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
//! three rows above the bottom so they never run into it. The pinned
//! launcher icons (`ui.activity_bar_pinned_integrations`, Rust's
//! `LauncherIcon` rows) follow the sections on the same step, each an
//! integration chip's glyph in the chip's colour; a click fires the
//! chip's command and a right click opens the chip's menu.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const paletteColor = @import("integrations_view.zig").paletteColor;
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
    http,
    notes,
    todos,
    findings,
    /// // changed (lua-track): what the scripts registered, with file:line.
    scripts,
    /// // changed (lua-plumbing): a section a script registered
    /// (`mnml.section{}`) — one rail row per registered section, in the
    /// position its `after` names. The row is never painted when no
    /// script has registered one, so the stock rail is unchanged.
    script,
    diagnostics,
    outline,

    pub const all = std.enums.values(Section);
    /// The rows the rail paints, in order.
    /// // changed (sessions-merge): the AGENTS and CLOUD AGENTS rows are
    /// gone — the sessions table (`sessions.table`) and the cloud rows
    /// live in SESSIONS.
    pub const rail = all[0..11];

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
            .http => .{ .glyph = "\u{f1d8}", .fallback = "H", .label = "HTTP" }, // nf-fa-paper_plane
            .notes => .{ .glyph = "\u{f249}", .fallback = "N", .label = "Notes" }, // nf-fa-sticky_note
            .todos => .{ .glyph = "\u{f046}", .fallback = "O", .label = "TODOs" }, // nf-fa-check_square
            .findings => .{ .glyph = "\u{f1623}", .fallback = "F", .label = "Findings" }, // nf-md-file_search
            .scripts => .{ .glyph = "\u{f08b1}", .fallback = "L", .label = "Scripts" }, // nf-md-language_lua
            .script => .{ .glyph = "\u{f0331}", .fallback = "P", .label = "Script section" }, // nf-md-library (a script's own glyph overrides it)
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
    /// The `i`-th pinned launcher icon, in `Props.pins` order.
    pin: u16,
    /// // changed (lua-plumbing): the `i`-th registered script section,
    /// in `Props.scripts` order.
    script: u16,
};

/// A script section's rail row: its own glyph and ASCII twin, and the
/// built-in section it sits after (empty = last).
pub const ScriptRow = struct {
    glyph: []const u8,
    fallback: []const u8,
    label: []const u8,
    after: []const u8 = "",
};

/// One row of the rail, in paint order.
pub const RailRow = union(enum) { section: Section, script: u16 };

/// The rail's rows: the built-ins in their order, with each script
/// section spliced in after the one its `after` names (or at the end).
/// Frame arena.
pub fn railOrder(arena: std.mem.Allocator, scripts: []const ScriptRow) std.mem.Allocator.Error![]const RailRow {
    var out: std.ArrayListUnmanaged(RailRow) = .empty;
    for (Section.rail) |sec| {
        try out.append(arena, .{ .section = sec });
        for (scripts, 0..) |sr, i| {
            if (sr.after.len > 0 and std.mem.eql(u8, sr.after, @tagName(sec))) try out.append(arena, .{ .script = @intCast(i) });
        }
    }
    for (scripts, 0..) |sr, i| {
        if (sr.after.len == 0 or !nameIsSection(sr.after)) try out.append(arena, .{ .script = @intCast(i) });
    }
    return out.items;
}

fn nameIsSection(name: []const u8) bool {
    for (Section.rail) |sec| if (std.mem.eql(u8, @tagName(sec), name)) return true;
    return false;
}

/// A pinned launcher icon: an integration chip's glyph, its ASCII twin
/// and its colour name (`paletteColor`).
pub const Pin = struct {
    glyph: []const u8,
    fallback: []const u8,
    color: []const u8 = "",
};

pub const Props = struct {
    active: Section,
    /// Which script section is lit when `active` is `.script`.
    active_script: u16 = 0,
    /// The registered script sections, in registration order. Empty
    /// leaves the rail exactly as it was before scripts could add one.
    scripts: []const ScriptRow = &.{},
    /// The rows in paint order (`railOrder`); empty means `Section.rail`
    /// less the `script` slot.
    rows: []const RailRow = &.{},
    /// A count per section, by `@intFromEnum`; zero paints nothing.
    badges: [Section.all.len]u32 = @splat(0),
    /// The pulse: this frame paints the counts over their glyphs.
    show_counts: bool = false,
    /// The pinned launcher icons, painted after the sections; the
    /// density rule counts them, so a config that packs the Rust rail
    /// packs this one the same way.
    pins: []const Pin = &.{},
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

    pub fn ordinalY(l: Layout, i: usize) ?u16 {
        const y = l.first_y + l.step * @as(u16, @intCast(i));
        return if (y < l.end_y) y else null;
    }

    /// The row a built-in section lands on when no script section has
    /// been spliced in — what the tests and the hit map ask for.
    pub fn sectionY(l: Layout, s: Section) ?u16 {
        return l.ordinalY(@intFromEnum(s));
    }

    /// The `i`-th pinned icon's row: after the last section, on the same
    /// step. `sections` is how many section rows the rail painted (the
    /// built-ins, plus any script section spliced in).
    pub fn pinY(l: Layout, i: usize) ?u16 {
        return l.pinYAfter(Section.rail.len, i);
    }

    pub fn pinYAfter(l: Layout, sections: usize, i: usize) ?u16 {
        const y = l.first_y + l.step * @as(u16, @intCast(sections + i));
        return if (y < l.end_y) y else null;
    }
};

pub fn layout(area: Rect, extra_items: usize) Layout {
    const end_y = area.y + area.h -| 3;
    const first_y = area.y + 1;
    const avail: usize = end_y -| first_y;
    // A registered script section arrives through `extra_items`, like a
    // pinned launcher: `Section.rail` is the built-in rows alone.
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
    const lay = layout(area, props.pins.len + props.scripts.len);
    if (lay.gear_y) |gy| {
        const row = Rect.init(area.x, gy, area.w, 1);
        _ = ui.putStr(glyph_x, gy, glyph_w, if (ui.ascii) gear_ascii else gear_nerd, muted);
        ui.hit(row, .{ .rail = .gear });
    }
    var default_rows: [Section.rail.len]RailRow = undefined;
    for (Section.rail, 0..) |sec, n| default_rows[n] = .{ .section = sec };
    const rows: []const RailRow = if (props.rows.len > 0) props.rows else &default_rows;
    for (rows, 0..) |rr, i| {
        const y = lay.ordinalY(i) orelse break;
        const row = Rect.init(area.x, y, area.w, 1);
        const is_active = switch (rr) {
            .section => |sec| sec == props.active,
            .script => |si| props.active == .script and si == props.active_script,
        };
        const glyph: []const u8 = switch (rr) {
            .section => |sec| if (ui.ascii) sec.meta().fallback else sec.meta().glyph,
            .script => |si| if (si < props.scripts.len) (if (ui.ascii) props.scripts[si].fallback else props.scripts[si].glyph) else "",
        };
        if (is_active) _ = ui.putStr(area.x, y, 1, if (ui.ascii) indicator_ascii else indicator, Theme.withFg(Theme.onBg(th.fg, bg), pal.blue));
        _ = ui.putStr(glyph_x, y, glyph_w, glyph, if (is_active) lit else muted);
        // The badge pulses over the glyph (Rust): the strip is too
        // narrow for a superscript beside a glyph.
        const count: u32 = switch (rr) {
            .section => |sec| props.badges[@intFromEnum(sec)],
            .script => 0,
        };
        if (count > 0 and props.show_counts and area.w >= width) {
            const text = if (count == 1) (if (ui.ascii) badge_one_ascii else badge_one) else if (count <= 9) ui.fmt("{d}", .{count}) else "+";
            _ = ui.putStr(glyph_x, y, glyph_w, text, badge);
        }
        ui.hit(row, .{ .rail = switch (rr) {
            .section => |sec| .{ .section = sec },
            .script => |si| .{ .script = si },
        } });
    }
    // The pinned launcher icons: the chip's glyph in the chip's colour,
    // at the rail's weight (dim, like an unmarked section).
    for (props.pins, 0..) |p, i| {
        const y = lay.pinYAfter(rows.len, i) orelse break;
        const row = Rect.init(area.x, y, area.w, 1);
        const glyph = if (ui.ascii or !ui.nerd_font or p.glyph.len == 0) p.fallback else p.glyph;
        if (glyph.len == 0) continue;
        _ = ui.putStr(glyph_x, y, glyph_w, glyph, dim(Theme.withFg(Theme.onBg(th.fg, bg), paletteColor(th, p.color))));
        ui.hit(row, .{ .rail = .{ .pin = @intCast(i) } });
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

test "glyph table: eleven rail sections in Rust's order less the two that folded into SESSIONS, plus SCRIPTS (and the two hidden ones), each glyph one codepoint with a one-character ASCII twin and a label" {
    try t.expectEqual(@as(usize, 11), Section.rail.len);
    try t.expectEqual(@as(usize, 14), Section.all.len);
    try t.expectEqual(Section.explorer, Section.rail[0]);
    try t.expectEqual(Section.findings, Section.rail[9]);
    try t.expectEqual(Section.scripts, Section.rail[10]);
    try t.expectEqual(Section.script, Section.all[11]);
    try t.expectEqual(Section.outline, Section.all[13]);
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

test "layout: rows 1..37 of a 40-row screen — eleven sections on 2..12 when six launcher slots pack the rail, on 2,4,..22 without them; the gear on row 36" {
    // The fixture: the rail spans rows 1..37 (the palette bar above, the
    // statusline and `:` line below) and the config pins six launchers.
    // // changed (sessions-merge): two sections fewer, one more from
    // lua-track (SCRIPTS): eleven, and six launchers still pack the rail.
    const dense = layout(Rect.init(0, 1, width, 37), 6);
    try t.expectEqual(@as(u16, 1), dense.step);
    try t.expectEqual(@as(u16, 2), dense.sectionY(.explorer).?);
    try t.expectEqual(@as(u16, 11), dense.sectionY(.findings).?);
    try t.expectEqual(@as(u16, 12), dense.sectionY(.scripts).?);
    try t.expectEqual(@as(u16, 36), dense.gear_y.?);
    const crowded = layout(Rect.init(0, 1, width, 37), 8);
    try t.expectEqual(@as(u16, 1), crowded.step);
    try t.expectEqual(@as(u16, 11), crowded.sectionY(.findings).?);
    const roomy = layout(Rect.init(0, 1, width, 37), 0);
    try t.expectEqual(@as(u16, 2), roomy.step);
    try t.expectEqual(@as(u16, 20), roomy.sectionY(.findings).?);
    try t.expectEqual(@as(u16, 22), roomy.sectionY(.scripts).?);
    // 80x24: rows 1..21 — the eleven sections need the dense step and
    // still all fit above the gear on row 20.
    const short = layout(Rect.init(0, 1, width, 21), 0);
    try t.expectEqual(@as(u16, 1), short.step);
    try t.expectEqual(@as(u16, 11), short.sectionY(.findings).?);
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

test "draw: the pinned icons follow the sections on the same step, each a hit, in the chip's colour; the density rule counts them; ASCII paints the twins" {
    var fx = try test_fixture.init(10, 40);
    defer fx.deinit();
    const pins = [_]Pin{
        .{ .glyph = "\u{F1D00}", .fallback = "H", .color = "green" },
        .{ .glyph = "\u{F0AEF}", .fallback = "B", .color = "red" },
    };
    const area = Rect.init(0, 1, width, 37);
    draw(fx.ui(), area, .{ .active = .explorer, .pins = &pins });
    const lay = layout(area, pins.len);
    try t.expectEqual(@as(u16, 2), lay.step);
    try t.expectEqual(@as(u16, 24), lay.pinY(0).?);
    try t.expectEqual(@as(u16, 26), lay.pinY(1).?);
    try t.expectEqualStrings("\u{F1D00}", fx.cell(1, 24).char.grapheme);
    try t.expectEqualStrings("\u{F0AEF}", fx.cell(1, 26).char.grapheme);
    try t.expectEqual(fx.theme.palette.green, fx.cell(1, 24).style.fg);
    try t.expectEqual(fx.theme.palette.red, fx.cell(1, 26).style.fg);
    try t.expectEqual(@as(u16, 0), fx.hits.at(0, 24).?.rail.pin);
    try t.expectEqual(@as(u16, 1), fx.hits.at(2, 26).?.rail.pin);
    try t.expect(fx.hits.at(1, 28) == null);
    try t.expect(fx.hits.at(1, lay.gear_y.?).?.rail == .gear);
    // Six pins pack the rail: sections one row apart, pins right after.
    var six: [6]Pin = undefined;
    for (&six) |*p| p.* = pins[0];
    fx.hits.reset();
    draw(fx.ui(), area, .{ .active = .explorer, .pins = &six });
    const dense = layout(area, six.len);
    try t.expectEqual(@as(u16, 1), dense.step);
    try t.expectEqual(@as(u16, 13), dense.pinY(0).?);
    try t.expectEqual(@as(u16, 18), dense.pinY(5).?);
    try t.expectEqual(@as(u16, 5), fx.hits.at(1, 18).?.rail.pin);
    // ASCII: the twins.
    fx.hits.reset();
    var ui = fx.ui();
    ui.ascii = true;
    draw(ui, area, .{ .active = .explorer, .pins = &pins });
    try t.expectEqualStrings("H", fx.cell(1, 24).char.grapheme);
    try t.expectEqualStrings("B", fx.cell(1, 26).char.grapheme);
    // A short rail drops the pins before the gear.
    var short = try test_fixture.init(10, 14);
    defer short.deinit();
    draw(short.ui(), Rect.init(0, 1, width, 11), .{ .active = .explorer, .pins = &pins });
    try t.expect(layout(Rect.init(0, 1, width, 11), pins.len).pinY(0) == null);
    try t.expect(short.hits.at(1, 10).?.rail == .gear);
}
