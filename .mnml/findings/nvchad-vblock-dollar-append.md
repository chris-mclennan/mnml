---
severity: SEV-2
status: fixed
---
# `$` in V-BLOCK does not extend to end-of-line — `Ctrl-V … $ A` appends at the shortest line's column

**Command ids:** vim V-BLOCK (`src/input/vim.zig` `VimMode.visual_block`), `A` append.

**Reproduction** (a.txt lines 1–3 have lengths 19 / 18 / 16):
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"ctrl+v"}
{"cmd":"key","key":"2 j"}
{"cmd":"key","key":"$"}
{"cmd":"snapshot"}
{"cmd":"key","key":"A"}
{"cmd":"type","text":";"}
{"cmd":"key","key":"esc"}
{"cmd":"snapshot"}
```
**status.json** after `$`: `"mode":"V-BLOCK","cursor":{"line":3,"col":16}`. **screen.txt** after `A;<Esc>`:
```
 2|   1 alpha bravo char;lie
 3|   2 delta echo foxtr;ot
 4|   3 golf hotel india;
```

**Expected**: with `$` the block is ragged-right; `A` appends `;` at the end of every line (`charlie;`, `foxtrot;`, `india;`).

**Actual**: the block is clipped to the cursor column of the line where `$` was pressed and `;` lands mid-word on the longer lines. `Ctrl-V … I` (insert at block start) works. Reproduced twice.

**Source pointer**: `src/editor/select.zig` block selection has no "to EOL" flag; `src/input/vim.zig` `$` in V-BLOCK just moves the cursor.

## Fix

`e6911f4` on branch `vim-edit` — vim: $ in V-BLOCK runs the block to every line's end. Regression: `tests/e2e-zig/vim_*.test` for this finding, plus unit rows in `src/editor/buffer.zig`.
