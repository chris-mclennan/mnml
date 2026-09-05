//! The peek overlay: a bordered box near the top of the editor area,
//! centered, showing the lines around a definition with their numbers;
//! the definition's line carries `▸` and the cursor-line band. The
//! title is `✦ peek · <file> · Esc closes` — the gate asserts the
//! `✦ peek` prefix is absent when nothing opened.

const std = @import("std");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");

pub const Props = struct {
    title: []const u8,
    lines: []const []const u8,
    /// 0-based line of `lines[0]` in the file.
    first_line: u32,
    /// Index into `lines` of the definition.
    highlight: usize,
};

pub fn draw(ui: Ui, area: Rect, scroll: *usize, p: Props) void {
    const t = ui.theme;
    if (area.w < 20 or area.h < 6) return;
    const w = std.math.clamp(area.w - area.w / 5, 20, @min(120, area.w));
    const max_h = area.h - area.h / 4;
    const h: u16 = @max(@min(@as(u16, @intCast(@min(p.lines.len + 2, 200))), max_h), @min(8, area.h));
    const x = area.x + (area.w - w) / 2;
    const y = area.y + 1;
    const title = ui.fmt("{s} peek · {s} · Esc closes", .{ if (ui.ascii) "*" else "✦", p.title });
    const inner = overlay.frame(ui, Rect.init(x, y, w, h), title);
    if (inner.isEmpty()) return;
    const rows: usize = inner.h;
    scroll.* = @min(scroll.*, p.lines.len -| rows);
    // Keep the definition visible on the first paint.
    if (p.highlight >= scroll.* + rows) scroll.* = p.highlight + 1 - rows;
    var i: usize = 0;
    while (i < rows and scroll.* + i < p.lines.len) : (i += 1) {
        const idx = scroll.* + i;
        const r = inner.row(@intCast(i));
        const is_anchor = idx == p.highlight;
        const style = if (is_anchor) Theme.onBg(t.overlay_bg, t.cursor_line.bg) else t.overlay_bg;
        ui.fill(r, style);
        const prefix = ui.fmt("{d:>4} {s} ", .{ p.first_line + idx + 1, if (is_anchor) (if (ui.ascii) ">" else "▸") else " " });
        var cx = r.x;
        cx += ui.putStr(cx, r.y, r.w, prefix, Theme.withFg(style, if (is_anchor) t.warn_fg.fg else t.muted.fg));
        _ = ui.putStr(cx, r.y, r.right() -| cx, ui.clipStr(p.lines[idx], r.right() -| cx), Theme.withFg(style, t.fg.fg));
    }
}

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "numbered lines around the definition, the anchor marked" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    var scroll: usize = 0;
    const lines = [_][]const u8{ "fn a() {}", "", "fn target() {", "}" };
    draw(f.ui(), f.full(), &scroll, .{ .title = "src/lib.rs", .lines = &lines, .first_line = 10, .highlight = 2 });
    try f.expectContains("✦ peek · src/lib.rs · Esc closes");
    try f.expectContains("  11   fn a() {}");
    try f.expectContains("  13 ▸ fn target() {");
}
