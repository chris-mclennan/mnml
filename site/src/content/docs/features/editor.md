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
a menu bar and right-click menus whose rows print their chords for
your profile, and a mouse that works everywhere — click, drag, resize,
scroll. [Menus, Tabs and Fields](/docs/features/menus) covers the
menus, the tab strips, the picker and the text fields.

Splits nest in any direction, and tab pages hold a layout each.
`layout.save` (`space W s`) keeps the current tab page as a named
layout for later; `view.toggle_zoom` gives one split the whole screen
for a moment; `view.fullscreen` (`space t f`) hides the chrome.

<!-- video: splits -->

### Even splits

`view.equalize_splits` (`ctrl+w =` in the vim profile) shares the
current tab page's space equally between its splits, once. To have mnml
do that every time a split opens or closes, turn on **Auto-equalize
splits**:

- the Window menu's *Auto-equalize splits* row, ticked while it is on;
- Settings → **UI** → *Auto-equalize splits*;
- `view.toggle_auto_equalize_splits` from the palette.

With it on, closing one of three splits leaves two even halves instead
of one pane twice the size of the other, and turning it on evens the
splits out at once. It is off by default, and is written to the
workspace's `config.zon` as `ui.auto_equalize_splits`.

Integrations are a separate case: a split an integration opens evens
out after itself whatever this switch says, unless you set
`integrations.equalize_on_open = false`.

### The file tree

Below the top level, every row in the tree carries neo-tree's
connectors, folders and files alike: a `│` down each level that still
has entries to come, and at the row's own level a `│` while a sibling
follows or a `└` on the last child. They are drawn in the theme's
comment grey, so they guide the eye without competing with the names.
A row nested too deep for the column folds its outer levels into `…`
and keeps its name.

With more than one workspace in the tree (`view.add_workspace`), each
gets a header row, and a **workspace dot** after the header's chevron
marks which one is active: `●` on the active workspace, `○` on every
other. Click a `○` to switch to that workspace — it opens, the others
fold, and the tree takes the keys. A click anywhere else on the header
still folds or unfolds it. The same switch is *Switch to this
workspace* on an extra workspace's right-click menu, and
`view.switch_workspace` picks one from a list (`ctrl+k ctrl+o` in the
standard profile). Removing the active workspace hands the dot back to
the workspace mnml was opened on.

The dots are on by default. *Show workspace dots* on the header's
right-click menu, the *Workspace dots* row in the settings overlay, or
`ui.show_workspace_dots = false` turns them off.

### The sidebar's width and side

The sidebar is a share of the window, not a fixed number of cells: a
fifth of the width, never narrower than 30 cells or wider than 48. That
is 30 cells up to a 150-column window, 40 at 200 columns, and 48 from
240 columns on. It follows the window as you resize it.

To fix the width instead, give `ui.tree_width` a number of cells (10 to
80), in `config.zon` or the *Tree width* row of the settings overlay
(one step below 10 reads `auto`, which is `0` in the file):

```zig
.{ .ui = .{ .tree_width = 36 } }   // 0, the default, is the share
```

Dragging the divider between the sidebar and the editor also sets the
width, and that width wins over the config: it stays put through
resizes and is saved with the session, so it is still there next time
you open the workspace. Changing the *Tree width* row in the settings
overlay drops a dragged width and applies the row's value. When mnml
reads its configuration again while running — after you trust a
workspace, for example — a dragged width survives, unless
`ui.tree_width` itself changed; then the file's value takes over.

Right-click the divider for its menu:

| Row | What it does |
| --- | ------------ |
| *Reset width* | Drops a dragged or typed width and goes back to the config's: the share, or the number `ui.tree_width` names. |
| *Set width…* | Asks for a width: a number of cells, or a share of the window such as `25%`. It must come to 10–80 cells. Like a drag, it lasts until *Reset width* and is saved with the session. |
| *Hide sidebar* | Hides the column, as `ctrl+n` (vim) or `ctrl+b` (standard) does. |
| *Auto-hide sidebar* | Keeps the sidebar out of sight until the pointer reaches the screen edge, then shows it over the editor without resizing anything (`ui.sidebar = .auto`). The row is ticked while it is on; `view.sidebar_mode_always` docks it again. |
| *Move sidebar to the right* | Moves the sidebar to the other side of the editor (`ui.sidebar_side`). Read *Move sidebar to the left* once it is there. |

Moving the sidebar moves every section that follows the default side —
the file tree, git, sessions and the rest — and it moves the outline,
which always takes the side opposite the sidebar. A section you moved
by hand, or one `ui.section_side` places, stays where it is, and the
problems list stays in the bottom dock. *Auto-hide* and *Move sidebar*
are written to your home `config.zon`; *Set width…* and a drag are not.

### The launcher dock

The launcher dock is a strip of things you start — the `+` menu, your
integrations, a terminal item, and any command you pin — centred along
one edge of the editor. On the bottom edge it can sit in one of three
places:

| Placement | Where the strip goes |
| --------- | -------------------- |
| *above statusline* (`.inner`, the default) | The editor area's last row, above the statusline. |
| *below command line* (`.outer`) | The screen's last row, under the `:` line. Everything else moves up a row. |
| *on command line* (`.shared`) | The `:` line's own row. It takes no row of its own. |

Choose with the *Launcher dock placement* row in the settings overlay,
the *Place:* rows on the strip's right-click menu, or `:dock inner`,
`:dock outer` and `:dock shared` (`ctrl+;` opens the `:` line in the
standard profile). In `config.zon` it is `ui.dock.placement`:

```zig
.{ .ui = .{ .dock = .{ .placement = .shared } } }
```

On the command line's row the dock is always up: there is no grip to
find it by and no extra row to reveal, so an auto-hide setting reads as
always shown there (`hidden` still hides it). The items sit where
`ui.dock.align` puts them and do not move while you type. Only when a
long command would reach them does the strip step aside — it is not
drawn while the command is that long, and it comes back as soon as the
line closes or gets shorter. With the items aligned to the start of
the row they step aside as soon as a line opens, so keep the default
centred alignment, or `end`, to see them while you type.

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
