//! The Files pane painter: a breadcrumb row with the sort / hidden /
//! refresh chips, an optional filter pill, a column header, then one
//! row per entry — name, size, modified, kind — and, when the pane is
//! wide enough, a preview column showing the head of the file under
//! the cursor. Marked rows carry a tick in the marker column.
//!
//! Every clickable thing registers a `.script_hit{ pane, id }` in the
//! same statement as its paint; the id space is split by `Hit` so the
//! app's one click handler can tell a row from a crumb from a chip.

const std = @import("std");
const mnml_sdk = @import("mnml_sdk");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const filter_input = @import("filter_input.zig");
const text_field = @import("text_field.zig");
const chip = @import("chip.zig");
const ids = @import("../core/ids.zig");

const Style = vaxis.Style;
const PaneId = ids.PaneId;

pub const Caret = text_field.Caret;

/// The `.script_hit` id space. Rows are their index; everything else
/// sits above `row_limit`.
pub const Hit = struct {
    pub const row_limit: u32 = 0x1000_0000;
    pub const crumb_base: u32 = 0x1000_0000;
    pub const chip_base: u32 = 0x2000_0000;
    pub const kebab_base: u32 = 0x3000_0000;
    pub const body: u32 = 0x4000_0000;
    pub const filter: u32 = 0x4000_0001;
    pub const column_base: u32 = 0x5000_0000;

    pub const Chip = enum(u32) { sort, hidden, refresh, up };
    pub const Column = enum(u32) { name, size, modified, kind };

    pub const Kind = union(enum) {
        row: u32,
        crumb: u32,
        chip: Chip,
        kebab: u32,
        body,
        filter,
        column: Column,
    };

    pub fn decode(id: u32) Kind {
        if (id < row_limit) return .{ .row = id };
        if (id >= column_base) return .{ .column = @enumFromInt(@min(id - column_base, 3)) };
        if (id == body) return .body;
        if (id == filter) return .filter;
        if (id >= kebab_base) return .{ .kebab = id - kebab_base };
        if (id >= chip_base) return .{ .chip = @enumFromInt(@min(id - chip_base, 3)) };
        return .{ .crumb = id - crumb_base };
    }
};

pub const Row = struct {
    name: []const u8,
    is_dir: bool,
    is_link: bool = false,
    /// Null for a directory.
    size: ?u64 = null,
    /// Seconds since the epoch; null when unknown.
    mtime: ?i64 = null,
    marked: bool = false,
    /// A git porcelain letter (`M A D ?`), 0 for none.
    git: u8 = 0,
};

pub const Filter = struct { text: []const u8, caret: usize, focused: bool, anchor: ?usize = null };

pub const Doc = struct {
    /// The path, one segment per crumb; the last is the current dir.
    crumbs: []const []const u8,
    rows: []const Row,
    cursor: usize,
    focused: bool,
    sort_label: []const u8,
    sort_widest: usize,
    show_hidden: bool,
    filter: Filter,
    marked: usize,
    /// The unfiltered count, for `(3 of 40)`.
    total: usize,
    err: ?[]const u8 = null,
    /// The head of the cursor file, painted beside the list when it fits.
    preview: ?[]const u8 = null,
    now_s: i64 = 0,
    empty: []const u8 = "Empty directory",
};

/// The listing column widths, right to left. The name takes the rest.
const size_w: u16 = 7;
const mtime_w: u16 = 12;
const kind_w: u16 = 5;
/// Below this width the preview column is not painted.
const preview_min_w: u16 = 80;

pub const sort_widest: usize = 8; // "Modified"

/// `1.2K` / `340M` / `12G` — never wider than `size_w - 1`.
pub fn humanBytes(arena: std.mem.Allocator, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T", "P", "E" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1024.0 and u < units.len - 1) : (u += 1) v /= 1024.0;
    if (u == 0) return std.fmt.allocPrint(arena, "{d}{s}", .{ n, units[0] }) catch "";
    if (v < 10.0) return std.fmt.allocPrint(arena, "{d:.1}{s}", .{ v, units[u] }) catch "";
    return std.fmt.allocPrint(arena, "{d:.0}{s}", .{ v, units[u] }) catch "";
}

/// `just now` / `5m ago` / `3h ago` / `2d ago` / `2026-01-05`.
pub fn humanAge(arena: std.mem.Allocator, mtime: i64, now: i64) []const u8 {
    const age = now - mtime;
    if (age < 0) return "just now";
    if (age < 60) return "just now";
    if (age < 3600) return std.fmt.allocPrint(arena, "{d}m ago", .{@divTrunc(age, 60)}) catch "";
    if (age < 86_400) return std.fmt.allocPrint(arena, "{d}h ago", .{@divTrunc(age, 3600)}) catch "";
    if (age < 30 * 86_400) return std.fmt.allocPrint(arena, "{d}d ago", .{@divTrunc(age, 86_400)}) catch "";
    const day = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(mtime, 0)) };
    const ymd = day.getEpochDay().calculateYearDay();
    const md = ymd.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}", .{ ymd.year, md.month.numeric(), md.day_index + 1 }) catch "";
}

/// The kind column's width on a listing `w` wide: five cells, and on a
/// wide listing what its longest kind needs, shared with a name that is
/// itself cut (`sdk.pane.columns`, the family's one table rule).
fn kindWidth(doc: Doc, w: u16) u16 {
    var need_kind: usize = 0;
    var need_name: usize = 0;
    for (doc.rows) |r| {
        need_kind = @max(need_kind, mnml_sdk.pane.width(kindLabel(r)));
        need_name = @max(need_name, mnml_sdk.pane.width(r.name) + 3);
    }
    const specs = [_]mnml_sdk.pane.columns.Spec{
        .{ .w = 8, .rest = true, .need = @intCast(@min(need_name, 1000)) },
        .{ .w = kind_w, .need = @intCast(@min(need_kind, 24)) },
    };
    var out: [2]u16 = undefined;
    mnml_sdk.pane.columns.fit(&out, &specs, w -| (3 + size_w + 1 + mtime_w + 1), 0);
    return @max(out[1], kind_w);
}

fn kindLabel(r: Row) []const u8 {
    if (r.is_link) return "link";
    if (r.is_dir) return "dir";
    const dot = std.mem.lastIndexOfScalar(u8, r.name, '.') orelse return "file";
    if (dot == 0 or dot + 1 >= r.name.len) return "file";
    return r.name[dot + 1 ..];
}

pub fn gitStyle(t: *const Theme, code: u8, base: Style) Style {
    return Theme.withFg(base, switch (code) {
        'A' => t.syntax.string.fg,
        'D' => t.error_fg.fg,
        'M', 'R', 'C', 'T' => t.warn_fg.fg,
        'U' => t.error_fg.fg,
        '?' => t.muted.fg,
        else => base.fg,
    });
}

/// Paints the pane and returns the filter caret when it has focus.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, doc: Doc, scroll: *usize) ?Caret {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return null;

    // ── row 0: breadcrumb + chips ──
    var rest = area;
    const crumb_row = rest.splitTop(1);
    drawCrumbs(ui, pane, crumb_row.top, doc);
    rest = crumb_row.rest;
    if (rest.isEmpty()) return null;

    // ── the filter pill, only while there is something in it ──
    var caret: ?Caret = null;
    if (doc.filter.focused or doc.filter.text.len > 0) {
        const fr = rest.splitTop(1);
        // The pill's hit is the pane's own id: the Files pane routes
        // clicks by pane.
        caret = filter_input.draw(ui, fr.top, .{
            .panel = .todos,
            .text = doc.filter.text,
            .caret = doc.filter.caret,
            .anchor = doc.filter.anchor,
            .focused = doc.filter.focused,
            .bg = t.bg,
            .pane = pane,
            .pane_hit = Hit.filter,
        });
        rest = fr.rest;
        if (rest.isEmpty()) return caret;
    }

    // ── the preview column, when it fits ──
    var list = rest;
    if (doc.preview != null and rest.w >= preview_min_w) {
        const pw: u16 = rest.w * 2 / 5;
        const split = rest.splitRight(pw);
        list = split.left;
        drawPreview(ui, split.rest, doc.preview.?);
        // One cell of air.
        list = list.splitRight(1).left;
    }

    // ── the column header ──
    const head = list.splitTop(1);
    const kw = kindWidth(doc, head.top.w);
    drawColumns(ui, pane, head.top, kw);
    list = head.rest;
    if (list.isEmpty()) return caret;

    if (doc.err) |e| {
        _ = ui.putStr(list.x + 2, list.y, list.w -| 2, ui.clipStr(ui.fmt("cannot read: {s}", .{e}), list.w -| 2), Theme.onBg(t.error_fg, t.bg.bg));
        ui.hit(list, .{ .script_hit = .{ .pane = pane, .id = Hit.body } });
        return caret;
    }
    if (doc.rows.len == 0) {
        _ = ui.putStr(list.x + 2, list.y, list.w -| 2, ui.clipStr(doc.empty, list.w -| 2), Theme.onBg(t.muted, t.bg.bg));
        ui.hit(list, .{ .script_hit = .{ .pane = pane, .id = Hit.body } });
        return caret;
    }
    // The body hit sits UNDER the rows: a click in the blank tail lands
    // here, a click on a row lands on the row painted after it.
    ui.hit(list, .{ .script_hit = .{ .pane = pane, .id = Hit.body } });
    const win = list_panel.scrollWindow(scroll, doc.cursor, doc.rows.len, list.h);
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const r = list.row(@intCast(i));
        const row = doc.rows[idx];
        const selected = idx == doc.cursor;
        const base: Style = if (selected) Theme.onBg(t.fg, t.cursor_line.bg) else if (row.marked) Theme.onBg(t.fg, t.selection.bg) else t.bg;
        ui.fill(r, base);
        // Marker column: a mark's tick — on the cursor row too, where the
        // band is the cursor — else the cursor's bar.
        const marker: []const u8 = if (row.marked) (if (ui.ascii) "*" else "✓") else if (selected) (if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph) else " ";
        _ = ui.putStr(r.x, r.y, 1, marker, Theme.withFg(base, if (selected and doc.focused) t.accent.fg else if (row.marked) t.accent.fg else t.muted.fg));
        paintRow(ui, Rect.init(r.x + 1, r.y, r.w -| 1, 1), row, base, doc.now_s, kw);
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(idx) } });
        if (ui.hovered(r) and r.w > list_panel.kebab_w + 4) {
            const kr = r.rightCells(list_panel.kebab_w);
            _ = ui.putStr(kr.x, kr.y, kr.w, if (ui.ascii) list_panel.kebab_ascii else list_panel.kebab_glyph, Theme.withFg(base, t.accent.fg));
            ui.hit(kr, .{ .script_hit = .{ .pane = pane, .id = Hit.kebab_base + @as(u32, @intCast(idx)) } });
        }
    }
    return caret;
}

/// `<git> <name>            <size> <modified> <kind>` inside `r`.
fn paintRow(ui: Ui, r: Rect, row: Row, base: Style, now_s: i64, kw: u16) void {
    const t = ui.theme;
    if (r.isEmpty()) return;
    const end = r.right();
    var x = r.x;
    // The git badge takes one cell (a space when clean).
    if (row.git != 0) {
        x += ui.putStr(x, r.y, end -| x, ui.fmt("{c}", .{row.git}), gitStyle(t, row.git, base));
    } else {
        x += ui.putStr(x, r.y, end -| x, " ", base);
    }
    x += ui.putStr(x, r.y, end -| x, " ", base);
    const wide = r.w >= 1 + 1 + 8 + size_w + 1 + mtime_w + 1 + kind_w;
    const cols_w: u16 = if (wide) size_w + 1 + mtime_w + 1 + kw else 0;
    const name_w: u16 = (end -| x) -| cols_w;
    const name_style = if (row.is_dir) Theme.withFg(base, t.accent.fg) else base;
    var shown = row.name;
    if (row.is_dir) shown = ui.fmt("{s}/", .{row.name});
    if (row.is_link) shown = ui.fmt("{s}{s}", .{ shown, if (ui.ascii) " ->" else " →" });
    _ = ui.putStr(x, r.y, name_w, ui.clipStr(shown, name_w), name_style);
    if (!wide) return;
    x = end - cols_w;
    const dim = Theme.withFg(base, t.muted.fg);
    const size_text: []const u8 = if (row.size) |n| humanBytes(ui.arena, n) else "";
    _ = ui.putStrRight(x + size_w, r.y, size_w, size_text, dim);
    x += size_w + 1;
    const age: []const u8 = if (row.mtime) |m| humanAge(ui.arena, m, now_s) else "";
    _ = ui.putStrRight(x + mtime_w, r.y, mtime_w, age, dim);
    x += mtime_w + 1;
    _ = ui.putStr(x, r.y, kw, ui.clipStr(kindLabel(row), kw), dim);
}

/// The path as crumbs, each a click target, then the chips right-aligned.
fn drawCrumbs(ui: Ui, pane: PaneId, r: Rect, doc: Doc) void {
    const t = ui.theme;
    ui.fill(r, t.bufferline);
    const bg = t.bufferline.bg;
    // Chips first, right to left, so the crumbs know where to stop.
    var right = r.right();
    const refresh_text = chip.refreshIcon(ui.ascii);
    if (right -| r.x >= ui.width(refresh_text) + 8) {
        right -= ui.width(refresh_text);
        const rr = Rect.init(right, r.y, ui.width(refresh_text), 1);
        _ = ui.putStr(rr.x, rr.y, rr.w, refresh_text, chip.refreshStyle(t, bg));
        ui.hit(rr, .{ .script_hit = .{ .pane = pane, .id = Hit.chip_base + @intFromEnum(Hit.Chip.refresh) } });
        right -= 1;
    }
    const hidden_text: []const u8 = if (doc.show_hidden) " .* " else " .  ";
    if (right -| r.x >= ui.width(hidden_text) + 8) {
        right -= ui.width(hidden_text);
        const hr = Rect.init(right, r.y, ui.width(hidden_text), 1);
        const hs = if (doc.show_hidden) chip.modeStyle(t) else Theme.onBg(t.muted, t.chip.bg);
        _ = ui.putStr(hr.x, hr.y, hr.w, hidden_text, hs);
        ui.hit(hr, .{ .script_hit = .{ .pane = pane, .id = Hit.chip_base + @intFromEnum(Hit.Chip.hidden) } });
        right -= 1;
    }
    const sort_full = chip.modeText(ui.arena, "sort", doc.sort_label, doc.sort_widest) catch "";
    const sort_icon = chip.modeIcon(ui.ascii);
    const sort_text: ?[]const u8 = if (right -| r.x >= ui.width(sort_full) + 12) sort_full else if (right -| r.x >= ui.width(sort_icon) + 8) sort_icon else null;
    if (sort_text) |st| {
        right -= ui.width(st);
        const sr = Rect.init(right, r.y, ui.width(st), 1);
        _ = ui.putStr(sr.x, sr.y, sr.w, st, chip.modeStyle(t));
        ui.hit(sr, .{ .script_hit = .{ .pane = pane, .id = Hit.chip_base + @intFromEnum(Hit.Chip.sort) } });
        right -= 1;
    }
    if (doc.marked > 0) {
        const mt = ui.fmt(" {s}{d} ", .{ if (ui.ascii) "*" else "✓", doc.marked });
        if (right -| r.x >= ui.width(mt) + 8) {
            right -= ui.width(mt);
            _ = ui.putStr(right, r.y, ui.width(mt), mt, Theme.onBg(t.accent, bg));
            right -= 1;
        }
    }
    // The crumbs: ` up ` first when there is somewhere to go, then the
    // segments joined by a separator, each its own target.
    var x = r.x;
    const up_text: []const u8 = if (ui.ascii) " ^ " else " ↑ ";
    if (doc.crumbs.len > 1 and right -| x > ui.width(up_text) + 4) {
        const ur = Rect.init(x, r.y, ui.width(up_text), 1);
        _ = ui.putStr(ur.x, ur.y, ur.w, up_text, Theme.onBg(t.muted, bg));
        ui.hit(ur, .{ .script_hit = .{ .pane = pane, .id = Hit.chip_base + @intFromEnum(Hit.Chip.up) } });
        x += ur.w;
    }
    const sep: []const u8 = if (ui.ascii) " > " else " › ";
    const count = ui.fmt(" ({d}{s})", .{ doc.rows.len, if (doc.rows.len != doc.total) ui.fmt(" of {d}", .{doc.total}) else "" });
    const count_w = ui.width(count);
    // Drop leading crumbs from the left when the path does not fit.
    var first: usize = 0;
    while (first + 1 < doc.crumbs.len) {
        var need: u16 = 0;
        for (doc.crumbs[first..], 0..) |c, i| need += ui.width(c) + @as(u16, if (i > 0) ui.width(sep) else 1);
        if (x + need + count_w + 1 <= right) break;
        first += 1;
    }
    for (doc.crumbs[first..], 0..) |c, i| {
        const idx = first + i;
        if (i > 0) {
            x += ui.putStr(x, r.y, right -| x, sep, Theme.onBg(t.muted, bg));
        } else {
            x += ui.putStr(x, r.y, right -| x, " ", t.bufferline);
        }
        const last = idx == doc.crumbs.len - 1;
        const style = if (last) Theme.onBg(if (doc.focused) t.accent else t.fg, bg) else Theme.onBg(t.muted, bg);
        const shown = ui.clipStr(c, right -| x);
        const w = ui.putStr(x, r.y, right -| x, shown, style);
        ui.hit(Rect.init(x, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = Hit.crumb_base + @as(u32, @intCast(idx)) } });
        x += w;
        if (x >= right) break;
    }
    if (x + count_w <= right) _ = ui.putStr(x, r.y, right -| x, count, Theme.onBg(t.muted, bg));
}

/// `Name … Size Modified Kind`, each a click target that sorts by it.
fn drawColumns(ui: Ui, pane: PaneId, r: Rect, kw: u16) void {
    const t = ui.theme;
    var style = Theme.onBg(t.muted, t.bg.bg);
    style.bold = true;
    ui.fill(r, t.bg);
    if (r.w < 4) return;
    const wide = r.w >= 1 + 1 + 1 + 8 + size_w + 1 + mtime_w + 1 + kind_w;
    const cols_w: u16 = if (wide) size_w + 1 + mtime_w + 1 + kw else 0;
    const name_x = r.x + 3;
    const name_w: u16 = (r.right() -| name_x) -| cols_w;
    _ = ui.putStr(name_x, r.y, name_w, "Name", style);
    ui.hit(Rect.init(r.x, r.y, name_w + 3, 1), .{ .script_hit = .{ .pane = pane, .id = Hit.column_base + @intFromEnum(Hit.Column.name) } });
    if (!wide) return;
    var x = r.right() - cols_w;
    _ = ui.putStrRight(x + size_w, r.y, size_w, "Size", style);
    ui.hit(Rect.init(x, r.y, size_w, 1), .{ .script_hit = .{ .pane = pane, .id = Hit.column_base + @intFromEnum(Hit.Column.size) } });
    x += size_w + 1;
    _ = ui.putStrRight(x + mtime_w, r.y, mtime_w, "Modified", style);
    ui.hit(Rect.init(x, r.y, mtime_w, 1), .{ .script_hit = .{ .pane = pane, .id = Hit.column_base + @intFromEnum(Hit.Column.modified) } });
    x += mtime_w + 1;
    _ = ui.putStr(x, r.y, kw, "Kind", style);
    ui.hit(Rect.init(x, r.y, kw, 1), .{ .script_hit = .{ .pane = pane, .id = Hit.column_base + @intFromEnum(Hit.Column.kind) } });
}

/// The head of the cursor file, one line per row, dim, inside a left rule.
fn drawPreview(ui: Ui, r: Rect, text: []const u8) void {
    const t = ui.theme;
    ui.fill(r, t.bg);
    if (r.w < 3) return;
    ui.vrule(r.x, r.y, r.h, t.border);
    const body = Rect.init(r.x + 2, r.y, r.w -| 2, r.h);
    const style = Theme.onBg(t.muted, t.bg.bg);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var row: u16 = 0;
    while (lines.next()) |line| : (row += 1) {
        if (row >= body.h) break;
        const clean = std.mem.trimEnd(u8, line, "\r");
        _ = ui.putStr(body.x, body.y + row, body.w, ui.clipStr(expandTabs(ui, clean), body.w), style);
    }
}

fn expandTabs(ui: Ui, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\t') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '\t') out.appendSlice(ui.arena, "    ") catch return s else out.append(ui.arena, c) catch return s;
    }
    return out.items;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn sampleRows() [3]Row {
    return .{
        .{ .name = "src", .is_dir = true, .mtime = 1_700_000_000 },
        .{ .name = "README.md", .is_dir = false, .size = 2048, .mtime = 1_700_000_000, .marked = true, .git = 'M' },
        .{ .name = "build.zig", .is_dir = false, .size = 512, .mtime = 1_700_000_000 - 90 },
    };
}

fn sampleDoc(rows: []const Row) Doc {
    return .{
        .crumbs = &.{ "mnml", "src" },
        .rows = rows,
        .cursor = 1,
        .focused = true,
        .sort_label = "Name",
        .sort_widest = sort_widest,
        .show_hidden = false,
        .filter = .{ .text = "", .caret = 0, .focused = false },
        .marked = 1,
        .total = rows.len,
        .now_s = 1_700_000_000 + 30,
    };
}

test "humanBytes and humanAge stay narrow" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("0B", humanBytes(a, 0));
    try testing.expectEqualStrings("1023B", humanBytes(a, 1023));
    try testing.expectEqualStrings("1.0K", humanBytes(a, 1024));
    try testing.expectEqualStrings("340M", humanBytes(a, 340 * 1024 * 1024));
    try testing.expectEqualStrings("16E", humanBytes(a, std.math.maxInt(u64)));
    try testing.expectEqualStrings("just now", humanAge(a, 100, 130));
    try testing.expectEqualStrings("5m ago", humanAge(a, 0, 5 * 60 + 3));
    try testing.expectEqualStrings("3h ago", humanAge(a, 0, 3 * 3600));
    try testing.expectEqualStrings("2d ago", humanAge(a, 0, 2 * 86_400));
    try testing.expectEqualStrings("2023-11-14", humanAge(a, 1_700_000_000, 1_800_000_000));
}

test "the pane at 60 wide: crumbs with chips, columns, rows with their hits, the marked row's tick" {
    var f = try Fixture.init(60, 7);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = sampleRows();
    const caret = draw(f.ui(), 4, f.full(), sampleDoc(&rows), &scroll);
    try testing.expect(caret == null);
    try f.expectContains(" ↑  mnml › src (3)");
    try f.expectContains("sort: Name");
    try f.expectContains("✓1");
    try f.expectContains("Name");
    try f.expectContains("Size");
    try f.expectContains("Modified");
    try f.expectContains("Kind");
    try f.expectContains("src/");
    // README is marked AND under the cursor: the tick shows on the band.
    try f.expectContains("✓M README.md");
    try f.expectContains("2.0K");
    try f.expectContains("just now");
    try f.expectContains("2m ago"); // build.zig: 90 s before "now - 30 s"
    try f.expectContains(" build.zig");
    // Hits: the row, the crumb, the chips, the column header, the body under the rows.
    try testing.expectEqual(@as(u32, 1), f.hits.at(10, 3).?.script_hit.id);
    try testing.expectEqual(@as(PaneId, 4), f.hits.at(10, 3).?.script_hit.pane);
    try testing.expectEqual(Hit.Kind{ .crumb = 0 }, Hit.decode(f.hits.at(5, 0).?.script_hit.id));
    try testing.expectEqual(Hit.Kind{ .chip = .up }, Hit.decode(f.hits.at(1, 0).?.script_hit.id));
    try testing.expectEqual(Hit.Kind{ .chip = .refresh }, Hit.decode(f.hits.at(58, 0).?.script_hit.id));
    try testing.expectEqual(Hit.Kind{ .column = .name }, Hit.decode(f.hits.at(4, 1).?.script_hit.id));
    try testing.expectEqual(Hit.Kind{ .column = .size }, Hit.decode(f.hits.at(36, 1).?.script_hit.id));
    try testing.expectEqual(Hit.Kind.body, Hit.decode(f.hits.at(10, 6).?.script_hit.id));
    try testing.expect(f.bgEql(10, 3, f.theme.cursor_line));
    try testing.expect(f.bgEql(10, 2, f.theme.bg));
}

test "a wide pane paints the preview column; the filter pill appears while focused; hover paints the kebab" {
    var f = try Fixture.init(100, 8);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = sampleRows();
    var doc = sampleDoc(&rows);
    doc.preview = "line one\nline\ttwo\n";
    doc.filter = .{ .text = "re", .caret = 2, .focused = true };
    f.hover = .{ .x = 5, .y = 4 };
    const caret = draw(f.ui(), 4, f.full(), doc, &scroll);
    try testing.expect(caret != null);
    try f.expectContains("│ line one");
    try f.expectContains("│ line    two");
    try f.expectContains("re");
    try testing.expectEqual(Hit.Kind{ .kebab = 1 }, Hit.decode(f.hits.at(57, 4).?.script_hit.id));
    // The filter took row 1, so the column header is row 2 and the first entry row 3.
    try testing.expectEqual(Hit.Kind{ .column = .name }, Hit.decode(f.hits.at(4, 2).?.script_hit.id));
    try testing.expectEqual(@as(u32, 0), f.hits.at(4, 3).?.script_hit.id);
}

test "an error and an empty listing paint their message and only the body hit; tiny areas never panic" {
    var f = try Fixture.init(40, 4);
    defer f.deinit();
    var scroll: usize = 0;
    var doc = sampleDoc(&.{});
    doc.err = "PermissionDenied";
    _ = draw(f.ui(), 1, f.full(), doc, &scroll);
    try f.expectContains("cannot read: PermissionDenied");
    try testing.expectEqual(Hit.Kind.body, Hit.decode(f.hits.at(3, 2).?.script_hit.id));
    f.hits.reset();
    doc.err = null;
    _ = draw(f.ui(), 1, f.full(), doc, &scroll);
    try f.expectContains("Empty directory");
    inline for (.{ .{ 1, 1 }, .{ 3, 2 }, .{ 12, 3 }, .{ 20, 1 } }) |wh| {
        var g = try Fixture.init(wh[0], wh[1]);
        defer g.deinit();
        const rows = sampleRows();
        _ = draw(g.ui(), 1, g.full(), sampleDoc(&rows), &scroll);
        for (g.hits.items.items) |e| try testing.expect(g.full().intersect(e.rect).eql(e.rect));
    }
}

test "a long kind reads whole on a wide listing and is cut to five cells on a narrow one" {
    const rows = [_]Row{
        .{ .name = "build.tsbuildinfo", .is_dir = false, .size = 512, .mtime = 1_700_000_000 },
        .{ .name = "a.md", .is_dir = false, .size = 512, .mtime = 1_700_000_000 },
    };
    try testing.expectEqual(@as(u16, 11), kindWidth(sampleDoc(&rows), 120));
    try testing.expectEqual(kind_w, kindWidth(sampleDoc(&rows), 30));
    try testing.expectEqual(kind_w, kindWidth(sampleDoc(&sampleRows()), 120));
    var f = try Fixture.init(120, 7);
    defer f.deinit();
    var scroll: usize = 0;
    _ = draw(f.ui(), 4, f.full(), sampleDoc(&rows), &scroll);
    try f.expectContains(" tsbuildinfo");
}

test "Hit.decode round-trips every id family" {
    try testing.expectEqual(Hit.Kind{ .row = 7 }, Hit.decode(7));
    try testing.expectEqual(Hit.Kind{ .crumb = 2 }, Hit.decode(Hit.crumb_base + 2));
    try testing.expectEqual(Hit.Kind{ .chip = .hidden }, Hit.decode(Hit.chip_base + 1));
    try testing.expectEqual(Hit.Kind{ .kebab = 3 }, Hit.decode(Hit.kebab_base + 3));
    try testing.expectEqual(Hit.Kind.body, Hit.decode(Hit.body));
    try testing.expectEqual(Hit.Kind.filter, Hit.decode(Hit.filter));
    try testing.expectEqual(Hit.Kind{ .column = .kind }, Hit.decode(Hit.column_base + 3));
}
