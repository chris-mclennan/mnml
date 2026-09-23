//! Indent guides: where the editor view paints a faint rule in a line's
//! leading white space, one per indent step, and which of them is the
//! cursor's own scope.
//!
//! Pure over the text and its line index — the view (`editor_view.zig`)
//! asks, and paints. A blank line takes the smaller of the indents of
//! the nearest non-blank lines above and below it, so a guide runs
//! through the empty lines inside a block and stops at the one after it
//! (the way VS Code and indent-blankline draw them).
//!
//! A guide stands for a whole indent level: the one at column `c` is
//! drawn on a line indented at least `c + step`, so a line pushed in by
//! a stray space or aligned under an open paren past its last level
//! gets no rule in the part that is not a level.
//!
//! The active scope is the block the cursor is in: the deepest guide
//! of the cursor line's indent, over the run of lines around it that
//! carry that guide. On a line that opens a block (the next non-blank
//! line is indented deeper) it is the block that line opens.

const std = @import("std");

/// `editor.indent_guides`.
pub const Mode = enum { off, on, active };

/// How far a scope is looked for in each direction. A block longer
/// than this still paints; its highlight stops here.
const scan_limit: u32 = 5000;

/// The display columns of `line`'s leading white space at tab width
/// `tab_w`, or null when the line is nothing but white space.
pub fn leadingCols(line: []const u8, tab_w: u32) ?u32 {
    const tw = @max(tab_w, 1);
    var cols: u32 = 0;
    for (line) |b| switch (b) {
        ' ' => cols += 1,
        '\t' => cols += tw - (cols % tw),
        '\r' => {},
        else => return cols,
    };
    return null;
}

/// The active guide: its column and the lines (0-based, inclusive) it
/// runs over.
pub const Scope = struct { col: u32, first: u32, last: u32 };

/// One frame's answers. `lines` is anything with `count() u32` and
/// `slice(text, line) []const u8` — the view's `Lines`.
pub fn Frame(comptime L: type) type {
    return struct {
        const Self = @This();

        text: []const u8,
        lines: L,
        tab_w: u32,
        /// Columns per indent level (never 0).
        step: u32,
        active: ?Scope,

        pub fn init(text: []const u8, lines: L, tab_w: u32, step: u32, cursor_line: u32) Self {
            var f: Self = .{ .text = text, .lines = lines, .tab_w = @max(tab_w, 1), .step = @max(step, 1), .active = null };
            f.active = f.scopeAt(cursor_line);
            return f;
        }

        fn raw(f: Self, line: u32) ?u32 {
            return leadingCols(f.lines.slice(f.text, line), f.tab_w);
        }

        /// The indent a line is drawn with: its own, or for a blank line
        /// the smaller of its nearest non-blank neighbours' (0 when
        /// either side runs out).
        pub fn indentOf(f: Self, line: u32) u32 {
            if (f.raw(line)) |c| return c;
            const n = f.lines.count();
            var up: u32 = 0;
            var i = line;
            var steps: u32 = 0;
            while (i > 0 and steps < scan_limit) : (steps += 1) {
                i -= 1;
                if (f.raw(i)) |c| {
                    up = c;
                    break;
                }
            }
            var down: u32 = 0;
            i = line;
            steps = 0;
            while (i + 1 < n and steps < scan_limit) : (steps += 1) {
                i += 1;
                if (f.raw(i)) |c| {
                    down = c;
                    break;
                }
            }
            return @min(up, down);
        }

        /// The next non-blank line after `line`, if one is near.
        fn nextNonBlank(f: Self, line: u32) ?u32 {
            const n = f.lines.count();
            var i = line;
            var steps: u32 = 0;
            while (i + 1 < n and steps < scan_limit) : (steps += 1) {
                i += 1;
                if (f.raw(i) != null) return i;
            }
            return null;
        }

        fn scopeAt(f: Self, cursor_line: u32) ?Scope {
            const n = f.lines.count();
            if (cursor_line >= n) return null;
            var level = f.indentOf(cursor_line);
            var from = cursor_line;
            // On a line that opens a block, the block it opens.
            if (f.raw(cursor_line) != null) if (f.nextNonBlank(cursor_line)) |nx| {
                const deeper = f.raw(nx).?;
                if (deeper > level) {
                    level = deeper;
                    from = nx;
                }
            };
            if (level < f.step) return null;
            const col = (level / f.step - 1) * f.step;
            const need = col + f.step;
            var first = from;
            var steps: u32 = 0;
            while (first > 0 and steps < scan_limit and f.indentOf(first - 1) >= need) : (steps += 1) first -= 1;
            var last = from;
            steps = 0;
            while (last + 1 < n and steps < scan_limit and f.indentOf(last + 1) >= need) : (steps += 1) last += 1;
            return .{ .col = col, .first = first, .last = last };
        }

        /// Whether a guide sits at display column `x` of `line`, whose
        /// drawn indent is `indent`, and whether it is the active one.
        pub fn at(f: Self, mode: Mode, line: u32, indent: u32, x: u32) ?bool {
            if (mode == .off or x + f.step > indent or x % f.step != 0) return null;
            const is_active = if (f.active) |s| x == s.col and line >= s.first and line <= s.last else false;
            if (mode == .active and !is_active) return null;
            return is_active;
        }
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A line index over `text` for the tests (the view's own `Lines` is
/// the same shape).
const TestLines = struct {
    starts: []const usize,
    len: usize,

    fn count(l: TestLines) u32 {
        return @intCast(l.starts.len);
    }
    fn slice(l: TestLines, text: []const u8, line: u32) []const u8 {
        const s = l.starts[line];
        const e = if (line + 1 < l.starts.len) l.starts[line + 1] - 1 else l.len;
        return text[s..e];
    }
};

fn testLines(buf: []usize, text: []const u8) TestLines {
    var n: usize = 1;
    buf[0] = 0;
    for (text, 0..) |b, i| if (b == '\n') {
        buf[n] = i + 1;
        n += 1;
    };
    return .{ .starts = buf[0..n], .len = text.len };
}

test "leading columns: spaces, tabs to the next stop, a blank line is null" {
    try testing.expectEqual(@as(?u32, 4), leadingCols("    x", 4));
    try testing.expectEqual(@as(?u32, 8), leadingCols("\t\tx", 4));
    try testing.expectEqual(@as(?u32, 4), leadingCols("  \tx", 4));
    try testing.expectEqual(@as(?u32, 0), leadingCols("x", 4));
    try testing.expectEqual(@as(?u32, null), leadingCols("   ", 4));
    try testing.expectEqual(@as(?u32, null), leadingCols("", 4));
}

test "a blank line inside a block keeps the block's guides; the one after it does not" {
    const text = "fn a() {\n    if x {\n        y();\n\n        z();\n    }\n\n}\n";
    var buf: [16]usize = undefined;
    // The cursor on the last `}`: no scope, so every guide is a plain one.
    const f = Frame(TestLines).init(text, testLines(&buf, text), 4, 4, 7);
    try testing.expect(f.active == null);
    try testing.expectEqual(@as(u32, 8), f.indentOf(3)); // between y and z
    try testing.expectEqual(@as(u32, 0), f.indentOf(6)); // between } and }
    try testing.expectEqual(@as(?bool, false), f.at(.on, 2, 8, 0));
    try testing.expectEqual(@as(?bool, false), f.at(.on, 2, 8, 4));
    try testing.expectEqual(@as(?bool, null), f.at(.on, 2, 8, 2));
    try testing.expectEqual(@as(?bool, null), f.at(.on, 2, 8, 8));
}

test "the active scope is the block the cursor is in, or the one its line opens" {
    const text = "fn a() {\n    if x {\n        y();\n\n        z();\n    }\n    w();\n}\n";
    var buf: [16]usize = undefined;
    const lines = testLines(&buf, text);
    // On `y();`: the if's body, the guide at column 4, lines 2..4.
    const in_if = Frame(TestLines).init(text, lines, 4, 4, 2);
    try testing.expectEqual(Scope{ .col = 4, .first = 2, .last = 4 }, in_if.active.?);
    try testing.expectEqual(@as(?bool, true), in_if.at(.on, 3, 8, 4));
    try testing.expectEqual(@as(?bool, false), in_if.at(.on, 3, 8, 0));
    // `.active` paints that one guide and no other.
    try testing.expectEqual(@as(?bool, null), in_if.at(.active, 3, 8, 0));
    try testing.expectEqual(@as(?bool, null), in_if.at(.active, 6, 4, 4));
    // On `if x {`: the block it opens, the same guide.
    const on_if = Frame(TestLines).init(text, lines, 4, 4, 1);
    try testing.expectEqual(Scope{ .col = 4, .first = 2, .last = 4 }, on_if.active.?);
    // On `w();`: the function body, the guide at column 0, lines 1..6.
    const in_fn = Frame(TestLines).init(text, lines, 4, 4, 6);
    try testing.expectEqual(Scope{ .col = 0, .first = 1, .last = 6 }, in_fn.active.?);
    // On `fn a() {` itself: the body it opens.
    const on_fn = Frame(TestLines).init(text, lines, 4, 4, 0);
    try testing.expectEqual(Scope{ .col = 0, .first = 1, .last = 6 }, on_fn.active.?);
    // On the closing `}` at column 0: nothing is open.
    const at_end = Frame(TestLines).init(text, lines, 4, 4, 7);
    try testing.expect(at_end.active == null);
}

test "a guide is a whole level: a stray space or an aligned line past its last level gets none" {
    const text = "fn a() {\n call(x,\n      y);\n    z;\n}\n";
    var buf: [8]usize = undefined;
    const f = Frame(TestLines).init(text, testLines(&buf, text), 4, 4, 4);
    // One space: under a level, no guide.
    try testing.expectEqual(@as(?bool, null), f.at(.on, 1, 1, 0));
    // Six: the level at 0 and nothing at 4.
    try testing.expect(f.at(.on, 2, 6, 0) != null);
    try testing.expectEqual(@as(?bool, null), f.at(.on, 2, 6, 4));
    // On `y);` (six) the scope is the level at 0.
    const on_y = Frame(TestLines).init(text, testLines(&buf, text), 4, 4, 2);
    try testing.expectEqual(@as(u32, 0), on_y.active.?.col);
}

test "a two-space file steps by two, a tab-indented one by the tab width" {
    const two = "a:\n  b:\n    c: 1\n";
    var buf: [8]usize = undefined;
    const f2 = Frame(TestLines).init(two, testLines(&buf, two), 4, 2, 2);
    try testing.expectEqual(@as(?bool, false), f2.at(.on, 2, 4, 0));
    try testing.expectEqual(@as(?bool, true), f2.at(.on, 2, 4, 2));
    try testing.expectEqual(@as(?bool, null), f2.at(.on, 2, 4, 1));
    const tabs = "f {\n\tg {\n\t\th\n\t}\n}\n";
    var buf2: [8]usize = undefined;
    const ft = Frame(TestLines).init(tabs, testLines(&buf2, tabs), 4, 4, 2);
    try testing.expectEqual(@as(u32, 8), ft.indentOf(2));
    try testing.expectEqual(@as(?bool, true), ft.at(.on, 2, 8, 4));
}
