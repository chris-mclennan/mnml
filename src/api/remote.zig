//! `mnml remote` (alias `mnml r`): drive a running mnml over its API
//! socket from a shell — inside one of its panes or from any terminal
//! (`docs/research/api-design.md` §7, phase 1's verbs).
//!
//!   mnml remote open PATH[:LINE[:COL]]
//!   mnml remote run COMMAND-ID
//!   mnml remote status | panes | ping | instances
//!   mnml remote call METHOD [JSON-PARAMS]
//!
//! Flags: `--json` (the result object verbatim), `--instance PID`,
//! `--workspace PATH`. Which instance: `MNML_API` (set in every pane, so
//! a command run in a pane reaches the mnml it runs in, as that pane),
//! then the flags, then the instance whose root holds the current
//! directory, then the only one running; otherwise exit 3 with the
//! candidates. A marker whose socket refuses and whose pid is dead is
//! removed by whoever finds it.
//!
//! Exit: 0 done · 1 the method failed · 2 usage · 3 no mnml (or several
//! and none matched) · 4 not permitted · 5 the user said no · 7 protocol
//! mismatch.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");
const server_mod = @import("server.zig");
const marker = @import("../tui/marker.zig");

pub const Exit = enum(u8) {
    ok = 0,
    failed = 1,
    usage = 2,
    no_instance = 3,
    not_permitted = 4,
    denied = 5,
    timeout = 6,
    protocol = 7,
};

pub const usage_text =
    \\usage: mnml remote [--json] [--instance PID] [--workspace PATH] VERB
    \\  open PATH[:LINE[:COL]]   open a file in the active pane
    \\  run COMMAND-ID           run a command (asks you unless it only views)
    \\  status                   the instance's status
    \\  panes                    the open panes
    \\  ping                     a round trip
    \\  instances                every running mnml
    \\  call METHOD [JSON]       any method, raw
    \\
;

const Opts = struct {
    json: bool = false,
    pid: ?i64 = null,
    workspace: ?[]const u8 = null,
    verb: []const u8 = "",
    args: []const []const u8 = &.{},
};

fn parseArgs(arena: Allocator, argv: []const []const u8) !?Opts {
    var o: Opts = .{};
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--instance")) {
            i += 1;
            if (i >= argv.len) return null;
            o.pid = std.fmt.parseInt(i64, argv[i], 10) catch return null;
        } else if (std.mem.eql(u8, a, "--workspace")) {
            i += 1;
            if (i >= argv.len) return null;
            o.workspace = argv[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return null;
        } else try rest.append(arena, a);
    }
    if (rest.items.len == 0) return null;
    o.verb = rest.items[0];
    o.args = rest.items[1..];
    return o;
}

pub const Std = struct { out: *Io.Writer, err: *Io.Writer };

/// The whole subcommand. `cwd` is where it was run (a real path).
pub fn run(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, argv: []const []const u8, s: Std) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const code = runInner(arena, io, env, cwd, argv, s) catch |err| blk: {
        s.err.print("mnml remote: {s}\n", .{@errorName(err)}) catch {};
        break :blk Exit.failed;
    };
    s.out.flush() catch {};
    s.err.flush() catch {};
    return @intFromEnum(code);
}

fn runInner(arena: Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, argv: []const []const u8, s: Std) !Exit {
    const o = try parseArgs(arena, argv) orelse {
        try s.err.writeAll(usage_text);
        return .usage;
    };
    if (std.mem.eql(u8, o.verb, "instances")) return instances(arena, io, env, o, s);

    // The request, before any connection: a usage error is a usage error
    // whether or not an mnml is running.
    var method: []const u8 = undefined;
    var params: []const u8 = "{}";
    if (std.mem.eql(u8, o.verb, "open")) {
        if (o.args.len != 1) return usageErr(s, "open needs PATH[:LINE[:COL]]");
        params = try openParams(arena, cwd, o.args[0]);
        method = "editor.open";
    } else if (std.mem.eql(u8, o.verb, "run")) {
        if (o.args.len != 1) return usageErr(s, "run needs a command id");
        var a: Io.Writer.Allocating = .init(arena);
        try a.writer.writeAll("{\"id\":");
        try std.json.Stringify.encodeJsonString(o.args[0], .{}, &a.writer);
        try a.writer.writeByte('}');
        params = a.written();
        method = "commands.run";
    } else if (std.mem.eql(u8, o.verb, "status")) {
        method = "state.status";
    } else if (std.mem.eql(u8, o.verb, "panes")) {
        method = "layout.panes";
    } else if (std.mem.eql(u8, o.verb, "ping")) {
        method = "ping";
    } else if (std.mem.eql(u8, o.verb, "call")) {
        if (o.args.len < 1 or o.args.len > 2) return usageErr(s, "call needs METHOD [JSON]");
        method = o.args[0];
        if (o.args.len == 2) params = o.args[1];
    } else return usageErr(s, "unknown verb");

    // Which instance, and whether this process is one of its panes.
    const target = try find(arena, io, env, cwd, o, s) orelse return .no_instance;
    const client = server_mod.Client.connect(io, target.socket) catch {
        try s.err.print("mnml remote: cannot connect to {s}\n", .{target.socket});
        return .no_instance;
    };
    defer client.close();

    var init_line: Io.Writer.Allocating = .init(arena);
    try init_line.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"client\":\"mnml remote\"");
    if (target.token) |tok| {
        try init_line.writer.writeAll(",\"token\":");
        try std.json.Stringify.encodeJsonString(tok, .{}, &init_line.writer);
    }
    try init_line.writer.writeAll("}}");
    const init_reply = try client.call(arena, init_line.written());
    const ir = try parseReply(arena, init_reply);
    if (ir.err) |e| return reportError(s, e);
    const ver = getStr(ir.result, "version") orelse "";
    if (!std.mem.eql(u8, ver, "v1")) {
        try s.err.print("mnml remote: the instance speaks `{s}`, this mnml speaks v1\n", .{ver});
        return .protocol;
    }

    const line = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}", .{ method, params });
    const reply = try client.call(arena, line);
    const r = try parseReply(arena, reply);
    if (r.err) |e| return reportError(s, e);
    if (o.json) {
        try s.out.print("{s}\n", .{r.raw_result});
        return .ok;
    }
    try human(s.out, o, r.result);
    return .ok;
}

fn usageErr(s: Std, msg: []const u8) !Exit {
    try s.err.print("mnml remote: {s}\n{s}", .{ msg, usage_text });
    return .usage;
}

/// `PATH[:LINE[:COL]]` as `editor.open`'s params, relative to `cwd`.
fn openParams(arena: Allocator, cwd: []const u8, spec: []const u8) ![]const u8 {
    var path = spec;
    var line: ?u32 = null;
    var col: ?u32 = null;
    // From the right: a trailing `:N` is a number only when it parses.
    if (std.mem.lastIndexOfScalar(u8, path, ':')) |i| if (std.fmt.parseInt(u32, path[i + 1 ..], 10)) |n| {
        line = n;
        path = path[0..i];
        if (std.mem.lastIndexOfScalar(u8, path, ':')) |j| if (std.fmt.parseInt(u32, path[j + 1 ..], 10)) |m| {
            col = n;
            line = m;
            path = path[0..j];
        } else |_| {};
    } else |_| {};
    const abs = if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(arena, &.{ cwd, path });
    var a: Io.Writer.Allocating = .init(arena);
    try a.writer.writeAll("{\"path\":");
    try std.json.Stringify.encodeJsonString(abs, .{}, &a.writer);
    if (line) |l| try a.writer.print(",\"line\":{d}", .{l});
    if (col) |c| try a.writer.print(",\"col\":{d}", .{c});
    try a.writer.writeByte('}');
    return a.written();
}

const Target = struct { socket: []const u8, token: ?[]const u8 };

fn find(arena: Allocator, io: Io, env: *const std.process.Environ.Map, cwd: []const u8, o: Opts, s: Std) !?Target {
    const own = env.get(paths.env_socket);
    const own_token = env.get(paths.env_token);
    if (own) |sock| if (sock.len > 0 and o.pid == null and o.workspace == null) {
        return .{ .socket = sock, .token = own_token };
    };
    const live = try liveInstances(arena, io, env);
    switch (paths.pick(live, cwd, o.pid, o.workspace)) {
        .one => |i| {
            const sock = live[i].socket;
            // A pane's token is good only on the socket it was minted for.
            const tok = if (own != null and std.mem.eql(u8, own.?, sock)) own_token else null;
            return .{ .socket = sock, .token = tok };
        },
        .none => {
            try s.err.writeAll(if (live.len == 0) "mnml remote: no mnml is running\n" else "mnml remote: no running mnml matched\n");
            try printCandidates(s.err, live);
            return null;
        },
        .ambiguous => {
            try s.err.writeAll("mnml remote: several mnml are running; pick one with --instance PID or --workspace PATH\n");
            try printCandidates(s.err, live);
            return null;
        },
    }
}

/// The markers in the directory, less the stale ones — which are removed.
fn liveInstances(arena: Allocator, io: Io, env: *const std.process.Environ.Map) ![]marker.Instance {
    const dir = try paths.dir(arena, env);
    const all = try marker.listInstances(arena, io, dir);
    var live: std.ArrayList(marker.Instance) = .empty;
    for (all) |inst| {
        const reachable = if (Io.net.UnixAddress.init(inst.socket)) |addr| blk: {
            const c = addr.connect(io) catch break :blk false;
            c.close(io);
            break :blk true;
        } else |_| false;
        if (!reachable and !paths.alive(inst.pid)) {
            const mp = try paths.markerPath(arena, dir, inst.pid);
            Io.Dir.cwd().deleteFile(io, mp) catch {};
            continue;
        }
        try live.append(arena, inst);
    }
    return live.items;
}

fn printCandidates(w: *Io.Writer, live: []const marker.Instance) !void {
    for (live) |inst| try w.print("  {d}  {s}  started {d}\n", .{ inst.pid, inst.workspace, inst.started_ms });
}

fn instances(arena: Allocator, io: Io, env: *const std.process.Environ.Map, o: Opts, s: Std) !Exit {
    const live = try liveInstances(arena, io, env);
    if (o.json) {
        try s.out.writeByte('[');
        for (live, 0..) |inst, i| {
            if (i > 0) try s.out.writeByte(',');
            try s.out.print("{{\"pid\":{d},\"version\":", .{inst.pid});
            try std.json.Stringify.encodeJsonString(inst.version, .{}, s.out);
            try s.out.writeAll(",\"workspace\":");
            try std.json.Stringify.encodeJsonString(inst.workspace, .{}, s.out);
            try s.out.writeAll(",\"socket\":");
            try std.json.Stringify.encodeJsonString(inst.socket, .{}, s.out);
            try s.out.print(",\"started_ms\":{d}}}", .{inst.started_ms});
        }
        try s.out.writeAll("]\n");
        return .ok;
    }
    if (live.len == 0) try s.out.writeAll("no mnml is running\n");
    for (live) |inst| try s.out.print("{d}  {s}  {s}\n", .{ inst.pid, inst.version, inst.workspace });
    return .ok;
}

const RpcError = struct { code: i64, message: []const u8 };
const Reply = struct {
    result: std.json.Value = .null,
    raw_result: []const u8 = "null",
    err: ?RpcError = null,
};

fn parseReply(arena: Allocator, line: []const u8) !Reply {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return error.BadReply;
    const obj = switch (v) {
        .object => |o| o,
        else => return error.BadReply,
    };
    if (obj.get("error")) |e| {
        const eo = switch (e) {
            .object => |x| x,
            else => return error.BadReply,
        };
        const code = switch (eo.get("code") orelse .null) {
            .integer => |i| i,
            else => 0,
        };
        const msg = switch (eo.get("message") orelse .null) {
            .string => |m| m,
            else => "",
        };
        return .{ .err = .{ .code = code, .message = msg } };
    }
    const res = obj.get("result") orelse .null;
    return .{ .result = res, .raw_result = try std.json.Stringify.valueAlloc(arena, res, .{}) };
}

fn reportError(s: Std, e: RpcError) !Exit {
    try s.err.print("mnml remote: {s}\n", .{e.message});
    return switch (e.code) {
        -32001 => .not_permitted,
        -32002 => .denied,
        -32601 => .protocol,
        -32600, -32602 => .usage,
        else => .failed,
    };
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .string => |x| x,
        else => null,
    };
}

fn getInt(v: std.json.Value, key: []const u8) ?i64 {
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .integer => |x| x,
        else => null,
    };
}

fn getBool(v: std.json.Value, key: []const u8) bool {
    const o = switch (v) {
        .object => |o| o,
        else => return false,
    };
    return switch (o.get(key) orelse return false) {
        .bool => |x| x,
        else => false,
    };
}

/// The line a person reads.
fn human(w: *Io.Writer, o: Opts, res: std.json.Value) !void {
    if (std.mem.eql(u8, o.verb, "open")) {
        try w.print("opened {s} in pane {d}\n", .{ o.args[0], getInt(res, "pane") orelse 0 });
    } else if (std.mem.eql(u8, o.verb, "run")) {
        try w.print("ran {s}\n", .{o.args[0]});
    } else if (std.mem.eql(u8, o.verb, "ping")) {
        try w.writeAll("pong\n");
    } else if (std.mem.eql(u8, o.verb, "panes")) {
        const arr = switch (res) {
            .array => |a| a.items,
            else => &.{},
        };
        for (arr) |p| try w.print("{d}\t{s}\t{s}{s}{s}\n", .{
            getInt(p, "pane") orelse 0,
            getStr(p, "kind") orelse "",
            getStr(p, "title") orelse "",
            if (getBool(p, "dirty")) " ●" else "",
            if (getBool(p, "active")) "  (active)" else "",
        });
    } else if (std.mem.eql(u8, o.verb, "status")) {
        const file = getStr(res, "activeFile") orelse "";
        try w.print("focus {s} · {s}", .{ getStr(res, "focus") orelse "?", if (file.len > 0) file else "no file" });
        const cur = switch (res) {
            .object => |ob| ob.get("cursor") orelse .null,
            else => .null,
        };
        if (file.len > 0) try w.print(":{d}:{d}", .{ getInt(cur, "line") orelse 0, getInt(cur, "col") orelse 0 });
        try w.print(" · mode {s}\n", .{getStr(res, "mode") orelse "?"});
    } else {
        const raw = try std.json.Stringify.valueAlloc(std.heap.page_allocator, res, .{});
        defer std.heap.page_allocator.free(raw);
        try w.print("{s}\n", .{raw});
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "open's PATH[:LINE[:COL]] becomes editor.open's params, relative to where it was run" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqualStrings("{\"path\":\"/w/src/main.zig\",\"line\":120}", try openParams(a, "/w", "src/main.zig:120"));
    try t.expectEqualStrings("{\"path\":\"/x.zig\",\"line\":3,\"col\":9}", try openParams(a, "/w", "/x.zig:3:9"));
    try t.expectEqualStrings("{\"path\":\"/w/a:b\"}", try openParams(a, "/w", "a:b"));
}

test "usage errors exit 2 before any instance is looked for" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put(paths.env_dir, "/no/such/api/dir");
    var out: Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    var err: Io.Writer.Allocating = .init(t.allocator);
    defer err.deinit();
    const s: Std = .{ .out = &out.writer, .err = &err.writer };
    try t.expectEqual(@as(u8, 2), run(t.allocator, t.io, &env, "/w", &.{}, s));
    try t.expectEqual(@as(u8, 2), run(t.allocator, t.io, &env, "/w", &.{"frobnicate"}, s));
    try t.expectEqual(@as(u8, 2), run(t.allocator, t.io, &env, "/w", &.{"open"}, s));
    // Well formed, and nothing running: 3.
    try t.expectEqual(@as(u8, 3), run(t.allocator, t.io, &env, "/w", &.{"status"}, s));
    try t.expect(std.mem.indexOf(u8, err.written(), "no mnml is running") != null);
}
