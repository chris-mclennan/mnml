---
title: Configuration
description: mnml works with no configuration, and everything it does can be changed in a config.zon file — by hand, or from the settings overlay.
---

## Zero configuration

mnml is meant to be useful the moment it starts. Every setting has a
default, the first-launch setup asks the handful of questions that are
genuinely personal (vim or standard, icons or plain characters, which
AI tools you use), and after that there is nothing you have to
configure.

When you do want to change something, there are two ways, and they
edit the same file.

## The settings overlay

`ctrl+,` (both profiles), or `:settings`, opens the **settings
overlay**: the everyday options — theme, keymap profile, icons, tree
width, line numbers, integrations and more — one row each, in sections.

| Key | Action |
| --- | ------ |
| `↑` `↓` / `j` `k` | Move between rows. |
| `←` `→` / `h` `l` | Change the value. |
| `Enter` | Keep the changes and close. |
| `Esc` | Put everything back as it was when you opened it. |

A change applies at once and is written to the file straight away, so
you see it before you decide. Each row knows which file it belongs in:
personal choices like the theme go to your home config, and per-project
view settings like the tree width go to the workspace's.

## The file: `config.zon`

Configuration is written in **ZON**, Zig's own data syntax: `.{ }` for
a group, `.name = value` for a setting, `//` for a comment. A file only
has to mention what it changes:

```zig
.{
    .editor = .{
        .input_style = .vim, // .vim or .standard
        .tab_width = 4,
    },
    .ui = .{
        .theme = "onedark",
        .ascii_icons = false,
        .tree_width = 30,
    },
}
```

A few rules make it predictable:

- **Choices are enum literals** — `.vim`, not `"vim"`. A value that is
  not one of the choices is an error at its line.
- **Errors stay local.** A mistake in `.ui` drops `.ui` from that file
  and leaves the rest applied; mnml always starts, and the problem is
  reported with its file, line and column.
- **Edits keep your file.** When mnml writes a setting — from the
  overlay, the first-launch setup, or a command — it changes that one
  value in place, keeps your comments and ordering, and saves a backup
  under `backups/` beside the file first.

`file.open_settings` opens your home `config.zon` in an editor. Opening
any `.zon` file and choosing **View as tree** on its tab turns it into a
form, with a widget for each setting.

Edits you make by hand take effect the next time mnml starts. Changes
made from the settings overlay apply immediately.

## Where it lives

mnml reads up to three files, each layered over the one before:

| Layer | File | |
| ----- | ---- | - |
| Home | `~/.config/mnml/config.zon` | Always read. |
| Workspace | `<workspace>/.mnml/config.zon` | Read subject to [trust](#workspace-trust). |
| Explicit | the file given to `--config PATH` | Always read, applied last. |

The home file lives in mnml's **data root**, which is
`~/.config/mnml` on macOS, Linux and Windows alike (on Windows, `~` is
your user profile folder). `$XDG_CONFIG_HOME/mnml` is used when
`XDG_CONFIG_HOME` is set, and `MNML_DATA_ROOT` moves the whole data root
anywhere you like. A portable install keeps it in `mnml-data` beside the
binary instead.

Most settings simply replace the value from the layer below. Chords,
snippets and abbreviations add to it instead, so a workspace can add a
key binding without restating yours.

## Workspace trust

A repository you clone can carry a `.mnml/config.zon`, and some settings
in it could run a program on your machine: a language server, a
formatter, a debugger, a task, or a Lua script. mnml will not run any of
those until you say so.

The first time you open such a workspace, mnml lists exactly what it
wants to run and asks **Trust this workspace?** — with *Don't trust*
selected. Until you trust it, those settings are left out, and the
statusline shows **RESTRICTED**. The rest of the workspace's settings
still apply. A workspace with nothing that could run a program is
trusted without asking.

Your answer is remembered per workspace, keyed to what the file asked
for: if a later change to it asks for something new, you are asked
again. `workspace.review_trust` shows the decision and lets you forget
it.

## One data root

Every mnml — installed, or built from source — keeps its state in the
same `~/.config/mnml`. There is no separate dev profile: a leftover
`~/.config/mnml-dev` from an older build is ignored; delete it, or move
what you want from it into `~/.config/mnml`, by hand. For a throwaway
state, launch with `--sandbox` or point `MNML_DATA_ROOT` somewhere
else.

## Coming from 0.2.x

mnml 0.2.x used `config.toml`. 0.3.0 reads only `config.zon` and never
reads or changes the TOML. If mnml finds a `config.toml` without a
`config.zon` beside it, it tells you once, with the command that
converts it — `mnml export-config-zon`, which ships in 0.2.22. See the
[0.3.0 release notes](/docs/install/release-notes/0-3-0#your-config-run-the-converter-first).

## Reference

The [configuration reference](/docs/config/reference) is the complete
commented `config.zon`: every setting, its default, and what it does.
Key bindings are covered on [Keymap Profiles](/docs/config/keymaps).
