//! Yank and put. Linewise payloads always end in `\n`; `paste_after`
//! on the buffer's last line re-shapes the payload so no phantom line
//! appears.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Editor = editor.Editor;
const Clipboard = editor.Clipboard;
const edit_op = @import("edit_op.zig");
const EditOp = edit_op.EditOp;
const EditOutcome = edit_op.EditOutcome;
const delete = @import("delete.zig");
const mc = @import("multicursor.zig");

pub fn setRegisterHint(clip: *Clipboard, reg: ?u21) void {
    clip.setPendingRegister(reg);
}

/// `yy`.
pub fn yankLine(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try yankLinesCount(ed, 1, clip, out);
}

/// `<n>yy` / `y<n>j`: `n` lines from the cursor, linewise.
pub fn yankLinesCount(ed: *Editor, n: u32, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    if (n == 0) return;
    const first = ed.currentLine();
    const last = @min(first + n - 1, ed.lineCount() - 1);
    const start = ed.lineStart(first);
    const last_end = ed.lineEnd(last);
    const end = if (last_end < ed.len()) last_end + 1 else last_end;
    const body = ed.bytes()[start..end];
    if (body.len > 0 and body[body.len - 1] == '\n') {
        try clip.setYank(body, true);
    } else {
        const s = try std.mem.concat(ed.gpa, u8, &.{ body, "\n" });
        defer ed.gpa.free(s);
        try clip.setYank(s, true);
    }
    out.clipboard_set = clip.lastWritten();
    out.clipboard_linewise = true;
    out.yanked_range = .{ start, end };
}

pub fn yankSelection(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    if (mc.hasExtras(ed)) {
        // Every cursor's range joined by `\n`; each extra's selection ends.
        const text = (try mc.joinedSelections(ed)) orelse return;
        defer ed.gpa.free(text);
        try clip.setYank(text, false);
        out.clipboard_set = clip.lastWritten();
        out.yanked_range = mc.selectionsExtent(ed);
        ed.rememberSelection();
        mc.clearExtraAnchors(ed);
        return;
    }
    const sel = ed.selection() orelse return;
    try clip.setYank(ed.bytes()[sel[0]..sel[1]], false);
    out.clipboard_set = clip.lastWritten();
    out.yanked_range = sel;
    ed.rememberSelection();
}

/// V-mode yank: marks the register linewise so `p` opens a new line.
pub fn yankSelectionLinewise(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const sel = ed.selection() orelse return;
    const body = ed.bytes()[sel[0]..sel[1]];
    if (body.len > 0 and body[body.len - 1] == '\n') {
        try clip.setYank(body, true);
    } else {
        const s = try std.mem.concat(ed.gpa, u8, &.{ body, "\n" });
        defer ed.gpa.free(s);
        try clip.setYank(s, true);
    }
    out.clipboard_set = clip.lastWritten();
    out.clipboard_linewise = true;
    out.yanked_range = sel;
    ed.rememberSelection();
}

const Where = enum { after, before };
const Land = enum { start, end };

fn put(ed: *Editor, clip: *Clipboard, where: Where, land: Land, out: *EditOutcome) Allocator.Error!void {
    return putTimes(ed, clip, where, land, 1, out);
}

/// `[count]p`: the register `times` times in a row, as ONE put (`:help
/// p`) — a put per iteration would re-anchor after every copy and
/// interleave (`2yy3p` grouping the copies per line, `yiw3p` sprinkling
/// the word between the next chars).
pub fn putTimes(ed: *Editor, clip: *Clipboard, where: Where, land: Land, times: u32, out: *EditOutcome) Allocator.Error!void {
    const one = clip.text();
    if (one.len == 0 or times == 0) return;
    if (clip.isBlockwise() and !mc.hasExtras(ed)) return putBlock(ed, one, where, land, times, out);
    const repeated: ?[]u8 = if (times > 1) blk: {
        const buf = try ed.gpa.alloc(u8, one.len * times);
        for (0..times) |i| @memcpy(buf[i * one.len ..][0..one.len], one);
        break :blk buf;
    } else null;
    defer if (repeated) |r| ed.gpa.free(r);
    const s: []const u8 = repeated orelse one;
    try ed.checkpoint();
    if (mc.hasExtras(ed)) {
        try putAll(ed, s, where == .after);
        out.buffer_changed = true;
        return;
    }
    if (clip.isLinewise()) {
        _ = try putLines(ed, s, where, land);
    } else {
        // `p` puts after the char under the cursor; on an empty line (or
        // past the end) there is none, and vim puts at the cursor — not
        // after the `\n`, onto the next line.
        const on_newline = ed.cursor >= ed.len() or ed.bytes()[ed.cursor] == '\n';
        const at = if (where == .after and !on_newline) @min(ed.nextBoundary(ed.cursor), ed.len()) else ed.cursor;
        try ed.splice(at, at, s);
        ed.cursor = at + s.len;
    }
    ed.anchor = null;
    out.buffer_changed = true;
}

/// A blockwise register (`:help blockwise-register`): its rows go into
/// the cursor's line and the ones below, all at one display column —
/// after the cursor's char (`p`) or at it (`P`) — with lines added past
/// the end of the buffer and a line too short for the column padded out
/// with spaces. A row narrower than the block is padded to its width
/// when text follows it, so the column stays straight; `{count}p` puts
/// each row `count` times side by side. The cursor lands on the block's
/// top-left (`gp`: just after its bottom-right).
fn putBlock(ed: *Editor, s: []const u8, where: Where, land: Land, times: u32, out: *EditOutcome) Allocator.Error!void {
    const gpa = ed.gpa;
    var rows: std.ArrayList([]const u8) = .empty;
    defer rows.deinit(gpa);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |r| try rows.append(gpa, r);
    var width: usize = 0;
    for (rows.items) |r| width = @max(width, textCells(r));
    const row0 = ed.currentLine();
    const on_char = ed.cursor < ed.lineEnd(row0);
    const cur_v = ed.vcolAtByte(ed.cursor);
    const col = if (where == .after and on_char) cur_v + ed.doc.cellsAt(ed.cursor, cur_v) else cur_v;
    try ed.checkpoint();
    // Enough lines below for every row. `lineCount` leaves out the
    // phantom line after a final `\n`, so each `\n` appended adds one
    // (the first only ends the last line when there was no final `\n`).
    const last_needed = row0 + rows.items.len - 1;
    while (ed.lineCount() <= last_needed) {
        const n = ed.len();
        try ed.splice(n, n, "\n");
    }
    var piece: std.ArrayList(u8) = .empty;
    defer piece.deinit(gpa);
    var top_left: usize = 0;
    var end_at: usize = 0;
    for (rows.items, 0..) |r, i| {
        const line = row0 + i;
        const have = ed.doc.lineVcols(line);
        const eol = ed.lineEnd(line);
        piece.clearRetainingCapacity();
        const at = if (have < col) eol else ed.byteAtVcol(line, col);
        if (have < col) try piece.appendNTimes(gpa, ' ', col - have);
        const lead = piece.items.len;
        const w = textCells(r);
        const text_after = at < eol;
        for (0..times) |k| {
            try piece.appendSlice(gpa, r);
            if (k + 1 < times or text_after) try piece.appendNTimes(gpa, ' ', width -| w);
        }
        try ed.splice(at, at, piece.items);
        if (i == 0) top_left = at + lead;
        end_at = at + piece.items.len;
    }
    ed.cursor = if (land == .start) top_left else @min(end_at, ed.len());
    ed.anchor = null;
    ed.goal_col = null;
    out.buffer_changed = true;
}

/// Display cells a register row takes (no tabs expand: a block yank
/// already took the cells it cut as spaces).
fn textCells(r: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < r.len) {
        const len = std.unicode.utf8ByteSequenceLength(r[i]) catch 1;
        const end = @min(i + len, r.len);
        n += if (r[i] < 0x80) 1 else @min(@import("vaxis").gwidth.gwidth(r[i..end], .unicode), 2);
        i = end;
    }
    return n;
}

/// A linewise payload `s` below (`after`) or above the cursor's line;
/// returns the line its first line landed on.
fn putLines(ed: *Editor, s: []const u8, where: Where, land: Land) Allocator.Error!usize {
    const line = ed.currentLine();
    if (where == .after) {
        const eol = ed.lineEnd(line);
        const at_eof = eol >= ed.len();
        const insert_at = if (at_eof) eol else eol + 1;
        if (at_eof and ed.len() > 0) {
            // No `\n` to put after: open a line with `\n` + payload
            // minus its own terminator.
            const trimmed = if (s[s.len - 1] == '\n') s[0 .. s.len - 1] else s;
            const payload = try std.mem.concat(ed.gpa, u8, &.{ "\n", trimmed });
            defer ed.gpa.free(payload);
            try ed.splice(insert_at, insert_at, payload);
            ed.cursor = if (land == .start) insert_at + 1 else insert_at + payload.len;
        } else {
            try ed.splice(insert_at, insert_at, s);
            ed.cursor = if (land == .start) insert_at else insert_at + s.len;
        }
        return line + 1;
    }
    const bol = ed.lineStart(line);
    try ed.splice(bol, bol, s);
    ed.cursor = if (land == .start) bol else bol + s.len;
    return line;
}

/// `[count]]p` / `[count][p` (`:help ]p`): a linewise register put with
/// its lines shifted so the first non-empty one takes the cursor line's
/// indent, the rest keeping their indent relative to it (never below
/// column 0). Empty lines stay empty. The indent is rebuilt from
/// columns — tabs at `tab_width` under `use_tabs`, else spaces. A
/// charwise register is a plain `p` / `P`. The cursor lands on the
/// first put line's first non-blank.
pub fn putIndentedTimes(ed: *Editor, clip: *Clipboard, where: Where, times: u32, out: *EditOutcome) Allocator.Error!void {
    const one = clip.text();
    if (one.len == 0 or times == 0) return;
    if (!clip.isLinewise() or mc.hasExtras(ed)) return putTimes(ed, clip, where, .start, times, out);
    const tw = @max(ed.doc.tab_width, 1);
    const target: isize = @intCast(indentCols(ed.leadingIndent(ed.currentLine(), null), tw));
    const body = if (one[one.len - 1] == '\n') one[0 .. one.len - 1] else one;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(ed.gpa);
    // The shift is fixed by the first non-empty line of the first copy
    // and holds for every copy after it.
    var diff: ?isize = null;
    for (0..times) |_| {
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |ln| {
            if (ln.len > 0) {
                const lead = ln.len - std.mem.trimStart(u8, ln, " \t").len;
                const have: isize = @intCast(indentCols(ln[0..lead], tw));
                const d = diff orelse blk: {
                    diff = target - have;
                    break :blk target - have;
                };
                try appendIndent(ed, &payload, @intCast(@max(have + d, 0)), tw);
                try payload.appendSlice(ed.gpa, ln[lead..]);
            }
            try payload.append(ed.gpa, '\n');
        }
    }
    try ed.checkpoint();
    const first = try putLines(ed, payload.items, where, .start);
    ed.cursor = ed.firstNonWs(first);
    ed.goal_col = null;
    ed.anchor = null;
    out.buffer_changed = true;
}

/// The display width of an indent run, tabs advancing to the next stop.
fn indentCols(lead: []const u8, tw: usize) usize {
    var cols: usize = 0;
    for (lead) |b| cols = if (b == '\t') (cols / tw + 1) * tw else cols + 1;
    return cols;
}

fn appendIndent(ed: *Editor, list: *std.ArrayList(u8), cols: usize, tw: usize) Allocator.Error!void {
    var left = cols;
    if (ed.doc.use_tabs) {
        try list.appendNTimes(ed.gpa, '\t', left / tw);
        left %= tw;
    }
    try list.appendNTimes(ed.gpa, ' ', left);
}

/// Multi-cursor put: a clipboard with exactly one line per cursor is
/// distributed (vim's block-paste convention); anything else lands whole
/// at every cursor. Every selection ends.
fn putAll(ed: *Editor, s: []const u8, after: bool) Allocator.Error!void {
    const total = ed.extra_cursors.items.len + 1;
    if (std.mem.count(u8, s, "\n") + 1 == total) {
        const parts = try ed.gpa.alloc([]const u8, total);
        defer ed.gpa.free(parts);
        var it = std.mem.splitScalar(u8, s, '\n');
        for (parts) |*p| p.* = it.next().?;
        try mc.pasteDistribute(ed, parts, after);
    } else {
        try mc.insertStrAll(ed, s);
    }
    ed.anchor = null;
    mc.clearExtraAnchors(ed);
}

/// The put a `repeat` wraps, run once with its count — see `putTimes`.
pub fn putRepeated(ed: *Editor, op: EditOp, times: u32, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    return switch (op) {
        .paste_after => putTimes(ed, clip, .after, .start, times, out),
        .paste_before => putTimes(ed, clip, .before, .start, times, out),
        .paste_after_end => putTimes(ed, clip, .after, .end, times, out),
        .paste_before_end => putTimes(ed, clip, .before, .end, times, out),
        .paste_after_indent => putIndentedTimes(ed, clip, .after, times, out),
        .paste_before_indent => putIndentedTimes(ed, clip, .before, times, out),
        else => unreachable,
    };
}

pub fn isPut(op: EditOp) bool {
    return switch (op) {
        .paste_after, .paste_before, .paste_after_end, .paste_before_end, .paste_after_indent, .paste_before_indent => true,
        else => false,
    };
}

/// `p`.
pub fn pasteAfter(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try put(ed, clip, .after, .start, out);
}

/// `P`.
pub fn pasteBefore(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    // Charwise `P` lands after the text like Rust mnml; linewise at the
    // line start.
    try put(ed, clip, .before, .start, out);
}

/// `gp`.
pub fn pasteAfterEnd(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try put(ed, clip, .after, .end, out);
}

/// `gP`.
pub fn pasteBeforeEnd(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try put(ed, clip, .before, .end, out);
}

/// `]p`.
pub fn pasteAfterIndent(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try putIndentedTimes(ed, clip, .after, 1, out);
}

/// `[p` / `[P` / `]P`.
pub fn pasteBeforeIndent(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    try putIndentedTimes(ed, clip, .before, 1, out);
}

/// Modeless paste: replaces the selection, inserts at the cursor.
pub fn paste(ed: *Editor, clip: *Clipboard, out: *EditOutcome) Allocator.Error!void {
    const s = clip.text();
    if (s.len == 0) return;
    if (!try delete.deleteSelectionIfAny(ed, out)) try ed.checkpoint();
    try ed.splice(ed.cursor, ed.cursor, s);
    ed.cursor += s.len;
    ed.anchor = null;
    out.buffer_changed = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

test "yy then p opens a line below; P above; on the last line no phantom line" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(std.testing.allocator, "a\nb");
    defer ed.deinit();
    var out: EditOutcome = .{};
    try yankLine(ed, &clip, &out);
    try std.testing.expectEqualStrings("a\n", out.clipboard_set.?);
    try std.testing.expectEqual([2]usize{ 0, 2 }, out.yanked_range.?);
    try pasteAfter(ed, &clip, &out);
    try std.testing.expectEqualStrings("a\na\nb", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor);
    ed.cursor = 4; // on `b`, the last line
    try pasteAfter(ed, &clip, &out);
    try std.testing.expectEqualStrings("a\na\nb\na", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
    try pasteBefore(ed, &clip, &out);
    try std.testing.expectEqualStrings("a\na\nb\na\na", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor);
}

test "charwise yank/put and modeless paste over a selection" {
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(std.testing.allocator, "hello");
    defer ed.deinit();
    var out: EditOutcome = .{};
    ed.anchor = 0;
    ed.cursor = 2;
    try yankSelection(ed, &clip, &out);
    try std.testing.expectEqualStrings("he", out.clipboard_set.?);
    ed.anchor = null;
    ed.cursor = 4;
    try pasteAfter(ed, &clip, &out);
    try std.testing.expectEqualStrings("hellohe", ed.doc.text.items);
    try std.testing.expectEqual(@as(usize, 7), ed.cursor);
    ed.anchor = 0;
    ed.cursor = 5;
    try paste(ed, &clip, &out);
    try std.testing.expectEqualStrings("hehe", ed.doc.text.items);
    try yankLinesCount(ed, 3, &clip, &out);
    try std.testing.expectEqualStrings("hehe\n", clip.text());
}

/// Runs `op` through `Editor.apply` — the path a keystroke takes.
fn applyOp(ed: *Editor, clip: *Clipboard, op: EditOp) !EditOutcome {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    return ed.apply(op, 10, clip, arena_state.allocator());
}

fn cursorRowCol(ed: *const Editor) [2]usize {
    const row = ed.currentLine();
    return .{ row, ed.cursor - ed.lineStart(row) };
}

test "put-indent ]p: a 2-space block put under an 8-space line takes its indent, the inner line keeps +2" {
    // Neovim 0.12.5 (ts=4 sw=4 et): `3yyG]p`.
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(std.testing.allocator, "  if x {\n    y();\n  }\n        target");
    defer ed.deinit();
    _ = try applyOp(ed, &clip, .{ .yank_lines_count = 3 });
    ed.cursor = ed.lineStart(3) + 8;
    const out = try applyOp(ed, &clip, .paste_after_indent);
    try std.testing.expect(out.buffer_changed);
    try std.testing.expectEqualStrings("  if x {\n    y();\n  }\n        target\n        if x {\n          y();\n        }", ed.doc.text.items);
    try std.testing.expectEqual([2]usize{ 4, 8 }, cursorRowCol(ed));
    // One undo step takes the whole put back.
    _ = try applyOp(ed, &clip, .undo);
    try std.testing.expectEqualStrings("  if x {\n    y();\n  }\n        target", ed.doc.text.items);
}

test "put-indent [p: put above a tab-indented line; the tab counts to its stop, spaces under expandtab" {
    // Neovim 0.12.5 (ts=4 sw=4 et): `2yyG[p`.
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(std.testing.allocator, "  a\n    b\n\tfoo\n");
    defer ed.deinit();
    ed.doc.tab_width = 4;
    _ = try applyOp(ed, &clip, .{ .yank_lines_count = 2 });
    ed.cursor = ed.lineStart(2) + 1;
    _ = try applyOp(ed, &clip, .paste_before_indent);
    try std.testing.expectEqualStrings("  a\n    b\n    a\n      b\n\tfoo\n", ed.doc.text.items);
    try std.testing.expectEqual([2]usize{ 2, 4 }, cursorRowCol(ed));
}

test "put-indent ]p with a charwise register is exactly p; [p exactly P" {
    // Neovim 0.12.5: `yeG]p` on `        target` puts `hello` after the `t`.
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const text = "  hello world\n        target";
    const ed = try Editor.init(std.testing.allocator, text);
    defer ed.deinit();
    ed.anchor = 2;
    ed.cursor = 7;
    _ = try applyOp(ed, &clip, .yank_selection);
    ed.anchor = null;
    const plain = try Editor.init(std.testing.allocator, text);
    defer plain.deinit();
    for ([_][2]EditOp{ .{ .paste_after_indent, .paste_after }, .{ .paste_before_indent, .paste_before } }) |pair| {
        try ed.setText(text);
        try plain.setText(text);
        ed.cursor = ed.lineStart(1) + 8;
        plain.cursor = ed.cursor;
        _ = try applyOp(ed, &clip, pair[0]);
        _ = try applyOp(plain, &clip, pair[1]);
        try std.testing.expectEqualStrings(plain.doc.text.items, ed.doc.text.items);
        try std.testing.expectEqual(plain.cursor, ed.cursor);
    }
    try std.testing.expectEqualStrings("  hello world\n        hellotarget", ed.doc.text.items);
}

test "put-indent [count]]p: the copies all take the one shift; the cursor lands on the first copy" {
    // Neovim 0.12.5 (ts=4 sw=4 et): `2yyG2]p`.
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(std.testing.allocator, "  a\n    b\n      t\n");
    defer ed.deinit();
    _ = try applyOp(ed, &clip, .{ .yank_lines_count = 2 });
    ed.cursor = ed.lineStart(2);
    _ = try applyOp(ed, &clip, .{ .repeat = .{ .count = 2, .inner = &.paste_after_indent } });
    try std.testing.expectEqualStrings("  a\n    b\n      t\n      a\n        b\n      a\n        b\n", ed.doc.text.items);
    try std.testing.expectEqual([2]usize{ 3, 6 }, cursorRowCol(ed));
    _ = try applyOp(ed, &clip, .undo);
    try std.testing.expectEqualStrings("  a\n    b\n      t\n", ed.doc.text.items);
}

test "put-indent ]p under use_tabs: tabs then spaces; empty lines stay empty; a shift below column 0 stops there" {
    // Neovim 0.12.5 (ts=4 sw=4 noet): `3yyG]p` over an empty line, and
    // `2yyG]p` from a deeper block onto an unindented line.
    var clip = Clipboard.init(std.testing.allocator);
    defer clip.deinit();
    const ed = try Editor.init(std.testing.allocator, "  a\n\n    b\n      x\n");
    defer ed.deinit();
    ed.doc.tab_width = 4;
    ed.doc.use_tabs = true;
    _ = try applyOp(ed, &clip, .{ .yank_lines_count = 3 });
    ed.cursor = ed.lineStart(3);
    _ = try applyOp(ed, &clip, .paste_after_indent);
    try std.testing.expectEqualStrings("  a\n\n    b\n      x\n\t  a\n\n\t\tb\n", ed.doc.text.items);
    try std.testing.expectEqual([2]usize{ 4, 3 }, cursorRowCol(ed));

    try ed.setText("    a\n  b\nx\n");
    ed.cursor = 0;
    _ = try applyOp(ed, &clip, .{ .yank_lines_count = 2 });
    ed.cursor = ed.lineStart(2);
    _ = try applyOp(ed, &clip, .paste_after_indent);
    try std.testing.expectEqualStrings("    a\n  b\nx\na\nb\n", ed.doc.text.items);
}
