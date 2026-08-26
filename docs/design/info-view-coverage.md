# Info View coverage — 2026-08-25

Ad-hoc audit triggered by a user report: the GitGraph toolbar chips
(Undo/Redo/Pull/Push/Fetch/Branch/Commit/Stash/Pop/Reflog/Refresh/Blame)
read as having no hover help. Root cause + a full sweep for the same
two failure modes elsewhere below. **Report only — nothing in
`src/ui/info_view_copy.rs` was edited.**

## Summary

- The git-toolbar report is a **copy gap**, not a plumbing gap: hover
  detection is fully wired (`src/app/dispatch.rs:952-960`), but
  `GitToolbarChip` collapses all 11-12 distinct actions into one
  generic, non-differentiated entry (`src/ui/info_view_copy.rs:1091`)
  with a wrong `src:` comment. It reads as "no help" because the copy
  never names the button you're actually over.
- 105/105 `HoverChip` variants are texually referenced in
  `chip_copy()`, but 2 resolve to a hard `None` (real copy gap) and at
  least 1 (`DockKebab`) is dead on arrival — the variant exists, has
  copy, has a legacy tooltip, but `hover_chip_at` never constructs it,
  so no code path can ever reach that copy (plumbing gap).
- The bigger finding from the click-rect vs. hover-target diff: whole
  **row-level item families** in the activity-bar panels (HTTP /
  Notes / Findings / Todos / Agents / Cloud Agents) and several
  **very-visible chrome affordances** (menu-bar overflow chip, the two
  brand-new Marketplace "↑ Update" chip families, bufferline overflow
  arrows, git rail file rows) have click rects and real actions but
  were never given a `HoverChip` variant at all — hovering them can
  never resolve to anything, copy or no copy. This is systemic, not a
  one-off.

## (A) Copy gaps — chip exists, hover resolves, copy is missing/generic/stale

Ranked by hover frequency.

### 1. `GitToolbarChip` — flat generic entry instead of per-action (HIGH — this is the reported bug)

- **Where drawn**: `src/ui/git_graph_view.rs:2065` `draw_git_toolbar` —
  pushes `(Rect, PaneId, GitToolbarAction)` into
  `buttons_out` for each of Undo/Redo/Pull/Push/Fetch/Branch/Commit/
  Stash/(Pop if `has_stash`)/Reflog/Refresh/Blame.
- **Hover resolution**: `src/app/dispatch.rs:952-960` — correctly
  matches `app.rects.git_toolbar_buttons` and returns
  `HoverChip::GitToolbarChip(action)`. **Not a plumbing gap** — this
  fires every time.
- **Copy**: `src/ui/info_view_copy.rs:1091` —
  `GitToolbarChip(_) => Some(InfoViewCopy { title: "Git toolbar chip",
  body: "One-click git action — fetch, pull, push, stage-all,
  commit. …" })`. Single entry for all 12 `GitToolbarAction` variants
  (`src/lib.rs:132-165`), so hovering "Reflog" and hovering "Blame"
  both show the same generic sentence — reads as no help. The `src:`
  comment above it says `src/ui/statusline.rs`, which is wrong; the
  toolbar is drawn in `git_graph_view.rs`, not the statusline.
- **What it would take**: mirror the pattern already used two variants
  away — `RailHeaderChip(GitRailHeaderAction)` at
  `src/ui/info_view_copy.rs:790-849` and
  `RequestTopBarChip(ReqChip)` at `src/ui/info_view_copy.rs:1214-1279`
  both differentiate per action with 6 curated entries each. Do the
  same for `GitToolbarChip`: 11 entries (Undo/Redo/Pull/Push/Fetch/
  BranchPicker/Commit/Stash/StashPop/Reflog/RefreshRepos/BlameToggle —
  `SwitchRepo` is defined on the enum but no longer rendered by the
  toolbar per the 2026-08-24 comment at `git_graph_view.rs:2167-2170`,
  so it can be skipped or left generic). `GitToolbarAction::
  tooltip_label()` (`src/lib.rs:168-…`) already has a distinct
  one-line label per action — good seed material, expand each into
  2-4 sentences per the voice guide, `try_it: PaletteLink` to
  `git.checkout` / `git.commit` / `git.stash` / etc. (all verified to
  resolve in `command.rs`). Fix the `src:` comment while in there.

### 2. `BufferlineTabPage` / `BufferlineTabPageClose` — no entry, falls to flat legacy tooltip (MEDIUM)

- **Where drawn**: numbered tab-page pips (`1`/`2`/…) at the right
  edge of the bufferline chrome row — only visible once the user has
  2+ tab pages, so moderate not high traffic, but it's core chrome for
  split-heavy power users.
- **Copy**: `src/ui/info_view_copy.rs:1450-1451` — both variants
  explicitly `=> None`.
- **Effect**: `pick_help_copy` (`src/ui/hover_help.rs:546-558`) falls
  through to `tooltip::describe_text`, which DOES have entries
  (`src/ui/tooltip.rs:944`, `:968`) — so the panel isn't blank, but it
  shows the flat one-liner tooltip text instead of a real title/body,
  no shortcuts, no try_it. Violates the design doc's "no id·state
  fallback" rule in spirit even though it's not literally raw state.
- **Fix**: two curated `InfoViewCopy` entries, same section as the
  other Bufferline* entries.

### 3. `HttpToolbarChip(_)` catch-all beyond index 1 (LOW)

- `src/ui/info_view_copy.rs:613` — indices 0 and 1 have real entries
  (Import, collapse/expand-all); anything else falls to `None`. Per
  `src/ui/git_graph_view.rs`-style toolbars this list is currently
  fixed at 2 buttons so it's not actively wrong, but if a third HTTP
  toolbar button is ever added it'll silently go copy-less. Flagging
  so whoever adds button #3 knows to extend this arm.

## (B) Plumbing gaps — clickable + click rect registered, but no `HoverChip` (or no chip ever constructed) exists

This is the systemic finding. Method: diffed every field in
`PaneRects` (`src/app/mod.rs:2076`, 289 fields) against every field
actually read inside `hover_chip_at`
(`src/app/dispatch.rs:343-1091`). ~180 fields never appear in that
function; most of those are legitimately exempt (text-input caret
rects, drag-ghost state, transient Y/N modal buttons, scrollbar
internals, background/container rects). What's below is the
non-exempt residue — real per-item click targets with real commands
behind them and zero hover story. Ranked by how often a user sees the
surface.

### High — always-visible chrome

- **`DockKebab` is dead code, not just missing copy.** The variant
  (`src/lib.rs`, `pub enum HoverChip`) has a legacy tooltip
  (`src/ui/tooltip.rs:772`) AND an Info View entry
  (`src/ui/info_view_copy.rs:1455`) — but `hover_chip_at` never
  constructs `HoverChip::DockKebab` anywhere; only `DockEmptyChip` is
  wired (`src/app/dispatch.rs:1082-1088`). The click rect it should
  key off is `app.rects.dock_widget_kebabs`
  (`src/app/mod.rs:2318-2321`, consumed by the click handler at
  `src/tui/mouse/down_left.rs:2720`). Someone wrote the copy assuming
  the wiring existed; it doesn't. **Fix**: add a
  `dock_widget_kebabs` hit-test arm to `hover_chip_at` returning
  `HoverChip::DockKebab` — the copy is already sitting there waiting.
- **Menu-bar overflow chip (`»`)** — `app.rects.menu_bar_overflow`
  (`src/app/mod.rs:2236`), the R9-round fix that lets narrow
  terminals reach clipped menus (mentioned in this file's Status
  block). Real click target, zero hover chip. Every user on a narrow
  terminal sees this and can't get an explanation of what `»` means.
- **Marketplace / font "↑ Update" chips** — `update_chip_rects`
  (`src/app/mod.rs:2205`) and `font_update_chip_rects`
  (`src/app/mod.rs:2211`), the fonts-in-Marketplace feature that
  shipped *today* per the Status block. Both rect lists are cleared +
  rebuilt every frame with real click actions (brew upgrade in a Pty)
  and have no `HoverChip` variant at all.
- **Bufferline overflow arrows** — `bufferline_overflow_left`
  (`src/app/mod.rs:3037`) / `bufferline_overflow_right`
  (`:3041`), shown whenever there are more tabs than fit; click
  scrolls the strip. No hover chip — a brand-new user has no way to
  learn what the arrow does short of clicking it.
- **Git rail file rows** — `git_rail_rows`
  (`src/app/mod.rs:2123`, `Vec<(Rect, GitRailHit)>`), the changed-
  files list under the sidebar's GIT section (distinct from the
  GitGraph pane's toolbar this audit started from, but arguably more
  visible day-to-day since it's always in the left rail). Click
  focuses + runs a default action, right-click opens a context menu —
  no hover chip for the row.
- **`git_repo_chip`** (`src/app/mod.rs:2103`) and **`git_section_
  toggle`** (`:2098`) — repo-switcher chip and the GIT section's
  collapse toggle. Same rail, same visibility tier, no hover chip.
- **`workspace_picker_chevron`** (`src/app/mod.rs:2263`) — the `▾`
  next to the workspace name that opens the workspace picker. No
  hover chip.

### Medium — activity-bar panel row families (HTTP / Notes / Findings / Todos / Agents / Cloud Agents)

Same shape repeats across six panels: the panel's *toolbar icon
buttons* got a `HoverChip` (e.g. `HttpSectionChip`,
`ClaudeAgentsTopbarChip`) but the *row list underneath* — the actual
file/request/session/run the user is scanning — never did.

- HTTP panel: `http_panel_files` (`:2336`), `http_panel_recent_rows`
  (`:2345`), `http_panel_captured_rows` (`:2348`),
  `http_panel_chain_rows` (`:2392`), `http_panel_mock_rows` (`:2395`),
  `http_panel_collection_rows` (`:2399`),
  `http_panel_collection_folder_rows` (`:2402`), `http_panel_env_rows`
  (`:2379`) — 8 row families, zero hover chips. Also the section-level
  chrome around them: `http_panel_section_headers` (`:2352`,
  collapse/expand), `http_panel_new_chip` (`:2339`),
  `http_panel_capture_chip` (`:2355`), `http_panel_captured_clear_chip`
  (`:2358`), `http_panel_captured_refresh_chip` (`:2363`),
  `http_panel_recent_clear_chip` (`:2373`), `http_panel_discover_chip`
  (`:2376`), `http_panel_env_new_chip` (`:2382`),
  `http_panel_chain_new_chip` (`:2385`),
  `http_panel_collection_new_chip` (`:2389`), `http_panel_import_chip`
  (`:2413`) — 11 more chip-shaped buttons with no hover chip. This is
  the single largest concentration of plumbing gaps in the app.
- Notes: `notes_panel_files` (`:2416`), `notes_panel_new_chip`
  (`:2421`), `notes_panel_refresh_chip` (`:2256`).
- Findings: `findings_panel_files` (`:2418`),
  `findings_panel_refresh_chip` (`:2260`).
- Todos: `todos_panel_rows` (`:2426`), `todos_panel_refresh_chip`
  (`:2428`).
- Sessions: `session_new_chip` (`:2434`, the "+ New session" chip).
- Agents: `agents_panel_rows` (`:2439`), `agents_panel_refresh_chip`
  (`:2509`), `agents_panel_workspace_headers` (`:2512`).
- Cloud Agents: `cloud_agents_rows` (`:2515`),
  `cloud_agents_view_chip` (`:2520`), `cloud_agents_refresh_chip`
  (`:2524`), `cloud_agents_change_defaults_chip` (`:2292`).

Fix shape for all of these is the same: add a hit-test arm in
`hover_chip_at` (probably new `HoverChip` variants per family, e.g.
`HttpFileRow(usize)` mirroring the existing index-carrying variants)
plus one dispatched `InfoViewCopy` per family (these can mostly be
generic-by-family rather than per-row, similar to how
`HttpSectionChip` is already generic — a row is a row).

### Medium — GitGraph pane, adjacent to the reported toolbar

Since the report started here, worth flagging that the toolbar isn't
the only gap in this pane:

- `git_graph_repo_switch` (`src/app/mod.rs:2870`) — repo name in the
  GitGraph sidebar header, click opens the workspace picker.
- `git_graph_column_headers` (`:2866`) — sortable column headers.
- `git_graph_detail_dividers` (`:2095`) — resize dividers in the
  commit-detail panel.
- `commit_file_rows` (`:3019`) — per-file rows in the commit-detail
  panel, click opens that file's diff.
- `wip_file_rows` (`:3004`) / `wip_buttons` (`:2998`) — the
  uncommitted-changes file list + inline stage/unstage `[+]`/`[−]`
  buttons.
- `diff_hunk_buttons` (`:3026`) — `[Stage]`/`[Unstage]`/`[Discard]`
  chips in the Diff pane's Hunk view (separate from `DiffToolbar`,
  which IS wired).
- `fold_arrows` (`:2980`) — gutter fold arrows, separate from
  `FoldChip` (which covers the collapsed-region chip, not the
  expand/collapse arrow itself).

### Low — narrower surfaces, fine to defer

- `marketplace_row_rects` (`:2197`) — Marketplace install rows.
  Notable because the design doc's own Phase-1 top-50 inventory
  explicitly names `marketplace_row` as a target, so this is a
  regression against the original plan, not just an omission.
- `request_response_type_chip` (`:2680`) / `request_regenerate_button`
  (`:2657`) — two Request-pane response-bar chips not covered by the
  four `RequestResponse*` variants that do exist.
- `workspaces_editor_rows` (`:2528`) — the `[[workspaces]]` list
  editor overlay.
- Overlay-only surfaces not itemized in full here (fine to defer
  further): Settings rows/buttons, glyph-builder field rows, cheatsheet
  section headers, help-overlay section headers, spend-view headers,
  integration-detail buttons/links, workspace-picker rows, context-menu
  items, confirm/quit/close-prompt buttons, command-palette/`:`-cmdline
  rows. These are transient/modal or already carry their own inline
  label text, so the ROI is much lower than the always-on chrome above.

## Deliberately not investigated this pass

- LSP-hover-backed `EditorSymbol` target (Phase 2, explicitly out of
  scope per the design doc).
- The ~110 `PaneRects` fields excluded as exempt (text-input carets,
  drag state, transient modal Y/N buttons, pure background rects,
  scroll offsets) — not relisted individually. To regenerate: list
  every `pub <field>:` in the `PaneRects` struct
  (`src/app/mod.rs:2076`), then check which are read inside
  `hover_chip_at` (`src/app/dispatch.rs:343-1091`); anything absent is
  a candidate, then triage by reading its doc comment for exemption.
