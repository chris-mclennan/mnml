# mnml VS-Code mouse-first bug hunt — 2026-06-10

Persona: VS Code refugee. Trackpad is the whole world. Keyboard only for typing. If a thing has no mouse path, it doesn't exist.

Binary: `/Users/chrismclennan/Projects/mnml/target/release/mnml` (splash version `3ad2e2245`). Driven via file IPC at `/tmp/mnml-mouse-hunt/.mnml/ipc/` using `--headless --input standard`.

## Executive summary
- SEV-1: 0
- SEV-2: 6
- SEV-3: 8

**How mouse-discoverable does mnml feel?** Decent for the surfaces I expected, painful for the next layer in. Tree rail, tab strip, palette bar, statusline chips, activity bar, integration `+` chip, branch / git icons, command palette — all on screen, almost all with hover tooltips, mostly clickable. I can open a file by clicking, switch tabs, drag-reorder tabs, drag the rail edge, drag the split divider, middle-click to close, right-click a tree row for a full per-file menu, click activity-bar icons to swap rails. Basics: yes.

Walls: Settings overlay paints clickable-looking `[on] / off` chips and silently swallows every click on them. The `+ Add integration` overlay drops every click anywhere inside the panel. A dirty tab swaps its close-X for a modified-dot, and that dot doesn't accept a click — **no mouse path to close a dirty tab**. Double-click doesn't select word, triple-click doesn't select line. Save-prompt buttons render as keyboard mnemonics. Activity-bar icons, palette-bar arrows, the `♪ mixr` chip, the split divider are all silent on hover. I could get my day's work done; Settings would have to wait, closing dirty tabs would have to wait.

## SEV-2

1. **Settings overlay swallows all clicks on option values.** Row title click moves the `▸` focus arrow; clicking value glyphs themselves does nothing. Only `←` / `→` keys mutate. CLAUDE.md says discrete-choice rows use arrow keys by design — but the visual screams clickable.
2. **+ Add integration overlay swallows all mouse clicks.** Opens via tooltipped `󰐙` chip on INTEGRATIONS rail. Then left-click inside the overlay (row, footer, anywhere) dismisses; the focus arrow never moves. Footer literally says "↑↓ move · Enter add · i install · y yank · Esc close" — entirely keyboard.
3. **No mouse path to close a dirty tab.** Dirty buffers swap close-X for `●` modified-dot, which isn't clickable. Middle-click on tab body also nothing on dirty tabs.
4. **Double-click doesn't select word; triple-click doesn't select line.** `tui.rs` tracks `last_click` for SCM panes but the editor-body mouse-down branch never reads the count.
5. **Tree single-click is preview; no double-click pin gesture wired.** Source comment claims "double-click pins" but the tree-click handler never reads `app.last_click`.
6. **Right-click on bufferline tab sometimes fails to open the context menu.** Earlier in a session right-click works reliably; after a sequence of left/middle clicks elsewhere it stops opening the menu. Trigger not fully isolated.

## SEV-3

1. `+ Add integration` chip tooltip shows raw command id `integrations.add` instead of a human description.
2. No hover tooltips on activity bar icons (Explorer / Search / Source Control / Debug / Integrations).
3. No hover tooltip on the `♪ mixr` now-playing chip in the statusline.
4. No hover tooltips on palette-bar back / forward / dropdown chevron.
5. Save-prompt buttons `[S]ave  [D]iscard  [C]ancel` look like keyboard mnemonics, not buttons.
6. Tree-edge resize handle is exactly 1 cell wide — fiddly with a trackpad.
7. Vertical editor scrollbar is invisible (background colors only, no glyph/border).
8. Recent-files dropdown picker's top entry is the currently open file (selecting is a no-op).
9. Git-rail file-row click semantics confused — clicking a staged file's row caused that row + 2 others to flip back to unstaged. Expected VS Code behavior is "open the file's diff".

## Positive notes

Welcome overlay outside-click dismiss · tree single-click preview / folder expand / drag rail edge · tree right-click full menu including Reveal in Finder · workspace header chips tooltipped + clickable · bufferline `+` / `1` / `2` / close-X all work · tab drag-reorder · middle-click closes clean tab · activity-bar icons swap rail content on click · statusline EDIT / branch / LSP / clock / workspace / filetype 2-line tooltips · git rail chips fetch/pull/push/stage/commit/graph tooltipped + fire · branch chip → graph · Stage All click · split divider drag-resize · editor scrollbar click + drag (despite invisibility) · wheel scroll · **Alt+click multi-cursor** · right-click menu dismisses on outside-click · palette type-to-filter + row-click run · 100 rapid clicks stable · recent-files picker row-click open.
