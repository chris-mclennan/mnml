---
title: Terminal
description: mnml's terminal panes run on libghostty, the terminal-emulation core of Ghostty, so programs inside a pane behave the way they do in a modern terminal.
---

A terminal pane is a shell, or any command, running in a split beside
your code. Test runners, build tasks, tools like `htop`, and AI coding
sessions all use the same kind of pane.

## Built on libghostty

mnml does not have its own terminal emulator. The part of a terminal
that reads a program's output and keeps the screen — parsing escape
sequences, the grid of cells, scrollback, modes, selection, hyperlinks,
prompt marks — is **libghostty**: the core of
[Ghostty](https://ghostty.org), which Ghostty's authors describe as a
cross-platform library that "provides the core terminal emulation".
mnml uses its `ghostty-vt` Zig module directly, pinned to a Ghostty
commit in `build.zig.zon`, and paints each pane from that grid in its
own chrome.

The reason is fidelity. A terminal emulator that handles everything
real programs send is a project in itself; libghostty is that project,
and a program in an mnml pane gets the same emulation it would get in
Ghostty. Because mnml is also written in Zig, it uses the module as a
plain Zig dependency, with no C layer in between. (mnml uses only the
emulation; the drawing is mnml's own, inside whatever terminal you run
it in.)

## What that gives a program in a pane

<!-- video: terminal -->

Everything below is handled by the pane today:

- **Colour.** Palette and 24-bit RGB colours, underline styles and
  underline colours. The child sees `COLORTERM=truecolor`, and
  `TERM=xterm-ghostty` when Ghostty's terminfo is installed
  (`xterm-256color` otherwise).
- **The mouse.** Programs that ask for mouse reporting get it, in the
  normal and SGR encodings. Hold `Shift` to select text yourself instead.
- **The Kitty keyboard protocol**, for programs that turn it on. A
  program that turns on both it and application cursor keys gets the
  arrows, `Home` and `End` as `CSI` sequences, as Ghostty sends them.
- **Bracketed paste**, with the pasted text cleaned so it cannot close
  the bracket early.
- **Hyperlinks** (OSC 8), window titles (OSC 0/2), and the clipboard:
  a program can **write** to your clipboard (OSC 52, and Kitty's
  clipboard protocol) but never read it. Turn writes off with
  `terminal.osc52 = false`.
- **Grapheme clustering**, so multi-codepoint characters take the right
  number of cells.
- **Device attribute queries** are answered, which some shells wait for
  at start-up.

## Shell integration

In a plain shell pane, mnml loads a small integration for **zsh**,
**bash** and **fish** without touching your dotfiles. It marks each
prompt (OSC 133) and reports the working directory (OSC 7). With the
marks in place, `term.prev_prompt` and `term.next_prompt` jump between
commands, and a resize redraws the prompt cleanly. Turn it off with
`terminal.shell_integration = false`. It applies on macOS and Linux.

## Opening a terminal

| Command | vim | standard |
| ------- | --- | -------- |
| `term.shell` — a new shell beside the current pane | ``ctrl+shift+` ``, `space a t` | ``ctrl+shift+` `` |
| `term.shell_right` — a shell in the right half | `space v` | — |
| `term.shell_bottom` — a shell in the bottom half | `space h` | — |
| `term.scratch_toggle` — a scratch terminal strip at the bottom | ``ctrl+` ``, `alt+h` | ``ctrl+` `` |

In the standard profile, the `space …` chords are reached through
`ctrl+k`, which opens the same which-key menu.

The `:term` command runs anything:

```text
:term
:term htop
:term cargo watch -x test
```

With no argument it opens your login shell; with one, it runs the line
through the shell (`sh -c`, or `cmd /d /c` on Windows) in a pane named
after the command. In the vim profile it opens as a new tab; in the
standard profile, in a split below.

## Scrollback and search

Scrollback keeps `terminal.scrollback_lines` lines (10,000 by default).
`Shift+PageUp` / `PageDown` / `Home` / `End` move through it, and the
mouse wheel scrolls it when the program has not asked for the wheel.

The scrollback has a scrollbar over the pane's rightmost column. It
shows while you are scrolled back from the bottom, or while the pointer
is on that column (unless the program has taken the mouse). Drag the
thumb through the history, or click the track above or below it to
page a screenful. The bar is painted over the program's last column
rather than beside it, so the program's size never changes when the bar
comes or goes. A full-screen program — an editor, `htop` — runs on the
alternate screen, which keeps no history, so it never shows the bar.

`term.search` searches the scrollback — plain text with smart case, or
a regular expression. In the standard profile, `ctrl+f` in a terminal
pane opens it; `n` and `N` step through matches.

## Selecting and copying

Drag to select. Double-click selects a word and triple-click a line.
When the program has taken the mouse, hold `Shift` for any of these.

With **copy on select** on — the default — releasing the button copies
the selection to the clipboard, and so does a double- or triple-click.
Turn it off with the *Terminal copy on select* row in the settings
overlay, or in `config.zon`:

```zig
.{ .ui = .{ .copy_on_select = false } }
```

Off, a drag only selects, and you copy with `ctrl+c`.

The copy keys, in both profiles:

| Key | With a selection | With none |
| --- | ---------------- | --------- |
| `ctrl+c` | Clears the selection — copying it first when copy on select is off. The program hears nothing. | Goes to the program, as its interrupt. |
| `ctrl+shift+c` | Copies the selection, whatever the setting, and clears it. | — |

`ctrl+d`, `ctrl+z` and `ctrl+l` always go to the program.

In the vim profile, `ctrl+\ ctrl+n` puts the pane in terminal-normal
mode, where the keys go to mnml instead of the program: `/` searches,
`y` yanks the selection, the `ctrl+w` window keys work, `]a` / `[a`
step to the next or previous AI session, and `i` or `a` hands the
keyboard back.

## Pasting

`ctrl+shift+v` and `shift+insert` paste the clipboard into the pane, in
both profiles. Plain `ctrl+v` stays the program's — Claude Code uses it
to paste an image. A paste goes in as bracketed paste when the program
has asked for it.

## Links

URLs in a pane's output are links — a plain `https://…` as well as a
hyperlink the program printed (OSC 8) — and so are ticket keys and
pull-request references, by the patterns your installed integrations
declare (a manifest's `links[]`, in the [SDK](/docs/integrations/sdk)
reference). With no integration declaring one, only URLs link. A link
wears a dotted underline and lights under the pointer.

- `ctrl+click` or `cmd+click` opens it in the browser. A plain press
  still starts a selection.
- A right-click on it opens a menu with *Copy link* and *Open link*
  above *Copy*. While that menu is open the link stays lit in the
  accent with a solid underline, so you can see which link the rows
  are for.

A line is matched once it has held still for a frame, so a flood of
output costs nothing extra; a URL soft-wrapped over two rows links
whole on both.

## Links

URLs in a pane's output, and the ticket keys and pull-request
references your integrations declare, wear a dotted underline and light
under the pointer. `Ctrl`+click (`Cmd`+click on macOS) opens one; a
plain press still starts a selection. Right-click a link for *Copy link*
and *Open link*. See [Links](/docs/features/links).

## Windows

On Windows, panes use the system's ConPTY. The Windows build compiles
on every change but has not yet been run end to end, so expect rough
edges there;
[`docs/WINDOWS.md`](https://github.com/chris-mclennan/mnml/blob/main/docs/WINDOWS.md)
keeps the honest list.

## Configuration

The `terminal` keys — scrollback, shell integration, clipboard writes
and the rest — and `ui.copy_on_select` are in the
[configuration reference](/docs/config/reference).

## Next

- [Menus, Tabs and Fields](/docs/features/menus) — the right-click
  menus, tab strips and scrollbars a terminal pane shares with the rest
  of mnml.
- [AI sessions](/docs/features/ai) — Claude Code and Codex in terminal
  panes.
- [The API](/docs/features/api) — what a program in a pane may ask mnml
  to do.
