# Keymap profiles — vim and standard

mnml ships two complete keymaps. The **vim** profile gives a Neovim /
NvChad user the chords their hands already know: `Space` as the leader,
`Ctrl-W` for windows, `g d` / `K` / `[ d` for the language server. The
**standard** profile gives a VS Code user theirs: `Ctrl` shortcuts, the
`Ctrl+K …` chords and the function keys.

Pick one with `.editor.input_style = .vim` or `.standard` in
`config.zon`, or for one launch with `--input vim|standard`.

Every default chord belongs to one of three sets: **both** (it fires in
either profile), **vim** (only under `.vim`) or **standard** (only under
`.standard`). In `config.zon`, `.keys.global` applies to both profiles
and `.keys.vim` / `.keys.standard` add to or override their own.

## How the profiles differ

1. **Vim keeps the editor's Ctrl keys.** `Ctrl-W`, `Ctrl-G`, `Ctrl-D`,
   `Ctrl-U`, `Ctrl-E`, `Ctrl-Y`, `Ctrl-R`, `Ctrl-N`, `Ctrl-H`, `Ctrl-J`,
   `Ctrl-T`, `Ctrl-F`, `Ctrl-B` and `Ctrl-O` all mean something in
   Neovim's normal or insert mode, so a default chord that starts with
   one of them is standard-only. The exceptions are the ones NvChad maps
   itself in normal mode, which the vim profile binds the way NvChad
   does: `Ctrl-N` toggles the file tree, and `Ctrl-H` / `Ctrl-J` /
   `Ctrl-K` / `Ctrl-L` move between windows.
2. **`Ctrl+K` is the standard profile's leader; `Space` is vim's.** In
   the vim profile `Ctrl-K` is NvChad's window-up. In the standard
   profile `Ctrl+K` starts a VS Code chord: press the next key straight
   away and the chord runs. Pause after `Ctrl+K` (or after `Ctrl+K g`)
   and a popup lists what can follow — `w → close others`,
   `g → +git (1)`, including your own `.keys` overrides. The next key
   runs the chord as if you had not paused, `Esc` cancels, and a key no
   chord uses says `no Ctrl+K chord: …`. The palette's *Leader menu
   (which-key)* opens the same popup. Wherever VS Code defines a
   `Ctrl+K` chord for a command mnml has, the standard profile uses VS
   Code's meaning.
3. **`Ctrl+]` / `Ctrl+[`** indent and outdent in standard, as in VS
   Code. In vim `Ctrl-]` jumps to the matching bracket.
4. **`Ctrl+L`** selects the line in standard and moves to the window on
   the right in vim, so *Redraw* (`view.redraw`) has no chord in either
   profile; it is in the palette.
5. **No chord is lost.** When a profile-only chord lands on a key a
   shared command used, the shared command moves to the other profile's
   chord instead of disappearing.
6. **Back / forward** (`nav.back` / `nav.forward`) are on `Alt+←` /
   `Alt+→`, except on macOS, where those two keys are left unbound.
7. **A menu row prints the profile's chord.** In standard that
   includes the keys the editor answers itself — Cut `Ctrl+X`, Copy
   `Ctrl+C`, Paste `Ctrl+V`, Undo `Ctrl+Z`, Select all `Ctrl+A`, Toggle
   comment `Ctrl+/` — and never a leader chord: a command whose only
   chord is a `Space …` row prints none, and the hover help says which
   leader row reaches it. The vim profile prints its leader chords.
8. **The menu bar's Alt+letter mnemonics** keep every letter in
   standard, as VS Code's do; in vim a chord the keymap binds wins
   (`Alt+H` is NvChad's scratch terminal, `Alt+R` regex search) and
   only unbound letters open their menus (`menu_bar.interceptKey`).
9. **The hover help ends on the click's chord.** A control whose left
   click runs one command — a chrome button, a statusline chip, a rail
   icon, a panel or tree header chip, a launcher dock entry, a menu or
   palette row — closes its info-view entry with `Key: …`, that
   command's chord under the same rule as a menu row (`Key: Ctrl+K
   Ctrl+T` in standard, `Key: Space t t` in vim for the theme pill); no
   line when the profile binds it to nothing, or when the entry's own
   `[chord]` rows already print it. The click and the line read one
   table, `src/app/primary_command.zig`.

## Chords that differ between the profiles

| command | chord | profile | why |
|---|---|---|---|
| `view.fullscreen` | `ctrl+k z` | standard | VS Code's Zen Mode chord |
| `view.close_others` | `ctrl+k w` | standard | a `Ctrl+K` chord |
| `find.find` | `ctrl+f` | standard | vim: `Ctrl-F` is page-forward |
| `find.replace` | `ctrl+h` | standard | vim: `Ctrl-H` is window-left |
| `editor.goto_line` | `ctrl+g` | standard | vim: `Ctrl-G` shows the file position |
| `editor.bracket_match` | `ctrl+]` | vim | standard: `Ctrl+]` indents |
| `editor.add_cursor_at_next_word` | `ctrl+d` | standard | vim: `Ctrl-D` scrolls half a page |
| `file.new` | `ctrl+n` | standard | vim: `Ctrl-N` toggles the tree (NvChad) |
| `picker.recent` | `ctrl+r` | standard | vim: `Ctrl-R` is redo |
| `picker.recent_items` | `space f i` / `ctrl+k ctrl+e` | vim / standard | `space f r` is `picker.recent` in both and `ctrl+k ctrl+r` is `view.help`, so the next free pair |
| `buffer.close` | `ctrl+w` | standard | vim: `Ctrl-W` is the window prefix |
| `tab.new` | `ctrl+k n` | standard | a `Ctrl+K` chord |
| `theme.toggle` | `ctrl+k t` | standard | a `Ctrl+K` chord |
| `view.switch_workspace` | `ctrl+k ctrl+o` | standard | VS Code: Open Folder |
| `view.activity_sessions` | `ctrl+k a` | standard | a `Ctrl+K` chord VS Code leaves free |
| `git.blame_toggle` | `ctrl+k b` | standard | a `Ctrl+K` chord |
| `git.commit` | `ctrl+k g c` | standard | a `Ctrl+K` chord |
| `lsp.hover` | `ctrl+k ctrl+i` | standard | VS Code: Show Hover |
| `integrations.show_details` | `ctrl+k i d` | standard | a `Ctrl+K` chord |
| `snippet.expand` | `ctrl+j` | standard | vim: `Ctrl-J` is window-down |
| `picker.workspace_symbol` | `ctrl+t` | standard | vim: `Ctrl-T` pops the tag stack |
| `whichkey.leader` | `ctrl+k` (then pause) | standard | the standard leader popup |
| `view.focus_left` / `_right` / `_up` / `_down` | `ctrl+k ctrl+←` / `→` / `↑` / `↓` | standard | VS Code: focus the editor group in that direction |
| `editor.indent_line` / `editor.outdent_line` | `ctrl+]` / `ctrl+[` | standard | VS Code: Indent / Outdent Line |
| `file.save_all` / `view.cheatsheet` / `view.help` / `theme.pick` | `ctrl+k s` / `ctrl+k ctrl+s` / `ctrl+k ctrl+r` / `ctrl+k ctrl+t` | standard | VS Code: Save All (its Windows default), Keyboard Shortcuts, Keyboard Shortcuts Reference, Color Theme |
| `lsp.format_selection` / `picker.buffers` / `messages.show` / `file.copy_path` / `view.reveal_active` | `ctrl+k ctrl+f` / `ctrl+k ctrl+p` / `ctrl+k ctrl+shift+n` / `ctrl+k p` / `ctrl+k r` | standard | VS Code: Format Selection, Show All Editors, Show Notifications, Copy Path of Active File, Reveal Active File in the OS |
| `editor.toggle_fold` / `editor.unfold_all` / `lsp.fold_all` | `ctrl+k ctrl+l` / `ctrl+k ctrl+j` / `ctrl+k ctrl+0` | standard | VS Code: Toggle Fold, Unfold All, Fold All |
| `buffer.prev` / `buffer.next` / `buffer.pin_toggle` | `ctrl+k ctrl+pageup` / `ctrl+k ctrl+pagedown` / `ctrl+k shift+enter` | standard | VS Code: Previous / Next Editor in Group, Pin / Unpin Editor |
| `view.move_split_left` / `_right` / `_up` / `_down` / `view.split_down` / `view.split_goto_definition` | `ctrl+k ←` / `→` / `↑` / `↓` / `ctrl+k ctrl+\` / `ctrl+k f12` | standard | VS Code: Move Editor Group, Split Editor Orthogonal, Open Definition to the Side |
| `editor.jump_prev_edit` / `lsp.next_diagnostic` / `lsp.prev_diagnostic` / `lsp.goto_implementation` / `lsp.incoming_calls` / `view.toggle_wrap` / `editor.select_all_occurrences` / `nav.back` / `view.toggle_right_panel` / `find.grep_replace` / `view.menu_bar_open` / `file.copy_path` / `lsp.peek_definition_overlay` | `ctrl+k ctrl+q` / `alt+f8` / `shift+alt+f8` / `ctrl+f12` / `shift+alt+h` / `alt+z` / `ctrl+f2` / `ctrl+alt+minus` / `ctrl+alt+b` / `ctrl+shift+h` / `alt+f10` / `ctrl+alt+c`, `ctrl+k ctrl+alt+c` / `ctrl+shift+f10` | standard | VS Code's Linux defaults for the same commands |
| `view.toggle_tree` | `ctrl+b` | standard | vim: `Ctrl-B` is page-back |
| `ai.claude_code` / `ai.ask` | `ctrl+alt+i` / `ctrl+alt+shift+l` | standard | VS Code: Open Chat, Open Quick Chat. Both keep their `space a c` / `space a a` leader rows |
| `picker.files` | `ctrl+o` | standard | vim: `Ctrl-O` is the jumplist in normal mode and one normal-mode command in insert mode. `ctrl+p` opens the picker in both profiles |
| `picker.files` / `picker.buffers` | `space f f` / `space f b` | both | NvChad `<leader>ff` / `<leader>fb` |
| `find.grep` | `space f w` | vim | NvChad `<leader>fw` |
| `view.toggle_tree` | `ctrl+n` | vim | NvChad `<C-n>` |
| `view.focus_tree` | `space e` | vim | NvChad `<leader>e`: focuses the tree, opening it first if it is hidden. `Ctrl-N` toggles it |
| `buffer.close` | `space x` | vim | NvChad `<leader>x` |
| `term.shell_bottom` / `term.shell_right` | `space h` / `space v` | vim | NvChad `<leader>h` / `<leader>v` terminals |
| `buffer.next` / `buffer.prev` | `tab` / `shift+tab` | vim | NvChad's bufferline |
| `view.focus_left` / `_down` / `_up` / `_right` | `ctrl+h` / `ctrl+j` / `ctrl+k` / `ctrl+l` | vim | NvChad `<C-h/j/k/l>`. From the leftmost split `Ctrl-H` enters the sidebar and `Ctrl-L` comes back |
| `editor.toggle_line_comment` | `space /` | vim | NvChad `<leader>/` |
| `lsp.format` | `space f m` | vim | NvChad `<leader>fm` |
| `view.cheatsheet` | `space c h` | vim | NvChad `<leader>ch` |
| `whichkey.leader` | `space w K` | vim | NvChad `<leader>wK` |
| `scratch.new` | `space b` | vim | NvChad `<leader>b`: a new empty buffer; `:w name` gives it a file |
| `lsp.rename` / `lsp.code_action` / `git.status_pane` / `git.graph` / `picker.recent` / `find.find` | `space r a` / `space c a` / `space g t` / `space c m` / `space f o` / `space f z` | vim | NvChad `<leader>ra`, `ca`, `gt`, `cm`, `fo`, `fz`. Themes are `space t t` |
| `view.toggle_relative_numbers` / `lsp.diagnostics` | `space r n` / `space d s` | vim | NvChad `<leader>rn`, `<leader>ds` |
| `lsp.goto_type_definition` / `term.scratch_toggle` / `buffer.prev` / `buffer.next` | `space D` / `alt+h` / `[ b` / `] b` | vim | NvChad `<leader>D` and `<A-h>`, Neovim `[b` / `]b` |
| `view.focus_top` / `view.focus_bottom` / `view.focus_previous` | `ctrl+w t` / `ctrl+w b` / `ctrl+w p` | vim | Neovim `Ctrl-W t` / `b` / `p`. From the tree, `Ctrl-W p` returns to the window you left |
| `view.focus_next_split` / `view.focus_prev_split` | `ctrl+w w` / `ctrl+w W` | vim | Neovim's window walk, both ways |
| `view.focus_next_split` / `view.focus_prev_split` | `ctrl+alt+shift+→` / `ctrl+alt+shift+←` | standard | the same walk; *Walking the splits* in `docs/CONFIG.md` shows how to put it on `Shift+Cmd+→/←` in ghostty |
| `view.move_to_new_tab` | `ctrl+w T` | vim | Neovim `Ctrl-W T`: the focused split moves to a tab page of its own (a pane alone on its page stays put, with a message) |
| `view.toggle_zoom` | `ctrl+w z`, `space s z` / `ctrl+k ctrl+m` | vim / standard | the focused split fills the page; again restores. Standard uses VS Code's Toggle Maximize Editor Group. `Ctrl-W o` keeps Neovim's meaning, close the others |
| `lsp.goto_definition` / `lsp.goto_declaration` / `lsp.references` / `lsp.hover` | `g d` / `g D` / `g r` / `K` | vim | Neovim |
| `lsp.prev_diagnostic` / `lsp.next_diagnostic` | `[ d` / `] d` | vim | Neovim |
| `file.cut` / `file.copy` / `file.paste` / `file.duplicate` | `ctrl+x` / `ctrl+c` / `ctrl+v` / `ctrl+d` | both, in the tree and the Files pane | under vim the Files pane keeps `Ctrl-D` / `Ctrl-U` as half-page scroll |
| `file.copy` / `file.paste` | `y y` / `P` | vim, in the tree and the Files pane | two keys, so a stray press cannot copy a file. `D` duplicates in both profiles |
| `file.new` / `file.rename` / `file.delete` / `file.cut` / `tree.refresh` / `tree.expand_all` / `tree.collapse_all` | `a` / `r` / `d` / `x` / `R` / `E` / `W` | vim, in the tree | nvim-tree's own keys; delete asks first. The standard profile keeps `r` as refresh |
| `sessions.next_waiting` / `sessions.prev_waiting` | `space a j` / `space a k` · `ctrl+alt+n` / `ctrl+alt+shift+n` | vim · standard | focus the next / previous session that is ready for you — waiting on you, or finished / ended since you last looked — wrapping, skipping the rest. Works from a focused terminal too |
| `sessions.focus_1` … `sessions.focus_9` | `space a 1` … `space a 9` · `ctrl+alt+1` … `ctrl+alt+9` | vim · standard | focus the Nth session as SESSIONS lists it — the muted digit in the column left of its card, under the on-screen / ready mark, and the sessions table's `#` — bringing up its tab page; in the sessions mode it is swapped into the focused column. `space s` is the splits' group and `ctrl+1…9` the tabs', so each profile takes the sessions keys one step over. Past the last card it toasts |
| `ai.focus_next_session` / `ai.focus_prev_session` | `ctrl+alt+pagedown` / `ctrl+alt+pageup` | both | every Claude Code / Codex pane in one ring — page order, then layout order — wrapping and crossing tab pages. `ctrl+alt+→/←` is `buffer.next` / `buffer.prev`, so the ring takes the buffer walk's page keys one modifier up. Works from a focused terminal too |
| `ai.focus_next_session` / `ai.focus_prev_session` | `] a` / `[ a` | vim, an editor | the same ring through the handler's `]` / `[` pairs (Neovim's argument list, which mnml has none of). A session pane is a terminal, so from inside one it is the chord above |
| `term.search` / next / previous | `/` / `?` / `n` / `N` | vim, a terminal pane in terminal-normal mode | as in Neovim's terminal buffer: `/` searches down, `?` up, `n` repeats, `N` reverses, wrapping with a message. Enter lands and closes |
| `term.search` | `ctrl+f` (whatever `find.find` is on) | standard, a terminal pane | as in VS Code's terminal. Enter goes to the previous (older) match and Shift+Enter to the next; Esc closes with the match selected. Under vim `Ctrl-F` goes to the shell |
| `whichkey.leader` | `space` in the tree, the git status pane and every other window | vim | NvChad's leader works from any window. In the standard profile Space keeps the pane's own meaning |
| git status: stage / unstage | `-` | vim (and `-` in both) | fugitive's key; Space is the leader under vim |
| `app.command_line` | `:` in every pane | vim | `:` opens the command line from any normal-mode window, as in Neovim |

## Sections and columns

Every activity section lives in one of two columns, left or right. The
vim profile moves them with Neovim's window keys, read from a focused
section; the standard profile has no chord for the moves — use the
palette, the rail's right-click menu (*Move to right / left side*) or
`:sidebar left|right`.

| command | vim | standard / both |
|---|---|---|
| `view.move_section_left` | `Ctrl-W H` in a section or the tree; `<leader>sH` | — (`:sidebar left`, the rail menu, the palette) |
| `view.move_section_right` | `Ctrl-W L` in a section or the tree; `<leader>sL` | — (`:sidebar right`) |
| `view.toggle_tree` (the left column) | `Ctrl-N`, `<leader>te` (`<leader>e` focuses it) | `Ctrl+B` |
| `view.toggle_right_panel` (the right column) | `<leader>tr` | `Ctrl+Shift+B` (both), `Ctrl+Alt+B` |
| `view.focus_right_panel` | — | — (the palette) |
| `view.right_panel_next_tab` / `prev_tab` | `<leader>t]` / `<leader>t[` | — |
| `view.right_panel_close_tab` | `<leader>tx` | `Ctrl+Alt+W` (both) |
| `view.toggle_bottom_panel` (the dock) | `Ctrl+Shift+J` (both) | `Ctrl+Shift+J` (both) |
| `view.host_active_in_bottom_panel` | — (the palette; run it again on a docked pane to send it back) | — |
| a section into the dock / back up | `Ctrl-W J` / `K` in a section or the tree | — (`:sidebar bottom`, the rail menu) |
| focus the dock / leave it | `Ctrl-W j` / `k` | — |
| `view.sidebar_pin` (dock a revealed column for the session) | `<leader>E` | `Ctrl+K Ctrl+B` |

With `ui.sidebar = .auto` or `.hidden` the columns float over the
editor instead of taking room beside it: `view.toggle_tree` and
`view.toggle_right_panel` show and hide that overlay, and every command
that shows a section (`view.activity_*`, `view.focus_tree`,
`<leader>e`) reveals it. `view.sidebar_pin` docks the column for the
rest of the session without editing the config; run it again to unpin.

In an editor `Ctrl-W H` / `L` keep Neovim's meaning — move the split to
the far edge; only a focused section or the tree reads them as a side
move. `Ctrl-W J` / `K` work the same way: the section goes into the dock
and comes back up to the column it came from. Lowercase `j` / `k` move
the focus, and reach the dock because it sits under everything.
`Ctrl-W + / - / > / <` resize the window the keys are in: a row of the
dock, or two cells of a focused column.

## Debugger

Both profiles reach every `dap.*` command: the vim profile through
nvim-dap's leader chords (a `+debug` group under `<leader>d`), the
standard profile through VS Code's function keys. The function keys work
in both profiles, so a vim user has them too.

| command | vim | standard / both |
|---|---|---|
| `dap.toggle_breakpoint` | `<leader>db` | `F9` |
| `dap.toggle_breakpoint_conditional` | `<leader>dB` | `Shift+F9` |
| `dap.set_breakpoint_log_message` | `<leader>dl` | — |
| `dap.run` (start explicitly) | — | — (palette) |
| `dap.continue` (starts a session when there is none) | `<leader>dc` | `F5` |
| `dap.next` | `<leader>do` | `F10` |
| `dap.step_in` | `<leader>di` | `F11` |
| `dap.step_out` | `<leader>dO` | `Shift+F11` |
| `dap.pause` | `<leader>dp` | — |
| `dap.restart` | `<leader>dR` | `Ctrl+Shift+F5` |
| `dap.terminate` | `<leader>dt` | `Shift+F5` |
| `dap.repl` (focus the debug console) | `<leader>dr` | — |
| `dap.add_watch` | `<leader>dw` | — |
| `dap.exceptions` (exception breakpoints, a picker) | `<leader>de` | — |
| `dap.toggle_panel` (the DEBUG section) | `<leader>du` | `Ctrl+Shift+D` (`view.activity_debug`) |
| `dap.evaluate_hover` | `<leader>dh`, and `K` while stopped | — |
| `dap.show` (the section and the console) | — | — (palette) |

The `+debug` group, and the `+lsp` rows under `r` such as NvChad's
`<leader>ra` (rename), appear only in the vim profile's leader popup.

## The leader popup

The popup that opens after the leader (`Space` in vim, a pause after
`Ctrl+K` in standard) lists exactly the chords you can type: a chord
typed fast and the same chord walked through the popup are one entry,
labelled with the command's short name. Its header names the key that
opened it — `<leader>` in vim, `Ctrl+K` in standard.

Following NvChad: `<leader>h` / `<leader>v` are the terminals and the
HTTP group is `<leader>R`; `<leader>w` is the prefix of `wK`, not a
save; `<leader>x` closes the buffer. The waiting-session jumps are
`<leader>aj` / `ak` under `+ai/term`, the Lua line runner `<leader>Ll`
under `+lang/run`, and the split zoom `<leader>sz`.

Inside the popup `Backspace` goes back one level; a key that is not a
character — an arrow, Enter, a function key — leaves the popup open; and
a key no row carries says `no leader mapping: Ctrl+K …` / `<leader>…`
instead of closing it silently. A vim operator waiting for its next key
(`g`, `z`, `Ctrl-W`) shows the same popup titled `Vim: <prefix>`,
without the glyph column, since its rows are motions rather than groups.

Every row has a glyph and every group its chord count —
`󰍉 f → +find (8)` — and a sub-level's header repeats that group's row
(`<leader>f  +find (8)`; in standard, `Ctrl+K f  +find (4)`). Each glyph
has a one-cell `--ascii` twin.

## Ctrl-O, Ctrl-I and Tab in the vim profile

- **Normal-mode `Ctrl-O`** goes back through the jumplist (`nav.back`);
  **insert-mode `Ctrl-O`** runs one normal-mode command. That is why the
  file picker's `Ctrl+O` is standard-only.
- **`Tab` / `Shift+Tab`** are NvChad's bufferline (`buffer.next` /
  `buffer.prev`), not Neovim's jumplist-forward. `Ctrl-I` and `Tab` are
  the same byte on a terminal without the kitty keyboard protocol, so
  there the bufferline wins; with the kitty protocol `Ctrl-I` still goes
  forward in the jumplist (`nav.forward`), and `Ctrl+Tab` does on every
  terminal.

## A shifted Tab has one spelling

No terminal sends Tab with a Shift modifier: it sends its own back-tab
code instead. So `shift+tab`, `<S-Tab>`, `shift+backtab` and `backtab`
all name the same chord, and `ctrl+shift+tab` is `ctrl+backtab` —
whether you write it in `.keys`, a `.test` script or an IPC `key`
command.

## Shifted function keys on a terminal without the kitty protocol

Nine commands sit on `Shift+F` keys in both profiles (`find.prev`
Shift+F3, `dap.terminate` Shift+F5, `git.diff_prev_file` Shift+F7,
`git.conflict_prev` Shift+F8, `dap.toggle_breakpoint_conditional`
Shift+F9, `view.context_menu_at_focus` Shift+F10, `dap.step_out`
Shift+F11, `lsp.references` Shift+F12, and `dap.restart` on
Ctrl+Shift+F5); the standard profile adds `help.focus` on Shift+F1 and
`lsp.peek_definition_overlay` on Ctrl+Shift+F10. How they arrive depends
on the terminal:

| terminal | Shift+F5 arrives as | read as |
|---|---|---|
| ghostty, kitty, WezTerm, foot, xterm, Windows Terminal, VTE, Konsole | `CSI 15;2 ~` (xterm's modifier parameter) | `shift+f5` |
| Terminal.app (`TERM_PROGRAM=Apple_Terminal`) | `CSI 25 ~` — the VT220's F13 | `shift+f5` |
| rxvt, the Linux console (`TERM=rxvt*` / `linux`) | `CSI 28 ~` — F15 | `shift+f5` |

The last two send a different key rather than a modified one, and mnml
reads them by what `$TERM_PROGRAM` / `$TERM` name: Terminal.app sends
Shift+F5–F12 as F13–F20; rxvt and the Linux console send Shift+F3–F10
as F13–F20 and Shift+F11 / F12 as `CSI 23 $` / `CSI 24 $`; anywhere else
F13–F20 are xterm's names for Shift+F1–F8. Two chords stay out of reach
there: rxvt's Shift+F1 / F2 are the same bytes as F11 / F12, and neither
Terminal.app nor rxvt sends anything for Ctrl+Shift+F5 — `dap.restart`
has `<leader>dR` and the palette. On rxvt the standard profile's
`help.focus` (Shift+F1) is out of reach the same way; it is in the
palette too.

## Quick open's prefixes — and the non-kitty route to the palette

`Ctrl+P` opens *Open file*, and the first character typed picks a mode,
the way VS Code's quick open does:

| prefix | mode |
|---|---|
| `>` | the command palette, with the rest of what you type as its query |
| `@` | the symbols of the active buffer (`lsp.symbols`) |
| `:` | go to line — `:12`, or `:12:4` for a column |
| `?` | the list of these four; a row is a way into its mode |

Only a **leading** prefix counts, so `src/a>b.txt` stays a path.

`>` matters on some terminals. The palette is on `Ctrl+Shift+P` and the
leader's `space p`, and a terminal without the kitty keyboard protocol
cannot tell `Ctrl+Shift+P` from `Ctrl+P` — both are byte `0x10`. On
Terminal.app, Alacritty's default config or tmux without passthrough,
`Ctrl+Shift+P` therefore opens the file picker, and `>` is the way to
every command that has no chord of its own (`view.focus_dock`,
`view.dock_cycle_mode`, `editor.highlight_this_file`,
`view.reveal_in_tree`, …). `keys.doctor` does not test for this.

## Insert mode and the window keys

`Ctrl-H` / `Ctrl-J` move between windows in the vim profile, but in
insert mode the editor receives them as Neovim does (backspace and
newline): the window move fires from normal mode or from a pane that is
not an editor. That matches NvChad, whose `<C-h>` window map is
normal-mode only.
