//! Where mnml keeps its state, and where the home config file lives.
//!
//! `dataRoot` precedence:
//!   1. `$MNML_DATA_ROOT` (non-empty)
//!   2. portable: `<binary dir>/mnml-data/` when that directory exists and
//!      holds an `.opted-in` marker
//!   3. `$XDG_CONFIG_HOME/mnml/` — but only if it already has state (a
//!      `config.zon` or an `integrations/` dir); otherwise fall through to
//!      `$HOME/.config/mnml/` if THAT has state; otherwise the XDG path
//!   4. `$HOME/.config/mnml/`
//!   5. `./mnml`
//!
//! `homeConfigPath` is the same ladder minus the state probes (a fresh
//! install has no state yet, and the file it names is where it will go).
//!
//! That ladder answers for the *stable* profile. The dev profile
//! (`MNML_PROFILE=dev`, `config/profile.zig`) is the same answer with
//! `-dev` on the end — at every rung, the explicit `$MNML_DATA_ROOT`
//! included — so the two profiles never share a file and there is still
//! only one precedence to reason about. `stableDataRoot` is the
//! un-suffixed answer, for the one caller that needs both: the seeder.
//!
//! Every function takes the environment and the binary dir as values so
//! tests can hand in a fake map and a tmp dir; only the existence probes
//! touch the file system, through `io`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const profile_mod = @import("profile.zig");
pub const Profile = profile_mod.Profile;

pub const config_file = "config.zon";
pub const portable_dir = "mnml-data";
pub const portable_opt_in = ".opted-in";
pub const user_choice_marker = ".user-welcomed";

pub const Kind = enum { portable, home };

pub const PortableState = enum { absent, awaiting_consent, active };

pub const Env = struct {
    vars: *const std.process.Environ.Map,
    /// Directory of the running binary; `null` when it cannot be found.
    exe_dir: ?[]const u8 = null,

    fn get(env: Env, key: []const u8) ?[]const u8 {
        const v = env.vars.get(key) orelse return null;
        return if (v.len == 0) null else v;
    }

    /// The user's home: `$HOME`, or `%USERPROFILE%` where that is the
    /// spelling (Windows sets no `HOME`; MSYS and Git Bash set both).
    pub fn home(env: Env) ?[]const u8 {
        return env.get("HOME") orelse env.get("USERPROFILE");
    }

    /// The profile this environment asks for (`MNML_PROFILE`).
    pub fn profile(env: Env) Profile {
        return profile_mod.of(env.vars);
    }
};

/// `base` as this profile spells it: itself for stable, `base-dev` for
/// dev. Frees `base` either way; the result is owned.
fn withProfile(alloc: Allocator, base: []u8, p: Profile) Allocator.Error![]u8 {
    const sfx = profile_mod.suffix(p);
    if (sfx.len == 0) return base;
    defer alloc.free(base);
    return std.mem.concat(alloc, u8, &.{ base, sfx });
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isDir(io: Io, path: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// `<binary dir>/mnml-data`, or null without a binary dir.
pub fn portableCandidate(alloc: Allocator, env: Env) Allocator.Error!?[]u8 {
    const dir = env.exe_dir orelse return null;
    return try std.fs.path.join(alloc, &.{ dir, portable_dir });
}

pub fn portableState(alloc: Allocator, io: Io, env: Env) Allocator.Error!PortableState {
    const candidate = (try portableCandidate(alloc, env)) orelse return .absent;
    defer alloc.free(candidate);
    if (!isDir(io, candidate)) return .absent;
    const marker = try std.fs.path.join(alloc, &.{ candidate, portable_opt_in });
    defer alloc.free(marker);
    return if (exists(io, marker)) .active else .awaiting_consent;
}

fn hasState(alloc: Allocator, io: Io, root: []const u8) Allocator.Error!bool {
    const cfg = try std.fs.path.join(alloc, &.{ root, config_file });
    defer alloc.free(cfg);
    if (exists(io, cfg)) return true;
    const integrations = try std.fs.path.join(alloc, &.{ root, "integrations" });
    defer alloc.free(integrations);
    return isDir(io, integrations);
}

/// Where this profile keeps its state.
pub fn dataRoot(alloc: Allocator, io: Io, env: Env) Allocator.Error![]u8 {
    return withProfile(alloc, try stableDataRoot(alloc, io, env), env.profile());
}

/// The stable profile's root, whatever profile is running — what the
/// dev profile seeds itself from.
pub fn stableDataRoot(alloc: Allocator, io: Io, env: Env) Allocator.Error![]u8 {
    if (env.get("MNML_DATA_ROOT")) |root| return alloc.dupe(u8, root);
    if (try portableState(alloc, io, env) == .active) {
        if (try portableCandidate(alloc, env)) |p| return p;
    }
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        const xdg_path = try std.fs.path.join(alloc, &.{ xdg, "mnml" });
        if (try hasState(alloc, io, xdg_path)) return xdg_path;
        if (env.home()) |home| {
            const home_path = try std.fs.path.join(alloc, &.{ home, ".config", "mnml" });
            if (try hasState(alloc, io, home_path)) {
                alloc.free(xdg_path);
                return home_path;
            }
            alloc.free(home_path);
        }
        return xdg_path;
    }
    if (env.home()) |home| return std.fs.path.join(alloc, &.{ home, ".config", "mnml" });
    return alloc.dupe(u8, "mnml");
}

pub fn dataRootKind(alloc: Allocator, io: Io, env: Env) Allocator.Error!Kind {
    return if (try portableState(alloc, io, env) == .active) .portable else .home;
}

/// The user-level `config.zon`, or null when there is no home at all.
pub fn homeConfigPath(alloc: Allocator, io: Io, env: Env) Allocator.Error!?[]u8 {
    const root = (try homeConfigRoot(alloc, io, env)) orelse return null;
    defer alloc.free(root);
    return try std.fs.path.join(alloc, &.{ root, config_file });
}

/// The directory `homeConfigPath` names — the ladder without the state
/// probes, with the profile applied. Null when there is no home at all.
fn homeConfigRoot(alloc: Allocator, io: Io, env: Env) Allocator.Error!?[]u8 {
    const p = env.profile();
    if (env.get("MNML_DATA_ROOT")) |root| return try withProfile(alloc, try alloc.dupe(u8, root), p);
    if (try portableState(alloc, io, env) == .active) {
        if (try portableCandidate(alloc, env)) |c| return try withProfile(alloc, c, p);
    }
    if (env.get("XDG_CONFIG_HOME")) |xdg| return try withProfile(alloc, try std.fs.path.join(alloc, &.{ xdg, "mnml" }), p);
    if (env.home()) |home| return try withProfile(alloc, try std.fs.path.join(alloc, &.{ home, ".config", "mnml" }), p);
    return null;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

const Sandbox = struct {
    tmp: t.TmpDir,
    root: []u8,
    vars: std.process.Environ.Map,

    fn init() !Sandbox {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &buf);
        const root = try t.allocator.dupe(u8, buf[0..n]);
        return .{ .tmp = tmp, .root = root, .vars = std.process.Environ.Map.init(t.allocator) };
    }

    fn deinit(s: *Sandbox) void {
        s.vars.deinit();
        t.allocator.free(s.root);
        s.tmp.cleanup();
    }

    fn sub(s: *Sandbox, rel: []const u8) ![]u8 {
        return std.fs.path.join(t.allocator, &.{ s.root, rel });
    }

    fn env(s: *Sandbox, exe_dir: ?[]const u8) Env {
        return .{ .vars = &s.vars, .exe_dir = exe_dir };
    }
};

fn expectPath(actual: []const u8, root: []const u8, rel: []const u8) !void {
    const want = try std.fs.path.join(t.allocator, &.{ root, rel });
    defer t.allocator.free(want);
    try sdk_testing.expectPath(want, actual);
}

test "MNML_DATA_ROOT wins over everything" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.vars.put("MNML_DATA_ROOT", "/explicit/root");
    try s.vars.put("HOME", "/home/x");
    try s.vars.put("XDG_CONFIG_HOME", "/xdg");
    const root = try dataRoot(t.allocator, t.io, s.env(null));
    defer t.allocator.free(root);
    try sdk_testing.expectPath("/explicit/root", root);
    const cfg = (try homeConfigPath(t.allocator, t.io, s.env(null))).?;
    defer t.allocator.free(cfg);
    try sdk_testing.expectPath("/explicit/root/config.zon", cfg);
}

test "portable needs the directory AND the opt-in marker" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.vars.put("HOME", "/home/x");
    const bin = try s.sub("bin");
    defer t.allocator.free(bin);
    try s.tmp.dir.createDirPath(t.io, "bin");

    try t.expectEqual(PortableState.absent, try portableState(t.allocator, t.io, s.env(bin)));
    try s.tmp.dir.createDirPath(t.io, "bin/mnml-data");
    try t.expectEqual(PortableState.awaiting_consent, try portableState(t.allocator, t.io, s.env(bin)));
    // awaiting consent = NOT portable yet: still home
    const home_root = try dataRoot(t.allocator, t.io, s.env(bin));
    defer t.allocator.free(home_root);
    try sdk_testing.expectPath("/home/x/.config/mnml", home_root);

    try s.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/mnml-data/.opted-in", .data = "" });
    try t.expectEqual(PortableState.active, try portableState(t.allocator, t.io, s.env(bin)));
    try t.expectEqual(Kind.portable, try dataRootKind(t.allocator, t.io, s.env(bin)));
    const root = try dataRoot(t.allocator, t.io, s.env(bin));
    defer t.allocator.free(root);
    try expectPath(root, s.root, "bin/mnml-data");
    const cfg = (try homeConfigPath(t.allocator, t.io, s.env(bin))).?;
    defer t.allocator.free(cfg);
    try expectPath(cfg, s.root, "bin/mnml-data/config.zon");
}

test "XDG is used only when it has state; HOME with state wins; else XDG" {
    var s = try Sandbox.init();
    defer s.deinit();
    const xdg = try s.sub("xdg");
    defer t.allocator.free(xdg);
    const home = try s.sub("home");
    defer t.allocator.free(home);
    try s.vars.put("XDG_CONFIG_HOME", xdg);
    try s.vars.put("HOME", home);

    // neither has state → XDG path
    {
        const root = try dataRoot(t.allocator, t.io, s.env(null));
        defer t.allocator.free(root);
        try expectPath(root, s.root, "xdg/mnml");
    }
    // HOME has state, XDG does not → HOME
    try s.tmp.dir.createDirPath(t.io, "home/.config/mnml/integrations");
    {
        const root = try dataRoot(t.allocator, t.io, s.env(null));
        defer t.allocator.free(root);
        try expectPath(root, s.root, "home/.config/mnml");
    }
    // XDG has state → XDG
    try s.tmp.dir.createDirPath(t.io, "xdg/mnml");
    try s.tmp.dir.writeFile(t.io, .{ .sub_path = "xdg/mnml/config.zon", .data = ".{}" });
    {
        const root = try dataRoot(t.allocator, t.io, s.env(null));
        defer t.allocator.free(root);
        try expectPath(root, s.root, "xdg/mnml");
    }
    // the config path never probes: XDG set ⇒ XDG
    const cfg = (try homeConfigPath(t.allocator, t.io, s.env(null))).?;
    defer t.allocator.free(cfg);
    try expectPath(cfg, s.root, "xdg/mnml/config.zon");
}

test "no HOME at all falls back to ./mnml and no config path" {
    var s = try Sandbox.init();
    defer s.deinit();
    const root = try dataRoot(t.allocator, t.io, s.env(null));
    defer t.allocator.free(root);
    try t.expectEqualStrings("mnml", root);
    try t.expect((try homeConfigPath(t.allocator, t.io, s.env(null))) == null);
}

test "USERPROFILE is the home where HOME is not set" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.vars.put("USERPROFILE", "/Users/x");
    const root = try dataRoot(t.allocator, t.io, s.env(null));
    defer t.allocator.free(root);
    try expectPath(root, "/Users/x", ".config/mnml");
    const cfg = (try homeConfigPath(t.allocator, t.io, s.env(null))).?;
    defer t.allocator.free(cfg);
    try expectPath(cfg, "/Users/x", ".config/mnml/config.zon");
    // HOME wins when both are set (MSYS, Git Bash).
    try s.vars.put("HOME", "/home/x");
    const both = try dataRoot(t.allocator, t.io, s.env(null));
    defer t.allocator.free(both);
    try expectPath(both, "/home/x", ".config/mnml");
}

test "the dev profile is every rung of the ladder with -dev on the end" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.vars.put("MNML_PROFILE", "dev");

    // 5. no home at all
    {
        const root = try dataRoot(t.allocator, t.io, s.env(null));
        defer t.allocator.free(root);
        try t.expectEqualStrings("mnml-dev", root);
        try t.expect((try homeConfigPath(t.allocator, t.io, s.env(null))) == null);
    }
    // 4. HOME
    try s.vars.put("HOME", "/home/x");
    {
        const root = try dataRoot(t.allocator, t.io, s.env(null));
        defer t.allocator.free(root);
        try sdk_testing.expectPath("/home/x/.config/mnml-dev", root);
        const cfg = (try homeConfigPath(t.allocator, t.io, s.env(null))).?;
        defer t.allocator.free(cfg);
        try sdk_testing.expectPath("/home/x/.config/mnml-dev/config.zon", cfg);
    }
    // 3. XDG — and the state probes still run on the STABLE paths, so a
    // dev root that does not exist yet (it is about to be seeded) never
    // changes which rung was taken.
    const xdg = try s.sub("xdg");
    defer t.allocator.free(xdg);
    const home = try s.sub("home");
    defer t.allocator.free(home);
    try s.vars.put("XDG_CONFIG_HOME", xdg);
    try s.vars.put("HOME", home);
    try s.tmp.dir.createDirPath(t.io, "home/.config/mnml/integrations");
    {
        const root = try dataRoot(t.allocator, t.io, s.env(null));
        defer t.allocator.free(root);
        try expectPath(root, s.root, "home/.config/mnml-dev");
        const stable = try stableDataRoot(t.allocator, t.io, s.env(null));
        defer t.allocator.free(stable);
        try expectPath(stable, s.root, "home/.config/mnml");
    }
    // 2. portable
    const bin = try s.sub("bin");
    defer t.allocator.free(bin);
    try s.tmp.dir.createDirPath(t.io, "bin/mnml-data");
    try s.tmp.dir.writeFile(t.io, .{ .sub_path = "bin/mnml-data/.opted-in", .data = "" });
    {
        const root = try dataRoot(t.allocator, t.io, s.env(bin));
        defer t.allocator.free(root);
        try expectPath(root, s.root, "bin/mnml-data-dev");
        const cfg = (try homeConfigPath(t.allocator, t.io, s.env(bin))).?;
        defer t.allocator.free(cfg);
        try expectPath(cfg, s.root, "bin/mnml-data-dev/config.zon");
    }
    // 1. the explicit root is suffixed too: a private root stays private.
    try s.vars.put("MNML_DATA_ROOT", "/explicit/root");
    {
        const root = try dataRoot(t.allocator, t.io, s.env(bin));
        defer t.allocator.free(root);
        try sdk_testing.expectPath("/explicit/root-dev", root);
        const cfg = (try homeConfigPath(t.allocator, t.io, s.env(bin))).?;
        defer t.allocator.free(cfg);
        try sdk_testing.expectPath("/explicit/root-dev/config.zon", cfg);
        const stable = try stableDataRoot(t.allocator, t.io, s.env(bin));
        defer t.allocator.free(stable);
        try sdk_testing.expectPath("/explicit/root", stable);
    }
    // An unknown profile is the stable one, not a third root.
    try s.vars.put("MNML_PROFILE", "prod");
    const root = try dataRoot(t.allocator, t.io, s.env(bin));
    defer t.allocator.free(root);
    try sdk_testing.expectPath("/explicit/root", root);
}

test "an empty variable counts as unset" {
    var s = try Sandbox.init();
    defer s.deinit();
    try s.vars.put("MNML_DATA_ROOT", "");
    try s.vars.put("HOME", "/h");
    const root = try dataRoot(t.allocator, t.io, s.env(null));
    defer t.allocator.free(root);
    try sdk_testing.expectPath("/h/.config/mnml", root);
}
