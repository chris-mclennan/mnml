---
severity: SEV-3
status: fixed
---
# Files pane: the cursor bar `▌` paints over the `✓` mark of the selected row, so the row under the cursor never looks marked

**Command id:** `files.mark_toggle` (Space), shift-click / ctrl-click marks. Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"run-command","id":"files.open"}
{"cmd":"click","col":50,"row":18}
{"cmd":"key","key":"enter"}
{"cmd":"key","key":"space"}
{"cmd":"key","key":"up"}
{"cmd":"snapshot"}
```

**screen.txt**:
```
│ ↑  hunt › vscode-scratch (28)                              ✓1   sort: Name       .
│   Name                                                           Size     Modified Kind
│▌  data/                                                                    22m ago dir
│   alpha.zig                                                      183B      34m ago zig
```
The header counts one mark; no row shows `✓`. Move the cursor down and `✓  data/` appears. The same happens after a shift-click range (`✓5` with four visible checks) and ctrl-click.

**Expected**: the mark survives the cursor (a second glyph column, or `▌` styled on a `✓` cell) — a user deciding whether to Space-toggle the current row cannot see its state.
**Actual**: both glyphs share column 0 of the row and the cursor wins.

**Source pointer**: the row painter in `src/ui/files_view.zig` (cursor glyph written after the mark glyph into the same cell).

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.

## Fix

Commit `fix(files): a marked row keeps its tick under the cursor`.

`files_view` paints the marker column as the tick whenever the row is
marked; the cursor row is told by its band. The view test now expects
`✓M README.md` for the marked cursor row; `tests/e2e-zig/files_mark_under_cursor.test`.
