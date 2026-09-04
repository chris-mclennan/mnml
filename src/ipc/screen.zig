//! The text the host sees: two screen flatteners, `status.json`, and the
//! JSON helpers every events.jsonl line goes through.
//!
//! Two flatteners exist because two consumers read them differently:
//!
//! - `toScreenTxt` is `screen.txt`. Each row is trimmed on the right and
//!   ends in `\n` — the last row too. A host greps it.
//! - `toTestText` is what a `.test` `expect screen` matches against. No
//!   trim, no trailing newline. A row is exactly `cols` cells wide, so a
//!   script can assert on column alignment.
//!
//! Both walk every cell, tails of wide glyphs included: a wide head owns a
//! real " " tail cell (see `ui/canvas.zig`), so the text stays one entry per
//! column and mirrors what mnml 0.2 dumps.
//!
//! `status.json` is hand-rolled in a fixed key order and `jsonStr` escapes
//! only `" \ \n \r \t` plus `\u00XX` for other controls. These bytes are a
//! contract with the hosts that already read them; a struct serializer would
//! be shorter and wrong.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");

pub const Screen = vaxis.Screen;

/// `screen.txt`: rows right-trimmed, every row `\n`-terminated.
pub fn toScreenTxt(gpa: Allocator, screen: *const Screen) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var y: u16 = 0;
    while (y < screen.height) : (y += 1) {
        const row_start = out.items.len;
        try appendRow(gpa, &out, screen, y);
        const trimmed_len = std.mem.trimEnd(u8, out.items[row_start..], " \t").len;
        out.shrinkRetainingCapacity(row_start + trimmed_len);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// `.test` matching text: no trim, rows joined by `\n`, no trailing newline.
pub fn toTestText(gpa: Allocator, screen: *const Screen) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var y: u16 = 0;
    while (y < screen.height) : (y += 1) {
        try appendRow(gpa, &out, screen, y);
        if (y + 1 < screen.height) try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn appendRow(gpa: Allocator, out: *std.ArrayList(u8), screen: *const Screen, y: u16) Allocator.Error!void {
    var x: u16 = 0;
    while (x < screen.width) : (x += 1) {
        const cell = screen.readCell(x, y) orelse break;
        try out.appendSlice(gpa, cell.char.grapheme);
    }
}

// ─── status.json ────────────────────────────────────────────────────────

pub const Focus = enum { tree, pane, right_panel, bottom_panel };

pub const PaneStatus = struct {
    title: []const u8,
    dirty: bool,
};

/// Everything `status.json` reports. The App fills one per frame; nothing
/// here is owned — slices borrow from the App or the frame arena.
pub const Status = struct {
    focus: Focus,
    active_pane: ?usize,
    active_file: []const u8,
    /// 1-based, `0` when there is no editor.
    cursor_line: usize,
    cursor_col: usize,
    /// The editing-mode label, or `none`.
    mode: []const u8,
    tree_cursor: usize,
    tree_selection: []const u8,
    tree_visible: bool,
    right_panel_visible: bool,
    right_panel_panes: []const usize,
    right_panel_active_idx: usize,
    panes: []const PaneStatus,
    quit: bool,
};

pub fn writeStatusJson(w: *Io.Writer, s: Status) Io.Writer.Error!void {
    try w.writeAll("{\"focus\":");
    try jsonStr(w, @tagName(s.focus));
    try w.writeAll(",\"activePane\":");
    if (s.active_pane) |i| try w.print("{d}", .{i}) else try w.writeAll("null");
    try w.writeAll(",\"activeFile\":");
    try jsonStr(w, s.active_file);
    try w.print(",\"cursor\":{{\"line\":{d},\"col\":{d}}},\"mode\":", .{ s.cursor_line, s.cursor_col });
    try jsonStr(w, s.mode);
    try w.print(",\"treeCursor\":{d},\"treeSelection\":", .{s.tree_cursor});
    try jsonStr(w, s.tree_selection);
    try w.print(",\"treeVisible\":{},\"rightPanelVisible\":{},\"rightPanelPanes\":[", .{ s.tree_visible, s.right_panel_visible });
    for (s.right_panel_panes, 0..) |idx, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{idx});
    }
    try w.print("],\"rightPanelActiveIdx\":{d},\"panes\":[", .{s.right_panel_active_idx});
    for (s.panes, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"title\":");
        try jsonStr(w, p.title);
        try w.print(",\"dirty\":{}}}", .{p.dirty});
    }
    try w.print("],\"quit\":{}}}", .{s.quit});
}

pub fn statusJson(gpa: Allocator, s: Status) Allocator.Error![]u8 {
    var a: Io.Writer.Allocating = .init(gpa);
    errdefer a.deinit();
    writeStatusJson(&a.writer, s) catch return error.OutOfMemory;
    return a.toOwnedSlice();
}

// ─── JSON helpers ───────────────────────────────────────────────────────

/// A JSON string literal. Escapes `" \ \n \r \t`; other controls become
/// `\u00XX`; everything else (multi-byte UTF-8 included) is written raw.
pub fn jsonStr(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

pub const Pair = struct { []const u8, []const u8 };

/// A flat object whose values are all strings — the events.jsonl shape.
pub fn writeJsonEvent(w: *Io.Writer, pairs: []const Pair) Io.Writer.Error!void {
    try w.writeByte('{');
    for (pairs, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try jsonStr(w, p[0]);
        try w.writeByte(':');
        try jsonStr(w, p[1]);
    }
    try w.writeByte('}');
}

pub fn jsonEvent(gpa: Allocator, pairs: []const Pair) Allocator.Error![]u8 {
    var a: Io.Writer.Allocating = .init(gpa);
    errdefer a.deinit();
    writeJsonEvent(&a.writer, pairs) catch return error.OutOfMemory;
    return a.toOwnedSlice();
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn testScreen(w: u16, h: u16) !Screen {
    var s = try Screen.init(t.allocator, .{ .cols = w, .rows = h, .x_pixel = 0, .y_pixel = 0 });
    s.width_method = .unicode;
    return s;
}

/// Paint ASCII text at (x, y); a wide glyph is written as head + " " tail
/// the way Canvas does.
fn paint(screen: *Screen, x: u16, y: u16, text: []const u8) void {
    var col = x;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepointSlice()) |g| {
        const wide = g.len > 1 and g[0] >= 0xE2; // CJK / box-drawing for these tests
        const width: u8 = if (wide and std.mem.eql(u8, g, "字")) 2 else 1;
        screen.writeCell(col, y, .{ .char = .{ .grapheme = g, .width = width } });
        if (width == 2) {
            screen.writeCell(col + 1, y, .{ .char = .{ .grapheme = " ", .width = 1 } });
            col += 2;
        } else col += 1;
    }
}

test "toScreenTxt trims each row on the right and newline-terminates every row" {
    var screen = try testScreen(8, 3);
    defer screen.deinit(t.allocator);
    paint(&screen, 0, 0, "ab");
    paint(&screen, 2, 1, "字x");
    // row 2 stays blank
    const txt = try toScreenTxt(t.allocator, &screen);
    defer t.allocator.free(txt);
    try t.expectEqualStrings("ab\n  字 x\n\n", txt);
}

test "toTestText keeps every column and has no trailing newline" {
    var screen = try testScreen(5, 2);
    defer screen.deinit(t.allocator);
    paint(&screen, 0, 0, "ab");
    paint(&screen, 1, 1, "字");
    const txt = try toTestText(t.allocator, &screen);
    defer t.allocator.free(txt);
    // The wide glyph's tail is a real " " cell, so every row is exactly
    // `cols` entries and a `.test` can assert column alignment.
    try t.expectEqualStrings("ab   \n 字   ", txt);
    var rows = std.mem.splitScalar(u8, txt, '\n');
    _ = rows.next();
    try t.expectEqual(@as(usize, 5), std.unicode.utf8CountCodepoints(rows.next().?) catch unreachable);
}

test "status.json matches the bytes mnml 0.2.21 writes" {
    // Captured from `mnml --headless` (target/debug, 2026-09-04) after
    // `open hello.txt` in a 60×12 screen.
    const want =
        "{\"focus\":\"tree\",\"activePane\":0,\"activeFile\":\"/tmp/ws/hello.txt\",\"cursor\":{\"line\":1,\"col\":1},\"mode\":\"none\",\"treeCursor\":2,\"treeSelection\":\"/tmp/ws/.gitignore\",\"treeVisible\":true,\"rightPanelVisible\":false,\"rightPanelPanes\":[],\"rightPanelActiveIdx\":0,\"panes\":[{\"title\":\"hello.txt\",\"dirty\":false}],\"quit\":false}";
    const got = try statusJson(t.allocator, .{
        .focus = .tree,
        .active_pane = 0,
        .active_file = "/tmp/ws/hello.txt",
        .cursor_line = 1,
        .cursor_col = 1,
        .mode = "none",
        .tree_cursor = 2,
        .tree_selection = "/tmp/ws/.gitignore",
        .tree_visible = true,
        .right_panel_visible = false,
        .right_panel_panes = &.{},
        .right_panel_active_idx = 0,
        .panes = &.{.{ .title = "hello.txt", .dirty = false }},
        .quit = false,
    });
    defer t.allocator.free(got);
    try t.expectEqualStrings(want, got);
}

test "status.json: null activePane, several right-panel panes, a dirty pane" {
    const got = try statusJson(t.allocator, .{
        .focus = .right_panel,
        .active_pane = null,
        .active_file = "",
        .cursor_line = 0,
        .cursor_col = 0,
        .mode = "insert",
        .tree_cursor = 0,
        .tree_selection = "",
        .tree_visible = false,
        .right_panel_visible = true,
        .right_panel_panes = &.{ 1, 3 },
        .right_panel_active_idx = 1,
        .panes = &.{ .{ .title = "a \"q\"", .dirty = true }, .{ .title = "b", .dirty = false } },
        .quit = true,
    });
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        "{\"focus\":\"right_panel\",\"activePane\":null,\"activeFile\":\"\",\"cursor\":{\"line\":0,\"col\":0},\"mode\":\"insert\",\"treeCursor\":0,\"treeSelection\":\"\",\"treeVisible\":false,\"rightPanelVisible\":true,\"rightPanelPanes\":[1,3],\"rightPanelActiveIdx\":1,\"panes\":[{\"title\":\"a \\\"q\\\"\",\"dirty\":true},{\"title\":\"b\",\"dirty\":false}],\"quit\":true}",
        got,
    );
}

test "jsonStr escapes exactly the dangerous characters" {
    var a: Io.Writer.Allocating = .init(t.allocator);
    defer a.deinit();
    try jsonStr(&a.writer, "a\"b\\c\nd\re\tf\x01g\x1fh é 字");
    try t.expectEqualStrings("\"a\\\"b\\\\c\\nd\\re\\tf\\u0001g\\u001fh é 字\"", a.written());
}

test "jsonEvent is a flat object of string values in insertion order" {
    const got = try jsonEvent(t.allocator, &.{ .{ "event", "click" }, .{ "button", "Right" }, .{ "col", "5" }, .{ "row", "3" } });
    defer t.allocator.free(got);
    try t.expectEqualStrings("{\"event\":\"click\",\"button\":\"Right\",\"col\":\"5\",\"row\":\"3\"}", got);
    const raw = try jsonEvent(t.allocator, &.{ .{ "event", "unknown" }, .{ "raw", "{\"cmd\":\"nope\"}" } });
    defer t.allocator.free(raw);
    try t.expectEqualStrings("{\"event\":\"unknown\",\"raw\":\"{\\\"cmd\\\":\\\"nope\\\"}\"}", raw);
}
