//! The DIAGNOSTICS panel's row: `<severity glyph> <message>  <rel>:<line>`
//! — the glyph coloured by severity, the location dim and clipped from
//! the left so the file and line survive a long message. The panel
//! chrome (header, filter, scrollbar, hits) is `ListPanel`'s.

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
    const loc = ui.fmt("{s}:{d}", .{ row.rel, row.line + 1 });
    const min_loc: u16 = 10;
    const avail: u16 = end -| x;
    var message = row.message;
    var loc_shown = loc;
    if (ui.width(message) + 2 + ui.width(loc) > avail) {
        const loc_keep = @min(ui.width(loc), min_loc);
        message = ui.clipStr(row.message, avail -| (2 + loc_keep));
        const loc_max = avail -| (ui.width(message) + 2);
        if (ui.width(loc) > loc_max) {
            const ell: []const u8 = if (ui.ascii) "..." else "…";
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
