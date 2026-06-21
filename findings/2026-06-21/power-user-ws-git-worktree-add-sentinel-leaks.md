---
finding: worktree-add-sentinel-leaks
severity: SEV-1
agent: power-user-ws-git
repro: e2e
---

# Esc on `:git.worktree_add` leaks a sentinel that hijacks the next `view.add_workspace`

`App::open_worktree_add_prompt` (src/app/git.rs:2201) primes
`pending_worktree_path = Some(PathBuf::new())` as a sentinel,
then opens the shared `PromptKind::AddWorkspace` prompt. The
AddWorkspace accept handler in src/app/picker.rs:1062 checks for
this sentinel and reroutes the typed path to the worktree-add
flow.

`prompt_cancel()` in src/app/picker.rs:1004 clears most pending
stashes (`pending_rename`, `pending_fs_action`,
`pending_delete_branch`, `pending_worktree_remove`,
`pending_branch_source`, `pending_lookup_picked_id`,
`pending_env_edit_key`) — but NOT `pending_worktree_path`.

Result: pressing Esc on the worktree-add path prompt leaves the
sentinel in place. The very next time the user opens
`view.add_workspace` (the "Open folder…" flow) and types a path,
mnml routes the path into the worktree-add flow instead of
opening it as a workspace — the user gets a "Branch for /tmp
(Enter to create):" prompt they never asked for.

## Repro (passes after the prompt unexpectedly hijacks):

```text
# .test script — findings/2026-06-21/probe_worktree_sentinel.test
shell git init -q
shell git config user.email t@x.com
shell git config user.name t
write seed.txt seed
shell git add .
shell git commit -q -m seed

command git.worktree_add
expect screen contains "Worktree"
key esc

command view.add_workspace
expect screen contains "Workspace path"
type /tmp
key enter
wait 100
# This assertion FAILS — the Branch prompt IS shown
expect screen lacks "Branch for"
```

The test fails on line 29 with "screen unexpectedly contains 'Branch for'":
the AddWorkspace flow has been hijacked by the stale sentinel.

## Fix sketch

Add `self.pending_worktree_path = None;` to `prompt_cancel` alongside
the other pending clears. (Or better — promote the sentinel to a
typed enum field rather than overloading `Option<PathBuf>`.)
