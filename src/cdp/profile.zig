//! Who holds a Chrome profile directory. Chrome marks a profile in use
//! with `SingletonLock`, a symlink to `<host>-<pid>`; a second Chrome on
//! the same directory finds it, hands its URL to the first and exits —
//! without a DevTools line, which the browser pane used to report as
//! "did it start?".
//!
//! `probe` reads the lock and says what it found:
//!
//! - `free` — no lock.
//! - `stale` — a lock whose pid is gone. Chrome clears these itself.
//! - `orphan` — a live Chrome that mnml started on this directory and
//!   whose mnml is gone: its argv carries `--user-data-dir=<dir>` and
//!   `--remote-debugging-port=0` (the launch's signature, kept by the
//!   test wrapper too), and it was reparented to pid 1. That is what a
//!   `kill -9` or a panic of mnml leaves behind: a headless Chrome with
//!   no window to close, holding the profile and a debugging port
//!   forever.
//! - `held` — anything else alive: another mnml's live pane, the user's
//!   own Chrome. Never touched; the pane picks another directory.
//!
//! Windows has no `SingletonLock`; `probe` says `free` there.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Pid = std.posix.pid_t;

pub const State = union(enum) {
    free,
    stale: Pid,
    orphan: Pid,
    held: Pid,
};

/// The pid a `SingletonLock` target names (`<host>-<pid>`).
pub fn lockPid(target: []const u8) ?Pid {
    const dash = std.mem.lastIndexOfScalar(u8, target, '-') orelse return null;
    return std.fmt.parseInt(Pid, target[dash + 1 ..], 10) catch null;
}

/// True when `argv` (one `ps` command line) is a Chrome launched on
/// `dir` the way `cdp.spawn` launches one.
pub fn isOurLaunch(command: []const u8, dir: []const u8) bool {
    if (std.mem.indexOf(u8, command, "--remote-debugging-port=0") == null) return false;
    var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const flag = std.fmt.bufPrint(&buf, "--user-data-dir={s}", .{dir}) catch return false;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, command, at, flag)) |i| {
        const end = i + flag.len;
        // Whole argument only: `…/chrome-profile` is not `…/chrome-profile-1`.
        if (end == command.len or command[end] == ' ') return true;
        at = end;
    }
    return false;
}

fn alive(pid: Pid) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| return err != error.ProcessNotFound;
    return true;
}

/// `ps` for one pid: its parent and its command line.
const PsLine = struct { ppid: Pid, command: []const u8 };

fn ps(arena: Allocator, io: Io, pid: Pid) ?PsLine {
    var pbuf: [16]u8 = undefined;
    const pid_s = std.fmt.bufPrint(&pbuf, "{d}", .{pid}) catch return null;
    const r = std.process.run(arena, io, .{ .argv = &.{ "ps", "-ww", "-o", "ppid=", "-o", "command=", "-p", pid_s } }) catch return null;
    if (r.term != .exited or r.term.exited != 0) return null;
    const line = std.mem.trim(u8, r.stdout, " \t\r\n");
    const sp = std.mem.indexOfAny(u8, line, " \t") orelse return null;
    const ppid = std.fmt.parseInt(Pid, line[0..sp], 10) catch return null;
    return .{ .ppid = ppid, .command = std.mem.trim(u8, line[sp..], " \t") };
}

/// What holds `dir` (absolute).
pub fn probe(gpa: Allocator, io: Io, dir: []const u8) State {
    if (builtin.os.tag == .windows) return .free;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const lock = std.fs.path.join(a, &.{ dir, "SingletonLock" }) catch return .free;
    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().readLink(io, lock, &tbuf) catch return .free;
    const pid = lockPid(tbuf[0..n]) orelse return .free;
    if (!alive(pid)) return .{ .stale = pid };
    const line = ps(a, io, pid) orelse return .{ .held = pid };
    if (line.ppid == 1 and isOurLaunch(line.command, dir)) return .{ .orphan = pid };
    return .{ .held = pid };
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "lockPid and isOurLaunch read Chrome's lock and mnml's launch line" {
    try testing.expectEqual(@as(?Pid, 83520), lockPid("my-host.local-83520"));
    try testing.expectEqual(@as(?Pid, null), lockPid("nohyphen"));
    const cmd = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --remote-debugging-port=0 --user-data-dir=/w/.mnml/chrome-profile --no-first-run about:blank";
    try testing.expect(isOurLaunch(cmd, "/w/.mnml/chrome-profile"));
    try testing.expect(!isOurLaunch(cmd, "/w/.mnml/chrome-profile-1"));
    try testing.expect(!isOurLaunch("chrome --remote-debugging-port=0 --user-data-dir=/w/.mnml/chrome-profile-1 x", "/w/.mnml/chrome-profile"));
    try testing.expect(!isOurLaunch("chrome --user-data-dir=/w/.mnml/chrome-profile", "/w/.mnml/chrome-profile"));
}

fn lockTo(io: Io, dir: []const u8, pid: Pid) !void {
    var buf: [64]u8 = undefined;
    const target = try std.fmt.bufPrint(&buf, "test-host-{d}", .{pid});
    var d = try Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    d.deleteFile(io, "SingletonLock") catch {};
    try d.symLink(io, target, "SingletonLock", .{});
}

test "probe: no lock is free, a dead pid is stale, our own live child is held, an orphaned launch on the dir is an orphan" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &pbuf);
    const root = pbuf[0..n];
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try std.fs.path.join(a, &.{ root, "chrome-profile" });
    try Io.Dir.cwd().createDirPath(io, dir);
    try testing.expect(probe(gpa, io, dir) == .free);

    // A pid that is gone.
    var done = try std.process.spawn(io, .{ .argv = &.{"/usr/bin/true"}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const dead = done.id.?;
    _ = try done.wait(io);
    try lockTo(io, dir, dead);
    try testing.expect(probe(gpa, io, dir) == .stale);

    // A stand-in carrying the launch's signature. As our child it is
    // someone's live pane: held, never touched.
    const script = try std.fs.path.join(a, &.{ root, "fake-chrome" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = "#!/bin/sh\nexec /bin/sleep 30\n" });
    const udd = try std.fmt.allocPrint(a, "--user-data-dir={s}", .{dir});
    var mine = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", script, "--remote-debugging-port=0", udd }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    defer mine.kill(io);
    // Our child, alive: whatever its argv reads by now, it is held.
    try lockTo(io, dir, mine.id.?);
    const held = probe(gpa, io, dir);
    try testing.expect(held == .held);

    // The same stand-in, orphaned: started from a shell that exits, so
    // launchd adopts it — the shape `kill -9` of mnml leaves.
    const pidfile = try std.fs.path.join(a, &.{ root, "orphan.pid" });
    const orphan_script = try std.fs.path.join(a, &.{ root, "orphan-chrome" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = orphan_script, .data = "#!/bin/sh\nwhile :; do /bin/sleep 1; done\n" });
    const line = try std.fmt.allocPrint(a, "/bin/sh '{s}' --remote-debugging-port=0 '{s}' </dev/null >/dev/null 2>&1 & echo $! > '{s}'", .{ orphan_script, udd, pidfile });
    var launcher = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", line }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    _ = try launcher.wait(io);
    var nbuf: [32]u8 = undefined;
    const orphan_pid = try std.fmt.parseInt(Pid, std.mem.trim(u8, try Io.Dir.cwd().readFile(io, pidfile, &nbuf), " \n"), 10);
    defer std.posix.kill(orphan_pid, .KILL) catch {};
    try lockTo(io, dir, orphan_pid);
    // Reparenting is asynchronous: give launchd a moment to adopt it.
    var state = probe(gpa, io, dir);
    var tries: usize = 0;
    while (state != .orphan and tries < 100) : (tries += 1) {
        io.sleep(.fromMilliseconds(20), .awake) catch {};
        state = probe(gpa, io, dir);
    }
    try testing.expect(state == .orphan);
    try testing.expectEqual(orphan_pid, state.orphan);
}
