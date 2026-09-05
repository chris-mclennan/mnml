//! The cookie jar: `host → name → value`, fed by `Set-Cookie` on every
//! response and replayed as one `Cookie` header on requests to the same
//! host. Persisted as `<ws>/.mnml/cookies.json` (`{"host":{"name":"v"}}`).
//! Attributes (`Path`, `Expires`, `Secure`…) are dropped: the jar is a
//! developer convenience for staying logged in across sends, not a
//! browser.
//!
//! `normalize` collapses the three shapes a DevTools cookie paste takes
//! into the on-the-wire `name=v; name=v` form.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Jar = struct {
    gpa: Allocator,
    /// host → (name → value); every string owned.
    hosts: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged([]u8)) = .empty,

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
            var inner = e.value_ptr;
            var jt = inner.iterator();
            while (jt.next()) |c| {
                self.gpa.free(c.key_ptr.*);
                self.gpa.free(c.value_ptr.*);
            }
            inner.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.hosts.clearRetainingCapacity();
    }

    pub fn total(self: *const Jar) usize {
        var n: usize = 0;
        var it = self.hosts.iterator();
        while (it.next()) |e| n += e.value_ptr.count();
        return n;
    }

    pub fn put(self: *Jar, host: []const u8, name: []const u8, value: []const u8) Allocator.Error!void {
        const gpa = self.gpa;
        const v = try gpa.dupe(u8, value);
        errdefer gpa.free(v);
        const slot = self.hosts.getPtr(host) orelse blk: {
            const h = try gpa.dupe(u8, host);
            errdefer gpa.free(h);
            try self.hosts.put(gpa, h, .empty);
            break :blk self.hosts.getPtr(h).?;
        };
        if (slot.getPtr(name)) |existing| {
            gpa.free(existing.*);
            existing.* = v;
            return;
        }
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        try slot.put(gpa, n, v);
    }

    /// `Set-Cookie: name=value; Path=/; …` → one entry.
    pub fn recordSetCookie(self: *Jar, host: []const u8, set_cookie: []const u8) Allocator.Error!void {
        const first = std.mem.sliceTo(set_cookie, ';');
        const eq = std.mem.indexOfScalar(u8, first, '=') orelse return;
        const name = std.mem.trim(u8, first[0..eq], " \t");
        if (name.len == 0) return;
        try self.put(host, name, std.mem.trim(u8, first[eq + 1 ..], " \t"));
    }

    /// `name=v; name=v` for `host`, or null when the jar has none.
    pub fn cookieHeaderFor(self: *const Jar, alloc: Allocator, host: []const u8) Allocator.Error!?[]u8 {
        const inner = self.hosts.get(host) orelse return null;
        if (inner.count() == 0) return null;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var it = inner.iterator();
        var first = true;
        while (it.next()) |c| {
            if (!first) try out.appendSlice(alloc, "; ");
            first = false;
            try out.appendSlice(alloc, c.key_ptr.*);
            try out.append(alloc, '=');
            try out.appendSlice(alloc, c.value_ptr.*);
        }
        return try out.toOwnedSlice(alloc);
    }

    pub fn remove(self: *Jar, host: []const u8, name: []const u8) bool {
        const inner = self.hosts.getPtr(host) orelse return false;
        const kv = inner.fetchOrderedRemove(name) orelse return false;
        self.gpa.free(kv.key);
        self.gpa.free(kv.value);
        return true;
    }

    pub const Entry = struct { host: []const u8, name: []const u8, value: []const u8 };

    /// Every cookie, host order then name order, on `alloc`.
    pub fn entries(self: *const Jar, alloc: Allocator) Allocator.Error![]Entry {
        var out: std.ArrayListUnmanaged(Entry) = .empty;
        var it = self.hosts.iterator();
        while (it.next()) |e| {
            var jt = e.value_ptr.iterator();
            while (jt.next()) |c| try out.append(alloc, .{ .host = e.key_ptr.*, .name = c.key_ptr.*, .value = c.value_ptr.* });
        }
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
                while (jt.next()) |c| switch (c.value_ptr.*) {
                    .string => |s| try self.put(h.key_ptr.*, c.key_ptr.*, s),
                    else => {},
                };
            },
            else => {},
        };
    }

    pub fn toJson(self: *const Jar, gpa: Allocator) Allocator.Error![]u8 {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        js.beginObject() catch return error.OutOfMemory;
        var it = self.hosts.iterator();
        while (it.next()) |h| {
            js.objectField(h.key_ptr.*) catch return error.OutOfMemory;
            js.beginObject() catch return error.OutOfMemory;
            var jt = h.value_ptr.iterator();
            while (jt.next()) |c| {
                js.objectField(c.key_ptr.*) catch return error.OutOfMemory;
                js.write(c.value_ptr.*) catch return error.OutOfMemory;
            }
            js.endObject() catch return error.OutOfMemory;
        }
        js.endObject() catch return error.OutOfMemory;
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
    try jar.recordSetCookie("a.com", "sid=1; Path=/; HttpOnly");
    try jar.recordSetCookie("a.com", "t=x");
    try jar.recordSetCookie("b.com", "sid=2");
    try jar.recordSetCookie("a.com", "sid=9");
    try testing.expectEqual(@as(usize, 3), jar.total());
    const h = (try jar.cookieHeaderFor(testing.allocator, "a.com")).?;
    defer testing.allocator.free(h);
    try testing.expectEqualStrings("sid=9; t=x", h);
    try testing.expect((try jar.cookieHeaderFor(testing.allocator, "c.com")) == null);
    const json = try jar.toJson(testing.allocator);
    defer testing.allocator.free(json);
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
