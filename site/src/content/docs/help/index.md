---
title: Help
description: Common problems and their fixes, where mnml keeps its logs, and how to report a bug.
---

mnml is a personal project with no support team. This page collects the
problems new users run into most often; if yours is not here, see
[Reporting a bug](#reporting-a-bug).

## Common issues

| Issue | Solution |
| ----- | -------- |
| Icons show as boxes or question marks | [A Nerd Font](#icons-show-as-boxes-or-question-marks) |
| `alt` / `Option` chords do nothing | [Alt and Option chords](#alt-and-option-chords-do-nothing) |
| The setup questions come back every launch | [The first-launch setup](#the-first-launch-setup-keeps-coming-back) |
| My 0.2.x settings are gone | [config.zon, not config.toml](#my-02x-settings-are-gone) |
| The statusline says RESTRICTED | [Workspace trust](#the-statusline-says-restricted) |
| Something went wrong and I want details | [Logs and messages](#logs-and-messages) |

## Icons show as boxes or question marks

mnml draws file icons, the sidebar rail and statusline chips with
[Nerd Font](https://www.nerdfonts.com/) symbols, and your terminal's font
does not have them.

- The quickest fix is the first-launch setup's **Nerd Font** section:
  answer that you see boxes and press `space` to install *Symbols Nerd
  Font Mono* (with Homebrew on macOS, into `~/.local/share/fonts` on
  Linux, and into your user fonts on Windows). When it finishes, mnml
  tells you how to point your terminal at it. Reopen the setup with
  `first_launch.show`.
- The symbols-only font has no letters, so it is never your main font.
  In Ghostty, set `font-family` to any full Nerd Font mono — for example
  `JetBrainsMono Nerd Font Mono`. In iTerm2, set it as the font for
  non-ASCII text. In WezTerm, add it to the `font` fallback list.
- Or run without symbols: `mnml --ascii` for one launch, or
  `.ui = .{ .ascii_icons = true }` in `config.zon`.

A few marks, such as the Claude icon on a session's tab, come from
mnml's own font, `MnmlSymbols.ttf`. It ships in every release archive
under `share/mnml/fonts/` (and in `/usr/share/mnml/fonts/` from the
Linux packages); install it like any other font. In Ghostty also add:

```text
font-codepoint-map = U+F1B00-U+F20FF=MnmlSymbols
```

Quit and reopen the terminal completely after installing a font.

## Alt and Option chords do nothing

Many terminals on macOS send `Option` as a character-composing key
rather than as `Alt`, so chords like `alt+1` never reach mnml.
`keys.doctor` shows which modifier chords arrive. In Ghostty on macOS,
the first-launch setup's **Keyboard** section can set
`macos-option-as-alt = true` in Ghostty's config for you; for other
terminals it tells you the setting to change.

## The first-launch setup keeps coming back

The setup is saved only when you press **Enter**. **Esc** skips it
without writing anything, so it asks again next launch. Press Enter,
even with nothing changed, and it will not return. `first_launch.show`
opens it again later.

## My 0.2.x settings are gone

mnml 0.3.0 reads `config.zon` and never reads `config.toml`. Your old
file is still there, untouched. Convert it with `mnml export-config-zon`
from mnml 0.2.22 — the
[0.3.0 release notes](/docs/install/release-notes/0-3-0#your-config-run-the-converter-first)
explain how, including after you have already upgraded.

## The statusline says RESTRICTED

The workspace has settings that could run a program — a language
server, a formatter, a task, a Lua script — and you have not trusted it,
so those settings are not in effect. It also appears when the workspace
still has an unconverted 0.2.x `.mnml/config.toml`. Click the chip, or
run `workspace.review_trust`, to see which and decide. See
[Workspace trust](/docs/config#workspace-trust).

## Logs and messages

- **`:messages`** lists every notice mnml has shown this session (the
  last 200). In the standard profile, `ctrl+k ctrl+shift+n` opens it.
  `:messages!` copies the list into a buffer you can search.
- **`mnml.log`**, in the data root (`~/.config/mnml/mnml.log` by
  default), collects the log output while mnml is running. It starts
  fresh on every launch, so copy it before restarting if you need it.
- **`mnml.log` is not written** for `--headless`, `mnml test` and the
  command-line subcommands; they log to the terminal instead.
- If mnml **crashes**, it restores your terminal and prints the error
  and a stack trace. Include that trace in a bug report.

## Windows

The Windows build compiles on every release but has not been run end to
end yet, so problems there are more likely.
[`docs/WINDOWS.md`](https://github.com/chris-mclennan/mnml/blob/main/docs/WINDOWS.md)
lists what is known to work and what is still open.

## Reporting a bug

<!-- cards -->
- [GitHub Issues](https://github.com/chris-mclennan/mnml/issues) — Search existing reports, and open a new one for a bug or a request.
- [Source on GitHub](https://github.com/chris-mclennan/mnml) — The code, the design notes under docs/, and the changelog.

Search the issues first, then open a new one with:

- `mnml --version`;
- your operating system and terminal;
- what you did, what you expected, and what happened;
- the relevant part of `mnml.log`, or the crash trace.
