//! Imports: a HAR file (`log.entries[].request`) and a Postman
//! Collection v2.1 (`item[]`, nested folders flattened into the file
//! name) each become one `.curl` file per request. Nothing is written
//! here — the caller gets `(name, curl text)` pairs and a directory
//! stem and decides where they land.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Stub = struct {
    /// A file name without the `.curl` extension.
    name: []const u8,
    curl: []const u8,
};

pub const Import = struct {
    /// The directory stem: `har-<timestamp>` / `postman-<collection>`.
    dir: []const u8,
    stubs: []const Stub,
};

pub const ImportError = error{ NotJson, NotAHar, NotAPostmanCollection } || Allocator.Error;

fn str(v: ?Value) ?[]const u8 {
    return if (v) |x| switch (x) {
        .string => |s| s,
        else => null,
    } else null;
}

fn escapeSingle(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\'') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c);
    }
    return out.items;
}

fn safeName(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try a.dupe(u8, s);
    for (out) |*c| if (!(std.ascii.isAlphanumeric(c.*) or c.* == '-' or c.* == '_' or c.* == '.')) {
        c.* = '_';
    };
    return out;
}

/// Everything on `arena`.
pub fn har(arena: Allocator, text: []const u8) ImportError!Import {
    const root = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return error.NotJson;
    const log = if (root == .object) root.object.get("log") else null;
    const entries = if (log != null and log.? == .object) log.?.object.get("entries") else null;
    if (entries == null or entries.? != .array) return error.NotAHar;
    const items = entries.?.array.items;
    var dir: []const u8 = "har-import";
    if (items.len > 0 and items[0] == .object) if (str(items[0].object.get("startedDateTime"))) |ts| {
        const cut = ts[0..@min(ts.len, 19)];
        const stem = try arena.dupe(u8, cut);
        for (stem) |*c| if (c.* == ':') {
            c.* = '-';
        };
        dir = try std.fmt.allocPrint(arena, "har-{s}", .{stem});
    };
    var stubs: std.ArrayListUnmanaged(Stub) = .empty;
    for (items, 0..) |entry, i| {
        if (entry != .object) continue;
        const req = entry.object.get("request") orelse continue;
        if (req != .object) continue;
        const method_raw = str(req.object.get("method")) orelse "GET";
        const method = try std.ascii.allocUpperString(arena, method_raw);
        const url = str(req.object.get("url")) orelse continue;
        var curl: std.ArrayListUnmanaged(u8) = .empty;
        try appendFmt(arena, &curl, "curl -X {s} '{s}'", .{ method, try escapeSingle(arena, url) });
        if (req.object.get("headers")) |hs| if (hs == .array) {
            for (hs.array.items) |h| {
                if (h != .object) continue;
                const name = str(h.object.get("name")) orelse continue;
                const value = str(h.object.get("value")) orelse continue;
                if (name.len > 0 and name[0] == ':') continue;
                try appendFmt(arena, &curl, " \\\n  -H '{s}: {s}'", .{ name, try escapeSingle(arena, value) });
            }
        };
        if (req.object.get("postData")) |pd| if (pd == .object) if (str(pd.object.get("text"))) |body| {
            try appendFmt(arena, &curl, " \\\n  --data-raw '{s}'", .{try escapeSingle(arena, body)});
        };
        const short = std.mem.sliceTo(std.mem.sliceTo(url, '?'), '#');
        const tail = if (std.mem.lastIndexOfScalar(u8, std.mem.trimEnd(u8, short, "/"), '/')) |s| short[s + 1 ..] else short;
        const name = try std.fmt.allocPrint(arena, "{d:0>3}_{s}_{s}", .{ i, method, try safeName(arena, if (tail.len == 0) "root" else tail) });
        try stubs.append(arena, .{ .name = name, .curl = curl.items });
    }
    return .{ .dir = dir, .stubs = stubs.items };
}

/// Everything on `arena`.
pub fn postman(arena: Allocator, text: []const u8) ImportError!Import {
    const root = std.json.parseFromSliceLeaky(Value, arena, text, .{}) catch return error.NotJson;
    if (root != .object) return error.NotAPostmanCollection;
    const items = root.object.get("item") orelse return error.NotAPostmanCollection;
    if (items != .array) return error.NotAPostmanCollection;
    var coll_name: []const u8 = "collection";
    if (root.object.get("info")) |info| if (info == .object) if (str(info.object.get("name"))) |n| {
        coll_name = n;
    };
    var stubs: std.ArrayListUnmanaged(Stub) = .empty;
    var counter: usize = 0;
    try walkItems(arena, items.array.items, "", &stubs, &counter);
    return .{ .dir = try std.fmt.allocPrint(arena, "postman-{s}", .{try safeName(arena, coll_name)}), .stubs = stubs.items };
}

fn walkItems(arena: Allocator, items: []const Value, prefix: []const u8, stubs: *std.ArrayListUnmanaged(Stub), counter: *usize) Allocator.Error!void {
    for (items) |item| {
        if (item != .object) continue;
        const name = str(item.object.get("name")) orelse "request";
        if (item.object.get("item")) |sub| if (sub == .array) {
            const p = try std.fmt.allocPrint(arena, "{s}{s}__", .{ prefix, try safeName(arena, name) });
            try walkItems(arena, sub.array.items, p, stubs, counter);
            continue;
        };
        const req = item.object.get("request") orelse continue;
        var method: []const u8 = "GET";
        var url: ?[]const u8 = null;
        var curl: std.ArrayListUnmanaged(u8) = .empty;
        switch (req) {
            .string => |s| url = s,
            .object => |o| {
                if (str(o.get("method"))) |m| method = try std.ascii.allocUpperString(arena, m);
                if (o.get("url")) |u| switch (u) {
                    .string => |s| url = s,
                    .object => |uo| url = str(uo.get("raw")) orelse try joinPostmanUrl(arena, uo),
                    else => {},
                };
            },
            else => continue,
        }
        const u = url orelse continue;
        try appendFmt(arena, &curl, "curl -X {s} '{s}'", .{ method, try escapeSingle(arena, u) });
        if (req == .object) {
            if (req.object.get("header")) |hs| if (hs == .array) {
                for (hs.array.items) |h| {
                    if (h != .object) continue;
                    if (h.object.get("disabled")) |d| if (d == .bool and d.bool) continue;
                    const key = str(h.object.get("key")) orelse continue;
                    const value = str(h.object.get("value")) orelse "";
                    try appendFmt(arena, &curl, " \\\n  -H '{s}: {s}'", .{ key, try escapeSingle(arena, value) });
                }
            };
            if (req.object.get("body")) |b| if (b == .object) {
                if (str(b.object.get("raw"))) |raw| {
                    try appendFmt(arena, &curl, " \\\n  --data-raw '{s}'", .{try escapeSingle(arena, raw)});
                } else if (b.object.get("urlencoded")) |ue| if (ue == .array) {
                    var body: std.ArrayListUnmanaged(u8) = .empty;
                    for (ue.array.items) |kv| {
                        if (kv != .object) continue;
                        if (body.items.len > 0) try body.append(arena, '&');
                        try appendFmt(arena, &body, "{s}={s}", .{ str(kv.object.get("key")) orelse "", str(kv.object.get("value")) orelse "" });
                    }
                    try appendFmt(arena, &curl, " \\\n  --data-raw '{s}'", .{try escapeSingle(arena, body.items)});
                };
            };
        }
        const stub_name = try std.fmt.allocPrint(arena, "{d:0>3}_{s}{s}", .{ counter.*, prefix, try safeName(arena, name) });
        counter.* += 1;
        try stubs.append(arena, .{ .name = stub_name, .curl = curl.items });
    }
}

fn joinPostmanUrl(arena: Allocator, uo: std.json.ObjectMap) Allocator.Error!?[]const u8 {
    const protocol = str(uo.get("protocol")) orelse "https";
    var host: std.ArrayListUnmanaged(u8) = .empty;
    if (uo.get("host")) |h| switch (h) {
        .string => |s| try host.appendSlice(arena, s),
        .array => |arr| for (arr.items, 0..) |part, i| {
            if (i > 0) try host.append(arena, '.');
            try host.appendSlice(arena, str(part) orelse "");
        },
        else => {},
    };
    if (host.items.len == 0) return null;
    var path: std.ArrayListUnmanaged(u8) = .empty;
    if (uo.get("path")) |p| switch (p) {
        .string => |s| try path.appendSlice(arena, s),
        .array => |arr| for (arr.items) |part| {
            try path.append(arena, '/');
            try path.appendSlice(arena, str(part) orelse "");
        },
        else => {},
    };
    return try std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ protocol, host.items, path.items });
}

fn appendFmt(a: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try list.appendSlice(a, s);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "har: one curl per entry, headers and body carried, dir from the first timestamp" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try har(arena.allocator(), "{\"log\":{\"entries\":[{\"startedDateTime\":\"2024-01-01T00:00:00Z\",\"request\":{\"method\":\"get\",\"url\":\"https://api.example.com/users\",\"headers\":[{\"name\":\":authority\",\"value\":\"x\"},{\"name\":\"Accept\",\"value\":\"*/*\"}]}},{\"request\":{\"method\":\"POST\",\"url\":\"https://api.example.com/items\",\"headers\":[],\"postData\":{\"text\":\"{\\\"a\\\":1}\"}}}]}}");
    try testing.expectEqualStrings("har-2024-01-01T00-00-00", out.dir);
    try testing.expectEqual(@as(usize, 2), out.stubs.len);
    try testing.expectEqualStrings("000_GET_users", out.stubs[0].name);
    try testing.expectEqualStrings("curl -X GET 'https://api.example.com/users' \\\n  -H 'Accept: */*'", out.stubs[0].curl);
    try testing.expect(std.mem.endsWith(u8, out.stubs[1].curl, "--data-raw '{\"a\":1}'"));
    try testing.expectError(error.NotAHar, har(arena.allocator(), "{}"));
    try testing.expectError(error.NotJson, har(arena.allocator(), "nope"));
}

test "postman: v2.1 items, folders flattened, url object joined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try postman(arena.allocator(), "{\"info\":{\"name\":\"TestColl\"},\"item\":[{\"name\":\"GetUsers\",\"request\":{\"method\":\"GET\",\"url\":{\"raw\":\"https://api.example.com/users\"},\"header\":[]}},{\"name\":\"Auth\",\"item\":[{\"name\":\"Login\",\"request\":{\"method\":\"post\",\"url\":{\"protocol\":\"https\",\"host\":[\"api\",\"x\",\"com\"],\"path\":[\"login\"]},\"header\":[{\"key\":\"Content-Type\",\"value\":\"application/json\"}],\"body\":{\"mode\":\"raw\",\"raw\":\"{\\\"u\\\":1}\"}}}]}]}");
    try testing.expectEqualStrings("postman-TestColl", out.dir);
    try testing.expectEqual(@as(usize, 2), out.stubs.len);
    try testing.expectEqualStrings("000_GetUsers", out.stubs[0].name);
    try testing.expect(std.mem.indexOf(u8, out.stubs[0].curl, "api.example.com/users") != null);
    try testing.expectEqualStrings("001_Auth__Login", out.stubs[1].name);
    try testing.expectEqualStrings("curl -X POST 'https://api.x.com/login' \\\n  -H 'Content-Type: application/json' \\\n  --data-raw '{\"u\":1}'", out.stubs[1].curl);
    try testing.expectError(error.NotAPostmanCollection, postman(arena.allocator(), "{\"log\":{}}"));
}
