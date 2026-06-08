# mnml untouched-surfaces bug hunt — 2026-06-08

Scope: git, http, AI, DAP, `.test` runner, `keys.edit`. Skipped all
surfaces touched in the 2026-06-08 session (chrome / editor / hover /
settings / drag-select / scrollbar / wheel / context menus / new chords)
since they were freshly hunted.

## Severity counts

- **SEV-1 (crash / data loss / UI freeze)**: 2
- **SEV-2 (broken workflow / security)**: 9
- **SEV-3 (polish)**: 2

## Top 3 (fix first)

1. **SEV-1 — `git push/pull/fetch/cherry-pick` block the UI thread.** All
   four shell-out via `Command::output()` on the foreground event loop. A
   push that triggers a credential helper, an SSH key prompt, or a slow
   remote freezes mnml until git completes. No spinner, no cancel, no
   input. Should use the `spawn_ai_job` background-thread + channel
   pattern instead.
2. **SEV-1 — `shell_exec` agent tool can hang forever via pipe-inheriting
   grandchildren.** `tool_shell_exec` has a 60s timeout on the child but
   no timeout on the stdout/stderr reader threads.
   `command = "sleep 9999 &"` exits sh immediately but the backgrounded
   sleep inherits the pipe ends — `stdout_join.join()` waits forever. AI
   agent thread is stuck for the rest of the session.
3. **SEV-2 — `tool_write_file` follows symlinks.** Path validation rejects
   `..` and absolute paths, and checks `parent.canonicalize().starts_with
   (workspace)` — but the target leaf itself isn't checked. A pre-existing
   symlink `foo.txt -> /tmp/important` lets `write_file("foo.txt", "...")`
   punch through to `/tmp/important`. Fix: open with `O_NOFOLLOW`.

## SEV-1 details

### 1. Git sync ops block the UI thread

**Files**: `src/git/sync.rs:21-71`, `src/app/git.rs:1261-1331`
(`run_git_fetch`, `run_git_pull`, `run_git_push`), `src/app/git.rs:
1336-1356` (`run_git_cherry_pick`)

`fn run(workspace, args)` uses `Command::output()` (blocking). Every
caller invokes from event handlers, not a worker thread. Net effect: any
push/pull that triggers cred helper / SSH prompt / network slowness
wedges the whole event loop. Only Ctrl+C from the terminal recovers.

### 2. `shell_exec` reader threads have no timeout

**File**: `src/ai/api_client.rs:1078-1149`

`TIMEOUT = 60s` on `child.try_wait` ✓. But `stdout_join.join()` /
`stderr_join.join()` after the kill have no deadline — and `read_to_end`
only returns when every FD holding the pipe end closes. Backgrounded
grandchildren (`&`, `nohup`, `disown`) keep the pipe alive past the
parent's exit, so join blocks indefinitely.

## SEV-2 details

### 3. `tool_write_file` follows symlinks outside the workspace

**File**: `src/ai/api_client.rs:1153-1177`. Reproducer:
`ln -s /tmp/sentinel $WS/safe.txt; ask agent to write_file("safe.txt",
"X")`. Result: `/tmp/sentinel` overwritten. Fix: `O_NOFOLLOW` on Unix.

### 4. `dap.clear_all_breakpoints` doesn't sync to the live adapter

**File**: `src/app/dap.rs:52-63`. Clears `b.breakpoints` in memory but
never calls `set_breakpoints_with_conditions` on the live `DapClient`.
UI shows no gutter; the program still stops where the adapter remembers.
Compare `dap_toggle_breakpoint` (line 19-48) which DOES sync.

### 5. `.test` runner `shell` step is unsandboxed RCE

**File**: `src/e2e/mod.rs:502-535`. `$SHELL -c <cmd>` in workspace cwd.
A cloned untrusted repo with `tests/e2e/*.test` + `cargo test` discovery
(`tests/e2e.rs`) = arbitrary shell in user's account. No warning in the
grammar docstring.

### 6. `.test` runner `write <rel>` doesn't reject absolute paths

**File**: `src/e2e/mod.rs:444-449`. `workspace.join(rel)` returns the
absolute path verbatim if `rel` is absolute. `write /etc/passwd "..."`
works. `Step::Open` (line 451) has the same hole. Fix: reject
`is_absolute()` + `ParentDir` components before join.

### 7. `git stash push` doesn't refuse with unsaved buffers — only warns

**File**: `src/app/git.rs:1225-1243`. Toast says "heads up: unsaved edits
in open buffers" but stash proceeds anyway. The buffer's in-memory edits
aren't stashed; later `stash pop` + save = silent loss. Compare
`run_git_pull` (line 1276-1295) which DOES refuse. Asymmetry is the bug.

### 8. `git stash drop` happens with no confirmation

**File**: `src/app/git.rs:1428-1455`, `src/app/picker.rs:528-534`. Enter
on a picker row immediately drops. Author's comment claims reflog
recovery — only true until the next `git gc` (~30 days). Branch delete
requires typing the name (`git_delete_branch_prompt` at `src/app/git.rs:
2406`); stash drop should at least match that.

### 9. `git checkout/restore/stage/blame/status-refresh` also block the UI

**Files**: `src/app/git.rs:521-554` (`toggle_blame`), `src/app/git.rs:
2032-2063` (`checkout_branch`), `src/app/mod.rs:3541-3561`
(`accept_discard_file`), `src/git/status.rs:86-89` (`refresh`). Same
shape as SEV-1 #1, lower severity because typically fast — but
`git blame` on a huge file or `git status` on the linux kernel can take
10+ seconds.

### 10. `git checkout`/`git branch -b` don't use `--` separator

**File**: `src/git/branch.rs:130-148`. `checkout(workspace, "-foo")` →
`git checkout -foo` treated as flag. Same for `create_from` source and
`delete_branch`. Mostly mitigated by git's own name validation, but fix
is trivial: insert `--` before the user-supplied name.

### 11. HTTP `Response.body` has no max-size cap

**File**: `src/http/mod.rs:151-153`. `resp.text()` slurps the full body.
10GB malicious response = OOM-kill mnml. Fix: bound with a
`take(MAX).read_to_end` or similar.

## SEV-3

### 12. Three keymap collisions at every startup

stderr warns about `f1` (`view.discovery` vs `view.help` vs `palette`)
and `ctrl+shift+o` (`editor.open_at_cursor` vs `lsp.symbols`). The
collision-warning landed today (2026-06-08) is doing its job —
surfacing the pre-existing duplicates.

### 13. git status pane shows octal-escaped Unicode filenames

`weird-😀.txt` displays as `weird-\360\237\230\200.txt`. Fix:
`git status --porcelain -z` + split on NUL.

## Verified working (no findings)

- `keys.edit` end-to-end with XDG_CONFIG_HOME set/unset, creates parent
  dir, appends stub idempotently, cursor lands inside section
- `git.status_pane` stage/unstage/commit round-trip
- `git.graph` rendering + embedded diff
- `http.send` parses .http, expands vars, fires reqwest, renders response
- `dap_repl_submit` handles missing session gracefully
- `tool_grep` / `tool_read_file` / `tool_list_directory` correctly
  canonicalize and use `-e` for patterns
- `discover` sanitize() prevents path traversal in spec-derived file names
