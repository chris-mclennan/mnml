---
title: First run
description: Open mnml, pick an editing mode, find your way around the panes and pickers.
---

## Launch

```sh
mnml                       # open the current directory
mnml ~/code/project        # open a specific workspace
mnml --input vim           # start in vim mode (default is standard)
mnml --ascii               # no Nerd Font? plain-text icons
mnml --headless            # virtual screen + file-IPC channel (for scripts / .test)
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
| `:settings` | open the settings overlay |
| `F1` while hovering | click-discovery — see what every UI element does |

Every key is remappable — see [Configuration](#configuration) below.

## Editing: vim or standard

mnml ships two input handlers and lets you pick per-session or per-workspace:

```toml
# ~/.config/mnml/config.toml
[editor]
input_style = "vim"        # or "standard"
```

Switch at runtime with `:set input=vim` / `:set input=standard`, or the `editor.toggle_keymap` command.

The **vim** handler covers modal editing in depth — operators and text objects (`iw`, `ip`, tree-sitter objects `if`/`ic`/`ia`), registers, macros, marks (buffer-local + global, persisted), the `.` repeat, jumplist + change-list, `f`/`t`, vim-surround, multi-cursor, flash-motion jumps, abbreviations, and a deep `:` ex-command surface (`:%s///`, ranges, `:g/`, `:norm`, `:sort`, `:!cmd`, user `:command`s).

The **standard** handler is a modeless VS Code-style keymap with multi-cursor (`Ctrl-D` add-next-occurrence, `Ctrl-Alt-↑/↓` column cursors).

Both resolve through the same config-driven keymap, so `[keys.global]`, `[keys.vim]`, and `[keys.standard]` rebind either.

## Pane types

Editors aren't the only thing mnml can open in a pane. Splits + tabs let you mix-and-match these in one session:

- **Editor** — text buffer + LSP
- **Terminal (pty)** — a shell, the `claude` CLI, Codex, or any command
- **Diff** — git diff with per-hunk staging
- **Browser (CDP)** — Chrome via DevTools Protocol with network/console/DOM inspectors
- **DAP** — Debug Adapter Protocol client (breakpoints, stepping, watches, REPL)
- **HTTP request** — editable form-style request pane
- **SCM dashboard** — Bitbucket / GitHub / GitLab / Azure DevOps PRs + pipelines
- **AI** — `claude` CLI, Codex CLI, or direct Anthropic Messages API with agentic tools
- **Test results** — Playwright runner with trace viewer + flaky-test history

Open via the command palette (`Ctrl-Shift-P`) or the `:` ex-line.

## Settings overlay

`:settings` opens a keyboard-driven overlay for everyday config toggles — section headers, `▸ row` focus, `*` modified marker. Keys: `←→` adjust, `↑↓` move, `r` reset row, `R` reset all, `Enter` save, `Esc` cancel. v1 is discrete-choice rows only — number/text/color row kinds are v2.

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

# Bufferline launcher icons (right cluster). Drop in :host.launch entries for any
# private blit-host binary you've built locally.
[[ui.launcher_icon]]
id       = "myapp"
glyph    = "\u{F0668}"
fallback = "MA"
command  = ":host.launch myapp"
color    = "teal"
tooltip  = "My private blit-host app"
```

## Inside tmnl

If you're running mnml under [tmnl](https://tmnl.sh), three extra commands light up:

- `:tmnl.open-tab <command>` — opens a new tmnl tab running `<command>` instead of nesting it in mnml
- `:tmnl.pop-pty` — transfers the focused pty pane out of mnml into its own native tmnl tab (SCM_RIGHTS fd transfer, no state loss)
- The pluggable AI pane chips on the bufferline can launch into native tmnl tabs

If you're not under tmnl, these no-op with a toast.

## Headless

```sh
mnml --headless
```

Renders to a virtual screen driven over a file-IPC channel at `<workspace>/.mnml/ipc/`:
- `command` (JSONL, host → mnml)
- `screen.txt` / `status.json` / `events.jsonl` (mnml → host)

Same `App` and draw path as the GUI. Used by the `.test` e2e format (`mnml test` and under `cargo test`) and any out-of-process tooling that wants to drive mnml programmatically.

## Next

- See [FEATURES.md](https://github.com/chris-mclennan/mnml/blob/main/FEATURES.md) for the complete feature inventory.
- File an issue or feature request: https://github.com/chris-mclennan/mnml/issues
