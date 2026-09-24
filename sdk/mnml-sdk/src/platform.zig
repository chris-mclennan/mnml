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

const std = @import("std");
const Allocator = std.mem.Allocator;

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
