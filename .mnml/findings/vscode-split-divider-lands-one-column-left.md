---
severity: SEV-3
status: fixed
---
# Split divider drag lands one column left of the pointer, every time

**Command id:** none (mouse drag on `divider:0`). Reproduced on two fresh launches, 6/6 drags.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"key","key":"ctrl+\"}
{"cmd":"dump-rects"}
{"cmd":"drag","from_col":75,"from_row":10,"col":100,"row":10}
{"cmd":"dump-rects"}
{"cmd":"drag","from_col":99,"from_row":10,"col":60,"row":10}
{"cmd":"dump-rects"}
```
**rects.json** `divider:0` x after each drop: `75 → 100` gives `99`; `99 → 60` gives `59`; session 1: `83→100`→`99`, `99→70`→`69`, `69→60`→`59`, `59→90`→`89`. The tree divider (`divider:4294967295`) and the right-panel divider both land exactly on the pointer.

**Expected**: the divider follows the pointer (VS Code sash: the handle sits under the cursor when released).
**Actual**: split dividers settle at `target − 1` — the ratio is recomputed from the pointer and floored, so the second drag must start from a different column than the user released on.

**Source pointer**: `src/app/dispatch.zig` `beginDividerDrag` / `continueDrag` `.divider` ratio math for `Layout` splits (`src/app/layout.zig`) vs. the exact width math used for the tree/right-panel dividers.

## Fix

`63da25f` — layout: a dragged split divider lands on the pointer's column. `ratioAt` returns the percent whose `firstLen` lands on the cell (rounded up; past 100 cells the nearer candidate). Pinned by `tests/e2e-zig/split_divider_lands_on_pointer.test` and a `ratioAt` round-trip unit test.
