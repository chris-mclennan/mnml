---
title: All chords
description: One reference grid of every mnml binding — vim chord and standard chord side-by-side, grouped by domain.
---

This page lists every chord mnml ships, grouped by what the chord does. Each row shows the **vim** binding, the **standard** binding, and the **command id** mnml fires when either chord is pressed. When a chord doesn't exist for a given input style, the cell is `—`.

:::tip[When to use this page vs the per-style cheatsheets]
- Use [NvChad cheatsheet](/manual/cheatsheet-nvchad/) if you're a vim user and want NvChad chords on the left of every row.
- Use [VS Code cheatsheet](/manual/cheatsheet-vscode/) if you're a standard-mode user coming from VS Code.
- Use **this** page when you're learning all of mnml, when you're pair-programming with someone in the other style, or when you saw a chord in passing and don't know which handler it came from.
:::

:::note[Escape hatches]
Two chords always work regardless of which input handler is loaded — keep these in your back pocket and you can reach every command in mnml without learning anything else first.

- **`Ctrl+Shift+P`** (also `F1`) — command palette. Fuzzy search every command by title.
- **`:`** (vim mode) — the ex command line. Type the command id or one of the title-case aliases (e.g. `:Format`, `:Diagnostics`, `:Status`).
:::

## Reading the table

- **vim** = the chord under `input_style = "vim"` (NvChad-style). `<leader>` is `<space>` in vim Normal mode.
- **standard** = the chord under `input_style = "standard"` (modeless / VS Code-style). The standard leader is `Ctrl+K`.
- A chord ending in `…` means it's a prompt or picker that opens with the chord.
- A "`same`" entry means vim and standard share the chord (the global keymap routes it before the handler sees it).
- `Ctrl+X` is `Cmd+X` on macOS for whichever chords your terminal forwards. mnml writes `Ctrl` throughout because that's what crossterm sees.

## File ops

| Action | vim | standard | Command id |
|---|---|---|---|
| New file (prompt) | `:enew` / `:e <path>` | `Ctrl+N` | `file.new` |
| Open file picker | `<leader>ff` / `Ctrl+P` | `Ctrl+P` | `picker.files` |
| Open recent picker | `Ctrl+R` | `Ctrl+R` | `picker.recent` |
| Save | `<leader>w` / `:w` / `Ctrl+S` | `Ctrl+S` | `file.save` |
| Save all | `:wa` / `:wall` | — | `file.save_all` |
| Save as (copy) | `:saveas <path>` | — | (vim ex only) |
| Reload from disk | `:reload` | (palette) | `file.reload` |
| Close buffer | `<leader>q` / `<leader>bd` / `:bd` | `Ctrl+W` | `buffer.close` |
| Reopen closed buffer | `<leader>br` | `Ctrl+Shift+T` | `buffer.reopen` |
| Open settings TOML | `Ctrl+,` | `Ctrl+,` | `file.open_settings` |
| Open settings overlay | (palette) | (palette) | `view.settings` |

## Buffers & tabs

| Action | vim | standard | Command id |
|---|---|---|---|
| Next buffer | `:bn` / `<leader>bn` | `Ctrl+PageDown` | `buffer.next` |
| Previous buffer | `:bp` / `<leader>bp` | `Ctrl+PageUp` | `buffer.prev` |
| Last buffer (toggle) | `Ctrl+6` | `Ctrl+Tab` / `Ctrl+6` | `buffer.last` |
| Buffer picker | `:b <name>` | `Ctrl+P` | `picker.buffers` / `picker.files` |
| List buffers | `:ls` / `:buffers` | (palette) | `picker.buffers` |
| New tab page | `:tabnew` / `:tabe` | (palette) | `tab.new` |
| Next tab | `gt` / `:tabnext` | (palette) | `tab.next` |
| Previous tab | `gT` / `:tabprev` | (palette) | `tab.prev` |
| First / last tab | `:tabfirst` / `:tablast` | (palette) | `tab.first` / `tab.last` |
| Close tab | `:tabclose` | (palette) | `tab.close` |
| Close other tabs | `:tabonly` | (palette) | `tab.only` |
| Focus tab N | `<leader>1`…`<leader>9` (harpoon) | `Alt+1`…`Alt+9` | `tab.goto_N` |

## Splits

| Action | vim | standard | Command id |
|---|---|---|---|
| Split right (vertical) | `<leader>sv` / `:vsp` / `Ctrl+W v` | `Ctrl+K Sv` | `view.split_right` |
| Split down (horizontal) | `<leader>ss` / `:sp` / `Ctrl+W s` | `Ctrl+K Ss` | `view.split_down` |
| Focus left | `Ctrl+W h` / `<leader>sh` | `Ctrl+K Sh` | `view.focus_left` |
| Focus down | `Ctrl+W j` / `<leader>sj` | `Ctrl+K Sj` | `view.focus_down` |
| Focus up | `Ctrl+W k` / `<leader>sk` | `Ctrl+K Sk` | `view.focus_up` |
| Focus right | `Ctrl+W l` / `<leader>sl` | `Ctrl+K Sl` | `view.focus_right` |
| Cycle focus | `Ctrl+W w` / `<leader>sw` | `Ctrl+K Sw` | `view.focus_next_split` |
| Close split | `Ctrl+W c` / `<leader>sc` | `Ctrl+K Sc` | `view.close_split` |
| Close other splits | `Ctrl+W o` / `:only` / `<leader>so` | `Ctrl+K So` | `view.close_others` |
| Equalize splits | `Ctrl+W =` | (palette) | `view.equalize_splits` |
| Maximize height | `Ctrl+W _` | (palette) | `view.maximize_height` |
| Maximize width | `Ctrl+W |` | (palette) | `view.maximize_width` |
| Grow / shrink height | `Ctrl+W +` / `Ctrl+W -` | (palette) | `view.split_grow_height` / `view.split_shrink_height` |
| Grow / shrink width | `Ctrl+W >` / `Ctrl+W <` | (palette) | `view.split_grow_width` / `view.split_shrink_width` |
| Rotate splits | `Ctrl+W r` | (palette) | `view.rotate_splits` |
| Move split direction | `Ctrl+W H/J/K/L` | (palette) | `view.move_split_*` |
| Promote split to tab | `Ctrl+W T` | (palette) | `view.move_to_new_tab` |
| Split + go to def | `Ctrl+W d` | (palette) | `view.split_goto_definition` |
| Split + open path under cursor | `Ctrl+W f` / `gf` | (palette) | `view.split_open_file_under_cursor` |
| Split + scratch buffer | `Ctrl+W n` | (palette) | `view.split_new_scratch` |

## File rail & activity bar

| Action | vim | standard | Command id |
|---|---|---|---|
| Toggle file rail | `<leader>e` / `<leader>te` | `Ctrl+B` | `view.toggle_tree` |
| Focus file rail | (palette) | `Ctrl+Shift+E` | `view.focus_tree` |
| Cycle focus tree ⇄ editor | `Ctrl+E` | `Ctrl+E` | `focus.cycle` |
| Toggle hidden files (focused tree) | `<leader>th` | (palette) | `view.toggle_hidden` |
| Toggle hidden files (all trees) | `<leader>tH` | (palette) | `view.toggle_hidden_all` |
| Reveal active file | (palette) | (palette) | `view.reveal_active` |

## Cursor motion

These are the chords most likely to differ between handlers. The vim handler interprets `hjkl`, word motion, and operators directly; the standard handler uses arrow keys, Ctrl+arrow, Home/End, PageUp/Down.

| Action | vim | standard | Command id / source |
|---|---|---|---|
| Left / right / up / down | `h` / `l` / `k` / `j` | `←` / `→` / `↑` / `↓` | `edit_op::Move*` |
| Word forward / back | `w` / `b` (variants `e`, `ge`, `W`, `B`, `E`) | `Ctrl+→` / `Ctrl+←` | `edit_op::MoveWord*` |
| Line start / end | `0` / `^` / `$` / `g_` | `Home` / `End` | `edit_op::MoveLine{Start,End}` |
| Buffer start / end | `gg` / `G` | `Ctrl+Home` / `Ctrl+End` | `edit_op::MoveBuffer{Start,End}` |
| Page up / down | `Ctrl+B` / `Ctrl+F` | `PageUp` / `PageDown` | `edit_op::Page{Up,Down}` |
| Half-page up / down | `Ctrl+U` / `Ctrl+D` | — | `vim.rs` |
| Go to line N | `nG` / `:N` | `Ctrl+G` | `editor.goto_line` |
| Viewport top / middle / bottom | `H` / `M` / `L` | (palette) | `view.move_cursor_view_*` |
| Scroll cursor to top / middle / bottom | `zt` / `zz` / `zb` | (palette) | `view.cursor_to_*` |
| Scroll one line up / down | `Ctrl+Y` / `Ctrl+E` | (palette) | `view.scroll_buffer_*` |
| Horizontal scroll | `zh` / `zl` / `zH` / `zL` | (palette) | `view.hscroll_*` |
| Char find on line | `f<c>` / `F<c>` / `t<c>` / `T<c>` / `;` / `,` | — | `vim.rs` |
| Matching bracket | `%` | (palette) | `editor.bracket_match` |
| Paragraph / sentence nav | `{` / `}` / `(` / `)` | — | `vim.rs` |
| Last jump | `''` / `` `` `` | — | `vim.rs` |
| Jumplist back / forward | `Ctrl+O` / `Ctrl+I` | `Alt+←` / `Alt+→` | `nav.back` / `nav.forward` |
| Changelist back / forward | `g;` / `g,` | (palette) | `editor.jump_{prev,next}_edit` |

## Editing

| Action | vim | standard | Command id |
|---|---|---|---|
| Cut | `d` / `dd` / `D` / `x` (vim operators) | `Ctrl+X` | `edit_op::CutSelection` |
| Copy / yank | `y` / `yy` / `Y` | `Ctrl+C` | `edit_op::YankSelection` / `YankLine` |
| Paste | `p` / `P` | `Ctrl+V` | `edit_op::Paste` |
| Undo | `u` | `Ctrl+Z` | `edit_op::Undo` |
| Redo | `Ctrl+R` | `Ctrl+Shift+Z` / `Ctrl+Y` | `edit_op::Redo` |
| Select all | `ggVG` | `Ctrl+A` | `edit_op::SelectAll` |
| Select line | `V` | `Ctrl+L` | `edit_op::SelectLine` |
| Add cursor at next word match | (operator-pending) | `Ctrl+D` | `editor.add_cursor_at_next_word` |
| Select all occurrences | (palette) | `Ctrl+Shift+L` | `editor.select_all_occurrences` |
| Delete line | `dd` | `Ctrl+Shift+K` | `editor.delete_line` |
| Duplicate line | `yyp` | `Ctrl+Shift+D` | `edit_op::DuplicateLine` |
| Move line up / down | (palette) | `Alt+↑` / `Alt+↓` (also `Alt+K` / `Alt+J`) | `editor.move_line_{up,down}` |
| Indent / outdent | `>>` / `<<` / `>` / `<` (operators) | `Tab` / `Shift+Tab` | `edit_op::Indent` / `Outdent` |
| Toggle line comment | `Ctrl+/` | `Ctrl+/` | `edit_op::ToggleLineComment` |
| Insert line below / above | `o` / `O` | `Ctrl+Enter` / `Ctrl+Shift+Enter` | (custom) |
| Delete word left / right | (operator-pending) | `Ctrl+Backspace` / `Ctrl+Delete` | `edit_op::DeleteWordLeft` / `DeleteWordRight` |
| Reflow paragraph | `gq` / `gqq` / `gqap` / `gqip` | (palette) | `editor.reflow_paragraph` |
| Join lines (with / without space) | `J` / `gJ` | (palette) | `vim.rs` |
| Case toggle / upper / lower | `~` / `gU` / `gu` | (palette) | `vim.rs` |
| Add cursor above / below | (palette) | `Ctrl+Alt+↑` / `Ctrl+Alt+↓` (also `Ctrl+Alt+K` / `Ctrl+Alt+J`) | `editor.add_cursor_{above,below}` |
| Clear extra cursors | `Esc` (drops selection too) | `Esc` | `editor.clear_extra_cursors` |
| Dot repeat | `.` | — | `vim.dot_repeat` |
| Macros: record / replay | `qa…q` / `@a` / `@@` / `n@a` | — | `vim.macro_{toggle,replay}` |
| Named registers | `"ay` / `"ap` / `"+y` / `"+p` / `"0p` | — | `vim.rs` |
| Marks: set / jump | `ma` / `'a` / `` `a `` | — | `vim.rs` |
| Char info / utf-8 info | `ga` / `g8` | (palette) | `editor.char_info` / `editor.char_utf8` |
| File info / stats | `Ctrl+G` / `g Ctrl+G` | (palette) | `editor.file_info` / `editor.file_stats` |
| Repeat last `:s` | `&` / `:&` | — | `editor.repeat_last_substitute` |
| Toggle fold | `za` | (palette) | `editor.toggle_fold` |
| Unfold all | `zR` | (palette) | `editor.unfold_all` |
| Fold all (LSP ranges) | (palette) | (palette) | `lsp.fold_all` |

### Text objects (vim only)

These are operator-pending objects — type them after `d`, `c`, `y`, `v`, etc.

| Object | Chord | Notes |
|---|---|---|
| Word (inner / around) | `iw` / `aw` | |
| Bracket / paren / quote (inner / around) | `i(` / `a(` / `i"` / `a"` | also `i{`, `i[`, `i<`, `i'`, `` i` `` |
| Paragraph | `ip` / `ap` | |
| Sentence | `is` / `as` | |
| Function (tree-sitter) | `if` / `af` | |
| Class (tree-sitter) | `ic` / `ac` | |
| Parameter / argument (tree-sitter) | `ia` / `aa` | |
| Conditional (tree-sitter) | `ii` / `ai` | |

## Search

| Action | vim | standard | Command id |
|---|---|---|---|
| Find forward (prompt) | `/` | `Ctrl+F` | `find.find` |
| Find backward (prompt) | `?` | (palette) | `find.find_backward` |
| Next / prev match | `n` / `N` | `F3` / `Shift+F3` | `find.next` / `find.prev` |
| Word under cursor (forward / back) | `*` / `#` | (palette) | `find.word_{forward,backward}` |
| Partial word under cursor | `g*` / `g#` | (palette) | `vim.rs` |
| Select next / prev match | `gn` / `gN` | (palette) | `find.select_match_{forward,backward}` |
| Clear find highlight | `:noh` / `:nohlsearch` | (palette) | `find.clear` |
| Toggle regex (in find prompt) | `Alt+R` | `Alt+R` | `find.toggle_regex` |
| Replace (in current buffer) | `:%s/old/new/g` / `:%s/old/new/gc` | `Ctrl+H` | `find.replace` |
| Workspace grep | `:Rg <pat>` / `:Ag` / `:grep` / `:vimgrep` | `Ctrl+Shift+F` | `find.grep` |
| Replace across workspace | (results pane) | (results pane) | `find.grep_replace` |
| Quickfix next / prev | `:cn` / `:cp` | (palette) | `qf.next` / `qf.prev` |
| Quickfix first / last | `:cfirst` / `:clast` | (palette) | `qf.first` / `qf.last` |
| Open / close quickfix pane | `:copen` / `:cclose` | (palette) | `vim.rs` |

## LSP

| Action | vim | standard | Command id |
|---|---|---|---|
| Code action | `<leader>la` | `Ctrl+.` | `lsp.code_action` |
| Apply first quick fix | (palette) | `Alt+Enter` | `lsp.quick_fix` |
| Trigger completion | `<leader>lc` / `Ctrl+Space` | `Ctrl+Space` | `lsp.completion` |
| Symbols in file | `<leader>ls` | `Ctrl+Shift+O` | `lsp.symbols` |
| Workspace symbols | `<leader>lS` | (palette) | `lsp.workspace_symbols` |
| Outline pane | `<leader>lo` | (palette) | `outline.show` |
| Go to definition | `gd` / `<leader>ld` / `F12` | `F12` | `lsp.goto_definition` |
| Go to declaration | `gD` | (palette) | `lsp.goto_declaration` |
| Go to implementation | (palette) | (palette) | `lsp.goto_implementation` |
| Hover docs | `K` / `<leader>lh` | (palette) | `lsp.hover` |
| Find references | `gr` / `<leader>lr` | (palette) | `lsp.references` |
| Rename symbol | `<leader>lR` | (palette) | `lsp.rename` |
| Diagnostics list | `<leader>le` | (palette) | `lsp.diagnostics` |
| Next / prev diagnostic | `<leader>ln` / `<leader>lp` | (palette / Ctrl+K leader) | `lsp.next_diagnostic` / `lsp.prev_diagnostic` |
| Format document | `Ctrl+Shift+I` | `Ctrl+Shift+I` | `lsp.format` (falls back to `editor.format`) |
| Organize imports | `Alt+Shift+O` | `Alt+Shift+O` | `lsp.organize_imports` |
| Open URL under cursor (OS browser) | `gx` | (palette) | `editor.open_url_at_cursor` |
| Open path under cursor | `gf` | (palette) | `editor.open_at_cursor` |

## Git

| Action | vim | standard | Command id |
|---|---|---|---|
| Status / staging pane | `<leader>gs` | (palette) | `git.status_pane` |
| Commit (editor for staged) | `<leader>gc` | (palette) | `git.commit` |
| AI (Claude) commit message | `<leader>gm` | (palette) | `git.ai_commit` |
| AI rewrite HEAD message | `<leader>gM` | (palette) | `git.ai_recompose` |
| Codex commit message | `<leader>gx` | (palette) | `git.codex_commit` |
| Blame toggle | `<leader>gb` | (palette) | `git.blame_toggle` |
| Diff active file | `<leader>gd` | (palette) | `git.diff_file` |
| Diff worktree | `<leader>gD` | (palette) | `git.diff` |
| Diff all vs HEAD | `<leader>gA` | (palette) | `git.diff_all` |
| Peek change at cursor | `<leader>gp` | (palette) | `git.peek_change` |
| Commit graph (DAG) | `<leader>gl` | (palette) | `git.graph` |
| Checkout branch | `<leader>go` | (palette) | `git.checkout` |
| New branch | `<leader>gn` | (palette) | `git.new_branch` |
| Worktrees → shell | `<leader>gw` | (palette) | `git.worktrees` |
| Stash (with optional msg) | `<leader>gS` | (palette) | `git.stash` |
| Stash pop | `<leader>gP` | (palette) | `git.stash_pop` |
| Next / prev change hunk | `]c` / `[c` | (palette) | `git.jump_next_change` / `git.jump_prev_change` |
| Next / prev file in diff | `]f` / `[f` | (palette) | `git.diff_next_file` / `git.diff_prev_file` |
| Push | (palette) | (palette) | `git.push` |
| Pull (`--ff-only`) | (palette) | (palette) | `git.pull` |
| Fetch (`--all --prune`) | (palette) | (palette) | `git.fetch` |
| Reflog picker | (palette) | (palette) | `git.reflog` |
| File history | (palette) | (palette) | `git.file_history` |
| Open in remote (host browser) | (palette) | (palette) | `git.browse` |
| Cherry-pick (from graph) | (palette) | (palette) | `git.cherry_pick` |
| Revert (from graph) | (palette) | (palette) | `git.revert` |
| Undo / redo last commit | (palette) | (palette) | `git.undo` / `git.redo` |
| Tag / push tags / delete tag | (palette) | (palette) | `git.tag` / `git.push_tags` / `git.tag_delete` |

## Tasks & tests

| Action | vim | standard | Command id |
|---|---|---|---|
| Run task | `<leader>o` | (palette) | `task.run` |
| Run all tests | `<leader>Ta` | (palette) | `test.run_all` |
| Run tests in this file | `<leader>Tf` | (palette) | `test.run_file` |
| Run test at cursor | `<leader>Tt` | (palette) | `test.run_at_cursor` |
| Rerun last-failed | `<leader>Tl` | (palette) | `test.rerun_failed` |
| Heal failing test (Claude) | `<leader>Th` | (palette) | `test.heal` |
| Flaky / wobbly dashboard | `<leader>Tw` | (palette) | `flaky.show` |

## Debug (DAP)

| Action | vim | standard | Command id |
|---|---|---|---|
| Start debugging | `F5` | `F5` | `dap.run` |
| Continue | `Shift+F5` | `Shift+F5` | `dap.continue` |
| Toggle breakpoint | `F9` | `F9` | `dap.toggle_breakpoint` |
| Conditional breakpoint | `Shift+F9` | `Shift+F9` | `dap.toggle_breakpoint_conditional` |
| Step over / into / out | `F10` / `F11` / `Shift+F11` | `F10` / `F11` / `Shift+F11` | `dap.next` / `dap.step_in` / `dap.step_out` |
| Pause | (palette) | (palette) | `dap.pause` |
| Debug console (REPL) | (palette) | (palette) | `dap.repl` |
| Watch expressions | (palette) | (palette) | `dap.{add,remove,clear}_watch` |
| Reverse continue / step back | (palette) | (palette) | `dap.reverse_continue` / `dap.step_back` |
| Attach to process | (palette) | (palette) | `dap.attach` |
| Set hit-count / exception breakpoints | (palette) | (palette) | `dap.set_breakpoint_hit_count` / `dap.exceptions` |

## Terminal

| Action | vim | standard | Command id |
|---|---|---|---|
| Scratch terminal toggle (bottom strip) | `` Ctrl+` `` / `Ctrl+\` | `` Ctrl+` `` / `Ctrl+\` | `term.scratch_toggle` |
| Focus existing or open new shell | `Ctrl+T` | `Ctrl+T` | `term.focus_or_open_shell` |
| Shell as a pane | `<leader>at` / `:term` / `:terminal` | (palette) | `term.shell` |
| Rename pty tab | (palette) | (palette) | `term.rename` |
| Pop pty into tmnl (transfer fd) | `:tmnl.pop-pty` / `:tmnl.pop` | (palette) | `tmnl.pop_pty` |

## AI

| Action | vim | standard | Command id |
|---|---|---|---|
| Ask Claude | `<leader>aa` | (palette) | `ai.ask` |
| Explain selection / file | `<leader>ae` | (palette) | `ai.explain` |
| Fix bugs | `<leader>af` | (palette) | `ai.fix` |
| Refactor | `<leader>ar` | (palette) | `ai.refactor` |
| Write tests | `<leader>aw` | (palette) | `ai.write_tests` |
| Mirror live Claude session | `<leader>am` | (palette) | `ai.session_view` |
| Claude Code dock | `<leader>ac` | (palette) | `ai.claude_code` |
| Claude chat (with context) | `<leader>aC` | (palette) | `ai.chat` |
| Codex dock | `<leader>ax` | (palette) | `ai.codex` |
| Mixr DJ split | `<leader>aM` | (palette) | `mixr.show` |
| Cancel running AI request | (palette) | (palette) | `ai.cancel` |
| Apply suggested change | (palette) | (palette) | `ai.apply` |
| Toggle inline ghost-text suggestions | (palette) | (palette) | `ai.toggle_inline_suggestions` |

## HTTP client

| Action | vim | standard | Command id |
|---|---|---|---|
| Send request | `<leader>hs` | (palette) | `http.send` |
| Copy as `curl` | `<leader>hy` | (palette) | `http.copy_curl` |
| Ask Claude to debug request | `<leader>hd` | (palette) | `http.ai_debug` |
| Toggle response view | (palette) | (palette) | `http.toggle_view` |
| Copy response body | (palette) | (palette) | `http.copy_response_body` |

## Browser (CDP)

| Action | vim | standard | Command id |
|---|---|---|---|
| Open browser (Chrome under CDP) | `<leader>B` | (palette) | `browser.open` |
| Screenshot | (palette) | (palette) | `browser.screenshot` |
| Print to PDF | (palette) | (palette) | `browser.print_pdf` |
| Cookies (list / edit / add / delete) | (palette) | (palette) | `browser.cookies` / `browser.{edit,add,delete}_cookie` |
| Storage (localStorage / sessionStorage) | (palette) | (palette) | `browser.storage` / `browser.{edit,add,delete}_storage` |
| Network snapshot / diff | (palette) | (palette) | `browser.snapshot` / `browser.diff_snapshot` |
| Device emulation picker | (palette) | (palette) | `browser.device_picker` |
| Performance (Core Web Vitals) | (palette) | (palette) | `browser.perf` |
| DOM picker | (palette) | (palette) | `browser.dom` |
| URL history picker | (palette) | (palette) | `browser.url_history` |

## Harpoon

| Action | vim | standard | Command id |
|---|---|---|---|
| Pin active file | `<leader>Ha` | (palette) | `harpoon.add` |
| Menu / picker over pins | `<leader>Hm` | (palette) | `harpoon.menu` |
| Jump to pin N (1–9) | `<leader>1`…`<leader>9` | (palette) | `harpoon.goto_N` |

## Snippets

| Action | vim | standard | Command id |
|---|---|---|---|
| Snippet picker | `<leader>Is` | (palette) | `snippet.pick` |
| Expand snippet at cursor | `<leader>Ix` / `Ctrl+J` | `Ctrl+J` | `snippet.expand` |

## Cross-host PRs

| Action | vim | standard | Command id |
|---|---|---|---|
| PR fuzzy picker (GH + GL + BB + Az) | `<leader>Pp` | (palette) | `pr.picker` |
| Refresh cross-host cache | `<leader>Pr` | (palette) | `pr.refresh` |

## Integrations (sibling binaries)

Each chord launches the matching `mnml-*` sibling binary as a tab. The sibling must be installed and visible to mnml's [integration detector](/manual/integrations/installing/) — otherwise the rail chip is hidden.

| Sibling | vim | standard | Command id |
|---|---|---|---|
| Bitbucket forge viewer | `<leader>ib` | (palette) | `forge.open_bitbucket` |
| GitHub forge viewer | `<leader>ig` | (palette) | `forge.open_github` |
| GitLab forge viewer | `<leader>il` | (palette) | `forge.open_gitlab` |
| Azure DevOps forge viewer | `<leader>iz` | (palette) | `forge.open_azdevops` |
| Jira ticket viewer | `<leader>ij` | (palette) | `forge.open_jira` |
| AWS CodeBuild | `<leader>ic` | (palette) | `forge.open_codebuild` |
| AWS CloudWatch Logs | `<leader>iw` | (palette) | `forge.open_cloudwatch_logs` |
| AWS Amplify | `<leader>ia` | (palette) | `forge.open_amplify` |
| AWS Lambda | `<leader>iL` | (palette) | `forge.open_lambda` |
| AWS EventBridge | `<leader>ie` | (palette) | `forge.open_eventbridge` |
| AWS RDS | `<leader>iR` | (palette) | `forge.open_rds` |
| AWS ECS | `<leader>iC` | (palette) | `forge.open_ecs` |
| AWS ECR | `<leader>iE` | (palette) | `forge.open_ecr` |
| AWS Cognito | `<leader>io` | (palette) | `forge.open_cognito` |
| AWS SQS | `<leader>iq` | (palette) | `forge.open_sqs` |
| AWS SNS | `<leader>iN` | (palette) | `forge.open_sns` |
| Amazon S3 browser | `<leader>is` | (palette) | `forge.open_s3` |
| Azure Blob Storage browser | `<leader>iA` | (palette) | `forge.open_azure_blob` |
| DynamoDB browser | `<leader>id` | (palette) | `forge.open_dynamodb` |
| Datadog | `<leader>iD` | (palette) | `forge.open_datadog` |
| Buttondown newsletter | `<leader>iB` | (palette) | `forge.open_buttondown` |
| Slack browse + post | `<leader>iS` | (palette) | `forge.open_slack` |
| Microsoft Teams | `<leader>iT` | (palette) | `forge.open_teams` |
| Mandrill email | `<leader>iM` | (palette) | `forge.open_mandrill` |
| Docker containers | `<leader>iK` | (palette) | `forge.open_docker` |
| Gmail browse + send | `<leader>iG` | (palette) | `forge.open_gmail` |
| Cloudflare CDN | `<leader>iF` | (palette) | `forge.open_cloudflare` |
| Tattle inbox (internal) | `<leader>it` | (palette) | `forge.open_tattle_inbox` |
| htop | `<leader>ih` | (palette) | `tools.htop` |
| iftop | `<leader>iI` | (palette) | `tools.iftop` |
| Add-integration overlay | (rail `+` chip) | (rail `+` chip) | `integrations.add` |
| Refresh detection cache | (palette) | (palette) | `integrations.refresh` |

## UI toggles

| Action | vim | standard | Command id |
|---|---|---|---|
| Command palette | `<leader>p` / `Ctrl+Shift+P` / `F1` | `Ctrl+Shift+P` / `F1` | `palette` |
| Cheatsheet pane (live) | `<leader>?` | (palette) | `view.cheatsheet` |
| Help overlay | `F1` (toggle with palette) | `F1` | `view.help` |
| Theme picker | `<leader>tt` | (palette) | `theme.pick` |
| Vim ⇄ standard runtime swap | `<leader>tk` / `:set input=vim` / `:set input=standard` | `<leader>tk` (via `Ctrl+K`) | `editor.toggle_keymap` |
| Zen mode (hide tree + bufferline + statusline) | (palette) | `Ctrl+Shift+Z` | `view.zen` |
| Redraw | `Ctrl+L` | (palette) | `view.redraw` |
| Word wrap | (palette) | (palette) | `view.toggle_wrap` |
| Scrollbar | (palette) | (palette) | `view.toggle_scrollbar` |
| Whitespace render | (palette) | (palette) | `view.toggle_whitespace` |
| Bracket rainbow | (palette) | (palette) | `view.toggle_bracket_rainbow` |
| Sticky context | (palette) | (palette) | `view.toggle_sticky_context` |
| Color column / ruler | (palette) | (palette) | `view.toggle_color_column` |
| Trailing whitespace highlight | (palette) | (palette) | `view.toggle_highlight_trailing_ws` |
| Highlight word under cursor | (palette) | (palette) | `view.toggle_highlight_word` |
| Render markdown inline | (palette) | (palette) | `view.toggle_render_markdown` |
| TODO highlight | (palette) | (palette) | `view.toggle_todo_highlight` |
| Breadcrumb bar | (palette) | (palette) | `view.toggle_breadcrumb` |
| Bufferline | (palette) | (palette) | `view.toggle_bufferline` |
| Relative line numbers | (palette) | (palette) | `view.toggle_relative_numbers` |
| Markdown preview | `<leader>m` | (palette) | `markdown.preview` |
| Restart mnml (rebuild via run.sh) | `<leader>r` | (palette) | `app.restart` |

## Source pointers

If a chord in this page is wrong or out of date, these are the files that define the truth:

- `src/whichkey.rs` — the `<leader>` trie (vim mode `<space>`, standard mode `Ctrl+K`)
- `src/input/vim.rs` — every vim chord plus the ex-command set
- `src/input/standard.rs` — every standard-mode Ctrl / Alt / arrow chord
- `src/input/keymap.rs` — the global `Keymap` overlay that resolves chords before they reach the handler
- `src/command.rs` — the canonical command registry (every command id and its default keyspecs)
- `src/cheatsheet.rs` — the in-app cheatsheet pane (always live for your current keymap)

## Next

- [NvChad cheatsheet](/manual/cheatsheet-nvchad/) — same data, sorted around NvChad chords with migration notes
- [VS Code cheatsheet](/manual/cheatsheet-vscode/) — same data, sorted around VS Code chords with migration notes
- [Editing](/manual/editing/) — the input-handler architecture behind the two columns above
- [Settings & configuration](/manual/settings/) — how `[keys.*]` config overlays customize any chord on this page
- [Coming from NvChad](/manual/coming-from-nvchad/) / [Coming from VS Code](/manual/coming-from-vscode/) — the narrative walkthroughs
