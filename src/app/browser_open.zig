//! Handing a URL to a browser. `ui.external_browser` names an
//! application to use instead of the OS default — the trust layer
//! strips the key from an untrusted workspace's config before it is
//! read here (`src/config/trust.zig`), so a repo cannot pick your
//! browser for you. macOS opens by app name (`open -a`), Windows
//! through `start`, elsewhere the name is the program on PATH.
//!
//! Windows's default goes through `rundll32 url.dll,FileProtocolHandler`,
//! not `cmd /c start`: `cmd` re-parses its command line, so the `&` in
//! `?a=1&b=2` ended the command there — and a URL out of a ticket or a
//! pull request could name a second command to run. A named browser
//! still needs `start` (it resolves `msedge` / `chrome` through App
//! Paths), so its URL has every `cmd` metacharacter caret-escaped.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;

/// Whether `url` stops short of a browser: `$MNML_OPEN_URL` in the
/// app's environment (`mnml_sdk.platform.divertOpenUrl`) — `none` drops
/// it, a path logs it there. Every spawning opener asks this first; true
/// means spawn nothing. A log that could not be written is toasted, and
/// still spawns nothing.
pub fn diverted(app: *App, url: []const u8) bool {
    const platform = @import("mnml_sdk").platform;
    return switch (platform.divertOpenUrl(app.io, app.env.get(platform.open_url_env), url)) {
        .spawn => false,
        .dropped, .logged => true,
        .log_failed => blk: {
            app.toast("could not write the $MNML_OPEN_URL log for {s}", .{url});
            break :blk true;
        },
    };
}

/// The argv that opens `url`: the configured browser, else the OS default.
pub fn argv(app: *const App, arena: Allocator, url: []const u8) Allocator.Error![]const []const u8 {
    return argvFor(arena, std.mem.trim(u8, app.cfg.ui.external_browser, " \t"), url, builtin.os.tag);
}

pub fn argvFor(arena: Allocator, browser: []const u8, url: []const u8, os: std.Target.Os.Tag) Allocator.Error![]const []const u8 {
    if (browser.len == 0) {
        return switch (os) {
            .macos => try arena.dupe([]const u8, &.{ "open", url }),
            .windows => try arena.dupe([]const u8, &.{ "rundll32", "url.dll,FileProtocolHandler", try windowsUrlArg(arena, url) }),
            else => try arena.dupe([]const u8, &.{ "xdg-open", url }),
        };
    }
    return switch (os) {
        .macos => try arena.dupe([]const u8, &.{ "open", "-a", browser, url }),
        .windows => try arena.dupe([]const u8, &.{ "cmd", "/c", "start", "", browser, try cmdEscape(arena, try windowsUrlArg(arena, url)) }),
        else => try arena.dupe([]const u8, &.{ browser, url }),
    };
}

/// `url` with space, tab and `"` percent-encoded, so the argv-to-command
/// line step never wraps it in quotes: `cmd` and `rundll32` both take a
/// quoted argument's quotes literally.
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

/// `s` with each character `cmd.exe` treats specially outside quotes
/// preceded by `^`, so `cmd /c start "" browser <s>` hands `s` on as
/// one literal argument. `%` too: `^%` stops `%VAR%` expansion.
pub fn cmdEscape(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const meta = "^&|<>()%!";
    if (std.mem.indexOfAny(u8, s, meta) == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (std.mem.indexOfScalar(u8, meta, c) != null) try out.append(arena, '^');
        try out.append(arena, c);
    }
    return out.items;
}

test "external_browser picks the application; empty is the OS default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dflt = try argvFor(a, "", "https://x.test/", .macos);
    try std.testing.expectEqualStrings("open", dflt[0]);
    try std.testing.expectEqual(@as(usize, 2), dflt.len);
    const mac = try argvFor(a, "Google Chrome", "https://x.test/", .macos);
    try std.testing.expectEqualStrings("-a", mac[1]);
    try std.testing.expectEqualStrings("Google Chrome", mac[2]);
    try std.testing.expectEqualStrings("https://x.test/", mac[3]);
    const lin = try argvFor(a, "firefox", "https://x.test/", .linux);
    try std.testing.expectEqualStrings("firefox", lin[0]);
    const win = try argvFor(a, "msedge", "https://x.test/", .windows);
    try std.testing.expectEqualStrings("start", win[2]);
    try std.testing.expectEqualStrings("msedge", win[4]);
    const win_default = try argvFor(a, "", "https://x.test/", .windows);
    try std.testing.expectEqualStrings("rundll32", win_default[0]);
    try std.testing.expectEqualStrings("https://x.test/", win_default[2]);
    // Through the app: the config field drives it.
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    app.cfg.ui.external_browser = "Firefox";
    const via = try argv(&app, a, "https://y.test/");
    try std.testing.expect(std.mem.indexOf(u8, via[via.len - 2], "Firefox") != null or std.mem.eql(u8, via[0], "Firefox"));
}

test "a Windows URL reaches the browser whole: no cmd metacharacter survives unescaped, no space forces quotes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const url = "https://x.test/a b?q=\"1\"&r=%41|(x)";
    // The default never goes through cmd: only the quoting-forcing
    // characters change.
    const dflt = try argvFor(a, "", url, .windows);
    try std.testing.expectEqualStrings("https://x.test/a%20b?q=%221%22&r=%41|(x)", dflt[2]);
    // A named browser does: every metacharacter is caret-escaped.
    const named = try argvFor(a, "msedge", url, .windows);
    try std.testing.expectEqualStrings("https://x.test/a^%20b?q=^%221^%22^&r=^%41^|^(x^)", named[5]);
    // Nothing to escape: the URL itself, unchanged and unallocated.
    const plain = "https://x.test/p";
    try std.testing.expect((try cmdEscape(a, plain)).ptr == plain.ptr);
    try std.testing.expect((try windowsUrlArg(a, plain)).ptr == plain.ptr);
    // Other platforms never see the escaping.
    try std.testing.expectEqualStrings(url, (try argvFor(a, "", url, .linux))[1]);
}

test "MNML_OPEN_URL diverts the app's openers: a log path gets the line, none drops it, unset spawns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &root);
    const log = try std.fmt.allocPrint(std.testing.allocator, "{s}/opened-urls.log", .{root[0..n]});
    defer std.testing.allocator.free(log);
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    _ = app.env.swapRemove("MNML_OPEN_URL");
    try std.testing.expect(!diverted(&app, "https://x.test/spawned"));
    try app.env.put("MNML_OPEN_URL", log);
    try std.testing.expect(diverted(&app, "https://x.test/logged"));
    // Through the real opener: `git.openExternal` writes the line and
    // starts nothing.
    @import("git.zig").openExternal(&app, "https://x.test/through-git");
    try app.env.put("MNML_OPEN_URL", "none");
    try std.testing.expect(diverted(&app, "https://x.test/dropped"));
    const body = try tmp.dir.readFileAlloc(std.testing.io, "opened-urls.log", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\thttps://x.test/logged\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\thttps://x.test/through-git\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "dropped") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "spawned") == null);
}
