//! The blocking sender on `std.http.Client`: one `Request` in, a
//! `Response` (status, headers, decoded body, timing) or a one-line
//! transport error out. Runs on a worker; the app never calls `send`
//! from the UI thread. gzip / deflate / zstd bodies are decoded by the
//! std client; brotli is not offered (`accept-encoding` says so).
//!
//! `JobResult` is the `.http` event payload: built here on the gpa,
//! owned by the event, adopted or destroyed by the handler.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");

pub const Header = parse.Header;
pub const Request = parse.Request;

/// Bodies past this are cut; the viewer says so.
pub const max_body: usize = 16 * 1024 * 1024;

pub const Timing = struct {
    /// Send → response head received.
    wait_ms: u64 = 0,
    /// Head → body fully read.
    receive_ms: u64 = 0,
    total_ms: u64 = 0,
};

pub const Response = struct {
    status: u16,
    /// The reason phrase; empty when the server sent none.
    status_text: []u8,
    /// Where the body came from after redirects.
    final_url: []u8,
    headers: []Header,
    /// Decoded body bytes, cut at `max_body`.
    body: []u8,
    truncated: bool = false,
    timing: Timing = .{},

    pub fn deinit(self: *Response, gpa: Allocator) void {
        gpa.free(self.status_text);
        gpa.free(self.final_url);
        for (self.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.headers);
        gpa.free(self.body);
        self.* = undefined;
    }

    pub fn clone(self: *const Response, gpa: Allocator) Allocator.Error!Response {
        var out: Response = .{
            .status = self.status,
            .status_text = try gpa.dupe(u8, self.status_text),
            .final_url = undefined,
            .headers = &.{},
            .body = undefined,
            .truncated = self.truncated,
            .timing = self.timing,
        };
        errdefer gpa.free(out.status_text);
        out.final_url = try gpa.dupe(u8, self.final_url);
        errdefer gpa.free(out.final_url);
        out.body = try gpa.dupe(u8, self.body);
        errdefer gpa.free(out.body);
        const hs = try gpa.alloc(Header, self.headers.len);
        var filled: usize = 0;
        errdefer {
            for (hs[0..filled]) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            gpa.free(hs);
        }
        for (self.headers) |h| {
            hs[filled].name = try gpa.dupe(u8, h.name);
            errdefer gpa.free(hs[filled].name);
            hs[filled].value = try gpa.dupe(u8, h.value);
            filled += 1;
        }
        out.headers = hs;
        return out;
    }

    /// Case-insensitive, first match.
    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }

    pub fn contentType(self: *const Response) ?[]const u8 {
        return self.header("content-type");
    }

    pub fn looksLikeJson(self: *const Response) bool {
        if (self.contentType()) |ct| if (std.mem.indexOf(u8, ct, "json") != null) return true;
        const b = std.mem.trimStart(u8, self.body, " \t\r\n");
        return b.len > 0 and (b[0] == '{' or b[0] == '[');
    }

    /// The shape the body viewer highlights it as.
    pub const Kind = enum { json, html, xml, text };

    pub fn kind(self: *const Response) Kind {
        if (self.looksLikeJson()) return .json;
        const ct = self.contentType() orelse "";
        if (std.mem.indexOf(u8, ct, "html") != null) return .html;
        if (std.mem.indexOf(u8, ct, "xml") != null) return .xml;
        const b = std.mem.trimStart(u8, self.body, " \t\r\n");
        if (std.mem.startsWith(u8, b, "<!DOCTYPE") or std.mem.startsWith(u8, b, "<html")) return .html;
        if (std.mem.startsWith(u8, b, "<?xml")) return .xml;
        return .text;
    }

    /// Every `Set-Cookie` value, in order.
    pub fn setCookies(self: *const Response, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) try out.append(arena, h.value);
        return out.toOwnedSlice(arena);
    }
};

/// What a send produced. `err` is a gpa-owned one-liner.
pub const Outcome = union(enum) {
    ok: Response,
    err: []u8,
    /// A handler adopted the response; nothing left to free.
    moved,

    pub fn deinit(self: *Outcome, gpa: Allocator) void {
        switch (self.*) {
            .ok => |*r| r.deinit(gpa),
            .err => |e| gpa.free(e),
            .moved => {},
        }
        self.* = .moved;
    }

    /// Move the response out, leaving `.moved` behind.
    pub fn take(self: *Outcome) ?Response {
        switch (self.*) {
            .ok => |r| {
                self.* = .moved;
                return r;
            },
            else => return null,
        }
    }
};

pub const SendOptions = struct {
    /// An extra `Cookie` header from the jar, unless the request has one.
    cookie: ?[]const u8 = null,
};

/// Fire `req` and wait for the whole response. Never throws for a
/// transport failure — that is the `.err` outcome. OOM is the one error.
pub fn send(gpa: Allocator, io: Io, req: *const Request, opts: SendOptions) Allocator.Error!Outcome {
    return sendInner(gpa, io, req, opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => .{ .err = try describe(gpa, err) },
    };
}

fn describe(gpa: Allocator, err: anyerror) Allocator.Error![]u8 {
    const name = @errorName(err);
    const prefix: []const u8 = switch (err) {
        error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.NetworkUnreachable, error.HostUnreachable => "connection failed: ",
        error.UnknownHostName, error.NameServerFailure, error.TemporaryNameServerFailure, error.HostLacksNetworkAddresses => "dns: ",
        error.TlsInitializationFailed, error.TlsFailure, error.CertificateBundleLoadFailure => "tls: ",
        error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidFormat, error.InvalidPort, error.UnexpectedCharacter, error.InvalidMethod => "bad request: ",
        error.Canceled => "canceled: ",
        else => "",
    };
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, name });
}

const SendError = Allocator.Error || std.http.Client.RequestError || std.http.Client.Request.ReceiveHeadError || std.Uri.ParseError || Io.Writer.Error || Io.Reader.StreamError || error{ InvalidMethod, UnsupportedCompressionMethod, WriteFailed };

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn sendInner(gpa: Allocator, io: Io, req: *const Request, opts: SendOptions) SendError!Outcome {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const uri = try std.Uri.parse(std.mem.trim(u8, req.url, " \t"));
    var method_buf: [16]u8 = undefined;
    if (req.method.len > method_buf.len) return error.InvalidMethod;
    const upper = std.ascii.upperString(&method_buf, req.method);
    const method = std.meta.stringToEnum(std.http.Method, upper) orelse return error.InvalidMethod;

    // The std client owns six headers with default behaviour; a request
    // header of that name overrides it instead of duplicating it.
    var std_headers: std.http.Client.Request.Headers = .{};
    var extra: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer extra.deinit(gpa);
    var has_cookie = false;
    for (req.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "host")) {
            std_headers.host = .{ .override = h.value };
        } else if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            std_headers.authorization = .{ .override = h.value };
        } else if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
            std_headers.user_agent = .{ .override = h.value };
        } else if (std.ascii.eqlIgnoreCase(h.name, "connection")) {
            std_headers.connection = .{ .override = h.value };
        } else if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) {
            std_headers.accept_encoding = .{ .override = h.value };
        } else if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            std_headers.content_type = .{ .override = h.value };
        } else {
            if (std.ascii.eqlIgnoreCase(h.name, "cookie")) has_cookie = true;
            if (std.mem.indexOf(u8, h.value, "\r\n") != null or std.mem.indexOfScalar(u8, h.name, ':') != null or h.name.len == 0) continue;
            try extra.append(gpa, .{ .name = h.name, .value = h.value });
        }
    }
    if (!has_cookie) if (opts.cookie) |c| try extra.append(gpa, .{ .name = "cookie", .value = c });
    if (std_headers.user_agent == .default) std_headers.user_agent = .{ .override = "mnml-zig" };

    const started = nowMs(io);
    var request = try client.request(method, uri, .{
        .headers = std_headers,
        .extra_headers = extra.items,
        .keep_alive = false,
        .redirect_behavior = if (req.body == null) @enumFromInt(5) else .unhandled,
    });
    defer request.deinit();

    if (req.body) |body| {
        request.transfer_encoding = .{ .content_length = body.len };
        var bw = try request.sendBodyUnflushed(&.{});
        try bw.writer.writeAll(body);
        try bw.end();
        try request.connection.?.flush();
    } else {
        try request.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    const head_at = nowMs(io);

    const status: u16 = @intFromEnum(response.head.status);
    const status_text = try gpa.dupe(u8, response.head.reason);
    errdefer gpa.free(status_text);
    var headers: std.ArrayListUnmanaged(Header) = .empty;
    errdefer {
        for (headers.items) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        headers.deinit(gpa);
    }
    var hit = response.head.iterateHeaders();
    while (hit.next()) |h| {
        const n = try gpa.dupe(u8, h.name);
        errdefer gpa.free(n);
        const v = try gpa.dupe(u8, h.value);
        errdefer gpa.free(v);
        try headers.append(gpa, .{ .name = n, .value = v });
    }
    const final_url = try std.fmt.allocPrint(gpa, "{f}", .{request.uri});
    errdefer gpa.free(final_url);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) gpa.free(decompress_buffer);
    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var sink: Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var truncated = false;
    var limited = Io.Writer.Allocating.init(gpa);
    defer limited.deinit();
    _ = reader.streamRemaining(&sink.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        error.WriteFailed => return error.WriteFailed,
    };
    var body_bytes = sink.written();
    if (body_bytes.len > max_body) {
        body_bytes = body_bytes[0..max_body];
        truncated = true;
    }
    const body = try gpa.dupe(u8, body_bytes);
    errdefer gpa.free(body);
    const done_at = nowMs(io);

    return .{ .ok = .{
        .status = status,
        .status_text = status_text,
        .final_url = final_url,
        .headers = try headers.toOwnedSlice(gpa),
        .body = body,
        .truncated = truncated,
        .timing = .{
            .wait_ms = @intCast(@max(head_at - started, 0)),
            .receive_ms = @intCast(@max(done_at - head_at, 0)),
            .total_ms = @intCast(@max(done_at - started, 0)),
        },
    } };
}

// ─── the event payload ──────────────────────────────────────────────────

/// Why a job was fired; the handler routes on it.
pub const JobKind = enum { send, fan_env, bench, lookup, chain };

pub const JobResult = struct {
    job: u64,
    /// The pane that fired it, if any (a chain / fan-out has none).
    pane: ?u32,
    kind: JobKind,
    outcome: Outcome,
    /// Extra text the kind needs (fan_env: the env name; bench / chain:
    /// the report). Owned.
    label: ?[]u8 = null,
    /// The URL that was actually sent (post-expansion). Owned.
    url: []u8,
    method: []u8,
    /// How long the whole job took, as the worker measured it.
    elapsed_ms: u64 = 0,

    pub fn create(gpa: Allocator, job: u64, pane: ?u32, kind: JobKind, method: []const u8, url: []const u8, outcome: Outcome) Allocator.Error!*JobResult {
        const r = try gpa.create(JobResult);
        errdefer gpa.destroy(r);
        const m = try gpa.dupe(u8, method);
        errdefer gpa.free(m);
        const u = try gpa.dupe(u8, url);
        errdefer gpa.free(u);
        r.* = .{ .job = job, .pane = pane, .kind = kind, .outcome = outcome, .url = u, .method = m };
        return r;
    }

    pub fn destroy(self: *JobResult, gpa: Allocator) void {
        self.outcome.deinit(gpa);
        if (self.label) |l| gpa.free(l);
        gpa.free(self.url);
        gpa.free(self.method);
        gpa.destroy(self);
    }

    pub fn status(self: *const JobResult) ?u16 {
        return switch (self.outcome) {
            .ok => |r| r.status,
            .err, .moved => null,
        };
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const mock = @import("mock.zig");

test "send: a real round trip over a local socket — status, headers, body, timing" {
    const io = testing.io;
    var server = try mock.Server.start(testing.allocator, io, .{
        .status = 418,
        .status_text = "I'm a teapot",
        .headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "set-cookie", .value = "sid=abc; Path=/" } },
        .body = "{\"tea\":true}",
    });
    defer server.stop(io);
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/brew?x=1", .{server.port});
    defer testing.allocator.free(url);
    try req.setUrl(testing.allocator, url);
    try req.setMethod(testing.allocator, "post");
    try req.addHeader(testing.allocator, "X-Probe", "yes");
    try req.addHeader(testing.allocator, "Content-Type", "text/plain");
    try req.setBody(testing.allocator, "hello");
    var outcome = try send(testing.allocator, io, &req, .{ .cookie = "a=b" });
    defer outcome.deinit(testing.allocator);
    const resp = outcome.ok;
    try testing.expectEqual(@as(u16, 418), resp.status);
    try testing.expectEqualStrings("I'm a teapot", resp.status_text);
    try testing.expectEqualStrings("application/json", resp.header("Content-Type").?);
    try testing.expectEqualStrings("{\"tea\":true}", resp.body);
    try testing.expect(resp.looksLikeJson());
    try testing.expect(resp.kind() == .json);
    const cookies = try resp.setCookies(testing.allocator);
    defer testing.allocator.free(cookies);
    try testing.expectEqual(@as(usize, 1), cookies.len);
    try testing.expect(std.mem.indexOf(u8, resp.final_url, "/brew?x=1") != null);
    // The server saw what we sent.
    const seen = server.lastRequest();
    try testing.expect(std.mem.startsWith(u8, seen, "POST /brew?x=1 HTTP/1.1\r\n"));
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "x-probe: yes\r\n") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "cookie: a=b\r\n") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "content-type: text/plain\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, seen, "\r\n\r\nhello"));
    var cloned = try resp.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);
    try testing.expectEqualStrings(resp.body, cloned.body);
}

test "send: a closed port is a connection failure, not an error" {
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, "http://127.0.0.1:1/nothing");
    var outcome = try send(testing.allocator, testing.io, &req, .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome == .err);
    try testing.expect(std.mem.indexOf(u8, outcome.err, "connection failed") != null or std.mem.indexOf(u8, outcome.err, "Refused") != null);
    var bad = try Request.init(testing.allocator);
    defer bad.deinit(testing.allocator);
    try bad.setUrl(testing.allocator, "nonsense");
    var o2 = try send(testing.allocator, testing.io, &bad, .{});
    defer o2.deinit(testing.allocator);
    try testing.expect(o2 == .err);
}

test "JobResult owns its outcome" {
    const gpa = testing.allocator;
    const r = try JobResult.create(gpa, 1, 0, .send, "GET", "http://x", .{ .err = try gpa.dupe(u8, "boom") });
    r.label = try gpa.dupe(u8, "dev");
    try testing.expect(r.status() == null);
    r.destroy(gpa);
}
