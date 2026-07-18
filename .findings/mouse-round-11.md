# mnml mouse hunt — round 11 (2026-07-12)

Headless drive against `~/Projects/mnml/target/release/mnml --input standard`,
workspace = a scratch `round11-ws` (git-init'd `src/main.rs`, `src/lib.rs`,
`docs/notes.md`, `api.http` + `.mnml/env/dev.env` with `TOKEN=abc123`).
Everything driven through `.mnml/ipc/`.

Focus:
1. Verify round-10 fixes (menu-bar hover-switch, settings row-click off-by-one,
   HTTP-panel COLLECTIONS collapse, toast surfaces).
2. Cover new mouse surfaces: palette recents-at-top, undo chip, stress meter,
   toast context menu, `+ dock` chip, split divider double-click, tree drag
   resize clamp, activity-bar right-click coverage, HTTP-panel section-header
   right-clicks, Notes filter row focus.

## Executive summary

**14 findings: 0 SEV-1 · 6 SEV-2 · 8 SEV-3.**

**Round-10 scoreboard: 4 of the 4 explicit SEV-2 items verified fixed** — menu-bar
hover-switch now works (click File, hover Edit → menu switches to Edit); settings
row-click no longer off-by-one (clicking Menu-bar label focuses Menu-bar, does
not silently toggle Cursor-line); HTTP-panel COLLECTIONS header collapses on
click; toast body now has a working right-click context menu (Dismiss this /
Dismiss all / Copy text to clipboard). Round-10 SEV-3 gaps remain — palette
recents ordering has landed but is still visually indistinguishable from the
long tail of unranked commands (no `── Recent ──` header).

**New territory dominated by three families.**

**(1) The Notes / activity filter row switches to HTTP.** A mouse-first user in
the NOTES activity who clicks the visible `󰍉 / filter` row at (~15, 2) gets
their sidebar swapped to HTTP without warning. The filter placeholder in HTTP
was underneath — apparently the filter click coord routes to the HTTP-panel's
filter input, dragging the activity along with it. Reproducible on every fresh
switch to NOTES. SEV-2 (silent activity swap).

**(2) HTTP-panel section headers still have no right-click affordance.** The
FILES / ENVS / CHAINS / MOCKS / RECENT / CAPTURED / COLLECTIONS headers accept
left-click-to-collapse (COLLECTIONS finally works, round-10 SEV-2 verified)
but right-click on any of them produces zero context menu. Section-header
right-click on a similar VS-Code-style tree gives Collapse-all / New item /
Show-hidden etc.; here the click just falls through to the pane below. Row
items themselves DO have full right-click menus (Set active / Open file / Rename
/ Delete on ENVS row, Open / Open as text / Open in split / Reveal / Yank / Rename
/ Delete on FILES row). Compare against tree rows in Explorer where every level
(root, folder, file) has a menu.

**(3) Invisible click targets in the workspace tree header.** The `▼ ● round…`
row displays a chevron + truncated workspace name and appears to be a plain
section header. But cols 15–24 in that row are silently mapped to
`file.new_folder` / `file.new` / `tree.refresh` icons that render only on
hover; a left-click at (15, 1) opens a **New folder in /** prompt instead of
toggling section collapse. Users clicking anywhere on the header past ~col 14
stop hitting the section toggle. Real hit-rect layering means a click on
whitespace fires a mutation prompt with no icon shown. SEV-2 (phantom click
target).

**Round-10 residuals still open (SEV-3):** toast box + cmdline row show the
same text redundantly (double-render); no `× close` glyph on the toast box
so click-to-dismiss remains hidden-only-in-subtitle; toast context menu
shows `Toast: (gone)` when the underlying entry TTL'd out just before the
right-click hit the stale rect (race).

## Findings

### SEV-2

**F1. Notes filter row click switches sidebar activity to HTTP.**
Steps: activity bar → Notes (y=20) → screen shows `NOTES` header + `󰍉 / filter`
row + `+ New note` button. Click (15, 2) on the filter row. Result: sidebar
shifts to HTTP activity — `HTTP` header, `󰍉 type to filter…▏` input, ▼ COLLECTIONS
/ ▼ FILES / ▼ ENVS visible. Nothing in the Notes pane changed. Reproducible
100% on switch → filter-click. Same class of issue likely on TODOs / Sessions
whose filter rows share the input widget.

**F2. HTTP-panel section headers have no right-click context menu.**
Steps: activity bar → HTTP → right-click (15, 3) COLLECTIONS header / (15, 5)
FILES / (15, 8) ENVS / (15, 14) CHAINS / (15, 18) MOCKS / (15, 21) RECENT /
(15, 24) CAPTURED. Result: no menu opens on any of them. Left-click collapses
(good). Right-click silently falls through to whatever pane is on top — user
sees no verb list. Compare to the ENVS `dev` item right-click which shows
Set active / Open file / Yank name / Yank path / Rename / Delete.

**F3. Phantom click targets in workspace-header row.**
Steps: hover over `▼ ● round…` header (y=1). Cols 15–24 look empty (whitespace
in the section-header row rendered padding). Left-click (15, 1). Result: a
`┌ New folder in / ────────────┐` prompt opens for the workspace root.
Expected: click on the workspace header collapses the section (which does
happen if you click at col 5–14 on the chevron/name). The hover-only icons
(`file.new_folder`, `file.new`, `tree.refresh` per `dump-rects`) claim their
hit-rects even when not visible. A click at col ≥15 on the header row silently
fires the wrong action.

**F4. Tree drag-resize doesn't clamp to config minimum (16).**
Steps: drag `tree_edge` (x=30 default) leftward all the way to col 0. Result:
tree drops to width=5 (`tree` rect w=5, `tree_edge` at x=8). Config schema says
`file_tree_width` min=16 (visible in Settings overlay: `File tree width [ 30 cols ]
(16–60 · step 2 · defa…`). Runtime drag ignores this floor. A 5-column tree is
mostly unusable (`▶ ●` visible + one char of workspace name). Not a crash, but
inconsistency between drag runtime and configured min drives users into
"how do I get my tree back to normal?" territory.

**F5. Toast subtitle promises "hover pauses TTL" but under sequential hovers
the toast still expires.**
Steps: fire toast, immediate hover at box center (col 111, row 36), 10 hovers
at 0.7s intervals (~7s total). Result: toast box gone from screen at ~5s in.
A *single* hover followed by a 6s sleep DOES preserve the box, so the mechanism
partially works — but the more common real-user pattern of holding the mouse
over the box while reading (which causes repeated Moved events) does not.
Empirically the mid-hover expiry reproduces even though the tick-based
created_at bump exists in code. The subtitle promise ("hover pauses TTL")
is what a mouse-first user acts on; when it fails during a normal-speed read,
the box vanishes mid-sentence and the affordance feels broken.

**F6. Split divider double-click no longer equalizes splits.**
Steps: create horizontal split via bufferline `[│]` chip → drag divider
from col 72 to col 88 (3:1 ratio) → double-click at (88, 10) → nothing
happens. Also tested with two back-to-back `mouse_down/mouse_up` pairs at
50ms interval → divider stayed at col 88. Round-9 landed `equalize_splits`
on divider double-click but the trigger doesn't fire under IPC clicks that
should be tight enough to count as a double-click. Real mouse double-clicks
may or may not be affected — worth a manual test.

### SEV-3

**F7. Palette recents-at-top has no visual separator or section header.**
Verified the reordering works: running `view.help`, `view.about`, `view.zen`
from palette, then reopening → `view.help / view.about / view.zen /
view.settings / app.quit / app.restart …` at the top. But the recently-used
rows look exactly like every other row — same `group · title · id` format,
same coloring, no `── RECENT ──` header. Users won't know they're looking at
"the palette knows what I ran" vs "the alphabetical/default order shuffled".
VS Code puts recents under a `Recently used` heading with visual separation.

**F8. Toast rendered TWICE — floating box + cmdline row at y=39.**
Every ephemeral toast puts the same string in the toast box at rows 35–37
(near bottom-right) AND writes the plain text to the cmdline row at y=39.
Redundant visual. If the intent is "persist the message on the cmdline after
the box fades", the semantics aren't obvious — the text shows up in both
places simultaneously, then the box fades but the cmdline line stays until
the next command runs.

**F9. Toast context menu shows `Toast: (gone)` when right-click hits a stale
rect.**
Steps: fire a toast, wait ~4s for TTL to expire, right-click at the coord
where the box used to be. Result: context menu opens with `Toast: (gone)`
as the header line + Dismiss this toast / Dismiss all toasts / Copy text
to clipboard as verbs. `(gone)` reads like an internal placeholder — users
right-clicking after the box fades don't know what "gone" means. Cleaner:
suppress the menu when the target toast no longer exists; or show
`Toast: (dismissed)` and offer only `Copy last toast text`.

**F10. Numeric settings rows look click-editable but clicks are silent.**
Rows like `Scrolloff  [ 0 ]  (0–20 · step…`, `Sidescrolloff [ 0 ]`,
`File tree width [ 30 cols ]` render brackets + a value + a range hint,
exactly matching the discrete-choice pattern where clicking a value cycles
it. Clicking on `[ 0 ]` on Scrolloff (col 76, row 24) focuses the row (`▸`
moves) but the value doesn't change. There's no visible increment/decrement
button, no input activation. The Settings CLAUDE.md convention notes
"Number rows are v2" — but the visible chrome makes them look v1-ready.
No-mouse-path to any numeric setting.

**F11. Settings section headers (`── UI ──`, `── Integrations ──`, `── Reset ──`)
don't respond to clicks.**
Steps: click (30, 8) on the `── UI ──` header. Result: no collapse, no focus
change. Section headers in most tree UIs collapse when clicked. mnml's
Settings has only 25-ish rows total so this isn't fatal — but as the schema
grows a click-to-collapse on section headers becomes essential.

**F12. `.. scratchpad` up-nav row has no right-click menu.**
Steps: right-click (10, 2) on the `▌   .. scratchpad` row. Result: no menu.
Left-click navigates workspace root up one level (works). Right-click could
offer `Go to project root`, `Copy path`, `Open in Finder` — none appear.

**F13. `+ dock` chip at bottom-right toggles behaviour is unclear.**
Steps: click the `+ dock` chip (col 115, row 37). Result: docks toggle
(open/close). But the label reads "+ dock" which implies **add** a dock,
not toggle. Hover on the chip shows a "dock widget #1" popup for the
docked Note-1 item, plus "Click × to close, or run `dock.close_all`" —
suggesting the chip is more of a docks-inventory hover than an "add" verb.
Right-click at the same coord sometimes routes to the still-alive toast
context menu below the chip (F9 stale-rect problem again). Rename or
re-glyph to match behavior: `[⚏] docks` chip that opens a dock picker,
with `+ New dock` a separate button inside the popup.

**F14. Tree scroll wheel doesn't scroll the tree when tree is short.**
Steps: hover over tree, scroll down 3 ticks (`{"cmd":"scroll","col":10,
"row":15,"dy":-3}`). Result: no visible change in the tree. Only ~20 tree
rows exist in this session so scrolling isn't strictly needed, but a
mouse-first user with a long workspace list will not know if the wheel
scrolls the tree (it should) or the editor (which it can, if focused).
Test with a longer tree next round.

## Verifications (round-10 items still holding)

- **Menu-bar hover-switch**: click File (12, 0) → File menu opens.
  Hover Edit (18, 0) → menu switches to Edit (Find/Replace items visible).
- **Settings row-click off-by-one**: click Menu-bar row (50, 10). Result:
  focus (`▸`) moves to Menu-bar, value stays `[always] / auto / hidden` —
  no silent Cursor-line toggle. Click on the value `hidden` (col 77, row 10)
  correctly cycles to `always / auto / [hidden] *`.
- **HTTP-panel COLLECTIONS collapse**: click (15, 3) on `▼ COLLECTIONS (0)`.
  Result: chevron flips to `▶ COLLECTIONS (0)`, following section moves up.
- **Toast body right-click menu**: right-click on the toast box body opens
  a proper `Toast: <text>` context menu with three verbs.
- **Alt+click multi-cursor**: click at col 40 row 2 in editor + Alt+click at
  col 55 row 2 + type "X" → two `X`s inserted in the same line (`pub Xfn add
  (a:i32, bX:i32) …`). Verified working.
- **Tab drag-reorder**: drag tab:0 from (40, 1) → (85, 1) reorders (notes.md
  moved past lib.rs).
- **Tab context menu**: right-click a tab shows Close / Close others / Close
  all / Copy path / Reveal in Finder / Split right / Split down / Split left /
  Split up — rich, correct.
- **Middle-click dirty tab**: middle-click on dirty tab shows Unsaved changes
  prompt with Save / Discard / Cancel buttons. No silent data loss.
- **Statusline chip tooltips**: hover each of mode / branch / mixr / LSP /
  clock / workspace / language chips → each shows `click: <verb> ·
  right-click: <menu>` tooltip. All 7 chips have valid right-click menus
  (mode → Input style / vim / standard, branch → git ops, workspace → repo
  switch, etc.).
- **Activity-bar right-click**: every activity icon (Explorer / Search /
  Source control / Debug / Integrations / Sessions / Agents / Cloud agents /
  HTTP / Notes / TODOs) has a right-click menu with at least a
  "Show <activity>" verb. Coverage looks complete.
- **Right panel drag-resize**: dragging the right-panel edge from col 87 to
  col 60 widens the panel; dragging back to col 111 narrows to 9 cells with
  header truncation. No clamp on the narrow side either (F4-adjacent —
  same pattern as tree drag).
- **Palette dropdown chevron**: click at (78, 0) with buffers open shows a
  Recent files picker.
- **Nav Back right-click**: right-click at (40, 0) shows a `Nav Back` menu
  with recent buffers + Clear buffer MRU. Correct.

## How mouse-discoverable does mnml feel this round

Better than round 10, worse than a good VS Code clone. Round-10's top SEV-2s
(menu-bar hover-switch, settings mis-toggle, COLLECTIONS collapse) all
verified fixed — a mouse-first user coming back this session would notice
their most-annoying prior gripes gone. Chip / tab / activity-icon right-click
coverage is now solid; the tooltips on statusline chips explicitly advertise
"click: X · right-click: Y" which is exactly what a VS Code refugee expects.

But the invisible-icon click-through in the workspace header (F3), the
Notes filter → HTTP activity switch (F1), and the HTTP-panel section-header
right-click gap (F2) all still block a genuine mouse-first day of work. The
tree resize below the configured minimum (F4) makes it easy to break your
own layout with a stray drag. And numeric-settings rows look clickable but
silently refuse (F10) — a mouse-first user reading the `Scrolloff [ 0 ]`
row has literally no way to change it.

Could I get my day's work done without learning a chord? For editing +
navigating + splitting + switching tabs + firing HTTP requests — yes,
comfortably. For adjusting Scrolloff or `File tree width` values, changing
Notes filters, or right-clicking to add a new collection — no, I'd hit the
gaps in F1/F2/F10 and either hunt for a chord or give up.
