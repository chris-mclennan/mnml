//! Request chains: `.chain.json` is a JSON array of steps, each a
//! request file (relative to the chain, then `<ws>/.mnml/requests/`,
//! then the workspace) and an optional `extract` map binding a variable
//! to a JSON path into the response (`$.a.b[0]` or `.a.b`). Extracted
//! values feed the later steps' `{{VAR}}`. The chain stops at the first
//! transport error, non-2xx/3xx status, or extraction that finds nothing.
//!
//!   [ { "request": "auth/login.curl", "extract": { "TOKEN": "$.access_token" } },
//!     { "request": "merchant/get-locations.curl" } ]

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse_mod = @import("parse.zig");
const client = @import("client.zig");
const body_mod = @import("body.zig");
const env_mod = @import("env.zig");
const script_mod = @import("script.zig");

pub const Extract = struct { name: []const u8, path: []const u8 };

pub const Step = struct {
    request: []const u8,
    extract: []const Extract,
};

pub const Chain = struct {
    steps: []const Step,
    /// Per-step keys the parser does not know (`if`, `retry`…).
    unknown_keys: []const []const u8,
};

pub const ParseError = error{ NotJson, NotAnArray, StepMissingRequest } || Allocator.Error;

/// Everything on `arena`.
pub fn parse(arena: Allocator, text: []const u8) ParseError!Chain {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.NotJson;
    if (v != .array) return error.NotAnArray;
    var steps: std.ArrayListUnmanaged(Step) = .empty;
    var unknown: std.ArrayListUnmanaged([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item != .object) return error.StepMissingRequest;
        const req = item.object.get("request") orelse return error.StepMissingRequest;
        if (req != .string) return error.StepMissingRequest;
        var ex: std.ArrayListUnmanaged(Extract) = .empty;
        if (item.object.get("extract")) |e| if (e == .object) {
            var it = e.object.iterator();
            while (it.next()) |kv| if (kv.value_ptr.* == .string) try ex.append(arena, .{ .name = kv.key_ptr.*, .path = kv.value_ptr.string });
        };
        var it = item.object.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            if (std.mem.eql(u8, k, "request") or std.mem.eql(u8, k, "extract")) continue;
            var seen = false;
            for (unknown.items) |u| if (std.mem.eql(u8, u, k)) {
                seen = true;
                break;
            };
            if (!seen) try unknown.append(arena, k);
        }
        try steps.append(arena, .{ .request = req.string, .extract = ex.items });
    }
    return .{ .steps = steps.items, .unknown_keys = unknown.items };
}

/// Resolve a step's request path: absolute → beside the chain →
/// `<ws>/.mnml/requests/` → the workspace.
pub fn resolveRequestPath(arena: Allocator, io: Io, step_request: []const u8, chain_dir: []const u8, workspace: []const u8) Allocator.Error!?[]const u8 {
    if (std.fs.path.isAbsolute(step_request)) {
        Io.Dir.cwd().access(io, step_request, .{}) catch return null;
        return step_request;
    }
    const cands = [_][]const u8{
        try std.fs.path.join(arena, &.{ chain_dir, step_request }),
        try std.fs.path.join(arena, &.{ workspace, ".mnml", "requests", step_request }),
        try std.fs.path.join(arena, &.{ workspace, step_request }),
    };
    for (cands) |c| {
        Io.Dir.cwd().access(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

/// `$.a.b[0]` / `.a.b` / `a.b` into a parsed JSON value; scalars come
/// back as text, containers re-serialised.
pub fn resolveJsonPath(arena: Allocator, root: std.json.Value, path_in: []const u8) Allocator.Error!?[]const u8 {
    var path = path_in;
    if (std.mem.startsWith(u8, path, "$")) path = path[1..];
    var cur = root;
    var it = std.mem.tokenizeScalar(u8, path, '.');
    while (it.next()) |seg_full| {
        var seg = seg_full;
        while (seg.len > 0) {
            const br = std.mem.indexOfScalar(u8, seg, '[');
            const key = if (br) |b| seg[0..b] else seg;
            if (key.len > 0) {
                if (cur != .object) return null;
                cur = cur.object.get(key) orelse return null;
            }
            if (br == null) break;
            const close = std.mem.indexOfScalarPos(u8, seg, br.?, ']') orelse return null;
            const idx = std.fmt.parseInt(usize, seg[br.? + 1 .. close], 10) catch return null;
            if (cur != .array or idx >= cur.array.items.len) return null;
            cur = cur.array.items[idx];
            seg = seg[close + 1 ..];
        }
    }
    return switch (cur) {
        .string => |s| s,
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        .integer, .float, .number_string => try std.json.Stringify.valueAlloc(arena, cur, .{}),
        .array, .object => try std.json.Stringify.valueAlloc(arena, cur, .{}),
    };
}

pub const RunResult = struct {
    ok: bool,
    /// Why it stopped, when it did.
    err: ?[]u8,
    /// The step-by-step trace.
    trace: []u8,
    /// Variables captured along the way (`KEY=VALUE` lines).
    captured: []u8,

    pub fn deinit(self: *RunResult, gpa: Allocator) void {
        if (self.err) |e| gpa.free(e);
        gpa.free(self.trace);
        gpa.free(self.captured);
    }
};

/// Run the chain at `chain_path` against `env_name`.
pub fn run(gpa: Allocator, io: Io, chain_path: []const u8, workspace: []const u8, env_name: []const u8) !RunResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var trace: std.ArrayListUnmanaged(u8) = .empty;
    var captured: std.ArrayListUnmanaged(u8) = .empty;
    const text = try Io.Dir.cwd().readFileAlloc(io, chain_path, a, .limited(4 << 20));
    const chain = parse(a, text) catch |err| {
        return finish(gpa, false, try std.fmt.allocPrint(gpa, "parse chain: {s}", .{@errorName(err)}), &trace, &captured);
    };
    if (chain.steps.len == 0) return finish(gpa, false, try gpa.dupe(u8, "chain has no steps"), &trace, &captured);
    for (chain.unknown_keys) |k| try appendFmt(a, &trace, "note: unknown step key \"{s}\" is ignored\n", .{k});
    var set = try env_mod.EnvSet.load(a, io, workspace, env_name);
    const chain_dir = std.fs.path.dirname(chain_path) orelse ".";
    for (chain.steps, 0..) |step, i| {
        const path = (try resolveRequestPath(a, io, step.request, chain_dir, workspace)) orelse {
            return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: {s} not found", .{ i + 1, step.request }), &trace, &captured);
        };
        const src = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20));
        var raw = parse_mod_parse(a, src) catch |err| {
            return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: {s}: {s}", .{ i + 1, step.request, @errorName(err) }), &trace, &captured);
        };
        // The step's own directives: `@set-*` before the send, `@assert`
        // and `@capture` after it, captures feeding the later steps.
        const script = try script_mod.parse(a, raw.script orelse "");
        try script_mod.applyPre(a, &raw, &set, script);
        var req = try expandWith(a, io, &raw, &set);
        // The same wire body the pane and `mnml-zig run` send.
        var missing: ?[]const u8 = null;
        body_mod.encode(a, io, &req, .{ .base_dir = std.fs.path.dirname(path) orelse chain_dir }, &missing) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: multipart: no file at {s}", .{ i + 1, missing orelse "?" }), &trace, &captured),
        };
        var outcome = try client.send(a, io, &req, .{});
        switch (outcome) {
            .err => |e| {
                try appendFmt(a, &trace, "{d}. {s} {s} → ERR {s}\n", .{ i + 1, req.method, req.url, e });
                return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: {s}", .{ i + 1, e }), &trace, &captured);
            },
            .ok => |*resp| {
                try appendFmt(a, &trace, "{d}. {s} {s} → {d} ({d} ms, {d} B)\n", .{ i + 1, req.method, req.url, resp.status, resp.timing.total_ms, resp.body.len });
                if (resp.status >= 400) return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: status {d}", .{ i + 1, resp.status }), &trace, &captured);
                for (try script_mod.runAsserts(a, script, resp.status, resp.headers, resp.body)) |r| {
                    if (r.ok) {
                        try appendFmt(a, &trace, "   ✓ {s}\n", .{r.label});
                    } else {
                        try appendFmt(a, &trace, "   ✗ {s} — {s}\n", .{ r.label, r.detail });
                        return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: assert failed: {s}", .{ i + 1, r.label }), &trace, &captured);
                    }
                }
                for (try script_mod.runCaptures(a, script, resp.status, resp.headers, resp.body)) |c| {
                    const value = c.value orelse return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: capture {s} found nothing", .{ i + 1, c.name }), &trace, &captured);
                    try set.put(c.name, value);
                    try appendFmt(a, &trace, "   {s} = {s}\n", .{ c.name, value });
                    try appendFmt(a, &captured, "{s}={s}\n", .{ c.name, value });
                }
                if (step.extract.len > 0) {
                    const body = std.json.parseFromSliceLeaky(std.json.Value, a, resp.body, .{}) catch {
                        return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: body is not JSON, cannot extract", .{i + 1}), &trace, &captured);
                    };
                    for (step.extract) |ex| {
                        const value = (try resolveJsonPath(a, body, ex.path)) orelse {
                            return finish(gpa, false, try std.fmt.allocPrint(gpa, "step {d}: {s} found nothing at {s}", .{ i + 1, ex.name, ex.path }), &trace, &captured);
                        };
                        try set.put(ex.name, value);
                        try appendFmt(a, &trace, "   {s} = {s}\n", .{ ex.name, value });
                        try appendFmt(a, &captured, "{s}={s}\n", .{ ex.name, value });
                    }
                }
            },
            .moved => {},
        }
    }
    return finish(gpa, true, null, &trace, &captured);
}

fn parse_mod_parse(a: Allocator, src: []const u8) parse_mod.ParseError!parse_mod.Request {
    return parse_mod.parse(a, src);
}

fn expandWith(a: Allocator, io: Io, req: *const parse_mod.Request, set: *const env_mod.EnvSet) Allocator.Error!parse_mod.Request {
    var out = try req.clone(a);
    out.url = try env_mod.expand(a, io, try parse_mod.substitutePath(a, req.url, try parse_mod.pathParams(a, req)), set);
    for (out.headers.items) |*h| h.value = try env_mod.expand(a, io, h.value, set);
    if (out.body) |b| out.body = try env_mod.expand(a, io, b, set);
    return out;
}

fn finish(gpa: Allocator, ok: bool, err: ?[]u8, trace: *std.ArrayListUnmanaged(u8), captured: *std.ArrayListUnmanaged(u8)) Allocator.Error!RunResult {
    errdefer if (err) |e| gpa.free(e);
    const t = try gpa.dupe(u8, trace.items);
    errdefer gpa.free(t);
    return .{ .ok = ok, .err = err, .trace = t, .captured = try gpa.dupe(u8, captured.items) };
}

fn appendFmt(a: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    try list.appendSlice(a, s);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const mock = @import("mock.zig");

test "parse: steps, extracts, unknown keys; json path resolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a, "[{\"request\":\"a.curl\",\"extract\":{\"TOKEN\":\"$.access_token\"},\"retry\":3},{\"request\":\"b.curl\"}]");
    try testing.expectEqual(@as(usize, 2), c.steps.len);
    try testing.expectEqualStrings("TOKEN", c.steps[0].extract[0].name);
    try testing.expectEqualStrings("retry", c.unknown_keys[0]);
    try testing.expectError(error.NotAnArray, parse(a, "{}"));
    try testing.expectError(error.StepMissingRequest, parse(a, "[{}]"));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"a\":{\"b\":[{\"id\":7,\"n\":\"x\"}]},\"t\":true}", .{});
    try testing.expectEqualStrings("7", (try resolveJsonPath(a, v, "$.a.b[0].id")).?);
    try testing.expectEqualStrings("x", (try resolveJsonPath(a, v, ".a.b[0].n")).?);
    try testing.expectEqualStrings("true", (try resolveJsonPath(a, v, "t")).?);
    try testing.expect((try resolveJsonPath(a, v, "$.a.zz")) == null);
    try testing.expect((try resolveJsonPath(a, v, "$.a.b[9]")) == null);
}

test "run: two steps over a local server, the first's extract feeds the second" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pbuf);
    const ws = pbuf[0..n];
    var server = try mock.Server.start(testing.allocator, io, .{ .body = "{\"access_token\":\"tok9\",\"items\":[{\"id\":1}]}", .headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    defer server.stop(io);
    try tmp.dir.createDirPath(io, ".mnml/chains");
    try tmp.dir.createDirPath(io, ".mnml/requests");
    const login = try std.fmt.allocPrint(testing.allocator, "curl 'http://127.0.0.1:{d}/login'\n", .{server.port});
    defer testing.allocator.free(login);
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/requests/login.curl", .data = login });
    const list = try std.fmt.allocPrint(testing.allocator, "curl 'http://127.0.0.1:{d}/list' -H 'Authorization: Bearer {{{{TOKEN}}}}'\n", .{server.port});
    defer testing.allocator.free(list);
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/requests/list.curl", .data = list });
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/chains/flow.chain.json", .data = "[{\"request\":\"login.curl\",\"extract\":{\"TOKEN\":\"$.access_token\"}},{\"request\":\"list.curl\"}]" });
    const chain_path = try std.fs.path.join(testing.allocator, &.{ ws, ".mnml/chains/flow.chain.json" });
    defer testing.allocator.free(chain_path);
    var out = try run(testing.allocator, io, chain_path, ws, "dev");
    defer out.deinit(testing.allocator);
    try testing.expect(out.ok);
    try testing.expect(std.mem.indexOf(u8, out.trace, "TOKEN = tok9") != null);
    try testing.expectEqualStrings("TOKEN=tok9\n", out.captured);
    try testing.expect(std.ascii.indexOfIgnoreCase(server.lastRequest(), "authorization: Bearer tok9") != null);
    // A missing extract stops the chain.
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/chains/bad.chain.json", .data = "[{\"request\":\"login.curl\",\"extract\":{\"X\":\"$.nope\"}},{\"request\":\"list.curl\"}]" });
    const bad_path = try std.fs.path.join(testing.allocator, &.{ ws, ".mnml/chains/bad.chain.json" });
    defer testing.allocator.free(bad_path);
    var bad = try run(testing.allocator, io, bad_path, ws, "dev");
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
    try testing.expect(std.mem.indexOf(u8, bad.err.?, "found nothing") != null);
}

test "run: a step's directives — @set-var feeds its headers, @assert gates the chain, @capture feeds the next step" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pbuf);
    const ws = pbuf[0..n];
    var server = try mock.Server.start(testing.allocator, io, .{ .body = "{\"session\":\"s-42\"}", .headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "x-trace", .value = "abc123" } } });
    defer server.stop(io);
    try tmp.dir.createDirPath(io, ".mnml/chains");
    try tmp.dir.createDirPath(io, ".mnml/requests");
    const first = try std.fmt.allocPrint(testing.allocator, "# @set-var PROBE = yes\n# @set-header X-Probe = {{{{PROBE}}}}\n# @assert status == 200\n# @assert header.x-trace ~ /^[a-z0-9]+$/\n# @capture SESSION = body.session\ncurl 'http://127.0.0.1:{d}/one'\n", .{server.port});
    defer testing.allocator.free(first);
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/requests/one.curl", .data = first });
    const second = try std.fmt.allocPrint(testing.allocator, "# @assert body.session != nope\ncurl 'http://127.0.0.1:{d}/two' -H 'Cookie: sid={{{{SESSION}}}}'\n", .{server.port});
    defer testing.allocator.free(second);
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/requests/two.curl", .data = second });
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/chains/d.chain.json", .data = "[{\"request\":\"one.curl\"},{\"request\":\"two.curl\"}]" });
    const chain_path = try std.fs.path.join(testing.allocator, &.{ ws, ".mnml/chains/d.chain.json" });
    defer testing.allocator.free(chain_path);
    var out = try run(testing.allocator, io, chain_path, ws, "dev");
    defer out.deinit(testing.allocator);
    try testing.expect(out.ok);
    try testing.expect(std.mem.indexOf(u8, out.trace, "✓ status == 200") != null);
    try testing.expect(std.mem.indexOf(u8, out.trace, "SESSION = s-42") != null);
    try testing.expectEqualStrings("SESSION=s-42\n", out.captured);
    try testing.expect(std.ascii.indexOfIgnoreCase(server.lastRequest(), "cookie: sid=s-42") != null);
    // A failing assert stops the chain before the next step.
    const failing = try std.fmt.allocPrint(testing.allocator, "# @assert status == 201\ncurl 'http://127.0.0.1:{d}/one'\n", .{server.port});
    defer testing.allocator.free(failing);
    try tmp.dir.writeFile(io, .{ .sub_path = ".mnml/requests/one.curl", .data = failing });
    var bad = try run(testing.allocator, io, chain_path, ws, "dev");
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
    try testing.expect(std.mem.indexOf(u8, bad.err.?, "assert failed: status == 201") != null);
    try testing.expect(std.mem.indexOf(u8, bad.trace, "got 200") != null);
    try testing.expect(std.mem.indexOf(u8, bad.trace, "2. ") == null);
}
