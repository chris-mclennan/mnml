//! Where an instance's API socket and its marker live, and how a client
//! picks an instance (`docs/research/api-design.md` §4.1–§4.2).
//!
//! One directory per user and profile, created 0700:
//!
//!   macOS    `$TMPDIR/<prefix><user>.api/`
//!   Linux    `$XDG_RUNTIME_DIR/<prefix><user>.api/`, else `$TMPDIR`, else `/tmp`
//!   Windows  `%LOCALAPPDATA%\<prefix><user>.api\`
//!
//! `<prefix>` is the running-instance marker's (`tui/marker.zig`), so an
//! installed mnml and a `run.sh` build never find each other. In it, per
//! instance, `<pid>.sock` (0600) and `<pid>.zon` (the marker,
//! `marker.Instance`). A socket path too long for a `sockaddr_un` falls
//! back exactly as the broker's does (`broker.fallbackPath`); the marker
//! always records the socket's full path, so a reader never re-derives it.
//! `MNML_API_DIR` names the directory outright (a `--sandbox` run, tests).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const marker = @import("../tui/marker.zig");
const broker = @import("mnml_sdk").broker;

/// The socket path, in every pane child's environment.
pub const env_socket = "MNML_API";
/// The pane's token, in the same child's environment (§5.2).
pub const env_token = "MNML_API_TOKEN";
/// An explicit directory, over the derived one.
pub const env_dir = "MNML_API_DIR";

fn nonEmpty(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len > 0) v else null;
}

/// The directory this environment's instances share. Owned.
pub fn dir(gpa: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]u8 {
    if (nonEmpty(env, env_dir)) |d| return gpa.dupe(u8, d);
    const base = switch (builtin.os.tag) {
        .windows => nonEmpty(env, "LOCALAPPDATA") orelse nonEmpty(env, "TEMP") orelse nonEmpty(env, "TMP") orelse ".",
        .macos, .ios, .tvos, .watchos, .visionos => nonEmpty(env, "TMPDIR") orelse "/tmp",
        else => nonEmpty(env, "XDG_RUNTIME_DIR") orelse nonEmpty(env, "TMPDIR") orelse "/tmp",
    };
    const user = nonEmpty(env, "USER") orelse nonEmpty(env, "USERNAME") orelse "x";
    const name = try std.fmt.allocPrint(gpa, "{s}{s}.api", .{ marker.filePrefix(env), user });
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ base, name });
}

/// `<dir>/<pid>.sock`, or the broker's short fallback when that would
/// not fit a `sockaddr_un`. Owned.
pub fn socketPath(gpa: Allocator, api_dir: []const u8, pid: i64) Allocator.Error![]u8 {
    const name = try std.fmt.allocPrint(gpa, "{d}.sock", .{pid});
    defer gpa.free(name);
    const derived = try std.fs.path.join(gpa, &.{ api_dir, name });
    if (derived.len <= broker.max_path_len) return derived;
    defer gpa.free(derived);
    return broker.fallbackPath(gpa, "api", derived);
}

/// `<dir>/<pid>.zon`. Owned.
pub fn markerPath(gpa: Allocator, api_dir: []const u8, pid: i64) Allocator.Error![]u8 {
    const name = try std.fmt.allocPrint(gpa, "{d}" ++ marker.instance_suffix, .{pid});
    defer gpa.free(name);
    return std.fs.path.join(gpa, &.{ api_dir, name });
}

/// Create the directory and hold it to its owner (0700). A directory
/// someone else made is tightened too; one we cannot tighten is an error.
pub fn ensureDir(io: Io, api_dir: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, api_dir);
    if (builtin.os.tag == .windows) return;
    try Io.Dir.cwd().setFilePermissions(io, api_dir, .fromMode(0o700), .{});
}

/// This process's id.
pub fn selfPid() i64 {
    if (builtin.os.tag == .windows) return std.os.windows.GetCurrentProcessId();
    return std.c.getpid();
}

/// Whether `pid` is a process that is still there. Windows has no cheap
/// probe: true, and a refused connection alone decides there.
pub fn alive(pid: i64) bool {
    if (builtin.os.tag == .windows) return true;
    if (pid <= 0 or pid > std.math.maxInt(i32)) return false;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| return err != error.ProcessNotFound;
    return true;
}

pub const Pick = union(enum) {
    one: usize,
    /// Nothing running, or nothing that matched what was asked for.
    none,
    /// Several, and nothing chose between them.
    ambiguous,
};

/// Which instance `mnml remote` talks to (`MNML_API` in the environment
/// is the caller's, before this): `--instance PID`, `--workspace PATH`,
/// the longest root containing `cwd`, the only one running.
pub fn pick(instances: []const marker.Instance, cwd: []const u8, want_pid: ?i64, want_ws: ?[]const u8) Pick {
    if (want_pid) |p| {
        for (instances, 0..) |inst, i| if (inst.pid == p) return .{ .one = i };
        return .none;
    }
    if (want_ws) |w| {
        for (instances, 0..) |inst, i| if (std.mem.eql(u8, trimSep(inst.workspace), trimSep(w))) return .{ .one = i };
        return .none;
    }
    var best: ?usize = null;
    var best_len: usize = 0;
    var tie = false;
    for (instances, 0..) |inst, i| {
        const roots: []const []const u8 = if (inst.roots.len > 0) inst.roots else &.{inst.workspace};
        for (roots) |r| {
            const root = trimSep(r);
            if (root.len == 0 or !contains(root, cwd)) continue;
            if (root.len > best_len) {
                best = i;
                best_len = root.len;
                tie = false;
            } else if (root.len == best_len and best != i) tie = true;
        }
    }
    if (best) |b| return if (tie) .ambiguous else .{ .one = b };
    return switch (instances.len) {
        0 => .none,
        1 => .{ .one = 0 },
        else => .ambiguous,
    };
}

fn trimSep(p: []const u8) []const u8 {
    return if (p.len > 1) std.mem.trimEnd(u8, p, "/\\") else p;
}

/// `path` is `root` or under it.
fn contains(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    const c = path[root.len];
    return c == '/' or c == '\\' or root[root.len - 1] == '/';
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "the directory is per user and profile, under TMPDIR on macOS; MNML_API_DIR wins" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/t");
    try env.put("XDG_RUNTIME_DIR", "/run/user/501");
    try env.put("USER", "chris");
    const d = try dir(t.allocator, &env);
    defer t.allocator.free(d);
    const base = switch (builtin.os.tag) {
        .macos => "/t",
        .windows => ".",
        else => "/run/user/501",
    };
    const want = try std.fmt.allocPrint(t.allocator, "{s}/{s}chris.api", .{ base, marker.filePrefix(&env) });
    defer t.allocator.free(want);
    try sdk_testing.expectPath(want, d);

    try env.put(env_dir, "/elsewhere");
    const over = try dir(t.allocator, &env);
    defer t.allocator.free(over);
    try t.expectEqualStrings("/elsewhere", over);
}

test "a socket path too long for sockaddr_un falls back to the broker's short name" {
    const short = try socketPath(t.allocator, "/t/d", 42);
    defer t.allocator.free(short);
    try sdk_testing.expectPath("/t/d/42.sock", short);
    const deep = "/" ++ "x" ** 120;
    const long = try socketPath(t.allocator, deep, 42);
    defer t.allocator.free(long);
    try t.expect(long.len <= broker.max_path_len);
    try t.expect(std.mem.indexOf(u8, long, "mnml-broker-api-") != null);
}

test "pick: an explicit pid or workspace, else the longest root holding cwd, else the only one" {
    const insts = [_]marker.Instance{
        .{ .pid = 10, .workspace = "/w", .roots = &.{"/w"} },
        .{ .pid = 11, .workspace = "/w/sub", .roots = &.{"/w/sub"} },
        .{ .pid = 12, .workspace = "/other" },
    };
    try t.expectEqual(Pick{ .one = 1 }, pick(&insts, "/w/sub/src", null, null));
    try t.expectEqual(Pick{ .one = 0 }, pick(&insts, "/w/subway", null, null));
    try t.expectEqual(Pick{ .one = 2 }, pick(&insts, "/other", null, null));
    try t.expectEqual(Pick.ambiguous, pick(&insts, "/nowhere", null, null));
    try t.expectEqual(Pick{ .one = 0 }, pick(&insts, "/nowhere", 10, null));
    try t.expectEqual(Pick.none, pick(&insts, "/w", 99, null));
    try t.expectEqual(Pick{ .one = 2 }, pick(&insts, "/w", null, "/other/"));
    try t.expectEqual(Pick{ .one = 0 }, pick(insts[0..1], "/nowhere", null, null));
    try t.expectEqual(Pick.none, pick(&.{}, "/w", null, null));
    // The longer root wins whichever order the markers listed in.
    const rev = [_]marker.Instance{ insts[1], insts[0] };
    try t.expectEqual(Pick{ .one = 0 }, pick(&rev, "/w/sub/src", null, null));
}
