---
title: Editor
description: A modal Neovim-style editor or a modeless VS Code-style one — two complete keymaps over the same editor — with tree-sitter, LSP and a debugger built in.
---

## Two keymap profiles

mnml has two complete keymaps, and you pick one:

- **vim** — modes, motions, operators, text objects, registers, the `:`
  line, and NvChad's `space` leader menus. If your fingers know Neovim
  and NvChad, they know this.
- **standard** — modeless editing with VS Code's chords: `ctrl+p` to open
  a file, `ctrl+shift+p` for the palette, `ctrl+d` for the next
  occurrence.

**standard** is the default. Choose in the first-launch wizard, with
`--input vim` for one launch, or in `config.zon`:

```zig
.{ .editor = .{ .input_style = .vim } }
```

Neither profile is the other with patches on top. Each one has its own
complete set of chords, and the rest of mnml — the editor, the panes,
the renderer — does not know which one is active. The
[keymap profiles](/docs/config/keymaps) page lists every chord that
differs.

A few of the everyday ones:

| Action | vim | standard |
| ------ | --- | -------- |
| Command palette | `ctrl+shift+p`, `space p` | `ctrl+shift+p` |
| Find a file | `ctrl+p`, `space f f` | `ctrl+p` |
| Search in files | `space f w`, `space f g` | `ctrl+shift+f` |
| Save | `:w`, `ctrl+s` | `ctrl+s` |
| Toggle the file tree | `ctrl+n` | `ctrl+b` |
| Close the buffer | `space x` | `ctrl+w` |
| Next / previous buffer | `tab` / `shift+tab` | `ctrl+pagedown` / `ctrl+pageup` |
| Split right / down | `ctrl+w v` / `ctrl+w s` | `ctrl+\` / `ctrl+shift+\` |
| Go to definition | `gd` | `f12` |
| Comment the line | `gcc`, `space /` | `ctrl+/` |
| Undo / redo | `u` / `ctrl+r` | `ctrl+z` / `ctrl+y` |

In the vim profile, pressing `space` and waiting opens **which-key**, a
menu of everything under the leader. In the standard profile `ctrl+k`
opens the same menu, so every leader chord is reachable from both.

## The frame

mnml draws NvChad's chrome: a file tree on the left, a buffer line
across the top, a powerline statusline along the bottom, and file-type
icons from a [Nerd Font](https://www.nerdfonts.com/). It ships NvChad's
94 base46 colour themes; `theme.pick` (`space t t`) previews each as you
move through the list. The default is `onedark`.

Around that frame are the parts you would expect from VS Code: a
command palette that finds every command by name and shows its chord,
right-click menus, and a mouse that works everywhere — click, drag,
resize, scroll.

Splits nest in any direction, and tab pages hold a layout each.
`layout.save` (`space W s`) keeps the current tab page as a named
layout for later; `view.toggle_zoom` gives one split the whole screen
for a moment; `view.fullscreen` (`space t f`) hides the chrome.

## Editing

- **Multiple cursors.** Every cursor types, deletes, selects and pastes.
  `ctrl+d` (standard) adds the next occurrence, `ctrl+shift+l` selects
  them all, and `ctrl+alt+up` / `down` add a cursor above or below.
- **Vim's toolkit**, in the vim profile: counts, dot-repeat, registers,
  marks (capital marks persist across sessions), macros, visual block,
  text objects, surround (`ys`, `ds`, `cs`), `gq` reflow, and `ctrl+a` /
  `ctrl+x` on numbers.
- **Snippets** with tab stops that follow the text as you type.
- **Folds**, and **sticky context**: the header of the function or block
  you are in stays pinned above the text.
- **Harpoon**: pin the files you keep coming back to (`space H a`) and
  jump between them (`space H m`).

Undo is grouped the way you would expect: typing over a selection is
one undo step.

## Syntax highlighting

Highlighting is tree-sitter, with 41 grammars compiled into the binary —
nothing to download. It updates incrementally as you type, and it
understands embedded languages: code fenced in Markdown, `<script>` and
`<style>` in HTML.

## Language servers

mnml speaks the Language Server Protocol to whatever servers you have
installed: diagnostics, completion, hover, signature help, go to
definition and references, rename, formatting, code actions, document
symbols, and semantic highlighting.

| Action | vim | standard |
| ------ | --- | -------- |
| Go to definition | `gd` | `f12` |
| References | `gr` | `shift+f12` |
| Hover | `K` | `ctrl+k ctrl+i` |
| Rename | `space r a` | `f2` |
| Code action | `space c a` | `ctrl+.` |
| Format | `space f m` | `ctrl+shift+i` |
| Symbols in this file | `space l s` | `ctrl+shift+o` |

An external formatter (Prettier, rustfmt, Ruff and others) runs instead
of the server when the project is configured for one.

## Debugging

mnml is a Debug Adapter Protocol client: breakpoints, stepping, the call
stack, watches, and a REPL pane. `f9` toggles a breakpoint and `f5`
starts or continues, in both profiles.

## Markdown and images

`markdown.preview` (`space m`) renders a Markdown file in a pane beside
it. Images — PNG, JPEG and GIF — display in terminals that support the
Kitty, iTerm2 or sixel image protocols.

## Files on disk

Open files are checked every two seconds. A file that changed on disk
reloads if you have not edited it; if you have, mnml warns you instead of
overwriting either side.
