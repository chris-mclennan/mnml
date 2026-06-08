---
title: VS Code cheatsheet
description: Every VS Code chord and menu path mapped to its mnml equivalent. Printable, scannable, exhaustive.
---

This is the **reference**. VS Code chord / menu path on the left, mnml chord on the right, the command id mnml fires in the middle. For the narrative migration walkthrough — what mnml ships, what's renamed, what's intentionally missing — see [Coming from VS Code](/manual/coming-from-vscode/). For the live in-app cheatsheet that walks your current keymap, open the pane with `Ctrl+K ?` (which-key leader → `?`) or run the palette command `view.cheatsheet`.

:::tip[How to use this page]
- Use your browser's find (`Ctrl+F` / `Cmd+F`) to grep for a chord, a command id, or an action verb.
- Rows marked `(not bound)` are honest about VS Code commands that mnml does not implement — either the feature exists under a different chord, or the feature isn't here yet.
- mnml is in **standard** (modeless / VS Code-style) mode by default. Switch with the palette command `editor.use_standard`, the ex command `:set input=standard`, or the bufferline mode chip.
- Chord notation: `Ctrl+X` is `Cmd+X` on macOS for the chords macOS terminals can transmit. mnml uses `Ctrl` throughout; your terminal may need an "Option/Alt sends Esc+" toggle to forward `Alt+…` chords.
- mnml's leader chord in standard mode is `Ctrl+K` — same prefix VS Code uses for its chord-prefix bindings. Follow with the next-key from the [NvChad cheatsheet](/manual/cheatsheet-nvchad/)'s `<leader>…` tables.
:::

## File ops

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+N` New File | `Ctrl+N` | `file.new` | Prompts for workspace-relative path |
| `Ctrl+S` Save | `Ctrl+S` | `file.save` | |
| `Ctrl+K S` Save All | (not bound under chord) | `file.save_all` | Palette: "Save all files" |
| `Ctrl+Shift+S` Save As… | (not bound) | — | Use `:saveas <path>` in vim mode; SEV-3 gap |
| `Ctrl+W` Close Editor | `Ctrl+W` | `buffer.close` | |
| `Ctrl+Shift+T` Reopen Closed Editor | `Ctrl+Shift+T` | `buffer.reopen` | |
| `Ctrl+K Ctrl+W` Close All | (not bound under chord) | `view.close_others` (partial) | Closes all but active |
| `Ctrl+P` Quick Open | `Ctrl+P` | `picker.files` | File picker |
| `Ctrl+R` Recent | `Ctrl+R` | `picker.recent` | mnml-specific; VS Code uses `Ctrl+R` for recent folders |
| `Ctrl+Shift+N` New Window | (not bound) | — | mnml is single-window; launch a second binary |
| `Ctrl+,` Settings | `Ctrl+,` | `file.open_settings` | Opens the TOML in a buffer (settings UI is `view.settings`) |
| `Ctrl+Shift+Y` (none) | — | — | |
| File: Revert | (not bound under chord) | `file.reload` | Refuses if dirty |

## Edit

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+X` Cut | `Ctrl+X` | `edit_op::CutSelection` / `YankLine`+`DeleteLine` | Falls back to cut-line when no selection |
| `Ctrl+C` Copy | `Ctrl+C` | `edit_op::YankSelection` / `YankLine` | Yanks line with no selection |
| `Ctrl+V` Paste | `Ctrl+V` | `edit_op::Paste` | |
| `Ctrl+Z` Undo | `Ctrl+Z` | `edit_op::Undo` | |
| `Ctrl+Shift+Z` / `Ctrl+Y` Redo | both | `edit_op::Redo` | |
| `Ctrl+A` Select All | `Ctrl+A` | `edit_op::SelectAll` | |
| `Ctrl+L` Select Line | `Ctrl+L` | `edit_op::SelectLine` | Note: vim mode rebinds `Ctrl+L` to `view.redraw` |
| `Ctrl+D` Add Selection to Next Find Match | `Ctrl+D` | `editor.add_cursor_at_next_word` | |
| `Ctrl+Shift+L` Select All Occurrences | `Ctrl+Shift+L` | `editor.select_all_occurrences` | |
| `Ctrl+Shift+K` Delete Line | `Ctrl+Shift+K` | `editor.delete_line` | |
| `Ctrl+Shift+D` Duplicate Line | `Ctrl+Shift+D` | `edit_op::DuplicateLine` | |
| `Alt+Up` / `Alt+Down` Move Line | same | `editor.move_line_{up,down}` | Aliases: `Alt+K` / `Alt+J` |
| `Shift+Alt+Up` / `Shift+Alt+Down` Copy Line Up/Down | `Shift+Alt+Up` / `Shift+Alt+Down` | `edit_op::DuplicateLine` | Same VS-Code semantic — cursor lands on the new copy. `Ctrl+Shift+D` still works and stays in place. |
| `Ctrl+]` Indent | `Tab` (with selection) | `edit_op::Indent` | mnml indents the selection range |
| `Ctrl+[` Outdent | `Shift+Tab` | `edit_op::Outdent` | |
| `Ctrl+/` Toggle Line Comment | `Ctrl+/` | `edit_op::ToggleLineComment` | |
| `Shift+Alt+A` Block Comment | (not bound) | — | Filetype-aware toggle still in flight |
| `Ctrl+Enter` Insert Line Below | `Ctrl+Enter` | (custom) | Open line below |
| `Ctrl+Shift+Enter` Insert Line Above | `Ctrl+Shift+Enter` | (custom) | Open line above |
| `Alt+Click` Add Cursor | `Alt+Click` | (in-handler) | Wired. macOS Terminal swallows Option by default — enable "Use Option as Meta" in your terminal, or use iTerm2 / Alacritty / Kitty where Alt arrives intact. |
| `Ctrl+Alt+Up` / `Ctrl+Alt+Down` Add Cursor Above/Below | same (also `Ctrl+Alt+K` / `Ctrl+Alt+J`) | `editor.add_cursor_{above,below}` | |
| `Escape` Clear Multi-Cursor | (rebinds `Esc` to drop selection only) | `editor.clear_extra_cursors` | Palette-only; SEV-3 gap |
| `Ctrl+Space` Trigger Suggest | `Ctrl+Space` | `lsp.completion` | |
| `Ctrl+.` Quick Fix… | `Ctrl+.` | `lsp.code_action` | |
| `Alt+Enter` Apply First Quick Fix | `Alt+Enter` | `lsp.quick_fix` | |
| `Ctrl+Shift+I` Format Document | `Ctrl+Shift+I` | `lsp.format` | Falls back to external formatter via `editor.format` |
| `Ctrl+K Ctrl+F` Format Selection | (not bound under chord) | — | Use `Ctrl+Shift+I` |
| `Shift+Alt+O` Organize Imports | `Alt+Shift+O` | `lsp.organize_imports` | |

## Cursor motion

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| Arrow keys | same | `edit_op::Move{Left,Right,Up,Down}` | |
| Shift+Arrows | same | (SelectStart + motion) | Extends selection |
| `Ctrl+Left` / `Ctrl+Right` | same | `edit_op::MoveWord{Left,Right}` | Word motion |
| `Home` / `End` | same | `edit_op::MoveLine{Start,End}` | |
| `Ctrl+Home` / `Ctrl+End` | same | `edit_op::MoveBuffer{Start,End}` | |
| `PageUp` / `PageDown` | same | `edit_op::Page{Up,Down}` | |
| `Ctrl+G` Go to Line… | `Ctrl+G` | `editor.goto_line` | 1-based |
| `Ctrl+Backspace` Delete Word Left | same | `edit_op::DeleteWordLeft` | |
| `Ctrl+Delete` Delete Word Right | same | `edit_op::DeleteWordRight` | |
| `Ctrl+M` Toggle Tab Moves Focus | (not bound) | — | mnml's Tab is always indent / insert spaces |

## Search

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+F` Find | `Ctrl+F` | `find.find` | |
| `Ctrl+H` Replace | `Ctrl+H` | `find.replace` | Replace every match of the active find |
| `F3` Find Next | `F3` | `find.next` | |
| `Shift+F3` Find Previous | `Shift+F3` | `find.prev` | |
| `Alt+R` Toggle Regex | `Alt+R` | `find.toggle_regex` | Sticky toggle |
| `Ctrl+Shift+F` Find in Files | `Ctrl+Shift+F` | `find.grep` | Workspace grep (rg / git grep) → results pane |
| `Ctrl+Shift+H` Replace in Files | (not bound under chord) | `find.grep_replace` | Run after `find.grep` from the results pane |
| `Ctrl+G` Go to Line — note conflict | rebound — `Ctrl+G` opens go-to-line | `editor.goto_line` | VS Code's `Ctrl+G` and mnml's are the same chord, same action |
| `Alt+Enter` Select all matches | (not bound for find) | — | mnml uses `Alt+Enter` for `lsp.quick_fix` |
| Find: Match Case (toggle) | (not bound) | — | Find is case-insensitive by default; SEV-3 gap |
| Find: Match Whole Word (toggle) | (not bound) | — | Use word-boundary regex with `Alt+R` |

## Navigation

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Alt+Left` Back | `Alt+Left` | `nav.back` | |
| `Alt+Right` Forward | `Alt+Right` | `nav.forward` | |
| `F12` Go to Definition | `F12` | `lsp.goto_definition` | |
| `Ctrl+F12` Go to Implementation | (not bound under chord) | `lsp.goto_implementation` | Palette |
| `Shift+F12` Go to References | (not bound under chord) | `lsp.references` | Palette / `Ctrl+K Ctrl+L` chord |
| `F2` Rename Symbol | `F2` | `lsp.rename` | Added 2026-06-08 — also surfaced in the editor-body right-click menu |
| `Ctrl+Click` Go to Definition | (not bound — `Ctrl+Click` not wired) | — | SEV-3 mouse-pathway gap |
| `Ctrl+T` Workspace Symbol | (not bound under chord) | `lsp.workspace_symbols` | Palette |
| `Ctrl+Shift+O` Go to Symbol in File | `Ctrl+Shift+O` | `lsp.symbols` | Note: also bound to `editor.open_at_cursor` — chord conflict (file symbols wins in vim mode, open_at_cursor in standard mode behavior unverified; SEV-3) |
| `Ctrl+P @` Symbol picker | (not implemented as fuzzy modifier) | — | Use `Ctrl+Shift+O` |
| `Ctrl+G` Go to Line | `Ctrl+G` | `editor.goto_line` | |
| `F8` / `Shift+F8` Next/Previous Problem | (not bound to F-keys) | `lsp.{next,prev}_diagnostic` | Use `<leader>ln` / `<leader>lp` via `Ctrl+K` |

## Buffers / tabs

mnml's "tab" can mean two things: a buffer (file open in a pane) and a tab page (vim-style window group). VS Code's tabs are mnml's buffers.

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+Tab` Cycle Last Opened | `Ctrl+Tab` (also `Ctrl+6`) | `buffer.last` | Swap to previously-active buffer |
| `Ctrl+PageDown` Next Tab | `Ctrl+PageDown` | `buffer.next` | |
| `Ctrl+PageUp` Previous Tab | `Ctrl+PageUp` | `buffer.prev` | |
| `Ctrl+W` Close Tab | `Ctrl+W` | `buffer.close` | |
| `Ctrl+K W` Close All Tabs in Group | (not bound under chord) | `view.close_others` | Closes other panes |
| `Ctrl+Shift+T` Reopen Closed | `Ctrl+Shift+T` | `buffer.reopen` | |
| `Ctrl+1` … `Ctrl+9` Focus Tab N | `Alt+1` … `Alt+9` | `tab.goto_N` | mnml binds `Alt+N`, not `Ctrl+N` (which is New File) |
| Middle-click tab to close | (not bound) | — | Use `Ctrl+W` or palette `buffer.close` |
| Drag tab to reorder | (not bound) | `tab.move_{left,right}` (palette) | Drag-reorder is a SEV-3 mouse gap |
| Right-click tab → Close Others | (no context menu) | palette `view.close_others` | |

## Splits / window groups

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+\` Split Editor Right | `Ctrl+\` | `view.split_right` | Same VS Code chord. (`term.scratch_toggle` is now `` Ctrl+` `` only — the chords were colliding before 2026-06-08.) |
| `Ctrl+K Ctrl+\` Split Editor Down | (not bound) | `view.split_down` | Use `Ctrl+K Ss` |
| `Ctrl+1` `Ctrl+2` `Ctrl+3` Focus Group N | (not bound) | — | Use `Ctrl+K Sh/Sj/Sk/Sl` directional focus |
| `Ctrl+K Left/Right/Up/Down` Move Editor | (not bound under chord) | `view.move_split_*` | Palette |
| `Ctrl+W` (split context) Close Editor Group | (not bound separately) | `view.close_split` | Same chord as buffer close |
| Drag splitter to resize | (not bound) | `view.split_{grow,shrink}_{width,height}` | Palette / leader |
| `Ctrl+K =` Reset Editor Group Sizes | (not bound) | `view.equalize_splits` | Palette |

## Sidebar / file explorer

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+B` Toggle Sidebar | `Ctrl+B` | `view.toggle_tree` | |
| `Ctrl+Shift+E` Show Explorer | `Ctrl+Shift+E` | `view.focus_tree` | Focuses tree (unhides if hidden) |
| `Ctrl+Shift+F` Show Search | (not bound to view-show) | `view.activity_search` (palette) | Same chord starts a grep |
| `Ctrl+Shift+G` Show Source Control | (not bound under chord) | `view.activity_git` | Palette |
| `Ctrl+Shift+D` Show Debug | (not bound — `Ctrl+Shift+D` is duplicate-line) | `view.activity_debug` | Palette |
| `Ctrl+Shift+X` Show Extensions | (not bound — mnml has no extensions panel) | `integrations.add` | Discover overlay for family siblings |
| Click folder to expand | yes (mouse path works) | tree event | |
| Right-click → New File / New Folder | (no context menu) | palette `file.new` / `file.new_folder` | |
| Right-click → Reveal in Finder | (no context menu) | palette `view.reveal_active` | |
| Drag-drop to move file | (not bound) | — | SEV-3 |

## Command palette + which-key

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+Shift+P` Command Palette | `Ctrl+Shift+P` (also `F1`) | `palette` | |
| `F1` Command Palette | `F1` | `palette` / `view.help` | F1 toggles between palette + auto-generated help overlay |
| `Ctrl+P` Quick Open | `Ctrl+P` | `picker.files` | |
| `Ctrl+P @` Symbols | (not as modifier) | `Ctrl+Shift+O` instead | |
| `Ctrl+P #` Workspace Symbols | (not as modifier) | `lsp.workspace_symbols` palette | |
| `Ctrl+P :` Go to Line | (not as modifier) | `Ctrl+G` instead | |
| `Ctrl+K Ctrl+S` Keyboard Shortcuts | (not bound under chord) | `view.cheatsheet` | Palette; also `<leader>?` |

## Terminal

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `` Ctrl+` `` Toggle Terminal | `` Ctrl+` `` | `term.scratch_toggle` | Quick scratch strip at bottom. (`Ctrl+\` used to also fire this; that binding was dropped in #273 so VS-Code parity could land it on `view.split_right`.) |
| `Ctrl+T` New Terminal | `Ctrl+T` | `term.focus_or_open_shell` | Focus existing or open new |
| Terminal: New | (palette) | `term.shell` | New shell, splits below |
| Terminal: Rename | (palette) | `term.rename` | |
| `Ctrl+Shift+5` Split Terminal | (not bound under chord) | — | Use `term.shell` again to add a session |
| `Ctrl+PageUp/Down` (in terminal) Switch | same | `buffer.{next,prev}` | mnml's pty pane has its own tab strip |

## Source Control / Git

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+Shift+G` Source Control | (palette) | `view.activity_git` | |
| Stage selected (UI) | (UI in status pane) | `git.status_pane` | |
| `Ctrl+Enter` Commit (in SC view) | (palette) | `git.commit` | |
| Push (UI button) | (palette) | `git.push` | Auto `--set-upstream` on first push |
| Pull (UI button) | (palette) | `git.pull` | `--ff-only` |
| Fetch (UI button) | (palette) | `git.fetch` | `--all --prune` |
| `Alt+F5` / `Alt+F3` Next/Prev Change | (not bound to Alt+F-keys) | `git.jump_{next,prev}_change` | Use `]c` / `[c` in vim mode |
| Open File at Remote | (palette) | `git.browse` | GitHub / GitLab / Bitbucket / Azure DevOps |
| GitLens Blame | (palette / `<leader>gb`) | `git.blame_toggle` | |
| File History | (palette) | `git.file_history` | Commits touching this file |
| Diff with Working Tree | (palette / `<leader>gd`) | `git.diff_file` | |
| Stash (UI) | (palette / `<leader>gS`) | `git.stash` | |
| Stash Pop (UI) | (palette / `<leader>gP`) | `git.stash_pop` | |
| Reflog | (palette) | `git.reflog` | Pick entry → open commit diff |
| Tag | (palette) | `git.tag` / `git.push_tags` / `git.tag_delete` | |
| Undo Last Commit | (palette) | `git.undo` / `git.redo` | `reset --soft HEAD~1` / inverse |
| Cherry-Pick | (palette, from graph) | `git.cherry_pick` | From the selected graph commit |
| Revert Commit | (palette, from graph) | `git.revert` | |

## Debug (DAP)

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `F5` Start Debugging | `F5` | `dap.run` | |
| `Shift+F5` Stop / Continue | `Shift+F5` | `dap.continue` | Continue (resume from breakpoint); `dap.terminate` for stop |
| `F9` Toggle Breakpoint | `F9` | `dap.toggle_breakpoint` | |
| `Shift+F9` Conditional Breakpoint | `Shift+F9` | `dap.toggle_breakpoint_conditional` | |
| `F10` Step Over | `F10` | `dap.next` | |
| `F11` Step Into | `F11` | `dap.step_in` | |
| `Shift+F11` Step Out | `Shift+F11` | `dap.step_out` | |
| Pause | (palette) | `dap.pause` | |
| Debug Console | (palette) | `dap.repl` | Evaluate expressions |
| Watch Expressions | (palette) | `dap.{add,remove,clear}_watch` | |
| Reverse Continue | (palette) | `dap.reverse_continue` | Requires record-replay adapter |
| Step Backward | (palette) | `dap.step_back` | Requires record-replay adapter |
| Attach to Process | (palette) | `dap.attach` | |
| Exception Breakpoints | (palette) | `dap.exceptions` | |
| Hit Count Breakpoint | (palette) | `dap.set_breakpoint_hit_count` | |

## Tasks

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+Shift+B` Run Build Task | (not bound under chord) | `task.run` | `<leader>o` chord |
| Run Test | (palette / `<leader>Ta` etc.) | `test.run_*` | |
| Tasks: Configure | (palette) | — | Use `tasks` block in TOML — see Settings |

## AI (Copilot / Continue / etc. equivalents)

VS Code's AI is via extensions. mnml ships AI as first-class panes.

| VS Code AI workflow | mnml | Command id | Notes |
|---|---|---|---|
| Copilot inline suggest | (palette / config) | `ai.toggle_inline_suggestions` | Cursor-style ghost text |
| Copilot accept (Tab) | (not bound — Tab is indent) | — | SEV-3 — need a distinct chord for accept-suggestion |
| Copilot Chat | `<leader>aC` / palette | `ai.chat` | |
| Open Claude Code | `<leader>ac` / palette | `ai.claude_code` | Right dock |
| Open Codex | `<leader>ax` / palette | `ai.codex` | Right dock |
| Ask | `<leader>aa` | `ai.ask` | |
| Explain | `<leader>ae` | `ai.explain` | Selection or file |
| Fix | `<leader>af` | `ai.fix` | |
| Refactor | `<leader>ar` | `ai.refactor` | |
| Write Tests | `<leader>aw` | `ai.write_tests` | |
| Mirror live session | `<leader>am` | `ai.session_view` | |
| Cancel | (palette) | `ai.cancel` | |
| Apply Suggested Change | (palette) | `ai.apply` | |

## Settings + UI

| VS Code | mnml | Command id | Notes |
|---|---|---|---|
| `Ctrl+,` Settings | `Ctrl+,` | `file.open_settings` | Opens the TOML in a buffer |
| `Ctrl+K Ctrl+T` Color Theme | (palette / `<leader>tt`) | `theme.pick` | |
| Settings UI (overlay) | (palette) | `view.settings` | mnml's keyboard-driven schema overlay |
| `Ctrl+K Z` Zen Mode | `Ctrl+Shift+Z` | `view.zen` | Hide tree + bufferline + statusline |
| `Ctrl+L` Cursor Centered (vim style) | (vim mode: `zz`) | `view.cursor_to_center` | Standard mode rebinds `Ctrl+L` to redraw |
| `Ctrl+K Ctrl+0` Fold All | (palette) | `lsp.fold_all` | LSP server ranges |
| `Ctrl+K Ctrl+J` Unfold All | (palette) | `editor.unfold_all` | |
| Word Wrap (toggle) | (palette) | `view.toggle_wrap` | |
| Minimap (toggle) | (palette) | `view.toggle_scrollbar` | mnml has a scrollbar, not a minimap |
| Render Whitespace | (palette) | `view.toggle_whitespace` | |
| Bracket Pair Colorization | (palette) | `view.toggle_bracket_rainbow` | |
| Sticky Scroll | (palette) | `view.toggle_sticky_context` | |
| Color Column (Ruler) | (palette) | `view.toggle_color_column` | |
| Trailing Whitespace highlight | (palette) | `view.toggle_highlight_trailing_ws` | |
| Highlight word under cursor | (palette) | `view.toggle_highlight_word` | |
| Render markdown inline | (palette) | `view.toggle_render_markdown` | render-markdown.nvim style |
| TODO highlight | (palette) | `view.toggle_todo_highlight` | TODO / FIXME / HACK / XXX |
| Breadcrumb toggle | (palette) | `view.toggle_breadcrumb` | |
| Bufferline toggle | (palette) | `view.toggle_bufferline` | |
| Markdown Preview | `<leader>m` / palette | `markdown.preview` | Split |
| Reveal in Finder/Explorer | (palette) | `view.reveal_active` | |

## Browser / live preview (CDP)

VS Code uses Live Preview / Live Server extensions. mnml has CDP-driven Chrome control built-in.

| VS Code analog | mnml | Command id | Notes |
|---|---|---|---|
| Live Preview | `<leader>B` | `browser.open` | Spawns Chrome under CDP — console + nav + eval |
| Screenshot extension | (palette) | `browser.screenshot` | → `.mnml/screenshots/` |
| Print to PDF | (palette) | `browser.print_pdf` | |
| Cookie editor | (palette) | `browser.cookies` / `browser.edit_cookie` / `browser.delete_cookie` / `browser.add_cookie` | |
| Storage panel | (palette) | `browser.storage` / `browser.{edit,add,delete}_storage` | localStorage / sessionStorage |
| Network snapshot | (palette) | `browser.snapshot` / `browser.diff_snapshot` | Capture + compare |
| Device emulation | (palette) | `browser.device_picker` | Mobile UA + viewport |
| Performance panel | (palette) | `browser.perf` | Core Web Vitals |
| DOM picker | (palette) | `browser.dom` | Selectable nodes |
| URL history | (palette) | `browser.url_history` | Fuzzy pick |

## HTTP client

VS Code uses REST Client extension. mnml has an HTTP pane built-in (`.http` / `.curl` / `.rest` files).

| REST Client | mnml | Command id | Notes |
|---|---|---|---|
| Send Request (codelens) | `<leader>hs` / palette | `http.send` | |
| Copy as cURL | `<leader>hy` / palette | `http.copy_curl` | |
| Toggle response view | (palette) | `http.toggle_view` | Edit ⇄ Response |
| Copy response body | (palette) | `http.copy_response_body` | |
| Debug failing request | `<leader>hd` | `http.ai_debug` | Asks Claude |

## What VS Code ships that mnml does NOT

Honest gaps — either mnml hasn't implemented these, or the keyboard path exists but a mouse-only VS Code-shaped path is missing.

| VS Code feature | Status in mnml | Notes |
|---|---|---|
| `Ctrl+Click` go-to-definition | (not bound) | Use `F12` or `gd` — SEV-3 mouse-pathway gap |
| `Alt+Click` add cursor | (not bound) | Use `Ctrl+Alt+Down/Up` — SEV-3 |
| Drag tab to reorder | (not bound, palette only) | SEV-3 mouse-pathway gap |
| Middle-click tab to close | (not bound) | Use `Ctrl+W` — SEV-3 |
| Right-click context menus | (not implemented) | mnml has no context menus — SEV-3 across the board |
| Splitter drag to resize | (not bound) | Use `view.split_grow_*` palette commands — SEV-3 |
| `Ctrl+Shift+S` Save As | (not bound) | `:saveas <path>` in vim mode — SEV-3 |
| Settings UI (mouse-driven) | (keyboard-only `view.settings`) | mnml's settings overlay is keyboard-first |
| Extensions Marketplace | (no extensions; family integrations instead) | Use `integrations.add` |
| Notebook editor | (not implemented) | — |
| Outline view (sidebar) | (palette `outline.show` opens a pane) | Different shape from VS Code's sidebar pane |
| Problems panel (sidebar) | (palette `lsp.diagnostics` opens a pane) | Same data, different shape |
| Timeline view | use `git.file_history` | |
| Remote SSH | (not implemented) | mnml runs in your terminal — SSH to host first |
| GitHub Pull Requests extension | use `<leader>Pp` `pr.picker` | Cross-host (GitHub + GitLab + Bitbucket + Azure DevOps) |

## Source pointers

- `src/input/standard.rs` — the modeless input handler (Ctrl shortcuts, arrow motion)
- `src/command.rs` — every command + its default keyspecs
- `src/input/keymap.rs` — keyspec parser + the `Keymap` overlay engine
- `src/whichkey.rs` — `Ctrl+K` leader trie root
- `src/cheatsheet.rs` — the in-app cheatsheet pane

## Next

- [Coming from VS Code](/manual/coming-from-vscode/) — the narrative walkthrough
- [NvChad cheatsheet](/manual/cheatsheet-nvchad/) — the other-side reference
- [All chords](/manual/cheatsheet-all/) — one grid for every binding in every mode
- [Editing](/manual/editing/) — the two input handlers' architecture
- [Settings & configuration](/manual/settings/) — `[keys.*]` config overlays
