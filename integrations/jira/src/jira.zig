//! The Jira REST client: one `request` through the rate limiter, and a
//! named wrapper per endpoint the pane uses — the REST v3 search, the
//! issue, its transitions / comments / assignee / fix version / watchers,
//! the dev-status pull requests, the project's versions and assignable
//! users, and the Agile API's boards, board issues, sprints and quick
//! filters. Nothing here knows about panes, frames or keys —
//! `tools/fake_jira` answers every route, so every test runs offline.
//!
//! **API version.** `v3` is Atlassian Cloud today: a description and a
//! comment body are ADF (a JSON document), and search is
//! `POST /rest/api/3/search/jql` with a `nextPageToken` — the old
//! `/rest/api/3/search` now answers 410. `v2` is a Server / Data Center
//! site: bodies are wiki-markup strings and search is
//! `GET /rest/api/2/search` with `startAt`. `Client.api` picks; the
//! callers below are written once and branch only where the wire differs.
//!
//! **Errors.** Every call returns either the parsed value or a
//! `Failure` carrying the status and a message read out of Jira's
//! `errorMessages` / `errors` object, because "400" on its own is
//! useless and Jira's own sentence is usually exactly right.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = @import("json.zig");
const text = @import("text.zig");
const ratelimit = @import("ratelimit.zig");
const config = @import("config.zig");
const model = @import("model.zig");
const sdk = @import("mnml_sdk");
const request_log = sdk.request_log;

pub const Reason = request_log.Reason;

pub const Value = std.json.Value;
pub const ApiVersion = config.ApiVersion;

/// The ceiling on one search, however many pages Jira offers.
pub const max_issues: usize = 500;
/// Rows per page.
pub const page_size: u32 = 100;
/// The fields every search asks for. `parent` carries the epic on a
/// team-managed project; `customfield_*` extras are added by the caller.
pub const search_fields = [_][]const u8{
    "summary",           "status",  "assignee",    "reporter",   "priority", "issuetype",
    "updated",           "created", "fixVersions", "components", "labels",   "parent",
    "customfield_10020",
};

pub const Failure = struct {
    status: u16,
    /// Jira's own sentence where it sent one, else a generic line. Owned
    /// by the arena the call was given.
    message: []const u8,
};

pub const CallError = error{ Transport, OutOfMemory };

/// Every endpoint returns this: the value, or what the server said.
pub fn Answer(comptime T: type) type {
    return union(enum) {
        ok: T,
        failed: Failure,
    };
}

pub const Raw = struct {
    status: u16,
    body: []u8,
    retry_after_secs: ?f64,
    /// The body read's error, when it stopped short; the body holds what
    /// arrived before it.
    read_error: ?[]const u8 = null,
    /// The answer's content-type, for a parse failure to name.
    content_type: ?[]const u8 = null,
};

/// What a body that failed to parse as JSON was: the read error if the
/// body stopped short, else the content-type and the first bytes —
/// "the search answer was not JSON" alone left nothing to go on.
pub fn notJson(arena: Allocator, what: []const u8, raw: Raw) []const u8 {
    // "the search answer …" / "the answer …": the blank `what` drops its space.
    const label: []const u8 = if (what.len == 0) "answer" else std.fmt.allocPrint(arena, "{s} answer", .{what}) catch "answer";
    if (raw.read_error) |e| return std.fmt.allocPrint(arena, "the {s} was cut short after {d} bytes ({s})", .{ label, raw.body.len, e }) catch label;
    var head: [96]u8 = undefined;
    var n: usize = 0;
    for (raw.body) |b| {
        if (n >= head.len) break;
        head[n] = if (b >= 0x20 and b < 0x7f) b else '.';
        n += 1;
    }
    return std.fmt.allocPrint(arena, "the {s} was not JSON ({s}, {d} bytes: {s})", .{ label, raw.content_type orelse "no content-type", raw.body.len, head[0..n] }) catch label;
}

/// How a 429 is answered when the pane has handed the client no budget
/// (a one-shot `--values` run): the SDK's backoff, started at Jira's
/// cooldown (45 s) and capped at the bucket's longest block. The pane
/// configures its own off `config.rate` (`backoffFor`).
pub const default_backoff: sdk.budget.Backoff = .{ .base_secs = 45, .cap_secs = 120 };

/// The pane's backoff, off the config's `rate` block: the first pause
/// is the bucket's cooldown, the ceiling its longest block.
pub fn backoffFor(rate: config.Rate) sdk.budget.Backoff {
    return .{ .base_secs = rate.cooldown_secs, .cap_secs = @max(rate.max_block_secs, rate.cooldown_secs) };
}

/// A read, as the budget counts it and as a 429 may retry it: a GET,
/// or the search that Jira Cloud takes as a POST.
pub fn isRead(method: std.http.Method, url: []const u8) bool {
    if (method == .GET) return true;
    if (method != .POST) return false;
    const path_end = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const path = url[0..path_end];
    return std.mem.endsWith(u8, path, "/search/jql") or std.mem.endsWith(u8, path, "/search");
}

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    /// `https://acme.atlassian.net`, no trailing slash.
    base_url: []const u8,
    /// `Basic …`, built once by `auth.basicHeader`.
    authorization: []const u8,
    api: ApiVersion = .v3,
    /// The bucket every call passes through, shared with every other
    /// process on this machine (`ratelimit.zig`). Null in a test, which
    /// talks to a fake server and has no budget to spend; the caller
    /// owns it otherwise.
    limiter: ?*ratelimit.Limiter = null,
    /// Where every request is written down (`mnml_sdk.request_log`).
    /// Null in a test, which has no data root to write into.
    log: ?*request_log.Log = null,
    /// Where a wait long enough for a person to notice is left for the
    /// paint loop to say something about.
    notice: ?*ratelimit.Notice = null,
    /// The pacer for this service, shared by every copy of the client
    /// (a job takes one by value). Null leaves requests unpaced, which
    /// is what a test that counts requests wants.
    gate: ?*sdk.warm.Gate = null,
    /// The pane's API budget (`mnml_sdk.budget`): the headers, the 429
    /// pause, the hit ratio, the tally, dry run — the Bitbucket pane's
    /// same object. Null (a one-shot run) gets one of its own per
    /// request, so a 429 is answered the same way.
    budget: ?*sdk.Budget = null,
    /// False for a call made on the paint loop's own thread (`/myself`
    /// at startup): a 429's pause is never waited out there, because a
    /// loop parked in a sleep cannot paint the `paused until` that
    /// explains it. The call answers the 429 at once instead.
    wait_pauses: bool = true,
    user_agent: []const u8 = "mnml-jira",

    pub fn init(gpa: Allocator, io: Io, base_url: []const u8, authorization: []const u8, api: ApiVersion) Client {
        return .{
            .gpa = gpa,
            .io = io,
            .base_url = base_url,
            .authorization = authorization,
            .api = api,
        };
    }

    /// `/rest/api/3` or `/rest/api/2`.
    pub fn apiRoot(c: *const Client) []const u8 {
        return switch (c.api) {
            .v3 => "/rest/api/3",
            .v2 => "/rest/api/2",
        };
    }

    /// One request, gated, with the body read into `arena`. `reason`
    /// is why this call is being made — it goes into the request log,
    /// where it is the difference between "the tab asked for forty
    /// things" and "the poller did".
    pub fn request(c: *Client, arena: Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8, reason: Reason) CallError!Raw {
        var own_budget: sdk.Budget = .{};
        const budget = c.budget orelse blk: {
            own_budget.configure(c.io, .{ .label = "Jira", .service = ratelimit.service, .backoff = default_backoff });
            break :blk &own_budget;
        };
        const read = isRead(method, url);
        // A dry run sends nothing: the line says what would have gone
        // out, and the pane keeps the rows it already shows.
        if (budget.isDry()) {
            c.note(arena, method, url, null, 0, Io.Timestamp.now(c.io, .real), .{ .ok = true }, reason, .{}, true);
            return synthetic(arena, 0, dry_run_message);
        }
        // A 429 is answered the SDK's way, the way the Bitbucket pane
        // answers it: the budget pauses for what the site asked (else
        // the backoff) and the header chip says until when; the bucket
        // parks every process for as long; a READ asks again once the
        // pause is up — `waitOut` is the wait — and a write never does.
        var attempt: u32 = 0;
        while (true) {
            attempt += 1;
            if (!c.wait_pauses and budget.pausedUntilMs() > 0) return pausedRaw(arena, c.io, budget);
            switch (budget.waitOut()) {
                .go => {},
                .paused => return pausedRaw(arena, c.io, budget),
                .cancelled => return synthetic(arena, 429, "stopped waiting out the rate limit"),
                // The machine's shared bucket file is empty or cooling
                // down: this round is skipped and nothing goes out.
                .bucket_empty, .bucket_cooldown => |g| return synthetic(arena, 429, sdk.Budget.refusalText(g)),
            }
            const raw = try c.once(arena, method, url, body, reason, budget, read);
            if (raw.status != 429) return raw;
            const ra: ?u32 = if (raw.retry_after_secs) |x| @intFromFloat(x) else null;
            const delay = budget.throttled(attempt, ra);
            if (!c.wait_pauses or !budget.backoff.retries(attempt, read)) return raw;
            if (delay > budget.backoff.wait_in_request_secs) return raw;
        }
    }

    /// A request refused because a pause is running: nothing went out,
    /// and the answer says until when.
    fn pausedRaw(arena: Allocator, io: Io, budget: *sdk.Budget) Allocator.Error!Raw {
        const snap = budget.snapshot(Io.Timestamp.now(io, .real).toSeconds());
        var clock: [8]u8 = undefined;
        return synthetic(arena, 429, try std.fmt.allocPrint(arena, "rate limited — paused until {s}", .{sdk.budget.clockText(&clock, snap.paused_until, snap.offset_secs)}));
    }

    /// What a dry run answers every request with: nothing went out. The
    /// pane reads it as a notice, not a failed fetch (`App.applyRefresh`).
    pub const dry_run_message = "dry run — nothing sent; the pane keeps what it already shows";

    /// An answer that never came off the wire — a dry run, a pause —
    /// in Jira's own error shape, so `failureOf` reads its sentence.
    fn synthetic(arena: Allocator, status: u16, message: []const u8) Allocator.Error!Raw {
        var out: Io.Writer.Allocating = .init(arena);
        out.writer.print("{{\"errorMessages\":[{f}],\"errors\":{{}}}}", .{std.json.fmt(message, .{})}) catch return error.OutOfMemory;
        return .{ .status = status, .body = out.toOwnedSlice() catch return error.OutOfMemory, .retry_after_secs = null };
    }

    /// One try: the gate, the bucket, the wire.
    fn once(c: *Client, arena: Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8, reason: Reason, budget: *sdk.Budget, read: bool) CallError!Raw {
        // The bucket is shared, so this waits on every other process
        // too — and fails open rather than leaving the pane hung.
        // The bucket's own draw line carries the reason too, so the
        // machine-wide file says not just which program spent the
        // budget but on what.
        // Spacing, before the bucket: a burst of warm work spread one
        // per gap never drains what an interactive request needs a
        // moment later. A reader waits for nothing (`Gate.hold`) — the
        // reservation still moves the slot, so background work steps
        // behind them.
        if (c.gate) |g| {
            const prio = sdk.warm.priorityOf(reason);
            if (prio == .interactive) g.enter();
            const hold_ms = g.hold(prio, Io.Timestamp.now(c.io, .real).toMilliseconds());
            if (hold_ms > 0) c.io.sleep(.fromMilliseconds(@intCast(hold_ms)), .awake) catch {};
            if (prio == .interactive) g.leave();
        }
        // Through the local broker when mnml is hosting one, so this
        // pane queues ahead of the warmers and the batch scripts on
        // the machine — and straight off the shared file when it is
        // not, which is every run with no mnml open.
        const gate: ratelimit.Acquired = if (c.limiter) |l| blk: {
            l.reason = @tagName(reason);
            // The limiter writes the request's live phase — queued
            // behind N, waiting on the bucket, sending — where the
            // header reads it; `.idle` below is this side's to say.
            l.live = c.notice;
            break :blk l.acquireVia(sdk.warm.classOf(reason));
        } else .{ .ok = true };
        if (c.notice) |n| n.record(gate);
        defer if (c.notice) |n| n.setPhase(.idle, 0);
        const started = Io.Timestamp.now(c.io, .real);
        var client: std.http.Client = .{ .allocator = c.gpa, .io = c.io };
        defer client.deinit();
        const uri = std.Uri.parse(url) catch {
            c.note(arena, method, url, null, 0, started, gate, reason, .{}, false);
            return error.Transport;
        };
        var extra: [5]std.http.Header = .{
            .{ .name = "authorization", .value = c.authorization },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "x-atlassian-force-account-id", .value = "true" },
            .{ .name = "content-type", .value = "application/json" },
            undefined,
        };
        const n_extra: usize = if (body == null) 3 else 4;
        const transport = struct {
            fn fail(cl: *Client, ar: Allocator, m: std.http.Method, u: []const u8, st: Io.Timestamp, g: ratelimit.Acquired, r: Reason) CallError {
                // A request that never reached a status is still a line
                // in the log: a wedged socket and a throttled bucket
                // look the same on screen and must not look the same
                // here. It is still a call on the budget's count.
                cl.note(ar, m, u, null, 0, st, g, r, .{}, false);
                if (cl.budget) |b| b.record(.{ .now_secs = st.toSeconds() });
                return error.Transport;
            }
        }.fail;
        var req = client.request(method, uri, .{
            .headers = .{ .user_agent = .{ .override = c.user_agent } },
            .extra_headers = extra[0..n_extra],
            .keep_alive = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return transport(c, arena, method, url, started, gate, reason),
        };
        defer req.deinit();
        if (body) |p| {
            req.transfer_encoding = .{ .content_length = p.len };
            var bw = req.sendBodyUnflushed(&.{}) catch return transport(c, arena, method, url, started, gate, reason);
            bw.writer.writeAll(p) catch return transport(c, arena, method, url, started, gate, reason);
            bw.end() catch return transport(c, arena, method, url, started, gate, reason);
            if (req.connection) |conn| conn.flush() catch return transport(c, arena, method, url, started, gate, reason);
        } else {
            req.sendBodiless() catch return transport(c, arena, method, url, started, gate, reason);
        }
        var response = req.receiveHead(&.{}) catch return transport(c, arena, method, url, started, gate, reason);
        const status: u16 = @intFromEnum(response.head.status);
        // `Retry-After`, read off the head before the body so a body
        // that fails to read cannot swallow the hint.
        var retry_after: ?f64 = null;
        var rate_limit: request_log.RateLimit = .{};
        var hit = response.head.iterateHeaders();
        var ctype: ?[]const u8 = null;
        while (hit.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) ctype = arena.dupe(u8, h.value) catch null;
            if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
                if (sdk.ratelimit.parseRetryAfter(h.value)) |secs| retry_after = @floatFromInt(secs);
            }
            // The budget headers, by name — an allow-list, numbers only.
            request_log.rateLimitHeader(&rate_limit, h.name, h.value);
        }
        var out: Io.Writer.Allocating = .init(arena);
        var transfer: [4096]u8 = undefined;
        // The body is read through the content-encoding the site chose:
        // the std client offers gzip, deflate and zstd, and a body that
        // came back compressed is bytes the JSON parser cannot read
        // (it said "the search answer was not JSON" and nothing else).
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try arena.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try arena.alloc(u8, std.compress.flate.max_window_len),
            .compress => &.{},
        };
        var decompress: std.http.Decompress = undefined;
        const reader = if (response.head.content_encoding == .compress) response.reader(&transfer) else response.readerDecompressing(&transfer, &decompress, decompress_buffer);
        // A truncated body still leaves a usable status; the read error
        // travels with the body so a parse failure can name it.
        var read_error: ?[]const u8 = null;
        _ = reader.streamRemaining(&out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => read_error = @errorName(err),
        };
        if (response.head.content_encoding == .compress) read_error = "UnsupportedCompressionMethod";
        // A 429 or a 5xx parks every process on the bucket, not just
        // this one — for as long as the site said, when it said.
        if (ratelimit.shouldPenalise(status)) {
            if (c.limiter) |l| l.penalize(retry_after);
        }
        c.note(arena, method, url, status, out.written().len, started, gate, reason, rate_limit, false);
        // A read that carried its body back is a miss; the pane's own
        // stores count their hits (`App.seedPrs`). A write is neither.
        budget.record(.{ .now_secs = Io.Timestamp.now(c.io, .real).toSeconds(), .rate_limit = rate_limit, .cache = if (read and status >= 200 and status < 300) .miss else .none });
        return .{ .status = status, .body = out.toOwnedSlice() catch return error.OutOfMemory, .retry_after_secs = retry_after, .read_error = read_error, .content_type = ctype };
    }

    /// One line in the request log. Best effort: a log is never a
    /// reason a request fails.
    fn note(
        c: *Client,
        arena: Allocator,
        method: std.http.Method,
        url: []const u8,
        status: ?u16,
        bytes: usize,
        started: Io.Timestamp,
        gate: ratelimit.Acquired,
        reason: Reason,
        rate_limit: request_log.RateLimit,
        /// The line is what a dry run did NOT send.
        dry: bool,
    ) void {
        const log = c.log orelse return;
        const split = request_log.splitUrl(arena, url) catch return;
        const ms: u64 = @intCast(@max(Io.Timestamp.now(c.io, .real).toMilliseconds() - started.toMilliseconds(), 0));
        log.append(.{
            .service = "",
            .integration = "",
            .method = @tagName(method),
            .host = split.host,
            .path = split.path,
            .status = status,
            .ms = ms,
            .bytes = bytes,
            .reason = reason,
            .wait_ms = gate.wait_ms,
            .waited_for = gate.waited_for,
            .tokens_after = gate.tokens_after,
            .via = gate.via,
            .rate_limit = rate_limit,
            .dry = dry,
        });
    }
};

/// Jira's error shape: `{"errorMessages":["…"],"errors":{"field":"…"}}`.
/// Anything else becomes a line naming the status.
pub fn failureOf(arena: Allocator, status: u16, body: []const u8) Allocator.Error!Failure {
    const generic = switch (status) {
        401 => "401 — the token was refused (check the email and the API token)",
        403 => "403 — the token is valid but not allowed to do that",
        404 => "404 — no such issue, project or endpoint",
        410 => "410 — this Jira no longer serves that endpoint (try .api = .v2)",
        429 => "429 — rate limited; the next call backs off",
        else => "",
    };
    const parsed = std.json.parseFromSlice(Value, arena, body, .{}) catch {
        if (generic.len > 0) return .{ .status = status, .message = generic };
        return .{ .status = status, .message = try std.fmt.allocPrint(arena, "HTTP {d}", .{status}) };
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (json.array(parsed.value, "errorMessages")) |m| {
        if (json.str(m)) |s| {
            if (out.items.len > 0) try out.appendSlice(arena, "; ");
            try out.appendSlice(arena, s);
        }
    }
    if (json.get(parsed.value, "errors")) |errs| switch (errs) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (json.str(e.value_ptr.*)) |s| {
                    if (out.items.len > 0) try out.appendSlice(arena, "; ");
                    try out.appendSlice(arena, e.key_ptr.*);
                    try out.appendSlice(arena, ": ");
                    try out.appendSlice(arena, s);
                }
            }
        },
        else => {},
    };
    if (out.items.len == 0) {
        if (generic.len > 0) return .{ .status = status, .message = generic };
        return .{ .status = status, .message = try std.fmt.allocPrint(arena, "HTTP {d}", .{status}) };
    }
    return .{ .status = status, .message = try out.toOwnedSlice(arena) };
}

// ─── JQL surgery ─────────────────────────────────────────────────────────

/// Split a JQL into its `where` and its trailing `ORDER BY …`. Jira
/// rejects `(<where> ORDER BY x) AND <extra>`, so anything that adds a
/// clause has to take the order clause off first and put it back after.
/// The split is on the **last** case-insensitive `order by` that is not
/// inside double quotes.
pub fn splitOrderBy(jql: []const u8) struct { where: []const u8, order: []const u8 } {
    var in_quote = false;
    var best: ?usize = null;
    var i: usize = 0;
    while (i < jql.len) : (i += 1) {
        const c = jql[i];
        if (c == '\\' and in_quote) {
            i += 1;
            continue;
        }
        if (c == '"') {
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        if (i + 8 <= jql.len and std.ascii.eqlIgnoreCase(jql[i .. i + 8], "order by")) {
            const before_ok = i == 0 or isJqlBreak(jql[i - 1]);
            if (before_ok) best = i;
        }
    }
    const cut = best orelse return .{ .where = std.mem.trim(u8, jql, " \t"), .order = "" };
    return .{
        .where = std.mem.trim(u8, jql[0..cut], " \t"),
        .order = std.mem.trim(u8, jql[cut..], " \t"),
    };
}

fn isJqlBreak(c: u8) bool {
    return c == ' ' or c == '\t' or c == ')' or c == '\n';
}

/// `"` → `\"` for a value going inside a JQL string literal.
pub fn escapeQuotes(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '"') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '"') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

/// `(<where>) AND ("<field>" = "<team>" OR component = "<team>" OR labels = "<team>") <order>`.
/// The team is matched three ways because sites disagree about where a
/// team lives; the clause goes to the server rather than being applied
/// client-side, which used to drop matches past the row cap.
pub fn withTeam(arena: Allocator, jql: []const u8, team: []const u8, field_name: []const u8, field_id: []const u8) Allocator.Error![]const u8 {
    if (team.len == 0) return jql;
    const parts = splitOrderBy(jql);
    const t = try escapeQuotes(arena, team);
    const field = if (field_name.len > 0) field_name else field_id;
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("({s}) AND (", .{parts.where}) catch return error.OutOfMemory;
    if (field.len > 0) w.print("\"{s}\" = \"{s}\" OR ", .{ field, t }) catch return error.OutOfMemory;
    w.print("component = \"{s}\" OR labels = \"{s}\")", .{ t, t }) catch return error.OutOfMemory;
    if (parts.order.len > 0) w.print(" {s}", .{parts.order}) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `project in (A, B) AND (<where>) <order>` — the statusline count's
/// scoping. An empty list leaves the JQL alone.
/// `(<where>) AND updated >= -15m <ORDER BY …>` — the delta window, in
/// the one place the ORDER BY surgery is already done. Jira rejects
/// `(<where> ORDER BY x) AND <extra>`, which is why this cannot be a
/// `std.fmt.allocPrint` at the call site.
///
/// An empty `since` is no window: the caller wanted the whole listing.
pub fn withUpdatedSince(arena: Allocator, jql: []const u8, since: []const u8) Allocator.Error![]const u8 {
    if (since.len == 0 or jql.len == 0) return jql;
    const parts = splitOrderBy(jql);
    if (parts.order.len == 0) return std.fmt.allocPrint(arena, "({s}) AND updated >= {s}", .{ parts.where, since });
    return std.fmt.allocPrint(arena, "({s}) AND updated >= {s} {s}", .{ parts.where, since, parts.order });
}

pub fn withProjects(arena: Allocator, jql: []const u8, projects: []const []const u8) Allocator.Error![]const u8 {
    if (projects.len == 0) return jql;
    const parts = splitOrderBy(jql);
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll("project in (") catch return error.OutOfMemory;
    for (projects, 0..) |p, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.writeAll(p) catch return error.OutOfMemory;
    }
    w.print(") AND ({s})", .{parts.where}) catch return error.OutOfMemory;
    if (parts.order.len > 0) w.print(" {s}", .{parts.order}) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `project = X AND fixVersion = "v" [AND component = "c"] ORDER BY rank`.
pub fn fixVersionJql(arena: Allocator, project: []const u8, version: []const u8, component: []const u8) Allocator.Error![]const u8 {
    const v = try escapeQuotes(arena, version);
    if (component.len == 0) return std.fmt.allocPrint(arena, "project = {s} AND fixVersion = \"{s}\" ORDER BY rank", .{ project, v });
    const c = try escapeQuotes(arena, component);
    return std.fmt.allocPrint(arena, "project = {s} AND fixVersion = \"{s}\" AND component = \"{s}\" ORDER BY rank", .{ project, v, c });
}

// ─── endpoints ───────────────────────────────────────────────────────────

pub const Page = struct {
    issues: []const Value,
    next_page_token: ?[]const u8,
    is_last: bool,
    total: ?i64,
};

/// One page of a JQL search. `token` is the previous page's
/// `next_page_token` (v3) or the row offset as a decimal string (v2).
pub fn searchPage(c: *Client, arena: Allocator, jql: []const u8, extra_fields: []const []const u8, limit: u32, token: ?[]const u8, reason: Reason) CallError!Answer(Page) {
    var fields: std.ArrayListUnmanaged([]const u8) = .empty;
    try fields.appendSlice(arena, &search_fields);
    for (extra_fields) |f| if (f.len > 0) try fields.append(arena, f);

    const raw = switch (c.api) {
        .v3 => blk: {
            var body: Io.Writer.Allocating = .init(arena);
            var s: std.json.Stringify = .{ .writer = &body.writer };
            s.beginObject() catch return error.OutOfMemory;
            s.objectField("jql") catch return error.OutOfMemory;
            s.write(jql) catch return error.OutOfMemory;
            s.objectField("maxResults") catch return error.OutOfMemory;
            s.write(limit) catch return error.OutOfMemory;
            s.objectField("fields") catch return error.OutOfMemory;
            s.write(fields.items) catch return error.OutOfMemory;
            if (token) |t| {
                s.objectField("nextPageToken") catch return error.OutOfMemory;
                s.write(t) catch return error.OutOfMemory;
            }
            s.endObject() catch return error.OutOfMemory;
            const url = try std.fmt.allocPrint(arena, "{s}{s}/search/jql", .{ c.base_url, c.apiRoot() });
            break :blk try c.request(arena, .POST, url, body.written(), reason);
        },
        .v2 => blk: {
            const start = if (token) |t| std.fmt.parseInt(u32, t, 10) catch 0 else 0;
            const encoded = try text.urlEncode(arena, jql);
            const field_csv = try std.mem.join(arena, ",", fields.items);
            const url = try std.fmt.allocPrint(arena, "{s}{s}/search?jql={s}&maxResults={d}&startAt={d}&fields={s}", .{ c.base_url, c.apiRoot(), encoded, limit, start, field_csv });
            break :blk try c.request(arena, .GET, url, null, reason);
        },
    };
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch {
        return .{ .failed = .{ .status = raw.status, .message = notJson(arena, "search", raw) } };
    };
    const issues = json.array(doc, "issues");
    const total = json.getInt(doc, "total");
    return .{ .ok = .{
        .issues = issues,
        .next_page_token = switch (c.api) {
            .v3 => json.getStr(doc, "nextPageToken"),
            .v2 => blk: {
                const start = if (token) |t| std.fmt.parseInt(u32, t, 10) catch 0 else 0;
                const seen: i64 = @as(i64, start) + @as(i64, @intCast(issues.len));
                if (total) |tt| if (seen < tt and issues.len > 0) break :blk try std.fmt.allocPrint(arena, "{d}", .{seen});
                break :blk null;
            },
        },
        .is_last = json.getBool(doc, "isLast") orelse false,
        .total = total,
    } };
}

/// Every page, up to `max_issues`.
pub fn search(c: *Client, arena: Allocator, jql: []const u8, extra_fields: []const []const u8, reason: Reason) CallError!Answer([]const Value) {
    var all: std.ArrayListUnmanaged(Value) = .empty;
    var token: ?[]const u8 = null;
    while (true) {
        switch (try searchPage(c, arena, jql, extra_fields, page_size, token, reason)) {
            .failed => |f| return .{ .failed = f },
            .ok => |p| {
                try all.appendSlice(arena, p.issues);
                if (all.items.len >= max_issues) {
                    all.shrinkRetainingCapacity(max_issues);
                    break;
                }
                const next = p.next_page_token orelse break;
                if (p.is_last or p.issues.len == 0) break;
                token = next;
            },
        }
    }
    return .{ .ok = try all.toOwnedSlice(arena) };
}

// ─── issues ──────────────────────────────────────────────────────────────

/// One issue with the fields the detail pane paints.
pub fn issueDetail(c: *Client, arena: Allocator, key: []const u8) CallError!Answer(model.IssueDetail) {
    const url = try std.fmt.allocPrint(
        arena,
        "{s}{s}/issue/{s}?fields=description,comment,watches,summary,status,assignee,issuetype,priority,fixVersions,updated,reporter",
        .{ c.base_url, c.apiRoot(), key },
    );
    switch (try getJson(c, arena, url, .detail)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| return .{ .ok = try model.IssueDetail.fromJson(arena, doc) },
    }
}

/// One issue with the caller's field list (`*all` when empty), raw —
/// the detail modal paints whatever `[detail_modal] fields` asked for.
pub fn issueFull(c: *Client, arena: Allocator, key: []const u8, fields: []const []const u8) CallError!Answer(Value) {
    const csv = if (fields.len == 0) "*all" else try std.mem.join(arena, ",", fields);
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}?fields={s}", .{ c.base_url, c.apiRoot(), key, csv });
    return getJson(c, arena, url, .detail);
}

/// The tickets a JQL finds, parsed. `extra_fields` is the team select's id.
pub fn searchIssues(c: *Client, arena: Allocator, jql: []const u8, extra_fields: []const []const u8, team_field_id: []const u8, reason: Reason) CallError!Answer([]const model.Issue) {
    switch (try search(c, arena, jql, extra_fields, reason)) {
        .failed => |f| return .{ .failed = f },
        .ok => |vals| return .{ .ok = try parseIssues(arena, vals, team_field_id) },
    }
}

pub fn parseIssues(arena: Allocator, vals: []const Value, team_field_id: []const u8) Allocator.Error![]const model.Issue {
    const out = try arena.alloc(model.Issue, vals.len);
    for (vals, out) |v, *i| i.* = try model.Issue.fromJson(arena, v, team_field_id);
    return out;
}

pub fn transitions(c: *Client, arena: Allocator, key: []const u8) CallError!Answer([]const model.Transition) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/transitions", .{ c.base_url, c.apiRoot(), key });
    switch (try getJson(c, arena, url, .user)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| {
            var out: std.ArrayList(model.Transition) = .empty;
            for (json.array(doc, "transitions")) |t| try out.append(arena, .{
                .id = json.getStrOr(t, "id", ""),
                .name = json.getStrOr(t, "name", "(unnamed)"),
                .to_name = json.getStrOr(t, "to.name", ""),
            });
            return .{ .ok = try out.toOwnedSlice(arena) };
        },
    }
}

pub fn doTransition(c: *Client, arena: Allocator, key: []const u8, id: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/transitions", .{ c.base_url, c.apiRoot(), key });
    const body = try std.fmt.allocPrint(arena, "{{\"transition\":{{\"id\":\"{s}\"}}}}", .{id});
    return voidCall(c, arena, .POST, url, body, .user);
}

/// A comment. v3 takes an ADF document; v2 takes the text.
pub fn addComment(c: *Client, arena: Allocator, key: []const u8, plain: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/comment", .{ c.base_url, c.apiRoot(), key });
    var body: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &body.writer };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("body") catch return error.OutOfMemory;
    switch (c.api) {
        .v3 => writeAdf(&s, plain) catch return error.OutOfMemory,
        .v2 => s.write(plain) catch return error.OutOfMemory,
    }
    s.endObject() catch return error.OutOfMemory;
    return voidCall(c, arena, .POST, url, body.written(), .user);
}

/// `plain` as an ADF doc: one paragraph per line, a bare paragraph for a
/// blank one.
pub fn writeAdf(s: *std.json.Stringify, plain: []const u8) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("doc");
    try s.objectField("version");
    try s.write(1);
    try s.objectField("content");
    try s.beginArray();
    var it = std.mem.splitScalar(u8, plain, '\n');
    while (it.next()) |line| {
        try s.beginObject();
        try s.objectField("type");
        try s.write("paragraph");
        if (line.len > 0) {
            try s.objectField("content");
            try s.beginArray();
            try s.beginObject();
            try s.objectField("type");
            try s.write("text");
            try s.objectField("text");
            try s.write(line);
            try s.endObject();
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

/// `account_id` empty unassigns.
pub fn setAssignee(c: *Client, arena: Allocator, key: []const u8, account_id: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}", .{ c.base_url, c.apiRoot(), key });
    const body = if (account_id.len == 0)
        try arena.dupe(u8, "{\"fields\":{\"assignee\":null}}")
    else
        try std.fmt.allocPrint(arena, "{{\"fields\":{{\"assignee\":{{\"accountId\":\"{s}\"}}}}}}", .{account_id});
    return voidCall(c, arena, .PUT, url, body, .user);
}

/// The one version this ticket is for; an empty name clears the list.
pub fn setFixVersion(c: *Client, arena: Allocator, key: []const u8, name: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}", .{ c.base_url, c.apiRoot(), key });
    var body: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &body.writer };
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("fields") catch return error.OutOfMemory;
    s.beginObject() catch return error.OutOfMemory;
    s.objectField("fixVersions") catch return error.OutOfMemory;
    s.beginArray() catch return error.OutOfMemory;
    if (name.len > 0) {
        s.beginObject() catch return error.OutOfMemory;
        s.objectField("name") catch return error.OutOfMemory;
        s.write(name) catch return error.OutOfMemory;
        s.endObject() catch return error.OutOfMemory;
    }
    s.endArray() catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    s.endObject() catch return error.OutOfMemory;
    return voidCall(c, arena, .PUT, url, body.written(), .user);
}

/// Watch as the token's user: an empty JSON string as the body.
pub fn watch(c: *Client, arena: Allocator, key: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/watchers", .{ c.base_url, c.apiRoot(), key });
    return voidCall(c, arena, .POST, url, "\"\"", .user);
}

/// Unwatch needs the account id (`myself`).
pub fn unwatch(c: *Client, arena: Allocator, key: []const u8, account_id: []const u8) CallError!Answer(void) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/issue/{s}/watchers?accountId={s}", .{ c.base_url, c.apiRoot(), key, account_id });
    return voidCall(c, arena, .DELETE, url, null, .user);
}

/// The PRs Atlassian's dev panel links to the issue (by numeric id).
/// A 404 is "no dev info", not a failure.
pub fn pullRequests(c: *Client, arena: Allocator, issue_id: []const u8, reason: Reason) CallError!Answer([]const model.LinkedPr) {
    const url = try std.fmt.allocPrint(
        arena,
        "{s}/rest/dev-status/latest/issue/detail?issueId={s}&applicationType=bitbucket&dataType=pullrequest",
        .{ c.base_url, issue_id },
    );
    const raw = try c.request(arena, .GET, url, null, reason);
    if (raw.status == 404) return .{ .ok = &.{} };
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    return .{ .ok = try parsePullRequests(arena, raw.body) };
}

/// The same call, handing back the RESPONSE rather than the parsed
/// list — what a cache files under the ticket's `updated` stamp so the
/// next run can paint it without asking. Null when the site refused;
/// a failure is never worth caching.
pub fn pullRequestsRaw(c: *Client, arena: Allocator, issue_id: []const u8, reason: Reason) CallError!?[]const u8 {
    const url = try std.fmt.allocPrint(
        arena,
        "{s}/rest/dev-status/latest/issue/detail?issueId={s}&applicationType=bitbucket&dataType=pullrequest",
        .{ c.base_url, issue_id },
    );
    const raw = try c.request(arena, .GET, url, null, reason);
    // A 404 is "no dev info", not a failure — and it is worth
    // remembering, because it is the answer for most tickets.
    if (raw.status == 404) return "{\"detail\":[{\"pullRequests\":[]}]}";
    if (raw.status < 200 or raw.status >= 300) return null;
    return raw.body;
}

/// A dev-status response as the tree's rows. The same parse whether it
/// came off the wire or off the cache, which is what makes the cached
/// path paint identically.
pub fn parsePullRequests(arena: Allocator, body: []const u8) Allocator.Error![]const model.LinkedPr {
    const doc = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch Value{ .null = {} };
    var out: std.ArrayList(model.LinkedPr) = .empty;
    for (json.array(doc, "detail")) |d| {
        for (json.array(d, "pullRequests")) |p| try out.append(arena, try model.LinkedPr.fromJson(arena, p));
    }
    return out.toOwnedSlice(arena);
}

// ─── people and versions ─────────────────────────────────────────────────

/// Who the token belongs to. A scoped token often cannot answer this
/// while being perfectly able to search, so a failure here must only
/// cost the "me" features — never the pane.
pub fn myself(c: *Client, arena: Allocator) CallError!Answer(model.User) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/myself", .{ c.base_url, c.apiRoot() });
    switch (try getJson(c, arena, url, .pane_open)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| return .{ .ok = .{
            .account_id = json.getStrOr(doc, "accountId", ""),
            .display_name = json.getStrOr(doc, "displayName", ""),
        } },
    }
}

pub fn assignableUsers(c: *Client, arena: Allocator, project: []const u8) CallError!Answer([]const model.User) {
    const p = try text.urlEncode(arena, project);
    const url = try std.fmt.allocPrint(arena, "{s}{s}/user/assignable/search?project={s}&query=&maxResults=50", .{ c.base_url, c.apiRoot(), p });
    // A picker the user opened.
    const raw = try c.request(arena, .GET, url, null, .user);
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch Value{ .null = {} };
    const items: []const Value = switch (doc) {
        .array => |a| a.items,
        else => json.array(doc, "values"),
    };
    var out: std.ArrayList(model.User) = .empty;
    for (items) |u| {
        const id = json.getStrOr(u, "accountId", "");
        if (id.len == 0) continue;
        try out.append(arena, .{ .account_id = id, .display_name = json.getStrOr(u, "displayName", id) });
    }
    return .{ .ok = try out.toOwnedSlice(arena) };
}

pub fn projectVersions(c: *Client, arena: Allocator, project: []const u8) CallError!Answer([]const model.Version) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/project/{s}/versions", .{ c.base_url, c.apiRoot(), project });
    const raw = try c.request(arena, .GET, url, null, .pane_open);
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch Value{ .null = {} };
    const items: []const Value = switch (doc) {
        .array => |a| a.items,
        else => json.array(doc, "values"),
    };
    var out: std.ArrayList(model.Version) = .empty;
    for (items) |v| try out.append(arena, .{
        .name = json.getStrOr(v, "name", ""),
        .released = json.getBool(v, "released") orelse false,
        .archived = json.getBool(v, "archived") orelse false,
        .start_date = json.getStrOr(v, "startDate", ""),
        .release_date = json.getStrOr(v, "releaseDate", ""),
    });
    return .{ .ok = try out.toOwnedSlice(arena) };
}

/// The unreleased versions in the order a release tab reads them:
/// `startDate` ascending with the undated last, and **name descending**
/// between two undated ones (most projects never set a start date, and
/// `13.16.0` is the one being worked on, not `13.1.0`). `contains`
/// narrows to one release track first.
pub fn unreleasedVersions(arena: Allocator, all: []const model.Version, contains: []const u8) Allocator.Error![]const model.Version {
    var keep: std.ArrayList(model.Version) = .empty;
    for (all) |v| {
        if (v.released) continue;
        if (contains.len > 0 and !text.containsIgnoreCase(v.name, contains)) continue;
        try keep.append(arena, v);
    }
    std.mem.sort(model.Version, keep.items, {}, versionBefore);
    return keep.toOwnedSlice(arena);
}

fn versionBefore(_: void, a: model.Version, b: model.Version) bool {
    const ad = a.start_date.len > 0;
    const bd = b.start_date.len > 0;
    if (ad and bd) {
        const c = std.mem.order(u8, a.start_date, b.start_date);
        if (c != .eq) return c == .lt;
        return std.mem.order(u8, a.name, b.name) == .gt;
    }
    if (ad != bd) return ad;
    return std.mem.order(u8, a.name, b.name) == .gt;
}

/// The picker's order: unreleased first, each half by `startDate`
/// descending then name descending, archived ones dropped.
pub fn pickerVersions(arena: Allocator, all: []const model.Version) Allocator.Error![]const model.Version {
    var keep: std.ArrayList(model.Version) = .empty;
    for (all) |v| if (!v.archived) try keep.append(arena, v);
    std.mem.sort(model.Version, keep.items, {}, pickerBefore);
    return keep.toOwnedSlice(arena);
}

fn pickerBefore(_: void, a: model.Version, b: model.Version) bool {
    if (a.released != b.released) return !a.released;
    const ad = a.start_date.len > 0;
    const bd = b.start_date.len > 0;
    if (ad and bd) {
        const c = std.mem.order(u8, a.start_date, b.start_date);
        if (c != .eq) return c == .gt;
        return std.mem.order(u8, a.name, b.name) == .gt;
    }
    if (ad != bd) return ad;
    return std.mem.order(u8, a.name, b.name) == .gt;
}

/// The version a release tab means: the first unreleased one, or the
/// one after it (falling back to the first).
pub fn pickVersion(list: []const model.Version, mode: config.ResolveMode) ?model.Version {
    if (list.len == 0) return null;
    return switch (mode) {
        .current_release => list[0],
        .next_release => if (list.len > 1) list[1] else list[0],
    };
}

// ─── the Agile API ───────────────────────────────────────────────────────

pub const agile_root = "/rest/agile/1.0";

/// The board's issues (its saved filter + active sprint), paged by
/// `startAt`, with `extra_jql` ANDed in, capped at `max_issues`.
pub fn boardIssues(c: *Client, arena: Allocator, board_id: u64, extra_jql: ?[]const u8, extra_fields: []const []const u8, reason: Reason) CallError!Answer([]const Value) {
    var fields: std.ArrayList([]const u8) = .empty;
    try fields.appendSlice(arena, &search_fields);
    for (extra_fields) |f| if (f.len > 0) try fields.append(arena, f);
    const csv = try std.mem.join(arena, ",", fields.items);
    var all: std.ArrayList(Value) = .empty;
    var start: u32 = 0;
    while (true) {
        var url = try std.fmt.allocPrint(arena, "{s}{s}/board/{d}/issue?fields={s}&maxResults={d}&startAt={d}", .{ c.base_url, agile_root, board_id, csv, page_size, start });
        if (extra_jql) |j| if (std.mem.trim(u8, j, " ").len > 0) {
            url = try std.fmt.allocPrint(arena, "{s}&jql={s}", .{ url, try text.urlEncode(arena, j) });
        };
        const raw = try c.request(arena, .GET, url, null, reason);
        if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
        const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch {
            return .{ .failed = .{ .status = raw.status, .message = notJson(arena, "board", raw) } };
        };
        const issues = json.array(doc, "issues");
        try all.appendSlice(arena, issues);
        if (all.items.len >= max_issues) {
            all.shrinkRetainingCapacity(max_issues);
            break;
        }
        const got: u32 = @intCast(issues.len);
        const total = json.getInt(doc, "total");
        const done_by_total = if (total) |t| (@as(i64, start) + got) >= t else false;
        if (got < page_size or done_by_total or (json.getBool(doc, "isLast") orelse false)) break;
        start += page_size;
    }
    return .{ .ok = try all.toOwnedSlice(arena) };
}

pub fn board(c: *Client, arena: Allocator, board_id: u64) CallError!Answer(model.Board) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/board/{d}", .{ c.base_url, agile_root, board_id });
    switch (try getJson(c, arena, url, .pane_open)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| return .{ .ok = .{
            .id = @intCast(@max(json.getInt(doc, "id") orelse 0, 0)),
            .name = json.getStrOr(doc, "name", ""),
            .kind = json.getStrOr(doc, "type", ""),
        } },
    }
}

pub fn boardsForProject(c: *Client, arena: Allocator, project: []const u8) CallError!Answer([]const model.Board) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/board?projectKeyOrId={s}&maxResults=100", .{ c.base_url, agile_root, try text.urlEncode(arena, project) });
    switch (try getJson(c, arena, url, .user)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| {
            var out: std.ArrayList(model.Board) = .empty;
            for (json.array(doc, "values")) |b| try out.append(arena, .{
                .id = @intCast(@max(json.getInt(b, "id") orelse 0, 0)),
                .name = json.getStrOr(b, "name", ""),
                .kind = json.getStrOr(b, "type", ""),
            });
            return .{ .ok = try out.toOwnedSlice(arena) };
        },
    }
}

/// The board's sprints: active and future in full, then the most recent
/// closed ones (the endpoint pages oldest first, so the closed tail is
/// asked for from `total - 20`). A kanban board answers 400 to any of
/// these, which is an empty list, not a failure.
pub fn sprintsForBoard(c: *Client, arena: Allocator, board_id: u64) CallError!Answer([]const model.Sprint) {
    var out: std.ArrayList(model.Sprint) = .empty;
    for ([_][]const u8{ "active", "future" }) |state| {
        switch (try sprintPage(c, arena, board_id, state, 0, 50)) {
            .failed => |f| {
                if (f.status == 400) return .{ .ok = &.{} };
                return .{ .failed = f };
            },
            .ok => |page| try out.appendSlice(arena, page.values),
        }
    }
    switch (try sprintPage(c, arena, board_id, "closed", 0, 1)) {
        .ok => |probe| {
            const total: u32 = @intCast(@max(probe.total, 0));
            const start = total -| 20;
            switch (try sprintPage(c, arena, board_id, "closed", start, 20)) {
                .ok => |page| try out.appendSlice(arena, page.values),
                .failed => {},
            }
        },
        .failed => {},
    }
    return .{ .ok = try out.toOwnedSlice(arena) };
}

const SprintPage = struct { values: []const model.Sprint, total: i64 };

fn sprintPage(c: *Client, arena: Allocator, board_id: u64, state: []const u8, start: u32, max: u32) CallError!Answer(SprintPage) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/board/{d}/sprint?state={s}&startAt={d}&maxResults={d}", .{ c.base_url, agile_root, board_id, state, start, max });
    switch (try getJson(c, arena, url, .pane_open)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| {
            var out: std.ArrayList(model.Sprint) = .empty;
            for (json.array(doc, "values")) |s| try out.append(arena, .{
                .id = @intCast(@max(json.getInt(s, "id") orelse 0, 0)),
                .name = json.getStrOr(s, "name", ""),
                .state = json.getStrOr(s, "state", ""),
                .start_date = json.getStrOr(s, "startDate", ""),
                .end_date = json.getStrOr(s, "endDate", ""),
                .complete_date = json.getStrOr(s, "completeDate", ""),
            });
            return .{ .ok = .{ .values = try out.toOwnedSlice(arena), .total = json.getInt(doc, "total") orelse @as(i64, @intCast(out.items.len)) } };
        },
    }
}

pub fn quickFilters(c: *Client, arena: Allocator, board_id: u64) CallError!Answer([]const model.QuickFilter) {
    const url = try std.fmt.allocPrint(arena, "{s}{s}/board/{d}/quickfilter?maxResults=50", .{ c.base_url, agile_root, board_id });
    switch (try getJson(c, arena, url, .pane_open)) {
        .failed => |f| return .{ .failed = f },
        .ok => |doc| {
            var out: std.ArrayList(model.QuickFilter) = .empty;
            for (json.array(doc, "values")) |q| try out.append(arena, .{
                .id = @intCast(@max(json.getInt(q, "id") orelse 0, 0)),
                .name = json.getStrOr(q, "name", ""),
                .jql = json.getStrOr(q, "jql", ""),
            });
            return .{ .ok = try out.toOwnedSlice(arena) };
        },
    }
}

// ─── shared shapes ───────────────────────────────────────────────────────

fn getJson(c: *Client, arena: Allocator, url: []const u8, reason: Reason) CallError!Answer(Value) {
    const raw = try c.request(arena, .GET, url, null, reason);
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    const doc = std.json.parseFromSliceLeaky(Value, arena, raw.body, .{}) catch {
        return .{ .failed = .{ .status = raw.status, .message = notJson(arena, "", raw) } };
    };
    return .{ .ok = doc };
}

fn voidCall(c: *Client, arena: Allocator, method: std.http.Method, url: []const u8, body: ?[]const u8, reason: Reason) CallError!Answer(void) {
    const raw = try c.request(arena, method, url, body, reason);
    if (raw.status < 200 or raw.status >= 300) return .{ .failed = try failureOf(arena, raw.status, raw.body) };
    return .{ .ok = {} };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "splitOrderBy takes the last one outside quotes, and leaves a JQL without one alone" {
    const a = splitOrderBy("project = X AND summary ~ \"order by me\" ORDER BY rank ASC");
    try testing.expectEqualStrings("project = X AND summary ~ \"order by me\"", a.where);
    try testing.expectEqualStrings("ORDER BY rank ASC", a.order);
    const b = splitOrderBy("project = X");
    try testing.expectEqualStrings("project = X", b.where);
    try testing.expectEqualStrings("", b.order);
    const c = splitOrderBy("(a = 1 OR b = 2) order by updated DESC");
    try testing.expectEqualStrings("(a = 1 OR b = 2)", c.where);
    const d = splitOrderBy("reorder by = 1");
    try testing.expectEqualStrings("reorder by = 1", d.where);
}

test "the team clause goes to the server, wrapping the where and keeping the order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings(
        "(assignee = currentUser()) AND (\"Team\" = \"Apollo\" OR component = \"Apollo\" OR labels = \"Apollo\") ORDER BY updated DESC",
        try withTeam(arena, "assignee = currentUser() ORDER BY updated DESC", "Apollo", "Team", "customfield_1"),
    );
    try testing.expect(std.mem.indexOf(u8, try withTeam(arena, "project = X", "T", "", "customfield_1"), "\"customfield_1\" = \"T\"") != null);
    try testing.expectEqualStrings("(project = X) AND (component = \"T\" OR labels = \"T\")", try withTeam(arena, "project = X", "T", "", ""));
    try testing.expectEqualStrings("project = X", try withTeam(arena, "project = X", "", "Team", ""));
    try testing.expectEqualStrings(
        "project in (ENG, OPS) AND (assignee = currentUser()) ORDER BY updated DESC",
        try withProjects(arena, "assignee = currentUser() ORDER BY updated DESC", &.{ "ENG", "OPS" }),
    );
    try testing.expectEqualStrings("project = ENG AND fixVersion = \"13.15.0\" ORDER BY rank", try fixVersionJql(arena, "ENG", "13.15.0", ""));
    try testing.expect(std.mem.indexOf(u8, try fixVersionJql(arena, "ENG", "a\"b", ""), "\"a\\\"b\"") != null);
}

test "versions: the release resolve order and the picker order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const all = [_]model.Version{
        .{ .name = "13.14.0", .released = true },
        .{ .name = "13.15.0" },
        .{ .name = "13.16.0", .start_date = "2026-09-01" },
        .{ .name = "13.17.0", .start_date = "2026-09-15" },
        .{ .name = "Mobile - 1.6.X", .archived = true },
    };
    const open = try unreleasedVersions(arena, &all, "");
    try testing.expectEqual(@as(usize, 4), open.len);
    try testing.expectEqualStrings("13.16.0", open[0].name);
    try testing.expectEqualStrings("13.17.0", open[1].name);
    try testing.expectEqualStrings("Mobile - 1.6.X", open[2].name);
    try testing.expectEqualStrings("13.15.0", open[3].name);
    try testing.expectEqualStrings("13.16.0", pickVersion(open, .current_release).?.name);
    try testing.expectEqualStrings("13.17.0", pickVersion(open, .next_release).?.name);
    const track = try unreleasedVersions(arena, &all, "13.");
    try testing.expectEqual(@as(usize, 3), track.len);
    try testing.expect(pickVersion(&.{}, .current_release) == null);
    // The picker: unreleased first, dated by start desc, archived gone.
    const pick = try pickerVersions(arena, &all);
    try testing.expectEqual(@as(usize, 4), pick.len);
    try testing.expectEqualStrings("13.17.0", pick[0].name);
    try testing.expectEqualStrings("13.16.0", pick[1].name);
    try testing.expectEqualStrings("13.15.0", pick[2].name);
    try testing.expectEqualStrings("13.14.0", pick[3].name);
}

test "a Jira error answer becomes the sentence Jira wrote, not the number" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    try testing.expectEqualStrings("Field 'wat' does not exist.", (try failureOf(arena, 400, "{\"errorMessages\":[\"Field 'wat' does not exist.\"],\"errors\":{}}")).message);
    try testing.expectEqualStrings("summary: is required", (try failureOf(arena, 400, "{\"errorMessages\":[],\"errors\":{\"summary\":\"is required\"}}")).message);
    try testing.expect(std.mem.indexOf(u8, (try failureOf(arena, 401, "<html>nope</html>")).message, "token was refused") != null);
    try testing.expectEqualStrings("HTTP 418", (try failureOf(arena, 418, "{}")).message);
}

test "ADF: one paragraph per line, a bare one for a blank line" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try writeAdf(&s, "first\n\nthird");
    try testing.expectEqualStrings(
        "{\"type\":\"doc\",\"version\":1,\"content\":[" ++
            "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"first\"}]}," ++
            "{\"type\":\"paragraph\"}," ++
            "{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"third\"}]}]}",
        out.written(),
    );
}

// ─── the wire, end to end ────────────────────────────────────────────────
//
// `tools/fake_jira` is the same store the unit tests drive as a pure
// function; here it is behind a real socket, so the client's URLs,
// headers, bodies and status handling are all exercised against an
// answer that came off a TCP connection.

pub const fake = @import("../tools/fake_jira/main.zig");

/// A fake Jira behind a real socket, for the pane's tests too.
///
/// One connection at a time, answered by the binary's own
/// `fake.serveOne`. A connection whose client hung up — a pane worker
/// cancelled between its connect and its answer, which is what every
/// test's teardown does to a fetch still on the wire — is dropped and
/// the loop takes the next one. This loop used to END on one instead,
/// and every request after it sat in the listen backlog with nobody to
/// accept it: a unit suite hung for 53 minutes on a loaded machine.
pub const Loopback = struct {
    store: *fake.Store,
    server: *Io.net.Server,
    /// Connections taken.
    served: std.atomic.Value(u32) = .init(0),
    /// Connections whose client hung up before its answer.
    dropped: std.atomic.Value(u32) = .init(0),
    /// Where the loop is, for a watchdog on another thread to name.
    phase: std.atomic.Value(Phase) = .init(.accepting),

    pub const Phase = enum(u8) {
        /// Parked in `accept`, waiting for the next client.
        accepting,
        /// Reading a request or writing its answer.
        answering,
        /// Asked to stop (`/__done`): the loop is over, as it should be.
        done,
        /// Cancelled: the loop is over, as it should be.
        canceled,
    };

    /// Serve until the client asks for `/__done` or the task is cancelled.
    pub fn serve(io: Io, lb: *Loopback) Io.Cancelable!void {
        while (true) {
            lb.phase.store(.accepting, .release);
            const stream = lb.server.accept(io) catch |err| switch (err) {
                error.Canceled => {
                    lb.phase.store(.canceled, .release);
                    return error.Canceled;
                },
                // A connection given up on before it was taken, a
                // moment out of descriptors: the next accept may be
                // fine (the binary's loop does the same).
                else => {
                    io.sleep(.fromMilliseconds(10), .awake) catch {
                        lb.phase.store(.canceled, .release);
                        return error.Canceled;
                    };
                    continue;
                },
            };
            defer stream.close(io);
            _ = lb.served.fetchAdd(1, .monotonic);
            lb.phase.store(.answering, .release);
            switch (fake.serveOne(lb.store.gpa, io, lb.store, stream, .{ .stop_path = "/__done", .stamp_clock = false })) {
                .answered => {},
                .dropped => _ = lb.dropped.fetchAdd(1, .monotonic),
                .stop => {
                    lb.phase.store(.done, .release);
                    return;
                },
                .canceled => {
                    lb.phase.store(.canceled, .release);
                    return error.Canceled;
                },
            }
        }
    }

    pub fn finish(lb: *Loopback, c: *Client, arena: Allocator) !void {
        _ = lb;
        const url = try std.fmt.allocPrint(arena, "{s}/__done", .{c.base_url});
        _ = c.request(arena, .GET, url, null, .user) catch {};
    }
};

fn okOr(comptime T: type, answer: Answer(T)) !T {
    return switch (answer) {
        .ok => |v| v,
        .failed => |f| {
            std.debug.print("call failed: {d} {s}\n", .{ f.status, f.message });
            return error.TestUnexpectedResult;
        },
    };
}

test "the client against a real socket: search, detail, the full issue, transitions, a comment, an assignment, watchers, the PRs" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try fake.Store.init(testing.allocator);
    defer store.deinit();
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var lb: Loopback = .{ .store = &store, .server = &server };
    var group: Io.Group = .init;
    try group.concurrent(io, Loopback.serve, .{ io, &lb });
    defer group.cancel(io);

    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    const authorization = try @import("auth.zig").basicHeader(arena, "fake@acme.com", "fake-token");
    var c = Client.init(testing.allocator, io, base, authorization, .v3);

    const all = try okOr([]const model.Issue, try searchIssues(&c, arena, "project = ENG ORDER BY rank", &.{"customfield_10056"}, "customfield_10056", .pane_open));
    try testing.expectEqual(@as(usize, fake.issue_count), all.len);
    try testing.expectEqualStrings("ENG-1", all[0].key);
    try testing.expectEqualStrings("Checkout rewrite", all[0].summary);
    try testing.expectEqualStrings("Apollo", all[0].team);
    try testing.expectEqualStrings("ENG-1", all[1].epicKey().?);
    try testing.expectEqualStrings("Sprint 4", all[1].sprint);

    const mine = try okOr([]const model.Issue, try searchIssues(&c, arena, TabKindJql(.work_assigned), &.{}, "", .pane_open));
    try testing.expectEqual(@as(usize, 3), mine.len);

    const d = try okOr(model.IssueDetail, try issueDetail(&c, arena, "ENG-2"));
    try testing.expect(std.mem.indexOf(u8, d.description, "loses focus") != null);
    try testing.expectEqual(@as(usize, 2), d.comments.len);
    try testing.expect(d.watching);

    const full = try okOr(Value, try issueFull(&c, arena, "ENG-2", &.{ "summary", "labels", "customfield_10056" }));
    try testing.expectEqualStrings("Apollo", try model.fieldDisplay(arena, full, "customfield_10056"));

    const ts = try okOr([]const model.Transition, try transitions(&c, arena, "ENG-3"));
    try testing.expectEqual(@as(usize, 4), ts.len);
    var start_id: []const u8 = "";
    for (ts) |t| if (std.mem.eql(u8, t.to_name, "In Progress")) {
        start_id = t.id;
    };
    try testing.expect((try doTransition(&c, arena, "ENG-3", start_id)) == .ok);
    try testing.expectEqualStrings("In Progress", store.find("ENG-3").?.status);

    try testing.expect((try addComment(&c, arena, "ENG-3", "picking this up")) == .ok);
    try testing.expect((try setAssignee(&c, arena, "ENG-3", fake.account_me)) == .ok);
    try testing.expectEqualStrings(fake.account_me, store.find("ENG-3").?.assignee);
    try testing.expect((try setFixVersion(&c, arena, "ENG-3", "13.15.0")) == .ok);
    try testing.expectEqualStrings("13.15.0", store.find("ENG-3").?.fix_version);

    // Watch, then unwatch with the account id from /myself.
    const me = try okOr(model.User, try myself(&c, arena));
    try testing.expectEqualStrings(fake.account_me, me.account_id);
    try testing.expect((try watch(&c, arena, "ENG-3")) == .ok);
    try testing.expect((try okOr(model.IssueDetail, try issueDetail(&c, arena, "ENG-3"))).watching);
    try testing.expect((try unwatch(&c, arena, "ENG-3", me.account_id)) == .ok);
    try testing.expect(!(try okOr(model.IssueDetail, try issueDetail(&c, arena, "ENG-3"))).watching);

    const prs = try okOr([]const model.LinkedPr, try pullRequests(&c, arena, "10002", .refresh));
    try testing.expectEqual(@as(usize, 2), prs.len);
    try testing.expectEqualStrings("#2023", prs[0].id);
    try testing.expectEqualStrings("checkout", prs[0].repo);
    try testing.expectEqual(@as(u16, 2), prs[0].approvals());
    try testing.expectEqual(@as(usize, 0), (try okOr([]const model.LinkedPr, try pullRequests(&c, arena, "10001", .refresh))).len);

    const users = try okOr([]const model.User, try assignableUsers(&c, arena, "ENG"));
    try testing.expectEqual(@as(usize, fake.user_count), users.len);
    const versions = try okOr([]const model.Version, try projectVersions(&c, arena, "ENG"));
    try testing.expectEqualStrings("13.16.0", pickVersion(try unreleasedVersions(arena, versions, ""), .current_release).?.name);

    try lb.finish(&c, arena);
    try group.await(io);
}

fn TabKindJql(k: config.TabKind) []const u8 {
    return k.defaultJql().?;
}

test "the client against a real socket: the Agile API — board issues, the board, the boards, sprints, quick filters" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = try fake.Store.init(testing.allocator);
    defer store.deinit();
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var lb: Loopback = .{ .store = &store, .server = &server };
    var group: Io.Group = .init;
    try group.concurrent(io, Loopback.serve, .{ io, &lb });
    defer group.cancel(io);
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    const authorization = try @import("auth.zig").basicHeader(arena, "fake@acme.com", "fake-token");
    var c = Client.init(testing.allocator, io, base, authorization, .v3);

    const sprint_issues = try okOr([]const Value, try boardIssues(&c, arena, fake.board_scrum, null, &.{}, .pane_open));
    try testing.expectEqual(@as(usize, fake.sprint_issue_count), sprint_issues.len);
    const bugs = try okOr([]const Value, try boardIssues(&c, arena, fake.board_scrum, "(issuetype = Bug)", &.{}, .pane_open));
    try testing.expectEqual(@as(usize, 2), bugs.len);
    const b = try okOr(model.Board, try board(&c, arena, fake.board_scrum));
    try testing.expectEqualStrings("Checkout board", b.name);
    try testing.expectEqualStrings("scrum", b.kind);
    const boards = try okOr([]const model.Board, try boardsForProject(&c, arena, "ENG"));
    try testing.expectEqual(@as(usize, 2), boards.len);
    const sprints = try okOr([]const model.Sprint, try sprintsForBoard(&c, arena, fake.board_scrum));
    try testing.expectEqual(@as(usize, 4), sprints.len);
    try testing.expectEqualStrings("Sprint 4", sprints[0].name);
    try testing.expect(sprints[0].isActive());
    try testing.expectEqual(@as(usize, 0), (try okOr([]const model.Sprint, try sprintsForBoard(&c, arena, fake.board_kanban))).len);
    const qf = try okOr([]const model.QuickFilter, try quickFilters(&c, arena, fake.board_scrum));
    try testing.expectEqual(@as(usize, 2), qf.len);
    try testing.expectEqualStrings("Only bugs", qf[0].name);
    try testing.expectEqual(@as(usize, 0), (try okOr([]const model.QuickFilter, try quickFilters(&c, arena, fake.board_kanban))).len);

    try lb.finish(&c, arena);
    try group.await(io);
}

test "a refusal comes back as Jira's own sentence, and a 429 parks the shared bucket for every process" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = try fake.Store.init(testing.allocator);
    defer store.deinit();
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var lb: Loopback = .{ .store = &store, .server = &server };
    var group: Io.Group = .init;
    try group.concurrent(io, Loopback.serve, .{ io, &lb });
    defer group.cancel(io);
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var c = Client.init(testing.allocator, io, base, "Basic bm9wZQ==", .v3);
    // A bucket of its own, in a temporary directory: the real one is
    // shared with the user's running panes and must never be touched by
    // a test.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const bucket_path = try std.fs.path.join(arena, &.{ dir, "jira-ratelimit.json" });
    var bucket = try ratelimit.Limiter.init(testing.allocator, io, bucket_path, .{ .max_block_secs = 0.1 });
    defer bucket.deinit();
    c.limiter = &bucket;
    switch (try search(&c, arena, "project = ENG", &.{}, .pane_open)) {
        .ok => return error.TestUnexpectedResult,
        .failed => |f| {
            try testing.expectEqual(@as(u16, 401), f.status);
            try testing.expect(std.mem.indexOf(u8, f.message, "must be authenticated") != null);
        },
    }
    store.require_auth = false;
    store.fail_with = 429;
    _ = try search(&c, arena, "project = ENG", &.{}, .pane_open);
    // The 429 landed in the file, so a second process — another pane,
    // the statusline poller — is parked by it too.
    const st = bucket.status().?;
    try testing.expectEqual(@as(u32, 1), st.throttles);
    try testing.expect(st.cooldown_remaining_secs > 1.0);
    var other = try ratelimit.Limiter.init(testing.allocator, io, bucket_path, .{ .max_block_secs = 0.1 });
    defer other.deinit();
    try testing.expect(!other.acquire());
    store.fail_with = null;
    try lb.finish(&c, arena);
    try group.await(io);
}

test "a 429 with Retry-After parks the bucket for what the site asked, then the request asks again" {
    // hunt/findings-2026-09-23/integ-jira-429-ignores-retry-after.md: the
    // header was never read (`fetch` hides it), the bucket parked for
    // 45 s when the site asked for 2, and nothing asked again.
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store = try fake.Store.init(testing.allocator);
    defer store.deinit();
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var lb: Loopback = .{ .store = &store, .server = &server };
    var group: Io.Group = .init;
    try group.concurrent(io, Loopback.serve, .{ io, &lb });
    defer group.cancel(io);
    const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var c = Client.init(testing.allocator, io, base, "Basic bm9wZQ==", .v3);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const bucket_path = try std.fs.path.join(arena, &.{ dir, "jira-ratelimit.json" });
    var bucket = try ratelimit.Limiter.init(testing.allocator, io, bucket_path, .{ .max_block_secs = 0.1 });
    defer bucket.deinit();
    c.limiter = &bucket;
    store.require_auth = false;
    store.rate_limit_next = 1;
    store.rate_limit_retry_after = 1;
    const before = store.requests;
    const t0 = Io.Timestamp.now(io, .real).toMilliseconds();
    switch (try search(&c, arena, "project = ENG", &.{}, .refresh)) {
        .ok => |issues| try testing.expect(issues.len > 0),
        .failed => return error.TestUnexpectedResult,
    }
    // Asked twice — the 429, then the answer — about a second apart.
    try testing.expectEqual(@as(usize, 2), store.requests - before);
    try testing.expect(Io.Timestamp.now(io, .real).toMilliseconds() - t0 >= 900);
    // The park was the site's second, not the 45 s default.
    const st = bucket.status().?;
    try testing.expectEqual(@as(u32, 1), st.throttles);
    try testing.expect(st.cooldown_remaining_secs < 2.0);
    try lb.finish(&c, arena);
    try group.await(io);
}

/// A client on the loopback fake with the pane's budget, for the
/// budget tests below.
const BudgetRig = struct {
    store: fake.Store,
    server: Io.net.Server,
    lb: Loopback,
    group: Io.Group = .init,
    budget: sdk.Budget = .{},
    c: Client,

    fn start(r: *BudgetRig, arena: Allocator) !void {
        const io = testing.io;
        r.store = try fake.Store.init(testing.allocator);
        r.store.require_auth = false;
        var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        r.server = try addr.listen(io, .{ .reuse_address = true });
        r.lb = .{ .store = &r.store, .server = &r.server };
        r.group = .init;
        try r.group.concurrent(io, Loopback.serve, .{ io, &r.lb });
        const base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{r.server.socket.address.getPort()});
        r.c = Client.init(testing.allocator, io, base, "Basic bm9wZQ==", .v3);
        r.budget = .{};
        r.budget.configure(io, .{ .label = "Jira", .service = "jira" });
        r.c.budget = &r.budget;
    }

    fn stop(r: *BudgetRig, arena: Allocator) void {
        r.c.budget = null;
        r.lb.finish(&r.c, arena) catch {};
        r.group.await(testing.io) catch {};
        r.server.deinit(testing.io);
        r.store.deinit();
    }
};

test "a 429 on a write pauses the budget and goes back to the pane: a transition is never asked twice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: BudgetRig = undefined;
    try r.start(arena);
    defer r.stop(arena);
    r.store.rate_limit_next = 1;
    r.store.rate_limit_retry_after = 2;
    const before = r.store.requests;
    switch (try doTransition(&r.c, arena, "ENG-2", "31")) {
        .ok => return error.TestUnexpectedResult,
        .failed => |f| try testing.expectEqual(@as(u16, 429), f.status),
    }
    try testing.expectEqual(@as(usize, 1), r.store.requests - before);
    try testing.expect(r.budget.snapshot(Io.Timestamp.now(testing.io, .real).toSeconds()).paused_until > 0);
}

test "a call on the paint loop never waits a pause out: a 429 answers at once, and nothing goes out while the pause runs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: BudgetRig = undefined;
    try r.start(arena);
    defer r.stop(arena);
    r.store.rate_limit_next = 1;
    r.store.rate_limit_retry_after = 20;
    var c = r.c;
    c.wait_pauses = false;
    const before = r.store.requests;
    const t0 = Io.Timestamp.now(testing.io, .real).toMilliseconds();
    switch (try myself(&c, arena)) {
        .ok => return error.TestUnexpectedResult,
        .failed => |f| try testing.expectEqual(@as(u16, 429), f.status),
    }
    switch (try myself(&c, arena)) {
        .ok => return error.TestUnexpectedResult,
        .failed => |f| try testing.expect(std.mem.indexOf(u8, f.message, "paused until") != null),
    }
    try testing.expect(Io.Timestamp.now(testing.io, .real).toMilliseconds() - t0 < 5000);
    try testing.expectEqual(@as(usize, 1), r.store.requests - before);
    // `stop` sends its `/__done` past the pause.
    _ = r.budget.cancelWait();
}

test "the budget reads Jira's rate-limit headers — the ISO reset too — and a read that carried a body is a miss" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: BudgetRig = undefined;
    try r.start(arena);
    defer r.stop(arena);
    r.store.budget_limit = 500;
    r.store.budget_remaining = 51;
    r.store.budget_reset = "2026-09-25T14:10:00.000Z";
    switch (try search(&r.c, arena, "project = ENG", &.{}, .refresh)) {
        .ok => {},
        .failed => return error.TestUnexpectedResult,
    }
    const s = r.budget.snapshot(Io.Timestamp.now(testing.io, .real).toSeconds());
    try testing.expectEqual(@as(?i64, 500), s.limit);
    try testing.expectEqual(@as(?i64, 50), s.remaining);
    try testing.expectEqual(@as(?i64, 1_790_345_400), s.reset);
    try testing.expectEqual(@as(u32, 1), s.misses);
    try testing.expectEqual(@as(u32, 1), s.hour_calls);
    try testing.expectEqual(sdk.budget.Tier.alarm, s.tier());
}

test "dry run sends nothing: the pane gets Jira's own shape of a refusal, and the log says what would have gone out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    var log = try sdk.RequestLog.openAt(testing.allocator, testing.io, dir, "jira", "mnml-jira");
    defer log.deinit();
    var r: BudgetRig = undefined;
    try r.start(arena);
    defer r.stop(arena);
    r.c.log = &log;
    _ = r.budget.toggleDry();
    const before = r.store.requests;
    switch (try search(&r.c, arena, "project = ENG", &.{}, .refresh)) {
        .ok => return error.TestUnexpectedResult,
        .failed => |f| try testing.expect(std.mem.indexOf(u8, f.message, "dry run") != null),
    }
    switch (try doTransition(&r.c, arena, "ENG-2", "31")) {
        .ok => return error.TestUnexpectedResult,
        .failed => {},
    }
    try testing.expectEqual(before, r.store.requests);
    const p = try log.path(testing.allocator);
    defer testing.allocator.free(p);
    const lines = try Io.Dir.cwd().readFileAlloc(testing.io, p, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(lines);
    try testing.expect(std.mem.indexOf(u8, lines, "\"dry\":true") != null);
    try testing.expect(std.mem.indexOf(u8, lines, "\"route\":\"/rest/api/3/issue/{key}/transitions\"") != null);
    _ = r.budget.toggleDry();
}

test "a delta window wraps the where and keeps the ORDER BY, and an empty window is the whole listing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "(assignee = currentUser() AND resolution = Unresolved) AND updated >= -7m ORDER BY updated DESC",
        try withUpdatedSince(a, "assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC", "-7m"),
    );
    // No ORDER BY to keep.
    try testing.expectEqualStrings(
        "(project = ENG) AND updated >= -30m",
        try withUpdatedSince(a, "project = ENG", "-30m"),
    );
    // No window is the query untouched — a caller that has never
    // synced asks for everything.
    try testing.expectEqualStrings("project = ENG", try withUpdatedSince(a, "project = ENG", ""));
    try testing.expectEqualStrings("", try withUpdatedSince(a, "", "-5m"));
    // An `order by` inside a quoted value is not the ORDER BY.
    try testing.expectEqualStrings(
        "(summary ~ \"order by rank\") AND updated >= -5m ORDER BY rank",
        try withUpdatedSince(a, "summary ~ \"order by rank\" ORDER BY rank", "-5m"),
    );
}
