//! `<ws>/.rqst/captured/log.jsonl` — browser traffic the CDP pane (or
//! `mnml-zig proxy`) recorded, one request per line:
//!
//!   {"at":1,"request_id":"r1","method":"GET","url":"…","headers":[["k","v"]],"body":null,"paused":false}
//!
//! `requestId` (Chrome's camel case) is accepted too. A row replays as
//! a request pane.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const Value = std.json.Value;

pub const Row = struct {
    at: i64 = 0,
    request_id: []const u8 = "",
    method: []const u8 = "GET",
    url: []const u8 = "",
    headers: []const parse.Header = &.{},
    body: ?[]const u8 = null,
    paused: bool = false,
};

pub fn logPath(alloc: Allocator, workspace: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(alloc, &.{ workspace, ".rqst", "captured", "log.jsonl" });
}

/// Every row, oldest first, on `arena`. Malformed lines are skipped.
pub fn load(arena: Allocator, io: Io, workspace: []const u8) Allocator.Error![]Row {
    const path = try logPath(arena, workspace);
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch return &.{};
    return parseRows(arena, text);
}

pub fn parseRows(arena: Allocator, text: []const u8) Allocator.Error![]Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch continue;
        if (v != .object) continue;
        const o = v.object;
        var row: Row = .{};
        if (o.get("at")) |x| if (x == .integer) {
            row.at = x.integer;
        };
        if (o.get("request_id") orelse o.get("requestId")) |x| if (x == .string) {
            row.request_id = x.string;
        };
        if (o.get("method")) |x| if (x == .string) {
            row.method = x.string;
        };
        if (o.get("url")) |x| if (x == .string) {
            row.url = x.string;
        };
        if (o.get("body")) |x| if (x == .string) {
            row.body = x.string;
        };
        if (o.get("paused")) |x| if (x == .bool) {
            row.paused = x.bool;
        };
        if (o.get("headers")) |x| if (x == .array) {
            var hs: std.ArrayListUnmanaged(parse.Header) = .empty;
            for (x.array.items) |pair| {
                if (pair == .array and pair.array.items.len >= 2 and pair.array.items[0] == .string and pair.array.items[1] == .string) {
                    try hs.append(arena, .{ .name = @constCast(pair.array.items[0].string), .value = @constCast(pair.array.items[1].string) });
                } else if (pair == .object) {
                    const n = pair.object.get("name") orelse continue;
                    const val = pair.object.get("value") orelse continue;
                    if (n == .string and val == .string) try hs.append(arena, .{ .name = @constCast(n.string), .value = @constCast(val.string) });
                }
            }
            row.headers = hs.items;
        };
        if (row.url.len == 0) continue;
        try out.append(arena, row);
    }
    return out.items;
}

/// A runnable request from a row (pseudo-headers dropped).
pub fn toRequest(gpa: Allocator, row: Row) Allocator.Error!parse.Request {
    var req = try parse.Request.init(gpa);
    errdefer req.deinit(gpa);
    try req.setMethod(gpa, row.method);
    try req.setUrl(gpa, row.url);
    for (row.headers) |h| {
        if (h.name.len > 0 and h.name[0] == ':') continue;
        try req.addHeader(gpa, h.name, h.value);
    }
    if (row.body) |b| try req.setBody(gpa, b);
    return req;
}

/// The line the CDP pane appends for a network request.
pub fn renderLine(gpa: Allocator, at_ms: i64, request_id: []const u8, method: []const u8, url: []const u8, headers: []const parse.Header, body: ?[]const u8) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const E = error{OutOfMemory};
    const emit = struct {
        fn f(j: *std.json.Stringify, at: i64, rid: []const u8, m: []const u8, u: []const u8, hs: []const parse.Header, b: ?[]const u8) E!void {
            j.beginObject() catch return error.OutOfMemory;
            j.objectField("at") catch return error.OutOfMemory;
            j.write(at) catch return error.OutOfMemory;
            j.objectField("request_id") catch return error.OutOfMemory;
            j.write(rid) catch return error.OutOfMemory;
            j.objectField("method") catch return error.OutOfMemory;
            j.write(m) catch return error.OutOfMemory;
            j.objectField("url") catch return error.OutOfMemory;
            j.write(u) catch return error.OutOfMemory;
            j.objectField("headers") catch return error.OutOfMemory;
            j.beginArray() catch return error.OutOfMemory;
            for (hs) |h| {
                j.beginArray() catch return error.OutOfMemory;
                j.write(h.name) catch return error.OutOfMemory;
                j.write(h.value) catch return error.OutOfMemory;
                j.endArray() catch return error.OutOfMemory;
            }
            j.endArray() catch return error.OutOfMemory;
            j.objectField("body") catch return error.OutOfMemory;
            j.write(b) catch return error.OutOfMemory;
            j.objectField("paused") catch return error.OutOfMemory;
            j.write(false) catch return error.OutOfMemory;
            j.endObject() catch return error.OutOfMemory;
        }
    }.f;
    try emit(&js, at_ms, request_id, method, url, headers, body);
    return gpa.dupe(u8, aw.written());
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseRows accepts both id spellings and both header shapes; toRequest drops pseudo-headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const rows = try parseRows(arena.allocator(), "{\"at\":1,\"request_id\":\"r1\",\"method\":\"GET\",\"url\":\"https://captured.example.com/api/items\",\"headers\":[[\":authority\",\"x\"],[\"accept\",\"*/*\"]],\"body\":null,\"paused\":false}\n{\"requestId\":\"r2\",\"method\":\"POST\",\"url\":\"https://c/x\",\"headers\":[{\"name\":\"a\",\"value\":\"1\"}],\"body\":\"{}\"}\nbroken\n");
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("r2", rows[1].request_id);
    try testing.expectEqualStrings("1", rows[1].headers[0].value);
    var req = try toRequest(testing.allocator, rows[0]);
    defer req.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), req.headers.items.len);
    try testing.expectEqualStrings("accept", req.headers.items[0].name);
    const line = try renderLine(testing.allocator, 5, "r9", "GET", "https://x", &.{}, null);
    defer testing.allocator.free(line);
    try testing.expectEqualStrings("{\"at\":5,\"request_id\":\"r9\",\"method\":\"GET\",\"url\":\"https://x\",\"headers\":[],\"body\":null,\"paused\":false}", line);
}
