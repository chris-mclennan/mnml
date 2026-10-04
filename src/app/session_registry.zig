//! Claude Code's live-session registry: each running CLI keeps
//! `~/.claude/sessions/<pid>.json` — its pid, session id, cwd, name
//! (and who chose it), its status (busy / idle / waiting) and the Unix
//! socket its inbox listens on. SESSIONS reads it on the stat tick for
//! the EXTERNAL rows' names and states, and `sessions.ask_external` /
//! `sessions.take_over` act through it.
//!
//! The format is Claude Code's own, undocumented and liable to change
//! (`docs/API.md`, "Claude Code's session registry"): a file that does
//! not parse, or lacks a pid or a session id, is skipped, and the
//! transcripts stay the listing. Only `*.json` is opened — the directory
//! also holds files that are none of mnml's business.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Status = enum {
    busy,
    idle,
    waiting,
    unknown,

    pub fn label(s: Status) []const u8 {
        return switch (s) {
            .busy => "busy",
            .idle => "idle",
            .waiting => "waiting",
            .unknown => "?",
        };
    }

    fn parse(s: []const u8) Status {
        inline for (.{ .busy, .idle, .waiting }) |v| if (std.mem.eql(u8, s, @tagName(v))) return v;
        return .unknown;
    }
};

/// One live session as its file states it. Slices borrow the entry's
/// arena: valid until the next `refresh` that sees the file change or go.
pub const Record = struct {
    pid: u32,
    session_id: []const u8,
    cwd: ?[]const u8 = null,
    /// The name, any source; `user_named` when the user chose it
    /// (`nameSource: "user"` — `/rename`, `--name`).
    name: ?[]const u8 = null,
    user_named: bool = false,
    status: Status = .unknown,
    /// `messagingSocketPath`: the session's inbox, when it binds one.
    socket: ?[]const u8 = null,

    /// What a row calls it: the user's name, else the generated one,
    /// else the cwd's basename, else the short id.
    pub fn title(r: Record) []const u8 {
        if (r.name) |n| if (n.len > 0) return n;
        if (r.cwd) |c| {
            const b = std.fs.path.basename(c);
            if (b.len > 0) return b;
        }
        return r.session_id[0..@min(8, r.session_id.len)];
    }
};

/// The file's record, or null for anything that is not one: not JSON,
/// not an object, no positive integer pid, no session id. Unknown and
/// mistyped fields are ignored.
pub fn parse(arena: Allocator, bytes: []const u8) ?Record {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return null;
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const pid: u32 = switch (o.get("pid") orelse return null) {
        .integer => |n| if (n > 0 and n <= std.math.maxInt(u32)) @intCast(n) else return null,
        else => return null,
    };
    const sid = str(o, "sessionId") orelse return null;
    if (sid.len == 0) return null;
    const name = str(o, "name");
    const src = str(o, "nameSource");
    return .{
        .pid = pid,
        .session_id = sid,
        .cwd = str(o, "cwd"),
        .name = if (name) |n| (if (n.len > 0) n else null) else null,
        .user_named = if (src) |s| std.mem.eql(u8, s, "user") else false,
        .status = if (str(o, "status")) |s| Status.parse(s) else .unknown,
        .socket = if (str(o, "messagingSocketPath")) |s| (if (s.len > 0) s else null) else null,
    };
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// The directory's records, re-read per file only when its size or
/// mtime moved — a handful of stats a tick.
pub const Cache = struct {
    map: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    pass: u32 = 0,
    /// Files parsed (tests count work).
    reads: u64 = 0,

    const Entry = struct {
        arena: std.heap.ArenaAllocator,
        size: u64,
        mtime_ns: i96,
        pass: u32,
        rec: ?Record,
    };

    pub fn deinit(c: *Cache, gpa: Allocator) void {
        for (c.map.keys(), c.map.values()) |k, *e| {
            gpa.free(k);
            e.arena.deinit();
        }
        c.map.deinit(gpa);
    }

    pub fn clear(c: *Cache, gpa: Allocator) void {
        c.deinit(gpa);
        c.* = .{ .pass = c.pass, .reads = c.reads };
    }

    /// Read `dir_path` again. Whether any record changed.
    pub fn refresh(c: *Cache, io: Io, gpa: Allocator, dir_path: []const u8) Allocator.Error!bool {
        c.pass +%= 1;
        var changed = false;
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
            changed = c.map.count() > 0;
            c.clear(gpa);
            return changed;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |f| {
            if (f.kind != .file or !std.mem.endsWith(u8, f.name, ".json")) continue;
            const stat = dir.statFile(io, f.name, .{}) catch continue;
            if (stat.size > max_file_bytes) continue;
            if (c.map.getPtr(f.name)) |e| if (e.size == stat.size and e.mtime_ns == stat.mtime.nanoseconds) {
                e.pass = c.pass;
                continue;
            };
            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const bytes = dir.readFileAlloc(io, f.name, arena.allocator(), .limited(max_file_bytes)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    arena.deinit();
                    continue;
                },
            };
            c.reads += 1;
            const rec = parse(arena.allocator(), bytes);
            const gop = try c.map.getOrPut(gpa, f.name);
            if (gop.found_existing) {
                gop.value_ptr.arena.deinit();
            } else {
                gop.key_ptr.* = gpa.dupe(u8, f.name) catch |err| {
                    c.map.orderedRemoveAt(gop.index);
                    return err;
                };
            }
            gop.value_ptr.* = .{ .arena = arena, .size = stat.size, .mtime_ns = stat.mtime.nanoseconds, .pass = c.pass, .rec = rec };
            changed = true;
        }
        var i: usize = 0;
        while (i < c.map.count()) {
            if (c.map.values()[i].pass != c.pass) {
                gpa.free(c.map.keys()[i]);
                c.map.values()[i].arena.deinit();
                c.map.orderedRemoveAt(i);
                changed = true;
            } else i += 1;
        }
        return changed;
    }

    /// The record for `session_id`, if a live CLI claims it.
    pub fn find(c: *const Cache, session_id: []const u8) ?Record {
        for (c.map.values()) |e| if (e.rec) |r| if (std.mem.eql(u8, r.session_id, session_id)) return r;
        return null;
    }

    pub fn findPid(c: *const Cache, pid: u32) ?Record {
        for (c.map.values()) |e| if (e.rec) |r| if (r.pid == pid) return r;
        return null;
    }

    /// Every parsed record, in file order.
    pub fn records(c: *const Cache, arena: Allocator) Allocator.Error![]Record {
        var out: std.ArrayListUnmanaged(Record) = .empty;
        for (c.map.values()) |e| if (e.rec) |r| try out.append(arena, r);
        return out.items;
    }
};

const max_file_bytes: u64 = 64 * 1024;

/// `<home>/.claude/sessions`.
pub fn dirPath(arena: Allocator, home: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ home, ".claude", "sessions" });
}

// ─── ask: one line to the session's inbox ─────────────────────────────

pub const ask_text = "mnml asks: in one line, what are you working on right now, and is it safe to interrupt? Reply via SendMessage.";

/// The documented cross-session message shape, one line.
pub fn userLine(arena: Allocator, text: []const u8) Allocator.Error![]u8 {
    const Msg = struct { type: []const u8 = "user", message: struct { role: []const u8 = "user", content: []const u8 } };
    var out: Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(Msg{ .message = .{ .content = text } }, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub const SendError = error{ Unsupported, Unreachable, OutOfMemory };

/// Connect to `socket_path`, write the line, close. Windows inboxes are
/// named pipes with a required auth line: not yet.
pub fn send(io: Io, arena: Allocator, socket_path: []const u8, text: []const u8) SendError!void {
    if (builtin.os.tag == .windows) return error.Unsupported;
    const line = try userLine(arena, text);
    const addr = Io.net.UnixAddress.init(socket_path) catch return error.Unreachable;
    const stream = addr.connect(io) catch return error.Unreachable;
    defer stream.close(io);
    var buf: [1024]u8 = undefined;
    var w = stream.writer(io, &buf);
    w.interface.writeAll(line) catch return error.Unreachable;
    w.interface.flush() catch return error.Unreachable;
}

// ─── take over: the signal step, behind an interface ──────────────────

/// What `sessions.take_over` does to another process: read its command
/// line, send it SIGTERM. Tests hand in a fake; nothing else signals.
pub const Signaler = struct {
    ctx: ?*anyopaque = null,
    cmdline: *const fn (ctx: ?*anyopaque, io: Io, gpa: Allocator, arena: Allocator, pid: u32) ?[]const u8 = osCmdline,
    term: *const fn (ctx: ?*anyopaque, io: Io, gpa: Allocator, pid: u32) bool = osTerm,
};

fn osCmdline(_: ?*anyopaque, io: Io, gpa: Allocator, arena: Allocator, pid: u32) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    var buf: [16]u8 = undefined;
    const arg = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return null;
    const r = std.process.run(gpa, io, .{ .argv = &.{ "ps", "-o", "command=", "-p", arg } }) catch return null;
    defer gpa.free(r.stderr);
    defer gpa.free(r.stdout);
    if (!(r.term == .exited and r.term.exited == 0)) return null;
    const line = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (line.len == 0) return null;
    return arena.dupe(u8, line) catch null;
}

fn osTerm(_: ?*anyopaque, io: Io, gpa: Allocator, pid: u32) bool {
    if (builtin.os.tag == .windows) return false;
    var buf: [16]u8 = undefined;
    const arg = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return false;
    const r = std.process.run(gpa, io, .{ .argv = &.{ "kill", "-TERM", arg } }) catch return false;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    return r.term == .exited and r.term.exited == 0;
}

/// A command line that is Claude Code's CLI: its program is `claude`, or
/// a JS runtime running the `claude-code` package. Anything else is
/// refused — a pid the registry names may since belong to another
/// process.
pub fn isClaudeCmdline(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    const prog = it.next() orelse return false;
    const base = std.fs.path.basename(prog);
    if (std.mem.eql(u8, base, "claude")) return true;
    if (!(std.mem.eql(u8, base, "node") or std.mem.eql(u8, base, "bun"))) return false;
    while (it.next()) |a| {
        if (a.len > 0 and a[0] == '-') continue;
        return std.mem.indexOf(u8, a, "claude-code") != null or std.mem.eql(u8, std.fs.path.basename(a), "claude");
    }
    return false;
}

/// May `sessions.take_over` end this session? Only at rest.
pub fn takeOverAllowed(s: Status) bool {
    return s == .idle or s == .waiting;
}

// ─── tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "session_registry: parse: a full record; the user's name; the status" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const r = parse(a.allocator(),
        \\{"pid":4242,"sessionId":"abcd1234-0000","cwd":"/w/proj","name":"payments","nameSource":"user","status":"waiting","kind":"interactive","messagingSocketPath":"/tmp/cc-socks/4242.sock","peerProtocol":1,"peerFeatures":["x"],"updatedAt":1}
    ).?;
    try testing.expectEqual(@as(u32, 4242), r.pid);
    try testing.expectEqualStrings("abcd1234-0000", r.session_id);
    try testing.expectEqualStrings("payments", r.title());
    try testing.expect(r.user_named);
    try testing.expectEqual(Status.waiting, r.status);
    try testing.expectEqualStrings("/tmp/cc-socks/4242.sock", r.socket.?);
}

test "session_registry: parse: garbage and missing fields are not records; odd fields are ignored" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    for ([_][]const u8{ "", "nope", "[]", "{}", "{\"pid\":1}", "{\"sessionId\":\"s\"}", "{\"pid\":-3,\"sessionId\":\"s\"}", "{\"pid\":\"7\",\"sessionId\":\"s\"}", "{\"pid\":7,\"sessionId\":\"\"}", "{\"pid\":7,\"sessionId\":3}", "{\"pid\":7,\"sessionId\":\"s\"" }) |bad|
        try testing.expect(parse(ar, bad) == null);
    const r = parse(ar, "{\"pid\":7,\"sessionId\":\"s\",\"status\":42,\"name\":[1],\"cwd\":\"/x/y\",\"status2\":\"busy\"}").?;
    try testing.expectEqual(Status.unknown, r.status);
    try testing.expect(r.name == null and !r.user_named);
    try testing.expectEqualStrings("y", r.title());
    try testing.expectEqual(Status.unknown, parse(ar, "{\"pid\":7,\"sessionId\":\"s\",\"status\":\"napping\"}").?.status);
}

test "session_registry: Cache: reads *.json only, re-reads on change, forgets a removed file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "11.json", .data = "{\"pid\":11,\"sessionId\":\"aaa\",\"status\":\"busy\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "12.json", .data = "garbage" });
    try tmp.dir.writeFile(io, .{ .sub_path = "11.key", .data = "never read" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var c: Cache = .{};
    defer c.deinit(gpa);
    try testing.expect(try c.refresh(io, gpa, path));
    try testing.expectEqual(@as(u64, 2), c.reads);
    try testing.expectEqual(Status.busy, c.find("aaa").?.status);
    try testing.expect(c.findPid(12) == null);
    // Nothing moved: nothing read.
    try testing.expect(!try c.refresh(io, gpa, path));
    try testing.expectEqual(@as(u64, 2), c.reads);
    try tmp.dir.writeFile(io, .{ .sub_path = "11.json", .data = "{\"pid\":11,\"sessionId\":\"aaa\",\"status\":\"idle\",\"x\":1}" });
    try testing.expect(try c.refresh(io, gpa, path));
    try testing.expectEqual(Status.idle, c.find("aaa").?.status);
    try tmp.dir.deleteFile(io, "11.json");
    try testing.expect(try c.refresh(io, gpa, path));
    try testing.expect(c.find("aaa") == null);
    // The directory gone: empty, no error.
    _ = try c.refresh(io, gpa, "/nonexistent-mnml-registry-dir");
    try testing.expectEqual(@as(usize, 0), c.map.count());
}

test "session_registry: userLine: the documented shape, one line" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const line = try userLine(a.allocator(), "say \"hi\"");
    try testing.expectEqualStrings("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"say \\\"hi\\\"\"}}\n", line);
}

test "session_registry: isClaudeCmdline: claude, or node running claude-code; nothing else" {
    try testing.expect(isClaudeCmdline("claude"));
    try testing.expect(isClaudeCmdline("/opt/homebrew/bin/claude --resume abc"));
    try testing.expect(isClaudeCmdline("node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"));
    try testing.expect(!isClaudeCmdline("vim notes.md"));
    try testing.expect(!isClaudeCmdline("/bin/zsh -c claude"));
    try testing.expect(!isClaudeCmdline("node server.js"));
    try testing.expect(!isClaudeCmdline("claudette"));
    try testing.expect(!isClaudeCmdline(""));
}

test "session_registry: takeOverAllowed: idle and waiting only" {
    try testing.expect(!takeOverAllowed(.busy));
    try testing.expect(!takeOverAllowed(.unknown));
    try testing.expect(takeOverAllowed(.idle));
    try testing.expect(takeOverAllowed(.waiting));
}
