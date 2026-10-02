//! Prompt — the single-line input overlay: a titled box a third of the
//! way down the screen with one editable row and a hint under it.
//! `Go to line`, a commit message, a rename, a filter value: one shape.
//!
//! The frame is Rust's `popup_menu` — square, the title in plain bold
//! on the top edge — 4 rows tall, `max(title, 56) + 4` wide, centred on
//! the whole screen a third of the way down.
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
    /// The whole line is a selection (a seeded name): the next typed
    /// character or paste replaces it, backspace / delete clear it, any
    /// other key drops the selection and edits the line as usual.
    select_all: bool = false,
    /// A double-clicked word (`text_field.clickSelect`): the range from
    /// here to the caret. A triple-click is `select_all`.
    anchor: ?usize = null,

    pub fn text(s: *const State) []const u8 {
        return s.buf.items;
    }

    /// Replaces the line (a default value the app pre-fills) with the
    /// caret at its end — typing continues it.
    pub fn setText(s: *State, gpa: Allocator, value: []const u8) Allocator.Error!void {
        s.buf.clearRetainingCapacity();
        try s.buf.appendSlice(gpa, value);
        s.caret = s.buf.items.len;
        s.select_all = false;
    }

    /// Pre-fills the line as a selection: enter keeps it, typing
    /// replaces it (a suggested file name, the way an explorer's new-name
    /// box behaves).
    pub fn seed(s: *State, gpa: Allocator, value: []const u8) Allocator.Error!void {
        try s.setText(gpa, value);
        s.select_all = value.len > 0;
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
    const selected = s.select_all;
    s.select_all = false;
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
            // Ctrl+A selects the line (VS Code), not the field's home:
            // the next typed character replaces it.
            if (key.mods.ctrl and !key.mods.alt and c == 'a') {
                s.select_all = s.buf.items.len > 0;
                s.caret = s.buf.items.len;
                return .consumed;
            }
        },
        else => {},
    }
    if (selected and consumeSelection(s, key)) return .consumed;
    _ = try text_field.editKey(&s.buf, &s.caret, &s.anchor, gpa, key);
    return .consumed;
}

/// The selection's answer to a key: a typed character or a delete
/// replaces the whole line (true when the key is done — an erase; a
/// typed character still inserts into the emptied line). Anything else
/// leaves the text for the field to edit.
fn consumeSelection(s: *State, key: Key) bool {
    const typed = if (key.typed()) |cp| cp >= 0x20 and cp != 0x7f else false;
    const erase = (key.code == .backspace or key.code == .delete) and !key.mods.ctrl and !key.mods.alt;
    if (!typed and !erase) return false;
    s.buf.clearRetainingCapacity();
    s.caret = 0;
    return erase;
}

fn loadHistory(s: *State, gpa: Allocator, idx: usize) Allocator.Error!void {
    s.buf.clearRetainingCapacity();
    try s.buf.appendSlice(gpa, s.history.items[idx]);
    s.caret = s.buf.items.len;
    s.hist_idx = idx;
}

pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
    if (s.select_all) {
        s.select_all = false;
        s.buf.clearRetainingCapacity();
        s.caret = 0;
    }
    try text_field.insertSel(&s.buf, &s.caret, &s.anchor, gpa, text);
}

/// The field's rect inside the row `draw` registers as `.overlay_item(0)`.
pub fn fieldOf(row: Rect) Rect {
    return Rect.init(row.x + 1, row.y, row.w -| 2, 1);
}

/// Title row, then the input (hit `.overlay_item(0)`), then the hint.
/// Returns the caret cell for the terminal cursor.
pub fn draw(ui: Ui, area: Rect, s: *const State) ?Caret {
    const t = ui.theme;
    const title_w = ui.width(s.title) + 2;
    const w = @min(@max(title_w, min_width) + 4, area.w -| 2);
    const inner = overlay.boxLook(ui, area, @max(w, @min(area.w, 8)), height, s.title, .third, .menu);
    if (inner.isEmpty()) return null;
    const field_row = inner.row(0);
    const field = fieldOf(field_row);
    ui.hit(field_row, .{ .overlay_item = 0 });
    // A seeded line paints as a selection so the user sees that typing
    // replaces it.
    const style = if (s.select_all and s.buf.items.len > 0) Theme.onBg(t.fg, t.selection.bg) else Theme.onBg(t.fg, t.overlay_bg.bg);
    const caret = text_field.draw(ui, field, s.buf.items, s.caret, .{
        .style = style,
        .placeholder = s.placeholder,
        .placeholder_style = blk: {
            var ps = Theme.onBg(t.muted, t.overlay_bg.bg);
            ps.italic = true;
            break :blk ps;
        },
        .secret = s.secret,
        .anchor = s.anchor,
        // A press on the line: caret, word, line (`dispatch.fieldPress`).
        .field = .prompt,
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
    try f.expectRow(2, "          ┌ Go to line " ++ "─" ** 46 ++ "┐");
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

test "ctrl+a selects the whole line: the next character replaces it; on an empty line it is nothing" {
    const gpa = testing.allocator;
    var s = init(gpa, "Find in files");
    defer deinit(&s, gpa);
    try s.setText(gpa, "charlie one");
    try testing.expect(!s.select_all);
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.ctrl('a')));
    try testing.expect(s.select_all);
    _ = try handleKey(&s, gpa, Key.char('X'));
    try testing.expectEqualStrings("X", s.text());
    try testing.expect(!s.select_all);
    // An arrow after ctrl+a keeps the text and drops the selection.
    _ = try handleKey(&s, gpa, Key.ctrl('a'));
    _ = try handleKey(&s, gpa, Key.named(.left));
    try testing.expectEqualStrings("X", s.text());
    try testing.expect(!s.select_all);
    // The caret is before the X now: delete empties the line, and
    // ctrl+a on an empty line selects nothing.
    _ = try handleKey(&s, gpa, Key.named(.delete));
    try testing.expectEqualStrings("", s.text());
    _ = try handleKey(&s, gpa, Key.ctrl('a'));
    try testing.expect(!s.select_all);
}

test "a seeded line is a selection: typing replaces it, an arrow keeps it, backspace clears it, paste replaces it" {
    const gpa = testing.allocator;
    var s = init(gpa, "New note in .mnml/notes/");
    defer deinit(&s, gpa);
    try s.seed(gpa, "note-1.md");
    try testing.expect(s.select_all);
    try testing.expectEqualStrings("note-1.md", s.text());
    // Typing replaces the seed, then continues normally.
    _ = try handleKey(&s, gpa, Key.char('m'));
    _ = try handleKey(&s, gpa, Key.char('y'));
    try testing.expectEqualStrings("my", s.text());
    try testing.expect(!s.select_all);
    // A motion drops the selection and keeps the text.
    try s.seed(gpa, "note-1.md");
    _ = try handleKey(&s, gpa, Key.named(.left));
    _ = try handleKey(&s, gpa, Key.char('x'));
    try testing.expectEqualStrings("note-1.mxd", s.text());
    // Backspace clears the seed outright; the next key edits an empty line.
    try s.seed(gpa, "note-1.md");
    _ = try handleKey(&s, gpa, Key.named(.backspace));
    try testing.expectEqualStrings("", s.text());
    // Enter keeps the seed — the fast path.
    try s.seed(gpa, "note-1.md");
    try testing.expectEqual(Outcome.submit, try handleKey(&s, gpa, Key.named(.enter)));
    try testing.expectEqualStrings("note-1.md", s.text());
    // A paste replaces it too.
    try s.seed(gpa, "note-1.md");
    try paste(&s, gpa, "pasted");
    try testing.expectEqualStrings("pasted", s.text());
    // setText is the plain pre-fill: the caret at the end, no selection.
    try s.setText(gpa, "a.txt");
    try testing.expect(!s.select_all);
    _ = try handleKey(&s, gpa, Key.char('z'));
    try testing.expectEqualStrings("a.txtz", s.text());
}

test "the seeded line paints on the selection ground" {
    var f = try Fixture.init(80, 12);
    defer f.deinit();
    var s = init(testing.allocator, "New note");
    defer deinit(&s, testing.allocator);
    try s.seed(testing.allocator, "note-1.md");
    _ = draw(f.ui(), f.full(), &s);
    try f.expectContains("│ note-1.md");
    try testing.expect(f.bgEql(12, 3, f.theme.selection));
    _ = try handleKey(&s, testing.allocator, Key.named(.end));
    _ = draw(f.ui(), f.full(), &s);
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
