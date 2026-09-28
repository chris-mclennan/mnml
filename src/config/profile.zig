//! Which mnml this is: the one you live in, or the one you are working on.
//!
//! One machine runs two mnmls — the installed `mnml` you use all day and
//! the build in this repo. They must not share state, so a *profile*
//! picks every name that could collide:
//!
//!   |                | `stable` (the default) | `dev`                   |
//!   | data root      | `~/.config/mnml`       | `~/.config/mnml-dev`    |
//!   | session file   | `.mnml/session.zon`    | `.mnml/session-dev.zon` |
//!   | IPC mailbox    | `<ws>/.mnml/ipc`*      | `<ws>/.mnml/ipc-zig`    |
//!   | marker         | `mnml-running-…`*      | `mnml-zig-running-…`    |
//!   | statusline     | —                      | a `dev` chip            |
//!
//!   * the build decides: `-Dinstall-names` (what `run.sh install` and
//!     `zig build release` pass) names the stable profile the way a
//!     shipped mnml does; without it — this repo's own builds — the
//!     stable profile keeps the side-by-side names, so nothing in the
//!     dev tree moves and `MNML_PROFILE=dev` is still its own mailbox.
//!
//! The profile is read from the environment (`MNML_PROFILE=dev|stable`),
//! so it reaches everything that already has an env: the data-root
//! ladder, the App, and every integration the host spawns (they inherit
//! `MNML_DATA_ROOT`, which is already the profile's). `--profile dev` is
//! the flag spelling — `main` puts it in the environment, the way
//! `--startup-picker` does.
//!
//! The default is `stable`: a profile is a thing you ask for. `run.sh`
//! — the dev workflow — exports `MNML_PROFILE=dev` for you.
//!
//! What is deliberately NOT per-profile: the cross-process rate-limit
//! bucket in the shared-state directory
//! (`$MNML_SHARED_STATE_DIR/<service>-ratelimit.json`,
//! `sdk/mnml-sdk/src/ratelimit.zig`). It is one budget per machine, and
//! a second profile spending a second budget against the same API is
//! the bug, not the feature. With the variable unset the bucket falls
//! back under the data root, which is the profile's — set it to have
//! both profiles share one budget.

const std = @import("std");
const build_options = @import("build_options");

pub const Profile = enum {
    stable,
    dev,

    pub fn label(p: Profile) []const u8 {
        return @tagName(p);
    }
};

/// The environment variable, and the flag that writes it.
pub const env_var = "MNML_PROFILE";
pub const flag = "--profile";

/// What the dev profile appends to the stable data root.
pub const dev_suffix = "-dev";
/// The dev profile's IPC mailbox and marker, whatever the build named
/// the stable ones.
pub const dev_ipc_subdir = "ipc-zig";
pub const dev_marker_prefix = "mnml-zig-running-";

/// `stable` / `dev`, or null for anything else (an unknown value is not
/// silently a profile).
pub fn parse(name: []const u8) ?Profile {
    const trimmed = std.mem.trim(u8, name, " \t");
    if (std.mem.eql(u8, trimmed, "stable")) return .stable;
    if (std.mem.eql(u8, trimmed, "dev")) return .dev;
    return null;
}

/// The profile this environment asks for; `stable` when it asks for
/// nothing, or for something that is not a profile.
pub fn of(vars: *const std.process.Environ.Map) Profile {
    const v = vars.get(env_var) orelse return .stable;
    return parse(v) orelse .stable;
}

/// `--profile dev` / `--profile=dev` anywhere on the line: the value as
/// written (validated by the caller, which reports a bad one).
pub fn fromArgs(argv: []const [:0]const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, flag)) {
            if (i + 1 < argv.len) return argv[i + 1];
            return null;
        }
        if (std.mem.startsWith(u8, a, flag ++ "=")) return a[flag.len + 1 ..];
    }
    return null;
}

/// What the profile appends to the stable data root.
pub fn suffix(p: Profile) []const u8 {
    return switch (p) {
        .stable => "",
        .dev => dev_suffix,
    };
}

/// The IPC mailbox under `<workspace>/.mnml/`. `MNML_IPC_DIR` still
/// overrides it outright, for both profiles.
pub fn ipcSubdir(p: Profile) []const u8 {
    return pick(p, build_options.ipc_subdir, dev_ipc_subdir);
}

/// The running-instance marker's file-name prefix under `TMPDIR`.
pub fn markerPrefix(p: Profile) []const u8 {
    return pick(p, build_options.marker_prefix, dev_marker_prefix);
}

/// The rule the two above share, with the stable name as a value so a
/// test can pin it: the dev profile's name is its own whatever the
/// build called the stable one. In THIS repo's builds the two happen
/// to be equal (the tree keeps the side-by-side names for both), so a
/// test that compared them against `build_options` would pass however
/// this was written — hence the parameter.
pub fn pick(p: Profile, stable_name: []const u8, dev_name: []const u8) []const u8 {
    return switch (p) {
        .stable => stable_name,
        .dev => dev_name,
    };
}

/// The chip the statusline paints and the tag the window title carries;
/// empty for the profile you are meant to forget you are in.
pub fn tag(p: Profile) []const u8 {
    return switch (p) {
        .stable => "",
        .dev => "dev",
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the names are stable unless the environment says dev" {
    var vars: std.process.Environ.Map = .init(t.allocator);
    defer vars.deinit();
    try t.expectEqual(Profile.stable, of(&vars));
    try t.expectEqualStrings("", suffix(of(&vars)));
    try t.expectEqualStrings("", tag(of(&vars)));

    try vars.put(env_var, "dev");
    try t.expectEqual(Profile.dev, of(&vars));
    try t.expectEqualStrings("-dev", suffix(of(&vars)));
    try t.expectEqualStrings("dev", tag(of(&vars)));
    try t.expectEqualStrings(dev_ipc_subdir, ipcSubdir(.dev));
    try t.expectEqualStrings(dev_marker_prefix, markerPrefix(.dev));

    try vars.put(env_var, "stable");
    try t.expectEqual(Profile.stable, of(&vars));
    // Neither an empty value nor a typo is a profile.
    try vars.put(env_var, "");
    try t.expectEqual(Profile.stable, of(&vars));
    try vars.put(env_var, "DEV");
    try t.expectEqual(Profile.stable, of(&vars));
    try vars.put(env_var, "development");
    try t.expectEqual(Profile.stable, of(&vars));
}

test "parse takes the two names and nothing else" {
    try t.expectEqual(Profile.stable, parse("stable").?);
    try t.expectEqual(Profile.dev, parse("dev").?);
    try t.expectEqual(Profile.dev, parse(" dev ").?);
    try t.expect(parse("") == null);
    try t.expect(parse("prod") == null);
}

test "--profile is read as a value or with an equals sign" {
    try t.expectEqualStrings("dev", fromArgs(&.{ "mnml", "--profile", "dev" }).?);
    try t.expectEqualStrings("stable", fromArgs(&.{ "mnml", "--profile=stable", "/ws" }).?);
    try t.expect(fromArgs(&.{ "mnml", "/ws" }) == null);
    // A trailing `--profile` with nothing after it is not a value.
    try t.expect(fromArgs(&.{ "mnml", "--profile" }) == null);
}

test "the stable names are the build's; dev's are its own either way" {
    // This repo's own build has no `-Dinstall-names`, so both profiles
    // keep the side-by-side names and comparing them here would prove
    // nothing. `pick` takes the stable name as a value, so the split
    // can be pinned as an installed build would see it:
    try t.expectEqualStrings("ipc", pick(.stable, "ipc", dev_ipc_subdir));
    try t.expectEqualStrings("ipc-zig", pick(.dev, "ipc", dev_ipc_subdir));
    try t.expectEqualStrings("mnml-running-", pick(.stable, "mnml-running-", dev_marker_prefix));
    try t.expectEqualStrings("mnml-zig-running-", pick(.dev, "mnml-running-", dev_marker_prefix));
    // And the wiring: the stable name comes from the build, the dev
    // name never does.
    try t.expectEqualStrings(build_options.ipc_subdir, ipcSubdir(.stable));
    try t.expectEqualStrings(build_options.marker_prefix, markerPrefix(.stable));
    try t.expectEqualStrings(dev_ipc_subdir, ipcSubdir(.dev));
    try t.expectEqualStrings(dev_marker_prefix, markerPrefix(.dev));
}
