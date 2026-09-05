# Parity ledger — mnml-zig against mnml 0.2.21

One row per bullet of the Rust repo's `FEATURES.md` (a bullet that lists
several separable things is several rows). Every claim below was checked
by reading this worktree's source — a runner in a `pub const table`, a
`Pane` variant, a config field that something reads — not by trusting a
report. A spec id without a runner is `missing`, whatever its title says.

| status | meaning |
|---|---|
| `done` | implemented; the file names it |
| `partial` | some of it exists; the note says what is missing |
| `cut` | left out on purpose; the note says why and where the user learns it (a toast, this page) |
| `missing` | nothing found |

The cutover decision reads the totals and the Remaining list first.

## Totals

| section | done | partial | cut | missing | rows |
|---|---|---|---|---|---|
| Editing & input | 38 | 3 | 0 | 8 | 49 |
| Panes, splits & tab pages | 16 | 1 | 0 | 2 | 19 |
| File manager | 0 | 1 | 0 | 21 | 22 |
| Navigation & search | 18 | 3 | 0 | 9 | 30 |
| Language intelligence (LSP) | 23 | 0 | 0 | 10 | 33 |
| Git | 22 | 0 | 2 | 15 | 39 |
| TODOs, notes & findings | 9 | 3 | 0 | 10 | 22 |
| AI | 16 | 2 | 1 | 2 | 21 |
| Terminal & process panes | 9 | 1 | 0 | 5 | 15 |
| Dock widgets | 0 | 0 | 0 | 13 | 13 |
| HTTP request client | 31 | 4 | 1 | 7 | 43 |
| Browser & CDP capture | 15 | 1 | 0 | 1 | 17 |
| Debugging (DAP) | 13 | 0 | 0 | 0 | 13 |
| Testing & quality | 3 | 1 | 0 | 5 | 9 |
| UI & theming | 33 | 13 | 4 | 24 | 74 |
| Workspace trust | 7 | 0 | 0 | 3 | 10 |
| Headless, IPC & extensibility | 20 | 3 | 2 | 14 | 39 |
| Languages | 5 | 0 | 0 | 0 | 5 |
| **total** | **278** | **36** | **10** | **149** | **473** |

Ids: 820 in `src/commands/specs.zig`; 654 have runners after this branch
(537 before it). `zig build -Dpartial=false` lists the rest.

## Remaining — the large items, with an estimate

S = a day, M = a few days, L = a week or more, for one person who knows
the tree.

| item | size | section |
|---|---|---|
| Files pane (`Pane` variant, listing, sorts, hidden toggle, filter, preview, breadcrumb, `files.open` / `open_split`) — the list / filter / scrollbar primitives all exist | M | File manager |
| Multi-select with path-keyed marks and mark-aware operations / menus (after the Files pane) | S | File manager |
| Workspace trash: undoable delete, "Delete permanently", `files.trash` / `restore_from_trash`, the 7-day / 512 MB / 256 MB bounds | M | File manager |
| Background transfer worker + statusline progress chip + `transfer.cancel_all` + the `:qa` guard | M | File manager |
| File clipboard: `file.cut` / `copy` / `paste` / `duplicate`, `-copy-N`, the Ctrl+X/C/V/D chords, menu rows | S–M | UI & theming |
| Workspace grep: rg spawn, a results pane, cross-file replace with a per-hit toggle (`find.grep`, `find.grep_replace`, `view.activity_search`) | L | Navigation & search |
| Multi-root workspaces + the `AddWorkspace` directory-completion prompt + repo switcher | L | Navigation & search |
| A regex engine for find and `:s` (`TODO(find-regex)`; the UI toggle exists) | M–L | Navigation & search |
| `Ctrl-W` move (`H/J/K/L`) — resize / maximize / rotate landed on this branch | S | Panes |
| System clipboard (`"+` / `"*` via OSC 52 or pbcopy / wl-copy; `TODO(clipboard-os)`) | M | Editing & input |
| `:g/` / `:v/` and `:norm` (an ex re-entrancy loop over matched lines) | M | Editing & input |
| Flash-motion labels (the two-char jump exists; the overlay / label-press half does not) | M | Editing & input |
| User-defined `:command`s, `:!cmd`, `:r`, `:r !cmd`, `:<` / `:>`, `:&`, `:s///c` | S–M | Editing & input |
| Global (cross-file) marks + persisted macros + `.editorconfig` + location lists | S–M | Editing & input |
| Jumplist (`nav.back` / `nav.forward` / `nav.jump_toggle_prev`) — a ring on `App` plus the push points | S | Navigation & search |
| NOTES and FINDINGS panels (the TODOS panel is the template) and their row menus; SESSIONS panel | S–M | TODOs, notes & findings |
| TODOS: the `.claude/`-aware action menu with the Claude Code / Codex fallback; the `.fixme(` / `.fail(` / `.skip(` scan; rescan on file change | M | TODOs, notes & findings |
| Dock widgets — the whole tier (corners, Text / LogTail, presets, Overlay / Inline, opacity, kebab, drag-to-move with snap, session persistence) | L | Dock widgets |
| Inlay hints (the toggle is a stub), code lens, semantic tokens, document colors, document links, on-type formatting, `willSaveWaitUntil`, range formatting | S each; semantic tokens M | LSP |
| Rename preview / cross-file confirmation pane | S | LSP |
| External linters and formatters (`Config.linters` / `formatters` are parsed and never read) | M | LSP |
| Diff pane Inline + Split views, intraline highlighting, the density minimap, the `/`-filter | L | Git |
| Graph detail panel, sortable columns, hash-jump, the WIP row with staging buttons | S–M | Git |
| Branch rail (branches / worktrees / open PRs as a collapsible section — the pickers exist) | M | Git |
| AI commit messages (`git.ai_commit` / `codex_commit` / `ai_recompose` are `notInBuild` stubs) | M | Git |
| Browse-a-commit on the remote; the provider badge | S | Git |
| `ai.apply` as a reviewed diff (today it splices the first code block) | S | AI |
| AI launch profiles (`[[launch_profile]]`, chip right-click, the `wrapper` shim) — needs the manifest layer | M | AI |
| Pty session strip, `$` suffix and close button on pty tabs, `:bn` / `:bp` skipping ptys, `term.rename`, `term.scratch_toggle` | S | Terminal |
| HTTP activity-bar panel (seven sections + the `/` filter) | L | HTTP |
| Side-by-side request edit split (`http.toggle_edit_split` is a stub) | M | HTTP |
| Inline `{{VAR}}` highlighting, click-to-definition line, hover, the quick-fix menu | M | HTTP |
| True SSE streaming (the parser exists; the send path reads to the end) | M | HTTP |
| Pre / post-request scripts (`@set-*`, `@assert`, `@capture` — directives are skipped today) | M | HTTP |
| Browser inspectors' type-to-narrow filters; live DOM highlight | S | Browser & CDP |
| Playwright runner, grouped results, trace viewer, flaky dashboard (`test.*` run generic project tests) | L | Testing & quality |
| The `.test` corpus under `zig build test` (today `mnml-zig test`; `zig build check` runs the gate) | S | Testing & quality |
| Image rendering over kitty / iTerm2 (the capability is probed; nothing transmits), image preview tabs, inline images in the markdown preview | M | UI & theming |
| Inline-rendered markdown in the editor (`render_markdown`) | M | UI & theming |
| Menu glyphs + submenus + the curated five-section `+` menu with pin / hide | M | UI & theming |
| Hover tooltips on chips; a real F1 click-discovery overlay; `Shift+F10` keyboard right-click | M | UI & theming |
| The many `ui.*` toggles whose fields nothing reads yet (relative numbers, whitespace, rainbow brackets, trailing-ws highlight, word highlight, hover help, workspace dots, todo keywords, click echo, breadcrumb, cluster mode, tab-bar AI icon, AI layout, coverage chip, menu bar, clock) — `:set` reaches every field; the render side is the work | S each | UI & theming |
| Toast right-click menu, the Undo chip, the bell's idle state, the stress segment's hover / menu | S | UI & theming |
| Statusline clickable segments beyond mode / file / position | S | UI & theming |
| `RESTRICTED` statusline chip; `workspace.review_trust` (needs `trusted.forget`) | S | Workspace trust |
| The integration / manifest layer: manifest format, scanner, `DynRegistry` registration with `owner = .integration`, a trust sink, `integrations.refresh`, the enabled flag, the kebab | L | Headless, IPC & extensibility |
| Icon strips: palette-bar launcher cluster and the tree rail (`IntegrationIcon` schema exists, nothing reads it) | M | Headless, IPC & extensibility |
| Marketplace + the integrations activity panel (`MarketResult = struct { _todo }`) | L | Headless, IPC & extensibility |
| IPC tier-2 app effects: `statusline-set-segment` / `-clear-segment`, `open-pty`, `set-activity-badge`, `notify` fidelity | S–M | Headless, IPC & extensibility |
| Glyph baking / audit tooling (not the SVG preview, which is cut) | M | Headless, IPC & extensibility |
| `--startup-picker` flag and the `mnml.app` bundle | S | Headless, IPC & extensibility |
| Right-panel settings rows (need `ui.right_panel_visible` / `right_panel_width` config fields and numeric rows in the overlay) | S | Headless, IPC & extensibility |

## Cuts — and where the user learns it

| cut | why | the user sees |
|---|---|---|
| Local in-process FIM model (`mnml-fim-engine`) | a bundled model is a release-size and build-time cost mnml-zig does not carry; ghost text is API-only | `ai.suggest_backend = local` toasts the migration note (`src/app/ai.zig` header) |
| brotli response decoding | `std.compress` has gzip / deflate / zstd, not brotli; the HTTP client asks for the encodings it can decode | `Accept-Encoding` never lists `br` (`src/http/client.zig`); a forced `br` body is shown raw with a toast |
| WebP images | no decoder in `zigimg` for this release; image rendering itself is Remaining | `view.image_open` is Remaining; the markdown preview shows `[image: alt]` |
| Glyph-builder SVG preview and Nerd Font patching | SVG rasterising and font patching have no Zig path; the rest of the glyph tooling is Remaining | `integrations.glyph_builder` / `patch_nerd_font_svg` toast the reason (`src/app/cmd_app.zig` `cutRunner`) |
| TOML anywhere (config, themes, manifests, `trusted_workspaces.toml`) | E1 / E2: every persisted format is ZON; the final Rust release ships `mnml export-config-zon` | `docs/CONFIG.md`; the one corpus failure (`settings_persist_to_workspace.test`) asserts TOML by design; the Zig twin in `tests/e2e-zig/` passes |
| The Rust integration binaries and the crates.io marketplace of them (`mnml-forge-*`, `mnml-aws-*`, …) | E5: integrations are rewritten in Zig on a v2 bridge after the cutover; the 0.2.x crates stay published for 0.2.x users | `pr.picker` / `pr.refresh` toast the reason; `:term <binary>` still runs any installed binary as a pty pane |
| now-playing / Sonos / mixr transport | macOS-only AppleScript + a sibling-app IPC; not a terminal-IDE concern for the successor | every `sonos.*` / `mixr.*` / `audio.*` id toasts the reason (`cutRunner`); `sonos.*` config keys are accepted and ignored |
| Playwright runner as a first-class feature | the generic `test.*` runners cover cargo / npm / go / pytest; the Playwright viewer is Remaining, not cut — listed here because the spec titles still say "Playwright" | `test.run_*` run the project's own test command |

## Editing & input

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Pluggable input layer — vim + standard, runtime switch | done | `src/input/mod.zig`, `src/input/vim.zig`, `src/input/standard.zig`, `editor.toggle_keymap` in `src/app/cmd_view.zig`, `:set input=` / `:set editor.input_style=` in `src/app/ex.zig` | |
| Fully remappable keymaps | done | `src/core/keymap.zig`, `Keys{vim,standard,both}` in `src/commands/specs.zig`, `Config.keys` | chord collisions are a compile error per profile |
| Vim modes Normal / Insert / Visual / V-Line / V-Block / Replace | done | `src/input/vim.zig` `VimMode` | |
| Operators + motions | done | `src/input/vim.zig`, `src/editor/motion.zig` | |
| Text objects `iw` `ip` `i(` quotes tag argument | done | `src/editor/select.zig` | |
| Tree-sitter objects `if` / `ic` / `ia` | done | `src/editor/select.zig` `object()`, provider at `src/app.zig` `objectLookup` | |
| Indent objects | done | `src/editor/select.zig` | |
| Registers — named, numbered ring, `0`, blackhole | done | `src/editor/clipboard.zig`, `:reg` in `ex.zig`, `picker.clipboard` in `src/app/cmd_app.zig` | |
| Macros — named | partial | `src/editor/buffer.zig` `macroToggle` / `macroReplay` | not persisted across launches; `vim.macro_*` ids are keymap-only |
| Marks — buffer-local, persisted | done | `src/editor/buffer.zig`, `src/app/session.zig` `Pane.marks`, `:marks` / `:delm`, `picker.marks` | |
| Global (uppercase) marks | missing | — | per-buffer only |
| `.` repeat | done | `src/editor/buffer.zig` dot state | |
| Change list `g;` / `g,` | done | `src/editor/editor.zig` `change_list`, `editor.jump_prev_edit` / `jump_next_edit` | |
| Jumplist `Ctrl-O` / `Ctrl-I` | missing | `nav.back` / `nav.forward` / `nav.jump_toggle_prev` have no runner | Remaining (S) |
| `f` / `t` / `;` / `,` | done | `src/input/vim.zig`, `find_char_on_line` in `src/editor/edit_op.zig` | |
| vim-surround | done | `src/editor/surround.zig` | |
| Multi-cursor (vim side) | done | `src/editor/multicursor.zig` | |
| Abbreviations | done | `abbreviate` in `src/app/ex.zig`, expansion in `src/app/dispatch.zig` | |
| Charwise VISUAL inclusive | done | `make_selection_inclusive` in `src/editor/edit_op.zig` | |
| Folds `za` / `zo` / `zc`, idempotent | done | `src/editor/buffer.zig` folds, `editor.toggle_fold` / `open_fold` / `close_fold` | |
| Fold navigation `zj` / `zk`, fold the selection | done | `editor.fold_next` / `fold_prev` / `fold_selection` in `src/app/cmd_app.zig` | `editor.fold_all_brackets` is missing |
| Flash-motion `s` + two chars | partial | `.flash1` / `.flash2` in `src/input/vim.zig`, `flashJump` in `dispatch.zig` | jumps to the next match; no labels, no armed overlay |
| Ex `:w` `:q` `:e` `:wq` `:x` `:qa` `:bd` `:enew` | done | `src/app/ex.zig` | |
| Ex `:%s/old/new/flags` | partial | `substitute` in `ex.zig` | `g` / `i` only; no `c`, no `n`, no `:&` |
| Ex ranges + marks | done | `Parser.parseRange` / `parseAddr` in `ex.zig` | |
| Ex `:g/` / `:v/` | missing | — | Remaining (M) |
| Ex `:norm` | missing | — | Remaining (M) |
| Ex `:!cmd`, `:r`, `:r !cmd`, `:<` / `:>` | missing | — | Remaining (S) |
| Ex `:sort` | done | `sort` in `ex.zig` | |
| User-defined `:command`s | missing | — | Remaining (M) |
| Ex history with completion | done | `App.cmd_history`, `view.cmdline_history` (`q:`), `cmdlineTabComplete` in `dispatch.zig`, `picker.recent_commands`, `vim.replay_last_ex` | `:set` completes option names and values |
| Standard keymap — modeless VS Code editing | done | `src/input/standard.zig` | |
| `Ctrl-D` add next occurrence | done | `editor.add_cursor_at_next_word` in `src/app/cmd_editor.zig` | |
| `Ctrl-Alt-↑/↓` column cursors | done | `editor.add_cursor_above` / `below` | |
| `Ctrl-Shift-L` select all occurrences | done | `editor.select_all_occurrences` in `src/app/cmd_app.zig` | |
| Undo / redo | done | `src/editor/undo.zig` | |
| Persisted undo per file | done | `src/app/undo_store.zig` (`<data root>/undo/<hash>.zon`, behind `editor.persistent_undo`) | `// changed:` off by default, under the data root |
| System clipboard | missing | `TODO(clipboard-os)` in `src/editor/clipboard.zig` | Remaining (M) |
| Word-wrap | done | `view.toggle_wrap`, `:set wrap`, `EditorPane.wrap` | |
| Auto-indent | done | `src/editor/insert.zig` | |
| Auto-pairs | done | `src/editor/insert.zig` / `delete.zig`, `editor.toggle_auto_pair` in `cmd_app.zig` | |
| Bracket-match highlight / jump | done | `editor.bracket_match` in `cmd_editor.zig` | |
| Code folding — manual | done | `src/editor/buffer.zig` | |
| Code folding — LSP-suggested | done | `applyFolds` in `src/app/lsp.zig` | |
| `.editorconfig` | missing | — | Remaining (S–M) |
| Snippets with tab-stops | done | `src/app/snippets.zig` | `snippet.pick` / `pick_all` have no runner |
| Trailing-whitespace tools | done | `editor.trim_trailing_ws_on_save`, `ensure_trailing_newline` | the highlight (`ui.highlight_trailing_ws`) is not painted |
| `:set` over every discrete config field | done | `option_paths` / `setOption` / `completeSet` in `src/app/ex.zig` | Zig-only: `no` / `!` / `inv` / `?` / `=value`, bare names when unique |
| Ex `:messages` / `:messages!` | done | `src/app/ex.zig` → `src/app/messages.zig` | |

## Panes, splits & tab pages

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Recursive binary split tree | done | `src/app/layout.zig` | |
| Every tool view a `Pane` | done | `src/app/pane.zig` — 17 variants | no Files pane (see File manager) |
| Split side-by-side / stacked | done | `view.split_right` / `split_down`, `:sp` / `:vs` | |
| `Ctrl-W` focus `h j k l w` | done | `src/input/vim.zig` `.window` | |
| `Ctrl-W` split / close / only `s v q c o` | done | same | |
| `Ctrl-W` move `H J K L` | missing | `view.move_split_*` have no runner | Remaining (S) |
| `Ctrl-W` resize `+ - < >`, `_` / `\|` maximize | done | `view.split_grow_*` / `shrink_*` / `maximize_*` in `src/app/cmd_view.zig` | ratio on the enclosing split; the vim.zig chord table does not bind them yet |
| `Ctrl-W` rotate `r` | done | `view.rotate_splits` in `cmd_view.zig` | |
| `Ctrl-W =` equalize | partial | `view.equalize_splits` | not bound in the `Ctrl-W` switch; `toggle_auto_equalize_splits` unread |
| Mouse click-to-focus | done | `src/app/dispatch.zig`, `src/ui/hit.zig` | |
| Mouse drag-to-resize dividers | done | `dispatch.zig` `.divider` drag | |
| Tab pages `:tab*` with independent trees | done | `src/app/cmd_tab.zig`, `Layouts` in `layout.zig` | `tab.reopen` missing |
| Bufferline tab strip | done | `src/ui/bufferline.zig`, per-leaf strips in `render.zig` | |
| Tab pages session-persisted | done | `src/app/session.zig` `tabs` / `active_tab` | |
| Tabline of open buffers | done | `src/ui/bufferline.zig`, `view.focus_tab_1–8` / `focus_tab_last` in `cmd_view.zig` | |
| MRU buffer switching | missing | `buffer.last` / `clear_mru` / `pin_toggle` have no runner | `buffer.next_dirty` / `prev_dirty` landed |
| Reopen closed buffer | done | `buffer.reopen` in `src/app/cmd_buffer.zig` | |
| Recent-files picker | done | `picker.recent` in `src/app/cmd_picker.zig`, `file.open_recent_0–9` / `clear_recent` in `cmd_app.zig` | |
| Alternate-file jump | done | `:A` in `ex.zig` | |
| Session — panes, layout, tab pages, chrome, pins, history | done | `src/app/session.zig` (`.mnml/session.zon`, `session.save` / `restore` / `clear`) | Zig-only; a stale / foreign file is one toast |

## File manager

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Files pane as a `Pane` (`files.open`) | missing | spec only | Remaining (M) |
| `files.open_split` dual layout | missing | spec only | |
| Three sort orders | missing | — | |
| Hidden-file toggle in the Files pane | missing | — | the tree has `view.toggle_hidden` |
| Clickable breadcrumb + destinations picker | missing | — | |
| Per-row git status badges | missing | — | |
| `p` preview from the listing | missing | — | |
| `/`-filter | missing | — | `src/ui/filter_input.zig` exists for panels |
| `file.*` ops from a focused Files pane | missing | — | tree-only today (`src/app/tree.zig`) |
| Multi-select `Space` / `a` / `Esc` | missing | — | |
| Ctrl-click toggle, Shift-click range | missing | — | |
| Right-click acts on marks | missing | — | |
| Marks keyed by path | missing | — | |
| Background transfers on a worker | missing | — | Remaining (M) |
| Statusline transfer chip | missing | — | |
| `transfer.cancel_all` | missing | spec only | |
| `:qa` refuses mid-transfer | missing | — | |
| Undoable delete → `.mnml/trash` | missing | `delete` in `tree.zig` removes outright | Remaining (M) |
| "Delete permanently" in the confirm | missing | — | |
| `files.trash` / `restore_from_trash` | missing | spec only | |
| Trash bounds (7 d / 512 MB / 256 MB) | missing | — | |
| Editor breadcrumb row | partial | `editor.breadcrumb` config + settings row | nothing renders it; `view.toggle_breadcrumb` has no runner |

## Navigation & search

| feature | status | Zig file(s) | note |
|---|---|---|---|
| One fuzzy core | done | `src/ui/fuzzy.zig`, `src/ui/picker.zig` | |
| File finder | done | `picker.files` in `src/app/cmd_picker.zig` | |
| Command palette | done | `cmd_picker.zig` `palette` | |
| Buffer switcher | done | `picker.buffers` | |
| Symbol picker | partial | `lsp.symbols` / `lsp.workspace_symbols` in `src/app/cmd_lsp.zig` | `picker.workspace_symbol` has no runner |
| Marks picker | done | `picker.marks` in `src/app/cmd_app.zig` | |
| Clipboard / register picker | done | `picker.clipboard` in `cmd_app.zig` | Enter inserts |
| Recent-commands picker | done | `picker.recent_commands` in `cmd_app.zig` (+ `view.cmdline_history`) | |
| Which-key leader popup | partial | `src/app/whichkey.zig`, `src/ui/which_key.zig` | see the group rows |
| Which-key `f` find | partial | `whichkey.zig` | `f g` → `find.grep`, which is missing |
| Which-key `b` `t` `g` `s` `l` `a` `c` | done | `whichkey.zig` | `t` lacks hidden-files / keymap / theme leaves |
| Which-key `h` `T` `L` `P` `i` `I` `H` + `1`–`9` | missing | — | `H` harpoon exists as ids (`harpoon.*`) but not in the tree |
| Which-key root leaves `/ n e w q` | done | `whichkey.zig` | `x` closes a buffer here |
| Which-key root leaves `? B m p o` | missing | — | |
| In-buffer find — literal, smart-case, incremental | done | `src/app/find.zig`, `src/app/cmd_find.zig`, `src/ui/find_bar.zig` | |
| In-buffer find — regex | missing | `TODO(find-regex)` | the toggle toasts "literal matching only" |
| Replace | done | `cmd_find.zig` `replace`, `:%s` | |
| Find history | missing | — | |
| Workspace grep → results pane | missing | `find.grep` has no runner | Remaining (L) |
| Cross-file replace / per-hit toggle | missing | — | |
| Quickfix pane | done | `ListPane.Kind.quickfix` in `src/app/pane.zig`, `:cexpr` | |
| Quickfix `:cnext` / `:cprev` / `:cfirst` / `:clast` | done | `qf.*` in `src/app/cmd_app.zig`, the verbs in `ex.zig` | |
| Location lists | missing | — | |
| Multi-root workspaces + repo switcher | missing | `view.add_workspace` … have no runner | Remaining (L) |
| `AddWorkspace` prompt with directory listing | missing | — | |
| Harpoon — pin, jump 1–9, picker | done | `src/app/harpoon.zig`, `src/app/cmd_harpoon.zig` | Zig-only ids: `harpoon.clear` |
| Startup picker (no-argument launch) | done | `src/app/startup_picker.zig` | `// changed:` a workspace row names the relaunch |
| `gf` open path under cursor (+ `:line:col`) | done | `editor.open_at_cursor` / `view.split_open_file_under_cursor` | |
| `H` / `M` / `L`, sideways scroll | done | `view.move_cursor_view_*`, `view.hscroll_*` in `cmd_view.zig` | |
| Focus cycling tree → pane → panel | done | `focus.cycle` in `cmd_app.zig` | |

## Language intelligence (LSP)

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Completion popup | done | `src/app/lsp.zig` `textDocument/completion`, `src/ui/completion_view.zig` | |
| Completion — documentation | done | `drawPopups` in `lsp.zig` | one line |
| Completion — lazy `completionItem/resolve` | done | `lsp.zig` | |
| Completion — snippet items | done | `lsp.zig` → `src/app/snippets.zig` | |
| Go-to definition / declaration / type-definition / implementation | done | `lsp.goto_*` | |
| Find references | done | `lsp.references` | |
| Document + workspace symbols | done | `lsp.symbols` / `workspace_symbols` | |
| Outline pane | done | `src/app/outline.zig` | |
| Diagnostics — gutter signs | done | `lsp.zig`, `src/ui/editor_view.zig` | |
| Diagnostics — Problems pane | done | `src/ui/diagnostics_view.zig`, `PanelId.diagnostics` | |
| `]d` / `[d` | done | `lsp.next_diagnostic` / `prev_diagnostic` | |
| External linters | missing | `Config.linters` is never read | Remaining (M) |
| Code actions — quick-fix | done | `quickFix` in `lsp.zig` | |
| Code actions — refactors + picker | done | `codeAction` → picker | |
| Organize imports | done | `lsp.zig` | |
| Rename | done | `lsp.zig` → `applyWorkspaceEdit` | |
| Rename — inline preview + confirmation pane | missing | — | Remaining (S) |
| Hover | done | `src/ui/hover_view.zig` | |
| Signature help | done | `lsp.signature_help*` | |
| Inlay hints | missing | `inlayHintsToggle` is a stub | Remaining (S) |
| Semantic tokens | missing | — | Remaining (M) |
| Document colors | missing | — | |
| Code lens | missing | — | |
| Document links | missing | — | |
| Call hierarchy | done | `lsp.incoming_calls` / `outgoing_calls` | |
| Type hierarchy | done | `lsp.supertypes` / `subtypes` | |
| Formatting — LSP | done | `lsp.format`, `editor.format` aliases it | whole document |
| Format-on-save | done | `onSavePre` in `lsp.zig` | |
| On-type formatting | missing | — | |
| `willSaveWaitUntil` | missing | `src/lsp/client.zig` declares `false` | |
| External formatters | missing | `Config.formatters` is never read | Remaining (M) |
| Tools picker (installer) | done | `tools.installer` in `src/app/runners.zig` | 18 tools |
| Document highlight, selection range, folding range, executeCommand | done | `lsp.zig` | beyond the Rust list |

## Git

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Gutter signs | done | `marksFor` in `src/app/git.zig` | |
| Branch chip with ahead / behind / counts | done | `statusSegment` in `git.zig` | |
| Clickable provider badge | missing | — | Remaining (S) |
| Diff pane — Hunk view | done | `src/ui/diff_view.zig`, `openDiff` | |
| Diff pane — Inline view | missing | — | Remaining (L, with the rest of the diff pane) |
| Diff pane — Split view | missing | — | |
| Per-hunk stage / unstage / discard | done | `applyHunk`, `s` `u` `x` in `diffKey` | |
| Intraline highlighting | missing | — | |
| Diff `/`-filter | missing | — | |
| Change-density minimap | missing | — | |
| Staging view — lists | done | `src/ui/git_status_view.zig`, `git.status_pane` | |
| Stage / unstage whole files | done | `git.stage` / `unstage` / `*_all` in `src/app/cmd_git.zig` | |
| Dive into hunks | done | `git.diff_file` | |
| Commit from the IDE | done | `git.commit` | |
| Commit graph — coloured lanes | done | `src/ui/git_graph_view.zig`, `git.graph` | |
| Graph — detail panel | missing | Enter opens a diff pane | Remaining (S–M) |
| Graph — sortable columns | missing | — | |
| Graph — filters | done | `git.graph_filter_*` | |
| Graph — hash-jump | missing | — | |
| Graph — WIP row + staging buttons | missing | — | |
| Branch rail | missing | context menu + pickers instead | Remaining (M) |
| Checkout / create / delete | done | `git.checkout` / `new_branch` / `delete_branch` | |
| Worktree management | done | `git.worktree_*` | |
| Fetch / pull / push | done | `git.fetch` / `pull` / `push` / `push_tags` | |
| Cherry-pick | done | `cmd_git.zig`, `c` in the graph | |
| Revert | done | `cmd_git.zig`, `v` in the graph | |
| Tags | done | `git.tag` / `tag_delete` | |
| Stash list picker | done | `git.stash*` | |
| Reflog picker | done | `git.reflog` | |
| Operation undo / redo | done | `src/git/client.zig` `UndoEntry`, `git.undo` / `redo` | |
| Blame gutter | done | `requestBlame` / `blameLabels` in `git.zig` | |
| AI commit message (claude) | missing | `git.ai_commit` is `notInBuild` | Remaining (M) |
| AI recompose HEAD | missing | `git.ai_recompose` stub | |
| AI commit via Codex | missing | `git.codex_commit` stub | |
| Browse current file on the remote (4 hosts) | done | `browseUrl` in `src/git/client.zig` | |
| Browse current commit | missing | file URLs only | Remaining (S) |
| Cross-host PR picker | cut | `pr.picker` toasts the reason (`cutRunner` in `cmd_app.zig`) | forge integrations are rewritten in Zig after the cutover |
| `pr.refresh` cache | cut | same | |
| File history, merge, rebase, multi-repo | done | `git.file_history` / `merge` / `rebase` / `switch_repo` … | beyond the Rust list |

## TODOs, notes & findings

| feature | status | Zig file(s) | note |
|---|---|---|---|
| TODOS scan of `TODO` / `FIXME` / `XXX` / `HACK` / `REVIEW` | done | `src/todos.zig` | |
| Markdown list-item markers | done | `matchLine` in `todos.zig` | |
| `.fixme(` / `.fail(` / `.skip(` call sites | missing | — | Remaining |
| Rescan on file change, throttled | missing | `src/app/watch.zig` stats open buffers only | |
| `+ New todo` → `## Inbox` in `TODO.md` | done | `newCmd` in `todos.zig` | |
| 1000-marker cap + `+` | done | `scan_cap` | |
| Row menu → `.claude/` agents / commands / skills | missing | `openRowMenu` has Open / Copy path / Ignore | Remaining (M) |
| "Fix with Claude Code / Codex" fallback | missing | — | |
| NOTES panel | missing | `render.zig` paints "not in this build yet" | Remaining (S–M) |
| FINDINGS panel | missing | same | |
| `notes.new` / `findings.new` | missing | spec only | |
| `notes.refresh` / `findings.refresh` | missing | spec only | |
| Caps header with live count | done | `src/ui/header.zig`, `src/ui/list_panel.zig` | |
| `/`-focus filter row | done | `src/ui/filter_input.zig` | |
| Accent bar, scrollbar, wheel / drag scroll | done | `src/ui/list_panel.zig` | |
| `⟳` chip right-click menu + auto-refresh | partial | `chipMouse` in `todos.zig` | left-click only; `ui.auto_refresh_off` unread |
| Sort chip — click cycles, right-click lists | done | `openSortMenu` in `todos.zig` | TODOS only |
| Narrow-panel icon-only chip | missing | — | |
| Four sort modes persisted for the three panels | partial | `ui.todos_sort` / `notes_sort` / `findings_sort` exist | only `todos.sort` runs |
| SESSIONS sort axis | partial | `ui.sessions_sort` exists | panel is a stub |
| Row context menus (NOTES / FINDINGS / SEARCH / AGENTS) | missing | — | those panels do not exist |
| `:messages` bell + history | done | `src/app/messages.zig` | Zig-only here; also under UI & theming |

## AI

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Claude CLI / Codex as panes | done | `src/app/ai.zig` → `src/app/pty_pane.zig` | |
| Tail transcripts | done | `src/ai/transcript.zig`, `ai.session_view` | |
| Promote one-shot → interactive | done | `promoteCmd` in `ai.zig` | |
| `ai.claude_code_focus` | done | `ai.zig` | |
| Explain / fix / refactor / write-tests | done | `ai.zig` | |
| Free-text ask | done | `ai.ask` / `ai.reask` | |
| Results stream into a pane | done | `Pane.ai`, `src/ui/ai_view.zig` | |
| Fix / refactor applied as a reviewed diff | partial | `applyCmd` splices the first code block | Remaining (S) |
| Backend — claude CLI print mode | done | `src/ai/cli.zig` | |
| Backend — Messages API + read-only tool loop | done | `src/ai/api_client.zig`, `agentLoop` | |
| Config knobs — backend / model / prompt / cap | done | `Config.Ai`, `ai.show_config` | |
| Ghost text — API backend | done | `src/ai/suggest.zig`, `drawGhost` in `render.zig` | |
| Ghost text — local FIM model | cut | `ai.zig` header; `suggest_backend = local` toasts the migration note | |
| Opt-in via the first-launch wizard | done | `src/app/first_launch.zig` | |
| Opt-in via `ai.setup_suggestions` | done | `ai.zig` | |
| Opt-in via Settings → AI | partial | two rows under Integrations in `src/app/settings.zig` | no AI section / model rows |
| Secret-bearing files never sent | done | `isSecretBearing` in `suggest.zig` | |
| Context-aware chat | done | `chatCmd` in `ai.zig` | |
| Launch profiles | missing | — | Remaining (M), needs the manifest layer |
| Legacy "Set launcher script…" | missing | — | |
| Agents dashboard, spend report | done | `src/app/agents.zig`, `src/app/spend.zig` | beyond the Rust list |

## Terminal & process panes

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Pty — shell | done | `src/app/cmd_term.zig`, `src/app/pty_pane.zig`, `src/pty/` | |
| Pty — claude / Codex | done | `ai.zig` | |
| Pty — any task / command | done | `termEx` (`:term <cmd>`), `src/app/tasks.zig` | |
| Multi-session tab strip | partial | ptys are leaf tabs | no dedicated strip |
| `:rename` | missing | `term.rename` has no runner | Remaining (S) |
| `$` suffix on pty tabs | missing | `src/ui/bufferline.zig` | |
| Close button on pty tabs | missing | — | |
| `:bn` / `:bp` skip ptys | missing | `cycle` in `src/app/cmd_buffer.zig` | |
| Scratch terminal strip | missing | `term.scratch_toggle` has no runner | |
| `tools.htop` / `iftop` / `btop` (+ `term.*`), `ncdu` / `lazygit` / `gh` / `dust` | done | `toolRunner` + `onPath` in `src/app/cmd_app.zig` | PATH probe; brew / apt / winget hint |
| Tasks — config | done | `Config.Task`, `tasks.zig` | |
| Tasks — launcher | done | `task.run` | |
| Startup tasks | done | `State.startup` on the `startup` hook | |
| `term.paste` / `clear` / `restart` | done | `cmd_term.zig` | beyond the Rust list |
| Suspend hint | done | `editor.suspend_hint` in `cmd_app.zig` | |

## Dock widgets

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Three-tier UI (middle tier) | missing | — | Remaining (L) — the whole section |
| Four corners + stacking + 50 % cap | missing | — | |
| `Text` content (`dock.new_text*`) | missing | spec only | |
| `LogTail` content (`dock.new_log_tail`) | missing | spec only | |
| `▼N` chip | missing | — | |
| Size presets | missing | — | |
| Layout modes Overlay / Inline | missing | — | |
| Opacity modes | missing | — | |
| Kebab menu | missing | — | |
| Drag-to-move with snap | missing | — | |
| `dock.close_all` / `move_corner_next` | missing | spec only; a test asserts the not-implemented toast | |
| "New dock note" in the `+` menu | missing | `openNewTabMenu` has four rows | |
| Session persistence of widgets | missing | `session.zig` carries no dock state | |

## HTTP request client

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Send `.http` / `.rest` / `.curl` | done | `src/http/parse.zig`, `http.send` | |
| Multi-block files | done | `http.next_block` / `prev_block` | |
| `{{variable}}` templating | done | `src/http/env.zig` | |
| Environments | done | `env.zig`, `http.pick_env` / `new_env` / `reset_env` | |
| Pre / post-request scripts | missing | directives are skipped in `parse.zig` | Remaining (M) |
| Request pane — form edit | done | `src/app/request_pane.zig`, `src/ui/request_view.zig` | |
| Re-send / copy-as-curl / write-back | done | `http.send` / `copy_curl` / `save` | |
| Tabbed Edit view | done | `EditTab` in `request_view.zig` (six tabs) | |
| `Ctrl+]` / `Ctrl+[`, `Ctrl+1..5` | done | `request_pane.zig` | |
| Side-by-side edit split | missing | `http.toggle_edit_split` is `notInThisBuild` | Remaining (M) |
| `{{VAR}}` inline highlight | missing | Vars tab only | Remaining (M) |
| `{{VAR}}` click → definition | partial | `jumpToEnvVarCmd` opens the env file | not the line |
| `{{VAR}}` right-click quick-fix | partial | `http.set_env_var_value` from the Vars tab | no menu |
| `{{VAR}}` hover | missing | — | |
| Dynamic vars `{{$uuid}}` etc. | done | `env.zig` | |
| HTTP activity-bar panel (7 sections) | missing | `activityHttp` → `notInBuild` | Remaining (L) |
| HTTP panel `/` filter | missing | same | |
| Blank request `http.new` | done | `openBlank` in `src/app/http.zig` | |
| Green `+` chip in the INTEGRATIONS rail | missing | no integrations panel | |
| Paste curl | done | `pasteCurlCmd`, `context_menus.zig` | |
| Field-aware right-click menu | partial | one flat Request menu | no per-field title |
| Cycle method | done | `cycleMethodCmd` | |
| SSE streaming | partial | `src/http/sse.zig` parses; the send reads to the end | Remaining (M) |
| Cookies normalizer | done | `src/http/cookies.zig` | |
| Env files `.mnml/env` + `.rqst/env` | done | `env.zig` | |
| Env resolution chain | done | `env.zig` | |
| Chains | done | `src/http/chain.zig`, `http.run_chain` | |
| Discover | done | `src/http/discover.zig`, CLI | |
| Sources sync | done | `src/http/sources.zig`, `http.sync` on a worker | |
| Bench | done | `src/http/bench.zig` | |
| Mocks | done | `src/http/mock.zig` | |
| History | done | `src/http/history.zig`, `http.history` | |
| Captured browser traffic | done | `src/http/captured.zig`, `browser.autocapture_toggle` | |
| `http.view_captured` | done | `cmd_http.zig` | |
| `http.capture_now` | done | `cmd_browser.zig` | |
| Lookup picker | done | `cmd_http.zig` (`http_lookup_*` purposes) | |
| Env editor | done | `editEnvCmd` | |
| `jwt.decode` | done | `src/http/jwt.zig` | |
| `auth.extract_bearer` | done | `cmd_http.zig` | |
| `sse.parse_active_response` | done | `sse.zig` `parseAll` | |
| CLI `run` / `chain run` / `discover` / `sync` / `proxy` | done | `src/main.zig` → `src/http/cli.zig`, `src/http/proxy.zig` | five rows |
| WebSocket client | done | `src/app/ws_pane.zig`, `src/http/ws.zig` | beyond the Rust list |
| brotli | cut | `src/http/client.zig` never asks for `br` | see Cuts |

## Browser & CDP capture

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Launch Chrome over CDP | done | `src/cdp/client.zig`, `src/app/browser_pane.zig` | |
| Live console | done | `browser_pane.zig` log panel | |
| Filtered network log | done | `NetEntry`, `Panel.net` | fixed filter |
| Navigation log | done | `LogKind.nav` | |
| Network — copy-as-curl, re-send as request pane | done | `resendSelected` | |
| DOM tree with live highlight | partial | `flattenDom` | no `Overlay.highlightNode` |
| Cookies | done | `browser.cookies` / `add` / `edit` / `delete_cookie` | |
| Web storage | done | `browser.storage` / `*_storage` | |
| Performance panel | done | `perf_dump` in `cmd_browser.zig` | |
| Type-to-narrow filters | missing | — | Remaining (S) |
| Full-page screenshot | done | `browser.screenshot` | |
| Per-node screenshot | done | `browser.screenshot_node` | |
| Print-to-PDF | done | `browser.print_pdf` | |
| Snapshot diffs | done | `browser.snapshot` / `diff_snapshot` | |
| Device emulation | done | `browser.device_picker` | |
| Multi-target | done | `Target.setAutoAttach` in `cdp/client.zig` | |
| Headless | done | `browser.headless`, `mnml proxy` | |

## Debugging (DAP)

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Launch | done | `src/dap/client.zig`, `src/app/dap.zig`, `dap.run` | |
| Attach | done | `dap.attach` | |
| Breakpoints — toggle / list / clear | done | `dap.*_breakpoint*` | |
| Conditional breakpoints | done | `toggle_breakpoint_conditional` | |
| Hit-count breakpoints | done | `dap.set_breakpoint_hit_count` | |
| Exception-breakpoints picker | done | `dap.exceptions` | |
| Step controls | done | `src/app/cmd_dap.zig` | |
| Call-stack pane | done | `src/ui/dap_view.zig` | |
| Variables tree | done | `variableRows` in `dap/client.zig` | |
| Set-variable | done | `dap.set_variable` | |
| Watch expressions | done | `dap.add_watch` / `remove_watch` / `clear_watches` | |
| REPL with lazy expand | done | `src/ui/dap_repl_view.zig` | |
| Reverse debugging | done | `dap.step_back` / `reverse_continue` | |

## Testing & quality

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Playwright runner | missing | `test.run_*` run cargo / npm / go / pytest (`src/app/runners.zig`) | Remaining (L) |
| Grouped results pane | missing | output goes to a runner pty | |
| Jump-to-source | missing | — | |
| Trace timeline viewer | missing | — | |
| Flaky dashboard | missing | `flaky.show` has no runner | |
| `.test` DSL | done | `src/e2e/parser.zig` (a superset) | |
| Drives the real `App` | done | `src/e2e/driver.zig`, `app_factory` in `main.zig` | |
| Runs via `mnml-zig test` | done | `testSubcommand` in `src/main.zig` | `--gate`, `--sizes`, the directives |
| Runs under the unit-test harness | partial | `zig build check` runs the gate, the sweep and `defaults.test` | the full corpus is `mnml-zig test` |

## UI & theming

| feature | status | Zig file(s) | note |
|---|---|---|---|
| File-tree rail | done | `src/app/tree.zig` | |
| Bufferline | done | `src/ui/bufferline.zig` | |
| Powerline statusline | done | `src/ui/statusline.zig` | |
| Cmdline bar | done | `render.zig` `FrameRects.cmdline` | |
| Which-key | done | `src/ui/which_key.zig` | |
| Indent guides | done | `src/ui/editor_view.zig` | |
| Sticky scope context | done | `src/app/sticky.zig` | |
| `file.cut` / `copy` / `paste` / `duplicate` | missing | spec only | Remaining (S–M) |
| `file.move_to` with prompt | partial | `moveTo` in `tree.zig` | autocomplete / `~` unverified |
| Ctrl+X/C/V/D chords + menu rows | missing | — | |
| `-copy` / `-copy-N` bump | missing | — | |
| Tree drag → "Move to X?" | done | `dropTreeFile` in `dispatch.zig` | |
| `Alt`-drag copies | missing | no modifier branch | |
| Right side panel — toggle, `Ctrl+Shift+B` | done | `view.toggle_right_panel` | |
| Right panel — drag grip | done | `dispatch.zig`, `right_divider_id` | |
| Right panel — persisted visible + width | partial | `session.zig` | no `ui.right_panel_visible` / `_width` config keys |
| `:set rightpanel` / `rightpanel!` / `norightpanel` | done | `src/app/ex.zig` | |
| Right-panel icon in the palette bar | partial | `render.zig` | `▤`, not the codicon |
| `<leader>tr` | missing | not in `whichkey.zig` | |
| Outline / diagnostics hosted in the panel | done | `render.zig`, `lsp.drawPanel` | |
| `×` evicts the hosted pane | done | `view.right_panel_close_tab` | |
| Empty-state copy | done | `src/ui/empty_state.zig` | |
| Right-panel next / prev tab | done | `view.right_panel_next_tab` / `prev_tab` in `cmd_view.zig` | over the panels this build has |
| Keyboard right-click `Shift+F10` | missing | `view.context_menu_at_focus` has no runner | Remaining (S) |
| Palette bar — sidebar + panel toggles + palette chip | done | `drawPaletteBar` in `render.zig` | |
| Palette bar — integration chips | missing | — | needs the integration layer |
| Palette bar — `+` add-integration | missing | — | |
| Palette bar — narrow drops TABS | missing | the bar hides below 80 columns | |
| Menu glyphs | missing | `MenuItem` has no icon | Remaining (M) |
| `ascii_icons` blanks glyphs | partial | swaps chrome glyphs | no menu glyphs to blank |
| `menu.glyph_audit` | missing | spec only | |
| Submenus | missing | — | |
| Curated five-section `+` menu | missing | four flat rows in `openNewTabMenu` | |
| Per-row kebab pin / hide / copy id | missing | — | |
| `plus_menu_pinned` / `hidden` | partial | fields declared, unread | |
| `ui.external_browser` | partial | field + trust sink | nothing launches with it |
| 94 themes | done | `themes/*.zon`, `src/ui/theme.zig`, `theme.pick` | committed ZON, parsed at comptime |
| F1 click-discovery overlay | partial | `view.discovery` lists hit kinds; F1 → `view.help` → the cheatsheet | not the highlighted-regions overlay |
| Hover tooltips on chips | missing | `ui.hover_tooltip` unread | Remaining (M) |
| Right-click menus throughout | partial | `src/app/context_menus.zig` — editor / tab / tree / mode / `+` / request / todos | no chip / toast / statusline menus |
| First-launch welcome | done | `src/app/first_launch.zig` | |
| About & Settings overlays | done | `view.about` / `view.welcome`, `src/app/settings.zig` | |
| Markdown live preview | done | `src/app/md_preview.zig`, `src/ui/md_view.zig` | |
| Inline images in the preview | missing | `[image: alt]` placeholder | |
| `render_markdown` inline in the editor | missing | field unread | Remaining (M) |
| `markdown_opens_rendered` | done | `src/app.zig` `openPath` | |
| Preview tabs — markdown | partial | opens rendered | no replace-on-next-glance |
| Preview tabs — `.http` / `.curl` | done | `findPreview` in `src/app/http.zig` | |
| Preview tabs — images | missing | no image pane | |
| Typing makes a preview permanent | partial | request panes only | |
| Image rendering (kitty / iTerm2) | missing | capability probed in `src/tui/term.zig` | Remaining (M) |
| Now-playing transport chip | cut | `cutRunner` toasts | |
| Source-aware dispatch (mixr / AppleScript) | cut | same | |
| Idle `♪` chip, `preferred_music_app` | cut | same; config keys accepted and ignored | |
| Mixr panel size chips | cut | same | |
| Stress meter — statusline bar | done | `src/app/stress.zig`, `render.zig` | p95 of a 120-sample ring |
| Stress meter — bufferline copy | missing | — | |
| Stress meter — hover numbers | missing | no hit on the segment | `perf.toast_stress` has them |
| Stress meter — right-click Reset / Copy / Toast | partial | `perf.reset_stress` / `toast_stress` / `hide_stress` / `toggle_stress` exist | no menu; no Copy summary |
| Stress meter — hidden when idle, 120 samples | done | `stress.zig` | |
| Click-to-dismiss toasts | done | `src/ui/toast.zig`, `dispatch.zig` | |
| Toast right-click menu | missing | — | `toast.dismiss_all` / `dismiss_current` landed as commands |
| Undo chip beside the stack | missing | — | |
| `:messages` picker | done | `messages.show` in `src/app/messages.zig` | |
| `:messages!` dump | done | `dump` in `messages.zig`, `:messages!` in `ex.zig` | |
| Persists per workspace | done | `session.zig` `messages` | |
| Bell chip — three states | partial | `bellSegment` in `messages.zig` | no idle state; no clock beside it |
| Zen mode | done | `src/app/zen.zig` (`view.zen` / `view.fullscreen`) | |
| Clickable statusline | partial | mode / file / position register hits | the rest is inert |
| Clock | missing | `ui.clock` unread; `clock.*` have no runner | |
| Settings overlay | done | `src/app/settings.zig`, `src/ui/settings.zig` | 39 discrete rows |
| `:set` for every discrete field | done | `src/app/ex.zig` | Zig-only |
| Update check | done | `src/app/update.zig` | GitHub releases JSON on a worker; `ui.check_updates`, `MNML_NO_UPDATE_CHECK` |
| Startup picker | done | `src/app/startup_picker.zig` | |

## Workspace trust

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Exec-bearing keys gated before use | done | `src/config/trust.zig` (`exec_bearing`, `strip`, `claims`) | 8 sinks |
| `.mnml/integrations/*` manifests gated | missing | no manifest layer | Remaining (with the integration layer) |
| Quiet by default | done | `promptIfNeeded` in `src/app/trust.zig` | |
| Dialog shows the commands, "Don't trust" focused | done | `src/app/trust.zig`, `Claim.format` | |
| Untrusted is restricted, not broken | done | `strip` / `stripSink` | |
| `RESTRICTED` statusline chip | missing | — | Remaining (S) |
| Fingerprinted trust, re-asks on change | done | `fingerprint` in `config/trust.zig` | |
| Decisions outside the workspace, keyed by canonical path | done | `src/config/trusted.zig` (`trusted_workspaces.zon`) | TOML → ZON is the declared cut |
| `workspace.review_trust` | missing | spec only | Remaining (S) |
| Trust-keyed workspace config round-trip | done | `src/config/load.zig` | |

## Headless, IPC & extensibility

| feature | status | Zig file(s) | note |
|---|---|---|---|
| `--headless`, same App + draw path | done | `src/headless.zig`, `src/app/driver.zig` | |
| File IPC `command` / `screen.txt` / `status.json` / `events.jsonl` | done | `src/ipc/channel.zig`, `src/ipc/screen.zig` | + `rects.json` |
| IPC command vocabulary | done | `src/ipc/command.zig` (30 kinds) | |
| Plugins register commands over IPC | done | `register_command`, `DynRegistry` in `src/core/command.zig` | |
| Registered commands in the palette | done | `cmd_picker.zig` walks `dyn_commands` | |
| Registered commands as keybindings | done | `keymap.bindNow`, `Target.named` | |
| Invocation reported back | done | `ackPluginCommand`, `drainPluginEvents` | |
| Tier-2 toasts / sticky / progress / notify | done | `driver.zig` | `notify` degrades to a toast |
| Tier-2 statusline segment / open-pty / activity badge | partial | parsed and acked; `TODO(ipc-tier2)` | Remaining (S–M) |
| `:term <binary>` | done | `termEx` in `cmd_term.zig` | |
| The Rust integration binaries | cut | — | rewritten in Zig on bridge v2 (E5) |
| Manifest-declared dynamic commands | missing | no manifest reader | Remaining (L) |
| `integrations.refresh` | missing | spec only | |
| `.ui.integration_icons` config | partial | `Config.IntegrationIcon` + defaults | nothing reads it |
| Launcher-icon strip | missing | — | Remaining (M) |
| Integration-icon rail | missing | — | |
| `+` add-integration → Marketplace | missing | the `+` is the new-tab chip | |
| Marketplace | missing | `MarketResult = struct { _todo }` | Remaining (L) |
| `integrations.toggle_enabled`, `<leader>iE` | missing | spec only | |
| `integrations.edit` / `remove` / kebab | missing | spec only | |
| Installed / Marketplace / In-Dev tabs | missing | no `PanelId.integrations` | |
| `integrations.icon_picker` | missing | spec only | |
| Glyph baking / audit tooling | missing | spec only | Remaining (M) |
| Glyph-builder SVG preview / font patching | cut | `cutRunner` toasts | |
| Settings overlay `:settings` | done | `view.settings`, `src/app/settings.zig` | |
| Rows `▸ label: [active] / other *`, section headers | done | `src/ui/settings.zig` | |
| Keys `←→` `↑↓` `r` `R` Enter Esc | done | `settings.zig` | Esc restores the file's bytes |
| Centered ~60 % × 70 % | partial | content-sized | cosmetic |
| Right-panel visible / width rows | missing | no config fields | Remaining (S) |
| Startup picker overlay | done | `src/app/startup_picker.zig` | `// changed:` a workspace row names the relaunch |
| `MNML_STARTUP_PICKER=1` | done | `wanted` in `startup_picker.zig` | also when the workspace is `$HOME` |
| `--startup-picker` flag | missing | not parsed in `main.zig` | Remaining (S) |
| `mnml.app` launcher default | missing | no bundle | |
| Update check on launch | done | `src/app/update.zig` | |
| `ui.check_updates = false` opt-out | done | `Config.zig`, `update.zig` | + `MNML_NO_UPDATE_CHECK=1` |
| Skipped in headless | done | the `startup` hook is the terminal loop's | |
| `zig build docs` → `docs/commands.md` | done | `tools/gen_commands.zig`, `build.zig` | Zig-only |
| `zig build check` (E7 gates) | done | `build.zig`, `tools/break-check.sh`, `tests/e2e-zig/defaults.test` | Zig-only |
| Session file `.mnml/session.zon` | done | `src/app/session.zig` | ZON, never JSON |

## Languages

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Tree-sitter highlighting, 39+ languages | done | `grammars` in `build.zig` (42), `src/highlight/table.zig` | |
| Every Rust-listed language | done | same | Zig adds make, regex, markdown_inline, ocaml_interface |
| Repo-local queries (hcl / proto / vue) | done | `local_queries` in `build.zig` | |
| Language injection | done | `src/highlight/engine.zig`, `predicate.zig` | markdown fences, `<script>` / `<style>` tested |
| Extension / filename / injection-name mapping | done | `src/highlight/table.zig` aliases | comptime-validated |
