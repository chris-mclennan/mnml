---
severity: SEV-3
status: open
---
# `files.open_split` adds two Files panes — a duplicate tab in the current group *and* the split

**Command id:** `files.open_split` ("open a second file-browser pane beside this one"). Reproduced on two fresh launches, 2/2 (from an editor pane and from a Files pane).

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/bravo.txt"}
{"cmd":"run-command","id":"files.open"}
{"cmd":"run-command","id":"files.open_split"}
{"cmd":"snapshot"}
```

**screen.txt** (tab strips): `bravo.txt   hunt   hunt │ hunt   +` — `status.json` `panes` goes from 2 to 4 (`bravo.txt, hunt, hunt, hunt`). Each further `files.open_split` adds two more.

**Expected**: one new pane beside the active one (VS Code "Split Editor Right" = +1).
**Actual**: `openSplitCmd` calls `open(app, dir)` (a fresh pane in the current group) *and then* creates `second` for the split.

**Source pointer**: `src/app/files_pane.zig:623-634` — `const left = try open(app, dir);` at `:626` should reuse the focused Files pane when there is one.

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.
