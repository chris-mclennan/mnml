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

Counted by a script over this file (one `| feature | status |` row per
line), not by hand.

| section | done | partial | cut | missing | rows |
|---|---|---|---|---|---|
| Editing & input | 49 | 0 | 0 | 0 | 49 |
| Panes, splits & tab pages | 19 | 0 | 0 | 1 | 20 |
| File manager | 22 | 0 | 0 | 0 | 22 |
| Navigation & search | 25 | 2 | 0 | 3 | 30 |
| Language intelligence (LSP) | 33 | 0 | 0 | 0 | 33 |
| Git | 37 | 0 | 2 | 0 | 39 |
| TODOs, notes & findings | 20 | 2 | 0 | 0 | 22 |
| AI | 18 | 1 | 1 | 1 | 21 |
| Terminal & process panes | 15 | 0 | 0 | 0 | 15 |
| Dock widgets | 13 | 0 | 0 | 0 | 13 |
| HTTP request client | 40 | 1 | 1 | 1 | 43 |
| Browser & CDP capture | 17 | 0 | 0 | 0 | 17 |
| Debugging (DAP) | 13 | 0 | 0 | 0 | 13 |
| Testing & quality | 9 | 0 | 0 | 0 | 9 |
| UI & theming | 58 | 7 | 4 | 6 | 75 |
| Workspace trust | 9 | 0 | 0 | 1 | 10 |
| Headless, IPC & extensibility | 32 | 5 | 2 | 2 | 41 |
| Languages | 5 | 0 | 0 | 0 | 5 |
| **total** | **434** | **18** | **10** | **15** | **477** |

The first ledger (at `de423c5`) printed 278 / 36 / 10 / 149 of 473; the
same script over that file counts 279 / 36 / 10 / 149 of 474 — the old
table was tallied by hand and off by one. Three rows were added since:
the `ui.*` toggles (a Remaining item before, a row now), Lua scripting
and bridge v2 — the last two beyond the Rust list.

Ids: 901 in `src/commands/specs.zig`; 812 have runners (42 of them the
deliberate `cutRunner` / `notInBuild` stubs), 89 have none. `zig build
-Dpartial=false` names each one.

## Landed since the first ledger

The first ledger was written at `de423c5` (Phases 0–8). Ten merges since,
each with a `docs/parity-notes/<track>.md` that named the rows it flipped
and the file proving each; every claim was re-checked against the source
before the row moved (a disputed one is at the bottom). The notes are
folded in here and in `docs/WAVE3_CONTRACT.md`'s `// changed:` sections.

Row counts are from the status diff between the two ledgers (162
changed rows: 159 flips, 3 new rows), each row attributed to the note
that named it.

| track | rows flipped | what |
|---|---|---|
| `files` | 24 | the File manager section entire (21) + `file.cut` / `copy` / `paste` / `duplicate`, the Ctrl+X/C/V/D chords, `-copy-N` |
| `search` | 7 | regex find, workspace grep + cross-file replace, multi-root workspaces + the `AddWorkspace` prompt, the jumplist, `f g` in which-key |
| `editor-ex` | 13 | `:g` / `:v` / `:norm` / `:!` / `:r` / `:<` / `:>` / `:command` / `:s///c` / `:&`, system clipboard, flash labels, global marks, persisted macros, `.editorconfig`, `Ctrl-W` move + `=`, location lists |
| `git-more` | 15 | diff Inline / Split / intraline / filter / minimap, graph detail / sort / hash-jump / WIP row, the branch rail, AI commit messages, browse-a-commit, the provider badge |
| `lsp-more` | 10 | inlay hints, semantic tokens, colors, code lens, links, on-type formatting, `willSaveWaitUntil`, rename preview, external linters + formatters |
| `panels` | 25 | NOTES / FINDINGS / SESSIONS panels and the TODOS action menu, `.fixme(` scan, rescan-on-change, the sort chips (12); the Dock widgets section entire (13) |
| `http-more` | 11 | pre / post scripts, the edit split, inline `{{VAR}}` highlight / click / hover / quick-fix, the HTTP activity panel + filter, SSE streaming; browser filters and the DOM highlight |
| `ui-polish` | 23 | menu glyphs / submenus / the curated `+` menu / kebab, F1 discovery, hover tooltips, chip / toast / statusline menus, image rendering + preview tabs + inline images, `render_markdown`, the undo chip, the bell, the clickable statusline, `Shift+F10`, right-panel config; the `RESTRICTED` chip and `workspace.review_trust` |
| `misc` | 18 | `ai.apply` as a reviewed diff, launch profiles, the pty tab strip family, the Playwright pane + flaky dashboard, the corpus under `zig build test`, IPC tier-2 effects, `--startup-picker`, `mnml.app`, glyph audit (kept `partial`) |
| independent re-check | 16 | rows no note named: the integration / manifest layer, the palette-bar chip strip, the marketplace, the integrations pane and its tabs / kebab / enable toggle, `integrations.refresh`, `ui.integration_icons`, the editor breadcrumb; the three new rows |

## Remaining — what is still `missing` or `partial`, with an estimate

S = a day, M = a few days, L = a week or more, for one person who knows
the tree. Nothing left is larger than M.

| item | size | section |
|---|---|---|
| MRU buffer switching (`buffer.last` / `clear_mru` / `pin_toggle`) and `tab.reopen` — the ids have no runner | S | Panes |
| `picker.workspace_symbol`, `snippet.pick` / `pick_all`, `editor.fold_all_brackets` — ids without a runner | S | Navigation, Editing |
| Which-key: the `h T L P i I H` groups and `1`–`9`, the root leaves `? B m p o`, `<leader>tr`, the `t` group's hidden-files / keymap / theme leaves, `<leader>iE` | S | Navigation & search |
| Find history (the find bar keeps no ring) | S | Navigation & search |
| Symbol picker as one picker (`lsp.symbols` and `workspace_symbols` are two) | S | Navigation & search |
| `⟳` chip right-click menu and `ui.auto_refresh_off` (the chip is a left-click rescan on every list panel) | S | TODOs, notes & findings |
| Row context menus on the SEARCH and AGENTS panes | S | TODOs, notes & findings |
| Settings → AI section (backend / model rows; today two rows under Integrations); the overlay's 60 % × 70 % centering | S | AI, Headless |
| Legacy "Set launcher script…" (launch profiles cover the use) | S | AI |
| The green `+` chip in the INTEGRATIONS rail (the HTTP panel's row menu and `http.new_request` cover it); a per-field title on the request menu | S | HTTP |
| `Alt`-drag copies in the tree; `file.move_to` autocomplete / `~` unverified | S | UI & theming |
| Palette bar: a dedicated `+` add-integration chip (today the `+` menu's Integrations submenu), and the narrow bar hides below 80 columns instead of dropping TABS | S | UI & theming |
| The right-panel palette-bar codicon (`▤` today); the stress meter's bufferline copy; a clock beside the bell (`ui.clock`, `clock.*`) | S | UI & theming |
| Markdown preview replace-on-next-glance; typing promotes a preview only for request panes | S | UI & theming |
| `ui.external_browser` — trust-gated and never launched; `ui.click_echo`, `coverage_chip_mode`, `menu_bar`, `auto_equalize_splits` (+ `view.toggle_auto_equalize_splits`) unread | S each | UI & theming |
| Integration-icon rail in the tree (`IntegrationIcon` has `in_palette_bar` only); `integrations.icon_picker`; the In-Development tab (`integrations.show_in_dev` toasts) | M | Headless, IPC & extensibility |
| Glyph audit / bake as commands (`integrations.audit_glyphs`, `bake_*_glyphs`, `menu.glyph_audit` have no runner; `zig build glyph-audit` is the tool) | S | Headless, IPC & extensibility |
| `.mnml/integrations/*` manifests as a trust sink (`init.lua` is one; workspace manifests are not) | S | Workspace trust |

## Cuts — and where the user learns it

| cut | why | the user sees |
|---|---|---|
| Local in-process FIM model (`mnml-fim-engine`) | a bundled model is a release-size and build-time cost mnml-zig does not carry; ghost text is API-only | `ai.suggest_backend = local` toasts the migration note (`src/app/ai.zig` header) |
| brotli response decoding | `std.compress` has gzip / deflate / zstd, not brotli; the HTTP client asks for the encodings it can decode | `Accept-Encoding` never lists `br` (`src/http/client.zig`); a forced `br` body is shown raw with a toast |
| WebP images | no decoder in `zigimg` for this release; PNG / JPEG / GIF render over kitty / iTerm2 / sixel | `view.image_open` and the markdown preview show the `[image: alt]` placeholder for `.webp` |
| Glyph-builder SVG preview and Nerd Font patching | SVG rasterising and font patching have no Zig path; the audit / bake half is `zig build glyph-audit` | `integrations.glyph_builder` / `patch_nerd_font_svg` toast the reason (`src/app/cmd_app.zig` `cutRunner`) |
| TOML anywhere (config, themes, manifests, `trusted_workspaces.toml`) | E1 / E2: every persisted format is ZON; the final Rust release ships `mnml export-config-zon` | `docs/CONFIG.md`; the one corpus failure (`settings_persist_to_workspace.test`) asserts TOML by design; the Zig twin in `tests/e2e-zig/` passes |
| The Rust integration binaries and the crates.io marketplace of them (`mnml-forge-*`, `mnml-aws-*`, …) | E5: integrations are rewritten in Zig on a v2 bridge after the cutover; the 0.2.x crates stay published for 0.2.x users | `pr.picker` / `pr.refresh` toast the reason; `:term <binary>` still runs any installed binary as a pty pane; a `crates_keyword` marketplace source is accepted and lists nothing |
| now-playing / Sonos / mixr transport | macOS-only AppleScript + a sibling-app IPC; not a terminal-IDE concern for the successor | every `sonos.*` / `mixr.*` / `audio.*` id toasts the reason (`cutRunner`); `sonos.*` config keys are accepted and ignored |
| Playwright as the generic `test.*` runner | the generic `test.*` runners keep the project's own command (cargo / npm / go / pytest); Playwright has its own ids (`test.run_playwright*`, the Tests pane) — listed here because the spec titles still say "Playwright" | `test.run_*` run the project's own test command |

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
| Registers — named, numbered ring, `0`, blackhole | done | `src/editor/clipboard.zig`, `:reg` in `ex.zig`, `picker.clipboard` in `src/app/cmd_app.zig` | `"+` / `"*` are the OS clipboard (below); a write lands in the unnamed register first, then the sink |
| Macros — named, persisted | done | `putMacro` / `macro` on `src/editor/clipboard.zig` (replays in any buffer), `src/app/macros_store.zig` (`<data root>/macros.zon`) | `vim.macro_*` ids are keymap-only |
| Marks — buffer-local, persisted | done | `src/editor/buffer.zig`, `src/app/session.zig` `Pane.marks`, `:marks` / `:delm`, `picker.marks` | |
| Global (uppercase) marks | done | `src/app/marks_store.zig` (`mA`–`mZ` on the App, `<data root>/marks.zon`), `'A` as an ex address | `'A` opens the file when it is not |
| `.` repeat | done | `src/editor/buffer.zig` dot state | |
| Change list `g;` / `g,` | done | `src/editor/editor.zig` `change_list`, `editor.jump_prev_edit` / `jump_next_edit` | |
| Jumplist `Ctrl-O` / `Ctrl-I` | done | `src/app/jumplist.zig`, `nav.back` / `nav.forward` / `nav.jump_toggle_prev` | two stacks capped at 100; `''` / ``` `` ``` toggle; a search hit and a file open push |
| `f` / `t` / `;` / `,` | done | `src/input/vim.zig`, `find_char_on_line` in `src/editor/edit_op.zig` | |
| vim-surround | done | `src/editor/surround.zig` | |
| Multi-cursor (vim side) | done | `src/editor/multicursor.zig` | |
| Abbreviations | done | `abbreviate` in `src/app/ex.zig`, expansion in `src/app/dispatch.zig` | |
| Charwise VISUAL inclusive | done | `make_selection_inclusive` in `src/editor/edit_op.zig` | |
| Folds `za` / `zo` / `zc`, idempotent | done | `src/editor/buffer.zig` folds, `editor.toggle_fold` / `open_fold` / `close_fold` | |
| Fold navigation `zj` / `zk`, fold the selection | done | `editor.fold_next` / `fold_prev` / `fold_selection` in `src/app/cmd_app.zig`; `editor.fold_all_brackets` (`foldAllBrackets` in `cmd_editor.zig`) | one stack scan per bracket family, the first fold to claim a start line keeps it; `tests/e2e-zig/fold_snippet_pick.test` |
| Flash-motion `s` + two chars, labels | done | `src/app/flash.zig` (`start`, `interceptKey`), `drawFlashCue` in `render.zig`, `Doc.labels` in `src/ui/editor_view.zig` | labels nearest-to-cursor first; a single match jumps at once |
| Ex `:w` `:q` `:e` `:wq` `:x` `:qa` `:bd` `:enew` | done | `src/app/ex.zig` | `:qa` refuses mid-transfer; `:qa!` overrides |
| Ex `:%s/old/new/flags` | done | `substitute` / `compilePattern` in `ex.zig`, `substituteConfirm` / `substituteCount` / `ampersand` in `src/app/ex_verbs.zig`, `src/regex/` | vim patterns; `g` `i` `c` `n`; `:&` / `:&&`; `&`, `\0`–`\9`, `\u \l \U \L \E` in the replacement |
| Ex ranges + marks | done | `Parser.parseRange` / `parseAddr` in `ex.zig` | |
| Ex `:g/` / `:v/` | done | `global` in `ex_verbs.zig` | targets remapped through the edit log after every command; `:g!` = `:v`; E147 on a nested `:g` |
| Ex `:norm` | done | `normal` in `ex_verbs.zig` | keys through the active handler per line; `<esc>` / `<lt>` / `<c-x>` notation |
| Ex `:!cmd`, `:r`, `:r !cmd`, `:<` / `:>` | done | `shell` / `read` / `shift` in `ex_verbs.zig` | `:!` into a reused `[scratch]` pane; `:[range]!` filters; `:!!` repeats |
| Ex `:sort` | done | `sort` in `ex.zig` | |
| User-defined `:command`s | done | `defineCommand` / `deleteCommand` / `runUserCommand` in `ex_verbs.zig` | `<args>` `<q-args>` `<bang>` `<line1>` `<line2>` `<range>`; `<data root>/commands.zon`; Tab completion on the `:` line |
| Ex history with completion | done | `App.cmd_history`, `view.cmdline_history` (`q:`), `cmdlineTabComplete` in `dispatch.zig`, `picker.recent_commands`, `vim.replay_last_ex` | `:set` completes option names and values |
| Standard keymap — modeless VS Code editing | done | `src/input/standard.zig` | Ctrl+C / X / V carry the `"+` hint |
| `Ctrl-D` add next occurrence | done | `editor.add_cursor_at_next_word` in `src/app/cmd_editor.zig` | |
| `Ctrl-Alt-↑/↓` column cursors | done | `editor.add_cursor_above` / `below` | |
| `Ctrl-Shift-L` select all occurrences | done | `editor.select_all_occurrences` in `src/app/cmd_app.zig` | |
| Undo / redo | done | `src/editor/undo.zig` | |
| Persisted undo per file | done | `src/app/undo_store.zig` (`<data root>/undo/<hash>.zon`, behind `editor.persistent_undo`) | `// changed:` off by default, under the data root |
| System clipboard | done | `src/core/clipboard_os.zig` (`Sink`, `probe`, `writeOsc52`, the tool pair), `attach` / `isOsRegister` in `src/editor/clipboard.zig`, `Config.Editor.clipboard` | `.auto` / `.os` / `.internal`; OSC 52 or pbcopy / wl-copy / xclip / xsel / clip.exe; headless and tests get `.none` |
| Word-wrap | done | `view.toggle_wrap`, `:set wrap`, `EditorPane.wrap` | |
| Auto-indent | done | `src/editor/insert.zig` | |
| Auto-pairs | done | `src/editor/insert.zig` / `delete.zig`, `editor.toggle_auto_pair` in `cmd_app.zig` | |
| Bracket-match highlight / jump | done | `editor.bracket_match` in `cmd_editor.zig` | |
| Code folding — manual | done | `src/editor/buffer.zig` | |
| Code folding — LSP-suggested | done | `applyFolds` in `src/app/lsp.zig` | |
| `.editorconfig` | done | `src/editor/editorconfig.zig`, `applyEditorconfig` in `src/editor/buffer.zig`, `App.applyBufferPrefs` | `indent_style` / `indent_size` / `tab_width` / `end_of_line` / `trim_trailing_whitespace`; a slash-in-the-middle glob |
| Snippets with tab-stops | done | `src/app/snippets.zig`; `snippet.pick` / `pick_all` (`openPicker`, `PickerKind.snippets`) | the file's scope + `global`, or every scope; trigger / scope hint / one-line body; Enter inserts at the cursor through the same `insertBody` as a trigger expansion |
| Trailing-whitespace tools | done | `editor.trim_trailing_ws_on_save`, `ensure_trailing_newline` (both read by `Buffer.save`), `ui.highlight_trailing_ws` painted from `render.zig` | |
| `:set` over every discrete config field | done | `option_paths` / `setOption` / `completeSet` in `src/app/ex.zig` | Zig-only: `no` / `!` / `inv` / `?` / `=value`, bare names when unique |
| Ex `:messages` / `:messages!` | done | `src/app/ex.zig` → `src/app/messages.zig` | |

## Panes, splits & tab pages

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Recursive binary split tree | done | `src/app/layout.zig` | |
| Every tool view a `Pane` | done | `src/app/pane.zig` — 27 variants | |
| Split side-by-side / stacked | done | `view.split_right` / `split_down`, `:sp` / `:vs` | |
| `Ctrl-W` focus `h j k l w` | done | `src/input/vim.zig` `.window` | |
| `Ctrl-W` split / close / only `s v q c o` | done | same | |
| `Ctrl-W` move `H J K L` | done | `moveToEdge` in `src/app/layout.zig`, `view.move_split_*` in `src/app/cmd_view.zig`, the `.window` prong | the leaf re-hangs as one half of a new root split |
| `Ctrl-W` resize `+ - < >`, `_` / `\|` maximize | done | `view.split_grow_*` / `shrink_*` / `maximize_*` in `src/app/cmd_view.zig`; bound in the `.window` prong (with `r n d f`) | ratio on the enclosing split |
| `Ctrl-W` rotate `r` | done | `view.rotate_splits` in `cmd_view.zig` | |
| `Ctrl-W =` equalize | done | `'='` in the `.window` prong → `view.equalize_splits`; `ui.auto_equalize_splits` via `App.afterSplitChange` on every split and close, `view.toggle_auto_equalize_splits` in `cmd_view.zig` | the toggle persists to the workspace config and evens the splits at once |
| Mouse click-to-focus | done | `src/app/dispatch.zig`, `src/ui/hit.zig` | |
| Mouse drag-to-resize dividers | done | `dispatch.zig` `.divider` drag | |
| Tab pages `:tab*` with independent trees | done | `src/app/cmd_tab.zig`, `Layouts` in `layout.zig` | `tab.reopen` (`tabReopen`, `App.closed_tabs`, 8 deep) — `// changed:` a closed page's clean panes are closed, so its files come back as tabs of one leaf after the current page, the active one focused; `tests/e2e-zig/buffer_pin_reopen.test` |
| Bufferline tab strip | done | `src/ui/bufferline.zig`, per-leaf strips in `render.zig` | |
| Tab pages session-persisted | done | `src/app/session.zig` `tabs` / `active_tab` | |
| Tabline of open buffers | done | `src/ui/bufferline.zig`, `view.focus_tab_1–8` / `focus_tab_last` in `cmd_view.zig` | |
| MRU buffer switching | done | `App.pane_mru` (`setActive` fronts, `forceClosePane` drops); `buffer.last` / `clear_mru` / `pin_toggle` in `src/app/cmd_buffer.zig` | `buffer.last` reads the MRU past a closed alternate; a pinned tab fronts its strip with the pin glyph (`bufferline.pin_glyph`, `^` ascii), survives `buffer.close_others` / `close_right` / `view.close_others`, rides in `session.zon`; the tab menu's *Pin tab* row; `buffer.next_dirty` / `prev_dirty` landed earlier |
| Reopen closed buffer | done | `buffer.reopen` in `src/app/cmd_buffer.zig` | |
| Recent-files picker | done | `picker.recent` in `src/app/cmd_picker.zig`, `file.open_recent_0–9` / `clear_recent` in `cmd_app.zig` | |
| Alternate-file jump | done | `:A` in `ex.zig` | |
| Session — panes, layout, tab pages, chrome, pins, history | done | `src/app/session.zig` (`.mnml/session.zon`, `session.save` / `restore` / `clear`) | Zig-only; a stale / foreign file is one toast; dock widgets ride along |

## File manager

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Files pane as a `Pane` (`files.open`) | done | `Pane.files`, `src/app/files_pane.zig`, `src/ui/files_view.zig` | name / size / modified / kind columns; the tab title is the directory's name |
| `files.open_split` dual layout | done | `openSplitCmd` in `files_pane.zig` | two browsers side by side, the right one focused |
| Three sort orders | done | `FilesPane.Sort`, `setSort` | dirs first in every mode; `s` cycles; the `sort:` chip and the column headers |
| Hidden-file toggle in the Files pane | done | `files.toggle_hidden`, the `.` chip | `.` / `H` keys; `view.toggle_hidden_all` is the same runner as `view.toggle_hidden` — the tree keeps one `show_hidden` for every root |
| Clickable breadcrumb + destinations picker | done | `drawCrumbs` in `files_view.zig`, `files.destinations` | each segment a target; `b` opens the Go to… picker |
| Per-row git status badges | done | `gitBadge` in `files_pane.zig`, `gitStyle` in `files_view.zig` | the porcelain letter; a directory carries its first child's |
| `p` preview from the listing | done | `preview` in `files_pane.zig` | a leaf of its own, reused on the next `p`; a preview column at ≥ 80 cells |
| `/`-filter | done | `FilesPane.applyFilter`, `src/ui/filter_input.zig` | case-insensitive substring; `(n of total)` in the crumb row |
| `file.*` ops from a focused Files pane | done | `targetPaths` in `src/app/file_clipboard.zig`; the `tree.zig` runners defer to `files_pane.{rename,moveTo,newFile,newFolder}Cmd` | one subject: a focused pane's marks, else its cursor row, else the tree's |
| Multi-select `Space` / `a` / `Esc` | done | `FilesPane.toggleMark` / `markAll` / `clearMarks` | `v` marks from the anchor, `*` inverts |
| Ctrl-click toggle, Shift-click range | done | `click` in `files_pane.zig` | Cmd-click too |
| Right-click acts on marks | done | `openRowMenu` in `files_pane.zig` | titled `Marked` when more than one is marked |
| Marks keyed by path | done | `FilesPane.marks: StringHashMap` | survive a re-sort, a reload, a hidden toggle |
| Background transfers on a worker | done | `src/app/transfers.zig` (`Io.Group`, `AppEvent.transfer`) | copy / move; a same-filesystem move is a rename; cancel removes what it created |
| Statusline transfer chip | done | `transfers.chip` in `render.drawStatusline` | `⇄ 42% 3.1M/s`; hidden at rest; right-click cancels |
| `transfer.cancel_all` | done | `cancelAllCmd` in `transfers.zig` | |
| `:qa` refuses mid-transfer | done | `ex.zig` | toast + refusal; `:qa!` overrides |
| Undoable delete → trash | done | `src/app/trash.zig` | `// changed:` `<data root>/trash/<workspace hash>/`, not `.mnml/trash` — a deleted file must not reappear in the tree, grep or git status |
| "Delete permanently" in the confirm | done | `confirmDelete` in `trash.zig` | `[D]elete / Delete [P]ermanently / [C]ancel`, Cancel the default |
| `files.trash` / `restore_from_trash` | done | `openTrashCmd` / `restoreCmd` in `trash.zig` | the trash is a Files pane titled `Trash`; restore refuses when the origin exists again |
| Trash bounds (7 d / 512 MB / 256 MB) | done | `prune` / `tick` in `trash.zig` | age by the entry stamp; on the first tick, every ten minutes, and after every delete |
| Editor breadcrumb row | done | `drawBreadcrumb` in `render.zig` behind `editor.breadcrumb`, `view.toggle_breadcrumb` | `dir › dir › name` on the tab strip |

## Navigation & search

| feature | status | Zig file(s) | note |
|---|---|---|---|
| One fuzzy core | done | `src/ui/fuzzy.zig`, `src/ui/picker.zig` | |
| File finder | done | `picker.files` in `src/app/cmd_picker.zig` | `ctrl+o` in the vim profile is the jumplist now |
| Command palette | done | `cmd_picker.zig` `palette` | |
| Buffer switcher | done | `picker.buffers` | |
| Symbol picker | done | `lsp.symbols` / `lsp.workspace_symbols` / `picker.workspace_symbol` in `src/app/cmd_lsp.zig` → one `.lsp_symbols` picker (`symbolsPicker` in `lsp.zig`) | `picker.workspace_symbol` (`workspaceSymbolPicker`) sends an empty `workspace/symbol` query straight into the picker — VS Code `Ctrl+T`, the picker's own filter narrows; the no-server test in `lsp.zig` |
| Marks picker | done | `picker.marks` in `src/app/cmd_app.zig` | lists the global marks too |
| Clipboard / register picker | done | `picker.clipboard` in `cmd_app.zig` | Enter inserts |
| Recent-commands picker | done | `picker.recent_commands` in `cmd_app.zig` (+ `view.cmdline_history`) | |
| Which-key leader popup | partial | `src/app/whichkey.zig`, `src/ui/which_key.zig` | see the group rows |
| Which-key `f` find | done | `whichkey.zig` | `f g` → `find.grep` |
| Which-key `b` `t` `g` `s` `l` `a` `c` | done | `whichkey.zig` | `t` has the NvChad leaves — explorer, right panel (+ next / prev / close tab), keymap, theme, hidden files (focused / all) — plus wrap / numbers; `g` and `a` carry the Rust leaves (`a M` mixr is cut) |
| Which-key `h` `T` `L` `P` `i` `I` `H` + `1`–`9` | done | `whichkey.zig`; `tests/e2e-zig/whichkey_groups.test` | `P` (+pr) is dropped — `pr.*` are cut with the Rust integration binaries; `i p` waits on `integrations.icon_picker` (the icon-rail track); `L c r` has no `cargo.run` id; a test asserts every key under a group is unique |
| Which-key root leaves `/ n e w q` | done | `whichkey.zig` | `x` closes a buffer here |
| Which-key root leaves `? B m p o` | done | `whichkey.zig` | cheatsheet / browser / markdown preview / palette / task |
| In-buffer find — literal, smart-case, incremental | done | `src/app/find.zig`, `src/app/cmd_find.zig`, `src/ui/find_bar.zig` | |
| In-buffer find — regex | done | `src/regex/regex.zig` (Oniguruma via ghostty's `pkg/oniguruma`), `src/regex/vim.zig`, `regex` / `bad_pattern` in `find.zig`, `find.toggle_regex` | vim patterns; `ctrl+r` / the `.*` chip; a bad pattern toasts why |
| Replace | done | `cmd_find.zig` `replace`, `:%s` | groups expand in the replacement |
| Find history | done | `src/app/find_history.zig` (`App.find_history`, `FindBarState.hist_cursor`), `history_prev` / `history_next` in `src/ui/find_bar.zig` | Enter remembers the query (de-duped against the newest, 50 deep, a miss too); `↑` / `↓` on the bar recall, past the newest is empty; `// changed:` persisted at `<data root>/find_history.zon` on every accept, not in the workspace session — a query is not a workspace concern; `tests/e2e-zig/find_history.test` |
| Workspace grep → results pane | done | `src/app/grep.zig`, `src/ui/grep_view.zig`, `Pane.grep`, `find.grep` / `view.activity_search` | `rg --json` when on PATH, else a gitignore walk over `src/regex/`; batches of 64, cap 5000 |
| Cross-file replace / per-hit toggle | done | `replaceAll` in `grep.zig`, `find.grep_replace` | Space disables a hit; clean open buffers through `EditOp`s, closed files on disk, dirty buffers refused |
| Quickfix pane | done | `ListPane.Kind.quickfix` in `src/app/pane.zig`, `:cexpr` | |
| Quickfix `:cnext` / `:cprev` / `:cfirst` / `:clast` | done | `qf.*` in `src/app/cmd_app.zig`, the verbs in `ex.zig` | |
| Location lists | done | `src/app/loclist.zig`, `EditorPane.loclist`, `ListPane.Kind.location` | `:lexpr` / `:lopen` / `:lwindow` / `:lclose` / `:lnext` / `:lprev` / `:lfirst` / `:llast`; seeded from LSP diagnostics when empty |
| Multi-root workspaces + repo switcher | done | `Root` / `syncRoots` / `addRoot` / `switchTo` in `src/app/tree.zig`, `view.add_workspace` / `view.switch_workspace`, `discover` in `src/app/git.zig` | `cfg.workspaces` as collapsed sections; every root's repo on the GIT rail; `view.manage_workspaces` / `remove_workspace` / `workspace_menu` have no runner |
| `AddWorkspace` prompt with directory listing | done | `addWorkspace` in `tree.zig` | Tab completes a directory segment and cycles |
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
| External linters | done | `src/lsp/tools.zig`, `lintOnHook` / `lintPath` / `lintWorker` in `src/app/lsp_format.zig` | on open and on save, a worker per run; findings merge beside the server's as server id 0 |
| Code actions — quick-fix | done | `quickFix` in `lsp.zig` | |
| Code actions — refactors + picker | done | `codeAction` → picker | |
| Organize imports | done | `lsp.zig` | |
| Rename | done | `lsp.zig` → `applyWorkspaceEdit` | |
| Rename — inline preview + confirmation pane | done | `src/app/lsp_rename.zig` | per-file toggles, hunk rows `Lnn  before → after`; a single-file rename applies at once |
| Hover | done | `src/ui/hover_view.zig` | |
| Signature help | done | `lsp.signature_help*` | |
| Inlay hints | done | `requestHints` / `virtualTextFor` in `src/app/lsp_decor.zig`, `Doc.virtual_text` in `editor_view.zig`, `lsp.inlay_hints_toggle` | visible window ±1 screen, idle-debounced; `editor.inlay_hints` |
| Semantic tokens | done | `src/lsp/semantic.zig`, `src/app/lsp_semantic.zig`, `layerSpans` in `src/highlight/engine.zig` | full + `full/delta` (+ `range`); laid over the tree-sitter spans; `editor.semantic_tokens` |
| Document colors | done | `virtualTextFor` in `lsp_decor.zig` | a `■ ` swatch before the literal (`# ` under `--ascii`) |
| Code lens | done | `virtualLinesFor` / `runLens` in `lsp_decor.zig`, `Doc.virtual_lines`, `lsp.code_lens_run` | a row above the target; click or Enter runs it; `editor.code_lens` |
| Document links | done | `linkUnderlinesFor` / `linkAtCursor` in `lsp_decor.zig`, `editor.open_url_at_cursor` (`gx`) | |
| Call hierarchy | done | `lsp.incoming_calls` / `outgoing_calls` | |
| Type hierarchy | done | `lsp.supertypes` / `subtypes` | |
| Formatting — LSP | done | `lsp.format`, `editor.format` aliases it; `formatSelection` in `lsp_format.zig` → `lsp.format_selection` | whole document, or the visual selection |
| Format-on-save | done | `onSavePre` in `lsp_format.zig` | the external tool when no server formats |
| On-type formatting | done | `onTyped` in `lsp_format.zig` | the server's trigger characters, behind `editor.format_on_type` |
| `willSaveWaitUntil` | done | `onSavePre` / `handleResponse` in `lsp_format.zig` | behind `editor.will_save_wait_until`; the reply's edits are applied and the buffer written again (D3) |
| External formatters | done | `src/lsp/tools.zig`, `formatExternalPane` in `lsp_format.zig`, `editor.format_external` | stdin → stdout, or `in_place` on `{file}`; `lsp.format` prefers the server and falls back |
| Tools picker (installer) | done | `tools.installer` in `src/app/runners.zig` | 18 tools |
| Document highlight, selection range, folding range, executeCommand | done | `lsp.zig` | beyond the Rust list |

## Git

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Gutter signs | done | `marksFor` in `src/app/git.zig` | |
| Branch chip with ahead / behind / counts | done | `statusSegment` in `git.zig` | |
| Clickable provider badge | done | `badge_id` in `src/ui/git_status_view.zig`, `git.State.provider` | the status pane's header; a click runs `git.browse_commit` |
| Diff pane — Hunk view | done | `src/ui/diff_view.zig`, `openDiff` | |
| Diff pane — Inline view | done | `Mode.flat`, `drawUnified` in `diff_view.zig`, `git.diff_toggle_view` | the whole file, one number column, changed rows tinted |
| Diff pane — Split view | done | `pairs` / `drawSplit` in `diff_view.zig`, `dragDivider` in `git.zig` | removed runs zipped with added runs; the divider drags 15–85 % |
| Per-hunk stage / unstage / discard | done | `applyHunk`, `s` `u` `x` in `diffKey` | |
| Intraline highlighting | done | `src/git/intraline.zig`, `rangesFor` in `diff_view.zig` | prefix / suffix peel then LCS, capped at 64 K cells |
| Diff `/`-filter | done | `filterRows` / `filterSplitRows` in `diff_view.zig`, `refilterDiff` in `git.zig`, `git.diff_filter` | hunks holding the needle; `n` / `p` walk the matches |
| Change-density minimap | done | `density` / `drawStrip` in `diff_view.zig` | one cell per band on the right edge, clickable |
| Staging view — lists | done | `src/ui/git_status_view.zig`, `git.status_pane` | |
| Stage / unstage whole files | done | `git.stage` / `unstage` / `*_all` in `src/app/cmd_git.zig` | |
| Dive into hunks | done | `git.diff_file` | |
| Commit from the IDE | done | `git.commit` | |
| Commit graph — coloured lanes | done | `src/ui/git_graph_view.zig`, `git.graph` | |
| Graph — detail panel | done | `drawDetail` in `git_graph_view.zig`, `requestDetail` / `openDetail` in `git.zig`, `git.graph_detail` | Enter opens it, Tab focuses it, Enter on a file opens that file's diff; the width drags |
| Graph — sortable columns | done | `sortOrder` in `git_graph_view.zig`, `setSort` in `git.zig`, `git.graph_sort` | GRAPH / DATE / AUTHOR / SUBJECT chips; `s` cycles |
| Graph — filters | done | `git.graph_filter_*` | |
| Graph — hash-jump | done | `findByHashPrefix` in `git_graph_view.zig`, `git.graph_jump_hash` | `/` in the pane |
| Graph — WIP row + staging buttons | done | `drawWipRow` in `git_graph_view.zig`, `syncWip` in `git.zig` | `[stage all] [unstage all] [commit…]`; `a` / `A` / `c` on the row |
| Branch rail | done | `appendRailRows` / `requestRail` / `toggleRail` in `git.zig`, `parseTrack` / `parsePrs` in `src/git/parse.zig`, `git.branch_rail_toggle` | branches / worktrees / PRs as folding sections; PRs via `gh pr list --json`, a toast when `gh` is missing |
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
| AI commit message (claude) | done | `aiCommit` in `cmd_git.zig`, `askAi(.staged, .claude)` in `git.zig`, `askProduct` in `src/app/ai.zig` | the staged diff through the worker; the commit prompt opens prefilled |
| AI recompose HEAD | done | `aiRecompose` in `cmd_git.zig`, `askAi(.head, …)`, `Job.amend` | with the commit prompt open it recomposes that message |
| AI commit via Codex | done | `codexCommit` in `cmd_git.zig`, `askAi(.staged, .codex)` | the `codex exec` route; the `api` route is refused with a reason |
| Browse current file on the remote (4 hosts) | done | `src/git/remote.zig` (15 remote shapes tested), `git.browse_file` / `browse_line` | |
| Browse current commit | done | `commitUrl` in `remote.zig`, `git.browse_commit` | the graph's selected commit, a commit diff pane's, else HEAD |
| Cross-host PR picker | cut | `pr.picker` toasts the reason (`cutRunner` in `cmd_app.zig`) | forge integrations are rewritten in Zig after the cutover |
| `pr.refresh` cache | cut | same | |
| File history, merge, rebase, multi-repo | done | `git.file_history` / `merge` / `rebase` / `switch_repo` … | beyond the Rust list |

## TODOs, notes & findings

| feature | status | Zig file(s) | note |
|---|---|---|---|
| TODOS scan of `TODO` / `FIXME` / `XXX` / `HACK` / `REVIEW` | done | `src/todos.zig` | `ui.todo_keywords` adds `custom` |
| Markdown list-item markers | done | `matchLine` in `todos.zig` | |
| `.fixme(` / `.fail(` / `.skip(` call sites | done | `test_markers` in `todos.zig` | titled by the first string argument; never in markdown or a string |
| Rescan on file change, throttled | done | `watch.check` → `noteFileChanged` / `tick` in `todos.zig` | 500 ms after the last change, a used panel only |
| `+ New todo` → `## Inbox` in `TODO.md` | done | `newCmd` in `todos.zig` | |
| 1000-marker cap + `+` | done | `scan_cap` | |
| Row menu → `.claude/` agents / commands / skills | done | `openRowMenu` / `pickAgent` in `todos.zig` | the agent row says what the fallback will do |
| "Fix with Claude Code / Codex" fallback | done | `openInAgent` in `todos.zig` | a pty pane to the right, the marker as the prompt |
| NOTES panel | done | `src/notes.zig`, `PanelId.notes` | `<name>  <title>  <age>` |
| FINDINGS panel | done | `src/findings.zig`, `PanelId.findings` | `<SEV> <name>  <title>  <age>`; frontmatter `severity:` / `status:`; `(N open of M)` |
| `notes.new` / `findings.new` | done | `newCmd` in each | seeded `note-N.md` / `finding-N.md` with the frontmatter template |
| `notes.refresh` / `findings.refresh` | done | `refresh` in each | scan workers on the todos shape |
| Caps header with live count | done | `src/ui/header.zig`, `src/ui/list_panel.zig` | |
| `/`-focus filter row | done | `src/ui/filter_input.zig` | |
| Accent bar, scrollbar, wheel / drag scroll | done | `src/ui/list_panel.zig` | |
| `⟳` chip right-click menu + auto-refresh | done | `src/app/auto_refresh.zig` (`openRefreshMenu`, `on`, `toggle`, `seed`); the `.refresh` prong of `chipMouse` in `todos.zig` / `notes.zig` / `findings.zig` / `sessions.zig` | *Refresh now* + a ✓ *Auto-refresh* row; off stops TODOS' save / watcher rescan, NOTES' / FINDINGS' path hooks and SESSIONS' cadence; `ui.auto_refresh_off` seeds the set and the toggle persists it to the workspace config; `tests/e2e-zig/refresh_chip_row_menus.test` |
| Sort chip — click cycles, right-click lists | done | `openSortMenu` in `todos.zig` / `notes.zig` / `findings.zig` / `sessions.zig` | every list panel |
| Narrow-panel icon-only chip | done | the ladder in `src/ui/header.zig` | full + count → icon + count → full → icon; tested at 26 / 30 / 34 / 40 / 50 |
| Four sort modes persisted for the three panels | done | `todos.sort` / `notes.sort` / `findings.sort` | each persists `ui.<panel>_sort` |
| SESSIONS sort axis | done | `sortCmd` / `sort_auto` / `sort_manual` in `src/sessions.zig` | State / Manual; `J` / `K` build the manual order, persisted in `session.zon` |
| Row context menus (NOTES / FINDINGS / SEARCH / AGENTS) | done | `openRowMenu` in `notes.zig` / `findings.zig` / `sessions.zig` / `src/app/grep.zig` / `src/app/agents.zig` | SEARCH: titled by the hit's `path:line` or the file — open, skip / include the hit, copy, include / skip every hit, replace in files, expand / collapse all, search again (`grep.*`, eight Zig-only ids); AGENTS: transcript, resume, copy id / cwd, export, kill, refresh |
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
| Fix / refactor applied as a reviewed diff | done | `src/app/ai_apply.zig`, `Pane.ai_apply`, `src/ui/ai_apply_view.zig` | per-hunk accept / skip; one `App.splice`, so undo is one step |
| Backend — claude CLI print mode | done | `src/ai/cli.zig` | |
| Backend — Messages API + read-only tool loop | done | `src/ai/api_client.zig`, `agentLoop` | |
| Config knobs — backend / model / prompt / cap | done | `Config.Ai`, `ai.show_config` | |
| Ghost text — API backend | done | `src/ai/suggest.zig`, `drawGhost` in `render.zig` | |
| Ghost text — local FIM model | cut | `ai.zig` header; `suggest_backend = local` toasts the migration note | |
| Opt-in via the first-launch wizard | done | `src/app/first_launch.zig` | |
| Opt-in via `ai.setup_suggestions` | done | `ai.zig` | |
| Opt-in via Settings → AI | done | `Section.ai` in `src/app/settings.zig` — ghost text, ghost-text backend (a virtual row over `ai.extra` + the setup picker's override), Claude / Codex backend (`ai.routing.*.backend`, optional enums: `unset` first), Claude meter | the model stays `ai.model` in the config — free text, and v1 rows are discrete choices (the family idiom); `tests/e2e-zig/settings_ai_section.test` |
| Secret-bearing files never sent | done | `isSecretBearing` in `suggest.zig` | |
| Context-aware chat | done | `chatCmd` in `ai.zig` | |
| Launch profiles | done | `src/app/launch_profiles.zig`, `Config.Ai.launch_profiles` / `default_profile` | the chip menu's *New session:* / *Default:* lanes; the `mnml-ai-<name>` shim (`writeShim`) |
| Legacy "Set launcher script…" | done | the last row of the AI chip menu (`legacy_label` / `openProfilePicker` in `src/app/launch_profiles.zig`) | opens the launch-profile picker (Enter starts a session) and toasts that launcher scripts are profiles now |
| Agents dashboard, spend report | done | `src/app/agents.zig`, `src/app/spend.zig` | beyond the Rust list |

## Terminal & process panes

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Pty — shell | done | `src/app/cmd_term.zig`, `src/app/pty_pane.zig`, `src/pty/` | |
| Pty — claude / Codex | done | `ai.zig` | |
| Pty — any task / command | done | `termEx` (`:term <cmd>`), `src/app/tasks.zig` | |
| Multi-session tab strip | done | `Tab.kind` in `src/ui/bufferline.zig` | pty tabs marked in the strip |
| `:rename` | done | `rename` in `cmd_term.zig`, `term.rename` | |
| `$` suffix on pty tabs | done | `bufferline.zig` | |
| Close button on pty tabs | done | `HitTarget.tab_close` in `bufferline.zig` | |
| `:bn` / `:bp` skip ptys | done | `cycleAny` in `src/app/cmd_buffer.zig` | `!` walks all |
| Scratch terminal strip | done | `term.scratch_toggle` in `cmd_term.zig`, `App.scratch_pty`, `Kind.scratch` | |
| `tools.htop` / `iftop` / `btop` (+ `term.*`), `ncdu` / `lazygit` / `gh` / `dust` | done | `toolRunner` + `onPath` in `src/app/cmd_app.zig` | PATH probe; brew / apt / winget hint |
| Tasks — config | done | `Config.Task`, `tasks.zig` | |
| Tasks — launcher | done | `task.run` | |
| Startup tasks | done | `State.startup` on the `startup` hook | |
| `term.paste` / `clear` / `restart` | done | `cmd_term.zig` | beyond the Rust list |
| Suspend hint | done | `editor.suspend_hint` in `cmd_app.zig` | |

## Dock widgets

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Three-tier UI (middle tier) | done | `dock.draw` after the panes in `render.zig`, `src/app/dock.zig`, `src/ui/dock_view.zig`, `src/core/dock.zig` | |
| Four corners + stacking + 50 % cap | done | `layout` in `dock.zig` | a corner stacks inward; the stack stops at half the body |
| `Text` content (`dock.new_text*`) | done | `promptNewText` / `acceptNewText` in `dock.zig` | |
| `LogTail` content (`dock.new_log_tail`) | done | `tailWorker` / `readTailInto` in `dock.zig` | one read per widget per second, on the dock's `Io.Group` |
| `▼N` chip | done | `dock_view.draw` | rows above the visible tail |
| Size presets | done | `Size` in `src/core/dock.zig` | Small / Medium / Large / Wide / Tall; 15–90 % clamp |
| Layout modes Overlay / Inline | done | `strips` / `bodyAfterStrips` in `dock.zig` | strips tile left to right; each edge capped at a quarter |
| Opacity modes | done | `blend` in `dock.zig`, `blendGround` in `dock_view.zig` | rgb blend at 45 % |
| Kebab menu | done | `openMenu` in `dock.zig`, `MenuAction.dock_set` | current values ticked |
| Drag-to-move with snap | done | `continueDrag` / `dropTarget` / `applyDrop` in `dock.zig`, `drawDrag` in `dock_view.zig` | ghost chip + landing preview; snap within 8 cells |
| `dock.close_all` / `move_corner_next` | done | `closeAll` / `moveCornerNext` in `dock.zig` | |
| "New dock note" in the `+` menu | done | `openNewTabMenu` in `context_menus.zig` | in the New section |
| Session persistence of widgets | done | `capture` / `apply` in `dock.zig`, `Saved.dock` / `dock_hidden` in `session.zig` | Zig-only besides: `dock.toggle`, `dock.add_preset` (clock / git branch / log tail / note), `dock.edit` / `rename` / `remove` |

## HTTP request client

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Send `.http` / `.rest` / `.curl` | done | `src/http/parse.zig`, `http.send` | |
| Multi-block files | done | `http.next_block` / `prev_block` | |
| `{{variable}}` templating | done | `src/http/env.zig` | |
| Environments | done | `env.zig`, `http.pick_env` / `new_env` / `reset_env` | |
| Pre / post-request scripts | done | `src/http/script.zig`, `runScript` in `cmd_http.zig` | `@set-*` before the send, `@assert` / `@capture` after, per chain step |
| Request pane — form edit | done | `src/app/request_pane.zig`, `src/ui/request_view.zig` | |
| Re-send / copy-as-curl / write-back | done | `http.send` / `copy_curl` / `save` | |
| Tabbed Edit view | done | `EditTab` in `request_view.zig` (six tabs) | |
| `Ctrl+]` / `Ctrl+[`, `Ctrl+1..5` | done | `request_pane.zig` | |
| Side-by-side edit split | done | `RequestPane.split*`, `drawTabContent` in `request_view.zig`, `http.toggle_edit_split` | the divider drags; `⇔` chip; `http.toggle_split_orientation` cycles auto / vertical / horizontal |
| `{{VAR}}` inline highlight | done | `paintVarsOnField` / `paintVarsOnLine` in `request_view.zig`, the `editor_view` hook | `syntax.variable` when resolved, `error_fg` when not |
| `{{VAR}}` click → definition | done | `jumpToVarDef` in `src/app/http.zig`, `lineOfKey` in `env.zig` | lands on the `KEY=` line; a toast when undefined |
| `{{VAR}}` right-click quick-fix | done | `openQuickFixMenu` in `http.zig`, `http.quick_fix` | Define in env… / Jump to definition / Pick env… / Inline value / Copy variable name |
| `{{VAR}}` hover | done | `drawVarTip` in `request_view.zig`, `drawEditorVarTip` in `http.zig` | masked for `# @secret` and credential-shaped names |
| Dynamic vars `{{$uuid}}` etc. | done | `env.zig` | |
| HTTP activity-bar panel (7 sections) | done | `src/app/http_panel.zig`, `PanelId.http` | COLLECTIONS / ENVS / CHAINS / MOCKS / COOKIES / RECENT / CAPTURED |
| HTTP panel `/` filter | done | `rebuild` in `http_panel.zig` | one filter across every section; honest header counts |
| Blank request `http.new` | done | `openBlank` in `src/app/http.zig` | |
| Green `+` chip in the INTEGRATIONS rail | done | `new_chip` in `src/ui/header.zig` (`chip.newStyle`, `ChipKind.new`), set by `draw` in `src/app/http_panel.zig`; `chipMouse` runs `http.new` | a green ` + ` before the HTTP panel's ⟳; a click opens the blank request pane; `tests/e2e-zig/http_plus_chip.test` |
| Paste curl | done | `pasteCurlCmd`, `context_menus.zig` | |
| Field-aware right-click menu | done | `openRequestFieldMenu(app, field, x, y)` + `RequestField` in `context_menus.zig` | titled `URL` / `Body` / `Headers` / `Response` by the field under the pointer (the URL row, the edit area by its tab, the response body — `request_pane.zig`) |
| Cycle method | done | `cycleMethodCmd` | |
| SSE streaming | done | `handleStream` in `http.zig`, streaming in `src/http/client.zig`, `src/http/sse.zig` | events land one by one; `http.cancel` stops a stream |
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
| Filtered network log | done | `NetEntry`, `Panel.net` | |
| Navigation log | done | `LogKind.nav` | |
| Network — copy-as-curl, re-send as request pane | done | `resendSelected` | |
| DOM tree with live highlight | done | `flattenDom`, `Overlay.highlightNode` sent as the row under the cursor changes | |
| Cookies | done | `browser.cookies` / `add` / `edit` / `delete_cookie` | |
| Web storage | done | `browser.storage` / `*_storage` | |
| Performance panel | done | `perf_dump` in `cmd_browser.zig` | |
| Type-to-narrow filters | done | `filter` / `filter_caret` on the pane in `browser_pane.zig` | one per panel |
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
| Playwright runner | done | `src/app/tests_pane.zig` (`test.run_playwright*`), `Pane.tests` | Zig-only ids; the generic `test.run_*` stay the project runners |
| Grouped results pane | done | `src/ui/tests_view.zig` | file headers, `s` for slowest-first |
| Jump-to-source | done | `jumpTo` in `tests_pane.zig` | Enter, or a second click |
| Trace timeline viewer | done | `openTrace` in `tests_pane.zig` | a launcher: `npx playwright show-trace` in a pane below |
| Flaky dashboard | done | `src/app/flaky.zig`, `src/ui/flaky_view.zig`, `flaky.show` | `<ws>/.mnml/flaky.zon`, most flips first |
| `.test` DSL | done | `src/e2e/parser.zig` (a superset) | |
| Drives the real `App` | done | `src/e2e/driver.zig`, `app_factory` in `main.zig` | |
| Runs via `mnml-zig test` | done | `testSubcommand` in `src/main.zig` | `--gate`, `--sizes`, `--filter`, the directives |
| Runs under the unit-test harness | done | the `── e2e ──` blocks in `build.zig` | `zig build test` runs the gate; `zig build check` the full corpus (minus the TOML-by-design file); `zig build e2e` |

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
| `file.cut` / `copy` / `paste` / `duplicate` | done | `src/app/file_clipboard.zig` | from the tree or a Files pane's marks |
| `file.move_to` with prompt | done | `moveTo` in `tree.zig` (seeded with the row's folder), `moveToCmd` in `files_pane.zig` (acts on the marks, one background move); Tab → `promptPathComplete` in `dispatch.zig`; `App.expandTilde` | Tab cycles the folders under the typed prefix (`~/` too); `~` is the config's `HOME`, else the process's; tests in `tree.zig` / `dispatch.zig` |
| Ctrl+X/C/V/D chords + menu rows | done | `file_clipboard.zig` | fire in both profiles; vim adds `yy` / `dd` / `P` |
| `-copy` / `-copy-N` bump | done | `copyName` in `file_clipboard.zig` | |
| Tree drag → "Move to X?" | done | `dropTreeFile` in `dispatch.zig` | |
| `Alt`-drag copies | done | `Drag.tree.copy` (the press's Alt, or the release's) in `dispatch.zig`; `confirmMove(…, copy)` / `acceptCopy` in `tree.zig` | *Copy to folder* confirm; the copy runs on the transfer worker, the original stays |
| Right side panel — toggle, `Ctrl+Shift+B` | done | `view.toggle_right_panel` | |
| Right panel — drag grip | done | `dispatch.zig`, `right_divider_id` | |
| Right panel — persisted visible + width | done | `ui.right_panel_visible` / `ui.right_panel_width` read in `initWith` (`src/app.zig`), number rows in `settings.zig` | `// changed:` the default width is 40, not 32 — 32 drops the sort chip to its icon; a session restore still overrides |
| `:set rightpanel` / `rightpanel!` / `norightpanel` | done | `src/app/ex.zig` | |
| Right-panel icon in the palette bar | done | `right_panel_codicon` / `tree_codicon` in `render.zig` | codicon `layout-sidebar-right-off` (EC00), the mirror of the sidebar's EC02; `#` / `=` under `--ascii` |
| `<leader>tr` | done | the `t` group in `whichkey.zig` | `view.toggle_right_panel`; `t ]` / `t [` / `t x` step and close the panel's tabs |
| Outline / diagnostics hosted in the panel | done | `render.zig`, `lsp.drawPanel` | |
| `×` evicts the hosted pane | done | `view.right_panel_close_tab` | |
| Empty-state copy | done | `src/ui/empty_state.zig` | |
| Right-panel next / prev tab | done | `view.right_panel_next_tab` / `prev_tab` in `cmd_view.zig` | |
| Keyboard right-click `Shift+F10` | done | `contextMenuAtFocus` in `context_menus.zig`, `view.context_menu_at_focus` | tree row / panel row / active tab, anchored at the thing's rect |
| Palette bar — sidebar + panel toggles + palette chip | done | `drawPaletteBar` in `render.zig` | |
| Palette bar — integration chips | done | `chips` in `src/app/integrations.zig`, `drawChips` in `src/ui/integrations_view.zig` | config icons and installed manifests with a chip, in `ui.integration_icon_order` |
| Palette bar — `+` add-integration | done | `Button.add_integration` in `drawPaletteBar` (`add_codicon`, green) → `integrations.show_marketplace` | at the right end of the chip strip; the `+` menu's Integrations submenu stays |
| Palette bar — narrow drops TABS | done | `palette_bar_narrow_width` (80) / `palette_bar_min_width` (40) in `render.zig` | below 80 the bar stays: the cluster's extras (badges, AI chips, the stress copy, the `+`) drop and the palette chip is the icon; below 40 it goes; the frame tests pin 39 / 40 / 48 / 120 |
| Menu glyphs | done | `src/ui/menu_glyph.zig`, `paintMenuRows` in `render.zig` | one glyph per command group; `MenuItem.icon` overrides |
| `ascii_icons` blanks glyphs | done | `forItem(it, ascii)` in `menu_glyph.zig` | every group glyph has a one-character ASCII twin |
| `menu.glyph_audit` | done | `menuAuditCmd` in `src/app/glyph_audit.zig` | the menu glyph table (group · codepoint · catalog name · ASCII twin · one-codepoint check) then the source audit, in a scratch pane; needs the workspace's `data/nerd-glyphnames.json` (the mnml-zig tree) |
| Submenus | done | `MenuState.sub`, `openSubmenu` in `context_menus.zig`, `overlayKey` in `dispatch.zig` | → / l / Enter / click open, ← / h step back |
| Curated five-section `+` menu | done | `plus_sections` / `openNewTabMenu` in `context_menus.zig` | New / Open / Panels / Tools / Integrations, pinned rows first |
| Per-row kebab pin / hide / copy id | done | `openCuration` in `context_menus.zig`, `menu.pin_row` / `unpin_row` / `hide_row` / `copy_id` | ⋯ on the focused leaf row, or → on it |
| `plus_menu_pinned` / `hidden` | done | `App.plus_pinned` / `plus_hidden`, `persistPlus` in `context_menus.zig` | written back to the home config |
| `ui.external_browser` | done | `src/app/browser_open.zig` (`argv`), used by `git.openExternal` and `lsp_decor.openExternal` | `open -a <name>` / `start "" <name>` / `<name> <url>`; the trust layer strips the key from an untrusted workspace before it is read |
| 94 themes | done | `themes/*.zon`, `src/ui/theme.zig`, `theme.pick` | committed ZON, parsed at comptime |
| F1 click-discovery overlay | done | `src/app/discovery.zig` (`drawOverlay`, `explain`), `view.discovery` | every hit tinted and labelled; the next click explains |
| Hover tooltips on chips | done | `describe` in `discovery.zig`, `src/ui/tooltip.zig` | `ui.hover_tooltip` popup and the `ui.hover_help` rail box; wake on motion only |
| Right-click menus throughout | done | `src/app/context_menus.zig` — editor / tab / tree / mode / `+` / request / todos / stress / branch / diagnostics / bell / toast | |
| First-launch welcome | done | `src/app/first_launch.zig` | |
| About & Settings overlays | done | `view.about` / `view.welcome`, `src/app/settings.zig` | |
| Markdown live preview | done | `src/app/md_preview.zig`, `src/ui/md_view.zig` | |
| Inline images in the preview | done | `Placement` / `renderWith` in `md_view.zig`, `ui.md_image_rows` | a standalone `![alt](src)` reserves rows; text fallback headless |
| `render_markdown` inline in the editor | done | the `// ── ui toggles ──` block in `editor_view.zig`, `view.toggle_render_markdown` | marks concealed off the cursor line |
| `markdown_opens_rendered` | done | `src/app.zig` `openPath` | |
| Preview tabs — markdown | done | `MdPreviewPane.is_preview`, `PaneStore.findMdGlance`, the in-place swap in `md_preview.open` | a `.here` open (a click, a jump, the session) is a glance the next glance replaces, like the image viewer; `markdown.preview` on an editor is permanent; `tests/e2e-zig/md_preview_glance.test` |
| Preview tabs — `.http` / `.curl` | done | `findPreview` in `src/app/http.zig` | |
| Preview tabs — images | done | `src/app/image_pane.zig` (`open` replaces the preview tab in place), `PaneStore.findImagePreview`, `Pane.image`, `view.image_open` | |
| Typing makes a preview permanent | done | `edited` in `request_pane.zig` (request panes); `swapToEditor` in `md_preview.zig` (a markdown preview becomes the raw editor, which is never a preview) | the rule as Rust's: a request preview is promoted by an edit; typing on a markdown preview swaps the editor in; editor and image tabs carry no promotion — pinned by the `preview tabs:` test in `md_preview.zig` |
| Image rendering (kitty / iTerm2) | done | `src/image/{root,kitty,iterm2,sixel,painter}.zig`, the attach in `tui/loop.zig` | kitty by probe, iTerm2 by `TERM_PROGRAM`, sixel for foot / mlterm; `MNML_IMAGE_PROTOCOL` overrides |
| Now-playing transport chip | cut | `cutRunner` toasts | |
| Source-aware dispatch (mixr / AppleScript) | cut | same | |
| Idle `♪` chip, `preferred_music_app` | cut | same; config keys accepted and ignored | |
| Mixr panel size chips | cut | same | |
| Stress meter — statusline bar | done | `src/app/stress.zig`, `render.zig` | p95 of a 120-sample ring |
| Stress meter — bufferline copy | done | `Button.stress` in `drawPaletteBar` | the same four blocks + p95 in the bar's right cluster, hidden when idle; click toasts, right-click the meter menu |
| Stress meter — hover numbers | done | `describeSegment(.stress)` in `discovery.zig` | p50 / p95 / max / n in the tooltip |
| Stress meter — right-click Reset / Copy / Toast | done | `openStressMenu` in `context_menus.zig`, `perf.copy_stress` | |
| Stress meter — hidden when idle, 120 samples | done | `stress.zig` | |
| Click-to-dismiss toasts | done | `src/ui/toast.zig`, `dispatch.zig` | |
| Toast right-click menu | done | `openToastMenu` in `context_menus.zig`, `toast.dismiss_clicked` / `copy_clicked` | |
| Undo chip beside the stack | done | `App.armUndo` / `takeUndo`, `drawUndo` in `src/ui/toast.zig` | armed by `buffer.close_others` / `close_right` |
| `:messages` picker | done | `messages.show` in `src/app/messages.zig` | |
| `:messages!` dump | done | `dump` in `messages.zig`, `:messages!` in `ex.zig` | |
| Persists per workspace | done | `session.zig` `messages` | |
| Bell chip — three states | done | `bell_seg` in `render.drawStatusline` | idle `○`, yellow count, red count; the clock beside it |
| Zen mode | done | `src/app/zen.zig` (`view.zen` / `view.fullscreen`) | |
| Clickable statusline | done | `Seg.id` in `src/ui/statusline.zig`, `.statusline_seg` in `dispatch.zig` | branch / diagnostics / AI / bell / stress / indent / encoding / transfers / input style; host segments above `seg_dyn_base` |
| Clock | done | `src/app/clock.zig` (`SegId.clock`, `clock.local` / `utc` / `hide` / `menu`) | `HH:MM` local beside the bell, `HH:MMZ` for UTC, a frame on every minute; `ui.clock` seeds and follows (`clock.hide` persists it); `// changed:` local time is libc `localtime_r` — Windows shows UTC; UTC is a session choice, the config has no zone key; `tests/e2e-zig/palette_bar_clock.test` |
| Settings overlay | done | `src/app/settings.zig`, `src/ui/settings.zig` | 39 discrete rows + 9 number rows (`‹ [32] ›`) |
| `:set` for every discrete field | done | `src/app/ex.zig` | Zig-only |
| The `ui.*` toggles | partial | read: relative numbers, whitespace, rainbow brackets, trailing-ws, word highlight, hover help / tooltip, workspace dots, todo keywords, breadcrumb, cluster mode, tab-bar AI icon, AI layout mode (`render.zig`, `tooltip.zig`, `todos.zig`) | `auto_refresh_off` (`auto_refresh.zig`), `clock` (`clock.zig`), `click_echo` (a 120 ms double underline under a left press — `App.click_echo`, `Doc.echo`), `coverage_chip_mode` (`coverage.zig`: the `F` / `C` chip from the two `trends.json` files, four modes), `menu_bar` (`menu_bar.zig`: File / Edit / View / Go / Help on the bar row — always / auto / hidden, `view.menu_bar_cycle` / `menu_bar_open`), `auto_equalize_splits` (`App.afterSplitChange`); each has a test that changes a cell |
| Update check | done | `src/app/update.zig` | GitHub releases JSON on a worker; `ui.check_updates`, `MNML_NO_UPDATE_CHECK` |
| Startup picker | done | `src/app/startup_picker.zig` | |

## Workspace trust

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Exec-bearing keys gated before use | done | `src/config/trust.zig` (`exec_bearing`, `strip`, `claims`) | 9 sinks, `init.lua` among them |
| `.mnml/integrations/*` manifests gated | done | the `workspace_manifests` sink in `src/config/trust.zig` (`Facts.manifests` via `manifestNames`, one claim per file); the scan gate in `integrations.refresh`; `reloadConfig` re-scans on the grant | quiet like every other stripped sink; the dialog lists `integration <name> — runs .mnml/integrations/<name>.zon` |
| Quiet by default | done | `promptIfNeeded` in `src/app/trust.zig` | |
| Dialog shows the commands, "Don't trust" focused | done | `src/app/trust.zig`, `Claim.format` | |
| Untrusted is restricted, not broken | done | `strip` / `stripSink` | |
| `RESTRICTED` statusline chip | done | `Info.restricted` / `seg_restricted` in `src/ui/statusline.zig` | a click runs `workspace.review_trust` |
| Fingerprinted trust, re-asks on change | done | `fingerprint` in `config/trust.zig` | |
| Decisions outside the workspace, keyed by canonical path | done | `src/config/trusted.zig` (`trusted_workspaces.zon`) | TOML → ZON is the declared cut |
| `workspace.review_trust` | done | `src/app/workspace_trust.zig` (`reviewTrust`, `forget` → `trusted.forget`) | untrusted: the first dialog again; trusted: the claims re-read with Keep / Forget |
| Trust-keyed workspace config round-trip | done | `src/config/load.zig` | |

## Headless, IPC & extensibility

| feature | status | Zig file(s) | note |
|---|---|---|---|
| `--headless`, same App + draw path | done | `src/headless.zig`, `src/app/driver.zig` | |
| File IPC `command` / `screen.txt` / `status.json` / `events.jsonl` | done | `src/ipc/channel.zig`, `src/ipc/screen.zig` | + `rects.json` |
| IPC command vocabulary | done | `src/ipc/command.zig` | |
| Plugins register commands over IPC | done | `register_command`, `DynRegistry` in `src/core/command.zig` | owners: `integration` / `script` / `ipc` |
| Registered commands in the palette | done | `cmd_picker.zig` walks `dyn_commands` | |
| Registered commands as keybindings | done | `keymap.bindNow`, `Target.named` | |
| Invocation reported back | done | `ackPluginCommand`, `drainPluginEvents` | |
| Tier-2 toasts / sticky / progress / notify | done | `src/ipc/effects.zig` | `notify` is a toast plus `osascript` / `notify-send` / PowerShell in the terminal loop |
| Tier-2 statusline segment / open-pty / activity badge | done | `effects.zig`, `Info.dyn_*` in `statusline.zig`; the golden pair in `src/ipc/golden/tier2.*.jsonl` | every field; priority pack; `click_command`; badges for every Rust section |
| `:term <binary>` | done | `termEx` in `cmd_term.zig` | |
| The Rust integration binaries | cut | — | rewritten in Zig on bridge v2 (E5) |
| Manifest-declared dynamic commands | done | `src/app/integrations.zig` (the scan of `<data root>/integrations/*.zon` and `<ws>/.mnml/integrations/*.zon`), `src/bridge/manifest.zig` (the SDK's schema), `owner = .integration` in `DynRegistry` | each command opens a `Pane.mount` or a pty, or runs the manifest's `ex` line |
| `integrations.refresh` | done | `refreshCmd` in `integrations.zig` | |
| `.ui.integration_icons` config | done | read by `chips` in `integrations.zig` | |
| Launcher-icon strip | done | the palette-bar chip strip (`drawChips` in `integrations_view.zig`) | |
| Integration-icon rail | missing | `IntegrationIcon` has `in_palette_bar` only; nothing places an icon in the tree rail | |
| `+` add-integration → Marketplace | done | `Button.add_integration` in `render.zig` → `integrations.show_marketplace` | the green codicon chip at the end of the palette bar's strip; the `+` menu row stays |
| Marketplace | done | `src/app/marketplace.zig`, `Pane.marketplace`, `src/ui/marketplace_view.zig`, `marketplace.*` | `github_launcher_folder` and `github_monorepo_apps` sources; a `crates_keyword` source lists nothing |
| `integrations.toggle_enabled`, `<leader>iE` | done | `toggleEnabled` in `integrations.zig` (a picker); the `i` group in `whichkey.zig` | `i d` details, `i h` / `i I` / `i r` the tool panes |
| `integrations.edit` / `remove` / kebab | done | `editCmd` / `removeCmd` / `openRowMenu` in `integrations.zig` | |
| Installed / Marketplace / In-Dev tabs | partial | `Pane.integrations` + `Pane.marketplace`, `integrations.toggle_tab` | `integrations.show_in_dev` toasts "not in this build" |
| `integrations.icon_picker` | missing | spec only | |
| Glyph baking / audit tooling | done | `tools/glyph_audit.zig` (`zig build glyph-audit`), and the same logic in-process — the tool is an import of the app — behind `integrations.audit_glyphs` / `bake_ai_glyphs` / `bake_all_glyphs` / `bake_integration_glyphs` in `src/app/glyph_audit.zig` | the audit lands in a scratch pane with a toast; the three `bake_*` ids do the one bake this build has (the catalog → `<data root>/nerd-glyphs.tsv`) — Rust baked SVGs into a font, which is cut; `tests/e2e-zig/glyph_audit.test` |
| Glyph-builder SVG preview / font patching | cut | `cutRunner` toasts | |
| Settings overlay `:settings` | done | `view.settings`, `src/app/settings.zig` | a row per manifest `settings[]` entry too |
| Rows `▸ label: [active] / other *`, section headers | done | `src/ui/settings.zig` | |
| Keys `←→` `↑↓` `r` `R` Enter Esc | done | `settings.zig` | Esc restores the file's bytes |
| Centered ~60 % × 70 % | done | `draw` in `src/ui/settings.zig` | ~60 % wide (wider when a row needs it, up to 84), capped at ~70 % tall — a long list scrolls inside; a test pins the frame at 120×40 |
| Right-panel visible / width rows | done | the number rows in `settings.zig`, `ui.right_panel_visible` / `_width` | |
| Startup picker overlay | done | `src/app/startup_picker.zig` | `// changed:` a workspace row names the relaunch |
| `MNML_STARTUP_PICKER=1` | done | `wanted` in `startup_picker.zig` | also when the workspace is `$HOME` |
| `--startup-picker` flag | done | `src/main.zig` | sets `MNML_STARTUP_PICKER=1` for the process |
| `mnml.app` launcher default | done | `dist/macos/{Info.plist,launcher.sh,build-app.sh}`, `scripts/package.sh --macos-app` | ghostty first, Terminal.app else; the picker on |
| Update check on launch | done | `src/app/update.zig` | |
| `ui.check_updates = false` opt-out | done | `Config.zig`, `update.zig` | + `MNML_NO_UPDATE_CHECK=1` |
| Skipped in headless | done | the `startup` hook is the terminal loop's | |
| `zig build docs` → `docs/commands.md` | done | `tools/gen_commands.zig`, `build.zig` | Zig-only |
| `zig build check` (E7 gates) | done | `build.zig`, `tools/break-check.sh`, `tests/e2e-zig/defaults.test` | Zig-only |
| Session file `.mnml/session.zon` | done | `src/app/session.zig` | ZON, never JSON |
| Lua scripting — `.mnml/init.lua`, the `mnml` table | done | `src/scripting/lua.zig`, `src/scripting/api.zig`, `script.reload` / `script.edit_init`, the `init_lua` trust sink | beyond the Rust list (D10); a 20 ms budget per entry |
| Bridge v2 — `Pane.mount` over a socket | done | `src/bridge/host.zig` / `wire.zig`, `src/app/mount_pane.zig`, `mount.open` | beyond the Rust list; the SDK is `sdk/mnml-sdk` |

## Languages

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Tree-sitter highlighting, 39+ languages | done | `grammars` in `build.zig` (42), `src/highlight/table.zig` | |
| Every Rust-listed language | done | same | Zig adds make, regex, markdown_inline, ocaml_interface |
| Repo-local queries (hcl / proto / vue) | done | `local_queries` in `build.zig` | |
| Language injection | done | `src/highlight/engine.zig`, `predicate.zig` | markdown fences, `<script>` / `<style>` tested |
| Extension / filename / injection-name mapping | done | `src/highlight/table.zig` aliases | comptime-validated |

## Disputed

Claims in a parity note that did not check out against the source. The
row keeps the status the source supports.

| note | claim | what was looked for | row stays |
|---|---|---|---|
| `misc` | Glyph baking / audit tooling — `done` | `tools/glyph_audit.zig` and `zig build glyph-audit` exist (bake + audit); but the ledger row is the command surface, and `integrations.audit_glyphs`, `bake_ai_glyphs`, `bake_all_glyphs`, `bake_integration_glyphs`, `edit_claude_glyph`, `edit_codex_glyph` and `menu.glyph_audit` have no runner (`zig build -Dpartial=false`) | `partial` |
| `files`, `search`, `ui-polish` | "Command ids: N — every one with a runner" | true of each track's own ids; 89 of the 901 spec ids still have no runner (the list at the top of this page's Remaining table is drawn from them) | the totals line above says 812 / 901 |
