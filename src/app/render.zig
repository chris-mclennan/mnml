//! One frame. Row 0 is the palette bar (on a screen at least 80 wide),
//! the last two rows are the statusline and the `:` line, and between
//! them sit the sidebar — the activity bar down its left edge, a `│`,
//! then the tree — the split tree and the right panel. Every
//! leaf of the split tree carries its own tab strip on its first row —
//! a tab is dragged between leaves, so the strip belongs to the leaf,
//! not to the frame. Then the overlay and the toasts, in that order, so
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
const statusline = @import("../ui/statusline.zig");
const statusline_app = @import("statusline.zig");
const messages = @import("messages.zig");
const stress = @import("stress.zig");
const clock_mod = @import("clock.zig");
const coverage = @import("coverage.zig");
const menu_bar = @import("menu_bar.zig");
const bufferline = @import("../ui/bufferline.zig");
const prompt_mod = @import("../ui/prompt.zig");
const confirm_mod = @import("../ui/confirm.zig");
const picker_mod = @import("../ui/picker.zig");
const which_key = @import("../ui/which_key.zig");
const find_bar_mod = @import("../ui/find_bar.zig");
const toast_mod = @import("../ui/toast.zig");
const whichkey = @import("whichkey.zig");
const input = @import("../input/mod.zig");
const overlay_mod = @import("../ui/overlay.zig");
const Theme = @import("../ui/theme.zig");
const Style = vaxis.Style;
const menu_glyph = @import("../ui/menu_glyph.zig");
const discovery = @import("discovery.zig");
const image_pane = @import("image_pane.zig");
const command = @import("../core/command.zig");
const todos = @import("../todos.zig");
const notes = @import("../notes.zig");
const findings = @import("../findings.zig");
const sessions = @import("../sessions.zig");
const dock = @import("dock.zig");
const settings_app = @import("settings.zig");
const settings_ui = @import("../ui/settings.zig");
const first_launch = @import("first_launch.zig");
const flash = @import("flash.zig");
const wizard_ui = @import("../ui/wizard.zig");
const syntax = @import("syntax.zig");
const sticky = @import("sticky.zig");
const outline = @import("outline.zig");
const md_preview = @import("md_preview.zig");
const layout_mod = @import("layout.zig");
const cmd_view = @import("cmd_view.zig");
const cheatsheet = @import("cheatsheet.zig");
const script_pane = @import("script_pane.zig");
const pty_view = @import("../ui/pty_view.zig");
const pty_pane = @import("pty_pane.zig");
const git_app = @import("git.zig");
const ai_app = @import("ai.zig");
const agents = @import("agents.zig");
const spend = @import("spend.zig");
const ai_view = @import("../ui/ai_view.zig");
const agents_view = @import("../ui/agents_view.zig");
const spend_view = @import("../ui/spend_view.zig");
const ai_apply_view = @import("../ui/ai_apply_view.zig");
const ai_apply = @import("ai_apply.zig");
const tests_pane = @import("tests_pane.zig");
const tests_view = @import("../ui/tests_view.zig");
const flaky = @import("flaky.zig");
const flaky_view = @import("../ui/flaky_view.zig");
const grep_view = @import("../ui/grep_view.zig");
const dap = @import("dap.zig");
const lsp = @import("lsp.zig");
const request_pane = @import("request_pane.zig");
const http_app = @import("http.zig");
const decor = @import("lsp_decor.zig");
const semantic_app = @import("lsp_semantic.zig");
const http_panel = @import("http_panel.zig");
const ws_pane = @import("ws_pane.zig");
const browser_pane = @import("browser_pane.zig");
const mount_pane = @import("mount_pane.zig");
const integrations = @import("integrations.zig");
const marketplace = @import("marketplace.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const ipc = @import("../ipc/root.zig");
const files_pane = @import("files_pane.zig");
const transfers = @import("transfers.zig");
const activity_bar = @import("activity_bar.zig");
const rail_mod = @import("../ui/activity_bar.zig");

/// Below this width the palette bar row is not painted (Rust parity).
/// Below this the palette bar is not painted at all (a tiny screen).
pub const palette_bar_min_width: u16 = 40;
/// Below this the bar is narrow: the right cluster drops its extras
/// (the badges, the AI chips, the stress copy) and the palette chip is
/// the icon — the bar itself stays. Rust: "drops TABS rather than
/// vanishing entirely".
pub const palette_bar_narrow_width: u16 = 80;
/// The divider hit ids the split tree does not use (`.divider` is
/// otherwise an index into the split tree's dividers).
pub const tree_divider_id: u32 = std.math.maxInt(u32);
pub const right_divider_id: u32 = std.math.maxInt(u32) - 1;

/// `.button` ids the frame registers. `new_tab_base + leaf` is the `+`
/// on that leaf's strip; toasts own `toast.button_base` and up.
pub const Button = enum(u32) {
    palette = 1,
    toggle_tree = 2,
    toggle_right_panel = 3,
    /// `ui.tab_bar_ai_icon`: the brand chips in the bar's right cluster.
    ai_claude = 4,
    ai_codex = 5,
    /// The green ` + ` after the integration chips: the Marketplace.
    add_integration = 6,
    /// The stress meter's bufferline copy.
    stress = 7,
    /// The tab strip's `‹` / `›` overflow markers, one pair per leaf
    /// (`tabScroll`); leaves 0..63.
    tab_scroll_left_base = 0x80,
    tab_scroll_right_base = 0xC0,
    new_tab_base = 0x100,
    _,

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

/// The rows of the frame for a screen, and the columns of its sidebar.
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
    /// The sidebar's panel (the tree); empty when the sidebar is hidden.
    sidebar: Rect = Rect.empty,
    /// The one-cell resize divider on the sidebar's right (`tree_divider_id`).
    sidebar_divider: Rect = Rect.empty,
    /// What `upper` leaves for the panes, the right panel and the dock.
    body: Rect,
};

/// What `frameRects` is told about the sidebar — it reads no app.
pub const Chrome = struct {
    /// The sidebar's width when it is visible. Rust's `tree_width`: the
    /// rail and its border are carved from it, not added to it.
    sidebar: ?u16 = null,
    /// Whether the activity bar paints (`activity_bar.shown`).
    rail: bool = true,
};

/// The frame's `Chrome` for this app, this frame.
pub fn chrome(app: *const App) Chrome {
    return .{
        .sidebar = if (!app.zen and app.tree.visible) app.tree.width else null,
        .rail = activity_bar.shown(app),
    };
}

/// Palette bar on top when wide enough; the statusline and the `:`
/// line at the bottom; the rest in between. A tiny screen gives up the
/// `:` line, then the bar, before it gives up the statusline.
///
/// The sidebar takes its width (clamped so the panes keep 21 columns,
/// never under 8) plus a one-cell divider off the left of `upper`; the
/// rail takes its three cells off the sidebar's left, then a border
/// column when the sidebar has more than two cells to spare (Rust
/// `ui/mod.rs`). The tree's `│` divider therefore stays where it was
/// with or without the rail.
pub fn frameRects(full: Rect, ch: Chrome) FrameRects {
    var r = full;
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
    var fr: FrameRects = .{ .bar = bar, .upper = s.top, .status = s.rest, .cmdline = cmdline, .body = s.top };
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
    app.frame.begin();
    // The info box reads the previous frame's hits: they are what the
    // pointer is resting on until this frame replaces them.
    const help_tip: ?discovery.Tip = if (app.cfg.ui.hover_help and app.tree.visible) blk: {
        const tip = discovery.hoverTip(app, app.frame.allocator()) catch null;
        break :blk if (tip) |tp| .{ .title = try app.frame.allocator().dupe(u8, tp.title), .detail = if (tp.detail) |d| try app.frame.allocator().dupe(u8, d) else null } else null;
    } else null;
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
    };
    const full = ui.canvas.full();
    ui.canvas.fill(full, app.theme.bg);
    screen.cursor_vis = false;
    app.cursor_pos = null;

    // Zen: the panes fill everything above the `:` line — no bar, no
    // tree, no right panel, no strips, no statusline (`zen.zig`).
    try drawPaletteBar(app, ui, fr.bar);
    var panes_area = fr.body;
    if (!fr.sidebar.isEmpty()) {
        // ── rail ──
        // The activity bar down the sidebar's left edge, and the `│`
        // between it and the tree — `t.line` on the rail's ground, as
        // Rust paints it, so no panel fill butts against the icons.
        if (!fr.rail.isEmpty()) rail_mod.draw(ui, fr.rail, activity_bar.props(app));
        if (!fr.rail_border.isEmpty()) {
            const pal = app.theme.palette;
            const line = Theme.withFg(Theme.onBg(app.theme.border, pal.bg_darker), pal.line);
            ui.canvas.fill(fr.rail_border, line);
            var y: u16 = fr.rail_border.y;
            while (y < fr.rail_border.bottom()) : (y += 1) ui.canvas.put(fr.rail_border.x, y, .{ .char = .{ .grapheme = if (ui.ascii) "|" else "│", .width = 1 }, .style = line });
        }
        // ── sidebar ──
        // `ui.hover_help`: while the pointer rests on something with a
        // description, the panel's bottom rows are its info box.
        var side = fr.sidebar;
        if (help_tip) |tip| if (app.cfg.ui.hover_help and side.h > app.cfg.ui.hover_help_height + 4) {
            const parts = side.splitBottom(app.cfg.ui.hover_help_height);
            side = parts.top;
            discovery.drawHelpBox(ui, parts.rest, tip);
        };
        try app.tree.draw(app, ui, side);
        drawDivider(app, ui, fr.sidebar_divider, tree_divider_id);
    }
    // The right panel takes its width plus a divider off the far side.
    if (app.right_panel) |which| if (!app.zen and panes_area.w > 21 + 8) {
        const w: u16 = @max(@min(app.right_panel_width, panes_area.w -| 21), 8);
        const cols = panes_area.splitRight(w);
        const div = cols.left.splitRight(1);
        panes_area = div.left;
        drawDivider(app, ui, div.rest, right_divider_id);
        try drawRightPanel(app, ui, cols.rest, which);
    };
    // The dock's inline strips come off the body; its widgets paint
    // over whatever the panes drew.
    const dock_area = panes_area;
    if (!app.zen) panes_area = dock.bodyAfterStrips(dock_area, dock.strips(dock_area, app.dock.widgets.items, app.dock.hidden));
    app.panes_area = panes_area;
    try drawBody(app, ui, panes_area);
    if (!app.zen) try dock.draw(app, ui, dock_area);
    if (!app.zen) try drawStatusline(app, ui, fr.status);
    drawCmdline(app, ui, fr.cmdline);
    try drawOverlay(app, ui, panes_area);
    try lsp.drawPopups(app, ui, panes_area);
    // The Undo chip takes the toasts' spacer row; the stack sits above it.
    var toast_area = panes_area;
    if (app.undo_chip) |u| {
        toast_mod.drawUndo(ui, panes_area, u.label);
        toast_area.h -|= 1;
    }
    toast_mod.draw(ui, toast_area, try app.visibleToasts(arena));
    // A context menu is the topmost layer — over the toasts too, whose
    // own menu it is — and it stays above the statusline and the `:`
    // line, whatever it was anchored in.
    if (app.overlay == .menu) drawMenu(ui, Rect.init(full.x, full.y, full.w, fr.upper.bottom() -| full.y), &app.overlay.menu);
    try discovery.drawTooltip(app, ui, full);
}

/// `[≡]` toggles the tree, the centred chip opens the palette, `[▤]`
/// toggles the right panel — VS Code's title row, one line tall.
fn drawPaletteBar(app: *App, ui: Ui, bar: Rect) Allocator.Error!void {
    if (bar.isEmpty()) return;
    const th = ui.theme;
    const bg = th.bufferline;
    ui.fill(bar, bg);
    const y = bar.y;
    const btn = Theme.onBg(th.muted, bg.bg);
    // The sidebar toggles are a matched codicon pair — `layout-sidebar-
    // left-off` / `layout-sidebar-right-off` — with `=` / `#` as their
    // ASCII twins.
    const tree_glyph: []const u8 = if (ui.ascii) " " ++ tree_codicon_ascii ++ " " else " " ++ tree_codicon ++ " ";
    var w0 = ui.putStr(bar.x, y, bar.w, tree_glyph, if (app.tree.visible) Theme.onBg(th.accent, bg.bg) else btn);
    ui.hit(Rect.init(bar.x, y, w0, 1), .{ .button = @intFromEnum(Button.toggle_tree) });
    // The menu bar's words, after the sidebar toggle (`app/menu_bar.zig`).
    if (menu_bar.shown(app) and bar.w >= palette_bar_narrow_width) {
        var mx = bar.x + w0 + 1;
        app.menu_bar_x = mx;
        for (menu_bar.Menu.all) |m| {
            const word = ui.fmt(" {s} ", .{m.label()});
            const ww = ui.width(word);
            if (mx + ww > bar.x + bar.w / 3) break;
            const open = app.menu_bar_open == m;
            _ = ui.putStr(mx, y, ww, word, if (open) Theme.onBg(th.accent, bg.bg) else btn);
            ui.hit(Rect.init(mx, y, ww, 1), .{ .button = menu_bar.button_base + @as(u32, @intFromEnum(m)) });
            mx += ww;
        }
        w0 = mx - bar.x;
    }
    const right_glyph: []const u8 = if (ui.ascii) " " ++ right_panel_codicon_ascii ++ " " else " " ++ right_panel_codicon ++ " ";
    const rw = ui.width(right_glyph);
    const narrow = bar.w < palette_bar_narrow_width;
    var cluster_left = bar.right();
    if (bar.w > w0 + rw + 4) {
        const rx = ui.putStrRight(bar.right(), y, rw, right_glyph, if (app.right_panel != null) Theme.onBg(th.accent, bg.bg) else btn);
        ui.hit(Rect.init(rx, y, rw, 1), .{ .button = @intFromEnum(Button.toggle_right_panel) });
        cluster_left = rx;
    }
    if (!narrow and bar.w > w0 + rw + 4) {
        const rx = cluster_left;
        // The git badge: changed files in the active repo, Rust's
        // `set_activity_badge("git", n)` — a host's own `git` badge
        // replaces it. Then every other section's badge, summed, as
        // `•N` in the accent (`set-activity-badge` over IPC).
        var bx = rx;
        const host_git = app.ipc_fx.badge("git");
        const badge = if (host_git > 0) host_git else app.git.badge();
        if (badge > 0) {
            const label = ui.fmt("{d}", .{badge});
            const bw = ui.width(label);
            if (bx > w0 + bw + 2) bx = ui.putStrRight(bx, y, bw, label, Theme.onBg(th.warn_fg, bg.bg));
        }
        const others = app.ipc_fx.badgeTotal("git");
        if (others > 0) {
            const label = ui.fmt("{s}{d} ", .{ @as([]const u8, if (ui.ascii) "*" else "•"), others });
            const bw = ui.width(label);
            if (bx > w0 + bw + 2) bx = ui.putStrRight(bx, y, bw, label, Theme.onBg(th.accent, bg.bg));
        }
        cluster_left = bx;
        // `ui.tab_bar_ai_icon`: the brand chips, a click opens the session.
        const ai = app.cfg.ui.tab_bar_ai_icon;
        if (ai == .codex or ai == .both) cluster_left = drawAiChip(app, ui, cluster_left, y, .codex);
        if (ai == .claude_code or ai == .both) cluster_left = drawAiChip(app, ui, cluster_left, y, .claude);
        // The stress meter's copy in the cluster: the same four blocks
        // and p95 as the statusline's, hidden when idle.
        if (try stress.segment(app, ui.arena, ui.ascii)) |txt| {
            const sw = ui.width(txt) + 2;
            if (cluster_left > w0 + sw + 2) {
                const sx = ui.putStrRight(cluster_left, y, sw, ui.fmt(" {s} ", .{txt}), Theme.onBg(th.warn_fg, bg.bg));
                ui.hit(Rect.init(sx, y, sw, 1), .{ .button = @intFromEnum(Button.stress) });
                cluster_left = sx;
            }
        }
    }
    // `ui.top_bar_cluster_mode`: the palette chip's label — the full
    // hint, or the icon alone; `auto` keeps the hint on a wide bar. A
    // narrow bar is always the icon.
    const compact = narrow or switch (app.cfg.ui.top_bar_cluster_mode) {
        .compact => true,
        .expanded => false,
        .auto => bar.w < 100,
    };
    const label: []const u8 = if (compact) (if (ui.ascii) " > " else " ⌘ ") else (if (ui.ascii) "  search files - run commands  " else "  search files · run commands  ");
    const lw = @min(ui.width(label), bar.w -| (w0 + (bar.right() - cluster_left) + 2));
    var chip_right = cluster_left -| 1;
    const min_chip: u16 = if (compact) 3 else 8;
    if (lw >= min_chip) {
        const x = bar.x + (bar.w - lw) / 2;
        const chip = Rect.init(x, y, lw, 1);
        ui.fill(chip, th.chip);
        _ = ui.putStr(x, y, lw, ui.clipStr(label, lw), Theme.onBg(th.muted, th.chip.bg));
        ui.hit(chip, .{ .button = @intFromEnum(Button.palette) });
        // The add-integration ` + ` (the Marketplace) sits at the right
        // end of the chip strip, then the integration chips between it
        // and the palette chip; whatever does not fit is dropped whole.
        const plus: []const u8 = if (ui.ascii) " " ++ add_codicon_ascii ++ " " else " " ++ add_codicon ++ " ";
        const pw = ui.width(plus);
        if (chip_right > x + lw + pw + 1) {
            const px = ui.putStrRight(chip_right, y, pw, plus, .{ .fg = th.palette.green, .bg = bg.bg, .bold = true });
            ui.hit(Rect.init(px, y, pw, 1), .{ .button = @intFromEnum(Button.add_integration) });
            chip_right = px -| 1;
        }
        const strip = try integrations.chips(app, ui.arena);
        const props = try ui.arena.alloc(integrations_view.ChipProps, @min(strip.len, integrations_view.max_chips));
        for (props, 0..) |*cp, i| cp.* = .{ .glyph = strip[i].glyph, .fallback = strip[i].fallback, .color = strip[i].color, .enabled = strip[i].enabled };
        chip_right = integrations_view.drawChips(ui, chip_right, y, x + lw + 1, bg, props);
    }
}

/// codicon `layout-sidebar-left-off` / `layout-sidebar-right-off` / `add`,
/// each with the one-char twin `--ascii` paints (the glyph audit pairs
/// `<x>_codicon` with `<x>_codicon_ascii`).
pub const tree_codicon = "\u{ec02}";
pub const tree_codicon_ascii = "=";
pub const right_panel_codicon = "\u{ec00}";
pub const right_panel_codicon_ascii = "#";
pub const add_codicon = "\u{ea7c}";
pub const add_codicon_ascii = "+";

pub const AiBrand = enum { claude, codex };

/// Claude's asterisk / Codex's prompt glyph (the `default_integration_icons`
/// fallbacks under `--ascii`), lit when a session is running. Returns
/// the x it started at.
fn drawAiChip(app: *App, ui: Ui, right_x: u16, y: u16, brand: AiBrand) u16 {
    const th = ui.theme;
    const bg = th.bufferline;
    const glyph: []const u8 = switch (brand) {
        .claude => if (ui.ascii) " * " else " \u{2733} ",
        .codex => if (ui.ascii) " > " else " \u{276F}_ ",
    };
    const live = ai_app.findSession(app, if (brand == .claude) .claude else .codex) != null;
    const style = if (live) Theme.onBg(th.accent, bg.bg) else Theme.onBg(th.muted, bg.bg);
    const w = ui.width(glyph);
    if (right_x < w + 4) return right_x;
    const x = ui.putStrRight(right_x, y, w, glyph, style);
    ui.hit(Rect.init(x, y, w, 1), .{ .button = @intFromEnum(if (brand == .claude) Button.ai_claude else Button.ai_codex) });
    return x;
}

fn drawDivider(app: *App, ui: Ui, r: Rect, id: u32) void {
    const dragging = if (app.drag) |d| switch (d) {
        .tree_divider => id == tree_divider_id,
        .right_divider => id == right_divider_id,
        else => false,
    } else false;
    const style = if (dragging or ui.hovered(r)) app.theme.accent else app.theme.border;
    ui.canvas.fill(r, style);
    var y: u16 = r.y;
    while (y < r.bottom()) : (y += 1) ui.canvas.put(r.x, y, .{ .char = .{ .grapheme = if (ui.ascii) "|" else "│", .width = 1 }, .style = style });
    ui.hit(r, .{ .divider = id });
}

/// The panel in the right slot. Only TODOS draws today; the others
/// name themselves until their module lands.
fn drawRightPanel(app: *App, ui: Ui, area: Rect, which: app_mod.PanelId) Allocator.Error!void {
    switch (which) {
        .todos => try todos.draw(app, ui, area),
        .notes => try notes.draw(app, ui, area),
        .findings => try findings.draw(app, ui, area),
        .git => try git_app.draw(app, ui, area),
        .diagnostics => try lsp.drawPanel(app, ui, area),
        .http => try http_panel.draw(app, ui, area),
        .sessions => try sessions.draw(app, ui, area),
    }
}

/// The tabs of leaf `lid` for the strip. The strip lists documents,
/// not windows: a second window on a file already in the strip folds
/// into the first tab (which is active when either window is).
fn tabsOf(app: *App, ui: Ui, layout: *app_mod.Layout, lid: layout_mod.NodeId) Allocator.Error![]bufferline.Tab {
    var tabs: std.ArrayListUnmanaged(bufferline.Tab) = .empty;
    const leaf = layout.leaf(lid) orelse return tabs.items;
    for (leaf.tabs.items) |id| {
        const p = app.panes.get(id) orelse continue;
        const active = leaf.active == id;
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
        }
        try tabs.append(ui.arena, .{ .id = id, .title = p.title(), .dirty = p.dirty(), .active = active, .kind = if (p.* == .pty) .pty else .file, .pinned = p.pinned() });
    }
    return tabs.items;
}

/// The leaf's tab strip. The window (`Leaf.strip_first`) is re-fitted
/// to the active tab when that changed since the last paint, else it
/// stays where the wheel / markers left it; what was painted goes back
/// on the leaf so the wheel knows whether there is anything to scroll.
fn drawStrip(app: *App, ui: Ui, layout: *app_mod.Layout, lid: layout_mod.NodeId, li: usize, strip: Rect) void {
    const tabs = tabsOf(app, ui, layout, lid) catch return;
    var first: usize = 0;
    if (layout.leaf(lid)) |leaf| {
        if (leaf.strip_anchor == null or leaf.strip_anchor.? != leaf.active) {
            first = bufferline.fitActive(ui, strip, tabs, bufferline.plus_w);
            leaf.strip_anchor = leaf.active;
        } else first = leaf.strip_first;
    }
    const win = bufferline.draw(ui, strip, tabs, .{
        .leaf = @intCast(li),
        .new_tab = Button.newTab(li),
        .first = first,
        .scroll_left = Button.tabScroll(li, .left),
        .scroll_right = Button.tabScroll(li, .right),
    });
    if (layout.leaf(lid)) |leaf| {
        leaf.strip_first = win.first;
        leaf.strip_hidden_right = win.hidden_right;
    }
}

/// The markdown chip at the right end of the active leaf's strip:
/// `✏ Edit` on a preview, ` Preview` on a markdown editor. A click is
/// the command.
fn drawMdChip(app: *App, ui: Ui, area: Rect) u16 {
    const active = app.active orelse return 0;
    const pane = app.panes.get(active) orelse return 0;
    const label: []const u8, const button: u32 = switch (pane.*) {
        .md_preview => .{ if (ui.ascii) " Edit " else " ✏ Edit ", md_preview.button_edit },
        .editor => |*e| if (e.buf.doc.path != null and md_preview.isMarkdownPath(e.buf.doc.path.?)) .{ if (ui.ascii) " Preview " else "  Preview ", md_preview.button_preview } else return 0,
        .outline, .image, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .claude_agents, .spend_report, .grep, .debug, .dap_repl, .request, .websocket, .browser, .script, .mount, .integrations, .marketplace, .ai_apply, .tests, .flaky, .files => return 0,
    };
    const w = ui.width(label);
    if (area.w < w + 2) return 0;
    const r = Rect.init(area.right() - w, area.y, w, 1);
    ui.fill(r, app.theme.chip);
    _ = ui.putStr(r.x, r.y, w, label, app.theme.chip);
    ui.hit(r, .{ .button = button });
    return w;
}

/// `editor.breadcrumb`: the file's path as `dir › dir › name`, right-
/// aligned on the active leaf's strip after the tabs, before the
/// markdown chip. Painted only when the whole crumb fits past the tabs
/// — a clipped path reads as a different file.
fn drawBreadcrumb(app: *App, ui: Ui, pane: *app_mod.Pane, strip: Rect, reserved: u16) void {
    const path = switch (pane.*) {
        .editor => |*e| e.buf.doc.path orelse return,
        .md_preview => |*m| m.path,
        else => return,
    };
    const rel = app.relPath(path);
    const sep: []const u8 = if (ui.ascii) " > " else " › ";
    var crumb: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, rel, '/');
    var first = true;
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (!first) crumb.appendSlice(ui.arena, sep) catch return;
        crumb.appendSlice(ui.arena, part) catch return;
        first = false;
    }
    const text = ui.fmt(" {s} ", .{crumb.items});
    const w = ui.width(text);
    // The tabs' extent: the right edge of the last `.tab` / `+` hit on this row.
    var tabs_end: u16 = strip.x;
    for (app.hits.items.items) |h| {
        if (h.rect.y != strip.y or h.rect.x < strip.x or h.rect.right() > strip.right()) continue;
        if (h.target == .tab or (h.target == .button and render_button_is_new_tab(h.target.button))) tabs_end = @max(tabs_end, h.rect.right());
    }
    const right = strip.right() - reserved;
    if (right < tabs_end + w + 1) return;
    _ = ui.putStrRight(right, strip.y, w, text, Theme.onBg(app.theme.muted, app.theme.bufferline.bg));
}

fn render_button_is_new_tab(id: u32) bool {
    return Button.newTabLeaf(id) != null;
}

fn drawBody(app: *App, ui: Ui, body: Rect) Allocator.Error!void {
    const layout = app.layouts.current();
    if (layout.isEmpty()) {
        // An empty frame keeps the strip row so the `+` is where the
        // first tab will land.
        if (body.h >= 2) _ = bufferline.draw(ui, body.row(0), &.{}, .{ .leaf = 0, .new_tab = Button.newTab(0) });
        const msg = "mnml-zig — ctrl+p opens a file, ctrl+q quits";
        const w: u16 = @intCast(@min(std.unicode.utf8CountCodepoints(msg) catch msg.len, body.w));
        const r = Rect.init(body.x + (body.w -| w) / 2, body.y + body.h / 2, w, 1);
        _ = ui.canvas.text(r, &.{.{ .text = msg, .style = app.theme.muted }}, .{});
        return;
    }
    const rects = try layout.computeRects(body, ui.arena);
    for (rects.dividers, 0..) |d, i| {
        const dragging = if (app.drag) |dr| dr == .divider and dr.divider.split == d.split else false;
        const style = if (dragging or ui.hovered(d.rect)) app.theme.accent else app.theme.border;
        ui.canvas.fill(d.rect, style);
        const glyph: []const u8 = if (d.dir == .horizontal) (if (ui.ascii) "|" else "│") else (if (ui.ascii) "-" else "─");
        var y: u16 = d.rect.y;
        while (y < d.rect.bottom()) : (y += 1) {
            var x: u16 = d.rect.x;
            while (x < d.rect.right()) : (x += 1) ui.canvas.put(x, y, .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = style });
        }
        try ui.hits.add(ui.arena, d.rect, .{ .divider = @intCast(i) });
    }
    for (rects.panes, 0..) |pr, li| {
        const pane = app.panes.get(pr.pane) orelse continue;
        try ui.hits.add(ui.arena, pr.rect, .{ .pane = pr.pane });
        var rect = pr.rect;
        if (rect.h >= 2 and !app.zen) {
            const s = rect.splitTop(1);
            drawStrip(app, ui, layout, pr.leaf, li, s.top);
            if (app.active == pr.pane) {
                const md_w = drawMdChip(app, ui, s.top);
                if (app.cfg.editor.breadcrumb) drawBreadcrumb(app, ui, pane, s.top, md_w);
            }
            rect = s.rest;
        }
        switch (pane.*) {
            .editor => |*e| try drawEditor(app, ui, pr.pane, e, rect),
            .outline => |*o| {
                if (app.active == pr.pane) app.pane_rows = @max(rect.h, 1);
                try outline.draw(app, ui, pr.pane, o, rect);
            },
            .md_preview => |*m| try md_preview.draw(app, ui, pr.pane, m, rect),
            .cheatsheet => |*c| try cheatsheet.draw(app, c, ui, pr.pane, rect),
            .list => |*l| drawListPane(app, l, ui, pr.pane, rect),
            .pty => |*p| try drawPty(app, ui, pr.pane, p, rect),
            .git_status => |*s| try git_app.drawStatusPane(app, ui, pr.pane, s, rect),
            .diff => |*d| git_app.drawDiffPane(app, ui, pr.pane, d, rect),
            .git_graph => |*g| git_app.drawGraphPane(app, ui, pr.pane, g, rect),
            .ai => |*a| drawAi(app, ui, pr.pane, a, rect),
            .claude_agents => |*a| try drawAgents(app, ui, pr.pane, a, rect),
            .spend_report => |*s| {
                if (app.active == pr.pane) app.pane_rows = @max(rect.h, 1);
                spend_view.draw(ui, pr.pane, rect, s, app.active == pr.pane and app.focus == .pane);
            },
            .grep => |*g| {
                if (app.active == pr.pane) app.pane_rows = @max(rect.h, 1);
                grep_view.draw(ui, pr.pane, rect, g, app.active == pr.pane and app.focus == .pane);
            },
            .debug => |*d| try dap.drawDebug(app, ui, pr.pane, d, rect),
            .dap_repl => |*r| try dap.drawRepl(app, ui, pr.pane, r, rect),
            .request => |*rp| try request_pane.draw(app, ui, pr.pane, rp, rect),
            .websocket => |*w| try ws_pane.draw(app, ui, pr.pane, w, rect),
            .browser => |*b| try browser_pane.draw(app, ui, pr.pane, b, rect),
            .script => |*s| try script_pane.draw(app, ui, pr.pane, s, rect),
            .mount => |*mp| try mount_pane.draw(app, ui, pr.pane, mp, rect),
            .integrations => |*ip| try integrations.draw(app, ui, pr.pane, ip, rect),
            .marketplace => |*mk| try marketplace.draw(app, ui, pr.pane, mk, rect),
            .ai_apply => |*ap| drawAiApply(app, ui, pr.pane, ap, rect),
            .tests => |*tp| try drawTests(app, ui, pr.pane, tp, rect),
            .flaky => |*fp| {
                if (app.active == pr.pane) app.pane_rows = @max(rect.h, 1);
                flaky_view.draw(ui, pr.pane, rect, fp, app.active == pr.pane and app.focus == .pane);
            },
            .files => |*f| try files_pane.draw(app, ui, pr.pane, f, rect),
            .image => |*im| try image_pane.draw(app, ui, pr.pane, im, rect),
        }
        drawDropHint(app, ui, pr.pane, rect);
    }
}

/// While a tab or a tree file is being dragged over a pane, the zone
/// it would land in is tinted.
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
    const focused = app.active == id and app.focus == .pane;
    p.fit(rect.w, rect.h);
    try p.grid.update(app.gpa, p.session.terminal());
    const exit_label: ?[]const u8 = if (p.exit) |e| switch (e) {
        .code => |c| ui.fmt("[exited {d}] — any key closes", .{c}),
        .signal => |sg| ui.fmt("[killed by signal {d}] — any key closes", .{sg}),
    } else null;
    const cursor = pty_view.draw(ui, rect, &p.grid, .{ .focused = focused, .exit_label = exit_label });
    if (app.active == id) {
        app.pane_rows = @max(rect.h, 1);
        app.pane_cols = @max(rect.w, 1);
        if (focused) if (cursor) |c| {
            app.cursor_pos = .{ .x = c.x, .y = c.y };
        };
    }
}

/// The AI answer pane; the scroll is clamped to what overflowed.
fn drawAi(app: *App, ui: Ui, id: PaneId, a: *ai_app.AiPane, rect: Rect) void {
    const focused = app.active == id and app.focus == .pane;
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
        .focused = app.active == id and app.focus == .pane,
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
        .focused = app.active == id and app.focus == .pane,
        .wobbly = wobbly,
        .command = try tests_pane.cmdlineFor(ui.arena, p.last_args),
    });
}

/// The Claude Agents dashboard: rows in the pane's display order.
fn drawAgents(app: *App, ui: Ui, id: PaneId, a: *agents.AgentsPane, rect: Rect) Allocator.Error!void {
    if (app.active == id) app.pane_rows = @max(rect.h, 1);
    const rows = try ui.arena.alloc(agents.Row, a.visible.items.len);
    for (a.visible.items, 0..) |idx, i| rows[i] = a.rows[idx];
    const focused = app.active == id and app.focus == .pane;
    const caret = agents_view.draw(ui, id, rect, a, .{
        .rows = rows,
        .cursor = a.cursor,
        .focused = focused,
        .workspace = app.workspace,
        .now_s = @divFloor(app.now_ms, 1000),
    });
    if (focused) if (caret) |c| {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
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
    const hint = ui.fmt(" {s} {s} press a label to jump {s} Esc cancels ", .{ flash.pairText(f.a, f.b, &pair), if (ui.ascii) "->" else "→", if (ui.ascii) "-" else "·" });
    _ = ui.putStrRight(rect.right(), rect.bottom() - 1, rect.w, hint, ui.theme.current_match);
}

/// The gutter's marks, in priority order: the debugger's signs first (a
/// breakpoint, the ▶ of a stop), then a diagnostic's dot on the lines
/// they leave, then git's change bars — the view paints the first sign
/// and the first change mark it finds for a line (one column each; in
/// a one-cell gutter the sign wins).
fn gutterMarks(app: *App, arena: Allocator, e: *EditorPane, ascii: bool) Allocator.Error![]const editor_view.GutterMark {
    const d = try dap.marksFor(app, arena, e.buf.doc.path, &app.theme, ascii);
    const l = try lsp.marksFor(app, arena, e.buf.doc.path, &app.theme, ascii);
    const g: []const editor_view.GutterMark = if (e.buf.doc.path) |p| try git_app.viewMarks(app, p, arena) else &.{};
    if (l.len == 0 and g.len == 0) return d;
    if (d.len == 0 and g.len == 0) return l;
    if (d.len == 0 and l.len == 0) return g;
    return std.mem.concat(arena, editor_view.GutterMark, &.{ d, l, g });
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

fn drawEditor(app: *App, ui: Ui, id: PaneId, e: *EditorPane, rect_in: Rect) Allocator.Error!void {
    const arena = ui.arena;
    var rect = rect_in;
    // The find bar docks under the pane it belongs to.
    var bar: ?Rect = null;
    if (app.find_bar) |*fb| if (fb.pane == id and rect.h >= 2) {
        const rows: u16 = if (fb.state.show_replace) 2 else 1;
        const s = rect.splitBottom(rows);
        rect = s.top;
        bar = s.rest;
    };
    const focused = app.active == id and app.focus == .pane;
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
    // gate — or runs at once for a first parse or a lost log.
    if (e.syntax.dirty and e.syntax.since_ms == null) e.syntax.since_ms = app.now_ms;
    const lost = e.syntax.absorb(ed);
    const due = e.syntax.dirty and (lost or e.syntax.parsed_seq == null or app.now_ms - e.syntax.since_ms.? >= syntax.idle_ms);
    if (due) {
        try e.syntax.refresh(ed);
        e.syntax.dirty = false;
        e.syntax.since_ms = null;
    }
    ed.doc.edits.trim(e.syntax.seen_seq);
    // Spans for a window around the viewport and the cursor — the view
    // may scroll to the cursor inside `draw`, so both are covered.
    const line_count = ed.lineCount();
    const rows: usize = @max(rect.h, 1);
    const cur_line = ed.currentLine();
    const lo_line = @min(@min(e.view.scroll_line -| rows, cur_line -| rows), line_count - 1);
    const hi_line = @min(@max(e.view.scroll_line + 2 * rows, cur_line + rows), line_count - 1);
    // The server's decorations for the visible lines (idle-debounced),
    // and its semantic tokens laid over the grammar's spans.
    const first_vis: u32 = @intCast(@min(e.view.scroll_line, line_count - 1));
    const last_vis: u32 = @intCast(@min(e.view.scroll_line + rows, line_count) -| 1);
    try decor.onFrame(app, id, e, first_vis, last_vis);
    const base_spans = try e.syntax.styledSpans(arena, &app.theme, ed.lineStart(lo_line), ed.lineEnd(hi_line));
    const spans = try semantic_app.layer(app, arena, e, &app.theme, base_spans, lo_line, hi_line);
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
        .cursor = e.buf.editor.cursor,
        .anchor = e.buf.editor.anchor,
        .extra_cursors = e.buf.editor.extra_cursors.items,
        .folds = folds,
        .spans = spans,
        .matches = matches,
        .current_match = e.find.current,
        .wrap = e.wrap orelse app.cfg.ui.wrap,
        .tab_width = app.cfg.editor.tab_width,
        .line_numbers = app.cfg.ui.line_numbers,
        .cursor_shape = switch (mode) {
            .insert, .none => .bar,
            .replace => .underline,
            else => .block,
        },
        .focused = focused,
        .visual_block = mode == .visual_block,
        .block_eol = e.buf.editor.block_eol,
        .scrollbar = app.cfg.ui.scrollbar,
        .gutter_marks = try gutterMarks(app, arena, e, ui.ascii),
        .blame = (try git_app.blameLabels(app, id, arena)) orelse &.{},
        .underlines = try decor.mergeUnderlines(arena, try lsp.underlinesFor(app, arena, e, &app.theme), try decor.linkUnderlinesFor(app, arena, e, &app.theme)),
        .var_spans = try http_app.editorVarSpans(app, arena, e),
        .labels = labels,
        .echo = if (app.click_echo) |ce| (if (ce.pane == id and ce.until_ms > app.now_ms) editor_view.Range{ .start = ce.start, .end = ce.end } else null) else null,
        .virtual_text = try decor.virtualTextFor(app, arena, e, &app.theme, ui.ascii),
        .virtual_lines = try decor.virtualLinesFor(app, arena, e, &app.theme, ui.ascii),
        // ── ui toggles ──
        .relative_numbers = app.cfg.ui.relative_line_numbers,
        .cursor_line_band = app.cfg.ui.cursor_line,
        .show_whitespace = app.cfg.ui.show_whitespace,
        .highlight_trailing_ws = app.cfg.ui.highlight_trailing_ws,
        .bracket_rainbow = app.cfg.ui.bracket_rainbow,
        .word_matches = if (app.cfg.ui.highlight_word_under_cursor) try wordMatches(arena, ed, ed.lineStart(lo_line), ed.lineEnd(hi_line)) else &.{},
        .todo_keywords = app.cfg.ui.highlight_todo_keywords,
        .color_column = app.cfg.ui.color_column,
        .render_markdown = app.cfg.ui.render_markdown and e.buf.doc.path != null and md_preview.isMarkdownPath(e.buf.doc.path.?),
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
        if (focused) app.cursor_pos = cursor;
    }
    if (bar) |b| if (app.find_bar) |*fb| {
        if (find_bar_mod.draw(ui, b, &fb.state, .{ .current = e.find.current, .total = e.find.matches.items.len })) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

/// The cmdline-history / quickfix list: a header, then one row per
/// entry with the cursor row banded. Rows register `.script_hit`.
fn drawListPane(app: *App, l: *app_mod.ListPane, ui: Ui, pane: PaneId, area: Rect) void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    const header = switch (l.kind) {
        .cmdline_history => ui.fmt(" cmdline history · {d} entr{s} · enter re-runs · esc closes ", .{ l.entries.items.len, if (l.entries.items.len == 1) "y" else "ies" }),
        .quickfix => ui.fmt(" {d} match{s}   ·   quickfix: enter opens · esc closes ", .{ l.entries.items.len, if (l.entries.items.len == 1) "" else "es" }),
        // changed: a third list kind — the location list is the quickfix row layout under its own header.
        .location => ui.fmt(" {d} entr{s}   ·   location list: enter opens · :lnext / :lprev walk · esc closes ", .{ l.entries.items.len, if (l.entries.items.len == 1) "y" else "ies" }),
    };
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(header, area.w), Theme.onBg(th.accent, th.bg.bg));
    if (area.h < 2) return;
    const list = area.splitTop(1).rest;
    const rows: usize = list.h;
    if (l.cursor < l.scroll) l.scroll = l.cursor;
    if (l.cursor >= l.scroll + rows) l.scroll = l.cursor + 1 - rows;
    var y: u16 = 0;
    var i = l.scroll;
    while (i < l.entries.items.len and y < list.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = list.row(y);
        const e = l.entries.items[i];
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

/// The `:` line while it is open; blank otherwise (vim's cmdline row).
fn drawCmdline(app: *App, ui: Ui, area: Rect) void {
    if (area.isEmpty()) return;
    ui.fill(area, app.theme.bg);
    const e = app.activeEditor() orelse return;
    const line = e.buf.input.cmdlineGet() orelse return;
    const caret = @min(e.buf.input.cmdlineCaret() orelse line.len, line.len);
    // The caret is drawn (`▏`, as Rust's cmdline bar drew it — the
    // corpus reads `:▏wq`) and the terminal cursor sits on it.
    const shown = ui.fmt(":{s}{s}{s}", .{ line[0..caret], if (ui.ascii) "|" else "▏", line[caret..] });
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(shown, area.w), app.theme.fg);
    const cx: u16 = area.x + 1 + @as(u16, @intCast(@min(ui.width(line[0..caret]), area.w -| 1)));
    app.cursor_pos = .{ .x = cx, .y = area.y };
}

fn drawOverlay(app: *App, ui: Ui, body: Rect) Allocator.Error!void {
    switch (app.overlay) {
        .none => {},
        .prompt => |*p| if (prompt_mod.draw(ui, body, &p.state)) |c| {
            app.cursor_pos = .{ .x = c.x, .y = c.y };
        },
        .confirm => |*c| confirm_mod.draw(ui, body, &c.state),
        .picker => |*p| {
            const items = try ui.arena.alloc(picker_mod.Item, p.filtered.items.len);
            for (p.filtered.items, 0..) |idx, i| items[i] = .{
                .label = p.labels[idx],
                .detail = if (p.details.len > idx) p.details[idx] else null,
                .hint = if (p.hints.len > idx and p.hints[idx].len > 0) p.hints[idx] else null,
            };
            p.state.total = p.labels.len;
            if (picker_mod.draw(ui, body, &p.state, items)) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
        },
        .which_key => |*w| {
            const path = w.slice();
            const node = whichkey.lookup(path);
            const title: []const u8 = if (path.len == 0) "Leader" else if (node) |n| n.label() else "?";
            const kids = whichkey.continuations(path);
            const entries = try ui.arena.alloc(which_key.Entry, kids.len);
            for (kids, 0..) |k, i| {
                const key = try ui.arena.alloc(u8, 1);
                key[0] = k.key;
                entries[i] = .{ .key = key, .label = k.node.label(), .is_group = k.node == .group };
            }
            which_key.draw(ui, body, title, entries);
        },
        // A menu paints last of all, after the toasts (`render`).
        .menu => {},
        .settings => |*s| {
            const items = try settings_app.items(app, ui.arena);
            const sub = try settings_app.footer(app, ui.arena, items);
            // Centered on the screen, but the tab strip and the statusline
            // stay: the box never covers row 0 or the last row.
            const full = ui.canvas.full();
            settings_ui.draw(ui, Rect.init(full.x, full.y + 1, full.w, full.h -| 2), &s.ui, items, sub);
        },
        .wizard => |*w| {
            const full = ui.canvas.full();
            wizard_ui.draw(ui, Rect.init(full.x, full.y + 1, full.w, full.h -| 2), &w.ui, first_launch.model(app));
        },
        .info => |kind| switch (kind) {
            .discovery => discovery.drawOverlay(app, ui, ui.canvas.full()),
            else => cmd_view.drawInfo(app, ui, ui.canvas.full(), kind),
        },
    }
}

/// A context menu anchored at the click: below the pointer when it
/// fits, else above it (the frame's bottom row on the pointer's row),
/// and pulled inside `screen` either way. Every row registers `.menu_item{0, idx}`; a
/// separator paints a rule and registers nothing. A row with a submenu
/// ends in `▸`; the open child (`m.sub`) paints beside its parent row
/// with `.menu_item{1, idx}` hits. In a curatable menu the focused leaf
/// row ends in a kebab (`.menu_item{2, idx}` / `{3, idx}` in the child)
/// that opens the pin / hide / copy-id submenu.
fn drawMenu(ui: Ui, screen: Rect, m: *app_mod.MenuState) void {
    const size = menuSize(ui, m.title, m.items);
    const w: u16 = @min(size.w, screen.w);
    const h: u16 = @min(size.h, screen.h);
    const x = @min(m.x, (screen.x + screen.w) -| w);
    const y = menuTop(screen, m.y, h);
    const frame = Rect.init(x, y, w, h);
    const inner = overlay_mod.frame(ui, frame, m.title);
    if (inner.isEmpty()) return;
    const parent_row = paintMenuRows(ui, inner, m.items, m.cursor, 0, m.curatable and m.sub == null, m.sub != null);
    const sub = &(m.sub orelse return);
    // The child: beside the parent row, to the right when it fits.
    const child = menuSize(ui, null, sub.items);
    const cw: u16 = @min(child.w, screen.w);
    const ch: u16 = @min(child.h, screen.h);
    const anchor_y = inner.y + (parent_row.get(sub.parent) orelse 0);
    const cx: u16 = if (frame.right() + cw <= screen.right()) frame.right() else frame.x -| cw;
    const cy = @min(anchor_y -| 1, (screen.y + screen.h) -| ch);
    const crect = Rect.init(cx, cy, cw, ch);
    const cinner = overlay_mod.frame(ui, crect, null);
    sub.rect = crect;
    if (cinner.isEmpty()) return;
    _ = paintMenuRows(ui, cinner, sub.items, sub.cursor, 1, m.curatable, false);
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

/// Frame + ✓ column + glyph column + label + marker column.
fn menuSize(ui: Ui, title: ?[]const u8, items: []const command.MenuItem) MenuSize {
    var widest: u16 = if (title) |tt| ui.width(tt) + 2 else 4;
    var rows: u16 = 0;
    for (items) |it| {
        widest = @max(widest, ui.width(it.label));
        rows += 1;
        if (it.separator_before) rows += 1;
    }
    return .{ .w = widest + 2 + 2 + menu_glyph.width + 2 + 2, .h = rows + 2 };
}

/// Paints `items` into `inner`, registering `.menu_item{menu_id, i}`,
/// and returns each item's row offset (for anchoring a child). `kebab`
/// paints the curation kebab on the focused leaf row; `dim_cursor`
/// paints the cursor row without the highlight (a child is open).
fn paintMenuRows(ui: Ui, inner: Rect, items: []const command.MenuItem, cursor: usize, menu_id: u32, kebab: bool, dim_cursor: bool) std.AutoHashMapUnmanaged(usize, u16) {
    const th = ui.theme;
    var offsets: std.AutoHashMapUnmanaged(usize, u16) = .empty;
    var row: u16 = 0;
    for (items, 0..) |it, i| {
        if (it.separator_before and row < inner.h) {
            const r = inner.row(row);
            var xx: u16 = r.x;
            while (xx < r.right()) : (xx += 1) _ = ui.putStr(xx, r.y, 1, if (ui.ascii) "-" else "─", Theme.onBg(th.overlay_border, th.overlay_bg.bg));
            row += 1;
        }
        if (row >= inner.h) break;
        const r = inner.row(row);
        offsets.put(ui.arena, i, row) catch {};
        const selected = i == cursor;
        const style = if (selected and !dim_cursor) Theme.onBg(th.overlay_bg, th.cursor_line.bg) else th.overlay_bg;
        ui.fill(r, style);
        var xx = r.x + 1;
        xx += ui.putStr(xx, r.y, r.right() -| xx, if (it.checked) (if (ui.ascii) "* " else "✓ ") else "  ", Theme.withFg(style, th.accent.fg));
        _ = ui.putStr(xx, r.y, r.right() -| xx, menu_glyph.forItem(it, ui.ascii), Theme.withFg(style, th.muted.fg));
        xx += menu_glyph.width;
        const label_fg = if (it.action == .none and it.submenu.len == 0) th.muted.fg else th.fg.fg;
        _ = ui.putStr(xx, r.y, r.right() -| (xx + 2), ui.clipStr(it.label, r.right() -| (xx + 2)), Theme.withFg(style, label_fg));
        var kebab_x: ?u16 = null;
        if (it.submenu.len > 0) {
            _ = ui.putStrRight(r.right() -| 1, r.y, 1, if (ui.ascii) ">" else "▸", Theme.withFg(style, th.accent.fg));
        } else if (kebab and selected and it.action == .command) {
            kebab_x = ui.putStrRight(r.right() -| 1, r.y, 1, if (ui.ascii) ":" else "⋯", Theme.withFg(style, th.accent.fg));
        }
        // The row's hit stops where the kebab starts, and the kebab's
        // cells (the glyph and its margin) are registered after it, so
        // a click on the glyph opens the curation. Registering the
        // glyph cell first let the row's hit cover it and run the row.
        const row_w: u16 = if (kebab_x) |kx| kx -| r.x else r.w -| 1;
        ui.hit(Rect.init(r.x, r.y, row_w, 1), .{ .menu_item = .{ .menu = menu_id, .idx = @intCast(i) } });
        if (kebab_x) |kx| ui.hit(Rect.init(kx, r.y, r.right() -| kx, 1), .{ .menu_item = .{ .menu = menu_id + 2, .idx = @intCast(i) } });
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
    try t.expect(std.mem.indexOf(u8, empty, "mnml-zig") != null);
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
    // The `+` after the last tab, the mode chip on the statusline.
    try t.expectEqual(Button.newTab(0), app.hits.at(12, 1).?.button);
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
    try t.expectEqual(@intFromEnum(Button.palette), app.hits.at(60, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.toggle_tree), app.hits.at(1, 0).?.button);
    try t.expectEqual(@intFromEnum(Button.toggle_right_panel), app.hits.at(118, 0).?.button);
    try t.expectEqual(@as(u32, 0), app.hits.at(3, 1).?.tab.leaf);
    try t.expectEqual(@as(u32, 1), app.hits.at(64, 1).?.tab.leaf);
    try t.expect(app.hits.at(60, 10).? == .divider);
    try t.expect(app.hits.at(3, 2).? == .editor_cell);
    try t.expectEqual(@as(u32, 0), app.hits.at(3, 2).?.editor_cell.line);
    try t.expectEqual(statusline.seg_mode, app.hits.at(2, 38).?.statusline_seg);
    try t.expect(app.hits.at(60, 38) == null);
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
    try t.expect(std.mem.indexOf(u8, with_bar, " Find ") != null);
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

test "ui toggles: cluster mode shrinks the palette chip, the AI icon registers its button" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    app.cfg.ui.tab_bar_ai_icon = .none;
    const wide = try screenText(&app);
    defer t.allocator.free(wide);
    try t.expect(std.mem.indexOf(u8, wide, "search files · run commands") != null);
    app.cfg.ui.top_bar_cluster_mode = .compact;
    const compact = try screenText(&app);
    defer t.allocator.free(compact);
    try t.expect(std.mem.indexOf(u8, compact, "search files") == null);
    try t.expect(std.mem.indexOf(u8, compact, "⌘") != null);
    // no AI chip while the icon is off
    for (app.hits.items.items) |h| try t.expect(!(h.target == .button and h.target.button == @intFromEnum(Button.ai_claude)));
    app.cfg.ui.tab_bar_ai_icon = .both;
    try app.render();
    var claude: ?Rect = null;
    var codex: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .button) {
        if (h.target.button == @intFromEnum(Button.ai_claude)) claude = h.rect;
        if (h.target.button == @intFromEnum(Button.ai_codex)) codex = h.rect;
    };
    try t.expect(claude != null and codex != null);
    try t.expect(claude.?.y == 0 and claude.?.right() <= codex.?.x);
    app.cfg.ui.tab_bar_ai_icon = .codex;
    try app.render();
    for (app.hits.items.items) |h| try t.expect(!(h.target == .button and h.target.button == @intFromEnum(Button.ai_claude)));
}

test "ui toggles: the breadcrumb sits on the strip after the tabs and follows editor.breadcrumb" {
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
    app.cfg.ui.show_workspace_dots = true;
    const chev = try screenText(&app);
    defer t.allocator.free(chev);
    try t.expect(std.mem.indexOf(u8, chev, "\u{f47c} sub") != null);
    try t.expect(std.mem.indexOf(u8, chev, "●") != null);
    app.cfg.ui.expand_indicator = .triangle;
    app.cfg.ui.show_workspace_dots = false;
    const tri = try screenText(&app);
    defer t.allocator.free(tri);
    try t.expect(std.mem.indexOf(u8, tri, "▾ sub") != null);
    try t.expect(std.mem.indexOf(u8, tri, "●") == null);
    // the toggle runners flip the fields
    try command.run(&app, .{ .static = .@"view.toggle_workspace_dots" });
    try t.expect(app.cfg.ui.show_workspace_dots);
    try command.run(&app, .{ .static = .@"view.toggle_relative_numbers" });
    try t.expect(app.cfg.ui.relative_line_numbers);
    try command.run(&app, .{ .static = .@"view.toggle_color_column" });
    try t.expectEqual(@as(u16, 80), app.cfg.ui.color_column);
}

test "the palette bar: codicons with ASCII twins, the + chip opens the Marketplace, the cluster's extras drop below 80 columns, the stress copy" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    app.cfg.ui.tab_bar_ai_icon = .claude_code;
    const wide = try screenText(&app);
    defer t.allocator.free(wide);
    const row0 = wide[0..std.mem.indexOfScalar(u8, wide, '\n').?];
    try t.expect(std.mem.indexOf(u8, row0, tree_codicon) != null);
    try t.expect(std.mem.indexOf(u8, row0, right_panel_codicon) != null);
    try t.expect(std.mem.indexOf(u8, row0, add_codicon) != null);
    try t.expect(std.mem.indexOf(u8, row0, "search files") != null);
    var plus: ?u16 = null;
    var ai: ?u16 = null;
    var x: u16 = 0;
    while (x < 120) : (x += 1) {
        const h = app.hits.at(x, 0) orelse continue;
        if (h != .button) continue;
        if (h.button == @intFromEnum(Button.add_integration)) plus = x;
        if (h.button == @intFromEnum(Button.ai_claude)) ai = x;
    }
    try t.expect(plus != null and ai != null);
    // The stress copy joins the cluster once the meter has samples.
    app.cfg.ui.stress_meter = true;
    var i: usize = 0;
    while (i < 20) : (i += 1) app.stress.push(30_000);
    const stressed = try screenText(&app);
    defer t.allocator.free(stressed);
    const srow = stressed[0..std.mem.indexOfScalar(u8, stressed, '\n').?];
    try t.expect(std.mem.indexOf(u8, srow, "ms") != null);
    var stress_hit = false;
    x = 0;
    while (x < 120) : (x += 1) if (app.hits.at(x, 0)) |h| if (h == .button and h.button == @intFromEnum(Button.stress)) {
        stress_hit = true;
    };
    try t.expect(stress_hit);
    // The + chip routes to integrations.show_marketplace — proved by its
    // refusal when the marketplace is off (no fetch in a test). The chip
    // moved left when the stress copy joined the cluster: find it again.
    plus = null;
    x = 0;
    while (x < 120) : (x += 1) if (app.hits.at(x, 0)) |h| if (h == .button and h.button == @intFromEnum(Button.add_integration)) {
        plus = x;
    };
    app.cfg.marketplace.enabled = false;
    app.diag.clear();
    try app.handle(.{ .mouse = .{ .x = plus.?, .y = 0, .kind = .press, .button = .left } });
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "marketplace: disabled") != null);
    // Narrow: the bar stays, the palette chip is the icon, the AI chip and the + are gone.
    try app.resize(60, 12);
    const narrow = try screenText(&app);
    defer t.allocator.free(narrow);
    const nrow = narrow[0..std.mem.indexOfScalar(u8, narrow, '\n').?];
    try t.expect(std.mem.indexOf(u8, nrow, tree_codicon) != null);
    try t.expect(std.mem.indexOf(u8, nrow, right_panel_codicon) != null);
    try t.expect(std.mem.indexOf(u8, nrow, "search files") == null);
    try t.expect(std.mem.indexOf(u8, nrow, "⌘") != null);
    x = 0;
    while (x < 60) : (x += 1) if (app.hits.at(x, 0)) |h| if (h == .button) {
        try t.expect(h.button != @intFromEnum(Button.ai_claude));
        try t.expect(h.button != @intFromEnum(Button.stress));
    };
    // ASCII twins.
    app.cfg.ui.ascii_icons = true;
    const ascii = try screenText(&app);
    defer t.allocator.free(ascii);
    const arow = ascii[0..std.mem.indexOfScalar(u8, ascii, '\n').?];
    try t.expect(std.mem.indexOf(u8, arow, " = ") != null);
    try t.expect(std.mem.indexOf(u8, arow, " # ") != null);
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
