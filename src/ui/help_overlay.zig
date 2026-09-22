//! Help — the keymap reference the Rust editor opens on F1: a modal
//! box seven tenths of the screen wide (70..140) and eight tenths tall
//! (20..60), centred, titled ` Help `. The first inner row is the
//! filter (` / filter…` at rest, ` /query` while it has the keys), the
//! last the hint; between them the rows scroll: a section header
//! `▾ ── name ── (n)` (`▸` folded) and under it one binding per row,
//! `  chord` in the accent padded to the widest chord (8..20 cells)
//! then two cells and the title. A section with nothing matching the
//! filter is left out; a folded section shows its header alone. A list
//! longer than the body gets a scrollbar column.
//!
//! The rows come from the app (`app/help.zig`): the mode chips, the
//! stress meter, then every command group of the registry with the
//! chords the active keymap binds. Keys: j/k ↑/↓ scroll one, PageUp /
//! PageDown ten, Home / End the ends; `/` takes the filter (Esc / Enter
//! give it back, Backspace edits); `c` / `e` fold / open every section;
//! Esc / F1 close. A header row registers `.overlay_item(i)` with its
//! index into the rows, so a click folds it.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const scrollbar = @import("scrollbar.zig");
const key_mod = @import("../core/key.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const Key = key_mod.Key;

pub const Row = union(enum) {
    section: []const u8,
    binding: struct { keys: []const u8, title: []const u8 },
};

pub const State = struct {
    scroll: usize = 0,
    /// The folded sections, by name (the names are static).
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    query: std.ArrayListUnmanaged(u8) = .empty,
    filter_focused: bool = false,
    /// Rows the body had last frame; the scroll is clamped to the list
    /// on paint.
    body_rows: usize = 0,
    /// Lines the list had last frame, for the clamp.
    line_count: usize = 0,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.collapsed.deinit(gpa);
        s.query.deinit(gpa);
        s.* = .{};
    }

    pub fn isCollapsed(s: *const State, name: []const u8) bool {
        return s.collapsed.contains(name);
    }

    pub fn toggle(s: *State, gpa: Allocator, name: []const u8) Allocator.Error!void {
        if (s.collapsed.fetchRemove(name) == null) try s.collapsed.put(gpa, name, {});
        s.scroll = 0;
    }

    pub fn scrollBy(s: *State, delta: isize) void {
        const max = s.line_count -| s.body_rows;
        if (delta < 0) {
            s.scroll -|= @intCast(-delta);
        } else {
            s.scroll = @min(s.scroll + @as(usize, @intCast(delta)), max);
        }
    }
};

pub const Outcome = enum { consumed, close };

/// The `.scrollbar` owner the help's bar registers under.
pub const scrollbar_owner: ids.PaneId = std.math.maxInt(ids.PaneId) - 1;

pub const hint_rest = "/ filter · j/k scroll · PageUp/Down faster · c/e collapse/expand · Esc close";
pub const hint_typing = "typing… · Enter/Esc leave input · Backspace edit";

/// Rust's `handle_help_overlay_key`. `sections` lets `c` / `e` fold
/// or open every section.
pub fn handleKey(s: *State, gpa: Allocator, key: Key, sections: []const []const u8) Allocator.Error!Outcome {
    if (s.filter_focused) {
        switch (key.code) {
            .esc, .enter => s.filter_focused = false,
            .backspace => {
                _ = s.query.pop();
                s.scroll = 0;
            },
            .char => |c| if (!key.mods.ctrl and !key.mods.alt and c >= 0x20) {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return .consumed;
                try s.query.appendSlice(gpa, buf[0..n]);
                s.scroll = 0;
            },
            else => {},
        }
        return .consumed;
    }
    switch (key.code) {
        .esc => return .close,
        .f => |n| if (n == 1) return .close,
        .up => s.scrollBy(-1),
        .down => s.scrollBy(1),
        .page_up => s.scrollBy(-10),
        .page_down => s.scrollBy(10),
        .home => s.scrollBy(-1_000_000),
        .end => s.scrollBy(1_000_000),
        .char => |c| switch (c) {
            'k' => s.scrollBy(-1),
            'j' => s.scrollBy(1),
            '/' => s.filter_focused = true,
            'c' => {
                for (sections) |name| if (!s.collapsed.contains(name)) try s.collapsed.put(gpa, name, {});
                s.scroll = 0;
            },
            'e' => {
                s.collapsed.clearRetainingCapacity();
                s.scroll = 0;
            },
            else => {},
        },
        else => {},
    }
    return .consumed;
}

/// Rust's `overlay_rect`.
pub fn place(screen: Rect) Rect {
    const w: u16 = @min(std.math.clamp((screen.w * 7) / 10, 70, 140), screen.w -| 4);
    const h: u16 = @min(std.math.clamp((screen.h * 8) / 10, 20, 60), screen.h -| 4);
    return overlay.place(screen, w, h, .center);
}

/// A line the body shows: a header (with its row index, for the click)
/// or a binding.
const Line = struct { row: ?usize, text_a: []const u8, text_b: []const u8, header: bool };

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

/// Paints the box; registers a header row's `.overlay_item` with its
/// index into `rows`, and the scrollbar.
pub fn draw(ui: Ui, screen: Rect, s: *State, rows: []const Row) void {
    const t = ui.theme;
    if (screen.w < 6 or screen.h < 6) return;
    const inner = overlay.frameLook(ui, place(screen), "Help", .modal);
    if (inner.isEmpty() or inner.h < 3) return;
    const bg = t.overlay_bg.bg;
    const query = s.query.items;

    // The chord column: the widest bound chord, 8..20.
    var key_col_w: usize = 8;
    for (rows) |r| if (r == .binding) {
        key_col_w = @max(key_col_w, ui.width(r.binding.keys));
    };
    key_col_w = @min(key_col_w, 20);

    // Rust counts a section by NAME across the whole list (a group
    // that recurs shows its total on each of its headers), under the
    // filter the rows that match.
    var per_name: std.StringHashMapUnmanaged(usize) = .empty;
    defer per_name.deinit(ui.arena);
    {
        var cur: ?[]const u8 = null;
        for (rows) |r| switch (r) {
            .section => |name| {
                cur = name;
                _ = per_name.getOrPutValue(ui.arena, name, 0) catch return;
            },
            .binding => |b| if (cur) |name| {
                if (query.len == 0 or containsIgnoreCase(ui.fmt("{s} {s}", .{ b.keys, b.title }), query)) {
                    (per_name.getPtr(name) orelse continue).* += 1;
                }
            },
        };
    }

    // Pass one: what each section keeps under the filter.
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var i: usize = 0;
    while (i < rows.len) : (i += 1) {
        const r = rows[i];
        if (r != .section) continue;
        const name = r.section;
        // The section's bindings run to the next header.
        var end = i + 1;
        while (end < rows.len and rows[end] != .section) : (end += 1) {}
        var kept: usize = 0;
        for (rows[i + 1 .. end]) |b| {
            if (query.len == 0 or containsIgnoreCase(ui.fmt("{s} {s}", .{ b.binding.keys, b.binding.title }), query)) kept += 1;
        }
        if (query.len > 0 and kept == 0) {
            i = end - 1;
            continue;
        }
        const folded = query.len == 0 and s.isCollapsed(name);
        const count = per_name.get(name) orelse kept;
        lines.append(ui.arena, .{ .row = i, .text_a = ui.fmt("{s} ── {s} ── ({d})", .{ if (folded) "▸" else "▾", name, count }), .text_b = "", .header = true }) catch return;
        if (!folded) for (rows[i + 1 .. end]) |b| {
            if (query.len > 0 and !containsIgnoreCase(ui.fmt("{s} {s}", .{ b.binding.keys, b.binding.title }), query)) continue;
            const kc = if (b.binding.keys.len == 0) "·" else b.binding.keys;
            const pad = key_col_w -| ui.width(kc);
            lines.append(ui.arena, .{ .row = null, .text_a = ui.fmt("  {s}", .{kc}), .text_b = ui.fmt("{s}{s}", .{ spaces(ui, pad + 2), b.binding.title }), .header = false }) catch return;
        };
        i = end - 1;
    }
    if (query.len > 0 and lines.items.len == 0) {
        lines.append(ui.arena, .{ .row = null, .text_a = ui.fmt("  no bindings match \"{s}\"", .{query}), .text_b = "", .header = true }) catch return;
    }

    // The filter row.
    const filter_row = inner.row(0);
    const filter_text = if (s.filter_focused) ui.fmt(" /{s}", .{query}) else if (query.len == 0) " / filter…" else ui.fmt(" filter: {s}   (/ to edit)", .{query});
    var filter_style = if (s.filter_focused) Theme.onBg(t.warn_fg, bg) else Theme.onBg(t.muted, bg);
    filter_style.bold = s.filter_focused;
    filter_style.dim = !s.filter_focused;
    _ = ui.putStr(filter_row.x, filter_row.y, filter_row.w, ui.clipStr(filter_text, filter_row.w), filter_style);

    // The body between the filter and the hint.
    const body_h: usize = inner.h - 2;
    s.body_rows = body_h;
    s.line_count = lines.items.len;
    const max_scroll = lines.items.len -| body_h;
    if (s.scroll > max_scroll) s.scroll = max_scroll;
    const needs_bar = lines.items.len > body_h;
    // The bar's column, and a cell of air before it.
    const body_w = if (needs_bar) inner.w -| 2 else inner.w;
    var header_style = Theme.onBg(t.muted, bg);
    header_style.bold = true;
    header_style.dim = true;
    const key_style = Theme.onBg(t.accent, bg);
    const title_style = Theme.onBg(t.fg, bg);
    var y: usize = 0;
    while (y < body_h and s.scroll + y < lines.items.len) : (y += 1) {
        const ln = lines.items[s.scroll + y];
        const r = Rect.init(inner.x, inner.y + 1 + @as(u16, @intCast(y)), body_w, 1);
        if (ln.header) {
            _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(ln.text_a, r.w), header_style);
            if (ln.row) |row| ui.hit(Rect.init(inner.x, r.y, inner.w, 1), .{ .overlay_item = @intCast(row) });
        } else {
            // Rust cuts a long title at the edge, no ellipsis.
            const used = ui.putStr(r.x, r.y, r.w, ln.text_a, key_style);
            _ = ui.putStr(r.x + used, r.y, r.w -| used, ln.text_b, title_style);
        }
    }
    if (needs_bar) {
        const sb = Rect.init(inner.x + inner.w - 1, inner.y + 1, 1, @intCast(body_h));
        scrollbar.drawVertical(ui, sb, .{ .pane = scrollbar_owner }, lines.items.len, body_h, s.scroll);
    }

    // The hint.
    const hint_row = inner.row(inner.h - 1);
    var hint_style = Theme.onBg(t.muted, bg);
    hint_style.dim = true;
    _ = ui.putStr(hint_row.x, hint_row.y, hint_row.w, ui.clipStr(overlay.hintText(ui, if (s.filter_focused) hint_typing else hint_rest), hint_row.w), hint_style);
}

fn spaces(ui: Ui, n: usize) []const u8 {
    const s = ui.arena.alloc(u8, n) catch return "";
    @memset(s, ' ');
    return s;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const sample = [_]Row{
    .{ .section = "modes" },
    .{ .binding = .{ .keys = "NORMAL", .title = "vim normal mode (red)" } },
    .{ .binding = .{ .keys = "INSERT", .title = "vim/standard editable (green)" } },
    .{ .section = "app" },
    .{ .binding = .{ .keys = "ctrl+q", .title = "Quit mnml" } },
    .{ .binding = .{ .keys = "", .title = "Restart mnml (rebuild + relaunch via run.sh)" } },
};

test "the box is Rust's: 84×32 at 120×40, the filter row, headers with counts, chords padded to the column, the hint" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    draw(f.ui(), f.full(), &s, &sample);
    try testing.expect(place(f.full()).eql(Rect.init(18, 4, 84, 32)));
    try f.expectRow(4, " " ** 18 ++ "┌ Help " ++ "─" ** 76 ++ "┐");
    try f.expectRow(5, " " ** 18 ++ "│ / filter…" ++ " " ** 72 ++ "│");
    try f.expectRow(6, " " ** 18 ++ "│▾ ── modes ── (2)" ++ " " ** 65 ++ "│");
    try f.expectRow(7, " " ** 18 ++ "│  NORMAL    vim normal mode (red)" ++ " " ** 49 ++ "│");
    try f.expectRow(10, " " ** 18 ++ "│  ctrl+q    Quit mnml" ++ " " ** 61 ++ "│");
    try f.expectRow(11, " " ** 18 ++ "│  ·         Restart mnml (rebuild + relaunch via run.sh)" ++ " " ** 26 ++ "│");
    try f.expectRow(34, " " ** 18 ++ "│" ++ hint_rest ++ " " ** 6 ++ "│");
    try f.expectRow(35, " " ** 18 ++ "└" ++ "─" ** 82 ++ "┘");
    // The headers are the hits, by their row index; a chord is the accent.
    try testing.expectEqual(@as(u32, 0), f.hits.at(30, 6).?.overlay_item);
    try testing.expectEqual(@as(u32, 3), f.hits.at(30, 9).?.overlay_item);
    try testing.expect(f.hits.at(30, 7) == null);
    try testing.expect(f.fgEql(21, 10, f.theme.accent));
    try testing.expect(f.bgEql(21, 4, f.theme.chip_active));
}

test "folding, the filter, and the keys" {
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    const gpa = testing.allocator;
    var s: State = .{};
    defer s.deinit(gpa);
    const sections = [_][]const u8{ "modes", "app" };
    // c folds every section: headers alone, with ▸.
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.char('c'), &sections));
    draw(f.ui(), f.full(), &s, &sample);
    try f.expectContains("▸ ── modes ── (2)");
    try f.expectLacks("NORMAL");
    // e opens them; a click on the header folds one.
    _ = try handleKey(&s, gpa, Key.char('e'), &sections);
    try s.toggle(gpa, "app");
    draw(f.ui(), f.full(), &s, &sample);
    try f.expectContains("NORMAL");
    try f.expectContains("▸ ── app ── (2)");
    try f.expectLacks("Quit mnml");
    // / takes the filter: a query keeps the matching rows, ignores the fold,
    // drops a section with nothing; the hint says so.
    _ = try handleKey(&s, gpa, Key.char('/'), &sections);
    try testing.expect(s.filter_focused);
    for ("quit") |c| _ = try handleKey(&s, gpa, Key.char(c), &sections);
    draw(f.ui(), f.full(), &s, &sample);
    try f.expectContains(" /quit");
    try f.expectContains("▾ ── app ── (1)");
    try f.expectContains("Quit mnml");
    try f.expectLacks("modes");
    try f.expectContains(hint_typing);
    _ = try handleKey(&s, gpa, Key.named(.backspace), &sections);
    _ = try handleKey(&s, gpa, Key.named(.enter), &sections);
    try testing.expect(!s.filter_focused);
    draw(f.ui(), f.full(), &s, &sample);
    try f.expectContains(" filter: qui   (/ to edit)");
    for ("xyz") |c| {
        _ = try handleKey(&s, gpa, Key.char('/'), &sections);
        _ = try handleKey(&s, gpa, Key.char(c), &sections);
        _ = try handleKey(&s, gpa, Key.named(.esc), &sections);
    }
    draw(f.ui(), f.full(), &s, &sample);
    try f.expectContains("no bindings match \"quixyz\"");
    // Esc and F1 close when the filter is not focused.
    try testing.expectEqual(Outcome.close, try handleKey(&s, gpa, Key.named(.esc), &sections));
    try testing.expectEqual(Outcome.close, try handleKey(&s, gpa, Key.named(.{ .f = 1 }), &sections));
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.named(.{ .f = 2 }), &sections));
}

test "a long list scrolls by key and shows a bar; tiny screens do not panic" {
    var f = try Fixture.init(90, 24);
    defer f.deinit();
    const arena = f.arena_state.allocator();
    const many = try arena.alloc(Row, 60);
    many[0] = .{ .section = "big" };
    for (many[1..], 1..) |*r, i| r.* = .{ .binding = .{ .keys = try std.fmt.allocPrint(arena, "f{d}", .{i}), .title = try std.fmt.allocPrint(arena, "row {d}", .{i}) } };
    var s: State = .{};
    defer s.deinit(testing.allocator);
    draw(f.ui(), f.full(), &s, many);
    // h = 20 at 24 rows → 18 inner → 16 body rows.
    try testing.expectEqual(@as(usize, 16), s.body_rows);
    try f.expectContains("row 15");
    try f.expectLacks("row 16");
    try testing.expect(f.hits.at(f.hits.items.items[f.hits.items.items.len - 1].rect.x, 5).? == .scrollbar);
    _ = try handleKey(&s, testing.allocator, Key.named(.page_down), &.{});
    _ = try handleKey(&s, testing.allocator, Key.char('j'), &.{});
    draw(f.ui(), f.full(), &s, many);
    try testing.expectEqual(@as(usize, 11), s.scroll);
    try f.expectContains("row 26");
    try f.expectLacks("row 10");
    _ = try handleKey(&s, testing.allocator, Key.named(.end), &.{});
    draw(f.ui(), f.full(), &s, many);
    try f.expectContains("row 59");
    _ = try handleKey(&s, testing.allocator, Key.named(.home), &.{});
    try testing.expectEqual(@as(usize, 0), s.scroll);
    inline for (.{ .{ 5, 5 }, .{ 30, 8 }, .{ 2, 2 } }) |wh| {
        var g = try Fixture.init(wh[0], wh[1]);
        defer g.deinit();
        draw(g.ui(), g.full(), &s, many);
        for (g.hits.items.items) |e| try testing.expect(g.full().intersect(e.rect).eql(e.rect));
    }
}

test "a cell of air before the bar: a long title is cut a cell short of it on every body row" {
    var f = try Fixture.init(60, 16);
    defer f.deinit();
    const arena = f.arena_state.allocator();
    const many = try arena.alloc(Row, 40);
    many[0] = .{ .section = "big" };
    for (many[1..], 1..) |*r, i| r.* = .{ .binding = .{ .keys = try std.fmt.allocPrint(arena, "f{d}", .{i}), .title = "a" ** 100 } };
    var s: State = .{};
    defer s.deinit(testing.allocator);
    draw(f.ui(), f.full(), &s, many);
    const bar = for (f.hits.items.items) |e| {
        if (e.target == .scrollbar) break e.rect;
    } else return error.TestNoBar;
    try f.expectAirBeforeBar(bar.y, bar.y + bar.h, bar.x);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, f.row(bar.y + 1, &buf), "aaa █│"));
}
