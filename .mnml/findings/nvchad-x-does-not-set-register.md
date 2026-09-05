---
severity: SEV-2
status: open
---
# `x` does not write the unnamed register — `xp` (swap two chars) is broken

**Command ids:** vim `x` (`editor.delete_char` path in `src/input/vim.zig`), `:reg`.

**Reproduction** (a.txt line 1 = `alpha bravo charlie`):
```
{"cmd":"open","path":"hunt/a.txt"}
{"cmd":"key","key":"g g"}
{"cmd":"key","key":"l"}
{"cmd":"key","key":"x"}
{"cmd":"type","text":":reg\n"}
{"cmd":"snapshot"}
{"cmd":"key","key":"esc"}
{"cmd":"key","key":"p"}
{"cmd":"snapshot"}
```
**screen.txt**: after `x` the line is `apha bravo charlie`; the `:reg` toast reads `│ :reg — empty │`; after `p` the line is still `apha bravo charlie` (nothing pasted; in a session where a linewise register existed from an earlier `dd`, `p` pasted that line instead and moved the cursor to line 2).

**Expected**: `x` yanks the deleted character into `""` (and `"-`), so `p` gives `aplha …`. `xp` / `ddp` are among the most common vim reflexes.

**Actual**: `x` deletes without touching any register. `dd`, `dw`, `yy` do populate registers correctly (verified via `:reg`), so it is specific to `x`. Reproduced from two fresh launches.

**Source pointer**: `src/input/vim.zig` — the `x` / `X` branch emits a delete without the yank-to-register step that the operator path (`src/editor/clipboard.zig`) uses.
