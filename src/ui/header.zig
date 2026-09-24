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
const focus_cue = @import("focus_cue.zig");

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
    /// A green ` + ` before the refresh chip (`ChipKind.new`): the HTTP
    /// panel's blank request.
    new_chip: bool = false,
    /// The panel's ground.
    bg: Style,
    /// // changed (sessions-merge): hosted by a pane, every chip is the
    /// pane's `.script_hit` (`hit.chipTarget`), and `extra` paints.
    pane: ?PaneId = null,
    /// Extra chips left of the mode chip, laid right to left, each
    /// dropped whole when it does not fit before the title. On a panel
    /// (no pane) only the chips that name a `kind` paint.
    extra: []const ExtraChip = &.{},
    /// The section has the keys: the label lights (`focus_cue.label`).
    /// Null is a header with no focus of its own to show.
    focused: ?bool = null,
};

pub const ExtraChip = struct {
    /// Painted as given — pad it yourself (` ended: hidden `).
    text: []const u8,
    /// The `.script_hit` id (pane-hosted).
    id: u32,
    /// Null paints in the mode chip's style.
    style: ?Style = null,
    /// // changed (sessions-card): on a panel (no pane) the chip's
    /// target is `.chip{ panel, kind }`; a chip with no kind is dropped
    /// there, as before.
    kind: ?ChipKind = null,
};

pub const PaneId = hit.PaneId;

/// The ` + ` chip's text and width.
pub const new_text = " + ";
pub const new_w: u16 = 3;

pub const Layout = struct {
    /// Where the mode chip painted (full or icon), null when dropped.
    mode: ?Rect = null,
    /// True when the icon rung was used.
    mode_is_icon: bool = false,
    refresh: ?Rect = null,
    /// Where the ` + ` chip painted.
    new: ?Rect = null,
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
    const label_style = if (p.focused) |f| focus_cue.label(t, ui.focus_cue, f, labelStyle(t, p.bg)) else labelStyle(t, p.bg);
    const refresh_text = chip.refreshIcon(ui.ascii);
    // `refresh_w` is the room the right-end chips take: the refresh
    // glyph and, with `new_chip`, the ` + ` before it.
    const refresh_w: u16 = (if (p.show_refresh) ui.width(refresh_text) else 0) + @as(u16, if (p.new_chip) new_w else 0);

    // Rung 0: no room for any chip — the title alone, clipped.
    const refresh_fits = w >= label_w + refresh_w + 3;
    if (!refresh_fits) {
        _ = ui.putStr(area.x + 1, y, w -| 1, ui.clipStr(p.label, w -| 1), label_style);
        return out;
    }

    // The subtitle is droppable. The header owns the one cell between
    // the label and it, so a caller passes `(2 running)` bare — a leading
    // space it does pass is folded into that one cell, never two.
    var sub: ?[]const u8 = null;
    var sub_w: u16 = 0;
    if (p.subtitle) |raw| {
        const s = std.mem.trimStart(u8, raw, " ");
        if (s.len > 0) {
            const sw = ui.width(s) + 1;
            if (w >= label_w + sw + refresh_w + 3) {
                sub = s;
                sub_w = sw;
            }
        }
    }

    // The mode chip: full, icon, or nothing — and the subtitle goes
    // before the chip does. In order: the full chip with the count, the
    // icon with the count, the full chip alone, the icon alone. A count
    // beside an icon still says what the panel holds and the icon is
    // still the whole button (click cycles, right-click lists).
    // // changed (panels): the first cut of this ladder only dropped
    // the subtitle when the REFRESH chip needed the room, so a wide
    // count (`(3 open of 12)`) deleted the sort chip at the shipped
    // panel width — the Rust bug this file's header describes.
    var mode_text: ?[]const u8 = null;
    var mode_w: u16 = 0;
    if (p.mode_chip) |full| {
        const full_w = ui.width(full);
        const icon = chip.modeIcon(ui.ascii);
        const icon_w = ui.width(icon);
        if (w >= label_w + sub_w + refresh_w + full_w + 4) {
            mode_text = full;
            mode_w = full_w;
        } else if (sub != null and w >= label_w + sub_w + refresh_w + icon_w + 4) {
            mode_text = icon;
            mode_w = icon_w;
            out.mode_is_icon = true;
        } else if (w >= label_w + refresh_w + full_w + 4) {
            mode_text = full;
            mode_w = full_w;
            sub = null;
            sub_w = 0;
        } else if (w >= label_w + refresh_w + icon_w + 4) {
            mode_text = icon;
            mode_w = icon_w;
            out.mode_is_icon = true;
            sub = null;
            sub_w = 0;
        }
    }

    const refresh_x = area.right() - refresh_w;
    // One cell of air between the two chips.
    const gap: u16 = if (p.show_refresh or p.new_chip) 1 else 0;
    const mode_x = refresh_x -| (mode_w + gap);
    const title_end = if (mode_text != null) mode_x else refresh_x;
    // // changed (sessions-card): the extra chips are laid before the
    // title is painted, so the subtitle can give way to them — the
    // count is nice, a chip is a button (the ladder's rule 2).
    var extra_total: u16 = 0;
    for (p.extra) |e| if (p.pane != null or e.kind != null) {
        extra_total += ui.width(e.text) + 1;
    };
    if (sub != null and extra_total > 0 and title_end < area.x + label_w + sub_w + 2 + extra_total) {
        sub = null;
        sub_w = 0;
    }

    var x = area.x + 1;
    x += ui.putStr(x, y, title_end -| x, p.label, label_style);
    if (sub) |s| {
        x += ui.putStr(x, y, title_end -| x, " ", subtitleStyle(t, p.bg));
        _ = ui.putStr(x, y, title_end -| x, s, subtitleStyle(t, p.bg));
    }

    if (mode_text) |mt| {
        out.mode = chip.paintTarget(ui, mode_x, y, mode_w, mt, chip.modeStyle(t), hit.chipTarget(p.panel, p.mode_kind, p.pane));
    }
    var cx = refresh_x;
    if (p.new_chip) {
        out.new = chip.paintTarget(ui, cx, y, new_w, new_text, chip.newStyle(t, p.bg.bg), hit.chipTarget(p.panel, .new, p.pane));
        cx += new_w;
    }
    if (p.show_refresh) {
        out.refresh = chip.paintTarget(ui, cx, y, refresh_w - @as(u16, if (p.new_chip) new_w else 0), refresh_text, chip.refreshStyle(t, p.bg.bg), hit.chipTarget(p.panel, .refresh, p.pane));
    }
    // The extra chips: right to left from the mode chip, one cell of
    // air between, each dropped whole once it would cross the title.
    {
        const title_w = label_w + sub_w + 2;
        var ex = title_end;
        for (p.extra) |e| {
            const target: hit.HitTarget = if (p.pane) |pane_id|
                .{ .script_hit = .{ .pane = pane_id, .id = e.id } }
            else if (e.kind) |k|
                .{ .chip = .{ .panel = p.panel, .kind = k } }
            else
                continue;
            const ew = ui.width(e.text);
            if (ex < area.x + title_w + ew + 1) break;
            ex -= ew + 1;
            _ = chip.paintTarget(ui, ex, y, ew, e.text, e.style orelse chip.modeStyle(t), target);
        }
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

test "a wide subtitle gives way to the chip: the count goes before the sort control does" {
    // FINDINGS (8) + " (3 open of 12)" (15) + refresh 3 + icon 3 + 4 = 33.
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    var p = props(&f, " (3 open of 12)", full_chip);
    p.label = "FINDINGS";
    const l = draw(f.ui(), f.full(), p);
    try testing.expect(l.mode != null);
    try testing.expect(l.mode_is_icon);
    try f.expectLacks("open of");
    try testing.expectEqual(ChipKind.sort, f.hits.at(30 - 6, 0).?.chip.kind);
    // At the shipped default width the count and the icon share the row.
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const m = draw(g.ui(), g.full(), p);
    try testing.expect(m.mode_is_icon);
    try g.expectContains("(3 open of 12)");
    try g.expectLacks("sort:");
    // With room for both, both paint in full.
    var h = try Fixture.init(56, 1);
    defer h.deinit();
    const n = draw(h.ui(), h.full(), p);
    try testing.expect(!n.mode_is_icon);
    try h.expectContains("(3 open of 12)");
    try h.expectContains(" sort: Newest first ");
    // A count too wide for even the icon rung goes, and the full chip
    // takes the room: TODOS (5) + 19 + 3 + 3 + 4 = 34 > 33 ≥ 5 + 3 + 20 + 4.
    var i = try Fixture.init(33, 1);
    defer i.deinit();
    const q = props(&i, " (120 open of 3400)", full_chip);
    const o = draw(i.ui(), i.full(), q);
    try testing.expect(!o.mode_is_icon);
    try i.expectContains(" sort: Newest first ");
    try i.expectLacks("open of");
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

test "focus cue: a focused header's label lights, an unfocused or focus-less one keeps the dim role" {
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    var p = props(&f, null, null);
    // No focus of its own to show: the label as it always was.
    _ = draw(f.ui(), f.full(), p);
    try testing.expect(f.fgEql(1, 0, .{ .fg = f.theme.muted.fg }));
    p.focused = false;
    _ = draw(f.ui(), f.full(), p);
    try testing.expect(f.fgEql(1, 0, .{ .fg = f.theme.muted.fg }));
    // The keys are here: the accent under `both` (and `rail`)…
    p.focused = true;
    _ = draw(f.ui(), f.full(), p);
    try testing.expect(f.fgEql(1, 0, .{ .fg = f.theme.accent.fg }));
    try testing.expect(f.style(1, 0).bold);
    // …the full foreground under `dim`.
    var ui = f.ui();
    ui.focus_cue = .dim;
    _ = draw(ui, f.full(), p);
    try testing.expect(f.fgEql(1, 0, .{ .fg = f.theme.fg.fg }));
}
