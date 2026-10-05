//! The file glyph beside a name — the statusline's file chip paints the
//! devicon for the open file in that language's colour, the way the
//! Rust editor's `icons::for_path` did. A small table of the common
//! types; a name the table does not know gets the plain file glyph.
//!
//! // changed: the tree track is building the full icon table as
//! `src/ui/icons.zig`; this lookup is the statusline's slice of it and
//! folds into that module when the two land — same codepoints, same
//! colours, so the merge is a delete here and an import there.

const std = @import("std");
const Theme = @import("theme.zig");
const repeat = @import("mnml_sdk").zig_compat.repeat;

pub const Glyph = struct {
    /// The nerd-font glyph.
    glyph: []const u8,
    /// Its `--ascii` twin.
    fallback: []const u8,
    color: Theme.Color,
};

const Row = struct { key: []const u8, glyph: []const u8, fallback: []const u8, color: u24 };

/// Whole file names (lower-cased) that outrank their extension.
const by_name = [_]Row{
    .{ .key = "package.json", .glyph = "\u{e71e}", .fallback = "n", .color = 0xe8274b },
    .{ .key = "package-lock.json", .glyph = "\u{e71e}", .fallback = "n", .color = 0x7a0d21 },
    .{ .key = "tsconfig.json", .glyph = "\u{e69d}", .fallback = "t", .color = 0x519aba },
    .{ .key = ".gitignore", .glyph = "\u{e702}", .fallback = "g", .color = 0xf54d27 },
    .{ .key = ".gitattributes", .glyph = "\u{e702}", .fallback = "g", .color = 0xf54d27 },
    .{ .key = ".editorconfig", .glyph = "\u{e652}", .fallback = "e", .color = 0xfff2f2 },
    .{ .key = "dockerfile", .glyph = "\u{f0868}", .fallback = "d", .color = 0x458ee6 },
    .{ .key = "readme", .glyph = "\u{f00ba}", .fallback = "r", .color = 0xededed },
    .{ .key = "readme.md", .glyph = "\u{f00ba}", .fallback = "r", .color = 0xededed },
    .{ .key = "license", .glyph = "\u{e60a}", .fallback = "l", .color = 0xd0bf41 },
    .{ .key = "makefile", .glyph = "\u{e779}", .fallback = "m", .color = 0x6d8086 },
};

/// Extensions (lower-cased, no dot).
const by_ext = [_]Row{
    .{ .key = "ts", .glyph = "\u{e628}", .fallback = "t", .color = 0x519aba },
    .{ .key = "tsx", .glyph = "\u{e7ba}", .fallback = "t", .color = 0x1354bf },
    .{ .key = "js", .glyph = "\u{e60c}", .fallback = "j", .color = 0xcbcb41 },
    .{ .key = "cjs", .glyph = "\u{e60c}", .fallback = "j", .color = 0xcbcb41 },
    .{ .key = "mjs", .glyph = "\u{e60c}", .fallback = "j", .color = 0xf1e05a },
    .{ .key = "jsx", .glyph = "\u{e625}", .fallback = "j", .color = 0x20c2e3 },
    .{ .key = "rs", .glyph = "\u{e68b}", .fallback = "r", .color = 0xdea584 },
    .{ .key = "zig", .glyph = "\u{e6a9}", .fallback = "z", .color = 0xf7a41d },
    .{ .key = "cs", .glyph = "\u{f031b}", .fallback = "c", .color = 0x596706 },
    .{ .key = "html", .glyph = "\u{e736}", .fallback = "h", .color = 0xe44d26 },
    .{ .key = "css", .glyph = "\u{e6b8}", .fallback = "c", .color = 0x663399 },
    .{ .key = "scss", .glyph = "\u{e603}", .fallback = "s", .color = 0xf55385 },
    .{ .key = "vue", .glyph = "\u{e6a0}", .fallback = "v", .color = 0x8dc149 },
    .{ .key = "json", .glyph = "\u{e60b}", .fallback = "j", .color = 0xcbcb41 },
    .{ .key = "yaml", .glyph = "\u{e8eb}", .fallback = "y", .color = 0xd70000 },
    .{ .key = "yml", .glyph = "\u{e8eb}", .fallback = "y", .color = 0xd70000 },
    .{ .key = "toml", .glyph = "\u{e6b2}", .fallback = "t", .color = 0x9c4221 },
    .{ .key = "zon", .glyph = "\u{e6a9}", .fallback = "z", .color = 0xf7a41d },
    .{ .key = "xml", .glyph = "\u{f05c0}", .fallback = "x", .color = 0xe37933 },
    .{ .key = "csv", .glyph = "\u{e64a}", .fallback = "c", .color = 0x89e051 },
    .{ .key = "ini", .glyph = "\u{e615}", .fallback = "i", .color = 0x6d8086 },
    .{ .key = "conf", .glyph = "\u{e615}", .fallback = "c", .color = 0x6d8086 },
    .{ .key = "py", .glyph = "\u{e606}", .fallback = "p", .color = 0xffbc03 },
    .{ .key = "go", .glyph = "\u{e627}", .fallback = "g", .color = 0x00add8 },
    .{ .key = "rb", .glyph = "\u{e791}", .fallback = "r", .color = 0x701516 },
    .{ .key = "java", .glyph = "\u{e738}", .fallback = "j", .color = 0xcc3e44 },
    .{ .key = "kt", .glyph = "\u{e634}", .fallback = "k", .color = 0x7f52ff },
    .{ .key = "swift", .glyph = "\u{e755}", .fallback = "s", .color = 0xe37933 },
    .{ .key = "c", .glyph = "\u{e61e}", .fallback = "c", .color = 0x599eff },
    .{ .key = "cpp", .glyph = "\u{e61d}", .fallback = "c", .color = 0x519aba },
    .{ .key = "h", .glyph = "\u{f0fd}", .fallback = "h", .color = 0xa074c4 },
    .{ .key = "hpp", .glyph = "\u{f0fd}", .fallback = "h", .color = 0xa074c4 },
    .{ .key = "php", .glyph = "\u{e608}", .fallback = "p", .color = 0xa074c4 },
    .{ .key = "lua", .glyph = "\u{e620}", .fallback = "l", .color = 0x51a0cf },
    .{ .key = "sql", .glyph = "\u{e706}", .fallback = "s", .color = 0xdad8d8 },
    .{ .key = "sh", .glyph = "\u{e795}", .fallback = "$", .color = 0x4d5a5e },
    .{ .key = "bash", .glyph = "\u{e760}", .fallback = "$", .color = 0x89e051 },
    .{ .key = "zsh", .glyph = "\u{e795}", .fallback = "$", .color = 0x89e051 },
    .{ .key = "md", .glyph = "\u{f48a}", .fallback = "m", .color = 0xdddddd },
    .{ .key = "txt", .glyph = "\u{f0219}", .fallback = "t", .color = 0x89e051 },
    .{ .key = "lock", .glyph = "\u{e672}", .fallback = "l", .color = 0xbbbbbb },
    .{ .key = "log", .glyph = "\u{f0331}", .fallback = "l", .color = 0xdddddd },
    .{ .key = "http", .glyph = "\u{f1d8}", .fallback = "h", .color = 0x008ec7 },
    .{ .key = "curl", .glyph = "\u{f1d8}", .fallback = "h", .color = 0x008ec7 },
    .{ .key = "rest", .glyph = "\u{f1d8}", .fallback = "h", .color = 0x008ec7 },
    .{ .key = "svg", .glyph = "\u{f0721}", .fallback = "s", .color = 0xffb13b },
    .{ .key = "png", .glyph = "\u{e60d}", .fallback = "i", .color = 0xa074c4 },
    .{ .key = "jpg", .glyph = "\u{e60d}", .fallback = "i", .color = 0xa074c4 },
    .{ .key = "jpeg", .glyph = "\u{e60d}", .fallback = "i", .color = 0xa074c4 },
    .{ .key = "gif", .glyph = "\u{e60d}", .fallback = "i", .color = 0xa074c4 },
    .{ .key = "webp", .glyph = "\u{e60d}", .fallback = "i", .color = 0xa074c4 },
    .{ .key = "zip", .glyph = "\u{f410}", .fallback = "z", .color = 0xeca517 },
    .{ .key = "gz", .glyph = "\u{f410}", .fallback = "z", .color = 0xeca517 },
};

/// The plain file, for a name the table does not know.
pub const default_glyph = "\u{f15b}";
pub const default_ascii = "-";
const default_color: u24 = 0x6d8086;

fn lowerInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    return std.ascii.lowerString(buf[0..s.len], s);
}

/// The glyph for a file by its name (a path is fine — only the last
/// component counts).
pub fn forName(path: []const u8) Glyph {
    const name = std.fs.path.basename(path);
    var buf: [64]u8 = undefined;
    if (lowerInto(&buf, name)) |lower| {
        for (&by_name) |r| if (std.mem.eql(u8, r.key, lower)) return of(r);
        if (std.mem.lastIndexOfScalar(u8, lower, '.')) |dot| {
            const ext = lower[dot + 1 ..];
            for (&by_ext) |r| if (std.mem.eql(u8, r.key, ext)) return of(r);
        }
    }
    return .{ .glyph = default_glyph, .fallback = default_ascii, .color = Theme.rgb(default_color) };
}

fn of(r: Row) Glyph {
    return .{ .glyph = r.glyph, .fallback = r.fallback, .color = Theme.rgb(r.color) };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "a name outranks its extension; extensions are case-insensitive; the unknown gets the plain file" {
    const readme = forName("/ws/README.md");
    try testing.expectEqualStrings("\u{f00ba}", readme.glyph);
    const md = forName("notes.MD");
    try testing.expectEqualStrings("\u{f48a}", md.glyph);
    try testing.expect(Theme.Color.eql(md.color, Theme.rgb(0xdddddd)));
    const rs = forName("src/main.rs");
    try testing.expectEqualStrings("\u{e68b}", rs.glyph);
    try testing.expectEqualStrings("r", rs.fallback);
    const none = forName("[scratch]");
    try testing.expectEqualStrings(default_glyph, none.glyph);
    try testing.expectEqualStrings(default_ascii, none.fallback);
    // A very long name is not a crash.
    try testing.expectEqualStrings(default_glyph, forName(repeat("x", 200) ++ ".rs").glyph);
}
