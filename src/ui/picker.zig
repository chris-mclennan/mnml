//! Picker — the fuzzy list overlay behind the buffer list, the file
//! finder and the command palette, painted as the Rust editor paints
//! its: a square box `clamp(W-8, 30, 90)` wide, as tall as its items up
//! to 22 rows (never more than four fifths of the screen), the title
//! an accent chip on the top edge, the query on the first inner row
//! with the count (` N ` / ` N of M `) flush right, then the ranked
//! rows: a `▌` on the selected one, the label with the matched
//! characters in the accent, and the detail (a chord, a directory)
//! right-aligned with a cell of air on each side. A list longer than
//! the box gets a scrollbar column. `ui.picker_position` drops the box
//! to the top edge or centres it.
//!
//! The app ranks (`rank` on `fuzzy.score`, Rust's `refilter`: priority
//! desc, score desc, index asc) and hands the filtered slice to `draw`;
//! `accept` is an index into THAT slice, so the app maps it back
//! through the order `rank` returned.
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
    /// Right-aligned, muted: a chord, a path, a time.
    detail: ?[]const u8 = null,
    /// After the label, muted: a note the row carries (Zig's pickers
    /// that say more than Rust's).
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
    /// `ui.picker_position`: `.top` or `.center`.
    anchor: overlay.Anchor = .center,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.query.deinit(gpa);
        s.* = .{ .title = s.title };
    }

    pub fn queryText(s: *const State) []const u8 {
        return s.query.items;
    }
};

/// `ignored`: not a picker key and not a field key — a modified chord
/// the app may still resolve (Ctrl+S saves from the palette).
pub const Outcome = union(enum) { consumed, ignored, cancel, changed, accept: usize };

/// The `.scrollbar` owner the picker's bar registers under.
pub const scrollbar_owner: ids.PaneId = std.math.maxInt(ids.PaneId);

pub const min_width: u16 = 30;
pub const max_width: u16 = 90;
pub const min_height: u16 = 7;
pub const compact_height: u16 = 22;
pub const no_matches = "  (no matches)";
/// The label keeps at least this many cells; the detail gives way.
pub const min_label: u16 = 12;

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

/// The wheel: `delta` rows (negative up), clamped to the list.
pub fn wheel(s: *State, delta: isize, count: usize) void {
    const last = count -| 1;
    if (delta < 0) {
        s.cursor -|= @intCast(-delta);
    } else {
        s.cursor = @min(s.cursor + @as(usize, @intCast(delta)), last);
    }
}

fn editKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
    switch (try text_field.handleKey(&s.query, &s.caret, gpa, key)) {
        .changed => {
            s.cursor = 0;
            s.scroll = 0;
            return .changed;
        },
        .moved => return .consumed,
        .ignored => return .ignored,
    }
}

pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
    try text_field.insert(&s.query, &s.caret, gpa, text);
    s.cursor = 0;
    s.scroll = 0;
}

/// What the app knows about a row beyond its label — Rust's
/// `PickerItem.priority` (a hard tier that always beats the score) and
/// `score_bonus` (added to the score); `id` lets the palette pin an
/// exact id and boost a substring hit.
pub const RankOpts = struct {
    priority: []const u8 = &.{},
    score_bonus: []const i64 = &.{},
    /// The command ids, for the palette's boosts; empty otherwise.
    ids: []const []const u8 = &.{},
};

/// Indices into `items` that match `query`, best first: priority desc,
/// score desc, index asc — Rust's `refilter`. An empty query keeps
/// every item, ordered by priority and bonus alone.
pub fn rank(arena: Allocator, query: []const u8, items: []const Item, opts: RankOpts) Allocator.Error![]const usize {
    const Scored = struct { prio: u8, score: i64, idx: usize };
    var scored: std.ArrayListUnmanaged(Scored) = .empty;
    var qlower_buf: [256]u8 = undefined;
    const q = std.ascii.lowerString(qlower_buf[0..@min(query.len, qlower_buf.len)], query[0..@min(query.len, qlower_buf.len)]);
    const id_boosts = opts.ids.len > 0 and q.len > 0;
    for (items, 0..) |it, i| {
        const raw = fuzzy.raw(query, it.label) orelse continue;
        var prio: u8 = if (i < opts.priority.len) opts.priority[i] else 0;
        var sc: i64 = raw + (if (i < opts.score_bonus.len) opts.score_bonus[i] else 0);
        if (id_boosts and i < opts.ids.len) {
            var idbuf: [256]u8 = undefined;
            const id = opts.ids[i];
            const idl = std.ascii.lowerString(idbuf[0..@min(id.len, idbuf.len)], id[0..@min(id.len, idbuf.len)]);
            if (std.mem.eql(u8, idl, q)) {
                prio = @max(prio, 9);
            } else if (std.mem.indexOf(u8, idl, q) != null) {
                sc += 100;
            }
        }
        try scored.append(arena, .{ .prio = prio, .score = sc, .idx = i });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn less(_: void, a: Scored, b: Scored) bool {
            if (a.prio != b.prio) return a.prio > b.prio;
            if (a.score != b.score) return a.score > b.score;
            return a.idx < b.idx;
        }
    }.less);
    const out = try arena.alloc(usize, scored.items.len);
    for (scored.items, 0..) |e, i| out[i] = e.idx;
    return out;
}

/// `items` in `order` — what `draw` takes.
pub fn gather(arena: Allocator, items: []const Item, order: []const usize) Allocator.Error![]const Item {
    const out = try arena.alloc(Item, order.len);
    for (order, 0..) |idx, i| out[i] = items[idx];
    return out;
}

/// The box's rect on `area` for `n` items — Rust's geometry.
pub fn place(area: Rect, n: usize, anchor: overlay.Anchor) Rect {
    const w = @min(std.math.clamp(area.w -| 8, min_width, max_width), area.w);
    const compact = std.math.clamp(@as(u16, @intCast(@min(n, 1000))) + 3, min_height, compact_height);
    const generous = @max(@min(area.h -| 4, (area.h * 4) / 5), min_height);
    const h = @min(@min(compact, generous), area.h);
    return overlay.place(area, w, h, if (anchor == .top) .top else .center);
}

/// The box: query row, then the rows. Registers `.overlay_item(i)` per
/// visible row. Returns the query caret.
pub fn draw(ui: Ui, area: Rect, s: *State, items: []const Item) ?Caret {
    const t = ui.theme;
    if (area.isEmpty()) return null;
    const inner = overlay.frameLook(ui, place(area, items.len, s.anchor), s.title, .modal);
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
    const lw = rows_rect.w;
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const it = items[idx];
        const r = rows_rect.row(@intCast(i));
        const selected = idx == s.cursor;
        const row_bg = if (selected) t.chip.bg else bg;
        ui.fill(r, .{ .bg = row_bg });
        if (selected) _ = ui.putStr(r.x, r.y, 1, marker, Theme.onBg(t.accent, row_bg));
        // Rust's budget: the detail may take what is left past twelve
        // label cells, clipped with an ellipsis; it costs a cell of air
        // on each side, and a row without one still owes the edge one.
        const detail_budget = lw -| (list_panel.marker_w + min_label + 1);
        var detail: []const u8 = it.detail orelse "";
        const detail_orig_w = ui.width(detail);
        if (detail_orig_w > detail_budget) detail = if (detail_budget >= 2) ui.clipStr(detail, detail_budget) else "";
        const dw = ui.width(detail);
        const detail_cost: u16 = if (dw > 0) dw + 2 else 0;
        const right_pad: u16 = if (dw > 0) 0 else 1;
        const label_avail = lw -| (list_panel.marker_w + detail_cost + right_pad);
        const label = if (ui.width(it.label) > label_avail) ui.clipStr(it.label, label_avail) else it.label;
        var label_style = Theme.onBg(t.fg, row_bg);
        if (selected) label_style.bold = true;
        var hit_style = Theme.onBg(t.accent, row_bg);
        hit_style.bold = true;
        var x = r.x + list_panel.marker_w;
        x += drawLabel(ui, x, r.y, label_avail, label, s.query.items, label_style, hit_style);
        if (it.hint) |hh| {
            const room = (r.right() -| detail_cost) -| x;
            if (room > 2) x += ui.putStr(x, r.y, room, ui.clipStr(ui.fmt(" {s}", .{hh}), room), Theme.onBg(t.muted, row_bg));
        }
        if (dw > 0) _ = ui.putStrRight(r.right(), r.y, dw + 2, ui.fmt(" {s} ", .{detail}), Theme.onBg(t.muted, row_bg));
        ui.hit(r, .{ .overlay_item = @intCast(idx) });
    }
    return caret;
}

/// The label with the query's matched characters in `hit_style`;
/// returns the cells painted.
fn drawLabel(ui: Ui, x: u16, y: u16, max_w: u16, label: []const u8, query: []const u8, style: Style, hit_style: Style) u16 {
    if (query.len == 0) return ui.putStr(x, y, max_w, label, style);
    const m = (fuzzy.match(ui.arena, query, label) catch null) orelse return ui.putStr(x, y, max_w, label, style);
    var painted: u16 = 0;
    var pos: usize = 0;
    var hi: usize = 0;
    while (pos < label.len and painted < max_w) {
        // The run from `pos`: matched cells while `positions` say so,
        // else up to the next matched byte.
        const hit = hi < m.positions.len and m.positions[hi] == pos;
        var end = pos;
        if (hit) {
            while (hi < m.positions.len and m.positions[hi] == end) : (hi += 1) {
                end += std.unicode.utf8ByteSequenceLength(label[end]) catch 1;
                if (end >= label.len) break;
            }
        } else {
            end = if (hi < m.positions.len) @min(m.positions[hi], label.len) else label.len;
        }
        if (end <= pos) end = pos + 1;
        painted += ui.putStr(x + painted, y, max_w - painted, label[pos..end], if (hit) hit_style else style);
        pos = end;
    }
    return painted;
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
    // The selected row: marker + bold label + a chip ground; a square frame.
    try testing.expectEqualStrings("\u{258c}", f.cell(5, 8).char.grapheme);
    try testing.expect(f.style(6, 8).bold);
    try testing.expect(f.bgEql(6, 8, f.theme.chip));
    try testing.expect(!f.style(6, 9).bold);
    try testing.expect(std.mem.startsWith(u8, f.row(6, &buf), "    ┌ Buffers "));
    // The detail sits against the right edge with one cell of air.
    try testing.expect(std.mem.endsWith(u8, f.row(8, &buf), "src/a.txt │"));
}

const names = [_]Item{ .{ .label = "alpha" }, .{ .label = "beta" }, .{ .label = "gamma" } };

test "typing filters via rank + gather, the count says N of M, the cursor rewinds, the hits paint in the accent" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    var s: State = .{ .title = "Files", .total = names.len };
    defer s.deinit(testing.allocator);
    const gpa = testing.allocator;
    _ = try handleKey(&s, gpa, Key.named(.down), names.len);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.char('g'), names.len));
    try testing.expectEqual(@as(usize, 0), s.cursor);
    const order = try rank(f.arena_state.allocator(), s.queryText(), &names, .{});
    try testing.expectEqualSlices(usize, &.{2}, order);
    const shown = try gather(f.arena_state.allocator(), &names, order);
    _ = draw(f.ui(), f.full(), &s, shown);
    try f.expectContains("gamma");
    try f.expectLacks("alpha");
    try f.expectContains(" 1 of 3 ");
    // 52 wide at x 4; the row at y (12-7)/2 + 2 = 4; the `g` at cell 6 is the hit.
    try testing.expect(f.fgEql(6, 4, f.theme.accent));
    try testing.expect(f.style(6, 4).bold);
    try testing.expect(!f.fgEql(7, 4, f.theme.accent));
    try testing.expectEqual(@as(usize, 0), (try handleKey(&s, gpa, Key.named(.enter), shown.len)).accept);
    // No matches: the row says so and enter does nothing.
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.char('z'), shown.len));
    const none = try rank(f.arena_state.allocator(), s.queryText(), &names, .{});
    try testing.expectEqual(@as(usize, 0), none.len);
    _ = draw(f.ui(), f.full(), &s, &.{});
    try f.expectContains("(no matches)");
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.named(.enter), 0));
    try testing.expectEqual(Outcome.cancel, try handleKey(&s, gpa, Key.named(.esc), 0));
    // An empty query keeps the app's order.
    const all = try rank(f.arena_state.allocator(), "", &files, .{});
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, all);
}

test "rank is Rust's refilter: priority beats score, bonuses tier the empty query, the palette pins an exact id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // priority_beats_score_in_refilter
    const items = [_]Item{ .{ .label = "lib.rs" }, .{ .label = "src/lib.rs" } };
    const by_prio = try rank(arena, "lib", &items, .{ .priority = &.{ 1, 2 } });
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, by_prio);
    // score_bonus_tiers_recents_beat_pane_scoped_beat_generic
    const cmds = [_]Item{ .{ .label = "Quit mnml" }, .{ .label = "Editor stats" }, .{ .label = "Insert last cmdline" } };
    const tiers = try rank(arena, "", &cmds, .{ .score_bonus = &.{ 0, 20, 50 } });
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, tiers);
    // The exact id is tier 9; an id containing the query gains 100.
    const pal = [_]Item{ .{ .label = "file  ·  Save file as…  ·  file.save_as" }, .{ .label = "file  ·  Save file  ·  file.save" } };
    const pinned = try rank(arena, "file.save", &pal, .{ .ids = &.{ "file.save_as", "file.save" } });
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, pinned);
}

test "the geometry at 80, 120 and 200 columns is Rust's; top anchors to the edge" {
    // w = clamp(W-8, 30, 90); h = clamp(n+3, 7, 22) capped at 4/5 of H; centred.
    try testing.expect(place(Rect.init(0, 0, 80, 24), 3, .center).eql(Rect.init(4, 8, 72, 7)));
    try testing.expect(place(Rect.init(0, 0, 120, 40), 321, .center).eql(Rect.init(15, 9, 90, 22)));
    try testing.expect(place(Rect.init(0, 0, 200, 60), 4, .center).eql(Rect.init(55, 26, 90, 7)));
    try testing.expect(place(Rect.init(0, 0, 120, 40), 321, .top).eql(Rect.init(15, 0, 90, 22)));
    try testing.expect(place(Rect.init(0, 0, 20, 5), 40, .center).eql(Rect.init(0, 0, 20, 5)));
}

test "a long list scrolls with the cursor, pages, wheels, and shows a bar" {
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
    wheel(&s, 3, many.len);
    try testing.expectEqual(@as(usize, 14), s.cursor);
    wheel(&s, -100, many.len);
    try testing.expectEqual(@as(usize, 0), s.cursor);
    wheel(&s, 100, many.len);
    try testing.expectEqual(@as(usize, 39), s.cursor);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    try testing.expectEqual(@as(usize, 0), s.cursor);
    try paste(&s, testing.allocator, "item 3");
    try testing.expectEqualStrings("item 3", s.queryText());
}

test "the palette row is Rust's: marker, label, gap, the chord with air on both sides, the bar" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    const arena = f.arena_state.allocator();
    const many = try arena.alloc(Item, 30);
    for (many, 0..) |*it, i| it.* = .{ .label = try std.fmt.allocPrint(arena, "git  ·  Git: row {d}  ·  git.row_{d}", .{ i, i }), .detail = if (i == 1) "ctrl+k b" else "" };
    var s: State = .{ .title = "Command palette", .total = 796 };
    defer s.deinit(testing.allocator);
    try s.query.appendSlice(testing.allocator, "git");
    s.caret = 3;
    _ = draw(f.ui(), f.full(), &s, many);
    try f.expectRow(9, " " ** 15 ++ "┌ Command palette " ++ "─" ** 71 ++ "┐");
    try f.expectRow(10, " " ** 15 ++ "│  git" ++ " " ** 72 ++ " 30 of 796 │");
    try f.expectRow(11, " " ** 15 ++ "│▌git  ·  Git: row 0  ·  git.row_0" ++ " " ** 54 ++ "█│");
    try f.expectRow(12, " " ** 15 ++ "│ git  ·  Git: row 1  ·  git.row_1" ++ " " ** 45 ++ "ctrl+k b █│");
    try f.expectRow(30, " " ** 15 ++ "└" ++ "─" ** 88 ++ "┘");
    // The three `git` cells of every row are the hit; the rest is not.
    try testing.expect(f.fgEql(17, 11, f.theme.accent));
    try testing.expect(f.fgEql(19, 11, f.theme.accent));
    try testing.expect(!f.fgEql(20, 11, f.theme.accent));
    try testing.expectEqual(@as(u32, 1), f.hits.at(40, 12).?.overlay_item);
    try testing.expect(f.hits.at(103, 12).? == .scrollbar);
}

test "the box never exceeds a tiny screen" {
    var s: State = .{ .title = "Tiny" };
    defer s.deinit(testing.allocator);
    inline for (.{ .{ 29, 5 }, .{ 12, 3 }, .{ 2, 2 }, .{ 40, 1 }, .{ 1, 1 } }) |wh| {
        var f = try Fixture.init(wh[0], wh[1]);
        defer f.deinit();
        _ = draw(f.ui(), f.full(), &s, &files);
        for (f.hits.items.items) |e| try testing.expect(f.full().intersect(e.rect).eql(e.rect));
    }
}
