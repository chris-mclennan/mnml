//! What every request cost, written down where a person can read it.
//!
//! A pane that is slow gives the user one word — `loading…` — and no
//! way to tell a throttled bucket from a wedged socket from a tab that
//! simply asks for forty things. So every request an integration makes
//! appends one JSON line here:
//!
//! ```
//! {"ts":1789526218.41,"service":"jira","integration":"mnml-jira",
//!  "method":"GET","host":"acme.atlassian.net","path":"/rest/api/3/search/jql",
//!  "status":200,"ms":412,"bytes":18244,"reason":"pane_open",
//!  "wait_ms":3030,"tokens_after":0.14,"retry_of":0,"cache":"miss"}
//! ```
//!
//! `<data root>/requests/<service>.jsonl`, one file per service so two
//! integrations on one API share a file and read as one story — which
//! is the point, since they share the bucket too. It rotates at
//! `max_bytes` and keeps one older generation (`<service>.1.jsonl`):
//! the log is a diagnosis aid, not an archive.
//!
//! **What is never written.** There is no free-form header field, by
//! construction: `Entry` names the fields it carries, and the only
//! header it takes is `RateLimit`, four numbers a server sends about
//! the budget. No request or response body is ever written. The query
//! IS kept — `?jql=…` is most of what makes a Jira line worth reading —
//! so `redactQuery` strips the value of any parameter whose NAME reads
//! like a credential (`token`, `access_token`, `api_key`, `password`,
//! `secret`, `sig`, `signature`, `auth`) and leaves `name=***` behind,
//! so a line still says the parameter was sent.
//!
//! **A log is never a reason a request fails.** Every file operation
//! here is best effort: a log that cannot be written costs a line, not
//! a fetch.
//!
//! **Whether it is on** is the host's to say. mnml's own
//! `integrations.request_log` block reaches every integration it
//! starts as two environment variables — `MNML_REQUEST_LOG`
//! (`0` / `off` / `false` / `no` turns it off) and
//! `MNML_REQUEST_LOG_MAX_MB` — which is what `open` reads. An
//! integration run by hand with neither set gets the log: the point of
//! it is to be there when the slow morning happens, not to be switched
//! on afterwards.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ratelimit = @import("ratelimit.zig");

/// The default ceiling before a rotate, in bytes.
pub const default_max_bytes: u64 = 4 * 1024 * 1024;
/// Older generations kept beside the live file. One: `<service>.1.jsonl`.
pub const kept_generations: usize = 1;
/// What the host sets from `integrations.request_log`: `0` / `off` /
/// `false` / `no` turns the log off, anything else leaves it on.
pub const enabled_env = "MNML_REQUEST_LOG";
/// The ceiling before a rotate, in megabytes.
pub const max_mb_env = "MNML_REQUEST_LOG_MAX_MB";

/// Why a request was made. Every call site passes one; a line without
/// a reason cannot be read back to a cause, which is the whole point.
pub const Reason = enum {
    /// The first load of a tab, when a pane opens.
    pane_open,
    /// A refetch the user or the interval asked for.
    refresh,
    /// The statusline poller's `--values` run.
    poll,
    /// Filling a cache ahead of a pane that is not open yet.
    prefetch,
    /// One row's detail, fetched because the reader is on it.
    detail,
    /// The runs on a pull request's commit.
    builds,
    /// May this pull request merge?
    readiness,
    /// A command the host dispatched.
    dispatch,
    /// The user asked for this one outright — a transition, a comment,
    /// an approval.
    user,
    /// The warmer filling a cache for a tab nobody is looking at, paced
    /// so it never races an interactive request for the same bucket.
    warm,
    /// A window since the last successful sync — `updated >= -15m`
    /// rather than the whole listing.
    delta,
    /// A conditional GET: the body is already held, and the server is
    /// only being asked whether it still stands (`If-None-Match`).
    revalidate,
    /// **Not a request.** A local cache answered, and the line is
    /// written anyway so the log reads as the whole story rather than
    /// only the part that cost something. A `cache_hit` line never
    /// took a token.
    cache_hit,

    pub fn tag(r: Reason) []const u8 {
        return @tagName(r);
    }

    /// Whether a reason is a person waiting on an answer. An
    /// interactive request outranks warm and delta work for the next
    /// slot in the pacer — that ordering is `warm.priorityOf`, and
    /// this is the half of it the log owns.
    pub fn interactive(r: Reason) bool {
        return switch (r) {
            .pane_open, .detail, .user, .readiness, .dispatch, .refresh => true,
            .poll, .prefetch, .builds, .warm, .delta, .revalidate, .cache_hit => false,
        };
    }
};

/// Whether a local cache answered instead of the network. `none` is
/// "this call has no cache", which is not the same as a miss.
pub const Cache = enum { hit, miss, none };

/// The four headers a server sends about the budget, when it sends
/// them. Numbers only — this is the only header shape the log takes,
/// so a credential has no field to arrive in.
pub const RateLimit = struct {
    /// `X-RateLimit-Limit`.
    limit: ?i64 = null,
    /// `X-RateLimit-Remaining`.
    remaining: ?i64 = null,
    /// `X-RateLimit-Reset`, as the server sent it (epoch seconds).
    reset: ?i64 = null,
    /// `Retry-After`, in seconds.
    retry_after: ?i64 = null,
    /// `X-RateLimit-NearLimit: true` — both Atlassian clouds send it
    /// when less than a fifth of the budget is left, sometimes without
    /// the numbers.
    near_limit: ?bool = null,

    pub fn any(r: RateLimit) bool {
        return r.limit != null or r.remaining != null or r.reset != null or r.retry_after != null or r.near_limit != null;
    }
};

/// One request, as it is written down.
pub const Entry = struct {
    /// Wall clock, seconds since the epoch, with milliseconds.
    ts: f64 = 0,
    /// The bucket this spent from: `jira`, `bitbucket`.
    service: []const u8,
    /// Which binary made it — so two integrations on one service are
    /// still told apart.
    integration: []const u8,
    method: []const u8,
    /// Host only, no scheme and no credentials.
    host: []const u8,
    /// Path with its query, the query redacted.
    path: []const u8,
    /// Null when the request never reached a status — DNS, TLS, a
    /// reset connection.
    status: ?u16 = null,
    /// Wall time for the request itself, the limiter's wait excluded.
    ms: u64 = 0,
    /// Response body size.
    bytes: usize = 0,
    reason: Reason,
    /// How long `acquire` held this request before it went out.
    wait_ms: u64 = 0,
    /// Tokens left in the shared bucket after this request took one.
    tokens_after: f64 = 0,
    /// 0 for a first attempt, else which retry this is.
    retry_of: u32 = 0,
    cache: Cache = .none,
    rate_limit: RateLimit = .{},
    /// Why the limiter made this request wait, when it did.
    waited_for: Waited = .nothing,
    /// Which side of the machine handed the token over — the local
    /// broker's queue, or the shared state file. Reason-agnostic on
    /// purpose: every line carries it, so "was the broker up" is a
    /// question the log answers for a `poll` exactly as it does for a
    /// `pane_open`. A line that took no token (`cache_hit`) still says
    /// `file`, which is what a bucket nobody asked looks like.
    via: Via = .file,
    /// A dry run: the request was NOT sent. The line is what it would
    /// have been — method, route, reason — with no status, so counting
    /// requests by counting lines with a status still counts requests.
    dry: bool = false,
};

/// Where a token came from. The limiter's own enum, so the broker, the
/// bucket and this file all spell it one way.
pub const Via = ratelimit.Via;

/// What `acquire` was waiting on. The limiter's own enum — one name
/// for the thing, whether it is being decided, shown in the pane or
/// written down here.
pub const Waited = ratelimit.Wait;

/// Where the log lives and whether it is on. Cheap to hold: an
/// integration makes one at startup and hands `&log` to its client.
pub const Log = struct {
    gpa: Allocator,
    io: Io,
    /// `<data root>/requests`. Owned. Empty when the log is off.
    dir: []u8 = &.{},
    /// Owned.
    service: []u8 = &.{},
    /// Owned.
    integration: []u8 = &.{},
    enabled: bool = true,
    max_bytes: u64 = default_max_bytes,
    /// Lines actually written — what a test counts.
    written: u32 = 0,

    /// The log for a service, under the data root the environment
    /// resolves to. Never fails for want of a directory: the directory
    /// is made when the first line is written.
    pub fn open(
        gpa: Allocator,
        io: Io,
        env: *const std.process.Environ.Map,
        service: []const u8,
        integration: []const u8,
    ) Allocator.Error!Log {
        const root = try dataRoot(gpa, env);
        defer gpa.free(root);
        const dir = try std.fs.path.join(gpa, &.{ root, "requests" });
        errdefer gpa.free(dir);
        const svc = try gpa.dupe(u8, service);
        errdefer gpa.free(svc);
        return .{
            .gpa = gpa,
            .io = io,
            .dir = dir,
            .service = svc,
            .integration = try gpa.dupe(u8, integration),
            .enabled = enabledIn(env),
            .max_bytes = maxBytesIn(env),
        };
    }

    /// A log at an explicit directory — what a test uses, so nothing
    /// ever writes into the user's real data root.
    pub fn openAt(gpa: Allocator, io: Io, dir: []const u8, service: []const u8, integration: []const u8) Allocator.Error!Log {
        const d = try gpa.dupe(u8, dir);
        errdefer gpa.free(d);
        const svc = try gpa.dupe(u8, service);
        errdefer gpa.free(svc);
        return .{
            .gpa = gpa,
            .io = io,
            .dir = d,
            .service = svc,
            .integration = try gpa.dupe(u8, integration),
        };
    }

    pub fn deinit(self: *Log) void {
        self.gpa.free(self.dir);
        self.gpa.free(self.service);
        self.gpa.free(self.integration);
        self.* = undefined;
    }

    /// `<dir>/<service>.jsonl`. Owned by the caller.
    pub fn path(self: *const Log, gpa: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}.jsonl", .{ self.dir, self.service });
    }

    /// One line. Best effort throughout: a log that cannot be written
    /// costs a line, never a request.
    pub fn append(self: *Log, entry: Entry) void {
        if (!self.enabled) return;
        var e = entry;
        if (e.service.len == 0) e.service = self.service;
        if (e.integration.len == 0) e.integration = self.integration;
        if (e.ts == 0) e.ts = nowSecs(self.io);

        var buf: [4096]u8 = undefined;
        var fixed: Io.Writer = .fixed(&buf);
        writeLine(&fixed, e) catch return;
        const line = fixed.buffered();

        Io.Dir.cwd().createDirPath(self.io, self.dir) catch {};
        const p = self.path(self.gpa) catch return;
        defer self.gpa.free(p);
        const file = Io.Dir.cwd().createFile(self.io, p, .{ .truncate = false, .lock = .exclusive }) catch return;
        var end = file.length(self.io) catch 0;
        if (end + line.len > self.max_bytes) {
            file.close(self.io);
            self.rotate(p);
            const fresh = Io.Dir.cwd().createFile(self.io, p, .{ .truncate = false, .lock = .exclusive }) catch return;
            defer fresh.close(self.io);
            end = fresh.length(self.io) catch 0;
            fresh.writePositionalAll(self.io, line, end) catch return;
            self.written += 1;
            return;
        }
        defer file.close(self.io);
        file.writePositionalAll(self.io, line, end) catch return;
        self.written += 1;
    }

    /// A local cache answered instead of the network. The line is
    /// written so the log reads as the whole story rather than only
    /// the part that cost something — but nothing here implies a
    /// token: `status` stays null, `wait_ms` and `tokens_after` stay
    /// zero, and the reason is `cache_hit`. That is what lets a reader
    /// count requests by counting lines with a status.
    pub fn noteCacheHit(self: *Log, method: []const u8, host: []const u8, url_path: []const u8, bytes: usize) void {
        self.append(.{
            .service = "",
            .integration = "",
            .method = method,
            .host = host,
            .path = url_path,
            .status = null,
            .bytes = bytes,
            .reason = .cache_hit,
            .cache = .hit,
        });
    }

    /// `<service>.jsonl` → `<service>.1.jsonl`, the old `.1` dropped.
    /// One generation is kept: this is a diagnosis aid, not an archive.
    fn rotate(self: *Log, live: []const u8) void {
        const older = std.fmt.allocPrint(self.gpa, "{s}/{s}.1.jsonl", .{ self.dir, self.service }) catch return;
        defer self.gpa.free(older);
        Io.Dir.cwd().deleteFile(self.io, older) catch {};
        Io.Dir.cwd().rename(live, Io.Dir.cwd(), older, self.io) catch {
            // A rename that cannot happen must not mean the log grows
            // without bound: truncate instead.
            Io.Dir.cwd().writeFile(self.io, .{ .sub_path = live, .data = "" }) catch {};
        };
    }
};

/// One entry as its JSON line, newline included.
pub fn writeLine(w: *Io.Writer, e: Entry) Io.Writer.Error!void {
    try w.print("{{\"ts\":{d:.3},\"service\":\"{f}\",\"integration\":\"{f}\",\"method\":\"{f}\",\"host\":\"{f}\",\"path\":\"{f}\",\"status\":", .{
        e.ts,
        std.zig.fmtString(e.service),
        std.zig.fmtString(e.integration),
        std.zig.fmtString(e.method),
        std.zig.fmtString(e.host),
        std.zig.fmtString(e.path),
    });
    if (e.status) |s| try w.print("{d}", .{s}) else try w.writeAll("null");
    try w.print(",\"ms\":{d},\"bytes\":{d},\"reason\":\"{s}\",\"wait_ms\":{d},\"waited_for\":\"{s}\",\"tokens_after\":{d:.3},\"retry_of\":{d},\"cache\":\"{s}\",\"via\":\"{s}\"", .{
        e.ms,           e.bytes,    e.reason.tag(),    e.wait_ms,   e.waited_for.tag(),
        e.tokens_after, e.retry_of, @tagName(e.cache), e.via.tag(),
    });
    // The path with its ids elided — `/repositories/{…}/pullrequests/{n}`
    // — so lines about the same endpoint read (and group) as one, and a
    // line quoted in a bug report carries no ticket key or PR number.
    var route_buf: [512]u8 = undefined;
    try w.print(",\"route\":\"{f}\"", .{std.zig.fmtString(elideIds(&route_buf, e.path))});
    if (e.dry) try w.writeAll(",\"dry\":true");
    if (e.rate_limit.any()) {
        try w.writeAll(",\"rate_limit\":{");
        var first = true;
        inline for (.{ "limit", "remaining", "reset", "retry_after" }) |name| {
            if (@field(e.rate_limit, name)) |v| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.print("\"{s}\":{d}", .{ name, v });
            }
        }
        if (e.rate_limit.near_limit) |near| {
            if (!first) try w.writeByte(',');
            try w.print("\"near_limit\":{}", .{near});
        }
        try w.writeAll("}");
    }
    try w.writeAll("}\n");
}

/// Split a URL into its host and its `path?query`, the query redacted.
/// Anything before `@` in the authority is dropped outright: a URL
/// carrying `user:password@` must never reach the file.
pub fn splitUrl(arena: Allocator, url: []const u8) Allocator.Error!struct { host: []const u8, path: []const u8 } {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    const cut = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..cut];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    const tail = rest[cut..];
    const hash = std.mem.indexOfScalar(u8, tail, '#') orelse tail.len;
    return .{ .host = authority, .path = try redactQuery(arena, tail[0..hash]) };
}

/// Parameter names whose VALUE is a credential. Matched
/// case-insensitively against the whole name, so `jql` and `sig` are
/// told apart rather than `sig` matching inside `assignee`.
const credential_params = [_][]const u8{
    "token",         "access_token",  "accesstoken", "refresh_token", "api_key",
    "apikey",        "key",           "password",    "passwd",        "pwd",
    "secret",        "client_secret", "sig",         "signature",     "auth",
    "authorization", "session",       "sessionid",   "jwt",           "bearer",
};

/// `?a=1&token=abc` → `?a=1&token=***`. The parameter stays, so a line
/// still says it was sent; only the value goes.
pub fn redactQuery(arena: Allocator, path_and_query: []const u8) Allocator.Error![]const u8 {
    const q = std.mem.indexOfScalar(u8, path_and_query, '?') orelse return path_and_query;
    const query = path_and_query[q + 1 ..];
    if (query.len == 0) return path_and_query;
    var any = false;
    var probe = std.mem.splitScalar(u8, query, '&');
    while (probe.next()) |pair| {
        if (isCredentialParam(pair)) any = true;
    }
    if (!any) return path_and_query;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, path_and_query[0 .. q + 1]);
    var it = std.mem.splitScalar(u8, query, '&');
    var first = true;
    while (it.next()) |pair| {
        if (!first) try out.append(arena, '&');
        first = false;
        if (isCredentialParam(pair)) {
            const eq = std.mem.indexOfScalar(u8, pair, '=').?;
            try out.appendSlice(arena, pair[0 .. eq + 1]);
            try out.appendSlice(arena, "***");
        } else try out.appendSlice(arena, pair);
    }
    return out.toOwnedSlice(arena);
}

fn isCredentialParam(pair: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return false;
    const name = pair[0..eq];
    for (credential_params) |c| if (std.ascii.eqlIgnoreCase(name, c)) return true;
    return false;
}

/// `X-RateLimit-…` / `Retry-After` off a response, by name. Anything
/// else is ignored: this is an allow-list, not a filter.
///
/// Both clouds are read with the one function. Bitbucket sends
/// `X-RateLimit-Limit` / `-Remaining` / `-NearLimit`; Jira Cloud sends
/// the same three and a `X-RateLimit-Reset` that is an ISO 8601 stamp
/// (`2026-09-25T14:10:00Z`) where other services send epoch seconds —
/// both land in `reset` as epoch seconds.
pub fn rateLimitHeader(r: *RateLimit, name: []const u8, value: []const u8) void {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-nearlimit")) {
        if (std.ascii.eqlIgnoreCase(v, "true")) r.near_limit = true;
        if (std.ascii.eqlIgnoreCase(v, "false")) r.near_limit = false;
        return;
    }
    if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset")) {
        r.reset = std.fmt.parseInt(i64, v, 10) catch (isoSeconds(v) orelse return);
        return;
    }
    const n = std.fmt.parseInt(i64, v, 10) catch return;
    if (std.ascii.eqlIgnoreCase(name, "retry-after")) r.retry_after = n;
    if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-limit")) r.limit = n;
    if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-remaining")) r.remaining = n;
}

/// `YYYY-MM-DDTHH:MM:SS[.fff][Z]` as epoch seconds, UTC. An offset
/// other than `Z` is not honoured (Jira sends `Z`); null for anything
/// that is not the shape.
pub fn isoSeconds(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant).
pub fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @intCast((m + 9) % 12);
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// The path half of a request line with the parts that name ONE thing
/// replaced by what kind of thing they are, and the query dropped:
///
///   /2.0/repositories/acme/api/pullrequests/1198/comments
///     → /2.0/repositories/acme/api/pullrequests/{n}/comments
///   /rest/api/3/issue/ENG-12/transitions → /rest/api/3/issue/{key}/transitions
///
/// A number is `{n}`, a tracker key (`ABC-12`) `{key}`, a brace or
/// `%7B` uuid `{uuid}`, a hex run of seven or more with a digit in it
/// (a commit) `{sha}`. Names — a workspace, a repo — stay: they are
/// what tells two endpoints apart. Written into `buf`; clipped there.
pub fn elideIds(buf: []u8, path_and_query: []const u8) []const u8 {
    const q = std.mem.indexOfAny(u8, path_and_query, "?#") orelse path_and_query.len;
    const path = path_and_query[0..q];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    var first = true;
    var prev: []const u8 = "";
    while (it.next()) |seg| {
        defer prev = seg;
        if (!first) {
            if (n >= buf.len) break;
            buf[n] = '/';
            n += 1;
        }
        first = false;
        // `/rest/api/3` is a version, not an id.
        const version = std.ascii.eqlIgnoreCase(prev, "api") or std.ascii.eqlIgnoreCase(prev, "agile");
        const out = if (version) seg else segmentKind(seg) orelse seg;
        const take = @min(out.len, buf.len - n);
        @memcpy(buf[n .. n + take], out[0..take]);
        n += take;
    }
    return buf[0..n];
}

fn segmentKind(seg: []const u8) ?[]const u8 {
    if (seg.len == 0) return null;
    if (allOf(seg, std.ascii.isDigit)) return "{n}";
    if (seg[0] == '{' or std.ascii.startsWithIgnoreCase(seg, "%7B")) return "{uuid}";
    if (isTrackerKey(seg)) return "{key}";
    if (seg.len >= 7 and allOf(seg, std.ascii.isHex) and !allOf(seg, std.ascii.isAlphabetic)) return "{sha}";
    return null;
}

fn allOf(s: []const u8, comptime pred: fn (u8) bool) bool {
    for (s) |c| if (!pred(c)) return false;
    return true;
}

/// `ABC-12`: an upper-case project key, a dash, a number.
fn isTrackerKey(seg: []const u8) bool {
    const dash = std.mem.lastIndexOfScalar(u8, seg, '-') orelse return false;
    if (dash == 0 or dash + 1 >= seg.len) return false;
    if (!std.ascii.isUpper(seg[0])) return false;
    for (seg[0..dash]) |c| if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return allOf(seg[dash + 1 ..], std.ascii.isDigit);
}

/// The SDK's own read of mnml's data-root ladder. The host always sets
/// `MNML_DATA_ROOT` for a child it starts, so in practice this is the
/// first branch; the rest is for an integration run by hand.
pub fn dataRoot(gpa: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    if (nonEmpty(env.get("MNML_DATA_ROOT"))) |root| return gpa.dupe(u8, root);
    if (nonEmpty(env.get("XDG_CONFIG_HOME"))) |xdg| return std.fs.path.join(gpa, &.{ xdg, "mnml" });
    if (nonEmpty(env.get("HOME") orelse env.get("USERPROFILE"))) |home| return std.fs.path.join(gpa, &.{ home, ".config", "mnml" });
    return gpa.dupe(u8, "mnml");
}

/// `MNML_REQUEST_LOG`: off only when the host says so outright.
pub fn enabledIn(env: *const std.process.Environ.Map) bool {
    const v = nonEmpty(env.get(enabled_env)) orelse return true;
    for ([_][]const u8{ "0", "off", "false", "no" }) |no| {
        if (std.ascii.eqlIgnoreCase(v, no)) return false;
    }
    return true;
}

/// `MNML_REQUEST_LOG_MAX_MB`, as bytes. A nonsense value keeps the
/// default rather than turning the ceiling off.
pub fn maxBytesIn(env: *const std.process.Environ.Map) u64 {
    const v = nonEmpty(env.get(max_mb_env)) orelse return default_max_bytes;
    const mb = std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t"), 10) catch return default_max_bytes;
    if (mb == 0) return default_max_bytes;
    return @as(u64, mb) * 1024 * 1024;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

fn nowSecs(io: Io) f64 {
    const ns: f64 = @floatFromInt(Io.Timestamp.now(io, .real).toNanoseconds());
    return ns / 1_000_000_000.0;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "one request, one line — and the line carries every field the pane needs to explain itself" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var log = try Log.openAt(t.allocator, t.io, dir, "jira", "mnml-jira");
    defer log.deinit();

    log.append(.{
        .ts = 1789526218.411,
        .service = "",
        .integration = "",
        .method = "GET",
        .host = "acme.atlassian.net",
        .path = "/rest/api/3/search/jql",
        .status = 200,
        .ms = 412,
        .bytes = 18244,
        .reason = .pane_open,
        .wait_ms = 3030,
        .waited_for = .tokens,
        .tokens_after = 0.14,
        .cache = .miss,
        .via = .broker,
    });
    log.append(.{
        .service = "",
        .integration = "",
        .method = "GET",
        .host = "acme.atlassian.net",
        .path = "/rest/dev-status/latest/issue/detail?issueId=10002",
        .status = 429,
        .reason = .refresh,
        .retry_of = 1,
        .rate_limit = .{ .retry_after = 30 },
    });
    try t.expectEqual(@as(u32, 2), log.written);

    const p = try log.path(t.allocator);
    defer t.allocator.free(p);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, p, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    const first = lines.next().?;
    // The fields the REQUESTS view and the pane's own status read.
    for ([_][]const u8{
        "\"ts\":1789526218.411",    "\"service\":\"jira\"",            "\"integration\":\"mnml-jira\"",
        "\"method\":\"GET\"",       "\"host\":\"acme.atlassian.net\"", "\"path\":\"/rest/api/3/search/jql\"",
        "\"status\":200",           "\"ms\":412",                      "\"bytes\":18244",
        "\"reason\":\"pane_open\"", "\"wait_ms\":3030",                "\"waited_for\":\"tokens\"",
        "\"tokens_after\":0.140",   "\"retry_of\":0",                  "\"cache\":\"miss\"",
        "\"via\":\"broker\"",
    }) |needle| {
        t.expect(std.mem.indexOf(u8, first, needle) != null) catch |err| {
            std.debug.print("missing {s} in: {s}\n", .{ needle, first });
            return err;
        };
    }
    // The second line parses as JSON and carries the 429's own hint.
    const second = lines.next().?;
    try t.expect(lines.next() == null);
    try t.expect(std.mem.indexOf(u8, second, "\"status\":429") != null);
    try t.expect(std.mem.indexOf(u8, second, "\"retry_of\":1") != null);
    try t.expect(std.mem.indexOf(u8, second, "\"rate_limit\":{\"retry_after\":30}") != null);
    // Every line says which side handed the token over, whatever the
    // reason was — a line that never asked for one says `file`, which
    // is what a bucket nobody asked looks like.
    try t.expect(std.mem.indexOf(u8, second, "\"via\":\"file\"") != null);
    // Every line is valid JSON — the REQUESTS view parses them.
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, line, .{});
        parsed.deinit();
    }
    // A transport failure has no status; it is still a line.
    log.append(.{ .service = "", .integration = "", .method = "GET", .host = "h", .path = "/p", .status = null, .reason = .poll });
    const again = try Io.Dir.cwd().readFileAlloc(t.io, p, t.allocator, .limited(1 << 16));
    defer t.allocator.free(again);
    try t.expect(std.mem.indexOf(u8, again, "\"status\":null") != null);
}

test "a credential never reaches the file: not in the query, not in the authority, not from a header" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The parameter stays so the line still says it was sent; the
    // value goes.
    try t.expectEqualStrings(
        "/x?jql=project+%3D+ENG&token=***",
        try redactQuery(arena, "/x?jql=project+%3D+ENG&token=s3cr3t"),
    );
    for ([_][]const u8{ "access_token", "api_key", "apikey", "key", "password", "secret", "client_secret", "sig", "signature", "auth", "jwt", "session" }) |name| {
        const url = try std.fmt.allocPrint(arena, "/p?{s}=LEAKED", .{name});
        const out = try redactQuery(arena, url);
        t.expect(std.mem.indexOf(u8, out, "LEAKED") == null) catch |err| {
            std.debug.print("{s} survived redaction: {s}\n", .{ name, out });
            return err;
        };
    }
    // A name that merely CONTAINS one of them is not a credential.
    try t.expectEqualStrings("/p?keyword=checkout", try redactQuery(arena, "/p?keyword=checkout"));
    try t.expectEqualStrings("/p?assignee=sig", try redactQuery(arena, "/p?assignee=sig"));
    try t.expectEqualStrings("/p", try redactQuery(arena, "/p"));

    // A URL carrying `user:password@` loses the whole authority prefix.
    const split = try splitUrl(arena, "https://me:hunter2@acme.atlassian.net/rest/api/3/myself?token=abc");
    try t.expectEqualStrings("acme.atlassian.net", split.host);
    try t.expectEqualStrings("/rest/api/3/myself?token=***", split.path);
    try t.expect(std.mem.indexOf(u8, split.host, "hunter2") == null);

    // The only header shape the log takes is four numbers: an
    // `authorization` offered to it is simply not a field it has.
    var rl: RateLimit = .{};
    rateLimitHeader(&rl, "authorization", "Basic ZmFrZQ==");
    rateLimitHeader(&rl, "x-ratelimit-remaining", "17");
    rateLimitHeader(&rl, "retry-after", "30");
    try t.expectEqual(@as(?i64, 17), rl.remaining);
    try t.expectEqual(@as(?i64, 30), rl.retry_after);
    try t.expect(rl.limit == null);

    // And end to end: a request whose URL carried a token writes no
    // token, and no `authorization` word at all.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var log = try Log.openAt(t.allocator, t.io, dir, "bitbucket", "mnml-bitbucket");
    defer log.deinit();
    const s = try splitUrl(arena, "https://api.bitbucket.org/2.0/repositories/acme/api?access_token=ATCTT-REAL-TOKEN");
    log.append(.{ .service = "", .integration = "", .method = "GET", .host = s.host, .path = s.path, .status = 200, .reason = .refresh });
    const p = try log.path(t.allocator);
    defer t.allocator.free(p);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, p, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "ATCTT") == null);
    try t.expect(std.mem.indexOf(u8, text, "hunter2") == null);
    try t.expect(std.ascii.indexOfIgnoreCase(text, "authorization") == null);
    try t.expect(std.mem.indexOf(u8, text, "access_token=***") != null);
}

test "the file rotates at the ceiling and keeps one older generation" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var log = try Log.openAt(t.allocator, t.io, dir, "jira", "mnml-jira");
    defer log.deinit();
    const live = try log.path(t.allocator);
    defer t.allocator.free(live);
    const older = try std.fmt.allocPrint(t.allocator, "{s}/jira.1.jsonl", .{dir});
    defer t.allocator.free(older);

    // Five lines under a ceiling nothing can reach, to learn what a
    // line costs rather than guessing at it.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        log.append(.{ .service = "", .integration = "", .method = "GET", .host = "acme.atlassian.net", .path = "/rest/api/3/myself", .status = 200, .reason = .poll, .ms = i });
    }
    const five = try Io.Dir.cwd().readFileAlloc(t.io, live, t.allocator, .limited(1 << 16));
    defer t.allocator.free(five);
    try t.expectEqual(@as(usize, 5), std.mem.count(u8, five, "\n"));
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, older, .{}));

    // A ceiling the sixth line cannot fit under: exactly one rotate,
    // and the five already written become the older generation.
    log.max_bytes = five.len + 10;
    while (i < 10) : (i += 1) {
        log.append(.{ .service = "", .integration = "", .method = "GET", .host = "acme.atlassian.net", .path = "/rest/api/3/myself", .status = 200, .reason = .poll, .ms = i });
    }
    const live_text = try Io.Dir.cwd().readFileAlloc(t.io, live, t.allocator, .limited(1 << 16));
    defer t.allocator.free(live_text);
    const old_text = try Io.Dir.cwd().readFileAlloc(t.io, older, t.allocator, .limited(1 << 16));
    defer t.allocator.free(old_text);
    try t.expect(live_text.len <= log.max_bytes);
    try t.expectEqualStrings(five, old_text);
    try t.expectEqual(@as(u32, 10), log.written);
    try t.expectEqual(@as(usize, 10), std.mem.count(u8, live_text, "\n") + std.mem.count(u8, old_text, "\n"));
    // The newest line is in the LIVE file, and the oldest is not.
    try t.expect(std.mem.indexOf(u8, live_text, "\"ms\":9") != null);
    try t.expect(std.mem.indexOf(u8, live_text, "\"ms\":0,") == null);
    // Only one generation is kept: there is never a `.2.jsonl`.
    const second = try std.fmt.allocPrint(t.allocator, "{s}/jira.2.jsonl", .{dir});
    defer t.allocator.free(second);
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, second, .{}));
    // And a long run keeps rotating rather than growing: the pair is
    // still bounded after forty more lines.
    while (i < 50) : (i += 1) {
        log.append(.{ .service = "", .integration = "", .method = "GET", .host = "acme.atlassian.net", .path = "/rest/api/3/myself", .status = 200, .reason = .poll, .ms = i });
    }
    const late_live = try Io.Dir.cwd().readFileAlloc(t.io, live, t.allocator, .limited(1 << 16));
    defer t.allocator.free(late_live);
    const late_old = try Io.Dir.cwd().readFileAlloc(t.io, older, t.allocator, .limited(1 << 16));
    defer t.allocator.free(late_old);
    try t.expect(late_live.len + late_old.len <= 2 * log.max_bytes);
    try t.expect(std.mem.indexOf(u8, late_live, "\"ms\":49") != null);
}

test "off writes nothing at all" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var log = try Log.openAt(t.allocator, t.io, dir, "jira", "mnml-jira");
    defer log.deinit();
    log.enabled = false;
    log.append(.{ .service = "", .integration = "", .method = "GET", .host = "h", .path = "/p", .status = 200, .reason = .poll });
    try t.expectEqual(@as(u32, 0), log.written);
    const p = try log.path(t.allocator);
    defer t.allocator.free(p);
    try t.expectError(error.FileNotFound, Io.Dir.cwd().access(t.io, p, .{}));
}

test "the data root is the host's, and the file is one per service" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/ada");
    {
        const r = try dataRoot(t.allocator, &env);
        defer t.allocator.free(r);
        try t.expectEqualStrings("/home/ada/.config/mnml", r);
    }
    try env.put("XDG_CONFIG_HOME", "/xdg");
    {
        const r = try dataRoot(t.allocator, &env);
        defer t.allocator.free(r);
        try t.expectEqualStrings("/xdg/mnml", r);
    }
    // What the host sets for every child it starts wins over both.
    try env.put("MNML_DATA_ROOT", "/data");
    var log = try Log.open(t.allocator, t.io, &env, "bitbucket", "mnml-bitbucket");
    defer log.deinit();
    try t.expectEqualStrings("/data/requests", log.dir);
    const p = try log.path(t.allocator);
    defer t.allocator.free(p);
    try t.expectEqualStrings("/data/requests/bitbucket.jsonl", p);
    // Neither variable set is ON: the log has to be there when the
    // slow morning happens, not be switched on afterwards.
    try t.expect(log.enabled);
    try t.expectEqual(default_max_bytes, log.max_bytes);
}

test "the host's `integrations.request_log` reaches the SDK as two variables" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_DATA_ROOT", "/data");
    for ([_][]const u8{ "0", "off", "false", "no", "OFF", "False" }) |off| {
        try env.put(enabled_env, off);
        var log = try Log.open(t.allocator, t.io, &env, "jira", "mnml-jira");
        defer log.deinit();
        t.expect(!log.enabled) catch |err| {
            std.debug.print("{s} did not turn the log off\n", .{off});
            return err;
        };
    }
    for ([_][]const u8{ "1", "on", "true", "" }) |on| {
        try env.put(enabled_env, on);
        var log = try Log.open(t.allocator, t.io, &env, "jira", "mnml-jira");
        defer log.deinit();
        try t.expect(log.enabled);
    }
    try env.put(enabled_env, "1");
    try env.put(max_mb_env, "8");
    {
        var log = try Log.open(t.allocator, t.io, &env, "jira", "mnml-jira");
        defer log.deinit();
        try t.expectEqual(@as(u64, 8 * 1024 * 1024), log.max_bytes);
    }
    // Nonsense keeps the default rather than removing the ceiling.
    for ([_][]const u8{ "nonsense", "0", "-3" }) |bad| {
        try env.put(max_mb_env, bad);
        var log = try Log.open(t.allocator, t.io, &env, "jira", "mnml-jira");
        defer log.deinit();
        try t.expectEqual(default_max_bytes, log.max_bytes);
    }
}

test "a cache hit is a line too — with no status, no wait and no tokens, so counting requests still counts requests" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    var log = try Log.openAt(t.allocator, t.io, dir, "bitbucket", "mnml-bitbucket");
    defer log.deinit();

    log.noteCacheHit("GET", "api.bitbucket.org", "/2.0/repositories/acme/web/pullrequests/12", 4096);
    const p = try log.path(t.allocator);
    defer t.allocator.free(p);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, p, t.allocator, .limited(1 << 16));
    defer t.allocator.free(text);

    try t.expect(std.mem.indexOf(u8, text, "\"reason\":\"cache_hit\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"cache\":\"hit\"") != null);
    // The three that say "this did not cost anything". A reader counts
    // requests by counting lines with a status, so a cache hit must not
    // have one.
    try t.expect(std.mem.indexOf(u8, text, "\"status\":null") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"wait_ms\":0") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"tokens_after\":0.000") != null);
    // The service and the integration are still filled in from the log.
    try t.expect(std.mem.indexOf(u8, text, "\"service\":\"bitbucket\"") != null);
    try t.expectEqual(@as(u32, 1), log.written);
}

test "the reasons the warmer added, and which of them yield to a reader" {
    // Somebody is waiting on the answer.
    for ([_]Reason{ .pane_open, .refresh, .detail, .readiness, .dispatch, .user }) |r| {
        try t.expect(r.interactive());
    }
    // Nobody is.
    for ([_]Reason{ .poll, .prefetch, .builds, .warm, .delta, .revalidate, .cache_hit }) |r| {
        try t.expect(!r.interactive());
    }
    // The tags are what the REQUESTS pane groups on, so they are pinned.
    try t.expectEqualStrings("warm", Reason.warm.tag());
    try t.expectEqualStrings("delta", Reason.delta.tag());
    try t.expectEqualStrings("revalidate", Reason.revalidate.tag());
    try t.expectEqualStrings("cache_hit", Reason.cache_hit.tag());
}

test "a line names its route with the ids elided, so one endpoint reads as one and no key or number is quoted" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("/2.0/repositories/acme/api/pullrequests/{n}/comments", elideIds(&buf, "/2.0/repositories/acme/api/pullrequests/1198/comments?pagelen=50"));
    try t.expectEqualStrings("/rest/api/3/issue/{key}/transitions", elideIds(&buf, "/rest/api/3/issue/ENG-12/transitions"));
    try t.expectEqualStrings("/2.0/repositories/acme/api/commit/{sha}/statuses", elideIds(&buf, "/2.0/repositories/acme/api/commit/4f2a9c01be/statuses"));
    try t.expectEqualStrings("/2.0/workspaces/acme/pipelines/{uuid}", elideIds(&buf, "/2.0/workspaces/acme/pipelines/%7Babc-1%7D"));
    // A word made of hex letters is still a word.
    try t.expectEqualStrings("/rest/agile/1.0/board/{n}/backlog", elideIds(&buf, "/rest/agile/1.0/board/7/backlog"));
    try t.expectEqualStrings("/2.0/repositories/acme/deadbeef", elideIds(&buf, "/2.0/repositories/acme/deadbeef"));

    var out: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    try writeLine(&w, .{ .service = "jira", .integration = "mnml-jira", .method = "GET", .host = "h", .path = "/rest/api/3/issue/ENG-7?fields=summary", .reason = .detail, .dry = true, .rate_limit = .{ .near_limit = true } });
    const line = w.buffered();
    try t.expect(std.mem.indexOf(u8, line, "\"route\":\"/rest/api/3/issue/{key}\"") != null);
    try t.expect(std.mem.indexOf(u8, line, "\"dry\":true") != null);
    try t.expect(std.mem.indexOf(u8, line, "\"near_limit\":true") != null);
}

test "both clouds' budget headers read into one shape: Bitbucket's epoch reset, Jira's ISO reset, the near-limit flag" {
    var r: RateLimit = .{};
    rateLimitHeader(&r, "X-RateLimit-Limit", "1000");
    rateLimitHeader(&r, "x-ratelimit-remaining", " 812 ");
    rateLimitHeader(&r, "X-RateLimit-NearLimit", "true");
    rateLimitHeader(&r, "X-RateLimit-Reset", "2026-09-25T14:10:00.000Z");
    rateLimitHeader(&r, "Authorization", "Basic abc");
    try t.expectEqual(@as(?i64, 1000), r.limit);
    try t.expectEqual(@as(?i64, 812), r.remaining);
    try t.expectEqual(@as(?bool, true), r.near_limit);
    try t.expectEqual(@as(?i64, 1_790_345_400), r.reset);
    rateLimitHeader(&r, "X-RateLimit-Reset", "1790345999");
    try t.expectEqual(@as(?i64, 1_790_345_999), r.reset);
    rateLimitHeader(&r, "X-RateLimit-Reset", "soon");
    try t.expectEqual(@as(?i64, 1_790_345_999), r.reset);
    try t.expectEqual(@as(?i64, null), isoSeconds("2026-13-01T00:00:00Z"));
}
