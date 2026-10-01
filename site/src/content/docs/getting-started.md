---
title: Getting Started
description: Open a project, answer the first-launch questions once, and find everything else from the command palette.
---

This page assumes mnml is [installed](/docs/install) and `mnml --version`
prints a version. To try mnml without it touching your own config first,
see [Try It First](/docs/install/try).

## Opening a project

Run `mnml` in a project folder, or name one:

```sh
cd ~/src/my-project && mnml
mnml ~/src/my-project
mnml ~/src/my-project src/main.zig     # and open a file in it
```

The folder is the **workspace**: the file tree shows it, searches cover
it, and mnml keeps its per-project state in a `.mnml/` folder inside it.

When you quit (`ctrl+q`, or `:q` in the vim profile) mnml saves the
session — the layout, the open files, the cursor positions — and puts it
back the next time you open that workspace. `--no-session` starts clean.

## The first launch

The first time mnml runs, it opens a short setup with eight sections:

| Section | What it asks |
| ------- | ------------ |
| **Nerd Font** | Do the icons show, or boxes? If boxes, `space` installs *Symbols Nerd Font Mono* for you. |
| **Keyboard** | Checks that your terminal sends `Option`/`Alt` chords, and offers the fix it knows for your terminal. |
| **Input style** | vim or standard. |
| **Claude Code + Codex** | Whether they are installed; `space` runs their vendors' installers for whichever is missing. |
| **AI billing preference** | Whether Claude and Codex requests use your subscription or an API key. |
| **AI ghost-text** | Whether to show inline suggestions as you type. |
| **VSCode `code` shim** | On macOS, links VS Code's `code` command if you have VS Code but not the command. |
| **Integrations** | Jira and Bitbucket as checkboxes (none ticked), and a row for adding a [private source](/docs/integrations/private-sources). |

Press **Enter** to save. Only the answers you changed are written, to
your home `config.zon`, and ticked integrations are installed on the way
out. Press **Esc** to skip; nothing is written, and the setup comes back
next launch. `first_launch.show` opens it again whenever you like.

After that, mnml needs no configuration. Everything else has a default.

> [!NOTE]
> If the workspace you open has its own `.mnml/config.zon` that could
> run programs — a language server, a formatter, a task, a script —
> mnml asks whether to trust it before the setup appears. See
> [Workspace trust](/docs/config#workspace-trust).

## Vim or standard

mnml has two complete keymaps. **standard** (the default) is modeless,
with VS Code's chords. **vim** has modes, motions, operators, the `:`
line, and NvChad's leader menus under `space`. Change your mind any time
in the settings overlay, for one launch with `--input vim`, or in
`config.zon`:

```zig
.{ .editor = .{ .input_style = .vim } }
```

The [Editor](/docs/features/editor#two-keymap-profiles) page compares
the everyday chords, and the [keymap profiles](/docs/config/keymaps)
page lists all of them.

## Finding things

Every action in mnml is a named command, and there are over a thousand.
You do not need to learn many keys, because these four find the rest:

| Keys (both profiles) | Opens |
| -------------------- | ----- |
| `ctrl+shift+p` | The **command palette**: any command by name, with its chord beside it — so it is also how you learn the keys. |
| `ctrl+p` | A file by name. |
| `ctrl+;` | A `:` command line, in either profile. Besides vim's own commands it runs any command by its id, as in `:tab.close`. |
| `space` (vim) / `ctrl+k` (standard) | **which-key**: a menu of every leader chord, grouped. |

Right-click almost anything — a file, a tab, a chip on the statusline —
for a menu of what you can do with it.

<!-- video: palette -->

## A tour in five commands

- ``ctrl+shift+` `` opens a terminal beside your code. Or type `:term`.
- `space g s` (`ctrl+k g s` in standard) opens git status.
- `space a c` (`ctrl+k a c`) starts a Claude Code session in a split,
  if you have Claude Code installed. See [AI Coding Sessions](/docs/features/ai).
- `ctrl+shift+x` opens the INTEGRATIONS section and its Marketplace.
- `ctrl+,` opens the **settings overlay**: the everyday options, one row
  each, changed with the arrow keys and applied as you go. `Enter` keeps
  the changes; `Esc` puts everything back.

## Where to next

- [Configuration](/docs/config) — how `config.zon` works, and where it
  lives.
- [Features](/docs/features) — what is in the box.
- [Lua Scripting](/docs/lua) — your own commands, keys and hooks.
- [Help](/docs/help) — when something looks wrong.
