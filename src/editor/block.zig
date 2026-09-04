//! Visual block (`ctrl+v`). The rectangle is `block_anchor` → `cursor`
//! in (row, char col); `anchor` mirrors it so the view paints the
//! rectangle. Rows shorter than the left edge contribute an empty range,
//! as vim does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const Clipboard = editor.Clipboard;
const EditOutcome = @import("edit_op.zig").EditOutcome;

/// Inclusive rows and char columns.
pub const Rect = struct { r0: usize, c0: usize, r1: usize, c1: usize };

pub fn rect(ed: *const Editor) ?Rect {
    const a = ed.rowColAt(ed.block_anchor orelse return null);
    const c = ed.rowCol();
    return .{ .r0 = @min(a.row, c.row), .c0 = @min(a.col, c.col), .r1 = @max(a.row, c.row), .c1 = @max(a.col, c.col) };
}

/// One `[start, end)` per row, top to bottom; clamped to each line.
pub fn ranges(ed: *const Editor, r: Rect, gpa: Allocator) Allocator.Error![][2]usize {
    const last = @min(r.r1, ed.lineCount() - 1);
    const out = try gpa.alloc([2]usize, last + 1 - r.r0);
    for (out, r.r0..) |*o, row| {
        const s = ed.byteAtCol(row, r.c0);
        o.* = .{ s, @max(ed.byteAtCol(row, r.c1 + 1), s) };
    }
    return out;
}

pub fn selectStart(ed: *Editor) void {
    ed.block_anchor = ed.cursor;
    ed.anchor = ed.cursor;
}

pub fn selectClear(ed: *Editor) void {
    ed.block_anchor = null;
    ed.anchor = null;
}

fn joined(ed: *const Editor, rs: []const [2]usize) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ed.gpa);
    for (rs, 0..) |r, i| {
        if (i > 0) try out.append(ed.gpa, '\n');
        try out.appendSlice(ed.gpa, ed.bytes()[r[0]..r[1]]);
    }
    return out.toOwnedSlice(ed.gpa);
}

/// `y` on a block: the rows joined by `\n`, charwise.
pub fn yankBlock(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const r = rect(ed) orelse return;
    const rs = try ranges(ed, r, ed.gpa);
    defer ed.gpa.free(rs);
    const text = try joined(ed, rs);
    defer ed.gpa.free(text);
    try clip.setYank(text, false);
    out.clipboard_set = clip.lastWritten();
    out.yanked_range = .{ rs[0][0], rs[rs.len - 1][1] };
    ed.cursor = ed.byteAtCol(r.r0, r.c0);
    selectClear(ed);
}

/// `d` / `x` on a block: yank, then cut every row's slice; the cursor
/// parks at the rectangle's top-left.
pub fn deleteBlock(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const r = rect(ed) orelse return;
    const rs = try ranges(ed, r, ed.gpa);
    defer ed.gpa.free(rs);
    const text = try joined(ed, rs);
    defer ed.gpa.free(text);
    try clip.pushDelete(text, false);
    out.clipboard_set = clip.lastWritten();
    try ed.checkpoint();
    var i = rs.len;
    while (i > 0) {
        i -= 1;
        if (rs[i][1] > rs[i][0]) try ed.splice(rs[i][0], rs[i][1], "");
    }
    ed.cursor = ed.byteAtCol(r.r0, r.c0);
    selectClear(ed);
    out.buffer_changed = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "block yank joins the rows; delete cuts them; short rows contribute nothing" {
    var clip = Clipboard.init(testing.allocator);
    defer clip.deinit();
    var ed = try Editor.init(testing.allocator, "abcdef\ngh\nmnopqr\nstuvwx");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 1;
    selectStart(&ed);
    try testing.expectEqual(@as(?usize, 1), ed.anchor);
    ed.placeCursor(2, 2);
    try yankBlock(&ed, &clip, &out);
    try testing.expectEqualStrings("bc\nh\nno", out.clipboard_set.?);
    try testing.expectEqual([2]usize{ 1, 13 }, out.yanked_range.?);
    try testing.expect(ed.block_anchor == null and ed.anchor == null);
    try testing.expectEqual(@as(usize, 1), ed.cursor);
    selectStart(&ed);
    ed.placeCursor(3, 2);
    try deleteBlock(&ed, &clip, &out);
    try testing.expectEqualStrings("adef\ng\nmpqr\nsvwx", ed.text.items);
    try testing.expectEqualStrings("bc\nh\nno\ntu", clip.text());
    try testing.expectEqual(@as(usize, 1), ed.cursor);
    try testing.expect(out.buffer_changed);
}
