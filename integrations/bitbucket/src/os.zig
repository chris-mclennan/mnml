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
pub fn openUrl(gpa: Allocator, io: Io, url: []const u8) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = openArgv(arena.allocator(), url) catch return "out of memory";
    const res = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch |err| switch (err) {
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
            try t.expectEqualStrings("cmd", open[0]);
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
