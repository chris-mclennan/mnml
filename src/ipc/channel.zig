//! The file-IPC channel at `<workspace>/.mnml/<subdir>/`:
//!
//!   command       host → mnml, JSONL, one command per line (see command.zig)
//!   screen.txt    the last rendered screen (see screen.zig)
//!   status.json   focus / panes / cursor / mode snapshot
//!   rects.json    every registered click rect, each frame
//!   events.jsonl  append-only: lifecycle lines and one ack per command
//!
//! Init is destructive on purpose: the four files are truncated (created
//! owner-only — `screen.txt` is a verbatim dump of whatever is on screen),
//! a symlink in their place is unlinked rather than written through, and
//! anything a host pre-queued in `command` is counted into an
//! `ipc_init_truncated` event so it is not silently lost.
//!
//! The reader tails `command` by byte offset and only consumes complete
//! lines; a truncated file restarts at zero.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const log = std.log.scoped(.ipc);

pub const Command = command.Command;

/// Where the channel lives relative to the workspace when `MNML_IPC_DIR`
/// is not set. Rust mnml uses `ipc`; the Zig host defaults to `ipc-zig`
/// (`-Dipc-subdir`) so both can run on one workspace until cutover.
pub const default_subdir = "ipc";

pub const InitOptions = struct {
    /// `MNML_IPC_DIR`: an absolute directory that replaces `<ws>/.mnml/<subdir>`.
    dir_override: ?[]const u8 = null,
    subdir: []const u8 = default_subdir,
};

pub const Channel = struct {
    gpa: Allocator,
    io: Io,
    workspace: []u8,
    dir: []u8,
    cmd_path: []u8,
    screen_path: []u8,
    status_path: []u8,
    events_path: []u8,
    rects_path: []u8,
    /// Bytes of `command` already consumed.
    cmd_offset: u64 = 0,
    /// Set once an `"event":"exit"` line is written; `deinit` writes a
    /// death certificate otherwise.
    exit_event_written: bool = false,
    /// events.jsonl is appended from two tasks under the terminal loop —
    /// the command tail's acks and the loop's own `plugin-command`
    /// lines — and an append is "read the length, write there": one
    /// line at a time, or two land on the same offset.
    append_lock: Io.Mutex = .init,

    pub const InitError = Allocator.Error || Io.Dir.CreateDirPathError || Io.File.OpenError || Io.File.Writer.Error;

    pub fn init(gpa: Allocator, io: Io, workspace: []const u8, opts: InitOptions) InitError!Channel {
        const ws = try gpa.dupe(u8, workspace);
        errdefer gpa.free(ws);
        const dir = if (opts.dir_override) |d|
            try gpa.dupe(u8, d)
        else
            try std.fs.path.join(gpa, &.{ workspace, ".mnml", opts.subdir });
        errdefer gpa.free(dir);
        try Io.Dir.cwd().createDirPath(io, dir);
        ensureWorkspaceExcluded(gpa, io, workspace) catch {};

        var self: Channel = .{
            .gpa = gpa,
            .io = io,
            .workspace = ws,
            .dir = dir,
            .cmd_path = try std.fs.path.join(gpa, &.{ dir, "command" }),
            .screen_path = undefined,
            .status_path = undefined,
            .events_path = undefined,
            .rects_path = undefined,
        };
        errdefer gpa.free(self.cmd_path);
        self.screen_path = try std.fs.path.join(gpa, &.{ dir, "screen.txt" });
        errdefer gpa.free(self.screen_path);
        self.status_path = try std.fs.path.join(gpa, &.{ dir, "status.json" });
        errdefer gpa.free(self.status_path);
        self.events_path = try std.fs.path.join(gpa, &.{ dir, "events.jsonl" });
        errdefer gpa.free(self.events_path);
        self.rects_path = try std.fs.path.join(gpa, &.{ dir, "rects.json" });
        errdefer gpa.free(self.rects_path);

        // A cloned repo can ship `.mnml/ipc/screen.txt -> ~/.zshrc`; refuse
        // to write through it. Unlink rather than bail: these are mnml's own
        // scratch files, and a dead channel would cost the whole session.
        for ([_][]const u8{ self.cmd_path, self.screen_path, self.status_path, self.events_path }) |p| {
            if (isSymlink(io, p)) {
                log.warn("{s} was a symlink — replacing it with a regular file", .{p});
                Io.Dir.cwd().deleteFile(io, p) catch {};
            }
        }

        // Anything queued before launch is reported, then dropped: the live
        // loop starts clean.
        const pre_queued = readFile(gpa, io, self.cmd_path) catch "";
        defer gpa.free(pre_queued);

        try writeSecret(io, self.cmd_path, "");
        try writeSecret(io, self.events_path, "");
        try writeSecret(io, self.screen_path, "");
        try writeSecret(io, self.status_path, "{}");

        if (pre_queued.len > 0) {
            var buf: [96]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{{\"event\":\"ipc_init_truncated\",\"bytes\":{d},\"lines\":{d}}}", .{ pre_queued.len, countLines(pre_queued) }) catch unreachable;
            self.appendEvent(line);
        }
        return self;
    }

    pub fn deinit(self: *Channel) void {
        if (!self.exit_event_written) {
            // Best-effort death certificate so the host has something to
            // grep for after a crash-shaped exit.
            self.appendEvent("{\"event\":\"shutdown\",\"reason\":\"unexpected\",\"note\":\"ipc drop without happy-path exit\"}");
        }
        self.gpa.free(self.rects_path);
        self.gpa.free(self.events_path);
        self.gpa.free(self.status_path);
        self.gpa.free(self.screen_path);
        self.gpa.free(self.cmd_path);
        self.gpa.free(self.dir);
        self.gpa.free(self.workspace);
        self.* = undefined;
    }

    pub fn dirPath(self: *const Channel) []const u8 {
        return self.dir;
    }

    /// Every complete line appended to `command` since the last poll,
    /// parsed. Results live in `arena`.
    pub fn poll(self: *Channel, arena: Allocator) Allocator.Error![]Command {
        const io = self.io;
        const file = Io.Dir.cwd().openFile(io, self.cmd_path, .{}) catch return &.{};
        defer file.close(io);
        const len = file.length(io) catch return &.{};
        if (len < self.cmd_offset) self.cmd_offset = 0; // truncated or rotated — start over
        if (len == self.cmd_offset) return &.{};
        const buf = try arena.alloc(u8, @intCast(len - self.cmd_offset));
        const n = file.readPositionalAll(io, buf, self.cmd_offset) catch return &.{};
        const text = buf[0..n];

        var out: std.ArrayList(Command) = .empty;
        for (try splitLines(arena, text, &self.cmd_offset)) |line| try out.append(arena, try command.parse(arena, line));
        return out.toOwnedSlice(arena);
    }

    /// The same tail, unparsed. The terminal loop wants the raw line so
    /// each command can be parsed onto an arena that outlives the poll
    /// — a posted event owns its own strings.
    pub fn pollLines(self: *Channel, arena: Allocator) Allocator.Error![]const []const u8 {
        const io = self.io;
        const file = Io.Dir.cwd().openFile(io, self.cmd_path, .{}) catch return &.{};
        defer file.close(io);
        const len = file.length(io) catch return &.{};
        if (len < self.cmd_offset) self.cmd_offset = 0;
        if (len == self.cmd_offset) return &.{};
        const buf = try arena.alloc(u8, @intCast(len - self.cmd_offset));
        const n = file.readPositionalAll(io, buf, self.cmd_offset) catch return &.{};
        return splitLines(arena, buf[0..n], &self.cmd_offset);
    }

    /// The complete lines in `text`, advancing `offset` past them. A
    /// partial last line waits for its newline.
    fn splitLines(arena: Allocator, text: []const u8, offset: *u64) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var consumed: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
            const line = text[start .. nl + 1];
            start = nl + 1;
            consumed += line.len;
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) continue;
            try out.append(arena, trimmed);
        }
        offset.* += consumed;
        return out.toOwnedSlice(arena);
    }

    pub fn writeScreen(self: *const Channel, text: []const u8) void {
        writeSecret(self.io, self.screen_path, text) catch {};
    }

    pub fn writeStatus(self: *const Channel, json: []const u8) void {
        writeSecret(self.io, self.status_path, json) catch {};
    }

    pub fn writeRects(self: *const Channel, json: []const u8) void {
        writeSecret(self.io, self.rects_path, json) catch {};
    }

    /// Append one JSON line to events.jsonl.
    pub fn appendEvent(self: *Channel, json_line: []const u8) void {
        self.append_lock.lockUncancelable(self.io);
        defer self.append_lock.unlock(self.io);
        if (std.mem.indexOf(u8, json_line, "\"event\":\"exit\"") != null) self.exit_event_written = true;
        appendSecret(self.io, self.events_path, json_line) catch {};
    }
};

// ─── owner-only files ───────────────────────────────────────────────────

fn secretPermissions() Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

/// Create-or-truncate `path` with `bytes`, owner-only. A pre-existing file
/// keeps its inode but is tightened to 0600 as well.
pub fn writeSecret(io: Io, path: []const u8, bytes: []const u8) (Io.File.OpenError || Io.File.Writer.Error)!void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .permissions = secretPermissions() });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    file.setPermissions(io, secretPermissions()) catch {};
}

/// Append `line` + `\n` to `path`, creating it owner-only.
pub fn appendSecret(io: Io, path: []const u8, line: []const u8) (Io.File.OpenError || Io.File.WritePositionalError || Io.File.LengthError)!void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false, .permissions = secretPermissions() });
    defer file.close(io);
    const end = try file.length(io);
    try file.writePositionalAll(io, line, end);
    try file.writePositionalAll(io, "\n", end + line.len);
    file.setPermissions(io, secretPermissions()) catch {};
}

fn isSymlink(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return st.kind == .sym_link;
}

fn readFile(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

/// Line count the way `str::lines` counts: a trailing newline adds nothing.
fn countLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    var n = std.mem.count(u8, s, "\n");
    if (s[s.len - 1] != '\n') n += 1;
    return n;
}

// ─── .gitignore ─────────────────────────────────────────────────────────

/// Workspace-local state directories mnml writes into a repo. Both hold
/// credential-bearing files (screen dumps; HTTP history with expanded
/// `Authorization` headers), so both belong in `.gitignore`.
const workspace_state_dirs = [_][]const u8{ ".mnml", ".rqst" };

/// True when `existing` already has a rule about `dir`: `x`, `x/`, `/x`,
/// `/x/`, `x/**`, `x/*`, a rule on something inside it (`x/ipc/`) and a
/// carve-out under it (`!x/findings/`) all count, as do comments and
/// indentation around them. A rule inside the directory is the user's
/// decision about it — appending `x/` after `x/*` + `!x/findings/`
/// would defeat the carve-out, since a trailing directory rule stops
/// git from re-including anything below it.
fn gitignoreCovers(existing: []const u8, dir: []const u8) bool {
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const before_comment = if (std.mem.indexOfScalar(u8, line, '#')) |i| line[0..i] else line;
        var s = std.mem.trim(u8, before_comment, " \t\r");
        if (s.len > 0 and s[0] == '!') s = s[1..];
        while (s.len > 0 and s[0] == '/') s = s[1..];
        if (std.mem.startsWith(u8, s, "**/")) s = s[3..];
        const seg = if (std.mem.indexOfScalar(u8, s, '/')) |i| s[0..i] else s;
        if (std.mem.eql(u8, seg, dir)) return true;
    }
    return false;
}

/// On a git workspace, make sure `.mnml/` (and `.rqst/` once it exists)
/// are ignored — in the clone's own `info/exclude`, never in
/// `.gitignore`. A `.gitignore` is the project's file: editing it made
/// every repo mnml opened show a change the user never made, which then
/// rode along in their next `commit -a` or stash, and a stash that took
/// the edit away left `.mnml/` for the next `add -A` to commit. The
/// exclude file is per clone, invisible to `status`, and never
/// committed or stashed. Idempotent; nothing is written when either
/// file already has a rule about the directory.
pub fn ensureWorkspaceExcluded(gpa: Allocator, io: Io, workspace: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const common = (try gitCommonDir(gpa, io, workspace)) orelse return;
    defer gpa.free(common);

    const gi = try std.fs.path.join(gpa, &.{ workspace, ".gitignore" });
    defer gpa.free(gi);
    const ignore = readFile(gpa, io, gi) catch try gpa.dupe(u8, "");
    defer gpa.free(ignore);
    const info = try std.fs.path.join(gpa, &.{ common, "info" });
    defer gpa.free(info);
    const ex = try std.fs.path.join(gpa, &.{ info, "exclude" });
    defer gpa.free(ex);
    const existing = readFile(gpa, io, ex) catch try gpa.dupe(u8, "");
    defer gpa.free(existing);

    var missing: std.ArrayList([]const u8) = .empty;
    defer missing.deinit(gpa);
    for (workspace_state_dirs) |d| {
        if (!std.mem.eql(u8, d, ".mnml")) {
            const p = try std.fs.path.join(gpa, &.{ workspace, d });
            defer gpa.free(p);
            cwd.access(io, p, .{}) catch continue;
        }
        if (!gitignoreCovers(ignore, d) and !gitignoreCovers(existing, d)) try missing.append(gpa, d);
    }
    if (missing.items.len == 0) return;

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try w.writeByte('\n');
    try w.writeAll("# Added by mnml — workspace state: IPC, session, and HTTP\n");
    try w.writeAll("# history / captured traffic / env values (these carry secrets)\n");
    for (missing.items) |d| try w.print("{s}/\n", .{d});
    try cwd.createDirPath(io, info);
    try cwd.writeFile(io, .{ .sub_path = ex, .data = out.written() });
}

/// The workspace's git common dir — where `info/exclude` is read — or
/// null when the workspace is not a repo root. `.git` is that directory
/// in a plain clone; in a linked worktree it is a file naming the
/// worktree's git dir (`gitdir: …`), whose `commondir` names the shared
/// one. Owned.
fn gitCommonDir(gpa: Allocator, io: Io, workspace: []const u8) !?[]u8 {
    const dot_git = try std.fs.path.join(gpa, &.{ workspace, ".git" });
    defer gpa.free(dot_git);
    const st = Io.Dir.cwd().statFile(io, dot_git, .{}) catch return null;
    if (st.kind == .directory) return try gpa.dupe(u8, dot_git);
    const text = readFile(gpa, io, dot_git) catch return null;
    defer gpa.free(text);
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return null;
    const gd_rel = std.mem.trim(u8, line["gitdir:".len..], " \t");
    const gd = try std.fs.path.resolve(gpa, &.{ workspace, gd_rel });
    defer gpa.free(gd);
    const cd_path = try std.fs.path.join(gpa, &.{ gd, "commondir" });
    defer gpa.free(cd_path);
    const cd = readFile(gpa, io, cd_path) catch return try gpa.dupe(u8, gd);
    defer gpa.free(cd);
    return try std.fs.path.resolve(gpa, &.{ gd, std.mem.trim(u8, cd, " \t\r\n") });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

const TestWs = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init() !TestWs {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        return .{ .tmp = tmp, .path = try t.allocator.dupe(u8, buf[0..n]) };
    }

    fn deinit(self: *TestWs) void {
        t.allocator.free(self.path);
        self.tmp.cleanup();
    }

    fn read(self: *TestWs, rel: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(t.io, rel, t.allocator, .unlimited);
    }

    fn write(self: *TestWs, rel: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(t.io, .{ .sub_path = rel, .data = data });
    }

    fn append(self: *TestWs, rel: []const u8, data: []const u8) !void {
        const p = try std.fs.path.join(t.allocator, &.{ self.path, rel });
        defer t.allocator.free(p);
        const f = try Io.Dir.cwd().createFile(t.io, p, .{ .read = true, .truncate = false });
        defer f.close(t.io);
        try f.writePositionalAll(t.io, data, try f.length(t.io));
    }
};

fn modeOf(ws: *TestWs, rel: []const u8) !u32 {
    const st = try ws.tmp.dir.statFile(t.io, rel, .{});
    return if (builtin.os.tag == .windows) 0o600 else @as(u32, @intCast(st.permissions.toMode())) & 0o777;
}

test "init creates the channel, truncates a pre-queued command file, and reports it" {
    var ws = try TestWs.init();
    defer ws.deinit();
    try ws.tmp.dir.createDirPath(t.io, ".mnml/ipc");
    try ws.write(".mnml/ipc/command", "{\"cmd\":\"quit\"}\n{\"cmd\":\"x\"}");

    var ch = try Channel.init(t.allocator, t.io, ws.path, .{});
    defer ch.deinit();
    try t.expect(sdk_testing.pathEndsWith(ch.dirPath(), "/.mnml/ipc"));

    const cmd = try ws.read(".mnml/ipc/command");
    defer t.allocator.free(cmd);
    try t.expectEqualStrings("", cmd);
    const status = try ws.read(".mnml/ipc/status.json");
    defer t.allocator.free(status);
    try t.expectEqualStrings("{}", status);
    const events = try ws.read(".mnml/ipc/events.jsonl");
    defer t.allocator.free(events);
    try t.expectEqualStrings("{\"event\":\"ipc_init_truncated\",\"bytes\":26,\"lines\":2}\n", events);

    for ([_][]const u8{ "command", "screen.txt", "status.json", "events.jsonl" }) |f| {
        var buf: [64]u8 = undefined;
        const rel = try std.fmt.bufPrint(&buf, ".mnml/ipc/{s}", .{f});
        try t.expectEqual(@as(u32, 0o600), try modeOf(&ws, rel));
    }
    ch.appendEvent("{\"event\":\"exit\"}");
}

test "a subdir override and MNML_IPC_DIR both relocate the channel" {
    var ws = try TestWs.init();
    defer ws.deinit();
    var a = try Channel.init(t.allocator, t.io, ws.path, .{ .subdir = "ipc-zig" });
    defer a.deinit();
    try t.expect(sdk_testing.pathEndsWith(a.dirPath(), "/.mnml/ipc-zig"));
    a.appendEvent("{\"event\":\"exit\"}");

    const elsewhere = try std.fs.path.join(t.allocator, &.{ ws.path, "elsewhere" });
    defer t.allocator.free(elsewhere);
    var b = try Channel.init(t.allocator, t.io, ws.path, .{ .dir_override = elsewhere });
    defer b.deinit();
    try t.expectEqualStrings(elsewhere, b.dirPath());
    b.appendEvent("{\"event\":\"exit\"}");
    _ = try ws.tmp.dir.statFile(t.io, "elsewhere/status.json", .{});
}

test "a symlinked channel file is replaced by a regular file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    var ws = try TestWs.init();
    defer ws.deinit();
    try ws.tmp.dir.createDirPath(t.io, ".mnml/ipc");
    try ws.tmp.dir.symLink(t.io, "/dev/null", ".mnml/ipc/screen.txt", .{});
    var ch = try Channel.init(t.allocator, t.io, ws.path, .{});
    defer ch.deinit();
    const st = try ws.tmp.dir.statFile(t.io, ".mnml/ipc/screen.txt", .{ .follow_symlinks = false });
    try t.expectEqual(Io.File.Kind.file, st.kind);
    ch.writeScreen("row\n");
    const got = try ws.read(".mnml/ipc/screen.txt");
    defer t.allocator.free(got);
    try t.expectEqualStrings("row\n", got);
    ch.appendEvent("{\"event\":\"exit\"}");
}

test "poll tails complete lines by byte offset and restarts after truncation" {
    var ws = try TestWs.init();
    defer ws.deinit();
    var ch = try Channel.init(t.allocator, t.io, ws.path, .{});
    defer ch.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try t.expectEqual(@as(usize, 0), (try ch.poll(arena)).len);
    try ws.append(".mnml/ipc/command", "{\"cmd\":\"quit\"}\n\n  \n{\"cmd\":\"snapshot\"}\n{\"cmd\":\"part");
    const first = try ch.poll(arena);
    try t.expectEqual(@as(usize, 2), first.len);
    try t.expectEqual(Command.quit, first[0]);
    try t.expectEqual(Command.snapshot, first[1]);
    // The partial line is not consumed until its newline arrives.
    try t.expectEqual(@as(usize, 0), (try ch.poll(arena)).len);
    try ws.append(".mnml/ipc/command", "ial\"}\n");
    const second = try ch.poll(arena);
    try t.expectEqual(@as(usize, 1), second.len);
    try t.expectEqualStrings("{\"cmd\":\"partial\"}", second[0].unknown);
    // Truncation (a host that rewrites the file) resets the offset.
    try ws.write(".mnml/ipc/command", "{\"cmd\":\"restart\"}\n");
    const third = try ch.poll(arena);
    try t.expectEqual(@as(usize, 1), third.len);
    try t.expectEqual(Command.restart, third[0]);
    ch.appendEvent("{\"event\":\"exit\"}");
}

test "events append one line each; deinit without an exit line writes a death certificate" {
    var ws = try TestWs.init();
    defer ws.deinit();
    {
        var ch = try Channel.init(t.allocator, t.io, ws.path, .{});
        defer ch.deinit();
        ch.appendEvent("{\"event\":\"start\"}");
        ch.appendEvent("{\"event\":\"open\",\"path\":\"a\"}");
    }
    const got = try ws.read(".mnml/ipc/events.jsonl");
    defer t.allocator.free(got);
    try t.expectEqualStrings(
        "{\"event\":\"start\"}\n{\"event\":\"open\",\"path\":\"a\"}\n{\"event\":\"shutdown\",\"reason\":\"unexpected\",\"note\":\"ipc drop without happy-path exit\"}\n",
        got,
    );
    {
        var ch = try Channel.init(t.allocator, t.io, ws.path, .{});
        defer ch.deinit();
        ch.appendEvent("{\"event\":\"exit\",\"restart\":true}");
    }
    const clean = try ws.read(".mnml/ipc/events.jsonl");
    defer t.allocator.free(clean);
    try t.expectEqualStrings("{\"event\":\"exit\",\"restart\":true}\n", clean);
}

test "the state dirs go into the clone's info/exclude once, only in a git workspace; .gitignore is never written" {
    var ws = try TestWs.init();
    defer ws.deinit();
    // Not a git repo: nothing is written.
    try ensureWorkspaceExcluded(t.allocator, t.io, ws.path);
    try t.expectError(error.FileNotFound, ws.tmp.dir.statFile(t.io, ".gitignore", .{}));

    const header = "# Added by mnml — workspace state: IPC, session, and HTTP\n# history / captured traffic / env values (these carry secrets)\n";
    try ws.tmp.dir.createDirPath(t.io, ".git");
    // No .gitignore: none is made; the exclude file (and `info/`) is.
    try ensureWorkspaceExcluded(t.allocator, t.io, ws.path);
    try t.expectError(error.FileNotFound, ws.tmp.dir.statFile(t.io, ".gitignore", .{}));
    const made = try ws.read(".git/info/exclude");
    defer t.allocator.free(made);
    try t.expectEqualStrings(header ++ ".mnml/\n", made);

    // A tracked-looking .gitignore stays byte for byte; git's own
    // exclude lines are kept above ours.
    try ws.write(".gitignore", "*.log");
    try ws.write(".git/info/exclude", "# git ls-files --others --exclude-from=.git/info/exclude\n*.swp");
    try ensureWorkspaceExcluded(t.allocator, t.io, ws.path);
    const ignore = try ws.read(".gitignore");
    defer t.allocator.free(ignore);
    try t.expectEqualStrings("*.log", ignore);
    const once = try ws.read(".git/info/exclude");
    defer t.allocator.free(once);
    try t.expectEqualStrings("# git ls-files --others --exclude-from=.git/info/exclude\n*.swp\n" ++ header ++ ".mnml/\n", once);
    // Idempotent.
    try ensureWorkspaceExcluded(t.allocator, t.io, ws.path);
    const twice = try ws.read(".git/info/exclude");
    defer t.allocator.free(twice);
    try t.expectEqualStrings(once, twice);
    // `.rqst/` joins only once the directory exists.
    try ws.tmp.dir.createDirPath(t.io, ".rqst");
    try ensureWorkspaceExcluded(t.allocator, t.io, ws.path);
    const with_rqst = try ws.read(".git/info/exclude");
    defer t.allocator.free(with_rqst);
    try t.expect(std.mem.endsWith(u8, with_rqst, ".mnml/\n" ++ header ++ ".rqst/\n"));
    try ws.tmp.dir.deleteDir(t.io, ".rqst");

    // A .gitignore that already has a rule about `.mnml` (the user's
    // decision, carve-outs included) means no exclude line either.
    try ws.write(".git/info/exclude", "");
    for ([_][]const u8{
        ".mnml/*\n!.mnml/findings/\n",
        "/.mnml/\n",
        "  .mnml  # state\n",
        ".mnml/**\n",
        "**/.mnml/\n",
        ".mnml/ipc/\n",
        "!.mnml/findings/\n",
    }) |body| {
        try ws.write(".gitignore", body);
        try ensureWorkspaceExcluded(t.allocator, t.io, ws.path);
        const kept = try ws.read(".gitignore");
        defer t.allocator.free(kept);
        try t.expectEqualStrings(body, kept);
        const ex = try ws.read(".git/info/exclude");
        defer t.allocator.free(ex);
        try t.expectEqualStrings("", ex);
    }
    // A rule that only resembles the name is not a decision about it.
    try ws.write(".gitignore", "*.mnml\n.mnml-backup/\n");
    try ensureWorkspaceExcluded(t.allocator, t.io, ws.path);
    const grown = try ws.read(".git/info/exclude");
    defer t.allocator.free(grown);
    try t.expect(std.mem.endsWith(u8, grown, ".mnml/\n"));
    const same = try ws.read(".gitignore");
    defer t.allocator.free(same);
    try t.expectEqualStrings("*.mnml\n.mnml-backup/\n", same);
}

test "a linked worktree's state dirs go into the shared git dir's info/exclude" {
    var ws = try TestWs.init();
    defer ws.deinit();
    // main/.git/worktrees/wt is the worktree's git dir; its commondir
    // points two levels up, at main/.git.
    try ws.tmp.dir.createDirPath(t.io, "main/.git/worktrees/wt");
    try ws.tmp.dir.createDirPath(t.io, "wt");
    try ws.write("main/.git/worktrees/wt/commondir", "../..\n");
    try ws.write("wt/.git", "gitdir: ../main/.git/worktrees/wt\n");
    const wt = try std.fs.path.join(t.allocator, &.{ ws.path, "wt" });
    defer t.allocator.free(wt);
    try ensureWorkspaceExcluded(t.allocator, t.io, wt);
    const ex = try ws.read("main/.git/info/exclude");
    defer t.allocator.free(ex);
    try t.expect(std.mem.endsWith(u8, ex, ".mnml/\n"));
    try t.expectError(error.FileNotFound, ws.tmp.dir.statFile(t.io, "wt/.gitignore", .{}));
}

test "gitignoreCovers tolerates the usual spellings" {
    try t.expect(gitignoreCovers(".mnml", ".mnml"));
    try t.expect(gitignoreCovers("  /.mnml/ # ipc", ".mnml"));
    try t.expect(gitignoreCovers(".mnml/**", ".mnml"));
    try t.expect(gitignoreCovers("node_modules\n.mnml/", ".mnml"));
    try t.expect(!gitignoreCovers(".mnml2", ".mnml"));
    try t.expect(!gitignoreCovers("# .mnml", ".mnml"));
    try t.expect(!gitignoreCovers("", ".rqst"));
}

test "countLines counts like str::lines" {
    try t.expectEqual(@as(usize, 0), countLines(""));
    try t.expectEqual(@as(usize, 1), countLines("a"));
    try t.expectEqual(@as(usize, 1), countLines("a\n"));
    try t.expectEqual(@as(usize, 2), countLines("a\nb"));
    try t.expectEqual(@as(usize, 2), countLines("a\r\nb\n"));
}
