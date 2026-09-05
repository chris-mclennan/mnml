---
severity: SEV-3
status: open
---
# Trash view: every `files.trash` opens another `Trash` tab, and `↑` from it walks into `<data root>/trash` with the breadcrumb spelling out the data-root path

**Command id:** `files.trash`, `files.up` (the `↑` breadcrumb button). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/bravo.txt"}
{"cmd":"run-command","id":"files.trash"}
{"cmd":"run-command","id":"files.trash"}
{"cmd":"snapshot"}
{"cmd":"click","col":32,"row":2}
{"cmd":"snapshot"}
```

**screen.txt**:
```
│ bravo.txt   Trash   Trash   +
│ ↑  sessions › v1 › data › trash › 20536f505c027737 (0)          sort: Name       .
│  The trash is empty
```
after `↑`:
```
│ ↑  scratchpad › sessions › v1 › data › trash (1)
│▌  20536f505c027737/                              just now dir
│   20536f505c027737.index.zon                20B  just now zon
```
(`status.json` `panes`: `bravo.txt, Trash, Trash`; the statusline reads `TRASH  /private/tmp/…/scratchpad/sessi`.)

**Expected**: a singleton view (VS Code re-focuses an existing view rather than opening a twin) titled for the workspace, whose `↑` returns to the workspace root; the data-root layout (`trash/<hash>/`, `.index.zon`) is an implementation detail.
**Actual**: each call adds a pane; the breadcrumb is the raw data-root path; `↑` browses the data root's trash directory (other workspaces' hashes included), where marks/paste/delete all still work.

**Source pointer**: `src/app/files_pane.zig` `trashCmd` (always `open(app, trash_dir)`), `upCmd` (no stop at the trash root); `src/app/trash.zig` `isTrashDir`.

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.
