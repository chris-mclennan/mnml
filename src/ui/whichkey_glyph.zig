//! The glyph a which-key row paints before its key — the reference
//! plugin's look, which the reference editor's own popup does not have
//! (`docs/PARITY.md`, the which-key row: a deliberate departure, decided
//! 2026-09-14).
//!
//! One row per group label, `+` and all. Wherever the group already has
//! a face elsewhere in mnml the face is *taken*, not re-picked, so the
//! popup and the rest of the chrome agree: the rail's own section meta
//! (`activity_bar.zig`) for find / git / debug / integrations / http /
//! buffers, the file-type table (`icons.zig`) for the language runners,
//! and the menu glyphs (`menu_glyph.zig`) for the verbs a menu row
//! already draws that way. A label the table does not know gets the
//! neutral keyboard glyph, so a group added tomorrow still paints a
//! column of the right width.
//!
//! Every glyph has its one-character `--ascii` twin, so the column is
//! one cell either way and the strip's math does not move.

const std = @import("std");
const rail = @import("activity_bar.zig");
const icons = @import("icons.zig");

pub const Glyph = struct {
    glyph: []const u8,
    /// The `--ascii` twin: one printable byte, never a space.
    fallback: []const u8,

    /// The face for the mode the ui is painting in.
    pub fn pick(g: Glyph, ascii: bool) []const u8 {
        return if (ascii) g.fallback else g.glyph;
    }
};

const Row = struct { key: []const u8, glyph: []const u8, fallback: []const u8 };

/// A rail section's glyph — the same codepoint that section paints on
/// the icon rail.
fn railGlyph(comptime s: rail.Section) []const u8 {
    return s.meta().glyph;
}

/// A file-type glyph from the devicon table, by extension.
fn extGlyph(comptime ext: []const u8) []const u8 {
    for (icons.by_ext) |e| {
        if (std.mem.eql(u8, e.key, ext)) return e.glyph;
    }
    @compileError("no icons.by_ext row for ." ++ ext);
}

/// A file-type glyph from the devicon table, by whole name.
fn nameGlyph(comptime name: []const u8) []const u8 {
    for (icons.by_name) |e| {
        if (std.mem.eql(u8, e.key, name)) return e.glyph;
    }
    @compileError("no icons.by_name row for " ++ name);
}

/// A group the table does not know — nf-md-apple_keyboard_option, the
/// neutral "a chord lives here" mark.
pub const neutral: Glyph = .{ .glyph = "\u{f0635}", .fallback = "." }; // 󰘵

/// `label` → glyph, the group labels exactly as `app/whichkey.zig`
/// spells them. First match wins; the order is the tree's.
pub const by_group = [_]Row{
    .{ .key = "+find", .glyph = railGlyph(.search), .fallback = "f" }, // the rail's SEARCH
    .{ .key = "+nvchad", .glyph = "\u{f11c}", .fallback = "k" }, //  fa-keyboard_o
    .{ .key = "+lsp", .glyph = "\u{f085}", .fallback = "l" }, //  fa-cogs, the menus' lsp domain
    .{ .key = "+buffer", .glyph = railGlyph(.sessions), .fallback = "b" }, // the rail's SESSIONS
    .{ .key = "+split", .glyph = "\u{f0db}", .fallback = "|" }, //  fa-columns, the menus' split verb
    .{ .key = "+debug", .glyph = railGlyph(.debug), .fallback = "d" }, // the rail's DEBUG
    .{ .key = "+git", .glyph = railGlyph(.git), .fallback = "g" }, // the rail's GIT
    .{ .key = "+ai/term", .glyph = "\u{f06a9}", .fallback = "*" }, // 󰚩 md-robot, the menus' ai domain
    .{ .key = "+toggle", .glyph = "\u{f205}", .fallback = "~" }, //  fa-toggle_on, the menus' toggle verb
    .{ .key = "+http", .glyph = railGlyph(.http), .fallback = "h" }, // the rail's HTTP
    .{ .key = "+test", .glyph = "\u{f0c3}", .fallback = "t" }, //  fa-flask, the menus' test verb
    .{ .key = "+lang/run", .glyph = "\u{f04b}", .fallback = ">" }, //  fa-play, the menus' run verb
    .{ .key = "+cargo", .glyph = extGlyph("rs"), .fallback = "r" }, // the .rs devicon
    .{ .key = "+npm", .glyph = nameGlyph("package.json"), .fallback = "n" }, // the package.json devicon
    .{ .key = "+pytest", .glyph = extGlyph("py"), .fallback = "p" }, // the .py devicon
    .{ .key = "+go", .glyph = extGlyph("go"), .fallback = "o" }, // the .go devicon
    .{ .key = "+pr", .glyph = "\u{f04c2}", .fallback = "P" }, // 󰓂 md-source_pull
    .{ .key = "+integrations", .glyph = railGlyph(.integrations), .fallback = "i" }, // the rail's INTEGRATIONS
    .{ .key = "+insert", .glyph = "\u{f121}", .fallback = "s" }, //  fa-code, a snippet
    .{ .key = "+harpoon", .glyph = "\u{f08d}", .fallback = "^" }, //  fa-thumb_tack, the menus' pin verb
    .{ .key = "+layouts", .glyph = "\u{f009}", .fallback = "#" }, //  fa-th_large, a page of splits
    .{ .key = "+which-key", .glyph = "\u{f059}", .fallback = "?" }, //  fa-question_circle, the keymap lookup
};

/// The glyph for a group label (`+find`), or the neutral one. The root
/// (`<leader>`) is not a `+` label and gets the neutral glyph too, which
/// is what its own leaves paint.
pub fn forGroup(label: []const u8) Glyph {
    for (by_group) |r| {
        if (std.mem.eql(u8, r.key, label)) return .{ .glyph = r.glyph, .fallback = r.fallback };
    }
    return neutral;
}

// ── tests ──

const t = std.testing;

test "the rail's own faces, the devicons, and the neutral fallback" {
    // Taken, not re-picked: the popup's find/git/debug/http/buffers
    // glyphs ARE the rail's, so the two never drift apart.
    try t.expectEqualStrings(rail.Section.search.meta().glyph, forGroup("+find").glyph);
    try t.expectEqualStrings(rail.Section.git.meta().glyph, forGroup("+git").glyph);
    try t.expectEqualStrings(rail.Section.debug.meta().glyph, forGroup("+debug").glyph);
    try t.expectEqualStrings(rail.Section.http.meta().glyph, forGroup("+http").glyph);
    try t.expectEqualStrings(rail.Section.sessions.meta().glyph, forGroup("+buffer").glyph);
    try t.expectEqualStrings(rail.Section.integrations.meta().glyph, forGroup("+integrations").glyph);
    // The language runners wear their file type's devicon.
    try t.expectEqualStrings("\u{E68B}", forGroup("+cargo").glyph);
    try t.expectEqualStrings("\u{E606}", forGroup("+pytest").glyph);
    try t.expectEqualStrings("\u{E627}", forGroup("+go").glyph);
    try t.expectEqualStrings("\u{E71E}", forGroup("+npm").glyph);
    // A label no row carries, and the root, get the neutral mark.
    try t.expectEqualStrings(neutral.glyph, forGroup("+nope").glyph);
    try t.expectEqualStrings(neutral.glyph, forGroup("<leader>").glyph);
    try t.expectEqualStrings(".", forGroup("").fallback);
    try t.expectEqualStrings("f", forGroup("+find").pick(true));
    try t.expectEqualStrings(rail.Section.search.meta().glyph, forGroup("+find").pick(false));
}

test "every row: one Nerd Font codepoint, one printable ascii twin, no repeated key" {
    for (by_group ++ [_]Row{.{ .key = "", .glyph = neutral.glyph, .fallback = neutral.fallback }}, 0..) |r, i| {
        try t.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(r.glyph));
        const cp = try std.unicode.utf8Decode(r.glyph);
        try t.expect((cp >= 0xe000 and cp <= 0xf8ff) or (cp >= 0xf0000 and cp <= 0xfffff));
        try t.expect(r.fallback.len == 1 and std.ascii.isPrint(r.fallback[0]) and r.fallback[0] != ' ');
        if (i < by_group.len) {
            for (by_group[0..i]) |prev| try t.expect(!std.mem.eql(u8, prev.key, r.key));
            try t.expect(r.key.len > 1 and r.key[0] == '+');
        }
    }
}
