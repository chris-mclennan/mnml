---
severity: SEV-3
status: open
---
# Host statusline segments are fitted by codepoint count, so segments with wide glyphs overflow the row and push the workspace chip off the right edge

**Command id / surface:** IPC `statusline-set-segment` (what every integration's chip uses); the statusline at 80×24.

**Reproduction** (fresh launch, 80×24):
```
{"cmd":"statusline-set-segment","id":"seg1","side":"right","text":"S1 界界 11","priority":10}
{"cmd":"statusline-set-segment","id":"seg2","side":"right","text":"S2 界界 22","priority":20}
{"cmd":"statusline-set-segment","id":"seg3","side":"right","text":"S3 界界 33","priority":30}
```
Control: the same three with `abcd` (the same 4 cells) in place of `界界`.

**Expected:** a wide segment takes the budget its cells take; the row fits 80 columns either way.

**Actual** (screen.txt row 23):
```
before:  START  [no file]                  F 58% ▼0.6  󱼀 󰐎    01:35  ws-71   —
ascii:   START  [… S3 abcd 33  S2 abcd 22   F 58% ▼0.6  󱼀 󰐎    01:35  ws-71
wide:    START  [… S3 界 界  33  S2 界 界  22  S1 …   F 58% ▼0.6  󱼀 󰐎    01:35  ws-
```
With wide text a third segment is admitted (each `界` counted as one cell), the painted row is 4+ cells wider than the screen, and the workspace chip is cut to `ws-` (its hit rect is `x 75 w 5`).

**Why:** `ipc.effects.pack` measures `natural` with `std.unicode.utf8CountCodepoints` and `truncate` keeps "the first `width` codepoints" (`src/ipc/effects.zig:270`, `:284`) — codepoints, not display cells.

**Reproduced:** 3/3 fresh launches.
