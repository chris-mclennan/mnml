//! Panel header — the caps title (`TODOS`, `NOTES`, `SESSIONS`), the dim
//! `(N of M)` subtitle beside it, and a right-aligned cluster of chips:
//! an optional mode chip (`sort: Newest first`) and the refresh glyph.
//!
//! Widths are resolved right to left and every piece is DROPPED rather
//! than clipped when it will not fit: a half-painted chip is a dead
//! click target, worse than none. The order of sacrifice is the width
//! ladder from the Rust `panel_chrome.rs`:
//!
//!   1. the refresh chip needs `label + 3 + refresh`; without that the
//!      row is just the title;
//!   2. the subtitle is next to go — the count is nice, the button is
//!      functional, and a filter that grows `(3)` into `(3 of 40)` must
//!      not delete the refresh chip mid-keystroke;
//!   3. the mode chip has three rungs: the full ` key: value `, the
//!      icon alone, nothing. The middle rung is what makes the chip
//!      exist at the shipped default sidebar width — the full form
//!      needs ~38 cells against 26 available, and in the Rust mnml the
//!      sort control was invisible at stock settings for that reason.
//!
//! The chip hits are registered by `chip.paint`, in the same statement
//! as the cells they cover.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const chip = @import("chip.zig");
const hit = @import("hit.zig");

const Style = vaxis.Style;

pub const PanelId = hit.PanelId;
pub const ChipKind = hit.ChipKind;

pub const Props = struct {
    panel: PanelId,
    /// Painted as given — callers pass caps.
    label: []const u8,
    /// `(3 of 40)` — painted dim after the label, dropped before the chips.
    subtitle: ?[]const u8 = null,
    /// The full ` key: value ` text (see `chip.modeText`); null = no chip.
    mode_chip: ?[]const u8 = null,
    mode_kind: ChipKind = .sort,
    show_refresh: bool = true,
    /// The panel's ground.
    bg: Style,
};

pub const Layout = struct {
    /// Where the mode chip painted (full or icon), null when dropped.
    mode: ?Rect = null,
    /// True when the icon rung was used.
    mode_is_icon: bool = false,
    refresh: ?Rect = null,
};

pub fn labelStyle(t: *const Theme, bg: Style) Style {
    var s = Theme.onBg(t.muted, bg.bg);
    s.bold = true;
    return s;
}

pub fn subtitleStyle(t: *const Theme, bg: Style) Style {
    var s = Theme.onBg(t.muted, bg.bg);
    s.dim = true;
    return s;
}

pub fn draw(ui: Ui, area: Rect, p: Props) Layout {
    var out: Layout = .{};
    ui.fill(area, p.bg);
    if (area.isEmpty()) return out;
    const t = ui.theme;
    const y = area.y;
    const w = area.w;

    const label_w = ui.width(p.label);
    const refresh_text = chip.refreshIcon(ui.ascii);
    const refresh_w: u16 = if (p.show_refresh) ui.width(refresh_text) else 0;

    // Rung 0: no room for any chip — the title alone, clipped.
    const refresh_fits = w >= label_w + refresh_w + 3;
    if (!refresh_fits) {
        _ = ui.putStr(area.x + 1, y, w -| 1, ui.clipStr(p.label, w -| 1), labelStyle(t, p.bg));
        return out;
    }

    // The subtitle is droppable.
    var sub: ?[]const u8 = null;
    var sub_w: u16 = 0;
    if (p.subtitle) |s| {
        if (s.len > 0) {
            const sw = ui.width(s);
            if (w >= label_w + sw + refresh_w + 3) {
                sub = s;
                sub_w = sw;
            }
        }
    }

    // The mode chip: full, icon, or nothing.
    var mode_text: ?[]const u8 = null;
    var mode_w: u16 = 0;
    if (p.mode_chip) |full| {
        const full_w = ui.width(full);
        const icon = chip.modeIcon(ui.ascii);
        const icon_w = ui.width(icon);
        if (w >= label_w + sub_w + refresh_w + full_w + 4) {
            mode_text = full;
            mode_w = full_w;
        } else if (w >= label_w + sub_w + refresh_w + icon_w + 4) {
            mode_text = icon;
            mode_w = icon_w;
            out.mode_is_icon = true;
        }
    }

    const refresh_x = area.right() - refresh_w;
    // One cell of air between the two chips.
    const gap: u16 = if (p.show_refresh) 1 else 0;
    const mode_x = refresh_x -| (mode_w + gap);
    const title_end = if (mode_text != null) mode_x else refresh_x;

    var x = area.x + 1;
    x += ui.putStr(x, y, title_end -| x, p.label, labelStyle(t, p.bg));
    if (sub) |s| _ = ui.putStr(x, y, title_end -| x, s, subtitleStyle(t, p.bg));

    if (mode_text) |mt| {
        out.mode = chip.paint(ui, mode_x, y, mode_w, mt, chip.modeStyle(t), p.panel, p.mode_kind);
    }
    if (p.show_refresh) {
        out.refresh = chip.paint(ui, refresh_x, y, refresh_w, refresh_text, chip.refreshStyle(t, p.bg.bg), p.panel, .refresh);
    }
    return out;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn props(f: *Fixture, subtitle: ?[]const u8, mode: ?[]const u8) Props {
    return .{ .panel = .todos, .label = "TODOS", .subtitle = subtitle, .mode_chip = mode, .bg = f.theme.panel_bg };
}

const full_chip = " sort: Newest first ";

test "the ladder at the shipped default and around it: 26, 30, 34" {
    // Full chip needs 5 + 0 + 3 + 20 + 4 = 32; the icon rung 15.
    inline for (.{ 26, 30 }) |w| {
        var f = try Fixture.init(w, 1);
        defer f.deinit();
        const l = draw(f.ui(), f.full(), props(&f, null, full_chip));
        try testing.expect(l.mode_is_icon);
        try testing.expect(l.mode.?.eql(Rect.init(w - 3 - 1 - 3, 0, 3, 1)));
        try testing.expect(l.refresh.?.eql(Rect.init(w - 3, 0, 3, 1)));
        try f.expectRow(0, " TODOS" ++ " " ** (w - 6 - 7) ++ " \u{f0dc}   \u{eb37}");
        try testing.expectEqual(ChipKind.sort, f.hits.at(w - 6, 0).?.chip.kind);
        try testing.expectEqual(ChipKind.refresh, f.hits.at(w - 2, 0).?.chip.kind);
        try testing.expectEqual(hit.PanelId.todos, f.hits.at(w - 2, 0).?.chip.panel);
        try f.expectLacks("sort:");
    }
    var f = try Fixture.init(34, 1);
    defer f.deinit();
    const l = draw(f.ui(), f.full(), props(&f, null, full_chip));
    try testing.expect(!l.mode_is_icon);
    try testing.expect(l.mode.?.eql(Rect.init(34 - 3 - 1 - 20, 0, 20, 1)));
    try f.expectRow(0, " TODOS     sort: Newest first   \u{eb37}");
    try testing.expectEqual(ChipKind.sort, f.hits.at(12, 0).?.chip.kind);
    try testing.expect(f.hits.at(9, 0) == null);
    try testing.expect(f.bgEql(12, 0, f.theme.chip_active));
    try testing.expect(f.style(1, 0).bold);
}

test "the subtitle goes before the chips do, and the chips before the title" {
    // 5 + 10 + 3 + 3 = 21 ≤ 24: subtitle and icon both fit at 25.
    var f = try Fixture.init(25, 1);
    defer f.deinit();
    var l = draw(f.ui(), f.full(), props(&f, " (3 of 40)", full_chip));
    try testing.expect(l.mode_is_icon);
    try f.expectRow(0, " TODOS (3 of 40)   \u{f0dc}   \u{eb37}");
    try testing.expect(f.style(7, 0).dim);
    // At 20 the subtitle (needs 21 with refresh) is dropped; the icon stays.
    var g = try Fixture.init(20, 1);
    defer g.deinit();
    l = draw(g.ui(), g.full(), props(&g, " (3 of 40)", full_chip));
    try g.expectRow(0, " TODOS        \u{f0dc}   \u{eb37}");
    try testing.expect(l.mode != null);
    // At 12 the icon (needs 15) is gone; the refresh chip (needs 11) stays.
    var h = try Fixture.init(12, 1);
    defer h.deinit();
    l = draw(h.ui(), h.full(), props(&h, null, full_chip));
    try testing.expect(l.mode == null);
    try testing.expect(l.refresh != null);
    try h.expectRow(0, " TODOS    \u{eb37}");
    // At 10 there is no chip at all; the title still paints.
    var i = try Fixture.init(10, 1);
    defer i.deinit();
    l = draw(i.ui(), i.full(), props(&i, null, full_chip));
    try testing.expect(l.refresh == null);
    try i.expectRow(0, " TODOS");
    try testing.expectEqual(@as(usize, 0), i.hits.items.items.len);
}

test "a chip that shrinks keeps its right edge: the same cell hits before and after" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const a = draw(f.ui(), f.full(), props(&f, null, full_chip));
    const short = try chip.modeText(f.arena_state.allocator(), "sort", "Oldest first", 12);
    f.hits.reset();
    const b = draw(f.ui(), f.full(), props(&f, null, short));
    try testing.expect(a.mode.?.eql(b.mode.?));
    try f.expectContains(" sort: Oldest first ");
}

test "ascii glyphs, no refresh, a view chip, and degenerate areas" {
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    var ui = f.ui();
    ui.ascii = true;
    var p = props(&f, null, " view: Compact ");
    p.mode_kind = .view;
    const l = draw(ui, f.full(), p);
    try f.expectRow(0, " TODOS      view: Compact   \u{21ba}");
    try testing.expectEqual(ChipKind.view, f.hits.at(16, 0).?.chip.kind);
    try testing.expect(!l.mode_is_icon);
    // Without the refresh chip the mode chip takes the right edge.
    p.show_refresh = false;
    f.hits.reset();
    _ = draw(ui, f.full(), p);
    try f.expectRow(0, " TODOS          view: Compact");
    try testing.expectEqual(ChipKind.view, f.hits.at(29, 0).?.chip.kind);
    try testing.expectEqual(@as(usize, 1), f.hits.items.items.len);
    _ = draw(ui, Rect.empty, p);
    var g = try Fixture.init(3, 1);
    defer g.deinit();
    _ = draw(g.ui(), g.full(), props(&g, null, null));
    try g.expectRow(0, " T…");
}
