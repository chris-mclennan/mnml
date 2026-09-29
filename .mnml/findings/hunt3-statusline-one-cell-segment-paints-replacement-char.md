---
severity: SEV-3
status: open
---
# A host segment truncated to one cell paints U+FFFD — half of the `…` ellipsis's UTF-8 bytes

**Command id / surface:** IPC `statusline-set-segment`; any segment whose share of the lane is one cell (`max_width: 1`, or a lane with 3 cells left).

**Reproduction** (fresh launch, 120×40):
```
{"cmd":"statusline-set-segment","id":"tiny","side":"right","text":"abcdef","priority":90,"max_width":1}
```

**Expected:** a one-cell chip shows `…` (or the segment is dropped).

**Actual** (screen.txt row 39):
```
 TREE  [no file]                                                      �   F 58% ▼0.6  󱼀 󰐎    01:35  ws-76   —
```
The chip holds the replacement character (`ef bf bd` in the dump).

**Why:** `truncate` in `src/ipc/effects.zig:287` returns `ell[0..@min(ell.len, width)]` when `width <= ell_w`; the unicode ellipsis is 3 bytes with a width of 1, so `width == 1` slices its first byte, an invalid UTF-8 sequence.

**Reproduced:** 3/3 fresh launches.
