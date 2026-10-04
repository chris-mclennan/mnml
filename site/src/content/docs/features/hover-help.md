---
title: Hover Help
description: The info panel at the foot of mnml's sidebar — what it says about the chip, row, button or menu row under the pointer, the chords it prints for your keymap profile, how to pin, resize or hide it, and how an integration supplies its own words.
---

mnml has a lot of small controls: chips on the statusline, chips on
every section header, buttons on the tab strips, rows in a dozen
right-click menus. A one-line tooltip cannot say much about any of them,
so mnml keeps a box for it instead. The **info panel** sits at the
bottom of the left column and describes whatever the pointer rests on:
what the control is in its current state, what a click and the keys do,
and where to go next.

It is curated, not generated. Each control has an entry written for it,
and a build step fails when a new control lands without one. The chords
in an entry come from the keymap when the entry is shown, so they are
always your profile's and always bound.

## Where it lives

The panel takes the bottom rows of the left column, under whatever
section is showing there: the file tree, SESSIONS, TODOS or the rest.
From the top down:

- **A rule.** It is the panel's top edge and also its resize handle;
  see [Its height](#its-height).
- **The title row**, on a lighter band. The topic is in bold. At the
  right end are the **pin** (`󰐃`, `P` under `--ascii`) and the **kebab**
  (`⋮`, `:` under `--ascii`). A long title is cut short rather than
  ellipsised. On a column too narrow for both, the pin goes and the
  kebab stays.
- **The entry**, wrapped to the column with a one-cell gutter, and a
  scrollbar in the last column when it is longer than the box.
- A blank last row, as a cushion above the statusline.

The panel shows only while the left column does. In full screen
(`view.fullscreen`) it goes with the rest of the chrome, and a column
too short to give the panel four rows and still leave the section above
it six has no panel.

Under SESSIONS, the panel steps aside while the cards would otherwise
have to scroll. Its rows go to the cards, and it comes back once they
fit. A pinned panel, or one that has the keys, stays.

## What an entry says

An entry has up to six parts. Every part except the title is optional:

| Part | Looks like | What it is |
| ---- | ---------- | ---------- |
| Title | **Refresh tree** | The topic, bold on the title row. |
| Body | Plain text | Two to four sentences about this control in its current state. |
| Aside | *Italic, muted* | One caveat, after the body. |
| Shortcuts | `[Ctrl+G] Go to line` | Chords that act on the thing, each a row: the chord in bold cyan, then what it does. |
| Links | `→ Run it` | Up to three rows, green and underlined, that do something when clicked. |
| `Key:` | `Key: Ctrl+K Ctrl+T` | The chord of the control's own click, last. |

Bodies describe state. A git chip's entry names the branch and its dirty
counts, a diagnostics chip's counts the errors, and a Settings row's
reads its current value and says whether it is written to the home
config or the workspace's.

### The links

A link row's glyph says what kind of thing it does:

| Glyph | `--ascii` | Does |
| ----- | --------- | ---- |
| `→` | `->` | Runs a command, the same one the palette would. |
| `⚙` | `*` | Opens Settings with the cursor on one row. |
| `↗` | `^` | Opens a web page in the OS browser. |
| `§` | `#` | Opens a section of the built-in configuration manual as a read-only markdown preview. |
| `✦` | `?` | *Ask Claude about this*: sends the Claude session a prompt about the control. |

An *Ask* link builds its prompt at the moment you click it. The prompt
holds the entry's own words, followed by the state of the thing you
pointed at: the diagnostics and their lines, the branch and its changed
files, the unread messages, a config key and its value, a command and
its binding. The answer is then about your situation and not about the
control in general. When Claude's route is off
(`ai.routing.claude.backend`), the row reads *Ask about this — AI is
off; turn it on* and opens that Settings row.

### Chords follow your profile

A shortcut row names a **command**, not a chord. When the entry is
shown, mnml looks the chord up in the active
[keymap profile](/docs/features/editor#two-keymap-profiles), with the
same rules the [menus](/docs/features/menus#every-row-prints-its-chord)
use. When you rebind a command, its entries change with it. A shortcut
whose command your profile leaves unbound is dropped from the entry,
never shown with a chord that does nothing.

So the same entry reads differently in the two profiles. With an editor
focused and the cursor on an identifier, the panel's summary ends with:

| Profile | Summary line |
| ------- | ------------ |
| standard | `[F12] Definition · [Shift+F12] References · [Ctrl+K Ctrl+I] Hover · [F2] Rename` |
| vim | `[gd] Definition · [gr] References · [K] Hover · [Space r a] Rename` |

A handful of keys belong to lists and overlays and are not commands
(`Enter`, `Esc`, `↑ / ↓`, `Wheel`, `Right-click`), so entries spell them
as written.

### The `Key:` line

When a control's left click runs one command, its entry ends with a
`Key:` line naming that command's chord in your profile. This covers a
chrome button, a statusline chip, a rail icon, a section or tree header
chip, a launcher dock entry, and a menu or palette row. The theme pill
is an example:

| Profile | Last line |
| ------- | --------- |
| standard | `Key: Ctrl+K Ctrl+T` |
| vim | `Key: Space t t` |

The line is left out:

- **when the click runs no command.** For example, a tab's close
  button, or a chip that drops a menu or starts a session.
- **when your profile binds the command to nothing.** The tree's
  new-file chip reads `Key: Ctrl+N` under standard and has no line
  under vim, which reaches the command through the tree's own `a`.
- **when one of the entry's `[chord]` rows already names it.** Under
  standard, the cursor-position chip's entry lists `[Ctrl+G] Go to
  line`, so it gets
  no `Key:` line, which would only repeat that row.

Only the left button counts, never the right-click menu. The click and
the `Key:` line read the same table (`src/app/primary_command.zig`), so
they always agree.

Under standard, a command reached only through the `Ctrl+K` leader
prints nothing at a menu row's right edge. When that row has no
curated entry, its fallback names the leader row instead: *This profile
reaches it only through the leader, `Space a e`…*, which you type as
`Ctrl+K a e`.

### *No help written yet*

A control without a curated entry still gets something: its tooltip
line or, for a menu row, the command's id, title and chord. A dim
italic *no help written yet* goes at the top, so you can see the gap
where it is. See [The audit](#the-audit) for how these gaps are caught
before release.

## What it shows, and when

The panel works down a list and shows the first thing that has
something to say:

1. **What the pointer rests on.** A chip, a button, a tab, a tree row,
   a menu row, a statusline chip, a link, a gutter mark.
2. **The keyboard's place in the tree.** Once you walk the tree's
   cursor past its first row, the panel shows that row's entry folded
   onto one line: the body, then its first two shortcuts. On the first
   row it stays on the column's own line.
3. **The active pane.** A summary of whatever has the keys.
4. **The focused surface.** A one-liner for where the keys are.

The pane summaries:

| Pane | Title | Body |
| ---- | ----- | ---- |
| Editor | `name · LANG · L:C · N lines`, with `· unsaved` while dirty, or with the identifier under the cursor first | Definition, References, Code actions, Files (or Hover and Rename on an identifier), as chords |
| Terminal | The pane's label, such as `ghostty (zsh)` | `Terminal pane — ` then the Restart, Rename and Close chords |
| Claude Code / Codex | The session's name, as its tab and SESSIONS card show it | `Session pane — ` then the same chords |
| One-shot AI answer | The pane's title | Its own keys: `r` re-ask, `c` cancel, `a` apply, `p` continue in Claude Code, `y` copy, `q` close |
| ZON tree | The focused field's path | That field's documentation from the configuration reference, or its type |

The one-liners, by surface:

| Surface | Title | Says |
| ------- | ----- | ---- |
| The tree | `Sidebar` | Arrows or `j`/`k` walk rows, Enter opens, `Ctrl+Shift+P` opens the palette. |
| A section | Its name: `Todos`, `Source control`, `Run and debug`… | How the section is walked. |
| A pane with nothing more to say | `Editor` | Hover a chip, tab or tree row for help. |
| The start screen | `Start` | `j`/`k`, Tab, Enter, and `?` for the cheatsheet. |

### Under menus and overlays

**An open menu.** Hovering a row shows that row's entry. Rows are
matched by the menu they are in as well as their label. That way,
*Rename…* on a terminal tab and *Rename…* on a tree row each get the
entry written for them. A row in a submenu is matched by its parent row
too.

**A picker, a prompt or a confirm box.** Pointing at one of its rows or
buttons shows that row's or button's entry. Otherwise, the panel
describes the surface the keys will go back to when the box closes.
With the tree walked to `main.rs`, its delete confirmation leaves
`main.rs — Rust source` in the panel.

### Integration panes

A [Jira or Bitbucket](/docs/integrations) pane draws every cell itself,
so only the pane knows whether the pointer is on an `assignee:` chip or
on a row. The pane reports the element under the pointer, and the panel
shows that title and body. Integration entries are words only. They
have no shortcut rows, links or `Key:` line, and the pane often spells
its keys in the body (*Key: r.*). A pane that has said nothing gets a
generic entry: what a mounted integration is, and that `?` in the pane
lists its keys.

A statusline chip an integration publishes gets an entry from the host.
The chip's tooltip supplies the title (its first line) and the start of
the body. The host then adds what a click runs, what the right-click
menu lists, and how fresh the figure is: as of the integration's last
poll, or of the publisher's last send.

## Reaching the links

The panel follows the pointer, so moving toward a link row means
crossing other things on the way: tree rows, the empty space under
them. Each of those would replace the entry before you got there.
Three things stop that.

**A grace window.** When the pointer leaves a target, the panel keeps
that target's entry for `ui.hover_help_grace_ms` (900 ms by default),
as long as the pointer keeps closing on the panel. "Closing" means two
things. The pointer must never move farther from the panel than its
last step. And it must stay inside the column (give or take two cells)
or inside the triangle from where it left toward the panel's near edge.
A step outside that switches the panel at once. So does the window
running out while the pointer rests on something else. Set the grace
to `0` to switch at once every time.

**Sticky on the box.** While the pointer is on the panel, the entry
stays, whatever it does there: a wheel notch and a click included. A
new topic always opens scrolled to the top.

**The pin.** Click the pin, or run `help.pin_toggle`, and the entry
stays put, words and links, wherever the pointer goes. A toast says
*info panel: pinned — Title*. The pin is lit yellow while it holds.
Click it again, run the command again, or press `Esc` in the panel to
let go. *Ask* on a pinned entry asks about the thing it was pinned
from.

## Driving it from the keyboard

`help.focus` gives the panel the keys. Its title lights the way a
focused section's header does, and a cursor sits on the first walkable
row: the shortcut rows first, then the links. While the panel has the
keys, its entry holds wherever the pointer goes.

| Key | Does |
| --- | ---- |
| `Tab` / `Shift+Tab` | Next / previous row, wrapping round. |
| `Enter` | Runs the row: a shortcut's command, or what a link does. On a gesture row (`Wheel`, `Drag`), it toasts that there is nothing to run. |
| `Esc` | Gives the keys back to where they came from, and lets a pin go. |

The cursor's row is kept on screen, scrolling the entry if it has to.
When the panel is not showing, `help.focus` toasts where to turn it on
and does nothing else.

The commands, and the chords each profile gives them:

| Command | What it does | vim | standard |
| ------- | ------------ | --- | -------- |
| `help.focus` | Gives the panel the keys | `Space K` | `Shift+F1` |
| `help.pin_toggle` | Pins or unpins the entry | `Space t p` | `Ctrl+K Shift+H` |
| `view.toggle_hover_help` | Shows or hides the panel | — | — |
| `view.toggle_hover_tooltip` | Shows or hides the small tooltip by the pointer | — | — |

The two toggles have no chord. They are in the palette, and *Toggle
hover-help* is also on the *View* menu.

## The mouse on the panel

| Gesture | Where | Does |
| ------- | ----- | ---- |
| Wheel | Anywhere on it | Scrolls a long entry a row per notch. |
| Click | A link row | Does what the row names. |
| Click | The pin | Pins or unpins. |
| Click or right-click | The kebab | Opens the panel's menu. |
| Drag | The top rule | Resizes the panel. |
| Double-click | The top rule | Puts the height back to the default. |

A click anywhere else on the panel is used up there: it never reaches
the tree underneath.

## Its height

The panel is `ui.hover_help_height` rows tall, 8 by default. Drag its
top rule to change that. The rule lights in the accent while the
pointer is on it or you are dragging it, as the column's divider does.
When you let go, the new height is written to the home config, the same
as the Settings row would write it. Double-click the rule to go back
to 8.

The height is clamped twice. The panel keeps between 4 and 60 rows, and
the section above it always keeps 6. On a short window the panel
shrinks first, and below ten rows of column there is no panel. An
entry that does not fit scrolls. It is never cut, so a link under a
long body is a wheel notch or two away.

## Turning it off

There are three ways, and they last for different lengths of time:

- **Settings → UI → Hover help** writes `ui.hover_help` to the home
  config, so it sticks across restarts.
- **The kebab's menu** has one row: *Turn off info panel (Settings → UI
  to bring back)*. The kebab goes with the panel, so you turn it back
  on from Settings or the palette.
- **`view.toggle_hover_help`** (the palette, or *View → Toggle
  hover-help*) flips it for this session only. The next launch reads
  the config again.

Turning the panel off gives its rows to the section above it. The small
tooltip beside the pointer is a separate switch, `ui.hover_tooltip`,
which is off by default.

## Settings

Four rows in Settings' UI section govern the panel, all written to the
home config:

| Row | Key | Default | Values |
| --- | --- | ------- | ------ |
| Hover help | `ui.hover_help` | `true` | on / off |
| Hover help rows | `ui.hover_help_height` | `8` | 4 to 60 |
| Hover help grace (ms) | `ui.hover_help_grace_ms` | `900` | 0 to 5000; 0 switches at once |
| Hover tooltips | `ui.hover_tooltip` | `false` | on / off |

The same keys in `config.zon`:

```zig
.{
    .ui = .{
        .hover_help = true,
        .hover_help_height = 12, // clamped to 4..60
        .hover_help_grace_ms = 600, // 0 switches at once; clamped to 5000
        .hover_tooltip = false,
    },
}
```

The [option reference](/docs/config/reference) has every key.

## For integration authors

### A mounted pane names what is under the pointer

The host sends your pane a `hover` input every time the pointer moves
over it. Look up the cell in your own hit map and send back a title and
body with `Mount.hover`. Both first-party integrations do it like this:

```zig
.hover => |h| if (h.dragging) try app.drag(h.col, h.row) else {
    try app.hover(h.col, h.row);
    // The host's info view, told what is under the pointer
    // (sent only when it changed).
    var hb: [1024]u8 = undefined;
    const help = app.helpAt(h.col, h.row, &hb);
    mount.hover(help.title, help.body) catch {};
},
```

`mount.hover` sends nothing to a host that does not show the panel
(`hello.capabilities.hover_help`), and nothing when the text has not
changed since the last call. You can call it on every move at no cost.
A title of `""` clears the entry. On the wire, it is one line:

```json
{"hover":{"title":"assignee:","body":"Whose tickets show. Click opens a picker of the people on the tab."}}
```

Use the SDK's words for the toolkit's own controls. `sdk.pane.help.common`
has one entry each for the refresh and `?` chips, a tab, the filter
pill, a tree or list row, a chevron, a build line, the pull-request
row's Open / Review / Merge, the detail panel, the scrollbar, a picker
row and the key sheet. `sdk.pane.help.key` spells a hint-row entry
(`r — Refresh`). With these, the same element reads the same in every
pane. Write your own words only for what is yours: a Jira chip, a
pipelines page.

### A statusline chip says what it counts

For a chip your integration publishes, the `tooltip` you send is the
start of its entry. The first line becomes the title, and the rest
opens the body. Without one, the entry can only name the chip by its id.
Add `items` so the chip's hover lists what the figure is made of. The
[SDK reference](/docs/integrations/sdk) has the fields and the rules.

### Entries in mnml itself

Contributing a control to mnml means contributing its entry. Entries
are data in `src/app/info_view_copy/`, one module per area (statusline,
rail, chrome, dock, settings, menus, overlays, panels, editor, git
graph, tree). This is the pin's:

```zig
.pin => .{
    .title = "Pin the entry",
    .body = "Click pins what the box shows now: the entry stays — its words and its links — wherever the pointer goes, until the pin is clicked again or Esc is pressed in the box. Lit yellow while pinned. Without it the box follows the pointer, and holds an entry only while the pointer travels to the box.",
    .keys = &.{.{ .command = .@"help.pin_toggle", .label = "Pin / unpin" }},
    .links = &.{ .{ .command = .{ .id = .@"help.pin_toggle", .label = "Pin / unpin" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.hover_help_grace_ms"), .label = "The travel grace" } } },
},
```

- **`keys` name commands.** The chord is looked up when the entry is
  shown. Only a short, fixed list of literal keys (`Enter`, `Esc`,
  `Wheel`…) may be spelled out instead.
- **`links` are checked.** A command link takes a command id, and a
  Settings link takes a config path through `settingsRow`. A wrong one
  of either fails to compile. A `docsSection` link names a heading of
  the configuration manual, and the lint fails a heading that does not
  exist.
- **Don't write the `Key:` line.** It comes from
  `src/app/primary_command.zig`. A new control whose click runs a
  command goes in that table, and its entry gets the line
  automatically.

### The audit

`zig build hover-audit`, or `mnml hover-audit --strict`, starts a
headless mnml and walks every target it can produce:

- every statusline segment, rail row, chrome button and tab
- every launcher dock kind, dock widget part and Settings row
- every confirm button and picker row
- every row of every right-click menu, opened for real, submenus
  included
- every section's chips, rows, kebabs and filters
- the tree's rows and chips, the editor's cells, and each pane kind

Each target counts as curated, fallback or none. A recent run counted
more than 1,400 targets. It also lints each entry it reaches. A
shortcut whose command neither profile binds, a literal chord outside
the allowed list, or a body under forty characters each fail it.

The audit fails on an uncovered target unless
`docs/hover-help-todo.txt` lists it. That file is the backlog of known
gaps, one key per line. A new control cannot land without help, and a
listed target that has gained an entry is reported stale, so the file
cannot go out of date. `mnml hover-audit --write-todo
docs/hover-help-todo.txt` regenerates it.

The audit covers the host's own controls. Inside a mounted pane, the
pane is what names the element under the pointer, so an integration's
words are the integration's to keep.

## Next

- [Menus, Tabs and Fields](/docs/features/menus): the chords at a menu
  row's right edge, which use the same rules as the panel's.
- [Editor](/docs/features/editor): the sidebar the panel sits in, and
  the two keymap profiles.
- [Keymap profiles](/docs/config/keymaps): every chord that differs
  between vim and standard.
- [SDK](/docs/integrations/sdk): `Mount.hover`, `sdk.pane.help` and
  statusline segments for integration authors.
- [Command reference](/docs/reference/commands): every command a link
  row or a shortcut can run.
