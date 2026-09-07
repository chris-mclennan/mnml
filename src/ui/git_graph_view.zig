//! The commit graph: lanes laid out from parent ids (`layout`), then
//! painted one commit per row — `<lanes> <sha> <subject>  <author> <age>`
//! with `lane_spacing` blank cells between lanes. The app owns the
//! commits and the lanes; the view keeps the scroll.
//!
//! Layout is the classic column walk over a topological list: a commit
//! takes the lane its hash was expected in (or a fresh one), hands the
//! lane to its first parent, and opens a lane per extra parent that is
//! not already expected somewhere. A row's cells then read as: the node
//! in its lane, `│` for every other lane still open, and `─` runs with
//! `┐` / `┘` where the merge edges leave the node's lane.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const clip = @import("clip.zig");
const parse = @import("../git/parse.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;
const PaneId = ids.PaneId;

pub const Cell = enum { empty, node, pass, horiz, branch_right, branch_left, merge_right, merge_left };

/// One commit's row of the graph.
pub const Lane = struct {
    /// The column the commit sits in.
    lane: u16,
    /// One per column that exists at this row.
    cells: []Cell,
};

/// Lanes for `commits` (children before parents). Every slice borrows
/// `arena`.
pub fn layout(arena: Allocator, commits: []const parse.Commit) Allocator.Error![]Lane {
    var out = try arena.alloc(Lane, commits.len);
    // Column → the hash expected next in it (null = free).
    var active: std.ArrayListUnmanaged(?[]const u8) = .empty;
    for (commits, 0..) |c, i| {
        // The lane this commit was expected in, else the first free one.
        var lane: ?usize = null;
        for (active.items, 0..) |h, k| if (h != null and std.mem.eql(u8, h.?, c.hash)) {
            lane = k;
            break;
        };
        if (lane == null) {
            for (active.items, 0..) |h, k| if (h == null) {
                lane = k;
                break;
            };
        }
        if (lane == null) {
            try active.append(arena, null);
            lane = active.items.len - 1;
        }
        const me = lane.?;
        // Any other column that also expected this commit (a sibling
        // branch merging back in) closes into me.
        var closing: std.ArrayListUnmanaged(usize) = .empty;
        for (active.items, 0..) |h, k| if (k != me and h != null and std.mem.eql(u8, h.?, c.hash)) {
            try closing.append(arena, k);
            active.items[k] = null;
        };
        // The first parent inherits my column; extra parents open theirs.
        var opening: std.ArrayListUnmanaged(usize) = .empty;
        if (c.parents.len == 0) {
            active.items[me] = null;
        } else {
            active.items[me] = c.parents[0];
            for (c.parents[1..]) |p| {
                var have = false;
                for (active.items) |h| if (h != null and std.mem.eql(u8, h.?, p)) {
                    have = true;
                };
                if (have) continue;
                var slot: ?usize = null;
                for (active.items, 0..) |h, k| if (h == null and k != me) {
                    slot = k;
                    break;
                };
                if (slot == null) {
                    try active.append(arena, null);
                    slot = active.items.len - 1;
                }
                active.items[slot.?] = p;
                try opening.append(arena, slot.?);
            }
        }
        // The row is as wide as the columns still open after it, or
        // any edge that ends in this row — a lane closing into the node
        // is painted on this row even though it is free from the next.
        var width: usize = me + 1;
        for (closing.items) |k| width = @max(width, k + 1);
        for (opening.items) |k| width = @max(width, k + 1);
        // Trim trailing free columns so the graph does not keep growing.
        while (active.items.len > 0 and active.items[active.items.len - 1] == null) _ = active.pop();
        width = @max(width, active.items.len);
        const cells = try arena.alloc(Cell, width);
        @memset(cells, .empty);
        for (active.items, 0..) |h, k| if (h != null and k != me) {
            cells[k] = .pass;
        };
        cells[me] = .node;
        for (closing.items) |k| markEdge(cells, me, k, true);
        for (opening.items) |k| markEdge(cells, me, k, false);
        out[i] = .{ .lane = @intCast(me), .cells = cells };
    }
    return out;
}

/// A horizontal run from `me` to `k` ending in a corner; `closing`
/// draws the corner as the lane's end (`┘`), else as its start (`┐`).
fn markEdge(cells: []Cell, me: usize, k: usize, closing: bool) void {
    if (k > cells.len - 1) return;
    const lo = @min(me, k);
    const hi = @max(me, k);
    var x = lo + 1;
    while (x < hi) : (x += 1) if (cells[x] == .empty) {
        cells[x] = .horiz;
    };
    cells[k] = if (k > me) (if (closing) .merge_right else .branch_right) else (if (closing) .merge_left else .branch_left);
}

pub const State = struct {
    scroll: usize = 0,
    detail_scroll: usize = 0,
    /// A jump landed off screen: centre it on the next paint.
    center_next: bool = false,
};

pub const SortCol = enum {
    none,
    date,
    author,
    subject,

    pub fn label(c: SortCol) []const u8 {
        return switch (c) {
            .none => "GRAPH",
            .date => "DATE",
            .author => "AUTHOR",
            .subject => "SUBJECT",
        };
    }

    pub fn next(c: SortCol) SortCol {
        return switch (c) {
            .none => .date,
            .date => .author,
            .author => .subject,
            .subject => .none,
        };
    }
};

/// `none` is git's own topological order (the lanes only make sense
/// there); a column sorts the list and the lanes collapse to a dot.
pub const Sort = struct {
    col: SortCol = .none,
    asc: bool = false,
};

/// The display order under `sort`: indices into `commits`. `none`
/// keeps git's order; date sorts newest first unless `asc`; author and
/// subject sort A–Z (case-insensitive) unless `!asc`… — every column
/// reads `asc` the same way, and ties keep git's order.
pub fn sortOrder(arena: Allocator, commits: []const parse.Commit, sort: Sort) Allocator.Error![]u32 {
    const out = try arena.alloc(u32, commits.len);
    for (out, 0..) |*o, i| o.* = @intCast(i);
    if (sort.col == .none) return out;
    const Ctx = struct {
        commits: []const parse.Commit,
        sort: Sort,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            const ca = ctx.commits[a];
            const cb = ctx.commits[b];
            const ord: std.math.Order = switch (ctx.sort.col) {
                .none => .eq,
                .date => std.math.order(ca.time, cb.time),
                .author => orderIgnoreCase(ca.author, cb.author),
                .subject => orderIgnoreCase(ca.subject, cb.subject),
            };
            if (ord == .eq) return a < b;
            return if (ctx.sort.asc) ord == .lt else ord == .gt;
        }
    };
    std.mem.sort(u32, out, Ctx{ .commits = commits, .sort = sort }, Ctx.lessThan);
    return out;
}

fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return std.math.order(lx, ly);
    }
    return std.math.order(a.len, b.len);
}

/// The first commit whose hash starts with `prefix` (ASCII
/// case-insensitive); an empty prefix matches nothing.
pub fn findByHashPrefix(commits: []const parse.Commit, prefix: []const u8) ?usize {
    const p = std.mem.trim(u8, prefix, " \t");
    if (p.len == 0) return null;
    for (commits, 0..) |c, i| {
        if (c.hash.len >= p.len and std.ascii.eqlIgnoreCase(c.hash[0..p.len], p)) return i;
    }
    return null;
}

// ─── hit ids ────────────────────────────────────────────────────────────

/// Rows are their virtual index (the WIP row is 0 when shown); the
/// controls live above `special_base`.
pub const special_base: u32 = 0xF000_0000;
pub const divider_id: u32 = 0xF000_0001;
const sort_base: u32 = 0xF100_0000;
const wip_btn_base: u32 = 0xF200_0000;
const detail_row_base: u32 = 0xF300_0000;

pub fn sortId(c: SortCol) u32 {
    return sort_base + @intFromEnum(c);
}

pub fn sortOf(id: u32) ?SortCol {
    if (id < sort_base or id >= sort_base + 4) return null;
    return @enumFromInt(id - sort_base);
}

/// The three WIP buttons, in paint order.
pub const WipButton = enum { stage_all, unstage_all, commit };

pub fn wipButtonId(b: WipButton) u32 {
    return wip_btn_base + @intFromEnum(b);
}

pub fn wipButtonOf(id: u32) ?WipButton {
    if (id < wip_btn_base or id >= wip_btn_base + 3) return null;
    return @enumFromInt(id - wip_btn_base);
}

pub fn detailRowId(i: u32) u32 {
    return detail_row_base + i;
}

pub fn detailRowOf(id: u32) ?u32 {
    if (id < detail_row_base or id >= detail_row_base + 0x100_0000) return null;
    return id - detail_row_base;
}

// ─── the document ───────────────────────────────────────────────────────

/// What the detail panel shows: a commit (its message and files), or
/// the working tree (its entries, with the staging buttons).
pub const DetailDoc = struct {
    title: []const u8,
    message: []const u8 = "",
    files: []const parse.DetailFile = &.{},
    /// The working tree's rows instead of a commit's.
    wip: bool = false,
    entries: []const parse.Entry = &.{},
    pending: bool = false,
};

pub const Doc = struct {
    commits: []const parse.Commit,
    lanes: []const Lane,
    /// Display order: indices into `commits`; `commits.len` long.
    order: []const u32,
    /// Over the virtual rows: the WIP row first when `has_wip`.
    cursor: usize,
    focused: bool,
    header: []const u8,
    lane_spacing: u16 = 1,
    /// Unix seconds, for the age column.
    now: i64,
    sort: Sort = .{},
    has_wip: bool = false,
    /// `WIP @ main · 3 changes`
    wip_label: []const u8 = "",
    /// The detail panel, when open; `detail_w` is its width (0 = none).
    detail: ?DetailDoc = null,
    detail_w: u16 = 0,
    detail_focus: bool = false,
    detail_cursor: usize = 0,
};

/// What `draw` measured.
pub const Painted = struct {
    body: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    list: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    detail: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

const lane_palette_len = 6;

fn laneStyle(t: *const Theme, lane: usize, base: Style) Style {
    return Theme.withFg(base, switch (lane % lane_palette_len) {
        0 => t.accent.fg,
        1 => t.syntax.string.fg,
        2 => t.warn_fg.fg,
        3 => t.info_fg.fg,
        4 => t.syntax.keyword.fg,
        else => t.error_fg.fg,
    });
}

fn glyph(c: Cell, ascii: bool) []const u8 {
    if (ascii) return switch (c) {
        .empty => " ",
        .node => "*",
        .pass => "|",
        .horiz => "-",
        .branch_right, .branch_left => "\\",
        .merge_right, .merge_left => "/",
    };
    return switch (c) {
        .empty => " ",
        .node => "●",
        .pass => "│",
        .horiz => "─",
        .branch_right => "┐",
        .branch_left => "┌",
        .merge_right => "┘",
        .merge_left => "└",
    };
}

pub fn totalRows(doc: Doc) usize {
    return doc.commits.len + @as(usize, if (doc.has_wip) 1 else 0);
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *State, doc: Doc) Painted {
    const t = ui.theme;
    ui.fill(area, t.bg);
    var painted: Painted = .{};
    if (area.isEmpty()) return painted;
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(doc.header, area.w), Theme.onBg(t.accent, t.bg.bg));
    if (area.h < 3) return painted;
    const below = area.splitTop(1).rest;
    drawColumnHeader(ui, pane, below.row(0), doc);
    const body = below.splitTop(1).rest;
    painted.body = body;
    // The detail panel takes the right side when there is room.
    var list = body;
    if (doc.detail != null and doc.detail_w > 0 and body.w >= 60) {
        const dw: u16 = @min(doc.detail_w, body.w / 2);
        list = Rect.init(body.x, body.y, body.w - dw - 1, body.h);
        const div_x = list.right();
        const div_glyph: []const u8 = if (ui.ascii) "|" else "│";
        var y: u16 = 0;
        while (y < body.h) : (y += 1) _ = ui.putStr(div_x, body.y + y, 1, div_glyph, Theme.onBg(t.border, t.bg.bg));
        ui.hit(Rect.init(div_x, body.y, 1, body.h), .{ .script_hit = .{ .pane = pane, .id = divider_id } });
        const detail = Rect.init(div_x + 1, body.y, dw, body.h);
        painted.detail = detail;
        drawDetail(ui, pane, detail, view, doc, doc.detail.?);
    }
    painted.list = list;
    drawList(ui, pane, list, view, doc);
    return painted;
}

/// `  GRAPH   DATE ▼   AUTHOR   SUBJECT` — each a chip; the active sort
/// carries its arrow and the chip ground.
fn drawColumnHeader(ui: Ui, pane: PaneId, r: Rect, doc: Doc) void {
    const t = ui.theme;
    ui.fill(r, t.panel_bg);
    var x = r.x + 1;
    const end = r.right();
    inline for (.{ SortCol.none, SortCol.date, SortCol.author, SortCol.subject }) |c| {
        const active = doc.sort.col == c;
        const arrow: []const u8 = if (!active or c == .none) "" else if (doc.sort.asc) (if (ui.ascii) " ^" else " ▲") else (if (ui.ascii) " v" else " ▼");
        const label = ui.fmt(" {s}{s} ", .{ c.label(), arrow });
        const w = ui.width(label);
        if (x + w <= end) {
            const style = if (active) Theme.onBg(t.chip_active, t.panel_bg.bg) else Theme.onBg(t.muted, t.panel_bg.bg);
            const cr = Rect.init(x, r.y, w, 1);
            _ = ui.putStr(x, r.y, w, label, style);
            ui.hit(cr, .{ .script_hit = .{ .pane = pane, .id = sortId(c) } });
            x += w + 1;
        }
    }
}

fn drawList(ui: Ui, pane: PaneId, body: Rect, view: *State, doc: Doc) void {
    const t = ui.theme;
    const total = totalRows(doc);
    if (total == 0) {
        _ = ui.putStr(body.x + 2, body.y + 1, body.w -| 2, "No commits.", Theme.onBg(t.muted, t.bg.bg));
        return;
    }
    const wip: usize = if (doc.has_wip) 1 else 0;
    var widest: usize = 1;
    for (doc.lanes) |l| widest = @max(widest, l.cells.len);
    const step: u16 = 1 + doc.lane_spacing;
    const graph_w: u16 = if (doc.sort.col == .none) @intCast(@min(widest * step + 1, body.w / 2)) else 2;
    const win = list_panel.scrollWindow(&view.scroll, doc.cursor, total, body.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < total and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = body.row(y);
        const sel = i == doc.cursor and doc.focused and !doc.detail_focus;
        const base: Style = if (sel) Theme.onBg(t.fg, t.cursor_line.bg) else t.bg;
        if (sel) ui.fill(r, t.cursor_line);
        if (doc.has_wip and i == 0) {
            // The row first, the buttons after it: the last hit wins.
            ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = 0 } });
            drawWipRow(ui, pane, r, doc, base, graph_w);
            continue;
        }
        const ci = doc.order[i - wip];
        const c = doc.commits[ci];
        // Lanes (git's order only); sorted lists get a dot.
        if (doc.sort.col == .none) {
            if (ci < doc.lanes.len) {
                const l = doc.lanes[ci];
                for (l.cells, 0..) |cell, k| {
                    const x: u16 = r.x + @as(u16, @intCast(k)) * step;
                    if (x >= r.x + graph_w) break;
                    const colour_lane: usize = if (cell == .node) l.lane else k;
                    _ = ui.putStr(x, r.y, 1, glyph(cell, ui.ascii), laneStyle(t, colour_lane, base));
                    // The spacing cells continue a horizontal run.
                    if (doc.lane_spacing > 0 and k + 1 < l.cells.len) {
                        const joins = switch (cell) {
                            .horiz, .branch_left, .merge_left => true,
                            .node => l.cells[k + 1] == .horiz or l.cells[k + 1] == .branch_right or l.cells[k + 1] == .merge_right,
                            else => false,
                        };
                        if (joins) {
                            var s: u16 = 1;
                            while (s <= doc.lane_spacing) : (s += 1) _ = ui.putStr(x + s, r.y, 1, glyph(.horiz, ui.ascii), laneStyle(t, l.lane, base));
                        }
                    }
                }
            }
        } else {
            _ = ui.putStr(r.x, r.y, 1, if (ui.ascii) "*" else "·", laneStyle(t, 0, base));
        }
        var x = r.x + graph_w;
        const end = r.right();
        var sha_style = Theme.onBg(t.warn_fg, base.bg);
        sha_style.bold = false;
        x += ui.putStr(x, r.y, end -| x, c.short(), sha_style);
        x += ui.putStr(x, r.y, end -| x, " ", base);
        if (c.refs.len > 0) {
            x += ui.putStr(x, r.y, end -| x, ui.fmt("({s}) ", .{c.refs}), Theme.onBg(t.info_fg, base.bg));
        }
        var age_buf: [16]u8 = undefined;
        const age = parse.relativeAge(&age_buf, c.time, doc.now);
        const tail = ui.fmt("{s} {s}", .{ c.author, age });
        const tail_w = ui.width(tail);
        const avail: u16 = end -| x;
        const subj_w = if (avail > tail_w + 2) avail - tail_w - 2 else avail;
        x += ui.putStr(x, r.y, subj_w, ui.clipStr(c.subject, subj_w), Theme.onBg(t.fg, base.bg));
        if (avail > tail_w + 2) _ = ui.putStrRight(end, r.y, tail_w, tail, Theme.onBg(t.muted, base.bg));
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
    }
    if (win.needs_bar and body.w > 4) {
        const bar = Rect.init(body.right() - 1, body.y, 1, body.h);
        @import("scrollbar.zig").drawVertical(ui, bar, .{ .pane = pane }, total, body.h, view.scroll);
    }
}

/// `● WIP @ main · 3 changes    [stage all] [unstage all] [commit…]`
fn drawWipRow(ui: Ui, pane: PaneId, r: Rect, doc: Doc, base: Style, graph_w: u16) void {
    const t = ui.theme;
    _ = ui.putStr(r.x, r.y, 1, if (ui.ascii) "*" else "●", Theme.onBg(t.warn_fg, base.bg));
    var x = r.x + graph_w;
    const end = r.right();
    var s = Theme.onBg(t.warn_fg, base.bg);
    s.bold = true;
    x += ui.putStr(x, r.y, end -| x, ui.clipStr(doc.wip_label, end -| x), s);
    x += 2;
    drawWipButtons(ui, pane, r, x, base);
}

pub const wip_buttons = [_]struct { b: WipButton, label: []const u8 }{
    .{ .b = .stage_all, .label = "[stage all]" },
    .{ .b = .unstage_all, .label = "[unstage all]" },
    .{ .b = .commit, .label = "[commit…]" },
};

fn drawWipButtons(ui: Ui, pane: PaneId, r: Rect, start_x: u16, base: Style) void {
    const t = ui.theme;
    var x = start_x;
    const end = r.right();
    for (wip_buttons) |wb| {
        const label = if (ui.ascii and wb.b == .commit) "[commit...]" else wb.label;
        const w = ui.width(label);
        if (x + w > end) break;
        const br = Rect.init(x, r.y, w, 1);
        const style = if (ui.hovered(br)) Theme.onBg(t.chip_active, base.bg) else Theme.onBg(t.chip, base.bg);
        _ = ui.putStr(x, r.y, w, label, style);
        ui.hit(br, .{ .script_hit = .{ .pane = pane, .id = wipButtonId(wb.b) } });
        x += w + 1;
    }
}

/// Bytes of `rest` that go on one row of width `w`: the longest prefix
/// that fits, cut back to the last space when the line continues. Never
/// past `rest.len` — the caller slices `rest` by it.
fn wrapTake(rest: []const u8, w: u16, method: vaxis.gwidth.Method) usize {
    var take = clip.fitCells(rest, w, method);
    if (take < rest.len) {
        if (std.mem.lastIndexOfScalar(u8, rest[0..take], ' ')) |sp| if (sp > 0) {
            take = sp + 1;
        };
    }
    return take;
}

/// The detail panel: title, the message wrapped to the width, a blank,
/// `files (n)` and one row per file (the cursor row banded when the
/// panel has focus). The working tree shows its entries instead, with
/// the staging buttons on the first row.
fn drawDetail(ui: Ui, pane: PaneId, area: Rect, view: *State, doc: Doc, d: DetailDoc) void {
    const t = ui.theme;
    ui.fill(area, t.panel_bg);
    if (area.w < 4 or area.h == 0) return;
    const inner = Rect.init(area.x + 1, area.y, area.w -| 2, area.h);
    // Lines to paint, then a window over them so a long message scrolls.
    var lines: std.ArrayListUnmanaged(struct { text: []const u8, style: Style, file: ?u32 = null, buttons: bool = false }) = .empty;
    var title = Theme.onBg(t.accent, t.panel_bg.bg);
    title.bold = true;
    lines.append(ui.arena, .{ .text = d.title, .style = title }) catch return;
    if (d.wip) {
        lines.append(ui.arena, .{ .text = "", .style = t.panel_bg, .buttons = true }) catch return;
        lines.append(ui.arena, .{ .text = ui.fmt("changes ({d})", .{d.entries.len}), .style = Theme.onBg(t.muted, t.panel_bg.bg) }) catch return;
        for (d.entries, 0..) |e, i| {
            lines.append(ui.arena, .{ .text = ui.fmt("{c} {s}", .{ e.code, e.path }), .style = codeStyle(t, e.code, t.panel_bg), .file = @intCast(i) }) catch return;
        }
    } else if (d.pending) {
        lines.append(ui.arena, .{ .text = "loading…", .style = Theme.onBg(t.muted, t.panel_bg.bg) }) catch return;
    } else {
        var it = std.mem.splitScalar(u8, d.message, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            // Wrap at the width, on spaces where there is one.
            var rest = line;
            if (rest.len == 0) lines.append(ui.arena, .{ .text = "", .style = t.panel_bg }) catch return;
            while (rest.len > 0) {
                const take = wrapTake(rest, inner.w, ui.canvas.widthMethod());
                if (take == 0) break;
                lines.append(ui.arena, .{ .text = std.mem.trimEnd(u8, rest[0..take], " "), .style = Theme.onBg(t.fg, t.panel_bg.bg) }) catch return;
                rest = rest[take..];
            }
        }
        lines.append(ui.arena, .{ .text = "", .style = t.panel_bg }) catch return;
        lines.append(ui.arena, .{ .text = ui.fmt("files ({d})", .{d.files.len}), .style = Theme.onBg(t.muted, t.panel_bg.bg) }) catch return;
        for (d.files, 0..) |f, i| {
            lines.append(ui.arena, .{ .text = ui.fmt("{c} {s}", .{ f.status, f.path }), .style = codeStyle(t, f.status, t.panel_bg), .file = @intCast(i) }) catch return;
        }
    }
    // The cursor row (a file) stays in view.
    var cursor_line: usize = 0;
    for (lines.items, 0..) |l, i| if (l.file != null and l.file.? == doc.detail_cursor) {
        cursor_line = i;
    };
    const win = list_panel.scrollWindow(&view.detail_scroll, if (doc.detail_focus) cursor_line else view.detail_scroll, lines.items.len, inner.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < lines.items.len and y < inner.h) : ({
        i += 1;
        y += 1;
    }) {
        const l = lines.items[i];
        const r = inner.row(y);
        const sel = l.file != null and l.file.? == doc.detail_cursor and doc.detail_focus and doc.focused;
        var style = l.style;
        if (sel) {
            ui.fill(r, t.cursor_line);
            style = Theme.onBg(style, t.cursor_line.bg);
        }
        if (l.buttons) {
            drawWipButtons(ui, pane, r, r.x, t.panel_bg);
            continue;
        }
        _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(l.text, r.w), style);
        if (l.file) |fi| ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = detailRowId(fi) } });
    }
}

fn codeStyle(t: *const Theme, code: u8, base: Style) Style {
    return Theme.withFg(base, switch (code) {
        'A' => t.syntax.string.fg,
        'D' => t.error_fg.fg,
        'M', 'R', 'C', 'T' => t.warn_fg.fg,
        'U' => t.error_fg.fg,
        else => t.muted.fg,
    });
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn commit(hash: []const u8, parents: []const []const u8) parse.Commit {
    return .{ .hash = hash, .parents = parents, .author = "a", .time = 0, .refs = "", .subject = hash };
}

fn identity(arena: Allocator, n: usize) ![]u32 {
    const out = try arena.alloc(u32, n);
    for (out, 0..) |*o, i| o.* = @intCast(i);
    return out;
}

test "layout: a linear chain stays in lane 0" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const cs = [_]parse.Commit{ commit("c", &.{"b"}), commit("b", &.{"a"}), commit("a", &.{}) };
    const l = try layout(a.allocator(), &cs);
    for (l) |row| {
        try testing.expectEqual(@as(u16, 0), row.lane);
        try testing.expectEqual(@as(usize, 1), row.cells.len);
        try testing.expectEqual(Cell.node, row.cells[0]);
    }
}

test "layout: a merge opens a second lane for its second parent, which closes at the fork point" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    // m merges f (a feature commit off base) into main's x.
    //   m -> x, f ; x -> base ; f -> base ; base
    const cs = [_]parse.Commit{ commit("m", &.{ "x", "f" }), commit("x", &.{"base"}), commit("f", &.{"base"}), commit("base", &.{}) };
    const l = try layout(a.allocator(), &cs);
    try testing.expectEqual(@as(u16, 0), l[0].lane);
    try testing.expectEqual(@as(usize, 2), l[0].cells.len);
    try testing.expectEqual(Cell.node, l[0].cells[0]);
    try testing.expectEqual(Cell.branch_right, l[0].cells[1]);
    // x: lane 0, with f's lane passing beside it.
    try testing.expectEqual(@as(u16, 0), l[1].lane);
    try testing.expectEqual(Cell.pass, l[1].cells[1]);
    // f sits in lane 1 while main's lane passes.
    try testing.expectEqual(@as(u16, 1), l[2].lane);
    try testing.expectEqual(Cell.pass, l[2].cells[0]);
    try testing.expectEqual(Cell.node, l[2].cells[1]);
    // base: both lanes expected it; lane 1 closes into lane 0.
    try testing.expectEqual(@as(u16, 0), l[3].lane);
    try testing.expectEqual(Cell.node, l[3].cells[0]);
    try testing.expectEqual(Cell.merge_right, l[3].cells[1]);
}

test "draw paints lanes, sha, subject, the column chips, and registers row hits" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const cs = [_]parse.Commit{ commit("aaaaaaaaaa", &.{"bbbbbbbbbb"}), commit("bbbbbbbbbb", &.{}) };
    const l = try layout(a.allocator(), &cs);
    var f = try Fixture.init(50, 5);
    defer f.deinit();
    var st: State = .{};
    var ui = f.ui();
    ui.ascii = true;
    _ = draw(ui, 1, Rect.init(0, 0, 50, 5), &st, .{ .commits = &cs, .lanes = l, .order = try identity(a.allocator(), 2), .cursor = 0, .focused = true, .header = " graph ", .lane_spacing = 1, .now = 0 });
    try f.expectRow(0, " graph");
    try f.expectRow(1, "  GRAPH   DATE   AUTHOR   SUBJECT");
    try f.expectContains("*  aaaaaaa aaaaaaaaaa");
    try f.expectContains("*  bbbbbbb bbbbbbbbbb");
    try testing.expectEqual(@as(u32, 1), f.hits.at(3, 3).?.script_hit.id);
    try testing.expectEqual(sortId(.date), f.hits.at(11, 1).?.script_hit.id);
}

const three = [_]parse.Commit{
    .{ .hash = "c1", .parents = &.{}, .author = "zed", .time = 30, .refs = "", .subject = "beta" },
    .{ .hash = "b2", .parents = &.{}, .author = "Amy", .time = 10, .refs = "", .subject = "alpha" },
    .{ .hash = "a3", .parents = &.{}, .author = "mia", .time = 20, .refs = "", .subject = "Gamma" },
};

test "sortOrder: none keeps git's order; date newest first (asc flips); author and subject A–Z ignoring case" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, try sortOrder(arena, &three, .{}));
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1 }, try sortOrder(arena, &three, .{ .col = .date }));
    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, try sortOrder(arena, &three, .{ .col = .date, .asc = true }));
    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, try sortOrder(arena, &three, .{ .col = .author, .asc = true }));
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1 }, try sortOrder(arena, &three, .{ .col = .author, .asc = false }));
    try testing.expectEqualSlices(u32, &.{ 1, 0, 2 }, try sortOrder(arena, &three, .{ .col = .subject, .asc = true }));
}

test "findByHashPrefix: case-insensitive, the first match wins, an empty prefix matches nothing" {
    try testing.expectEqual(@as(?usize, 2), findByHashPrefix(&three, "A3"));
    try testing.expectEqual(@as(?usize, 0), findByHashPrefix(&three, "c"));
    try testing.expectEqual(@as(?usize, null), findByHashPrefix(&three, ""));
    try testing.expectEqual(@as(?usize, null), findByHashPrefix(&three, "zz"));
    try testing.expectEqual(@as(?usize, null), findByHashPrefix(&three, "c1c1c1"));
}

test "the WIP row paints its three buttons with hits, and the detail panel lists a commit's files" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const cs = [_]parse.Commit{commit("aaaaaaaaaa", &.{})};
    const l = try layout(arena, &cs);
    var f = try Fixture.init(120, 8);
    defer f.deinit();
    var st: State = .{};
    var ui = f.ui();
    ui.ascii = true;
    const files = [_]parse.DetailFile{ .{ .status = 'M', .path = "src/a.zig" }, .{ .status = 'A', .path = "new.txt" } };
    const p = draw(ui, 1, Rect.init(0, 0, 120, 8), &st, .{
        .commits = &cs,
        .lanes = l,
        .order = try identity(arena, 1),
        .cursor = 0,
        .focused = true,
        .header = " graph ",
        .now = 0,
        .has_wip = true,
        .wip_label = "WIP @ main · 2 changes",
        .detail = .{ .title = "aaaaaaa · a", .message = "Subject line\n\nA body that is long enough to wrap inside the panel.", .files = &files },
        .detail_w = 40,
        .detail_focus = true,
        .detail_cursor = 1,
    });
    try testing.expectEqual(@as(u16, 40), p.detail.w);
    try f.expectContains("WIP @ main · 2 changes");
    try f.expectContains("[stage all] [unstage all] [commit...]");
    // The buttons sit on row 2 (title, chips, WIP); find them by hit.
    var found_stage = false;
    var found_commit = false;
    var x: u16 = 0;
    while (x < p.list.right()) : (x += 1) {
        if (f.hits.at(x, 2)) |h| if (h == .script_hit) {
            if (wipButtonOf(h.script_hit.id)) |b| switch (b) {
                .stage_all => found_stage = true,
                .commit => found_commit = true,
                else => {},
            };
        };
    }
    try testing.expect(found_stage);
    try testing.expect(found_commit);
    try testing.expectEqual(@as(u32, 0), f.hits.at(1, 2).?.script_hit.id);
    try testing.expectEqual(@as(u32, 1), f.hits.at(1, 3).?.script_hit.id);
    try testing.expectEqual(divider_id, f.hits.at(p.list.right(), 4).?.script_hit.id);
    try f.expectContains("files (2)");
    try f.expectContains("M src/a.zig");
    try f.expectContains("A new.txt");
    try testing.expectEqual(@as(u32, 1), detailRowOf(f.hits.at(p.detail.x + 2, 7).?.script_hit.id).?);
}

test "wrapTake: a line one cell wider than the panel takes the width, not the clipped form's bytes" {
    const line = "x" ** 41;
    try testing.expectEqual(@as(usize, 40), wrapTake(line, 40, .unicode));
    try testing.expectEqual(@as(usize, 41), wrapTake(line, 41, .unicode));
    try testing.expectEqual(@as(usize, 41), wrapTake(line, 120, .unicode));
    // A continuing line breaks after its last space; a lone word does not.
    try testing.expectEqual(@as(usize, 6), wrapTake("hello world", 8, .unicode));
    try testing.expectEqual(@as(usize, 8), wrapTake("helloworld", 8, .unicode));
    // Every width against every length walks the remainder without
    // slicing past it — the loop drawDetail runs.
    var w: u16 = 1;
    while (w <= 45) : (w += 1) {
        var rest: []const u8 = line;
        while (rest.len > 0) {
            const take = wrapTake(rest, w, .unicode);
            try testing.expect(take > 0 and take <= rest.len);
            rest = rest[take..];
        }
    }
}
