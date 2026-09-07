//! Toasts — the notification stack in the bottom-right corner, each a
//! one-row bordered box, the newest against the statusline, as Rust's
//! `toast_stack` paints them: a square frame with ` × ` set into its top
//! edge (click anywhere on the box to dismiss), the text clipped to one
//! row with an ellipsis rather than wrapped; a message that repeats
//! while its box is up bumps that box instead of stacking a twin (the
//! app coalesces). The border carries the level: info and warn in the calm
//! muted color, an error in red so a failure stands out. At most five
//! paint; past that the oldest slot becomes `+K more…` so a burst never
//! covers the pane.
//!
//! Each box registers `.button(button_base + i)` — click to dismiss —
//! in the same statement as its paint. The app passes the region above
//! the statusline; the stack sits on its last row and keeps one cell of
//! margin on the right, and paints nothing at all on a screen too small
//! to hold a box.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

const Segment = vaxis.Segment;
const Style = vaxis.Style;

pub const Level = enum { info, warn, err };

pub const Toast = struct { text: []const u8, level: Level = .info };

pub const max_width: u16 = 64;
pub const max_visible: usize = 5;
pub const right_margin: u16 = 1;
/// The text cap: the box less its frame and the pad each side.
pub const max_text: u16 = max_width - 4;
/// `.button(button_base + i)` dismisses toast `i`.
pub const button_base: u32 = 0x7000_0000;
/// The Undo chip's hit: one below the toasts' range.
pub const undo_button: u32 = button_base - 1;

pub fn borderStyle(t: *const Theme, level: Level) Style {
    const bg = t.overlay_bg.bg;
    return switch (level) {
        .info => Theme.onBg(t.muted, bg),
        .warn => Theme.onBg(t.warn_fg, bg),
        .err => Theme.onBg(t.error_fg, bg),
    };
}

/// Rust's cap is in chars, not cells (`chars().count()` against
/// `MAX_WIDTH - 4`): past it the first `max_text - 1` chars and an
/// ellipsis. A newline inside the text — rust-analyzer's `Failed to
/// discover workspace.\nConsider…` — costs a char and paints nothing,
/// exactly as under Rust, so the two screens clip at the same letter.
fn clipChars(ui: Ui, s: []const u8) []const u8 {
    const n = std.unicode.utf8CountCodepoints(s) catch s.len;
    if (n <= max_text) return s;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var taken: usize = 0;
    var end: usize = 0;
    while (taken + 1 < max_text) : (taken += 1) {
        const cp = it.nextCodepointSlice() orelse break;
        end += cp.len;
    }
    return ui.fmt("{s}{s}", .{ s[0..end], if (ui.ascii) "..." else "…" });
}

/// `s` without its line breaks: the row is one line.
fn oneRow(ui: Ui, s: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, s, "\r\n") == null) return s;
    const out = ui.arena.alloc(u8, s.len) catch return s;
    var n: usize = 0;
    for (s) |c| if (c != '\n' and c != '\r') {
        out[n] = c;
        n += 1;
    };
    return out[0..n];
}

/// Paints one box whose bottom edge is `bottom` (exclusive), returns
/// its rect, or null when it does not fit above `top`. The text is one
/// row, clipped at `max_text` chars; the box is as wide as the text
/// and its pads, at most `max_width`, at most the area less two.
fn paintBox(ui: Ui, area: Rect, bottom: u16, text_in: []const u8, border: Style, hit_id: ?u32) ?Rect {
    const t = ui.theme;
    const text = clipChars(ui, text_in);
    const chars: u16 = @intCast(@min(std.unicode.utf8CountCodepoints(text) catch text.len, max_text));
    const w = @min(chars + 4, @min(max_width, area.w -| 2));
    if (w < 6) return null;
    const h: u16 = 3;
    if (bottom < area.y + h) return null;
    const r = Rect.init(area.right() - right_margin - w, bottom - h, w, h);
    ui.fill(r, t.overlay_bg);
    const kind: @import("border.zig").Kind = if (ui.ascii) .ascii else .single;
    const inner = ui.canvas.border(r, kind, border, null);
    // The close mark sits in the top edge, three cells before the corner.
    if (w >= 8) _ = ui.putStr(r.right() - 4, r.y, 3, if (ui.ascii) " x " else " × ", border);
    const fg = Theme.onBg(t.fg, t.overlay_bg.bg);
    _ = ui.putStr(inner.x + 1, inner.y, inner.w -| 1, oneRow(ui, text), fg);
    if (hit_id) |id| ui.hit(r, .{ .button = id });
    return r;
}

/// Newest first in `toasts`: index 0 lands closest to the bottom.
pub fn draw(ui: Ui, area: Rect, toasts: []const Toast) void {
    if (toasts.len == 0 or area.w < 20 or area.h < 3) return;
    const t = ui.theme;
    var bottom = area.bottom();
    const overflow = toasts.len > max_visible;
    const take = if (overflow) max_visible - 1 else @min(toasts.len, max_visible);
    for (toasts[0..take], 0..) |toast, i| {
        const r = paintBox(ui, area, bottom, toast.text, borderStyle(t, toast.level), button_base + @as(u32, @intCast(i))) orelse return;
        bottom = r.y;
    }
    if (overflow) {
        const hidden = toasts.len - take;
        const more = if (ui.ascii) ui.fmt("+{d} more...", .{hidden}) else ui.fmt("+{d} more…", .{hidden});
        _ = paintBox(ui, area, bottom, more, borderStyle(t, .info), null);
    }
}

/// The Undo chip — `↶ Undo · closed 3 tabs` — on the last row of
/// `area`, right-aligned, in the accent colour so it reads as the one
/// thing here that is an offer rather than a report. Registers
/// `.button(undo_button)`; paints nothing when it does not fit.
pub fn drawUndo(ui: Ui, area: Rect, label: []const u8) void {
    if (area.isEmpty()) return;
    const t = ui.theme;
    const text = if (ui.ascii) ui.fmt(" < Undo - {s} ", .{label}) else ui.fmt(" ↶ Undo · {s} ", .{label});
    const w = ui.width(text);
    if (w + right_margin > area.w) return;
    const y = area.bottom() - 1;
    const x = area.right() - right_margin - w;
    var style = Theme.onBg(t.chip_active, t.chip_active.bg);
    style.bold = true;
    _ = ui.putStr(x, y, w, text, style);
    ui.hit(Rect.init(x, y, w, 1), .{ .button = undo_button });
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the Undo chip sits on the last row, right-aligned, with its own hit" {
    var f = try Fixture.init(50, 6);
    defer f.deinit();
    drawUndo(f.ui(), f.full(), "closed 3 tabs");
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, f.row(5, &buf), " "), "↶ Undo · closed 3 tabs"));
    try testing.expectEqual(undo_button, f.hits.at(40, 5).?.button);
    try testing.expect(f.hits.at(5, 5) == null);
    var g = try Fixture.init(12, 2);
    defer g.deinit();
    drawUndo(g.ui(), g.full(), "closed 3 tabs");
    try testing.expectEqual(@as(usize, 0), g.hits.items.items.len);
}

test "toasts stack from the bottom right, newest lowest, with dismiss hits and level colors" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    const toasts = [_]Toast{
        .{ .text = "mark 'a set" },
        .{ .text = "no mark 'z", .level = .warn },
        .{ .text = "save failed: EACCES", .level = .err },
    };
    draw(f.ui(), f.full(), &toasts);
    try f.expectContains("mark 'a set");
    try f.expectContains("no mark 'z");
    try f.expectContains("save failed: EACCES");
    // Newest box: rows 9..11 on the area's last row, as wide as its text
    // and the pads, ending at col 58 — Rust's square frame with the
    // close mark set into the top edge.
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, f.row(11, &buf), "┘"));
    try testing.expect(std.mem.endsWith(u8, f.row(9, &buf), "─ × ┐"));
    try testing.expect(std.mem.endsWith(u8, f.row(10, &buf), "│ mark 'a set │"));
    try testing.expect(std.mem.indexOf(u8, f.row(7, &buf), "no mark 'z") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(4, &buf), "save failed") != null);
    try testing.expectEqual(button_base + 0, f.hits.at(50, 10).?.button);
    try testing.expectEqual(button_base + 1, f.hits.at(50, 7).?.button);
    try testing.expectEqual(button_base + 2, f.hits.at(50, 4).?.button);
    try testing.expect(f.hits.at(10, 10) == null);
    try testing.expect(f.fgEql(58, 10, f.theme.muted));
    try testing.expect(f.fgEql(58, 7, f.theme.warn_fg));
    try testing.expect(f.fgEql(58, 4, f.theme.error_fg));
    try testing.expect(f.bgEql(50, 10, f.theme.overlay_bg));
}

test "a long text is one row clipped with an ellipsis at Rust's cap; a burst collapses into +K more" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    // rust-analyzer's own text, newline included: 59 chars and the
    // ellipsis, one pad each side, the frame — 64, and the newline
    // paints as nothing, so the row reads `Car…  │` as Rust's does.
    const long = [_]Toast{.{ .text = "LSP: Failed to discover workspace.\nConsider adding the `Cargo.toml` of the workspace" }};
    draw(f.ui(), f.full(), &long);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("┌─────────────────────────────────────────────────────────── × ┐", std.mem.trimStart(u8, f.row(17, &buf), " "));
    try testing.expectEqualStrings("│ LSP: Failed to discover workspace.Consider adding the `Car…  │", std.mem.trimStart(u8, f.row(18, &buf), " "));
    const r = f.hits.items.items[0].rect;
    try testing.expectEqual(@as(u16, 3), r.h);
    try testing.expectEqual(@as(u16, 64), r.w);
    try testing.expectEqual(@as(u16, 15), r.x);
    f.hits.reset();
    // Narrow: the box is the area less two, the text clipped inside it.
    var n = try Fixture.init(40, 6);
    defer n.deinit();
    draw(n.ui(), n.full(), &long);
    try testing.expectEqual(@as(u16, 38), n.hits.items.items[0].rect.w);
    try n.expectContains("LSP: Failed to discover workspace.");
    f.hits.reset();
    var burst: [8]Toast = undefined;
    for (&burst, 0..) |*b, i| b.* = .{ .text = if (i == 0) "eight" else "older" };
    draw(f.ui(), f.full(), &burst);
    try f.expectContains("+4 more…");
    try testing.expectEqual(@as(usize, 4), f.hits.items.items.len);
    var ui = f.ui();
    ui.ascii = true;
    draw(ui, f.full(), &burst);
    try f.expectContains("+4 more...");
    try f.expectContains(" x +");
}

test "no room, no paint" {
    var f = try Fixture.init(18, 8);
    defer f.deinit();
    draw(f.ui(), f.full(), &.{.{ .text = "hi" }});
    try f.expectRow(4, "");
    try testing.expectEqual(@as(usize, 0), f.hits.items.items.len);
    var g = try Fixture.init(40, 5);
    defer g.deinit();
    // Two boxes need 6 rows; the second is dropped, the first stays.
    draw(g.ui(), g.full(), &.{ .{ .text = "one" }, .{ .text = "two" } });
    try g.expectContains("one");
    try g.expectLacks("two");
    draw(g.ui(), Rect.empty, &.{.{ .text = "x" }});
    draw(g.ui(), g.full(), &.{});
}
