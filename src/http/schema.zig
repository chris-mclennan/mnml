//! Response-body validation against a JSON Schema sidecar
//! (`<stem>.schema.json` beside the request file, or
//! `<file>.schema.json`). The subset: `type` (string or list),
//! `required`, `properties`, `additionalProperties: false`, `items`,
//! `enum`, `const`, `minimum` / `maximum` / `exclusiveMinimum` /
//! `exclusiveMaximum`, `minLength` / `maxLength`, `minItems` /
//! `maxItems`, `pattern` (as a plain substring — there is no regex
//! engine), `anyOf` / `oneOf` / `allOf`, `nullable`. Errors name the
//! path inside the body.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Status = enum { valid, invalid, no_sidecar, read_error, schema_parse_error, not_json };

pub const Result = struct {
    status: Status,
    /// `path: message` lines, on the arena the caller gave.
    errors: []const []const u8 = &.{},
    schema_path: ?[]const u8 = null,

    pub fn summary(self: Result, alloc: Allocator) Allocator.Error![]u8 {
        return switch (self.status) {
            .valid => alloc.dupe(u8, "✓ schema valid"),
            .invalid => std.fmt.allocPrint(alloc, "✗ {d} schema error(s)", .{self.errors.len}),
            .no_sidecar => alloc.dupe(u8, "no schema sidecar"),
            .read_error => alloc.dupe(u8, "schema: read error"),
            .schema_parse_error => alloc.dupe(u8, "schema: not valid JSON"),
            .not_json => alloc.dupe(u8, "schema: body is not JSON"),
        };
    }
};

/// `<stem>.schema.json` then `<file>.schema.json` beside `source`.
pub fn resolveSidecar(alloc: Allocator, io: Io, source: []const u8) Allocator.Error!?[]u8 {
    const dir = std.fs.path.dirname(source) orelse ".";
    const file = std.fs.path.basename(source);
    const stem = std.fs.path.stem(file);
    const cands = [_][]const u8{ stem, file };
    for (cands) |c| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}.schema.json", .{ dir, c });
        Io.Dir.cwd().access(io, path, .{}) catch {
            alloc.free(path);
            continue;
        };
        return path;
    }
    return null;
}

pub fn validateFile(arena: Allocator, io: Io, body: []const u8, schema_path: []const u8) Allocator.Error!Result {
    const text = Io.Dir.cwd().readFileAlloc(io, schema_path, arena, .limited(4 << 20)) catch return .{ .status = .read_error, .schema_path = schema_path };
    var r = try validate(arena, body, text);
    r.schema_path = schema_path;
    return r;
}

/// Validate `body` (JSON text) against `schema_text`.
pub fn validate(arena: Allocator, body: []const u8, schema_text: []const u8) Allocator.Error!Result {
    const schema = std.json.parseFromSliceLeaky(Value, arena, schema_text, .{}) catch return .{ .status = .schema_parse_error };
    const value = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch return .{ .status = .not_json };
    var errors: std.ArrayListUnmanaged([]const u8) = .empty;
    var path: std.ArrayListUnmanaged(u8) = .empty;
    try check(arena, &errors, &path, schema, value);
    return .{ .status = if (errors.items.len == 0) .valid else .invalid, .errors = errors.items };
}

fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "boolean",
        .integer, .number_string => "integer",
        .float => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn matchesType(v: Value, want: []const u8) bool {
    if (std.mem.eql(u8, want, "number")) return v == .integer or v == .float or v == .number_string;
    if (std.mem.eql(u8, want, "integer")) {
        if (v == .integer) return true;
        if (v == .float) return @floor(v.float) == v.float;
        return false;
    }
    return std.mem.eql(u8, typeName(v), want);
}

fn fail(arena: Allocator, errors: *std.ArrayListUnmanaged([]const u8), path: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const p: []const u8 = if (path.len == 0) "$" else path;
    const msg = try std.fmt.allocPrint(arena, "{s}: " ++ fmt, .{p} ++ args);
    try errors.append(arena, msg);
}

fn asFloat(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn check(arena: Allocator, errors: *std.ArrayListUnmanaged([]const u8), path: *std.ArrayListUnmanaged(u8), schema: Value, v: Value) Allocator.Error!void {
    const obj = switch (schema) {
        .object => |o| o,
        .bool => |b| {
            if (!b) try fail(arena, errors, path.items, "schema is false", .{});
            return;
        },
        else => return,
    };
    if (obj.get("nullable")) |n| if (n == .bool and n.bool and v == .null) return;
    if (obj.get("type")) |t| {
        var ok = false;
        switch (t) {
            .string => |s| ok = matchesType(v, s),
            .array => |arr| for (arr.items) |alt| if (alt == .string and matchesType(v, alt.string)) {
                ok = true;
            },
            else => ok = true,
        }
        if (!ok) {
            const want = switch (t) {
                .string => |s| s,
                else => "one of the listed types",
            };
            try fail(arena, errors, path.items, "expected {s}, got {s}", .{ want, typeName(v) });
            return;
        }
    }
    if (obj.get("const")) |c| if (!valueEql(c, v)) try fail(arena, errors, path.items, "does not equal the const", .{});
    if (obj.get("enum")) |e| if (e == .array) {
        var hit = false;
        for (e.array.items) |alt| if (valueEql(alt, v)) {
            hit = true;
        };
        if (!hit) try fail(arena, errors, path.items, "not one of the enum values", .{});
    };
    if (asFloat(v)) |n| {
        if (obj.get("minimum")) |m| if (asFloat(m)) |min| if (n < min) try fail(arena, errors, path.items, "{d} is below the minimum {d}", .{ n, min });
        if (obj.get("maximum")) |m| if (asFloat(m)) |max| if (n > max) try fail(arena, errors, path.items, "{d} is above the maximum {d}", .{ n, max });
        if (obj.get("exclusiveMinimum")) |m| if (asFloat(m)) |min| if (n <= min) try fail(arena, errors, path.items, "{d} is not above {d}", .{ n, min });
        if (obj.get("exclusiveMaximum")) |m| if (asFloat(m)) |max| if (n >= max) try fail(arena, errors, path.items, "{d} is not below {d}", .{ n, max });
    }
    switch (v) {
        .string => |s| {
            const len = std.unicode.utf8CountCodepoints(s) catch s.len;
            if (obj.get("minLength")) |m| if (m == .integer and len < @as(usize, @intCast(@max(m.integer, 0)))) try fail(arena, errors, path.items, "shorter than minLength {d}", .{m.integer});
            if (obj.get("maxLength")) |m| if (m == .integer and len > @as(usize, @intCast(@max(m.integer, 0)))) try fail(arena, errors, path.items, "longer than maxLength {d}", .{m.integer});
            if (obj.get("pattern")) |p| if (p == .string) {
                // No regex engine: a literal pattern (anchors stripped) must occur.
                const lit = std.mem.trim(u8, p.string, "^$");
                if (std.mem.indexOfAny(u8, lit, ".*+?[](){}|\\") == null and std.mem.indexOf(u8, s, lit) == null)
                    try fail(arena, errors, path.items, "does not match pattern {s}", .{p.string});
            };
        },
        .array => |arr| {
            if (obj.get("minItems")) |m| if (m == .integer and arr.items.len < @as(usize, @intCast(@max(m.integer, 0)))) try fail(arena, errors, path.items, "fewer than minItems {d}", .{m.integer});
            if (obj.get("maxItems")) |m| if (m == .integer and arr.items.len > @as(usize, @intCast(@max(m.integer, 0)))) try fail(arena, errors, path.items, "more than maxItems {d}", .{m.integer});
            if (obj.get("items")) |items| {
                for (arr.items, 0..) |item, i| {
                    const mark = path.items.len;
                    try appendFmt(arena, path, "[{d}]", .{i});
                    try check(arena, errors, path, items, item);
                    path.items.len = mark;
                }
            }
        },
        .object => |o| {
            if (obj.get("required")) |req| if (req == .array) {
                for (req.array.items) |r| if (r == .string and o.get(r.string) == null) {
                    try fail(arena, errors, path.items, "missing required property \"{s}\"", .{r.string});
                };
            };
            const props: ?std.json.ObjectMap = if (obj.get("properties")) |p| (if (p == .object) p.object else null) else null;
            if (props) |p| {
                var it = p.iterator();
                while (it.next()) |e| {
                    const child = o.get(e.key_ptr.*) orelse continue;
                    const mark = path.items.len;
                    try appendFmt(arena, path, "{s}{s}", .{ if (path.items.len == 0) "" else ".", e.key_ptr.* });
                    try check(arena, errors, path, e.value_ptr.*, child);
                    path.items.len = mark;
                }
            }
            if (obj.get("additionalProperties")) |ap| if (ap == .bool and !ap.bool) {
                var it = o.iterator();
                while (it.next()) |e| {
                    if (props != null and props.?.get(e.key_ptr.*) != null) continue;
                    try fail(arena, errors, path.items, "unexpected property \"{s}\"", .{e.key_ptr.*});
                }
            };
        },
        else => {},
    }
    if (obj.get("allOf")) |all| if (all == .array) {
        for (all.array.items) |sub| try check(arena, errors, path, sub, v);
    };
    if (obj.get("anyOf")) |any| if (any == .array) {
        if (!try anyMatch(arena, path, any.array.items, v, false)) try fail(arena, errors, path.items, "matches none of anyOf", .{});
    };
    if (obj.get("oneOf")) |one| if (one == .array) {
        if (!try anyMatch(arena, path, one.array.items, v, true)) try fail(arena, errors, path.items, "does not match exactly one of oneOf", .{});
    };
}

fn anyMatch(arena: Allocator, path: *std.ArrayListUnmanaged(u8), alts: []const Value, v: Value, exactly_one: bool) Allocator.Error!bool {
    var hits: usize = 0;
    for (alts) |alt| {
        var scratch: std.ArrayListUnmanaged([]const u8) = .empty;
        var sub_path: std.ArrayListUnmanaged(u8) = .empty;
        try sub_path.appendSlice(arena, path.items);
        try check(arena, &scratch, &sub_path, alt, v);
        if (scratch.items.len == 0) hits += 1;
    }
    return if (exactly_one) hits == 1 else hits >= 1;
}

fn valueEql(a: Value, b: Value) bool {
    if (asFloat(a)) |x| if (asFloat(b)) |y| return x == y;
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, b.string, x),
        .array => |x| blk: {
            if (b != .array or b.array.items.len != x.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!valueEql(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or b.object.count() != x.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!valueEql(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn appendFmt(a: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    defer a.free(s);
    try list.appendSlice(a, s);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "type / required / properties / items / enum / ranges / additionalProperties" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema =
        \\{"type":"object","required":["name","tags"],"additionalProperties":false,
        \\ "properties":{"name":{"type":"string","minLength":2},"age":{"type":"integer","minimum":0,"maximum":150},
        \\ "tags":{"type":"array","items":{"type":"string"},"minItems":1},"role":{"enum":["admin","user"]},
        \\ "opt":{"type":["string","null"]},"v":{"const":2},"pat":{"type":"string","pattern":"^abc"}}}
    ;
    const ok = try validate(a, "{\"name\":\"Bo\",\"age\":3,\"tags\":[\"x\"],\"role\":\"user\",\"opt\":null,\"v\":2,\"pat\":\"xabcx\"}", schema);
    try testing.expectEqual(Status.valid, ok.status);
    const bad = try validate(a, "{\"name\":42,\"age\":200,\"tags\":[1],\"role\":\"root\",\"extra\":1,\"v\":3,\"pat\":\"nope\"}", schema);
    try testing.expectEqual(Status.invalid, bad.status);
    const joined = try std.mem.join(a, "\n", bad.errors);
    try testing.expect(std.mem.indexOf(u8, joined, "name: expected string, got integer") != null);
    try testing.expect(std.mem.indexOf(u8, joined, "age: 200 is above the maximum 150") != null);
    try testing.expect(std.mem.indexOf(u8, joined, "tags[0]: expected string") != null);
    try testing.expect(std.mem.indexOf(u8, joined, "role: not one of the enum") != null);
    try testing.expect(std.mem.indexOf(u8, joined, "unexpected property \"extra\"") != null);
    try testing.expect(std.mem.indexOf(u8, joined, "v: does not equal the const") != null);
    try testing.expect(std.mem.indexOf(u8, joined, "pat: does not match pattern") != null);
    const missing = try validate(a, "{\"name\":42}", "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}");
    try testing.expectEqual(@as(usize, 1), missing.errors.len);
    try testing.expectEqualStrings("name: expected string, got integer", missing.errors[0]);
    try testing.expectEqual(Status.not_json, (try validate(a, "nope", "{}")).status);
    try testing.expectEqual(Status.schema_parse_error, (try validate(a, "{}", "{")).status);
    const any = try validate(a, "5", "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}");
    try testing.expectEqual(Status.valid, any.status);
    const one = try validate(a, "5", "{\"oneOf\":[{\"type\":\"number\"},{\"type\":\"integer\"}]}");
    try testing.expectEqual(Status.invalid, one.status);
    const s = try (Result{ .status = .invalid, .errors = bad.errors }).summary(a);
    try testing.expect(std.mem.startsWith(u8, s, "✗ 7 schema error(s)"));
}

test "resolveSidecar tries the stem then the full file name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    const src = try std.fs.path.join(testing.allocator, &.{ ws, "users.curl" });
    defer testing.allocator.free(src);
    try testing.expect((try resolveSidecar(testing.allocator, testing.io, src)) == null);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.curl.schema.json", .data = "{}" });
    const full = (try resolveSidecar(testing.allocator, testing.io, src)).?;
    defer testing.allocator.free(full);
    try testing.expect(std.mem.endsWith(u8, full, "users.curl.schema.json"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.schema.json", .data = "{}" });
    const stem = (try resolveSidecar(testing.allocator, testing.io, src)).?;
    defer testing.allocator.free(stem);
    try testing.expect(std.mem.endsWith(u8, stem, "/users.schema.json"));
}
