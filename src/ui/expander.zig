//! The expander — the fold marker of a collapsible row or section: the
//! tree's workspace headers and folders, the git panel's LOCAL / REMOTE
//! / WORKTREES / STASHES / TAGS, the DEBUG section's VARIABLES / WATCH /
//! CALL STACK / BREAKPOINTS and its scopes, the HTTP section's headers
//! and collections, a grep group, a sessions-table group. One glyph
//! pair, one colour, one slot width — every panel paints its expander
//! through here, so none can drift to a triangle of its own.
//!
//! The glyphs are the Octicons chevrons neo-tree uses and the Rust tree
//! paints (nf-oct-chevron_down / chevron_right, U+F47C / U+F460), `v` /
//! `>` under `--ascii` or without a Nerd Font, and the small triangles
//! under `ui.expand_indicator = .triangle`. The colour is the menu
//! bar's idle label: the palette's `grey`, one step dimmer than the
//! `comment` grey the chevrons wore before (the user found them a
//! little bright beside the tree's lines, which share this colour).
//! A slot is the glyph and one cell of air after it.
//!
//! Not an expander: a chip's dropdown mark (the sort chip, the repo
//! pill), a menu row's submenu mark, a focus marker, the debugger's
//! current-frame mark, a run glyph. Those keep their own glyphs.

const std = @import("std");
const vaxis = @import("vaxis");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");

pub const Style = vaxis.Style;

/// nf-oct-chevron_down / nf-oct-chevron_right.
pub const open_glyph = "\u{F47C}";
pub const open_ascii = "v";
pub const closed_glyph = "\u{F460}";
pub const closed_ascii = ">";
/// `ui.expand_indicator = .triangle`: the small triangles.
pub const open_triangle = "\u{25BE}";
pub const closed_triangle = "\u{25B8}";

/// The cells a slot takes: the glyph and a cell of air.
pub const slot_w: u16 = 2;

/// The glyph alone.
pub fn glyph(ui: Ui, expanded: bool) []const u8 {
    if (ui.ascii or !ui.nerd_font) return if (expanded) open_ascii else closed_ascii;
    if (ui.triangle) return if (expanded) open_triangle else closed_triangle;
    return if (expanded) open_glyph else closed_glyph;
}

/// The glyph with its cell of air — what a row paints in its slot.
pub fn slot(ui: Ui, expanded: bool) []const u8 {
    if (ui.ascii or !ui.nerd_font) return if (expanded) open_ascii ++ " " else closed_ascii ++ " ";
    if (ui.triangle) return if (expanded) open_triangle ++ " " else closed_triangle ++ " ";
    return if (expanded) open_glyph ++ " " else closed_glyph ++ " ";
}

/// `base` with the expander's colour: the menu bar's idle-label grey.
pub fn style(ui: Ui, base: Style) Style {
    return Theme.withFg(base, ui.theme.palette.grey);
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

test "one codepoint per glyph; the slot is the glyph and a cell of air; ascii, no Nerd Font and the triangle setting pick their twins" {
    inline for (.{ open_glyph, closed_glyph, open_triangle, closed_triangle }) |g| {
        try testing.expectEqual(@as(usize, 1), try std.unicode.utf8CountCodepoints(g));
    }
    var f = try Fixture.init(8, 1);
    defer f.deinit();
    var ui = f.ui();
    try testing.expectEqualStrings(open_glyph, glyph(ui, true));
    try testing.expectEqualStrings(closed_glyph, glyph(ui, false));
    try testing.expectEqualStrings(open_glyph ++ " ", slot(ui, true));
    try testing.expectEqual(slot_w, ui.width(slot(ui, false)));
    ui.triangle = true;
    try testing.expectEqualStrings(open_triangle, glyph(ui, true));
    try testing.expectEqualStrings(closed_triangle ++ " ", slot(ui, false));
    ui.triangle = false;
    ui.nerd_font = false;
    try testing.expectEqualStrings("v", glyph(ui, true));
    ui.nerd_font = true;
    ui.ascii = true;
    try testing.expectEqualStrings("> ", slot(ui, false));
    try testing.expectEqualStrings("v", glyph(ui, true));
    // The colour is the menu bar's idle-label grey — `palette.grey`,
    // dimmer than the `comment` grey of `muted.fg`.
    const s = style(ui, .{ .bg = f.theme.bg.bg });
    try testing.expect(vaxis.Color.eql(s.fg, f.theme.palette.grey));
    try testing.expect(!vaxis.Color.eql(s.fg, f.theme.muted.fg));
    try testing.expect(vaxis.Color.eql(s.bg, f.theme.bg.bg));
}

/// The panels whose expanders paint through this module. Each is
/// embedded and searched for the glyphs it used to hand-roll; a new
/// hand-rolled expander in one of them fails this test. The allowance
/// names the one occurrence that is not an expander.
const covered = [_]struct {
    path: []const u8,
    src: []const u8,
    /// `{ literal, count, what it is }` — the sites that may keep the glyph.
    allow: []const struct { lit: []const u8, n: usize, why: []const u8 } = &.{},
}{
    .{ .path = "tree_view.zig", .src = @embedFile("tree_view.zig") },
    .{ .path = "git_palette.zig", .src = @embedFile("git_palette.zig"), .allow = &.{
        .{ .lit = cp(0xF0140), .n = 3, .why = "the repo pill's dropdown mark: `repo_chevron_nerd` and the two comments that show the pill" },
        .{ .lit = cp(0xF0142), .n = 1, .why = "the tab strip's next arrow, in the diagram of the column" },
    } },
    .{ .path = "debug_panel.zig", .src = @embedFile("debug_panel.zig") },
    .{ .path = "dap_view.zig", .src = @embedFile("dap_view.zig") },
    .{ .path = "http_panel.zig", .src = @embedFile("http_panel.zig") },
    .{ .path = "grep_view.zig", .src = @embedFile("grep_view.zig") },
    .{ .path = "sessions_table_view.zig", .src = @embedFile("sessions_table_view.zig"), .allow = &.{
        .{ .lit = "\u{25B8}", .n = 1, .why = "the summary line's `tool` state mark" },
    } },
};

/// The glyphs a panel used to paint on its own: the small triangles and
/// the md-chevron pair, each as the glyph itself and as its escape. The
/// chevrons are spelled as codepoints, and their escapes in two halves,
/// so the glyph audit does not read this list as paint sites.
const banned = [_]struct { lit: []const u8, spellings: []const []const u8 }{
    .{ .lit = "\u{25BE}", .spellings = &.{ "\u{25BE}", "\\u{25BE}", "\\u{25be}" } },
    .{ .lit = "\u{25B8}", .spellings = &.{ "\u{25B8}", "\\u{25B8}", "\\u{25b8}" } },
    .{ .lit = cp(0xF0140), .spellings = &.{ cp(0xF0140), "\\u{" ++ "F0140}", "\\u{" ++ "f0140}" } },
    .{ .lit = cp(0xF0142), .spellings = &.{ cp(0xF0142), "\\u{" ++ "F0142}", "\\u{" ++ "f0142}" } },
};

/// `c` encoded as UTF-8, at comptime.
fn cp(comptime c: u21) []const u8 {
    return comptime blk: {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(c, &buf) catch unreachable;
        const bytes = buf[0..n].*;
        break :blk &bytes;
    };
}

fn countAll(src: []const u8, spellings: []const []const u8) usize {
    var n: usize = 0;
    for (spellings) |s| n += std.mem.count(u8, src, s);
    return n;
}

test "no panel hand-rolls an expander: the old glyphs are gone from every covered painter, but for the allowed non-expander sites" {
    for (covered) |c| {
        for (banned) |b| {
            var allowed: usize = 0;
            for (c.allow) |a| if (std.mem.eql(u8, a.lit, b.lit)) {
                allowed = a.n;
            };
            const found = countAll(c.src, b.spellings);
            if (found != allowed) {
                std.debug.print("src/ui/{s}: {d} of {s} (allowed {d})\n", .{ c.path, found, b.spellings[1], allowed });
                return error.HandRolledExpander;
            }
        }
    }
    // The check can fail: a painter with the triangle in it is caught.
    try testing.expectEqual(@as(usize, 2), countAll("x = \"\u{25BE} \"; // \\u{25BE}", banned[0].spellings));
}
