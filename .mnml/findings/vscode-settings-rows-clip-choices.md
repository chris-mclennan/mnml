---
severity: SEV-3
status: fixed
---
# Settings overlay clips the option list on wider rows at 120 columns (`[newest] / oldest / name /`)

**Command id:** `view.settings` (`ctrl+,`). Seen on every open across three launches.

**Reproduction**:
```
{"cmd":"key","key":"ctrl+,"}
{"cmd":"snapshot"}
```
**screen.txt** (120×40, default `tree_width`):
```
│   TODOS sort:                        [newest] / oldest / name /     │
│   AI icon in the bar:                none / [claude_code] / codex / │
│   Coverage chip:                     both / [feature] / code /      │
```
The overlay box is 71 cells wide (`overlay_item:1048575` x=24 w=71); `ListSort` has six values and the AI-icon row four, so the tail (`name Z–A`, `…`) is never visible and `→` steps onto choices the user cannot see.

**Expected**: the row wraps its options, abbreviates, or the overlay uses the width it has (PARITY lists "the overlay's 60 % × 70 % centering" as remaining, but the clipping is independent of centering).
**Actual**: `ui.settings` draws options until `x + ow > r.right()` and silently `break`s (`src/ui/settings.zig:297`), so a keyboard user cycles through invisible values and a mouse user cannot reach them at all (see the chip-click finding).

**Source pointer**: `src/ui/settings.zig:294-303`.

## Fix

`566b5af` — settings: a row's choices window around the active one instead of clipping. `choiceWindow` grows from the active value outward while the row fits and marks each hidden side with `‹` / `›`, a hit on the nearest hidden choice; the bracketed value is never dropped. The box keeps its 60 % width. Pinned by `tests/e2e-zig/settings_row_window.test` and a `choiceWindow` unit test; holds at 80 columns.
