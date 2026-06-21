---
severity: SEV-2
surface: git pickers (merge / rebase)
hunt: vscode-user mixed-input
date: 2026-06-21
---

## [SEV-2] `git.merge` / `git.rebase` pickers fast-forward / rewrite history on a single mouse click — no confirmation, no toast preview

**Reproduction**:
```jsonc
// Workspace with a divergent feature branch
//   main:        A -- B (HEAD)
//   feature/bar: A -- C
{"cmd":"key","key":"esc"}                                // dismiss welcome
{"cmd":"run-command","id":"git.merge"}                    // opens "Merge into main" picker
{"cmd":"snapshot"}                                        // confirms feature/bar row visible
{"cmd":"click","col":28,"row":8,"button":"left"}          // single click on feature/bar
{"cmd":"wait_ms","ms":1000}
// Now `git log --oneline --all --decorate` shows main
// has fast-forwarded onto feature/bar — *no* prompt was
// shown, no toast appeared.
```

Same flow with `git.rebase` accepts the picked branch and tries to
rebase the current branch onto it the instant the row is clicked.

**Expected**: VS Code's source-control destructive ops (delete branch, rebase,
hard reset) all gate on a confirm dialog. A single click on a *row* in any
picker should select; a second action (Enter / double-click / a `merge`
button) should commit the destructive op. mnml itself does this for
`git.delete_branch` (single-click pops the "type 'delete' to force-delete
branch <name>" confirm prompt) and for `git.worktree_remove` (same pattern
with "type 'remove'"). Merge and rebase are at least as destructive as
deleting a branch — they rewrite the current branch.

**Actual**: The generic picker mouse handler (`src/tui.rs:3577-3596`) calls
`app.picker_accept()` on `MouseEventKind::Down(Left)` for *any*
`PickerKind`. For `PickerKind::GitMergeInto` accept fires
`git_merge_branch(item.id.clone())` directly (`src/app/picker.rs:689-691`),
which shells `git merge --no-edit <name>` immediately. Same for
`PickerKind::GitRebaseOnto` (`src/app/picker.rs:692-696` →
`git_rebase_onto` → `crate::git::branch::rebase`). No `prompt` is opened,
no `close_prompt` interstitial; the merge / rebase runs in-process before
the user even sees the row highlight.

The asymmetry is jarring next to `GitDeleteBranch` and `GitWorktreeRemove`,
both of which DO open a `Prompt` confirm step on accept. From a VS-Code-user
perspective the mouse single-click on a destructive picker row reads as
"select for preview" — every native VS Code picker (Quick Pick / branch
picker / commit-graph picker) behaves that way.

**Source pointer**:
- `src/tui.rs:3577-3596` — picker mouse handler accepts on Down(Left)
- `src/app/picker.rs:689-696` — `GitMergeInto` / `GitRebaseOnto` accept
  arms shell out directly; compare to `:686-688` / `:700-707` which open
  confirm prompts.
- `src/app/git.rs:2139-2146` — `git_rebase_onto` toasts but never asks

**Notes**: Aggravating factor — `git.rebase` failures don't surface a useful
toast either when the active workspace isn't focused properly (the
`rebasing onto <name>…` toast wasn't visible during reproduction, and the
final "rebased onto <name>" / error toast also didn't appear; the picker
just closed). So a user who *intended* to merge gets a silent fast-forward,
and a user who intended to rebase gets either a silent success or a silent
no-op with no feedback.

Suggested fix shape: route `GitMergeInto` accept through a
`PromptKind::GitMergeConfirm` ("type 'merge' to merge <name> into <current>")
and `GitRebaseOnto` similarly, matching the existing `GitDeleteBranch` /
`WorktreeRemoveConfirm` pattern. Or at minimum: a non-modal toast
preview ("about to merge feature/bar — Enter confirm, Esc cancel") so the
single-click reads as a stage step, not an action step.
