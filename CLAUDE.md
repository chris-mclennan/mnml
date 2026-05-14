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
  big tracks (the `private` feature, CDP follow-ups, Git GUI phase 4) for when there's room.
  After each landed feature: update this Status block + commit + `./run.sh restart`.

## Status

P0–P3 done. Working: NvChad-ish layout; editable buffers via
either `StandardInputHandler` (VSCode-style, modeless) or `VimInputHandler` (modal:
Normal/Insert/Visual + `:`-line), swappable at runtime (`editor.toggle_keymap` /
`editor.use_vim` / `editor.use_standard` in the palette, or `:set input=vim`);
`:`-commands (`w q wq x q! wa wqa qa bd bn bp e set %s/old/new/[gi] …`) via `App::run_ex_command`;
**`:%s/old/new/[flags]`** — vim-style global substitute via `parse_substitute` + `App::run_substitute`:
splits on unescaped `/` (`\/`/`\\`/`\n`/`\t` understood inside the fields), `g` is implicit (whole buffer
always), `i` makes the match case-insensitive (`buffer::find_all_ci_ascii` vs `app::find_all_case_sensitive`),
no-replacement form `:%s/foo/` deletes; one undo step + an `:%s — N replacement(s)` toast. Literal-string
match for now — no regex.
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
+ `find_prev` for the navigation.
**Vim find-char** — `f<c>` / `F<c>` jump to next/prev `<c>` on the cursor's line; `t<c>` / `T<c>` stop
one cell before. Operator-pending forms work too: `df<c>` deletes up to and including the target,
`dt<c>` stops on the target (vim convention). New `Prefix::FindChar(forward, before)` + new
`EditOp::FindCharOnLine{ ch, forward, before, inclusive }`; the handler sets `inclusive` based on whether
an operator is pending so the deleted/changed range matches vim's exclusive vs inclusive semantics.
`tests/e2e/vim_find_char.test` covers `f` + `dt`.
**Vim Visual `o`** — swap which end of the selection the cursor sits on (so you can extend the *other*
side without redoing the selection). New `EditOp::SwapAnchorCursor`.
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
**Vim change list (`g;` / `g,`)** — every text-changing edit pushes the cursor's `(row, col)` onto the
buffer's `edit_history: Vec<(usize, usize)>` (capped at `EDIT_HISTORY_MAX = 100`); consecutive entries
within a few columns of each other dedupe so a burst of typing doesn't bury the list. `g;` walks back,
`g,` walks forward (cursor index is `edit_history_cursor`, sits past the newest after each edit). Vim
chords go through `AppCommand::RunCommand("editor.jump_prev_edit"/"jump_next_edit")` →
`Buffer::jump_prev_edit` / `jump_next_edit`. `App::jump_prev_edit` also pushes the current position onto
the nav-back stack so `Alt+Left` returns. Toasts the new `row+1:col+1`. Hooked into both `feed_key`'s and
`apply_edit_ops`'s "if changed" branches via `Buffer::note_edit_position`.
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
tree-sitter syntax highlight (`src/highlight.rs`, 30 grammars: rs/js/jsx/ts/tsx/py/json/go/
toml/css/bash/html/md/c/cpp/rb/java/cs/lua/yaml/scala/ex/hs/php/swift/make/zig/nix/ocaml/dart/sql — `build_config` maps file extensions →
`(language, highlights, injections, locals)` query set; `config_for_lang` resolves *injected*
languages so fenced code blocks in markdown / embedded HTML·CSS·JS get highlighted too, and the
markdown `text.*` captures are in `HIGHLIGHT_NAMES`) + indent guides; hybrid relative line numbers (`[ui] relative_line_numbers`,
`:set [no]relativenumber`, `view.toggle_relative_numbers` — cursor line absolute, others = distance).
**Build-version chip** — `build.rs::emit_git_sha` reads `git rev-parse --short=9 HEAD` (+ `git status --porcelain` for a
`-dirty` suffix) and emits it as `cargo:rustc-env=MNML_GIT_SHA=…`; the statusline reads `env!("MNML_GIT_SHA")` and renders
it as a small chip at the right edge so the user can tell at a glance which build is running (the `./run.sh restart`
"is it actually picking up my changes?" question). Falls back to `build-<unix-seconds>` if git isn't available.
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
dirty changes. **Optional editor extras** — `[editor] trim_trailing_ws_on_save` (off by default; strips trailing
space/tab per line on `save_to_disk` via `EditOp::ReplaceRange` so undo restores them; cursor preserved + clamped),
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
recalled query immediately.
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
which focuses an existing preview of the same path, or splits a new one off the clicked pane
(and pulls the in-memory text from any open editor for that file so the preview tracks unsaved
edits). **Auto-open** — `[ui] auto_md_preview = true` (off by default; `:set [no]automdpreview`
runtime toggle): on every `open_path` for a markdown file, also open the preview pane next to it
in passive mode (`focus_preview=false`, so focus stays on the editor where the user reached).
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
are open). headless+IPC (interactive TUI listens too) + the `run.sh`/`dev.sh`
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
send) writes the parsed list onto `request.headers`. **`Ctrl+S` over a request pane** writes the edited request
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
**`D` toggles a DOM panel** — first press fires `DOM.getDocument {depth:-1, pierce:true}`; `browser_pane::parse_dom` walks
the reply into a flat `Vec<DomRow{depth,label,selector,node_id}>` (whitespace text + shadow-root wrappers skipped; iframes
recursed); rows render indented + colour-coded (elements blue, text white, comments dim). ↑↓/jk/PgUp/PgDn/Home/End/g/G
move the selection (wheel too), `c` copies the highlighted node's CSS-ish selector (`html > body > div#main.card`),
**`h` draws the live highlight overlay on the page** (`Overlay.highlightNode {nodeId}` — `DOM.enable` + `Overlay.enable` are
in the initial domain-enable set), `R` re-fetches, `D` (or Esc) leave the panel (Esc also clears any highlight via
`Overlay.hideHighlight`). After `s` writes the PNG, `open_path_external` hands it to the OS default app (`open` on macOS,
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
`[target: <kind>: <title> · T to switch]` when more than one target is attached. One browser pane at a time.
**Headless mode** — `[browser] headless` config (default off; `:set [no]headless` / `:set headless!` /
`browser.toggle_headless`) — when on, `cdp::run_session` passes `headless: true` to `spawn_chrome` which
appends `--headless=new --no-sandbox --disable-gpu` to Chrome's flags. The pane still receives network /
console / DOM / target events and can be driven by `g` / `e` / `s` / `D` / etc; the only difference is no
visible window. Takes effect on the *next* `browser.open` — in-flight panes are unaffected.
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
`item.insert`; snippet items fall back to the label, no placeholder expansion), Esc dismisses, any other key
dismisses + is handled normally, a click dismisses it. `lsp.completion` (`Ctrl+Space` / `<leader>l c`) is the
manual trigger (requests regardless of prefix; same popup). Known simplifications (in `src/lsp/mod.rs`):
full-text doc sync, char-offset columns, `initialize` not awaited before `didOpen`; completion list is
filtered locally after the first reply (no re-request as the prefix grows). Then: CDP follow-ups (network
entries → curl, DOM, screenshots, headless), more `.test` coverage, the `private` Cargo feature (DocDB
`TestExecutions` + CodeBuild + native launcher actions), Git GUI phase 4 (branch rail UI, commit-with-Codex,
recompose-with-AI, multi-repo); plus queued polish (editable request-pane field tabs). See `.local/PLAN.md`.
Highlight follow-ups: more grammars; incremental tree-sitter parsing (needs dropping
`tree-sitter-highlight` for raw `Parser`/`Query` so an old `Tree` can be reused — not bounded);
markdown's `markdown_inline` injection (the callback fires but emphasis/inline-code spans don't
land — some `tree-sitter-md` split-grammar quirk; fenced code blocks DO highlight).

## Not set up yet (could add later)

- `.mcp.json` — no project MCP servers needed yet.
- `.claude/agents/` — a `code-reviewer` subagent could be useful once the codebase grows.
- The repo isn't packaged as a Claude Code plugin (`.claude-plugin/`); not needed for a single repo.
