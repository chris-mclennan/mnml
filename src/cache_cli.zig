//! `mnml cache` — the shared recent-items cache (`sdk.cache`,
//! `docs/SDK.md` "The recent-items cache") from a shell:
//!
//!   mnml cache get <kind> <id>                    the record as JSON; exit 1 when absent
//!   mnml cache ls <kind> [--source S] [--limit N] one line per record, newest first
//!   mnml cache clear [kind] [--yes]               remove the files, after asking
//!
//! `<kind>` is `ticket`, `pr`, `pipeline` or `release`. The directory is
//! the one every integration writes: `$MNML_SHARED_STATE_DIR/recent`,
//! else `<MNML_DATA_ROOT>/recent`, else `~/.config/mnml/recent`. Reading
//! never writes; `clear` is the one thing the host removes, and only on
//! the user's ask.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sdk = @import("mnml_sdk");
const cache = sdk.cache;

pub const Std = struct {
    out: *Io.Writer,
    err: *Io.Writer,
    /// Where `clear`'s answer is read; null reads stdin.
    in: ?*Io.Reader = null,
};

const usage_text =
    \\usage: mnml cache get <kind> <id>
    \\       mnml cache ls <kind> [--source S] [--limit N]
    \\       mnml cache clear [kind] [--yes]
    \\kinds: ticket, pr, pipeline, release
    \\
;

/// The exit code.
pub fn run(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, s: Std) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const code = dispatch(arena_state.allocator(), io, env, argv, s) catch |e| blk: {
        s.err.print("mnml cache: {s}\n", .{@errorName(e)}) catch {};
        break :blk 1;
    };
    s.out.flush() catch {};
    s.err.flush() catch {};
    return code;
}

fn dispatch(a: Allocator, io: Io, env: *const std.process.Environ.Map, argv: []const []const u8, s: Std) !u8 {
    if (argv.len == 0) {
        try s.err.writeAll(usage_text);
        return 2;
    }
    const root = (try cache.rootDir(a, env)) orelse {
        try s.err.writeAll("mnml cache: no home directory to find the cache under\n");
        return 1;
    };
    const verb = argv[0];
    if (std.mem.eql(u8, verb, "get")) {
        if (argv.len != 3) return usageError(s);
        const kind = kindOf(argv[1]) orelse return badKind(s, argv[1]);
        return switch (kind) {
            inline else => |k| get(k, a, io, root, argv[2], s),
        };
    }
    if (std.mem.eql(u8, verb, "ls")) {
        if (argv.len < 2) return usageError(s);
        const kind = kindOf(argv[1]) orelse return badKind(s, argv[1]);
        var q: cache.Query = .{};
        var i: usize = 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--source") and i + 1 < argv.len) {
                i += 1;
                q.source = argv[i];
            } else if (std.mem.eql(u8, argv[i], "--limit") and i + 1 < argv.len) {
                i += 1;
                q.limit = std.fmt.parseInt(usize, argv[i], 10) catch return usageError(s);
            } else return usageError(s);
        }
        return switch (kind) {
            inline else => |k| ls(k, a, io, root, q, s),
        };
    }
    if (std.mem.eql(u8, verb, "clear")) {
        var kind: ?cache.Kind = null;
        var yes = false;
        for (argv[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
                yes = true;
            } else if (kind == null) {
                kind = kindOf(arg) orelse return badKind(s, arg);
            } else return usageError(s);
        }
        return clear(a, io, root, kind, yes, s);
    }
    return usageError(s);
}

fn usageError(s: Std) !u8 {
    try s.err.writeAll(usage_text);
    return 2;
}

fn badKind(s: Std, k: []const u8) !u8 {
    try s.err.print("mnml cache: no kind `{s}` — ticket, pr, pipeline or release\n", .{k});
    return 2;
}

fn kindOf(name: []const u8) ?cache.Kind {
    return std.meta.stringToEnum(cache.Kind, name);
}

fn nowSecs(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

fn get(comptime kind: cache.Kind, a: Allocator, io: Io, root: []const u8, id: []const u8, s: Std) !u8 {
    const found = cache.getAt(kind, a, io, root, id, nowSecs(io)) orelse {
        try s.err.print("mnml cache: no {s} `{s}`\n", .{ @tagName(kind), id });
        return 1;
    };
    try s.out.print("{f}\n", .{std.json.fmt(found, .{})});
    return 0;
}

fn ls(comptime kind: cache.Kind, a: Allocator, io: Io, root: []const u8, q: cache.Query, s: Std) !u8 {
    for (cache.queryAt(kind, a, io, root, q, nowSecs(io))) |r| {
        const rec = r.record;
        const title, const status = switch (kind) {
            .ticket => .{ rec.summary, rec.status },
            .pr => .{ rec.title, rec.state },
            .pipeline => .{ rec.ref_name, if (rec.result.len > 0) rec.result else rec.state },
            .release => .{ rec.role, rec.state },
        };
        try s.out.print("{s}\t{s}\t{s}\t{s}{s}\n", .{ rec.id, title, status, r.source, if (r.stale) "\tstale" else "" });
    }
    return 0;
}

/// Every `<source>/<kind>.json` (and its lock) under `root`; with no
/// kind, every source's directory whole. Asks first unless `yes`.
fn clear(a: Allocator, io: Io, root: []const u8, kind: ?cache.Kind, yes: bool, s: Std) !u8 {
    var doomed: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
        try s.out.writeAll("mnml cache: nothing to clear\n");
        return 0;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        if (kind) |k| {
            const path = try cache.filePath(a, root, e.name, k);
            _ = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
            try doomed.append(a, path);
        } else try doomed.append(a, try std.fs.path.join(a, &.{ root, e.name }));
    }
    if (doomed.items.len == 0) {
        try s.out.writeAll("mnml cache: nothing to clear\n");
        return 0;
    }
    if (!yes) {
        try s.err.print("remove {d} {s} of the recent-items cache under {s}? [y/N] ", .{ doomed.items.len, if (kind == null) "source directories" else "files", root });
        try s.err.flush();
        var in_buf: [64]u8 = undefined;
        var stdin: Io.File.Reader = .initStreaming(.stdin(), io, &in_buf);
        const r: *Io.Reader = s.in orelse &stdin.interface;
        const line = r.takeDelimiterInclusive('\n') catch "";
        const answer = std.mem.trim(u8, line, " \t\r\n");
        if (!(std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes"))) {
            try s.err.writeAll("left as it was\n");
            return 1;
        }
    }
    for (doomed.items) |path| {
        if (kind != null) {
            Io.Dir.cwd().deleteFile(io, path) catch {};
            const lock = try std.fmt.allocPrint(a, "{s}.lock", .{path[0 .. path.len - ".json".len]});
            Io.Dir.cwd().deleteFile(io, lock) catch {};
        } else Io.Dir.cwd().deleteTree(io, path) catch {};
    }
    try s.out.print("mnml cache: removed {d}\n", .{doomed.items.len});
    return 0;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Rig = struct {
    tmp: t.TmpDir,
    shared: []u8,
    root: []u8,
    env: std.process.Environ.Map,
    out: Io.Writer.Allocating,
    err: Io.Writer.Allocating,

    fn init(r: *Rig) !void {
        r.tmp = t.tmpDir(.{});
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        r.shared = try t.allocator.dupe(u8, pbuf[0..try r.tmp.dir.realPath(t.io, &pbuf)]);
        r.root = try std.fs.path.join(t.allocator, &.{ r.shared, "recent" });
        r.env = .init(t.allocator);
        try r.env.put("MNML_SHARED_STATE_DIR", r.shared);
        r.out = .init(t.allocator);
        r.err = .init(t.allocator);
        const tickets = [_]cache.Ticket{.{ .id = "ACME-123", .summary = "Fix the login redirect", .status = "In Review", .assignee = "Pat Example" }};
        try t.expectEqual(cache.Outcome.written, cache.putAt(t.allocator, t.io, r.root, .{ .source = "jira", .kind = .ticket, .stale_after_secs = 600 }, &tickets));
        const prs = [_]cache.Pr{
            .{ .id = "acme/widget#44", .title = "Bump the client timeout", .state = "MERGED", .author = "Max Orr" },
            .{ .id = "acme/widget#45", .title = "Redesign the empty state", .state = "OPEN", .author = "Max Orr" },
        };
        try t.expectEqual(cache.Outcome.written, cache.putAt(t.allocator, t.io, r.root, .{ .source = "bitbucket", .kind = .pr, .stale_after_secs = 600 }, &prs));
    }

    fn deinit(r: *Rig) void {
        r.out.deinit();
        r.err.deinit();
        r.env.deinit();
        t.allocator.free(r.root);
        t.allocator.free(r.shared);
        r.tmp.cleanup();
    }

    fn call(r: *Rig, argv: []const []const u8, in: ?*Io.Reader) u8 {
        r.out.clearRetainingCapacity();
        r.err.clearRetainingCapacity();
        return run(t.allocator, t.io, &r.env, argv, .{ .out = &r.out.writer, .err = &r.err.writer, .in = in });
    }

    fn exists(r: *Rig, source: []const u8, kind: cache.Kind) bool {
        const path = cache.filePath(t.allocator, r.root, source, kind) catch return false;
        defer t.allocator.free(path);
        _ = Io.Dir.cwd().statFile(t.io, path, .{}) catch return false;
        return true;
    }
};

test "mnml cache get: the record as JSON, exit 1 when absent; ls: newest first, by source, limited" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    try t.expectEqual(@as(u8, 0), r.call(&.{ "get", "pr", "acme/widget#45" }, null));
    try t.expect(std.mem.indexOf(u8, r.out.written(), "\"title\":\"Redesign the empty state\"") != null);
    try t.expect(std.mem.indexOf(u8, r.out.written(), "\"source\":\"bitbucket\"") != null);
    try t.expectEqual(@as(u8, 1), r.call(&.{ "get", "pr", "acme/widget#9" }, null));
    try t.expectEqual(@as(u8, 2), r.call(&.{ "get", "prs", "acme/widget#45" }, null));
    try t.expectEqual(@as(u8, 0), r.call(&.{ "ls", "pr" }, null));
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, r.out.written(), "\n"));
    try t.expect(std.mem.indexOf(u8, r.out.written(), "acme/widget#45\tRedesign the empty state\tOPEN\tbitbucket\n") != null);
    try t.expectEqual(@as(u8, 0), r.call(&.{ "ls", "pr", "--limit", "1" }, null));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, r.out.written(), "\n"));
    try t.expectEqual(@as(u8, 0), r.call(&.{ "ls", "pr", "--source", "jira" }, null));
    try t.expectEqualStrings("", r.out.written());
    try t.expectEqual(@as(u8, 0), r.call(&.{ "ls", "ticket" }, null));
    try t.expectEqualStrings("ACME-123\tFix the login redirect\tIn Review\tjira\n", r.out.written());
}

test "mnml cache clear: asks first, a no leaves everything; a kind removes that kind's files; none removes every source" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    var no: Io.Reader = .fixed("n\n");
    try t.expectEqual(@as(u8, 1), r.call(&.{ "clear", "pr" }, &no));
    try t.expect(r.exists("bitbucket", .pr));
    var yes: Io.Reader = .fixed("y\n");
    try t.expectEqual(@as(u8, 0), r.call(&.{ "clear", "pr" }, &yes));
    try t.expect(!r.exists("bitbucket", .pr));
    try t.expect(r.exists("jira", .ticket));
    try t.expectEqual(@as(u8, 0), r.call(&.{ "clear", "--yes" }, null));
    try t.expect(!r.exists("jira", .ticket));
    try t.expectEqual(@as(u8, 0), r.call(&.{"clear"}, null));
    try t.expect(std.mem.indexOf(u8, r.out.written(), "nothing to clear") != null);
}
