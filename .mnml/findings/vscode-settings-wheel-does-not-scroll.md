---
severity: SEV-3
status: fixed
---
# Settings overlay: the mouse wheel does not scroll the list (keyboard does)

**Command id:** `view.settings` (`ctrl+,`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"key","key":"ctrl+,"}
{"cmd":"scroll","col":60,"row":20,"dy":-10}
{"cmd":"snapshot"}
{"cmd":"scroll","col":60,"row":20,"dy":-5}
{"cmd":"snapshot"}
```
**screen.txt** (top of the list, unchanged after both wheels):
```
 ── UI ──
   Line numbers:                      off / [on]
 ▸ Relative line numbers:             [off] / on
```
Thirty-six `down` presses scroll the same list to `── Editor ──` / `Lines per wheel notch`, so the rows exist.

**Expected**: wheel over the overlay scrolls it (it is a 60-row list in a 35-row box).
**Actual**: nothing; the wheel event is dropped. The overlay's `surface` rect (`overlay_item:1048575`) receives the scroll and `settings_app.click` / `key` have no scroll branch.

**Source pointer**: `src/app/dispatch.zig` `.overlay_item` mouse branch → `settings_app.click(app, i)` handles `.press` only; `src/ui/settings.zig:238-243` computes `scroll` from the cursor alone.

## Fix

`73589ba` — settings: the wheel scrolls the box. `ui/settings.State.wheel` slides the window by `wheel_lines × count` and carries the cursor inside it; the dispatcher's `.overlay_item` arm routes `.scroll_up` / `.scroll_down` there while Settings is up. Pinned by `tests/e2e-zig/settings_wheel.test` and a `State.wheel` unit test.
