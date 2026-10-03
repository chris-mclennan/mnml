//! Toasts — the notification stack in the bottom-right corner, each a
//! one-row bordered box, the newest against the statusline, as Rust's
//! `toast_stack` paints them: a square frame with ` × ` set into its top
//! edge (click anywhere on the box to dismiss), the text wrapped to
//! the box up to `max_lines` rows (Rust clips at one; see `wrap`) and
//! ellipsised past that; a message that repeats
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
const link_span = @import("link_span.zig");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

const Segment = vaxis.Segment;
const Style = vaxis.Style;

pub const Level = enum { info, warn, err };

pub const Toast = struct {
    text: []const u8,
    level: Level = .info,
    /// The label of the offer attached to the message, if it has one —
    /// painted as a ` label ` button on its own row inside the box, with
    /// its own hit. A message that reports a missing dependency and then
    /// vanishes leaves the user to copy a command out of a widget that
    /// is already gone.
    action: ?[]const u8 = null,
};

pub const max_width: u16 = 64;
pub const max_visible: usize = 5;
pub const right_margin: u16 = 1;
/// The text cap: the box less its frame and the pad each side.
pub const max_text: u16 = max_width - 4;
/// `.button(button_base + i)` dismisses toast `i`.
pub const button_base: u32 = 0x7000_0000;
/// `.button(action_base + i)` runs toast `i`'s offer; `.button(close_base
/// + i)` is its ` × `. Both sit above the dismiss range, so a dispatcher
/// reads them before the catch-all `>= button_base` arm.
pub const action_base: u32 = 0x7400_0000;
pub const close_base: u32 = 0x7800_0000;
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

/// How many rows a toast may take before it is cut: the message
/// wraps (a word at a time, a newline where the text has one) up to
/// this many lines, and a text still longer ends its last line in an
/// ellipsis. Rust clips at one row; a one-row box lost the instruction
/// behind a long path (`config: /private/tmp/…/config.toml: mnml-…`).
pub const max_lines: usize = 4;

/// The chars of `s`, by codepoint, as Rust's cap counts them.
fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// The byte offset after the first `n` chars of `s`.
fn byteAt(s: []const u8, n: usize) usize {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var taken: usize = 0;
    var end: usize = 0;
    while (taken < n) : (taken += 1) {
        const cp = it.nextCodepointSlice() orelse break;
        end += cp.len;
    }
    return end;
}

/// `s` as at most `max_lines` lines of at most `cap` chars: a line
/// breaks at the last space that fits, else mid-word; a `\n` (or
/// `\r\n`) breaks one; what does not fit in the last line is an
/// ellipsis in its last char. Trailing spaces are not carried over.
pub fn wrap(ui: Ui, s: []const u8, cap_in: u16) []const []const u8 {
    const cap: usize = @max(cap_in, 1);
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var rest = s;
    var cut = false;
    while (rest.len > 0 and lines.items.len < max_lines) {
        var seg = rest;
        var after: []const u8 = "";
        if (std.mem.indexOfAny(u8, rest, "\r\n")) |nl| {
            seg = rest[0..nl];
            after = rest[nl + 1 ..];
            if (rest[nl] == '\r' and after.len > 0 and after[0] == '\n') after = after[1..];
        }
        var line = seg;
        if (charCount(seg) > cap) {
            const hard = byteAt(seg, cap);
            const space = std.mem.lastIndexOfScalar(u8, seg[0..hard], ' ');
            // `hard` itself may sit on a space: the word fit exactly.
            const at: usize = if (hard < seg.len and seg[hard] == ' ') hard else if (space) |sp| (if (sp == 0) hard else sp) else hard;
            line = seg[0..at];
            after = std.mem.concat(ui.arena, u8, &.{ std.mem.trimStart(u8, seg[at..], " "), if (after.len > 0) "\n" else "", after }) catch after;
        }
        lines.append(ui.arena, std.mem.trimEnd(u8, line, " ")) catch break;
        rest = after;
        cut = rest.len > 0;
    }
    if (cut and lines.items.len > 0) {
        // The last line ends in the ellipsis, inside the cap.
        const last = lines.items[lines.items.len - 1];
        const keep = @min(charCount(last), cap - 1);
        lines.items[lines.items.len - 1] = ui.fmt("{s}{s}", .{ last[0..byteAt(last, keep)], ui.ellipsisText() });
    }
    if (lines.items.len == 0) lines.append(ui.arena, "") catch {};
    return lines.items;
}

/// Paints one box whose bottom edge is `bottom` (exclusive), returns
/// its rect, or null when it does not fit above `top`. The text wraps
/// at the box's inner width (`max_text` chars, less on a narrow
/// screen) up to `max_lines` rows; the box is as wide as its longest
/// line and the pads, at most `max_width`, at most the area less two.
fn paintBox(ui: Ui, area: Rect, bottom: u16, toast: Toast, border: Style, idx: ?usize) ?Rect {
    const t = ui.theme;
    const cap: u16 = @min(max_text, (area.w -| 2) -| 4);
    if (cap < 2) return null;
    const lines = wrap(ui, toast.text, cap);
    var longest: u16 = 0;
    for (lines) |l| longest = @max(longest, @as(u16, @intCast(@min(charCount(l), cap))));
    // The offer is a row of its own inside the box, so it needs to fit
    // there too. On the bottom BORDER a filled button straddling a
    // 1-cell rule reads as detached — outside the box, not in it.
    const action = if (toast.action) |a| buttonLabel(ui, a, cap) else null;
    if (action) |a| longest = @max(longest, @as(u16, @intCast(@min(charCount(a), cap))));
    const w = @min(longest + 4, @min(max_width, area.w -| 2));
    if (w < 6) return null;
    const h: u16 = @intCast(lines.len + 2 + @as(usize, if (action != null) 1 else 0));
    if (bottom < area.y + h) return null;
    const r = Rect.init(area.right() - right_margin - w, bottom - h, w, h);
    ui.fill(r, t.overlay_bg);
    const kind: @import("border.zig").Kind = if (ui.ascii) .ascii else .single;
    const inner = ui.canvas.border(r, kind, border, null);
    const fg = Theme.onBg(t.fg, t.overlay_bg.bg);
    for (lines, 0..) |line, i| _ = ui.putStr(inner.x + 1, inner.y + @as(u16, @intCast(i)), inner.w -| 1, line, fg);
    // The box's own hit goes down first so the two above it win.
    if (idx) |i| ui.hit(r, .{ .button = button_base + @as(u32, @intCast(i)) });
    // Its URLs and declared keys link, over the box's own hit. A link
    // the wrap cut at a line's end is not one: half a URL opens the
    // wrong page.
    for (lines, 0..) |line, i| link_span.markWrapped(ui, inner.x + 1, inner.y + @as(u16, @intCast(i)), inner.w -| 1, line, i + 1 < lines.len);
    // The close mark sits in the top edge, three cells before the
    // corner: it costs the message no width and is a three-cell target
    // rather than one.
    if (w >= 8) {
        _ = ui.putStr(r.right() - 4, r.y, 3, if (ui.ascii) " x " else " × ", border);
        if (idx) |i| ui.hit(Rect.init(r.right() - 4, r.y, 3, 1), .{ .button = close_base + @as(u32, @intCast(i)) });
    }
    if (action) |a| {
        const y = inner.y + @as(u16, @intCast(lines.len));
        var style = Theme.onBg(t.chip_active, t.palette.green);
        style.bold = true;
        const bw = ui.putStr(inner.x + 1, y, inner.w -| 1, a, style);
        if (bw > 0 and idx != null) ui.hit(Rect.init(inner.x + 1, y, bw, 1), .{ .button = action_base + @as(u32, @intCast(idx.?)) });
    }
    return r;
}

/// ` Install ` — the offer's label, padded into a button and clipped to
/// what the box can hold.
fn buttonLabel(ui: Ui, label: []const u8, cap: u16) []const u8 {
    const room = cap -| 2;
    const clipped = if (charCount(label) > room) label[0..byteAt(label, room)] else label;
    return ui.fmt(" {s} ", .{clipped});
}

/// Newest first in `toasts`: index 0 lands closest to the bottom.
pub fn draw(ui: Ui, area: Rect, toasts: []const Toast) void {
    if (toasts.len == 0 or area.w < 20 or area.h < 3) return;
    const t = ui.theme;
    var bottom = area.bottom();
    const overflow = toasts.len > max_visible;
    const take = if (overflow) max_visible - 1 else @min(toasts.len, max_visible);
    for (toasts[0..take], 0..) |toast, i| {
        const r = paintBox(ui, area, bottom, toast, borderStyle(t, toast.level), i) orelse return;
        bottom = r.y;
    }
    if (overflow) {
        const hidden = toasts.len - take;
        const more = if (ui.ascii) ui.fmt("+{d} more...", .{hidden}) else ui.fmt("+{d} more…", .{hidden});
        _ = paintBox(ui, area, bottom, .{ .text = more }, borderStyle(t, .info), null);
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

test "a long text wraps to the box, a newline breaks a line, past four lines it ends in an ellipsis; a burst collapses into +K more" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    // rust-analyzer's own text: the newline is a line break, the box
    // is as wide as the longer line (49 chars) and its pads.
    const long = [_]Toast{.{ .text = "LSP: Failed to discover workspace.\nConsider adding the `Cargo.toml` of the workspace" }};
    draw(f.ui(), f.full(), &long);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("┌──────────────────────────────────────────────── × ┐", std.mem.trimStart(u8, f.row(16, &buf), " "));
    try testing.expectEqualStrings("│ LSP: Failed to discover workspace.                │", std.mem.trimStart(u8, f.row(17, &buf), " "));
    try testing.expectEqualStrings("│ Consider adding the `Cargo.toml` of the workspace │", std.mem.trimStart(u8, f.row(18, &buf), " "));
    try testing.expectEqualStrings("└───────────────────────────────────────────────────┘", std.mem.trimStart(u8, f.row(19, &buf), " "));
    const r = f.hits.items.items[0].rect;
    try testing.expectEqual(@as(u16, 4), r.h);
    try testing.expectEqual(@as(u16, 53), r.w);
    try testing.expectEqual(@as(u16, 26), r.x);
    f.hits.reset();
    // A path-first message: the instruction after the path is on the
    // rows below it instead of behind an ellipsis at char 59.
    const cfg = [_]Toast{.{ .text = "config: /private/tmp/walk/slot1/ws/.mnml/config.toml: mnml-zig reads config.zon, not TOML — run `mnml export-config-zon` (0.2.22) to convert this file" }};
    draw(f.ui(), f.full(), &cfg);
    try f.expectContains("export-config-zon");
    try f.expectContains("to convert this file");
    try testing.expectEqual(@as(u16, 5), f.hits.items.items[0].rect.h);
    f.hits.reset();
    // Past four lines the fourth ends in an ellipsis, inside the cap.
    const words = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu " ** 3;
    draw(f.ui(), f.full(), &.{.{ .text = words }});
    const rr = f.hits.items.items[0].rect;
    try testing.expectEqual(@as(u16, 6), rr.h);
    // Word-wrapped lines fall short of the cap by a word's tail.
    try testing.expect(rr.w > 50 and rr.w <= 64);
    try testing.expect(std.mem.indexOf(u8, f.row(rr.y + 4, &buf), "…") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(rr.y + 3, &buf), "…") == null);
    try f.expectLacks("zulu alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu");
    f.hits.reset();
    // Narrow: the box is the area less two, the text wrapped inside it.
    var n = try Fixture.init(40, 8);
    defer n.deinit();
    draw(n.ui(), n.full(), &long);
    try testing.expectEqual(@as(u16, 38), n.hits.items.items[0].rect.w);
    try testing.expectEqual(@as(u16, 5), n.hits.items.items[0].rect.h);
    try n.expectContains("LSP: Failed to discover workspace.");
    try n.expectContains("Consider adding the `Cargo.toml`");
    try n.expectContains("of the workspace");
    var burst: [8]Toast = undefined;
    for (&burst, 0..) |*b, i| b.* = .{ .text = if (i == 0) "eight" else "older" };
    draw(f.ui(), f.full(), &burst);
    try f.expectContains("+4 more…");
    // Four boxes, two hits each: the box itself and the ` × ` in its
    // top edge. The `+K more…` chip has neither.
    try testing.expectEqual(@as(usize, 8), f.hits.items.items.len);
    var ui = f.ui();
    ui.ascii = true;
    draw(ui, f.full(), &burst);
    try f.expectContains("+4 more...");
    try f.expectContains(" x +");
}

test "wrap: words, a hard cut of a long word, the newline, the ellipsis in the cap" {
    var f = try Fixture.init(40, 4);
    defer f.deinit();
    const ui = f.ui();
    const a = wrap(ui, "one two three four", 10);
    try testing.expectEqual(@as(usize, 2), a.len);
    try testing.expectEqualStrings("one two", a[0]);
    try testing.expectEqualStrings("three four", a[1]);
    const b = wrap(ui, "abcdefghijkl", 5);
    try testing.expectEqualStrings("abcde", b[0]);
    try testing.expectEqualStrings("fghij", b[1]);
    try testing.expectEqualStrings("kl", b[2]);
    const c = wrap(ui, "a\r\nb\nc", 10);
    try testing.expectEqual(@as(usize, 3), c.len);
    try testing.expectEqualStrings("b", c[1]);
    const d = wrap(ui, "1 2 3 4 5 6 7 8 9", 3);
    try testing.expectEqual(max_lines, d.len);
    try testing.expectEqualStrings("7 …", d[3]);
    try testing.expectEqualStrings("", wrap(ui, "", 10)[0]);
}

test "an offer paints as a button on its own row inside the box, with its own hit" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    draw(f.ui(), f.full(), &.{.{ .text = "missing: zls (brew install zls)", .action = "Install", .level = .warn }});
    var buf: [256]u8 = undefined;
    // Four rows: the top edge with the close mark, the message, the
    // button, the bottom edge. The button is INSIDE, not on the rule.
    const r = f.hits.items.items[0].rect;
    try testing.expectEqual(@as(u16, 4), r.h);
    try testing.expect(std.mem.endsWith(u8, f.row(r.y, &buf), "─ × ┐"));
    try testing.expect(std.mem.indexOf(u8, f.row(r.y + 1, &buf), "missing: zls") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(r.y + 2, &buf), " Install ") != null);
    try testing.expect(std.mem.endsWith(u8, f.row(r.y + 3, &buf), "┘"));
    // Three hits over the box: the box itself, then the `×` and the
    // button over it, both of which must win where they sit.
    try testing.expectEqual(button_base, f.hits.at(r.x + 1, r.y + 1).?.button);
    try testing.expectEqual(close_base, f.hits.at(r.right() - 3, r.y).?.button);
    try testing.expectEqual(action_base, f.hits.at(r.x + 2, r.y + 2).?.button);
    // Past the button's own width the box's dismiss answers again.
    try testing.expectEqual(button_base, f.hits.at(r.right() - 2, r.y + 2).?.button);
    try testing.expect(f.bgEql(r.x + 2, r.y + 2, .{ .bg = f.theme.palette.green }));
    // No offer, no extra row.
    f.hits.reset();
    draw(f.ui(), f.full(), &.{.{ .text = "missing: zls (brew install zls)" }});
    try testing.expectEqual(@as(u16, 3), f.hits.items.items[0].rect.h);
    try f.expectLacks(" Install ");
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

test "a toast's ticket key and PR ref take `.link` hits over the box's own; a link the wrap cut at a line's end does not" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    var ui = f.ui();
    ui.links = link_span.TestKeys.finder();
    const toasts = [_]Toast{.{ .text = "opened ENG-123 for widget#42" }};
    draw(ui, f.full(), &toasts);
    var buf: [256]u8 = undefined;
    const row = f.row(10, &buf);
    const k: u16 = @intCast(try std.unicode.utf8CountCodepoints(row[0..std.mem.indexOf(u8, row, "ENG-123").?]));
    const p: u16 = @intCast(try std.unicode.utf8CountCodepoints(row[0..std.mem.indexOf(u8, row, "widget#42").?]));
    try testing.expectEqualStrings(link_span.TestKeys.key_url, f.hits.at(k + 3, 10).?.link.url);
    try testing.expectEqualStrings(link_span.TestKeys.pr_url, f.hits.at(p + 8, 10).?.link.url);
    try testing.expectEqual(button_base + 0, f.hits.at(k - 2, 10).?.button);
    // Wrapped so the key ends the first line: it is left plain there.
    var g = try Fixture.init(24, 12);
    defer g.deinit();
    var ui2 = g.ui();
    ui2.links = link_span.TestKeys.finder();
    draw(ui2, g.full(), &.{.{ .text = "see the ENG-12 tail words here" }});
    var y: u16 = 0;
    var linked = false;
    while (y < 12) : (y += 1) {
        var x: u16 = 0;
        while (x < 24) : (x += 1) if (g.hits.at(x, y)) |h| if (h == .link) {
            linked = true;
        };
    }
    try testing.expect(!linked);
}
