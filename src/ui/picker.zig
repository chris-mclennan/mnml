//! Picker — the fuzzy list overlay behind the buffer list, the file
//! finder and the command palette: a centered box with the query on
//! its first row, the count on the right, and the ranked items below
//! with a marker on the selected one. The app ranks (`rank` + `gather`
//! on `fuzzy.score`) and hands the filtered slice to `draw`; `accept`
//! is an index into THAT slice, so the app maps it back through the
//! order `rank` returned.
//!
//! Every visible row registers `.overlay_item(i)`; the scrollbar, when
//! the list outgrows the box, registers under `scrollbar_owner`. The
//! box never exceeds the screen — the Rust picker panicked below 30
//! columns because a comment said the clamp would "clip, fine".

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const text_field = @import("text_field.zig");
const scrollbar = @import("scrollbar.zig");
const fuzzy = @import("fuzzy.zig");
const list_panel = @import("list_panel.zig");
const key_mod = @import("../core/key.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const Key = key_mod.Key;
pub const Caret = text_field.Caret;

pub const Item = struct {
    label: []const u8,
    /// Right-aligned, muted: a path, a command id, a time.
    detail: ?[]const u8 = null,
    /// After the label, muted: a key chord.
    hint: ?[]const u8 = null,
};

pub const State = struct {
    title: []const u8,
    query: text_field.Buf = .empty,
    caret: usize = 0,
    cursor: usize = 0,
    scroll: usize = 0,
    /// The unfiltered count, for ` N of M `; null paints ` N `.
    total: ?usize = null,
    /// Rows the list had last frame — paging reads it.
    rows: usize = 0,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.query.deinit(gpa);
        s.* = .{ .title = s.title };
    }

    pub fn queryText(s: *const State) []const u8 {
        return s.query.items;
    }
};

pub const Outcome = union(enum) { consumed, cancel, changed, accept: usize };

/// The `.scrollbar` owner the picker's bar registers under.
pub const scrollbar_owner: ids.PaneId = std.math.maxInt(ids.PaneId);

pub const min_width: u16 = 30;
pub const max_width: u16 = 90;
pub const min_height: u16 = 7;
pub const compact_height: u16 = 22;
pub const no_matches = "  (no matches)";

/// ↑↓ / ctrl+p ctrl+n / ctrl+j ctrl+k move, page keys page, enter
/// accepts the cursor, esc cancels, typing changes the query (and
/// rewinds the cursor). `count` is the length of the slice last drawn.
pub fn handleKey(s: *State, gpa: Allocator, key: Key, count: usize) Allocator.Error!Outcome {
    const last = count -| 1;
    if (s.cursor > last) s.cursor = last;
    const page = @max(1, s.rows);
    switch (key.code) {
        .esc => return .cancel,
        .enter => return if (count > 0) .{ .accept = s.cursor } else .consumed,
        .up => s.cursor -|= 1,
        .down => s.cursor = @min(s.cursor + 1, last),
        .page_up => s.cursor -|= page,
        .page_down => s.cursor = @min(s.cursor + page, last),
        .char => |c| if (key.mods.ctrl and !key.mods.alt) switch (c) {
            'p', 'k' => s.cursor -|= 1,
            'n', 'j' => s.cursor = @min(s.cursor + 1, last),
            'u' => s.cursor -|= page,
            'd' => s.cursor = @min(s.cursor + page, last),
            else => return editKey(s, gpa, key),
        } else return editKey(s, gpa, key),
        else => return editKey(s, gpa, key),
    }
    return .consumed;
}

fn editKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
    switch (try text_field.handleKey(&s.query, &s.caret, gpa, key)) {
        .changed => {
            s.cursor = 0;
            s.scroll = 0;
            return .changed;
        },
        else => return .consumed,
    }
}

pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
    try text_field.insert(&s.query, &s.caret, gpa, text);
    s.cursor = 0;
    s.scroll = 0;
}

/// Indices into `items` that match `query`, best first (stable for
/// ties, so the app's own order breaks them). An empty query keeps
/// every item in place.
pub fn rank(arena: Allocator, query: []const u8, items: []const Item) Allocator.Error![]const usize {
    const Scored = struct { idx: usize, score: u32 };
    var scored: std.ArrayListUnmanaged(Scored) = .empty;
    for (items, 0..) |it, i| {
        var best = fuzzy.score(query, it.label);
        if (it.detail) |d| if (fuzzy.score(query, d)) |sd| {
            // The id / path is a weaker signal than the label.
            const weak = sd -| 50;
            best = if (best) |b| @max(b, weak) else weak;
        };
        if (best) |b| try scored.append(arena, .{ .idx = i, .score = b });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn less(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.idx < b.idx;
        }
    }.less);
    const out = try arena.alloc(usize, scored.items.len);
    for (scored.items, 0..) |s, i| out[i] = s.idx;
    return out;
}

/// `items` in `order` — what `draw` takes.
pub fn gather(arena: Allocator, items: []const Item, order: []const usize) Allocator.Error![]const Item {
    const out = try arena.alloc(Item, order.len);
    for (order, 0..) |idx, i| out[i] = items[idx];
    return out;
}

/// The box: query row, then the rows. Registers `.overlay_item(i)` per
/// visible row. Returns the query caret.
pub fn draw(ui: Ui, area: Rect, s: *State, items: []const Item) ?Caret {
    const t = ui.theme;
    if (area.isEmpty()) return null;
    const w = @min(std.math.clamp(area.w -| 8, min_width, max_width), area.w);
    const compact = std.math.clamp(@as(u16, @intCast(@min(items.len, 1000))) + 3, min_height, compact_height);
    const generous = @max(@min(area.h -| 4, (area.h / 5) * 4), min_height);
    const h = @min(@min(compact, generous), area.h);
    const inner = overlay.box(ui, area, w, h, s.title, .center);
    if (inner.isEmpty()) return null;
    const bg = t.overlay_bg.bg;

    // ── query row ──
    const qr = inner.row(0);
    const count_text = if (s.total) |total| blk: {
        if (s.query.items.len == 0 or items.len == total) break :blk ui.fmt(" {d} ", .{items.len});
        break :blk ui.fmt(" {d} of {d} ", .{ items.len, total });
    } else ui.fmt(" {d} ", .{items.len});
    const count_w = ui.width(count_text);
    var field_w = qr.w -| 2;
    if (qr.w >= count_w + 8) {
        _ = ui.putStrRight(qr.right(), qr.y, count_w, count_text, Theme.onBg(t.muted, bg));
        field_w = qr.w -| (2 + count_w + 1);
    }
    const qf = Rect.init(qr.x + 2, qr.y, field_w, 1);
    const caret = text_field.draw(ui, qf, s.query.items, s.caret, .{ .style = Theme.onBg(t.fg, bg) });
    if (inner.h < 2) return caret;

    // ── rows ──
    const list_area = Rect.init(inner.x, inner.y + 1, inner.w, inner.h - 1);
    s.rows = list_area.h;
    if (s.cursor >= items.len) s.cursor = items.len -| 1;
    if (items.len == 0) {
        s.scroll = 0;
        _ = ui.putStr(list_area.x, list_area.y, list_area.w, no_matches, Theme.onBg(t.muted, bg));
        return caret;
    }
    const win = list_panel.scrollWindow(&s.scroll, s.cursor, items.len, list_area.h);
    var rows_rect = list_area;
    if (win.needs_bar and list_area.w > 4) {
        const split = list_area.splitRight(1);
        rows_rect = split.left;
        scrollbar.drawVertical(ui, split.rest, .{ .pane = scrollbar_owner }, items.len, list_area.h, s.scroll);
    }
    const marker = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const it = items[idx];
        const r = rows_rect.row(@intCast(i));
        const selected = idx == s.cursor;
        const row_bg = if (selected) t.chip.bg else bg;
        ui.fill(r, .{ .bg = row_bg });
        if (selected) _ = ui.putStr(r.x, r.y, 1, marker, Theme.onBg(t.accent, row_bg));
        var x = r.x + list_panel.marker_w;
        var right = r.right() -| 1;
        // The detail keeps the right edge; the label gets what is left,
        // never fewer than twelve cells.
        if (it.detail) |d| {
            const budget = (right -| x) -| 13;
            if (budget >= 2) {
                const shown = ui.clipStr(d, budget);
                right = ui.putStrRight(right, r.y, budget, shown, Theme.onBg(t.muted, row_bg)) -| 1;
            }
        }
        var label_style = Theme.onBg(t.fg, row_bg);
        if (selected) label_style.bold = true;
        x += ui.putStr(x, r.y, right -| x, ui.clipStr(it.label, right -| x), label_style);
        if (it.hint) |hh| {
            if (right -| x > 2) {
                const shown = ui.fmt(" {s}", .{hh});
                _ = ui.putStr(x, r.y, right -| x, ui.clipStr(shown, right -| x), Theme.onBg(t.muted, row_bg));
            }
        }
        ui.hit(r, .{ .overlay_item = @intCast(idx) });
    }
    return caret;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const files = [_]Item{
    .{ .label = "a.txt", .detail = "src/a.txt" },
    .{ .label = "b.txt", .detail = "src/b.txt", .hint = "ctrl+2" },
    .{ .label = "c.txt", .detail = "lib/c.txt" },
};

test "the box shows the title, the query, the count, ranked rows with hits, and the caret" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    var s: State = .{ .title = "Buffers", .total = 3 };
    defer s.deinit(testing.allocator);
    const caret = draw(f.ui(), f.full(), &s, &files);
    try f.expectContains(" Buffers ");
    try f.expectContains("a.txt");
    try f.expectContains("c.txt");
    try f.expectContains("src/b.txt");
    try f.expectContains("ctrl+2");
    // 72 wide (80-8), 6 rows (3 items + 3 → min 7): box y = (20-7)/2 = 6.
    // Query row is inner row 7; rows 8..10.
    try testing.expectEqual(Caret{ .x = 7, .y = 7 }, caret.?);
    try testing.expectEqual(@as(u32, 0), f.hits.at(10, 8).?.overlay_item);
    try testing.expectEqual(@as(u32, 2), f.hits.at(10, 10).?.overlay_item);
    try testing.expect(f.hits.at(10, 11) == null);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, f.row(7, &buf), " 3 │"));
    // The selected row: marker + bold label + a chip ground.
    try testing.expectEqualStrings("\u{258c}", f.cell(5, 8).char.grapheme);
    try testing.expect(f.style(6, 8).bold);
    try testing.expect(f.bgEql(6, 8, f.theme.chip));
    try testing.expect(!f.style(6, 9).bold);
    // The detail sits against the right edge with one cell of air.
    try testing.expect(std.mem.endsWith(u8, f.row(8, &buf), "src/a.txt │"));
}

const names = [_]Item{ .{ .label = "alpha" }, .{ .label = "beta" }, .{ .label = "gamma" } };

test "typing filters via rank + gather, the count says N of M, the cursor rewinds" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    var s: State = .{ .title = "Files", .total = names.len };
    defer s.deinit(testing.allocator);
    const gpa = testing.allocator;
    _ = try handleKey(&s, gpa, Key.named(.down), names.len);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.char('g'), names.len));
    try testing.expectEqual(@as(usize, 0), s.cursor);
    const order = try rank(f.arena_state.allocator(), s.queryText(), &names);
    try testing.expectEqualSlices(usize, &.{2}, order);
    const shown = try gather(f.arena_state.allocator(), &names, order);
    _ = draw(f.ui(), f.full(), &s, shown);
    try f.expectContains("gamma");
    try f.expectLacks("alpha");
    try f.expectContains(" 1 of 3 ");
    try testing.expectEqual(@as(usize, 0), (try handleKey(&s, gpa, Key.named(.enter), shown.len)).accept);
    // No matches: the row says so and enter does nothing.
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.char('z'), shown.len));
    const none = try rank(f.arena_state.allocator(), s.queryText(), &names);
    try testing.expectEqual(@as(usize, 0), none.len);
    _ = draw(f.ui(), f.full(), &s, &.{});
    try f.expectContains("(no matches)");
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.named(.enter), 0));
    try testing.expectEqual(Outcome.cancel, try handleKey(&s, gpa, Key.named(.esc), 0));
    // An empty query keeps the app's order; a label hit outranks a detail hit.
    const all = try rank(f.arena_state.allocator(), "", &files);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, all);
    const by_detail = try rank(f.arena_state.allocator(), "lib", &files);
    try testing.expectEqualSlices(usize, &.{2}, by_detail);
    const mixed = [_]Item{ .{ .label = "zz", .detail = "open" }, .{ .label = "open" } };
    const o = try rank(f.arena_state.allocator(), "open", &mixed);
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, o);
}

test "a long list scrolls with the cursor, pages, and shows a bar" {
    var f = try Fixture.init(50, 16);
    defer f.deinit();
    const arena = f.arena_state.allocator();
    const many = try arena.alloc(Item, 40);
    for (many, 0..) |*it, i| it.* = .{ .label = try std.fmt.allocPrint(arena, "item {d}", .{i}) };
    var s: State = .{ .title = "Many" };
    defer s.deinit(testing.allocator);
    _ = draw(f.ui(), f.full(), &s, many);
    // h = min(43→22, min(12, 12)→12, 16) = 12 → 9 rows.
    try testing.expectEqual(@as(usize, 9), s.rows);
    try f.expectContains("item 8");
    try f.expectLacks("item 9");
    try testing.expect(f.hits.at(44, 5).? == .scrollbar);
    try testing.expectEqual(scrollbar_owner, f.hits.at(44, 5).?.scrollbar.owner.pane);
    _ = try handleKey(&s, testing.allocator, Key.named(.page_down), many.len);
    try testing.expectEqual(@as(usize, 9), s.cursor);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('n'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('j'), many.len);
    try testing.expectEqual(@as(usize, 11), s.cursor);
    f.hits.reset();
    _ = draw(f.ui(), f.full(), &s, many);
    try testing.expectEqual(@as(usize, 3), s.scroll);
    try f.expectContains("item 11");
    try f.expectLacks("item 2");
    try testing.expectEqual(@as(u32, 11), f.hits.at(10, 12).?.overlay_item);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('k'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('p'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    try testing.expectEqual(@as(usize, 0), s.cursor);
    try paste(&s, testing.allocator, "item 3");
    try testing.expectEqualStrings("item 3", s.queryText());
}

test "the box never exceeds a tiny screen" {
    var s: State = .{ .title = "Tiny" };
    defer s.deinit(testing.allocator);
    inline for (.{ .{ 29, 5 }, .{ 12, 3 }, .{ 2, 2 }, .{ 40, 1 } }) |wh| {
        var f = try Fixture.init(wh[0], wh[1]);
        defer f.deinit();
        _ = draw(f.ui(), f.full(), &s, &files);
        for (f.hits.items.items) |e| try testing.expect(f.full().intersect(e.rect).eql(e.rect));
    }
}
