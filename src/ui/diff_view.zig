//! The diff pane's paint: a header row, then one row per file header,
//! hunk header and diff line, with a two-column line-number gutter
//! (old | new), `+` lines in the add colour and `-` lines in the
//! delete colour. The app owns the parsed files and the flattened rows
//! (`flatten`); the view keeps only the scroll.
//!
//! Every row registers `.script_hit{ pane, id = row index }` so a click
//! moves the cursor and the wheel scrolls through the pane hit.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const parse = @import("../git/parse.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;
const PaneId = ids.PaneId;

/// One painted row of the diff, addressing the parsed structure.
pub const Row = union(enum) {
    file: u32,
    hunk: struct { file: u32, hunk: u32 },
    line: struct { file: u32, hunk: u32, line: u32 },
    blank,
};

pub const State = struct { scroll: usize = 0 };

pub const Doc = struct {
    files: []const parse.FileDiff,
    rows: []const Row,
    cursor: usize,
    focused: bool,
    header: []const u8,
};

/// The rows a diff paints: a file header, then per hunk its header and
/// lines, a blank between files.
pub fn flatten(arena: Allocator, files: []const parse.FileDiff) Allocator.Error![]Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    for (files, 0..) |f, fi| {
        if (fi > 0) try out.append(arena, .blank);
        try out.append(arena, .{ .file = @intCast(fi) });
        for (f.hunks, 0..) |h, hi| {
            try out.append(arena, .{ .hunk = .{ .file = @intCast(fi), .hunk = @intCast(hi) } });
            for (h.lines, 0..) |_, li| try out.append(arena, .{ .line = .{ .file = @intCast(fi), .hunk = @intCast(hi), .line = @intCast(li) } });
        }
    }
    return out.items;
}

pub fn addStyle(t: *const Theme, base: Style) Style {
    return Theme.withFg(base, t.syntax.string.fg);
}

pub fn delStyle(t: *const Theme, base: Style) Style {
    return Theme.withFg(base, t.error_fg.fg);
}

/// Width of the two-column gutter for the widest line number in `files`.
fn gutterWidth(files: []const parse.FileDiff) u16 {
    var max: u32 = 1;
    for (files) |f| for (f.hunks) |h| {
        max = @max(max, h.old_start + h.old_count);
        max = @max(max, h.new_start + h.new_count);
    };
    var digits: u16 = 1;
    while (max >= 10) : (max /= 10) digits += 1;
    return 2 * @max(digits, 3) + 3;
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *State, doc: Doc) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(doc.header, area.w), Theme.onBg(t.accent, t.bg.bg));
    if (area.h < 2) return;
    const body = area.splitTop(1).rest;
    if (doc.rows.len == 0) {
        const msg: []const u8 = if (doc.files.len == 0) "No differences." else "";
        _ = ui.putStr(body.x + 2, body.y + 1, body.w -| 2, msg, Theme.onBg(t.muted, t.bg.bg));
        return;
    }
    const gw = gutterWidth(doc.files);
    const win = list_panel.scrollWindow(&view.scroll, doc.cursor, doc.rows.len, body.h);
    const num_w: u16 = (gw - 3) / 2;
    var y: u16 = 0;
    var i = win.first;
    while (i < doc.rows.len and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = body.row(y);
        const sel = i == doc.cursor and doc.focused;
        const base: Style = if (sel) Theme.onBg(t.fg, t.cursor_line.bg) else t.bg;
        if (sel) ui.fill(r, t.cursor_line);
        const text_x = r.x + gw;
        const text_w = r.w -| gw;
        switch (doc.rows[i]) {
            .blank => {},
            .file => |fi| {
                const f = doc.files[fi];
                const tag: []const u8 = switch (f.status) {
                    .added => "new file",
                    .deleted => "deleted",
                    .renamed => "renamed",
                    .modified => "modified",
                };
                const label = if (f.status == .renamed and f.old_path != null)
                    ui.fmt("{s} {s} → {s}  ({d} hunk{s}, {s})", .{ if (ui.ascii) "==" else "──", f.old_path.?, f.path(), f.hunks.len, if (f.hunks.len == 1) "" else "s", tag })
                else
                    ui.fmt("{s} {s}  ({d} hunk{s}, {s}{s})", .{ if (ui.ascii) "==" else "──", f.path(), f.hunks.len, if (f.hunks.len == 1) "" else "s", tag, if (f.binary) ", binary" else "" });
                var s = Theme.onBg(t.accent, base.bg);
                s.bold = true;
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(label, r.w), s);
            },
            .hunk => |h| {
                const hunk = doc.files[h.file].hunks[h.hunk];
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(hunk.header, r.w), Theme.onBg(t.info_fg, base.bg));
            },
            .line => |l| {
                const line = doc.files[l.file].hunks[l.hunk].lines[l.line];
                const style: Style = switch (line.kind) {
                    .add => addStyle(t, base),
                    .del => delStyle(t, base),
                    .context => base,
                    .meta => Theme.onBg(t.muted, base.bg),
                };
                // Gutter: `old new ` right-aligned, dim.
                const gstyle = Theme.onBg(t.gutter, base.bg);
                if (line.old_no) |n| _ = ui.putStrRight(r.x + num_w, r.y, num_w, ui.fmt("{d}", .{n}), gstyle);
                if (line.new_no) |n| _ = ui.putStrRight(r.x + 2 * num_w + 1, r.y, num_w, ui.fmt("{d}", .{n}), gstyle);
                const sign: []const u8 = switch (line.kind) {
                    .add => "+",
                    .del => "-",
                    .context => " ",
                    .meta => "\\",
                };
                _ = ui.putStr(r.x + gw - 1, r.y, 1, sign, style);
                const text = if (line.kind == .meta) line.text else line.text;
                _ = ui.putStr(text_x, r.y, text_w, ui.clipStr(expandTabs(ui, text), text_w), style);
            },
        }
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
    }
    if (win.needs_bar and body.w > 4) {
        const bar = Rect.init(body.right() - 1, body.y, 1, body.h);
        @import("scrollbar.zig").drawVertical(ui, bar, .{ .pane = pane }, doc.rows.len, body.h, view.scroll);
    }
}

/// Tabs as four spaces — a diff line is painted as one run.
fn expandTabs(ui: Ui, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\t') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '\t') out.appendSlice(ui.arena, "    ") catch return s else out.append(ui.arena, c) catch return s;
    }
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const sample =
    "diff --git a/code.rs b/code.rs\n" ++
    "--- a/code.rs\n" ++
    "+++ b/code.rs\n" ++
    "@@ -1 +1 @@\n" ++
    "-fn alpha() {}\n" ++
    "+fn beta() {}\n";

test "flatten lists file, hunk and lines; draw paints the signs and registers row hits" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parse.parseDiff(a.allocator(), sample);
    const rows = try flatten(a.allocator(), files);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expect(rows[0] == .file);
    try testing.expect(rows[1] == .hunk);
    try testing.expect(rows[3] == .line);

    var f = try Fixture.init(40, 6);
    defer f.deinit();
    var st: State = .{};
    draw(f.ui(), 2, Rect.init(0, 0, 40, 6), &st, .{ .files = files, .rows = rows, .cursor = 2, .focused = true, .header = " diff: code.rs " });
    try f.expectRow(0, " diff: code.rs");
    try f.expectRow(1, "── code.rs  (1 hunk, modified)");
    try f.expectRow(2, "@@ -1 +1 @@");
    try f.expectRow(3, "  1     -fn alpha() {}");
    try f.expectRow(4, "      1 +fn beta() {}");
    try testing.expectEqual(@as(u32, 3), f.hits.at(5, 4).?.script_hit.id);
}
