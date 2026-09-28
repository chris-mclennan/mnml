//! The platform's own URL opener, for an integration that has to open a
//! browser itself (Bridge v2 has no message for it). One definition, so
//! the integrations cannot drift apart on the Windows arm.
//!
//! Windows goes through `rundll32 url.dll,FileProtocolHandler`, not
//! `cmd /c start`: `cmd` re-parses its command line, so the `&` in
//! `?a=1&b=2` ended the command there — and a URL out of a ticket or a
//! pull request could name a second command to run. `rundll32` hands
//! the rest of its command line to the shell's URL handler as is; only
//! the characters that would make the argv step quote the argument
//! (space, tab, `"`) are percent-encoded, since a quoted argument's
//! quotes would reach the handler as part of the URL.
//!
//! `MNML_OPEN_URL` decides whether a URL reaches a browser at all
//! (`openUrlRoute`): unset or empty opens it; `none` drops it; any other
//! value is a file the URL is appended to instead. Every opener in the
//! host and the integrations asks it first, so a test run, a headless
//! host or a scripted window never puts a page in front of a person.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The variable every opener consults before it spawns one.
pub const open_url_env = "MNML_OPEN_URL";

/// What an opener does with a URL.
pub const OpenUrlRoute = union(enum) {
    /// Hand it to the browser.
    spawn,
    /// Drop it: no process, no file.
    none,
    /// Append `<epoch seconds>\t<url>\n` to this file (`logOpenedUrl`),
    /// spawn nothing.
    log: []const u8,
};

/// `MNML_OPEN_URL`'s value, read as a route. Unset and empty both mean
/// open normally — empty is what a `KEY=` line leaves, and it must not
/// name a file called "".
pub fn openUrlRoute(value: ?[]const u8) OpenUrlRoute {
    const v = value orelse return .spawn;
    if (v.len == 0) return .spawn;
    if (std.mem.eql(u8, v, "none")) return .none;
    return .{ .log = v };
}

/// `openUrlRoute` over an environment map.
pub fn openUrlRouteFrom(env: *const std.process.Environ.Map) OpenUrlRoute {
    return openUrlRoute(env.get(open_url_env));
}

/// What `divertOpenUrl` did with a URL.
pub const Diverted = enum {
    /// Nothing: the caller spawns its opener.
    spawn,
    /// `none`: dropped.
    dropped,
    /// Written to the log file.
    logged,
    /// The log file could not be written. Still no spawn — the variable
    /// said no browser, and a full disk does not change that.
    log_failed,
};

/// The step every opener takes before it spawns one: act on
/// `MNML_OPEN_URL`'s value (`env_value`) for `url`. Only `.spawn` lets
/// the caller go on to the browser.
pub fn divertOpenUrl(io: Io, env_value: ?[]const u8, url: []const u8) Diverted {
    return switch (openUrlRoute(env_value)) {
        .spawn => .spawn,
        .none => .dropped,
        .log => |path| if (logOpenedUrl(io, path, url)) .logged else |_| .log_failed,
    };
}

/// Append `<epoch seconds>\t<url>\n` to `path`, creating it. Locked, so
/// the host and an integration logging at once never interleave.
pub fn logOpenedUrl(io: Io, path: []const u8, url: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false, .lock = .exclusive });
    defer file.close(io);
    var buf: [32]u8 = undefined;
    const secs = @divFloor(Io.Timestamp.now(io, .real).toMilliseconds(), 1000);
    const stamp = std.fmt.bufPrint(&buf, "{d}\t", .{secs}) catch unreachable;
    var end = try file.length(io);
    try file.writePositionalAll(io, stamp, end);
    end += stamp.len;
    try file.writePositionalAll(io, url, end);
    end += url.len;
    try file.writePositionalAll(io, "\n", end);
}

/// The argv that opens `url` on `os`, URL last.
pub fn openUrlArgv(arena: Allocator, url: []const u8, os: std.Target.Os.Tag) Allocator.Error![]const []const u8 {
    return switch (os) {
        .macos => try arena.dupe([]const u8, &.{ "open", url }),
        .windows => try arena.dupe([]const u8, &.{ "rundll32", "url.dll,FileProtocolHandler", try windowsUrlArg(arena, url) }),
        else => try arena.dupe([]const u8, &.{ "xdg-open", url }),
    };
}

/// `url` with space, tab and `"` percent-encoded; `url` itself when it
/// has none.
pub fn windowsUrlArg(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, url, " \t\"") == null) return url;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (url) |c| switch (c) {
        ' ' => try out.appendSlice(arena, "%20"),
        '\t' => try out.appendSlice(arena, "%09"),
        '"' => try out.appendSlice(arena, "%22"),
        else => try out.append(arena, c),
    };
    return out.items;
}

test "openUrlArgv: Windows never goes through cmd, and the URL is one unquoted argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const url = "https://x.test/a b?q=\"1\"&r=2|x";
    const win = try openUrlArgv(a, url, .windows);
    try std.testing.expectEqual(@as(usize, 3), win.len);
    try std.testing.expectEqualStrings("rundll32", win[0]);
    try std.testing.expectEqualStrings("https://x.test/a%20b?q=%221%22&r=2|x", win[2]);
    for (win) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "cmd"));
    try std.testing.expectEqualStrings("open", (try openUrlArgv(a, url, .macos))[0]);
    const lin = try openUrlArgv(a, url, .linux);
    try std.testing.expectEqualStrings("xdg-open", lin[0]);
    try std.testing.expectEqualStrings(url, lin[1]);
    const plain = "https://x.test/p";
    try std.testing.expect((try windowsUrlArg(a, plain)).ptr == plain.ptr);
}

test "openUrlRoute: unset or empty spawns, none drops, anything else is a log file" {
    try std.testing.expectEqual(OpenUrlRoute.spawn, openUrlRoute(null));
    try std.testing.expectEqual(OpenUrlRoute.spawn, openUrlRoute(""));
    try std.testing.expectEqual(OpenUrlRoute.none, openUrlRoute("none"));
    // Only the exact word: a path that happens to contain it is a path.
    try std.testing.expectEqualStrings("/tmp/none", openUrlRoute("/tmp/none").log);
    try std.testing.expectEqualStrings("opened-urls.log", openUrlRoute("opened-urls.log").log);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(OpenUrlRoute.spawn, openUrlRouteFrom(&env));
    try env.put(open_url_env, "none");
    try std.testing.expectEqual(OpenUrlRoute.none, openUrlRouteFrom(&env));
}

test "logOpenedUrl creates the file and appends one tab-separated line per URL" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &root);
    const path = try std.fmt.allocPrint(t.allocator, "{s}/opened-urls.log", .{root[0..n]});
    defer t.allocator.free(path);
    try logOpenedUrl(t.io, path, "https://x.test/a?b=1&c=2");
    try logOpenedUrl(t.io, path, "https://x.test/second");
    const body = try tmp.dir.readFileAlloc(t.io, "opened-urls.log", t.allocator, .unlimited);
    defer t.allocator.free(body);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, body, "\n"), '\n');
    const urls = [_][]const u8{ "https://x.test/a?b=1&c=2", "https://x.test/second" };
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.NoTab;
        _ = try std.fmt.parseInt(i64, line[0..tab], 10);
        try t.expectEqualStrings(urls[count], line[tab + 1 ..]);
    }
    try t.expectEqual(@as(usize, 2), count);
    // Through `divertOpenUrl`: the log route writes, `none` does not,
    // and neither is `.spawn`.
    try t.expectEqual(Diverted.logged, divertOpenUrl(t.io, path, "https://x.test/third"));
    try t.expectEqual(Diverted.dropped, divertOpenUrl(t.io, "none", "https://x.test/never"));
    try t.expectEqual(Diverted.spawn, divertOpenUrl(t.io, null, "https://x.test/never"));
    const after = try tmp.dir.readFileAlloc(t.io, "opened-urls.log", t.allocator, .unlimited);
    defer t.allocator.free(after);
    try t.expect(std.mem.indexOf(u8, after, "\thttps://x.test/third\n") != null);
    try t.expect(std.mem.indexOf(u8, after, "never") == null);
    // A path that cannot be written is a failure to report, not a spawn.
    const bad = try std.fmt.allocPrint(t.allocator, "{s}/no/such/dir/x.log", .{root[0..n]});
    defer t.allocator.free(bad);
    try t.expectEqual(Diverted.log_failed, divertOpenUrl(t.io, bad, "https://x.test/y"));
}
