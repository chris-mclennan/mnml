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

pub const State = struct { scroll: usize = 0 };

pub const Doc = struct {
    commits: []const parse.Commit,
    lanes: []const Lane,
    cursor: usize,
    focused: bool,
    header: []const u8,
    lane_spacing: u16 = 1,
    /// Unix seconds, for the age column.
    now: i64,
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

pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *State, doc: Doc) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(doc.header, area.w), Theme.onBg(t.accent, t.bg.bg));
    if (area.h < 2) return;
    const body = area.splitTop(1).rest;
    if (doc.commits.len == 0) {
        _ = ui.putStr(body.x + 2, body.y + 1, body.w -| 2, "No commits.", Theme.onBg(t.muted, t.bg.bg));
        return;
    }
    var widest: usize = 1;
    for (doc.lanes) |l| widest = @max(widest, l.cells.len);
    const step: u16 = 1 + doc.lane_spacing;
    const graph_w: u16 = @intCast(@min(widest * step + 1, body.w / 2));
    const win = list_panel.scrollWindow(&view.scroll, doc.cursor, doc.commits.len, body.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < doc.commits.len and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = body.row(y);
        const c = doc.commits[i];
        const sel = i == doc.cursor and doc.focused;
        const base: Style = if (sel) Theme.onBg(t.fg, t.cursor_line.bg) else t.bg;
        if (sel) ui.fill(r, t.cursor_line);
        // Lanes.
        if (i < doc.lanes.len) {
            const l = doc.lanes[i];
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
        @import("scrollbar.zig").drawVertical(ui, bar, .{ .pane = pane }, doc.commits.len, body.h, view.scroll);
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn commit(hash: []const u8, parents: []const []const u8) parse.Commit {
    return .{ .hash = hash, .parents = parents, .author = "a", .time = 0, .refs = "", .subject = hash };
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

test "draw paints lanes, sha, subject and registers row hits" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const cs = [_]parse.Commit{ commit("aaaaaaaaaa", &.{"bbbbbbbbbb"}), commit("bbbbbbbbbb", &.{}) };
    const l = try layout(a.allocator(), &cs);
    var f = try Fixture.init(50, 4);
    defer f.deinit();
    var st: State = .{};
    var ui = f.ui();
    ui.ascii = true;
    draw(ui, 1, Rect.init(0, 0, 50, 4), &st, .{ .commits = &cs, .lanes = l, .cursor = 0, .focused = true, .header = " graph ", .lane_spacing = 1, .now = 0 });
    try f.expectRow(0, " graph");
    try f.expectContains("*  aaaaaaa aaaaaaaaaa");
    try f.expectContains("*  bbbbbbb bbbbbbbbbb");
    try testing.expectEqual(@as(u32, 1), f.hits.at(3, 2).?.script_hit.id);
}
