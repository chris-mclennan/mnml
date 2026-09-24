# The UI spec

`rust-120x40.txt` is the Rust editor's screen — every cell, glyphs
included — on the fixture workspace with the author's real config, at
120×40, after the first-run overlay is dismissed. It is what mnml-zig
must look like. `rust-80x24.txt` is the same screen at 80×24 — the
statusline's overflow rule (the branch chip clipped to `main …`). Both
are embedded into the test binary (`build.zig`, `ui_spec_rust_*`) so
the statusline tests compare the painted row with the spec's. Colours are not in the dump; for those the Rust source
under `src/ui/` is the reference, and a side-by-side screenshot in
ghostty is the final check.

Regenerate and compare with `tools/ui-diff.sh WS RS_DATA ZIG_DATA
STEPS` (see the script header). Out of scope until the Zig integrations
exist: the pinned integration launcher icons in the rail and palette
bar. Cut: the Sonos chip. The now-playing cluster (`󱼀 󰐎` left of WRAP)
is painted in its idle form headless, as every Rust dump shows it;
`MNML_NOW_PLAYING` (see `src/app/now_playing.zig`) puts a track there.

Glyphs are codepoints, not looks. The author's ghostty runs
`font-family = JetBrainsMono Nerd Font` with `font-codepoint-map =
U+F1B00-U+F20FF=MnmlSymbols` (mnml's own baked glyphs: integration
chips, spinners, the claude/codex marks, tree connectors). Paint the
exact codepoint the Rust painter uses — never a lookalike from another
Nerd Font family — and put nothing in U+F1B00–U+F20FF the Rust side does
not already bake (`mnml/assets/glyphs/`, the Rust glyph tables), or it
renders as a box.

`zig-bottom-dock-120x40.txt` / `zig-bottom-dock-80x24.txt` are the
bottom dock with its default section, the diagnostics
(`tools/zig-spec.sh bottom-dock`, `steps-bottom-dock.jsonl`): the `─`
divider across the frame, the section's caps header with its `sort:`
chip and the `×` that hides the dock, and the columns above it short by
the dock's rows. There is nothing to diff against — the Rust bottom
panel was never driven for a spec, and it is absent from every
`rust-*.txt` here (it is carved only while it is open), so no existing
dump changed when the dock landed. The DIAGNOSTICS section moved from
the right column into it; no dump carried that section either. The
geometry itself is pinned by the unit tests in `src/app/side.zig`
(80×24 / 120×40 / 200×60).

Same look, Zig internals: the Rust modules are a behaviour reference,
not a template. Build on the component system (`Ui`, `HitMap`,
`Canvas`, `ListPanel`), register every click target in the same
statement that paints it, and add nothing the Rust screen does not show.

`zig-launcher-dock-left-auto-120x40.txt` is the side-band shape —
// changed (side-band, 2026-09-21): a LEFT dock in the shipped
`auto_hide` mode with the strip DOWN (`tools/zig-spec.sh
launcher-dock-left-auto`, `steps-launcher-dock-left-auto.jsonl`, which
only runs `view.dock_move`). The dock's three columns are reserved
whether the strip is up or down, so columns 0-2 are empty ground with
the `⋮` grip in the middle one — column 1, where the strip's own item
glyphs paint — and the activity bar starts at column 3, its icons on
column 4. Before this the band was one column in name and none in
fact: the rail painted from column 0, the grip's three-row run sat on
its icons, and revealing the strip painted the rail out of existence
(`docs/PARITY.md`, the edge-grip row).

`zig-launcher-dock-120x40.txt` / `zig-launcher-dock-left-120x40.txt`
are the LAUNCHER dock — `ui.dock`, macOS's Dock, not the bottom panel
and not the dock widgets — in `always` mode at each of its three shapes
(`tools/zig-spec.sh launcher-dock` / `launcher-dock-left` /
`launcher-dock-outer`, `steps-launcher-dock*.jsonl`, which cycle
`view.dock_cycle_mode` twice from the shipped `auto_hide` to `always`
and then, for the second dump, `view.dock_move` once — and, for the
third, run `:dock outer` before the cycle). On the **bottom** edge it is the EDITOR AREA's
last row — row 37 at 120x40, above the statusline on 38 and the `:`
line on 39, which is `ui.dock.placement = .inner`, the default
(// changed (dock-placement): the edge-grip pass had put it on the
screen's last row under the `:` line; `zig-launcher-dock-outer-120x40.txt`,
`tools/zig-spec.sh launcher-dock-outer`, is that shape now, and it is
opt-in) — reading `  Browser  󲀀 New terminal` with the 󰐃 pin chip at the far
end: the enabled integration chips first (only the browser globe is on
out of the box), then the terminals. On the **left** edge it is the
frame's outermost three columns, glyph-only, one item per row starting
at row 1, with the activity bar pushed in behind it and the pin chip on
the strip's last row — the outer-band rule (`app/hover_zones.zig`), the
same reason a side dock pushes an auto-hiding column's reveal edge one
cell inwards. There is nothing to diff against: Rust has no such
surface, and no `rust-*.txt` here changed, since an `auto_hide` dock —
the shipped default — draws nothing until the pointer asks for it.

`zig-usage-120x40.txt` / `zig-usage-80x24.txt` / `zig-usage-codex-120x40.txt`
are the usage panes (`tools/zig-spec.sh usage` / `usage-codex`), cut on
`usage-fixture/` — three synthetic accounts, a fixed clock and a UTC
zone through `MNML_CLAUDE_USAGE_FIXTURE` (`env-usage`), so the dump
never touches the wire and the reset clocks read the same on every
machine. The Rust pane was never driven for a spec; the layout is
`claude_usage_view.rs` / `codex_usage_view.rs` read against these.

*// changed 2026-09-22 (narrow):* every `zig-*-80x24.txt` was re-cut
(`zig-usage`, `zig-git-palette`, `zig-bottom-dock`, `zig-debug-stopped`):
an 80-column terminal is under `ui.sidebar_auto_below` (100), so the
`always` column reads as `auto` — no tree, no activity bar, the `⋮`
grip at each screen edge, the panes the whole width. And
`zig-usage-{80x24,120x40}`, `zig-git-palette-{80x24,120x40,all-120x40}`
and `zig-sessions-table-120x40` lost their `▌▌`: a row's own stripe
(an account's gutter, a lane, a session's accent) is in the pane
rail's column now and the cell after it is blank
(`pane_rail.absorb`). The GIT panel is therefore not in
`zig-git-palette-80x24.txt` any more — at 80 columns the column is
down until something asks for it; the 120-column dumps are the panel's
spec. The other lines those files moved on are the clock, the stress
meter, the graph detail's age, and the launcher dock's `⋯` grip on the
last row, which main already paints; the git dumps were cut under
`TZ=UTC`, as their dates always were. Against `rust-80x24.txt` this is
a deliberate departure — the Rust columns dock at any width — so
`tools/ui-diff.sh … "" 80x24` on the chrome fixture reads 44 differing
lines (22 rows beyond the rail) where it read 20 (4): the tree and the
activity bar are not on the Zig screen. At 120x40 nothing grew, and
`steps-esc` / `steps-graph2` / `steps-http` each lost a row (the `▌▌`).
*// changed 2026-09-23:* the sessions table had NOT lost them — its row
stripe sits past the list's marker column, where `absorb` does not look,
so the dump read `▌ ▌` on every row and `▌▌` on the selected one.
`pane_rail.absorbList` takes it now, and `zig-sessions-table-120x40.txt`
was re-cut (it had also been cut over a second run's rows).

`rust-git-120x40.txt` / `rust-git-80x24.txt` are git mode (`steps-graph2.jsonl`).

`zig-search-120x40.txt` is the SEARCH section (`steps-search.jsonl`
through `tools/zig-spec-git.sh search` — the branches fixture's repo,
the query `t`, the cursor on the first hit): Rust's
`draw_search_section` shape row for row — the header with the
`Aa \b .*` flags, the query pill `󰍉 t`, a blank row,
`2 hits (git grep)`, a blank row, the file header, `  2:1  two`.
*// changed 2026-09-15 (panel-consistency):* the query was the THIRD
row with the blank above it, painted as a bare ` / t█` run of the
section's own; it is `ui/filter_input.zig`'s pill on the second row
now — the grey band, the blue magnify glyph, `/ search` as the
placeholder — the shape every other left section has. The Rust side has no dump of its
own; the walkthrough's `docs/ui-spec/walk/steps-search.jsonl` on the
chrome fixture is the comparison (`rg` off the PATH, so both sides
answer with `git grep`): `tools/ui-diff.sh` read 33 rows beyond the
rail before the section (the grep pane in the body, the tree still in
the sidebar; 38 with a query that hits) and 23 after — the body's
welcome screen, which every section shares. The sidebar's own columns
(4–30) went from 20 differing rows to 1 (2 with a hit): the header
row — Rust has no refresh chip there, so its flags sit four cells
further right — and the `▌` marker on the selected hit, the list
panels' one departure. Rust's Enter on a hit does nothing (walkthrough
finding 1.2); here it opens the file at the line, as Rust's own hint
promises.

`rust-git-status-120x40.txt` / `rust-git-status-80x24.txt` are the
staging pane (`steps-status.jsonl`: `git.status_pane` from the resting
screen), re-cut 2026-09-07 on the fixture's two untracked entries
(`.gitignore`, `requests/`). The 80×24 cut shows the hint row clipped
at the pane's edge (`⏎ di█`), not dropped word by word.

`rust-80x24.txt` is the same screen at 80×24 — the narrow rule: only
the brand menu fits before the ` » `, the browser chip is dropped from
the gap, the right cluster is the compact one. `src/ui/menu_bar.zig`
pins row 0 of both dumps as `rust_row_120` / `rust_row_80`.

## Current counts (main d10de0b, 2026-09-08)

The rail diverges from Rust's by design: Rust's AGENTS and CLOUD AGENTS
rows are gone (they folded into SESSIONS) and Zig has a SCRIPTS row, so
every rail row below the fold reads differently — about 12 lines on a
full-height screen, all in columns 0–3. `tools/ui-diff.sh` prints
`rows differing beyond the rail: N (rail-only rows: M)` under its line
count; a gate judges N. The rail-only rows are the accepted baseline. Outside the rail: the version string, the
coverage ticker's phase, and each screen's own accepted rows. Totals as
run: esc 16, todos 36, editor ~14, status ~16, graph2 ~40 — the number
to watch is the count of rows whose columns 4+ differ (esc 2, todos 12,
status 0 at rest).

*// changed 2026-09-08 (padding):* the tree's cursor row now carries
the list panels' `▌` in its leading cell (column 4 on screen) — the
one deliberate departure from Rust's tree, which keeps that cell
blank — so every screen that shows the tree reads one row more:
esc 2 → 3, editor 1 → 2 (status 1 → 1, todos 12 → 12, notes 13 → 12,
findings 13 → 13 — the statusline's battery / clock chips flicker a
row in and out between runs; the todos / notes / findings columns
have no tree and no bar, so they did not move).

*// changed 2026-09-10 (colors):* the fixture's `zig-data/config.zon`
lists two more workspace roots, so git discovery finds several repos
and the `ws` repo has an accent: on `steps-graph2` the graph pane's
left edge is its one-cell `▌` gutter and the pill's column 0 its `▌`,
so the graph's columns sit one cell to the right of Rust's — graph2
reads 37 beyond the rail (was 38; the rows already differed). esc 3,
editor 3, status 3, diff 14 are unchanged (measured before / after
on the branch base `c0b67b0`). A workspace with one repo paints no
gutter and no pill accent, so a fixture without the extra roots would
read as before.

*// changed 2026-09-10 (std-fixes):* the info box's editor summary
spells its chords for the active profile (D4b), so on `steps-editor`
its four copy rows read `[F12] Definition · [Shift+F12] References ·
[Ctrl+K Ctrl+I] Hover · [F2] Rename` where Rust's `hover_help.rs`
hard-codes `[gd] … [K]` — editor 2 → 6 beyond the rail, the four rows
deliberate. esc 3, menu-file 3, menu-plus 8, http 3 are unchanged (the
statusline's coverage-ticker phase flickers one more row in some runs).

## The start surface (2026-09-23, branch `welcome`)

With no pane open the editor area is the start surface
(`src/ui/welcome.zig`'s `drawStart`, `ui.welcome = full`, the default)
where Rust paints its centred logo: a three-row word mark, the
workspace line, WORKSPACES (it read RECENT WORKSPACES until 2026-09-23,
for a list of this window's roots — the dumps were edited to the new
label, column for column) and RECENT FILES on the left, SESSIONS
(with `+ New Claude Code session here`) and SHORTCUTS on the right, the
version line under them. Every `zig-*` dump that shows the empty
layout was re-cut for it — `esc`, `status`, `menu-plus`, `whichkey`,
`themes`, `fonts`, `launchers`, `scripts`, `scripts-dev`,
`scripts-marketplace`, `picker-preview`, `grep-preview` through
`tools/zig-spec.sh`, `search` through `tools/zig-spec-git.sh`, and
`integrations` through `tools/ui-diff.sh` on a copy of the chrome
fixture whose `zig-data/config.zon` has its `.workspaces` list taken
out: WORKSPACES lists them, and the author's own workspace names
do not belong in a dump. The rows outside the editor area moved only
where main had moved since the last cut (the `⋯` grip on the `:` line,
the marketplace sections, the clock). `ui.welcome = minimal` is the old
pane, still matched against `rust-120x40.txt` by the unit test.

The dump tools now set `MNML_SESSIONS_HOME` for the Zig run to a
throwaway directory: SESSIONS lists this workspace's transcripts out of
`~/.claude` / `~/.codex`, the dumps' workspace is `ws`, and several
real workspaces on this machine are called that. Nothing else reads it,
so the fonts, the coverage chip and the rest are what they were.

`tools/ui-diff.sh` on the chrome fixture, main `06e0d4b2` / this
branch, Rust `target/release`: esc 5 → 27, menu-plus 16 → 34 rows
beyond the rail — the editor area's rows, which Rust fills with its
logo and this build with the lists.

## The chrome walk (2026-09-14)

`zig-esc-120x40.txt` (`steps-esc.jsonl`, the resting screen),
`zig-menu-plus-120x40.txt` (`steps-menu-plus.jsonl`, the `+` chip's
`Create…` with the pointer on `New ▸`) and `zig-status-120x40.txt`
(`steps-status.jsonl`) were cut on `tools/zig-spec.sh`'s throwaway
workspace after the walkthrough's chrome findings landed
(`docs/PARITY.md` `walkthrough-chrome`): a child menu's first arrow
moves as well as lights, Esc clears the
toast stack, a long toast wraps to four rows and the stack paints
beneath the overlays, a 0.2 `config.toml` is one notice per data root
and the `RESTRICTED` chip. `tools/ui-diff.sh` on the chrome fixture
before / after (main `6a13786` / this branch, Rust `target/release`):
esc 4 → 4, status 8 → 3, menu-plus 11 → 8 beyond the rail.

## One toast per source (sessiontabs, 2026-09-22)

`zig-launcher-dock-120x40.txt` and `zig-launcher-dock-outer-120x40.txt`
were re-cut (`tools/zig-spec.sh launcher-dock` / `launcher-dock-outer`):
the two cycles of `view.dock_cycle_mode` paint one toast box,
`dock: always`, where they stacked `dock: hidden` above it — a later
run of the command whose toast is up replaces it (`App.toastLevel`,
`ToastSource`). Cut a second time with main's binary, the two differ
only in those three rows and the clock.

## Context menus: the row above the bottom border (2026-09-10)

Every titled popup — a rail menu, a tree row's, the `+` chip's
`Create…` — paints one blank row between its last item and the bottom
border. That row is Rust's: `ui/context_menu.rs` sizes a titled menu
as `items + 1 + 2` and paints the title in the top border, so the
reserved row stays empty (`rust-menu-plus-120x40.txt`, and a
right-click on the Explorer rail or a tree row, cut with
`tools/ui-diff.sh` on the fixture, show the same blank row on both
sides). `menuSize` in `src/app/render.zig` keeps it so the boxes match
cell for cell; a hunt that reads it as a bug should diff against Rust
first. The one Zig-only popup, the ` » ` list of the menus that did
not fit the bar, is painted in the dropdown shape instead (no title,
the `▸ ` marker column) so an arrow lights a visible cursor.

## Scrollbars: the cell of air (2026-09-08)

Text never touches a vertical scrollbar. Wherever a bar is painted —
`ListPanel` (TODOS / NOTES / FINDINGS / SESSIONS / SCRIPTS / HTTP /
DIAGNOSTICS / DEBUG), the tree, the outline, the git palette, the
staging pane, the editor, the info box, the help overlay, the picker,
the grep and ZON panes — the row's text, its clipped `…` and its
right-aligned badge or count all stop one cell short of the bar's
column, so there is always a blank cell between the last glyph and
the bar (`a-long-name… █`, `13 █`, `1↑ 3↓ █`). The row's ground and
its hit still run to the bar; a hovered row's kebab (` ⋯ `) and a
header chip's own trailing pad are that cell. The Rust dumps keep the
same air (`1 symbol         █`, `ctrl+k b █`); the one place Rust
does not — the staging pane's hint row, clipped `⏎ di█` at 80×24 —
now reads `⏎ d █` here. The editor's text column also ends a cell
short of its bar (Rust keeps a pad beside its change strip); the
gutter does not move.

*// changed 2026-09-10 (mouse-fixes):* the editor's bar no longer
paints `█` — it is Rust's editor bar, a styled space per cell (the
track on the chip ground, the thumb on the muted one), so a dump of a
file taller than its pane shows the blank last column Rust's shows.
The panels' bars are unchanged (Rust's `paint_simple_scrollbar` is `█`
for both track and thumb, as here). None of the four gate screens
scrolls an editor, so `tools/ui-diff.sh` reads the same before and
after: esc 4, editor 3, picker 4, todos 12 beyond the rail (todos
flickers 11–12 with the clock chip). The `zig-*.txt` dumps carry no
editor bar (the `█` in `zig-debug-stopped-80x24.txt` is the DEBUG
panel's), so none was re-cut. `tools/compare.sh compare-mouse` reads
the `ö` click as 10:9 on both sides now (was 10:11).

## Overlays (2026-09-07)

Each `rust-<name>-120x40.txt` below is the Rust screen after the
matching `steps-<name>.jsonl`, on the fixture workspace (which now has
`requests/demo.http`; `rust-palette` / `rust-picker` were re-cut on it):

- `palette` — `ctrl+shift+p`, type `git`: the command palette.
- `picker` — `ctrl+p`, type `ma`: the `Open file` picker.
- `rename` / `delete` — three arrows down the tree (Rust previews the
  row under the cursor, so `.gitignore` is open behind the box), then
  `file.rename` / `file.delete`. The delete steps only OPEN the
  confirm; nothing in the fixture is ever deleted. *// changed
  (one-confirm), 2026-09-21:* the Zig delete box no longer matches
  `rust-delete-120x40.txt` and is not meant to — Rust paints its
  delete confirm as padded labels right-aligned in a five-row box,
  and the Zig side draws every confirm the one bracketed way (the
  row `rust-close-120x40.txt` shows, `   [D]elete      Delete
  [P]ermanently      [C]ancel`, six rows). A `ui-diff` on `delete`
  reports those five rows; `docs/PARITY.md` (`one-confirm`) is the
  record, and `zig-delete-120x40.txt` (`tools/zig-spec.sh delete`, so
  the box is over `prog.dbg` on the throwaway workspace) is the Zig
  dump of the one look.
- `goto` — `src/main.rs` open, `ctrl+g`: the go-to-line prompt.
- `whichkey` — `ctrl+k`: the leader popup (standard profile).
- `help` — `f1`: the help overlay (the keymap reference).
- `discovery` — `view.discovery`: the click-discovery panel.
- `close` — `src/main.rs` open, type `x`, `ctrl+w`: the unsaved-changes
  prompt (the buffer is never saved; the quit discards it).
- `wizard` (Zig-only, `zig-wizard-120x40.txt` via `tools/zig-spec.sh`,
  run with `PATH=/usr/bin:/bin` so no CLI is found) — `first_launch.show`,
  then `n`: the first-launch wizard with "boxes" answered, so the Nerd
  Font install row and the macOS note show; sections 4–6 with the
  not-installed badges; section 7 is below the fold at 40 rows.

Four more from the same fixture, cut in the same commit as `palette`
and `picker`:

- `editor` — `src/main.rs` open: the editor at rest.
- `diff` — `src/main.rs` open, then `git.diff`.
- `outline` — `src/main.rs` open, `view.toggle_right_panel`, then
  `outline.show`.
- `rust-request-120x40.txt` — the one dump whose steps file has another
  name: `steps-http.jsonl`, `requests/demo.http` open, the request pane.

Every dump with `src/main.rs` open (`goto`, `close`, `editor`, `diff`,
`delete`, `rename`, `outline`) also shows rust-analyzer started on it:
the `LSP 1` statusline chip and, bottom-right, the toast `LSP: Failed to
discover workspace.Consider adding the \`Car…` — rust-analyzer's own
complaint (the fixture has no `Cargo.toml`; the root is the file's
directory, as Rust's `find_root` falls back). The toast is
rust-analyzer's text verbatim, with Rust's `LSP: ` prefix, clipped by
the toast painter at 60 chars; the newline in the message costs a char
and paints nothing, hence `workspace.Consider`. rust-analyzer needs
~1–2 s to say it; `steps-goto` / `steps-close` wait 800 ms after the
open and the harness another ~1.4 s before the dump, which has been
enough on this machine — a dump without the toast on a slow run is
timing, not a regression (`tools/fake_lsp/` is the deterministic proof).

**The harness runs on a private copy of the fixture.** `tools/ui-diff.sh`
writes the IPC command file under `<ws>/.mnml/` and both editors'
session files, so two runs on the same paths would cross-talk (another
run's keystrokes land in your screen, and the number jumps). Every run
therefore copies `ws` / `rs-data` / `zig-data` under a fresh `mktemp
-d` and drives both editors there; any number of runs — several agents
on the shared `mnml-zig-worktrees/chrome-fixture` — can go at once, and
the fixture itself is never written. Inside the copy every absolute
path that names a source directory is rewritten to the copy's realpath
(the Zig app resolves the workspace to its realpath and `session.zig`
compares that string with the one `session.zon` names, so `/tmp/x`
would never match its own `/private/tmp/x` — a 4-row `session: …
belongs to … — ignored` toast on every screen, and the tree no longer
restored); today that is `ws/.mnml/session.zon` (Zig),
`ws/.mnml/session.json` (Rust) and `rs-data/history-global.jsonl`, and
the script greps the copy afterwards so a new file carrying the path
fails the run rather than toasting. The copy is deleted at exit;
`KEEP=1` keeps it and prints its path. `--no-copy` (before the
positionals) drives the given directories in place — the old behaviour,
with the session files snapshotted before each editor and restored
after — for a fixture you own alone. `tools/zig-spec.sh` and
`tools/zig-spec-git.sh` seed their own throwaway workspace and data
root under `mktemp -d` and read nothing shared.

*// changed 2026-09-12 (git-walk):* `steps-graph2` reads 38 beyond the
rail against `rust-git-120x40.txt` (37 on 2026-09-10): the extra row is
row 1, the tab strip's chevrons and AI chip, not the graph. The
`git.graph` the steps send twice now lands on the ACTIVE repo's tab
(the same `ws` tab as before on this fixture); a second `git.graph` on
a graph an `esc` has closed brings it back instead of showing the next
repo's. `zig-git-palette-{120x40,80x24}.txt` / `-all-120x40.txt` were
re-cut: only the clock and the detail header's age moved. The walk's
own steps (`docs/ui-spec/walk/steps-git.jsonl`) reproduce findings
1.3–1.6 on a private copy; `tests/e2e/git_graph_dates.test`,
`git_graph_active_repo.test`, `git_commit_box.test` and
`git_status_beside.test` drive the same sequences in the corpus.

*// changed 2026-09-16 (git-panel):* `zig-git-palette-{120x40,80x24}.txt`
/ `-all-120x40.txt` were re-cut: the checked-out branch reads
`  󱓏 main` (its own glyph, no check in the gutter, no green ground)
and the worktree on show `  󰋜 main (ws)`; nothing else moved. The
Rust panel still paints the check and the green row, so `steps-graph2`
reads 38 beyond the rail against `rust-git-120x40.txt` (37 before the
re-skin): the one extra row is `main` in LOCAL. The click model
(one click hovers, a double-click acts) and the row menus are the
user's departure from the Rust panel, described in `docs/PARITY.md`
under `git-panel`.

## Sections and their sides (2026-09-07)

Every activity section has a side (`src/app/side.zig`); these are the
Rust screens the columns are measured against, on the fixture
workspace at 120×40:

- `todos` / `notes` / `findings` — `view.activity_<x>`: the section in
  the sidebar's 26 cells (rail 3 + border + 26, the divider at 30), the
  info box titled with it, the mode chip `TREE`. The Zig columns match,
  and the `+ New todo` / `+ New note` / `+ New finding` row is Rust's
  (`ListPanel.Props.new_label`). The rest of the rows are Zig's by the
  user's decision (2026-09-07), so these three stay at residue —
  todos 26, notes 28, findings 28 differing lines (each +2 since the
  SCRIPTS rail row, a Zig-only entry, landed 2026-09-08) — and the hunks are
  the accepted ones: a blank row directly under the filter (the user's
  ask; Rust has none, so every row below sits one lower), the filter
  pill (`󰍉 / filter` vs `󰍉 type to filter…▏`), the header's count
  spacing (`TODOS (0)` vs `TODOS  (0)`), the empty state's `…` clip
  (Rust clips hard), the info box's copy, the version line, and the
  statusline's stock / now-playing chips.
- `sessions` — `rust-sessions-120x40.txt` / `rust-sessions-80x24.txt`
  (`steps-sessions.jsonl`): the SESSIONS section on a fake home. Both
  editors list the Claude Code sessions of `$HOME/.claude/projects`, so
  the spec is cut on a home of its own: `tools/seed-sessions-home.sh
  HOME_DIR WS` writes three transcripts of WS (live `…0001`, idle
  `…0002` renamed "release train", ended `…0003`), a fake `claude` in
  `HOME_DIR/bin` (on `--resume <sid>` it titles its window `✳ <the
  session's prompt>`, as Claude Code titles its window with a summary of
  the conversation, and stays up — the ended one exits), adds the three
  to `WS/.mnml/session.json` (`claude_sessions`, which Rust resumes at
  startup — the three pty panes on the right of the dump are the fake's
  output and not part of the spec) and the alias to `session.zon`, and
  starts two background copies for the live and the idle session (Zig
  pairs them through `ps`; `seed-sessions-home.sh stop HOME_DIR` ends
  them). Run the harness with `HOME=HOME_DIR PATH=HOME_DIR/bin:$PATH`
  and `--no-copy`: the transcripts name WS, and Rust reads a session's
  transcript under the workspace's own encoded path, so a private copy
  of WS finds none and falls back to the pty's grid lines.
  The steps open the section, right-click the ended card and click
  `Pin` (row 0 of both menus). Rust's rows, cell for cell: a card of
  four rows — ` ▌ <name>` (the accent at `x + 1`, a pin `󰐃 ` before a
  pinned name, the name clipped hard at the edge), ` ▌ you: …` /
  ` ▌ claude: …` (the transcript's last exchange, each clipped to
  `width − 6` with `…`; `exited` alone on a dead session), a fourth row
  for a third line — then a blank row; pinned first, then live, idle,
  ended. The Zig columns match below the top block; the top block is
  the Zig idiom (header, filter, a blank, `+ New session`, a blank), so
  every card sits one row lower than Rust's. At 80×24 one card fits
  and the ended card is off-screen, so the pin click lands on nothing
  and that dump is unpinned. Accepted residue: the header's count
  spacing, the filter pill, the info box's copy, the version line, the
  statusline chips, the panes on the right, and — Zig's — the
  scrollbar column when the cards overflow. `src/sessions.zig`'s unit
  test embeds the 120×40 dump and holds rows 3–18 to it cell for cell.
  *// changed 2026-09-12 (sessions-card):* the cards are the app's AI
  pty panes, as Rust's are (`src/sessions.zig`, the PARITY row), so the
  seed writes `WS/.mnml/session.zon` too — the three sessions as pty
  panes (`claude --resume <sid>`, the accents orange / blue / green,
  the alias) that Zig restores at startup, the way Rust resumes its
  `claude_sessions`. `zig-sessions-120x40.txt` (`tools/zig-spec-
  sessions.sh sessions`, the same steps file, the seed's `--waiting`
  fourth session) is the Zig dump: the fake `claude` titles each pane
  by its prompt, the card at rest reads the transcript's `you:` /
  `claude:` lines off the scan, the ended one `exited`, the pin lands
  on the same click, and the waiting session — a process no pane owns
  — is the `EXTERNAL` row under the cards, `main  (5e551011)`. The
  panes are tabs of one leaf rather than Rust's three splits (not part
  of the spec). `tests/e2e/sessions_*.test` seed their own home
  (`# env: HOME=home`, a relative HOME is under the workspace) and a
  fake `claude` on PATH that takes the pane's `--session-id`, titles
  its window, writes a transcript for its cwd and stays up; a `shell`
  step names the workspace the App sees as `$MNML_E2E_WORKSPACE` (a
  transcript's `cwd` must match it — `$PWD` resolves the symlinked
  temp dir and does not).
  *// changed 2026-09-13 (tab-icons):* `zig-sessions-120x40.txt` was
  re-cut — row 1's three pty tabs now read `󱸀 claude 󰅖`, the Claude
  mark Rust paints there, where they showed the generic codicon
  terminal ``; and the info box's pty copy reads `Terminal pane —
  Restart · Rename · [Ctrl+W] Close.`, the chords read off the
  keymap, where it repeated Rust's prose about a detach and a kill
  chord neither editor binds. Rows beyond the rail against
  `rust-sessions-120x40.txt` are unchanged at 39 — the row itself
  still differs (Rust names each session by its prompt, Zig by the
  binary), but the mark on it now matches.
  *// changed 2026-09-22 (sessiontabs):* `zig-sessions-120x40.txt` and
  `zig-sessions-table-120x40.txt` were re-cut — row 1's tabs now read
  each session by its name, `󱸀 fix the failing t…  󱸀 release train
  󱸀 write the release`, the names Rust's row 1 carries (`sessions.nameOf`,
  the one function the card reads too); the table's strip, three names
  wider, folds two of them into `+2 hidden`. The tabs are one leaf's
  and Rust's three splits, as before. Cut a second time with main's
  binary, the two differ only in row 1, the clock and a pid; the rest of
  each re-cut is main's own drift since it was last cut (the table's
  Claude mark, the strip's New-terminal chip).
- `outline` — `src/main.rs` open, `view.toggle_right_panel`,
  `outline.show`: the outline in the right panel at Rust's 32 cells (the
  divider at 87), a strip row above it (`main.rs ⌥1   󰐕 … ×`,
  `ui/side_strip.zig`), the keys left in the editor (`EDIT`), the rail
  still marking the explorer. At residue: 8 differing lines, all the
  LSP toast (no server for Zig in the fixture) and the statusline's
  stock / now-playing / `LSP 1` chips.

## The debugger (Zig-authored, 2026-09-07)

The debug UI is the one deliberate departure from same-look: the Rust
debug pane was never driven by anyone, so these screens are the spec
and there is no Rust side to diff against. `tools/zig-spec.sh NAME
[COLSxROWS]` seeds a throwaway workspace with `prog.dbg` (the program
`src/app/dap.zig`'s integration test debugs), names `mnml-fake-dap` as
the `.dbg` adapter in a throwaway data root (the home layer is trusted,
so no dialog), feeds `steps-NAME.jsonl` over IPC and keeps the screen:

- `zig-debug-stopped-120x40.txt` — `steps-debug-stopped.jsonl`: a
  breakpoint on line 4, `dap.run`, `dap.show`. The DEBUG section in the
  left column (the status row's narrow form `● prog.dbg:4 · main`,
  VARIABLES with both scopes, WATCH, CALL STACK, BREAKPOINTS with the
  adapter's two exception filters, a blank row between one section and
  the next, every section and scope behind the tree's chevron in the
  headers' grey — `src/ui/expander.zig`, the one expander every left
  panel paints), the editor with the ▶ and its band,
  the step toolbar strip under the breadcrumb, `  x = 1` inline values,
  the hover tooltip over `x` (`ui.hover_tooltip`), and the Debug pane —
  toolbar, `── started prog.dbg ──`, `hello`, the input row.
- `zig-debug-stopped-80x24.txt` — the same at 80×24: the toolbar drops
  to icons, the section scrolls, nothing overflows.
- `zig-debug-console-120x40.txt` — `steps-debug-console.jsonl`: three
  evaluations in the console (`2 : int`, a foldable struct, an error)
  and a Tab completion.
- `zig-debug-breakpoints-120x40.txt` — `steps-debug-breakpoints.jsonl`:
  no session; a conditional (◐), a logpoint (◆), a plain (●) and a
  disabled (○) breakpoint in the gutter, the BREAKPOINTS rows, and the
  row menu opened with `view.context_menu_at_focus`.

## The sessions table (Zig-authored, 2026-09-08)

`tools/zig-spec-sessions.sh sessions-table [COLSxROWS]` seeds a
throwaway workspace and a HOME through `tools/seed-sessions-home.sh
--waiting` (the three sessions of the SESSIONS spec plus `…0004`,
whose transcript ends on a tool use nobody answered — `waiting`), feeds
`steps-sessions-table.jsonl` (`sessions.table`) and keeps the screen.
The Claude Agents dashboard the table replaced was never driven for a
spec, so there is nothing to diff against:

- `zig-sessions-table-120x40.txt` — the table pane: the header chips
  (`state:` sort, `ended: hidden`, `⏸ pause`, `? help`), one group
  row ` ws (3 · 1 hidden)` (the ended session is a day old), the
  rows sorted by state — waiting, live, idle — with the id, tokens,
  cost, age and dirty columns, and the summary block: the counts per
  state, the hidden count, and the selected row's last exchange.
  Re-cut 2026-09-10 after the session accents: a row's first cell is
  the session's `▌` in its colour — colour only, so the text is the
  same bar the clock, the fake's pid and the strip's Claude chip
  (`󱸀`, painted when a `claude` is on PATH — the fake is).

Session worktrees (2026-09-10, `src/app/session_worktree.zig`): a row
whose session runs in a worktree mnml made for it carries ` ⑂ <name>`
after its label — the card in cyan, the table row muted after the
name in what is left before the number columns, `wt:<name>` under
`ui.ascii_icons`. The columns and the rest of the row are unchanged,
and the seeded home has no such session, so the dumps above stand as
cut; the tag is asserted by `tests/e2e/sessions_worktree_launch_merge.test`
(the card, beside a pane, in an 18-cell column) and the unit test in
`src/sessions.zig` (both views, both glyph sets).

## Conflict resolution (Zig-authored, 2026-09-08)

`tools/zig-spec-conflict.sh git-conflict [COLSxROWS]` seeds a throwaway
repo whose `c.txt` is left in a merge conflict — `main` and `feature`
each changed lines 2 and 9 of a ten-line file — and feeds
`steps-git-conflict.jsonl`: the status pane, enter on the `U` row, a
split to the right, `git.conflict_split`, focus back left.

- `zig-git-conflict-120x40.txt` — the editor on the left with both
  blocks: a header row above each (`⚠ conflict N/2` and the chips
  `Ours  Theirs  Both  Edit  Split  AI resolve`, clipped by the leaf's
  width here), the marker lines muted and bold, ours on the green
  ground and theirs on the blue (colours are not in the dump); the diff
  pane on the right in the Split view, `conflict: c.txt`, ours (`:2:`)
  left against theirs (`:3:`) right under one `@@` header. The status
  pane's `⚠ Conflicts (1)  ⏎ resolve in the editor` section is in the
  first tab; the statusline's branch chip carries `⚠1`.

## The branches panel (Zig-authored, 2026-09-07)

The git column is the second deliberate departure from same-look: the
Rust sidebar's `GIT` header, `⎇ branch` row, folder-grouped LOCAL and
PULL REQUESTS are replaced by a branches panel, so the sidebar rows of
`rust-git-120x40.txt` / `rust-git-80x24.txt` are the accepted
difference and only the PANE (cols 31+) is still measured against
them. `tools/zig-spec-git.sh NAME [COLSxROWS]` seeds a throwaway repo
— two locals (`main` one commit ahead of its upstream, `feature`), a
remote `origin` with three branches whose URL names github.com, two
linked worktrees (`wt-locked` on feature, locked; `wt-dirty` detached
with an untracked file), one stash, two tags — feeds
`steps-NAME.jsonl` over IPC and keeps the screen; the shared fixture
is never touched.

- `zig-git-palette-120x40.txt` — `steps-git-palette.jsonl` (the
  graph2 steps). The column starts as TODOS does: row 1 the caps `GIT`
  header with the refresh chip at its right edge, row 2 the list
  panels' filter row, a blank, row 4 the repo pill ` ws 󰅀 ` with the
  tab strip's two chevrons after it (dim here: one repo), row 5
  `Viewing 11`, a blank, then LOCAL (the check, the green ground and
  `1↑` on main), REMOTE (`origin` with the GitHub glyph, its three
  branches indented without the prefix), WORKTREES (the house on the
  main tree with `1↑`, the lock in the gutter of `wt-locked`, the blue
  dot at the edge of `wt-dirty`), STASHES (`sha message`), TAGS newest
  first. Every section folds behind the tree's chevron
  (`src/ui/expander.zig`), as every left panel's expander does. The
  cursor rests on LOCAL with the muted marker, as every list panel's
  does.
- `zig-git-palette-80x24.txt` — the same at 80×24: the column is 12
  cells, the pill paints alone (no room for the chevrons), labels and
  names clip with `…` before the counts and the right-edge cells, the
  list scrolls with the scrollbar in its last column and a cell of
  air before it, nothing overflows.
- `zig-git-palette-all-120x40.txt` — `steps-git-palette-all.jsonl`
  (the graph2 steps, then `git.palette_all`) on the `-all` layout: the
  seeded repo at `ws/alpha` beside `ws/beta` (on `dev`; a `main`, one
  tag). Two graph tabs; the pill reads ` All repos 󰅀 ` with the
  chevrons lit and closed up against it (the 20-cell column has no
  room for the cell of air); `Viewing 15`; every section holds a muted
  sub-header per repo (`alpha`, `beta`, indented like a remote's name)
  with that repo's rows one level further in, its count the sum, the
  check on each repo's own branch and main tree; a repo with nothing
  under a section keeps its sub-header (`beta` under REMOTE).
  Re-cut 2026-09-10 with the repo accents (colour is not in the dump;
  alpha is green, beta blue — the slots in discovery order): every
  sub-header carries its repo's `▌` in the gutter, the pill under All
  repos has none, and the graph pane's left edge is the active repo's
  `▌` bar, so the graph's columns start a cell later and the COMMIT
  MESSAGE column is a cell narrower. The single-repo dumps do not
  change: one repo paints no accent anywhere.
  cells, labels and names clip with `…` before the counts and the
  right-edge cells, the list scrolls with the scrollbar in its last
  column, nothing overflows.

## The HTTP section (2026-09-07)

`rust-http-panel-120x40.txt` is the Rust screen after
`steps-http-panel.jsonl` (`esc`, `esc`, `view.activity_http`): the
section in the left column, the request pane it opens in the centre,
the info box on that pane. The fixture has one request file and
nothing else, so the empty sections show their words and links. Zig
is at 58 differing lines, every hunk deliberate:

- the header — Rust `HTTP` with collapse-all + refresh, Zig
  `HTTP (3)  +  ⟳`; the filter pill's one cell of pad;
- COLLECTIONS — Rust needs two files in a folder to call it a
  collection, so its `requests/demo.http` is a FILES straggler under
  an empty COLLECTIONS with `+ New collection`; Zig groups every folder
  (` 󰉋 requests (1)` with the `+` at its edge, `demo.http` under it);
- COOKIES — Zig's section, with its words (`No cookies yet — …`) and
  the RECENT ladder; Rust has none;
- the scrollbar in the column's last cell, a cell of air before it —
  the list is longer than the column, Rust simply stops painting (its
  `+ New request` /
  `↓ Paste curl…` / `↓ Import…` are below the cut on both, and reach
  with `G` here);
- the empty words at Zig's two-cell pad and the `…` clip (Rust pads
  three on MOCKS / RECENT / CAPTURED and clips hard);
- the AI row's extra box and the statusline's stock / now-playing
  chips (pre-existing residue, in every dump).

Element for element the Zig column has what the Rust one has: the
blank row under the filter, `NAME (n)` behind the expander (the tree's
chevron, `src/ui/expander.zig`, where Rust paints `▼`; the user's call,
2026-09-08) with the ladder at the edge
(`+` alone on COLLECTIONS at 26 cells with the bar, `≡ +` on ENVS,
none on CHAINS, `≡ ⟳ ✕` on MOCKS, `≡ ⟳` on RECENT, `≡ 🌐` on CAPTURED
— Rust's drop rule at this width), the folder tree, `● / ○` envs,
`200 GET  host/path` recent rows with the status coloured, the words,
the green links. `steps-http` (2), `steps-esc` (4) and `steps-todos`
(24) did not move.

Rail residue (sessions-merge, 2026-09-08): every dump that shows the
rail differs from Rust's on its rows — the AGENTS and CLOUD AGENTS rows
folded into SESSIONS and lua-track's SCRIPTS row joined, so Rust's 󰚩 /
󰅣 sit where Zig has nothing and Zig's 󰢱 where Rust has nothing.
`steps-esc` reads 16 (its 4 plus the twelve rail lines);
`steps-sessions` reads 74 on a private seeded copy — the rail, the
top block one row lower, the info box's copy, the version line, the
toast, and Rust's three pty panes across the right of every row — the
SESSIONS column itself is unchanged, card for card.

## Integrations (2026-09-07, branch `sample-integration`)

- `rust-integrations-120x40.txt` — `steps-integrations.jsonl`
  (`view.activity_integrations` from the resting screen): the
  INTEGRATIONS section in the sidebar — the caps header, the tab row
  `Inst (3) Mkt (9)  (34)` (the Rust fixture's real data root has
  three manifests and its marketplace is fetched; the third tab's label
  is nf-fa-dev), the filter pill `󰍉 type to filter…▏` with the sort chip
  ` A-Z ▾` at its right end (Zig keeps the sort in the header's chip
  ladder instead — see the note under the SCRIPTS dumps), then three
  rows per entry — ` <glyph>
  Label (hidden)`, the dim command id, a blank. The Zig side lists the
  sample instead of the author's manifests; the chrome is what is
  matched. `rust-integrations-mkt-120x40.txt` /
  `rust-integrations-dev-120x40.txt` are the Marketplace and Dev tabs
  (`integrations.show_marketplace` / `show_in_dev`): `  <glyph>
  [launcher] btop  ✓ Official  (source)` over the description, the
  scrollbar in the last column with a cell of air before it. The Rust
  FONTS block on the Marketplace tab is not painted here.
- `zig-integrations-120x40.txt` — the Zig screen after the same steps
  on the fixture with the sample installed (`zig-data` holds its
  manifest and the linked binary): `Inst (1) Mkt (0)  (0)`, the
  `Sample` row over `sample.open`, the sample's chip on the palette bar
  and its `S·sample` segment on the statusline.
## The FONTS section (Zig-authored, 2026-09-08)

`zig-fonts-120x40.txt` is the Marketplace tab with the FONTS section at
its top (`steps-fonts.jsonl`: `integrations.show_marketplace` from the
resting screen). The Rust dumps were cut on a machine whose scan saw
nothing, so the Rust screen for it is the author's screenshot, not a
dump: ` FONTS · latest Nerd Fonts 3.5.1`, then `A  <family>  v3.5.1 ✓`
per family (nf-fa-font, the tick green when current, the version
yellow when behind, `auto-baked by mnml` on the mnml face), one blank
row, then the entries. `env-fonts` seeds it: `MNML_FONT_DIRS` points at
`fonts-fixture/` — four minimal sfnt files `tools/fixture-font.py`
writes (a name table each, a format-12 cmap on MnmlSymbols; nothing
renders from them) — and `MNML_NERDFONTS_LATEST` pins the release, so
the dump is the same on every machine. The `↑ Update` chip at the
right of the Symbols row is macOS-only (`font_scan.updateCommand`); a
dump cut on Linux or Windows shows the yellow version alone.

- `zig-launchers-120x40.txt` — `steps-launchers.jsonl` through
  `tools/zig-spec.sh launchers` (`env-launchers` points
  `MNML_MARKETPLACE_LOCAL` at the repo's `launchers/`): the Marketplace
  tab listing the four launchers as `[launcher] <name>  ✓ Official
  (local)` rows over their descriptions, btop installed by `i` and
  greyed `[installed]`, and btop's chip pinned on the rail — the
  `󰫯` on row 24, after the SCRIPTS row, where Rust paints its
  `LauncherIcon` slots. Zig-authored (the Rust dump was cut on the
  author's own pins); the shape is `rust-integrations-mkt-120x40.txt`'s.
- `zig-scripts-120x40.txt`, `zig-scripts-marketplace-120x40.txt`,
  `zig-scripts-dev-120x40.txt` — `steps-scripts{,-marketplace,-dev}.jsonl`
  through `tools/zig-spec.sh scripts[-marketplace|-dev]` (`env-scripts`
  points `MNML_SCRIPTS_MARKETPLACE` at the repo's
  `lua/` and `MNML_SCRIPTS_DEV_ROOTS` at the seeded
  workspace's `dev/`): the SCRIPTS section's three tabs, painted by the
  INTEGRATIONS section's own `drawSection` — `Inst (1) Mkt (5)  󰫯 (1)`,
  the filter pill across the whole row, and three-row entries.
  *// changed 2026-09-15 (panel-consistency):* the sort was an ` A-Z ▾`
  pill at the right end of the FILTER row, which no other section
  does; it is the header's mode chip now (`ui/header.zig`'s ladder —
  the icon rung at the shipped 26 cells, ``), and a selected
  entry's `▌` gutter runs BOTH its rows, not the first alone. Both
  changes land on INTEGRATIONS too, which shares `drawSection`.
  Installed shows the `+ create init.lua` link and the `init.lua` row;
  Marketplace the five shipped examples as `✓ Official`; Dev the seeded
  `hello-scripts  0.1.0  Dev` over the command it adds. Zig-authored —
  the Rust editor has no script install path.

## Menus (2026-09-07)

- `rust-menu-file-120x40.txt` — `steps-menu-file.jsonl`: a click on the
  `File` word (12, 0). The menu-bar dropdown shape (`ui/menu_bar.rs`):
  no title, a two-cell marker column (`▸ ` on the highlighted row —
  none on a mouse-open until a hover or an arrow), the icon, two cells
  of air, the label; ` ▸` ends the recent-files row; a separator is a
  full-width rule; no chord column. `app/render.zig`'s `drawMenu`
  paints it for `MenuState.dropdown`.
- `rust-menu-plus-120x40.txt` — `steps-menu-plus.jsonl`: a click on the
  empty strip's `󰐕` (32, 1), then a hover on its `New ▸` row. The
  context-menu shape (`ui/context_menu.rs`): the title in the top
  border, ` <glyph>  label` with `▸ ` at the end of a parent row, the
  blank row above the bottom edge, the child hung from its parent row
  (its frame's top on the row). Every right-click menu paints the
  same; the `+` menu's rows are Rust's `Create…` tree.


`zig-zon-view-120x40.txt` is the ZON view pane (`steps-zon-view.jsonl`
on `seed-zon-view/`, a workspace config with comments): `zon.view` on
the `.mnml/config.zon` editor tab, `breadcrumb` toggled (its `*` and
the section's, `unsaved` in the crumb row), and the tag picker open on
`md_preview_engine`. Zig-authored — the Rust side has no such pane, so
the dump is the spec. A `seed-<NAME>/` beside a steps file is copied
into the spec's workspace by `tools/zig-spec.sh`.

## The navigation harness (2026-09-09)

`tools/compare.sh NAME [COLSxROWS]` is `ui-diff` for *navigation*: the
same private copy of the chrome fixture and the same two binaries, but
one large file (`src/large.rs`, 6000 lines written into the copy by
`tools/gen-large-fixture.py` — deterministic, gitignored at 314 KB), a
`steps-compare-NAME.jsonl`, and a screen plus `status.json` kept after
**every** step. `steps-compare-keys` is the vim motions (`PageDown`,
`Ctrl+D`, `G`, `gg`, `50%`, `/needle`, `n`, `w`, `b`, `}`, `$`, `0`,
`zz` / `zt` / `zb`, `Ctrl+E` / `Ctrl+Y`), `steps-compare-keys-standard`
the standard profile's (arrows, page keys, `Ctrl+Home/End`, word steps,
`Ctrl+F`, `Ctrl+G`), `steps-compare-mouse` clicks in the text, the
gutter, a tab and the tree, wheel runs of 1 / 3 / 10 / 30, a drag and a
double-click — every verb one both IPCs accept. The profile follows the
name (`standard` / `mouse` → `--input standard`, else vim; `MNML_INPUT`
overrides). Output is `docs/research/compare/NAME[-COLSxROWS]/`:
`step-NNN.{rust,zig}.txt` and `.status.json` (ignored), `diff.md` — per
step the rows differing beyond the rail, the **`text`** count (body
rows still differing once the tree's cursor cell, the last column,
a wide glyph's spacer cell and trailing blanks are dropped — the number
to read), each side's cursor `line:col` and mode from `status.json`,
the top visible line read off the gutter (`+N` pinned scope rows above
it; neither side's `status.json` has a scroll offset), and a first-guess
class — and `timing.md`: start event and first frame after spawn, peak
RSS (`ps -o rss` every 50 ms), and per step the ms from the command's
append to its ack in `events.jsonl` and to the next `screen.txt` write
after it (1 ms polls; both editors dump every frame, so the ack is what
anchors a step). The Rust binary is `target/release/mnml` when present,
else `debug`, else built; `timing.md` names it. Both editors are killed
on exit; `KEEP=1` keeps the copy; `FIXTURE_LINES=30000` writes a
larger fixture (the output dir gains `-30000l`). The reading of the
first four runs is `docs/research/rust-vs-zig-navigation.md`, with a
dated addendum for the open-path work that followed.

`zig-picker-preview-120x40.txt` / `zig-grep-preview-120x40.txt` are the
picker's preview column (`tools/zig-spec.sh picker-preview` /
`grep-preview`, seeded from `seed-picker-preview/` and
`seed-grep-preview/` — one Rust file with a `counts` map in it). This
is the **one place the picker deliberately leaves the Rust screen**:
Rust's picker has no preview column, so `steps-picker` reads 10 rows
differing beyond the rail where it read 4. The reference for the column
is the reference plugin, not the reference editor — results left, the
cursor row's file right, a `│` rule between them, the count at the
prompt's right edge, and the column dropped entirely below the picker's
width floor. The grep dump shows the other half of the rule: the window
is centred on the hit line, not the file's head.

`zig-whichkey-120x40.txt` is the leader popup the standard profile
showed (`tools/zig-spec.sh whichkey`), beside `rust-whichkey-120x40.txt`.
*Since 2026-09-24* the standard profile's popup is its own `Ctrl+K`
chords (`docs/KEYMAP_PROFILES.md` rule 2), so the steps now paint those
rows and the leader tree is the vim profile's; this dump predates that
and is due a re-cut (`docs/PARITY.md`, the which-key row).
The rows carry the same keys and labels in the same order — the root's
`r → +lsp` became `vim_only` to make that true — but this is the **one
place the which-key popup deliberately leaves the Rust screen**: on
2026-09-14 the user chose the reference plugin's look, so every row now
wears a glyph and every group label carries its chord count
(`󰍉 f → +find (7)`), and a sub-level's header is that group's own row
(`┌ <leader>f  +find (7) `). Rust's popup has neither, so `steps-whichkey`
reads 14 rows differing beyond the rail where it read 2 — the twelve
content rows of the popup; its header, its `esc to cancel` hint and its
box still match, and the other two rows predate this. The faces are
taken from the rail and the devicon table rather than re-picked
(`src/ui/whichkey_glyph.zig`), each with its one-cell `--ascii` twin, so
the popup agrees with the rest of the chrome and the column math does
not move between glyph modes. See `docs/PARITY.md`, the which-key row.
Since 2026-09-23 the tree is derived from the spec table's leader chords
(`docs/KEYMAP_PROFILES.md`, "One leader table"), so the standard popup
no longer lists the rows the spec binds for the vim profile alone
(`+nvchad`, `e`, `E`, `/`, `f m` / `f o` / `f z`, the NvChad `g` rows),
`w` is no longer a save, and `+http` sits under `R` — the dump was
re-cut and differs from the Rust one in those rows too.

`zig-themes-120x40.txt` is the theme browser mid-preview
(`tools/zig-spec.sh themes` — `theme.pick`, then `gruv` typed). The
dump carries no colour, which is the point of the `expect color` verb:
`tests/e2e/theme_preview_live.test` asserts the editor body and the
statusline really repaint in the highlighted theme and revert on Esc.
