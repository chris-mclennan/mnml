//! The `:` line's completion popup — the candidates for what is typed,
//! shown as they are typed, so a user who does not know the Tab chord
//! still sees where the line could go. It stands DIRECTLY ABOVE the
//! command line, its left edge on the first typed character (the
//! column after the `:`), growing upward: the lower-left of the screen,
//! next to the eyes and the typing, never centred (`overlay.placeAbove`
//! is the placement; the frame is the shared `overlay.frameLook`, the
//! `.menu` look every list popup wears).
//!
//! Behaviour (Rust's `cmdline_popup_view.rs`):
//!
//!   - painted while the `:` line is open AND there are at least two
//!     candidates for the current token; a single candidate is no
//!     popup at all (the line is the only place it could go, and Tab
//!     still completes it);
//!   - up to `max_visible` rows, windowed around the selection; past
//!     that a `(N more — Tab to cycle)` hint row;
//!   - the selected row on the palette's `bg3`, bold; a click on any
//!     row writes it into the line (`.overlay_item(i)` — `i` indexes
//!     the caller's list, not the painted row);
//!   - width is the widest label plus four, capped at `max_width` and
//!     at the screen's right edge; height never rises above `top`, the
//!     first row under the tab bar, so it caps its rows on a short
//!     screen rather than climbing over the chrome;
//!   - `ui.cmdline_popup_border_color` (`#RRGGBB`) colours the border;
//!     empty or malformed means the theme's own `overlay_border`.
//!
//! The app hands in plain data: the labels and which one is selected.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");

const Style = vaxis.Style;

pub const max_visible: usize = 8;
pub const max_width: u16 = 60;
/// A row's label plus one cell of air each side, plus the frame.
pub const chrome_w: u16 = 4;

pub const Props = struct {
    labels: []const []const u8,
    selected: usize,
    /// `ui.cmdline_popup_border_color`; "" = the theme's.
    border_color: []const u8 = "",
};

/// Whether `n` candidates make a popup at all.
pub fn shows(n: usize) bool {
    return n >= 2;
}

/// `#RRGGBB` / `RRGGBB` → a colour; anything else is null.
pub fn parseHex(s: []const u8) ?vaxis.Color {
    const t = std.mem.trim(u8, s, " \t");
    const body = if (t.len > 0 and t[0] == '#') t[1..] else t;
    if (body.len != 6) return null;
    const v = std.fmt.parseInt(u24, body, 16) catch return null;
    return Theme.rgb(v);
}

/// The hint row's text for `n` candidates past the visible ones.
pub fn moreHint(ui: Ui, n: usize) []const u8 {
    return if (ui.ascii) ui.fmt("  ({d} more - Tab to cycle)", .{n}) else ui.fmt("  ({d} more — Tab to cycle)", .{n});
}

/// Paints the popup above `cmdline` (the `:` line's row), never
/// rising above row `top`, and registers a hit per row. Returns the
/// frame it painted, or null when there is nothing to show or no room.
pub fn draw(ui: Ui, cmdline: Rect, top: u16, p: Props) ?Rect {
    const n = p.labels.len;
    if (!shows(n) or cmdline.isEmpty() or cmdline.y == 0) return null;
    const t = ui.theme;
    // The screen the popup may use: from `top` down to the `:` line.
    const screen = Rect.init(cmdline.x, top, cmdline.w, cmdline.y -| top);
    const x = cmdline.x + 1;
    const bottom = cmdline.y - 1;
    const room = bottom + 1 -| top;
    if (room < 3) return null;
    // Rows: the cap, then whatever the room allows once the frame and
    // the hint have theirs.
    var rows: usize = @min(n, max_visible);
    var hint: usize = if (n > rows) 1 else 0;
    while (rows + 2 + hint > room and rows > 1) {
        rows -= 1;
        hint = 1;
    }
    if (rows + 2 + hint > room) return null;
    const selected = @min(p.selected, n - 1);
    const start = if (selected < rows) 0 else selected + 1 - rows;
    var label_w: u16 = 1;
    for (p.labels[start .. start + rows]) |l| label_w = @max(label_w, ui.width(l));
    if (hint == 1) label_w = @max(label_w, ui.width(moreHint(ui, n - rows)) -| 2);
    const w: u16 = @min(label_w + chrome_w, max_width);
    const h: u16 = @intCast(rows + 2 + hint);
    const frame = overlay.placeAbove(screen, x, bottom, top, w, h);
    if (frame.isEmpty()) return null;

    // The shared frame, with the configured border colour set into a
    // copy of the theme so the component paints it, not a hand-drawn
    // border.
    var themed = ui;
    if (parseHex(p.border_color)) |c| {
        const copy = ui.arena.create(Theme) catch null;
        if (copy) |cp| {
            cp.* = t.*;
            cp.overlay_border = Theme.withFg(t.overlay_border, c);
            themed.theme = cp;
        }
    }
    const inner = overlay.frameLook(themed, frame, null, .menu);
    if (inner.isEmpty()) return frame;

    const plain = t.overlay_bg;
    var band = Theme.onBg(t.overlay_bg, t.palette.bg3);
    band.bold = true;
    var i: usize = 0;
    while (i < rows and i < inner.h) : (i += 1) {
        const idx = start + i;
        const r = inner.row(@intCast(i));
        const style = if (idx == selected) band else plain;
        ui.fill(r, style);
        const max = r.w -| 2;
        _ = ui.putStr(r.x + 1, r.y, max, ui.clipStr(p.labels[idx], max), Theme.withFg(style, t.fg.fg));
        ui.hit(r, .{ .overlay_item = @intCast(idx) });
    }
    if (hint == 1 and rows < inner.h) overlay.hint(ui, inner.row(@intCast(rows)), moreHint(ui, n - rows));
    return frame;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const labels3 = [_][]const u8{ "dock", "docs.open", "editor.dot_repeat" };

test "two or more candidates paint above the : line, left edge on the first typed cell" {
    var f = try Fixture.init(40, 12);
    defer f.deinit();
    const cmdline = Rect.init(0, 11, 40, 1);
    const r = draw(f.ui(), cmdline, 2, .{ .labels = &labels3, .selected = 0 }).?;
    // The placement rule: bottom row is the row above the `:` line, and
    // x is the cmdline text's column (the one after the `:`).
    try testing.expectEqual(cmdline.y - 1, r.bottom() - 1);
    try testing.expectEqual(cmdline.x + 1, r.x);
    // Three rows plus the frame; widest label 17 + 4.
    try testing.expectEqual(@as(u16, 5), r.h);
    try testing.expectEqual(@as(u16, 21), r.w);
    try f.expectRow(6, " ┌───────────────────┐");
    try f.expectRow(7, " │ dock              │");
    try f.expectRow(8, " │ docs.open         │");
    try f.expectRow(9, " │ editor.dot_repeat │");
    try f.expectRow(10, " └───────────────────┘");
    // The selected row is banded on bg3 and bold; the others are plain.
    try testing.expect(f.bgEql(3, 7, .{ .bg = f.theme.palette.bg3 }));
    try testing.expect(f.style(3, 7).bold);
    try testing.expect(f.bgEql(3, 8, f.theme.overlay_bg));
    try testing.expect(!f.style(3, 8).bold);
    // Every row is a hit carrying the caller's index.
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 7).?.overlay_item);
    try testing.expectEqual(@as(u32, 2), f.hits.at(5, 9).?.overlay_item);
    // The border is the theme's when no colour is configured.
    try testing.expect(f.fgEql(1, 6, f.theme.overlay_border));
}

test "a single candidate is no popup; none is no popup" {
    var f = try Fixture.init(40, 12);
    defer f.deinit();
    const one = [_][]const u8{"dock"};
    try testing.expect(draw(f.ui(), Rect.init(0, 11, 40, 1), 2, .{ .labels = &one, .selected = 0 }) == null);
    try testing.expect(draw(f.ui(), Rect.init(0, 11, 40, 1), 2, .{ .labels = &.{}, .selected = 0 }) == null);
    try f.expectLacks("dock");
    try testing.expectEqual(@as(usize, 0), f.hits.items.items.len);
}

test "past max_visible rows the last row says how many more, and the window follows the selection" {
    var f = try Fixture.init(40, 20);
    defer f.deinit();
    var many: [12][]const u8 = undefined;
    for (&many, 0..) |*l, i| l.* = try std.fmt.allocPrint(f.arena_state.allocator(), "cmd.{d:0>2}", .{i});
    const r = draw(f.ui(), Rect.init(0, 19, 40, 1), 1, .{ .labels = &many, .selected = 0 }).?;
    try testing.expectEqual(@as(u16, max_visible + 3), r.h);
    try f.expectContains("cmd.00");
    try f.expectContains("cmd.07");
    try f.expectLacks("cmd.08");
    try f.expectContains("(4 more — Tab to cycle)");
    // Selecting row 10 slides the window so it is on screen.
    f.hits.reset();
    _ = draw(f.ui(), Rect.init(0, 19, 40, 1), 1, .{ .labels = &many, .selected = 10 }).?;
    try f.expectContains("cmd.10");
    try f.expectLacks("cmd.00");
    try testing.expectEqual(@as(u32, 10), f.hits.at(3, 16).?.overlay_item);
    // ASCII spells the hint without the dash.
    var ui = f.ui();
    ui.ascii = true;
    _ = draw(ui, Rect.init(0, 19, 40, 1), 1, .{ .labels = &many, .selected = 0 }).?;
    try f.expectContains("(4 more - Tab to cycle)");
}

test "width is the widest label plus four, capped at max_width and at the screen" {
    var f = try Fixture.init(100, 12);
    defer f.deinit();
    const long = "a" ** 70;
    const wide = [_][]const u8{ long, "b" };
    const r = draw(f.ui(), Rect.init(0, 11, 100, 1), 2, .{ .labels = &wide, .selected = 0 }).?;
    try testing.expectEqual(max_width, r.w);
    // A narrow screen clips the cap.
    var g = try Fixture.init(30, 12);
    defer g.deinit();
    const r2 = draw(g.ui(), Rect.init(0, 11, 30, 1), 2, .{ .labels = &wide, .selected = 0 }).?;
    try testing.expectEqual(@as(u16, 29), r2.w);
    try testing.expectEqual(@as(u16, 1), r2.x);
}

test "a short screen caps the rows so the popup never rises above `top`" {
    var f = try Fixture.init(40, 8);
    defer f.deinit();
    var many: [12][]const u8 = undefined;
    for (&many, 0..) |*l, i| l.* = try std.fmt.allocPrint(f.arena_state.allocator(), "cmd.{d:0>2}", .{i});
    // Rows 2..6 are the room (top = 2, the `:` line on 7): five rows,
    // so two candidates, the hint and the frame.
    const r = draw(f.ui(), Rect.init(0, 7, 40, 1), 2, .{ .labels = &many, .selected = 0 }).?;
    try testing.expectEqual(@as(u16, 2), r.y);
    try testing.expectEqual(@as(u16, 5), r.h);
    try f.expectContains("cmd.01");
    try f.expectLacks("cmd.02");
    try f.expectContains("(10 more — Tab to cycle)");
    // Two rows of room is none at all.
    try testing.expect(draw(f.ui(), Rect.init(0, 7, 40, 1), 5, .{ .labels = &many, .selected = 0 }) == null);
    try testing.expect(draw(f.ui(), Rect.init(0, 0, 40, 1), 0, .{ .labels = &many, .selected = 0 }) == null);
}

test "the configured border colour is honoured; a malformed one falls back to the theme" {
    var f = try Fixture.init(40, 12);
    defer f.deinit();
    _ = draw(f.ui(), Rect.init(0, 11, 40, 1), 2, .{ .labels = &labels3, .selected = 0, .border_color = "#ff8800" }).?;
    try testing.expect(f.fgEql(1, 6, .{ .fg = Theme.rgb(0xff8800) }));
    try testing.expect(!f.fgEql(1, 6, f.theme.overlay_border));
    _ = draw(f.ui(), Rect.init(0, 11, 40, 1), 2, .{ .labels = &labels3, .selected = 0, .border_color = "orange" }).?;
    try testing.expect(f.fgEql(1, 6, f.theme.overlay_border));
    try testing.expect(parseHex("") == null);
    try testing.expect(parseHex("#12345") == null);
    try testing.expect(parseHex("112233") != null);
}
