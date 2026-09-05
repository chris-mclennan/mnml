---
severity: SEV-3
status: open
---
# Files pane and tree do not notice files created outside mnml until a manual refresh — no watcher on the listing

**Command id:** `files.refresh` / tree `r` (the only way the new file appears). Reproduced on two fresh launches, 2/2.

**Reproduction** (a shell `touch` between the two batches):
```
{"cmd":"run-command","id":"files.open"}
{"cmd":"click","col":50,"row":18}
{"cmd":"key","key":"enter"}
{"cmd":"snapshot"}
# touch vscode-scratch/zzz-external3.txt
{"cmd":"wait_ms","ms":3000}
{"cmd":"snapshot"}
{"cmd":"run-command","id":"files.refresh"}
{"cmd":"snapshot"}
```

**screen.txt** header: `hunt › vscode-scratch (28)` before, `(28)` three seconds after the touch, `(29)` only after `files.refresh`. The tree behaves the same (`r` reveals `zzz-external.txt`). In the first session a whole `big/` directory created on disk a minute earlier was absent from the listing, so the next click landed on the wrong row and `ctrl+c` copied `data/` instead.

**Expected**: VS Code's Explorer and any file manager refresh on filesystem events; mnml-zig already has a throttled watcher for TODOS (`watch.check` → `noteFileChanged`, PARITY row 341), and the Files pane re-reads after its own operations.
**Actual**: only self-initiated changes re-read the directory; external tools (git checkout, a build, another editor) leave the pane stale, and stale rows mean the next keyboard action targets the wrong file.

**Source pointer**: `src/app/files_pane.zig` (`reload` is called from the pane's own ops and `refreshCmd` only); the watcher in `src/app/watch.zig` is subscribed by `todos.zig` alone.

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.
