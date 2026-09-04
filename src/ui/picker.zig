//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! A fuzzy list overlay (buffers, files, commands).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("rect.zig");
const context = @import("context.zig");
const prompt = @import("prompt.zig");
const key_mod = @import("../core/key.zig");
pub const Key = key_mod.Key;
pub const Ui = context.Ui;

pub const Picker = struct {
    pub const Item = struct { label: []const u8, detail: ?[]const u8 = null, hint: ?[]const u8 = null };
    pub const State = struct { title: []const u8, query: std.ArrayListUnmanaged(u8) = .empty, caret: usize = 0, cursor: usize = 0, scroll: usize = 0 };
    /// `accept` indexes the ITEMS SLICE PASSED TO DRAW (filtered order).
    pub const Outcome = union(enum) { consumed, cancel, changed, accept: usize };

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.query.deinit(gpa);
    }

    pub fn handleKey(s: *State, gpa: Allocator, key: Key, visible_count: usize) Allocator.Error!Outcome {
        switch (key.code) {
            .esc => return .cancel,
            .enter => return if (visible_count == 0) .cancel else .{ .accept = @min(s.cursor, visible_count - 1) },
            .up => return move(s, visible_count, -1),
            .down => return move(s, visible_count, 1),
            .page_up => return move(s, visible_count, -10),
            .page_down => return move(s, visible_count, 10),
            .char => |c| if (key.mods.ctrl) switch (c) {
                'p', 'k' => return move(s, visible_count, -1),
                'n', 'j' => return move(s, visible_count, 1),
                else => {},
            },
            else => {},
        }
        const before = s.query.items.len;
        const edited = try prompt.editKey(gpa, &s.query, &s.caret, key);
        if (edited and (before != s.query.items.len or key.code == .char)) {
            s.cursor = 0;
            s.scroll = 0;
            return .changed;
        }
        return .consumed;
    }

    fn move(s: *State, visible: usize, delta: i32) Outcome {
        if (visible == 0) return .consumed;
        const cur: i64 = @intCast(s.cursor);
        const next = @min(@max(cur + delta, 0), @as(i64, @intCast(visible - 1)));
        s.cursor = @intCast(next);
        return .consumed;
    }

    pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
        try prompt.insertText(gpa, &s.query, &s.caret, text);
    }

    pub fn draw(ui: Ui, area: Rect, s: *State, items: []const Item) void {
        const w: u16 = @min(area.w -| 4, 70);
        const h: u16 = @min(area.h -| 2, @as(u16, @intCast(@min(items.len, 12))) + 4);
        if (w < 10 or h < 4) return;
        const box = Rect.init(area.x + (area.w - w) / 2, area.y + (area.h -| h) / 4, w, h);
        ui.canvas.fill(box, ui.theme.overlay_bg);
        const inner = ui.canvas.border(box, .rounded, ui.theme.overlay_border, null);
        _ = ui.canvas.text(inner.row(0), &.{.{ .text = s.title, .style = ui.theme.overlay_title }}, .{});
        const cur = @min(s.caret, s.query.items.len);
        const q = std.mem.concat(ui.arena, u8, &.{ "> ", s.query.items[0..cur], "\u{258f}", s.query.items[cur..] }) catch return;
        _ = ui.canvas.text(inner.row(1), &.{.{ .text = q, .style = ui.theme.overlay_bg }}, .{});
        const rows: usize = inner.h -| 2;
        if (rows == 0) return;
        if (s.cursor < s.scroll) s.scroll = s.cursor;
        if (s.cursor >= s.scroll + rows) s.scroll = s.cursor + 1 - rows;
        var i: usize = s.scroll;
        var y: u16 = 2;
        while (i < items.len and y < inner.h) : ({
            i += 1;
            y += 1;
        }) {
            const it = items[i];
            const r = inner.row(y);
            const style = if (i == s.cursor) ui.theme.chip_active else ui.theme.overlay_bg;
            const line = if (it.detail) |d| std.fmt.allocPrint(ui.arena, " {s}  {s}", .{ it.label, d }) catch return else std.fmt.allocPrint(ui.arena, " {s}", .{it.label}) catch return;
            ui.canvas.fill(r, style);
            _ = ui.canvas.text(r, &.{.{ .text = line, .style = style }}, .{});
            ui.hits.add(ui.arena, r, .{ .overlay_item = @intCast(i) }) catch {};
        }
    }
};

test "picker: moves, accepts the visible index, esc cancels" {
    const gpa = std.testing.allocator;
    var s: Picker.State = .{ .title = "Buffers" };
    defer Picker.deinit(&s, gpa);
    _ = try Picker.handleKey(&s, gpa, Key.named(.down), 3);
    _ = try Picker.handleKey(&s, gpa, Key.ctrl('n'), 3);
    try std.testing.expectEqual(@as(usize, 2), (try Picker.handleKey(&s, gpa, Key.named(.enter), 3)).accept);
    try std.testing.expect((try Picker.handleKey(&s, gpa, Key.char('x'), 3)) == .changed);
    try std.testing.expectEqual(@as(usize, 0), s.cursor);
    try std.testing.expect((try Picker.handleKey(&s, gpa, Key.named(.esc), 3)) == .cancel);
}
