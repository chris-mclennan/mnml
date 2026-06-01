---
title: Settings & configuration
description: mnml's two-layer TOML config, the schema-driven settings overlay, and every knob in `[ui]` / `[editor]` / `[keys.*]` / `[lsp.<server>]` and the git-host / AI / HTTP tables.
---

mnml has two ways to change behavior: a **TOML config file** (the durable surface — every knob, including ones that don't have a UI yet) and a **Settings overlay** (`:settings` / `view.settings` — a keyboard-driven sectioned list for the everyday toggles). The overlay writes to the live config in memory; the TOML file is the on-disk source of truth.

Both layers see the same `Config` struct. Editing TOML and reopening, or toggling in the overlay, both end up at the same state.

## Where config lives

mnml reads two files at startup, **lowest to highest precedence**:

1. **Global** — `~/.config/mnml/config.toml` (or `$XDG_CONFIG_HOME/mnml/config.toml` when `XDG_CONFIG_HOME` is set).
2. **Per-workspace overlay** — `<workspace>/.mnml/config.toml`, relative to whatever directory you launched mnml in.
3. **Explicit** — `mnml --config /some/path.toml`, applied on top of the two above.

Each file is a *partial overlay*: keys you don't set fall through to the lower layer (or to the built-in default). So a workspace-local file can flip `input_style = "vim"` for just that repo without re-declaring everything else.

Missing files are fine — mnml silently treats them as empty. A malformed file is reported on stderr and skipped (the rest of the layers still apply). To re-apply a file at runtime without restarting:

```vim
:source ~/.config/mnml/config.toml
```

A few sections (`[[bitbucket.repos]]`, `[[github.repos]]`, `[[workspaces]]`, `[[ui.launcher_icon]]`, …) have their own merge rules — repos and workspaces *append* across files; launcher-icon and integration-icon arrays *replace*. Those quirks are called out below.

## The Settings overlay

Open it with `:settings`, the `view.settings` command id from the palette, or the gear glyph in the bufferline. The overlay is a centered ~60% × 70% sectioned list — section headers `── UI ──` / `── Editor ──` / `── Session ──` / `── Reset ──` with editable rows in between.

Each row looks like:

```
▸ Cursor line:     [on] / off  *
  Scrollbar:       [on] / off
  Tab width:       2 / [4] / 8
```

- `▸` marks the focused row.
- `[bracketed]` is the current value.
- Trailing `*` means the row's value differs from the built-in default.

### Keys

| Key | Action |
|---|---|
| `↑` `↓` / `j` `k` | Move row (skips section headers) |
| `←` `→` / `h` `l` | Cycle the focused row's value backward / forward |
| `r` | Reset just this row to its default |
| `R` | Reset every setting (also: focus the **Reset all to defaults** row and press `Enter`) |
| `Enter` | On a normal row, same as `→`. On the reset-all sentinel row, fires the global reset |
| `Esc` | Cancel — revert the live config to whatever it was when the overlay opened |

`Enter` (anywhere except the reset row) commits whatever's currently on screen and closes the overlay. The overlay does **not** persist changes to TOML — it writes the in-memory `Config`. If you want a change to survive restarts, also edit the matching TOML key.

### What's in the overlay vs what's TOML-only

The overlay covers **discrete-choice rows only** — booleans (`on` / `off`), input style (`vim` / `standard`), tab width (`2` / `4` / `8`), line numbers (`relative` / `absolute` / `off`), picker position (`center` / `top`). Number / text / color inputs are a planned v2.

Things the overlay does **not** edit:

- Arrays of complex things — `[[workspaces]]`, `[[bitbucket.repos]]`, `[[ui.launcher_icon]]`, `[snippets.<scope>]`, `[tasks.<name>]`, `[formatters.<ext>]`, `[linters.<ext>]`. These stay in TOML.
- Free-form strings — theme name, ticket prefixes, formatter command templates.
- `[keys.*]` tables — keybindings are TOML-only (see [Keybindings](#keybindings) below).

### Row → config key mapping

Each row drives a single `Config` slot. Useful when you want to find the matching TOML key:

| Row | Key |
|---|---|
| Line numbers | `[ui] relative_line_numbers` + `[ui] line_numbers` (3-state) |
| Cursor line | `[ui] cursor_line` |
| Scrollbar | `[ui] scrollbar` |
| Syntax highlighting | `[ui] syntax` |
| Show whitespace | `[ui] show_whitespace` |
| Bracket rainbow | `[ui] bracket_rainbow` |
| Highlight trailing whitespace | `[ui] highlight_trailing_ws` |
| Statusline clock | `[ui] clock` |
| Highlight word under cursor | `[ui] highlight_word_under_cursor` |
| Soft wrap | `[ui] wrap` |
| Sticky scope context | `[ui] sticky_context` |
| Inline markdown rendering | `[ui] render_markdown` |
| Auto-open markdown preview | `[ui] auto_md_preview` |
| Palette / picker position | `[ui] picker_position` |
| Input style | `[editor] input_style` |
| Tab width | `[editor] tab_width` |
| Trim trailing whitespace on save | `[editor] trim_trailing_ws_on_save` |
| Auto-pair brackets / quotes | `[editor] auto_pair` |
| Auto-indent on Enter | `[editor] auto_indent` |
| Format on save (LSP) | `[editor] format_on_save` |
| Inlay hints | `[editor] inlay_hints` |
| Code lens | `[editor] code_lens` |
| Breadcrumb | `[editor] breadcrumb` |
| Restore open buffers on launch | `[session] restore` |

## The major sections

### `[ui]` — chrome and visual knobs

```toml
[ui]
theme = "onedark"                 # any of mnml's 94 base46 themes
theme_toggle = "gruvbox"          # optional second theme for the 1-press slider
ascii_icons = false               # fallback glyphs when not running a Nerd Font
tree_width = 30                   # file-tree rail width (clamped 10..=80)

# Gutter / cursor decoration
line_numbers = true               # master switch for the line-number gutter
relative_line_numbers = false     # hybrid relative numbers (cursor line is absolute)
cursor_line = false               # paint a subtle tint on the cursor's row
scrollbar = true                  # 1-col vertical scrollbar on each editor pane
scrolloff = 0                     # keep cursor N rows from the viewport edges
sidescrolloff = 0                 # horizontal counterpart
show_whitespace = false           # `·` for space, `→` for tab
bracket_rainbow = false           # cycling colors on matched brackets
highlight_trailing_ws = false     # red background on trailing whitespace cells
color_column = 0                  # subtle marker at column N (0 = off; 80 for the classic hint)
wrap = false                      # soft-wrap long lines instead of clipping
syntax = true                     # tree-sitter highlighting master switch

# Statusline / chrome extras
clock = true                      # `HH:MM` chip in the statusline
highlight_word_under_cursor = false
auto_md_preview = false           # open the rendered preview when opening any `.md`
render_markdown = false           # inline markdown rendering in the editor pane
sticky_context = false            # enclosing scope chain at the pane top
md_image_rows = 12                # rows reserved for markdown image embeds
picker_position = "center"        # or "top" — where the palette / picker anchors

# Pty-tab auto-naming
ticket_prefixes = ["TE-", "MIX-", "PROJ-"]  # see below
```

#### Theme

`theme` is the active palette; `theme_toggle` (optional) is the *other* member of a light/dark pair. The slider button in the bufferline flips between them on click; when `theme_toggle` is unset, the slider falls back to opening the full theme picker. See the [Themes](/manual/themes/) page for the list.

#### `ticket_prefixes`

When set (e.g. `["TE-", "MIX-"]`), pty session tabs that don't have a user-set name auto-fill their label from the most-recently-mentioned ticket token in the session's visible scrollback. Useful for Claude Code / Codex sessions discussing a specific ticket — the tab strip shows `TE-1234` instead of `claude code` without a manual `:rename`. Empty (default) disables the scan entirely.

#### The launcher-icon strips

mnml has two icon strips driven from `[ui]` arrays:

- `[[ui.launcher_icon]]` — colored chips on the right edge of the bufferline. Defaults to empty.
- `[[ui.integration_icon]]` — plain glyphs in the rail's INTEGRATIONS row (under GIT). Defaults to Claude Code / Codex / Bitbucket / HTTP / CodeBuild / GitHub.

Both share the same shape:

```toml
[[ui.launcher_icon]]
id       = "myapp"                       # stable identifier
glyph    = "\u{F0668}"                   # nerd-font glyph
fallback = "MA"                          # ASCII fallback for --ascii / ascii_icons = true
command  = ":host.launch myapp"          # leading `:` ⇒ ex-cmdline; no prefix ⇒ command id
color    = "teal"                        # orange / cyan / blue / green / yellow / purple / red / teal / bg2
tooltip  = "My private blit-host app"    # optional hover text
```

Setting the array **replaces** the built-in defaults — copy the defaults from the source if you want to extend rather than replace.

### `[editor]` — editing behavior

```toml
[editor]
input_style = "standard"          # or "vim" — picks the input layer
tab_width = 4                     # min 1
autosave_secs = 0                 # auto-save N secs after last edit; 0 = off
autosave_on_focus_loss = false    # save dirty buffers on buffer/pane switch

# Indent / pair / wrap behavior
auto_indent = true                # carry leading whitespace on Enter
auto_pair = false                 # `(` inserts `()` with cursor between
text_width = 80                   # target width for `gqq` reflow

# Save-time transforms
trim_trailing_ws_on_save = false
ensure_trailing_newline = true    # POSIX file convention
format_on_save = false            # textDocument/formatting before each save
format_on_type = false            # textDocument/onTypeFormatting on `}` / `;` / `\n`
will_save_wait_until = false      # eslint --fix / organize-imports hook

# LSP-driven decorations
inlay_hints = true                # type / parameter chips
code_lens = true                  # `5 references` / `Run | Debug` chips
semantic_tokens_viewport = false  # range-only tokens for very large files
breadcrumb = true                 # workspace-relative path above each editor pane
```

The full list is in the [Editing manual](/manual/editing/) and the [LSP manual](/manual/lsp/) — this is the on-disk surface.

### `[keys.global]`, `[keys.vim]`, `[keys.standard]`

Keymaps are **key spec → command id** (the same shape as VSCode's `keybindings.json`). The reverse direction is awkward — a key can only do one thing — and this lets `"ctrl+p" = "none"` cleanly unbind a default.

```toml
[keys.global]
"ctrl+p" = "picker.files"
"ctrl+shift+p" = "picker.commands"
"alt+`" = "term.toggle"

[keys.vim]
" ff" = "picker.files"            # leader+ff (space prefix)
" gs" = "git.status_pane"

[keys.standard]
"ctrl+s" = "file.save"
"ctrl+/" = "editor.toggle_comment"
```

- `[keys.global]` applies always.
- `[keys.vim]` and `[keys.standard]` overlay it for that input style — so you can give the same chord different meanings in each mode.
- Unknown command ids are tolerated — they just never fire (handy when sharing a config across mnml versions).
- **Unbinding**: set the value to `""` or `"none"` to drop a default binding.

The full command-id catalog lives in the command palette (`Ctrl+Shift+P` or `:`) — every command shows its id alongside its label. Defaults are documented in the [Keybindings reference](/reference/keybindings/).

### `[lsp.<server>]` — language servers

Each `[lsp.<name>]` table layers on top of the built-in default of the same name. Partial overrides fall through field by field.

```toml
[lsp.rust]
cmd = "rust-analyzer"
args = []
extensions = ["rs"]
root_markers = ["Cargo.toml"]
language_id = "rust"

[lsp.lua]
cmd = "lua-language-server"
extensions = ["lua"]
root_markers = [".luarc.json", "stylua.toml"]
```

See the [LSP manual](/manual/lsp/) for the field reference and the list of servers mnml ships defaults for.

### Git-host integrations — `[bitbucket]`, `[github]`, `[gitlab]`, `[azdevops]`

mnml ships per-provider dashboards for pipelines and pull / merge requests. Each follows the same shape: top-level config keys plus an array of `[[<provider>.repos]]` (or `.projects`) entries.

```toml
[bitbucket]
auth_env  = "BITBUCKET_TOKEN"     # env var to read the API token from
poll_secs = 60                    # min 5

[[bitbucket.repos]]
workspace = "tattledevs"
slug      = "tattle-api"

[[bitbucket.repos]]
workspace = "tattledevs"
slug      = "tattle-playwright"
branches  = ["main", "release/2026-Q2"]   # pinned branches for the per-branch view

[github]
auth_env  = "GITHUB_TOKEN"
poll_secs = 60

[[github.repos]]
owner = "myorg"
repo  = "knowledge-base"

[gitlab]
auth_env = "GITLAB_TOKEN"
base_url = "https://gitlab.example.com/api/v4"   # for self-hosted

[[gitlab.projects]]
project  = "platform/checkout"     # path or numeric ID
branches = ["main", "production"]

[azdevops]
auth_env = "AZDO_TOKEN"

[[azdevops.projects]]
org     = "my-org"
project = "MyProject"
repo    = "my-repo"
```

`[[<provider>.repos]]` / `[[<provider>.projects]]` entries **append** across config files — a workspace-local file can add repos without re-listing the global set. Tokens are read from `$<auth_env>` at worker start; the value never lands in a config file.

When no repos / projects are configured for a provider, that worker stays idle — the panes just show "no repos configured."

### `[ai]` and `[http]`

The `[ai]` and `[http]` tables are **parsed-and-kept** today: mnml will accept whatever shape your file has and won't error, but consumes them on the AI / HTTP tracks rather than from a single global table. The active surfaces:

- **AI providers** — keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, …) read from the environment at request time, not from config. AI pane preferences (which model, default prompt) live in workspace state, not TOML. See the [AI panes manual](/manual/ai-panes/).
- **HTTP requests** — defined per-file (`.http` / `.curl` / `.rest` / `.chain.json`) under your workspace. Environment selection is a runtime concept (`mnml run FILE --env staging`), not a config key. See the [HTTP client manual](/manual/http/).

A future `[ai] default_model = "..."` / `[http] default_env = "..."` shape is reserved; the current values are tolerated for forward compatibility.

## Workspaces — `[[workspaces]]`

mnml's file-tree rail shows the launched workspace at the top. To pin additional workspaces as collapsible sibling sections in the rail:

```toml
[[workspaces]]
name = "work"
path = "~/Projects/work-stuff"

[[workspaces]]
path = "~/Projects/mnml-family"   # name defaults to "mnml-family" (basename)
```

- `~` is expanded at config-load time.
- `name` defaults to the path's basename when omitted.
- Entries **append** across config files (so a workspace-local file can add siblings).
- Missing directories are tolerated — mnml logs and skips them rather than failing to start.

Each workspace gets its own `Tree`, its own discovered repos, and its own git status reader. Switching between workspace roots is a click in the rail; nothing reloads.

## Resetting

Three levels of reset, smallest to largest:

- **Per-row** — open the overlay, focus the row, press `r`. Just that one setting reverts to its built-in default.
- **All settings (live)** — focus the **Reset all to defaults** sentinel row at the bottom of the overlay and press `Enter` (or `R` anywhere in the overlay). The live `Config` is rewritten to `Config::default()`. The pre-open snapshot is still held, so `Esc` would *un*-revert if you change your mind before pressing `Enter` on a normal row.
- **All settings (on disk)** — delete `~/.config/mnml/config.toml` and `<workspace>/.mnml/config.toml`. mnml falls back to built-in defaults on the next start.

Reset only touches keys the overlay exposes — `[[workspaces]]`, `[[bitbucket.repos]]`, `[keys.*]`, etc. are untouched by **Reset all**.

## Next

- [Editing](/manual/editing/) — the `[editor]` knobs in context
- [LSP](/manual/lsp/) — `[lsp.<name>]` field reference
- [Git](/manual/git/) — what the git-host dashboards do once configured
- [HTTP client](/manual/http/) — request files and environment selection
- [AI panes](/manual/ai-panes/) — Claude Code / Codex integration
