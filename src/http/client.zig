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
//! Per-request transport (`Transport`): `insecure` (the `-k` shim in
//! `insecure.zig` — the std client has no switch, so an https hop goes
//! to a loopback TLS shim that skips the chain check), `timeout_ms` (a
//! deadline over the whole send, redirects included — the send races an
//! `Io.Select` timer and is cancelled when the timer wins),
//! `follow_redirects` / `max_redirects`, and `proxy` (`host:port` for
//! this send; an https origin is tunnelled with `CONNECT`). A request's
//! `# @…` directives override the defaults the caller passes.
//!
//! `JobResult` is the `.http` event payload: built here on the gpa,
//! owned by the event, adopted or destroyed by the handler.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const cookies_mod = @import("cookies.zig");
const insecure_mod = @import("insecure.zig");

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
    /// The hop's request path (the cookie's default `Path`).
    path: []u8,
};

/// Frees the entries, not the slice — for an `ArrayList`'s `items`.
fn freeHopCookieEntries(gpa: Allocator, list: []const HopCookie) void {
    for (list) |c| {
        gpa.free(c.host);
        gpa.free(c.value);
        gpa.free(c.path);
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
        errdefer gpa.free(out[filled].value);
        out[filled].path = try gpa.dupe(u8, c.path);
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

/// How a send goes out — the config's defaults, which a request's own
/// `# @…` directives override (`fromRequest`).
pub const Transport = struct {
    /// Skip the certificate chain check (`-k` / `# @insecure`).
    insecure: bool = false,
    /// The whole send, redirects included; null waits forever.
    timeout_ms: ?u64 = null,
    follow_redirects: bool = true,
    max_redirects: u8 = max_redirects,
    /// `host:port` (`user:pass@host:port`, `http://host:port`); borrowed.
    proxy: ?[]const u8 = null,

    /// `defaults` with the request's directives over it.
    pub fn fromRequest(req: *const Request, defaults: Transport) Transport {
        const o = parse.options(req);
        return .{
            .insecure = defaults.insecure or o.insecure,
            .timeout_ms = o.timeout_ms orelse defaults.timeout_ms,
            .follow_redirects = o.follow_redirects orelse defaults.follow_redirects,
            .max_redirects = o.max_redirects orelse defaults.max_redirects,
            .proxy = o.proxy orelse defaults.proxy,
        };
    }
};

pub const SendOptions = struct {
    /// An extra `Cookie` header from the jar, unless the request has one.
    cookie: ?[]const u8 = null,
    stream: ?Stream = null,
    /// The defaults; the request's directives win (`Transport.fromRequest`).
    transport: Transport = .{},
};

/// Fire `req` and wait for the whole response. Never throws for a
/// transport failure — that is the `.err` outcome. OOM is the one error.
pub fn send(gpa: Allocator, io: Io, req: *const Request, opts: SendOptions) Allocator.Error!Outcome {
    if (try urlRefusal(gpa, req.url)) |msg| return .{ .err = msg };
    const t = Transport.fromRequest(req, opts.transport);
    if (t.timeout_ms) |ms| if (ms > 0) return sendWithDeadline(gpa, io, req, opts, t, ms);
    return sendGuarded(gpa, io, req, opts, t);
}

/// A URL no server can be sent: a space or a control character would go
/// onto the request line as it is — a malformed request line (RFC 9112
/// §3). curl refuses such a URL ("URL rejected", exit 3), and so does
/// the send, naming the column and the fix rather than letting a server
/// answer 400. Owned; null for a URL that can go out.
pub fn urlRefusal(gpa: Allocator, raw: []const u8) Allocator.Error!?[]u8 {
    const url = std.mem.trim(u8, raw, " \t");
    for (url, 0..) |c, i| {
        if (c > ' ' and c != 0x7f) continue;
        const what: []const u8 = switch (c) {
            ' ' => "a space",
            '\t' => "a tab",
            '\r', '\n' => "a line break",
            else => "a control character",
        };
        const fix: []const u8 = if (c == ' ') " \u{2014} write it as %20" else "";
        return try std.fmt.allocPrint(gpa, "bad request: the URL has {s} at column {d}{s} ({s})", .{ what, i + 1, fix, url });
    }
    return null;
}

fn sendGuarded(gpa: Allocator, io: Io, req: *const Request, opts: SendOptions, t: Transport) Allocator.Error!Outcome {
    return sendInner(gpa, io, req, opts, t) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // A cancel becomes the `.err` outcome's text, so it is
            // re-armed for the caller: the runtime reports it once, and
            // dropped here the caller's next wait could not be
            // interrupted — its group's `cancel` waited that out.
            if (err == error.Canceled) io.recancel();
            return .{ .err = try describe(gpa, err, req.url) };
        },
    };
}

/// The send races a timer; the loser is cancelled. A cancelled send
/// drops its socket mid-read, which is what a timeout must do to a
/// server that never finishes. Without a spare unit of concurrency the
/// send runs inline, with no deadline.
fn sendWithDeadline(gpa: Allocator, io: Io, req: *const Request, opts: SendOptions, t: Transport, ms: u64) Allocator.Error!Outcome {
    const Result = union(enum) { send: Allocator.Error!Outcome, timer: void };
    var buf: [2]Result = undefined;
    var sel: Io.Select(Result) = .init(io, &buf);
    sel.concurrent(.send, sendGuarded, .{ gpa, io, req, opts, t }) catch return sendGuarded(gpa, io, req, opts, t);
    sel.async(.timer, sleepMs, .{ io, ms });
    const first = sel.await() catch {
        // We were cancelled ourselves: end both and report as a cancel,
        // re-armed for the caller as `sendGuarded` does.
        drainSelect(&sel, gpa);
        io.recancel();
        return .{ .err = try std.fmt.allocPrint(gpa, "canceled: {s}", .{req.url}) };
    };
    switch (first) {
        .send => |r| {
            drainSelect(&sel, gpa);
            return r;
        },
        .timer => {
            drainSelect(&sel, gpa);
            return .{ .err = try std.fmt.allocPrint(gpa, "timeout: no response within {d} ms ({s})", .{ ms, req.url }) };
        },
    }
}

fn drainSelect(sel: anytype, gpa: Allocator) void {
    while (sel.cancel()) |r| switch (r) {
        .send => |res| {
            var outcome = res catch continue;
            outcome.deinit(gpa);
        },
        .timer => {},
    };
}

fn sleepMs(io: Io, ms: u64) void {
    Io.sleep(io, .fromMilliseconds(@intCast(@min(ms, std.math.maxInt(i64) / 2))), .awake) catch {};
}

/// The words for a transport failure. A connect-class error (refused,
/// unreachable, a name that does not resolve) reads as reqwest's does
/// in Rust — `connection failed: error sending request for url (<url>)`
/// — with the cause after it; the URL is what the user looks for.
///
/// The resolver's error is not the same one on every platform: a name
/// that does not exist is `UnknownHostName` on macOS and
/// `NoAddressReturned` on glibc. Missing one of them cost the URL — a
/// Linux user saw a bare `NoAddressReturned` and no way to tell which
/// request it belonged to.
fn describe(gpa: Allocator, err: anyerror, url: []const u8) Allocator.Error![]u8 {
    const name = @errorName(err);
    switch (err) {
        error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.NetworkUnreachable, error.HostUnreachable, error.UnknownHostName, error.NameServerFailure, error.TemporaryNameServerFailure, error.HostLacksNetworkAddresses, error.NoAddressReturned, error.ResolvConfParseFailed, error.DetectingNetworkConfigurationFailed => return std.fmt.allocPrint(gpa, "connection failed: error sending request for url ({s}): {s}", .{ url, name }),
        // Zig 0.16's Windows connect has no mapping for
        // CONNECTION_REFUSED (a closed port) and answers `Unexpected`;
        // the name stays in the message, the kind is the one it is.
        error.Unexpected => if (@import("builtin").os.tag == .windows) return std.fmt.allocPrint(gpa, "connection failed: error sending request for url ({s}): {s}", .{ url, name }),
        else => {},
    }
    const prefix: []const u8 = switch (err) {
        error.TlsInitializationFailed, error.TlsFailure, error.CertificateBundleLoadFailure => "tls: ",
        error.UnsupportedUriScheme, error.UriMissingHost, error.InvalidFormat, error.InvalidPort, error.UnexpectedCharacter, error.InvalidMethod => "bad request: ",
        error.Canceled => "canceled: ",
        error.TooManyHttpRedirects, error.HttpRedirectLocationMissing, error.HttpRedirectLocationOversize, error.HttpRedirectLocationInvalid => "redirect: ",
        error.InvalidProxy, error.UnsupportedProxy, error.TunnelNotSupported => "proxy: ",
        else => "",
    };
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, name });
}

const SendError = Allocator.Error || std.http.Client.RequestError || std.http.Client.Request.ReceiveHeadError || std.Uri.ParseError || std.Uri.ResolveInPlaceError || std.Uri.GetHostError || Io.Writer.Error || Io.Reader.StreamError || insecure_mod.ProxyError || Io.net.HostName.ValidateError || error{ InvalidMethod, UnsupportedCompressionMethod, WriteFailed, TlsInitializationFailed };

/// Whether the request's socket read or write was cancelled. std's
/// readers answer a cancel with a bare `ReadFailed` (or `WriteFailed`)
/// and keep the cause on the connection's stream; surfaced as
/// `error.Canceled`, `sendGuarded` re-arms it for the caller.
fn socketCanceled(request: *const std.http.Client.Request) bool {
    const c = request.connection orelse return false;
    if (c.stream_reader.err) |e| if (e == error.Canceled) return true;
    if (c.stream_writer.err) |e| if (e == error.Canceled) return true;
    return false;
}

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

/// The `tls (insecure): …` line for a send the shim failed.
fn shimFailure(gpa: Allocator, shim: ?*insecure_mod.Shim) Allocator.Error!?Outcome {
    const s = shim orelse return null;
    const name = s.failure() orelse return null;
    return .{ .err = try std.fmt.allocPrint(gpa, "tls (insecure): {s}", .{name}) };
}

fn sendInner(gpa: Allocator, io: Io, req: *const Request, opts: SendOptions, t: Transport) SendError!Outcome {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    // The proxy for this send only: the client is ours for its life,
    // and `Proxy` borrows its strings for the client's.
    // Two `Proxy`s of one spec: a plain origin is asked for in absolute
    // form (`GET http://host/path`, what curl does), an https origin is
    // tunnelled with `CONNECT`.
    var proxy_storage: std.http.Client.Proxy = undefined;
    var tunnel_storage: std.http.Client.Proxy = undefined;
    var proxy_host: ?[]u8 = null;
    defer if (proxy_host) |h| gpa.free(h);
    var proxy_auth: ?[]u8 = null;
    defer if (proxy_auth) |a| gpa.free(a);
    if (t.proxy) |ptext| {
        var pa = std.heap.ArenaAllocator.init(gpa);
        defer pa.deinit();
        const p = try insecure_mod.parseProxy(pa.allocator(), ptext);
        proxy_host = try gpa.dupe(u8, p.host);
        if (p.authorization) |a| proxy_auth = try gpa.dupe(u8, a);
        proxy_storage = .{
            .protocol = if (p.tls) .tls else .plain,
            .host = try Io.net.HostName.init(proxy_host.?),
            .authorization = proxy_auth,
            .port = p.port,
            .supports_connect = false,
        };
        tunnel_storage = proxy_storage;
        tunnel_storage.supports_connect = true;
        client.http_proxy = &proxy_storage;
        client.https_proxy = &tunnel_storage;
    }
    // `-k`: an https hop goes through a loopback shim that skips the
    // chain check (`insecure.zig`); one shim per hop.
    var shim: ?*insecure_mod.Shim = null;
    defer if (shim) |s| s.stop();
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
        if (shim) |s| {
            s.stop();
            shim = null;
        }
        var hop_uri = uri;
        var shim_host: ?[]const u8 = null;
        if (t.insecure and std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
            var hbuf: [Io.net.HostName.max_len]u8 = undefined;
            const hn = try uri.getHost(&hbuf);
            const port: u16 = uri.port orelse 443;
            shim = insecure_mod.Shim.start(gpa, io, hn.bytes, port, t.proxy) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.TlsInitializationFailed,
            };
            hop_uri = .{ .scheme = "http", .host = .{ .raw = "127.0.0.1" }, .port = shim.?.port, .path = uri.path, .query = uri.query };
            shim_host = if (port == 443) try ha.dupe(u8, hn.bytes) else try std.fmt.allocPrint(ha, "{s}:{d}", .{ hn.bytes, port });
        }

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
        // Through the shim the wire says `127.0.0.1`; the origin must not.
        if (shim_host) |h| if (std_headers.host == .default) {
            std_headers.host = .{ .override = h };
        };
        const body_on_bodiless = body != null and !method.requestHasBody();
        if (body_on_bodiless) {
            // std will not frame it; the length goes out as a plain header.
            const len = std.fmt.bufPrint(&length_buf, "{d}", .{body.?.len}) catch unreachable;
            try extra.append(gpa, .{ .name = "content-length", .value = len });
        }

        var request = try client.request(method, hop_uri, .{
            .headers = std_headers,
            .extra_headers = extra.items,
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();

        const sent: SendError!void = blk: {
            if (body) |b| {
                if (method.requestHasBody()) {
                    request.transfer_encoding = .{ .content_length = b.len };
                    var bw = request.sendBodyUnflushed(&.{}) catch |e| break :blk e;
                    bw.writer.writeAll(b) catch |e| break :blk e;
                    bw.end() catch |e| break :blk e;
                    request.connection.?.flush() catch |e| break :blk e;
                } else {
                    request.sendBodilessUnflushed() catch |e| break :blk e;
                    request.connection.?.writer().writeAll(b) catch |e| break :blk e;
                    request.connection.?.flush() catch |e| break :blk e;
                }
            } else if (method.requestHasBody()) {
                // A POST with nothing to send: a zero length, not std's
                // assert on `sendBodiless`.
                request.transfer_encoding = .{ .content_length = 0 };
                var bw = request.sendBodyUnflushed(&.{}) catch |e| break :blk e;
                bw.end() catch |e| break :blk e;
                request.connection.?.flush() catch |e| break :blk e;
            } else {
                request.sendBodiless() catch |e| break :blk e;
            }
        };
        sent catch |err| {
            if (socketCanceled(&request)) return error.Canceled;
            if (try shimFailure(gpa, shim)) |o| return o;
            return err;
        };

        var redirect_buffer: [8 * 1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch |err| {
            if (socketCanceled(&request)) return error.Canceled;
            // The shim closed on us: its failure is the one to name.
            if (try shimFailure(gpa, shim)) |o| return o;
            return err;
        };
        const head_at = nowMs(io);
        const status: u16 = @intFromEnum(response.head.status);

        if (isRedirect(status) and response.head.location != null and t.follow_redirects) {
            if (hops >= t.max_redirects) return error.TooManyHttpRedirects;
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
                const path = try gpa.dupe(u8, cookies_mod.pathOf(url));
                errdefer gpa.free(path);
                try hop_cookies.append(gpa, .{ .host = host, .value = value, .path = path });
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
        // The hop's URL as resolved, not the wire's (a shim hop says
        // `127.0.0.1`).
        const final_url = try gpa.dupe(u8, url);
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
                // What the head's read already pulled in goes first: a
                // close-delimited body reads straight off the
                // connection, whose buffer can hold the first event
                // behind the head — reading more before handing that
                // over parks it until the server's NEXT write.
                if (reader.buffered().len == 0) reader.fillMore() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return response.bodyErr() orelse if (socketCanceled(response.request)) error.Canceled else error.ReadFailed,
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
            error.ReadFailed => return response.bodyErr() orelse if (socketCanceled(response.request)) error.Canceled else error.ReadFailed,
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
    for (resp.hop_cookies) |c| try jar.recordSetCookie(c.host, c.path, c.value, 0);
    try testing.expectEqual(@as(usize, 2), jar.total());
    const line = (try jar.cookieHeaderFor(testing.allocator, "127.0.0.1", "/cookies", false, 0)).?;
    defer testing.allocator.free(line);
    // `user` came with no Path from `/cookies/set`: its default path is
    // `/cookies` (RFC 6265 §5.1.4), so it rides first there — and not to `/`.
    try testing.expectEqualStrings("user=chris; session=abc123", line);
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

test "send: @timeout trips on a body that never finishes; the outcome names the timeout and the deadline" {
    const io = testing.io;
    var server = try mock.Server.start(testing.allocator, io, .{ .chunks = &.{"late"}, .chunk_delay_ms = 1500 });
    defer server.stop(io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/slow", .{server.port});
    defer testing.allocator.free(url);
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, url);
    try parse.setDirective(&req, testing.allocator, "@timeout", "300ms");
    try testing.expectEqual(@as(?u64, 300), Transport.fromRequest(&req, .{}).timeout_ms);
    const t0 = nowMs(io);
    var outcome = try send(testing.allocator, io, &req, .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome == .err);
    try testing.expect(std.mem.startsWith(u8, outcome.err, "timeout: no response within 300 ms"));
    try testing.expect(nowMs(io) - t0 < 1400);
    // The config's default applies when the block says nothing.
    var plain = try Request.init(testing.allocator);
    defer plain.deinit(testing.allocator);
    try plain.setUrl(testing.allocator, url);
    var o2 = try send(testing.allocator, io, &plain, .{ .transport = .{ .timeout_ms = 200 } });
    defer o2.deinit(testing.allocator);
    try testing.expect(o2 == .err and std.mem.startsWith(u8, o2.err, "timeout"));
}

test "send: @no-redirect hands back the 302 itself; @max-redirects caps the chain; the config default follows" {
    const io = testing.io;
    const final: mock.Canned = .{ .status = 200, .body = "landed" };
    var server = try mock.Server.start(testing.allocator, io, .{ .status = 302, .status_text = "Found", .headers = &.{.{ .name = "location", .value = "/there" }}, .next = &final });
    defer server.stop(io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/here", .{server.port});
    defer testing.allocator.free(url);
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, url);
    try parse.setDirective(&req, testing.allocator, "@no-redirect", "");
    var outcome = try send(testing.allocator, io, &req, .{});
    defer outcome.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 302), outcome.ok.status);
    try testing.expectEqualStrings("/there", outcome.ok.header("location").?);
    try testing.expectEqual(@as(u32, 1), server.served.load(.monotonic));
    // The same block without the directive, under a config that does not
    // follow (a fresh server: the mock's chain answers its final link
    // from the second request on).
    try parse.setDirective(&req, testing.allocator, "@no-redirect", null);
    var server2 = try mock.Server.start(testing.allocator, io, .{ .status = 302, .status_text = "Found", .headers = &.{.{ .name = "location", .value = "/there" }}, .next = &final });
    defer server2.stop(io);
    const url2 = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/here", .{server2.port});
    defer testing.allocator.free(url2);
    try req.setUrl(testing.allocator, url2);
    var o2 = try send(testing.allocator, io, &req, .{ .transport = .{ .follow_redirects = false } });
    defer o2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 302), o2.ok.status);
    // `@follow-redirects` overrides that config.
    try parse.setDirective(&req, testing.allocator, "@follow-redirects", "");
    var server3 = try mock.Server.start(testing.allocator, io, .{ .status = 302, .status_text = "Found", .headers = &.{.{ .name = "location", .value = "/there" }}, .next = &final });
    defer server3.stop(io);
    const url3 = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/here", .{server3.port});
    defer testing.allocator.free(url3);
    try req.setUrl(testing.allocator, url3);
    var o3 = try send(testing.allocator, io, &req, .{ .transport = .{ .follow_redirects = false } });
    defer o3.deinit(testing.allocator);
    try testing.expectEqualStrings("landed", o3.ok.body);
    // A loop capped at two hops: three requests served, then the error.
    var loop = try mock.Server.start(testing.allocator, io, .{ .status = 302, .status_text = "Found", .headers = &.{.{ .name = "location", .value = "/again" }} });
    defer loop.stop(io);
    const loop_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/start", .{loop.port});
    defer testing.allocator.free(loop_url);
    var capped = try Request.init(testing.allocator);
    defer capped.deinit(testing.allocator);
    try capped.setUrl(testing.allocator, loop_url);
    try parse.setDirective(&capped, testing.allocator, "@max-redirects", "2");
    var o4 = try send(testing.allocator, io, &capped, .{});
    defer o4.deinit(testing.allocator);
    try testing.expect(o4 == .err and std.mem.indexOf(u8, o4.err, "redirect") != null);
    try testing.expectEqual(@as(u32, 3), loop.served.load(.monotonic));
}

test "send: @proxy sends a plain origin's request to the proxy in absolute form, with the proxy's credentials" {
    const io = testing.io;
    var proxy = try mock.Server.start(testing.allocator, io, .{ .body = "via proxy" });
    defer proxy.stop(io);
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, "http://origin.invalid/path?q=1");
    const spec = try std.fmt.allocPrint(testing.allocator, "me:pw@127.0.0.1:{d}", .{proxy.port});
    defer testing.allocator.free(spec);
    try parse.setDirective(&req, testing.allocator, "@proxy", spec);
    var outcome = try send(testing.allocator, io, &req, .{});
    defer outcome.deinit(testing.allocator);
    try testing.expectEqualStrings("via proxy", outcome.ok.body);
    const seen = proxy.lastRequest();
    try testing.expect(std.mem.startsWith(u8, seen, "GET http://origin.invalid/path?q=1 HTTP/1.1\r\n"));
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "proxy-authorization: Basic bWU6cHc=\r\n") != null);
    try testing.expect(std.ascii.indexOfIgnoreCase(seen, "host: origin.invalid\r\n") != null);
    // A proxy spec that does not parse is a named failure, not a hang.
    var bad = try Request.init(testing.allocator);
    defer bad.deinit(testing.allocator);
    try bad.setUrl(testing.allocator, "http://origin.invalid/");
    try parse.setDirective(&bad, testing.allocator, "@proxy", "socks5://nope:1");
    var o2 = try send(testing.allocator, io, &bad, .{});
    defer o2.deinit(testing.allocator);
    try testing.expect(o2 == .err and std.mem.startsWith(u8, o2.err, "proxy: "));
}

test "send: -k routes an https hop through the shim (the origin sees a ClientHello, the failure is named); without it std's own TLS fails as before" {
    const io = testing.io;
    const origin = try insecure_mod.JunkOrigin.start(testing.allocator, io, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi");
    defer origin.stop();
    const url = try std.fmt.allocPrint(testing.allocator, "https://127.0.0.1:{d}/secure", .{origin.port});
    defer testing.allocator.free(url);
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, url);
    req.insecure = true;
    try testing.expect(Transport.fromRequest(&req, .{}).insecure);
    var outcome = try send(testing.allocator, io, &req, .{});
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome == .err);
    try testing.expect(std.mem.startsWith(u8, outcome.err, "tls (insecure): Tls"));
    try testing.expectEqual(@as(u32, 1), origin.served.load(.monotonic));
    const seen = origin.seen();
    try testing.expect(seen.len > 2 and seen[0] == 0x16 and seen[1] == 0x03);
    // The plain path: std's client, the bundle, the name — a different failure.
    req.insecure = false;
    var o2 = try send(testing.allocator, io, &req, .{});
    defer o2.deinit(testing.allocator);
    try testing.expect(o2 == .err);
    try testing.expect(std.mem.startsWith(u8, o2.err, "tls: "));
    try testing.expect(std.mem.indexOf(u8, o2.err, "insecure") == null);
    // The config default reaches the transport the same way.
    var o3 = try send(testing.allocator, io, &req, .{ .transport = .{ .insecure = true } });
    defer o3.deinit(testing.allocator);
    try testing.expect(o3 == .err and std.mem.startsWith(u8, o3.err, "tls (insecure): "));
}

test "urlRefusal: a space or a control character in the URL is refused with its column, as curl refuses it" {
    const msg = (try urlRefusal(testing.allocator, "http://h/search?q=new york")).?;
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("bad request: the URL has a space at column 22 \u{2014} write it as %20 (http://h/search?q=new york)", msg);
    const tab = (try urlRefusal(testing.allocator, "http://h/a\tb")).?;
    defer testing.allocator.free(tab);
    try testing.expect(std.mem.startsWith(u8, tab, "bad request: the URL has a tab at column 11"));
    // Encoded, or with the surrounding blanks a paste leaves: fine.
    try testing.expect((try urlRefusal(testing.allocator, "  http://h/search?q=new%20york  ")) == null);
    // The send says so instead of putting it on the wire.
    var req = try Request.init(testing.allocator);
    defer req.deinit(testing.allocator);
    try req.setUrl(testing.allocator, "http://127.0.0.1:9/search?q=new york");
    var out = try send(testing.allocator, testing.io, &req, .{});
    defer out.deinit(testing.allocator);
    try testing.expect(out == .err);
    try testing.expect(std.mem.startsWith(u8, out.err, "bad request: the URL has a space"));
}

test "send: a cancelled send keeps the cancel armed — the caller's next wait is interrupted too, so its group's cancel returns" {
    const io = testing.io;
    var server = try mock.Server.start(testing.allocator, io, .{ .chunks = &.{"late"}, .chunk_delay_ms = 1500 });
    defer server.stop(io);
    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/slow", .{server.port});
    defer testing.allocator.free(url);
    const Worker = struct {
        fn run(wio: Io, u: []const u8, saw: *std.atomic.Value(bool)) void {
            var req = Request.init(testing.allocator) catch return;
            defer req.deinit(testing.allocator);
            req.setUrl(testing.allocator, u) catch return;
            var outcome = send(testing.allocator, wio, &req, .{}) catch return;
            outcome.deinit(testing.allocator);
            // The caller's next cancelation point, as a marketplace
            // fetch's next source or an install's next step is.
            wio.sleep(.fromSeconds(20), .awake) catch {
                saw.store(true, .release);
                return;
            };
        }
    };
    var saw = std.atomic.Value(bool).init(false);
    var group: Io.Group = .init;
    try group.concurrent(io, Worker.run, .{ io, url, &saw });
    // The send is waiting on the body the server holds back.
    io.sleep(.fromMilliseconds(300), .awake) catch {};
    const t0 = nowMs(io);
    group.cancel(io);
    try testing.expect(nowMs(io) - t0 < 2000);
    try testing.expect(saw.load(.acquire));
}
