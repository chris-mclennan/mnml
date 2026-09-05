---
severity: SEV-2
status: fixed
---
# `dd` on a closed fold deletes only the header line; the fold re-attaches to the next line

**Command ids:** `editor.close_fold` (`zc`), vim `dd`.

**Reproduction** (long.zig: every `pub fn` is 8 lines):
```
{"cmd":"open","path":"hunt/long.zig"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"z c"}
{"cmd":"key","key":"d d"}
{"cmd":"snapshot"}
```
**screen.txt**:
```
 2|   1     var s: i32 = 0; ⋯ folded · 7 lines hidden
 3|   9 pub fn fn2(a: i32) i32 {
```
Only `pub fn fn1(a: i32) i32 {` was removed; lines 2–8 (the body) still exist, now hidden under a fold whose header is `var s: i32 = 0;`.

**Expected**: in vim a closed fold is one line for line operators — `dd` deletes the whole fold (8 lines), `yy` yanks all of it.

**Actual**: one line deleted, fold state left stale over the wrong range (the fold now hides lines 2–8 of a 7-line remainder). Reproduced twice from fresh launches. `zc` from inside the body (`3G zc`) folds the right range, so detection is fine; it is the operator that ignores folds.

**Source pointer**: `src/editor/buffer.zig` folds vs. the linewise delete in `src/editor/delete.zig` — no fold-range expansion before the operator.

## Fix

`1671c9d` on branch `vim-edit` — vim: a closed fold is one line to j / k and to dd / yy. Regression: `tests/e2e-zig/vim_*.test` for this finding, plus unit rows in `src/editor/buffer.zig`.
