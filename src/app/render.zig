//! One frame. Row 0 is the bufferline, the last row the statusline,
//! everything between is the split tree (each editor pane through
//! `editor_view.draw` with a `Doc` built from its buffer), then the find
//! bar, the overlay, and the toasts — in that order, so the hit map's
//! back-to-front scan gives the overlay the mouse.
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
const pty_view = @import("../ui/pty_view.zig");
const pty_pane = @import("pty_pane.zig");

/// The right panel's width; the divider takes one more column.
pub const right_panel_width: u16 = 40;
/// The divider hit ids the body does not use (`.divider` is otherwise
/// an index into the split tree's dividers).
pub const tree_divider_id: u32 = std.math.maxInt(u32);
pub const right_divider_id: u32 = std.math.maxInt(u32) - 1;

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
        .ascii = app.cfg.ascii,
    };
    const full = ui.canvas.full();
    ui.canvas.fill(full, app.theme.bg);
    screen.cursor_vis = false;
    app.cursor_pos = null;

    // Row 0: bufferline. Last row: statusline. Between: the panes.
    const top = full.splitTop(1);
    const bottom = top.rest.splitBottom(1);
    const body = bottom.top;
    // The tree takes its width plus a one-cell divider (Rust `ui/mod.rs`).
    var panes_area = body;
    if (app.tree.visible and body.w > 12) {
        const w: u16 = @max(@min(app.tree.width, body.w -| 21), 8);
        const cols = body.splitLeft(w);
        const div = cols.rest.splitLeft(1);
        try app.tree.draw(app, ui, cols.left);
        drawDivider(app, ui, div.left, tree_divider_id);
        panes_area = div.rest;
    }
    // The right panel takes its width plus a divider off the far side.
    if (app.right_panel) |which| if (panes_area.w > right_panel_width + 21) {
        const cols = panes_area.splitRight(right_panel_width);
        const div = cols.left.splitRight(1);
        panes_area = div.left;
        drawDivider(app, ui, div.rest, right_divider_id);
        try drawRightPanel(app, ui, cols.rest, which);
    };
    try drawBufferline(app, ui, .{ .x = panes_area.x, .y = top.top.y, .w = panes_area.w, .h = 1 });
    try drawBody(app, ui, panes_area);
    try drawStatusline(app, ui, bottom.rest);
    try drawOverlay(app, ui, panes_area);
    toast_mod.draw(ui, panes_area, try app.visibleToasts(arena));
}

fn drawDivider(app: *App, ui: Ui, r: Rect, id: u32) void {
    ui.canvas.fill(r, app.theme.border);
    var y: u16 = r.y;
    while (y < r.bottom()) : (y += 1) ui.canvas.put(r.x, y, .{ .char = .{ .grapheme = if (ui.ascii) "|" else "│", .width = 1 }, .style = app.theme.border });
    ui.hit(r, .{ .divider = id });
}

/// The panel in the right slot. Only TODOS draws today; the others
/// name themselves until their module lands.
fn drawRightPanel(app: *App, ui: Ui, area: Rect, which: app_mod.PanelId) Allocator.Error!void {
    switch (which) {
        .todos => try todos.draw(app, ui, area),
        .notes, .findings, .sessions => {
            ui.fill(area, app.theme.panel_bg);
            const msg = ui.fmt(" {s}: not in this build yet", .{@tagName(which)});
            _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(msg, area.w), Theme.onBg(app.theme.muted, app.theme.panel_bg.bg));
        },
    }
}

fn drawBufferline(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const layout = app.layouts.current();
    var tabs: std.ArrayListUnmanaged(bufferline.Tab) = .empty;
    const ids: []const PaneId = blk: {
        if (app.active) |a| if (layout.leafOf(a)) |leaf| break :blk layout.leaf(leaf).?.tabs.items;
        break :blk try layout.allPanes(ui.arena);
    };
    for (ids) |id| {
        const p = app.panes.get(id) orelse continue;
        try tabs.append(ui.arena, .{ .id = id, .title = p.title(), .dirty = p.dirty(), .active = app.active == id });
    }
    bufferline.draw(ui, area, tabs.items);
}

fn drawBody(app: *App, ui: Ui, body: Rect) Allocator.Error!void {
    const layout = app.layouts.current();
    if (layout.isEmpty()) {
        const msg = "mnml-zig — ctrl+p opens a file, ctrl+q quits";
        const w: u16 = @intCast(@min(std.unicode.utf8CountCodepoints(msg) catch msg.len, body.w));
        const r = Rect.init(body.x + (body.w -| w) / 2, body.y + body.h / 2, w, 1);
        _ = ui.canvas.text(r, &.{.{ .text = msg, .style = app.theme.muted }}, .{});
        return;
    }
    const rects = try layout.computeRects(body, ui.arena);
    for (rects.dividers, 0..) |d, i| {
        ui.canvas.fill(d, app.theme.border);
        const glyph: []const u8 = if (d.w == 1) (if (ui.ascii) "|" else "│") else (if (ui.ascii) "-" else "─");
        var y: u16 = d.y;
        while (y < d.bottom()) : (y += 1) {
            var x: u16 = d.x;
            while (x < d.right()) : (x += 1) ui.canvas.put(x, y, .{ .char = .{ .grapheme = glyph, .width = 1 }, .style = app.theme.border });
        }
        try ui.hits.add(ui.arena, d, .{ .divider = @intCast(i) });
    }
    for (rects.panes) |pr| {
        const pane = app.panes.get(pr.pane) orelse continue;
        try ui.hits.add(ui.arena, pr.rect, .{ .pane = pr.pane });
        switch (pane.*) {
            .editor => |*e| try drawEditor(app, ui, pr.pane, e, pr.rect),
            .pty => |*p| try drawPty(app, ui, pr.pane, p, pr.rect),
        }
    }
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
    if (e.hl_dirty) {
        try e.syntax.refresh(e.buf.editor.bytes());
        e.hl_dirty = false;
    }
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
        .spans = e.syntax.spans.items,
        .matches = matches,
        .current_match = e.find.current,
        .wrap = e.wrap orelse app.cfg.wrap,
        .tab_width = app.cfg.tab_width,
        .line_numbers = app.cfg.line_numbers,
        .cursor_shape = switch (mode) {
            .insert, .none => .bar,
            .replace => .underline,
            else => .block,
        },
        .focused = focused,
        .visual_block = mode == .visual_block,
    };
    const cursor = editor_view.draw(ui, id, rect, &e.view, doc);
    if (app.active == id) {
        app.pane_rows = @max(rect.h, 1);
        // Text columns: the gutter takes the digits plus two.
        var digits: u16 = 1;
        var n = e.buf.editor.lineCount();
        while (n >= 10) : (n /= 10) digits += 1;
        const gutter: u16 = if (app.cfg.line_numbers) digits + 2 else 0;
        app.pane_cols = @max(rect.w -| gutter, 1);
        if (focused) app.cursor_pos = cursor;
    }
    if (bar) |b| if (app.find_bar) |*fb| {
        if (find_bar_mod.draw(ui, b, &fb.state, .{ .current = e.find.current, .total = e.find.matches.items.len })) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
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
        .input_style = @tagName(app.cfg.input_style),
    };
    if (app.activeEditor()) |e| {
        const ed = &e.buf.editor;
        const mode = e.buf.input.mode();
        info.mode_label = mode.label();
        info.mode_kind = switch (mode) {
            .none => .none,
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
    };
    statusline.draw(ui, area, info);
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
            for (p.filtered.items, 0..) |idx, i| items[i] = .{ .label = p.labels[idx] };
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

test "a frame: bufferline tab, text with gutter, statusline Ln/Col, and the pane hit under the text" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 40, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    const empty = try screenText(&app);
    defer t.allocator.free(empty);
    try t.expect(std.mem.indexOf(u8, empty, "mnml-zig") != null);
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
    // gutter is max(digits, 3) + 2 = 5 cells; the cursor sits at col 2.
    try t.expectEqual(@as(u16, 7), app.cursor_pos.?.x);
    try t.expectEqual(@as(u16, 2), app.cursor_pos.?.y);
    try t.expectEqual(@as(usize, 6), app.pane_rows);
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
    try t.expectEqual(@as(usize, 9), app.pane_rows);
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
