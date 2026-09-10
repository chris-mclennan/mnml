//! The typed config schema (E1). `Config{}` is the shipped default —
//! every field has one, every stringly-typed choice in the Rust config
//! is a real `enum` here, and the six user-keyed sections are `Map`s.
//!
//! Ownership: a loaded `Config` borrows every string, slice and map
//! table from the arena `load.Loaded` owns. `Config{}` borrows nothing
//! (literals only), so the default needs no arena at all.
//!
//! Field names are the ZON keys. Where the Rust file used a different
//! spelling the ZON one wins: `abbreviations` → `.abbr` (the section
//! was always `[abbr]` on disk), `startup_tasks` / `startup_layout` /
//! `default_workspace` → `.startup.{tasks,layout,default_workspace}`.

const std = @import("std");
const map = @import("map.zig");
const dynamic = @import("Dynamic.zig");

pub const Map = map.Map;
pub const Dynamic = dynamic.Dynamic;

const Config = @This();

editor: Editor = .{},
ui: Ui = .{},
session: Session = .{},
ipc: Ipc = .{},
cloud_run: CloudRun = .{},
jira: Jira = .{},
cloud_agents: CloudAgents = .{},
keys: Keys = .{},
lsp: Map(LspServer) = .empty,
ai: Ai = .{},
/// Forwarded verbatim to integrations; mnml itself reads nothing here.
tools: Dynamic = .empty_object,
http: Http = .{},
ws: Ws = .{},
sonos: Sonos = .{},
git_graph: GitGraph = .{},
git: Git = .{},
tasks: Map(Task) = .empty,
startup: Startup = .{},
snippets: Map(Map([]const u8)) = .empty,
abbr: Map([]const u8) = .empty,
formatters: Map(Formatter) = .empty,
linters: Map(Linter) = .empty,
dap: Map(DapAdapter) = .empty,
browser: Browser = .{},
ci: Ci = .{},
integrations: Integrations = .{},
workspaces: []const Workspace = &.{},
marketplace: Marketplace = .{},

// ─── editor ──────────────────────────────────────────────────────────────

pub const InputStyle = enum { vim, standard };
pub const LspMissingDefaults = enum { quiet, toast, ignore };
pub const WheelMovesCursor = enum { auto, always, never };
pub const ScrollAccel = enum { off, gentle, normal, fast };

pub const chord_timeout_ms_min: u16 = 100;
pub const chord_timeout_ms_max: u16 = 5000;

pub const Editor = struct {
    input_style: InputStyle = .standard,
    tab_width: u8 = 4,
    /// 0 disables.
    autosave_secs: u32 = 0,
    trim_trailing_ws_on_save: bool = false,
    breadcrumb: bool = true,
    auto_pair: bool = true,
    auto_indent: bool = true,
    format_on_save: bool = false,
    will_save_wait_until: bool = false,
    format_on_type: bool = false,
    autosave_on_focus_loss: bool = false,
    inlay_hints: bool = true,
    /// // changed (lsp-defaults): a built-in default server (`lsp/client.zig`'s
    /// table, not a `.lsp.<name>` of your own) that is not on PATH.
    /// `.quiet` records it once per session — the LSP chip counts it and
    /// its menu offers the install — with no toast; `.toast` warns as a
    /// configured server does; `.ignore` says nothing anywhere. A server
    /// you named in `.lsp` always toasts: you asked for it.
    lsp_missing_defaults: LspMissingDefaults = .quiet,
    /// // changed (debug-ui): while the debugger is stopped, the values
    /// of the scope's variables named on a line paint after its text.
    inline_values: bool = true,
    cursor_blink: bool = false,
    semantic_tokens_viewport: bool = false,
    // changed: the Rust config had only the viewport switch; the layer
    // itself had no off. `semantic_tokens` is the master switch —
    // off leaves the tree-sitter paint alone.
    /// Lay a server's semantic tokens over the syntax highlighting.
    semantic_tokens: bool = true,
    code_lens: bool = true,
    text_width: u16 = 80,
    ensure_trailing_newline: bool = true,
    /// Vim's `timeoutlen`; clamped to `chord_timeout_ms_min..max` on load.
    chord_timeout_ms: u16 = 500,
    wheel_moves_cursor: WheelMovesCursor = .auto,
    scroll_accel: ScrollAccel = .normal,
    // changed: the Rust config had no switch for persistent undo (it was
    // always on, `.mnml/undo/<hash>.json`). mnml-zig keeps the history
    // under the data root and behind a flag, off by default: a history
    // file per edited file is a surprise for a first launch.
    /// Keep each file's undo + redo stacks in `<data root>/undo/` across
    /// launches (`undo_store.zig`).
    persistent_undo: bool = false,
    // changed: the Rust build always went through arboard — the unnamed
    // register was the OS clipboard, unconditionally. mnml-zig makes it a
    // switch: `"+` / `"*` (and the standard profile's Ctrl+C/X/V) reach
    // the OS through OSC 52 or a clipboard tool; `.internal` never
    // touches it. `src/core/clipboard_os.zig`.
    /// `.auto`: OSC 52 on a live terminal, else a tool (pbcopy, wl-copy,
    /// xclip, xsel, clip.exe), else in-process registers only. `.os`:
    /// prefer the tool (it can read back), then OSC 52. `.internal`:
    /// registers only.
    clipboard: Clipboard = .auto,
};

pub const Clipboard = enum { auto, os, internal };

// ─── ui ──────────────────────────────────────────────────────────────────

pub const ListSort = enum { newest, oldest, name, name_desc };
pub const SessionsSort = enum { auto, manual };
pub const PickerPosition = enum { center, top };
pub const NowPlayingSource = enum { auto, mixr, macos };
pub const MusicApp = enum { mixr, music, spotify };
pub const MenuBar = enum { always, auto, hidden };
/// // changed: the Rust activity bar had one mode (its header carried
/// a TODO for these three, with the menu bar's vocabulary). `auto`
/// shows the rail while the pointer is in column 0 or on the rail.
pub const ActivityBar = enum { always, auto, hidden };
/// // changed (debug-ui): the step toolbar strip over the editor —
/// `auto` while a debug session is live, `always`, or never.
pub const DebugToolbar = enum { auto, always, hidden };
/// // changed (section-side): which column an activity section lives
/// in. `ui.sidebar_side` is the side sections take when nothing says
/// otherwise; `ui.section_side` overrides it per section.
pub const Side = enum { left, right };
/// One optional side per section that owns a column surface (the tree,
/// git mode's palette, a list panel). The field names are the rail's
/// section tags; a pane-backed section (search, debug, …) has no side.
/// // changed (section-side): a typed struct, not a map — `std.zon`
/// has no map type, and the loader's `Patch` overlays it field by field.
pub const SectionSide = struct {
    explorer: ?Side = null,
    git: ?Side = null,
    sessions: ?Side = null,
    http: ?Side = null,
    notes: ?Side = null,
    todos: ?Side = null,
    findings: ?Side = null,
    scripts: ?Side = null,
    diagnostics: ?Side = null,
    outline: ?Side = null,
};
pub const DiagStyle = enum { count, dot, off };
pub const CoverageChipMode = enum { both, feature, code, ticker };
pub const ExpandIndicator = enum { chevron, triangle };
pub const TopBarClusterMode = enum { auto, expanded, compact };
pub const TabBarAiIcon = enum { none, claude_code, codex, both };
pub const AiLayoutMode = enum { grid, tabs };

/// `.builtin` / `.glow` / `.pandoc` are vetted paths; `.{ .custom = "cmd" }`
/// runs `cmd` and is therefore exec-bearing (see `trust.zig`).
pub const MdEngine = union(enum) {
    builtin,
    glow,
    pandoc,
    custom: []const u8,
};

pub const tree_width_min: u16 = 10;
pub const tree_width_max: u16 = 80;
pub const hover_help_height_min: u16 = 3;
pub const hover_help_height_max: u16 = 20;

pub const Ui = struct {
    theme: []const u8 = "onedark",
    cmdline_popup_border_color: []const u8 = "",
    theme_toggle: ?[]const u8 = null,
    theme_auto_system: bool = false,
    ascii_icons: bool = false,
    /// Clamped to `tree_width_min..max` on load.
    tree_width: u16 = 30,
    /// The right column opens at start (on the last section it showed,
    /// else the first section whose side is right).
    right_panel_visible: bool = false,
    /// The right column's width (Rust's right panel: 32); `tree_width`
    /// is the left column's.
    right_panel_width: u16 = 32,
    /// // changed (section-side): the side a section takes when
    /// `section_side` does not name it. The Rust right-panel panes
    /// (outline, diagnostics) take the other side.
    sidebar_side: Side = .left,
    section_side: SectionSide = .{},
    auto_hide_narrow_width: u16 = 0,
    auto_equalize_splits: bool = false,
    relative_line_numbers: bool = false,
    line_numbers: bool = true,
    cursor_line: bool = false,
    scrolloff: u16 = 0,
    sidescrolloff: u16 = 0,
    show_whitespace: bool = false,
    bracket_rainbow: bool = false,
    tree_preview_on_arrow: bool = true,
    syntax: bool = true,
    scrollbar: bool = true,
    /// Lines per wheel notch.
    wheel_lines: u8 = 3,
    highlight_trailing_ws: bool = false,
    clock: bool = true,
    stress_meter: bool = false,
    // changed: Rust's `[ui] check_updates` was missing from the schema;
    // the update check (`app/update.zig`) reads it.
    /// Ask GitHub for the newest release once per launch and toast when
    /// it is newer than this build. `MNML_NO_UPDATE_CHECK=1` also skips it.
    check_updates: bool = true,
    activity_bar_pinned_integrations: []const []const u8 = &.{},
    plus_menu_pinned: []const []const u8 = &.{},
    plus_menu_hidden: []const []const u8 = &.{},
    auto_refresh_off: []const []const u8 = &.{},
    sessions_sort: SessionsSort = .auto,
    /// // changed (sessions-merge): ring the terminal bell when a session
    /// starts waiting for input.
    session_bell: bool = false,
    todos_sort: ListSort = .newest,
    notes_sort: ListSort = .newest,
    findings_sort: ListSort = .newest,
    statusline_segment_order: []const []const u8 = &.{},
    highlight_word_under_cursor: bool = false,
    auto_md_preview: bool = false,
    /// 0 disables.
    color_column: u16 = 0,
    wrap: bool = false,
    highlight_todo_keywords: bool = false,
    // changed: the Rust scanner's marker list was a constant. The TODOS
    // panel reads this one (a marker must follow a comment opener, or
    // be a markdown list item); the `.fixme(` / `.fail(` / `.skip(`
    // test-marker scan is always on and not listed here.
    todo_keywords: []const []const u8 = &default_todo_keywords,
    render_markdown: bool = false,
    markdown_opens_rendered: bool = true,
    always_show_fold_arrows: bool = false,
    sticky_context: bool = false,
    md_image_rows: u16 = 12,
    git_graph_branch_col: ?u16 = null,
    git_graph_author_col: ?u16 = null,
    git_graph_detail_col: ?u16 = null,
    picker_position: PickerPosition = .center,
    integration_icons: []const IntegrationIcon = &default_integration_icons,
    integration_icon_order: []const []const u8 = &.{},
    ticket_prefixes: []const []const u8 = &.{},
    now_playing_source: NowPlayingSource = .mixr,
    now_playing_marquee: bool = false,
    preferred_music_app: MusicApp = .mixr,
    mixr_auto_play_on_open: bool = true,
    /// Tilde-expanded on load. Empty disables.
    projects_dir: []const u8 = "",
    menu_bar: MenuBar = .always,
    activity_bar: ActivityBar = .always,
    debug_toolbar: DebugToolbar = .auto,
    bufferline_diag_style: DiagStyle = .count,
    coverage_chip_mode: CoverageChipMode = .feature,
    expand_indicator: ExpandIndicator = .chevron,
    /// Clamped to `hover_help_height_min..max` on load.
    hover_help_height: u16 = 8,
    terminal_label: []const u8 = "terminal",
    /// A program mnml spawns — exec-bearing. Empty = the OS default.
    external_browser: []const u8 = "",
    terminal_glyph_svg: []const u8 = "",
    top_bar_cluster_mode: TopBarClusterMode = .auto,
    tab_bar_ai_icon: TabBarAiIcon = .claude_code,
    ai_layout_mode: AiLayoutMode = .grid,
    /// Deprecated, read by nothing: the AI chips always paint mnml's own
    /// baked marks (U+F1E00 / U+F1E01). Accepted so a 0.2.x config
    /// still loads.
    ai_chip_use_mnml_glyphs: bool = false,
    auto_show_sessions_on_ai_activate: bool = true,
    git_section_default_expanded: bool = false,
    integrations_section_default_expanded: bool = false,
    hover_help: bool = true,
    hover_tooltip: bool = false,
    click_echo: bool = false,
    first_launch_complete: bool = false,
    show_workspace_dots: bool = true,
    md_preview_engine: MdEngine = .builtin,
};

pub const IntegrationIconCommand = struct {
    id: []const u8 = "",
    title: []const u8 = "",
};

pub const IntegrationIcon = struct {
    id: []const u8 = "",
    glyph: []const u8 = "",
    fallback: []const u8 = "",
    command: []const u8 = "",
    color: []const u8 = "",
    label: ?[]const u8 = null,
    enabled: bool = true,
    in_palette_bar: bool = true,
    description: ?[]const u8 = null,
    homepage: ?[]const u8 = null,
    docs: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    author: ?[]const u8 = null,
    version: ?[]const u8 = null,
    commands: []const IntegrationIconCommand = &.{},
};

/// The markers the TODOS panel scans for when `ui.todo_keywords` is unset.
pub const default_todo_keywords = [_][]const u8{ "TODO", "FIXME", "XXX", "HACK", "REVIEW" };

pub const default_integration_icons = [_]IntegrationIcon{
    .{ .id = "browser", .glyph = "\u{EB01}", .fallback = "B", .command = "browser.open", .color = "blue", .label = "Browser", .enabled = true, .in_palette_bar = true },
    .{ .id = "claude_code", .glyph = "\u{F1E00}", .fallback = "\u{2733}", .command = "ai.claude_code", .color = "#D16D51", .label = "Claude Code", .enabled = false, .in_palette_bar = false },
    .{ .id = "codex", .glyph = "\u{F1E01}", .fallback = "\u{276F}_", .command = "ai.codex", .color = "cyan", .label = "Codex", .enabled = false, .in_palette_bar = false },
};

// ─── small fixed sections ────────────────────────────────────────────────

pub const Session = struct { restore: bool = true };
pub const Ipc = struct { write_screen: bool = false };

pub const CloudRunDefaults = struct {
    agent_id: []const u8 = "",
    env_id: []const u8 = "",
    sandbox: []const u8 = "",
    model: []const u8 = "",
};
pub const CloudRun = struct { defaults: CloudRunDefaults = .{} };

pub const Jira = struct {
    /// `MNML_JIRA_DOMAIN` overrides at runtime.
    domain: []const u8 = "",
    /// `MNML_JIRA_TICKET_PREFIX` overrides at runtime.
    ticket_prefix: []const u8 = "",
};

pub const CloudAgents = struct {
    label: []const u8 = "",
    short_id: []const u8 = "",
    /// `MNML_CLOUD_AGENTS_REGION` overrides at runtime.
    region: []const u8 = "",
    account_id: []const u8 = "",
    runs_table: []const u8 = "",
    cluster: []const u8 = "",
    task_definition: []const u8 = "",
    sg_export_name: []const u8 = "",
    log_group: []const u8 = "",
    /// `MNML_AWS_PROFILE` overrides at runtime.
    aws_profile_fallback: []const u8 = "",
    s3_artifacts_bucket: []const u8 = "",
    /// Empty reads as `"cloud"`.
    default_workspace_label: []const u8 = "",
    managed_agents_enabled: bool = false,
};

// ─── keys ────────────────────────────────────────────────────────────────

/// `.keys = .{ .global = .{ .@"ctrl+p" = "picker.files", .@"space f f" = "none" } }`
/// — one line per binding, chord spec → command id (`""` / `"none"` /
/// `"unbound"` remove a default). ZonGen rejects a duplicated chord.
pub const Keys = struct {
    global: Map([]const u8) = .empty,
    vim: Map([]const u8) = .empty,
    standard: Map([]const u8) = .empty,
};

// ─── lsp / dap / formatters / linters / tasks ────────────────────────────

pub const LspServer = struct {
    /// Exec-bearing. `null` = mnml's built-in default for the language.
    cmd: ?[]const u8 = null,
    /// Exec-bearing (stripped together with `cmd`).
    args: []const []const u8 = &.{},
    extensions: []const []const u8 = &.{},
    root_markers: []const []const u8 = &.{},
    /// Forwarded verbatim as `workspace/didChangeConfiguration`.
    settings: Dynamic = .empty_object,
    /// Forwarded verbatim as `initialize.initializationOptions`.
    initialization_options: Dynamic = .empty_object,
};

pub const DapAdapter = struct {
    cmd: []const u8 = "",
    args: []const []const u8 = &.{},
    /// Forwarded verbatim as the `launch` request arguments.
    launch: Dynamic = .empty_object,
};

pub const Formatter = struct {
    /// argv; the Rust config also accepted a bare string. `{file}` in
    /// an argument becomes the workspace-relative path.
    cmd: []const []const u8 = &.{},
    // changed: the Rust formatter was stdin → stdout only. A tool that
    // insists on rewriting the file (`rustfmt`, `gofmt -w`) runs with
    // `in_place`: the buffer is written, the tool runs on `{file}`, and
    // the result is read back.
    /// The tool rewrites `{file}` on disk instead of printing to stdout.
    in_place: bool = false,
};

pub const LintParser = enum { vimgrep, eslint, tsc, ruff, shellcheck, pattern };

pub const Linter = struct {
    /// argv; `{file}` becomes the workspace-relative path.
    cmd: []const []const u8 = &.{},
    parser: LintParser = .vimgrep,
    // changed: Zig has no regex in std, and a linter's line format is
    // rarely more than fields in a fixed order. `pattern` is a template
    // of placeholders — `{file}:{line}:{col}: {severity}: {message}` —
    // that `parser = .pattern` matches literally between them.
    /// The line template for `parser = .pattern`.
    pattern: []const u8 = "",
};

pub const Task = struct {
    cmd: []const u8 = "",
    cwd: ?[]const u8 = null,
};

// ─── ai / tools ──────────────────────────────────────────────────────────

pub const AiBackend = enum { auto, api, sub, off };
pub const ClaudeMeterMode = enum { off, compact, ticker };

pub const AiRoute = struct { backend: ?AiBackend = null };

pub const AiRouting = struct {
    claude: AiRoute = .{},
    codex: AiRoute = .{},
};

pub const AiProduct = enum { claude, codex };
pub const CwdMode = enum { workspace, home, file_dir };

/// A named way to start a `claude` / `codex` session
/// (`app/launch_profiles.zig`): the chip's right-click lists them.
// changed: Rust's `[[launch_profile]]` lived in the integration
// manifest; here it is config, the built-in `default` (the bare
// binary) implicit.
pub const LaunchProfile = struct {
    name: []const u8 = "",
    product: AiProduct = .claude,
    /// An executable path or a name on PATH.
    binary: []const u8 = "",
    args: []const []const u8 = &.{},
    /// `KEY=VALUE` lines, exported by the shim.
    env: []const []const u8 = &.{},
    cwd_mode: CwdMode = .workspace,
    /// Every session of this profile starts in a git worktree of its
    /// own (`app/session_worktree.zig`): the launch prompts for a name,
    /// `git worktree add -b <name>` makes `<root>/<name>` and the
    /// session runs there. `cwd_mode` is then moot.
    worktree: bool = false,
};

/// The persisted default per product; null (or a name that is not
/// configured) is the built-in.
pub const DefaultProfile = struct {
    claude: ?[]const u8 = null,
    codex: ?[]const u8 = null,
};

pub const Ai = struct {
    /// Legacy single-backend switch; `.routing.claude.backend` wins.
    backend: ?AiBackend = null,
    routing: AiRouting = .{},
    // changed: launch profiles and their per-product default.
    launch_profiles: []const LaunchProfile = &.{},
    default_profile: DefaultProfile = .{},
    /// Where a session worktree goes: null is `<repo>-worktrees` beside
    /// the repository; a path (`~` expanded, a relative one under the
    /// repository) overrides it. The worktree itself is `<root>/<name>`.
    default_worktree_root: ?[]const u8 = null,
    inline_suggestions: bool = true,
    claude_show_all_accounts: bool = false,
    claude_meter_mode: ClaudeMeterMode = .compact,
    /// Every key not named above, kept verbatim for the AI subsystems
    /// and integrations that read their own settings out of `.ai`. (A
    /// field named `extra` of type `Dynamic` is the decoder's convention
    /// for "collect unknown keys here".)
    extra: Dynamic = .empty_object,
};

// ─── http / ws / sonos / git_graph ───────────────────────────────────────

pub const CollectionRoot = enum { hidden, workspace };

pub const Http = struct {
    default_env: ?[]const u8 = null,
    collection_root: CollectionRoot = .hidden,
    auto_format_body: bool = true,
    sync_normalize: bool = false,
    // The transport defaults; a block's `# @insecure` / `# @timeout` /
    // `# @no-redirect` / `# @max-redirects` / `# @proxy` line overrides
    // its own send (`docs/CONFIG.md`).
    /// Skip the certificate chain check on every send (`-k`).
    insecure: bool = false,
    /// A deadline over the whole send in ms; null waits forever.
    timeout_ms: ?u32 = null,
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    /// `host:port`, `user:pass@host:port` or `http://host:port`.
    proxy: ?[]const u8 = null,
};

pub const Ws = struct {
    subprotocols: []const []const u8 = &.{},
    ping_interval_secs: u32 = 30,
    reconnect_max_attempts: u32 = 3,
};

pub const ChipLabel = enum { never, hover, always };

pub const Sonos = struct {
    enabled: bool = true,
    host: ?[]const u8 = null,
    room: ?[]const u8 = null,
    poll_secs: u32 = 3,
    chip_label: ChipLabel = .never,
    prefer_airplay: bool = true,
};

pub const GitGraph = struct { lane_spacing: u16 = 1 };

/// // changed (colors): the git panel's per-repo accents.
pub const Git = struct {
    /// Repo name → a palette name (`ui/accent_color.zig`), or `none`
    /// for the auto slot. Written by the app on a repo's first sighting
    /// in a multi-repo workspace and by the pill's Color menu; the
    /// first assignment wins across restarts.
    repo_colors: Map([]const u8) = .empty,
};

// ─── startup ─────────────────────────────────────────────────────────────

pub const LayoutKind = enum { editor, pty };
pub const SplitDir = enum { right, down };

pub const LayoutEntry = struct {
    kind: LayoutKind = .editor,
    /// `.editor` — required.
    path: ?[]const u8 = null,
    /// `.pty` — required; runs under `$SHELL -c` at startup (exec-bearing).
    cmd: ?[]const u8 = null,
    /// Required on every entry after the first.
    split: ?SplitDir = null,
    /// Percent of the parent, 1..99.
    ratio: ?u8 = null,
};

pub const Startup = struct {
    /// Names from `.tasks`, run at startup in order.
    tasks: []const []const u8 = &.{},
    layout: []const LayoutEntry = &.{},
    /// Tilde-expanded on load.
    default_workspace: ?[]const u8 = null,
};

// ─── browser / ci / integrations / workspaces / marketplace ─────────────

pub const ProfileMode = enum { workspace, shared, ephemeral };

pub const Browser = struct {
    headless: bool = false,
    autocapture_to_log: bool = true,
    profile_mode: ProfileMode = .workspace,
};

pub const Ci = struct {
    provider: ?[]const u8 = null,
    project: ?[]const u8 = null,
    region: ?[]const u8 = null,
};

pub const Integrations = struct {
    auto_update_cargo: bool = false,
    auto_update_git: bool = false,
    /// Folders the INTEGRATIONS section's Dev tab scans: every
    /// subfolder holding a `build.zig` and a `manifest.zon` is an
    /// integration in development. Relative to the workspace, `~`
    /// expanded. A workspace with `sdk/mnml-sdk` adds its own
    /// `integrations/` by itself.
    dev_roots: []const []const u8 = &.{},
};

pub const Workspace = struct {
    name: []const u8 = "",
    path: []const u8 = "",
    group: ?[]const u8 = null,
};

pub const MarketplaceSource = union(enum) {
    crates_keyword: struct { id: []const u8 = "", keyword: []const u8 = "" },
    github_launcher_folder: struct { id: []const u8 = "", repo: []const u8 = "", path: []const u8 = "" },
    github_monorepo_apps: struct { id: []const u8 = "", repo: []const u8 = "", apps_dir: []const u8 = "" },
    /// A folder on this machine (or a mounted share — the private
    /// path): every `*.zon` in it is a manifest to install as-is, every
    /// subfolder with a `build.zig` and a `manifest.zon` a Zig
    /// integration to build and install. Relative to the workspace,
    /// `~` expanded.
    local_folder: struct { id: []const u8 = "", path: []const u8 = "" },
};

pub const Marketplace = struct {
    enabled: bool = true,
    cache_ttl_secs: u32 = 3600,
    /// Prepend mnml's built-in sources to `.sources`.
    use_defaults: bool = true,
    sources: []const MarketplaceSource = &.{},
    show_dev_tab: bool = false,
};

/// The sources mnml ships with when `.marketplace.use_defaults` is on.
/// None yet: the 0.2 sources (the crates.io keyword, the launchers
/// folder and the apps monorepo) list integrations built on the old
/// bridge, which this host cannot mount, so they are gone. The official
/// set is this repo's `integrations/` folder, served here as a
/// `github_monorepo_apps` source once jira and bitbucket are in it.
pub const default_marketplace_sources = [_]MarketplaceSource{};

// ─── tests ───────────────────────────────────────────────────────────────

test "defaults are the shipped values" {
    const c: Config = .{};
    // editor
    try std.testing.expectEqual(InputStyle.standard, c.editor.input_style);
    try std.testing.expectEqual(@as(u8, 4), c.editor.tab_width);
    try std.testing.expect(c.editor.breadcrumb);
    try std.testing.expect(c.editor.auto_pair);
    try std.testing.expect(!c.editor.format_on_save);
    try std.testing.expectEqual(@as(u16, 80), c.editor.text_width);
    try std.testing.expectEqual(@as(u16, 500), c.editor.chord_timeout_ms);
    try std.testing.expectEqual(WheelMovesCursor.auto, c.editor.wheel_moves_cursor);
    try std.testing.expectEqual(ScrollAccel.normal, c.editor.scroll_accel);
    try std.testing.expectEqual(Clipboard.auto, c.editor.clipboard);
    try std.testing.expect(c.editor.inlay_hints);
    try std.testing.expect(c.editor.semantic_tokens);
    try std.testing.expect(c.editor.code_lens);
    try std.testing.expect(!c.editor.format_on_type);
    try std.testing.expect(!c.editor.will_save_wait_until);
    try std.testing.expectEqual(@as(usize, 0), c.formatters.count());
    try std.testing.expectEqual(@as(usize, 0), c.linters.count());
    try std.testing.expect(!(Formatter{}).in_place);
    try std.testing.expectEqual(LintParser.vimgrep, (Linter{}).parser);
    // ui
    try std.testing.expectEqualStrings("onedark", c.ui.theme);
    try std.testing.expectEqual(@as(u16, 30), c.ui.tree_width);
    try std.testing.expectEqual(@as(u16, 32), c.ui.right_panel_width);
    try std.testing.expect(c.ui.line_numbers);
    try std.testing.expect(!c.ui.relative_line_numbers);
    try std.testing.expect(c.ui.clock);
    try std.testing.expect(c.ui.scrollbar);
    try std.testing.expectEqual(@as(u8, 3), c.ui.wheel_lines);
    try std.testing.expect(c.ui.markdown_opens_rendered);
    try std.testing.expectEqual(@as(u16, 12), c.ui.md_image_rows);
    try std.testing.expectEqual(ListSort.newest, c.ui.todos_sort);
    try std.testing.expectEqual(@as(usize, 5), c.ui.todo_keywords.len);
    try std.testing.expectEqualStrings("REVIEW", c.ui.todo_keywords[4]);
    try std.testing.expectEqual(SessionsSort.auto, c.ui.sessions_sort);
    try std.testing.expectEqual(PickerPosition.center, c.ui.picker_position);
    try std.testing.expectEqual(NowPlayingSource.mixr, c.ui.now_playing_source);
    try std.testing.expectEqual(MenuBar.always, c.ui.menu_bar);
    try std.testing.expectEqual(ActivityBar.always, c.ui.activity_bar);
    try std.testing.expectEqual(DiagStyle.count, c.ui.bufferline_diag_style);
    try std.testing.expectEqual(CoverageChipMode.feature, c.ui.coverage_chip_mode);
    try std.testing.expectEqual(ExpandIndicator.chevron, c.ui.expand_indicator);
    try std.testing.expectEqual(@as(u16, 8), c.ui.hover_help_height);
    try std.testing.expectEqualStrings("terminal", c.ui.terminal_label);
    try std.testing.expectEqual(TabBarAiIcon.claude_code, c.ui.tab_bar_ai_icon);
    try std.testing.expectEqual(AiLayoutMode.grid, c.ui.ai_layout_mode);
    try std.testing.expect(c.ui.hover_help);
    try std.testing.expect(c.ui.show_workspace_dots);
    try std.testing.expect(!c.ui.first_launch_complete);
    try std.testing.expectEqual(MdEngine.builtin, c.ui.md_preview_engine);
    try std.testing.expectEqual(@as(usize, 3), c.ui.integration_icons.len);
    try std.testing.expectEqualStrings("browser", c.ui.integration_icons[0].id);
    try std.testing.expect(!c.ui.integration_icons[1].enabled);
    // the rest
    try std.testing.expect(c.session.restore);
    try std.testing.expect(!c.editor.persistent_undo);
    try std.testing.expect(c.ui.check_updates);
    try std.testing.expect(!c.ipc.write_screen);
    try std.testing.expectEqual(CollectionRoot.hidden, c.http.collection_root);
    try std.testing.expect(c.http.auto_format_body);
    try std.testing.expect(!c.http.insecure and c.http.follow_redirects);
    try std.testing.expectEqual(@as(?u32, null), c.http.timeout_ms);
    try std.testing.expectEqual(@as(u8, 10), c.http.max_redirects);
    try std.testing.expect(c.http.proxy == null);
    try std.testing.expectEqual(@as(u32, 30), c.ws.ping_interval_secs);
    try std.testing.expectEqual(@as(u32, 3), c.ws.reconnect_max_attempts);
    try std.testing.expect(c.sonos.enabled);
    try std.testing.expectEqual(@as(u32, 3), c.sonos.poll_secs);
    try std.testing.expectEqual(ChipLabel.never, c.sonos.chip_label);
    try std.testing.expectEqual(@as(u16, 1), c.git_graph.lane_spacing);
    try std.testing.expectEqual(ProfileMode.workspace, c.browser.profile_mode);
    try std.testing.expect(c.browser.autocapture_to_log);
    try std.testing.expect(!c.integrations.auto_update_cargo);
    try std.testing.expectEqual(@as(usize, 0), c.integrations.dev_roots.len);
    try std.testing.expect(c.marketplace.enabled);
    try std.testing.expectEqual(@as(u32, 3600), c.marketplace.cache_ttl_secs);
    try std.testing.expect(c.marketplace.use_defaults);
    try std.testing.expectEqual(@as(usize, 0), c.marketplace.sources.len);
    try std.testing.expectEqual(@as(usize, 0), default_marketplace_sources.len);
    try std.testing.expectEqual(@as(usize, 0), c.lsp.count());
    try std.testing.expectEqual(@as(usize, 0), c.keys.global.count());
    try std.testing.expect(c.tools.isEmpty());
    try std.testing.expect(c.ai.backend == null);
    try std.testing.expect(c.ai.inline_suggestions);
    try std.testing.expectEqual(@as(usize, 0), c.startup.layout.len);
    try std.testing.expect(c.startup.default_workspace == null);
}
