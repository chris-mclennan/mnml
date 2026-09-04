//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! A single-line input overlay: title row + input row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("rect.zig");
const Canvas = @import("canvas.zig");
const context = @import("context.zig");
const key_mod = @import("../core/key.zig");
pub const Key = key_mod.Key;
pub const Ui = context.Ui;

/// Shared line-editing over an `ArrayListUnmanaged(u8)` + caret. Returns
/// true when the key was an edit / caret move.
pub fn editKey(gpa: Allocator, buf: *std.ArrayListUnmanaged(u8), caret: *usize, key: Key) Allocator.Error!bool {
    const n = buf.items.len;
    if (caret.* > n) caret.* = n;
    if (key.mods.ctrl and !key.mods.alt) {
        switch (key.code) {
            .char => |c| switch (c) {
                'a' => caret.* = 0,
                'e' => caret.* = n,
                'u' => {
                    buf.replaceRangeAssumeCapacity(0, caret.*, &.{});
                    caret.* = 0;
                },
                'w' => {
                    var s = caret.*;
                    while (s > 0 and buf.items[s - 1] == ' ') s -= 1;
                    while (s > 0 and buf.items[s - 1] != ' ') s -= 1;
                    buf.replaceRangeAssumeCapacity(s, caret.* - s, &.{});
                    caret.* = s;
                },
                else => return false,
            },
            else => return false,
        }
        return true;
    }
    switch (key.code) {
        .left => caret.* = prevBoundary(buf.items, caret.*),
        .right => caret.* = nextBoundary(buf.items, caret.*),
        .home => caret.* = 0,
        .end => caret.* = n,
        .backspace => {
            const p = prevBoundary(buf.items, caret.*);
            buf.replaceRangeAssumeCapacity(p, caret.* - p, &.{});
            caret.* = p;
        },
        .delete => {
            const q = nextBoundary(buf.items, caret.*);
            buf.replaceRangeAssumeCapacity(caret.*, q - caret.*, &.{});
        },
        .char => |c| {
            if (key.mods.alt or key.mods.super) return false;
            var tmp: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &tmp) catch return false;
            try buf.insertSlice(gpa, caret.*, tmp[0..len]);
            caret.* += len;
        },
        else => return false,
    }
    return true;
}

pub fn insertText(gpa: Allocator, buf: *std.ArrayListUnmanaged(u8), caret: *usize, text: []const u8) Allocator.Error!void {
    if (caret.* > buf.items.len) caret.* = buf.items.len;
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(gpa);
    for (text) |c| if (c != '\n' and c != '\r') try clean.append(gpa, c);
    try buf.insertSlice(gpa, caret.*, clean.items);
    caret.* += clean.items.len;
}

fn prevBoundary(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var p = i - 1;
    while (p > 0 and (s[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

fn nextBoundary(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var q = i + 1;
    while (q < s.len and (s[q] & 0xC0) == 0x80) q += 1;
    return q;
}

/// Paints `title` then `> text▏rest` in a centered box. Returns the input rect.
pub fn drawBox(ui: Ui, area: Rect, title: []const u8, text: []const u8, caret: usize) Rect {
    const w: u16 = @min(area.w -| 4, 60);
    const h: u16 = 4;
    if (w < 8 or area.h < h) return Rect.empty;
    const box = Rect.init(area.x + (area.w - w) / 2, area.y + (area.h -| h) / 3, w, h);
    ui.canvas.fill(box, ui.theme.overlay_bg);
    const inner = ui.canvas.border(box, .rounded, ui.theme.overlay_border, null);
    _ = ui.canvas.text(inner.row(0), &.{.{ .text = title, .style = ui.theme.overlay_title }}, .{});
    const cur = @min(caret, text.len);
    const row = inner.row(1);
    const line = std.mem.concat(ui.arena, u8, &.{ "> ", text[0..cur], "\u{258f}", text[cur..] }) catch return row;
    _ = ui.canvas.text(row, &.{.{ .text = line, .style = ui.theme.overlay_bg }}, .{});
    return row;
}

pub const Prompt = struct {
    pub const State = struct {
        title: []const u8,
        buf: std.ArrayListUnmanaged(u8) = .empty,
        caret: usize = 0,
        placeholder: ?[]const u8 = null,
        history: std.ArrayListUnmanaged([]u8) = .empty,
        hist_idx: ?usize = null,
    };
    pub const Outcome = enum { consumed, cancel, submit };

    pub fn init(gpa: Allocator, title: []const u8) State {
        _ = gpa;
        return .{ .title = title };
    }

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.buf.deinit(gpa);
        for (s.history.items) |h| gpa.free(h);
        s.history.deinit(gpa);
    }

    pub fn handleKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
        switch (key.code) {
            .esc => return .cancel,
            .enter => return .submit,
            .up => {
                if (s.history.items.len == 0) return .consumed;
                const idx = if (s.hist_idx) |i| i -| 1 else s.history.items.len - 1;
                s.hist_idx = idx;
                s.buf.clearRetainingCapacity();
                try s.buf.appendSlice(gpa, s.history.items[idx]);
                s.caret = s.buf.items.len;
                return .consumed;
            },
            .down => {
                const idx = s.hist_idx orelse return .consumed;
                s.buf.clearRetainingCapacity();
                if (idx + 1 < s.history.items.len) {
                    s.hist_idx = idx + 1;
                    try s.buf.appendSlice(gpa, s.history.items[idx + 1]);
                } else s.hist_idx = null;
                s.caret = s.buf.items.len;
                return .consumed;
            },
            else => {},
        }
        _ = try editKey(gpa, &s.buf, &s.caret, key);
        return .consumed;
    }

    pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
        try insertText(gpa, &s.buf, &s.caret, text);
    }

    pub fn draw(ui: Ui, area: Rect, s: *const State) void {
        const row = drawBox(ui, area, s.title, s.buf.items, s.caret);
        ui.hits.add(ui.arena, row, .{ .overlay_item = 0 }) catch {};
    }
};

test "prompt: typing, caret edits, submit and cancel" {
    const gpa = std.testing.allocator;
    var s = Prompt.init(gpa, "Go to line");
    defer Prompt.deinit(&s, gpa);
    try std.testing.expectEqual(Prompt.Outcome.consumed, try Prompt.handleKey(&s, gpa, Key.char('4')));
    try std.testing.expectEqual(Prompt.Outcome.consumed, try Prompt.handleKey(&s, gpa, Key.char('2')));
    _ = try Prompt.handleKey(&s, gpa, Key.named(.left));
    _ = try Prompt.handleKey(&s, gpa, Key.char('1'));
    try std.testing.expectEqualStrings("412", s.buf.items);
    _ = try Prompt.handleKey(&s, gpa, Key.named(.backspace));
    try std.testing.expectEqualStrings("42", s.buf.items);
    try Prompt.paste(&s, gpa, "9\n");
    try std.testing.expectEqualStrings("492", s.buf.items);
    try std.testing.expectEqual(Prompt.Outcome.submit, try Prompt.handleKey(&s, gpa, Key.named(.enter)));
    try std.testing.expectEqual(Prompt.Outcome.cancel, try Prompt.handleKey(&s, gpa, Key.named(.esc)));
}
