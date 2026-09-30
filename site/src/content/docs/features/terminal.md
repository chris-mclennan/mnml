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
- **The Kitty keyboard protocol**, for programs that turn it on.
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

`term.search` searches the scrollback — plain text with smart case, or
a regular expression. In the standard profile, `ctrl+f` in a terminal
pane opens it; `n` and `N` step through matches.

## Selecting and copying

Drag to select. Double-click selects a word and triple-click a line.
Releasing the button copies the selection to the clipboard.

In the vim profile, `ctrl+\ ctrl+n` puts the pane in terminal-normal
mode, where the keys go to mnml instead of the program: `/` searches,
`y` yanks the selection, the `ctrl+w` window keys work, and `i` or `a`
hands the keyboard back.

`ctrl+c`, `ctrl+d`, `ctrl+z` and `ctrl+l` always go to the program.

## Windows

On Windows, panes use the system's ConPTY. The Windows build compiles
on every change but has not yet been run end to end, so expect rough
edges there;
[`docs/WINDOWS.md`](https://github.com/chris-mclennan/mnml/blob/main/docs/WINDOWS.md)
keeps the honest list.

## Configuration

The `terminal` keys — scrollback, shell integration, clipboard writes
and the rest — are in the [configuration reference](/docs/config/reference).
