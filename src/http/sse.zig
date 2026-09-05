//! Server-Sent Events: `event:` / `data:` / `id:` / `retry:` lines,
//! blank-line delimited, `data` lines joined with `\n`, `:` comments
//! dropped. `Reader` takes bytes as they arrive and yields complete
//! events; `parseAll` runs it over a whole body.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Event = struct {
    /// The `event:` field, or empty (the spec's default is "message").
    name: []const u8,
    data: []const u8,
    id: ?[]const u8 = null,
    retry_ms: ?u32 = null,
};

/// Feed bytes in any chunking; pull events out. Every returned slice
/// is on `arena`.
pub const Reader = struct {
    arena: Allocator,
    pending: std.ArrayListUnmanaged(u8) = .empty,
    name: std.ArrayListUnmanaged(u8) = .empty,
    data: std.ArrayListUnmanaged(u8) = .empty,
    id: ?[]const u8 = null,
    retry_ms: ?u32 = null,
    has_data: bool = false,
    events: std.ArrayListUnmanaged(Event) = .empty,
    next_out: usize = 0,

    pub fn init(arena: Allocator) Reader {
        return .{ .arena = arena };
    }

    pub fn feed(self: *Reader, bytes: []const u8) Allocator.Error!void {
        try self.pending.appendSlice(self.arena, bytes);
        while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
            const line = std.mem.trimEnd(u8, self.pending.items[0..nl], "\r");
            try self.takeLine(line);
            std.mem.copyForwards(u8, self.pending.items, self.pending.items[nl + 1 ..]);
            self.pending.items.len -= nl + 1;
        }
    }

    /// End of stream: a trailing event without its blank line still counts.
    pub fn finish(self: *Reader) Allocator.Error!void {
        if (self.pending.items.len > 0) {
            const line = try self.arena.dupe(u8, std.mem.trimEnd(u8, self.pending.items, "\r"));
            self.pending.clearRetainingCapacity();
            try self.takeLine(line);
        }
        try self.dispatch();
    }

    fn takeLine(self: *Reader, l: []const u8) Allocator.Error!void {
        if (l.len == 0) return self.dispatch();
        if (l[0] == ':') return;
        const colon = std.mem.indexOfScalar(u8, l, ':');
        const field = if (colon) |c| l[0..c] else l;
        var value: []const u8 = if (colon) |c| l[c + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (std.mem.eql(u8, field, "event")) {
            self.name.clearRetainingCapacity();
            try self.name.appendSlice(self.arena, value);
        } else if (std.mem.eql(u8, field, "data")) {
            if (self.has_data) try self.data.append(self.arena, '\n');
            try self.data.appendSlice(self.arena, value);
            self.has_data = true;
        } else if (std.mem.eql(u8, field, "id")) {
            self.id = try self.arena.dupe(u8, value);
        } else if (std.mem.eql(u8, field, "retry")) {
            self.retry_ms = std.fmt.parseInt(u32, value, 10) catch null;
        }
    }

    fn dispatch(self: *Reader) Allocator.Error!void {
        if (!self.has_data) {
            self.name.clearRetainingCapacity();
            return;
        }
        try self.events.append(self.arena, .{
            .name = try self.arena.dupe(u8, self.name.items),
            .data = try self.arena.dupe(u8, self.data.items),
            .id = self.id,
            .retry_ms = self.retry_ms,
        });
        self.name.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
        self.has_data = false;
    }

    /// The next event not yet handed out.
    pub fn next(self: *Reader) ?Event {
        if (self.next_out >= self.events.items.len) return null;
        defer self.next_out += 1;
        return self.events.items[self.next_out];
    }
};

pub fn parseAll(arena: Allocator, body: []const u8) Allocator.Error![]Event {
    var r = Reader.init(arena);
    try r.feed(body);
    try r.finish();
    return r.events.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseAll: two events, multi-line data, comments and ids; chunked feeding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const evs = try parseAll(a, "event: ping\ndata: hello\n\nevent: pong\ndata: world\n\n");
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expectEqualStrings("ping", evs[0].name);
    try testing.expectEqualStrings("hello", evs[0].data);
    try testing.expectEqualStrings("world", evs[1].data);
    const multi = try parseAll(a, ": keepalive\nid: 7\ndata: {\"a\":\ndata: 1}\nretry: 500\n\ndata:last");
    try testing.expectEqual(@as(usize, 2), multi.len);
    try testing.expectEqualStrings("{\"a\":\n1}", multi[0].data);
    try testing.expectEqualStrings("7", multi[0].id.?);
    try testing.expectEqual(@as(?u32, 500), multi[0].retry_ms);
    try testing.expectEqualStrings("", multi[0].name);
    try testing.expectEqualStrings("last", multi[1].data);
    var r = Reader.init(a);
    try r.feed("event: a\nda");
    try testing.expect(r.next() == null);
    try r.feed("ta: x\n\r\n");
    try testing.expectEqualStrings("x", r.next().?.data);
    try r.finish();
    try testing.expect(r.next() == null);
}
