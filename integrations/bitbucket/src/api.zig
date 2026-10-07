//! Bitbucket Cloud REST v2 — the reads the pane makes and its one
//! write, approve. Blocking: the fetches run on the pane's worker
//! thread, which is why every call is a plain function and not a
//! future.
//!
//! Two things are deliberate here:
//!
//! * **A failure is a value, not an error.** `send` answers `.failed`
//!   with the status, the server's message and a parsed `Retry-After`;
//!   only running out of memory is an `error`. A 404 on one archived
//!   repo has to be paintable in that repo's row, not fatal to the fan
//!   out, and a transport failure has to read the same way as an HTTP
//!   one.
//! * **The shared bucket is in front of every request** (`ratelimit.zig`),
//!   and a 429 is answered the SDK's way (`sdk.budget`), the Jira pane's
//!   too: the bucket is penalised so every process on the machine backs
//!   off, and the pane's budget pauses — for `Retry-After`, else an
//!   exponential backoff with jitter capped at `max_backoff_secs` — with
//!   the header chip saying `paused until hh:mm:ss`. A READ is asked
//!   again once the pause is up, up to `max_attempts` in all; a write
//!   never is, and nothing else is retried — a 401 will not become a 200
//!   by asking twice.
//! * **Dry run** (`budget.isDry`): nothing goes out. The line the
//!   request would have been is written to the request log, and a GET
//!   is answered with the body already held for it, if there is one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cfg = @import("config.zig");
const auth = @import("auth.zig");
const ratelimit = @import("ratelimit.zig");
const cache_mod = @import("cache.zig");
const sdk = @import("mnml_sdk");
const request_log = sdk.request_log;

pub const Reason = request_log.Reason;

pub const default_base_url = "https://api.bitbucket.org/2.0";
pub const user_agent = "mnml-bitbucket/0.2.1";

pub const Method = enum {
    GET,
    POST,
    DELETE,

    fn stdMethod(m: Method) std.http.Method {
        return switch (m) {
            .GET => .GET,
            .POST => .POST,
            .DELETE => .DELETE,
        };
    }
};

pub const Side = enum { read, write };

pub const Failure = struct {
    /// null for a transport failure — DNS, TLS, a reset connection.
    status: ?u16 = null,
    retry_after_secs: ?u32 = null,
    /// The server's message, or the transport error's name. Owned.
    message: []u8 = &.{},

    pub fn deinit(self: *Failure, gpa: Allocator) void {
        gpa.free(self.message);
        self.* = undefined;
    }

    pub fn isRateLimited(self: Failure) bool {
        return self.status == 429;
    }

    /// The reference's short row label: `429 · retry in 30s`, `auth
    /// failed`, `no such repo`, `HTTP 400 · <why>`, `network error`.
    pub fn shortLabel(self: Failure, buf: []u8) []const u8 {
        if (sdk.budget.isBucketRefusal(self.message)) return fit(buf, "waiting on the shared bucket");
        const status = self.status orelse return fit(buf, "network error");
        return switch (status) {
            429 => if (self.retry_after_secs) |s|
                (std.fmt.bufPrint(buf, "429 · retry in {d}s", .{s}) catch fit(buf, "429 · rate limited"))
            else
                fit(buf, "429 · rate limited"),
            401, 403 => fit(buf, "auth failed"),
            404 => fit(buf, "no such repo"),
            400 => if (self.message.len > 0)
                (std.fmt.bufPrint(buf, "HTTP 400 · {s}", .{self.message[0..@min(self.message.len, 80)]}) catch fit(buf, "HTTP 400"))
            else
                fit(buf, "HTTP 400"),
            else => std.fmt.bufPrint(buf, "HTTP {d}", .{status}) catch fit(buf, "HTTP error"),
        };
    }

    /// `HTTP 403: <message>` / `<message>` — the long form for a status line.
    pub fn describe(self: Failure, buf: []u8) []const u8 {
        if (self.status) |code| return std.fmt.bufPrint(buf, "HTTP {d}: {s}", .{ code, self.message }) catch fit(buf, "HTTP error");
        return fit(buf, self.message);
    }

    fn fit(buf: []u8, s: []const u8) []const u8 {
        const n = @min(buf.len, s.len);
        @memcpy(buf[0..n], s[0..n]);
        return buf[0..n];
    }
};

/// What one `once` learned about the budget from the response head.
/// Numbers only; no header value that could carry a credential is ever
/// read out of a response here.
pub const Head = struct {
    retry_after: ?u32 = null,
    rate_limit: request_log.RateLimit = .{},
    /// The response's `ETag`, duped onto the caller's allocator — the
    /// header buffer it came out of does not outlive the request.
    /// Empty when the endpoint sent none.
    etag: []const u8 = "",
    /// The server answered 304: it has nothing new, and the body we
    /// already hold still stands.
    not_modified: bool = false,
    /// The response's `Content-Type`, duped like `etag` — what the
    /// shared cache files beside the body. Empty when none came.
    content_type: []const u8 = "",
};

pub const Body = struct {
    status: u16,
    /// Owned by the allocator passed to `send`.
    bytes: []u8,

    pub fn deinit(self: *Body, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

pub const Reply = union(enum) {
    ok: Body,
    failed: Failure,

    pub fn deinit(self: *Reply, gpa: Allocator) void {
        switch (self.*) {
            .ok => |*b| b.deinit(gpa),
            .failed => |*f| f.deinit(gpa),
        }
    }
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    /// No trailing slash; `https://api.bitbucket.org/2.0` by default.
    base_url: []u8,
    read_header: []u8,
    write_header: []u8,
    /// What the read token is, so the caller can ask the right
    /// question of it: an access token has no `/2.0/user`.
    read_kind: auth.Kind = .account,
    rate: cfg.Rate,
    limiter: ?*ratelimit.Limiter = null,
    /// Where every request is written down (`mnml_sdk.request_log`).
    /// Null in a test, which has no data root to write into.
    log: ?*request_log.Log = null,
    /// Where a wait long enough for a person to notice is left for the
    /// paint loop to say something about.
    notice: ?*ratelimit.Notice = null,
    /// Why the requests being made right now are being made. The
    /// worker sets it when it picks up a job — a job IS a reason — so
    /// a line in the log reads back to the thing that caused it.
    reason: Reason = .refresh,
    /// The prefetch cache (`cache.zig`). In `.prime` it answers the
    /// first GET for each URL without a request; in `.fill` it records
    /// every one that succeeds. Null is the same as `.off`.
    cache: ?*cache_mod.Cache = null,
    /// The clock the cache ages entries against; the pane sets it.
    now_secs: i64 = 0,
    /// The shared HTTP response cache (`mnml_sdk.http_cache`), one file
    /// per GET that every process on the machine reads and writes.
    /// `decide` says, per GET: fresh (answered off the file, no
    /// request), revalidate (`If-None-Match` with the held tag; a 304
    /// hands the held body back — a token and no bytes), or miss. Null
    /// simply means every GET is unconditional.
    http_cache: ?sdk.http_cache.Dir = null,
    /// The pacer for this service — see `mnml_sdk.warm`.
    gate: ?*sdk.warm.Gate = null,
    /// Send `If-None-Match` where a tag is held. False is the full
    /// refresh: ask unconditionally, so a tag that has somehow gone
    /// wrong is always one keypress from being replaced.
    conditional: bool = true,
    /// Requests actually sent, retries included — the diagnostics and
    /// the rate-limit tests both read it.
    sent: u32 = 0,
    /// Where a listing refresh folds every GET's answer, to learn
    /// whether the listing moved (`sdk.feed`'s adaptive poller). Null
    /// outside one.
    digest: ?*std.hash.Wyhash = null,
    /// The pane's API budget (`mnml_sdk.budget`): the headers, the
    /// 429 pause, the hit ratio, the tally, dry run. Null — a one-shot
    /// command-line run — gets a budget of its own per request, so a
    /// 429 is answered the same way with nothing to show it on.
    budget: ?*sdk.Budget = null,

    pub fn init(
        gpa: Allocator,
        io: Io,
        base_url: []const u8,
        email: []const u8,
        read_token: []const u8,
        write_token: []const u8,
        rate: cfg.Rate,
    ) Allocator.Error!Client {
        const trimmed = std.mem.trimEnd(u8, if (base_url.len > 0) base_url else default_base_url, "/");
        const write = if (write_token.len > 0) write_token else read_token;
        return .{
            .gpa = gpa,
            .io = io,
            .base_url = try gpa.dupe(u8, trimmed),
            // The scheme comes off each token's own kind: an account
            // credential goes out Basic, an `ATCTT…` access token
            // Bearer. Either sent the other way is a 401 that says
            // nothing about whether the token is good.
            .read_header = try auth.authHeader(gpa, email, read_token),
            .write_header = try auth.authHeader(gpa, email, write),
            .read_kind = auth.kindOf(read_token),
            .rate = rate,
        };
    }

    pub fn deinit(self: *Client) void {
        self.gpa.free(self.base_url);
        self.gpa.free(self.read_header);
        self.gpa.free(self.write_header);
        self.* = undefined;
    }

    fn header(self: *const Client, side: Side) []const u8 {
        return switch (side) {
            .read => self.read_header,
            .write => self.write_header,
        };
    }

    /// One request, gated and retried. `path` starts with `/` and
    /// already carries its query. Every GET's answer — a body off the
    /// wire, a 304's held one, a cache's — is folded into `digest` when
    /// one is set, so a listing refresh can say whether anything moved.
    pub fn send(self: *Client, gpa: Allocator, method: Method, path: []const u8, payload: ?[]const u8, side: Side) Allocator.Error!Reply {
        return self.sendStamped(gpa, method, path, payload, side, "");
    }

    /// `send`, for a GET about one pull request whose `updated_on` the
    /// caller already holds from a listing: a held answer filed under
    /// the same stamp is the server's own word that nothing moved, and
    /// is used with no request at all.
    pub fn sendStamped(self: *Client, gpa: Allocator, method: Method, path: []const u8, payload: ?[]const u8, side: Side, stamp: []const u8) Allocator.Error!Reply {
        const reply = try self.sendUnhashed(gpa, method, path, payload, side, stamp);
        if (method == .GET) if (self.digest) |d| {
            d.update(path);
            switch (reply) {
                .ok => |b| d.update(b.bytes),
                .failed => |f| {
                    d.update("\x00failed");
                    d.update(f.message);
                },
            }
        };
        return reply;
    }

    fn sendUnhashed(self: *Client, gpa: Allocator, method: Method, path: []const u8, payload: ?[]const u8, side: Side, stamp: []const u8) Allocator.Error!Reply {
        const url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ self.base_url, path });
        defer gpa.free(url);
        // Everything the shared cache reads for this request lives here
        // and goes with it; a body handed back is duped onto `gpa`.
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const held: ?Held = if (method == .GET) self.heldFor(scratch.allocator(), url, stamp) else null;
        var own_budget: sdk.Budget = .{};
        const budget = self.budget orelse blk: {
            own_budget.configure(self.io, .{ .label = "Bitbucket", .service = ratelimit.service, .backoff = self.backoff() });
            break :blk &own_budget;
        };
        // A dry run sends nothing. The line says what would have gone
        // out; a GET is answered with what is already held for it.
        if (budget.isDry()) {
            self.note(gpa, method, url, null, 0, 0, .{ .ok = true }, 0, .none, .{}, null, .dry);
            if (held) |h| if (h.entry) |e| {
                budget.record(.{ .now_secs = self.nowSecs(), .on_wire = false, .cache = .hit });
                return .{ .ok = .{ .status = 200, .bytes = try gpa.dupe(u8, e.body) } };
            };
            return .{ .failed = .{ .status = null, .message = try gpa.dupe(u8, if (method == .GET) "dry run — nothing held for this yet" else "dry run — not sent") } };
        }
        // A prefetched GET is answered off the disk: no token spent, no
        // round trip, so the pane's first paint is the prefetch's.
        if (method == .GET and self.conditional) {
            if (self.cache) |c| {
                if (try c.take(gpa, url, self.now_secs)) |bytes| {
                    // A request that cost nothing is still worth a
                    // line: "the prefetch paid for this" is the answer
                    // to half the questions the log is read with.
                    self.note(gpa, method, url, null, bytes.len, 0, .{ .ok = true }, 0, .hit, .{}, .cache_hit, .off_wire);
                    budget.record(.{ .now_secs = self.nowSecs(), .on_wire = false, .cache = .hit });
                    return .{ .ok = .{ .status = 200, .bytes = bytes } };
                }
            }
        }
        // What the machine last heard about this URL. Fresh — inside
        // the writer's `valid_until`, or filed under the very stamp the
        // caller's listing carries — is answered off the file with no
        // request. Revalidate goes out conditional: a 304 is a round
        // trip that costs a token and no bytes, where the unconditional
        // form costs a token and the whole listing. `R` (conditional
        // off) asks outright either way.
        var if_none_match: []const u8 = "";
        if (self.conditional) if (held) |h| switch (h.verdict) {
            .fresh => {
                const e = h.entry.?;
                const bytes = try gpa.dupe(u8, e.body);
                self.note(gpa, method, url, null, bytes.len, 0, .{ .ok = true }, 0, .hit, .{}, .cache_hit, .off_wire);
                budget.record(.{ .now_secs = self.nowSecs(), .on_wire = false, .cache = .hit });
                return .{ .ok = .{ .status = 200, .bytes = bytes } };
            },
            .revalidate => if_none_match = h.entry.?.etag,
            .miss => {},
        };
        var attempt: u32 = 0;
        while (true) {
            attempt += 1;
            // A 429's pause, before anything else: a short one is
            // waited out here (the chip says until when, and a click
            // stops it); a long one sends nothing at all.
            switch (budget.waitOut()) {
                .go => {},
                .paused => return pausedFailure(gpa, budget),
                .cancelled => return .{ .failed = .{ .status = 429, .message = try gpa.dupe(u8, "stopped waiting out the rate limit") } },
                // The machine's shared bucket file is empty or cooling
                // down: this round is skipped, nothing goes out, and
                // the pane says it is waiting rather than failing.
                .bucket_empty, .bucket_cooldown => |g| return .{ .failed = .{ .status = null, .message = try gpa.dupe(u8, sdk.Budget.refusalText(g)) } },
            }
            // Spacing, before the bucket. A reader waits for nothing;
            // a warm sweep waits its turn (`mnml_sdk.warm.Gate`).
            if (self.gate) |g| {
                const prio = sdk.warm.priorityOf(self.reason);
                if (prio == .interactive) g.enter();
                const hold_ms = g.hold(prio, Io.Timestamp.now(self.io, .real).toMilliseconds());
                if (hold_ms > 0) self.io.sleep(.fromMilliseconds(@intCast(hold_ms)), .awake) catch {};
                if (prio == .interactive) g.leave();
            }
            // Through the local broker when mnml is hosting one, so a
            // pane queues ahead of the warmers and the batch scripts
            // on the machine — and straight off the shared file when
            // it is not, which is every run with no mnml open.
            const gate: ratelimit.Acquired = if (self.limiter) |l| blk: {
                l.reason = @tagName(self.reason);
                // The limiter writes the request's live phase — queued
                // behind N, waiting on the bucket, sending — where the
                // header reads it; `.idle` below is this side's to say.
                l.live = self.notice;
                break :blk l.acquireVia(sdk.warm.classOf(self.reason));
            } else .{ .ok = true };
            if (self.notice) |n| n.record(gate);
            self.sent += 1;
            const started = Io.Timestamp.now(self.io, .real);
            var head: Head = .{};
            var reply = try self.once(gpa, method, url, payload, side, if_none_match, &head);
            if (self.notice) |n| n.setPhase(.idle, 0);
            defer if (head.etag.len > 0) gpa.free(head.etag);
            defer if (head.content_type.len > 0) gpa.free(head.content_type);
            const ms: u64 = @intCast(@max(Io.Timestamp.now(self.io, .real).toMilliseconds() - started.toMilliseconds(), 0));
            // Nothing new. The body already held still stands, so it
            // is handed back as if it had been sent — and the line
            // says `revalidate` + `hit`, which is how the REQUESTS
            // pane tells a cheap round trip from a dear one.
            if (head.not_modified) {
                reply.deinit(gpa);
                if (held) |h| if (h.entry) |e| {
                    // The server's word that the held body still
                    // stands: the entry's clock moves to when this
                    // request left, so every process sees it confirmed.
                    _ = self.http_cache.?.confirm(scratch.allocator(), self.io, e, started.toSeconds());
                    const kept = try gpa.dupe(u8, e.body);
                    self.note(gpa, method, url, 304, kept.len, ms, gate, attempt - 1, .hit, head.rate_limit, .revalidate, .wire);
                    budget.record(.{ .now_secs = self.nowSecs(), .rate_limit = head.rate_limit, .cache = .hit });
                    return .{ .ok = .{ .status = 200, .bytes = kept } };
                };
                // A 304 with nothing held is a server being odd; the
                // next unconditional GET fixes it.
                self.note(gpa, method, url, 304, 0, ms, gate, attempt - 1, .miss, head.rate_limit, .revalidate, .wire);
                budget.record(.{ .now_secs = self.nowSecs(), .rate_limit = head.rate_limit, .cache = .miss });
                return .{ .ok = .{ .status = 200, .bytes = try gpa.dupe(u8, "{}") } };
            }
            switch (reply) {
                .ok => |body| {
                    self.note(gpa, method, url, body.status, body.bytes.len, ms, gate, attempt - 1, if (self.cache == null) .none else .miss, head.rate_limit, null, .wire);
                    // A read that carried its body back is a miss; a
                    // write is neither.
                    budget.record(.{ .now_secs = self.nowSecs(), .rate_limit = head.rate_limit, .cache = if (method == .GET) .miss else .none });
                    if (method == .GET) {
                        if (self.cache) |c| c.put(url, body.bytes, self.now_secs);
                        // Into the shared cache, dated when the request
                        // LEFT, so a change stamped while it was in
                        // flight still makes it stale. Only a 200 is.
                        if (held) |h| if (body.status == 200) {
                            const sa = scratch.allocator();
                            _ = self.http_cache.?.store(sa, self.io, .{
                                .url = h.url,
                                .body = body.bytes,
                                .etag = head.etag,
                                .key = h.key,
                                .stamp = stampOf(sa, h, body.bytes),
                                .content_type = head.content_type,
                                .now = started.toSeconds(),
                            });
                        };
                    } else if (self.http_cache) |d| {
                        // A write this process made: everything held
                        // about the pull request it touched is stale,
                        // for every process on the machine.
                        const sa = scratch.allocator();
                        if (sdk.http_cache.canonical(sa, url, &.{})) |canon| {
                            if (sdk.http_cache.itemKey(sa, canon)) |key| {
                                _ = d.markChanged(sa, self.io, key, sdk.http_cache.changedNow(self.io));
                            } else |_| {}
                        } else |_| {}
                    }
                    return reply;
                },
                .failed => |f| {
                    self.note(gpa, method, url, f.status, 0, ms, gate, attempt - 1, .none, head.rate_limit, null, .wire);
                    budget.record(.{ .now_secs = self.nowSecs(), .rate_limit = head.rate_limit });
                    if (!f.isRateLimited()) return reply;
                    // The SDK's one answer to a 429, the Jira pane's too:
                    // the pane's budget pauses for what the server asked
                    // (or the backoff), the shared bucket parks every
                    // process for as long, and a READ asks again once
                    // the pause is up — `waitOut` at the top of the loop
                    // is the wait. A write goes back to the pane.
                    const delay = budget.throttled(attempt, f.retry_after_secs);
                    // Bitbucket sends no useful `Retry-After`; without
                    // one the bucket parks for at least the preset's
                    // cooldown (30 s — what a 429 took to clear when it
                    // was measured), not the first, shorter backoff.
                    if (self.limiter) |l| {
                        const secs: f64 = @floatFromInt(delay);
                        l.penalize(if (f.retry_after_secs != null) secs else @max(secs, l.cfg.default_cooldown_secs));
                    }
                    if (!budget.backoff.retries(attempt, method == .GET)) return reply;
                    if (delay > budget.backoff.wait_in_request_secs) return reply;
                    reply.deinit(gpa);
                },
            }
        }
    }

    /// What the shared cache holds for one GET, and what to do about it.
    const Held = struct {
        /// The canonical URL — the entry's file name and its `url`.
        url: []const u8,
        /// The pull request or pipeline the URL is about, or empty.
        key: []const u8,
        entry: ?sdk.http_cache.Entry,
        verdict: sdk.http_cache.Verdict,
        /// The caller's stamp (the listing's `updated_on`), or empty.
        stamp: []const u8,
    };

    /// The cache's view of `url`: null when there is no cache or the
    /// URL is not one every credential gets the same answer to.
    fn heldFor(self: *Client, a: Allocator, url: []const u8, stamp: []const u8) ?Held {
        const d = self.http_cache orelse return null;
        const canon = sdk.http_cache.canonical(a, url, &.{}) catch return null;
        if (!shareable(canon)) return null;
        const key = sdk.http_cache.itemKey(a, canon) catch return null;
        const entry = d.load(a, self.io, canon);
        const now_s = @as(f64, @floatFromInt(Io.Timestamp.now(self.io, .real).toMilliseconds())) / 1000.0;
        return .{
            .url = canon,
            .key = key,
            .entry = entry,
            .verdict = sdk.http_cache.decide(entry, now_s, d.changedAt(a, self.io, key), stamp),
            .stamp = stamp,
        };
    }

    /// The `stamp` a 200 is filed under: the pull request's own
    /// `updated_on` when the body IS the pull request; else the
    /// listing's stamp the caller passed for something under it (its
    /// comments); else none, and the entry revalidates by its tag.
    fn stampOf(a: Allocator, h: Held, body: []const u8) []const u8 {
        if (h.key.len == 0 or std.mem.indexOfScalar(u8, h.key, '#') == null) return "";
        if (isPullRequestItself(h.url)) {
            const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return "";
            if (v != .object) return "";
            const u = v.object.get("updated_on") orelse return "";
            return if (u == .string) u.string else "";
        }
        return h.stamp;
    }

    /// One line in the request log. Best effort: a log is never a
    /// reason a request fails.
    fn note(
        self: *Client,
        gpa: Allocator,
        method: Method,
        url: []const u8,
        status: ?u16,
        bytes: usize,
        ms: u64,
        gate: ratelimit.Acquired,
        retry_of: u32,
        cache: request_log.Cache,
        rate_limit: request_log.RateLimit,
        /// Overrides the client's own reason: a conditional round trip
        /// is a `revalidate` and an answer off the disk is a
        /// `cache_hit`, whatever the job that asked for it was.
        as_reason: ?request_log.Reason,
        /// `.dry`: the line is what a dry run did NOT send.
        wire: enum { wire, off_wire, dry },
    ) void {
        const log = self.log orelse return;
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const split = request_log.splitUrl(scratch.allocator(), url) catch return;
        log.append(.{
            .service = "",
            .integration = "",
            .method = @tagName(method),
            .host = split.host,
            .path = split.path,
            .status = status,
            .ms = ms,
            .bytes = bytes,
            .reason = as_reason orelse self.reason,
            .wait_ms = gate.wait_ms,
            .waited_for = gate.waited_for,
            .tokens_after = gate.tokens_after,
            .via = gate.via,
            .retry_of = retry_of,
            .cache = cache,
            .rate_limit = rate_limit,
            .dry = wire == .dry,
        });
    }

    /// The pane's backoff, off the config's `rate` block.
    pub fn backoff(self: *const Client) sdk.budget.Backoff {
        return .{
            .max_attempts = self.rate.max_attempts,
            .base_secs = self.rate.default_backoff_secs,
            .cap_secs = self.rate.max_backoff_secs,
        };
    }

    fn nowSecs(self: *const Client) i64 {
        return Io.Timestamp.now(self.io, .real).toSeconds();
    }

    /// A request refused because a long pause is running: nothing went
    /// out, and the failure says until when.
    fn pausedFailure(gpa: Allocator, budget: *sdk.Budget) Allocator.Error!Reply {
        const snap = budget.snapshot(Io.Timestamp.now(budget.io, .real).toSeconds());
        var c: [8]u8 = undefined;
        const msg = try std.fmt.allocPrint(gpa, "rate limited — paused until {s}", .{sdk.budget.clockText(&c, snap.paused_until, snap.offset_secs)});
        return .{ .failed = .{ .status = 429, .message = msg } };
    }

    fn once(self: *Client, gpa: Allocator, method: Method, url: []const u8, payload: ?[]const u8, side: Side, if_none_match: []const u8, head: *Head) Allocator.Error!Reply {
        var client: std.http.Client = .{ .allocator = gpa, .io = self.io };
        defer client.deinit();
        const uri = std.Uri.parse(url) catch return transportFailure(gpa, "the base URL does not parse");

        var extra: [4]std.http.Header = undefined;
        var n_extra: usize = 2;
        extra[0] = .{ .name = "authorization", .value = self.header(side) };
        extra[1] = .{ .name = "accept", .value = "application/json" };
        if (payload != null) {
            extra[n_extra] = .{ .name = "content-type", .value = "application/json" };
            n_extra += 1;
        }
        if (if_none_match.len > 0) {
            extra[n_extra] = .{ .name = "if-none-match", .value = if_none_match };
            n_extra += 1;
        }

        var req = client.request(method.stdMethod(), uri, .{
            .headers = .{
                .user_agent = .{ .override = user_agent },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = extra[0..n_extra],
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) catch |err| return transportFailure(gpa, @errorName(err));
        defer req.deinit();

        if (payload) |p| {
            req.transfer_encoding = .{ .content_length = p.len };
            var body = req.sendBodyUnflushed(&.{}) catch |err| return transportFailure(gpa, @errorName(err));
            body.writer.writeAll(p) catch |err| return transportFailure(gpa, @errorName(err));
            body.end() catch |err| return transportFailure(gpa, @errorName(err));
            if (req.connection) |c| c.flush() catch |err| return transportFailure(gpa, @errorName(err));
        } else {
            req.sendBodiless() catch |err| return transportFailure(gpa, @errorName(err));
        }

        var response = req.receiveHead(&.{}) catch |err| return transportFailure(gpa, @errorName(err));
        const status: u16 = @intFromEnum(response.head.status);
        // `Retry-After` is read off the head before the body, so a
        // body-read failure can never swallow the hint.
        var retry_after: ?u32 = null;
        var hit = response.head.iterateHeaders();
        while (hit.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
                retry_after = sdk.ratelimit.parseRetryAfter(h.value);
            }
            // The tag, duped: `h.value` points into the header buffer,
            // which does not outlive this request.
            if (std.ascii.eqlIgnoreCase(h.name, "etag") and head.etag.len == 0) {
                head.etag = gpa.dupe(u8, std.mem.trim(u8, h.value, " \t")) catch "";
            }
            if (std.ascii.eqlIgnoreCase(h.name, "content-type") and head.content_type.len == 0) {
                head.content_type = gpa.dupe(u8, std.mem.trim(u8, h.value, " \t")) catch "";
            }
            // The budget headers, by name — an allow-list, so nothing
            // a response carries can reach the log by accident.
            request_log.rateLimitHeader(&head.rate_limit, h.name, h.value);
        }
        head.retry_after = retry_after;
        head.not_modified = status == 304;

        var transfer: [4096]u8 = undefined;
        var sink: Io.Writer.Allocating = .init(gpa);
        errdefer sink.deinit();
        // Read through the content-encoding the site chose: the std
        // client offers gzip, deflate and zstd, and a compressed body
        // handed to the JSON parser as-is reads as "not JSON".
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity, .compress => &.{},
            .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        };
        defer if (decompress_buffer.len > 0) gpa.free(decompress_buffer);
        var decompress: std.http.Decompress = undefined;
        const reader = if (response.head.content_encoding == .compress) response.reader(&transfer) else response.readerDecompressing(&transfer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(&sink.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => {
                // A truncated body still leaves a usable status.
            },
        };
        const bytes = sink.toOwnedSlice() catch return error.OutOfMemory;

        if (status >= 200 and status < 300) return .{ .ok = .{ .status = status, .bytes = bytes } };
        defer gpa.free(bytes);
        return .{ .failed = .{
            .status = status,
            .retry_after_secs = retry_after,
            .message = try gpa.dupe(u8, serverMessage(bytes)),
        } };
    }

    fn transportFailure(gpa: Allocator, message: []const u8) Allocator.Error!Reply {
        return .{ .failed = .{ .status = null, .message = try gpa.dupe(u8, message) } };
    }

    // ─── the endpoints ───────────────────────────────────────────────

    /// `GET /user` — the account the token belongs to. An access token
    /// belongs to no account and 401s here; ask `workspaceProbe`
    /// instead, which `read_kind` says when.
    pub fn whoami(self: *Client, gpa: Allocator) Allocator.Error!Reply {
        return self.send(gpa, .GET, "/user", null, .read);
    }

    /// `GET /workspaces/{slug}` — the cheapest thing an access token
    /// can answer, so `--check` still has something to prove the token
    /// works with.
    pub fn workspaceProbe(self: *Client, gpa: Allocator, workspace: []const u8) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/workspaces/{s}", .{workspace});
        defer gpa.free(path);
        return self.send(gpa, .GET, path, null, .read);
    }

    /// `GET /repositories/{ws}` — every repo with its `updated_on`,
    /// newest activity first (`pagelen=100`, up to five pages, or the
    /// first page whose last entry is older than `since_secs`).
    pub fn listReposWithActivity(self: *Client, gpa: Allocator, workspace: []const u8) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/repositories/{s}?role=member&pagelen=100&sort=-updated_on", .{workspace});
        defer gpa.free(path);
        return self.send(gpa, .GET, path, null, .read);
    }

    /// `GET …/pullrequests?state=&pagelen=[&q=]`.
    /// `GET …/pullrequests?state=OPEN&state=MERGED…` — one `state=` per
    /// entry of `states`, which is how Bitbucket takes more than one;
    /// none asks for the API's default (OPEN).
    pub fn listPrs(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, states: []const []const u8, bbql: []const u8, page_len: u32) Allocator.Error!Reply {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("/repositories/{s}/{s}/pullrequests?pagelen={d}", .{ workspace, repo, page_len }) catch return error.OutOfMemory;
        for (states) |state| if (state.len > 0) w.print("&state={s}", .{state}) catch return error.OutOfMemory;
        if (bbql.len > 0) {
            w.writeAll("&q=") catch return error.OutOfMemory;
            percentEncode(w, bbql) catch return error.OutOfMemory;
        }
        return self.send(gpa, .GET, out.written(), null, .read);
    }

    pub fn prDetail(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .GET, workspace, repo, id, "", null, .read);
    }

    /// `prDetail` with the `updated_on` the caller's listing carried: a
    /// held detail filed under the same stamp costs no request.
    pub fn prDetailAt(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64, updated_on: []const u8) Allocator.Error!Reply {
        return self.prPathStamped(gpa, workspace, repo, id, "", updated_on);
    }

    pub fn prComments(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .GET, workspace, repo, id, "/comments?pagelen=50", null, .read);
    }

    /// `prComments` with the listing's `updated_on` — a comment moves
    /// it, so held comments filed under the same stamp still stand.
    pub fn prCommentsAt(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64, updated_on: []const u8) Allocator.Error!Reply {
        return self.prPathStamped(gpa, workspace, repo, id, "/comments?pagelen=50", updated_on);
    }

    /// `GET …/diffstat` — the per-file summary. Its STATUS is what
    /// readiness reads: Bitbucket answers a pull request that no longer
    /// merges cleanly with a 555, so a 2xx here is "it still applies".
    pub fn prDiffstat(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .GET, workspace, repo, id, "/diffstat?pagelen=50", null, .read);
    }

    /// `POST …/approve` — the one write. `DELETE` withdraws it.
    pub fn approve(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .POST, workspace, repo, id, "/approve", "", .write);
    }

    pub fn unapprove(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .DELETE, workspace, repo, id, "/approve", null, .write);
    }

    /// `GET …/pipelines/?sort=-created_on` — newest first.
    pub fn listPipelines(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, page_len: u32) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/repositories/{s}/{s}/pipelines/?pagelen={d}&sort=-created_on", .{ workspace, repo, page_len });
        defer gpa.free(path);
        return self.send(gpa, .GET, path, null, .read);
    }

    /// `GET …/refs/branches?sort=-target.date` — most recently committed first.
    pub fn listBranches(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, page_len: u32) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/repositories/{s}/{s}/refs/branches?pagelen={d}&sort=-target.date", .{ workspace, repo, page_len });
        defer gpa.free(path);
        return self.send(gpa, .GET, path, null, .read);
    }

    fn prPath(self: *Client, gpa: Allocator, method: Method, workspace: []const u8, repo: []const u8, id: i64, tail: []const u8, payload: ?[]const u8, side: Side) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/repositories/{s}/{s}/pullrequests/{d}{s}", .{ workspace, repo, id, tail });
        defer gpa.free(path);
        return self.send(gpa, method, path, payload, side);
    }

    fn prPathStamped(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64, tail: []const u8, stamp: []const u8) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/repositories/{s}/{s}/pullrequests/{d}{s}", .{ workspace, repo, id, tail });
        defer gpa.free(path);
        return self.sendStamped(gpa, .GET, path, null, .read, stamp);
    }
};

/// Whether a canonical URL's answer is the same whichever credential
/// asks, and so may go in a cache every token on the machine shares:
/// repository content only (`/2.0/repositories/…`), never `/2.0/user`,
/// a workspace probe, or a listing filtered by the caller's own role.
pub fn shareable(canon: []const u8) bool {
    const after_scheme = (std.mem.indexOf(u8, canon, "://") orelse return false) + 3;
    const slash = std.mem.indexOfScalarPos(u8, canon, after_scheme, '/') orelse return false;
    const rest = canon[slash..];
    const q = std.mem.indexOfScalar(u8, rest, '?');
    const path = rest[0 .. q orelse rest.len];
    if (!std.mem.startsWith(u8, path, "/2.0/repositories/")) return false;
    const query = if (q) |i| rest[i + 1 ..] else "";
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| if (std.mem.startsWith(u8, pair, "role=")) return false;
    return true;
}

/// The URL is the pull request's own resource, not something under it.
fn isPullRequestItself(canon: []const u8) bool {
    const q = std.mem.indexOfScalar(u8, canon, '?') orelse canon.len;
    const path = std.mem.trimEnd(u8, canon[0..q], "/");
    const at = std.mem.lastIndexOf(u8, path, "/pullrequests/") orelse return false;
    const id = path[at + "/pullrequests/".len ..];
    if (id.len == 0) return false;
    for (id) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// `author.account_id = "{id}"` and friends, ready for `&q=`.
pub fn percentEncode(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

/// Bitbucket's error shape is `{"error":{"message":"…"}}`; anything
/// else comes back as its first line, cut short.
pub fn serverMessage(body: []const u8) []const u8 {
    if (std.mem.indexOf(u8, body, "\"message\"")) |at| {
        const rest = body[at + "\"message\"".len ..];
        const open = std.mem.indexOfScalar(u8, rest, '"') orelse return firstLine(body);
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse return firstLine(body);
        return rest[open + 1 .. close];
    }
    return firstLine(body);
}

fn firstLine(body: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, body, '\n') orelse body.len;
    return body[0..@min(end, 120)];
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const listener = @import("../tools/fake_bitbucket/listener.zig");
const server = @import("../tools/fake_bitbucket/server.zig");

test "a short label says what the user has to fix, not just a number" {
    var buf: [96]u8 = undefined;
    try t.expectEqualStrings("network error", (Failure{ .status = null, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("auth failed", (Failure{ .status = 401, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("auth failed", (Failure{ .status = 403, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("no such repo", (Failure{ .status = 404, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("429 · rate limited", (Failure{ .status = 429, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("429 · retry in 45s", (Failure{ .status = 429, .retry_after_secs = 45, .message = &.{} }).shortLabel(&buf));
    var why = [_]u8{ 'b', 'a', 'd', ' ', 'q' };
    try t.expectEqualStrings("HTTP 400 · bad q", (Failure{ .status = 400, .message = &why }).shortLabel(&buf));
    try t.expectEqualStrings("HTTP 500", (Failure{ .status = 500, .message = &.{} }).shortLabel(&buf));
}

test "the server's message is lifted out of Bitbucket's error envelope" {
    try t.expectEqualStrings("Resource not found", serverMessage("{\"type\":\"error\",\"error\":{\"message\":\"Resource not found\"}}"));
    try t.expectEqualStrings("plain text", serverMessage("plain text\nmore"));
}

test "percent-encoding keeps the unreserved set and escapes the rest" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try percentEncode(&w, "author.account_id = \"a-1\"");
    try t.expectEqualStrings("author.account_id%20%3D%20%22a-1%22", w.buffered());
}

test "against the fake server: whoami, the lists, approve and unapprove, a 404 as a value" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "", .{});
    defer client.deinit();

    var who = try client.whoami(t.allocator);
    defer who.deinit(t.allocator);
    try t.expect(who == .ok);
    try t.expect(std.mem.indexOf(u8, who.ok.bytes, "acct-max") != null);

    var prs = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "author.account_id = \"acct-max\"", 25);
    defer prs.deinit(t.allocator);
    try t.expect(prs == .ok);
    try t.expect(std.mem.indexOf(u8, prs.ok.bytes, "Fix the login redirect") != null);
    try t.expect(std.mem.indexOf(u8, prs.ok.bytes, "Bump the client timeout") == null);

    var pl = try client.listPipelines(t.allocator, "acme", "api", 100);
    defer pl.deinit(t.allocator);
    try t.expect(pl == .ok);
    try t.expect(std.mem.indexOf(u8, pl.ok.bytes, "\"build_number\":412") != null);
    var br = try client.listBranches(t.allocator, "acme", "web", 100);
    defer br.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, br.ok.bytes, "feature/empty-state") != null);

    var ok = try client.approve(t.allocator, "acme", "api", 1198);
    defer ok.deinit(t.allocator);
    try t.expect(ok == .ok);
    try t.expectEqual(server.State.Vote.approved, srv.snapshot().voteFor(1198));
    var gone = try client.unapprove(t.allocator, "acme", "api", 1198);
    defer gone.deinit(t.allocator);
    try t.expect(gone == .ok);
    try t.expectEqual(server.State.Vote.none, srv.snapshot().voteFor(1198));

    var missing = try client.listPrs(t.allocator, "acme", "ghost", &.{"OPEN"}, "", 25);
    defer missing.deinit(t.allocator);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("no such repo", missing.failed.shortLabel(&buf));
}

test "against a server that gzips: the client asks for identity, and a body compressed anyway reads the same" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "", .{});
    defer client.deinit();

    // Asked for `identity`, a server that honours Accept-Encoding sends
    // plain bytes.
    srv.gzipAnswers(.when_asked);
    var asked = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "author.account_id = \"acct-max\"", 25);
    defer asked.deinit(t.allocator);
    try t.expect(asked == .ok);
    try t.expectEqual(@as(u32, 0), srv.snapshot().gzipped);

    // A proxy that compresses whatever was asked: the body is read
    // through its Content-Encoding, not handed to the parser as gzip.
    srv.gzipAnswers(.always);
    var prs = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "author.account_id = \"acct-max\"", 25);
    defer prs.deinit(t.allocator);
    try t.expect(prs == .ok);
    try t.expect(std.mem.indexOf(u8, prs.ok.bytes, "Fix the login redirect") != null);
    try t.expect(std.mem.indexOf(u8, prs.ok.bytes, "Bump the client timeout") == null);
    try t.expectEqual(@as(u32, 1), srv.snapshot().gzipped);
}

test "against the fake server: an access token goes out as a Bearer and an account credential as Basic — the user's 401 reproduced" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);

    // The bug: an `ATCTT…` access token sent the account way. The
    // server answers exactly as Bitbucket did for the user — 401, with
    // nothing to say the token itself is fine.
    {
        var wrong = try Client.init(t.allocator, t.io, base, "me@x.com", "", "", .{});
        defer wrong.deinit();
        t.allocator.free(wrong.read_header);
        wrong.read_header = try auth.basicHeader(t.allocator, "me@x.com", "ATCTTaccess-token");
        var r = try wrong.whoami(t.allocator);
        defer r.deinit(t.allocator);
        try t.expect(r == .failed);
        try t.expectEqual(@as(u16, 401), r.failed.status.?);
        try t.expectEqual(server.Credential.basic_with_access_token, srv.snapshot().last_credential);
    }

    // The fix: the same token, scheme chosen off its own kind.
    {
        var client = try Client.init(t.allocator, t.io, base, "me@x.com", "ATCTTaccess-token", "", .{});
        defer client.deinit();
        try t.expectEqual(auth.Kind.access_token, client.read_kind);
        try t.expect(std.mem.startsWith(u8, client.read_header, "Bearer "));
        // `/2.0/user` still 401s — an access token has no account —
        // so the workspace is what it can be checked against.
        var who = try client.whoami(t.allocator);
        defer who.deinit(t.allocator);
        try t.expect(who == .failed);
        var ws = try client.workspaceProbe(t.allocator, "acme");
        defer ws.deinit(t.allocator);
        try t.expect(ws == .ok);
        try t.expect(std.mem.indexOf(u8, ws.ok.bytes, "\"slug\":\"acme\"") != null);
        try t.expectEqual(server.Credential.bearer_access_token, srv.snapshot().last_credential);
    }

    // And an account credential keeps going out Basic, to `/2.0/user`.
    {
        var client = try Client.init(t.allocator, t.io, base, "me@x.com", "ATATTaccount-token", "", .{});
        defer client.deinit();
        try t.expectEqual(auth.Kind.account, client.read_kind);
        try t.expect(std.mem.startsWith(u8, client.read_header, "Basic "));
        var who = try client.whoami(t.allocator);
        defer who.deinit(t.allocator);
        try t.expect(who == .ok);
        try t.expect(std.mem.indexOf(u8, who.ok.bytes, "acct-max") != null);
        try t.expectEqual(server.Credential.basic_account, srv.snapshot().last_credential);
    }
}

test "a 429 is retried after Retry-After and penalises the bucket; the last attempt's failure is returned" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const state_path = try std.fs.path.join(t.allocator, &.{ dir, "bucket.json" });
    defer t.allocator.free(state_path);
    var lim = try ratelimit.Limiter.init(t.allocator, t.io, state_path, .{ .max_block_secs = 0.1 });
    defer lim.deinit();
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "tok", "", .{ .max_attempts = 2, .max_backoff_secs = 1 });
    defer client.deinit();
    client.limiter = &lim;
    // Two 429s, then a 200: with two attempts the second answer is
    // still the 429, and the bucket has been penalised twice.
    srv.rateLimitNext(2);
    var r = try client.whoami(t.allocator);
    defer r.deinit(t.allocator);
    try t.expect(r == .failed);
    try t.expect(r.failed.isRateLimited());
    try t.expectEqual(@as(u32, 2), client.sent);
    try t.expectEqual(@as(u32, 2), lim.status().?.throttles);
}

test "a prefetched GET answers the first ask off the disk and the refresh goes out; a write is never cached" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const cfg_path = try std.fs.path.join(t.allocator, &.{ dir, "config.zon" });
    defer t.allocator.free(cfg_path);

    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);

    // `--prefetch`: the bodies land in the cache, and a write does not.
    var fill = try cache_mod.Cache.init(t.allocator, t.io, cfg_path, .fill);
    defer fill.deinit();
    var filler = try Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "", .{});
    defer filler.deinit();
    filler.cache = &fill;
    filler.now_secs = 1000;
    var warm = try filler.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer warm.deinit(t.allocator);
    try t.expect(warm == .ok);
    var voted = try filler.approve(t.allocator, "acme", "api", 1198);
    defer voted.deinit(t.allocator);
    try t.expectEqual(@as(u32, 1), fill.writes);
    try t.expectEqual(@as(u32, 2), filler.sent);

    // The pane: the same request is served without a round trip.
    var prime = try cache_mod.Cache.init(t.allocator, t.io, cfg_path, .prime);
    defer prime.deinit();
    var pane_client = try Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "", .{});
    defer pane_client.deinit();
    pane_client.cache = &prime;
    pane_client.now_secs = 1010;
    var first = try pane_client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer first.deinit(t.allocator);
    try t.expectEqual(@as(u32, 0), pane_client.sent);
    try t.expectEqualStrings(warm.ok.bytes, first.ok.bytes);
    // The refresh is live.
    var second = try pane_client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer second.deinit(t.allocator);
    try t.expectEqual(@as(u32, 1), pane_client.sent);
    // A URL the prefetch never saw is fetched as usual.
    var other = try pane_client.listPipelines(t.allocator, "acme", "api", 100);
    defer other.deinit(t.allocator);
    try t.expectEqual(@as(u32, 2), pane_client.sent);
}

test "a GET that already holds the server's tag goes out conditional, and a 304 costs a token and no bytes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const cache_root = try std.fs.path.join(t.allocator, &.{ dir, "http-cache" });
    defer t.allocator.free(cache_root);
    const log_dir = try std.fs.path.join(t.allocator, &.{ dir, "requests" });
    defer t.allocator.free(log_dir);

    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);

    var log = try sdk.RequestLog.openAt(t.allocator, t.io, log_dir, "bitbucket", "mnml-bitbucket");
    defer log.deinit();
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "", .{});
    defer client.deinit();
    client.http_cache = .{ .root = cache_root, .service = "bitbucket" };
    client.log = &log;

    // The first ask is unconditional: nothing is held, so the whole
    // listing comes back and is filed under the server's tag.
    var first = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer first.deinit(t.allocator);
    try t.expect(first == .ok);
    try t.expect(first.ok.bytes.len > 0);
    try t.expectEqual(@as(u32, 0), srv.snapshot().not_modified);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const listing = try sdk.http_cache.canonical(arena.allocator(), try std.fmt.allocPrint(arena.allocator(), "{s}/repositories/acme/api/pullrequests?pagelen=25&state=OPEN", .{base}), &.{});
    const held = client.http_cache.?.load(arena.allocator(), t.io, listing).?;
    try t.expect(held.etag.len > 0);
    // A listing is mnml's to ask about every time: `valid_until` 0.
    try t.expectEqual(@as(f64, 0), held.valid_until);
    try t.expectEqualStrings("", held.key);

    // The second ask carries `If-None-Match`. The server says there is
    // nothing new; the client hands back the body it already had, so
    // the caller cannot tell — which is the whole point.
    var second = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer second.deinit(t.allocator);
    try t.expect(second == .ok);
    try t.expectEqualStrings(first.ok.bytes, second.ok.bytes);
    try t.expectEqual(@as(u32, 1), srv.snapshot().not_modified);

    // `R` — `conditional = false` — asks outright, so a tag that has
    // somehow gone wrong is always one keypress from being replaced.
    client.conditional = false;
    var third = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer third.deinit(t.allocator);
    try t.expect(third == .ok);
    try t.expectEqual(@as(u32, 1), srv.snapshot().not_modified);

    // The cheap round trip is in the log under its own name, so the
    // REQUESTS pane can tell it from the dear one.
    const p = try log.path(t.allocator);
    defer t.allocator.free(p);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, p, t.allocator, .limited(1 << 20));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"reason\":\"revalidate\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"status\":304") != null);
}

test "the shared cache end to end: a 200 is stored, a 304 confirms, a stamp answers with no request, a write makes it ask again" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const cache_root = try std.fs.path.join(t.allocator, &.{ dir, "http-cache" });
    defer t.allocator.free(cache_root);
    const log_dir = try std.fs.path.join(t.allocator, &.{ dir, "requests" });
    defer t.allocator.free(log_dir);
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var log = try sdk.RequestLog.openAt(t.allocator, t.io, log_dir, "bitbucket", "mnml-bitbucket");
    defer log.deinit();
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "tok", "", .{});
    defer client.deinit();
    const shared: sdk.http_cache.Dir = .{ .root = cache_root, .service = "bitbucket" };
    client.http_cache = shared;
    client.log = &log;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pr_url = try sdk.http_cache.canonical(a, try std.fmt.allocPrint(a, "{s}/repositories/acme/api/pullrequests/1198", .{base}), &.{});

    // A miss: a plain GET, and the 200 goes in the cache with the tag,
    // the pull request's key, and its own `updated_on` as the stamp.
    var first = try client.prDetail(t.allocator, "acme", "api", 1198);
    defer first.deinit(t.allocator);
    try t.expect(first == .ok);
    try t.expectEqual(@as(u32, 1), client.sent);
    const held = shared.load(a, t.io, pr_url).?;
    try t.expectEqualStrings("acme/api#1198", held.key);
    try t.expect(held.etag.len > 0);
    try t.expect(held.stamp.len > 0);
    try t.expectEqual(@as(f64, 0), held.valid_until);
    try t.expectEqualStrings(first.ok.bytes, held.body);
    try t.expect(std.mem.indexOf(u8, held.content_type, "json") != null);

    // The listing's stamp matches the held one: the server's own word
    // that nothing moved. No request at all.
    var by_stamp = try client.prDetailAt(t.allocator, "acme", "api", 1198, held.stamp);
    defer by_stamp.deinit(t.allocator);
    try t.expectEqualStrings(first.ok.bytes, by_stamp.ok.bytes);
    try t.expectEqual(@as(u32, 1), client.sent);

    // No stamp: `valid_until` is 0, so it revalidates; the 304 hands
    // the held body back and moves `fetched_at` forward.
    const served_before = srv.snapshot().not_modified;
    var older = held;
    older.fetched_at = 1000;
    try t.expect(sdk.http_cache.confirm(a, t.io, cache_root, "bitbucket", older, 1000, 0));
    var again = try client.prDetail(t.allocator, "acme", "api", 1198);
    defer again.deinit(t.allocator);
    try t.expectEqualStrings(first.ok.bytes, again.ok.bytes);
    try t.expectEqual(@as(u32, 2), client.sent);
    try t.expectEqual(served_before + 1, srv.snapshot().not_modified);
    const confirmed = shared.load(a, t.io, pr_url).?;
    try t.expect(confirmed.fetched_at > 1000);
    try t.expectEqualStrings(held.etag, confirmed.etag);
    try t.expectEqualStrings(held.stamp, confirmed.stamp);

    // A write this process made — an approval — stamps the pull request
    // changed. The listing's `updated_on` has not moved, but the change
    // is after the fetch: it asks again, conditionally, and the body
    // that comes back (the approval in it) replaces the held one.
    var approved = try client.approve(t.allocator, "acme", "api", 1198);
    defer approved.deinit(t.allocator);
    try t.expect(approved == .ok);
    try t.expect(shared.changedAt(a, t.io, "acme/api#1198") > 0);
    t.io.sleep(.fromMilliseconds(1100), .awake) catch {};
    const sent_before = client.sent;
    var after = try client.prDetailAt(t.allocator, "acme", "api", 1198, held.stamp);
    defer after.deinit(t.allocator);
    try t.expectEqual(sent_before + 1, client.sent);
    try t.expect(!std.mem.eql(u8, first.ok.bytes, after.ok.bytes));
    try t.expectEqualStrings(after.ok.bytes, shared.load(a, t.io, pr_url).?.body);
    // Dated after the write, so the stamp answers again.
    var settled = try client.prDetailAt(t.allocator, "acme", "api", 1198, held.stamp);
    defer settled.deinit(t.allocator);
    try t.expectEqual(sent_before + 1, client.sent);

    // The log says which was which: a cache hit with no request, a
    // revalidation's 304.
    const p = try log.path(t.allocator);
    defer t.allocator.free(p);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, p, t.allocator, .limited(1 << 20));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"reason\":\"cache_hit\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"reason\":\"revalidate\"") != null);
}

test "an entry another writer holds inside its valid_until answers with no request; /user is never shared" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const cache_root = try std.fs.path.join(t.allocator, &.{ dir, "http-cache" });
    defer t.allocator.free(cache_root);
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var budget: sdk.Budget = .{};
    budget.configure(t.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "tok", "", .{});
    defer client.deinit();
    client.budget = &budget;
    client.http_cache = .{ .root = cache_root, .service = "bitbucket" };
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Written the way the other side writes: decimal times, a 60 s
    // TTL, a listing (no key), and a body that is not what the server
    // would say — so an answer off the file is unmistakable.
    const raw = try std.fmt.allocPrint(a, "{s}/repositories/acme/api/pullrequests?state=OPEN&pagelen=25", .{base});
    const url = try sdk.http_cache.canonical(a, raw, &.{});
    const now = Io.Timestamp.now(t.io, .real).toSeconds();
    const path = try sdk.http_cache.entryPath(a, cache_root, "bitbucket", url);
    var out: Io.Writer.Allocating = .init(a);
    try out.writer.print("{{\"version\": 1, \"url\": \"{s}\", \"key\": \"\", \"status\": 200, \"etag\": \"\", \"stamp\": \"\", \"fetched_at\": {d}.25, \"valid_until\": {d}.25, \"content_type\": \"application/json\", \"body\": \"{{\\\"values\\\": [], \\\"from\\\": \\\"the other writer\\\"}}\"}}", .{ url, now - 5, now + 55 });
    sdk.cache.makeDir(t.io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = path, .data = out.written() });

    const served = srv.snapshot().served;
    var got = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer got.deinit(t.allocator);
    try t.expect(got == .ok);
    try t.expect(std.mem.indexOf(u8, got.ok.bytes, "the other writer") != null);
    try t.expectEqual(@as(u32, 0), client.sent);
    try t.expectEqual(served, srv.snapshot().served);
    try t.expectEqual(@as(u32, 1), budget.snapshot(now).hits);
    // `R` asks outright whatever is held.
    client.conditional = false;
    var fresh = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer fresh.deinit(t.allocator);
    try t.expectEqual(@as(u32, 1), client.sent);
    try t.expect(std.mem.indexOf(u8, fresh.ok.bytes, "the other writer") == null);
    client.conditional = true;

    // `/user` answers about the caller: never filed where another
    // token would read it.
    var me = try client.whoami(t.allocator);
    defer me.deinit(t.allocator);
    const user_url = try sdk.http_cache.canonical(a, try std.fmt.allocPrint(a, "{s}/user", .{base}), &.{});
    try t.expect(client.http_cache.?.load(a, t.io, user_url) == null);
    try t.expect(!shareable(user_url));
    try t.expect(!shareable("https://api.bitbucket.org/2.0/repositories/acme?pagelen=100&role=member"));
    try t.expect(shareable("https://api.bitbucket.org/2.0/repositories/acme/api/pullrequests/7/comments?pagelen=50"));
}

test "a 429 on a write pauses the budget and goes back to the pane: a write is never asked twice" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var budget: sdk.Budget = .{};
    budget.configure(t.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "tok", "", .{ .max_attempts = 3 });
    defer client.deinit();
    client.budget = &budget;
    srv.retryAfter(2);
    srv.rateLimitNext(1);
    var r = try client.approve(t.allocator, "acme", "api", 1198);
    defer r.deinit(t.allocator);
    try t.expect(r == .failed);
    try t.expect(r.failed.isRateLimited());
    try t.expectEqual(@as(u32, 1), client.sent);
    try t.expectEqual(@as(u32, 1), srv.snapshot().served);
    // The pane's chip says until when.
    try t.expect(budget.snapshot(Io.Timestamp.now(t.io, .real).toSeconds()).paused_until > 0);
}

test "a 429 on a read waits the pause out and asks again; nothing goes out while the pause runs" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var budget: sdk.Budget = .{};
    budget.configure(t.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "tok", "", .{});
    defer client.deinit();
    client.budget = &budget;
    srv.retryAfter(1);
    srv.rateLimitNext(1);
    const t0 = Io.Timestamp.now(t.io, .real).toMilliseconds();
    var r = try client.whoami(t.allocator);
    defer r.deinit(t.allocator);
    try t.expect(r == .ok);
    // Two on the wire — the 429 and the answer — and a second between.
    try t.expectEqual(@as(u32, 2), srv.snapshot().served);
    try t.expect(Io.Timestamp.now(t.io, .real).toMilliseconds() - t0 >= 900);
}

test "the budget reads the server's rate-limit headers and counts a 304 as a hit, a full GET as a miss" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const cache_root = try std.fs.path.join(t.allocator, &.{ dir, "http-cache" });
    defer t.allocator.free(cache_root);
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var budget: sdk.Budget = .{};
    budget.configure(t.io, .{ .label = "Bitbucket", .service = "bitbucket", .data_root = dir });
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "tok", "", .{});
    defer client.deinit();
    client.budget = &budget;
    client.http_cache = .{ .root = cache_root, .service = "bitbucket" };
    srv.budgetHeaders(1000, 900);
    var first = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer first.deinit(t.allocator);
    var second = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer second.deinit(t.allocator);
    const s = budget.snapshot(Io.Timestamp.now(t.io, .real).toSeconds());
    try t.expectEqual(@as(?i64, 1000), s.limit);
    try t.expectEqual(@as(?i64, 898), s.remaining);
    try t.expectEqual(@as(u32, 1), s.hits);
    try t.expectEqual(@as(u32, 1), s.misses);
    try t.expectEqual(@as(u32, 2), s.hour_calls);
    // Both calls are on today's tally, in the data root.
    try t.expectEqual(@as(u32, 2), s.today);
}

test "dry run sends nothing: a GET answers what is held, a write is refused, and the log says what would have gone out" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    const cache_root = try std.fs.path.join(t.allocator, &.{ dir, "http-cache" });
    defer t.allocator.free(cache_root);
    const log_dir = try std.fs.path.join(t.allocator, &.{ dir, "requests" });
    defer t.allocator.free(log_dir);
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var log = try sdk.RequestLog.openAt(t.allocator, t.io, log_dir, "bitbucket", "mnml-bitbucket");
    defer log.deinit();
    var budget: sdk.Budget = .{};
    budget.configure(t.io, .{ .label = "Bitbucket", .service = "bitbucket" });
    var client = try Client.init(t.allocator, t.io, base, "me@x.com", "tok", "", .{});
    defer client.deinit();
    client.budget = &budget;
    client.http_cache = .{ .root = cache_root, .service = "bitbucket" };
    client.log = &log;
    var live = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer live.deinit(t.allocator);
    const served = srv.snapshot().served;

    _ = budget.toggleDry();
    var held = try client.listPrs(t.allocator, "acme", "api", &.{"OPEN"}, "", 25);
    defer held.deinit(t.allocator);
    try t.expect(held == .ok);
    try t.expectEqualStrings(live.ok.bytes, held.ok.bytes);
    var never = try client.listPipelines(t.allocator, "acme", "api", 100);
    defer never.deinit(t.allocator);
    try t.expect(never == .failed);
    var write = try client.approve(t.allocator, "acme", "api", 1198);
    defer write.deinit(t.allocator);
    try t.expect(write == .failed);
    try t.expectEqual(served, srv.snapshot().served);

    const p = try log.path(t.allocator);
    defer t.allocator.free(p);
    const text = try Io.Dir.cwd().readFileAlloc(t.io, p, t.allocator, .limited(1 << 20));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "\"dry\":true") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"method\":\"POST\"") != null);
}
