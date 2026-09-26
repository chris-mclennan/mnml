//! `<ws>/.mnml/sources.json` (or the rqst-era `.rqst/sources.json`): a
//! JSON array of swagger sources — `name`, `kind: "swagger"`, `url` (a
//! file or an http(s) URL; relative paths are workspace-relative), `out`
//! (defaults to `.rqst/requests/<name>`), `base_url_override`. `sync`
//! regenerates every source's stubs; `check` is the dry run that lists
//! what would be added, removed or changed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const discover = @import("discover.zig");

pub const Source = struct {
    name: []const u8,
    kind: []const u8,
    url: []const u8,
    out: []const u8,
    base_url: ?[]const u8,
};

pub const LoadError = error{ NoSourcesFile, NotJson, NotAnArray } || Allocator.Error;

/// Everything on `arena`.
pub fn load(arena: Allocator, io: Io, workspace: []const u8) LoadError![]Source {
    const cands = [_][]const u8{ ".mnml/sources.json", ".rqst/sources.json" };
    var text: ?[]const u8 = null;
    for (cands) |c| {
        const path = try std.fs.path.join(arena, &.{ workspace, c });
        text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
        break;
    }
    return parseText(arena, workspace, text orelse return error.NoSourcesFile);
}

pub fn parseText(arena: Allocator, workspace: []const u8, text: []const u8) LoadError![]Source {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.NotJson;
    if (v != .array) return error.NotAnArray;
    var out: std.ArrayListUnmanaged(Source) = .empty;
    for (v.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const name = strOf(o.get("name")) orelse "(unnamed)";
        const url_raw = strOf(o.get("url")) orelse continue;
        const url = if (std.mem.startsWith(u8, url_raw, "http://") or std.mem.startsWith(u8, url_raw, "https://") or std.fs.path.isAbsolute(url_raw)) url_raw else try std.fs.path.join(arena, &.{ workspace, url_raw });
        const out_raw = strOf(o.get("out")) orelse try std.fmt.allocPrint(arena, ".rqst/requests/{s}", .{name});
        const out_path = if (std.fs.path.isAbsolute(out_raw)) out_raw else try std.fs.path.join(arena, &.{ workspace, out_raw });
        try out.append(arena, .{ .name = name, .kind = strOf(o.get("kind")) orelse "", .url = url, .out = out_path, .base_url = strOf(o.get("base_url_override")) });
    }
    return out.items;
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    return if (v) |x| switch (x) {
        .string => |s| s,
        else => null,
    } else null;
}

pub const SyncOut = struct {
    /// A per-source trace, owned by the caller's allocator.
    trace: []u8,
    total: usize,
};

/// Regenerate every swagger source's stubs (overwriting).
pub fn sync(gpa: Allocator, io: Io, workspace: []const u8, normalize: bool) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const list = try load(a, io, workspace);
    if (list.len == 0) return error.NoSources;
    var trace: std.ArrayListUnmanaged(u8) = .empty;
    var total: usize = 0;
    for (list) |s| {
        if (!std.mem.eql(u8, s.kind, "swagger")) {
            try appendFmt(a, &trace, "## {s}\n  skipping unsupported kind '{s}'\n\n", .{ s.name, s.kind });
            continue;
        }
        try appendFmt(a, &trace, "## {s}\n  spec: {s}\n  out:  {s}\n", .{ s.name, s.url, s.out });
        const r = discover.run(gpa, io, .{ .spec = s.url, .out = s.out, .base_url = s.base_url, .normalize = normalize, .force = true }) catch |err| {
            try appendFmt(a, &trace, "  FAILED: {s}\n\n", .{@errorName(err)});
            continue;
        };
        total += r.written;
        try appendFmt(a, &trace, "  wrote {d} stub(s)\n\n", .{r.written});
    }
    try appendFmt(a, &trace, "ok — {d} stubs written\n", .{total});
    return gpa.dupe(u8, trace.items);
}

/// The dry run: what `sync` would add, remove or change.
pub fn check(gpa: Allocator, io: Io, workspace: []const u8, normalize: bool) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const list = try load(a, io, workspace);
    if (list.len == 0) return error.NoSources;
    var trace: std.ArrayListUnmanaged(u8) = .empty;
    try trace.appendSlice(a, "# http.sync_check — drift report\n\n");
    var drift: usize = 0;
    for (list) |s| {
        if (!std.mem.eql(u8, s.kind, "swagger")) continue;
        try appendFmt(a, &trace, "## {s}\n  spec: {s}\n  compared against: {s}\n", .{ s.name, s.url, s.out });
        const text = discover.loadSpecText(gpa, io, s.url) catch |err| {
            try appendFmt(a, &trace, "  FAILED: {s}\n\n", .{@errorName(err)});
            continue;
        };
        defer gpa.free(text);
        const spec = discover.parseSpec(a, text) catch |err| {
            try appendFmt(a, &trace, "  FAILED: {s}\n\n", .{@errorName(err)});
            continue;
        };
        const stubs = try discover.generate(a, spec, .{ .spec = s.url, .out = s.out, .base_url = s.base_url, .normalize = normalize });
        var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (stubs) |st| {
            try seen.put(a, st.rel, {});
            const path = try std.fs.path.join(a, &.{ s.out, st.rel });
            const on_disk = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch {
                try appendFmt(a, &trace, "  + {s}\n", .{st.rel});
                drift += 1;
                continue;
            };
            if (!std.mem.eql(u8, on_disk, st.text)) {
                try appendFmt(a, &trace, "  ~ {s}\n", .{st.rel});
                drift += 1;
            }
        }
        // Files on disk the spec no longer yields.
        var dir = Io.Dir.cwd().openDir(io, s.out, .{ .iterate = true }) catch {
            try trace.append(a, '\n');
            continue;
        };
        defer dir.close(io);
        var walker = dir.walk(a) catch {
            try trace.append(a, '\n');
            continue;
        };
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".curl")) continue;
            if (seen.get(entry.path) == null) {
                try appendFmt(a, &trace, "  - {s}\n", .{entry.path});
                drift += 1;
            }
        }
        try trace.append(a, '\n');
    }
    if (drift == 0) try trace.appendSlice(a, "no drift — every stub matches its spec\n") else try appendFmt(a, &trace, "{d} file(s) differ\n", .{drift});
    return gpa.dupe(u8, trace.items);
}

fn appendFmt(a: Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    try list.appendSlice(a, s);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "parseText resolves relative url / out against the workspace; bad entries are skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const list = try parseText(arena.allocator(), "/ws", "[{\"name\":\"pets\",\"kind\":\"swagger\",\"url\":\"openapi/pets.yaml\"},{\"name\":\"remote\",\"kind\":\"swagger\",\"url\":\"https://x/spec.json\",\"out\":\"/abs/out\",\"base_url_override\":\"https://dev\"},{\"kind\":\"swagger\"}]");
    try testing.expectEqual(@as(usize, 2), list.len);
    try sdk_testing.expectPath("/ws/openapi/pets.yaml", list[0].url);
    try testing.expectEqualStrings("/ws/.rqst/requests/pets", list[0].out);
    try testing.expectEqualStrings("/abs/out", list[1].out);
    try testing.expectEqualStrings("https://dev", list[1].base_url.?);
    try testing.expectError(error.NotAnArray, parseText(arena.allocator(), "/ws", "{}"));
}

test "sync writes the stubs and check reports no drift, then a change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    try tmp.dir.createDirPath(testing.io, ".mnml");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "spec.yaml", .data = "openapi: 3.0.0\npaths:\n  /a:\n    get:\n      operationId: getA\n      tags: [t]\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/sources.json", .data = "[{\"name\":\"s\",\"kind\":\"swagger\",\"url\":\"spec.yaml\",\"out\":\"stubs\"}]" });
    const trace = try sync(testing.allocator, testing.io, ws, false);
    defer testing.allocator.free(trace);
    try testing.expect(std.mem.indexOf(u8, trace, "wrote 1 stub(s)") != null);
    try testing.expect(std.mem.endsWith(u8, trace, "ok — 1 stubs written\n"));
    const stub = try tmp.dir.readFileAlloc(testing.io, "stubs/t/getA.curl", testing.allocator, .limited(4096));
    defer testing.allocator.free(stub);
    try testing.expect(std.mem.indexOf(u8, stub, "curl '{{BASE_URL}}/a'") != null);
    const clean = try check(testing.allocator, testing.io, ws, false);
    defer testing.allocator.free(clean);
    try testing.expect(std.mem.indexOf(u8, clean, "no drift") != null);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "stubs/t/getA.curl", .data = "edited\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "stubs/t/stale.curl", .data = "old\n" });
    const dirty = try check(testing.allocator, testing.io, ws, false);
    defer testing.allocator.free(dirty);
    try testing.expect(std.mem.indexOf(u8, dirty, "  ~ t/getA.curl") != null);
    try testing.expect(std.mem.indexOf(u8, dirty, "  - t/stale.curl") != null);
    try testing.expect(std.mem.indexOf(u8, dirty, "2 file(s) differ") != null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NoSourcesFile, load(arena.allocator(), testing.io, "/nope"));
}
