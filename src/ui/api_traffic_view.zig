//! The API TRAFFIC pane's paint (`Pane.api_traffic`): the caps header
//! (`BITBUCKET · last 1h · 412 requests · 89 % 304`) with the window
//! chip and the refresh chip, a tab per service, then three sections
//! off the prepared snapshot — nothing here reads a file:
//!
//!   NOW       the bucket, this hour against the hourly limit, mnml's
//!             day tally, the broker, the event feed, the shared cache;
//!   TIMELINE  requests a minute, one column per minute (or per run of
//!             minutes on a wide window), stacked by program in the
//!             shared accent ladder, the hourly limit drawn across;
//!   WHO       one row per program, busiest first.
//!
//! The strip is eighth-block cells: a cell holds the series that
//! covers its bottom in the foreground and the one above it in the
//! background, so two programs meeting inside a cell both show. Every
//! part registers a `.script_hit` (`app/api_traffic.zig`'s ids); the
//! hover copy is `info_view_copy/api_traffic.zig`.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const header = @import("header.zig");
const border = @import("border.zig");
const chip = @import("chip.zig");
const hit = @import("hit.zig");
const overlay = @import("overlay.zig");
const empty_state = @import("empty_state.zig");
const list_panel = @import("list_panel.zig");
const accent_color = @import("accent_color.zig");
const ids = @import("../core/ids.zig");
const traffic = @import("../app/api_traffic.zig");
const reader = @import("../app/api_traffic_reader.zig");
const columns = @import("mnml_sdk").pane.columns;
const cellWidth = @import("mnml_sdk").pane.width;

const Style = vaxis.Style;
const Color = vaxis.Color;
const PaneId = ids.PaneId;

pub const hint = "  tab service   w window   ←→ minute   ↑↓ program   y pid   r reload   esc close";

/// The colour of series `i`: the shared accent ladder, by rank.
/// `other` (the last slot) is the muted ink — it is everybody else,
/// and no one colour is theirs.
pub fn seriesColor(t: *const Theme, i: usize, n: usize, other: bool) Color {
    _ = n;
    if (other) return t.muted.fg;
    return accent_color.resolve(accent_color.auto(i), t) orelse t.accent.fg;
}

fn seriesStyle(t: *const Theme, w: *const reader.WinSnap, i: usize, bg: Color) Style {
    const other = i == reader.max_series or (i < w.series.len and std.mem.eql(u8, w.series[i].label, "other") and i == w.series.len - 1 and w.who.len > reader.max_series);
    return .{ .fg = seriesColor(t, i, w.series.len, other), .bg = bg };
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, p: *traffic.ApiTrafficPane, focused: bool) void {
    const t = ui.theme;
    ui.fill(area, t.bg);
    if (area.isEmpty()) return;
    const snap = p.current();
    const win = p.currentWin();

    // ── the header ──
    const label = if (snap) |s| upper(ui, s.service) else "API TRAFFIC";
    const sub = if (win) |w| headerLine(ui, p.window, w) else if (p.loading) "· reading the logs…" else "";
    _ = header.draw(ui, area.row(0), .{
        .panel = .script,
        .label = label,
        .subtitle = sub,
        .mode_chip = chip.modeText(ui.arena, "window", p.window.label(), 3) catch null,
        .mode_kind = .sort,
        .bg = t.bg,
        .pane = pane,
        .focused = focused,
    });
    ui.hit(Rect.init(area.x, area.y, @min(ui.width(label) + 2, area.w), 1), .{ .script_hit = .{ .pane = pane, .id = traffic.hit_title } });
    if (area.h < 2) return;

    const r = p.result orelse {
        _ = empty_state.draw(ui, area.splitTop(1).rest, .{ .message = "reading the draws and request logs…" }, t.bg);
        return;
    };
    if (r.services.len == 0 or snap == null) {
        _ = empty_state.draw(ui, area.splitTop(1).rest, .{
            .message = "no API traffic recorded on this machine yet",
            .hint = "an integration's draws land in <service>-draws.jsonl beside its rate bucket; mnml's own requests in requests/<service>.jsonl",
        }, t.bg);
        return;
    }
    const s = snap.?;
    const w = win.?;

    drawTabs(ui, pane, area.row(1), p, r);
    var y: u16 = area.y + 2;
    const bottom = area.bottom();
    const rows_left = struct {
        fn f(yy: u16, b: u16) u16 {
            return b -| yy;
        }
    }.f;

    // How the height is shared: NOW keeps three rows, WHO at least
    // three, the strip what is left (3…16) — and a pane too short for
    // all of it drops the strip first, then NOW's detail rows.
    const total_h = rows_left(y, bottom);
    const hint_h: u16 = if (total_h >= 22) 1 else 0;
    const now_h: u16 = if (total_h >= 15) 5 else if (total_h >= 8) 2 else 0;
    const who_fixed: u16 = 2; // heading + column header
    const tl_fixed: u16 = 4; // heading + legend + axis + readout
    const room = total_h -| (now_h + who_fixed + hint_h + 3);
    var strip_h: u16 = 0;
    if (room >= tl_fixed + 3) strip_h = std.math.clamp((room - tl_fixed) / 2, 3, 16);
    if (strip_h > 0 and room < tl_fixed + strip_h) strip_h = 0;

    if (now_h > 0) {
        y += drawNow(ui, pane, Rect.init(area.x, y, area.w, now_h), s, r.now);
    }
    if (strip_h > 0) {
        y += drawTimeline(ui, pane, Rect.init(area.x, y, area.w, tl_fixed + strip_h), p, s, w, r.tz_offset, r.now);
    }
    const who_h = rows_left(y, bottom) -| hint_h;
    if (who_h > 0) drawWho(ui, pane, Rect.init(area.x, y, area.w, who_h), p, w, r.now, focused);
    if (hint_h > 0) {
        _ = ui.putStr(area.x, bottom - 1, area.w, ui.clipStr(overlay.hintText(ui, hint), area.w), Theme.onBg(t.muted, t.bg.bg));
    }
}

/// `· last 1h · 412 requests · 89 % 304 · 2 429 · 37 cached`.
pub fn headerLine(ui: Ui, window: reader.Window, w: *const reader.WinSnap) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.print(ui.arena, "· last {s} · {d} request{s}", .{ window.label(), w.requests, if (w.requests == 1) "" else "s" }) catch return "";
    if (w.not_modified_pct) |pct| out.print(ui.arena, " · {d:.0} % 304", .{pct}) catch {};
    if (w.throttled > 0) out.print(ui.arena, " · {d} 429", .{w.throttled}) catch {};
    if (w.cache_hits > 0) out.print(ui.arena, " · {d} cached", .{w.cache_hits}) catch {};
    return out.items;
}

fn upper(ui: Ui, s: []const u8) []const u8 {
    const out = ui.arena.alloc(u8, s.len) catch return s;
    return std.ascii.upperString(out, s);
}

/// ` Bitbucket 412 ` per service with files; the active one is the
/// accent pill, the others muted — the Integrations view's tabs.
fn drawTabs(ui: Ui, pane: PaneId, row: Rect, p: *const traffic.ApiTrafficPane, r: *const traffic.Result) void {
    const t = ui.theme;
    ui.fill(row, t.bg);
    var x = row.x + 1;
    const cur = p.current();
    for (r.services, 0..) |*s, i| {
        if (i >= traffic.max_tabs) break;
        const name = titleCase(ui, s.service);
        const text = ui.fmt(" {s} {d} ", .{ name, s.win(p.window).requests });
        const tw = ui.width(text);
        if (x + tw > row.right()) break;
        const active = cur != null and std.mem.eql(u8, cur.?.service, s.service);
        const style = if (active) t.chip_active else Theme.onBg(t.muted, t.bg.bg);
        _ = chip.paintTarget(ui, x, row.y, tw, text, style, .{ .script_hit = .{ .pane = pane, .id = traffic.hit_tab_base + @as(u32, @intCast(i)) } });
        x += tw + 1;
    }
}

/// The app-wide "this thing is that colour" mark (`list_panel`'s
/// marker, the pane rail's stripe), in the series' colour.
fn swatch(ui: Ui) []const u8 {
    return if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
}

fn titleCase(ui: Ui, s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const out = ui.arena.dupe(u8, s) catch return s;
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

fn sectionHeading(ui: Ui, pane: PaneId, r: Rect, text: []const u8, section: traffic.Section) void {
    const t = ui.theme;
    _ = ui.putStr(r.x + 1, r.y, r.w -| 1, ui.clipStr(text, r.w -| 1), header.labelStyle(t, t.bg));
    ui.hit(Rect.init(r.x, r.y, @min(ui.width(text) + 1, r.w), 1), .{ .script_hit = .{ .pane = pane, .id = traffic.hit_section_base + @intFromEnum(section) } });
}

fn nowHit(pane: PaneId, row: traffic.NowRow) hit.HitTarget {
    return .{ .script_hit = .{ .pane = pane, .id = traffic.hit_now_base + @intFromEnum(row) } };
}

/// NOW: the heading and up to three rows. Returns the rows used.
fn drawNow(ui: Ui, pane: PaneId, area: Rect, s: *const reader.ServiceSnap, now: f64) u16 {
    _ = now;
    const t = ui.theme;
    sectionHeading(ui, pane, area.row(0), "NOW", .now);
    if (area.h < 2) return 1;
    const n = s.now;
    const fg = Theme.onBg(t.fg, t.bg.bg);
    const muted = Theme.onBg(t.muted, t.bg.bg);
    const warn = Theme.onBg(t.warn_fg, t.bg.bg);

    // The bucket.
    {
        const r = area.row(1);
        const line = if (n.bucket) |b| ui.fmt("  bucket  {d:.1}/{d:.0} tokens · {d:.2}/s{s}{s}{s}", .{
            b.tokens,
            b.capacity,
            b.rate,
            if (b.cooldown_secs > 0) ui.fmt(" · cooling {s}", .{age(ui, b.cooldown_secs)}) else " · no cooldown",
            if (b.last_429_age) |a| ui.fmt(" · last 429 {s} ago", .{age(ui, a)}) else " · no 429 on record",
            if (b.throttles > 0) ui.fmt(" · {d} throttle{s}", .{ b.throttles, if (b.throttles == 1) "" else "s" }) else "",
        }) else "  bucket  no shared bucket file — every process on its own pacing";
        const style = if (n.bucket) |b| (if (b.cooldown_secs > 0) warn else fg) else muted;
        _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(line, r.w), style);
        ui.hit(r, nowHit(pane, .bucket));
    }
    if (area.h < 3) return 2;

    // This hour against the limit, and mnml's day.
    {
        const r = area.row(2);
        const pct: f64 = if (n.hourly_limit > 0) @as(f64, @floatFromInt(n.hour_requests)) * 100.0 / @as(f64, @floatFromInt(n.hourly_limit)) else 0;
        const line = ui.fmt("  hour    {d} of {d} limit ({d:.0} %){s}", .{
            n.hour_requests,
            n.hourly_limit,
            pct,
            if (n.tally_today) |d| ui.fmt(" · mnml today {d}", .{d}) else "",
        });
        _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(line, r.w), if (pct >= 85) warn else fg);
        ui.hit(r, nowHit(pane, .hour));
    }
    if (area.h < 4) return 3;

    // The 429s on the machine for this API, this hour.
    {
        const r = area.row(3);
        const th = n.throttles;
        const line = if (th.n == 0) "  throttles  none in the last hour" else ui.fmt("  throttles  {d} in the last hour · last {s} ago · {s}", .{ th.n, age(ui, th.last_age orelse 0), whoText(ui, th.by) });
        _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(line, r.w), if (th.n == 0) muted else warn);
        ui.hit(r, nowHit(pane, .throttles));
    }
    if (area.h < 5) return 4;

    // Broker · feed · cache, each its own hover.
    {
        const r = area.row(4);
        var x = r.x;
        const b = n.broker;
        const broker_text = switch (b.where) {
            .unknown => "  broker  unknown",
            .off => "  broker  down — every client on the file bucket",
            .hosted, .client => ui.fmt("  broker  up{s} · queue {d}{s}", .{
                if (b.where == .hosted) " (this mnml)" else "",
                b.total(),
                if (b.total() > 0) ui.fmt(" ({d} interactive · {d} refresh · {d} warm · {d} batch)", .{ b.queue[0], b.queue[1], b.queue[2], b.queue[3] }) else "",
            }),
        };
        const bw = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(broker_text, r.right() -| x), if (b.where == .off) muted else fg);
        ui.hit(Rect.init(x, r.y, bw, 1), nowHit(pane, .broker));
        x += bw;
        const f = n.feed;
        const feed_text = switch (f.state) {
            .polling => "   feed polling",
            .live => ui.fmt("   feed live · {s} ago", .{age(ui, f.quiet_secs)}),
            .stale => ui.fmt("   feed stale · quiet {s}", .{age(ui, f.quiet_secs)}),
            .missing => "   feed missing — polling",
        };
        if (x < r.right()) {
            const fw = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(feed_text, r.right() -| x), if (f.state == .stale or f.state == .missing) warn else muted);
            ui.hit(Rect.init(x, r.y, fw, 1), nowHit(pane, .feed));
            x += fw;
        }
        if (n.cache_entries) |c| if (x < r.right()) {
            const cw = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(ui.fmt("   cache {d} entr{s}", .{ c, if (c == 1) "y" else "ies" }), r.right() -| x), muted);
            ui.hit(Rect.init(x, r.y, cw, 1), nowHit(pane, .cache));
        };
    }
    return 5;
}

/// `widget.py (2), mnml-bitbucket (1)` — the callers, the most first.
fn whoText(ui: Ui, by: []const reader.Reason) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (by, 0..) |b, i| {
        if (i == 4) {
            out.appendSlice(ui.arena, ", …") catch {};
            break;
        }
        out.print(ui.arena, "{s}{s} ({d})", .{ if (i > 0) ", " else "", b.reason, b.n }) catch return out.items;
    }
    return out.items;
}

/// `12s`, `4m`, `3h`, `2d`.
pub fn age(ui: Ui, secs: f64) []const u8 {
    const s = reader.wholeSecs(secs);
    if (s < 60) return ui.fmt("{d}s", .{s});
    if (s < 3600) return ui.fmt("{d}m", .{s / 60});
    if (s < 86400) return ui.fmt("{d}h", .{s / 3600});
    return ui.fmt("{d}d", .{s / 86400});
}

/// `14:07` on the local clock, or `Mon 14:00` on the week's strip.
pub fn clockText(ui: Ui, ts: f64, tz: i64, with_day: bool) []const u8 {
    const secs: i64 = reader.floorI64(ts) + std.math.clamp(tz, -86400, 86400);
    const day = @divFloor(secs, 86400);
    const in_day: u64 = @intCast(secs - day * 86400);
    const hm = ui.fmt("{d:0>2}:{d:0>2}", .{ in_day / 3600, (in_day % 3600) / 60 });
    if (!with_day) return hm;
    const names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    return ui.fmt("{s} {s}", .{ names[@intCast(@mod(day, 7))], hm });
}

/// The strip's geometry: how many buckets a column holds, how many
/// columns, how wide each is.
pub const Geometry = struct { span: usize, cols: usize, cell_w: u16 };

pub fn geometry(buckets: usize, plot_w: u16) Geometry {
    if (buckets == 0 or plot_w == 0) return .{ .span = 1, .cols = 0, .cell_w = 1 };
    const span = (buckets + plot_w - 1) / plot_w;
    const cols = (buckets + span - 1) / span;
    const cell_w: u16 = @intCast(@max(@as(usize, plot_w) / cols, 1));
    return .{ .span = span, .cols = cols, .cell_w = @min(cell_w, 3) };
}

const axis_w: u16 = 7;

/// TIMELINE: heading, legend, the strip, the time axis and the
/// readout of the picked (or hovered) column. Returns the rows used.
fn drawTimeline(ui: Ui, pane: PaneId, area: Rect, p: *traffic.ApiTrafficPane, s: *const reader.ServiceSnap, w: *const reader.WinSnap, tz: i64, now: f64) u16 {
    _ = s;
    const t = ui.theme;
    const bg = t.bg.bg;
    const strip_h = area.h - 4;
    const unit: []const u8 = if (p.window == .week) "requests per 10 minutes" else "requests a minute";
    sectionHeading(ui, pane, area.row(0), ui.fmt("TIMELINE · {s}", .{unit}), .timeline);

    // The legend: one swatch per series, mnml's own marked.
    {
        const r = area.row(1);
        var x = r.x + 2;
        for (w.series, 0..) |sr, i| {
            const text = ui.fmt(" {s}{s}", .{ sr.label, if (sr.mnml) " (mnml)" else "" });
            const tw = ui.width(text) + 1;
            if (x + tw > r.right()) break;
            _ = ui.putStr(x, r.y, 1, swatch(ui), seriesStyle(t, w, i, bg));
            _ = ui.putStr(x + 1, r.y, tw - 1, text, Theme.onBg(t.muted, bg));
            ui.hit(Rect.init(x, r.y, tw, 1), .{ .script_hit = .{ .pane = pane, .id = traffic.hit_legend_base + @as(u32, @intCast(i)) } });
            x += tw + 3;
        }
        if (w.series.len == 0) _ = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(ui.fmt("nothing drew in the last {s}", .{p.window.label()}), r.right() -| x), Theme.onBg(t.muted, bg));
    }

    const plot_x = area.x + axis_w;
    const plot_w = area.w -| (axis_w + 1);
    const nb = p.window.buckets();
    const g = geometry(nb, plot_w);
    p.col_span = g.span;
    const strip_top = area.y + 2;

    // The scale: requests per bucket, the limit per bucket beside it.
    const per_bucket_limit: f64 = @as(f64, @floatFromInt(s_limit(p))) * @as(f64, @floatFromInt(p.window.bucketSecs())) / 3600.0;
    var peak: f64 = 0;
    for (0..g.cols) |c| peak = @max(peak, colRate(w, c, g.span));
    // The limit is on the strip unless it would flatten every bar to a
    // sliver: past four times the peak it is named, not drawn.
    const limit_on_scale = per_bucket_limit > 0 and per_bucket_limit <= @max(peak, 0.0001) * 4;
    const scale = if (limit_on_scale) @max(peak, per_bucket_limit) else @max(peak, 1);
    const eighths: f64 = @floatFromInt(@as(u32, strip_h) * 8);

    // The axis labels.
    const axis_style = Theme.onBg(t.muted, bg);
    _ = ui.putStrRight(plot_x - 1, strip_top, axis_w - 1, rateText(ui, scale), axis_style);
    _ = ui.putStrRight(plot_x - 1, strip_top + strip_h - 1, axis_w - 1, "0", axis_style);
    const limit_row: ?u16 = if (limit_on_scale) blk: {
        const frac = per_bucket_limit / scale;
        const from_bottom: u16 = @intFromFloat(reader.clampF(@floor(frac * @as(f64, @floatFromInt(strip_h)) - 0.0001), 0, @as(f64, @floatFromInt(strip_h - 1))));
        break :blk strip_top + strip_h - 1 - from_bottom;
    } else null;
    const limit_style: Style = .{ .fg = t.warn_fg.fg, .bg = bg };
    if (limit_row) |lr| {
        // `lim 13` in the warning ink, over the scale's own top label
        // when the limit is the top of the scale.
        ui.fill(Rect.init(area.x, lr, axis_w, 1), t.bg);
        _ = ui.putStrRight(plot_x - 1, lr, axis_w - 1, ui.fmt("lim {s}", .{rateText(ui, per_bucket_limit)}), limit_style);
        ui.hit(Rect.init(area.x, lr, axis_w, 1), .{ .script_hit = .{ .pane = pane, .id = traffic.hit_limit } });
    }

    // The columns.
    const hovered_col: ?usize = blk: {
        for (0..g.cols) |c| {
            const cx = plot_x + @as(u16, @intCast(c)) * g.cell_w;
            if (ui.hovered(Rect.init(cx, strip_top, g.cell_w, strip_h))) break :blk c;
        }
        break :blk null;
    };
    const picked_col: ?usize = if (p.column) |b| b / g.span else null;
    const shown_col = picked_col orelse hovered_col;
    for (0..g.cols) |c| {
        const cx = plot_x + @as(u16, @intCast(c)) * g.cell_w;
        if (cx + g.cell_w > plot_x + plot_w) break;
        // Each series' extent, in eighths of a cell from the bottom.
        var bounds: [reader.max_series + 2]f64 = undefined;
        bounds[0] = 0;
        var acc: f64 = 0;
        const ns: usize = @min(w.series.len, reader.max_series + 1);
        for (0..ns) |si| {
            acc += seriesRate(w, c, g.span, si);
            bounds[si + 1] = @min(acc / scale * eighths, eighths);
        }
        const col_bg = if (shown_col != null and shown_col.? == c) t.cursor_line.bg else bg;
        var row: u16 = 0;
        while (row < strip_h) : (row += 1) {
            const cy = strip_top + strip_h - 1 - row;
            const lo: f64 = @floatFromInt(@as(u32, row) * 8);
            const cell = cellFor(bounds[0 .. ns + 1], lo);
            var text: []const u8 = " ";
            var style: Style = .{ .bg = col_bg };
            if (cell.fill > 0) {
                text = if (ui.ascii) (if (cell.fill >= 4) "#" else ".") else blocks[cell.fill - 1];
                style = .{ .fg = seriesColor(t, cell.bottom, ns, isOther(w, cell.bottom)), .bg = if (cell.top) |tp| seriesColor(t, tp, ns, isOther(w, tp)) else col_bg };
            } else if (limit_row != null and limit_row.? == cy) {
                text = border.ruleGlyph(.h, ui.ascii);
                style = .{ .fg = t.warn_fg.fg, .bg = col_bg };
            }
            var k: u16 = 0;
            while (k < g.cell_w) : (k += 1) _ = ui.putStr(cx + k, cy, 1, text, style);
        }
        ui.hit(Rect.init(cx, strip_top, g.cell_w, strip_h), .{ .script_hit = .{ .pane = pane, .id = traffic.hit_col_base + @as(u32, @intCast(c * g.span)) } });
    }

    // The time axis: the start, the middle and now.
    {
        const ay = strip_top + strip_h;
        const with_day = p.window != .hour;
        const left = clockText(ui, w.start, tz, with_day);
        _ = ui.putStr(plot_x, ay, plot_w, ui.clipStr(left, plot_w), axis_style);
        const right_text = "now";
        const used_w = @as(u16, @intCast(g.cols)) * g.cell_w;
        const right_x = plot_x + @min(used_w, plot_w);
        _ = ui.putStrRight(right_x, ay, 3, right_text, axis_style);
        const mid = clockText(ui, w.start + @as(f64, @floatFromInt(p.window.secs())) / 2, tz, with_day);
        const mid_w = ui.width(mid);
        const mid_x = plot_x + used_w / 2 -| mid_w / 2;
        if (mid_x > plot_x + ui.width(left) + 1 and mid_x + mid_w + 1 < right_x -| 3) _ = ui.putStr(mid_x, ay, mid_w, mid, axis_style);
    }

    // The readout: the picked column, else the hovered one, else the
    // limit when it is off the scale.
    {
        const ry = strip_top + strip_h + 1;
        const r = Rect.init(area.x, ry, area.w, 1);
        if (shown_col) |c| {
            _ = ui.putStr(r.x + 2, r.y, r.w -| 2, ui.clipStr(readout(ui, p, w, c * g.span, g.span, tz), r.w -| 2), Theme.onBg(t.fg, bg));
        } else if (!limit_on_scale and per_bucket_limit > 0) {
            _ = ui.putStr(r.x + 2, r.y, r.w -| 2, ui.clipStr(ui.fmt("limit {s} {s} — off the top of this scale; the peak is {s}", .{ rateText(ui, per_bucket_limit), if (ui.ascii) "^" else "\u{2191}", rateText(ui, peak) }), r.w -| 2), limit_style);
            ui.hit(Rect.init(r.x, r.y, r.w, 1), .{ .script_hit = .{ .pane = pane, .id = traffic.hit_limit } });
        } else {
            _ = ui.putStr(r.x + 2, r.y, r.w -| 2, ui.clipStr(overlay.hintText(ui, "point at a column, or ←→, for its minute and who drew"), r.w -| 2), Theme.onBg(t.muted, bg));
        }
    }
    _ = now;
    return area.h;
}

fn s_limit(p: *const traffic.ApiTrafficPane) u32 {
    const s = p.current() orelse return 0;
    return s.now.hourly_limit;
}

const blocks = [_][]const u8{ "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}" };

fn isOther(w: *const reader.WinSnap, i: usize) bool {
    return i == w.series.len - 1 and w.who.len > reader.max_series;
}

/// What one cell of a column paints: the series under its bottom edge
/// (filling `fill` eighths from the bottom) and the one above it, if a
/// second series starts inside the cell.
const Cell = struct { fill: u8 = 0, bottom: usize = 0, top: ?usize = null };

fn cellFor(bounds: []const f64, lo: f64) Cell {
    const n = bounds.len - 1;
    // The series covering `lo`.
    var si: usize = 0;
    while (si < n and bounds[si + 1] <= lo) : (si += 1) {}
    if (si >= n) return .{};
    const hi = bounds[si + 1];
    const top_edge = lo + 8;
    if (hi >= top_edge) return .{ .fill = 8, .bottom = si };
    const fill: u8 = @intFromFloat(@max(@round(hi - lo), 0));
    // Another series continues above inside this cell.
    var above: ?usize = null;
    var sj = si + 1;
    while (sj < n) : (sj += 1) if (bounds[sj + 1] > hi) {
        above = sj;
        break;
    };
    if (fill == 0) return if (above) |a| (if (bounds[a + 1] - lo >= 4) .{ .fill = 8, .bottom = a } else .{}) else .{};
    return .{ .fill = fill, .bottom = si, .top = if (above != null and bounds[above.? + 1] >= top_edge - 0.5) above else null };
}

/// Requests a bucket, averaged over the column's buckets.
fn colRate(w: *const reader.WinSnap, c: usize, span: usize) f64 {
    var n: u64 = 0;
    const first = c * span;
    var b = first;
    const nb = w.window.buckets();
    while (b < first + span and b < nb) : (b += 1) n += w.total(b);
    return @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(span));
}

fn seriesRate(w: *const reader.WinSnap, c: usize, span: usize, si: usize) f64 {
    var n: u64 = 0;
    const first = c * span;
    var b = first;
    const nb = w.window.buckets();
    while (b < first + span and b < nb) : (b += 1) n += w.at(b, si);
    return @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(span));
}

fn rateText(ui: Ui, v: f64) []const u8 {
    if (v >= 10) return ui.fmt("{d:.0}", .{v});
    return ui.fmt("{d:.1}", .{v});
}

/// `14:07 · 23 requests · widget.py 12 · mnml-bitbucket 11` — the
/// column starting at bucket `first`, `span` buckets wide.
pub fn readout(ui: Ui, p: *const traffic.ApiTrafficPane, w: *const reader.WinSnap, first: usize, span: usize, tz: i64) []const u8 {
    const bsecs: f64 = @floatFromInt(p.window.bucketSecs());
    const from = w.start + @as(f64, @floatFromInt(first)) * bsecs;
    const with_day = p.window != .hour;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var n: u64 = 0;
    const nb = w.window.buckets();
    var b = first;
    while (b < first + span and b < nb) : (b += 1) n += w.total(b);
    if (span * @as(usize, @intCast(p.window.bucketSecs())) > 60) {
        const to = from + @as(f64, @floatFromInt(span)) * bsecs;
        out.print(ui.arena, "{s}–{s}", .{ clockText(ui, from, tz, with_day), clockText(ui, to, tz, false) }) catch return "";
    } else out.appendSlice(ui.arena, clockText(ui, from, tz, with_day)) catch return "";
    out.print(ui.arena, " · {d} request{s}", .{ n, if (n == 1) "" else "s" }) catch {};
    for (w.series, 0..) |sr, si| {
        var m: u64 = 0;
        b = first;
        while (b < first + span and b < nb) : (b += 1) m += w.at(b, si);
        if (m == 0) continue;
        out.print(ui.arena, " · {s} {d}", .{ sr.label, m }) catch {};
    }
    return out.items;
}

const WhoWidths = struct { program: u16, requests: u16, share: u16, reason: u16, wait: u16, seen: u16, pids: u16 };

const who_heads = [_][]const u8{ "program", "requests", "share", "top reason", "worst wait", "last seen", "pids" };

fn whoWidths(ui: Ui, w: *const reader.WinSnap, first: usize, rows: usize, width: u16, now: f64) WhoWidths {
    var need = [_]u16{ 8, 8, 6, 10, 10, 9, 5 };
    const last = @min(w.who.len, first + rows);
    for (w.who[first..last]) |row| {
        need[0] = @max(need[0], @as(u16, @intCast(@min(cellWidth(row.program) + 3 + @as(usize, if (row.mnml) 7 else 0), 40))));
        need[3] = @max(need[3], @as(u16, @intCast(@min(cellWidth(row.topReason()), 24))));
        need[6] = @max(need[6], @as(u16, @intCast(ui.width(pidsText(ui, row)))));
        _ = now;
    }
    // The program is the column a row is known by: it takes the rest
    // and gives way last. The pids go first, then the last-seen age,
    // then the wait, then the reason; the counts never go.
    const specs = [_]columns.Spec{
        // No `rest`: on a wide pane the numbers stay beside the name
        // they belong to, and the spare cells are left at the right.
        .{ .w = 14, .min = 10, .need = need[0] },
        .{ .w = 8, .need = need[1], .fixed = true },
        .{ .w = 6, .need = need[2], .fixed = true },
        .{ .w = 12, .min = 8, .need = need[3], .drop = 4 },
        .{ .w = 10, .need = need[4], .fixed = true, .drop = 3 },
        .{ .w = 9, .need = need[5], .fixed = true, .drop = 2 },
        .{ .w = 9, .min = 7, .need = need[6], .drop = 1 },
    };
    var out: [7]u16 = undefined;
    columns.fit(&out, &specs, width, 2);
    return .{ .program = out[0], .requests = out[1], .share = out[2], .reason = out[3], .wait = out[4], .seen = out[5], .pids = out[6] };
}

/// `4100`, or `4200 +1` when the program ran as more than one process.
pub fn pidsText(ui: Ui, row: reader.WhoRow) []const u8 {
    if (row.pids.len == 0) return "—";
    if (row.pids.len == 1) return ui.fmt("{d}", .{row.pids[0]});
    return ui.fmt("{d} +{d}", .{ row.pids[0], row.pids.len - 1 });
}

/// WHO: heading, column header, one row per program.
fn drawWho(ui: Ui, pane: PaneId, area: Rect, p: *traffic.ApiTrafficPane, w: *const reader.WinSnap, now: f64, focused: bool) void {
    const t = ui.theme;
    const bg = t.bg.bg;
    sectionHeading(ui, pane, area.row(0), ui.fmt("WHO · {d} program{s}", .{ w.who.len, if (w.who.len == 1) "" else "s" }), .who);
    if (area.h < 2) return;
    if (w.who.len == 0) {
        _ = empty_state.draw(ui, area.splitTop(1).rest, .{ .message = ui.fmt("nothing drew on this bucket in the last {s}", .{p.window.label()}) }, t.bg);
        return;
    }
    const body_h = area.h -| 2;
    const win = list_panel.scrollWindow(&p.scroll, p.cursor, w.who.len, body_h);
    const inner_w = area.w -| 2;
    const cw = whoWidths(ui, w, win.first, body_h, inner_w, now);
    const widths = [_]u16{ cw.program, cw.requests, cw.share, cw.reason, cw.wait, cw.seen, cw.pids };
    const right_aligned = [_]bool{ false, true, true, false, true, true, false };

    // The column header.
    {
        const r = area.row(1);
        var style = header.labelStyle(t, t.bg);
        style.bold = false;
        var x = r.x + 2;
        for (who_heads, widths, right_aligned, 0..) |h, cwid, ra, i| {
            if (cwid == 0 or x >= r.right()) continue;
            const cell = Rect.init(x, r.y, @min(cwid, r.right() -| x), 1);
            if (ra) _ = ui.putStrRight(cell.right(), r.y, cell.w, ui.clipStr(h, cell.w), style) else _ = ui.putStr(x, r.y, cell.w, ui.clipStr(h, cell.w), style);
            ui.hit(cell, .{ .script_hit = .{ .pane = pane, .id = traffic.hit_who_head_base + @as(u32, @intCast(i)) } });
            x += cwid + 2;
        }
    }
    if (body_h == 0) return;

    var y: u16 = 0;
    var i = win.first;
    while (i < w.who.len and y < body_h) : ({
        i += 1;
        y += 1;
    }) {
        const row = w.who[i];
        const line = Rect.init(area.x, area.y + 2 + y, area.w, 1);
        const on_cursor = i == p.cursor;
        const rbg = if (on_cursor and focused) t.cursor_line.bg else bg;
        if (on_cursor and focused) ui.fill(line, t.cursor_line);
        if (on_cursor) list_panel.paintMarker(ui, Rect.init(line.x, line.y, 1, 1), .{ .bg = rbg }, focused);
        var x = line.x + 2;
        const cells = [_][]const u8{
            "",
            ui.fmt("{d}", .{row.requests}),
            ui.fmt("{d:.0} %", .{row.share_pct}),
            row.topReason(),
            if (row.worst_wait_ms == 0) "·" else waitText(ui, row.worst_wait_ms),
            ui.fmt("{s} ago", .{age(ui, now - row.last_seen)}),
            pidsText(ui, row),
        };
        for (widths, right_aligned, 0..) |cwid, ra, ci| {
            if (cwid == 0 or x >= line.right()) continue;
            const cell = Rect.init(x, line.y, @min(cwid, line.right() -| x), 1);
            if (ci == 0) {
                // The swatch in the row's series colour, then the name,
                // mnml's own marked so the split is legible without the
                // legend.
                _ = ui.putStr(x, line.y, 1, swatch(ui), .{ .fg = seriesColor(t, row.series, w.series.len, row.series >= reader.max_series), .bg = rbg });
                var name_style = Theme.onBg(t.fg, rbg);
                name_style.bold = on_cursor;
                const nw = ui.putStr(x + 2, line.y, cell.w -| 2, ui.clipStr(row.program, cell.w -| 2), name_style);
                if (row.mnml and x + 2 + nw + 7 <= cell.right()) _ = ui.putStr(x + 2 + nw + 1, line.y, 6, "(mnml)", Theme.onBg(t.muted, rbg));
            } else {
                const text = ui.clipStr(cells[ci], cell.w);
                const style = if (ci == 4 and row.worst_wait_ms >= 2000) Theme.onBg(t.warn_fg, rbg) else Theme.onBg(if (ci == 1) t.fg else t.muted, rbg);
                if (ra) _ = ui.putStrRight(cell.right(), line.y, cell.w, text, style) else _ = ui.putStr(x, line.y, cell.w, text, style);
            }
            x += cwid + 2;
        }
        ui.hit(line, .{ .script_hit = .{ .pane = pane, .id = traffic.hit_row_base + @as(u32, @intCast(i)) } });
    }
}

fn waitText(ui: Ui, ms: u32) []const u8 {
    if (ms < 1000) return ui.fmt("{d}ms", .{ms});
    return ui.fmt("{d:.1}s", .{@as(f64, @floatFromInt(ms)) / 1000.0});
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

/// A pane with a hand-made result: two services, three programs on
/// bitbucket — invented names only.
fn fixturePane(now: f64) !traffic.ApiTrafficPane {
    var p = traffic.ApiTrafficPane.init(testing.allocator, .hour);
    errdefer p.deinit(testing.io);
    const r = try traffic.Result.create(testing.allocator, 0);
    p.result = r;
    r.now = now;
    const a = r.arena.allocator();
    const nb = reader.Window.hour.buckets();
    const series = try a.dupe(reader.Series, &.{ .{ .label = "widget.py" }, .{ .label = "mnml-bitbucket", .mnml = true }, .{ .label = "cron.sh" } });
    const counts = try a.alloc(u32, nb * series.len);
    @memset(counts, 0);
    // The newest minute: 3 + 2 + 1; ten minutes back: 4 of widget.py.
    counts[(nb - 1) * 3 + 0] = 3;
    counts[(nb - 1) * 3 + 1] = 2;
    counts[(nb - 1) * 3 + 2] = 1;
    counts[(nb - 11) * 3 + 0] = 4;
    var bb: reader.ServiceSnap = .{ .service = "bitbucket", .source = .draws };
    bb.windows[0] = .{
        .window = .hour,
        .requests = 10,
        .not_modified_pct = 89,
        .throttled = 1,
        .series = series,
        .counts = counts,
        .start = now - 3600 + 30,
        .who = try a.dupe(reader.WhoRow, &.{
            .{ .program = "widget.py", .requests = 7, .share_pct = 70, .reasons = try a.dupe(reader.Reason, &.{ .{ .reason = "poll", .n = 5 }, .{ .reason = "user", .n = 2 } }), .worst_wait_ms = 3100, .last_seen = now - 12, .pids = try a.dupe(i32, &.{ 4200, 4100 }), .series = 0 },
            .{ .program = "mnml-bitbucket", .mnml = true, .requests = 2, .share_pct = 20, .reasons = try a.dupe(reader.Reason, &.{.{ .reason = "pane_open", .n = 2 }}), .last_seen = now - 40, .pids = try a.dupe(i32, &.{77}), .series = 1 },
            .{ .program = "cron.sh", .requests = 1, .share_pct = 10, .reasons = try a.dupe(reader.Reason, &.{.{ .reason = "batch", .n = 1 }}), .worst_wait_ms = 5, .last_seen = now - 300, .series = 2 },
        }),
    };
    bb.now = .{
        .bucket = .{ .tokens = 12.4, .capacity = 40, .rate = 0.22, .last_429_age = 240, .throttles = 3 },
        .hour_requests = 10,
        .hourly_limit = 792,
        .tally_today = 1204,
        .broker = .{ .where = .client, .queue = .{ 1, 0, 0, 2 } },
        .feed = .{ .state = .live, .quiet_secs = 12 },
        .cache_entries = 214,
        .throttles = .{ .n = 3, .last_age = 240, .by = try a.dupe(reader.Reason, &.{ .{ .reason = "widget.py", .n = 2 }, .{ .reason = "mnml-bitbucket", .n = 1 } }) },
    };
    const jira: reader.ServiceSnap = .{ .service = "jira", .source = .draws };
    r.services = try a.dupe(reader.ServiceSnap, &.{ bb, jira });
    p.service = try testing.allocator.dupe(u8, "bitbucket");
    return p;
}

test "the view paints the header line, the tabs, NOW, a stacked strip and the Who table, and every hit is on screen" {
    const now: f64 = 1_790_000_000;
    var p = try fixturePane(now);
    defer p.deinit(testing.io);
    defer p.result.?.destroy(testing.allocator);
    for ([_][2]u16{ .{ 80, 24 }, .{ 120, 40 }, .{ 200, 60 } }) |size| {
        var f = try Fixture.init(size[0], size[1]);
        defer f.deinit();
        draw(f.ui(), 9, f.full(), &p, true);
        // The header: the service in caps, then the window's numbers.
        try f.expectContains("BITBUCKET · last 1h · 10 requests · 89 % 304 · 1 429");
        try f.expectContains(" Bitbucket 10 ");
        try f.expectContains(" Jira 0");
        try f.expectContains("widget.py");
        try f.expectContains("4200 +1");
        // No hit lands outside the pane.
        for (f.hits.items.items) |h| {
            try testing.expect(h.rect.right() <= size[0]);
            try testing.expect(h.rect.bottom() <= size[1]);
        }
        if (size[1] >= 40) {
            try f.expectContains("12.4/40 tokens · 0.22/s · no cooldown · last 429 4m ago · 3 throttles");
            try f.expectContains("10 of 792 limit (1 %) · mnml today 1204");
            try f.expectContains("broker  up · queue 3 (1 interactive · 0 refresh · 0 warm · 2 batch)");
            try f.expectContains("feed live · 12s ago");
            try f.expectContains("cache 214 entries");
            try f.expectContains("throttles  3 in the last hour · last 4m ago · widget.py (2), mnml-bitbucket (1)");
            try f.expectContains("TIMELINE");
            try f.expectContains("mnml-bitbucket (mnml)");
        }
    }
}

test "the strip stacks the programs: the newest column's cells wear more than one series colour" {
    const now: f64 = 1_790_000_000;
    var p = try fixturePane(now);
    defer p.deinit(testing.io);
    defer p.result.?.destroy(testing.allocator);
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    draw(f.ui(), 9, f.full(), &p, true);
    // The newest column's hit: its id is its first bucket.
    const nb = reader.Window.hour.buckets();
    var col_rect: ?Rect = null;
    for (f.hits.items.items) |h| switch (h.target) {
        .script_hit => |sh| if (sh.id == traffic.hit_col_base + nb - 1) {
            col_rect = h.rect;
        },
        else => {},
    };
    const cr = col_rect.?;
    // Every colour painted in that column, foreground and background.
    var colours: std.ArrayListUnmanaged(Color) = .empty;
    defer colours.deinit(testing.allocator);
    var yy = cr.y;
    while (yy < cr.bottom()) : (yy += 1) {
        const cell = f.cell(cr.x, yy);
        if (std.mem.eql(u8, cell.char.grapheme, " ")) continue;
        for ([_]Color{ cell.style.fg, cell.style.bg }) |c| {
            var seen = false;
            for (colours.items) |have| if (std.meta.eql(have, c)) {
                seen = true;
            };
            if (!seen) try colours.append(testing.allocator, c);
        }
    }
    const t = &f.theme;
    const want = [_]Color{ seriesColor(t, 0, 3, false), seriesColor(t, 1, 3, false) };
    for (want) |c| {
        var found = false;
        for (colours.items) |have| if (std.meta.eql(have, c)) {
            found = true;
        };
        try testing.expect(found);
    }
    // Three programs, three ladder colours, all different.
    try testing.expect(!std.meta.eql(seriesColor(t, 0, 3, false), seriesColor(t, 1, 3, false)));
    try testing.expect(!std.meta.eql(seriesColor(t, 1, 3, false), seriesColor(t, 2, 3, false)));
}

test "a picked column reads out its minute, its count and the split by program" {
    const now: f64 = 1_790_000_000;
    var p = try fixturePane(now);
    defer p.deinit(testing.io);
    defer p.result.?.destroy(testing.allocator);
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    p.column = reader.Window.hour.buckets() - 1;
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectContains("6 requests · widget.py 3 · mnml-bitbucket 2 · cron.sh 1");
}

test "the strip geometry: one column a minute when it fits, runs of minutes when it does not" {
    const g1 = geometry(60, 110);
    try testing.expectEqual(@as(usize, 1), g1.span);
    try testing.expectEqual(@as(usize, 60), g1.cols);
    try testing.expectEqual(@as(u16, 1), g1.cell_w);
    const g2 = geometry(60, 190);
    try testing.expectEqual(@as(u16, 3), g2.cell_w);
    const g3 = geometry(1440, 110);
    try testing.expectEqual(@as(usize, 14), g3.span);
    try testing.expect(g3.cols * g3.span >= 1440);
    try testing.expect(g3.cols <= 110);
}

test "before the first look the pane says it is reading; with no services it says where the files would be" {
    var p = traffic.ApiTrafficPane.init(testing.allocator, .hour);
    defer p.deinit(testing.io);
    defer if (p.result) |r| r.destroy(testing.allocator);
    var f = try Fixture.init(100, 12);
    defer f.deinit();
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectContains("reading the draws and request logs");
    p.result = try traffic.Result.create(testing.allocator, 0);
    draw(f.ui(), 9, f.full(), &p, true);
    try f.expectContains("no API traffic recorded on this machine yet");
}

test "the ages and the clock labels saturate on any number: NaN, infinity, either sign, past every integer" {
    var f = try Fixture.init(40, 4);
    defer f.deinit();
    const ui = f.ui();
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e20, 1e300, -1e300, -1, 0, 59.9, 3599, 86399 }) |v| {
        _ = age(ui, v);
        _ = clockText(ui, v, 3600, true);
        _ = clockText(ui, v, -std.math.maxInt(i32), false);
    }
    try testing.expectEqualStrings("0s", age(ui, -5));
    try testing.expectEqualStrings("0s", age(ui, std.math.nan(f64)));
    try testing.expectEqualStrings("11574074074d", age(ui, 1e20));
}
