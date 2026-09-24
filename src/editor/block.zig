//! Visual block (`ctrl+v`). The rectangle is `block_anchor` → `cursor`
//! in rows and DISPLAY columns — cells, a tab and a wide glyph at their
//! width — so the block is the one on screen; `anchor` mirrors it so the
//! view paints the rectangle. A row narrower than the left edge
//! contributes nothing, as in vim. With `block_eol` (`$`) every row runs
//! to its own end. A wide glyph the block's edge cuts through is split
//! the way Neovim splits it: `d` leaves its outside part as spaces, `y`
//! takes its inside part as spaces.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const Clipboard = editor.Clipboard;
const EditOutcome = @import("edit_op.zig").EditOutcome;
const CaseTransform = @import("edit_op.zig").CaseTransform;
const line_ops = @import("line.zig");

/// Inclusive rows and display columns.
pub const Rect = struct { r0: usize, c0: usize, r1: usize, c1: usize };

/// The rectangle from `anchor` to the cursor: each end's character is
/// counted whole, so a wide glyph under either widens the block to it.
pub fn rectFrom(ed: *const Editor, anchor: usize) Rect {
    const a_row = ed.lineOfByte(anchor);
    const c_row = ed.currentLine();
    const av = ed.vcolAtByte(anchor);
    const cv = ed.vcolAtByte(ed.cursor);
    const aw = @max(ed.doc.cellsAt(anchor, av), 1);
    const cw = @max(ed.doc.cellsAt(ed.cursor, cv), 1);
    return .{ .r0 = @min(a_row, c_row), .c0 = @min(av, cv), .r1 = @max(a_row, c_row), .c1 = @max(av + aw, cv + cw) - 1 };
}

pub fn rect(ed: *const Editor) ?Rect {
    return rectFrom(ed, ed.block_anchor orelse return null);
}

/// One row's share of a rectangle. `[s, e)` holds every character whose
/// cells meet `[c0, c1]`; `[inner_s, inner_e)` the ones wholly inside.
/// A straddling first / last character leaves `pre_out` / `post_out`
/// cells outside the block and `pre_in` / `post_in` inside it. `short`:
/// the row ends before `c0`.
pub const Span = struct {
    s: usize,
    e: usize,
    inner_s: usize,
    inner_e: usize,
    pre_out: usize = 0,
    post_out: usize = 0,
    pre_in: usize = 0,
    post_in: usize = 0,
    short: bool = false,
};

pub fn span(ed: *const Editor, row: usize, c0: usize, c1: usize, to_eol: bool) Span {
    const doc = ed.doc;
    const end = doc.lineEnd(row);
    var b = doc.lineStart(row);
    var v: usize = 0;
    while (b < end) {
        const w = doc.cellsAt(b, v);
        if (v + w > c0) break;
        v += w;
        b = doc.nextBoundary(b);
    }
    if (b >= end) return .{ .s = end, .e = end, .inner_s = end, .inner_e = end, .short = v < c0 };
    var out: Span = .{ .s = b, .e = b, .inner_s = b, .inner_e = b };
    if (v < c0) {
        // The first character starts left of the block.
        const w = doc.cellsAt(b, v);
        out.pre_out = c0 - v;
        out.pre_in = @min(v + w, c1 + 1) - c0;
        v += w;
        b = doc.nextBoundary(b);
        out.inner_s = b;
    }
    out.inner_e = out.inner_s;
    while (b < end and (to_eol or v <= c1)) {
        const w = doc.cellsAt(b, v);
        if (!to_eol and v + w > c1 + 1) {
            // The last character runs past the block's right edge.
            out.post_in = c1 + 1 - v;
            out.post_out = v + w - (c1 + 1);
            b = doc.nextBoundary(b);
            break;
        }
        v += w;
        b = doc.nextBoundary(b);
        out.inner_e = b;
    }
    if (out.pre_out > 0 and out.inner_e < out.inner_s) out.inner_e = out.inner_s;
    // One character cut on both sides: its inside is the whole block.
    if (out.pre_out > 0 and out.post_out == 0 and out.inner_e == out.inner_s and b == out.inner_s and !to_eol) {
        const first_end = v;
        if (first_end > c1 + 1) {
            out.post_out = first_end - (c1 + 1);
            out.pre_in = c1 + 1 - c0;
        }
    }
    out.e = b;
    return out;
}

/// One `[start, end)` per row, top to bottom — the bytes each row's slice
/// touches (a cut glyph included); to each line's end under `block_eol`.
pub fn ranges(ed: *const Editor, r: Rect, gpa: Allocator) Allocator.Error![][2]usize {
    // A rect whose rows outran the text (a stale anchor) still names at
    // least its last row: no caller can take an empty list.
    const last = @min(r.r1, ed.lineCount() - 1);
    const first = @min(r.r0, last);
    const out = try gpa.alloc([2]usize, last + 1 - first);
    for (out, first..) |*o, row| {
        const sp = span(ed, row, r.c0, r.c1, ed.block_eol);
        o.* = .{ sp.s, sp.e };
    }
    return out;
}

pub fn selectStart(ed: *Editor) void {
    ed.block_anchor = ed.cursor;
    ed.anchor = ed.cursor;
    ed.block_eol = false;
}

pub fn selectClear(ed: *Editor) void {
    remember(ed);
    ed.block_anchor = null;
    ed.anchor = null;
    ed.block_eol = false;
}

/// `gv` brings the rectangle back (`:help gv`) — taken before an
/// operator parks the cursor at the top-left corner.
fn remember(ed: *Editor) void {
    if (ed.block_anchor) |a| {
        if (a != ed.cursor) ed.last_selection = .{ a, ed.cursor };
    }
}

fn appendSpaces(gpa: Allocator, out: *std.ArrayList(u8), n: usize) Allocator.Error!void {
    try out.appendNTimes(gpa, ' ', n);
}

/// What `y` takes from each row, joined by `\n`: the cells inside the
/// block, a cut glyph's inside part as spaces.
fn joined(ed: *const Editor, r: Rect) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ed.gpa);
    const last = @min(r.r1, ed.lineCount() - 1);
    var row = @min(r.r0, last);
    while (row <= last) : (row += 1) {
        if (row > r.r0) try out.append(ed.gpa, '\n');
        const sp = span(ed, row, r.c0, r.c1, ed.block_eol);
        try appendSpaces(ed.gpa, &out, sp.pre_in);
        try out.appendSlice(ed.gpa, ed.bytes()[sp.inner_s..@max(sp.inner_s, sp.inner_e)]);
        try appendSpaces(ed.gpa, &out, sp.post_in);
    }
    return out.toOwnedSlice(ed.gpa);
}

/// Cut the rectangle out of every row, bottom-up so earlier offsets hold;
/// a cut glyph leaves its outside cells as spaces. The caller owns the
/// checkpoint.
pub fn cutRows(ed: *Editor, r: Rect, to_eol: bool) Allocator.Error!void {
    const last = @min(r.r1, ed.lineCount() - 1);
    var row = last + 1;
    var pad: [64]u8 = @splat(' ');
    while (row > r.r0) {
        row -= 1;
        const sp = span(ed, row, r.c0, r.c1, to_eol);
        if (sp.e <= sp.s) continue;
        const n = @min(sp.pre_out + sp.post_out, pad.len);
        try ed.splice(sp.s, sp.e, pad[0..n]);
    }
}

/// `y` on a block: the rows joined by `\n`, charwise.
pub fn yankBlock(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const r = rect(ed) orelse return;
    remember(ed);
    const rs = try ranges(ed, r, ed.gpa);
    defer ed.gpa.free(rs);
    const text = try joined(ed, r);
    defer ed.gpa.free(text);
    try clip.setYankBlock(text);
    out.clipboard_set = clip.lastWritten();
    out.yanked_range = .{ rs[0][0], rs[rs.len - 1][1] };
    ed.cursor = ed.byteAtVcol(r.r0, r.c0);
    selectClear(ed);
}

/// `d` / `x` on a block: yank, then cut every row's slice; the cursor
/// parks at the rectangle's top-left.
pub fn deleteBlock(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const r = rect(ed) orelse return;
    remember(ed);
    const text = try joined(ed, r);
    defer ed.gpa.free(text);
    try clip.pushDeleteBlock(text);
    out.clipboard_set = clip.lastWritten();
    try ed.checkpoint();
    try cutRows(ed, r, ed.block_eol);
    ed.cursor = ed.byteAtVcol(r.r0, r.c0);
    selectClear(ed);
    out.buffer_changed = true;
}

/// `U` / `u` / `~` on a block (`:help v_U`): the case of every
/// character inside the rectangle, ASCII letters as the charwise form
/// does. The cursor parks at the top-left.
pub fn transformCase(ed: *Editor, kind: CaseTransform, out: *EditOutcome) Allocator.Error!void {
    const r = rect(ed) orelse return;
    remember(ed);
    const last = @min(r.r1, ed.lineCount() - 1);
    var cp = false;
    var row = @min(r.r0, last);
    while (row <= last) : (row += 1) {
        const sp = span(ed, row, r.c0, r.c1, ed.block_eol);
        var b = sp.inner_s;
        while (b < sp.inner_e) : (b += 1) {
            const c = ed.bytes()[b];
            const t = switch (kind) {
                .lower => std.ascii.toLower(c),
                .upper => std.ascii.toUpper(c),
                .toggle => if (std.ascii.isUpper(c)) std.ascii.toLower(c) else std.ascii.toUpper(c),
            };
            if (t == c) continue;
            if (!cp) {
                try ed.checkpoint();
                cp = true;
            }
            try ed.splice(b, b + 1, &.{t});
            out.buffer_changed = true;
        }
    }
    ed.cursor = ed.byteAtVcol(r.r0, r.c0);
    selectClear(ed);
}

/// `>` / `<` on a block (`:help v_b_>`): every row is shifted from the
/// block's left edge — the white space there grows (or, for `<`,
/// shrinks) by `count` shift widths, the text after it moving with it
/// — and is written again as tabs to the tab stops then spaces under
/// `use_tabs`, else spaces. A row that ends before the edge is left
/// alone. The cursor parks at the top-left.
pub fn shift(ed: *Editor, left: bool, count: u32, out: *EditOutcome) Allocator.Error!void {
    const r = rect(ed) orelse return;
    remember(ed);
    const unit = @max(ed.doc.tab_width, 1);
    const total = unit * @max(count, 1);
    const last = @min(r.r1, ed.lineCount() - 1);
    var cp = false;
    var fill: std.ArrayList(u8) = .empty;
    defer fill.deinit(ed.gpa);
    var row = last + 1;
    while (row > r.r0) {
        row -= 1;
        const start = ed.byteAtVcol(row, r.c0);
        const line_end = ed.lineEnd(row);
        if (start >= line_end) continue;
        const from = ed.vcolAtByte(start);
        var ws_end = start;
        while (ws_end < line_end and (ed.bytes()[ws_end] == ' ' or ed.bytes()[ws_end] == '\t')) ws_end += 1;
        const width = ed.vcolAtByte(ws_end) - from;
        if (left and width == 0) continue;
        const to = from + (if (left) width -| total else width + total);
        fill.clearRetainingCapacity();
        var v = from;
        if (ed.doc.use_tabs) while (true) {
            const stop = (v / unit + 1) * unit;
            if (stop > to) break;
            try fill.append(ed.gpa, '\t');
            v = stop;
        };
        try fill.appendNTimes(ed.gpa, ' ', to - v);
        if (std.mem.eql(u8, fill.items, ed.bytes()[start..ws_end])) continue;
        if (!cp) {
            try ed.checkpoint();
            cp = true;
        }
        try ed.splice(start, ws_end, fill.items);
        out.buffer_changed = true;
    }
    ed.cursor = ed.byteAtVcol(r.r0, r.c0);
    selectClear(ed);
}

/// `J` / `gJ` on a block: the rows it spans joined, as `V…J` joins them
/// (two rows at least).
pub fn join(ed: *Editor, keep_space: bool, out: *EditOutcome) Allocator.Error!void {
    const r = rect(ed) orelse return;
    remember(ed);
    ed.cursor = ed.lineStart(r.r0);
    selectClear(ed);
    const joins = @max(r.r1 - r.r0, 1);
    // One undo step, as vim's `J` over a range.
    const tok = try ed.beginAtomic();
    defer ed.endAtomic(tok);
    for (0..joins) |_| try line_ops.joinLines(ed, keep_space, out);
}

/// `O` in a block (`:help v_b_O`): the cursor goes to the other end of
/// its own row, and the anchor to the other end of its row, so the
/// same rectangle grows from the corner beside the cursor.
pub fn otherEndOfRow(ed: *Editor) void {
    const a = ed.block_anchor orelse return;
    const a_row = ed.lineOfByte(a);
    const c_row = ed.currentLine();
    const av = ed.vcolAtByte(a);
    const cv = ed.vcolAtByte(ed.cursor);
    const na = ed.byteAtVcol(a_row, cv);
    ed.cursor = ed.byteAtVcol(c_row, av);
    ed.block_anchor = na;
    ed.anchor = na;
    ed.goal_col = null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "block_eol runs every row to its end; a new block drops it" {
    var clip = Clipboard.init(testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(testing.allocator, "abcdef\ngh\nmnop");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 1;
    selectStart(ed);
    ed.placeCursor(2, 1);
    ed.block_eol = true;
    try yankBlock(ed, &clip, &out);
    try testing.expectEqualStrings("bcdef\nh\nnop", out.clipboard_set.?);
    try testing.expect(!ed.block_eol);
    selectStart(ed);
    ed.placeCursor(1, 1);
    ed.block_eol = true;
    try deleteBlock(ed, &clip, &out);
    try testing.expectEqualStrings("a\ng\nmnop", ed.doc.text.items);
    try testing.expect(!ed.block_eol);
}

test "block yank joins the rows; delete cuts them; short rows contribute nothing" {
    var clip = Clipboard.init(testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(testing.allocator, "abcdef\ngh\nmnopqr\nstuvwx");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 1;
    selectStart(ed);
    try testing.expectEqual(@as(?usize, 1), ed.anchor);
    ed.placeCursor(2, 2);
    try yankBlock(ed, &clip, &out);
    try testing.expectEqualStrings("bc\nh\nno", out.clipboard_set.?);
    try testing.expectEqual([2]usize{ 1, 13 }, out.yanked_range.?);
    try testing.expect(ed.block_anchor == null and ed.anchor == null);
    try testing.expectEqual(@as(usize, 1), ed.cursor);
    selectStart(ed);
    ed.placeCursor(3, 2);
    try deleteBlock(ed, &clip, &out);
    try testing.expectEqualStrings("adef\ng\nmpqr\nsvwx", ed.doc.text.items);
    try testing.expectEqualStrings("bc\nh\nno\ntu", clip.text());
    try testing.expectEqual(@as(usize, 1), ed.cursor);
    try testing.expect(out.buffer_changed);
}

test "a block is display columns: a wide glyph cut by an edge splits the way Neovim splits it" {
    var clip = Clipboard.init(testing.allocator);
    defer clip.deinit();
    // Neovim 0.12.5: `2l<C-v>2jld` on `abcdef / 中文字 / x中yz` gives
    // `abef / 中字 / x z`; `…y` yanks `cd / 文 / " y"`.
    const ed = try Editor.init(testing.allocator, "abcdef\n中文字\nx中yz");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.cursor = 2;
    selectStart(ed);
    ed.cursor = ed.byteAtVcol(2, 3);
    try yankBlock(ed, &clip, &out);
    try testing.expectEqualStrings("cd\n文\n y", out.clipboard_set.?);
    ed.cursor = 2;
    selectStart(ed);
    ed.cursor = ed.byteAtVcol(2, 3);
    try deleteBlock(ed, &clip, &out);
    try testing.expectEqualStrings("abef\n中字\nx z", ed.doc.text.items);
}

test "a block yank or delete is a blockwise register: p / P lay its rows out as a column" {
    const register = @import("register.zig");
    var clip = Clipboard.init(testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(testing.allocator, "abcd\nefgh\nijkl\nmnop\n");
    defer ed.deinit();
    var out: EditOutcome = .{};
    // `l<C-v>jjly` then `P`: the column goes back in front of itself.
    ed.cursor = 1;
    selectStart(ed);
    ed.placeCursor(2, 2);
    try yankBlock(ed, &clip, &out);
    try register.pasteBefore(ed, &clip, &out);
    try testing.expectEqualStrings("abcbcd\nefgfgh\nijkjkl\nmnop\n", ed.doc.text.items);
    try testing.expectEqual(@as(usize, 1), ed.cursor);
    // `l<C-v>jjld`, then `p` after the `n` of the last line: rows past the
    // end open new lines, padded out to the column.
    try ed.setText("abcd\nefgh\nijkl\nmnop\n");
    ed.cursor = 1;
    selectStart(ed);
    ed.placeCursor(2, 2);
    try deleteBlock(ed, &clip, &out);
    try testing.expectEqualStrings("ad\neh\nil\nmnop\n", ed.doc.text.items);
    ed.placeCursor(3, 1);
    try register.pasteAfter(ed, &clip, &out);
    try testing.expectEqualStrings("ad\neh\nil\nmnbcop\n  fg\n  jk\n", ed.doc.text.items);
    // A charwise yank after it puts inline again.
    try clip.setYank("Q", false);
    try register.pasteAfter(ed, &clip, &out);
    try testing.expect(!clip.isBlockwise());
}
