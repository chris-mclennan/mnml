---
severity: SEV-2
status: fixed
---
# `{count}.` after `cw` corrupts the line (`3.` on `delta echo foxtrot` → `PAPPAPPAPA`)

**Command ids:** vim `.` repeat (`src/editor/buffer.zig` dot state), `c` + `w`.

**Reproduction**:
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"c w"}
{"cmd":"type","text":"PAPA"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"0"}
{"cmd":"key","key":"3 ."}
{"cmd":"snapshot"}
```
**screen.txt**:
```
 2|   1 PAPA bravo charlie
 3|   2 PAPPAPPAPA
```
(line 2 was `delta echo foxtrot`).

**Expected**: `3.` replays the change with count 3 → `3cw` → `PAPA` (line 2 becomes `PAPA`). Even the other defensible reading (repeat the whole change three times) yields `PAPA echo foxtrot`.

**Actual**: the change is replayed three times but each replay starts from the previous replay's cursor and re-deletes partially, leaving `PAP` + `PAP` + `PAPA` and losing `echo foxtrot`. Reproduced twice from fresh launches. Plain `.` (no count) after `cc` works.

**Source pointer**: `src/editor/buffer.zig` dot-repeat with a count — the count is applied as "repeat N times" with the cursor left one column past the inserted text between iterations.

## Fix

`3ddb205` on branch `vim-edit` — vim: {count}. replaces the recorded change's count. Regression: `tests/e2e-zig/vim_*.test` for this finding, plus unit rows in `src/editor/buffer.zig`.
