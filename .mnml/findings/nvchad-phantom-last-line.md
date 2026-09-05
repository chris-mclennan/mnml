---
severity: SEV-3
status: open
---
# A file ending in `\n` shows a phantom empty line N+1 in the gutter

**Command ids:** editor view (`src/ui/editor_view.zig`).

**Reproduction** (a.txt = 9 lines, trailing newline):
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"key","key":"G"}
{"cmd":"snapshot"}
```
**status.json**: `"cursor":{"line":9,"col":1}` and the statusline says `Ln 9/9`; **screen.txt**:
```
10|   9 yankee zulu
11|  10
```

**Expected**: vim shows 9 numbered lines; the trailing newline is the line terminator, not a tenth line.

**Actual**: a numbered empty line 10 is painted that `G` cannot reach. Cosmetic, but it is the first thing a vim user notices when opening any file. Seen in every launch.
