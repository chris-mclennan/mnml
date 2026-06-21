---
finding: git-merge-rebase-worktree-block-ui-thread
severity: SEV-2
agent: power-user-ws-git
repro: code-review
---

# `:git.merge` / `:git.rebase` / `:git.delete_branch` / `:git.worktree_add` block the UI thread

The new git pickers (commits `8be0ba6`, `9358ac8`, `fbff72b`)
land their accept handlers as synchronous shell-outs in
`src/app/git.rs`:

- `git_merge_branch` (line 2130): calls `crate::git::branch::merge`
  which is `Command::new("git").args(...).output()` — blocking.
- `git_rebase_onto` (line 2139): same shape.
- `git_delete_branch_apply` (line 2186): same shape.
- `git_worktree_add_apply` (line 2290): same shape, AND on
  success it calls `add_workspace_runtime`, which itself
  canonicalizes + reads the dir, etc.
- `git_worktree_remove_apply` (line 2268): same shape.

By contrast, the existing fetch/pull/push/cherry-pick (this same
file, lines 1306-1366) and checkout (line 2418) all go through
`git_loader_tx` for async dispatch — they were explicitly moved
async per `untouched-surfaces-hunt-2026-06-08 SEV-2 #9`.

The new pickers reintroduced a previously-fixed class of bug. A
merge over a slow repo (large worktree, conflicts being resolved,
post-receive hooks, signed commits, etc.) can freeze the UI for
seconds. A worktree add on a large repo can take minutes —
filesystem checkout speed bounds it.

Toast UX is misleading too — `self.toast(format!("merging {name}…"))`
fires BEFORE the blocking call, but no tick runs between the
toast and the blocking call, so the "merging…" toast never
actually paints. The user sees the prior frame frozen until the
shell-out returns, and only then sees the final "merged" or
"merge: <error>" toast.

## Fix sketch

Mirror the existing `git_loader_tx` pattern. Extend `GitJob` with:

```rust
GitJob::Merge { repo: PathBuf, branch: String },
GitJob::Rebase { repo: PathBuf, onto: String },
GitJob::DeleteBranch { repo: PathBuf, name: String },
GitJob::WorktreeAdd { repo: PathBuf, path: PathBuf, branch: String },
GitJob::WorktreeRemove { repo: PathBuf, path: PathBuf },
```

and matching `GitResult` variants. `drain_git_results` already
handles the pattern — just add the arms.

Side benefit: the now-async merge can detect "conflicts in
progress" and post a richer toast (or open a status pane) instead
of just surfacing git's stderr line.
