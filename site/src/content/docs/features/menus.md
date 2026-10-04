---
title: Menus, Tabs and Fields
description: How mnml's menus print each row's chord for your keymap profile, how a tab strip pages and reaches every tab, and how the picker, the scrollbars and every text field take the mouse and the keyboard.
---

Around the editor sits a frame of small controls: the menu bar and the
right-click menus, the tab strip over each split, the picker that
`ctrl+p` and the palette open, and the one-line fields — a filter, the
find bar, the `:` line. Each of them is one component used everywhere,
so a menu behaves the same whether it dropped from the menu bar or
opened on a chip, and every text field takes a click, a paste and a
selection the same way.

Most of what follows works the same in both
[keymap profiles](/docs/features/editor#two-keymap-profiles). Where a
profile changes something — mostly which chord a menu row prints — the
page says so.

## Menus

### Where menus come from

- **The menu bar** across the top row: the `mnml` brand menu, then
  *File*, *Edit*, *Selection*, *View*, *Go*, *Run*, *Terminal*,
  *Window* and *Help*. Words that do not fit before the centred
  workspace chip fold behind a ` » ` chip, whose menu lists them.
- **Right-click menus** on nearly everything: the editor's text, a
  file in the tree, a tab, a chip on the statusline, a SESSIONS card,
  a link, the sidebar's divider.
- **Chip and dock menus**: the `+` menu, the launcher dock's strip, the
  AI chips.

`ui.menu_bar` decides whether the bar's words show: `always` (the
default), `hidden`, or `auto`, which paints them while a menu is open
or the pointer is on the row.

### Opening a menu from the keyboard

| Key | What it opens |
| --- | ------------- |
| `F10` | The *File* menu. Not while a debug session is running, where `F10` steps over. |
| `Alt` + a menu's first letter | That menu: `Alt+F` *File*, `Alt+E` *Edit*, `Alt+H` *Help*, `Alt+M` the brand menu, and so on. |
| `Alt+F10` (standard) | The *File* menu, as `view.menu_bar_open`. |
| `Shift+F10` | The right-click menu of whatever has the keys (`view.context_menu_at_focus`), in both profiles — a focused SESSIONS card's, for example. |

While a menu-bar menu is open, the first letter of every other word is
underlined: that is the letter `Alt` reaches it with. The bar does not
take these keys while another overlay is open, while the bar is
`hidden`, or while a terminal pane has the keys — the program in the
pane gets them.

Under the vim profile a chord your keymap binds wins over the letter —
`Alt+H` is NvChad's scratch terminal and `Alt+R` toggles regex search, so
*Help* and *Run* open from the bar or `F10` instead; an `Alt` letter vim
leaves unbound still opens its menu. Under standard the letters stay the
menus', as in VS Code.

Inside an open menu:

| Key | Does |
| --- | ---- |
| `↑` `↓`, `k` `j` | Move between rows. |
| `Home` / `End` | First / last row. |
| `Enter` | Runs the row, or opens its submenu. |
| `→`, `l` | Opens the row's submenu. In a menu-bar menu, on a row without one, steps to the next menu. |
| `←`, `h` | Steps back out of a submenu. In a menu-bar menu, steps to the previous menu. |
| `Esc`, `q` | Closes the menu. |

The wheel scrolls a menu taller than the screen; the last cell of its
bottom border shows `↑`, `↓` or `↕` when there are rows out of sight.

### Every row prints its chord

A row that runs a command prints that command's chord at its right
edge, in muted grey — the chord **for the profile you are in**. The
menus are how you learn the keys, the same way the
[command palette](/docs/getting-started#finding-things) is.

A row with no binding prints nothing there. A row whose label and chord
do not both fit drops the chord: the label is never cut to make room.
The highlighted row prints its chord in the highlight's own colour so
it reads on the accent.

The two profiles print different keys for the same row, because they
are different keymaps, not one map with patches:

| Row | vim | standard |
| --- | --- | -------- |
| Cut | `d` | `Ctrl+X` |
| Copy | `y` | `Ctrl+C` |
| Paste | `p` | `Ctrl+V` |
| Undo | `u` | `Ctrl+Z` |
| Redo | `Ctrl+R` | `Ctrl+Shift+Z` |
| Select all | `ggVG` | `Ctrl+A` |
| Toggle fold | `za` | `Ctrl+Shift+[` |
| Save | `Ctrl+S` | `Ctrl+S` |

**Under vim**, a row prints Neovim's own key whenever vim has one —
never a VS Code chord in its place. Save stays `Ctrl+S`, which NvChad
binds too. A command reached through the leader prints its leader
chord, such as `Space f b`.

**Under standard**, a row prints the editor's own keys — the `Ctrl`
chords the standard editor answers itself, as in the table — and
**never a leader chord**. A command whose only standard chord goes
through the `Ctrl+K` leader prints nothing at the right edge. Hover the
row instead: the hover help names the leader row that reaches it
(`Space a e` for *Explain*, typed as `Ctrl+K a e` in the standard
profile, where `Ctrl+K` opens the same which-key menu).

Inside the [sessions mode](/docs/features/ai), the rows print the
chords that mode gives its own verbs — `Ctrl+N` starts a session in
the focused column there — and not what those keys mean elsewhere.

### Ticks

A row that switches something on or off, or picks one of a few
choices, wears a `✓` before its label while it is the current state
(`*` under `--ascii`). A menu with a row that can be ticked keeps two
cells for the tick on every row, so the labels line up whether a row
is ticked or not.

Some of the rows that tick:

| Menu | Row |
| ---- | --- |
| *Window* | *Auto-equalize splits* |
| The sidebar's divider | *Auto-hide sidebar* — ticked, a click puts the sidebar back to always shown |
| The tree's workspace header | *Show git-ignored files*, *Show workspace dots* |
| A revealed auto-hide sidebar | *Always (docked)*, *Auto-hide (reveal on the edge)*, *Hidden (keyboard only)* — the current mode ticked — and the pin |
| The theme menu | *Auto: match system (light / dark)* |

A click on a ticked on/off row turns the thing off again.

### Menus on links

A right-click on a link — a URL, a ticket key, or a pull-request
reference, in a terminal pane, on a SESSIONS card or in the sessions
table — opens a menu with *Copy link* and *Open link*. The menu opens
on the row under the link, left-aligned to it, so it never covers the
link it is for; above the link when the rows below cannot hold it; at
the pointer when neither side can. While the menu is open the link
stays lit in the accent with a solid underline, so you can see which
link the two rows act on.

*Copy link*, *Copy path* and every other copy outside the editor reach
the system clipboard, so the text pastes into another app.

## Tab strips

Every split has a tab strip across its top.

| Gesture | Does |
| ------- | ---- |
| Click | Shows the tab. |
| Drag | Moves the tab along the strip. |
| Double-click | Zooms the tab's pane to fill the page (`view.toggle_zoom`). Double-click again to put the splits back. A double-click also keeps a preview tab open, as in VS Code. |
| Middle-click | Closes the tab. |
| Right-click | The tab's menu. |
| Wheel | Slides the strip a tab at a time, when its tabs overflow. |

### The pager

When a strip has more tabs than fit, a pager appears at its right end:
` ‹ 2/5 › ` — the page of tabs on show, out of how many. The arrows
turn a page, wrapping round at either end. When every tab fits, nothing is painted; on a strip short
of room the number goes first, then the arrows.

A page holds whole tabs only. The tab that would be cut at the strip's
edge is not painted there; it starts the next page, which is what the
page count already said. Opening a tab that sits just past the last
whole one brings it into view whole, with its name and its close
button.

### ` ⋯ `: every tab by name

Beside the pager, ` ⋯ ` (`...` under `--ascii`) opens the **buffer
picker**: every tab by name, on the page or not, one click away. It is
the pager's companion — it shows only while the strip pages, and it is
the first thing to go on a strip short of room, before the pager's
number. The buffer picker is also `picker.buffers`:

| vim | standard |
| --- | -------- |
| `Space f b` | `Ctrl+K Ctrl+P` |

Earlier versions printed a ` +N hidden ` count here. It is gone: with
every page and every tab a click away, nothing is hidden.

### Session strips

The strip of a Claude Code or Codex session pane wears the same
` ‹ n/m › ` control with a different meaning: the session's place among
the sessions it steps through. It has no ` ⋯ `; the
[sessions rail](/docs/features/ai) lists the rest. A strip with one
session shows no ` ‹ 1/1 › `.

## The picker

The picker is the box behind `ctrl+p`, the command palette, the buffer
list and most lists you choose from. The query is on its first row,
with the count flush right (` 12 `, or ` 12 of 340 ` while a query
filters); the ranked rows follow, the selected one marked with `▌`, the
matched characters in the accent, and a muted detail — a chord, a
directory — at the right.

| Key | Does |
| --- | ---- |
| `↑` `↓`, `Ctrl+P` `Ctrl+N`, `Ctrl+K` `Ctrl+J` | Move. |
| `PageUp` `PageDown`, `Ctrl+U` `Ctrl+D` | Page the list — or scroll the preview, in a picker that has one. |
| `Enter` | Accepts the selected row. |
| `Esc` | Closes the picker. |
| `Tab` | Marks a row, in a picker that takes several. |

`ui.picker_position` puts the box in the centre (the default) or at
the top of the screen.

### Its scrollbar

A list longer than the box gets a scrollbar in its rightmost column.
Press or drag on the bar to move through the list — the selection
follows the pointer's place on the track — and the wheel over the bar
scrolls as it does over the rows.

### On a narrow screen

The box is the screen's width less eight cells, at least 30 and at most
90 (120 with a preview column). It never grows past the screen: below
30 columns it takes what there is. Its height follows the list, up to
22 rows and never more than four fifths of the screen. As the box
narrows:

- the detail gives way before the label, which keeps at least twelve
  cells, and is cut with `…`;
- the count beside the query goes when the row cannot hold it and a
  usable field;
- a preview column is dropped when the two halves could not both be
  read, and the rows get the whole width;
- the scrollbar is left off a list four cells wide or less.

## Scrollbars

Lists, panes and overlays share one scrollbar: a one-cell strip with a
brighter thumb, where a click on the track pages and a drag on the
thumb carries the view. Besides the lists that always had one, these
show it:

- **The picker**, as above.
- **A terminal's scrollback.** See
  [Terminal](/docs/features/terminal#scrollback-and-search).
- **The HTTP pane.** The Response box's Body, Headers and Timeline tabs
  and the request's Body editor, when their rows overflow, on a column
  of their own beside the text. A press on the Response bar's track
  jumps there. See [HTTP](/docs/features/http).

## Text fields

Every one-line input in mnml is the same field:

- the query of the picker and the palette, and a prompt's line;
- the filter at the top of every sidebar list — SESSIONS, TODOS, NOTES,
  SEARCH and the rest — and of the Files, ZON, browser, grep and
  sessions-table panes;
- the find bar's *Find* and *Replace* fields;
- the `:` line and the settings filter;
- the HTTP pane's URL and its *Params* / *Headers* name and value
  cells, a WebSocket's message line, and the debug console;
- a ZON field being edited.

### The mouse

| Gesture | Does |
| ------- | ---- |
| Click | Puts the caret there. On a find field, it also gives the field the keys. |
| Double-click | Selects the word under the pointer. |
| Triple-click | Selects the whole line. |
| Shift+click | Grows the selection from the caret to the pointer. |

A click inside a ZON field being edited keeps editing, rather than
closing the field.

### The keyboard

| Key | Does |
| --- | ---- |
| `←` `→` | Move a character. |
| `Ctrl` or `Alt` with `←` `→` | Move a word. |
| `Home` / `End` | Start / end of the field. |
| `Shift` with `←` `→` `Home` `End` | Grows a selection. |
| `Backspace` / `Delete` | Delete a character — or the selection. |
| `Ctrl` or `Alt` with `Backspace` / `Delete` | Delete a word. |

The fields also answer the readline keys — `Ctrl+A` / `Ctrl+E` for the
start and end, `Ctrl+U` / `Ctrl+K` to delete to either end, `Ctrl+W`
for the word before the caret, `Alt+B` / `Alt+F` to move a word — where
the box they sit in does not use the key itself. The picker, for one,
moves its selection with `Ctrl+K` and `Ctrl+U`.

Typing or pasting over a selection replaces it; `Backspace` deletes it.

### Paste

A paste goes into the field you are typing in. A pasted line break
becomes a space, since a field holds one line. This includes a sidebar
list's filter, a pane's filter, the `:` line and the debug console,
which used to pass a paste through to the editor underneath.

A field that opens with a value already in it — a prompt seeded with a
name, the find bar's query after a second `Ctrl+F` — starts with the
whole value selected, so typing replaces it.

## Next

- [Editor](/docs/features/editor) — the frame these controls sit in,
  and the two keymap profiles.
- [Terminal](/docs/features/terminal) — selection, copy and paste, and
  links in a terminal pane.
- [AI sessions](/docs/features/ai) — the sessions rail, the sessions
  mode and the session strip's control.
- [Keymap profiles](/docs/config/keymaps) — every chord that differs
  between vim and standard.
- [Command reference](/docs/reference/commands) — every command a menu
  row can run.
