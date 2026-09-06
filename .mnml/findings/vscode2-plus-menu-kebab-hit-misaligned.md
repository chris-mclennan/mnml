---
severity: SEV-3
status: fixed
---
# `+` menu: the per-row `⋯` kebab is painted 2–3 cells right of its hit rect — clicking the visible glyph closes the menu (or runs the row); the Pin / Hide list is only reachable by clicking blank cells

**Command id:** `menu.pin_row` / `menu.hide_row` / `menu.copy_id` (the curation list, `context_menus.openCuration`). Reproduced on two fresh launches, 2/2, in two tab-strip geometries.

**Reproduction**:
```
{"cmd":"open","path":"vscode-scratch/alpha.zig"}
{"cmd":"click","col":45,"row":1,"button":"right"}
{"cmd":"click","col":55,"row":2}
{"cmd":"hover","col":80,"row":2}
{"cmd":"snapshot"}
{"cmd":"dump-rects"}
{"cmd":"click","col":90,"row":2}
{"cmd":"snapshot"}
```

**screen.txt** row 2 (cells): `│    New          ▸ ││    New file…     ⋯ │` — the `⋯` sits at cell **90**, the submenu's right border at 92.
**rects.json**: `menu_item:1:0 x=68 w=20` (the row, cells 68–87), `menu_item:3:0 x=87 w=1` and `menu_item:3:0 x=88 w=1` (the kebab). A click at 90 or 91 → no hit → `closeOverlay`, the menus vanish. A click at 88 → the curation list (`Pin to top / Hide this row / Copy command id`) — which then works and persists (`plus_menu_hidden = .{"file.new"}` in `config.zon`, honoured after relaunch). With a longer tab strip (`pic.png [PNG]`) the hits were 90/91 with the row rect ending at 90, and a click on 90 ran the row (a `[scratch]` tab opened).

**Expected**: the glyph and its hit share cells (the settings-chip fix `d6dd972` set the rule: a chip takes the click, not the row under it).
**Actual**: the kebab hit is registered at the row's text end while the glyph is right-aligned in the box; at one geometry the first hit cell is still inside the row rect, so the row wins there.

**Source pointer**: the submenu painter that registers `menu_item:3:*` (kebab) vs. where it draws `⋯` — `src/ui/menu_view.zig` / `src/app/context_menus.zig:356` (`openCuration`), `src/app/dispatch.zig:1140-1150`.

Seed (all under `vscode-scratch/`): `alpha.zig` (the 15-line zig file with `alpha`/`beta`/`gamma`), `bravo.txt` (`bravo line 1..3`), `charlie.txt`, `t1.txt`…`t15.txt`. Launch: `MNML_DATA_ROOT=<fresh dir> MNML_COLS=120 MNML_ROWS=40 mnml-zig --headless --input standard <workspace>`.

## Fix

Commit `fix(menu): a click on a child row's kebab glyph opens the curation`.

The measurement in this finding did not reproduce: replaying the drive
(`alpha.zig` tab, right-click 45, click 55) paints `⋯` at cell 87 — the
first of the two `menu_item:3:0` hit cells — in both the unit test (cell
readback) and the e2e text dump; the "90" was a column miscount. The second
observation was real and is the bug: `paintMenuRows` registered the glyph
cell's hit *before* the full-width row hit, and the last-registered hit
wins, so a click on the glyph ran the row and only the margin cell beside
it reached Pin / Hide / Copy. The row's hit now stops where the kebab
starts and the kebab's two cells are registered after it. Unit test in
`context_menus.zig` (the glyph cell resolves to `menu=3`; the click opens
`Pin to top`); `tests/e2e-zig/plus_menu_kebab.test`.
