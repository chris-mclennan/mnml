//! The FONTS section at the top of the INTEGRATIONS column's
//! Marketplace tab — the Rust editor's rows (`src/ui/mod.rs`, #1202):
//!
//! ```text
//!   FONTS · latest Nerd Fonts 3.5.1
//!   A  JetBrainsMono Nerd Font  v3.5.1 ✓
//!   A  MnmlSymbols  auto-baked by mnml
//!   A  Symbols Nerd Font  v3.4.0                  ↑ Update
//! ```
//!
//! then one blank row before the marketplace entries. `A` is nf-fa-font
//! in cyan; the version is green with a tick when it is the latest,
//! yellow when behind, muted when nothing is known to compare; the
//! mnml-owned face says so instead. `↑ Update` is overpainted at the
//! row's right edge only when the family is behind AND the platform
//! knows an update command (`font_scan.updateCommand`), registered as
//! `.font_update = row` in the statement that paints it. The rows are
//! not list rows: no cursor, no hit but the chip.
//!
//! The section is the caller's to hide — it is not drawn while a filter
//! is typed or once the list is scrolled (`integrations.zig`), as Rust
//! hides it, so the virtual-list math never has to scroll it.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

/// nf-fa-font.
pub const font_glyph = "\u{F031}";
pub const font_ascii = "A";
pub const chip_glyph = "\u{2191} Update";
pub const chip_ascii = "^ Update";

pub const Row = struct {
    family: []const u8,
    /// Null: no Nerd Fonts lineage (MnmlSymbols).
    version: ?[]const u8,
    /// Behind the latest and the platform has an update command.
    updatable: bool = false,
};

pub const Props = struct {
    /// The latest release, when known.
    latest: ?[]const u8,
    rows: []const Row,
};

/// Rows the section takes in `avail` rows: the header, every row that
/// fits leaving one row free (Rust's `y + 1 < bottom`), one blank —
/// and 0 when not even the header and a row fit.
pub fn height(p: Props, avail: u16) u16 {
    if (p.rows.len == 0 or avail < 3) return 0;
    const fit: u16 = @intCast(@min(p.rows.len, avail - 2));
    return 1 + fit + 1;
}

/// Paints the section at the top of `area`; returns the rows used.
pub fn draw(ui: Ui, area: Rect, p: Props) u16 {
    const t = ui.theme;
    const used = height(p, area.h);
    if (used == 0) return 0;
    const bg = t.panel_bg;
    var hs = Theme.onBg(t.muted, bg.bg);
    hs.bold = true;
    const head = area.row(0);
    const label = if (p.latest) |v| ui.fmt("  FONTS \u{00B7} latest Nerd Fonts {s}", .{v}) else "  FONTS";
    _ = ui.putStr(head.x, head.y, head.w, ui.clipStr(label, head.w), hs);
    const glyph = if (ui.nerd_font and !ui.ascii) font_glyph else font_ascii;
    const tick: []const u8 = if (ui.ascii) "+" else "\u{2713}";
    const chip = if (ui.ascii) chip_ascii else chip_glyph;
    const chip_w = ui.width(chip);
    var y: u16 = 1;
    for (p.rows, 0..) |row, i| {
        if (y + 1 >= area.h) break;
        const r = area.row(y);
        var x = r.x;
        x += ui.putStr(x, r.y, r.right() -| x, "  ", bg);
        x += ui.putStr(x, r.y, r.right() -| x, glyph, Theme.onBg(Theme.withFg(bg, t.palette.cyan), bg.bg));
        x += ui.putStr(x, r.y, r.right() -| x, "  ", bg);
        x += ui.putStr(x, r.y, r.right() -| x, ui.clipStr(row.family, r.right() -| x), Theme.onBg(t.fg, bg.bg));
        const behind = if (row.version) |cur| (if (p.latest) |lat| !std.mem.eql(u8, cur, lat) else false) else false;
        const ver_label: []const u8 = if (row.version) |cur|
            (if (p.latest != null and !behind) ui.fmt("  v{s} {s}", .{ cur, tick }) else ui.fmt("  v{s}", .{cur}))
        else
            "  auto-baked by mnml";
        const ver_fg: vaxis.Color = if (row.version == null or p.latest == null) t.muted.fg else if (behind) t.palette.yellow else t.palette.green;
        x += ui.putStr(x, r.y, r.right() -| x, ui.clipStr(ver_label, r.right() -| x), Theme.onBg(Theme.withFg(bg, ver_fg), bg.bg));
        if (row.updatable and behind and r.w > chip_w + 1) {
            const chip_x = @max(r.right() - chip_w - 1, x + 2);
            if (chip_x + chip_w <= r.right()) {
                var cs = Theme.onBg(Theme.withFg(bg, t.palette.cyan), bg.bg);
                cs.bold = true;
                const cr = Rect.init(chip_x, r.y, chip_w, 1);
                _ = ui.putStr(chip_x, r.y, chip_w, chip, cs);
                ui.hit(cr, .{ .font_update = @intCast(i) });
            }
        }
        y += 1;
    }
    return used;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the section: header with the latest, a tick on a current family, yellow + the chip on one behind, the mnml face, one blank" {
    var f = try Fixture.init(46, 8);
    defer f.deinit();
    const rows = [_]Row{
        .{ .family = "JetBrainsMono Nerd Font", .version = "3.5.1" },
        .{ .family = "MnmlSymbols", .version = null },
        .{ .family = "Symbols Nerd Font", .version = "3.4.0", .updatable = true },
    };
    const used = draw(f.ui(), f.full(), .{ .latest = "3.5.1", .rows = &rows });
    try testing.expectEqual(@as(u16, 5), used);
    try f.expectRow(0, "  FONTS \u{00B7} latest Nerd Fonts 3.5.1");
    try f.expectRow(1, "  " ++ font_glyph ++ "  JetBrainsMono Nerd Font  v3.5.1 \u{2713}");
    try f.expectRow(2, "  " ++ font_glyph ++ "  MnmlSymbols  auto-baked by mnml");
    try f.expectRow(3, "  " ++ font_glyph ++ "  Symbols Nerd Font  v3.4.0       \u{2191} Update");
    try f.expectRow(4, "");
    try testing.expect(f.style(0, 0).bold);
    try testing.expectEqual(f.theme.palette.cyan, f.style(2, 1).fg);
    try testing.expectEqual(f.theme.palette.green, f.style(32, 1).fg);
    try testing.expectEqual(f.theme.palette.yellow, f.style(26, 3).fg);
    try testing.expectEqual(f.theme.muted.fg, f.style(18, 2).fg);
    // The chip is the only hit, on its own row.
    try testing.expectEqual(@as(u16, 2), f.hits.at(40, 3).?.font_update);
    try testing.expect(f.hits.at(40, 1) == null);
    try testing.expect(f.hits.at(5, 3) == null);
}

test "no latest: versions muted, no tick, no chip; the ascii twins; too little room draws nothing" {
    var f = try Fixture.init(44, 6);
    defer f.deinit();
    const rows = [_]Row{
        .{ .family = "Hack Nerd Font", .version = "3.4.0", .updatable = true },
    };
    const used = draw(f.ui(), f.full(), .{ .latest = null, .rows = &rows });
    try testing.expectEqual(@as(u16, 3), used);
    try f.expectRow(0, "  FONTS");
    try f.expectRow(1, "  " ++ font_glyph ++ "  Hack Nerd Font  v3.4.0");
    try testing.expectEqual(f.theme.muted.fg, f.style(24, 1).fg);
    try testing.expect(f.hits.at(40, 1) == null);
    var g = try Fixture.init(44, 6);
    defer g.deinit();
    g.ascii = true;
    const rows2 = [_]Row{.{ .family = "Hack Nerd Font", .version = "3.4.0", .updatable = true }};
    _ = draw(g.ui(), g.full(), .{ .latest = "3.5.1", .rows = &rows2 });
    try g.expectRow(1, "  A  Hack Nerd Font  v3.4.0        ^ Update");
    try testing.expectEqual(@as(u16, 0), g.hits.at(40, 1).?.font_update);
    // Two rows cannot hold the header and a row: nothing paints.
    var h = try Fixture.init(44, 2);
    defer h.deinit();
    try testing.expectEqual(@as(u16, 0), draw(h.ui(), h.full(), .{ .latest = "3.5.1", .rows = &rows2 }));
    try h.expectRow(0, "");
    // Rows past the room are dropped, the blank kept.
    try testing.expectEqual(@as(u16, 4), height(.{ .latest = null, .rows = &(rows ++ rows2 ++ rows2) }, 4));
}
