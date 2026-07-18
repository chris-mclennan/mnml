# mnml mouse hunt — round 15 (2026-07-15)

Headless drive against `~/Projects/mnml/target/release/mnml --input standard`,
workspace = a scratch `round15-ws` (git-init'd `src/main.rs`, `src/lib.rs`,
`docs/notes.md`, `README.md`, `api.http`, `subdir1/subdir2/deep.txt`,
`http-tests/example.chain.json`, `.mnml/env/dev.env`, `.rqst/env/dev.env`).
Everything driven through `.mnml/ipc/`; keyboard used only for text typing and `Esc`.

Focus:
1. Verify the five priority items called out in the round-15 kickoff.
2. Fresh hunt: split-divider click-then-drag boundary, tab dbl-click semantics,
   right-click-while-menu-open, drag from tree to bufferline.
3. Re-probe the round-13/14 residuals.

## Executive summary

**11 findings: 0 SEV-1 · 6 SEV-2 · 5 SEV-3.**

**Priority-verification scoreboard (5 items):**

- **P1 Split-divider dbl-click at 500 ms / 650 ms / 900 ms cadences** —
  **VERIFIED partially.** Threshold sweep on the shared vertical divider
  (divider drag → col 50, then two clicks at same coord with wall delay `d`
  between):
  - `d=500 ms` → equalizes ✓ (was failing at 350+ per round-14 F1)
  - `d=550 ms` → equalizes ✓
  - `d=600 ms` → equalizes ✓
  - `d=650 ms` → equalizes ✓
  - `d=700 ms` → does NOT equalize (right at the boundary)
  - `d=900 ms` → does NOT equalize ✓ (separate clicks, expected)

  So the window really is ~700 ms in headless. The regression on round-14 F1
  is genuinely fixed. See F1 below for the side-effect that came with it.

- **P2 Settings `/ filter` row click focuses filter, typing narrows list**
  — **VERIFIED FIXED.** Click at (25, 7) on the `/ filter` row (rect
  `settings_filter_row` at x=25 y=7 w=70 h=1) turns off the placeholder
  and captures the caret. Typing "line" narrows the 25-row list to
  5 (`Line numbers` / `Cursor line` / `Statusline clock` / `Inline
  markdown rendering` / `Cmdline popup border color`).

- **P3 Workspace-header hover-gated chips (cold click doesn't phantom-fire)**
  — **VERIFIED HOLDING.** Cursor pre-set at (100, 30), then `click 15, 1`:
  the workspace collapses/expands (tree_toggle fires). No phantom
  file.new_folder / file.new / tree.refresh chip actions ever fire from
  a cold click.

  **BUT** hover-gated chip clicks land — and their tooltips are wrong.
  See F3 below.

- **P4 Bufferline dirty inactive tab hover-close (× reveals on hover,
  click closes)** — **VERIFIED partial.**
  - Cursor far → `main.rs ●` (dirty dot), cursor hovering tab → `main.rs 󰅖`
    (close X). Reveal works.
  - Click on the X at (57, 1) fires the Save/Discard/Cancel prompt for
    the dirty tab. Verified.
  - **NEW SIDE-EFFECT**: dbl-click on the close-X closes the tab AND
    the next tab that flows into the vacated slot. See F2 below.

- **P5 HTTP-panel MOCKS section right-click shows Save / Replay verbs**
  — **VERIFIED HOLDING.** Right-click at (8, 18) on `▼ MOCKS (0)` opens
  a menu titled "MOCKS" with all 4 items: `Save active response as mock`
  / `Replay mock into active request` / `Toggle all sections` /
  `Refresh HTTP panel`. Stable across multiple activity switches.

**Fresh hunt scoreboard (4 new items):**

- **Split-divider click-then-drag within 700 ms** — **BROKEN.** See F1.
- **Tab bar dbl-click on close-X** — **BROKEN.** Closes 2 tabs. See F2.
- **Tab bar dbl-click on tab body** — inactive: single click switches +
  second click no-op (acceptable). Active: no-op both times (fine, but
  no rename / no pin — see F11).
- **Right-click while a context menu is open** — **WORKS.** The second
  right-click dismisses the first menu and opens a new one at the new
  coord. Verified on tree-file → tree-file transition (`.gitignore` →
  `main.rs`) and on ENV file → MOCKS section transition.
- **Drag from tree file to bufferline** — **PARTIALLY BROKEN.** Drag
  api.http → editor body opens the file (in a new split). Drag → bufferline
  strip is a no-op. See F4.

**Round-13/14 residuals (regression check):**
- F1-round14 divider cold dbl-click threshold (300–350 ms wall) — **FIXED**
  by moving window to ~700 ms; new side-effect F1 introduced.
- F2-round14 settings `/filter` row click — still FIXED.
- F5-round14 split-strip `[│]/[─]/[$]` right-click — **STILL BROKEN**
  (see F6 below). No menu on right-click any of the three chips.
- F6-round14 tree edge MAX clamp — **STILL BROKEN**. Drag tree_edge
  from col 30 → col 200 lands at col 99 (screen edge minus 21 buffer),
  well past the configured 60-col max. See F7.
- F7-round14 activity-bar right-click menus — **STILL BROKEN**. 5 rows
  show only "Show X" as a single verb. See F8.
- F8-round14 empty-tree-space right-click — **STILL BROKEN.** Rows below
  the last workspace listing (rows 35+) return no menu on right-click.
  See F9.
- F9-round14 git toolbar chips missing tooltips + right-click — **STILL
  BROKEN.** None of the 9 chips (`󰕌 Undo` / `󰑎 Redo` / `󰅢 Pull` /
  `󰅦 Push` / `󰑐 Fetch` / `󰘬 Branch` / `󰄬 Commit` / `󰇚 Stash` / `󰇛 Pop`)
  show any hover tooltip. Right-click on any of them: no menu. See F10.
- F10-round14 tree drag-to-bufferline no-op — **STILL BROKEN.** Confirmed
  F4 below.
- F4-round14 close-prompt races — dismissed hover before click still
  requires care to hit the X (partial).

## Findings

### SEV-2

**F1. Split-divider click-then-drag within the 700 ms dbl-click window
converts the drag's initial mouse-down into a dbl-click, firing equalize
instead of moving the divider.**

The extended 700 ms window (raised from 450) improves cold dbl-click
reliability but introduces a new failure mode. The drag command
synthesizes `Down(left) → Drag(left, per step) → Up(left)`. If the
`Down(left)` at coord `(c, r)` lands within 700 ms of a prior click at
the same coord, the code treats it as the 2nd click of a dbl-click and
fires the divider-equalize command BEFORE the drag steps are consumed.
Once equalized, the drag no longer targets the divider (which has moved
to the center), so the intended drag is lost.

Steps to reproduce:

```
{"cmd":"drag","from_col":75,"from_row":10,"col":45,"row":10}  → imbalance to col 44
{"cmd":"click","col":44,"row":10}                              → single click on divider
{"cmd":"wait_ms","ms":300}                                     → within 700 ms
{"cmd":"drag","from_col":44,"from_row":10,"col":25,"row":10}   → drag left toward col 25
```

Expected: divider ends near col 25 (drag succeeded).
Actual: divider ends at col 75 (equalized).

Contrast with `wait_ms:1000` between click and drag:
- Divider moved from col 53 → col 39 (drag succeeded, target 30).

Real-world impact: a VS Code habit is "click a splitter to place focus,
then drag to fine-tune width." That pattern is now hijacked by equalize
across the entire 700 ms window. The two workarounds — wait longer than
700 ms between click and drag, or click somewhere else first — are both
non-obvious.

Suggested fix: gate the dbl-click detection on "the second event is
Click (Down+Up in place), not Drag." A `Down(left)` immediately followed
by `Drag(left)` (delta > 0 within some ms) should cancel the pending
dbl-click and start a drag.

---

**F2. Dbl-click (or triple-click) on a bufferline tab close-X closes
multiple tabs — each click closes whichever tab currently occupies that
slot.**

The close-X coord for `bufferline_tab:0` is at a fixed cell (e.g.,
col 37 for a 12-char tab title). When the first tab closes, the second
tab flows into slot 0, and its close-X registers at the same coord.
A second click at the original coord (from a natural dbl-click cadence)
hits the new close-X and closes the second tab too.

Steps to reproduce:

```
Open main.rs and lib.rs (2 clean tabs).
bufferline_tab_close for tab:0 sits at col 37.
{"cmd":"click","col":37,"row":1}                          → main.rs closes
{"cmd":"wait_ms","ms":100..500}                           → close-X for lib.rs now at col 37
{"cmd":"click","col":37,"row":1}                          → lib.rs also closes
```

Result: `panes: []` (both closed from 2 clicks).

Extended to 3 tabs + triple-click at same coord: 3 tabs close.

Real-world impact: a slightly hurried user who clicks close-X twice
(because the first click seemed to lag, or they double-tapped instinctively)
loses the wrong tab. This is data-loss-adjacent on clean tabs (recoverable
via `:e`) but genuinely destructive on dirty ones — my dbl-click hit the
Save/Discard/Cancel prompt for the second tab after the first tab closed.

Suggested fix: after a bufferline_tab_close click, either (a) suppress
the next `bufferline_tab_close` click at the same coord for ~500 ms, or
(b) require the mouse to leave the close-X rect between clicks (which
happens naturally because the tab shifts and the layout redraws).

---

**F3. Tree-workspace-header hover-revealed action chips show the WRONG
tooltip text.**

The hover-gated chips at cols 15–29 on row 1 (`file.new_folder`,
`file.new`, `tree.refresh`, `git.pull`, `tree.toggle_collapse_all`)
all show the wrong tooltip on hover:

- Cold state (Explorer, no prior HTTP visit):
  hover any chip col (16, 19, 22, 25, 28) → tooltip reads
  `/private/tmp/round15-ws` (the workspace-path tooltip from the
  underlying `tree_toggle` rect). The chip-specific tooltip
  ("new folder" / "new file" / "refresh tree" / "pull" / "collapse all")
  never appears.

- After HTTP → Explorer transition (open HTTP activity, then click
  Explorer activity):
  hover col 25 → tooltip reads
  `HTTP: rescan collections / files / envs / captured log` (belongs
  to the HTTP panel's rescan chip, NOT to `git.pull`).
  hover col 28 → tooltip reads
  `HTTP: collapse / expand all sidebar sections` (belongs to
  HTTP's collapse chip, NOT to `tree.toggle_collapse_all`).

The click behavior itself is correct — clicking col 25 in Explorer
does fire `git.pull` (I confirmed via events + `git.pull` toast). It's
purely the tooltip lookup that's wrong. Users get confusing hover
information ("wait, why is my file tree telling me about HTTP?").

Suggested fix: the tooltip lookup for chips 4 and 5 in the tree header
appears to key off panel-agnostic chip index rather than the current
panel context. Rebuild the tooltip map per-panel on activity change,
or key it by chip label rather than position/index.

---

**F4. Drag a tree file onto the bufferline tab strip is a no-op —
should open the file as a new tab (VS Code convention).**

Steps:

```
{"cmd":"drag","from_col":15,"from_row":15,"col":80,"row":1}
```

Expected: api.http opens as a new tab, inserted at the drop position
in the tab strip.
Actual: no change; panes unchanged.

Confusingly, drag to the editor BODY (row 10) does something — it opens
the file in a NEW SPLIT beside/below the existing pane. So the drag
handler is aware of tree files and can open them; it just refuses when
the drop target is the bufferline (row 1 of any pane).

Suggested fix: route drop-on-bufferline the same as drop-on-body,
except open the file as a new tab in the existing pane rather than
splitting.

---

**F5. Statusline "Symbol" chip right-click returns an empty menu.**

Right-click at col 42 (in `statusline_symbol_chip`, x=39 w=11) with the
cursor sitting on a symbol like `it_adds` in lib.rs: the menu popup
appears but contains no items. The border chrome is drawn empty. This
is worse than "no menu" — the user sees a box, expects options, and
finds nothing.

Contrast: `statusline_mixr_chip` right-click shows `Open mixr` (single
verb); `statusline_lsp_chip` shows a 4+ item LSP menu. The Symbol chip
should at minimum show `Jump to symbol` / `Copy symbol name` /
`Find references`.

---

**F6. Split-strip `[│]` / `[─]` / `[$]` chips have no right-click menu.**

Right-click on any of `split_strip:*:Horizontal` (col 114),
`split_strip:*:Vertical` (col 117), or `split_strip_term:*` (col 111):
nothing appears. VS Code's split arrows all have "Split up / down /
left / right" context menus with orientation hints. mnml's chips have
only their single left-click action.

This is round-13 F5 / round-14 F5. STILL BROKEN.

---

### SEV-3

**F7. Tree-edge drag has no MAX clamp — user can shove the tree to
col 99 (screen width – 21) even though Settings caps `File tree width`
at 60.**

Steps:

```
{"cmd":"drag","from_col":30,"from_row":10,"col":115,"row":10}
```

Result: `tree_edge` rect updates to x=99 (out to the last-reasonable
column, but past the Settings max of 60). Trying to drag beyond col 120
(off-screen) also caps at col 99. So there's SOME clamp (screen width
– constant), but the Settings-configured max is ignored.

Round-13 F6 / round-14 F6. STILL BROKEN.

---

**F8. 5 activity-bar rows have only a single "Show X" verb on
right-click.**

Sweep of right-clicks on each activity icon (row 4, 6, 8, 10, 12, 14,
16, 18, 20, 22):

- Search (row 4): `Show Search`  ← 1 verb
- Source control (row 6): `Show Source control`  ← 1 verb
- Run and debug (row 8): `Show Run and debug`  ← 1 verb
- Integrations (row 10): `Show Integrations`  ← 1 verb
- Sessions (row 12): `Show Sessions`  ← 1 verb
- Agents (row 14): `Show Agents` + `Open dashboard`
- Cloud agents (row 16): `Show Cloud agents`  ← 1 verb
- HTTP (row 18): `Show HTTP` + `+ New request` + `Paste curl from clipboard`
- Notes (row 20): `Show Notes` + `+ New note`
- TODOs (row 22): `Show TODOs` + `Rescan`

Single-verb menus feel broken. VS Code sidebar icons all give at least
a "Show", "Reveal in Explorer", "Search all files" style short list.

Round-13 F7 / round-14 F7. STILL BROKEN.

---

**F9. Right-click in empty tree space below the workspace list returns
no menu.**

At rows 35+ (below `mnml` workspace toggle, above the activity-bar
gear at row 36), right-click yields nothing. A user trying to
"right-click into an empty area to add a workspace or refresh" hits a
dead zone. VS Code's Explorer empty-space right-click gives
`New file` / `New folder` / `Refresh Explorer` / `Reveal in Finder` /
`Open in integrated terminal`.

Round-13 F8 / round-14 F8. STILL BROKEN.

---

**F10. Git toolbar chips (Undo / Redo / Pull / Push / Fetch / Branch /
Commit / Stash / Pop) have no hover tooltip and no right-click menu.**

Hovering each glyph (cols 26, 35, 44, 53, 62, 72, 83, 94, 104) for
800 ms surfaces nothing. Right-click on each: no menu. Left-click
fires the underlying action.

Real-world impact: the row is Nerd-Font-only glyphs; a new user
looking at `󰅢 Pull │ 󰅦 Push` has no visual way to remember which is
which. VS Code's git panel has tooltips on every icon.

Round-13 F10 / round-14 F9. STILL BROKEN.

---

**F11. Bufferline tab dbl-click on the tab body does nothing — no pin,
no rename, no split.**

- Dbl-click on the ACTIVE tab body: no-op both clicks.
- Dbl-click on an INACTIVE tab body: first click switches to it,
  second click is a no-op.

VS Code convention:
- Dbl-click on a preview tab → converts to a pinned tab
- Dbl-click on any tab → sometimes "open beside" (varies)

mnml's tab strip doesn't distinguish preview vs pinned in the UI, so
"convert to pinned" may not apply. But the absent action leaves a
common gesture returning nothing at all — feels broken to a
VS-Code-conditioned user. A `dbl-click → rename` fallback (matching
finder / most tab strips) would be reasonable and discoverable.

---

## What works well (positive controls)

- **HTTP-panel MOCKS 4-verb right-click menu** — stable across multiple
  activity switches (fresh + aged sessions).
- **Right-click while a menu is open** — correctly dismisses the old
  menu and opens a new one at the new coord.
- **Statusline chip right-click menus** — most are useful and
  correctly-attributed: `mode` / `branch` / `file` / `mixr` / `lsp` /
  `filesize` / `lncol` / `clock` / `workspace` / `language` all fire
  the right menu. (Symbol is empty — F5; mixr is single-verb.)
- **Alt+click multi-cursor** — verified: primary click at line 24 col 11,
  Alt+click at line 28 → typing "X" inserts on both lines.
- **Middle-click bufferline tab** — closes clean tab silently, dirty
  tab surfaces Save/Discard/Cancel prompt.
- **Nested tree navigation** — click a folder row expands/collapses;
  click a nested file (e.g., `subdir1/subdir2/deep.txt`) opens it.
- **Palette dropdown chevron** — click at (78, 0) opens the recent-files
  picker.
- **Palette back/forward** — verified: forward re-focuses previously-open
  file after a back.
- **Scroll wheel on editor body** — scrolls the editor.
- **Rapid clicks (100)** — no crash, no lag.
- **Tree-workspace-header cold click** — no phantom chip fire (P3
  hover-gating holds).

## How mouse-discoverable does mnml feel this round

The 700 ms dbl-click window fixes the biggest cold-dbl-click friction
(round-14 F1), and the settings filter row is stable — those are wins.
But the extended window opened one regression (F1 click-then-drag → equalize)
and left one unrelated hazard (F2 dbl-click-on-close-X closes 2 tabs).
Both are the kind of thing a mouse-first user will hit within their first
hour: the first because clicking a splitter then dragging is a natural
"place-then-adjust" gesture; the second because "clicked too fast on the
X" is a universal trackpad experience.

The three big discoverability families from rounds 13/14 are all still
open:
- **Git toolbar** has 9 Nerd-Font glyphs with no tooltips and no
  right-click menu (F10). Learning them requires memorizing icon shapes.
- **Activity-bar rows** — half of them have a single "Show X" verb
  (F8). Feels like right-click did nothing.
- **Tree-header hover chips show the wrong tooltip** (F3). Hover
  says workspace path, click does file-new-folder. A user hovering
  to learn what chips do is actively misled.
- **Empty-tree right-click dead zone** (F9) and **split-strip
  right-click dead zone** (F6) remain.

I could get my day's work done — file navigation, editing,
running requests, opening git — with mouse only. But every time I
try to explore a new region ("what's this chip do?"), the answer
is "hover: workspace path; click: something else entirely."
mnml is now polished-enough for a mouse-first user to survive; it's
not yet polished-enough for one to LEARN it by clicking.
