//! The results pane's paint (`Pane.tests`, Playwright or `dotnet test`):
//! the command on the first row, then — running — `⟳ running…`; failed
//! — the error; done — a `✓ ✗ ≈ ⊘ ≋` tally, the tool's own tally line
//! when it printed one, a width-aware key hint, a rule, and the
//! rows: file headers, one line per spec (status glyph, `≋` when the
//! history says it wobbles, `suite › title`, the duration, `file:line`
//! when the headers are off), a failure's error lines beneath it and
//! an *open trace* launcher when one was kept. Every row registers
//! `.script_hit{ pane, id = row }`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const ids = @import("../core/ids.zig");
const tests_pane = @import("../app/tests_pane.zig");

const Style = vaxis.Style;
const PaneId = ids.PaneId;

pub const Props = struct {
    p: *tests_pane.TestsPane,
    focused: bool,
    /// Per `run.tests` index: the history calls it wobbly.
    wobbly: []const bool,
    /// What the header names while running / errored.
    command: []const u8,
};

pub fn draw(ui: Ui, pane: PaneId, area: Rect, pr: Props) void {
    const t = ui.theme;
    const p = pr.p;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    const cmd: []const u8 = if (p.state == .done and p.run.command.len > 0) p.run.command else pr.command;
    var head_style = Theme.onBg(t.info_fg, t.bg.bg);
    head_style.bold = true;
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(ui.fmt("{s} {s}", .{ if (ui.ascii) ">" else "▸", cmd }), area.w), head_style);
    if (area.h < 2) return;
    var y: u16 = 1;
    switch (p.state) {
        .running => {
            var s = Theme.onBg(t.warn_fg, t.bg.bg);
            s.bold = true;
            _ = ui.putStr(area.x, area.y + y, area.w, ui.clipStr(if (ui.ascii) "  ~  running..." else "  ⟳  running…", area.w), s);
        },
        .failed => {
            var s = Theme.onBg(t.error_fg, t.bg.bg);
            s.bold = true;
            _ = ui.putStr(area.x, area.y + y, area.w, ui.clipStr(ui.fmt("  {s} {s} errored:", .{ if (ui.ascii) "x" else "✗", p.runner.label() }), area.w), s);
            y += 1;
            var lines = std.mem.splitScalar(u8, p.err, '\n');
            while (lines.next()) |l| : (y += 1) {
                if (y >= area.h) break;
                _ = ui.putStr(area.x, area.y + y, area.w, ui.clipStr(ui.fmt("    {s}", .{l}), area.w), Theme.onBg(t.muted, t.bg.bg));
            }
        },
        .done => {
            drawTally(ui, area.row(y), p, pr.wobbly);
            y += 1;
            if (y >= area.h) return;
            if (p.run.summary.len > 0) {
                _ = ui.putStr(area.x, area.y + y, area.w, ui.clipStr(ui.fmt("  {s}", .{p.run.summary}), area.w), Theme.onBg(t.muted, t.bg.bg));
                y += 1;
                if (y >= area.h) return;
            }
            _ = ui.putStr(area.x, area.y + y, area.w, ui.clipStr(hint(area.w, p.sort, ui.ascii), area.w), Theme.onBg(t.muted, t.bg.bg));
            y += 1;
            if (y >= area.h) return;
            const rule = area.row(y);
            var x = rule.x;
            while (x < rule.right()) : (x += 1) _ = ui.putStr(x, rule.y, 1, if (ui.ascii) "-" else "─", Theme.onBg(t.muted, t.bg.bg));
            y += 1;
            if (y >= area.h) return;
            drawRows(ui, pane, Rect.init(area.x, area.y + y, area.w, area.h - y), p, pr.wobbly, pr.focused);
        },
    }
}

fn drawTally(ui: Ui, r: Rect, p: *const tests_pane.TestsPane, wobbly: []const bool) void {
    const t = ui.theme;
    var x = r.x + 2;
    const run = p.run;
    const Cell = struct { n: usize, glyph: []const u8, style: Style };
    var wob: usize = 0;
    for (wobbly) |w| wob += @intFromBool(w);
    var bold_err = Theme.onBg(t.error_fg, t.bg.bg);
    bold_err.bold = true;
    const cells = [_]Cell{
        .{ .n = run.count(.passed), .glyph = tests_pane.Status.passed.glyph(ui.ascii), .style = Theme.onBg(t.info_fg, t.bg.bg) },
        .{ .n = run.count(.failed), .glyph = tests_pane.Status.failed.glyph(ui.ascii), .style = bold_err },
        .{ .n = run.count(.flaky), .glyph = tests_pane.Status.flaky.glyph(ui.ascii), .style = Theme.onBg(t.warn_fg, t.bg.bg) },
        .{ .n = run.count(.skipped), .glyph = tests_pane.Status.skipped.glyph(ui.ascii), .style = Theme.onBg(t.muted, t.bg.bg) },
        .{ .n = wob, .glyph = if (ui.ascii) "~~" else "≋", .style = Theme.onBg(t.accent, t.bg.bg) },
    };
    for (cells) |c| {
        if (c.n == 0) continue;
        x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s} {d} ", .{ c.glyph, c.n }), c.style);
    }
    if (run.tests.len == 0) _ = ui.putStr(x, r.y, r.right() -| x, "(no tests)", Theme.onBg(t.muted, t.bg.bg));
}

/// Width-aware: the whole legend, a shorter one, the two keys that matter.
pub fn hint(w: u16, sort: tests_pane.Sort, ascii: bool) []const u8 {
    _ = ascii;
    return switch (sort) {
        .file_line => if (w >= 110) "  ↵ open · t trace · h heal (Claude) · r re-run · a all · f file · R last-failed · s sort [file:line] · esc close" else if (w >= 60) "  ↵ open · t trace · r re-run · a all · R last-failed · s [file:line]" else if (w >= 32) "  ↵ open · r re-run · esc" else "  ↵ open · r run",
        .duration_desc => if (w >= 110) "  ↵ open · t trace · h heal (Claude) · r re-run · a all · f file · R last-failed · s sort [slowest] · esc close" else if (w >= 60) "  ↵ open · t trace · r re-run · a all · R last-failed · s [slowest]" else if (w >= 32) "  ↵ open · r re-run · esc" else "  ↵ open · r run",
    };
}

fn drawRows(ui: Ui, pane: PaneId, body: Rect, p: *tests_pane.TestsPane, wobbly: []const bool, focused: bool) void {
    const t = ui.theme;
    if (p.rows.len == 0) return;
    const win = list_panel.scrollWindow(&p.scroll, p.cursor, p.rows.len, body.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < p.rows.len and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const r = body.row(y);
        const row = p.rows[i];
        const on_cursor = i == p.cursor and focused;
        const bg = if (on_cursor) t.cursor_line.bg else t.bg.bg;
        if (on_cursor) ui.fill(r, t.cursor_line);
        switch (row) {
            .global_err => |g| _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(ui.fmt("  ! {s}", .{g}), r.w), Theme.onBg(t.error_fg, bg)),
            .file => |f| {
                var s = Theme.onBg(t.accent, bg);
                s.bold = true;
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(f, r.w), s);
            },
            .case => |ci| {
                const tc = p.run.tests[ci];
                var x = r.x;
                x += ui.putStr(x, r.y, r.w, if (on_cursor) (if (ui.ascii) " > " else " ▶ ") else "   ", Theme.onBg(t.warn_fg, bg));
                const glyph_style = switch (tc.status) {
                    .passed => Theme.onBg(t.info_fg, bg),
                    .failed => Theme.onBg(t.error_fg, bg),
                    .flaky => Theme.onBg(t.warn_fg, bg),
                    .skipped => Theme.onBg(t.muted, bg),
                };
                x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s} ", .{tc.status.glyph(ui.ascii)}), glyph_style);
                if (ci < wobbly.len and wobbly[ci]) {
                    var ws = Theme.onBg(t.accent, bg);
                    ws.bold = true;
                    x += ui.putStr(x, r.y, r.right() -| x, if (ui.ascii) "~~ " else "≋ ", ws);
                }
                if (tc.suite_path.len > 0) x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s} › ", .{tc.suite_path}), Theme.onBg(t.muted, bg));
                var name = Theme.onBg(if (tc.status == .skipped) t.muted else t.fg, bg);
                name.bold = tc.status == .failed;
                x += ui.putStr(x, r.y, r.right() -| x, ui.clipStr(tc.title, r.right() -| x), name);
                if (tc.duration_ms > 0) x += ui.putStr(x, r.y, r.right() -| x, ui.fmt("  {d} ms", .{tc.duration_ms}), Theme.onBg(t.muted, bg));
                if (p.sort != .file_line) _ = ui.putStr(x, r.y, r.right() -| x, ui.fmt("  {s}:{d}", .{ tc.file, tc.line }), Theme.onBg(t.muted, bg));
            },
            .err_line => |e| _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(ui.fmt("      {s}", .{e.text}), r.w), Theme.onBg(t.error_fg, bg)),
            .trace => _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(if (ui.ascii) "      > open trace (npx playwright show-trace)" else "      ▸ open trace (npx playwright show-trace)", r.w), Theme.onBg(t.accent, bg)),
        }
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
    }
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the results pane paints the command, the tally, headers, signed rows, the error and the trace row, one hit per row" {
    var f = try Fixture.init(120, 14);
    defer f.deinit();
    var p = try tests_pane.TestsPane.init(testing.allocator);
    defer p.deinit(testing.allocator, testing.io);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var run = try tests_pane.parseReport(p.snapshot.allocator(), tests_pane.fixture_report);
    run.command = "npx playwright test --reporter=json --trace=retain-on-failure";
    p.run = run;
    p.state = .done;
    try p.rebuildRows();
    p.cursor = 3;
    const wobbly = [_]bool{ false, true, false, false };
    draw(f.ui(), 7, f.full(), .{ .p = &p, .focused = true, .wobbly = &wobbly, .command = "" });
    try f.expectRow(0, "▸ npx playwright test --reporter=json --trace=retain-on-failure");
    try f.expectRow(1, "  ✓ 1 ✗ 1 ≈ 1 ⊘ 1 ≋ 1");
    try f.expectContains("s sort [file:line]");
    try f.expectRow(4, "  ! Error: config broke");
    try f.expectRow(5, "login.spec.ts");
    try f.expectRow(6, "   ✓ auth › logs in  120 ms");
    try f.expectRow(7, " ▶ ✗ ≋ auth › rejects bad password  30 ms");
    try f.expectRow(8, "      Error: expect(received).toBe(expected)");
    try f.expectRow(10, "      ▸ open trace (npx playwright show-trace)");
    try f.expectRow(12, "cart.spec.ts");
    try f.expectRow(13, "   ≈ adds  410 ms");
    try testing.expectEqual(@as(u32, 3), f.hits.at(5, 7).?.script_hit.id);
    try testing.expectEqual(@as(u32, 6), f.hits.at(5, 10).?.script_hit.id);
    try testing.expect(f.bgEql(2, 7, f.theme.cursor_line));
    try testing.expect(f.hits.at(5, 3) == null);

    // Running and errored states.
    p.state = .running;
    draw(f.ui(), 7, f.full(), .{ .p = &p, .focused = true, .wobbly = &.{}, .command = "npx playwright test --reporter=json --trace=retain-on-failure a.spec.ts" });
    try f.expectRow(0, "▸ npx playwright test --reporter=json --trace=retain-on-failure a.spec.ts");
    try f.expectRow(1, "  ⟳  running…");
    p.state = .failed;
    p.err = "running `npx playwright test`: FileNotFound\nsecond";
    draw(f.ui(), 7, f.full(), .{ .p = &p, .focused = true, .wobbly = &.{}, .command = "cmd" });
    try f.expectRow(1, "  ✗ playwright errored:");
    try f.expectRow(2, "    running `npx playwright test`: FileNotFound");
    try f.expectRow(3, "    second");
    // Narrow: the short hint.
    try testing.expectEqualStrings("  ↵ open · r re-run · esc", hint(40, .file_line, false));
    try testing.expectEqualStrings("  ↵ open · r run", hint(20, .duration_desc, false));
}
