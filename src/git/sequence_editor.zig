//! mnml as git's own sequence editor. An interactive rebase asks an
//! editor to rewrite its todo and, for a `reword`, a commit's message;
//! the worker (`client.zig`, `Job.rebase_plan`) points both at this
//! executable — `GIT_SEQUENCE_EDITOR` and `GIT_EDITOR` in the child's
//! environment, which beat any `core.editor` — and exits are the
//! whole protocol:
//!
//!   mnml-zig --rebase-todo <plan> <todo>     # overwrite git's todo with the plan
//!   mnml-zig --commit-msg  <queue> <target>  # a reworded message from the queue
//!
//! The plan is a todo file the app wrote from the graph's selection,
//! oldest first, with git's own words (`pick reword edit squash fixup
//! drop`) and full shas. The child checks it against the todo git
//! generated — every sha in the plan must be one git listed, and every
//! listed commit must be in the plan (a missing line would be a drop
//! git only warns about) — then copies it over. A mismatch exits 1,
//! which makes git abort the rebase with the child's reason.
//!
//! The queue keys reworded messages by the commit's OLD subject, not by
//! position: git opens the editor once per `reword` and once per run of
//! `squash`es, so counting invocations would hand a squash a reword's
//! message. The child reads the first non-comment line of the file git
//! handed it, looks that subject up, writes the new message and drops
//! the record. A squash's combined message (its first line is the pick's
//! subject, which has no record) is left as git wrote it, and so is
//! anything the queue does not name. Nothing here touches `App` or runs
//! `git`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");

pub const Action = parse.TodoAction;

/// One line of the plan as the app builds it. `subject` is the commit's
/// current subject — the queue's key for a reword. Strings are owned by
/// the job that carries the op (`Job.deinit`).
pub const Op = struct {
    sha: []u8,
    action: Action,
    subject: []u8 = &.{},
    new_message: ?[]u8 = null,

    pub fn deinit(op: Op, gpa: Allocator) void {
        gpa.free(op.sha);
        if (op.subject.len > 0) gpa.free(op.subject);
        if (op.new_message) |m| gpa.free(m);
    }
};

/// The todo text for `ops`, oldest first: `<action> <sha> <subject>`.
pub fn todoText(arena: Allocator, ops: []const Op) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (ops) |op| {
        try out.appendSlice(arena, op.action.word());
        try out.append(arena, ' ');
        try out.appendSlice(arena, op.sha);
        if (op.subject.len > 0) {
            try out.append(arena, ' ');
            try out.appendSlice(arena, firstLine(op.subject));
        }
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

/// The queue text: one `<subject>\n<message>` record per op with a new
/// message, `\x00` between records.
pub fn queueText(arena: Allocator, ops: []const Op) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var n: usize = 0;
    for (ops) |op| {
        const msg = op.new_message orelse continue;
        if (n > 0) try out.append(arena, 0);
        try out.appendSlice(arena, firstLine(op.subject));
        try out.append(arena, '\n');
        try out.appendSlice(arena, std.mem.trim(u8, msg, " \t\r\n"));
        n += 1;
    }
    return out.toOwnedSlice(arena);
}

/// A value for `GIT_SEQUENCE_EDITOR` / `GIT_EDITOR`: git hands it to
/// `sh -c`, so the exe and the file are single-quoted (a quote inside
/// becomes `'\''`).
pub fn editorCommand(arena: Allocator, exe: []const u8, flag: []const u8, file: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{s} {s} {s}", .{ try shQuote(arena, exe), flag, try shQuote(arena, file) });
}

fn shQuote(arena: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.toOwnedSlice(arena);
}

pub const Error = error{ PlanMismatch, ReadFailed, WriteFailed } || Allocator.Error;

/// `--rebase-todo`: the plan at `plan_path` replaces the todo at
/// `todo_path` once every commit is accounted for on both sides.
/// `reason` (when given) receives what went wrong, on `gpa`.
pub fn writeTodo(io: Io, gpa: Allocator, plan_path: []const u8, todo_path: []const u8, reason: ?*?[]u8) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    const plan = cwd.readFileAlloc(io, plan_path, arena, .limited(16 * 1024 * 1024)) catch return error.ReadFailed;
    const todo = cwd.readFileAlloc(io, todo_path, arena, .limited(16 * 1024 * 1024)) catch return error.ReadFailed;
    if (try mismatch(arena, plan, todo)) |why| {
        if (reason) |r| r.* = gpa.dupe(u8, why) catch null;
        return error.PlanMismatch;
    }
    cwd.writeFile(io, .{ .sub_path = todo_path, .data = plan }) catch return error.WriteFailed;
}

/// Why `plan` does not describe `todo`, or null when it does: a plan
/// sha git did not list, or a listed commit the plan leaves out.
pub fn mismatch(arena: Allocator, plan: []const u8, todo: []const u8) Allocator.Error!?[]const u8 {
    const want = try parse.parseTodo(arena, plan);
    const have = try parse.parseTodo(arena, todo);
    for (want) |p| {
        var found = false;
        for (have) |h| if (shaEql(p.sha, h.sha)) {
            found = true;
            break;
        };
        if (!found) return try std.fmt.allocPrint(arena, "the plan names {s}, which is not in the rebase (a merge in between?)", .{p.sha[0..@min(7, p.sha.len)]});
    }
    for (have) |h| {
        var found = false;
        for (want) |p| if (shaEql(p.sha, h.sha)) {
            found = true;
            break;
        };
        if (!found) return try std.fmt.allocPrint(arena, "the rebase lists {s}, which the plan leaves out", .{h.sha[0..@min(7, h.sha.len)]});
    }
    return null;
}

/// Either sha may be abbreviated.
fn shaEql(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    return n >= 4 and std.mem.eql(u8, a[0..n], b[0..n]);
}

/// `--commit-msg`: the message git handed us at `target_path` is
/// replaced by the queue's record for its subject, when there is one.
/// A missing or empty queue leaves the message alone.
pub fn writeCommitMsg(io: Io, gpa: Allocator, queue_path: []const u8, target_path: []const u8) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    const queue = cwd.readFileAlloc(io, queue_path, arena, .limited(16 * 1024 * 1024)) catch return;
    const target = cwd.readFileAlloc(io, target_path, arena, .limited(16 * 1024 * 1024)) catch return error.ReadFailed;
    const picked = try takeRecord(arena, queue, subjectOf(target)) orelse return;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    try body.appendSlice(arena, picked.message);
    try body.append(arena, '\n');
    cwd.writeFile(io, .{ .sub_path = target_path, .data = body.items }) catch return error.WriteFailed;
    cwd.writeFile(io, .{ .sub_path = queue_path, .data = picked.rest }) catch return error.WriteFailed;
}

/// The first line of a message file that is not blank or a comment.
pub fn subjectOf(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        return line;
    }
    return "";
}

const Picked = struct { message: []const u8, rest: []const u8 };

/// The record keyed by `subject`, and the queue without it.
pub fn takeRecord(arena: Allocator, queue: []const u8, subject: []const u8) Allocator.Error!?Picked {
    if (subject.len == 0) return null;
    var rest: std.ArrayListUnmanaged(u8) = .empty;
    var picked: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, queue, 0);
    while (it.next()) |rec| {
        if (rec.len == 0) continue;
        const nl = std.mem.indexOfScalar(u8, rec, '\n') orelse rec.len;
        const key = std.mem.trim(u8, rec[0..nl], " \t\r");
        if (picked == null and std.mem.eql(u8, key, subject)) {
            picked = if (nl < rec.len) rec[nl + 1 ..] else "";
            continue;
        }
        if (rest.items.len > 0) try rest.append(arena, 0);
        try rest.appendSlice(arena, rec);
    }
    const m = picked orelse return null;
    return .{ .message = m, .rest = rest.items };
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return std.mem.trimEnd(u8, t[0..nl], " \t\r");
}

pub const Mode = enum { todo, commit_msg };

/// The child's `main`: `args` are what follows the flag. Exit 0 is the
/// only thing git reads; the reason goes to `e` (stderr in `main`).
pub fn childMain(io: Io, gpa: Allocator, mode: Mode, args: []const [:0]const u8, e: *Io.Writer) u8 {
    if (args.len < 2) {
        e.print("mnml {s}: expected <file> <target>\n", .{if (mode == .todo) "--rebase-todo" else "--commit-msg"}) catch {};
        e.flush() catch {};
        return 2;
    }
    switch (mode) {
        .todo => {
            var reason: ?[]u8 = null;
            defer if (reason) |r| gpa.free(r);
            writeTodo(io, gpa, args[0], args[1], &reason) catch |err| {
                e.print("mnml --rebase-todo: {s}\n", .{reason orelse @errorName(err)}) catch {};
                e.flush() catch {};
                return 1;
            };
        },
        .commit_msg => writeCommitMsg(io, gpa, args[0], args[1]) catch |err| {
            e.print("mnml --commit-msg: {s}\n", .{@errorName(err)}) catch {};
            e.flush() catch {};
            return 1;
        },
    }
    return 0;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn ops3(arena: Allocator) ![]Op {
    const list = try arena.alloc(Op, 3);
    list[0] = .{ .sha = try arena.dupe(u8, "1111111111111111111111111111111111111111"), .action = .pick, .subject = try arena.dupe(u8, "first") };
    list[1] = .{ .sha = try arena.dupe(u8, "2222222222222222222222222222222222222222"), .action = .reword, .subject = try arena.dupe(u8, "second one"), .new_message = try arena.dupe(u8, "second, better\n\nwith a body\n") };
    list[2] = .{ .sha = try arena.dupe(u8, "3333333333333333333333333333333333333333"), .action = .squash, .subject = try arena.dupe(u8, "third") };
    return list;
}

test "plan → todo round-trip: todoText parses back to the same actions and shas; the queue keys the reword by its old subject" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const ops = try ops3(arena);
    const text = try todoText(arena, ops);
    try testing.expectEqualStrings("pick 1111111111111111111111111111111111111111 first\nreword 2222222222222222222222222222222222222222 second one\nsquash 3333333333333333333333333333333333333333 third\n", text);
    const back = try parse.parseTodo(arena, text);
    try testing.expectEqual(@as(usize, 3), back.len);
    for (ops, back) |op, line| {
        try testing.expectEqual(op.action, line.action);
        try testing.expectEqualStrings(op.sha, line.sha);
        try testing.expectEqualStrings(op.subject, line.rest);
    }
    try testing.expectEqualStrings("second one\nsecond, better\n\nwith a body", try queueText(arena, ops));
    try testing.expectEqualStrings("'/usr/bin/mnml-zig' --rebase-todo '/tmp/it'\\''s/plan'", try editorCommand(arena, "/usr/bin/mnml-zig", "--rebase-todo", "/tmp/it's/plan"));
}

test "the sequence editor on a real todo file: git's todo is replaced by the plan; a plan naming a commit git did not list, or missing one, refuses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const plan_path = try std.fs.path.join(arena, &.{ root, "plan" });
    const todo_path = try std.fs.path.join(arena, &.{ root, "git-rebase-todo" });
    const git_todo = "pick 1111111 first\npick 2222222 second one\npick 3333333 third\n\n# Rebase 0000000..3333333 onto 0000000 (3 commands)\n#\n# Commands:\n# p, pick <commit> = use commit\n";
    const plan = try todoText(arena, try ops3(arena));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "plan", .data = plan });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "git-rebase-todo", .data = git_todo });
    try writeTodo(testing.io, testing.allocator, plan_path, todo_path, null);
    const after = try tmp.dir.readFileAlloc(testing.io, "git-rebase-todo", arena, .unlimited);
    try testing.expectEqualStrings(plan, after);
    // The child mode itself, on the same files (idempotent).
    const argv = [_][:0]const u8{ try arena.dupeZ(u8, plan_path), try arena.dupeZ(u8, todo_path) };
    var err_buf: [256]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 0), childMain(testing.io, testing.allocator, .todo, &argv, &err_w));
    try testing.expectEqualStrings("", err_w.buffered());
    // A commit the plan leaves out.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "git-rebase-todo", .data = git_todo ++ "pick 4444444 fourth\n" });
    var reason: ?[]u8 = null;
    defer if (reason) |r| testing.allocator.free(r);
    try testing.expectError(error.PlanMismatch, writeTodo(testing.io, testing.allocator, plan_path, todo_path, &reason));
    try testing.expectEqualStrings("the rebase lists 4444444, which the plan leaves out", reason.?);
    try testing.expectEqual(@as(u8, 1), childMain(testing.io, testing.allocator, .todo, &argv, &err_w));
    try testing.expectEqualStrings("mnml --rebase-todo: the rebase lists 4444444, which the plan leaves out\n", err_w.buffered());
    err_w = .fixed(&err_buf);
    const untouched = try tmp.dir.readFileAlloc(testing.io, "git-rebase-todo", arena, .unlimited);
    try testing.expect(std.mem.endsWith(u8, untouched, "pick 4444444 fourth\n"));
    // A commit git did not list.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "git-rebase-todo", .data = "pick 1111111 first\npick 2222222 second one\n" });
    try testing.expect((try mismatch(arena, plan, "pick 1111111 first\npick 2222222 second one\n")) != null);
    try testing.expectEqual(@as(u8, 2), childMain(testing.io, testing.allocator, .todo, argv[0..1], &err_w));
    try testing.expectEqualStrings("mnml --rebase-todo: expected <file> <target>\n", err_w.buffered());
}

test "the message editor: the record for the file's subject replaces it and leaves the queue; a squash's combined message and an unknown subject pass through" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    const queue_path = try std.fs.path.join(arena, &.{ root, "msgs" });
    const target_path = try std.fs.path.join(arena, &.{ root, "COMMIT_EDITMSG" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "msgs", .data = "second one\nsecond, better\n\nwith a body\x00third\nthird, renamed" });
    // A squash's file: the pick's subject leads; no record → untouched.
    const squash = "# This is a combination of 2 commits.\n# This is the 1st commit message:\n\nfirst\n\n# This is the commit message #2:\n\nsecond one\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "COMMIT_EDITMSG", .data = squash });
    try writeCommitMsg(testing.io, testing.allocator, queue_path, target_path);
    try testing.expectEqualStrings(squash, try tmp.dir.readFileAlloc(testing.io, "COMMIT_EDITMSG", arena, .unlimited));
    // The reword: the old message with git's comment block.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "COMMIT_EDITMSG", .data = "second one\n\n# Please enter the commit message for your changes.\n" });
    const argv = [_][:0]const u8{ try arena.dupeZ(u8, queue_path), try arena.dupeZ(u8, target_path) };
    var err_buf: [256]u8 = undefined;
    var err_w: Io.Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 0), childMain(testing.io, testing.allocator, .commit_msg, &argv, &err_w));
    try testing.expectEqualStrings("second, better\n\nwith a body\n", try tmp.dir.readFileAlloc(testing.io, "COMMIT_EDITMSG", arena, .unlimited));
    try testing.expectEqualStrings("third\nthird, renamed", try tmp.dir.readFileAlloc(testing.io, "msgs", arena, .unlimited));
    // The second reword drains the queue; a third invocation finds nothing.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "COMMIT_EDITMSG", .data = "third\n" });
    try writeCommitMsg(testing.io, testing.allocator, queue_path, target_path);
    try testing.expectEqualStrings("third, renamed\n", try tmp.dir.readFileAlloc(testing.io, "COMMIT_EDITMSG", arena, .unlimited));
    try testing.expectEqualStrings("", try tmp.dir.readFileAlloc(testing.io, "msgs", arena, .unlimited));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "COMMIT_EDITMSG", .data = "third\n" });
    try writeCommitMsg(testing.io, testing.allocator, queue_path, target_path);
    try testing.expectEqualStrings("third\n", try tmp.dir.readFileAlloc(testing.io, "COMMIT_EDITMSG", arena, .unlimited));
    // No queue file at all: a plain `commit` through this editor keeps its message.
    try tmp.dir.deleteFile(testing.io, "msgs");
    try writeCommitMsg(testing.io, testing.allocator, queue_path, target_path);
    try testing.expectEqualStrings("third\n", try tmp.dir.readFileAlloc(testing.io, "COMMIT_EDITMSG", arena, .unlimited));
    try testing.expectEqualStrings("second one", subjectOf("\n# a comment\n  second one  \nbody"));
}
