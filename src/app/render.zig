//! One frame. Row 0 is the palette bar (on a screen at least 80 wide),
//! the last two rows are the statusline and the `:` line, and between
//! them sit the left column — the activity bar down its edge, a `│`,
//! then the section it shows — the split tree and the right column
//! (`app/side.zig`: every section has a side). Every
//! leaf of the split tree carries its own tab strip on its first row —
//! a tab is dragged between leaves, so the strip belongs to the leaf,
//! not to the frame. Then the toasts and the overlay, in that order, so
//! the hit map's back-to-front scan gives the overlay the mouse.
//!
//! // changed: DESIGN said "row 0 is the bufferline, the last row the
//! statusline". The `.test` corpus clicks against Rust mnml's frame —
//! palette bar row 0, tab strip row 1, statusline on the second-last
//! row — so that is the frame painted here.
//!
//! The frame arena is reset here (see `app.zig`'s header): every slice
//! built for a draw lives until the next frame, the hit map included.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const PaneId = app_mod.PaneId;
const Rect = @import("../ui/rect.zig");
const Canvas = @import("../ui/canvas.zig");
const context = @import("../ui/context.zig");
const Ui = context;
const editor_view = @import("../ui/editor_view.zig");
const indent_mod = @import("../editor/indent.zig");
const line_blame = @import("line_blame.zig");
const statusline = @import("../ui/statusline.zig");
const cmdline_bar = @import("../ui/cmdline_bar.zig");
const edge_grip = @import("../ui/edge_grip.zig");
const cmdline_mod = @import("cmdline.zig");
const cmdline_popup_app = @import("cmdline_popup.zig");
const cursor_mod = @import("cursor.zig");
const statusline_app = @import("statusline.zig");
const messages = @import("messages.zig");
const stress = @import("stress.zig");
const clock_mod = @import("clock.zig");
const coverage = @import("coverage.zig");
const menu_bar = @import("menu_bar.zig");
const ui_menu_bar = @import("../ui/menu_bar.zig");
const bufferline = @import("../ui/bufferline.zig");
const brand = @import("../ui/brand.zig");
const side_strip = @import("../ui/side_strip.zig");
const pane_rail = @import("../ui/pane_rail.zig");
const focus_cue = @import("../ui/focus_cue.zig");
const pane_accent = @import("pane_accent.zig");
const welcome_app = @import("welcome.zig");
const keymap = @import("../core/keymap.zig");
const update = @import("update.zig");
const prompt_mod = @import("../ui/prompt.zig");
const confirm_mod = @import("../ui/confirm.zig");
const picker_mod = @import("../ui/picker.zig");
const which_key = @import("../ui/which_key.zig");
const whichkey_glyph = @import("../ui/whichkey_glyph.zig");
const find_bar_mod = @import("../ui/find_bar.zig");
const toast_mod = @import("../ui/toast.zig");
const whichkey = @import("whichkey.zig");
const input = @import("../input/mod.zig");
const overlay_mod = @import("../ui/overlay.zig");
const Theme = @import("../ui/theme.zig");
const Style = vaxis.Style;
const menu_glyph = @import("../ui/menu_glyph.zig");
const discovery = @import("discovery.zig");
const help_app = @import("help.zig");
const help_ui = @import("../ui/help_overlay.zig");
const info_view_app = @import("info_view.zig");
const info_view_ui = @import("../ui/info_view.zig");
const image_pane = @import("image_pane.zig");
const command = @import("../core/command.zig");
const todos = @import("../todos.zig");
const search_section = @import("search_section.zig");
const notes = @import("../notes.zig");
const findings = @import("../findings.zig");
const debug_panel = @import("debug_panel.zig");
const sessions = @import("../sessions.zig");
const dock = @import("dock.zig");
const settings_app = @import("settings.zig");
const settings_ui = @import("../ui/settings.zig");
const first_launch = @import("first_launch.zig");
const first_launch_install = @import("first_launch_install.zig");
const Config = @import("../config/Config.zig");
const flash = @import("flash.zig");
const wizard_ui = @import("../ui/wizard.zig");
const syntax = @import("syntax.zig");
const syntax_jobs = @import("syntax_jobs.zig");
const sticky = @import("sticky.zig");
const outline = @import("outline.zig");
const md_preview = @import("md_preview.zig");
const zon_pane = @import("zon_pane.zig");
const session_changes = @import("session_changes.zig");
const zon_view = @import("../ui/zon_view.zig");
const layout_mod = @import("layout.zig");
const cmd_view = @import("cmd_view.zig");
const cheatsheet = @import("cheatsheet.zig");
const script_pane = @import("script_pane.zig");
const pty_view = @import("../ui/pty_view.zig");
const pty_search = @import("pty_search.zig");
const pty_pane = @import("pty_pane.zig");
const terminal_glyph = @import("terminal_glyph.zig");
const claude_mark = @import("claude_mark.zig");
const list_panel = @import("../ui/list_panel.zig");
const git_app = @import("git.zig");
const git_palette = @import("git_palette.zig");
const ai_app = @import("ai.zig");
const sessions_table = @import("sessions_table.zig");
const spend = @import("spend.zig");
const ai_view = @import("../ui/ai_view.zig");
const spend_view = @import("../ui/spend_view.zig");
const usage_pane = @import("usage_pane.zig");
const ai_apply_view = @import("../ui/ai_apply_view.zig");
const ai_apply = @import("ai_apply.zig");
const tests_pane = @import("tests_pane.zig");
const tests_view = @import("../ui/tests_view.zig");
const flaky = @import("flaky.zig");
const flaky_view = @import("../ui/flaky_view.zig");
const requests_view = @import("../ui/requests_view.zig");
const grep_view = @import("../ui/grep_view.zig");
const dap = @import("dap.zig");
const debug_toolbar = @import("../ui/debug_toolbar.zig");
const lsp = @import("lsp.zig");
const request_pane = @import("request_pane.zig");
const http_app = @import("http.zig");
const decor = @import("lsp_decor.zig");
const script_decor = @import("script_decor.zig");
const conflicts = @import("conflicts.zig");
const semantic_app = @import("lsp_semantic.zig");
const http_panel = @import("http_panel.zig");
const ws_pane = @import("ws_pane.zig");
const browser_pane = @import("browser_pane.zig");
const mount_pane = @import("mount_pane.zig");
const integrations = @import("integrations.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const ipc = @import("../ipc/root.zig");
const files_pane = @import("files_pane.zig");
const scripts_panel = @import("scripts_panel.zig");
const script_section = @import("script_section.zig");
const transfers = @import("transfers.zig");
const activity_bar = @import("activity_bar.zig");
const hover_zones = @import("hover_zones.zig");
const sidebar_auto = @import("sidebar_auto.zig");
const launcher_dock = @import("launcher_dock.zig");
const side_mod = @import("side.zig");
const bottom_mod = @import("bottom.zig");
const rail_mod = @import("../ui/activity_bar.zig");
const sidebar_overlay = @import("../ui/sidebar_overlay.zig");
const icons = @import("../ui/icons.zig");

/// Below this width the palette bar row is not painted at all (a tiny
/// screen); Rust's chrome row needs its 48-cell cluster or shows the
/// workspace chip alone.
pub const palette_bar_min_width: u16 = 40;

/// // changed (edge-grip): the screen a bottom launcher dock needs
/// before it takes the last row. Its own row, plus the bar, the
/// statusline and the `:` line, plus the four rows the editor area
/// kept under the old carve — so a frame that could hold the strip
/// before still can. `hover_zones.dockBand` reads it too, so the
/// reveal band and the carve appear and disappear together.
pub const dock_bottom_min_height: u16 = launcher_dock.height + 8;
/// The divider hit ids the split tree does not use (`.divider` is
/// otherwise an index into the split tree's dividers).
pub const tree_divider_id: u32 = std.math.maxInt(u32);
pub const right_divider_id: u32 = std.math.maxInt(u32) - 1;
/// // changed (bottom-dock): the dock's own divider, the row above it.
pub const bottom_divider_id: u32 = std.math.maxInt(u32) - 2;
/// The info view's top rule (`ui/info_view.zig`): its height.
pub const info_divider_id: u32 = std.math.maxInt(u32) - 3;
/// // changed (bottom-dock): rows the frame's upper area needs before a
/// dock is carved at all — Rust's `upper.height >= 6`.
pub const bottom_upper_min: u16 = 6;

/// `.button` ids the frame registers. The chrome row's fixed buttons
/// are 1..0x10; the integration chips own 0x10..0x40
/// (`integrations_view.chip_base`); the right cluster's tab-page chips
/// 0x40..0x80; `new_tab_base + leaf` is the `+` on that leaf's strip;
/// toasts own `toast.button_base` and up.
pub const Button = enum(u32) {
    /// The workspace chip: the command palette.
    palette = 1,
    toggle_tree = 2,
    toggle_right_panel = 3,
    /// The strip's AI chips, when the integrations are enabled.
    ai_claude = 4,
    ai_codex = 5,
    /// ` ← ` / ` → ` beside the chip: the previous / next buffer.
    back = 6,
    forward = 7,
    /// The ` ▾ ` on the chip: the recent-files picker.
    dropdown = 8,
    /// The right cluster: ` + ` (a tab page), ` TABS `, the theme pill, ` × `.
    new_tab_page = 9,
    tabs_label = 10,
    theme_toggle = 11,
    window_close = 12,
    /// The strip's right end: a shell, split right, split down, maximize.
    split_term = 13,
    split_right = 14,
    split_down = 15,
    split_max = 16,
    /// The strip's ` +N hidden ` chip: the buffer picker.
    hidden_tabs = 17,
    /// The right column's strip: its `×` closes the column, its chip
    /// focuses the column, its ` 󰐕 ` opens the add-panel menu.
    right_close = 18,
    right_tab = 19,
    right_new = 20,
    /// Full screen's corner mark: the one cell of chrome kept, at the
    /// body's top-right; a click leaves (`drawFullscreenMark`).
    fullscreen_exit = 21,
    /// // changed (bottom-dock): the dock's `×` — it hides the dock,
    /// as the `×` on Rust's bottom-panel header does.
    bottom_close = 22,
    /// // changed (bottom-row): the row under the statusline. The bar
    /// itself opens the `:` line; the `⟳ … running…` indicator aborts
    /// the work it reports; the echoed toast's `[name]` reveals the
    /// pane it names.
    cmdline_bar = 23,
    cmdline_inflight = 24,
    cmdline_mention = 25,
    /// // changed (sidebar-autohide): the revealed side column. The
    /// panel's own cells swallow a press that no part of the section
    /// claimed, so it cannot fall through onto the editor underneath;
    /// the pin chip docks the column for the session.
    sidebar_overlay = 26,
    sidebar_pin = 27,
    /// // changed (menu-bar-pin): the chip past the menu bar's words.
    /// It paints only while `ui.menu_bar` can hide the bar, and keeps
    /// the words up for the session.
    menu_bar_pin = 28,
    /// // changed (edge-grip): the `⋯` / `⋮` handle at the middle of a
    /// hidden slide-in's edge (`ui/edge_grip.zig`). A left click
    /// reveals AND pins the surface it marks — the same pin the chip
    /// at the other end of the revealed surface toggles — and a right
    /// click opens that surface's own menu, so the grip answers
    /// everything its chip does.
    edge_grip_menu_bar = 29,
    edge_grip_sidebar_left = 30,
    edge_grip_sidebar_right = 31,
    edge_grip_dock = 32,
    /// The right cluster's tab-page chips and their `×`, 32 pages each.
    tab_page_base = 0x40,
    tab_page_close_base = 0x60,
    /// The tab strip's `‹` / `›` overflow markers, one pair per leaf
    /// (`tabScroll`); leaves 0..63.
    tab_scroll_left_base = 0x80,
    tab_scroll_right_base = 0xC0,
    new_tab_base = 0x100,
    _,

    pub fn tabPage(page: usize) u32 {
        return @intFromEnum(Button.tab_page_base) + @as(u32, @intCast(@min(page, 31)));
    }

    pub fn tabPageClose(page: usize) u32 {
        return @intFromEnum(Button.tab_page_close_base) + @as(u32, @intCast(@min(page, 31)));
    }

    /// The tab page a chip id names, if it is one.
    pub fn tabPageOf(id: u32) ?usize {
        const b: u32 = @intFromEnum(Button.tab_page_base);
        if (id < b or id >= @intFromEnum(Button.tab_page_close_base)) return null;
        return id - b;
    }

    pub fn tabPageCloseOf(id: u32) ?usize {
        const b: u32 = @intFromEnum(Button.tab_page_close_base);
        if (id < b or id >= @intFromEnum(Button.tab_scroll_left_base)) return null;
        return id - b;
    }

    pub const ScrollDir = enum { left, right };
    pub const TabScroll = struct { leaf: usize, dir: ScrollDir };

    pub fn tabScroll(leaf: usize, dir: ScrollDir) u32 {
        const base: u32 = @intFromEnum(if (dir == .left) Button.tab_scroll_left_base else Button.tab_scroll_right_base);
        return base + @as(u32, @intCast(@min(leaf, 63)));
    }

    /// The leaf and direction a marker id names, if it is one.
    pub fn tabScrollOf(id: u32) ?TabScroll {
        const l: u32 = @intFromEnum(Button.tab_scroll_left_base);
        const r: u32 = @intFromEnum(Button.tab_scroll_right_base);
        if (id >= l and id < r) return .{ .leaf = id - l, .dir = .left };
        if (id >= r and id < @intFromEnum(Button.new_tab_base)) return .{ .leaf = id - r, .dir = .right };
        return null;
    }

    pub fn newTab(leaf: usize) u32 {
        return @intFromEnum(Button.new_tab_base) + @as(u32, @intCast(leaf));
    }

    /// The leaf a `new_tab_base + leaf` id names, if it is one.
    pub fn newTabLeaf(id: u32) ?usize {
        const base = @intFromEnum(Button.new_tab_base);
        if (id < base or id >= toast_mod.button_base) return null;
        return id - base;
    }
};

/// The statusline's hit ids live with the chips: `app/statusline.zig`.
pub const SegId = statusline_app.SegId;

/// The rows of the frame for a screen, and its two columns.
pub const FrameRects = struct {
    bar: Rect,
    upper: Rect,
    status: Rect,
    cmdline: Rect,
    /// The activity bar (`ui/activity_bar.zig`), carved off the
    /// sidebar's left edge; empty when it is hidden or there is no sidebar.
    rail: Rect = Rect.empty,
    /// The `│` column between the rail and the sidebar's panel.
    rail_border: Rect = Rect.empty,
    /// The left column's panel (the section it shows); empty when the
    /// column is closed.
    sidebar: Rect = Rect.empty,
    /// The one-cell resize divider on the left column's right (`tree_divider_id`).
    sidebar_divider: Rect = Rect.empty,
    /// The right column's panel; empty when the column is closed.
    right: Rect = Rect.empty,
    /// The one-cell resize divider on the right column's left (`right_divider_id`).
    right_divider: Rect = Rect.empty,
    /// // changed (bottom-dock): the dock under the whole frame — the
    /// two columns and the splits all sit above it, as Rust's bottom
    /// panel does (it is carved off `upper` before them). Empty when
    /// the dock is closed or the frame is too short to hold it.
    bottom: Rect = Rect.empty,
    /// The one-row resize divider above the dock (`bottom_divider_id`).
    bottom_divider: Rect = Rect.empty,
    /// // changed (launcher-dock): the launcher dock's strip
    /// (`app/launcher_dock.zig`) when `ui.dock.mode = .always` — the
    /// OUTERMOST band of `upper`, carved before the bottom panel and
    /// before the columns, so a bottom dock is the last row of the
    /// editor area and the panel sits inside it. Empty when the dock
    /// hides, reveals as an overlay, or there is no room.
    launcher_dock: Rect = Rect.empty,
    /// What `upper` leaves for the panes and the dock widgets.
    body: Rect,
};

/// What `frameRects` is told about the columns — it reads no app.
pub const Chrome = struct {
    /// The left column's width when it is open. Rust's `tree_width`: the
    /// rail and its border are carved from it, not added to it.
    sidebar: ?u16 = null,
    /// The right column's width when it is open (`ui.right_panel_width`).
    right: ?u16 = null,
    /// // changed (bottom-dock): the dock's height in rows when it is
    /// open (`ui.bottom_panel_height`).
    bottom: ?u16 = null,
    /// Whether the activity bar paints (`activity_bar.shown`).
    rail: bool = true,
    /// // changed (launcher-dock): which edge the launcher dock claims
    /// this frame, or null when it is hidden or only revealed as an
    /// overlay (`launcher_dock.docked`).
    /// // changed (side-band): a SIDE dock claims its band for as long
    /// as it is not `hidden`, whether the strip is up or down
    /// (`launcher_dock.banded`) — the band belongs to the surface, not
    /// to the moment. A bottom dock is unchanged: only `.always`.
    dock: ?Config.DockEdge = null,
    /// // changed (dock-placement): where a BOTTOM dock is carved from
    /// — `.inner` (the default) off the editor area's last row, so the
    /// statusline and the `:` line do not move, `.outer` off the
    /// screen's last row, under them both. A side dock ignores it.
    dock_placement: Config.DockPlacement = .inner,
};

/// The frame's `Chrome` for this app, this frame.
pub fn chrome(app: *const App) Chrome {
    // // changed (sidebar-autohide): a column the overlay is carrying,
    // or one `ui.sidebar` is hiding, is NOT carved here — which is the
    // whole point. `drawSidebarOverlay` paints it later, over the
    // editor, and every pane keeps the rect (and every pty the size) it
    // had; `frameRects` never learns the panel exists.
    return .{
        // A narrow terminal (`ui.sidebar_auto_below`) is in the auto-hide
        // regime too, through `sidebar_auto.mode`: one rule.
        .sidebar = if (!app.zen and !sidebar_auto.autoHiding(app) and side_mod.shown(app, .left) != null) app.tree.width else null,
        .right = if (!app.zen and !sidebar_auto.autoHiding(app) and side_mod.shown(app, .right) != null) app.side.right_width else null,
        .bottom = if (!app.zen and bottom_mod.open(app)) app.side.bottom_height else null,
        .rail = activity_bar.shown(app),
        // // changed (side-band): the dock's BAND is carved, which on a
        // side edge means for as long as the dock lives there — so the
        // strip fills a band that is already its own and a reveal
        // reflows nothing and covers nothing. On the bottom edge the
        // old rule stands: only an `always` strip is carved, a revealed
        // one is paint over the `:` line's row (`launcher_dock.banded`).
        .dock = if (launcher_dock.banded(app)) app.cfg.ui.dock.edge else null,
        .dock_placement = launcher_dock.placement(app),
    };
}

/// Palette bar on top when wide enough; the statusline and the `:`
/// line at the bottom; the rest in between. A tiny screen gives up the
/// `:` line, then the bar, before it gives up the statusline.
///
/// The left column takes its width (clamped so the panes keep 21
/// columns, never under 8) plus a one-cell divider off the left of
/// `upper`; the rail takes its three cells off the column's left, then
/// a border column when the column has more than two cells to spare
/// (Rust `ui/mod.rs`). The tree's `│` divider therefore stays where it
/// was with or without the rail. The right column takes its width plus
/// a divider off the far side of what is left, under the same clamp
/// (Rust's right panel).
///
/// // changed (bottom-dock): the dock is carved off the bottom of
/// `upper` FIRST — the columns and the splits are all above it, which
/// is where Rust's bottom panel sits (`ui/mod.rs` splits the screen,
/// takes the panel's rows off `upper`, then lays the tree out in what
/// is left). Its rows plus a divider row need `upper` to be at least
/// six deep, and never take more than two thirds of it, so the editor
/// keeps rows whatever height the user drags to.
pub fn frameRects(full: Rect, ch: Chrome) FrameRects {
    var r = full;
    // ── the bottom launcher dock ──
    // // changed (edge-grip): it comes off the SCREEN's last row,
    // under the `:` line, before anything else is carved — the dock is
    // the frame's outermost edge, which is the row its reveal band
    // watches in every other mode (`hover_zones.dockBand`). The bottom
    // panel / statusline / `:` line keep their order inside what is
    // left. A side dock is still carved off `upper` below.
    // // changed (dock-placement): only `.outer` takes that row. An
    // `.inner` bottom dock is carved off `upper` below, with the side
    // docks, so the statusline and the `:` line stay where they are.
    var dock_bottom = Rect.empty;
    if (ch.dock == .bottom and ch.dock_placement == .outer and full.h >= dock_bottom_min_height) {
        const rows = r.splitBottom(launcher_dock.height);
        r = rows.top;
        dock_bottom = rows.rest;
    }
    var bar = Rect.empty;
    if (full.w >= palette_bar_min_width and full.h >= 5) {
        const s = r.splitTop(1);
        bar = s.top;
        r = s.rest;
    }
    var cmdline = Rect.empty;
    if (r.h >= 4) {
        const s = r.splitBottom(1);
        cmdline = s.rest;
        r = s.top;
    }
    const s = r.splitBottom(1);
    var fr: FrameRects = .{ .bar = bar, .upper = s.top, .status = s.rest, .cmdline = cmdline, .body = s.top, .launcher_dock = dock_bottom };
    // ── launcher dock ──
    // A SIDE dock is the outermost band of the editor area:
    // everything else — the bottom panel, both columns, the splits —
    // is carved out of what is left, so the dock reads as the frame's
    // own edge. The bottom one is already off the screen's last row.
    if (ch.dock) |dock_edge| switch (dock_edge) {
        // // changed (dock-placement): an `.inner` bottom dock is the
        // outermost band of the EDITOR AREA — the row above the
        // statusline — carved before the bottom panel and the columns,
        // so the panel sits inside it exactly as it does on a side
        // edge. An `.outer` one already came off the screen's last row.
        .bottom => if (ch.dock_placement == .inner and fr.upper.h >= launcher_dock.height + 4) {
            const rows = fr.upper.splitBottom(launcher_dock.height);
            fr.upper = rows.top;
            fr.launcher_dock = rows.rest;
            fr.body = fr.upper;
        },
        .left => if (fr.upper.w >= launcher_dock.side_min_width) {
            const cols = fr.upper.splitLeft(launcher_dock.width);
            fr.launcher_dock = cols.left;
            fr.upper = cols.rest;
            fr.body = fr.upper;
        },
        .right => if (fr.upper.w >= launcher_dock.side_min_width) {
            const cols = fr.upper.splitRight(launcher_dock.width);
            fr.upper = cols.left;
            fr.launcher_dock = cols.rest;
            fr.body = fr.upper;
        },
    };
    // ── bottom dock ──
    if (ch.bottom) |bh| if (fr.upper.h >= bottom_upper_min) {
        // Rust's two-thirds cap, and — since the Zig dock also spends a
        // row on its divider — a floor of two rows for the body, so
        // the dock can never take the editor's last row.
        const two_thirds: u16 = @intCast(@as(u32, fr.upper.h) * 2 / 3);
        const max_allowed: u16 = @min(two_thirds, fr.upper.h -| 3);
        const want: u16 = @max(bh, Config.bottom_panel_height_min);
        const h: u16 = @max(@min(want, max_allowed), Config.bottom_panel_height_min);
        const rows = fr.upper.splitBottom(h);
        const div = rows.top.splitBottom(1);
        fr.upper = div.top;
        fr.bottom_divider = div.rest;
        fr.bottom = rows.rest;
        fr.body = fr.upper;
    };
    // ── rail ──
    if (ch.sidebar) |tw| if (fr.upper.w > 12) {
        const w: u16 = @max(@min(tw, fr.upper.w -| 21), 8);
        const cols = fr.upper.splitLeft(w);
        const div = cols.rest.splitLeft(1);
        var side = cols.left;
        if (ch.rail) {
            const bar_w: u16 = @min(rail_mod.width, side.w);
            const rs = side.splitLeft(bar_w);
            fr.rail = rs.left;
            side = rs.rest;
            if (w > bar_w + 2) {
                const bs = side.splitLeft(1);
                fr.rail_border = bs.left;
                side = bs.rest;
            }
        }
        fr.sidebar = side;
        fr.sidebar_divider = div.left;
        fr.body = div.rest;
    };
    // ── right column ──
    if (ch.right) |rw| if (fr.body.w > 21 + 8) {
        const w: u16 = @max(@min(rw, fr.body.w -| 21), 8);
        const cols = fr.body.splitRight(w);
        const div = cols.left.splitRight(1);
        fr.body = div.left;
        fr.right_divider = div.rest;
        fr.right = cols.rest;
    };
    return fr;
}

/// Zen: only the `:` line is kept (a vim user leaves through it).
pub fn zenRects(full: Rect) FrameRects {
    if (full.h < 2) return .{ .bar = Rect.empty, .upper = full, .status = Rect.empty, .cmdline = Rect.empty, .body = full };
    const s = full.splitBottom(1);
    return .{ .bar = Rect.empty, .upper = s.top, .status = Rect.empty, .cmdline = s.rest, .body = s.top };
}

/// The whole screen as a rect.
fn screenRect(screen: *vaxis.Screen) Rect {
    return Rect.init(0, 0, screen.width, screen.height);
}

pub fn render(app: *App, screen: *vaxis.Screen) Allocator.Error!void {
    // What the pointer rests on, read off the previous frame's hits
    // BEFORE `begin` hands their memory back: the info view's dictionary
    // allocates on the new frame, and a hit list read after that is a
    // hit list being overwritten (a segfault in `entryAt`).
    info_view_app.snapshotHover(app);
    app.frame.begin();
    // The frame's dwell zones, before anything asks whether an `auto`
    // surface is showing: `begin` swaps in what the previous frame's
    // painters registered (the rail's rect) and re-derives the ones
    // that need no paint (a screen edge, the bar's row).
    hover_zones.begin(app, screenRect(screen), app.now_ms);
    // …and the reveal / hide clock that reads them, so a `.test` script
    // that only renders still advances it (`App.tick` calls this too;
    // both are idempotent at one `now`).
    sidebar_auto.tick(app, app.now_ms);
    launcher_dock.tick(app, app.now_ms);
    // The info view reads the target snapshotted above: what the
    // pointer is resting on until this frame replaces it.
    const help_copy: ?info_view_ui.Copy = if (app.cfg.ui.hover_help and side_mod.shown(app, .left) != null and !app.zen) try info_view_app.pick(app, app.frame.allocator()) else null;
    // The frame's rects read the previous frame's hits too (an `auto`
    // rail stays while the pointer rests on it).
    const fr = if (app.zen) zenRects(screenRect(screen)) else frameRects(screenRect(screen), chrome(app));
    app.hits.reset();
    // The image paints are the frame's too (`Term.paintImages` reads
    // them after the cells are out).
    app.image_paints = .empty;
    const arena = app.frame.allocator();
    const ui: Ui = .{
        .canvas = Canvas.init(screen, .{}),
        .hits = &app.hits,
        .theme = &app.theme,
        .arena = arena,
        .focus = app.focus,
        .hover = if (app.hover) |h| .{ .x = h.x, .y = h.y } else null,
        .ascii = app.cfg.ui.ascii_icons,
        .triangle = app.cfg.ui.expand_indicator == .triangle,
        .focus_cue = app.cfg.ui.focus_cue,
    };
    const full = ui.canvas.full();
    ui.canvas.fill(full, app.theme.bg);
    // ── the frame's one cursor ──
    // Nothing between here and `applyCursor` at the end of the frame
    // touches `screen.cursor_vis` / `cursor` / `cursor_shape`; a
    // surface that takes typing writes `app.cursor_pos` instead, and
    // draw order settles which one wins (`app/cursor.zig`).
    app.cursor_pos = null;
    app.cursor_shape = .bar;
    app.cursor_blink = app.cfg.editor.cursor_blink;
    app.cursor_from_child = false;

    // Zen: the panes fill everything above the `:` line — no bar, no
    // tree, no right panel, no strips, no statusline (`zen.zig`).
    try drawPaletteBar(app, ui, fr.bar);
    // The info view says where it is when it paints (the corridor).
    app.info_view.rect = null;
    var panes_area = fr.body;
    if (!fr.sidebar.isEmpty()) {
        // ── rail ──
        // The activity bar down the sidebar's left edge, and the `│`
        // between it and the tree — `t.line` on the rail's ground, as
        // Rust paints it, so no panel fill butts against the icons.
        if (!fr.rail.isEmpty()) {
            rail_mod.draw(ui, fr.rail, try activity_bar.props(app, ui.arena));
            // An `auto` rail stays up while the pointer rests on it —
            // the rail's own zone, for the next frame.
            hover_zones.register(app, .{ .rect = fr.rail, .id = .rail_left, .priority = hover_zones.prio_rail });
        }
        if (!fr.rail_border.isEmpty()) {
            const pal = app.theme.palette;
            const line = Theme.withFg(Theme.onBg(app.theme.border, pal.bg_darker), pal.line);
            ui.canvas.fill(fr.rail_border, line);
            ui.vrule(fr.rail_border.x, fr.rail_border.y, fr.rail_border.h, line);
        }
        // ── left column ──
        // `ui.hover_help`: the column's bottom `hover_help_height` rows
        // are the info view, clamped so the section above keeps six
        // (`info_view.boxRows`); a column too short for four rows and
        // the six has no box. The section takes the rest.
        var side = fr.sidebar;
        if (help_copy) |copy| if (info_view_app.boxRows(side.h, app.cfg.ui.hover_help_height)) |rows| {
            const parts = side.splitBottom(rows);
            side = parts.top;
            const focused = app.focus == .info_view;
            // Its top rule is a divider like the column's edge: it
            // lights under the pointer and while it is being dragged.
            const dragging = if (app.drag) |d| d == .info_divider else false;
            const l = info_view_ui.draw(ui, parts.rest, .{ .copy = copy, .scroll = app.info_view.scroll, .pinned = info_view_app.isPinned(app), .focused = focused, .cursor = if (focused) app.info_view.cursor else null, .rule = .{ .hit = .{ .divider = info_divider_id }, .lit = dragging, .lit_style = app.theme.accent } });
            // The column the drag measures against.
            app.info_view.column = fr.sidebar;
            app.info_view.max_scroll = l.max_scroll;
            // The keyboard's row pulled the view along.
            app.info_view.scroll = l.scroll;
            // Where the box is, for the next frame's corridor.
            app.info_view.rect = parts.rest;
        };
        if (side_mod.shown(app, .left)) |s| try drawColumn(app, ui, side, s);
        drawDivider(app, ui, fr.sidebar_divider, tree_divider_id);
    }
    // ── right column ──
    // Rust's right panel carries a strip row above its content — the
    // pane's title and a `×` — so a pane-backed section (the outline,
    // diagnostics) lands one row down. A section moved to the right
    // is still a section: it starts with its caps header, as on the
    // left, and gets no strip.
    if (!fr.right.isEmpty()) {
        drawDivider(app, ui, fr.right_divider, right_divider_id);
        if (side_mod.shown(app, .right)) |s| {
            var area = fr.right;
            if (area.h >= 2 and side_mod.hasStrip(s)) {
                const parts = area.splitTop(1);
                try drawRightStrip(app, ui, parts.top, s);
                area = parts.rest;
            }
            try drawColumn(app, ui, area, s);
        }
    }
    // ── bottom dock ──
    if (!fr.bottom.isEmpty()) {
        drawHDivider(app, ui, fr.bottom_divider, bottom_divider_id);
        try drawBottomDock(app, ui, fr.bottom);
    }
    // The dock's inline strips come off the body; its widgets paint
    // over whatever the panes drew.
    const dock_area = panes_area;
    if (!app.zen) panes_area = dock.bodyAfterStrips(dock_area, dock.strips(dock_area, app.dock.widgets.items, app.dock.hidden));
    app.panes_area = panes_area;
    try drawBody(app, ui, panes_area);
    if (app.zen) try drawFullscreenMark(app, ui, panes_area);
    if (!app.zen) try dock.draw(app, ui, dock_area);
    // ── the revealed side column ──
    // Over the panes and the dock, under the toasts and the overlays:
    // the hits it registers here are the last word on every cell it
    // covers (`HitMap.at` scans back to front).
    if (!app.zen) try drawSidebarOverlay(app, ui, fr);
    if (!app.zen) try drawStatusline(app, ui, fr.status);
    try drawCmdline(app, ui, fr.cmdline);
    // ── the launcher dock ──
    // Over the panes, the dock widgets AND the revealed side column:
    // the strip owns the frame's outermost band, so nothing paints on
    // top of it (`app/launcher_dock.zig`, the outer-band rule).
    // // changed (edge-grip): and over the `:` line's row too, which is
    // where a revealed bottom strip now lands — so it paints AFTER
    // `drawCmdline`, and its hits are the last word on those cells.
    // An open `:` line refuses the reveal, so nothing in use is hidden.
    // // changed (side-band): the band and the strip are two questions
    // now. `fr.launcher_dock` is the band the frame RESERVED — on a
    // side edge that is there whenever the dock lives on it — and the
    // strip paints into it only while it is actually up. A reserved
    // band with the strip down is left as the frame's own ground, with
    // nothing in it but the grip: inert, which is exactly what the
    // grip's contract needs.
    if (!app.zen) {
        const band = if (!fr.launcher_dock.isEmpty()) fr.launcher_dock else if (launcher_dock.revealed(app)) launcher_dock.overlayRect(app, screenRect(screen)) else Rect.empty;
        const strip = if (launcher_dock.shown(app)) band else Rect.empty;
        if (!strip.isEmpty()) try launcher_dock.draw(app, ui, strip) else app.launcher_dock.rect = .empty;
    }
    // ── the edge grips ──
    // Last of the frame's chrome, so a grip's hit is the last word on
    // its three cells: the dock's sits on the `:` line's row, whose
    // own hit `drawCmdline` registered a moment ago, and a click there
    // must pin the dock rather than open a command line
    // (`ui/edge_grip.zig`). The overlays, the toasts and the menus all
    // paint after this and still cover it.
    if (!app.zen) drawEdgeGrips(app, ui, fr, screenRect(screen));
    // The stack sits on the panes' last row, against the statusline, as
    // Rust's does. The Undo chip takes that row when it is up, and so
    // does the flash cue (`drawFlashCue`, right-aligned there): the
    // stack moves up one so neither is covered. It paints BEFORE the
    // overlays, as Rust's `toast_stack::draw` runs before its picker /
    // palette / which-key pass: a toast never covers the last rows of
    // the palette or the which-key menu (walkthrough 1.10) — the
    // overlay is what the user is looking at, the toast waits under it.
    // The one exception is the first-launch wizard: its own toasts —
    // "Claude Code: found" when it comes back from an install pane,
    // the font's terminal hint — are meant to be read with the wizard
    // up, and its box would cover them, so it paints under the stack.
    var toast_area = panes_area;
    if (app.undo_chip) |u| {
        toast_mod.drawUndo(ui, panes_area, u.label);
        toast_area.h -|= 1;
    } else if (app.flash != null) {
        toast_area.h -|= 1;
    }
    const wizard_up = app.overlay == .wizard;
    if (wizard_up) try drawOverlay(app, ui, panes_area);
    toast_mod.draw(ui, toast_area, try app.visibleToasts(arena));
    // The `:` line's completion popup: above the line, over the toasts
    // (it is what the user is typing into), under the overlays. Its
    // ceiling is the row under the tab bar — the panes' first row is
    // the bufferline's.
    try cmdline_popup_app.draw(app, ui, fr.cmdline, panes_area.y + 1);
    if (!wizard_up) try drawOverlay(app, ui, panes_area);
    try lsp.drawPopups(app, ui, panes_area);
    // A context menu is the topmost layer — over the toasts too, whose
    // own menu it is — and it stays above the statusline and the `:`
    // line, whatever it was anchored in.
    if (app.overlay == .menu) drawMenu(ui, Rect.init(full.x, full.y, full.w, fr.upper.bottom() -| full.y), &app.overlay.menu);
    try discovery.drawTooltip(app, ui, full);
    applyCursor(app, screen);
}

/// The frame's last act: hand the one cursor to the terminal.
///
/// Everything above has drawn; `app.cursor_pos` now holds the caret of
/// the frontmost surface that takes typing, or nothing. `cursor.resolve`
/// applies the two rules draw order cannot — a box that takes no typing
/// hides what is under it, and `ui.cursor_shape` overrides the mode —
/// and this is the only place in mnml that writes the three vaxis
/// fields.
///
/// It writes them headless too. Nothing draws a cursor there, so they
/// are simply the frame's honest answer to "where would it be" — which
/// is what `status.json` reports and what a unit test reads.
/// `app.term_cursor` is the separate question of whether a REAL
/// terminal will draw one, and that decides only who paints a stand-in
/// into the cells (`drawPty`'s `paint_focused`).
fn applyCursor(app: *App, screen: *vaxis.Screen) void {
    const want: ?cursor_mod.Want = if (app.cursor_pos) |p| .{
        .pos = p,
        .shape = app.cursor_shape,
        .blink = app.cursor_blink,
        .from_child = app.cursor_from_child,
    } else null;
    const operator_popup = if (app.activeEditor()) |e| e.buf.input.operatorMenuHint() != null else false;
    app.cursor_out = cursor_mod.resolve(want, .{
        .blocked = cursor_mod.blocks(app.overlay, app.menu_bar.open != null, operator_popup),
        .pref = switch (app.cfg.ui.cursor_shape) {
            .terminal => .terminal,
            .block => .block,
            .bar => .bar,
            .underline => .underline,
        },
    });
    if (app.cursor_out) |c| {
        screen.cursor_vis = true;
        screen.cursor = .{ .row = c.pos.y, .col = c.pos.x };
        screen.cursor_shape = cursor_mod.decscusr(c.shape, c.blink);
    } else {
        screen.cursor_vis = false;
        // Back to the terminal's own shape: mnml is not asking for one.
        screen.cursor_shape = .default;
    }
}

// ── full screen's corner mark ──

/// The one cell of chrome full screen keeps: the strip's restore glyph
/// (its ASCII twin under `--ascii`), muted, at the body's top-right —
/// lit while the pointer rests on it — registered as the button whose
/// click leaves. The statusline that would show the way is not
/// painted, so this is where the mouse finds it (Rust repurposes the
/// strip's maximize button the same way).
fn drawFullscreenMark(app: *App, ui: Ui, body: Rect) Allocator.Error!void {
    if (body.isEmpty()) return;
    const cell = Rect.init(body.right() - 1, body.y, 1, 1);
    const pal = app.theme.palette;
    const style: Theme.Style = if (ui.hovered(cell)) app.theme.accent else .{ .fg = pal.comment, .bg = pal.bg };
    _ = ui.putStr(cell.x, cell.y, 1, if (ui.ascii) bufferline.restore_ascii else bufferline.restore_glyph, style);
    try ui.hits.add(ui.arena, cell, .{ .button = @intFromEnum(Button.fullscreen_exit) });
}

// ── palette bar ──

/// The chrome row, as the Rust editor paints it: the menu words at the
/// left (`ui/menu_bar.zig`), the centred nav cluster and workspace chip,
/// the right cluster (`bufferline.drawCluster`) and, in the gap between
/// them, the enabled integration chips — the browser globe by default.
/// // changed (edge-grip): the `⋯` / `⋮` handles at the middle of each
/// hidden slide-in's edge (`ui/edge_grip.zig`). Each one is placed in
/// the very band `hover_zones` watches — the grip names the zone's own
/// cell and is never a second way in — so dwelling on it reveals the
/// surface because it is INSIDE the zone, and a click on it reveals
/// and pins.
///
/// It runs last of the frame's chrome for one reason: the dock's grip
/// sits on the `:` line's row, whose whole-row hit `drawCmdline` has
/// just registered, and `HitMap.at` scans back to front — so a click
/// on those three cells pins the dock instead of opening a command
/// line the user did not ask for.
fn drawEdgeGrips(app: *App, ui: Ui, fr: FrameRects, full: Rect) void {
    const bg = app.theme.bg.bg;
    const dock_band = hover_zones.dockBand(app, full);
    // ── the menu bar: the middle of the run its WORDS take ──
    // Not the middle of the row: that is the workspace chip's, and the
    // chip never hides, so a grip there would paint through its name.
    // The words' run is the left of the row (`ui_menu_bar.wordsRun`) —
    // the cells the grip is actually summoning.
    if (!fr.bar.isEmpty() and menu_bar.gripShown(app, fr.bar.y)) {
        if (hover_zones.barRow(full)) |row| if (edge_grip.place(ui_menu_bar.wordsRun(row), .top)) |cell| {
            edge_grip.draw(ui, cell, .top, .{ .bg = app.theme.palette.bg_dark, .hit = .{ .button = @intFromEnum(Button.edge_grip_menu_bar) } });
        };
    }
    // ── the side columns: the middle of each one's screen edge ──
    for ([_]Config.ColumnSide{ .left, .right }) |s| {
        if (!sidebar_auto.gripShown(app, s)) continue;
        const band = hover_zones.sidebarEdge(app, full, s);
        const cell = edge_grip.place(band, if (s == .left) .left else .right) orelse continue;
        edge_grip.draw(ui, cell, if (s == .left) .left else .right, .{
            .bg = bg,
            .hit = .{ .button = @intFromEnum(if (s == .left) Button.edge_grip_sidebar_left else Button.edge_grip_sidebar_right) },
        });
    }
    // ── the launcher dock: the middle of its band, whichever edge ──
    if (launcher_dock.gripShown(app)) {
        if (dock_band) |band| {
            const e: edge_grip.Edge = switch (launcher_dock.edge(app)) {
                .bottom => .bottom,
                .left => .left,
                .right => .right,
            };
            if (edge_grip.place(band, e)) |cell| edge_grip.draw(ui, cell, e, .{
                .bg = bg,
                .hit = .{ .button = @intFromEnum(Button.edge_grip_dock) },
            });
        }
    }
}

fn drawPaletteBar(app: *App, ui: Ui, bar: Rect) Allocator.Error!void {
    if (bar.isEmpty()) return;
    const words = menu_bar.shown(app, bar.y);
    const layout = ui_menu_bar.draw(ui, bar, .{
        .labels = if (words) &menu_bar.labels else &.{},
        .open = if (app.menu_bar.open) |m| @intFromEnum(m) else null,
        .workspace = std.fs.path.basename(app.workspace),
        .tree_open = app.tree.visible,
        .right_open = side_mod.shown(app, .right) != null,
        .nav_enabled = app.panes.count() > 1,
        .pin = if (menu_bar.pinShown(app, bar.y)) app.menu_bar.pinned else null,
    }, .{
        .word_base = menu_bar.button_base,
        .overflow = menu_bar.overflow_button,
        .pin = @intFromEnum(Button.menu_bar_pin),
        .sidebar = @intFromEnum(Button.toggle_tree),
        .back = @intFromEnum(Button.back),
        .forward = @intFromEnum(Button.forward),
        .chip = @intFromEnum(Button.palette),
        .dropdown = @intFromEnum(Button.dropdown),
        .right_panel = @intFromEnum(Button.toggle_right_panel),
    });
    menu_bar.notePainted(app, bar.y, layout.word_x, layout.first_hidden, layout.words_end);
    const right_edge = layout.palette_right_edge orelse return;
    // The right cluster: the tab pages, the theme pill, the quit `×`.
    const pages = app.layouts.layouts.items;
    const dirty = try ui.arena.alloc(bool, pages.len);
    for (pages, dirty) |*l, *d| {
        d.* = false;
        for (try l.allPanes(ui.arena)) |id| if (app.panes.get(id)) |p| if (p.dirty()) {
            d.* = true;
        };
    }
    var cluster: bufferline.Cluster = .{
        .pages = @intCast(pages.len),
        .active = @intCast(app.layouts.active),
        .dirty = dirty,
        .on_alt = if (app.cfg.ui.theme_toggle) |alt| std.ascii.eqlIgnoreCase(app.theme.name, alt) else false,
    };
    const pref: bufferline.ClusterPref = switch (app.cfg.ui.top_bar_cluster_mode) {
        .auto => .auto,
        .expanded => .expanded,
        .compact => .compact,
    };
    const fit = bufferline.pickCluster(bar, right_edge, cluster, pref) orelse return;
    cluster.compact = fit.compact;
    const cluster_area = Rect.init(bar.right() - fit.w, bar.y, fit.w, 1);
    bufferline.drawCluster(ui, cluster_area, cluster, .{
        .new_tab = @intFromEnum(Button.new_tab_page),
        .tabs_label = @intFromEnum(Button.tabs_label),
        .page_base = @intFromEnum(Button.tab_page_base),
        .page_close_base = @intFromEnum(Button.tab_page_close_base),
        .theme = @intFromEnum(Button.theme_toggle),
        .close = @intFromEnum(Button.window_close),
    });
    try drawGapChips(app, ui, right_edge, cluster_area.x, bar.y);
}

/// The integration chips between the right-panel toggle and the right
/// cluster, Rust's `paint_integration_chips_in_gap`: from the toggle's
/// right edge, ` glyph ` every five cells, in the muted colour on the
/// bar's ground, a three-cell slot left at the cluster's end; the AI
/// chips paint on the strip instead. A click is `integrations.chipClick`.
fn drawGapChips(app: *App, ui: Ui, left: u16, cluster_left: u16, y: u16) Allocator.Error!void {
    const th = ui.theme;
    const right = cluster_left -| 1;
    if (right <= left) return;
    const avail = right - left;
    if (avail < 3) return;
    const room = (avail - 3) / 5;
    if (room == 0) return;
    const strip = try integrations.chips(app, ui.arena);
    var x = left;
    var painted: usize = 0;
    for (strip, 0..) |chip, i| {
        if (i >= integrations_view.max_chips or painted >= room) break;
        if (!chip.enabled) continue;
        if (std.mem.eql(u8, chip.id, "claude_code") or std.mem.eql(u8, chip.id, "codex")) continue;
        const glyph = if (ui.nerd_font and !ui.ascii and chip.glyph.len > 0) chip.glyph else chip.fallback;
        if (glyph.len == 0) continue;
        const r = Rect.init(x, y, 3, 1);
        _ = ui.putStr(x + 1, y, 1, glyph, .{ .fg = th.palette.comment, .bg = th.palette.bg_dark });
        ui.hit(r, .{ .button = integrations_view.chip_base + @as(u32, @intCast(i)) });
        x += 5;
        painted += 1;
    }
}

/// The strip's AI chips. A product's chip
/// shows when its icon is enabled in `ui.integration_icons`, or when
/// its CLI is on PATH and `ui.tab_bar_ai_icon` names it (`.claude_code`
/// — the default — / `.codex` / `.both`); `.none` hides both. So a
/// fresh install with `claude` on PATH gets the Claude chip with no
/// config, an enabled icon shows whatever the key says, and the
/// `view.tab_bar_ai_*` commands are the way to hide a found CLI's chip.
/// The marks are mnml's own baked glyphs — Rust's
/// `ai_chip_use_mnml_glyphs` resolves to them on both arms and the key
/// is deprecated here too. WHICH mark Claude wears is
/// `ui.claude_mark`'s to say (`claude_mark.mark`); Codex has the one.
fn aiChips(app: *App, ui: Ui) Allocator.Error![]const bufferline.AiChip {
    const want = app.cfg.ui.tab_bar_ai_icon;
    if (want == .none) return &.{};
    var out: std.ArrayListUnmanaged(bufferline.AiChip) = .empty;
    // The marks wear their product's colour, not the theme's accent:
    // Claude's is Anthropic's orange (`ui/brand.zig`, the same value the
    // statusline chip and a Claude pty tab paint); Codex has no
    // published brand, so it keeps the theme's cyan. Neither changes
    // with what is running — a chip in this cluster is a button, and
    // the four beside it look the same whatever state they act on
    // (`ui/bufferline.zig`'s `AiChip`).
    if (aiChipShown(app, .claude)) {
        // Which Claude mark this is comes from `ui.claude_mark`
        // (`claude_mark.mark`) — the chip, a Claude pty tab, the
        // statusline meter and the dock all read the one resolver, so
        // the right-click menu's choice lands on every one of them.
        const m = claude_mark.mark(app);
        try out.append(ui.arena, .{ .id = @intFromEnum(Button.ai_claude), .glyph = m.glyph, .fallback = m.fallback, .fg = brand.claude });
    }
    if (aiChipShown(app, .codex)) try out.append(ui.arena, .{ .id = @intFromEnum(Button.ai_codex), .glyph = bufferline.codex_glyph, .fallback = ">", .fg = app.theme.palette.cyan });
    return out.items;
}

fn aiChipShown(app: *App, product: Config.AiProduct) bool {
    const want = app.cfg.ui.tab_bar_ai_icon;
    const id: []const u8 = switch (product) {
        .claude => "claude_code",
        .codex => "codex",
    };
    if (integrationEnabled(app, id)) return true;
    const named = switch (product) {
        .claude => want == .claude_code or want == .both,
        .codex => want == .codex or want == .both,
    };
    return named and first_launch_install.cliOnPath(app, product);
}

fn integrationEnabled(app: *const App, id: []const u8) bool {
    for (app.cfg.ui.integration_icons) |ic| if (std.mem.eql(u8, ic.id, id)) return ic.enabled;
    return false;
}

// ── end palette bar ──

fn drawDivider(app: *App, ui: Ui, r: Rect, id: u32) void {
    const dragging = if (app.drag) |d| switch (d) {
        .tree_divider => id == tree_divider_id,
        .right_divider => id == right_divider_id,
        else => false,
    } else false;
    const style = if (dragging or ui.hovered(r)) app.theme.accent else app.theme.border;
    ui.canvas.fill(r, style);
    ui.vrule(r.x, r.y, r.h, style);
    ui.hit(r, .{ .divider = id });
}

/// The dock's divider — the same cell treatment lying down.
/// // changed (bottom-dock).
fn drawHDivider(app: *App, ui: Ui, r: Rect, id: u32) void {
    if (r.isEmpty()) return;
    const dragging = if (app.drag) |d| d == .bottom_divider else false;
    const style = if (dragging or ui.hovered(r)) app.theme.accent else app.theme.border;
    ui.canvas.fill(r, style);
    ui.hrule(r.x, r.y, r.w, style);
    ui.hit(r, .{ .divider = id });
}

/// The dock's content: its hosted panes behind a tab strip, else the
/// section its side shows — the section's own caps header and chips,
/// with a `×` over the header's right end that hides the dock (Rust's
/// bottom-panel header carries the same `×`).
/// // changed (bottom-dock).
fn drawBottomDock(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    ui.canvas.fill(area, app.theme.bg);
    if (bottom_mod.activePane(app)) |id| {
        try ui.hits.add(ui.arena, area, .{ .pane = id });
        var rect = area;
        if (rect.h >= 2) {
            const s = rect.splitTop(1);
            const tabs = try tabsOfList(app, ui, app.bottom.panes.items, id);
            _ = bufferline.draw(ui, s.top, tabs, .{ .leaf = bottom_mod.strip_leaf, .focused = paneFocused(app, id) });
            rect = s.rest;
        }
        try drawPaneContent(app, ui, id, rect);
        return;
    }
    const s = side_mod.shown(app, .bottom) orelse return;
    try drawColumn(app, ui, area, s);
    drawBottomClose(app, ui, area);
}

/// The ` × ` at the dock header's right end. It paints after the
/// section so it lands over the header row's empty tail — the dock is
/// the body's width, so nothing of the section's own chips is there.
fn drawBottomClose(app: *App, ui: Ui, area: Rect) void {
    if (area.w < 5 or area.h == 0) return;
    const cell = Rect.init(area.right() - 4, area.y, 3, 1);
    const pal = app.theme.palette;
    const style: Theme.Style = if (ui.hovered(cell)) app.theme.accent else .{ .fg = pal.red, .bg = pal.bg, .bold = true };
    _ = ui.putStr(cell.x, cell.y, 3, if (ui.ascii) " x " else " × ", style);
    ui.hit(cell, .{ .button = @intFromEnum(Button.bottom_close) });
}

/// The panel in the right slot. Only TODOS draws today; the others
/// name themselves until their module lands.
/// The right column's strip: ` <title>` and a `×` at the far end (Rust
/// `right_panel` strip, less the tab chord and the `+` that mean
/// nothing here). The outline is titled with its file, the rest with
/// the section's label.
fn drawRightStrip(app: *App, ui: Ui, row: Rect, s: side_mod.Section) Allocator.Error!void {
    const title: []const u8 = blk: {
        if (s == .outline) if (app.outline_panel) |id| if (app.panes.get(id)) |p| if (p.asOutline()) |o| break :blk try o.tabTitle(ui.arena);
        break :blk s.meta().label;
    };
    _ = side_strip.draw(ui, row, .{
        .title = title,
        .chip_hit = .{ .button = @intFromEnum(Button.right_tab) },
        .plus_hit = .{ .button = @intFromEnum(Button.right_new) },
        .close_hit = .{ .button = @intFromEnum(Button.right_close) },
    });
}

/// `ui.sidebar = .auto` / `.hidden`: the revealed column, painted OVER
/// the editor area. Nothing about it reaches `frameRects` — see
/// `app/sidebar_auto.zig` for why, and for what opens and closes it.
///
/// The panel is laid out at its full docked width every frame and the
/// slide is a widening CLIP over it, so no row inside it reflows or
/// moves while it comes in — a third of the width per frame, three
/// frames, skipped entirely when the frames are not live.
///
/// Inside it, left to right (mirrored on the right column): the rail
/// and its border — `ui.activity_bar = .auto` counts as shown here,
/// since the pointer is on the panel that carries it — the one-row
/// strip with the section's name and the pin chip, the section itself,
/// and the edge rule.
fn drawSidebarOverlay(app: *App, ui: Ui, fr: FrameRects) Allocator.Error!void {
    const s = app.sidebar_auto.open orelse return;
    const upper = fr.upper;
    if (upper.w <= 12 or upper.h == 0) return;
    const side_id: side_mod.Side = if (s == .left) .left else .right;
    const section = side_mod.shown(app, side_id) orelse {
        // The section closed under it (a command, a restored session).
        sidebar_auto.hide(app);
        return;
    };
    const geo = overlayRects(app, upper, s);
    if (geo.all.isEmpty() or geo.clip.isEmpty()) return;
    const clipped = ui.withClip(geo.clip.intersect(upper));
    const pal = app.theme.palette;
    // The ground first, and a swallow hit under everything the panel
    // covers: a press on a cell no part of the section claims must not
    // reach the editor beneath it. The section's own hits are
    // registered after this one, so they win.
    clipped.fill(geo.all, Theme.onBg(app.theme.fg, pal.bg_darker));
    ui.hit(geo.clip.intersect(upper), .{ .button = @intFromEnum(Button.sidebar_overlay) });
    if (!geo.rail.isEmpty()) rail_mod.draw(clipped, geo.rail, try activity_bar.props(app, ui.arena));
    if (!geo.rail_border.isEmpty()) {
        const line = Theme.withFg(Theme.onBg(app.theme.border, pal.bg_darker), pal.line);
        clipped.fill(geo.rail_border, line);
        clipped.vrule(geo.rail_border.x, geo.rail_border.y, geo.rail_border.h, line);
    }
    if (!geo.strip.isEmpty()) _ = sidebar_overlay.drawStrip(clipped, geo.strip, .{
        .title = section.meta().label,
        .pinned = app.sidebar_auto.pinned,
        .pin_hit = .{ .button = @intFromEnum(Button.sidebar_pin) },
    });
    if (!geo.body.isEmpty()) try drawColumn(app, clipped, geo.body, section);
    sidebar_overlay.drawEdge(clipped, geo.edge);
    // The panel keeps itself up while the pointer rests anywhere on it
    // — the second piece of the column's hover zone.
    const on_screen = geo.clip.intersect(upper);
    app.sidebar_auto.rect = on_screen;
    hover_zones.register(app, .{
        .rect = on_screen,
        .id = sidebar_auto.zoneOf(s),
        .dwell_ms = app.cfg.ui.sidebar_reveal_ms,
        .priority = hover_zones.prio_sidebar,
    });
}

/// What the overlay is made of: the panel at its full docked width
/// (`all`) and the part of it the slide has revealed (`clip`).
pub const OverlayRects = struct {
    all: Rect = .empty,
    /// What of `all` is on screen this frame — the whole of it once the
    /// slide is done. The panel is laid out at its full width and
    /// REVEALED through this, so no row inside it moves mid-slide.
    clip: Rect = .empty,
    rail: Rect = .empty,
    rail_border: Rect = .empty,
    strip: Rect = .empty,
    body: Rect = .empty,
    edge: Rect = .empty,
};

/// The overlay's geometry: the docked width under `frameRects`' own
/// clamp, then the same rail / border carve the docked column gets, a
/// strip row and the edge rule — and the slide's clip over the lot.
pub fn overlayRects(app: *const App, upper: Rect, s: sidebar_auto.ColumnSide) OverlayRects {
    if (upper.w <= 12 or upper.h == 0) return .{};
    const side_id: side_mod.Side = if (s == .left) .left else .right;
    const want = side_mod.size(app, side_id);
    const w: u16 = @max(@min(want, upper.w -| 21), 8);
    const st = app.sidebar_auto;
    const frames: u32 = sidebar_auto.slide_frames;
    const done: u32 = @min(@as(u32, st.step) + 1, frames);
    const shown_w: u16 = @intCast(@max(@as(u32, 1), (@as(u32, w) * done) / frames));
    var out: OverlayRects = .{};
    out.all = if (s == .left)
        Rect.init(upper.x, upper.y, w, upper.h)
    else
        Rect.init(upper.right() - w, upper.y, w, upper.h);
    out.clip = if (s == .left)
        Rect.init(upper.x, upper.y, shown_w, upper.h)
    else
        Rect.init(upper.right() - shown_w, upper.y, shown_w, upper.h);
    var rest = out.all;
    // The edge rule comes off the inner side first, so the section's
    // width is the same whichever column it is in.
    if (rest.w > 1) {
        if (s == .left) {
            const e = rest.splitRight(1);
            out.edge = e.rest;
            rest = e.left;
        } else {
            const e = rest.splitLeft(1);
            out.edge = e.left;
            rest = e.rest;
        }
    }
    // The rail: the left column's only, as the docked carve is.
    if (s == .left and app.cfg.ui.activity_bar != .hidden and rest.w > rail_mod.width + 2) {
        const rs = rest.splitLeft(rail_mod.width);
        out.rail = rs.left;
        rest = rs.rest;
        const bs = rest.splitLeft(1);
        out.rail_border = bs.left;
        rest = bs.rest;
    }
    if (rest.h >= 3) {
        const ss = rest.splitTop(1);
        out.strip = ss.top;
        rest = ss.rest;
    }
    out.body = rest;
    return out;
}

/// One column's section, in the column's rect. The painters take a
/// rect and do not care which side they land on. Git mode: the palette
/// takes the tree's place (Rust `ui/mod.rs` on `ActivitySection::Git`).
fn drawColumn(app: *App, ui: Ui, area: Rect, s: side_mod.Section) Allocator.Error!void {
    switch (s) {
        .explorer => try app.tree.draw(app, ui, area),
        .todos => try todos.draw(app, ui, area),
        .notes => try notes.draw(app, ui, area),
        .findings => try findings.draw(app, ui, area),
        .git => try git_palette.draw(app, ui, area),
        .diagnostics => try lsp.drawPanel(app, ui, area),
        .http => try http_panel.draw(app, ui, area),
        .sessions => try sessions.draw(app, ui, area),
        .outline => try outline.drawPanel(app, ui, area),
        .debug => try debug_panel.draw(app, ui, area),
        .integrations => try integrations.drawSection(app, ui, area),
        // // changed (lua-track): the SCRIPTS section.
        .scripts => try scripts_panel.draw(app, ui, area),
        // // changed (search-section): Rust's SEARCH sidebar section.
        .search => try search_section.draw(app, ui, area),
        // // changed (lua-plumbing): a script's own rail section.
        .script => try script_section.draw(app, ui, area),
    }
}

/// The icon a pane's tab carries — the Rust editor's `icon_for_pane`:
/// a file's devicon, else one glyph per pane kind in its colour. A
/// Request pane has none (its method pill is the identity) and hands
/// back the method's colour for the pill.
pub fn paneIcon(app: *App, pane: *const app_mod.Pane, ascii: bool) icons.Icon {
    const p = app.theme.palette;
    // Each row names the `--ascii` twin first, then the glyph.
    return switch (pane.*) {
        .editor => |*e| icons.forName(std.fs.path.basename(e.buf.doc.path orelse "untitled"), false, false, ascii),
        .md_preview => |*m| icons.forName(std.fs.path.basename(m.path), false, false, ascii),
        .zon => |*z| icons.forName(std.fs.path.basename(z.path), false, false, ascii),
        .diff => kindIcon(ascii, "\u{B1}", "\u{F0E7E}", p.orange),
        .git_graph => kindIcon(ascii, "\u{2387}", "\u{F02A2}", p.orange),
        .git_status => kindIcon(ascii, "\u{B1}", "\u{F1D2}", p.green),
        .session_changes => kindIcon(ascii, "\u{B1}", "\u{F1D2}", p.yellow),
        .request => |*r| .{ .glyph = "", .color = request_pane.methodColor(&app.theme, r.methodName()) },
        .pty => |*pty_p| ptyIcon(app, pty_p, ascii),
        .ai, .ai_apply => kindIcon(ascii, "\u{2726}", "\u{F0E0A}", p.purple),
        .tests => kindIcon(ascii, "\u{2713}", "\u{F0668}", p.green),
        .browser => kindIcon(ascii, "\u{25C9}", "\u{F059F}", p.blue),
        .grep => kindIcon(ascii, "\u{2315}", "\u{F0349}", p.yellow),
        .flaky => kindIcon(ascii, "\u{224B}", "\u{F0668}", p.purple),
        .requests => kindIcon(ascii, "\u{2194}", "\u{F0AEE}", p.cyan),
        .outline => kindIcon(ascii, "\u{2325}", "\u{F01BD}", p.purple),
        .files => kindIcon(ascii, "\u{25A4}", "\u{F0770}", p.blue),
        .list => |*l| switch (l.kind) {
            .cmdline_history, .search_history => kindIcon(ascii, "\u{276F}", "\u{EB15}", p.comment),
            .stash_files, .git_log => kindIcon(ascii, "\u{2387}", "\u{F02A2}", p.orange),
            else => kindIcon(ascii, "\u{2315}", "\u{F0349}", p.teal),
        },
        .script => kindIcon(ascii, "\u{276F}", "\u{EB15}", p.comment),
        .cheatsheet => kindIcon(ascii, "?", "\u{F128}", p.yellow),
        .debug => kindIcon(ascii, "\u{1F41B}", "\u{F188}", p.red),
        .image => kindIcon(ascii, "\u{25A4}", "\u{F021F}", p.purple),
        .sessions_table => kindIcon(ascii, "\u{25C6}", "\u{F0392}", p.purple),
        .websocket => kindIcon(ascii, "\u{25C7}", "\u{F0317}", p.teal),
        .spend_report => kindIcon(ascii, "$", "\u{F01C2}", p.orange),
        .ai_usage => |*u| if (u.product == .claude) .{ .glyph = claude_mark.glyph(app, ascii), .color = p.orange } else kindIcon(ascii, bufferline.codex_ascii, bufferline.codex_glyph, p.cyan),
        .mount => kindIcon(ascii, "M", "\u{F0BD3}", p.cyan),
        .integrations => kindIcon(ascii, "\u{25C8}", "\u{F0431}", p.cyan),
    };
}

/// The tab mark of a mounted integration: its manifest chip's glyph (or
/// the chip's own fallback text where there is no Nerd Font) in the
/// chip's colour. Null when the pane was not opened from a manifest, or
/// the manifest declares no chip — the generic mount glyph then stands.
fn mountChipIcon(app: *App, ui: Ui, mp: *const mount_pane.MountPane) ?icons.Icon {
    const id = mp.integration orelse return null;
    const chip = integrations.chipOf(app, id) orelse return null;
    const color = integrations_view.paletteColor(&app.theme, chip.color);
    if (ui.ascii or chip.glyph.len + chip.glyph_codepoint.len == 0) {
        if (chip.fallback.len == 0) return null;
        return .{ .glyph = chip.fallback, .color = color };
    }
    if (chip.glyph.len > 0) return .{ .glyph = chip.glyph, .color = color };
    // A pinned codepoint decodes into the frame arena: the manifest
    // holds the hex, not the bytes, and the tab outlives a stack buffer.
    var buf: [4]u8 = undefined;
    const g = chip.glyphText(&buf);
    if (g.len == 0) return null;
    return .{ .glyph = ui.arena.dupe(u8, g) catch return null, .color = color };
}

/// One pane kind's glyph in its colour, or the `--ascii` twin.
fn kindIcon(ascii: bool, twin: []const u8, nerd: []const u8, color: vaxis.Color) icons.Icon {
    return .{ .glyph = if (ascii) twin else nerd, .color = color };
}

/// A pty tab's mark: the product's own for an AI session (in the
/// product's brand, which `tabsOf` then lets the pane's accent
/// override), and the terminal mark for everything else — white for a
/// shell, green for a command pty. Which mark that is comes from
/// `ui.terminal_glyph` (`terminal_glyph.mark`), so a shell and a
/// command wear the same one rather than the emulator's and the
/// codicon's.
fn ptyIcon(app: *App, pane: *const pty_pane.PtyPane, ascii: bool) icons.Icon {
    const p = app.theme.palette;
    if (pty_pane.productOf(app, pane)) |product| return switch (product) {
        .claude => .{ .glyph = claude_mark.glyph(app, ascii), .color = pty_pane.claude_brand },
        .codex => kindIcon(ascii, bufferline.codex_ascii, bufferline.codex_glyph, p.cyan),
    };
    const term = terminal_glyph.mark(app);
    const glyph = if (ascii) term.fallback else term.glyph;
    if (pane.argv.len > 0) return .{ .glyph = glyph, .color = p.green };
    return .{ .glyph = glyph, .color = bufferline.terminal_chip_fg };
}

/// `✗N` / `⚠N` (or `●` under `dot`) for an editor with diagnostics,
/// per `ui.bufferline_diag_style` — Rust's `diag_chip_for`.
const DiagChip = struct { text: []const u8, severity: bufferline.Severity };

fn diagChip(app: *App, ui: Ui, e: *EditorPane) DiagChip {
    const none: DiagChip = .{ .text = "", .severity = .none };
    if (app.cfg.ui.bufferline_diag_style == .off) return none;
    const path = e.buf.doc.path orelse return none;
    var err: usize = 0;
    var warn: usize = 0;
    for (lsp.diagnosticsFor(app, path)) |d| switch (d.severity) {
        .err => err += 1,
        .warning => warn += 1,
        else => {},
    };
    if (err == 0 and warn == 0) return none;
    const sev: bufferline.Severity = if (err > 0) .err else .warning;
    if (app.cfg.ui.bufferline_diag_style == .dot) return .{ .text = bufferline.dirty_dot, .severity = sev };
    return .{ .text = if (err > 0) ui.fmt("\u{2717}{d}", .{err}) else ui.fmt("\u{26A0}{d}", .{warn}), .severity = sev };
}

/// The tabs of leaf `lid` for the strip, as the painter wants them —
/// one builder for the paint, the drop router and the wheel, so none
/// can drift from the others. The strip lists documents, not windows:
/// a second window on a file already in the strip folds into the first
/// tab (which is active when either window is). A Request pane's title
/// splits into the method pill and the rest.
pub fn tabsOf(app: *App, ui: Ui, layout: *app_mod.Layout, lid: layout_mod.NodeId) Allocator.Error![]bufferline.Tab {
    const leaf = layout.leaf(lid) orelse return &.{};
    return tabsOfList(app, ui, leaf.tabs.items, leaf.active);
}

/// The strip chips for a list of panes with one of them active — the
/// leaf's own list, or the dock's hosted panes (`app/bottom.zig`).
/// // changed (bottom-dock): lifted out of `tabsOf`.
pub fn tabsOfList(app: *App, ui: Ui, ids: []const PaneId, active_id: PaneId) Allocator.Error![]bufferline.Tab {
    var tabs: std.ArrayListUnmanaged(bufferline.Tab) = .empty;
    for (ids) |id| {
        const p = app.panes.get(id) orelse continue;
        const active = active_id == id;
        var diag: bufferline.Severity = .none;
        var diag_text: []const u8 = "";
        if (p.asEditor()) |e| {
            var folded = false;
            for (tabs.items) |*tab| {
                const other = app.panes.editor(tab.id) orelse continue;
                if (other.buf.doc != e.buf.doc) continue;
                tab.active = tab.active or active;
                folded = true;
                break;
            }
            if (folded) continue;
            const d = diagChip(app, ui, e);
            diag = d.severity;
            diag_text = d.text;
        }
        // A pty whose child is blocked on the user wears the needs-you
        // mark — the one answer the SESSIONS card and the jumps read.
        const needs_you = p.* == .pty and sessions.needsYou(app, id);
        var icon = paneIcon(app, p, ui.ascii);
        // A mounted integration's tab wears its own manifest chip — the
        // glyph and the colour the rail and the palette bar already give
        // it — instead of one placeholder for every integration there is.
        if (p.* == .mount) if (mountChipIcon(app, ui, &p.mount)) |own| {
            icon = own;
        };
        // colors: a pty tab's glyph in the pane's accent (Rust's
        // `pty_icon` applies the session colour after the match).
        if (p.* == .pty) if (pty_pane.accentOf(app, &p.pty, ui.theme)) |accent| {
            icon.color = accent;
        };
        // colors: a repo-owned pane's glyph in its repo's accent.
        const repo_of: ?u32 = switch (p.*) {
            .git_status => |*s| s.repo,
            .diff => |*d| d.repo,
            .git_graph => |*g| g.repo,
            else => null,
        };
        if (repo_of) |rid| if (git_palette.repoAccent(app, rid)) |accent| {
            icon.color = accent;
        };
        var title = p.title();
        // A Claude / Codex tab goes by its session's name — the one its
        // SESSIONS card reads (`sessions.nameOf`), so three sessions in
        // a leaf are not three `claude` tabs. The component cuts it.
        if (p.* == .pty) if (sessions.paneName(app, id)) |n| {
            title = n.text;
        };
        var verb: ?[]const u8 = null;
        if (p.* == .request) if (std.mem.indexOfScalar(u8, title, ' ')) |sp| {
            verb = title[0..sp];
            title = std.mem.trimStart(u8, title[sp..], " ");
        };
        try tabs.append(ui.arena, .{
            .id = id,
            .title = title,
            .glyph = icon.glyph,
            .icon_color = icon.color,
            .verb = verb,
            .active = active,
            .dirty = p.dirty(),
            .pinned = p.pinned(),
            // VS Code's italic: a tab the user is only glancing at.
            .preview = p.preview(),
            .diag = diag_text,
            .diag_severity = diag,
            .needs_you = needs_you,
        });
    }
    return tabs.items;
}

/// The split cluster's ids — the same four on every strip; a click
/// focuses the leaf under it first (`dispatch`).
fn splitIds(app: *App, ui: Ui) Allocator.Error!bufferline.SplitIds {
    return .{
        .term = @intFromEnum(Button.split_term),
        .term_mark = terminal_glyph.mark(app),
        .right = @intFromEnum(Button.split_right),
        .down = @intFromEnum(Button.split_down),
        .max = @intFromEnum(Button.split_max),
        .ai = try aiChips(app, ui),
    };
}

/// The markdown mode chip for the leaf's active pane: `  Preview ` on
/// a markdown editor, ` ✏ Edit ` on a preview. A click is the command.
fn modeChip(app: *App, ui: Ui, active: PaneId) ?bufferline.ModeChip {
    const pane = app.panes.get(active) orelse return null;
    return switch (pane.*) {
        .md_preview => .{ .label = if (ui.ascii) " e Edit " else " \u{F044} Edit ", .button = md_preview.button_edit, .kind = .preview_md },
        .editor => |*e| if (e.buf.doc.path != null and md_preview.isMarkdownPath(e.buf.doc.path.?)) .{ .label = if (ui.ascii) " p Preview " else " \u{F06E} Preview ", .button = md_preview.button_preview, .kind = .edit_md } else if (e.buf.doc.path != null and zon_pane.isZonPath(e.buf.doc.path.?)) .{ .label = if (ui.ascii) " t View as tree " else " \u{F0E8} View as tree ", .button = zon_pane.button_view, .kind = .view_zon } else null,
        // The ZON tree's way back to the raw text.
        .zon => .{ .label = if (ui.ascii) " e Source " else " \u{F044} Source ", .button = zon_pane.button_source, .kind = .source_zon },
        else => null,
    };
}

/// The leaf's tab strip. The window (`Leaf.strip_first`) is re-fitted
/// to the active tab when that changed since the last paint, else it
/// stays where the wheel / chevrons left it; what was painted goes back
/// on the leaf so the wheel knows whether there is anything to scroll.
fn drawStrip(app: *App, ui: Ui, layout: *app_mod.Layout, lid: layout_mod.NodeId, li: usize, strip: Rect) Allocator.Error!void {
    const tabs = try tabsOf(app, ui, layout, lid);
    const leaf = layout.leaf(lid) orelse return;
    var opts: bufferline.Opts = .{
        .leaf = @intCast(li),
        .new_tab = Button.newTab(li),
        .first = leaf.strip_first,
        .scroll_left = Button.tabScroll(li, .left),
        .scroll_right = Button.tabScroll(li, .right),
        .split = try splitIds(app, ui),
        .mode_chip = modeChip(app, ui, leaf.active),
        .hidden_button = @intFromEnum(Button.hidden_tabs),
        // The maximize button reads restore while this leaf is zoomed —
        // or in full screen, where the zoom is moot and the button is
        // the way out (Rust `ui/mod.rs`).
        .zoomed = app.zen or (if (app.zoomedPane()) |z| layout.leafOf(z) == lid else false),
        .focused = paneFocused(app, leaf.active),
    };
    if (leaf.strip_anchor == null or leaf.strip_anchor.? != leaf.active) {
        opts.first = bufferline.fitActive(ui, strip, tabs, leaf.strip_first, opts);
        leaf.strip_anchor = leaf.active;
    }
    const win = bufferline.draw(ui, strip, tabs, opts);
    leaf.strip_first = win.first;
    leaf.strip_hidden_right = win.hidden_right;
}

// ── welcome ──

/// The welcome pane: the start surface, or its minimal form
/// (`app/welcome.zig`).
fn drawWelcome(app: *App, ui: Ui, area: Rect) void {
    welcome_app.draw(app, ui, area);
}

// ── end welcome ──

fn drawBody(app: *App, ui: Ui, body: Rect) Allocator.Error!void {
    const layout = app.layouts.current();
    if (layout.isEmpty()) {
        // An empty frame keeps the strip row so the `+` is where the
        // first tab will land.
        if (body.h >= 2) {
            // Rust's empty strip has no maximize button.
            var ids = try splitIds(app, ui);
            ids.max = null;
            _ = bufferline.draw(ui, body.row(0), &.{}, .{ .leaf = 0, .new_tab = Button.newTab(0), .split = ids });
        }
        drawWelcome(app, ui, if (body.h >= 2) body.splitTop(1).rest else Rect.empty);
        return;
    }
    var rects = try layout.computeRects(body, ui.arena);
    // `view.toggle_zoom`: the zoomed pane's leaf alone, over the whole
    // body, at its own strip ordinal (the strip's buttons name the leaf
    // by paint index); no dividers. The split tree underneath is what
    // the mouse and `Ctrl+W` still see (`zen.zig`).
    var leaf_index: usize = 0;
    if (app.zoomedPane()) |zid| if (layout.leafOf(zid)) |zlid| {
        for (rects.panes, 0..) |pr, i| if (pr.leaf == zlid) {
            const one = try ui.arena.alloc(layout_mod.PaneRect, 1);
            one[0] = .{ .pane = pr.pane, .rect = body, .leaf = zlid };
            rects = .{ .panes = one, .dividers = &.{} };
            leaf_index = i;
            break;
        };
    };
    for (rects.dividers, 0..) |d, i| {
        const dragging = if (app.drag) |dr| dr == .divider and dr.divider.split == d.split else false;
        const style = if (dragging or ui.hovered(d.rect)) app.theme.accent else app.theme.border;
        ui.canvas.fill(d.rect, style);
        // A horizontal split's divider stands (`│`); a vertical one lies
        // (`─`). Either may be more than one cell thick.
        if (d.dir == .horizontal) {
            var x: u16 = d.rect.x;
            while (x < d.rect.right()) : (x += 1) ui.vrule(x, d.rect.y, d.rect.h, style);
        } else {
            var y: u16 = d.rect.y;
            while (y < d.rect.bottom()) : (y += 1) ui.hrule(d.rect.x, y, d.rect.w, style);
        }
        try ui.hits.add(ui.arena, d.rect, .{ .divider = @intCast(i) });
    }
    if (app.ai.placeholder) for (rects.empties) |e| try drawAiPlaceholder(app, ui, e);
    for (rects.panes, leaf_index..) |pr, li| {
        if (app.panes.get(pr.pane) == null) continue;
        try ui.hits.add(ui.arena, pr.rect, .{ .pane = pr.pane });
        var rect = pr.rect;
        if (rect.h >= 2 and !app.zen) {
            const s = rect.splitTop(1);
            try drawStrip(app, ui, layout, pr.leaf, li, s.top);
            rect = s.rest;
        }
        try drawPaneContent(app, ui, pr.pane, rect);
        drawDropHint(app, ui, pr.pane, rect);
    }
}

/// Whether pane `id` has the keys — what the focus cue marks, and the
/// one answer every "is this pane focused" in the chrome reads.
///
/// It is asked the way `dispatch.keyInner` routes a key, not of the
/// id `app.focus` carries: a key that no overlay, visible tree or shown
/// section takes goes to `app.active`, whatever pane `.pane` names. The
/// two can disagree — an overlay closed back to the `.pane` it was
/// opened over after the active pane changed under it leaves `.pane`
/// naming the old one — and reading the id then put the cue on a pane
/// the keys were not going to and stepped back the one they were (an
/// integration pane with the keys and the VIEW chip, the editor lit).
pub fn paneFocused(app: *const App, id: PaneId) bool {
    if (app.active != id) return false;
    if (app.overlay != .none) return false;
    return switch (app.focus) {
        .pane, .overlay => true,
        .tree => !app.tree.visible,
        .panel => |p| !side_mod.isShown(app, side_mod.sectionOfPanel(p)),
        // The sidebar's info view holds the keys itself (`help.focus`).
        .welcome, .info_view => false,
    };
}

/// One pane's body in a rect — the kind switch, with nothing about
/// where the rect came from. // changed (bottom-dock): lifted out of
/// `drawBody` so the dock paints a hosted pane the same way a leaf
/// does; a docked pane is a leaf like any other, minus the split tree.
pub fn drawPaneContent(app: *App, ui: Ui, id: PaneId, full_rect: Rect) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    // // changed (pane-rail): one rule for every kind — the pane's
    // colour goes down its first column and its body starts one cell
    // in (`ui/pane_rail.zig`). The editor is the one kind that keeps
    // the whole rect: its gutter opens with a sign column that is
    // blank on most lines, so the rail goes into that cell after the
    // pane has painted (`pane_rail.drawOver`) and nothing on screen
    // moves. With line numbers off there is no gutter to share and
    // the editor insets like everything else.
    // The focus cue (`ui/focus_cue.zig`): a pane without the keys wears
    // its colour stepped back toward the ground under `rail` / `both`.
    const rail = if (pane_accent.railColorOf(app, id, ui.theme)) |c|
        focus_cue.rail(ui.theme, ui.focus_cue, paneFocused(app, id), c, ui.theme.bg.bg)
    else
        null;
    // A pane that paints its own stripe takes no rail; the cue goes on
    // its stripe instead, after it has painted (`pane_rail.recolor`).
    const own_stripe = if (rail == null) pane_accent.ownStripeColorOf(app, id, ui.theme) else null;
    defer if (own_stripe) |c| pane_rail.recolor(ui, full_rect, focus_cue.rail(ui.theme, ui.focus_cue, paneFocused(app, id), c, ui.theme.bg.bg));
    const shares_gutter = pane.* == .editor and app.cfg.ui.line_numbers;
    const inset = rail != null and !shares_gutter;
    const rect = pane_rail.body(full_rect, inset);
    if (rail) |c| if (inset) pane_rail.draw(ui, full_rect, c);
    defer if (rail) |c| if (shares_gutter) pane_rail.drawOver(ui, full_rect, c);
    // A pane that painted its own `▌` in its first column gets one
    // bar there, not two (`pane_rail.absorb`).
    // One bar per row: a pane's own stripe beside the rail goes into it
    // (`pane_rail.absorb`); a list pane's sits past the list's marker
    // column (`absorbList`).
    defer if (rail != null and inset) switch (pane.*) {
        .sessions_table => pane_rail.absorbList(ui, full_rect),
        else => pane_rail.absorb(ui, full_rect),
    };
    switch (pane.*) {
        .editor => |*e| try drawEditor(app, ui, id, e, rect),
        .outline => |*o| {
            if (app.active == id) app.pane_rows = @max(rect.h, 1);
            try outline.draw(app, ui, id, o, rect, app.active == id);
        },
        .md_preview => |*m| try md_preview.draw(app, ui, id, m, rect),
        .zon => |*z| try drawZon(app, ui, id, z, rect),
        .cheatsheet => |*c| try cheatsheet.draw(app, c, ui, id, rect),
        .list => |*l| drawListPane(app, l, ui, id, rect),
        .pty => |*p| try drawPty(app, ui, id, p, rect),
        .git_status => |*s| try git_app.drawStatusPane(app, ui, id, s, rect),
        .session_changes => |*v| try session_changes.draw(app, ui, id, v, rect),
        .diff => |*d| git_app.drawDiffPane(app, ui, id, d, rect),
        .git_graph => |*g| git_app.drawGraphPane(app, ui, id, g, rect),
        .ai => |*a| drawAi(app, ui, id, a, rect),
        .sessions_table => |*tp| try sessions_table.drawPane(app, ui, id, tp, rect),
        .spend_report => |*s| {
            if (app.active == id) app.pane_rows = @max(rect.h, 1);
            spend_view.draw(ui, id, rect, s, paneFocused(app, id));
        },
        .ai_usage => |*u| {
            if (app.active == id) app.pane_rows = @max(rect.h, 1);
            try usage_pane.draw(app, ui, id, u, rect);
        },
        .grep => |*g| {
            if (app.active == id) app.pane_rows = @max(rect.h, 1);
            grep_view.draw(ui, id, rect, g, paneFocused(app, id));
        },
        .debug => |*d| try dap.drawDebug(app, ui, id, d, rect),
        .request => |*rp| try request_pane.draw(app, ui, id, rp, rect),
        .websocket => |*w| try ws_pane.draw(app, ui, id, w, rect),
        .browser => |*b| try browser_pane.draw(app, ui, id, b, rect),
        .script => |*s| try script_pane.draw(app, ui, id, s, rect),
        .mount => |*mp| try mount_pane.draw(app, ui, id, mp, rect),
        .integrations => |*ip| try integrations.draw(app, ui, id, ip, rect),
        .ai_apply => |*ap| drawAiApply(app, ui, id, ap, rect),
        .tests => |*tp| try drawTests(app, ui, id, tp, rect),
        .flaky => |*fp| {
            if (app.active == id) app.pane_rows = @max(rect.h, 1);
            flaky_view.draw(ui, id, rect, fp, paneFocused(app, id));
        },
        .requests => |*rp| {
            if (app.active == id) app.pane_rows = @max(rect.h, 1);
            requests_view.draw(ui, id, rect, rp, paneFocused(app, id));
        },
        .files => |*f| try files_pane.draw(app, ui, id, f, rect),
        .image => |*im| try image_pane.draw(app, ui, id, im, rect),
    }
}

/// While a tab or a tree file is being dragged over a pane, the zone
/// it would land in is tinted.
/// The AI grid's open slot: the pane ground with a `+ Add Claude Code`
/// chip in the middle (`+ Claude` when the slot is narrow), the whole
/// slot a press target for the next session.
fn drawAiPlaceholder(app: *App, ui: Ui, e: layout_mod.EmptyRect) Allocator.Error!void {
    const r = e.rect;
    ui.canvas.fill(r, app.theme.bg);
    try ui.hits.add(ui.arena, r, .{ .ai_placeholder = e.node });
    if (r.w < 8 or r.h < 3) return;
    const plus: []const u8 = if (ui.ascii or !ui.nerd_font) "+" else bufferline.plus_glyph;
    const full = " Add Claude Code";
    const short = " Claude";
    const label: []const u8 = if (r.w >= 1 + full.len + 4) full else short;
    const chip_w: u16 = @intCast(1 + label.len + 2);
    if (r.w < chip_w) return;
    const chip = Rect.init(r.x + (r.w - chip_w) / 2, r.y + r.h / 2, chip_w, 1);
    const ground = app.theme.chip;
    ui.canvas.fill(chip, ground);
    var plus_style = Theme.withFg(ground, app.theme.palette.green);
    plus_style.bold = true;
    _ = ui.putStr(chip.x + 1, chip.y, 1, plus, plus_style);
    _ = ui.putStr(chip.x + 2, chip.y, chip_w - 3, label, ground);
}

fn drawDropHint(app: *App, ui: Ui, pane: PaneId, body: Rect) void {
    const d = app.drag orelse return;
    switch (d) {
        .tab => |tb| if (!tb.moved) return,
        .tree => {},
        else => return,
    }
    const h = app.hover orelse return;
    if (!body.contains(h.x, h.y)) return;
    const zone = layout_mod.zoneFor(body, h.x, h.y);
    const zr = layout_mod.zoneRect(body, zone);
    var y: u16 = zr.y;
    while (y < zr.bottom()) : (y += 1) {
        var x: u16 = zr.x;
        while (x < zr.right()) : (x += 1) {
            var cell = ui.canvas.screen.readCell(x, y) orelse continue;
            cell.style.bg = app.theme.selection.bg;
            ui.canvas.put(x, y, cell);
        }
    }
    _ = pane;
}

/// A pty pane: the layout's rect is what the child sees (resize is a
/// no-op when unchanged), then the grid is refreshed and painted.
fn drawPty(app: *App, ui: Ui, id: PaneId, p: *pty_pane.PtyPane, rect: Rect) Allocator.Error!void {
    if (!pty_pane.supported) return;
    const focused = paneFocused(app, id);
    // A dormant pane never ran, so it has no exit to report and a key
    // starts it rather than closing it.
    const exit_label: ?[]const u8 = if (p.dormant)
        ui.fmt("[exited] — any key restarts {s}", .{p.label})
    else if (p.resume_missing)
        // The resume found no conversation (the CLI said so just
        // above): Enter starts a new one in place rather than closing
        // the tab (`pty_pane.startFresh`).
        ui.fmt("[exited {d}] Enter starts a new session", .{switch (p.exit.?) {
            .code => |c| c,
            .signal => |sg| sg,
        }})
    else if (p.exit) |e| switch (e) {
        .code => |c| ui.fmt("[exited {d}] — Enter closes", .{c}),
        .signal => |sg| ui.fmt("[killed by signal {d}] — Enter closes", .{sg}),
    } else null;
    // // changed (pane-rail): the rail is painted by `drawPaneContent`
    // for every kind, and the rect that lands here has already had its
    // column taken off. What the child sees is exactly this rect.
    const body = rect;
    p.fit(body.w, body.h);
    p.body = .{ .x = body.x, .y = body.y, .w = body.w, .h = body.h };
    if (p.session) |session| try p.grid.update(app.gpa, session.terminal());
    const cursor = pty_view.draw(ui, body, &p.grid, .{
        .focused = focused,
        .exit_label = exit_label,
        // A real terminal draws the focused pane's cursor itself, from
        // the DECSCUSR below — so the cells carry only the stand-in for
        // the OTHER pty panes. Headless has no such cursor and paints
        // the focused one too.
        .paint_focused = !app.term_cursor,
        .unfocused = switch (app.cfg.ui.pty_cursor.unfocused) {
            .hollow => .hollow,
            .dim => .dim,
            .none => .none,
        },
        .blink = app.cfg.ui.pty_cursor.blink,
        .mnml_font = app.fonts.baked(pty_view.cursor_hollow_cp),
        // The scrollback search's matches in view (`pty_search.zig`).
        .marks = try pty_search.marks(app, id, p),
    });
    // Its bar lies over the last row: the child keeps its size.
    pty_search.drawBar(app, ui, id, p, body);
    if (app.active == id) {
        app.pane_rows = @max(body.h, 1);
        app.pane_cols = @max(body.w, 1);
    }
    // The host's own cursor goes on the focused pty pane's cell: Ghostty
    // then blinks it and hollows it out when the mnml window itself
    // loses focus, exactly as it does for a bare shell.
    if (focused) if (cursor) |c| {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
        app.cursor_shape = switch (c.shape) {
            .block => .block,
            .bar => .bar,
            .underline => .underline,
        };
        app.cursor_blink = c.blink;
        // The child's own DECSCUSR: `ui.cursor_shape` must not rewrite
        // it, or vim inside a terminal pane would lie about its mode.
        app.cursor_from_child = true;
    };
}

/// The AI answer pane; the scroll is clamped to what overflowed.
/// The ZON view: rows rebuilt when stale, the caret handed to the
/// terminal while a field or the filter has it.
fn drawZon(app: *App, ui: Ui, id: PaneId, z: *zon_pane.ZonPane, rect: Rect) Allocator.Error!void {
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    if (z.stale) try z.rebuildRows();
    const focused = paneFocused(app, id);
    const caret = zon_view.draw(ui, id, rect, z, focused);
    if (focused) if (caret) |c| {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

fn drawAi(app: *App, ui: Ui, id: PaneId, a: *ai_app.AiPane, rect: Rect) void {
    const focused = paneFocused(app, id);
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    const over = ai_view.draw(ui, id, rect, .{
        .title = a.title,
        .status = a.statusLabel(),
        .prompt = a.prompt,
        .answer = a.answer.items,
        .err = a.err,
        .scroll = a.scroll,
        .focused = focused,
        .running = a.status == .running,
    });
    if (a.scroll > over) a.scroll = over;
}

/// The `ai.apply` review: hunks with their accept / skip badges.
fn drawAiApply(app: *App, ui: Ui, id: PaneId, p: *ai_apply.AiApplyPane, rect: Rect) void {
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    const Text = struct {
        var pane: *ai_apply.AiApplyPane = undefined;
        fn line(row: ai_apply.Row) []const u8 {
            return ai_apply.lineText(pane, row);
        }
    };
    Text.pane = p;
    ai_apply_view.draw(ui, id, rect, &p.scroll, .{
        .file = p.file,
        .hunks = p.hunks,
        .rows = p.rows,
        .cursor = p.cursor,
        .focused = paneFocused(app, id),
        .cursor_row = p.cursorRow(),
        .lineText = &Text.line,
    });
}

/// The Playwright results: the history's wobbly marks come from the app.
fn drawTests(app: *App, ui: Ui, id: PaneId, p: *tests_pane.TestsPane, rect: Rect) Allocator.Error!void {
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    const wobbly = try ui.arena.alloc(bool, p.run.tests.len);
    for (p.run.tests, 0..) |tc, i| wobbly[i] = flaky.isWobbly(app, tc.file, tc.suite_path, tc.title);
    tests_view.draw(ui, id, rect, .{
        .p = p,
        .focused = paneFocused(app, id),
        .wobbly = wobbly,
        .command = try tests_pane.cmdlineFor(ui.arena, p.runner, p.last_args),
    });
}

/// The ghost text: the suggestion's first line at the cursor, the
/// rest of the current line pushed right behind it, further lines on
/// the rows below. Dim, so it reads as a proposal.
fn drawGhost(ui: Ui, rect: Rect, cursor: editor_view.Cursor, ed: *const @import("../editor/editor.zig").Editor, ghost: []const u8, gutter: u16) void {
    const th = ui.theme;
    var style = Theme.onBg(th.muted, th.bg.bg);
    style.italic = true;
    var lines = std.mem.splitScalar(u8, ghost, '\n');
    var y = cursor.y;
    var first = true;
    while (lines.next()) |line| : (y += 1) {
        if (y >= rect.bottom()) break;
        const x: u16 = if (first) cursor.x else rect.x + gutter;
        if (x >= rect.right()) continue;
        var used = ui.putStr(x, y, rect.right() - x, line, style);
        if (first) {
            first = false;
            const cur_line = ed.currentLine();
            const rest = ed.bytes()[ed.cursor..ed.lineEnd(cur_line)];
            if (rest.len > 0 and x + used < rect.right()) used += ui.putStr(x + used, y, rect.right() - (x + used), rest, Theme.onBg(th.fg, th.bg.bg));
        }
    }
}

/// While flash is armed, the pane's last row says what to press —
/// `ab → press a label to jump · Esc cancels`, right-aligned, in the
/// label style; nothing on screen would otherwise say the next key
/// is spoken for.
fn drawFlashCue(ui: Ui, rect: Rect, f: *const flash.State) void {
    if (rect.isEmpty()) return;
    var pair: [8]u8 = undefined;
    const hint = overlay_mod.hintText(ui, ui.fmt(" {s} → press a label to jump · Esc cancels ", .{flash.pairText(f.a, f.b, &pair)}));
    _ = ui.putStrRight(rect.right(), rect.bottom() - 1, rect.w, hint, ui.theme.current_match);
}

/// Two sorted virtual-text lists as one, by byte (the debugger's inline
/// values after the language server's hints at the same byte).
fn mergeVirtual(arena: Allocator, a: []const editor_view.VirtualText, b: []const editor_view.VirtualText) Allocator.Error![]const editor_view.VirtualText {
    if (b.len == 0) return a;
    if (a.len == 0) return b;
    const out = try arena.alloc(editor_view.VirtualText, a.len + b.len);
    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;
    while (i < a.len or j < b.len) : (k += 1) {
        if (j >= b.len or (i < a.len and a[i].byte <= b[j].byte)) {
            out[k] = a[i];
            i += 1;
        } else {
            out[k] = b[j];
            j += 1;
        }
    }
    return out;
}

/// The gutter's marks in priority order — the view paints the first
/// sign and the first change mark it finds for a line (one column
/// each; in a one-cell gutter the sign wins). The ladder itself is
/// `editor_view.mark_priority`: the debugger's signs (a breakpoint,
/// the ▶ of a stop), a diagnostic's dot, a script's `mnml.decor.gutter`
/// at whatever it asked for (50 by default), git's change bars last.
/// A stable sort keeps each producer's own order within its rung.
pub fn gutterMarksFor(app: *App, arena: Allocator, pane: PaneId, e: *EditorPane, ascii: bool) Allocator.Error![]const editor_view.GutterMark {
    const d = try dap.marksForPane(app, arena, pane, e, &app.theme, ascii);
    const l = try lsp.marksFor(app, arena, e.buf.doc.path, &app.theme, ascii);
    const s = try script_decor.gutterMarksFor(app, arena, pane, e, &app.theme);
    const g: []const editor_view.GutterMark = try git_app.viewMarks(app, e, arena);
    if (l.len == 0 and g.len == 0 and s.len == 0) return d;
    if (d.len == 0 and g.len == 0 and s.len == 0) return l;
    if (d.len == 0 and l.len == 0 and s.len == 0) return g;
    const all = try std.mem.concat(arena, editor_view.GutterMark, &.{ d, l, s, g });
    std.mem.sort(editor_view.GutterMark, all, {}, struct {
        fn gt(_: void, a: editor_view.GutterMark, b: editor_view.GutterMark) bool {
            return a.priority > b.priority;
        }
    }.gt);
    return all;
}

/// The gutter's hover chevron asks this of every line the pointer
/// visits: `editor.toggle_fold`'s own rule (`cmd_editor.foldStartsAt`),
/// reached through the `Doc` so the view keeps knowing nothing about
/// brackets.
fn foldStartsAt(ctx: *const anyopaque, line: u32) bool {
    const e: *const EditorPane = @ptrCast(@alignCast(ctx));
    const folds = @import("cmd_editor.zig");
    return folds.foldStartsAt(e.buf.editor, folds.foldRulesFor(e), line);
}

/// `ui.highlight_word_under_cursor`: every whole-word occurrence of the
/// word at the cursor within `[from, to)`, sorted — the view underlines
/// them. No word under the cursor = nothing.
fn wordMatches(arena: Allocator, ed: *const @import("../editor/editor.zig").Editor, from: usize, to: usize) Allocator.Error![]const editor_view.Range {
    const text = ed.bytes();
    const w = @import("find.zig").wordAt(text, ed.cursor) orelse return &.{};
    const word = text[w.start..w.end];
    var out: std.ArrayListUnmanaged(editor_view.Range) = .empty;
    var i = from;
    const end = @min(to, text.len);
    while (i + word.len <= end) {
        const at = std.mem.indexOfPos(u8, text[0..end], i, word) orelse break;
        const before_ok = at == 0 or !@import("find.zig").isWord(text[at - 1]);
        const after_ok = at + word.len >= text.len or !@import("find.zig").isWord(text[at + word.len]);
        if (before_ok and after_ok) try out.append(arena, .{ .start = at, .end = at + word.len });
        i = at + 1;
    }
    return out.items;
}

/// The breadcrumb's segments: the workspace-relative path's components
/// (a file outside the workspace shows its whole path).
pub fn breadcrumbNames(app: *App, arena: Allocator, path: []const u8) Allocator.Error![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, app.relPath(path), '/');
    while (it.next()) |part| if (part.len > 0) try names.append(arena, part);
    return names.items;
}

/// The directory a breadcrumb segment opens: a directory segment
/// itself, the file's segment its parent.
pub fn breadcrumbDir(app: *App, arena: Allocator, path: []const u8, idx: usize) Allocator.Error!?[]const u8 {
    const names = try breadcrumbNames(app, arena, path);
    if (names.len == 0) return null;
    const rel = app.relPath(path);
    const root: []const u8 = if (rel.ptr == path.ptr) "/" else app.workspace;
    const take = @min(idx + 1, names.len - 1);
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    try parts.append(arena, root);
    try parts.appendSlice(arena, names[0..take]);
    return try std.fs.path.join(arena, parts.items);
}

/// The line ranges (inclusive) a frame needs spans for: a screen either
/// side of the viewport, and a screen either side of the cursor. One
/// range when they meet, two when they do not — never the lines between.
pub const SpanLineRanges = struct {
    items: [2][2]usize = undefined,
    len: usize = 0,

    pub fn slice(r: *const SpanLineRanges) []const [2]usize {
        return r.items[0..r.len];
    }
};

/// Bytes of text the editor frames asked the highlighter for since the
/// process started — what a test reads to show a long line's frame asks
/// for a window of it.
pub var span_bytes_requested: usize = 0;

/// Styled spans for bytes `[lo, hi)` with the server's tokens over them,
/// appended to `acc` (pieces come in ascending, disjoint order).
fn spanPiece(app: *App, arena: Allocator, e: *EditorPane, ed: anytype, acc: []const editor_view.Span, lo: usize, hi: usize, lo_line: usize, hi_line: usize) Allocator.Error![]const editor_view.Span {
    span_bytes_requested += hi - lo;
    const base_spans = try e.syntax.styledSpans(ed, arena, &app.theme, lo, hi);
    const with_server = try semantic_app.layer(app, arena, e, &app.theme, base_spans, lo_line, hi_line);
    return if (acc.len == 0) with_server else try std.mem.concat(arena, editor_view.Span, &.{ acc, with_server });
}

/// The bytes of long line `line` that can be on screen this frame: the
/// columns around where the view will scroll to (it follows the cursor
/// on the cursor's line, and every row shares the one scroll column),
/// with a screen's width of slack on each side.
fn longLineSpanWindow(app: *App, e: *EditorPane, ed: anytype, line: usize, width: u16) [2]usize {
    const text = ed.bytes()[ed.lineStart(line)..ed.lineEnd(line)];
    const tw: u8 = @intCast(@min(app.cfg.editor.tab_width, 255));
    const method = app.screen.width_method;
    const w: u32 = @max(width, 1);
    // `keepCursorVisible`'s horizontal rule, on the cursor's column.
    var sc: u32 = e.view.scroll_col;
    const cur_line = ed.currentLine();
    const cl = ed.bytes()[ed.lineStart(cur_line)..ed.lineEnd(cur_line)];
    const cx = editor_view.colOfOffM(cl, tw, @intCast(ed.cursor - ed.lineStart(cur_line)), method);
    if (cx < sc) sc = cx else if (cx >= sc + w) sc = cx - w + 1;
    const from = editor_view.byteAtColM(text, tw, sc -| w, method);
    const to = editor_view.byteAtColM(text, tw, sc +| 2 * w, method);
    return .{ from, @min(to + 64, text.len) };
}

pub fn spanLineRanges(scroll_line: usize, cur_line: usize, rows: usize, line_count: usize) SpanLineRanges {
    const last = line_count -| 1;
    const view: [2]usize = .{ @min(scroll_line -| rows, last), @min(scroll_line + 2 * rows, last) };
    const cur: [2]usize = .{ @min(cur_line -| rows, last), @min(cur_line + rows, last) };
    var out: SpanLineRanges = .{};
    if (cur[0] <= view[1] + 1 and view[0] <= cur[1] + 1) {
        out.items[0] = .{ @min(view[0], cur[0]), @max(view[1], cur[1]) };
        out.len = 1;
    } else {
        out.items[0] = if (view[0] < cur[0]) view else cur;
        out.items[1] = if (view[0] < cur[0]) cur else view;
        out.len = 2;
    }
    return out;
}

test "spanLineRanges: one range while the cursor is near the viewport, two when it is far — never the lines between" {
    // Cursor inside the viewport: the old hull, unchanged.
    const near = spanLineRanges(100, 110, 40, 2_000_000);
    try std.testing.expectEqual(@as(usize, 1), near.len);
    try std.testing.expectEqual([2]usize{ 60, 180 }, near.items[0]);
    // `G` from the top of a two-million-line file: two screens' worth.
    const far = spanLineRanges(0, 1_999_999, 40, 2_000_000);
    try std.testing.expectEqual(@as(usize, 2), far.len);
    try std.testing.expectEqual([2]usize{ 0, 80 }, far.items[0]);
    try std.testing.expectEqual([2]usize{ 1_999_959, 1_999_999 }, far.items[1]);
    var lines: usize = 0;
    for (far.slice()) |r| lines += r[1] - r[0] + 1;
    try std.testing.expect(lines <= 4 * 40);
    // `gg` from the end: the same, the other way round, still ascending.
    const back = spanLineRanges(1_999_960, 0, 40, 2_000_000);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expect(back.items[0][1] < back.items[1][0]);
    // Touching ranges merge; a short file is one range.
    try std.testing.expectEqual(@as(usize, 1), spanLineRanges(0, 121, 40, 2_000_000).len);
    try std.testing.expectEqual(@as(usize, 2), spanLineRanges(0, 122, 40, 2_000_000).len);
    const short = spanLineRanges(0, 9, 40, 10);
    try std.testing.expectEqual(@as(usize, 1), short.len);
    try std.testing.expectEqual([2]usize{ 0, 9 }, short.items[0]);
}

test "a frame over a large document walks none of its text: no line index rebuilt, no marker looked for, whatever the keys" {
    const gpa = std.testing.allocator;
    const conflict_cache = @import("conflict_cache.zig");
    var app = try App.initWith(gpa, std.testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    try @import("../core/command.zig").run(&app, .{ .static = .@"editor.use_vim" });
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    var i: usize = 0;
    while (text.items.len < 4 << 20) : (i += 1) {
        const line = try std.fmt.allocPrint(gpa, "line {d}: a << b && c < d, plain text with no marker\n", .{i});
        defer gpa.free(line);
        try text.appendSlice(gpa, line);
    }
    try e.buf.editor.setText(text.items);
    e.buf.editor.setCursor(0);
    app.now_ms = 1000;
    // The first frame may look the text over once (is there a marker?).
    try app.render();
    const lines_before = editor_view.line_index_bytes_scanned;
    const marker_before = conflict_cache.bytes_scanned;
    const steps = [_][]const u8{ "G", "g", "g", "ctrl+f", "ctrl+f", "i", "Z", "Q", "esc", "G", "o", "J", "esc", "u", "g", "g" };
    for (steps) |spec| {
        try app.handle(.{ .key = keymap.parseKeySpec(spec).? });
        app.now_ms += 5;
        try app.tick(app.now_ms);
        try app.render();
    }
    // The keys did what they say: `ZQ` typed two pages down and kept, the
    // `o J` line opened at the end and undone.
    try std.testing.expectEqual(text.items.len + 2, e.buf.editor.len());
    try std.testing.expect(std.mem.indexOf(u8, e.buf.editor.bytes()[0 .. 64 * 1024], "ZQ") != null);
    try std.testing.expectEqual(@as(usize, 0), e.buf.editor.currentLine());
    // Sixteen frames and four edits over four megabytes: no index walked,
    // and only the edited lines looked at for a marker.
    try std.testing.expectEqual(lines_before, editor_view.line_index_bytes_scanned);
    try std.testing.expect(conflict_cache.bytes_scanned - marker_before < 4096);
}

test "a frame over a long unwrapped line asks the highlighter for the columns on screen, not the line" {
    const gpa = std.testing.allocator;
    var app = try App.initWith(gpa, std.testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 20 });
    defer app.deinit();
    try @import("../core/command.zig").run(&app, .{ .static = .@"editor.use_vim" });
    app.tree.visible = false;
    app.cfg.ui.wrap = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "short line above\n");
    while (text.items.len < 300_000) try text.appendSlice(gpa, "var a=[0,1,2],b={c:3};");
    try text.appendSlice(gpa, "\nshort line below\n");
    try e.buf.editor.setText(text.items);
    app.now_ms = 1000;
    for ([_][]const u8{ "j", "$", "0", "w" }) |spec| {
        try app.handle(.{ .key = keymap.parseKeySpec(spec).? });
        app.now_ms += 5;
        try app.tick(app.now_ms);
        const before = span_bytes_requested;
        try app.render();
        try std.testing.expect(span_bytes_requested - before < 4096);
    }
    try std.testing.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
}

fn drawEditor(app: *App, ui: Ui, id: PaneId, e: *EditorPane, rect_in: Rect) Allocator.Error!void {
    const arena = ui.arena;
    var rect = rect_in;
    // ── breadcrumb ──
    // The row under the strip: the file's path, one segment a target.
    if (app.cfg.editor.breadcrumb and rect.h >= 3) if (e.buf.doc.path) |path| {
        const names = try breadcrumbNames(app, arena, path);
        if (names.len > 0) {
            const s = rect.splitTop(editor_view.breadcrumb_h);
            editor_view.drawBreadcrumb(ui, id, s.top, names);
            rect = s.rest;
        }
    };
    // The debugger's step toolbar, docked over the editor while a
    // session is live (`ui.debug_toolbar`).
    if (rect.h >= 3) if (dap.stripPane(app)) |sp| if (sp == id) {
        const s = rect.splitTop(1);
        _ = debug_toolbar.draw(ui, s.top, .{ .pane = id, .state = dap.sessionState(app) });
        rect = s.rest;
    };
    // The find bar docks under the pane it belongs to.
    var bar: ?Rect = null;
    if (app.find_bar) |*fb| if (fb.pane == id and rect.h >= 2) {
        const rows: u16 = if (fb.state.show_replace) 2 else 1;
        const s = rect.splitBottom(rows);
        rect = s.top;
        bar = s.rest;
    };
    const focused = paneFocused(app, id);
    const ed = e.buf.editor;
    // Another window's edit above this one's viewport moved the lines
    // under it: the scroll follows so the same text stays in view.
    for (try ed.takeLineShifts(app.frame.allocator())) |sh| {
        if (e.view.scroll_line > sh.row) {
            const moved = @as(isize, @intCast(e.view.scroll_line)) + sh.delta;
            e.view.scroll_line = @intCast(@max(moved, @as(isize, @intCast(sh.row))));
        }
    }
    // The language server hears every edit before the frame paints.
    lsp.syncPane(app, id, e);
    // Highlighting: every frame folds the edits since the last one into
    // the tree and slides the cached spans along, so what is painted
    // lines up with the text; the reparse itself waits for the idle
    // gate (`Syntax.parseDue`) — a small file's first parse runs at
    // once, a large file's first frame paints unhighlighted rather than
    // wait on it. A structural query that already parsed the current
    // text (the outline, a text object) leaves nothing to do.
    // A document past `Syntax.worker_min_bytes` is not parsed here at
    // all: the gate hands it to a worker and the frame paints with the
    // tree it has (`syntax_jobs.zig`).
    if (e.syntax.dirty and e.syntax.since_ms == null) e.syntax.since_ms = app.now_ms;
    _ = e.syntax.absorb(ed);
    if (e.syntax.dirty and (e.syntax.isCurrent() or e.syntax.parseDue(app.now_ms, ed.len()))) {
        var settled = true;
        if (!e.syntax.isCurrent()) {
            if (!syntax.Syntax.onWorker(ed.len())) {
                try e.syntax.refresh(ed);
            } else if (e.syntax.pending != null) {
                // One job at a time; its result restarts the gate.
                settled = false;
            } else if (!e.syntax.hasLanguage()) {
                // Nothing to parse.
            } else if (!syntax_jobs.start(app, e.syntax, ed.doc)) {
                try e.syntax.refresh(ed);
            }
        }
        if (settled) {
            e.syntax.dirty = false;
            e.syntax.since_ms = null;
        }
    }
    // The decorations are an edit-log consumer too: a record dropped
    // before `script_decor` moved its anchors across it would leave
    // them sitting still while the text moved (`script_decor.minSeen`).
    try script_decor.syncPane(app, id);
    // So are the document's conflict regions: a marker can only appear
    // where the log says the text changed.
    try conflicts.sync(app, e);
    // And so are the AI panes' apply targets and the open reviews: the
    // range a proposal replaces moves with the edits made behind it.
    ai_apply.followAll(app, e.buf.doc);
    // The breakpoints are anchored to the text as well: an edit above
    // one moves it with its line.
    dap.followBreakpoints(app, e.buf.doc);
    // And the diagnostics: their marks stay on their text until the
    // server publishes again.
    lsp.followDiagnostics(app, e.buf.doc);
    // A ghost whose cursor moved (a click, a jump) is not painted there.
    try ai_app.dropMovedGhost(app, e);
    ed.doc.edits.trim(@min(e.syntax.trimFloor(), script_decor.minSeen(app, e.buf.doc) orelse std.math.maxInt(u64)));
    // Spans around the viewport and around the cursor — the view may
    // scroll to the cursor inside `draw`, so both are covered. Two
    // ranges when they are apart (`G` from the top of a long file), not
    // the stretch between them: that stretch is the file.
    const line_count = ed.lineCount();
    const rows: usize = @max(rect.h, 1);
    const ranges = spanLineRanges(e.view.scroll_line, ed.currentLine(), rows, line_count);
    // The server's decorations for the visible lines (idle-debounced),
    // and its semantic tokens laid over the grammar's spans.
    const first_vis: u32 = @intCast(@min(e.view.scroll_line, line_count - 1));
    const last_vis: u32 = @intCast(@min(e.view.scroll_line + rows, line_count) -| 1);
    try decor.onFrame(app, id, e, first_vis, last_vis);
    var layered: []const editor_view.Span = &.{};
    // A long line that does not wrap shows a column window of itself
    // (`editor_view.layoutWindow`), so it gets spans for that window, not
    // for its megabyte: a minified bundle's spans were built, styled and
    // sorted whole every frame.
    const wraps = e.wrap orelse app.cfg.ui.wrap;
    const md = app.cfg.ui.render_markdown and e.buf.doc.path != null and md_preview.isMarkdownPath(e.buf.doc.path.?);
    for (ranges.slice()) |r| {
        // The stretch of ordinary lines not yet taken: bytes from `lo`,
        // lines from `lo_line`.
        var lo = ed.lineStart(r[0]);
        var lo_line = r[0];
        var line = r[0];
        while (line <= r[1]) : (line += 1) {
            const ls = ed.lineStart(line);
            const le = ed.lineEnd(line);
            if (wraps or md or le - ls <= editor_view.window_min_bytes) continue;
            if (line > lo_line) layered = try spanPiece(app, arena, e, ed, layered, lo, ls, lo_line, line - 1);
            const w = longLineSpanWindow(app, e, ed, line, rect.w);
            layered = try spanPiece(app, arena, e, ed, layered, ls + w[0], ls + w[1], line, line);
            lo = le;
            lo_line = line + 1;
        }
        if (lo_line <= r[1]) layered = try spanPiece(app, arena, e, ed, layered, lo, ed.lineEnd(r[1]), lo_line, r[1]);
    }
    const tinted = try conflicts.tintSpans(app, arena, e, layered, &app.theme);
    // A script's `mnml.decor.highlight` goes over everything the
    // grammar, the server and a conflict marker put down.
    const spans = try @import("highlight").engine.layerSpans(editor_view.Span, arena, tinted, try script_decor.highlightsFor(app, arena, id, e, &app.theme));
    const folds = try arena.alloc(editor_view.Fold, e.buf.editor.folds.count());
    for (e.buf.editor.folds.keys(), e.buf.editor.folds.values(), 0..) |s, en, i| folds[i] = .{ .first_line = @intCast(s), .last_line = @intCast(en) };
    const matches = try arena.alloc(editor_view.Range, e.find.matches.items.len);
    for (e.find.matches.items, 0..) |m, i| matches[i] = .{ .start = m.start, .end = m.end };
    const mode = e.buf.input.mode();
    // Flash labels: one per armed match, in byte order (the state
    // keeps them sorted); a stale state is dropped here.
    var labels: []editor_view.Label = &.{};
    const armed: ?*flash.State = if (app.active == id) flash.current(app) else null;
    if (armed) |f| {
        labels = try arena.alloc(editor_view.Label, f.matches.len);
        for (f.matches, 0..) |m, i| labels[i] = .{ .byte = m.byte, .text = m.text() };
    }
    const doc: editor_view.Doc = .{
        .text = e.buf.editor.bytes(),
        .line_starts = e.buf.doc.line_starts.items,
        .cursor = e.buf.editor.cursor,
        .anchor = e.buf.editor.anchor,
        .extra_cursors = e.buf.editor.extra_cursors.items,
        .folds = folds,
        .foldable = .{ .ctx = e, .startsFold = &foldStartsAt },
        .always_show_fold_arrows = app.cfg.ui.always_show_fold_arrows,
        .spans = spans,
        .matches = matches,
        .current_match = e.find.current,
        .wrap = e.wrap orelse app.cfg.ui.wrap,
        .tab_width = app.cfg.editor.tab_width,
        .line_numbers = app.cfg.ui.line_numbers,
        .cursor_shape = cursor_mod.forMode(mode),
        .focused = focused,
        .visual_block = mode == .visual_block,
        .block_eol = e.buf.editor.block_eol,
        .scrollbar = app.cfg.ui.scrollbar,
        .gutter_marks = try gutterMarksFor(app, arena, id, e, ui.ascii),
        .blame = (try git_app.blameLabels(app, id, arena)) orelse &.{},
        .underlines = try decor.mergeUnderlines(arena, try lsp.underlinesFor(app, arena, e, &app.theme), try decor.linkUnderlinesFor(app, arena, e, &app.theme)),
        .var_spans = try http_app.editorVarSpans(app, arena, e),
        .labels = labels,
        .echo = if (app.click_echo) |ce| (if (ce.pane == id and ce.until_ms > app.now_ms) editor_view.Range{ .start = ce.start, .end = ce.end } else null) else null,
        .virtual_text = try mergeVirtual(arena, try mergeVirtual(arena, try mergeVirtual(arena, try decor.virtualTextFor(app, arena, e, &app.theme, ui.ascii), try dap.inlineValuesFor(app, arena, e, &app.theme)), try script_decor.virtualTextFor(app, arena, id, e, &app.theme)), try line_blame.virtualTextFor(app, arena, id, e, &app.theme)),
        .stopped_line = dap.stoppedLine(app, e),
        .virtual_lines = try conflicts.mergeVirtualLines(arena, try conflicts.mergeVirtualLines(arena, try decor.virtualLinesFor(app, arena, e, &app.theme, ui.ascii), try conflicts.virtualLinesFor(app, arena, e, &app.theme, ui.ascii)), try script_decor.virtualLinesFor(app, arena, id, e, &app.theme)),
        .line_grounds = try script_decor.lineGroundsFor(app, arena, id, e, &app.theme),
        // ── ui toggles ──
        .relative_numbers = app.cfg.ui.relative_line_numbers,
        .cursor_line_band = app.cfg.ui.cursor_line,
        .show_whitespace = app.cfg.ui.show_whitespace,
        .highlight_trailing_ws = app.cfg.ui.highlight_trailing_ws,
        .bracket_rainbow = app.cfg.ui.bracket_rainbow,
        .word_matches = if (app.cfg.ui.highlight_word_under_cursor) blk: {
            var found: []const editor_view.Range = &.{};
            for (ranges.slice()) |r| found = try std.mem.concat(arena, editor_view.Range, &.{ found, try wordMatches(arena, ed, ed.lineStart(r[0]), ed.lineEnd(r[1])) });
            break :blk found;
        } else &.{},
        .todo_keywords = app.cfg.ui.highlight_todo_keywords,
        .color_column = app.cfg.ui.color_column,
        .render_markdown = app.cfg.ui.render_markdown and e.buf.doc.path != null and md_preview.isMarkdownPath(e.buf.doc.path.?),
        .indent_guides = switch (app.cfg.editor.indent_guides) {
            .off => .off,
            .on => .on,
            .active => .active,
        },
        .indent_step = if (app.cfg.editor.indent_guides == .off) 0 else guideStep(e),
    };
    const cursor = editor_view.draw(ui, id, rect, &e.view, doc);
    try http_app.drawEditorVarTip(app, ui, id, e, rect);
    if (armed) |f| drawFlashCue(ui, rect, f);
    if (ed.ghost_suggestion) |ghost| if (cursor) |c| {
        var digits: u16 = 1;
        var n = ed.lineCount();
        while (n >= 10) : (n /= 10) digits += 1;
        const gutter: u16 = if (app.cfg.ui.line_numbers) @max(digits, 3) + 2 else 0;
        drawGhost(ui, rect, c, ed, ghost, gutter);
    };
    const headers = try sticky.headerLines(app, e, arena);
    if (headers.len > 0) sticky.draw(ui, id, e, rect, headers, app.cfg.ui.line_numbers);
    if (app.active == id) {
        app.pane_rows = @max(rect.h, 1);
        // Text columns: the gutter takes the digits plus two.
        var digits: u16 = 1;
        var n = e.buf.editor.lineCount();
        while (n >= 10) : (n /= 10) digits += 1;
        const gutter: u16 = if (app.cfg.ui.line_numbers) digits + 2 else 0;
        app.pane_cols = @max(rect.w -| gutter, 1);
        // The caret, with the mode's shape: a block in NORMAL and
        // VISUAL, a bar in INSERT (and in modeless editing, which is an
        // insert caret the whole time), an underline in REPLACE.
        if (focused) if (cursor) |c| {
            app.cursor_pos = c;
            app.cursor_shape = doc.cursor_shape;
        };
    }
    if (bar) |b| if (app.find_bar) |*fb| {
        if (find_bar_mod.draw(ui, b, &fb.state, .{ .current = e.find.current, .total = e.find.matches.items.len })) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

/// The columns one indent level takes in `e`'s buffer, for its indent
/// guides; 0 is the tab width (a tab-indented file). A `.editorconfig`'s
/// indent is the answer when it named one; otherwise what the text is
/// indented by (`editor/indent.zig`, over the first `guide_detect_bytes`
/// — a file's indent is settled long before that), cached per pane
/// until the next edit; a file that says nothing gets `tab_width`'s
/// unit. A detected step of one column is alignment, not indent.
fn guideStep(e: *app_mod.EditorPane) u8 {
    const doc = e.buf.doc;
    const fallback: u8 = if (doc.use_tabs) 0 else @intCast(@min(doc.indent_unit, 16));
    if (doc.indent_pinned) return fallback;
    const head = doc.edits.head();
    if (e.guide_step) |c| if (c.seq == head) return c.step;
    const text = e.buf.editor.bytes();
    const step: u8 = if (indent_mod.detect(text[0..@min(text.len, guide_detect_bytes)])) |d|
        (if (d.use_tabs) 0 else if (d.unit >= 2) @intCast(d.unit) else fallback)
    else
        fallback;
    e.guide_step = .{ .seq = head, .step = step };
    return step;
}

const guide_detect_bytes = 256 * 1024;

/// The cmdline-history / quickfix list: a header, then one row per
/// entry with the cursor row banded. Rows register `.script_hit`.
fn drawListPane(app: *App, l: *app_mod.ListPane, ui: Ui, pane: PaneId, area: Rect) void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    const header = switch (l.kind) {
        .cmdline_history => ui.fmt(" cmdline history · {d} entr{s} · enter re-runs · esc closes ", .{ l.entries.items.len, if (l.entries.items.len == 1) "y" else "ies" }),
        .search_history => ui.fmt(" search history · {d} entr{s} · enter searches {s} · esc closes ", .{ l.entries.items.len, if (l.entries.items.len == 1) "y" else "ies", if (l.reverse) "backward" else "forward" }),
        .quickfix => ui.fmt(" {d} match{s}   ·   quickfix: enter opens · esc closes ", .{ l.entries.items.len, if (l.entries.items.len == 1) "" else "es" }),
        // changed: a third list kind — the location list is the quickfix row layout under its own header.
        .location => ui.fmt(" {d} entr{s}   ·   location list: enter opens · :lnext / :lprev walk · esc closes ", .{ l.entries.items.len, if (l.entries.items.len == 1) "y" else "ies" }),
        // // changed (git-more2): the git list kinds.
        .stash_files => ui.fmt(" {s}   ·   {d} file{s}   ·   enter diffs · y copies the path · / filters · esc closes ", .{ git_app.stashViewTitle(app), l.entries.items.len, if (l.entries.items.len == 1) "" else "s" }),
        .git_log => ui.fmt(" git command log   ·   {d} entr{s}, newest first   ·   enter re-runs a read-only command · y copies · / filters · esc closes ", .{ l.entries.items.len, if (l.entries.items.len == 1) "y" else "ies" }),
    };
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(header, area.w), Theme.onBg(th.accent, th.bg.bg));
    if (area.h < 2) return;
    var list = area.splitTop(1).rest;
    // The filter row, while one is typed or set.
    if (l.filter_mode or l.filter.items.len > 0) {
        const fr = list.splitTop(1);
        list = fr.rest;
        const text = ui.fmt(" / {s}{s}", .{ l.filter.items, if (l.filter_mode) "\u{2588}" else "" });
        _ = ui.putStr(fr.top.x, fr.top.y, fr.top.w, ui.clipStr(text, fr.top.w), Theme.onBg(th.fg, th.bg.bg));
    }
    const shown = l.shown(ui.arena) catch return;
    const rows: usize = list.h;
    if (l.cursor >= shown.len) l.cursor = shown.len -| 1;
    if (l.cursor < l.scroll) l.scroll = l.cursor;
    if (rows > 0 and l.cursor >= l.scroll + rows) l.scroll = l.cursor + 1 - rows;
    var y: u16 = 0;
    var i = l.scroll;
    while (i < shown.len and y < list.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = list.row(y);
        const e = l.entries.items[shown[i]];
        const sel = i == l.cursor and app.active == pane;
        if (sel) ui.fill(r, th.cursor_line);
        const bg = if (sel) th.cursor_line.bg else th.bg.bg;
        var x = r.x + 2;
        if (e.path) |p| {
            x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s}:{d}:{d} ", .{ p, e.line, e.col }), Theme.onBg(th.muted, bg));
        }
        _ = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(e.text, r.right() -| x), Theme.onBg(th.fg, bg));
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
    }
}

// ── statusline ──
/// The bottom row: `app/statusline.zig` builds the chips, the
/// component paints the lanes.
fn drawStatusline(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    try statusline_app.draw(app, ui, area);
}
// ── statusline ──

/// The row under the statusline: an open `:` line, else the newest
/// toast echoed beside whatever async work is in flight, else a click
/// target that opens the `:` line (`ui/cmdline_bar.zig`).
fn drawCmdline(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    if (area.isEmpty()) return;
    // The app's own `:` line wins over a buffer's, whatever the focus:
    // `Ctrl+;` opens it from the tree and from a terminal pane too, and
    // an editor's pending state must not paint over it.
    var line: ?[]const u8 = try cmdline_mod.display(app, ui.arena, ui.ascii);
    if (line == null) if (app.activeEditor()) |e| {
        if (e.buf.input.cmdlineGet()) |l| {
            const caret = @min(e.buf.input.cmdlineCaret() orelse l.len, l.len);
            line = ui.fmt(":{s}{s}{s}", .{ l[0..caret], if (ui.ascii) "|" else "▏", l[caret..] });
        }
    };
    const model: cmdline_bar.Model = .{
        .line = line,
        // No echo under an open overlay: the toast paints beneath the
        // overlay, so its words must not surface on the row below it.
        .toast = if (line == null and app.overlay == .none) app.lastToast() else null,
        .inflight = if (line == null) inflightNames(app, ui.arena) catch null else null,
    };
    if (cmdline_bar.draw(ui, area, model, cmdline_bar_hits)) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
}

pub const cmdline_bar_hits: cmdline_bar.Hits = .{
    .bar = @intFromEnum(Button.cmdline_bar),
    .inflight = @intFromEnum(Button.cmdline_inflight),
    .mention = @intFromEnum(Button.cmdline_mention),
};

/// `bench (12/100 · 5s), sync (3s)` — the async HTTP work in flight,
/// each with how long it has been going, or null when there is none.
/// A toast fades in three seconds; a bench does not, so this is the
/// only lasting signal that something is still running.
pub fn inflightNames(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    const secs = struct {
        fn f(now: i64, started: i64) i64 {
            return @divTrunc(@max(now - started, 0), 1000);
        }
    }.f;
    if (app.http.bench) |*b| try parts.append(arena, try std.fmt.allocPrint(arena, "bench ({d}/{d} · {d}s)", .{ b.samples.items.len, b.total, secs(app.now_ms, b.started_ms) }));
    if (app.http.fan) |*f| try parts.append(arena, try std.fmt.allocPrint(arena, "envs ({d}/{d} · {d}s)", .{ f.done, f.total, secs(app.now_ms, f.started_ms) }));
    if (app.http.sync_running) try parts.append(arena, "sync");
    if (app.http.chain_running) try parts.append(arena, "chain");
    if (app.http.sending > 0) try parts.append(arena, try std.fmt.allocPrint(arena, "send ×{d}", .{app.http.sending}));
    if (parts.items.len == 0) return null;
    return try std.mem.join(arena, ", ", parts.items);
}

/// The standard profile's `Ctrl+K` popup (`ChordChain.menu`): the
/// keymap's own continuations of the pending chain — `w → Close other
/// tabs`, `g → +2` — drawn by the which-key component. Never the vim
/// leader tree: these rows are what the next key will run.
fn drawChordMenu(app: *App, ui: Ui, screen: Rect) Allocator.Error!void {
    const seq = app.chord.seq[0..app.chord.len];
    const kids = try app.keymap.continuations(ui.arena, seq);
    const entries = try ui.arena.alloc(which_key.Entry, kids.len);
    for (kids, 0..) |k, i| {
        var kb: std.Io.Writer.Allocating = .init(ui.arena);
        k.next.format(&kb.writer) catch return error.OutOfMemory;
        // A leaf reads as the leader popup's rows do — the command's
        // `short` name, its title when it has none — so the rows fit
        // side by side; a group is the leader table's label for the
        // same letter (`g` → `+git`) with its count.
        entries[i] = .{
            .key = kb.written(),
            .label = if (k.target) |tg| switch (tg) {
                .static => |id| command.shortTitle(id),
                .named => |n| n,
            } else if (chordGroupLabel(seq, k.next)) |g|
                ui.fmt("{s} ({d})", .{ g, k.longer })
            else
                ui.fmt("+{d} chord{s}", .{ k.longer, if (k.longer == 1) "" else "s" }),
            .is_group = k.target == null,
        };
    }
    var title: std.Io.Writer.Allocating = .init(ui.arena);
    for (seq, 0..) |c, i| {
        if (i > 0) title.writer.writeAll(" ") catch return error.OutOfMemory;
        var one: std.Io.Writer.Allocating = .init(ui.arena);
        c.format(&one.writer) catch return error.OutOfMemory;
        // The profile's own spelling for its leader chord.
        title.writer.writeAll(if (i == 0 and std.mem.eql(u8, one.written(), "ctrl+k")) whichkey.leaderLabel(false) else one.written()) catch return error.OutOfMemory;
    }
    which_key.draw(ui, screen, title.written(), entries);
}

/// The `Ctrl+K` group under `seq` + `next`, labelled by the leader
/// table's row for the same keys (`whichkey.groups`: `g` → `+git`), so
/// the two popups call a group one thing. Plain characters only.
fn chordGroupLabel(seq: []const ChordT, next: ChordT) ?[]const u8 {
    var path: [whichkey.max_depth]u8 = undefined;
    if (seq.len > path.len) return null;
    var n: usize = 0;
    for (seq[1..]) |c| {
        path[n] = plainChar(c) orelse return null;
        n += 1;
    }
    path[n] = plainChar(next) orelse return null;
    n += 1;
    for (whichkey.groups) |g| if (std.mem.eql(u8, g.prefix, path[0..n])) return g.label;
    return null;
}

const ChordT = @import("../core/key.zig").Chord;

/// A chord that is one unmodified character (a shifted letter as its
/// capital, as the leader table spells `space T`).
fn plainChar(c: ChordT) ?u8 {
    const ch = switch (c.code) {
        .char => |v| v,
        else => return null,
    };
    if (c.mods.ctrl or c.mods.alt or c.mods.super or ch >= 128) return null;
    return if (c.mods.shift and ch >= 'a' and ch <= 'z') @intCast(ch - ('a' - 'A')) else @intCast(ch);
}

/// The prompt, the confirm, the picker and the which-key popup are
/// placed on the whole screen, as Rust places them (`frame.area()`);
/// `body` is the pane area the rest anchor to.
fn drawOverlay(app: *App, ui: Ui, body: Rect) Allocator.Error!void {
    _ = body;
    const screen = ui.canvas.full();
    switch (app.overlay) {
        // No overlay, but a vim operator is pending: the same popup
        // lists what `g` / `z` / `ctrl+w` continue with, as the
        // reference editor's does.
        .none => if (if (app.activeEditor()) |e| e.buf.input.operatorMenuHint() else null) |hint| {
            const entries = try ui.arena.alloc(which_key.Entry, hint.items.len);
            for (hint.items, 0..) |it, i| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(it.key, &buf) catch 1;
                entries[i] = .{ .key = try ui.arena.dupe(u8, buf[0..n]), .label = it.label, .is_group = it.group };
            }
            which_key.draw(ui, screen, ui.fmt("Vim: {s}", .{hint.prefix}), entries);
        } else if (app.chord.menu) try drawChordMenu(app, ui, screen),
        .prompt => |*p| if (prompt_mod.draw(ui, screen, &p.state)) |c| {
            app.cursor_pos = .{ .x = c.x, .y = c.y };
        },
        .confirm => |*c| confirm_mod.draw(ui, screen, &c.state),
        .picker => |*p| {
            const items = try ui.arena.alloc(picker_mod.Item, p.filtered.items.len);
            for (p.filtered.items, 0..) |idx, i| items[i] = .{
                .label = p.labels[idx],
                .detail = if (p.details.len > idx) p.details[idx] else null,
                .hint = if (p.hints.len > idx and p.hints[idx].len > 0) p.hints[idx] else null,
                .icon = if (p.icons.len > idx and p.icons[idx].len > 0) p.icons[idx] else null,
                .marked = p.marked.len > idx and p.marked[idx],
            };
            p.state.total = p.labels.len;
            const preview = try ui.arena.alloc(picker_mod.PreviewRow, p.preview.len);
            for (p.preview, 0..) |row, i| preview[i] = row;
            p.state.preview = preview;
            if (picker_mod.draw(ui, screen, &p.state, items)) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
        },
        .which_key => |*w| {
            // The title is the leader and the keys typed so far; inside
            // a group it carries that group's own row — `<leader>f
            // +find (7)` — the way the reference plugin's header reads.
            //
            // The leader is the ACTIVE profile's, not always vim's: the
            // standard profile has no `<leader>` to press, it opens this
            // popup on `Ctrl+K` (`docs/KEYMAP_PROFILES.md` rule 2), and
            // a header naming a key that profile does not carry told a
            // VS Code user to press something that does not exist. A
            // deliberate departure from the reference editor, which
            // titles both profiles `<leader>` (`docs/PARITY.md`).
            const path = w.slice();
            const vim = app.input_style == .vim;
            const leader = whichkey.leaderLabel(vim);
            const gap = whichkey.leaderGap(vim);
            const here = try whichkey.lookupWith(ui.arena, &app.dyn_commands, path, vim);
            const title: []const u8 = if (path.len == 0 or here == null)
                leader
            else if (here.? == .dyn_group)
                ui.fmt("{s}{s}{s}  +{s}", .{ leader, gap, path, here.?.label() })
            else
                ui.fmt("{s}{s}{s}  {s} ({d})", .{ leader, gap, path, here.?.label(), whichkey.chordCount(&here.?, vim) });
            // A group row wears its own face; a leaf wears the face of
            // the group it lives in, which `which_key` paints dimmer.
            const leaf_glyph = whichkey_glyph.forGroup(if (here) |n| n.label() else "").pick(ui.ascii);
            const kids = try whichkey.kidsWith(ui.arena, &app.dyn_commands, path, vim);
            const entries = try ui.arena.alloc(which_key.Entry, kids.len);
            for (kids, 0..) |*k, i| {
                const key = try ui.arena.alloc(u8, 1);
                key[0] = k.key;
                const is_group = k.node == .group or k.node == .dyn_group;
                const label: []const u8 = switch (k.node) {
                    .group => ui.fmt("{s} ({d})", .{ k.node.label(), whichkey.chordCount(&k.node, vim) }),
                    .dyn_group => ui.fmt("+{s}", .{k.node.label()}),
                    else => k.node.label(),
                };
                entries[i] = .{
                    .key = key,
                    .label = label,
                    .is_group = is_group,
                    .glyph = if (is_group) whichkey_glyph.forGroup(k.node.label()).pick(ui.ascii) else leaf_glyph,
                    .id = @intCast(i),
                };
            }
            which_key.draw(ui, screen, title, entries);
        },
        // A menu paints last of all, after the toasts (`render`).
        .menu => {},
        .settings => |*s| {
            const both = try settings_app.lists(app, ui.arena);
            const sub = try settings_app.footer(app, ui.arena, both.visible);
            // Centered on the screen, but the tab strip and the statusline
            // stay: the box never covers row 0 or the last row.
            const full = ui.canvas.full();
            const box = Rect.init(full.x, full.y + 1, full.w, full.h -| 2);
            // The filter pill's caret, while the pill has the keys.
            if (settings_ui.draw(ui, box, &s.ui, both.visible, sub, .{ .all = both.all, .typeahead = app.input_style != .vim })) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
        },
        .wizard => |*w| {
            const full = ui.canvas.full();
            wizard_ui.draw(ui, Rect.init(full.x, full.y + 1, full.w, full.h -| 2), &w.ui, first_launch.model(app));
        },
        .info => |kind| cmd_view.drawInfo(app, ui, ui.canvas.full(), kind),
        .discovery => discovery.drawOverlay(app, ui, ui.canvas.full()),
        .help => |*h| help_ui.draw(ui, ui.canvas.full(), h, try help_app.rows(app, ui.arena)),
        .jobs => |*j| try @import("jobs.zig").drawOverlay(app, ui, j),
    }
}

/// A menu, in one of the two shapes the Rust editor paints
/// (`ui/context_menu.rs`, `ui/menu_bar.rs`): both a square frame on
/// `bg2`, the selected row `bg_dark` on cyan, a child beside its
/// parent row, to the right when it fits, else to the left.
///
/// A context menu (`m.dropdown == false`) carries its title in the top
/// border and nothing else: the frame is `rows + 2` tall, as a
/// dropdown's is. (It used to reserve a title row the border already
/// held, which painted as a blank line above the bottom border.) A row
/// is ` <glyph>  label `, padded, then `▸ ` on a parent row or `⋮ ` on
/// the focused leaf of a curatable menu. A menu-bar dropdown has no title; its row is a
/// two-cell marker (`▸ ` on the highlighted row), the icon column
/// (three cells, when any row has an icon), the label, and ` ▸` at
/// the end of a parent row. The highlight paints only once the menu
/// was interacted with (`m.highlight`): a mouse-opened dropdown shows
/// none until a row is hovered or an arrow pressed, as Rust's.
///
/// Every row registers `.menu_item{0, idx}` (the child's rows `{1,
/// idx}`); a separator paints a rule and registers nothing; the kebab
/// registers `{2, idx}` / `{3, idx}` over its own two cells.
fn drawMenu(ui: Ui, screen: Rect, m: *app_mod.MenuState) void {
    const size = menuSize(ui, if (m.dropdown) null else m.title, m.items, m.dropdown);
    const w: u16 = @min(size.w, screen.w);
    const h: u16 = @min(size.h, screen.h);
    const x = @min(m.x, (screen.x + screen.w) -| w);
    const y = menuTop(screen, m.y, h);
    const frame = Rect.init(x, y, w, h);
    const inner = overlay_mod.frameLook(ui, frame, if (m.dropdown) null else m.title, .menu);
    if (inner.isEmpty()) return;
    const parent_row = paintMenuRows(ui, inner, .{
        .items = m.items,
        .cursor = if (m.highlight) &m.cursor else null,
        .scroll = &m.scroll,
        .follow = m.follow,
        .menu_id = 0,
        .kebab = m.curatable and m.sub == null,
        .dropdown = m.dropdown,
    });
    const sub = if (m.sub) |*s| s else return;
    // The child: a context menu's hangs from the parent row (its first
    // row one below it), a dropdown's lines its first row up with it.
    const child = menuSize(ui, null, sub.items, m.dropdown);
    const cw: u16 = @min(child.w, screen.w);
    const ch: u16 = @min(child.h, screen.h);
    const row_y = inner.y + (parent_row.get(sub.parent) orelse 0);
    const cx: u16 = if (frame.right() + cw <= screen.right()) frame.right() else frame.x -| cw;
    const want_y = if (m.dropdown) row_y -| 1 else row_y;
    const cy = @max(@min(want_y, (screen.y + screen.h) -| ch), screen.y);
    const crect = Rect.init(cx, cy, cw, ch);
    const cinner = overlay_mod.frameLook(ui, crect, null, .menu);
    sub.rect = crect;
    if (cinner.isEmpty()) return;
    _ = paintMenuRows(ui, cinner, .{
        .items = sub.items,
        .cursor = if (sub.highlight) &sub.cursor else null,
        .scroll = &sub.scroll,
        .follow = sub.follow,
        .menu_id = 1,
        .kebab = m.curatable,
        .dropdown = m.dropdown,
    });
}

/// The top row of an `h`-row menu anchored at `anchor_y`: the anchor
/// when the menu fits below it, the row that puts the menu's bottom on
/// the anchor when it only fits above, else as low as `screen` allows.
pub fn menuTop(screen: Rect, anchor_y: u16, h: u16) u16 {
    if (anchor_y + h <= screen.bottom()) return @max(anchor_y, screen.y);
    if (anchor_y + 1 >= screen.y + h) return anchor_y + 1 - h;
    return @max(screen.bottom() -| h, screen.y);
}

const MenuSize = struct { w: u16, h: u16 };

/// The marker a dropdown row ends in (` ▸`) and a context row ends in
/// (`▸ ` / `⋮ `): two cells either way.
const marker_w: u16 = 2;
/// The dropdown's left column: `▸ ` on the highlighted row.
const dropdown_marker_w: u16 = 2;
/// A dropdown is never narrower than this (Rust's `.max(20)`).
const dropdown_min_w: u16 = 20;
/// A context menu's inner width is never narrower than this
/// (Rust's `.max(12)`).
const context_min_inner: u16 = 12;

/// The label as painted: a checked row carries its `✓ ` in the label,
/// as Rust's do.
fn rowLabel(ui: Ui, it: command.MenuItem) []const u8 {
    if (!it.checked) return it.label;
    return ui.fmt("{s} {s}", .{ if (ui.ascii) "*" else "\u{2713}", it.label });
}

/// Frame + rows, in the shape Rust sizes them (`ContextMenu::
/// content_width`; `menu_bar.rs`'s `w` / `sub_w`).
fn menuSize(ui: Ui, title: ?[]const u8, items: []const command.MenuItem, dropdown: bool) MenuSize {
    var rows: u16 = 0;
    var widest: u16 = 0;
    var any_icon = false;
    for (items) |it| {
        rows += 1;
        if (it.separator_before) rows += 1;
        if (menu_glyph.forItem(it, ui.ascii).len > 0) any_icon = true;
        const label_w = ui.width(rowLabel(ui, it)) + if (it.submenu.len > 0) marker_w else 0;
        widest = @max(widest, label_w);
    }
    if (dropdown) {
        const icon_col: u16 = if (any_icon) menu_glyph.width else 0;
        return .{ .w = @max(widest + icon_col + 4, dropdown_min_w), .h = rows + 2 };
    }
    var longest: u16 = @max(widest + menu_glyph.width, 8);
    if (title) |tt| longest = @max(longest, ui.width(tt));
    const inner = @max(longest + 2, context_min_inner);
    // A titled context menu is `rows + 2`, the same as a dropdown. The
    // title is NOT a row: `overlay.frameLook` paints it INSIDE the top
    // border, so a height that reserved a row for it left an empty line
    // above the bottom border of every right-click menu in the app —
    // the reference editor (`src/ui/context_menu.rs`, `items.len() +
    // title_rows + 2`) has the same off-by-one, and this departs from it
    // deliberately (`docs/PARITY.md`).
    return .{ .w = inner + 2, .h = rows + 2 };
}

const RowsProps = struct {
    items: []const command.MenuItem,
    /// The highlighted row; null paints every row plain.
    cursor: ?*usize,
    /// The first item painted; clamped here so the window is never
    /// short of rows while rows are left, then reconciled with the
    /// cursor per `follow`.
    scroll: *usize,
    follow: app_mod.MenuFollow,
    menu_id: u32,
    /// Paint the curation kebab on the highlighted leaf row.
    kebab: bool,
    dropdown: bool,
};

/// The rows item `i` takes when it is painted: its own and its rule.
fn menuItemRows(it: command.MenuItem) u16 {
    return if (it.separator_before) 2 else 1;
}

/// How many items from `start` fit in `h` rows.
fn menuItemsFitting(items: []const command.MenuItem, start: usize, h: u16) usize {
    var used: u16 = 0;
    var i = start;
    while (i < items.len) : (i += 1) {
        used += menuItemRows(items[i]);
        if (used > h) break;
    }
    return i - start;
}

/// The largest first item that still fills the window (Rust's
/// `len - rows` with rows that are not all one cell tall).
fn menuMaxScroll(items: []const command.MenuItem, h: u16) usize {
    var used: u16 = 0;
    var i = items.len;
    while (i > 0) : (i -= 1) {
        const rows = menuItemRows(items[i - 1]);
        if (used + rows > h) break;
        used += rows;
    }
    return i;
}

/// Where the window starts for `p` in `h` rows: clamped to the list,
/// then the cursor pulled into it (the wheel moved the window) or it
/// pulled after the cursor (a key moved the cursor). Rust 1ef21198:
/// a menu taller than the screen painted what fit and dropped the
/// rest, so the rows a right-click exists for were unreachable.
fn menuWindow(p: RowsProps, h: u16) usize {
    var scroll = @min(p.scroll.*, menuMaxScroll(p.items, h));
    if (p.cursor) |cur| {
        const c = @min(cur.*, p.items.len -| 1);
        switch (p.follow) {
            .cursor => {
                if (c < scroll) scroll = c;
                while (c >= scroll + menuItemsFitting(p.items, scroll, h) and scroll < c) scroll += 1;
            },
            .window => {
                const fit = menuItemsFitting(p.items, scroll, h);
                if (c < scroll) {
                    cur.* = scroll;
                } else if (fit > 0 and c >= scroll + fit) {
                    cur.* = scroll + fit - 1;
                }
            },
        }
    }
    p.scroll.* = scroll;
    return scroll;
}

/// Paints the rows into `inner`, registering `.menu_item{menu_id, i}`,
/// and returns each item's row offset (for anchoring a child). Rows
/// off the window are not painted; the bottom border's last cell says
/// which way the rest lies (`↑` / `↓` / `↕`).
fn paintMenuRows(ui: Ui, inner: Rect, p: RowsProps) std.AutoHashMapUnmanaged(usize, u16) {
    const th = ui.theme;
    const pal = th.palette;
    var offsets: std.AutoHashMapUnmanaged(usize, u16) = .empty;
    const plain = th.overlay_bg;
    const highlight: Style = .{ .fg = pal.bg_dark, .bg = pal.cyan, .bold = true };
    const rule = Theme.onBg(th.muted, plain.bg);
    // The dropdown's icon column is there only when a row has an icon.
    var any_icon = false;
    for (p.items) |it| if (menu_glyph.forItem(it, ui.ascii).len > 0) {
        any_icon = true;
    };
    const icon_col: u16 = if (p.dropdown and !any_icon) 0 else menu_glyph.width;
    const scroll = menuWindow(p, inner.h);
    const painted = menuItemsFitting(p.items, scroll, inner.h);
    const more_above = scroll > 0;
    const more_below = scroll + painted < p.items.len;
    if (more_above or more_below) {
        const glyph: []const u8 = if (more_above and more_below) (if (ui.ascii) "|" else "\u{2195}") else if (more_above) (if (ui.ascii) "^" else "\u{2191}") else (if (ui.ascii) "v" else "\u{2193}");
        _ = ui.putStr(inner.right() -| 1, inner.bottom(), 1, glyph, rule);
    }
    var row: u16 = 0;
    for (p.items[scroll..], scroll..) |it, i| {
        const selected = p.cursor != null and i == p.cursor.?.*;
        if (it.separator_before and row < inner.h) {
            const r = inner.row(row);
            ui.hrule(r.x, r.y, r.w, rule);
            row += 1;
        }
        if (row >= inner.h) break;
        const r = inner.row(row);
        offsets.put(ui.arena, i, row) catch {};
        const style = if (selected) highlight else plain;
        ui.fill(r, style);
        var xx = r.x;
        if (p.dropdown) {
            // The marker column, then the icon in the muted colour.
            xx += ui.putStr(xx, r.y, r.right() -| xx, if (selected) (if (ui.ascii) "> " else "\u{25b8} ") else "  ", style);
            if (icon_col > 0) {
                _ = ui.putStr(xx, r.y, r.right() -| xx, menu_glyph.forItem(it, ui.ascii), Theme.withFg(style, if (selected) style.fg else th.muted.fg));
                xx += icon_col;
            }
        } else {
            // One cell of air, then the glyph column in the row's colour.
            xx += 1;
            _ = ui.putStr(xx, r.y, r.right() -| xx, menu_glyph.forItem(it, ui.ascii), style);
            xx += icon_col;
        }
        const label_fg = if (it.action == .none and it.submenu.len == 0) th.muted.fg else style.fg;
        const label = rowLabel(ui, it);
        // The trailing marker: ` ▸` on a dropdown parent, `▸ ` on a
        // context parent, `⋮ ` on a curatable menu's focused leaf.
        var marker: ?[]const u8 = null;
        var kebab_x: ?u16 = null;
        const air: u16 = if (p.dropdown) 0 else 1;
        if (it.submenu.len > 0) {
            marker = if (p.dropdown) (if (ui.ascii) " >" else " \u{25b8}") else (if (ui.ascii) "> " else "\u{25b8} ");
        } else if (p.kebab and selected and it.action == .command) {
            // The kebab only where the label leaves it room: the width
            // reserves nothing for it, and on Rust's screen the label
            // wins (the marker runs off the row) — → and a right press
            // reach the curation either way.
            if (ui.width(label) + marker_w + air <= r.right() -| xx) marker = if (ui.ascii) ": " else "\u{22ee} ";
        }
        const marker_room: u16 = if (marker != null) marker_w else 0;
        const label_max = r.right() -| xx -| marker_room -| air;
        _ = ui.putStr(xx, r.y, label_max, ui.clipStr(label, label_max), Theme.withFg(style, label_fg));
        if (marker) |mk| {
            const mx = r.right() -| marker_w;
            _ = ui.putStr(mx, r.y, marker_w, mk, style);
            if (it.submenu.len == 0) kebab_x = mx;
        }
        // The row's hit stops where the kebab starts, and the kebab's
        // cells are registered after it, so a click on the glyph opens
        // the curation rather than running the row.
        const row_w: u16 = if (kebab_x) |kx| kx -| r.x else r.w;
        ui.hit(Rect.init(r.x, r.y, row_w, 1), .{ .menu_item = .{ .menu = p.menu_id, .idx = @intCast(i) } });
        if (kebab_x) |kx| ui.hit(Rect.init(kx, r.y, r.right() -| kx, 1), .{ .menu_item = .{ .menu = p.menu_id + 2, .idx = @intCast(i) } });
        row += 1;
    }
    return offsets;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

test "frameRects: the bar needs 40 columns (narrow below 80), the cmdline row needs 4 rows, the statusline is last to go" {
    const wide = frameRects(Rect.init(0, 0, 120, 40), .{});
    try t.expect(wide.bar.eql(Rect.init(0, 0, 120, 1)));
    try t.expect(wide.upper.eql(Rect.init(0, 1, 120, 37)));
    try t.expect(wide.status.eql(Rect.init(0, 38, 120, 1)));
    try t.expect(wide.cmdline.eql(Rect.init(0, 39, 120, 1)));
    // 40 columns: the bar stays (narrow — the cluster's extras drop).
    try t.expect(wide.body.eql(wide.upper));
    try t.expect(wide.rail.isEmpty() and wide.sidebar.isEmpty());
    const narrow = frameRects(Rect.init(0, 0, 40, 8), .{});
    try t.expect(narrow.bar.eql(Rect.init(0, 0, 40, 1)));
    try t.expect(narrow.upper.eql(Rect.init(0, 1, 40, 5)));
    try t.expect(narrow.status.eql(Rect.init(0, 6, 40, 1)));
    try t.expect(narrow.cmdline.eql(Rect.init(0, 7, 40, 1)));
    const slim = frameRects(Rect.init(0, 0, 39, 8), .{});
    try t.expect(slim.bar.isEmpty());
    try t.expect(slim.upper.eql(Rect.init(0, 0, 39, 6)));
    const tiny = frameRects(Rect.init(0, 0, 100, 3), .{});
    try t.expect(tiny.bar.isEmpty());
    try t.expect(tiny.cmdline.isEmpty());
    try t.expect(tiny.upper.eql(Rect.init(0, 0, 100, 2)));
    try t.expect(tiny.status.eql(Rect.init(0, 2, 100, 1)));
    const one = frameRects(Rect.init(0, 0, 100, 1), .{});
    try t.expect(one.upper.isEmpty());
    try t.expect(one.status.eql(Rect.init(0, 0, 100, 1)));
}

test "frameRects: `ui.dock.placement = .inner`, the default — an `always` bottom dock is the EDITOR AREA's last row and the statusline and the `:` line do not move" {
    // // changed (dock-placement), the user's "I'd like it above the
    // statusline I think": the default carve is the editor area's last
    // row again (37 at 120x40). `.outer` — the whole frame's last row,
    // under the `:` line — is the test below, and is now opt-in.
    const wide = frameRects(Rect.init(0, 0, 120, 40), .{ .dock = .bottom });
    const none = frameRects(Rect.init(0, 0, 120, 40), .{});
    try t.expect(wide.launcher_dock.eql(Rect.init(0, 37, 120, 1)));
    // The two rows the frame keeps for itself are exactly where they
    // were with no dock at all — the user's "extra bar at the bottom".
    try t.expect(wide.status.eql(none.status) and wide.status.eql(Rect.init(0, 38, 120, 1)));
    try t.expect(wide.cmdline.eql(none.cmdline) and wide.cmdline.eql(Rect.init(0, 39, 120, 1)));
    try t.expect(wide.bar.eql(none.bar));
    // The editor area is the one thing that gave up a row.
    try t.expectEqual(none.upper.h - 1, wide.upper.h);
    try t.expect(wide.upper.eql(Rect.init(0, 1, 120, 36)));
    try t.expect(wide.body.eql(wide.upper));
    // The bottom panel is carved INSIDE the strip, as on a side edge.
    const panel = frameRects(Rect.init(0, 0, 120, 40), .{ .dock = .bottom, .bottom = 12 });
    try t.expect(panel.launcher_dock.eql(Rect.init(0, 37, 120, 1)));
    try t.expect(panel.bottom.eql(Rect.init(0, 25, 120, 12)));
    try t.expect(panel.bottom_divider.eql(Rect.init(0, 24, 120, 1)));
    // A side dock ignores the key: the same frame whichever it says.
    const li = frameRects(Rect.init(0, 0, 120, 40), .{ .dock = .left, .dock_placement = .inner });
    const lo = frameRects(Rect.init(0, 0, 120, 40), .{ .dock = .left, .dock_placement = .outer });
    try t.expect(li.launcher_dock.eql(lo.launcher_dock) and li.launcher_dock.eql(Rect.init(0, 1, 3, 37)));
    try t.expect(li.status.eql(lo.status) and li.cmdline.eql(lo.cmdline));
    // Too little editor to carve from: no strip rather than an editor
    // with none (the old `upper.h >= height + 4` floor).
    const small = frameRects(Rect.init(0, 0, 120, 8), .{ .dock = .bottom });
    const small_bare = frameRects(Rect.init(0, 0, 120, 8), .{});
    try t.expect(small_bare.upper.h >= launcher_dock.height + 4);
    try t.expect(!small.launcher_dock.isEmpty() and small.upper.h == small_bare.upper.h - 1);
    const tiny = frameRects(Rect.init(0, 0, 120, 6), .{ .dock = .bottom });
    try t.expect(tiny.launcher_dock.isEmpty() and tiny.upper.eql(frameRects(Rect.init(0, 0, 120, 6), .{}).upper));
}

test "frameRects: `ui.dock.placement = .outer` — an `always` bottom launcher dock takes the SCREEN's last row, under the `:` line, and every other row moves up one" {
    // // changed (edge-grip): it used to be the editor area's last row
    // (37 at 120x40), two rows in from the screen's edge, where the
    // reveal band nothing marked also sat. Both are row 39 now.
    // // changed (dock-placement): and this is `.outer` now — the opt-in.
    const wide = frameRects(Rect.init(0, 0, 120, 40), .{ .dock = .bottom, .dock_placement = .outer });
    try t.expect(wide.launcher_dock.eql(Rect.init(0, 39, 120, 1)));
    // The bottom panel / statusline / `:` line keep their order inside
    // what is left — each one row up from the dockless frame.
    try t.expect(wide.bar.eql(Rect.init(0, 0, 120, 1)));
    try t.expect(wide.status.eql(Rect.init(0, 37, 120, 1)));
    try t.expect(wide.cmdline.eql(Rect.init(0, 38, 120, 1)));
    // The editor area is one row shorter, and nothing else changed.
    const none = frameRects(Rect.init(0, 0, 120, 40), .{});
    try t.expectEqual(none.upper.h - 1, wide.upper.h);
    try t.expect(wide.upper.eql(Rect.init(0, 1, 120, 36)));
    try t.expect(wide.body.eql(wide.upper));
    // The bottom panel is carved INSIDE it, as it always was.
    const panel = frameRects(Rect.init(0, 0, 120, 40), .{ .dock = .bottom, .dock_placement = .outer, .bottom = 12 });
    try t.expect(panel.launcher_dock.eql(Rect.init(0, 39, 120, 1)));
    try t.expect(panel.bottom.eql(Rect.init(0, 25, 120, 12)));
    try t.expect(panel.bottom_divider.eql(Rect.init(0, 24, 120, 1)));
    // A side dock is still carved off the editor area, not the screen.
    const left = frameRects(Rect.init(0, 0, 120, 40), .{ .dock = .left });
    try t.expect(left.launcher_dock.eql(Rect.init(0, 1, 3, 37)));
    try t.expect(left.cmdline.eql(Rect.init(0, 39, 120, 1)));
    // Too short for the row: no dock rather than an editor with none.
    const tight = frameRects(Rect.init(0, 0, 120, dock_bottom_min_height), .{ .dock = .bottom, .dock_placement = .outer });
    try t.expect(!tight.launcher_dock.isEmpty());
    const short = frameRects(Rect.init(0, 0, 120, dock_bottom_min_height - 1), .{ .dock = .bottom, .dock_placement = .outer });
    const bare = frameRects(Rect.init(0, 0, 120, dock_bottom_min_height - 1), .{});
    try t.expect(short.launcher_dock.isEmpty());
    try t.expect(short.upper.eql(bare.upper) and short.status.eql(bare.status) and short.cmdline.eql(bare.cmdline));
}

test "frameRects: the rail and its border come off the sidebar's own 30 columns — the tree's divider stays at column 30 (the Rust dump); hidden hands the tree the cells back; a narrow sidebar keeps the rail, loses the border" {
    const with = frameRects(Rect.init(0, 0, 120, 40), .{ .sidebar = 30 });
    try t.expect(with.rail.eql(Rect.init(0, 1, 3, 37)));
    try t.expect(with.rail_border.eql(Rect.init(3, 1, 1, 37)));
    try t.expect(with.sidebar.eql(Rect.init(4, 1, 26, 37)));
    try t.expect(with.sidebar_divider.eql(Rect.init(30, 1, 1, 37)));
    try t.expect(with.body.eql(Rect.init(31, 1, 89, 37)));
    const without = frameRects(Rect.init(0, 0, 120, 40), .{ .sidebar = 30, .rail = false });
    try t.expect(without.rail.isEmpty() and without.rail_border.isEmpty());
    try t.expect(without.sidebar.eql(Rect.init(0, 1, 30, 37)));
    try t.expect(without.sidebar_divider.eql(Rect.init(30, 1, 1, 37)));
    try t.expect(without.body.eql(with.body));
    // 80x24: the sidebar keeps its 30; the rail spans rows 1..21.
    const small = frameRects(Rect.init(0, 0, 80, 24), .{ .sidebar = 30 });
    try t.expect(small.rail.eql(Rect.init(0, 1, 3, 21)));
    try t.expect(small.sidebar_divider.eql(Rect.init(30, 1, 1, 21)));
    // The sidebar's floor is 8: rail 3, border 1, four cells of tree.
    const slim = frameRects(Rect.init(0, 0, 120, 40), .{ .sidebar = 4 });
    try t.expect(slim.rail.eql(Rect.init(0, 1, 3, 37)));
    try t.expect(slim.rail_border.eql(Rect.init(3, 1, 1, 37)));
    try t.expect(slim.sidebar.eql(Rect.init(4, 1, 4, 37)));
    // A screen too narrow for a sidebar has none, rail included.
    const none = frameRects(Rect.init(0, 0, 12, 10), .{ .sidebar = 30 });
    try t.expect(none.sidebar.isEmpty() and none.rail.isEmpty());
    try t.expect(none.body.eql(none.upper));
}

test "a frame: bufferline tab, text with gutter, statusline Ln/Col, and the pane hit under the text" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 48, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    const empty = try screenText(&app);
    defer t.allocator.free(empty);
    // No pane: the welcome pane (`ui/welcome.zig`) — whose ladder starts
    // at six rows; the four this frame leaves it paint only the ground.
    // (The workspace name still shows in the search chip and the
    // statusline's workspace chip, as Rust paints it — so the check is
    // for the welcome pane's own line, not the bare name.)
    try t.expect(std.mem.indexOf(u8, empty, "ctrl+p opens") == null);
    try t.expect(std.mem.indexOf(u8, empty, "Shortcuts") == null);
    try t.expect(std.mem.indexOf(u8, empty, "workspace · tmp") == null);
    // Row 0 is the (narrow) palette bar at 48 columns; the strip is row 1.
    try t.expectEqual(@intFromEnum(Button.toggle_tree), app.hits.at(1, 0).?.button);
    try t.expectEqual(Button.newTab(0), app.hits.at(1, 1).?.button);
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.editor.setText("hello\nworld");
    e.buf.editor.placeCursor(1, 2);
    const txt = try screenText(&app);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "[scratch]") != null);
    try t.expect(std.mem.indexOf(u8, txt, "1 hello") != null);
    try t.expect(std.mem.indexOf(u8, txt, "2 world") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Ln 2/2 Col 3") != null);
    try t.expect(std.mem.indexOf(u8, txt, "EDIT") != null); // the mode chip: a writable buffer has focus
    try t.expect(app.hits.at(5, 3).? == .editor_cell);
    try t.expect(app.hits.at(5, 1).? == .tab);
    try t.expectEqual(@as(u32, 0), app.hits.at(5, 1).?.tab.leaf);
    // The `+` after the last tab (` glyph [scratch] × ` is 15 cells), the
    // mode chip on the statusline.
    try t.expectEqual(Button.newTab(0), app.hits.at(17, 1).?.button);
    try t.expectEqual(@as(u32, 0), app.hits.at(2, 6).?.statusline_seg);
    // gutter is max(digits, 3) + 2 = 5 cells; the cursor sits at col 2.
    try t.expectEqual(@as(u16, 7), app.cursor_pos.?.x);
    try t.expectEqual(@as(u16, 3), app.cursor_pos.?.y);
    // 8 rows: bar, strip, 4 text rows, statusline, cmdline.
    try t.expectEqual(@as(usize, 4), app.pane_rows);
    try t.expect(app.panes_area.eql(Rect.init(0, 1, 48, 5)));
}

test "a wide frame has the palette bar on row 0 and the strip on row 1; each leaf carries its own strip" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.split_right" });
    try app.render();
    try t.expectEqual(@intFromEnum(Button.palette), app.hits.at(50, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.toggle_tree), app.hits.at(37, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.toggle_right_panel), app.hits.at(82, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.window_close), app.hits.at(118, 0).?.button);
    try t.expectEqual(@as(u32, 0), app.hits.at(3, 1).?.tab.leaf);
    try t.expectEqual(@as(u32, 1), app.hits.at(64, 1).?.tab.leaf);
    try t.expect(app.hits.at(60, 10).? == .divider);
    // The gutter is its own hit (a breakpoint's home); the text past it
    // is the cell.
    try t.expect(app.hits.at(3, 2).? == .gutter);
    try t.expectEqual(@as(u32, 0), app.hits.at(3, 2).?.gutter.line);
    try t.expect(app.hits.at(9, 2).? == .editor_cell);
    try t.expectEqual(@as(u32, 0), app.hits.at(9, 2).?.editor_cell.line);
    try t.expectEqual(statusline.seg_mode, app.hits.at(2, 38).?.statusline_seg);
    try t.expect(app.hits.at(60, 38) == null);
}

test "the edge grips: one per hidden slide-in, each on its own zone's cells, each a hit that pins — and none at all when the surface is up, pinned, or `ui.edge_grips` is off" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    app.cfg.ui.menu_bar = .auto;
    app.cfg.ui.sidebar = .auto;
    // The shipped dock is already `auto_hide`; say so out loud.
    try t.expectEqual(Config.DockMode.auto_hide, app.cfg.ui.dock.mode);
    try app.render();

    // Where each one landed. The menu bar's is on the words' run, NOT
    // the row's middle — that is the workspace chip's, and the chip
    // never hides.
    const words = ui_menu_bar.wordsRun(hover_zones.barRow(Rect.init(0, 0, 120, 40)).?);
    const menu_cell = edge_grip.place(words, .top).?;
    try t.expectEqual(@as(u16, 16), menu_cell.x);
    try t.expectEqual(@as(u16, 0), menu_cell.y);
    try t.expect(menu_cell.right() < 35);
    const grips = [_]struct { x: u16, y: u16, id: Button }{
        // The bar's row, in the middle of the words' own run.
        .{ .x = menu_cell.x + 1, .y = 0, .id = .edge_grip_menu_bar },
        // Each column's one-cell screen edge, vertically centred.
        .{ .x = 0, .y = 20, .id = .edge_grip_sidebar_left },
        .{ .x = 119, .y = 20, .id = .edge_grip_sidebar_right },
        // The dock's band: the SCREEN's last row, in its middle.
        .{ .x = 59, .y = 39, .id = .edge_grip_dock },
    };
    for (grips) |g| {
        const hit = app.hits.at(g.x, g.y) orelse return error.NoGripHere;
        try t.expectEqual(@intFromEnum(g.id), hit.button);
    }
    // The dock's grip beat the `:` line's whole-row hit, which was
    // registered a moment before it: a click there pins the dock
    // rather than opening a command line.
    try t.expectEqual(@intFromEnum(Button.cmdline_bar), app.hits.at(20, 39).?.button);
    // The glyph really is on each grip's middle cell. (`⋯` and `⋮`
    // turn up elsewhere in the chrome — a fold mark, a row kebab — so
    // the CELL is the honest question, never the whole screen.)
    try t.expectEqualStrings(edge_grip.grip_h, app.screen.readCell(menu_cell.x + 1, 0).?.char.grapheme);
    // The run is rows 18..20; the glyph sits on the middle one.
    try t.expectEqualStrings(edge_grip.grip_v, app.screen.readCell(0, 19).?.char.grapheme);
    try t.expectEqualStrings(edge_grip.grip_v, app.screen.readCell(119, 19).?.char.grapheme);
    try t.expectEqualStrings(edge_grip.grip_h, app.screen.readCell(59, 39).?.char.grapheme);

    // A surface that is UP wears no grip — the pin chip at its end is
    // the handle then.
    app.menu_bar.pinned = true;
    app.sidebar_auto.pinned = true;
    app.launcher_dock.pinned = true;
    try app.render();
    for (grips) |g| {
        const hit = app.hits.at(g.x, g.y);
        if (hit) |h| try t.expect(h != .button or h.button != @intFromEnum(g.id));
    }
    try t.expect(!std.mem.eql(u8, edge_grip.grip_v, app.screen.readCell(0, 19).?.char.grapheme));

    // And `ui.edge_grips = false` gives the invisible bands back — the
    // bands themselves never moved, so the dwell still reveals.
    app.menu_bar.pinned = false;
    app.sidebar_auto.pinned = false;
    app.launcher_dock.pinned = false;
    app.cfg.ui.edge_grips = false;
    try app.render();
    for (grips) |g| {
        const hit = app.hits.at(g.x, g.y);
        if (hit) |h| try t.expect(h != .button or h.button != @intFromEnum(g.id));
    }
    try t.expect(!std.mem.eql(u8, edge_grip.grip_v, app.screen.readCell(0, 19).?.char.grapheme));
    try t.expect(!std.mem.eql(u8, edge_grip.grip_h, app.screen.readCell(59, 39).?.char.grapheme));
    // The band itself never moved: the dwell still reveals.
    try t.expect(hover_zones.dockBand(&app, Rect.init(0, 0, 120, 40)) != null);
}

test "the edge grips: a screen too small for a band paints none of it, and `.hidden` — which registers no dwell zone — never wears one" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 30, .rows = 6 });
    defer app.deinit();
    _ = try app.openScratch();
    app.cfg.ui.menu_bar = .auto;
    app.cfg.ui.sidebar = .auto;
    try app.render();
    // No palette bar at 30 columns, so no bar row and no grip on it;
    // the frame is too short for the dock's row too.
    try t.expect(hover_zones.barRow(Rect.init(0, 0, 30, 6)) == null);
    try t.expect(hover_zones.dockBand(&app, Rect.init(0, 0, 30, 6)) == null);
    try app.render();

    // `.hidden` reveals on no dwell at all, so a grip there would be a
    // handle that does nothing.
    var wide = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer wide.deinit();
    _ = try wide.openScratch();
    wide.cfg.ui.menu_bar = .hidden;
    wide.cfg.ui.sidebar = .hidden;
    wide.cfg.ui.dock.mode = .hidden;
    try wide.render();
    for (wide.hits.items.items) |h| if (h.target == .button) switch (@as(Button, @enumFromInt(h.target.button))) {
        .edge_grip_menu_bar, .edge_grip_sidebar_left, .edge_grip_sidebar_right, .edge_grip_dock => return error.GripOnAHiddenSurface,
        else => {},
    };
}

test "overlays paint over the panes and win the hit test; the find bar docks at the pane bottom" {
    // 13 rows: the palette bar paints at 60 columns, then strip, 8 text
    // rows, find bar, statusline, cmdline.
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 13 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("alpha beta alpha");
    try command.run(&app, .{ .static = .@"find.find" });
    for ("alpha") |c| try app.handle(.{ .key = app_mod.Key.char(c) });
    const with_bar = try screenText(&app);
    defer t.allocator.free(with_bar);
    // The find bar docks inside the pane, so the rail takes the cell
    // its label used to be padded with: ` Find ` reads `▌Find `.
    try t.expect(std.mem.indexOf(u8, with_bar, "▌Find ") != null);
    try t.expect(std.mem.indexOf(u8, with_bar, "alpha") != null);
    try t.expect(std.mem.indexOf(u8, with_bar, "match 1/2") != null);
    try t.expectEqual(@as(usize, 8), app.pane_rows);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try command.run(&app, .{ .static = .@"editor.goto_line" });
    const with_prompt = try screenText(&app);
    defer t.allocator.free(with_prompt);
    try t.expect(std.mem.indexOf(u8, with_prompt, "Go to line") != null);
    // The prompt's input row is an overlay hit, above the editor cells.
    var found = false;
    for (app.hits.items.items) |h| if (h.target == .overlay_item) {
        try t.expect(app.hits.at(h.rect.x, h.rect.y).? == .overlay_item);
        found = true;
    };
    try t.expect(found);
}

test "a toast's menu opens above the pointer, over the toast, and never on the statusline" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    app.toast("hello toast", .{});
    try app.render();
    // The toast's dismiss button sits in the bottom-right corner.
    var toast_rect: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .button and h.target.button == toast_mod.button_base) {
        toast_rect = h.rect;
    };
    const tr = toast_rect.?;
    try t.expect(tr.bottom() > 30);
    try app.handle(.{ .mouse = .{ .x = tr.x + 4, .y = tr.y + 1, .kind = .press, .button = .right } });
    try app.handle(.{ .mouse = .{ .x = tr.x + 4, .y = tr.y + 1, .kind = .release, .button = .right } });
    try t.expect(app.overlay == .menu);
    const text = try screenText(&app);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "Copy text") != null);
    try t.expect(std.mem.indexOf(u8, text, "Dismiss all") != null);
    const fr = frameRects(Rect.init(0, 0, app.screen.width, app.screen.height), chrome(&app));
    var rows: usize = 0;
    for (app.hits.items.items) |h| if (h.target == .menu_item) {
        rows += 1;
        // Above the statusline, and the topmost layer: the cell resolves to the menu row.
        try t.expect(h.rect.bottom() <= fr.status.y);
        try t.expect(app.hits.at(h.rect.x, h.rect.y).? == .menu_item);
        // Flipped: the whole menu sits at or above the pointer's row.
        try t.expect(h.rect.y <= tr.y + 1);
    };
    try t.expectEqual(@as(usize, 3), rows);
    // The statusline is intact under it.
    try t.expect(std.mem.indexOf(u8, text, "TREE") != null); // no pane: the tree's label
}

test "menuTop: below when it fits, flipped onto the pointer when it does not, clamped otherwise" {
    const screen = Rect.init(0, 0, 80, 30);
    try t.expectEqual(@as(u16, 10), menuTop(screen, 10, 6));
    try t.expectEqual(@as(u16, 24), menuTop(screen, 24, 6));
    try t.expectEqual(@as(u16, 20), menuTop(screen, 25, 6));
    try t.expectEqual(@as(u16, 24), menuTop(screen, 29, 6));
    // Too tall to flip: as low as the screen allows.
    try t.expectEqual(@as(u16, 0), menuTop(Rect.init(0, 0, 80, 5), 4, 6));
    try t.expectEqual(@as(u16, 2), menuTop(Rect.init(0, 0, 80, 8), 3, 6));
}

// ── ui toggles: the frame-level ones, one cell each ──

test "ui toggles: cluster mode picks the full or compact right cluster; the AI chips sit on the strip when their integrations are enabled" {
    // No PATH: nothing found, so only the icons decide here.
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("PATH", "");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 12, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    app.cfg.ui.tab_bar_ai_icon = .none;
    const wide = try screenText(&app);
    defer t.allocator.free(wide);
    try t.expect(std.mem.indexOf(u8, wide[0..std.mem.indexOfScalar(u8, wide, '\n').?], " TABS ") != null);
    app.cfg.ui.top_bar_cluster_mode = .compact;
    const compact = try screenText(&app);
    defer t.allocator.free(compact);
    try t.expect(std.mem.indexOf(u8, compact[0..std.mem.indexOfScalar(u8, compact, '\n').?], " TABS ") == null);
    // No AI chip while the icon is off, nor while the integrations are disabled.
    for (app.hits.items.items) |h| try t.expect(!(h.target == .button and h.target.button == @intFromEnum(Button.ai_claude)));
    app.cfg.ui.tab_bar_ai_icon = .both;
    try app.render();
    for (app.hits.items.items) |h| try t.expect(!(h.target == .button and h.target.button == @intFromEnum(Button.ai_claude)));
    app.cfg.ui.integration_icons = &.{ .{ .id = "claude_code", .enabled = true }, .{ .id = "codex", .enabled = true } };
    try app.render();
    var claude: ?Rect = null;
    var codex: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .button) {
        if (h.target.button == @intFromEnum(Button.ai_claude)) claude = h.rect;
        if (h.target.button == @intFromEnum(Button.ai_codex)) codex = h.rect;
    };
    try t.expect(claude != null and codex != null);
    // On the strip, left of the split buttons.
    try t.expect(claude.?.y == 1 and claude.?.right() <= codex.?.x);
    try t.expectEqual(@intFromEnum(Button.split_term), app.hits.at(codex.?.right() + 1, 1).?.button);
    // An enabled icon shows under any key but .none (the key only
    // decides which found-on-PATH CLIs show).
    app.cfg.ui.tab_bar_ai_icon = .codex;
    try app.render();
    try t.expect(hasButton(&app, .ai_claude) and hasButton(&app, .ai_codex));
    app.cfg.ui.tab_bar_ai_icon = .none;
    try app.render();
    try t.expect(!hasButton(&app, .ai_claude) and !hasButton(&app, .ai_codex));
}

fn hasButton(app: *App, b: Button) bool {
    for (app.hits.items.items) |h| if (h.target == .button and h.target.button == @intFromEnum(b)) return true;
    return false;
}

test "AI chips: a CLI on PATH shows its chip under the default config; the key names which found CLIs show and .none hides both; an enabled icon shows regardless" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("PATH", root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 12, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    // The shipped default: `.claude_code`, both icons disabled, nothing on PATH.
    try t.expectEqual(Config.TabBarAiIcon.claude_code, app.cfg.ui.tab_bar_ai_icon);
    try app.render();
    try t.expect(!hasButton(&app, .ai_claude) and !hasButton(&app, .ai_codex));
    // claude lands on PATH: its chip, and only its chip.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "claude", .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "codex", .data = "" });
    first_launch_install.forgetProbe(&app);
    try app.render();
    try t.expect(hasButton(&app, .ai_claude) and !hasButton(&app, .ai_codex));
    // The probe is cached for a while: the file going away is not seen at once…
    try tmp.dir.deleteFile(t.io, "claude");
    try app.render();
    try t.expect(hasButton(&app, .ai_claude));
    // …but is after the TTL.
    app.now_ms += first_launch_install.probe_ttl_ms;
    try app.render();
    try t.expect(!hasButton(&app, .ai_claude));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "claude", .data = "" });
    first_launch_install.forgetProbe(&app);
    // `.both` lets the found codex through; `.codex` hides the found claude; `.none` hides both.
    app.cfg.ui.tab_bar_ai_icon = .both;
    try app.render();
    try t.expect(hasButton(&app, .ai_claude) and hasButton(&app, .ai_codex));
    app.cfg.ui.tab_bar_ai_icon = .codex;
    try app.render();
    try t.expect(!hasButton(&app, .ai_claude) and hasButton(&app, .ai_codex));
    app.cfg.ui.tab_bar_ai_icon = .none;
    try app.render();
    try t.expect(!hasButton(&app, .ai_claude) and !hasButton(&app, .ai_codex));
    // An enabled icon shows without the CLI, whatever the key names (not .none).
    try tmp.dir.deleteFile(t.io, "claude");
    try tmp.dir.deleteFile(t.io, "codex");
    first_launch_install.forgetProbe(&app);
    app.cfg.ui.tab_bar_ai_icon = .claude_code;
    app.cfg.ui.integration_icons = &.{.{ .id = "codex", .enabled = true }};
    try app.render();
    try t.expect(!hasButton(&app, .ai_claude) and hasButton(&app, .ai_codex));
    // The marks are mnml's baked pair, whatever the deprecated flag says.
    var f: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .button and h.target.button == @intFromEnum(Button.ai_codex)) {
        f = h.rect;
    };
    app.cfg.ui.ai_chip_use_mnml_glyphs = true;
    try app.render();
    var glyph_a: []const u8 = "";
    var x: u16 = f.?.x;
    while (x < f.?.right()) : (x += 1) if (app.screen.readCell(x, f.?.y)) |c| if (c.char.grapheme.len > 1) {
        glyph_a = c.char.grapheme;
    };
    try t.expectEqualStrings("\u{F1E01}", glyph_a);
    app.cfg.ui.ai_chip_use_mnml_glyphs = false;
    try app.render();
    var glyph_b: []const u8 = "";
    x = f.?.x;
    while (x < f.?.right()) : (x += 1) if (app.screen.readCell(x, f.?.y)) |c| if (c.char.grapheme.len > 1) {
        glyph_b = c.char.grapheme;
    };
    try t.expectEqualStrings("\u{F1E01}", glyph_b);
}

test "ui toggles: the breadcrumb row under the strip follows editor.breadcrumb" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp/ws", .cols = 80, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.activeEditor().?.buf.setPath("/tmp/ws/src/app/render.zig");
    app.cfg.editor.breadcrumb = true;
    const on = try screenText(&app);
    defer t.allocator.free(on);
    try t.expect(std.mem.indexOf(u8, on, "src › app › render.zig") != null);
    app.cfg.editor.breadcrumb = false;
    const off = try screenText(&app);
    defer t.allocator.free(off);
    try t.expect(std.mem.indexOf(u8, off, "src › app › render.zig") == null);
}

test "ui toggles: expand_indicator and workspace dots change the tree rail" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    try tmp.dir.createDirPath(t.io, "sub");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sub/a.txt", .data = "x" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n], .cols = 60, .rows = 10 });
    defer app.deinit();
    // A narrow screen with the column docked: this test is about
    // what sits beside it, not the width rule (`ui.sidebar_auto_below`).
    app.cfg.ui.sidebar_auto_below = 0;
    app.cfg.ui.show_workspace_dots = true;
    const chev = try screenText(&app);
    defer t.allocator.free(chev);
    try t.expect(std.mem.indexOf(u8, chev, "\u{f47c} \u{f07c} sub") != null);
    try t.expect(std.mem.indexOf(u8, chev, "●") != null);
    app.cfg.ui.expand_indicator = .triangle;
    app.cfg.ui.show_workspace_dots = false;
    const tri = try screenText(&app);
    defer t.allocator.free(tri);
    try t.expect(std.mem.indexOf(u8, tri, "▾ \u{f07c} sub") != null);
    try t.expect(std.mem.indexOf(u8, tri, "●") == null);
    // the toggle runners flip the fields
    try command.run(&app, .{ .static = .@"view.toggle_workspace_dots" });
    try t.expect(app.cfg.ui.show_workspace_dots);
    try command.run(&app, .{ .static = .@"view.toggle_relative_numbers" });
    try t.expect(app.cfg.ui.relative_line_numbers);
    try command.run(&app, .{ .static = .@"view.toggle_color_column" });
    try t.expectEqual(@as(u16, 80), app.cfg.ui.color_column);
}

test "the chrome row is the Rust dump's, cell for cell, at 120 and 80 columns; every element is a hit; the strip carries the + and the split buttons; ASCII twins" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(t.io, "ws", .default_dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const ws = try std.fmt.allocPrint(t.allocator, "{s}/ws", .{buf[0..n]});
    defer t.allocator.free(ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .cols = 120, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    // The author's config: the compact cluster.
    app.cfg.ui.top_bar_cluster_mode = .compact;
    const wide = try screenText(&app);
    defer t.allocator.free(wide);
    const row0 = wide[0..std.mem.indexOfScalar(u8, wide, '\n').?];
    const gap = " " ** 25;
    try t.expectEqualStrings(ui_menu_bar.rust_row_120 ++ "  \u{EB01}" ++ gap ++ "\u{F0415}  \u{25CF}\u{2501}  \u{F0156}", std.mem.trimEnd(u8, row0, " "));
    // Every element registers: the words, the », the nav cluster, the
    // chip, the globe, the right cluster.
    try t.expectEqual(menu_bar.button_base, app.hits.at(5, 0).?.button);
    try t.expectEqual(menu_bar.button_base + 1, app.hits.at(12, 0).?.button);
    try t.expectEqual(menu_bar.overflow_button, app.hits.at(23, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.toggle_tree), app.hits.at(37, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.back), app.hits.at(40, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.forward), app.hits.at(43, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.palette), app.hits.at(48, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.dropdown), app.hits.at(78, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.toggle_right_panel), app.hits.at(82, 0).?.button);
    try t.expectEqual(integrations_view.chip_base, app.hits.at(85, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.new_tab_page), app.hits.at(111, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.theme_toggle), app.hits.at(114, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.window_close), app.hits.at(118, 0).?.button);
    // Row 1: the strip's + at 32 with the sidebar, at 1 without; the
    // split buttons at the right end.
    const row1 = wide[row0.len + 1 ..];
    try t.expect(std.mem.startsWith(u8, row1, " \u{F0415}"));
    try t.expect(std.mem.indexOf(u8, row1[0..std.mem.indexOfScalar(u8, row1, '\n').?], "\u{F2000}  \u{EB56}  \u{EB57}") != null);
    try t.expectEqual(Button.newTab(0), app.hits.at(1, 1).?.button);
    // The empty layout's cluster is Rust's three buttons — the
    // maximize one joins once a pane is open (`rust-120x40.txt` row 1
    // ends `  ` at columns 111 / 114 / 117).
    try t.expectEqual(@intFromEnum(Button.split_term), app.hits.at(111, 1).?.button);
    try t.expectEqual(@intFromEnum(Button.split_right), app.hits.at(114, 1).?.button);
    try t.expectEqual(@intFromEnum(Button.split_down), app.hits.at(117, 1).?.button);
    try t.expect(app.hits.at(110, 1) == null or app.hits.at(110, 1).?.button != @intFromEnum(Button.split_max));
    app.tree.visible = true;
    try app.render();
    try t.expectEqual(Button.newTab(0), app.hits.at(32, 1).?.button);
    app.tree.visible = false;
    // The full cluster (`auto` at 120 columns): + TABS 1 × ●━ ×.
    app.cfg.ui.top_bar_cluster_mode = .auto;
    const full = try screenText(&app);
    defer t.allocator.free(full);
    try t.expect(std.mem.indexOf(u8, full[0..std.mem.indexOfScalar(u8, full, '\n').?], "\u{F0415}  TABS  1 \u{F0156}  \u{25CF}\u{2501}  \u{F0156}") != null);
    try t.expectEqual(@intFromEnum(Button.tabs_label), app.hits.at(104, 0).?.button);
    try t.expectEqual(Button.tabPage(0), app.hits.at(109, 0).?.button);
    try t.expectEqual(Button.tabPageClose(0), app.hits.at(111, 0).?.button);
    // 80 columns: the brand and the » alone, no globe, the compact cluster.
    app.cfg.ui.top_bar_cluster_mode = .compact;
    try app.resize(80, 12);
    const narrow = try screenText(&app);
    defer t.allocator.free(narrow);
    const nrow = narrow[0..std.mem.indexOfScalar(u8, narrow, '\n').?];
    try t.expectEqualStrings(ui_menu_bar.rust_row_80 ++ "        \u{F0415}  \u{25CF}\u{2501}  \u{F0156}", std.mem.trimEnd(u8, nrow, " "));
    try t.expectEqual(menu_bar.overflow_button, app.hits.at(11, 0).?.button);
    try t.expect(app.hits.at(65, 0) == null);
    // Below the cluster's 48 cells only the chip paints, centred.
    try app.resize(44, 12);
    const tiny = try screenText(&app);
    defer t.allocator.free(tiny);
    const trow = tiny[0..std.mem.indexOfScalar(u8, tiny, '\n').?];
    try t.expect(std.mem.indexOf(u8, trow, "\u{F0349}  ws") != null);
    try t.expect(std.mem.indexOf(u8, trow, "\u{EA9B}") == null);
    try t.expectEqual(@intFromEnum(Button.palette), app.hits.at(12, 0).?.button);
    // ASCII twins.
    try app.resize(120, 12);
    app.cfg.ui.ascii_icons = true;
    const ascii = try screenText(&app);
    defer t.allocator.free(ascii);
    const arow = ascii[0..std.mem.indexOfScalar(u8, ascii, '\n').?];
    try t.expect(std.mem.indexOf(u8, arow, "|  <  >    ?  ws") != null);
    try t.expect(std.mem.indexOf(u8, arow, "+  \u{25CF}\u{2501}  x") != null);
}

test "ui.click_echo: a left press underlines the word under it for 120 ms; off, nothing" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("hello world\n");
    try app.render();
    // The text row is under the bar and the strip; the gutter is 5 cells.
    const y: u16 = 2;
    const x: u16 = 7; // inside "hello"
    try t.expect(app.hits.at(x, y).? == .editor_cell);
    app.cfg.ui.click_echo = false;
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .press, .button = .left } });
    try t.expect(app.click_echo == null);
    try app.render();
    try t.expect(app.screen.readCell(x, y).?.style.ul_style != .double);
    app.cfg.ui.click_echo = true;
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .press, .button = .left } });
    try t.expect(app.click_echo != null);
    try t.expectEqual(@as(usize, 0), app.click_echo.?.start);
    try t.expectEqual(@as(usize, 5), app.click_echo.?.end);
    try app.render();
    try t.expect(app.screen.readCell(x, y).?.style.ul_style == .double);
    try t.expect(app.screen.readCell(12, y).?.style.ul_style != .double); // "world" is not echoed
    try t.expectEqual(app.click_echo.?.until_ms, app.nextDeadlineMs().?);
    // 120 ms later the echo is gone.
    try app.tick(app.now_ms + app_mod.click_echo_ms + 1);
    try t.expect(app.click_echo == null);
    try app.render();
    try t.expect(app.screen.readCell(x, y).?.style.ul_style != .double);
}

// ── the one cursor ──

test "the frame puts exactly one cursor on the focused editor's caret, in the mode's shape" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.editor.setText("hello\nworld");
    e.buf.editor.placeCursor(1, 2);
    try app.render();
    // Where: the caret, gutter and all. One cursor, and it is this one.
    try t.expect(app.cursor_out != null);
    try t.expectEqual(app.cursor_pos.?.x, app.cursor_out.?.pos.x);
    try t.expectEqual(app.cursor_pos.?.y, app.cursor_out.?.pos.y);
    try t.expect(app.screen.cursor_vis);
    try t.expectEqual(app.cursor_pos.?.x, app.screen.cursor.col);
    try t.expectEqual(app.cursor_pos.?.y, app.screen.cursor.row);
    // Standard (modeless) editing: a bar, always.
    try t.expectEqual(cursor_mod.Shape.bar, app.cursor_out.?.shape);
    try t.expect(app.screen.cursor_shape == .beam);
}

test "vim: NORMAL is a block, INSERT a bar, REPLACE an underline" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    try app.setInputStyle(.vim);
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("hello");
    try app.render();
    try t.expectEqual(cursor_mod.Shape.block, app.cursor_out.?.shape);
    try t.expect(app.screen.cursor_shape == .block);
    try app.handle(.{ .key = app_mod.Key.char('i') });
    try app.render();
    try t.expectEqual(cursor_mod.Shape.bar, app.cursor_out.?.shape);
    try t.expect(app.screen.cursor_shape == .beam);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try app.handle(.{ .key = app_mod.Key.char('R') });
    try app.render();
    try t.expectEqual(cursor_mod.Shape.underline, app.cursor_out.?.shape);
    try t.expect(app.screen.cursor_shape == .underline);
    // VISUAL keeps the block.
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try app.handle(.{ .key = app_mod.Key.char('v') });
    try app.render();
    try t.expectEqual(cursor_mod.Shape.block, app.cursor_out.?.shape);
}

test "editor.cursor_blink picks the blinking variant; ui.cursor_shape overrides the mode" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    try app.setInputStyle(.vim);
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("hello");
    app.cfg.editor.cursor_blink = true;
    try app.render();
    try t.expect(app.cursor_out.?.blink);
    try t.expect(app.screen.cursor_shape == .block_blink);
    app.cfg.ui.cursor_shape = .underline;
    try app.render();
    try t.expectEqual(cursor_mod.Shape.underline, app.cursor_out.?.shape);
    try t.expect(app.screen.cursor_shape == .underline_blink);
}

test "an overlay's field wins over the editor; a box that takes no typing hides the cursor; the tree has none" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 13 });
    defer app.deinit();
    // The tree docked at 60 columns, so it can keep the keys below
    // (the width rule would hide it and hand them to the editor).
    app.cfg.ui.sidebar_auto_below = 0;
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("alpha beta");
    try app.render();
    const on_editor = app.cursor_out.?.pos;

    // The prompt's input takes the typing, so it takes the cursor.
    try command.run(&app, .{ .static = .@"editor.goto_line" });
    try app.render();
    try t.expect(app.cursor_out != null);
    try t.expect(app.cursor_out.?.pos.x != on_editor.x or app.cursor_out.?.pos.y != on_editor.y);
    try t.expectEqual(cursor_mod.Shape.bar, app.cursor_out.?.shape);
    try t.expect(app.screen.cursor_vis);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });

    // The find bar is the same story, one row above the statusline.
    try command.run(&app, .{ .static = .@"find.find" });
    try app.render();
    try t.expect(app.cursor_out != null);
    try t.expect(app.cursor_out.?.pos.y != on_editor.y);
    try t.expectEqual(cursor_mod.Shape.bar, app.cursor_out.?.shape);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });

    // Help paints a box and takes no typing: nothing under it may keep
    // the cursor, or it would be drawn on top of the box.
    try command.run(&app, .{ .static = .@"view.help" });
    try app.render();
    try t.expect(app.cursor_out == null);
    try t.expect(!app.screen.cursor_vis);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });

    // The tree has its own highlighted row and no text field.
    app.tree.visible = true;
    app.focus = .tree;
    try app.render();
    try t.expect(app.cursor_out == null);
    try t.expect(!app.screen.cursor_vis);
}

test "paneFocused: the pane the keys go to, whatever its kind and whatever pane `.pane` names" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    // One pane of each kind that builds without a process or a disk: an
    // editor, an integration (mount) pane, the usage pane, a git panel
    // opened as a pane, a session's changes view.
    _ = try app.openScratch();
    const ed = app.active.?;
    const mount = try app.panes.add(.{ .mount = .{ .gpa = app.gpa, .mount = null, .label = try app.gpa.dupe(u8, "Bitbucket PRs"), .generation = 0 } });
    const usage = try app.panes.add(.{ .ai_usage = .{ .product = .claude } });
    const status = try app.panes.add(.{ .git_status = .{ .repo = 0 } });
    const changes = try app.panes.add(.{ .session_changes = .{ .session = ed, .token = 0, .title = try app.gpa.dupe(u8, "changes") } });
    const all = [_]PaneId{ ed, mount, usage, status, changes };
    for (all) |id| {
        app.showPane(id);
        for (all) |other| try t.expectEqual(other == id, paneFocused(&app, other));
    }
    // The keys go to the active pane even when `.pane` still names the
    // one an overlay was opened over — the integration pane with the
    // keys and the VIEW chip whose rail stepped back.
    app.showPane(mount);
    app.focus = .{ .pane = ed };
    try t.expect(paneFocused(&app, mount));
    try t.expect(!paneFocused(&app, ed));
    // A focus left on `.overlay` with no overlay up: the keys go on to
    // the active pane.
    app.focus = .overlay;
    try t.expect(paneFocused(&app, mount));
    // An overlay up has the keys: no pane does.
    try app.openMenu("m", try app.gpa.alloc(command.MenuItem, 0), 0, 0);
    for (all) |id| try t.expect(!paneFocused(&app, id));
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // The tree has them only while it is on screen.
    app.focus = .tree;
    try t.expect(paneFocused(&app, mount));
    app.tree.visible = true;
    for (all) |id| try t.expect(!paneFocused(&app, id));
    app.tree.visible = false;
    // The info view holding the keys (`help.focus`): no pane has them.
    app.focus = .info_view;
    for (all) |id| try t.expect(!paneFocused(&app, id));
    // No active pane: nobody.
    app.focus = .{ .pane = mount };
    app.active = null;
    for (all) |id| try t.expect(!paneFocused(&app, id));
}
