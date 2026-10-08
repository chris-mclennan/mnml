//! Hover help for the API TRAFFIC pane's parts (`app/api_traffic.zig`'s
//! `.script_hit` ids): the header, the window and refresh chips, a
//! service tab, the section headings, each NOW row, a legend swatch,
//! the limit line, a timeline column, a WHO column header and a WHO
//! row. The column and the row say their own numbers — the minute, the
//! count, the split; the reasons and the pids — read off the result the
//! pane already holds, so a hover never reads a file either.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../../app.zig").App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const hit = @import("../../ui/hit.zig");
const traffic = @import("../api_traffic.zig");
const reader = @import("../api_traffic_reader.zig");

const window_link: copy.Link = .{ .settings = .{ .row = copy.settingsRow("integrations.api_traffic_window"), .label = "The window it opens on" } };
const requests_link: copy.Link = .{ .command = .{ .id = .@"integrations.requests", .label = "mnml's own requests" } };

pub fn entry(app: *App, arena: Allocator, p: *const traffic.ApiTrafficPane, id: u32) Allocator.Error!Entry {
    _ = app;
    if (id == hit.ListHit.chip(.sort)) return .{
        .title = "Window",
        .body = try std.fmt.allocPrint(arena, "The span the header, the timeline and the WHO table cover — now the last {s}. A click walks hour → day → week; a right-click lists the three. The pane opens on `integrations.api_traffic_window`; this chip changes the view, not the setting.", .{p.window.label()}),
        .keys = &.{.{ .chord = "Right-click", .label = "Pick one" }},
        .links = &.{ .{ .command = .{ .id = .@"view.api_traffic_window_hour", .label = "Last hour" } }, .{ .command = .{ .id = .@"view.api_traffic_window_day", .label = "Last 24 hours" } }, window_link },
    };
    if (id == hit.ListHit.chip(.refresh)) return .{
        .title = "Read again",
        .body = "Reads every log's new lines now instead of at the next tick of the dashboard cadence, and takes the environment again — a `MNML_SHARED_STATE_DIR` set since the pane opened points it at another directory. Nothing is sent to any API; only files are read.",
        .keys = &.{.{ .chord = "r", .label = "Read again" }},
        .links = &.{.{ .settings = .{ .row = copy.settingsRow("ui.dashboard_refresh"), .label = "Dashboard refresh" } }},
    };
    if (id == traffic.hit_title) return header(arena, p);
    if (id >= traffic.hit_tab_base and id < traffic.hit_tab_base + traffic.max_tabs) return tab(arena, p, id - traffic.hit_tab_base);
    if (traffic.sectionOf(id)) |s| return section(s);
    if (traffic.bucketRowOf(id)) |i| return try bucketRow(arena, p, i);
    if (traffic.nowRowOf(id)) |r| return try now(arena, p, r);
    if (id >= traffic.hit_legend_base and id < traffic.hit_limit) return try legend(arena, p, id - traffic.hit_legend_base);
    if (id == traffic.hit_limit) return try limit(arena, p);
    if (traffic.whoColOf(id)) |c| return whoCol(c);
    if (id >= traffic.hit_col_base) return try column(arena, p, id - traffic.hit_col_base);
    if (id >= traffic.hit_row_base) return try row(arena, p, id - traffic.hit_row_base);
    return header(arena, p);
}

fn header(arena: Allocator, p: *const traffic.ApiTrafficPane) Entry {
    _ = arena;
    const source: reader.Source = if (p.current()) |s| s.source else .none;
    return .{
        .title = "API traffic header",
        .body = switch (source) {
            .draws => "The service and the window's totals: requests, the share of mnml's answered requests that came back `304` (unchanged — nearly free), the 429s and the cache hits. The counts are the draws file's — every process that took a token from the shared bucket, mnml's and everyone else's. The 304 share and the 429s are mnml's own request log; nothing else writes a status down.",
            .requests => "The service and the window's totals: requests, the share of mnml's answered requests that came back `304` (unchanged — nearly free), the 429s and the cache hits. This service has no draws file, so the counts are mnml's own request log — its lines that reached the wire.",
            .none => "The service and the window's totals: requests, the share of mnml's answered requests that came back `304`, the 429s and the cache hits. Nothing is counted until a log has a line.",
        },
        .keys = &.{ .{ .chord = "Tab", .label = "Next service" }, .{ .chord = "r", .label = "Read again" } },
        .links = &.{ requests_link, window_link },
    };
}

fn tab(arena: Allocator, p: *const traffic.ApiTrafficPane, i: u32) Allocator.Error!Entry {
    const r = p.result orelse return header(arena, p);
    if (i >= r.services.len) return header(arena, p);
    const s = r.services[i];
    return .{
        .title = try std.fmt.allocPrint(arena, "{s} tab", .{s.service}),
        .body = try std.fmt.allocPrint(arena, "{d} requests in the last {s}, counted from {s}. A service has a tab when any of its files exists — the draws file, the bucket, mnml's request log. Click to show it; Tab walks the tabs.", .{
            s.win(p.window).requests, p.window.label(),
            switch (s.source) {
                .draws => "the draws file (every process on the machine)",
                .requests => "mnml's own request log (no draws file yet)",
                .none => "no log yet",
            },
        }),
        .keys = &.{.{ .chord = "Tab", .label = "Next service" }},
        .links = &.{requests_link},
    };
}

fn section(s: traffic.Section) Entry {
    return switch (s) {
        .now => .{
            .title = "NOW",
            .body = "The shared bucket as it stands — its tokens refilled to this second at the rate in its file, a cooldown after a 429, the last one — then this hour against the hourly limit, the broker's queue, the integration's event feed and the shared HTTP cache. Each row's hover says where its number comes from.",
            .links = &.{requests_link},
        },
        .timeline => .{
            .title = "TIMELINE",
            .body = "Requests a minute over the window, one column a minute on the hour and runs of minutes on wider windows, stacked by program in the order of the WHO table — the busiest at the bottom. The dashed line is the hourly limit spread over a minute; a column above it is spending faster than the bucket refills.",
            .keys = &.{.{ .chord = "←→", .label = "Walk the minutes" }},
            .links = &.{window_link},
        },
        .who => .{
            .title = "WHO",
            .body = "One row per program that drew in the window, busiest first: its requests and share, its most common reason, the longest it waited on the bucket, when it last drew, and its pids. mnml's own integrations are marked; everything else is a process outside mnml spending the same budget.",
            .keys = &.{ .{ .chord = "↑↓", .label = "Move" }, .{ .chord = "y", .label = "Copy the pid" }, .{ .chord = "Right-click", .label = "The row's menu" } },
            .links = &.{requests_link},
        },
    };
}

fn now(arena: Allocator, p: *const traffic.ApiTrafficPane, r: traffic.NowRow) Allocator.Error!Entry {
    const s = p.current() orelse return header(arena, p);
    const n = s.now;
    return switch (r) {
        .bucket => try bucketRow(arena, p, 0),
        .hour => .{
            .title = "This hour against the limit",
            .body = if (n.hour_by.len < 2)
                try std.fmt.allocPrint(arena, "{d} requests in the last hour by every program, against {d} an hour — the bucket's refill rate times 3600, the same figure an integration's budget chip paces to. `mnml today` is the budget's day tally, which counts mnml's own integrations only.", .{ n.hour_requests, n.hourly_limit })
            else
                try std.fmt.allocPrint(arena, "{d} requests in the last hour, split by the bucket each one drew from: a draw line naming a `token_id` spent that token's bucket, one naming none spent the shared one. Each is against {d} an hour — the refill rate times 3600 — because {s} counts its limit per token, so two tokens each have the whole of it. `mnml today` is the budget's day tally, which counts mnml's own integrations only.", .{ n.hour_requests, n.hourly_limit, s.service }),
            .links = &.{requests_link},
        },
        .broker => .{
            .title = "The broker",
            .body = switch (n.broker.where) {
                .hosted => "Up, and this mnml is hosting it: the queue in front of the shared bucket that hands the next token to the pane on screen before a warmer or a batch script. The counts are the waiters per class — interactive, refresh, warm, batch.",
                .client => "Up, hosted by another process (a second mnml, or `mnml broker serve`): the queue in front of the shared bucket that serves the pane on screen first. The counts are the waiters per class — interactive, refresh, warm, batch.",
                .off => "Down: nobody holds the broker's election lock, so every client takes tokens from the file bucket first come, first served. That is a supported state; `integrations.broker` decides whether mnml hosts one.",
                .unknown => "Not read: the broker's socket path could not be resolved from the environment. Every client falls back to the file bucket in that case.",
            },
            .links = &.{requests_link},
        },
        .feed => .{
            .title = "The event feed",
            .body = switch (n.feed.state) {
                .polling => "The integration's config names no event file, so its pane polls — backing off while nothing changes. A `feed.file` in its config is a JSONL file another process appends events to, which lets the pane fetch only what moved.",
                .live => try std.fmt.allocPrint(arena, "The integration's event file was written {d:.0}s ago, inside its {d}s staleness limit, so its pane fetches only the items the file names and sweeps the listing rarely. File: {s}.", .{ n.feed.quiet_secs, n.feed.stale_secs, n.feed.path }),
                .stale => try std.fmt.allocPrint(arena, "Nothing has written the integration's event file for {d:.0}s, past its {d}s limit, so its pane is back to polling. File: {s}.", .{ n.feed.quiet_secs, n.feed.stale_secs, n.feed.path }),
                .missing => try std.fmt.allocPrint(arena, "The integration's config names an event file that is not there, so its pane polls. File: {s}.", .{n.feed.path}),
            },
        },
        .throttles => .{
            .title = "429s this hour",
            .body = if (n.throttles.n == 0)
                "Every 429 an API sent anybody on this machine in the last hour — none so far. They come from `api-usage/<UTC day>.throttles.jsonl` beside the shared buckets, where the fleet writes each one, and from mnml's own request log."
            else
                try std.fmt.allocPrint(arena, "{d} 429s in the last hour for this API, the newest {d:.0}s ago, by caller. They come from `api-usage/<UTC day>.throttles.jsonl` beside the shared buckets, where the fleet writes every one, and from mnml's own request log. New ones raise a warning toast — one per service per five minutes — unless `integrations.throttle_toasts` is off.", .{ n.throttles.n, n.throttles.last_age orelse 0 }),
            .links = &.{ .{ .settings = .{ .row = copy.settingsRow("integrations.throttle_toasts"), .label = "Toast on 429s" } }, requests_link },
        },
        .cache => .{
            .title = "The shared HTTP cache",
            .body = try std.fmt.allocPrint(arena, "Entries under `$MNML_SHARED_STATE_DIR/http-cache/{s}/`: responses one process fetched that another can answer from without spending a token. The row is only here when the directory exists.", .{s.service}),
        },
    };
}

/// NOW's bucket row `i`: which file it is and what it holds.
fn bucketRow(arena: Allocator, p: *const traffic.ApiTrafficPane, i: usize) Allocator.Error!Entry {
    const s = p.current() orelse return header(arena, p);
    const rows = s.now.buckets;
    if (rows.len == 0) return .{
        .title = "No bucket file",
        .body = try std.fmt.allocPrint(arena, "No `{s}-ratelimit.json` was found where the SDK resolves it (`MNML_SHARED_STATE_DIR`, else the data root's `ratelimit/`). Without one, every process paces itself alone and none of them can see the others spending.", .{s.service}),
        .links = &.{requests_link},
    };
    if (i >= rows.len) return section(.now);
    const br = rows[i];
    const b = br.bucket;
    const state = try std.fmt.allocPrint(arena, "{d:.1} of {d:.0} tokens now, refilling at {d:.3}/s ({d} 429s on record). A 429 parks it (`cooldown_until`) and cuts the rate until requests succeed again.", .{ b.tokens, b.capacity, b.rate, b.throttles });
    if (br.token.len == 0) return .{
        .title = "The shared bucket",
        .body = try std.fmt.allocPrint(arena, "`{s}` in the interop directory: {s} Every process that agrees to the file and names no token of its own draws one token per request from it, under one lock.{s}", .{
            br.file,
            state,
            if (rows.len > 1) " The rows below it are the buckets of single tokens, which their own clients spend instead." else "",
        }),
        .links = &.{requests_link},
    };
    return .{
        .title = "A token's bucket",
        .body = try std.fmt.allocPrint(arena, "`{s}` beside the shared bucket: the budget of one token, because {s} counts its limit per token. The id is the first 12 hex of a hash of the credential, never the credential. Every client using that token — mnml's own integration among them — draws from this file, and its draw lines carry `token_id` {s}. {s}", .{ br.file, s.service, br.token, state }),
        .links = &.{requests_link},
    };
}

fn legend(arena: Allocator, p: *const traffic.ApiTrafficPane, i: u32) Allocator.Error!Entry {
    const w = p.currentWin() orelse return header(arena, p);
    if (i >= w.series.len) return section(.timeline);
    const sr = w.series[i];
    if (std.mem.eql(u8, sr.label, "other") and i == reader.max_series) return .{
        .title = "other",
        .body = try std.fmt.allocPrint(arena, "Every program past the busiest {d}, stacked together at the top of each column in the muted colour. The WHO table still lists each of them on its own row.", .{reader.max_series}),
    };
    return .{
        .title = try arena.dupe(u8, sr.label),
        .body = try std.fmt.allocPrint(arena, "This program's share of every column, in its colour — {s}. Its colour is its rank in the WHO table for this window, so the same program can wear another colour on another window.", .{if (sr.mnml) "one of mnml's own integrations" else "a process outside mnml drawing on the same bucket"}),
    };
}

fn limit(arena: Allocator, p: *const traffic.ApiTrafficPane) Allocator.Error!Entry {
    const lim: u32 = if (p.current()) |s| s.now.hourly_limit else 0;
    return .{
        .title = "The hourly limit",
        .body = try std.fmt.allocPrint(arena, "{d} requests an hour — the shared bucket's refill rate for this service times 3600, spread over one column's minutes. A column above the line spends faster than the bucket refills; a run of them is what drains it. When the limit is far above every column it is named under the strip instead of drawn.", .{lim}),
    };
}

fn whoCol(c: traffic.WhoCol) Entry {
    return switch (c) {
        .program => .{ .title = "program", .body = "The `program` each draws line names — `argv[0]`'s basename, `mnml-bitbucket` for an integration mnml started. The swatch is its timeline colour; `(mnml)` marks mnml's own." },
        .requests => .{ .title = "requests", .body = "Tokens this program drew from the shared bucket in the window — one per request that reached the wire, retries included." },
        .share => .{ .title = "share", .body = "This program's requests as a share of every program's in the window. The column adds up to a hundred." },
        .reason => .{ .title = "top reason", .body = "The reason this program gave most often — `poll`, `pane_open`, `warm`… The row's hover lists every reason with its count." },
        .wait => .{ .title = "worst wait", .body = "The longest one acquire held this program's request before it went out — time spent waiting on an empty bucket, a cooldown or the broker's queue. Two seconds or more is drawn in the warning colour." },
        .seen => .{ .title = "last seen", .body = "How long ago this program last drew, measured when the pane last read the logs." },
        .pids => .{ .title = "pids", .body = "The process id that drew most recently, and how many others drew under the same program name in the window — a loop restarted, or two copies running." },
    };
}

/// `14:07` on the local clock (or `Mon 14:07`).
fn clock(arena: Allocator, ts: f64, tz: i64, with_day: bool) Allocator.Error![]const u8 {
    const secs: i64 = reader.floorI64(ts) + std.math.clamp(tz, -86400, 86400);
    const day = @divFloor(secs, 86400);
    const in_day: u64 = @intCast(secs - day * 86400);
    if (!with_day) return std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}", .{ in_day / 3600, (in_day % 3600) / 60 });
    const names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    return std.fmt.allocPrint(arena, "{s} {d:0>2}:{d:0>2}", .{ names[@intCast(@mod(day, 7))], in_day / 3600, (in_day % 3600) / 60 });
}

fn column(arena: Allocator, p: *const traffic.ApiTrafficPane, first: u32) Allocator.Error!Entry {
    const w = p.currentWin() orelse return header(arena, p);
    const r = p.result.?;
    const span = @max(p.col_span, 1);
    const nb = p.window.buckets();
    const bsecs: f64 = @floatFromInt(p.window.bucketSecs());
    const from = w.start + @as(f64, @floatFromInt(first)) * bsecs;
    // The column's last real bucket, and never past now — the readout's
    // own end (`api_traffic_view.readout`).
    const real: f64 = @floatFromInt(@max(@min(span, nb -| first), 1));
    const to = @min(from + real * bsecs, @max(r.now, from));
    const with_day = p.window != .hour;
    var total: u64 = 0;
    var b: usize = first;
    while (b < first + span and b < nb) : (b += 1) total += w.total(b);
    var split: std.ArrayListUnmanaged(u8) = .empty;
    for (w.series, 0..) |sr, si| {
        var m: u64 = 0;
        b = first;
        while (b < first + span and b < nb) : (b += 1) m += w.at(b, si);
        if (m == 0) continue;
        try split.print(arena, "{s}{s} {d}", .{ if (split.items.len > 0) ", " else "", sr.label, m });
    }
    return .{
        .title = if (span * p.window.bucketSecs() > 60)
            try std.fmt.allocPrint(arena, "{s}–{s}", .{ try clock(arena, from, r.tz_offset, with_day), try clock(arena, to, r.tz_offset, false) })
        else
            try clock(arena, from, r.tz_offset, with_day),
        .body = if (total == 0)
            "Nothing drew from the bucket in this column. Click pins it as the readout under the strip; ←→ walks from it."
        else
            try std.fmt.allocPrint(arena, "{d} request{s} in this column: {s}. Click pins it as the readout under the strip; ←→ walks from it.", .{ total, if (total == 1) "" else "s", split.items }),
        .keys = &.{.{ .chord = "←→", .label = "Walk the minutes" }},
    };
}

fn row(arena: Allocator, p: *const traffic.ApiTrafficPane, i: u32) Allocator.Error!Entry {
    const w = p.currentWin() orelse return header(arena, p);
    if (i >= w.who.len) return section(.who);
    const r = w.who[i];
    var reasons: std.ArrayListUnmanaged(u8) = .empty;
    for (r.reasons) |rs| try reasons.print(arena, "{s}{s} {d}", .{ if (reasons.items.len > 0) ", " else "", rs.reason, rs.n });
    var pids: std.ArrayListUnmanaged(u8) = .empty;
    for (r.pids) |pid| try pids.print(arena, "{s}{d}", .{ if (pids.items.len > 0) ", " else "", pid });
    return .{
        .title = try arena.dupe(u8, r.program),
        .body = try std.fmt.allocPrint(arena, "{d} requests in the last {s} ({d:.0} %), {s}. Reasons: {s}. Pids: {s}. Right-click opens it in REQUESTS or copies its pid.", .{
            r.requests,
            p.window.label(),
            r.share_pct,
            if (r.mnml) "one of mnml's own" else "a process outside mnml",
            if (reasons.items.len > 0) reasons.items else "none given",
            if (pids.items.len > 0) pids.items else "none recorded",
        }),
        .keys = &.{ .{ .chord = "y", .label = "Copy the pid" }, .{ .chord = "Right-click", .label = "The row's menu" } },
        .links = &.{requests_link},
    };
}
