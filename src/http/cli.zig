//! The HTTP subcommands: `run FILE`, `chain run FILE`, `discover SPEC`,
//! `sync`, `sync-check`, `proxy --url`. Each takes its argv after the
//! verb, writes to the given stdout / stderr writers, and returns the
//! exit code. The workspace, when not given, is the nearest ancestor
//! of the file holding `.mnml/` or `.rqst/`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const env_mod = @import("env.zig");
const client = @import("client.zig");
const chain = @import("chain.zig");
const discover = @import("discover.zig");
const sources = @import("sources.zig");
const proxy = @import("proxy.zig");
const body = @import("body.zig");

pub const Std = struct { out: *Io.Writer, err: *Io.Writer };

/// Walk up from `start` to the nearest dir holding `.mnml` or `.rqst`.
pub fn findWorkspace(arena: Allocator, io: Io, start: []const u8) Allocator.Error![]const u8 {
    var cur = start;
    while (true) {
        for ([_][]const u8{ ".mnml", ".rqst" }) |m| {
            const p = try std.fs.path.join(arena, &.{ cur, m });
            if (Io.Dir.cwd().statFile(io, p, .{})) |st| {
                if (st.kind == .directory) return cur;
            } else |_| {}
        }
        const parent = std.fs.path.dirname(cur) orelse return start;
        if (std.mem.eql(u8, parent, cur)) return start;
        cur = parent;
    }
}

fn absolute(arena: Allocator, io: Io, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, ".", &buf) catch return path;
    return std.fs.path.join(arena, &.{ buf[0..n], path });
}

const FileArgs = struct { file: ?[]const u8 = null, env: ?[]const u8 = null, workspace: ?[]const u8 = null, help: bool = false };

fn parseFileArgs(argv: []const []const u8, std_: Std, verb: []const u8) !?FileArgs {
    var out: FileArgs = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--env") or std.mem.eql(u8, a, "-e")) {
            i += 1;
            if (i >= argv.len) {
                try std_.err.print("mnml-zig {s}: --env needs a value\n", .{verb});
                return null;
            }
            out.env = argv[i];
        } else if (std.mem.eql(u8, a, "--workspace") or std.mem.eql(u8, a, "-w")) {
            i += 1;
            if (i >= argv.len) {
                try std_.err.print("mnml-zig {s}: --workspace needs a path\n", .{verb});
                return null;
            }
            out.workspace = argv[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            out.help = true;
        } else if (a.len > 0 and a[0] == '-') {
            try std_.err.print("mnml-zig {s}: unknown flag: {s}\n", .{ verb, a });
            return null;
        } else {
            if (out.file != null) {
                try std_.err.print("mnml-zig {s}: unexpected extra argument: {s}\n", .{ verb, a });
                return null;
            }
            out.file = a;
        }
    }
    return out;
}

// ─── run ────────────────────────────────────────────────────────────────

pub fn run(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, std_: Std) !u8 {
    const usage = "usage: mnml-zig run FILE [--env NAME] [--workspace DIR]";
    const args = (try parseFileArgs(argv, std_, "run")) orelse return 1;
    if (args.help) {
        try std_.out.print("{s}\n", .{usage});
        return 0;
    }
    const file_rel = args.file orelse {
        try std_.err.print("{s}\n", .{usage});
        return 1;
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const file = try absolute(a, io, file_rel);
    const raw = Io.Dir.cwd().readFileAlloc(io, file, a, .limited(16 << 20)) catch |err| {
        try std_.err.print("mnml-zig run: cannot read {s}: {s}\n", .{ file_rel, @errorName(err) });
        return 1;
    };
    const ws = args.workspace orelse try findWorkspace(a, io, std.fs.path.dirname(file) orelse ".");
    const sel = try env_mod.select(a, io, ws, args.env, env.get("MNML_ENV"), null);
    var set = try env_mod.EnvSet.load(a, io, ws, sel.name);
    set.process = env;
    try std_.err.print("env: {s}\n", .{sel.name});
    const blocks = try parse.blocks(a, raw);
    if (blocks.len == 0) {
        try std_.err.print("mnml-zig run: {s} has no request\n", .{file_rel});
        return 1;
    }
    var req = parse.parse(a, blocks[0].text) catch |err| {
        try std_.err.print("mnml-zig run: {s}: {s}\n", .{ file_rel, @errorName(err) });
        return 1;
    };
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try env_mod.unresolved(a, req.url, &set)) |m| try seen.put(a, m, {});
    for (req.headers.items) |h| for (try env_mod.unresolved(a, h.value, &set)) |m| try seen.put(a, m, {});
    if (req.body) |b| for (try env_mod.unresolved(a, b, &set)) |m| try seen.put(a, m, {});
    for (seen.keys()) |m| try std_.err.print("warn: {{{{{s}}}}} is not defined in env {s}\n", .{ m, sel.name });
    req.url = try env_mod.expand(a, io, try parse.substitutePath(a, req.url, try parse.pathParams(a, &req)), &set);
    for (req.headers.items) |*h| h.value = try env_mod.expand(a, io, h.value, &set);
    if (req.body) |b| req.body = try env_mod.expand(a, io, b, &set);
    // The pane's encoder: `# @body-type form-urlencoded` / `multipart`
    // put the same bytes on the wire from here as from the pane.
    var missing: ?[]const u8 = null;
    body.encode(a, io, &req, .{ .base_dir = std.fs.path.dirname(file) orelse ws }, &missing) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => {
            try std_.err.print("mnml-zig run: multipart: no file at {s} (relative to {s})\n", .{ missing orelse "?", std.fs.path.dirname(file) orelse ws });
            return 1;
        },
    };
    try std_.err.print("{s} {s}\n", .{ req.method, req.url });
    try std_.err.flush();
    var outcome = try client.send(a, io, &req, .{});
    switch (outcome) {
        .err => |e| {
            try std_.err.print("mnml-zig run: {s}\n", .{e});
            try std_.err.flush();
            return 1;
        },
        .ok => |*resp| {
            try std_.out.print("HTTP {d} {s} · {d} ms · {d} B\n", .{ resp.status, resp.status_text, resp.timing.total_ms, resp.body.len });
            for (resp.headers) |h| try std_.out.print("{s}: {s}\n", .{ h.name, h.value });
            try std_.out.print("\n{s}\n", .{resp.body});
            try std_.out.flush();
            return 0;
        },
        .moved => return 1,
    }
}

// ─── chain run ──────────────────────────────────────────────────────────

pub fn chainRun(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, std_: Std) !u8 {
    const usage = "usage: mnml-zig chain run FILE [--env NAME] [--workspace DIR]";
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], "run")) {
        try std_.err.print("{s}\n", .{usage});
        return 1;
    }
    const args = (try parseFileArgs(argv[1..], std_, "chain")) orelse return 1;
    if (args.help) {
        try std_.out.print("{s}\n", .{usage});
        return 0;
    }
    const file_rel = args.file orelse {
        try std_.err.print("{s}\n", .{usage});
        return 1;
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const file = try absolute(a, io, file_rel);
    const ws = args.workspace orelse try findWorkspace(a, io, std.fs.path.dirname(file) orelse ".");
    const sel = try env_mod.select(a, io, ws, args.env, env.get("MNML_ENV"), null);
    var result = chain.run(gpa, io, file, ws, sel.name) catch |err| {
        try std_.err.print("mnml-zig chain: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer result.deinit(gpa);
    try std_.out.print("{s}", .{result.trace});
    if (result.ok) {
        try std_.out.print("✓ chain passed\n", .{});
        try std_.out.flush();
        return 0;
    }
    try std_.out.flush();
    try std_.err.print("mnml-zig chain: {s}\n", .{result.err orelse "failed"});
    try std_.err.flush();
    return 1;
}

// ─── discover ───────────────────────────────────────────────────────────

pub fn discoverCmd(gpa: Allocator, io: Io, argv: []const []const u8, std_: Std) !u8 {
    const usage = "usage: mnml-zig discover SPEC [--out DIR] [--base-url URL] [--normalize] [--force]\n  SPEC is an OpenAPI / Swagger file (JSON or YAML) or an http(s) URL";
    var spec: ?[]const u8 = null;
    var out: []const u8 = "requests";
    var base_url: ?[]const u8 = null;
    var normalize = false;
    var force = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--out") or std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= argv.len) {
                try std_.err.print("mnml-zig discover: --out needs a path\n", .{});
                return 1;
            }
            out = argv[i];
        } else if (std.mem.eql(u8, a, "--base-url")) {
            i += 1;
            if (i >= argv.len) {
                try std_.err.print("mnml-zig discover: --base-url needs a value\n", .{});
                return 1;
            }
            base_url = argv[i];
        } else if (std.mem.eql(u8, a, "--normalize") or std.mem.eql(u8, a, "-n")) {
            normalize = true;
        } else if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std_.out.print("{s}\n", .{usage});
            return 0;
        } else if (a.len > 0 and a[0] == '-') {
            try std_.err.print("mnml-zig discover: unknown flag: {s}\n", .{a});
            return 1;
        } else spec = a;
    }
    const s = spec orelse {
        try std_.err.print("{s}\n", .{usage});
        return 1;
    };
    const r = discover.run(gpa, io, .{ .spec = s, .out = out, .base_url = base_url, .normalize = normalize, .force = force }) catch |err| {
        try std_.err.print("mnml-zig discover: {s}\n", .{switch (err) {
            error.SpecUnreadable => "cannot read the spec",
            error.SpecNotJsonOrYaml => "the spec is neither valid JSON nor the YAML subset",
            error.NoPaths => "the spec has no `paths`",
            error.FetchFailed => "fetching the spec failed",
            error.WriteFailed => "writing the stubs failed",
            error.OutOfMemory => "out of memory",
        }});
        return 1;
    };
    try std_.out.print("wrote {d} stub(s) under {s}{s}\n", .{ r.written, out, if (r.skipped > 0) " (existing files kept; --force overwrites)" else "" });
    if (r.skipped > 0) try std_.out.print("skipped {d} existing\n", .{r.skipped});
    try std_.out.flush();
    return 0;
}

// ─── sync / sync-check ──────────────────────────────────────────────────

pub fn syncCmd(gpa: Allocator, io: Io, argv: []const []const u8, std_: Std, check_only: bool) !u8 {
    const verb: []const u8 = if (check_only) "sync-check" else "sync";
    var workspace: ?[]const u8 = null;
    var normalize = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--workspace") or std.mem.eql(u8, a, "-w")) {
            i += 1;
            if (i >= argv.len) {
                try std_.err.print("mnml-zig {s}: --workspace needs a path\n", .{verb});
                return 1;
            }
            workspace = argv[i];
        } else if (std.mem.eql(u8, a, "--normalize") or std.mem.eql(u8, a, "-n")) {
            normalize = true;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std_.out.print("usage: mnml-zig {s} [--workspace DIR] [--normalize]\n  reads <workspace>/.mnml/sources.json (or .rqst/sources.json) and {s} .curl stubs per swagger source\n", .{ verb, if (check_only) "reports drift against the" else "regenerates" });
            return 0;
        } else {
            try std_.err.print("mnml-zig {s}: unexpected arg: {s}\n", .{ verb, a });
            return 1;
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const ws = try absolute(arena_state.allocator(), io, workspace orelse ".");
    const trace = (if (check_only) sources.check(gpa, io, ws, normalize) else sources.sync(gpa, io, ws, normalize)) catch |err| {
        try std_.err.print("mnml-zig {s}: {s}\n", .{ verb, switch (err) {
            error.NoSourcesFile => "no sources.json at .mnml/ or .rqst/",
            error.NoSources => "sources.json is empty",
            else => @errorName(err),
        } });
        return 1;
    };
    defer gpa.free(trace);
    try std_.out.print("{s}", .{trace});
    try std_.out.flush();
    return 0;
}

// ─── proxy ──────────────────────────────────────────────────────────────

pub fn proxyCmd(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, std_: Std) !u8 {
    const usage = "usage: mnml-zig proxy --url URL [--workspace DIR] [--seconds N] [--idle-ms N] [--quiet]";
    var url: ?[]const u8 = null;
    var workspace: ?[]const u8 = null;
    var seconds: ?u64 = null;
    var idle_ms: u64 = 2000;
    var verbose = true;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--url")) {
            i += 1;
            if (i >= argv.len) {
                try std_.err.print("mnml-zig proxy: --url needs a value\n", .{});
                return 1;
            }
            url = argv[i];
        } else if (std.mem.eql(u8, a, "--workspace") or std.mem.eql(u8, a, "-w")) {
            i += 1;
            if (i >= argv.len) {
                try std_.err.print("mnml-zig proxy: --workspace needs a path\n", .{});
                return 1;
            }
            workspace = argv[i];
        } else if (std.mem.eql(u8, a, "--seconds")) {
            i += 1;
            seconds = if (i < argv.len) std.fmt.parseInt(u64, argv[i], 10) catch null else null;
            if (seconds == null) {
                try std_.err.print("mnml-zig proxy: --seconds needs a positive integer\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, a, "--idle-ms")) {
            i += 1;
            idle_ms = if (i < argv.len) std.fmt.parseInt(u64, argv[i], 10) catch 0 else 0;
            if (idle_ms == 0) {
                try std_.err.print("mnml-zig proxy: --idle-ms needs a positive integer\n", .{});
                return 1;
            }
        } else if (std.mem.eql(u8, a, "--quiet")) {
            verbose = false;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try std_.out.print("{s}\n", .{usage});
            return 0;
        } else {
            try std_.err.print("mnml-zig proxy: unexpected arg: {s}\n", .{a});
            return 1;
        }
    }
    const u = url orelse {
        try std_.err.print("{s}\n", .{usage});
        return 1;
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const ws = try absolute(arena_state.allocator(), io, workspace orelse ".");
    const n = proxy.run(gpa, io, env, .{ .workspace = ws, .url = u, .max_seconds = seconds, .idle_ms = idle_ms, .verbose = verbose }, std_.err) catch |err| {
        try std_.err.print("mnml-zig proxy: {s}\n", .{switch (err) {
            error.ChromeNotFound => "Chrome not found (npx @puppeteer/browsers install chrome@stable)",
            error.NoDevToolsPort => "couldn't find Chrome's DevTools port — did it start?",
            error.NoPageTarget => "couldn't reach Chrome's /json endpoint",
            error.ConnectFailed => "connecting to the page's DevTools socket failed",
            error.OutOfMemory => "out of memory",
        }});
        return 1;
    };
    try std_.out.print("ok — {d} requests captured\n", .{n});
    try std_.out.flush();
    return 0;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const mock = @import("mock.zig");

test "run: env resolution, the request line on stderr, the response on stdout; a bad file exits 1" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .status = 200, .status_text = "OK", .headers = &.{.{ .name = "content-type", .value = "text/plain" }}, .body = "pong" });
    defer server.stop(testing.io);
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    try tmp.dir.createDirPath(testing.io, "requests");
    const envf = try std.fmt.allocPrint(testing.allocator, "BASE=http://127.0.0.1:{d}\n", .{server.port});
    defer testing.allocator.free(envf);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = envf });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "requests/ping.curl", .data = "curl '{{BASE}}/ping' -H 'X-Env: {{MISSING}}'\n" });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const file = try std.fs.path.join(testing.allocator, &.{ ws, "requests", "ping.curl" });
    defer testing.allocator.free(file);
    const code = try run(testing.allocator, testing.io, &env, &.{file}, .{ .out = &out.writer, .err = &err.writer });
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.startsWith(u8, err.written(), "env: dev\nwarn: {{MISSING}} is not defined in env dev\nGET http://127.0.0.1:"));
    try testing.expect(std.mem.startsWith(u8, out.written(), "HTTP 200 OK · "));
    try testing.expect(std.mem.endsWith(u8, out.written(), "\n\npong\n"));
    try testing.expect(std.ascii.indexOfIgnoreCase(server.lastRequest(), "x-env: {{MISSING}}") != null);
    var err2: Io.Writer.Allocating = .init(testing.allocator);
    defer err2.deinit();
    try testing.expectEqual(@as(u8, 1), try run(testing.allocator, testing.io, &env, &.{"/nope.curl"}, .{ .out = &out.writer, .err = &err2.writer }));
    try testing.expect(std.mem.startsWith(u8, err2.written(), "mnml-zig run: cannot read /nope.curl"));
    try testing.expectEqual(@as(u8, 1), try run(testing.allocator, testing.io, &env, &.{ "a", "b" }, .{ .out = &out.writer, .err = &err2.writer }));
}

test "run: a GET with trailing directives goes out without a body; a POST's body is the JSON alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .status = 200, .status_text = "OK", .body = "{\"json\":{\"hello\":\"world\"}}" });
    defer server.stop(testing.io);
    try tmp.dir.createDirPath(testing.io, ".mnml/env");
    const envf = try std.fmt.allocPrint(testing.allocator, "BASE_URL=http://127.0.0.1:{d}\n", .{server.port});
    defer testing.allocator.free(envf);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/env/dev.env", .data = envf });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "get.http", .data = "### get-json\nGET {{BASE_URL}}/get\nAccept: application/json\n\n# @assert status == 200\n# @capture origin = body.origin\n" });
    const json = "{\n  \"hello\": \"world\"\n}";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "post.http", .data = "POST {{BASE_URL}}/post\nContent-Type: application/json\n\n" ++ json ++ "\n\n# @assert status == 200\n# @capture origin = body.json.hello\n" });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const get_path = try std.fs.path.join(testing.allocator, &.{ ws, "get.http" });
    defer testing.allocator.free(get_path);
    // Before the fix this was exit 134: std's assert on a GET with a body.
    try testing.expectEqual(@as(u8, 0), try run(testing.allocator, testing.io, &env, &.{ get_path, "--env", "dev" }, .{ .out = &out.writer, .err = &err.writer }));
    const seen_get = server.lastRequest();
    try testing.expect(std.mem.startsWith(u8, seen_get, "GET /get HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, seen_get, "@assert") == null);
    try testing.expect(std.ascii.indexOfIgnoreCase(seen_get, "content-length:") == null);
    try testing.expect(std.mem.endsWith(u8, seen_get, "\r\n\r\n"));
    const post_path = try std.fs.path.join(testing.allocator, &.{ ws, "post.http" });
    defer testing.allocator.free(post_path);
    try testing.expectEqual(@as(u8, 0), try run(testing.allocator, testing.io, &env, &.{ post_path, "--env", "dev" }, .{ .out = &out.writer, .err = &err.writer }));
    const seen_post = server.lastRequest();
    try testing.expect(std.mem.endsWith(u8, seen_post, "\r\n\r\n" ++ json));
    const want_len = try std.fmt.allocPrint(testing.allocator, "content-length: {d}\r\n", .{json.len});
    defer testing.allocator.free(want_len);
    try testing.expect(std.ascii.indexOfIgnoreCase(seen_post, want_len) != null);
}

test "run: `# @body-type form-urlencoded` / `multipart` put the pane's bytes on the wire" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    var server = try mock.Server.start(testing.allocator, testing.io, .{ .status = 200, .status_text = "OK", .body = "ok" });
    defer server.stop(testing.io);
    const form = try std.fmt.allocPrint(testing.allocator, "# @body-type form-urlencoded\nPOST http://127.0.0.1:{d}/echo\n\nname = alice\ncity = new york\n", .{server.port});
    defer testing.allocator.free(form);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "form.http", .data = form });
    const mp = try std.fmt.allocPrint(testing.allocator, "# @body-type multipart\nPOST http://127.0.0.1:{d}/up\n\nname = alice\nfile = @data.txt\n", .{server.port});
    defer testing.allocator.free(mp);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "up.http", .data = mp });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.txt", .data = "hello file\n" });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const form_path = try std.fs.path.join(testing.allocator, &.{ ws, "form.http" });
    defer testing.allocator.free(form_path);
    try testing.expectEqual(@as(u8, 0), try run(testing.allocator, testing.io, &env, &.{form_path}, .{ .out = &out.writer, .err = &err.writer }));
    try testing.expect(std.ascii.indexOfIgnoreCase(server.lastRequest(), "content-type: application/x-www-form-urlencoded\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, server.lastRequest(), "\r\n\r\nname=alice&city=new+york"));
    const up_path = try std.fs.path.join(testing.allocator, &.{ ws, "up.http" });
    defer testing.allocator.free(up_path);
    try testing.expectEqual(@as(u8, 0), try run(testing.allocator, testing.io, &env, &.{up_path}, .{ .out = &out.writer, .err = &err.writer }));
    try testing.expect(std.ascii.indexOfIgnoreCase(server.lastRequest(), "content-type: multipart/form-data; boundary=") != null);
    try testing.expect(std.mem.indexOf(u8, server.lastRequest(), "filename=\"data.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, server.lastRequest(), "hello file") != null);
}

test "discover then sync-check from the CLI" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &pbuf);
    const ws = pbuf[0..n];
    try tmp.dir.createDirPath(testing.io, ".mnml");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "spec.yaml", .data = "openapi: 3.0.0\npaths:\n  /a:\n    get:\n      operationId: getA\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mnml/sources.json", .data = "[{\"name\":\"s\",\"kind\":\"swagger\",\"url\":\"spec.yaml\",\"out\":\"stubs\"}]" });
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(testing.allocator);
    defer err.deinit();
    const spec = try std.fs.path.join(testing.allocator, &.{ ws, "spec.yaml" });
    defer testing.allocator.free(spec);
    const outdir = try std.fs.path.join(testing.allocator, &.{ ws, "stubs" });
    defer testing.allocator.free(outdir);
    try testing.expectEqual(@as(u8, 0), try discoverCmd(testing.allocator, testing.io, &.{ spec, "--out", outdir }, .{ .out = &out.writer, .err = &err.writer }));
    try testing.expect(std.mem.startsWith(u8, out.written(), "wrote 1 stub(s) under "));
    var out2: Io.Writer.Allocating = .init(testing.allocator);
    defer out2.deinit();
    try testing.expectEqual(@as(u8, 0), try syncCmd(testing.allocator, testing.io, &.{ "--workspace", ws }, .{ .out = &out2.writer, .err = &err.writer }, true));
    try testing.expect(std.mem.indexOf(u8, out2.written(), "no drift") != null);
    try testing.expectEqual(@as(u8, 1), try syncCmd(testing.allocator, testing.io, &.{ "--workspace", "/nope" }, .{ .out = &out2.writer, .err = &err.writer }, false));
    try testing.expect(std.mem.indexOf(u8, err.written(), "no sources.json") != null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const deep = try std.fs.path.join(arena.allocator(), &.{ ws, "stubs", "untagged" });
    try testing.expectEqualStrings(ws, try findWorkspace(arena.allocator(), testing.io, deep));
}
