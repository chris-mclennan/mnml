//! Prompt — the single-line input overlay: a titled box a third of the
//! way down the screen with one editable row and a hint under it.
//! `Go to line`, a commit message, a rename, a filter value: one shape.
//!
//! The field is a `text_field`, so the caret, arrows, word deletes and
//! paste are all there. Enter submits and remembers the line; ↑/↓ walk
//! that history the way a shell does. The title is painted exactly as
//! given — the goto-line prompt's title is `Go to line` and the gate
//! asserts it.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const text_field = @import("text_field.zig");
const key_mod = @import("../core/key.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const Key = key_mod.Key;
pub const Caret = text_field.Caret;

pub const min_width: u16 = 56;
pub const height: u16 = 4;
pub const hint_text = "  enter to submit · esc to cancel";

pub const State = struct {
    title: []const u8,
    buf: text_field.Buf = .empty,
    caret: usize = 0,
    placeholder: ?[]const u8 = null,
    /// Newest last. Owned by `State` on the gpa.
    history: std.ArrayListUnmanaged([]u8) = .empty,
    /// Where ↑/↓ are in `history`; null = the fresh line.
    hist_idx: ?usize = null,
    /// Paint bullets instead of the text (a token, a password).
    secret: bool = false,

    pub fn text(s: *const State) []const u8 {
        return s.buf.items;
    }

    /// Replaces the line (a default value the app pre-fills).
    pub fn setText(s: *State, gpa: Allocator, value: []const u8) Allocator.Error!void {
        s.buf.clearRetainingCapacity();
        try s.buf.appendSlice(gpa, value);
        s.caret = s.buf.items.len;
    }

    /// Appends the current line to the history (skipping blanks and a
    /// repeat of the newest entry). `handleKey` does this on enter.
    pub fn remember(s: *State, gpa: Allocator) Allocator.Error!void {
        const line = s.buf.items;
        if (line.len == 0) return;
        if (s.history.items.len > 0 and std.mem.eql(u8, s.history.items[s.history.items.len - 1], line)) return;
        const copy = try gpa.dupe(u8, line);
        errdefer gpa.free(copy);
        try s.history.append(gpa, copy);
    }
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
    s.* = .{ .title = s.title };
}

/// esc → cancel, enter → submit (and remember), ↑/↓ → history,
/// everything else edits the line. A modal box consumes what it
/// does not understand.
pub fn handleKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
    switch (key.code) {
        .esc => return .cancel,
        .enter => {
            try s.remember(gpa);
            s.hist_idx = null;
            return .submit;
        },
        .up => {
            if (s.history.items.len == 0) return .consumed;
            const idx = if (s.hist_idx) |i| i -| 1 else s.history.items.len - 1;
            try loadHistory(s, gpa, idx);
            return .consumed;
        },
        .down => {
            const idx = s.hist_idx orelse return .consumed;
            if (idx + 1 < s.history.items.len) {
                try loadHistory(s, gpa, idx + 1);
            } else {
                // Past the newest entry: back to a fresh line.
                s.buf.clearRetainingCapacity();
                s.caret = 0;
                s.hist_idx = null;
            }
            return .consumed;
        },
        .char => |c| {
            if (key.mods.ctrl and (c == 'p' or c == 'n')) {
                return handleKey(s, gpa, Key.named(if (c == 'p') .up else .down));
            }
        },
        else => {},
    }
    _ = try text_field.handleKey(&s.buf, &s.caret, gpa, key);
    return .consumed;
}

fn loadHistory(s: *State, gpa: Allocator, idx: usize) Allocator.Error!void {
    s.buf.clearRetainingCapacity();
    try s.buf.appendSlice(gpa, s.history.items[idx]);
    s.caret = s.buf.items.len;
    s.hist_idx = idx;
}

pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
    try text_field.insert(&s.buf, &s.caret, gpa, text);
}

/// Title row, then the input (hit `.overlay_item(0)`), then the hint.
/// Returns the caret cell for the terminal cursor.
pub fn draw(ui: Ui, area: Rect, s: *const State) ?Caret {
    const t = ui.theme;
    const title_w = ui.width(s.title) + 2;
    const w = @min(@max(title_w, min_width) + 4, area.w -| 2);
    const inner = overlay.box(ui, area, @max(w, @min(area.w, 8)), height, s.title, .third);
    if (inner.isEmpty()) return null;
    const field_row = inner.row(0);
    const field = Rect.init(field_row.x + 1, field_row.y, field_row.w -| 2, 1);
    ui.hit(field_row, .{ .overlay_item = 0 });
    const caret = text_field.draw(ui, field, s.buf.items, s.caret, .{
        .style = Theme.onBg(t.fg, t.overlay_bg.bg),
        .placeholder = s.placeholder,
        .placeholder_style = blk: {
            var ps = Theme.onBg(t.muted, t.overlay_bg.bg);
            ps.italic = true;
            break :blk ps;
        },
        .secret = s.secret,
    });
    overlay.hint(ui, inner.row(1), hint_text);
    return caret;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the box carries its title verbatim, the input takes the caret, the hint sits below" {
    var f = try Fixture.init(80, 12);
    defer f.deinit();
    var s = init(testing.allocator, "Go to line");
    defer deinit(&s, testing.allocator);
    s.placeholder = "line number";
    var caret = draw(f.ui(), f.full(), &s);
    try f.expectContains("Go to line");
    try f.expectContains("line number");
    try f.expectContains("enter to submit · esc to cancel");
    // 60 wide, a third down: x = 10, y = (12-4)/3 = 2; input at row 3.
    try f.expectRow(2, "          ╭ Go to line " ++ "─" ** 46 ++ "╮");
    try testing.expectEqual(Caret{ .x = 12, .y = 3 }, caret.?);
    try testing.expectEqual(@as(u32, 0), f.hits.at(30, 3).?.overlay_item);
    try testing.expect(f.hits.at(30, 4) == null);
    try testing.expect(f.style(12, 3).italic);

    _ = try handleKey(&s, testing.allocator, Key.char('4'));
    _ = try handleKey(&s, testing.allocator, Key.char('2'));
    caret = draw(f.ui(), f.full(), &s);
    try f.expectContains("│ 42");
    try f.expectLacks("line number");
    try testing.expectEqual(Caret{ .x = 14, .y = 3 }, caret.?);
    try testing.expect(!f.style(12, 3).italic);
    try testing.expect(f.bgEql(12, 3, f.theme.overlay_bg));
}

test "enter submits and remembers; up/down walk the history; esc cancels" {
    const gpa = testing.allocator;
    var s = init(gpa, "Command");
    defer deinit(&s, gpa);
    try s.setText(gpa, "first");
    try testing.expectEqual(Outcome.submit, try handleKey(&s, gpa, Key.named(.enter)));
    try testing.expectEqual(@as(usize, 1), s.history.items.len);
    try s.setText(gpa, "second");
    try testing.expectEqual(Outcome.submit, try handleKey(&s, gpa, Key.named(.enter)));
    // A repeat of the newest entry and a blank line are not stored.
    try testing.expectEqual(Outcome.submit, try handleKey(&s, gpa, Key.named(.enter)));
    try s.setText(gpa, "");
    try testing.expectEqual(Outcome.submit, try handleKey(&s, gpa, Key.named(.enter)));
    try testing.expectEqual(@as(usize, 2), s.history.items.len);

    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.named(.up)));
    try testing.expectEqualStrings("second", s.text());
    try testing.expectEqual(@as(usize, 6), s.caret);
    _ = try handleKey(&s, gpa, Key.named(.up));
    try testing.expectEqualStrings("first", s.text());
    _ = try handleKey(&s, gpa, Key.named(.up));
    try testing.expectEqualStrings("first", s.text());
    _ = try handleKey(&s, gpa, Key.ctrl('n'));
    try testing.expectEqualStrings("second", s.text());
    _ = try handleKey(&s, gpa, Key.named(.down));
    try testing.expectEqualStrings("", s.text());
    try testing.expect(s.hist_idx == null);
    _ = try handleKey(&s, gpa, Key.named(.down));
    try testing.expectEqualStrings("", s.text());

    try paste(&s, gpa, "pasted\nline");
    try testing.expectEqualStrings("pasted line", s.text());
    _ = try handleKey(&s, gpa, Key.ctrl('w'));
    try testing.expectEqualStrings("pasted ", s.text());
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.named(.{ .f = 1 })));
    try testing.expectEqual(Outcome.cancel, try handleKey(&s, gpa, Key.named(.esc)));
}

test "a secret prompt paints bullets; tiny screens do not panic" {
    var f = try Fixture.init(30, 6);
    defer f.deinit();
    var s = init(testing.allocator, "Token");
    defer deinit(&s, testing.allocator);
    s.secret = true;
    try s.setText(testing.allocator, "abc");
    _ = draw(f.ui(), f.full(), &s);
    try f.expectContains("•••");
    try f.expectLacks("abc");
    var g = try Fixture.init(3, 2);
    defer g.deinit();
    try testing.expect(draw(g.ui(), g.full(), &s) == null);
    _ = draw(g.ui(), Rect.empty, &s);
}
