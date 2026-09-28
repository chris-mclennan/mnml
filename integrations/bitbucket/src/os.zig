//! The two things the pane needs from the machine and cannot ask mnml
//! for: open a URL in a browser, and put text on the clipboard. Both
//! shell out to whatever the platform ships, both are best-effort, and
//! both report the reason rather than failing silently — a `y` that
//! quietly does nothing is worse than one that says `xclip: not found`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");

/// The argv that opens a URL on this platform, with the URL appended.
/// The SDK's (`sdk.platform`): Windows's arm never goes through `cmd`.
pub fn openArgv(arena: Allocator, url: []const u8) Allocator.Error![]const []const u8 {
    return @import("mnml_sdk").platform.openUrlArgv(arena, url, builtin.os.tag);
}

/// The argv that reads the clipboard text from stdin.
pub fn copyArgv(arena: Allocator, wayland: bool) Allocator.Error![]const []const u8 {
    return switch (builtin.os.tag) {
        .macos => try arena.dupe([]const u8, &.{"pbcopy"}),
        .windows => try arena.dupe([]const u8, &.{"clip"}),
        else => if (wayland)
            try arena.dupe([]const u8, &.{"wl-copy"})
        else
            try arena.dupe([]const u8, &.{ "xclip", "-selection", "clipboard" }),
    };
}

/// Open `url`. The error is the tool's name and what went wrong.
/// `MNML_OPEN_URL` in `env` comes first (`sdk.platform.divertOpenUrl`):
/// `none` or a log file, and no opener is started.
pub fn openUrl(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, url: []const u8) ?[]const u8 {
    return openUrlVia(gpa, io, env, url, openArgv);
}

/// `openUrl` with the argv it would start named by `argvFn` — a test's
/// stand-in, so proving no opener started never needs a real one.
fn openUrlVia(
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    url: []const u8,
    comptime argvFn: fn (Allocator, []const u8) Allocator.Error![]const []const u8,
) ?[]const u8 {
    const platform = @import("mnml_sdk").platform;
    switch (platform.divertOpenUrl(io, env.get(platform.open_url_env), url)) {
        .spawn => {},
        .dropped, .logged => return null,
        .log_failed => return "could not write the $MNML_OPEN_URL log",
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = argvFn(arena.allocator(), url) catch return "out of memory";
    const res = std.process.run(gpa, io, .{ .argv = argv, .environ_map = env, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch |err| switch (err) {
        error.FileNotFound => return "no browser opener on PATH",
        else => return @errorName(err),
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |c| if (c == 0) null else "the browser opener exited non-zero",
        else => "the browser opener was signalled",
    };
}

/// Put `text` on the clipboard.
pub fn copy(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, text: []const u8) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const wayland = if (env.get("WAYLAND_DISPLAY")) |v| v.len > 0 else false;
    const argv = copyArgv(arena.allocator(), wayland) catch return "out of memory";
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return "no clipboard tool on PATH",
        else => return @errorName(err),
    };
    if (child.stdin) |in| {
        var buf: [4096]u8 = undefined;
        var w = in.writer(io, &buf);
        w.interface.writeAll(text) catch {};
        w.interface.flush() catch {};
        in.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch |err| return @errorName(err);
    return switch (term) {
        .exited => |c| if (c == 0) null else "the clipboard tool exited non-zero",
        else => "the clipboard tool was signalled",
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the opener and the clipboard tool are the platform's own" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const open = try openArgv(a, "https://example.com");
    try t.expectEqualStrings("https://example.com", open[open.len - 1]);
    switch (builtin.os.tag) {
        .macos => {
            try t.expectEqualStrings("open", open[0]);
            try t.expectEqualStrings("pbcopy", (try copyArgv(a, false))[0]);
        },
        .windows => {
            try t.expectEqualStrings("rundll32", open[0]);
            try t.expectEqualStrings("clip", (try copyArgv(a, false))[0]);
        },
        else => {
            try t.expectEqualStrings("xdg-open", open[0]);
            try t.expectEqualStrings("xclip", (try copyArgv(a, false))[0]);
            try t.expectEqualStrings("wl-copy", (try copyArgv(a, true))[0]);
        },
    }
}

test "a missing tool is a reason, not a crash" {
    // Nothing named this exists, so the spawn fails the way a machine
    // without `xdg-open` does.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const res = std.process.run(t.allocator, t.io, .{ .argv = &.{"mnml-bitbucket-no-such-tool"} }) catch |err| {
        try t.expect(err == error.FileNotFound or err == error.AccessDenied);
        return;
    };
    t.allocator.free(res.stdout);
    t.allocator.free(res.stderr);
}

test "MNML_OPEN_URL set to a file: the URL lands there and no opener is started" {
    // The opener is a program that does not exist: had one been
    // started, `openUrlVia` would say it was not found. The real
    // `open` / `xdg-open` never runs in this test.
    const Missing = struct {
        fn argv(arena: Allocator, url: []const u8) Allocator.Error![]const []const u8 {
            return arena.dupe([]const u8, &.{ "mnml-bitbucket-no-such-opener", url });
        }
    };
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &root);
    const log = try std.fmt.allocPrint(t.allocator, "{s}/opened-urls.log", .{root[0..n]});
    defer t.allocator.free(log);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    // The control: unset, it does try to start the opener.
    try t.expect(openUrlVia(t.allocator, t.io, &env, "https://x.test/control", Missing.argv) != null);
    try env.put("MNML_OPEN_URL", log);
    try t.expectEqual(@as(?[]const u8, null), openUrlVia(t.allocator, t.io, &env, "https://x.test/acme/api/pipelines", Missing.argv));
    const body = try tmp.dir.readFileAlloc(t.io, "opened-urls.log", t.allocator, .unlimited);
    defer t.allocator.free(body);
    try t.expect(std.mem.endsWith(u8, body, "\thttps://x.test/acme/api/pipelines\n"));
    try t.expect(std.mem.indexOf(u8, body, "control") == null);
    // `none`: nothing written, nothing started.
    try env.put("MNML_OPEN_URL", "none");
    try t.expectEqual(@as(?[]const u8, null), openUrlVia(t.allocator, t.io, &env, "https://x.test/dropped", Missing.argv));
    const again = try tmp.dir.readFileAlloc(t.io, "opened-urls.log", t.allocator, .unlimited);
    defer t.allocator.free(again);
    try t.expectEqualStrings(body, again);
}
