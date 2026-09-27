//! `<ws>/.rqst/history.jsonl` — one JSON object per send, appended
//! (never rewritten), the same shape the Rust client writes so a
//! workspace's log reads under either binary:
//!
//!   {"ts":…,"method":"GET","url":"…","status":200,"duration_ms":42,
//!    "body_bytes":512,"error":null,"headers":[["k","v"]],"request_body":null}
//!
//! A credential-bearing header keeps its unexpanded `{{VAR}}` form
//! when it has one and is redacted otherwise; the picker rebuilds a
//! runnable curl from what is stored. Every line is also mirrored into
//! `<data_root>/history-global.jsonl` with a `"workspace"` field.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");

pub const Header = parse.Header;

const sensitive = [_][]const u8{ "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key", "x-auth-token", "x-amz-security-token", "x-csrf-token" };

pub fn isSensitiveHeader(name: []const u8) bool {
    const n = std.mem.trim(u8, name, " \t");
    for (sensitive) |s| if (std.ascii.eqlIgnoreCase(n, s)) return true;
    return false;
}

/// What lands in the file for a header: expanded for ordinary headers;
/// the `{{VAR}}` reference when a sensitive one has it; `<redacted>` otherwise.
pub fn headerValueForHistory(name: []const u8, raw: []const u8, expanded: []const u8) []const u8 {
    if (!isSensitiveHeader(name)) return expanded;
    if (std.mem.indexOf(u8, raw, "{{") != null) return raw;
    return "<redacted>";
}

pub const Entry = struct {
    method: []const u8,
    url: []const u8,
    status: ?u16,
    duration_ms: ?u64,
    body_bytes: ?usize,
    err: ?[]const u8,
    /// Already passed through `headerValueForHistory`.
    headers: []const Header = &.{},
    request_body: ?[]const u8 = null,
    /// The URL as written (`{{BASE}}/me`); `url` is it expanded.
    url_template: ?[]const u8 = null,
    /// The env the send resolved against.
    env: ?[]const u8 = null,
};

pub fn historyPath(alloc: Allocator, workspace: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(alloc, &.{ workspace, ".rqst", "history.jsonl" });
}

/// One line, no trailing newline.
pub fn renderLine(gpa: Allocator, entry: Entry, ts_ms: i64, workspace_label: ?[]const u8) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    const E = error{OutOfMemory};
    const body = struct {
        fn f(j: *std.json.Stringify, e: Entry, ts: i64, ws: ?[]const u8) E!void {
            j.beginObject() catch return error.OutOfMemory;
            j.objectField("ts") catch return error.OutOfMemory;
            j.write(ts) catch return error.OutOfMemory;
            j.objectField("method") catch return error.OutOfMemory;
            j.write(e.method) catch return error.OutOfMemory;
            j.objectField("url") catch return error.OutOfMemory;
            j.write(e.url) catch return error.OutOfMemory;
            j.objectField("status") catch return error.OutOfMemory;
            j.write(e.status) catch return error.OutOfMemory;
            j.objectField("duration_ms") catch return error.OutOfMemory;
            j.write(e.duration_ms) catch return error.OutOfMemory;
            j.objectField("body_bytes") catch return error.OutOfMemory;
            j.write(e.body_bytes) catch return error.OutOfMemory;
            j.objectField("error") catch return error.OutOfMemory;
            j.write(e.err) catch return error.OutOfMemory;
            j.objectField("headers") catch return error.OutOfMemory;
            j.beginArray() catch return error.OutOfMemory;
            for (e.headers) |h| {
                j.beginArray() catch return error.OutOfMemory;
                j.write(h.name) catch return error.OutOfMemory;
                j.write(h.value) catch return error.OutOfMemory;
                j.endArray() catch return error.OutOfMemory;
            }
            j.endArray() catch return error.OutOfMemory;
            j.objectField("request_body") catch return error.OutOfMemory;
            j.write(e.request_body) catch return error.OutOfMemory;
            // Two keys the Rust shape lacks, written only when known; a
            // reader that does not know them skips them.
            if (e.url_template) |t| if (!std.mem.eql(u8, t, e.url)) {
                j.objectField("url_template") catch return error.OutOfMemory;
                j.write(t) catch return error.OutOfMemory;
            };
            if (e.env) |n| {
                j.objectField("env") catch return error.OutOfMemory;
                j.write(n) catch return error.OutOfMemory;
            }
            if (ws) |w| {
                j.objectField("workspace") catch return error.OutOfMemory;
                j.write(w) catch return error.OutOfMemory;
            }
            j.endObject() catch return error.OutOfMemory;
        }
    }.f;
    try body(&js, entry, ts_ms, workspace_label);
    return gpa.dupe(u8, aw.written());
}

/// Append one line to `path`, creating the file and its directory.
pub fn appendLine(gpa: Allocator, io: Io, path: []const u8, line: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try Io.Dir.cwd().createDirPath(io, parent);
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const end = try file.length(io);
    const with_nl = try std.mem.concat(gpa, u8, &.{ line, "\n" });
    defer gpa.free(with_nl);
    try file.writePositionalAll(io, with_nl, end);
}

/// Append to the workspace log and, when `global_path` is given, to the
/// cross-workspace mirror.
pub fn append(gpa: Allocator, io: Io, workspace: []const u8, global_path: ?[]const u8, entry: Entry) !void {
    const ts: i64 = @intCast(@divFloor(Io.Timestamp.now(io, .real).toNanoseconds(), std.time.ns_per_ms));
    const path = try historyPath(gpa, workspace);
    defer gpa.free(path);
    const line = try renderLine(gpa, entry, ts, null);
    defer gpa.free(line);
    try appendLine(gpa, io, path, line);
    if (global_path) |g| {
        const label = std.fs.path.basename(workspace);
        const gline = try renderLine(gpa, entry, ts, label);
        defer gpa.free(gline);
        appendLine(gpa, io, g, gline) catch {};
    }
}

/// A parsed line. Slices borrow from the arena `tail` filled.
pub const Row = struct {
    ts: i64 = 0,
    method: []const u8 = "?",
    url: []const u8 = "",
    status: ?u16 = null,
    duration_ms: ?u64 = null,
    body_bytes: ?u64 = null,
    err: ?[]const u8 = null,
    headers: []const Header = &.{},
    request_body: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    url_template: ?[]const u8 = null,
    env: ?[]const u8 = null,
};

/// The last `n` rows of a `.jsonl` file, oldest first. Malformed lines
/// are skipped. Missing file ⇒ empty.
pub fn tail(arena: Allocator, io: Io, path: []const u8, n: usize) Allocator.Error![]Row {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 << 20)) catch return &.{};
    return parseRows(arena, text, n);
}

pub fn parseRows(arena: Allocator, text: []const u8, n: usize) Allocator.Error![]Row {
    var all: std.ArrayListUnmanaged(Row) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const row = parseRow(arena, line) catch continue;
        try all.append(arena, row orelse continue);
    }
    const from = all.items.len -| n;
    return all.items[from..];
}

fn parseRow(arena: Allocator, line: []const u8) !?Row {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    var row: Row = .{};
    if (obj.get("ts")) |x| if (x == .integer) {
        row.ts = x.integer;
    };
    if (obj.get("method")) |x| if (x == .string) {
        row.method = x.string;
    };
    if (obj.get("url")) |x| if (x == .string) {
        row.url = x.string;
    };
    if (obj.get("status")) |x| if (x == .integer) {
        row.status = @intCast(std.math.clamp(x.integer, 0, 999));
    };
    if (obj.get("duration_ms")) |x| if (x == .integer) {
        row.duration_ms = @intCast(@max(x.integer, 0));
    };
    if (obj.get("body_bytes")) |x| if (x == .integer) {
        row.body_bytes = @intCast(@max(x.integer, 0));
    };
    if (obj.get("error")) |x| if (x == .string) {
        row.err = x.string;
    };
    if (obj.get("request_body")) |x| if (x == .string) {
        row.request_body = x.string;
    };
    if (obj.get("workspace")) |x| if (x == .string) {
        row.workspace = x.string;
    };
    if (obj.get("url_template")) |x| if (x == .string) {
        row.url_template = x.string;
    };
    if (obj.get("env")) |x| if (x == .string) {
        row.env = x.string;
    };
    if (obj.get("headers")) |x| if (x == .array) {
        var hs: std.ArrayListUnmanaged(Header) = .empty;
        for (x.array.items) |pair| if (pair == .array and pair.array.items.len >= 2) {
            const a = pair.array.items[0];
            const b = pair.array.items[1];
            if (a == .string and b == .string) try hs.append(arena, .{ .name = @constCast(a.string), .value = @constCast(b.string) });
        };
        row.headers = hs.items;
    };
    return row;
}

/// A runnable request built back from a row.
pub fn rowToRequest(gpa: Allocator, row: Row) Allocator.Error!parse.Request {
    var req = try parse.Request.init(gpa);
    errdefer req.deinit(gpa);
    try req.setMethod(gpa, row.method);
    // The URL as written when the row has it, so it resolves against the
    // same env as the headers (which are stored as written too).
    try req.setUrl(gpa, row.url_template orelse row.url);
    for (row.headers) |h| {
        if (std.mem.eql(u8, h.value, "<redacted>")) continue;
        try req.addHeader(gpa, h.name, h.value);
    }
    if (row.request_body) |b| try req.setBody(gpa, b);
    return req;
}

/// `host/path` without scheme, query or fragment — the picker label.
pub fn shortUrl(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.startsWith(u8, s, "https://")) s = s["https://".len..] else if (std.mem.startsWith(u8, s, "http://")) s = s["http://".len..];
    const cut = std.mem.indexOfAny(u8, s, "?#") orelse s.len;
    return s[0..cut];
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "renderLine matches the Rust shape; sensitive headers keep refs or redact" {
    const gpa = testing.allocator;
    const hs = [_]Header{ .{ .name = @constCast("Accept"), .value = @constCast("*/*") }, .{ .name = @constCast("Authorization"), .value = @constCast("Bearer {{TOKEN}}") } };
    const line = try renderLine(gpa, .{ .method = "POST", .url = "https://x/login", .status = 200, .duration_ms = 88, .body_bytes = 64, .err = null, .headers = &hs, .request_body = "{}" }, 1000, null);
    defer gpa.free(line);
    try testing.expectEqualStrings("{\"ts\":1000,\"method\":\"POST\",\"url\":\"https://x/login\",\"status\":200,\"duration_ms\":88,\"body_bytes\":64,\"error\":null,\"headers\":[[\"Accept\",\"*/*\"],[\"Authorization\",\"Bearer {{TOKEN}}\"]],\"request_body\":\"{}\"}", line);
    try testing.expectEqualStrings("Bearer {{T}}", headerValueForHistory("authorization", "Bearer {{T}}", "Bearer secret"));
    try testing.expectEqualStrings("<redacted>", headerValueForHistory("X-API-KEY", "literal", "literal"));
    try testing.expectEqualStrings("text/html", headerValueForHistory("Accept", "{{A}}", "text/html"));
    try testing.expect(isSensitiveHeader(" Cookie "));
}

test "tail reads the last n rows oldest first, skipping junk; rowToRequest rebuilds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try parseRows(a, "{\"ts\":1,\"method\":\"POST\",\"url\":\"https://api.example.com/login\",\"status\":200,\"duration_ms\":88,\"body_bytes\":64,\"error\":null}\nnot json\n{\"ts\":2,\"method\":\"GET\",\"url\":\"https://api.example.com/users\",\"status\":null,\"duration_ms\":42,\"error\":\"dns\",\"headers\":[[\"A\",\"1\"]],\"request_body\":\"b\"}\n", 5);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("POST", rows[0].method);
    try testing.expectEqual(@as(?u16, 200), rows[0].status);
    try testing.expect(rows[1].status == null);
    try testing.expectEqualStrings("dns", rows[1].err.?);
    try testing.expectEqualStrings("api.example.com/users", shortUrl(rows[1].url));
    const one = try parseRows(a, "{\"method\":\"GET\",\"url\":\"a\"}\n{\"method\":\"GET\",\"url\":\"b\"}\n", 1);
    try testing.expectEqualStrings("b", one[0].url);
    var req = try rowToRequest(testing.allocator, rows[1]);
    defer req.deinit(testing.allocator);
    try testing.expectEqualStrings("1", req.header("a").?);
    try testing.expectEqualStrings("b", req.body.?);
}

test "append creates the file and mirrors to the global log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    const global = try std.fs.path.join(testing.allocator, &.{ ws, "global.jsonl" });
    defer testing.allocator.free(global);
    try append(testing.allocator, testing.io, ws, global, .{ .method = "GET", .url = "https://x/1", .status = 200, .duration_ms = 1, .body_bytes = 2, .err = null });
    try append(testing.allocator, testing.io, ws, global, .{ .method = "GET", .url = "https://x/2", .status = null, .duration_ms = null, .body_bytes = null, .err = "boom" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try historyPath(arena.allocator(), ws);
    const rows = try tail(arena.allocator(), testing.io, path, 10);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("https://x/2", rows[1].url);
    const grows = try tail(arena.allocator(), testing.io, global, 10);
    try testing.expectEqual(@as(usize, 2), grows.len);
    try testing.expect(grows[0].workspace != null);
}
