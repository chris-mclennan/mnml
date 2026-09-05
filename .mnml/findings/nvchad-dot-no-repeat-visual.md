---
severity: SEV-3
status: open
---
# `.` does not repeat an operator applied to a visual selection

**Command ids:** vim `.` repeat (`src/editor/buffer.zig` dot state), V-LINE `d`.

**Reproduction**:
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"V"}
{"cmd":"key","key":"j"}
{"cmd":"key","key":"d"}
{"cmd":"key","key":"."}
{"cmd":"snapshot"}
```
**screen.txt** after `Vjd`: `1 golf hotel india / 2 juliet kilo lima …`; after `.`: unchanged (`golf hotel india` still line 1).

**Expected**: `.` re-applies `d` to the same number of lines from the cursor (Vim `:help visual-repeat`) → `mike november oscar` becomes line 1.

**Actual**: no-op. Reproduced twice. `.` after `cc`, `cw`, `dd` works.
