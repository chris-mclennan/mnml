---
title: Config reference (ZON)
description: mnml 0.3.0's config.zon, key by key — the ZON primer, the three-layer merge, workspace trust and which keys are exec-bearing, then every section with each key's type, default and doc comment.
---

mnml 0.3.0 reads its configuration from ZON — Zig's object notation — instead of TOML. This page is the complete reference: a short primer on the syntax, how the three config files layer, what workspace trust strips, and then every section in the order the shipped `config.zon` lists them, one table per section, with each key's type, default and the comment it carries in the file.

Coming from 0.2.x? [Upgrading to 0.3](/manual/upgrading-to-0-3/) covers `mnml export-config-zon`, which writes this file from your `config.toml`. The everyday toggles also have a UI — the [settings overlay](#the-settings-overlay) — so you rarely need to open the file for a bool.

## ZON in five minutes

ZON is a subset of Zig's literal syntax. A config file is one anonymous struct literal:

```zig
.{
    .editor = .{
        .input_style = .vim,
        .tab_width = 2,
    },
    .ui = .{
        .theme = "gruvbox",
        .line_numbers = true,
    },
}
```

The rules you need:

- **Every field starts with a dot** — `.tab_width = 2`, not `tab_width = 2`. Fields are separated by commas; a trailing comma is fine.
- **A nested section is another `.{ … }`**. `.editor = .{ … }`, `.lsp = .{ .rust = .{ … } }`. There is no `[section]` header — nesting is the structure.
- **Enums are enum literals**, written with a leading dot and no quotes: `.input_style = .vim`, `.scroll_accel = .fast`, `.md_preview_engine = .builtin`. `"vim"` (a string) is a type error at its line. Every closed set in the tables below is written this way.
- **Strings are double-quoted**, with Zig escapes: `"\u{EB01}"` for a codepoint, `"fn $1($2) {\n    $0\n}"` for a newline.
- **Lists are `.{ … }` too** — `.extensions = .{ "rs" }`, `.cmd = .{ "zig", "fmt", "--stdin" }`. An empty list is `.{}`.
- **`null`** is the absent value for a key marked `?` in the tables — `.theme_toggle = null`, `.cmd = null`.
- **Integers are bare** — `.tree_width = 30` — and `0xrrggbb` hex works where a theme wants a colour.
- **A key that is not a valid identifier is quoted with `@"…"`.** This is how chords and keywords are written: `.@"ctrl+p" = "picker.files"`, `.@"space f f" = "picker.files"`, `.@"test" = .{ .cmd = "zig build test" }` (`test` and `fn` are Zig keywords). Anything with a space, a `+`, a `-` or a leading digit needs it.
- **Comments are `//` to end of line.** They survive — settings written from the UI splice one value in place and keep every comment and the order of the file.
- **A tagged union is a one-field struct**: `.md_preview_engine = .{ .custom = "glow -s dark" }`, `.{ .crates_keyword = .{ .id = "…", .keyword = "…" } }`. The field name is the tag.

A layer only has to mention what it changes. Every key has a shipped default (`Config{}` in `src/config/Config.zig`; the tests assert them), so a complete, working home config can be three lines.

## The three layers

mnml reads three ZON files, in this order, each layered over the last:

| Layer | Path | Trust |
|---|---|---|
| home | `~/.config/mnml/config.zon` (see [where the home file lives](#where-the-home-file-lives)) | trusted |
| workspace | `<workspace>/.mnml/config.zon` | asked on first open |
| explicit | `--config PATH` | trusted |

**Merge rules.** Scalars, enums and lists replace the value below them. `.keys.*`, `.snippets.<scope>` and `.abbr` extend by key — a workspace can add one chord without restating the home file's. `.lsp.<name>`, `.tasks.<name>`, `.formatters.<ext>`, `.linters.<ext>` and `.dap.<name>` replace per name: the entry is the unit.

**Failure is local.** A syntax error drops that file; a typo inside `.ui` drops `.ui` for that file and `.editor` still applies; a bad `.lsp.rust` drops only `rust`. Every problem is one `file:line:col:` diagnostic in the toast log, never a failed start. Duplicate keys are an error.

### Where the home file lives

1. `$MNML_DATA_ROOT/config.zon` when the variable is set
2. `<binary dir>/mnml-data/config.zon` when that directory exists and contains `.opted-in` (portable mode)
3. `$XDG_CONFIG_HOME/mnml/config.zon` when the variable is set
4. `$HOME/.config/mnml/config.zon`

## Workspace trust

A workspace config is written by whoever owns the repo. Before its exec-bearing keys apply, mnml lists them and asks once:

```
 Trust this workspace?
   proj runs programs from its .mnml/config.zon:
     • language server zig — runs `zls` when you open a file
     • format on save zig — runs `zig fmt` when you save
   Until trusted these settings are ignored; the rest apply.
                                        [T]rust   [D]on't trust
```

*Don't trust* is the focused choice, so a reflexive Enter is the safe answer; the question comes back next launch. *Trust* records a fingerprint of the claims — FNV-1a over each `kind / key / command` line, sorted — in `<data root>/trusted_workspaces.zon`, keyed by the canonical workspace path:

```zig
.{
    .@"/Users/me/proj" = "3f2a9c0e11d4b7a8",
}
```

A later change to any command changes the fingerprint and asks again; ordinary edits to the file do not. A workspace file with no exec-bearing key never asks. Until trusted, these are dropped from the workspace layer and everything else still applies:

| Key | Runs |
|---|---|
| `.ui.external_browser` | when you open a link |
| `.ui.md_preview_engine = .{ .custom = … }` | when you preview markdown |
| `.lsp.<name>.cmd` / `.args` | when you open a file |
| `.formatters.<ext>` | when you save |
| `.linters.<ext>` | when you lint |
| `.dap.<name>` | when you start a debug session |
| `.startup.layout[]` with `.kind = .pty` | immediately, on open |
| `.startup.tasks` | immediately, on open |

`.tasks.<name>` bodies are not in the table: a task only runs when you ask for it by name. A workspace `.mnml/init.lua` is a claim in the same dialog — it simply does not run until the answer is Trust.

The tables below mark each of these keys **exec-bearing**.

## Reading the tables

Each section lists its keys in the order of the shipped `config.zon`. *Type* is the Zig type from `Config.zig` — `bool`, `u8` / `u16` / `u32`, `string`, `[]string` (a list), an enum written as its set of literals, `?T` for a key that takes `null`. *Default* is what you get when the key is absent. *Description* is the comment the key carries in the reference file, verbatim where it has one.

A key marked † is in the schema (`Config.zig`) but not in the sample block of `docs/CONFIG.md`; its description comes from the schema's doc comment instead.

## `.editor`

```zig
.editor = .{
    .input_style = .standard,
    .tab_width = 4,
    .chord_timeout_ms = 500,
    .clipboard = .auto,
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `input_style` | `.vim` \| `.standard` | `.standard` | `.vim` \| `.standard` |
| `tab_width` | `u8` | `4` | Spaces per tab stop. |
| `autosave_secs` | `u32` | `0` | 0 = off |
| `trim_trailing_ws_on_save` | `bool` | `false` | Strip trailing whitespace when a file is saved. |
| `breadcrumb` | `bool` | `true` | Show the file / symbol breadcrumb above the editor. |
| `auto_pair` | `bool` | `true` | Insert the closing bracket / quote with the opening one. |
| `auto_indent` | `bool` | `true` | Carry the previous line's indent onto a new line. |
| `format_on_save` | `bool` | `false` | Run the extension's formatter on save. |
| `will_save_wait_until` | `bool` | `false` | Let the language server edit the buffer before a save. |
| `format_on_type` | `bool` | `false` | Ask the language server to format as you type. |
| `autosave_on_focus_loss` | `bool` | `false` | Save every dirty buffer when the terminal loses focus. |
| `inlay_hints` | `bool` | `true` | Show the language server's inlay hints. |
| `cursor_blink` | `bool` | `false` | Blink the cursor. |
| `semantic_tokens_viewport` | `bool` | `false` | Request semantic tokens for the visible range only. |
| `semantic_tokens` † | `bool` | `true` | Lay a server's semantic tokens over the syntax highlighting. The master switch — off leaves the tree-sitter paint alone. |
| `code_lens` | `bool` | `true` | Show code lenses (run / test / references). |
| `text_width` | `u16` | `80` | Column `gq` wraps at. |
| `ensure_trailing_newline` | `bool` | `true` | Make sure a saved file ends in a newline. |
| `chord_timeout_ms` | `u16` | `500` | vim's timeoutlen; clamped to 100..5000 |
| `wheel_moves_cursor` | `.auto` \| `.always` \| `.never` | `.auto` | `.auto` \| `.always` \| `.never` |
| `scroll_accel` | `.off` \| `.gentle` \| `.normal` \| `.fast` | `.normal` | `.off` \| `.gentle` \| `.normal` \| `.fast` |
| `persistent_undo` † | `bool` | `false` | Keep each file's undo + redo stacks in `<data root>/undo/` across launches. Off by default: a history file per edited file is a surprise for a first launch. |
| `clipboard` | `.auto` \| `.os` \| `.internal` | `.auto` | `.auto` \| `.os` \| `.internal` — what `"+` / `"*` / Ctrl+C reach |

## `.ui`

```zig
.ui = .{
    .theme = "onedark",
    .tree_width = 30,
    .line_numbers = true,
    .picker_position = .center,
    .menu_bar = .always,
    .md_preview_engine = .builtin,
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `theme` | `string` | `"onedark"` | any theme name; an open set |
| `cmdline_popup_border_color` | `string` | `""` | `""` = the theme's |
| `theme_toggle` | `?string` | `null` | a second theme for ui.toggle_theme |
| `theme_auto_system` | `bool` | `false` | Follow the OS light / dark appearance. |
| `ascii_icons` | `bool` | `false` | Plain-text icons — no Nerd Font needed. |
| `tree_width` | `u16` | `30` | clamped to 10..80 |
| `right_panel_visible` | `bool` | `false` | Open the right panel on start. |
| `right_panel_width` | `u16` | `40` | the Rust default is 32; the Zig panels are tuned to 40 |
| `auto_hide_narrow_width` | `u16` | `0` | 0 = never auto-hide the tree |
| `auto_equalize_splits` | `bool` | `false` | Re-balance splits when one opens or closes. |
| `relative_line_numbers` | `bool` | `false` | Line numbers relative to the cursor line. |
| `line_numbers` | `bool` | `true` | Show line numbers. |
| `cursor_line` | `bool` | `false` | Highlight the cursor's line. |
| `scrolloff` | `u16` | `0` | Lines kept above / below the cursor when scrolling. |
| `sidescrolloff` | `u16` | `0` | Columns kept left / right of the cursor when scrolling. |
| `show_whitespace` | `bool` | `false` | Render spaces and tabs visibly. |
| `bracket_rainbow` | `bool` | `false` | Color nested brackets by depth. |
| `tree_preview_on_arrow` | `bool` | `true` | Arrowing through the tree previews the file. |
| `syntax` | `bool` | `true` | Syntax highlighting. |
| `scrollbar` | `bool` | `true` | Show the editor scrollbar. |
| `wheel_lines` | `u8` | `3` | lines per wheel notch |
| `highlight_trailing_ws` | `bool` | `false` | Highlight trailing whitespace. |
| `clock` | `bool` | `true` | Show a clock in the statusline. |
| `stress_meter` | `bool` | `false` | Show the stress meter in the statusline. |
| `check_updates` † | `bool` | `true` | Ask GitHub for the newest release once per launch. |
| `activity_bar_pinned_integrations` | `[]string` | `.{}` | integration ids |
| `plus_menu_pinned` | `[]string` | `.{}` | Command ids pinned to the + menu. |
| `plus_menu_hidden` | `[]string` | `.{}` | Command ids hidden from the + menu. |
| `auto_refresh_off` | `[]string` | `.{}` | panel ids whose auto-refresh is off |
| `sessions_sort` | `.auto` \| `.manual` | `.auto` | `.auto` \| `.manual` |
| `todos_sort` | `.newest` \| `.oldest` \| `.name` \| `.name_desc` | `.newest` | `.newest` \| `.oldest` \| `.name` \| `.name_desc` |
| `notes_sort` | same set | `.newest` | |
| `findings_sort` | same set | `.newest` | |
| `statusline_segment_order` | `[]string` | `.{}` | `.{}` = the built-in order |
| `highlight_word_under_cursor` | `bool` | `false` | Highlight every occurrence of the word under the cursor. |
| `auto_md_preview` | `bool` | `false` | Open a markdown preview beside a markdown file automatically. |
| `color_column` | `u16` | `0` | 0 = off |
| `wrap` | `bool` | `false` | Soft-wrap long lines. |
| `highlight_todo_keywords` | `bool` | `false` | Highlight TODO / FIXME markers in comments. |
| `todo_keywords` † | `[]string` | `.{ "TODO", "FIXME", "XXX", "HACK", "REVIEW" }` | Markers the TODOS panel scans for. A marker must follow a comment opener, or be a markdown list item; the `.fixme(` / `.fail(` / `.skip(` test-marker scan is always on and not listed here. |
| `render_markdown` | `bool` | `false` | Render markdown inline in the editor. |
| `markdown_opens_rendered` | `bool` | `true` | Open markdown files in the rendered view first. |
| `always_show_fold_arrows` | `bool` | `false` | Show fold arrows even where nothing folds. |
| `sticky_context` | `bool` | `false` | Pin the enclosing scope's header at the top of the editor. |
| `md_image_rows` | `u16` | `12` | Rows an inline markdown image takes. |
| `git_graph_branch_col` | `?u16` | `null` | null = auto width |
| `git_graph_author_col` | `?u16` | `null` | null = auto width |
| `git_graph_detail_col` | `?u16` | `null` | null = auto width |
| `picker_position` | `.center` \| `.top` | `.center` | `.center` \| `.top` |
| `integration_icons` | `[]IntegrationIcon` | the three built-ins | The activity-bar icon strip. Omit to keep the three built-ins (browser, claude_code, codex); set it to replace them. See [below](#integration_icons-entries). |
| `integration_icon_order` | `[]string` | `.{}` | ids, left to right |
| `ticket_prefixes` | `[]string` | `.{}` | e.g. `.{ "TE", "OPS" }` |
| `now_playing_source` | `.auto` \| `.mixr` \| `.macos` | `.mixr` | `.auto` \| `.mixr` \| `.macos` — accepted and ignored in 0.3.0 (the now-playing transport is a cut) |
| `now_playing_marquee` | `bool` | `false` | Scroll a long now-playing title. |
| `preferred_music_app` | `.mixr` \| `.music` \| `.spotify` | `.mixr` | `.mixr` \| `.music` \| `.spotify` |
| `mixr_auto_play_on_open` | `bool` | `true` | Start playback when mixr opens. |
| `projects_dir` | `string` | `""` | `"~/code"`; ~ is expanded |
| `menu_bar` | `.always` \| `.auto` \| `.hidden` | `.always` | `.always` \| `.auto` \| `.hidden` |
| `bufferline_diag_style` | `.count` \| `.dot` \| `.off` | `.count` | `.count` \| `.dot` \| `.off` |
| `coverage_chip_mode` | `.both` \| `.feature` \| `.code` \| `.ticker` | `.feature` | The coverage chip reads `.tattle-claude-artifacts` under `MNML_ARTIFACTS_HOME` when that is set, else your home directory. |
| `expand_indicator` | `.chevron` \| `.triangle` | `.chevron` | `.chevron` \| `.triangle` |
| `hover_help_height` | `u16` | `8` | clamped to 3..20 |
| `terminal_label` | `string` | `"terminal"` | Label for terminal tabs. |
| `external_browser` | `string` | `""` | a program to spawn; `""` = the OS default **(exec-bearing)** |
| `terminal_glyph_svg` | `string` | `""` | SVG baked into the terminal tab glyph. |
| `top_bar_cluster_mode` | `.auto` \| `.expanded` \| `.compact` | `.auto` | `.auto` \| `.expanded` \| `.compact` |
| `tab_bar_ai_icon` | `.none` \| `.claude_code` \| `.codex` \| `.both` | `.claude_code` | `.none` \| `.claude_code` \| `.codex` \| `.both` |
| `ai_layout_mode` | `.grid` \| `.tabs` | `.grid` | `.grid` \| `.tabs` |
| `ai_chip_use_mnml_glyphs` | `bool` | `false` | Use mnml's own baked glyphs for the AI chips. |
| `auto_show_sessions_on_ai_activate` | `bool` | `true` | Open the SESSIONS panel when an AI session starts. |
| `git_section_default_expanded` | `bool` | `false` | Start with the rail's GIT section expanded. |
| `integrations_section_default_expanded` | `bool` | `false` | Start with the rail's INTEGRATIONS section expanded. |
| `hover_help` | `bool` | `true` | The bottom-left hover-help strip. |
| `hover_tooltip` | `bool` | `false` | A small popup near the pointer after a hover-hold. |
| `click_echo` | `bool` | `false` | Underline a clicked target for 120 ms. |
| `first_launch_complete` | `bool` | `false` | set by the first-launch flow |
| `show_workspace_dots` | `bool` | `true` | ● / ○ markers on workspace-root rows. |
| `md_preview_engine` | `.builtin` \| `.glow` \| `.pandoc` \| `.{ .custom = "cmd" }` | `.builtin` | `.builtin` \| `.glow` \| `.pandoc` \| `.{ .custom = "cmd" }` **(exec-bearing when `.custom`)** |

### `integration_icons` entries

Omit `.integration_icons` to keep the three built-ins (`browser`, `claude_code`, `codex`); set it to replace them. Each entry:

```zig
.integration_icons = .{
    .{
        .id = "browser",
        .glyph = "\u{EB01}",
        .fallback = "B",
        .command = "browser.open",
        .color = "blue",
        .label = "Browser",
        .enabled = true,
        .in_palette_bar = true,
        .description = null,
        .homepage = null,
        .docs = null,
        .repository = null,
        .author = null,
        .version = null,
        .commands = .{}, // .{ .{ .id = "x.y", .title = "…" } }
    },
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `id` | `string` | `""` | Integration id. |
| `glyph` | `string` | `""` | Nerd Font glyph. |
| `fallback` | `string` | `""` | Plain-text stand-in for --ascii. |
| `command` | `string` | `""` | Command id the click fires. |
| `color` | `string` | `""` | Chip color. |
| `label` | `?string` | `null` | Label shown beside the chip. |
| `enabled` | `bool` | `true` | Show the chip. |
| `in_palette_bar` | `bool` | `true` | Also show it in the palette bar. |
| `description` | `?string` | `null` | One line for the Installed tab. |
| `homepage` | `?string` | `null` | Project homepage. |
| `docs` | `?string` | `null` | Documentation URL. |
| `repository` | `?string` | `null` | Source repository. |
| `author` | `?string` | `null` | Author. |
| `version` | `?string` | `null` | Version string. |
| `commands` | `[]{ id, title }` | `.{}` | `.{ .{ .id = "x.y", .title = "…" } }` — Command id, Palette title. |

## `.session` and `.ipc`

```zig
.session = .{ .restore = true },
.ipc = .{ .write_screen = false },
```

| Key | Type | Default | Description |
|---|---|---|---|
| `session.restore` | `bool` | `true` | Restore the last session's panes on open. |
| `ipc.write_screen` | `bool` | `false` | also dump screen.txt every frame |

## `.keys`

One line per binding: chord → command id. `""` / `"none"` / `"unbound"` removes a default. `.global` applies to both profiles; `.vim` and `.standard` on top of it. ZonGen rejects a chord written twice.

```zig
.keys = .{
    .global = .{
        .@"ctrl+p" = "picker.files",
        .@"ctrl+shift+p" = "none",
    },
    .vim = .{
        .@"space f f" = "picker.files",
        .@"g d" = "lsp.definition",
    },
    .standard = .{
        .@"ctrl+b" = "tree.toggle",
    },
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `global` | map: chord → command id | `.{}` | Bindings for both profiles. |
| `vim` | map: chord → command id | `.{}` | Bindings on top of .global in the vim profile. |
| `standard` | map: chord → command id | `.{}` | Bindings on top of .global in the standard profile. |

Chords are mnml's key grammar — `ctrl+p`, `ctrl+shift+p`, `space f f` (a chain), `g d`, `<C-p>` — and every chord is an `@"…"` key because of the `+` and the spaces. The three maps extend by key across layers, so a workspace file can add one chord. Which defaults each profile carries, and the rules that split them, is in [Upgrading to 0.3 → Keymap profiles](/manual/upgrading-to-0-3/#keymap-profiles).

## `.lsp`

One entry per server. `.cmd` / `.args` are exec-bearing (stripped from an untrusted workspace; `.extensions` etc. still apply). `.settings` and `.initialization_options` are forwarded verbatim as JSON.

```zig
.lsp = .{
    .rust = .{
        .cmd = "rust-analyzer", // null = mnml's built-in default
        .args = .{},
        .extensions = .{ "rs" },
        .root_markers = .{ "Cargo.toml" },
        .settings = .{ .cargo = .{ .allFeatures = true } },
        .initialization_options = .{},
    },
},
```

| Key (per `.lsp.<name>`) | Type | Default | Description |
|---|---|---|---|
| `cmd` | `?string` | `null` | null = mnml's built-in default **(exec-bearing)** |
| `args` | `[]string` | `.{}` | Arguments for .cmd **(exec-bearing)**. |
| `extensions` | `[]string` | `.{}` | File extensions this server handles. |
| `root_markers` | `[]string` | `.{}` | Files that mark a project root. |
| `settings` | any ZON value | `.{}` | Forwarded verbatim as workspace/didChangeConfiguration. |
| `initialization_options` | any ZON value | `.{}` | Forwarded verbatim as initialize.initializationOptions. |

Entries replace per name across layers: a workspace `.lsp.rust` is the whole `rust` entry, not a patch to the home one.

## `.ai`

```zig
.ai = .{
    .backend = null, // legacy; .auto | .api | .sub | .off
    .routing = .{
        .claude = .{ .backend = null }, // wins over .backend
        .codex = .{ .backend = null },
    },
    .inline_suggestions = true,
    .claude_show_all_accounts = false,
    .claude_meter_mode = .compact, // .off | .compact | .ticker
    // Any other key is kept verbatim for the AI subsystems, e.g.:
    .claude_accounts = .{
        .{ .name = "work", .token_path = "~/.claude/work.json", .active = true },
    },
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `backend` | `?` `.auto` \| `.api` \| `.sub` \| `.off` | `null` | legacy; `.auto` \| `.api` \| `.sub` \| `.off` |
| `routing.claude.backend` | `?` `.auto` \| `.api` \| `.sub` \| `.off` | `null` | wins over .backend |
| `routing.codex.backend` | `?` `.auto` \| `.api` \| `.sub` \| `.off` | `null` | wins over .backend |
| `launch_profiles` † | `[]LaunchProfile` | `.{}` | Named ways to start claude / codex; the chip's right-click lists them. Fields: `name` (string), `product` (`.claude` \| `.codex`), `binary` (an executable path or a name on PATH), `args` (`[]string`), `env` (`[]string`, `KEY=VALUE` lines exported by the shim), `cwd_mode` (`.workspace` \| `.home` \| `.file_dir`). |
| `default_profile.claude` † | `?string` | `null` | null = the built-in. |
| `default_profile.codex` † | `?string` | `null` | null = the built-in. |
| `inline_suggestions` | `bool` | `true` | Inline AI completions in the editor. |
| `claude_show_all_accounts` | `bool` | `false` | Show every Claude account on the statusline chip. |
| `claude_meter_mode` | `.off` \| `.compact` \| `.ticker` | `.compact` | `.off` \| `.compact` \| `.ticker` |
| *anything else* | any ZON value | — | Any other key is kept verbatim for the AI subsystems (`.claude_accounts` in the sample). |

## `.tools`

```zig
.tools = .{},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `tools` | any ZON value | `.{}` | Forwarded verbatim to integrations; mnml reads nothing here. |

## `.http` and `.ws`

```zig
.http = .{
    .default_env = null,
    .collection_root = .hidden,
    .auto_format_body = true,
    .sync_normalize = false,
},
.ws = .{
    .subprotocols = .{},
    .ping_interval_secs = 30,
    .reconnect_max_attempts = 3,
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `http.default_env` | `?string` | `null` | name of the env in .env files |
| `http.collection_root` | `.hidden` \| `.workspace` | `.hidden` | `.hidden` (.rqst/)` \| .workspace` |
| `http.auto_format_body` | `bool` | `true` | Pretty-print a response body. |
| `http.sync_normalize` | `bool` | `false` | Normalize request files on sync. |
| `ws.subprotocols` | `[]string` | `.{}` | Sec-WebSocket-Protocol values offered on connect. |
| `ws.ping_interval_secs` | `u32` | `30` | Seconds between keep-alive pings. |
| `ws.reconnect_max_attempts` | `u32` | `3` | Reconnect attempts before giving up. |

## `.sonos`

Accepted and ignored in 0.3.0 — the Sonos / now-playing transport is one of the [cuts](/manual/upgrading-to-0-3/#what-was-cut-and-what-to-do-instead). The keys stay in the schema so a converted 0.2.x file still loads clean.

```zig
.sonos = .{
    .enabled = true,
    .host = null, // null = discover
    .room = null,
    .poll_secs = 3,
    .chip_label = .never, // .never | .hover | .always
    .prefer_airplay = true,
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `true` | Look for a Sonos system. |
| `host` | `?string` | `null` | null = discover |
| `room` | `?string` | `null` | Room to control; null = the first found. |
| `poll_secs` | `u32` | `3` | Seconds between now-playing polls. |
| `chip_label` | `.never` \| `.hover` \| `.always` | `.never` | `.never` \| `.hover` \| `.always` |
| `prefer_airplay` | `bool` | `true` | Prefer the AirPlay route when both are available. |

## `.git_graph`

```zig
.git_graph = .{ .lane_spacing = 1 },
```

| Key | Type | Default | Description |
|---|---|---|---|
| `lane_spacing` | `u16` | `1` | Columns between graph lanes. |

## `.tasks` and `.startup`

```zig
.tasks = .{
    .build = .{ .cmd = "zig build", .cwd = null },
    .@"test" = .{ .cmd = "zig build test" }, // keywords need @"…"
},
.startup = .{
    .tasks = .{ "build" }, // task names to run on open (exec-bearing)
    // Panes to open. The first entry needs no .split; every later one
    // does. .kind = .pty runs .cmd under $SHELL -c (exec-bearing).
    .layout = .{
        .{ .kind = .editor, .path = "README.md" },
        .{ .kind = .pty, .cmd = "zig build --watch", .split = .right, .ratio = 40 },
    },
    .default_workspace = null, // "~/code/mnml"; ~ is expanded
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `tasks.<name>.cmd` | `string` | `""` | Shell command, run under $SHELL -c. |
| `tasks.<name>.cwd` | `?string` | `null` | Working directory; null = the workspace. |
| `startup.tasks` | `[]string` | `.{}` | task names to run on open **(exec-bearing)** |
| `startup.layout` | `[]LayoutEntry` | `.{}` | Panes to open. The first entry needs no .split; every later one does. .kind = .pty runs .cmd under $SHELL -c **(exec-bearing)**. |
| `startup.layout[].kind` | `.editor` \| `.pty` | `.editor` | `.editor` \| `.pty` |
| `startup.layout[].path` | `?string` | `null` | `.editor` — the file to open |
| `startup.layout[].cmd` | `?string` | `null` | `.pty` — the command to run |
| `startup.layout[].split` | `?(.right` \| `.down)` | `null` | `.right` \| `.down`; required after the first entry |
| `startup.layout[].ratio` | `?u8` | `null` | percent of the parent, 1..99 |
| `startup.default_workspace` | `?string` | `null` | `"~/code/mnml"`; ~ is expanded |

A task runs from `task.run`, `task.<name>`, `:task <name>` — or on open when `.startup.tasks` names it. `.tasks.<name>` entries replace per name across layers.

## `.snippets` and `.abbr`

```zig
.snippets = .{
    .rust = .{
        .@"fn" = "fn $1($2) {\n    $0\n}",
    },
    .zig = .{
        .@"test" = "test \"$1\" {\n    $0\n}",
    },
},
.abbr = .{
    .teh = "the",
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `snippets.<scope>` | map: trigger → body | `.{}` | Scope: a language name, or `all`. |
| `snippets.<scope>.<trigger>` | `string` | — | Body; $1 … are tab stops, $0 the final cursor. |
| `abbr.<typed>` | `string` | — | Typed abbreviation → expansion. |

Both extend by key across layers. A trigger that is a Zig keyword (`fn`, `test`, `if`, …) needs the `@"…"` quoting.

## `.formatters` and `.linters`

Both exec-bearing.

```zig
.formatters = .{
    .rs = .{ .cmd = .{ "rustfmt", "--edition", "2024" } },
    .zig = .{ .cmd = .{ "zig", "fmt", "--stdin" } },
},
.linters = .{
    .sh = .{ .cmd = .{ "shellcheck", "-f", "gcc" }, .parser = .shellcheck },
    // .parser: .vimgrep (default, path:line:col: msg) | .eslint | .tsc | .ruff | .shellcheck
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `formatters.<ext>.cmd` | `[]string` | `.{}` | argv; `{file}` becomes the workspace-relative path **(exec-bearing)** |
| `formatters.<ext>.in_place` † | `bool` | `false` | The tool rewrites `{file}` on disk instead of printing to stdout. For a tool that insists on rewriting the file (`rustfmt`, `gofmt -w`): the buffer is written, the tool runs on `{file}`, and the result is read back. |
| `linters.<ext>.cmd` | `[]string` | `.{}` | argv; `{file}` becomes the workspace-relative path **(exec-bearing)** |
| `linters.<ext>.parser` | `.vimgrep` \| `.eslint` \| `.tsc` \| `.ruff` \| `.shellcheck` \| `.pattern` | `.vimgrep` | `.vimgrep` (default, path:line:col: msg) \| `.eslint` \| `.tsc` \| `.ruff` \| `.shellcheck` \| `.pattern` |
| `linters.<ext>.pattern` † | `string` | `""` | The line template for parser = .pattern — placeholders matched literally between them, e.g. `{file}:{line}:{col}: {severity}: {message}`. |

`cmd` is always a list. The 0.2.x string form (`cmd = "rustfmt --edition 2024"`) is what `export-config-zon` splits for you.

## `.dap`

Exec-bearing.

```zig
.dap = .{
    .lldb = .{
        .cmd = "lldb-dap",
        .args = .{},
        .launch = .{ .program = "${workspaceFolder}/zig-out/bin/mnml-zig" }, // verbatim
    },
},
```

| Key (per `.dap.<name>`) | Type | Default | Description |
|---|---|---|---|
| `cmd` | `string` | `""` | The adapter binary **(exec-bearing)**. |
| `args` | `[]string` | `.{}` | Arguments for .cmd. |
| `launch` | any ZON value | `.{}` | verbatim — the launch request arguments |

## `.browser`, `.ci` and `.integrations`

```zig
.browser = .{
    .headless = false,
    .autocapture_to_log = true,
    .profile_mode = .workspace, // .workspace | .shared | .ephemeral
},
.ci = .{
    .provider = null, // "codebuild" …
    .project = null,
    .region = null,
},
.integrations = .{
    .auto_update_cargo = false,
    .auto_update_git = false,
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `browser.headless` | `bool` | `false` | Launch Chrome without a window. |
| `browser.autocapture_to_log` | `bool` | `true` | Record captured traffic into the log. |
| `browser.profile_mode` | `.workspace` \| `.shared` \| `.ephemeral` | `.workspace` | `.workspace` \| `.shared` \| `.ephemeral` |
| `ci.provider` | `?string` | `null` | `"codebuild"` … |
| `ci.project` | `?string` | `null` | CI project name. |
| `ci.region` | `?string` | `null` | Provider region. |
| `integrations.auto_update_cargo` | `bool` | `false` | Auto-update cargo-installed integrations. |
| `integrations.auto_update_git` | `bool` | `false` | Auto-update git-installed integrations. |

## `.workspaces`

```zig
.workspaces = .{
    .{ .name = "mnml", .path = "~/Projects/mnml", .group = "personal" },
},
```

| Key (per entry) | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | `""` | Display name. |
| `path` | `string` | `""` | Root directory; ~ is expanded. |
| `group` | `?string` | `null` | Picker group label. |

The list is what the [workspace picker](/manual/workspaces/) offers. As a list it replaces whole across layers.

## `.marketplace`

```zig
.marketplace = .{
    .enabled = true,
    .cache_ttl_secs = 3600,
    .use_defaults = true, // prepend mnml's own sources
    .sources = .{
        .{ .crates_keyword = .{ .id = "crates.io", .keyword = "mnml-integration" } },
        .{ .github_launcher_folder = .{ .id = "me/launchers", .repo = "me/launchers", .path = "launchers" } },
        .{ .github_monorepo_apps = .{ .id = "me/apps", .repo = "me/mono", .apps_dir = "apps" } },
    },
    .show_dev_tab = false,
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `true` | Show the marketplace. |
| `cache_ttl_secs` | `u32` | `3600` | Seconds the catalog is cached. |
| `use_defaults` | `bool` | `true` | prepend mnml's own sources |
| `sources` | `[]MarketplaceSource` | `.{}` | Extra catalog sources — a tagged union per entry. |
| `sources[].crates_keyword` | `{ id, keyword }` | | Source id; crates.io keyword to list. |
| `sources[].github_launcher_folder` | `{ id, repo, path }` | | Source id; owner/repo on GitHub; Folder of launcher manifests in the repo. |
| `sources[].github_monorepo_apps` | `{ id, repo, apps_dir }` | | Source id; owner/repo on GitHub; Directory whose sub-directories are integration crates. |
| `show_dev_tab` | `bool` | `false` | Show the Dev tab. |

Each source is a tagged union — the one field name inside the entry is the tag. In 0.3.0 a `crates_keyword` source is accepted and lists nothing: the Rust integrations it would find do not run on the Zig host (see [Integrations](/manual/upgrading-to-0-3/#integrations)).

## `.cloud_run`, `.jira` and `.cloud_agents`

```zig
.cloud_run = .{
    .defaults = .{ .agent_id = "", .env_id = "", .sandbox = "", .model = "" },
},
.jira = .{
    .domain = "", // MNML_JIRA_DOMAIN overrides
    .ticket_prefix = "", // MNML_JIRA_TICKET_PREFIX overrides
},
.cloud_agents = .{
    .label = "",
    .short_id = "",
    .region = "", // MNML_CLOUD_AGENTS_REGION overrides
    .account_id = "",
    .runs_table = "",
    .cluster = "",
    .task_definition = "",
    .sg_export_name = "",
    .log_group = "",
    .aws_profile_fallback = "", // MNML_AWS_PROFILE overrides
    .s3_artifacts_bucket = "",
    .default_workspace_label = "", // "" reads as "cloud"
    .managed_agents_enabled = false,
},
```

| Key | Type | Default | Description |
|---|---|---|---|
| `cloud_run.defaults.agent_id` | `string` | `""` | Agent id. |
| `cloud_run.defaults.env_id` | `string` | `""` | Environment id. |
| `cloud_run.defaults.sandbox` | `string` | `""` | Sandbox name. |
| `cloud_run.defaults.model` | `string` | `""` | Model id. |
| `jira.domain` | `string` | `""` | MNML_JIRA_DOMAIN overrides |
| `jira.ticket_prefix` | `string` | `""` | MNML_JIRA_TICKET_PREFIX overrides |
| `cloud_agents.label` | `string` | `""` | Label for the cloud agents section. |
| `cloud_agents.short_id` | `string` | `""` | Short id shown on chips. |
| `cloud_agents.region` | `string` | `""` | MNML_CLOUD_AGENTS_REGION overrides |
| `cloud_agents.account_id` | `string` | `""` | AWS account id. |
| `cloud_agents.runs_table` | `string` | `""` | DynamoDB table of runs. |
| `cloud_agents.cluster` | `string` | `""` | ECS cluster. |
| `cloud_agents.task_definition` | `string` | `""` | ECS task definition. |
| `cloud_agents.sg_export_name` | `string` | `""` | CloudFormation export of the security group. |
| `cloud_agents.log_group` | `string` | `""` | CloudWatch log group. |
| `cloud_agents.aws_profile_fallback` | `string` | `""` | MNML_AWS_PROFILE overrides |
| `cloud_agents.s3_artifacts_bucket` | `string` | `""` | S3 bucket for run artifacts. |
| `cloud_agents.default_workspace_label` | `string` | `""` | `""` reads as `"cloud"` |
| `cloud_agents.managed_agents_enabled` | `bool` | `false` | Enable the managed-agents flow. |

The runner these configure is described in [Cloud agents runner (ECS)](/manual/cloud-agents-config/).

## Changing values at runtime

### `:set`

Every discrete key — every `bool` and every enum in the tables above, outside the map sections (`lsp`, `tasks`, `snippets`, `abbr`, `formatters`, `linters`, `dap`, `tools`, `keys`, `workspaces`) — is reachable from the cmdline by its dotted path, or by its bare field name when exactly one section has it:

```vim
:set ui.line_numbers          " on
:set noline_numbers           " off
:set line_numbers!            " toggle (also :set invline_numbers)
:set line_numbers?            " ask — toasts ui.line_numbers=on
:set scroll_accel=fast        " an enum, by value
:set theme=gruvbox
:set input=vim                " the input style
```

A bare name that two sections share is refused with `"<name>" is in more than one section; use section.<name>`. The vim spellings work ahead of the table — `nu` / `number`, `rnu` / `relativenumber`, `list`, `cul` / `cursorline`, `ai` / `autoindent`, `wrap` — and `Tab` completes option names (dotted paths, bare names and the vim spellings) and, after `=`, the values the option takes.

`:set` applies in memory. Writing a value to disk is the overlay's job.

### The settings overlay

`view.settings`, `:settings` or `Ctrl+,` opens the sectioned list — `── UI ──`, `── Editor ──`, `── Integrations ──`, `── Reset ──` — one row per discrete-choice key:

```
 ▸ Line numbers:      off / [on]
   TODOS sort:        [newest] / oldest / name / name_desc
   Theme:             [onedark] ‹ 62/94 ›
   Input style:       vim / [standard]  *
```

`▸` marks focus, `[brackets]` the current choice, a trailing `*` a value that is not the shipped default. `←→` / `h l` adjust, `↑↓` / `j k` move, `r` resets the row, `R` everything, `Enter` (or a click outside) keeps and closes, `Esc` cancels.

**The file follows the row.** Adjusting a row applies at once and writes the value to the row's file, so what you see is what is on disk. Which file depends on the row: a per-project view setting (line numbers, wrap, format on save, …) goes to the workspace's `.mnml/config.zon`; a preference (theme, input style, ASCII icons, AI, …) goes to the home config. The title names the focused row's file. `Esc` puts back the config, the input style, the theme, and the exact bytes of every file written since the overlay opened — a file that did not exist is removed again.

Rows are discrete choices only (bools, enums, the theme); numbers and text (`tree_width`, `projects_dir`, …) are file edits.

### How a write lands

Settings screens and toggles write back with `persistScalar`: the file is parsed, the one value's bytes are replaced in place, and comments and order survive. A missing key is added at its section's indent; a missing section is appended. An unchanged value is not written. Before every write the previous file is copied to `backups/config.<YYYY-MM-DD-HHMMSS>.zon` next to it, keeping the newest 50.

## Themes

`.ui.theme` names one of the bundled themes — every `themes/*.zon`, the 94 NvChad palettes, matched case-insensitively (`"OneDark"` is `onedark`). `theme.pick` / `:theme` opens a picker that previews as you move and writes the pick to the home config on Enter; `:theme <name>` and `:set theme=<name>` pick directly. `theme.toggle` flips to `.ui.theme_toggle`, or to the first bundled theme of the other kind when it is unset; `theme.reset` returns to `.ui.theme`; `theme.auto_system` follows the OS appearance (checked every 15 s) and `theme.auto_system_off` freezes it. Only a pick writes the file.

A theme file is the palette as NvChad ships it, `0xrrggbb` values:

```zig
.{
    .name = "onedark",
    .kind = .dark, // .dark | .light
    .base_30 = .{ .white = 0xabb2bf, .black = 0x1e222a, /* … */ },
    .base_16 = .{ .base00 = 0x1e222a, /* … base0F */ },
}
```

Every UI role derives from it at build time with the same fallback chains 0.2.x used (`one_bg2 → one_bg → black`, `light_grey → grey_fg2 → grey_fg → grey → white`, `cyan → blue`, …); a missing `base_16` slot takes onedark's. A malformed theme fails the build, not the launch.

## First launch

`.ui.first_launch_complete` gates the setup wizard: while it is false the terminal loop opens it on start (after the trust dialog, if any). Enter writes only what was touched — `editor.input_style`, `ui.ascii_icons`, `ai.routing.<product>.backend`, `ai.inline_suggestions` — plus `first_launch_complete = true`, to the home config. Esc writes nothing and asks again next launch; `first_launch.show` reopens it any time.

## Next

- [Upgrading to 0.3](/manual/upgrading-to-0-3/) — `mnml export-config-zon`, the shape changes, the `// unmigrated:` block
- [Settings & configuration](/manual/settings/) — the 0.2.x TOML reference, kept for anyone pinned there
- [First-launch wizard](/manual/first-launch/)
- [Security & hardening](/manual/security/) — workspace trust in depth
- [LSP](/manual/lsp/) and [Git](/manual/git/) — what `.lsp` and `.git_graph` drive
