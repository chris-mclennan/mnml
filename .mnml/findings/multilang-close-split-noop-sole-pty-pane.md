---
severity: SEV-2
status: open
---

# `view.close_split` silently no-ops when a pty pane is the ONLY pane in the layout

## Summary

`view.close_split` ("Close split / buffer") correctly closes a pty pane
when there's another split to fall back to. But when the pty pane is the
**sole** pane in the layout — the common case of running `npm.test` /
`pytest.run` / etc. from a fresh workspace with nothing else open — the
command acks `ok:"true"` and does **nothing**: the pane stays open, the
status bar still shows the pty pane, `status.json.panes` is unchanged.
This reproduces identically whether the pty is still **running** or has
**already exited** (`EXITED` state, "any key closes" prompt showing).

This isn't a hard UI constraint — pressing a literal key (e.g. `enter`) on
an EXITED pty, or `ctrl+c` on a running one, *does* successfully empty the
layout (`panes: []`, `focus: "tree"`). So the layout can legitimately go
empty; `view.close_split` specifically just refuses to do it when it's the
last pane.

Given the task brief's explicit question ("Can the pty be killed mid-run
via the existing pty-pane controls?") — the answer for the single-pane case
is: not via the documented close command, only via `ctrl+c` (which works,
but is an implicit terminal convention, not the app's pane-close control).

## Repro (verified twice — running pty, then already-exited pty)

Workspace: `/Users/chrismclennan/Projects/mnml-zig-worktrees/hunt-py/ts-app`
(added a `dev` script: `"sleep 30 && echo done-sleeping"` to
`package.json` for a controllable long-running pty).

**Case A — running pty, sole pane:**

```json
{"cmd":"run-command","id":"npm.run"}      // spawns "npm run dev" as the ONLY pane
{"cmd":"wait_ms","ms":700}
```

Confirmed via `ps`: `npm run dev` (pid 7744) → `sh -c sleep 30 ...` (7768)
→ `sleep 30` (7771) all running, parented under the mnml-zig process.

```json
{"cmd":"run-command","id":"view.close_split"}
{"cmd":"wait_ms","ms":500}
{"cmd":"snapshot"}
```

`status.json`: `panes:[{"title":"npm run dev","dirty":false}]` — unchanged.
`screen.txt` bottom bar still `TERM  npm run dev`. `ps -p 7744 7768 7771`
still shows all three processes alive.

Sending `{"cmd":"key","key":"ctrl+c"}` instead (same state) *does* close
the pane (`panes:[]`, tree focus) **and** kills the process tree (`ps -p`
returns nothing afterward).

**Case B — already-exited pty, sole pane:**

```json
{"cmd":"run-command","id":"npm.lint"}     // "echo lint-placeholder", exits fast
{"cmd":"wait_ms","ms":500}                // now EXITED, "any key closes"
{"cmd":"run-command","id":"view.close_split"}
{"cmd":"wait_ms","ms":300}
```

`status.json`: `panes:[{"title":"npm run lint","dirty":false}]` — again
unchanged; the EXITED pane is still there. Sending a literal `{"cmd":"key","key":"enter"}`
in the same state *does* dismiss it (`panes:[]`).

Both cases reproduced from the same live session (npm.run → close_split
no-op → ctrl+c works → npm.lint → close_split no-op again → enter works).

## Expected vs actual

- Expected: `view.close_split` closes/kills the sole pty pane (running or
  exited), same as it does when there's a second split to fall back to.
- Actual: it's a silent no-op specifically when the pty pane is the only
  pane — no error, no toast, `ok:"true"` regardless.

## Command id

`view.close_split`
