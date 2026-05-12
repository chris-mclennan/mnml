# mnml — a NvChad-style terminal IDE (Rust + ratatui)

Greenfield. Supersedes the `../mnml1` prototype and absorbs `../rqst` (a ratatui
Postman-in-the-terminal) — both are **reference implementations to port logic
from, not dependencies**. Full design + phased roadmap: **`.local/PLAN.md`** (the
authoritative spec; read it before architectural decisions).

## Architecture spine — keep these load-bearing

- **Pluggable input layer.** `Box<dyn InputHandler>` (`src/input/`) translates key
  events into `Vec<EditOp>` (text editing — `src/edit_op.rs`, interpreted by the
  single chokepoint `src/editor.rs::Editor::apply`) or escalates to a small *closed*
  `AppCommand` / a registered command. The editor/buffer/render layers **never**
  branch on which handler is active — only the statusline (mode chip) and the
  cursor-shape code read the 4-variant `EditingMode`. (`grep -rn EditingMode src/ui`
  should hit only `statusline.rs`.) This is "vim way + standard way without
  conditionals everywhere" — the thing the user explicitly wants done right.
- **`Pane` + `Layout` + `Command` registry are the rest of the spine.** `Pane`
  (`src/pane.rs`) is the open-thing enum (Editor today; Pty/Request/Diff/Ai later —
  each additive). `Layout` (`src/layout.rs`) is the split tree (Empty|Leaf today;
  HSplit/VSplit in P3). `Command` (`src/command.rs`, a process-global `OnceLock`) is
  what the palette / which-key / keybindings / plugins all hang off. Adding a feature
  = register commands + maybe a `Pane`/`EditOp` variant — not a refactor.
- **Headless mode (`src/headless.rs`, renders via ratatui `TestBackend`) + the file-IPC
  channel (`src/ipc/`) share `app.rs` + `ui::draw` + `tui::dispatch_*` with the
  terminal loop (`src/tui.rs`)** so headless behavior matches the real UI. This is the
  substrate for the planned `.test` E2E format. IPC lives at `<workspace>/.mnml/ipc/`:
  `command` (JSONL host→mnml), `screen.txt` / `status.json` / `events.jsonl` (mnml→host).
- **No giant files.** `src/app.rs` is render-free; `src/tui.rs` is *only* the crossterm
  event loop; chrome lives in `src/ui/`, subsystems get their own dirs (`src/git/`,
  later `src/http/`, `src/lsp/`, `src/ai/`, `src/cdp/`). mnml1's `tui.rs` (~56k chars)
  and rqst's `app.rs` (~468k chars) both rotted — don't repeat that.
- Storage is a plain `String` + byte cursor in `Editor`; all mutation goes through
  `apply` so a rope can slide in later without touching call sites. Columns are chars
  for now (display-width / tabs / CJK is a P2 refinement).

## Build / run / test

```bash
cargo build            # debug
cargo test             # unit tests
cargo clippy --all-targets   # must be warning-free
cargo fmt              # before committing

./run.sh               # launch mnml in *your* cwd (build + run, relaunch-on-exit-75 loop)
./run.sh ~/some/proj   # launch on a specific workspace
./run.sh restart       # tell the running mnml to rebuild + relaunch (IPC {"cmd":"restart"})
./run.sh stop          # quit the running mnml
./run.sh status        # show the marker (workspace, IPC dir)
./run.sh headless [WS]  # same loop, but --headless (virtual screen + file-IPC)
./dev.sh               # cargo-watch auto-rebuild-on-save loop (needs `cargo install cargo-watch`)

cargo run -- [WS] [--input vim|standard] [--ascii] [--config PATH] [--headless]
```

**The user keeps a `mnml` instance running via `./run.sh`.** After a `cargo build`
that **succeeds**, run `./run.sh restart` so it picks up the new code. (A
`PostToolUse` hook in `.claude/settings.json` does this automatically; the manual
command is the fallback.) Do **not** restart on a *failed* build — that would tell
the loop to rebuild, fail, and the instance would disappear. `restart` force-relaunches
(bypasses the unsaved-changes guard) and re-reads files from disk, so flag it if the
user might be mid-edit *inside mnml* on something untouched.

## Conventions

- `cargo fmt` + `cargo clippy --all-targets` clean before every commit. Run the test
  suite. Commit messages end with the `Co-Authored-By: Claude …` trailer.
- Work on a branch only if asked / on `main` — this repo's default workflow is small
  commits straight to `main` (the user authorized that).
- Don't copy code verbatim from `../mnml1` or `../rqst`; port + restructure.
- When a track needs something from the core, add a `Command` / `EditOp` / `Pane`
  variant — don't special-case across layers.

## Status

P0–P3 done. Working: NvChad-ish layout; editable buffers via
either `StandardInputHandler` (VSCode-style, modeless) or `VimInputHandler` (modal:
Normal/Insert/Visual + `:`-line), swappable at runtime (`editor.toggle_keymap` /
`editor.use_vim` / `editor.use_standard` in the palette, or `:set input=vim`);
`:`-commands (`w q wq x q! wa wqa qa bd bn bp e set …`) via `App::run_ex_command`;
selection/undo/clipboard; fuzzy file finder (`Ctrl+P`) + command palette
(`Ctrl+Shift+P` where the terminal supports the kitty protocol, else `F1`) + buffer
switcher (`src/picker.rs` / `src/fuzzy.rs`); config-driven keymap — app-level chords
resolve through `App::keymap` (`src/input/keymap.rs::Keymap`), built from each
`Command`'s default `keys: &[&str]` overlaid with `[keys.global]` / `[keys.<style>]`
config (`"key" = "command.id"`, `= "none"` to unbind); which-key leader popup
(`src/whichkey.rs` trie + `src/ui/whichkey.rs`) — `<space>` in vim Normal or `Ctrl+K`
opens it, keys descend a group, a leaf runs its command (`whichkey.leader` command;
state on `App.whichkey`); editor splits — `Layout` is a binary split tree (`Empty | Leaf |
Split{dir,ratio,first,second}`), `ui::draw` recursively renders one editor per leaf with
1-cell dividers; each leaf shows a distinct buffer, background buffers (in no leaf) are
allowed (bufferline shows all), `App.active` = focused pane = uniquely the focused leaf;
`view.split_right`/`view.split_down`, `view.focus_{left,right,up,down}`,
`view.focus_next_split`, `view.close_split` commands, surfaced in the which-key `+split`
submenu (`<leader>s …` / `Ctrl+K s …`); click a leaf to focus it, drag a divider to
resize it; closing a dirty buffer pops a Save/Discard/Cancel overlay (`src/ui/close_prompt.rs`).
tree-sitter syntax highlight (`src/highlight.rs`, 12 grammars: rs/js/jsx/ts/tsx/py/json/go/
toml/css/bash/html/md) + indent guides. **Theme engine** (`src/ui/theme.rs`): a `Theme`
struct (named UI colours + `base16[16]`) behind an `RwLock`; `theme::cur()` reads it,
`theme::set(name)` swaps it. Themes are all of NvChad's base46 schemes (~90), converted
to `themes/*.toml` (`[base_30]` + `[base_16]` colour tables), enumerated by `build.rs` →
`THEME_SOURCES` and parsed (serde/`toml`) at first use; `onedark` is the default (also
kept hardcoded as the seed/fallback).
`[ui] theme = "…"` at launch, `theme.pick` command / `:set theme=…` at runtime
(re-highlights open buffers). Markdown preview — `Pane::MdPreview` (`src/ui/md_preview.rs`,
a block-level renderer: headings/lists/fenced code/blockquotes/hrules styled, inline
markers unwrapped); `markdown.preview` command (`<leader>m`) opens a rendered, read-only,
scrollable view in a split next to the source, refreshed when the source is saved.
Git: branch + change counts in the statusline + tree tint (P0); **gutter line-signs** —
`src/git/diff.rs` parses `git diff HEAD --unified=0` into per-file added/modified/removed
line marks (kept in `GitStatus`'s ~3s-cached `Snapshot.line_changes`), drawn as a coloured
`▎` in the editor gutter; **diff pane** — `Pane::Diff` (`src/ui/diff_view.rs`) shows parsed
hunks (header + context/`+`/`-` lines), `n`/`p` move the cursor hunk, `s`/`u` stage/unstage
it (`git apply --cached [--reverse]`), `r` refreshes, Enter jumps to the hunk's line in the
source editor; `git.diff_file` (`<leader>g d`, opens in a split next to the source) /
`git.diff` (worktree). headless+IPC (interactive TUI listens too) + the `run.sh`/`dev.sh`
wrappers. The statusline git segment shows branch + `⇡ahead ⇣behind` + `✚staged ●modified
…untracked ⚠conflicts` (only the nonzero parts), from `git status --porcelain -b`. Next:
the rest of the Git track (blame gutter → commit-from-mnml), then HTTP, Pty/AI-CLI, AI-API, CDP, the `.test`
E2E format, plugins; plus queued polish (right-click context menus on files/tabs,
inline-styled markdown, line-wrapped preview). See `.local/PLAN.md` for the full plan.
Highlight follow-ups: more grammars, incremental tree-sitter parsing, relative line numbers.

## Not set up yet (could add later)

- `.mcp.json` — no project MCP servers needed yet.
- `.claude/agents/` — a `code-reviewer` subagent could be useful once the codebase grows.
- The repo isn't packaged as a Claude Code plugin (`.claude-plugin/`); not needed for a single repo.
