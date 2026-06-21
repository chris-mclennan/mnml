---
finding: git-merge-rebase-from-detached-head
severity: SEV-2
agent: power-user-ws-git
repro: e2e
---

# `:git.merge` / `:git.rebase` from detached HEAD: misleading picker, dangerous result

`App::open_merge_branch_picker` (src/app/git.rs:2080) and
`open_rebase_picker` (line 2105) compute the current branch with
`crate::git::branch::current(...)`, then exclude it from the
picker. But `current()` returns `None` on detached HEAD — so
NOTHING is excluded.

The picker title is then "Merge into current" / "Rebase onto…"
(the `cur.as_ref()` branches at lines 2091-2094 and 2122-2125
fall through to the bare default), which falsely implies the user
has a branch to merge into.

If the user accepts, `git_merge_branch(name)` / `git_rebase_onto(name)`
shell out to git, which will:

- For merge: refuse with "fatal: You are in 'detached HEAD' state.
  ... Cannot create new commit" — or worse, on some git versions,
  create an unreferenced merge commit that gets garbage-collected
  in 30 days. The error toast is fine but the user has already
  invested in picking a branch.

- For rebase: refuse with "fatal: It seems that there is already
  a rebase-apply directory..." — slightly less catastrophic but
  still confusing.

The fix is to check detached HEAD BEFORE opening the picker,
toasting "git.merge: detached HEAD — checkout a branch first"
the same way other commands do.

## Repro

```text
# .test — findings/2026-06-21/probe_merge_detached.test
shell git init -q
shell git config user.email t@x.com
shell git config user.name t
write seed.txt seed
shell git add .
shell git commit -q -m seed
shell git checkout -b feature
write a.txt feat
shell git add .
shell git commit -q -m feat
shell git checkout main 2>/dev/null || git checkout master 2>/dev/null
shell git checkout --detach HEAD

command git.merge
expect screen contains "Merge into current"
expect screen contains "feature"
```

## Fix sketch

```rust
pub fn open_merge_branch_picker(&mut self) {
    let cur = crate::git::branch::current(self.active_repo_path());
    if cur.is_none() {
        self.toast("git.merge: detached HEAD — checkout a branch first");
        return;
    }
    ...
}
```

Same shape in `open_rebase_picker` and `open_delete_branch_picker`
(`delete_branch` from detached HEAD would also be a no-op-with-
weird-toast situation).
