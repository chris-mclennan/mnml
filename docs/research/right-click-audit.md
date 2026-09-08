# Right-click audit — Rust `right_click.rs` vs. mnml-zig

Every arm of Rust `src/tui/mouse/right_click.rs` (2,515 lines, 2026-09-03
build) that opens a menu or acts on a right press, in the order the cascade
checks them, against what mnml-zig routes on `.button == .right` today.
The Zig column is the `dispatch.zig` prong (or the module it hands to) at
the branch point `2f56661`; the *after* column is this branch.

Legend — **gap**: `none` (same rows, or Zig's equivalent), `partial`
(the surface has a menu, Rust rows are missing), `missing` (a left press
does something, a right press nothing), `n/a` (Rust surface that does not
exist in Zig, or Zig folds it into another surface). **owner**: `me`
(this branch), or the running track that owns the file.

Rows are Rust's command ids; `→ zig` names the id that replaced one.
Actions that are not commands in Rust (`CopyPath`, `RevealInTree`,
`OpenPath`, `SetTheme` …) are named as such; in Zig they are a
`MenuAction` variant or a Zig-only command.

## The table

| # | Rust surface (rect) | Rust rows | Zig today | gap | owner | after |
|---|---|---|---|---|---|---|
| 1 | panel `⟳` chip: todos/notes/findings/sessions | `<panel>.refresh`, TogglePanelAutoRefresh | `todos.zig:838` `notes.zig:508` `findings.zig:672` `sessions.zig:771` → `auto_refresh.openRefreshMenu` | none | — | — |
| 1b | `⟳` chip: agents pane, cloud agents | same | the sessions table's `⟳` (`sessions_table.zig` `click`, `.refresh`) → `auto_refresh.openRefreshMenu`; the two panels are gone | none | sessions-merge | none |
| 1c | `⟳` chip: git palette | `git.refresh` + auto toggle | `git_palette.zig:1057` left only | missing | me | `openRefreshMenu(.git)` |
| 1d | `⟳` chip: HTTP, INTEGRATIONS (Zig-only) | — | `http_panel.zig:873` left only; `integrations.zig:1317` ✓ | missing (http) | me | `openRefreshMenu(.http)` |
| 2 | `sort:` chip todos/notes/findings | SetPanelSort × ListSort (✓ current) | `todos.zig:837` `notes.zig:507` `findings.zig:671` | none | — | — |
| 3 | SESSIONS sort chip | `sessions.sort_auto`, `sessions.sort_manual` | `sessions.zig:770` | none | — | — |
| 4 | statusline bell chip | `messages.show`, MarkMessagesSeen, CopyLastMessage, CopyAllMessages | `dispatch.zig .bell` → `openBellMenu` (Show messages, Clear history) | partial (no mark-seen / copy rows: no Zig ids) | me | accepted |
| 5 | `debug_click_inspector` toast | (debug aid) | — | n/a | — | — |
| 6 | `{{var}}` token (request pane, editor) | SetEnvVarValue, JumpToEnvVar, CopyPath(name) | `http.zig:318,532` `openQuickFixMenu` | none | http-options | — |
| 7 | palette search chip | runs `picker.recent` | `Button.palette` left = `palette` | missing | me | right → `picker.recent` |
| 8 | activity-bar gear | `view.settings`, `palette`, `view.help`, `theme.pick`, `view.about` | `activity_bar.zig:157` `openGearMenu` | none | — | — |
| 9 | right-panel tab chip | SetRightPanelTab, CloseTab, CloseOtherRightPanelTabs, CloseAllRightPanelTabs, `view.toggle_right_panel` | `Button.right_tab` left = `view.focus_right_panel` | missing | me | Focus / Next / Previous / Close tab / Hide column |
| 10 | right-panel `×` | same as 9 | `Button.right_close` left = `view.right_panel_close_tab` | missing | me | same menu |
| 11 | session card (SESSIONS row) | SessionTogglePin, MoveUp/Down/ToTop/ToBottom, SessionSortAuto, SessionRename, color rows | `sessions.zig` `openRowMenuFor` (Pin, Move up/down, Rename…, Resume, Open transcript, Copy id, Delete…) | partial (to top / to bottom / colour) | sessions-merge | partial: Move to top / Move to bottom (`sessions.move_top` / `_bottom`) and a ✓ Auto sort row (`sessions.sort_auto`) added; the colour rows tint a pty pane's card in Rust — Zig's rows are transcripts with no colour model, accepted |
| 12 | `+ New session` chip | `ai.claude_code_new`, `_x2`, `_x4`, `_x8` | `sessions.zig:772` `openNewMenu` | none | — | — |
| 13 | dock widget body / title / kebab | the kebab menu | `dock.zig:877` | none | — | — |
| 14 | Claude Agents dashboard row | `ai.dashboard.open_transcript`, `resume_in_pty`, `yank_session_id`, `yank_cwd`, `export_markdown`, `kill` | `agents.zig:828` `openRowMenu` | none | sessions-merge | — |
| 15 | Cloud Agents row | CopyText(runId), OpenUrl(CloudWatch), OpenUrl(PR), OpenCloudAgentRunDetail | a SESSIONS cloud row → `openRowMenuFor` (Open run, Tail log, Copy run id, Cancel run…) | partial (the two links) | sessions-merge | none: titled `workspace · runId`, Open CloudWatch in browser (`cloud_agents.cloudwatchUrl`, when the account / region / log group are set) and Open PR (when the record names one) as `open_url` rows |
| 16 | dashboard Files drill-down row | OpenPath, RevealInTree, RevealInFinder, CopyPath, OpenExternally | — | n/a | sessions-merge | n/a: the sessions table has no Files drill-down (the dashboard's drill-downs did not carry over) |
| 17 | GIT rail section header | `git.fetch`, `git.pull`, `git.graph` | the rail's `.git` icon → `openRailMenu` (graph / fetch / commit) | none (equivalent) | — | — |
| 18 | Cloud Agents `view:` chip | `cloud_agents.view_compact` / `_standard` | — | n/a | sessions-merge | n/a: the table has one row density; the chip and the three `cloud_agents.*view*` ids (which toggled a flag nothing read) are gone |
| 19 | NOTES row | OpenPath, OpenInSplit, RevealInTree, RevealInFinder, CopyPath, Rename, Delete | `notes.zig:481` (`notes.open`, `notes.copy_path`, `notes.delete`) | partial (split / reveal / rename: no Zig ids) | me | accepted |
| 20 | top-right `+` | `plus_menu_items` (Create…), curatable | `dispatch.zig:1780` → `openNewTabMenu` | none | — | — |
| 21 | AGENTS rail rows | Open transcript, Copy session id, reveal, Copy workspace path, `ai.dashboard` | Zig's AGENTS section opens the dashboard pane (#14) | n/a | — | — |
| 22 | SEARCH result row | OpenPath, OpenInSplit, RevealInTree, RevealInFinder, CopyPath(match), CopyPath(path:line) | `grep.zig:1054` `openRowMenu` (Open, Skip/Include on replace, Copy path:line + text, …) | partial (split / reveal) | me | accepted |
| 23 | FINDINGS row | as NOTES | `findings.zig:645` (`findings.open`, `copy_path`, `resolve`, `delete`) | partial | me | accepted |
| 24 | activity-bar icon (each section) | `Show X` + section verbs; LauncherIcon: Launch / Move… / Remove | `activity_bar.zig:152` `openRailMenu` (+ Move to side) | none | — | — |
| 25 | response tabs Body / Headers / Cookies / Timeline / Tests | `http.copy_response_body`, `http.format_body`, `http.save_response` / `copy_response_headers` / `copy_response_cookies` / `copy_response_timeline`, `diff_last_two` / `copy_response_tests`, `http.send` | `request_pane.zig:1013` `hit_resp_tab_base` left only | missing | http-options | listed |
| 26 | Send chip | `http.send`, `http.abort`, `http.diff_last_two` | `request_pane.zig` `hit_send` left only | missing | http-options | listed |
| 27 | Save chip | `http.save`, `http.save_mock`, `http.save_response` | `hit_save` left only | missing | http-options | listed |
| 28 | Clear chip | `http.new` | `hit_clear` left only | missing | http-options | listed |
| 29 | Code chip | `http.copy_curl`, `http.generate_code` | `hit_code` left = copy-as picker | missing | http-options | listed |
| 30 | Vars-tab row | Edit…, Copy name, `http.delete_env_key` | `hit_var_row` left only | missing | http-options | listed |
| 31 | Env chip | `http.pick_env`, `http.edit_env`, `http.reset_env` | `hit_env` left = pick | missing | http-options | listed |
| 32 | HTTP FILES / collection item row | OpenPath, OpenPathAsText, OpenInSplit, RevealInTree, RevealInFinder, CopyPath, Rename, Delete | `http_panel.zig:832` `openRowMenu` (Open, Copy path, New request…, New collection…, Sync) | partial (text / split / reveal / rename / delete) | me | accepted |
| 33 | RECENT row | Open as scratch, Copy curl, Copy URL | `openRowMenu` recent (Open as request, Copy URL, History picker…, Clear recent) | partial (Copy curl) | me | accepted |
| 34 | CAPTURED row | Open as curl, Copy curl, Copy URL | captured rows (Open as request, Copy URL, Captured picker…, Clear captured) | partial | me | accepted |
| 35 | ENVS row | `http.pick_env`, OpenPath, Copy name, Copy path, Rename, Delete | envs rows (Use this env, Copy name, Edit active env…, Clear override, New env…) | partial | me | accepted |
| 36 | CHAINS row | Run, Open file, reveal ×2, Copy path, Delete | chains rows (Run chain, Copy name, New chain…) | partial | me | accepted |
| 37 | collection folder row | NewFile, NewFolder, reveal ×2, CopyPath, Rename, Delete | folder rows (Expand/Collapse, Copy path, New request…, New collection…) | partial | me | accepted |
| 38 | MOCKS row | Replay, Open file, reveal ×2, Copy path, Delete | mocks rows (Open, Copy path, Replay on active request) | partial | me | accepted |
| 39 | HTTP section header | per section: `http.new_request` / `clear_recent` / `capture_start` + `clear_captured` / `new_env` / `new_chain` / `save_mock` + `replay_mock` / `new_collection`; then `toggle_collapse_all`, `http.refresh` | header rows (`kind == .header`) → `openRowMenu` | none | — | — |
| 39b | HTTP header chips / link rows / folder ` + ` (Zig-only `Part`) | — | `http_panel.zig:883` `partMouse` left only | missing | me | right → the row's menu |
| 40 | statusline branch chip | `git.graph`, `git.status_pane`, `git.checkout`, `git.new_branch`, `git.fetch`, `git.pull`, `git.push`, `git.stash`, `git.stash_pop`, `git.commit`, `git.ai_commit` | `openBranchMenu` (status, graph, commit, fetch, pull, push, refresh) | partial | me | + Checkout…, New branch…, Stash…, Stash pop, AI commit |
| 41 | statusline workspace chip | `git.switch_repo` / `next_repo` / `prev_repo` (multi-repo), `git.worktrees`, `view.switch_workspace`, `view.add_workspace`, `view.manage_workspaces`, `git.refresh_repos`, RevealInFinder | `.workspace` left only | missing | me | all but reveal |
| 42 | mode chip | `editor.use_vim`, `editor.use_standard`, `editor.toggle_keymap` | `openModeMenu` | none | — | — |
| 43 | file chip | RevealInTree, RevealInFinder, CopyPath(abs), CopyPath(rel), CopyPath(name), `buffer.close` | `openFileChipMenu` (Copy path, Close) | partial | me | + Reveal in tree, Reveal in Finder, Copy absolute path, Copy file name |
| 44 | PR chip | OpenExternally(url), CopyPath(url), CopyPath(number) | `.pr` left = open URL | missing | me | Open in browser / Copy URL / Copy number |
| 45 | palette `←` / `→` | MRU history rows (`buffer.*`), `buffer.clear_mru` | `Button.back` / `forward` left only | missing | me | Previous / Next / Buffer picker… / Clear history |
| 46 | palette sidebar toggle | `view.toggle_tree`, `view.reset_tree_width`, `view.focus_tree` | `Button.toggle_tree` left only | missing | me | ✓ |
| 47 | palette right-panel toggle | `view.toggle_right_panel`, `view.focus_right_panel`, `outline.show`, `lsp.diagnostics` | `Button.toggle_right_panel` left only | missing | me | ✓ |
| 48 | palette dropdown `▾` | `picker.recent`, `picker.recent_commands`, `picker.files`, `palette` | `Button.dropdown` left = recent | missing | me | ✓ |
| 49 | palette stress mirror | stress menu | Zig has no top-right mirror | n/a | — | — |
| 50 | bufferline `+` (old New-tab menu) | superseded by #20 | — | n/a | — | — |
| 51 | theme pill | Theme: cur, `theme.toggle`, `theme.auto_system` / `_off`, `theme.reset`, `theme.pick`, per-theme SetTheme rows | `Button.theme_toggle` left only | missing | me | ✓ (`MenuAction.set_theme`) |
| 52 | menu-bar words | Menu bar: cur, `view.menu_bar_cycle` | `menu_bar.buttonOf` left opens | missing | me | ✓ |
| 53 | window `×` | `app.quit`, `file.save_all`, `app.restart` | `Button.window_close` left = quit | missing | me | ✓ |
| 54 | undo chip | dismiss | `dispatch.zig:1713` | none | — | — |
| 55 | toast body | Toast: text, `toast.dismiss_current`, `toast.dismiss_all`, CopyPath(text) | `dispatch.zig:1721` `openToastMenu` | none | — | — |
| 56 | statusline stress chip | stress menu | `.stress` → `openStressMenu` | none | — | — |
| 57 | diagnostics chip | `lsp.next_diagnostic`, `lsp.prev_diagnostic`, `lsp.diagnostics` | `openDiagnosticsMenu` | none | — | — |
| 58 | language chip | CopyPath(language) | `.language` left = toast | missing | me | Copy language name |
| 59 | Ln/Col chip | `editor.goto_line`, CopyPath(pos) | `.position` left = goto | missing | me | ✓ |
| 60 | find chip | `find.next`, `find.prev`, `find.clear`, `find.find` | `.find` left = find | missing | me | ✓ |
| 61 | Sel chip | `editor.copy`, `editor.cut` | `.sel => {}` | missing | me | ✓ |
| 62 | size chip | CopyPath(bytes), OpenExternally | `.filesize` left = toast | missing | me | Copy size (no open-externally id) |
| 63 | WRAP chip | `view.toggle_wrap`, `view.settings` | `.wrap` left = toggle | missing | me | ✓ |
| 64 | autosave chip | none, by design | `.autosave` left = toast | none (rust-none) | — | — |
| 65 | LSP chip | Status, `lsp.symbols`, `workspace_symbols`, `diagnostics`, `references`, `rename`, `format`, `code_action`, `inlay_hints_toggle` | `statusline.openLspChipMenu` | none | — | — |
| 66 | test chip | `test.run_all`, `test.run_file`, `test.run_at_cursor` | `.test_run` left = focus pane | missing | me | ✓ |
| 67 | clock chip | `clock.local`, `clock.utc`, `clock.hide` | `clock.openMenu` | none | — | — |
| 68 | AI Claude / Codex chip | open usage (`ai.claude_usage` / `ai.codex_usage`), `ai.refresh_usage`, `ai.show_last_response`, `ai.chip_show_session` / `_weekly` / `_both`, `ai.chip_toggle_reset`, `ai.chip_show_all_off` / `_compact` / `_ticker` | `.ai_claude`/`.ai_codex` left = `ai.spend_today` | missing | me | ✓ |
| 69 | coverage chip | open pane, `coverage.chip_show_*` | `coverage.openModeMenu` | none | — | — |
| 70 | dynamic (host) statusline segment | ReorderStatuslineSegment ±1 | `seg_dyn_base` left = `click_command` | missing | me | deferred: Zig's `effects.pack` orders by priority, there is no user order to move in |
| 71 | Sonos cluster | `sonos.*` | Zig has no Sonos chip | n/a | — | — |
| 72 | mixr chip | `mixr.*` | `now_playing.openMenu` | none | — | — |
| 73 | `> WORKSPACE` header | `view.toggle_tree_section`, TreeExpandRecursive, TreeCollapseRecursive, `view.switch_workspace`, `view.add_workspace`, `view.manage_workspaces`, SetDefaultWorkspace, RemovePrimaryWorkspace, RevealInFinder, `tree.refresh`, `tree.collapse_all`, `tree.expand_all`, `view.toggle_workspace_dots` | `.tree_root` left = fold | missing | me | ✓ (the ids that exist) |
| 74 | detail-pane link row | copy URL | `.link => {}` | missing | me | Open in browser / Copy URL |
| 75 | integration chip (palette bar) | Enable/Disable, palette-bar toggle, Details, Update, marketplace, auto-update, Move…, Edit, bookmarks, Configure, Diag, launcher, rail pin, Copy id, Manifest, glyph, Remove | `integrations.zig:933` `openInstalledMenu` | partial (Rust's config-editing rows have no Zig counterpart) | me | accepted |
| 76 | marketplace row | `marketplace.install_focused`, `open_detail_focused`, `copy_id_focused` | `integrations.zig:1288` `openEntryMenu` | none | — | — |
| 77 | TABS label | SetTopBarClusterMode expanded / compact / auto | `Button.tabs_label` left = `tab.picker` | missing | me | `view.cluster_mode_*` ✓ |
| 78 | split-strip `[│]` / `[─]` | `view.split_right`/`_down`, `view.equalize_splits`, `split_grow_*`, `split_shrink_*`, `buffer.close` | `Button.split_right` / `split_down` left only | missing | me | ✓ |
| 79 | maximize chip | `view.toggle_zoom`, `view.fullscreen`, `view.equalize_splits` | `Button.split_max` left = fullscreen | missing | me | ✓ |
| 80 | terminal chip | `term.shell`, `term.shell_left`/`_right`/`_top`/`_bottom`, `term.scratch_toggle` | `Button.split_term` left = shell | missing | me | ✓ |
| 81 | split-strip AI button | profile rows, toggle (`ai.claude_code`), `ai.claude_code_new_left`/`_right`/`_top`/`_bottom`, `view.ai_layout_grid`/`_tabs`, `integrations.bake_ai_glyphs`, glyph builder | `Button.ai_claude` / `ai_codex` left only | missing | me | ✓ (no glyph builder in Zig) |
| 82 | INTEGRATIONS rail header | collapse / expand | the rail icon (#24) | n/a | — | — |
| 83 | extra-workspace header | SetAsWorkspace, SetDefaultWorkspaceAt, SwitchToExtraWorkspace, MoveUp/Down, `view.switch_workspace`, `view.remove_workspace`, `view.manage_workspaces`, RevealInFinder, `tree.refresh`, collapse / expand, dots | `.tree_root` (i + 1) left = fold | missing | me | ✓ (the ids that exist) |
| 84 | request URL / Method / Headers / Body | `http.send`, `http.field_copy`/`_paste`/`_cut`/`_select_all`, `http.copy_curl`, …, Method picker (`http.set_method.*`) | `request_pane.zig:1072,989,1102` `openRequestFieldMenu`; method: left cycles, right nothing | partial (method picker) | http-options | listed |
| 85 | AI pane | `ai.reask`, `ai.cancel`, `ai.promote`, `ai.apply`, `ai.session_view` | `.pane` right → editor menu only; `.ai => {}` | missing | me | ✓ (the four ids that exist) |
| 86 | pty pane body | `term.paste`, `term.clear`, `term.restart`, `view.move_split_left`/`_right`/`_up`/`_down`, `view.maximize_width`/`_height`, `view.fullscreen`, `view.equalize_splits`, `buffer.close` | `.pane` pty: forwarded to a mouse-tracking child, else nothing | missing | me | ✓ when the child does not track the mouse |
| 87 | editor gutter | `dap.toggle_breakpoint`, `dap.toggle_breakpoint_conditional`, `lsp.goto_definition`, `lsp.references`, `lsp.hover`, `git.peek_change`, `git.blame_toggle`, `git.browse` | `openGutterMenu` (breakpoint verbs, dap session) | partial | me | + Peek change, Toggle blame, Open on remote |
| 88 | fold arrow | editor body menu | folded into `.gutter` | n/a | — | — |
| 89 | editor body | cut/copy/paste/undo/redo/select all, goto def/refs/hover/rename, `editor.select_all_occurrences`, `lsp.selection_expand`, `editor.toggle_fold`, `ai.explain`, `ai.ask`, Save | `openEditorMenu` | partial | me | + Expand selection, Explain with Claude, Ask Claude… |
| 90 | pty tab strip | RenameSession, (Claude: session id row), CloseTab | `.tab` → `openTabMenu` | partial | me | + Rename…, Restart, Clear for a pty tab |
| 91 | bufferline tab | Save, Pin, Close, Close others, Close all, (request: Open as text, Copy path), (editor: Preview markdown, Copy rel / abs, RevealInTree, RevealInFinder), Split into R/B/L/T, Host in bottom panel, (pty: Rename, Restart, Interrupt, Clear) | `openTabMenu` (Save, Close ×4, Pin, Split right / down, Copy path) | partial | me | + Preview markdown, Reveal in tree, Reveal in Finder, pty rows |
| 92 | per-split tab chips | same | one strip in Zig (`.tab`) | n/a | — | — |
| 93 | tree row | OpenPath, OpenInSplit, PreviewMarkdown, NewFile, NewFolder, OpenTerminal, Cut, Copy, Paste, Duplicate, MoveTo, Rename, Delete, RevealInFinder, OpenExternally, CopyPath; dir: SetAsWorkspace, OpenFilesPane, Expand/CollapseRecursive | `openTreeMenu` | partial (set as workspace / files pane / recursive / terminal / externally) | me | accepted |
| 94 | tree empty area | the workspace header menu (#73) | nothing registered below the last row | missing | me | `HitTarget.tree_empty` → #73 |
| 95 | extra workspace rows | tree menu | one list in Zig (`.tree_node`) | none | — | — |
| 96 | GIT rail rows: branch / worktree / pull / stash / tag | checkout, merge, rebase, new branch, copy name, delete; worktree open / shell / copy / remove; PR open / copy; stash pop / apply / drop / copy; tag checkout / copy / delete | `git_palette.zig:1032` `openRowMenu` | none | — | — |
| 97 | Files pane row | tree menu + Restore (trash), Mark/Unmark, Cut N / Copy N selected | `files_pane.zig:1057` | none | — | — |
| 98 | TODO row | TodoAction fix-with-agent / Claude / Codex, OpenPath, OpenInSplit, RevealInTree, RevealInFinder, CopyPath(rel:line) | `todos.zig:809` | partial (split / reveal) | me | accepted |
| 99 | git palette rows | as #96 | as #96 | none | — | — |
| 100 | Diff rows | `open_diff_context_menu` | `git.zig:2124` `diffClick` left only | missing | git-lines | listed |
| 101 | GitGraph embedded diff rows | same | `git.zig:2529` graph rows ✓; embedded diff — | partial | git-rebase | listed |
| 102 | GitStatus rows | stage / unstage / discard / … | `git.zig:2585` `openRowMenu` | none | — | — |

## Zig surfaces Rust never had

| surface (`HitTarget`) | left today | right today | decision |
|---|---|---|---|
| `.tab_close` (a tab's badge cells) | close | nothing | the tab's menu (Rust's tab rect covered the `×`) — me |
| `.breadcrumb` segment | Files pane at the dir | nothing | Copy path / Open folder — me |
| `.welcome` recent / shortcut rows | open / run | nothing | recent: Open / Copy path; shortcut: no menu (a single verb) — me |
| `.info_view` kebab | the sidebar menu | nothing | the same menu — me |
| `.button` `right_new` | Add panel menu | nothing | the same menu — me |
| `.button` tab-page chip / its `×` | show page / close | nothing | Close this page / Close other pages / New tab page — me |
| `.button` INTEGRATIONS tabs | show tab | nothing | Installed / Marketplace / Dev with ✓ + Refresh — me |
| `.button` `hidden_tabs` | buffer picker | nothing | no_right: one verb, already a list |
| `.button` tab-scroll markers, md-preview chips, menu-bar overflow | step / switch / open | nothing | no_right: one verb each |
| `.chip` `.git` refresh | refresh | nothing | #1c |
| `.chip` `.http` refresh / new | refresh / new request | nothing | refresh: #1d; new: New request… / New collection… / New env… / New chain… / Paste curl ladder — me |
| `.chip` `.diagnostics` | cycle filter | nothing | lua-track (owns `lsp.zig` rows) — listed |
| `.chip` `.debug` new | add watch | nothing | no_right: one verb |
| `.row` `.diagnostics` | jump | nothing | lua-track — listed |
| `.git_palette` repo pill / `‹` `›` | repos menu / step | nothing | pill: the same menu — me; arrows: no_right |
| `.statusline_seg` symbol / macro / restricted / transfer | outline / macro / trust / cancel | nothing / nothing / nothing / cancel | symbol: Outline / Copy symbol — me; macro, restricted: no_right (one verb); transfer: a one-row menu — me |
| `.pane` on a non-editor pane (outline, preview, image, files, grep, …) | focus | nothing | the pane's tab menu — me |
| `.script_hit` tests / flaky / spend / ai_apply / browser / cheatsheet / dap / list / outline / md_preview / image | select / run | nothing | no_right: rows Rust never gave a menu; the pane body (`.pane`) now offers the tab menu |
| `.scrollbar`, `.divider`, `.filter_input`, `.overlay_item`, `.tree_chip`, `.editor_cell` (has), `.gutter` (has), `.menu_item` (has) | — | — | no_right: drag / focus / overlay; the chips are one verb each |

## Totals

Rust arms enumerated: 102 (plus 19 Zig-only surfaces).

Before this branch: none 38 · partial 15 · missing 44 · n/a 9 (of the
102 Rust arms; 19 Zig-only surfaces all missing or undecided).

Handed to other tracks: sessions-merge (#1b, #11, #15, #16, #18 —
landed on that branch: #1b and #15 none, #11 an accepted partial for
the colour rows, #16 and #18 n/a),
http-options (#25–#31, #84), git-lines (#100), git-rebase (#101),
lua-track (diagnostics rows and chip).

Accepted partials (rows whose Rust action is a path-carrying
`MenuAction` with no Zig command behind it — Open in split / Reveal in
tree / Reveal in Finder / Rename / Delete on the list panels): #4, #19,
#22, #23, #32–#38, #75, #93, #98. Each needs a row-scoped Zig-only
command family (`notes.reveal`, `http.panel_reveal` …); a follow-up,
not a right-click gap.

Deferred: #70 (host segment reorder — no order model to move in).

## After (this branch, rebased on `9c78dbf`)

Of the 102 Rust arms: none 78 · partial 14 (all accepted, see above) ·
missing 1 (#70, deferred) · n/a 9 — the 44 missing became 40 none, 3
handed to their tracks' lists (#25–#31/#84 http-options, #100
git-lines, #101 git-rebase, #1b/#15/#16/#18 sessions-merge, the
diagnostics rows and chip lua-track) and 1 deferred. The 19 Zig-only
surfaces: 13 now open a menu, 6 are `no_right_click` with a reason
(`dispatch.right_click_of`).

A caveat from git-lines, true of every `.right` arm here: the e2e
driver swallows a command's failure unless the handler toasts. A menu
opener can only fail with OutOfMemory, so an arm that opens one cannot
fail silently; the rows it offers run through `runMenuAction`, which
lets a command's own diag through the way the palette does. The one
arm that runs a command directly — the palette search chip's
`picker.recent` — swallows a non-OOM failure the same way the chip's
left press does; a `.test` that right-clicks it must expect the picker,
not the absence of a toast.
