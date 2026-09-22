//! The REQUESTS view's paint (`Pane.requests`): a header with what the
//! last hour cost per service and who has been drawing on the buckets,
//! the filter pill, then one row per request, newest first —
//! `time · integration · reason · method path · status · ms · wait`.
//!
//! The columns are fixed rather than proportional: every one of them
//! is being read as a number against the row above it, and a column
//! that moves with its content cannot be. The path takes whatever is
//! left, because it is the only field whose length says anything.
//!
//! Every row registers `.script_hit{ pane, id = row }`, so a click
//! focuses it, a second click opens its whole line, and a right-click
//! copies its path.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const list_panel = @import("list_panel.zig");
const ids = @import("../core/ids.zig");
const requests = @import("../app/requests.zig");

const Style = vaxis.Style;
const PaneId = ids.PaneId;

pub const hint = "  / filter   r reload   ⏎ full line   y copy path   esc close";

/// Rows the header and the hint take before the first request.
const head_rows: u16 = 5;

pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: *requests.RequestsPane, focused: bool) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;

    var head = Theme.onBg(if (p.rows.len > 0) t.accent else t.muted, t.bg.bg);
    head.bold = true;
    _ = ui.putStr(area.x, area.y, area.w, ui.clipStr(ui.fmt("  {s} REQUESTS ({d})", .{ if (ui.ascii) "<>" else "\u{f0aee}", p.shown.len }), area.w), head);
    if (area.h < 2) return;

    // Per service, the last hour: what it cost, what came back 429,
    // how long the bucket held it, and how much a cache saved.
    _ = ui.putStr(area.x, area.y + 1, area.w, ui.clipStr(totalsLine(ui, p), area.w), Theme.onBg(t.fg, t.bg.bg));
    if (area.h < 3) return;
    _ = ui.putStr(area.x, area.y + 2, area.w, ui.clipStr(programsLine(ui, p), area.w), Theme.onBg(t.muted, t.bg.bg));
    if (area.h < 4) return;
    // Who is handing the tokens out. A queue that is deep and a budget
    // that is nearly gone are the two things a person opens this view
    // to find out, and they are not in the rows.
    _ = ui.putStr(area.x, area.y + 3, area.w, ui.clipStr(brokersLine(ui, p), area.w), Theme.onBg(t.muted, t.bg.bg));
    if (area.h < 5) return;

    if (p.filtering or p.filter.items.len > 0) {
        var pill = Theme.onBg(if (p.filtering) t.accent else t.muted, t.bg.bg);
        pill.bold = p.filtering;
        _ = ui.putStr(area.x, area.y + 4, area.w, ui.clipStr(ui.fmt("  {s} {s}{s}", .{
            if (ui.ascii) "/" else "\u{f0349}",
            p.filter.items,
            if (p.filtering) "\u{2588}" else "",
        }), area.w), pill);
    } else {
        _ = ui.putStr(area.x, area.y + 4, area.w, ui.clipStr(overlay.hintText(ui, hint), area.w), Theme.onBg(t.muted, t.bg.bg));
    }
    if (area.h <= head_rows) return;

    if (p.shown.len == 0) {
        const line = if (p.rows.len == 0)
            ui.fmt("  nothing has been requested yet — integrations write to {s}", .{p.dir})
        else
            ui.fmt("  no request matches \"{s}\"", .{p.filter.items});
        _ = ui.putStr(area.x, area.y + head_rows, area.w, ui.clipStr(line, area.w), Theme.onBg(t.info_fg, t.bg.bg));
        return;
    }

    const body = Rect.init(area.x, area.y + head_rows, area.w, area.h - head_rows);
    const win = list_panel.scrollWindow(&p.scroll, p.cursor, p.shown.len, body.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < p.shown.len and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const idx = p.shown[i];
        const r = p.rows[idx];
        const line = body.row(y);
        const on_cursor = i == p.cursor and focused;
        const bg = if (on_cursor) t.cursor_line.bg else t.bg.bg;
        if (on_cursor) ui.fill(line, t.cursor_line);
        var x = line.x;
        x += ui.putStr(x, line.y, line.w, if (on_cursor) (if (ui.ascii) "> " else "\u{25B6} ") else "  ", Theme.onBg(t.accent, bg));
        x += ui.putStr(x, line.y, line.right() -| x, ui.fmt("{s}  ", .{clock(ui, r.ts)}), Theme.onBg(t.muted, bg));
        x += ui.putStr(x, line.y, line.right() -| x, pad(ui, r.integration, 16), Theme.onBg(t.fg, bg));
        x += ui.putStr(x, line.y, line.right() -| x, pad(ui, r.reason, 11), Theme.onBg(t.accent, bg));
        x += ui.putStr(x, line.y, line.right() -| x, pad(ui, r.method, 5), Theme.onBg(t.muted, bg));

        // The three numbers come off the right, so they line up
        // whatever the path did.
        const tail = ui.fmt("{s}  {s}  {s}", .{ statusText(ui, r), msText(ui, r.ms), waitText(ui, r) });
        const tail_w: u16 = @intCast(@min(tail.len, line.w));
        const path_w = (line.right() -| x) -| (tail_w + 2);
        var path_style = Theme.onBg(t.fg, bg);
        path_style.bold = on_cursor;
        _ = ui.putStr(x, line.y, path_w, ui.clipStr(r.path, path_w), path_style);
        _ = ui.putStrRight(line.right(), line.y, tail_w, tail, statusStyle(t, r, bg));
        ui.hit(line, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });

        // The whole line, under the row it belongs to: every field the
        // log holds, including the ones no column had room for.
        if (p.detail != null and p.detail.? == idx and y + 1 < body.h) {
            y += 1;
            const d = body.row(y);
            ui.fill(d, t.bg);
            _ = ui.putStr(d.x, d.y, d.w, ui.clipStr(ui.fmt("    {s}", .{r.raw}), d.w), Theme.onBg(t.muted, t.bg.bg));
        }
    }
}

/// `last hour — jira 27 req · 1 429 · 1.1s avg wait · 3 cached` per
/// service, busiest first.
fn totalsLine(ui: Ui, p: *const requests.RequestsPane) []const u8 {
    if (p.totals.len == 0) return "  last hour — nothing";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ui.arena, "  last hour — ") catch return "  last hour";
    for (p.totals, 0..) |s, i| {
        if (i > 0) out.appendSlice(ui.arena, "   ") catch return out.items;
        out.print(ui.arena, "{s} {d} req · {d} 429 · {s} avg wait · {d} cached", .{
            s.service, s.requests, s.throttled, secsText(ui, s.avgWaitMs()), s.cache_hits,
        }) catch return out.items;
    }
    return out.items;
}

/// `by program — mnml-jira 41 · bb.py 30 · mnml-bitbucket 12`. The
/// point of the line is that the programs are not all mnml's: a bucket
/// held by a script outside mnml looks identical from inside it.
fn programsLine(ui: Ui, p: *const requests.RequestsPane) []const u8 {
    if (p.programs.len == 0) return "  by program — no draws recorded on the shared buckets";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ui.arena, "  by program — ") catch return "  by program";
    const shown = @min(p.programs.len, 4);
    for (p.programs[0..shown], 0..) |g, i| {
        if (i > 0) out.appendSlice(ui.arena, " · ") catch return out.items;
        out.print(ui.arena, "{s} {d}", .{ g.program, g.draws }) catch return out.items;
    }
    if (p.programs.len > shown) {
        var rest: u32 = 0;
        for (p.programs[shown..]) |g| rest += g.draws;
        out.print(ui.arena, " · other {d}", .{rest}) catch return out.items;
    }
    return out.items;
}

/// `broker — jira on · queue 3 · 42% budget   bitbucket off` per
/// service. `on` is this mnml serving it; `client` is another process
/// serving it and this one queueing there; `off` is nobody, which
/// means every client is on the file bucket and its first-come order.
fn brokersLine(ui: Ui, p: *const requests.RequestsPane) []const u8 {
    if (p.brokers.len == 0) return "  broker — not started";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.appendSlice(ui.arena, "  broker — ") catch return "  broker";
    for (p.brokers, 0..) |b, i| {
        if (i > 0) out.appendSlice(ui.arena, "   ") catch return out.items;
        if (b.where == .off) {
            out.print(ui.arena, "{s} off", .{b.service}) catch return out.items;
            continue;
        }
        out.print(ui.arena, "{s} {s} · queue {d} · {d}% budget", .{
            b.service,
            if (b.where == .hosted) "on" else "client",
            b.queue,
            b.budget_pct,
        }) catch return out.items;
    }
    return out.items;
}

/// `14:22:03` out of a wall-clock stamp. A request log is read against
/// the clock on the wall, never against an age.
fn clock(ui: Ui, ts: f64) []const u8 {
    if (ts <= 0) return "--:--:--";
    const secs: u64 = @intFromFloat(@max(ts, 0));
    const day = secs % 86400;
    return ui.fmt("{d:0>2}:{d:0>2}:{d:0>2}", .{ day / 3600, (day % 3600) / 60, day % 60 });
}

/// `s` in a column `w` wide, clipped and padded — a table whose
/// columns move with their content cannot be read down.
fn pad(ui: Ui, s: []const u8, w: u16) []const u8 {
    const cut = ui.clipStr(s, w);
    const spaces = "                         ";
    const n = @min(@as(usize, w) -| cut.len, spaces.len);
    return ui.fmt("{s}{s}", .{ cut, spaces[0..n] });
}

fn statusText(ui: Ui, r: requests.Row) []const u8 {
    const st = r.status orelse return "   —";
    if (r.retry_of > 0) return ui.fmt("{d}r{d}", .{ st, r.retry_of });
    return ui.fmt(" {d}", .{st});
}

fn msText(ui: Ui, ms: u64) []const u8 {
    if (ms < 1000) return ui.fmt("{d:>4}ms", .{ms});
    return ui.fmt("{d:>4.1}s", .{@as(f64, @floatFromInt(ms)) / 1000.0});
}

/// The wait, and — where there was one — what it was for. A wait with
/// no cause reads as the network being slow, which is the wrong answer
/// nearly every time.
fn waitText(ui: Ui, r: requests.Row) []const u8 {
    if (std.mem.eql(u8, r.cache, "hit")) return "   cached";
    if (r.wait_ms == 0) return "        ·";
    const w = secsText(ui, r.wait_ms);
    if (std.mem.eql(u8, r.waited_for, "cooldown")) return ui.fmt("{s} 429", .{w});
    if (std.mem.eql(u8, r.waited_for, "gave_up")) return ui.fmt("{s} open", .{w});
    return ui.fmt("{s} bkt", .{w});
}

fn secsText(ui: Ui, ms: u64) []const u8 {
    if (ms == 0) return "0s";
    if (ms < 1000) return ui.fmt("{d}ms", .{ms});
    return ui.fmt("{d:.1}s", .{@as(f64, @floatFromInt(ms)) / 1000.0});
}

fn statusStyle(t: *const Theme, r: requests.Row, bg: vaxis.Cell.Color) Style {
    const st = r.status orelse return Theme.onBg(t.error_fg, bg);
    if (st == 429) return Theme.onBg(t.warn_fg, bg);
    if (st >= 400) return Theme.onBg(t.error_fg, bg);
    if (std.mem.eql(u8, r.cache, "hit")) return Theme.onBg(t.info_fg, bg);
    return Theme.onBg(t.muted, bg);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "the view paints the hour's totals, who drew on the buckets, one row per request and the full line under it" {
    var f = try Fixture.init(120, 12);
    defer f.deinit();
    var p = requests.RequestsPane.init(testing.allocator);
    defer p.deinit();
    const a = p.snapshot.allocator();
    const rows = try a.alloc(requests.Row, 3);
    // 14:22:03 on any day — the clock column is a wall clock, not an age.
    rows[0] = .{ .ts = 51723, .service = "jira", .integration = "mnml-jira", .reason = "pane_open", .method = "GET", .host = "acme.atlassian.net", .path = "/rest/api/3/search/jql", .status = 200, .ms = 412, .wait_ms = 3030, .waited_for = "tokens", .cache = "miss", .raw = "{\"ts\":51723,\"path\":\"/rest/api/3/search/jql\"}" };
    rows[1] = .{ .ts = 51722, .service = "jira", .integration = "mnml-jira", .reason = "refresh", .method = "GET", .host = "acme.atlassian.net", .path = "/rest/dev-status/latest/issue/detail", .status = 429, .ms = 90, .wait_ms = 30000, .waited_for = "cooldown", .retry_of = 1, .cache = "none", .raw = "{}" };
    rows[2] = .{ .ts = 51721, .service = "bitbucket", .integration = "mnml-bitbucket", .reason = "poll", .method = "GET", .host = "api.bitbucket.org", .path = "/2.0/repositories/acme/api/pullrequests", .status = 200, .ms = 1500, .wait_ms = 0, .cache = "hit", .raw = "{}" };
    p.rows = rows;
    p.shown = try a.dupe(u32, &.{ 0, 1, 2 });
    p.totals = try a.dupe(requests.ServiceTotals, &.{
        .{ .service = "jira", .requests = 27, .throttled = 1, .cache_hits = 0, .wait_total_ms = 29700 },
        .{ .service = "bitbucket", .requests = 7, .throttled = 0, .cache_hits = 3, .wait_total_ms = 0 },
    });
    p.programs = try a.dupe(requests.ProgramDraws, &.{
        .{ .program = "mnml-jira", .draws = 41 },
        .{ .program = "bb.py", .draws = 30 },
        .{ .program = "mnml-bitbucket", .draws = 12 },
    });
    p.brokers = try a.dupe(requests.BrokerLine, &.{
        .{ .service = "jira", .where = .hosted, .queue = 3, .budget_pct = 42 },
        .{ .service = "bitbucket", .where = .off },
    });
    p.cursor = 0;
    draw(f.ui(), 9, f.full(), &p, true);

    try f.expectRow(0, "  \u{f0aee} REQUESTS (3)");
    try f.expectRow(1, "  last hour — jira 27 req · 1 429 · 1.1s avg wait · 0 cached   bitbucket 7 req · 0 429 · 0s avg wait · 3 cached");
    // The line that makes a drained bucket attributable: not every
    // program on it is mnml's.
    try f.expectRow(2, "  by program — mnml-jira 41 · bb.py 30 · mnml-bitbucket 12");
    // Who is handing the tokens out: a deep queue and a nearly-spent
    // budget are the two things this view is opened to find out, and
    // neither of them is in the rows.
    try f.expectRow(3, "  broker — jira on · queue 3 · 42% budget   bitbucket off");
    try f.expectRow(4, "  / filter   r reload   ⏎ full line   y copy path   esc close");
    // The cursor row, its columns, and the wait blamed on the bucket.
    try f.expectRow(5, "▶ 14:22:03  mnml-jira       pane_open  GET  /rest/api/3/search/jql                                 200   412ms  3.0s bkt");
    // A 429 says so, and says it was a retry.
    try f.expectRow(6, "  14:22:02  mnml-jira       refresh    GET  /rest/dev-status/latest/issue/detail                429r1    90ms  30.0s 429");
    // A cache hit cost nothing and says that instead of a wait.
    try f.expectRow(7, "  14:22:01  mnml-bitbucket  poll       GET  /2.0/repositories/acme/api/pullrequests                200   1.5s     cached");
    // One hit per row, so a click lands on the row it looks like.
    try testing.expectEqual(@as(u32, 0), f.hits.at(3, 5).?.script_hit.id);
    try testing.expectEqual(@as(u32, 2), f.hits.at(3, 7).?.script_hit.id);
    try testing.expect(f.bgEql(2, 5, f.theme.cursor_line));

    // The whole line opens under the row it belongs to.
    p.detail = 1;
    p.cursor = 1;
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectRow(7, "    {}");

    // The filter pill replaces the hint while it is being typed.
    p.detail = null;
    try p.filter.appendSlice(testing.allocator, "429");
    p.filtering = true;
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectRow(4, "  \u{f0349} 429█");
}

test "an empty view says where the files would be; a filter that matches nothing says so" {
    var f = try Fixture.init(100, 9);
    defer f.deinit();
    var p = requests.RequestsPane.init(testing.allocator);
    defer p.deinit();
    p.dir = "/home/ada/.config/mnml/requests";
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectRow(0, "  \u{f0aee} REQUESTS (0)");
    try f.expectRow(1, "  last hour — nothing");
    try f.expectRow(2, "  by program — no draws recorded on the shared buckets");
    // Before the first reload there is nothing to say about a broker,
    // and the line says that rather than claiming one is off.
    try f.expectRow(3, "  broker — not started");
    try f.expectRow(5, "  nothing has been requested yet — integrations write to /home/ada/.config/mnml/requests");

    const a = p.snapshot.allocator();
    const rows = try a.alloc(requests.Row, 1);
    rows[0] = .{ .ts = 1, .service = "jira", .path = "/p" };
    p.rows = rows;
    p.shown = &.{};
    try p.filter.appendSlice(testing.allocator, "nope");
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectRow(5, "  no request matches \"nope\"");
}
