//! The scratch workspace a unit test's App opens when it wants some
//! directory and not a particular one — `App.initWith(…, .{ .workspace
//! = App.scratch_workspace })`.
//!
//! Some 360 tests used to open the real `/tmp` for that, and the App
//! reads what it opens: the tree lists it, `git.discover` walks it
//! three levels down for repos, the IPC mailbox and the session land
//! under its `.mnml/`. What `/tmp` holds is whatever else the machine
//! is doing that minute — review and QA agents park git worktrees
//! there under sixty-character names — and with two repos found the
//! workspace chip reads the first repo's name, which at 80 columns
//! pushed `[no file]` off the statusline. One full Debug run failed the
//! which-key test on it, twice; alone, once the worktrees were gone, it
//! passed every time.
//!
//! So each App gets a private empty folder instead: `<cwd>/.zig-cache/
//! tmp/unit-ws-<pid>/<n>/ws`, made by `create` from `App.initWith` and
//! removed by `remove` from `App.deinit`. Its basename is `ws`, the
//! chip the fixtures paint. The per-process parent outlives a crash;
//! the next process to make one prunes the parents an hour stale.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const parent = ".zig-cache/tmp";
const prefix = "unit-ws-";
const stale_ms: i64 = 60 * 60 * 1000;

var counter = std.atomic.Value(u32).init(0);
var pruned = std.atomic.Value(bool).init(false);

fn pid() u32 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

/// A fresh empty directory, its absolute path on `gpa`.
pub fn create(gpa: Allocator, io: Io) ![]u8 {
    const n = counter.fetchAdd(1, .monotonic);
    var rel_buf: [128]u8 = undefined;
    const rel = try std.fmt.bufPrint(&rel_buf, parent ++ "/" ++ prefix ++ "{d}/{d}/ws", .{ pid(), n });
    var dir = try Io.Dir.cwd().createDirPathOpen(io, rel, .{});
    defer dir.close(io);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    if (!pruned.swap(true, .monotonic)) pruneStale(io);
    return gpa.dupe(u8, buf[0..len]);
}

/// Remove what `create` made for `path` (`…/<n>/ws`): the `<n>` folder
/// and everything the App put under it.
pub fn remove(io: Io, path: []const u8) void {
    const n_dir = std.fs.path.dirname(path) orelse return;
    Io.Dir.cwd().deleteTree(io, n_dir) catch {};
}

/// Another process's parent folder, an hour or more untouched, is a
/// crashed run's — gone.
fn pruneStale(io: Io) void {
    var dir = Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const now = Io.Timestamp.now(io, .real).toMilliseconds();
    var mine_buf: [64]u8 = undefined;
    const mine = std.fmt.bufPrint(&mine_buf, prefix ++ "{d}", .{pid()}) catch return;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        if (!std.mem.startsWith(u8, e.name, prefix) or std.mem.eql(u8, e.name, mine)) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        if (now - st.mtime.toMilliseconds() < stale_ms) continue;
        dir.deleteTree(io, e.name) catch {};
    }
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const App = @import("../app.zig").App;

fn entryCount(path: []const u8) !usize {
    var dir = try Io.Dir.cwd().openDir(testing.io, path, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

test "App.scratch_workspace: an absolute empty folder named ws, private to its App, not /tmp, gone after deinit" {
    var a = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace });
    var b = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace });
    defer b.deinit();
    try testing.expect(std.fs.path.isAbsolute(a.workspace));
    try testing.expectEqualStrings("ws", std.fs.path.basename(a.workspace));
    try testing.expect(std.mem.indexOf(u8, a.workspace, prefix) != null);
    try testing.expect(!std.mem.eql(u8, a.workspace, b.workspace));
    try testing.expect(!std.mem.startsWith(u8, a.workspace, "/tmp"));
    try testing.expectEqual(@as(usize, 0), try entryCount(a.workspace));
    // Nothing of the machine's shows through: no repo under it.
    try @import("git.zig").discover(&a);
    try testing.expectEqual(@as(usize, 0), a.git.repos.items.len);
    const kept = try testing.allocator.dupe(u8, a.workspace);
    defer testing.allocator.free(kept);
    a.deinit();
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, kept, .{}));
}

test "a workspace named by path is opened as given and kept on deinit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var a = try App.initWith(testing.allocator, testing.io, .{ .workspace = root });
    try testing.expectEqualStrings(root, a.workspace);
    a.deinit();
    try Io.Dir.cwd().access(testing.io, root, .{});
}
