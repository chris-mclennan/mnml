---
severity: SEV-2
status: fixed
---
# `Ctrl+Q` during a Files-pane copy quits immediately — the `:qa` transfer guard only exists on the ex path, so the standard profile's only quit leaves a half-written tree behind

**Command id:** `app.quit` (`ctrl+q`), `file.paste` (`ctrl+v` in the Files pane). Reproduced on two fresh launches, 2/2.

**Reproduction** (needs a tree big enough to take a second — `python3` making `vscode-scratch/big/d000..d119/f000..f149.txt`, 18,000 × 4 KB, did it):
```
{"cmd":"run-command","id":"files.open"}
{"cmd":"wait_ms","ms":300}
{"cmd":"click","col":50,"row":18}
{"cmd":"key","key":"enter"}
{"cmd":"click","col":50,"row":4}
{"cmd":"key","key":"ctrl+c"}
{"cmd":"click","col":50,"row":5}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"snapshot"}
{"cmd":"key","key":"ctrl+q"}
{"cmd":"snapshot"}
```
(row 18 = `vscode-scratch/`, row 4 = `big/`, row 5 = `data/` in the default name sort.)

**screen.txt** (after `ctrl+v`): statusline `FILES  vscode-scratch/data   Ln 1/4 Col 0  ⇄ 0%  standard`, toast `copying 1 item into vscode-scratch/data`. After `ctrl+q`: `events.jsonl` shows `{"event":"key","key":"ctrl+q"}` then `{"event":"exit"}`, rc 0. On disk: run 1 `data/big` absent, run 2 `find data/big -type f | wc -l` → 169 of 18000.

**Expected**: the same guard the ex path has — `src/app/ex.zig:112-115` refuses `:qa` with `N transfer(s) still running — transfer.cancel_all, or :qa! to quit anyway`. VS Code keeps the window open while a file operation is in flight. A standard-profile user has no `:qa`; `ctrl+q` is the quit.
**Actual**: `cmd_app.zig` `quit` checks `anyDirty()` only, sets `app.quit = true`, and the transfer workers are killed mid-copy. The source survives (copy) but a partial destination tree is left with no toast on the next launch; a cross-volume move would be worse.

**Source pointer**: `src/app/cmd_app.zig:140-146` (`quit`: no `app.transfersRunning()` check); the guard that should be shared lives at `src/app/ex.zig:112-115` (`src/app/transfers.zig:16` documents it as `:qa`-only).

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.

## Fix

Commit `fix(app): Ctrl+Q asks the transfer guard :qa already had`.

`transfers.quitGuard(app, force)` is the one guard; `cmd_app.quit` calls it
before the dirty check (so the Save/Discard box can never be a way past
it). `ex.zig`'s `:qa` keeps its inline check, byte-for-byte the same
message, because that file belongs to the live `vim-round2` track — fold
it onto `quitGuard` once that lands. Unit test in `transfers.zig` (a 400-file
copy, `app.quit` refused, `cancel_all` then quits); `tests/e2e-zig/quit_transfer_guard.test`
pastes a 3000-file tree and sends Ctrl+Q while it copies.
