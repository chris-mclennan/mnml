//! vim-surround: wrap a selection (`ys{motion}<c>`, visual `S<c>`),
//! delete the enclosing pair (`ds<c>`), change it (`cs<from><to>`).
//! An opener (`(` `[` `{`) pads the inside with one space and, as the
//! target of `ds` / `cs`, eats one; its closer never touches spacing.
//! `t` names the enclosing tag pair for `ds` / `cs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const EditOutcome = @import("edit_op.zig").EditOutcome;
const select = @import("select.zig");

pub const Pair = struct { open: u21, close: u21, pad: bool };

/// vim-surround's table, aliases included: `b` `)`, `B` `}`, `r` `]`,
/// `a` `>`. `<` is plain angle brackets here (vim-surround prompts for a
/// tag), so it never pads — the way `cs(<` on `(1, 2)` gives `<1, 2>`.
pub fn pairFor(c: u21) ?Pair {
    return switch (c) {
        '"', '\'', '`' => .{ .open = c, .close = c, .pad = false },
        '(' => .{ .open = '(', .close = ')', .pad = true },
        ')', 'b' => .{ .open = '(', .close = ')', .pad = false },
        '[' => .{ .open = '[', .close = ']', .pad = true },
        ']', 'r' => .{ .open = '[', .close = ']', .pad = false },
        '{' => .{ .open = '{', .close = '}', .pad = true },
        '}', 'B' => .{ .open = '{', .close = '}', .pad = false },
        '<', '>', 'a' => .{ .open = '<', .close = '>', .pad = false },
        else => null,
    };
}

/// Chars the handler accepts after `ds` / `cs` / `ys`.
pub fn isSurroundChar(c: u21) bool {
    return c == 't' or pairFor(c) != null;
}

/// The enclosing pair as `{ open_start, open_end, close_start, close_end }`.
fn find(ed: *const Editor, c: u21) ?[4]usize {
    if (c == 't') return select.enclosingTagPair(ed);
    const p = pairFor(c) orelse return null;
    const r = (if (p.open == p.close) select.enclosingQuotePairOnLine(ed, p.open) else select.enclosingBracketPair(ed, p.open, p.close)) orelse return null;
    return .{ r[0], r[0] + editor.charLen(p.open), r[1], r[1] + editor.charLen(p.close) };
}

/// Widen the delimiter ranges over one inner space each side.
fn eatInnerSpaces(ed: *const Editor, r: *[4]usize) void {
    const t = ed.bytes();
    if (r[1] < r[2] and t[r[1]] == ' ') r[1] += 1;
    if (r[2] > r[1] and t[r[2] - 1] == ' ') r[2] -= 1;
}

/// The delimiter strings a pair inserts, padding included.
const Delims = struct {
    open: [5]u8 = undefined,
    open_len: usize = 0,
    close: [5]u8 = undefined,
    close_len: usize = 0,

    fn of(p: Pair) Delims {
        var d: Delims = .{};
        d.open_len = std.unicode.utf8Encode(p.open, d.open[0..4]) catch 0;
        if (p.pad) {
            d.open[d.open_len] = ' ';
            d.open_len += 1;
            d.close[0] = ' ';
            d.close_len = 1;
        }
        d.close_len += std.unicode.utf8Encode(p.close, d.close[d.close_len..][0..4]) catch 0;
        return d;
    }

    fn openStr(d: *const Delims) []const u8 {
        return d.open[0..d.open_len];
    }

    fn closeStr(d: *const Delims) []const u8 {
        return d.close[0..d.close_len];
    }
};

/// Wrap the selection. The cursor lands on the closer (Rust parity).
pub fn surroundSelection(ed: *Editor, open: u21, close: u21, pad: bool, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    if (sel[1] <= sel[0]) return;
    const d = Delims.of(.{ .open = open, .close = close, .pad = pad });
    try ed.checkpoint();
    try ed.splice(sel[1], sel[1], d.closeStr());
    try ed.splice(sel[0], sel[0], d.openStr());
    ed.cursor = sel[1] + d.open_len + d.close_len - editor.charLen(close);
    ed.anchor = null;
    out.buffer_changed = true;
}

/// `ds<c>`: drop both delimiters; the cursor lands where the opener was.
pub fn deleteSurround(ed: *Editor, c: u21, out: *EditOutcome) Allocator.Error!void {
    var r = find(ed, c) orelse return;
    if (pairFor(c)) |p| if (p.pad) eatInnerSpaces(ed, &r);
    try ed.checkpoint();
    try ed.splice(r[2], r[3], "");
    try ed.splice(r[0], r[1], "");
    ed.cursor = r[0];
    ed.anchor = null;
    out.buffer_changed = true;
}

/// `cs<from><to>`: swap the delimiters; the cursor lands on the new opener.
/// A tag target needs a name and is not expressible here, so `to == 't'`
/// is a no-op.
pub fn changeSurround(ed: *Editor, from: u21, to: u21, out: *EditOutcome) Allocator.Error!void {
    const tp = pairFor(to) orelse return;
    var r = find(ed, from) orelse return;
    if (pairFor(from)) |p| if (p.pad) eatInnerSpaces(ed, &r);
    const d = Delims.of(tp);
    try ed.checkpoint();
    try ed.splice(r[2], r[3], d.closeStr());
    try ed.splice(r[0], r[1], d.openStr());
    ed.cursor = r[0];
    ed.anchor = null;
    out.buffer_changed = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "wrap: quotes are bare, an opener pads, a closer does not" {
    var ed = try Editor.init(testing.allocator, "abc def");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.setSelection(0, 3);
    try surroundSelection(&ed, '"', '"', false, &out);
    try testing.expectEqualStrings("\"abc\" def", ed.text.items);
    try testing.expectEqual(@as(usize, 4), ed.cursor);
    try testing.expect(ed.anchor == null);
    ed.setSelection(6, 9);
    try surroundSelection(&ed, '(', ')', true, &out);
    try testing.expectEqualStrings("\"abc\" ( def )", ed.text.items);
    try testing.expectEqual(@as(usize, 12), ed.cursor); // on the closer, past its padding
    ed.setSelection(0, 5);
    try surroundSelection(&ed, '[', ']', false, &out);
    try testing.expectEqualStrings("[\"abc\"] ( def )", ed.text.items);
}

test "ds: quotes on the line, brackets with depth, an opener eats its padding, t drops both tags" {
    var ed = try Editor.init(testing.allocator, "x \"a b\" ( c ) <b>hi</b>");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 4;
    try deleteSurround(&ed, '"', &out);
    try testing.expectEqualStrings("x a b ( c ) <b>hi</b>", ed.text.items);
    try testing.expectEqual(@as(usize, 2), ed.cursor);
    ed.cursor = 8;
    try deleteSurround(&ed, ')', &out);
    try testing.expectEqualStrings("x a b  c  <b>hi</b>", ed.text.items);
    try ed.setText("f( a, (b) )");
    ed.cursor = 3;
    try deleteSurround(&ed, '(', &out);
    try testing.expectEqualStrings("fa, (b)", ed.text.items);
    try ed.setText("<b>hi</b>");
    ed.cursor = 4;
    try deleteSurround(&ed, 't', &out);
    try testing.expectEqualStrings("hi", ed.text.items);
    ed.cursor = 0;
    try deleteSurround(&ed, '{', &out); // nothing to delete
    try testing.expectEqualStrings("hi", ed.text.items);
}

test "cs: from and to resolve through the same table; `<` never pads" {
    var ed = try Editor.init(testing.allocator, "let t = (1, 2); s = \"x\"");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 9;
    try changeSurround(&ed, '(', '<', &out);
    try testing.expectEqualStrings("let t = <1, 2>; s = \"x\"", ed.text.items);
    try testing.expectEqual(@as(usize, 8), ed.cursor);
    ed.cursor = 21;
    try changeSurround(&ed, '"', '\'', &out);
    try testing.expectEqualStrings("let t = <1, 2>; s = 'x'", ed.text.items);
    ed.cursor = 9;
    try changeSurround(&ed, '>', '{', &out);
    try testing.expectEqualStrings("let t = { 1, 2 }; s = 'x'", ed.text.items);
    try changeSurround(&ed, '{', ']', &out);
    try testing.expectEqualStrings("let t = [1, 2]; s = 'x'", ed.text.items);
    try changeSurround(&ed, '[', 't', &out); // a tag needs a name: no-op
    try testing.expectEqualStrings("let t = [1, 2]; s = 'x'", ed.text.items);
}
