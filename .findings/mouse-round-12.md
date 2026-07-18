# mnml mouse hunt — round 12 (2026-07-14)

Headless drive against `~/Projects/mnml/target/release/mnml --input standard`,
workspace = a scratch `round12-ws` (git-init'd `src/main.rs`, `src/lib.rs`,
`docs/notes.md`, `api.http`, `README.md`, `subdir1/subdir2/deep.txt`, `.mnml/env/dev.env`
with `TOKEN=abc123`). Everything driven through `.mnml/ipc/` — no keyboard except
`Esc` (dismissing dialogs) and one `/` (to prove keyboard-only path in settings
filter).

Focus:
1. Verify the six priority round-11 fixes.
2. Re-probe the two round-11 SEV-2s that were NOT in the fix batch (F3 phantom
   header icons, F5 toast TTL under rapid Moved).
3. Fresh hunt across hover tooltips, right-click coverage, drag-drop edges,
   wheel-scroll routing.

## Executive summary

**11 findings: 0 SEV-1 · 3 SEV-2 · 8 SEV-3.**

**Priority-verification scoreboard:** 4 of 6 items verified fixed. 1 confirmed
still broken. 1 partially confirmed (works at happy path, wrong hit-rect at
boundary).

- **F1 (Notes filter row → HTTP swap)**: FIXED. Verified across Notes / Todos /
  Sessions — clicking the `󰍉 / filter` row correctly focuses the filter and
  leaves the current activity intact.
- **F2 (HTTP-panel section-header right-click)**: FIXED. All seven headers
  (COLLECTIONS / FILES / ENVS / CHAINS / MOCKS / RECENT / CAPTURED) now open
  right-click menus with sensible verbs: "New X…", "Toggle all sections",
  "Refresh HTTP panel"; RECENT has "Clear recent history"; CAPTURED has
  "Start capture / Clear captured".
- **F3 (workspace-header phantom-fire on cols 15-30)**: STILL BROKEN. See
  F1-round12 below. The claim that "cols 15-24 fire icon commands" was accurate
  in round-11 and remains accurate — plus cols 27-30 (tree.toggle_collapse_all)
  and 24-26 (git.pull) also fire.
- **F4 (tree drag-resize min-clamp)**: FIXED on the narrow side (edge now clamps
  at x=16, matching config `file_tree_width` min). Max side is still unclamped —
  drag to col 80 lands at x=80 despite config max=60 (SEV-3 · F5-round12).
- **F5 (toast hover pauses TTL)**: FIXED. Fired toast, hovered center at
  700 ms intervals for 7 s of Moved events — toast survives. Move cursor away
  and it expires normally ~4 s later.
- **F6 (split-divider double-click equalizes)**: STILL BROKEN under both
  IPC-driven click pairs (50 ms, 150 ms gaps) and mouse_down/up quad sequences.
  Root cause visible in `src/tui/mouse/down_left.rs`: line 227
  `if app.begin_divider_drag(x, y) { return; }` runs BEFORE the double-click
  handler at line 2760, so the first click always starts a drag and the second
  click starts another drag — the "is this the second click of a pair?" test
  at line 2776 is never reached because the return at 227 short-circuits it.
  The fallback to `split_dividers` hit-test at line 2768 is dead code. See
  F2-round12.

- **Bufferline non-active tab close-× on hover + single click closes without
  activating**: FIXED. Verified with 3 tabs (`main.rs / lib.rs / notes.md`,
  notes.md active). Hover on lib.rs makes `󰅖` appear; single click on that
  ×  closes lib.rs and leaves notes.md active — no pre-activation flash.

- **Claude Code AI-chip right-click menu**: FIXED. Right-click on the
  `split_strip_ai_claude` chip opens a full launcher menu: "Toggle existing
  Claude Code pane", "New Claude Code session in left / right / top / bottom
  half", "✓ Show Claude only" / "Show Codex only" / "Show both" / "Hide these
  icons", "Edit Claude Code glyph…". Radio-style ✓ mark on the active option
  is a nice touch.

**Fresh findings dominated by three families.**

**(1) Left-click / right-click inconsistency on the workspace header (F1).**
The tree_toggle rect at cols 3-30 SHOULD own the whole row. But five
`tree_icon:*` rects (`file.new_folder`, `file.new`, `tree.refresh`, `git.pull`,
`tree.toggle_collapse_all`) at cols 15-30 shadow the last 15 cols and eat
LEFT-clicks — firing their mutation-y commands from cells that render as blank
padding unless the user hovers exactly on those cells. RIGHT-click on the same
cells falls through to `tree_toggle` and correctly opens the workspace menu.
Two different hit-rect orders for one visual row.

**(2) Split-divider double-click short-circuit (F2).** Round-11's fix added a
`split_dividers.iter().any(...)` fallback so IPC clicks without preceding hover
still count, but placed it at line 2760 — AFTER `begin_divider_drag` returns at
line 227. Result: the equalize path is unreachable under any input model. Since
this convention (dbl-click a divider to equalize) is the only "reset my splits"
mouse gesture that mnml advertises via its VS-Code lineage, it's a genuine gap.

**(3) Discoverability gaps in the Settings pane (F3-round12, F4-round12).**
Numeric-settings rows accept double-click-to-increment (I verified `Scrolloff`
went 0 → 2 on a double-click), but there is no visible affordance to hint that
click does anything different from focus, no right-click "Reset / Enter value…"
menu, and single click doesn't cycle. The `/ filter` placeholder row LOOKS like
an input but click doesn't focus it — only pressing `/` on the keyboard
activates it. Settings section headers (`── UI ──`, `── Editor ──`,
`── Integrations ──`, `── Reset ──`) still don't collapse on click (round-11
F11 residual).

## Findings

### SEV-2

**F1-round12. Workspace-header row hit-rect order — LEFT-click on cols 15-30
fires phantom icons; RIGHT-click on the same cells correctly opens the
workspace menu.**  (Also round-11 F3, unfixed.)
Steps: Explorer activity → hover cursor away (col 80, row 15). Click at
(col=15, row=1) → `New folder in /` prompt opens. Repeat with col=18 → `New
file in /` prompt. Col=21 → `tree.refresh` fires (introduces a `.rqst` folder
into the tree). Col=24 → `git.pull` (no visible change). Col=27 → collapse-all
fires (`▶` on every folder + workspace pinned indicator `󰪴` appears in header).
Reproducible at tree widths 24, 30, 50. RIGHT-click at (15, 1) instead opens
`round12-ws` workspace menu (Toggle expand / Expand recursively / Manage
workspaces / Set as default / etc.) — so the correct rect is registered, just
losing to the icon rects on left-click. The five `tree_icon:*` rects (visible
in `rects.json`) are always live even when the icons themselves only render
on hover. Discoverable via `python3 -c "import json; [print(r) for r in
json.load(open('.mnml/ipc/rects.json')) if r['label'].startswith('tree_icon:')]"`.

**F2-round12. Split-divider double-click does not equalize — the round-11 fix
is dead code.**
Steps: split editor via `split_strip:0:Horizontal` chip → divider settles at
col 75 (50/50). Drag from (75, 10) to (95, 10) → divider at col 89-93 (skewed).
Double-click at (89, 10) or (93, 10) with 50 / 100 / 150 ms gaps, with or
without prior hover. Also tried `mouse_down` / `mouse_up` quad sequences. In
every case: divider stays skewed; no equalize. Root cause: in
`src/tui/mouse/down_left.rs` the first hit-test on a divider is
`if app.begin_divider_drag(x, y) { return; }` at line 227. That starts a
one-click drag arm and returns. The fallback-plus-double-click check at line
2760-2789 is placed AFTER dozens of intervening handler blocks — including
that early return — and is never reached under any input path. `equalize_splits`
itself works fine when invoked via `run-command view.equalize_splits`. The fix
needs a "if `last_click` was on this same divider within 450 ms → equalize,
consume, don't arm-drag" gate INSIDE `begin_divider_drag` (or immediately
before line 227).

**F3-round12. Settings `/ filter` row click does not focus the filter — only
the `/` key on the keyboard activates it.**
Steps: `activity_bar_gear` click → Settings opens with `/ filter` placeholder
on row 7. Click at col=30, 40, 50 on the filter row — no focus change, no
cursor caret. Typing "Line" after the click sends each letter to the settings
list keyboard handler; because 'l' is bound to "cycle-right" on the focused
row, `Line numbers` cycles values instead of the filter capturing anything.
Only pressing the `/` key opens the filter (placeholder switches to `type to
filter…▏` with visible cursor). Mouse-first user has no path to filter the
25-row settings list.

### SEV-3

**F4-round12. Settings numeric rows: double-click increments but no visible
affordance advertises this — right-click gives nothing.**
Steps: Settings → single-click `[ 0 ]` for `Scrolloff` → focus (`▸`) moves to
that row but value stays 0. Double-click the same cell → value flips to `[ 2 ]`
and a `*` modified indicator appears. Also works on `Sidescrolloff`,
`File tree width`, `Theme` cells. There is no `-`/`+` glyph, no scroll-arrow
on hover, no tooltip hinting "double-click to change". Single-click users will
conclude the row is read-only. Right-click on the value cell produces no
context menu (would be a natural place for "Reset to default" / "Enter value…").

**F5-round12. Tree edge drag has no max-clamp.**
Steps: drag `tree_edge` from x=30 to x=80 (well past config `file_tree_width`
max=60). Result: edge lands at x=80, tree occupies half the screen, bufferline
+ editor scrunched. The min-side clamp landed in round-11 but the max side
never got one. Right-panel edge has the same asymmetry (round-11 verified min
side lacks clamp too).

**F6-round12. Six of eleven activity-bar right-click menus have only "Show X"
as their sole verb.**
Right-click on Search / Source control (Git) / Debug / Integrations / Sessions
/ Cloud agents opens a menu with a single entry. That's a menu with no menu.
The other five (Explorer, Agents, HTTP, Notes, TODOs) have 2-3 useful verbs
(Refresh tree, Reveal active file, + New request, Rescan, etc.). Bring the
sparse six up to that bar — e.g. Search could offer "Open recent search…" /
"Clear history"; Git could add "Fetch all", "Open commit graph"; Debug could
add "Set up debugger…" launch prompt.

**F7-round12. Right-click on empty tree space produces no menu.**
Steps: Explorer → right-click at (col=10, row=13) which is a blank gap between
`README.md` and the workspace integrations. Result: nothing. VS Code offers
`New file / New folder / Refresh Explorer / Open in Integrated Terminal` on
that click. mnml exposes those verbs only from folder rows.

**F8-round12. Split-strip `[│]`, `[─]`, and terminal `[$]` buttons have no
right-click menu.**
Hover shows the click tooltip ("split right / split down / open shell in
split"), left-click works. Right-click on any of the three produces nothing.
Natural verbs a user might expect: "Split with duplicate", "Split at 3:1
ratio", "Open new terminal in split" (vs re-use existing shell). Not fatal
but a discoverability shape gap.

**F9-round12. Git activity toolbar chips (Undo/Redo/Pull/Push/Fetch/Branch/
Commit/Stash/Pop) have no hover tooltips and no right-click menus.**
Steps: Git activity → hover at row 1 col 32 (`󰕌 Undo`), col 40 (`󰅢 Pull`),
col 55 (`󰑐 Fetch`), col 65 (`󰘬 Branch`). No tooltip appears at any of them
(800 ms hover). Right-click also silent. A user who doesn't know the Nerd
Font glyphs by heart cannot discover which chip does what. Compare against
the statusline chips which all have `click: X · right-click: Y` tooltips.

**F10-round12. Git left-panel section headers (`WORKTREES`, `LOCAL`) accept
neither hover tooltip nor right-click menu.**
Steps: Git activity → right-click at (10, 6) `▾ WORKTREES 1` header, at
(10, 9) `▾ LOCAL 1`. Result: no menu. Left-click collapses the section (good).
VS Code SCM offers a "…" (three-dot) menu at each section header with "Refresh
/ Sort by / Show inactive" etc.; here neither the header nor a chevron does.

**F11-round12. Dock widget subtitle promises `× to close` but there is no `×`
button — only the ⋮ menu → Close.**
The visible widget body says `Click × to close, or run 'dock.close_all' to
clear them all.`. Hovering the widget header — even the far right where a `×`
button conventionally sits (col 118 for a widget at x=76-119) — does not
reveal an ×. The only close paths are (a) right-click the `+ dock` chip
(which doesn't have a right-click menu either — see round-11 F13), (b) open
the ⋮ menu and click Close, (c) type `:dock.close_all`. The subtitle text is
lying about the ×.

**F12-round12. Dock-widget title stays "Dock widget #1 at BottomLeft" after
dragging to another quadrant.**
Steps: `+ dock` chip → widget appears bottom-left with the title text. Drag
the widget by its header from bottom-left to top-right (drop at 110, 10).
Widget re-anchors top-right but its body text still says "at BottomLeft".
Minor label-vs-state drift; the ⋮ menu's `Move to → ● Top-right` correctly
reflects the new anchor.

## Verifications (round-11 residuals + newer)

- **Menu-bar hover-switch** (round-11 pass): click File (12, 0) opens File
  menu; hover Edit (18, 0) switches to Edit (Find / Replace items visible).
- **Settings row focus vs value** (round-11 pass): click on Menu-bar row's
  LABEL moves focus; click on `[always]` cycles the tri-state. Numeric-row
  double-click increments now works (F4-round12 above).
- **Menu-bar Selection menu**: click Selection (25, 0) → Expand selection /
  Shrink selection / Add cursor above / Add cursor below / Add cursor at
  next match / Select all occurrences / Clear extra cursors.
- **Tab context menu**: right-click a tab shows Pin tab / Close / Close
  others / Close all / Copy relative path / Copy absolute path / Reveal in
  Finder / Split right / Split down / Split left / Split up.
- **Middle-click tab closes without prompt** (non-dirty) — confirmed.
- **Middle-click on dirty tab shows Save / Discard / Cancel** — button coords
  Save at col 44, Discard at col 54, Cancel at col 67; all click-hittable.
- **Alt+click multi-cursor**: click (col 39, row 2) then Alt+click (col 39,
  row 3) then type "XX" → two XX inserted (`pubXX` on line 1, `   XX a + b`
  on line 2). Works.
- **Tab drag-reorder**: `notes.md / main.rs / lib.rs` — drag notes.md from
  col 40 to col 78 → order becomes `lib.rs / main.rs / notes.md`. Drag back
  from 68 to 40 → notes.md returns to front.
- **Tab drag to editor-body creates split**: drag notes.md from bufferline
  (col 37, row 1) to left half of editor body (col 35, row 20) → left/right
  split with notes.md alone on the left.
- **`..` up-nav row right-click menu**: Navigate up one level / Copy current
  path / Reveal in Finder / Open in terminal here. (Round-11 F12 fixed.)
- **Tree row right-click menu**: comprehensive — Open / Open in split / New
  file / New folder / Open in terminal / Cut / Copy / Duplicate / Move to /
  Rename / Delete / Reveal in Finder / Open externally / Copy path.
- **Tree folder right-click menu**: adds Set as workspace / Expand recursively
  / Collapse recursively / Refresh tree on top of the file menu.
- **Tree drag-drop file into folder**: drag lib.rs (col 15, row 6) onto
  subdir1 (col 15, row 8) → `Move to subdir1/lib.rs?` confirm dialog.
- **Editor body right-click**: Cut / Copy / Paste / Undo / Redo / Select all /
  Go to definition / Find references / Hover info / Rename symbol… / Select
  all occurrences / Expand selection (LSP) / Toggle fold.
- **Gutter right-click**: Toggle breakpoint / Conditional breakpoint / Go to
  definition / Find references / Hover info / Peek change / Toggle blame /
  Open at remote (browse line).
- **`+ New tab` right-click**: New blank tab / Reopen last closed / Open
  recent / Open file.
- **Theme toggle right-click**: Theme: onedark / Pick theme… / Toggle
  (primary ↔ alt) / Reset to config default.
- **`activity_bar_gear` right-click**: Settings / Command Palette /
  Cheatsheet / Themes / About mnml.
- **Integration chip right-click**: `browser` chip → Disable (hide chip) /
  Move to top / Move up / Edit / Copy id / Show manifest / Remove.
- **Statusline chip tooltips**: mode (`click: toggle vim ⇄ standard · green =
  EDIT`), branch (`click: graph · + added` / `right-click: git ops menu`),
  mixr, LSP, clock, workspace, language — all seven show `click / right-click`
  affordance lines. Coverage complete.
- **Palette bar hover tooltips**: sidebar (`file tree: open · click: toggle
  file tree (Ctrl+B)`), back (`click: prev buffer (MRU) · 2 open · right-click:
  nav history menu`), forward (`click: next buffer (MRU) · 2 open`), search
  chip (`command palette · click: open files, commands, recent (Ctrl+P)`),
  dropdown chevron (`recent files · click: open recent · right-click: open
  menu`), right-panel button (`right panel: off · click: toggle right side
  panel (Ctrl+Shift+B)`), new-tab (`new tab · click: open a new scratch
  buffer`), theme-toggle (`theme: onedark · click: toggle between configured
  themes`), window-close (`quit mnml · click: quit`). All confirmed.
- **Bufferline right-side chips**: `split_strip_ai_claude` (`open new Claude
  Code session · click: spawn new session · right-click: menu`),
  `split_strip_term:0` (`open shell in split`), `split_strip:0:Horizontal`
  (`split right`), `split_strip:0:Vertical` (`split down`). Tooltips present;
  right-click empty (F8-round12 above).
- **Tab hover tooltip**: `notes.md ◳ · click: focus · middle: close · right:
  menu`. Complete.
- **Activity-bar icon tooltips**: all 11 have hover tooltips (Explorer /
  Search / Source control / Debug / Integrations / Sessions / Agents / Cloud
  agents / HTTP / Notes / TODOs). Confirmed with proper hover-away first.
- **Palette bar search chip click → palette overlay** with recents marked by
  `★`. (Round-11 F7's "no visual separator" is partially addressed — the
  `★` glyph now flags recent entries even if there's no `── RECENT ──`
  header.)
- **Palette wheel-scroll**: over overlay body scrolls the command list.
- **Palette click-to-run**: clicking a palette row executes the command +
  dismisses the overlay.
- **Tab-strip wheel scroll**: cycles tabs — verified 2 forward + 1 back.
- **Editor scrollbar drag**: drag from (119, 5) to (119, 30) jumps to line
  138; drag back to (119, 2) returns to line 1.
- **Editor wheel scroll**: 5 clicks down = ~5-line advance on a 200-line file.
- **Statusline / cmdline row wheel scroll**: no-op (safe).
- **Palette-bar / activity-bar wheel scroll**: no-op (safe).
- **100 rapid tab-switch clicks**: no lag, no crash, tabs cycle correctly.
- **Toast right-click at exact toast body coords (col 115, row 36)**: opens
  `Toast: <text>` menu with Dismiss this / Dismiss all / Copy text to clipboard.
- **`+ dock` chip left-click** toggles a Note-1 dock widget on/off (well —
  first click OPENS; a second click while the dock is visible does nothing;
  see round-11 F13 for the label-misleading complaint. Reproduced here.)

## How mouse-discoverable does mnml feel this round

Better again than round 11 — three of the four round-11 SEV-2 fixes stuck
(F1 filter row, F2 HTTP-panel section right-clicks, F4 tree min-clamp), plus
two of the fixes for gaps I hadn't reported in round-11 landed cleanly
(bufferline hover-close on non-active tabs + Claude Code chip full radio-menu).
The Alt+click multi-cursor / gutter right-click / editor symbol right-click
suite is genuinely strong now — a VS-Code refugee would recognize every
verb and every gesture, and the tooltips over statusline chips explicitly
document the click and right-click affordances.

The remaining SEV-2s cluster around two shapes:
1. **Hit-rect ordering vs render order.** The workspace-header phantom-icon
   click and the split-divider dead double-click both come from the same
   family — sub-rects that render only on hover but always own the click,
   plus a broader rect that only gets the click if nothing narrower matches.
   Fixing these means auditing every `if app.rects.X.iter().any(...)`
   short-circuit for "does this rect claim the click when its glyph isn't
   painted?".
2. **Discoverability at the settings pane.** Numeric-rows are click-editable
   via double-click but the affordance is invisible; the filter row LOOKS
   like an input but ignores clicks; section headers don't collapse. The v1
   discrete-choice contract is honored but the surface around it feels
   patchy for anyone who never opens the ex-command palette.

Could I get my day's work done without a chord? For editing, splitting,
tab-management, HTTP requests, git panel navigation, and toast handling —
yes, and now the tooltip surface is dense enough that I don't have to guess.
For adjusting Scrolloff via mouse, filtering settings, or equalizing my
splits after a mis-drag — no, I'd hit F2-round12 (dead dblclick), F3-round12
(dead click), or F4-round12 (silent value cell) and either learn a chord
or live with the wrong ratio.
