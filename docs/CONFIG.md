# mnml config — `config.zon`

mnml reads three ZON files, in this order, each layered over the last:

| layer | path | trust |
|---|---|---|
| home | `~/.config/mnml/config.zon` (see *Where the home file lives*) | trusted |
| workspace | `<workspace>/.mnml/config.zon` | asked on first open |
| explicit | `--config PATH` | trusted |

A layer only has to mention what it changes. Every key has a shipped
default (`Config{}` in `src/config/Config.zig`); the tests assert them.

**Merge rules.** Scalars, enums, and lists replace the value below them.
`.keys.*`, `.snippets.<scope>`, and `.abbr` extend by key — a workspace
can add one chord without restating the home file's. `.lsp.<name>`,
`.tasks.<name>`, `.formatters.<ext>`, `.linters.<ext>`, and `.dap.<name>`
replace per name: the entry is the unit.

**Failure is local.** A syntax error drops that file; a typo inside `.ui`
drops `.ui` for that file and `.editor` still applies; a bad `.lsp.rust`
drops only `rust`. Every problem is one `file:line:col:` diagnostic in
the toast log, never a failed start. Duplicate keys are an error.

**Enums are enum literals.** `.input_style = .vim`, not `"vim"`. A value
that is not in the set is a type error at its line.

## The complete file

Every section and every key, at its default unless the comment says
otherwise. Copy what you need; leave the rest out.

```zon
.{
    // ── editor ─────────────────────────────────────────────────────────
    .editor = .{
        .input_style = .standard, // .vim | .standard
        .tab_width = 4,
        .autosave_secs = 0, // 0 = off
        .trim_trailing_ws_on_save = false,
        .breadcrumb = true,
        .auto_pair = true,
        .auto_indent = true,
        .format_on_save = false,
        .will_save_wait_until = false,
        .format_on_type = false,
        .autosave_on_focus_loss = false,
        .inlay_hints = true,
        .cursor_blink = false,
        .semantic_tokens_viewport = false,
        .code_lens = true,
        .text_width = 80,
        .ensure_trailing_newline = true,
        .chord_timeout_ms = 500, // vim's timeoutlen; clamped to 100..5000
        .wheel_moves_cursor = .auto, // .auto | .always | .never
        .scroll_accel = .normal, // .off | .gentle | .normal | .fast
    },

    // ── ui ─────────────────────────────────────────────────────────────
    .ui = .{
        .theme = "onedark", // any theme name; an open set
        .cmdline_popup_border_color = "", // "" = the theme's
        .theme_toggle = null, // a second theme for ui.toggle_theme
        .theme_auto_system = false,
        .ascii_icons = false,
        .tree_width = 30, // clamped to 10..80
        .right_panel_visible = false,
        .right_panel_width = 32,
        .auto_hide_narrow_width = 0, // 0 = never auto-hide the tree
        .auto_equalize_splits = false,
        .relative_line_numbers = false,
        .line_numbers = true,
        .cursor_line = false,
        .scrolloff = 0,
        .sidescrolloff = 0,
        .show_whitespace = false,
        .bracket_rainbow = false,
        .tree_preview_on_arrow = true,
        .syntax = true,
        .scrollbar = true,
        .wheel_lines = 3, // lines per wheel notch
        .highlight_trailing_ws = false,
        .clock = true,
        .stress_meter = false,
        .activity_bar_pinned_integrations = .{}, // integration ids
        .plus_menu_pinned = .{},
        .plus_menu_hidden = .{},
        .auto_refresh_off = .{}, // panel ids whose auto-refresh is off
        .sessions_sort = .auto, // .auto | .manual
        .todos_sort = .newest, // .newest | .oldest | .name | .name_desc
        .notes_sort = .newest,
        .findings_sort = .newest,
        .statusline_segment_order = .{}, // .{} = the built-in order
        .highlight_word_under_cursor = false,
        .auto_md_preview = false,
        .color_column = 0, // 0 = off
        .wrap = false,
        .highlight_todo_keywords = false,
        .render_markdown = false,
        .markdown_opens_rendered = true,
        .always_show_fold_arrows = false,
        .sticky_context = false,
        .md_image_rows = 12,
        .git_graph_branch_col = null, // null = auto width
        .git_graph_author_col = null,
        .git_graph_detail_col = null,
        .picker_position = .center, // .center | .top
        // The activity-bar icon strip. Omit to keep the three built-ins
        // (browser, claude_code, codex); set it to replace them.
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
        .integration_icon_order = .{}, // ids, left to right
        .ticket_prefixes = .{}, // e.g. .{ "TE", "OPS" }
        .now_playing_source = .mixr, // .auto | .mixr | .macos
        .now_playing_marquee = false,
        .preferred_music_app = .mixr, // .mixr | .music | .spotify
        .mixr_auto_play_on_open = true,
        .projects_dir = "", // "~/code"; ~ is expanded
        .menu_bar = .always, // .always | .auto | .hidden
        .bufferline_diag_style = .count, // .count | .dot | .off
        .coverage_chip_mode = .feature, // .both | .feature | .code | .ticker
        .expand_indicator = .chevron, // .chevron | .triangle
        .hover_help_height = 8, // clamped to 3..20
        .terminal_label = "terminal",
        .external_browser = "", // a program to spawn; "" = the OS default (exec-bearing)
        .terminal_glyph_svg = "",
        .top_bar_cluster_mode = .auto, // .auto | .expanded | .compact
        .tab_bar_ai_icon = .claude_code, // .none | .claude_code | .codex | .both
        .ai_layout_mode = .grid, // .grid | .tabs
        .ai_chip_use_mnml_glyphs = false,
        .auto_show_sessions_on_ai_activate = true,
        .git_section_default_expanded = false,
        .integrations_section_default_expanded = false,
        .hover_help = true,
        .hover_tooltip = false,
        .click_echo = false,
        .first_launch_complete = false, // set by the first-launch flow
        .show_workspace_dots = true,
        // .builtin | .glow | .pandoc | .{ .custom = "cmd" } (exec-bearing)
        .md_preview_engine = .builtin,
    },

    // ── session / ipc ──────────────────────────────────────────────────
    .session = .{ .restore = true },
    .ipc = .{ .write_screen = false }, // also dump screen.txt every frame

    // ── keys ───────────────────────────────────────────────────────────
    // One line per binding: chord → command id. "" / "none" / "unbound"
    // removes a default. .global applies to both profiles; .vim and
    // .standard on top of it. ZonGen rejects a chord written twice.
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

    // ── lsp ────────────────────────────────────────────────────────────
    // One entry per server. .cmd/.args are exec-bearing (stripped from an
    // untrusted workspace; .extensions etc. still apply). .settings and
    // .initialization_options are forwarded verbatim as JSON.
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

    // ── ai ─────────────────────────────────────────────────────────────
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

    // ── tools ──────────────────────────────────────────────────────────
    // Forwarded verbatim to integrations; mnml reads nothing here.
    .tools = .{},

    // ── http / ws ──────────────────────────────────────────────────────
    .http = .{
        .default_env = null, // name of the env in .env files
        .collection_root = .hidden, // .hidden (.rqst/) | .workspace
        .auto_format_body = true,
        .sync_normalize = false,
    },
    .ws = .{
        .subprotocols = .{},
        .ping_interval_secs = 30,
        .reconnect_max_attempts = 3,
    },

    // ── sonos ──────────────────────────────────────────────────────────
    .sonos = .{
        .enabled = true,
        .host = null, // null = discover
        .room = null,
        .poll_secs = 3,
        .chip_label = .never, // .never | .hover | .always
        .prefer_airplay = true,
    },

    // ── git_graph ──────────────────────────────────────────────────────
    .git_graph = .{ .lane_spacing = 1 },

    // ── tasks / startup ────────────────────────────────────────────────
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

    // ── snippets / abbr ────────────────────────────────────────────────
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

    // ── formatters / linters (exec-bearing) ────────────────────────────
    .formatters = .{
        .rs = .{ .cmd = .{ "rustfmt", "--edition", "2024" } },
        .zig = .{ .cmd = .{ "zig", "fmt", "--stdin" } },
    },
    .linters = .{
        .sh = .{ .cmd = .{ "shellcheck", "-f", "gcc" }, .parser = .shellcheck },
        // .parser: .vimgrep (default, path:line:col: msg) | .eslint | .tsc | .ruff | .shellcheck
    },

    // ── dap (exec-bearing) ─────────────────────────────────────────────
    .dap = .{
        .lldb = .{
            .cmd = "lldb-dap",
            .args = .{},
            .launch = .{ .program = "${workspaceFolder}/zig-out/bin/mnml-zig" }, // verbatim
        },
    },

    // ── browser / ci / integrations ────────────────────────────────────
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

    // ── workspaces ─────────────────────────────────────────────────────
    .workspaces = .{
        .{ .name = "mnml", .path = "~/Projects/mnml", .group = "personal" },
    },

    // ── marketplace ────────────────────────────────────────────────────
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

    // ── cloud ──────────────────────────────────────────────────────────
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
}
```

The block above is parsed by a test (`docs config example parses clean`
in `src/config/load.zig`) — it cannot drift from the schema.

## Workspace trust

A workspace config is written by whoever owns the repo. Before its
exec-bearing keys apply, mnml lists them and asks once:

```
 Trust this workspace?
   proj runs programs from its .mnml/config.zon:
     • language server zig — runs `zls` when you open a file
     • format on save zig — runs `zig fmt` when you save
   Until trusted these settings are ignored; the rest apply.
                                        [T]rust   [D]on't trust
```

*Don't trust* is the focused choice, so a reflexive Enter is the safe
answer; the question comes back next launch. *Trust* records a
fingerprint of the claims — FNV-1a over each `kind / key / command`
line, sorted — in `<data root>/trusted_workspaces.zon`, keyed by the
canonical workspace path:

```zon
.{
    .@"/Users/me/proj" = "3f2a9c0e11d4b7a8",
}
```

A later change to any command changes the fingerprint and asks again;
ordinary edits to the file do not. A workspace file with no
exec-bearing key never asks. Until trusted, these are dropped from the
workspace layer and everything else still applies:

| key | runs |
|---|---|
| `.ui.external_browser` | when you open a link |
| `.ui.md_preview_engine = .{ .custom = … }` | when you preview markdown |
| `.lsp.<name>.cmd` / `.args` | when you open a file |
| `.formatters.<ext>` | when you save |
| `.linters.<ext>` | when you lint |
| `.dap.<name>` | when you start a debug session |
| `.startup.layout[]` with `.kind = .pty` | immediately, on open |
| `.startup.tasks` | immediately, on open |

(`.tasks.<name>` bodies are not in the table: a task only runs when you
ask for it by name.)

## Where the home file lives

1. `$MNML_DATA_ROOT/config.zon` when the variable is set
2. `<binary dir>/mnml-data/config.zon` when that directory exists and
   contains `.opted-in` (portable mode)
3. `$XDG_CONFIG_HOME/mnml/config.zon` when the variable is set
4. `$HOME/.config/mnml/config.zon`

## Writes

Settings screens and toggles write back with `persistScalar`: the file is
parsed, the one value's bytes are replaced in place, and comments and
order survive. A missing key is added at its section's indent; a missing
section is appended. An unchanged value is not written. Before every
write the previous file is copied to `backups/config.<YYYY-MM-DD-HHMMSS>.zon`
next to it, keeping the newest 50.

### The settings overlay

`view.settings`, `:settings`, or `Ctrl+,` opens the sectioned list —
`── UI ──`, `── Editor ──`, `── Integrations ──`, `── Reset ──` — one row
per discrete-choice key:

```
 ▸ Line numbers:      off / [on]
   TODOS sort:        [newest] / oldest / name / name_desc
   Theme:             [onedark] ‹ 62/94 ›
   Input style:       vim / [standard]  *
```

`▸` marks focus, `[brackets]` the current choice, a trailing `*` a value
that is not the shipped default. `←→` / `h l` adjust, `↑↓` / `j k` move,
`r` resets the row, `R` everything, `Enter` (or a click outside) keeps
and closes, `Esc` cancels.

**The file follows the row.** Adjusting a row applies at once and writes
the value to the row's file, so what you see is what is on disk. Which
file depends on the row: a per-project view setting (line numbers, wrap,
format on save, …) goes to the workspace's `.mnml/config.zon`; a
preference (theme, input style, ASCII icons, AI, Sonos, …) goes to the
home config. The title names the focused row's file. `Esc` puts back
the config, the input style, the theme, and the exact bytes of every
file written since the overlay opened — a file that did not exist is
removed again.

v1 rows are discrete choices only (bools, enums, the theme); numbers
and text (`tree_width`, `projects_dir`, …) stay TOML-era file edits
until v2.

### Themes

`.ui.theme` names one of the bundled themes — every `themes/*.zon`,
the 94 NvChad palettes, matched case-insensitively (`"OneDark"` is
`onedark`). `theme.pick` / `:theme` opens a picker that previews as you
move and writes the pick to the home config on Enter; `:theme <name>`
and `:set theme=<name>` pick directly. `theme.toggle` flips to
`.ui.theme_toggle`, or to the first bundled theme of the other kind
when it is unset; `theme.reset` returns to `.ui.theme`;
`theme.auto_system` follows the OS appearance (checked every 15 s) and
`theme.auto_system_off` freezes it. Only a pick writes the file.

A theme file is the palette as NvChad ships it, `0xrrggbb` values:

```zon
.{
    .name = "onedark",
    .kind = .dark, // .dark | .light
    .base_30 = .{ .white = 0xabb2bf, .black = 0x1e222a, /* … */ },
    .base_16 = .{ .base00 = 0x1e222a, /* … base0F */ },
}
```

Every UI role derives from it at build time with the same fallback
chains 0.2.x used (`one_bg2 → one_bg → black`, `light_grey → grey_fg2
→ grey_fg → grey → white`, `cyan → blue`, …); a missing `base_16` slot
takes onedark's. A malformed theme fails the build, not the launch.

### First launch

`.ui.first_launch_complete` gates the setup wizard: while it is false
the terminal loop opens it on start (after the trust dialog, if any).
Enter writes only what was touched — `editor.input_style`,
`ui.ascii_icons`, `ai.routing.<product>.backend`,
`ai.inline_suggestions` — plus `first_launch_complete = true`, to the
home config. Esc writes nothing and asks again next launch;
`first_launch.show` reopens it any time.

## Coming from 0.2.x (TOML)

mnml-zig reads no TOML — not `config.toml`, not the theme files, not
`trusted_workspaces.toml`. The last Rust release (0.2.22) carries the
converter, since it is the one that still has the typed TOML config:

```
mnml export-config-zon                # writes ~/.config/mnml/config.zon
mnml export-config-zon --out PATH     # or wherever you like
```

Run it once per config file you keep: the home file, and each
workspace's `.mnml/config.toml` (from inside that workspace, with
`--out .mnml/config.zon`). The output carries a `//` comment per key
from the schema's own doc table, and every key it could not place lands
verbatim in a trailing `// unmigrated:` block so nothing is lost
silently. The TOML file is left where it was; mnml-zig ignores it.

What changes shape on the way:

| 0.2.x TOML | ZON |
|---|---|
| `[abbr]` | `.abbr` |
| `[startup] tasks`, `[[startup.layout]]`, `default_workspace` | `.startup = .{ .tasks, .layout, .default_workspace }` |
| `[[marketplace.source]] type = "crates_keyword"` | `.marketplace.sources = .{ .{ .crates_keyword = .{ … } } }` (a tagged union) |
| `[[ui.integration_icon]]` | `.ui.integration_icons = .{ … }` |
| `md_preview_engine = "custom:cmd"` | `.md_preview_engine = .{ .custom = "cmd" }` |
| `input_style = "vim"` and every other closed-set string | an enum literal: `.input_style = .vim` |
| a formatter / linter `cmd = "rustfmt"` string | a list: `.cmd = .{ "rustfmt" }` |
| `claude_show_all_accounts = "true"` (bool-or-string) | a bool |
| `[keys.global] "ctrl+p" = "picker.files"` | `.keys = .{ .global = .{ .@"ctrl+p" = "picker.files" } }` |
| legacy glyph names, `DEAD_INTEGRATION_IDS` | remapped / dropped |

What does not need migrating:

- **Themes.** All 94 bundled themes ship as `themes/*.zon`; a custom
  `.toml` in your data root is not read. Convert it with the same shape
  as above (`tools/theme_toml2zon.zig` in the repo is the script that
  produced the bundled files) and drop it beside them.
- **Trust.** `trusted_workspaces.toml` is not read; each workspace with
  exec-bearing settings asks once more and is remembered in
  `trusted_workspaces.zon`.
- **`session.json`, `.rqst/history.jsonl`.** JSON, read best-effort with
  unknown fields ignored and rewritten in the 0.3 shape.

Nothing is automatic: a 0.3.0 launch with no `config.zon` starts on the
shipped defaults and the first-launch wizard, and says so in a toast if
a `config.toml` is sitting next to where the ZON file would be.
