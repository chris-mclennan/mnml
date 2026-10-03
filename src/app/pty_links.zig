//! A terminal pane's links: the URLs and declared keys (`link_rules`)
//! in the lines on screen, for the painter to give the link look
//! (`pty_view.Props.links`). The pane opens them itself —
//! Ctrl/Cmd+click and the right-click Link rows (`pty_pane.linkUnder`).
//!
//! A terminal repaints far more often than its text changes, and a
//! flood changes every row every frame, so the matching is cached per
//! pane by the line's own text: a line already seen — unchanged, or
//! only scrolled to another row — is not matched again. A line not
//! seen before is matched once it has held still for a frame (its row
//! shows the same text as the frame before): while output streams past
//! nothing is matched at all, and the frame after it stops links the
//! screen (`State.pending` asks for that frame). The cache holds the
//! lines of the last frame and nothing else, and drops everything when
//! the rule set is rebuilt.
//!
//! A line is a run of rows the terminal soft-wrapped, so a URL broken
//! over two rows links whole on both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pty = @import("pty");
const link_rules = @import("link_rules.zig");
const link_span = @import("../ui/link_span.zig");
const RowLinks = @import("../ui/pty_view.zig").RowLinks;
const Span = link_span.Span;

const Entry = struct {
    /// gpa-owned, each `url` too.
    spans: []Span,
    stamp: u32,
};

pub const Cache = struct {
    /// A line's text (gpa-owned key) → its links.
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    /// The rule set's generation the entries were found under.
    gen: u32 = 0,
    stamp: u32 = 0,
    /// Lines matched since the pane opened — what a test reads to see
    /// that an unchanged line was not matched again.
    matched: u32 = 0,
    /// The line being read, reused frame to frame.
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Per row, the hash of the line that started there last frame (0:
    /// none) — how a line is known to have held still.
    prev: std.ArrayListUnmanaged(u64) = .empty,

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        c.clear(gpa);
        c.map.deinit(gpa);
        c.buf.deinit(gpa);
        c.prev.deinit(gpa);
    }

    fn clear(c: *Cache, gpa: Allocator) void {
        var it = c.map.iterator();
        while (it.next()) |e| drop(gpa, e.key_ptr.*, e.value_ptr.spans);
        c.map.clearRetainingCapacity();
    }
};

fn drop(gpa: Allocator, key: []const u8, spans: []Span) void {
    for (spans) |s| gpa.free(s.url);
    gpa.free(spans);
    gpa.free(key);
}

/// The links of every row `grid` shows, on `arena`, one entry per row
/// that has any: the row's text and its spans in that text. An
/// out-of-memory line is a line without links.
pub fn rows(gpa: Allocator, arena: Allocator, st: *link_rules.State, c: *Cache, grid: *const pty.Grid) Allocator.Error![]const RowLinks {
    if (c.gen != st.gen) {
        c.clear(gpa);
        c.gen = st.gen;
    }
    c.stamp +%= 1;
    var out: std.ArrayListUnmanaged(RowLinks) = .empty;
    const n = grid.rows();
    if (c.prev.items.len != n) {
        try c.prev.resize(gpa, n);
        @memset(c.prev.items, 0);
    }
    var y: u16 = 0;
    while (y < n) {
        var last = y;
        while (last + 1 < n and grid.rowWraps(last)) last += 1;
        // The line's text, and where each of its rows starts in it.
        const starts = try arena.alloc(usize, last - y + 2);
        c.buf.clearRetainingCapacity();
        var r = y;
        while (r <= last) : (r += 1) {
            starts[r - y] = c.buf.items.len;
            try appendRow(gpa, &c.buf, grid, r);
        }
        starts[last - y + 1] = c.buf.items.len;
        const h = std.hash.Wyhash.hash(0, c.buf.items) | 1;
        const still = c.prev.items[y] == h;
        c.prev.items[y] = h;
        r = y + 1;
        while (r <= last) : (r += 1) c.prev.items[r] = 0;
        if (lookup(gpa, st, c, c.buf.items, still)) |hit| if (hit.spans.len > 0) {
            r = y;
            while (r <= last) : (r += 1) {
                const a = starts[r - y];
                const b = starts[r - y + 1];
                var mine: std.ArrayListUnmanaged(Span) = .empty;
                for (hit.spans) |s| {
                    if (s.end <= a or s.start >= b) continue;
                    try mine.append(arena, .{ .start = @max(s.start, a) - a, .end = @min(s.end, b) - a, .url = s.url });
                }
                if (mine.items.len > 0) try out.append(arena, .{ .y = r, .text = hit.text[a..b], .spans = mine.items });
            }
        };
        y = last + 1;
    }
    sweep(gpa, c);
    return out.items;
}

const Hit = struct { text: []const u8, spans: []const Span };

/// The line's links, from the cache or found now (and kept) — found
/// only when it held still (`still`); otherwise none yet, and the rule
/// set's `pending` asks for the frame that will find them.
fn lookup(gpa: Allocator, st: *link_rules.State, c: *Cache, text: []const u8, still: bool) ?Hit {
    if (c.map.getEntry(text)) |e| {
        e.value_ptr.stamp = c.stamp;
        return .{ .text = e.key_ptr.*, .spans = e.value_ptr.spans };
    }
    if (!still) {
        st.pending = true;
        return null;
    }
    c.matched += 1;
    const found = link_rules.find(st, gpa, text) catch return null;
    const key = gpa.dupe(u8, text) catch {
        drop(gpa, &.{}, found);
        return null;
    };
    c.map.put(gpa, key, .{ .spans = found, .stamp = c.stamp }) catch {
        drop(gpa, key, found);
        return null;
    };
    return .{ .text = key, .spans = found };
}

/// Out with every line this frame did not show.
fn sweep(gpa: Allocator, c: *Cache) void {
    if (c.map.count() == 0) return;
    var stale: [64][]const u8 = undefined;
    while (true) {
        var k: usize = 0;
        var it = c.map.iterator();
        while (it.next()) |e| if (e.value_ptr.stamp != c.stamp) {
            stale[k] = e.key_ptr.*;
            k += 1;
            if (k == stale.len) break;
        };
        for (stale[0..k]) |key| {
            const kv = c.map.fetchRemove(key) orelse continue;
            drop(gpa, kv.key, kv.value.spans);
        }
        if (k < stale.len) return;
    }
}

/// Row `y`'s text as painted: a blank cell is a space, a wide glyph's
/// spacer adds nothing (the glyph is two cells wide already).
fn appendRow(gpa: Allocator, buf: *std.ArrayListUnmanaged(u8), grid: *const pty.Grid, y: u16) Allocator.Error!void {
    var x: u16 = 0;
    while (x < grid.cols()) : (x += 1) {
        const cell = grid.cell(x, y);
        switch (cell.wide) {
            .spacer_tail, .spacer_head => continue,
            .narrow, .wide => {},
        }
        if (cell.cp == 0) {
            try buf.append(gpa, ' ');
            continue;
        }
        try appendCp(gpa, buf, cell.cp);
        for (cell.grapheme) |cp| try appendCp(gpa, buf, cp);
    }
}

fn appendCp(gpa: Allocator, buf: *std.ArrayListUnmanaged(u8), cp: u21) Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch return buf.append(gpa, '?');
    try buf.appendSlice(gpa, tmp[0..n]);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn testRule(st: *link_rules.State, pattern: []const u8, url: []const u8) !void {
    const regex = @import("../regex/regex.zig");
    try st.rules.append(t.allocator, .{
        .owner = try t.allocator.dupe(u8, "acme"),
        .re = try regex.Regex.compile(pattern, .{ .dialect = .perl }),
        .url = try t.allocator.dupe(u8, url),
    });
}

test "rows: a key and a PR ref link on their rows; an unchanged line is not matched again, a changed one is; a wrapped URL links whole on both rows; a new rule set drops the cache" {
    var st: link_rules.State = .{};
    defer st.deinit(t.allocator);
    try testRule(&st, "[A-Z][A-Z0-9]+-\\d+", "https://t.example/browse/{0}");
    try testRule(&st, "([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#(\\d+)", "https://bitbucket.org/{1}/{2}/pull-requests/{3}");
    var term: pty.vt.Terminal = try .init(t.io, t.allocator, .{ .cols = 20, .rows = 4 });
    defer term.deinit(t.allocator);
    var s = term.vtStream();
    defer s.deinit();
    var grid: pty.Grid = .{};
    defer grid.deinit(t.allocator);
    var c: Cache = .{};
    defer c.deinit(t.allocator);
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    s.nextSlice("fix ENG-123 now\r\nacme/widget#42\r\n");
    try grid.update(t.allocator, &term);
    // New text links once it has held still for a frame: the first
    // frame matches nothing and asks for another.
    var got = try rows(t.allocator, arena, &st, &c, &grid);
    try t.expectEqual(@as(usize, 0), got.len);
    try t.expectEqual(@as(u32, 0), c.matched);
    try t.expect(st.pending);
    st.pending = false;
    got = try rows(t.allocator, arena, &st, &c, &grid);
    try t.expect(!st.pending);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqual(@as(u16, 0), got[0].y);
    try t.expectEqualStrings("ENG-123", got[0].text[got[0].spans[0].start..got[0].spans[0].end]);
    try t.expectEqualStrings("https://t.example/browse/ENG-123", got[0].spans[0].url);
    try t.expectEqualStrings("https://bitbucket.org/acme/widget/pull-requests/42", got[1].spans[0].url);
    // Four rows, three lines matched: the two blank rows are one text.
    try t.expectEqual(@as(u32, 3), c.matched);
    // The same screen again: nothing is matched.
    got = try rows(t.allocator, arena, &st, &c, &grid);
    try t.expectEqual(@as(u32, 3), c.matched);
    try t.expectEqual(@as(usize, 2), got.len);
    // One row changes: that row alone is matched.
    s.nextSlice("ENG-9");
    try grid.update(t.allocator, &term);
    _ = try rows(t.allocator, arena, &st, &c, &grid);
    got = try rows(t.allocator, arena, &st, &c, &grid);
    try t.expectEqual(@as(u32, 4), c.matched);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqual(@as(u16, 2), got[2].y);
    // A URL the terminal wrapped over two rows links whole on both.
    s.nextSlice("\r\nhttps://example.com/a/b/c/d");
    try grid.update(t.allocator, &term);
    _ = try rows(t.allocator, arena, &st, &c, &grid);
    got = try rows(t.allocator, arena, &st, &c, &grid);
    var wrapped: usize = 0;
    for (got) |rl| for (rl.spans) |sp| if (std.mem.eql(u8, sp.url, "https://example.com/a/b/c/d")) {
        wrapped += 1;
    };
    try t.expectEqual(@as(usize, 2), wrapped);
    // A rebuilt rule set: every line is matched again.
    const before = c.matched;
    st.gen +%= 1;
    _ = try rows(t.allocator, arena, &st, &c, &grid);
    try t.expectEqual(before + grid.rows() - 1, c.matched); // the wrapped pair is one line
}
