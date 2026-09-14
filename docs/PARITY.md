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
| Panes, splits & tab pages | 19 | 0 | 0 | 0 | 19 |
| File manager | 22 | 0 | 0 | 0 | 22 |
| Navigation & search | 31 | 0 | 0 | 0 | 31 |
| Language intelligence (LSP) | 33 | 0 | 0 | 0 | 33 |
| Git | 47 | 0 | 2 | 0 | 49 |
| TODOs, notes & findings | 22 | 0 | 0 | 0 | 22 |
| AI | 30 | 0 | 1 | 0 | 31 |
| Terminal & process panes | 15 | 0 | 0 | 0 | 15 |
| Dock widgets | 13 | 0 | 0 | 0 | 13 |
| HTTP request client | 48 | 0 | 1 | 0 | 49 |
| Browser & CDP capture | 17 | 0 | 0 | 0 | 17 |
| Debugging (DAP) | 25 | 0 | 0 | 0 | 25 |
| Testing & quality | 17 | 0 | 0 | 0 | 17 |
| UI & theming | 84 | 0 | 3 | 0 | 87 |
| Workspace trust | 11 | 0 | 0 | 0 | 11 |
| Headless, IPC & extensibility | 54 | 0 | 2 | 0 | 56 |
| Languages | 6 | 0 | 0 | 0 | 6 |
| **total** | **544** | **0** | **9** | **0** | **553** |

The first ledger (at `de423c5`) printed 278 / 36 / 10 / 149 of 473; the
same script over that file counts 279 / 36 / 10 / 149 of 474 — the old
table was tallied by hand and off by one. Three rows were added since:
the `ui.*` toggles (a Remaining item before, a row now), Lua scripting
and bridge v2 — the last two beyond the Rust list. Two more since: the
Lua decorations + diagnostics sink and the idle hook / hidden task that
the two shipped example scripts are written against, both Zig-authored.
Three more since: the live picker source with its preview column, the
list helper with its rail sections, and the text operations with
operator registration — the three shapes examples 3, 4 and 5 are
written against, all Zig-authored.

Ids: 1039 in `src/commands/specs.zig` (the four session-worktree ids — `ai.new_session_worktree`, `sessions.open_worktree_in_tree` / `merge_worktree` / `remove_worktree` — landed 2026-09-10); 1039 have runners (35 of them the deliberate `cutRunner` stubs, each naming the cut and the PARITY section that records it), none without — `view.toggle_zoom` landed with the fullscreen track (`zen.zig`) and `integrations.icon_picker` with the leftovers track. `zig build -Dpartial=false` builds, and CI runs it.

## Landed since the first ledger

The first ledger was written at `de423c5` (Phases 0–8). Ten merges since,
each with a `docs/parity-notes/<track>.md` (folded into this page and
deleted at `5498f87`) that named the rows it flipped and the file proving each; every claim was re-checked against the source
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

## Landed since the recount (2026-09-05 → 2026-09-07)

The recount above was taken at `a38b759`. Twelve tracks merged after it
— the same-look tracks measured against the Rust screen dumps in
`docs/ui-spec/` (`tools/ui-diff.sh`), then the debugger, which is the
one deliberate departure from same-look (`tools/zig-spec.sh` dumps the
Zig screen as its own spec). Each row below was re-checked against the
source on 2026-09-07; the rows they touched carry the new pointers.

| track | merged | what the rows now say |
|---|---|---|
| `rail` | 2026-09-06 | the activity bar as its own component (`src/ui/activity_bar.zig`, `src/app/activity_bar.zig`), `ui.activity_bar` always / auto / hidden, the rail menu, badges on Rust's pulse; `view.activity_debug` / `activity_agents` / `activity_cloud_agents` got runners |
| `statusline` | 2026-09-06 | the row is Rust's (`src/app/statusline.zig` builds the lanes in Rust's order; `src/ui/statusline.zig` paints them); the indent / encoding / input-style chips are gone, the mode chip cycles the keymap; every chip routed and described |
| `welcome` | 2026-09-06 | the welcome pane matches rows 10–28 of `rust-120x40.txt` |
| `tree` | 2026-09-06 | `src/ui/tree_view.zig` + `src/ui/icons.zig` (nvim-web-devicons as comptime data), the header chips, neo-tree connectors, the info view (`src/ui/info_view.zig`) replacing the tooltip help box |
| `menu-bar` | 2026-09-06 | row 0 is Rust's `draw_palette_bar` cell for cell (`src/ui/menu_bar.zig`), the ten menus (`src/app/menu_bar.zig`), F10 / Alt+letter; the old bar's stress copy and green Marketplace `+` are gone — the Rust row shows neither |
| `editor-panes` | 2026-09-06 | the bufferline chips, the breadcrumb row, the git toolbar (`src/ui/git_toolbar.zig`), the diff pane's three views, the request pane's boxes |
| `git-mode` | 2026-09-07 | the Git section takes the sidebar as the git palette (`src/app/git_palette.zig`, `src/ui/git_palette.zig`), one graph tab per repo, the detail column always there with the WIP staging and the commit box; the right-panel GIT rail and its branch-rail rows are gone |
| `ai-grid` | 2026-09-12 | new Claude sessions tile by the count on the page (`src/app/ai_grid.zig`): two side by side, the third makes a 2×2 with an `.empty` slot (`Layout.buildGrid`, the `+ Add Claude Code` card), the fourth fills it, then 3×2 and 4×2 the same way, eight per page and the ninth on a fresh page — on the chip click and on Open ×N alike (Rust spills only the batch); a rearranged layout falls back to the plain split; `Layout.equalize` shares by leaf count |
| `vim-fixes` | 2026-09-12 | the vim-profile hunt (`hunt-vim-2026-09-09.md`): `>>` / `V>` end on the range's first line; `}` stops at the adjacent empty line and a Normal cursor never rests past the line end; a Visual `:` covers the cursor's line; `:tabclose` keeps shared panes; `<leader>e` focuses the tree, `<C-n>` toggles it; terminal-normal mode; the ghost is Insert's; unbound leader chords swallowed; nvim-tree's `a r d x R E W`; `is` / `as`; `u` lands on the restored text; `<leader>ra ca gt cm fo fz`; `Ctrl-W t b p`; `j` / `k` in the references list; hover markdown; `:e src/<Tab>` descends |
| `overlays` | 2026-09-07 | prompt / confirm / picker / palette / which-key / help / discovery painted as Rust's; F1 is `view.help`; `ui/fuzzy.zig` is Rust's scorer |
| `debug-mode` | 2026-09-07 | `mnml-fake-dap` (`tools/fake_dap/`), `$NAME` in an adapter's `cmd`, `dap.run` re-reads `.dap` |
| `git-status` | 2026-09-07 | the staging pane is Rust's `git_status_view.rs` cell for cell; the provider badge and the grouped rail rows went with the old pane |
| `section-side` | 2026-09-07 | every section has a side (`src/app/side.zig`); two columns replace the sidebar + right-panel slot; `view.move_section_left` / `_right`, `:sidebar`, `Ctrl-W H` / `L`; `ui.sidebar_side` / `ui.section_side`; `ui.right_panel_width` back to Rust's 32 |
| `launchers` | 2026-09-08 | a manifest without a `binary` is a launcher (`validate` in the SDK, run by both readers); `run` lines through `src/app/launcher_template.zig` (the eight tokens) at fire time, a missing program toasts the install hint; `launchers/{btop,htop,iftop,vscode}.zon` on the Dev tab and as a `✓ Official` local source; `launcher.add_local`; the pinned activity-bar icons (`ui.activity_bar_pinned_integrations`) paint, click and carry the chip's menu — the "wait on the Zig integrations" notes below are gone |
| `debug-ui` | 2026-09-07 | the DEBUG section, the step toolbar and its strip, the Debug Console (`Pane.dap_repl` and `ui/dap_repl_view.zig` are gone), gutter breakpoint editing, inline and hover values, nvim-dap chords |
| `wizard` | 2026-09-08 | the first-launch wizard's installs (`src/app/first_launch_install.zig`): Space runs the Nerd Font install (brew cask / zip + fc-cache / PowerShell per OS), the vendors' `curl \| sh` lines for a missing `claude` / `codex`, the `code` shim symlink — each in an `install: …` pane whose exit 0 toasts the terminal hint and re-detects; the AI chips show a CLI found on PATH; `view.tab_bar_ai_*` / `view.cluster_mode_*` got runners; `ai.launch_profiles` / `default_profile` are exec-bearing; `zig-wizard-120x40.txt`. *2026-09-09 (leftovers):* Space on the Keyboard section is Rust's `wizard_apply_keyboard_fix` — in ghostty on macOS, with no Option/Alt chord ticked, `macos-option-as-alt = true` is written to ghostty's config (flipped in place or appended after a breadcrumb, the original backed up beside it) and the row says which; any other terminal gets its steps as a toast. The probe/fix logic is `src/app/key_doctor.zig` (`detectTerminal`, `remedy`, `ghosttyConfigPath`, `applyGhosttyOptionAsAlt`, `fixNote`), the same API a `keys.doctor` runner reads; `tests/e2e/first_launch_keyboard_fix.test` |
| `http-hooks` | 2026-09-07 | `docs/research/http-vs-posting.md` §3 rows 1–2: the `http_request` / `http_response` hooks with `mnml.http.set_var` / `send` (beyond the Rust list), and the Headers tab as a key / value table whose name and value cells complete — from the last response first, the workspace's `.http` files next, the bundled table last |
| `walkthrough-chrome` | 2026-09-14 | five findings of `docs/research/rust-vs-zig-walkthrough-2026-09-12.md` on the chrome: (1.1) the 0.2 `integrations/*.toml` manifests are counted, never read — one toast per launch + the Installed tab's empty-state line, `integrations.dismiss_toml_notice` / *Don't show again* on the toast's menu writes `ui.integrations_toml_notice_shown`; (1.10) a 0.2 `config.toml` where the `.zon` should be is `Loaded.workspace_toml` / `home_toml`, toasted once per data root (`ui.config_toml_notice_shown`), in `:messages` after, and the workspace one keeps the `RESTRICTED` chip (hover names it, the click / `workspace.review_trust` repeats the converter line); toasts wrap to four rows (`toast.wrap`) and paint beneath the overlays as Rust's `toast_stack::draw` does; (1.11) Esc clears the transient toasts before anything else sees the key, the stack keeps five (Rust's `TOAST_STACK_MAX`), sticky ones untouched; (1.12) `App.recent_commands` — `command.run` notes every success, `session.zon` keeps it, `picker.recent_commands` lists it and the empty palette pins it ★-marked (`Picker.RankOpts.order`); (2.2) a child menu's first arrow moves as well as lights, so the row the keys act on is the row the screen shows (`New ▸`, two downs, Enter opens the request); → on a child's leaf still opens its pin / hide / copy-id list — this tree's keyboard reach to the kebab — where Rust's Right arm reads the parent's row and does nothing (the walkthrough lists that as Rust's bug). Corpus: `plus_menu_submenu_enter`, `esc_dismisses_toasts`, `toast_wraps_and_sits_under_overlays`, `config_toml_restricted_chip`, `integrations_toml_notice`, `recent_commands_picker`. 1043 specs |
| `zig-perf` | 2026-09-12 | the open path on a large file: the first frame paints before the parse (`Syntax.parseDue` — files over 32 KiB wait for the idle gate, smaller ones parse at once), a server's symbol list repaints the outline without a reparse (`lsp.symbols_gen`), the sticky chain is cached per pane and never parses — the line patterns answer when the tree has errors, and a pinned header always encloses the top line (`sticky.Cache`, `scopeEnd`) — and the transport writes from a task (`jsonrpc.zig`); `docs/research/rust-vs-zig-navigation.md`'s addendum has before / after (a 30 000-line open: 1655 → 51 ms) |
| `colors` | 2026-09-10 | one palette for sessions and repos (`src/ui/accent_color.zig`, Rust's `session_color.rs` list in its order); a new Claude pane takes the next slot and paints its `▌` identity strip, tab glyph, SESSIONS card and table row in it; with two or more repos each takes a slot on first sight (home `git.repo_colors`) and paints the pill's column 0, the All-repos sub-headers' gutter, a `▌` down its graph / status / diff panes, their tab glyphs and the tree's repo dot; right-click on any of them → `Color: …` with the current ticked, `Color: Auto` last |

| `git-walk` | 2026-09-12 | `docs/research/rust-vs-zig-walkthrough-2026-09-12.md` findings 1.3–1.6 (`docs/ui-spec/walk/steps-git.jsonl`): the graph's 11-cell DATE / TIME column painted a dead stack buffer (eleven U+FFFD per row at 120 and 80 columns) — the date lives on the frame arena now; `git.graph` lands on the ACTIVE repo's graph and brings a tab back that an `esc` had closed (`git_palette.showActiveGraph`), the rebuild's fallback being the active repo's tab before the first; `git.commit` in git mode is the graph's commit box focused on the WIP row from any tab (Rust's `commit_from_active_wip_textarea_or_prompt` when the box holds a message; the modal, titled with the staged count, outside git mode or under eighty cells); the status pane, `git.diff_file` and the graph's commit diff open beside the active leaf as Rust's `split_leaf_with` does (`git.showBeside`: forty cells each, else a tab). `git_graph_dates.test`, `git_graph_active_repo.test`, `git_commit_box.test`, `git_status_beside.test` |
| `sessions-worktree` | 2026-09-10 | a Claude / Codex session in a git worktree of its own, opt-in per launch or per profile (`src/app/session_worktree.zig`): *New session in a worktree…* on the AI chip's menu, the `+` menus and `+ New session`, `ai.new_session_worktree`, `LaunchProfile.worktree`; a branch-name prompt, `<repo>-worktrees/<name>` (`ai.default_worktree_root` overrides) from `HEAD`, the session's cwd there with `MNML_WORKSPACE`; the SESSIONS card / table row tagged `⑂ <name>`, the row menu's *Open worktree in tree* / *Merge into <branch>…* / *Remove worktree…* behind named confirms, the git panel's WORKTREES row in the session's accent with the same verbs, and one toast when the session ends with commits waiting; `session.zon` `sessions_worktrees` |
| `usage-pane` | 2026-09-12 | the walkthrough's finding 1.9: `ai.claude_usage` opens the quota pane, not the spend report with an apology toast. `src/ai/usage.zig` is the reader Rust's `src/ai_usage.rs` is — the Claude Code OAuth usage endpoint with the per-account token files (`.ai.claude_accounts`, new in `Config.Ai`), the refresh grant, the keychain fallback, the profile, the identity pins; today's Codex session logs — plus `MNML_CLAUDE_USAGE_FIXTURE` for the tests; `src/app/usage_pane.zig` / `src/ui/usage_view.zig` are `Pane.ai_usage` (Claude and Codex) and the cadence; the statusline chip reads the same snapshots (the detail, the countdown, compact / ticker over real accounts); `tests/e2e/usage_pane_fixture.test`; `zig-usage-*.txt` off `docs/ui-spec/usage-fixture` |

## Remaining — what is still `missing` or `partial`, with an estimate

S = a day, M = a few days, L = a week or more, for one person who knows
the tree. Nothing left is larger than M.

| item | size | section |
|---|---|---|
| (none — every spec id has a runner or a `cutRunner`; `zig build -Dpartial=false` builds and CI runs it) | — | Headless, IPC & extensibility |

Everything else the first Remaining list named landed on the `remaining`
branch (2026-09-05; the corpus was 351/352 then — the one failure asserted TOML; it asserts ZON since 2026-09-07 and the corpus is 393/393): MRU buffers, pins and `tab.reopen`; the symbol,
snippet and fold commands; the NvChad which-key groups; find history;
the `⟳` chip menu with auto-refresh and the SEARCH / AGENTS row menus;
Settings → AI and the 60 % × 70 % box; the legacy launcher-script row;
the HTTP `+` chip and the per-field request menu; `Alt`-drag copies and
move-to completion; the palette bar's codicons, `+` chip, narrow rule,
stress copy and the clock; markdown glance tabs; the five unread `ui.*`
fields; the glyph audit / bake commands; workspace manifests as a
trust sink. Each row names its file and its test.

## Cuts — and where the user learns it

| cut | why | the user sees |
|---|---|---|
| Local in-process FIM model (`mnml-fim-engine`) | a bundled model is a release-size and build-time cost mnml-zig does not carry; ghost text is API-only | `ai.suggest_backend = local` toasts the migration note (`src/app/ai.zig` header) |
| brotli response decoding | `std.compress` has gzip / deflate / zstd, not brotli; the HTTP client asks for the encodings it can decode | `Accept-Encoding` never lists `br` (`src/http/client.zig`); a forced `br` body is shown raw with a toast |
| WebP images | no decoder in `zigimg` for this release; PNG / JPEG / GIF render over kitty / iTerm2 / sixel | `view.image_open` and the markdown preview show the `[image: alt]` placeholder for `.webp` |
| Glyph-builder SVG preview and Nerd Font patching | SVG rasterising and font patching have no Zig path; the audit / bake half is `zig build glyph-audit` | `integrations.glyph_builder` / `patch_nerd_font_svg` toast the reason (`src/app/cmd_app.zig` `cutRunner`) |
| TOML anywhere (config, themes, manifests, `trusted_workspaces.toml`) | E1 / E2: every persisted format is ZON; the final Rust release ships `mnml export-config-zon` | `docs/CONFIG.md`; `settings_persist_to_workspace.test` asserts the workspace `.mnml/config.zon` (the Rust corpus asserted a TOML file there — re-aimed 2026-09-07, so the corpus reads 393/393) |
| The Rust integration binaries and the crates.io marketplace of them (`mnml-forge-*`, `mnml-aws-*`, …) | E5: integrations are rewritten in Zig on a v2 bridge after the cutover; the 0.2.x crates stay published for 0.2.x users | `pr.picker` / `pr.refresh` toast the reason; `:term <binary>` still runs any installed binary as a pty pane; a `crates_keyword` marketplace source is accepted and lists nothing |
| Sonos transport | a sibling-app IPC; not a terminal-IDE concern for the successor | every `sonos.*` / `audio.*` id toasts the reason (`cutRunner`); `sonos.*` config keys are accepted and ignored. *// changed 2026-09-07:* the now-playing chip is DONE (`src/app/now_playing.zig`: idle pair, transport, the macOS/mixr poller, `MNML_NOW_PLAYING` for tests); `mixr.set_preferred_*` / `mixr.copy_track` run, the rest of `mixr.*` still toast |
| Playwright as the generic `test.*` runner | the generic `test.*` runners keep the project's own command (cargo / npm / go / pytest); Playwright has its own ids (`test.run_playwright*`, the Tests pane) — listed here because the spec titles still say "Playwright" | `test.run_*` run the project's own test command |

## Editing & input

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Pluggable input layer — vim + standard, runtime switch | done | `src/input/mod.zig`, `src/input/vim.zig`, `src/input/standard.zig`, `editor.toggle_keymap` in `src/app/cmd_view.zig`, `:set input=` / `:set editor.input_style=` in `src/app/ex.zig` | |
| Fully remappable keymaps | done | `src/core/keymap.zig`, `Keys{vim,standard,both}` in `src/commands/specs.zig`, `Config.keys` | chord collisions are a compile error per profile |
| Vim modes Normal / Insert / Visual / V-Line / V-Block / Replace | done | `src/input/vim.zig` `VimMode` | |
| Operators + motions | done | `src/input/vim.zig`, `src/editor/motion.zig` | |
| Text objects `iw` `ip` `is` `i(` quotes tag argument | done | `src/editor/select.zig` | `is` / `as` (`sentenceBounds`) landed 2026-09-12 on `vim-fixes`, probed with `vim -es` |
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
| Fold navigation `zj` / `zk`, fold the selection | done | `editor.fold_next` / `fold_prev` / `fold_selection` in `src/app/cmd_app.zig`; `editor.fold_all_brackets` (`foldAllBrackets` in `cmd_editor.zig`) | one stack scan per bracket family, the first fold to claim a start line keeps it; `tests/e2e/fold_snippet_pick.test` |
| Flash-motion `s` + two chars, labels | done | `src/app/flash.zig` (`start`, `interceptKey`), `drawFlashCue` in `render.zig`, `Doc.labels` in `src/ui/editor_view.zig` | labels nearest-to-cursor first; a single match jumps at once |
| Ex `:w` `:q` `:e` `:wq` `:x` `:qa` `:bd` `:enew` | done | `src/app/ex.zig` | `:qa` refuses mid-transfer; `:qa!` overrides |
| Ex `:%s/old/new/flags` | done | `substitute` / `compilePattern` in `ex.zig`, `substituteConfirm` / `substituteCount` / `ampersand` in `src/app/ex_verbs.zig`, `src/regex/` | vim patterns; `g` `i` `c` `n`; `:&` / `:&&`; `&`, `\0`–`\9`, `\u \l \U \L \E` in the replacement |
| Ex ranges + marks | done | `Parser.parseRange` / `parseAddr` in `ex.zig` | a Visual `:` widens a linewise range before it remembers it, so `'>` is the cursor's line, and leaves Visual on the spot (`vim-fixes`) |
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
| Undo / redo | done | `src/editor/undo.zig` | `u` / `Ctrl-R` land on the restored text, from the cursor the key began at (`placeAfterHistoryHop`, `Buffer.stampUndoCursor`; vim's `u_undoredo`) |
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
| Every tool view a `Pane` | done | `src/app/pane.zig` — 26 variants | `Pane.dap_repl` folded into `Pane.debug` (the toolbar over the Debug Console) on 2026-09-07 |
| Split side-by-side / stacked | done | `view.split_right` / `split_down`, `:sp` / `:vs`; `splitCompanion` in `src/app/cmd_view.zig` | every pane kind splits (2026-09-10, Rust's `split_active`): an editor duplicates, a preview opens its file, a request pane gets a blank request, anything else a scratch editor; `command.reason` spells the shared error tags as sentences (`needs an editor pane`), so no toast reads `NotAnEditor`; `tests/e2e/split_any_pane.test` |
| `Ctrl-W` focus `h j k l w t b p` | done | `src/input/vim.zig` `.window`; `view.focus_top` / `focus_bottom` / `focus_previous` in `cmd_view.zig` | `t` / `b` the first / last leaf, `p` the window that had the keys before (from the tree too) |
| `Ctrl-W` split / close / only `s v q c o` | done | same | |
| `Ctrl-W` move `H J K L` | done | `moveToEdge` in `src/app/layout.zig`, `view.move_split_*` in `src/app/cmd_view.zig`, the `.window` prong | the leaf re-hangs as one half of a new root split |
| `Ctrl-W` resize `+ - < >`, `_` / `\|` maximize | done | `view.split_grow_*` / `shrink_*` / `maximize_*` in `src/app/cmd_view.zig`; bound in the `.window` prong (with `r n d f`) | ratio on the enclosing split |
| `Ctrl-W` rotate `r` | done | `view.rotate_splits` in `cmd_view.zig` | |
| `Ctrl-W =` equalize | done | `'='` in the `.window` prong → `view.equalize_splits`; `ui.auto_equalize_splits` via `App.afterSplitChange` on every split and close, `view.toggle_auto_equalize_splits` in `cmd_view.zig` | the toggle persists to the workspace config and evens the splits at once |
| Mouse click-to-focus | done | `src/app/dispatch.zig`, `src/ui/hit.zig` | *2026-09-10 (mouse-fixes):* a click and a drag resolve an `.editor_cell` hit as the byte offset it carries (`cellByte`) — the second cell of a wide glyph is that glyph, the EOL space the line's end; `ö` clicked reads 10:9 on both sides of `tools/compare.sh compare-mouse` (was 10:11: the handler added the cell delta and counted chars). A gutter press on a file nothing can debug selects the line with the cursor at its column 1, Shift extending (Rust's `SelectLineToEnd`); `tests/e2e/editor_click_multibyte.test`, `gutter_click_selects_line.test` |
| Mouse drag-to-resize dividers | done | `dispatch.zig` `.divider` drag | |
| Tab drag — reorder, into another leaf, into a split | done | `dropTab` / `dropIntoLeaf` in `dispatch.zig`, `layout.zoneFor` | a tab dropped on a strip reorders into that leaf; on a pane body's edge zone it splits the leaf and moves in, on the centre it joins the strip (the hunt's no-op was at `c0b67b0`; on main both work — `tests/e2e/tab_drag_into_split.test`, 2026-09-10) |
| Tab pages `:tab*` with independent trees | done | `src/app/cmd_tab.zig`, `Layouts` in `layout.zig` | `tab.reopen` (`tabReopen`, `App.closed_tabs`, 8 deep) — `// changed:` a closed page's clean panes are closed, so its files come back as tabs of one leaf after the current page, the active one focused; `tests/e2e/buffer_pin_reopen.test` — `:tabclose` / `:tabonly` leave a pane another page still shows to that page (`shownElsewhere`); `tab.reopen` (`tabReopen`, `App.closed_tabs`, 8 deep) — `// changed:` a closed page's clean panes are closed, so its files come back as tabs of one leaf after the current page, the active one focused; `tests/e2e/buffer_pin_reopen.test` |
| Bufferline tab strip | done | `src/ui/bufferline.zig`, per-leaf strips in `render.zig` | the ` +N hidden ` chip counts the tabs off either edge of the window plus the filtered ones (2026-09-10, Rust's `tabs.len() - painted_count`); a click opens the buffer picker; `tests/e2e/tabs_hidden_chip.test` |
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
| One fuzzy core | done | `src/ui/fuzzy.zig`, `src/ui/picker.zig` | `fuzzy.score` is Rust's `fuzzy_match` bonus for bonus (code points); `Picker.rank` is Rust's `refilter` (priority, score, index); the box is Rust's geometry (`Picker.place`, `ui.picker_position`) and never exceeds the screen |
| File finder | done | `picker.files` in `src/app/cmd_picker.zig` (`walkTree`) | Rust's `Open file` list — recents, the tree's order with dotfiles and `.gitignore`, cross-workspace recents a tier below, the directory as the detail; `ctrl+o` in the vim profile is the jumplist now |
| Command palette | done | `cmd_picker.zig` `palette`, `chordHint` | rows `group  ·  title  ·  id`, the default chords as the detail; `rust-palette-120x40.txt`. *2026-09-14 (walkthrough-chrome):* the recently-run commands (`App.recent_commands`) head an empty query newest first, `★`-marked, +50 on a typed one — Rust's recents > pane-scoped > the rest |
| Buffer switcher | done | `picker.buffers` | |
| Symbol picker | done | `lsp.symbols` / `lsp.workspace_symbols` / `picker.workspace_symbol` in `src/app/cmd_lsp.zig` → one `.lsp_symbols` picker (`symbolsPicker` in `lsp.zig`) | `picker.workspace_symbol` (`workspaceSymbolPicker`) sends an empty `workspace/symbol` query straight into the picker — VS Code `Ctrl+T`, the picker's own filter narrows; the no-server test in `lsp.zig` |
| Marks picker | done | `picker.marks` in `src/app/cmd_app.zig` | lists the global marks too |
| Clipboard / register picker | done | `picker.clipboard` in `cmd_app.zig` | Enter inserts |
| Recent-commands picker | done | `picker.recent_commands` in `cmd_app.zig` over `App.recent_commands` (`command.run` notes each success; `session.zon` `recent_commands`) | the commands that ran, newest first, `group · title · id` rows, Enter runs the id again; the `:` line's own history is `view.cmdline_history`. *2026-09-14:* was the `:` history (`no : lines yet`) |
| Which-key leader popup | done | `src/app/whichkey.zig`, `src/ui/which_key.zig` | every group row below is done; the popup's `<leader>` title is Rust's in both profiles (`rust-whichkey-120x40.txt` is the standard profile) |
| Info-box copy per profile | done | `chordOf` / `chordLine` in `src/app/info_view.zig` | the editor summary's chords come from the spec table under the active profile (D4b, 2026-09-10): `[gd] Definition · [K] Hover` for vim, `[F12] Definition · [Ctrl+K Ctrl+I] Hover` for standard — Rust's `hover_help.rs` hard-codes the vim spelling; the file's tests were container-imported and never ran until `app.zig`'s test block named it |
| Which-key `f` find | done | `whichkey.zig` | `f g` → `find.grep` |
| Which-key `b` `t` `g` `s` `l` `a` `c` | done | `whichkey.zig` | `t` has the NvChad leaves — explorer, right panel (+ next / prev / close tab), keymap, theme, hidden files (focused / all) — plus wrap / numbers; `s H` / `s L` move the focused section to the other column; `g` and `a` carry the Rust leaves (`a M` mixr is cut) |
| Which-key `h` `T` `L` `P` `i` `I` `H` + `1`–`9` | done | `whichkey.zig`; `tests/e2e/whichkey_groups.test` | `P` (+pr) is there with two `dead` leaves (`whichkey.Node.dead` — a row for a command neither editor has; a press says so), as Rust shows it; `i p` waits on `integrations.icon_picker` (the icon-rail track); `L c r` has no `cargo.run` id; a test asserts every key under a group is unique |
| Which-key root leaves `/ n e w q` | done | `whichkey.zig` | the root reads as Rust's — `e explorer`, `q close buffer`, `w write/save`, no `x`; the title is `<leader>` / `<leader> f`; `rust-whichkey-120x40.txt` at zero differing lines |
| Which-key `d` +debug — the vim profile's | done | `groupVim('d', "+debug")` in `whichkey.zig`, `Entry.vim_only`; `tests/e2e/debug_vim_leader.test` | nvim-dap's leader chords (`b B l c o i O p R t r w u h`); the standard profile's `Ctrl+K` popup keeps Rust's rows (`steps-whichkey` stays at zero differing lines) |
| Which-key root leaves `? B m p o` | done | `whichkey.zig` | cheatsheet / browser / markdown preview / palette / task |
| In-buffer find — literal, smart-case, incremental | done | `src/app/find.zig`, `src/app/cmd_find.zig`, `src/ui/find_bar.zig` | |
| In-buffer find — regex | done | `src/regex/regex.zig` (Oniguruma via ghostty's `pkg/oniguruma`), `src/regex/vim.zig`, `regex` / `bad_pattern` in `find.zig`, `find.toggle_regex` | vim patterns; `ctrl+r` / the `.*` chip; a bad pattern toasts why |
| Replace | done | `cmd_find.zig` `replace`, `:%s` | groups expand in the replacement |
| Find history | done | `src/app/find_history.zig` (`App.find_history`, `FindBarState.hist_cursor`), `history_prev` / `history_next` in `src/ui/find_bar.zig` | Enter remembers the query (de-duped against the newest, 50 deep, a miss too); `↑` / `↓` on the bar recall, past the newest is empty; `// changed:` persisted at `<data root>/find_history.zon` on every accept, not in the workspace session — a query is not a workspace concern; `tests/e2e/find_history.test` |
| SEARCH sidebar section | done | `src/app/search_section.zig`, `src/ui/search_section_view.zig`, `PanelId.search`, `view.activity_search`, `search.*` | Rust's `draw_search_section` on `ListPanel` (`prelude_rows`): the `Aa` / `\b` / `.*` flags before the refresh chip, ` / query█`, `N hits (git grep)` naming the backend, the hits by file — a file row folds (`h` / `l`, the arrows) — Enter or a click opens the file at its line, the row menu (open, open to the side, copy path:line / line, search again, open as pane), Esc clears the query. `git grep -n --column` first — the tracked files only (Rust's 16 hits where the walk found 437) — then `rg`, then the walk; `search.toggle_*` flip the section's flags when it is shown (the pane's otherwise). `zig-search-120x40.txt`; `tests/e2e/search_section.test` |
| Workspace grep → results pane (Zig-only door) | done | `src/app/grep.zig`, `src/ui/grep_view.zig`, `Pane.grep`, `find.grep`, `search.open_pane` | `rg --json` when on PATH, else a gitignore walk over `src/regex/`; batches of 64, cap 5000. Rust has no such pane: the section's *Open as pane* (row menu, rail menu, `o`) and `find.grep` open it — the replace and the per-hit toggles live here |
| Cross-file replace / per-hit toggle | done | `replaceAll` in `grep.zig`, `find.grep_replace` | Space disables a hit; clean open buffers through `EditOp`s, closed files on disk, dirty buffers refused |
| Quickfix pane | done | `ListPane.Kind.quickfix` in `src/app/pane.zig`, `:cexpr` | |
| Quickfix `:cnext` / `:cprev` / `:cfirst` / `:clast` | done | `qf.*` in `src/app/cmd_app.zig`, the verbs in `ex.zig` | |
| Location lists | done | `src/app/loclist.zig`, `EditorPane.loclist`, `ListPane.Kind.location` | `:lexpr` / `:lopen` / `:lwindow` / `:lclose` / `:lnext` / `:lprev` / `:lfirst` / `:llast`; seeded from LSP diagnostics when empty |
| Multi-root workspaces + repo switcher | done | `Root` / `syncRoots` / `addRoot` / `switchTo` in `src/app/tree.zig`, `view.add_workspace` / `view.switch_workspace`, `discover` in `src/app/git.zig` | `cfg.workspaces` as collapsed sections; every root's repo on the GIT rail; `view.manage_workspaces` / `remove_workspace` / `workspace_menu` got runners on the `runners` track (`src/app/tree.zig`) |
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
| Outline pane | done | `src/app/outline.zig` (`drawPanel`), `Section.outline` / `PanelId.outline`, `outline.show` | a section with a side, right by default; `outline.show` keeps Rust's rule — the column when it is open, else a split (`App.outline_panel`); `rust-outline-120x40.txt` |
| Diagnostics — gutter signs | done | `lsp.zig`, `src/ui/editor_view.zig` | |
| Diagnostics — Problems pane | done | `src/ui/diagnostics_view.zig`, `PanelId.diagnostics` / `Section.diagnostics`, `lsp.drawPanel` | a section with a side, right by default; `lsp.diagnostics` places it |
| `]d` / `[d` | done | `lsp.next_diagnostic` / `prev_diagnostic` | |
| External linters | done | `src/lsp/tools.zig`, `lintOnHook` / `lintPath` / `lintWorker` in `src/app/lsp_format.zig` | on open and on save, a worker per run; findings merge beside the server's as server id 0 |
| Code actions — quick-fix | done | `quickFix` in `lsp.zig` | |
| Code actions — refactors + picker | done | `codeAction` → picker | |
| Organize imports | done | `lsp.zig` | |
| Rename | done | `lsp.zig` → `applyWorkspaceEdit` | |
| Rename — inline preview + confirmation pane | done | `src/app/lsp_rename.zig` | per-file toggles, hunk rows `Lnn  before → after`; a single-file rename applies at once |
| Hover | done | `src/ui/hover_view.zig` | *2026-09-10 (mouse-fixes):* the box registers `.hover_popup` over itself; the wheel scrolls it two lines an event (Rust's ±2) instead of the editor under it, a press puts it away — markdown emphasis and code spans paint as such through `md_view.inlineSegs`, the markers dropped |
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
| Tools picker (installer) | done | `tools.installer` / `known_tools` in `src/app/runners.zig` | 24 tools (12 servers, 3 formatters, 4 linters, 5 runners); `tests/e2e/tools_installer.test` |
| Document highlight, selection range, folding range, executeCommand | done | `lsp.zig` | beyond the Rust list |

## Git

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Gutter signs | done | `marksFor` in `src/app/git.zig` | |
| Branch chip with ahead / behind / counts | done | `SegId.branch` in `src/app/statusline.zig` (`⇡N ⇣N` + the NvChad file counts, the provider glyph); the palette's `⎇` row with `↑n ↓n` in `src/ui/git_palette.zig` | a click opens the status pane, a right-click the branch menu (`dispatch.zig`); `git.tick` discovers on the first tick so the chip shows before any git pane opens |
| Clickable provider badge | done (by spec) | `git.State.provider`; `providerGlyph` / `hostTag` in `src/app/statusline.zig`; `git.browse` / `git.browse_file` / `git.browse_commit` in `cmd_git.zig` | the glyph paints in the branch chip and the PR chip (a click on the PR chip opens it in the browser). *2026-09-09 (leftovers):* Rust has no status-pane badge to click — `provider_icon` is read in one place, `ui/statusline.rs:903` (the branch chip), `ui/git_status_view.rs` never mentions a provider, and the pane's header in `rust-git-status-120x40.txt` is `  on main   2 unstaged · 0 staged`; `git.browse_commit` is not a Rust id at all (Rust's `:GBrowse <commit>` and `git.browse`). The three browse commands have runners here (the commit under the graph cursor / the diff pane's rev) and the branch chip's right-click menu carries the browse rows; adding a badge would put a cell on the status pane the Rust screen does not show |
| Diff pane — Hunk view | done | `src/ui/diff_view.zig`, `openDiff` | |
| Diff pane — Inline view | done | `Mode.flat`, `drawUnified` in `diff_view.zig`, `git.diff_toggle_view` | the whole file, one number column, changed rows tinted |
| Diff pane — Split view | done | `pairs` / `drawSplit` in `diff_view.zig`; the diff toolbar `Hunk   Inline   Split` | removed runs zipped with added runs, a header across both, a `·` filler; `rust-diff-120x40.txt`; `// changed:` the draggable split divider (`App.git_divider`) went with the re-cut to the Rust spec |
| Per-hunk stage / unstage / discard | done | `applyHunk`, `s` `u` `x` in `diffKey` | |
| Line-level stage / unstage / discard with a selection | done (Zig-only) | `DiffPane.anchor`, `selectedLines` / `verbPatch` in `git.zig`; `parse.patchForLineMask` / `patchForLines`; `diff_view.isSelected` | `v` / `V` anchor, shift+↑↓ / `J` `K` grow, a row drag or shift+click, esc drops; the rows paint on the editor's selection ground; `s` `u` `x`, the chips and the row menu act on the selection, else the hunk; `t` cycles the view. `tests/e2e/git_diff_stage_lines.test`, `git_diff_discard_lines.test` |
| Stash these lines / Commit these lines | done (Zig-only) | `client.stashLines` / `commitLines` (a temporary index under `GIT_INDEX_FILE`), `git.diff_stash_lines` / `git.diff_commit_lines`, the diff row menu | the stash is built with `commit-tree` + `stash store` and the lines reversed out of the worktree; the commit is `commit-tree` + `update-ref` with the real index catching up, undoable as a plain commit. `git_diff_stash_lines.test`, `git_diff_commit_lines.test` |
| Conflict resolution in the editor | done (Zig-only) | `src/app/conflicts.zig`, `parse.parseConflicts`, `DiffScope.conflict`, `Job.conflict_text`; the status pane's `⚠ Conflicts (N)` section | the status row opens the editor on the file; each block gets a tinted ground and a header row of chips `Ours · Theirs · Both · Edit · Split · AI resolve`; vim `co` `ct` `cb` / standard `alt+1..3` inside a block, `]x` `[x` / `f8` `shift+f8` between blocks; `Split` is the diff pane on `:2:` against `:3:`; `AI resolve` sends base / ours / theirs through the git AI route and previews the answer through `ai.apply`; a save with no marker left `git add`s the file. `zig-git-conflict-120x40.txt`; `git_conflict_resolve.test`, `git_conflict_commands.test` |
| Intraline highlighting | done | `src/git/intraline.zig`, `rangesFor` in `diff_view.zig` | prefix / suffix peel then LCS, capped at 64 K cells |
| Diff `/`-filter | done | `filterRows` / `filterSplitRows` in `diff_view.zig`, `refilterDiff` in `git.zig`, `git.diff_filter` | hunks holding the needle; `n` / `p` walk the matches |
| Change-density minimap | done | `density` / `drawStrip` in `diff_view.zig` | one cell per band on the right edge, clickable |
| Staging view — lists | done | `src/ui/git_status_view.zig`, `git.status_pane`; `statusFiles` / `statusPaneKey` in `git.zig`; `tests/e2e/git_status_*.test` | Rust's `git_status_view.rs` cell for cell (`rust-git-status-120x40.txt` / `-80x24.txt`): `on <branch>   N unstaged · M staged`, the hint row, `Unstaged changes (N)` / `Staged changes (N)`, `✓ working tree clean`; every hint word is a hit; keys `j k space s u a A ⏎ c C r b B w` *2026-09-12 (git-walk):* `git.status_pane` opens the pane beside the focused leaf — Rust's `open_git_status` split, the leaf's tabs kept on the left — when the active pane has forty cells for each half, else as a tab of it (the pane at 80 columns); `git_status_beside.test` |
| Stage / unstage whole files | done | `git.stage` / `unstage` / `*_all` in `src/app/cmd_git.zig` | |
| Dive into hunks | done | `git.diff_file` | |
| Commit from the IDE | done | `git.commit`; the graph's commit box (`wip_text` / `wip_cursor` on `GraphPane`) | the prompt, or the box pinned to the detail column's bottom — Ctrl+Enter commits, `C` asks for an AI message *2026-09-12 (git-walk):* `git.commit` in git mode opens the active repo's graph with the box focused on the WIP row, from an editor tab or a diff as much as from the graph; a box holding a message commits it (Rust's `commit_from_active_wip_textarea_or_prompt`); outside git mode, or under eighty cells where the graph paints no detail column, the modal prompt titled as Rust's `open_commit_prompt` titles it (`Commit message (N staged)` / `(nothing staged — stage hunks first)`); `git_commit_box.test` |
| Commit graph — coloured lanes | done | `src/ui/git_graph_view.zig` (`layout`), `git.graph` | rewritten to `rust-git-120x40.txt`: Rust's lane walk (rounded corners, a freed lane cools for five rows, `┼` crossings, colour = lane index), Rust's column widths, the `MM/DD HH:MM` date, the git toolbar row above *2026-09-12 (git-walk):* the 11-cell DATE / TIME column (the pane at 120 and 80 columns) painted eleven U+FFFD per row — `rightAlign` hands the formatted text back untouched at that width and the screen keeps the slice past the frame; the date is on the frame arena now, a test reuses the stack and reads the dates back; `git_graph_dates.test` |
| Graph — detail panel | done | `drawDetail` in `git_graph_view.zig`, `requestDetail` / `openDetail` in `git.zig`, `git.graph_detail` | always there at Rust's width (a drag persists `ui.git_graph_detail_col`; none under 80 columns); `git.graph_detail` focuses it, Tab walks its files, Enter opens a file's diff; a commit's `─ sha · author · age ─` rule, the wrapped message, parents and changed files |
| Graph — sortable columns | done | `sortOrder` in `git_graph_view.zig`, `setSort` in `git.zig`, `git.graph_sort` | GRAPH / DATE / AUTHOR / SUBJECT chips; `s` cycles |
| Graph — filters | done | `git.graph_filter_*` | |
| Graph — hash-jump | done | `findByHashPrefix` in `git_graph_view.zig`; `hashFilterKey` in `git.zig`; `git.graph_jump_hash` | *2026-09-09 (leftovers):* `/` arms Rust's header chip — `/<prefix>_` in yellow over COMMIT MESSAGE (before the filter chip), each hex digit jumps to the first commit it prefixes, a miss toasts `no commit ~ <prefix>`, Backspace steps back, Enter keeps the place, Esc clears; `tests/e2e/git_graph_hash_chip.test`. // changed: the empty `/_` paints as soon as `/` is pressed (Rust paints nothing until a digit). The palette's `git.graph_jump_hash` keeps its prompt |
| Graph — WIP row + staging buttons | done | `wipButtonId` / `wipFileId` in `git_graph_view.zig`, `wipFiles` / `syncWip` in `git.zig` | on the WIP row the detail column shows `▾ Unstaged Files (n)` with ` Stage All ` and a ` [+] ` per row, `▾ Staged Files (n)` with ` Unstage All ` / ` [−] `, and the commit box (` Commit  AI Message  Clear `); `s` / `u` on a row, `c` on the WIP row commits the box; a cut button keeps its visible cells as a hit |
| Branch rail | done | the git palette: `src/app/git_palette.zig` (`rows`, the filter, the folds), `src/ui/git_palette.zig`; `requestRail` in `git.zig`, `parseTrack` / `parsePrs` in `src/git/parse.zig`; `git.branch_rail_toggle` enters git mode | WORKTREES / LOCAL (folder-grouped by the first `/`) / REMOTE / PULL REQUESTS as folding sections with counts, the ` repo 󰅀 ` pill, the `⎇` row, Rust's `/` filter; PRs via `gh pr list --json`, a toast when `gh` is missing; STASHES (`git stash list`, newest first, Enter shows the files, the menu applies / pops / drops) and TAGS (`git tag`, newest first, annotated marked) sections since git-more2 — `stashRows` / `tagRows` in `src/app/git_palette.zig`, `rail_stashes` / `rail_tags` from the rail worker (`parseTrack`'s siblings), the test at `git.zig` "the rail carries the worker's data". *2026-09-09 (leftovers):* the `+ N more` branch cap of the Remaining note was Rust's tree-rail GIT section (`BRANCH_LIST_CAP` in `ui/tree_view.rs`), which Rust zeroes with the INTEGRATIONS section (`git_height = 0u16`, 2026-06-30) — the Rust git palette lists every branch, as this one does; nothing to cap |
| Git mode — the section takes the sidebar, one graph tab per repo | done | `src/app/git_palette.zig` (`State.active` / `State.pre`), `activity_bar.enter`, `git.reopen_repo`; `tests/e2e/git_mode.test` | `view.activity_git` / `git.graph` enter: the sidebar snaps to a fifth of the screen, the layout is stashed and replaced by one leaf of `git_graph` tabs (reused when they exist); any other section leaves and the layout comes back, the panes stay in the store; `rust-git-120x40.txt` / `-80x24.txt`; beyond the Rust list as a row, Rust's `open_git_graph` as behaviour *2026-09-12 (git-walk):* `git.graph` shows the ACTIVE repo's graph (the workspace root's unless the panel switched), reopening a tab an `esc` had closed — it used to rebuild the tabs without that repo and land on a foreign one; the rebuild's fallback is the active repo's tab before the first; `git_graph_active_repo.test` |
| Git toolbar above the diff pane and the graph | done | `src/ui/git_toolbar.zig`; `tests/e2e/git_diff_toolbar.test` | Undo · Redo · Pull · Push · Fetch · Branch · Commit · Stash (· Pop while there is one) · Reflog; buttons drop from the right, one always stays; not painted under 40 cells or 6 rows |
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
| AI commit message (claude) | done | `aiCommit` in `cmd_git.zig`, `askAi(.staged, .claude)` / `deliverAiAnswer` in `git.zig`, `askProduct` in `src/app/ai.zig` | the staged diff through the worker; the commit prompt opens prefilled. *2026-09-09 (leftovers):* asked from the graph's WIP row (`C`, the ` AI Message ` button), the answer goes into the commit box instead — `wip_ai` holds the box (` AI writing… `, the placeholder) while the job runs and the message lands as its text, focused, subject and body, Rust's `wip_commit.ai_streaming` + `set_text`; Rust does not stream deltas into the box either (`AiMsg::Delta(_) => continue`), the flag is the streaming |
| AI recompose HEAD | done | `aiRecompose` in `cmd_git.zig`, `askAi(.head, …)`, `Job.amend` | with the commit prompt open it recomposes that message |
| AI commit via Codex | done | `codexCommit` in `cmd_git.zig`, `askAi(.staged, .codex)` | the `codex exec` route; the `api` route is refused with a reason |
| Browse current file on the remote (4 hosts) | done | `src/git/remote.zig` (15 remote shapes tested), `git.browse_file` / `browse_line` | |
| Browse current commit | done | `commitUrl` in `remote.zig`, `git.browse_commit` | the graph's selected commit, a commit diff pane's, else HEAD |
| Cross-host PR picker | cut | `pr.picker` toasts the reason (`cutRunner` in `cmd_app.zig`) | forge integrations are rewritten in Zig after the cutover |
| `pr.refresh` cache | cut | same | |
| File history, merge, rebase, multi-repo | done | `git.file_history` / `merge` / `rebase` / `switch_repo` … | beyond the Rust list |
| Repo accents — a slot on first sight, the pill's Color menu, the gutter on the repo's panes | done | `repoColorName` / `ensureRepoColors` / `setRepoColor` / `openRepoColorMenu` / `repoGutter` in `src/app/git_palette.zig`, `Config.Git.repo_colors`, `src/ui/accent_color.zig`; `tests/e2e/git_palette_repo_color_menu.test` | Zig-authored — the Rust editor's repos carry no colour. Two or more repos: each takes a palette slot in discovery order the first time it is seen, written to the home config's `git.repo_colors` (the first assignment wins across restarts); right-click on the repo pill lists `Color: …` per palette entry with the one in effect ticked and `Color: Auto` last (Auto ticked only once chosen; under All repos the right-click stays the repos menu); the pill's column 0, each All-repos sub-header's gutter, a one-cell `▌` down the left edge of the repo's graph / status / diff panes, their tab glyphs and the tree's repo dot paint it; one repo paints nothing |
| Interactive rebase — the plan on the graph | done | `Plan` / `openPlan` / `runPlan` / `directVerb` in `src/app/git.zig`, `drawPlan` in `src/ui/git_graph_view.zig`, `Job.rebase_plan` in `src/git/client.zig`, `src/git/sequence_editor.zig`; `tests/e2e/git_rebase_plan_*.test` | beyond the Rust list (2026-09-07): space / `v` / `*` select rows, `r` opens the plan oldest-first, `←→` / `p r e s f d` set the action, `J` / `K` move a row, Enter runs `rebase -i` with mnml as the sequence editor (`mnml-zig --rebase-todo`, `--commit-msg`); `git.fixup` / `squash` / `drop` / `reword` are the one-line plans; the graph rows carry the action's letter and colour while the plan is open; undo restores |
| Operation in progress — continue / abort / skip | done | `Status.in_progress` / `progressFrom` in `src/git/parse.zig` (read off the git dir in the status job), `git.op_continue` / `op_abort` / `op_skip`, the toolbar swap in `src/ui/git_toolbar.zig`, the `main \| REBASE 2/5` chip in `src/app/statusline.zig`; `tests/e2e/git_rebase_abort.test` | beyond the Rust list; conflicts are counted (`Status.conflicted`) — resolving them is the diff pane's later work |
| Multi-select on the graph | done | `GraphPane.marks` / `anchor` in `src/app/git.zig`, the `✓` mark cell in `git_graph_view.zig` | beyond the Rust list: space toggles, `v` a range, `*` the branch's commits since its upstream, Esc clears |
| Amend — HEAD with the staged changes, or an older commit | done | `Job.amend_noedit` / `amend_to` in `client.zig`, `git.amend` (`A` on the WIP row) / `git.amend_to` (`A` on a commit) | beyond the Rust list: `commit --amend --no-edit`; `commit --fixup` + `rebase -i --autosquash --autostash` with `true` as the editor; both undoable |
| Reset — soft / mixed / hard to a commit or branch | done | `Job.reset` in `client.zig`, `git.reset_soft` / `_mixed` / `_hard` (the graph row menu, the branches row menu, else a rev prompt), `Confirm.reset_hard` | beyond the Rust list: HEAD and a `stash create` are recorded first, so `git.undo` restores the index and the tree (`Action.reset_hard`) |

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
| Accent bar, scrollbar, wheel / drag scroll | done | `src/ui/list_panel.zig`; `wheel(app, down, rows)` in `todos.zig` / `notes.zig` / `findings.zig` / `sessions.zig`, `dispatch.panelWheel` / `panelScrollbar` / `Drag.bar` | the wheel over the rows, the kebabs and the bar moves the cursor by the budgeted batch clamped to the list cap (Rust `list_scroll_clamp_scaled`: 8 rows at `off`, scaled with the setting); a press on the bar lands the cursor at the pointer's fraction and the drag keeps steering it off the bar; `tests/e2e/wheel_list_panel.test` |
| `⟳` chip right-click menu + auto-refresh | done | `src/app/auto_refresh.zig` (`openRefreshMenu`, `on`, `toggle`, `seed`); the `.refresh` prong of `chipMouse` in `todos.zig` / `notes.zig` / `findings.zig` / `sessions.zig` | *Refresh now* + a ✓ *Auto-refresh* row; off stops TODOS' save / watcher rescan, NOTES' / FINDINGS' path hooks and SESSIONS' cadence; `ui.auto_refresh_off` seeds the set and the toggle persists it to the workspace config; `tests/e2e/refresh_chip_row_menus.test` |
| Sort chip — click cycles, right-click lists | done | `openSortMenu` in `todos.zig` / `notes.zig` / `findings.zig` / `sessions.zig` | every list panel |
| Narrow-panel icon-only chip | done | the ladder in `src/ui/header.zig` | full + count → icon + count → full → icon; tested at 26 / 30 / 34 / 40 / 50 |
| Four sort modes persisted for the three panels | done | `todos.sort` / `notes.sort` / `findings.sort` | each persists `ui.<panel>_sort` |
| SESSIONS sort axis | done | `sortCmd` / `sort_auto` / `sort_manual` in `src/sessions.zig` | State / Manual; `J` / `K` build the manual order, persisted in `session.zon` |
| Row context menus (NOTES / FINDINGS / SEARCH / AGENTS) | done | `openRowMenu` in `notes.zig` / `findings.zig` / `sessions.zig` / `src/app/search_section.zig` / `src/app/grep.zig` / `src/app/agents.zig` | SEARCH section: titled by the hit's `path:line` or the file — open, open to the side, copy path:line / line, search again, open as pane (`search.*`, six Zig-only ids); the grep pane: open, skip / include the hit, copy, include / skip every hit, replace in files, expand / collapse all, search again (`grep.*`, eight Zig-only ids); AGENTS: transcript, resume, copy id / cwd, export, kill, refresh |
| `:messages` bell + history | done | `src/app/messages.zig` | Zig-only here; also under UI & theming |

## AI

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Claude CLI / Codex as panes | done | `src/app/ai.zig` → `src/app/pty_pane.zig` | |
| The Claude grid — `ai_layout_mode = .grid` | done | `src/app/ai_grid.zig` (the rule), `Layout.findLeafPairSplit` / `findPureCluster` / `buildGrid` / `fillFirstEmpty` in `src/app/layout.zig`, `drawAiPlaceholder` in `src/app/render.zig`; `tests/e2e/ai_grid_2x2.test` | by the count of Claude panes on the page: 0–1 a split right; 2 → a 2×2 with the third bottom-left and an `.empty` slot bottom-right (the `+ Add Claude Code` card; a click opens the next one there); 3 / 5 / 7 fill the slot; 4 → 3×2, 6 → 4×2, each with a slot; every step needs a pure cluster of those sessions (`Rust find_pure_pane_cluster`) else the plain split; the splits share equally. Codex: a split right, or a tab in tabs mode, as Rust. *Departure:* Rust counts Claudes across every page for the rule; here the page's own count, so a second page grids again |
| `ui.auto_show_sessions_on_ai_activate` | done | `showSessionsSection` in `src/app/ai.zig` | every session open — the chip, `ai.claude_code_new` and its placed variants, Codex, the batch — shows SESSIONS in its column first, the keys with the pane; off leaves the column alone (walkthrough finding 8: the key was read by nothing) |
| The eight-per-page cap | done | `ai_grid.cap`, `cmd_tab.tabNewEmpty` | at eight Claude panes on the page the next one opens a fresh, empty page and continues there; the batch toasts `opened N Claude sessions across M screens`. *Departure:* Rust caps only the batch (`open_claude_code_new_batch`) and lets a single open past eight fall to the plain split; here the chip click spills too — the cap is the rule the user set |
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
| Opt-in via the first-launch wizard | done | `src/app/first_launch.zig` (the AI ghost-text section), `src/app/first_launch_install.zig` (the Claude Code + Codex section's Space: the vendors' `curl … \| sh` installers — `irm \| iex` on Windows — for whichever is missing, in an `install: ai clis` pane; the rows re-detect on its exit and the wizard returns with them) | the rows are Rust's badge rows; a line says the top-right chip appears when the CLI is found; `tests/e2e/first_launch_ai_cli_install.test` |
| Opt-in via `ai.setup_suggestions` | done | `ai.zig` | |
| Opt-in via Settings → AI | done | `Section.ai` in `src/app/settings.zig` — ghost text, ghost-text backend (a virtual row over `ai.extra` + the setup picker's override), Claude / Codex backend (`ai.routing.*.backend`, optional enums: `unset` first), Claude meter | the model stays `ai.model` in the config — free text, and v1 rows are discrete choices (the family idiom); `tests/e2e/settings_ai_section.test` |
| Secret-bearing files never sent | done | `isSecretBearing` in `suggest.zig` | |
| Context-aware chat | done | `chatCmd` in `ai.zig` | |
| Launch profiles | done | `src/app/launch_profiles.zig`, `Config.Ai.launch_profiles` / `default_profile` | the chip menu's *New session:* / *Default:* lanes; the `mnml-ai-<name>` shim (`writeShim`); both keys are exec-bearing (`Sink.launch_profile`), as Rust's `pty_pane.rs` refused an untrusted workspace's launcher |
| AI chip click — a live session, no confirm | done | the `.ai_claude` / `.ai_codex` button arm in `src/app/dispatch.zig` → `ai.claude_code` | a plain click on the row-1 AI chip spawns the CLI at once, as Rust's does by design; there is no `ui.confirm_ai_launch` key on either side (checked 2026-09-10), so a headless hunt that clicks it starts a real `claude` in the workspace — drive `ai.*` by command there |
| AI chips when the CLI is found | done (Zig-only rule) | `aiChips` / `aiChipShown` in `src/app/render.zig`, `cliOnPath` (a PATH walk cached ten seconds on `App.cli_probe`) in `first_launch_install.zig` | Rust reads the icon's `enabled` only (`bufferline.rs`), so a fresh install shows no chip until the integrations pane toggles it; here an enabled icon shows under any key but `.none`, and a CLI found on PATH shows its chip when `ui.tab_bar_ai_icon` names it (the default `.claude_code` shows a found `claude`; `.both` a found `codex` too); `view.tab_bar_ai_*` and `view.cluster_mode_*` set and persist their key |
| `ui.ai_chip_use_mnml_glyphs` | done | the field's doc in `Config.zig`; `aiChips` paints U+F1E00 / U+F1E01 on both arms | deprecated as Rust's `theme.rs` has it (both arms resolve to the baked pair); accepted so a 0.2.x config loads |
| Legacy "Set launcher script…" | done | the last row of the AI chip menu (`legacy_label` / `openProfilePicker` in `src/app/launch_profiles.zig`) | opens the launch-profile picker (Enter starts a session) and toasts that launcher scripts are profiles now |
| Sessions table (was the Agents dashboard), spend report | done | `src/app/sessions_table.zig`, `src/ui/sessions_table_view.zig`, `src/app/spend.zig`; `sessions.table` / `ai.dashboard` | one row model (`sessions.Item`) behind the SESSIONS cards and the table: grouped by cwd, this workspace first; state / where / text filters; ended past a day hidden until the `ended:` chip; space ticks, K kills the batch; the summary block |
| Claude usage pane (`ai.claude_usage`) — session / weekly / per-model windows per account, the reset clocks, the 429 countdown, the guided re-auth | done | `src/ai/usage.zig` (the reader: `GET /api/oauth/usage` as Rust's `ai_usage.rs` — the token file per `.ai.claude_accounts`, the refresh grant on a rejected token, the keychain fallback, `/api/oauth/profile` for the identity, the pins), `src/app/usage_pane.zig` (`Pane.ai_usage`, the cadence, the keys), `src/ui/usage_view.zig`; `tests/e2e/usage_pane_fixture.test`, `zig-usage-120x40.txt` / `-80x24` | Rust's layout (`claude_usage_view.rs`): the header hints, the green gutter and `(active)` pill, the bars, `Resets 6:50pm` / `Sep 19 at 5am`; `r` refresh, `L` opens `claude login` in a pty, `R` files the keychain login under the account pinned to its email (refused with the reason otherwise), `j`/`k`/`g`/`G`/PageUp/PageDown, `q`/Esc. Opens as a tab (Rust's `reveal_pane`). Not painted: the `✎` rename affordance — `ai.claude_rename_account` is not in this build. `MNML_CLAUDE_USAGE_FIXTURE=<dir>` replaces the wire (the tests, the spec dumps) |
| Codex usage pane (`ai.codex_usage`) — tokens today, sessions today, the scan time | done | `fetchCodexLive` in `src/ai/usage.zig`, the `.codex` arm of `src/ui/usage_view.zig`; `zig-usage-codex-120x40.txt` | Rust's spare layout (`codex_usage_view.rs`); the walk under `~/.codex/sessions` is recursive (the CLI nests `YYYY/MM/DD/`; Rust lists the directory flat and finds nothing there) |
| The Claude quota chip and the Codex tokens chip, one reader | done | `claudeChip` / `codexChip` in `src/app/usage_pane.zig`, the chip arms in `src/app/statusline.zig`, `singleChip` / `compactChip` / `tickerIndex` in `src/ai/usage.zig` | the same per-account snapshots the pane shows — nothing else in the app holds a percentage: ` 󱸀 24% 3h 62% 4d` (the `ai.chip_show_*` detail, the reset countdown, a `!` when the last fetch failed, `—` before the first reading), the compact sparkline with the `→P` urgency arrow or `⟳3h`, the ticker (4 s an account, its letter first) under `claude_meter_mode`; a click opens the pane. Rust's refresh cadence (5 min active, 1 min from 90 %, 20 min idle, one spawn a tick, 20 s apart, the backoff); Rust's `[ai] claude_meter_mode = session|weekly|both` / `claude_show_reset` stay runtime-only here (`ai.chip_show_*`, `ai.chip_toggle_reset`) — the config's `claude_meter_mode` is the multi-account mode (`docs/CONFIG.md`). Neither side's SESSIONS rows show a quota |
| Cloud runs as SESSIONS rows | done | `src/app/cloud_agents.zig`, `Item.where` / `CloudInfo` in `src/sessions.zig` | scanned when `[cloud_agents]` is configured; Open run / Tail log / Cancel run… and the CloudWatch / PR links on the row menu; the two wizards under `+ New session` |
| `waiting` / `done` / `failed` states, the edge toast, the bell | done | `AgentState` in `src/app/agents.zig`, `stateEdges` / `announceEdges` in `src/sessions.zig`, `ui.session_bell` | a dangling tool use gone quiet is `waiting`: first in both views, one warn toast per edge, the pty tab badged, the bell under the config; `failed` off the transcript's last error |
| Done-but-dirty signal | done | `agents.dirtyScan`, the `dirty` column and the summary's `dirty, ended` | one `git status --porcelain` per distinct cwd on the refresh cadence |
| AGENTS / CLOUD AGENTS rail rows folded into SESSIONS | done | `Section.rail` in `src/ui/activity_bar.zig`; `view.activity_agents` / `view.activity_cloud_agents` as aliases | scripts naming the rows keep passing |
| SESSIONS section — the cards are this app's AI panes, EXTERNAL below | done | `Card` / `refilter` / `cardView` / `derive` / `drawFooter` in `src/sessions.zig`; `PtyPane.sessionId` / `fed_gen` / `exited_at_ms`, `--session-id` in `launch_profiles.launch`; `tests/e2e/sessions_cards.test` | Rust's `sessions_panel.rs` rule (2026-09-12, the user's "we didn't do the left panel correctly"): a card is a pane running `claude` / `codex` (`is_ai_session_pane`), not a scan row — row 1 the alias, else the child's window title with the spinner stripped, else the label; rows 2–4 `exited` in red once the child is gone, else at rest the scan's exchange for the pane's session id as `you:` / `claude:` (120 chars), else the grid's last content lines (no chrome, footer chips, prompt, `Worked for`), else `—`; the lines follow the pane (a fresh session reads its banner, a thinking one its live rows); sorted by `session_state_priority` (approval prompt, thinking, idle, exited; pins lead; Manual as before) off one grid walk per pane cached by output generation, the priority re-read every 500 ms; the transcript comes off the scan's snapshot on its 3 s cadence, so a frame opens no file; a new session starts under mnml's own `--session-id` so the pane owns its transcript from the first frame (the session file spells it `--resume`); EXTERNAL lists at most four live unowned rows of the workspace as `<branch>  (<short id>)`; hover on a card: the name, `⎇ branch`, `⌂ cwd`, a blank, the lines; Enter focuses the pane; the row commands act on the scan's row for the pane, or a stand-in that refuses the transcript verbs; `w` scopes EXTERNAL / ENDED to every workspace; the `.test` corpus drives it with a fake `claude` on PATH |
| SESSIONS history chip — ended sessions hidden, an ENDED group, a grace window | done (Zig-authored) | `ChipKind.history`, `toggleEndedCmd` / `clearEndedCmd` / `openHistoryMenu` in `src/sessions.zig`, `ui.session_ended_grace_min`, `session.zon` `sessions_show_ended`; `tests/e2e/sessions_ended_chip.test` | the user's ask (2026-09-12: "hide the completed or exited ones behind an icon like a history icon"): an exited pane past the grace window (10 min by default) and the scan's ended transcripts of the workspace hide behind a `󰋚 N` header chip (`H N` in ASCII; the count gives way to it before the sort chip does) — `E` / a click lists them greyed under `ENDED` at the bottom (`<name>  (<short id>)`) and lights the chip; right-click: Show ended / Hide ended / Clear ended (the scan's ended rows forgotten until the next launch, the exited panes closed); one that ended inside the window stays put — a card, or an ENDED row — so its toast and worktree offer are not lost; the toggle rides in the session file; the table keeps its own `ended:` chip |

## Terminal & process panes

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Pty — shell | done | `src/app/cmd_term.zig`, `src/app/pty_pane.zig`, `src/pty/` | |
| Terminal-normal mode (vim profile) | done (Zig-only) | `PtyPane.term_normal`, `escapeKey` / `termNormalKey` in `pty_pane.zig`, `ptyKey` in `dispatch.zig` | `<C-\><C-n>` (`:help CTRL-\_CTRL-N`) or NvChad's `<C-x>` leaves the child for the app's keys — the leader, the `Ctrl-W` family — and `i` / `a` return; the mode chip reads TERMINAL / T-NORMAL |
| Pty — claude / Codex | done | `ai.zig` | |
| Pty — any task / command | done | `termEx` (`:term <cmd>`), `src/app/tasks.zig` | |
| Multi-session tab strip | done | `Tab.kind` in `src/ui/bufferline.zig` | pty tabs marked in the strip |
| Session worktrees — a session in a git worktree of its own | done (Zig-authored) | `src/app/session_worktree.zig` (`validName`, `rootFor`, `create` / `merge` / `remove`, `openNamePrompt` / `acceptName`, `confirmMerge` / `confirmRemove`), `Registry` on `sessions.State.worktrees`, `worktreeOf` / `announceWorktreeEnded` in `src/sessions.zig`, `sessionAccent` in `src/app/git_palette.zig`, `Config.LaunchProfile.worktree`, `Config.Ai.default_worktree_root`; `tests/e2e/sessions_worktree_launch_merge.test` | Zig-authored — the Rust editor has no such thing. Opt-in and off by default: *New session in a worktree…* on the AI chip's right-click (the default profile), the SESSIONS rail `+` menu, the `+` tab menu's AI rows, `+ New session` (section, table, the table's group row) and `ai.new_session_worktree`; a profile with `.worktree = true` always goes this way. The prompt is seeded `session-<n>` / `<profile>-<n>` (the first free directory) and validated as a branch name; `git worktree add -b <name> <repo>-worktrees/<name> HEAD` (`ai.default_worktree_root` overrides the root: `~` expands, a relative path sits under the repo), refused with the reason when the directory or the branch exists; the session's cwd is the tree, `MNML_WORKSPACE` names it, the tab reads `claude @ <name>`. The registry (`session.zon` `sessions_worktrees`) pairs the tree with its session by path, then by the id the scan lists; the card paints ` ⑂ <name>` after the label, the table row a muted one (`wt:<name>` in ASCII); the row menu offers *Open worktree in tree* (an extra workspace root, the repo switched to), *Merge into <branch>…* (`--no-ff`; refused while the main tree has uncommitted changes; a failed merge opens the command log) and *Remove worktree…* (`worktree remove` + `branch -d`; an unmerged branch asks once more with Force); the git panel's WORKTREES row paints the session's `▌` and carries the same two verbs; a session whose row goes ended with its tree still there toasts once — `session <name> ended — its worktree <wt> has N commits: merge / remove / keep (row menu)`. Every git child of these verbs runs synchronously and lands in the command log |
| Session accents — a slot per new Claude pane, the Color menu | done | `assignAutoAccent` / `accentOf` in `src/app/pty_pane.zig`, `setColorAction` in `src/sessions.zig`, `src/ui/accent_color.zig`; `tests/e2e/sessions_second_claude_color.test` | Rust's `session_color.rs` palette in its order (the auto-cycle order is the menu order); a new Claude pane takes the next slot, a shell none; the pty pane's one-cell `▌` identity strip, its tab glyph, the SESSIONS card's `▌` and the table row's first cell paint it; right-click on the card, the table row, the pty tab or the pane body → `Color: …` with the current ticked, `Color: Auto` last; overrides persist by session id (`session.zon` `sessions_colors`) and on the saved pane, and a resumed session opens in its colour |
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
| Request pane — form edit | done | `src/app/request_pane.zig`, `src/ui/request_view.zig` | the response strip's chips (` — ▼ `, ` copy `, ` wrap `, ` ⚡ AI `) never paint over its labels: on a strip too narrow for both they drop from the left of their row inward, Rust's `fit_row` rule (2026-09-10; `tests/e2e/http_response_strip_narrow.test`) |
| Re-send / copy-as-curl / write-back | done | `http.send` / `copy_curl` / `save` | |
| Tabbed Edit view | done | `EditTab` in `request_view.zig` (six tabs) | |
| Request pane — browsed vs edited | done | `RequestPane.editing`, `browseKey` in `src/app/request_pane.zig`; `PromptPurpose.ex_line` + `dispatch.openExLine` | a pane opened from a file is browsed (2026-09-10): `r` / `R` fire, `:` opens an ex-line prompt (Rust's `no_pane_cmdline`), the arrows and Home / End walk the field, every other key goes to the chord chain; Enter or a click on a text field edits it, Esc leaves it; a blank pane and a Tab back from the response start editing (Rust's `toggle_view` lands the caret on the URL); the caret paints only while editing; both profiles; `tests/e2e/http_request_pane_keys.test` |
| `Ctrl+]` / `Ctrl+[`, `Ctrl+1..5` | done | `request_pane.zig` | |
| Side-by-side edit split | done | `RequestPane.split*`, `drawTabContent` in `request_view.zig`, `http.toggle_edit_split` | the divider drags; `⇔` chip; `http.toggle_split_orientation` cycles auto / vertical / horizontal |
| `{{VAR}}` inline highlight | done | `paintVarsOnField` / `paintVarsOnLine` in `request_view.zig`, the `editor_view` hook | `syntax.variable` when resolved, `error_fg` when not |
| `{{VAR}}` click → definition | done | `jumpToVarDef` in `src/app/http.zig`, `lineOfKey` in `env.zig` | lands on the `KEY=` line; a toast when undefined |
| `{{VAR}}` right-click quick-fix | done | `openQuickFixMenu` in `http.zig`, `http.quick_fix` | Define in env… / Jump to definition / Pick env… / Inline value / Copy variable name |
| `{{VAR}}` hover | done | `drawVarTip` in `request_view.zig`, `drawEditorVarTip` in `http.zig` | masked for `# @secret` and credential-shaped names |
| `-k` / `# @insecure` honoured | done | `src/http/insecure.zig`, `Transport` in `src/http/client.zig` | a loopback TLS shim skips the chain check (std has no switch); the name is checked with SNI, retried without on a mismatch; a failure reads `tls (insecure): …` |
| Per-request timeout / redirects / proxy | done | `parse.options` / `setDirective`, `client.Transport`, the Auth tab's Options rows in `request_view.zig` | `# @timeout 5s`, `# @no-redirect` / `@follow-redirects`, `# @max-redirects 3`, `# @proxy host:port`; curl `--max-time` / `--max-redirs` / `-L` / `-x` round-trip; `.http` config defaults |
| Response search | done | `cmd_find.Target`, `RequestPane.resp_find`, `overlayMatches` in `request_view.zig` | `/` (vim) or Ctrl+F over the body, or the Headers tab; `n` / `N`, F3; the count in the bar |
| `{{` completion | done | `VarCompletion` in `src/app/http.zig`, `ui/completion_view.zig` | env names, `$` built-ins, `@capture` names, each with its value dimmed; `http.complete_var` |
| Dynamic vars `{{$uuid}}` etc. | done | `env.zig` | |
| HTTP activity-bar panel (7 sections) | done | `src/app/http_panel.zig`, `PanelId.http` | COLLECTIONS / ENVS / CHAINS / MOCKS / COOKIES / RECENT / CAPTURED. *2026-09-10 (mouse-fixes):* one left press on a request or block row opens it, as a tree file does (Rust; the second press it once waited for is gone); `tests/e2e/http_row_single_click.test` |
| HTTP panel `/` filter | done | `rebuild` in `http_panel.zig` | one filter across every section; honest header counts |
| Blank request `http.new` | done | `openBlank` in `src/app/http.zig` | |
| Green `+` chip in the INTEGRATIONS rail | done | `new_chip` in `src/ui/header.zig` (`chip.newStyle`, `ChipKind.new`), set by `draw` in `src/app/http_panel.zig`; `chipMouse` runs `http.new` | a green ` + ` before the HTTP panel's ⟳; a click opens the blank request pane; `tests/e2e/http_plus_chip.test` |
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
| Lua `http_request` / `http_response` hooks, `mnml.http.set_var` / `send` | done | `HttpRequestArgs` / `HttpResponseArgs` / `HttpRewrite` in `src/core/hooks.zig`; `beforeSend` / `emitResponseHook` / `responseHookArgs` in `cmd_http.zig`; the `mnml.http` block of `src/scripting/api.zig` | beyond the Rust list — `docs/research/http-vs-posting.md` §3 row 1. The order is directives → `{{VAR}}` expansion → `http_request` (a returned table rewrites the wire) and cookies → schema → `@assert` / `@capture` → `http_response`; a body past 1 MB reaches the hook cut with `body_truncated`; the Timeline tab lists the headers as sent; `docs/LUA.md`, `tests/e2e/lua_http_hooks.test` |
| Headers tab as a key / value table with name + value completion | done | `headersKey` / `Completion` / `headerRows` in `request_pane.zig`; `headerNameCandidates` / `headerValueCandidates` / `headerScan` in `http.zig`; `src/http/header_table.zig`; the `.headers` prong of `drawEdit` + `drawTip` in `request_view.zig` | beyond the Rust list — §3 row 2 with §4-A: the last response's headers seed both columns (`ETag` → `If-None-Match` with the tag's value), the workspace's `.http` files next (frequency-ranked), the bundled ~70-name table with a description each last; the popup is `ui/completion_view.zig`; `?` / hover describe a row; `tests/e2e/http/http-headers-*.test` |
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

The one deliberate departure from same-look: the Rust debug pane was
never driven by anyone, so the Zig screens are the spec
(`docs/ui-spec/zig-debug-*.txt`, cut by `tools/zig-spec.sh`), and every
row below is tested against `mnml-fake-dap` rather than a hand-written
reply. Nine `dap_session_*.test` and ten `debug_*.test` scripts.

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Launch | done | `src/dap/client.zig`, `src/app/dap.zig`, `dap.run` (palette) / `dap.continue` (`F5`, starts a session when there is none) | `$NAME` / `${NAME}` in an adapter's `cmd` or an argument expands from the environment; `dap.run` re-reads the config's `.dap` table when the file has no adapter yet (trusted workspaces only) |
| Attach | done | `dap.attach` | |
| Breakpoints — toggle / list / clear | done | `dap.toggle_breakpoint` (`F9` / `<leader>db`), `dap.list_breakpoints`, `dap.clear_all_breakpoints`; `types.Breakpoint` in `src/dap/types.zig` | `enabled` / `log_message` / `verified` per breakpoint; the reply's `verified` lands per file |
| Conditional breakpoints | done | `dap.toggle_breakpoint_conditional` (`Shift+F9` / `<leader>dB`) | |
| Hit-count breakpoints | done | `dap.set_breakpoint_hit_count` | `>= 5`, `% 10`, … |
| Logpoints, enable / disable, all on / off | done | `dap.set_breakpoint_log_message` (`<leader>dl`), `dap.toggle_breakpoint_enabled`, `dap.remove_breakpoint`, `dap.enable_all_breakpoints` / `disable_all_breakpoints` | beyond the Rust list; the `dap.*breakpoint*` prompts act on the DEBUG section's selected row when it has the keys, else the cursor line (`bpTarget`) |
| Gutter breakpoints — glyphs, click, right-click editing | done | `HitTarget.gutter` in `src/ui/hit.zig`, the `.gutter` prong in `dispatch.zig` → `dap.gutterToggle`, `openGutterMenu` in `context_menus.zig`; `tests/e2e/debug_panel_breakpoint_toggle.test` | `●` plain, `◐` conditional / hit-counted, `◆` logpoint, `○` disabled, unverified muted; a right press opens the Breakpoint menu (condition, hit count, log message, enable, remove). *2026-09-10 (mouse-fixes):* a left press anywhere in the margin — the line number as much as the sign cell — toggles on a file an adapter answers to or that carries breakpoints (`dap.gutterToggles`, the config re-read on a miss as `dap.run` does); on any other file the press is the line-numbers click (the row above); `tests/e2e/gutter_click_breakpoint.test` |
| Exception-breakpoints picker | done | `dap.exceptions` | the adapter's filters, listed under BREAKPOINTS too |
| Step controls | done | `src/app/cmd_dap.zig` | VS Code's F-keys for the standard profile (2026-09-10): `F5` continue / start, `Shift+F5` stop, `Ctrl+Shift+F5` restart, `F10` / `F11` / `Shift+F11` step — pinned by `cmd_dap.zig`'s doors test; `<leader>do` / `di` / `dO` / `dc`; `dap.pause` (`<leader>dp`), `dap.terminate` (`<leader>dt`); `dap.continue` starts a session when there is none (nvim-dap); `dap.restart` (`<leader>dR`) starts the last file again |
| Step toolbar + the strip over the editor | done | `src/ui/debug_toolbar.zig`; the strip in `render.zig` behind `ui.debug_toolbar` (auto / always / hidden); `tests/e2e/debug_toolbar_click.test` | Start / Continue / Pause · Step over · Step into · Step out · Restart · Stop as ` icon label ` chips (nf-md glyphs, `--ascii` twins); labels drop first, then buttons from the right; the first row of `Pane.debug`, and a strip over the active editor while a session is live |
| DEBUG sidebar section — VARIABLES / WATCH / CALL STACK / BREAKPOINTS | done | `src/app/debug_panel.zig`, `src/ui/debug_panel.zig` (`PanelId.debug`, `Section.debug`); `view.activity_debug` (`Ctrl+Shift+D`), `dap.toggle_panel` (`<leader>du`), `dap.show`; `tests/e2e/debug_panel_stop.test` | one `ListPanel(Row)` list: a status row (`● prog.dbg:4 · main`), four foldable headers with counts, every row a hit with a right-click menu of command ids; the `dap.*_selected` family (`toggle_section`, `toggle_selected`, `edit_selected`, `remove_selected`, `open_selected`, `watch_selected`, `copy_value`, `edit_watch`) so a key, a menu row and the palette share one runner; a value that changed since the last resume paints in the warning colour; the section has a side like the rest (`tests/e2e/debug_panel_moved_right.test`) |
| Call stack | done | the CALL STACK section (threads, then the current thread's frames); `dap.open_selected`, `dap.pick_thread` | a chosen frame sets `Session.frame_id`; evaluations and scopes follow it; Enter jumps to the frame's line |
| Variables tree | done | `variableRows` in `src/dap/client.zig`, the VARIABLES section | scopes as trees; a struct expands; `dap.copy_value` |
| Set-variable | done | `dap.set_variable`, `dap.edit_selected`; `tests/e2e/debug_panel_set_variable.test` | |
| Watch expressions | done | `dap.add_watch` (`<leader>dw`) / `remove_watch` / `clear_watches` / `watch_selected` / `edit_watch`, the WATCH section; `tests/e2e/debug_panel_watch.test` | watches survive the session; `(no value)` without one |
| Debug Console (the REPL) | done | `src/ui/dap_view.zig`, `dap.State.console` in `src/app/dap.zig`, `dap.repl` (`<leader>dr`), `dap.clear_console` (Ctrl+L); `tests/e2e/debug_console_eval.test` | VS Code's shape: the program's output, `> expr` echoes, results (a composite folds on click), errors and `── started / exited ──` notes in one scrollback kept across sessions; an input row with ↑↓ history and Tab completion of variable / watch names; `// changed:` `Pane.dap_repl` and `ui/dap_repl_view.zig` are gone — `Pane.debug` is the toolbar over the console |
| Inline values | done | `dap.inlineValuesFor` in `src/app/dap.zig`, merged with the LSP virtual text in `render.zig`; `editor.inline_values`; `tests/e2e/debug_inline_values.test` | `  name = value` after every line up to the stop that names a scope variable; beyond the Rust list |
| Hover values, `K` evaluates | done | `dap.hoverValue` (the tooltip on a cell, from the fetched scopes), `dap.evaluate_hover` (`<leader>dh`; `lsp.hover` / vim `K` evaluates the word through the adapter first while stopped, into the hover box); `tests/e2e/debug_vim_k_hover.test` | beyond the Rust list |
| The stopped line | done | `Doc.stopped_line` in `src/ui/editor_view.zig`, the ▶ in the gutter | the line wears the band; the stop jumps to the file and focuses the editor |
| Reverse debugging | done | `dap.step_back` / `reverse_continue` | the runners exist; the fake adapter advertises no step-back |
| nvim-dap chords + VS Code F-keys | done | `.vim` / `.both` keys in `specs.zig`, pinned by the `both key profiles` test in `cmd_dap.zig`; `docs/KEYMAP_PROFILES.md` → Debugger | `<leader>d b B l c o i O p R t r w u h`; the F-keys are `both`, so a vim user keeps them; no `dap.*` chord is standard-only |
| Settings rows | done | `editor.inline_values` (Settings → Editor “Inline debugger values”), `ui.debug_toolbar` (Settings → UI “Debug toolbar strip”) in `src/app/settings.zig` | |
| The fake adapter — `mnml-fake-dap` | done | `tools/fake_dap/{main,program}.zig` + `README.md`, installed by `zig build`; `MNML_FAKE_DAP` exported by `mnml-zig test` (`src/main.zig`) and the runner (`src/e2e/runner.zig`); the client's integration test in `src/app/dap.zig` spawns it | a deterministic DAP server over stdio that runs a tiny line-oriented language (breakpoints with conditions and hit counts, stepping, `call` frames, structs, exceptions, output, `sleep` / `pause`); a script writes `.dap.dbg.cmd = "$MNML_FAKE_DAP"` and a `prog.dbg`; the same works outside the corpus; beyond the Rust list |
| netcoredbg, built in — `dotnet.debug` builds first | done | `builtin_adapters` / `builtinAdapterFor` / `resolveAdapter`, `dotnetDebug` / `pollPendingLaunch` in `src/app/dap.zig`; `dotnet.launchBody`; `tests/e2e/dotnet_debug_build_*.test`; `docs/CONFIG.md` → `.dap` | `.cs` → `netcoredbg --interpreter=vscode` with `{ program: <csproj dir>/bin/Debug/<TargetFramework>/<AssemblyName>.dll, cwd }` from the nearest csproj, after `.dap.cs` and the config re-read; `dotnet.debug` runs `dotnet build` in a task pane and launches on exit 0; netcoredbg's `initialized` arrives before its `initialize` reply, so the reply now sends the default exception filter (`user-unhandled`); beyond the Rust list |
| The Zig-authored spec | done | `docs/ui-spec/zig-debug-{stopped,console,breakpoints}-120x40.txt`, `zig-debug-stopped-80x24.txt` (`tools/zig-spec.sh`); `tools/debug-demo.sh [vim|standard]` opens the same seed on a real screen | the dumps are the spec; nothing on the Rust side to diff against |

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
| Runs via `mnml-zig test` | done | `testSubcommand` in `src/main.zig` | `--gate`, `--sizes`, `--filter`, the directives; exports `MNML_FAKE_DAP`; a `# requires: network` file is skipped (`http/http-bench-running-toast.test`), so 394 `.test` files read 393/393 |
| Runs under the unit-test harness | done | the `── e2e ──` blocks in `build.zig` | `zig build test` runs the unit suite (1205 tests: 1203 pass, 2 skip) then the gate; `zig build check` runs fmt, both optimize modes, the gate, the width sweep, `defaults.test` and the full corpus; `zig build e2e` the corpus alone |
| `tools/ui-diff.sh` — the Rust screen as the spec | done | `tools/ui-diff.sh WS RS_DATA ZIG_DATA [STEPS] [COLSxROWS]`, `docs/ui-spec/` (`rust-*.txt` dumps, one `steps-*.jsonl` per screen, the README) | both binaries headless on one workspace and config, a row-by-row diff; the session is snapshotted around each run; every chrome track is measured with it — Zig-only |
| `tools/zig-spec.sh` — a Zig-only screen as its own spec | done | `tools/zig-spec.sh NAME [COLSxROWS] [OUT_DIR]` | headless on a throwaway workspace wired to the fake adapter, one steps file in, the screen kept as `docs/ui-spec/zig-<name>-<size>.txt`; Zig-only |
| `tools/debug-demo.sh` | done | `tools/debug-demo.sh [vim\|standard]` | the debugger on a real screen — the same seed as `zig-spec.sh`, the workspace deleted when mnml-zig exits; Zig-only |
| `tools/break-check.sh` | done | `tools/break-check.sh <test> <file> <sed-expr>` | proves a unit test can fail on a scratch copy; exit 2 when the break did not land (a `zig fmt` reflow), 3 when the broken copy does not compile, 4 when no test matched; Zig-only |
| `tools/pty-mouse-check.py` | done | `tools/pty-mouse-check.py [BIN] [WORKSPACE]` | the real binary in a pty answering the probes like ghostty: cell coordinates asked for (mode 1006, never 1016), one click opens a file, a right-click opens the row menu, a wheel notch reaches the app; Zig-only |
| .NET runners — `dotnet.build` / `run` / `test` / `restore` / `watch`, the `test.*` arm | done | `runDotnet` in `src/app/runners.zig`, `src/app/dotnet.zig` (`find`, `Project.buildRoot` / `runRoot`, `testAt`, `filterArg`); `tests/e2e/dotnet_runner_*.test`, `dotnet_test_at_cursor_filter.test` | the nearest `*.csproj` and `*.sln` at or above the file: the solution builds / tests / restores, the project runs / watches; `test.run_at_cursor` is `--filter "FullyQualifiedName~Class.Method"` from the grammar's outline (the line patterns without a tree), `run_file` the file's classes; the missing-manifest toast names the id like the others; `dotnet` in `known_tools`; beyond the Rust list |
| `dotnet test` in the results pane | done | `Runner.dotnet`, `parseDotnet`, `parseTrx`, `locateSources`, `failedFilter` in `src/app/tests_pane.zig`; `tools/shims/dotnet`; `tests/e2e/dotnet_test_results_pane.test` | the console logger's lines are the rows, the TRX fills in durations and the class; a failure's file:line from its first frame, a passed row found in the project's `.cs`; the tool's own tally under the glyph tally; `R` re-runs the failures as `--filter FullyQualifiedName=…`; the worker resolves the tool on the App's PATH (`runners.pathOf`); beyond the Rust list |
| `zig build gate-build -Dtarget=…` | done | `build.zig` | the exe and every test binary compiled for a foreign target without running — the Windows / Linux gate; Zig-only |

## UI & theming

| feature | status | Zig file(s) | note |
|---|---|---|---|
| File-tree rail | done | `src/app/tree.zig`, `src/ui/tree_view.zig`, `src/ui/icons.zig` | Rust's `tree_view.rs` cell for cell (columns 4–29 of `rust-120x40.txt`): the ` ▾ ~/path/ ` header with its chips, neo-tree connectors (mnml's baked U+F1F04 / U+F1F05), nvim-web-devicons, git badges right-aligned; the standard profile's arrow-preview (`Tree.previewCursor`); the info view (`src/ui/info_view.zig`) in the panel's bottom rows |
| Activity bar — the icon rail | done | `src/ui/activity_bar.zig`, `src/app/activity_bar.zig`, `ui.activity_bar` (always / auto / hidden), `view.activity_bar_cycle`, `openRailMenu` / `openGearMenu` in `context_menus.zig` | Rust's twelve sections, order and codepoints, the `▌` mark, the gear; the marked section is read off the surfaces; a click runs the section's `view.activity_*`; badges on Rust's pulse; the pinned launcher icons follow the sections (`Part.pin`, `Layout.pinY` — the Headless section's row) |
| Bufferline | done | `src/ui/bufferline.zig` | |
| Powerline statusline | done | `src/ui/statusline.zig` (the two lanes, the arrows at every colour hand-off), `src/app/statusline.zig` (the chips in Rust's order) | left: mode · host segments · branch · PR · file · diagnostics · symbol · macro · find; right: host segments · tests · Claude · Codex · coverage · transfer · LSP · RESTRICTED · WRAP · autosave · size · Ln/Col · Sel · stress · bell · clock · workspace · language; the row is pinned against `rust-120x40.txt` / `rust-80x24.txt` |
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
| Right side panel — toggle, `Ctrl+Shift+B` | done | `view.toggle_right_panel` → `src/app/side.zig` | `// changed:` Rust's sidebar + tabbed right panel are one idea — every section has a side, the frame has two columns and each shows one section; the toggle opens the right column on the last section shown there, else the first whose side is right |
| Sections have a side — move left / right | done | `src/app/side.zig` (`State`, `place` / `remove`, `move`, `ctrlWCommand`), `view.move_section_left` / `_right`, `:sidebar left\|right` in `ex.zig`, vim `Ctrl-W H` / `L` in a section or the tree, which-key `s H` / `s L`, the rail menu's *Move to right / left side* (`MenuAction.move_section`); `ui.sidebar_side`, `ui.section_side`; `session.zon` `sides`; `tests/e2e/section_move_{command,rail_rightclick,vim_ctrl_w,ex_sidebar}.test` | TODOS / NOTES / FINDINGS start on the left, the outline and the diagnostics on the right (Rust's placement); a section that opens a pane (search, agents) has no side; a left-column section reads `TREE` in the mode chip, the right column `PANEL`; beyond the Rust list |
| Right panel — drag grip | done | `right_divider_id` / `FrameRects.right_divider` in `render.zig`, `dispatch.zig` | Rust's 21-column clamp |
| Right panel — persisted visible + width | done | `ui.right_panel_visible` read in `initWith` (`src/app.zig`), `ui.right_panel_width` in `side.State.init` (floored at 8), number rows in `settings.zig` | the default width is Rust's 32 (the section-side track put it back from 40; the panels' chrome at 26–32 cells is the panel track's); a session restore still overrides |
| `:set rightpanel` / `rightpanel!` / `norightpanel` | done | `src/app/ex.zig` | |
| Right-panel icon in the palette bar | done | the nav cluster in `src/ui/menu_bar.zig` (`Button.toggle_tree` / `toggle_right_panel`) | codicon layout-sidebar-left-off / -right-off either side of the workspace chip, cell for cell with row 0 of `rust-120x40.txt` |
| `<leader>tr` | done | the `t` group in `whichkey.zig` | `view.toggle_right_panel`; `t ]` / `t [` / `t x` step and close the panel's tabs |
| Outline / diagnostics hosted in the panel | done | `Section.outline` / `Section.diagnostics` (a side and a column, no rail row), `outline.drawPanel` / `lsp.drawPanel` | right by default (Rust's `right_panel_panes`); the column carries Rust's strip row — the title and a `×` |
| `×` evicts the hosted pane | done | `view.right_panel_close_tab` (`ctrl+alt+w`), `Button.right_close` on the column's strip row (`render.zig`) | closes the right column |
| Empty-state copy | done | `src/ui/empty_state.zig` | |
| Right-panel next / prev tab | done | `view.right_panel_next_tab` / `prev_tab` in `src/app/side.zig` | walk the sections whose side is right; the keys stay where they are (Rust's panel) |
| Keyboard right-click `Shift+F10` | done | `contextMenuAtFocus` in `context_menus.zig`, `view.context_menu_at_focus` | tree row / panel row / active tab, anchored at the thing's rect |
| Palette bar — sidebar + panel toggles + palette chip | done | `drawPaletteBar` in `render.zig` over `src/ui/menu_bar.zig` (`rust_row_120` / `rust_row_80` pin row 0) | the centred 48-cell nav cluster — sidebar toggle · ` ← ` ` → ` · the workspace chip `  󰍉  <name>  ` · ` ▾ ` · right-panel toggle — then Rust's right cluster from `bufferline.zig` (` + `, ` TABS `, a chip per tab page, the theme pill, the ` × ` that quits; `ui.top_bar_cluster_mode`) |
| Menu bar — the ten menus | done | `src/app/menu_bar.zig`, `src/ui/menu_bar.zig`, `ui.menu_bar` (always / auto / hidden), `view.menu_bar_open` / `menu_bar_cycle`; `tests/e2e/menu_bar_top_row.test` | ` ❯_  mnml ` then File / Edit / Selection / View / Go / Run / Terminal / Window / Help; every row a registered command (an enum) with its chord under the active profile and Rust's glyph; F10 opens File, Alt+letter a menu, ← / → step; words that do not fit collapse behind ` » ` |
| Palette bar — integration chips | done | `chips` in `src/app/integrations.zig`, `drawGapChips` in `render.zig` (`integrations.chipClick`) | the enabled icons on Rust's 5-cell stride in the gap between the sidebar toggle and the cluster (the browser globe by default), in `ui.integration_icon_order`; an installed manifest's chip joins them (`allChips` / `chips`), and a chip's right click offers Add / Remove from activity bar and Hide from / Show on top bar. *2026-09-10 (mouse-fixes):* the globe's `browser.open` opens the pane at about:blank with no prompt (Rust's rail-chip default; `browser.open_url` keeps the prompt) — a missing Chrome toasts the pane's diag |
| Palette bar — `+` add-integration | done (by spec) | `integrations.show_marketplace` from the `+` menu's Integrations submenu (`context_menus.zig`) and `M` in the integrations pane | *2026-09-09 (leftovers), verified against the dump:* `rust-120x40.txt` row 0 ends `󰐕  ●━  󰅖` — the `󰐕` is Rust's `bufferline_new_tab_button` (`ui/bufferline.rs:774`, "`+` new-tab button"), `●━` the theme-toggle pill (`:920`), `󰅖` the close; no green `+` is in the row, and row 1's `󰐕` is the empty strip's `+` (`bufferline_empty_plus`, `:483`) whose menu has the Integrations submenu. Not painted, by the spec |
| Palette bar — narrow drops TABS | done | the hidden-word rule in `src/ui/menu_bar.zig` (`rust_row_80`), `pickCluster` in `bufferline.zig` | Rust's rule: a 50-cell cluster estimate bounds the menu words, a 3-cell slot is kept for the ` » ` while words remain; at 80 columns only the brand menu fits, the gap chip drops and the right cluster is the compact one (`rust-80x24.txt`); the chip alone below 48 columns |
| Menu glyphs | done | `src/ui/menu_glyph.zig`, `paintMenuRows` in `render.zig` | one glyph per command group; `MenuItem.icon` overrides |
| `ascii_icons` blanks glyphs | done | `forItem(it, ascii)` in `menu_glyph.zig` | every group glyph has a one-character ASCII twin |
| `menu.glyph_audit` | done | `menuAuditCmd` in `src/app/glyph_audit.zig` | the menu glyph table (group · codepoint · catalog name · ASCII twin · one-codepoint check) then the source audit, in a scratch pane; needs the workspace's `data/nerd-glyphnames.json` (the mnml-zig tree) |
| Submenus | done | `MenuState.sub`, `openSubmenu` in `context_menus.zig`, `overlayKey` in `dispatch.zig` | → / l / Enter / click open, ← / h step back |
| Curated five-section `+` menu | done | `plus_sections` / `openNewTabMenu` in `context_menus.zig` | New / Open / Panels / Tools / Integrations, pinned rows first |
| Per-row kebab pin / hide / copy id | done | `openCuration` in `context_menus.zig`, `menu.pin_row` / `unpin_row` / `hide_row` / `copy_id` | ⋯ on the focused leaf row, or → on it |
| `plus_menu_pinned` / `hidden` | done | `App.plus_pinned` / `plus_hidden`, `persistPlus` in `context_menus.zig` | written back to the home config |
| `ui.external_browser` | done | `src/app/browser_open.zig` (`argv`), used by `git.openExternal` and `lsp_decor.openExternal` | `open -a <name>` / `start "" <name>` / `<name> <url>`; the trust layer strips the key from an untrusted workspace before it is read |
| 94 themes | done | `themes/*.zon`, `src/ui/theme.zig`, `theme.pick` | committed ZON, parsed at comptime |
| Help overlay — F1 keymap reference | done | `view.help` (`f1`), `src/ui/help_overlay.zig`, `src/app/help.zig` | Rust's `build_help`: the mode chips, the stress meter, then every command group with the chords the active keymap binds; `/` filters, `c` / `e` fold and open every section; `rust-help-120x40.txt` |
| Click-discovery panel | done | `Overlay.discovery`, `discovery.Category` / `App.discovery_flash` in `src/app/discovery.zig`, `view.discovery` (unbound, as in Rust) | eleven rows with the frame's hit counts; a row press flashes that family for two seconds; F1 / Esc / a press elsewhere close; `rust-discovery-120x40.txt`; `// changed:` the old label-every-hit overlay is gone |
| Hover tooltips on chips | done | `describe` in `discovery.zig`, `src/ui/tooltip.zig` | `ui.hover_tooltip` popup and the `ui.hover_help` rail box; wake on motion only |
| Right-click menus throughout | done | `src/app/context_menus.zig` — editor / tab / tree / mode / `+` / request / todos / stress / branch / diagnostics / bell / toast | |
| Context menus taller than the screen scroll | done | `MenuState.scroll` / `SubMenu.scroll` / `MenuFollow` in `src/app.zig`, `menuWindow` / `paintMenuRows` in `src/app/render.zig`, `menuWheel` in `dispatch.zig`; `tests/e2e/wheel_context_menu.test` | Rust 1ef21198: the window is clamped to the list and pulled after a key's cursor or, after the wheel, the cursor after it; the bottom border's last cell says `↑` / `↓` / `↕`; a row's hit names its item, not its screen row; a menu that fits is untouched |
| Wheel acceleration — `[editor] scroll_accel` | done | `Accel` / `ceiling` / `listStep` in `src/app/scroll.zig`, `dispatch.wheelLines`; `docs/research/scroll-tuning.md` | Rust's `budgeted_scroll_at` with its arithmetic kept: the multiplier ramps on the wheel's rate, a 250 ms gap is a new gesture, a decaying wheel is never amplified, the sub-line remainder carries, a 40 × ceiling bucket refilled at 60/s, at least one line an event; a unit test pins the line counts per setting for the same event runs; `tools/compare.sh compare-mouse` reads the same top line as Rust after 1 / 3 / 10 / 30 notches |
| `[editor] wheel_moves_cursor` — auto / always / never | done | `App.cursorFollowsWheel`, the editor arm of `wheelOnPane` and `dragScrollbar` in `dispatch.zig`; `tests/e2e/mouse_wheel_moves_cursor.test` | the wheel and the editor's scrollbar drag agree: `always` moves the cursor (the view follows), `never` moves the view and pins it until the cursor moves, `auto` is the input style |
| Wheel coalescing + the click after a flick | done | `Coalescer` in `src/app/scroll.zig`, `App.handle` / `flushWheel` | a tick's burst is one batch (cap 40); a turn the other way starts the next batch after the flush; a click flushes the batch first; a batch after a batch routes against the frame's hit map without a render |
| Editor scrollbar — Rust's styled cells | done | `scrollbar.Look.solid`, `drawVerticalLook` in `src/ui/scrollbar.zig`; the bar in `editor_view.zig` | *2026-09-10 (mouse-fixes):* the editor's bar is a styled space per cell (track on the chip ground, thumb on the muted one — Rust's `editor_view.rs` bg2 / comment), so a dump shows the blank column Rust's does; the panels keep `█` in two colours (Rust's `paint_simple_scrollbar`, which also paints `█` for both since 2026-07-08); ASCII keeps `\|` / `#` |
| Every scrollbar drags and its track jumps | done | the `.scrollbar` prong, `paneBarJump`, `barDrag`, `scrollbarTrackOf` in `dispatch.zig`, `Drag.bar` | the editor's thumb keeps its grab row and follows `wheel_moves_cursor`; the panels, the tree, the picker, the help box and the outline / markdown / ZON / git-status / grep panes land at the pointer's fraction of the track and keep steering off the bar until the release |
| Tree wheel — one row per notch | done | `treeWheel` in `dispatch.zig`, `Accel.treeRows` | with accel off a batch inside 60 ms of the last step is the same notch (ghostty reports a detent as three events); with it on the rows come from the factor, accumulated (2.5 alternates 2 and 3) |
| Pty wheel — pass-through vs scrollback | done | the `.pane` prong for a pty in `dispatch.zig`; the wheel test in `src/app/pty_pane.zig`, `tests/e2e/wheel_pty_pane.test` | a child tracking the mouse gets every event of a batch as its report, unbudgeted; one that does not scrolls the scrollback a line per event |
| Welcome pane (no pane open) | done | `src/ui/welcome.zig`, the `// ── welcome ──` block in `src/app/render.zig` | logo · workspace · branch · Recent Files · Shortcuts · version; rows 10–28 of `docs/ui-spec/rust-120x40.txt` match |
| First-launch welcome | done | `src/app/first_launch.zig`, `src/ui/wizard.zig`, `src/app/first_launch_install.zig` | seven sections; Space installs — the Nerd Font once "boxes" is answered (`brew install --cask font-symbols-only-nerd-font` / the NerdFontsSymbolsOnly zip into `~/.local/share/fonts` + `fc-cache -f` / PowerShell into the per-user font dir with an HKCU registration; a toast at nerdfonts.com elsewhere), the AI CLIs, the `code` shim (`sudo ln -sf` of the VS Code bundle's `code` into `/usr/local/bin`, macOS) — in an `install: …` pane; the wizard closes for it keeping its answers and returns on the pane's exit; the terminal hint (ghostty / iTerm2 / Terminal.app / WezTerm / Windows Terminal, off `TERM_PROGRAM`) toasts on exit 0 only; `docs/ui-spec/zig-wizard-120x40.txt`; `first_launch_nerd_font_install.test`. Not carried: Rust's Keyboard-section Space (the ghostty `macos-option-as-alt` auto-fix) — the probes tick, no fix is written |
| About & Settings overlays | done | `view.about` / `view.welcome`, `src/app/settings.zig` | Help → Welcome (Alt+H, Enter) opens the welcome overlay — an overlay, so `status.json`'s pane list never changes; `tests/e2e/menu_help_welcome.test` (2026-09-10) |
| Markdown live preview | done | `src/app/md_preview.zig`, `src/ui/md_view.zig` | |
| Inline images in the preview | done | `Placement` / `renderWith` in `md_view.zig`, `ui.md_image_rows` | a standalone `![alt](src)` reserves rows; text fallback headless |
| `render_markdown` inline in the editor | done | the `// ── ui toggles ──` block in `editor_view.zig`, `view.toggle_render_markdown` | marks concealed off the cursor line |
| `markdown_opens_rendered` | done | `src/app.zig` `openPath` | |
| Preview tabs — markdown | done | `MdPreviewPane.is_preview`, `PaneStore.findMdGlance`, the in-place swap in `md_preview.open` | a `.here` open (a click, a jump, the session) is a glance the next glance replaces, like the image viewer; `markdown.preview` on an editor is permanent; `tests/e2e/md_preview_glance.test` |
| Preview tabs — `.http` / `.curl` | done | `findPreview` in `src/app/http.zig` | |
| Preview tabs — images | done | `src/app/image_pane.zig` (`open` replaces the preview tab in place), `PaneStore.findImagePreview`, `Pane.image`, `view.image_open` | |
| Typing makes a preview permanent | done | `edited` in `request_pane.zig` (request panes); `swapToEditor` in `md_preview.zig` (a markdown preview becomes the raw editor, which is never a preview) | the rule as Rust's: a request preview is promoted by an edit; typing on a markdown preview swaps the editor in; editor and image tabs carry no promotion — pinned by the `preview tabs:` test in `md_preview.zig` |
| Image rendering (kitty / iTerm2) | done | `src/image/{root,kitty,iterm2,sixel,painter}.zig`, the attach in `tui/loop.zig` | kitty by probe, iTerm2 by `TERM_PROGRAM`, sixel for foot / mlterm; `MNML_IMAGE_PROTOCOL` overrides |
| Now-playing transport chip | done | `src/app/now_playing.zig` (`ui.now_playing_source`, `ui.preferred_music_app`, `ui.now_playing_marquee`; `MNML_NOW_PLAYING` override); `tests/e2e/statusline_now_playing.test` | the poller runs only under the terminal loop; headless paints the idle pair as Rust does |
| Source-aware dispatch (mixr / AppleScript) | cut | same | |
| Idle `♪` chip, `preferred_music_app` | cut | same; config keys accepted and ignored | |
| Mixr panel size chips | cut | same | |
| Stress meter — statusline bar | done | `src/app/stress.zig`, `render.zig` | p95 of a 120-sample ring |
| Stress meter — bufferline copy | done (by spec) | the statusline meter, its tooltip and its menu | *2026-09-09 (leftovers), verified against the dump:* `rust-120x40.txt` row 0 shows no meter, and `ui/bufferline.rs:894` says why — the top-right mirror was added and removed on 2026-07-12 ("the statusline meter is enough"), `palette_stress_chip = None`, "paint nothing". Not painted, by the spec |
| Stress meter — hover numbers | done | `describeSegment(.stress)` in `discovery.zig` | p50 / p95 / max / n in the tooltip |
| Stress meter — right-click Reset / Copy / Toast | done | `openStressMenu` in `context_menus.zig`, `perf.copy_stress` | |
| Stress meter — hidden when idle, 120 samples | done | `stress.zig` | |
| Click-to-dismiss toasts | done | `src/ui/toast.zig`, `dispatch.zig` | |
| Toast right-click menu | done | `openToastMenu` in `context_menus.zig`, `toast.dismiss_clicked` / `copy_clicked` | *2026-09-14 (walkthrough-chrome):* the stack keeps five transient toasts and Esc clears them (`App.dismissTransientToasts`, before any overlay sees the key); a long text wraps to four rows (`ui/toast.zig` `wrap`, Rust clips at one); the stack paints beneath the overlays; the 0.2-manifests notice carries *Don't show again* |
| Undo chip beside the stack | done | `App.armUndo` / `takeUndo`, `drawUndo` in `src/ui/toast.zig` | armed by `buffer.close_others` / `close_right` |
| `:messages` picker | done | `messages.show` in `src/app/messages.zig` | |
| `:messages!` dump | done | `dump` in `messages.zig`, `:messages!` in `ex.zig` | |
| Persists per workspace | done | `session.zig` `messages` | |
| Bell chip — three states | done | `SegId.bell` in `src/app/statusline.zig` | always there; the colour carries the level — idle, yellow count, red count; the clock beside it |
| Zen mode | done | `src/app/zen.zig` (`view.fullscreen`) | full screen; the way out is toasted going in (a restored session too) — `Esc Esc` from any pane (`zen.escKey`, one site ahead of every pane in `dispatch.keyInner`; a terminal still gets the first Esc), the corner mark at the body's top-right (`Button.fullscreen_exit`), `Ctrl+K Z` / `:fullscreen` / `:zen`, "Exit full screen" at the end of the editor and tab menus; the View menu row and the palette title read Enter / Exit (`zen.title`) |
| Leaf zoom | done | `view.toggle_zoom` → `App.zoomed_leaf`, the single-leaf paint in `render.drawBody` | `space z z`, the maximize button's menu; the split tree underneath is untouched; closing the pane clears it |
| Reset view | done | `view.reset_layout` in `zen.zig`, `:resetview`, the View menu's last row, `space t 0` | leaves full screen and the zoom, the tree on its side at `ui.tree_width`, a hidden menu / activity bar back (persisted), every split equalized, the panes kept |
| Clickable statusline | done | `SegId` in `src/app/statusline.zig`, `Seg.hit` in `src/ui/statusline.zig`, `.statusline_seg` in `dispatch.zig` | mode / position / file / language / branch / PR / diagnostics / symbol / macro / find / tests / Claude / Codex / coverage / transfer / LSP / WRAP / autosave / size / bell / stress / clock / workspace; host segments above `seg_dyn_base`; `// changed:` the indent, encoding and input-style chips are gone — the Rust row has none, the mode chip cycles the keymap |
| Clock | done | `src/app/clock.zig` (`SegId.clock`, `clock.local` / `utc` / `hide` / `menu`) | `HH:MM` local beside the bell, `HH:MMZ` for UTC, a frame on every minute; `ui.clock` seeds and follows (`clock.hide` persists it); `// changed:` local time is libc `localtime_r` — Windows shows UTC; UTC is a session choice, the config has no zone key; `tests/e2e/palette_bar_clock.test` |
| Settings overlay | done | `src/app/settings.zig` (`rows`), `src/ui/settings.zig` | 61 discrete rows + 9 number rows (`‹ [32] ›`) — 70, with the activity bar, the debug toolbar strip, the default sidebar side and the inline debugger values among them |
| `:set` for every discrete field | done | `src/app/ex.zig` | Zig-only |
| The `ui.*` toggles | done | read: relative numbers, whitespace, rainbow brackets, trailing-ws, word highlight, hover help / tooltip, workspace dots, todo keywords, breadcrumb, cluster mode, tab-bar AI icon, AI layout mode (`render.zig`, `tooltip.zig`, `todos.zig`) | `auto_refresh_off` (`auto_refresh.zig`), `clock` (`clock.zig`), `click_echo` (a 120 ms double underline under a left press — `App.click_echo`, `Doc.echo`), `coverage_chip_mode` (`coverage.zig`: the `F` / `C` chip from the two `trends.json` files, four modes), `menu_bar` (`menu_bar.zig`: the ten menus on the bar row — always / auto / hidden, `view.menu_bar_cycle` / `menu_bar_open`), `activity_bar` (`activity_bar.zig`, the same three words), `debug_toolbar` (`render.zig`: the strip over the editor), `sidebar_side` / `section_side` (`side.zig`), `auto_equalize_splits` (`App.afterSplitChange`); each has a test that changes a cell |
| Update check | done | `src/app/update.zig` | GitHub releases JSON on a worker; `ui.check_updates`, `MNML_NO_UPDATE_CHECK` |
| Startup picker | done | `src/app/startup_picker.zig` | |

## Workspace trust

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Exec-bearing keys gated before use | done | `src/config/trust.zig` (`exec_bearing`, `strip`, `claims`) | 11 sinks, `init.lua` among them |
| AI launch profiles gated | done | the `launch_profile` sink in `src/config/trust.zig`: `ai.launch_profiles[]` (a whole-replace list in a layer) and `ai.default_profile` stripped from an untrusted layer, each profile's binary + args a claim | Rust's `launcher_from_an_untrusted_workspace_is_ignored` (`pty_pane.rs`) as a Zig test in `launch_profiles.zig`: an untrusted workspace naming a profile binary is not spawnable by name and the default stays the built-in |
| `.mnml/integrations/*` manifests gated | done | the `workspace_manifests` sink in `src/config/trust.zig` (`Facts.manifests` via `manifestNames`, one claim per file); the scan gate in `integrations.refresh`; `reloadConfig` re-scans on the grant | quiet like every other stripped sink; the dialog lists `integration <name> — runs .mnml/integrations/<name>.zon` |
| Quiet by default | done | `promptIfNeeded` in `src/app/trust.zig` | |
| Dialog shows the commands, "Don't trust" focused | done | `src/app/trust.zig`, `Claim.format` | |
| Untrusted is restricted, not broken | done | `strip` / `stripSink` | |
| `RESTRICTED` statusline chip | done | `Info.restricted` / `seg_restricted` in `src/ui/statusline.zig` | a click runs `workspace.review_trust`. *2026-09-14:* also up while the workspace has a 0.2 `.mnml/config.toml` and no `.zon` (`App.workspace_toml`) — the whole file is unread; the hover and the click say so |
| Fingerprinted trust, re-asks on change | done | `fingerprint` in `config/trust.zig` | |
| Decisions outside the workspace, keyed by canonical path | done | `src/config/trusted.zig` (`trusted_workspaces.zon`) | TOML → ZON is the declared cut |
| `workspace.review_trust` | done | `src/app/workspace_trust.zig` (`reviewTrust`, `forget` → `trusted.forget`) | untrusted: the first dialog again; trusted: the claims re-read with Keep / Forget |
| Trust-keyed workspace config round-trip | done | `src/config/load.zig` | |

## Headless, IPC & extensibility

| feature | status | Zig file(s) | note |
|---|---|---|---|
| `--headless`, same App + draw path | done | `src/headless.zig`, `src/app/driver.zig` | |
| File IPC `command` / `screen.txt` / `status.json` / `events.jsonl` | done | `src/ipc/channel.zig`, `src/ipc/screen.zig` | + `rects.json`: every registered hit, the open overlay's rows named after it (`picker:N`, `palette:N`, `settings:N`, `prompt:N`… — `App.overlayLabel`, 2026-09-10) rather than the generic `overlay_item:N` |
| IPC command vocabulary | done | `src/ipc/command.zig` | |
| Plugins register commands over IPC | done | `register_command`, `DynRegistry` in `src/core/command.zig` | owners: `integration` / `script` / `ipc` |
| Registered commands in the palette | done | `cmd_picker.zig` walks `dyn_commands` | |
| Registered commands as keybindings | done | `keymap.bindNow`, `Target.named` | |
| Invocation reported back | done | `ackPluginCommand`, `drainPluginEvents` | |
| Tier-2 toasts / sticky / progress / notify | done | `src/ipc/effects.zig` | `notify` is a toast plus `osascript` / `notify-send` / PowerShell in the terminal loop |
| Tier-2 statusline segment / open-pty / activity badge | done | `effects.zig`, `Info.dyn_*` in `statusline.zig`; the golden pair in `src/ipc/golden/tier2.*.jsonl` | every field; priority pack; `click_command`; badges for every Rust section |
| `:term <binary>` | done | `termEx` in `cmd_term.zig` | |
| The Rust integration binaries | cut | — | rewritten in Zig on bridge v2 (E5) |
| Manifest-declared dynamic commands | done | `src/app/integrations.zig` (the scan of `<data root>/integrations/*.zon` and `<ws>/.mnml/integrations/*.zon`), `src/bridge/manifest.zig` (the SDK's schema), `owner = .integration` in `DynRegistry` | each command opens a `Pane.mount` or a pty, or runs the manifest's `run` / `ex` line through `launchers.fire` (its `{{tokens}}` expanded) |
| Launchers — a manifest without a binary | done | `sdk/mnml-sdk/src/manifest.zig` (`binary` optional, `Command.run`, `Chip.glyph_codepoint`, `validate` — the rule both readers run), `src/app/launchers.zig` (`fire`, `installFile`), `launchers/{btop,htop,iftop,vscode}.zon` + `launchers/README.md` | Rust's `binary = None` launchers: every command a `run` line; a `term <prog>` whose program is not on PATH toasts `<prog> is not on PATH — brew install <prog>`; the Dev tab lists an SDK checkout's `launchers/` (Install copies the file), a `local_folder` that is the repo's `launchers/` lists `✓ Official`; `tests/e2e/launchers_marketplace_local.test`, `launchers_fire.test` |
| Launcher template tokens | done | `src/app/launcher_template.zig` (`expand`, `contextOf`), applied in `command.runDyn` for every manifest line | `{{workspace}}` `{{workspace_name}}` `{{current_file}}` `{{current_file_abs}}` `{{current_file_dir}}` `{{cursor_line}}` `{{cursor_col}}` `{{selection}}`; an unknown token stays literal; a test per token |
| Pinned activity-bar icons (`ui.activity_bar_pinned_integrations`) | done | `Pin` / `Part.pin` / `Layout.pinY` in `src/ui/activity_bar.zig`; `props` / `mouse` / `describeIn` in `src/app/activity_bar.zig`; `pinnedChips` / `pinClick` / `openPinMenu` / `setPinned` and `integrations.pin_to_activity_bar` / `unpin_from_activity_bar` / `toggle_palette_bar` in `integrations.zig` | the chip's glyph in its colour after the sections; a click fires the chip's command, the right click its menu (Enable / Disable, Hide from top bar / Show on top bar, Remove from activity bar, Copy id); "Add to activity bar" on the row's and the chip's menus; persisted home through `settings.persist`; `docs/ui-spec/zig-launchers-120x40.txt`; `tests/e2e/launchers_pin_click.test` |
| `launcher.add_local` | done | `addLocalCmd` / `addLocalAccept` in `launchers.zig` (`PromptPurpose.launcher_add_local`) | a prompt for a `.zon` path (`~`, workspace-relative), parsed before it is written; the picker of Rust's chip builder is not ported — a launcher is a file |
| `integrations.refresh` | done | `refreshCmd` in `integrations.zig` | |
| `.ui.integration_icons` config | done | read by `chips` in `integrations.zig` | |
| Launcher-icon strip | done | `drawGapChips` in `render.zig` over `integrations.chips` | the enabled config icons and installed manifests' chips (`in_palette_bar`) in the bar's gap on Rust's stride |
| Integration-icon rail | done (by spec) | the palette-bar chips (`in_palette_bar`, `src/app/integrations.zig` `barChips`) and the activity-bar pins (`ui.activity_bar_pinned_integrations`, `src/app/activity_bar.zig`, the launchers track) | *2026-09-09 (leftovers):* the Rust tree paints no integration icons — `ui/tree_view.rs` hard-codes `integration_height = 0u16` (the 2026-06-30 note: the INTEGRATIONS and GIT tree sections were zeroed when both got activity-bar panels), so `draw_integration_section` returns at its first line and `IntegrationIcon` has no `in_tree_rail` field to read. The icons Rust does place — the palette bar's chips and the rail's pinned launcher slots — are here, painted, clicked and menued |
| `+` add-integration → Marketplace | done (by spec) | `integrations.show_marketplace` from the `+` menu's Integrations submenu and the integrations pane's `M` | the bar chip is not painted: Rust's row-0 `󰐕` is the new-tab button and row 1's is the empty strip's `+` menu (the UI section's row has the line numbers) |
| Marketplace | done | `src/app/marketplace.zig`, `Pane.marketplace`, `src/ui/marketplace_view.zig`, `marketplace.*` | `github_launcher_folder` and `github_monorepo_apps` sources; a `crates_keyword` source lists nothing |
| `integrations.toggle_enabled`, `<leader>iE` | done | `toggleEnabled` in `integrations.zig` (a picker); the `i` group in `whichkey.zig` | `i d` details, `i h` / `i I` / `i r` the tool panes |
| `integrations.edit` / `remove` / kebab | done | `editCmd` / `removeCmd` / `openRowMenu` in `integrations.zig` | |
| Installed / Marketplace / In-Dev tabs | done — *2026-09-14:* `*.toml` manifests (0.2's) are counted, never read: one toast per launch, the Installed empty state's line, `integrations.dismiss_toml_notice` | `Tab` in `src/ui/integrations_view.zig`, `showTab` / `scanDev` in `integrations.zig`, `integrations.show_installed` / `show_marketplace` / `show_in_dev` / `toggle_tab` / `toggle_dev_tab` | the Dev tab scans `integrations.dev_roots` and an SDK checkout's own `integrations/` and `launchers/`; Build / Install / Rebuild + reinstall from the row; `tests/e2e/integrations_sample_dev_install.test` |
| `integrations.icon_picker` | done | `src/app/icon_picker.zig`; `PickerKind.icon_glyphs`; `tests/e2e/icon_picker.test` | *2026-09-09 (leftovers):* every glyph of the embedded `data/nerd-glyphnames.json` (the glyph audit's catalog) as Rust's `open_icon_picker` rows them — `<glyph>  <human name>  [<category>]  U+<HEX>` with `nf-<name>  \u{<HEX>}` and ghostty's routed font (`→ MnmlSymbols`) as the detail; the ranker matches the detail too and a typed codepoint pins its row. Enter copies the glyph alone (Rust's accept copies a three-part line — the config's `.glyph` field wants the glyph), the toast gives the escape; Ctrl+C on the cursor's row and the right-click menu (Copy glyph / Copy codepoint / Copy name) cover the rest. Rust's hand-curated seed section and its grid renderer are not reproduced: one list, one ranker |
| Glyph baking / audit tooling | done | `tools/glyph_audit.zig` (`zig build glyph-audit`), and the same logic in-process — the tool is an import of the app — behind `integrations.audit_glyphs` / `bake_ai_glyphs` / `bake_all_glyphs` / `bake_integration_glyphs` in `src/app/glyph_audit.zig` | the audit lands in a scratch pane with a toast; the three `bake_*` ids do the one bake this build has (the catalog → `<data root>/nerd-glyphs.tsv`) — Rust baked SVGs into a font, which is cut; `tests/e2e/glyph_audit.test`; the catalog is embedded (`data/root.zig`), so the audit works in any workspace |
| Installed Nerd Font scan | done | `src/app/font_scan.zig`: the seek-based sfnt name-table reader (name ID 5's `Nerd Fonts X.Y.Z`, ID 16 / 1 for the family, `ttcf` / `OTTO`), the platform font dirs, `MNML_FONT_DIRS` | families grouped as Rust groups them (`X Nerd Font [Mono\|Propo]`, ` NF` / ` NFM` / ` NFP`, the NL marker); the scan runs on the `startup` hook |
| FONTS section on the Marketplace tab | done | `src/ui/fonts_section.zig`, `.fonts` in `integrations_view.SectionProps`; `docs/ui-spec/zig-fonts-120x40.txt` | ` FONTS · latest Nerd Fonts <v>`, one row per family, the tick / yellow / muted version rule; hidden while a filter is typed or once scrolled, as Rust hides it; the rows are not list rows |
| `↑ Update` chip | done | `font_scan.updateCommand` (the cask rule, macOS), `HitTarget.font_update`, `ConfirmPurpose.font_update` | painted only when behind and a command is known; the box runs the cask line in a pty pane below (the tools installer's path) or copies it |
| Latest Nerd Fonts release, cached 24 h | done | `font_scan.fetchLatest` on the state's `Io.Group`, the `.fonts` event; `<data root>/cache/nerdfonts-latest.json`; `MNML_NERDFONTS_LATEST` | fetched only when a family is installed to compare; `MNML_MARKETPLACE_API` stubs it in the tests |
| ghostty `font-codepoint-map` | done | `src/app/ghostty_config.zig` | the last rule wins; comma-separated ranges; `$XDG_CONFIG_HOME`, `~/.config`, the macOS app-support folder; `config-file` includes are not followed (Rust did not either) |
| Startup tofu check + toast | done | `glyph_audit.tofuCheck` / `onStartup`; the check leads `integrations.audit_glyphs`'s pane | Rust's three verdicts over the config icons, the manifests' chips and the four core mnml-block glyphs; silent when clean; mnml-block refs stand down while no MnmlSymbols face is installed |
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
| `zig build check` (E7 gates) | done | `build.zig`, `tools/break-check.sh`, `tests/e2e/defaults.test` | fmt → Debug tests → ReleaseSafe tests → the gate → the width sweep → `defaults.test` → the full corpus; Zig-only |
| Session file `.mnml/session.zon` | done | `src/app/session.zig` | ZON, never JSON |
| Lua scripting — `.mnml/init.lua`, the `mnml` table | done | `src/scripting/lua.zig`, `src/scripting/api.zig`, `script.reload` / `script.edit_init`, the `init_lua` trust sink | beyond the Rust list (D10); a 20 ms budget per entry |
| Lua decorations + the diagnostics sink — `mnml.decor.*`, `mnml.diagnostics.*` | done | `src/app/script_decor.zig`, the `mnml.decor` / `mnml.diagnostics` blocks of `src/scripting/api.zig`, `applyLuaDiagnostics` in `src/app/lsp.zig`, `LineGround` / `VirtualLine.below` / `GutterMark.priority` in `src/ui/editor_view.zig` | Zig-authored — the Rust editor has no script decorations. Four decorations in a namespace the script owns (virtual text at `eol` / `above` / `below`, a gutter sign with a priority, a role over a byte range, a whole-row ground), anchored to bytes that follow every edit; a namespace goes with `script.reload`. The sink is a fourth source on the per-file diagnostics keyed by `(namespace, path)`, so the gutter, the squiggle, the statusline count, the DIAGNOSTICS panel and `]d` show a script's findings under its own `source`. `docs/LUA.md`; `tests/e2e/lua_decor.test`, `lua_diagnostics_sink.test` |
| Lua live picker source + preview column + multi-select | done | `live` / `preview` / `multi` / `on_accept` in the `mnml.picker` block of `src/scripting/api.zig`, `PreviewRow` / `placeWith` / `drawPreview` / `Outcome.toggle` in `src/ui/picker.zig`, `toggleMark` / `tick` in `src/app/cmd_picker.zig` | Zig-authored — the Rust picker has no preview column and no live source. `items(query)` is asked again as the query changes, debounced 80 ms, and the previous call's rows stay until the new ones land; `preview(row)` fills a right-hand column (results left, a `│` rule, the box widened to 120) decoded when the cursor moves, never in the paint loop; `Tab` marks a row and steps on, Enter hands `on_accept` the list. Rows gain `icon` and `data` — the row table itself comes back. `docs/LUA.md`; `tests/e2e/lua_picker_live.test`, `lua_example_recent_commands.test` |
| Lua list helper + rail sections — `mnml.list{}`, `mnml.section{}`, `mnml.pane.open{ list }` | done | `src/app/script_list.zig`, `src/app/script_section.zig`, `src/ui/script_list.zig`, `Section.script` / `RailRow` / `railOrder` in `src/ui/activity_bar.zig`, `PanelId.script` in `src/core/panel.zig` | Zig-authored — the Rust editor's sections are all built in. `mnml.list{}` is the `ListPanel` TODOS is (caps header, refresh and `sort:` chips, filter pill, `j`/`k`/`g`/`G`/Enter, fold headers, scrollbar, row menu, hits); the script answers only with rows, asked on creation, on `l:refresh()`, on the chip and on a sort change. `mnml.section{}` gives it a real activity-bar row — its own glyph, its own place from `after` — and a column of its own, in `rects.json` as `rail:script:N` / `row:script:N` / `chip:script:refresh`, all dropped on `script.reload`; `mnml.pane.open{ list = l }` is the pane form. `docs/LUA.md`; `tests/e2e/lua_section.test`, `lua_example_todo_list.test` |
| Lua text operations + operator registration — `mnml.buf.selection` / `range` / `word_at`, `mnml.operator{}`, `mnml.commands` | done | the `mnml.buf` block of `src/scripting/api.zig`, `src/input/script_ops.zig`, `PendingOp.script` / `finishOperator` in `src/input/vim.zig`, `AppCommand.script_operator`, `runOperatorMode` | Zig-authored. A script reads a range (`selection` with its `char` / `line` / `block` shape, `range`, `word_at`) and registers an operator that reaches both profiles by their own road: under vim the `g<letter>` chord goes into a table the handler asks once its own `g` switch has fallen through, so `gs{motion}`, `gsiw`, `3gsw`, `gss` and `V…gs` all build the range the way `gU{motion}` does; under standard the chord is an ordinary `user.<id>` command taking the selection, or the word under the cursor. Whatever `run` applies is one undo step. `docs/LUA.md`; `tests/e2e/lua_operator.test`, `lua_example_surround_word.test` |
| Lua `cursor_idle` hook; `mnml.task.run{ hidden, on_line }` | done | `src/app/idle.zig`, `src/app/script_task.zig`, `Hook.cursor_idle` in `src/core/hooks.zig` | Zig-authored. `cursor_idle` fires 300 ms after the cursor stops, once per resting place; `buffer_change`, documented since D10 and emitted nowhere, fires too. A `hidden` task has no pane and streams its output to `on_line` a line at a time (stderr merged in, 5000 lines of 4 KiB capped). The two shipped examples are the acceptance: `docs/examples/scripts/{git-blame-line,eslint}.lua`, `tests/e2e/lua_example_git_blame_line.test`, `lua_example_eslint.test` |
| Bridge v2 — `Pane.mount` over a socket | done | `src/bridge/host.zig` / `wire.zig`, `src/app/mount_pane.zig`, `mount.open` | beyond the Rust list; the SDK is `sdk/mnml-sdk` |

## Languages

| feature | status | Zig file(s) | note |
|---|---|---|---|
| Tree-sitter highlighting, 39+ languages | done | `grammars` in `build.zig` (41 entries), `src/highlight/table.zig` | the Rust `Cargo.toml` pins 38 grammar crates; `markdown_inline` and `ocaml_interface` are separate entries here where Rust's `md` / `ocaml` crates carry both |
| Every Rust-listed language | done | same | every one of the 38 has an entry (`tsx` is its own here, `typescript`'s in Rust) |
| Repo-local queries (hcl / proto / vue) | done | `local_queries` in `build.zig` | |
| Language injection | done | `src/highlight/engine.zig`, `predicate.zig` | markdown fences, `<script>` / `<style>` tested |
| Extension / filename / injection-name mapping | done | `src/highlight/table.zig` aliases | comptime-validated |
| C# — outline, `if` / `af` / `ic` / `ac`, folds, the line-pattern fallback | done | the c_sharp rows of `kinds` in `src/highlight/structure.zig` (a `property` kind), `cs_rules` + `csMethodName` in `src/app/outline.zig`; `tests/e2e/dotnet_highlight_outline.test` | properties, constructors, records, local functions, file-scoped namespaces, the two lambda shapes; beyond the Rust list (Rust had the grammar, not the structure) |

## Disputed

Claims in a parity note that did not check out against the source. The
row keeps the status the source supports. *(2026-09-07: kept as the
record of that check. The glyph rows are `done` since `62e607e` — the
runners landed — and the 812 / 901 line was that day's count; the Ids
line at the top of this page is today's.)*

| note | claim | what was looked for | row stays |
|---|---|---|---|
| `misc` | Glyph baking / audit tooling — `done` | `tools/glyph_audit.zig` and `zig build glyph-audit` exist (bake + audit); the ledger row is the command surface, and at the time `integrations.audit_glyphs`, `bake_ai_glyphs`, `bake_all_glyphs`, `bake_integration_glyphs`, `edit_claude_glyph`, `edit_codex_glyph` and `menu.glyph_audit` had no runner. Since `62e607e` all but the two `edit_*_glyph` ids run (`src/app/glyph_audit.zig`; those two are `cutRunner` stubs since the `runners` track — the SVG editor is cut), and the catalog is embedded, so the row and this line agree | `done` |
| `files`, `search`, `ui-polish` | "Command ids: N — every one with a runner" | true of each track's own ids; 89 of the 901 spec ids still have no runner (the list at the top of this page's Remaining table is drawn from them) | the totals line above says 812 / 901 |
