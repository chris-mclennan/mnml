//! Handing a URL to a browser. `ui.external_browser` names an
//! application to use instead of the OS default — the trust layer
//! strips the key from an untrusted workspace's config before it is
//! read here (`src/config/trust.zig`), so a repo cannot pick your
//! browser for you. macOS opens by app name (`open -a`), Windows
//! through `start`, elsewhere the name is the program on PATH.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;

/// The argv that opens `url`: the configured browser, else the OS default.
pub fn argv(app: *const App, arena: Allocator, url: []const u8) Allocator.Error![]const []const u8 {
    return argvFor(arena, std.mem.trim(u8, app.cfg.ui.external_browser, " \t"), url, builtin.os.tag);
}

pub fn argvFor(arena: Allocator, browser: []const u8, url: []const u8, os: std.Target.Os.Tag) Allocator.Error![]const []const u8 {
    if (browser.len == 0) {
        return switch (os) {
            .macos => try arena.dupe([]const u8, &.{ "open", url }),
            .windows => try arena.dupe([]const u8, &.{ "cmd", "/c", "start", "", url }),
            else => try arena.dupe([]const u8, &.{ "xdg-open", url }),
        };
    }
    return switch (os) {
        .macos => try arena.dupe([]const u8, &.{ "open", "-a", browser, url }),
        .windows => try arena.dupe([]const u8, &.{ "cmd", "/c", "start", "", browser, url }),
        else => try arena.dupe([]const u8, &.{ browser, url }),
    };
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
    // Through the app: the config field drives it.
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp" });
    defer app.deinit();
    app.cfg.ui.external_browser = "Firefox";
    const via = try argv(&app, a, "https://y.test/");
    try std.testing.expect(std.mem.indexOf(u8, via[via.len - 2], "Firefox") != null or std.mem.eql(u8, via[0], "Firefox"));
}
