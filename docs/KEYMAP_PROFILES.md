# Keymap profiles — the vim / standard split (D4b)

mnml-zig binds every default chord to a profile. `both` chords fire in
either profile; `vim` chords only when `editor.input_style = .vim`;
`standard` only under `.standard`. `.keys.global` in `config.zon` still
applies to both and `.keys.vim` / `.keys.standard` overlay their profile.

This is the **spike-scope** split: Rust defaults into `both`, a small set of
mechanical rules, and the NvChad leader menus a vim user reaches for first.
The full NvChad `mappings.lua` derivation is Phase 1 (`TODO(D4b)` in
`src/commands/specs.zig`).

## Rules

1. **vim reserves** `ctrl+w g d u e y r n h j t f b o` — each has an insert- or
   normal-mode meaning the editor must receive. Any default chord starting
   with one of these is `standard` only.
2. **`ctrl+k …` menus are the standard leader.** NvChad uses `ctrl+k` for
   window-up; the vim profile keeps `space` as its only which-key leader.
   A bare `ctrl+k` is therefore bound on its own (`whichkey.leader`) AND
   is the prefix of eighteen `ctrl+k …` chords. **Chord resolution wins:**
   `keymap.resolveSeq` answers `pending_with_fallback`, the tail key
   completes the chord, and the popup is only the `timeoutlen` fallback
   for a `ctrl+k` nothing followed. Anything that expires a pending chain
   without reading the deadline turns that on its head — the popup opens
   on the `ctrl+k` and eats the tail, and none of the eighteen can fire.
   That is what the `.test` runner and the headless loop used to do, so
   `Ctrl+K Ctrl+I` (hover, which the Info panel advertises) could not be
   driven at all; `app/driver.zig`'s `expireChords` hook reads the same
   clock `App.tick` does. `tests/e2e/chord_ctrl_k_prefix.test`.
3. **`ctrl+]` / `ctrl+[`** indent / outdent in `standard` (VS Code);
   `editor.bracket_match` keeps `ctrl+]` in `vim`.
4. **`ctrl+l`** is select-line in standard and window-right in vim, so
   `view.redraw` has no chord in either profile (palette-reachable).
5. **Collision rule:** when a profile addition lands on a chord some `both`
   command already owned, the addition wins in that profile and the displaced
   chord moves to the other profile. Nothing is silently dropped.
6. `nav.back` / `nav.forward` are platform-split at comptime (`alt+left`/
   `alt+right` are not bound on macOS).

## Every move made

| command | chord | from | to | why |
|---|---|---|---|---|
| `view.fullscreen` | `ctrl+k z` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `view.close_others` | `ctrl+k w` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `find.find` | `ctrl+f` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `find.replace` | `ctrl+h` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `editor.goto_line` | `ctrl+g` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `editor.bracket_match` | `ctrl+]` | both | vim | standard: ctrl+] / ctrl+[ indent / outdent (VS Code) |
| `editor.add_cursor_at_next_word` | `ctrl+d` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `view.focus_right_panel` | `ctrl+k r` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `file.new` | `ctrl+n` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `keys.edit` | `ctrl+k ctrl+s` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `picker.recent` | `ctrl+r` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `buffer.close` | `ctrl+w` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `tab.new` | `ctrl+k n` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `theme.toggle` | `ctrl+k t` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `view.switch_workspace` | `ctrl+k ctrl+o` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `view.activity_sessions` | `ctrl+k s` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `git.blame_toggle` | `ctrl+k b` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `git.commit` | `ctrl+k g c` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `lsp.hover` | `ctrl+k ctrl+i` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `integrations.show_details` | `ctrl+k i d` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `snippet.expand` | `ctrl+j` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `picker.workspace_symbol` | `ctrl+t` | both | standard | vim reserves this ctrl chord for the editor (insert/normal meaning) |
| `whichkey.leader` | `ctrl+k` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `view.focus_left` | `ctrl+k ctrl+left` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `view.focus_right` | `ctrl+k ctrl+right` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `view.focus_up` | `ctrl+k ctrl+up` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `view.focus_down` | `ctrl+k ctrl+down` | both | standard | vim: ctrl+k is NvChad window-up; the ctrl+k menus are the standard profile's leader |
| `editor.indent_line` | `ctrl+]` | (new) | standard | VS Code indent |
| `view.toggle_tree` | `ctrl+b` | both | standard | vim: `Ctrl-B` is page-back (the pair of `Ctrl-F`); it was toggling the sidebar |
| `editor.outdent_line` | `ctrl+[` | (new) | standard | VS Code outdent |
| `picker.files` | `space f f` | both | both | NvChad <leader>ff (already the Rust default) |
| `picker.files` | `ctrl+o` | both | standard | vim: `ctrl+o` is the jumplist (`nav.back`, with `ctrl+i` forward) in NORMAL and one-shot normal in INSERT (`:help i_CTRL-O`) — the chord chain runs before the vim handler, so a `both` binding shadowed both: the picker opened over insert mode and ate the next keys. `ctrl+p` stays in both |
| `find.grep` | `space f w` | (new) | vim | NvChad <leader>fw |
| `picker.buffers` | `space f b` | both | both | NvChad <leader>fb (already the Rust default) |
| `view.toggle_tree` | `ctrl+n` | (new) | vim | NvChad <C-n> |
| `view.focus_tree` | `space e` | (new) | vim | NvChad <leader>e is `NvimTreeFocus`: the tree takes the keys, opened first when hidden — never hidden. `<C-n>` (`NvimTreeToggle`) toggles, and the tree it opens is focused; VS Code's Ctrl+B leaves the focus in the editor |
| `buffer.close` | `space x` | (new) | vim | NvChad <leader>x |
| `term.shell_bottom` | `space h` | (new) | vim | NvChad <leader>h horizontal term |
| `term.shell_right` | `space v` | (new) | vim | NvChad <leader>v vertical term |
| `buffer.next` | `tab` | (new) | vim | NvChad <Tab> bufferline |
| `buffer.prev` | `shift+tab` | (new) | vim | NvChad <S-Tab> bufferline |
| `view.focus_left` | `ctrl+h` | (new) | vim | NvChad <C-h> — from the leftmost split it enters the sidebar (nvim-tree is a window); `ctrl+l` from the sidebar returns; `Ctrl-W w` past the last split lands there too |
| `view.focus_down` | `ctrl+j` | (new) | vim | NvChad <C-j> |
| `view.focus_up` | `ctrl+k` | (new) | vim | NvChad <C-k> |
| `view.focus_right` | `ctrl+l` | (new) | vim | NvChad <C-l> |
| `editor.toggle_line_comment` | `space /` | (new) | vim | NvChad <leader>/ |
| `lsp.format` | `space f m` | (new) | vim | NvChad <leader>fm |
| `view.cheatsheet` | `space c h` | (new) | vim | NvChad <leader>ch |
| `whichkey.leader` | `space w K` | (new) | vim | NvChad <leader>wK |
| `lsp.rename` / `lsp.code_action` / `git.status_pane` / `git.graph` / `picker.recent` / `find.find` | `space r a` / `space c a` / `space g t` / `space c m` / `space f o` / `space f z` | (new) | vim | NvChad mappings.lua: `<leader>ra` LSP renamer, `<leader>ca` code action, `<leader>gt` git status, `<leader>cm` git commits, `<leader>fo` oldfiles, `<leader>fz` find in current buffer. `<leader>th` (themes) stays `theme.pick` under `space t t`: `t h` is the Rust popup's hidden-files toggle |
| `view.focus_top` / `view.focus_bottom` / `view.focus_previous` | `ctrl+w t` / `ctrl+w b` / `ctrl+w p` | (new) | vim, through the handler's `Ctrl-W` prefix | `:help CTRL-W_t` / `CTRL-W_b` / `CTRL-W_p`; from the tree `Ctrl-W p` returns to the window that was left |
| `view.focus_next_split` / `view.focus_prev_split` | `ctrl+w w` / `ctrl+w W` | (new) | vim, through the handler's `Ctrl-W` prefix | `:help CTRL-W_w` / `CTRL-W_W` — the split walk both ways; the spec lists them in `Keys.vim_handler`, which the cheatsheet, palette and `docs/commands.md` show and the keymap never binds |
| `view.focus_next_split` / `view.focus_prev_split` | `ctrl+alt+shift+right` / `ctrl+alt+shift+left` | (new) | standard | Terminal.app's `Shift+Cmd+→/←` between tabs; the two-modifier arrows are taken (`ctrl+shift` / `alt+shift` extend a selection by a word, `ctrl+alt` is `buffer.next` / `buffer.prev`). `docs/CONFIG.md` → *Walking the splits* has the ghostty line that puts it on `Shift+Cmd+→/←` |
| `view.move_to_new_tab` | `ctrl+w T` | (new) | vim, through the handler's `Ctrl-W` prefix | `:help CTRL-W_T` — the focused split leaves the page for one of its own, the partner of `Ctrl-W s` / `v`. A pane alone on its page is refused out loud |
| `view.toggle_zoom` | `ctrl+w z` / `ctrl+k ctrl+z` | (new) | vim, through the handler's `Ctrl-W` prefix / standard | tmux's zoom letter — the focused split has the page, again restores; the spec lists `ctrl+w z` in `Keys.vim_handler`. Neovim's own `Ctrl-W z` closes the preview window, which mnml does not have; `Ctrl-W o` is left as Neovim's `:only`, which closes the others. Standard: VS Code's zen chord `ctrl+k z` is `view.fullscreen` here, so the zoom takes `ctrl+k ctrl+z` |
| `lsp.goto_definition` | `g d` | (new) | vim | Neovim gd |
| `lsp.goto_declaration` | `g D` | (new) | vim | Neovim gD |
| `lsp.references` | `g r` | (new) | vim | Neovim gr |
| `lsp.hover` | `K` | (new) | vim | Neovim K |
| `lsp.prev_diagnostic` | `[ d` | (new) | vim | Neovim [d |
| `lsp.next_diagnostic` | `] d` | (new) | vim | Neovim ]d |
| `file.cut` / `file.copy` / `file.paste` / `file.duplicate` | `ctrl+x` / `ctrl+c` / `ctrl+v` / `ctrl+d` | (new) | both, tree and Files pane focus only | handled by the tree / Files pane key handlers, not the keymap: neither edits text, so the editor's insert-mode meanings cannot want them there (Rust parity). Under vim the Files pane's `ctrl+d` / `ctrl+u` stay half-page scroll and the ctrl chords fall through — see the next row |
| `file.copy` / `file.paste` | `y y` / `P` | (new) | vim, tree and Files pane focus only | ranger's vocabulary: two keys so a stray press cannot copy a file; a stray key between the two cancels. `D` duplicates in both profiles |
| `file.new` / `file.rename` / `file.delete` / `file.cut` / `tree.refresh` / `tree.expand_all` / `tree.collapse_all` | `a` / `r` / `d` / `x` / `R` / `E` / `W` | (new) | vim, tree focus only | nvim-tree's default `on_attach` verbs (create, rename, delete — a confirm box — cut, refresh, expand all, collapse all); `d d` cut gave way to `d` delete. The standard profile keeps `r` = refresh and none of the others |
| `sessions.next_waiting` / `sessions.prev_waiting` | `space s n` / `space s N` (vim) · `ctrl+alt+n` / `ctrl+alt+shift+n` (standard) | (new) | vim / standard | Focus the next / previous pane whose child is blocked on a question (`sessions.needsYou`), in pane order, wrapping. The vim pair sits in the `+split` group, whose `n` / `N` were free — Neovim's own `n` / `N` is "the next / previous match", the same reading; `<leader>s n` / `s N` are vim-only rows, so the standard `Ctrl+K` popup keeps the rows it had. The standard pair collides with nothing in `specs.zig` (`ctrl+alt+` holds only the cursor adders, the buffer and split-walk arrows, `w` and `enter`), and a focused terminal hands it to the app: a modified chord the keymap binds reaches the chord chain before the child (`dispatch.ptyKey`) |
| `term.search` / `term.search_next` / `term.search_prev` | `/` / `n` / `N` | (new) | vim, a terminal pane in terminal-normal only | handled by the terminal pane's key handler (`pty_search.termNormalKey`), not the keymap: in terminal mode every plain key is the child's, and in an editor `/` `n` `N` are vim's own search. Neovim's terminal buffer answers `/` in terminal-normal the same way. In the bar Enter lands and closes, as vim's `/` does |
| `term.search` | `ctrl+f` (whatever `find.find` is bound to) | (new) | standard, a terminal pane only | the pane's key handler reads the editor's find chord as the terminal's (`pty_search.findChord`), as VS Code's terminal takes `Ctrl+F`; `find.find` itself is untouched, so a rebind of it moves both. Under vim `ctrl+f` stays the child's (readline's forward-char). In the bar Enter / Shift+Enter step, wrapping; Esc closes with the match selected |
| git status stage toggle | `-` | `space` | vim (and `-` in both) | fugitive's `-` toggles the row's staging; the pane's hint row reads `- toggle` under vim |
| `app.command_line` | `:` in every pane and section that did not take it | nothing (the letters after it ran the pane's verbs) | vim | `:` opens the command line from every Normal-mode window in Neovim — terminal-normal, help, nvim-tree, the cheatsheet |

## Sections and columns

Every activity section has a side (`src/app/side.zig`); the two columns
replace Rust's sidebar and tabbed right panel. The vim chords are
Neovim's window family read from a section; the standard profile has
no chord for the moves — the palette, the rail's right-click menu
(*Move to right / left side*) and `:sidebar left|right` are its doors.
Pinned by the `ctrlWCommand` and `vim:` tests in `src/app/side.zig`.

| command | vim | standard / both |
|---|---|---|
| `view.move_section_left` | `Ctrl-W H` in a section or the tree; `<leader>sH` | — (`:sidebar left`, the rail menu, the palette) |
| `view.move_section_right` | `Ctrl-W L` in a section or the tree; `<leader>sL` | — (`:sidebar right`) |
| `view.toggle_tree` (the left column) | `Ctrl-N`, `<leader>te` (`<leader>e` is `view.focus_tree`) | `Ctrl+B` |
| `view.toggle_right_panel` (the right column) | `<leader>tr` | `Ctrl+Shift+B` (both) |
| `view.focus_right_panel` | — | `Ctrl+K r` |
| `view.right_panel_next_tab` / `prev_tab` | `<leader>t]` / `<leader>t[` | — |
| `view.right_panel_close_tab` | `<leader>tx` | `Ctrl+Alt+W` (both) |
| `view.toggle_bottom_panel` (the dock) | `Ctrl+Shift+J` (both) | `Ctrl+Shift+J` (both) |
| `view.host_active_in_bottom_panel` | — (the palette; run again on a docked pane to send it back) | — |
| section → the dock / back up | `Ctrl-W J` / `K` in a section or the tree | — (`:sidebar bottom`, the rail menu) |
| focus the dock / leave it | `Ctrl-W j` / `k` (the ordinary focus step) | — |
| `view.sidebar_pin` (dock a revealed column for the session) | `<leader>E` | `Ctrl+K Ctrl+B` |

// changed (sidebar-autohide): under `ui.sidebar = .auto` / `.hidden`
the columns are not docked, so `view.toggle_tree` and
`view.toggle_right_panel` toggle the OVERLAY that floats over the
editor, and every command that shows a section (`view.activity_*`,
`view.focus_tree`, `<leader>e`) reveals it. `view.sidebar_pin` is the
way back to a docked column without editing the config: it reads
`ui.sidebar = always` for the rest of the session, and again unpins.
Both profiles carry the chord and the `<leader>`/`Ctrl+K` popup row.

In an editor `Ctrl-W H` / `L` keep Neovim's meaning — move the split to
the far edge; only a focused section or the tree reads them as a side
move. // changed (bottom-dock): `Ctrl-W J` / `K` read the same way —
the section goes into the dock and comes back up to the column it came
from — and they are not command ids, since the dock's two ids are
Rust's `toggle` and `host_active`. Lowercase `j` / `k` stay the focus
step, and reach the dock because it is a window under everything.
`Ctrl-W + / - / > / <` resize the window the keys are in: a row of the
dock, or two cells of a focused column.

## Debugger

Two complete doors to the same `dap.*` commands, neither a patch on the
other: the vim profile gets nvim-dap's leader chords (a `+debug`
which-key group under `<leader>d`), the standard profile VS Code's
function keys. The F-keys are `both`, so a vim user keeps them too.

| command | vim | standard / both |
|---|---|---|
| `dap.toggle_breakpoint` | `<leader>db` | `F9` |
| `dap.toggle_breakpoint_conditional` | `<leader>dB` | `Shift+F9` |
| `dap.set_breakpoint_log_message` | `<leader>dl` | — |
| `dap.run` (the explicit start) | — | — (palette) |
| `dap.continue` (starts a session when there is none) | `<leader>dc` | `F5` |
| `dap.next` | `<leader>do` | `F10` |
| `dap.step_in` | `<leader>di` | `F11` |
| `dap.step_out` | `<leader>dO` | `Shift+F11` |
| `dap.pause` | `<leader>dp` | — |
| `dap.restart` | `<leader>dR` | `Ctrl+Shift+F5` |
| `dap.terminate` | `<leader>dt` | `Shift+F5` |
| `dap.repl` (focus the debug console) | `<leader>dr` | — |
| `dap.add_watch` | `<leader>dw` | — |
| `dap.toggle_panel` (the DEBUG section) | `<leader>du` | `Ctrl+Shift+D` (`view.activity_debug`) |
| `dap.evaluate_hover` | `<leader>dh`, and `K` while stopped | — |
| `dap.show` (the section and the console) | — | — (palette) |

Every chord above is checked against `src/commands/specs.zig` by the
`both key profiles` test in `src/app/cmd_dap.zig`, which also asserts
that no `dap.*` chord is standard-only. The `+debug` and `+lsp`-on-`r`
which-key groups are `vim_only` (`src/app/whichkey.zig`): the standard
profile's `Ctrl+K` popup keeps the reference editor's rows. `r` carries
NvChad's `<leader>ra` (LSP rename), which that popup does not list, so
the vim profile shows the row and the standard one does not.

The popup's header names the key that opened it in the ACTIVE profile —
`<leader>` in vim, `Ctrl+K` in standard (`whichkey.leaderLabel` /
`leaderGap`) — and so does the dead-end toast. It used to say `<leader>`
in both, which is what the reference editor does (`docs/PARITY.md`) and
which told a VS Code user, on the same screen whose Info panel reads
`[Ctrl+K Ctrl+I] Hover`, to press a leader that profile does not have.
The rows are already per-profile (`Entry.vim_only`), so a standard popup
never listed a chord it could not run; only the header did.
`tests/e2e/whichkey_standard_title.test`.

Inside the popup `<BS>` climbs back one level (the reference plugin's
key); a key that is not a character — an arrow, Enter, a function key —
leaves the popup where it is; and a key no row carries toasts `no
leader mapping: Ctrl+K …` / `<leader>…` rather than dismissing it
silently. A vim operator with a pending prefix (`g`, `z`, `ctrl+w`) paints the same
popup titled `Vim: <prefix>` — with no glyph column, since its rows are
motions rather than groups.

Since 2026-09-14 the popup reads the reference plugin's way in both
profiles: a glyph before every row and the chord count after every
group label — `󰍉 f → +find (7)`, a leaf wearing its group's face
dimmed, and a sub-level's header carrying that group's own row
(`<leader>f  +find (7)`). The count is read off the tree
(`whichkey.chordCount`), so a chord added under a group moves it; the
faces come from `src/ui/whichkey_glyph.zig`, which takes the rail's and
the devicon table's glyphs rather than picking new ones. Each has a
one-cell `--ascii` twin. This is a deliberate departure from the
reference editor's popup, which has neither (`docs/PARITY.md`).

## Ctrl-O / Ctrl-I / Tab in the vim profile

- **NORMAL `Ctrl-O`** is the jumplist (`nav.back`); **INSERT `Ctrl-O`** is
  one-shot normal (`:help i_CTRL-O`). The file picker's `ctrl+o` is
  `standard` only for that reason.
- **`Tab` / `S-Tab`** are NvChad's bufferline (`buffer.next` / `buffer.prev`),
  not Neovim's jumplist-forward. `Ctrl-I` and `Tab` are one byte on a
  terminal without the kitty keyboard protocol, so the bufferline wins
  there; under kitty `ctrl+i` still reaches `nav.forward` (the handler's
  ctrl table), and `ctrl+tab` does on every terminal. The choice follows
  NvChad because that is what a vim user's hands expect on `Tab`.

## A shifted Tab has one spelling

No terminal sends Tab with a shift modifier: it sends its own back-tab
code and drops the modifier, and `tui/loop.zig`'s `translateKey` folds
vaxis's form the same way. So `Key.canonical` (`src/core/key.zig`) is the
one place the spelling is settled, and `keymap.parseKeySpec` goes through
it — `shift+tab`, `<S-Tab>`, `shift+backtab` and `backtab` are one chord,
and `ctrl+shift+tab` is `ctrl+backtab`. That holds for the spec table, a
`.keys.*` line in the config, a `.test` script's `key` directive and the
IPC `key` verb alike, so a script can no longer synthesise a key a
terminal never sends. Before it did, and `buffer.prev` was dead on
`Ctrl+Shift+Tab` and on NvChad's `<S-Tab>` in every terminal while the
corpus reported it working.

## Shifted function keys on a terminal without the kitty protocol

Nine commands sit on `Shift+F`-keys in both profiles (`find.prev`
Shift+F3, `dap.terminate` Shift+F5, `git.diff_prev_file` Shift+F7,
`git.conflict_prev` Shift+F8, `dap.toggle_breakpoint_conditional`
Shift+F9, `view.context_menu_at_focus` Shift+F10, `dap.step_out`
Shift+F11, `lsp.references` Shift+F12, and `dap.restart` on
Ctrl+Shift+F5). How they arrive depends on the terminal:

| terminal | Shift+F5 arrives as | read as |
|---|---|---|
| ghostty, kitty, WezTerm, foot, xterm, Windows Terminal, VTE, Konsole | `CSI 15;2 ~` (xterm's modifier parameter) | `shift+f5` |
| Terminal.app (`TERM_PROGRAM=Apple_Terminal`) | `CSI 25 ~` — the VT220's F13 | `shift+f5` |
| rxvt, the Linux console (`TERM=rxvt*` / `linux`) | `CSI 28 ~` — F15 | `shift+f5` |

The last two send a different KEY rather than a modified one, and the
parser mnml uses drops those codes; `src/tui/legacy_fkeys.zig` reads
them first, by the convention `$TERM_PROGRAM` / `$TERM` names:
Terminal.app sends Shift+F5–F12 as F13–F20; rxvt and the Linux console
send Shift+F3–F10 as F13–F20 and Shift+F11 / F12 as `CSI 23 $` /
`CSI 24 $`; anywhere else F13–F20 are xterm's own names for
Shift+F1–F8. `ESC O <m> P…S` (SS3 with a modifier digit) reads its
modifier too. Two chords stay out of reach there: rxvt's Shift+F1 /
F2 are the same bytes as F11 / F12, and neither Terminal.app nor rxvt
sends anything for Ctrl+Shift+F5 — `dap.restart` has `<leader>dR` and
the palette.

## Quick open's prefixes — and the non-kitty route to the palette

`Ctrl+P` opens *Open file*, and the FIRST character typed picks a mode,
the way VS Code's one quick-open widget does:

| prefix | mode |
|---|---|
| `>` | the command palette, with the rest of what you type as its query |
| `@` | the symbols of the active buffer (`lsp.symbols`) |
| `:` | go to line — `:12`, or `:12:4` for a column |
| `?` | the list of these four; a row is a way into its mode |

Only a **leading** prefix counts, so `src/a>b.txt` stays a path.

`>` is load-bearing rather than decorative. `palette` is bound to
`ctrl+shift+p` and nothing else, and a terminal without the kitty
keyboard protocol cannot tell `Ctrl+Shift+P` from `Ctrl+P` — both are
byte `0x10` — so on Terminal.app, Alacritty's default config or plain
tmux without passthrough, `Ctrl+Shift+P` arrives as `ctrl+p` and opens
the file picker. `>` there is the door to every command that has no
chord of its own (`view.focus_dock`, `view.dock_cycle_mode`,
`editor.highlight_this_file`, `view.reveal_in_tree`, …). `keys.doctor`
does not probe this family — its `Probe` set is
`{ ctrl_right, alt_right, cmd_right, end }` — so nothing tells the user;
`>` is what makes that survivable.

## Known tension to resolve in Phase 1

- `ctrl+h` / `ctrl+j` are on the vim side as NvChad window nav (rule 5 of the
  task) while rule 1 says the editor wants them raw in insert mode. Neovim
  resolves this by mode: the `<C-h>` window map is normal-mode only. The
  keymap has no mode axis yet; until it does, the editor handler runs first
  and consumes them in insert mode, so the global binding only fires from
  normal mode or a non-editor pane — which is the NvChad behaviour.
- Kitty-keyboard fallbacks (`Keys.standard_legacy`) are not modelled yet.
