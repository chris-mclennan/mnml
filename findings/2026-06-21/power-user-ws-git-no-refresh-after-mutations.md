---
finding: git-mutations-skip-after-git-change-rail-stale
severity: SEV-2
agent: power-user-ws-git
repro: code-review
---

# `:git.merge` / `:git.rebase` / `:git.delete_branch` / `:git.worktree_*` skip `after_git_change` — rail goes stale

Every other git-mutation helper in `src/app/git.rs` calls
`self.after_git_change()` on success — it's the standard "git
state may have changed, refresh the git status snapshot + rail +
status panes + graph panes + rail pulls" hook (see lines 1280
[stash push], 1294 [stash pop], the cherry-pick / push / pull
arms in `drain_git_results`, etc.).

The new picker accept handlers do NOT:

- `git_merge_branch` (line 2130): toast only. No refresh.
  HEAD moved, branch is now ahead of upstream, working tree may
  have new files — rail's ahead/behind count, status snapshot,
  and any open `Pane::GitStatus`/`Pane::GitGraph` all show stale
  data until the next refresh trigger.

- `git_rebase_onto` (line 2139): same. After rebase the current
  branch's commits all have new SHAs — graph pane shows the OLD
  ones.

- `git_delete_branch_apply` (line 2186): no refresh. The git rail's
  `branches` list still includes the deleted name until something
  else (e.g. fetch) triggers a rail refresh. The user can right-
  click the deleted branch in the rail and try to checkout it —
  git fails with "did not match any file(s) known to git".

- `git_worktree_add_apply` (line 2290): doesn't call
  `after_git_change` but DOES call `add_workspace_runtime` which
  triggers some refresh side-effects. The rail's `worktrees`
  list isn't updated though.

- `git_worktree_remove_apply` (line 2268): no refresh. Rail still
  shows the removed worktree.

## Fix sketch

Add `self.after_git_change()` to each success arm. For deletes:

```rust
pub fn git_delete_branch_apply(&mut self) {
    let Some(name) = self.pending_branch_delete.take() else { return };
    let repo = self.active_repo_path().to_path_buf();
    match crate::git::branch::delete_branch(&repo, &name) {
        Ok(()) => {
            self.toast(format!("deleted branch {name}"));
            self.after_git_change();
        }
        Err(e) => self.toast(format!("delete {name}: {e}")),
    }
}
```

Worktree add/remove additionally need to refresh the rail's
worktree list (currently a separate `self.git_rail.refresh(&root)`
that `after_git_change` already runs — so the same fix lands them
both).

When the merge-block-UI finding is fixed (separate report)
by moving these through `git_loader_tx`, the `drain_git_results`
arms can call `after_git_change` centrally.
