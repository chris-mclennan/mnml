//! `--sandbox`: run mnml against a throwaway home, so what you see is
//! what a brand-new user sees and nothing you do reaches your real
//! config, state or credentials.
//!
//! `mnml --sandbox [WS]` makes a fresh `mnml-sandbox-XXXXXXXX`
//! directory under the temp root (`$TMPDIR`, else `/tmp`) and re-executes
//! itself — the same pid, `execve` — with this environment on top of the
//! one it was started with (everything else passes through unchanged):
//!
//!   HOME              <root>
//!   XDG_CONFIG_HOME   <root>/xdg
//!   MNML_DATA_ROOT    <root>/xdg/mnml   (the dev profile adds `-dev`)
//!   MNML_SANDBOX      <root>            (the statusline's chip reads it)
//!   MNML_SANDBOX_PID  <pid>             (who removes <root> on exit)
//!
//! It happens before any config is read, so every lookup — the data
//! root, the home config, the session, a shell pane's `~`, an
//! integration, a CLI subcommand run from inside — sees the sandbox and
//! never the real home. Without a workspace argument the sandbox's own
//! `<root>/workspace` is opened, not the directory you ran it from.
//!
//! The `--sandbox` flag stays on the re-executed command line. On that
//! second entry the environment is already a sandbox (`alreadyInside`),
//! so nothing is re-executed again. The same test recognises a bare
//! `--sandbox` in an environment that is already throwaway — `HOME`
//! under the temp root, or named `mnml-sandbox-*`, with `XDG_CONFIG_HOME`
//! and `MNML_DATA_ROOT` (when set) inside it — and runs there as it is;
//! `main` then sets `MNML_SANDBOX` to that `HOME` for the chip.
//!
//! On exit the process that made the directory (its pid is
//! `MNML_SANDBOX_PID`; a nested mnml in a shell pane is not it) removes
//! it, unless `--sandbox-keep` was given — then it says where it is. A
//! sandbox this process did not make is never removed. SIGTERM, SIGHUP
//! and SIGINT end the run the way a quit does, so it is removed then too
//! (`core/exit_signal.zig`); a crash or a `kill -9` leaves it to the OS's
//! temp cleanup.
//!
//! POSIX only: Windows has no `execve`, and the flag is refused there
//! with a message rather than half-working.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const os_path = @import("../core/os_path.zig");
const demo = @import("demo.zig");
const data_root_mod = @import("data_root.zig");

pub const flag = "--sandbox";
pub const keep_flag = "--sandbox-keep";
/// The sandbox root; set by the re-exec (or by `main` for a bare flag in
/// a throwaway home). Its presence is what paints the chip.
pub const env_var = "MNML_SANDBOX";
/// The pid of the process that created the root — the one that removes
/// it. `execve` keeps the pid, so it is the re-executed app itself.
pub const owner_env = "MNML_SANDBOX_PID";
pub const dir_prefix = "mnml-sandbox-";

pub const supported = builtin.os.tag != .windows;

/// `--sandbox`, `--sandbox-keep` or `--demo` (a sandbox with a
/// workspace in it, `demo.zig`) anywhere on the line.
pub fn wanted(args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag) or std.mem.eql(u8, a, keep_flag) or std.mem.eql(u8, a, demo.flag)) return true;
    return false;
}

pub fn keep(args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, keep_flag)) return true;
    return false;
}

fn nonEmpty(env: *const Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

fn trimSep(p: []const u8) []const u8 {
    var s = p;
    while (s.len > 1 and std.fs.path.isSep(s[s.len - 1])) s = s[0 .. s.len - 1];
    return s;
}

/// `path` is strictly inside `parent`, on a component boundary:
/// `/tmp/a` is under `/tmp` and `/tmp/`; `/tmpx` and `/tmp` are not.
pub fn isUnder(path: []const u8, parent: []const u8) bool {
    const p = trimSep(path);
    const root = trimSep(parent);
    if (root.len == 0) return false;
    if (std.mem.eql(u8, root, "/")) return p.len > 1 and p[0] == '/';
    // Either separator on Windows: the sandbox's own paths are joined
    // there with `\`.
    return p.len > root.len + 1 and std.mem.startsWith(u8, p, root) and std.fs.path.isSep(p[root.len]);
}

/// The probe: `home` is a sandbox tempdir — strictly under the temp root
/// `tmp_root`, or named `mnml-sandbox-*` wherever it is.
pub fn homeIsSandbox(home: ?[]const u8, tmp_root: []const u8) bool {
    const h = home orelse return false;
    if (h.len == 0) return false;
    if (isUnder(h, tmp_root)) return true;
    return std.mem.startsWith(u8, std.fs.path.basename(trimSep(h)), dir_prefix);
}

/// This environment already is a sandbox the flag can run in as it is:
/// `HOME` passes `homeIsSandbox`, and neither `XDG_CONFIG_HOME` nor
/// `MNML_DATA_ROOT` points outside it (either would put the config or
/// the state back in the real home).
pub fn alreadyInside(env: *const Map) bool {
    const home = nonEmpty(env, "HOME") orelse return false;
    if (!homeIsSandbox(home, os_path.tempDir(env, .posix))) return false;
    for ([_][]const u8{ "XDG_CONFIG_HOME", "MNML_DATA_ROOT" }) |k| {
        const v = nonEmpty(env, k) orelse continue;
        if (!isUnder(v, home)) return false;
    }
    return true;
}

/// What the statusline shows: nothing, the sandbox, or a sandbox that is
/// not one — `MNML_SANDBOX` is set but the home is not a sandbox tempdir
/// or the data root is outside it, so the chip must not promise safety.
pub const State = enum { off, on, unsafe };

pub fn state(env: *const Map, data_root: []const u8) State {
    _ = nonEmpty(env, env_var) orelse return .off;
    const home = nonEmpty(env, "HOME") orelse return .unsafe;
    if (!homeIsSandbox(home, os_path.tempDir(env, .posix))) return .unsafe;
    if (!isUnder(data_root, home)) return .unsafe;
    return .on;
}

/// The re-exec: the command line and the variables to set on top of the
/// current environment.
pub const Plan = struct {
    argv: []const []const u8,
    /// `HOME`, `XDG_CONFIG_HOME`, `MNML_DATA_ROOT`, `MNML_SANDBOX`,
    /// `MNML_SANDBOX_PID`, in that order.
    set: [5][2][]const u8,
    workspace: []const u8,
    /// `Extra.set`, after `set`.
    extra: []const [2][]const u8 = &.{},
    /// `Extra.unset`: removed from the environment first.
    unset: []const []const u8 = &.{},
};

/// What a caller adds to the plain sandbox — `--demo`'s workspace name
/// and variables (`demo.zig`).
pub const Extra = struct {
    /// The directory under the root that is opened without a workspace
    /// argument.
    workspace: []const u8 = "workspace",
    set: []const [2][]const u8 = &.{},
    unset: []const []const u8 = &.{},
};

/// `args` is the whole command line, `args[0]` the program. The flag is
/// kept; `exe` replaces `args[0]` (an absolute path, so the re-exec does
/// not depend on `PATH`); `<root>/workspace` is appended when no
/// positional argument names one. `takes_value` says which flags eat the
/// next argument (`--input vim`: "vim" is not a workspace). Everything
/// is allocated in `arena`.
pub fn plan(arena: Allocator, exe: []const u8, args: []const []const u8, root: []const u8, pid: i64, takes_value: *const fn ([]const u8) bool, extra: Extra) Allocator.Error!Plan {
    const workspace = try std.fs.path.join(arena, &.{ root, extra.workspace });
    const xdg = try std.fs.path.join(arena, &.{ root, "xdg" });
    const data = try std.fs.path.join(arena, &.{ xdg, "mnml" });
    const positional = hasPositional(args, takes_value);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, exe);
    if (args.len > 1) try argv.appendSlice(arena, args[1..]);
    if (!positional) try argv.append(arena, workspace);
    return .{
        .argv = argv.items,
        .set = .{
            .{ "HOME", root },
            .{ "XDG_CONFIG_HOME", xdg },
            .{ "MNML_DATA_ROOT", data },
            .{ env_var, root },
            .{ owner_env, try std.fmt.allocPrint(arena, "{d}", .{pid}) },
        },
        .workspace = workspace,
        .extra = extra.set,
        .unset = extra.unset,
    };
}

/// A workspace (or file) argument after `args[0]`.
fn hasPositional(args: []const []const u8, takes_value: *const fn ([]const u8) bool) bool {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (takes_value(a)) {
            i += 1;
            continue;
        }
        if (a.len > 0 and a[0] == '-') continue;
        return true;
    }
    return false;
}

/// Make `<tmp_root>/mnml-sandbox-XXXXXXXX` (0700) with `xdg/` and the
/// workspace directory `ws_name` inside. Returns the root, in `arena`.
pub fn create(arena: Allocator, io: Io, tmp_root: []const u8, ws_name: []const u8) ![]const u8 {
    if (comptime !supported) return error.Unsupported;
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    var attempt: u8 = 0;
    while (attempt < 16) : (attempt += 1) {
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        var name: [dir_prefix.len + 8]u8 = undefined;
        @memcpy(name[0..dir_prefix.len], dir_prefix);
        for (rnd, 0..) |b, k| name[dir_prefix.len + k] = alphabet[b % alphabet.len];
        const root = try std.fs.path.join(arena, &.{ tmp_root, &name });
        Io.Dir.cwd().createDir(io, root, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        var dir = try Io.Dir.cwd().openDir(io, root, .{});
        defer dir.close(io);
        try dir.createDirPath(io, "xdg/mnml");
        try dir.createDirPath(io, ws_name);
        return root;
    }
    return error.PathAlreadyExists;
}

fn getpid() i64 {
    if (comptime !supported) return 0;
    return @intCast(std.c.getpid());
}

/// `main`'s step, before anything reads the environment. Returns null to
/// carry on (no flag, or already inside a sandbox — `env` then has
/// `MNML_SANDBOX`), or an exit code when the sandbox could not be made.
/// On success the re-exec does not return.
pub fn enter(arena: Allocator, io: Io, env: *Map, args: []const []const u8, err_w: *Io.Writer, takes_value: *const fn ([]const u8) bool) !?u8 {
    if (!wanted(args)) return null;
    if (comptime !supported) {
        try err_w.writeAll("mnml: --sandbox is not supported on Windows (it re-executes itself, which Windows cannot);\n" ++
            "  set HOME, XDG_CONFIG_HOME and MNML_DATA_ROOT to a throwaway directory by hand instead\n");
        return 2;
    }
    const is_demo = demo.wanted(args);
    // The re-exec appends the demo's own workspace: only the first
    // entry can have been handed one.
    if (is_demo and demo.workspaceOf(env) == null and hasPositional(args, takes_value)) {
        try err_w.writeAll("mnml: --demo opens its own workspace; drop the path (or use --sandbox with it)\n");
        return 2;
    }
    if (alreadyInside(env)) {
        // `--demo`'s own re-exec carries `MNML_DEMO`; a bare `--demo` in
        // a home that already is throwaway has no workspace and no fakes
        // set up, so it is not half-run.
        if (is_demo and demo.workspaceOf(env) == null) {
            try err_w.writeAll("mnml: --demo cannot start inside a sandbox (HOME is already throwaway); run it from your own shell\n");
            return 2;
        }
        if (nonEmpty(env, env_var) == null) try env.put(env_var, env.get("HOME").?);
        return null;
    }
    // The re-executed process is this pid: if it still is not inside, a
    // second exec would only loop.
    if (nonEmpty(env, owner_env)) |p| if (std.fmt.parseInt(i64, p, 10) catch -1 == getpid()) {
        try err_w.writeAll("mnml: --sandbox: the re-executed environment is still not a sandbox; refusing to loop\n");
        return 70;
    };
    const root = create(arena, io, os_path.tempDir(env, .posix), if (is_demo) demo.workspace_name else "workspace") catch |err| {
        try err_w.print("mnml: --sandbox: cannot create the sandbox under {s}: {s}\n", .{ os_path.tempDir(env, .posix), @errorName(err) });
        return 70;
    };
    const exe = std.process.executablePathAlloc(io, arena) catch |err| {
        try err_w.print("mnml: --sandbox: cannot find this binary: {s}\n", .{@errorName(err)});
        return 70;
    };
    // The data root this run would have used: where the Marketplace put
    // the integrations `--demo` opens, found again from inside the sandbox.
    const host_data_root: ?[]const u8 = if (is_demo) try data_root_mod.dataRoot(arena, io, .{ .vars = env, .exe_dir = std.fs.path.dirname(exe) }) else null;
    const extra: Extra = if (is_demo) .{
        .workspace = demo.workspace_name,
        .set = try demo.extraSet(arena, root, env.get("PATH"), host_data_root),
        .unset = &demo.unset,
    } else .{};
    const p = try plan(arena, exe, args, root, getpid(), takes_value, extra);
    var child_env = try env.clone(arena);
    for (p.unset) |k| _ = child_env.swapRemove(k);
    for (p.set) |kv| try child_env.put(kv[0], kv[1]);
    for (p.extra) |kv| try child_env.put(kv[0], kv[1]);
    try err_w.print("mnml: {s}: HOME={s} (removed on exit; --sandbox-keep keeps it)\n", .{ if (is_demo) demo.flag else flag, root });
    try err_w.flush();
    const err = std.process.replace(io, .{ .argv = p.argv, .environ_map = &child_env });
    try err_w.print("mnml: --sandbox: exec failed: {s}\n", .{@errorName(err)});
    Io.Dir.cwd().deleteTree(io, root) catch {};
    return 70;
}

/// The sandbox root this process owns — it made it (`MNML_SANDBOX_PID`
/// is this pid) and the path is one `create` would make. Null otherwise.
pub fn owned(env: *const Map, pid: i64) ?[]const u8 {
    const root = nonEmpty(env, env_var) orelse return null;
    const owner = nonEmpty(env, owner_env) orelse return null;
    if ((std.fmt.parseInt(i64, owner, 10) catch return null) != pid) return null;
    if (!std.mem.startsWith(u8, std.fs.path.basename(trimSep(root)), dir_prefix)) return null;
    if (!isUnder(root, os_path.tempDir(env, .posix))) return null;
    return root;
}

/// On the way out: remove the sandbox this process made, or say where it
/// was kept. Anything else is left alone.
pub fn finish(io: Io, env: *const Map, args: []const []const u8, err_w: *Io.Writer) void {
    const root = owned(env, getpid()) orelse return;
    if (keep(args)) {
        err_w.print("mnml: sandbox kept at {s}\n", .{root}) catch {};
    } else {
        Io.Dir.cwd().deleteTree(io, root) catch |err| {
            err_w.print("mnml: sandbox {s} not removed: {s}\n", .{ root, @errorName(err) }) catch {};
            err_w.flush() catch {};
            return;
        };
        err_w.print("mnml: sandbox {s} removed\n", .{root}) catch {};
    }
    err_w.flush() catch {};
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

fn testTakesValue(a: []const u8) bool {
    return std.mem.eql(u8, a, "--input") or std.mem.eql(u8, a, "--config") or std.mem.eql(u8, a, "--profile");
}

test "the probe: a home under the temp root, or named mnml-sandbox-*, is a sandbox; the temp root itself, a sibling and the real home are not" {
    try t.expect(homeIsSandbox("/tmp/abc", "/tmp"));
    try t.expect(homeIsSandbox("/var/folders/x/T/mnml-sandbox-a1b2c3d4", "/var/folders/x/T/"));
    try t.expect(homeIsSandbox("/elsewhere/mnml-sandbox-a1b2c3d4", "/tmp"));
    try t.expect(homeIsSandbox("/elsewhere/mnml-sandbox-a1b2c3d4/", "/tmp"));
    try t.expect(!homeIsSandbox("/Users/dev", "/tmp"));
    try t.expect(!homeIsSandbox("/tmp", "/tmp"));
    try t.expect(!homeIsSandbox("/tmp/", "/tmp"));
    try t.expect(!homeIsSandbox("/tmpfoo/x", "/tmp"));
    try t.expect(!homeIsSandbox("/Users/dev/mnml-sandbox", "/tmp"));
    try t.expect(!homeIsSandbox(null, "/tmp"));
    try t.expect(!homeIsSandbox("", "/tmp"));
}

test "alreadyInside: a throwaway HOME counts only while XDG_CONFIG_HOME and MNML_DATA_ROOT stay inside it" {
    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/tmp");
    try env.put("HOME", "/Users/dev");
    try t.expect(!alreadyInside(&env));
    try env.put("HOME", "/tmp/mnml-sandbox-abcdefgh");
    try t.expect(alreadyInside(&env));
    try env.put("XDG_CONFIG_HOME", "/tmp/mnml-sandbox-abcdefgh/xdg");
    try env.put("MNML_DATA_ROOT", "/tmp/mnml-sandbox-abcdefgh/xdg/mnml");
    try t.expect(alreadyInside(&env));
    try env.put("MNML_DATA_ROOT", "/Users/dev/.config/mnml");
    try t.expect(!alreadyInside(&env));
    try env.put("MNML_DATA_ROOT", "");
    try env.put("XDG_CONFIG_HOME", "/Users/dev/.config");
    try t.expect(!alreadyInside(&env));
}

test "the re-exec plan: the flag kept, the binary absolute, HOME / XDG_CONFIG_HOME / MNML_DATA_ROOT / MNML_SANDBOX / MNML_SANDBOX_PID set, the sandbox workspace only without one" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = "/tmp/mnml-sandbox-abcdefgh";

    const bare = try plan(arena, "/opt/bin/mnml-zig", &.{ "mnml-zig", "--sandbox" }, root, 4242, testTakesValue, .{});
    try t.expectEqual(@as(usize, 3), bare.argv.len);
    try sdk_testing.expectPath("/opt/bin/mnml-zig", bare.argv[0]);
    try t.expectEqualStrings("--sandbox", bare.argv[1]);
    try sdk_testing.expectPath(root ++ "/workspace", bare.argv[2]);
    try t.expectEqualStrings("HOME", bare.set[0][0]);
    try t.expectEqualStrings(root, bare.set[0][1]);
    try t.expectEqualStrings("XDG_CONFIG_HOME", bare.set[1][0]);
    try sdk_testing.expectPath(root ++ "/xdg", bare.set[1][1]);
    try t.expectEqualStrings("MNML_DATA_ROOT", bare.set[2][0]);
    try sdk_testing.expectPath(root ++ "/xdg/mnml", bare.set[2][1]);
    try t.expectEqualStrings(env_var, bare.set[3][0]);
    try t.expectEqualStrings(root, bare.set[3][1]);
    try t.expectEqualStrings(owner_env, bare.set[4][0]);
    try t.expectEqualStrings("4242", bare.set[4][1]);

    // A flag's value is not a workspace: the sandbox's is still added,
    // and every argument passes through in order.
    const valued = try plan(arena, "/x", &.{ "mnml-zig", "--input", "vim", "--sandbox", "--profile", "dev" }, root, 1, testTakesValue, .{});
    try t.expectEqual(@as(usize, 7), valued.argv.len);
    try t.expectEqualStrings("vim", valued.argv[2]);
    try t.expectEqualStrings("--sandbox", valued.argv[3]);
    try sdk_testing.expectPath(root ++ "/workspace", valued.argv[6]);

    // A workspace of your own is honoured — no second one.
    const own = try plan(arena, "/x", &.{ "mnml-zig", "/Users/dev/proj", "--sandbox-keep" }, root, 1, testTakesValue, .{});
    try t.expectEqual(@as(usize, 3), own.argv.len);
    try sdk_testing.expectPath("/Users/dev/proj", own.argv[1]);
    try t.expectEqualStrings("--sandbox-keep", own.argv[2]);

    // Second entry: the planned environment is already a sandbox, so the
    // kept flag re-executes nothing.
    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/tmp/");
    try env.put("HOME", "/Users/dev");
    try env.put("XDG_CONFIG_HOME", "/Users/dev/.config");
    try env.put("PATH", "/usr/bin");
    try t.expect(!alreadyInside(&env));
    for (bare.set) |kv| try env.put(kv[0], kv[1]);
    try t.expect(alreadyInside(&env));
    try t.expect(wanted(bare.argv));
    try sdk_testing.expectPath("/usr/bin", env.get("PATH").?);
}

test "the chip's state: off without MNML_SANDBOX; on with the home a sandbox and the data root inside; unsafe otherwise" {
    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/tmp");
    try env.put("HOME", "/tmp/mnml-sandbox-abcdefgh");
    try t.expectEqual(State.off, state(&env, "/tmp/mnml-sandbox-abcdefgh/xdg/mnml"));
    try env.put(env_var, "/tmp/mnml-sandbox-abcdefgh");
    try t.expectEqual(State.on, state(&env, "/tmp/mnml-sandbox-abcdefgh/xdg/mnml"));
    try t.expectEqual(State.unsafe, state(&env, "/Users/dev/.config/mnml"));
    try env.put("HOME", "/Users/dev");
    try t.expectEqual(State.unsafe, state(&env, "/Users/dev/.config/mnml"));
}

test "ownership: only the pid that made it, only a mnml-sandbox-* under the temp root" {
    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("TMPDIR", "/tmp");
    try t.expect(owned(&env, 7) == null);
    try env.put(env_var, "/tmp/mnml-sandbox-abcdefgh");
    try env.put(owner_env, "7");
    try sdk_testing.expectPath("/tmp/mnml-sandbox-abcdefgh", owned(&env, 7).?);
    // A nested mnml in a shell pane inherits both, with its own pid.
    try t.expect(owned(&env, 8) == null);
    // A root that is not one `create` makes is never ours to remove.
    try env.put(env_var, "/Users/dev");
    try t.expect(owned(&env, 7) == null);
    try env.put(env_var, "/elsewhere/mnml-sandbox-abcdefgh");
    try t.expect(owned(&env, 7) == null);
}

test "create: a private mnml-sandbox-* directory with xdg/mnml and workspace inside, and data_root resolves inside it" {
    if (comptime !supported) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try create(arena, t.io, buf[0..n], "workspace");
    try t.expect(std.mem.startsWith(u8, std.fs.path.basename(root), dir_prefix));
    try t.expect(isUnder(root, buf[0..n]));
    const st = try Io.Dir.cwd().statFile(t.io, root, .{});
    try t.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    var ws = try Io.Dir.cwd().openDir(t.io, try std.fs.path.join(arena, &.{ root, "workspace" }), .{});
    ws.close(t.io);

    // The environment the re-exec hands on: the data root is the
    // sandbox's, for both profiles, and the chip says so.
    const p = try plan(arena, "/x", &.{"mnml-zig"}, root, 1, testTakesValue, .{});
    var env: Map = .init(t.allocator);
    defer env.deinit();
    try env.put("TMPDIR", buf[0..n]);
    try env.put("HOME", "/Users/dev");
    for (p.set) |kv| try env.put(kv[0], kv[1]);
    const data_root = @import("data_root.zig");
    const dr = try data_root.dataRoot(t.allocator, t.io, .{ .vars = &env });
    defer t.allocator.free(dr);
    try t.expect(isUnder(dr, root));
    try t.expectEqual(State.on, state(&env, dr));
    try env.put("MNML_PROFILE", "dev");
    const dev = try data_root.dataRoot(t.allocator, t.io, .{ .vars = &env });
    defer t.allocator.free(dev);
    try t.expect(isUnder(dev, root));
    try t.expect(std.mem.endsWith(u8, dev, "-dev"));
}
