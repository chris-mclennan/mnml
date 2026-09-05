# Keymap profiles — the vim / standard split (D4b)

mnml-zig binds every default chord to a profile. `both` chords fire in
either profile; `vim` chords only when `editor.input_style = .vim`;
`standard` only under `.standard`. `[keys.global]` still applies to both
and `[keys.vim]` / `[keys.standard]` overlay their profile.

This is the **spike-scope** split: Rust defaults into `both`, a small set of
mechanical rules, and the NvChad leader menus a vim user reaches for first.
The full NvChad `mappings.lua` derivation is Phase 1 (`TODO(D4b)` in
`src/commands/specs.zig`).

## Rules

1. **vim reserves** `ctrl+w g d u e y r n h j t f b` — each has an insert- or
   normal-mode meaning the editor must receive. Any default chord starting
   with one of these is `standard` only.
2. **`ctrl+k …` menus are the standard leader.** NvChad uses `ctrl+k` for
   window-up; the vim profile keeps `space` as its only which-key leader.
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
| `picker.files` | `ctrl+o` | both | standard | vim: `ctrl+o` is the jumplist (`nav.back`, with `ctrl+i` forward) — the chord chain runs before the vim handler, so a `both` binding would shadow it |
| `find.grep` | `space f w` | (new) | vim | NvChad <leader>fw |
| `picker.buffers` | `space f b` | both | both | NvChad <leader>fb (already the Rust default) |
| `view.toggle_tree` | `ctrl+n` | (new) | vim | NvChad <C-n> |
| `view.toggle_tree` | `space e` | (new) | vim | NvChad <leader>e |
| `buffer.close` | `space x` | (new) | vim | NvChad <leader>x |
| `term.shell_bottom` | `space h` | (new) | vim | NvChad <leader>h horizontal term |
| `term.shell_right` | `space v` | (new) | vim | NvChad <leader>v vertical term |
| `buffer.next` | `tab` | (new) | vim | NvChad <Tab> bufferline |
| `buffer.prev` | `shift+tab` | (new) | vim | NvChad <S-Tab> bufferline |
| `view.focus_left` | `ctrl+h` | (new) | vim | NvChad <C-h> |
| `view.focus_down` | `ctrl+j` | (new) | vim | NvChad <C-j> |
| `view.focus_up` | `ctrl+k` | (new) | vim | NvChad <C-k> |
| `view.focus_right` | `ctrl+l` | (new) | vim | NvChad <C-l> |
| `editor.toggle_line_comment` | `space /` | (new) | vim | NvChad <leader>/ |
| `lsp.format` | `space f m` | (new) | vim | NvChad <leader>fm |
| `view.cheatsheet` | `space c h` | (new) | vim | NvChad <leader>ch |
| `whichkey.leader` | `space w K` | (new) | vim | NvChad <leader>wK |
| `lsp.goto_definition` | `g d` | (new) | vim | Neovim gd |
| `lsp.goto_declaration` | `g D` | (new) | vim | Neovim gD |
| `lsp.references` | `g r` | (new) | vim | Neovim gr |
| `lsp.hover` | `K` | (new) | vim | Neovim K |
| `lsp.prev_diagnostic` | `[ d` | (new) | vim | Neovim [d |
| `lsp.next_diagnostic` | `] d` | (new) | vim | Neovim ]d |
| `file.cut` / `file.copy` / `file.paste` / `file.duplicate` | `ctrl+x` / `ctrl+c` / `ctrl+v` / `ctrl+d` | (new) | both, tree and Files pane focus only | handled by the tree / Files pane key handlers, not the keymap: neither edits text, so the editor's insert-mode meanings cannot want them there (Rust parity). Under vim the Files pane's `ctrl+d` / `ctrl+u` stay half-page scroll and the ctrl chords fall through — see the next row |
| `file.copy` / `file.cut` / `file.paste` | `y y` / `d d` / `P` | (new) | vim, tree and Files pane focus only | ranger's vocabulary: two keys so a stray press cannot move a file (the property `ctrl+v` lacks); a stray key between the two cancels. `D` duplicates in both profiles |

## Known tension to resolve in Phase 1

- `ctrl+h` / `ctrl+j` are on the vim side as NvChad window nav (rule 5 of the
  task) while rule 1 says the editor wants them raw in insert mode. Neovim
  resolves this by mode: the `<C-h>` window map is normal-mode only. The
  keymap has no mode axis yet; until it does, the editor handler runs first
  and consumes them in insert mode, so the global binding only fires from
  normal mode or a non-editor pane — which is the NvChad behaviour.
- Kitty-keyboard fallbacks (`Keys.standard_legacy`) are not modelled yet.
