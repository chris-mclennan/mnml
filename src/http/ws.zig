//! A WebSocket client, RFC 6455 by hand: the `ws://` / `wss://` URL,
//! the HTTP upgrade handshake (`Sec-WebSocket-Accept` checked), frames
//! in both directions (client frames masked, 7/16/64-bit lengths),
//! fragment reassembly, ping → pong, close → close. `wss` runs the same
//! frames through `std.crypto.tls.Client` over the same socket.
//!
//! `Conn` is heap-allocated: the TLS client keeps pointers into it.
//! One `readMessage` at a time; `send*` may be called from another
//! thread while a read blocks (the halves do not share buffers) —
//! `send_lock` serialises writers.
//!
//! The CDP session and the WebSocket pane both run on this; the
//! server-side handshake (`serverAccept`) hosts a fake endpoint for the
//! tests, and — with a required header (`serverAcceptChecked`) — the
//! agent face's listener (`api/ide_server.zig`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tls = std.crypto.tls;

pub const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(op: Opcode) bool {
        return @intFromEnum(op) >= 0x8;
    }
};

pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    /// Unmasked payload (borrowed from the decode buffer / the caller).
    payload: []const u8,
};

// ─── URL ────────────────────────────────────────────────────────────────

pub const Url = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    /// Path + query, never empty (`/` at least).
    path: []const u8,

    pub const ParseError = error{ BadScheme, NoHost, BadPort };

    pub fn parse(text_in: []const u8) ParseError!Url {
        const text = std.mem.trim(u8, text_in, " \t\r\n");
        var secure = false;
        var rest: []const u8 = undefined;
        if (std.ascii.startsWithIgnoreCase(text, "wss://")) {
            secure = true;
            rest = text["wss://".len..];
        } else if (std.ascii.startsWithIgnoreCase(text, "ws://")) {
            rest = text["ws://".len..];
        } else if (std.ascii.startsWithIgnoreCase(text, "https://")) {
            secure = true;
            rest = text["https://".len..];
        } else if (std.ascii.startsWithIgnoreCase(text, "http://")) {
            rest = text["http://".len..];
        } else return error.BadScheme;
        const slash = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        var hostport = rest[0..slash];
        if (std.mem.lastIndexOfScalar(u8, hostport, '@')) |at| hostport = hostport[at + 1 ..];
        var host = hostport;
        var port: u16 = if (secure) 443 else 80;
        if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| {
            if (std.mem.indexOfScalar(u8, hostport, ']') == null or colon > std.mem.indexOfScalar(u8, hostport, ']').?) {
                host = hostport[0..colon];
                port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return error.BadPort;
            }
        }
        host = std.mem.trim(u8, host, "[]");
        if (host.len == 0) return error.NoHost;
        const path = if (slash < rest.len and rest[slash] != '#') rest[slash..] else "/";
        return .{ .secure = secure, .host = host, .port = port, .path = if (path.len == 0) "/" else path };
    }
};

// ─── frames ─────────────────────────────────────────────────────────────

/// Encode one frame. Client frames are masked with `mask` (random per
/// frame); server frames pass `null`.
pub fn encodeFrame(alloc: Allocator, opcode: Opcode, payload: []const u8, fin: bool, mask: ?[4]u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, (@as(u8, if (fin) 0x80 else 0)) | @as(u8, @intFromEnum(opcode)));
    const mask_bit: u8 = if (mask != null) 0x80 else 0;
    if (payload.len < 126) {
        try out.append(alloc, mask_bit | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xFFFF) {
        try out.append(alloc, mask_bit | 126);
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @intCast(payload.len), .big);
        try out.appendSlice(alloc, &b);
    } else {
        try out.append(alloc, mask_bit | 127);
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, payload.len, .big);
        try out.appendSlice(alloc, &b);
    }
    if (mask) |m| {
        try out.appendSlice(alloc, &m);
        const start = out.items.len;
        try out.appendSlice(alloc, payload);
        for (out.items[start..], 0..) |*c, i| c.* ^= m[i % 4];
    } else try out.appendSlice(alloc, payload);
    return out.toOwnedSlice(alloc);
}

pub const Decoded = struct { frame: Frame, consumed: usize };

pub const DecodeError = error{ Incomplete, ReservedBits, TooLong };

/// Decode the frame at the start of `bytes`. The payload is unmasked in
/// place (so `bytes` must be mutable) and borrowed from it.
pub fn decodeFrame(bytes: []u8) DecodeError!Decoded {
    if (bytes.len < 2) return error.Incomplete;
    const b0 = bytes[0];
    const b1 = bytes[1];
    if (b0 & 0x70 != 0) return error.ReservedBits;
    const fin = b0 & 0x80 != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0)));
    const masked = b1 & 0x80 != 0;
    var len: u64 = b1 & 0x7F;
    var pos: usize = 2;
    if (len == 126) {
        if (bytes.len < 4) return error.Incomplete;
        len = std.mem.readInt(u16, bytes[2..4], .big);
        pos = 4;
    } else if (len == 127) {
        if (bytes.len < 10) return error.Incomplete;
        len = std.mem.readInt(u64, bytes[2..10], .big);
        pos = 10;
    }
    if (len > 64 * 1024 * 1024) return error.TooLong;
    var key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (bytes.len < pos + 4) return error.Incomplete;
        key = bytes[pos..][0..4].*;
        pos += 4;
    }
    const plen: usize = @intCast(len);
    if (bytes.len < pos + plen) return error.Incomplete;
    const payload = bytes[pos .. pos + plen];
    if (masked) for (payload, 0..) |*c, i| {
        c.* ^= key[i % 4];
    };
    return .{ .frame = .{ .fin = fin, .opcode = opcode, .payload = payload }, .consumed = pos + plen };
}

pub const Header = struct { fin: bool, opcode: Opcode, masked: bool, key: [4]u8, len: u64 };

/// A frame's header, read off `r`.
pub fn readHeader(r: *Io.Reader) !Header {
    var b: [2]u8 = undefined;
    try r.readSliceAll(&b);
    if (b[0] & 0x70 != 0) return error.ReservedBits;
    var len: u64 = b[1] & 0x7F;
    if (len == 126) {
        var e: [2]u8 = undefined;
        try r.readSliceAll(&e);
        len = std.mem.readInt(u16, &e, .big);
    } else if (len == 127) {
        var e: [8]u8 = undefined;
        try r.readSliceAll(&e);
        len = std.mem.readInt(u64, &e, .big);
    }
    const masked = b[1] & 0x80 != 0;
    var key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) try r.readSliceAll(&key);
    return .{ .fin = b[0] & 0x80 != 0, .opcode = @enumFromInt(@as(u4, @truncate(b[0]))), .masked = masked, .key = key, .len = len };
}

/// The payload `h` announces, into `buf`, unmasked.
fn readPayload(r: *Io.Reader, alloc: Allocator, buf: *std.ArrayListUnmanaged(u8), h: Header) !Frame {
    if (h.len > 64 * 1024 * 1024) return error.TooLong;
    buf.clearRetainingCapacity();
    try buf.resize(alloc, @intCast(h.len));
    try r.readSliceAll(buf.items);
    if (h.masked) for (buf.items, 0..) |*c, i| {
        c.* ^= h.key[i % 4];
    };
    return .{ .fin = h.fin, .opcode = h.opcode, .payload = buf.items };
}

/// Read exactly one frame from `r` into `buf` (grown as needed).
pub fn readFrame(r: *Io.Reader, alloc: Allocator, buf: *std.ArrayListUnmanaged(u8)) !Frame {
    buf.clearRetainingCapacity();
    try buf.resize(alloc, 2);
    try r.readSliceAll(buf.items[0..2]);
    const b1 = buf.items[1];
    var len: u64 = b1 & 0x7F;
    if (len == 126) {
        try buf.resize(alloc, 4);
        try r.readSliceAll(buf.items[2..4]);
        len = std.mem.readInt(u16, buf.items[2..4], .big);
    } else if (len == 127) {
        try buf.resize(alloc, 10);
        try r.readSliceAll(buf.items[2..10]);
        len = std.mem.readInt(u64, buf.items[2..10], .big);
    }
    if (len > 64 * 1024 * 1024) return error.TooLong;
    const masked = b1 & 0x80 != 0;
    const head = buf.items.len;
    const extra: usize = @as(usize, @intCast(len)) + @as(usize, if (masked) 4 else 0);
    try buf.resize(alloc, head + extra);
    try r.readSliceAll(buf.items[head..]);
    const d = try decodeFrame(buf.items);
    return d.frame;
}

// ─── handshake ──────────────────────────────────────────────────────────

/// `base64(sha1(key + GUID))`.
pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(guid);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

pub const HandshakeError = error{ BadStatus, BadAccept, HeadTooLong } || Allocator.Error || Io.Reader.Error || Io.Writer.Error || error{ ReadFailed, EndOfStream };

/// The response head lines (`Name: value`) after a handshake, on `alloc`.
pub const Head = struct {
    status: u16,
    headers: []const [2][]const u8,

    pub fn get(self: Head, name: []const u8) ?[]const u8 {
        for (self.headers) |h| if (std.ascii.eqlIgnoreCase(h[0], name)) return h[1];
        return null;
    }
};

fn readHead(r: *Io.Reader, alloc: Allocator) !Head {
    var lines: std.ArrayListUnmanaged([2][]const u8) = .empty;
    var status: u16 = 0;
    var first = true;
    var total: usize = 0;
    while (true) {
        const line_raw = try r.takeDelimiterInclusive('\n');
        total += line_raw.len;
        if (total > 64 * 1024) return error.HeadTooLong;
        const line = std.mem.trimEnd(u8, line_raw, "\r\n");
        if (line.len == 0) break;
        if (first) {
            first = false;
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            _ = parts.next();
            status = std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch 0;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        try lines.append(alloc, .{ try alloc.dupe(u8, std.mem.trim(u8, line[0..colon], " \t")), try alloc.dupe(u8, std.mem.trim(u8, line[colon + 1 ..], " \t")) });
    }
    return .{ .status = status, .headers = lines.items };
}

/// Server side: read the client's request head, answer 101. Returns
/// the requested path (on `alloc`) and the first subprotocol offered.
/// What the client asked for: its path and the first subprotocol offered.
pub const Accepted = struct { path: []const u8, protocol: ?[]const u8 };

pub fn serverAccept(r: *Io.Reader, w: *Io.Writer, alloc: Allocator) !Accepted {
    return serverAcceptChecked(r, w, alloc, null);
}

/// A request header the upgrade must carry, value compared in full
/// (every byte, whatever differs first).
pub const RequiredHeader = struct { name: []const u8, value: []const u8 };

/// `serverAccept`, refusing the upgrade with a 401 — and
/// `error.Unauthorized` — unless the request carries `required`.
pub fn serverAcceptChecked(r: *Io.Reader, w: *Io.Writer, alloc: Allocator, required: ?RequiredHeader) !Accepted {
    var path: []const u8 = "/";
    var key: ?[]const u8 = null;
    var protocol: ?[]const u8 = null;
    var presented: ?[]const u8 = null;
    var first = true;
    var total: usize = 0;
    while (true) {
        const line_raw = try r.takeDelimiterInclusive('\n');
        total += line_raw.len;
        if (total > 64 * 1024) return error.HeadTooLong;
        const line = std.mem.trimEnd(u8, line_raw, "\r\n");
        if (line.len == 0) break;
        if (first) {
            first = false;
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            _ = parts.next();
            path = try alloc.dupe(u8, parts.next() orelse "/");
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) key = try alloc.dupe(u8, value);
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-protocol")) protocol = try alloc.dupe(u8, std.mem.sliceTo(value, ','));
        if (required) |req| if (std.ascii.eqlIgnoreCase(name, req.name)) {
            presented = try alloc.dupe(u8, value);
        };
    }
    if (required) |req| if (!sameBytes(presented orelse "", req.value)) {
        try w.writeAll("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        try w.flush();
        return error.Unauthorized;
    };
    const k = key orelse return error.BadStatus;
    var accept_buf: [28]u8 = undefined;
    const accept = acceptKey(k, &accept_buf);
    try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n", .{accept});
    if (protocol) |p| try w.print("Sec-WebSocket-Protocol: {s}\r\n", .{p});
    try w.writeAll("\r\n");
    try w.flush();
    return .{ .path = path, .protocol = protocol };
}

fn sameBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ─── the connection ─────────────────────────────────────────────────────

pub const Message = union(enum) {
    text: []const u8,
    binary: []const u8,
    /// The peer closed; `code` 1005 when it sent none.
    close: struct { code: u16, reason: []const u8 },
    /// Ping arrived and a pong was sent; the payload is theirs.
    ping: []const u8,
    pong: []const u8,
    /// A message over `Conn.max_message`, skipped whole so the stream
    /// stays in step: `len` bytes of it arrived, `head` is its first
    /// `head_len` bytes (unmasked), enough to name what it was.
    too_long: struct { len: u64, head: []const u8 },
};

/// How much of an oversized message `Message.too_long` keeps.
pub const head_len = 256;

pub const ConnectOptions = struct {
    subprotocols: []const []const u8 = &.{},
    /// Extra request headers (`Origin`, `Authorization`…).
    headers: []const [2][]const u8 = &.{},
    /// Skip certificate checks on `wss` (self-signed dev servers).
    insecure: bool = false,
};

pub const Conn = struct {
    gpa: Allocator,
    io: Io,
    stream: Io.net.Stream,
    plain_reader: Io.net.Stream.Reader,
    plain_writer: Io.net.Stream.Writer,
    plain_rbuf: []u8,
    plain_wbuf: []u8,
    tls_client: ?tls.Client = null,
    tls_rbuf: []u8 = &.{},
    tls_wbuf: []u8 = &.{},
    bundle: std.crypto.Certificate.Bundle = .empty,
    bundle_lock: Io.RwLock = .init,
    /// The subprotocol the server picked, if any. Owned.
    protocol: ?[]u8 = null,
    send_lock: Io.Mutex = .init,
    frame_buf: std.ArrayListUnmanaged(u8) = .empty,
    /// A partial fragmented message.
    assembling: std.ArrayListUnmanaged(u8) = .empty,
    assembling_op: Opcode = .text,
    /// The last message's payload, valid until the next read.
    last: std.ArrayListUnmanaged(u8) = .empty,
    closed: bool = false,
    close_sent: bool = false,
    /// A text / binary message longer than this is skipped rather than
    /// buffered, and reported as `too_long`; the connection lives on.
    max_message: u64 = 64 * 1024 * 1024,
    /// Skipping the rest of a fragmented message that went over the cap:
    /// its bytes so far.
    skipping: ?u64 = null,

    /// Open a socket to `url`'s host, TLS when `wss`, and upgrade.
    pub fn connect(gpa: Allocator, io: Io, url_text: []const u8, opts: ConnectOptions) !*Conn {
        const url = try Url.parse(url_text);
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const stream = try connectStream(io, url.host, url.port);
        errdefer stream.close(io);
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        const rbuf = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(rbuf);
        const wbuf = try gpa.alloc(u8, tls.Client.min_buffer_len);
        errdefer gpa.free(wbuf);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .plain_reader = undefined,
            .plain_writer = undefined,
            .plain_rbuf = rbuf,
            .plain_wbuf = wbuf,
        };
        self.plain_reader = Io.net.Stream.Reader.init(stream, io, rbuf);
        self.plain_writer = Io.net.Stream.Writer.init(stream, io, wbuf);
        if (url.secure) {
            self.tls_rbuf = try gpa.alloc(u8, tls.Client.min_buffer_len);
            errdefer gpa.free(self.tls_rbuf);
            self.tls_wbuf = try gpa.alloc(u8, tls.Client.min_buffer_len);
        }
        errdefer if (self.tls_rbuf.len > 0) gpa.free(self.tls_rbuf);
        errdefer if (self.tls_wbuf.len > 0) gpa.free(self.tls_wbuf);
        if (url.secure) {
            const now = Io.Timestamp.now(io, .real);
            if (!opts.insecure) self.bundle.rescan(gpa, io, now) catch return error.CertificateBundleLoadFailure;
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            self.tls_client = try tls.Client.init(&self.plain_reader.interface, &self.plain_writer.interface, .{
                .host = if (opts.insecure) .no_verification else .{ .explicit = url.host },
                .ca = if (opts.insecure) .no_verification else .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &self.bundle_lock, .bundle = &self.bundle } },
                .write_buffer = self.tls_wbuf,
                .read_buffer = self.tls_rbuf,
                .entropy = &entropy,
                .realtime_now = now,
                .allow_truncation_attacks = true,
            });
        }
        errdefer self.bundle.deinit(gpa);
        // The upgrade.
        var key_raw: [16]u8 = undefined;
        io.random(&key_raw);
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &key_raw);
        const w = self.writer();
        try w.print("GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n", .{ url.path, url.host, url.port, key });
        if (opts.subprotocols.len > 0) {
            try w.writeAll("Sec-WebSocket-Protocol: ");
            for (opts.subprotocols, 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(p);
            }
            try w.writeAll("\r\n");
        }
        for (opts.headers) |h| try w.print("{s}: {s}\r\n", .{ h[0], h[1] });
        try w.writeAll("\r\n");
        try self.flush();
        const head = try readHead(self.reader(), a);
        if (head.status != 101) return error.BadStatus;
        var accept_buf: [28]u8 = undefined;
        const want = acceptKey(key, &accept_buf);
        const got = head.get("sec-websocket-accept") orelse return error.BadAccept;
        if (!std.mem.eql(u8, got, want)) return error.BadAccept;
        if (head.get("sec-websocket-protocol")) |p| self.protocol = try gpa.dupe(u8, p);
        return self;
    }

    fn connectStream(io: Io, host: []const u8, port: u16) !Io.net.Stream {
        if (Io.net.IpAddress.parse(host, port)) |addr| {
            return addr.connect(io, .{ .mode = .stream });
        } else |_| {}
        const hn = try Io.net.HostName.init(host);
        return hn.connect(io, port, .{ .mode = .stream });
    }

    pub fn reader(self: *Conn) *Io.Reader {
        if (self.tls_client) |*c| return &c.reader;
        return &self.plain_reader.interface;
    }

    pub fn writer(self: *Conn) *Io.Writer {
        if (self.tls_client) |*c| return &c.writer;
        return &self.plain_writer.interface;
    }

    /// The TLS writer encrypts into the socket writer; both need flushing.
    pub fn flush(self: *Conn) !void {
        if (self.tls_client) |*c| try c.writer.flush();
        try self.plain_writer.interface.flush();
    }

    pub fn deinit(self: *Conn) void {
        const gpa = self.gpa;
        self.stream.close(self.io);
        self.bundle.deinit(gpa);
        if (self.tls_rbuf.len > 0) gpa.free(self.tls_rbuf);
        if (self.tls_wbuf.len > 0) gpa.free(self.tls_wbuf);
        gpa.free(self.plain_rbuf);
        gpa.free(self.plain_wbuf);
        if (self.protocol) |p| gpa.free(p);
        self.frame_buf.deinit(gpa);
        self.assembling.deinit(gpa);
        self.last.deinit(gpa);
        gpa.destroy(self);
    }

    fn sendFrame(self: *Conn, opcode: Opcode, payload: []const u8) !void {
        self.send_lock.lockUncancelable(self.io);
        defer self.send_lock.unlock(self.io);
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        const frame = try encodeFrame(self.gpa, opcode, payload, true, mask);
        defer self.gpa.free(frame);
        const w = self.writer();
        try w.writeAll(frame);
        try self.flush();
    }

    pub fn sendText(self: *Conn, text: []const u8) !void {
        return self.sendFrame(.text, text);
    }

    pub fn sendBinary(self: *Conn, bytes: []const u8) !void {
        return self.sendFrame(.binary, bytes);
    }

    pub fn ping(self: *Conn, payload: []const u8) !void {
        return self.sendFrame(.ping, payload);
    }

    /// Send a close frame (once). The peer's close comes back through
    /// `readMessage`.
    pub fn close(self: *Conn, code: u16, reason: []const u8) !void {
        if (self.close_sent) return;
        self.close_sent = true;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.gpa);
        var c: [2]u8 = undefined;
        std.mem.writeInt(u16, &c, code, .big);
        try buf.appendSlice(self.gpa, &c);
        try buf.appendSlice(self.gpa, reason);
        try self.sendFrame(.close, buf.items);
    }

    /// Block until a whole message arrives. Control frames are handled
    /// here (pong sent for a ping, close echoed) and also reported.
    /// Null once the connection is closed.
    pub fn readMessage(self: *Conn) !?Message {
        const gpa = self.gpa;
        while (true) {
            if (self.closed) return null;
            const head = readHeader(self.reader()) catch |err| switch (err) {
                error.EndOfStream => {
                    self.closed = true;
                    return null;
                },
                else => return err,
            };
            const data = head.opcode == .text or head.opcode == .binary or head.opcode == .continuation;
            if (head.opcode == .text or head.opcode == .binary) self.skipping = null;
            const so_far: u64 = if (head.opcode == .continuation) (self.skipping orelse self.assembling.items.len) else 0;
            if (data and (self.skipping != null and head.opcode == .continuation or so_far + head.len > self.max_message)) {
                if (head.opcode != .continuation) self.assembling_op = head.opcode;
                const total = so_far + head.len;
                if (self.skipping == null) {
                    // The first bytes of the message: what is already
                    // assembled, then this frame's.
                    self.last.clearRetainingCapacity();
                    const keep_old = @min(self.assembling.items.len, head_len);
                    try self.last.appendSlice(gpa, self.assembling.items[0..keep_old]);
                    self.assembling.clearRetainingCapacity();
                    const want: usize = @intCast(@min(head.len, head_len - keep_old));
                    const at = self.last.items.len;
                    try self.last.resize(gpa, at + want);
                    try self.reader().readSliceAll(self.last.items[at..]);
                    if (head.masked) for (self.last.items[at..], 0..) |*c, i| {
                        c.* ^= head.key[i % 4];
                    };
                    try self.reader().discardAll64(head.len - want);
                } else try self.reader().discardAll64(head.len);
                if (!head.fin) {
                    self.skipping = total;
                    continue;
                }
                self.skipping = null;
                return .{ .too_long = .{ .len = total, .head = self.last.items } };
            }
            const frame = try readPayload(self.reader(), gpa, &self.frame_buf, head);
            switch (frame.opcode) {
                .ping => {
                    self.sendFrame(.pong, frame.payload) catch {};
                    self.last.clearRetainingCapacity();
                    try self.last.appendSlice(gpa, frame.payload);
                    return .{ .ping = self.last.items };
                },
                .pong => {
                    self.last.clearRetainingCapacity();
                    try self.last.appendSlice(gpa, frame.payload);
                    return .{ .pong = self.last.items };
                },
                .close => {
                    const code: u16 = if (frame.payload.len >= 2) std.mem.readInt(u16, frame.payload[0..2], .big) else 1005;
                    self.last.clearRetainingCapacity();
                    try self.last.appendSlice(gpa, if (frame.payload.len > 2) frame.payload[2..] else "");
                    if (!self.close_sent) self.close(code, "") catch {};
                    self.closed = true;
                    return .{ .close = .{ .code = code, .reason = self.last.items } };
                },
                .text, .binary => {
                    self.assembling.clearRetainingCapacity();
                    self.assembling_op = frame.opcode;
                    try self.assembling.appendSlice(gpa, frame.payload);
                    if (!frame.fin) continue;
                },
                .continuation => {
                    try self.assembling.appendSlice(gpa, frame.payload);
                    if (!frame.fin) continue;
                },
                _ => continue,
            }
            self.last.clearRetainingCapacity();
            try self.last.appendSlice(gpa, self.assembling.items);
            self.assembling.clearRetainingCapacity();
            return if (self.assembling_op == .text) .{ .text = self.last.items } else .{ .binary = self.last.items };
        }
    }
};

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "url: ws / wss / ports / paths" {
    const a = try Url.parse("ws://echo.example:8080/chat?x=1");
    try testing.expect(!a.secure);
    try testing.expectEqualStrings("echo.example", a.host);
    try testing.expectEqual(@as(u16, 8080), a.port);
    try testing.expectEqualStrings("/chat?x=1", a.path);
    const b = try Url.parse("wss://api.example.com");
    try testing.expect(b.secure);
    try testing.expectEqual(@as(u16, 443), b.port);
    try testing.expectEqualStrings("/", b.path);
    const c = try Url.parse("ws://127.0.0.1:9222/devtools/page/ABC");
    try testing.expectEqualStrings("127.0.0.1", c.host);
    try testing.expectError(error.BadScheme, Url.parse("ftp://x"));
    try testing.expectError(error.BadPort, Url.parse("ws://x:abc/"));
}

test "frames: encode/decode both directions, lengths 7/16/64, masking, control" {
    const gpa = testing.allocator;
    const mask: [4]u8 = .{ 0x37, 0xfa, 0x21, 0x3d };
    // RFC 6455 §5.7: a masked "Hello".
    const hello = try encodeFrame(gpa, .text, "Hello", true, mask);
    defer gpa.free(hello);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, hello);
    const buf = try gpa.dupe(u8, hello);
    defer gpa.free(buf);
    const d = try decodeFrame(buf);
    try testing.expect(d.frame.fin and d.frame.opcode == .text);
    try testing.expectEqualStrings("Hello", d.frame.payload);
    try testing.expectEqual(hello.len, d.consumed);
    // An unmasked server frame, 16-bit length.
    const mid = try gpa.alloc(u8, 300);
    defer gpa.free(mid);
    @memset(mid, 'x');
    const frame16 = try encodeFrame(gpa, .binary, mid, true, null);
    defer gpa.free(frame16);
    try testing.expectEqual(@as(u8, 126), frame16[1]);
    try testing.expectEqual(@as(usize, 304), frame16.len);
    const d16 = try decodeFrame(frame16);
    try testing.expectEqual(@as(usize, 300), d16.frame.payload.len);
    // 64-bit length.
    const big = try gpa.alloc(u8, 70_000);
    defer gpa.free(big);
    @memset(big, 'y');
    const f64_ = try encodeFrame(gpa, .binary, big, false, mask);
    defer gpa.free(f64_);
    try testing.expectEqual(@as(u8, 0x02), f64_[0]);
    try testing.expectEqual(@as(u8, 0x80 | 127), f64_[1]);
    const d64 = try decodeFrame(f64_);
    try testing.expect(!d64.frame.fin);
    try testing.expectEqual(@as(usize, 70_000), d64.frame.payload.len);
    try testing.expectEqual(@as(u8, 'y'), d64.frame.payload[69_999]);
    try testing.expectError(error.Incomplete, decodeFrame(buf[0..3]));
    var bad = [_]u8{ 0xC1, 0x00 };
    try testing.expectError(error.ReservedBits, decodeFrame(&bad));
    try testing.expect(Opcode.ping.isControl() and !Opcode.text.isControl());
}

test "acceptKey matches the RFC example" {
    var out: [28]u8 = undefined;
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out));
}

/// A local echo server for the tests: one connection, handshake, then
/// echoes text (fragmented when asked), pongs pings, echoes close.
pub const EchoServer = struct {
    gpa: Allocator,
    io: Io,
    server: Io.net.Server,
    port: u16,
    thread: std.Thread,
    protocol_seen: std.ArrayListUnmanaged(u8) = .empty,
    /// Every text the server received, joined by `\n`.
    received: std.ArrayListUnmanaged(u8) = .empty,
    lock: Io.Mutex = .init,

    pub fn start(gpa: Allocator, io: Io) !*EchoServer {
        const self = try gpa.create(EchoServer);
        errdefer gpa.destroy(self);
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);
        self.* = .{ .gpa = gpa, .io = io, .server = server, .port = server.socket.address.getPort(), .thread = undefined };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    pub fn stop(self: *EchoServer) void {
        self.thread.join();
        self.server.deinit(self.io);
        self.protocol_seen.deinit(self.gpa);
        self.received.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn loop(self: *EchoServer) void {
        const stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        self.serve(stream) catch {};
    }

    fn serve(self: *EchoServer, stream: Io.net.Stream) !void {
        const gpa = self.gpa;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, self.io, &rbuf);
        var writer = Io.net.Stream.Writer.init(stream, self.io, &wbuf);
        const r = &reader.interface;
        const w = &writer.interface;
        const hs = try serverAccept(r, w, arena.allocator());
        if (hs.protocol) |p| try self.protocol_seen.appendSlice(gpa, p);
        var fbuf: std.ArrayListUnmanaged(u8) = .empty;
        defer fbuf.deinit(gpa);
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(gpa);
        while (true) {
            const frame = try readFrame(r, gpa, &fbuf);
            switch (frame.opcode) {
                .text, .continuation => {
                    try msg.appendSlice(gpa, frame.payload);
                    if (!frame.fin) continue;
                    {
                        self.lock.lockUncancelable(self.io);
                        defer self.lock.unlock(self.io);
                        if (self.received.items.len > 0) try self.received.append(gpa, '\n');
                        try self.received.appendSlice(gpa, msg.items);
                    }
                    // "close:<code> <reason>" is answered with a Close
                    // frame carrying them, and the connection ends.
                    if (std.mem.startsWith(u8, msg.items, "close:")) {
                        const spec = msg.items["close:".len..];
                        const sp = std.mem.indexOfScalar(u8, spec, ' ') orelse spec.len;
                        const code = std.fmt.parseInt(u16, spec[0..sp], 10) catch 1000;
                        var payload: std.ArrayListUnmanaged(u8) = .empty;
                        defer payload.deinit(gpa);
                        var cb: [2]u8 = undefined;
                        std.mem.writeInt(u16, &cb, code, .big);
                        try payload.appendSlice(gpa, &cb);
                        if (sp < spec.len) try payload.appendSlice(gpa, spec[sp + 1 ..]);
                        const f = try encodeFrame(gpa, .close, payload.items, true, null);
                        defer gpa.free(f);
                        try w.writeAll(f);
                        try w.flush();
                        return;
                    }
                    // "split:<text>" comes back as two fragments.
                    if (std.mem.startsWith(u8, msg.items, "split:")) {
                        const body = msg.items["split:".len..];
                        const half = body.len / 2;
                        const f1 = try encodeFrame(gpa, .text, body[0..half], false, null);
                        defer gpa.free(f1);
                        const f2 = try encodeFrame(gpa, .continuation, body[half..], true, null);
                        defer gpa.free(f2);
                        try w.writeAll(f1);
                        try w.writeAll(f2);
                    } else {
                        const f = try encodeFrame(gpa, .text, msg.items, true, null);
                        defer gpa.free(f);
                        try w.writeAll(f);
                    }
                    try w.flush();
                    msg.clearRetainingCapacity();
                },
                .binary => {
                    const f = try encodeFrame(gpa, .binary, frame.payload, true, null);
                    defer gpa.free(f);
                    try w.writeAll(f);
                    try w.flush();
                },
                .ping => {
                    const f = try encodeFrame(gpa, .pong, frame.payload, true, null);
                    defer gpa.free(f);
                    try w.writeAll(f);
                    try w.flush();
                },
                .close => {
                    const f = try encodeFrame(gpa, .close, frame.payload, true, null);
                    defer gpa.free(f);
                    try w.writeAll(f);
                    try w.flush();
                    return;
                },
                else => {},
            }
        }
    }
};

test "a client round trip over a local socket: handshake, echo, fragments, ping/pong, close" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try EchoServer.start(gpa, io);
    defer server.stop();
    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/chat", .{server.port});
    defer gpa.free(url);
    const conn = try Conn.connect(gpa, io, url, .{ .subprotocols = &.{ "json", "text" } });
    defer conn.deinit();
    try testing.expectEqualStrings("json", conn.protocol.?);
    try conn.sendText("hello there");
    const m1 = (try conn.readMessage()).?;
    try testing.expectEqualStrings("hello there", m1.text);
    try conn.sendText("split:abcdefgh");
    const m2 = (try conn.readMessage()).?;
    try testing.expectEqualStrings("abcdefgh", m2.text);
    try conn.ping("k");
    const m3 = (try conn.readMessage()).?;
    try testing.expectEqualStrings("k", m3.pong);
    const big = try gpa.alloc(u8, 70_000);
    defer gpa.free(big);
    @memset(big, 'z');
    try conn.sendBinary(big);
    const m4 = (try conn.readMessage()).?;
    try testing.expectEqual(@as(usize, 70_000), m4.binary.len);
    try conn.close(1000, "bye");
    const m5 = (try conn.readMessage()).?;
    try testing.expectEqual(@as(u16, 1000), m5.close.code);
    try testing.expect((try conn.readMessage()) == null);
    try testing.expectEqualStrings("hello there\nsplit:abcdefgh", server.received.items);
}

test "a message over the cap is skipped whole and reported, and the connection reads on" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try EchoServer.start(gpa, io);
    defer server.stop();
    const url = try std.fmt.allocPrint(gpa, "ws://127.0.0.1:{d}/", .{server.port});
    defer gpa.free(url);
    const conn = try Conn.connect(gpa, io, url, .{});
    defer conn.deinit();
    conn.max_message = 1000;
    // One frame over the cap: its head and its length, no error.
    const big = try gpa.alloc(u8, 5000);
    defer gpa.free(big);
    @memset(big, 'z');
    @memcpy(big[0..10], "{\"id\":107,");
    try conn.sendText(big);
    const m1 = (try conn.readMessage()).?;
    try testing.expectEqual(@as(u64, 5000), m1.too_long.len);
    try testing.expectEqual(@as(usize, head_len), m1.too_long.head.len);
    try testing.expectEqualStrings("{\"id\":107,", m1.too_long.head[0..10]);
    // The stream is still in step.
    try conn.sendText("after");
    try testing.expectEqualStrings("after", (try conn.readMessage()).?.text);
    // A fragmented message that crosses the cap in its second fragment:
    // skipped as one message, the head from the first.
    const split = try gpa.alloc(u8, "split:".len + 1800);
    defer gpa.free(split);
    @memcpy(split[0.."split:".len], "split:");
    @memset(split["split:".len..], 'y');
    try conn.sendText(split);
    const m2 = (try conn.readMessage()).?;
    try testing.expectEqual(@as(u64, 1800), m2.too_long.len);
    try testing.expectEqual(@as(u8, 'y'), m2.too_long.head[0]);
    try conn.sendText("still here");
    try testing.expectEqualStrings("still here", (try conn.readMessage()).?.text);
    try conn.close(1000, "");
    _ = try conn.readMessage();
}
