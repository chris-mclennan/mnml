//! `-k` / `# @insecure`: the TLS session that skips the checks.
//!
//! `std.http.Client` builds every TLS session with the system bundle
//! and the URL's host name and has no switch for either, so the seam is
//! the socket. A `Shim` listens on a loopback port for the one
//! connection a send makes, opens the real host itself (through the
//! proxy's `CONNECT` tunnel when there is one), runs the handshake with
//! `.ca = .no_verification` — the chain is never checked — and pumps
//! bytes both ways; the client speaks plain HTTP to the shim with the
//! real `Host` header, so everything else about the send (redirects,
//! cookies, streaming, the timeout) is unchanged.
//!
//! The name on the certificate is checked first, with SNI sent — what a
//! self-signed certificate for the right host needs, and what most
//! virtual hosts need to answer at all. A name that does not match
//! retries the handshake with no name check and no SNI, which is as far
//! as std's TLS client goes toward curl's `-k`. Whatever failed lands in
//! `failure`, named, so the send reads `tls (insecure): …` instead of a
//! closed connection.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;

/// `host:port`, `http://host:port`, `user:pass@host:port` — what
/// `# @proxy` / `-x` take. `https://` proxies are not tunnelled here.
pub const Proxy = struct {
    host: []const u8,
    port: u16,
    /// The `Proxy-Authorization` value, when the text carried a user.
    authorization: ?[]const u8,
    tls: bool,
};

pub const ProxyError = error{ InvalidProxy, UnsupportedProxy } || Allocator.Error;

/// The pieces of a proxy spec, on `a`.
pub fn parseProxy(a: Allocator, text: []const u8) ProxyError!Proxy {
    var s = std.mem.trim(u8, text, " \t");
    var secure = false;
    if (std.mem.indexOf(u8, s, "://")) |i| {
        const scheme = s[0..i];
        if (std.ascii.eqlIgnoreCase(scheme, "http")) {} else if (std.ascii.eqlIgnoreCase(scheme, "https")) {
            secure = true;
        } else return error.UnsupportedProxy;
        s = s[i + 3 ..];
    }
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| s = s[0..slash];
    var authorization: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, s, '@')) |at| {
        const enc = std.base64.standard.Encoder;
        const buf = try a.alloc(u8, enc.calcSize(at));
        authorization = try std.mem.concat(a, u8, &.{ "Basic ", enc.encode(buf, s[0..at]) });
        s = s[at + 1 ..];
    }
    if (s.len == 0) return error.InvalidProxy;
    var host = s;
    var port: u16 = 1080;
    if (s[0] == '[') {
        const close = std.mem.indexOfScalar(u8, s, ']') orelse return error.InvalidProxy;
        host = s[1..close];
        if (close + 1 < s.len) {
            if (s[close + 1] != ':') return error.InvalidProxy;
            port = std.fmt.parseInt(u16, s[close + 2 ..], 10) catch return error.InvalidProxy;
        }
    } else if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| {
        host = s[0..colon];
        port = std.fmt.parseInt(u16, s[colon + 1 ..], 10) catch return error.InvalidProxy;
    }
    if (host.len == 0) return error.InvalidProxy;
    return .{ .host = host, .port = port, .authorization = authorization, .tls = secure };
}

/// Open a TCP stream to `host:port` — an IP literal or a name.
pub fn connectStream(io: Io, host: []const u8, port: u16) !Io.net.Stream {
    if (Io.net.IpAddress.parse(host, port)) |addr| {
        return addr.connect(io, .{ .mode = .stream });
    } else |_| {}
    const hn = try Io.net.HostName.init(host);
    return hn.connect(io, port, .{ .mode = .stream });
}

const buf_len = tls.Client.min_buffer_len;

pub const Shim = struct {
    gpa: Allocator,
    io: Io,
    /// The loopback port the client connects to.
    port: u16,
    server: Io.net.Server,
    host: []u8,
    upstream_port: u16,
    proxy: ?[]u8,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    lock: Io.Mutex = .init,
    /// Under `lock`: the two sockets while they live, and the name of
    /// the connect / handshake error, if one happened.
    client_stream: ?Io.net.Stream = null,
    upstream: ?Io.net.Stream = null,
    failure_name: ?[]const u8 = null,
    /// How many handshakes were attempted (1, or 2 after a name retry).
    handshakes: std.atomic.Value(u8) = .init(0),

    /// Listen on a free loopback port and wait for the client.
    pub fn start(gpa: Allocator, io: Io, host: []const u8, port: u16, proxy: ?[]const u8) !*Shim {
        const self = try gpa.create(Shim);
        errdefer gpa.destroy(self);
        const host_copy = try gpa.dupe(u8, host);
        errdefer gpa.free(host_copy);
        const proxy_copy: ?[]u8 = if (proxy) |p| try gpa.dupe(u8, p) else null;
        errdefer if (proxy_copy) |p| gpa.free(p);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        self.* = .{ .gpa = gpa, .io = io, .port = server.socket.address.getPort(), .server = server, .host = host_copy, .upstream_port = port, .proxy = proxy_copy, .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    /// Stop, unblock whatever is waiting, join, free.
    pub fn stop(self: *Shim) void {
        const io = self.io;
        self.stopping.store(true, .release);
        {
            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);
            if (self.client_stream) |s| s.shutdown(io, .both) catch {};
            if (self.upstream) |s| s.shutdown(io, .both) catch {};
        }
        // A connection of our own unblocks `accept`.
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        self.thread.join();
        self.server.deinit(io);
        self.gpa.free(self.host);
        if (self.proxy) |p| self.gpa.free(p);
        self.gpa.destroy(self);
    }

    /// The error name of a failed connect / handshake, once one happened.
    pub fn failure(self: *Shim) ?[]const u8 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.failure_name;
    }

    fn setFailure(self: *Shim, name: []const u8) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.failure_name == null) self.failure_name = name;
    }

    fn setStream(self: *Shim, which: enum { client, upstream }, s: ?Io.net.Stream) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        switch (which) {
            .client => self.client_stream = s,
            .upstream => self.upstream = s,
        }
    }

    fn loop(self: *Shim) void {
        const io = self.io;
        const stream = self.server.accept(io) catch return;
        if (self.stopping.load(.acquire)) {
            stream.close(io);
            return;
        }
        self.setStream(.client, stream);
        self.serve(stream) catch |err| self.setFailure(@errorName(err));
        self.setStream(.client, null);
        stream.close(io);
    }

    const HostMode = enum { named, anonymous };

    /// Connect upstream (through the proxy when set) and shake hands.
    fn handshake(self: *Shim, mode: HostMode, rbuf: []u8, wbuf: []u8, tls_rbuf: []u8, tls_wbuf: []u8, plain_reader: *Io.net.Stream.Reader, plain_writer: *Io.net.Stream.Writer) !tls.Client {
        const io = self.io;
        const gpa = self.gpa;
        var stream: Io.net.Stream = undefined;
        if (self.proxy) |ptext| {
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const p = try parseProxy(scratch.allocator(), ptext);
            if (p.tls) return error.UnsupportedProxy;
            stream = try connectStream(io, p.host, p.port);
            errdefer stream.close(io);
            // The tunnel: a CONNECT and its 2xx, then bytes are the origin's.
            var w = Io.net.Stream.Writer.init(stream, io, wbuf);
            try w.interface.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ self.host, self.upstream_port, self.host, self.upstream_port });
            if (p.authorization) |auth| try w.interface.print("Proxy-Authorization: {s}\r\n", .{auth});
            try w.interface.writeAll("\r\n");
            try w.interface.flush();
            var r = Io.net.Stream.Reader.init(stream, io, rbuf);
            const status_line = try r.interface.takeDelimiterInclusive('\n');
            var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
            _ = parts.next();
            const code = std.fmt.parseInt(u16, parts.next() orelse "", 10) catch return error.ProxyConnectFailed;
            if (code < 200 or code > 299) return error.ProxyConnectRefused;
            while (true) {
                const line = try r.interface.takeDelimiterInclusive('\n');
                if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
            }
            // Anything the reader buffered past the head belongs to TLS;
            // the proxy has nothing to say before our ClientHello.
        } else {
            stream = try connectStream(io, self.host, self.upstream_port);
        }
        errdefer stream.close(io);
        self.setStream(.upstream, stream);
        plain_reader.* = Io.net.Stream.Reader.init(stream, io, rbuf);
        plain_writer.* = Io.net.Stream.Writer.init(stream, io, wbuf);
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        _ = self.handshakes.fetchAdd(1, .monotonic);
        return tls.Client.init(&plain_reader.interface, &plain_writer.interface, .{
            .host = switch (mode) {
                .named => .{ .explicit = self.host },
                .anonymous => .no_verification,
            },
            .ca = .no_verification,
            .write_buffer = tls_wbuf,
            .read_buffer = tls_rbuf,
            .entropy = &entropy,
            .realtime_now = Io.Timestamp.now(io, .real),
            .allow_truncation_attacks = true,
        }) catch |err| {
            self.setStream(.upstream, null);
            return err;
        };
    }

    fn serve(self: *Shim, client: Io.net.Stream) !void {
        const gpa = self.gpa;
        const io = self.io;
        const rbuf = try gpa.alloc(u8, buf_len);
        defer gpa.free(rbuf);
        const wbuf = try gpa.alloc(u8, buf_len);
        defer gpa.free(wbuf);
        const tls_rbuf = try gpa.alloc(u8, buf_len);
        defer gpa.free(tls_rbuf);
        const tls_wbuf = try gpa.alloc(u8, buf_len);
        defer gpa.free(tls_wbuf);
        var plain_reader: Io.net.Stream.Reader = undefined;
        var plain_writer: Io.net.Stream.Writer = undefined;
        var session = self.handshake(.named, rbuf, wbuf, tls_rbuf, tls_wbuf, &plain_reader, &plain_writer) catch |err| switch (err) {
            error.CertificateHostMismatch => try self.handshake(.anonymous, rbuf, wbuf, tls_rbuf, tls_wbuf, &plain_reader, &plain_writer),
            else => return err,
        };
        const upstream = plain_reader.stream;
        defer {
            self.setStream(.upstream, null);
            upstream.close(io);
        }
        // Down: the origin's bytes to the client, on its own thread;
        // up: the client's bytes to the origin, here.
        var cbuf: [buf_len]u8 = undefined;
        var client_writer = Io.net.Stream.Writer.init(client, io, &cbuf);
        const down = try std.Thread.spawn(.{}, pumpDown, .{ self, &session.reader, &client_writer, client });
        var client_rbuf: [buf_len]u8 = undefined;
        var client_reader = Io.net.Stream.Reader.init(client, io, &client_rbuf);
        pump(&client_reader.interface, &session.writer);
        // The client is done sending: close_notify upstream, then the
        // origin's EOF ends the other pump.
        session.end() catch {};
        upstream.shutdown(io, .send) catch {};
        down.join();
    }

    fn pumpDown(self: *Shim, src: *Io.Reader, dst: *Io.net.Stream.Writer, client: Io.net.Stream) void {
        pump(src, &dst.interface);
        client.shutdown(self.io, .send) catch {};
    }

    fn pump(src: *Io.Reader, dst: *Io.Writer) void {
        while (true) {
            src.fillMore() catch break;
            const got = src.buffered();
            if (got.len == 0) continue;
            dst.writeAll(got) catch break;
            dst.flush() catch break;
            src.toss(got.len);
        }
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const mock = @import("mock.zig");

test "parseProxy: host:port, a scheme, a user, an IPv6 literal, the 1080 default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p1 = try parseProxy(a, "proxy.local:3128");
    try testing.expectEqualStrings("proxy.local", p1.host);
    try testing.expectEqual(@as(u16, 3128), p1.port);
    try testing.expect(p1.authorization == null and !p1.tls);
    const p2 = try parseProxy(a, "http://me:pw@10.0.0.1:8080/");
    try testing.expectEqualStrings("10.0.0.1", p2.host);
    try testing.expectEqual(@as(u16, 8080), p2.port);
    try testing.expectEqualStrings("Basic bWU6cHc=", p2.authorization.?);
    const p3 = try parseProxy(a, "[::1]:9");
    try testing.expectEqualStrings("::1", p3.host);
    try testing.expectEqual(@as(u16, 9), p3.port);
    const p4 = try parseProxy(a, "bare.host");
    try testing.expectEqual(@as(u16, 1080), p4.port);
    try testing.expectError(error.UnsupportedProxy, parseProxy(a, "socks5://x:1"));
    try testing.expectError(error.InvalidProxy, parseProxy(a, "host:notaport"));
    try testing.expectError(error.InvalidProxy, parseProxy(a, ""));
}

/// A test origin: answers the first bytes of every connection with
/// `reply` and closes — what a TLS handshake against a plain server
/// meets. `seen` keeps the first bytes of the last connection.
pub const JunkOrigin = struct {
    gpa: Allocator,
    io: Io,
    port: u16,
    server: Io.net.Server,
    reply: []const u8,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    served: std.atomic.Value(u32) = .init(0),
    seen_lock: Io.Mutex = .init,
    seen_buf: [512]u8 = undefined,
    seen_len: usize = 0,

    pub fn start(gpa: Allocator, io: Io, reply: []const u8) !*JunkOrigin {
        const self = try gpa.create(JunkOrigin);
        errdefer gpa.destroy(self);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        self.* = .{ .gpa = gpa, .io = io, .port = server.socket.address.getPort(), .server = server, .reply = reply, .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    pub fn stop(self: *JunkOrigin) void {
        const io = self.io;
        self.stopping.store(true, .release);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
        if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        self.thread.join();
        self.server.deinit(io);
        self.gpa.destroy(self);
    }

    /// The first bytes the last connection sent. Borrowed.
    pub fn seen(self: *JunkOrigin) []const u8 {
        self.seen_lock.lockUncancelable(self.io);
        defer self.seen_lock.unlock(self.io);
        return self.seen_buf[0..self.seen_len];
    }

    fn loop(self: *JunkOrigin) void {
        const io = self.io;
        while (!self.stopping.load(.acquire)) {
            const stream = self.server.accept(io) catch break;
            defer stream.close(io);
            if (self.stopping.load(.acquire)) break;
            var rbuf: [1024]u8 = undefined;
            var reader = Io.net.Stream.Reader.init(stream, io, &rbuf);
            var got: [512]u8 = undefined;
            const n = reader.interface.readSliceShort(&got) catch 0;
            {
                self.seen_lock.lockUncancelable(io);
                defer self.seen_lock.unlock(io);
                @memcpy(self.seen_buf[0..n], got[0..n]);
                self.seen_len = n;
            }
            // The rest of the record, drained, and the close as a FIN:
            // a connection closed with unread bytes is reset on Windows,
            // the reply queued behind them is thrown away, and the
            // client's read fails with a status no name maps to
            // (CONNECTION_RESET → error.Unexpected) instead of the TLS
            // error the hop is expected to name. A ClientHello is one
            // record whose length is in its header.
            if (n >= 5 and got[0] == 0x16) {
                const total: usize = 5 + ((@as(usize, got[3]) << 8) | got[4]);
                var left = total -| n;
                var sink: [1024]u8 = undefined;
                while (left > 0) {
                    const k = reader.interface.readSliceShort(sink[0..@min(left, sink.len)]) catch 0;
                    if (k == 0) break;
                    left -= k;
                }
            }
            _ = self.served.fetchAdd(1, .monotonic);
            var wbuf: [1024]u8 = undefined;
            var writer = Io.net.Stream.Writer.init(stream, io, &wbuf);
            writer.interface.writeAll(self.reply) catch {};
            writer.interface.flush() catch {};
            stream.shutdown(io, .send) catch {};
        }
    }
};

test "shim: the client's connection reaches the origin as a TLS ClientHello; a plain origin's answer is a named handshake failure" {
    const io = testing.io;
    const origin = try JunkOrigin.start(testing.allocator, io, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nplain");
    defer origin.stop();
    const shim = try Shim.start(testing.allocator, io, "127.0.0.1", origin.port, null);
    defer shim.stop();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(shim.port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &wbuf);
    try writer.interface.writeAll("GET / HTTP/1.1\r\nhost: x\r\n\r\n");
    try writer.interface.flush();
    // The shim answers by closing once the handshake failed.
    var rbuf: [1024]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &rbuf);
    var sink: Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    _ = reader.interface.streamRemaining(&sink.writer) catch {};
    try testing.expectEqual(@as(u32, 1), origin.served.load(.monotonic));
    // The origin saw a TLS handshake record, not our HTTP line.
    const seen = origin.seen();
    try testing.expect(seen.len > 2 and seen[0] == 0x16 and seen[1] == 0x03);
    const name = shim.failure() orelse return error.TestExpectedFailure;
    try testing.expect(std.mem.startsWith(u8, name, "Tls"));
    try testing.expectEqual(@as(u8, 1), shim.handshakes.load(.monotonic));
}

test "shim: a proxy that refuses the CONNECT is named, and the tunnel request carried the origin" {
    const io = testing.io;
    var proxy = try mock.Server.start(testing.allocator, io, .{ .status = 403, .status_text = "Forbidden", .body = "" });
    defer proxy.stop(io);
    const ptext = try std.fmt.allocPrint(testing.allocator, "me:pw@127.0.0.1:{d}", .{proxy.port});
    defer testing.allocator.free(ptext);
    const shim = try Shim.start(testing.allocator, io, "origin.invalid", 443, ptext);
    defer shim.stop();
    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(shim.port) };
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var rbuf: [64]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &rbuf);
    var sink: Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    _ = reader.interface.streamRemaining(&sink.writer) catch {};
    try testing.expectEqualStrings("ProxyConnectRefused", shim.failure().?);
    const seen = proxy.lastRequest();
    try testing.expect(std.mem.startsWith(u8, seen, "CONNECT origin.invalid:443 HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, seen, "Proxy-Authorization: Basic bWU6cHc=\r\n") != null);
}
