//! The activity bar — the three-cell icon rail down the left edge of
//! the sidebar (Rust `ui/activity_bar.rs`): one glyph per section, the
//! active one marked with `▌` in the accent, the settings gear on the
//! second-to-last row. The rail is carved from the sidebar's own width
//! (a padding cell, the glyph, a padding cell), and a `│` border column
//! stands between it and the panel — `render.frameRects` hands both
//! rects out; this file paints the rail.
//!
//! Every glyph is the codepoint the Rust painter uses — ghostty maps
//! U+F1B00–U+F20FF to mnml's own baked font, and the rest to the Nerd
//! Font, so a lookalike from another family would render as a box.
//! Each has its `ui.ascii_icons` twin beside it (`zig build glyph-audit`).
//!
//! The rows: the sections start one row down and step by two when they
//! fit, by one when they do not (a short terminal gets a denser rail,
//! never a shorter one); the gear sits on `bottom - 2`; the sections stop
//! three rows above the bottom so they never run into it.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const Style = Ui.Style;

/// Padding, glyph, padding.
pub const width: u16 = 3;

/// The sections, top to bottom. `diagnostics` and `outline` are Rust's
/// right-panel panes: they have a side and a column like the rest
/// (`app/side.zig`) but no rail row — `rail` is what the bar paints.
/// // changed (section-side): the two hidden members.
pub const Section = enum(u8) {
    explorer,
    search,
    git,
    debug,
    integrations,
    sessions,
    agents,
    cloud_agents,
    http,
    notes,
    todos,
    findings,
    /// // changed (lua-track): what the scripts registered, with file:line.
    scripts,
    diagnostics,
    outline,

    pub const all = std.enums.values(Section);
    /// The rows the rail paints, in order.
    pub const rail = all[0..13];

    pub const Meta = struct {
        /// The Nerd Font glyph (Rust's codepoint).
        glyph: []const u8,
        /// Its one-character `ui.ascii_icons` twin.
        fallback: []const u8,
        /// The tooltip word and the menu title.
        label: []const u8,
    };

    pub fn meta(s: Section) Meta {
        return switch (s) {
            .explorer => .{ .glyph = "\u{f115}", .fallback = "E", .label = "Explorer" }, // nf-fa-folder_open
            .search => .{ .glyph = "\u{f0349}", .fallback = "S", .label = "Search" }, // nf-md-magnify
            .git => .{ .glyph = "\u{f02a2}", .fallback = "G", .label = "Source control" }, // nf-md-source_branch
            .debug => .{ .glyph = "\u{f188}", .fallback = "D", .label = "Run and debug" }, // nf-fa-bug
            .integrations => .{ .glyph = "\u{f0431}", .fallback = "I", .label = "Integrations" }, // nf-md-puzzle
            .sessions => .{ .glyph = "\u{f0392}", .fallback = "T", .label = "Sessions" }, // nf-md-tab
            .agents => .{ .glyph = "\u{f06a9}", .fallback = "A", .label = "Agents" }, // nf-md-robot
            .cloud_agents => .{ .glyph = "\u{f0163}", .fallback = "C", .label = "Cloud agents" }, // nf-md-cloud
            .http => .{ .glyph = "\u{f1d8}", .fallback = "H", .label = "HTTP" }, // nf-fa-paper_plane
            .notes => .{ .glyph = "\u{f249}", .fallback = "N", .label = "Notes" }, // nf-fa-sticky_note
            .todos => .{ .glyph = "\u{f046}", .fallback = "O", .label = "TODOs" }, // nf-fa-check_square
            .findings => .{ .glyph = "\u{f1623}", .fallback = "F", .label = "Findings" }, // nf-md-file_search
            .scripts => .{ .glyph = "\u{f08b1}", .fallback = "L", .label = "Scripts" }, // nf-md-language_lua
            .diagnostics => .{ .glyph = "\u{f071}", .fallback = "!", .label = "Diagnostics" }, // nf-fa-warning (never on the rail)
            .outline => .{ .glyph = "\u{f01bd}", .fallback = "=", .label = "Outline" }, // nf-md-file_tree (never on the rail)
        };
    }

    /// The key a host's `set-activity-badge` names this section by —
    /// Rust's `badge_key`, which `ipc/effects.known_sections` lists.
    pub fn badgeKey(s: Section) []const u8 {
        return @tagName(s);
    }
};

const gear_nerd = "\u{f013}"; //  nf-fa-cog
const gear_ascii = "*";
const indicator = "▌";
const indicator_ascii = ">";
const badge_one = "•";
const badge_one_ascii = "*";

/// What a rail cell means to a click (`HitTarget.rail`).
pub const Part = union(enum) {
    section: Section,
    gear,
};

pub const Props = struct {
    active: Section,
    /// A count per section, by `@intFromEnum`; zero paints nothing.
    badges: [Section.all.len]u32 = @splat(0),
    /// The pulse: this frame paints the counts over their glyphs.
    show_counts: bool = false,
    /// Rows Rust's rail spends after the sections (the pinned launcher
    /// slots, not painted here). The density rule counts them so a
    /// config that packs the Rust rail packs this one the same way.
    extra_items: usize = 0,
};

/// Where the sections and the gear land in `area` — shared by `draw`
/// and the tests, so a test can ask for a row without painting.
pub const Layout = struct {
    /// First section row; each section is `step` rows below the last.
    first_y: u16,
    step: u16,
    /// Sections at or below this row are not painted.
    end_y: u16,
    /// Null when the rail is too short for a gear.
    gear_y: ?u16,

    pub fn sectionY(l: Layout, s: Section) ?u16 {
        const y = l.first_y + l.step * @as(u16, @intFromEnum(s));
        return if (y < l.end_y) y else null;
    }
};

pub fn layout(area: Rect, extra_items: usize) Layout {
    const end_y = area.y + area.h -| 3;
    const first_y = area.y + 1;
    const avail: usize = end_y -| first_y;
    const items = Section.rail.len + extra_items;
    return .{
        .first_y = first_y,
        .step = if (items * 2 > avail) 1 else 2,
        .end_y = end_y,
        .gear_y = if (area.h >= 2) area.y + area.h - 2 else null,
    };
}

pub fn draw(ui: Ui, area: Rect, props: Props) void {
    if (area.isEmpty()) return;
    const th = ui.theme;
    const pal = th.palette;
    const bg = pal.bg_darker;
    const muted = dim(Theme.withFg(Theme.onBg(th.muted, bg), pal.comment));
    const lit = bold(Theme.withFg(Theme.onBg(th.fg, bg), pal.blue));
    const badge = bold(Theme.withFg(Theme.onBg(th.fg, bg), pal.orange));
    ui.fill(area, Theme.onBg(th.fg, bg));
    const glyph_x = area.x + 1;
    const glyph_w = area.w -| 1;
    const lay = layout(area, props.extra_items);
    if (lay.gear_y) |gy| {
        const row = Rect.init(area.x, gy, area.w, 1);
        _ = ui.putStr(glyph_x, gy, glyph_w, if (ui.ascii) gear_ascii else gear_nerd, muted);
        ui.hit(row, .{ .rail = .gear });
    }
    for (Section.rail) |s| {
        const y = lay.sectionY(s) orelse break;
        const row = Rect.init(area.x, y, area.w, 1);
        const m = s.meta();
        const is_active = s == props.active;
        if (is_active) _ = ui.putStr(area.x, y, 1, if (ui.ascii) indicator_ascii else indicator, Theme.withFg(Theme.onBg(th.fg, bg), pal.blue));
        _ = ui.putStr(glyph_x, y, glyph_w, if (ui.ascii) m.fallback else m.glyph, if (is_active) lit else muted);
        // The badge pulses over the glyph (Rust): the strip is too
        // narrow for a superscript beside a glyph.
        const count = props.badges[@intFromEnum(s)];
        if (count > 0 and props.show_counts and area.w >= width) {
            const text = if (count == 1) (if (ui.ascii) badge_one_ascii else badge_one) else if (count <= 9) ui.fmt("{d}", .{count}) else "+";
            _ = ui.putStr(glyph_x, y, glyph_w, text, badge);
        }
        ui.hit(row, .{ .rail = .{ .section = s } });
    }
}

fn dim(s: Style) Style {
    var out = s;
    out.dim = true;
    return out;
}

fn bold(s: Style) Style {
    var out = s;
    out.bold = true;
    return out;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const test_fixture = @import("test_fixture.zig");

test "glyph table: twelve rail sections in Rust's order plus SCRIPTS (and the two hidden ones), each glyph one codepoint with a one-character ASCII twin and a label" {
    try t.expectEqual(@as(usize, 13), Section.rail.len);
    try t.expectEqual(@as(usize, 15), Section.all.len);
    try t.expectEqual(Section.explorer, Section.rail[0]);
    try t.expectEqual(Section.findings, Section.rail[11]);
    try t.expectEqual(Section.scripts, Section.rail[12]);
    try t.expectEqual(Section.outline, Section.all[14]);
    var seen_glyphs: [Section.all.len]u21 = undefined;
    for (Section.all, 0..) |s, i| {
        const m = s.meta();
        try t.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(m.glyph));
        try t.expectEqual(@as(usize, 1), m.fallback.len);
        try t.expect(m.label.len > 0);
        const cp = try std.unicode.utf8Decode(m.glyph);
        // The Nerd Font planes — never mnml's own U+F1B00–U+F20FF block,
        // which only holds what the Rust side bakes.
        try t.expect((cp >= 0xe000 and cp <= 0xf8ff) or (cp >= 0xf0000 and cp <= 0xf1aff));
        for (seen_glyphs[0..i]) |prev| try t.expect(prev != cp);
        seen_glyphs[i] = cp;
    }
    // The dump's codepoints (docs/ui-spec/rust-120x40.txt, rows 2–13).
    try t.expectEqual(@as(u21, 0xf115), try std.unicode.utf8Decode(Section.explorer.meta().glyph));
    try t.expectEqual(@as(u21, 0xf0349), try std.unicode.utf8Decode(Section.search.meta().glyph));
    try t.expectEqual(@as(u21, 0xf1623), try std.unicode.utf8Decode(Section.findings.meta().glyph));
    try t.expectEqual(@as(u21, 0xf013), try std.unicode.utf8Decode(gear_nerd));
}

test "layout: rows 1..37 of a 40-row screen — sections on 2..13 when six launcher slots pack the rail, on 2,4,..24 without them; the gear on row 36" {
    // The fixture: the rail spans rows 1..37 (the palette bar above, the
    // statusline and `:` line below) and the config pins six launchers.
    const dense = layout(Rect.init(0, 1, width, 37), 6);
    try t.expectEqual(@as(u16, 2), dense.sectionY(.explorer).?);
    try t.expectEqual(@as(u16, 13), dense.sectionY(.findings).?);
    try t.expectEqual(@as(u16, 36), dense.gear_y.?);
    const roomy = layout(Rect.init(0, 1, width, 37), 0);
    try t.expectEqual(@as(u16, 2), roomy.step);
    try t.expectEqual(@as(u16, 24), roomy.sectionY(.findings).?);
    // 80x24: rows 1..21 — the twelve sections need the dense step and
    // still all fit above the gear on row 20.
    const short = layout(Rect.init(0, 1, width, 21), 0);
    try t.expectEqual(@as(u16, 1), short.step);
    try t.expectEqual(@as(u16, 13), short.sectionY(.findings).?);
    try t.expectEqual(@as(u16, 20), short.gear_y.?);
    // Too short for everything: the last sections go, the gear stays.
    const tiny = layout(Rect.init(0, 1, width, 8), 0);
    try t.expect(tiny.sectionY(.findings) == null);
    try t.expectEqual(@as(u16, 7), tiny.gear_y.?);
    try t.expect(layout(Rect.init(0, 0, width, 1), 0).gear_y == null);
}

test "draw: the indicator sits beside the active glyph, every section and the gear register a hit, a badge paints its count only on the pulse" {
    var fx = try test_fixture.init(10, 40);
    defer fx.deinit();
    var props: Props = .{ .active = .git };
    props.badges[@intFromEnum(Section.todos)] = 3;
    props.badges[@intFromEnum(Section.notes)] = 1;
    const area = Rect.init(0, 1, width, 37);
    draw(fx.ui(), area, props);
    const lay = layout(area, 0);
    // Rows 2 and 6: explorer unmarked, git marked.
    try t.expectEqualStrings(" ", fx.cell(0, lay.sectionY(.explorer).?).char.grapheme);
    try t.expectEqualStrings(indicator, fx.cell(0, lay.sectionY(.git).?).char.grapheme);
    try t.expectEqualStrings(Section.git.meta().glyph, fx.cell(1, lay.sectionY(.git).?).char.grapheme);
    try t.expectEqualStrings(gear_nerd, fx.cell(1, lay.gear_y.?).char.grapheme);
    for (Section.rail) |s| {
        const y = lay.sectionY(s).?;
        try t.expectEqual(s, fx.hits.at(0, y).?.rail.section);
        try t.expectEqual(s, fx.hits.at(2, y).?.rail.section);
    }
    try t.expect(fx.hits.at(1, lay.gear_y.?).?.rail == .gear);
    try t.expect(fx.hits.at(0, 1) == null);
    try t.expect(fx.hits.at(3, lay.sectionY(.git).?) == null);
    // Off the pulse the glyph shows; on it the count.
    try t.expectEqualStrings(Section.todos.meta().glyph, fx.cell(1, lay.sectionY(.todos).?).char.grapheme);
    props.show_counts = true;
    fx.hits.reset();
    draw(fx.ui(), area, props);
    try t.expectEqualStrings("3", fx.cell(1, lay.sectionY(.todos).?).char.grapheme);
    try t.expectEqualStrings(badge_one, fx.cell(1, lay.sectionY(.notes).?).char.grapheme);
    try t.expectEqualStrings(Section.git.meta().glyph, fx.cell(1, lay.sectionY(.git).?).char.grapheme);
    // ASCII: the twins.
    fx.hits.reset();
    var ui = fx.ui();
    ui.ascii = true;
    draw(ui, area, .{ .active = .explorer });
    try t.expectEqualStrings(indicator_ascii, fx.cell(0, lay.sectionY(.explorer).?).char.grapheme);
    try t.expectEqualStrings("E", fx.cell(1, lay.sectionY(.explorer).?).char.grapheme);
    try t.expectEqualStrings(gear_ascii, fx.cell(1, lay.gear_y.?).char.grapheme);
}
