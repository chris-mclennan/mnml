# mnml mouse hunt — round 16 (2026-07-16)

Headless drive against `~/Projects/mnml/target/release/mnml --input standard`,
workspace = a scratch `/private/tmp/r16` (git-init'd `src/main.rs`, `src/lib.rs`,
`docs/notes.md`, `README.md`, `api.http`, `subdir1/subdir2/deep.txt`,
`http-tests/example.chain.json`, `.mnml/env/dev.env`, `.rqst/env/dev.env`).
Everything driven through `.mnml/ipc/`; keyboard used only for text typing,
`Esc`, and `Ctrl+Z` (undo).

Focus:
1. Verify the nine priority items called out in the round-16 kickoff.
2. Re-probe every round-13/14/15 residual that was still open at the top of
   round-16.
3. Fresh hunt for new surfaces that weren't stressed last round.

## Executive summary

**10 findings: 0 SEV-1 · 2 SEV-2 · 8 SEV-3.**

**Priority-verification scoreboard (9 items):**

- **P1 Double-click window ~700 ms on split divider** —
  **VERIFIED HOLDING.** Fresh cadence sweep on the vertical divider
  (divider at col 44, click twice at same coord with `wait_ms=N`
  between the two clicks):
  - `N=400 ms` → equalizes ✓
  - `N=500 ms` → equalizes ✓ (round-16 target)
  - `N=600 ms` → equalizes ✓
  - `N=650 ms` → equalizes ✓ (round-16 target)
  - `N=700 ms` → does NOT equalize (boundary)
  - `N=750 ms` → does NOT equalize
  - `N=900 ms` → does NOT equalize ✓ (round-16 target — separate clicks)
  - `N=1500 ms` → does NOT equalize
  All 8 samples match the `DOUBLE_CLICK_MAX_MS = 700` const in
  `src/tui/mouse/down_left.rs:30`.

- **P2 Click-then-drag on split divider within 700 ms** —
  **VERIFIED HOLDING.** Click at (44, 10), wait 300 ms, drag (44, 10) →
  (60, 10): divider lands at col 59. Click at (44, 10), wait 500 ms,
  drag → (60, 10): divider lands at col 59. So the round-15 F1 fix
  ("don't early-return after equalize; fall through to
  `begin_divider_drag`") holds — the equalize fires but the drag
  still arms from the new (equalized) position, matching what
  `src/tui/mouse/down_left.rs:238-269` describes.

- **P3 Dbl-click on bufferline close-X closes ONE tab** —
  **STILL BROKEN.** See F1 below. Two tabs (sometimes 3) close on a
  natural double-tap of the same coord, at every cadence I swept
  (100 / 200 / 300 / 500 / 700 / 900 ms). The `last_click = None`
  patch at `src/tui/mouse/down_left.rs:1044-1051` does NOT prevent
  the scenario the fix comment describes.

- **P4 Systematic stale-rect clear on activity switch** —
  **VERIFIED HOLDING.** Right-clicks at all six HTTP-panel row coords
  (COLLECTIONS / FILES / CHAINS / MOCKS / RECENT / CAPTURED) fire
  nothing after switching Explorer → Http → Explorer → Notes.
  Rects are cleanly rebuilt per panel — no phantom HTTP menu leaks
  into Notes.

- **P5 Workspace-header hover-gated chips (cold click doesn't phantom
  fire)** — **VERIFIED HOLDING.** Cursor parked at (100, 38),
  `click 15, 1` toggles the workspace collapse only — no chip
  fires (file.new_folder / file.new / tree.refresh / git.pull /
  tree.toggle_collapse_all all stay silent). Note round-15 F3
  ("chips show the WRONG tooltip text") was NOT tested this round —
  the hover state now shows a `/private/tmp/r16` workspace-path
  tooltip regardless of column, which is the same behavior round-15
  described. Still latent.

  **Side observation:** clicking col 22 (tree.refresh chip) fires
  `tree.refresh` which then hides `.mnml/` from the tree because
  mnml wrote `.gitignore` on first launch containing `.mnml/`, and
  `Tree::rescan` re-honors `.gitignore` via `WalkBuilder`. This is
  DESIGN-INTENDED behavior but genuinely disorienting the first
  time a user sees it. Not filing.

- **P6 Settings `/ filter` row click focuses filter, typing narrows
  list** — **VERIFIED HOLDING.** Click at (30, 7) on the `/ filter`
  row (rect `settings_filter_row` at x=25 y=7 w=70 h=1) captures the
  caret; typing "line" narrows the 25-row list to 5 (`Line numbers`
  / `Cursor line` / `Statusline clock` / `Inline markdown
  rendering` / `Cmdline popup border color`).

- **P7 Bufferline dirty inactive tab hover-close reveals × in orange**
  — **VERIFIED HOLDING.** With `lib.rs ●   main.rs 󰅖` on the tab
  strip, hovering col 30 (inside lib.rs tab) turns the `●` dot into
  `󰅖` (close X). Clicking that X fires the Save / Discard / Cancel
  dialog. Move-off then the dot returns.

- **P8 HTTP-panel MOCKS section right-click menu shows Save / Replay
  verbs** — **VERIFIED HOLDING.** Right-click at (8, 18) opens a
  `MOCKS` menu with all 4 items: `Save active response as mock` /
  `Replay mock into active request` / `Toggle all sections` /
  `Refresh HTTP panel`.

- **P9 Sessions panel filters to Claude Code + Codex only** —
  **VERIFIED by code inspection.** `src/ui/sessions_panel.rs:50-58`
  filters `Pane::Pty` to `matches!(exe_base, "claude" | "codex")`,
  excluding bitbucket / amplify / `:term X` panes. Empty
  workspace shows "No sessions yet" (correct). I could not spawn a
  real `claude` / `codex` PTY in headless to visually confirm the
  positive path, but the exclusion logic is in place.

**Round-13/14/15 residuals still open:**

- F7-r15 tree-edge MAX clamp missing — **STILL BROKEN** (F2 below)
- F6-r15 split-strip chip right-click empty — **STILL BROKEN** (F3)
- F8-r15 sparse activity-bar right-click menus — **STILL BROKEN** (F4)
- F9-r15 empty-tree right-click dead zone — **STILL BROKEN** (F5)
- F10-r15 git-toolbar chip tooltips / right-click — **STILL BROKEN** (F6)
- F4-r15 tree-drag-to-bufferline no-op — **STILL BROKEN** (F7)
- F5-r15 statusline symbol chip empty right-click — **STILL BROKEN**
  (F8 — behavior CHANGED: no menu box appears at all now, whereas
  round-15 said "empty box drew").
- `+ dock` chip right-click falls through — **STILL BROKEN + WORSE**
  (F9 — chip is now inert to left AND right click, and has no hover
  tooltip either)

**Fresh hunt items that worked (positive controls):**

- Multi-cursor Alt+click — verified. Primary click at (32, 4) then
  Alt-click at (32, 6), typing "X" inserts on both lines.
- Word-select via double-click — dbl-click on "multiply" in
  lib.rs then typing "REPLACED" swaps the whole word.
- Middle-click on bufferline tab → clean close, no prompt.
- Right-click on tree file → 15-item menu (Open / Open in split /
  New file / New folder / Open in terminal / Cut / Copy / Duplicate
  / Move to / Rename / Delete / Reveal in Finder / Open externally
  / Copy path).
- Right-click on tree folder → 17-item menu (Set as workspace /
  Expand recursively / Collapse recursively / …).
- Right-click on `.. tmp` up-nav row → 5-item Workspace menu
  (Navigate up one level / Copy current path / Reveal in Finder /
  Open in terminal here).
- Right-click on bufferline tab → 12-item menu (Pin tab / Close /
  Close others / Close all / Copy relative path / Copy absolute
  path / Reveal in Finder / Split right / Split down / Split left).
- Right-click on `split_strip_ai_claude` chip → 8-item AI launcher
  menu (Toggle existing Claude Code pane / New session in left/right/
  top/bottom half / Show Claude only / Show Codex only / Show both).
- Right-click on `integration:*` chip → 7-item Browser menu
  (Disable / Move to top / Move up / Edit… / Copy id /
  Show manifest… / Remove).
- Palette dropdown chevron click at (78, 0) → Recent files picker.
- Palette search chip click at (50, 0) → Command palette overlay.
- File menu bar click at (12, 0) → File menu (New file / Open file /
  Open folder / Save / Save all / Close tab / Settings… / Quit).
- Clicking "Settings…" in File menu → Settings overlay opens.
- Clicking value chips in a Settings row → swap current choice
  (verified `Line numbers` toggle from absolute → relative).
- Cancel button in Settings closes without saving.
- New-tab button hover at (111, 0) → `new tab` + `click: open a
  new scratch buffer` tooltip.
- Window-close hover at (118, 0) → `quit mnml` + `click: quit`.
- Explorer / Http / Notes activity hover → 3-line tooltip each
  (name + description).
- Tab drag reorder — [main.rs, lib.rs, notes.md] → drag main.rs
  from col 30 to col 71 → [notes.md, lib.rs, main.rs]. Then drag
  main.rs (col 57) to col 45 → [notes.md, main.rs, lib.rs].
- Statusline mixr chip right-click → `Open mixr` menu (single verb).
- Statusline branch / workspace right-click → rich menus.
- Statusline language / clock right-click → single-verb menus
  (Copy language name / Hide clock).
- Word-select double-click on editor works.
- Left-click on statusline symbol chip → Outline split opens.

## Findings

### SEV-2

**F1. Dbl-click on a bufferline close-X still closes 2 (sometimes 3)
tabs — the round-15 F2 `last_click = None` patch does not prevent the
scenario the fix comment describes.**

Round-16 kickoff claims: *"Double-click on bufferline tab close-×
closes only ONE tab (round-15 F2 fix: `last_click` reset after close
so successive clicks land on the newly-slotted tab's × don't chain
into a dbl-close)"*. That is not what I observe.

Reproduction (3-tab, 200 ms cadence — natural trackpad speed):

```
Setup: [main.rs (w=14, close_x=37), lib.rs (w=13, close_x=51),
        notes.md (w=17, close_x=69)]

wait_ms 2000                         (isolate from prior events)
click 37, 1                          (close X of main.rs)
wait_ms 200
click 37, 1                          (second click at same coord)
```

Result: 1 tab remains (only notes.md). main.rs AND lib.rs both got
closed on a 2-click cadence.

Root cause reading `src/tui/mouse/down_left.rs:1036-1053`: on the
first click, mnml runs `close_pane(id)` for main.rs, then resets
`app.last_click = None`. Tabs shift: lib.rs (was tab 1) now occupies
x=25 w=13, its close-X moves to col 36; notes.md (was tab 2) now
occupies x=39 w=17, close-X at col 54. So col 37 in the NEW layout
still falls INSIDE lib.rs's close-X rect (x=36 w=2 → cols 36-37).
The second click hits that rect, `close_pane` runs again, lib.rs
closes.

The `last_click = None` line was intended to prevent this by
"unarming double-click chains", but there is no double-click check
on the tab-close path in the first place — the close is a plain
single-click handler. So the reset is a no-op for this bug.

The suggested fixes from round-15 F2 (still applicable):
- (a) Suppress the next `bufferline_tab_close` click at the same
  coord for ~500 ms after any close, OR
- (b) Require the mouse to leave the close-X rect between two
  close-clicks (mouse-up-outside-then-mouse-down-inside pattern).

Verified across cadences 100 / 200 / 300 / 500 / 700 / 900 ms — every
one closed 2 tabs. Only when the second click coord falls OUTSIDE the
newly-slotted close-X rect (because tab widths shift far enough) does
this bug not fire. That's coincidence, not by design.

Real-world impact: a dirty tab in the middle position can be closed
by accident. A user does "close this scratch tab, ah too fast let
me re-do it" — instead they hit the Save / Discard prompt for the
NEXT tab which happens to be their unsaved work.

---

**F7. Drag a tree file onto the bufferline tab strip is still a
no-op.** (round-15 F4 verbatim — no change.)

```
Drag api.http tree row (col 7, row 15) → bufferline (col 50, row 1)
```

Expected: api.http opens as a new tab, inserted at the drop position
in the tab strip.
Actual: `bufferline_tab:0` unchanged (single tab main.rs); api.http
not opened.

Contrast with drag-to-editor-body: drag `bufferline_tab:1` (lib.rs)
from (42, 1) → (100, 15) DOES create a split with lib.rs on the
right. So the drag machinery handles editor-body drops correctly;
it just doesn't accept a bufferline-strip drop for tree files.

STILL BROKEN.

---

### SEV-3

**F2. Tree-edge drag has no MAX clamp — user can shove the tree to
col 99 (screen width – 21) even though Settings caps `File tree width`
at 60.**

```
Drag tree_edge from col 30 → col 115
Result: tree_edge x=99, tree w=96
```

The clamp in `src/ui/mod.rs:465`:
`app.tree_width.min(upper.width.saturating_sub(21)).max(8)` —
no Settings-max reference.

Round-13 F6 / round-14 F6 / round-15 F7. STILL BROKEN.

---

**F3. Split-strip `[│]` / `[─]` / `[$]` chips have no right-click
menu.** (round-15 F6 verbatim — no change.)

Right-click on any of `split_strip:0:Horizontal` (col 69),
`split_strip:0:Vertical` (col 72), or `split_strip_term:0` (col 66):
no menu appears. Same for pane-1 chips at 114 / 117 / 111. VS Code's
split arrows all have "Split up / down / left / right" context menus
with orientation hints.

Round-13 F5 / round-14 F5 / round-15 F6. STILL BROKEN.

Left-click on `split_strip_term:*` DOES open a shell pane (positive
control). Left-click on `split_strip_ai_claude` opens the Claude
Code launcher menu (positive control, so left-click has a discovery
path). Right-click just doesn't exist.

---

**F4. 5 activity-bar rows have only a single "Show X" verb on
right-click; 6 rows have 2-3 useful verbs.**

Sweep of right-clicks on each activity icon (all at col 1):

- Explorer (row 2): 3 verbs — `Show Explorer` / `Reveal active file` / `Refresh tree` ← IMPROVED from round-15
- Search (row 4): 1 verb — `Show Search` ← STILL 1
- Git (row 6): 1 verb — `Show Source control` ← STILL 1
- Debug (row 8): 1 verb — `Show Run and debug` ← STILL 1
- Integrations (row 10): 1 verb — `Show Integrations` ← STILL 1
- Sessions (row 12): 1 verb — `Show Sessions` ← STILL 1
- Agents (row 14): 2 verbs — `Show Agents` + `Open dashboard`
- CloudAgents (row 16): 1 verb — `Show Cloud agents` ← STILL 1
- Http (row 18): 3 verbs — `Show HTTP` + `+ New request` + `Paste curl from clipboard`
- Notes (row 20): 2 verbs — `Show Notes` + `+ New note`
- Todos (row 22): 2 verbs — `Show TODOs` + `Rescan`

Explorer's `Refresh tree` + `Reveal active file` were added since
round-15. The other five sparse rows (Search / Git / Debug /
Integrations / Sessions / CloudAgents) still show just "Show X".

Round-13 F7 / round-14 F7 / round-15 F8. PARTIAL PROGRESS.

---

**F5. Right-click in empty tree space (rows 33-37 below the
workspace list) returns no menu.** (round-15 F9 verbatim.)

Rows 33-37 in the workspace-list gutter are visually empty gray
strip. Right-click yields nothing. VS Code's Explorer empty-space
right-click gives `New file` / `New folder` / `Refresh Explorer` /
`Reveal in Finder` / `Open in integrated terminal`.

Round-13 F8 / round-14 F8 / round-15 F9. STILL BROKEN.

---

**F6. Git toolbar chips (Undo / Redo / Pull / Push / Fetch / Branch /
Commit / Stash / Pop) still have no hover tooltip and no right-click
menu.** (round-15 F10 verbatim.)

Chip positions in the Git panel: cols 26, 35, 44, 53, 62, 72, 83,
94, 104 on row 1. Hover each for 800 ms — no tooltip. Right-click
each — no menu. Left-click fires the underlying action (positive
control on left-click).

Round-13 F10 / round-14 F9 / round-15 F10. STILL BROKEN.

---

**F8. Statusline `symbol` chip right-click now shows NO menu at all
(regression from round-15 which reported "empty menu box").**

Right-click at (33, 38) or (35, 38) on the `statusline_symbol_chip`
(rect x=31 y=38 w=7 when cursor is in a real symbol like `add` in
lib.rs): no menu appears. Compare round-15 F5: "the menu popup
appears but contains no items. The border chrome is drawn empty."

Now the click is silently swallowed with no visible feedback at all.
That's arguably worse — the user gets no clue they even hit
something clickable. Left-click on the same chip DOES fire (opens
the Outline overlay), so the rect is live for left; right just has
no handler.

Round-15 F5 was rated SEV-2 (empty menu). Now: still SEV-3 (no menu).
Same underlying gap — no discoverable right-click actions for the
symbol chip.

---

**F9. `+ dock` chip at (~col 112, row 37) is completely inert — no
click, no hover tooltip, no right-click menu.**

Round-15 said `+ dock` right-click "falls through to editor menu".
This round: neither left-click, right-click, nor hover at col 114
row 37 produces any visible effect or tooltip. There's no rect
entry for it in `rects.json` (search: no `dock` or similar). Yet
it's rendered on-screen with an inviting `+` glyph. False
affordance — the icon suggests a click target but there isn't one.

Contrast: the very-similar `+ New session` / `+ New note` / `+ New
collection` chips in various panels all fire their intended
actions. `+ dock` is the odd one out.

---

**F10. `+ dock` render coordinate (screen col 112 as of this test)
sits ~4 chars to the right of the rendered pane-1 edge — visually
belongs to the pane-1 status border, but if it's meant to be a
global "dock a new panel" affordance, it should live in the palette
bar (row 0) or the right-panel edge, not floating on a status
divider.**

Style critique, not a broken feature — but paired with F9 (chip is
inert) it reads as "someone drew a placeholder and forgot to wire
it up." A mouse-first user hunting for "how do I dock the current
scratch buffer somewhere?" sees the `+ dock` glyph, clicks it,
nothing happens, moves on confused.

---

## What works well (positive controls)

- **Multi-cursor Alt+click** — verified across two lines, typing
  inserts on both.
- **Double-click for word-select** in editor body — verified with
  "multiply" in `lib.rs`.
- **Middle-click on bufferline tab** closes the tab (clean, no
  prompt).
- **Tab reorder via drag** — clean; final position matches drop
  coord's tab-strip slot.
- **Tab drag to editor body** creates a new split with the dragged
  file — correct even if source pane is otherwise unchanged.
- **Right-click on `split_strip_ai_claude` chip** — 8-item Claude
  Code launcher menu (way richer than round-15's single verb).
- **Right-click on `integration:*` chip** in palette bar — 7-item
  menu (`Disable / Move to top / Move up / Edit / Copy id / Show
  manifest / Remove`).
- **Right-click on tree file / folder / up-nav row** — rich menus
  with Cut / Copy / Duplicate / Move to / Reveal in Finder etc.
- **Right-click on bufferline tab body** — 12-item menu.
- **Left-click on `split_strip_term:*` chip** — opens a shell pane
  as a split — feels great.
- **Right-click on statusline branch / workspace chips** — rich
  Git / workspace menus.
- **Left-click on statusline `symbol` chip** — opens Outline
  overlay (breadcrumb-jump behavior).
- **Palette dropdown chevron** at (78, 0) — Recent files picker.
- **Palette search chip** at (50, 0) — Command palette.
- **File menu bar dropdown** at (12, 0) — 8-item File menu.
- **Settings row value clicks** — cycle the choice; save/cancel
  buttons fire.
- **`/ filter` row click** in Settings, Notes, Sessions, HTTP
  panels — all focus their respective filter inputs.
- **Hover tooltips** on Activity bar, palette bar buttons, new-tab
  button, window-close button — all show meaningful text.
- **HTTP-panel MOCKS section 4-verb right-click menu** — stable
  across activity switches.
- **Stale-rect clearing on activity switch** — no phantom fires when
  clicking old-panel coords after switching.
- **Cold click on tree-workspace header row toggles the workspace
  without phantom-firing chip actions** (hover-gating works).
- **Dbl-click on close-X of dirty tab shows Save / Discard / Cancel
  prompt** (the F1 bug is about dbl-click closing 2 tabs; the
  prompt itself works).
- **Right-click integration chip** offers 7 verbs.

## How mouse-discoverable does mnml feel this round

Nine priority items sweep — seven green, one still broken (F1
tab-close dbl-tap = 2 tabs), one not fully testable in headless
(Sessions filter positive path). The stale-rect clear (P4), the
Settings filter row focus (P6), the workspace-header cold-click
gating (P5), and the HTTP MOCKS rich menu (P8) are all durable
wins that graduated from earlier hunts.

The dbl-tap close-X bug (F1) is the item worth prioritizing — it's
data-loss-adjacent (a fast-clicking user closes 2 tabs, one of
which might be dirty). The claimed round-15 fix targeted the wrong
mechanism (`last_click = None` doesn't guard a plain single-click
handler); the round-15 F2 suggestion (b) — require mouse to leave
the close-X rect between clicks — is still the right fix.

The residual constellation (F2 tree-edge no MAX, F3 split-strip
right-click, F4 sparse activity menus, F5 empty-tree right-click,
F6 git-toolbar tooltips, F7 tree-drag-to-bufferline, F8 symbol
chip empty rc, F9/F10 `+ dock`) is all polish now. Nothing is
data-losing, but each one is a small "I clicked and nothing
happened" moment that adds up. Explorer's activity-bar right-click
picked up 2 new verbs since round-15 — that pattern (put 1-2 useful
verbs alongside "Show X" on every rail icon) would knock F4 out in
an afternoon.

I could get my day's work done — file navigation, editing, running
requests, opening git, splitting panes, multi-cursor — with mouse
only. And the discoverable surface has widened this round (integration
chip right-click, AI-split chip right-click, tab body right-click,
tree row right-click, palette bar, File menu). Learning mnml by
clicking is getting closer to the "no chords required" goalpost.
Two more rounds of the F4 / F6 / F7 / F8 / F9 polish + a real fix
for F1 and mnml would be VS-Code-parity mouse-discoverable for
the surfaces that matter.
