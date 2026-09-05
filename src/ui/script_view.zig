//! The script pane's painter (D10.3). A script's `render(w, h)` answers
//! with rows of segments; this paints them row by row inside the pane's
//! rect and registers a `.script_hit{ pane, id }` for every segment that
//! carries a `hit` — the same statement as the paint, so a clickable
//! segment cannot be painted without being clickable.
//!
//! Scripts never see a colour. A segment names a theme *role* (`fg =
//! "accent"`, `"muted"`, `"syn_keyword"`) and `roleStyle` resolves it
//! against the theme the app is painting with; an unknown role paints as
//! plain text rather than failing the frame.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");

const Style = vaxis.Style;
pub const PaneId = ids.PaneId;

/// One run of text on a row. `text` lives on the frame arena.
pub const Segment = struct {
    text: []const u8,
    style: Style,
    /// Registered as `.script_hit{ pane, id }` when set.
    hit: ?u32 = null,
};

/// The roles a script may name. The `syn_*` ones are the syntax slots;
/// the rest are the chrome roles the components paint with.
pub const Role = enum {
    fg,
    muted,
    accent,
    @"error",
    warn,
    info,
    border,
    gutter,
    selection,
    match,
    cursor_line,
    chip,
    chip_active,
    title,
    syn_comment,
    syn_string,
    syn_keyword,
    syn_function,
    syn_type,
    syn_number,
    syn_constant,
    syn_operator,
    syn_punctuation,
    syn_property,
    syn_variable,
    syn_escape,
};

/// The style a role paints with, on the editor ground.
pub fn styleOf(t: *const Theme, role: Role) Style {
    return switch (role) {
        .fg => t.fg,
        .muted => t.muted,
        .accent => t.accent,
        .@"error" => t.error_fg,
        .warn => t.warn_fg,
        .info => t.info_fg,
        .border => t.border,
        .gutter => t.gutter,
        .selection => t.selection,
        .match => t.match,
        .cursor_line => t.cursor_line,
        .chip => t.chip,
        .chip_active => t.chip_active,
        .title => t.overlay_title,
        .syn_comment => t.syntax.comment,
        .syn_string => t.syntax.string,
        .syn_keyword => t.syntax.keyword,
        .syn_function => t.syntax.function,
        .syn_type => t.syntax.type,
        .syn_number => t.syntax.number,
        .syn_constant => t.syntax.constant,
        .syn_operator => t.syntax.operator,
        .syn_punctuation => t.syntax.punctuation,
        .syn_property => t.syntax.property,
        .syn_variable => t.syntax.variable,
        .syn_escape => t.syntax.escape,
    };
}

/// `"accent"` → the accent style; null for a name that is not a role.
pub fn roleStyle(t: *const Theme, name: []const u8) ?Style {
    const role = std.meta.stringToEnum(Role, name) orelse return null;
    return styleOf(t, role);
}

/// What a script's segment table asks for, before the theme resolves it.
pub const StyleSpec = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

/// Resolve a spec against the theme: the `fg` role's foreground, the `bg`
/// role's colour as a ground (its own background when it has one, its
/// foreground otherwise), and the attributes. Unknown roles fall back
/// to plain text on the editor ground.
pub fn resolve(t: *const Theme, spec: StyleSpec) Style {
    var s: Style = t.fg;
    if (spec.fg) |name| if (roleStyle(t, name)) |rs| {
        s = rs;
    };
    // Every segment sits on the editor ground unless a bg role says otherwise.
    s.bg = t.bg.bg;
    if (spec.bg) |name| if (roleStyle(t, name)) |rs| {
        s.bg = if (rs.bg != .default) rs.bg else rs.fg;
    };
    if (spec.bold) s.bold = true;
    if (spec.italic) s.italic = true;
    if (spec.underline) s.ul_style = .single;
    return s;
}

/// Paint `rows` inside `area`, top-left anchored, one row per line;
/// rows past the bottom and text past the right edge are clipped.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, rows: []const []const Segment) void {
    ui.fill(area, ui.theme.bg);
    if (area.isEmpty()) return;
    for (rows, 0..) |row, i| {
        if (i >= area.h) break;
        const y: u16 = area.y + @as(u16, @intCast(i));
        var x = area.x;
        for (row) |seg| {
            if (x >= area.right()) break;
            const w = ui.putStr(x, y, area.right() - x, seg.text, seg.style);
            if (seg.hit) |id| if (w > 0) ui.hit(Rect.init(x, y, w, 1), .{ .script_hit = .{ .pane = pane, .id = id } });
            x += w;
        }
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "roles resolve against the theme; unknown names paint plain" {
    const t = &Theme.default;
    try testing.expect(roleStyle(t, "accent") != null);
    try testing.expect(roleStyle(t, "syn_keyword") != null);
    try testing.expect(roleStyle(t, "magenta") == null);
    const bold = resolve(t, .{ .fg = "accent", .bold = true });
    try testing.expect(bold.bold);
    try testing.expect(std.meta.eql(bold.fg, t.accent.fg));
    const plain = resolve(t, .{ .fg = "nope" });
    try testing.expect(std.meta.eql(plain.fg, t.fg.fg));
    try testing.expect(std.meta.eql(plain.bg, t.bg.bg));
}

test "draw paints rows, clips, and registers hits with the paint" {
    var f = try Fixture.init(10, 2);
    defer f.deinit();
    const ui = f.ui();
    const t = ui.theme;
    const rows = [_][]const Segment{
        &.{ .{ .text = "ab", .style = t.fg, .hit = 7 }, .{ .text = "cdefghijkl", .style = t.muted } },
        &.{.{ .text = "x", .style = t.fg }},
        &.{.{ .text = "never", .style = t.fg }},
    };
    draw(ui, 3, f.full(), &rows);
    try f.expectRow(0, "abcdefghij");
    try f.expectRow(1, "x");
    const h = f.hits.at(1, 0).?.script_hit;
    try testing.expectEqual(@as(PaneId, 3), h.pane);
    try testing.expectEqual(@as(u32, 7), h.id);
    try testing.expect(f.hits.at(5, 0) == null);
}
