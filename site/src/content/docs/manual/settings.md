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

A few sections (`[[workspaces]]`, `[[ui.launcher_icon]]`, `[[ui.integration_icon]]`, …) have their own merge rules — workspaces *append* across files; launcher-icon and integration-icon arrays *replace*. Those quirks are called out below.

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
| `Enter` | On a discrete-choice row, same as `→`. On a text or color row, enters greedy edit mode (printable keys → buffer, `Backspace` → delete, `Enter` → commit, `Esc` → cancel). On the reset-all sentinel row, fires the global reset |
| `Esc` | While editing a text/color row, cancel the in-progress edit (restore the value the row had on edit-mode entry). Otherwise, cancel the overlay — revert the live config to whatever it was when the overlay opened |

`Enter` (anywhere except the reset row) commits whatever's currently on screen and closes the overlay. The overlay does **not** persist changes to TOML — it writes the in-memory `Config`. If you want a change to survive restarts, also edit the matching TOML key.

### Number rows (v2)

A second row kind has shipped alongside the discrete-choice rows: **number rows**. Where a choice row brackets the active option, a number row brackets the live value with its unit:

```
▸ Scrolloff (rows of context above/below cursor):  [ 4 ]      (0–20 · step 1 · default 0)
  Sidescrolloff (cols of context left/right …):    [ 0 ]      (0–20 · step 1 · default 0)
  File tree width:                                 [ 30 cols ] (16–60 · step 2 · default 30)  *
```

- `←` / `→` step the value by the row's `step`, clamped to `[min, max]`. The hint in dim text — `(min–max · step N · default D)` — tells you what each press will do.
- `r` resets just this row to its built-in default.
- `[ <value><unit> ]` is the live value; the `*` modified marker appears when it differs from the default.

The three first-class number rows today:

| Row | TOML key | Range | Step | Unit | Default |
|---|---|---|---|---|---|
| Scrolloff | `[ui] scrolloff` | 0..=20 | 1 | (none) | 0 |
| Sidescrolloff | `[ui] sidescrolloff` | 0..=20 | 1 | (none) | 0 |
| File tree width | `[ui] tree_width` | 16..=60 | 2 | `cols` | 30 |

### Text rows (v2)

A third row kind has landed: **text rows** for free-form string settings. Press `Enter` on a focused text row to drop into **greedy edit mode** — the row's value becomes a live edit buffer until you commit or cancel:

```
▸ Theme:                            [ "tokyonight-night│" ]  (editing · Enter commit · Esc cancel)
```

- `Enter` on a focused text row enters edit mode (text rows don't cycle on `Enter` the way discrete rows do).
- While editing: printable keys append to the buffer · `Backspace` drops the trailing character · `Enter` commits + exits · `Esc` restores the value the row had when you started editing and exits.
- The value is **live-written** to the in-memory `Config` on every keystroke (via `apply_text_setting`), so the rendered `[ "<buffer>│" ]` and any downstream visuals (e.g. a color swatch on a Color row) reflect the in-progress edit. Cancelling restores the snapshot.
- The `│` is a literal cursor caret painted at the end of the buffer while in edit mode. The bottom-of-overlay hint swaps from the navigation chord list to `(editing · Enter commit · Esc cancel)`.
- `←` / `→` are no-ops on text rows outside of edit mode — there's nothing to step through.
- `r` resets just this row's setting to its built-in default (via `apply_text_setting`).
- `[ "<value>" ]` is the live value; the `*` modified marker appears when it differs from the default.

The one first-class text row today:

| Row | TOML key | Default |
|---|---|---|
| Theme | `[ui] theme` | `tokyonight-night` |

### Color rows (v2)

The fourth row kind: **color rows** for hex-color settings. Same shape as text rows, but the value is a 6-char `RRGGBB` hex string (no leading `#`). The renderer brackets the value, then paints a `████` swatch in the parsed color:

```
▸ Accent:                           [ #61afef ]  ████  (color · default #61afef · TOML to edit)
```

- Invalid hex (wrong length, non-hex chars) falls back to the foreground color for the swatch and appends ` · invalid hex` to the dim hint suffix.
- Same edit-mode shape as text rows: `Enter` enters greedy edit mode, printable keys append, `Backspace` deletes, `Enter` commits, `Esc` cancels + restores. Each keystroke live-writes through `apply_text_setting`, so the swatch repaints in the in-progress color as you type (the parsed-color preview is the whole reason live edit matters for color rows). `r` still resets to the row's default; the `*` modified marker behaves the same way.
- No first-class color rows are wired into `build_settings` yet — the `ColorRow` variant is reserved for future overrides (theme accent picker, status-line color override, etc.). The live-edit machinery is shared with text rows, so adding such a row needs only a `build_settings` entry + an `apply_text_setting` arm — no new overlay code.

### What's in the overlay vs what's TOML-only

The overlay covers **discrete-choice rows** (booleans, input style `vim`/`standard`, tab width `2`/`4`/`8`, line numbers `relative`/`absolute`/`off`, picker position `center`/`top`, now-playing source `auto`/`mixr`/`macos`), **number rows** (scrolloff, sidescrolloff, tree width), **text rows** (theme — with live edit), and **color rows** (live-edit machinery shared with text rows; no first-class entries yet — reserved for future overrides).

Things the overlay does **not** edit:

- Arrays of complex things — `[[workspaces]]`, `[[ui.launcher_icon]]`, `[[ui.integration_icon]]`, `[snippets.<scope>]`, `[tasks.<name>]`, `[formatters.<ext>]`, `[linters.<ext>]`. These stay in TOML.
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
| Scrolloff | `[ui] scrolloff` |
| Sidescrolloff | `[ui] sidescrolloff` |
| Theme | `[ui] theme` |
| File tree width | `[ui] tree_width` |
| Now-playing source | `[ui] now_playing_source` |
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
now_playing_source = "auto"       # "auto" | "mixr" | "macos" — statusline ♪ miniplayer

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
command  = ":host.launch myapp"          # leading `:` ⇒ ex-cmdline;
                                          # `tmnl:<id>` ⇒ tmnl-host command;
                                          # no prefix ⇒ mnml command id
color    = "teal"                        # orange / cyan / blue / green / yellow / purple / red / teal / bg2
tooltip  = "My private blit-host app"    # optional hover text
```

Setting the array **replaces** the built-in defaults — copy the defaults from the source if you want to extend rather than replace.

##### `tmnl:` commands — left-rail chips for tmnl-host capabilities

When mnml is running under [tmnl](/family/tmnl/), `command = "tmnl:<id>"` asks the tmnl renderer to fire one of *its* registered commands by id (rather than a mnml command). The message goes over the blit channel as `Message::RunHostCommand` and tmnl looks the id up in its own registry. Driving use case: tmnl-only capabilities like the Browser pane and the Playwright dashboard — neither lives in mnml, but you may want a one-click chip in mnml's left rail to fire them.

Two ready-made recipes:

```toml
# Playwright dashboard: tmnl spawns `playwright-cli show` with
# PLAYWRIGHT_DASHBOARD_DEBUG_PORT=9222, discovers the dashboard's
# local URL via CDP /json/list, opens it in a Browser pane.
[[ui.integration_icon]]
id       = "playwright_dashboard"
glyph    = "\u{F0668}"                  # nf-md-play_circle
fallback = "▶"
command  = "tmnl:browser.attach_dashboard"
color    = "green"
tooltip  = "Playwright dashboard"

# Browser pane from clipboard URL: tmnl reads the clipboard, opens
# the URL in a new Browser pane next to the focused split.
[[ui.integration_icon]]
id       = "browser_clipboard"
glyph    = "\u{F059F}"                  # nf-md-web
fallback = "B"
command  = "tmnl:split.browser_clipboard"
color    = "blue"
tooltip  = "Browser (clipboard URL)"
```

When mnml is **not** running under tmnl, clicking a `tmnl:` chip toasts an explanation instead of silently failing — the command would have nowhere to land. The chips themselves are still visible (mnml can't know which commands the host registry has), so opt in only if you're running under tmnl most of the time.

#### Update check

```toml
[ui]
check_updates = true              # default — opt out by setting to false
```

On launch, mnml spawns a background thread that does one HTTP GET against `https://api.github.com/repos/chris-mclennan/mnml/releases/latest`. If the response's `tag_name` differs from `CARGO_PKG_VERSION` (the version baked into the running binary), mnml fires a one-shot toast on the next tick — *"v0.1.3 available — github.com/chris-mclennan/mnml/releases/tag/v0.1.3"*.

A few details worth knowing:

- **Background, non-blocking.** The HTTP call runs on a fresh `std::thread`; mnml never waits for it. The editor is usable from the first frame regardless of network state.
- **One toast per session.** An `AtomicBool` flips on first surface, so the toast can't re-fire after you dismiss it.
- **String-equality, not semver.** mnml compares the tag verbatim. A dev build whose `Cargo.toml` runs ahead of the latest tag won't trigger the toast; a build whose version *matches* the tag while having unreleased local changes won't either. False-positives are limited to "tag bumped but the dev version still matches the old tag" — rare in practice.
- **Opt out:** set `[ui] check_updates = false` and the background thread never spawns. No network call, no toast.
- **Skipped automatically in `--headless` and `--blit` modes.** Both modes have no toast surface and no statusline chip, so the check is a no-op there even when `check_updates` is `true`.

Source: `src/update_check.rs` (the background fetch + the shared `UpdateCheck` handle) and `src/main.rs` (the gate that decides whether to spawn it).

#### Now-playing source

```toml
[ui]
now_playing_source = "auto"       # "auto" (default) | "mixr" | "macos"
```

The statusline `♪` miniplayer chip can read from two sources — the sibling [mixr](/family/mixr/) DJ app (via the `~/.mixr/quick.txt` flat file it writes on track changes) and the macOS Music / Spotify apps (via an `osascript` AppleScript poll). `now_playing_source` picks which:

- `"auto"` (default) — try mixr first (a cheap file read), fall back to macOS Music / Spotify when mixr is idle. The "show whatever's actually playing" mode.
- `"mixr"` — only read mixr. Skips the macOS `osascript` poll entirely, which is useful if you don't use Music or Spotify and want to shave the only non-trivial cost off the now-playing poller.
- `"macos"` — only read macOS Music / Spotify. Skips the mixr file read. Useful if you don't run mixr.

The matching row is in the settings overlay under `── UI ──` as **Now-playing source** with options `auto` / `mixr` / `macos`. The chip itself is hidden when nothing is playing — switching sources doesn't toggle visibility, just which player gets queried.

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

### Git-host integrations — moved to `mnml-forge-*` siblings

The in-tree Bitbucket / GitHub / GitLab / Azure DevOps live panes were split out of mnml core in 2026-06 into four standalone sibling binaries — [`mnml-forge-bitbucket`](/manual/integrations/forge-bitbucket/), [`mnml-forge-github`](/manual/integrations/forge-github/), [`mnml-forge-gitlab`](/manual/integrations/forge-gitlab/), [`mnml-forge-azdevops`](/manual/integrations/forge-azdevops/) — each hosted in a regular mnml pane via `:host.launch <binary>`. Each forge sibling reads its own config from `~/.config/mnml-forge-<host>.toml` and its own credentials from `~/.config/mnml-forge-<host>/token`. See the [integration class overview](/manual/integrations/community/) for the model.

Existing `[bitbucket]`, `[github]`, `[gitlab]`, `[azdevops]` sections in your mnml config are **silently ignored** — no error, no warning. You can either delete them or leave them in place; they're noise to mnml now. The new shape lives in each forge sibling's own per-binary config file.

Mnml's default config still seeds four launcher chips in the rail's INTEGRATIONS row (`bitbucket`, `github`, `gitlab`, `azdevops`) that fire `:host.launch mnml-forge-<host>` — install whichever siblings you use and click the chip to open the viewer.

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
