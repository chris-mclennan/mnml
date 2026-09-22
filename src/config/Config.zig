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
const brand = @import("../ui/brand.zig");
const bufferline = @import("../ui/bufferline.zig");

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
scripts: Scripts = .{},
statusline: Statusline = .{},

// ─── statusline ──────────────────────────────────────────────

pub const Statusline = struct {
    /// How many of the things behind a figure the chip's hover lists
    /// before the `… and N more` line. A figure counts something; the
    /// hover is where the reader finds out WHAT, so the default is
    /// generous enough for a normal day's pull requests. 0 turns the
    /// list off and leaves the one-line hover every chip had.
    hover_items: u8 = 8,
};

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
    /// Blink the cursor mnml puts on the focused editor or text field
    /// — it picks the blinking DECSCUSR variant, and the terminal owns
    /// the clock, so mnml runs none of its own. A terminal pane's
    /// cursor follows `ui.pty_cursor.blink` and its child's request
    /// instead.
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
    /// Ceiling on what tree-sitter is asked to parse. A file that opens
    /// larger than this many bytes gets no tree-sitter at all: no parse,
    /// no tree, no spans, no injections. Everything else about the buffer
    /// (editing, search, LSP, the git gutter) is untouched, and the
    /// statusline says so — the `highlight off` chip turns it on for that
    /// one file. `0` is no limit: every file is highlighted in full,
    /// however large.
    ///
    /// The limit exists because a parse tree is the largest thing this
    /// editor holds. Measured on a 100 MB Rust file, ONE tree is 2.5 GB —
    /// about 25× the source, and the whole of the difference between a
    /// 2.9 GB process and a 450 MB one. 4 MiB is the shipped default and
    /// covers every hand-written source file; past it a buffer is a
    /// generated bundle or a log, where highlighting is worth the least
    /// and costs the most.
    highlight_max_bytes: u64 = 4 << 20,

    /// The ceiling on what a language server is started for. A file that
    /// opens larger than this many bytes attaches no server: no
    /// `didOpen`, no diagnostics, no completion, no hover, no go-to —
    /// editing, search, highlighting and the git gutter are untouched.
    /// It is never silent: a toast names the file and the statusline
    /// reads `LSP off · 120 MB` while it is up, and
    /// `editor.lsp_this_file` attaches one anyway for that buffer. Per
    /// buffer, never persisted. 0 is no limit.
    ///
    /// The limit exists because `didOpen` has to carry the whole file:
    /// the protocol has no other way to hand a server a document, so a
    /// 100 MB buffer is a 100 MB JSON string encoded on the frame that
    /// opened it, and the server's answers scale with it too — a reply
    /// of 75 MB and one of 196 MB came back from rust-analyzer on that
    /// file. 50 MiB is VS Code's own large-file threshold and the
    /// nearest thing to a precedent; mnml's Rust predecessor has no
    /// ceiling at all. Every hand-written source file, and every
    /// generated one worth a server, is far under it.
    lsp_max_bytes: u64 = 50 << 20,
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
/// // changed (sidebar-autohide): the side columns' own three words.
/// `always` docks the column (the shipped look); `auto` hides it and
/// reveals it as an OVERLAY over the editor — no relayout, no pty
/// resize — once the pointer has rested at the column's screen edge
/// for `ui.sidebar_reveal_ms`, and hides it again `ui.sidebar_hide_ms`
/// after the pointer leaves; `hidden` never reveals on hover, and a
/// keyboard command that targets the column brings up a one-shot
/// overlay instead. `view.sidebar_pin` docks a revealed column for
/// the session (`always` for as long as mnml runs).
pub const Sidebar = enum { always, auto, hidden };
/// // changed (debug-ui): the step toolbar strip over the editor —
/// `auto` while a debug session is live, `always`, or never.
pub const DebugToolbar = enum { auto, always, hidden };
/// // changed (section-side): which column an activity section lives
/// in. `ui.sidebar_side` is the side sections take when nothing says
/// otherwise; `ui.section_side` overrides it per section.
/// // changed (bottom-dock): `.bottom` is the dock under the editor
/// area — a third host beside the two columns, sized in rows
/// (`ui.bottom_panel_height`) rather than in columns.
pub const Side = enum { left, right, bottom };
/// The two columns. `ui.sidebar_side` names one of them: the dock is
/// somewhere a section is *put*, never the home every section that
/// names no side falls back to.
pub const ColumnSide = enum { left, right };
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
    search: ?Side = null,
    diagnostics: ?Side = null,
    outline: ?Side = null,
};
/// // changed (launcher-dock): the launcher dock's three words. The
/// dock is the strip of integrations, terminals, launchers and pinned
/// commands along one edge of the editor area — macOS's Dock. It is
/// NOT the bottom panel (`ui.bottom_panel_*`, `app/bottom.zig`, which
/// hosts sections and panes) and not the dock WIDGETS
/// (`app/dock.zig`, which persist in the session file). `always`
/// reserves its row / column; `auto_hide` draws nothing until the
/// pointer has rested at that edge for `reveal_ms`, and puts it away
/// `hide_ms` after the pointer leaves; `hidden` never draws and never
/// reveals on hover (`view.dock_toggle` is still the keyboard's
/// one-shot door).
pub const DockMode = enum { always, auto_hide, hidden };
/// Which edge the launcher dock lives on. There is no `.top`: that row
/// belongs to the menu bar (`app/menu_bar.zig`).
pub const DockEdge = enum { bottom, left, right };
/// // changed (dock-placement): where a BOTTOM launcher dock sits
/// relative to the two rows the frame keeps for itself. `.inner` (the
/// default) puts the strip ABOVE the statusline — it is the editor
/// area's last row, carved out of `upper` under `always` and painted
/// over that row when it reveals, so the statusline and the `:` line
/// stay exactly where they are. `.outer` puts it UNDER the `:` line,
/// as the frame's last row: everything else moves up one, and a
/// revealed strip paints over the `:` line's row (so an open `:` line
/// refuses the reveal). A dock on a side edge ignores the key — it is
/// a column, and neither of those rows is its business.
pub const DockPlacement = enum { inner, outer };
/// How much of an item a BOTTOM launcher dock paints. `icon_label` is
/// ` <glyph> <label> `, the strip's own form; `icon` paints the glyph
/// alone in the same three cells a side dock uses — padding, glyph,
/// padding — with the running dot in that padding cell and the name in
/// the tooltip. `label` is the third form the user asked for — the
/// word alone, no glyph anywhere on the strip, with the running dot
/// (and the keyboard cursor) in the one padding cell before it. A dock
/// on a side edge is icon-only by geometry (three cells is all it has)
/// and paints the icon form whatever this key says — `label` included.
pub const DockLabels = enum { icon, icon_label, label };
/// Where the run of items sits along the strip. `center` is the
/// shipped look — macOS's Dock, centred — and the pin chip keeps the
/// far end whatever this says. On a side edge it centres the items
/// vertically. A run too long to centre is laid from the start rather
/// than clipped on the left.
pub const DockAlign = enum { start, center, end };

/// `ui.dock` — the launcher dock (`app/launcher_dock.zig`).
pub const Dock = struct {
    mode: DockMode = .auto_hide,
    edge: DockEdge = .bottom,
    /// // changed (dock-placement): where a bottom strip goes — above
    /// the statusline (the default) or under the `:` line. Side edges
    /// ignore it (`:dock inner|outer`, also `above` / `below`).
    placement: DockPlacement = .inner,
    labels: DockLabels = .icon_label,
    /// Where the items sit along the strip (`:dock center|start|end`).
    /// `align` is a Zig keyword, so the field wears the quotes the key
    /// name does not: `.@"align" = .center` in the file.
    @"align": DockAlign = .center,
    /// The `+` leads the strip — the tab bar's own `+`, opening the
    /// same *Create…* menu. `false` takes it off.
    plus: bool = true,
    /// Command ids pinned onto the dock, in this order — a static id
    /// or a dynamic one (an integration's `jira.open`). An id nothing
    /// answers to is skipped rather than painted dead.
    pins: []const []const u8 = &.{},
    /// The dwell before an `auto_hide` dock reveals (ms; clamped to
    /// 0..`sidebar_dwell_ms_max`, the sidebar's own ceiling).
    reveal_ms: u16 = 250,
    /// How long after the pointer leaves before it hides again (ms;
    /// the same clamp).
    hide_ms: u16 = 400,
};

pub const DiagStyle = enum { count, dot, off };
pub const CoverageChipMode = enum { both, feature, code, ticker };
pub const ExpandIndicator = enum { chevron, triangle };
/// Which panes wear the one-cell colour rail down their left edge
/// (`ui/pane_rail.zig`). `all` is every pane, so two terminals side by
/// side are never the same colour; `sessions` is the older look, where
/// only an AI session pane wore one; `off` paints none.
pub const PaneRail = enum { all, sessions, off };
pub const TabIndicator = enum { block, rule, line, quarter, quarter_track };
pub const TopBarClusterMode = enum { auto, expanded, compact };
/// `terminal` = follow the editing mode (see `ui.cursor_shape`).
pub const CursorShape = enum { terminal, block, bar, underline };
pub const TabBarAiIcon = enum { none, claude_code, codex, both };
/// What the tab strip's maximize button does on a left click. The
/// layout's only scope between one pane and the whole window is the
/// leaf — a leaf IS the tab group — so `.zoom_pane` is that zoom: the
/// active pane's leaf alone fills the editor area, the other splits
/// hide, the chrome stays. `.fullscreen` is the other end — the tree,
/// the strips and the statusline go with them. The right button lists
/// both and ticks this one (`app/context_menus.zig`).
pub const MaximizeClick = enum { zoom_pane, fullscreen };
pub const AiLayoutMode = enum { grid, tabs };
/// Which mark a terminal wears in the chrome (`app/terminal_glyph.zig`).
/// The type lives beside the resolver that answers it, so the tags and
/// the glyphs they pick cannot drift apart.
pub const TerminalGlyph = bufferline.TerminalMark;
/// Which mark Claude Code wears (`app/claude_mark.zig`) — same idea,
/// same file.
pub const ClaudeMark = bufferline.ClaudeMark;

/// How a terminal pane draws the cursor its child asked for.
pub const PtyCursor = struct {
    /// A pty pane that is not the focused one. A terminal emulator
    /// draws a hollow block there; a cell grid cannot draw an outline,
    /// so `hollow` keeps the cell's own glyph readable and repaints it
    /// in the cursor colour, `dim` is a muted filled block, and `none`
    /// leaves the cell alone.
    unfocused: Unfocused = .hollow,
    /// Pass the child's blink request (DECSCUSR / DEC mode 12) out to
    /// the host terminal, which owns the clock. Off keeps every cursor
    /// steady. An unfocused pane's cursor never blinks either way.
    blink: bool = true,

    pub const Unfocused = enum { hollow, dim, none };
};

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
/// // changed (bottom-dock): the dock's row clamp — Rust's
/// `session.rs` clamps a restored `bottom_panel_height` to 3..60 and
/// `ui/mod.rs` floors the drawn height at 3.
pub const bottom_panel_height_min: u16 = 3;
pub const bottom_panel_height_max: u16 = 60;
/// // changed (sidebar-autohide): the reveal / hide dwells, clamped on
/// load. 0 is allowed — an instant reveal.
pub const sidebar_dwell_ms_max: u16 = 5000;
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
    /// // changed (bottom-dock): the dock opens at start (on the last
    /// section it showed, else the first section whose side is bottom
    /// — the diagnostics by default).
    bottom_panel_visible: bool = false,
    /// // changed (bottom-dock): the dock's height in rows (Rust's
    /// `App::bottom_panel_height`: 12). Clamped to
    /// `bottom_panel_height_min..max` on load.
    bottom_panel_height: u16 = 12,
    /// // changed (section-side): the side a section takes when
    /// `section_side` does not name it. The Rust right-panel panes
    /// (outline, diagnostics) take the other side — the diagnostics
    /// then land in the dock (`side.configuredSide`).
    sidebar_side: ColumnSide = .left,
    section_side: SectionSide = .{},
    /// // changed (sidebar-autohide): a WIDTH rule, and Rust's
    /// (`ui/mod.rs`, task #891): below this many columns both side
    /// columns are dropped FOR THE FRAME — `tree.visible` and the
    /// column's own section are untouched, so widening brings back
    /// whatever was open. 0 = never. It composes with `ui.sidebar`:
    /// a narrow screen hides the column whatever the mode says, and
    /// under `auto` the hover reveal is refused there too.
    auto_hide_narrow_width: u16 = 0,
    /// // changed (sidebar-autohide): `always` | `auto` | `hidden` —
    /// see `Sidebar`. It governs BOTH columns; `ui.sidebar_side` still
    /// says which one a section calls home.
    sidebar: Sidebar = .always,
    /// How long the pointer must rest in a column's edge zone before
    /// the overlay slides in (ms; clamped to 0..`sidebar_dwell_ms_max`).
    sidebar_reveal_ms: u16 = 250,
    /// How long after the pointer leaves the overlay before it hides
    /// (ms; clamped to 0..`sidebar_dwell_ms_max`).
    sidebar_hide_ms: u16 = 400,
    /// // changed (sidebar-autohide): the reduced-motion switch. False
    /// skips every chrome animation that has an instant end state —
    /// today the sidebar overlay's three-frame slide, which then
    /// appears at its full width on the first frame. `--headless` and
    /// the `.test` harness behave as if it were false.
    animations: bool = true,
    /// // changed (edge-grip): the three-dot handle `⋯` / `⋮` at the
    /// middle of a hidden slide-in's edge (`ui/edge_grip.zig`) — the
    /// menu bar's row, the launcher dock's bottom row, each side
    /// column's screen edge. False gives the invisible dwell bands
    /// back; the bands themselves never move, so every reveal works
    /// either way.
    edge_grips: bool = true,
    /// // changed (launcher-dock): the launcher dock — the strip of
    /// integrations, terminals, launchers and pinned commands along
    /// one edge of the editor area (`app/launcher_dock.zig`). Not the
    /// bottom panel (`ui.bottom_panel_*`) and not the dock widgets.
    dock: Dock = .{},
    auto_equalize_splits: bool = false,
    relative_line_numbers: bool = false,
    line_numbers: bool = true,
    cursor_line: bool = false,
    scrolloff: u16 = 0,
    sidescrolloff: u16 = 0,
    show_whitespace: bool = false,
    bracket_rainbow: bool = false,
    tree_preview_on_arrow: bool = true,
    /// VS Code's preview tabs: a glance (a tree click, an arrow over a
    /// tree row) opens an italic tab the next glance takes over. Off,
    /// every open is a tab of its own. The vim profile never has them.
    preview_tabs: bool = true,
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
    /// // changed (sessions-card): a session that ended within this many
    /// minutes stays listed (its card, or an ENDED row) before the
    /// history chip hides it — so the ended toast and a worktree offer
    /// are not lost. 0 hides at once.
    session_ended_grace_min: u16 = 10,
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
    /// The gutter's fold offer (`▼`) on every foldable line, not only
    /// the one under the pointer — read by `signFor` in
    /// `ui/editor_view.zig`.
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
    /// How a mounted integration's tab strip marks the tab that is on
    /// — one row under the labels, in the pane's brand colour, over
    /// exactly the active label's cells. `block` is the flush upper
    /// half-block, `rule` a heavy mark over a light track across the
    /// strip, `line` a light mark under the active label alone. Sent
    /// to every pane on `hello`.
    tab_indicator: TabIndicator = .block,
    /// Clamped to `hover_help_height_min..max` on load.
    hover_help_height: u16 = 8,
    terminal_label: []const u8 = "terminal",
    /// How a terminal pane draws its child's cursor.
    pty_cursor: PtyCursor = .{},
    /// Which panes wear a colour rail down their left edge.
    pane_rail: PaneRail = .all,
    /// The shape of the cursor mnml puts on the focused editor or text
    /// field. `terminal` — the default — follows the editing mode, as
    /// vim does: a block in NORMAL and VISUAL, a bar in INSERT (and in
    /// modeless editing, which is an insert caret the whole time), an
    /// underline in REPLACE. Any other value is that one shape
    /// everywhere. A terminal pane's cursor is never overridden: its
    /// child asked for a shape over DECSCUSR and gets it.
    cursor_shape: CursorShape = .terminal,
    /// A program mnml spawns — exec-bearing. Empty = the OS default.
    external_browser: []const u8 = "",
    /// The mark every terminal wears in the chrome — a pty tab, the
    /// strip's terminal chip. `.ghostty` is Ghostty's ghost, which mnml
    /// bakes into its own face at U+F2000; `.terminal` is the codicon,
    /// and the only value that brings back the per-emulator table
    /// (kitty's cat, Apple's apple); `.custom` is the SVG below, baked
    /// at the same codepoint.
    terminal_glyph: TerminalGlyph = .ghostty,
    /// The SVG behind `.custom` — `view.terminal_glyph_custom` sets both
    /// keys and bakes `<data root>/fonts/MnmlSymbols.ttf`.
    terminal_glyph_svg: []const u8 = "",
    /// The mark Claude Code wears everywhere in the chrome — the tab
    /// bar's right cluster, a Claude pty tab, the statusline meter, the
    /// launcher dock, a SESSIONS card. `.figure` is the Claude Code
    /// figure mnml bakes at U+F1E00; `.spark` is the Anthropic spark,
    /// one codepoint along. The cluster chip's right-click menu is the
    /// other way to set it (`app/claude_mark.zig`).
    claude_mark: ClaudeMark = .figure,
    top_bar_cluster_mode: TopBarClusterMode = .auto,
    /// The tab strip's maximize button, left click. The default is the
    /// zoom, not full screen: with the frame split, a click on it is
    /// read as "give this one the room", and hiding every other pane is
    /// that, where dropping the chrome and keeping both is not.
    maximize_click: MaximizeClick = .zoom_pane,
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
    /// `app.quit` (Ctrl+Q, the menu bar's Quit, the palette) always
    /// stops to ask, clean workspace or not — a fat-fingered chord is
    /// the one way to lose a session outright, and Cancel holds the
    /// focus so Enter on a box nobody meant to raise is safe. `false`
    /// asks only when something is unsaved. `:q!` / `:qa!`, the IPC
    /// `quit` and `restart` never ask either way.
    confirm_quit: bool = true,
    first_launch_complete: bool = false,
    /// The once-per-data-root notice about a 0.2 `config.toml` beside a
    /// missing `config.zon` — a file mnml-zig never reads
    /// (`App.noticeUnreadToml`); set the first time it is shown.
    config_toml_notice_shown: bool = false,
    /// The same for 0.2 `integrations/*.toml` manifests
    /// (`integrations.refresh`); `integrations.dismiss_toml_notice`
    /// sets it.
    integrations_toml_notice_shown: bool = false,
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

/// The four first-party surfaces, as `app/integrations.zig`'s
/// `first_party` table spells them — that table is the description
/// (the Installed tab's rows and their menus), this array the storage
/// the two user preferences persist into. A unit test there holds the
/// two together.
pub const default_integration_icons = [_]IntegrationIcon{
    .{ .id = "browser", .glyph = "\u{EB01}", .fallback = "B", .command = "browser.open", .color = "blue", .label = "Browser", .enabled = true, .in_palette_bar = true },
    // The marks come from `ui/bufferline.zig`, which is where a
    // codepoint is spelled: this row's glyph is the value `allChips`
    // compares against to know the icon is still the shipped figure
    // (`app/integrations.zig`), so a second spelling here would let
    // the two drift.
    .{ .id = "claude_code", .glyph = bufferline.claude_glyph, .fallback = bufferline.claude_ascii, .command = "ai.claude_code", .color = brand.claude_hex, .label = "Claude Code", .enabled = false, .in_palette_bar = false },
    .{ .id = "codex", .glyph = bufferline.codex_glyph, .fallback = "\u{276F}_", .command = "ai.codex", .color = "cyan", .label = "Codex", .enabled = false, .in_palette_bar = false },
    .{ .id = "http", .glyph = "\u{F1D8}", .fallback = "H", .command = "view.activity_http", .color = "teal", .label = "HTTP", .enabled = false, .in_palette_bar = false },
};

// ─── small fixed sections ────────────────────────────────────────────────

/// What a saved TERMINAL pane comes back as when the session restores
/// (`app/session.zig`'s `terminalRestore`). `.running` is the default:
/// a plain shell comes back live in the cwd it was saved in, and an AI
/// session pane whose id was saved RESUMES that session — a restart
/// hands the workspace back the way it was left. `.dormant` is the
/// other way: every terminal pane comes back with its tab, its title
/// and `[exited] — any key restarts …`, starting nothing until a key
/// asks. Either way a pane whose command cannot be re-run safely — and
/// a resume with no id to resume — comes back dormant.
pub const RestoreTerminals = enum { running, dormant };
pub const Session = struct {
    restore: bool = true,
    restore_terminals: RestoreTerminals = .running,
};
pub const Ipc = struct {
    write_screen: bool = false,
    /// Whether the file channel may drive INPUT at a live terminal —
    /// `key`, `type`, `click`, `scroll`, `drag`, `mouse_*`, `hover`.
    /// Off: a host that writes one is told so, and told this is the
    /// switch. The tier-2 set an integration actually needs (segments,
    /// badges, toasts, progress, notify, register-command, open-pty,
    /// run-command) is always taken — it is what the SDK promises.
    ///
    /// Typing into someone's editor from a file on disk is a different
    /// kind of power from moving a number on their statusline, which is
    /// why the two are not one switch. The headless loop is the driver
    /// and takes everything regardless.
    allow_input: bool = false,
};

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

/// One Claude Code login the usage reader polls (`src/ai/usage.zig`).
/// `token_path` is the token file — `~` expands, a relative path sits
/// under the data root beside the default `ai_token`; `active` marks the
/// one the statusline chip shows alone (the CLI's live login wins when
/// the keychain names one). No entries is the single `default` account
/// on `ai_token`.
pub const ClaudeAccount = struct {
    name: []const u8 = "default",
    token_path: []const u8 = "ai_token",
    active: bool = false,
};

/// Ghost text's two clocks, clamped on load. The idle one is how long
/// typing must stop before a request goes out; the budget is what keeps
/// a `claude -p` that never answers from holding the only in-flight
/// slot. Both are observable in the statusline chip
/// (`src/app/ghost_chip.zig`).
pub const suggest_idle_ms_min: u16 = 50;
pub const suggest_idle_ms_max: u16 = 5000;
pub const suggest_timeout_ms_min: u32 = 500;
pub const suggest_timeout_ms_max: u32 = 120_000;

/// GitHub Copilot as the ghost-text backend (`suggest_backend =
/// "copilot"`). Everything here is HOME-scope: `command` is an argv, so
/// the trust layer strips it from a workspace layer. The per-workspace
/// switch is `ai.copilot_here`, and it is the only one a workspace may
/// set.
pub const Copilot = struct {
    /// The language server's argv. Empty means `copilot-language-server
    /// --stdio` on `PATH`. mnml never downloads it; write
    /// `.{ "npx", "--yes", "@github/copilot-language-server", "--stdio" }`
    /// here if that is how you want it fetched.
    command: []const []const u8 = &.{},
    /// Glob patterns whose files are never sent. Empty means the
    /// shipped list (`.env*`, `*.pem`, `*.key`, `id_*`). Setting it
    /// REPLACES that list — the secret-name check and the gitignore
    /// check are not negotiable either way.
    exclude: []const []const u8 = &.{},
    /// A GitHub Enterprise instance, passed through as
    /// `github-enterprise.uri` in `workspace/didChangeConfiguration`.
    github_enterprise_uri: ?[]const u8 = null,
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
    /// Idle time after the last edit before a suggestion is asked for.
    suggest_idle_ms: u16 = 300,
    /// The wall-clock budget one suggestion gets. Past it the child is
    /// killed, the chip says `!`, and `:messages` says `timeout`.
    suggest_timeout_ms: u32 = 4000,
    copilot: Copilot = .{},
    /// THE privacy switch. False by default, and the only Copilot key a
    /// workspace's own `.mnml/config.zon` may set — and only in a
    /// TRUSTED workspace (`config/trust.zig`'s `copilot_share` sink), so
    /// a repo you cloned cannot opt you in by shipping a config. It
    /// turns sharing on for THIS workspace and no other.
    copilot_here: bool = false,
    claude_show_all_accounts: bool = false,
    claude_meter_mode: ClaudeMeterMode = .compact,
    /// The Claude logins the usage chip and pane read; see `ClaudeAccount`.
    claude_accounts: []const ClaudeAccount = &.{},
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

/// // changed (integration-split): where a mounted integration's pane
/// lands. The Rust editor has no setting — `open_mount_with_args`
/// always splits side by side (`integration_install_methods.rs`) — and
/// that is the default here; `.tab` is the other half of the toggle
/// the user asked for.
pub const IntegrationOpenAs = enum { split, tab };

/// How a pane opened as a split sizes itself against what is already
/// there (`app/arrange.zig`).
pub const SplitArrange = enum {
    /// Read the room: an empty editor area takes the pane FULL, and a
    /// split evens out every sibling along the new split's axis, so a
    /// third pane is thirds and a fourth is quarters. A stack across
    /// that axis keeps the proportions it was dragged to.
    context,
    /// The old behaviour, cell for cell: the new pane halves the
    /// active one and everything else stays where it is (`.tab` and
    /// `equalize_on_open` still apply).
    fixed,
};

pub const Integrations = struct {
    auto_update_cargo: bool = false,
    auto_update_git: bool = false,
    /// A mounted integration opens beside the active pane (`.split`,
    /// the Rust behaviour) or as another tab in its leaf (`.tab`).
    open_as: IntegrationOpenAs = .split,
    /// After an integration split, even the splits out whatever
    /// `ui.auto_equalize_splits` says — the "they actually auto adjust"
    /// half of the ask. Only an integration's own split equalizes; a
    /// `Ctrl+\` still obeys `ui.auto_equalize_splits` alone.
    equalize_on_open: bool = true,
    /// How a new pane sizes itself when it opens as a split — every
    /// such path, not only an integration's: terminals and the session
    /// panes go through the same rule (`app/arrange.zig`). `.context`
    /// is the default because a fixed half-of-the-active-pane made the
    /// third thing opened a quarter and the fourth an eighth.
    arrange: SplitArrange = .context,
    /// Folders the INTEGRATIONS section's Dev tab scans: every
    /// subfolder holding a `build.zig` and a `manifest.zon` is an
    /// integration in development. Relative to the workspace, `~`
    /// expanded. A workspace with `sdk/mnml-sdk` adds its own
    /// `integrations/` by itself.
    dev_roots: []const []const u8 = &.{},
    /// The statusline poller (`app/integration_poll.zig`): what keeps a
    /// manifest's chip counts live with no pane open.
    poll: Poll = .{},
    /// What every integration's requests cost, written down where a
    /// person can read them (`integrations.requests` opens the view).
    request_log: RequestLog = .{},
    /// Host the API broker while mnml runs (`app/broker.zig`): one
    /// queue per service in front of the shared token bucket, so the
    /// pane you are looking at gets the next token before a warmer or
    /// a batch script that asked earlier. On, because the whole point
    /// of it is that a machine running a dozen things against one API
    /// budget still paints the pane in front of you first.
    ///
    /// Off puts every client back on the file bucket and its
    /// first-come order — including the integrations mnml starts,
    /// which are told so (`MNML_BROKER=0`) rather than left to open a
    /// socket nobody is on.
    broker: bool = true,
};

/// `<data root>/requests/<service>.jsonl` — one JSON line per request
/// an integration makes. Reaches every integration mnml starts as
/// `MNML_REQUEST_LOG` / `MNML_REQUEST_LOG_MAX_MB`; the SDK
/// (`mnml_sdk.request_log`) is what reads them there.
pub const RequestLog = struct {
    /// On, because the point of it is to be there when the slow
    /// morning happens rather than to be switched on afterwards.
    enabled: bool = true,
    /// The ceiling before a file rotates, in megabytes. One older
    /// generation is kept beside it.
    max_mb: u32 = 4,
};

pub const Poll = struct {
    /// Off means a chip only moves when its pane or its refresh command
    /// says so — which is what mnml did before the poller existed.
    enabled: bool = true,
    /// The floor under every manifest's `poll_interval_secs`: the
    /// user's say in how hard their own API budget may be spent. The
    /// poller's own floor (30 s) still applies underneath.
    min_interval_secs: u32 = 60,
};

/// // changed (lua-install): installed Lua scripts — the SCRIPTS
/// section's three tabs, exactly as `marketplace` + `integrations`
/// feed the INTEGRATIONS section's.
pub const Scripts = struct {
    /// A folder of script directories the Marketplace tab lists INSTEAD
    /// of the set that ships with mnml — an offline mirror, a company
    /// set, a test fixture. Empty is the normal case: the curated set
    /// is this repo's own `lua/`, packaged as `share/mnml/lua` beside
    /// the binary, and `app/scripts.zig`'s `shippedRoot` finds it with
    /// no config at all. Relative to the workspace, `~` expanded;
    /// `MNML_SCRIPTS_MARKETPLACE` beats it.
    marketplace_local: []const u8 = "",
    /// Folders of script directories the user maintains — a company
    /// repo, a mounted share. Listed with the `private` badge.
    private_sources: []const []const u8 = &.{},
    /// Folders the SCRIPTS section's Dev tab scans: every subfolder
    /// with a `script.zon` is a script in development, reloaded when
    /// one of its files is saved.
    dev_roots: []const []const u8 = &.{},
    /// Show the Dev tab even with no `dev_roots`.
    show_dev_tab: bool = false,
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
    try std.testing.expect(c.ai.inline_suggestions);
    try std.testing.expectEqual(@as(u16, 300), c.ai.suggest_idle_ms);
    try std.testing.expectEqual(@as(u32, 4000), c.ai.suggest_timeout_ms);
    try std.testing.expectEqual(WheelMovesCursor.auto, c.editor.wheel_moves_cursor);
    try std.testing.expectEqual(ScrollAccel.normal, c.editor.scroll_accel);
    try std.testing.expectEqual(Clipboard.auto, c.editor.clipboard);
    // 4 MiB: a file larger than this opens with no tree-sitter at all.
    try std.testing.expectEqual(@as(u64, 4 << 20), c.editor.highlight_max_bytes);
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
    try std.testing.expectEqual(@as(u16, 10), c.ui.session_ended_grace_min);
    try std.testing.expectEqual(PickerPosition.center, c.ui.picker_position);
    try std.testing.expectEqual(NowPlayingSource.mixr, c.ui.now_playing_source);
    try std.testing.expectEqual(MenuBar.always, c.ui.menu_bar);
    try std.testing.expectEqual(ActivityBar.always, c.ui.activity_bar);
    try std.testing.expectEqual(Sidebar.always, c.ui.sidebar);
    try std.testing.expectEqual(@as(u16, 250), c.ui.sidebar_reveal_ms);
    try std.testing.expectEqual(@as(u16, 400), c.ui.sidebar_hide_ms);
    try std.testing.expectEqual(@as(u16, 0), c.ui.auto_hide_narrow_width);
    try std.testing.expect(c.ui.animations);
    try std.testing.expect(c.ui.edge_grips);
    try std.testing.expectEqual(DiagStyle.count, c.ui.bufferline_diag_style);
    try std.testing.expectEqual(CoverageChipMode.feature, c.ui.coverage_chip_mode);
    try std.testing.expectEqual(ExpandIndicator.chevron, c.ui.expand_indicator);
    try std.testing.expectEqual(@as(u16, 8), c.ui.hover_help_height);
    try std.testing.expectEqualStrings("terminal", c.ui.terminal_label);
    try std.testing.expectEqual(TabBarAiIcon.claude_code, c.ui.tab_bar_ai_icon);
    // The maximize button zooms by default; full screen is the choice.
    try std.testing.expectEqual(MaximizeClick.zoom_pane, c.ui.maximize_click);
    try std.testing.expectEqual(TerminalGlyph.ghostty, c.ui.terminal_glyph);
    try std.testing.expectEqualStrings("", c.ui.terminal_glyph_svg);
    try std.testing.expectEqual(AiLayoutMode.grid, c.ui.ai_layout_mode);
    try std.testing.expect(c.ui.hover_help);
    try std.testing.expect(c.ui.show_workspace_dots);
    try std.testing.expect(!c.ui.first_launch_complete);
    try std.testing.expectEqual(MdEngine.builtin, c.ui.md_preview_engine);
    try std.testing.expectEqual(@as(usize, 4), c.ui.integration_icons.len);
    try std.testing.expectEqualStrings("browser", c.ui.integration_icons[0].id);
    try std.testing.expectEqualStrings("http", c.ui.integration_icons[3].id);
    try std.testing.expect(!c.ui.integration_icons[1].enabled);
    // the rest
    try std.testing.expect(c.session.restore);
    try std.testing.expectEqual(RestoreTerminals.running, c.session.restore_terminals);
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
    try std.testing.expectEqual(IntegrationOpenAs.split, c.integrations.open_as);
    try std.testing.expect(c.integrations.equalize_on_open);
    // The request log is on by default: it has to be there when the
    // slow morning happens, not be switched on afterwards.
    try std.testing.expect(c.integrations.request_log.enabled);
    try std.testing.expect(c.integrations.broker);
    try std.testing.expectEqual(@as(u32, 4), c.integrations.request_log.max_mb);
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
