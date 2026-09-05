//! One frame. Row 0 is the palette bar (on a screen at least 80 wide),
//! the last two rows are the statusline and the `:` line, and between
//! them sit the tree rail, the split tree and the right panel. Every
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
const messages = @import("messages.zig");
const stress = @import("stress.zig");
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
const todos = @import("../todos.zig");
const settings_app = @import("settings.zig");
const settings_ui = @import("../ui/settings.zig");
const first_launch = @import("first_launch.zig");
const wizard_ui = @import("../ui/wizard.zig");
const syntax = @import("syntax.zig");
const sticky = @import("sticky.zig");
const outline = @import("outline.zig");
const md_preview = @import("md_preview.zig");
const layout_mod = @import("layout.zig");
const cmd_view = @import("cmd_view.zig");
const cheatsheet = @import("cheatsheet.zig");
const pty_view = @import("../ui/pty_view.zig");
const pty_pane = @import("pty_pane.zig");
const git_app = @import("git.zig");
const ai_app = @import("ai.zig");
const agents = @import("agents.zig");
const spend = @import("spend.zig");
const ai_view = @import("../ui/ai_view.zig");
const agents_view = @import("../ui/agents_view.zig");
const spend_view = @import("../ui/spend_view.zig");
const dap = @import("dap.zig");
const lsp = @import("lsp.zig");
const request_pane = @import("request_pane.zig");
const ws_pane = @import("ws_pane.zig");
const browser_pane = @import("browser_pane.zig");

/// Below this width the palette bar row is not painted (Rust parity).
pub const palette_bar_min_width: u16 = 80;
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
    new_tab_base = 0x100,
    _,

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

/// The rows of the frame for a screen.
pub const FrameRects = struct { bar: Rect, upper: Rect, status: Rect, cmdline: Rect };

/// Palette bar on top when wide enough; the statusline and the `:`
/// line at the bottom; the rest in between. A tiny screen gives up the
/// `:` line, then the bar, before it gives up the statusline.
pub fn frameRects(full: Rect) FrameRects {
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
    return .{ .bar = bar, .upper = s.top, .status = s.rest, .cmdline = cmdline };
}

/// Zen: only the `:` line is kept (a vim user leaves through it).
pub fn zenRects(full: Rect) FrameRects {
    if (full.h < 2) return .{ .bar = Rect.empty, .upper = full, .status = Rect.empty, .cmdline = Rect.empty };
    const s = full.splitBottom(1);
    return .{ .bar = Rect.empty, .upper = s.top, .status = Rect.empty, .cmdline = s.rest };
}

pub fn render(app: *App, screen: *vaxis.Screen) Allocator.Error!void {
    app.frame.begin();
    app.hits.reset();
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
    const fr = if (app.zen) zenRects(full) else frameRects(full);
    drawPaletteBar(app, ui, fr.bar);
    // The tree takes its width plus a one-cell divider (Rust `ui/mod.rs`).
    var panes_area = fr.upper;
    if (!app.zen and app.tree.visible and panes_area.w > 12) {
        const w: u16 = @max(@min(app.tree.width, panes_area.w -| 21), 8);
        const cols = panes_area.splitLeft(w);
        const div = cols.rest.splitLeft(1);
        try app.tree.draw(app, ui, cols.left);
        drawDivider(app, ui, div.left, tree_divider_id);
        panes_area = div.rest;
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
    app.panes_area = panes_area;
    try drawBody(app, ui, panes_area);
    if (!app.zen) try drawStatusline(app, ui, fr.status);
    drawCmdline(app, ui, fr.cmdline);
    try drawOverlay(app, ui, panes_area);
    try lsp.drawPopups(app, ui, panes_area);
    toast_mod.draw(ui, panes_area, try app.visibleToasts(arena));
}

/// `[≡]` toggles the tree, the centred chip opens the palette, `[▤]`
/// toggles the right panel — VS Code's title row, one line tall.
fn drawPaletteBar(app: *App, ui: Ui, bar: Rect) void {
    if (bar.isEmpty()) return;
    const th = ui.theme;
    const bg = th.bufferline;
    ui.fill(bar, bg);
    const y = bar.y;
    const btn = Theme.onBg(th.muted, bg.bg);
    const tree_glyph: []const u8 = if (ui.ascii) " = " else " ≡ ";
    const w0 = ui.putStr(bar.x, y, bar.w, tree_glyph, if (app.tree.visible) Theme.onBg(th.accent, bg.bg) else btn);
    ui.hit(Rect.init(bar.x, y, w0, 1), .{ .button = @intFromEnum(Button.toggle_tree) });
    const right_glyph: []const u8 = if (ui.ascii) " # " else " ▤ ";
    const rw = ui.width(right_glyph);
    if (bar.w > w0 + rw + 4) {
        const rx = ui.putStrRight(bar.right(), y, rw, right_glyph, if (app.right_panel != null) Theme.onBg(th.accent, bg.bg) else btn);
        ui.hit(Rect.init(rx, y, rw, 1), .{ .button = @intFromEnum(Button.toggle_right_panel) });
        // The git badge: changed files in the active repo, Rust's
        // `set_activity_badge("git", n)`.
        const badge = app.git.badge();
        if (badge > 0) {
            const label = ui.fmt("{d}", .{badge});
            const bw = ui.width(label);
            if (rx > w0 + bw + 2) _ = ui.putStrRight(rx, y, bw, label, Theme.onBg(th.warn_fg, bg.bg));
        }
    }
    const label: []const u8 = if (ui.ascii) "  search files - run commands  " else "  search files · run commands  ";
    const lw = @min(ui.width(label), bar.w -| (w0 + rw + 2));
    if (lw >= 8) {
        const x = bar.x + (bar.w - lw) / 2;
        const chip = Rect.init(x, y, lw, 1);
        ui.fill(chip, th.chip);
        _ = ui.putStr(x, y, lw, ui.clipStr(label, lw), Theme.onBg(th.muted, th.chip.bg));
        ui.hit(chip, .{ .button = @intFromEnum(Button.palette) });
    }
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
        .git => try git_app.draw(app, ui, area),
        .diagnostics => try lsp.drawPanel(app, ui, area),
        .notes, .findings, .sessions => {
            ui.fill(area, app.theme.panel_bg);
            const caps = ui.fmt(" {s}", .{@tagName(which)});
            const up = try ui.arena.dupe(u8, caps);
            for (up) |*c| c.* = std.ascii.toUpper(c.*);
            _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(up, area.w), Theme.onBg(app.theme.accent, app.theme.panel_bg.bg));
            if (area.h > 1) _ = ui.putStr(area.x, area.y + 1, area.w, ui.clipStr(" not in this build yet", area.w), Theme.onBg(app.theme.muted, app.theme.panel_bg.bg));
        },
    }
}

/// The tabs of leaf `lid` for the strip.
fn tabsOf(app: *App, ui: Ui, layout: *app_mod.Layout, lid: layout_mod.NodeId) Allocator.Error![]bufferline.Tab {
    var tabs: std.ArrayListUnmanaged(bufferline.Tab) = .empty;
    const leaf = layout.leaf(lid) orelse return tabs.items;
    for (leaf.tabs.items) |id| {
        const p = app.panes.get(id) orelse continue;
        try tabs.append(ui.arena, .{ .id = id, .title = p.title(), .dirty = p.dirty(), .active = leaf.active == id });
    }
    return tabs.items;
}

/// The markdown chip at the right end of the active leaf's strip:
/// `✏ Edit` on a preview, ` Preview` on a markdown editor. A click is
/// the command.
fn drawMdChip(app: *App, ui: Ui, area: Rect) void {
    const active = app.active orelse return;
    const pane = app.panes.get(active) orelse return;
    const label: []const u8, const button: u32 = switch (pane.*) {
        .md_preview => .{ if (ui.ascii) " Edit " else " ✏ Edit ", md_preview.button_edit },
        .editor => |*e| if (e.buf.path != null and md_preview.isMarkdownPath(e.buf.path.?)) .{ if (ui.ascii) " Preview " else "  Preview ", md_preview.button_preview } else return,
        .outline, .cheatsheet, .list, .pty, .git_status, .diff, .git_graph, .ai, .claude_agents, .spend_report, .debug, .dap_repl, .request, .websocket, .browser => return,
    };
    const w = ui.width(label);
    if (area.w < w + 2) return;
    const r = Rect.init(area.right() - w, area.y, w, 1);
    ui.fill(r, app.theme.chip);
    _ = ui.putStr(r.x, r.y, w, label, app.theme.chip);
    ui.hit(r, .{ .button = button });
}

fn drawBody(app: *App, ui: Ui, body: Rect) Allocator.Error!void {
    const layout = app.layouts.current();
    if (layout.isEmpty()) {
        // An empty frame keeps the strip row so the `+` is where the
        // first tab will land.
        if (body.h >= 2) bufferline.draw(ui, body.row(0), &.{}, .{ .leaf = 0, .new_tab = Button.newTab(0) });
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
            bufferline.draw(ui, s.top, try tabsOf(app, ui, layout, pr.leaf), .{ .leaf = @intCast(li), .new_tab = Button.newTab(li) });
            if (app.active == pr.pane) drawMdChip(app, ui, s.top);
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
            .debug => |*d| try dap.drawDebug(app, ui, pr.pane, d, rect),
            .dap_repl => |*r| try dap.drawRepl(app, ui, pr.pane, r, rect),
            .request => |*rp| try request_pane.draw(app, ui, pr.pane, rp, rect),
            .websocket => |*w| try ws_pane.draw(app, ui, pr.pane, w, rect),
            .browser => |*b| try browser_pane.draw(app, ui, pr.pane, b, rect),
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

/// The gutter's marks, in priority order: the debugger's signs first (a
/// breakpoint, the ▶ of a stop), then a diagnostic's dot on the lines
/// they leave, then git's change bars — the view paints the first sign
/// and the first change mark it finds for a line (one column each; in
/// a one-cell gutter the sign wins).
fn gutterMarks(app: *App, arena: Allocator, e: *EditorPane, ascii: bool) Allocator.Error![]const editor_view.GutterMark {
    const d = try dap.marksFor(app, arena, e.buf.path, &app.theme, ascii);
    const l = try lsp.marksFor(app, arena, e.buf.path, &app.theme, ascii);
    const g: []const editor_view.GutterMark = if (e.buf.path) |p| try git_app.viewMarks(app, p, arena) else &.{};
    if (l.len == 0 and g.len == 0) return d;
    if (d.len == 0 and g.len == 0) return l;
    if (d.len == 0 and l.len == 0) return g;
    return std.mem.concat(arena, editor_view.GutterMark, &.{ d, l, g });
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
    const ed = &e.buf.editor;
    // The language server hears every edit before the frame paints.
    lsp.syncPane(app, id, e);
    // Highlighting: every frame folds the edits since the last one into
    // the tree and slides the cached spans along, so what is painted
    // lines up with the text; the reparse itself waits for the idle
    // gate — or runs at once for a first parse or a lost log.
    if (e.hl_dirty and e.hl_since_ms == null) e.hl_since_ms = app.now_ms;
    const lost = e.syntax.absorb(ed);
    const due = e.hl_dirty and (lost or e.syntax.parsed_seq == null or app.now_ms - e.hl_since_ms.? >= syntax.idle_ms);
    if (due) {
        try e.syntax.refresh(ed);
        e.hl_dirty = false;
        e.hl_since_ms = null;
    }
    ed.edits.trim(e.syntax.seen_seq);
    // Spans for a window around the viewport and the cursor — the view
    // may scroll to the cursor inside `draw`, so both are covered.
    const line_count = ed.lineCount();
    const rows: usize = @max(rect.h, 1);
    const cur_line = ed.currentLine();
    const lo_line = @min(@min(e.view.scroll_line -| rows, cur_line -| rows), line_count - 1);
    const hi_line = @min(@max(e.view.scroll_line + 2 * rows, cur_line + rows), line_count - 1);
    const spans = try e.syntax.styledSpans(arena, &app.theme, ed.lineStart(lo_line), ed.lineEnd(hi_line));
    const folds = try arena.alloc(editor_view.Fold, e.buf.folds.count());
    for (e.buf.folds.keys(), e.buf.folds.values(), 0..) |s, en, i| folds[i] = .{ .first_line = @intCast(s), .last_line = @intCast(en) };
    const matches = try arena.alloc(editor_view.Range, e.find.matches.items.len);
    for (e.find.matches.items, 0..) |m, i| matches[i] = .{ .start = m.start, .end = m.end };
    const mode = e.buf.input.mode();
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
        .scrollbar = app.cfg.ui.scrollbar,
        .gutter_marks = try gutterMarks(app, arena, e, ui.ascii),
        .blame = (try git_app.blameLabels(app, id, arena)) orelse &.{},
        .underlines = try lsp.underlinesFor(app, arena, e, &app.theme),
    };
    const cursor = editor_view.draw(ui, id, rect, &e.view, doc);
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

fn drawStatusline(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    var info: statusline.Info = .{
        .mode_label = null,
        .mode_kind = .none,
        .file = null,
        .dirty = false,
        .line = 0,
        .col = 0,
        .total_lines = 0,
        .input_style = @tagName(app.input_style),
    };
    var lsp_seg: ?[]const u8 = null;
    if (app.activeEditor()) |e| {
        const ed = &e.buf.editor;
        const mode = e.buf.input.mode();
        info.mode_label = mode.label() orelse "EDIT";
        info.mode_kind = switch (mode) {
            .none => .edit,
            .normal => .normal,
            .insert => .insert,
            .replace => .replace,
            .visual, .visual_line, .visual_block => .visual,
        };
        info.file = if (e.buf.path) |p| app.relPath(p) else "[scratch]";
        info.dirty = e.buf.dirty;
        const pos = ed.rowCol();
        info.line = @intCast(pos.row + 1);
        info.col = @intCast(pos.col + 1);
        info.total_lines = @intCast(ed.lineCount());
        if (ed.selection()) |sel| if (sel[1] > sel[0]) {
            info.selection_chars = std.unicode.utf8CountCodepoints(ed.bytes()[sel[0]..sel[1]]) catch sel[1] - sel[0];
        };
        info.pending = try e.buf.input.pendingDisplay(ui.arena);
        if (e.buf.recording) |r| info.macro_recording = r.reg;
        lsp_seg = try lsp.statusSegment(app, ui.arena, e, ui.ascii);
    } else if (app.active) |id| if (app.panes.pty(id)) |p| {
        info.mode_label = if (p.exit == null) "TERM" else "EXITED";
        info.mode_kind = .edit;
        info.file = p.childTitle() orelse p.label;
        // The grid was refreshed by drawBody; its cursor is pane-relative.
        if (pty_pane.supported) if (p.grid.cursor()) |c| {
            info.line = c.y + 1;
            info.col = c.x + 1;
        };
        info.total_lines = p.rows;
    } else if (app.panes.get(id)) |p| if (p.asRequest()) |rp| {
        info.mode_label = if (rp.isSending()) "SENDING" else "HTTP";
        info.mode_kind = .edit;
        info.file = if (rp.source_path) |sp| app.relPath(sp) else rp.title();
        info.dirty = rp.edited;
    } else if (p.asWebsocket()) |w| {
        info.mode_label = "WS";
        info.mode_kind = .edit;
        info.file = w.url;
    } else if (p.asBrowser()) |b| {
        info.mode_label = "CDP";
        info.mode_kind = .edit;
        info.file = b.url;
    };
    // The branch segment (`main ↑2 ↓1 ●3`), the diagnostics chip
    // (`✗ 2  ⚠ 1`), then the AI meter, before the input style.
    const branch_seg = try git_app.statusSegment(app, ui.arena);
    const meter_seg = try ai_app.meterSegment(app, ui.arena);
    // Then the unread-messages bell and the frame-time bar (`:messages`,
    // `ui.stress_meter`), nearest the input style.
    const bell_seg = try messages.bellSegment(app, ui.arena, ui.ascii);
    const stress_seg = try stress.segment(app, ui.arena, ui.ascii);
    const maybes = [_]?[]const u8{ branch_seg, lsp_seg, meter_seg, bell_seg, stress_seg };
    var extra: usize = 0;
    for (maybes) |m| extra += @intFromBool(m != null);
    if (extra > 0) {
        const segs = try ui.arena.alloc([]const u8, info.right.len + extra);
        @memcpy(segs[0..info.right.len], info.right);
        var n = info.right.len;
        for (maybes) |maybe| if (maybe) |seg| {
            segs[n] = seg;
            n += 1;
        };
        info.right = segs;
    }
    statusline.draw(ui, area, info);
}

/// The `:` line while it is open; blank otherwise (vim's cmdline row).
fn drawCmdline(app: *App, ui: Ui, area: Rect) void {
    if (area.isEmpty()) return;
    ui.fill(area, app.theme.bg);
    const e = app.activeEditor() orelse return;
    const line = e.buf.input.cmdlineGet() orelse return;
    const caret = e.buf.input.cmdlineCaret() orelse line.len;
    const shown = ui.fmt(":{s}", .{line});
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(shown, area.w), app.theme.fg);
    const cx: u16 = area.x + 1 + @as(u16, @intCast(@min(ui.width(line[0..@min(caret, line.len)]), area.w -| 1)));
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
        // A menu is anchored where the click was, which may be in the
        // tree or the right panel: it clamps against the whole screen.
        .menu => |*m| drawMenu(ui, ui.canvas.full(), m),
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
        .info => |kind| cmd_view.drawInfo(app, ui, ui.canvas.full(), kind),
    }
}

/// A context menu anchored at the click, pulled inside `screen` when it
/// would run off the edge. Every row registers `.menu_item{0, idx}`; a
/// separator paints a rule and registers nothing.
fn drawMenu(ui: Ui, screen: Rect, m: *const app_mod.MenuState) void {
    const th = ui.theme;
    var widest: u16 = ui.width(m.title) + 2;
    var rows: u16 = 0;
    for (m.items) |it| {
        widest = @max(widest, ui.width(it.label));
        rows += 1;
        if (it.separator_before) rows += 1;
    }
    // ✓ column + label + a cell of air each side, inside the frame.
    const w: u16 = @min(widest + 2 + 2 + 2, screen.w);
    const h: u16 = @min(rows + 2, screen.h);
    const x = @min(m.x, (screen.x + screen.w) -| w);
    const y = @min(m.y, (screen.y + screen.h) -| h);
    const inner = overlay_mod.frame(ui, Rect.init(x, y, w, h), m.title);
    if (inner.isEmpty()) return;
    var row: u16 = 0;
    for (m.items, 0..) |it, i| {
        if (it.separator_before and row < inner.h) {
            const r = inner.row(row);
            var xx: u16 = r.x;
            while (xx < r.right()) : (xx += 1) _ = ui.putStr(xx, r.y, 1, if (ui.ascii) "-" else "─", Theme.onBg(th.overlay_border, th.overlay_bg.bg));
            row += 1;
        }
        if (row >= inner.h) break;
        const r = inner.row(row);
        const selected = i == m.cursor;
        const style = if (selected) Theme.onBg(th.overlay_bg, th.cursor_line.bg) else th.overlay_bg;
        ui.fill(r, style);
        var xx = r.x + 1;
        xx += ui.putStr(xx, r.y, r.right() -| xx, if (it.checked) (if (ui.ascii) "* " else "✓ ") else "  ", Theme.withFg(style, th.accent.fg));
        _ = ui.putStr(xx, r.y, r.right() -| xx, ui.clipStr(it.label, r.right() -| xx), Theme.onBg(th.fg, style.bg));
        ui.hit(r, .{ .menu_item = .{ .menu = 0, .idx = @intCast(i) } });
        row += 1;
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(t.allocator, &app.screen);
}

test "frameRects: the bar needs 80 columns, the cmdline row needs 4 rows, the statusline is last to go" {
    const wide = frameRects(Rect.init(0, 0, 120, 40));
    try t.expect(wide.bar.eql(Rect.init(0, 0, 120, 1)));
    try t.expect(wide.upper.eql(Rect.init(0, 1, 120, 37)));
    try t.expect(wide.status.eql(Rect.init(0, 38, 120, 1)));
    try t.expect(wide.cmdline.eql(Rect.init(0, 39, 120, 1)));
    const narrow = frameRects(Rect.init(0, 0, 40, 8));
    try t.expect(narrow.bar.isEmpty());
    try t.expect(narrow.upper.eql(Rect.init(0, 0, 40, 6)));
    try t.expect(narrow.status.eql(Rect.init(0, 6, 40, 1)));
    try t.expect(narrow.cmdline.eql(Rect.init(0, 7, 40, 1)));
    const tiny = frameRects(Rect.init(0, 0, 100, 3));
    try t.expect(tiny.bar.isEmpty());
    try t.expect(tiny.cmdline.isEmpty());
    try t.expect(tiny.upper.eql(Rect.init(0, 0, 100, 2)));
    try t.expect(tiny.status.eql(Rect.init(0, 2, 100, 1)));
    const one = frameRects(Rect.init(0, 0, 100, 1));
    try t.expect(one.upper.isEmpty());
    try t.expect(one.status.eql(Rect.init(0, 0, 100, 1)));
}

test "a frame: bufferline tab, text with gutter, statusline Ln/Col, and the pane hit under the text" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 48, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    const empty = try screenText(&app);
    defer t.allocator.free(empty);
    try t.expect(std.mem.indexOf(u8, empty, "mnml-zig") != null);
    try t.expectEqual(Button.newTab(0), app.hits.at(1, 0).?.button);
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
    try t.expect(std.mem.indexOf(u8, txt, "standard") != null);
    try t.expect(app.hits.at(5, 2).? == .editor_cell);
    try t.expect(app.hits.at(5, 0).? == .tab);
    try t.expectEqual(@as(u32, 0), app.hits.at(5, 0).?.tab.leaf);
    // The `+` after the last tab, the mode chip on the statusline.
    try t.expectEqual(Button.newTab(0), app.hits.at(12, 0).?.button);
    try t.expectEqual(@as(u32, 0), app.hits.at(2, 6).?.statusline_seg);
    // gutter is max(digits, 3) + 2 = 5 cells; the cursor sits at col 2.
    try t.expectEqual(@as(u16, 7), app.cursor_pos.?.x);
    try t.expectEqual(@as(u16, 2), app.cursor_pos.?.y);
    // 8 rows: strip, 5 text rows, statusline, cmdline.
    try t.expectEqual(@as(usize, 5), app.pane_rows);
    try t.expect(app.panes_area.eql(Rect.init(0, 0, 48, 6)));
}

test "a wide frame has the palette bar on row 0 and the strip on row 1; each leaf carries its own strip" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const command = @import("../core/command.zig");
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
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText("alpha beta alpha");
    const command = @import("../core/command.zig");
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
