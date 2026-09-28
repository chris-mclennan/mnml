//! The two things the pane needs from the machine and cannot ask mnml
//! for: put a string on the clipboard, and open a URL.
//!
//! Bridge v2 has no message for either (`wire.SiblingMessage` is frames,
//! a title, a cursor, a toast, a command and `bye`), and an integration
//! must not write escape sequences — it does not own the terminal. So
//! both spawn the platform's own tool, and both report what happened so
//! the caller can toast the truth rather than a silent nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Outcome = union(enum) {
    ok: []const u8,
    /// Nothing on this machine could do it; the message says so.
    failed: []const u8,
};

/// The clipboard tool for this platform, argv-first.
pub fn clipboardArgv() []const []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => &.{"pbcopy"},
        .windows => &.{ "cmd", "/c", "clip" },
        // Wayland first: `xclip` on a Wayland session copies into an X
        // bridge that may not be running.
        else => &.{ "wl-copy", "--type", "text/plain" },
    };
}

/// The fallbacks to try when the first tool is not installed.
pub fn clipboardFallbacks() []const []const []const u8 {
    return switch (@import("builtin").os.tag) {
        .macos, .windows => &.{},
        else => &.{
            &.{ "xclip", "-selection", "clipboard" },
            &.{ "xsel", "--clipboard", "--input" },
        },
    };
}

/// Put `bytes` on the system clipboard.
pub fn copy(io: Io, bytes: []const u8) Outcome {
    if (feed(io, clipboardArgv(), bytes)) return .{ .ok = "copied" };
    for (clipboardFallbacks()) |argv| {
        if (feed(io, argv, bytes)) return .{ .ok = "copied" };
    }
    return .{ .failed = "no clipboard tool (install wl-copy, xclip or xsel)" };
}

fn feed(io: Io, argv: []const []const u8, bytes: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    if (child.stdin) |in| {
        var buf: [4096]u8 = undefined;
        var w: std.Io.File.Writer = .init(in, io, &buf);
        w.interface.writeAll(bytes) catch {};
        w.interface.flush() catch {};
        in.close(io);
        child.stdin = null;
    }
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// The opener for this platform, or the one the config named.
pub fn openArgv(arena: Allocator, configured: []const u8, url: []const u8) Allocator.Error![]const []const u8 {
    if (configured.len > 0) {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, configured, ' ');
        while (it.next()) |w| try argv.append(arena, w);
        try argv.append(arena, url);
        return argv.toOwnedSlice(arena);
    }
    // The SDK's opener (`sdk.platform`): Windows's arm never goes
    // through `cmd`, which would split the URL at its `&`.
    return @import("mnml_sdk").platform.openUrlArgv(arena, url, @import("builtin").os.tag);
}

/// Open `url` in whatever the machine calls a browser. Detached: the
/// pane must not wait on a browser starting up. `route` is
/// `$MNML_OPEN_URL` (`sdk.platform.divertOpenUrl`): `none` or a log
/// file, and no opener is started — the configured one included.
pub fn open(io: Io, arena: Allocator, configured: []const u8, route: ?[]const u8, url: []const u8) Outcome {
    if (!looksSafe(url)) return .{ .failed = "that is not an http(s) URL" };
    switch (@import("mnml_sdk").platform.divertOpenUrl(io, route, url)) {
        .spawn => {},
        .dropped, .logged => return .{ .ok = "opened" },
        .log_failed => return .{ .failed = "could not write the $MNML_OPEN_URL log" },
    }
    const argv = openArgv(arena, configured, url) catch return .{ .failed = "out of memory" };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return .{ .failed = "could not start the browser" };
    _ = child.wait(io) catch {};
    return .{ .ok = "opened" };
}

/// Only `http://` and `https://` are handed to a shell-adjacent opener,
/// so a URL out of a Jira field can never become `file://` or a flag.
pub fn looksSafe(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "-")) return false;
    return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "only an http(s) URL is ever handed to the opener" {
    try testing.expect(looksSafe("https://acme.atlassian.net/browse/ENG-1"));
    try testing.expect(looksSafe("http://127.0.0.1:8080/x"));
    try testing.expect(!looksSafe("file:///etc/passwd"));
    try testing.expect(!looksSafe("javascript:alert(1)"));
    try testing.expect(!looksSafe("--version"));
    try testing.expect(!looksSafe(""));
}

test "openArgv: the configured command takes the URL as its last argument" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const argv = try openArgv(a.allocator(), "firefox --new-tab", "https://x/y");
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings("firefox", argv[0]);
    try testing.expectEqualStrings("--new-tab", argv[1]);
    try testing.expectEqualStrings("https://x/y", argv[2]);
    // With nothing configured it is the platform's own opener, and the
    // URL is still the last word.
    const platform = try openArgv(a.allocator(), "", "https://x/y");
    try testing.expectEqualStrings("https://x/y", platform[platform.len - 1]);
}

test "the clipboard tool list has a first choice and, off macOS and Windows, fallbacks" {
    try testing.expect(clipboardArgv().len > 0);
    const tag = @import("builtin").os.tag;
    if (tag == .macos) {
        try testing.expectEqualStrings("pbcopy", clipboardArgv()[0]);
        try testing.expectEqual(@as(usize, 0), clipboardFallbacks().len);
    } else if (tag == .windows) {
        try testing.expectEqualStrings("cmd", clipboardArgv()[0]);
    } else {
        try testing.expectEqualStrings("wl-copy", clipboardArgv()[0]);
        try testing.expectEqual(@as(usize, 2), clipboardFallbacks().len);
    }
}

test "MNML_OPEN_URL set to a file: the URL lands there, even over a configured opener, and nothing starts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &root);
    const log = try std.fmt.allocPrint(testing.allocator, "{s}/opened-urls.log", .{root[0..n]});
    defer testing.allocator.free(log);
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    // A configured opener that does not exist: had it been started, the
    // outcome would be `.failed`.
    const missing = "mnml-jira-no-such-opener";
    try testing.expect(open(testing.io, a.allocator(), missing, null, "https://x.test/control") == .failed);
    try testing.expect(open(testing.io, a.allocator(), missing, log, "https://x.test/browse/ENG-1") == .ok);
    try testing.expect(open(testing.io, a.allocator(), missing, "none", "https://x.test/dropped") == .ok);
    const body = try tmp.dir.readFileAlloc(testing.io, "opened-urls.log", testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expect(std.mem.endsWith(u8, body, "\thttps://x.test/browse/ENG-1\n"));
    try testing.expect(std.mem.indexOf(u8, body, "dropped") == null);
}
