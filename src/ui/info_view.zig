//! The sidebar's info view — the Ableton-style help box at the bottom
//! of the left panel (Rust `ui/hover_help.rs`): a rule, a title row on
//! the lighter ground with the `⋮` kebab at its right edge, a spacer,
//! then the copy word-wrapped with a one-cell gutter — the body, an
//! italic aside, `[Chord] Label` shortcut rows, `→ label` links — and a
//! scrollbar when the copy outgrows the rows. The last row stays blank
//! as a cushion above the statusline.
//!
//! The copy is data (`Copy`); what it says about a target is the app's
//! business (`app/info_view.zig`). The whole box registers as
//! `info_view:body` first, so a press inside it never falls through to
//! the tree; the kebab and each link row register after it and win.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const hit = @import("hit.zig");
const pin_chip = @import("pin_chip.zig");
const focus_cue = @import("focus_cue.zig");

const Style = vaxis.Style;

pub const Part = hit.InfoPart;

pub const Shortcut = struct { chord: []const u8, label: []const u8 };

/// What a link row does when pressed — the painter only picks the
/// glyph by it; the app keeps the action, by position
/// (`app/info_view.zig`'s `State.links`).
pub const LinkKind = enum {
    /// `→ label`: runs a palette command.
    command,
    /// `⚙ label`: opens the Settings overlay on a row.
    settings,
    /// `↗ label`: a web page, through the OS browser.
    url,
    /// `✦ label`: asks the AI session about the thing under the pointer.
    ask,
    /// `§ label`: opens a section of the embedded manual as a preview.
    docs,

    pub fn glyph(k: LinkKind, ascii: bool) []const u8 {
        return switch (k) {
            .command => if (ascii) "->" else "→",
            .settings => if (ascii) "*" else "⚙",
            .url => if (ascii) "^" else "↗",
            .ask => if (ascii) "?" else "✦",
            .docs => if (ascii) "#" else "\u{00a7}",
        };
    }
};

/// A `→ label` row; the app keeps what it runs, by position.
pub const Link = struct { label: []const u8, kind: LinkKind = .command };

/// What the box says (Rust `InfoViewCopy`).
pub const Copy = struct {
    /// The topic, bold on the title row.
    title: []const u8,
    /// Prose, wrapped.
    body: []const u8 = "",
    /// One italic caveat after the body.
    aside: ?[]const u8 = null,
    /// The aside paints BEFORE the body: the ladder's mark on a
    /// control without an entry, which has to be on screen whatever the
    /// body's length.
    aside_first: bool = false,
    shortcuts: []const Shortcut = &.{},
    try_it: []const Link = &.{},
};

/// Rust's `to_flat_pair`: the body, the aside and the first two
/// shortcuts on one line — what the keyboard-focus ladder shows.
pub fn flatten(arena: std.mem.Allocator, c: Copy) std.mem.Allocator.Error!Copy {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, c.body);
    if (c.aside) |a| {
        if (out.items.len > 0) try out.appendSlice(arena, "  ");
        try out.appendSlice(arena, a);
    }
    for (c.shortcuts[0..@min(c.shortcuts.len, 2)]) |s| {
        if (out.items.len > 0) try out.appendSlice(arena, "  ");
        try out.print(arena, "[{s}] {s}", .{ s.chord, s.label });
    }
    return .{ .title = c.title, .body = out.items };
}

pub const Props = struct {
    copy: Copy,
    /// The first content line shown; the painter clamps it.
    scroll: u16 = 0,
    /// The entry is pinned: the title row's pin chip is lit.
    pinned: bool = false,
    /// The box has the keys (`help.focus`): its title lights as a
    /// section's header does (`focus_cue.label`).
    focused: bool = false,
    /// The keyboard's row, counted over the shortcut rows then the
    /// link rows; painted on the selection ground and scrolled into
    /// view. Null paints no cursor.
    cursor: ?usize = null,
    /// The top rule as a drag handle: its hit (registered over the
    /// whole row, after the box's, so it wins), and whether it is lit
    /// — under the pointer or being dragged, as a divider lights.
    rule: ?Rule = null,
};

pub const Rule = struct {
    hit: hit.HitTarget,
    /// Being dragged: lit whatever the pointer is over.
    lit: bool = false,
    /// A divider's lit style (the theme's accent).
    lit_style: Style,
};

pub const Layout = struct {
    /// The last `scroll` that still fills the rows; 0 when it all fits.
    max_scroll: u16 = 0,
    kebab: ?Rect = null,
    /// The pin chip's cells, when the title row had room for it.
    pin: ?Rect = null,
    /// The first line shown — `Props.scroll` clamped, and moved so the
    /// keyboard's row is on screen.
    scroll: u16 = 0,
};

/// The title row keeps at least this many cells for the title before
/// the pin chip is dropped from it.
pub const pin_min_title: u16 = 6;

pub const kebab_glyph = "⋮";
pub const kebab_ascii = ":";

const Line = struct {
    /// Painted after the gutter cell.
    segs: []const vaxis.Segment,
    /// A `→ label` row: its index in `copy.try_it`.
    link: ?u8 = null,
    /// A row the keyboard walks: shortcuts first, then links.
    row: ?usize = null,
};

pub fn draw(ui: Ui, area: Rect, p: Props) Layout {
    var out: Layout = .{};
    if (area.isEmpty()) return out;
    const t = ui.theme;
    const pal = t.palette;
    const body_bg = pal.bg_darker;
    const title_bg = pal.bg2;
    ui.fill(area, Theme.onBg(t.fg, body_bg));
    ui.hit(area, .{ .info_view = .body });
    // Row 0: the rule — and, handed a hit, the handle that drags the
    // box's height, lit like a divider under the pointer.
    var sep = Theme.onBg(Theme.withFg(t.fg, pal.comment), body_bg);
    sep.dim = true;
    const rule_row = Rect.init(area.x, area.y, area.w, 1);
    if (p.rule) |r| if (r.lit or ui.hovered(rule_row)) {
        sep = Theme.onBg(Theme.withFg(t.fg, r.lit_style.fg), body_bg);
    };
    ui.hrule(area.x, area.y, area.w, sep);
    if (p.rule) |r| ui.hit(rule_row, r.hit);
    if (area.h <= 1) return out;
    // Row 1: the title band, from the second cell (the first keeps the
    // panel's ground so the band never touches the activity bar), the
    // kebab and a trailing cell at the right.
    const ty = area.y + 1;
    const kebab_cells: u16 = 2;
    // The pin sits left of the kebab when the title keeps room beside
    // it; a narrower box has the kebab alone.
    const with_pin = area.w >= kebab_cells + pin_chip.width + 1 + pin_min_title;
    const title_avail = area.w -| kebab_cells -| 1 -| (if (with_pin) pin_chip.width else 0);
    var title_style = focus_cue.label(t, ui.focus_cue, p.focused, Theme.onBg(t.fg, title_bg));
    title_style.bold = true;
    ui.fill(Rect.init(area.x + 1, ty, title_avail, 1), title_style);
    // A long title is cut, not ellipsised (Rust), a cell short of the
    // kebab — or of the pin, whose own leading cell is that gap.
    _ = ui.putStr(area.x + 1, ty, if (with_pin) title_avail else title_avail -| 1, p.copy.title, title_style);
    if (area.w >= 3) {
        const kx = area.right() - kebab_cells;
        ui.fill(Rect.init(kx, ty, kebab_cells, 1), Theme.onBg(t.fg, title_bg));
        _ = ui.putStr(kx, ty, 1, if (ui.ascii) kebab_ascii else kebab_glyph, Theme.onBg(Theme.withFg(t.fg, pal.comment), title_bg));
        const kr = Rect.init(kx, ty, 1, 1);
        ui.hit(kr, .{ .info_view = .kebab });
        out.kebab = kr;
        if (with_pin) {
            const pr = Rect.init(kx - pin_chip.width, ty, pin_chip.width, 1);
            pin_chip.draw(ui, pr, .{ .pinned = p.pinned, .bg = title_bg, .hit = .{ .info_view = .pin } });
            out.pin = pr;
        }
    }
    if (area.h <= 2) return out;
    // Rows 2..: the lines, wrapped to the width less the gutters — and
    // a cell narrower when they overflow, so the text stops a cell
    // short of the bar.
    const body = Rect.init(area.x, area.y + 2, area.w, area.h -| 3);
    const cap: usize = body.h;
    var content_w = area.w -| 2;
    var lines = buildLines(ui, p, content_w) orelse return out;
    if (lines.items.len > cap and content_w > 1) {
        content_w -= 1;
        lines = buildLines(ui, p, content_w) orelse return out;
    }
    const total = lines.items.len;
    const overflow = total > cap;
    out.max_scroll = @intCast(total -| cap);
    var scroll: usize = @min(p.scroll, out.max_scroll);
    // The keyboard's row stays on screen.
    if (p.cursor) |c| for (lines.items, 0..) |line, li| if (line.row != null and line.row.? == c) {
        if (li < scroll) scroll = li else if (li >= scroll + cap) scroll = li + 1 - cap;
        break;
    };
    out.scroll = @intCast(scroll);
    const text_w = body.w -| @as(u16, if (overflow) 2 else 0);
    for (lines.items[scroll..@min(total, scroll + cap)], 0..) |line, i| {
        const y: u16 = body.y + @as(u16, @intCast(i));
        const on_cursor = p.cursor != null and line.row != null and line.row.? == p.cursor.?;
        if (on_cursor) ui.fill(Rect.init(body.x, y, text_w, 1), Theme.onBg(t.fg, t.selection.bg));
        var lx = body.x + 1;
        for (line.segs) |s| lx += ui.putStr(lx, y, (body.x + text_w) -| lx, s.text, if (on_cursor) Theme.onBg(s.style, t.selection.bg) else s.style);
        if (line.link) |li| ui.hit(Rect.init(body.x, y, text_w, 1), .{ .info_view = .{ .try_it = li } });
    }
    if (overflow) {
        // The track in the comment colour, the thumb in cyan (Rust).
        const track_h: usize = body.h;
        const thumb_h = @max(1, (cap * track_h) / total);
        const thumb_y = if (out.max_scroll == 0) 0 else (scroll * (track_h -| thumb_h)) / out.max_scroll;
        const sx = body.right() - 1;
        var i: usize = 0;
        while (i < track_h) : (i += 1) {
            const is_thumb = i >= thumb_y and i < thumb_y + thumb_h;
            _ = ui.putStr(sx, body.y + @as(u16, @intCast(i)), 1, if (is_thumb) (if (ui.ascii) "#" else "┃") else (if (ui.ascii) "|" else "│"), Theme.onBg(Theme.withFg(t.fg, if (is_thumb) pal.cyan else pal.comment), body_bg)); // chrome-audit: allow — Rust's info-view bar (cyan thumb on a comment track, no hit); scrollbar.zig is the candidate once hit.Owner has an info-view variant
        }
    }
    return out;
}

/// The body's lines at `content_w`: a blank, the body and the aside
/// wrapped, then every shortcut and every link after a spacer each.
/// Nothing is dropped for want of rows — the box scrolls, so a link
/// under a long body is a notch or two of the wheel away rather than
/// gone (Rust cut the rows that did not fit on screen, and at the
/// default height every link under a long body with them). Null on OOM.
fn buildLines(ui: Ui, p: Props, content_w: u16) ?std.ArrayListUnmanaged(Line) {
    const arena = ui.arena;
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    const t = ui.theme;
    const pal = t.palette;
    const body_bg = pal.bg_darker;
    const fg = Theme.onBg(t.fg, body_bg);
    var aside_style = Theme.onBg(Theme.withFg(t.fg, pal.comment), body_bg);
    aside_style.italic = true;
    var chord_style = Theme.onBg(Theme.withFg(t.fg, pal.cyan), body_bg);
    chord_style.bold = true;
    var link_style = Theme.onBg(Theme.withFg(t.fg, pal.green), body_bg);
    link_style.bold = true;
    link_style.ul_style = .single;
    lines.append(arena, .{ .segs = &.{} }) catch return null;
    if (p.copy.aside_first) if (p.copy.aside) |a| for (wrapWords(arena, a, content_w) catch return null) |l| lines.append(arena, .{ .segs = seg1(arena, l, aside_style) catch return null }) catch return null;
    for (wrapWords(arena, p.copy.body, content_w) catch return null) |l| lines.append(arena, .{ .segs = seg1(arena, l, fg) catch return null }) catch return null;
    if (!p.copy.aside_first) if (p.copy.aside) |a| for (wrapWords(arena, a, content_w) catch return null) |l| lines.append(arena, .{ .segs = seg1(arena, l, aside_style) catch return null }) catch return null;
    if (p.copy.shortcuts.len > 0) {
        lines.append(arena, .{ .segs = &.{} }) catch return null;
        for (p.copy.shortcuts, 0..) |s, i| {
            const segs = arena.alloc(vaxis.Segment, 2) catch return null;
            segs[0] = .{ .text = ui.fmt("[{s}]", .{s.chord}), .style = chord_style };
            segs[1] = .{ .text = ui.fmt(" {s}", .{s.label}), .style = fg };
            lines.append(arena, .{ .segs = segs, .row = i }) catch return null;
        }
    }
    if (p.copy.try_it.len > 0) {
        lines.append(arena, .{ .segs = &.{} }) catch return null;
        for (p.copy.try_it, 0..) |l, i| {
            lines.append(arena, .{ .segs = seg1(arena, ui.fmt("{s} {s}", .{ l.kind.glyph(ui.ascii), l.label }), link_style) catch return null, .link = @intCast(i), .row = p.copy.shortcuts.len + i }) catch return null;
        }
    }
    return lines;
}

fn seg1(arena: std.mem.Allocator, text: []const u8, style: Style) std.mem.Allocator.Error![]const vaxis.Segment {
    const segs = try arena.alloc(vaxis.Segment, 1);
    segs[0] = .{ .text = text, .style = style };
    return segs;
}

/// Rust `wrap_words`: greedy on whitespace, a word longer than the
/// width hard-broken, counting code points. Empty text is one empty
/// line.
pub fn wrapWords(arena: std.mem.Allocator, text: []const u8, width: u16) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (width == 0 or text.len == 0) {
        try out.append(arena, "");
        return out.items;
    }
    var line: std.ArrayListUnmanaged(u8) = .empty;
    var line_len: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        const word_len = std.unicode.utf8CountCodepoints(word) catch word.len;
        if (word_len > width) {
            if (line.items.len > 0) {
                try out.append(arena, try line.toOwnedSlice(arena));
                line_len = 0;
            }
            var it = std.unicode.Utf8View.initUnchecked(word).iterator();
            var chunk: std.ArrayListUnmanaged(u8) = .empty;
            var n: usize = 0;
            while (it.nextCodepointSlice()) |cp| {
                try chunk.appendSlice(arena, cp);
                n += 1;
                if (n == width) {
                    try out.append(arena, try chunk.toOwnedSlice(arena));
                    n = 0;
                }
            }
            if (n > 0) {
                line = chunk;
                line_len = n;
            }
            continue;
        }
        const needed = if (line_len == 0) word_len else line_len + 1 + word_len;
        if (needed > width) {
            try out.append(arena, try line.toOwnedSlice(arena));
            line = .empty;
            try line.appendSlice(arena, word);
            line_len = word_len;
        } else {
            if (line_len > 0) {
                try line.append(arena, ' ');
                line_len += 1;
            }
            try line.appendSlice(arena, word);
            line_len += word_len;
        }
    }
    if (line.items.len > 0) try out.append(arena, line.items);
    if (out.items.len == 0) try out.append(arena, "");
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const sidebar_copy: Copy = .{ .title = "Sidebar", .body = "Arrows or j/k walk rows. Enter opens the selection. Ctrl+Shift+P opens the palette." };

test "the spec's rows 27..33 at 26x11: the rule, `Sidebar` with the kebab, a spacer, the body wrapped at 24" {
    var f = try Fixture.init(26, 11);
    defer f.deinit();
    const l = draw(f.ui(), f.full(), .{ .copy = sidebar_copy });
    try f.expectRows(&.{
        "──────────────────────────",
        " Sidebar              󰐃 ⋮",
        "",
        " Arrows or j/k walk rows.",
        " Enter opens the",
        " selection. Ctrl+Shift+P",
        " opens the palette.",
        "",
        "",
        "",
        "",
    });
    try testing.expectEqual(@as(u16, 0), l.max_scroll);
    try testing.expect(l.kebab.?.eql(Rect.init(24, 1, 1, 1)));
    try testing.expect(f.hits.at(24, 1).?.info_view == .kebab);
    // The pin chip left of the kebab (`ui/pin_chip.zig`): its three
    // cells are its hit, cold (dim) until pinned.
    try testing.expect(l.pin.?.eql(Rect.init(21, 1, 3, 1)));
    try testing.expect(f.hits.at(21, 1).?.info_view == .pin);
    try testing.expect(f.hits.at(23, 1).?.info_view == .pin);
    try testing.expect(f.style(22, 1).dim);
    const lit = draw(f.ui(), f.full(), .{ .copy = sidebar_copy, .pinned = true });
    try testing.expect(lit.pin != null);
    try testing.expect(vaxis.Color.eql(f.style(22, 1).fg, f.theme.palette.yellow));
    try testing.expect(f.style(22, 1).bold);
    try testing.expect(f.hits.at(5, 4).?.info_view == .body);
    try testing.expect(f.hits.at(0, 0).?.info_view == .body);
    // The title band from the second cell on bg2, the first cell on the panel ground.
    try testing.expect(vaxis.Color.eql(f.style(1, 1).bg, f.theme.palette.bg2));
    try testing.expect(vaxis.Color.eql(f.style(25, 1).bg, f.theme.palette.bg2));
    try testing.expect(vaxis.Color.eql(f.style(0, 1).bg, f.theme.palette.bg_darker));
    try testing.expect(f.style(1, 1).bold);
    try testing.expect(f.style(3, 0).dim);
}

test "shortcuts and links get their rows after a spacer; a link row is a hit by index; a long title clips before the kebab" {
    var f = try Fixture.init(30, 10);
    defer f.deinit();
    const copy: Copy = .{
        .title = "A title that is far too long for the band",
        .body = "Body.",
        .aside = "An aside.",
        .shortcuts = &.{ .{ .chord = "Enter", .label = "Open" }, .{ .chord = "→ / ←", .label = "Expand / collapse" } },
        .try_it = &.{.{ .label = "Run it" }},
    };
    _ = draw(f.ui(), f.full(), .{ .copy = copy });
    try f.expectRow(1, " A title that is far too  󰐃 ⋮");
    try f.expectRow(3, " Body.                       ┃");
    try f.expectRow(4, " An aside.                   ┃");
    try f.expectRow(5, "                             ┃");
    try f.expectRow(6, " [Enter] Open                ┃");
    try f.expectRow(7, " [→ / ←] Expand / collapse   ┃");
    // Out of rows: the link is below the fold, not dropped — the bar
    // says there is more, and scrolled it is a row with its hit.
    try f.expectLacks("Run it");
    try testing.expect(f.style(4, 4).italic);
    try testing.expect(vaxis.Color.eql(f.style(2, 6).fg, f.theme.palette.cyan));
    var s = try Fixture.init(30, 10);
    defer s.deinit();
    const sl = draw(s.ui(), s.full(), .{ .copy = copy, .scroll = 99 });
    try testing.expectEqual(@as(u16, 1), sl.max_scroll);
    try s.expectRow(8, " → Run it                    ┃");
    try testing.expectEqual(@as(u8, 0), s.hits.at(3, 8).?.info_view.try_it);
    var g = try Fixture.init(30, 14);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), .{ .copy = copy });
    try g.expectRow(9, " → Run it");
    try testing.expectEqual(@as(u8, 0), g.hits.at(3, 9).?.info_view.try_it);
    try testing.expect(g.hits.at(3, 8).?.info_view == .body);
    try testing.expect(g.style(2, 9).ul_style == .single);
}

test "overflow: a scrollbar in the last column, the scroll clamped to what still fills the rows" {
    var f = try Fixture.init(20, 6);
    defer f.deinit();
    const copy: Copy = .{ .title = "T", .body = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen" };
    const l = draw(f.ui(), f.full(), .{ .copy = copy, .scroll = 99 });
    try testing.expect(l.max_scroll > 0);
    var buf: [64]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, f.row(2, &buf), "│") or std.mem.endsWith(u8, f.row(2, &buf), "┃"));
    try f.expectRow(5, "");
    // Scrolled to the end: the last wrapped line shows.
    try f.expectContains("fourteen");
    var g = try Fixture.init(20, 6);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), .{ .copy = copy, .scroll = 0 });
    try g.expectLacks("fourteen");
    try g.expectRow(2, "                   ┃");
    try g.expectRow(3, " one two three     │");
}

test "wrapWords: greedy on whitespace, a long word broken, empty is one line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try wrapWords(arena, "Arrows or j/k walk rows. Enter opens the selection.", 24);
    try testing.expectEqual(@as(usize, 3), a.len);
    try testing.expectEqualStrings("Arrows or j/k walk rows.", a[0]);
    try testing.expectEqualStrings("Enter opens the", a[1]);
    try testing.expectEqualStrings("selection.", a[2]);
    const b = try wrapWords(arena, "abcdefghij", 4);
    try testing.expectEqual(@as(usize, 3), b.len);
    try testing.expectEqualStrings("abcd", b[0]);
    try testing.expectEqualStrings("ij", b[2]);
    const c = try wrapWords(arena, "", 10);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqualStrings("", c[0]);
    const flat = try flatten(arena, .{ .title = "x/", .body = "Dir.", .shortcuts = &.{ .{ .chord = "Enter", .label = "Open" }, .{ .chord = "l", .label = "In" }, .{ .chord = "h", .label = "Out" } } });
    try testing.expectEqualStrings("Dir.  [Enter] Open  [l] In", flat.body);
    // Degenerate areas: a one-row box is the rule alone, a two-row one adds the title.
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .copy = sidebar_copy });
    try f.expectRow(0, "──────────");
    // Too narrow for the pin and a title beside it: the kebab alone.
    try f.expectRow(1, " Sideba ⋮");
    _ = draw(f.ui(), Rect.empty, .{ .copy = sidebar_copy });
}

test "the keyboard's box: the title lights as a focused section's header, the cursor's row sits on the selection ground and is scrolled into view" {
    var f = try Fixture.init(30, 10);
    defer f.deinit();
    const copy: Copy = .{
        .title = "T",
        .body = "Body.",
        .aside = "An aside.",
        .shortcuts = &.{ .{ .chord = "Enter", .label = "Open" }, .{ .chord = "→ / ←", .label = "Expand / collapse" } },
        .try_it = &.{.{ .label = "Run it" }},
    };
    // Unfocused: the title keeps its own colour; no cursor painted.
    _ = draw(f.ui(), f.full(), .{ .copy = copy });
    const cold = f.style(1, 1);
    try testing.expect(!vaxis.Color.eql(cold.fg, f.theme.accent.fg));
    // Focused (the default `both` cue lights): the accent.
    var l = draw(f.ui(), f.full(), .{ .copy = copy, .focused = true, .cursor = 0 });
    try testing.expect(vaxis.Color.eql(f.style(1, 1).fg, f.theme.accent.fg));
    // Cursor 0 is the first shortcut row (row 6): the selection ground.
    try testing.expect(f.bgEql(3, 6, .{ .bg = f.theme.selection.bg }));
    try testing.expect(!f.bgEql(3, 7, .{ .bg = f.theme.selection.bg }));
    try testing.expectEqual(@as(u16, 0), l.scroll);
    // Cursor 2 is the link, below the fold at scroll 0: the view follows.
    l = draw(f.ui(), f.full(), .{ .copy = copy, .focused = true, .cursor = 2 });
    try testing.expectEqual(@as(u16, 1), l.scroll);
    try f.expectRow(8, " → Run it                    ┃");
    try testing.expect(f.bgEql(3, 8, .{ .bg = f.theme.selection.bg }));
    // Back up to row 0 from a scrolled view: it follows up again.
    l = draw(f.ui(), f.full(), .{ .copy = copy, .focused = true, .cursor = 0, .scroll = 1 });
    try testing.expectEqual(@as(u16, 1), l.scroll);
    var g = try Fixture.init(30, 6);
    defer g.deinit();
    const tall = draw(g.ui(), g.full(), .{ .copy = copy, .focused = true, .cursor = 0, .scroll = 3 });
    try testing.expect(tall.scroll <= 4);
    try g.expectContains("[Enter] Open");
}

test "the rule as a handle: its hit over the whole top row wins over the box's, and it lights under the pointer or while dragged" {
    var f = try Fixture.init(26, 11);
    defer f.deinit();
    const accent = f.theme.accent;
    const rule: Rule = .{ .hit = .{ .divider = 7 }, .lit_style = accent };
    _ = draw(f.ui(), f.full(), .{ .copy = sidebar_copy, .rule = rule });
    try testing.expectEqual(@as(u32, 7), f.hits.at(0, 0).?.divider);
    try testing.expectEqual(@as(u32, 7), f.hits.at(25, 0).?.divider);
    try testing.expect(f.hits.at(5, 1).? == .info_view);
    try testing.expect(f.style(3, 0).dim);
    try testing.expect(!vaxis.Color.eql(f.style(3, 0).fg, accent.fg));
    // Being dragged: lit, not dim.
    _ = draw(f.ui(), f.full(), .{ .copy = sidebar_copy, .rule = .{ .hit = rule.hit, .lit = true, .lit_style = accent } });
    try testing.expect(vaxis.Color.eql(f.style(3, 0).fg, accent.fg));
    try testing.expect(!f.style(3, 0).dim);
    // Under the pointer: lit the same way.
    var g = try Fixture.init(26, 11);
    defer g.deinit();
    g.hover = .{ .x = 12, .y = 0 };
    _ = draw(g.ui(), g.full(), .{ .copy = sidebar_copy, .rule = rule });
    try testing.expect(vaxis.Color.eql(g.style(3, 0).fg, accent.fg));
    // No handle: the rule is the box's, as before.
    var h = try Fixture.init(26, 11);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), .{ .copy = sidebar_copy });
    try testing.expect(h.hits.at(0, 0).?.info_view == .body);
}
