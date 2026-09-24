//! The answer pane (`Pane.ai`): a title row with the job's status and
//! the keys, the prompt dimmed, a rule, then the answer wrapped to the
//! width and scrolled by the app. Registers the body as `.script_hit`
//! rows so a click focuses the pane and the wheel reaches it.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const text_mod = @import("text.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;

pub const Props = struct {
    title: []const u8,
    status: []const u8,
    prompt: []const u8,
    answer: []const u8,
    err: ?[]const u8,
    scroll: usize,
    focused: bool,
    running: bool,
};

/// How many prompt rows the header keeps.
pub const prompt_rows: u16 = 2;

/// Paints the pane; returns the number of answer rows that did not
/// fit (so the app can clamp `scroll`).
pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: Props) u16 {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return 0;
    const title_style = Theme.onBg(if (p.focused) th.accent else th.muted, th.panel_bg.bg);
    const head = area.row(0);
    ui.fill(head, th.panel_bg);
    const dot: []const u8 = if (p.running) (if (ui.ascii) "*" else "●") else " ";
    // Every key stays on the row as the pane narrows: the words go
    // first (down to the bare letters), then the title (the tab names
    // the pane too). A half-width split used to clip after `c cance…`,
    // so `a` apply, `p` promote and `y` yank were never shown.
    const tiers = [_][]const u8{
        ui.fmt(" {s} {s} · {s} · r re-ask · c cancel · a apply · p promote · y yank · q close ", .{ dot, p.title, p.status }),
        ui.fmt(" {s} {s} · {s} · r re-ask  c cancel  a apply  p promote  y yank  q close ", .{ dot, p.title, p.status }),
        ui.fmt(" {s} {s} · {s} · r c a p y q ", .{ dot, p.title, p.status }),
        ui.fmt(" {s} {s} · r c a p y q ", .{ dot, p.status }),
    };
    var title = tiers[tiers.len - 1];
    for (tiers) |cand| if ((std.unicode.utf8CountCodepoints(cand) catch cand.len) <= head.w) {
        title = cand;
        break;
    };
    _ = ui.putStr(head.x, head.y, head.w, ui.clipStr(title, head.w), title_style);
    ui.hit(head, .{ .script_hit = .{ .pane = pane, .id = 0 } });
    if (area.h < 2) return 0;
    var body = area.splitTop(1).rest;
    // The prompt, dimmed, at most `prompt_rows`.
    const dim = Theme.onBg(th.muted, th.bg.bg);
    var lines = std.mem.splitScalar(u8, p.prompt, '\n');
    var shown: u16 = 0;
    while (lines.next()) |line| {
        if (shown >= prompt_rows or body.h == 0) break;
        const r = body.row(0);
        _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(if (shown == 0) ui.fmt("> {s}", .{line}) else ui.fmt("  {s}", .{line}), r.w -| 1), dim);
        body = body.splitTop(1).rest;
        shown += 1;
    }
    if (body.h > 0) {
        const r = body.row(0);
        ui.hrule(r.x, r.y, r.w, Theme.onBg(th.border, th.bg.bg));
        body = body.splitTop(1).rest;
    }
    if (body.isEmpty()) return 0;
    // The answer, or the failure, wrapped to the body's width.
    const content: []const u8 = if (p.err) |e| ui.fmt("✗ {s}", .{e}) else if (p.answer.len == 0 and p.running) "…" else p.answer;
    const style = if (p.err != null) Theme.onBg(th.error_fg, th.bg.bg) else Theme.onBg(th.fg, th.bg.bg);
    const segs = [_]vaxis.Segment{.{ .text = content, .style = style }};
    const inner = Rect.init(body.x + 1, body.y, body.w -| 2, body.h);
    const total = text_mod.measure(&segs, inner.w, .{ .wrap = .word }, ui.canvas.widthMethod());
    const skip: u16 = @intCast(@min(p.scroll, @as(usize, total -| inner.h)));
    _ = ui.canvas.text(inner, &segs, .{ .wrap = .word, .scroll_y = skip });
    var y: u16 = 0;
    while (y < body.h) : (y += 1) ui.hit(body.row(y), .{ .script_hit = .{ .pane = pane, .id = 1 + @as(u32, y) } });
    return total -| inner.h;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the header keeps every key as the pane narrows: the words shrink first, then the title goes" {
    const props: Props = .{ .title = "ai: explain", .status = "done", .prompt = "p", .answer = "a", .err = null, .scroll = 0, .focused = true, .running = false };
    var wide = try Fixture.init(100, 6);
    defer wide.deinit();
    _ = draw(wide.ui(), 3, wide.full(), props);
    try wide.expectContains("ai: explain · done · r re-ask · c cancel · a apply · p promote · y yank · q close");
    var mid = try Fixture.init(80, 6);
    defer mid.deinit();
    _ = draw(mid.ui(), 3, mid.full(), props);
    try mid.expectContains("ai: explain · done · r re-ask  c cancel  a apply  p promote  y yank  q close");
    // A half-width split beside an editor.
    var half = try Fixture.init(45, 6);
    defer half.deinit();
    _ = draw(half.ui(), 3, half.full(), props);
    try half.expectContains("ai: explain · done · r c a p y q");
    var narrow = try Fixture.init(24, 6);
    defer narrow.deinit();
    _ = draw(narrow.ui(), 3, narrow.full(), props);
    try narrow.expectContains("done · r c a p y q");
    try narrow.expectLacks("ai: explain");
}

test "the answer pane paints the title, the prompt, the rule and the answer; a failure reads red" {
    var f = try Fixture.init(60, 10);
    defer f.deinit();
    _ = draw(f.ui(), 3, f.full(), .{ .title = "ai: ask", .status = "done", .prompt = "why?", .answer = "because.", .err = null, .scroll = 0, .focused = true, .running = false });
    try f.expectContains("ai: ask");
    try f.expectContains("> why?");
    try f.expectContains("because.");
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 0).?.script_hit.id);
    try testing.expect(f.hits.at(5, 5).? == .script_hit);
    f.hits.reset();
    _ = draw(f.ui(), 3, f.full(), .{ .title = "ai: fix", .status = "failed", .prompt = "p", .answer = "", .err = "boom", .scroll = 0, .focused = false, .running = false });
    try f.expectContains("✗ boom");
    // A long answer overflows and reports the rows that did not fit.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var long: std.ArrayList(u8) = .empty;
    for (0..40) |i| try long.print(arena.allocator(), "line {d}\n", .{i});
    const over = draw(f.ui(), 3, f.full(), .{ .title = "t", .status = "done", .prompt = "p", .answer = long.items, .err = null, .scroll = 0, .focused = true, .running = false });
    try testing.expect(over > 0);
    try f.expectContains("line 0");
    try f.expectLacks("line 39");
    _ = draw(f.ui(), 3, f.full(), .{ .title = "t", .status = "done", .prompt = "p", .answer = long.items, .err = null, .scroll = 100, .focused = true, .running = false });
    try f.expectContains("line 39");
}
