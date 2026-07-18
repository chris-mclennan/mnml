# mnml mouse hunt — round 13 (2026-07-14)

Headless drive against `~/Projects/mnml/target/release/mnml --input standard`,
workspace = a scratch `round13-ws` (git-init'd `src/main.rs`, `src/lib.rs`,
`docs/notes.md`, `README.md`, `api.http`, `subdir1/subdir2/deep.txt`,
`.mnml/env/dev.env` with `TOKEN=abc123`). Everything driven through
`.mnml/ipc/` — keyboard only for typing text bodies and `Esc` /
`/` (proving the mouse-only path was closed for the settings filter).

Focus:
1. Verify the eight priority items called out in the round-13 kickoff.
2. Re-probe the round-12 SEV-2 / SEV-3 residuals that were not scheduled
   for this batch of fixes.
3. Fresh hunt around drag/drop edges, right-panel empty-state clicks,
   right-click completeness on chrome elements, timing artifacts.

## Executive summary

**11 findings: 0 SEV-1 · 4 SEV-2 · 7 SEV-3.**

**Priority-verification scoreboard (8 items):**
- **P1 Workspace-header cold left-click no phantom-fire · hover-then-click
  still fires · right-click menu correct** — VERIFIED FIXED. Cold clicks at
  cols 15, 18, 21, 24, 27 on row 1 (icon positions) produced no `New folder in
  /` / `New file` / `git.pull` prompts (round-12 F1 confirmed dead). Hover
  at (15, 1) then click still fires the `New folder in /` prompt. Right-click
  at (15, 1) after hover-away opens the workspace context menu (Toggle expand,
  Expand recursively, Collapse recursively, Switch workspace…, Add workspace…,
  Manage workspaces…, Set as default workspace, Remove workspace, Reveal in
  Finder, Refresh tree).
- **P2 Split-divider double-click equalizes** — **PARTIALLY FIXED**. Works
  when the user hovers the divider first (hover_divider_idx set → line 2794
  path triggers). Does NOT work under a cursor-far-away → click → click
  sequence (the round-12 F2 "fix" at down_left.rs:231 is still unreachable
  under IPC-driven zero-hover click pairs). See F1 below — the fallback
  block at line 231 that was supposed to remove the hover dependency is
  present but the second click's is_double check evaluates false in the
  cursor-away scenario. Real mouse users typically hover before clicking
  a resize handle, so they'll hit the working path; headless tests and
  power users doing `click-fast-click-fast` may not.
- **P3 Settings `/ filter` row click focuses the filter** — **STILL BROKEN**
  (round-12 F3 unfixed). Rects dump lists 23 `settings_row:*` entries but
  no `settings_filter_row` rect. Clicks at cols 26, 30, 40 on the placeholder
  row do not switch the filter into edit mode; typing after the click still
  routes to the value-cycler ('L' cycles `Line numbers` on the focused row).
  The `/` key remains the only way in.
- **P4 Bufferline hover-close reveals × on dirty inactive tabs** —
  VERIFIED FIXED. api.http (dirty, inactive) with cursor-far-away
  hover-then-hover on the tab shows badge switch from `●` to `󰅖` in orange.
  Verified twice with a fresh workspace + verified via close-rect
  registration (bufferline_tab_close rects now include the dirty inactive
  tab's badge zone; regression confirmed on a clean tab where hover reveals
  × in grey).
- **P5 Bufferline dirty active tab has a close hit-rect** — VERIFIED FIXED.
  Click at (43, 1) on main.rs's `●` badge while main.rs is active + dirty
  opens the Save / Discard / Cancel unsaved-changes prompt. Prior to the
  fix the rect wasn't registered so the click fell through to "activate".
- **P6 HTTP-panel MOCKS section right-click menu shows Save / Replay verbs**
  — VERIFIED FIXED (after fresh process restart). Right-click at (15, 18)
  on `▼ MOCKS (0)` opens a menu titled "MOCKS" with 4 items: `Save active
  response as mock`, `Replay mock into active request`, `Toggle all sections`,
  `Refresh HTTP panel`. **Caveat / new SEV-3 (F5 below):** on a long-lived
  session that has re-entered the HTTP activity, the same right-click showed
  only the trailing 2 items — the section-specific `Save`/`Replay` items
  went missing. Repro'd across 4 attempts; disappears after a fresh mnml
  restart. Suspect a stale-state pathway inside
  `open_http_panel_section_context_menu`.
- **P7 Tree drag-resize clamps to min 16** — VERIFIED FIXED. Drag from
  x=30 to x=5 landed at x=16 (matches `[ui] file_tree_width` min). Second
  drag from x=16 to x=80 lands at x=80 — the **max side is still
  unclamped** (F5-round12 residual, see F6 below).
- **P8 Toast hover pauses TTL under repeated Moved events** — VERIFIED FIXED
  (round-12 pass still holds). Not re-probed in depth; existing tests +
  round-12's 7-second Moved sweep result stands.

**Round-12 residuals (regression check):**
- **F1-round12 workspace-header phantom icons** — FIXED (see P1 above).
- **F2-round12 split-divider dbl-click** — PARTIAL (see P2 above + F1 below).
- **F3-round12 settings /filter click** — STILL BROKEN (see P3 above).
- **F4-round12 numeric-settings row double-click affordance** — STILL BROKEN
  (see F4 below).
- **F5-round12 tree edge max clamp** — STILL BROKEN (see F6 below).
- **F6-round12 activity-bar right-click menus with only "Show X"** — STILL
  BROKEN on 6 of 11 activities (see F7 below).
- **F7-round12 empty-tree-space right-click** — STILL BROKEN.
- **F8-round12 split-strip right-click** — STILL BROKEN.
- **F9-round12 git toolbar chip tooltips + right-click** — STILL BROKEN.
- **F10-round12 git-panel section header right-click** — STILL BROKEN.
- **F11-round12 dock widget subtitle × claim** — STILL BROKEN (dock widget
  chrome only exposes ⋮ menu; kebab menu itself is complete, see below).
- **F12-round12 dock widget title label vs anchor drift** — not re-probed
  this round.

Fresh hunt turned up four new gaps.

## Findings

### SEV-2

**F1. Split-divider double-click doesn't equalize when the pointer arrives
directly via a click (no prior hover on the divider).**
Steps: Split editor via `view.split_right`; skew via 2× `view.split_grow_width`
(divider at col 83). Move cursor far away via `hover(10, 10)` → `wait_ms 500`.
Two clicks at (83, 15) 80 ms apart. Expected: divider snaps back to 50/50.
Result: no change; divider stays at 83. Same experiment with divider at 79,
97, and 81 — all fail. When the same second click sequence is preceded by
a `hover` DIRECTLY ON THE DIVIDER (setting `hover_divider_idx`), the equalize
fires (divider snaps from 81 → 72 for a 47.5% split). Round-12 F2's fix at
`src/tui/mouse/down_left.rs:231-251` was intended to remove the hover-idx
dependency by falling back to `split_dividers.iter().any(contains)`, but
under the zero-hover IPC path it still doesn't reach `equalize_splits()`.
A real trackpad user hovers naturally before double-clicking, so this
shows up mostly in scripted tests + power users doing fast click sequences.
The prior round-11 fallback at line 2794-2814 is now definitely dead code
too (the earlier line 253 `begin_divider_drag` return still short-circuits
it — same reason round-12 called it dead). Two dead copies of the equalize
check sit in the source for one broken code path.

**F2. Settings `/ filter` row remains unclickable (round-12 F3 unfixed).**
Steps: `activity_bar_gear` → Settings opens with the `/ filter` placeholder
at row 8. Rects dump: 23 `settings_row:N` entries, no `settings_filter_row`.
Click at (26, 8), (30, 8), (40, 8), (50, 8) — no focus indicator, no cursor
caret. Typing "L" after the click sends the letter to the value-cycler on
the focused row (cycles `Line numbers`). Pressing `/` on the keyboard is
still the only way to activate the filter. Mouse-first user has no path
to narrow the 30+ row settings list.

**F3. Right-panel empty-state picker's `▸ Outline`, `▸ AI chat`, `▸ Grep`,
`▸ Tests` rows silently no-op unless an editor pane is already active +
focused.**
Steps: Toggle right panel while an HTTP Request pane is active. Right panel
shows the empty-state list with 5 rows. `right_panel_empty_outline` rect at
(89, 5, 13, 1) is registered. Click at (92, 5) — no state change. Click at
(92, 6) — Problems opens. Click at (92, 7 / 8 / 9) — no state change. Root
cause: the underlying commands (outline.show / ai.chat / find.grep /
test.run_file) all check for an `active_editor()` and quietly return
(`no active editor` toast or similar). The click IS wired, but if the
active pane isn't an Editor the picker fires-and-forgets silently. Users
see "click did nothing" 4 times out of 5 in the natural flow — pick the
right panel, get the picker, click Outline, get nothing. VS Code's
equivalent picker either enables/disables the entry visually or shows a
toast explaining what the user needs to do. Compare Diagnostics (row 6),
which always opens because its pane is self-contained (a diagnostics panel
even for the workspace).

**F4. HTTP-panel MOCKS right-click menu drops its section-specific verbs
after non-fresh session activity (regression of P6 in continuous use).**
Steps: In a mnml process that has been through multiple activity switches
(HTTP → Explorer → HTTP → Git → HTTP), right-click at (15, 18) on
`▼ MOCKS (0)`. Result: menu title "MOCKS" is correct but the body shows
ONLY `Toggle all sections` + `Refresh HTTP panel` (2 items) — the
`Save active response as mock` and `Replay mock into active request` items
from the section=5 match arm are gone. `strings ~/Projects/mnml/target/release/mnml
| grep "Save active response"` confirms the string is compiled in.
Reproduced 4× in one session. After `kill $mnml_pid; ~/Projects/mnml/target/release/mnml
--headless …` the same right-click on MOCKS shows all 4 items. Suggests
stale state on `app.context_menu` reuse or on the section-headers rect
vec — the section id being passed to
`open_http_panel_section_context_menu` looks correct (title shows "MOCKS")
but items collapse to `Toggle`/`Refresh` regardless. SEV-2 because the
feature exists in code but is invisible in the exact flow it targets
(mock lifecycle).

### SEV-3

**F5. `+ dock` chip has no right-click menu; falls through to editor
context menu.** (Continuation of round-11 F13 residual.)
Steps: hover far, then right-click at (114, 37) on the `+ dock` chip.
Result: the editor pane's right-click menu opens (Cut / Copy / Paste / Undo
/ Redo / Select all / Go to definition / …). Left-click at (114, 37)
correctly opens a "Note 1" dock widget at Bottom-left. Expected right-click
verbs: `Add Note dock`, `Add scratch dock`, `Add clock`, `Hide + dock chip`
(discoverability toggle), maybe `Dock preferences…`. Note: the dock widget's
OWN kebab (⋮) menu is comprehensive (Position ⇒ 4 corners, Layout ⇒ Overlay
/ Inline, Opacity ⇒ Solid / Translucent, Rename…, Close) — the chip itself
is what's missing.

**F6. Tree drag-resize still lacks a MAX clamp.** (Round-12 F5-round12,
unfixed.)
Steps: drag tree_edge from x=16 → x=80. Result: edge lands at x=80, tree
occupies half the screen, main editor scrunched. `[ui] file_tree_width`
config max=60 not enforced. Right-panel edge has the same asymmetry
(min-clamp not implemented, max-clamp not implemented — verified indirectly
by round-11 F6-residual). MIN got a clamp; MAX did not.

**F7. Six of eleven activity-bar right-click menus still have only "Show X"
as their sole verb.** (Round-12 F6-round12, unfixed.)
- Search (row 4): `Show Search` — 1 verb.
- Source control / Git (row 6): `Show Source control` — 1 verb.
- Run and debug (row 8): `Show Run and debug` — 1 verb.
- Integrations (row 10): `Show Integrations` — 1 verb.
- Sessions (row 12): `Show Sessions` — 1 verb.
- Cloud agents (row 16): `Show Cloud agents` — 1 verb.
Agents (row 14) now has 2 (`Show Agents`, `Open dashboard`) — halfway
there. Explorer / HTTP / Notes / Todos have 2-3 useful verbs.

**F8. Right-click on empty tree space (below the last row) produces no
menu.** (Round-12 F7-round12, unfixed.)
Steps: Explorer → right-click at (10, 34) — below README.md, above the
tree scrollbar bottom. Result: no menu. `New file / New folder / Refresh
Explorer / Open in Integrated Terminal` (VS Code shape) would be natural.

**F9. Split-strip `[│]`, `[─]`, and terminal `[$]` buttons still have no
right-click menu.** (Round-12 F8-round12, unfixed.)
- (114, 1) `split_strip:0:Horizontal` → nothing on right-click.
- (117, 1) `split_strip:0:Vertical` → nothing.
- (111, 1) `split_strip_term:0` → nothing.
Left-click + hover tooltip all work. `split_strip_ai_claude` (108, 1) DOES
have a right-click menu (verified in round-12) so the gap is on the other
three chips.

**F10. Git activity toolbar chips (Undo / Redo / Pull / Push / Fetch /
Branch / Commit / Stash / Pop) have no hover tooltips and no right-click
menus.** (Round-12 F9-round12, unfixed.)
Hover at (26, 1), (44, 1), (53, 1), (72, 1) with cursor-far-away
pre-hover + 800 ms wait — no tooltip appears at any of them. Right-click
at (44, 1) on `󰅢 Pull` — no context menu. A user who doesn't recognize
the Nerd Font glyphs by heart can't discover which chip does what. Compare
statusline chips which all have `click: X · right-click: Y` tooltips.

**F11. Drag-to-bufferline-strip for tree files is a no-op.**
Steps: Explorer → drag `api.http` from (12, 10) in the tree to (30, 1)
on the bufferline strip. Result: nothing — the file doesn't open as a
new tab. Dropping the same file on the editor body (row 15) works fine
(creates a split or opens the file inline). VS Code + JetBrains both
allow dragging tree files to the tab strip as an open action; mnml's
`up_left.rs::handle_up_left` handles bufferline_tab-to-bufferline_tab
(reorder) and bufferline_tab-to-pane-body (split-open), but has no
handler for tree-file-to-bufferline. Not fatal (drop on pane body works)
but a discoverability gap; the tab strip looks like a natural target.

## Verifications (regression + priority + newly clean surfaces)

- **Workspace-header phantom icons** — FIXED (see P1).
- **Bufferline dirty active tab close click** — FIXED (see P5).
- **Bufferline hover-close on dirty inactive tab** — FIXED (see P4).
- **HTTP-panel MOCKS section verbs** — FIXED after fresh restart (see P6);
  see F4 for the stale-state regression path.
- **Tree drag-resize min-clamp at 16** — FIXED (see P7).
- **Split-divider double-click equalize** — PARTIAL (see F1); works when the
  cursor was on the divider before the click sequence, fails when the click
  arrives cold.
- **Toast hover pauses TTL** — round-12 pass still holds.
- **Right-click on divider** hover tooltip: shows `horizontal split divider /
  drag to resize · double-click to equalize`. Correct affordance advertised.
- **Tab drag between splits** — works: dragging pane 0's tab to pane 1's
  body collapses the split into a single leaf carrying both tabs. Side
  effect: the two tabs render with their workspace-prefixed titles
  (`round13-ws/api.http`) as the ambiguity-disambiguation kicks in even
  though both point to the SAME file; harmless but noisy.
- **Tab drag to activity bar mid-drag** — no crash, drag cancels cleanly.
- **Tab drag to own leaf** — no-op (as expected).
- **Alt+click multi-cursor** — verified in round-12; not re-probed.
- **Palette / tab / statusline / editor / gutter right-click menus** — all
  round-12 verifications still hold.
- **Dock widget kebab menu (⋮)** — comprehensive: Position (4 corners),
  Layout (Overlay / Inline), Opacity (Solid / Translucent), Rename…, Close.
- **`+ dock` left-click** — opens a Note 1 widget at Bottom-left (working).
- **`Shift+F10` context-menu-for-focused-element** — untested this round
  (keyboard chord).
- **Tree drag file to editor body** — opens as split, working.

## How mouse-discoverable does mnml feel this round

The priority sweep landed 5 of 8 items cleanly: workspace-header phantom
click, dirty-active close, hover-dirty-inactive close, tree min-clamp,
toast TTL. Two more are partially there: the MOCKS Save/Replay verbs work
until session state ages (F4), and the split-divider dbl-click works if
you hovered the divider first (F1). One is untouched: settings `/ filter`
row (F2).

The stubborn family across three rounds now is the same shape as before:
- **Rect-registered-but-not-in-the-user's-flow.** F3 (empty-state picker
  clicks that fall through commands that check `active_editor`), F4 (MOCKS
  items in code but not in render), F5 (dock chip has no rect at all for
  right-click).
- **Missing-affordance-parity.** F7 (six activities with 1-verb menus),
  F8 (empty-space RC), F9 (three split-strip chips missing RC), F10 (git
  toolbar with no hover / no RC) — these are all "menu that should have
  more than 0-1 verbs based on VS Code parity."
- **Asymmetric clamps + drag gaps.** F6 (tree edge max), F11 (tree-to-
  bufferline drag no-op).

Could I get my day's work done without a chord? For file editing, split
management (with a hover-first divider dbl-click), tab reorder, git panel
review, HTTP requests + mocks in a fresh session — yes. For filtering
Settings, discovering what git-toolbar glyphs do without memorizing,
right-clicking most activity-bar icons for more than one verb, or dropping
a file from the tree onto the tab strip — still no. The tooltip + menu
surface is dense in the parts of the app that shipped their round-1
polish; the parts that got the round-2 polish (git graph, dock chip,
settings filter row) are still short on it.
