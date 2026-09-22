//! The cookie jar, by RFC 6265: a cookie is (domain, path, name), fed
//! by `Set-Cookie` on every response and replayed as one `Cookie`
//! header on the requests it matches. `Max-Age` / `Expires` are
//! honoured — `Max-Age=0` or a past `Expires` deletes, as every logout
//! endpoint relies on; `Domain` must domain-match the host that set it
//! and then covers its subdomains; `Path` scopes it (the request's
//! directory when absent); `Secure` keeps it to https. curl's jar
//! (`-b` / `-c`) is the reference. Persisted as `<ws>/.mnml/cookies.json`:
//! `{"host":{"name":"v"}}` for a plain cookie (host-only, `Path=/`, no
//! expiry, not Secure) — the shape earlier builds wrote and still read
//! — and `{"name": {"value":…, "path":…, …}}` for the rest, a second
//! cookie of a name under another path keyed `"name <path>"`.
//!
//! `normalize` collapses the three shapes a DevTools cookie paste takes
//! into the on-the-wire `name=v; name=v` form.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Cookie = struct {
    /// Owned.
    name: []u8,
    value: []u8,
    /// Starts with `/`.
    path: []u8,
    /// Only the host that set it (no `Domain` attribute), else it and
    /// its subdomains.
    host_only: bool = true,
    secure: bool = false,
    /// Unix ms; null lasts the session (and is still persisted, as
    /// curl's `-c` does).
    expires_ms: ?i64 = null,

    fn deinit(c: Cookie, gpa: Allocator) void {
        gpa.free(c.name);
        gpa.free(c.value);
        gpa.free(c.path);
    }

    fn plain(c: Cookie) bool {
        return c.host_only and !c.secure and c.expires_ms == null and std.mem.eql(u8, c.path, "/");
    }
};

/// Now, for the expiry checks, in Unix ms.
pub fn nowMs(io: Io) i64 {
    return @intCast(@divFloor(Io.Timestamp.now(io, .real).toNanoseconds(), std.time.ns_per_ms));
}

pub const Jar = struct {
    gpa: Allocator,
    /// domain (lower-case, no leading dot) → its cookies in creation
    /// order; every string owned.
    hosts: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Cookie)) = .empty,

    pub fn init(gpa: Allocator) Jar {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Jar) void {
        self.clear();
        self.hosts.deinit(self.gpa);
    }

    pub fn clear(self: *Jar) void {
        var it = self.hosts.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |c| c.deinit(self.gpa);
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.hosts.clearRetainingCapacity();
    }

    pub fn total(self: *const Jar) usize {
        var n: usize = 0;
        var it = self.hosts.iterator();
        while (it.next()) |e| n += e.value_ptr.items.len;
        return n;
    }

    fn listFor(self: *Jar, domain: []const u8) Allocator.Error!*std.ArrayListUnmanaged(Cookie) {
        if (self.hosts.getPtr(domain)) |l| return l;
        const d = try self.gpa.dupe(u8, domain);
        errdefer self.gpa.free(d);
        try self.hosts.put(self.gpa, d, .empty);
        return self.hosts.getPtr(d).?;
    }

    /// Store `c` (its strings are copied), replacing the cookie of the
    /// same domain, path and name where it stood (§5.3 step 11 keeps
    /// the old creation time); an already-expired one deletes it.
    pub fn store(self: *Jar, domain: []const u8, c: Cookie, now_ms: i64) Allocator.Error!void {
        const gpa = self.gpa;
        const list = try self.listFor(domain);
        var at_index: ?usize = null;
        for (list.items, 0..) |old, i| if (std.mem.eql(u8, old.name, c.name) and std.mem.eql(u8, old.path, c.path)) {
            at_index = i;
            break;
        };
        if (c.expires_ms) |at| if (at <= now_ms) {
            if (at_index) |i| {
                list.items[i].deinit(gpa);
                _ = list.orderedRemove(i);
            }
            return;
        };
        const name = try gpa.dupe(u8, c.name);
        errdefer gpa.free(name);
        const value = try gpa.dupe(u8, c.value);
        errdefer gpa.free(value);
        const path = try gpa.dupe(u8, c.path);
        errdefer gpa.free(path);
        const fresh: Cookie = .{ .name = name, .value = value, .path = path, .host_only = c.host_only, .secure = c.secure, .expires_ms = c.expires_ms };
        if (at_index) |i| {
            list.items[i].deinit(gpa);
            list.items[i] = fresh;
        } else try list.append(gpa, fresh);
    }

    /// A plain cookie for `host` (path `/`, no expiry) — a paste, a test.
    pub fn put(self: *Jar, host: []const u8, name: []const u8, value: []const u8) Allocator.Error!void {
        try self.store(host, .{ .name = @constCast(name), .value = @constCast(value), .path = @constCast("/") }, 0);
    }

    /// `Set-Cookie: name=value; Path=/; …` from a response to `host`
    /// for `request_path` (the default path comes from it), at `now_ms`.
    /// A `Domain` the host does not domain-match is rejected, as a
    /// browser and curl reject it.
    pub fn recordSetCookie(self: *Jar, host_in: []const u8, request_path: []const u8, set_cookie: []const u8, now_ms: i64) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const host = try std.ascii.allocLowerString(a, host_in);
        var parts = std.mem.splitScalar(u8, set_cookie, ';');
        const first = parts.first();
        const eq = std.mem.indexOfScalar(u8, first, '=') orelse return;
        const name = std.mem.trim(u8, first[0..eq], " \t");
        if (name.len == 0) return;
        var c: Cookie = .{ .name = @constCast(name), .value = @constCast(std.mem.trim(u8, first[eq + 1 ..], " \t\"")), .path = @constCast(try defaultPath(a, request_path)) };
        var domain: []const u8 = host;
        var max_age: ?i64 = null;
        var expires: ?i64 = null;
        while (parts.next()) |raw| {
            const attr = std.mem.trim(u8, raw, " \t");
            const aeq = std.mem.indexOfScalar(u8, attr, '=');
            const key = std.mem.trim(u8, attr[0 .. aeq orelse attr.len], " \t");
            const val = if (aeq) |e| std.mem.trim(u8, attr[e + 1 ..], " \t") else "";
            if (std.ascii.eqlIgnoreCase(key, "max-age")) {
                // RFC 6265 §5.2.2: a leading digit or `-`, else ignored.
                if (std.fmt.parseInt(i64, val, 10)) |secs| {
                    max_age = if (secs <= 0) std.math.minInt(i64) else now_ms +| (secs *| 1000);
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(key, "expires")) {
                if (parseCookieDate(val)) |at| expires = at;
            } else if (std.ascii.eqlIgnoreCase(key, "domain")) {
                var d = std.mem.trimStart(u8, val, ".");
                if (d.len == 0) continue;
                d = try std.ascii.allocLowerString(a, d);
                if (!domainMatch(host, d)) return;
                domain = d;
                c.host_only = false;
            } else if (std.ascii.eqlIgnoreCase(key, "path")) {
                if (val.len > 0 and val[0] == '/') c.path = @constCast(val);
            } else if (std.ascii.eqlIgnoreCase(key, "secure")) {
                c.secure = true;
            }
        }
        // Max-Age wins over Expires (§5.3 step 3).
        c.expires_ms = max_age orelse expires;
        try self.store(domain, c, now_ms);
    }

    /// `name=v; name=v` for a request to `host` + `path` (over https
    /// when `secure`), longest path first; null when nothing matches.
    /// Expired cookies are dropped on the way.
    pub fn cookieHeaderFor(self: *Jar, alloc: Allocator, host_in: []const u8, path: []const u8, secure: bool, now_ms: i64) Allocator.Error!?[]u8 {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const host = try std.ascii.allocLowerString(sa, host_in);
        self.expire(now_ms);
        const Hit = struct { c: Cookie, order: usize };
        var hits: std.ArrayListUnmanaged(Hit) = .empty;
        var it = self.hosts.iterator();
        var order: usize = 0;
        while (it.next()) |e| for (e.value_ptr.items) |c| {
            order += 1;
            const domain = e.key_ptr.*;
            const host_ok = if (c.host_only) std.mem.eql(u8, host, domain) else domainMatch(host, domain);
            if (!host_ok or !pathMatch(path, c.path) or (c.secure and !secure)) continue;
            try hits.append(sa, .{ .c = c, .order = order });
        };
        if (hits.items.len == 0) return null;
        std.mem.sort(Hit, hits.items, {}, struct {
            fn lt(_: void, x: Hit, y: Hit) bool {
                if (x.c.path.len != y.c.path.len) return x.c.path.len > y.c.path.len;
                return x.order < y.order;
            }
        }.lt);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(alloc);
        for (hits.items, 0..) |h, i| {
            if (i > 0) try out.appendSlice(alloc, "; ");
            try out.appendSlice(alloc, h.c.name);
            try out.append(alloc, '=');
            try out.appendSlice(alloc, h.c.value);
        }
        return try out.toOwnedSlice(alloc);
    }

    /// Drop every cookie past its expiry.
    pub fn expire(self: *Jar, now_ms: i64) void {
        var it = self.hosts.iterator();
        while (it.next()) |e| {
            var i: usize = 0;
            while (i < e.value_ptr.items.len) {
                const c = e.value_ptr.items[i];
                if (c.expires_ms) |at| if (at <= now_ms) {
                    c.deinit(self.gpa);
                    _ = e.value_ptr.orderedRemove(i);
                    continue;
                };
                i += 1;
            }
        }
    }

    /// The value of `host`'s cookie `name` (the first path's).
    pub fn valueOf(self: *const Jar, host: []const u8, name: []const u8) ?[]const u8 {
        const list = self.hosts.get(host) orelse return null;
        for (list.items) |c| if (std.mem.eql(u8, c.name, name)) return c.value;
        return null;
    }

    /// Every cookie named `name` under `host`, whatever its path.
    pub fn remove(self: *Jar, host: []const u8, name: []const u8) bool {
        const list = self.hosts.getPtr(host) orelse return false;
        var gone = false;
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i].name, name)) {
                list.items[i].deinit(self.gpa);
                _ = list.orderedRemove(i);
                gone = true;
                continue;
            }
            i += 1;
        }
        return gone;
    }

    pub const Entry = struct { host: []const u8, name: []const u8, value: []const u8, path: []const u8 = "/" };

    /// Every cookie, host order then creation order, on `alloc`.
    pub fn entries(self: *const Jar, alloc: Allocator) Allocator.Error![]Entry {
        var out: std.ArrayListUnmanaged(Entry) = .empty;
        var it = self.hosts.iterator();
        while (it.next()) |e| for (e.value_ptr.items) |c| try out.append(alloc, .{ .host = e.key_ptr.*, .name = c.name, .value = c.value, .path = c.path });
        return out.toOwnedSlice(alloc);
    }

    pub fn jarPath(alloc: Allocator, workspace: []const u8) Allocator.Error![]u8 {
        return std.fs.path.join(alloc, &.{ workspace, ".mnml", "cookies.json" });
    }

    pub fn load(gpa: Allocator, io: Io, workspace: []const u8) Allocator.Error!Jar {
        var jar = Jar.init(gpa);
        errdefer jar.deinit();
        const path = try jarPath(gpa, workspace);
        defer gpa.free(path);
        const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return jar;
        defer gpa.free(text);
        try jar.mergeJson(text);
        jar.expire(nowMs(io));
        return jar;
    }

    pub fn mergeJson(self: *Jar, text: []const u8) Allocator.Error!void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, text, .{}) catch return;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        var it = obj.iterator();
        while (it.next()) |h| switch (h.value_ptr.*) {
            .object => |inner| {
                var jt = inner.iterator();
                while (jt.next()) |c| {
                    // `"name <path>"`: a second path's cookie of a name.
                    const name = std.mem.sliceTo(c.key_ptr.*, ' ');
                    switch (c.value_ptr.*) {
                        .string => |v| try self.put(h.key_ptr.*, name, v),
                        .object => |o| {
                            const v = if (o.get("value")) |x| (if (x == .string) x.string else "") else "";
                            const path = if (o.get("path")) |x| (if (x == .string and x.string.len > 0 and x.string[0] == '/') x.string else "/") else "/";
                            const host_only = if (o.get("host_only")) |x| (x != .bool or x.bool) else true;
                            const secure = if (o.get("secure")) |x| (x == .bool and x.bool) else false;
                            const expires: ?i64 = if (o.get("expires_ms")) |x| (if (x == .integer) x.integer else null) else null;
                            try self.store(h.key_ptr.*, .{ .name = @constCast(name), .value = @constCast(v), .path = @constCast(path), .host_only = host_only, .secure = secure, .expires_ms = expires }, std.math.minInt(i64));
                        },
                        else => {},
                    }
                }
            },
            else => {},
        };
    }

    pub fn toJson(self: *const Jar, gpa: Allocator) Allocator.Error![]u8 {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        const E = error{WriteFailed};
        const body = struct {
            fn f(j: *std.json.Stringify, jar: *const Jar, a: Allocator) (E || Allocator.Error)!void {
                try j.beginObject();
                var it = jar.hosts.iterator();
                while (it.next()) |h| {
                    if (h.value_ptr.items.len == 0) continue;
                    try j.objectField(h.key_ptr.*);
                    try j.beginObject();
                    for (h.value_ptr.items, 0..) |c, i| {
                        var dup = false;
                        for (h.value_ptr.items[0..i]) |o| if (std.mem.eql(u8, o.name, c.name)) {
                            dup = true;
                        };
                        const key = if (dup) try std.fmt.allocPrint(a, "{s} {s}", .{ c.name, c.path }) else c.name;
                        defer if (dup) a.free(key);
                        try j.objectField(key);
                        if (c.plain()) {
                            try j.write(c.value);
                            continue;
                        }
                        try j.beginObject();
                        try j.objectField("value");
                        try j.write(c.value);
                        try j.objectField("path");
                        try j.write(c.path);
                        try j.objectField("host_only");
                        try j.write(c.host_only);
                        try j.objectField("secure");
                        try j.write(c.secure);
                        try j.objectField("expires_ms");
                        try j.write(c.expires_ms);
                        try j.endObject();
                    }
                    try j.endObject();
                }
                try j.endObject();
            }
        }.f;
        body(&js, self, gpa) catch return error.OutOfMemory;
        return gpa.dupe(u8, aw.written());
    }

    /// Write the jar; returns the path (owned).
    pub fn save(self: *const Jar, gpa: Allocator, io: Io, workspace: []const u8) ![]u8 {
        const path = try jarPath(gpa, workspace);
        errdefer gpa.free(path);
        const text = try self.toJson(gpa);
        defer gpa.free(text);
        if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
        return path;
    }
};

/// RFC 6265 §5.1.3: `host` is `domain`, or ends in `.domain` and is a
/// name, not an IP address.
pub fn domainMatch(host: []const u8, domain: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, domain)) return true;
    if (isIp(host)) return false;
    if (host.len <= domain.len + 1) return false;
    const tail = host[host.len - domain.len ..];
    return host[host.len - domain.len - 1] == '.' and std.ascii.eqlIgnoreCase(tail, domain);
}

fn isIp(host: []const u8) bool {
    if (std.mem.indexOfScalar(u8, host, ':') != null) return true; // IPv6
    for (host) |ch| if (!(std.ascii.isDigit(ch) or ch == '.')) return false;
    return host.len > 0;
}

/// RFC 6265 §5.1.4: the request path is the cookie's, or below it.
pub fn pathMatch(req_path: []const u8, cookie_path: []const u8) bool {
    if (std.mem.eql(u8, req_path, cookie_path)) return true;
    if (!std.mem.startsWith(u8, req_path, cookie_path)) return false;
    return cookie_path[cookie_path.len - 1] == '/' or req_path[cookie_path.len] == '/';
}

/// RFC 6265 §5.1.4's default-path: the request path up to its last `/`
/// (`/` when that is the first).
fn defaultPath(a: Allocator, req_path: []const u8) Allocator.Error![]const u8 {
    if (req_path.len == 0 or req_path[0] != '/') return "/";
    const last = std.mem.lastIndexOfScalar(u8, req_path, '/').?;
    if (last == 0) return "/";
    return a.dupe(u8, req_path[0..last]);
}

/// The path of a URL, no query or fragment: `http://h/a/b?x` → `/a/b`.
pub fn pathOf(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    const start = std.mem.indexOfScalar(u8, s, '/') orelse return "/";
    const rest = s[start..];
    const end = std.mem.indexOfAny(u8, rest, "?#") orelse rest.len;
    return if (end == 0) "/" else rest[0..end];
}

/// RFC 6265 §5.1.1's lenient date: the first `hh:mm:ss`, day of month,
/// month name and year among the tokens, in any order. Unix ms.
pub fn parseCookieDate(text: []const u8) ?i64 {
    var hour: ?u8 = null;
    var minute: u8 = 0;
    var second: u8 = 0;
    var day: ?u8 = null;
    var month: ?u8 = null;
    var year: ?i64 = null;
    var it = std.mem.tokenizeAny(u8, text, " \t,;-/");
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    while (it.next()) |tok| {
        if (hour == null and std.mem.count(u8, tok, ":") == 2) {
            var hms = std.mem.splitScalar(u8, tok, ':');
            const h = std.fmt.parseInt(u8, hms.next().?, 10) catch continue;
            const m = std.fmt.parseInt(u8, hms.next().?, 10) catch continue;
            const s3 = hms.next().?;
            const sec = std.fmt.parseInt(u8, s3[0..@min(2, s3.len)], 10) catch continue;
            hour = h;
            minute = m;
            second = sec;
            continue;
        }
        if (month == null and tok.len >= 3) {
            var found = false;
            for (months, 0..) |mn, i| if (std.ascii.eqlIgnoreCase(tok[0..3], mn)) {
                month = @intCast(i + 1);
                found = true;
            };
            if (found) continue;
        }
        const digits = std.mem.trim(u8, tok, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ");
        const n = std.fmt.parseInt(i64, digits, 10) catch continue;
        if (day == null and digits.len <= 2 and n >= 1 and n <= 31) {
            day = @intCast(n);
        } else if (year == null and digits.len >= 2 and digits.len <= 4) {
            year = if (n >= 70 and n <= 99) n + 1900 else if (n >= 0 and n <= 69) n + 2000 else n;
        }
    }
    const y = year orelse return null;
    const mo = month orelse return null;
    const d = day orelse return null;
    const h = hour orelse return null;
    if (y < 1601 or h > 23 or minute > 59 or second > 59) return null;
    // days-from-civil (H. Hinnant).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp: i64 = if (mo > 2) mo - 3 else mo + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 86400) + @as(i64, h) * 3600 + @as(i64, minute) * 60 + second) * 1000;
}

/// The host part of a URL: `https://a.b:8/c` → `a.b`.
pub fn hostOf(url: []const u8) ?[]const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |i| s = s[i + 3 ..];
    const end = std.mem.indexOfAny(u8, s, "/?#") orelse s.len;
    var host = s[0..end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    return if (host.len == 0) null else host;
}

/// Any of: `name=v` per line, `name: v` per line (a DevTools table
/// paste, tabs allowed), or the canonical `name=v; name=v` — into the
/// canonical form. Blank and `#` lines are skipped.
pub fn normalize(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // A canonical line may carry several pairs.
        var parts = std.mem.splitScalar(u8, line, ';');
        while (parts.next()) |part_raw| {
            const part = std.mem.trim(u8, part_raw, " \t");
            if (part.len == 0) continue;
            var name: []const u8 = undefined;
            var value: []const u8 = undefined;
            if (std.mem.indexOfScalar(u8, part, '=')) |eq| {
                name = std.mem.trim(u8, part[0..eq], " \t");
                value = std.mem.trim(u8, part[eq + 1 ..], " \t");
            } else if (std.mem.indexOfAny(u8, part, ":\t")) |sep| {
                name = std.mem.trim(u8, part[0..sep], " \t");
                value = std.mem.trim(u8, part[sep + 1 ..], " \t");
            } else continue;
            if (name.len == 0) continue;
            if (out.items.len > 0) try out.appendSlice(alloc, "; ");
            try out.appendSlice(alloc, name);
            try out.append(alloc, '=');
            try out.appendSlice(alloc, value);
        }
    }
    return out.toOwnedSlice(alloc);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "jar: record, replay per host, remove, clear, json round-trip" {
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();
    const now: i64 = 1_700_000_000_000;
    try jar.recordSetCookie("a.com", "/", "sid=1; Path=/; HttpOnly", now);
    try jar.recordSetCookie("a.com", "/", "t=x", now);
    try jar.recordSetCookie("b.com", "/", "sid=2", now);
    try jar.recordSetCookie("a.com", "/", "sid=9", now);
    try testing.expectEqual(@as(usize, 3), jar.total());
    const h = (try jar.cookieHeaderFor(testing.allocator, "a.com", "/", false, now)).?;
    defer testing.allocator.free(h);
    try testing.expectEqualStrings("sid=9; t=x", h);
    try testing.expect((try jar.cookieHeaderFor(testing.allocator, "c.com", "/", false, now)) == null);
    const json = try jar.toJson(testing.allocator);
    defer testing.allocator.free(json);
    // Plain cookies keep the shape earlier builds read.
    try testing.expect(std.mem.indexOf(u8, json, "\"t\": \"x\"") != null);
    var jar2 = Jar.init(testing.allocator);
    defer jar2.deinit();
    try jar2.mergeJson(json);
    try testing.expectEqual(@as(usize, 3), jar2.total());
    try testing.expect(jar.remove("a.com", "t"));
    try testing.expect(!jar.remove("a.com", "t"));
    const es = try jar.entries(testing.allocator);
    defer testing.allocator.free(es);
    try testing.expectEqual(@as(usize, 2), es.len);
    jar.clear();
    try testing.expectEqual(@as(usize, 0), jar.total());
    try testing.expectEqualStrings("api.x.com", hostOf("https://u:p@api.x.com:8443/a?b#c").?);
    try testing.expect(hostOf("nonsense/") != null);
    try testing.expectEqualStrings("/a/b", pathOf("http://h:1/a/b?x#y"));
    try testing.expectEqualStrings("/", pathOf("http://h"));
}

test "jar: RFC 6265 — deletion by Max-Age=0 and a past Expires, Path and Domain scope, Secure (curl's jar agrees)" {
    var jar = Jar.init(testing.allocator);
    defer jar.deinit();
    const now: i64 = 1_700_000_000_000; // 2023-11-14
    // The hunter's sequence against 127.0.0.1, curl `-b cj -c cj` as the oracle.
    try jar.recordSetCookie("127.0.0.1", "/setcookie", "sid=abc123; Path=/", now);
    try jar.recordSetCookie("127.0.0.1", "/setcookie", "theme=dark; Path=/", now);
    try jar.recordSetCookie("127.0.0.1", "/s", "scoped=1; Path=/api", now);
    try jar.recordSetCookie("127.0.0.1", "/s", "old=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT", now);
    try jar.recordSetCookie("127.0.0.1", "/s", "other=1; Domain=example.com", now);
    try jar.recordSetCookie("127.0.0.1", "/logout", "sid=; Max-Age=0; Path=/", now);
    const root = (try jar.cookieHeaderFor(testing.allocator, "127.0.0.1", "/echo", false, now)).?;
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("theme=dark", root);
    const api = (try jar.cookieHeaderFor(testing.allocator, "127.0.0.1", "/api/echo", false, now)).?;
    defer testing.allocator.free(api);
    try testing.expectEqualStrings("scoped=1; theme=dark", api);
    // `/apix` is not under `/api`.
    const apix = (try jar.cookieHeaderFor(testing.allocator, "127.0.0.1", "/apix", false, now)).?;
    defer testing.allocator.free(apix);
    try testing.expectEqualStrings("theme=dark", apix);
    // A Domain cookie covers subdomains; a host-only one does not.
    try jar.recordSetCookie("www.shop.test", "/", "d=1; Domain=shop.test", now);
    try jar.recordSetCookie("www.shop.test", "/", "h=1", now);
    const sub = (try jar.cookieHeaderFor(testing.allocator, "api.shop.test", "/", false, now)).?;
    defer testing.allocator.free(sub);
    try testing.expectEqualStrings("d=1", sub);
    // Secure only over https; a Max-Age runs out.
    try jar.recordSetCookie("s.test", "/", "sec=1; Secure; Max-Age=60", now);
    try testing.expect((try jar.cookieHeaderFor(testing.allocator, "s.test", "/", false, now)) == null);
    const tls = (try jar.cookieHeaderFor(testing.allocator, "s.test", "/", true, now)).?;
    defer testing.allocator.free(tls);
    try testing.expectEqualStrings("sec=1", tls);
    try testing.expect((try jar.cookieHeaderFor(testing.allocator, "s.test", "/", true, now + 61_000)) == null);
    // The attributes survive a save.
    try jar.recordSetCookie("127.0.0.1", "/s", "scoped=2; Path=/api/v2", now);
    const json = try jar.toJson(testing.allocator);
    defer testing.allocator.free(json);
    var back = Jar.init(testing.allocator);
    defer back.deinit();
    try back.mergeJson(json);
    const v2 = (try back.cookieHeaderFor(testing.allocator, "127.0.0.1", "/api/v2/x", false, now)).?;
    defer testing.allocator.free(v2);
    try testing.expectEqualStrings("scoped=2; scoped=1; theme=dark", v2);
    try testing.expectEqual(@as(?i64, 1445412480000), parseCookieDate("Wed, 21 Oct 2015 07:28:00 GMT"));
    try testing.expectEqual(@as(?i64, 1445412480000), parseCookieDate("Wednesday, 21-Oct-15 07:28:00 GMT"));
}

test "normalize: the three DevTools shapes collapse to name=v; name=v" {
    const a = try normalize(testing.allocator, "sessionid=abc123; csrftoken=xyz789");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("sessionid=abc123; csrftoken=xyz789", a);
    const b = try normalize(testing.allocator, "sessionid=abc123\ncsrftoken=xyz789\n");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("sessionid=abc123; csrftoken=xyz789", b);
    const c = try normalize(testing.allocator, "sessionid: abc123\n# note\ncsrftoken\txyz789");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("sessionid=abc123; csrftoken=xyz789", c);
}
