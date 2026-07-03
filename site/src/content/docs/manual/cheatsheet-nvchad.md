---
title: NvChad cheatsheet
description: Every NvChad / vim chord you have in muscle memory mapped to its mnml equivalent. Printable, scannable, exhaustive.
---

This is the **reference**. NvChad chord on the left, mnml chord on the right, the command id mnml fires in the middle. For the narrative migration walkthrough — what mnml ships, what's renamed, what's intentionally missing — see [Coming from NvChad](/manual/coming-from-nvchad/). For the live in-app cheatsheet that walks your current keymap, open the pane with `<leader>?` or the palette command `view.cheatsheet`.

:::tip[How to use this page]
- Use your browser's find (`Ctrl+F` / `Cmd+F`) to grep for a chord, a command id, or an action verb.
- Rows marked `(not bound)` are honest about chords NvChad has that mnml does not — either the feature exists under a different chord, or the feature isn't here yet.
- mnml ships in **vim** mode by default if you set `[editor] input_style = "vim"`. Without that flag every Ctrl shortcut you see for VS Code-style users is also live in vim mode (mnml's `Keymap` overlays both layers).
- Vim mode reserves `Ctrl+W`, `Ctrl+G`, `Ctrl+D`, `Ctrl+U` for vim's window / file-info / half-page chords — the global keymap removes those so vim semantics win.
:::

## Modes, motions, operators

These work as vim built-ins — no remapping is involved, the vim input handler interprets them directly.

| NvChad / vim chord | mnml chord | Source | Notes |
|---|---|---|---|
| `i` `I` `a` `A` `o` `O` `s` `S` `R` | same | `vim.rs` | Insert variants |
| `Esc` / `Ctrl+[` | same | `vim.rs` | Back to Normal |
| `v` `V` `Ctrl+V` | same | `vim.rs` | Visual / line / block |
| `hjkl` | same | `vim.rs` | Cursor |
| `w` `b` `e` `ge` `W` `B` `E` | same | `vim.rs` | Word motion |
| `0` `^` `$` `g_` | same | `vim.rs` | Line ends |
| `gg` `G` `nG` | same | `vim.rs` | Buffer ends |
| `Ctrl+D` `Ctrl+U` | same | `vim.rs` | Half-page |
| `Ctrl+F` `Ctrl+B` | same | `vim.rs` | Full-page |
| `H` `M` `L` | same | `view.move_cursor_view_*` | Viewport top/mid/bottom |
| `zz` `zt` `zb` | same | `view.cursor_to_*` | Scroll cursor in viewport |
| `Ctrl+E` `Ctrl+Y` | same | `view.scroll_buffer_*` | Scroll one line |
| `f<c>` `F<c>` `t<c>` `T<c>` `;` `,` | same | `vim.rs` | Char find on line |
| `%` | same | `editor.bracket_match` | Matching bracket |
| `{` `}` | same | `vim.rs` | Paragraph nav |
| `(` `)` | same | `vim.rs` | Sentence nav |
| `*` `#` | same | `find.word_{forward,backward}` | Word under cursor |
| `g*` `g#` | same | `vim.rs` | Partial-word variant |
| `''` `` `` `` | same | `vim.rs` | Last jump |
| `Ctrl+O` `Ctrl+I` | same | `vim.rs` | Jumplist |
| `g;` `g,` | same | `editor.jump_{prev,next}_edit` | Changelist |
| `d` `c` `y` `>` `<` `=` | same | `vim.rs` | Operators |
| `dd` `yy` `cc` `D` `Y` `C` | same | `vim.rs` | Line / from-cursor |
| `gU` `gu` `~` | same | `vim.rs` | Case toggle |
| `gq` `gqq` `gqap` `gqip` | same | `editor.reflow_paragraph` | Reflow to `text_width` |
| `gJ` `J` | same | `vim.rs` | Join (no-space / space) |
| `iw` `aw` `i(` `a(` `i"` `a"` `ip` `ap` `is` `as` | same | `vim.rs` | Text objects |
| `if` `af` `ic` `ac` `ia` `aa` `ii` `ai` | same | `vim.rs` | Tree-sitter text objects |
| `.` | same | `vim.dot_repeat` | Dot-repeat |
| `u` `Ctrl+R` | same | `vim.rs` | Undo / redo |
| `qa` … `q` `@a` `@@` `n@a` | same | `vim.macro_{toggle,replay}` | Macros |
| `"ay` `"ap` `"+y` `"+p` `"0p` | same | `vim.rs` | Named / system / yank registers |
| `ma` `'a` `` `a `` | same | `vim.rs` | Marks |
| `gd` | same | `lsp.goto_definition` | LSP |
| `gD` | same | `lsp.goto_declaration` | LSP |
| `K` | same | `lsp.hover` | LSP hover popup |
| `gr` | same | `lsp.references` | LSP refs picker |
| `gi` | same | `vim.go_to_last_insert` | Last insert position |
| `gx` | same | `editor.open_url_at_cursor` | Open URL in OS browser |
| `gf` | same | `view.split_open_file_under_cursor` | Open path under cursor |
| `ga` `g8` | same | `editor.char_info` / `editor.char_utf8` | Char info |
| `Ctrl+G` `g Ctrl+G` | same | `editor.file_info` / `editor.file_stats` | File info / stats |
| `&` | same | `editor.repeat_last_substitute` | Repeat last `:s` |
| `gn` `gN` | same | `find.select_match_{forward,backward}` | Select next/prev find match |

## Search

| NvChad / vim chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `/` | same | `find.find` | Forward find prompt |
| `?` | same | `find.find_backward` | Reverse find prompt |
| `n` `N` | same | `find.{next,prev}` | Next / prev match |
| `*` `#` | same | `find.word_{forward,backward}` | Word under cursor |
| `:noh` / `:nohlsearch` | same | `find.clear` | Clear highlights |
| `:%s/old/new/g` | same | `vim.rs` `substitute` | Substitute |
| `:%s/old/new/gc` | same | `vim.rs` | Confirm flow (`y`/`n`/`a`/`q`/`l`) |
| `:Ag` `:Rg` `:grep` `:vimgrep` | `:Rg <pat>` | `find.grep` | Workspace grep → results pane |
| `:cn` `:cp` `:cfirst` `:clast` | same | `qf.{next,prev,first,last}` | Quickfix nav |
| `:copen` `:cclose` `:cwindow` | same | `vim.rs` | Quickfix pane |

## Buffers, tabs, splits

| NvChad / vim chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `:e <file>` | same | `vim.rs` `edit` | Opens existing or creates new buffer |
| `:enew` | same | `vim.rs` | Empty buffer |
| `:w` `:write` | same | `file.save` | Save |
| `:wa` `:wall` | same | `file.save_all` | Save all |
| `:q` `:quit` | same | `vim.rs` | Refuses if dirty |
| `:q!` | same | `vim.rs` | Force quit |
| `:wq` `:x` `:xit` | same | `vim.rs` | Write + quit |
| `:qa` `:qall` `:wqa` `:wqall` | same | `vim.rs` | All-buffers variants |
| `:bn` `:bnext` | same | `buffer.next` | Next buffer |
| `:bp` `:bprev` `:bprevious` | same | `buffer.prev` | Previous buffer |
| `:bd` `:bdelete` | same | `buffer.close` | Close buffer |
| `:b <name>` `:buffer <name>` | same | `vim.rs` | Fuzzy buffer switch |
| `:ls` `:buffers` `:files` | same | `vim.rs` | List buffers |
| `:b#` `Ctrl+^` | `Ctrl+6` / `Ctrl+Tab` | `buffer.last` | Last buffer toggle |
| `:tabnew` `:tabe` `:tabedit` | same | `tab.new` | New tab page |
| `gt` `:tabnext` | same | `tab.next` | Next tab |
| `gT` `:tabprev` | same | `tab.prev` | Prev tab |
| `:tabfirst` `:tablast` | same | `tab.{first,last}` | First / last tab |
| `:tabclose` | same | `tab.close` | Close active tab |
| `:tabonly` | same | `tab.only` | Close other tabs |
| (NvChad's `<leader>x`) | `<leader>bd` or `:bd` or `Ctrl+W` | `buffer.close` | Close buffer (standard mode rebinds `Ctrl+W`) |
| `:sp` `:split` | `<leader>ss` or `:split` | `view.split_down` | Horizontal split |
| `:vsp` `:vsplit` | `<leader>sv` or `:vsplit` | `view.split_right` | Vertical split |
| `Ctrl+W h/j/k/l` | same | `view.focus_{left,down,up,right}` | Move focus |
| `Ctrl+W w` | same | `view.focus_next_split` | Cycle focus |
| `Ctrl+W c` | same | `view.close_split` | Close split |
| `Ctrl+W o` `:only` | same | `view.close_others` | Close other splits |
| `Ctrl+W =` | same | `view.equalize_splits` | Balance splits |
| `Ctrl+W _` | same | `view.maximize_height` | Maximize height |
| `Ctrl+W |` | same | `view.maximize_width` | Maximize width |
| `Ctrl+W +` `Ctrl+W -` | same | `view.split_{grow,shrink}_height` | Resize height |
| `Ctrl+W > ` `Ctrl+W <` | same | `view.split_{grow,shrink}_width` | Resize width |
| `Ctrl+W r` | same | `view.rotate_splits` | Rotate splits |
| `Ctrl+W H/J/K/L` | same | `view.move_split_{left,down,up,right}` | Move split |
| `Ctrl+W T` | same | `view.move_to_new_tab` | Promote to tab |
| `Ctrl+W d` | same | `view.split_goto_definition` | Split + go-to-def |
| `Ctrl+W f` | same | `view.split_open_file_under_cursor` | Split + open path |
| `Ctrl+W n` | same | `view.split_new_scratch` | Split + scratch buffer |

## Folds + viewport

| NvChad / vim chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `za` | same | `editor.toggle_fold` | Toggle fold |
| `zR` | same | `editor.unfold_all` | Open every fold |
| `zM` | (not bound) | — | "Close every fold" not exposed yet |
| `zo` `zc` | (not bound directly) | — | Use `za`; no separate open/close-only |
| `zh` `zl` `zH` `zL` | same | `view.hscroll_*` | Horizontal scroll |

## Leader (`<space>`) chords — NvChad parity

NvChad picks `<space>` as the leader. mnml does too. The chord trie is in `src/whichkey.rs`; the which-key popup opens after `<space>` in Normal mode (and `Ctrl+K` in standard mode).

### `<leader>f` — find

| NvChad chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `<leader>ff` files | same | `picker.files` | |
| `<leader>fb` buffers | same | `picker.buffers` | |
| `<leader>fo` recents | (not bound under `<leader>f`) | `picker.recent` | Use `Ctrl+R` |
| `<leader>fg` grep | `<leader>fg` | `find.grep` | NvChad parity — added 2026-06-08. `Ctrl+Shift+F` / `:Rg` also work. |
| `<leader>fh` help | (not bound) | — | mnml has no `:help` system; use this docs site |
| `<leader>fm` formatter | (not bound) | `editor.format` | Use `Ctrl+Shift+I` |
| `<leader>fz` find in buffer | (not bound under `<leader>f`) | `find.find` | Use `Ctrl+F` or `/` |

### `<leader>b` — buffer

| NvChad chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `<leader>b` new buffer | (not bound) | — | Use `Ctrl+N` or `:enew` |
| — | `<leader>bn` next | `buffer.next` | |
| — | `<leader>bp` previous | `buffer.prev` | |
| — | `<leader>bd` delete | `buffer.close` | |
| — | `<leader>br` reopen closed | `buffer.reopen` | NvChad doesn't ship this |

### `<leader>t` — toggle / theme

| NvChad chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `<leader>th` themes | `<leader>tt` | `theme.pick` | |
| — | `<leader>te` explorer | `view.toggle_tree` | Also `<leader>e` and `Ctrl+B` |
| — | `<leader>tk` vim ⇄ standard | `editor.toggle_keymap` | mnml-specific — flip input mode at runtime |
| — | `<leader>th` hidden (focused tree) | `view.toggle_hidden` | |
| — | `<leader>tH` hidden (all) | `view.toggle_hidden_all` | |

### `<leader>g` — git

NvChad's git chords live under `<leader>g` (gitsigns / fugitive flavor). mnml's git layer is richer than NvChad's defaults — full graph DAG, AI commit messages, stash management, multi-repo.

| NvChad chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `<leader>gs` status | same | `git.status_pane` | Staging view |
| `<leader>gc` commit | same | `git.commit` | Editor for staged changes |
| — | `<leader>gm` AI (Claude) commit message | `git.ai_commit` | |
| — | `<leader>gM` AI rewrite HEAD msg | `git.ai_recompose` | `git commit --amend` with AI |
| — | `<leader>gx` Codex commit message | `git.codex_commit` | |
| `<leader>gb` blame | same | `git.blame_toggle` | Gutter blame |
| `<leader>gd` diff | same | `git.diff_file` | File diff (split) |
| — | `<leader>gD` diff worktree | `git.diff` | All changes |
| — | `<leader>gA` diff all vs HEAD | `git.diff_all` | Multi-file |
| — | `<leader>gp` peek change at cursor | `git.peek_change` | Popup |
| `<leader>gl` log | same | `git.graph` | DAG browser |
| `<leader>go` checkout | same | `git.checkout` | Branch picker |
| — | `<leader>gn` new branch | `git.new_branch` | |
| — | `<leader>gw` worktrees | `git.worktrees` | Shell in one |
| — | `<leader>gS` stash (with msg) | `git.stash` | |
| — | `<leader>gP` stash pop | `git.stash_pop` | |
| `[c` `]c` hunk nav | same | `git.jump_{prev,next}_change` | |
| `]f` `[f` | same | `git.diff_{next,prev}_file` | Within diff pane |

### `<leader>l` — LSP

| NvChad chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `<leader>la` code action | same | `lsp.code_action` | Also `Ctrl+.` |
| `<leader>lc` complete | same | `lsp.completion` | Also `Ctrl+Space` |
| `<leader>ls` symbols (file) | same | `lsp.symbols` | Also `Ctrl+Shift+O` |
| `<leader>lS` workspace symbols | same | `lsp.workspace_symbols` | |
| `<leader>lo` outline | same | `outline.show` | Sidebar |
| `<leader>ld` definition | same | `lsp.goto_definition` | Also `gd`, `F12` |
| `<leader>lh` hover | same | `lsp.hover` | Also `K` |
| `<leader>lr` references | same | `lsp.references` | Also `gr` |
| `<leader>lR` rename | same | `lsp.rename` | |
| `<leader>le` diagnostics | same | `lsp.diagnostics` | |
| `<leader>ln` next diag | same | `lsp.next_diagnostic` | |
| `<leader>lp` prev diag | same | `lsp.prev_diagnostic` | |
| `<leader>lf` format | (not bound) | `lsp.format` | Use `Ctrl+Shift+I` |

### `<leader>s` — split

| NvChad chord | mnml chord | Command id | Notes |
|---|---|---|---|
| — | `<leader>sv` split right | `view.split_right` | |
| — | `<leader>ss` split down | `view.split_down` | |
| — | `<leader>sh/sj/sk/sl` focus | `view.focus_*` | Same `hjkl` layout |
| — | `<leader>sw` focus next | `view.focus_next_split` | |
| — | `<leader>sc` close split | `view.close_split` | |
| — | `<leader>so` close others | `view.close_others` | |

### `<leader>H` — harpoon

mnml ships Harpoon-style file pinning out of the box.

| Chord | Command id | Action |
|---|---|---|
| `<leader>Ha` | `harpoon.add` | Pin active file in next free slot |
| `<leader>Hm` | `harpoon.menu` | Picker over pinned files |
| `<leader>1` … `<leader>9` | `harpoon.goto_N` | Jump to slot N |

### `<leader>I` — insert (snippets)

NvChad's snippet integration is through cmp/LuaSnip; mnml's is built-in.

| NvChad equivalent | mnml chord | Command id | Notes |
|---|---|---|---|
| LuaSnip jump | `<leader>Is` | `snippet.pick` | |
| LuaSnip expand | `<leader>Ix` / `Ctrl+J` | `snippet.expand` | Trigger word at cursor |

### `<leader>a` — AI + terminal

mnml has no NvChad analog here — these are mnml-native. (NvChad has `<leader>th` for theme picker; mnml uses `<leader>tt`.)

| Chord | Command id | Action |
|---|---|---|
| `<leader>aa` | `ai.ask` | Ask Claude |
| `<leader>ae` | `ai.explain` | Explain selection |
| `<leader>af` | `ai.fix` | Fix bugs |
| `<leader>ar` | `ai.refactor` | Refactor |
| `<leader>aw` | `ai.write_tests` | Write tests |
| `<leader>am` | `ai.session_view` | Mirror Claude session live |
| `<leader>at` | `term.shell` | Shell |
| `<leader>ac` | `ai.claude_code` | Claude Code dock |
| `<leader>aC` | `ai.chat` | Claude chat with context |
| `<leader>ax` | `ai.codex` | Codex dock |
| `<leader>aM` | `mixr.show` | Mixr DJ split |

### `<leader>h` — HTTP

| Chord | Command id | Action |
|---|---|---|
| `<leader>hs` | `http.send` | Send request |
| `<leader>hy` | `http.copy_curl` | Copy as `curl` |
| `<leader>hd` | `http.ai_debug` | Ask Claude (debug failing request) |

### `<leader>T` — test

| NvChad chord | mnml chord | Command id | Notes |
|---|---|---|---|
| (vim-test) `<leader>ta` | `<leader>Ta` | `test.run_all` | |
| (vim-test) `<leader>tf` | `<leader>Tf` | `test.run_file` | |
| (vim-test) `<leader>tn` | `<leader>Tt` | `test.run_at_cursor` | |
| (vim-test) `<leader>tl` | `<leader>Tl` | `test.rerun_failed` | |
| — | `<leader>Th` | `test.heal` | Claude heals failing test |
| — | `<leader>Tw` | `flaky.show` | Flaky dashboard |

### `<leader>P` — pull requests

mnml has cross-host PR discovery (GitHub / GitLab / Bitbucket / Azure DevOps unified). NvChad has no analog.

| Chord | Command id | Action |
|---|---|---|
| `<leader>Pp` | `pr.picker` | Cross-host fuzzy picker |
| `<leader>Pr` | `pr.refresh` | Refresh cross-host cache |

### `<leader>i` — integrations

The sibling-binary launcher trie. NvChad has no analog — these are mnml-family viewers (each lives in a separate repo as `mnml-{forge,aws,db,…}-*`).

| Chord | Command id | Action |
|---|---|---|
| `<leader>ib` | `forge.open_bitbucket` | Bitbucket viewer |
| `<leader>ig` | `forge.open_github` | GitHub viewer |
| `<leader>il` | `forge.open_gitlab` | GitLab viewer |
| `<leader>iz` | `forge.open_azdevops` | Azure DevOps viewer |
| `<leader>ic` | `forge.open_codebuild` | AWS CodeBuild |
| `<leader>is` | `forge.open_s3` | Amazon S3 |
| `<leader>iA` | `forge.open_azure_blob` | Azure Blob Storage |
| `<leader>iw` | `forge.open_cloudwatch_logs` | CloudWatch Logs |
| `<leader>ia` | `forge.open_amplify` | AWS Amplify |
| `<leader>id` | `forge.open_dynamodb` | DynamoDB |
| `<leader>iL` | `forge.open_lambda` | Lambda functions |
| `<leader>ie` | `forge.open_eventbridge` | EventBridge |
| `<leader>iR` | `forge.open_rds` | RDS |
| `<leader>iC` | `forge.open_ecs` | ECS |
| `<leader>iE` | `forge.open_ecr` | ECR |
| `<leader>io` | `forge.open_cognito` | Cognito |
| `<leader>iq` | `forge.open_sqs` | SQS |
| `<leader>iN` | `forge.open_sns` | SNS |
| `<leader>iD` | `forge.open_datadog` | Datadog |
| `<leader>iB` | `forge.open_buttondown` | Buttondown |
| `<leader>iS` | `forge.open_slack` | Slack |
| `<leader>iT` | `forge.open_teams` | Microsoft Teams |
| `<leader>iM` | `forge.open_mandrill` | Mandrill |
| `<leader>iK` | `forge.open_docker` | Docker |
| `<leader>iG` | `forge.open_gmail` | Gmail |
| `<leader>ij` | `forge.open_jira` | Jira |
| `<leader>iF` | `forge.open_cloudflare` | Cloudflare |
| `<leader>ih` | `tools.htop` | htop |
| `<leader>iI` | `tools.iftop` | iftop |

### Top-level `<leader>` keys

| Chord | Command id | Action |
|---|---|---|
| `<leader>w` | `file.save` | Save |
| `<leader>q` | `buffer.close` | Close buffer |
| `<leader>e` | `view.toggle_tree` | Toggle file rail |
| `<leader>p` | `palette` | Command palette |
| `<leader>o` | `task.run` | Run task |
| `<leader>r` | `app.restart` | Restart mnml (rebuild via run.sh) |
| `<leader>m` | `markdown.preview` | Markdown preview |
| `<leader>B` | `browser.open` | Open browser (CDP) |
| `<leader>?` | `view.cheatsheet` | Live cheatsheet pane |

## Ex commands (`:`)

`src/input/vim.rs` ships ~120 ex-command names. Selected mappings — every common NvChad-era reflex is honored.

| `:` command | mnml behavior | Notes |
|---|---|---|
| `:w` `:write` `:wa` `:wall` | Save current / all | |
| `:q` `:qa` `:qall` | Quit current / all (refuses if dirty) | |
| `:q!` `:qa!` | Force quit | |
| `:wq` `:x` `:xit` `:wqa` `:wqall` `:xall` | Write + quit variants | |
| `:e <file>` `:edit` `:enew` | Open / new buffer | 2026-06-07: `:e <newfile>` creates a buffer |
| `:saveas <path>` | Save copy | |
| `:reload` | Re-read buffer from disk (refuses if dirty) | `file.reload` |
| `:bd` `:bdelete` `:bn` `:bp` `:bnext` `:bprev` `:bfirst` `:blast` | Buffer ops | |
| `:b <name>` `:buffer` `:buffers` `:ls` `:files` | Switch / list | |
| `:badd <file>` | Add buffer (don't focus) | |
| `:sp` `:split` `:vsp` `:vsplit` `:close` `:only` `:resize` | Splits | |
| `:tabnew` `:tabe` `:tabedit` `:tabnext` `:tabprev` `:tabfirst` `:tablast` `:tabclose` `:tabonly` | Tabs | |
| `:set input=vim` `:set input=standard` | Flip input handler at runtime | mnml-specific |
| `:set wrap` `:set nowrap` `:set cc=80` `:set text_width=N` | Editor toggles | |
| `:noh` `:nohlsearch` | Clear find highlight | |
| `:%s/old/new/g[c]` `:'<,'>s/…` `:.s/…` `:sub` `:substitute` | Substitute (ranges + flags) | |
| `:&` | Repeat last `:s` on current line | `editor.repeat_last_substitute` |
| `:earlier <N>` `:later <N>` | Time-machine undo | |
| `:redo` `:undo` | Same | |
| `:marks` `:jumps` `:history` `:messages` `:registers` `:reg` | Listings | |
| `:delm <a>` | Delete mark | |
| `:Ag <pat>` `:Rg <pat>` `:grep <pat>` `:vimgrep <pat>` | Workspace grep | → `find.grep` |
| `:copen` `:cclose` `:cwindow` `:cnext` `:cprev` `:cfirst` `:clast` | Quickfix | |
| `:norm <chord>` `:normal` | Run Normal-mode chord on every selected line | E.g. `:'<,'>norm @a` |
| `:earlier 1f` `:earlier 5m` | Time-based undo | |
| `:G <args>` `:Git` `:Gblame` `:Gcommit` `:Gdiff` `:Glog` | fugitive-style | Aliased to mnml's git layer |
| `:Blame` `:Branch` `:Branches` `:Commit` `:Diagnostics` `:Format` `:Hover` `:Log` `:QF` `:QuickFix` `:References` `:Rename` `:Stash` `:StashPop` `:Status` `:Symbols` `:Test` `:TestAll` `:TestFailed` `:TestFile` `:Flaky` `:Trim` | Title-case command aliases | One word, no chord needed |
| `:Files` `:Buffers` `:Lines` `:BLines` `:History` `:Marks` `:Maps` `:Keys` `:Snippets` | fzf.vim-style pickers | |
| `:term` `:terminal` | Open shell pane | `term.shell` |
| `:cd <dir>` `:pwd` | Change / print directory | |
| `:source <file>` | Source script | |
| `:retab` | Retab buffer | |
| `:sort [u]` | Sort selection / range | |
| `:Toast <msg>` | Drop a manual toast | Useful from headless |
| `:Explore` `:Lex` `:Lexplore` `:Sex` `:Sexplore` `:Vex` `:Vexplore` | netrw-style tree open | Routes to `view.toggle_tree` / split equivalents |
| `:version` | Version info | |
| `:colo` `:colorscheme` | Pick theme | `theme.pick` |

## Ctrl chords vim mode inherits

Even in vim mode, the global `Keymap` overlay still resolves these unless your vim handler intercepts them first. The exceptions vim mode reserves (so vim semantics win) are `Ctrl+W`, `Ctrl+G`, `Ctrl+D`, `Ctrl+U`.

| Vim might-also-know-this chord | mnml chord | Command id | Notes |
|---|---|---|---|
| `Ctrl+S` save | same | `file.save` | Survives in vim mode too |
| `Ctrl+P` Files | same | `picker.files` | NvChad telescope analog |
| `Ctrl+Shift+P` palette | same | `palette` | Also `F1` |
| `Ctrl+B` toggle tree | same | `view.toggle_tree` | NvChad's nvimtree toggle |
| `Ctrl+R` recents | same | `picker.recent` | Picker over recently-opened |
| `Ctrl+F` find | same | `find.find` | Mid-buffer dialog (not `/` style) |
| `Ctrl+H` replace-all | same | `find.replace` | |
| `Ctrl+Shift+F` grep | same | `find.grep` | Same as `:Rg` |
| `Ctrl+L` redraw | same | `view.redraw` | |
| `Ctrl+,` open config | same | `file.open_settings` | |
| `Ctrl+E` cycle focus tree ⇄ editor | same | `focus.cycle` | mnml-specific; vim's `Ctrl+E` scroll-line-down still works inside buffers |
| `Alt+Left` / `Alt+Right` | same | `nav.{back,forward}` | Jumplist analog |
| `Alt+1` … `Alt+9` | same | `tab.goto_N` | Tab N |
| `F1` | same | `palette` or `view.help` | Toggle help / palette |
| `F3` / `Shift+F3` | same | `find.{next,prev}` | |
| `F5` / `Shift+F5` | same | `dap.{run,continue}` | Debug |
| `F9` / `Shift+F9` | same | `dap.toggle_breakpoint{,_conditional}` | |
| `F10` / `F11` / `Shift+F11` | same | `dap.{next,step_in,step_out}` | |
| `F12` | same | `lsp.goto_definition` | |

## What NvChad ships that mnml does NOT

Honest gaps. These are either intentional (mnml is not Neovim) or backlogged.

| NvChad / vim chord | Status in mnml | Notes |
|---|---|---|
| `<leader>th` themes | renamed to `<leader>tt` | `theme.pick` |
| `<leader>n` line numbers toggle | (not bound) | Toggle relative numbers exists as `view.toggle_relative_numbers` (palette only) |
| `<leader>rn` LSP rename | use `<leader>lR` | |
| `<leader>cm` Comment.nvim | (not bound under leader) | Use `Ctrl+/` or `gc` |
| `<leader>fa` find all (project-wide) | use `<leader>fg` (2026-06-08) or `Ctrl+Shift+F` | `find.grep` |
| `<leader>x` close buffer | use `<leader>q` or `Ctrl+W` | |
| `gcc` `gc<motion>` Comment.nvim | (toggle line comment is `Ctrl+/`) | Vim handler has no operator-pending `gc`; SEV-3 finding |
| `:help <topic>` | (no `:help`) | This docs site is the substitute |
| `:Telescope <picker>` | use `:Files` / `:Buffers` / `:History` / `:Marks` / `:Maps` | |
| `:Mason` | use `Browse external tools` palette / `tools.installer` | |
| `:Lazy` | (no plugin manager) | mnml's plugin model is the command registry + IPC |
| `:Trouble` | use `<leader>le` (`lsp.diagnostics`) | |
| `:DiffviewOpen` | use `git.diff` / `git.graph` | |
| `<leader>ww` window picker | (not bound) | Use `Ctrl+W w` |
| `zM` close all folds | (not bound) | `zR` works; close-all is missing — SEV-3 |
| `zo` / `zc` open / close fold (only) | use `za` toggle | |
| `<leader>uX` UI toggles | spread across `<leader>t…` and palette | mnml has many but no umbrella menu |
| `<leader>th` ASCII / Nerd toggle | (not bound) | mnml respects `--ascii` flag at launch |

## Source pointers

- `src/whichkey.rs` — `<leader>` trie root
- `src/command.rs` — every command + its default keyspecs
- `src/input/keymap.rs` — keyspec parser + the `Keymap` overlay engine
- `src/input/vim.rs` — vim handler + ex-command set
- `src/cheatsheet.rs` — the in-app cheatsheet pane

## Next

- [Coming from NvChad](/manual/coming-from-nvchad/) — the narrative walkthrough
- [VS Code cheatsheet](/manual/cheatsheet-vscode/) — the other-side reference
- [All chords](/manual/cheatsheet-all/) — one grid for every binding in every mode
- [Editing](/manual/editing/) — the two input handlers' architecture
- [Settings & configuration](/manual/settings/) — `[keys.*]` config overlays
