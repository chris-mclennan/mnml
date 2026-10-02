//! Filter input — the pill on a list panel's second row: a search glyph,
//! then the filter text or its placeholder. Unfocused it reads
//! `/ filter` (the `/` is the key that focuses it); focused and empty it
//! says `type to filter…`. One shape for every panel so the eye finds
//! the filter in the same place with the same words.
//!
//! The whole pill registers a `.filter_input(panel)` hit in the same
//! statement as its paint; the text itself is a `text_field`, so the
//! caret, arrows, paste and word deletes come for free — and a click,
//! a double-click and a triple, through the field it registers.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_field = @import("text_field.zig");
const hit = @import("hit.zig");

const Style = vaxis.Style;

pub const PanelId = hit.PanelId;
pub const Caret = text_field.Caret;

/// nf-md-magnify.
pub const glyph_nerd = "\u{F0349}";
pub const glyph_ascii = "/";

/// The word the placeholder names. Every list panel filters, so
/// `filter` is the default; SEARCH runs a grep, so its pill says
/// `search` in the same widget rather than lying about what Enter does.
pub const default_noun = "filter";

pub fn glyph(ui: Ui) []const u8 {
    return if (ui.ascii or !ui.nerd_font) glyph_ascii else glyph_nerd;
}

/// `/ <noun>` unfocused — the `/` is the key that focuses the pill —
/// and `type to <noun>…` focused and empty. On the frame arena.
pub fn placeholder(ui: Ui, focused: bool, noun: []const u8) []const u8 {
    if (!focused) return ui.fmt("/ {s}", .{noun});
    return ui.fmt("type to {s}{s}", .{ noun, ui.ellipsisText() });
}

pub const Props = struct {
    panel: PanelId,
    text: []const u8,
    caret: usize,
    /// The text's selection (`text_field.selRange`), painted in the
    /// theme's selection.
    anchor: ?usize = null,
    focused: bool,
    /// The panel's ground, painted at the pill's edges.
    bg: Style,
    /// // changed (sessions-merge): hosted by a pane, the pill's hit is
    /// the pane's `.script_hit` with `hit.ListHit.filter_id`.
    pane: ?hit.PaneId = null,
    /// // changed (panel-consistency): what the placeholder calls the
    /// thing being typed — `filter` everywhere but SEARCH.
    noun: []const u8 = default_noun,
};

/// Paints the pill across `area` (one row, one cell of ground on each
/// side) and returns the caret cell when focused.
pub fn draw(ui: Ui, area: Rect, p: Props) ?Caret {
    ui.fill(area, p.bg);
    if (area.isEmpty() or area.w < 4) return null;
    const t = ui.theme;
    const pill = Rect.init(area.x + 1, area.y, area.w - 2, 1);
    const style = if (p.focused) Theme.withFg(t.chip, t.fg.fg) else t.chip;
    ui.fill(pill, style);
    var x = pill.x;
    x += ui.putStr(x, pill.y, pill.w, " ", style);
    x += ui.putStr(x, pill.y, pill.right() - x, glyph(ui), Theme.withFg(style, t.accent.fg));
    x += ui.putStr(x, pill.y, pill.right() - x, " ", style);
    const field = Rect.init(x, pill.y, (pill.right() - 1) -| x, 1);
    if (p.pane) |id| ui.hit(pill, .{ .script_hit = .{ .pane = id, .id = hit.ListHit.filter_id } }) else ui.hit(pill, .{ .filter_input = p.panel });
    return text_field.draw(ui, field, p.text, p.caret, .{
        .style = style,
        .placeholder = placeholder(ui, p.focused, p.noun),
        .focused = p.focused,
        .anchor = p.anchor,
        // A press on the text: caret, word, the whole filter
        // (`dispatch.fieldPress`), read off the owner of the pill.
        .field = if (p.pane) |id| .{ .pane_filter = id } else .{ .panel_filter = p.panel },
    });
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "unfocused pill shows the glyph and `/ filter`; focused shows the caret" {
    var f = try Fixture.init(22, 1);
    defer f.deinit();
    const ui = f.ui();
    var c = draw(ui, f.full(), .{ .panel = .notes, .text = "", .caret = 0, .focused = false, .bg = f.theme.panel_bg });
    try testing.expect(c == null);
    try f.expectRow(0, "  \u{F0349} / filter");
    try testing.expect(f.bgEql(0, 0, f.theme.panel_bg));
    try testing.expect(f.bgEql(1, 0, f.theme.chip));
    try testing.expect(f.bgEql(20, 0, f.theme.chip));
    try testing.expect(f.bgEql(21, 0, f.theme.panel_bg));
    try testing.expectEqual(PanelId.notes, f.hits.at(5, 0).?.filter_input);
    try testing.expect(f.hits.at(0, 0) == null);
    try testing.expect(f.hits.at(21, 0) == null);

    c = draw(ui, f.full(), .{ .panel = .notes, .text = "", .caret = 0, .focused = true, .bg = f.theme.panel_bg });
    try f.expectRow(0, "  \u{F0349} type to filter…");
    try testing.expectEqual(Caret{ .x = 4, .y = 0 }, c.?);
    c = draw(ui, f.full(), .{ .panel = .notes, .text = "bug", .caret = 3, .focused = true, .bg = f.theme.panel_bg });
    try f.expectRow(0, "  \u{F0349} bug");
    try testing.expectEqual(Caret{ .x = 7, .y = 0 }, c.?);
    try testing.expect(f.fgEql(5, 0, f.theme.fg));
}

test "ascii pill and a pill too narrow to hold anything" {
    var f = try Fixture.init(24, 1);
    defer f.deinit();
    var ui = f.ui();
    ui.ascii = true;
    _ = draw(ui, f.full(), .{ .panel = .todos, .text = "", .caret = 0, .focused = true, .bg = f.theme.panel_bg });
    try f.expectRow(0, "  / type to filter...");
    ui.ascii = false;
    ui.nerd_font = false;
    _ = draw(ui, f.full(), .{ .panel = .todos, .text = "", .caret = 0, .focused = false, .bg = f.theme.panel_bg });
    try f.expectRow(0, "  / / filter");
    var g = try Fixture.init(3, 1);
    defer g.deinit();
    try testing.expect(draw(g.ui(), g.full(), .{ .panel = .todos, .text = "x", .caret = 1, .focused = true, .bg = g.theme.panel_bg }) == null);
    try testing.expectEqual(@as(usize, 0), g.hits.items.items.len);
}
