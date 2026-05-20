# mnml — a NvChad-style terminal IDE (Rust + ratatui)

Greenfield. Supersedes the `../mnml1` prototype and absorbs `../rqst` (a ratatui
Postman-in-the-terminal) — both are **reference implementations to port logic
from, not dependencies**. Full design + phased roadmap: **`.local/PLAN.md`** (the
authoritative spec; read it before architectural decisions).

## Architecture spine — keep these load-bearing

- **Pluggable input layer.** `Box<dyn InputHandler>` (`src/input/`) translates key
  events into `Vec<EditOp>` (text editing — `src/edit_op.rs`, interpreted by the
  single chokepoint `src/editor.rs::Editor::apply`) or escalates to a small *closed*
  `AppCommand` / a registered command. The editor/buffer/render layers **never**
  branch on which handler is active — only the statusline (mode chip) and the
  cursor-shape code read the 4-variant `EditingMode`. (`grep -rn EditingMode src/ui`
  should hit only `statusline.rs`.) This is "vim way + standard way without
  conditionals everywhere" — the thing the user explicitly wants done right.
- **`Pane` + `Layout` + `Command` registry are the rest of the spine.** `Pane`
  (`src/pane.rs`) is the open-thing enum (Editor today; Pty/Request/Diff/Ai later —
  each additive). `Layout` (`src/layout.rs`) is the split tree (Empty|Leaf today;
  HSplit/VSplit in P3). `Command` (`src/command.rs`, a process-global `OnceLock`) is
  what the palette / which-key / keybindings / plugins all hang off. Adding a feature
  = register commands + maybe a `Pane`/`EditOp` variant — not a refactor.
- **Headless mode (`src/headless.rs`, renders via ratatui `TestBackend`) + the file-IPC
  channel (`src/ipc/`) share `app.rs` + `ui::draw` + `tui::dispatch_*` with the
  terminal loop (`src/tui.rs`)** so headless behavior matches the real UI. This is the
  substrate for the planned `.test` E2E format. IPC lives at `<workspace>/.mnml/ipc/`:
  `command` (JSONL host→mnml), `screen.txt` / `status.json` / `events.jsonl` (mnml→host).
- **No giant files.** `src/app.rs` is render-free; `src/tui.rs` is *only* the crossterm
  event loop; chrome lives in `src/ui/`, subsystems get their own dirs (`src/git/`,
  later `src/http/`, `src/lsp/`, `src/ai/`, `src/cdp/`). mnml1's `tui.rs` (~56k chars)
  and rqst's `app.rs` (~468k chars) both rotted — don't repeat that.
- Storage is a plain `String` + byte cursor in `Editor`; all mutation goes through
  `apply` so a rope can slide in later without touching call sites. Columns are chars
  for now (display-width / tabs / CJK is a P2 refinement).

## Build / run / test

```bash
cargo build            # debug
cargo test             # unit tests
cargo clippy --all-targets   # must be warning-free
cargo fmt              # before committing

./run.sh               # launch mnml in *your* cwd (build + run, relaunch-on-exit-75 loop)
./run.sh ~/some/proj   # launch on a specific workspace
./run.sh restart       # tell the running mnml to rebuild + relaunch (IPC {"cmd":"restart"})
./run.sh stop          # quit the running mnml
./run.sh status        # show the marker (workspace, IPC dir)
./run.sh headless [WS]  # same loop, but --headless (virtual screen + file-IPC)
./dev.sh               # cargo-watch auto-rebuild-on-save loop (needs `cargo install cargo-watch`)

cargo run -- [WS] [--input vim|standard] [--ascii] [--config PATH] [--headless]
cargo run -- run FILE [--env NAME]    # HTTP: send a .http/.curl/.rest file headlessly
cargo run -- chain run FILE           # HTTP: run a .chain.json
cargo run -- discover SPEC [--out DIR]  # HTTP: OpenAPI/Swagger → .curl stubs
cargo run -- test [PATH…]             # run .test E2E scripts (default tests/e2e/); also under `cargo test`
```

**The user keeps a `mnml` instance running via `./run.sh`.** After a `cargo build`
that **succeeds**, run `./run.sh restart` so it picks up the new code. (A
`PostToolUse` hook in `.claude/settings.json` does this automatically; the manual
command is the fallback.) Do **not** restart on a *failed* build — that would tell
the loop to rebuild, fail, and the instance would disappear. `restart` force-relaunches
(bypasses the unsaved-changes guard) and re-reads files from disk, so flag it if the
user might be mid-edit *inside mnml* on something untouched.

## Conventions

- `cargo fmt` + `cargo clippy --all-targets` clean before every commit. Run the test
  suite. Commit messages end with the `Co-Authored-By: Claude …` trailer.
- Work on a branch only if asked / on `main` — this repo's default workflow is small
  commits straight to `main` (the user authorized that).
- Don't copy code verbatim from `../mnml1` or `../rqst`; port + restructure.
- When a track needs something from the core, add a `Command` / `EditOp` / `Pane`
  variant — don't special-case across layers.
- The user is happy to have Claude pick which track/feature to do next ("keep going,
  you decide the order — we'll do them all eventually") — choose the most valuable;
  don't ask which. Lean toward *bounded* items when starting a fresh session; save the
  big tracks (the `private` feature, CDP follow-ups, Git GUI phase 4, Mixr pane) for
  when there's room.
  After each landed feature: update this Status block + commit + `./run.sh restart`.

## Status

**Discoverability + small features wave (2026-05-19):**
seven items in one big sweep.
(1) **More statusline action chips wired** — LSP/WRAP/AS/filesize/
Ln-Col chips all clickable now, with hover tooltips describing each.
LSP→`:LspStatus`, WRAP→toggle `[ui] wrap`, AS→autosave config toast,
filesize→`:Stat`, Ln/Col→goto-line prompt.
(2) **Cheatsheet pane click rows** — refactored `&App` → `&mut App`
so the renderer can register row rects; double-click runs the
selected command. `CheatsheetPane::visible_rows_len` exposes the
count for click clamping.
(3) **File-tree drag-and-drop** — mouse-down on a tree row arms a
drag, mouse-up on a different directory row opens a confirmation
prompt that calls `std::fs::rename`. Repoints open editors on the
moved file; refreshes tree + git. Refuses dropping a dir into its
own subtree.
(4) **Quick scratch terminal** — `Ctrl+`` / `Ctrl+\` opens a fixed
10-row pty strip at the bottom of the body. Persistent across pane
switches; click to focus, Esc to blur, second toggle to close.
Sibling to `term.shell` (full pane) for "I want to run one command
without rearranging splits."
(5) **Snippet manager (lite)** — `snippet.pick_all` / `:SnippetsAll`
list every configured snippet across every scope, not just the
active file's filetype. Same accept path inserts at the cursor.
(6) **Markdown link checker** — `markdown.link_check` / `:LinkCheck`
walks every `.md`/`.mdx`/`.markdown`/`.mkd` file in the workspace
and opens broken `[label](path)` references in a Quickfix pane.
URLs (http/https/mailto/etc.) are skipped — path-style links only.
`.gitignored`-style dirs (`node_modules`/`target`/`dist`/`build`)
and dot-dirs are pruned.
(7) **Per-hit toggle in grep replace** — `Pane::Grep` rows now show
an `[x]`/`[ ]` checkbox; Space toggles, `A` enables all, `D`
disables all. `R` (replace) skips files whose hits are all
disabled. Header swaps to `M/N enabled` when any are off.
678 lib tests + clippy clean.

**Discoverability wave III — interactive F1 / sortable graph headers / right-click everywhere / first-launch welcome (2026-05-19):**
five-item polish pass extending the prior waves.
(1) **Interactive F1 overlay.** The Click Discovery panel now
registers each row as a clickable rect. Click a category → matching
on-screen rects flash yellow for ~2s (DISCOVERY_FLASH_MS) so the user
can see exactly where each clickable lives. Active row is underlined
in the panel while flashing. New `DiscoveryCategory` enum (11
variants — one per chip family), `App.discovery_flash:
Option<(category, Instant)>` carries the timer, `ui::discovery::
draw_flash` paints the highlight after every other layer so it sits
on top.
(2) **Mouse parity audit.** Confirmed every list-row pane already
dispatches `is_double_click` through `handle_scm_row_click` —
Diagnostics, Outline, Flaky, Diff, GitGraph (incl. WIP row),
CmdlineHistory, Tests, GitStatus, Grep/Quickfix, Browser (net + DOM
+ cookies + storage), all 8 SCM panes. Cheatsheet remains the only
list pane without row clicks (refactor it'd take takes `&App` not
`&mut App` — left as a follow-up).
(3) **GitGraph sortable column headers.** Click `AUTHOR` / `DATE /
TIME` / `SHA` chip → cycle that column's sort (none → desc → asc
→ none). Active column underlined + yellow with `▲`/`▼` glyph; sort
is in-memory only (re-applied after every refresh via
`GitGraphPane::apply_sort`). New `SortColumn` enum +
`App.rects.git_graph_column_headers` registry +
`GitGraphPane::cycle_sort`.
(4) **Right-click coverage pass.** Workspace header (toggle expand /
switch workspace / add workspace / reveal / refresh), extra-workspace
header (switch / remove / reveal / refresh), Request pane fields
(send / copy as curl / toggle view), AI pane (re-ask / cancel /
promote / apply / session view). New palette commands `ai.reask` /
`ai.cancel` / `ai.promote` / `ai.apply` / `rqst.toggle_view` so each
menu entry has a real dispatch target.
(5) **First-launch welcome overlay.** Auto-opens on the first launch
in a workspace (detected via missing `<ws>/.mnml/.welcomed` marker).
Lists the handful of shortcuts a new user most needs (F1, Ctrl+P,
Ctrl+Shift+P, Ctrl+B, Ctrl+T, leader g l / l h, right-click,
`:welcome`). Esc / any click dismisses + writes the marker so it
doesn't reappear automatically. Manual trigger via `view.welcome`
palette command or `:welcome` / `:Welcome` ex alias.
678 lib tests + clippy clean.

**Discoverability wave II — GitGraph filter set + tooltip + right-click extension + gutter menu + request-pane focus bar + F1 overlay (2026-05-19):**
five small/medium items extending the prior chip work. (1) **GitGraph
filters complete.** `LogFilter` gained `author` (`--author=`) +
`grep` (`--grep=` with `--regexp-ignore-case`). Chord set on the
graph pane: `b` branch picker / `B` clears · `D` date range
(since[..until] or `--since=`/`--until=` flags) · `a` author ·
`s` subject grep · `F` clears every filter. Palette commands
`git.graph_filter_{date,author,subject,reset_all}`. Header chip
combines every active filter into one yellow label
(`⎇ feat · @alice · ~regex · since 1 week ago · F clears`).
(2) **Tooltip + hover system extended** to four more chip
families: bufferline tabs (full workspace-relative path + dirty
marker), diff toolbar (each Inline/Hunk/Split/Wrap/Close chip
describes its effect), fold chips (`⋯ N hidden`), code-lens chips
(`⚡ <title>`). Same ~500ms hover delay. (3) **Gutter right-click
menu.** Right-click any line-number cell opens a per-line menu:
Toggle breakpoint / Conditional / Goto definition / Find
references / Hover / Peek change / Toggle blame / Open at remote.
The click first focuses the pane + places the cursor on the right
line so each command sees the target. New
`app.rects.editor_gutters` registry +
`App::open_editor_gutter_context_menu`. (4) **Request-pane field
focus bar.** Edit mode now paints a yellow `▌` left-edge bar on
the focused field (Method/URL/Headers/Body) instead of the
previous subtle `▸`. Unfocused fields get a dim `▏` so the column
is still anchored visually. (5) **F1 discovery overlay.** Press
F1 to toggle a centered floating panel listing every clickable
region category with live rect counts; green count chip = at
least one is on screen right now. Esc closes (alongside the
toast/tooltip dismiss gesture). New `ui::discovery` module +
`App.show_discovery_overlay` + `view.discovery` palette command.
678 lib tests + clippy clean.

**Discoverability wave: rail buttons + draggable dividers + GitGraph branch filter + chip tooltips + chip right-click menus + persisted clock (2026-05-19):**
five-item polish pass aimed at closing the click-discoverability
loop. (1) **Right-click menus on every statusline chip.** Branch
chip → checkout / new / fetch / pull / push / stash / commit / AI
commit message / graph / status. Workspace chip → switch repo (when
multi-repo) / next-prev repo / worktrees / switch + add workspace /
refresh repos / reveal. Mode chip → use vim / use standard / toggle
keymap. Clock chip → show local / show UTC / hide. Three new
commands `clock.local` / `clock.utc` / `clock.hide` back the clock
menu; the chip's view-state now persists across launches via
`SavedSession.clock_show_utc`. (2) **Chip hover tooltips.** After
~500ms of stable hover on any clickable chip (statusline four +
GIT rail-header chips below), a small bordered popup describes the
left-click action and notes "right-click: menu" when one exists.
New `crate::HoverChip` enum + `App.hover_chip: Option<(HoverChip,
Instant)>` + `ui::tooltip` renderer. Hover detection requires
all-motion mouse tracking (`?1003h`), enabled directly after
crossterm's `EnableMouseCapture` since that only enables button +
drag. Hover clears on any keystroke + mouse-down. (3) **`> GIT`
rail header buttons.** Six right-aligned 3-cell chips on the GIT
header row: Fetch / Pull / Push / Stage all / Commit / Graph.
Glyphs match the GitGraph toolbar. Chips drop from the right when
the rail is too narrow. New `GitRailHeaderAction` enum +
`app.rects.rail_git_header_buttons` registry +
`App::run_git_rail_header_action`. Stage-all uses a new
pane-gate-free `git_stage_all_rail` helper since the existing
`git_stage_all_active` required `Pane::GitStatus` focus. (4)
**Hover-yellow split dividers.** The drag-to-resize was already
wired (`begin_divider_drag` / `drag_divider_to` /
`end_divider_drag`) but had no visual cue. Now hovering any
divider tints the `│`/`─` line + grip glyphs from `t.line`/
`t.comment` to bold `t.yellow`, and the tint persists during an
active drag. New `App.hover_divider_idx`. (5) **GitGraph branch
filter.** `Pane::GitGraph` gained a `filter: LogFilter` slot
(`branch` + optional `since`/`until` for future date-range work).
`load_filtered` wraps `git log` so the branch arg replaces
`--all` and date args pass through as `--since=`/`--until=`. New
chord `b` opens a fuzzy picker over local + remote branches
(with `--all` as the reset entry); `B` clears. New palette
commands `git.graph_filter_branch` / `git.graph_filter_clear` +
`PickerKind::GitGraphBranchFilter`. The header row's "COMMIT
MESSAGE" label flips to a yellow `⎇ <branch> · B clears` chip
when a branch filter is active. 678 lib tests + clippy clean.

**Statusline click targets — mode / workspace / clock (2026-05-19):**
three more statusline chips are now clickable, completing the set
(branch already shipped). (1) **Mode chip** (`EDIT` / `VIEW` / `TREE` /
`INSERT` / `NORMAL` / `VISUAL` / `REPLACE`) on the left → fires
`editor.toggle_keymap` so a click flips between vim ↔ standard input
style. The chip's rect covers both halves of the vim-mode split-chip
(the diamond-V glyph + the label) by spanning the captured `(start,
end)` seg range. (2) **Workspace / active-repo chip** on the right →
opens `App::open_repo_picker`. Single-repo workspaces toast "only one
repo in this workspace"; multi-repo ones get the fuzzy picker the
existing `git.switch_repo` command already uses. The chip label now
shows the *active repo* name (not just the workspace folder) when
there are multiple repos so the user has visible feedback after
switching. (3) **Clock chip** → toggles between local time and UTC.
`App.clock_show_utc: bool` (default false — local; in-memory only).
UTC mode shows `HH:MMZ` (ISO convention) so the user can tell at a
glance which timezone is rendered; toast confirms each flip.
Implementation: `render_right` was refactored to also return per-seg
`(start_col, width)` (mirror of the earlier `render_left` change) so
the caller can register screen-relative click rects after the right
lane's anchor point is computed. 678 lib tests + clippy clean.

**Clickable statusline branch chip + GitGraph live WIP refresh (2026-05-19):**
two daily-usability wins. (1) **Clickable branch chip** — the existing
green statusline git-branch chip ( <branch> +/●/- ⇡/⇣ …) is now a
click target that fires `git.graph`. Picks up "I want the commit
history" without learning `<leader>g l`. Implementation reused the
existing left-lane Seg layout: `render_left` now also returns each
seg's `(start_col, width)` so the caller can register an
`app.rects.statusline_branch_chip` rect after assembly; the chip's
seg index is captured at push time. The earlier-considered bufferline
`` button was reverted in favor of this — the branch chip was always
visible already, so adding a separate icon would have duplicated the
conceptual link without freeing the user from finding it. (2) **GitGraph
WIP refreshes on tab activation + on every editor save** — the WIP
virtual row (working-tree changes summary at the top of the commit list)
was previously frozen at whatever state it was in when `after_git_change`
last fired; coming back to a GitGraph tab after editing a file in another
split showed stale WIP info until the user closed + reopened the pane.
Two new hooks: `App::reveal_pane` calls `g.refresh()` when revealing a
`Pane::GitGraph` (catches "I switched tabs, made changes elsewhere, came
back"); `App::save_active_now` calls `refresh_git_graph_panes()` (catches
"I'm watching the graph in one split while saving in another"). Both
re-shell `git status --porcelain` for the WIP detection + re-fetch the
commit list, so the WIP row appears immediately. 678 lib tests + e2e
green.

**GitStatus right-click context menu + sticky Hunk chips (2026-05-19):**
two follow-ups on yesterday's diff/git bundle. (1) **GitStatus
right-click menu** — right-click a file row in `Pane::GitStatus`
opens a per-file menu: `Stage` / `Unstage` (whichever applies given
the row's current side), `Discard changes…` (destructive — confirmed
via a `PromptKind::GitDiscardFile` prompt that requires typing the
filename), `Stash file` (`git stash push -u -- <rel>`), `Ignore
<name>` + `Ignore *.<ext>` (appends to `.gitignore`, creating the
file when missing; idempotent — duplicate lines skipped), `Edit
file` (open in the active leaf), `Reveal in Finder`, `Copy path`,
and `Delete file…` (filename confirmation via the existing
`PromptKind::DeleteConfirm`). Backed by three new helpers in
`crate::git::stage`: `discard_file` (`git restore -- <rel>` with
`git checkout HEAD -- <rel>` fallback for old git), `stash_file`,
`append_gitignore`. Six new `MenuAction` variants — `GitStageFile`,
`GitUnstageFile`, `GitDiscardFile`, `GitIgnoreFile`,
`GitIgnoreExtension`, `GitStashFile` — wired through
`App::run_menu_action`. (2) **Sticky chip row on Hunk view too** —
the per-hunk Stage/Discard sticky row at the top of body (already
on Inline + Split from bundle 4) now also paints on Hunk view so
all three modes are visually consistent. The inline per-hunk header
chips still render below — the sticky row gives a fixed-position
target that doesn't scroll with the body. 678 lib tests + e2e
green.

**Diff/git/scrollbar polish bundle 4: Discard confirm + Inline/Split chips + filter highlights + list-pane scrollbars (2026-05-19):**
four items in one sweep. (1) **Discard hunk confirm prompt** —
clicking the red `[Discard]` chip no longer fires immediately; it
opens a `PromptKind::DiffDiscardHunk` prompt that requires the user
to type the literal `discard` to confirm. New `App.pending_discard_hunk:
Option<(PaneId, usize)>` carries the target across the prompt
accept. (2) **Per-hunk chips in Inline + Split** — added a sticky
top-of-body chip row (`Hunk N/M  src/foo.rs  …  [Stage] [Discard]`)
that acts on `d.cursor`'s hunk. Hunk view keeps its inline per-
hunk chips. Factored the chip layout into shared helpers
(`chip_actions_for_scope`, `chips_total_width`, `push_chip_spans`,
`active_hunk_chips_row`). (3) **Filter highlighting** — `/`-filter
matches now tint the matching substring with a yellow bg over the
body row's existing fg in Inline + Hunk views. New
`highlight_filter_spans(text, filter, base_style, match_bg)`
splits a single body span into prefix / match / suffix spans
case-insensitively. Skipped in Split (would conflict with the
intraline char highlighting). (4) **List-pane scrollbars** —
Diagnostics, Outline, Grep, Quickfix, GitStatus, Tests, Flaky,
CmdlineHistory all now reserve a 1-cell right-edge scrollbar
(`bg2` track + solid `comment` thumb) painted via the new shared
`crate::ui::scrollbar::paint_simple_scrollbar` helper, registered
on `app.rects.scrollbars` with per-pane `ScrollbarKind` variants so
the existing drag dispatcher can update each pane's `scroll`
field. Selection follows scroll (snapped) so the per-frame
keep-selected-on-screen math doesn't fight the bar back. 678 lib
tests + e2e green.

**Split scrollbar and change-density indicators (2026-05-19):**
the combined-column scrollbar (track + thumb + change markers all in
one 1-cell strip) was confusing — the thumb either hid the change
colors or overlaid them with a stippled glyph that read as muddy.
Now both the editor pane and all three diff views reserve TWO right-
edge columns: an inner thin change-density indicator (one `▏` glyph
per cell, fg=green/blue/red/yellow based on the git-sign or
RowKind aggregate over that file-row range, bg=bg_dark) plus an
outer 1-cell scrollbar (track in `bg2`, thumb in `comment`). The
two reads as distinct strips at a glance: the thin colored ticks
mark *where* changes are, the scrollbar shows *where you are* in
the file. Reserved-cells threshold bumped from 16 → 17 (diff)
and 32 → 33 (split) and from `gutter_w + 2` → `gutter_w + 3`
(editor) to account for the extra column. `draw_diff_scrollbar`
no longer takes `row_kinds` — change markers moved to a new
`draw_change_strip` helper. 678 lib tests + e2e green.

**Diff polish bundle: hunk chips, intraline-split, `/`-filter, file-walk, right-click menu (2026-05-19):**
five Diff/Git GUI items shipped together. (1) **Per-hunk
`[Stage]` / `[Unstage]` / `[Discard]` chips** in Hunk view — clickable
green/orange/red chips right-aligned on each hunk header row. New
`crate::DiffHunkAction` enum + `app.rects.diff_hunk_buttons` registry
+ `App::apply_hunk_action(pid, hunk_index, action)` dispatcher.
Scope-aware: `Unstaged` / `AllVsHead` show `[Stage] [Discard]`;
`Staged` / `StagedFile` show `[Unstage]`; commit / buffer-vs-disk
show nothing (read-only). New `crate::git::diff::discard_hunk`
shells `git apply --reverse` (no `--cached`) against the working
tree. (2) **Intraline char highlighting in Split view** — paired
Removed/Added rows now compute `intraline_diff` and split the body
text into prefix (dim) / middle (bold tint) / suffix (dim) on
*both* sides; matches the existing Inline view's per-line
behavior. New `push_intraline_spans` helper. (3) **Diff `/`-filter**
— `/` opens filter mode in any diff view (standalone or embedded);
type / Backspace / Enter / Esc as expected. A yellow banner row at
the top of the body shows `/ <query>_` (in mode) or `filter: <query>`
(after Enter). `n`/`N` walk between hunks containing the filter
(case-insensitive substring match) — new `next_filter_match(d,
forward)` helper wraps. (4) **`]f` / `[f` next-/prev-file in
embedded diff** — `App::diff_jump_file` now handles the
`DiffScope::CommitFile { hash, rel_path }` shape by walking the
selected commit's `detail.files` and reopening the embedded diff
against the next/prev file; falls through to the standalone
behavior for `Pane::Diff`. The chord is also wired in the
embedded-diff key handler. (5) **Right-click context menu** —
right-click on any diff body row opens a per-hunk menu. For
`CommitFile` it offers "Open file at this revision" (new
`App::open_file_at_revision` shells `git show <hash>:<rel>` into a
scratch buffer) + "Copy commit hash"; for `Unstaged` / `AllVsHead`
it offers "Stage hunk" / "Discard hunk"; for `Staged` /
`StagedFile` it offers "Unstage hunk". New
`MenuAction::DiffOpenAtRevision { hash, rel }` and
`DiffHunkAction { pane_id, hunk_index, action }` variants. 678 lib
tests + e2e green.

**Diff `[ × ]` close chip + embedded-diff click suppression (2026-05-19):**
two follow-ups on the embedded-diff UX. (1) **`[ × ]` close chip
on the diff toolbar** (red, right-edge aligned) — clicking closes
the diff: clears `g.embedded_diff` for an embedded-in-GitGraph
diff, or closes the standalone `Pane::Diff`. Esc still works; this
is the discoverable alternative. New `DiffToolbarAction::Close`
variant + a special-case branch in the toolbar click dispatcher
(needs to run before the view-mode handling because the pane may
no longer exist after the close). (2) **Embedded-diff click
suppression** — when an embedded diff is overpainting the commit
list, clicks on the diff body were also landing on the commit-row
rects registered earlier in the same frame, swapping the right
detail panel to whatever commit the click happened to land on top
of. Fix: skip registering commit-row click rects in
`app.rects.list_rows` when `g.embedded_diff.is_some()`. The right
detail panel now stays pinned to the originally-selected commit
until the user closes the diff. 678 lib tests + e2e green.

**Translucent thumb + GitGraph commit-list scrollbar (2026-05-19):**
two scrollbar polish items. (1) **Translucent thumb over change
markers** — when a scrollbar thumb cell sits on top of a green / red
/ yellow change marker it used to paint solid grey, fully hiding the
change color. Now those cells render a `▓` glyph with
`fg = comment` + `bg = change-color`, so the thumb stays visible
(75% comment) but the underlying change color shows through (25%).
Plain-track thumb cells still get solid `comment` for max contrast.
Applied to both the diff scrollbar (Hunk / Inline / Split — all
flavors, standalone Pane::Diff + embedded GitGraph) and the editor
pane scrollbar's git-sign markers. (2) **GitGraph commit-list
scrollbar** — when no embedded diff is showing, the commit-list
body now renders a 1-cell scrollbar on its right edge (track in
`bg2`, solid `comment` thumb). New `ScrollbarKind::GitGraphCommits`
+ `App::set_pane_scroll` arm that updates `g.scroll` AND snaps
`g.selected = new_scroll` so the per-frame keep-selected-on-screen
math doesn't immediately fight the scrollbar back to the old
position. Reuses the same drag dispatcher already wired for the
diff scrollbars. 678 lib tests + e2e green.

**Embedded diff: clear cell contents under the overlay (2026-05-19):**
the commit-list rows inside `Pane::GitGraph` were bleeding through
to the right of every embedded-diff body row (e.g. `"...config /"`
was getting `"fix"` appended where the commit-list's trailing
"fix accidental stray 'z' in build.rs" subject column had been
painted). Root cause: `Paragraph::new("")` calls `buf.set_style`
on the area but doesn't overwrite the underlying cell content — it
just retints the chars that were already there. The embedded-diff
body rows are shorter than the full pane width, so anywhere the
diff content didn't reach, the commit-list chars from earlier this
frame remained visible (just retinted). Fix: render
`ratatui::widgets::Clear` over `list_area` before the bg-style
fill — `Clear` resets every cell to a space with default style,
then the styled paragraph + the diff body paint over the clean
slate. 678 lib tests + e2e green.

**Diff body styling: graphical-Git-GUI-style subtle row tints (2026-05-19):**
the three diff views were painting the entire body text of added /
removed lines in saturated green / red — visually loud and at odds
with a popular Git GUI's quieter convention of a subtle row-bg tint with
normal-colored code text. New `blend_over(fg, bg, alpha, fallback)`
helper mixes the theme's `green` / `red` over `bg_dark` at ~18%
opacity to derive `added_row_bg(t)` and `removed_row_bg(t)`. All
three renderers (Hunk / Inline / Split) now use those tints as the
per-row bg for changed lines; the body fg stays `t.fg` so the code
reads naturally. Only the left `▏` chip + the `+` / `-` sign cell
carry the saturated green / red — those are the "this row is added
/ removed" indicators. For indexed-color (non-RGB) themes the
helper falls back to a hardcoded muted dark-green / dark-red so the
distinction is visible regardless of theme. 678 lib tests + e2e
green.

**Draggable + click-to-jump scrollbars + SHA padding bump (2026-05-19):**
the scrollbars on editor + diff panes (Hunk / Inline / Split — both
standalone `Pane::Diff` and the embedded diff inside `Pane::GitGraph`)
are now full pointer targets, not just visual indicators. Click
anywhere in a scrollbar (including on a green / red change marker) to
jump the viewport so the click row is centered; click + drag to
continuously scroll. New `crate::app::ScrollbarHit { area, pane_id,
total, viewport, kind: ScrollbarKind }` + `app.rects.scrollbars:
Vec<ScrollbarHit>` registry, populated by each renderer at the same
time the scrollbar is painted. `App.dragging_scrollbar:
Option<ScrollbarHit>` carries the drag across mouse-move events;
`begin_scrollbar_drag` / `drag_scrollbar_to` / `end_scrollbar_drag` +
`apply_scrollbar_to` / `set_pane_scroll` do the work. The
`begin_scrollbar_drag` short-circuit sits at the very top of the
`Down(Left)` arm in `tui::dispatch_mouse` so a click on a scrollbar
no longer falls through to the editor's place-cursor handler or the
GitGraph row-select handler (which was the "clicking near the
scrollbar changes the selected commit row" surprise). Three new diff
renderer args (`scrollbars`, `sb_kind`, `pane_id`) thread the
registry + kind tag from caller down — the kind tells the dispatcher
which scroll field to write (`Pane::Editor.buffer.scroll` /
`Pane::Diff.scroll` / `Pane::GitGraph.embedded_diff.scroll`).
**SHA column padding** bumped from 1 → 2 chars so it doesn't sit
flush against the new scrollbar.

**Diff scrollbar / change-minimap on all three views + split gutter alignment fix (2026-05-19):**
unified scrollbar / change-minimap on the right edge of every diff
view (Hunk / Inline / Split). New `draw_diff_scrollbar(frame, area,
t, row_kinds, scroll, viewport_h)` helper paints: `bg2` track,
green / red / yellow change markers from a per-row `RowKind` tag,
`comment`-colored thumb sized by `viewport_h / total_rows`. All three
renderers now build a parallel `Vec<RowKind>` alongside `rows` so the
minimap reflects the actual content layout. Split view's pre-existing
`draw_change_minimap` was replaced with the shared call (same shape,
adds the thumb on top). Editor pane's scrollbar got the same upgrade
— track switched from `bg_dark` to `bg2` (was nearly invisible),
thumb from `bg3` to `comment` (now actually visible), plus git-sign
change markers tinted across the bar so it doubles as a per-file
minimap. **Split gutter shift fix** — empty-filler rows on the left
side of split view were rendering 1 cell narrower than numbered rows
(the `gutter_text` Some-branch produced `width + 1` chars but the
None-branch produced `width`). Now both arms emit `width + 1` so the
body stays vertically aligned across numbered + empty rows. 678 lib
tests + 1 e2e suite — green.

**Diff view modes: Hunk gets line numbers, Inline shows full file, Split gets minimap (2026-05-19):**
the three diff views had drifted to nearly identical output — both
Hunk and Inline were rendering `d.hunks` (the focused-context
hunks), so the "Inline" toggle didn't visibly change anything.
Reworked to match a popular Git GUI's three-mode UX. **Hunk** keeps the
focused-region semantics (just the changed lines + 3-row context per
hunk, expanded by default with chevron-fold collapse) but gained a
`<old> <new>` line-number gutter (5-char column with one trailing
space). **Inline** now uses `d.full_hunks` (lazily fetched via
`fetch_diff_full` — the `-U99999` form that returns the whole file's
before/after) and renders one continuous single-column view with
green for additions, red for removals, plain fg for context, plus
the same line-number gutter; no per-hunk header rows (the file is
one continuous document). Falls back to the focused hunks if the
full-context fetch returned empty (binary files, parse failure).
**Split** keeps the side-by-side whole-file layout but gained a
1-cell change-density minimap on the right edge — each cell
aggregates a `rows.len() / area.height` chunk of file rows and
paints green / red / yellow / bg2 depending on what changes fall in
that range. A subtle `bg3` band overlays the unchanged cells inside
the current viewport so the user can see where they are in the
file at a glance. Minimap is skipped when the pane is narrower than
32 columns. Both Inline + Split lazy-fetch `full_hunks` on first
render (was Split-only); the embedded-diff path inside GitGraph
matches the same fetch shape. Shared helpers `hunk_start_lines`,
`pair_line_nos`, `compute_gutter_width`, `gutter_text_pair`,
`compute_intraline_partners`, `intraline_range_for` factor the
line-number math + intraline-diff pairing across renderers.
**SHA column padding** dropped from 2 to 1 char to match the
1-char gap on every other column. 678 lib tests + 1 e2e suite —
green.

**Embedded diff key/wheel/toolbar routing + repo cycling (2026-05-19):**
finishing the embedded-diff plumbing inside `Pane::GitGraph`. Click a
file in the WIP or commit-detail panel and the diff opens *in-place*
on the left (replacing the commit list) while the right detail panel
stays visible. Now the keyboard / mousewheel / toolbar all follow:
diff chords (j/k/n/p/u/d/v/w/Up/Down/PgUp/PgDn/Home/End) route to
`embedded_diff` when present (intercept sits between the WIP textarea-
focus check and the hash-filter check); Esc closes the embedded diff
first (a second Esc bails to tree); wheel over the GitGraph pane
scrolls the embedded diff instead of moving the commit-list selection;
the existing `diff_toolbar_buttons` click handler picks `Pane::Diff`
*or* `Pane::GitGraph.embedded_diff` so the Hunk/Inline/Split/Wrap
chips work in both contexts. App-level `diff_view_mode_pref` /
`diff_wrap_pref` capture `v` / `w` chord-driven changes from the
embedded path too so the next open inherits them. **Multi-repo
cycling** — new `App::cycle_active_repo(forward)` + `git.next_repo`
(`Alt+]`) / `git.prev_repo` (`Alt+[`) commands wrap through
`self.repos`. Mousewheel over the `> GIT` section header in
multi-repo workspaces cycles the active repo too (Up = previous, Down
= next; matches bufferline/tab-strip wheel convention). Both gestures
are no-ops in single-repo workspaces (wheel falls through to the next
rect handler). 678 lib tests + 1 e2e suite — green.

**GitGraph WIP detail: interactive stage/unstage/commit buttons + click-detail fix (2026-05-18 cont.):**
the WIP detail panel went from read-only to fully interactive. New
`crate::WipAction` enum carries six variants — `StageAll`,
`UnstageAll`, `StageFile(PathBuf)`, `UnstageFile(PathBuf)`,
`OpenCommitPrompt`, `RequestAiCommitMessage`. The renderer emits one
clickable button rect per action onto a new `app.rects.wip_buttons:
Vec<(Rect, PaneId, WipAction)>` registry, drawn as colored chips
(green for stage / orange for unstage / blue for AI). Layout:
- "Unstaged Files (N)" header has a green `Stage All` button right-aligned.
- Each unstaged-file row gets a `[+]` green button at the right edge.
- "Staged Files (N)" header has an orange `Unstage All` button.
- Each staged-file row gets an orange `[−]` button.
- New "Commit" section below: 4-space-indented `Commit` (green) +
  `AI Message` (blue) buttons. Disabled (bg2 + comment) when
  nothing's staged, with a hint line above.

`tui::dispatch_mouse` matches the click against `app.rects.wip_buttons`
before falling through to the editor-pane click handler — buttons
"own" the click. The new `App::run_wip_action(action)` dispatches to
the right `crate::git::stage::*` helper (gate-free, unlike the
existing `git_stage_all_active` which required `Pane::GitStatus`
to be active), then refreshes the GitGraph pane so the WIP file
list reflects the change immediately. After-action toast confirms
("staged foo.rs", "unstaged everything", etc.); errors surface as
`git add: <stderr>` toasts.

The keyboard chord shortcuts (`c` / `C` / `Enter`) on the WIP row
still work as before — they bypass the button rects and call the
App methods directly. Mouse-driven and keyboard-driven flows
share the same underlying helpers.

**Click-detail-reload bug fix** — `handle_scm_row_click` for
`Pane::GitGraph` was setting `g.selected = flat_idx` directly,
which skipped `reload_detail()` and left the right-side detail
panel empty for commit selections (WIP rows still worked because
their detail comes from `wip_snapshot` not `g.detail`). Symptom:
only the WIP row populated the right side — clicking any real
commit showed an empty right panel. Also the old bounds check
(`flat_idx < g.commits.len()`) used the wrong total since
`flat_idx` is now a virtual index that includes the WIP row.
Fix: route through `g.jump_to(flat_idx)` which clamps to
`total_rows()` AND calls `reload_detail`.

676 lean / 710 private lib tests, 87 e2e, 7 ipc — all green.

**GitGraph: WIP row + right-side detail + auto-sized columns (2026-05-18 cont.):**
substantive rework of `Pane::GitGraph` to feel more like a popular Git GUI's
commit-graph view. Headline changes: (1) **WIP virtual row at the
top** of the list. When the working tree is dirty (`git status
--porcelain` reports anything), the renderer inserts a row above
commits[0] with a yellow swimlane bar, "WIP @ <branch>" chip, and
change summary (e.g. `5 change(s) · 2 staged · 1 new`). The
`GitGraphPane.selected` field is now a *virtual* index — `0 = WIP`,
`1..=commits.len() = commits[i-1]` when `has_wip` is true. New
helpers `total_rows()` / `is_wip_selected()` / `commit_index()` /
`jump_to_commit()` translate between virtual rows and the underlying
commit list. (2) **Right-side detail panel** instead of bottom.
a popular Git GUI's convention; takes ~40% of pane width (clamped 30..=70),
falls back to no detail panel for narrow panes (< 80 cols).
Vertical divider between list + detail. (3) **WIP detail view** —
when the WIP row is selected, the right panel shows a yellow banner
(`WIP @ <branch> · <summary>`) over collapsible Unstaged Files / Staged
Files lists, each row prefixed by a colored status letter (M/A/?/!).
Closes with a hint row: `c commit · C AI message · Enter status pane`.
Commit detail (when a real commit row is selected) still shows
message + parents + changed files, just on the right instead of
bottom. (4) **WIP-row chords**: `c` opens the commit prompt,
`C` triggers AI commit message, `Enter` opens the full
`Pane::GitStatus` for interactive staging. (5) **Auto-sized
columns** — `compute_column_widths` now takes a `ColAutoSize` carrier
with `branch_chars` / `author_chars` from the visible window. Branch
column auto-sizes to fit refs (clamped 10..=35); author column to
fit names (clamped 8..=22). (6) **Config overrides** for users who
want explicit control: `[ui] git_graph_branch_col = N` (None ⇒
auto-size, Some(0) ⇒ disable column entirely), `git_graph_author_col`,
`git_graph_detail_col`. Pairs naturally with the existing visual
swimlane bar so a user can dial in their preferred layout. The
existing per-row mouse click + the hash-filter (`/`) flow both work
unchanged — find_by_hash_prefix still returns commit-list indices,
callers route through `jump_to_commit` so the WIP-offset is applied.
676 lean / 710 private lib tests (+2 new for auto-sizing & overrides),
87 e2e, 7 ipc — all green.

**Small polish — AI max_tokens + md image_rows config + Git ex aliases (2026-05-18 cont.):**
configurables + small ex aliases for what just landed. (1) **`[ai]
max_tokens = N`** overrides the API backend's `DEFAULT_MAX_TOKENS`
(4096) output cap. Clamped to 16..=200_000. CLI backend ignores
(the `claude` binary picks its own). Wired through
`App::ai_max_tokens` ⇒ `api_client::stream_to_channel`'s new
`max_tokens: Option<u32>` parameter. (2) **`[ui] md_image_rows = N`**
overrides `DEFAULT_IMAGE_ROWS` (12) — how tall inline image embeds
are in markdown preview. Clamped to 2..=100 on load. `parse_image_directives`
+ `render_markdown_with_image_placeholders` now take the row count
as a parameter; `md_preview::draw` reads it from
`app.config.ui.md_image_rows`. Useful for note files with many
small thumbnails (drop to 6) or screenshots (bump to 20). (3)
**Git ex aliases** — `:Stashes` / `:StashList` (apply picker),
`:StashDrop`, `:Reflog`. Vim users reach for the colon-line first.
674 lean / 708 private lib tests (+1 new `parse_image_directives_respects_custom_rows`),
87 e2e, 7 ipc — green.

**Markdown preview: inline image embedding (2026-05-18 cont.):**
ties the wave-2 image plumbing to a daily-use feature. New
`parse_image_directives(src) → Vec<ImageDirective{line_idx, rows,
path, alt}>` walks the markdown source for standalone `![alt](path)`
lines and records (rendered-row-index, source-path, alt-text) for
each. `render_markdown_with_image_placeholders` extends the existing
renderer with a `with_image_placeholders` flag — when on,
standalone-image lines emit `DEFAULT_IMAGE_ROWS = 12` placeholder
rows (first row a dim italic `[image: alt]` caption; rest blank) so
the post-`terminal.draw()` overlay has room to land. Path resolution
is relative to the `.md` file's parent dir (handles workspace-
relative paths like `img/foo.png`); absolute paths pass through.
New `MdPreview.image_cache: HashMap<PathBuf, ImageData>` caches the
loaded + decoded PNG bytes (via `ensure_png_bytes`) across frames so
typing / scrolling doesn't re-decode. Stale entries auto-evict when
the source's image set shrinks. **`PaintRequest` was refactored** to
carry `png_bytes: Arc<Vec<u8>>` directly instead of pointing at a
pane — the emitter in `tui.rs::emit_image_placements` no longer
needs to know which pane variant owns the image (was Pane::Image
only; would need a special case for MdPreview otherwise). The
renderer is now responsible for staging ready-to-emit bytes; the
emitter just writes them. Terminal without an image protocol still
sees the placeholder + caption (intentional — keeps line-count math
identical so scroll position is stable between the two paths).
Inline-image references (mid-paragraph `![alt](url)`) fall through
to the existing link renderer — only *standalone-line* images get
the placeholder treatment. 5 new tests cover the parser:
standalone detection, inline rejection, code-fence skipping, alt-
text + path extraction, missing/empty path rejection.
673 lean / 707 private lib tests (+5 new), 87 e2e, 7 ipc — green.

**Wave 4 polish — git stash list + reflog pickers (2026-05-18 cont.):**
two long-asked-for Git pickers landed together. (1) **Stash list** —
new `crate::git::stash::list` runs `git stash list --pretty=%gd%x09%gs`
+ `parse_stash_message` splits "WIP on <branch>: <hash> <subject>"
(auto form) / "On <branch>: <message>" (user-message form) into
`StashEntry{ stash_ref, branch, subject }`. New
`crate::git::stash::{apply, drop_stash}` operate on `stash@{N}`
selectors. Two new picker kinds: `PickerKind::StashesApply` (accept
⇒ `git stash apply <ref>` — keeps the stash, vim canon) and
`StashesDrop` (accept ⇒ `git stash drop <ref>`). Commands
`git.stash_list` (apply) and `git.stash_drop`. Pairs with the
existing `git.stash` (push) + `git.stash_pop` (pop most-recent
unconditionally) so the full stash lifecycle is now navigable
without ever leaving mnml.
(2) **Reflog viewer** — new `crate::git::reflog::list(workspace,
limit)` runs `git reflog -n<limit> --pretty=format:%H%x09%h%x09%gd
%x09%gr%x09%gs` into `Vec<ReflogEntry{ selector, short_hash,
full_hash, op, subject, relative_time }>`. The renderer splits `%gs`
on the first `": "` to separate operation (`commit` / `commit
(amend)` / `checkout: moving from X to Y` / `rebase: aborting`)
from the subject. New `PickerKind::Reflog`; accept ⇒ open the
chosen commit as a diff pane (reuses `open_commit_diff`). The
`HEAD@{N}` selector renders in the dim detail column so the user
can copy it for a manual `git reset --hard HEAD@{N}` from a pty
if they want to actually rewind to that state. Useful for "I
just rebased and lost a commit, find HEAD before the rebase"
recovery flows. Capped at 200 entries (clamped 1..1000).
668 lean / 702 private lib tests (+5 new across stash + reflog),
87 e2e, 7 ipc — all green.

**Wave 3 polish — image follow-ups + AI per-call config (2026-05-18 cont.):**
finishing the rough edges on yesterday's MVPs. (1) **JPEG / GIF /
WebP / BMP support** — added the `image = "0.25"` crate (default
features off; explicit `png`/`jpeg`/`gif`/`webp`/`bmp`). New
`ImageData.png_bytes: Option<Arc<Vec<u8>>>` cache + `pixel_size`
slot. `ImageData::ensure_png_bytes()` is lazy: PNG sources return
`Arc::new(self.bytes.clone())` and parse the IHDR chunk for size
(cheap, 24 bytes); other formats decode via `image::load_from_memory`
and re-encode as PNG once. Kitty + iTerm2 both accept the cached
PNG payload, so the second `terminal.draw()` flushes the already-
transcoded bytes (no per-frame decode). 50 MB hard cap survives.
(2) **iTerm2 inline-image protocol emission** — new
`crate::image::iterm2::encode_placement` wraps the PNG bytes in an
OSC 1337 escape (`\x1b]1337;File=inline=1;width=Nc;height=Nr;
preserveAspectRatio=1:<base64>\x07`). `tui.rs::emit_image_placements`
now dispatches to either Kitty or iTerm2 based on the detected
protocol. iTerm2 is the standard macOS dev terminal, so this opens
image previews to a big audience without needing Kitty / WezTerm.
No chunking — iTerm2 reads the OSC string in one go, unlike
Kitty's 4 KB chunk cap. (3) **AI per-call config** — `[ai] model =
"claude-sonnet-4-6"` lets users override the API backend's default
model (was hardcoded `claude-opus-4-7`). `[ai] system_prompt = "..."`
prepends a system prompt to every API-backend request (the `system`
field on `/v1/messages`). Both read at job-spawn time so changing
the config and re-firing picks up the new values without restart.
CLI backend ignores both (the `claude` binary picks its own
defaults). New `App::ai_model()` + `ai_system_prompt()` accessors.
Refactored `api_client::stream_to_channel` signature: now takes
`Option<&str>` for both model and system; old signature lost the
`model` param (it was already there but only as `Option`). The
Kitty `encode_placement` signature also changed: takes `&[u8]` of
PNG bytes directly (the format dispatch moved upstream into
`ensure_png_bytes`), so callers don't need to branch on
`ImageFormat::Png`. 663 lean / 697 private lib tests (+1 across
image + ai_api — the kitty refactor dropped one "refuses non-PNG"
test that no longer applies, iterm2 added two). 87 e2e, 7 ipc —
all green.

**Image rendering + AI SDK direct-HTTP backend (2026-05-18 cont.):**
two of the three big "deferred" tracks landing as foundation cuts.
(1) **Image rendering (Kitty graphics, PNG-only MVP)** — new
`crate::image` module + `Pane::Image` variant + `ui::image_view`
renderer + post-`terminal.draw()` escape emission in `tui.rs`.
`crate::image::detect_protocol()` checks `$KITTY_WINDOW_ID` /
`$TERM` / `$TERM_PROGRAM` and returns
`ImageProtocol::{Kitty, Iterm2, None}`; mnml stores the result on
`App.image_protocol` at startup. The renderer reserves the pane
area + stages a `PaintRequest` (when a protocol is supported); after
`terminal.draw()`, `tui.rs::emit_image_placements` moves the cursor to
the area's top-left via `\x1b[<row>;<col>H` and writes the Kitty
escape directly to stdout. `crate::image::kitty::encode_placement`
handles chunked base64 (4000 chars/chunk, m=0/1 continuation), pinned
to `f=100` (PNG pass-through). Other formats (JPEG/GIF/WebP/BMP)
render the metadata-only fallback — supporting them would need an
image-decode crate to convert to RGBA. The metadata-only banner shows
the file path, byte size, and a hint ("preview requires Kitty or
iTerm2 inline-image protocol; supported terminals: Kitty / WezTerm /
Ghostty / iTerm2 / recent Konsole") so users without a graphics-
capable terminal know what they're missing. iTerm2 protocol detection
works; emission is not yet wired (falls through to the fallback).
Auto-routing: `open_path` checks `is_image_extension` (png / jpg /
jpeg / gif / webp / bmp) and routes to `open_image_pane` instead of
the Buffer path so the file-tree's Enter / Ctrl+P open / right-click
all just work. Pane keys: `i` toggles the metadata header, `r`
reloads from disk, Esc → tree. 50 MB hard cap on file size so a
stray click on a multi-GB raw file doesn't OOM. Per-frame `clear_all`
escape ensures stale images don't linger when panes close. tmnl
(mnml's usual host terminal) doesn't implement Kitty yet, so the
fallback shows in that case — but the plumbing is structurally in
place so the moment tmnl adds Kitty support this lights up.
(2) **AI SDK — direct HTTP to api.anthropic.com** — new
`crate::ai::api_client::stream_to_channel` posts to `/v1/messages`
with `stream: true`, reads SSE events, forwards `text_delta`s as
`AiMsg::Delta`s through the same channel the existing `claude -p`
backend uses, then a final `AiMsg::Done`. Reqwest blocking (same
dep mnml's HTTP track already uses; no new SDK dependency). Reads
`$ANTHROPIC_API_KEY`; missing key ⇒ `AiMsg::Failed` with a hint.
New `AiBackend::{Cli, Api}` enum + `[ai] backend = "cli" | "api"`
config (default `cli` so users without an API key see no change).
`App.ai_backend()` reads the config; `spawn_ai_job` dispatches to
the right backend. New `ai.toggle_backend` palette command for
runtime flipping (doesn't persist — restart re-reads from disk).
Every `ask_ai` consumer (explain / fix / refactor / write_tests /
ask / commit-message generation) routes through `spawn_ai_job` so
all flows pick up the toggle automatically. Tool use is NOT wired
in the MVP — for agent flows (file reads, shell, refactor across
files) the user keeps the CLI backend. Direct-API shines for short
asks: commit messages, "explain this", quick refactors. The legacy
explicitly-deferred note in `mnml-deferred-nvchad-tracks.md` is
now satisfied for the "short asks" use case; `Codex commit` still
shells out (`codex exec` has no public direct-HTTP equivalent).
Model is hardcoded to `claude-opus-4-7`; per-call override via
`stream_to_channel(prompt, Some("claude-sonnet-4-6"), ...)` is
wired but not yet plumbed through `spawn_ai_job`. 3 new unit tests
cover the SSE delta parser (text-only / tool-use filtered out /
malformed JSON resilience).
662 lean / 696 private lib tests (+7 new across image + ai_api),
87 e2e, 7 ipc — all green.

**Git GUI — graphical-Git-GUI-style graph pane + hash-jump + tags (2026-05-18 cont.):**
three Git tracks landed together. (1) **`Pane::GitGraph` visual
refresh** — restructured the per-commit row from one flowing line
(`▶ <graph> <hash> [chips] <subject> · <age> · <author>`) into a
columnar layout closer to a popular Git GUI: `▌ ▶ BRANCH/TAG  <graph>
COMMIT MESSAGE                       AUTHOR    AGE    SHA`. Each row
now starts with a 1-cell `▌` swimlane indicator in the commit's lane
color (the "this row belongs to <color> branch" visual cue without
needing alpha-blend bg tints). The branch/tag chip column is fixed-
width (up to 28 chars, ellipsis-truncated with a `+N` overflow chip);
the right side gets fixed-width `AUTHOR` (14) · `AGE` (6) · `SHA` (9)
columns that right-align so every column lines up vertically across
visible rows. New `compute_column_widths(total, graph_w) → ColWidths`
shrinks right-to-left when the pane is narrow (sha → age → author →
branch). A new column-header row above the body shows faint
`BRANCH/TAG · GRAPH · COMMIT MESSAGE · AUTHOR · AGE · SHA` labels.
(2) **Hash-typing to pick a commit** — `/` in the graph pane enters
`hash_filter_mode`; printable hex chars accumulate on
`GitGraphPane.hash_filter` and the renderer flips the COMMIT MESSAGE
header label to `/abc_` (yellow, bold) so you see what's being typed.
Each keystroke fires `find_by_hash_prefix` (case-insensitive prefix
match against full hashes) and `jump_to`s the result. Backspace
walks back; Enter accepts (keeps the selection, drops filter mode);
Esc clears + exits. Toast on no-match so you know you've drifted off.
(3) **Tag commands** — new `crate::git::tag` module: `create_annotated`
(`git tag -a <name> -m <msg> [<commit>]`), `create_lightweight`
(`git tag <name> [<commit>]`), `delete_local` (`git tag -d <name>`),
`delete_remote` (`git push origin :refs/tags/<name>`), `push_all`
(`git push --tags`), `list` (`git tag --list --sort=-creatordate`).
Three palette commands: `git.tag` (prompt for name; targets the
selected graph commit or HEAD), `git.tag_delete` (picker over local
tags), `git.push_tags`. Ex aliases `:tag [<name>]` / `:tags` (list
toast) / `:PushTags`. Tag-on-selected-graph-commit works because the
prompt's accept reads `selected_graph_commit_hash()` at accept time.
New `PromptKind::GitTag`, `PickerKind::GitTags`. 655 lean / 689
private lib tests (+3 unit in `git/tag.rs`, +6 helpers in
`git_graph_view.rs`, +1 in `git/graph.rs` for the hash lookup).

**Git GUI phase 4 — sync triad + cherry-pick / revert (2026-05-18 cont.):**
the five most-asked-for daily git ops that weren't wired. New module
`crate::git::sync` (shells out to `git`, returns `Result<summary,
error>` in the established style): `fetch_all` runs `git fetch --all
--prune`; `pull_ff_only` runs `git pull --ff-only` (refuses on
divergent histories instead of producing surprise merge commits);
`push` runs `git push` (no `--force` — force-push intentionally not
exposed; users who need it drop to a pty); `push_set_upstream` is the
first-push fallback for branches without a tracked upstream. New
`commit::cherry_pick` + `commit::revert` operate on the selected
`Pane::GitGraph` commit. Five new palette commands: `git.fetch` /
`git.pull` / `git.push` / `git.cherry_pick` / `git.revert`. `git.pull`
refuses when unsaved buffers are open (pull rewrites tracked files;
in-mnml edits would silently conflict). `git.push` auto-detects the
"no upstream" error from a bare `git push` and falls back to
`--set-upstream origin <current>` for the first push of a fresh
branch. Conflict cases on cherry-pick / revert / pull surface git's
own message in the toast — the user resolves + continues from a pty.
Two new unit tests cover sync.rs (no-remote fetch is a no-op success;
first-push with set-upstream against a bare repo works). 644 lean /
678 private lib tests (+2 new).

**Wave 3 polish — PR badge + outline depth + stale-doc cleanup (2026-05-18 cont.):**
two real features + several stale-doc / stale-TODO cleanups.
(1) **Statusline PR badge** — when the current branch has an open PR/MR
across any of the four configured SCM hosts (BB / GH / GL / AZ), the
statusline left side now shows a `BB#123` / `GH#42` / `GL!7` / `AZ#9`
chip in purple. Reuses the existing `App.git_rail.pulls` lookup
(populated by `refresh_rail_pulls` against the per-host caches). Zero
new state — same is_current_branch flag the rail's PR section already
uses. (2) **Regex outline depth** — `extract_symbols` used to emit
every symbol at `depth: 0`, so nested methods inside classes / impls
rendered flat. New `indent_depth(line)` heuristic: each leading tab = 1
level + (leading spaces / 4) = 1 level (capped at 8). Methods inside
`impl S {` / `class Foo:` etc. now indent under their parent in the
outline pane. 3 new tests (`indent_depth_counts_tabs_and_spaces`,
`rust_impl_methods_get_depth_1`, `python_class_methods_get_depth_1`).
**Stale-doc cleanups**: bufferline TODO (every item in the cluster
shipped); statusline TODO (git chip's `+N ~N -N` + ahead/behind are
already wired; only the PR badge was missing — now done); editorconfig
brace-expansion limitation note (now supported); `:r path` TODO (was
shipped); DAP drain-events doc claim that output "surfaces as toasts"
(actually goes to `dap_output_log` for the Pane::Debug output
section). 642 lean / 676 private lib tests (+3 new).

**Real-bug polish — toggle-comment for HTML/CSS + editorconfig brace
expansion (2026-05-18 cont.):** two genuine bugs found while surveying
TODO markers. (1) **`ToggleLineComment` on HTML / CSS / XML / Vue /
Svelte / Astro** used to prepend `<!-- ` with no closing `-->` —
corrupting files. Editor now tracks a `comment_token_close` field
(empty for line-comment languages like Rust / Python / Lua; non-empty
for block-comment families). `comment_token_for(ext)` returns
`(open, close)`. The `ToggleLineComment` arm splices the close at EOL
(rightmost edit first so byte offsets stay valid) and strips both
tokens on untoggle. Round-trip safe. New unit tests cover HTML
(`<!-- foo -->`) + CSS (`/* foo */`). (2) **`.editorconfig` brace
expansion + char classes** — patterns like `[*.{js,ts,jsx,tsx}]` (the
most common shape in real configs) used to silently match nothing.
New `expand_braces(pattern) -> Vec<String>` walks depth-aware braces
and expands `{a,b}` to alternatives — handles nested `{a,{b,c}}` and
multi-group `{a,b}-{c,d}` (cartesian product). `glob_match` grew a
char-class arm (`[abc]` / `[a-z]` / `[!abc]` / `[^abc]` for negation).
Updated existing "skipped safely" test → real matching assertion; 3
new tests cover brace expansion + char class. 639 lean lib tests
total (+5 new).

**Polish wave 2 — 5 bounded items (2026-05-18 cont.):** (1) **Reverse-
debugging DAP commands** — `DapClient::step_back` + `reverse_continue`
hitting the `stepBack` / `reverseContinue` DAP requests; palette
commands `dap.step_back` / `dap.reverse_continue`. Only meaningful
on adapters that support record-replay (rr / lldb-rr); unsupported
adapters return `success: false` which flows through the existing
generic `DapEvent::Failed` toast. (2) **Multi-item call-hierarchy
picker** — `prepareCallHierarchy` may return multiple items when the
cursor straddles overloaded fns. New `PickerKind::CallHierarchyItems`;
the picker shows each candidate as `<name>  <rel>:<line>` and accept
fires the chosen-direction follow-up against the picked item. Single-
item case still auto-dispatches (no UI change for the common path).
(3) **Smarter fold tracking on multi-edit batches** — `apply_edit_ops`
used to wholesale-clear `Buffer.folds` on any change. Now it snapshots
`at_line` per-op (the start-byte's line for `ReplaceRange` ops; the
cursor's line otherwise) + the line-count delta, and calls
`shift_folds_after` per-op so folds survive LSP-rename / find-replace
runs that don't cross fold boundaries. Two new unit tests cover the
line-preserving and line-shifting cases. (4) **Request-pane Body tab**
inserts a literal `\t` character (typing indented JSON / XML is the
common use). Other fields keep the form-cycle gesture; Shift+Tab
everywhere still cycles back. Stale Tab-cycle help text + doc comment
updated to mention Headers (the cycle is URL → Method → Headers → Body
→ URL, not the old 3-field form). (5) **Snippet session Shift+Tab fix**
— the session handler matched `KeyCode::Tab` without inspecting
modifiers, so on modern terminals that synthesize `Tab+Shift` (vs the
legacy `BackTab` code) `Shift+Tab` was firing forward-step instead of
backward. Added the `Shift+Tab → snippet_prev_placeholder` arm
explicitly. New e2e (`snippet_backtab_visited.test`) covers the
visited-stop Backtab-to-end-of-typed-content path that was silently
broken on most terminals. 87 e2e total.

**DAP setVariable + REPL filter + cookies/storage value-only copy (2026-05-18 cont.):**
three more bounded items. (1) **`s` in the variables panel** opens a
prompt seeded with the row's current value; accept fires `setVariable`
against `(parent_ref, name, new_value)`. Required adding `parent_ref:
i64` to `VarRow` (populated in `variable_rows()` + `walk_var()` —
0 for scope rows, scope's ref for top-level vars, parent var's ref for
nested children) so the request has full routing context (DAP's
`setVariable` targets the parent's ref + a name, not the child's own
ref). New `DapClient::set_variable(parent_ref, name, value)` request
using `send_request_full` with `aux = parent_ref` + `aux_str = name`;
new `DapEvent::SetVariableDone { parent_ref, name, value, ty,
variables_ref }` reply event; new `setVariable` arm in the reader's
response match table. App's `apply_dap_event` patches the cached
child in place (`mgr.variables[parent_ref].iter_mut().find(name)`)
+ toasts confirmation. Errors flow through the existing generic
`DapEvent::Failed` toast path. New palette command `dap.set_variable`.
(2) **`/` in the DAP REPL pane** enters filter mode — mirrors the
cookies / storage / net / DOM filter UX. Filter triggers only when
the input is empty (so `/` stays a literal in division / path
expressions) OR a row is selected. `DapReplPane` gained
`filter: String` + `filter_mode: bool` and a `visible_history_indices()`
helper that fuzzy-matches via `crate::fuzzy::fuzzy_match` against
`entry.expression`. Renderer shows the narrowed view + a filter
chip on the header; `dap_repl_select_move` walks the visible (post-
filter) indices so the cursor never lands on a hidden row. Esc
cascade: clears filter, then clears row selection, then bails to
tree. (3) **`c` in the cookies + storage panels** copies just the
value (no `name=` / `key=` prefix). Common when the value is a
session token / JWT the user wants to drop directly into code. `y`
keeps the existing `name=value` pair behavior. Help text on both
panels updated to differentiate (`y pair · c value`). Two new e2e
tests (`dap_set_variable.test`, `dap_repl_filter.test`); 86 e2e
total. VarRow test extended to assert `parent_ref` values.

**the private integration phase 8 — DocDB ↔ CodeBuild correlation (2026-05-18 cont.):**
the CodeBuilds pane now surfaces an inline test-execution chip on each
row (`· ✓N ✗M ≈K ⊘L` aggregated across every TE record that matches
the build). New App-level cache `App.private_executions: HashMap<String,
TestExecutionRecord>` populated alongside `Pane::TestExecutions` in
`drain_docdb_events` so the chip works without forcing the TE pane
open. `open_codebuilds_pane` side-spawns the DocDB worker when not
already running so records stream into the cache from the start. New
pure free function `crate::private::correlate_executions_with_build`
implements the matcher — primary on `te.build_id ==
build.build_number.to_string()`, fallback on `te.started_at_ms` in
`[build.start, build.start + duration + 30min]` AND `te.branch` matching
`build.source_version` (exact or 7-char SHA prefix, case-insensitive;
ARN source_versions disable the branch path). The `x` chord on a
CodeBuilds row now uses the matcher so jumping to the matching TE
record works even when `build_id` isn't populated. 7 new unit tests
cover build_id exact match, branch+time-window fallback, short SHA
prefix, time-window exclusion, ARN-disables-fallback, no-match, and
multi-env-same-build. 668 lib tests under `--features private`, all
passing.

**DAP vars copy/watch + CDP filter parity (2026-05-18 cont.):** three
more bounded items. (1) **`y` in debug variables panel** copies the
selected row's value (or label when no inlined value) to the system
clipboard; toast confirms with the first 40 chars. (2) **`w` in debug
variables panel** promotes the selected variable's name into a watch
expression (strips ` : type` suffix to get just the bare name).
Pre-existing watches are detected + skipped with a toast. Fires
immediate eval against the current top frame so the watch row
populates without waiting for the next stop. (3) **CDP cookies +
storage filters** — `/` while focused enters filter mode (Backspace
pops, Enter applies, Esc clears), mirroring the existing net + DOM
filter UX. New `visible_cookies_indices` / `visible_storage_indices`
match against `name=value · domain · path` / `[L|S] key=value` via
`crate::fuzzy::fuzzy_match`. Selection now indexes into the filtered
list (sel clamps against `visible.len()`), and the header hint
shows `N/M` while a filter is held. Esc-clears-filter wired into
the browser pane's existing two-step UX. Two new unit tests verify
the filters narrow correctly. 642 lib+integration tests + 84 e2e,
all passing.

**REPL lazy-expand + tree-sitter perf (2026-05-18 cont.):** three more
small wins. (1) **DAP REPL lazy-expand** — `DapReplEntry` now tracks
`variables_ref` + `expanded` slots, populated when the `evaluate`
reply arrives. New `DapReplPane.selected: Option<usize>` for row
focus; `Shift+Up`/`Shift+Down` move it (plain Up/Down still walks
command history). `o` on a selected row toggles expansion — first
press fires `variables(variables_ref)` (cached on `DapManager.variables`,
shared with the variables panel); children render indented below the
result. Tail-pinned scroll math now walks backward from the end
counting `entry_render_rows` so an expanded row at the bottom still
fits without bumping older entries off-screen. (2) **Tree-sitter
syntax perf** — `line_color_grid(spans, line_width)` pre-bakes a
per-cell color array once per row (O(sum_of_span_widths +
line_width)); the per-cell loop now does O(1) indexed lookup instead
of the prior `spans.iter().rev().find(...)` linear scan. For a 200-
char Rust line with 60 spans that's a 60× per-cell reduction. Caller
falls back to the old helper for OOB cells. 3 new tests verify the
grid matches the linear-scan output, handles empty input, and clips
spans past EOL. (3) **DAP REPL selection e2e** — `dap_repl_selection.test`
covers the Shift+Up → row focus → Esc → input-focus cycle. 84 e2e
tests total, 640 lib/integration tests, all passing.

**DAP exception breakpoints + hit-count breakpoints (2026-05-18 cont.):**
finishing the last two real DAP gaps. (1) **Exception breakpoints** —
new `setExceptionBreakpoints` request + `DapEvent::InitializeCaps
{ exception_filters }` captured from the `initialize` reply. New
`ExceptionFilter { filter, label, default }` struct; cached on
`DapManager.exception_filters` + `enabled_exception_filters`. App
auto-enables any filter with `default = true` (debugpy's "uncaught"
is typical) immediately after init. New `dap.exceptions` opens a
picker over the cached filters with `●`/`○` markers showing the
current state; accept toggles that one filter + re-fires
`setExceptionBreakpoints` with the new enabled set. (2) **Hit-count
breakpoints** — new `Buffer.breakpoint_hit_conditions` parallel to
`breakpoint_conditions` (DAP supports both per line, independently).
`DapClient::set_breakpoints_with_conditions` grew a fourth arg for
the hit-condition map; all three call sites updated. New
`dap.set_breakpoint_hit_count` opens a prompt seeded with any
existing hit-condition; accepts expressions like `">= 5"` (stop
after 5+ hits) or `"% 10"` (every 10th hit). Empty input clears the
hit-condition without removing the BP. Persisted in
`SavedBuffer.breakpoint_hit_conditions` with the same orphan-line
cleanup as conditions. Two new e2e tests cover the no-adapter
graceful-toast path (`dap_exception_breakpoints.test`) and the
prompt flow (`dap_hit_count.test`) — 83 e2e tests total.

**CDP snapshot diffs + DAP test coverage (2026-05-18 cont.):** two more
items shipped. (1) **CDP snapshot diffs** — new `BrowserSnapshot
{ label, url, net, cookies, storage }` and `browser.snapshot` command
that freezes the active browser pane's state into
`BrowserPane.snapshots` (capped at `SNAPSHOT_MAX = 5`, oldest FIFO).
`browser.diff_snapshot` toggles a diff panel that compares the
most-recent snapshot vs the current live state — set-diff per
collection. URL changes show as a section. Network entries diff by
`(method, url)`: pure adds + removes plus a "changed" line for
status-only deltas. Cookies diff by `(name, domain, path)` with
value/flag changes surfacing as "changed". Storage diffs by
`(is_local, key)` with value changes as "changed". Renderer paints
section headers bold, `-`/`+`/`~` glyphs in red/green/yellow.
Keyboard chords `X` (capture) and `x` (toggle diff) when no other
panel is focused; Esc closes the diff first then walks back to the
tree. `browser.clear_snapshots` drops them all. Capture refreshes
cookies + storage fire-and-forget so the snapshot has the latest
server state. Cookies / storage labels use a per-process local-time
HMS via env-var-only resolution (no shell-out from this hot path).
4 new unit tests cover the diff logic (add/remove/change detection,
empty diff when unchanged, no-snapshot returns None, cap enforced).
(2) **DAP `.test` coverage** — three new e2e tests cover the new DAP
surface area: `dap_conditional_breakpoint.test` exercises the
conditional-breakpoint prompt flow (no live adapter needed — the
buffer state + toast still work); `dap_watches.test` adds a watch
expression via the prompt + the remove-picker round-trip;
`dap_repl_pane.test` opens the REPL pane and submits an expression
(no session → "no DAP session" feedback row, plumbing verified).
The existing `browser_commands_no_pane.test` grew to cover the new
`browser.snapshot` / `diff_snapshot` / `clear_snapshots` no-pane
paths. 81 e2e tests total, all passing.

**DAP completion wave + indent text objects + semantic perf (2026-05-18 cont.):**
five bounded items in one push. (1) **DAP attach workflow** — new
`dap.attach` command opens a picker over `ps -eo user,pid,command` output
(`AttachableProcess { pid, user, cmd }`). Accept reuses the existing
`dap_run` adapter-spawn / init handshake but forces `request: "attach"`
+ injects `pid` into the launch body — the user's `[dap.<lang>].launch.*`
fields (host/port/etc) survive for remote-attach configs. (2) **DAP
multi-thread UI** — new `DapEvent::Threads(Vec<ThreadInfo>)` + auto-fired
`threads` request on every `Stopped` so `DapManager.threads` always
reflects the current set. `dap.pick_thread` opens a picker over them
(active thread chipped with `●`); accept switches `App.dap_thread` +
re-fetches the stack trace for the new thread. Single-thread programs
toast "only one thread" instead of opening a useless picker. (3) **DAP
REPL pane** — new `Pane::DapRepl(DapReplPane)`: persistent
`(expression, value)` history list + single-line input. `dap.repl`
opens (or focuses) the pane. Enter fires `evaluate` with
`context: "repl"` — the same channel watches use, so adapter REPL
shorthands (debugpy's `pp`, gdb's `info`) work. Pending entries
render `(evaluating…)`; errors render in red; results green (with
type when known). Up/Down walks command history. Watch + REPL share
`DapEvent::Evaluate` — the App routes the reply to whichever pane is
expecting it, matching by `expression` string. Custom bufferline glyph
(nf-md-console `\u{F018D}`). (4) **Python/Ruby indent text objects**
— `if`/`af` / `ic`/`ac` now work in indent-scoped languages. New
`Editor::enclosing_indent_scope(ext, header_kinds, inner)` walks
forward from the header line until the first non-blank line whose
indent ≤ the header's; that's the body extent. For Ruby, the closing
`end` line is included in `around` mode (matches vim convention).
Python is pure-indent. The SelectInner/AroundFunction + Class arms
branch on `ext ∈ {py, rb}` to pick indent-scope vs the existing
brace-scope path. (5) **Semantic tokens perf** — replaced the linear
scan-per-cell in `semantic_style` with a per-line projection
(`tokens_for_line(tokens, line)`) sorted by `start_char` + a
binary-search inside `semantic_style`. The per-line list is built
once before each row's cell loop. For a 12k-line file with 50 tokens
per line, the per-row cost drops from O(total_tokens × cols) to
O(tokens_on_line + log(tokens_on_line) × cols) — the difference
between syntax highlighting blocking a render frame and not. Tests
verify the binary-search-with-sort path catches every column it
should + the right token wins when multiple are on the same line.

**DAP watches + conditional breakpoints + CDP detail panel (2026-05-18 cont.):**
finishing the queued bigger tracks. (1) **DAP watch expressions** — new
`DapClient::evaluate(expression, frame_id, context)` request + `DapEvent::Evaluate
{ expression, value, ty, err, variables_ref }` reply (echoes the input expression
via a new `aux_str` field on `PendingReq` so the reader can route the reply to
the right row). `App.dap_watches: Vec<String>` + `App.dap_watch_results:
HashMap<String, WatchResult { value, ty, err }>`. Auto-re-eval on every
`StackTrace` against the top frame so the panel always reflects the current
stop. Failed evals (`name 'foo' is not defined` etc.) land on the watch row's
`err` slot — red text in the panel — instead of toast spam. Watches render as
the top section of the variables panel with a `👁` prefix; counts surface in
the panel title. Results clear on `Continued`; the expression list survives
terminates. Commands `dap.add_watch` (prompt) / `dap.remove_watch` (picker —
detail shows current value or err) / `dap.clear_watches`. Watches persisted in
session.json (`SavedSession.dap_watches`). (2) **Conditional breakpoints** —
`Buffer.breakpoint_conditions: HashMap<u32, String>` parallel to `breakpoints`;
`DapClient::set_breakpoints_with_conditions(source, lines, conditions)` wraps
each line as `{ line, condition }`. The condition map persists in session.json
(`SavedBuffer.breakpoint_conditions`) and gets re-applied via the conditional
setter on `Initialized`. Gutter renders `◆` (diamond) for conditional vs `●`
(circle) for plain — wins over plain BPs in the sign-column priority chain.
`dap.toggle_breakpoint_conditional` (`Shift+F9`) opens a prompt seeded with
the existing condition (if any); empty input ⇒ plain BP. Toggling a BP off
also drops its condition. (3) **CDP request-detail panel** — `i` while
net-focused splits the network panel: rows on top, per-request detail on the
bottom (request line · headers · body · response status · mime · failure
reason). New `NetEntry::detail_lines() -> Vec<String>` is the formatter;
`BrowserPane.net_detail_open` / `net_detail_scroll` are the state; `[`/`]`
scroll within the detail panel (vim pager convention, since `j`/`k` are
taken by row selection). Switching rows resets the scroll. Lets the user
inspect a captured request without re-sending it through a Request pane.

**Bigger tracks NOT done (with reasons):** *Image rendering (Sixel / Kitty
graphics)* — multi-week, terminal-protocol heavy; out of scope for one
session. *AI: real Anthropic SDK client* — `mnml-deferred-nvchad-tracks.md`
memory explicitly notes the user previously deferred this indefinitely;
not touched without re-confirmation. *the private integration phase 8 (DocDB diff alongside
CodeBuild output)* — feature-gated track; queued. *Git GUI phase 4* —
investigation: the branch rail UI, commit-with-Codex (`git.codex_commit`),
recompose-with-AI (`git.ai_recompose`), and multi-repo polish are *all
already shipped* (see earlier Status entries). What's left there is
substantive UX polish rather than missing features — defer to a focused
session.

**Polish + DAP variables (2026-05-18):** four queued NvChad polish items landed
in one sweep. (1) **Vim mode glyph orange tint** — the `\u{e7c5}` diamond-V chip
prefix in the statusline now renders in its own span with `theme.orange` fg (or
`bg_darker` when the mode bg is itself orange — REPLACE mode — to avoid
clashing). The mode label keeps the normal dark-on-color contrast. Tiny visual
accent that makes the vim-mode chips feel distinctly vim-y. (2) **Per-workspace
`view.toggle_hidden`** — formerly propagated to every workspace; now targets
just the workspace section that owns the active repo (computed via new
`App::focused_tree_workspace_idx`). The "toggle everywhere" behavior moved to a
new sibling command `view.toggle_hidden_all`. Both surfaced in the `+toggle`
which-key group at `<leader>th` / `<leader>tH` (the queued default keybinding).
(3) **DAP variables tree** — biggest of the four. New `Scope` + `Variable`
types + `DapEvent::Scopes` / `Variables` round-trip; `DapClient::scopes(frame_id)`
+ `variables(ref)` requests with a new `PendingReq{command, aux}` so the reader
can attach the original ref/frame_id to the reply (DAP responses don't echo
those). On `StackTrace` arrival the App auto-fires `scopes` for the top frame;
on `Scopes` arrival it auto-expands non-expensive scopes and fires `variables`
for each. The `Pane::Debug` layout grew a third section between call stack and
output — a flat-tree variables panel (`DapManager::variable_rows()` walks
scopes → vars → expanded composites recursively into `Vec<VarRow {depth,
is_scope, label, value, var_ref, expanded, expandable}>`). `▾`/`▸` chevrons
mark expandable rows; `=` separates name and value; scope rows render bold;
expensive scopes render dim `(expensive)`. New `DebugSection::{Stack,
Variables}` on `DebugPane` — Tab cycles focus; j/k/PgUp/PgDn/g/G/wheel route
to whichever section is focused; Enter expands/collapses the highlighted var
(in Variables) or jumps to the picked frame *and* re-fires `scopes` for it
(in Stack — so the vars panel follows the user's frame pick). First-expand
of a composite fires `variables`; re-collapse/re-expand reuses the cache.
On `Continued`, scopes + variables + expanded_vars all clear (the refs go
stale at resume). Picking a non-top frame in the stack also re-fires scopes
so the panel shows that frame's locals (instead of the top's). What's still
missing for "complete DAP": watch expressions, conditional breakpoints, a
polished `attach` workflow. Tests: `variable_rows_flattens_scopes_and_expanded_composites`
covers the recursive flatten; `parse_scope_extracts_ref_and_expensive` +
`parse_variable_handles_type_and_ref` + `parse_variable_handles_missing_type`
cover the parsers.

**Multi-root workspaces (phase 2a, 2026-05-17):** new `[[workspaces]]` config
table — `name = "private"`, `path = "~/Projects/private-claude-workspace"` per
entry (path supports `~/`-expansion). Each configured workspace renders as an
additional collapsible `> name` section in the rail below the launched
workspace's own section; its file tree mounts inside that section. Phase 1's
multi-repo decoration applies to each extra workspace's depth-0 dirs too, so a
`[[workspaces]]` pointing at a parent dir containing several sibling repos
opens as a clean list of repo headers under a collapsible workspace header.
Extra sections start collapsed by default and capped at `EXTRA_TREE_MAX_ROWS =
12` body rows when expanded so a deep tree can't crowd out siblings + the
shared GIT section. Repo discovery unions across all workspaces (flat `App.repos`),
so the active repo can be in any workspace — `git.switch_repo` picker + tree
clicks both navigate the union; the GIT rail / status pane / branches / PRs all
keep working unchanged. `Ctrl+P` (file picker) walks every workspace's tree
(primary first, then extras). Click on an extra workspace's `> name` header
toggles its expansion; click on a file/dir inside dispatches the standard
open/toggle, plus active-repo switch when clicking a depth-0 repo dir.
Currently scoped to phase 2a: grep / recents / session-restore for extras' tree
state are workspace-primary only and would land in phase 2b alongside a
workspace-switcher picker and a `view.add_workspace` / `view.remove_workspace`
runtime command set.

**Multi-repo tree decoration (phase 1, 2026-05-17):** when the workspace
contains more than one git repo, the depth-0 repo dirs in the file tree now
render as distinct "repo headers" rather than regular folders. Each gets the
`` (nf-dev-git) glyph (ASCII fallback `▶`/`▼`), a yellow name, and a leading
`● ` (active) or `○ ` (non-active) marker — same visual language the git rail
uses for branches. Non-active repos render dimmed. On launch, only the active
repo's dir is auto-expanded (via new `Tree::expand_only`); other repo dirs
render collapsed, so the tree opens with a clean list of repo headers the user
can drill into. Clicking a depth-0 repo dir in the tree both expands/collapses
it AND switches `active_repo` (so the git rail / branches / PRs follow the
user's tree focus — keeps the picker gesture in sync with the visual one).
Single-repo workspaces are unchanged. Phase 2 (multi-root workspace config —
multiple workspaces stacked, each with their own repos) is queued; would need
a config table + cross-workspace scope for find/grep/recents/session.

**Tab pages polish wave (2026-05-17):** lots of follow-up after the
initial `:tab*` ex commands landed. Headline additions:
* `Ctrl+W T` (`view.move_to_new_tab`) — vim canonical: pluck the
  active leaf out of the current tab's layout and insert it as a
  single-leaf new tab page. Old tab collapses via `remove_leaf`.
* `Alt+1`..`Alt+9` chords + 9 `tab.goto_N` palette commands for
  direct tab jumps (NvChad / iTerm convention). Out-of-range
  indices are no-ops.
* `tab.picker` / `PickerKind::Tabs` — fuzzy picker over open tab
  pages; each row labels tab N + headline pane title + a `● dirty`
  chip when any pane in the tab has unsaved changes. Active tab
  sorts last (mirrors buffer picker's "alternate buffer" pattern).
* `tab.reopen` (`:tabreopen` / `:tabundo`) — pops the most-recently-
  closed tab off `App.closed_tab_layouts` (cap 20) and re-inserts
  the layout after the active tab. `remove_pane_storage` now shifts
  PaneIds in the closed-tab stack too so a re-opened layout doesn't
  point at the wrong pane after a separate `close_pane`.
* `[count]gt` / `[count]gT` — vim `gt` chord now consumes a pending
  count: bare cycles, with N jumps absolute (`5gt` → tab 5). Routes
  through `:tabnext N` / `:tabprev N` (which themselves now accept
  counts).
* `:tabdo {cmd}` — actually iterates tab pages now (was an alias for
  `:bufdo` since mnml lacked real tabs). Switches to each tab in
  turn, runs the command in that tab's window, leaves the cursor
  on the last tab.
* `tab.move_left` / `tab.move_right` — palette wrappers for
  `:tabmove -1` / `:tabmove +1`.
* `:tabs` now toasts pane names alongside the tab number (e.g.
  `●1 a.txt · ○2 b.txt`).
* Bufferline tab chip — leading `●` glyph when any pane in the tab
  is dirty (`App::tab_has_dirty_buffer(idx)`). right_w + chip rects
  scale with digit count so 10+ tabs no longer overlap the buffer
  strip.
* `tab_new(Some(path))` — when the path is already open in another
  tab, switch to that tab instead of leaving an orphaned empty tab
  behind. Mnml is file-deduped (one pane per path).
* `reveal_pane` — when the target pane lives in a non-active tab's
  layout, switch tabs instead of duplicating the leaf reference
  (preserves the "each pane in at most one leaf across all tabs"
  invariant).
* `layout::shift_after` — now handles `Leaf(removed)` by setting it
  to `Empty` and collapses splits whose child became Empty. The
  pre-multi-tab world never had leaves pointing at the removed pane
  (close_pane removed them first); with multi-tab + the closed-tab
  stack, other layouts can hold such leaves and would otherwise
  silently re-bind to the wrong pane after shift.
* Zen mode + `:set nobufferline` — both now clear the new tab-page
  right-cluster rects so stale rects from the prior frame don't
  catch clicks.

**`:tabmove [N]` (2026-05-17):** vim canonical for reordering tabs.
Accepts bare or `$` (→ last), `0` (→ first), 1-based absolute N, or
relative `+N` / `-N`. Out-of-range clamps. `:tabm` alias. The
underlying primitive is `App::tab_swap(a, b)` which also powers
bufferline drag-to-reorder (`App::dragging_tab_page` set on chip
mousedown, swaps on drag over a different chip's rect, cleared on
left-up — symmetric with the tmnl chip drag-to-reorder).

**Multi-tab session persistence (2026-05-17):** `SavedSession` gained
`layouts: Option<Vec<Option<SavedLayout>>>` + `active_layout:
Option<usize>` (new), keeping the existing `layout: Option<SavedLayout>`
populated with the active tab's layout for back-compat with older mnml
binaries reading the same session.json. Save writes one entry per tab
page in display order; restore prefers `layouts` when present and falls
back to legacy `layout` as the only tab when not. New `tab_actives` is
seeded from each restored layout's `first_leaf` so per-tab focus comes
back. Tabs whose SavedLayout can't be remapped (a leaf pointing at a
buffer that no longer exists) fall back to `Layout::Empty`. Coverage:
new test `session_round_trips_multi_tab_layouts` in `app.rs::tests`
(opens two tabs with different files, saves, restores, asserts both
layouts + the previously-active index land).

**Bufferline right cluster (2026-05-17):** NvChad-style chrome on the right
side of the bufferline strip — `+` new-tab (purple, `tab.new`), `TABS` label
(blue, decorative), per-tab-page chips (active = yellow + bold, non-active =
`bg2` with a red `⊗` close button), `◯` theme toggle (opens `theme.pick`),
`×` close-active-pane (red). The prior statusline `tab N/M` chip is gone —
the right cluster carries the tab info visually. All segments are click-
targetable: `bufferline_new_tab_button`, `bufferline_tab_page_chips: Vec<(Rect,
tab_idx)>`, `bufferline_tab_page_close: Vec<(Rect, tab_idx)>`,
`bufferline_theme_toggle`, `bufferline_window_close` on `UiRects`. New
`App::tab_close_at(idx)` closes a specific tab by index (used by the per-tab
`⊗` so closing a non-active tab leaves focus where it was; closing the active
tab clamps to the previous one — vim convention). The bufferline's
`tabs_max_x` math now subtracts the cluster width (3 + 6 + per-tab + 6) so
the per-buffer strip never overlaps.

**Vim tab pages (2026-05-17):** real `:tab*` ex commands, replacing the prior aliases-to-buffer-ops.
`App.layout: Layout` rename → `App.layouts: Vec<Layout>` + `App.active_layout: usize` (each entry is
one tab page's independent split tree) + parallel `App.tab_actives: Vec<Option<PaneId>>` (per-tab
last-focused pane). Accessor methods `App::layout()` / `layout_mut()` keep the call-site diff small
(every `self.layout.foo()` → `self.layout_mut().foo()` for `&mut` methods, `self.layout().foo()` for
`&`; assignments became `*self.layout_mut() = X`). New helpers: `tab_new(Option<&Path>)` /
`tab_close` / `tab_next` / `tab_prev` / `tab_first` / `tab_last` / `tab_only` / `tab_list` /
`switch_tab(idx)`. Ex commands `:tabnew [path]` / `:tabnext` / `:tabprev` / `:tabfirst` /
`:tablast` / `:tabclose` / `:tabonly` / `:tabs` route to those. Palette commands `tab.new` /
`tab.next` / `tab.prev` / `tab.first` / `tab.last` / `tab.close` / `tab.only` / `tab.list` (all
in the `tab` group). Vim `gt` / `gT` chords were aliased to next/prev-buffer; now they fire
`tab.next` / `tab.prev`. Statusline yellow `tab N/M` chip surfaces when `layouts.len() > 1` (the
only visible cue, since the bufferline keeps showing every pane regardless of tab — vim's
"buffers persist when their window closes" model). PaneId shifts on close fan out across every
layout (one removed pane re-indexes leaves in every tab). Session-restore persists only the
active tab's layout (`saved_layout_from(self.layout(), ...)`); multi-tab persistence is a
follow-up. Coverage: new `tests/e2e/tab_pages.test` (open in N tabs, cycle, close, only);
legacy `vim_literal_next_tab_aliases.test` retargeted to `:bnext` / `:bprev` since the tab
aliases now mean something different.

**Cmdline bar (2026-05-16):** new 1-row strip below the statusline (`src/ui/cmdline_bar.rs`,
wired into `ui::draw`'s bottom split which now reserves 2 rows: statusline + cmdline_bar).
Hosts vim's `:` ex-command line (yellow + bold against `bg_darker`) when `pending_display()`
starts with `:`; otherwise mirrors the most-recent live toast dimmed so messages persist in
a known spot instead of just floating top-right. The statusline middle gap no longer
double-shows the `:` cmdline or toasts — it's reserved for the chord-pending state alone
(`d`, `gqap`, `cw`, …). Zen mode (`view.zen`) still skips both rows. No new keymaps —
existing `:` chord opens the cmdline as before; the row is purely a render-side relocation.

**Mixr pane (2026-05-16):** `mixr.show` (`<leader>a M`) opens the sibling `mixr-rs` TUI DJ as a `Pane::Pty`
spawned via new `BinaryProfile::mixr(workspace)` (mirrors `claude_code(ws)` / `codex(ws)` — `mixr --dashboard`
in the workspace cwd). Reuses existing portable-pty + vt100 plumbing — mixr's interactive TUI (keys / mouse /
overlays / colors) renders natively in the pane. Refuses cleanly with a toast when `mixr` isn't on `$PATH`
(new `mixr_on_path()` helper walks `$PATH` rather than pulling in the `which` crate). Paired with mixr-rs
commit `50fdae8` which added a `DashLayout::{Full, Panel}` + `PanelSection::{Queue, History, Browse, Log}`
mode — `v` inside the mixr pane cycles `Full → Panel(Queue) → Panel(History) → Panel(Browse) → Panel(Log)
→ Full` so the embedded view fits any split height. Mixr persists the layout choice in `~/.mixr/config.json`
so the same layout reappears next time the pane opens.

**NvChad-track add-ons (2026-05-16):** seven NvChad-style features landed in one sweep — (1) **startup
dashboard** (NvDash) — when `Layout::Empty`, `ui::welcome` paints an ASCII `mnml` logo + workspace name +
git branch chip + clickable recent-files list + shortcut hints; recent-file rows are click-targetable via
new `app.rects.dashboard_rows` (the `tui::dispatch_mouse` head matches them when no panes are open and
routes to `open_path`). (2) **Flash motion** (leap/lightspeed style) — vim Normal `s<a><b>` enters
`Prefix::Flash1` → `Prefix::Flash2(a)` → escalates `AppCommand::FlashStart(a, b)`; `App::flash_start`
scans the active editor's viewport for case-insensitive occurrences of the trigger pair, assigns each a
1-char label from `LABEL_POOL` (excluding the trigger chars), stashes them on `App.flash_state`; `tui::
dispatch_key`'s top intercepts the next keystroke and routes to `App::flash_consume_char` which jumps the
cursor (pushing nav-back) or cancels. `ui::flash_overlay` paints the labels inline as bg2-on-yellow over
each target's cell. Vim's `s` substitute (= `cl`) is displaced — leap.nvim convention. (3) **Harpoon**
(pinned 1–9 files) — `App.harpoon: [Option<PathBuf>; 9]` persisted in session.json; commands
`harpoon.add` / `harpoon.menu` / `harpoon.goto_1..9`; chords `<leader>1`..`<leader>9` jump, `<leader>H a`
adds active, `<leader>H m` opens a `PickerKind::Harpoon` picker. Idempotent add — re-adding the same
path is a no-op + toast. (4) **Cheatsheet pane** (NvCheatsheet) — new `Pane::Cheatsheet` rendering every
chord → command grouped by `Command::group` via `crate::cheatsheet::CheatsheetPane::build(&keymap)`;
`/`-filter narrows by chord / id / title; `j`/`k`/`PgUp`/`PgDn`/`g`/`G` navigate; Enter runs the
highlighted command. Opens via `view.cheatsheet` / `<leader>?`. (5) **Inline rename preview**
(inc-rename.nvim) — `lsp_rename` now also fills `App.rename_preview_state` with every whole-word
occurrence of the original identifier in the active editor (`collect_whole_word_occurrences` —
single-file MVP); while the prompt is open, `ui::rename_preview_overlay` paints the prompt's current
text inline at each occurrence (green-on-bg_dark, bold). Cleared on prompt accept / cancel; the
post-accept `RenamePreview` picker still handles cross-file scope. (6) **Multi-file diff browser** —
new `DiffScope::AllVsHead` running `git diff HEAD` (covers staged + unstaged in one pane);
`git.diff_all` command + `<leader>g A`; `f` / `F` in the diff pane jump to next / prev file's first
hunk (`App::diff_jump_file`, wraps). Header toast shows changed file count on open. (7) **Inline-
rendered markdown** (render-markdown.nvim) — `[ui] render_markdown = true` (default off; `:set
[no]rendermarkdown` / `view.toggle_render_markdown`); `ui::md_inline_overlay` post-process pass repaints
visible cells of markdown buffers: heading lines bold + depth-colored (red/orange/yellow/green/cyan/blue
for `#`..`######`, `#`s dimmed), `**bold**` (markers dim, inner bold), `*italic*`/`_italic_` (markers
dim, inner italic), `` `code` `` (backticks dim, inner with bg2 background), `[label](url)` (label
underlined blue, brackets/URL dim). Bails when `[ui] wrap` is on (the simple row mapping wouldn't track
wrapped continuation rows correctly). All seven covered by unit tests; 571 tests pass.

P0–P3 done. Working: NvChad-ish layout; editable buffers via
either `StandardInputHandler` (VSCode-style, modeless) or `VimInputHandler` (modal:
Normal/Insert/Visual + `:`-line), swappable at runtime (`editor.toggle_keymap` /
`editor.use_vim` / `editor.use_standard` in the palette, or `:set input=vim`);
`:`-commands (`w q wq x q! wa wqa qa bd bn bp e sp vsp tabnew only pwd sort retab set %s/old/new/[gi] …`)
via `App::run_ex_command` (`:sp [path]` / `:vsp [path]` split + open; `:only` collapses to active
pane; `:pwd` toasts the workspace path; `:tabnew <path>` aliases to `open_path` since mnml has
buffers, not tabs; `:sort [u]` sorts lines [selection or whole buffer; `u` de-dupes]; `:retab`
replaces tabs with `[editor] tab_width` spaces buffer-wide; `:term [cmd]` opens a shell pty
in a split (no arg ⇒ interactive shell, alias for `term.shell` / `Ctrl+T`; with arg ⇒ runs the
command via `BinaryProfile::task`); `:version` toasts the build SHA; `:source <path>` (alias `:so`)
re-applies a config file at runtime [layered on top of current config; rebuilds the keymap; bounces
the input handler if `[editor] input_style` changed]);
**`:%s/old/new/[flags]`** — vim-style global substitute via `parse_substitute` + `App::run_substitute`:
splits on unescaped `/` (`\/`/`\\`/`\n`/`\t` understood inside the fields), `g` is implicit (whole buffer
always), `i` makes the match case-insensitive (`buffer::find_all_ci_ascii` vs `app::find_all_case_sensitive`),
no-replacement form `:%s/foo/` deletes; one undo step + an `:%s — N replacement(s)` toast. Literal-string
match for now — no regex. **Bare `:s/old/new/[flags]`** substitutes only on the cursor's *current line*
(vim convention) — same parser, `Substitute.whole_buffer = false`. The toast prefix changes (`:s` vs `:%s`).
**Vim marks** — lowercase `a`-`z` are buffer-local (`Buffer.marks: HashMap<char, (row, col)>`);
uppercase `A`-`Z` are **global** (`App.global_marks: HashMap<char, (PathBuf, row, col)>`, persisted in
`.mnml/session.json` so they survive a relaunch). Vim normal-mode chords: `m<letter>` sets the mark at
the cursor (`Prefix::MarkSet` → `AppCommand::SetMark(c)` → `App::set_mark_at_cursor`); `'<letter>` jumps
to the mark's row at col 0 (`Prefix::MarkJumpLine` → `AppCommand::JumpToMarkLine`); `` `<letter>`` jumps
to the exact stored `(row, col)` (`Prefix::MarkJumpExact` → `AppCommand::JumpToMarkExact`). Uppercase
jumps `open_path` the marked file first when it isn't the active buffer. Toasts on set / jump / miss;
jumps push the current position onto the nav-back stack so `Alt+Left` returns. `tests/e2e/marks.test`
covers the chord flow.
**Vim `*` / `#`** — find next / prev occurrence of the word under the cursor. Sets the buffer's find
state to that identifier and jumps. Uses `editor::word_under_cursor` for extraction and `accept_find`
+ `find_prev` for the navigation. **Visual mode `*` / `#`** — same idea, but searches for the
literally-selected text (preserves spaces / punctuation / newlines, no word-boundary check). Uses
`editor::selected_text`; routed via `find.selection_forward` / `find.selection_backward` commands.
**Vim `/` / `n` / `N`** — `/` opens the find prompt, `n` jumps to the next match, `N` to the previous.
Routes through the existing `find.find` / `find.next` / `find.prev` commands.
**Vim find-char** — `f<c>` / `F<c>` jump to next/prev `<c>` on the cursor's line; `t<c>` / `T<c>` stop
one cell before. Operator-pending forms work too: `df<c>` deletes up to and including the target,
`dt<c>` stops on the target (vim convention). New `Prefix::FindChar(forward, before)` + new
`EditOp::FindCharOnLine{ ch, forward, before, inclusive }`; the handler sets `inclusive` based on whether
an operator is pending so the deleted/changed range matches vim's exclusive vs inclusive semantics.
`tests/e2e/vim_find_char.test` covers `f` + `dt`.
**Vim Visual `o`** — swap which end of the selection the cursor sits on (so you can extend the *other*
side without redoing the selection). New `EditOp::SwapAnchorCursor`.
**Vim Visual Block (`Ctrl+V`)** — rectangular selection. New `VimMode::VisualBlock` + `Editor.block_anchor:
Option<usize>` (independent of charwise `anchor`). The rect is computed from `block_anchor` and `cursor`
via `Editor::block_selection() → Option<(rmin, cmin, rmax, cmax)>`; `editor_view.rs` paints every cell in
the rectangle (vim convention — extends past EOL too). Motions extend the rect (the cursor moves; anchor
stays). `y` yanks the column slices joined with `\n` (`EditOp::YankBlock`); `d` / `x` deletes them
(`EditOp::DeleteBlock` — `Editor::block_ranges` enumerates per-row byte ranges, splices descending so
earlier offsets stay valid). Cursor lands at the rect's top-left after delete. Bare `v` / `V` in
block mode flip back to charwise / linewise; `Esc` exits. Block insert (`I` / `A` / `c` — true
multi-cursor "type once across rows") is out of scope for the MVP. V-BLOCK chip in the
statusline / pending-display.
**Vim normal `r<c>`** — replace the char under the cursor with `c`. New `EditOp::ReplaceCharAtCursor`
landing the cursor at the same byte position (vim convention). Visual `r<c>` replaces every non-newline
char in the selection.
**Vim `g_`** — move to last non-whitespace char on the current line (new `EditOp::MoveLineLastNonWs`).
**Vim `ga` / `g8`** — char info toasts. `ga` shows decimal · hex · U+XXXX; `g8` shows the UTF-8 byte
sequence. New commands `editor.char_info` / `editor.char_utf8`.
**Vim `Ctrl+O` / `Ctrl+I`** — jumplist back / forward. Aliased onto the `nav.back` / `nav.forward`
commands (the same machinery as `Alt+Left` / `Alt+Right`). `Tab` in vim normal also routes to
`nav.forward` (terminals don't distinguish Ctrl+I from Tab).
**Vim `&`** — repeat the last `:s` payload on the cursor's current line (vim convention: always line
scope, `c` flag dropped). `App.last_substitute: Option<Substitute>` records every `:s` / `:%s`;
`editor.repeat_last_substitute` re-fires.
**`:reg` / `:registers`** — toast the current clipboard contents (single anonymous register MVP;
newlines render as `↵`, truncated at 80 chars).
**`:b <substr>`** — switch to the editor pane whose path contains `<substr>` (case-insensitive,
filename-exact match wins on ambiguity). Bare `:b` toasts the open buffers list.
**Persisted `closed_buffers`** — `Ctrl+Shift+T` (`buffer.reopen`) survives a relaunch:
`SavedSession.closed_buffers: Vec<SavedNavPoint>` round-trips the recently-closed buffer paths +
their last cursor positions, capped at `CLOSED_BUFFERS_MAX` on restore.
**Vim `Ctrl+L`** — force a screen redraw (`view.redraw` command flips `App.redraw_requested` so
`tui.rs`'s loop calls `term.clear()` next frame). Vim canonical chord for "stale terminal? rip it".
**Vim `''` / `` `` ``** — second-quote / second-backtick after the mark prefix is aliased to
`nav.back` (vim's "jump to previous cursor position"). Bare-letter forms still go to `JumpToMarkLine`
/ `JumpToMarkExact`.
**`:!cmd`** — fire `cmd` through `$SHELL -c` synchronously from the workspace dir; toast the first
200 chars of stdout (or stderr if empty) + exit status. Bounded — for long-running tasks reach for
`:term <cmd>` (a pty pane). Vim canonical.
**Completion popup `Ctrl+J` / `Ctrl+K`** — vim-style alternates for Down / Up in the LSP
completion popup (in addition to the existing arrows + `Ctrl+N` / `Ctrl+P`). Ergonomic for vim
users who don't want to leave the home row.
**Statusline filesize chip** — compact in-memory byte count next to the `Ln/Col` chip
(`123B` / `4.2K` / `12M`). Reflects unsaved edits; `format_byte_size` helper picks the unit.
**`:r !cmd`** — fire `cmd` through `$SHELL -c`, splice stdout into the active editor below the
cursor's line. `:r <path>` (without `!`) reads a file the same way. Vim canonical.
**`:m N` / `:move N`** and **`:co N` / `:copy N` / `:t N`** — move / duplicate the cursor's
current line to right after line N (1-based; `0` ⇒ top, `$` ⇒ bottom; `+K` / `-K` relative).
Single edit op so undo restores the original ordering. `App::run_move_or_copy_line` does the
splice; cursor follows the line to its new home.
**`:marks`** — toast all set marks (buffer-local lowercase + global uppercase across the
workspace), sorted by letter. **`:jumps`** — toast the jumplist (`nav_back` + `nav_forward`,
newest first, capped at 10 each side).
**Vim `gu` / `gU` / `g~` operators** — case transforms with motion or text-object scope:
`guw` lowercases the word, `gUiw` uppercases the inner-word, `guip` lowercases the
paragraph, etc. New `PendingOp::Lower` / `Upper` / `ToggleCase` variants — emit
`TransformSelectionCase` after the motion's `SelectStart` + motion seal the range. Doubled
forms (`guu`, `gUU`, `g~~`) operate on the whole current line via `SelectLine`. Pending-op
display chips: `gu` / `gU` / `g~`.
**Vim `gn` / `gN`** — find as text-object. Selects the match the cursor is on (if any),
else the next / previous one (wraps). Standalone (`gn` from normal mode) goes through
`App::select_find_match(forward)` which reads `Buffer.find.matches` and sets editor.anchor
+ cursor via new `Editor::set_selection(start, end)`. **Operator-pending forms** (`cgn` /
`dgn` / `ygn` / `gugn` / `gUgn` / `g~gn`) work too: `EditCtx` was extended with
`next_find_match` / `prev_find_match` (the buffer pre-computes the cursor-relative match
range via `make_ctx`), and the vim handler emits an Op sequence
`[SetCursorByte(start), SelectStart, SetCursorByte(end), <op-effect>]` directly. Required
new `EditOp::SetCursorByte(usize)` (sets cursor to a specific byte offset, char-boundary
clamped). The operator-pending dispatch routes `g` (with op set) into `Prefix::G` while
preserving `self.op`, and the `n`/`N` arms in the G-prefix consume `pending_op` if set.
**`picker.marks`** — fuzzy picker over every set mark (buffer-local lowercase first, then
global uppercase). Each row labels the letter, the file (relative), the line/col, and a
short slice of the line text as a preview. Accept jumps to the mark (opens the file if
needed). New `PickerKind::Marks`.
**Vim `;` / `,`** — repeat the last `f` / `F` / `t` / `T` find-char in the same /
opposite direction. New `VimInputHandler.last_find_char: Option<(char, bool, bool)>`
records every find-char dispatch.
**Vim `Ctrl+^` / `Ctrl+6`** — switch to the alternate (most recently active) buffer.
Aliased to `buffer.last` (the existing `Ctrl+Tab` target).
**Esc dismisses the toast** — pressing Esc anywhere clears any visible toast immediately
(visual fluff the user explicitly said "go away" to). Doesn't return — other Esc handlers
still fire (exit overlays, leave visual mode, etc.).
**Vim `gp` / `gP`** — paste, cursor lands at the END of the pasted text (vs. `p` / `P`
which leave the cursor at the start of a linewise paste). New `EditOp::PasteAfterEnd` /
`PasteBeforeEnd`.
**Vim insert-mode chords** — `Ctrl+W` deletes the previous word; `Ctrl+U` deletes to
start of line; `Ctrl+H` is a backspace alias; `Ctrl+T` / `Ctrl+D` indent / outdent the
current line; **`Ctrl+R <reg>`** pastes the named register's contents inline at the
cursor (vim canonical). Vim canonical for typing-flow corrections without leaving Insert.
**Vim `H` / `M` / `L`** — move the cursor to the **top / middle / bottom of the visible
viewport** (scroll stays put). Distinct from `zz` / `zt` / `zb` (which scroll to put the
cursor at that position; H/M/L move the cursor to that position). New
`App::move_cursor_in_view(frac)`; commands `view.move_cursor_view_top` /
`_middle` / `_bottom`.
**Vim `Ctrl+G`** — toast the active editor's `<path> · Ln N/M · X%` (alias for
`editor.file_info`).
**Vim `{` / `}`** — paragraph navigation (prev / next blank-line boundary). New
`EditOp::MoveParagraph{forward}`. Pure motion — works after operators (`d}`, `c{`).
**Vim `(` / `)`** — sentence navigation. Sentence boundary = `.` / `!` / `?` followed by
whitespace. New `EditOp::MoveSentence{forward}`.
**`:%y` / `:%d`** — buffer-wide yank / delete (vim canonical). Single edit op so undo
restores; `:%y` mirrors to the clipboard linewise so a subsequent `p` re-pastes the buffer.
**Vim insert `Ctrl+Y` / `Ctrl+E`** — insert the char from the line above / below at the
same column. New `EditOp::InsertCharFromLine{above}`. Useful for "copy this structure"
gestures while typing.
**Vim `iq` / `aq` (mnml extension)** — smart-pick the closest enclosing quote pair from
`"`, `'`, `` ` ``. The smallest enclosing range wins. New `SelectInnerSmartQuote` /
`SelectAroundSmartQuote` ops. Saves a keystroke when you don't care which quote variant
you're inside.
**`:%!cmd` / `:'<,'>!cmd`** — pipe the whole buffer (or selection) through `cmd` via
`$SHELL -c`, replacing the input range with stdout. Single edit op so undo restores;
non-zero exit ⇒ buffer untouched + toast with stderr preview. Useful for `jq .`, `sort`,
`prettier`, etc. `App::run_filter_through_shell`.
**`lsp.organize_imports`** (`Alt+Shift+O`) — fires `textDocument/codeAction` with
`context.only = ["source.organizeImports"]`; auto-applies the first returned action.
New `LspManager::code_action_with_only` + client `code_action_inner` factor.
**Vim named macros** — `q<reg>` records into `<reg>` (`a`-`z`); `qq` records into the
anonymous `'@'` register (mnml convenience); `q` during recording stops. `@<reg>` replays;
`@@` replays anonymous. `App.macro_buffer: HashMap<char, Vec<KeyEvent>>`,
`MacroState::Recording { register, keys }`, new `AppCommand::MacroRecordInto(c)` /
`MacroReplayFrom(c)` for register-aware dispatch. Vim handler keeps a local
`is_recording_macro: bool` mirror so the `q` chord can decide between "enter
record-target prefix" (idle) and "stop the recording" (recording).
**Vim-surround** (`ds<c>` / `cs<from><to>` / `ys{motion}<c>` / `yss<c>`) — full
vim-surround equivalent. `ds"` deletes the surrounding `"..."`; `cs"'` changes them
to `'...'`; `ysiw"` wraps the inner word with quotes; `yss<` wraps the current line
with `<...>`. Works for quotes (`"`, `'`, `` ` ``) and brackets (`(`/`)`, `[`/`]`,
`{`/`}`, `<`/`>`). New `EditOp::DeleteSurround(c)` / `ChangeSurround{from, to}` /
`SurroundSelection{open, close}`. Operator-pending `s` after `d`/`c`/`y` routes into
new prefix variants (`SurroundDelete`, `SurroundChange(char)`, `SurroundAddCharWait`).
The add-surround flow uses a two-phase build: motion completes ⇒ `pending_surround_ops`
holds the select-ops, transition to char-wait ⇒ char arrives, emit
`[…select…, SurroundSelection, SelectClear]`.
**Vim abbreviations** — `[abbr]` config table or runtime `:ab <key> <expansion>`; in
Insert mode after a "trigger" char (whitespace / punctuation), the word just before
the trigger is replaced with the expansion if it matches. `:una <key>` removes; bare
`:ab` lists. Hooked into `dispatch_key` after `BufferEvent::Edited` via
`App::try_expand_abbreviation`.
**`:bufdo` / `:tabdo` / `:argdo`** — run an ex command on every editor pane in turn.
mnml has buffers (not tabs / arglist); all three aliases route to the same loop.
**`:cd`** — toasts the workspace path; mnml's workspace is per-session so we don't
actually change it.
**`:setlocal tab_width=N` / `[no]eol` / `[no]trim`** — per-buffer overrides for the
active editor's `editor.tab_width` / `ensure_trailing_newline` / `trim_trailing_ws_on_save`.
Vim canonical for file-specific settings without modifying the global config.
**`:retab!`** — mirror of `:retab` (tabs → spaces): leading runs of N spaces per line
collapse back to tabs (`N = [editor] tab_width`). Single edit op.
**`:sort!`** — reverse-order sort (vim canonical). Same machinery as `:sort` with a
`reverse` flag.
**Quickfix list** (`:cnext`, `:cprev`, `:cfirst`, `:clast`, `:ccurrent`, `]q`, `[q`)
— navigate the most-recent grep results without leaving the editor. Selection moves
inside the open `Pane::Grep` and the cursor jumps to the source line.
**LSP code lens** — `[editor] code_lens = true` (default; `:set [no]codelens` /
`:set codelens!`). `LspManager::code_lens(path)` fires `textDocument/codeLens` on
open + save; reply parsed by `parse_code_lenses` into
`Vec<CodeLens{line, title, command: Option<CodeCommand>, raw: Option<Value>}>`. Stub
lenses (title present, command missing) keep `raw` set so a click can fire
`codeLens/resolve` to fill in the command. Lenses without a title are dropped (no chip
to render). Renderer paints them as dim purple `⚡ <title>` chips at end-of-line, with
`|` separators between multiple lenses on the same line. **Clicks are routed** — each
painted lens's rect lands on `app.rects.code_lens_chips`; the mouse-down handler
dispatches `App::trigger_code_lens(pane_id, lens_idx)` which either fires
`workspace/executeCommand` directly (eager lens) or fires `codeLens/resolve` with the
original lens JSON and stashes the click in `App.pending_code_lens_resolve`. The
reply lands as `LspEvent::CodeLensResolve { path, lens_index, lens }` →
`apply_lsp_event` merges the new command back onto the buffer's lens and re-fires the
stashed click. Resolves rust-analyzer's "Run | Debug" + TypeScript's lazy
"references" lenses. `initialize` advertises both the capability and
`resolveSupport: { properties: ["command"] }`.
**Vim `Ctrl+W p` / `Ctrl+W _` / `Ctrl+W |` / `Ctrl+W f` / `Ctrl+W n` / `Ctrl+W d` /
`Ctrl+W x`** — focus previously-active leaf (alias `buffer.last`); maximize active
split's height / width by pushing the enclosing parent's ratio to 90/10 toward the
side containing the active leaf (`Layout::maximize_split_ratio_for`); split + open
file under cursor (`view.split_open_file_under_cursor`); split + scratch buffer
(`view.split_new_scratch`); split + goto definition (`view.split_goto_definition`);
exchange siblings (alias for `view.rotate_splits`).
**Vim `gt` / `gT`** — vim's "next/prev tab"; mnml has buffers, not tabs, so these
alias to `next_buffer` / `prev_buffer`.
**Vim `g*` / `g#`** — like `*` / `#` but match the word as a substring (no word-
boundary requirement). mnml's literal find is already substring-based, so these
alias to the existing `find.word_forward` / `find.word_backward`.
**Vim insert `Ctrl+R Ctrl+W` / `Ctrl+R Ctrl+A`** — paste the identifier (Ctrl+W) /
WORD (Ctrl+A, whitespace-delimited) under the cursor inline. New
`App::insert_word_under_cursor` / `insert_bigword_under_cursor`.
**`:earlier N` / `:later N`** — walk N undo / redo steps. Vim's duration syntax
(`5s`, `10m`) skipped — mnml doesn't timestamp snapshots yet.
**`:` cmdline history** — Up / Down on the cmdline walks through the in-session
history of accepted ex commands (de-duped against the most-recent, capped at
`EX_HISTORY_MAX = 100`). Volatile (not persisted across relaunches). The handler
stashes the user's typed text on first Up so Down past the newest restores it.
**`:[%]norm <keys>`** — for each line in the requested range (whole buffer with
`%`, selection if active, else current line), place the cursor at line start and
re-dispatch each char of `<keys>` through the active vim handler. Vim's killer
power tool for "do this on every line". Pre-captures the row range so edits that
add/remove lines don't repeat-fire. After each line's keys, force Esc to ensure
the next line dispatches in Normal mode.
**`:ls` / `:files` / `:buffers` / `:buf`** — open the buffer-switcher picker.
**Statusline clock chip** (`HH:MM`, optional) — `[ui] clock = true` (default;
`:set [no]clock` runtime). UTC by default; `$TZ_OFFSET_HOURS` env var for local
offset (avoids the libc `localtime_r` dance).
**`:%s/.../.../n`** — count-only mode (vim canonical). Doesn't touch the buffer;
toasts the match count.
**`:s//new/`** — empty find reuses the last `:s` find pattern (vim canonical).
Inherits the case-insensitivity flag from the previous sub when the new flags
don't override.
**`:put` / `:put!`** — paste the unnamed register on the next / previous line
(vim canonical ex form of `p` / `P`). Linewise — always inserts a fresh line.
**`:messages` / `:mes`** — toast the most-recent N (8) entries from
`App.message_log` (capped at `MESSAGE_LOG_MAX = 200`). The toast machinery now
mirrors every emitted toast into the log.
**`:d[elete]` / `:y[ank]`** — vim canonical ex form of `dd` / `yy` (delete /
yank current line; the unnamed register gets the line).
**`:wn` / `:wp`** — write the active buffer + jump to next / prev buffer.
**Vim insert `Ctrl+O`** — temporarily flips to Normal for one command, then
back to Insert. Chord-aware: `dd` from oneshot stays Normal until the second
`d` completes. `VimInputHandler.insert_oneshot_normal` flag is checked at the
bottom of `handle_key`.
**`[editor] autosave_on_focus_loss`** — save dirty buffers automatically when
they lose focus (e.g. switching to another buffer / pane). Off by default —
useful for "never lose work" workflows but surprising for users who switch
buffers to compare-then-discard.
**Vim `Ctrl+W R`** — alias for `Ctrl+W r` (rotate splits).
**Vim insert `Ctrl+N` / `Ctrl+P`** — keyword completion (vim-native, non-LSP).
Scans the active buffer for words matching the prefix-before-cursor and opens the
same completion popup we use for LSP. Capped at 200 matches; de-duped. New
`App::keyword_complete(backward)` + commands `editor.keyword_complete` /
`_back`.
**`:diff` / `:diffs` / `:diffsplit`** — alias for `git.diff_file` (open the diff
pane for the active file). Vim users reach for `:diff` reflexively.
**`:silent <cmd>` / `:sil <cmd>`** — run `<cmd>` with toasts suppressed (still
recorded into `:messages`). `App.silent_depth` ⇒ `toast()` skips the visible
toast while > 0. Re-entrant.
**`:command <Name> <expansion>`** — define a user ex command. `:Name <args>` runs
`<expansion> <args>`. Bare `:command` lists; `:delcommand <Name>` (alias `:delc`)
removes one. `App.user_ex_commands` HashMap; resolved in `run_ex_command` before
the builtin match.
**`:make [task]`** — kick off the configured `[tasks.make]` task (or named task) in
a pty pane. Vim canonical "build / test from inside the editor".
**`:g/pattern/cmd`** / **`:v/pattern/cmd`** — vim's "global" command. Runs `<cmd>`
on every line whose text contains `<pattern>` (literal substring; vim's regex
isn't wired). `:v/` is the invert form. Visits rows in reverse so `:d`-style
line removals don't misalign.
**`:!!`** — repeat last `:!cmd` shell command. `App.last_shell_cmd` tracks.
**`:silent!`** — alias for `:silent` (we don't distinguish error toasts from
normal toasts).
**`:syntax on|off` / `:syn`** — toggle tree-sitter highlights (master switch on
`[ui] syntax`, default true). When off, all editor text uses the theme's foreground.
**`:execute "<str>"` / `:exe`** — strip outer quotes (single or double),
unescape `\"` / `\\`, run as a fresh ex command. Strict literal MVP — no
expression eval (vim's `:execute` does string concat with `.`).
**`:setf <name>` / `:set filetype=<name>` / `:set ft=<name>`** — override the
buffer's `language_ext` so the highlighter targets a different grammar
(`:setf rust` for a `.txt` snippet that's actually code, etc.). Re-runs the
highlighter immediately.
**`:enew` / `:ene`** — fresh scratch buffer in the current pane.
**`:vimgrep <pat>` / `:grep <pat>` / `:gr <pat>`** — alias for workspace grep
(routes through `run_workspace_grep`).
**`:copen` / `:cclose` / `:cwin[dow]`** — focus / close the grep pane (mnml's
quickfix). Same alias family as the vim quickfix commands.
**Vim line-range ex commands** — `:1,5d`, `:5,$y`, `:.,+3d`, `:.+1d` etc. New
`parse_line_range(line, current_line, line_count) → Option<(start, end, remainder)>`
parser supports bare numbers (1-based on the wire), `.` (current line), `$` (last),
and `+N`/`-N`/`.+N`/`.-N` relative refs. Wired for `d`/`y` only — `s` already takes
its own scoping via `%`. New `App::delete_lines` / `yank_lines` helpers.
**Line-range mark refs** — `:'a,'bd`, `:'<,'>y`, etc. `expand_mark_refs` pre-processes
the line before `parse_line_range` sees it, substituting `'<letter>` (buffer-local
lowercase, global uppercase) and `'<` / `'>` (start / end of the last visual selection)
with their 1-based row numbers. Backed by new `Editor::last_selection_rows()` which
converts the existing `last_selection` byte range to row indices (rolling back the end
row by 1 when the selection's exclusive boundary sits exactly past a trailing newline,
so V-line `V↓↓y` followed by `:'<,'>d` deletes 3 rows not 4). Unresolvable marks left
in place so the parser declines and the outer dispatcher falls through.
**Buffer-list ex aliases** — `:bfirst` / `:bf` / `:brewind` / `:br` (first editor pane);
`:blast` / `:bl` (last); `:#` / `:b#` / `:e#` / `:bu#` (alternate buffer — alias for
`Ctrl+^`); `:undo` / `:u` and `:redo` / `:red` (single-step alternatives to `:earlier`
/ `:later`); `:redraw` / `:redr` / `:redraw!` (force a screen redraw — alias for
`view.redraw` / `Ctrl+L`).
**Vim `+` / `-` / `<CR>` / `_`** — `+` (also `<CR>` in Normal): move down N lines then to
first non-whitespace. `-`: same, up N lines. `_`: alias for `^` (first non-blank of current
line, vim canonical). New `EditOp::MoveDownFirstNonWs` / `MoveUpFirstNonWs` (each calls
`move_vertical` then re-applies `MoveLineFirstNonWs`). Wired in `motion()` so they compose
with operators (`d+` deletes through next line's first non-blank, etc.).
**Vim `g0` / `g^` / `g$` / `gj` / `gk`** — display-line motion aliases. mnml doesn't wrap
(yet), so each is wired to the matching logical-line motion — no behavioral difference today,
but the chords are reflexive for vim users and become real once visual wrap lands.
**Vim `<count>%` / `<count>|`** — `<count>%` jumps to N% of the buffer
(`((count * line_count) + 99) / 100`, clamped); bare `%` (no count) still falls through to
bracket-match. `<count>|` jumps to character column N on the current line (1-based, new
`EditOp::MoveToCol`). Both compose with operators (`d50%`, `c5|`).
**`:close` / `:clo` / `:hide`** — vim canonical "close current window" aliases for
`:bd` (dirty-prompt path included). **`:e +N <path>`** — open a file and jump to line N
(vim canonical "open at line"); `:e +<path>` (no N) opens at last line.
**Vim `W` / `B` / `E` / `ge` / `gE` (WORD motions)** — whitespace-delimited cousins of
`w` / `b` / `e` (which split on punctuation), plus the end-of-previous-word variants. New
`EditOp::MoveBigWordRight` / `MoveBigWordLeft` / `MoveBigWordEnd` / `MoveBigWordEndBack`
and `MoveWordEndBack`. `ge` / `gE` are two-phase scans (back over the current run, then
back over whitespace, landing on the last char of the prior run); the forward `E` is the
classic skip-whitespace-then-walk-until-next-is-ws pattern. Compose with operators
(`dW`, `dge`, `cE`, etc.).
**Vim insert `Ctrl+V` / `Ctrl+Q`** — literal-next. The next keystroke is inserted verbatim
(Tab as `\t`, Enter as `\n`, etc.) instead of going through the usual chord / tab-expand
path. New `VimInputHandler.insert_literal_next` flag consumed at the top of `handle_insert`.
**Tab-ex aliases** — `:tabnext` / `:tabprev` / `:tabfirst` / `:tablast` / `:tabclose` /
`:tabonly` route to mnml's buffer ops (mnml has buffers, not tabs; vim users reach for
these reflexively).
**`:badd <path>`** — load a file as a buffer without changing focus (vim canonical buffer-add).
**`:resize +N` / `:resize -N` / `:vert resize ±N`** — adjust the active split's height /
width by N percent (clamped to the existing 10..=90 range in `Layout::adjust_split_ratio_for`).
Vim's exact-rows form (`:resize 20`) skipped — mnml uses ratios, not row counts.
**`:set tabstop=N` / `:set ts=N` / `:set shiftwidth=N` / `:set sw=N` / `:set softtabstop=N` /
`:set sts=N`** — all alias to mnml's single `tab_width` setter (vim has three knobs; we have
one). Works at both `:set` and `:setlocal` scope.
**`:set autoindent` / `:set ai` / `:set noautoindent` / `:set ai!`** — toggle `[editor]
auto_indent`. Vim canonical.
**Vim-compat `:set` no-ops** — `:set expandtab` / `et` / `ignorecase` / `ic` / `smartcase` /
`scs` / `hlsearch` / `hls` / `incsearch` / `is` all toast "already on" (mnml's default).
Their `no…` variants toast "not supported". `:set wrap` / `nowrap` toast "wrap not implemented".
Vim users get a friendly hint instead of "unknown option".
**Vim adverbs** — `:keepjumps` / `:keepalt` / `:noautocmd` / `:keepmarks` (plus short forms
`:keepj` / `:keepa` / `:noa` / `:kee`) strip the adverb and run the inner ex command. mnml's
jumplist / alt-buffer / autocmd machinery isn't precise enough for strict suppression — the
adverbs document intent for vim users; behavior matches the bare command.
**Vim netrw aliases** — `:Explore` / `:E` / `:Sexplore` / `:Sex` / `:Vexplore` / `:Vex` /
`:Lexplore` / `:Lex` toggle mnml's file tree (closest thing to netrw). **`:browse` / `:bro`**
opens the `Ctrl+P` file picker (vim canonical "show a file open dialog").
**Line-length color column** — `[ui] color_column` (0 = off, default; `N` = paint column N).
`:set colorcolumn=N` / `:set cc=N` sets; `:set cc=` or `:set nocolorcolumn` clears;
`:set cc!` toggles between 0 and 80 (vim's classic). `view.toggle_color_column` is the
palette form. Editor view paints the cell at column `N-1` with the theme's `bg2` background
— priority is just above the base bg, so selection / find / cursor-line tints still win.
**Statusline macro recording chip** — when `App.macro_state == Recording { register, .. }`,
the statusline left side renders a red `● rec @<reg>` chip so the user can't forget
they're recording (vim shows "recording @<reg>" on the bottom; we put it next to the mode
chip so it's visible even when a toast is up).
**`:reg <regs>` filter** — `:reg abc` filters the registers list to just `"a` / `"b` / `"c`.
Include `"` in the arg to also keep the unnamed register. Bare `:reg` still shows them all.
**`:` cmdline Tab completion** — pressing Tab on a `:`-line cycles through matching
candidates. FIRST word matches against `EX_COMPLETION_NAMES`. TRAILING arg of a
path-accepting command (`:e` / `:edit` / `:sp` / `:vsp` / `:tabnew` / `:badd` /
`:saveas` / `:w` / `:source` / `:r`) cycles through workspace file/dir entries (hidden
entries shown only when the typed prefix starts with `.`). Cycle state lives on App
(`App.cmdline_complete_state`); the handler emits `AppCommand::CmdlineTabComplete` and
the App computes / writes back via the new `InputHandler::cmdline_get` / `cmdline_set`
trait methods. Watermark check on `last_shown` drops the cycle as soon as the user edits
the line by any other means.
**Vim cmdline `Ctrl+W` / `Ctrl+U` + mid-line editing** — `:` cmdline now tracks a caret
position (`VimInputHandler.cmdline_cursor`, byte offset). Left / Right step one char
boundary; Home / End jump to ends; Backspace deletes before the caret; Delete deletes at
the caret; printable chars insert at the caret. `Ctrl+W` deletes the word before the
caret; `Ctrl+U` clears the whole line; `Ctrl+A` / `Ctrl+E` jump to start / end (vim +
readline canon). The statusline pending-display renders the caret as a `▏` (left
one-eighth block) inline. History Up / Down places the caret at end-of-line (vim
convention).
**fzf.vim aliases** — `:Files` (Ctrl+P file picker), `:Buffers` (buffer picker), `:Rg` / `:Ag`
/ `:Lines` (workspace grep — with optional inline query: `:Rg foo`), `:BLines` (find in
current buffer), `:History` (recent-files picker), `:Commands` (palette), `:Marks` (marks
picker), `:Snippets` (snippet picker). Wide adoption among vim users from the fzf ecosystem.
**Title-case LSP ex aliases** — `:Format` / `:Hover` / `:Definition` / `:References` /
`:Symbols` / `:Diagnostics` / `:Rename` / `:CodeAction` / `:CA` / `:QuickFix` / `:QF` route
to the corresponding `lsp.*` commands. Friendlier than `:lsp` plumbing for vim users coming
from ALE / coc / nvim-lspconfig conventions. All also surface in `:` cmdline Tab completion.
**Fugitive-style git ex aliases** — `:G` / `:Git` / `:Status` (status pane), `:Gblame` /
`:Blame` (blame gutter toggle), `:Gdiff` (file diff pane), `:Glog` / `:Log` (commit graph),
`:Gcommit` / `:Commit` (commit prompt), `:Branch` / `:Branches` (branch picker), `:Stash` /
`:StashPop`. Routes to the corresponding `git.*` commands so fugitive.vim muscle memory
works in mnml.
**Playwright ex aliases** — `:Test` (test.run_at_cursor), `:TestAll`, `:TestFile`,
`:TestFailed` (rerun last failed), `:Flaky` (flaky-test dashboard).
**Git hunk ex aliases** — `:NextHunk` / `:Hnext` (jump to next changed hunk), `:PrevHunk` /
`:Hprev`, `:PeekHunk` / `:Hpeek` (popup the diff hunk at cursor).
**MRU buffer picker** — `:Buffers` / `:ls` / Ctrl+P-buffer picker now shows panes in
most-recently-used order with the active pane dropped to the bottom so the picker opens
already-cursored on the *previous* buffer (vim's "alternate buffer" idea — Enter swaps).
New `App.pane_mru: Vec<PaneId>` (newest first) maintained in `reveal_pane`; entries
removed and re-indexed in `remove_pane_storage`.
**LSP completion docs footer + lazy `completionItem/resolve`** — `CompletionItem.documentation`
is captured from each candidate's `documentation` field (string OR `MarkupContent`); the
popup renders the selected item's first non-empty doc line as a dim italic footer beneath
the list. When the highlighted item has no docs but the server gave us the original item
JSON (`CompletionItem.raw`), the App fires `completionItem/resolve` and merges the reply's
`documentation` + `detail` back into the row. `initialize` advertises
`completionItem.documentationFormat` + `resolveSupport: { properties: ["documentation",
"detail"] }`. New `LspEvent::CompletionResolve`, new `LspClient::completion_resolve` /
`LspManager::completion_resolve`. Pending-request stash carries an `Option<String>` opaque
slot so the reply can find the popup row by label. New
`CompletionPopup::{current_index_mut, item_at_mut, item_index_by_label}`. The first item's
resolve fires on initial popup open; subsequent items resolve when the user navigates to
them (one resolve per item — `resolved` flag prevents repeat requests).
**`:retab N` / `:retab! N`** — vim's optional N override; if the arg is a positive integer
it's used as the tab width for this retab only (the global `[editor] tab_width` is
restored after). Bare `:retab` still uses the global setting.
**`:sort i`** — case-insensitive sort (vim canonical). Combines with `u` and `!` as
expected. `run_sort_lines` now delegates to `run_sort_lines_opts(unique, reverse,
case_insensitive)`.
**`:Maps [filter]` / `:Keys [filter]`** — toast the resolved keymap (chord → command id),
optionally narrowed by a substring that matches either side. Vim users reach for `:map`
for this; mnml's keymap is config-driven so the listing is read-only discovery. Backed by
new `Keymap::iter` + `Chord::to_spec()` (pretty-prints chords back to key-spec strings
that round-trip through `parse_key_spec`).
**`:history` / `:his` / `:hist`** — toast the ex-command history (newest first, capped at
20, with overflow count). Vim canonical for "what did I just run".
**`:abclear` / `:abc`** — drop every abbreviation. Vim canonical.
**`:wincmd <c>` / `:winc <c>`** — run a `Ctrl+W <c>` chord as an ex command (vim canonical
"do window-cmd from cmdline"). Mirrors every Prefix::Window arm: `h` / `j` / `k` / `l` /
`w` (cycle), `q` / `c` (close), `s` / `v` (split), `=` (equalize), `o` (close others), `r`
/ `x` / `R` (rotate), `+` / `-` / `>` / `<` (resize), `H` / `J` / `K` / `L` (move), `p`
(last buffer), `_` / `|` (maximize), `f` (split + open under cursor), `d` (split + goto
def), `n` (split + new scratch).
**Location-list ex aliases** — `:lopen` / `:lwindow` (open diagnostics pane), `:lclose`
(close it), `:lnext` / `:lne` (next diagnostic in active buffer), `:lprev` / `:lp` /
`:lprevious`. Vim's location list maps to mnml's `Pane::Diagnostics`.
**Vim `<count>gg`** — go to line `<count>` (vim canonical: same as `<count>G`). Bare `gg`
still goes to the first line. The Prefix::G arm now snapshots `self.count.is_some()`
before `reset_pending` so it can branch.
**Vim `<count>r<c>`** — replace the next `<count>` characters with `<c>` (vim canonical;
bare `r<c>` still replaces just one). Emits `Replace, MoveRight` × (n-1) followed by a
final `Replace` so the cursor lands on the last replaced char.
**`:set list` EOL marker** — when `[ui] show_whitespace` is on, the editor view now paints
a dim `$` glyph at the cell immediately past each line's last char (vim canonical
`listchars=eol:$`). Joins the existing `·` (space) / `→` (tab) glyphs.
**Cmdline Tab completion for `:colorscheme` / `:b`** — the trailing-arg completer now
offers theme names from `crate::ui::theme::names()` when the first word is `colorscheme`
/ `colo`, and buffer display names when the first word is `b` / `buffer`. The helper
that has no App access (`compute_cmdline_completions`) only handles path completion; an
App-aware wrapper (`compute_cmdline_completions_for_app`) layers theme + buffer
completion on top.
**Vim Replace mode (`R`)** — full Replace mode. Typed chars overwrite the char under the
cursor and advance; at EOL / EOF the chars are inserted. Esc returns to Normal. New
`VimMode::Replace` + new `handle_replace` + new `EditingMode::Replace` variant (gets its
own orange `REPLACE` chip on the statusline + underline cursor shape). New
`EditOp::OverwriteCharAndAdvance(char)` (one op per typed char: replace-or-insert +
cursor advance). Backspace pops the last overwrite from `Editor.replace_stack` and
restores the original char (or removes an EOL-inserted one) — vim canonical. New ops
`ReplaceUndoOne` + `ReplaceSessionBegin`; the vim handler emits the latter on `R`-entry
so the stack starts fresh.
**LSP `workspace/applyEdit`** — server-initiated edits (rust-analyzer / some refactors)
now land. The reader replies `{applied: true}` and forwards the `WorkspaceEdit` via new
`LspEvent::ApplyEdit { label, edits }`; the App pipes it through `apply_rename_edits` and
toasts the count.
**Mouse click on completion popup** — clicking a row in the popup selects + accepts
that item. `app.rects.completion_rows` is recorded by the renderer; `dispatch_mouse`
matches click coords against it before the "click anywhere dismisses" path. New
`CompletionPopup::set_selected`.
**Lazy `codeAction/resolve`** — actions that arrive with no `edit` and no `command` (the
server held those for later) get resolved on demand. When `apply_code_action` sees a
stub with `raw` still set, it fires `codeAction/resolve` and stashes the action index in
`App.pending_code_action_resolve`. The reply (`LspEvent::CodeActionResolve`) merges
`edit` + `command` back into the action and applies it. `initialize` advertises
`codeAction.resolveSupport: { properties: ["edit", "command"] }`. `CodeAction` gains a
`raw: Option<serde_json::Value>` slot for the round-trip JSON.
**Vim `<count>o<text><Esc>` / `<count>O<text><Esc>` repeat-insert** — vim canonical
"open N new lines, type once, replicate". New `AppCommand::RepeatInsertStart{count,
above}`, new `App.repeat_insert_state: Option<RepeatInsertState>`. The App handles the
initial line + Insert-mode entry; `App::tick` polls for the Normal-mode transition and
splices `(count-1)` copies of the typed text in below the first. Single `apply_edit_ops`
so one Undo reverts.
**Vim `q:` cmdline-history pane** — new `Pane::CmdlineHistory(CmdlineHistoryPane)`,
new `src/ui/cmdline_history_view.rs`. Opened by the chord `q:` (handled in
`Prefix::MacroRecordTarget` as a special case before the register-letter rule) or by
`view.cmdline_history`. ↑↓ / jk / PgUp / PgDn / g / G navigate; Enter re-fires the
selected entry; Esc closes.
**`Pane::Quickfix` (vim quickfix list)** — distinct pane variant from `Pane::Grep` so
workspace-grep results don't get clobbered when something else fills the quickfix.
Shares the `GrepPane` struct + `grep_view::draw`; key handler is its own (no `r` rerun
since the populator is external). New `App::open_quickfix(title, hits)`. New
`:cexpr <text>` ex command (vim canonical) parses `file:line:col:message` lines and
populates a fresh Quickfix pane. `:copen` / `:cclose` / `:cnext` / `:cprev` now prefer
the Quickfix pane and fall back to Grep so vim users get muscle-memory behavior either
way.
**LSP references → Quickfix** — `lsp.references` now opens a `Pane::Quickfix` (browse
with `:cnext` / `:cprev`, jump with Enter) instead of the Locations picker.
**Code-action picker grouping** — actions sorted by kind (`quickfix` → `refactor` →
`source` → other) in `apply_code_action_reply` before opening the picker. Server order
preserved within a group.
**`:cdo <cmd>` / `:cfdo <cmd>`** — run an ex command on every quickfix entry (or once
per unique file). Saves after each. Falls back to `Pane::Grep` when there's no Quickfix
open.
**`:command -nargs=…`** — vim canonical argspec on user commands. `0` / `1` / `?` /
`+` / `*`; default `Any`. New `UserExCommand` struct + `ExCommandNargs` enum;
invocation tail validated; bad arity ⇒ refuse with toast.
**Markdown preview cursor sync** — any open `Pane::MdPreview` scrolls to roughly match
the source buffer's cursor row. Heading-aware heuristic (`#…` lines count as 2
rendered rows). Fires on edits and on cursor-only `Redraw` paths.
**Editor drag-select** — click-and-drag in an editor pane drops the anchor at the
origin and extends the cursor to the drag point. `App.drag_select: Option<(PaneId, row,
col, armed)>` records the click; the first `Drag(Left)` event arms the selection.
Releasing Left clears the state but the selection stays.
**LSP `textDocument/documentLink`** — fired on open + save alongside inlay hints and
code lens; reply parsed by new `parse_document_links` and stored on
`Buffer.document_links`. `editor.open_url_at_cursor` (vim `gx`) consults the link list
first, so server-recognized URLs / paths in comments work even when they aren't
whitespace-delimited. `file://` targets open as buffers; everything else goes to the
OS opener.
**LSP rename preview** — `textDocument/rename` no longer applies the `WorkspaceEdit`
silently. The reply opens a confirmation picker (new `PickerKind::RenamePreview`)
showing total edits + per-file breakdown; Apply commits, Cancel drops the stash on
`App.pending_rename_preview`.
**`:earlier <N><unit>` / `:later <N><unit>` duration form** — vim canonical time
syntax (`5s` / `10m` / `2h` / `1d`). Each undo `Snapshot` now carries a
`timestamp: u64` (UNIX epoch seconds, `#[serde(default)]` so old persisted histories
still load). `Editor::undo_steps_for_age` / `redo_steps_for_age` count how many steps
go back / forward to a snapshot at least `secs` old. Bare `:earlier N` still walks N
steps (no unit suffix).
**Multi-cursor — first cut** — `Editor.extra_cursors: Vec<usize>` (sorted byte
offsets, distinct from the primary `cursor`). New `EditOp::AddCursorBelow` /
`AddCursorAbove` / `ClearExtraCursors`. `editor.add_cursor_below` /
`add_cursor_above` are bound to `Ctrl+Alt+Down` / `Up` (with `Ctrl+Alt+J` / `K`
duplicates). Chained presses walk further from the bottom-most / top-most existing
cursor. The editor view paints each extra cursor's cell with the theme's `fg` bg +
`bg_dark` fg so it stands out from the primary cursor (which ratatui sets via the
terminal cursor). `InsertChar` is the one mutating op so far that fans out to all
cursors — inserts at every position descending so earlier offsets stay valid, then
advances each cursor by `char_len * (count ≤ position)`. Auto-pair is skipped on
multi-cursor inserts (semantics get hairy with N cursors). Esc in vim Normal mode
emits `ClearExtraCursors` so the gesture matches vim's "back to one cursor".
Multi-cursor fan-out expanded: `Backspace` / `DeleteForward` / `MoveLeft` /
`MoveRight` / `MoveUp` / `MoveDown` now all apply at every cursor. New helpers
`Editor::multi_delete_backward` / `multi_delete_forward` (each cursor deletes its
char in descending-position order; other cursors' positions are updated as the
text shrinks), and `move_extras_horizontal` / `move_extras_vertical` (each extra
walks one boundary or one row independently; out-of-range rows drop). `InsertStr` (paste) now fans out too — new `multi_insert_str` mirrors the
`InsertChar` algorithm but with the full byte length. `InsertNewline` also fans
out (auto-indent skipped on multi-cursor — earlier inserts would shift later
lines and make per-cursor indent introspection hairy). Word-level deletes
(`DeleteWordLeft` / `DeleteWordRight` / `DeleteToLineStart` / `DeleteToLineEnd`)
fan out via a new generic `multi_delete_range_per_cursor` helper: the caller
supplies a closure that maps each cursor's current position to a `(start, end)`
byte range; the helper applies them descending so earlier offsets stay valid
and shifts the other cursors as each delete lands. New
`word_left_target_from` / `word_right_target_from` helpers take a starting
byte so the closure can compute per-cursor ranges. Motions also extended:
`MoveWordRight` / `MoveWordLeft` / `MoveLineStart` / `MoveLineEnd` fan out
across cursors. **Alt+click in an editor pane** adds an extra cursor at the
clicked position (VS Code convention) — bypasses the focus / drag-arm path so
the existing primary stays put.
**Line-scoped multi-cursor ops** — `Indent` / `Outdent` / `ToggleLineComment`
(and any other op using `for_each_selected_line`) now operate on the union of
selection lines + the primary cursor's line + each extra cursor's line.
Same `>iw` / `<<` / `gcc` muscle memory; the change is per-line so multi-
cursor across rows just works.
**Per-cursor anchor (multi-cursor visual selection)** — new
`Editor.extra_anchors: Vec<Option<usize>>` parallel to `extra_cursors`.
`SelectStart` anchors each cursor at its own position (primary + every extra);
motions then extend each selection independently. `SelectClear` drops all
anchors. Editor view paints every cursor's selection bg (not just the
primary's). `DeleteSelection` fans out: each cursor's (anchor, cursor) range
gets deleted in one batched checkpoint; the joined text lands on the
delete-history clipboard. New helpers `replace_extra_positions` /
`replace_extra_pairs` / `commit_multi` keep cursor↔anchor pairing intact when
extras are re-sorted or shifted by edits. `add_extra_cursor` carries an
anchor if the primary already has one — so "v + AddCursorBelow" gives each
new cursor a zero-width selection that extends with motion.
`YankSelection` and `ReplaceSelection` (visual `y` / `c`) also fan out — yank
joins every range with `\n` and writes to the unnamed clipboard; replace
deletes every range then inserts `s` at each cursor's resting position via
the existing `multi_insert_str`. So `v…c<text><Esc>` does "change every
selection to `<text>`" — the most useful multi-cursor edit shape.
**Word wrap (char-break)** — `[ui] wrap` config (default false; `:set wrap` / `:set nowrap` /
`:set wrap!` / `view.toggle_wrap`). When on, long lines wrap to multiple visual rows; the
continuation rows show a blank gutter (no line number, no sign) so the user can tell it's the
same file line. Char-break MVP — no word-boundary heuristic. `h_scroll` is forced to 0 when
wrap is on. Implementation: `editor_view` precomputes a `Vec<VisRow {line_no, char_start,
is_continuation}>` of `text_h` entries from `buf.scroll`, then the existing per-row loop walks
that vector instead of `next_visible_line`; the inner cell loop uses `view_col_start + vc`
instead of `buf.h_scroll + vc`. Cursor placement uses wrap math (visual_y = sum of wrap-heights
from buf.scroll + cur_col / tw; visual_x = cur_col % tw). Vertical scroll gets a wrap-aware
correction loop that bumps `buf.scroll` forward when the cursor's visual offset would fall past
`text_h`.
**Wrap-aware click-to-place** — clicks (and alt-click, drag-select) inside a wrapped
continuation row land on the right `(file_line, char_col)` instead of snapping to the line's
start. New `Buffer::wrap_to_file_pos(scroll, visible_row, tw)` walks visual rows from
`buf.scroll` (skipping folds, counting wrap chunks); `tui.rs` factors the click-translation
into a `click_to_file_pos` helper used at the three click sites (alt-click add-cursor, plain
click place-cursor, drag-select extend).
**Wrap-aware vim motions `gj` / `gk` / `g0` / `g$`** — under wrap these walk one *visual*
row / move to the visual row's start / end (vim canonical display-line motions). Implemented
via new `EditCtx.wrap_width: Option<usize>` (passed from `tui.rs` from `app.rects.editor_panes`
when `[ui] wrap` is on) + new `EditOp::MoveVisualDown(width)` / `MoveVisualUp` /
`MoveVisualLineStart` / `MoveVisualLineEnd`. Editor::apply: down advances `width` chars on the
same line if room, else jumps to the next line at `cur_col % width`; up is the mirror; line
start / end snap to the segment boundary `(col / width) * width [+ width - 1]`. Compose with
counts (`3gj`). When wrap is off, the chords still alias to logical-line motions.
**Statusline LSP chip + `:LspStatus`** — when one or more language servers are running for any
of the open files, the statusline right side shows a `LSP N` chip (count of `(root, server-name)`
pairs). `:LspStatus` / `:LspInfo` toasts each running server with its workspace-relative root —
the breakdown when "wait, which servers do I have?" hits. New `LspManager::server_count` +
`servers_running()`.
**LSP type hierarchy** — `lsp.supertypes` / `lsp.subtypes` (ex aliases `:Supertypes` /
`:Subtypes` / `:ParentTypes` / `:ChildTypes`). Same two-step shape as call hierarchy
(`prepareTypeHierarchy` → `{super,sub}types` → Locations picker titled
`Supertypes/Subtypes — <name>`). Reuses `CallHierarchyItem` for the prepared item and
`CallHit` for the result. `initialize` advertises `typeHierarchy`. Most useful for
rust-analyzer / Java / C# where class / trait hierarchies are the navigation primitive.
**LSP call hierarchy** — `lsp.incoming_calls` / `lsp.outgoing_calls` (ex aliases `:Callers` /
`:Callees` / `:IncomingCalls` / `:OutgoingCalls`). Two-step: `textDocument/prepareCallHierarchy`
at the cursor → reply lands as `LspEvent::CallHierarchyPrepared` → the App fires
`callHierarchy/{incoming,outgoing}Calls` using the first item → reply lands as
`LspEvent::CallHierarchyCalls` → opens a `PickerKind::Locations` picker titled
`Incoming/Outgoing calls — <name>`; accept jumps to the call site (incoming) or callee
(outgoing). New `crate::lsp::CallHierarchyItem` (keeps the original JSON as `raw` so the
follow-up request hands it back verbatim — per spec). `initialize` advertises `callHierarchy`.
Multi-item disambiguation (overloaded fn under cursor) is a follow-up.
**LSP `documentHighlight`** — `lsp.highlight_symbol` (no default chord; `lsp.clear_highlights`
to drop): fires `textDocument/documentHighlight` at the cursor; the scope-aware reply tints
every same-symbol usage with `bg2` (the same tint used by `[ui] highlight_word_under_cursor`).
Unlike the text-match version, the server knows about scopes / shadowing / types, so `let x; ...
fn f(x: usize) { x }` highlights only one of the two `x`s. New `Buffer.document_highlights:
Vec<(u32, u32, u32, u32)>` (single-line ranges; multi-line dropped at parse). On-demand only —
wiring it into every cursor move would chatter the server.
**LSP `documentColor`** — server-supplied color literals get their foreground painted in their
actual color so `#ff0000` literally renders red, `rgb(0,255,0)` renders green, `hsl(...)` shows
the resolved hue. Fired on open + on save (same cadence as inlay hints / code lens). New
`crate::lsp::ColorDecoration{line, start_char, end_char, rgb}` (RGB packed as `0xRRGGBB`,
alpha dropped) on `Buffer.color_decorations`. `parse_document_color` clamps each component
to `[0,1]` × 255. Multi-line ranges dropped (renderer is per-line). `initialize` advertises
`colorProvider`. CSS / SCSS / Tailwind / HTML stylesheets light up immediately when the LSP
supports it (vscode-css-language-server, vscode-html-language-server, tailwindcss, etc.).
**LSP semantic tokens — first cut** — `textDocument/semanticTokens/full` fired on open + on
save (same cadence as inlay hints / code lens). Reply's flat `data[]` array is decoded by
`crate::lsp::client::parse_semantic_tokens` against the per-server legend (captured from
the `initialize` reply's `capabilities.semanticTokensProvider.legend.tokenTypes` and kept
as a reader-thread-local `Vec<String>`). Output is `Vec<SemanticToken{line, start_char,
length, type_name}>` on `Buffer.semantic_tokens`. The editor renderer's per-cell color
loop calls new `semantic_color(tokens, line, c)` BEFORE `syntax_color(spans, c)` — LSP
wins where they overlap (per LSP convention; servers know about types / shadowing / scopes
that tree-sitter doesn't). `semantic_token_color(type_name)` maps the LSP type-name string
(`"function"` / `"keyword"` / `"string"` / etc.) to theme colors using the same scheme as
the tree-sitter `HIGHLIGHT_NAMES` mapping. **Delta requests** — `LspClient::semantic_tokens`
picks `full` vs `full/delta` based on a per-path `SemState{result_id, raw_data}` cache
shared between the App-thread client and the reader thread via `Arc<Mutex<HashMap<PathBuf,
SemState>>>`. First request after `did_open` sends `full`; every subsequent request sends
`full/delta` with the cached `resultId`. The reader handles both reply shapes —
`SemanticTokens { data }` (full replacement, server bailed on computing a delta) and
`SemanticTokensDelta { edits: [{ start, deleteCount, data? }] }` (sparse splices into the
cached raw array). `apply_semantic_token_edits` sorts edits descending by `start` so later
splices don't shift earlier offsets out from under us; out-of-bounds edits drop the cache
so the next request falls back to `full`. `initialize` advertises `requests: { full: {
delta: true } }`. `did_close` evicts the per-path cache. **Modifier colors** —
`SemanticToken.modifiers: Vec<String>` is now populated by decoding the 5th-element
bitmask against the per-server `tokenModifiers` legend (also captured from the
`initialize` reply, reader-thread-local alongside the type legend). The renderer's
`semantic_style` returns `(Color, Modifier)` instead of just `Color`; per-cell `cells`
data shape grew a `ratatui::style::Modifier` slot so span coalescing keeps adjacent cells
with matching style together. Mapping: `deprecated` → CROSSED_OUT (deprecated APIs are
impossible to miss), `readonly` → ITALIC, `static` → BOLD, `defaultLibrary` → DIM
(stdlib symbols recede); other LSP-standard modifiers (`declaration` / `definition` /
`abstract` / `async` / `modification` / `documentation`) have no visual hook yet.
**Range requests** — `semanticTokens/range` (line 0 → file's last line) is wired as
a fallback when the server advertises `range: true` but not `full`. Per-server
capability flags (`supports_full` / `supports_delta` / `supports_range`) are captured
from the `initialize` reply's `semanticTokensProvider.requests` and live in a shared
`Arc<Mutex<SemServerCaps>>` so the App-thread
`LspClient::semantic_tokens(path, line_count, viewport)` chooser can pick the best
shape: viewport-range (when `viewport` is Some + server supports range) > delta > full
> whole-file range. `parse_semantic_tokens_caps` handles every common shape (legacy
`{ full: true }`, modern `{ full: { delta: true }, range: true }`, bare provider,
missing provider). Range replies don't carry a `resultId` useful for delta requests so
receipt drops the per-path cache (the next request will fall back to full or range,
not stale delta). `initialize` advertises `requests: { full: { delta: true }, range:
true }`. **Viewport-only mode** — `[editor] semantic_tokens_viewport` (default off;
`:set stviewport` / `:set nostviewport` runtime toggle): when on, every semantic-tokens
request becomes a viewport-shaped `semanticTokens/range` covering just the visible
lines of the active pane (`[scroll, scroll + pane_height]`). `App::tick` runs
`refresh_scroll_semantic_tokens` every cycle and re-fires range when the current
viewport has drifted more than `VIEWPORT_REFIRE_THRESHOLD = 20` lines from
`Buffer.last_semantic_viewport`. Smallest-scope dedupe — small scrolls don't mash the
LSP, but any meaningful jump refreshes promptly. Useful for very large files where
full/delta is expensive on every save; otherwise the default (delta > full) is faster.
**Limitations (first-cut still):** linear scan per cell (token volumes per file are
typically hundreds, fine for now; sort-by-line + binary-search would help on massive
files).
**`[ui] wrap` survives a relaunch** — the user's runtime `:set wrap` choice now persists in
`session.json` (`SavedSession.wrap: Option<bool>`). Config-file changes still take precedence
on a fresh workspace.
**Vim `?` reverse search** — opens the find prompt with the next `accept_find` flagged
to jump to the closest match BEFORE the cursor (vim canon). After the initial accept,
`n` / `N` still walk forward/back normally. `App.find_pending_reverse` carries the flag
across the prompt; consumed one-shot. New `find.find_backward` command.
**Persisted vim macros** — `q<reg>...q` recordings now survive a relaunch. Saved as
`(register, Vec<key_spec>)` via `Chord::to_spec` (the same format `[keys.global]` config
uses); restored on launch with `parse_key_spec`. Empty macros are dropped on save.
**`:Mkdir <path>` / `:Touch <path>` / `:Mv <from> <to>`** — workspace-relative POSIX file
ops accessible from ex. Mkdir creates parents too. Touch creates the file (and any missing
parent dirs) but won't truncate. Mv renames / moves (refuses to overwrite an existing
destination); also re-points any open editor on `from` to `to` and fires the LSP
close/open pair. All three refresh the tree.
**Statusline current-symbol chip** — `› <name>` chip painted on the left side showing the
cursor's closest enclosing symbol (fn / struct / class / etc.) for the active buffer.
Driven by `crate::regex_outline::extract_symbols` — one regex pass per frame for the
active buffer's text. Languages covered by regex_outline (rs/py/js/jsx/ts/tsx/go/rb/c/cpp)
get the chip; others render nothing. Approximation: shows the *last preceding* symbol
since regex_outline doesn't carry end-lines.
**`:Scratch [ft]`** — open a fresh scratch buffer split below, optionally tagged with a
filetype so syntax highlighting kicks in (`:Scratch md`, `:Scratch json`, …). Empty arg
⇒ plain scratch.
**`:Cp <from> <to>`** — workspace-relative file copy. Refuses to overwrite an existing
destination. Creates the parent dir of `<to>` if missing. (Lowercase `:cp` already
aliased to `:cprev`, so `:Cp` only.)
**`:Capture <cmd>`** — run the command via `$SHELL -c`, open the combined stdout/stderr
in a new scratch buffer (split below). Useful for grabbing `cargo test` output, log dumps,
etc. for grep / highlight without launching a full pty. Cwd is the workspace.
**`:Filetypes`** — toast the tree-sitter grammars mnml ships with (rs / js / py / …).
Quick "is X supported?" without grepping.
**`:OpenAt <path>:<line>[:<col>]`** — open the file and jump to a 1-based position.
Friendly for pasted `path:row:col` strings from grep / clippy / etc.
**`:Fn`** — toast just the active editor's filename (no path). Quicker than `:Path` when
all you need is "what file am I in".
**`:Args`** — list every open editor pane's workspace-relative path. Vim canonical
`:args` shows the arglist; mnml has buffers, so we list those.
**`:Mtime`** — toast the active file's modification time + humanized age.
**`:Notes`** — open / create `<workspace>/.mnml/notes.md` as a workspace-local notepad
(markdown so the auto-md-preview behavior kicks in).
**`:Reflow [N]`** — reflow the paragraph at cursor to width N (default `[editor]
text_width`). Vim canonical `gqq` with an optional width arg.
**`:Sleep <ms>`** — block the event loop for `<ms>` ms (e2e / scripting). Clamps at 10 s.
**`:Encoding` / `:enc`** — toast `utf-8` (mnml is UTF-8 only). For vim muscle memory.
**`:RootFor [path]`** — toast the LSP root for `<path>` (or the active buffer): walks
ancestors for `Cargo.toml` / `package.json` / `go.mod` / `pyproject.toml` / `.git`.
**`:Newer <N>` / `:Older <N>`** — friendlier vim aliases for `:later` / `:earlier`.
**`:setlocal [no]readonly` / `:setlocal ro` / `noro` / `readonly!`** — toggle the active
buffer's `read_only` flag (input handlers ignore text-changing keys when set). Useful for
"don't let me accidentally edit this" on a file open for reference.
**Debounced syntax highlighting** — `Buffer.highlights_dirty: bool` flag set on every
text-changing edit (replaces the immediate `refresh_highlights()` call). `App::tick`'s new
`refresh_stale_highlights` sweeps editor panes and re-runs tree-sitter on any buffer
whose last edit was ≥ 120 ms ago. Effect: rapid typing holds the previous frame's
highlights (the buffer text is still live; only the colors lag); after the typing pause,
highlights snap to fresh. Lets `HIGHLIGHT_BYTE_LIMIT` go from 2 MiB to 4 MiB without
laggy typing on big files. The first cut at "incremental" without dropping
`tree_sitter_highlight` (which would require re-implementing injections).
**`:Wc` / `:WordCount`** — classic `wc -lwc` shape: lines / words / chars / bytes for the
active buffer or selection. Sibling to `:Stat` which focuses on file metadata.
**`:Messages!` / `:MessageLog`** — open the full toast/message log in a fresh scratch
buffer (split below). `:messages` toasts the recent 8 inline; the bang form is for "show
me all ~200 entries" so you can scroll / grep.
**`:Sum`** — extract every integer/decimal from the visual selection (or whole buffer)
and toast the count + total. Spreadsheet-y "what does this column add up to" gesture.
**`:CountMatches <pattern>` / `:CountMatch`** — toast the count of regex matches for
`<pattern>` in the active buffer (or selection). Sibling to `:%s/.../.../n` but doesn't
require a replacement.
**`:Wipeout <substr>` / `:Wipe <substr>`** — close every editor pane whose workspace-
relative path contains `<substr>` (case-insensitive). Dirty buffers are kept + toasted
in the count. Useful for "drop everything under `tests/`" after a refactor.
**`:NextDirty` / `:PrevDirty`** (`buffer.next_dirty` / `buffer.prev_dirty`) — jump to the
next / previous editor pane with unsaved changes. Cycles. Useful pre-quit to find what's
still dirty when many buffers are open.
**`:Diffsplit <file>` / `:Diffwith <file>`** — open a diff pane comparing the active buffer's
text against `<file>` (workspace-relative). Same `git diff --no-index` plumbing as
`:DiffOrig` but with `<file>` as the "other" side instead of the buffer's own on-disk
version. Useful for "diff this branch's foo.rs against main's snapshot I just
checked out". Read-only.
**`git.diff_orig`** (`:DiffOrig`) — open a diff pane comparing the active buffer's in-
memory text against its on-disk version. Vim canonical "what have I changed since save?"
New `DiffScope::BufferVsDisk(path)` variant. Implementation: writes buffer text to
`.mnml/tmp/<filename>.diffview`, shells out to `git diff --no-index <orig> <tmp>`,
parses the result through the existing `parse_hunks`. Read-only — the diff pane's
stage/unstage doesn't apply to this scope.
**`picker.clipboard`** — fuzzy picker over the named-register history (`"0` last yank,
`"1`-`"9` delete ring, `"a`-`"z` named). Each row shows `"<reg>  <preview>` (newlines as
`↵`, truncated at 80 chars) with `linewise` as the dim detail. Accept inserts the chosen
register's text at the cursor. New `PickerKind::Clipboard`.
**`:Theme <name>`** — alias for `:colorscheme <name>` (vim canon). Bare form toasts the
current theme. Both `:Theme` and `:colorscheme` round-trip through `set_theme`.
**Vim `]t` / `[t`** — jump to next / previous `TODO` / `FIXME` / `HACK` / `XXX` whole-word
in the active buffer (wraps). Wired into the existing `[`/`]` bracket prefix alongside
`[c`/`]c` (git changes), `[d`/`]d` (diagnostics), `[q`/`]q` (quickfix).
**TODO / FIXME / HACK / XXX inline highlight** — `[ui] highlight_todo_keywords` (default
off; `:set [no]todohl` / `:set todohl!` / `view.toggle_todo_highlight`). When on, those
four whole-word keywords render in bright red across every visible line. Buffer-wide single
scan per render via `find_whole_word_occurrences` (reused from the cursor-word highlight).
**`ai.session_picker`** — pick from past Claude sessions for this workspace. Scans
`~/.claude/projects/<dashed-cwd>/*.jsonl` newest-first; each row shows a short id +
the first user message preview + age. Accept opens a live transcript mirror (the same
read-only follow that `ai.session_view` opens for an active `claude` pty). New
`crate::ai::transcript::list_sessions` + `PickerKind::AiSessions`. Lets you revisit
prior conversations without spinning up a new pty.
**`term.focus_or_open_shell`** — VS Code's `Ctrl+`` shape: focuses an existing terminal
pane if one is open, else opens a new shell. `term.shell` keeps the always-open-new
semantics for users who explicitly want a fresh shell. `Ctrl+T` now binds to the
focus-or-open variant.
**`:Outline` / `:Toc` / `:TOC`** — open the outline pane for the active file (alias
for `outline.show`; sibling to `:Symbols` which opens the picker variant).
**Outline pane "current symbol" indicator** — the row matching the cursor's enclosing
symbol (closest one whose `line` is at-or-before the cursor row) gets a yellow `●` glyph
in front of the kind chip. Selection-arrow still wins when both are the same row.
Approximation: `DocumentSymbol` doesn't carry an end-line, so deeply-nested cursors will
point to the *innermost* preceding symbol — fine for the typical "what fn am I in" use.
**Vim `zE`** — alias for `editor.unfold_all` (vim canon "eliminate every fold"; same
effect in mnml since folds are line-pair entries and unfold = drop).
**Vim Visual `S<c>` (vim-surround)** — wrap the visual selection with `<c>` (quote / bracket
variants). Selection is already live in Visual, so no prefix ops are needed — the handler
clears `pending_surround_ops`, transitions to `Prefix::SurroundAddCharWait`, and bounces back
to Normal once the char arrives.
**Vim `zM`** — alias for `lsp.fold_all` (server-suggested fold ranges). Vim's strict
"fold every block" semantics would need a from-scratch syntactic fold computation; using the
LSP's suggestions is what users want anyway and works on languages where bracket-folding
doesn't (Python, YAML).
**Standard `Ctrl+Enter` / `Ctrl+Shift+Enter`** — VS Code convention for "open new line below /
above". `Ctrl+Enter` goes to end-of-line + newline; `Ctrl+Shift+Enter` goes to start-of-line +
newline + move up. Cursor stays in Insert (standard mode is always editable).
**Standard-mode multi-cursor chords** — `Ctrl+D` now binds to `editor.add_cursor_at_next_word`
(VS Code muscle memory); `Ctrl+Shift+L` to `editor.select_all_occurrences` (drops a cursor at
every whole-word match of the identifier under the cursor in one go). The keymap builder
proactively strips `Ctrl+D` / `Ctrl+U` from the vim chord table so vim mode keeps them as
HalfPageDown / HalfPageUp via the handler. `find_whole_word_occurrences` was hoisted from
`editor_view` to the `editor` module so both the cursor-paint highlight and the multi-cursor
gesture share one scan.
**`view.toggle_bufferline`** (`:set [no]bufferline` / `:set bufferline!`) — hide the open-tabs
strip above the editor body. Useful for single-buffer workflows. Default on. When off, the
`bufferline_area` is omitted from the layout and the body grows up by one row.
**`:Hidden` / `:ToggleHidden`** — flip the file tree's hidden-file visibility (dotfiles +
`.gitignored` entries). Re-scans the tree.
**`:Bonly` / `:bonly`** — close every editor pane except the active one (vim's `:%bd`
equivalent; dirty buffers kept + counted).
**`:Macros` / `:Macro <reg>`** — list all recorded vim macros with their key counts /
replay a specific register's macro. Sibling to `@<reg>` for users who think in ex commands.
**`:A` / `:Alternate`** — vim's "jump to alternate file". Tries common test ↔ source
pairings (`_test` / `_spec` suffix on the stem, `.test.<ext>` / `.spec.<ext>` for
TS/JS). First candidate that exists wins. Stripped when present, added when absent.
**`:Refresh`** — manually rescan the file tree + git status. Useful after external
file operations (cloning a submodule, fetching a branch in another terminal, etc.).
**Middle-click in editor pane** pastes the unnamed register at the click position (X11 /
GTK convention — "primary selection" paste). Focuses the leaf + places the cursor first.
Bufferline-tab middle-click still closes the tab as before.
**`:Echo <text>`** — vim canonical toast of arbitrary text. Useful for keymap confirmation
and plugin debugging.
**LSP `$/progress` busy chip** — long-running server tasks (rust-analyzer indexing,
prettier discovery, etc.) surface as a `⟳ <title>` chip on the statusline right side.
Client parses `$/progress` notifications (`begin` / `report` / `end` kinds);
`LspEvent::Progress{Begin,Report,End}` → `App.lsp_progress: HashMap<token, title>`;
statusline renders any one title (truncated at 28 chars). `initialize` advertises
`window.workDoneProgress: true`. Bumped crate `recursion_limit` to 256 since the
`json!` macro on `initialize` capabilities was hitting the default 128.
**`project.todos`** (`:Todos` / `:TODO` / `:FIXME`) — workspace-wide grep for
`\b(TODO|FIXME|HACK|XXX)\b`; results land in the existing `Pane::Grep` so they're
browseable with the regular grep-pane keys (`n`/`p`, Enter jumps, `r` re-runs).
**`:GBrowse <commit>`** — open the commit's URL on the remote (GitHub / GitLab /
Bitbucket). Resolves short hashes / branch names / `HEAD` via `git rev-parse`. Bare
`:GBrowse` still opens the active file at cursor.
**`:Stat`** — toast the active file's line count, in-memory byte count, on-disk size
(B / KB / MB), and detected language. Combines `g Ctrl+G` + file metadata.
**`:LspRestart`** / **`:LspReset`** — kill every running language server (each
`LspClient` kills its child on Drop), clear the "dead" set, then re-fire `did_open` for
every open editor pane so the servers respawn immediately. The "LSP got stuck" recovery
gesture; otherwise mnml would only respawn the next time a buffer is opened.
**LSP `onTypeFormatting`** — `[editor] format_on_type = true` (default off; `:set
formatontype` / `:set noformatontype` runtime toggle, also `fot` / `nofot`). On each typed
trigger char (`}` / `;` / `\n`), fire `textDocument/onTypeFormatting` at the cursor and
apply the reply via the existing `apply_formatting_edits` path (the reply shape is identical
to `textDocument/formatting`, so the client.rs match arm just joins them). `initialize`
advertises `onTypeFormatting`. Off by default — an LSP rewriting half-typed code is
surprising.
**LSP `willSaveWaitUntil`** — `[editor] will_save_wait_until = true` (default off; `:set
willsavewaituntil` / `:set nowillsavewaituntil` runtime toggle, also `wswu` / `nowswu`).
Fires `textDocument/willSaveWaitUntil` before each save with `reason: 1` (Manual); the
server's `TextEdit[]` reply is applied to the buffer *before* the file hits disk. The save
state machine is now a three-stage chain: `save_active` → wsw (if enabled, sets
`pending_will_save`) → `save_active_after_will_save` → format-on-save (if enabled, sets
`pending_format_save`) → `save_active_now` (disk write + `did_save`). Both pre-save hooks
have a 2-second deadline checked from `tick`; a misbehaving server can't gate save
forever. `initialize` advertises `synchronization.{willSave, willSaveWaitUntil} = true`.
The hook is the canonical pre-save mechanism for servers that do `eslint --fix` /
`organizeImports`-on-save (formatting is for rustfmt / prettier-style whole-file rewrites);
both can run in sequence when configured.
**Ctrl+Click / Ctrl+Shift+Click** in an editor pane — plain `Ctrl+Click` places the cursor at
the click and fires `lsp.goto_definition` (VS Code's "click through"); `Ctrl+Shift+Click`
fires `lsp.references` (peek-references-style gesture). Modifier check happens in
`tui::dispatch_mouse` after the regular click handling so cursor is in position when the
request fires.
**`:Path`** — toast the active editor's full filesystem path (vs `:pwd` which shows the
workspace path).
**Statusline `WRAP` chip** — quiet visible confirmation that `[ui] wrap` is on; easy to forget
the mode is active when the file's lines aren't actually long.
**`:reveal` / `:Reveal` / `:Finder`** (`view.reveal_active`) — show the active file in the OS
Finder / Explorer / file manager. macOS uses `open -R`; Windows uses `explorer /select,<path>`;
Linux opens the parent dir via `xdg-open` (closest portable form — no "select" gesture).
**`git.browse`** (`:GBrowse` / `:Gbrowse` / `:Browse` from fugitive convention) — open the
active file at the cursor's line on the remote's web host (GitHub / GitLab / Bitbucket). With
a multi-line selection, links the range as `#L<lo>-L<hi>`. URL uses HEAD's short SHA so the
link is stable. New `crate::git::browse` module — `parse_remote` handles `git@host:o/r.git`
SSH and `https://[user@]host/o/r[.git]` HTTPS forms; Bitbucket uses `/src/<rev>/` instead of
GitHub/GitLab's `/blob/<rev>/`. New `crate::app::open_url_external` (extracted from the path
opener). Toast on success / "no recognized remote" miss.
**`git.file_history`** (also `:Gflog` / `:FileHistory`) — fuzzy picker over commits that touched
the active file (`git log --follow -- <rel>`, capped at 200, newest first). Each row shows
`<short>  <subject>` with `<age> · <author>` as the dim detail. Accept opens a diff pane for the
chosen commit (`DiffScope::Commit(hash)` → `git show`). New `crate::git::log::commits_for_file` +
`crate::git::log::FileCommit` + `PickerKind::FileHistory` + `App::open_file_history_picker` /
`open_commit_diff`. `humanize_age` was hoisted from `git_graph_view` to be reused.
**LSP `selectionRange`** — vim-style smart-expand selection driven by the server.
`lsp.selection_expand` fires `textDocument/selectionRange` at the cursor; the reply
(parsed as a linked list of `(start, end)` byte ranges from smallest → largest by
`parse_selection_ranges`) is installed as a `SelectionRangeLadder` on `App.selection_range_ladder`.
First press selects the smallest range (token / identifier under cursor); subsequent presses
walk *up* the ladder (`expression → statement → block → function → …`). `lsp.selection_shrink`
walks back *down*. New `InputHandler::request_visual_mode` trait method — vim flips into Visual,
standard is no-op (anchor alone drives the highlight). The ladder's pane index pins which
buffer/pane it belongs to so swapping panes invalidates the cycle. Re-firing expand without a
ladder (or with a stale pane) re-queries the server.
**LSP `folding_range`** — `lsp.fold_all` (no default chord): asks the active buffer's language
server for its suggested fold ranges (`textDocument/foldingRange`); the reply installs each
`(start, end)` as a `Buffer.folds` entry (replaces existing folds — the server is authoritative).
Toasts the count. Works for languages where bracket-based folding doesn't (Python, YAML, plain
text outline) since the server understands the structural shape. `initialize` advertises
`lineFoldingOnly: true` so servers return line-based ranges (mnml's fold model is line-based);
multi-line ranges with `end <= start` dropped. New `LspEvent::FoldingRanges{path, ranges}` +
`parse_folding_ranges` + `LspClient::folding_range` + `LspManager::folding_range` +
`App::lsp_fold_all` / `apply_folding_ranges`.
**LSP `goto_declaration` / `goto_type_definition` / `goto_implementation`** — three siblings of
`goto_definition`. `Declaration` is "the type/forward decl" (vs definition = "where bound") — diverges
from `definition` mainly in C/C++ headers + JS imports; `TypeDefinition` jumps from a value to the type
its bound to (`let x: Foo = …` → `Foo`); `Implementation` jumps from an interface/trait method to one
of its concrete impls. All three reuse `LspEvent::GotoDefinition` for the reply since the response
shape is identical (`Location | LocationLink | (Location|LocationLink)[]`). `initialize` advertises
`linkSupport` on each. Commands `lsp.goto_declaration` / `_type_definition` / `_implementation` (no
default chord — these are less-used than `goto_definition`'s F12); ex aliases `:Declaration` /
`:TypeDefinition` / `:Implementation`.
**Multi-cursor distributed paste** — vim block-paste convention: when the unnamed register
holds N lines and there are N cursors (primary + extras), `p` / `P` distribute one line per
cursor in *visual order* (topmost cursor → first line, bottommost → last). Mismatched line
count falls back to the existing "insert the whole clipboard at every cursor" path. New
`Editor::multi_paste_distribute(parts, after)` handles the cursor/anchor bookkeeping
(descending-position application + per-cursor shift propagation). Round-trip `y` + `P` on a
selection across N rows now does "duplicate this column slice into every selected row" —
the multi-cursor analogue of vim's classic block-yank-paste.
**Multi-cursor `editor.add_cursor_at_next_word`** — VS Code's `Ctrl+D` shape. Word at
the primary cursor is the rename target; first press snaps the primary to end-of-
word; each subsequent press finds the next whole-word occurrence after the bottom-
most cursor and drops an extra there. Then typing fans out: `iX<Esc>` becomes
"insert X at every occurrence" — quick rename via multi-cursor. No default chord
(vim's `Ctrl+D` is HalfPageDown); users can bind via `[keys.standard]`.
**`:Trim` / `:trimws`** — one-shot strip of trailing whitespace on every line in the active
buffer. Single edit op so one Undo restores. Pairs with `[editor] trim_trailing_ws_on_save`
for a per-save version. `Buffer::apply_trim_trailing_ws` is now `pub` for ex-command access.
**Visual-block `I` / `A` / `c` / `s` (multi-line edit)** — the long-asked-for vim power tool.
In VisualBlock mode, `I` enters Insert at the rect's leftmost column; `A` enters at the
right-of-rightmost column. `c` / `s` first delete the rectangle (via `EditOp::DeleteBlock`,
cursor lands at `(rmin, cmin)`) then start the same insert dance. The user types as usual
on the top row; on Esc, the typed run is replayed on every other row in the rect at the
same column. New `AppCommand::BlockInsertStart{append}` and `BlockChangeStart`, new
`App.block_insert_state: Option<BlockInsertState>` (rows, col, start_byte,
top_row_byte_len_before, pane_id, append). The replay polls in `App::tick` — when the
active handler's mode flips from Insert back to Normal AND the state is set, take
inserted_len = top_row_len_now - top_row_len_before, slice that span out of the buffer,
splice it at each other row at byte position `byte_at_col(row, col)`. All per-row inserts
batched through `Buffer::apply_edit_ops` so a single Undo reverts the whole block-insert.
New `InputHandler::request_insert_mode()` trait method (vim flips its internal
`VimMode::Insert`; standard is no-op) lets the App drive the handler without synthesizing
a keystroke. New `Editor::byte_at_col_pub` / `line_byte_len` / `set_cursor_byte` helpers.
Limitations: rows shorter than the rect's leftmost column still get the splice (at EOL —
vim's `A` does this too). Cursor lands at the insert origin after replay (vim convention).
**Vim `zh` / `zl` / `zH` / `zL` (horizontal scroll)** — `zh` / `zl` scroll the viewport one
column left / right; `zH` / `zL` half a screen. Adjust `Buffer.h_scroll` without moving the
cursor. New `App::hscroll_buffer` / `hscroll_buffer_half_screen` helpers; the half-screen form
reads pane width from `App.rects` (fallback 80).
**Vim `gI`** — insert at literal column 0 (vs. `I` which goes to first non-blank).
Single-key chord in the `g` prefix.
**`:1,5j` / `:join`** — bare form joins current+next; ranged form collapses the
range. Same trim+space rules as `J`.
**`:1,5>` / `:1,5<`** — indent / outdent line range by one tab_width step. Parser
also stops at `>` / `<` boundaries (not just letters).
**`:bd!` / `:bdelete!`** — force-close (bypass the dirty prompt).
**Vim `g Ctrl+G`** — toast file stats (lines / words / chars / bytes / cursor
position). Useful for prose buffers (markdown / blog drafts).
**`:ascii`** — alias for `ga` (char info under cursor).
**`:goto N` / `:go N`** — jump to byte offset N (rough — places cursor at the
line containing that byte). Vim canonical for byte-position navigation.
**`:set [no]number` / `:set nu` / `:set nonu`** — toggle the line-number gutter
entirely. `[ui] line_numbers` config (default `true`). When off, the gutter
collapses and the editor expands to fill the freed columns. Blame mode wins
(blame still shows even with `nonumber`).
**`:set cursorline` / `:set cul`** — paint a stronger background tint on the
cursor's row. `[ui] cursor_line` config (default `false`). Theme's `line` color
is the canonical highlight; the existing render path already used it but the
flag now gates whether the user actually sees it.
**`:set scrolloff=N` / `:set so=N`** — keep the cursor at least N lines from
the viewport's top / bottom edge (auto-scroll). `[ui] scrolloff` config (default
0; vim canonical). Clamped to half the viewport height. Mirror
`:set sidescrolloff=N` / `:set siso=N` for horizontal — keeps cursor N cols
from the side edges.
**Persistent ex history** — moved from vim handler to App; survives across sessions
via `SavedSession.ex_history` (oldest first, capped at 100). New `InputHandler::
set_ex_history` / `ex_history()` trait methods so the App can sync. Pre-seeded
into every editor's input handler on session restore + on each new buffer open.
**`picker.recent_commands`** — fuzzy picker over the most-recently-run commands
(newest first, capped at 50). `command::run` notes every successful run on
`App.recent_commands` (de-duped — re-running moves to front; some self-
referential commands skipped).
**Vim `.` (dot) repeat** — re-feeds the last "change" through the dispatcher. A change
is bounded by mode + chord state: starts when the user enters Insert from Normal, when
operator-pending opens a chord, or when a one-shot Normal-mode mutation happens (`p`,
`x`, `~`, etc.); ends when both mode is back to Normal AND no chord is pending. The
recording is finalized only if at least one keystroke during the session produced a
buffer mutation (so cancelled chords like `dEsc` get discarded, not re-fired). Tracked
on the App side (`dot_keys` / `dot_recording` / `dot_recording_saw_edit` /
`is_replaying_dot`); the dispatcher captures `mode` + `pending_display()` before/after
each key and feeds them to `record_dot`. The vim handler's `.` chord routes to
`vim.dot_repeat` which calls `App::dot_replay`. **Limitations**: keys consumed by the
keymap resolver (app-level chords) bypass the recorder; macro-replay-style nested
recursion is suppressed via `is_replaying_dot`.
**`.editorconfig` support** — `Buffer::apply_editorconfig(workspace)` walks up from
the file's directory to (or until `root = true`), parses `.editorconfig` files, and
applies per-file overrides for `tab_width` / `indent_size` ⇒ `editor.tab_width`,
`insert_final_newline` ⇒ `ensure_trailing_newline`, `trim_trailing_whitespace` ⇒
`trim_trailing_ws_on_save`. New `editorconfig` module hand-rolls a minimal INI parser
+ glob matcher (`*` non-`/`, `**` any, `?` one char, exact, `/`-anchored). Brace
expansion `{js,ts}` and char classes `[abc]` skipped — patterns containing them fall
through to no-match (safer than wrong-match). Ran on every `Buffer::open` from the
App side (3 call sites). 6 unit tests in the module.
**Vim `K` / `Ctrl+]` / `Ctrl+T`** — keyword help (LSP hover) / jump to definition /
jumplist back. The latter two are vim's tag-stack chords; mnml aliases them to the
existing LSP/nav commands since we don't have a separate ctags layer.
**External file modification detection** — every ~2 sec `App::tick` calls
`check_external_file_changes` which compares each open editor buffer's
`Buffer.disk_mtime` (set on open + save) against the file's current mtime. Clean buffer ⇒
silently reload (preserve cursor row + scroll best-effort, fire `did_save` to LSP);
dirty buffer ⇒ toast a warning ("<file> changed on disk — :e! to discard / save to
overwrite") and update mtime so the warning fires only once per change.
**Vim `"1`-`"9` delete history** — every delete that goes to the unnamed register also
pushes onto a 9-deep ring (`"1` = most recent, shifts older entries down to `"2`-`"9`,
drops past `"9`). Explicit named-register deletes (`"add`) don't pollute the ring (vim
convention). `Clipboard::push_delete(text, linewise)` is the entry point — wired into
`DeleteLine`, `DeleteSelection`, `CutSelection`, `DeleteBlock`. (Standard mode ops that
implicitly delete a selection — InsertChar / Backspace over a selection — still go
through `delete_selection_if_any` and don't yank.) `DeleteLine` and `DeleteSelection`
now also yank the deleted text into the unnamed register (vim's `dd` / `d{motion}`
convention) — was a long-standing missing piece.
**LSP inlay hints** — `[editor] inlay_hints = true` (default; `:set [no]inlayhints` /
`:set inlayhints!` runtime toggle). `LspManager::inlay_hint(path, line_count)` fires
`textDocument/inlayHint` for the whole file on open + on save; reply parsed by
`parse_inlay_hints` (handles both string-label and array-of-parts shapes) into
`Vec<InlayHint{line, character, label}>` per buffer. `editor_view.rs` paints them as dim
chips at the end of each line that has hints (concatenated with two-space separators if
multiple). Vim canonical position is *inline* — end-of-line MVP avoids shifting real
code cells. `initialize` advertises `inlayHint` capability so servers actually return them.
**Vim named registers** — `Clipboard` gained a `HashMap<char, (String, bool)>` named pool
plus a `pending_register: Option<char>` hint consumed by the next `set` / `text`. The vim
handler parses `"<reg>` (a-z named, `0` last-yank, `+` system, `_` blackhole) into
`VimInputHandler.pending_register`; before returning Ops it prepends
`EditOp::SetRegisterHint(Some(reg))` if the result touches the clipboard
(`Self::touches_clipboard` — yank/paste/cut/delete*/etc.). `set_yank` mirrors into `"0`
on every yank that didn't go to a named register. `:reg` lists every populated register
sorted. `Ctrl+R <reg>` in Insert pastes inline (uses `[SetRegisterHint(reg), Paste]`).
Limitations: no uppercase-append form (`"A` appending to `"a` register); no `"1`-`"9`
delete history; no `"%` / `"#` / `":` / `"/` special registers.
**Vim `gv`** — re-select the last visual selection. The editor remembers `(anchor, cursor)` whenever a
selection is closed (`SelectClear`, `YankSelection`, `DeleteSelection`); `gv` emits new
`EditOp::RestoreLastSelection` to put it back and the handler flips into Visual mode.
**Vim `%`** — jump between matched brackets in normal mode (bridges to `editor.bracket_match`, the same
implementation Standard mode's `Ctrl+]` uses).
**Vim text objects** — `iw` (inner word) and `aw` (around word, includes trailing whitespace) work after
any operator: `diw` deletes, `ciw` deletes + enters Insert, `yiw` yanks, `>iw` indents, `<iw` outdents.
Implemented via new `Prefix::TextObjectInner` / `Prefix::TextObjectAround` (set when `i` / `a` lands in
operator-pending state) plus new `EditOp::SelectInnerWord` / `EditOp::SelectAroundWord` (computed in
`editor.rs::apply` from `word_bounds_at`; "around" extends to trailing whitespace, or leading whitespace
when at end-of-line). **Quote variants** — `i"`, `a"`, `i'`, `a'`, `` i` ``, `` a` `` work too:
`SelectInnerQuote(char)` / `SelectAroundQuote(char)` ops, with `editor::enclosing_quote_pair_on_line`
**Paragraph variants** — `ip` / `ap` select the cursor's paragraph (`SelectInnerParagraph` /
`SelectAroundParagraph`). A paragraph is a maximal run of non-blank lines; `ap` extends to include
trailing blank lines (vim convention). When the cursor sits on a blank line the range covers that
blank run instead. New `Editor::paragraph_bounds(around)` helper.
scanning the cursor's line for unescaped quote pairs and choosing the one that flanks the cursor.
Restricted to a single line so a multi-line string elsewhere can't fool the scan. **Bracket variants** —
`i(`, `a(`, `i[`, `a[`, `i{`, `a{`, `i<`, `a<` (close-bracket alias accepted too: `i)` ≡ `i(`).
`SelectInnerBracket(open)` / `SelectAroundBracket(open)` ops; `editor::enclosing_bracket_pair` walks
back from the cursor for an unmatched open, then forward for the matching close (depth-counted,
50k-char budget per side). Spans multiple lines unlike the quote variants.
**Half-page scroll** — new `EditOp::HalfPageUp` / `HalfPageDown` (interpreted in `editor.rs::apply` with
`vp / 2`). Bound to `Ctrl+U` / `Ctrl+D` in vim normal mode (vim canonical).
**Vim `gf`** — open the path under the cursor (vim `gf`); routes through the `editor.open_at_cursor`
command (also bound to `Ctrl+Shift+O` in standard mode). Supports `path:line:col` suffixes.
**Vim `gx`** — open the URL under the cursor in the OS's default browser. Pulls the
whitespace-delimited token around the cursor, strips trailing punctuation (`<>()[]"'.,;:`),
checks for a known scheme (`http`/`https`/`file`/`mailto`/`ftp`), hands off via `open` /
`xdg-open` / `start` (same opener machinery as the file-tree right-click).
**Vim `Ctrl+W` split-nav prefix** — in vim normal mode, `Ctrl+W` is intercepted as a window-chord
prefix (new `Prefix::Window`). Two pieces of plumbing make this work despite the global keymap
binding `Ctrl+W` to `buffer.close`: (1) `Keymap::build` proactively removes `Ctrl+W` and `Ctrl+G`
from the resolved chord table when `input_style = "vim"` so the global resolver doesn't swallow
them — applied *before* user `[keys.*]` overlays so users can still rebind via `[keys.vim]`. (2)
The vim handler's "plain motions" early-return (which would otherwise treat `w` as `MoveWordRight`
even with Ctrl) now skips when `ctrl` is held, falling through to the modifier-aware arms below. Subsequent key picks the action: `h`/`j`/`k`/`l` (or arrows) focus
the split in that direction (`view.focus_left/right/up/down`); `w` cycles (`view.focus_next_split`);
`q`/`c` close (`view.close_split`); `s` splits down; `v` splits right; `=` equalizes every split's
ratio to 50/50 (`view.equalize_splits` → `Layout::equalize_splits`); `o` closes every other pane
(`view.close_others` — same as `:only`); `r` rotates the active leaf with its sibling
(`view.rotate_splits` → `Layout::swap_siblings_containing`); `+`/`-` grow/shrink height of the
nearest enclosing vertical split; `>`/`<` grow/shrink width of the nearest enclosing horizontal
split (5% step). `Layout::adjust_split_ratio_for(target, dir, grow_delta)` flips the sign based
on which side `target` is in, so the chord always grows the pane the cursor is in.
`H`/`J`/`K`/`L` (uppercase) move the active leaf to the left / bottom / top / right of its
*immediate* parent split — `Layout::move_active_to(target, dir, to_second)` updates the parent's
direction (if needed) and swaps siblings (if needed). Poor-man's vs vim's "promote to outermost"
canonical behavior — operates on the immediate parent only.
**Vim `gi`** — jump cursor to the most-recent edit position (last entry of `Buffer.edit_history`)
and enter Insert mode. The "enter Insert" half is delivered by re-feeding an `i` keypress through
`dispatch_key` (only meaningful in vim mode — `gi` is a vim chord, so the dispatch lands on vim's
`i` arm). Toasts when there's no recent edit.
**Vim `[c` / `]c` / `[d` / `]d`** — bracket prefix (new `Prefix::BracketOpen` /
`Prefix::BracketClose`) for "go to prev/next thing":
  `[c` / `]c` jump to the prev/next git hunk in the active buffer (uses
  `App.git.snapshot().line_changes` — consecutive change lines grouped into hunks; wraps).
  `[d` / `]d` jump to the prev/next LSP diagnostic (routes through the existing
  `lsp.prev_diagnostic` / `next_diagnostic`). Standard mode keeps `Ctrl+W` bound to `buffer.close`
(browser-tab convention) — the vim handler intercepts before the keymap resolver gets a chance.
`pending_display` shows `^W` in the statusline while the chord is pending.
**Vim `gqip` / `gqap`** — paragraph reflow as an operator + text-object: `gqip` reflows the
inner paragraph (same effect as `gqq`); `gqap` is the same op for now since the around-paragraph
extension doesn't change reflow output. Wired through new `PendingOp::Reflow` and the existing
`TextObjectInner` / `TextObjectAround` prefixes. The vim handler caches `text_width` from config
at construction (rebuilt on `editor.use_vim`); a `:set text_width=N` between handler builds is
visible to `gqq` (which goes through the App command and reads live config) but not to `gqip` /
`gqap` until the next handler rebuild.
**Vim macros** (`q...q` / `@`) — single anonymous register MVP. `q` in vim normal toggles
recording (the toggling `q` itself is removed from the captured stream); `@` replays. Captures
every `KeyEvent` flowing through `tui::dispatch_key` (gated on `App.macro_state ==
Recording`); `Replaying` ignores `@` to prevent unbounded recursion. The proper
named-register form (`qa...q`, `@a`) is a follow-up — would require register-aware Clipboard.
**Snippet placeholder polish** — `SnippetSession.stop_cursors: Vec<Option<usize>>` records the
cursor's exit position at each visited stop. Backtab to a previously-visited stop now lands at
the end of typed content there (vim convention — was the start of the stop before). Forward Tab
to a not-yet-visited stop still uses the placeholder's bare position.
**Sticky scroll** — when a fold's body extends past the top of the viewport, the editor view
overwrites body row 0 with the fold's start line (bold + `bg2`) so the user always knows what
function/section they're inside. Pure post-process: the line that *was* at row 0 gets covered
(user can scroll up by one to see it). Picks the smallest enclosing fold (closest scope). Only
active when `Buffer.folds` is non-empty.
**Folds survive line-shift edits** — `feed_key`'s per-op snapshot computes `cursor_line_before`
+ line-count delta, then `Buffer::shift_folds_after(at_line, delta)` adjusts every fold's
`(start, end)` pair: above the edit ⇒ keep, below ⇒ shift by delta, straddling ⇒ drop. Batch
edits via `apply_edit_ops` still clear folds wholesale (that path is for LSP rename / code
actions / find-replace where multiple edits at different positions would need per-edit
attribution we don't track).
**Vim `gqq` paragraph reflow** — greedy word-wrap the cursor's paragraph to `[editor] text_width`
(default 80; runtime `:set text_width=N`). New `EditOp::ReflowParagraph{width}` uses `paragraph_bounds`
to find the range, splits into words, rebuilds with line-wrapping. Preserves the first line's leading
whitespace as the indent on every wrapped line so indented prose stays indented. The `gqq` chord routes
through `editor.reflow_paragraph` (the App method reads `text_width` from config). Operator-pending
forms (`gqap`, `gq` + motion) aren't wired yet — `gqq` is the bounded MVP.
**Vim `zz` / `zt` / `zb`** — scroll the viewport so the cursor lands at center / top / bottom (the
cursor itself doesn't move). New `App::scroll_cursor_in_view(frac)` adjusts `buf.scroll` from the
cursor row + the active pane's recorded rect height (accounts for the breadcrumb row when on).
Wired into the `ZFold` prefix; commands `view.cursor_to_center` / `_top` / `_bottom` register them
for the palette too.
**Vim `Ctrl+A` / `Ctrl+X`** — increment / decrement the next decimal integer on the cursor's line.
Counts apply: `5<C-a>` adds 5, `3<C-x>` subtracts 3. New `EditOp::ChangeNumberAtCursor{delta}`
walks forward from cursor to the next digit, picks up a leading `-` only when it qualifies as a
sign (the char before isn't an identifier char — so `(-5)` is `-5`, but `x-5` is `5`). Cursor lands
on the last digit of the modified number (vim convention). No-op when no digit is on/after the
cursor.
**Vim normal-mode `~`** — toggles the case of the ASCII letter under the cursor and advances right.
`[count]~` repeats. New `EditOp::ToggleCaseChar`.
**Vim visual case ops** — `u` lowercases, `U` uppercases, `~` toggles case of the active selection.
New `EditOp::TransformSelectionCase(CaseTransform::Lower|Upper|Toggle)` — replaces selection in
place, drops the selection, returns to Normal mode (vim convention). Toggle is ASCII-only (uses
`is_ascii_uppercase`/`lowercase`); Lower / Upper use Unicode `to_lowercase` / `to_uppercase`.
**Vim `Y` / `J` / `gJ`** — `Y` yanks the current line (alias for `yy`, emits `EditOp::YankLine`). `J`
properly joins the next line in via `EditOp::JoinLines{keep_space: true}` — trims trailing whitespace
from the current line, trims leading whitespace from the next, inserts a single space (omitted when
the current line is empty, vim's convention). `gJ` joins verbatim (`keep_space: false`) — no space
inserted, no whitespace trimmed. `[count]J` / `[count]gJ` repeat — `3J` brings two lines up. Cursor
lands on the inserted space (or at the join boundary when none was inserted).
**Vim change list (`g;` / `g,`)** — every text-changing edit pushes the cursor's `(row, col)` onto the
buffer's `edit_history: Vec<(usize, usize)>` (capped at `EDIT_HISTORY_MAX = 100`); consecutive entries
within a few columns of each other dedupe so a burst of typing doesn't bury the list. `g;` walks back,
`g,` walks forward (cursor index is `edit_history_cursor`, sits past the newest after each edit). Vim
chords go through `AppCommand::RunCommand("editor.jump_prev_edit"/"jump_next_edit")` →
`Buffer::jump_prev_edit` / `jump_next_edit`. `App::jump_prev_edit` also pushes the current position onto
the nav-back stack so `Alt+Left` returns. Toasts the new `row+1:col+1`. Hooked into both `feed_key`'s and
`apply_edit_ops`'s "if changed" branches via `Buffer::note_edit_position`. **Persisted across launches**
via `SavedEditHistory{path, entries}` in `session.json` — restored for any buffer re-opened in the
session; rows past the file's current line count are dropped silently.
**Nav stacks (`Alt+Left` / `Alt+Right`)** — `App.nav_back` / `nav_forward: Vec<NavPoint{path, row, col}>`
are now persisted in `session.json` (capped at `NAV_STACK_MAX = 50` on restore) so browser-style
back/forward navigation survives a relaunch.
selection/undo/clipboard; fuzzy file finder (`Ctrl+P`) + command palette
(`Ctrl+Shift+P` where the terminal supports the kitty protocol, else `F1`) + buffer
switcher (`src/picker.rs` / `src/fuzzy.rs`); config-driven keymap — app-level chords
resolve through `App::keymap` (`src/input/keymap.rs::Keymap`), built from each
`Command`'s default `keys: &[&str]` overlaid with `[keys.global]` / `[keys.<style>]`
config (`"key" = "command.id"`, `= "none"` to unbind); which-key leader popup
(`src/whichkey.rs` trie + `src/ui/whichkey.rs`) — `<space>` in vim Normal or `Ctrl+K`
opens it, keys descend a group, a leaf runs its command (`whichkey.leader` command;
state on `App.whichkey`); editor splits — `Layout` is a binary split tree (`Empty | Leaf |
Split{dir,ratio,first,second}`), `ui::draw` recursively renders one editor per leaf with
1-cell dividers; each leaf shows a distinct buffer, background buffers (in no leaf) are
allowed (bufferline shows all), `App.active` = focused pane = uniquely the focused leaf;
`view.split_right`/`view.split_down`, `view.focus_{left,right,up,down}`,
`view.focus_next_split`, `view.close_split` commands, surfaced in the which-key `+split`
submenu (`<leader>s …` / `Ctrl+K s …`); click a leaf to focus it, drag a divider to
resize it; closing a dirty buffer pops a Save/Discard/Cancel overlay (`src/ui/close_prompt.rs`).
tree-sitter syntax highlight (`src/highlight.rs`, 39 grammars: rs/js/jsx/ts/tsx/py/json/go/
toml/css/bash/html/md/c/cpp/rb/java/cs/lua/yaml/scala/ex/hs/php/swift/make/zig/nix/ocaml/dart/sql/kt/regex
+ dockerfile (Containerfile/Dockerfile.* filenames too) + hcl (terraform/tf/tfvars) + proto + diff/patch +
vue + svelte + astro — `build_config` maps file extensions → `(language, highlights, injections, locals)`
query set; cheap aliases (jsonl/ndjson → json, mdx → md, sass → css, fish → sh) ride on the parent
grammar's arm; `config_for_lang` resolves *injected* languages so fenced code blocks in markdown /
embedded HTML·CSS·JS get highlighted too, and the markdown `text.*` captures are in `HIGHLIGHT_NAMES`.
hcl + proto + vue have to vendor their highlights/injections queries under `queries/*.scm` — upstream
hcl ships none, proto comments them out of the bindings, vue-next's build.rs cfg-gating mis-points at
the query files — so we `include_str!` local copies.) + indent guides; hybrid relative line numbers (`[ui] relative_line_numbers`,
`:set [no]relativenumber`, `view.toggle_relative_numbers` — cursor line absolute, others = distance).
**Build version (`MNML_GIT_SHA`)** — `build.rs::emit_git_sha` reads `git rev-parse --short=9 HEAD`
(+ `git status --porcelain` for a `-dirty` suffix) and emits it as `cargo:rustc-env=MNML_GIT_SHA=…`.
Surfaced via the `:version` ex-command (toasts `mnml <sha>`); a future settings/about pane will own
the long-form display. Used to live as a chip at the right edge of the statusline — too cluttered
for the steady state, so removed. Falls back to `build-<unix-seconds>` if git isn't available.
**Tree section header** — VS-Code Explorer style: the rail starts with a `> WORKSPACE-NAME` row that's clickable; default
expanded (`v WORKSPACE-NAME` + file list). Two independent state bits — `tree_visible` (rail in/out, `Ctrl+B` /
`view.toggle_tree`) and `tree_root_expanded` (the section's collapse, `view.toggle_tree_section` / click on the header).
Both persisted in `.mnml/session.json`. **`> GIT` rail section** — sibling of WORKSPACE: a collapsible section below the
file list (`src/git/rail.rs` = `GitRail{branches:Vec<BranchRow{name,is_current}>, worktrees:Vec<Worktree>, current_branch,
cursor, scroll}`, refreshed via `branch::local_branches` + `branch::worktrees` + `branch::current` on every
`after_git_change()` and on startup); `src/ui/tree_view.rs` renders it after the workspace files (which cap their height
to leave room for up to 8 git rows) — a dim `branches` sub-label, the branches (`●` = current, `○` = other), then
`worktrees` (`⤿` = the worktree we're in, `·` = other; label shown as `branch (dirname)`). The rail's keyboard focus
tracks which section it's on (`App::rail_section: RailSection::Workspace|Git`) — `↓` at the bottom of the workspace list
flips to git, `Esc`/`h`/`←` in the git section flips back; the renderer paints the cursor on the focused section. Click a
row to focus + run its default action (branch ⇒ `git_checkout_named`, worktree ⇒ `open_worktree_shell`). Right-click a
row opens a per-row context menu (`open_git_rail_context_menu`) — branch: Checkout / New branch from here… /
Delete <name>… (the current branch only gets "New branch from here…"); worktree: Open shell here / Reveal in Finder /
Copy path / Remove worktree… (the current worktree is non-removable). Delete + remove go through a "type the name to
confirm" prompt (`PromptKind::GitDeleteBranch` / `GitWorktreeRemove`, the rail's confirm idiom); on confirm,
`branch::delete_branch` / `branch::worktree_remove` shell out to `git branch -D` / `git worktree remove`. "New branch
from here…" captures the source ref via `App.pending_branch_source` and the prompt title shows
`New branch name (off <source>)`; on accept `branch::create_from` shells out to `git checkout -b <new> <source>`
(the bare `git.new_branch` command still branches off HEAD). Section expand
state (`git_section_expanded`) persisted in `session.json`. Click on the `> GIT` header toggles it
(`toggle_git_section_expanded`) and parks the rail's keyboard on the git section.
**Drag-to-resize the rail** — the rail's right-edge cell is a draggable handle: mouse-down + drag adjusts
`App.tree_width` live (clamped to `[8, screen_width - 20]`); the new width persists in `session.json` so a
relaunch keeps your preferred rail size. `begin_tree_edge_drag` / `drag_tree_edge_to` / `end_tree_edge_drag`
on `App`; the rect is recorded as `app.rects.tree_edge` in `ui::draw`. The `[ui] tree_width` config still
seeds the initial width on a fresh workspace. **Tree FS actions** — right-click a file or dir in the tree → "New file…", "New
folder…", "Rename…", "Delete…" (the delete prompt requires you to type the entry's filename to confirm). The "New file"
flow is also wired to `Ctrl+N` (`file.new`) for workspace-relative paths from anywhere; missing intermediate dirs are
auto-created. Rename / delete repoint or close any open editor buffer for the affected paths (LSP `did_close` / `did_open`
follow). `Tree::expanded_dirs()` / `set_expanded_dirs` persist the per-directory expand state in `tree_expanded_dirs` so
a relaunch keeps whatever the user had open. **Tree filter** — `/` in the focused tree enters
filter mode (`Tree.filter_mode = true`); printable keys append to `Tree.filter`, Backspace pops,
Enter exits filter mode (keeping the narrowed view), Esc clears + exits. `Tree::filter_visible_set`
fuzzy-matches each entry's file name and walks ancestors so the matched paths' parent dirs stay
visible (so `src/lsp/client.rs` matching also shows `src/` and `src/lsp/`). While filtering, every
visible directory renders as expanded regardless of the user's expansion state. The tree-view
reserves one row at the top for the `/ <query>` input line when active.
**Bufferline polish** — horizontal scroll (`bufferline_first_visible`) keeps the active tab on screen no matter how many
buffers are open, with `‹` / `›` overflow chevrons at the edges. Same-name tabs get parent-dir disambiguation (`git/mod.rs`
vs `ai/mod.rs`) via `tab_labels(&panes)`. **Middle-click closes a tab** (browser-tab pattern, handled in
`tui::dispatch_mouse`). Per-tab **diagnostic chip** (`bufferline::diag_chip_for`) — editor
tabs whose buffer has LSP diagnostics render `✗N` (errors, red) or `⚠N` (warnings, yellow) between the name
and the dirty badge; errors win over warnings. Widths recompute so the strip layout stays tight. **Statusline polish** — `Ln 12/580` (current of total) + a yellow `Sel N` chip
when there's a selection (chars selected). **Find chip** — when a `find.find` is active on the buffer, a yellow
`/<query> N/M` chip surfaces on the left side (after diagnostics) so the match count is visible without re-opening the
prompt; the query is char-truncated at 24.
**Zen mode** — `view.zen` (`Ctrl+Shift+Z`) hides tree + bufferline + statusline; the editor takes the full window.
Overlays (picker, prompt, hover, completion) still work. Not persisted — fresh launch is a normal IDE view.
**Reopen closed buffer** — `buffer.reopen` (`Ctrl+Shift+T`, `<leader>b r`): pops the
most-recently-closed editor off `App.closed_buffers` (capped at `CLOSED_BUFFERS_MAX = 20`, populated by
`force_close_pane` when the file isn't open in another pane). Re-uses `open_path` so the captured
`(cursor, scroll)` from `file_cursors` is restored. Not persisted across sessions — that's what
`recent_files` is for.
**Recent files** — `App::recent_files` (last 20 paths opened, de-duped, newest-first) updated in `open_path` and persisted
in `session.json`. `picker.recent` (`Ctrl+R`) opens a fuzzy picker over them. Also surfaced at the **top of `Ctrl+P`** —
`open_file_picker` prepends recent files (in recency order) before the workspace file list (de-duped against it). Empty
query → recents on top (the fuzzy `refilter` keeps original order on tie scores); start typing → score-based ranking
takes over and the order is determined by the match.
**Persisted theme** — `theme.pick` writes the picked theme name to session.json; restore calls a silent `set_theme_silent`
so a "theme: …" toast doesn't pop on every launch. Unknown theme names ⇒ launch default. **`Ctrl+G` go to line** —
standard-mode equivalent of vim's `:N`. **Esc clears find highlights** — Esc on an editor with active find drops the find
state before the input handler sees the Esc (vim's normal-mode transitions still work). **`:w <path>` save-as** — also
`:saveas <path>`. Repoints the buffer, creates parent dirs, refreshes git / tree / LSP / md preview / blame.
**`:e` / `file.reload` reload from disk** — re-read the active buffer, preserving cursor + scroll. `:e!` to force-discard
dirty changes. **Optional editor extras** — `[editor] ensure_trailing_newline` (on by default; appends `\n` on save when
the buffer doesn't already end with one — POSIX text file convention. Goes through `apply_edit_ops` so
undo can revert. Empty buffers are skipped. `:set [no]eol` runtime toggle), `[editor] trim_trailing_ws_on_save`
(off by default; strips trailing space/tab per line on `save_to_disk` via `EditOp::ReplaceRange` so undo restores them; cursor preserved + clamped),
`[editor] breadcrumb` (default on; a dim workspace-relative path row above each editor body — middle-truncates with `…`),
`[editor] auto_pair` (off by default; typing `(` `[` `{` `"` `'` `` ` `` inserts the matching close char when the next
char is "empty space" — whitespace, EOF, closer, or punctuator. Typing a close char on top of an auto-inserted one
skips over it). **Bracket-match highlight** — when the cursor sits on a bracket, paint both the bracket and its match
with `bg3`; nested correctly via a forward/backward depth-counting scan (capped at 50k chars/side).
**Highlight word under cursor** — `[ui] highlight_word_under_cursor` (default off; `:set [no]hlword` /
`:set hlword!` / `view.toggle_highlight_word`). When the cursor is on an identifier (`[A-Za-z0-9_]+`,
provided by new `editor::word_under_cursor`), every other whole-word case-sensitive occurrence in the
buffer renders with a subtle `bg2` background tint (the cursor's own occurrence is skipped — no point
flagging the word you're already on). New `find_word_occurrences(text, word)` does a buffer-wide single
scan per render (cheap for typical files).
**Trailing-whitespace highlight** — `[ui] highlight_trailing_ws` (default off; `:set [no]trailing` /
`:set trailing!` / `view.toggle_highlight_trailing_ws`). Paints the trailing space/tab run on each line
with a red background so stray whitespace is impossible to miss. Pure-whitespace lines aren't flagged
(no real "trailing" to fix); selection / find-match bg colors still win over the trailing tint when they
overlap. Pair with `[editor] trim_trailing_ws_on_save = true` for see-and-strip.
**Editor scrollbar** — `[ui] scrollbar` (default on; `:set [no]scrollbar` / `:set scrollbar!` /
`view.toggle_scrollbar`). When on, `ui/editor_view.rs` reserves the right-edge column of each editor pane
for a 1-cell vertical scrollbar: dim `bg_dark` track over the full body height, plus a `bg3` thumb whose
height = `(text_h² / line_count)` and top = `(scroll * max_thumb_top) / max_scroll` (proportional to the
visible portion + where the viewport sits in the file). Thumb is hidden when the file fits in the viewport.
The reserved column shrinks `text_w` by 1 (so the cursor/h-scroll logic naturally keeps text out of the
scrollbar's column).
**Rainbow brackets** — `[ui] bracket_rainbow` (default off; `:set rainbow` / `:set norainbow` /
`view.toggle_bracket_rainbow`): paint every visible `()[]{}` in a depth-cycling 6-color palette (yellow,
purple, blue, green, cyan, red — pulled from the theme). `editor::bracket_depths_per_line` walks the whole
buffer once per render (cheap — single linear scan), returning per-line `(col, depth)`; the cells loop in
`editor_view` looks each up and overrides the syntax color for that cell. Mismatched brackets are tolerated
(`saturating_sub` on depth) — the goal is a stable depth indicator, not strict balance.
**Session restore** — `[session] restore = true` (default; flip off to disable). On quit (`save_session_on_quit`, called
from both the `tui` and `headless` loops just before exit) the open editor buffers + their cursors + the **split tree**
(serialized via `SavedLayout`, leaves keyed by index into `open`) are written to `<workspace>/.mnml/session.json`. On
launch (`main.rs` → `try_restore_session` right after `App::new`) the buffers re-open in tab order (skipping any that no
longer exist), then `layout_from_saved` rebuilds `App.layout` from the saved tree (or skips it if any leaf can't be mapped
to a re-opened buffer). The previously-active one gets focus. Workspace mismatch / corrupt json ⇒ silently skip. Layouts
with non-editor leaves (transient pty / browser / etc.) drop the layout part — `saved_layout_from` returns `None` and the
buffer list alone is saved.
**Persistent undo** — every file save writes the editor's undo+redo stacks to `<workspace>/.mnml/undo/<hash>.json`
(FNV-1a 64 of the absolute path, capped at 100 most-recent snapshots per file via `PERSISTED_UNDO_LIMIT`); every
`Buffer::open` calls `editor::load_history_from` to restore them. The file pins the text it's valid against via
a `text_hash` field — if the file was edited outside mnml between sessions the load returns `false` and the
history is silently discarded (the offsets in old snapshots would no longer map onto the new text). Helpers:
`editor::undo_path_for(workspace, file)`, `editor::save_history_to(editor, path)`, `editor::load_history_from
(editor, path)`. I/O errors are swallowed end-to-end — persistent undo is a UX nicety, not load-bearing.
**Find-in-buffer** — `find.find` (`Ctrl+F`, palette) prompts for a query (seeded with the active selection or last query),
`accept_find` populates the active buffer's `FindState{query, matches:Vec<(byte_start,byte_end)>, current, regex}`
(`buffer::find_all_ci_ascii` for literal mode — ASCII case-insensitive, non-overlapping, char-boundary safe — or
`buffer::find_all_regex` for regex mode — auto-prefixed with `(?i)` for case-insensitivity, zero-width matches
skipped, invalid patterns → empty), jumps the cursor to the nearest match at-or-after the cursor (wraps), and
toasts `match N/M`. **`find.toggle_regex`** (`Alt+R`) flips between modes — sticky across the session (sets
`App.find_regex_default`) and immediately rebuilds the active find's match list. `find.next` (`F3`) / `find.prev` (`Shift+F3`) step through (wrap);
`find.clear` empties the state. `editor_view` paints a `t.bg2` background on every visible match and a `t.yellow` bg on the
current one (with `t.bg_dark` fg for readability). The find state is recomputed on every text-changing edit
(`Buffer::refresh_find_matches`, hooked into `feed_key` + `apply_edit_ops`) so highlights stay in sync as you type.
**Smart-case find** — literal-mode searches default to case-insensitive; any uppercase letter in the
query flips them to case-sensitive (ripgrep / fzf convention). Implemented via new
`FindState.case_sensitive` flag picked between `find_all_case_sensitive` (new in `buffer.rs`) and
`find_all_ci_ascii`. Regex mode ignores this flag — its `(?i)` is fixed for now.
**Find history** — `accept_find` pushes each non-empty query onto `App.find_history` (de-duped against
the most-recent entry, capped at `FIND_HISTORY_MAX = 50`). Up / Down on the open Find prompt walk back
and forth through history (`find_history_prev` / `find_history_next`); the live input is the entry past
the newest. Each walk reuses the incremental-find preview path so the editor highlights match the
recalled query immediately. **Persisted across launches** in `session.json` (oldest-first, capped at
`FIND_HISTORY_MAX` on restore).
**Incremental find** — every keystroke on the open `PromptKind::Find` prompt fires
`App::update_live_find_preview` which rebuilds the buffer's find state from the partial query (no cursor
move — just the highlight set + match index). The cursor doesn't jump until Enter; Esc restores the prior
find state from `App.find_preview_snapshot` so cancelling a search doesn't leak match highlights. Accept
commits the live state (snapshot dropped). `tests/e2e/find_incremental.test` covers the type → highlight
→ Esc-restore flow.
**Replace** — `find.replace` (`Ctrl+H`) opens a `PromptKind::Replace` (requires a non-empty find state; titled
`Replace N× "<query>" with`). Accept ⇒ `App::accept_replace` builds `EditOp::ReplaceRange` for every match in
*descending* offset order so earlier byte offsets stay valid, hands them to `Buffer::apply_edit_ops` (which also
refreshes the find matches + bumps LSP `didChange`), toasts `replaced N`.
**Workspace grep** — `find.grep` (`Ctrl+Shift+F`) opens a `PromptKind::Grep` prompt (seeded with the selection),
shells out to `rg --vimgrep --no-heading --smart-case <q> .` (or `git grep -n --column -I -e <q>` if `rg` isn't on
PATH); `crate::grep_pane::parse_rg_vimgrep` parses `path:line:col:text` lines (1-based on the wire → 0-based hits,
char-boundary safe, capped at 2000) into `GrepHit{path,rel,line,col,text}`. Results open as a **`Pane::Grep`** in a
split below the focused leaf — `src/grep_pane.rs` = `GrepPane{query,used,hits,selected,scroll}`, `src/ui/grep_view.rs`
renders a header (`N matches · rg: query`) over the hits grouped by per-file `▸ rel  (N)` headers. ↑↓/jk/PgUp/PgDn/g/G
select, Enter jumps to the file + line (and the pane stays open — "jump and keep the list"), `r` re-runs the same query
(swapping in the fresh hits, refreshing the header), `R` replaces every hit across every file (`find.grep_replace` →
`PromptKind::GrepReplace` titled `Replace N× "<query>" with`; per file: if it's open as a clean editor pane apply
`EditOp::ReplaceRange`s through `apply_edit_ops` + `save_to_disk` + LSP `didChange`, else read+splice+write directly,
skipping dirty open buffers with a toast), Esc → tree; wheel moves the selection too. Only one grep pane open at a time
— a fresh query into an existing pane refills it in place.
**Theme engine** (`src/ui/theme.rs`): a `Theme`
struct (named UI colours + `base16[16]`) behind an `RwLock`; `theme::cur()` reads it,
`theme::set(name)` swaps it. Themes are all of NvChad's base46 schemes (~90), converted
to `themes/*.toml` (`[base_30]` + `[base_16]` colour tables), enumerated by `build.rs` →
`THEME_SOURCES` and parsed (serde/`toml`) at first use; `onedark` is the default (also
kept hardcoded as the seed/fallback).
`[ui] theme = "…"` at launch, `theme.pick` command / `:set theme=…` at runtime
(re-highlights open buffers). Markdown preview — `Pane::MdPreview` (`src/ui/md_preview.rs`,
a block-level renderer: headings/lists/fenced code/blockquotes/hrules styled, inline
markers unwrapped, long lines word-wrapped to the pane width via `md_preview::wrap_lines`
[hanging indent for lists/quotes; also used by `ai_view`]); `markdown.preview` command
(`<leader>m`) opens a rendered, read-only, scrollable view in a split next to the source,
live-updated on every edit (any of `.md`/`.markdown`/`.mdx`/`.mkd`). **Right-click "Preview
markdown"** — entries surface on the file-tree context menu and the bufferline tab context
menu when the file is markdown; both run `App::open_md_preview_for_path(path, near, focus_preview=true)`
which focuses an existing preview of the same path, or **swaps the preview into the active leaf**
(takes the full pane — the source becomes a background buffer in the bufferline). The in-memory
text is pulled from any open editor for that file so the preview tracks unsaved edits.
**Auto-open** — `[ui] auto_md_preview = true` (off by default; `:set [no]automdpreview` runtime
toggle): on every `open_path` for a markdown file, opens the preview pane *split alongside* in
passive mode (`focus_preview=false`, so focus stays on the editor — the side-by-side workflow).
The two flows differ deliberately: explicit triggers replace (full width because that's what the
user reached for); auto-open splits (you wanted the editor open AND a live preview).
Idempotent — opening the same file twice doesn't re-split.
Git: branch + change counts in the statusline + tree tint + per-row git-state badge in the
tree (`M`/`A`/`?`/`!` right-aligned, colour-matched to the existing tint — modified/staged/
untracked/conflicted; rendered by `ui/tree_view.rs`); **gutter line-signs** —
`src/git/diff.rs` parses `git diff HEAD --unified=0` into per-file added/modified/removed
line marks (kept in `GitStatus`'s ~3s-cached `Snapshot.line_changes`), drawn as a coloured
`▎` in the editor gutter; **peek change at cursor** — `git.peek_change` (`<leader>g p`) shells out to
`git diff HEAD --unified=3 -- <rel>` (via `crate::git::diff::peek_hunk_at`), finds the hunk whose new-side
range contains the cursor's line (`Hunk::contains_new_line`, with pure-deletion hunks anchoring to the row
above), and opens the result as a `HoverPopup` (new `HoverPopup::from_lines` ctor skips the markdown
cleanup so leading `+`/`-`/` ` markers survive). Toasts "no change at cursor" when off a modified line.
**diff pane** — `Pane::Diff` (`src/ui/diff_view.rs`) shows parsed
hunks (header + context/`+`/`-` lines), `n`/`p` move the cursor hunk, `s`/`u` stage/unstage
it (`git apply --cached [--reverse]`), `r` refreshes, Enter jumps to the hunk's line in the
source editor; `git.diff_file` (`<leader>g d`, opens in a split next to the source) /
`git.diff` (worktree). **Intraline diff** — adjacent single `Removed`/`Added` pairs (one-for-one
swap, no neighbours of the same kind) get char-level highlighting: `git::diff::intraline_diff(old, new)`
computes the common-prefix + common-suffix char ranges; the diff pane renders the matching prefix/suffix
in `t.comment` (gray) and the differing middle in bold red/green so the eye lands on the change.
Multi-line edits (runs of removeds/addeds) skip this — pairing them would need an LCS. **blame gutter** — `git.blame_toggle` (`<leader>g b`) swaps the
line-number gutter on the active editor for a per-line `<sha> <author>` column
(`src/git/blame.rs` parses `git blame --porcelain`), refreshed on save; **commit** —
`git.commit` (`<leader>g c`) opens the single-line text-input overlay (`src/prompt.rs` /
`src/ui/prompt.rs`, a generic "type a string, Enter" sibling of the fuzzy picker) →
`git commit -m`; **commit graph** — `Pane::GitGraph` (`src/git/log.rs` reads `git log --all`
+ `for-each-ref` and computes a single-row-per-commit lane layout — node `●`, pass-through
`│`, corner glyphs at branch/merge points; `src/git/graph.rs` = `GitGraphPane` state w/ a
lazily-loaded per-commit detail; `src/ui/git_graph_view.rs` draws the lane graph + commit rows
[hash · ref chips · subject · age · author, selected row highlit] above a detail panel
[message · parents · changed files]). `git.graph` (`<leader>g l`); in the pane ↑↓/jk select,
PgUp/PgDn/g/G jump, Enter opens that commit's diff (`DiffScope::Commit(hash)` → `git show` —
read-only, staging refused), `r` refresh, `y` copy hash, Esc → tree, wheel moves the selection;
commits refresh open graph panes. **staging view** — `Pane::GitStatus` (`src/git/stage.rs`:
`git status --porcelain` → unstaged/staged file lists, `stage`/`unstage`/`stage_all`/`unstage_all`
[`git add` / `git restore --staged`, `git reset` fallback], `staged_diff`; `GitStatusPane` state;
`src/ui/git_status_view.rs` renders the two sections + branch/counts header). `git.status_pane`
(`<leader>g s`); in the pane ↑↓/jk select, PgUp/PgDn/g/G jump, `s`/`u`/Space stage·unstage·toggle,
`a`/`A` all, Enter → that file's diff, `c` commit prompt, `C` ai-commit, `r` refresh, Esc → tree.
**AI commit message** — `git.ai_commit` (`<leader>g m`, also `C` in the staging pane): `claude -p`
summarises `git diff --cached`; the result lands (via `App.pending_commit_msg_job`, sharing `ai_chan`)
in the commit prompt pre-seeded with its first line (`Prompt::seeded`).
**Codex commit message** — `git.codex_commit` (`<leader>g x`): same shape but invokes `codex exec`
instead of `claude -p`. New `ai::stream_codex_to_channel` mirrors `stream_to_channel` (refactored
to share a `stream_cli_to_channel` core that takes the binary + args, so both flow through the
same reader-thread + cancel-loop machinery). Codex is stateless per call (no `--session-id`).
**AI recompose HEAD's message** — `git.ai_recompose` (`<leader>g M`): same shape, but the prompt
context is `git show HEAD --stat -p` + the current message (`commit::show_head` / `commit::head_message`),
the job is routed via `App.pending_amend_msg_job`, and the resulting `PromptKind::GitCommitAmend`
prompt's accept calls `commit::amend` (`git commit --amend -m`) instead of a fresh `git commit`.
Limited to HEAD for now — rewriting older commits would need interactive rebase machinery. Per-hunk staging (diff pane),
commit, and staging-pane ops all run through `App::after_git_change()` (refreshes the cached status +
every open `GitGraph`/`GitStatus` pane). **branches / worktrees** — `src/git/branch.rs` (local/remote
branch lists, `git worktree list --porcelain`, `checkout` / `checkout --track` / `checkout -b`):
`git.checkout` (`<leader>g o`, `b` in the staging pane) — fuzzy picker over local + remote branches
→ `git checkout` (remotes via `--track`); `git.new_branch` (`<leader>g n`, `B`) — prompt → `git checkout
-b`; `git.worktrees` (`<leader>g w`, `w`) — picker over the worktrees → opens a shell pane in the chosen
one; after a checkout `App::after_checkout()` refreshes git + tree and toasts (warns if unsaved editors
are open). **`git.stash` / `git.stash_pop`** (`<leader>g S` / `<leader>g P`) — `src/git/stash.rs` shells
out to `git stash push -u [-m <msg>]` and `git stash pop`. The stash command opens a
`PromptKind::GitStashMessage` prompt for an optional message (Enter alone ⇒ untitled stash); pop is
fire-and-forget. Both refresh git status + tree and warn on unsaved-buffer surprises after the
operation. headless+IPC (interactive TUI listens too) + the `run.sh`/`dev.sh`
wrappers. The statusline git segment shows branch + `⇡ahead ⇣behind` + `✚staged ●modified
…untracked ⚠conflicts` (only the nonzero parts), from `git status --porcelain -b`. The Git
track is done (phase 4 — branch-rail UI [vs the picker], commit-with-Codex, "recompose commit with AI", multi-repo — is queued; see `.local/PLAN.md`). **HTTP track — in progress:** `src/http/` holds `Request`/`Response` +
`send` (reqwest blocking, rustls), `curl.rs` (parse a pasted cURL), `file.rs` (`.http`/
`.rest`/`.curl` parsing, multi-block via `### name`), `template.rs` (`{{VAR}}` from
`.mnml/env/<name>.env` → process env → dynamic `{{$uuid}}`/`{{$timestamp}}`/…), `script.rs`
(`@set-header`/`@set-env` pre-request + `@assert`/`@capture` post-response directives in `#`
comments, with a `.foo.bar[0]`/`$.path` JSON resolver); wired as `mnml run FILE [--env NAME]
[--workspace DIR]` — apply `@set-*` → expand `{{}}` → parse → send → print body → run
`@assert`s (✓/✗, non-zero exit on any failure; without asserts a non-2xx fails) → show
`@capture`s. Inside the IDE: **`rqst.send`** (`<leader>h s`) on a `.http`/`.rest`/`.curl`
editor (the `### block` under the cursor for multi-block files) parses + applies `@set-*` +
expands `{{}}` (env from `.mnml/env/$MNML_ENV`), opens a `Pane::Request` split, and fires
the send on a **background thread** (`App.http_chan`; `App::tick` drains it) — `src/request_pane.rs`
holds the state (`RunState::Sending|Done|Failed`), `src/ui/request_view.rs` renders the
request line + headers + body, then status/headers/pretty body + ✓/✗ asserts + ⇒ captures
(scroll with `k/j`/PgUp/PgDn, `r` re-fires, `y` copies-as-curl, Esc → tree); `rqst.copy_curl`
(`<leader>h y`) copies the request as a curl command. **Chains** — `src/http/chain.rs` runs a
`.chain.json` (`[{ "request": "a.curl", "extract": { "VAR": "$.path" } }, …]`): each step
expands `{{}}` against the running env, sends, runs its `@assert`/`@capture`, then `extract`s
into env vars for the next step; stops at the first transport error / non-2xx-3xx / failed
assert / empty extract — wired as `mnml chain run FILE [--env NAME] [--workspace DIR]`.
**Discover** — `src/http/discover.rs` reads an OpenAPI/Swagger spec (local JSON or http(s)
URL) and writes one `.curl` stub per operation under `<out>/<tag>/<operationId>.curl` (path
params → `{{name}}`, `security` ⇒ `Authorization: Bearer {{TOKEN}}`, JSON body from a spec
`example`); `mnml discover SPEC [--out DIR] [--base-url URL]` (default out `.mnml/requests`).
**Editable request pane** — `Pane::Request` is now two-mode: **Response** (read-only summary, the default —
status / headers / pretty body / `@assert` / `@capture` from the last send) and **Edit** (Postman-style form
— URL, method, body editable in place). `Tab` toggles modes; `e` from Response also enters Edit. In Edit:
`Shift-Tab` / `Tab` cycle the focused field (URL → Method → Body → URL), typing / Backspace / Left / Right /
Home / End edit, `Up`/`Down` in Body do cross-line motion (the URL is single-line — newline keystrokes
dropped), `Space` on Method cycles `GET → POST → PUT → PATCH → DELETE → HEAD → OPTIONS → GET`
(`request_pane::cycle_method`), `Enter` on URL or Method fires (`Enter` in Body inserts a newline). `r` always
re-fires the request using the current field values (so tweaking a URL and re-sending doesn't require flipping
back to the source file). Edit-view tab bar at the top shows `[Edit] [Response]` with the active one bolded +
underlined. `src/request_pane.rs` = `RequestPane{view:ViewMode::{Response,Edit},
focus:EditField::{Url,Method,Headers,Body}, url_cursor, body_cursor, headers_buffer, headers_cursor, …}` mutates
`request.url` / `request.method` / `request.body` directly. **Headers** are edited as a multi-line `Key: Value`
text buffer (`headers_to_text` serialises from `request.headers`; `parse_headers_text` parses back, dropping
blank lines + lines without `:`); `RequestPane::commit_headers` (called from `App::refire_request` before each
send) writes the parsed list onto `request.headers`. The view styles each header line as `<key in cyan> :
<value in fg>` so the structure is visible at a glance even though the editing model is still a flat textarea
(lines without `:` mid-edit render dim-gray as a hint they're not yet a valid header). **`Ctrl+S` over a request pane** writes the edited request
back to its source file (`App::save_active` routes to `App::save_request_to_source` when the active pane is
a Request); pane without a `source_path` ⇒ toast and bail. **Format-preserving multi-block writeback** —
`send_request_from_active` captures `RequestPane.source_block_name` when the source is a multi-block
`.http` / `.rest` (`Some("name")` for `### name`, `Some("")` for bare `###`, `None` for the leading
unnamed block or single-block files). On save, multi-block sources go through `splice_http_block` (re-parses
the on-disk file, finds the matching block by separator name, replaces just that block's line range with
`RequestPane::as_http_block(...)` — the canonical `### name\nMETHOD url\nHeaders\n\nbody` rendering — and
preserves every other block verbatim, including the file's trailing-newline policy). Splice-failure (file
edited externally so the source block is gone) refuses with a toast rather than overwriting. Single-block
sources (`.curl`, or `.http` with one block) still get the simple curl-overwrite write path.
**Pty / AI-CLI panes — first cut done:** `src/pty_pane.rs` (`portable-pty` +
`vt100`) — `PtySession` = a live pty + child + a `Mutex<vt100::Parser>` a reader thread pumps;
`BinaryProfile::shell()/claude_code(ws)/codex(ws)` (claude injects `.mnml/CLAUDE.md` via
`--append-system-prompt`); `Pane::Pty(PtySession)`; `src/ui/pty_view.rs` renders the vt100 grid
(theme bg/fg for the default colours, resizes the session to its area each frame, places the
caret when focused, "[process exited]" banner). `term.shell` (`Ctrl+T` / `<leader>a t`),
`ai.claude_code` (`<leader>a c`), `ai.codex` (`<leader>a x`) open one as a stacked split below
the focused leaf. A focused pty forwards keys→bytes to the child (`tui::pty_key_bytes`,
xterm-ish) — the global chords (esp. `Ctrl+E` cycle-focus, `Ctrl+B` tree) are the way back out
since they resolve before pane dispatch; `Ctrl+W` closes the pane (kills child, joins reader).
The event loop polls at 40 ms while a pty is open. **AI on-selection actions — done:** `src/ai/mod.rs`
runs `claude -p --session-id <uuid> "<prompt>"` (the CLI in print mode — tool use, returns text,
user's auth) on a worker thread (`ai::stream_to_channel` — spawns the child, a reader thread pumps
stdout chunks straight to `App.ai_chan` as `AiMsg::Delta`s while it runs, then `settle()` sends a
final `AiMsg::Done`/`Failed`; polls `try_wait` + an `AtomicBool` cancel flag, kills the child if it
goes true; `one_shot_cancellable` is the kept non-streaming variant);
`Pane::Ai(AiPane{title,prompt,session_id,job_id,state:Asking|Streaming(buf)|Done|Failed,scroll,target,cancel})`
shows the answer (the streaming buffer, then the final text) rendered as markdown (via
`md_preview::render_markdown`, with a `▌ …` cursor while `Streaming`) — `src/ui/ai_view.rs` (which
pins the scroll to the tail while streaming). Commands `ai.explain` / `ai.fix` / `ai.refactor` / `ai.write_tests`
(`<leader>a e/f/r/w`) feed the active editor's selection (or the whole buffer if nothing's
selected) + a task prompt; `ai.ask` (`<leader>a a`) takes a free-text question via the prompt
overlay (`PromptKind::AiAsk`). Results stream in via `App.ai_chan` / `App::tick` → `drain_ai_jobs`
(the commit-message job shares the channel — it ignores deltas, acts on the final text); the event
loop polls at 40 ms while a `claude -p` run is in flight (`App::has_pending_ai`). In the AI pane:
`r` re-asks (fresh session), `x` cancels an in-flight run
(`App::cancel_active_ai` → `cancel` flag → worker kills `claude -p`, replies `Failed("cancelled")`),
Esc → tree, **`a` applies the suggested code (two-phase)** — for a `fix`/`refactor` action the source
range is recorded as the pane's `crate::ai::ApplyTarget{path,start,end}`; the *first* `a` extracts the
answer's first fenced code block (`crate::ai::first_code_block`), diffs it against the live range
(`crate::ai::line_diff` — common prefix/suffix trimmed to ±3 context, the middle as `-`/`+`), and stages
it as `AiPane.pending_apply` (the pane renders the diff under a `── proposed change ──` header); the
*second* `a` (`App::do_apply_suggestion`) `ReplaceRange`s it over the range (offsets clamped to the
buffer's current len, edit left dirty — review & undo to revert); `r` (re-ask) discards a staged
suggestion. The `.` key in a request pane is the sibling `App::ai_debug_request` (request + response →
`claude -p`). **`c` promotes a `Pane::Ai` to an interactive Claude Code pane** — `claude --resume <session_id>` in a `Pane::Pty` below, with
the conversation already loaded (so a quick `-p` answer isn't a dead end — you can drill in /
let it apply edits). **JSONL session tail — done:** `src/ai/transcript.rs` reads
`~/.claude/projects/<dashed-cwd>/<session-id>.jsonl` into `Vec<Turn>` (user / assistant / thinking
preview / tool-use one-liner / truncated tool-result; meta + side-chain lines skipped); `AiState::Live
{path, last_len, turns}` is a live mirror — `App::tick` (`refresh_live_ai_panes`) appends just the
bytes past `last_len` (up to the last complete line) when the `.jsonl` grows, full-re-reads if it
shrank; `ui/ai_view.rs` renders the turns (assistant text as markdown). `claude` panes are spawned with a
known `--session-id` (`BinaryProfile.session_id`), so `ai.session_view` (`<leader>a m`) opens a
mirror for the active `claude`/Ai pane; `c`-promoting a `Pane::Ai` also flips that pane into a
live mirror of the (now-interactive) session. `G` follows the bottom.
**Playwright track — runner + results tree + trace pane done:** `src/playwright/mod.rs` runs `npx playwright test
--reporter=json --trace=retain-on-failure [args]` on a worker thread (`App.tests_chan` / `App::tick`), parses the JSON report
into a flat `TestRun{tests: Vec<TestCase{title,suite_path,file,line,status,duration_ms,error,trace_path}>}` (ANSI
stripped from error messages; `trace_path` = the retained `trace.zip` from a result's `attachments`); `Pane::Tests(TestsPane{state:Running|Done|Failed,...})` shows the
command + a ✓/✗/≈/⊘ tally + the tests grouped by file (highlighted selection, failure error inline) —
`src/ui/tests_view.rs`. Commands `test.run_all` / `test.run_file` / `test.run_at_cursor` (Playwright's
`file:line` selector) / `test.rerun_failed` (`--last-failed`) under `<leader>T` (`+test` a/f/t/l); in
the pane ↑↓ select, Enter jumps to the test's source, `t` opens the selected test's **trace** (`App::open_selected_test_trace`),
`h` heal-with-Claude, `r` re-runs (same args), `a`/`f` run all/file, `R` last-failed, Esc → tree. **Trace pane** — `src/playwright/trace.rs`
(`parse_trace_zip` reads the `*.trace` NDJSON entries from a `trace.zip` via the `zip` crate, pairs `before`/`after` action records by `callId`,
collects `console` / `error` / `stdio` events, re-bases times → a time-ordered `Vec<TraceEvent{at_ms,dur_ms,kind,title,detail,error}>`)
+ `src/playwright/trace_pane.rs` (`TracePane` state) + `src/ui/trace_view.rs` (a scrollable timeline — `+1.23s  ⏵ page.goto("…")  234ms`,
selected row highlit, the selected event's params/error stack in a panel below). `Pane::Trace`; in the pane ↑↓/jk select, PgUp/PgDn/g/G jump,
`h` heal-from-trace (`TracePane::timeline_text` renders the timeline → `App::heal_from_active_trace` → `claude -p` via `ask_ai`, opening a
`Pane::Ai` — Claude sees the *runtime* trace and uses its tools to read the spec/code; `c` in the answer pane promotes to interactive Claude Code),
`r` re-parses, Esc → tree. **Per-kind filter** — `TraceKindFilter{actions,console,errors,stdio}` (all on by default); `a`/`c`/`e`/`s` toggle one
kind, `E` is the errors-only preset, `A` shows everything; header chips dim out hidden kinds; the selection snaps to the next visible row when
it would otherwise be hidden.
**Sort mode** (`s` in the pane) — `TestsSort` (`FileLine` = the default, natural Playwright order grouped under per-file
headers; `DurationDesc` = slowest first, flat list with a `file:line` chip on each row). `TestsPane::sorted_indices(&run)`
yields indices into `r.tests` in the current sort order; the renderer walks that, the selection is still a raw `r.tests`
index. Cycle clears `scroll` so a re-ordered list starts from the top. **Wobbly-test history** — `src/playwright/history.rs` (`TestHistory` = `HashMap<(file\tsuite\ttitle), Vec<HistOutcome>>`,
last 10 outcomes per test) persists to `<workspace>/.mnml/test-history.json` (serde_json; corrupt/missing ⇒ start fresh;
write failures swallowed — UX nicety, not load-bearing). Loaded once in `App::new`, updated + saved in
`App::drain_tests_jobs` after each `TestsState::Done`. A test is **wobbly** if its kept window has at least one pass AND
at least one non-pass; `src/ui/tests_view.rs` shows a `≋` glyph (purple, bold) next to wobbly test rows + a `≋ N` chip
in the tally next to the ✓/✗/≈ counts. Skipped runs aren't recorded (no info). A brand-new failing test isn't wobbly
yet — let it run a few times.
**Flaky-test dashboard** — `Pane::Flaky` (`flaky.show` / `<leader>T w`): a workspace-wide list of every wobbly test
across recent runs. `src/playwright/flaky_pane.rs` = `FlakyPane{items:Vec<FlakyItem{path,rel,title,line,outcomes}>,
selected,scroll}`; `src/ui/flaky_view.rs` renders a `≋ N wobbly tests` header + per-file group labels with a row per test
that shows the compact outcome bar (`✓✗~✓✗`, last 10 runs) + the title + `:line`. ↑↓/jk select, PgUp/PgDn/g/G jump,
Enter jumps to the test in source (line 0 = "we never recorded a line, opens at top"), `r` rebuilds, Esc → tree.
`TestHistory` now also stores `last_line: HashMap<key, u32>` (`#[serde(default)]` keeps old `test-history.json` files
loadable) so the dashboard has a line for each test without re-running Playwright; `App::drain_tests_jobs` calls
`refresh_flaky_panes` after each test run so open flaky panes update live.
**CDP / browser track — first cut done:** `src/cdp/mod.rs` launches Chrome/Chromium (first of a known list) with
`--remote-debugging-port=0 --user-data-dir=<ws>/.mnml/chrome-profile <url>`, reads the chosen port off Chrome's
stderr, hits `http://127.0.0.1:PORT/json` for the first page target's `webSocketDebuggerUrl`, connects via
`tungstenite` (sync, no TLS — DevTools is plaintext localhost), enables `Page`/`Runtime`/`Log`; then a worker
thread pumps the WebSocket ↔ a command channel (`CdpCommand::Send(json)`/`Close`) in one loop (short socket read
timeout makes it cooperative — same shape as the pty/AI workers) and forwards every protocol message up over
`App.cdp_chan` as `CdpEvent::{Connected,Message(json),Closed}`. `Pane::Browser(BrowserPane)` (`src/browser_pane.rs`:
`{url, cmd_tx, log:Vec<LogLine{kind,text}>, net:Vec<NetEntry>, net_focus, net_sel, next_id, pending_eval, scroll, closed}`;
`Drop` sends `Close` → kills Chrome) shows a header (current URL) + a live colour-coded log — console output
(`Runtime.consoleAPICalled`/`Log.entryAdded`/`Runtime.exceptionThrown`), main-frame navigations (`Page.frameNavigated`),
a filtered network log (`Network.requestWillBeSent`/`responseReceived`/`loadingFailed` → `→ GET host/path` / `← 200 …` /
`✗ request failed`, but only Document/XHR/Fetch — the asset firehose is dropped via `cdp_resource_type_is_interesting`),
and `eval` request/result lines — rendered by `src/ui/browser_view.rs`. The same filtered requests are *also* accumulated
as `NetEntry{request_id,method,url,headers,post_data,status,mime,failed}` records (`note_net_request`/`_response`/`_failed`,
matched by `requestId`). `App::drain_cdp_events`/`apply_cdp_message` route events to the pane;
`browser.open` (`<leader>B`, palette) prompts for a URL (`PromptKind::BrowserUrl`) and launches; in the pane `g`
navigates (`PromptKind::BrowserNavigate` → `Page.navigate`), `e` evals JS (`PromptKind::BrowserEval` → `Runtime.evaluate`,
`returnByValue`; the reply is matched by id → a `= …` line), `r` reloads, `s` screenshots (`browser.screenshot` →
`Page.captureScreenshot` → base64 PNG decoded + written to `<ws>/.mnml/screenshots/shot-<ms>.png` via `App::save_screenshot_png`),
k/j/PgUp/PgDn/Home/End scroll, Esc → tree, `Ctrl+W` closes (kills Chrome). **`n` toggles a network panel** — the `net` records
as selectable rows (`METHOD status host/path [mime]`, status colour-coded); ↑↓/jk/PgUp/PgDn/g/G/Home/End move the selection,
`y` copies the selected request as a curl command (`NetEntry::as_curl` — pseudo-headers `:method`/… skipped), `Enter` opens it
in a `Pane::Request` split (`NetEntry::to_request` → `spawn_http_job`, re-sends), `n`/Esc leave the panel (then Esc → tree);
the wheel moves the selection too. (When a request's body isn't inlined — `hasPostData:true` but no `postData` — a
`Network.getRequestPostData` is fired and `BrowserPane::fill_post_data` patches the `NetEntry` when the reply lands.)
**Type-to-narrow filter** — `/` while `net_focus` enters filter mode (`BrowserPane.net_filter` /
`net_filter_mode`); printable keys narrow against `"<METHOD> <short_url>"` via `crate::fuzzy::fuzzy_match`, Backspace pops,
Enter exits the mode (keeping the filter), Esc clears the filter + exits the mode. Selection space switches to *filtered
indices* — `net_sel` is `0..visible_net_indices().len()` while a filter is held; `selected_net` resolves through. Esc with
an inactive filter still held clears it first (the canonical "narrow → exit" two-step); a second Esc actually leaves the
panel. Header chip shows `network (M/N)` while narrowed, `network filter: ..._ · Backspace · Enter · Esc clears` while
typing.
**`D` toggles a DOM panel** — first press fires `DOM.getDocument {depth:-1, pierce:true}`; `browser_pane::parse_dom` walks
the reply into a flat `Vec<DomRow{depth,label,selector,node_id}>` (whitespace text + shadow-root wrappers skipped; iframes
recursed); rows render indented + colour-coded (elements blue, text white, comments dim). ↑↓/jk/PgUp/PgDn/Home/End/g/G
move the selection (wheel too), `c` copies the highlighted node's CSS-ish selector (`html > body > div#main.card`),
**`h` draws the live highlight overlay on the page** (`Overlay.highlightNode {nodeId}` — `DOM.enable` + `Overlay.enable` are
in the initial domain-enable set), **`H` toggles hover-follow mode** —
`BrowserPane.dom_hover_highlight: bool` (default off); when on, every change in `dom_sel` (j/k/PgUp/PgDn/g/G/Home/End)
fires `Overlay.highlightNode` so the page's overlay box tracks the keyboard selection in real time. `set_dom_sel` /
`move_dom_sel` call `maybe_hover_highlight` after every selection change; toggling on immediately fires for the current
selection, toggling off fires `Overlay.hideHighlight`. Esc on the DOM panel also resets the toggle.
**Type-to-narrow DOM filter** — `/` while `dom_focus` enters filter mode (`BrowserPane.dom_filter` /
`dom_filter_mode`); printable keys narrow against `"<label> <selector>"` via `crate::fuzzy::fuzzy_match`, Backspace pops,
Enter exits the mode (keeping the filter), Esc clears + exits. Selection space switches to filtered indices — `dom_sel`
indexes into `visible_dom_indices()`; `selected_dom` resolves through. Esc with a held filter clears it first (the
canonical "narrow → exit" two-step). Filter changes auto-fire hover-highlight if follow mode is on so the page's overlay
tracks the narrowed selection. Header chip shows `DOM (M/N)` while narrowed, `DOM filter: ..._ · Backspace · Enter · Esc
clears` while typing.
**`S` screenshots the selected DOM node** (`browser.screenshot_node`) — two-step CDP flow: `DOM.getBoxModel { nodeId }`
→ reply parsed via `bbox_from_quad` (handles rotated quads — axis-aligned bbox of the 4 content-corner points) →
`Page.captureScreenshot { clip: {x, y, width, height, scale: 1} }`. The PNG lands in `.mnml/screenshots/` via the same
path as a full-page screenshot. New `BrowserPane.pending_node_screenshot` slot is distinct from `pending_screenshot` so
the two reply paths don't collide. `node_id == 0` (synthetic / un-screenshottable) ⇒ no-op + toast; off-screen nodes
where the bbox can't be computed log a `bbox unavailable` warning.
**`Z` scrolls the selected DOM node into view** (`browser.scroll_node_into_view`) — fires
`DOM.scrollIntoViewIfNeeded { nodeId }` so off-screen nodes become reachable by `S` (screenshot needs the bbox to be in
the viewport for `Page.captureScreenshot` to land anything useful) and `h` (overlay highlight isn't visible if the node
is scrolled off). Fire-and-forget — no reply handler needed; the page just scrolls.
**`Ctrl+R` opens a URL history picker** (`browser.url_history`) — fuzzy picker over `App.browser_url_history` (capped
at `BROWSER_URL_HISTORY_MAX = 100`, newest first). The history accumulates from every main-frame `Page.frameNavigated`
event (extracted via the new post-match `nav_url` capture in `apply_cdp_message`) and persists in `session.json` so
previously-visited URLs are available on fresh launch. Accept ⇒ `Page.navigate` the active browser pane to the chosen
URL. `about:blank` / empty URLs are skipped from history.
**`K` toggles a cookies panel** — fires `Network.getCookies` on first press, parses the reply via
`browser_pane::parse_cookies` into `Vec<CookieEntry{name, value, domain, path, expires, http_only, secure, same_site}>`,
and renders each row as `[SH] name=value · domain · path · <expires> <sameSite>`. The `S` / `H` chip lights up green
when `secure` is set, yellow when `http_only` is set. `expires` humanizes against now (`session` / `5m` / `2h` / `3d` /
`expired`). ↑↓/jk/PgUp/PgDn/Home/End move the selection (wheel too), `y` copies the selected `name=value` pair, `R`
re-fetches, Esc → back. Mutually exclusive with the net + DOM panels.
**`L` toggles a Web Storage panel** — reads both `localStorage` and `sessionStorage` for the current top-level page via
`Runtime.evaluate` against a fixed IIFE (`STORAGE_EVAL_EXPR` — wrapped in try/catch since `file://` and some
sandboxed origins throw on access). Reply parsed via `parse_storage_eval` into `Vec<StorageEntry{key, value, is_local}>`
(local entries first, then session). Each row renders as `[L] key=value` or `[S] key=value` — purple chip for
localStorage, yellow chip for sessionStorage. ↑↓ / jk / PgUp / PgDn / g / G / Home / End move the selection, `y` copies
`key=value`, `R` re-fetches, Esc back. Eval-based instead of `DOMStorage.getDOMStorageItems` so we don't have to enable
a new CDP domain or extract securityOrigin from the page URL.
**`d` in the cookies panel deletes the selected cookie** (`browser.delete_cookie`) — fires `Network.deleteCookies`
with the cookie's `{ name, domain, path }` so the match is narrow (a name-only delete drops the cookie across every
domain, usually too broad). The row drops locally on dispatch (optimistic); the next `R` re-fetch confirms with the
browser. Pairs naturally with the `K` cookies panel for "log out by clearing this session cookie" debug flows.
**`e` / `a` in the cookies panel edit / add cookies** (`browser.edit_cookie` / `browser.add_cookie`) — `e` opens a
prompt seeded with the current value; accept fires `Network.setCookie` with the same name+domain+path so the existing
cookie is replaced. `a` prompts for `name=value`; the cookie is scoped to the active pane's URL host (via `host_of_url`)
with path `/`. Both refresh the panel via `fetch_cookies` after dispatch. Together with `d` (delete), the cookies panel
now has full read/write/delete.
**`e` / `a` / `d` in the storage panel** — symmetrical with cookies. `e` opens a prompt seeded with the current value
of the selected entry; accept evals `localStorage.setItem` (or `sessionStorage.setItem`). `a` prompts for
`scope|key=value` where scope is `local` (default) or `session`. `d` evals `removeItem` for the selected entry and
drops the row locally. All three use `BrowserPane::eval_silent` (fire-and-forget eval that doesn't push a `» …` log
line or claim `pending_eval`).
**Bufferline overflow chevrons + wheel-scroll** — the `‹` / `›` chevrons that appear when
the tab strip overflows are now clickable (registered as
`app.rects.bufferline_overflow_left/right` whenever they're painted; click adjusts
`bufferline_first_visible` by 1). Wheel over the bufferline strip also scrolls by one tab
per tick (`scroll_under` matches `app.rects.bufferline` and updates first-visible). No
keybinding equivalent — the chord-driven tab strip already keeps the active tab on screen,
so this is purely for "I can see there are more tabs, let me page through them with the mouse."

**Request-pane mouse clicks** — the `[Edit]` / `[Response]` tab chips (registered in
`app.rects.request_tabs`) switch view; in Edit mode each field row (Method / URL / Headers /
Body — registered per visible line in `app.rects.request_fields`) clicks to focus that field
+ flip to Edit mode if currently in Response. The `request_view::draw` uses the same
`std::mem::take` swap as `browser_view` so the renderer can push to `app.rects` while still
holding the `rp` borrow. Field rect `y` values are stored as row indices within the rendered
`rows` vec and translated to screen y by the caller after `scroll` is applied.

**Browser sub-panel mouse clicks** — each row in the network / DOM / cookies / storage panels
registers a rect in `app.rects.list_rows` per render (via a `std::mem::take` swap so the renderer
can write to `app.rects` while still holding the `Pane::Browser` borrow). The `handle_scm_row_click`
dispatcher gains a `Pane::Browser` arm that routes single-clicks to the right per-panel
selection setter (`dom_sel` / `cookies_sel` / `storage_sel` / `net_sel`); double-clicking a
network row opens it as a Request pane (sibling to `Enter`). Closes the last list-style mouse
gap — every selectable row in the codebase is now click-targetable. **`tests/ipc.rs`** integration
test exercises the file-IPC channel end-to-end (open / run-command / type / register-command /
quit / unknown) by writing JSONL into `command` then asserting on `screen.txt` / `status.json` /
`events.jsonl`. Catches the headless wire format regressing without a real headless run.

**Active device preset persists across mnml relaunches** — `App.last_browser_device:
Option<usize>` (preset index) is saved on `SavedSession.last_browser_device` and restored on
launch. Every fresh `browser.open` re-applies it via `browser_pane.set_device(idx)` so the
emulated viewport survives a Chrome restart (Chrome itself loses state — the *choice* is what
persists; on relaunch the next browser pane lands already emulating without the user re-picking).
Picking the Reset row in the `m` picker also clears the persisted value. Out-of-range saved
indices (e.g. after a preset removal in code) drop silently on restore.

**`m` opens a device-emulation picker** (`browser.device_picker`) — fuzzy picker over
`crate::browser_pane::DEVICE_PRESETS` (iPhone 15 / iPhone SE / Pixel 8 / Galaxy S22 / iPad / iPad Pro 12.9" /
Desktop 1366×768 / Desktop 1920×1080) plus a top "Reset — clear device emulation" entry. The active preset
gets a `●` chip; the picker accept fires `Network.setUserAgentOverride` + `Emulation.setDeviceMetricsOverride`
(or the matching clear ops for Reset). Both are fire-and-forget — effects show on the next navigation / reload.
The active preset surfaces as a purple `📱 <label> · <w>×<h>` chip on the pane header so the emulated state is
always visible. New `BrowserPane.current_device: Option<usize>` records the index. UA strings are mid-2024
Chrome shapes — plausible but not auto-updated.

**`p` prints the current page to PDF** (`browser.print_pdf`) — fires `Page.printToPDF` (printBackground on so
brand colors / CSS backgrounds survive). The reply's base64 `data` decodes + writes to
`<workspace>/.mnml/screenshots/page-<ms>.pdf` (same dir as screenshots — "captures from the browser pane" all
in one place) via the new `save_pdf_bytes` helper; the file is handed to the OS's default PDF viewer
(`open_path_external`). New `BrowserPane.pending_pdf: Option<i64>` mirrors `pending_screenshot` so the two reply
paths don't collide. Only bound when no sub-panel is focused (the per-panel letters keep priority).

**`P` toggles a performance panel** (`browser.perf`) — eval-fetches `performance.getEntriesByType('navigation')[0]`
plus paint entries + LCP via `PERF_EVAL_EXPR` (a fixed IIFE). `parse_perf_eval` converts the result into
`PerfMetrics{dns, tcp, ttfb, response, dom_interactive, load, fcp, lcp}` — each field is `Option<f64>` (None when ≤ 0
or non-finite, since metrics that haven't fired yet show as 0 or NaN in the eval result). Renderer paints a
fixed-list view: each row `label · value` formatted as `123 ms` or `1.23 s`. Core Web Vitals get traffic-light
coloring (LCP < 2.5s green, < 4s yellow, ≥ 4s red; FCP < 1.8s/3s/≥3s; TTFB < 800ms/1.8s/≥1.8s). `R` re-fetches.
Mutually exclusive with the other panels. `R` re-fetches, `D`
(or Esc) leave the panel (Esc also clears any highlight via `Overlay.hideHighlight`). After `s` writes the PNG, `open_path_external` hands it to the OS default app (`open` on macOS,
`xdg-open` on Linux, `cmd /C start` on Windows; best-effort, errors swallowed). `Target.setDiscoverTargets {discover:true}`
is also sent on connect so popups / new-tabs show up as `⤴ new tab → url` log lines (`Target.targetCreated` with
`attached:false`). **Multi-page (`Target.attachToTarget`)** — the connect sequence also sends
`Target.setAutoAttach {autoAttach:true, waitForDebuggerOnStart:false, flatten:true}`. Auto-attached popups / new
tabs / iframes flow into `BrowserPane.targets: Vec<BrowserTarget{session_id,target_id,title,url,kind}>` via
`Target.attachedToTarget` events; `Target.targetInfoChanged` updates title/url; `Target.detachedFromTarget`
removes them (the main entry — index 0, empty session_id — is sticky). `T` opens a fuzzy picker
(`PickerKind::BrowserTargets`) over the discovered targets; accept sets `current_target`. Outbound CDP messages
get wrapped with `sessionId` via `cdp::with_session(message, session_id)` (flatten-mode routing) when the
current target isn't the main page, so subsequent `Page.navigate` / `Runtime.evaluate` / `Page.reload` /
`Page.captureScreenshot` / `DOM.getDocument` drive the picked target. The pane header shows
`[target: <kind>: <title> · T to switch]` when more than one target is attached.
**Multi-pane browsers** — `browser.open` no longer refuses when one is already running; each browser
pane owns its own CDP worker + per-pane command/event channels (`BrowserPane.event_rx` is the
receiver, drained per-tick by `App::drain_cdp_events` which walks every browser pane). All
browser-targeted App methods (`browser_screenshot`, `browser_print_pdf`, `browser_open_dom`,
`browser_open_cookies`, `browser_open_storage`, `browser_open_perf`, `open_browser_device_picker`,
`open_browser_target_picker`, `switch_browser_target`, `browser_navigate_to`, `browser_set_device`,
`browser_clear_device`, `browser_scroll_node_into_view`, `browser_screenshot_node`) now route
through new `App::active_browser{,_mut}` helpers so the *focused* browser pane receives the
operation (the old `iter().find(|p| matches!(p, Pane::Browser(_)))` would have hit the first pane
regardless of focus). For `workspace` / `shared` profile modes, the second + later panes use a
sibling `chrome-profile-N` dir (via `chrome_profile_dir_for_pane(N)`) so Chrome doesn't refuse to
start against an already-locked user-data-dir. `wipe_browser_profile` still targets the
unsuffixed dir (the suffix-N dirs are temporary by design and OS-cleaned over time).
**Headless mode** — `[browser] headless` config (default off; `:set [no]headless` / `:set headless!` /
`browser.toggle_headless`) — when on, `cdp::run_session` passes `headless: true` to `spawn_chrome` which
appends `--headless=new --no-sandbox --disable-gpu` to Chrome's flags. The pane still receives network /
console / DOM / target events and can be driven by `g` / `e` / `s` / `D` / etc; the only difference is no
visible window. Takes effect on the *next* `browser.open` — in-flight panes are unaffected.
**Profile persistence** — `[browser] profile_mode` config controls Chrome's `--user-data-dir`:
`"workspace"` (default) ⇒ `<workspace>/.mnml/chrome-profile/` — per-workspace, persists across
`browser.open` and across mnml relaunches in the same workspace, so login state / cookies / localStorage
survive a restart. `"shared"` ⇒ `$HOME/.mnml/chrome-profile/` — one profile across every workspace,
handy when signing into the same services from multiple repos. `"ephemeral"` ⇒ a fresh `tempfile::tempdir()`
per `open_browser` call — clean-slate for login testing; state vanishes when the pane closes.
`App::chrome_profile_dir` resolves the path; `browser.wipe_profile` clears the workspace / shared dir so
the next open starts fresh (no-op in ephemeral mode; refuses while a browser pane is open since Chrome
holds the files locked).
**Clear-on-navigate** — on a main-frame `Page.frameNavigated` event the browser pane's `net` + `dom`
lists and their selections reset to empty / 0. Mirrors Chrome DevTools' default ("Preserve log: off") —
the prior page's network log / DOM tree don't pile up across navigations. `g`-style navigation usually
means "I'm debugging the new page" so a clean slate is the principle-of-least-surprise default.
**Right-click context menus — done:** `src/context_menu.rs` (`ContextMenu{title,items:Vec<MenuItem{label,
action: MenuAction}>,anchor,selected}`) + `src/ui/context_menu.rs` (a bordered floating list at the click,
clamped to screen, selected row highlighted). Right-click a tree file → Open / Open in split / Reveal in
Finder / Copy path; a tree dir → Reveal in Finder / Copy path / Refresh tree; a bufferline tab → Close /
Close others / Close all (dirty editors are kept + counted) / Copy path. Modal like the picker — ↑↓/jk
select, Enter runs, Esc / click-away dismisses, click a row runs it. `App.context_menu` +
`open_tree_context_menu` / `open_tab_context_menu` / `context_menu_accept` / `run_menu_action`;
`tui::dispatch_mouse` handles `Down(Right)` → menu on the tree row / tab under it.
**Tasks / launcher — done (first cut):** `[tasks.<name>]` config (`cmd = "shell line"`, optional `cwd`
— relative to the workspace) + `[startup] tasks = ["name", …]`; `task.run` command (`<leader>o`) opens a
picker over the configured tasks and runs the chosen one via `$SHELL -c` in a pty pane
(`BinaryProfile::task`); `App::run_startup_tasks()` (called once by `tui`/`headless` before the loop)
spawns the `[startup]` ones. Absorbs `../private-playwright/start-launcher.sh`: drop it in as a task /
startup task instead of running it separately (the Playwright track will grow native equivalents later).
**`.test` E2E format — done (first cut):** `src/e2e/mod.rs` — a line-based DSL: steps (`write <relpath>
<content>` seed a fixture, `open <relpath>`, `key <spec>`, `type <text>`, `command <id>`, `wait <ms>`)
+ expectations (`expect screen contains|lacks <text>`, `expect dirty <bool>`, `expect pane <substr>`,
`expect file <relpath> contains|lacks <text>` for on-disk asserts after a save),
run against the same `App` + `ui::draw` the terminal/headless paths use — with a ratatui `TestBackend`
and synthesized key events (no real event loop, no file-IPC; deterministic + fast). `<text>` may be
`"…"`-wrapped (`\n \t \\ \"` unescaped). `mnml test [path…]` runs files/dirs of `.test` (default
`tests/e2e/`), non-zero exit on failure; `tests/e2e.rs` runs `tests/e2e/**/*.test` under `cargo test`
(`edit_and_save`, `command_palette`, `splits`, `markdown_preview`, `vim_mode`, `whichkey`,
`close_prompt`, `buffers`, `theme_picker`). **Plugins — done (first cut):** out-of-process
helpers over the `.mnml/ipc/` channel — IPC commands `register-command {id,title,group,keys}` /
`run-command <id>` / `type <text>`; a `register`ed command (`crate::command::DynCommand` on `App`) shows
up in the palette + resolves as a keybinding (`Keymap::bind`), and invoking it (palette / key / `run-command`)
appends a `{"event":"plugin-command","id":…}` line via `ipc::drain_plugin_events` (called once per run-loop
tick) for the owning plugin to react to; `command::run` falls back to `App::run_dynamic_command` after the
builtin lookup. Protocol + limits documented in `docs/PLUGINS.md` (and it contrasts plugins [out-of-process,
IPC] with Cargo features [compiled-in]); `examples/plugins/insert-timestamp.sh` is a working example.
**LSP — first cut:** `src/lsp/{mod,client}.rs` — one server subprocess per `(project-root, language)`, JSON-RPC
over stdio on a reader thread that forwards `publishDiagnostics` + `definition`/`hover` responses (and replies
`null` to server→client requests so strict servers don't stall) over an mpsc channel `App::tick` drains.
Servers from `[lsp.<name>]` config (`cmd`/`args`/`extensions`/`root_markers`/`language_id`) layered over
built-in defaults (rust-analyzer / pyright-langserver / typescript-language-server / gopls / clangd); an
uninstalled/dying server just disables LSP for that language (no retry, one toast). Wiring: `did_open` on
open, `did_save` on save, a full-text `did_change` on every edit (diagnostics update while typing),
`did_close` when the last pane for a file closes; diagnostics land on `buffer.diagnostics` → `editor_view`
paints a severity dot in the gutter sign cell + tints the line number, `statusline` shows error/warning
counts. Commands `lsp.goto_definition` (`F12` / `<leader>l d`), `lsp.hover` (`<leader>l h`) — the reply opens a
small bordered popup near the cursor (`src/hover.rs` = `HoverPopup`: fences dropped, headings/quotes
stripped, word-wrapped; `src/ui/hover.rs` anchors it below the cursor [flips above / clamps to screen],
title shows the scroll range when it overflows); `App.hover`, arrows/`j`/`k`/PgUp/PgDn scroll it, Esc or
any other key (or a mouse click) dismiss it (all in `tui.rs`'s `dispatch_key`/`dispatch_mouse` top).
`lsp.references` (`<leader>l r`, → fuzzy picker of `path:line:col`, Enter jumps — `PickerKind::Locations`),
`lsp.diagnostics` (`<leader>l e`) — `Pane::Diagnostics` (`src/lsp/diagnostics_pane.rs` = `DiagnosticsPane`
state: every diagnostic on an open buffer, errors-first; `src/ui/diagnostics_view.rs` renders the list
[`▶`-marked selection, `rel:line:col  message  (source)` per row, header err/warn counts]); a "Problems"
panel in a split below the focused leaf — ↑↓/jk select, Enter jumps to the location, `r` refreshes, Esc → tree,
wheel moves the selection; it's rebuilt live whenever diagnostics change (`App::refresh_diagnostics_panes`).
`lsp.next_diagnostic` / `lsp.prev_diagnostic` (`<leader>l n` / `<leader>l p`, `App::lsp_goto_diagnostic`) move
the cursor to the next/prev diagnostic in the active buffer (wrapping) and pop its message in the hover popup.
`lsp.rename` (`<leader>l R`) — one-line prompt (`PromptKind::LspRename`, seeded with the identifier under the
cursor; `App.pending_rename` holds the `(path,line,col)`) → `textDocument/rename`; the reply `WorkspaceEdit`
(`changes` / `documentChanges`, file-ops skipped) is flattened to `LspEvent::Rename` and `App::apply_rename_edits`
edits each file — through `Buffer::apply_edit_ops` + the new `EditOp::ReplaceRange{start,end,text}` if it's open
(left dirty for review), else by splicing the file on disk; `crate::lsp::byte_at` resolves LSP positions →
byte offsets, edits applied descending-by-offset. **code actions** — `lsp.code_action` (`Ctrl+.` / `<leader>l a`):
`App::lsp_code_action` collects the active editor's cursor (or selection) as an LSP `Range`, picks the
diagnostics overlapping that range (`ranges_overlap` is inclusive on the endpoint), and fires
`textDocument/codeAction` with `{ textDocument, range, context: { diagnostics } }`. `initialize` advertises
`codeActionLiteralSupport` (no `resolveSupport` — so servers return eager actions, not stubs that need a follow-up
`codeAction/resolve`). The reply `(Command | CodeAction)[]` is parsed by `crate::lsp::client::parse_code_actions`
into `Vec<CodeAction { title, kind, edit: Option<WorkspaceEdit>, command: Option<CodeCommand> }>` (legacy
`Command` literals + nested CodeActions both supported; `disabled` actions skipped; resolve-only stubs kept with
empty fields). The list lands on `App.pending_code_actions` and opens a `PickerKind::CodeActions` picker (items
labelled by title, `kind` shown as the dim detail); the picker's `accept` indexes back into the stash and
`App::apply_code_action` applies the workspace edit through the same `apply_rename_edits` path (open buffers ⇒
`Buffer::apply_edit_ops`, others ⇒ splice on disk) then fires `workspace/executeCommand` via
`LspManager::execute_command` (fire-and-forget — the server's effects come back as future `applyEdit` / diagnostics).
**Quick fix** — `lsp.quick_fix` (`Alt+Enter`): same code-action request, but the reply handler auto-applies
the *first* returned action instead of opening the picker (servers front-load the most relevant action, so
this matches the typical IDE "fix this for me" gesture). Toggled via `App.pending_code_action_auto_apply`,
which `apply_code_action_reply` consumes (`std::mem::take`). Empty reply ⇒ "no quick fix available" toast.
**Go to symbol** — `lsp.symbols` (`Ctrl+Shift+O` / `<leader>l s`): fires `textDocument/documentSymbol`,
parses both reply shapes (`DocumentSymbol[]` hierarchical + legacy `SymbolInformation[]` flat) into
`Vec<DocumentSymbol{name, kind, line, character, depth}>` (depth-first walk; `symbol_kind_label` maps the
LSP `SymbolKind` enum → short label like "fn"/"struct"/"class"); opens a `PickerKind::Symbols` fuzzy
picker with the symbol list indented by `depth`, kind as the dim detail; accept ⇒ jump the active editor
to the symbol's `(line, char)`.
**Workspace symbols** — `lsp.workspace_symbols` (`<leader>l S`, capital): prompt
(`PromptKind::LspWorkspaceSymbol`) for a query, fire `workspace/symbol` against every running language
server. Each reply lands as `LspEvent::WorkspaceSymbols(Vec<WorkspaceSymbol{name,kind,path,line,character,
container}>)` and merges into `App.pending_workspace_symbols`; the picker (re-)opens after every reply so
hits appear as servers respond. `client::parse_workspace_symbols` handles both reply shapes — legacy
`SymbolInformation[]` (full `location.range`) and the newer lazy `WorkspaceSymbol[]` (uri only, defaults to
(0, 0)). Reuses `PickerKind::Locations` for the accept path.
**Regex outline (no-LSP fallback)** — when the outline pane's target file has no language server
attached, `App::populate_regex_outline` runs `crate::regex_outline::extract_symbols(text, ext)` to
pull function/class/struct/etc. definitions via regex. Languages covered: `rs`/`py`/`js`/`jsx`/`ts`/
`tsx`/`go`/`rb`/`c`/`cpp` (anything else returns empty). Patterns are conservative — they target
the common case (top-level + simple-indent forms), not generics, decorators, or macro-defined
identifiers. Tree-sitter `tags.scm` queries would be more accurate; this exists because it ships
in 200 lines instead of vendoring a query family. Triggered both on first open
(`open_outline_pane`) and on `r` refresh (`refresh_outline_pane`) when the LSP request fails.
**Markdown outline** — when the outline pane's target is a `.md` / `.markdown` / `.mdx` / `.mkd` file,
`open_outline_pane` / `refresh_outline_pane` / `retarget_outline_to_active` skip the LSP and call
`crate::markdown_outline::extract_headings(text)` directly. ATX-style headings (`#` through `######`)
parsed at line start, `depth = level - 1` so the outline indents `##` under `#`; ATX closing `#`s stripped;
headings inside fenced code blocks (``` … ``` / `~~~ … ~~~`) skipped so example code doesn't pollute the
list. Same pane, same key handling (`/` filter, j/k navigate, Enter jumps).
**Outline pane** — `outline.show` (`<leader>l o`): a persistent sibling to the symbol picker. Opens a
horizontal split next to the active editor as `Pane::Outline(OutlinePane{target,items,selected,scroll})`,
captures the editor's path as the target, and asks the LSP for symbols. The reply routes to the open
outline (via `App.pending_outline` flag — same `documentSymbol` plumbing, different sink). ↑↓/jk select,
Enter jumps to the symbol's location in the target editor (opens if not already in a pane), `r` re-fires
the request, Esc → tree. The header shows the target's filename + symbol count; each row is `<kind>
<indent><name>:<line>` with kind color-coded (fn/method blue, struct/class yellow, const/var cyan,
module/namespace green). **Auto-track on focus change** — `reveal_pane` calls `retarget_outline_to_active`,
which retargets an open outline pane to the newly-active editor's path + re-fires `documentSymbol` (no-op
when nothing changed or the active pane isn't a saved editor). **Type-to-filter** — `/` in the pane
enters filter mode (`OutlinePane.filter_mode = true`); subsequent printable keys append to
`OutlinePane.query`, Backspace pops, Enter exits filter mode but keeps the narrowed list, Esc clears the
filter + exits. `visible_indices()` is a fuzzy match against `name` (uses `crate::fuzzy`) — preserves
nesting order so depth-indent stays readable. `selected` indexes into the filtered view; the count chip
shows `M/N symbol(s)` when narrowed; "(no matches)" placeholder when the filter zeros the list.
**Code folding** — `Buffer.folds: BTreeMap<usize, usize>` (`start_line → end_line` inclusive, both
0-based file lines). `editor.toggle_fold` picks the smallest enclosing bracket pair around the cursor
(`{}` > `[]` > `()`) and toggles a fold for the spanned lines; `editor.unfold_all` clears every fold on
the active buffer. Renders the start line with a dim purple `  ⋯ N hidden` chip painted into the
trailing space cells. Body lines are skipped during render — the loop walks via
`Buffer::next_visible_line` starting at `buf.scroll`. Cursor placement uses `file_to_visible_row` so
the caret sits on the right visual row. Vertical motions (`MoveUp` / `MoveDown` / `PageUp` / `PageDown`
/ `HalfPageUp` / `HalfPageDown` / `MoveBufferStart` / `MoveBufferEnd`, plus `Repeat(_)` wrapping any of
those) snap out of folded body via `Buffer::snap_cursor_out_of_fold(going_down)` — down jumps past the
fold's end, up retreats to its start. Click-to-place uses `visible_to_file_row`. Edits clear every fold
(simple invariant — smarter offset tracking is a follow-up). Lost on buffer close. **Persisted across
launches** via `SavedFolds{path, folds: Vec<(start, end)>}` in `session.json` — restored only for buffers
that re-open in the same session, applied after `open_path` runs so the new buffer's `Buffer.folds` map
gets the saved pairs (out-of-range pairs are dropped silently — likely stale from an external edit).
**Vim fold chords** — `za` / `zo` / `zc` toggle a fold (mnml has one gesture rather than separate open/close);
`zR` unfolds every fold. New `Prefix::ZFold` (separate from `Prefix::Z`, which still owns `ZZ` / `ZQ`).
**Click-to-unfold** — each rendered `⋯ N hidden` chip records `(rect, pane_id, start_line)` in
`app.rects.fold_chips` per frame; the mouse-down handler matches against it before the editor click path
and pops the fold from `b.folds`.
**Snippets** — `src/snippets.rs` + `[snippets.<scope>]` config table (where `<scope>` is a file extension like `rs`/`py`/`ts` or
the literal `global`; each entry is `<trigger> = "<expansion>"`). Two ways in: `snippet.expand` (`Ctrl+J`) replaces the
identifier prefix immediately left of the active editor's cursor with the matching trigger's expansion (toasts if no match);
`snippet.pick` (`<leader>i s`, `PickerKind::Snippets`) opens a fuzzy picker over every snippet available for the active buffer
and inserts the chosen one at the cursor without consuming a trigger word. The picker preview joins multi-line expansions
with `↵` (placeholder markers stripped) and caps at 60 chars so multi-line snippets stay readable in one row. A single literal `$0` in the expansion picks where
the cursor lands after insertion (absent ⇒ cursor at the end of the inserted text); further `$0`s are left in the text as
literals. Extension-scoped triggers shadow same-named `global` ones. `snippets::snippets_for(table, ext)` returns the sorted
list (ext first, then global), `snippets::find_by_trigger` does exact-match lookup, `snippets::word_before_cursor` extracts
the `[A-Za-z0-9_]*` prefix left of a cursor offset. `App::snippet_expand_at_cursor` / `App::snippet_pick` /
`App::snippet_insert_at_cursor` / `App::apply_snippet_edit` (shared edit path: `EditOp::ReplaceRange` then walk the cursor
back to the `$0` spot, plus an LSP `did_change`). The e2e harness has a new `snippet <scope> <trigger> <expansion>` step
that seeds an entry on `app.config.snippets`; `tests/e2e/snippets.test` exercises both expansion + the toast + the
`global`-scope fallthrough.
**Snippet placeholders** — `$1`..`$9` markers are tab-stops. `Snippet::parse` peels the first occurrence of each `$N`
out of the expansion text and records its byte offset (`Snippet.placeholders: Vec<usize>`, in tab-stop order — gaps
tolerated). On insert (`apply_snippet_edit`), the cursor lands at `$1` (or `$0` / end if no placeholders) and an
`App.snippet_session: Option<SnippetSession{pane_id, stops: Vec<usize>, current: usize, last_text_len: usize}>`
opens with the absolute byte positions of every stop. Tab → `App::snippet_next_placeholder` (and Shift-Tab →
`App::snippet_prev_placeholder`) shifts stops at indices > `current` by `current_text_len - last_text_len` (so
chars typed at the active stop push the later stops along by the right amount), advances/retreats `current`,
jumps the cursor via `place_cursor_at_byte`, records the new `last_text_len`. After the last placeholder `$0` is
appended as the final stop when present (otherwise Tab terminates at the last `$N`). Walking forward off the end
ends the session; Backtab from index 0 stays put (no wrap). Esc dismisses; switching panes auto-drops the session.
Tab / Shift-Tab / Esc are intercepted in `tui::dispatch_key` (mirrors the completion-popup pattern) — the
`snippet.next_placeholder` / `snippet.prev_placeholder` commands are registered for the palette but unbound by
default since Tab/Shift-Tab are editor-local. `tests/e2e/snippet_placeholders.test` covers the full Tab cycle.
Limitations: edits made *outside* the active stop still apply the same shift to later stops, and Backtab to a
visited stop puts the cursor at that stop's original position rather than at the end of whatever the user typed
there — both are follow-ups for a smarter per-stop range tracker.
**Signature help** — `textDocument/signatureHelp` (`lsp.signature_help` for explicit fire,
auto-triggered on `(` / `,` typed in insert mode; `)` dismisses). Reply parsed by
`client::parse_signature_help` into `Vec<SignatureInfo{label, parameters: Vec<(start_char,end_char)>,
active_parameter}>`. The popup (`src/signature.rs::SignaturePopup` + `src/ui/signature.rs`) anchors
above the cursor (flipping below when there isn't room), renders the active signature's label with the
active parameter range bolded + yellow, plus a `1/N signatures · ↑↓` indicator when the server returned
overloads (the chord hint matters because the popup doesn't capture focus — without it the cycle is
invisible). **Cycling overloads** — when there's more than one signature, Up / Down inside the popup move
between them (`SignaturePopup::cycle` / `cycle_prev`); single-signature popups don't steal arrow keys
from the editor. Commands `lsp.signature_next` / `lsp.signature_prev` are registered for the palette
but unbound (the chord lives at the dispatch site since the gating depends on a popup-state condition).
Esc / any mouse click dismisses.
`initialize` advertises `parameterInformation.labelOffsetSupport` so servers return numeric ranges
instead of substrings.
**completion — as-you-type popup**: `src/completion.rs`
(`CompletionPopup{path, all, filtered, selected, scroll, prefix}` — one `textDocument/completion` reply
populates `all`; `refilter(prefix)` narrows `filtered` locally via `crate::fuzzy` as you keep typing, no
re-request per keystroke) + `src/ui/completion.rs` (a small borderless list anchored just below the caret,
flips above / clamps to screen, selected row highlit, dim `detail` column). `App::completion_on_edit(typed)`
runs after every editor edit (`tui.rs` `BufferEvent::Edited`): refilters an open popup against the new prefix
(closing it when the prefix empties / stops matching), and auto-triggers a fresh `textDocument/completion`
on `.`/`:`(member access) or the first char of a new word; the reply (`apply_lsp_event`) opens the popup
filtered against the *live* prefix. In the popup: ↑↓/Ctrl-N·P move, PgUp/PgDn jump, Tab/Enter accept
(`App::completion_accept` → `EditOp::ReplaceRange` over the identifier prefix left of the cursor →
`item.insert`; **snippet items** (`insertTextFormat == 2`, surfaced as the new `CompletionItem.is_snippet`
flag) get LSP snippet syntax — `$1` / `${1:default}` / `${1|a,b|}` / `$0` / escapes — converted to mnml's
bare-`$N` form via new `crate::snippets::lsp_snippet_to_mnml`, then parsed through `Snippet::parse` and
applied via the existing `apply_snippet_edit` so Tab cycles through the placeholders. `${1:default}` puts
the default text in the buffer with the cursor at its end — default-as-selected isn't supported yet),
Esc dismisses, any other key
dismisses + is handled normally, a click dismisses it. `lsp.completion` (`Ctrl+Space` / `<leader>l c`) is the
manual trigger (requests regardless of prefix; same popup). Known simplifications (in `src/lsp/mod.rs`):
full-text doc sync, char-offset columns, `initialize` not awaited before `didOpen`; completion list is
filtered locally after the first reply (no re-request as the prefix grows). Then: CDP follow-ups (network
entries → curl, DOM, screenshots, headless), more `.test` coverage, the `private` Cargo feature (DocDB
`TestExecutions` + CodeBuild + native launcher actions), Git GUI phase 4 (branch rail UI, commit-with-Codex,
recompose-with-AI, multi-repo); plus queued polish (editable request-pane field tabs). See `.local/PLAN.md`.
Incremental tree-sitter parsing — full arc landed. `tree_sitter_highlight` is gone;
`highlight.rs` drives raw `tree_sitter::Parser` + `Query` directly, with a precomputed
capture-index → HIGHLIGHT_NAMES map and an innermost-wins span layout that exploits the
renderer's `spans.iter().rev().find(...)` order. **Injection support**: each `LangConfig`
carries an `injections_query`; for every match the resolver picks the language (via
`@injection.language` capture, or a `#set! injection.language "..."` property), parses the
`@injection.content` byte ranges with the inner grammar through `Parser::set_included_ranges`
(byte offsets stay in the outer text's coordinate space), and recurses up to
`MAX_INJECTION_DEPTH = 3`. Markdown fenced-code-blocks (` ```rust …` → Rust-highlighted),
markdown_inline (`**bold**`, `_em_`, `` `code` ``), HTML embedded `<style>` / `<script>`,
plus Rust/JS/PHP/Swift/Zig/Nix/Elixir/Haskell injections all work. **Incremental reparse**:
`Editor::apply` now reports `EditOutcome.text_edits: Vec<TextEdit>` (start/old_end/new_end
bytes). For ops where `extra_cursors.is_empty()` and the buffer changed, an inference
function deduces the single-edit shape from the before/after `(len, cursor)` snapshot —
catches typing, backspace, delete-forward, paste, selection-delete, and InsertNewline
with auto-indent in ~one match arm without instrumenting every mutation site.
`ReplaceRange` is handled explicitly (LSP rename / find-replace). Multi-cursor / indent /
auto-pair / JoinLines fall through with `text_edits` empty ⇒ caller drops the cached
parse tree. `Buffer.pending_tree_edits` accumulates between refreshes;
`Buffer.prev_line_starts` snapshots the parsed text's line-start index so the next
batch's `InputEdit::*_point` halves can be derived. `highlight_lines_with_cache(text, ext,
&mut prev_tree, &edits, &prev_line_starts, prev_highlights)` applies each `Tree::edit`,
reparses with `parser.parse(text, Some(&prev_tree))` so unchanged regions are reused, AND
restricts the query traversal to a dirty byte window derived from
`prev_tree.changed_ranges(&new_tree)`: `apply_query_to_spans` and `walk_injections` both
take an optional `Restrict { byte_range, dirty_rows }`, call
`QueryCursor::set_byte_range(...)` to skip nodes outside the changed bytes, and clip emitted
spans to the dirty row window. Lines outside the window get their spans from
`prev_highlights` shifted by `(new_end_row - old_end_row)`. Restricted to single-edit
batches (multi-edit shift composition isn't worth it for the MVP); falls back to full
query otherwise. Bench on 600 KB / 12.4k-line synthetic Rust: fresh **~95ms**,
incremental-parse-only ~58ms, **incremental-parse-plus-query ~7ms** (~13× speedup, hitting
the handoff's "<5ms" ballpark). Unit tests verify incremental output equals fresh for
typing and backspace.
**`private` Cargo feature (phases 1–7 done; sub-phases 5b/6b cross-nav + log tail too)** — off
by default. `cargo build --features private` drags in `mongodb = "3"` + `tokio`
(contained-runtime form) + `futures-util` + `bson`. Four phases shipped so far:
(1) module skeleton + worker-thread channel; (2) `Pane::TestExecutions` enum
variant (cfg-gated) + `ui/test_executions_view.rs` renderer (env-color-coded rows
· ✓✗⊘≈ tally · branch + duration) + opener command `private.test_executions`
(palette group "private") + `App.docdb_handle` + per-tick drain into open panes;
(3) `[playwright.docdb]` config section (unconditional in `Config` so lean builds
still parse it) with `{dev,staging,prod}_uri` + optional `database` /
`collection`; (4a) **real DocumentDB connection** — `private/docdb.rs` spawns a
`tokio::runtime::Builder::new_current_thread` runtime inside the worker thread
and fans out one async task per configured env URI. Each task connects via
`mongodb::Client::with_uri_str` (TLS / `tlsCAFile` / auth read from the URI),
runs a `BACKFILL_LIMIT = 100` initial backfill sorted by `startedAt` desc, then
enters a 5-second poll loop fetching `{ startedAt: { $gt: last_seen } }`. BSON
docs project to `TestExecutionRecord` via a tolerant `parse_doc` that accepts
ObjectId-or-string `_id`, BSON-datetime-or-epoch-ms `startedAt`, top-level or
nested-under-`stats` counts, and a `sourceVersion` alias for `branch`. Errors
surface as `DocDbEvent::Failed` banners and the loop retries after a 30s
backoff. `DocDbHandle`'s `Drop` flips an `AtomicBool` + joins the thread so
workers exit cleanly. **Phase 4b done** — `[playwright.docdb] mode = "stream"`
opens `coll.watch()` (DocumentDB change streams; requires the cluster's
`change_stream_log_retention_duration > 0`); `mode = "auto"` tries streams
first and falls back to polling with a one-time toast on failure. CodeBuild
absorption shipped as `Pane::CodeBuilds`; launcher absorption shipped as
`[tasks.<name>]` config + the startup-tasks runner.
**Bitbucket terminal dashboard (phases 1–3 done)** — `src/bitbucket/`
(unconditional in the lean build; reuses `reqwest::blocking` from the `http` track,
no Bitbucket SDK). One worker thread polls every configured `[[bitbucket.repos]]`
workspace/slug in turn (`api.rs` hits `GET /2.0/repositories/{ws}/{slug}/pipelines/?sort=-created_on&pagelen=20`),
projects each pipeline to a flat `PipelineRecord{workspace, slug, uuid, build_number, state, target_ref, target_kind,
commit_hash, creator, trigger, created_on_ms, completed_on_ms, duration_secs, web_url}`,
emits over an `mpsc` channel as `BitbucketEvent::Pipelines{ws, slug, pipelines}`. State
folds Bitbucket's two-level `state.name` + `state.result.name` into one enum
(`PipelineState::{Successful, Failed, Error, Stopped, Expired, InProgress, Pending,
Paused, Halted, Unknown}` — outer-state wins over a stale `result` field) with
`glyph()` + `label()` + `is_terminal()` helpers. Auth: token read from
`$BITBUCKET_TOKEN` (or whatever `[bitbucket] auth_env` names) at spawn time —
never persisted to config; values containing `:` use Basic (legacy app-password),
otherwise Bearer (the modern API-token format Bitbucket pushed in 2024). Poll
interval `[bitbucket] poll_secs` (default 30, floor 5 to keep us off the rate
limit). On per-repo fetch failure, the worker emits a `Failed("ws/slug: …")`
and continues with the next repo after a brief 5s inter-repo backoff so one
broken repo doesn't kill the whole loop. `BitbucketHandle::Drop` flips an
`AtomicBool` + joins the thread so workers exit cleanly. `App.bitbucket_handle`
is the lazy-spawn slot (`App::ensure_bitbucket_worker`); `App.bitbucket_pipelines:
HashMap<(workspace, slug), Vec<PipelineRecord>>` is the per-tick-drained cache the
phase 2 `Pane::BitbucketPipelines` reads from; `App.bitbucket_last_error` /
`App.bitbucket_connected` surface the loading / banner state. `examples/bitbucket_smoke.rs`
(`cargo run --example bitbucket_smoke`) verifies the real API call shape against
the configured repos. Multi-repo config from a TOML array:
```
[bitbucket]
auth_env  = "BITBUCKET_TOKEN"        # optional
poll_secs = 30                        # optional, floor 5

[[bitbucket.repos]]
workspace = "exampleorg"
slug      = "example-api"

[[bitbucket.repos]]
workspace = "exampleorg"
slug      = "private-playwright"
```
Repos *append* across config files (homedir + workspace .mnml/config.toml), so a
workspace-local override adds rather than replaces. **Phase 2 landed:**
`Pane::BitbucketPipelines` (`bitbucket.pipelines` command, `<leader>C p` chord via
new "+ci" leader group): a multi-repo grouped list of recent pipelines reading
from `App.bitbucket_pipelines` at render time (no per-pane data store — the
pane is stateless beyond `{selected, scroll}`). Header rows show `▸ ws/slug
(N)`; data rows are `<glyph> #build <ref> <duration> <age ago> <creator>
<trigger>` color-coded by state (green ✓ successful, red ✗ failed/error,
yellow ⏵ running, cyan · pending/paused, dim ⊘ stopped/halted/expired,
fg ? unknown). ↑↓/jk/PgUp/PgDn/g/G navigate (header rows auto-skipped),
Enter opens the pipeline's Bitbucket dashboard URL via `open_url_external`,
`y` copies it, `r` triggers an immediate refresh (wakes the worker out of
its poll-interval sleep via a new `BitbucketHandle::force_refresh` /
`AtomicBool` wake flag — the worker's `sleep_cancellable_with_wake` checks
both cancel + wake every 250ms), Esc → tree. `src/ui/bitbucket_pipelines_view.rs`
flattens config-order repos × cached pipelines into a `Vec<FlatRow>`;
`selected_pipeline(app, pane)` is the helper App-side commands call to
resolve the selection. **Phase 3 landed:** `Pane::BitbucketPullRequests`
+ the worker now fetches PRs alongside pipelines each pass (one extra
endpoint per repo per cycle — well within Bitbucket's 1000 req/hr limit).
`PullRequestRecord{ws, slug, id, title, state, author, source_branch,
dest_branch, reviewer_count, approved_count, changes_count, comment_count,
task_count, created_on_ms, updated_on_ms, web_url}` projects
`/pullrequests?state=OPEN&pagelen=20`; participants are walked to count
reviewers, approvals, and change-requested states. Same UX pattern as
the pipelines pane — flat grouped list, ↑↓/Enter→browse/y/r, header
auto-skip. PR rows render `<state> #ID title 👀N ✓A ✗C · 💬N · source →
dest · age · author`. `<leader>P b` chord (new `+pr` leader group).
Phase 4 polish covers a PR list picker, cross-nav (PR ↔ its pipelines),
branch-rail "open PRs" subsection, and live log tail in pty. GitHub Actions / GitLab CI / Azure
DevOps will mirror this pattern as future phases (GH ✓ done, GitLab next,
AzDevOps opt-in).
**GitHub Actions dashboard (phases 1–2 done)** — `src/github/` mirrors
`src/bitbucket/` deliberately: separate module + parallel pane so each
host's REST quirks stay flat (GH has workflow names, PER_PAGE pagination,
two-step status+conclusion state; BB has per-step state, pagelen
pagination, nested state.result). Worker hits
`GET /repos/{owner}/{repo}/actions/runs?per_page=20` with Bearer auth
(works for every PAT shape — classic `ghp_*`, fine-grained `github_pat_*`,
app `ghs_*`, OAuth `gho_*`); `Accept: application/vnd.github+json` +
`X-GitHub-Api-Version: 2022-11-28` mandatory headers. `WorkflowRunRecord
{owner, repo, id, run_number, workflow_name, state, target_ref,
commit_hash, creator, event, created_at_ms, started_at_ms, updated_at_ms,
duration_secs, web_url}` is the projected shape. `WorkflowRunState` folds
GH's two-step `{status, conclusion}` into one enum
(`Success | Failed | Cancelled | Skipped | TimedOut | ActionRequired |
Neutral | Stale | InProgress | Queued | Pending | Unknown`); status wins
over a stale conclusion (the same outer-wins rule as Bitbucket's
state.name). `Pane::GithubActions` reads from `App.github_workflow_runs`
(per-tick-drained cache, keyed by `(owner, repo)`); same flat-list-with-
headers UX as the Bitbucket pane, same color mapping by state, same
keys (↑↓/jk navigate, Enter→browse, y→copy URL, r→refresh, Esc→tree).
`<leader>C g` chord in the +ci leader group; `<leader>C R` (capital)
force-refreshes the GH pane. Config:
```
[github]
auth_env  = "GITHUB_TOKEN"           # optional
poll_secs = 30                        # optional

[[github.repos]]
owner = "exampleorg"
repo  = "private-claude-knowledge"
```
`examples/github_smoke.rs` (`cargo run --example github_smoke`) verifies
the API call shape against the real service. **Phase 3 (PR list)
landed alongside the BB equivalent:** `Pane::GithubPullRequests` reads
from `App.github_pull_requests`, fed by the GH worker which now also
hits `/repos/{owner}/{repo}/pulls?state=open&sort=updated`.
`PullRequestRecord` projects the GH-specific shape — `draft` flag is
hoisted into the state enum (`Open | Draft | Merged | Closed | Unknown`,
draft beats raw state), comment counts are split into "issue comments"
+ "review comments" (the inline kind), reviewer count comes from
`requested_reviewers` + `requested_teams` on the list endpoint. Phase 4
will follow up with a per-PR `/reviews` call to populate approved /
changes-requested counts the way BB's participant list already does.
`<leader>P g` chord.
**SCM/CI dashboards — sweep complete (BB + GH + GitLab + Azure DevOps).**
After the initial BB/GH phases the four hosts now share a single mental
model. All eight panes (pipelines + PRs × 4 hosts) have:
(1) **View-mode toggle (`v`)** — `Recent` ⇄ `PerBranch` for builds /
pipelines; `PerRepo` ⇄ `Mine` for PRs/MRs. State is stored on `App`
(`{bb,gh,gl,az}_pipelines_view_mode` etc) and flipping cycles the
flatten function used by both renderer and tui handler — view-mode
mismatches between flat and rendering were the headline bug surfaced
during the rewrite (`87ffef2` fixed it across both code paths).
(2) **Collapsible repo/project headers** — file-tree style. Nerd Font
chevrons `f105` ⇄ `f107` (Unicode triangles `▸ ▾` fallback when `[ui]
ascii_icons = true`). 2-space header indent, 4-space child indent.
Header rows are selectable; `Enter` toggles, `Right`/`l` expands,
`Left`/`h` collapses (or jumps up to parent header from a child row
— same tree convention).
(3) **Per-row mouse** — single-click selects, single-click on a header
toggles collapse, double-click on a data row fires the primary action
(open in browser). Renderers push per-row `(rect, pane_id, flat_idx)`
into `app.rects.list_rows`; the mouse dispatcher in `tui.rs` matches
the rect and calls `handle_scm_row_click`. The same registry was
extended to non-SCM list panes during the broader mouse audit
(Diagnostics, Outline, Grep/Quickfix, GitStatus, Tests, Flaky, Diff,
GitGraph, CmdlineHistory, CodeBuilds) — every list-style pane in the
codebase now supports click-to-select + double-click-to-act. The only
list pane *not* wired is `TestExecutions` (private-gated, multi-env
column layout that needs its own row-tracking shape).
(4) **Session persistence** — view-mode + `collapsed_*` HashSets land
in `session.json` via 8 new fields (`{bb,gh,gl,az}_{pipelines,prs}_view_mode`
+ `..._collapsed`). Enum variants serialize kebab-case. Survives pane
close + relaunch.
(5) **Per-PR reviewer accuracy on Mine** — the list endpoints return
stale or absent participant data. BB Mine worker fires
`/pullrequests/{id}` per PR after the list call; GH fires
`/pulls/{n}/reviews` and buckets each reviewer's *latest* state into
`✓N ✗N` (chronological; multiple reviews per author stack). Cost: N
extra calls per Mine cycle where N ≤ pagelen=50. BB+GH only — GitLab's
list endpoint already surfaces reviewers via `reviewers[]`; Azure
parses `vote ≥ 5` / `vote < 0` from each reviewer entry directly.
**GitLab CI / Merge Requests dashboard** — `src/gitlab/` mirrors
`src/bitbucket/` + `src/github/`. Endpoints (`api-version=4` paths):
`/projects/{id}/pipelines` (recent), `?ref=<b>` (per-branch latest),
`/projects/{id}/merge_requests?state=opened` (per-project MRs),
`/merge_requests?scope=created_by_me` (cross-project Mine). Project ID
accepts either numeric (`"12345"`) or URL-encoded path
(`"group/project"`) — the worker URL-encodes unconditionally. Self-
hosted GitLab supported via `[gitlab] base_url = "..."`. Auth:
`Bearer $GITLAB_TOKEN`. PipelineState folds GitLab's 12 raw statuses
(`success`/`failed`/`canceled`/`skipped`/`running`/`pending`/`created`/
`manual`/`scheduled`/`preparing`/`waiting_for_resource`/`unknown`) into
that enum; `is_terminal()` keys color + the per-branch "still running?"
hint. MergeRequestState handles `Opened | Draft | Merged | Closed |
Unknown` with draft beating the raw `state` field. `<leader>C l` opens
pipelines, `<leader>P l` opens MRs. Glyph for the pane chip: `▴` (not
the cyan triangle BB uses) in orange.
**Azure DevOps Builds / Pull Requests dashboard** — `src/azdevops/`.
Project entries are `(org, project, repo)` — Azure scopes builds at
project level and PRs at repo level. Endpoints (api-version=7.1):
`/{org}/{project}/_apis/build/builds`,
`?branchName=refs/heads/<b>&$top=1` (per-branch),
`/{org}/{project}/_apis/git/repositories/{repo}/pullrequests?searchCriteria.status=active`,
`/{org}/_apis/git/pullrequests?searchCriteria.creatorId=me` (cross-org-
project Mine — `me` is GA in recent api-versions; if a real user 400s
on this, fall back to ConnectionData → GUID lookup then substitute).
Auth: Basic with empty user + PAT, base64-encoded as `:<PAT>`
(`auth_header_value` in `src/azdevops/api.rs`). BuildState maps
status + result two-step (`inProgress` → InProgress;
`completed`+`succeeded` → Succeeded; etc.). PR review counts come from
each reviewer's `vote` field (10 = approved, 5 = approved-with-
suggestions, -5 = waiting, -10 = rejected); we count `vote ≥ 5` as
`✓N` and `vote < 0` as `✗N`. Header label is `"org/project/repo"`.
`<leader>C a` opens builds, `<leader>P a` opens PRs. **Untested
against a real Azure org** — projected fields and the
`creatorId=me` shortcut may need refinement on first real use; PR
comment_count is hardcoded 0 because Azure's list endpoint doesn't
return it (would need a per-PR `/threads` call). Free-tier signup
walk-through in conversation history if a real test is needed.

**GitHub workflow log viewer** — `L` chord on a GH Actions row opens
the same `Pane::BitbucketPipelineLog` variant the BB pipeline-log
viewer uses; the pane now carries a `host: LogHost` tag (`Bitbucket`
or `Github`) and refetch dispatches based on it. New
`crate::github::api::fetch_combined_run_log(client, auth, owner,
repo, run_id)` walks the run's jobs via `/actions/runs/{id}/jobs`
then each job's `/actions/jobs/{id}/logs` (plain text), concatenating
with `══ job N: <name> (state) ══` headers — sibling to BB's
fetch_combined_pipeline_log. 404/410 per-job logs ⇒ "(no log)"
inline so a half-finished run still renders.

**GitLab + Azure DevOps log viewers** — `L` chord on a GL pipeline
or AZ build row uses the same shared pane via two new `LogHost`
variants (`Gitlab` / `Azure`). `crate::gitlab::api::fetch_combined_pipeline_log`
walks `/projects/{id}/pipelines/{pipeline_id}/jobs` then GETs each
job's `/jobs/{id}/trace` (plain text); `crate::azdevops::api::fetch_combined_build_log`
walks `/_apis/build/builds/{id}/logs` then GETs each `/logs/{logId}`
(plain text). Same `══ job/log N ══` separators, same 404 ⇒ `(no log)`
fallback. The shared `PipelineLogPane` grew one new `host_extra: String`
slot to carry GitLab's API base URL (the only host where the endpoint
prefix isn't hard-coded); BB/GH/AZ leave it empty. Refetch reads
`host_extra` off the pane so a self-hosted GitLab instance keeps the
right base URL across `r`-presses.

**Bitbucket `target_ref` for PR + custom builds** — `RawTarget` /
`project_pipeline` now project three shapes instead of one. Branch
builds keep rendering the bare branch name (`main`, `feature/login`).
PR builds (`pipeline_pullrequest_target`) render
`PR #1234 source→dest`, falling back to `PR #1234 source` then bare
`PR #1234` when the API omits the branch fields. Custom builds
(`pipeline_commit_target` with a `selector`) render `custom: <pattern>`
so manually-triggered pipelines aren't blank. The list pane's
`target_ref` column auto-fits horizontally instead of truncating at
17 chars (was a hard cap when refs were always single branch names);
matching auto-fit added on every other SCM/CI list pane so a long
title / branch / `PR #N src→dst` stretches into spare real estate
instead of getting chopped.

**Cross-host PR picker: Tab → cross-nav-to-pipeline** — the cross-host
PR picker (`pr.picker`, `<leader>P p`) previously only opened the
chosen PR's web URL on Enter. Tab now triggers a secondary accept
that jumps to the PR's matching pipeline/build instead — works
across all 4 hosts. Implementation: picker item id now encodes
`url\x1Fhost_tag\x1Frepo_label\x1Fsource_branch` (delimited by unit
separator, which doesn't appear in URLs/labels). New
`App::picker_accept_secondary` dispatched by `Tab` in the picker.
Generic host-agnostic helper `App::cross_nav_pr_to_pipeline(host_tag,
repo_label, branch)` does the lookup from caches — sibling to the
existing pane-only `jump_from_*_pr_to_*` methods but doesn't require
the PR pane to be open.

**E2E highlight regression coverage** — new `expect highlights at_least
<N>` check in the `.test` format that asserts the active editor has
≥ N total syntax-highlight spans across all lines. Catches regressions
where a grammar's queries silently fail to compile / load. Four new
test files cover the principal injection-heavy paths: `highlight_rust`
(plain grammar), `highlight_markdown_injections` (markdown + inline +
fenced rust), `highlight_typescript` (TS), and `highlight_html_injections`
(HTML + CSS + JS injections). All four pass at floors that any
future legitimate change will still clear (5-6 spans each).

**the private integration 6b — `Pane::LogTail` with severity coloring** — dedicated
streaming log viewer for CodeBuild CloudWatch streams (sibling to
the existing pty-based `t` chord). Opened by `T` on a CodeBuilds
row. Spawns `aws logs tail --follow --format short ...` in a
background thread; lines stream over an mpsc channel into the pane's
buffer. Each line classified to a `LineSeverity` (`Error` / `Warn` /
`Info` / `Debug` / `Plain`) by substring match on common loglib
shapes (`[ERROR]`, `ERROR:`, `Exception`, `panicked at`, etc.);
renderer paints each line in the severity's theme color.
`scroll == usize::MAX` is the follow-the-tail mode; `j/k/g/G/F`
navigate; `F` toggles follow. Per-line capacity cap (10k) for
bounded memory. Single-tail-at-a-time model (the channel is App-
wide).

**the private integration 7b polish — `private.run_tests` pickers** — two opt-in pickers
in front of the default run: `private.run_tests_pick_env` (dev/staging/
prod) and `private.run_tests_pick_branch` (lists local branches; the
settings.json default is pinned to the top with a `●` marker). Each
picker dispatches to a new `App::run_private_tests_with_overrides
(env_override, branch_override)` so the underlying command shape
stays one path. The bare `private.run_tests` command still uses
settings.json defaults across the board. New `PickerKind::the private integrationEnv`
+ `PickerKind::the private integrationBranch` (both private-feature-gated at the
accept site). log_level wasn't picker-ized — settings.json controls it.

**Multi-repo workspace (rail switcher)** — `crate::git::repos::discover_repos`
walks the workspace at startup looking for `.git/` markers (bounded depth,
skips dot-dirs / `node_modules/` / `target/`). New `App.repos:
Vec<RepoEntry>` + `App.active_repo: usize`; the git rail's `branches` /
`worktrees` / `pulls` subsections + the `remote.origin.url` lookup all
consult `App.active_repo_path()` instead of `App.workspace`. Workspace-
is-a-repo case behaves unchanged (single entry, `is_workspace_root=true`).
Multi-repo workspaces surface a `· <name>` chip after the GIT rail header
and gain a `git.switch_repo` command (palette / `:`) opening a fuzzy
picker over the discovered repos. Picker is a no-op when there's just
one repo. New `PickerKind::Repos`.

**Repo rediscovery** — `git.refresh_repos` (palette only) re-walks the
workspace and rebuilds `App.repos`. Useful when a sub-repo was cloned
in another terminal after mnml launched — the original `App::new`
discovery is one-shot. Also enables E2E tests that need to set up
fixture repos via `shell git init` after the App is constructed.
Active repo resets to index 0; rail + pulls refresh.

**Multi-repo phase 2 — git operations follow active_repo_path** —
every git op now routes through `App.active_repo_path()` (with
`App.workspace` as the fallback for single-repo workspaces): status
pane, commit graph, file diff / worktree diff / staged diff / commit
diff, peek change at cursor, file history picker, hunk staging,
stash push/pop, commit, amend, branch checkout / create / delete,
worktree list / remove, blame gutter, `git.browse`, private branch
picker. The top-level `App.git` (which feeds the rail + statusline +
gutter line-signs) gets retargeted on `switch_active_repo` via the
new `GitStatus::retarget(workspace)` method so the rail's branch
chip + the per-file diff marks track the active repo. New helper
`App::rel_to_active_repo(path)` factors the workspace-relative path
computation for the active repo (vs. the existing
`rel_to_workspace`, which got removed since every git caller switched
over). Files-outside-the-active-repo toast `"file is outside the
active git repo"` instead of the old `"file is outside the workspace"`.
**Phase 3:** open `GitStatusPane` / `GitGraphPane` instances now get
retargeted on `switch_active_repo` too — new `GitStatusPane::retarget`
+ `GitGraphPane::retarget` methods re-point the cached workspace,
reset selection/scroll (the new repo's file list / commit history
shares nothing with the old), and refresh. The switch_active_repo
loop walks `App.panes` and calls retarget on any matching variant.
Other panes (BB / GH / GL / AZ pipelines etc.) aren't repo-scoped so
they don't move.

**Azure DevOps Mine — `creator_id` config override + auto-fallback** —
the `searchCriteria.creatorId=me` shorthand was a flagged risk:
recent API versions accept it, some don't. Two hardenings:
(1) New `[azdevops] creator_id = "<guid>"` config — when set, the
worker passes the GUID directly and skips the `me` keyword
entirely.
(2) When `me` errors with an HTTP status, the worker falls back to
`https://app.vssps.visualstudio.com/_apis/profile/profiles/me`
(returns the user's account GUID), then retries the Mine query
with that GUID. Slower by one round-trip but works without
manual config.
Plus a new `examples/azdevops_smoke.rs` smoke binary for verifying
end-to-end against a real org without launching the TUI.

**Azure DevOps — verified on a real org** (2026-05-16, `getprivate`):
the smoke binary returned all five event types cleanly — `Connected`,
`Builds` (1 row, state + ref + duration parsed), `BranchBuilds`
(4 branches), `PullRequests` (0 active), `MyPullRequests` via the
`creatorId=me` shorthand (0 failures — no fallback triggered for this
tenant). Auth-header shape (`Basic <base64(:PAT)>`), JSON projections,
state classification, per-branch fetch, and the Mine endpoint all hold
against a live tenant. Outstanding edge cases (no PR builds or
custom-targeted builds existed in the test org yet) are unverified but
follow the same JSON parsing patterns as the verified shapes.

**TestExecutions mouse support** (private-gated) — clicks now route
properly through the multi-env column layout. New
`app.rects.test_executions_rows: Vec<(Rect, PaneId, env_idx, row_idx)>`
(feature-gated) registers each column-header rect (sentinel
`HEADER_ROW_SENTINEL = usize::MAX` for the row index) and each
2-row data record. Click on a header ⇒ flip the active env without
selecting a record; click on a data row ⇒ flip env *and* set that
env's `selected_row`. Closes the last list-style pane in the
codebase that was keyboard-only.

**Bitbucket pipeline-log viewer** — `L` on a BB pipeline row opens a
`Pane::BitbucketPipelineLog` (split below the source) and a background
thread fetches every step's `/log` endpoint, concatenating into one
buffer with `══ step N: <name> (state) ══` separators between steps.
Read-only, scrollable (↑↓/j/k/PgUp/PgDn/g/G/Home/End); `r` re-fetches
(spawns a new job; stale replies dropped by `job_id` match); `y`
copies the pipeline's web URL; `Enter` opens it in the browser;
`Esc` returns to tree. Auth uses the BB worker's `auth_env`
(`$BITBUCKET_TOKEN` by default); missing env ⇒ pane lands in
`Failed("missing auth: set $...")`. New `crate::bitbucket::api::
fetch_combined_pipeline_log` (steps GET → loop step `/log` GETs,
treats 404 as "(no log)" for skipped/pending steps). One host only
for now — GH Actions / GitLab / Azure DevOps follow in later commits.

**Branch-rail "open PRs" subsection** — third sub-section in the GIT
rail (below `branches` + `worktrees`). Lists open PRs/MRs for the
*current* repo, resolved by parsing `git remote get-url origin` with
the shared `crate::git::browse::parse_remote` helper, then matching
the host (`bitbucket.org` / `github.com` / `gitlab` / `dev.azure.com`
/ `visualstudio.com`) and `(owner/workspace, repo/slug)` against the
per-host PR caches. Per-host glyph color (BB=blue / GH=fg / GL=orange
/ AZ=cyan); `●` marks the PR whose `source_branch == current_branch`
(matches the branches sub-section's "current" convention), `○`
otherwise; current-branch PRs sort to the top. Each row label is
`<#N> <title>` (truncated with `…`). Click ⇒ open the PR's web URL
in the OS browser; right-click ⇒ "Open in browser" / "Copy URL". New
`GitRailHit::Pull(usize)` + `GitRail.pulls: Vec<PullRow>`. The drain
functions for all 4 SCM workers (`drain_{bitbucket,github,gitlab,azdevops}_events`)
end with `App::refresh_rail_pulls()` so the rail tracks each poll
cycle. Falls back to empty silently when there's no recognized
remote — important for non-repo workspaces.

**Cross-nav PR ↔ pipeline** — pane-level chords: `c` on a PR row jumps
to the matching pipeline/build (selects the most-recent one whose
`target_ref` equals the PR's `source_branch`); `P` on a pipeline/build
row jumps to the matching open PR. Opens the peer pane if it isn't
already open. All 4 hosts: `jump_from_{bb,gh,gl,az}_{pr,pipeline,run,build}_to_*`
on `App`. Toasts when there's no match (PR with no pipelines yet, or
the worker hasn't cycled). Forces the peer pane's view-mode to
Recent/PerRepo before jumping so the target row is actually visible
(per-branch view-mode hides anything but the latest per branch).

**Cross-host PR picker** — `pr.picker` (`<leader>P p`) — one fuzzy
picker over every open PR/MR across the 4 configured SCM hosts.
Reads from the per-host caches the workers populate
(`bitbucket_pull_requests` / `github_pull_requests` /
`gitlab_merge_requests` / `azdevops_pull_requests`) — no fresh API
calls; the list is as recent as the last poll cycle. Sorted by most-
recent activity (`updated_at` ⇒ `created_at` fallback). Labels pack
host tag + repo + number + title + state for fuzzy matching; the
detail line shows author · `source→dest` · `👀N ✓N ✗N 💬N` counts ·
humanized age. Accept opens the chosen PR's `web_url` in the OS
browser via the same `open_url_external` helper the per-host
`open_selected_*_pr_url` commands use. New `PickerKind::OpenPullRequests`.
Empty caches ⇒ toast pointing at the four `[[<host>.repos]]` /
`[[<host>.projects]]` config tables (no picker opens).

**DAP debugging — real adapter wire protocol** — `dap.run` (`F5` /
`:Dap`) spawns the configured debug adapter for the active buffer's
filetype (`[dap.<lang>] cmd = "..." args = [...] launch.* = ...`) over
Content-Length-framed JSON-RPC on stdio, runs the canonical handshake
(`initialize` → on `initialized` event → `setBreakpoints` per open
buffer that has any → `launch` → `configurationDone`), and pumps
adapter events back into `App.dap`. `${file}` / `${workspace}` /
`${workspaceFolder}` / `${fileBasename}` / `${fileDirname}` are
substituted in the `launch.*` body. Step controls: `F5` continue,
`F10` next, `F11` step in, `Shift+F11` step out, `Shift+F5` resume
(alt continue), `dap.pause` / `dap.terminate` via palette. On
`Stopped`, the active editor jumps to the top frame's source line +
the gutter paints a yellow `▶` arrow (wins over breakpoint `●` and
LSP severity dots). `dap.toggle_breakpoint` (`F9`) re-fires
`setBreakpoints` to the live adapter when a session is initialized
so toggles take effect immediately. Mirrors `lsp::client` patterns:
reader thread + `Pending` map keyed by `seq` + `DapEvent` mpsc
channel drained in `App::tick`. New `src/dap/mod.rs` +
`src/dap/client.rs`. One session at a time for the MVP; the event
loop polls at 40ms while `App.dap.is_some()` so output/stopped
events surface promptly. **Pane::Debug** (`dap.show` / `:DapShow`)
shows the live call stack + tailing output log: a 3-section split
(status chip · call-stack list · output log). Enter on a stack-frame
row jumps the active editor to that frame's source line; `j`/`k`/
PgUp/PgDn/g/G navigate; `r` re-fetches the stack trace; Esc → tree.
Output log accumulates every adapter-output line categorized by
`stdout` / `stderr` / `console` / `telemetry` (capped at
`DAP_LOG_MAX = 500`); `stderr` / `important` categories also toast.
Cleared on `dap.terminate`. Limitations (still): no variables tree
or watches; no conditional breakpoints; no polished `attach` flow
(the launch body's `request` field can say `"attach"` and we'll
send it, but no helper to fish for a running process).

**DAP breakpoint marks** — `Buffer.breakpoints: Vec<u32>` (0-based,
sorted, unique) persisted in `session.json` via `SavedBuffer.breakpoints`
(stale lines past the file's current end-of-buffer are dropped on
restore). `dap.toggle_breakpoint` (`F9` / `:Bp`) flips on the active
editor's cursor line; painted as a red `●` in the 1-cell sign column.
`dap.list_breakpoints` (`:Breakpoints`) toasts a summary across every
open buffer; `dap.clear_all_breakpoints` (`:ClearBreakpoints`) drops
them for the active buffer.

**Mason-style tools picker** — `tools.installer` (`:Tools` / `:Mason`)
opens a fuzzy picker over `crate::tools::KNOWN_TOOLS` — a curated list
of every LSP / formatter / linter mnml looks for. Each row shows ✓/✗
(is the binary on `$PATH`?) + the kind chip (`lsp` / `fmt` / `lint`)
+ name + description; the picker's detail line carries the suggested
install command. Enter copies that install command to the clipboard
(the user runs it themselves — mnml doesn't auto-install since
package managers vary too much per platform / language). Sorted
missing-first so the user lands on what's actually broken. Covers
the standard tooling: rust-analyzer, typescript-language-server,
pyright, gopls, clangd, lua-language-server, ruby-lsp, prettier,
rustfmt, ruff, black, shfmt, stylua, nixfmt, biome, eslint,
shellcheck. New `crate::tools` module + `PickerKind::Tools`.

**External-linter integration** — `[linters.<ext>] cmd = "..." parser = "eslint"`
(or a list of commands) per file extension, layered on top of built-in
defaults (`eslint --format=unix` for js/ts/jsx/tsx, `ruff check --output-format=concise` for py,
`shellcheck --format=gcc` for sh/bash/zsh). `editor.lint_external` /
`:Lint` fires the linter on the active buffer in a background thread;
results land on `Buffer.linter_diagnostics` and merge with LSP
diagnostics in the gutter signs, statusline error/warn counts, bufferline
tab chips, diagnostics pane, and `]d` / `[d` navigation via new
`Buffer::all_diagnostics()` chaining helper. New `src/linter.rs` holds
the runner + per-parser output parsers (`parse_eslint_unix`,
`parse_tsc`, `parse_ruff`, `parse_shellcheck_gcc`, `parse_vimgrep`
fallback for unknown parser names). `{file}` in the command template
is substituted with the workspace-relative path. Each candidate
recipe is tried in order; first to spawn successfully wins (linters
exit non-zero on findings — that's *not* a spawn failure). New
`LinterJobDone` channel + `App::drain_linter_jobs` mirrors the
`tests_chan` pattern.

**Conform-style external formatters** — `[formatters.<ext>] cmd = "..."`
(or a list of strings tried in order) in the user's config; layered on
top of a built-in `DEFAULT_FORMATTERS` table covering the common cases
(`prettier --stdin-filepath {file}` for js/ts/json/css/html/md/yaml,
`rustfmt --emit stdout` for rs, `gofmt` for go, `ruff format -` / `black
-q -` for py, `shfmt -i 2` for sh/bash/zsh, `stylua -` for lua, `nixfmt`
for nix). `{file}` in the template is substituted with the buffer's
workspace-relative path (shell-quoted when it contains whitespace), so
prettier picks the right rule per extension. New `src/formatter.rs`
holds the table + `formatters_for` + `expand_cmd` + `run_formatter` (a
sync `$SHELL -c <cmd>` runner that pipes the source on stdin + captures
stdout). New `editor.format_external` command (`:Format!` /
`:FormatExternal`) pipes the active buffer through the configured
formatter, replacing the contents via `ReplaceRange` (one edit op so
Undo restores). New `editor.format` (`:Format` already aliases to
`lsp.format` — the smart variant tries LSP first then falls through to
external when no server is attached). Each candidate command in the
list is tried in order; the first to exit 0 wins. Non-zero exits ⇒
no buffer change + toast with stderr preview.

**Stacked notifications** — when more than one toast is live, the recent
ones (capped at `TOAST_STACK_MAX = 5`, newest first) render as a
vertical column of bordered boxes at the bottom-right above the
statusline (nvim-notify style). Each entry ages out independently at
`TOAST_TTL`. Single-toast case is unchanged — the statusline middle
still shows the most recent message there. New `App.toast_stack:
VecDeque<(String, Instant)>` fed by `App::toast` alongside the existing
single-slot `App.toast`. `App::tick` walks the back of the deque and
pops aged-out entries. Esc clears the whole stack (same gesture that
already dismissed the single toast). New `src/ui/toast_stack.rs` paints
the overlay; gated on `toast_stack.len() > 1` so the single-toast path
doesn't double-render.

**Tree-sitter text objects** — `if`/`af` (inner/around function), `ic`/`ac`
(inner/around class/struct/enum/trait/interface/mod/namespace/impl),
`ia`/`aa` (inner/around argument). New ops `SelectInnerFunction` /
`SelectAroundFunction` / `SelectInnerClass` / `SelectAroundClass` /
`SelectInnerArgument` / `SelectAroundArgument` on `EditOp`. Wired into
the vim text-object prefix arm (`Prefix::TextObjectInner` /
`TextObjectAround`). Function / class picking uses
`regex_outline::extract_symbols` for the header line — so it covers
rust/py/js/ts/go/rb/c/cpp without an LSP — plus brace matching for
the body extent (`match_close_after`); the cursor must sit inside the
braces for the scope to be picked. Inner ⇒ just the body; around ⇒
header line through closing `}`. Argument scan walks back to the
innermost unmatched `(`, walks forward to its `)`, splits on
top-level commas (depth-balanced over `()[]{}`, respects single-line
`""`/`''`/`` ` `` strings). Inner ⇒ the trimmed arg slice; around ⇒
extends to swallow the trailing comma + whitespace (or the leading
comma for the last arg, vim's `aa` convention). `Editor::language_ext`
mirrors `Buffer.language_ext` (set on open + by `:setf` / `:set ft=`
via the new `Buffer::set_language_ext` helper) so the editor can pick
language regex bundles without going back through the Buffer.
Indent-scoped languages (Python, Ruby) aren't supported yet — they
return None and the gesture is a no-op.

**Treesitter-context (sticky scope)** — `[ui] sticky_context = true`
(default off; `:set [no]stickycontext` runtime toggle, also `sticky` /
`nosticky`; `:set stickycontext!` flips). When on, the top N rows of
each editor pane are overwritten with the enclosing scope chain
(function → class → method → …) — function headers that scrolled off
the top are painted in bold `bg2` so you can always tell what you're
inside. Reuses `regex_outline::extract_symbols` (rust/py/js/ts/go/rb/c/
cpp) — same regex pass that already feeds the statusline `›` chip and
the outline pane. Algorithm: walk symbols in source order maintaining
a depth-monotonic stack; symbols with `line <= cursor.line` enter and
pop any equal-or-deeper symbols from the stack first. Only paints the
slice of the chain whose header line is strictly above the viewport
(otherwise the user can already see it). Capped at 3 rows; when the
chain is longer, the deepest scopes win. Sits between the existing
fold sticky-scroll overlay and the body paragraph render.

**mini.align** — `gA{motion}<char>` (Normal) and `gA<char>` (Visual) pad
every line in the motion's range with spaces before the first occurrence
of `<char>` so the chars line up at the same column. Lowercase `ga` is
taken by vim's char-info, so this uses capital `A`. New `EditOp::AlignSelection
{ on_char }` (operates on the live selection — finds each line's first hit
column, computes the max, inserts padding descending so byte offsets stay
valid). New `PendingOp::Align` + `Prefix::AlignCharWait`: in Normal,
`gA{motion}` leaves the motion's selection live and transitions to
char-wait; the char arrives and emits `[AlignSelection, SelectClear]`. In
Visual, `gA` goes straight to char-wait since the selection already exists.
Single edit op so one Undo reverts. Already-aligned input is a no-op (still
drops the selection like the case-transform ops).

## Not set up yet (could add later)

- `.mcp.json` — no project MCP servers needed yet.
- `.claude/agents/` — a `code-reviewer` subagent could be useful once the codebase grows.
- The repo isn't packaged as a Claude Code plugin (`.claude-plugin/`); not needed for a single repo.
