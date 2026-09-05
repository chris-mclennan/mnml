---
severity: SEV-3
status: fixed
---
# One insert session is several undo steps (`u` after `i…<Esc>` undoes only the last line)

**Command ids:** `editor.undo` (`u`), `src/editor/undo.zig`.

**Reproduction**:
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"O"}
{"cmd":"type","text":"one two\nthree"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"u"}
{"cmd":"snapshot"}
```
**screen.txt**:
```
 2|   1 one two
 3|   2
 4|   3 alpha bravo charlie
```
In an earlier session a `fresh file\nline two` insert took four `u` presses to reach the empty buffer.

**Expected**: everything typed between `i`/`o`/`O` and `Esc` is one undo step (Vim `:help undo-blocks`); a single `u` removes both lines.

**Actual**: the insert is chunked (at least per newline); `u` peels it back piecemeal. Reproduced twice. Reads as "not quite vim" rather than dangerous, hence SEV-3.

## Fix

`2376e20` on branch `vim-edit` — vim: one Insert session is one undo step. Regression: `tests/e2e-zig/vim_*.test` for this finding, plus unit rows in `src/editor/buffer.zig`.
