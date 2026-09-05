//! Sticky context: when the first visible line of an editor sits inside
//! a function or class whose header has scrolled off the top, that
//! header is painted over the pane's first rows (up to three, innermost
//! kept when there are more) so you always know what you are reading.
//! Off by default; `view.toggle_sticky_context` / `:set stickycontext`.
//!
//! The rows are painted after the editor view — the same gutter width,
//! the header line's own number, bold on the cursor-line ground — and
//! each registers an `.editor_cell` for its line so a click jumps to the
//! header.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const PaneId = app_mod.PaneId;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const editor_view = @import("../ui/editor_view.zig");

pub const max_rows = 3;

/// The header lines to pin for `e`'s current viewport, outermost first;
/// empty when the feature is off, the top line is not inside a scope,
/// or every enclosing header is already on screen.
pub fn headerLines(app: *App, e: *EditorPane, arena: Allocator) Allocator.Error![]u32 {
    if (!app.cfg.ui.sticky_context) return &.{};
    const first = e.view.scroll_line;
    if (first == 0) return &.{};
    const chain = try e.syntax.scopeChain(e.buf.editor, arena, first);
    if (chain.len <= max_rows) return chain;
    return chain[chain.len - max_rows ..];
}

/// Paint `lines` over the top of `area` (the rect the editor view was
/// given). `text_x` is where the editor's text column starts.
pub fn draw(ui: Ui, pane: PaneId, e: *const EditorPane, area: Rect, lines: []const u32, line_numbers: bool) void {
    const t = ui.theme;
    const ed = e.buf.editor;
    const total: u32 = @intCast(ed.lineCount());
    const gutter_w: u16 = if (line_numbers) blk: {
        var digits: u16 = 1;
        var n = total;
        while (n >= 10) : (n /= 10) digits += 1;
        break :blk @min(@max(digits, 3) + 2, area.w);
    } else 0;
    var style = t.cursor_line;
    style.bold = true;
    for (lines, 0..) |line, i| {
        if (i >= area.h or line >= total) break;
        const y = area.y + @as(u16, @intCast(i));
        const r = Rect.init(area.x, y, area.w, 1);
        ui.fill(r, style);
        if (gutter_w > 2) {
            const num = ui.fmt("{d}", .{line + 1});
            _ = ui.putStrRight(area.x + gutter_w - 1, y, gutter_w - 2, num, Theme.withFg(style, t.gutter.fg));
        }
        const text = ed.bytes()[ed.lineStart(line)..ed.lineEnd(line)];
        const cells = editor_view.layoutLine(ui, text, @intCast(ed.doc.tab_width)) catch &.{};
        var x = area.x + gutter_w;
        for (cells) |c| {
            if (x + c.w > area.right()) break;
            ui.canvas.put(x, y, .{ .char = .{ .grapheme = c.bytes, .width = c.w }, .style = style });
            x += c.w;
        }
        ui.hit(r, .{ .editor_cell = .{ .pane = pane, .line = line, .col = 0 } });
    }
}

// ── tests ──

const testing = std.testing;
const command = @import("../core/command.zig");
const screen_mod = @import("../ipc/screen.zig");

test "the enclosing fn header pins to the top once it scrolls off; the toggle toasts" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 40, .rows = 8 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/code.rs");
    e.syntax.setLanguage("/tmp/code.rs", "");
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "fn outer() {\n");
    for (0..20) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "    let v{d} = {d};\n", .{ i, i });
        defer testing.allocator.free(line);
        try text.appendSlice(testing.allocator, line);
    }
    try text.appendSlice(testing.allocator, "}\n");
    try e.buf.editor.setText(text.items);
    e.buf.editor.placeCursor(20, 0);
    try app.render();
    const plain = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "fn outer()") == null);
    try command.run(&app, .{ .static = .@"view.toggle_sticky_context" });
    try testing.expectEqualStrings("sticky context: on", app.lastToast().?);
    try app.render();
    const sticky = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(sticky);
    try testing.expect(std.mem.indexOf(u8, sticky, "fn outer()") != null);
    // The pinned row is the third screen row (row 0 is the palette bar,
    // which paints from 40 columns; row 1 the bufferline).
    var rows = std.mem.splitScalar(u8, sticky, '\n');
    _ = rows.next();
    _ = rows.next();
    try testing.expect(std.mem.indexOf(u8, rows.next().?, "fn outer()") != null);
    try testing.expectEqual(@as(u32, 0), app.hits.at(8, 2).?.editor_cell.line);
    // Scrolled back to the top there is nothing to pin.
    e.buf.editor.placeCursor(0, 0);
    try app.render();
    const top = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(top);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, top, "fn outer()"));
    try command.run(&app, .{ .static = .@"view.toggle_sticky_context" });
    try testing.expectEqualStrings("sticky context: off", app.lastToast().?);
}
