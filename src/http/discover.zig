//! `discover`: an OpenAPI 3 / Swagger 2 spec (JSON, or the YAML
//! subset in `yaml.zig`; a file or a URL) → one `.curl` stub per
//! operation under `<out>/<tag>/<operationId>.curl`. Path parameters
//! become `{{name}}`, required query / header parameters ride along
//! (`{{name}}` unless the spec gives an example / default / enum), a
//! JSON body comes from the example, from each named example (one stub
//! apiece), or is synthesised from the schema (`$ref`-resolving, cycle
//! safe, depth capped). `normalize` swaps ISO timestamps and UUIDs in
//! bodies for `{{$isoTimestamp}}` / `{{$uuid}}` so a re-sync is
//! byte-stable. A login-shaped POST gets `# extract: TOKEN=$.access_token`
//! and a `.chain.json` starter per tag.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const yaml = @import("yaml.zig");
const client = @import("client.zig");
const parse = @import("parse.zig");

pub const Options = struct {
    /// A path or an `http(s)://` URL.
    spec: []const u8,
    /// The stub tree's root.
    out: []const u8,
    /// Overrides `servers[0].url` (else `{{BASE_URL}}`).
    base_url: ?[]const u8 = null,
    normalize: bool = false,
    /// Overwrite stubs that already exist.
    force: bool = false,
};

pub const Result = struct { written: usize, skipped: usize };

pub const Error = error{ SpecUnreadable, SpecNotJsonOrYaml, NoPaths, FetchFailed, WriteFailed } || Allocator.Error;

/// A stub before it is written.
pub const Stub = struct {
    /// `tag/name.curl`, workspace-relative to `out`.
    rel: []const u8,
    text: []const u8,
};

/// Read the spec text from disk or the network.
pub fn loadSpecText(gpa: Allocator, io: Io, spec: []const u8) Error![]u8 {
    if (std.mem.startsWith(u8, spec, "http://") or std.mem.startsWith(u8, spec, "https://")) {
        var req = try parse.Request.init(gpa);
        defer req.deinit(gpa);
        try req.setUrl(gpa, spec);
        try req.addHeader(gpa, "accept", "application/json");
        var outcome = try client.send(gpa, io, &req, .{});
        defer outcome.deinit(gpa);
        return switch (outcome) {
            .ok => |r| if (r.status >= 200 and r.status < 300) try gpa.dupe(u8, r.body) else error.FetchFailed,
            else => error.FetchFailed,
        };
    }
    return Io.Dir.cwd().readFileAlloc(io, spec, gpa, .limited(64 << 20)) catch return error.SpecUnreadable;
}

/// JSON first, then YAML.
pub fn parseSpec(arena: Allocator, text: []const u8) Error!Value {
    if (std.json.parseFromSliceLeaky(Value, arena, text, .{})) |v| return v else |_| {}
    return yaml.parse(arena, text) catch return error.SpecNotJsonOrYaml;
}

/// Every stub the spec yields, on `arena`, nothing written.
pub fn generate(arena: Allocator, spec: Value, opts: Options) Error![]Stub {
    if (spec != .object) return error.NoPaths;
    const root = spec.object;
    const base_url = blk: {
        if (opts.base_url) |b| break :blk std.mem.trimEnd(u8, b, "/");
        if (root.get("servers")) |s| if (s == .array and s.array.items.len > 0) if (str(s.array.items[0], "url")) |u| break :blk std.mem.trimEnd(u8, try serverUrl(arena, u, get(s.array.items[0], &.{"variables"})), "/");
        if (str(spec, "host")) |host| {
            const base = str(spec, "basePath") orelse "";
            var scheme: []const u8 = "https";
            if (root.get("schemes")) |sc| if (sc == .array and sc.array.items.len > 0 and sc.array.items[0] == .string) {
                scheme = sc.array.items[0].string;
            };
            break :blk std.mem.trimEnd(u8, try std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ scheme, host, base }), "/");
        }
        break :blk "{{BASE_URL}}";
    };
    const paths = root.get("paths") orelse return error.NoPaths;
    if (paths != .object) return error.NoPaths;
    var stubs: std.ArrayListUnmanaged(Stub) = .empty;
    var login_by_tag: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var first_by_tag: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var pit = paths.object.iterator();
    while (pit.next()) |pe| {
        const path = pe.key_ptr.*;
        if (pe.value_ptr.* != .object) continue;
        var mit = pe.value_ptr.object.iterator();
        while (mit.next()) |me| {
            const method = me.key_ptr.*;
            if (!parse.isMethod(method)) continue;
            const op = me.value_ptr.*;
            if (op != .object) continue;
            const folder = blk: {
                if (op.object.get("tags")) |t| if (t == .array and t.array.items.len > 0 and t.array.items[0] == .string) break :blk try sanitize(arena, t.array.items[0].string);
                break :blk "untagged";
            };
            const file_base = if (str(op, "operationId")) |oid| try sanitize(arena, oid) else try sanitize(arena, try std.fmt.allocPrint(arena, "{s}-{s}", .{ try std.ascii.allocLowerString(arena, method), path }));
            const is_login = isLoginShaped(path, method);
            const named = try namedExamples(arena, op);
            if (named.len == 0) {
                const text = try renderCurl(arena, base_url, path, method, op, spec, null, opts.normalize);
                const rel = try std.fmt.allocPrint(arena, "{s}/{s}.curl", .{ folder, file_base });
                try stubs.append(arena, .{ .rel = rel, .text = text });
                if (is_login and login_by_tag.get(folder) == null) try login_by_tag.put(arena, folder, rel);
                if (!is_login and first_by_tag.get(folder) == null) try first_by_tag.put(arena, folder, rel);
            } else for (named) |n| {
                const text = try renderCurl(arena, base_url, path, method, op, spec, n, opts.normalize);
                const rel = try std.fmt.allocPrint(arena, "{s}/{s}.{s}.curl", .{ folder, file_base, try sanitize(arena, n.name) });
                try stubs.append(arena, .{ .rel = rel, .text = text });
                if (is_login and login_by_tag.get(folder) == null) try login_by_tag.put(arena, folder, rel);
                if (!is_login and first_by_tag.get(folder) == null) try first_by_tag.put(arena, folder, rel);
            }
        }
    }
    // A starter chain per tag that has a login: login → one request.
    var lit = login_by_tag.iterator();
    while (lit.next()) |e| {
        const tag = e.key_ptr.*;
        var text: std.ArrayListUnmanaged(u8) = .empty;
        try appendFmt(arena, &text, "[\n  {{ \"request\": \"{s}\", \"extract\": {{ \"TOKEN\": \"$.access_token\" }} }}", .{e.value_ptr.*});
        if (first_by_tag.get(tag)) |other| try appendFmt(arena, &text, ",\n  {{ \"request\": \"{s}\" }}", .{other});
        try text.appendSlice(arena, "\n]\n");
        try stubs.append(arena, .{ .rel = try std.fmt.allocPrint(arena, "chains/{s}-flow.chain.json", .{tag}), .text = text.items });
    }
    return stubs.items;
}

/// Generate and write under `opts.out`; existing files are kept unless
/// `force`.
pub fn run(gpa: Allocator, io: Io, opts: Options) Error!Result {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try loadSpecText(gpa, io, opts.spec);
    defer gpa.free(text);
    const spec = try parseSpec(arena, text);
    const stubs = try generate(arena, spec, opts);
    return writeStubs(arena, io, opts.out, stubs, opts.force);
}

pub fn writeStubs(arena: Allocator, io: Io, out: []const u8, stubs: []const Stub, force: bool) Error!Result {
    var written: usize = 0;
    var skipped: usize = 0;
    Io.Dir.cwd().createDirPath(io, out) catch return error.WriteFailed;
    for (stubs) |s| {
        const path = try std.fs.path.join(arena, &.{ out, s.rel });
        if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch return error.WriteFailed;
        if (!force) {
            if (Io.Dir.cwd().access(io, path, .{})) |_| {
                skipped += 1;
                continue;
            } else |_| {}
        }
        Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = s.text }) catch return error.WriteFailed;
        written += 1;
    }
    return .{ .written = written, .skipped = skipped };
}

// ─── rendering ──────────────────────────────────────────────────────────

fn str(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

fn get(v: Value, path: []const []const u8) ?Value {
    var cur = v;
    for (path) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

pub fn sanitize(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var pending_dash = false;
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            if (pending_dash and out.items.len > 0) try out.append(arena, '-');
            pending_dash = false;
            try out.append(arena, c);
        } else pending_dash = true;
    }
    return if (out.items.len == 0) "op" else out.items;
}

fn isLoginShaped(path: []const u8, method: []const u8) bool {
    if (!std.ascii.eqlIgnoreCase(method, "post")) return false;
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| trimmed[i + 1 ..] else trimmed;
    const names = [_][]const u8{ "login", "signin", "sign-in", "sign_in", "token", "authenticate", "sessions", "auth" };
    for (names) |n| if (std.ascii.eqlIgnoreCase(last, n)) return true;
    return false;
}

const NamedExample = struct { name: []const u8, summary: ?[]const u8, body: []const u8 };

fn namedExamples(arena: Allocator, op: Value) Allocator.Error![]NamedExample {
    var out: std.ArrayListUnmanaged(NamedExample) = .empty;
    const examples = get(op, &.{ "requestBody", "content", "application/json", "examples" }) orelse return out.items;
    if (examples != .object) return out.items;
    var it = examples.object.iterator();
    while (it.next()) |e| {
        const value = get(e.value_ptr.*, &.{"value"}) orelse continue;
        try out.append(arena, .{ .name = e.key_ptr.*, .summary = str(e.value_ptr.*, "summary"), .body = try std.json.Stringify.valueAlloc(arena, value, .{}) });
    }
    return out.items;
}

fn resolveRef(spec: Value, ref: []const u8) ?Value {
    if (!std.mem.startsWith(u8, ref, "#/")) return null;
    var cur = spec;
    var it = std.mem.splitScalar(u8, ref[2..], '/');
    while (it.next()) |seg| {
        if (cur != .object) return null;
        cur = cur.object.get(seg) orelse return null;
    }
    return cur;
}

fn flat(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        .null => "null",
        .bool => |b| if (b) "true" else "false",
        else => try std.json.Stringify.valueAlloc(arena, v, .{}),
    };
}

/// An OpenAPI 3 server URL with its `{variable}`s filled: each one's
/// `default`, or a `{{variable}}` an env can fill when the spec gives
/// none — never the braces as written, which no request can be sent to.
fn serverUrl(arena: Allocator, url: []const u8, variables: ?Value) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, url, '{') == null) return url;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < url.len) : (i += 1) {
        if (url[i] == '{' and !(i + 1 < url.len and url[i + 1] == '{')) {
            if (std.mem.indexOfScalarPos(u8, url, i, '}')) |close| {
                const name = url[i + 1 .. close];
                const def: ?Value = if (variables) |v| get(v, &.{ name, "default" }) else null;
                if (def) |d| try out.appendSlice(arena, try flat(arena, d)) else try appendFmt(arena, &out, "{{{{{s}}}}}", .{name});
                i = close;
                continue;
            }
        }
        try out.append(arena, url[i]);
    }
    return out.items;
}

/// A query value as it goes into the stub's URL: percent-encoded (an
/// example like `red widgets` would otherwise put a space on the
/// request line), a `{{VAR}}` left whole for the env.
fn queryValue(arena: Allocator, v: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < v.len) {
        if (std.mem.startsWith(u8, v[i..], "{{")) if (std.mem.indexOfPos(u8, v, i + 2, "}}")) |close| {
            try out.appendSlice(arena, v[i .. close + 2]);
            i = close + 2;
            continue;
        };
        const c = v[i];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == ',' or c == ':') {
            try out.append(arena, c);
        } else try appendFmt(arena, &out, "%{X:0>2}", .{c});
        i += 1;
    }
    return out.items;
}

fn placeholder(arena: Allocator, param: Value, name: []const u8) Allocator.Error![]const u8 {
    // OpenAPI 3 puts `example` on the Parameter itself, beside `schema`.
    if (get(param, &.{"example"})) |e| return flat(arena, e);
    if (get(param, &.{"examples"})) |ex| if (ex == .object and ex.object.count() > 0) if (get(ex.object.values()[0], &.{"value"})) |v| return flat(arena, v);
    const schema = get(param, &.{"schema"}) orelse param;
    if (get(schema, &.{"example"})) |e| return flat(arena, e);
    if (get(schema, &.{"default"})) |d| return flat(arena, d);
    if (get(schema, &.{"enum"})) |e| if (e == .array and e.array.items.len > 0) return flat(arena, e.array.items[0]);
    return std.fmt.allocPrint(arena, "{{{{{s}}}}}", .{name});
}

const Param = struct { name: []const u8, value: []const u8 };
const Params = struct { req_q: []Param, opt_q: []Param, req_h: []Param, opt_h: []Param };

fn collectParams(arena: Allocator, op: Value, spec: Value) Allocator.Error!Params {
    var req_q: std.ArrayListUnmanaged(Param) = .empty;
    var opt_q: std.ArrayListUnmanaged(Param) = .empty;
    var req_h: std.ArrayListUnmanaged(Param) = .empty;
    var opt_h: std.ArrayListUnmanaged(Param) = .empty;
    const params = get(op, &.{"parameters"}) orelse return .{ .req_q = &.{}, .opt_q = &.{}, .req_h = &.{}, .opt_h = &.{} };
    if (params == .array) for (params.array.items) |p_in| {
        const p = if (str(p_in, "$ref")) |r| (resolveRef(spec, r) orelse continue) else p_in;
        const name = str(p, "name") orelse continue;
        const loc = str(p, "in") orelse "";
        const required = if (get(p, &.{"required"})) |r| (r == .bool and r.bool) else false;
        const value = try placeholder(arena, p, name);
        if (std.mem.eql(u8, loc, "query")) {
            try (if (required) &req_q else &opt_q).append(arena, .{ .name = name, .value = value });
        } else if (std.mem.eql(u8, loc, "header")) {
            try (if (required) &req_h else &opt_h).append(arena, .{ .name = name, .value = value });
        }
    };
    return .{ .req_q = req_q.items, .opt_q = opt_q.items, .req_h = req_h.items, .opt_h = opt_h.items };
}

/// A plausible body from a schema: example / default / type-driven
/// placeholders, `$ref` resolved, depth capped at 5.
pub fn synth(arena: Allocator, schema: Value, spec: Value, visited: *std.StringArrayHashMapUnmanaged(void), depth: u32, prop: []const u8) Allocator.Error!Value {
    if (depth > 5 or schema != .object) return .null;
    if (str(schema, "$ref")) |r| {
        if (visited.get(r) != null) return .null;
        try visited.put(arena, r, {});
        const resolved = resolveRef(spec, r) orelse return .null;
        return synth(arena, resolved, spec, visited, depth + 1, prop);
    }
    if (schema.object.get("example")) |e| return e;
    if (schema.object.get("default")) |d| return d;
    if (schema.object.get("enum")) |e| if (e == .array and e.array.items.len > 0) return e.array.items[0];
    for ([_][]const u8{ "allOf", "oneOf", "anyOf" }) |k| if (schema.object.get(k)) |alts| if (alts == .array and alts.array.items.len > 0) {
        if (std.mem.eql(u8, k, "allOf")) {
            var merged: std.json.ObjectMap = .empty;
            for (alts.array.items) |alt| {
                const v = try synth(arena, alt, spec, visited, depth + 1, prop);
                if (v == .object) {
                    var it = v.object.iterator();
                    while (it.next()) |e| try merged.put(arena, e.key_ptr.*, e.value_ptr.*);
                }
            }
            return .{ .object = merged };
        }
        return synth(arena, alts.array.items[0], spec, visited, depth + 1, prop);
    };
    const ty = str(schema, "type") orelse (if (schema.object.get("properties") != null) "object" else "string");
    const format = str(schema, "format") orelse "";
    if (std.mem.eql(u8, ty, "object")) {
        var obj: std.json.ObjectMap = .empty;
        if (schema.object.get("properties")) |props| if (props == .object) {
            var it = props.object.iterator();
            while (it.next()) |e| try obj.put(arena, e.key_ptr.*, try synth(arena, e.value_ptr.*, spec, visited, depth + 1, e.key_ptr.*));
        };
        return .{ .object = obj };
    }
    if (std.mem.eql(u8, ty, "array")) {
        var arr: std.json.Array = .init(arena);
        if (schema.object.get("items")) |items| try arr.append(try synth(arena, items, spec, visited, depth + 1, prop));
        return .{ .array = arr };
    }
    if (std.mem.eql(u8, ty, "integer")) return .{ .integer = if (get(schema, &.{"minimum"})) |m| (if (m == .integer) m.integer else 0) else 1 };
    if (std.mem.eql(u8, ty, "number")) return .{ .float = 1.5 };
    if (std.mem.eql(u8, ty, "boolean")) return .{ .bool = false };
    // strings, by format then by name
    if (std.mem.eql(u8, format, "date-time")) return .{ .string = "2026-01-01T00:00:00Z" };
    if (std.mem.eql(u8, format, "date")) return .{ .string = "2026-01-01" };
    if (std.mem.eql(u8, format, "email")) return .{ .string = "user@example.com" };
    if (std.mem.eql(u8, format, "uuid")) return .{ .string = "00000000-0000-4000-8000-000000000000" };
    if (std.mem.eql(u8, format, "uri") or std.mem.eql(u8, format, "url")) return .{ .string = "https://example.com" };
    const lower = try std.ascii.allocLowerString(arena, prop);
    if (std.mem.indexOf(u8, lower, "email") != null) return .{ .string = "user@example.com" };
    if (std.mem.indexOf(u8, lower, "name") != null) return .{ .string = "Example Name" };
    if (std.mem.indexOf(u8, lower, "phone") != null) return .{ .string = "+15555550100" };
    if (std.mem.indexOf(u8, lower, "url") != null) return .{ .string = "https://example.com" };
    if (std.mem.endsWith(u8, lower, "id")) return .{ .string = "00000000-0000-4000-8000-000000000000" };
    return .{ .string = "string" };
}

/// ISO timestamps → `{{$isoTimestamp}}`, lowercase UUIDs → `{{$uuid}}`
/// inside JSON string values.
pub fn normalizeDynamic(arena: Allocator, body: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        if (isUuidAt(body, i)) {
            try out.appendSlice(arena, "{{$uuid}}");
            i += 36;
            continue;
        }
        if (isoLenAt(body, i)) |n| {
            try out.appendSlice(arena, "{{$isoTimestamp}}");
            i += n;
            continue;
        }
        try out.append(arena, body[i]);
        i += 1;
    }
    return out.items;
}

fn isUuidAt(s: []const u8, i: usize) bool {
    if (i + 36 > s.len) return false;
    if (i > 0 and (std.ascii.isHex(s[i - 1]) or s[i - 1] == '-')) return false;
    for (s[i .. i + 36], 0..) |c, k| {
        const dash = k == 8 or k == 13 or k == 18 or k == 23;
        if (dash) {
            if (c != '-') return false;
        } else if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    }
    if (i + 36 < s.len and (std.ascii.isHex(s[i + 36]) or s[i + 36] == '-')) return false;
    return true;
}

/// `YYYY-MM-DDTHH:MM:SS(.fff)?(Z|±HH:MM)` — its length, when it starts at `i`.
fn isoLenAt(s: []const u8, i: usize) ?usize {
    if (i + 20 > s.len) return null;
    if (i > 0 and std.ascii.isDigit(s[i - 1])) return null;
    const head = s[i .. i + 19];
    const shape = "0000-00-00T00:00:00";
    for (head, shape) |c, sh| {
        if (sh == '0') {
            if (!std.ascii.isDigit(c)) return null;
        } else if (c != sh) return null;
    }
    var n: usize = 19;
    if (i + n < s.len and s[i + n] == '.') {
        n += 1;
        while (i + n < s.len and std.ascii.isDigit(s[i + n])) n += 1;
    }
    if (i + n < s.len and s[i + n] == 'Z') return n + 1;
    if (i + n + 6 <= s.len and (s[i + n] == '+' or s[i + n] == '-') and std.ascii.isDigit(s[i + n + 1]) and std.ascii.isDigit(s[i + n + 2]) and s[i + n + 3] == ':' and std.ascii.isDigit(s[i + n + 4]) and std.ascii.isDigit(s[i + n + 5])) return n + 6;
    return null;
}

fn renderCurl(arena: Allocator, base_url: []const u8, path: []const u8, method: []const u8, op: Value, spec: Value, named: ?NamedExample, normalize: bool) Allocator.Error![]const u8 {
    var url_path: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, path, i, '}') orelse {
                try url_path.append(arena, path[i]);
                continue;
            };
            try appendFmt(arena, &url_path, "{{{{{s}}}}}", .{path[i + 1 .. close]});
            i = close;
            continue;
        }
        try url_path.append(arena, path[i]);
    }
    const params = try collectParams(arena, op, spec);
    if (params.req_q.len > 0) {
        try url_path.append(arena, '?');
        for (params.req_q, 0..) |p, k| {
            if (k > 0) try url_path.append(arena, '&');
            try appendFmt(arena, &url_path, "{s}={s}", .{ p.name, try queryValue(arena, p.value) });
        }
    }
    const method_upper = try std.ascii.allocUpperString(arena, method);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (str(op, "summary")) |s| try appendFmt(arena, &out, "# {s}\n", .{s});
    if (str(op, "description")) |d| {
        var lines = std.mem.splitScalar(u8, d, '\n');
        while (lines.next()) |l| try appendFmt(arena, &out, "# {s}\n", .{l});
    }
    if (named) |n| if (n.summary) |s| try appendFmt(arena, &out, "# example: {s}\n", .{s});
    try appendFmt(arena, &out, "# {s} {s}\n", .{ method_upper, path });
    if (isLoginShaped(path, method)) try out.appendSlice(arena, "# extract: TOKEN=$.access_token\n");
    // The body.
    var body: ?[]const u8 = null;
    if (named) |n| {
        body = n.body;
    } else if (get(op, &.{ "requestBody", "content", "application/json", "example" })) |ex| {
        body = try std.json.Stringify.valueAlloc(arena, ex, .{});
    } else {
        var schema: ?Value = get(op, &.{ "requestBody", "content", "application/json", "schema" });
        if (schema == null) if (get(op, &.{"parameters"})) |ps| if (ps == .array) for (ps.array.items) |p| {
            if (str(p, "in")) |loc| if (std.mem.eql(u8, loc, "body")) {
                if (get(p, &.{ "schema", "example" })) |ex| {
                    body = try std.json.Stringify.valueAlloc(arena, ex, .{});
                } else schema = get(p, &.{"schema"});
            };
        };
        if (body == null) if (schema) |sc| {
            var visited: std.StringArrayHashMapUnmanaged(void) = .empty;
            const v = try synth(arena, sc, spec, &visited, 0, "");
            body = try std.json.Stringify.valueAlloc(arena, v, .{});
        };
    }
    if (body != null and normalize) body = try normalizeDynamic(arena, body.?);
    var headers: std.ArrayListUnmanaged([]const u8) = .empty;
    try headers.append(arena, "  -H 'accept: application/json'");
    try headers.append(arena, "  -H 'Authorization: Bearer {{TOKEN}}'");
    for (params.req_h) |h| try headers.append(arena, try std.fmt.allocPrint(arena, "  -H '{s}: {s}'", .{ h.name, h.value }));
    if (body != null) try headers.append(arena, "  -H 'content-type: application/json'");
    try appendFmt(arena, &out, "curl '{s}{s}' \\\n", .{ base_url, url_path.items });
    const is_get = std.mem.eql(u8, method_upper, "GET");
    const is_post = std.mem.eql(u8, method_upper, "POST");
    if ((!is_get and body == null) or (!is_post and body != null)) try appendFmt(arena, &out, "  -X {s} \\\n", .{method_upper});
    for (headers.items, 0..) |h, k| {
        try out.appendSlice(arena, h);
        try out.appendSlice(arena, if (k + 1 < headers.items.len or body != null) " \\\n" else "\n");
    }
    if (body) |b| {
        var esc: std.ArrayListUnmanaged(u8) = .empty;
        for (b) |c| if (c == '\'') try esc.appendSlice(arena, "'\\''") else try esc.append(arena, c);
        try appendFmt(arena, &out, "  --data-raw '{s}'\n", .{esc.items});
    }
    if (params.opt_q.len > 0 or params.opt_h.len > 0) {
        try out.appendSlice(arena, "\n# Optional parameters (uncomment to use):\n");
        for (params.opt_q) |p| try appendFmt(arena, &out, "#   ?{s}={s}\n", .{ p.name, p.value });
        for (params.opt_h) |h| try appendFmt(arena, &out, "#   -H '{s}: {s}'\n", .{ h.name, h.value });
    }
    return out.items;
}

fn appendFmt(a: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    try list.appendSlice(a, s);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const petstore =
    \\{"openapi":"3.0.0","servers":[{"url":"https://api.example.com/v1/"}],
    \\ "components":{"schemas":{"Pet":{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer","minimum":2},"tags":{"type":"array","items":{"type":"string"}},"owner":{"$ref":"#/components/schemas/Owner"}}},
    \\   "Owner":{"type":"object","properties":{"email":{"type":"string","format":"email"},"pet":{"$ref":"#/components/schemas/Pet"}}}}},
    \\ "paths":{
    \\  "/pets/{petId}":{"get":{"operationId":"getPet","tags":["pets"],"summary":"Get a pet","parameters":[{"name":"petId","in":"path","required":true},{"name":"verbose","in":"query","required":false,"schema":{"type":"boolean","default":false}},{"name":"X-Trace","in":"header","required":true}]}},
    \\  "/pets":{"post":{"operationId":"createPet","tags":["pets"],"requestBody":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Pet"}}}}}},
    \\  "/auth/login":{"post":{"operationId":"login","tags":["auth"],"requestBody":{"content":{"application/json":{"examples":{"admin":{"summary":"an admin","value":{"user":"a","pass":"b","at":"2024-05-01T10:00:00Z"}},"guest":{"value":{"user":"g"}}}}}}}},
    \\  "/auth/me":{"get":{"tags":["auth"]}}
    \\ }}
;

test "generate: one stub per operation, tags as folders, params, refs, named examples, chain starter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try parseSpec(a, petstore);
    const stubs = try generate(a, spec, .{ .spec = "x", .out = "o", .normalize = true });
    var by: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (stubs) |s| try by.put(a, s.rel, s.text);
    const get_pet = by.get("pets/getPet.curl").?;
    try testing.expect(std.mem.indexOf(u8, get_pet, "# Get a pet\n# GET /pets/{petId}\n") != null);
    try testing.expect(std.mem.indexOf(u8, get_pet, "curl 'https://api.example.com/v1/pets/{{petId}}' \\\n") != null);
    try testing.expect(std.mem.indexOf(u8, get_pet, "  -H 'X-Trace: {{X-Trace}}'\n") != null);
    try testing.expect(std.mem.indexOf(u8, get_pet, "#   ?verbose=false") != null);
    try testing.expect(std.mem.indexOf(u8, get_pet, "-X ") == null);
    const create = by.get("pets/createPet.curl").?;
    try testing.expect(std.mem.indexOf(u8, create, "--data-raw '{\"name\":\"Example Name\",\"age\":2,\"tags\":[\"string\"],\"owner\":{\"email\":\"user@example.com\",\"pet\":null}}'") != null);
    try testing.expect(std.mem.indexOf(u8, create, "-X ") == null);
    const admin = by.get("auth/login.admin.curl").?;
    try testing.expect(std.mem.indexOf(u8, admin, "# example: an admin\n") != null);
    try testing.expect(std.mem.indexOf(u8, admin, "# extract: TOKEN=$.access_token\n") != null);
    try testing.expect(std.mem.indexOf(u8, admin, "\"at\":\"{{$isoTimestamp}}\"") != null);
    try testing.expect(by.get("auth/login.guest.curl") != null);
    const me = by.get("auth/get-auth-me.curl").?;
    try testing.expect(std.mem.indexOf(u8, me, "curl 'https://api.example.com/v1/auth/me'") != null);
    const chain = by.get("chains/auth-flow.chain.json").?;
    try testing.expect(std.mem.indexOf(u8, chain, "\"request\": \"auth/login.admin.curl\", \"extract\": { \"TOKEN\": \"$.access_token\" }") != null);
    try testing.expect(std.mem.indexOf(u8, chain, "\"request\": \"auth/get-auth-me.curl\"") != null);
    try testing.expectEqualStrings("Get-By-Id", try sanitize(a, "Get/By Id"));
    const norm = try normalizeDynamic(a, "{\"id\":\"123e4567-e89b-42d3-a456-426614174000\",\"t\":\"2024-01-02T03:04:05.123+02:00\",\"keep\":\"123E4567-E89B-42D3-A456-426614174000\"}");
    try testing.expectEqualStrings("{\"id\":\"{{$uuid}}\",\"t\":\"{{$isoTimestamp}}\",\"keep\":\"123E4567-E89B-42D3-A456-426614174000\"}", norm);
}

test "generate: server variables take their defaults; a parameter's own example is its value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try parseSpec(a,
        \\{"openapi":"3.0.0","servers":[{"url":"http://{host}:{port}/{region}/v2","variables":{"host":{"default":"127.0.0.1"},"port":{"default":"8080"},"region":{"enum":["eu","us"]}}}],
        \\ "paths":{"/things":{"get":{"operationId":"listThings","parameters":[{"name":"q","in":"query","required":true,"example":"red widgets","schema":{"type":"string"}},{"name":"n","in":"query","required":true,"examples":{"small":{"value":3}}}]}}}}
    );
    const stubs = try generate(a, spec, .{ .spec = "x", .out = "o" });
    try testing.expectEqual(@as(usize, 1), stubs.len);
    // A variable with no default becomes a `{{var}}` an env can fill.
    try testing.expect(std.mem.indexOf(u8, stubs[0].text, "curl 'http://127.0.0.1:8080/{{region}}/v2/things?q=red%20widgets&n=3' \\\n") != null);
    try testing.expect(std.mem.indexOf(u8, stubs[0].text, "{host}") == null);
}

test "swagger 2 host/basePath and a YAML spec; run writes and skips existing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try parseSpec(a, "swagger: '2.0'\nhost: petstore.swagger.io\nbasePath: /v2\nschemes: [http]\npaths:\n  /pet:\n    put:\n      parameters:\n        - in: body\n          name: body\n          schema:\n            example:\n              id: 1\n");
    const stubs = try generate(a, spec, .{ .spec = "x", .out = "o" });
    try testing.expectEqual(@as(usize, 1), stubs.len);
    try testing.expectEqualStrings("untagged/put-pet.curl", stubs[0].rel);
    try testing.expect(std.mem.indexOf(u8, stubs[0].text, "curl 'http://petstore.swagger.io/v2/pet' \\\n  -X PUT \\\n") != null);
    try testing.expect(std.mem.indexOf(u8, stubs[0].text, "--data-raw '{\"id\":1}'") != null);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "spec.json", .data = petstore });
    const spec_path = try std.fs.path.join(a, &.{ root, "spec.json" });
    const out = try std.fs.path.join(a, &.{ root, "stubs" });
    const r1 = try run(testing.allocator, testing.io, .{ .spec = spec_path, .out = out });
    try testing.expectEqual(@as(usize, 6), r1.written);
    try testing.expectEqual(@as(usize, 0), r1.skipped);
    const r2 = try run(testing.allocator, testing.io, .{ .spec = spec_path, .out = out });
    try testing.expectEqual(@as(usize, 0), r2.written);
    try testing.expectEqual(@as(usize, 6), r2.skipped);
    const r3 = try run(testing.allocator, testing.io, .{ .spec = spec_path, .out = out, .force = true });
    try testing.expectEqual(@as(usize, 6), r3.written);
    try testing.expectError(error.SpecUnreadable, run(testing.allocator, testing.io, .{ .spec = "/nope/spec.json", .out = out }));
}
