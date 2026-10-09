//! The picker's preview column: whatever the cursor row points at,
//! read through the paths the editor already reads (an open buffer's
//! bytes when the file is open, the disk otherwise) and coloured by the
//! one highlight engine, in the `script_view.Segment` rows
//! `ui/picker.zig` paints.
//!
//! Two budgets keep a cursor move cheap: the read stops at
//! `max_bytes` (32 KiB — a preview is a look, not a load) and the build
//! stops at `max_rows` lines. A row that names a line (a grep hit)
//! centres the window on it: the rows start `lead` lines above the hit
//! and the hit's index comes back as the focus, so `ui/picker.zig`
//! places it against the column's real height without a rebuild.
//!
//! The highlighter lives on the `App` rather than here: every grammar
//! it loads (parser + compiled queries) is cached inside it, so moving
//! down a list of Zig files compiles the Zig query once, not once per
//! row.

const std = @import("std");
const Allocator = std.mem.Allocator;
const highlight = @import("highlight");
const hl_table = highlight.table;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Theme = @import("../ui/theme.zig");
const script_view = @import("../ui/script_view.zig");
const syntax = @import("syntax.zig");

pub const Segment = script_view.Segment;
pub const Row = []Segment;

/// The read budget: a preview shows the head of a file, never the file.
pub const max_bytes: usize = 32 * 1024;
/// The build budget: lines turned into rows in one go.
pub const max_rows: usize = 200;
/// Lines kept above a centred hit, so scrolling up has somewhere to go.
pub const lead: usize = 24;
/// The line-number gutter's width, the trailing space included.
pub const gutter_w: usize = 5;
/// Tabs are painted as this many spaces — a preview never edits, so the
/// exact stop does not matter, only that the row does not carry a `\t`.
pub const tab_spaces: usize = 4;

/// A line to centre on (1-based, as grep counts) and the match on it.
pub const Hit = struct { line: u32, col: u32 = 0, len: u32 = 0 };

pub const Built = struct {
    rows: [][]Segment,
    /// Index into `rows` of the hit's line, for the column to centre on.
    focus: ?usize = null,
};

/// The preview for `text`. `path` picks the grammar; `hit` centres the
/// window and paints the match. Rows and their texts are `gpa`-owned —
/// `app_mod.Overlay.freePreview` frees them.
pub fn build(app: *App, text_in: []const u8, path: ?[]const u8, hit: ?Hit) Allocator.Error!Built {
    const gpa = app.gpa;
    const text = clip(text_in);
    const first_line: usize = if (hit) |h| (h.line -| 1) -| lead else 0;

    // The spans, once, for the whole clipped text.
    const spans: []const highlight.engine.Span = blk: {
        if (app.preview_hl == null) app.preview_hl = highlight.Highlighter.init(gpa);
        const h = &app.preview_hl.?;
        const key = syntax.keyFor(path, text);
        h.setLanguage(if (key) |k| hl_table.find(k) else null);
        h.invalidate();
        // The slice is the highlighter's until its next call; nothing
        // below asks it for anything more before the rows are built.
        break :blk try h.highlightAll(text);
    };

    var rows: std.ArrayListUnmanaged([]Segment) = .empty;
    errdefer app_mod.Overlay.freePreview(gpa, rows.toOwnedSlice(gpa) catch &.{});
    var focus: ?usize = null;
    var line_no: usize = 0;
    var off: usize = 0;
    var span_at: usize = 0;
    while (rows.items.len < max_rows) {
        const nl = std.mem.indexOfScalarPos(u8, text, off, '\n');
        const end = nl orelse text.len;
        if (line_no >= first_line) {
            if (hit) |h| if (h.line == line_no + 1) {
                focus = rows.items.len;
            };
            const row = try buildRow(app, text[off..end], off, spans, &span_at, line_no + 1, if (hit) |h| (if (h.line == line_no + 1) h else null) else null);
            try rows.append(gpa, row);
        }
        line_no += 1;
        if (nl == null) break;
        off = end + 1;
        if (off >= text.len) break;
    }
    return .{ .rows = try rows.toOwnedSlice(gpa), .focus = focus };
}

/// The bytes a preview reads: the first `max_bytes`, cut back to a line
/// end so the last row is not half a line, and to a UTF-8 boundary.
fn clip(text: []const u8) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |nl| {
        end = nl;
    } else {
        while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    }
    return text[0..end];
}

/// One row: the muted line number, then the line split on the spans
/// that touch it. `span_at` walks forward across calls — the lines are
/// built in order, so the scan is linear over the whole file.
fn buildRow(app: *App, line: []const u8, line_off: usize, spans: []const highlight.engine.Span, span_at: *usize, number: usize, hit: ?Hit) Allocator.Error![]Segment {
    const gpa = app.gpa;
    const th = app.theme;
    var segs: std.ArrayListUnmanaged(Segment) = .empty;
    errdefer {
        for (segs.items) |s| gpa.free(s.text);
        segs.deinit(gpa);
    }
    var num_buf: [gutter_w + 8]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d: >4} ", .{number}) catch "     ";
    try segs.append(gpa, .{ .text = try gpa.dupe(u8, num), .style = groundless(th.muted) });

    // Drop spans that ended before this line; they cannot come back.
    while (span_at.* < spans.len and spans[span_at.*].end <= line_off) span_at.* += 1;
    const hit_lo: usize = if (hit) |h| @min(h.col, line.len) else 0;
    const hit_hi: usize = if (hit) |h| @min(h.col + h.len, line.len) else 0;

    var pos: usize = 0;
    var scan = span_at.*;
    while (pos < line.len) {
        // The style at `pos`: the first span covering it, else plain.
        var style = th.fg;
        var end = line.len;
        while (scan < spans.len and spans[scan].end <= line_off + pos) scan += 1;
        if (scan < spans.len) {
            const s = spans[scan];
            const s_start = @as(usize, s.start) -| line_off;
            const s_end = @as(usize, s.end) - line_off;
            if (s.start <= line_off + pos) {
                style = th.roleStyle(s.role);
                end = @min(line.len, s_end);
            } else {
                end = @min(line.len, s_start);
            }
        }
        // The theme's role styles carry the EDITOR's ground; in the
        // picker that painted every token as a dark box on the overlay's
        // lighter one. Tokens take the column's ground (`.default`).
        style = groundless(style);
        // A hit splits the run so the match keeps the search style —
        // the one segment that names its own ground.
        if (hit != null and hit_hi > hit_lo) {
            if (pos < hit_lo) {
                end = @min(end, hit_lo);
            } else if (pos < hit_hi) {
                end = @min(end, hit_hi);
                style = th.current_match;
            }
        }
        if (end <= pos) end = pos + 1;
        try segs.append(gpa, .{ .text = try expandTabs(gpa, line[pos..end]), .style = style });
        pos = end;
    }
    return segs.toOwnedSlice(gpa);
}

/// `\t` → spaces and `\r` dropped: a preview row is painted cell for
/// cell, and neither byte has a width the painter could honour.
fn expandTabs(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var extra: usize = 0;
    var drop: usize = 0;
    for (s) |c| {
        if (c == '\t') extra += tab_spaces - 1;
        if (c == '\r') drop += 1;
    }
    if (extra == 0 and drop == 0) return gpa.dupe(u8, s);
    var out = try gpa.alloc(u8, s.len + extra - drop);
    var i: usize = 0;
    for (s) |c| switch (c) {
        '\r' => {},
        '\t' => {
            @memset(out[i .. i + tab_spaces], ' ');
            i += tab_spaces;
        },
        else => {
            out[i] = c;
            i += 1;
        },
    };
    return out;
}

/// `st` without its background: the picker paints the column's own.
fn groundless(st: Theme.Style) Theme.Style {
    var out = st;
    out.bg = .default;
    return out;
}

/// One row saying why there is nothing to show — an unreadable file, a
/// pane that is not a file. The column is never blank without a reason.
pub fn note(app: *App, text: []const u8) Allocator.Error![][]Segment {
    const gpa = app.gpa;
    const rows = try gpa.alloc([]Segment, 1);
    errdefer gpa.free(rows);
    const segs = try gpa.alloc(Segment, 1);
    errdefer gpa.free(segs);
    segs[0] = .{ .text = try gpa.dupe(u8, text), .style = groundless(app.theme.muted) };
    rows[0] = segs;
    return rows;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn rowText(gpa: Allocator, row: []Segment) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (row) |s| try out.appendSlice(gpa, s.text);
    return out.toOwnedSlice(gpa);
}

test "the preview numbers its lines, keeps the file's order and stops at the row budget" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace });
    defer app.deinit();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    for (0..max_rows + 50) |i| {
        const l = try std.fmt.allocPrint(t.allocator, "line {d}\n", .{i});
        defer t.allocator.free(l);
        try text.appendSlice(t.allocator, l);
    }
    const built = try build(&app, text.items, "notes.txt", null);
    defer app_mod.Overlay.freePreview(t.allocator, built.rows);
    try t.expectEqual(max_rows, built.rows.len);
    try t.expect(built.focus == null);
    const first = try rowText(t.allocator, built.rows[0]);
    defer t.allocator.free(first);
    try t.expectEqualStrings("   1 line 0", first);
    const last = try rowText(t.allocator, built.rows[max_rows - 1]);
    defer t.allocator.free(last);
    try t.expectEqualStrings(" 200 line 199", last);
}

test "a hit centres the window on its line and paints the match in the search style" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace });
    defer app.deinit();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    for (0..120) |i| try text.appendSlice(t.allocator, if (i == 99) "the needle here\n" else "hay\n");
    const built = try build(&app, text.items, "hay.txt", .{ .line = 100, .col = 4, .len = 6 });
    defer app_mod.Overlay.freePreview(t.allocator, built.rows);
    // The window starts `lead` lines above the hit, so the hit is at
    // that index and there is context on both sides.
    try t.expectEqual(@as(?usize, lead), built.focus);
    const row = built.rows[built.focus.?];
    const text_of = try rowText(t.allocator, row);
    defer t.allocator.free(text_of);
    try t.expectEqualStrings(" 100 the needle here", text_of);
    // The needle is its own segment, in the search style.
    var found = false;
    for (row) |s| if (std.mem.eql(u8, s.text, "needle")) {
        found = true;
        try t.expect(std.meta.eql(app.theme.current_match.bg, s.style.bg));
    };
    try t.expect(found);
}

test "the read stops at 32 KiB on a line end, and tabs become spaces" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace });
    defer app.deinit();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.allocator);
    try text.appendSlice(t.allocator, "\tone\n");
    while (text.items.len < max_bytes * 2) try text.appendSlice(t.allocator, "0123456789abcdef\n");
    const built = try build(&app, text.items, "x.txt", null);
    defer app_mod.Overlay.freePreview(t.allocator, built.rows);
    const first = try rowText(t.allocator, built.rows[0]);
    defer t.allocator.free(first);
    try t.expectEqualStrings("   1     one", first);
    // The clip lands on a line end: the last row is a whole line.
    const last = try rowText(t.allocator, built.rows[built.rows.len - 1]);
    defer t.allocator.free(last);
    try t.expect(std.mem.endsWith(u8, last, "0123456789abcdef"));
}

test "a grammar colours the preview; plain text leaves it in the foreground" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace });
    defer app.deinit();
    const src = "const x = 1;\n";
    const zig_built = try build(&app, src, "a.zig", null);
    defer app_mod.Overlay.freePreview(t.allocator, zig_built.rows);
    var keyworded = false;
    for (zig_built.rows[0]) |s| if (std.mem.indexOf(u8, s.text, "const") != null) {
        keyworded = std.meta.eql(s.style.fg, app.theme.syntax.keyword.fg);
    };
    try t.expect(keyworded);
    const plain = try build(&app, src, "a.unknownext", null);
    defer app_mod.Overlay.freePreview(t.allocator, plain.rows);
    // No grammar: one run for the whole line, in the plain foreground.
    try t.expectEqual(@as(usize, 2), plain.rows[0].len);
    try t.expect(std.meta.eql(app.theme.fg.fg, plain.rows[0][1].style.fg));
    // Every segment leaves the ground to the picker: no token keeps the
    // editor's background inside the overlay.
    for (zig_built.rows[0]) |seg| try t.expect(std.meta.activeTag(seg.style.bg) == .default);
    for (plain.rows[0]) |seg| try t.expect(std.meta.activeTag(seg.style.bg) == .default);
}
