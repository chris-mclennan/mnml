//! `Pane.marketplace` — the listing: ` [kind] label  id  vX  — description`
//! with an `installed` / `installing…` note, the selected row's detail
//! (source, kind, id, description) when open, a spinner in the title
//! while a fetch runs, and the sources' problems under the rows. Every
//! row registers `.script_hit{ pane, id = row }`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const ids = @import("../core/ids.zig");

pub const PaneId = ids.PaneId;

pub const Row = struct {
    kind: []const u8,
    id: []const u8,
    label: []const u8,
    description: []const u8,
    version: []const u8,
    source: []const u8,
    installed: bool,
    installing: bool,
    selected: bool,
    detail: bool,
};

pub const Props = struct {
    rows: []const Row,
    scroll: *usize,
    focused: bool,
    fetching: bool,
    problems: []const []const u8 = &.{},
    enabled: bool = true,
};

pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: Props) void {
    const th = ui.theme;
    ui.fill(area, th.bg);
    if (area.isEmpty()) return;
    const head = area.row(0);
    ui.fill(head, th.panel_bg);
    const title = if (p.fetching) ui.fmt("MARKETPLACE · fetching{s}", .{if (ui.ascii) "..." else "…"}) else ui.fmt("MARKETPLACE ({d} available)", .{p.rows.len});
    _ = ui.putStr(head.x + 1, head.y, head.w -| 2, ui.clipStr(title, head.w -| 2), Theme.onBg(th.muted, th.panel_bg.bg));
    if (area.h >= 2) {
        const hr = area.row(1);
        const hint: []const u8 = "enter / i install · d details · y copy id · r refresh · I installed";
        _ = ui.putStr(hr.x + 1, hr.y, hr.w -| 2, ui.clipStr(hint, hr.w -| 2), th.muted);
    }
    var body = area;
    body.y += 2;
    body.h -|= 2;
    if (!p.enabled) {
        _ = ui.putStr(body.x + 1, body.y, body.w -| 2, "The marketplace is off (marketplace.enabled = false).", th.muted);
        return;
    }
    if (p.rows.len == 0) {
        const msg: []const u8 = if (p.fetching) "Fetching the sources…" else "Nothing listed. r fetches the sources again.";
        _ = ui.putStr(body.x + 1, body.y, body.w -| 2, msg, th.muted);
        drawProblems(ui, body, 2, p.problems);
        return;
    }
    var cursor: usize = 0;
    for (p.rows, 0..) |r, i| if (r.selected) {
        cursor = i;
    };
    const win = list_panel.scrollWindow(p.scroll, cursor, p.rows.len, @max(body.h, 1));
    var y: u16 = 0;
    var i: usize = win.first;
    while (i < p.rows.len and y < body.h) : (i += 1) {
        const r = p.rows[i];
        const rr = body.row(y);
        const style = list_panel.rowStyle(th, r.selected);
        ui.fill(rr, style);
        ui.hit(rr, .{ .script_hit = .{ .pane = pane, .id = @intCast(i) } });
        if (r.selected) {
            const marker = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
            _ = ui.putStr(rr.x, rr.y, 1, marker, Theme.withFg(style, if (p.focused) th.accent.fg else th.muted.fg));
        }
        var x = rr.x + 1;
        const kind = ui.fmt("[{s}] ", .{r.kind});
        x += ui.putStr(x, rr.y, rr.right() -| x, kind, Theme.withFg(style, th.muted.fg));
        x += ui.putStr(x, rr.y, rr.right() -| x, r.label, Theme.withFg(style, th.fg.fg));
        x += 2;
        const meta = ui.fmt("{s}{s}{s}", .{ r.id, if (r.version.len > 0) "  v" else "", r.version });
        x += ui.putStr(x, rr.y, rr.right() -| x, ui.clipStr(meta, rr.right() -| x), Theme.withFg(style, th.muted.fg));
        if (r.description.len > 0 and rr.right() > x + 6) {
            x += ui.putStr(x, rr.y, rr.right() -| x, "  — ", Theme.withFg(style, th.muted.fg));
            x += ui.putStr(x, rr.y, rr.right() -| x, ui.clipStr(r.description, rr.right() -| x), Theme.withFg(style, th.muted.fg));
        }
        const note: ?[]const u8 = if (r.installing) "installing…" else if (r.installed) "installed" else null;
        if (note) |n| {
            const nw = ui.width(n);
            if (rr.right() > x + nw + 2) _ = ui.putStrRight(rr.right() - 1, rr.y, nw, n, Theme.withFg(style, th.info_fg.fg));
        }
        y += 1;
        if (r.detail) {
            const Line = struct { k: []const u8, v: []const u8 };
            const lines = [_]Line{
                .{ .k = "source", .v = r.source },
                .{ .k = "kind", .v = r.kind },
                .{ .k = "id", .v = r.id },
                .{ .k = "description", .v = r.description },
            };
            for (lines) |l| {
                if (y >= body.h) break;
                if (l.v.len == 0) continue;
                const dr = body.row(y);
                var dx = dr.x + 4;
                dx += ui.putStr(dx, dr.y, dr.right() -| dx, l.k, th.muted);
                dx += ui.putStr(dx, dr.y, dr.right() -| dx, ": ", th.muted);
                _ = ui.putStr(dx, dr.y, dr.right() -| dx, ui.clipStr(l.v, dr.right() -| dx), th.fg);
                y += 1;
            }
        }
    }
    drawProblems(ui, body, y + 1, p.problems);
}

fn drawProblems(ui: Ui, body: Rect, start: u16, problems: []const []const u8) void {
    var y = start;
    for (problems) |p| {
        if (y >= body.h) return;
        const rr = body.row(y);
        _ = ui.putStr(rr.x + 1, rr.y, rr.w -| 2, ui.clipStr(ui.fmt("! {s}", .{p}), rr.w -| 2), ui.theme.warn_fg);
        y += 1;
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "rows paint with kind, meta, note and detail; the fetching title spins" {
    var f = try Fixture.init(80, 10);
    defer f.deinit();
    var scroll: usize = 0;
    const rows = [_]Row{
        .{ .kind = "launcher", .id = "hello", .label = "Hello", .description = "The sample", .version = "0.1.0", .source = "acme", .installed = true, .installing = false, .selected = true, .detail = true },
        .{ .kind = "app", .id = "mnml-jira", .label = "mnml-jira", .description = "", .version = "", .source = "acme", .installed = false, .installing = true, .selected = false, .detail = false },
    };
    draw(f.ui(), 4, f.full(), .{ .rows = &rows, .scroll = &scroll, .focused = true, .fetching = false, .problems = &.{"crates.io: not searched"} });
    try f.expectContains("MARKETPLACE (2 available)");
    try f.expectContains("[launcher] Hello  hello  v0.1.0  — The sample");
    try f.expectContains("installed");
    try f.expectContains("source: acme");
    try f.expectContains("[app] mnml-jira  mnml-jira");
    try f.expectContains("installing…");
    try f.expectContains("! crates.io: not searched");
    try testing.expectEqual(@as(u32, 1), f.hits.at(3, 7).?.script_hit.id);
    var g = try Fixture.init(40, 3);
    defer g.deinit();
    draw(g.ui(), 4, g.full(), .{ .rows = &.{}, .scroll = &scroll, .focused = true, .fetching = true });
    try g.expectContains("MARKETPLACE · fetching…");
    try g.expectContains("Fetching the sources…");
}
