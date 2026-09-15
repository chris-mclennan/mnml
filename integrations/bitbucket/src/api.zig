//! Bitbucket Cloud REST v2, only the endpoints the pane reads and
//! writes. Blocking — the pane calls this from its own loop and paints
//! a progress line around it, which is why every call is a plain
//! function and not a future.
//!
//! Two things are deliberate here:
//!
//! * **A failure is a value, not an error.** `send` answers `.failed`
//!   with the status, the server's message and a parsed `Retry-After`;
//!   only running out of memory is an `error`. A 403 on one archived
//!   repo has to be paintable in that repo's row, not fatal to the fan
//!   out, and a transport failure has to read the same way as an HTTP
//!   one.
//! * **The rate gate is in front of every request.** Bitbucket counts
//!   per account, so a fan-out over ten repos is what trips the
//!   ceiling. Requests are spaced by `rate.min_interval_ms`, a 429 is
//!   retried up to `rate.max_attempts` times honouring `Retry-After`
//!   (clamped by `max_backoff_secs`), and nothing else is retried —
//!   a 401 will not become a 200 by asking twice.
//!
//! Read and write go out with different tokens (`auth.zig`): the list
//! and the detail on the read token, approve / request-changes /
//! comment / merge on the write one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cfg = @import("config.zig");

pub const default_base_url = "https://api.bitbucket.org/2.0";
pub const user_agent = "mnml-bitbucket/0.1.0";

pub const Method = enum {
    GET,
    POST,
    DELETE,

    fn std_method(m: Method) std.http.Method {
        return switch (m) {
            .GET => .GET,
            .POST => .POST,
            .DELETE => .DELETE,
        };
    }
};

pub const Side = enum { read, write };

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

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

    /// A label short enough for a list row's STATE column. Written into
    /// the caller's buffer because a row paints and moves on.
    pub fn shortLabel(self: Failure, buf: []u8) []const u8 {
        const status = self.status orelse return fit(buf, "network error");
        return switch (status) {
            429 => if (self.retry_after_secs) |s|
                (std.fmt.bufPrint(buf, "429 · retry in {d}s", .{s}) catch fit(buf, "429 · rate limited"))
            else
                fit(buf, "429 · rate limited"),
            401, 403 => fit(buf, "auth failed"),
            404 => fit(buf, "no such repo"),
            // A 400 is nearly always Bitbucket naming the BBQL field it
            // will not filter on; a bare "HTTP 400" hides the only
            // useful part.
            400 => std.fmt.bufPrint(buf, "HTTP 400 · {s}", .{self.message[0..@min(self.message.len, 48)]}) catch fit(buf, "HTTP 400"),
            else => std.fmt.bufPrint(buf, "HTTP {d}", .{status}) catch fit(buf, "HTTP error"),
        };
    }

    fn fit(buf: []u8, s: []const u8) []const u8 {
        const n = @min(buf.len, s.len);
        @memcpy(buf[0..n], s[0..n]);
        return buf[0..n];
    }
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
    have_write: bool,
    rate: cfg.Rate,
    /// The wall clock of the last request, for the gate.
    last_request_ms: i64 = 0,
    /// Requests actually sent, retries included — the progress line and
    /// the rate-limit tests both read it.
    sent: u32 = 0,
    /// Set by the caller when no write token could be resolved and the
    /// borrow is off: every write refuses with this, before a request
    /// leaves the process. `auth.Tokens.writeRefusal` is what fills it.
    write_refusal: ?[]const u8 = null,

    pub fn init(
        gpa: Allocator,
        io: Io,
        base_url: []const u8,
        email: []const u8,
        read_token: []const u8,
        write_token: []const u8,
        rate: cfg.Rate,
    ) Allocator.Error!Client {
        const auth = @import("auth.zig");
        const trimmed = std.mem.trimEnd(u8, if (base_url.len > 0) base_url else default_base_url, "/");
        return .{
            .gpa = gpa,
            .io = io,
            .base_url = try gpa.dupe(u8, trimmed),
            .read_header = try auth.basicHeader(gpa, email, read_token),
            .write_header = if (write_token.len > 0) try auth.basicHeader(gpa, email, write_token) else try gpa.dupe(u8, ""),
            .have_write = write_token.len > 0,
            .rate = rate,
        };
    }

    pub fn deinit(self: *Client) void {
        self.gpa.free(self.base_url);
        self.gpa.free(self.read_header);
        self.gpa.free(self.write_header);
        self.* = undefined;
    }

    /// Why a write cannot go out, or null when one can.
    pub fn writeRefused(self: *const Client) ?[]const u8 {
        return self.write_refusal;
    }

    fn header(self: *const Client, side: Side) []const u8 {
        return switch (side) {
            .read => self.read_header,
            .write => if (self.have_write) self.write_header else self.read_header,
        };
    }

    /// Wait out `min_interval_ms` since the last request.
    fn gate(self: *Client) void {
        const now = nowMs(self.io);
        const since = now - self.last_request_ms;
        const want: i64 = @intCast(self.rate.min_interval_ms);
        if (self.last_request_ms != 0 and since >= 0 and since < want) {
            self.io.sleep(.fromMilliseconds(@intCast(want - since)), .awake) catch {};
        }
        self.last_request_ms = nowMs(self.io);
    }

    /// One request, gated and retried. `path` starts with `/` and
    /// already carries its query.
    pub fn send(self: *Client, gpa: Allocator, method: Method, path: []const u8, payload: ?[]const u8, side: Side) Allocator.Error!Reply {
        const url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ self.base_url, path });
        defer gpa.free(url);
        var attempt: u8 = 0;
        while (true) {
            attempt += 1;
            self.gate();
            self.sent += 1;
            var reply = try self.once(gpa, method, url, payload, side);
            switch (reply) {
                .ok => return reply,
                .failed => |f| {
                    const last = attempt >= @max(self.rate.max_attempts, 1);
                    if (!f.isRateLimited() or last) return reply;
                    const wait = @min(f.retry_after_secs orelse self.rate.default_backoff_secs, self.rate.max_backoff_secs);
                    reply.deinit(gpa);
                    self.io.sleep(.fromMilliseconds(@as(i64, wait) * 1000), .awake) catch {};
                },
            }
        }
    }

    fn once(self: *Client, gpa: Allocator, method: Method, url: []const u8, payload: ?[]const u8, side: Side) Allocator.Error!Reply {
        var client: std.http.Client = .{ .allocator = gpa, .io = self.io };
        defer client.deinit();
        const uri = std.Uri.parse(url) catch return transportFailure(gpa, "the base URL does not parse");

        var extra: [2]std.http.Header = undefined;
        var n_extra: usize = 1;
        extra[0] = .{ .name = "authorization", .value = self.header(side) };
        if (payload != null) {
            extra[1] = .{ .name = "content-type", .value = "application/json" };
            n_extra = 2;
        }

        var req = client.request(method.std_method(), uri, .{
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
                retry_after = std.fmt.parseInt(u32, std.mem.trim(u8, h.value, " \t"), 10) catch null;
            }
        }

        var transfer: [4096]u8 = undefined;
        var sink: Io.Writer.Allocating = .init(gpa);
        errdefer sink.deinit();
        const reader = response.reader(&transfer);
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

    /// `GET /user` — the account the read token belongs to. What a
    /// `mine` / `reviewing` tab needs before it can ask anything.
    pub fn whoami(self: *Client, gpa: Allocator) Allocator.Error!Reply {
        return self.send(gpa, .GET, "/user", null, .read);
    }

    /// `GET /repositories/{ws}` — the slugs, slim-projected.
    pub fn listRepos(self: *Client, gpa: Allocator, workspace: []const u8) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/repositories/{s}?role=member&pagelen=100&fields=values.slug,next", .{workspace});
        defer gpa.free(path);
        return self.send(gpa, .GET, path, null, .read);
    }

    pub fn listPrs(
        self: *Client,
        gpa: Allocator,
        workspace: []const u8,
        repo: []const u8,
        state: cfg.State,
        bbql: []const u8,
        page_len: u32,
    ) Allocator.Error!Reply {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("/repositories/{s}/{s}/pullrequests?pagelen={d}&state={s}", .{ workspace, repo, page_len, @tagName(state) }) catch return error.OutOfMemory;
        if (bbql.len > 0) {
            w.writeAll("&q=") catch return error.OutOfMemory;
            percentEncode(w, bbql) catch return error.OutOfMemory;
        }
        return self.send(gpa, .GET, out.written(), null, .read);
    }

    pub fn prDetail(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .GET, workspace, repo, id, "", null, .read);
    }

    pub fn activity(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .GET, workspace, repo, id, "/activity?pagelen=50", null, .read);
    }

    pub fn diffstat(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .GET, workspace, repo, id, "/diffstat?pagelen=100", null, .read);
    }

    pub fn diff(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .GET, workspace, repo, id, "/diff", null, .read);
    }

    /// Build statuses for the PR's source commit.
    pub fn statuses(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, sha: []const u8) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/repositories/{s}/{s}/commit/{s}/statuses?pagelen=50", .{ workspace, repo, sha });
        defer gpa.free(path);
        return self.send(gpa, .GET, path, null, .read);
    }

    pub fn approve(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .POST, workspace, repo, id, "/approve", "", .write);
    }

    pub fn unapprove(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .DELETE, workspace, repo, id, "/approve", null, .write);
    }

    pub fn requestChanges(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .POST, workspace, repo, id, "/request-changes", "", .write);
    }

    pub fn withdrawChanges(self: *Client, gpa: Allocator, workspace: []const u8, repo: []const u8, id: i64) Allocator.Error!Reply {
        return self.prPath(gpa, .DELETE, workspace, repo, id, "/request-changes", null, .write);
    }

    /// A top-level comment. `path` + `line`, when given, make it an
    /// inline one on the diff.
    pub fn comment(
        self: *Client,
        gpa: Allocator,
        workspace: []const u8,
        repo: []const u8,
        id: i64,
        text: []const u8,
        file_path: []const u8,
        line: ?i64,
    ) Allocator.Error!Reply {
        var body: Io.Writer.Allocating = .init(gpa);
        defer body.deinit();
        const w = &body.writer;
        w.writeAll("{\"content\":{\"raw\":") catch return error.OutOfMemory;
        writeJsonString(w, text) catch return error.OutOfMemory;
        w.writeAll("}") catch return error.OutOfMemory;
        if (file_path.len > 0) {
            w.writeAll(",\"inline\":{\"path\":") catch return error.OutOfMemory;
            writeJsonString(w, file_path) catch return error.OutOfMemory;
            if (line) |n| w.print(",\"to\":{d}", .{n}) catch return error.OutOfMemory;
            w.writeAll("}") catch return error.OutOfMemory;
        }
        w.writeAll("}") catch return error.OutOfMemory;
        return self.prPath(gpa, .POST, workspace, repo, id, "/comments", body.written(), .write);
    }

    pub const MergeStrategy = enum {
        merge_commit,
        squash,
        fast_forward,

        pub fn label(s: MergeStrategy) []const u8 {
            return switch (s) {
                .merge_commit => "merge commit",
                .squash => "squash",
                .fast_forward => "fast-forward",
            };
        }
    };

    pub fn merge(
        self: *Client,
        gpa: Allocator,
        workspace: []const u8,
        repo: []const u8,
        id: i64,
        strategy: MergeStrategy,
        close_source_branch: bool,
    ) Allocator.Error!Reply {
        const body = try std.fmt.allocPrint(gpa, "{{\"merge_strategy\":\"{s}\",\"close_source_branch\":{s}}}", .{
            @tagName(strategy),
            if (close_source_branch) "true" else "false",
        });
        defer gpa.free(body);
        return self.prPath(gpa, .POST, workspace, repo, id, "/merge", body, .write);
    }

    fn prPath(
        self: *Client,
        gpa: Allocator,
        method: Method,
        workspace: []const u8,
        repo: []const u8,
        id: i64,
        tail: []const u8,
        payload: ?[]const u8,
        side: Side,
    ) Allocator.Error!Reply {
        const path = try std.fmt.allocPrint(gpa, "/repositories/{s}/{s}/pullrequests/{d}{s}", .{ workspace, repo, id, tail });
        defer gpa.free(path);
        return self.send(gpa, method, path, payload, side);
    }
};

/// `author.account_id = "{id}"` and friends, ready for `&q=`.
pub fn percentEncode(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
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

/// `author.account_id = "<id>"` — the BBQL a `mine` tab sends. Owned.
pub fn authorPredicate(gpa: Allocator, account_id: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "author.account_id = \"{s}\"", .{account_id});
}

/// `reviewers.account_id = "<id>"` — the BBQL a `reviewing` tab sends.
pub fn reviewerPredicate(gpa: Allocator, account_id: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "reviewers.account_id = \"{s}\"", .{account_id});
}

/// Two predicates joined; either may be empty. Owned.
pub fn andPredicates(gpa: Allocator, a: []const u8, b: []const u8) Allocator.Error![]u8 {
    if (a.len == 0) return gpa.dupe(u8, b);
    if (b.len == 0) return gpa.dupe(u8, a);
    return std.fmt.allocPrint(gpa, "({s}) AND ({s})", .{ a, b });
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const listener = @import("../tools/fake_bitbucket/listener.zig");

test "a short label says what the user has to fix, not just a number" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("network error", (Failure{ .status = null, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("auth failed", (Failure{ .status = 401, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("auth failed", (Failure{ .status = 403, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("no such repo", (Failure{ .status = 404, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("429 · rate limited", (Failure{ .status = 429, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("429 · retry in 12s", (Failure{ .status = 429, .retry_after_secs = 12, .message = &.{} }).shortLabel(&buf));
    try t.expectEqualStrings("HTTP 500", (Failure{ .status = 500, .message = &.{} }).shortLabel(&buf));
    var msg = [_]u8{'x'} ** 5;
    try t.expectEqualStrings("HTTP 400 · xxxxx", (Failure{ .status = 400, .message = &msg }).shortLabel(&buf));
}

test "the server's message is pulled out of Bitbucket's error envelope" {
    try t.expectEqualStrings("Rate limit exceeded", serverMessage("{\"type\":\"error\",\"error\":{\"message\":\"Rate limit exceeded\"}}"));
    try t.expectEqualStrings("<html>oops", serverMessage("<html>oops\nmore"));
    try t.expectEqualStrings("", serverMessage(""));
}

test "BBQL predicates and their percent encoding" {
    const a = try authorPredicate(t.allocator, "acct-chris");
    defer t.allocator.free(a);
    try t.expectEqualStrings("author.account_id = \"acct-chris\"", a);
    const r = try reviewerPredicate(t.allocator, "acct-chris");
    defer t.allocator.free(r);
    try t.expectEqualStrings("reviewers.account_id = \"acct-chris\"", r);
    const both = try andPredicates(t.allocator, a, "updated_on >= 2026-01-01");
    defer t.allocator.free(both);
    try t.expectEqualStrings("(author.account_id = \"acct-chris\") AND (updated_on >= 2026-01-01)", both);
    const only_a = try andPredicates(t.allocator, a, "");
    defer t.allocator.free(only_a);
    try t.expectEqualStrings(a, only_a);
    const only_b = try andPredicates(t.allocator, "", "x");
    defer t.allocator.free(only_b);
    try t.expectEqualStrings("x", only_b);

    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try percentEncode(&out.writer, "a b\"c=d&e");
    try t.expectEqualStrings("a%20b%22c%3Dd%26e", out.written());
}

/// A client wired to a fake server on an ephemeral port.
fn testClient(srv: *listener.Server, rate: cfg.Rate) !Client {
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    return Client.init(t.allocator, t.io, base, "me@example.com", "read-token", "write-token", rate);
}

test "the read endpoints come back parseable, against a real fake server" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    var c = try testClient(srv, .{ .min_interval_ms = 0 });
    defer c.deinit();

    var who = try c.whoami(t.allocator);
    defer who.deinit(t.allocator);
    try t.expect(who == .ok);
    try t.expect(std.mem.indexOf(u8, who.ok.bytes, "acct-chris") != null);

    var list = try c.listPrs(t.allocator, "acme", "api", .OPEN, "", 50);
    defer list.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, list.ok.bytes, "Fix the login redirect") != null);

    var detail = try c.prDetail(t.allocator, "acme", "api", 1234);
    defer detail.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, detail.ok.bytes, "\"description\":{\"raw\"") != null);

    var act = try c.activity(t.allocator, "acme", "api", 1234);
    defer act.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, act.ok.bytes, "withQuery needs to escape") != null);

    var ds = try c.diffstat(t.allocator, "acme", "api", 1234);
    defer ds.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, ds.ok.bytes, "lines_added") != null);

    var d = try c.diff(t.allocator, "acme", "api", 1234);
    defer d.deinit(t.allocator);
    try t.expect(std.mem.startsWith(u8, d.ok.bytes, "diff --git"));

    var st = try c.statuses(t.allocator, "acme", "api", "abc1234def5678");
    defer st.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, st.ok.bytes, "Pipeline #412") != null);

    var repos = try c.listRepos(t.allocator, "acme");
    defer repos.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, repos.ok.bytes, "\"slug\":\"web\"") != null);
}

test "a BBQL author predicate survives the percent encoding and filters on the server" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    var c = try testClient(srv, .{ .min_interval_ms = 0 });
    defer c.deinit();
    const q = try authorPredicate(t.allocator, "acct-chris");
    defer t.allocator.free(q);
    var mine = try c.listPrs(t.allocator, "acme", "api", .OPEN, q, 50);
    defer mine.deinit(t.allocator);
    try t.expect(std.mem.indexOf(u8, mine.ok.bytes, "Fix the login redirect") != null);
    try t.expect(std.mem.indexOf(u8, mine.ok.bytes, "Bump the client timeout") == null);
}

test "the write endpoints move the server's state — approve, request changes, comment, merge" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    var c = try testClient(srv, .{ .min_interval_ms = 0 });
    defer c.deinit();

    var ap = try c.approve(t.allocator, "acme", "api", 1198);
    defer ap.deinit(t.allocator);
    try t.expect(ap == .ok);
    try t.expectEqual(@as(@TypeOf(srv.snapshot().votes[0]), .approved), srv.snapshot().voteFor(1198));

    var rc = try c.requestChanges(t.allocator, "acme", "api", 1198);
    defer rc.deinit(t.allocator);
    try t.expectEqual(@as(@TypeOf(srv.snapshot().votes[0]), .changes_requested), srv.snapshot().voteFor(1198));

    var un = try c.unapprove(t.allocator, "acme", "api", 1198);
    defer un.deinit(t.allocator);
    try t.expectEqual(@as(u16, 204), un.ok.status);
    try t.expectEqual(@as(@TypeOf(srv.snapshot().votes[0]), .none), srv.snapshot().voteFor(1198));

    var cm = try c.comment(t.allocator, "acme", "api", 1234, "looks good to me", "", null);
    defer cm.deinit(t.allocator);
    try t.expectEqual(@as(u16, 201), cm.ok.status);
    try t.expectEqual(@as(usize, 1), srv.snapshot().comment_count);
    try t.expectEqualStrings("looks good to me", srv.snapshot().comments[0].text);

    var inline_cm = try c.comment(t.allocator, "acme", "api", 1234, "escape this", "src/auth/session.zig", 44);
    defer inline_cm.deinit(t.allocator);
    try t.expectEqualStrings("src/auth/session.zig", srv.snapshot().comments[1].path);

    var mg = try c.merge(t.allocator, "acme", "api", 1234, .squash, true);
    defer mg.deinit(t.allocator);
    try t.expect(mg == .ok);
    try t.expect(srv.snapshot().isMerged(1234));
    try t.expect(std.mem.indexOf(u8, mg.ok.bytes, "\"state\":\"MERGED\"") != null);
}

test "a 429 is retried honouring Retry-After; a 404 is not retried at all" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    var c = try testClient(srv, .{ .min_interval_ms = 0, .max_attempts = 3, .max_backoff_secs = 0 });
    defer c.deinit();
    srv.rateLimitNext(2);
    var ok = try c.whoami(t.allocator);
    defer ok.deinit(t.allocator);
    try t.expect(ok == .ok);
    // Three requests went out for one call: two 429s and the answer.
    try t.expectEqual(@as(u32, 3), c.sent);

    // Past the attempt budget the 429 is what the caller sees, with the
    // Retry-After the server sent.
    srv.rateLimitNext(5);
    c.sent = 0;
    var limited = try c.whoami(t.allocator);
    defer limited.deinit(t.allocator);
    try t.expect(limited == .failed);
    try t.expectEqual(@as(u16, 429), limited.failed.status.?);
    try t.expectEqual(@as(u32, 1), limited.failed.retry_after_secs.?);
    try t.expectEqual(@as(u32, 3), c.sent);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("429 · retry in 1s", limited.failed.shortLabel(&buf));

    // A 404 answers once and stops — asking again would not help.
    srv.rateLimitNext(0);
    c.sent = 0;
    var missing = try c.prDetail(t.allocator, "acme", "api", 999999);
    defer missing.deinit(t.allocator);
    try t.expect(missing == .failed);
    try t.expectEqual(@as(u16, 404), missing.failed.status.?);
    try t.expectEqual(@as(u32, 1), c.sent);
    try t.expectEqualStrings("Resource not found", missing.failed.message);
}

test "a bad token is a 401 the pane can name, and a dead port is a transport failure" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    // An empty read token still makes a syntactically valid header, so
    // the refusal comes from the server, not from us.
    var c = try Client.init(t.allocator, t.io, base, "", "", "", .{ .min_interval_ms = 0 });
    defer c.deinit();
    var r = try c.whoami(t.allocator);
    defer r.deinit(t.allocator);
    try t.expect(r == .failed);
    try t.expectEqual(@as(u16, 401), r.failed.status.?);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("auth failed", r.failed.shortLabel(&buf));

    var dead = try Client.init(t.allocator, t.io, "http://127.0.0.1:1", "a@b.c", "x", "x", .{ .min_interval_ms = 0 });
    defer dead.deinit();
    var boom = try dead.whoami(t.allocator);
    defer boom.deinit(t.allocator);
    try t.expect(boom == .failed);
    try t.expect(boom.failed.status == null);
    try t.expectEqualStrings("network error", boom.failed.shortLabel(&buf));
}

test "the write side goes out under the write token, and borrows the read one when there is none" {
    const srv = try listener.Server.start(t.allocator, t.io, 0);
    defer srv.stop();
    const base = try srv.baseUrl(t.allocator);
    defer t.allocator.free(base);
    var split = try Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "write-tok", .{ .min_interval_ms = 0 });
    defer split.deinit();
    try t.expect(split.have_write);
    try t.expect(!std.mem.eql(u8, split.header(.read), split.header(.write)));

    var single = try Client.init(t.allocator, t.io, base, "me@x.com", "read-tok", "", .{ .min_interval_ms = 0 });
    defer single.deinit();
    try t.expect(!single.have_write);
    try t.expectEqualStrings(single.header(.read), single.header(.write));
}
