//! File-type icons — nvim-web-devicons' default set, the codepoints and
//! colours the Rust painter uses (`ui/icons.rs`), as comptime data. A
//! name wins over an extension (`package.json` is npm's glyph, not the
//! JSON one); an unknown file is the plain document glyph.
//!
//! Every glyph is a Nerd Font codepoint the user's font resolves; the
//! `--ascii` twin of every file glyph is the same middle dot, as in
//! Rust, so column widths stay put. Folders are the closed / open
//! folder pair; the tree paints them in the live theme's colour, not the
//! baked blue here (themes still apply — the Rust rule).

const std = @import("std");
const vaxis = @import("vaxis");
const Theme = @import("theme.zig");

pub const Icon = struct {
    glyph: []const u8,
    color: vaxis.Color,
};

/// nf-fa-file (the document glyph) — every unknown file.
pub const default_file_glyph = "\u{F15B}";
pub const default_file_ascii = "·";
pub const default_file_color: u24 = 0x6d8086;

/// onedark blue: nvim-tree's folder look. Baked so the table is
/// comptime; the painter swaps the live theme's blue in.
pub const folder_blue: u24 = 0x61afef;
/// nf-fa-folder / nf-fa-folder_open.
pub const folder_closed_glyph = "\u{F07B}";
pub const folder_closed_ascii = "▶";
pub const folder_open_glyph = "\u{F07C}";
pub const folder_open_ascii = "▼";

/// A repo folder in a multi-repo workspace: nf-dev-git, tinted orange.
pub const repo_orange: u24 = 0xE5C07B;
pub const repo_glyph = "\u{E702}";
pub const repo_ascii = "▶";
pub const repo_open_ascii = "▼";

const Entry = struct { key: []const u8, glyph: []const u8, fallback: []const u8, color: u24 };

/// Whole-filename rows, lower-cased. Checked before the extension.
pub const by_name = [_]Entry{
    .{ .key = "package.json", .glyph = "\u{E71E}", .fallback = "·", .color = 0xE8274B },
    .{ .key = "package-lock.json", .glyph = "\u{E71E}", .fallback = "·", .color = 0x7A0D21 },
    .{ .key = "pnpm-lock.yaml", .glyph = "\u{E865}", .fallback = "·", .color = 0xF9AD02 },
    .{ .key = "tsconfig.json", .glyph = "\u{E69D}", .fallback = "·", .color = 0x519ABA },
    .{ .key = ".env", .glyph = "\u{F462}", .fallback = "·", .color = 0xFAF743 },
    .{ .key = ".gitignore", .glyph = "\u{E702}", .fallback = "·", .color = 0xF54D27 },
    .{ .key = ".gitattributes", .glyph = "\u{E702}", .fallback = "·", .color = 0xF54D27 },
    .{ .key = ".gitconfig", .glyph = "\u{E615}", .fallback = "·", .color = 0xF54D27 },
    .{ .key = ".eslintrc", .glyph = "\u{E655}", .fallback = "·", .color = 0x4B32C3 },
    .{ .key = ".prettierrc", .glyph = "\u{E6B4}", .fallback = "·", .color = 0x4285F4 },
    .{ .key = ".editorconfig", .glyph = "\u{E652}", .fallback = "·", .color = 0xFFF2F2 },
    .{ .key = ".dockerignore", .glyph = "\u{F0868}", .fallback = "·", .color = 0x458EE6 },
    .{ .key = ".npmrc", .glyph = "\u{E71E}", .fallback = "·", .color = 0xE8274B },
    .{ .key = ".nvmrc", .glyph = "\u{E718}", .fallback = "·", .color = 0x5FA04E },
    .{ .key = "dockerfile", .glyph = "\u{F0868}", .fallback = "·", .color = 0x458EE6 },
    .{ .key = "docker-compose.yml", .glyph = "\u{F0868}", .fallback = "·", .color = 0x458EE6 },
    .{ .key = "docker-compose.yaml", .glyph = "\u{F0868}", .fallback = "·", .color = 0x458EE6 },
    .{ .key = "compose.yml", .glyph = "\u{F0868}", .fallback = "·", .color = 0x458EE6 },
    .{ .key = "compose.yaml", .glyph = "\u{F0868}", .fallback = "·", .color = 0x458EE6 },
    .{ .key = "readme", .glyph = "\u{F00BA}", .fallback = "·", .color = 0xEDEDED },
    .{ .key = "readme.md", .glyph = "\u{F00BA}", .fallback = "·", .color = 0xEDEDED },
    .{ .key = "license", .glyph = "\u{E60A}", .fallback = "·", .color = 0xD0BF41 },
    .{ .key = "copying", .glyph = "\u{E60A}", .fallback = "·", .color = 0xCBCB41 },
    .{ .key = "makefile", .glyph = "\u{E779}", .fallback = "·", .color = 0x6D8086 },
};

/// Extension rows, lower-cased, without the dot.
pub const by_ext = [_]Entry{
    .{ .key = "ts", .glyph = "\u{E628}", .fallback = "·", .color = 0x519ABA },
    .{ .key = "tsx", .glyph = "\u{E7BA}", .fallback = "·", .color = 0x1354BF },
    .{ .key = "js", .glyph = "\u{E60C}", .fallback = "·", .color = 0xCBCB41 },
    .{ .key = "cjs", .glyph = "\u{E60C}", .fallback = "·", .color = 0xCBCB41 },
    .{ .key = "mjs", .glyph = "\u{E60C}", .fallback = "·", .color = 0xF1E05A },
    .{ .key = "jsx", .glyph = "\u{E625}", .fallback = "·", .color = 0x20C2E3 },
    .{ .key = "rs", .glyph = "\u{E68B}", .fallback = "·", .color = 0xDEA584 },
    .{ .key = "cs", .glyph = "\u{F031B}", .fallback = "·", .color = 0x596706 },
    .{ .key = "csproj", .glyph = "\u{F0AAE}", .fallback = "·", .color = 0x512BD4 },
    .{ .key = "sln", .glyph = "\u{E70C}", .fallback = "·", .color = 0x854CC7 },
    .{ .key = "cshtml", .glyph = "\u{F1997}", .fallback = "·", .color = 0x512BD4 },
    .{ .key = "razor", .glyph = "\u{F1998}", .fallback = "·", .color = 0x512BD4 },
    .{ .key = "fs", .glyph = "\u{E7A7}", .fallback = "·", .color = 0x519ABA },
    .{ .key = "html", .glyph = "\u{E736}", .fallback = "·", .color = 0xE44D26 },
    .{ .key = "htm", .glyph = "\u{E60E}", .fallback = "·", .color = 0xE34C26 },
    .{ .key = "css", .glyph = "\u{E6B8}", .fallback = "·", .color = 0x663399 },
    .{ .key = "scss", .glyph = "\u{E603}", .fallback = "·", .color = 0xF55385 },
    .{ .key = "sass", .glyph = "\u{E603}", .fallback = "·", .color = 0xF55385 },
    .{ .key = "less", .glyph = "\u{E614}", .fallback = "·", .color = 0x563D7C },
    .{ .key = "vue", .glyph = "\u{E6A0}", .fallback = "·", .color = 0x8DC149 },
    .{ .key = "svelte", .glyph = "\u{E697}", .fallback = "·", .color = 0xFF3E00 },
    .{ .key = "json", .glyph = "\u{E60B}", .fallback = "·", .color = 0xCBCB41 },
    .{ .key = "yaml", .glyph = "\u{E8EB}", .fallback = "·", .color = 0xD70000 },
    .{ .key = "yml", .glyph = "\u{E8EB}", .fallback = "·", .color = 0xD70000 },
    .{ .key = "toml", .glyph = "\u{E6B2}", .fallback = "·", .color = 0x9C4221 },
    .{ .key = "xml", .glyph = "\u{F05C0}", .fallback = "·", .color = 0xE37933 },
    .{ .key = "csv", .glyph = "\u{E64A}", .fallback = "·", .color = 0x89E051 },
    .{ .key = "ini", .glyph = "\u{E615}", .fallback = "·", .color = 0x6D8086 },
    .{ .key = "conf", .glyph = "\u{E615}", .fallback = "·", .color = 0x6D8086 },
    .{ .key = "py", .glyph = "\u{E606}", .fallback = "·", .color = 0xFFBC03 },
    .{ .key = "go", .glyph = "\u{E627}", .fallback = "·", .color = 0x00ADD8 },
    .{ .key = "rb", .glyph = "\u{E791}", .fallback = "·", .color = 0x701516 },
    .{ .key = "java", .glyph = "\u{E738}", .fallback = "·", .color = 0xCC3E44 },
    .{ .key = "kt", .glyph = "\u{E634}", .fallback = "·", .color = 0x7F52FF },
    .{ .key = "swift", .glyph = "\u{E755}", .fallback = "·", .color = 0xE37933 },
    .{ .key = "c", .glyph = "\u{E61E}", .fallback = "·", .color = 0x599EFF },
    .{ .key = "cpp", .glyph = "\u{E61D}", .fallback = "·", .color = 0x519ABA },
    .{ .key = "h", .glyph = "\u{F0FD}", .fallback = "·", .color = 0xA074C4 },
    .{ .key = "hpp", .glyph = "\u{F0FD}", .fallback = "·", .color = 0xA074C4 },
    .{ .key = "php", .glyph = "\u{E608}", .fallback = "·", .color = 0xA074C4 },
    .{ .key = "lua", .glyph = "\u{E620}", .fallback = "·", .color = 0x51A0CF },
    .{ .key = "sql", .glyph = "\u{E706}", .fallback = "·", .color = 0xDAD8D8 },
    .{ .key = "sh", .glyph = "\u{E795}", .fallback = "·", .color = 0x4D5A5E },
    .{ .key = "bash", .glyph = "\u{E760}", .fallback = "·", .color = 0x89E051 },
    .{ .key = "zsh", .glyph = "\u{E795}", .fallback = "·", .color = 0x89E051 },
    .{ .key = "ps1", .glyph = "\u{F0A0A}", .fallback = "·", .color = 0x4273CA },
    .{ .key = "md", .glyph = "\u{F48A}", .fallback = "·", .color = 0xDDDDDD },
    .{ .key = "txt", .glyph = "\u{F0219}", .fallback = "·", .color = 0x89E051 },
    .{ .key = "lock", .glyph = "\u{E672}", .fallback = "·", .color = 0xBBBBBB },
    .{ .key = "log", .glyph = "\u{F0331}", .fallback = "·", .color = 0xDDDDDD },
    .{ .key = "exe", .glyph = "\u{EAE8}", .fallback = "·", .color = 0x9F0500 },
    .{ .key = "dll", .glyph = "\u{EB9C}", .fallback = "·", .color = 0x4D2C0B },
    .{ .key = "http", .glyph = "\u{F1D8}", .fallback = "·", .color = 0x008EC7 },
    .{ .key = "curl", .glyph = "\u{F1D8}", .fallback = "·", .color = 0x008EC7 },
    .{ .key = "rest", .glyph = "\u{F1D8}", .fallback = "·", .color = 0x008EC7 },
    .{ .key = "request", .glyph = "\u{F1D8}", .fallback = "·", .color = 0x008EC7 },
    .{ .key = "svg", .glyph = "\u{F0721}", .fallback = "·", .color = 0xFFB13B },
    .{ .key = "png", .glyph = "\u{E60D}", .fallback = "·", .color = 0xA074C4 },
    .{ .key = "jpg", .glyph = "\u{E60D}", .fallback = "·", .color = 0xA074C4 },
    .{ .key = "jpeg", .glyph = "\u{E60D}", .fallback = "·", .color = 0xA074C4 },
    .{ .key = "gif", .glyph = "\u{E60D}", .fallback = "·", .color = 0xA074C4 },
    .{ .key = "webp", .glyph = "\u{E60D}", .fallback = "·", .color = 0xA074C4 },
    .{ .key = "zip", .glyph = "\u{F410}", .fallback = "·", .color = 0xECA517 },
    .{ .key = "gz", .glyph = "\u{F410}", .fallback = "·", .color = 0xECA517 },
    .{ .key = "tgz", .glyph = "\u{F410}", .fallback = "·", .color = 0xECA517 },
};

/// The icon for a tree row. `expanded` only matters for a directory;
/// `ascii` paints the one-character twins (every file is the same dot,
/// so the icon column keeps its width).
pub fn forName(name: []const u8, is_dir: bool, expanded: bool, ascii: bool) Icon {
    if (is_dir) return .{
        .glyph = if (ascii) (if (expanded) folder_open_ascii else folder_closed_ascii) else (if (expanded) folder_open_glyph else folder_closed_glyph),
        .color = Theme.rgb(folder_blue),
    };
    if (ascii) return .{ .glyph = default_file_ascii, .color = Theme.rgb(default_file_color) };
    var buf: [256]u8 = undefined;
    if (name.len > buf.len) return .{ .glyph = default_file_glyph, .color = Theme.rgb(default_file_color) };
    const lower = std.ascii.lowerString(&buf, name);
    for (by_name) |e| if (std.mem.eql(u8, e.key, lower)) return .{ .glyph = e.glyph, .color = Theme.rgb(e.color) };
    if (extensionOf(lower)) |ext| {
        for (by_ext) |e| if (std.mem.eql(u8, e.key, ext)) return .{ .glyph = e.glyph, .color = Theme.rgb(e.color) };
    }
    return .{ .glyph = default_file_glyph, .color = Theme.rgb(default_file_color) };
}

/// The repo-folder icon (a depth-0 directory that is its own git repo
/// in a multi-repo workspace).
pub fn repo(expanded: bool, ascii: bool) Icon {
    return .{
        .glyph = if (ascii) (if (expanded) repo_open_ascii else repo_ascii) else repo_glyph,
        .color = Theme.rgb(repo_orange),
    };
}

/// After the last dot, unless the dot leads (`.gitignore` has none).
pub fn extensionOf(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0 or dot + 1 >= name.len) return null;
    return name[dot + 1 ..];
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn glyphOf(name: []const u8) []const u8 {
    return forName(name, false, false, false).glyph;
}

test "twenty paths resolve to the Rust glyphs: names beat extensions, case folds, unknown is the document" {
    try t.expectEqualStrings("\u{E68B}", glyphOf("main.rs"));
    try t.expectEqualStrings("\u{E628}", glyphOf("app.ts"));
    try t.expectEqualStrings("\u{E7BA}", glyphOf("App.tsx"));
    try t.expectEqualStrings("\u{E60C}", glyphOf("index.js"));
    try t.expectEqualStrings("\u{E606}", glyphOf("tool.py"));
    try t.expectEqualStrings("\u{E627}", glyphOf("main.go"));
    try t.expectEqualStrings("\u{F00BA}", glyphOf("README.md"));
    try t.expectEqualStrings("\u{F48A}", glyphOf("notes.md"));
    try t.expectEqualStrings("\u{E71E}", glyphOf("package.json"));
    try t.expectEqualStrings("\u{E60B}", glyphOf("data.json"));
    try t.expectEqualStrings("\u{E702}", glyphOf(".gitignore"));
    try t.expectEqualStrings("\u{E6B2}", glyphOf("Cargo.toml"));
    try t.expectEqualStrings("\u{E8EB}", glyphOf("config.yaml"));
    try t.expectEqualStrings("\u{F0868}", glyphOf("Dockerfile"));
    try t.expectEqualStrings("\u{E779}", glyphOf("Makefile"));
    try t.expectEqualStrings("\u{E60A}", glyphOf("LICENSE"));
    try t.expectEqualStrings("\u{E795}", glyphOf("run.sh"));
    try t.expectEqualStrings("\u{E60D}", glyphOf("logo.PNG"));
    try t.expectEqualStrings("\u{F1D8}", glyphOf("req.http"));
    try t.expectEqualStrings("\u{F15B}", glyphOf("weird.xyz"));
    try t.expect(vaxis.Color.eql(forName("main.rs", false, false, false).color, Theme.rgb(0xDEA584)));
    try t.expect(vaxis.Color.eql(forName("weird.xyz", false, false, false).color, Theme.rgb(0x6d8086)));
    try t.expect(vaxis.Color.eql(forName("package.json", false, false, false).color, Theme.rgb(0xE8274B)));
}

test "folders: closed and open, the ascii twins, and every file's dot" {
    try t.expectEqualStrings("\u{F07B}", forName("src", true, false, false).glyph);
    try t.expectEqualStrings("\u{F07C}", forName("src", true, true, false).glyph);
    try t.expectEqualStrings("▶", forName("src", true, false, true).glyph);
    try t.expectEqualStrings("▼", forName("src", true, true, true).glyph);
    try t.expectEqualStrings("·", forName("main.rs", false, false, true).glyph);
    try t.expectEqualStrings("·", forName("package.json", false, false, true).glyph);
    try t.expectEqualStrings("\u{E702}", repo(false, false).glyph);
    try t.expectEqualStrings("▼", repo(true, true).glyph);
}

test "every table glyph is one Nerd Font codepoint with a one-cell twin, and no key repeats within its table" {
    inline for (.{ by_name, by_ext }) |table| {
        for (table, 0..) |e, i| {
            try t.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(e.glyph));
            const cp = try std.unicode.utf8Decode(e.glyph);
            try t.expect((cp >= 0xe000 and cp <= 0xf8ff) or (cp >= 0xf0000 and cp <= 0xf1aff));
            try t.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(e.fallback));
            for (table[0..i]) |prev| try t.expect(!std.mem.eql(u8, prev.key, e.key));
            // Keys are lower-case: the lookup folds the name first.
            for (e.key) |c| try t.expect(!std.ascii.isUpper(c));
        }
    }
}

test "extensionOf: the last dot, never a leading one" {
    try t.expectEqualStrings("rs", extensionOf("main.rs").?);
    try t.expectEqualStrings("local", extensionOf(".env.local").?);
    try t.expectEqualStrings("gz", extensionOf("a.tar.gz").?);
    try t.expect(extensionOf(".gitignore") == null);
    try t.expect(extensionOf("Makefile") == null);
    try t.expect(extensionOf("trailing.") == null);
}
