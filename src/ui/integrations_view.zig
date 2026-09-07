//! `Pane.integrations` — the installed list — and the palette-bar chip
//! strip. A row is ` <glyph> <label>  <id>  <version>  <category>` with a
//! trailing `disabled` / `binary missing` note; the selected row can
//! unfold a detail block (description, binary, mode, manifest path, the
//! commands with their keys, the settings, what it requires). Every row
//! registers `.script_hit{ pane, id = row }`; the chips register
//! `.button = chip_base + i`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const ids = @import("../core/ids.zig");
const manifest = @import("../bridge/manifest.zig");

pub const PaneId = ids.PaneId;
const Style = vaxis.Style;
const Color = vaxis.Color;

/// `.button` ids of the palette-bar chips: `chip_base + index`. Kept
/// clear of `render.Button`'s small values and its `0x40`.. bases —
/// dispatch tests this range before the `Button` switch, so a base of
/// `0x10` swallowed `split_max` / `hidden_tabs` / `right_close`.
pub const chip_base: u32 = 0x0300;
pub const max_chips: u32 = 0x30;

pub const Detail = struct {
    description: []const u8,
    binary: []const u8,
    mode: []const u8,
    path: []const u8,
    commands: []const manifest.Command,
    settings: []const manifest.Setting,
    requires: []const []const u8,
};

pub const Row = struct {
    glyph: []const u8,
    fallback: []const u8,
    color: []const u8,
    label: []const u8,
    id: []const u8,
    version: []const u8,
    category: []const u8,
    enabled: bool,
    binary_found: bool,
    selected: bool,
    detail: ?Detail = null,
};

pub const Props = struct {
    rows: []const Row,
    scroll: *usize,
    focused: bool,
    /// The last scan's problems, painted under the list.
    problems: []const []const u8 = &.{},
    sort: []const u8 = "name",
};

/// A manifest colour name (`cyan`, `#d16d51`) as a theme colour; the
/// accent when it names nothing.
pub fn paletteColor(th: *const Theme, name: []const u8) Color {
    const p = &th.palette;
    if (name.len == 7 and name[0] == '#') {
        if (std.fmt.parseInt(u24, name[1..], 16)) |hex| return Theme.rgb(hex) else |_| {}
    }
    const Named = struct { n: []const u8, c: Color };
    const table = [_]Named{
        .{ .n = "red", .c = p.red },      .{ .n = "orange", .c = p.orange },   .{ .n = "yellow", .c = p.yellow },
        .{ .n = "green", .c = p.green },  .{ .n = "blue", .c = p.blue },       .{ .n = "cyan", .c = p.cyan },
        .{ .n = "teal", .c = p.teal },    .{ .n = "purple", .c = p.purple },   .{ .n = "pink", .c = p.pink },
        .{ .n = "magenta", .c = p.pink }, .{ .n = "comment", .c = p.comment }, .{ .n = "grey", .c = p.grey },
        .{ .n = "fg", .c = p.fg },        .{ .n = "white", .c = p.fg },
    };
    for (table) |t| if (std.ascii.eqlIgnoreCase(t.n, name)) return t.c;
    return th.accent.fg;
}

/// One chip of the strip, as the app hands it over.
pub const ChipProps = struct {
    glyph: []const u8,
    fallback: []const u8,
    color: []const u8,
    enabled: bool,
};

/// Paints the chips right-to-left ending at `right_x` on row `y`, each
/// ` <glyph> ` with its colour (dim when disabled), and returns the x
/// the strip starts at. A chip that would not fit is dropped whole.
pub fn drawChips(ui: Ui, right_x: u16, y: u16, min_x: u16, bg: Style, chips: []const ChipProps) u16 {
    const th = ui.theme;
    var x = right_x;
    var i = chips.len;
    while (i > 0) {
        i -= 1;
        const c = chips[i];
        const glyph = if (ui.nerd_font and !ui.ascii and c.glyph.len > 0) c.glyph else if (c.fallback.len > 0) c.fallback else c.glyph;
        if (glyph.len == 0) continue;
        const w = ui.width(glyph) + 2;
        if (x < min_x + w) break;
        x -= w;
        var style = Theme.onBg(th.fg, bg.bg);
        style.fg = paletteColor(th, c.color);
        if (!c.enabled) style.dim = true;
        const r = Rect.init(x, y, w, 1);
        ui.fill(r, bg);
        _ = ui.putStr(x + 1, y, w - 2, glyph, style);
        ui.hit(r, .{ .button = chip_base + @as(u32, @intCast(i)) });
    }
    return x;
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: Props) void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    const head = area.row(0);
    ui.fill(head, th.panel_bg);
    const title = ui.fmt("INTEGRATIONS ({d} installed) · sort: {s}", .{ p.rows.len, p.sort });
    _ = ui.putStr(head.x + 1, head.y, head.w -| 2, ui.clipStr(title, head.w -| 2), Theme.onBg(th.muted, th.panel_bg.bg));
    const hint: []const u8 = "enter open · d details · e enable · m manifest · y copy id · x remove · r refresh · s sort · M marketplace";
    if (area.h >= 2) {
        const hr = area.row(1);
        _ = ui.putStr(hr.x + 1, hr.y, hr.w -| 2, ui.clipStr(hint, hr.w -| 2), th.muted);
    }
    var body = area;
    body.y += 2;
    body.h -|= 2;
    if (p.rows.len == 0) {
        _ = ui.putStr(body.x + 1, body.y, body.w -| 2, "No integrations installed. Run `<integration> --install`, or open the marketplace (M).", th.muted);
        drawProblems(ui, body, 2, p.problems);
        return;
    }
    // The selected row must be visible; a detail block takes rows too.
    var cursor: usize = 0;
    for (p.rows, 0..) |r, i| if (r.selected) {
        cursor = i;
    };
    const win = list_panel.scrollWindow(p.scroll, cursor, p.rows.len, @max(body.h, 1));
    var y: u16 = 0;
    var i: usize = win.first;
    while (i < p.rows.len and y < body.h) : (i += 1) {
        const r = p.rows[i];
        const rr = body.row(y);
        const style = list_panel.rowStyle(th, r.selected);
        ui.fill(rr, style);
        ui.hit(rr, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
        var x = rr.x + 1;
        if (r.selected) {
            const marker = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
            _ = ui.putStr(rr.x, rr.y, 1, marker, Theme.withFg(style, if (p.focused) th.accent.fg else th.muted.fg));
        }
        const glyph = if (ui.nerd_font and !ui.ascii and r.glyph.len > 0) r.glyph else r.fallback;
        var gstyle = style;
        gstyle.fg = paletteColor(th, r.color);
        if (!r.enabled) gstyle.dim = true;
        if (glyph.len > 0) {
            x += ui.putStr(x, rr.y, 2, glyph, gstyle);
            x += 1;
        }
        var lstyle = style;
        if (!r.enabled) lstyle.dim = true;
        x += ui.putStr(x, rr.y, rr.right() -| x, r.label, Theme.withFg(lstyle, if (r.enabled) th.fg.fg else th.muted.fg));
        x += 2;
        const meta = ui.fmt("{s}{s}{s}{s}{s}", .{ r.id, if (r.version.len > 0) "  v" else "", r.version, if (r.category.len > 0) "  " else "", r.category });
        x += ui.putStr(x, rr.y, rr.right() -| x, ui.clipStr(meta, rr.right() -| x), Theme.withFg(style, th.muted.fg));
        const note: ?[]const u8 = if (!r.binary_found) "binary missing" else if (!r.enabled) "disabled" else null;
        if (note) |n| {
            const nw = ui.width(n);
            if (rr.right() > x + nw + 2) _ = ui.putStrRight(rr.right() - 1, rr.y, nw, n, Theme.withFg(style, th.warn_fg.fg));
        }
        y += 1;
        if (r.detail) |d| y += drawDetail(ui, body, y, d);
    }
    drawProblems(ui, body, y + 1, p.problems);
}

fn drawDetail(ui: Ui, body: Rect, start: u16, d: Detail) u16 {
    const th = ui.theme;
    var y = start;
    const indent: u16 = 4;
    const Line = struct { k: []const u8, v: []const u8 };
    const lines = [_]Line{
        .{ .k = "description", .v = d.description },
        .{ .k = "binary", .v = d.binary },
        .{ .k = "mode", .v = d.mode },
        .{ .k = "manifest", .v = d.path },
    };
    for (lines) |l| {
        if (y >= body.h) return y - start;
        if (l.v.len == 0) continue;
        const rr = body.row(y);
        var x = rr.x + indent;
        x += ui.putStr(x, rr.y, rr.right() -| x, l.k, th.muted);
        x += ui.putStr(x, rr.y, rr.right() -| x, ": ", th.muted);
        _ = ui.putStr(x, rr.y, rr.right() -| x, ui.clipStr(l.v, rr.right() -| x), th.fg);
        y += 1;
    }
    for (d.commands) |c| {
        if (y >= body.h) return y - start;
        const rr = body.row(y);
        var x = rr.x + indent;
        x += ui.putStr(x, rr.y, rr.right() -| x, c.id, th.accent);
        x += ui.putStr(x, rr.y, rr.right() -| x, "  ", th.fg);
        x += ui.putStr(x, rr.y, rr.right() -| x, ui.clipStr(c.title, rr.right() -| x), th.fg);
        for (c.keys) |k| {
            x += ui.putStr(x, rr.y, rr.right() -| x, "  ", th.fg);
            x += ui.putStr(x, rr.y, rr.right() -| x, k, th.muted);
        }
        if (c.ex) |ex| {
            x += ui.putStr(x, rr.y, rr.right() -| x, "  :", th.muted);
            _ = ui.putStr(x, rr.y, rr.right() -| x, ui.clipStr(ex, rr.right() -| x), th.muted);
        }
        y += 1;
    }
    for (d.settings) |s| {
        if (y >= body.h) return y - start;
        const rr = body.row(y);
        var x = rr.x + indent;
        x += ui.putStr(x, rr.y, rr.right() -| x, "setting ", th.muted);
        x += ui.putStr(x, rr.y, rr.right() -| x, s.key, th.fg);
        x += ui.putStr(x, rr.y, rr.right() -| x, ": ", th.muted);
        for (s.options, 0..) |o, i| {
            if (i > 0) x += ui.putStr(x, rr.y, rr.right() -| x, " / ", th.muted);
            x += ui.putStr(x, rr.y, rr.right() -| x, o, if (std.mem.eql(u8, o, s.default)) th.accent else th.fg);
        }
        y += 1;
    }
    if (d.requires.len > 0 and y < body.h) {
        const rr = body.row(y);
        var x = rr.x + indent;
        x += ui.putStr(x, rr.y, rr.right() -| x, "requires ", th.muted);
        for (d.requires, 0..) |r, i| {
            if (i > 0) x += ui.putStr(x, rr.y, rr.right() -| x, ", ", th.muted);
            x += ui.putStr(x, rr.y, rr.right() -| x, r, th.fg);
        }
        y += 1;
    }
    return y - start;
}

fn drawProblems(ui: Ui, body: Rect, start: u16, problems: []const []const u8) void {
    var y = start;
    for (problems) |p| {
        if (y >= body.h) return;
        const rr = body.row(y);
        _ = ui.putStr(rr.x + 1, rr.y, rr.w -| 2, ui.clipStr(ui.fmt("! {s}", .{p}), rr.w -| 2), ui.theme.warn_fg);
        y += 1;
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "rows paint with their notes and register hits; the detail block lists the commands" {
    var f = try Fixture.init(70, 14);
    defer f.deinit();
    var scroll: usize = 0;
    const cmds = [_]manifest.Command{.{ .id = "jira.open", .title = "Jira: open", .keys = &.{"ctrl+k j"} }};
    const rows = [_]Row{
        .{ .glyph = "J", .fallback = "J", .color = "blue", .label = "Jira", .id = "jira", .version = "1.0", .category = "tracker", .enabled = true, .binary_found = true, .selected = true, .detail = .{ .description = "Tickets", .binary = "mnml-jira", .mode = "mount", .path = "x/jira.zon", .commands = &cmds, .settings = &.{}, .requires = &.{"JIRA_TOKEN"} } },
        .{ .glyph = "S", .fallback = "S", .color = "green", .label = "Slack", .id = "slack", .version = "", .category = "", .enabled = false, .binary_found = false, .selected = false },
    };
    draw(f.ui(), 3, f.full(), .{ .rows = &rows, .scroll = &scroll, .focused = true, .problems = &.{"bad.zon: nope"} });
    try f.expectContains("INTEGRATIONS (2 installed)");
    try f.expectContains("Jira  jira  v1.0  tracker");
    try f.expectContains("description: Tickets");
    try f.expectContains("jira.open  Jira: open  ctrl+k j");
    try f.expectContains("requires JIRA_TOKEN");
    try f.expectContains("binary missing");
    try f.expectContains("! bad.zon: nope");
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 2).?.script_hit.id);
    try testing.expectEqual(@as(u32, 3), f.hits.at(5, 2).?.script_hit.pane);
}

test "chips paint right-to-left with their hits and drop what does not fit" {
    var f = try Fixture.init(20, 1);
    defer f.deinit();
    const chips = [_]ChipProps{
        .{ .glyph = "A", .fallback = "A", .color = "red", .enabled = true },
        .{ .glyph = "B", .fallback = "B", .color = "#00ff00", .enabled = false },
        .{ .glyph = "C", .fallback = "C", .color = "nope", .enabled = true },
    };
    const x = drawChips(f.ui(), 20, 0, 0, .{}, &chips);
    try testing.expectEqual(@as(u16, 11), x);
    try f.expectRow(0, "            A  B  C");
    try testing.expectEqual(chip_base + 2, f.hits.at(18, 0).?.button);
    try testing.expectEqual(chip_base + 0, f.hits.at(12, 0).?.button);
    try testing.expect(f.style(15, 0).dim);
    try testing.expectEqual(Color{ .rgb = .{ 0, 255, 0 } }, f.style(15, 0).fg);
    // Only one fits between min_x and the right edge.
    var g = try Fixture.init(20, 1);
    defer g.deinit();
    const x2 = drawChips(g.ui(), 20, 0, 16, .{}, &chips);
    try testing.expectEqual(@as(u16, 17), x2);
    try g.expectRow(0, "                  C");
}
