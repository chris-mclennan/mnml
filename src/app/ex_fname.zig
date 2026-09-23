//! The filename specials in an ex command's file argument (`:help
//! cmdline-special`): `%` is the current file, `#` the alternate one,
//! `<cfile>` the file name under the cursor, each followed by any of the
//! modifiers `:p` (full path), `:h` (head), `:t` (tail), `:r` (root) and
//! `:e` (extension) (`:help filename-modifiers`). `\%` / `\#` are the
//! characters themselves. So `:w %.bak`, `:e %:h/other.zig` and `:e#`
//! mean what a vim user types them for, and never make files named `%`
//! or `#`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Names = struct {
    /// The current file, as the `:` line shows it (workspace-relative).
    current: ?[]const u8,
    alternate: ?[]const u8,
    /// Under the cursor, when the line asks for `<cfile>`.
    cfile: ?[]const u8 = null,
    /// What `:p` prefixes a relative name with.
    workspace: []const u8 = "",
};

pub const Error = Allocator.Error || error{ NoFileName, NoAlternate, NoCfile };

/// `arg` with its specials expanded, on `arena`.
pub fn expand(arena: Allocator, arg: []const u8, n: Names) Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < arg.len) {
        const c = arg[i];
        if (c == '\\' and i + 1 < arg.len and (arg[i + 1] == '%' or arg[i + 1] == '#')) {
            try out.append(arena, arg[i + 1]);
            i += 2;
            continue;
        }
        var name: ?[]const u8 = null;
        if (c == '%') {
            name = n.current orelse return error.NoFileName;
            i += 1;
        } else if (c == '#') {
            name = n.alternate orelse return error.NoAlternate;
            i += 1;
        } else if (std.mem.startsWith(u8, arg[i..], "<cfile>")) {
            name = n.cfile orelse return error.NoCfile;
            i += "<cfile>".len;
        }
        const base = name orelse {
            try out.append(arena, c);
            i += 1;
            continue;
        };
        var cur: []const u8 = base;
        while (i + 1 < arg.len and arg[i] == ':') {
            switch (arg[i + 1]) {
                'p' => {
                    if (!std.fs.path.isAbsolute(cur) and n.workspace.len > 0) cur = try std.fs.path.join(arena, &.{ n.workspace, cur });
                },
                'h' => cur = std.fs.path.dirname(cur) orelse ".",
                't' => cur = std.fs.path.basename(cur),
                'r' => {
                    const ext = std.fs.path.extension(cur);
                    cur = cur[0 .. cur.len - ext.len];
                },
                'e' => {
                    const ext = std.fs.path.extension(cur);
                    cur = if (ext.len > 0) ext[1..] else "";
                },
                else => break,
            }
            i += 2;
        }
        try out.appendSlice(arena, cur);
    }
    return out.items;
}

/// vim's `isfname`: the characters a file name under the cursor is
/// made of (`<cfile>`, `gf`).
pub fn isFnameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80 or switch (c) {
        '/', '.', '-', '_', '+', ',', '#', '$', '%', '~', '=' => true,
        else => false,
    };
}

/// The file name around byte `at` of `text`, or null.
pub fn nameAt(text: []const u8, at: usize) ?[]const u8 {
    if (text.len == 0) return null;
    var s = @min(at, text.len - 1);
    if (!isFnameChar(text[s])) return null;
    var e = s;
    while (s > 0 and isFnameChar(text[s - 1])) s -= 1;
    while (e < text.len and isFnameChar(text[e])) e += 1;
    return text[s..e];
}

test "% # and <cfile> expand with their modifiers; \\% is a percent; a missing name is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const n: Names = .{ .current = "sub/a.txt", .alternate = "b.txt", .cfile = "src/x.zig", .workspace = "/w" };
    try std.testing.expectEqualStrings("sub/a.txt.bak", try expand(a, "%.bak", n));
    try std.testing.expectEqualStrings("sub/b.txt", try expand(a, "%:h/b.txt", n));
    try std.testing.expectEqualStrings("b.txt", try expand(a, "#", n));
    try std.testing.expectEqualStrings("a", try expand(a, "%:t:r", n));
    try std.testing.expectEqualStrings("txt", try expand(a, "%:e", n));
    try std.testing.expectEqualStrings("/w/sub/a.txt", try expand(a, "%:p", n));
    try std.testing.expectEqualStrings("src/x.zig", try expand(a, "<cfile>", n));
    try std.testing.expectEqualStrings("50%off #1", try expand(a, "50\\%off \\#1", n));
    try std.testing.expectEqualStrings("plain.txt", try expand(a, "plain.txt", n));
    try std.testing.expectError(error.NoAlternate, expand(a, "#", .{ .current = "a", .alternate = null }));
    try std.testing.expectError(error.NoFileName, expand(a, "%", .{ .current = null, .alternate = null }));
    try std.testing.expectEqualStrings("src/x.zig", nameAt("see src/x.zig here", 6).?);
    try std.testing.expect(nameAt("a  b", 1) == null);
}
