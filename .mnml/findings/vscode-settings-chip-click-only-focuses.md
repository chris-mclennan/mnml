---
severity: SEV-2
status: fixed
---
# Settings overlay: clicking a choice chip or a number row's `‹ ›` arrow only focuses the row — the value never changes

**Command id:** `view.settings` (`ctrl+,`). Reproduced on two fresh launches, 2/2.

**Reproduction**:
```
{"cmd":"key","key":"ctrl+,"}
{"cmd":"dump-rects"}
{"cmd":"click","col":72,"row":4}
{"cmd":"snapshot"}
```
`rects.json` for row y=4 (Relative line numbers):
```
{"label":"overlay_item:1048832","x":63,"y":4,"w":5,"h":1}   ← "[off]" chip
{"label":"overlay_item:1048833","x":71,"y":4,"w":2,"h":1}   ← "on" chip
{"label":"overlay_item:1","x":25,"y":4,"w":48,"h":1}        ← the row, registered last, spans x=25..72
```
**screen.txt** before / after the click on `on`:
```
   Relative line numbers:             [off] / on
 ▸ Relative line numbers:             [off] / on
```
Same for a number row: `Lines per wheel notch: ‹ [4] ›` — clicking the `›` at (69,36) leaves `[4]` (row rect `overlay_item:37` x=25 w=45 covers the arrow). Keyboard `←`/`→` on the same rows works.

**Expected**: click on a choice selects it; click on `‹`/`›` steps the number (VS Code settings are mouse-first; the row's own handler `settings_app.click` → `.option` → `setRow` intends exactly this).
**Actual**: every chip and arrow is painted, listed in `rects.json`, and dead — the click resolves to the row and only moves `▸`.

**Source pointer**: `src/ui/settings.zig:305` registers the full-width row rect *after* the option hits at `:301` / `:288` / `:292`; `src/ui/hit.zig:123-129` `entryAt` walks the hit list from the end, so the row wins. `src/app/settings.zig:442-459` (`click`) never sees `.option`.

## Fix

`d6dd972` — settings: a choice chip takes the click, not the row under it. The row rect registers before its chips, so the hit map's back-to-front scan resolves a chip's cells to the chip (D6, last painted wins). Pinned by `tests/e2e-zig/settings_chip_click.test` and the chip-walk in `src/ui/settings.zig`'s draw test.
