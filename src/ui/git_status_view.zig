//! The git status rows — one paint shared by the rail (`ListPanel`) and
//! the status pane. A row is a group header (`Staged (2)`) or an entry
//! (`M src/a.zig`), the letter coloured by what it means.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const parse = @import("../git/parse.zig");
const ids = @import("../core/ids.zig");

const Style = vaxis.Style;
const PaneId = ids.PaneId;

pub const Row = struct {
    header: bool,
    group: parse.Group,
    /// The porcelain letter (`M A D R ? U`); 0 on a header.
    code: u8 = 0,
    /// Repo-relative; borrowed from the status snapshot.
    path: []const u8 = "",
    /// Index into `Status.entries`.
    entry: u32 = 0,
    /// Entries in the group (headers only).
    count: u32 = 0,
};

/// The colour of a status letter: added green, deleted red, modified
/// yellow, untracked muted, a conflict in the error colour.
pub fn codeStyle(t: *const Theme, code: u8, base: Style) Style {
    var s = Theme.withFg(base, switch (code) {
        'A' => t.syntax.string.fg,
        'D' => t.error_fg.fg,
        'M', 'R', 'C', 'T' => t.warn_fg.fg,
        'U' => t.error_fg.fg,
        else => t.muted.fg,
    });
    s.bold = code != '?';
    return s;
}

pub fn groupStyle(t: *const Theme, group: parse.Group, base: Style) Style {
    var s = Theme.withFg(base, switch (group) {
        .staged => t.syntax.string.fg,
        .unstaged => t.warn_fg.fg,
        .untracked => t.muted.fg,
        .conflicted => t.error_fg.fg,
    });
    s.bold = true;
    return s;
}

/// `Staged (2)` for a header; `M path/to/file` for an entry, the
/// directory dimmed and the file name bright. When the path does not
/// fit its head is clipped so the name stays.
pub fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    if (row.header) {
        const label = ui.fmt("{s} ({d})", .{ row.group.label(), row.count });
        _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(label, r.w), groupStyle(t, row.group, base));
        return;
    }
    var x = r.x + 1;
    const end = r.right();
    // The cell keeps the slice it is given: the letter must outlive
    // this call, so it lives on the frame arena, not the stack.
    x += ui.putStr(x, r.y, end -| x, ui.fmt("{c}", .{row.code}), codeStyle(t, row.code, base));
    x += ui.putStr(x, r.y, end -| x, " ", base);
    const avail: u16 = end -| x;
    const shown = clipLeft(ui, row.path, avail);
    const slash = std.mem.lastIndexOfScalar(u8, shown, '/');
    if (slash) |s| {
        x += ui.putStr(x, r.y, end -| x, shown[0 .. s + 1], Theme.onBg(t.muted, base.bg));
        _ = ui.putStr(x, r.y, end -| x, shown[s + 1 ..], Theme.onBg(t.fg, base.bg));
    } else {
        _ = ui.putStr(x, r.y, end -| x, shown, Theme.onBg(t.fg, base.bg));
    }
}

/// `s` cut to `max` cells keeping its END, with the ellipsis in front.
fn clipLeft(ui: Ui, s: []const u8, max: u16) []const u8 {
    if (ui.width(s) <= max) return s;
    const ell: []const u8 = if (ui.ascii) "..." else "…";
    const ell_w = ui.width(ell);
    if (max <= ell_w) return "";
    var start: usize = 0;
    while (start < s.len and ui.width(s[start..]) > max - ell_w) {
        start += std.unicode.utf8ByteSequenceLength(s[start]) catch 1;
    }
    return ui.fmt("{s}{s}", .{ ell, s[start..] });
}

pub const PaneDoc = struct {
    header: []const u8,
    rows: []const Row,
    cursor: usize,
    focused: bool,
    empty: []const u8,
};

/// The status pane: a header row, then the rows with the cursor row
/// banded. Every row registers `.script_hit{ pane, id = row index }`.
pub fn drawPane(ui: Ui, pane: PaneId, area: Rect, doc: PaneDoc, scroll: *usize) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(doc.header, area.w), Theme.onBg(t.accent, t.bg.bg));
    if (area.h < 2) return;
    const list = area.splitTop(1).rest;
    if (doc.rows.len == 0) {
        _ = ui.putStr(list.x + 2, list.y + 1, list.w -| 2, ui.clipStr(doc.empty, list.w -| 2), Theme.onBg(t.muted, t.bg.bg));
        return;
    }
    const win = list_panel.scrollWindow(scroll, doc.cursor, doc.rows.len, list.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < doc.rows.len and y < list.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = list.row(y);
        const sel = i == doc.cursor and doc.focused;
        if (sel) ui.fill(r, t.cursor_line);
        const marker: []const u8 = if (i == doc.cursor) (if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph) else " ";
        _ = ui.putStr(r.x, r.y, 1, marker, Theme.onBg(t.accent, if (sel) t.cursor_line.bg else t.bg.bg));
        const content = Rect.init(r.x + 1, r.y, r.w -| 1, 1);
        paintRow(ui.withClip(content), content, doc.rows[i], sel);
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "paintRow: a header shows the group and count; an entry its letter and a name-first clip" {
    var f = try Fixture.init(20, 2);
    defer f.deinit();
    const ui = f.ui();
    paintRow(ui, Rect.init(0, 0, 20, 1), .{ .header = true, .group = .staged, .count = 2 }, false);
    try f.expectRow(0, "Staged (2)");
    paintRow(ui, Rect.init(0, 1, 12, 1), .{ .header = false, .group = .unstaged, .code = 'M', .path = "src/deep/dir/a.zig" }, false);
    try f.expectRow(1, " M …ir/a.zig");
}

test "drawPane: header, rows with hits, the cursor row banded" {
    var f = try Fixture.init(30, 5);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = [_]Row{
        .{ .header = true, .group = .untracked, .count = 1 },
        .{ .header = false, .group = .untracked, .code = '?', .path = "new.txt" },
    };
    drawPane(f.ui(), 3, Rect.init(0, 0, 30, 5), .{ .header = " main · 1 change ", .rows = &rows, .cursor = 1, .focused = true, .empty = "" }, &scroll);
    try f.expectRow(0, " main · 1 change");
    try f.expectRow(1, " Untracked (1)");
    try f.expectRow(2, "▌ ? new.txt");
    const h = f.hits.at(4, 2).?;
    try testing.expect(h == .script_hit);
    try testing.expectEqual(@as(u32, 1), h.script_hit.id);
    try testing.expectEqual(@as(PaneId, 3), h.script_hit.pane);
}
