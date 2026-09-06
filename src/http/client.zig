//! The blocking sender on `std.http.Client`: one `Request` in, a
//! `Response` (status, headers, decoded body, timing) or a one-line
//! transport error out. Runs on a worker; the app never calls `send`
//! from the UI thread. gzip / deflate / zstd bodies are decoded by the
//! std client; brotli is not offered (`accept-encoding` says so).
//!
//! Redirects are followed here, not by the std client (`redirect_behavior
//! = .unhandled`): each hop's `Set-Cookie` is kept on the response as a
//! `HopCookie` so the jar sees it, `Location` resolves against the hop,
//! 303 and a 301 / 302 on POST rewrite to GET without the body, 307 /
//! 308 resend it, and `max_redirects` hops is the cap — what curl and a
//! browser do. A cookie set by a hop rides to the next hop on the same
//! host; a hop to another host carries neither the jar's cookies nor
//! `Authorization`. A body on a bodyless method (GET, DELETE …) goes
//! out with its length as curl and reqwest send it — std refuses that
//! pairing with an assert, so the bytes are written past `sendBodiless`.
//!
//! `JobResult` is the `.http` event payload: built here on the gpa,
//! owned by the event, adopted or destroyed by the handler.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const cookies_mod = @import("cookies.zig");

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

/// A `Set-Cookie` a redirect hop answered with, and the host it belongs
/// to — the jar keys by that host, not by where the body finally came from.
pub const HopCookie = struct {
    host: []u8,
    value: []u8,
};

/// Frees the entries, not the slice — for an `ArrayList`'s `items`.
fn freeHopCookieEntries(gpa: Allocator, list: []const HopCookie) void {
    for (list) |c| {
        gpa.free(c.host);
        gpa.free(c.value);
    }
}

pub fn freeHopCookies(gpa: Allocator, list: []HopCookie) void {
    freeHopCookieEntries(gpa, list);
    gpa.free(list);
}

pub fn cloneHopCookies(gpa: Allocator, list: []const HopCookie) Allocator.Error![]HopCookie {
    const out = try gpa.alloc(HopCookie, list.len);
    var filled: usize = 0;
    errdefer {
        freeHopCookieEntries(gpa, out[0..filled]);
        gpa.free(out);
    }
    for (list) |c| {
        out[filled].host = try gpa.dupe(u8, c.host);
        errdefer gpa.free(out[filled].host);
        out[filled].value = try gpa.dupe(u8, c.value);
        filled += 1;
    }
    return out;
}

/// The most hops a send follows before it is an error.
pub const max_redirects: u8 = 10;

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
    /// `Set-Cookie`s from the redirect hops before this response, in
    /// order; the final response's own are in `headers`.
    hop_cookies: []HopCookie = &.{},

    pub fn deinit(self: *Response, gpa: Allocator) void {
        gpa.free(self.status_text);
        gpa.free(self.final_url);
        for (self.headers) |h| {
            gpa.free(h.name);
            gpa.free(h.value);
        }
        gpa.free(self.headers);
        gpa.free(self.body);
        freeHopCookies(gpa, self.hop_cookies);
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
        out.hop_cookies = try cloneHopCookies(gpa, self.hop_cookies);
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
    /// A handler adopted the response; nothing left to free. Also what a
    /// streamed send returns: the body went to the sink chunk by chunk.
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

/// What the response head said, handed to a `Stream` sink before the
/// body is read so the caller can decide whether to stream it.
pub const HeadInfo = struct {
    status: u16,
    status_text: []const u8,
    headers: []const Header,
    /// `content-type: text/event-stream`.
    is_sse: bool,
    /// `transfer-encoding: chunked`, or no length at all (read to close).
    chunked: bool,
    /// The redirect hops' `Set-Cookie`s; the sink copies what it keeps.
    hop_cookies: []const HopCookie,
};

/// A progressive reader: the sink sees the head, decides (`onHead`
/// returns true to stream), gets every chunk as it lands, then the
/// timing. A streamed send returns `Outcome.moved` — the bytes went to
/// the sink, not into a `Response`.
pub const Stream = struct {
    ctx: *anyopaque,
    onHead: *const fn (ctx: *anyopaque, head: HeadInfo) bool,
    onBytes: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    onDone: *const fn (ctx: *anyopaque, end: StreamEnd) void,
};

pub const StreamEnd = struct { timing: Timing, bytes: usize, truncated: bool };

pub const SendOptions = struct {
    /// An extra `Cookie` header from the jar, unless the request has one.
    cookie: ?[]const u8 = null,
    stream: ?Stream = null,
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
        error.TooManyHttpRedirects, error.HttpRedirectLocationMissing, error.HttpRedirectLocationOversize, error.HttpRedirectLocationInvalid => "redirect: ",
        else => "",
    };
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, name });
}

const SendError = Allocator.Error || std.http.Client.RequestError || std.http.Client.Request.ReceiveHeadError || std.Uri.ParseError || std.Uri.ResolveInPlaceError || Io.Writer.Error || Io.Reader.StreamError || error{ InvalidMethod, UnsupportedCompressionMethod, WriteFailed };

fn isRedirect(status: u16) bool {
    return switch (status) {
        301, 302, 303, 307, 308 => true,
        else => false,
    };
}

/// A name=value pair per `Set-Cookie`, the attributes dropped — what the
/// next hop on the same host gets in its `Cookie` header.
fn cookiePair(set_cookie: []const u8) ?[]const u8 {
    const first = std.mem.trim(u8, std.mem.sliceTo(set_cookie, ';'), " \t");
    const eq = std.mem.indexOfScalar(u8, first, '=') orelse return null;
    if (std.mem.trim(u8, first[0..eq], " \t").len == 0) return null;
    return first;
}

fn nowMs(io: Io) i64 {
    return Io.Timestamp.now(io, .awake).toMilliseconds();
}

fn sendInner(gpa: Allocator, io: Io, req: *const Request, opts: SendOptions) SendError!Outcome {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var method_buf: [16]u8 = undefined;
    if (req.method.len > method_buf.len) return error.InvalidMethod;
    const upper = std.ascii.upperString(&method_buf, req.method);
    var method = std.meta.stringToEnum(std.http.Method, upper) orelse return error.InvalidMethod;

    // Every hop's URL text lives here until the send is over: the
    // resolved `Location`s, and the `std.Uri`s that point into them.
    var hops_arena = std.heap.ArenaAllocator.init(gpa);
    defer hops_arena.deinit();
    const ha = hops_arena.allocator();
    var url: []const u8 = try ha.dupe(u8, std.mem.trim(u8, req.url, " \t"));
    var uri = try std.Uri.parse(url);
    const origin_host = cookies_mod.hostOf(url) orelse "";
    var body: ?[]const u8 = req.body;
    // The jar's line for the origin, growing with what same-host hops
    // set; null once a hop lands on another host.
    var cookie_now: ?[]const u8 = opts.cookie;
    var hop_cookies: std.ArrayListUnmanaged(HopCookie) = .empty;
    defer hop_cookies.deinit(gpa);
    errdefer freeHopCookieEntries(gpa, hop_cookies.items);
    var hops: u8 = 0;
    var extra: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer extra.deinit(gpa);
    var length_buf: [24]u8 = undefined;

    const started = nowMs(io);
    while (true) {
        const hop_host = cookies_mod.hostOf(url) orelse "";
        const same_host = std.ascii.eqlIgnoreCase(hop_host, origin_host);

        // The std client owns six headers with default behaviour; a
        // request header of that name overrides it instead of
        // duplicating it. Off the origin host, `Host`, `Authorization`
        // and `Cookie` stay behind.
        var std_headers: std.http.Client.Request.Headers = .{};
        extra.clearRetainingCapacity();
        var has_cookie = false;
        for (req.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) {
                if (same_host) std_headers.host = .{ .override = h.value };
            } else if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                if (same_host) std_headers.authorization = .{ .override = h.value };
            } else if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                std_headers.user_agent = .{ .override = h.value };
            } else if (std.ascii.eqlIgnoreCase(h.name, "connection")) {
                std_headers.connection = .{ .override = h.value };
            } else if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) {
                std_headers.accept_encoding = .{ .override = h.value };
            } else if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                if (body != null) std_headers.content_type = .{ .override = h.value };
            } else {
                if (std.mem.indexOf(u8, h.value, "\r\n") != null or std.mem.indexOfScalar(u8, h.name, ':') != null or h.name.len == 0) continue;
                if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
                    has_cookie = true;
                    if (!same_host) continue;
                }
                if (std.ascii.eqlIgnoreCase(h.name, "content-length") or std.ascii.eqlIgnoreCase(h.name, "transfer-encoding")) continue;
                try extra.append(gpa, .{ .name = h.name, .value = h.value });
            }
        }
        if (!has_cookie) if (cookie_now) |c| try extra.append(gpa, .{ .name = "cookie", .value = c });
        if (std_headers.user_agent == .default) std_headers.user_agent = .{ .override = "mnml-zig" };
        const body_on_bodiless = body != null and !method.requestHasBody();
        if (body_on_bodiless) {
            // std will not frame it; the length goes out as a plain header.
            const len = std.fmt.bufPrint(&length_buf, "{d}", .{body.?.len}) catch unreachable;
            try extra.append(gpa, .{ .name = "content-length", .value = len });
        }

        var request = try client.request(method, uri, .{
            .headers = std_headers,
            .extra_headers = extra.items,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();

        if (body) |b| {
            if (method.requestHasBody()) {
                request.transfer_encoding = .{ .content_length = b.len };
                var bw = try request.sendBodyUnflushed(&.{});
                try bw.writer.writeAll(b);
                try bw.end();
                try request.connection.?.flush();
            } else {
                try request.sendBodilessUnflushed();
                try request.connection.?.writer().writeAll(b);
                try request.connection.?.flush();
            }
        } else if (method.requestHasBody()) {
            // A POST with nothing to send: a zero length, not std's
            // assert on `sendBodiless`.
            request.transfer_encoding = .{ .content_length = 0 };
            var bw = try request.sendBodyUnflushed(&.{});
            try bw.end();
            try request.connection.?.flush();
        } else {
            try request.sendBodiless();
        }

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        const head_at = nowMs(io);
        const status: u16 = @intFromEnum(response.head.status);

        if (isRedirect(status) and response.head.location != null) {
            if (hops >= max_redirects) return error.TooManyHttpRedirects;
            hops += 1;
            // This hop's cookies: onto the response for the jar, and
            // onto the next hop's `Cookie` line when it stays here.
            var pairs: std.ArrayListUnmanaged([]const u8) = .empty;
            if (cookie_now) |c| try pairs.append(ha, c);
            var it = response.head.iterateHeaders();
            while (it.next()) |h| {
                if (!std.ascii.eqlIgnoreCase(h.name, "set-cookie")) continue;
                const host = try gpa.dupe(u8, hop_host);
                errdefer gpa.free(host);
                const value = try gpa.dupe(u8, h.value);
                errdefer gpa.free(value);
                try hop_cookies.append(gpa, .{ .host = host, .value = value });
                if (cookiePair(h.value)) |pair| try pairs.append(ha, try ha.dupe(u8, pair));
            }
            // `Location`, relative to this hop.
            const location = response.head.location.?;
            const aux = try ha.alloc(u8, location.len + url.len + 64);
            @memcpy(aux[0..location.len], location);
            var aux_rest: []u8 = aux;
            uri = try uri.resolveInPlace(location.len, &aux_rest);
            url = try std.fmt.allocPrint(ha, "{f}", .{uri});
            const next_host = cookies_mod.hostOf(url) orelse "";
            cookie_now = if (std.ascii.eqlIgnoreCase(next_host, hop_host) and pairs.items.len > 0) try std.mem.join(ha, "; ", pairs.items) else if (std.ascii.eqlIgnoreCase(next_host, hop_host)) cookie_now else null;
            // RFC 9110 §15.4: 303 is always a GET; 301 / 302 turn a
            // POST into one, as every browser and curl do.
            if (status == 303 or ((status == 301 or status == 302) and method == .POST)) {
                method = .GET;
                body = null;
            }
            continue;
        }

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
        const is_sse = blk: {
            for (headers.items) |h| if (std.ascii.eqlIgnoreCase(h.name, "content-type") and std.ascii.indexOfIgnoreCase(h.value, "text/event-stream") != null) break :blk true;
            break :blk false;
        };
        const chunked = response.head.transfer_encoding == .chunked or (response.head.transfer_encoding == .none and response.head.content_length == null and response.head.status.class() == .success);

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

        if (opts.stream) |st| if (st.onHead(st.ctx, .{ .status = status, .status_text = status_text, .headers = headers.items, .is_sse = is_sse, .chunked = chunked, .hop_cookies = hop_cookies.items })) {
            // The sink took the head; every read is handed over as it
            // lands. `fillMore` is one underlying read, so an idle SSE
            // socket parks here — cancelation (a signal on Threaded)
            // is what ends it.
            var total: usize = 0;
            var truncated = false;
            while (true) {
                reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
                };
                const got = reader.buffered();
                if (got.len == 0) {
                    try io.checkCancel();
                    continue;
                }
                if (total < max_body) {
                    const keep = @min(got.len, max_body - total);
                    st.onBytes(st.ctx, got[0..keep]);
                    if (keep < got.len) truncated = true;
                } else truncated = true;
                total += got.len;
                reader.toss(got.len);
                try io.checkCancel();
            }
            const done_at = nowMs(io);
            // The head's strings were the sink's to copy; on the error paths
            // above the errdefers release them.
            gpa.free(status_text);
            gpa.free(final_url);
            for (headers.items) |h| {
                gpa.free(h.name);
                gpa.free(h.value);
            }
            headers.deinit(gpa);
            freeHopCookieEntries(gpa, hop_cookies.items);
            hop_cookies.items.len = 0;
            st.onDone(st.ctx, .{ .bytes = total, .truncated = truncated, .timing = .{
                .wait_ms = @intCast(@max(head_at - started, 0)),
                .receive_ms = @intCast(@max(done_at - head_at, 0)),
                .total_ms = @intCast(@max(done_at - started, 0)),
            } });
            return .moved;
        };

        var sink: Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        var truncated = false;
        _ = reader.streamRemaining(&sink.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            error.WriteFailed => return error.WriteFailed,
        };
        var body_bytes = sink.written();
        if (body_bytes.len > max_body) {
            body_bytes = body_bytes[0..max_body];
            truncated = true;
        }
        const resp_body = try gpa.dupe(u8, body_bytes);
        errdefer gpa.free(resp_body);
        const done_at = nowMs(io);
        const hop_list = try hop_cookies.toOwnedSlice(gpa);
        errdefer freeHopCookies(gpa, hop_list);

        return .{ .ok = .{
            .status = status,
            .status_text = status_text,
            .final_url = final_url,
            .headers = try headers.toOwnedSlice(gpa),
            .body = resp_body,
            .truncated = truncated,
            .timing = .{
                .wait_ms = @intCast(@max(head_at - started, 0)),
                .receive_ms = @intCast(@max(done_at - head_at, 0)),
                .total_ms = @intCast(@max(done_at - started, 0)),
            },
            .hop_cookies = hop_list,
        } };
    }
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

// ─── the streaming payload ──────────────────────────────────────────────

/// One `.sse` event: the head, a run of bytes, or the end of the
/// stream. Built on the gpa by the worker, owned by the event; the
/// handler adopts the head's strings and the bytes or destroys the box.
pub const StreamChunk = struct {
    job: u64,
    pane: ?u32,
    kind: union(enum) {
        head: struct {
            status: u16,
            status_text: []u8,
            headers: []Header,
            is_sse: bool,
            chunked: bool,
            hop_cookies: []HopCookie = &.{},
        },
        bytes: []u8,
        done: struct { timing: Timing, bytes: usize, truncated: bool },
        /// A transport error after the head (or a cancel).
        err: []u8,
    },

    pub fn create(gpa: Allocator, job: u64, pane: ?u32, kind: @FieldType(StreamChunk, "kind")) Allocator.Error!*StreamChunk {
        const c = try gpa.create(StreamChunk);
        c.* = .{ .job = job, .pane = pane, .kind = kind };
        return c;
    }

    pub fn destroy(self: *StreamChunk, gpa: Allocator) void {
        switch (self.kind) {
            .head => |h| {
                gpa.free(h.status_text);
                for (h.headers) |x| {
                    gpa.free(x.name);
                    gpa.free(x.value);
                }
                gpa.free(h.headers);
                freeHopCookies(gpa, h.hop_cookies);
            },
            .bytes, .err => |b| gpa.free(b),
            .done => {},
        }
        gpa.destroy(self);
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

test "send: a body on a bodyless method never reaches std's assert — it goes out with a length, as curl and reqwest send it" {
    // A GET whose parsed body is non-empty used to trip
    // `assert(r.method.requestHasBody())` and abort the process.
    const io = testing.io;
    var server = try mock.Server.start(testing.allocator, io, .{ .body = "ok" });
    defer server.stop(io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/get", .{server.port});
    defer testing.allocator.free(url);
    for ([_][]const u8{ "GET", "DELETE", "OPTIONS", "HEAD" }) |m| {
        var req = try Request.init(testing.allocator);
        defer req.deinit(testing.allocator);
        try req.setUrl(testing.allocator, url);
        try req.setMethod(testing.allocator, m);
        try req.setBody(testing.allocator, "{\"q\":1}");
        var outcome = try send(testing.allocator, io, &req, .{});
        defer outcome.deinit(testing.allocator);
        try testing.expect(outcome == .ok);
        const seen = server.lastRequest();
        try testing.expect(std.mem.startsWith(u8, seen, m));
        try testing.expect(std.ascii.indexOfIgnoreCase(seen, "content-length: 7\r\n") != null);
        try testing.expect(std.mem.endsWith(u8, seen, "\r\n\r\n{\"q\":1}"));
    }
    // The mirror: a POST with no body is `content-length: 0`, not an
    // assert on `sendBodiless`.
    var post = try Request.init(testing.allocator);
    defer post.deinit(testing.allocator);
    try post.setUrl(testing.allocator, url);
    try post.setMethod(testing.allocator, "POST");
    var o2 = try send(testing.allocator, io, &post, .{});
    defer o2.deinit(testing.allocator);
    try testing.expect(o2 == .ok);
    try testing.expect(std.ascii.indexOfIgnoreCase(server.lastRequest(), "content-length: 0\r\n") != null);
}

test "send: redirects are followed by hand, so a 302's Set-Cookie reaches the jar and the hop's cookie rides to the same host" {
    const io = testing.io;
    const final: mock.Canned = .{ .status = 200, .body = "{\"cookies\":{}}" };
    var server = try mock.Server.start(testing.allocator, io, .{
        .status = 302,
        .status_text = "Found",
        .headers = &.{ .{ .name = "set-cookie", .value = "session=abc123; Path=/" }, .{ .name = "set-cookie", .value = "user=chris" }, .{ .name = "location", .value = "/cookies" } },
        .body = "",
        .next = &final,
    });
    defer server.stop(io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/cookies/set?session=abc123", .{server.port});
    defer testing.allocator.free(url);
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, url);
    var outcome = try send(testing.allocator, io, &req, .{ .cookie = "seed=1" });
    defer outcome.deinit(testing.allocator);
    const resp = outcome.ok;
    try testing.expectEqual(@as(u16, 200), resp.status);
    try testing.expect(std.mem.endsWith(u8, resp.final_url, "/cookies"));
    try testing.expectEqual(@as(usize, 2), resp.hop_cookies.len);
    try testing.expectEqualStrings("127.0.0.1", resp.hop_cookies[0].host);
    try testing.expectEqualStrings("session=abc123; Path=/", resp.hop_cookies[0].value);
    // The second hop carried the jar's line plus what the first hop set.
    try testing.expect(std.ascii.indexOfIgnoreCase(server.lastRequest(), "cookie: seed=1; session=abc123; user=chris\r\n") != null);
    // Into the jar, keyed by the host that set them.
    var jar = @import("cookies.zig").Jar.init(testing.allocator);
    defer jar.deinit();
    for (resp.hop_cookies) |c| try jar.recordSetCookie(c.host, c.value);
    try testing.expectEqual(@as(usize, 2), jar.total());
    const line = (try jar.cookieHeaderFor(testing.allocator, "127.0.0.1")).?;
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("session=abc123; user=chris", line);
    var cloned = try resp.clone(testing.allocator);
    defer cloned.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), cloned.hop_cookies.len);
}

test "send: 303 and a 301/302 on POST rewrite to GET without the body; 307 keeps both; ten hops is the cap" {
    const io = testing.io;
    const final: mock.Canned = .{ .status = 201, .body = "made" };
    const cases = [_]struct { status: u16, method: []const u8, want_method: []const u8, want_body: bool }{
        .{ .status = 303, .method = "POST", .want_method = "GET", .want_body = false },
        .{ .status = 302, .method = "POST", .want_method = "GET", .want_body = false },
        .{ .status = 301, .method = "POST", .want_method = "GET", .want_body = false },
        .{ .status = 307, .method = "POST", .want_method = "POST", .want_body = true },
        .{ .status = 308, .method = "PUT", .want_method = "PUT", .want_body = true },
        .{ .status = 302, .method = "PUT", .want_method = "PUT", .want_body = true },
    };
    for (cases) |c| {
        var server = try mock.Server.start(testing.allocator, io, .{ .status = c.status, .status_text = "Moved", .headers = &.{.{ .name = "location", .value = "/there?x=1" }}, .next = &final });
        defer server.stop(io);
        const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/here", .{server.port});
        defer testing.allocator.free(url);
        var req = try Request.init(testing.allocator);
        defer req.deinit(testing.allocator);
        try req.setUrl(testing.allocator, url);
        try req.setMethod(testing.allocator, c.method);
        try req.addHeader(testing.allocator, "Content-Type", "text/plain");
        try req.setBody(testing.allocator, "payload");
        var outcome = try send(testing.allocator, io, &req, .{});
        defer outcome.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 201), outcome.ok.status);
        const seen = server.lastRequest();
        const line_end = std.mem.indexOf(u8, seen, "\r\n").?;
        const want_line = try std.fmt.allocPrint(testing.allocator, "{s} /there?x=1 HTTP/1.1", .{c.want_method});
        defer testing.allocator.free(want_line);
        try testing.expectEqualStrings(want_line, seen[0..line_end]);
        try testing.expectEqual(c.want_body, std.mem.endsWith(u8, seen, "\r\n\r\npayload"));
        try testing.expectEqual(c.want_body, std.ascii.indexOfIgnoreCase(seen, "content-type: text/plain") != null);
    }
    // A loop: every answer redirects to itself.
    var loop = try mock.Server.start(testing.allocator, io, .{ .status = 302, .status_text = "Found", .headers = &.{.{ .name = "location", .value = "/again" }} });
    defer loop.stop(io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/start", .{loop.port});
    defer testing.allocator.free(url);
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, url);
    var outcome = try send(testing.allocator, io, &req, .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome == .err);
    try testing.expect(std.mem.indexOf(u8, outcome.err, "redirect") != null);
    try testing.expectEqual(@as(u32, 11), loop.served.load(.monotonic));
}

test "send: a redirect to another host drops the jar's cookie and the Authorization header" {
    const io = testing.io;
    var target = try mock.Server.start(testing.allocator, io, .{ .body = "there" });
    defer target.stop(io);
    const location = try std.fmt.allocPrint(testing.allocator, "http://localhost:{d}/landed", .{target.port});
    defer testing.allocator.free(location);
    var server = try mock.Server.start(testing.allocator, io, .{ .status = 302, .status_text = "Found", .headers = &.{ .{ .name = "location", .value = location }, .{ .name = "set-cookie", .value = "first=1" } } });
    defer server.stop(io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/go", .{server.port});
    defer testing.allocator.free(url);
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, url);
    try req.addHeader(testing.allocator, "Authorization", "Bearer t");
    try req.addHeader(testing.allocator, "X-Keep", "yes");
    var outcome = try send(testing.allocator, io, &req, .{ .cookie = "seed=1" });
    defer outcome.deinit(testing.allocator);
    const resp = outcome.ok;
    try testing.expectEqualStrings("there", resp.body);
    try testing.expectEqual(@as(usize, 1), resp.hop_cookies.len);
    try testing.expectEqualStrings("127.0.0.1", resp.hop_cookies[0].host);
    const first = server.lastRequest();
    try testing.expect(std.ascii.indexOfIgnoreCase(first, "authorization: Bearer t\r\n") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(first, "cookie: seed=1\r\n") != null);
    const second = target.lastRequest();
    try testing.expect(std.mem.startsWith(u8, second, "GET /landed HTTP/1.1\r\n"));
    try testing.expect(std.ascii.indexOfIgnoreCase(second, "authorization:") == null);
    try testing.expect(std.ascii.indexOfIgnoreCase(second, "cookie:") == null);
    try testing.expect(std.ascii.indexOfIgnoreCase(second, "x-keep: yes\r\n") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(second, "host: localhost:") != null);
}

test "send: thirty malformed blocks parse and go out (or fail soft); none aborts" {
    const io = testing.io;
    var server = try mock.Server.start(testing.allocator, io, .{ .body = "ok" });
    defer server.stop(io);
    const base = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{server.port});
    defer testing.allocator.free(base);
    const shapes = [_][]const u8{
        "GET @BASE@/a\n\n# @assert status == 200\n",
        "GET @BASE@/a\n# @assert status == 200\nAccept: */*\n\nbody\n",
        "GET @BASE@/a\n\n# only\n# comments\n",
        "GET @BASE@/a\nContent-Length: 12\n",
        "GET @BASE@/a\nContent-Length: 3\n\nabc\n",
        "GET @BASE@/a\nContent-Length: 999\n\nab\n",
        "HEAD @BASE@/a\n\nignored body\n",
        "OPTIONS @BASE@/a\n\n# @set-header X = 1\n",
        "DELETE @BASE@/a\n\n{\"ids\":[1]}\n# @assert status == 200\n",
        "POST @BASE@/a\n\n### mid ### line\n",
        "POST @BASE@/a\n\n{\"a\": \"###\"}\n",
        "POST @BASE@/a\r\nA: 1\r\n\r\n\r\n\r\n",
        "POST @BASE@/a\r\n\r\n#\r\n# @\r\n#@assert\r\n",
        "POST @BASE@/a\n",
        "POST @BASE@/a\nContent-Type: application/json\n",
        "PUT @BASE@/a\n\n\n\n\n",
        "PATCH @BASE@/a HTTP/1.1\nA: b: c\n\n# @capture X = body\n",
        "PUT @BASE@/a\nA\n\n# @assert status == 200\n",
        "TRACE @BASE@/a\n\n#@assert status == 200\n",
        "GET @BASE@/a\n:\n\n# @assert status == 200\n",
        "GET @BASE@/a\n\n\t# @assert status == 200\n",
        "GET @BASE@/a\n\n  // @capture A = header x\n\n\n",
        "GET @BASE@/a\n\n#\n//\n#@\n//@\n",
        "GET @BASE@/a\n\n\x00\x01\x02\n# @assert status == 200\n",
        "GET @BASE@/a\n\n# @assert status == 200\nafter directive\n",
        "POST @BASE@/a\n\n{\n# @assert status == 200\n}\n",
        "GET @BASE@/a\nCookie: a=b\nHost: nowhere.invalid\n\nbody\n",
        "GET @BASE@/a\nTransfer-Encoding: chunked\n\nbody\n",
        "GET @BASE@/a\nX-Bad: a\r\nInjected: yes\n\n",
        "GET @BASE@/a?q=# @assert\n\n# @assert status == 200\n",
    };
    try testing.expectEqual(@as(usize, 30), shapes.len);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (shapes) |shape| {
        const text = try std.mem.replaceOwned(u8, arena.allocator(), shape, "@BASE@", base);
        var req = parse.parse(testing.allocator, text) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer req.deinit(testing.allocator);
        var outcome = try send(testing.allocator, io, &req, .{});
        defer outcome.deinit(testing.allocator);
        try testing.expect(outcome == .ok or outcome == .err);
    }
}
