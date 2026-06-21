---
finding: pending-branch-delete-leaks-on-prompt-cancel
severity: SEV-3
agent: power-user-ws-git
repro: code-review
---

# `pending_branch_delete` is not cleared on `prompt_cancel`

Symmetric to the worktree-add sentinel finding, but with smaller
blast radius.

`App::git_delete_branch_confirm` (src/app/git.rs:2177) sets
`self.pending_branch_delete = Some(name)` then opens the
`GitDeleteBranchConfirm` prompt. The accept handler
(src/app/picker.rs:1349) gates on `input == "delete"`:

```rust
crate::prompt::PromptKind::GitDeleteBranchConfirm => {
    if p.input.trim().eq_ignore_ascii_case("delete") {
        self.git_delete_branch_apply();
    } else {
        self.pending_branch_delete = None;
        self.toast("branch delete cancelled");
    }
}
```

The "type 'kill' instead of 'delete'" path clears
`pending_branch_delete`. Good.

But `prompt_cancel` (src/app/picker.rs:1004) does NOT clear it —
only `pending_delete_branch` (a different field — note the
suffix swap: `delete_branch` vs `branch_delete`) and friends are
cleared.

Concrete consequence: user opens `:git.delete_branch`, picks
branch `foo`, sees the "type 'delete' to force-delete branch
foo" prompt, then Esc. `pending_branch_delete = Some("foo")`
remains set. Next time the user opens `:git.delete_branch` and
picks branch `bar`, picker accept reassigns it
(`self.pending_branch_delete = Some("bar")`), so the stale "foo"
gets overwritten — no harm done.

But: between the Esc and the next picker open, if anything ELSE
goes through `git_delete_branch_apply` (e.g. a context-menu
"Delete branch foo" action that bypasses the picker), it'll
read the stale `pending_branch_delete`. Today no such bypass
exists for THIS exact stash, but the `GitDeleteBranch` confirm
prompt (note: different prompt kind, opened from the rail's
right-click) uses a separate `pending_delete_branch` stash that
IS cleared.

Two pending stashes named almost identically, two prompts named
almost identically, one is cleared on cancel and one isn't —
that's a maintenance trap.

## Fix sketch

- Add `self.pending_branch_delete = None;` to `prompt_cancel`.
- OR rename one of the two stashes to disambiguate — e.g.
  `pending_picker_branch_delete` vs `pending_rail_branch_delete`.

The worktree-add sentinel finding (separate report) is the same
class of bug with bigger blast radius. Fix them together.
