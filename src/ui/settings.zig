//! Settings overlay — the family idiom for a settings screen: a centered,
//! scrollable list in sections (`── UI ──`, `── Editor ──`, …), one row
//! per setting as `▸ Label:  [active] / other / other  *`, where `▸`
//! marks focus, `[brackets]` the current choice and a trailing `*` a
//! value that differs from the shipped default. Labels pad so the
//! colons line up within the box.
//!
//! The component owns the cursor and the scroll; what a key *means* is
//! handed back as an `Outcome` (adjust this row by ±1, reset it, reset
//! everything, save, cancel) so the app decides what a change does and
//! where it is written. Every row registers `.overlay_item(id)`, and
//! every option chip its own id, so a click can focus a row or jump
//! straight to a value.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const key_mod = @import("../core/key.zig");

const Style = vaxis.Style;

pub const Key = key_mod.Key;

/// One line of the list.
pub const Item = union(enum) {
    /// `── name ──`
    section: []const u8,
    row: Row,
    /// The `Reset all to defaults` action row.
    action: Action,

    pub fn focusable(it: Item) bool {
        return it != .section;
    }
};

pub const Row = struct {
    label: []const u8,
    /// Every choice, in order; `current` indexes it. Empty for a
    /// number row, where `current` is the value itself.
    options: []const []const u8,
    current: usize,
    /// Differs from the shipped default — paints the trailing `*`.
    modified: bool = false,
    /// What `.overlay_item` carries for the row itself; option chips
    /// register `optionHit(id, i)`.
    id: u32,
    /// // changed: a number row — `‹ [value] ›` stepped by ←→; the two
    /// arrows register `optionHit(id, 0)` (down) and `optionHit(id, 1)`
    /// (up). The family convention calls number rows v2; this is the
    /// minimal step form.
    number: ?Number = null,

    pub const Number = struct { min: usize, max: usize, step: usize };
};

pub const Action = struct {
    label: []const u8,
    id: u32,
};

/// Hit ids: a row is `id`; its option `i` is `option_base + id * option_stride + i`;
/// the box itself is `surface_id`, so a click on its frame is not a
/// click outside.
pub const option_base: u32 = 1 << 20;
pub const option_stride: u32 = 256;
pub const surface_id: u32 = option_base - 1;

pub fn optionHit(id: u32, i: usize) u32 {
    return option_base + id * option_stride + @as(u32, @intCast(i));
}

pub const Hit = union(enum) { surface, row: u32, option: struct { id: u32, index: usize } };

pub fn decodeHit(h: u32) Hit {
    if (h == surface_id) return .surface;
    if (h < option_base) return .{ .row = h };
    const rel = h - option_base;
    return .{ .option = .{ .id = rel / option_stride, .index = rel % option_stride } };
}

pub const State = struct {
    /// Index into the items slice; always on a focusable item once
    /// `settle` has run.
    cursor: usize = 0,
    scroll: usize = 0,
    /// Rows the list showed last frame — paging reads it.
    rows: usize = 0,

    /// Move the cursor onto a focusable item (the first at or after it).
    pub fn settle(s: *State, items: []const Item) void {
        if (items.len == 0) return;
        if (s.cursor >= items.len) s.cursor = items.len - 1;
        var i = s.cursor;
        while (i < items.len) : (i += 1) if (items[i].focusable()) {
            s.cursor = i;
            return;
        };
        i = s.cursor;
        while (true) : (i -= 1) {
            if (items[i].focusable()) {
                s.cursor = i;
                return;
            }
            if (i == 0) return;
        }
    }

    fn move(s: *State, items: []const Item, delta: isize) void {
        var i: isize = @intCast(s.cursor);
        while (true) {
            i += delta;
            if (i < 0 or i >= @as(isize, @intCast(items.len))) return;
            if (items[@intCast(i)].focusable()) {
                s.cursor = @intCast(i);
                return;
            }
        }
    }

    fn moveBy(s: *State, items: []const Item, delta: isize) void {
        var n: usize = @abs(delta);
        while (n > 0) : (n -= 1) s.move(items, if (delta < 0) -1 else 1);
    }

    /// The wheel: the window slides `delta` lines and the cursor is
    /// pulled along so it stays inside — `draw` scrolls to the cursor,
    /// so a cursor left behind would drag the window straight back.
    /// A no-op before the first draw (`rows` is unknown).
    pub fn wheel(s: *State, items: []const Item, delta: isize) void {
        if (s.rows == 0 or items.len == 0) return;
        const max_scroll: isize = @intCast(items.len -| s.rows);
        s.scroll = @intCast(std.math.clamp(@as(isize, @intCast(s.scroll)) + delta, 0, max_scroll));
        if (s.cursor < s.scroll) {
            s.cursor = s.scroll;
            s.settle(items);
        } else if (s.cursor >= s.scroll + s.rows) {
            s.cursor = s.scroll + s.rows - 1;
            s.settleBack(items);
        }
    }

    /// `settle`, but looking up first: the last focusable at or before
    /// the cursor, else the first after it.
    fn settleBack(s: *State, items: []const Item) void {
        if (items.len == 0) return;
        if (s.cursor >= items.len) s.cursor = items.len - 1;
        var i = s.cursor + 1;
        while (i > 0) {
            i -= 1;
            if (items[i].focusable()) {
                s.cursor = i;
                return;
            }
        }
        s.settle(items);
    }
};

pub const Outcome = union(enum) {
    consumed,
    cancel,
    save,
    /// The focused row moves `delta` choices (wrapping).
    adjust: struct { item: usize, delta: i8 },
    reset_row: usize,
    reset_all,
    /// Enter / space on an action row.
    activate: usize,
};

/// ←→ / h l adjust · ↑↓ / j k move · r reset the row · R reset all ·
/// Enter save · Esc cancel · Home/End/PgUp/PgDn move further.
pub fn handleKey(s: *State, key: Key, items: []const Item) Outcome {
    s.settle(items);
    const page: isize = @intCast(@max(1, s.rows));
    switch (key.code) {
        .esc => return .cancel,
        .enter => return if (s.cursor < items.len and items[s.cursor] == .action) .{ .activate = s.cursor } else .save,
        .up => s.move(items, -1),
        .down => s.move(items, 1),
        .left => return adjustFocused(s, items, -1),
        .right => return adjustFocused(s, items, 1),
        .home => {
            s.cursor = 0;
            s.settle(items);
        },
        .end => {
            s.cursor = items.len -| 1;
            s.settle(items);
        },
        .page_up => s.moveBy(items, -page),
        .page_down => s.moveBy(items, page),
        .char => |c| {
            if (key.mods.ctrl or key.mods.alt) return .consumed;
            switch (c) {
                'k' => s.move(items, -1),
                'j' => s.move(items, 1),
                'h' => return adjustFocused(s, items, -1),
                'l' => return adjustFocused(s, items, 1),
                ' ' => return if (s.cursor < items.len and items[s.cursor] == .action) .{ .activate = s.cursor } else adjustFocused(s, items, 1),
                'r' => return if (s.cursor < items.len and items[s.cursor] == .row) .{ .reset_row = s.cursor } else .consumed,
                'R' => return .reset_all,
                'q' => return .save,
                else => {},
            }
        },
        else => {},
    }
    return .consumed;
}

fn adjustFocused(s: *State, items: []const Item, delta: i8) Outcome {
    if (s.cursor >= items.len) return .consumed;
    return switch (items[s.cursor]) {
        .row => .{ .adjust = .{ .item = s.cursor, .delta = delta } },
        .action => .{ .activate = s.cursor },
        .section => .consumed,
    };
}

pub const title = "Settings";
pub const hint_text = "←→ adjust · ↑↓ move · r/R reset · Enter save · Esc cancel";
pub const max_width: u16 = 84;
pub const min_width: u16 = 40;
/// A row with more choices than this paints `[current] ‹ i/n ›` instead
/// of the whole list (the theme row has 94).
pub const max_listed_options: usize = 6;

/// Paint the box. `subtitle` (the focused row's target file, say) joins
/// the title: `Settings · → .mnml/config.zon`. Rows scroll to keep the
/// cursor visible; the list is as tall as the screen allows.
pub fn draw(ui: Ui, area: Rect, s: *State, items: []const Item, subtitle: ?[]const u8) void {
    const t = ui.theme;
    s.settle(items);
    // Label column: the widest label, so every colon lines up.
    var label_w: u16 = 0;
    var widest: u16 = 0;
    for (items) |it| switch (it) {
        .row => |r| {
            label_w = @max(label_w, ui.width(r.label));
            // A choice list wider than the box windows around the active
            // value (`choiceWindow`), so a row asks only for what that
            // form needs: the bracketed active value and its two arrows.
            // The box stays the family's 60 %; it does not grow to fit
            // the longest list.
            var ow: u16 = 0;
            if (r.number != null) {
                ow = 12;
            } else if (r.options.len > max_listed_options) {
                ow = ui.width(r.options[r.current]) + 12;
            } else {
                ow = ui.width(r.options[r.current]) + 8;
            }
            widest = @max(widest, ui.width(r.label) + ow);
        },
        .action => |a| widest = @max(widest, ui.width(a.label)),
        .section => |name| widest = @max(widest, ui.width(name) + 6),
    };
    const hint = if (ui.ascii) hint_text_ascii else hint_text;
    // ~60 % of the screen wide and ~70 % tall (the family idiom): wider
    // when the rows need it, up to `max_width`; shorter when the rows
    // fit — a long list scrolls inside the box instead of filling the
    // screen.
    const want_w: u16 = @min(max_width, @max(@max(min_width, ui.width(hint) + 4), @max(widest + 12, area.w * 6 / 10)));
    const w = @min(want_w, area.w -| 2);
    const cap_h: u16 = @max(area.h * 7 / 10, @min(area.h, 8));
    const want_h: u16 = @intCast(@min(@as(usize, cap_h), items.len + 4));
    const full_title = if (subtitle) |sub| ui.fmt("{s} · {s}", .{ title, sub }) else title;
    const box_rect = overlay.place(area, w, want_h, .center);
    const inner = overlay.frame(ui, box_rect, full_title);
    if (inner.isEmpty() or inner.h < 2) return;
    // First, so every row and chip registered after it wins the scan.
    ui.hit(box_rect, .{ .overlay_item = surface_id });

    const list_h: usize = inner.h - 1;
    s.rows = list_h;
    if (s.cursor < s.scroll) s.scroll = s.cursor;
    if (s.cursor >= s.scroll + list_h) s.scroll = s.cursor + 1 - list_h;

    const bg = t.overlay_bg.bg;
    var y: u16 = inner.y;
    var idx = s.scroll;
    while (idx < items.len and y < inner.y + @as(u16, @intCast(list_h))) : ({
        idx += 1;
        y += 1;
    }) {
        const r = Rect.init(inner.x, y, inner.w, 1);
        const focused = idx == s.cursor;
        const row_style: Style = if (focused) Theme.onBg(t.overlay_bg, t.cursor_line.bg) else t.overlay_bg;
        ui.fill(r, row_style);
        switch (items[idx]) {
            .section => |name| {
                const rule = if (ui.ascii) "--" else "──";
                const text = ui.fmt("{s} {s} {s}", .{ rule, name, rule });
                _ = ui.putStr(r.x + 1, y, r.w -| 1, ui.clipStr(text, r.w -| 1), Theme.onBg(t.muted, bg));
            },
            .row => |row| {
                // The row first, its chips after: the hit map scans back
                // to front, so a chip registered later wins the click
                // over the row it sits on (D6 — last painted wins).
                ui.hit(r, .{ .overlay_item = row.id });
                var x = r.x + 1;
                x += ui.putStr(x, y, 2, if (focused) (if (ui.ascii) "> " else "▸ ") else "  ", Theme.onBg(t.accent, row_style.bg));
                const label = ui.fmt("{s}:", .{row.label});
                x += ui.putStr(x, y, r.right() -| x, label, Theme.onBg(if (focused) t.fg else t.fg, row_style.bg));
                x += label_w + 3 - @min(label_w + 3, ui.width(label));
                if (row.number) |num| {
                    // `‹ [32] ›` — the arrows step; the value is the row.
                    const prev_x = x;
                    x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) "<" else "‹", Theme.onBg(if (row.current > num.min) t.accent else t.muted, row_style.bg));
                    ui.hit(Rect.init(prev_x, y, 1, 1), .{ .overlay_item = optionHit(row.id, 0) });
                    x += 1;
                    const cur = ui.fmt("[{d}]", .{row.current});
                    const cw = ui.width(cur);
                    _ = ui.putStr(x, y, r.right() -| x, cur, t.chip_active);
                    ui.hit(Rect.init(x, y, cw, 1), .{ .overlay_item = row.id });
                    x += cw + 1;
                    const next_x = x;
                    x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) ">" else "›", Theme.onBg(if (row.current < num.max) t.accent else t.muted, row_style.bg));
                    ui.hit(Rect.init(next_x, y, 1, 1), .{ .overlay_item = optionHit(row.id, 1) });
                } else if (row.options.len > max_listed_options) {
                    // `[current] ‹ i/n ›` — the arrows are the neighbours' hits.
                    const n = row.options.len;
                    const cur = ui.fmt("[{s}]", .{row.options[row.current]});
                    const cw = ui.width(cur);
                    _ = ui.putStr(x, y, r.right() -| x, cur, t.chip_active);
                    ui.hit(Rect.init(x, y, cw, 1), .{ .overlay_item = row.id });
                    x += cw + 1;
                    const prev_x = x;
                    x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) "<" else "‹", Theme.onBg(t.accent, row_style.bg));
                    ui.hit(Rect.init(prev_x, y, 1, 1), .{ .overlay_item = optionHit(row.id, (row.current + n - 1) % n) });
                    x += ui.putStr(x, y, r.right() -| x, ui.fmt(" {d}/{d} ", .{ row.current + 1, n }), Theme.onBg(t.muted, row_style.bg));
                    const next_x = x;
                    x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) ">" else "›", Theme.onBg(t.accent, row_style.bg));
                    ui.hit(Rect.init(next_x, y, 1, 1), .{ .overlay_item = optionHit(row.id, (row.current + 1) % n) });
                } else {
                    // Every choice when the row has room; otherwise a
                    // window around the active one, the hidden side
                    // marked `‹` / `›` (each a hit on the nearest hidden
                    // choice), so the bracketed value is always on screen
                    // and `→` never steps onto one that is not.
                    const star: u16 = if (row.modified) 2 else 0;
                    const win = choiceWindow(ui, row.options, row.current, (r.right() -| x) -| star);
                    const mark_style = Theme.onBg(t.accent, row_style.bg);
                    if (win.lo > 0) {
                        ui.hit(Rect.init(x, y, 1, 1), .{ .overlay_item = optionHit(row.id, win.lo - 1) });
                        x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) "< " else "‹ ", mark_style);
                    }
                    var i = win.lo;
                    while (i < win.hi) : (i += 1) {
                        if (i > win.lo) x += ui.putStr(x, y, r.right() -| x, " / ", Theme.onBg(t.muted, row_style.bg));
                        const active = i == row.current;
                        const text = if (active) ui.fmt("[{s}]", .{row.options[i]}) else row.options[i];
                        const ow = ui.width(text);
                        const style: Style = if (active) t.chip_active else Theme.onBg(t.muted, row_style.bg);
                        _ = ui.putStr(x, y, r.right() -| x, text, style);
                        ui.hit(Rect.init(x, y, @min(ow, r.right() -| x), 1), .{ .overlay_item = optionHit(row.id, i) });
                        x += ow;
                    }
                    if (win.hi < row.options.len) {
                        x += ui.putStr(x, y, r.right() -| x, if (ui.ascii) " >" else " ›", mark_style);
                        ui.hit(Rect.init(x -| 1, y, 1, 1), .{ .overlay_item = optionHit(row.id, win.hi) });
                    }
                }
                if (row.modified and x + 2 < r.right()) _ = ui.putStr(x + 2, y, 1, "*", Theme.withFg(row_style, t.warn_fg.fg));
            },
            .action => |a| {
                var x = r.x + 1;
                x += ui.putStr(x, y, 2, if (focused) (if (ui.ascii) "> " else "▸ ") else "  ", Theme.onBg(t.accent, row_style.bg));
                _ = ui.putStr(x, y, r.right() -| x, ui.clipStr(a.label, r.right() -| x), Theme.withFg(row_style, t.error_fg.fg));
                ui.hit(r, .{ .overlay_item = a.id });
            },
        }
    }
    // Footer: the key hint, right-aligned, clipped when the box is narrow.
    const foot = inner.row(inner.h - 1);
    ui.fill(foot, t.overlay_bg);
    var hint_style = Theme.onBg(t.muted, bg);
    hint_style.dim = false;
    _ = ui.putStrRight(foot.right() -| 1, foot.y, foot.w -| 2, ui.clipStr(hint, foot.w -| 2), hint_style);
}

const hint_text_ascii = "<- -> adjust - up/down move - r/R reset - Enter save - Esc cancel";

/// `[lo, hi)` of `options` a row of `avail` cells shows: the active
/// choice always, then its neighbours added right, left, right… while
/// `a / [b] / c` plus a `‹ ` / ` ›` for each hidden side still fits. The
/// whole list when it fits; the active choice alone when nothing else
/// does.
pub const Window = struct { lo: usize, hi: usize };

pub fn choiceWindow(ui: Ui, options: []const []const u8, current: usize, avail: u16) Window {
    const n = options.len;
    if (n == 0) return .{ .lo = 0, .hi = 0 };
    const cur = @min(current, n - 1);
    var lo = cur;
    var hi = cur + 1;
    var width: u16 = ui.width(options[cur]) + 2;
    while (true) {
        var grew = false;
        if (hi < n) {
            const w = width + 3 + ui.width(options[hi]);
            if (w + marks(lo, hi + 1, n) <= avail) {
                width = w;
                hi += 1;
                grew = true;
            }
        }
        if (lo > 0) {
            const w = width + 3 + ui.width(options[lo - 1]);
            if (w + marks(lo - 1, hi, n) <= avail) {
                width = w;
                lo -= 1;
                grew = true;
            }
        }
        if (!grew) return .{ .lo = lo, .hi = hi };
    }
}

/// Cells the `‹ ` / ` ›` marks take for a window `[lo, hi)` of `n`.
fn marks(lo: usize, hi: usize, n: usize) u16 {
    return @as(u16, if (lo > 0) 2 else 0) + @as(u16, if (hi < n) 2 else 0);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const bool_opts = [_][]const u8{ "off", "on" };
const style_opts = [_][]const u8{ "vim", "standard" };
const many_opts = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };

fn sample() [6]Item {
    return .{
        .{ .section = "UI" },
        .{ .row = .{ .label = "Line numbers", .options = &bool_opts, .current = 1, .id = 0 } },
        .{ .section = "Editor" },
        .{ .row = .{ .label = "Input style", .options = &style_opts, .current = 1, .modified = true, .id = 1 } },
        .{ .row = .{ .label = "Theme", .options = &many_opts, .current = 2, .id = 2 } },
        .{ .action = .{ .label = "Reset all to defaults", .id = 3 } },
    };
}

test "rows paint as `▸ Label:  [active] / other  *`, colons aligned, hits per row and option; long lists paint one" {
    // 16 rows: the box caps at ~70 % of the screen, and six items plus
    // the chrome need eleven.
    var f = try Fixture.init(90, 16);
    defer f.deinit();
    var s: State = .{};
    const items = sample();
    draw(f.ui(), f.full(), &s, &items, "→ .mnml/config.zon");
    const text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, " Settings · → .mnml/config.zon ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "── UI ──") != null);
    try testing.expect(std.mem.indexOf(u8, text, "▸ Line numbers:  off / [on]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  Input style:   vim / [standard]  *") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  Theme:         [c] ‹ 3/8 ›") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Reset all to defaults") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Esc cancel") != null);
    // the first focusable is the cursor; a row hit and an option hit exist
    try testing.expectEqual(@as(usize, 1), s.cursor);
    var saw_row = false;
    var saw_opt = false;
    var saw_next = false;
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .surface => {},
        .row => |id| saw_row = saw_row or id == 0,
        .option => |o| {
            saw_opt = saw_opt or (o.id == 1 and o.index == 0);
            saw_next = saw_next or (o.id == 2 and o.index == 3);
        },
    };
    try testing.expect(saw_row and saw_opt and saw_next);
    // Every chip painted is a chip the pointer reaches: the scan from the
    // back must resolve a chip's own cells to the chip, not to the row
    // that carries it — the `off` / `[on]` pair and the long list's `‹`.
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .option => |o| try testing.expectEqual(Hit{ .option = o }, decodeHit(f.hits.at(h.rect.x, h.rect.y).?.overlay_item)),
        else => {},
    };
    // …and the row's label cell is still the row.
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .row => |id| if (id == 0) try testing.expectEqual(Hit{ .row = 0 }, decodeHit(f.hits.at(h.rect.x + 3, h.rect.y).?.overlay_item)),
        else => {},
    };
}

test "choices that overflow the row paint a window around the active one, marked on the hidden side" {
    var f = try Fixture.init(46, 5);
    defer f.deinit();
    const sorts = [_][]const u8{ "newest", "oldest", "name", "name_desc" };
    var s: State = .{};
    var items = [_]Item{
        .{ .row = .{ .label = "Sort", .options = &sorts, .current = 0, .id = 7 } },
    };
    draw(f.ui(), f.full(), &s, &items, null);
    var text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ Sort:  [newest] / oldest / name ›") != null);
    try testing.expect(std.mem.indexOf(u8, text, "name_desc") == null);
    // `›` is the nearest hidden choice's hit.
    var saw_next = false;
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .option => |o| if (o.index == 3) {
            saw_next = true;
            try testing.expectEqual(@as(u16, 1), h.rect.w);
        },
        else => {},
    };
    try testing.expect(saw_next);
    // The active value stays visible wherever it is; the far side drops.
    items[0].row.current = 3;
    f.hits.reset();
    draw(f.ui(), f.full(), &s, &items, null);
    text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ Sort:  ‹ oldest / name / [name_desc]") != null);
    // Room for everything paints everything, no marks.
    var wide = try Fixture.init(60, 5);
    defer wide.deinit();
    draw(wide.ui(), wide.full(), &s, &items, null);
    text = try wide.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ Sort:  newest / oldest / name / [name_desc]") != null);
    // The pure window arithmetic: a row too narrow for anything but the
    // active choice shows it alone.
    const w = choiceWindow(f.ui(), &sorts, 2, 6);
    try testing.expectEqual(@as(usize, 2), w.lo);
    try testing.expectEqual(@as(usize, 3), w.hi);
}

test "the box is ~60 % of the screen wide and caps at ~70 % tall; a long list scrolls inside it" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    var s: State = .{};
    var items: [60]Item = undefined;
    items[0] = .{ .section = "UI" };
    for (1..60) |i| items[i] = .{ .row = .{ .label = "Row", .options = &bool_opts, .current = 0, .id = @intCast(i) } };
    draw(f.ui(), f.full(), &s, &items, null);
    const text = try f.text();
    // 70 % of 40 rows = 28: the frame's corners sit 28 rows apart, centered.
    var top: ?usize = null;
    var bottom: ?usize = null;
    var dashes: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var y: usize = 0;
    while (it.next()) |line| : (y += 1) {
        if (std.mem.indexOf(u8, line, "╭") != null and top == null) top = y;
        if (std.mem.indexOf(u8, line, "╰") != null) {
            bottom = y;
            dashes = std.mem.count(u8, line, "─");
        }
    }
    try testing.expectEqual(@as(usize, 6), top.?);
    try testing.expectEqual(@as(usize, 33), bottom.?);
    // 60 % of 120 columns = 72 wide: the bottom border is 70 dashes between its corners.
    try testing.expectEqual(@as(usize, 70), dashes);
    // The list scrolls: the last row is not painted, the first is.
    try testing.expectEqual(@as(usize, 28 - 3), s.rows);
}

test "a number row paints ‹ [value] › with a hit on each arrow" {
    var f = try Fixture.init(60, 6);
    defer f.deinit();
    var s: State = .{};
    const items = [_]Item{
        .{ .section = "UI" },
        .{ .row = .{ .label = "Right panel width", .options = &.{}, .current = 32, .id = 4, .number = .{ .min = 8, .max = 120, .step = 2 } } },
    };
    draw(f.ui(), f.full(), &s, &items, null);
    const text = try f.text();
    try testing.expect(std.mem.indexOf(u8, text, "▸ Right panel width:  ‹ [32] ›") != null);
    var down = false;
    var up = false;
    for (f.hits.items.items) |h| switch (decodeHit(h.target.overlay_item)) {
        .option => |o| {
            down = down or (o.id == 4 and o.index == 0);
            up = up or (o.id == 4 and o.index == 1);
        },
        else => {},
    };
    try testing.expect(down and up);
    try testing.expectEqual(@as(i8, 1), handleKey(&s, Key.named(.right), &items).adjust.delta);
}

test "the wheel slides the window and carries the cursor with it" {
    var f = try Fixture.init(60, 7);
    defer f.deinit();
    var s: State = .{};
    const items = sample();
    // Nothing before a draw: the window height is unknown.
    s.wheel(&items, 2);
    try testing.expectEqual(@as(usize, 0), s.scroll);
    draw(f.ui(), f.full(), &s, &items, null);
    try testing.expect(s.rows > 0 and s.rows < items.len);
    s.wheel(&items, 2);
    try testing.expectEqual(@as(usize, 2), s.scroll);
    try testing.expect(s.cursor >= s.scroll);
    try testing.expect(items[s.cursor].focusable());
    // The draw keeps the window where the wheel put it.
    draw(f.ui(), f.full(), &s, &items, null);
    try testing.expectEqual(@as(usize, 2), s.scroll);
    // Back up past the top clamps; the cursor comes along (a header at 0
    // is skipped for the first row).
    s.cursor = items.len - 1;
    s.wheel(&items, -10);
    try testing.expectEqual(@as(usize, 0), s.scroll);
    try testing.expect(s.cursor < s.rows);
    try testing.expect(items[s.cursor].focusable());
}

test "keys: move skips headers, adjust/reset/save/cancel come back as outcomes" {
    var s: State = .{};
    const items = sample();
    try testing.expect(handleKey(&s, Key.named(.down), &items) == .consumed);
    try testing.expectEqual(@as(usize, 3), s.cursor);
    try testing.expectEqual(@as(i8, 1), handleKey(&s, Key.named(.right), &items).adjust.delta);
    try testing.expectEqual(@as(i8, -1), handleKey(&s, Key.char('h'), &items).adjust.delta);
    try testing.expectEqual(@as(usize, 3), handleKey(&s, Key.char('r'), &items).reset_row);
    try testing.expect(handleKey(&s, Key.char('R'), &items) == .reset_all);
    try testing.expect(handleKey(&s, Key.named(.enter), &items) == .save);
    try testing.expect(handleKey(&s, Key.named(.esc), &items) == .cancel);
    _ = handleKey(&s, Key.char('j'), &items);
    try testing.expectEqual(@as(usize, 4), s.cursor);
    _ = handleKey(&s, Key.char('j'), &items);
    try testing.expectEqual(@as(usize, 5), handleKey(&s, Key.named(.enter), &items).activate);
    _ = handleKey(&s, Key.char('k'), &items);
    _ = handleKey(&s, Key.char('k'), &items);
    _ = handleKey(&s, Key.char('k'), &items);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    _ = handleKey(&s, Key.char('k'), &items); // nowhere further up
    try testing.expectEqual(@as(usize, 1), s.cursor);
}
