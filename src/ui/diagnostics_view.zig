//! The DIAGNOSTICS panel's row: `<severity glyph> <message>  <source>
//! <rel>:<line>` — the glyph coloured by severity, the location dim and
//! clipped from the left so the file and line survive a long message
//! (and so a narrow panel loses the source before the location). The
//! panel chrome (header, filter, scrollbar, hits) is `ListPanel`'s.
//!
//! // changed (lua-decor): the row names the `source` a finding came
//! from — `eslint`, a language server's name — because a script
//! publishes into the same panel (`mnml.diagnostics.set`) and "who
//! said this" is the one thing that told them apart and was not shown.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const types = @import("../lsp/types.zig");

pub const Row = struct {
    /// Absolute.
    path: []const u8,
    rel: []const u8,
    line: u32,
    character: u32,
    severity: types.Severity,
    message: []const u8,
    source: ?[]const u8,
};

pub fn glyph(s: types.Severity, ascii: bool) []const u8 {
    return switch (s) {
        .err => if (ascii) "E" else "✗",
        .warning => if (ascii) "W" else "⚠",
        .info => if (ascii) "i" else "ℹ",
        .hint => if (ascii) "h" else "·",
    };
}

/// A server's message on one row. rustc's messages carry a newline
/// between the headline and the lint / related-info tail; `putStr`
/// drops the control character and the halves fused ("coveredthe").
/// Each line break becomes ` · ` (` | ` in ASCII), a tab a space; the
/// blanks around a break go. A message without any comes back as is.
pub fn oneLine(arena: std.mem.Allocator, msg: []const u8, ascii: bool) []const u8 {
    if (std.mem.indexOfAny(u8, msg, "\r\n\t") == null) return msg;
    const sep: []const u8 = if (ascii) " | " else " · ";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var pending_break = false;
    for (msg) |c| {
        if (c == '\n' or c == '\r') {
            pending_break = true;
            continue;
        }
        if (pending_break) {
            if (c == ' ' or c == '\t') continue;
            const kept = std.mem.trimEnd(u8, out.items, " ");
            out.items.len = kept.len;
            if (out.items.len > 0) out.appendSlice(arena, sep) catch return msg;
            pending_break = false;
        }
        out.append(arena, if (c == '\t') ' ' else c) catch return msg;
    }
    return out.items;
}

pub fn paintRow(ui: Ui, r: Rect, row: Row, selected: bool) void {
    const t = ui.theme;
    const base = list_panel.rowStyle(t, selected);
    const color = switch (row.severity) {
        .err => t.error_fg.fg,
        .warning => t.warn_fg.fg,
        .info, .hint => t.info_fg.fg,
    };
    var x = r.x;
    const end = r.right();
    x += ui.putStr(x, r.y, end -| x, glyph(row.severity, ui.ascii), Theme.withFg(base, color));
    x += ui.putStr(x, r.y, end -| x, " ", base);
    const loc = if (row.source) |src| ui.fmt("{s} {s}:{d}", .{ src, row.rel, row.line + 1 }) else ui.fmt("{s}:{d}", .{ row.rel, row.line + 1 });
    const min_loc: u16 = 10;
    const avail: u16 = end -| x;
    const full = oneLine(ui.arena, row.message, ui.ascii);
    var message = full;
    var loc_shown = loc;
    // Measures are capped at the row: a 100k-char message must not sum
    // two saturated widths past u16.
    if (ui.widthUpTo(message, avail) + 2 + ui.widthUpTo(loc, avail) > avail) {
        const loc_keep = @min(ui.widthUpTo(loc, avail), min_loc);
        message = ui.clipStr(full, avail -| (2 + loc_keep));
        const loc_max = avail -| (ui.widthUpTo(message, avail) + 2);
        if (ui.widthUpTo(loc, avail) > loc_max) {
            const ell = ui.ellipsisText();
            var start: usize = 0;
            while (start < loc.len and ui.width(loc[start..]) > loc_max -| ui.width(ell)) start += std.unicode.utf8ByteSequenceLength(loc[start]) catch 1;
            loc_shown = ui.fmt("{s}{s}", .{ ell, loc[start..] });
        }
    }
    x += ui.putStr(x, r.y, end -| x, message, Theme.onBg(t.fg, base.bg));
    x += ui.putStr(x, r.y, end -| x, "  ", base);
    _ = ui.putStr(x, r.y, end -| x, loc_shown, Theme.onBg(t.muted, base.bg));
}

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "glyph, message, then the location; a long message keeps the file:line" {
    var f = try Fixture.init(40, 2);
    defer f.deinit();
    paintRow(f.ui(), f.full().row(0), .{ .path = "/ws/src/api.ts", .rel = "src/api.ts", .line = 2, .character = 4, .severity = .err, .message = "x unused", .source = null }, false);
    try f.expectRow(0, "✗ x unused  src/api.ts:3");
    paintRow(f.ui(), f.full().row(1), .{ .path = "/ws/src/api.ts", .rel = "src/api.ts", .line = 2, .character = 4, .severity = .warning, .message = "a very very very long message about things", .source = null }, true);
    var buf: [128]u8 = undefined;
    const row = f.row(1, &buf);
    try testing.expect(std.mem.endsWith(u8, row, "api.ts:3"));
    try testing.expect(std.mem.startsWith(u8, row, "⚠ a very"));
}

test "a multi-line message paints on one row with a separator between its lines, not fused" {
    var f = try Fixture.init(100, 2);
    defer f.deinit();
    paintRow(f.ui(), f.full().row(0), .{ .path = "/ws/src/main.rs", .rel = "src/main.rs", .line = 39, .character = 4, .severity = .err, .message = "`Square` not covered\nthe matched value is of type `&Shape`", .source = "rust-analyzer" }, false);
    try f.expectRow(0, "✗ `Square` not covered · the matched value is of type `&Shape`  rust-analyzer src/main.rs:40");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("unused variable: `v` · `#[warn(unused_variables)]` on by default", oneLine(a, "unused variable: `v`  \r\n\n  `#[warn(unused_variables)]` on by default", false));
    try testing.expectEqualStrings("a | b c", oneLine(a, "a\nb\tc", true));
    try testing.expectEqualStrings("tail", oneLine(a, "\n\ntail\n", false));
    // No control characters: the same slice back, no copy.
    const plain = "just one line";
    try testing.expect(oneLine(a, plain, false).ptr == plain.ptr);
}

test "a 100k-char message paints clipped, the location intact, without overflowing the cell sum" {
    var f = try Fixture.init(60, 1);
    defer f.deinit();
    const long = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(long);
    @memset(long, 'm');
    paintRow(f.ui(), f.full().row(0), .{ .path = "/ws/src/api.ts", .rel = "src/api.ts", .line = 2, .character = 4, .severity = .err, .message = long, .source = null }, false);
    var buf: [256]u8 = undefined;
    const row = f.row(0, &buf);
    try testing.expect(std.mem.startsWith(u8, row, "✗ mmmm"));
    try testing.expect(std.mem.endsWith(u8, row, "…  …/api.ts:3"));
}
