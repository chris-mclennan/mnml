---
title: First run
description: Open mnml, pick an editing mode, find your way around.
---

## Launch

```sh
mnml                       # open the current directory
mnml ~/code/project        # open a specific workspace
mnml --input vim           # start in vim mode (default is standard)
mnml --ascii               # no Nerd Font? plain-text icons
```

## First few keys

| Key | Action |
|-----|--------|
| `Ctrl-P` | fuzzy file finder |
| `Ctrl-Shift-P` / `F1` | command palette |
| `Ctrl-B` | toggle the file tree |
| `Ctrl-K` / `<space>` | which-key leader popup |
| `Ctrl-\`` | scratch terminal |
| `:` (vim mode) | ex-command line |

Every key is remappable — see [Configuration](#configuration).

## Editing: vim or standard

mnml ships two input handlers and lets you pick per-session or per-workspace:

```toml
# ~/.config/mnml/config.toml
[editor]
input_style = "vim"        # or "standard"
```

Switch at runtime with `:set input=vim` / `:set input=standard`, or the `editor.toggle_keymap` command.

The **vim** handler covers modal editing in depth — operators and text objects, registers and macros, marks, `:`-commands (`:%s///`, ranges, `:g/`, `:norm`, …), surround, and more.

The **standard** handler is a modeless VS Code-style keymap.

Both resolve through the same config-driven keymap, so `[keys.global]`, `[keys.vim]`, and `[keys.standard]` rebind either.

## Configuration

mnml reads TOML, merged lowest-to-highest precedence:

```
built-in defaults
  → ~/.config/mnml/config.toml
  → <workspace>/.mnml/config.toml
  → --config PATH
```

```toml
[editor]
input_style = "standard"   # "vim" | "standard"
tab_width   = 4

[ui]
theme       = "onedark"    # any of 94 themes — gruvbox, catppuccin, kanagawa, nord, …
ascii_icons = false
wrap        = false

[keys.global]
"ctrl+s" = "buffer.save"
"ctrl+p" = "picker.files"
"f5"     = "dap.run"

[lsp.rust]
cmd        = "rust-analyzer"
extensions = ["rs"]
```

## Next

- Skim the project README for the broader feature inventory.
- File an issue or feature request: https://github.com/chris-mclennan/mnml/issues
