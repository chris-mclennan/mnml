---
severity: SEV-2
status: fixed
---
# `j` moves the cursor into a closed fold's hidden lines

**Command ids:** `editor.close_fold` (`zc`), vim `j`.

**Reproduction**:
```
{"cmd":"open","path":"hunt/long.zig"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"z c"}
{"cmd":"key","key":"j"}
{"cmd":"snapshot"}
```
**status.json**: `"cursor":{"line":2,"col":1}` while screen.txt shows the fold `1 pub fn fn1(a: i32) i32 { ⋯ folded` followed directly by line `9` — line 2 is not on screen; the cursor is inside the fold.

**Expected**: `j` from a closed fold lands on the first visible line after it (line 9); `k` from below lands on the fold header.

**Actual**: the cursor walks through hidden lines 2…8 one `j` at a time with nothing visible moving. Reproduced twice. (`zo`, `za`, `zc` toggling themselves are fine.)

**Source pointer**: `src/editor/motion.zig` vertical motion does not consult `buffer.zig` folds.

## Fix

`1671c9d` on branch `vim-edit` — vim: a closed fold is one line to j / k and to dd / yy. Regression: `tests/e2e-zig/vim_*.test` for this finding, plus unit rows in `src/editor/buffer.zig`.
