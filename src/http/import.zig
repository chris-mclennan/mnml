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

pub const Var = struct { key: []const u8, value: []const u8 };

pub const Import = struct {
    /// The directory stem: `har-<timestamp>` / `postman-<collection>`.
    dir: []const u8,
    stubs: []const Stub,
    /// A Postman collection's `variable[]` (enabled ones) — the values
    /// its `{{baseUrl}}`-style references resolve to.
    vars: []const Var = &.{},
    /// Requests whose auth type has no curl shape here (digest, hawk,
    /// aws, ntlm …) — imported without it, and counted so the caller
    /// can say so.
    unimported_auth: usize = 0,
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
    var unimported: usize = 0;
    try walkItems(arena, items.array.items, "", &stubs, &counter, root.object.get("auth"), &unimported);
    var vars: std.ArrayListUnmanaged(Var) = .empty;
    if (root.object.get("variable")) |vs| if (vs == .array) for (vs.array.items) |v| {
        if (v != .object or isDisabled(v)) continue;
        const key = str(v.object.get("key")) orelse continue;
        const value: []const u8 = switch (v.object.get("value") orelse .null) {
            .string => |x| x,
            .null => "",
            else => |x| try std.json.Stringify.valueAlloc(arena, x, .{}),
        };
        try vars.append(arena, .{ .key = key, .value = value });
    };
    return .{ .dir = try std.fmt.allocPrint(arena, "postman-{s}", .{try safeName(arena, coll_name)}), .stubs = stubs.items, .vars = vars.items, .unimported_auth = unimported };
}

fn isDisabled(v: Value) bool {
    if (v != .object) return false;
    const d = v.object.get("disabled") orelse return false;
    return d == .bool and d.bool;
}

/// The value of `key` in a Postman auth type's `[{key, value}]` list.
fn authField(auth: Value, kind: []const u8, key: []const u8) ?[]const u8 {
    const list = auth.object.get(kind) orelse return null;
    if (list == .object) return str(list.object.get(key)); // v2.0's `{key: value}`
    if (list != .array) return null;
    for (list.array.items) |kv| if (kv == .object) if (str(kv.object.get("key"))) |k| if (std.mem.eql(u8, k, key)) return str(kv.object.get("value"));
    return null;
}

/// The curl flags a Postman `auth` object stands for; `query` gets an
/// apikey that rides on the URL. `noauth` is none. False for a type
/// with no curl shape here.
fn authFlags(arena: Allocator, auth: ?Value, curl: *std.ArrayListUnmanaged(u8), query: *?[]const u8) Allocator.Error!bool {
    const a = auth orelse return true;
    if (a != .object) return true;
    const kind = str(a.object.get("type")) orelse return true;
    if (std.mem.eql(u8, kind, "noauth")) return true;
    if (std.mem.eql(u8, kind, "bearer")) {
        try appendFmt(arena, curl, " \\\n  -H 'Authorization: Bearer {s}'", .{try escapeSingle(arena, authField(a, "bearer", "token") orelse "")});
    } else if (std.mem.eql(u8, kind, "basic")) {
        const user = authField(a, "basic", "username") orelse "";
        const pass = authField(a, "basic", "password") orelse "";
        try appendFmt(arena, curl, " \\\n  -u '{s}:{s}'", .{ try escapeSingle(arena, user), try escapeSingle(arena, pass) });
    } else if (std.mem.eql(u8, kind, "apikey")) {
        const key = authField(a, "apikey", "key") orelse return true;
        const value = authField(a, "apikey", "value") orelse "";
        if (std.mem.eql(u8, authField(a, "apikey", "in") orelse "header", "query")) {
            query.* = try std.fmt.allocPrint(arena, "{s}={s}", .{ key, value });
        } else try appendFmt(arena, curl, " \\\n  -H '{s}: {s}'", .{ try escapeSingle(arena, key), try escapeSingle(arena, value) });
    } else if (std.mem.eql(u8, kind, "oauth2")) {
        const tok = authField(a, "oauth2", "accessToken") orelse return true;
        try appendFmt(arena, curl, " \\\n  -H 'Authorization: Bearer {s}'", .{try escapeSingle(arena, tok)});
    } else return false; // digest, hawk, aws, ntlm …: said, not guessed.
    return true;
}

/// `auth` is the nearest folder's (or the collection's) — what a
/// request without its own inherits, as Postman does.
fn walkItems(arena: Allocator, items: []const Value, prefix: []const u8, stubs: *std.ArrayListUnmanaged(Stub), counter: *usize, auth: ?Value, unimported: *usize) Allocator.Error!void {
    for (items) |item| {
        if (item != .object) continue;
        const name = str(item.object.get("name")) orelse "request";
        if (item.object.get("item")) |sub| if (sub == .array) {
            const p = try std.fmt.allocPrint(arena, "{s}{s}__", .{ prefix, try safeName(arena, name) });
            try walkItems(arena, sub.array.items, p, stubs, counter, item.object.get("auth") orelse auth, unimported);
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
        var u = url orelse continue;
        var auth_query: ?[]const u8 = null;
        var auth_flags: std.ArrayListUnmanaged(u8) = .empty;
        if (!try authFlags(arena, if (req == .object) (req.object.get("auth") orelse auth) else auth, &auth_flags, &auth_query)) unimported.* += 1;
        if (auth_query) |q| u = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ u, if (std.mem.indexOfScalar(u8, u, '?') == null) "?" else "&", q });
        try appendFmt(arena, &curl, "curl -X {s} '{s}'", .{ method, try escapeSingle(arena, u) });
        try curl.appendSlice(arena, auth_flags.items);
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
                } else if (b.object.get("urlencoded")) |ue| {
                    // One `--data-urlencode` per enabled row: the value
                    // is encoded on the way out, not pasted raw.
                    if (ue == .array) for (ue.array.items) |kv| {
                        if (kv != .object or isDisabled(kv)) continue;
                        const key = str(kv.object.get("key")) orelse continue;
                        try appendFmt(arena, &curl, " \\\n  --data-urlencode '{s}={s}'", .{ try escapeSingle(arena, key), try escapeSingle(arena, str(kv.object.get("value")) orelse "") });
                    };
                } else if (b.object.get("formdata")) |fd| {
                    if (fd == .array) for (fd.array.items) |kv| {
                        if (kv != .object or isDisabled(kv)) continue;
                        const key = str(kv.object.get("key")) orelse continue;
                        const is_file = std.mem.eql(u8, str(kv.object.get("type")) orelse "text", "file");
                        const value = if (is_file) (str(kv.object.get("src")) orelse "") else (str(kv.object.get("value")) orelse "");
                        try appendFmt(arena, &curl, " \\\n  -F '{s}={s}{s}'", .{ try escapeSingle(arena, key), if (is_file) "@" else "", try escapeSingle(arena, value) });
                    };
                }
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

test "postman: auth (collection, folder, request), formdata, disabled rows and collection variables come across" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try postman(arena.allocator(),
        \\{"info":{"name":"Shop"},"auth":{"type":"bearer","bearer":[{"key":"token","value":"{{TOKEN}}"}]},
        \\ "variable":[{"key":"baseUrl","value":"http://127.0.0.1:9"},{"key":"old","value":"x","disabled":true}],
        \\ "item":[
        \\  {"name":"Upload","request":{"method":"POST","header":[],"url":{"raw":"{{baseUrl}}/echo"},"body":{"mode":"formdata","formdata":[{"key":"title","value":"hello","type":"text"},{"key":"pic","src":"cat.png","type":"file"},{"key":"skip","value":"1","disabled":true}]}}},
        \\  {"name":"Login","request":{"method":"POST","auth":{"type":"basic","basic":[{"key":"username","value":"user"},{"key":"password","value":"pass"}]},"header":[{"key":"X-Off","value":"1","disabled":true}],"url":{"raw":"{{baseUrl}}/basic"},"body":{"mode":"urlencoded","urlencoded":[{"key":"a","value":"1"},{"key":"debug","value":"true","disabled":true},{"key":"q","value":"new york"}]}}},
        \\  {"name":"Public","item":[{"name":"Health","request":{"method":"GET","url":"{{baseUrl}}/health"}}],"auth":{"type":"noauth"}},
        \\  {"name":"Keyed","request":{"method":"GET","auth":{"type":"apikey","apikey":[{"key":"key","value":"api_key"},{"key":"value","value":"{{KEY}}"},{"key":"in","value":"query"}]},"url":"{{baseUrl}}/k"}}
        \\ ]}
    );
    try testing.expectEqual(@as(usize, 4), out.stubs.len);
    const upload = out.stubs[0].curl;
    try testing.expect(std.mem.indexOf(u8, upload, "-H 'Authorization: Bearer {{TOKEN}}'") != null);
    try testing.expect(std.mem.indexOf(u8, upload, "-F 'title=hello'") != null);
    try testing.expect(std.mem.indexOf(u8, upload, "-F 'pic=@cat.png'") != null);
    try testing.expect(std.mem.indexOf(u8, upload, "skip") == null);
    const login = out.stubs[1].curl;
    try testing.expect(std.mem.indexOf(u8, login, "-u 'user:pass'") != null);
    try testing.expect(std.mem.indexOf(u8, login, "Bearer") == null);
    try testing.expect(std.mem.indexOf(u8, login, "--data-urlencode 'a=1'") != null);
    try testing.expect(std.mem.indexOf(u8, login, "--data-urlencode 'q=new york'") != null);
    try testing.expect(std.mem.indexOf(u8, login, "debug") == null);
    try testing.expect(std.mem.indexOf(u8, login, "X-Off") == null);
    try testing.expect(std.mem.indexOf(u8, out.stubs[2].curl, "Authorization") == null);
    try testing.expect(std.mem.indexOf(u8, out.stubs[3].curl, "'{{baseUrl}}/k?api_key={{KEY}}'") != null);
    try testing.expectEqual(@as(usize, 1), out.vars.len);
    try testing.expectEqualStrings("baseUrl", out.vars[0].key);
    // What parses back: the form rows become a body type the sender encodes.
    var req = try @import("parse.zig").parse(testing.allocator, login);
    defer req.deinit(testing.allocator);
    try testing.expectEqual(@import("parse.zig").BodyType.form, @import("parse.zig").bodyType(&req));
    try testing.expect(std.mem.startsWith(u8, req.header("authorization").?, "Basic "));
}
