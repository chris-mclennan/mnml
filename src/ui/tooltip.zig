//! The hover tooltip — the popup near the pointer (`ui.hover_tooltip`):
//! one or two lines in an overlay box, below and to the right of the
//! cell, flipped above / left when the screen ends. It registers no
//! hit — a tip is never a click target. (The info view at the bottom of
//! the sidebar is `info_view.zig`.)

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");

pub const Tip = struct {
    title: []const u8,
    /// Lines that belong with the title — an integration chip's other
    /// counts, one per line — painted at the title's weight right under
    /// it, so a chip's second and third numbers are not footnotes.
    body: []const []const u8 = &.{},
    /// The publisher's own notes on those lines (`threads: 2 of 3
    /// counted off the cache`), muted, before the host's `detail`.
    notes: []const []const u8 = &.{},
    detail: ?[]const u8 = null,
    /// // changed (sessions-card): more rows under the detail, muted —
    /// the SESSIONS card's branch, cwd and what the pane shows. An
    /// empty line is a blank row.
    lines: []const []const u8 = &.{},
    /// // changed (statusline-hover): the things behind a figure, one
    /// per row under the detail — `text` in the foreground, `sub`
    /// muted and right-aligned. A figure counts something; this is
    /// where the reader finds out what.
    rows: []const Row = &.{},
    /// How many more there are than `rows` holds — the `… and N more`
    /// line under them.
    more: usize = 0,
    /// Non-null makes the rows click targets: each registers
    /// `.tip_row{ .seg, .idx }`, so a click runs what the row names.
    /// The tip itself still registers nothing.
    row_seg: ?u32 = null,
    /// Grow to the longest line up to the screen's width rather than
    /// `max_width`: an integration's breakdown is cut only when the
    /// screen itself has no more room.
    wide: bool = false,
};

/// One thing behind a figure.
pub const Row = struct {
    text: []const u8,
    /// Where it lives, how old it is, what state it is in — muted, at
    /// the right edge of the row when there is room for it.
    sub: []const u8 = "",
    /// The command id a click on the row runs; null is a label.
    command: ?[]const u8 = null,
    /// Appended to the argv when `command` mounts a binary.
    args: []const []const u8 = &.{},
};

/// Cells kept between a row's text and its right-aligned `sub`.
const sub_gap: u16 = 2;

pub const max_width: u16 = 60;

/// The popup beside `(x, y)`.
pub fn draw(ui: Ui, screen: Rect, x: u16, y: u16, tip: Tip) void {
    if (screen.isEmpty()) return;
    const t = ui.theme;
    // The frame arena, not the stack: the box paints this string after
    // the width pass, and a stack buffer would be dead by then.
    const more_text: ?[]const u8 = if (tip.more > 0) ui.fmt("\u{2026} and {d} more", .{tip.more}) else null;
    var widest: u16 = @max(ui.width(tip.title), if (tip.detail) |d| ui.width(d) else 0);
    for (tip.body) |l| widest = @max(widest, ui.width(l));
    for (tip.notes) |l| widest = @max(widest, ui.width(l));
    for (tip.lines) |l| widest = @max(widest, ui.width(l));
    for (tip.rows) |r| widest = @max(widest, ui.width(r.text) +| (if (r.sub.len > 0) sub_gap +| ui.width(r.sub) else 0));
    if (more_text) |m| widest = @max(widest, ui.width(m));
    const cap: u16 = if (tip.wide) screen.w -| 2 else @min(max_width, screen.w -| 2);
    const inner_w: u16 = @min(widest, cap);
    if (inner_w == 0) return;
    const w = inner_w + 2;
    const base_h: u16 = if (tip.detail != null) 4 else 3;
    if (w > screen.w or base_h > screen.h) return;
    // The extra lines and rows take what room there is under the base box.
    const extra = @min(tip.body.len, 8) + @min(tip.notes.len, 8) + @min(tip.lines.len, 12) + tip.rows.len + @intFromBool(tip.more > 0);
    const h: u16 = @min(base_h +| @as(u16, @intCast(@min(extra, 64))), screen.h);
    // Below-right of the cell; flip when the edge is in the way.
    var bx = x + 1;
    if (bx + w > screen.right()) bx = screen.right() - w;
    var by = y + 1;
    if (by + h > screen.bottom()) by = y -| h;
    if (by < screen.y) by = screen.y;
    const r = Rect.init(bx, by, w, h);
    const inner = overlay.frame(ui, r, null);
    if (inner.isEmpty()) return;
    _ = ui.putStr(inner.x, inner.y, inner.w, ui.clipStr(tip.title, inner.w), Theme.onBg(t.fg, t.overlay_bg.bg));
    var yy: u16 = inner.y + 1;
    for (tip.body[0..@min(tip.body.len, 8)]) |l| {
        if (yy >= inner.bottom()) break;
        _ = ui.putStr(inner.x, yy, inner.w, ui.clipStr(l, inner.w), Theme.onBg(t.fg, t.overlay_bg.bg));
        yy += 1;
    }
    for (tip.notes[0..@min(tip.notes.len, 8)]) |l| {
        if (yy >= inner.bottom()) break;
        _ = ui.putStr(inner.x, yy, inner.w, ui.clipStr(l, inner.w), Theme.onBg(t.muted, t.overlay_bg.bg));
        yy += 1;
    }
    if (tip.detail) |d| if (yy < inner.bottom()) {
        _ = ui.putStr(inner.x, yy, inner.w, ui.clipStr(d, inner.w), Theme.onBg(t.muted, t.overlay_bg.bg));
        yy += 1;
    };
    for (tip.lines) |l| {
        if (yy >= inner.bottom()) break;
        _ = ui.putStr(inner.x, yy, inner.w, ui.clipStr(l, inner.w), Theme.onBg(t.muted, t.overlay_bg.bg));
        yy += 1;
    }
    const text_style = Theme.onBg(t.fg, t.overlay_bg.bg);
    const muted_style = Theme.onBg(t.muted, t.overlay_bg.bg);
    for (tip.rows, 0..) |row, i| {
        if (yy >= inner.bottom()) break;
        // The `sub` takes the right edge, the text what is left of it
        // — a long title is clipped before the state it is in.
        var text_w = inner.w;
        if (row.sub.len > 0) {
            const sub_w = @min(ui.width(row.sub), inner.w);
            if (sub_w + sub_gap < inner.w) {
                _ = ui.putStrRight(inner.right(), yy, sub_w, row.sub, muted_style);
                text_w = inner.w - sub_w - sub_gap;
            }
        }
        _ = ui.putStr(inner.x, yy, text_w, ui.clipStr(row.text, text_w), text_style);
        if (tip.row_seg) |seg| ui.hit(Rect.init(inner.x, yy, inner.w, 1), .{ .tip_row = .{ .seg = seg, .idx = @intCast(i), .x = x, .y = y } });
        yy += 1;
    }
    if (more_text) |m| if (yy < inner.bottom()) {
        _ = ui.putStr(inner.x, yy, inner.w, ui.clipStr(m, inner.w), muted_style);
    };
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the popup sits below-right, flips at the edges, and registers no hit" {
    var f = try Fixture.init(40, 10);
    defer f.deinit();
    draw(f.ui(), f.full(), 2, 1, .{ .title = "click: toggle keymap", .detail = "right-click: menu" });
    try f.expectContains("click: toggle keymap");
    try f.expectContains("right-click: menu");
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, f.row(3, &buf), "click: toggle keymap") != null);
    try testing.expectEqual(@as(usize, 0), f.hits.items.items.len);
    // Near the bottom-right it flips above and left.
    var g = try Fixture.init(40, 10);
    defer g.deinit();
    draw(g.ui(), g.full(), 38, 9, .{ .title = "hello" });
    try testing.expect(std.mem.indexOf(u8, g.row(7, &buf), "hello") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, g.row(7, &buf), " "), "hello│"));
    // No room at all: nothing painted.
    var h = try Fixture.init(6, 2);
    defer h.deinit();
    draw(h.ui(), h.full(), 0, 0, .{ .title = "hello world" });
    try h.expectRow(0, "");
    // sessions-card: extra lines paint under the detail, one per row, a
    // blank line as a blank row; the box grows to hold them.
    var i = try Fixture.init(40, 12);
    defer i.deinit();
    draw(i.ui(), i.full(), 0, 0, .{ .title = "fix the tests", .detail = "click: focus", .lines = &.{ "⎇ main", "", "you: fix the tests" } });
    try testing.expect(std.mem.indexOf(u8, i.row(2, &buf), "fix the tests") != null);
    try testing.expect(std.mem.indexOf(u8, i.row(3, &buf), "click: focus") != null);
    try testing.expect(std.mem.indexOf(u8, i.row(4, &buf), "⎇ main") != null);
    try testing.expect(std.mem.indexOf(u8, i.row(6, &buf), "you: fix the tests") != null);
    try testing.expect(std.mem.indexOf(u8, i.row(7, &buf), "╰") != null);
}

test "the rows list what a figure counts: text left, sub right, the rest counted, each a hit" {
    var f = try Fixture.init(48, 14);
    defer f.deinit();
    draw(f.ui(), f.full(), 0, 0, .{
        .title = "Bitbucket \u{b7} 12 open pull requests you authored",
        .detail = "click runs the segment's command",
        .rows = &.{
            .{ .text = "Fix the login redirect", .sub = "acme/api", .command = "bb.open" },
            .{ .text = "Redesign the empty state", .sub = "acme/web", .command = "bb.open" },
        },
        .more = 10,
        .row_seg = 0x100,
    });
    var buf: [256]u8 = undefined;
    // Title, detail, then one row each, then the count of the rest.
    try testing.expect(std.mem.indexOf(u8, f.row(2, &buf), "Bitbucket") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(3, &buf), "click runs") != null);
    const first = f.row(4, &buf);
    try testing.expect(std.mem.indexOf(u8, first, "Fix the login redirect") != null);
    // The `sub` sits at the right edge of the box, not beside the text.
    const text_at = std.mem.indexOf(u8, first, "Fix the login").?;
    const sub_at = std.mem.indexOf(u8, first, "acme/api").?;
    try testing.expect(sub_at > text_at + "Fix the login redirect".len);
    var buf2: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, f.row(5, &buf2), "Redesign the empty state") != null);
    try testing.expect(std.mem.indexOf(u8, f.row(6, &buf2), "\u{2026} and 10 more") != null);
    // Every row is a click target, and only the rows are.
    try testing.expectEqual(@as(u32, 0x100), f.hits.at(2, 4).?.tip_row.seg);
    try testing.expectEqual(@as(u16, 0), f.hits.at(2, 4).?.tip_row.idx);
    try testing.expectEqual(@as(u16, 1), f.hits.at(2, 5).?.tip_row.idx);
    try testing.expect(f.hits.at(2, 2) == null);
    // The hit remembers where the box was anchored, so a pointer that
    // walks onto a row does not push the box out from under itself.
    try testing.expectEqual(@as(u16, 0), f.hits.at(2, 4).?.tip_row.x);

    // No `row_seg`: the rows paint and nothing is clickable \u2014 a host
    // segment whose rows name no command.
    var g = try Fixture.init(48, 14);
    defer g.deinit();
    draw(g.ui(), g.full(), 0, 0, .{ .title = "File transfers", .rows = &.{.{ .text = "copy \u{2192} dist", .sub = "40%" }} });
    try g.expectContains("copy \u{2192} dist");
    try testing.expectEqual(@as(usize, 0), g.hits.items.items.len);

    // A row wider than the box keeps its `sub` and loses the tail of
    // its text: what state a thing is in outlives its own name.
    var h = try Fixture.init(30, 10);
    defer h.deinit();
    draw(h.ui(), h.full(), 0, 0, .{
        .title = "Jira",
        .rows = &.{.{ .text = "ENG-12  a summary long enough to run past the edge", .sub = "In Review" }},
    });
    try h.expectContains("In Review");
    try h.expectContains("ENG-12");

    // Under `statusline.hover_items = 0` the caller hands over no rows
    // at all and the box is the one-line tip it always was.
    var i = try Fixture.init(40, 10);
    defer i.deinit();
    draw(i.ui(), i.full(), 0, 0, .{ .title = "Jira \u{b7} 43 open items", .detail = "click: the pane" });
    var ibuf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, i.row(4, &ibuf), "\u{2570}") != null);
}
