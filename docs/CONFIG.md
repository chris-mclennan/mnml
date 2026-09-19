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

**Edit it as a tree.** Open any `.zon` file and click ` View as tree `
on its tab (`zon.view`): every field becomes a row with the widget its
type calls for — a bool toggles on Enter, an enum cycles on `←→` and
picks on Enter, a number steps and types, a string edits inline, a
list adds (`+`) / removes (`x`) / reorders (`J` `K`), an optional's
`null` offers `set…`, a union picks its tag. The comments below are
the rows' info lines. Each edit is the same splice the Settings
overlay writes with, so your comments and order survive; `*` marks a
changed row, Esc puts it back, `Ctrl+S` writes (a backup lands in
`backups/` beside the file) and the raw editor tab reloads. `Source`
on the tree's tab (`zon.source`, `e`) goes back to the text.

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
        // A built-in default server (json / yaml / html / css / csharp / …)
        // that is not on PATH: .quiet records it once per session — the LSP
        // chip reads ` LSP? `, its menu lists the server with its install
        // line and an Install… row — with no toast; .toast warns as a
        // server you named in .lsp does; .ignore says nothing anywhere.
        .lsp_missing_defaults = .quiet, // .quiet | .toast | .ignore
        .inline_values = true, // while the debugger is stopped: `  x = 1` after a line that names x
        .cursor_blink = false,
        .semantic_tokens_viewport = false,
        .semantic_tokens = true, // lay a server's semantic tokens over the syntax highlighting (off leaves tree-sitter alone)
        .code_lens = true,
        .text_width = 80,
        .ensure_trailing_newline = true,
        .chord_timeout_ms = 500, // vim's timeoutlen; clamped to 100..5000
        // The wheel (and a scrollbar drag) in the editor: .always carries the
        // cursor with the view (vim's Ctrl-E canon), .never moves the view
        // and pins it until the cursor moves (VS Code / Sublime), .auto
        // picks by input_style (vim → always, standard → never).
        .wheel_moves_cursor = .auto, // .auto | .always | .never
        // How much further a hard spin travels than a slow one: the
        // multiplier ramps on the wheel's rate (events per second) from
        // 1.0 under 45/s to the ceiling at 120/s — gentle ×1.5, normal
        // ×2.5, fast ×4 — so a single notch is always 1:1; a decaying wheel
        // (a free spin) is never amplified; .off is a plain 1:1 with a 40-line
        // flick bucket. docs/research/scroll-tuning.md has the numbers.
        .scroll_accel = .normal, // .off | .gentle | .normal | .fast
        .persistent_undo = false, // keep each file's undo + redo stacks in <data root>/undo/ across launches
        .clipboard = .auto, // .auto | .os | .internal — what `"+` / `"*` / Ctrl+C reach
        // Opt-in ceiling on what tree-sitter is asked to parse. 0 — the
        // shipped default — is NO limit: every file is highlighted in
        // full, however large. Set it and a file that opens larger than
        // this many bytes gets no tree-sitter at all: no parse, no tree,
        // no spans, no injections — editing, search, LSP and the git
        // gutter are untouched. It is never silent: the statusline shows
        // `highlight off · 12 MB` and a toast names the file; the chip
        // (or `editor.highlight_this_file`) turns it on for that one
        // file, and `editor.highlight_toggle_file` switches ANY buffer
        // either way. Per buffer, never persisted.
        //
        // Rule of thumb: a tree-sitter parse tree runs about 40× the size
        // of the source — a 100 MB file settles near 4 GB of RSS, a 10 MB
        // one near 400 MB, a 1 MB one near 40 MB. Set it only if that
        // matters on your machine.
        .highlight_max_bytes = 0, // 0 = no limit; e.g. 4194304 for 4 MB
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
        .right_panel_width = 32, // the right column (the Rust right panel's width)
        .bottom_panel_visible = false, // the dock at start (Rust's bottom panel)
        .bottom_panel_height = 12, // the dock's rows; clamped to 3..60
        // Every activity section lives in the left column, the right
        // column or the BOTTOM DOCK (`view.move_section_left` /
        // `_right`, the rail's right-click, vim `Ctrl-W H` / `L` / `J` /
        // `K` in a section, `:sidebar left|right|bottom`).
        // `sidebar_side` is the column a section takes when
        // `section_side` does not name one — the outline takes the other
        // side of it, and the diagnostics the dock (Rust opens
        // `lsp.diagnostics` as a pane under the editor). Every section
        // has a side (SEARCH and DEBUG are columns too). The session
        // keeps the sides a user moved; these are the starting point.
        .sidebar_side = .left, // .left | .right (the Settings row "Default sidebar side")
        .section_side = .{ // per section, null = the default above
            .explorer = null, // .left | .right | .bottom
            .git = null,
            .sessions = null,
            .http = null,
            .notes = null,
            .todos = null,
            .findings = null,
            .scripts = null,
            .search = null, // Rust's SEARCH sidebar section (the grep pane is its *Open as pane* door)
            .diagnostics = null, // null = the dock; `.right` is the pre-dock placement
            .outline = null,
        },
        .auto_hide_narrow_width = 0, // a WIDTH rule: below this many columns both side columns are dropped for the frame (0 = never; a non-zero value is clamped to 40..300). Nothing is mutated — widening brings back what was open
        .sidebar = .always, // .always (docked) | .auto (hidden; the pointer at the column's screen edge reveals it as an overlay OVER the editor — no relayout, no pty resize) | .hidden (never on hover; a keyboard command still gives a one-shot overlay)
        .sidebar_reveal_ms = 250, // how long the pointer rests in the edge zone before the overlay slides in (0..5000)
        .sidebar_hide_ms = 400, // how long after the pointer leaves the overlay before it hides (0..5000)
        .animations = true, // false is the reduced-motion switch: chrome animations with an instant end state are skipped (today the overlay's three-frame slide). --headless and the .test harness behave as if it were false
        .auto_equalize_splits = false,
        .relative_line_numbers = false,
        .line_numbers = true,
        .cursor_line = false,
        .scrolloff = 0,
        .sidescrolloff = 0,
        .show_whitespace = false,
        .bracket_rainbow = false,
        .tree_preview_on_arrow = true,
        .preview_tabs = true, // VS Code's preview tabs: a tree click (or an arrow over a tree row) opens an italic tab the next glance takes over; a double-click, an edit, `view.keep_tab`, a pin or a drag keeps it. The vim profile never has them
        .syntax = true,
        .scrollbar = true,
        .wheel_lines = 3, // lines per wheel EVENT in a text body (the editor, a markdown preview, a diff — Rust's editor gain); lists move a row an event; ghostty reports a notched detent as three events
        .highlight_trailing_ws = false,
        .clock = true,
        .stress_meter = false,
        .check_updates = true, // ask GitHub for the newest release once per launch; MNML_NO_UPDATE_CHECK=1 also skips it
        .activity_bar_pinned_integrations = .{}, // chip ids painted as launcher icons after the rail's sections; "Add to activity bar" on a row / chip menu writes here
        .plus_menu_pinned = .{},
        .plus_menu_hidden = .{},
        .auto_refresh_off = .{}, // panel ids whose auto-refresh is off
        .sessions_sort = .auto, // .auto | .manual
        .session_bell = false, // ring the terminal bell when a session starts waiting for input (SESSIONS toasts once per edge either way)
        .session_ended_grace_min = 10, // minutes an ended session stays listed in SESSIONS before the history chip hides it (0 = at once)
        .todos_sort = .newest, // .newest | .oldest | .name | .name_desc
        .notes_sort = .newest,
        .findings_sort = .newest,
        .statusline_segment_order = .{}, // .{} = the built-in order
        .highlight_word_under_cursor = false,
        .auto_md_preview = false,
        .color_column = 0, // 0 = off
        .wrap = false,
        .highlight_todo_keywords = false,
        .todo_keywords = .{ "TODO", "FIXME", "XXX", "HACK", "REVIEW" }, // what the TODOS panel scans for (after a comment opener, or a markdown list item)
        .render_markdown = false,
        .markdown_opens_rendered = true,
        .always_show_fold_arrows = false,
        .sticky_context = false,
        .md_image_rows = 12,
        .git_graph_branch_col = null, // null = auto width
        .git_graph_author_col = null,
        .git_graph_detail_col = null,
        .picker_position = .center, // .center | .top
        // The four first-party surfaces (browser, claude_code, codex,
        // http) — the palette-bar chip strip AND the always-present rows
        // of the INTEGRATIONS section's Installed tab. Omit to keep them;
        // set it to replace them. `enabled` (the chip paints and the row
        // reads live, not `(hidden)`) and `in_palette_bar` (the chip is on
        // the bar's strip) are the two the row menu's *Enable / Disable*
        // and *Show in / Hide from palette bar* write back here, in the
        // home config, whole. The other fields describe the row and are
        // not written by the UI.
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
        .activity_bar = .always, // .always | .auto (pointer in column 0 reveals) | .hidden
        .debug_toolbar = .auto, // the step toolbar strip over the editor: .auto (while a debug session is live) | .always | .hidden
        .bufferline_diag_style = .count, // .count | .dot | .off
        // The coverage chip reads `.tattle-claude-artifacts` under
        // `MNML_ARTIFACTS_HOME` when that is set, else your home directory.
        .coverage_chip_mode = .feature, // .both | .feature | .code | .ticker
        .expand_indicator = .chevron, // .chevron | .triangle
        // How a mounted integration's tab strip marks the tab that is
        // on: one row under the labels, in the pane's brand colour,
        // over exactly the active label's cells.
        //   .block  ▀ upper half-block, flush, the rest of the row empty
        //   .rule   ━ heavy under the active label, ─ across the strip
        //   .line   ─ under the active label only
        // A pane under about twelve rows spends no row on it and
        // underlines the active label instead.
        .tab_indicator = .block, // .block (half-block) | .rule (heavy + track) | .line (thin) | .quarter (quarter-height, flush under the label) | .quarter_track (the same bar across the whole strip, the active tab in colour)
        .hover_help_height = 8, // clamped to 3..20
        .terminal_label = "terminal",
        // A terminal pane paints the cursor its child asked for
        // (DECSCUSR block / bar / underline, hidden by DECTCEM). The
        // focused pane's is filled and, in a real terminal, is the
        // host's OWN cursor — so Ghostty blinks it, and hollows it out
        // when the mnml window itself loses focus. Every other pty pane
        // gets a painted stand-in, which is what `unfocused` picks:
        //   .hollow the cell keeps its glyph, repainted in the cursor
        //           colour — a cell grid cannot draw a true outline, so
        //           a blank cell shows □ and the cursor is still there
        //   .dim    a muted filled block: the cursor colour half-way to
        //           the pane's ground
        //   .none   nothing
        // `blink` passes the child's blink request out to the host,
        // which owns the clock. An unfocused pane never blinks.
        .pty_cursor = .{
            .unfocused = .hollow, // .hollow | .dim | .none
            .blink = true,
        },
        .external_browser = "", // a program to spawn; "" = the OS default (exec-bearing)
        // The mark every terminal wears — a pty tab's icon, the strip's
        // terminal chip. .ghostty is Ghostty's ghost, which mnml bakes
        // into its own face at U+F2000 and paints whatever emulator it
        // is running inside; .terminal is the codicon, and the only
        // value that brings the per-emulator table back (kitty's cat,
        // Apple's apple); .custom is terminal_glyph_svg, baked at the
        // same codepoint. Right-click the terminal chip, or the
        // view.terminal_glyph_* commands.
        .terminal_glyph = .ghostty, // .ghostty | .terminal | .custom
        // The SVG behind .custom. view.terminal_glyph_custom prompts for
        // it, bakes <data root>/fonts/MnmlSymbols.ttf and sets both keys.
        .terminal_glyph_svg = "",
        .top_bar_cluster_mode = .auto, // .auto | .expanded | .compact
        // .none hides the AI chips; otherwise an enabled integration icon
        // shows its chip, and a CLI found on PATH shows its chip when named
        // here (.claude_code | .codex | .both). view.tab_bar_ai_* set it.
        .tab_bar_ai_icon = .claude_code,
        .ai_layout_mode = .grid, // .grid (Claude tiles 2×2 → 4×2, eight per screen) | .tabs
        .ai_chip_use_mnml_glyphs = false, // deprecated, read by nothing: the chips always paint mnml's baked marks
        .auto_show_sessions_on_ai_activate = true,
        .git_section_default_expanded = false,
        .integrations_section_default_expanded = false,
        .hover_help = true,
        .hover_tooltip = false,
        .click_echo = false,
        .first_launch_complete = false, // set by the first-launch flow
        .config_toml_notice_shown = false, // set once the 0.2 config.toml notice has shown on this data root (see "Coming from 0.2.x")
        .integrations_toml_notice_shown = false, // set by `integrations.dismiss_toml_notice` — the 0.2 manifests notice, "Don't show again"
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
    // Built-in defaults (`src/lsp/client.zig`), each overridable field by
    // field under its name: rust (rust-analyzer), python (pyright),
    // typescript, go (gopls), c (clangd), zig (zls), lua, json
    // (vscode-json-language-server --stdio, .json/.jsonc), yaml
    // (yaml-language-server --stdio), html, css (.css/.scss/.less; the
    // vscode-*-language-server pair from `npm i -g
    // vscode-langservers-extracted`) and csharp (csharp-ls, `dotnet tool
    // install -g csharp-ls`; roots at the nearest `*.sln` / `*.csproj` /
    // global.json — a `*` marker is a glob). A default that is not
    // installed is `.editor.lsp_missing_defaults`' business (quiet); a
    // server named here that is missing always toasts.
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
        // A named way to start claude / codex; the AI chip's right-click lists
        // them and the mnml-ai-<name> shim exports .env. The built-in `default`
        // (the bare binary) is implicit.
        .launch_profiles = .{
            .{
                .name = "work",
                .product = .claude, // .claude | .codex
                .binary = "claude", // a path, or a name on PATH
                .args = .{},
                .env = .{ "KEY=VALUE" },
                .cwd_mode = .workspace, // .workspace | .home | .file_dir
                .worktree = false, // true: every session of this profile starts in a git worktree of its own
            },
        },
        .default_profile = .{ .claude = null, .codex = null }, // a profile name per product; null = the built-in
        // Where a session worktree goes. null = `<repo>-worktrees` beside the
        // repository; `~` expands, a relative path sits under the repository.
        .default_worktree_root = null,
        .inline_suggestions = true,
        .claude_show_all_accounts = false,
        // How the statusline's Claude chip shows several accounts: .off = the
        // active one alone, .compact = a sparkline block per account, .ticker =
        // one account at a time, 4 s each (ai.chip_show_all_*). With one
        // account it is always the single chip; what that chip shows —
        // session %, weekly %, both; the reset countdown — is the chip's
        // right-click (ai.chip_show_session / _weekly / _both, ai.chip_toggle_reset).
        .claude_meter_mode = .compact, // .off | .compact | .ticker
        // The Claude Code logins the quota chip and the usage pane
        // (ai.claude_usage) poll. `token_path` is the OAuth token file the
        // CLI's keychain item was copied into (`ai.link_claude_token`, or R
        // in the pane) — `~` expands, a relative path sits under the data
        // root beside the default `ai_token`; `active` marks the one the
        // chip shows alone (the CLI's live login wins when the keychain
        // names one). No entries = one `default` account on `ai_token` — or
        // the 0.2.x `[[ai.claude.accounts]]` blocks, which the migration keeps
        // verbatim as `.ai.claude.accounts` and the reader honours as-is.
        // MNML_CLAUDE_USAGE_FIXTURE=<dir> replaces the wire with files (the
        // tests, the spec dumps; see src/ai/usage.zig).
        .claude_accounts = .{
            .{ .name = "personal", .token_path = "ai_token.personal" },
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
        // Transport defaults for every send; a block's own directive
        // (`# @insecure`, `# @timeout 5s`, `# @no-redirect`,
        // `# @max-redirects 3`, `# @proxy host:port`) overrides them for
        // that request, and the Auth tab's Options rows write those lines.
        .insecure = false, // skip the certificate chain check (curl -k)
        .timeout_ms = null, // a deadline over the whole send; null waits
        .follow_redirects = true,
        .max_redirects = 10,
        .proxy = null, // "host:port", "user:pass@host:port", "http://host:port"
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

    // ── git ────────────────────────────────────────────────────────────
    // Repo accents, by repo name: one of green blue yellow orange red
    // purple cyan pink (`src/ui/accent_color.zig`, the same palette the
    // sessions use), or "none" for the auto slot. With two or more repos
    // in the workspace the app writes each repo's slot here the first
    // time it sees it (the first assignment wins across restarts) and the
    // repo pill's right-click Color menu writes a pick; one repo shows no
    // accent. Home layer only — a workspace file's entries are read but
    // the app writes home.
    .git = .{ .repo_colors = .{ .mnml = "green", .@"mnml-zig" = "blue" } },

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
        .rs = .{ .cmd = .{ "rustfmt", "--edition", "2024" } }, // stdin → stdout
        .zig = .{ .cmd = .{ "zig", "fmt", "--stdin" } },
        // A tool that rewrites the file: the buffer is written, the tool runs
        // on {file} (the workspace-relative path), the result is read back.
        .go = .{ .cmd = .{ "gofmt", "-w", "{file}" }, .in_place = true },
    },
    .linters = .{
        .sh = .{ .cmd = .{ "shellcheck", "-f", "gcc" }, .parser = .shellcheck },
        // .parser: .vimgrep (default, path:line:col: msg) | .eslint | .tsc | .ruff | .shellcheck | .pattern
        // .pattern matches a line template of placeholders literally between them:
        .log = .{ .cmd = .{ "mylint", "{file}" }, .parser = .pattern, .pattern = "{file}:{line}:{col}: {severity}: {message}" },
    },

    // ── dap (exec-bearing) ─────────────────────────────────────────────
    .dap = .{
        .lldb = .{
            .cmd = "lldb-dap",
            .args = .{},
            .launch = .{ .program = "${workspaceFolder}/zig-out/bin/mnml-zig" }, // verbatim
        },
        // `$NAME` / `${NAME}` in .cmd or an argument expands from the
        // environment when the adapter is spawned; dap.run re-reads
        // this table when the file has no adapter yet (trusted only).
        //
        // Built in, consulted after this table and the re-read, so an
        // entry here for the same key wins (`dap.builtin_adapters`):
        //   .cs = .{ .cmd = "netcoredbg", .args = .{ "--interpreter=vscode" } }
        //     launch = { program: <csproj dir>/bin/Debug/<TargetFramework>/<AssemblyName>.dll, cwd: <csproj dir> }
        //     — derived from the nearest .csproj at or above the file
        //     (`<AssemblyName>` else the file's stem; `<TargetFramework>`,
        //     else the first of `<TargetFrameworks>`, else net8.0). The
        //     assembly must be built: `dotnet.debug` runs `dotnet build` in
        //     a task pane first and starts the session when it exits 0;
        //     `dap.run` (F5) on a .cs file launches what is already built.
        //     netcoredbg is a release download (github.com/Samsung/netcoredbg);
        //     its `all` / `user-unhandled` exception filters appear in
        //     `dap.exceptions`, `user-unhandled` on by default.
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
        .open_as = .split, // .split (a mounted integration opens BESIDE the active pane, side by side — the Rust behaviour) | .tab (another tab in the active leaf)
        .equalize_on_open = true, // after an integration split, even the splits out whatever ui.auto_equalize_splits says
        // Folders the INTEGRATIONS section's Dev tab scans: every
        // subfolder with a build.zig and a manifest.zon beside it is an
        // integration in development (Build / Install / Rebuild +
        // reinstall from the row). Relative to the workspace, `~`
        // expanded. A workspace with sdk/mnml-sdk adds its own
        // integrations/ by itself.
        .dev_roots = .{ "../my-integrations" },
        // The statusline poller: what keeps a manifest's chip counts
        // live with no pane open. It runs each manifest's
        // `values_sources` command (`mnml-bitbucket --values`) on that
        // source's interval, staggered, backing off on a failure, and
        // never while a pane of that integration is open.
        .poll = .{
            // Off means a chip moves only when its pane or its refresh
            // command says so.
            .enabled = true,
            // The floor under every manifest's own poll_interval_secs —
            // your say in how hard your API budget may be spent. The
            // poller's own 30-second floor still applies underneath.
            .min_interval_secs = 60,
        },
    },

    // ── workspaces ─────────────────────────────────────────────────────
    .workspaces = .{
        .{ .name = "mnml", .path = "~/Projects/mnml", .group = "personal" },
    },

    // ── marketplace ────────────────────────────────────────────────────
    .marketplace = .{
        .enabled = true,
        .cache_ttl_secs = 3600,
        .use_defaults = true, // prepend mnml's own sources (none ship yet — the official set comes with the first Zig integrations)
        .sources = .{
            .{ .crates_keyword = .{ .id = "crates.io", .keyword = "mnml-integration" } },
            .{ .github_launcher_folder = .{ .id = "me/launchers", .repo = "me/launchers", .path = "launchers" } },
            .{ .github_monorepo_apps = .{ .id = "me/apps", .repo = "me/mono", .apps_dir = "apps" } },
            // A folder on this machine or a mounted share — the private
            // path: every *.zon in it is a manifest to install as-is (a
            // launcher), every subfolder with a build.zig and a
            // manifest.zon a Zig integration built in place. Relative to
            // the workspace, `~` expanded. `MNML_MARKETPLACE_LOCAL=<folder>`
            // in the environment makes such a folder the only source.
            // The repo's own launchers/ lists as ✓ Official, not Private:
            // it is the official set.
            .{ .local_folder = .{ .id = "private", .path = "~/mnml-private" } },
        },
        .show_dev_tab = false,
        // The Marketplace tab opens with a FONTS section: every Nerd
        // Font family installed (the platform font folders, read from
        // the font files' own name tables) against the latest release,
        // with a one-click update on macOS. Nothing here configures it;
        // two environment variables do: MNML_FONT_DIRS=<dir:dir> (`;`
        // on Windows) replaces the folders scanned, MNML_NERDFONTS_LATEST=X.Y.Z
        // names the latest release and skips the once-a-day lookup
        // (cached at <data root>/cache/nerdfonts-latest.json).
    },

    // ── scripts ────────────────────────────────────────────────────────
    // Installed Lua scripts (docs/LUA.md, "Installing scripts"). A
    // script is a directory under <data root>/scripts/<name>/ holding a
    // script.zon, an init.lua and optionally lib/*.lua and a README.md,
    // and it gets its OWN Lua state: its own budget clock, its own
    // decoration namespaces, its own require root. The SCRIPTS section
    // lists them on three tabs — installed · marketplace · dev — the way
    // INTEGRATIONS does.
    // Installed scripts land in <data root>/scripts/ unless
    // MNML_SCRIPTS_ROOT=<folder> names somewhere else — how the corpus
    // keeps each file's installs to itself.
    .scripts = .{
        // The curated set ships with mnml — the repo's own lua/ folder,
        // packaged as share/mnml/lua beside the binary — so the
        // Marketplace tab lists it out of the box with no config at
        // all. This key points the tab at a folder of YOUR script
        // directories instead: an offline mirror, a company set, a test
        // fixture. Relative to the workspace, `~` expanded.
        // MNML_SCRIPTS_MARKETPLACE=<folder> overrides it, which is how
        // the corpus and the UI specs seed the tab.
        .marketplace_local = "",
        // Folders of script directories you maintain — a company repo, a
        // mounted share. Listed with the `private` badge; the same trust
        // dialog on install. Relative to the workspace, `~` expanded.
        .private_sources = .{ "~/mnml-private-scripts" },
        // Folders the Dev tab scans: every subfolder with a script.zon
        // is a script in development, reloaded when one of its files is
        // saved. MNML_SCRIPTS_DEV_ROOTS=<dir:dir> (`;` on Windows)
        // overrides, which is how the corpus and the UI specs point the
        // tab at a folder without writing a config.
        .dev_roots = .{ "../my-scripts" },
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
| `.ai.launch_profiles[]` (`.binary` / `.args` / `.env` / `.worktree`) and `.ai.default_profile` | when you start a Claude / Codex session |
| `.mnml/init.lua` (the script beside the config) | on open, and on `script.reload` |
| `.mnml/integrations/*.zon` (the manifests beside the config) | when one of their commands runs |

(`.tasks.<name>` bodies are not in the table: a task only runs when you
ask for it by name.)

## Launchers and integration manifests

An integration is a manifest at `<data root>/integrations/<id>.zon`
(or `<ws>/.mnml/integrations/<id>.zon` for one project); the schema is
`sdk/mnml-sdk/src/manifest.zig` and `docs/SDK.md`. A manifest without a
`binary` is a **launcher**: it ships no program, and each of its
commands carries a `run` line — an ex line, usually `:term <tool> …` —
that mnml expands and runs when the command fires:

```zig
.{
    .id = "htop",
    .label = "htop",
    .description = "Interactive process viewer",
    .chip = .{ .glyph_codepoint = "F1D00", .fallback = "H", .color = "green", .in_palette_bar = false },
    .commands = .{
        .{ .id = "htop.open", .title = "htop: open", .keys = .{"space i H"}, .run = ":term htop" },
    },
}
```

- `run` (or `ex`) may name mnml's context: `{{workspace}}`,
  `{{workspace_name}}`, `{{current_file}}` (workspace-relative),
  `{{current_file_abs}}`, `{{current_file_dir}}`, `{{cursor_line}}`,
  `{{cursor_col}}` (1-based), `{{selection}}` (its first line). An
  unknown `{{token}}` stays as written. A `term <prog>` line whose
  program is not on PATH toasts the install hint instead of opening a
  pane.
- `chip.glyph` is a Nerd Font glyph; `chip.glyph_codepoint` (`F1D00`)
  paints a codepoint verbatim when `glyph` is empty — for a mark in
  mnml's own font block; `chip.fallback` is what paints without the
  font. `chip.in_palette_bar` puts the chip on the palette bar; the
  row's and the chip's right-click menus toggle it (*Hide from top bar*
  / *Show on top bar*).
- A launcher needs at least one command and every command a `run`
  line; a manifest with no `binary` and no command is refused, by
  `--install` and by mnml's scan alike.

Where one comes from: the Marketplace tab (a `github_launcher_folder`
or `local_folder` source — the four in `launchers/` of the mnml-zig
repo are the official set), the Dev tab (an SDK checkout lists its
`launchers/` beside its `integrations/`), or `launcher.add_local` (a
prompt for a `.zon` path). Install is the file appearing in the data
root; uninstall is deleting it.

**Pinned icons.** `.ui.activity_bar_pinned_integrations = .{ "htop" }`
paints the named chips after the activity bar's sections, each the
chip's glyph in its colour; a click runs the chip's command (a pty
pane, no side panel), a right click opens the chip's menu. *Add to
activity bar* / *Remove from activity bar* on an Installed row's menu,
a chip's menu or the icon's own writes the list to the home config.

## Session worktrees

A Claude / Codex session can start in a git worktree of its own —
opt-in, off by default (`src/app/session_worktree.zig`). Per launch:
*New session in a worktree…* on the AI chip's right-click, the `+`
menus and `+ New session`, or `ai.new_session_worktree`. Per profile:
`.ai.launch_profiles[].worktree = true` sends every session of that
profile this way. Either prompts for a branch name (seeded
`session-<n>`, or `<profile>-<n>`), runs `git worktree add -b <name>
<root>/<name> HEAD` in the workspace's repository and opens the session
in the tree with `MNML_WORKSPACE` pointing at it.

`<root>` is `<repo>-worktrees` beside the repository (this project's
own convention: `mnml-zig-worktrees/<track>`) unless
`.ai.default_worktree_root` names another — `~` expands, a relative
path sits under the repository, an absolute one is taken as is. The
name is validated as a branch name; an existing directory or branch is
refused with the reason.

The SESSIONS row tags the session `⑂ <name>`; its menu offers *Open
worktree in tree*, *Merge into <branch>…* (`--no-ff`, refused while
the main tree has uncommitted changes) and *Remove worktree…*
(`worktree remove` + `branch -d`; an unmerged branch asks once more
with Force). The git panel's WORKTREES row paints the session's accent
and carries the same two verbs. The trees mnml made are remembered in
`.mnml/session.zon` (`sessions_worktrees`). `.worktree` on a profile
is stripped with the profile from an untrusted workspace config
(Workspace trust above).

## Bookmarks

`bookmarks.open` is a picker over your web bookmarks, grouped by
environment — `dev  ·  ADX Admin`, the URL as the row's detail; Enter
hands the URL to the browser (`.ui.external_browser`, or the OS
default). The mechanism is mnml's; the URLs are yours, in two files
that both load and add up — a repo's file extends your own set rather
than hiding it:

1. `<data root>/bookmarks.zon`
2. `<workspace>/.mnml/bookmarks.zon`

```zig
.{
    .sites = .{
        // One destination in several environments: dev / staging /
        // prod as fields, any other name under .envs.
        .{
            .name = "ADX Admin",
            .dev = "https://adx.dev.example.net/admin",
            .staging = "https://adx.staging.example.net/admin",
            .prod = "https://adx.example.com/admin",
            .envs = .{ .{ .env = "uat", .url = "https://adx.uat.example.net/admin" } },
        },
    },
    .bookmarks = .{
        // A one-off; .env defaults to "other".
        .{ .label = "Metabase", .url = "https://metabase.example.net", .env = "prod" },
    },
}
```

A site expands to one row per environment it names, in the order dev,
staging, prod, then `.envs` as written; an empty URL is skipped. A
malformed file is skipped rather than fatal. With neither file the
command toasts the path to write.

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
`── UI ──`, `── Editor ──`, `── AI ──`, `── Integrations ──`, `── Reset ──`
— one row per discrete-choice key, and a `‹ [32] ›` row per number:

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

Rows are discrete choices (bools, enums, the theme) and numbers
(`tree_width`, `right_panel_width`, `bottom_panel_height`, `wheel_lines`, `md_image_rows`,
`hover_help_height`, `color_column`, `tab_width`, `text_width`,
`chord_timeout_ms` — 73 rows in all); text (`projects_dir`, the
labels) stays a file edit.

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

Space is the install key and writes no config. On the Nerd Font section
with "boxes" answered it runs this OS's install of Symbols Nerd Font
Mono (`brew install --cask font-symbols-only-nerd-font`; on Linux the
NerdFontsSymbolsOnly zip into `~/.local/share/fonts/nerd-symbols` and
`fc-cache -f`; on Windows PowerShell into the per-user font directory
with an HKCU registration, no admin); on Claude Code + Codex it runs
the vendors' installers for whichever CLI is missing; on the `code`
shim (macOS) it links the VS Code bundle's `code` into `/usr/local/bin`
under sudo. Each runs in an `install: …` pane; the wizard closes for
the pane, keeps its answers, and comes back when the pane ends — with
the rows re-detected, and, for the font, a toast saying how to point
your terminal at it (keyed off `TERM_PROGRAM`) that appears only when
the pane exited 0.

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

What mnml-zig says about a `config.toml` it finds where a `config.zon`
should be (and only then — a `.toml` beside a `.zon` is nothing):

- **Once per data root, a toast** naming the file and the converter
  line above. `ui.config_toml_notice_shown = true` is written to the
  home config the first time; after that the same line is in
  `:messages` on every launch and nowhere else.
- **For a workspace file, `RESTRICTED` on the statusline** for as long
  as the file stands with no `.zon` beside it — the workspace's whole
  config is not in effect, which is what the chip means. Its hover says
  so and a click (`workspace.review_trust`) repeats the converter line.
  Converting the file (the `.zon` appears) clears the chip on the next
  launch or `workspace.review_trust`.

The 0.2 integration manifests (`<data root>/integrations/*.toml`,
`<workspace>/.mnml/integrations/*.toml`) are the same decision: never
read, never deleted or renamed. The INTEGRATIONS section says once per
launch, and on the Installed tab's empty state, that `N integrations
from mnml 0.2 are not loaded — 0.3 integrations install from the
Marketplace`; *Don't show again* on that toast's right-click menu (or
`integrations.dismiss_toml_notice`) writes
`ui.integrations_toml_notice_shown = true`.

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
