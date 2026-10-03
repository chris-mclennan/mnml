//! The running-instance marker: `${TMPDIR:-/tmp}/mnml-zig-running-${USER}.workspace`
//! holds the interactive instance's workspace (its real path, no trailing
//! newline). `run.sh restart` / `stop` / `status` and `scripts/shot.sh`
//! read it to find the instance's IPC directory and its window.
//!
//! The terminal loop writes it on start and removes it on a clean exit —
//! not on a restart's exit 75, where the wrapper relaunches straight
//! away. A second instance overwrites it, so removal is conditional on
//! the file still naming this instance's workspace. Headless writes
//! nothing: the wrapper keeps the marker for a headless loop itself.
//!
//! The prefix is the profile's (`src/config/profile.zig`): the dev
//! profile is always `mnml-zig-running-…`, and the stable one is what
//! the build was named — `mnml-running-…` for an installed mnml
//! (`-Dinstall-names`), this tree's `mnml-zig-running-…` otherwise. So
//! the installed mnml and a `run.sh` build never find each other's
//! instance (`docs/DESIGN.md`, "Side-by-side mechanics").

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const profile_mod = @import("../config/profile.zig");

pub const file_suffix = ".workspace";

/// The marker prefix for this environment's profile.
pub fn filePrefix(env: *const std.process.Environ.Map) []const u8 {
    return profile_mod.markerPrefix(profile_mod.of(env));
}

/// The marker's path for this environment. `TMPDIR` (then `TEMP`, `TMP`
/// — the Windows spellings), else `/tmp`; `USER` (then `USERNAME`), else
/// `x`, mirroring the wrapper's `${USER:-x}`. Owned.
pub fn path(alloc: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    const tmp = firstNonEmpty(env, &.{ "TMPDIR", "TEMP", "TMP" }) orelse "/tmp";
    const user = firstNonEmpty(env, &.{ "USER", "USERNAME" }) orelse "x";
    const name = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ filePrefix(env), user, file_suffix });
    defer alloc.free(name);
    return std.fs.path.join(alloc, &.{ tmp, name });
}

fn firstNonEmpty(env: *const std.process.Environ.Map, names: []const []const u8) ?[]const u8 {
    for (names) |n| if (env.get(n)) |v| if (v.len > 0) return v;
    return null;
}

/// Create or overwrite the marker with `workspace`, verbatim: no newline.
pub fn write(io: Io, marker_path: []const u8, workspace: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, marker_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, workspace);
}

/// What the marker names, or null when there is none. Owned.
pub fn read(alloc: Allocator, io: Io, marker_path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, marker_path, alloc, .limited(std.fs.max_path_bytes)) catch null;
}

/// Remove the marker if it still names `workspace`. A newer instance's
/// marker is left alone; a missing one is fine.
pub fn removeIfOurs(alloc: Allocator, io: Io, marker_path: []const u8, workspace: []const u8) void {
    const current = read(alloc, io, marker_path) orelse return;
    defer alloc.free(current);
    if (!std.mem.eql(u8, current, workspace)) return;
    Io.Dir.cwd().deleteFile(io, marker_path) catch {};
}

// ─── one marker per instance (`docs/research/api-design.md` §4.2) ────────
//
// Beside each instance's API socket, `<pid>.zon` — written at start,
// removed on a clean exit. The single marker above stays "the last one
// started", for `run.sh`; these are every instance, for `mnml remote`.

pub const instance_suffix = ".zon";

pub const Instance = struct {
    pid: i64 = 0,
    version: []const u8 = "",
    workspace: []const u8 = "",
    roots: []const []const u8 = &.{},
    /// The socket's full path.
    socket: []const u8 = "",
    started_ms: i64 = 0,
    frames: u32 = 1,
};

/// Write `inst` to `marker_path` as ZON, owner-only.
pub fn writeInstance(gpa: Allocator, io: Io, marker_path: []const u8, inst: Instance) !void {
    var a: Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    std.zon.stringify.serialize(inst, .{ .whitespace = false }, &a.writer) catch return error.OutOfMemory;
    a.writer.writeByte('\n') catch return error.OutOfMemory;
    try @import("../ipc/channel.zig").writeSecret(io, marker_path, a.written());
}

/// Every instance marker in `dir`, parsed into `arena`, oldest first. A
/// file that does not parse is skipped; a missing directory is none.
pub fn listInstances(arena: Allocator, io: Io, dir_path: []const u8) Allocator.Error![]Instance {
    var out: std.ArrayList(Instance) = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, instance_suffix)) continue;
        const text = dir.readFileAllocOptions(io, e.name, arena, .limited(64 * 1024), .of(u8), 0) catch continue;
        const inst = std.zon.parse.fromSliceAlloc(Instance, arena, text, null, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        try out.append(arena, inst);
    }
    std.mem.sortUnstable(Instance, out.items, {}, struct {
        fn lt(_: void, a: Instance, b: Instance) bool {
            return a.started_ms < b.started_ms;
        }
    }.lt);
    return out.items;
}

// ─── tests ───────────────────────────────────────────────────────────────

test "an instance marker round-trips as ZON, owner-only, and the directory lists it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    const p = try std.fs.path.join(t.allocator, &.{ root, "4242.zon" });
    defer t.allocator.free(p);
    try writeInstance(t.allocator, t.io, p, .{ .pid = 4242, .version = "0.3.2", .workspace = "/ws", .roots = &.{"/ws"}, .socket = "/d/4242.sock", .started_ms = 7 });
    // Not a marker: skipped.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "junk.zon", .data = "not zon" });
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const got = try listInstances(arena_state.allocator(), t.io, root);
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqual(@as(i64, 4242), got[0].pid);
    try t.expectEqualStrings("/ws", got[0].roots[0]);
    try t.expectEqualStrings("/d/4242.sock", got[0].socket);
    if (@import("builtin").os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(t.io, p, .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
    const none = try listInstances(arena_state.allocator(), t.io, "/no/such/dir/at/all");
    try t.expectEqual(@as(usize, 0), none.len);
}

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "the path is TMPDIR/mnml-zig-running-USER.workspace" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/var/folders/xy/T");
    try env.put("USER", "chris");
    const p = try path(t.allocator, &env);
    defer t.allocator.free(p);
    try sdk_testing.expectPath("/var/folders/xy/T/mnml-zig-running-chris.workspace", p);
}

test "no TMPDIR means /tmp; no USER means x; an empty value counts as unset" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    const bare = try path(t.allocator, &env);
    defer t.allocator.free(bare);
    try sdk_testing.expectPath("/tmp/mnml-zig-running-x.workspace", bare);

    try env.put("TMPDIR", "");
    try env.put("USER", "");
    const empty = try path(t.allocator, &env);
    defer t.allocator.free(empty);
    try sdk_testing.expectPath("/tmp/mnml-zig-running-x.workspace", empty);
}

test "the dev profile has its own marker, so restart never reaches the other instance" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/t");
    try env.put("USER", "chris");
    try env.put("MNML_PROFILE", "dev");
    const dev = try path(t.allocator, &env);
    defer t.allocator.free(dev);
    try sdk_testing.expectPath("/t/mnml-zig-running-chris.workspace", dev);

    try env.put("MNML_PROFILE", "stable");
    const stable = try path(t.allocator, &env);
    defer t.allocator.free(stable);
    const want = try std.fmt.allocPrint(t.allocator, "/t/{s}chris.workspace", .{profile_mod.markerPrefix(.stable)});
    defer t.allocator.free(want);
    try sdk_testing.expectPath(want, stable);
}

test "the Windows spellings fill in: TEMP for TMPDIR, USERNAME for USER" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("TEMP", "/w/temp");
    try env.put("USERNAME", "chris");
    const p = try path(t.allocator, &env);
    defer t.allocator.free(p);
    try sdk_testing.expectPath("/w/temp/mnml-zig-running-chris.workspace", p);
}

test "the marker holds the workspace verbatim, no trailing newline, and only its own instance removes it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    const p = try std.fs.path.join(t.allocator, &.{ root, "mnml-zig-running-x.workspace" });
    defer t.allocator.free(p);

    try write(t.io, p, "/Users/x/proj");
    const got = read(t.allocator, t.io, p).?;
    defer t.allocator.free(got);
    try t.expectEqualStrings("/Users/x/proj", got);
    try t.expect(got[got.len - 1] != '\n');

    // Another workspace's exit leaves it in place; ours removes it.
    removeIfOurs(t.allocator, t.io, p, "/Users/x/other");
    const kept = read(t.allocator, t.io, p) orelse return error.TestUnexpectedResult;
    t.allocator.free(kept);
    removeIfOurs(t.allocator, t.io, p, "/Users/x/proj");
    try t.expect(read(t.allocator, t.io, p) == null);
    // Gone already: not an error.
    removeIfOurs(t.allocator, t.io, p, "/Users/x/proj");
}
