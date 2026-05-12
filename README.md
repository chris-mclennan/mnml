# mnml

A NvChad-style terminal IDE, in Rust + [ratatui](https://ratatui.rs).

mnml is one binary that aims to be a real editor *and* a baked-in HTTP request
client *and* a scriptable/testable surface — built so the pieces compose instead
of fighting each other. It supersedes the `../mnml1` prototype and absorbs the
logic of `../rqst` (a "Postman in the terminal"); both are reference
implementations to port from, not dependencies.

> **Status:** P0–P3 of the roadmap are done — see [`.local/PLAN.md`](.local/PLAN.md)
> for the full design + phased plan, and [`CLAUDE.md`](CLAUDE.md) for the
> architecture spine and working conventions. The big tracks (LSP, rich git,
> ripgrep search, embedded pty / Claude Code / Codex panes, API-based AI, the
> rqst HTTP stack, CDP/Chrome capture, a `.test` E2E format, plugins) are next.

## What works today

- **NvChad-ish layout** — file-tree rail, a top "tabufline" of open buffers, a
  powerline statusline, onedark theme, Nerd-Font devicons, tree-sitter syntax
  highlight, indent guides.
- **Two editing modes, swap at runtime** — a modeless VSCode-style keymap
  (`StandardInputHandler`) or a modal vim keymap (`VimInputHandler`: Normal /
  Insert / Visual + a `:` command line). Switch with `editor.toggle_keymap` /
  `:set input=vim` / `:set input=standard`. The editor/render layers never branch
  on which handler is active — that's the "vim way *and* standard way without
  conditionals everywhere" design.
- **Editor splits** — split side by side or stacked (recursive split tree),
  move focus between splits, click a split to focus it.
- **Command palette** (`Ctrl+Shift+P` where the terminal supports the kitty
  keyboard protocol, else `F1`), **fuzzy file finder** (`Ctrl+P`), **buffer
  switcher**, and a **which-key leader popup** (`<space>` in vim Normal, or
  `Ctrl+K`).
- **Config-driven keybindings** — `[keys.global]` / `[keys.vim]` / `[keys.standard]`
  in TOML, `"key" = "command.id"`, `= "none"` to unbind.
- **Headless mode + file-IPC channel** — drives the same UI without a terminal
  (`mnml --headless`), reading commands from `<workspace>/.mnml/ipc/command` and
  writing `screen.txt` / `status.json` / `events.jsonl`. The substrate for the
  planned `.test` E2E format.
- **Mouse everywhere** — tree, tabs (including the `×`/`●` close hitbox), editor
  cursor placement, split focus, scroll.

## Build / run

```bash
cargo build
cargo test
cargo clippy --all-targets   # kept warning-free
cargo fmt

cargo run -- [WORKSPACE] [--input vim|standard] [--ascii] [--config PATH] [--headless]

# convenience wrappers
./run.sh [WORKSPACE]   # build + run, with a rebuild-on-exit-75 loop
./run.sh restart       # tell a running instance to rebuild + relaunch (IPC)
./dev.sh               # cargo-watch auto-rebuild-on-save (needs `cargo install cargo-watch`)
```

A [Nerd Font](https://www.nerdfonts.com/) is recommended (devicons + powerline
glyphs); pass `--ascii` (or `[ui] ascii_icons = true`) to fall back.

## Configuration

TOML, merged from (lowest → highest precedence): built-in defaults →
`~/.config/mnml/config.toml` → `<workspace>/.mnml/config.toml` → `--config PATH`.
Sections: `[editor]` (`input_style`, `tab_width`), `[ui]` (`theme`, `ascii_icons`,
`tree_width`), `[keys.*]` (keybindings). `[lsp.*]` / `[ai]` / `[tools]` are parsed
and kept for their tracks.

## License

MIT — see [LICENSE](LICENSE). Contributors: [CONTRIBUTORS.md](CONTRIBUTORS.md).
