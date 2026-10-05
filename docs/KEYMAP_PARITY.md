# Keymap parity — NvChad and VS Code against mnml

Two oracles, run rather than read: NvChad 2.5 on Neovim 0.12.5
(`~/Projects/nvchad-ref/nvchad-probe`, every mapping `nvim_get_keymap` lists
once VeryLazy has loaded, plus the LSP `on_attach` buffer maps in
`nvchad/configs/lspconfig.lua`) for the vim profile, and VS Code 1.138 for the
standard profile — its default keybindings read out of
`workbench.desktop.main.js` (every `primary` / `secondary` / per-platform rule
with its command id, `KeyChord` decoded; the Linux chord, since mnml sends
Ctrl where macOS VS Code has Cmd; Windows noted where it differs). mnml's
side is `docs/commands.md` (the spec table) plus the standard input handler's
own keys (`src/input/standard.zig`) and the vim handler's (`src/input/vim.zig`).

Verdicts: **same** — the chord runs the same meaning; **different** — mnml
binds the chord to something else; **missing** — mnml binds nothing there
(the note says whether the command exists).

## Counts

| oracle | same | different | missing |
|---|---|---|---|
| NvChad / Neovim (vim profile) | 36 | 9 | 16 |
| VS Code 1.138 (standard profile) | 117 | 27 | 39 |

mnml's own chords (bound in mnml, defined by neither oracle): **252** in the vim
profile, **158** in the standard profile — section (c).
Section (d) lists what the three sections miss — **4** vim and **31**
standard chords `src/commands/specs.zig` binds with no verdict yet.
`tools/keymap-parity-check.sh` diffs this page against the specs both ways
(every chord claimed here is bound to that id; every bound chord is named
here) and exits non-zero on a mismatch.

## Applied on this branch (clear-cut: the command existed, the chord was free)

| profile | chord | command | oracle |
|---|---|---|---|
| vim | `space b` | `scratch.new` | NvChad `<leader>b` (`:enew`) — the user's decision; the `+buffer` group went |
| vim | `space D` | `lsp.goto_type_definition` | NvChad LSP `<leader>D` |
| vim | `alt+h` | `term.scratch_toggle` | NvChad `<A-h>` toggleable horizontal term |
| vim | `[ b` / `] b` | `buffer.prev / buffer.next` | Neovim `[b` / `]b` |
| standard | `ctrl+k …` (22 chords) | see `docs/KEYMAP_PROFILES.md` | VS Code's `Ctrl+K` chords — the user's decision |
| standard | `ctrl+k ctrl+q` | `editor.jump_prev_edit` | Go to Last Edit Location |
| standard | `alt+f8` / `shift+alt+f8` | `lsp.next_diagnostic / prev` | Go to Next / Previous Problem |
| standard | `ctrl+f12` | `lsp.goto_implementation` | Go to Implementations |
| standard | `shift+alt+h` | `lsp.incoming_calls` | Show Call Hierarchy |
| standard | `alt+z` | `view.toggle_wrap` | Toggle Word Wrap |
| standard | `ctrl+f2` | `editor.select_all_occurrences` | Change All Occurrences |
| standard | `ctrl+alt+minus` | `nav.back` | Go Back (Linux) |
| standard | `ctrl+alt+b` | `view.toggle_right_panel` | Toggle Secondary Side Bar |
| standard | `ctrl+shift+h` | `find.grep_replace` | Replace in Files |
| standard | `alt+f10` | `view.menu_bar_open` | Focus Application Menu |
| standard | `ctrl+alt+c` / `ctrl+k ctrl+alt+c` | `file.copy_path` | Copy Path |
| standard | `ctrl+shift+f10` | `lsp.peek_definition_overlay` | Peek Definition (Linux; `alt+f12` is Windows') |
| standard | `ctrl+alt+i` | `ai.claude_code` | Open Chat — the Chat view, the conversation pane you return to; in mnml the Claude Code session (focus the running one, or start one) |
| standard | `ctrl+alt+shift+l` | `ai.ask` | Open Quick Chat — a one-off question; VS Code spells it `ctrl+shift+alt+l` |

The two AI chords were the user's decision: a VS Code user's AI chords on
the commands they reach for, and on a standard menu row no leader chord at
all (`info_view_copy.chordOf`). VS Code's Inline Chat, `Ctrl+I`, was left
out: without the kitty keyboard protocol it is the same byte as Tab, and in
a terminal pane it would take Neovim's jumplist-forward from the child. Its
agent-mode `Ctrl+Shift+I` is Format Document on Linux, and mnml's too.
Explain, fix, refactor, write tests and the Codex verbs have no VS Code
chord, so they keep their `space a …` rows in the leader popup only.

Pinned by `the parity additions` test in `src/core/keymap.zig`, the `[b / ]b`
test in `src/input/vim.zig`, the leader-tree tests in `src/app/whichkey.zig`,
`tests/e2e/vim_leader_b_enew.test` and `tests/e2e/whichkey_standard_ctrl_k.test`.

## For the user — collisions and missing features (not decided here)

Each is one line and a recommendation; none was changed on this branch.

- **`view.focus_right_panel` lost `Ctrl+K R`** to VS Code's Reveal Active File in the OS. It is palette-only in the standard profile now. *Recommend* no chord (VS Code has none for Focus Secondary Side Bar), or `ctrl+k ctrl+shift+b` if you want one.
- **`view.keep_tab` has no vim chord** since `space b` became `:enew` (`space b k` went with the group); `space B`, the home the plan named for buffer verbs, is `browser.open`. *Recommend* leaving it palette-only (NvChad has no preview tabs), or move `browser.open` to `space i B` and make `space B` a `+buffer` group of the old rows.
- **`Ctrl+K S` is Save All only on Windows VS Code**; Linux and macOS VS Code bind it to Save without Formatting, which mnml does not have. *Recommend* keeping Save All (mnml has no format-on-save to skip).
- **The sample integration's manifest binds `ctrl+k s`** (`integrations/sample/manifest.zon`, and `docs/SDK.md` says so); an installed integration's chord overrides the built-in, so installing it takes Save All away — it took Sessions before. *Recommend* moving the sample to a `ctrl+k` letter neither VS Code nor mnml binds (the SDK's hello example already uses `ctrl+k h`).
- **`Ctrl+K W`**: VS Code closes every editor in the group; mnml's `view.close_others` closes the other panes. *Recommend* a `buffer.close_all_in_split` command on `ctrl+k w`, `view.close_others` palette-only.
- **`Ctrl+K Ctrl+W` / `Ctrl+K Ctrl+Shift+W` / `Ctrl+K U`** (close all editors / all groups / unmodified) — no commands. *Recommend* adding the three close verbs together.
- **`Ctrl+K M`** (change language mode) — no language picker. *Recommend* a `syntax.pick` picker over the grammar table.
- **`Ctrl+K Ctrl+C` / `Ctrl+K Ctrl+U`** (add / remove line comment) — only the toggle exists. *Recommend* two EditOps beside `toggle_line_comment`.
- **`Ctrl+K Ctrl+X`** (trim trailing whitespace) — the trim exists only as `editor.trim_trailing_ws_on_save`. *Recommend* an `editor.trim_trailing_ws` command on it.
- **`Ctrl+K Ctrl+B`**: VS Code sets the selection anchor; mnml has `view.sidebar_pin` there. *Recommend* keeping mnml's (anchors do not exist here).
- **`Ctrl+K B` / `G C` / `I D` / `J` / `N` / `T` / `A`** are mnml's own `Ctrl+K` rows (VS Code defines none of them outside notebooks). *Recommend* keeping them — they are the popup's mnml verbs.
- **`Ctrl+Shift+[` / `Ctrl+Shift+]`**: VS Code folds / unfolds at the cursor; mnml toggles / unfolds all. *Recommend* `editor.close_fold` / `editor.open_fold` there (`Ctrl+K Ctrl+L` / `Ctrl+K Ctrl+J` now carry toggle / unfold all).
- **`F11` / `F6`**: VS Code step-into / pause only while debugging (full screen / focus next part otherwise); mnml has step-in on F11 always and focus.cycle on F6. *Recommend* no change.
- **`F7` / `Shift+F7` and `F8` / `Shift+F8`**: VS Code's next highlight / next problem in files; mnml's git diff file / conflict walk. *Recommend* no change — `alt+f8` now carries the problem walk.
- **`Ctrl+J`**: VS Code toggles the panel; mnml expands a snippet (standard). *Recommend* `view.toggle_bottom_panel` on `ctrl+j` and `snippet.expand` elsewhere.
- **`Ctrl+Shift+B`**: VS Code runs the build task; mnml toggles the right column (now also `ctrl+alt+b`, VS Code's). *Recommend* moving `ctrl+shift+b` to `task.run`.
- **`Ctrl+Shift+R` / `Ctrl+Shift+A`**: VS Code refactor / block comment; mnml's HTTP find-request / toast action. *Recommend* no change unless refactor lands.
- **`Ctrl+Shift+\`**: VS Code jump to bracket; mnml split down. *Recommend* no change (`ctrl+k ctrl+\` also splits down now).
- **`Shift+Alt+Up/Down`, `Shift+Alt+Left/Right`**: VS Code (Linux) add cursor above / below and expand / shrink selection; mnml duplicates lines and selects by word (macOS VS Code's meanings). *Recommend* no change — the Linux meanings are on `ctrl+alt+up/down` and the LSP selection commands.
- **`Ctrl+Alt+Left/Right`, `Ctrl+Shift+PageUp/Down`, `Shift+Alt+1/9`, `Alt+0`**: move editor between groups / within a group / open by index — mnml has no editor-to-group moves, and `alt+N` are tab pages. *Recommend* no change.
- **`Ctrl+N`**: VS Code opens an unnamed buffer; mnml's `file.new` asks for a path. *Recommend* `scratch.new` on `ctrl+n` (VS Code's meaning, and `:w name` names it) with `file.new` palette- and tree-only.
- **`F1`**: VS Code's command palette; mnml's keymap reference. *Recommend* no change (`ctrl+shift+p` is the palette).
- **`Ctrl+E`** (Quick Open's second chord) — `picker.files` exists and the keymap had nothing there, but a chord the keymap binds reaches it before a terminal pane's child, so it took readline's end-of-line (and a Jira pane's text field's: `integrations_jira_work_filter_jql.test` caught it). *Recommend* no chord, or a terminal-aware one.
- **The menu bar's Alt+letter accelerators give way to a bound chord under vim** (`menu_bar.interceptKey`): vim's `alt+h` (`term.scratch_toggle`) reaches the scratch terminal from an editor and `alt+r` (`find.toggle_regex`) toggles regex search instead of opening *Run*; a letter vim leaves unbound still opens its menu. Under standard every letter stays the menu's, as in VS Code. While the bar is `hidden` or a terminal pane has the keys, the bar takes no Alt letter at all.
- **Every keymap chord outranks a terminal pane's child**, so the additions here (`alt+z`, `alt+f8`, `alt+f10`, `ctrl+alt+b` / `c` / `minus`, and vim's `alt+h`, which NvChad also maps in terminal mode) are taken from a shell in a terminal pane, as `alt+r` / `alt+j` / `alt+k` already are; VS Code sends most chords to the shell unless the command is in `terminal.integrated.commandsToSkipShell`. *Recommend* a per-command "skip the shell" flag if one of them bites.
- **`Shift+Alt+.`** (auto fix) — `lsp.quick_fix` exists, but a terminal sends Shift+. as `>`, so the chord never arrives. *Recommend* no chord.
- **`Ctrl+Shift+5`** — VS Code's terminal split, terminal-focus only; the keymap has no focus condition, so binding it would reach editors too. *Recommend* the terminal pane's key handler, as `term.search` reads the find chord. (`Ctrl+Shift+C` / `Ctrl+Shift+V` are the terminal pane's own now, both profiles: `pty_pane.selectionCopyKey` copies a selection, `pty_pane.pasteKey` pastes — Shift+Insert too — and plain `Ctrl+V` stays the child's ^V.)
- **`Ctrl+Alt+R`** (reveal the explorer's file in the OS) — `view.reveal_active` reveals the active file, which `Ctrl+K R` now carries. *Recommend* the tree's own handler.
- **`Ctrl+K Ctrl+H`** (output panel), **`Ctrl+Shift+S`** (save as), **`Ctrl+K C` / `Ctrl+K D`** (compare with clipboard / saved), **`Ctrl+U`** (cursor undo), **`Shift+Alt+I`** (cursors at line ends), **`Ctrl+Alt+Backspace`** (remove brackets) — no commands. *Recommend* backlog, save-as first.
- **NvChad `<leader>ma`** (marks): `space m` is `markdown.preview`, a leaf. *Recommend* `markdown.preview` to `space M`, then `space m a` → `picker.marks`.
- **NvChad `<leader>th`** (themes): `space t h` is hidden files. *Recommend* no change (`space t t` is the theme picker).
- **NvChad `<leader>pt`** (hidden terminals): `space p` is the palette and there is no hidden-terminal picker. *Recommend* backlog.
- **NvChad `<leader>fa`** (all files, ignored + hidden) and **`<leader>fh`** (help tags), **`<leader>wk`** (which-key lookup), **`<M-v>` / `<M-i>`** (vertical / floating toggle terms), **`<C-c>`** (copy file) — missing features. *Recommend* `<leader>fa` first (a picker flag).
- **Neovim `grn gra grr gri grt grx`**: mnml's `gr` is references at once, so the prefix cannot exist. *Recommend* following Neovim 0.11+: `gr` becomes the prefix (`grr` references), a visible change for anyone used to `gr`.
- **Neovim `gO`** (document symbols): the handler has `g O` free, but `O` is one of the letters `mnml.operator` lets scripts claim. *Recommend* reserving `O` and binding it to `lsp.symbols`.
- **Neovim `[t` / `]t`** are tags; mnml's are TODOs. *Recommend* no change (no tags).
- **Neovim `<C-W>d`** is the diagnostics float; mnml's is vim's older split-to-definition. *Recommend* no change.
- **NvChad `;` → `:`** and the insert-mode `<C-h/j/k/l>`, `<C-e>`, `<C-b>`, `jk`: mnml keeps vim's own meanings. *Recommend* a `vim.nvchad_insert_keys` setting if anyone asks.

## (a) NvChad / Neovim → the vim profile


*NvChad mappings.lua*

| chord | there | verdict | mnml (vim) | note |
|---|---|---|---|---|
| `<leader>ff` | Telescope find_files | same | `space f f` picker.files |  |
| `<leader>fa` | find_files, no_ignore + hidden | missing | — | the file picker has no include-ignored mode |
| `<leader>fw` | Telescope live_grep | same | `space f w` find.grep | the grep lands in a results pane; `find.live_grep` is the picker form |
| `<leader>fb` | Telescope buffers | same | `space f b` picker.buffers |  |
| `<leader>fh` | Telescope help_tags | missing | — | no help-tag picker |
| `<leader>ma` | Telescope marks | different | `space m` markdown.preview (a leaf, so `m a` cannot exist) | `picker.marks` exists |
| `<leader>fo` | Telescope oldfiles | same | `space f o` picker.recent |  |
| `<leader>fz` | current_buffer_fuzzy_find | same | `space f z` find.find | the find bar, not a fuzzy list |
| `<leader>cm` | Telescope git_commits | same | `space c m` git.graph |  |
| `<leader>gt` | Telescope git_status | same | `space g t` git.status_pane |  |
| `<leader>pt` | Telescope terms (hidden terminals) | different | `space p` palette (a leaf) | no hidden-terminal picker either |
| `<leader>th` | NvChad theme picker | different | `space t h` view.toggle_hidden | `theme.pick` is `space t t` |
| `<leader>e` | NvimTreeFocus | same | `space e` view.focus_tree |  |
| `<C-n>` | NvimTreeToggle | same | `ctrl+n` view.toggle_tree |  |
| `<leader>/ (n, v)` | toggle comment | same | `space /` editor.toggle_line_comment |  |
| `<leader>x` | buffer close | same | `space x` buffer.close |  |
| `<leader>b` | buffer new (`:enew`) | same | `space b` scratch.new | this branch; it was the `+buffer` group |
| `<Tab> / <S-Tab>` | buffer next / prev | same | `tab` / `shift+tab` buffer.next / prev |  |
| `<leader>h / <leader>v` | new horizontal / vertical term | same | `space h` / `space v` term.shell_bottom / right |  |
| `<M-h> (n, t)` | toggleable horizontal term | same | `alt+h` term.scratch_toggle | added on this branch |
| `<M-v> (n, t)` | toggleable vertical term | missing | — | no vertical toggle terminal |
| `<M-i> (n, t)` | toggle floating term | missing | — | no floating terminal |
| `<leader>ds` | LSP diagnostic loclist | same | `space d s` lsp.diagnostics |  |
| `<leader>fm (n, v)` | conform format | same | `space f m` lsp.format | Visual formats the file, as conform does |
| `<leader>ch` | NvCheatsheet | same | `space c h` view.cheatsheet |  |
| `<leader>rn` | toggle relative number | same | `space r n` |  |
| `<leader>n` | toggle line number | same | `space n` |  |
| `<leader>wK` | WhichKey (all keymaps) | same | `space w K` whichkey.leader | the tree shows `w → +which-key (1)` |
| `<leader>wk` | WhichKey query lookup | missing | — | no "which key does X" prompt |
| `<C-h> <C-j> <C-k> <C-l>` | switch window | same | `ctrl+h` `ctrl+j` `ctrl+k` `ctrl+l` view.focus_left / down / up / right |  |
| `<C-s>` | save | same | `ctrl+s` file.save |  |
| `<C-c>` | copy whole file (`%y+`) | missing | — | no command; the handler ignores Ctrl-C in Normal |
| `<Esc>` | clear highlights (`:noh`) | same | Esc | the search chip goes (checked in the headless harness) |
| `;` | enter command mode | different | vim's `;` (repeat f / t) | `:` opens the line |
| `<C-x> (t)` | escape terminal mode | same | terminal-normal | `pty_pane.escapeKey` |

*NvChad LSP on_attach (buffer-local)*

| chord | there | verdict | mnml (vim) | note |
|---|---|---|---|---|
| `gd / gD` | definition / declaration | same | `g d` / `g D` |  |
| `<leader>D` | type definition | same | `space D` lsp.goto_type_definition | added on this branch |
| `<leader>ra` | NvRenamer | same | `space r a` lsp.rename |  |
| `<leader>wa / wr / wl` | LSP add / remove / list workspace folder | missing | — | no LSP workspace-folder commands; `view.add_workspace` is mnml's workspace, not the server's |

*Neovim 0.12 defaults the probe lists*

| chord | there | verdict | mnml (vim) | note |
|---|---|---|---|---|
| `K` | hover | same | `K` lsp.hover |  |
| `grn / gra / grr / gri / grt / grx` | rename / code action / references / implementation / type definition / codelens | different | `g r` lsp.references at once | the `gr` prefix cannot exist while `gr` is a whole command |
| `gO` | document symbols | missing | — | `lsp.symbols` exists and `g O` is free in the handler, but `O` is a letter `mnml.operator` scripts may claim (`script_ops.reserved`) |
| `gcc / gc{motion}` | toggle comment | same | the handler |  |
| `gx` | open under cursor | same | editor.open_url_at_cursor |  |
| `[d / ]d` | diagnostic prev / next | same | `[ d` / `] d` lsp.prev_diagnostic / next |  |
| `[D / ]D` | first / last diagnostic | missing | — |  |
| `[q / ]q` | quickfix prev / next | same | qf.prev / qf.next |  |
| `[Q / ]Q, [<C-Q> / ]<C-Q>` | quickfix first / last, file | missing | — |  |
| `[b / ]b` | :bprevious / :bnext | same | buffer.prev / buffer.next | added on this branch (`Keys.vim_handler`) |
| `[B / ]B` | :brewind / :blast | missing | — |  |
| `[t / ]t` | :tprevious / :tnext (tags) | different | project.prev_todo / next_todo | mnml's TODO jumps |
| `[T ]T [<C-T> ]<C-T>` | tag first / last / preview | missing | — | no tags |
| `[a ]a [A ]A` | argument list | missing | — | no arglist |
| `[l ]l [L ]L [<C-L> ]<C-L>` | location list | missing | — | no location list |
| `[<Space> / ]<Space>` | blank line above / below | missing | — |  |
| `<C-W>d` | diagnostics float | different | view.split_goto_definition | vim's older `CTRL-W d` |
| `Y` | y$ | same | the handler |  |
| `&` | :&& | same | editor.repeat_last_substitute | keeps the last `:s` flags since vimfix3 (it dropped them before, so the row was wrong) |
| `g&` | :%s//~/& | same | editor.repeat_last_substitute_all | added on vimfix3 |
| `:term` / `:term {cmd}` | a terminal buffer in the current window; `:b#` back to the file | same | a new tab in the focused leaf (`termEx`) | since termvim; the standard profile's `:term` still splits below, and a tool's `term` line (launchers, integrations, tasks) opens below in both profiles (`termTool`) |

*NvChad insert mode*

| chord | there | verdict | mnml (vim) | note |
|---|---|---|---|---|
| `<C-h> <C-j> <C-k> <C-l>` | cursor left / down / up / right | different | vim's own (backspace, newline, …) |  |
| `<C-e> / <C-b>` | end / start of line | different | `<C-e>` is vim's char-below; `<C-b>` nothing |  |
| `jk` | Esc | missing | — | no insert-mode key sequences |

The `<Space>` / `"` / `'` / `` ` `` / `c` / `g` / `v` rows the probe lists
with no description are which-key's own triggers, not mappings.

## (b) VS Code 1.138 → the standard profile

Editor, navigation, view, terminal, search, git and debug chords; the
context-only ones (a widget, a notebook, a peek view, the chat, the
web build) are left out. Rows marked with a bundle expression were
resolved by hand from the same file.

### editor

| VS Code chord | VS Code command | verdict | mnml (standard) | note |
|---|---|---|---|---|
| `alt+down` | `editor.action.moveLinesDownAction` | same | `editor.move_line_down` |  |
| `alt+up` | `editor.action.moveLinesUpAction` | same | `editor.move_line_up` |  |
| `ctrl+.` | `editor.action.quickFix` | same | `lsp.code_action` |  |
| `ctrl+/` | `editor.action.commentLine` | same | editor: toggle line comment |  |
| `ctrl+[` | `editor.action.outdentLines` | same | `editor.outdent_line` |  |
| `ctrl+]` | `editor.action.indentLines` | same | `editor.indent_line` |  |
| `ctrl+a` | `editor.action.selectAll` | same | editor: select all |  |
| `ctrl+alt+backspace` | `editor.action.removeBrackets` | missing | — | no mnml command |
| `ctrl+alt+c` | `copyFilePath` | same | `file.copy_path` |  |
| `ctrl+backspace` | `deleteWordLeft` | same | editor: delete word left |  |
| `ctrl+c` | `editor.action.clipboardCopyAction` | same | editor: copy (OS clipboard) |  |
| `ctrl+d` | `editor.action.addSelectionToNextFindMatch` | same | `editor.add_cursor_at_next_word` |  |
| `ctrl+delete` | `deleteWordRight` | same | editor: delete word right |  |
| `ctrl+enter` | `editor.action.insertLineAfter` | same | editor: line below |  |
| `ctrl+f2` | `editor.action.changeAll` | same | `editor.select_all_occurrences` |  |
| `ctrl+k c` | `workbench.files.action.compareWithClipboard` | missing | — | no mnml command |
| `ctrl+k ctrl+0` | `editor.foldAll` | same | `lsp.fold_all` |  |
| `ctrl+k ctrl+[` | `editor.foldRecursively` | missing | — | no mnml command |
| `ctrl+k ctrl+]` | `editor.unfoldRecursively` | missing | — | no mnml command |
| `ctrl+k ctrl+alt+c` | `copyFilePath` | same | `file.copy_path` |  |
| `ctrl+k ctrl+c` | `editor.action.addCommentLine` | missing | — | no mnml command |
| `ctrl+k ctrl+f` | `editor.action.formatSelection` | same | `lsp.format_selection` |  |
| `ctrl+k ctrl+i` | `editor.action.showHover` | same | `lsp.hover` |  |
| `ctrl+k ctrl+j` | `editor.unfoldAll` | same | `editor.unfold_all` |  |
| `ctrl+k ctrl+l` | `editor.toggleFold` | same | `editor.toggle_fold` |  |
| `ctrl+k ctrl+shift+alt+c` | `copyRelativeFilePath` | missing | — | no mnml command |
| `ctrl+k ctrl+shift+l` | `editor.toggleFoldRecursively` | missing | — | no mnml command |
| `ctrl+k ctrl+u` | `editor.action.removeCommentLine` | missing | — | no mnml command |
| `ctrl+k ctrl+x` | `editor.action.trimTrailingWhitespace` | missing | — | no mnml command |
| `ctrl+k d` | `workbench.files.action.compareWithSaved` | missing | — | no mnml command |
| `ctrl+k m` | `workbench.action.editor.changeLanguageMode` | missing | — | no mnml command |
| `ctrl+k p` | `workbench.action.files.copyPathOfActiveFile` | same | `file.copy_path` |  |
| `ctrl+k s` | `workbench.action.files.saveWithoutFormatting` | different | `file.save_all` | no mnml command |
| `ctrl+k s` | `saveAll` | same | `file.save_all` | Windows only (`win:{primary:mo(2089,49)}`); Linux: Save without Formatting, macOS: Cmd+Alt+S |
| `ctrl+l` | `expandLineSelection` | same | editor: select line |  |
| `ctrl+m` | `editor.action.toggleTabFocusMode` | missing | — | no mnml command |
| `ctrl+n` | `workbench.action.files.newUntitledFile` | different | `file.new` | mnml has `scratch.new` (no standard chord); `Ut?…:2092` on the desktop |
| `ctrl+s` | `workbench.action.files.save` | same | `file.save` |  |
| `ctrl+shift+s` | `workbench.action.files.saveAs` | same | `file.save_as` |  |
| `ctrl+shift+[` | `editor.fold` | different | `editor.toggle_fold` | mnml has `editor.close_fold` (no standard chord) |
| `ctrl+shift+]` | `editor.unfold` | different | `editor.unfold_all` | mnml has `editor.open_fold` (no standard chord) |
| `ctrl+shift+a` | `editor.action.blockComment` | different | `toast.run_action` | no mnml command |
| `ctrl+shift+alt+c` | `copyRelativeFilePath` | missing | — | no mnml command |
| `ctrl+shift+alt+down` | `editor.action.copyLinesDownAction` | missing | — | no mnml command |
| `ctrl+shift+alt+up` | `editor.action.copyLinesUpAction` | missing | — | no mnml command |
| `ctrl+shift+enter` | `editor.action.insertLineBefore` | same | editor: line above |  |
| `ctrl+shift+i` | `editor.action.formatDocument` | same | `lsp.format` |  |
| `ctrl+shift+k` | `editor.action.deleteLines` | same | `editor.delete_line` |  |
| `ctrl+shift+l` | `editor.action.selectHighlights` | same | `editor.select_all_occurrences` |  |
| `ctrl+shift+r` | `editor.action.refactor` | different | `http.find_request` | no mnml command |
| `ctrl+shift+s` | `workbench.action.files.saveAs` | missing | — | no mnml command |
| `ctrl+shift+space` | `editor.action.triggerParameterHints` | same | `lsp.signature_help` |  |
| `ctrl+space` | `editor.action.triggerSuggest` | same | `lsp.completion` |  |
| `ctrl+u` | `cursorUndo` | missing | — | no mnml command |
| `ctrl+v` | `editor.action.clipboardPasteAction` | same | editor: paste |  |
| `ctrl+x` | `editor.action.clipboardCutAction` | same | editor: cut |  |
| `ctrl+y` | `redo` | same | editor: redo |  |
| `ctrl+z` | `undo` | same | editor: undo |  |
| `f2` | `editor.action.rename` | same | `lsp.rename` |  |
| `shift+alt+.` | `editor.action.autoFix` | missing | — | mnml has `lsp.quick_fix` on `alt+enter` |
| `shift+alt+down` | `editor.action.insertCursorBelow` | different | editor: duplicate line | mnml has `editor.add_cursor_below` on `ctrl+alt+down`, `ctrl+alt+j` |
| `shift+alt+i` | `editor.action.insertCursorAtEndOfEachLineSelected` | missing | — | no mnml command |
| `shift+alt+left` | `editor.action.smartSelect.shrink` | different | editor: select word left | mnml has `lsp.selection_shrink` (no standard chord) |
| `shift+alt+o` | `editor.action.organizeImports` | same | `lsp.organize_imports` |  |
| `shift+alt+right` | `editor.action.smartSelect.expand` | different | editor: select word right | mnml has `lsp.selection_expand` (no standard chord) |
| `shift+alt+up` | `editor.action.insertCursorAbove` | different | editor: duplicate line (cursor up) | mnml has `editor.add_cursor_above` on `ctrl+alt+k`, `ctrl+alt+up` |
| `shift+tab` | `outdent` | same | editor: outdent |  |

### navigation

| VS Code chord | VS Code command | verdict | mnml (standard) | note |
|---|---|---|---|---|
| `alt+0` | `workbench.action.lastEditorInGroup` | missing | — | no mnml command |
| `alt+f12` | `editor.action.peekDefinition` | same | `lsp.peek_definition_overlay` | Windows; Linux Ctrl+Shift+F10 |
| `alt+f8` | `editor.action.marker.next` | same | `lsp.next_diagnostic` |  |
| `alt+pagedown` | `scrollPageDown` | missing | — | no mnml command |
| `alt+pageup` | `scrollPageUp` | missing | — | no mnml command |
| `ctrl+alt+minus` | `workbench.action.navigateBack` | same | `nav.back` |  |
| `ctrl+down` | `scrollLineDown` | different | editor: cursor down | mnml has `view.scroll_buffer_down` (no standard chord) |
| `ctrl+e` | `workbench.action.quickOpen` | missing | — | mnml has `picker.files` on `ctrl+o`, `ctrl+p`, `space f f`; kX.secondary = [2083] |
| `ctrl+end` | `cursorBottom` | same | editor: buffer end |  |
| `ctrl+f12` | `editor.action.goToImplementation` | same | `lsp.goto_implementation` |  |
| `ctrl+g` | `workbench.action.gotoLine` | same | `editor.goto_line` |  |
| `ctrl+home` | `cursorTop` | same | editor: buffer start |  |
| `ctrl+k ctrl+o` | `workbench.action.files.openFolder` | same | `view.switch_workspace` |  |
| `ctrl+k ctrl+p` | `workbench.action.showAllEditors` | same | `picker.buffers` |  |
| `ctrl+k ctrl+pagedown` | `workbench.action.nextEditorInGroup` | same | `buffer.next` |  |
| `ctrl+k ctrl+pageup` | `workbench.action.previousEditorInGroup` | same | `buffer.prev` |  |
| `ctrl+k ctrl+q` | `workbench.action.navigateToLastEditLocation` | same | `editor.jump_prev_edit` |  |
| `ctrl+k f12` | `editor.action.revealDefinitionAside` | same | `view.split_goto_definition` |  |
| `ctrl+left` | `cursorWordLeft` | same | editor: word left |  |
| `ctrl+o` | `workbench.action.files.openFile` | same | `picker.files` |  |
| `ctrl+p` | `workbench.action.quickOpen` | same | `picker.files` | kX.primary = 2094 |
| `ctrl+pagedown` | `workbench.action.nextEditor` | same | `buffer.next` |  |
| `ctrl+pageup` | `workbench.action.previousEditor` | same | `buffer.prev` |  |
| `ctrl+r` | `workbench.action.openRecent` | same | `picker.recent` |  |
| `ctrl+right` | `cursorWordEndRight` | same | editor: word right |  |
| `ctrl+shift+\` | `editor.action.jumpToBracket` | different | `view.split_down` | mnml has `editor.bracket_match` (no standard chord) |
| `ctrl+shift+end` | `cursorBottomSelect` | same | editor: select to end |  |
| `ctrl+shift+f10` | `editor.action.peekDefinition` | same | `lsp.peek_definition_overlay` |  |
| `ctrl+shift+home` | `cursorTopSelect` | same | editor: select to start |  |
| `ctrl+shift+left` | `cursorWordLeftSelect` | same | editor: select word left |  |
| `ctrl+shift+minus` | `workbench.action.navigateForward` | same | `nav.forward` |  |
| `ctrl+shift+o` | `workbench.action.gotoSymbol` | same | `lsp.symbols` |  |
| `ctrl+shift+right` | `cursorWordEndRightSelect` | same | editor: select word right |  |
| `ctrl+shift+tab` | `workbench.action.quickOpenLeastRecentlyUsedEditorInGroup` | different | `buffer.prev` | no mnml command |
| `ctrl+t` | `workbench.action.showAllSymbols` | same | `picker.workspace_symbol` |  |
| `ctrl+tab` | `workbench.action.quickOpenPreviousRecentlyUsedEditorInGroup` | same | `buffer.last` |  |
| `ctrl+up` | `scrollLineUp` | different | editor: cursor up | mnml has `view.scroll_buffer_up` (no standard chord) |
| `f12` | `editor.action.revealDefinition` | same | `lsp.goto_definition` |  |
| `f7` | `editor.action.wordHighlight.next` | different | `git.diff_next_file` | no mnml command |
| `f8` | `editor.action.marker.nextInFiles` | different | `git.conflict_next` | no mnml command |
| `shift+alt+f8` | `editor.action.marker.prev` | same | `lsp.prev_diagnostic` |  |
| `shift+alt+h` | `editor.showCallHierarchy` | same | `lsp.incoming_calls` |  |
| `shift+f12` | `editor.action.goToReferences` | same | `lsp.references` |  |
| `shift+f7` | `editor.action.wordHighlight.prev` | different | `git.diff_prev_file` | no mnml command |
| `shift+f8` | `editor.action.marker.prevInFiles` | different | `git.conflict_prev` | no mnml command |

### view

| VS Code chord | VS Code command | verdict | mnml (standard) | note |
|---|---|---|---|---|
| `alt+z` | `editor.action.toggleWordWrap` | same | `view.toggle_wrap` |  |
| `ctrl+,` | `workbench.action.openSettings` | same | `view.settings` |  |
| `ctrl+0` | `workbench.action.focusSideBar` | same | `view.focus_tree` |  |
| `ctrl+\` | `workbench.action.splitEditor` | same | `view.split_right` |  |
| `ctrl+alt+b` | `workbench.action.toggleAuxiliaryBar` | same | `view.toggle_right_panel` |  |
| `ctrl+alt+left` | `workbench.action.moveEditorToPreviousGroup` | different | `buffer.prev` | no mnml command |
| `ctrl+alt+r` | `revealFileInOS` | missing | — | mnml has `view.reveal_active` on `ctrl+k r` |
| `ctrl+alt+right` | `workbench.action.moveEditorToNextGroup` | different | `buffer.next` | no mnml command |
| `ctrl+b` | `workbench.action.toggleSidebarVisibility` | same | `view.toggle_tree` |  |
| `ctrl+j` | `workbench.action.togglePanel` | different | `snippet.expand` | mnml has `view.toggle_bottom_panel` on `ctrl+shift+j` |
| `ctrl+k ctrl+\` | `workbench.action.splitEditorOrthogonal` | same | `view.split_down` |  |
| `ctrl+k ctrl+down` | `workbench.action.focusBelowGroup` | same | `view.focus_down` |  |
| `ctrl+k ctrl+h` | `workbench.action.output.toggleOutput` | missing | — | no mnml command |
| `ctrl+k ctrl+left` | `workbench.action.focusLeftGroup` | same | `view.focus_left` |  |
| `ctrl+k ctrl+m` | `workbench.action.toggleMaximizeEditorGroup` | same | `view.toggle_zoom` |  |
| `ctrl+k ctrl+r` | `workbench.action.keybindingsReference` | same | `view.help` |  |
| `ctrl+k ctrl+right` | `workbench.action.focusRightGroup` | same | `view.focus_right` |  |
| `ctrl+k ctrl+s` | `workbench.action.openGlobalKeybindings` | same | `view.cheatsheet` |  |
| `ctrl+k ctrl+shift+n` | `notifications.showList` | same | `messages.show` |  |
| `ctrl+k ctrl+shift+w` | `workbench.action.closeAllGroups` | missing | — | no mnml command |
| `ctrl+k ctrl+t` | `workbench.action.selectTheme` | same | `theme.pick` |  |
| `ctrl+k ctrl+up` | `workbench.action.focusAboveGroup` | same | `view.focus_up` |  |
| `ctrl+k ctrl+w` | `workbench.action.closeAllEditors` | missing | — | no mnml command |
| `ctrl+k down` | `workbench.action.moveActiveEditorGroupDown` | same | `view.move_split_down` |  |
| `ctrl+k e` | `workbench.files.action.focusOpenEditorsView` | missing | — | no mnml command |
| `ctrl+k enter` | `workbench.action.keepEditor` | same | `view.keep_tab` |  |
| `ctrl+k f` | `workbench.action.closeFolder` | missing | — | no mnml command |
| `ctrl+k left` | `workbench.action.moveActiveEditorGroupLeft` | same | `view.move_split_left` |  |
| `ctrl+k r` | `workbench.action.files.revealActiveFileInWindows` | same | `view.reveal_active` |  |
| `ctrl+k right` | `workbench.action.moveActiveEditorGroupRight` | same | `view.move_split_right` |  |
| `ctrl+k shift+enter` | `workbench.action.pinEditor` | same | `buffer.pin_toggle` |  |
| `ctrl+k u` | `workbench.action.closeUnmodifiedEditors` | missing | — | no mnml command |
| `ctrl+k up` | `workbench.action.moveActiveEditorGroupUp` | same | `view.move_split_up` |  |
| `ctrl+k w` | `workbench.action.closeEditorsInGroup` | different | `view.close_others` | no mnml command |
| `ctrl+k z` | `workbench.action.toggleZenMode` | same | `view.fullscreen` |  |
| `ctrl+q` | `workbench.action.quit` | same | `app.quit` |  |
| `ctrl+shift+e` | `workbench.view.explorer` | same | `view.focus_tree` |  |
| `ctrl+shift+m` | `workbench.actions.view.problems` | same | `lsp.diagnostics` |  |
| `ctrl+shift+p` | `workbench.action.showCommands` | same | `palette` | `tu?void 0:3118` on the desktop |
| `ctrl+shift+pagedown` | `workbench.action.moveEditorRightInGroup` | missing | — | no mnml command |
| `ctrl+shift+pageup` | `workbench.action.moveEditorLeftInGroup` | missing | — | no mnml command |
| `ctrl+shift+t` | `workbench.action.reopenClosedEditor` | same | `buffer.reopen` |  |
| `ctrl+w` | `workbench.action.closeActiveEditor` | same | `buffer.close` |  |
| `f1` | `workbench.action.showCommands` | different | `view.help` | mnml has `palette` on `ctrl+shift+p`, `space p`; secondary [59] |
| `f11` | `workbench.action.toggleFullScreen` | different | `dap.step_in` | no mnml command |
| `f6` | `workbench.action.focusNextPart` | same | `focus.cycle` |  |
| `shift+alt+1` | `workbench.action.moveEditorToFirstGroup` | missing | — | no mnml command |
| `shift+alt+9` | `workbench.action.moveEditorToLastGroup` | missing | — | no mnml command |
| `shift+f6` | `workbench.action.focusPreviousPart` | missing | — | no mnml command |

### terminal

| VS Code chord | VS Code command | verdict | mnml (standard) | note |
|---|---|---|---|---|
| `` ctrl+` `` | `workbench.action.terminal.toggleTerminal` | same | `term.scratch_toggle` |  |
| `ctrl+shift+5` | `workbench.action.terminal.split` | missing | — | mnml has `term.shell` on `` ctrl+shift+` ``, `space a t` |
| `` ctrl+shift+` `` | `workbench.action.terminal.new` | same | `term.shell` |  |
| `ctrl+shift+c` | `workbench.action.terminal.copySelection` | missing | — | mnml has `term.copy` (no standard chord) |
| `ctrl+shift+v` | `workbench.action.terminal.paste` | missing | — | mnml has `term.paste` (no standard chord) |

### search

| VS Code chord | VS Code command | verdict | mnml (standard) | note |
|---|---|---|---|---|
| `ctrl+f` | `actions.find` | same | `find.find` |  |
| `ctrl+h` | `editor.action.startFindReplaceAction` | same | `find.replace` |  |
| `ctrl+shift+f` | `workbench.action.findInFiles` | same | `find.grep` |  |
| `ctrl+shift+h` | `workbench.action.replaceInFiles` | same | `find.grep_replace` |  |

### git

| VS Code chord | VS Code command | verdict | mnml (standard) | note |
|---|---|---|---|---|
| `ctrl+shift+g` | `scm` | same | `view.activity_git` |  |

### debug

| VS Code chord | VS Code command | verdict | mnml (standard) | note |
|---|---|---|---|---|
| `ctrl+f5` | `workbench.action.debug.run` | missing | — | no mnml command |
| `ctrl+shift+b` | `workbench.action.tasks.build` | different | `view.toggle_right_panel` | no mnml command |
| `ctrl+shift+d` | `workbench.view.debug` | same | `view.activity_debug` |  |
| `ctrl+shift+f5` | `workbench.action.debug.restart` | same | `dap.restart` |  |
| `f10` | `workbench.action.debug.stepOver` | same | `dap.next` |  |
| `f11` | `workbench.action.debug.stepInto` | same | `dap.step_in` | `vun` = 69 off the web |
| `f5` | `workbench.action.debug.continue` | same | `dap.continue` |  |
| `f5` | `workbench.action.debug.start` | same | `dap.continue` |  |
| `f6` | `workbench.action.debug.pause` | different | `focus.cycle` | mnml has `dap.pause` (no standard chord) |
| `f9` | `editor.debug.action.toggleBreakpoint` | same | `dap.toggle_breakpoint` |  |
| `shift+f11` | `workbench.action.debug.stepOut` | same | `dap.step_out` |  |
| `shift+f5` | `workbench.action.debug.stop` | same | `dap.terminate` |  |
| `shift+f9` | `editor.debug.action.toggleInlineBreakpoint` | different | `dap.toggle_breakpoint_conditional` | no mnml command |

## (c) mnml's own chords

Bound in mnml, defined by neither oracle for that profile. Most are the
which-key tree's mnml groups (`+lang/run`, `+http`, `+test`, `+ai/term`,
`+integrations`, `+harpoon`, `+layouts`, …) and the `Ctrl+K` rows above.

<details><summary>vim profile — 260 chords</summary>

| chord | command |
|---|---|
| `alt+1` | `tab.goto_1` |
| `alt+2` | `tab.goto_2` |
| `alt+3` | `tab.goto_3` |
| `alt+4` | `tab.goto_4` |
| `alt+5` | `tab.goto_5` |
| `alt+6` | `tab.goto_6` |
| `alt+7` | `tab.goto_7` |
| `alt+8` | `tab.goto_8` |
| `alt+9` | `tab.goto_9` |
| `alt+[` | `git.prev_repo` |
| `alt+]` | `git.next_repo` |
| `alt+down` | `editor.move_line_down` |
| `alt+enter` | `lsp.quick_fix` |
| `alt+f12` | `lsp.peek_definition_overlay` |
| `alt+j` | `editor.move_line_down` |
| `alt+k` | `editor.move_line_up` |
| `alt+r` | `find.toggle_regex` |
| `alt+up` | `editor.move_line_up` |
| `ctrl+,` | `view.settings` |
| `ctrl+.` | `lsp.code_action` |
| `ctrl+0` | `view.focus_tree` |
| `ctrl+1` | `view.focus_tab_1` |
| `ctrl+2` | `view.focus_tab_2` |
| `ctrl+3` | `view.focus_tab_3` |
| `ctrl+4` | `view.focus_tab_4` |
| `ctrl+5` | `view.focus_tab_5` |
| `ctrl+6` | `view.focus_tab_6` |
| `ctrl+7` | `view.focus_tab_7` |
| `ctrl+8` | `view.focus_tab_8` |
| `ctrl+9` | `view.focus_tab_last` |
| `ctrl+;` | `app.command_line` |
| `ctrl+\` | `view.split_right` |
| `ctrl+]` | `editor.bracket_match` |
| `` ctrl+` `` | `term.scratch_toggle` |
| `ctrl+alt+down` | `editor.add_cursor_below` |
| `ctrl+alt+j` | `editor.add_cursor_below` |
| `ctrl+alt+k` | `editor.add_cursor_above` |
| `ctrl+alt+left` | `buffer.prev` |
| `ctrl+alt+right` | `buffer.next` |
| `ctrl+alt+up` | `editor.add_cursor_above` |
| `ctrl+alt+w` | `view.right_panel_close_tab` |
| `ctrl+minus` | `nav.back` |
| `ctrl+p` | `picker.files` |
| `ctrl+pagedown` | `buffer.next` |
| `ctrl+pageup` | `buffer.prev` |
| `ctrl+q` | `app.quit` |
| `ctrl+shift+[` | `editor.toggle_fold` |
| `ctrl+shift+\` | `view.split_down` |
| `ctrl+shift+]` | `editor.unfold_all` |
| `` ctrl+shift+` `` | `term.shell` |
| `ctrl+shift+a` | `toast.run_action` |
| `ctrl+shift+b` | `view.toggle_right_panel` |
| `ctrl+shift+d` | `view.activity_debug` |
| `ctrl+shift+e` | `view.focus_tree` |
| `ctrl+shift+f` | `find.grep` |
| `ctrl+shift+f5` | `dap.restart` |
| `ctrl+shift+g` | `view.activity_git` |
| `ctrl+shift+i` | `lsp.format` |
| `ctrl+shift+j` | `view.toggle_bottom_panel` |
| `ctrl+shift+k` | `editor.delete_line` |
| `ctrl+shift+l` | `editor.select_all_occurrences` |
| `ctrl+shift+m` | `lsp.diagnostics` |
| `ctrl+shift+minus` | `nav.forward` |
| `ctrl+shift+o` | `lsp.symbols` |
| `ctrl+shift+p` | `palette` |
| `ctrl+shift+space` | `lsp.signature_help` |
| `ctrl+shift+t` | `buffer.reopen` |
| `ctrl+shift+tab` | `buffer.prev` |
| `ctrl+shift+x` | `view.activity_integrations` |
| `ctrl+shift+z` | `editor.redo` |
| `ctrl+space` | `lsp.completion` |
| `ctrl+tab` | `buffer.last` |
| `ctrl+underscore` | `nav.forward` |
| `ctrl+w shift+w` | `view.focus_prev_split` |
| `ctrl+w w` | `view.focus_next_split` |
| `ctrl+w z` | `view.toggle_zoom` |
| `delete` | `file.delete` |
| `f1` | `view.help` |
| `f10` | `dap.next` |
| `f11` | `dap.step_in` |
| `f12` | `lsp.goto_definition` |
| `f2` | `lsp.rename` |
| `f3` | `find.next` |
| `f5` | `dap.continue` |
| `f6` | `focus.cycle` |
| `f7` | `git.diff_next_file` |
| `f8` | `git.conflict_next` |
| `f9` | `dap.toggle_breakpoint` |
| `g r` | `lsp.references` |
| `shift+alt+o` | `lsp.organize_imports` |
| `shift+f10` | `view.context_menu_at_focus` |
| `shift+f11` | `dap.step_out` |
| `shift+f12` | `lsp.references` |
| `shift+f3` | `find.prev` |
| `shift+f5` | `dap.terminate` |
| `shift+f7` | `git.diff_prev_file` |
| `shift+f8` | `git.conflict_prev` |
| `shift+f9` | `dap.toggle_breakpoint_conditional` |
| `space 1` | `harpoon.goto_1` |
| `space 2` | `harpoon.goto_2` |
| `space 3` | `harpoon.goto_3` |
| `space 4` | `harpoon.goto_4` |
| `space 5` | `harpoon.goto_5` |
| `space 6` | `harpoon.goto_6` |
| `space 7` | `harpoon.goto_7` |
| `space 8` | `harpoon.goto_8` |
| `space 9` | `harpoon.goto_9` |
| `space ?` | `view.cheatsheet` |
| `space a 1` | `sessions.focus_1` |
| `space a 2` | `sessions.focus_2` |
| `space a 3` | `sessions.focus_3` |
| `space a 4` | `sessions.focus_4` |
| `space a 5` | `sessions.focus_5` |
| `space a 6` | `sessions.focus_6` |
| `space a 7` | `sessions.focus_7` |
| `space a 8` | `sessions.focus_8` |
| `space a 9` | `sessions.focus_9` |
| `space a a` | `ai.ask` |
| `space a b` | `ai.toggle_backend` |
| `space a c` | `ai.claude_code` |
| `space a d` | `ai.dashboard` |
| `space a e` | `ai.explain` |
| `space a f` | `ai.fix` |
| `space a j` | `sessions.next_waiting` |
| `space a k` | `sessions.prev_waiting` |
| `space a m` | `ai.session_view` |
| `space a n` | `ai.claude_code_new` |
| `space a r` | `ai.refactor` |
| `space a shift+c` | `ai.chat` |
| `space a shift+x` | `ai.codex_new` |
| `space a t` | `term.shell` |
| `space a w` | `ai.write_tests` |
| `space a x` | `ai.codex` |
| `space c a` | `lsp.code_action` |
| `space d b` | `dap.toggle_breakpoint` |
| `space d c` | `dap.continue` |
| `space d e` | `dap.exceptions` |
| `space d h` | `dap.evaluate_hover` |
| `space d i` | `dap.step_in` |
| `space d l` | `dap.set_breakpoint_log_message` |
| `space d o` | `dap.next` |
| `space d p` | `dap.pause` |
| `space d r` | `dap.repl` |
| `space d shift+b` | `dap.toggle_breakpoint_conditional` |
| `space d shift+o` | `dap.step_out` |
| `space d shift+r` | `dap.restart` |
| `space d t` | `dap.terminate` |
| `space d u` | `dap.toggle_panel` |
| `space d w` | `dap.add_watch` |
| `space f g` | `find.grep` |
| `space f i` | `picker.recent_items` |
| `space f r` | `picker.recent` |
| `space g b` | `git.blame_toggle` |
| `space g c` | `git.commit` |
| `space g d` | `git.diff` |
| `space g e` | `git.explain_branch` |
| `space g f` | `git.diff_file` |
| `space g i` | `git.rebase_interactive_onto` |
| `space g l` | `git.graph` |
| `space g m` | `git.ai_commit` |
| `space g n` | `git.jump_next_change` |
| `space g o` | `git.checkout` |
| `space g p` | `git.jump_prev_change` |
| `space g r` | `git.push_start_pr` |
| `space g s` | `git.status_pane` |
| `space g shift+a` | `git.diff_all` |
| `space g shift+d` | `git.diff` |
| `space g shift+m` | `git.ai_recompose` |
| `space g shift+p` | `git.stash_pop` |
| `space g shift+s` | `git.stash` |
| `space g shift+w` | `git.worktree_open_tab` |
| `space g w` | `git.worktrees` |
| `space g x` | `git.codex_commit` |
| `space i d` | `integrations.show_details` |
| `space i h` | `tools.htop` |
| `space i r` | `tools.btop` |
| `space i shift+e` | `integrations.toggle_enabled` |
| `space i shift+i` | `tools.iftop` |
| `space j` | `jobs.show` |
| `space l a` | `lsp.code_action` |
| `space l c` | `lsp.completion` |
| `space l d` | `lsp.goto_definition` |
| `space l e` | `lsp.diagnostics` |
| `space l h` | `lsp.hover` |
| `space l n` | `lsp.next_diagnostic` |
| `space l o` | `outline.show` |
| `space l p` | `lsp.prev_diagnostic` |
| `space l r` | `lsp.references` |
| `space l s` | `lsp.symbols` |
| `space l shift+r` | `lsp.rename` |
| `space l shift+s` | `lsp.workspace_symbols` |
| `space m` | `markdown.preview` |
| `space o` | `task.run` |
| `space p` | `palette` |
| `space q` | `buffer.close` |
| `space s c` | `view.close_split` |
| `space s h` | `view.focus_left` |
| `space s j` | `view.focus_down` |
| `space s k` | `view.focus_up` |
| `space s l` | `view.focus_right` |
| `space s o` | `view.close_others` |
| `space s s` | `view.split_down` |
| `space s shift+h` | `view.move_section_left` |
| `space s shift+l` | `view.move_section_right` |
| `space s shift+w` | `view.focus_prev_split` |
| `space s v` | `view.split_right` |
| `space s w` | `view.focus_next_split` |
| `space s z` | `view.toggle_zoom` |
| `space shift+b` | `browser.open` |
| `space shift+e` | `view.sidebar_pin` |
| `space shift+h a` | `harpoon.add` |
| `space shift+h m` | `harpoon.menu` |
| `space shift+i s` | `snippet.pick` |
| `space shift+i x` | `snippet.expand` |
| `space shift+l c b` | `cargo.build` |
| `space shift+l c c` | `cargo.check` |
| `space shift+l c f` | `cargo.fmt` |
| `space shift+l c l` | `cargo.clippy` |
| `space shift+l c t` | `cargo.test` |
| `space shift+l g b` | `go.build` |
| `space shift+l g p` | `go.run_path` |
| `space shift+l g r` | `go.run` |
| `space shift+l g t` | `go.test` |
| `space shift+l g v` | `go.vet` |
| `space shift+l l` | `script.run_selection` |
| `space shift+l n b` | `npm.build` |
| `space shift+l n i` | `npm.install` |
| `space shift+l n l` | `npm.lint` |
| `space shift+l n r` | `npm.run` |
| `space shift+l n s` | `npm.start` |
| `space shift+l n t` | `npm.test` |
| `space shift+l n x` | `npm.run_script` |
| `space shift+l p l` | `pytest.failed` |
| `space shift+l p t` | `pytest.run` |
| `space shift+r [` | `http.prev_block` |
| `space shift+r ]` | `http.next_block` |
| `space shift+r d` | `http.ai_debug` |
| `space shift+r r` | `http.find_request` |
| `space shift+r s` | `http.send` |
| `space shift+r y` | `http.copy_curl` |
| `space shift+t a` | `test.run_all` |
| `space shift+t f` | `test.run_file` |
| `space shift+t h` | `test.heal` |
| `space shift+t l` | `test.rerun_failed` |
| `space shift+t t` | `test.run_at_cursor` |
| `space shift+t w` | `flaky.show` |
| `space shift+w d` | `layout.delete` |
| `space shift+w l` | `layout.pick` |
| `space shift+w s` | `layout.save` |
| `space t 0` | `view.reset_layout` |
| `space t [` | `view.right_panel_prev_tab` |
| `space t ]` | `view.right_panel_next_tab` |
| `space t e` | `view.toggle_tree` |
| `space t f` | `view.fullscreen` |
| `space t k` | `editor.toggle_keymap` |
| `space t n` | `view.toggle_line_numbers` |
| `space t r` | `view.toggle_right_panel` |
| `space t shift+h` | `view.toggle_hidden_all` |
| `space t t` | `theme.pick` |
| `space t w` | `view.toggle_wrap` |
| `space t x` | `view.right_panel_close_tab` |

</details>

<details><summary>standard profile — 166 chords</summary>

| chord | command |
|---|---|
| `alt+1` | `tab.goto_1` |
| `alt+2` | `tab.goto_2` |
| `alt+3` | `tab.goto_3` |
| `alt+4` | `tab.goto_4` |
| `alt+5` | `tab.goto_5` |
| `alt+6` | `tab.goto_6` |
| `alt+7` | `tab.goto_7` |
| `alt+8` | `tab.goto_8` |
| `alt+9` | `tab.goto_9` |
| `alt+j` | `editor.move_line_down` |
| `ctrl+2` | `view.focus_tab_2` |
| `ctrl+3` | `view.focus_tab_3` |
| `ctrl+4` | `view.focus_tab_4` |
| `ctrl+5` | `view.focus_tab_5` |
| `ctrl+6` | `view.focus_tab_6` |
| `ctrl+7` | `view.focus_tab_7` |
| `ctrl+8` | `view.focus_tab_8` |
| `ctrl+alt+1` | `sessions.focus_1` |
| `ctrl+alt+2` | `sessions.focus_2` |
| `ctrl+alt+3` | `sessions.focus_3` |
| `ctrl+alt+4` | `sessions.focus_4` |
| `ctrl+alt+5` | `sessions.focus_5` |
| `ctrl+alt+6` | `sessions.focus_6` |
| `ctrl+alt+7` | `sessions.focus_7` |
| `ctrl+alt+8` | `sessions.focus_8` |
| `ctrl+alt+9` | `sessions.focus_9` |
| `ctrl+;` | `app.command_line` |
| `ctrl+k a` | `view.activity_sessions` |
| `ctrl+k b` | `git.blame_toggle` |
| `ctrl+k ctrl+e` | `picker.recent_items` |
| `ctrl+k g c` | `git.commit` |
| `ctrl+k i d` | `integrations.show_details` |
| `ctrl+k j` | `jobs.show` |
| `ctrl+k n` | `tab.new` |
| `ctrl+shift+alt+n` | `sessions.prev_waiting` |
| `ctrl+underscore` | `nav.forward` |
| `space 1` | `harpoon.goto_1` |
| `space 2` | `harpoon.goto_2` |
| `space 3` | `harpoon.goto_3` |
| `space 4` | `harpoon.goto_4` |
| `space 5` | `harpoon.goto_5` |
| `space 6` | `harpoon.goto_6` |
| `space 7` | `harpoon.goto_7` |
| `space 8` | `harpoon.goto_8` |
| `space 9` | `harpoon.goto_9` |
| `space ?` | `view.cheatsheet` |
| `space a a` | `ai.ask` |
| `space a b` | `ai.toggle_backend` |
| `space a c` | `ai.claude_code` |
| `space a d` | `ai.dashboard` |
| `space a e` | `ai.explain` |
| `space a f` | `ai.fix` |
| `space a m` | `ai.session_view` |
| `space a n` | `ai.claude_code_new` |
| `space a r` | `ai.refactor` |
| `space a shift+c` | `ai.chat` |
| `space a shift+x` | `ai.codex_new` |
| `space a t` | `term.shell` |
| `space a w` | `ai.write_tests` |
| `space a x` | `ai.codex` |
| `space f b` | `picker.buffers` |
| `space f f` | `picker.files` |
| `space f g` | `find.grep` |
| `space f r` | `picker.recent` |
| `space g b` | `git.blame_toggle` |
| `space g c` | `git.commit` |
| `space g d` | `git.diff` |
| `space g f` | `git.diff_file` |
| `space g l` | `git.graph` |
| `space g m` | `git.ai_commit` |
| `space g n` | `git.jump_next_change` |
| `space g o` | `git.checkout` |
| `space g p` | `git.jump_prev_change` |
| `space g s` | `git.status_pane` |
| `space g shift+a` | `git.diff_all` |
| `space g shift+d` | `git.diff` |
| `space g shift+m` | `git.ai_recompose` |
| `space g shift+p` | `git.stash_pop` |
| `space g shift+s` | `git.stash` |
| `space g w` | `git.worktrees` |
| `space g x` | `git.codex_commit` |
| `space i d` | `integrations.show_details` |
| `space i h` | `tools.htop` |
| `space i r` | `tools.btop` |
| `space i shift+e` | `integrations.toggle_enabled` |
| `space i shift+i` | `tools.iftop` |
| `space j` | `jobs.show` |
| `space l a` | `lsp.code_action` |
| `space l c` | `lsp.completion` |
| `space l d` | `lsp.goto_definition` |
| `space l e` | `lsp.diagnostics` |
| `space l h` | `lsp.hover` |
| `space l n` | `lsp.next_diagnostic` |
| `space l o` | `outline.show` |
| `space l p` | `lsp.prev_diagnostic` |
| `space l r` | `lsp.references` |
| `space l s` | `lsp.symbols` |
| `space l shift+r` | `lsp.rename` |
| `space l shift+s` | `lsp.workspace_symbols` |
| `space m` | `markdown.preview` |
| `space n` | `view.toggle_line_numbers` |
| `space o` | `task.run` |
| `space p` | `palette` |
| `space q` | `buffer.close` |
| `space s c` | `view.close_split` |
| `space s h` | `view.focus_left` |
| `space s j` | `view.focus_down` |
| `space s k` | `view.focus_up` |
| `space s l` | `view.focus_right` |
| `space s o` | `view.close_others` |
| `space s s` | `view.split_down` |
| `space s shift+h` | `view.move_section_left` |
| `space s shift+l` | `view.move_section_right` |
| `space s shift+w` | `view.focus_prev_split` |
| `space s v` | `view.split_right` |
| `space s w` | `view.focus_next_split` |
| `space shift+b` | `browser.open` |
| `space shift+h a` | `harpoon.add` |
| `space shift+h m` | `harpoon.menu` |
| `space shift+i s` | `snippet.pick` |
| `space shift+i x` | `snippet.expand` |
| `space shift+l c b` | `cargo.build` |
| `space shift+l c c` | `cargo.check` |
| `space shift+l c f` | `cargo.fmt` |
| `space shift+l c l` | `cargo.clippy` |
| `space shift+l c t` | `cargo.test` |
| `space shift+l g b` | `go.build` |
| `space shift+l g p` | `go.run_path` |
| `space shift+l g r` | `go.run` |
| `space shift+l g t` | `go.test` |
| `space shift+l g v` | `go.vet` |
| `space shift+l n b` | `npm.build` |
| `space shift+l n i` | `npm.install` |
| `space shift+l n l` | `npm.lint` |
| `space shift+l n r` | `npm.run` |
| `space shift+l n s` | `npm.start` |
| `space shift+l n t` | `npm.test` |
| `space shift+l n x` | `npm.run_script` |
| `space shift+l p l` | `pytest.failed` |
| `space shift+l p t` | `pytest.run` |
| `space shift+r [` | `http.prev_block` |
| `space shift+r ]` | `http.next_block` |
| `space shift+r d` | `http.ai_debug` |
| `space shift+r s` | `http.send` |
| `space shift+r y` | `http.copy_curl` |
| `space shift+t a` | `test.run_all` |
| `space shift+t f` | `test.run_file` |
| `space shift+t h` | `test.heal` |
| `space shift+t l` | `test.rerun_failed` |
| `space shift+t t` | `test.run_at_cursor` |
| `space shift+t w` | `flaky.show` |
| `space shift+w d` | `layout.delete` |
| `space shift+w l` | `layout.pick` |
| `space shift+w s` | `layout.save` |
| `space t 0` | `view.reset_layout` |
| `space t [` | `view.right_panel_prev_tab` |
| `space t ]` | `view.right_panel_next_tab` |
| `space t e` | `view.toggle_tree` |
| `space t f` | `view.fullscreen` |
| `space t h` | `view.toggle_hidden` |
| `space t k` | `editor.toggle_keymap` |
| `space t n` | `view.toggle_line_numbers` |
| `space t r` | `view.toggle_right_panel` |
| `space t shift+h` | `view.toggle_hidden_all` |
| `space t t` | `theme.pick` |
| `space t w` | `view.toggle_wrap` |
| `space t x` | `view.right_panel_close_tab` |

</details>

## (d) Bound in mnml, not yet placed in (a)–(c)

Chords `src/commands/specs.zig` binds that the three sections above do not
name — missed by the first cut of the ledger or bound after it (the help
pane's `help.focus` / `help.pin_toggle`). Some are also oracle chords (VS
Code's F3 / Shift+F3 find next / previous, for one) and move into (a) or
(b) with a verdict the next time the oracles are read; until then they are
listed here so `tools/keymap-parity-check.sh` can hold the doc to the
specs in both directions.

*vim profile — 8 chords*

| chord | command |
|---|---|
| `[ a` | `ai.focus_prev_session` |
| `] a` | `ai.focus_next_session` |
| `ctrl+alt+pagedown` | `ai.focus_next_session` |
| `ctrl+alt+pageup` | `ai.focus_prev_session` |
| `ctrl+shift+n` | `ai.claude_code_new` |
| `space` | `whichkey.leader` |
| `space shift+k` | `help.focus` |
| `space t p` | `help.pin_toggle` |

*standard profile — 33 chords*

| chord | command |
|---|---|
| `alt+[` | `git.prev_repo` |
| `alt+]` | `git.next_repo` |
| `alt+enter` | `lsp.quick_fix` |
| `alt+k` | `editor.move_line_up` |
| `alt+r` | `find.toggle_regex` |
| `ctrl+-` | `nav.back` |
| `ctrl+1` | `view.focus_tab_1` |
| `ctrl+9` | `view.focus_tab_last` |
| `ctrl+alt+down` | `editor.add_cursor_below` |
| `ctrl+alt+enter` | `script.run_selection` |
| `ctrl+alt+j` | `editor.add_cursor_below` |
| `ctrl+alt+k` | `editor.add_cursor_above` |
| `ctrl+alt+n` | `sessions.next_waiting` |
| `ctrl+alt+pagedown` | `ai.focus_next_session` |
| `ctrl+alt+pageup` | `ai.focus_prev_session` |
| `ctrl+alt+shift+left` | `view.focus_prev_split` |
| `ctrl+alt+shift+right` | `view.focus_next_split` |
| `ctrl+alt+up` | `editor.add_cursor_above` |
| `ctrl+alt+w` | `view.right_panel_close_tab` |
| `ctrl+k` | `whichkey.leader` |
| `ctrl+k ctrl+b` | `view.sidebar_pin` |
| `ctrl+k shift+h` | `help.pin_toggle` |
| `ctrl+k t` | `theme.toggle` |
| `ctrl+shift+j` | `view.toggle_bottom_panel` |
| `ctrl+shift+n` | `ai.claude_code_new` |
| `ctrl+shift+x` | `view.activity_integrations` |
| `ctrl+shift+z` | `editor.redo` |
| `delete` | `file.delete` |
| `f3` | `find.next` |
| `shift+f1` | `help.focus` |
| `shift+f10` | `view.context_menu_at_focus` |
| `shift+f3` | `find.prev` |
| `space` | `whichkey.leader` |

## (e) The sessions mode's contextual chords (both profiles)

While the sessions mode shows (`sessions.mode`, the Sessions row of the
activity bar), five chords mean the sessions' verbs instead of their usual
ones, whichever pane or panel has the keys, in both profiles
(`src/app/sessions_mode.zig`, `interceptKey`). Elsewhere they keep the
meaning the tables above give them. They are not spec bindings — the chord
is the same, the context picks the command — so they are listed here in
prose rather than in a table the checker holds to the specs:

- Ctrl+Tab → `sessions.column_next` (elsewhere `buffer.last`): the focused
  column's visible session gives way to the next one stacked behind it.
- Ctrl+Shift+Tab → `sessions.column_prev` (elsewhere `buffer.prev`).
- Ctrl+1 … Ctrl+9 → `sessions.focus_1` … `sessions.focus_9` (elsewhere
  `view.focus_tab_N`): the session whose SESSIONS card wears N — the
  number `Ctrl+Alt+N` / `Space a N` reach everywhere — in the focused
  column. These nine hold in the wider *sessions view* too: the mode on
  screen, or the SESSIONS panel with the keys (`sessions_mode.viewing`).
- Ctrl+N → `sessions.mode_new` (elsewhere `file.new` in the standard
  profile, `view.toggle_tree` in the vim profile): a new Claude Code session
  as the focused column's visible one; on a zoomed page it takes the zoom.

Outside the mode, Ctrl+Shift+N opens a new Claude Code session
(`ai.claude_code_new`, both profiles). Codex gets no chord: Ctrl+Shift+M,
the natural twin, is `lsp.diagnostics` in both profiles.
