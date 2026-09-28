//! `mnml export-config-zon` — the one-way bridge from the 0.2.x TOML
//! config to the ZON file mnml-zig (0.3.0) reads. mnml-zig reads no
//! TOML at all, so the last Rust release carries the converter: it is
//! the one binary that still has the typed TOML schema.
//!
//! The TOML is walked as a `toml::Value` tree against a schema that
//! mirrors mnml-zig's `src/config/Config.zig`, so the output carries
//! **only the keys the user set** (a typed `Config` would emit every
//! default). Each emitted key is preceded by a `//` doc comment from
//! [`DOCS`], keyed by ZON path; sections come out in the order of
//! mnml-zig's `docs/CONFIG.md`.
//!
//! Anything that cannot be placed — an unknown section, a key the Zig
//! schema does not have, a value the Zig enum would reject — lands
//! verbatim in a trailing `// unmigrated:` block, so nothing is lost
//! silently and a bad literal never reaches the Zig loader (which
//! drops the whole section on one bad field).

use std::path::Path;

// ─── schema ──────────────────────────────────────────────────────────────

/// Integer width on the Zig side. A TOML integer outside the range is
/// unmigrated rather than emitted (it would be a type error at its
/// line, and the section would be dropped).
#[derive(Clone, Copy)]
enum IntKind {
    U8,
    U16,
    U32,
}

impl IntKind {
    fn fits(self, v: i64) -> bool {
        match self {
            IntKind::U8 => (0..=u8::MAX as i64).contains(&v),
            IntKind::U16 => (0..=u16::MAX as i64).contains(&v),
            IntKind::U32 => (0..=u32::MAX as i64).contains(&v),
        }
    }
    fn name(self) -> &'static str {
        match self {
            IntKind::U8 => "u8",
            IntKind::U16 => "u16",
            IntKind::U32 => "u32",
        }
    }
}

/// What a TOML value at a given path becomes in ZON.
enum Shape {
    Bool,
    Int(IntKind),
    Str,
    StrList,
    /// A closed set → `.enum_literal`; anything else is unmigrated.
    Enum(&'static [&'static str]),
    /// Fixed fields; a key not in the list is unmigrated.
    Struct(&'static [Field]),
    /// Fixed fields plus pass-through: a key not in the list is emitted
    /// as a `Dynamic` value (mnml-zig collects it into `.extra`).
    StructExtra(&'static [Field]),
    /// User-keyed table; every value has the same shape.
    Map(&'static Shape),
    /// TOML array; every element has the same shape.
    List(&'static Shape),
    /// Verbatim value tree (`Dynamic` on the Zig side).
    Dynamic,
    /// `cmd = "rustfmt"` or `cmd = ["rustfmt", "--edition", "2024"]` → a list.
    StrOrList,
    /// `claude_show_all_accounts` — bool, or the 0.2.x tri-state string.
    BoolOrStr,
    /// `md_preview_engine` — `"custom:cmd"` → `.{ .custom = "cmd" }`.
    MdEngine,
    /// `[ai] backend` and `[ai.routing.*] backend` — Rust's alias set
    /// (`cli`, `subscription`, `http`, …) folded onto the Zig enum.
    AiBackend,
    /// `[http] collection_root` — Rust's aliases folded onto the enum.
    CollectionRoot,
    /// `[[marketplace.source]] type = "…"` → a tagged union per entry.
    MarketplaceSources,
    /// `[[ui.integration_icon]]` → `.integration_icons`, with the
    /// legacy glyph remaps applied and retired ids dropped.
    IntegrationIcons,
}

struct Field {
    /// The TOML key.
    toml: &'static str,
    /// The ZON key (usually the same).
    zon: &'static str,
    shape: Shape,
}

const fn f(name: &'static str, shape: Shape) -> Field {
    Field {
        toml: name,
        zon: name,
        shape,
    }
}

const LIST_SORT: &[&str] = &["newest", "oldest", "name", "name_desc"];

const EDITOR: &[Field] = &[
    f("input_style", Shape::Enum(&["vim", "standard"])),
    f("tab_width", Shape::Int(IntKind::U8)),
    f("autosave_secs", Shape::Int(IntKind::U32)),
    f("trim_trailing_ws_on_save", Shape::Bool),
    f("breadcrumb", Shape::Bool),
    f("auto_pair", Shape::Bool),
    f("auto_indent", Shape::Bool),
    f("format_on_save", Shape::Bool),
    f("will_save_wait_until", Shape::Bool),
    f("format_on_type", Shape::Bool),
    f("autosave_on_focus_loss", Shape::Bool),
    f("inlay_hints", Shape::Bool),
    f("cursor_blink", Shape::Bool),
    f("semantic_tokens_viewport", Shape::Bool),
    f("semantic_tokens", Shape::Bool),
    f("code_lens", Shape::Bool),
    f("text_width", Shape::Int(IntKind::U16)),
    f("ensure_trailing_newline", Shape::Bool),
    f("chord_timeout_ms", Shape::Int(IntKind::U16)),
    f(
        "wheel_moves_cursor",
        Shape::Enum(&["auto", "always", "never"]),
    ),
    f(
        "scroll_accel",
        Shape::Enum(&["off", "gentle", "normal", "fast"]),
    ),
    f("persistent_undo", Shape::Bool),
    f("clipboard", Shape::Enum(&["auto", "os", "internal"])),
];

const INTEGRATION_ICON_COMMAND: &[Field] = &[f("id", Shape::Str), f("title", Shape::Str)];

/// The fields of one `.integration_icons` entry, in Zig order.
const INTEGRATION_ICON: &[Field] = &[
    f("id", Shape::Str),
    f("glyph", Shape::Str),
    f("fallback", Shape::Str),
    f("command", Shape::Str),
    f("color", Shape::Str),
    f("label", Shape::Str),
    f("enabled", Shape::Bool),
    f("in_palette_bar", Shape::Bool),
    f("description", Shape::Str),
    f("homepage", Shape::Str),
    f("docs", Shape::Str),
    f("repository", Shape::Str),
    f("author", Shape::Str),
    f("version", Shape::Str),
    f(
        "commands",
        Shape::List(&Shape::Struct(INTEGRATION_ICON_COMMAND)),
    ),
];

const UI: &[Field] = &[
    f("theme", Shape::Str),
    f("cmdline_popup_border_color", Shape::Str),
    f("theme_toggle", Shape::Str),
    f("theme_auto_system", Shape::Bool),
    f("ascii_icons", Shape::Bool),
    f("tree_width", Shape::Int(IntKind::U16)),
    f("right_panel_visible", Shape::Bool),
    f("right_panel_width", Shape::Int(IntKind::U16)),
    f("auto_hide_narrow_width", Shape::Int(IntKind::U16)),
    f("auto_equalize_splits", Shape::Bool),
    f("relative_line_numbers", Shape::Bool),
    f("line_numbers", Shape::Bool),
    f("cursor_line", Shape::Bool),
    f("scrolloff", Shape::Int(IntKind::U16)),
    f("sidescrolloff", Shape::Int(IntKind::U16)),
    f("show_whitespace", Shape::Bool),
    f("bracket_rainbow", Shape::Bool),
    f("tree_preview_on_arrow", Shape::Bool),
    f("syntax", Shape::Bool),
    f("scrollbar", Shape::Bool),
    f("wheel_lines", Shape::Int(IntKind::U8)),
    f("highlight_trailing_ws", Shape::Bool),
    f("clock", Shape::Bool),
    f("stress_meter", Shape::Bool),
    f("check_updates", Shape::Bool),
    f("activity_bar_pinned_integrations", Shape::StrList),
    f("plus_menu_pinned", Shape::StrList),
    f("plus_menu_hidden", Shape::StrList),
    f("auto_refresh_off", Shape::StrList),
    f("sessions_sort", Shape::Enum(&["auto", "manual"])),
    f("todos_sort", Shape::Enum(LIST_SORT)),
    f("notes_sort", Shape::Enum(LIST_SORT)),
    f("findings_sort", Shape::Enum(LIST_SORT)),
    f("statusline_segment_order", Shape::StrList),
    f("highlight_word_under_cursor", Shape::Bool),
    f("auto_md_preview", Shape::Bool),
    f("color_column", Shape::Int(IntKind::U16)),
    f("wrap", Shape::Bool),
    f("highlight_todo_keywords", Shape::Bool),
    f("todo_keywords", Shape::StrList),
    f("render_markdown", Shape::Bool),
    f("markdown_opens_rendered", Shape::Bool),
    f("always_show_fold_arrows", Shape::Bool),
    f("sticky_context", Shape::Bool),
    f("md_image_rows", Shape::Int(IntKind::U16)),
    f("git_graph_branch_col", Shape::Int(IntKind::U16)),
    f("git_graph_author_col", Shape::Int(IntKind::U16)),
    f("git_graph_detail_col", Shape::Int(IntKind::U16)),
    f("picker_position", Shape::Enum(&["center", "top"])),
    Field {
        toml: "integration_icon",
        zon: "integration_icons",
        shape: Shape::IntegrationIcons,
    },
    f("integration_icon_order", Shape::StrList),
    f("ticket_prefixes", Shape::StrList),
    f(
        "now_playing_source",
        Shape::Enum(&["auto", "mixr", "macos"]),
    ),
    f("now_playing_marquee", Shape::Bool),
    f(
        "preferred_music_app",
        Shape::Enum(&["mixr", "music", "spotify"]),
    ),
    f("mixr_auto_play_on_open", Shape::Bool),
    f("projects_dir", Shape::Str),
    f("menu_bar", Shape::Enum(&["always", "auto", "hidden"])),
    f(
        "bufferline_diag_style",
        Shape::Enum(&["count", "dot", "off"]),
    ),
    f(
        "coverage_chip_mode",
        Shape::Enum(&["both", "feature", "code", "ticker"]),
    ),
    f("expand_indicator", Shape::Enum(&["chevron", "triangle"])),
    f("hover_help_height", Shape::Int(IntKind::U16)),
    f("terminal_label", Shape::Str),
    f("external_browser", Shape::Str),
    f("terminal_glyph_svg", Shape::Str),
    f(
        "top_bar_cluster_mode",
        Shape::Enum(&["auto", "expanded", "compact"]),
    ),
    f(
        "tab_bar_ai_icon",
        Shape::Enum(&["none", "claude_code", "codex", "both"]),
    ),
    f("ai_layout_mode", Shape::Enum(&["grid", "tabs"])),
    f("ai_chip_use_mnml_glyphs", Shape::Bool),
    f("auto_show_sessions_on_ai_activate", Shape::Bool),
    f("git_section_default_expanded", Shape::Bool),
    f("integrations_section_default_expanded", Shape::Bool),
    f("hover_help", Shape::Bool),
    f("hover_tooltip", Shape::Bool),
    f("click_echo", Shape::Bool),
    f("first_launch_complete", Shape::Bool),
    f("show_workspace_dots", Shape::Bool),
    f("md_preview_engine", Shape::MdEngine),
];

const SESSION: &[Field] = &[f("restore", Shape::Bool)];
const IPC: &[Field] = &[f("write_screen", Shape::Bool)];

const KEYS: &[Field] = &[
    f("global", Shape::Map(&Shape::Str)),
    f("vim", Shape::Map(&Shape::Str)),
    f("standard", Shape::Map(&Shape::Str)),
];

const LSP_SERVER: &[Field] = &[
    f("cmd", Shape::Str),
    f("args", Shape::StrList),
    f("extensions", Shape::StrList),
    f("root_markers", Shape::StrList),
    f("settings", Shape::Dynamic),
    f("initialization_options", Shape::Dynamic),
];

const AI_ROUTE: &[Field] = &[f("backend", Shape::AiBackend)];
const AI_ROUTING: &[Field] = &[
    f("claude", Shape::Struct(AI_ROUTE)),
    f("codex", Shape::Struct(AI_ROUTE)),
];
const LAUNCH_PROFILE: &[Field] = &[
    f("name", Shape::Str),
    f("product", Shape::Enum(&["claude", "codex"])),
    f("binary", Shape::Str),
    f("args", Shape::StrList),
    f("env", Shape::StrList),
    f("cwd_mode", Shape::Enum(&["workspace", "home", "file_dir"])),
];
const DEFAULT_PROFILE: &[Field] = &[f("claude", Shape::Str), f("codex", Shape::Str)];
const AI: &[Field] = &[
    f("backend", Shape::AiBackend),
    f("routing", Shape::Struct(AI_ROUTING)),
    f(
        "launch_profiles",
        Shape::List(&Shape::Struct(LAUNCH_PROFILE)),
    ),
    f("default_profile", Shape::Struct(DEFAULT_PROFILE)),
    f("inline_suggestions", Shape::Bool),
    f("claude_show_all_accounts", Shape::BoolOrStr),
    f(
        "claude_meter_mode",
        Shape::Enum(&["off", "compact", "ticker"]),
    ),
];

const HTTP: &[Field] = &[
    f("default_env", Shape::Str),
    f("collection_root", Shape::CollectionRoot),
    f("auto_format_body", Shape::Bool),
    f("sync_normalize", Shape::Bool),
];
const WS: &[Field] = &[
    f("subprotocols", Shape::StrList),
    f("ping_interval_secs", Shape::Int(IntKind::U32)),
    f("reconnect_max_attempts", Shape::Int(IntKind::U32)),
];
const SONOS: &[Field] = &[
    f("enabled", Shape::Bool),
    f("host", Shape::Str),
    f("room", Shape::Str),
    f("poll_secs", Shape::Int(IntKind::U32)),
    f("chip_label", Shape::Enum(&["never", "hover", "always"])),
    f("prefer_airplay", Shape::Bool),
];
const GIT_GRAPH: &[Field] = &[f("lane_spacing", Shape::Int(IntKind::U16))];
const TASK: &[Field] = &[f("cmd", Shape::Str), f("cwd", Shape::Str)];
const LAYOUT_ENTRY: &[Field] = &[
    f("kind", Shape::Enum(&["editor", "pty"])),
    f("path", Shape::Str),
    f("cmd", Shape::Str),
    f("split", Shape::Enum(&["right", "down"])),
    f("ratio", Shape::Int(IntKind::U8)),
];
const STARTUP: &[Field] = &[
    f("tasks", Shape::StrList),
    f("layout", Shape::List(&Shape::Struct(LAYOUT_ENTRY))),
    f("default_workspace", Shape::Str),
];
const FORMATTER: &[Field] = &[f("cmd", Shape::StrOrList), f("in_place", Shape::Bool)];
const LINTER: &[Field] = &[
    f("cmd", Shape::StrOrList),
    f(
        "parser",
        Shape::Enum(&["vimgrep", "eslint", "tsc", "ruff", "shellcheck", "pattern"]),
    ),
    f("pattern", Shape::Str),
];
const DAP_ADAPTER: &[Field] = &[
    f("cmd", Shape::Str),
    f("args", Shape::StrList),
    f("launch", Shape::Dynamic),
];
const BROWSER: &[Field] = &[
    f("headless", Shape::Bool),
    f("autocapture_to_log", Shape::Bool),
    f(
        "profile_mode",
        Shape::Enum(&["workspace", "shared", "ephemeral"]),
    ),
];
const CI: &[Field] = &[
    f("provider", Shape::Str),
    f("project", Shape::Str),
    f("region", Shape::Str),
];
const INTEGRATIONS: &[Field] = &[
    f("auto_update_cargo", Shape::Bool),
    f("auto_update_git", Shape::Bool),
];
const WORKSPACE: &[Field] = &[
    f("name", Shape::Str),
    f("path", Shape::Str),
    f("group", Shape::Str),
];
const MARKETPLACE: &[Field] = &[
    f("enabled", Shape::Bool),
    f("cache_ttl_secs", Shape::Int(IntKind::U32)),
    f("use_defaults", Shape::Bool),
    Field {
        toml: "source",
        zon: "sources",
        shape: Shape::MarketplaceSources,
    },
    f("show_dev_tab", Shape::Bool),
];
const CLOUD_RUN_DEFAULTS: &[Field] = &[
    f("agent_id", Shape::Str),
    f("env_id", Shape::Str),
    f("sandbox", Shape::Str),
    f("model", Shape::Str),
];
const CLOUD_RUN: &[Field] = &[f("defaults", Shape::Struct(CLOUD_RUN_DEFAULTS))];
const CLOUD_AGENTS: &[Field] = &[
    f("label", Shape::Str),
    f("short_id", Shape::Str),
    f("region", Shape::Str),
    f("account_id", Shape::Str),
    f("runs_table", Shape::Str),
    f("cluster", Shape::Str),
    f("task_definition", Shape::Str),
    f("sg_export_name", Shape::Str),
    f("log_group", Shape::Str),
    f("aws_profile_fallback", Shape::Str),
    f("s3_artifacts_bucket", Shape::Str),
    f("default_workspace_label", Shape::Str),
    f("managed_agents_enabled", Shape::Bool),
];

/// The top level, in the section order of mnml-zig's `docs/CONFIG.md`.
const ROOT: &[Field] = &[
    f("editor", Shape::Struct(EDITOR)),
    f("ui", Shape::Struct(UI)),
    f("session", Shape::Struct(SESSION)),
    f("ipc", Shape::Struct(IPC)),
    f("keys", Shape::Struct(KEYS)),
    f("lsp", Shape::Map(&Shape::Struct(LSP_SERVER))),
    f("ai", Shape::StructExtra(AI)),
    f("tools", Shape::Dynamic),
    f("http", Shape::Struct(HTTP)),
    f("ws", Shape::Struct(WS)),
    f("sonos", Shape::Struct(SONOS)),
    f("git_graph", Shape::Struct(GIT_GRAPH)),
    f("tasks", Shape::Map(&Shape::Struct(TASK))),
    f("startup", Shape::Struct(STARTUP)),
    f("snippets", Shape::Map(&Shape::Map(&Shape::Str))),
    f("abbr", Shape::Map(&Shape::Str)),
    f("formatters", Shape::Map(&Shape::Struct(FORMATTER))),
    f("linters", Shape::Map(&Shape::Struct(LINTER))),
    f("dap", Shape::Map(&Shape::Struct(DAP_ADAPTER))),
    f("browser", Shape::Struct(BROWSER)),
    f("ci", Shape::Struct(CI)),
    f("integrations", Shape::Struct(INTEGRATIONS)),
    f("workspaces", Shape::List(&Shape::Struct(WORKSPACE))),
    f("marketplace", Shape::Struct(MARKETPLACE)),
    f("cloud_run", Shape::Struct(CLOUD_RUN)),
    f("cloud_agents", Shape::Struct(CLOUD_AGENTS)),
];

/// Integration ids the 0.2.x loader drops on every load (retired
/// chips). Same list as `config::DEAD_INTEGRATION_IDS`; duplicated
/// here because that one is private to the loader and the exporter
/// must not depend on loader internals.
const DEAD_INTEGRATION_IDS: &[&str] = &["bitbucket", "linear", "gitlab", "cypress", "slack"];

// ─── docs ────────────────────────────────────────────────────────────────

/// One line per ZON key — the comment written above it. Keyed by ZON
/// path with `*` for a map entry (`lsp.*.cmd`) or a list element
/// (`workspaces.*.path`). The text is mnml-zig's `docs/CONFIG.md`
/// comment where that file has one, and a short description otherwise.
const DOCS: &[(&str, &str)] = &[
    // editor
    ("editor.input_style", ".vim | .standard"),
    ("editor.tab_width", "Spaces per tab stop."),
    ("editor.autosave_secs", "0 = off"),
    (
        "editor.trim_trailing_ws_on_save",
        "Strip trailing whitespace when a file is saved.",
    ),
    (
        "editor.breadcrumb",
        "Show the file / symbol breadcrumb above the editor.",
    ),
    (
        "editor.auto_pair",
        "Insert the closing bracket / quote with the opening one.",
    ),
    (
        "editor.auto_indent",
        "Carry the previous line's indent onto a new line.",
    ),
    (
        "editor.format_on_save",
        "Run the extension's formatter on save.",
    ),
    (
        "editor.will_save_wait_until",
        "Let the language server edit the buffer before a save.",
    ),
    (
        "editor.format_on_type",
        "Ask the language server to format as you type.",
    ),
    (
        "editor.autosave_on_focus_loss",
        "Save every dirty buffer when the terminal loses focus.",
    ),
    (
        "editor.inlay_hints",
        "Show the language server's inlay hints.",
    ),
    ("editor.cursor_blink", "Blink the cursor."),
    (
        "editor.semantic_tokens_viewport",
        "Request semantic tokens for the visible range only.",
    ),
    (
        "editor.semantic_tokens",
        "Lay a server's semantic tokens over the syntax highlighting.",
    ),
    (
        "editor.code_lens",
        "Show code lenses (run / test / references).",
    ),
    ("editor.text_width", "Column `gq` wraps at."),
    (
        "editor.ensure_trailing_newline",
        "Make sure a saved file ends in a newline.",
    ),
    (
        "editor.chord_timeout_ms",
        "vim's timeoutlen; clamped to 100..5000",
    ),
    ("editor.wheel_moves_cursor", ".auto | .always | .never"),
    ("editor.scroll_accel", ".off | .gentle | .normal | .fast"),
    (
        "editor.persistent_undo",
        "Keep each file's undo + redo stacks across launches.",
    ),
    (
        "editor.clipboard",
        ".auto | .os | .internal — what `\"+` / `\"*` / Ctrl+C reach",
    ),
    // ui
    ("ui.theme", "any theme name; an open set"),
    ("ui.cmdline_popup_border_color", "\"\" = the theme's"),
    ("ui.theme_toggle", "a second theme for ui.toggle_theme"),
    (
        "ui.theme_auto_system",
        "Follow the OS light / dark appearance.",
    ),
    ("ui.ascii_icons", "Plain-text icons — no Nerd Font needed."),
    ("ui.tree_width", "clamped to 10..80"),
    ("ui.right_panel_visible", "Open the right panel on start."),
    (
        "ui.right_panel_width",
        "Width of the right panel, in cells.",
    ),
    ("ui.auto_hide_narrow_width", "0 = never auto-hide the tree"),
    (
        "ui.auto_equalize_splits",
        "Re-balance splits when one opens or closes.",
    ),
    (
        "ui.relative_line_numbers",
        "Line numbers relative to the cursor line.",
    ),
    ("ui.line_numbers", "Show line numbers."),
    ("ui.cursor_line", "Highlight the cursor's line."),
    (
        "ui.scrolloff",
        "Lines kept above / below the cursor when scrolling.",
    ),
    (
        "ui.sidescrolloff",
        "Columns kept left / right of the cursor when scrolling.",
    ),
    ("ui.show_whitespace", "Render spaces and tabs visibly."),
    ("ui.bracket_rainbow", "Color nested brackets by depth."),
    (
        "ui.tree_preview_on_arrow",
        "Arrowing through the tree previews the file.",
    ),
    ("ui.syntax", "Syntax highlighting."),
    ("ui.scrollbar", "Show the editor scrollbar."),
    ("ui.wheel_lines", "lines per wheel notch"),
    ("ui.highlight_trailing_ws", "Highlight trailing whitespace."),
    ("ui.clock", "Show a clock in the statusline."),
    (
        "ui.stress_meter",
        "Show the stress meter in the statusline.",
    ),
    (
        "ui.check_updates",
        "Ask GitHub for the newest release once per launch.",
    ),
    ("ui.activity_bar_pinned_integrations", "integration ids"),
    ("ui.plus_menu_pinned", "Command ids pinned to the + menu."),
    ("ui.plus_menu_hidden", "Command ids hidden from the + menu."),
    ("ui.auto_refresh_off", "panel ids whose auto-refresh is off"),
    ("ui.sessions_sort", ".auto | .manual"),
    ("ui.todos_sort", ".newest | .oldest | .name | .name_desc"),
    ("ui.notes_sort", ".newest | .oldest | .name | .name_desc"),
    ("ui.findings_sort", ".newest | .oldest | .name | .name_desc"),
    ("ui.statusline_segment_order", ".{} = the built-in order"),
    (
        "ui.highlight_word_under_cursor",
        "Highlight every occurrence of the word under the cursor.",
    ),
    (
        "ui.auto_md_preview",
        "Open a markdown preview beside a markdown file automatically.",
    ),
    ("ui.color_column", "0 = off"),
    ("ui.wrap", "Soft-wrap long lines."),
    (
        "ui.highlight_todo_keywords",
        "Highlight TODO / FIXME markers in comments.",
    ),
    ("ui.todo_keywords", "Markers the TODOS panel scans for."),
    (
        "ui.render_markdown",
        "Render markdown inline in the editor.",
    ),
    (
        "ui.markdown_opens_rendered",
        "Open markdown files in the rendered view first.",
    ),
    (
        "ui.always_show_fold_arrows",
        "Show fold arrows even where nothing folds.",
    ),
    (
        "ui.sticky_context",
        "Pin the enclosing scope's header at the top of the editor.",
    ),
    ("ui.md_image_rows", "Rows an inline markdown image takes."),
    ("ui.git_graph_branch_col", "null = auto width"),
    ("ui.git_graph_author_col", "null = auto width"),
    ("ui.git_graph_detail_col", "null = auto width"),
    ("ui.picker_position", ".center | .top"),
    (
        "ui.integration_icons",
        "The activity-bar icon strip. Omit to keep the three built-ins (browser, claude_code, codex); set it to replace them.",
    ),
    ("ui.integration_icons.*.id", "Integration id."),
    ("ui.integration_icons.*.glyph", "Nerd Font glyph."),
    (
        "ui.integration_icons.*.fallback",
        "Plain-text stand-in for --ascii.",
    ),
    (
        "ui.integration_icons.*.command",
        "Command id the click fires.",
    ),
    ("ui.integration_icons.*.color", "Chip color."),
    (
        "ui.integration_icons.*.label",
        "Label shown beside the chip.",
    ),
    ("ui.integration_icons.*.enabled", "Show the chip."),
    (
        "ui.integration_icons.*.in_palette_bar",
        "Also show it in the palette bar.",
    ),
    (
        "ui.integration_icons.*.description",
        "One line for the Installed tab.",
    ),
    ("ui.integration_icons.*.homepage", "Project homepage."),
    ("ui.integration_icons.*.docs", "Documentation URL."),
    ("ui.integration_icons.*.repository", "Source repository."),
    ("ui.integration_icons.*.author", "Author."),
    ("ui.integration_icons.*.version", "Version string."),
    (
        "ui.integration_icons.*.commands",
        ".{ .{ .id = \"x.y\", .title = \"…\" } }",
    ),
    ("ui.integration_icons.*.commands.*.id", "Command id."),
    ("ui.integration_icons.*.commands.*.title", "Palette title."),
    ("ui.integration_icon_order", "ids, left to right"),
    ("ui.ticket_prefixes", "e.g. .{ \"TE\", \"OPS\" }"),
    ("ui.now_playing_source", ".auto | .mixr | .macos"),
    ("ui.now_playing_marquee", "Scroll a long now-playing title."),
    ("ui.preferred_music_app", ".mixr | .music | .spotify"),
    (
        "ui.mixr_auto_play_on_open",
        "Start playback when mixr opens.",
    ),
    ("ui.projects_dir", "\"~/code\"; ~ is expanded"),
    ("ui.menu_bar", ".always | .auto | .hidden"),
    ("ui.bufferline_diag_style", ".count | .dot | .off"),
    (
        "ui.coverage_chip_mode",
        ".both | .feature | .code | .ticker",
    ),
    ("ui.expand_indicator", ".chevron | .triangle"),
    ("ui.hover_help_height", "clamped to 3..20"),
    ("ui.terminal_label", "Label for terminal tabs."),
    (
        "ui.external_browser",
        "a program to spawn; \"\" = the OS default (exec-bearing)",
    ),
    (
        "ui.terminal_glyph_svg",
        "SVG baked into the terminal tab glyph.",
    ),
    ("ui.top_bar_cluster_mode", ".auto | .expanded | .compact"),
    (
        "ui.tab_bar_ai_icon",
        ".none | .claude_code | .codex | .both",
    ),
    ("ui.ai_layout_mode", ".grid | .tabs"),
    (
        "ui.ai_chip_use_mnml_glyphs",
        "Use mnml's own baked glyphs for the AI chips.",
    ),
    (
        "ui.auto_show_sessions_on_ai_activate",
        "Open the SESSIONS panel when an AI session starts.",
    ),
    (
        "ui.git_section_default_expanded",
        "Start with the rail's GIT section expanded.",
    ),
    (
        "ui.integrations_section_default_expanded",
        "Start with the rail's INTEGRATIONS section expanded.",
    ),
    ("ui.hover_help", "The bottom-left hover-help strip."),
    (
        "ui.hover_tooltip",
        "A small popup near the pointer after a hover-hold.",
    ),
    ("ui.click_echo", "Underline a clicked target for 120 ms."),
    ("ui.first_launch_complete", "set by the first-launch flow"),
    (
        "ui.show_workspace_dots",
        "● / ○ markers on workspace-root rows.",
    ),
    (
        "ui.md_preview_engine",
        ".builtin | .glow | .pandoc | .{ .custom = \"cmd\" } (exec-bearing)",
    ),
    // session / ipc
    (
        "session.restore",
        "Restore the last session's panes on open.",
    ),
    ("ipc.write_screen", "also dump screen.txt every frame"),
    // keys
    (
        "keys",
        "One line per binding: chord → command id. \"\" / \"none\" / \"unbound\" removes a default. .global applies to both profiles; .vim and .standard on top of it.",
    ),
    ("keys.global", "Bindings for both profiles."),
    ("keys.vim", "Bindings on top of .global in the vim profile."),
    (
        "keys.standard",
        "Bindings on top of .global in the standard profile.",
    ),
    // lsp
    (
        "lsp",
        "One entry per server. .cmd/.args are exec-bearing (stripped from an untrusted workspace; .extensions etc. still apply). .settings and .initialization_options are forwarded verbatim as JSON.",
    ),
    ("lsp.*.cmd", "null = mnml's built-in default"),
    ("lsp.*.args", "Arguments for .cmd (exec-bearing)."),
    ("lsp.*.extensions", "File extensions this server handles."),
    ("lsp.*.root_markers", "Files that mark a project root."),
    (
        "lsp.*.settings",
        "Forwarded verbatim as workspace/didChangeConfiguration.",
    ),
    (
        "lsp.*.initialization_options",
        "Forwarded verbatim as initialize.initializationOptions.",
    ),
    // ai
    ("ai.backend", "legacy; .auto | .api | .sub | .off"),
    ("ai.routing", "Per-product backend; wins over .backend."),
    ("ai.routing.claude", "wins over .backend"),
    ("ai.routing.claude.backend", ".auto | .api | .sub | .off"),
    ("ai.routing.codex", "wins over .backend"),
    ("ai.routing.codex.backend", ".auto | .api | .sub | .off"),
    ("ai.launch_profiles", "Named ways to start claude / codex."),
    ("ai.launch_profiles.*.name", "Profile name."),
    ("ai.launch_profiles.*.product", ".claude | .codex"),
    (
        "ai.launch_profiles.*.binary",
        "An executable path or a name on PATH.",
    ),
    ("ai.launch_profiles.*.args", "Arguments."),
    (
        "ai.launch_profiles.*.env",
        "KEY=VALUE lines, exported by the shim.",
    ),
    (
        "ai.launch_profiles.*.cwd_mode",
        ".workspace | .home | .file_dir",
    ),
    (
        "ai.default_profile",
        "The default launch profile per product.",
    ),
    ("ai.default_profile.claude", "null = the built-in."),
    ("ai.default_profile.codex", "null = the built-in."),
    (
        "ai.inline_suggestions",
        "Inline AI completions in the editor.",
    ),
    (
        "ai.claude_show_all_accounts",
        "Show every Claude account on the statusline chip.",
    ),
    ("ai.claude_meter_mode", ".off | .compact | .ticker"),
    // tools
    (
        "tools",
        "Forwarded verbatim to integrations; mnml reads nothing here.",
    ),
    // http / ws
    ("http.default_env", "name of the env in .env files"),
    ("http.collection_root", ".hidden (.rqst/) | .workspace"),
    ("http.auto_format_body", "Pretty-print a response body."),
    ("http.sync_normalize", "Normalize request files on sync."),
    (
        "ws.subprotocols",
        "Sec-WebSocket-Protocol values offered on connect.",
    ),
    ("ws.ping_interval_secs", "Seconds between keep-alive pings."),
    (
        "ws.reconnect_max_attempts",
        "Reconnect attempts before giving up.",
    ),
    // sonos
    ("sonos.enabled", "Look for a Sonos system."),
    ("sonos.host", "null = discover"),
    ("sonos.room", "Room to control; null = the first found."),
    ("sonos.poll_secs", "Seconds between now-playing polls."),
    ("sonos.chip_label", ".never | .hover | .always"),
    (
        "sonos.prefer_airplay",
        "Prefer the AirPlay route when both are available.",
    ),
    // git_graph
    ("git_graph.lane_spacing", "Columns between graph lanes."),
    // tasks / startup
    ("tasks.*.cmd", "Shell command, run under $SHELL -c."),
    ("tasks.*.cwd", "Working directory; null = the workspace."),
    ("startup.tasks", "task names to run on open (exec-bearing)"),
    (
        "startup.layout",
        "Panes to open. The first entry needs no .split; every later one does. .kind = .pty runs .cmd under $SHELL -c (exec-bearing).",
    ),
    ("startup.layout.*.kind", ".editor | .pty"),
    ("startup.layout.*.path", ".editor — the file to open"),
    ("startup.layout.*.cmd", ".pty — the command to run"),
    (
        "startup.layout.*.split",
        ".right | .down; required after the first entry",
    ),
    ("startup.layout.*.ratio", "percent of the parent, 1..99"),
    (
        "startup.default_workspace",
        "\"~/code/mnml\"; ~ is expanded",
    ),
    // snippets / abbr
    ("snippets", "Per-scope snippet bodies."),
    ("snippets.*", "Scope: a language name, or `all`."),
    (
        "snippets.*.*",
        "Body; $1 … are tab stops, $0 the final cursor.",
    ),
    ("abbr.*", "Typed abbreviation → expansion."),
    // formatters / linters
    (
        "formatters.*.cmd",
        "argv; {file} becomes the workspace-relative path",
    ),
    (
        "formatters.*.in_place",
        "The tool rewrites {file} on disk instead of printing to stdout.",
    ),
    (
        "linters.*.cmd",
        "argv; {file} becomes the workspace-relative path",
    ),
    (
        "linters.*.parser",
        ".vimgrep (default, path:line:col: msg) | .eslint | .tsc | .ruff | .shellcheck | .pattern",
    ),
    (
        "linters.*.pattern",
        "The line template for parser = .pattern.",
    ),
    // dap
    ("dap.*.cmd", "The adapter binary (exec-bearing)."),
    ("dap.*.args", "Arguments for .cmd."),
    ("dap.*.launch", "verbatim — the launch request arguments"),
    // browser / ci / integrations
    ("browser.headless", "Launch Chrome without a window."),
    (
        "browser.autocapture_to_log",
        "Record captured traffic into the log.",
    ),
    ("browser.profile_mode", ".workspace | .shared | .ephemeral"),
    ("ci.provider", "\"codebuild\" …"),
    ("ci.project", "CI project name."),
    ("ci.region", "Provider region."),
    (
        "integrations.auto_update_cargo",
        "Auto-update cargo-installed integrations.",
    ),
    (
        "integrations.auto_update_git",
        "Auto-update git-installed integrations.",
    ),
    // workspaces
    ("workspaces", "Workspaces the picker offers."),
    ("workspaces.*.name", "Display name."),
    ("workspaces.*.path", "Root directory; ~ is expanded."),
    ("workspaces.*.group", "Picker group label."),
    // marketplace
    ("marketplace.enabled", "Show the marketplace."),
    (
        "marketplace.cache_ttl_secs",
        "Seconds the catalog is cached.",
    ),
    ("marketplace.use_defaults", "prepend mnml's own sources"),
    (
        "marketplace.sources",
        "Extra catalog sources — a tagged union per entry.",
    ),
    ("marketplace.sources.*.crates_keyword.id", "Source id."),
    (
        "marketplace.sources.*.crates_keyword.keyword",
        "crates.io keyword to list.",
    ),
    (
        "marketplace.sources.*.github_launcher_folder.id",
        "Source id.",
    ),
    (
        "marketplace.sources.*.github_launcher_folder.repo",
        "owner/repo on GitHub.",
    ),
    (
        "marketplace.sources.*.github_launcher_folder.path",
        "Folder of launcher manifests in the repo.",
    ),
    (
        "marketplace.sources.*.github_monorepo_apps.id",
        "Source id.",
    ),
    (
        "marketplace.sources.*.github_monorepo_apps.repo",
        "owner/repo on GitHub.",
    ),
    (
        "marketplace.sources.*.github_monorepo_apps.apps_dir",
        "Directory whose sub-directories are integration crates.",
    ),
    ("marketplace.show_dev_tab", "Show the Dev tab."),
    // cloud
    (
        "cloud_run.defaults",
        "Saved defaults for the Cloud Agents quick-fire flow.",
    ),
    ("cloud_run.defaults.agent_id", "Agent id."),
    ("cloud_run.defaults.env_id", "Environment id."),
    ("cloud_run.defaults.sandbox", "Sandbox name."),
    ("cloud_run.defaults.model", "Model id."),
    ("cloud_agents.label", "Label for the cloud agents section."),
    ("cloud_agents.short_id", "Short id shown on chips."),
    ("cloud_agents.region", "MNML_CLOUD_AGENTS_REGION overrides"),
    ("cloud_agents.account_id", "AWS account id."),
    ("cloud_agents.runs_table", "DynamoDB table of runs."),
    ("cloud_agents.cluster", "ECS cluster."),
    ("cloud_agents.task_definition", "ECS task definition."),
    (
        "cloud_agents.sg_export_name",
        "CloudFormation export of the security group.",
    ),
    ("cloud_agents.log_group", "CloudWatch log group."),
    (
        "cloud_agents.aws_profile_fallback",
        "MNML_AWS_PROFILE overrides",
    ),
    (
        "cloud_agents.s3_artifacts_bucket",
        "S3 bucket for run artifacts.",
    ),
    (
        "cloud_agents.default_workspace_label",
        "\"\" reads as \"cloud\"",
    ),
    (
        "cloud_agents.managed_agents_enabled",
        "Enable the managed-agents flow.",
    ),
];

/// The doc for a pass-through key under `.ai` (mnml-zig keeps it in
/// `.ai.extra`).
const AI_EXTRA_DOC: &str = "kept verbatim for the AI subsystems";

fn doc_for(doc_path: &str) -> Option<&'static str> {
    DOCS.iter().find(|(k, _)| *k == doc_path).map(|(_, d)| *d)
}

// ─── the ZON value tree ──────────────────────────────────────────────────

/// What gets printed. Built from the TOML tree, then rendered once.
enum Zon {
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    EnumLit(String),
    List(Vec<Zon>),
    /// `(key, doc, value)` — key is the raw name, quoted at print time.
    Struct(Vec<(String, Option<&'static str>, Zon)>),
}

impl Zon {
    fn is_scalar(&self) -> bool {
        !matches!(self, Zon::List(_) | Zon::Struct(_))
    }
}

// ─── conversion ──────────────────────────────────────────────────────────

struct Ctx {
    /// Keys that made it across.
    migrated: usize,
    /// Verbatim TOML that did not, nested at its original path.
    unmigrated: toml::Table,
    /// Entries whose path has a list index (no TOML home) and reasons.
    notes: Vec<String>,
}

impl Ctx {
    /// Park `value` at its TOML path. A path through a list element
    /// (`ui.integration_icon[2].tooltip`) has no TOML home, so it goes
    /// into the notes instead.
    fn unmigrate(&mut self, path: &str, value: &toml::Value, reason: Option<String>) {
        if let Some(r) = &reason {
            self.notes.push(format!("{path}: {r}"));
        }
        if path.contains('[') {
            self.notes.push(format!("{path} = {}", toml_literal(value)));
            return;
        }
        let segs: Vec<&str> = path.split('.').collect();
        let mut t = &mut self.unmigrated;
        for seg in &segs[..segs.len() - 1] {
            let entry = t
                .entry((*seg).to_string())
                .or_insert_with(|| toml::Value::Table(toml::Table::new()));
            if !entry.is_table() {
                // A scalar already sits here — cannot nest under it;
                // fall back to a note.
                self.notes.push(format!("{path} = {}", toml_literal(value)));
                return;
            }
            t = entry.as_table_mut().expect("checked is_table");
        }
        t.insert(segs[segs.len() - 1].to_string(), value.clone());
    }
}

/// A TOML value as one TOML literal (`"x"`, `1`, `[1, 2]`) — for a
/// note line. Tables print as their inline form.
fn toml_literal(v: &toml::Value) -> String {
    match v {
        toml::Value::Table(t) => {
            let items: Vec<String> = t
                .iter()
                .map(|(k, v)| format!("{k} = {}", toml_literal(v)))
                .collect();
            format!("{{ {} }}", items.join(", "))
        }
        toml::Value::Array(a) => {
            let items: Vec<String> = a.iter().map(toml_literal).collect();
            format!("[{}]", items.join(", "))
        }
        other => other.to_string(),
    }
}

fn join(path: &str, key: &str) -> String {
    if path.is_empty() {
        key.to_string()
    } else {
        format!("{path}.{key}")
    }
}

/// The transform for one value. `path` is the TOML path (for the
/// unmigrated block); `doc_path` the ZON path with `*` for map / list
/// steps (for the doc table). `None` = parked in the unmigrated block.
fn convert(
    shape: &Shape,
    v: &toml::Value,
    path: &str,
    doc_path: &str,
    ctx: &mut Ctx,
) -> Option<Zon> {
    match shape {
        Shape::Bool => match v {
            toml::Value::Boolean(b) => Some(Zon::Bool(*b)),
            _ => reject(ctx, path, v, "expected a bool"),
        },
        Shape::Int(kind) => match v {
            toml::Value::Integer(i) if kind.fits(*i) => Some(Zon::Int(*i)),
            toml::Value::Integer(_) => {
                reject(ctx, path, v, &format!("does not fit {}", kind.name()))
            }
            _ => reject(ctx, path, v, "expected an integer"),
        },
        Shape::Str => match v {
            toml::Value::String(s) => Some(Zon::Str(s.clone())),
            _ => reject(ctx, path, v, "expected a string"),
        },
        Shape::StrList => match v {
            toml::Value::Array(items) if items.iter().all(|i| i.is_str()) => Some(Zon::List(
                items
                    .iter()
                    .map(|i| Zon::Str(i.as_str().unwrap_or_default().to_string()))
                    .collect(),
            )),
            _ => reject(ctx, path, v, "expected a list of strings"),
        },
        Shape::Enum(set) => match v {
            toml::Value::String(s) => {
                let norm = s.trim().to_ascii_lowercase();
                if set.contains(&norm.as_str()) {
                    Some(Zon::EnumLit(norm))
                } else {
                    reject(ctx, path, v, &format!("not one of {}", enum_set(set)))
                }
            }
            _ => reject(ctx, path, v, &format!("expected one of {}", enum_set(set))),
        },
        Shape::Struct(fields) => convert_struct(fields, false, v, path, doc_path, ctx),
        Shape::StructExtra(fields) => convert_struct(fields, true, v, path, doc_path, ctx),
        Shape::Map(inner) => {
            let Some(t) = v.as_table() else {
                return reject(ctx, path, v, "expected a table");
            };
            let mut out = Vec::new();
            let entry_doc = format!("{doc_path}.*");
            for (k, val) in t {
                let p = join(path, k);
                if let Some(z) = convert(inner, val, &p, &entry_doc, ctx) {
                    out.push((k.clone(), doc_for(&entry_doc), z));
                }
            }
            Some(Zon::Struct(out))
        }
        Shape::List(inner) => {
            let Some(items) = v.as_array() else {
                return reject(ctx, path, v, "expected a list");
            };
            let elem_doc = format!("{doc_path}.*");
            let mut out = Vec::new();
            for (i, item) in items.iter().enumerate() {
                let p = format!("{path}[{i}]");
                if let Some(z) = convert(inner, item, &p, &elem_doc, ctx) {
                    out.push(z);
                }
            }
            Some(Zon::List(out))
        }
        Shape::Dynamic => Some(dynamic(v)),
        Shape::StrOrList => match v {
            toml::Value::String(s) => Some(Zon::List(vec![Zon::Str(s.clone())])),
            other => convert(&Shape::StrList, other, path, doc_path, ctx),
        },
        Shape::BoolOrStr => match v {
            toml::Value::Boolean(b) => Some(Zon::Bool(*b)),
            toml::Value::String(s) => match s.trim().to_ascii_lowercase().as_str() {
                "compact" | "ticker" | "true" | "on" | "yes" => {
                    ctx.notes.push(format!(
                        "{path} = {}: became `true`; the 0.2.x display mode has no bool form",
                        toml_literal(v)
                    ));
                    Some(Zon::Bool(true))
                }
                "off" | "false" | "no" | "" => Some(Zon::Bool(false)),
                _ => reject(ctx, path, v, "expected a bool"),
            },
            _ => reject(ctx, path, v, "expected a bool"),
        },
        Shape::MdEngine => match v {
            toml::Value::String(s) => {
                let t = s.trim();
                if let Some(cmd) = t.strip_prefix("custom:") {
                    Some(Zon::Struct(vec![(
                        "custom".to_string(),
                        None,
                        Zon::Str(cmd.to_string()),
                    )]))
                } else {
                    convert(
                        &Shape::Enum(&["builtin", "glow", "pandoc"]),
                        v,
                        path,
                        doc_path,
                        ctx,
                    )
                }
            }
            _ => reject(ctx, path, v, "expected a string"),
        },
        Shape::AiBackend => match v {
            toml::Value::String(s) => {
                let tag = match s.trim().to_ascii_lowercase().as_str() {
                    "auto" => "auto",
                    "api" | "http" | "direct" => "api",
                    "cli" | "sub" | "subscription" | "cc" | "claude-code" => "sub",
                    "off" | "disable" | "disabled" => "off",
                    _ => {
                        return reject(ctx, path, v, "not one of .auto | .api | .sub | .off");
                    }
                };
                Some(Zon::EnumLit(tag.to_string()))
            }
            _ => reject(ctx, path, v, "expected a string"),
        },
        Shape::CollectionRoot => match v {
            toml::Value::String(s) => {
                let tag = match s.trim().to_ascii_lowercase().as_str() {
                    "workspace" | "in_tree" | "in-tree" | "bruno" => "workspace",
                    "hidden" | ".mnml/collections" | ".mnml" | "" => "hidden",
                    _ => return reject(ctx, path, v, "not one of .hidden | .workspace"),
                };
                Some(Zon::EnumLit(tag.to_string()))
            }
            _ => reject(ctx, path, v, "expected a string"),
        },
        Shape::MarketplaceSources => {
            let Some(items) = v.as_array() else {
                return reject(ctx, path, v, "expected [[marketplace.source]] entries");
            };
            let mut out = Vec::new();
            for (i, item) in items.iter().enumerate() {
                let p = format!("{path}[{i}]");
                if let Some(z) = marketplace_source(item, &p, doc_path, ctx) {
                    out.push(z);
                }
            }
            Some(Zon::List(out))
        }
        Shape::IntegrationIcons => {
            let Some(items) = v.as_array() else {
                return reject(ctx, path, v, "expected [[ui.integration_icon]] entries");
            };
            let elem_doc = format!("{doc_path}.*");
            let mut out = Vec::new();
            for (i, item) in items.iter().enumerate() {
                let p = format!("{path}[{i}]");
                let id = item.get("id").and_then(|v| v.as_str()).unwrap_or("");
                if DEAD_INTEGRATION_IDS.contains(&id) {
                    ctx.notes
                        .push(format!("{p}: dropped — \"{id}\" is a retired integration"));
                    continue;
                }
                let mut item = item.clone();
                if let Some(t) = item.as_table_mut()
                    && let Some(g) = t.get("glyph").and_then(|g| g.as_str())
                    && let Some(new) = remap_legacy_glyph(id, g)
                {
                    t.insert("glyph".to_string(), toml::Value::String(new));
                }
                if let Some(z) = convert_struct(INTEGRATION_ICON, false, &item, &p, &elem_doc, ctx)
                {
                    out.push(z);
                }
            }
            Some(Zon::List(out))
        }
    }
}

fn reject(ctx: &mut Ctx, path: &str, v: &toml::Value, reason: &str) -> Option<Zon> {
    ctx.unmigrate(path, v, Some(reason.to_string()));
    None
}

fn enum_set(set: &[&str]) -> String {
    set.iter()
        .map(|s| format!(".{s}"))
        .collect::<Vec<_>>()
        .join(" | ")
}

/// A fixed-field struct. Fields come out in schema order (the Zig
/// order), only those the user set. Unknown keys are unmigrated, or —
/// with `extra` — carried verbatim (mnml-zig collects them in `.extra`).
fn convert_struct(
    fields: &[Field],
    extra: bool,
    v: &toml::Value,
    path: &str,
    doc_path: &str,
    ctx: &mut Ctx,
) -> Option<Zon> {
    let Some(t) = v.as_table() else {
        return reject(ctx, path, v, "expected a table");
    };
    let mut out = Vec::new();
    for fld in fields {
        let Some(val) = t.get(fld.toml) else {
            continue;
        };
        let p = join(path, fld.toml);
        let dp = join(doc_path, fld.zon);
        if let Some(z) = convert(&fld.shape, val, &p, &dp, ctx) {
            if z.is_scalar() {
                ctx.migrated += 1;
            }
            out.push((fld.zon.to_string(), doc_for(&dp), z));
        }
    }
    for (k, val) in t {
        if fields.iter().any(|f| f.toml == k) {
            continue;
        }
        let p = join(path, k);
        if extra {
            ctx.migrated += 1;
            out.push((k.clone(), Some(AI_EXTRA_DOC), dynamic(val)));
        } else {
            ctx.unmigrate(&p, val, None);
        }
    }
    Some(Zon::Struct(out))
}

/// A verbatim value tree — `Dynamic` on the Zig side.
fn dynamic(v: &toml::Value) -> Zon {
    match v {
        toml::Value::String(s) => Zon::Str(s.clone()),
        toml::Value::Integer(i) => Zon::Int(*i),
        toml::Value::Float(f) => Zon::Float(*f),
        toml::Value::Boolean(b) => Zon::Bool(*b),
        toml::Value::Datetime(d) => Zon::Str(d.to_string()),
        toml::Value::Array(a) => Zon::List(a.iter().map(dynamic).collect()),
        toml::Value::Table(t) => Zon::Struct(
            t.iter()
                .map(|(k, v)| (k.clone(), None, dynamic(v)))
                .collect(),
        ),
    }
}

/// `[[marketplace.source]] type = "crates_keyword" keyword = "…"` →
/// `.{ .crates_keyword = .{ .keyword = "…" } }`.
fn marketplace_source(v: &toml::Value, path: &str, doc_path: &str, ctx: &mut Ctx) -> Option<Zon> {
    const CRATES: &[Field] = &[f("id", Shape::Str), f("keyword", Shape::Str)];
    const LAUNCHER: &[Field] = &[
        f("id", Shape::Str),
        f("repo", Shape::Str),
        f("path", Shape::Str),
    ];
    const MONOREPO: &[Field] = &[
        f("id", Shape::Str),
        f("repo", Shape::Str),
        f("apps_dir", Shape::Str),
    ];
    let Some(t) = v.as_table() else {
        return reject(ctx, path, v, "expected a table");
    };
    let Some(kind) = t.get("type").and_then(|k| k.as_str()) else {
        return reject(ctx, path, v, "missing `type`");
    };
    let (tag, fields): (&str, &[Field]) = match kind.trim().to_ascii_lowercase().as_str() {
        "crates_keyword" => ("crates_keyword", CRATES),
        "github_launcher_folder" => ("github_launcher_folder", LAUNCHER),
        "github_monorepo_apps" => ("github_monorepo_apps", MONOREPO),
        _ => {
            return reject(
                ctx,
                path,
                v,
                "type is not one of crates_keyword | github_launcher_folder | github_monorepo_apps",
            );
        }
    };
    let mut body = t.clone();
    body.remove("type");
    let inner = convert_struct(
        fields,
        false,
        &toml::Value::Table(body),
        path,
        &format!("{doc_path}.*.{tag}"),
        ctx,
    )?;
    Some(Zon::Struct(vec![(tag.to_string(), None, inner)]))
}

/// The glyph rewrites the 0.2.x loader applies on every load — old
/// codicons and purged PUA slots onto their current glyphs. Mirrors
/// the migration arms in `config.rs` `apply_file_inner` so a converted
/// file carries the glyph the user actually sees today.
fn remap_legacy_glyph(id: &str, glyph: &str) -> Option<String> {
    const AWS_F1B_REMAP: &[(char, char)] = &[
        ('\u{F1B00}', '\u{F1C0E}'), // amplify      pua-drift-ok: OLD value
        ('\u{F1B01}', '\u{F1C0A}'), // lambda       pua-drift-ok: OLD value
        ('\u{F1B02}', '\u{F1C08}'), // ecs          pua-drift-ok: OLD value
        ('\u{F1B03}', '\u{F1C07}'), // ecr          pua-drift-ok: OLD value
        ('\u{F1B04}', '\u{F1C0B}'), // rds          pua-drift-ok: OLD value
        ('\u{F1B05}', '\u{F1C0D}'), // sqs          pua-drift-ok: OLD value
        ('\u{F1B06}', '\u{F1C0C}'), // sns          pua-drift-ok: OLD value
        ('\u{F1B08}', '\u{F1C05}'), // cognito      pua-drift-ok: OLD value
        ('\u{F1B09}', '\u{F1C03}'), // cloudwatch   pua-drift-ok: OLD value
        ('\u{F1B0A}', '\u{F1C04}'), // codebuild    pua-drift-ok: OLD value
        ('\u{F1B0B}', '\u{F1C09}'), // eventbridge  pua-drift-ok: OLD value
    ];
    let new = match id {
        "claude_code" if glyph != "\u{F1E00}" => "\u{F1E00}".to_string(),
        "codex" if glyph != "\u{F1E01}" => "\u{F1E01}".to_string(),
        "http" if glyph != "\u{F1D8}" => "\u{F1D8}".to_string(),
        // pua-drift-ok: matches the OLD value
        "amplify" if glyph == "\u{F087D}" || glyph == "\u{F1B00}" => "\u{F1C0E}".to_string(),
        // pua-drift-ok: OLD value
        "btop" if glyph == "\u{F085F}" || glyph == "\u{F2000}" => "\u{F0AEF}".to_string(),
        // pua-drift-ok: OLD value
        "htop" if glyph == "\u{F085A}" || glyph == "\u{F2001}" => "\u{F0379}".to_string(),
        // pua-drift-ok: OLD value
        "iftop" if glyph == "\u{F048D}" || glyph == "\u{F2002}" => "\u{F06F3}".to_string(),
        _ => {
            let (_, new) = AWS_F1B_REMAP
                .iter()
                .find(|(old, _)| glyph.starts_with(*old))?;
            new.to_string()
        }
    };
    (new != glyph).then_some(new)
}

// ─── printing ────────────────────────────────────────────────────────────

const INDENT: &str = "    ";

/// Zig keywords and primitive type names — a field or enum tag with
/// one of these names needs the `@"…"` form. Quoting a name that did
/// not need it is always valid, so the primitive list errs long.
const ZIG_RESERVED: &[&str] = &[
    "addrspace",
    "align",
    "allowzero",
    "and",
    "anyframe",
    "anytype",
    "asm",
    "async",
    "await",
    "break",
    "callconv",
    "catch",
    "comptime",
    "const",
    "continue",
    "defer",
    "else",
    "enum",
    "errdefer",
    "error",
    "export",
    "extern",
    "fn",
    "for",
    "if",
    "inline",
    "linksection",
    "noalias",
    "noinline",
    "nosuspend",
    "opaque",
    "or",
    "orelse",
    "packed",
    "pub",
    "resume",
    "return",
    "struct",
    "suspend",
    "switch",
    "test",
    "threadlocal",
    "try",
    "union",
    "unreachable",
    "var",
    "volatile",
    "while",
    // primitives
    "anyerror",
    "anyopaque",
    "bool",
    "c_char",
    "c_int",
    "c_long",
    "c_longdouble",
    "c_longlong",
    "c_short",
    "c_uint",
    "c_ulong",
    "c_ulonglong",
    "c_ushort",
    "comptime_float",
    "comptime_int",
    "f128",
    "f16",
    "f32",
    "f64",
    "f80",
    "isize",
    "noreturn",
    "null",
    "type",
    "undefined",
    "usize",
    "void",
    "true",
    "false",
];

/// True when `s` can stand bare after `.` in ZON.
fn is_plain_ident(s: &str) -> bool {
    let mut chars = s.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return false;
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return false;
    }
    if ZIG_RESERVED.contains(&s) {
        return false;
    }
    // `u8`, `i64`, … are primitive names too.
    let rest = &s[1..];
    !((s.starts_with('u') || s.starts_with('i'))
        && !rest.is_empty()
        && rest.chars().all(|c| c.is_ascii_digit()))
}

/// `.name` or `.@"na me"`.
fn zon_name(s: &str) -> String {
    if is_plain_ident(s) {
        s.to_string()
    } else {
        format!("@{}", zon_string(s))
    }
}

/// A ZON string literal. Control characters are escaped; private-use
/// glyphs are written as `\u{…}` so the file stays readable in an
/// editor without the icon font.
pub fn zon_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => {
                out.push_str(&format!("\\x{:02x}", c as u32));
            }
            c if is_private_use(c) => out.push_str(&format!("\\u{{{:X}}}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn is_private_use(c: char) -> bool {
    matches!(c as u32, 0xE000..=0xF8FF | 0xF0000..=0xFFFFD | 0x100000..=0x10FFFD)
}

fn zon_float(f: f64) -> String {
    if f.is_nan() {
        "nan".to_string()
    } else if f.is_infinite() {
        if f > 0.0 { "inf" } else { "-inf" }.to_string()
    } else {
        format!("{f:?}")
    }
}

fn write_value(out: &mut String, z: &Zon, depth: usize) {
    match z {
        Zon::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Zon::Int(i) => out.push_str(&i.to_string()),
        Zon::Float(f) => out.push_str(&zon_float(*f)),
        Zon::Str(s) => out.push_str(&zon_string(s)),
        Zon::EnumLit(e) => {
            out.push('.');
            out.push_str(&zon_name(e));
        }
        Zon::List(items) => {
            if items.is_empty() {
                out.push_str(".{}");
                return;
            }
            let inline: Vec<String> = if items.iter().all(Zon::is_scalar) {
                items
                    .iter()
                    .map(|i| {
                        let mut s = String::new();
                        write_value(&mut s, i, depth + 1);
                        s
                    })
                    .collect()
            } else {
                Vec::new()
            };
            let inline_len: usize = inline.iter().map(|s| s.chars().count() + 2).sum();
            if !inline.is_empty() && inline_len + depth * INDENT.len() < 72 {
                out.push_str(".{ ");
                out.push_str(&inline.join(", "));
                out.push_str(" }");
                return;
            }
            out.push_str(".{\n");
            for item in items {
                push_indent(out, depth + 1);
                write_value(out, item, depth + 1);
                out.push_str(",\n");
            }
            push_indent(out, depth);
            out.push('}');
        }
        Zon::Struct(fields) => {
            if fields.is_empty() {
                out.push_str(".{}");
                return;
            }
            // A one-field struct of a scalar prints inline
            // (`.{ .custom = "cmd" }`, a marketplace tag body).
            if fields.len() == 1 && fields[0].2.is_scalar() && fields[0].1.is_none() {
                out.push_str(".{ .");
                out.push_str(&zon_name(&fields[0].0));
                out.push_str(" = ");
                write_value(out, &fields[0].2, depth + 1);
                out.push_str(" }");
                return;
            }
            out.push_str(".{\n");
            for (name, doc, value) in fields {
                if let Some(d) = doc {
                    push_indent(out, depth + 1);
                    out.push_str("// ");
                    out.push_str(d);
                    out.push('\n');
                }
                push_indent(out, depth + 1);
                out.push('.');
                out.push_str(&zon_name(name));
                out.push_str(" = ");
                write_value(out, value, depth + 1);
                out.push_str(",\n");
            }
            push_indent(out, depth);
            out.push('}');
        }
    }
}

fn push_indent(out: &mut String, depth: usize) {
    for _ in 0..depth {
        out.push_str(INDENT);
    }
}

/// `// ── name ───…` filled to 74 columns, like `docs/CONFIG.md`.
fn section_header(name: &str) -> String {
    let lead = format!("// ── {name} ");
    let fill = 74usize.saturating_sub(lead.chars().count());
    format!("{lead}{}", "─".repeat(fill))
}

// ─── entry points ────────────────────────────────────────────────────────

/// What an export produced, for the CLI summary and the tests.
#[derive(Debug)]
pub struct Export {
    /// The ZON text, ready to write.
    pub zon: String,
    /// Leaf values carried across.
    pub migrated: usize,
    /// Notes + parked keys in the trailing block.
    pub unmigrated: usize,
}

/// Convert one TOML document to ZON. Never fails on content — every
/// key either migrates or lands in the trailing `// unmigrated:` block.
/// Only a TOML syntax error is an `Err`.
pub fn export_toml_to_zon(toml_src: &str) -> Result<Export, String> {
    let root: toml::Table = toml::from_str(toml_src).map_err(|e| format!("not valid TOML: {e}"))?;
    let mut ctx = Ctx {
        migrated: 0,
        unmigrated: toml::Table::new(),
        notes: Vec::new(),
    };

    let mut sections: Vec<(&'static str, Zon)> = Vec::new();
    for fld in ROOT {
        let Some(v) = root.get(fld.toml) else {
            continue;
        };
        if let Some(z) = convert(&fld.shape, v, fld.toml, fld.zon, &mut ctx) {
            // An empty `[section]` table carries nothing worth a block.
            let empty = matches!(&z, Zon::Struct(f) if f.is_empty());
            if !empty || matches!(fld.shape, Shape::Dynamic) {
                sections.push((fld.zon, z));
            }
        }
    }
    for (k, v) in &root {
        if !ROOT.iter().any(|f| f.toml == k) {
            ctx.unmigrate(k, v, None);
        }
    }

    let mut out = String::new();
    out.push_str("// mnml config — converted from config.toml by `mnml export-config-zon`.\n");
    out.push_str("// Keys that could not be placed are listed at the end under `unmigrated`.\n");
    out.push_str(".{\n");
    for (i, (name, z)) in sections.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        push_indent(&mut out, 1);
        out.push_str(&section_header(name));
        out.push('\n');
        if let Some(d) = doc_for(name) {
            push_indent(&mut out, 1);
            out.push_str("// ");
            out.push_str(d);
            out.push('\n');
        }
        push_indent(&mut out, 1);
        out.push('.');
        out.push_str(&zon_name(name));
        out.push_str(" = ");
        write_value(&mut out, z, 1);
        out.push_str(",\n");
    }
    out.push_str("}\n");

    let parked = if ctx.unmigrated.is_empty() {
        String::new()
    } else {
        toml::to_string(&ctx.unmigrated).unwrap_or_else(|e| format!("# could not render: {e}"))
    };
    let unmigrated = ctx.notes.len() + parked.lines().filter(|l| l.contains('=')).count();
    if unmigrated > 0 {
        out.push_str("\n// unmigrated:\n");
        for n in &ctx.notes {
            out.push_str("// note: ");
            out.push_str(n);
            out.push('\n');
        }
        for line in parked.lines() {
            out.push_str(if line.is_empty() { "//" } else { "// " });
            out.push_str(line);
            out.push('\n');
        }
    }

    Ok(Export {
        zon: out,
        migrated: ctx.migrated,
        unmigrated,
    })
}

/// Read `src`, convert, write `out`. Refuses to overwrite an existing
/// `out` unless `force`. The TOML is left untouched.
pub fn export_file(src: &Path, out: &Path, force: bool) -> Result<Export, String> {
    let text =
        std::fs::read_to_string(src).map_err(|e| format!("cannot read {}: {e}", src.display()))?;
    let export = export_toml_to_zon(&text).map_err(|e| format!("{}: {e}", src.display()))?;
    if out.exists() && !force {
        return Err(format!(
            "{} exists — pass --force to overwrite it",
            out.display()
        ));
    }
    if let Some(dir) = out.parent()
        && !dir.as_os_str().is_empty()
    {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    std::fs::write(out, &export.zon).map_err(|e| format!("cannot write {}: {e}", out.display()))?;
    Ok(export)
}

/// Where the ZON goes when `--out` is not given: `config.zon` beside
/// the source file.
pub fn default_out_path(src: &Path) -> std::path::PathBuf {
    src.with_file_name("config.zon")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_identifiers_stay_bare_and_the_rest_get_quoted() {
        assert_eq!(zon_name("ctrl_p"), "ctrl_p");
        assert_eq!(zon_name("ctrl+p"), "@\"ctrl+p\"");
        assert_eq!(zon_name("space f f"), "@\"space f f\"");
        assert_eq!(zon_name("test"), "@\"test\"");
        assert_eq!(zon_name("fn"), "@\"fn\"");
        assert_eq!(zon_name("u8"), "@\"u8\"");
        assert_eq!(zon_name("rs"), "rs");
        assert_eq!(zon_name("1abc"), "@\"1abc\"");
    }

    #[test]
    fn strings_escape_control_chars_and_private_use_glyphs() {
        assert_eq!(zon_string("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"");
        assert_eq!(zon_string("\u{F1E00}"), "\"\\u{F1E00}\"");
        assert_eq!(zon_string("\u{1b}x"), "\"\\x1bx\"");
        assert_eq!(zon_string("héllo ✳"), "\"héllo ✳\"");
    }

    #[test]
    fn only_the_keys_the_user_set_are_emitted() {
        let e = export_toml_to_zon("[editor]\ninput_style = \"vim\"\n").unwrap();
        assert!(e.zon.contains(".input_style = .vim,"));
        assert!(!e.zon.contains("tab_width"), "a default leaked:\n{}", e.zon);
        assert!(
            !e.zon.contains(".ui ="),
            "an unset section leaked:\n{}",
            e.zon
        );
        assert_eq!(e.migrated, 1);
        assert_eq!(e.unmigrated, 0);
        assert!(!e.zon.contains("// unmigrated:"));
    }

    #[test]
    fn a_bad_enum_value_is_parked_not_emitted() {
        let e = export_toml_to_zon("[editor]\ninput_style = \"emacs\"\n").unwrap();
        assert!(!e.zon.contains(".emacs"), "{}", e.zon);
        assert!(e.zon.contains("// unmigrated:"));
        assert!(
            e.zon
                .contains("// note: editor.input_style: not one of .vim | .standard")
        );
        assert!(e.zon.contains("// [editor]\n// input_style = \"emacs\""));
    }

    #[test]
    fn empty_toml_is_an_empty_struct() {
        let e = export_toml_to_zon("").unwrap();
        assert!(e.zon.ends_with(".{\n}\n"), "{}", e.zon);
    }

    #[test]
    fn invalid_toml_is_an_error() {
        assert!(export_toml_to_zon("[editor\nx = ").is_err());
    }

    #[test]
    fn legacy_glyphs_remap_and_retired_ids_drop() {
        // The OLD values, the ones being migrated away from. One
        // binding per line so the marker stays on the codepoint's line
        // through any rustfmt reflow.
        let old_amplify = "\u{F1B00}"; // pua-drift-ok: OLD value
        let old_lambda = "\u{F1B01}"; // pua-drift-ok: OLD value
        assert_eq!(
            remap_legacy_glyph("amplify", old_amplify).as_deref(),
            Some("\u{F1C0E}")
        );
        assert_eq!(
            remap_legacy_glyph("lambda", old_lambda).as_deref(),
            Some("\u{F1C0A}")
        );
        assert_eq!(remap_legacy_glyph("codex", "\u{F1E01}"), None);
        assert_eq!(remap_legacy_glyph("jira", "J"), None);
        let e = export_toml_to_zon(
            "[[ui.integration_icon]]\nid = \"slack\"\n[[ui.integration_icon]]\nid = \"jira\"\nenabled = true\n",
        )
        .unwrap();
        assert!(!e.zon.contains(".id = \"slack\""));
        assert!(e.zon.contains(".id = \"jira\""));
        assert!(
            e.zon
                .contains("dropped — \"slack\" is a retired integration")
        );
    }
}
