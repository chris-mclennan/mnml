//! Statusline — the bottom row as two lanes of powerline chips.
//!
//! A chip is a `Seg`: its text, its own foreground and background, and
//! the hit it registers. The left lane runs from the left edge, the
//! right lane ends at the right edge, and between two chips of
//! different backgrounds sits a powerline arrow (U+E0B0 on the left,
//! U+E0B2 on the right) painted in the two backgrounds — the
//! colour hand-off. Two neighbours on the same ground get no arrow,
//! so a chip built from several segs (a glyph and its label) reads as
//! one pill. The component knows nothing about what a chip means: the
//! app builds the two lists (`app/statusline.zig`) and routes the hits.
//!
//! Overflow is Rust's: the right lane is measured whole; if the left
//! lane would then not fit with four cells of air, its longest chip is
//! clipped with an ellipsis (never below three cells) — a long file
//! name, a long branch. If the row is still too narrow, the right lane
//! follows the left lane directly and the screen edge cuts it: at 60
//! columns the Rust row ends in the clock, the workspace and the
//! language gone (a dump the statusline tests pin). An earlier pass
//! dropped right chips leftmost-first instead and kept the cursor
//! position sticky; that was Zig's rule, not the Rust look, and is gone.
//!
//! Every glyph is the codepoint the Rust statusline paints — the
//! terminal maps U+F1B00–U+F20FF onto mnml's own baked symbols, so a
//! lookalike renders as a box.
//!
//! // changed: `Info` is the two lanes plus the centred pending chord;
//! every chip carries its hit id (`Seg.hit`), so the mode chip, the file
//! name, the branch and a host's `statusline-set-segment` chip register
//! `.statusline_seg` from one paint loop. The fixed ids below are the
//! component's; `seg_app_base` and up are the app's (`app/statusline.zig`
//! `SegId`), `seg_dyn_base + index` a host segment's.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const bufferline = @import("bufferline.zig");

const Style = vaxis.Style;
const Color = vaxis.Color;

pub const seg_mode: u32 = 0;
pub const seg_file: u32 = 1;
pub const seg_position: u32 = 2;
/// The language chip at the far right (`  rs `, `  — ` for none).
pub const seg_language: u32 = 3;
/// `RESTRICTED` — the workspace's exec-bearing config is stripped.
pub const seg_restricted: u32 = 4;
/// Ids the app defines start here (and stay below `seg_dyn_base`).
pub const seg_app_base: u32 = 16;
/// `seg_dyn_base + i` is a host segment's slot in `ipc/effects.zig`.
pub const seg_dyn_base: u32 = 0x100;

/// Powerline hard dividers; nothing under `--ascii`, where the chips
/// meet edge to edge.
pub const pl_right_nerd = "\u{e0b0}";
pub const pl_right_ascii = "";
pub const pl_left_nerd = "\u{e0b2}";
pub const pl_left_ascii = "";

/// The glyphs the chips share, each with its `--ascii` twin. Every one
/// is the codepoint the Rust statusline paints.
/// nf-custom-vim, before a vim mode label.
pub const vim_glyph = "\u{e7c5}";
pub const vim_ascii = "";
/// nf-fa-code_fork — the branch when the remote names no forge.
pub const branch_glyph = "\u{f126}";
pub const branch_ascii = "";
/// nf-fa-github / nf-fa-gitlab / nf-dev-bitbucket / nf-md-microsoft_azure / nf-dev-git.
pub const github_glyph = "\u{f09b}";
pub const github_ascii = "";
pub const gitlab_glyph = "\u{f296}";
pub const gitlab_ascii = "";
pub const bitbucket_glyph = "\u{e703}";
pub const bitbucket_ascii = "";
pub const azure_glyph = "\u{f0805}";
pub const azure_ascii = "";
pub const forge_glyph = "\u{e702}";
pub const forge_ascii = "";
/// nf-md-plus_circle_outline / pencil_circle_outline / minus_circle_outline — the file counts.
pub const added_glyph = "\u{f0419}";
pub const added_ascii = "+";
pub const changed_glyph = "\u{f06d5}";
pub const changed_ascii = "~";
pub const removed_glyph = "\u{f0374}";
pub const removed_ascii = "-";
/// nf-fa-times_circle, before the error count.
pub const errors_glyph = "\u{f057}";
pub const errors_ascii = "E";
/// nf-oct-graph — the coverage chip when no integration names one.
pub const coverage_glyph = "\u{f437}";
pub const coverage_ascii = "";
/// nf-md-shield_lock_outline, before RESTRICTED.
pub const restricted_glyph = "\u{f033e}";
pub const restricted_ascii = "";
/// nf-md-content_save, before the autosave interval.
pub const autosave_glyph = "\u{f0193}";
pub const autosave_ascii = "save";
/// nf-fa-bell.
pub const bell_glyph = "\u{f0f3}";
pub const bell_ascii = "!";
/// nf-fa-folder, before the workspace name.
pub const folder_glyph = "\u{f07b}";
pub const folder_ascii = "";
/// The Claude / Codex marks — mnml's own baked glyphs (U+F1B00–U+F20FF),
/// the same constants the strip paints, so the two cannot drift. WHICH
/// Claude mark the statusline draws is `ui.claude_mark`'s to say, and
/// `app/claude_mark.zig` answers it; `claude_glyph` is the figure.
pub const claude_glyph = bufferline.claude_glyph;
pub const claude_ascii = bufferline.claude_ascii;
pub const codex_glyph = bufferline.codex_glyph;
pub const codex_ascii = bufferline.codex_ascii;
/// nf-md-code_json — the ghost-text chip, which says what the inline
/// suggestion is doing when there is no suggestion to look at
/// (`app/ghost_chip.zig`).
pub const ghost_glyph = "\u{f0626}";
pub const ghost_ascii = "AI";
/// The now-playing cluster's marks: mnml's baked Beatport B (mixr),
/// nf-fa-apple (Music), nf-fa-spotify (Spotify) as the idle brand;
/// nf-md-play_box_outline as the idle play chip; nf-md-pause /
/// nf-md-play / nf-md-skip_next as the transport.
pub const cluster_brand_glyph = "\u{f1f00}";
pub const cluster_brand_ascii = "B";
pub const apple_glyph = "\u{e711}";
pub const apple_ascii = "A";
pub const spotify_glyph = "\u{f1bc}";
pub const spotify_ascii = "S";
pub const cluster_play_glyph = "\u{f040e}";
pub const cluster_play_ascii = ">";
pub const np_pause_glyph = "\u{f03e4}";
pub const np_pause_ascii = "||";
pub const np_play_glyph = "\u{f040a}";
pub const np_play_ascii = ">";
pub const np_next_glyph = "\u{f04ad}";
pub const np_next_ascii = ">|";

/// Rust's floor for a clipped left chip.
pub const min_left_chip: u16 = 3;
/// Cells kept between the lanes before the left one is clipped.
pub const lane_gap: u16 = 4;

/// One chip.
pub const Seg = struct {
    text: []const u8,
    fg: Color,
    bg: Color,
    bold: bool = false,
    /// The `.statusline_seg` payload; null registers nothing.
    hit: ?u32 = null,
    /// A run after `text` in its own foreground — the coverage delta's
    /// tier colour — then `tail` in `fg` again. The three paint as one
    /// pill on `bg`.
    accent: ?Accent = null,
    tail: []const u8 = "",
    /// A transient chip's short form (the jobs chip's ` ✗ tests `): what
    /// it becomes, before anything on the left is clipped, when the two
    /// lanes do not fit — the file name wins the width, not a status that
    /// will be gone in ten seconds.
    short: ?[]const u8 = null,

    /// `underline` marks the run (the ticker's active account letter).
    /// `bg` gives the run a ground of its own inside the pill.
    pub const Accent = struct { text: []const u8, fg: Color, bg: ?Color = null, underline: bool = false };

    pub fn init(text: []const u8, fg: Color, bg: Color) Seg {
        return .{ .text = text, .fg = fg, .bg = bg };
    }

    pub fn withHit(s: Seg, id: u32) Seg {
        var out = s;
        out.hit = id;
        return out;
    }

    pub fn strong(s: Seg) Seg {
        var out = s;
        out.bold = true;
        return out;
    }

    fn style(s: Seg) Style {
        return .{ .fg = s.fg, .bg = s.bg, .bold = s.bold };
    }

    fn cols(s: Seg, ui: Ui) u16 {
        var w = ui.width(s.text);
        if (s.accent) |a| w += ui.width(a.text);
        return w + ui.width(s.tail);
    }
};

pub const Info = struct {
    left: []const Seg = &.{},
    right: []const Seg = &.{},
    /// A vim chord in progress (`d`, `2d`, `"a`), centred in the gap.
    middle: ?[]const u8 = null,
};

/// What the mode chip says about where the keys go — the one place the
/// editing mode is read for paint. `tree` / `view` / `edit` / `panel` are
/// the standard handler's context labels; `command` is an open `:` line,
/// either the app's own or a buffer's; the rest are vim's.
pub const ModeKind = enum { normal, insert, visual, replace, edit, view, tree, panel, command };

/// The mode chip's ground (NvChad's `st_modes`).
pub fn modeBg(t: *const Theme, kind: ModeKind) Color {
    return switch (kind) {
        .normal => t.mode_normal.bg,
        .insert => t.mode_insert.bg,
        .visual => t.mode_visual.bg,
        .replace => t.mode_replace.bg,
        .edit => t.mode_edit.bg,
        .tree => t.palette.blue,
        .view, .panel => t.palette.cyan,
        // The `:` line's own colour: the bottom row paints the line in
        // `warn_fg` (`ui/cmdline_bar.zig`), so the chip that names it
        // carries the same one rather than inventing a ninth.
        .command => t.warn_fg.fg,
    };
}

/// `123B`, `4.2K`, `12M` — a buffer's size for its chip.
pub fn formatByteSize(buf: []u8, bytes: usize) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
    const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
    if (kb < 10.0) return std.fmt.bufPrint(buf, "{d:.1}K", .{kb}) catch "?";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buf, "{d}K", .{bytes / 1024}) catch "?";
    const mb = kb / 1024.0;
    if (mb < 10.0) return std.fmt.bufPrint(buf, "{d:.1}M", .{mb}) catch "?";
    return std.fmt.bufPrint(buf, "{d}M", .{bytes / (1024 * 1024)}) catch "?";
}

// ─── measuring ───────────────────────────────────────────────────────────

fn arrowsOn(ui: Ui) bool {
    return !ui.ascii;
}

/// The left lane's cells: each chip, then an arrow where the next
/// ground differs (the lane's own ground after the last chip).
fn leftWidth(ui: Ui, segs: []const Seg, ground: Color) u16 {
    var w: u16 = 0;
    for (segs, 0..) |s, i| {
        w += s.cols(ui);
        const next = if (i + 1 < segs.len) segs[i + 1].bg else ground;
        if (arrowsOn(ui) and !Color.eql(next, s.bg)) w += 1;
    }
    return w;
}

/// The right lane's cells: an arrow before each chip whose ground
/// differs from the one before it (the lane's ground before the first).
fn rightWidth(ui: Ui, segs: []const Seg, ground: Color) u16 {
    var w: u16 = 0;
    var prev = ground;
    for (segs) |s| {
        if (arrowsOn(ui) and !Color.eql(prev, s.bg)) w += 1;
        w += s.cols(ui);
        prev = s.bg;
    }
    return w;
}

/// The lanes after the overflow rule: the left chips (one perhaps
/// clipped); the right lane is always whole.
const Fitted = struct { left: []const Seg, right: []const Seg };

fn fit(ui: Ui, width: u16, info: Info, ground: Color) Fitted {
    const right = shortened(ui, width, info, ground);
    return .{ .left = clipLeft(ui, width, info.left, rightWidth(ui, right, ground), ground), .right = right };
}

/// The right lane, its transient chips in their `short` form when the
/// left lane would otherwise be clipped. A copy on the arena; OOM keeps
/// the lane as given.
fn shortened(ui: Ui, width: u16, info: Info, ground: Color) []const Seg {
    var any = false;
    for (info.right) |s| {
        if (s.short != null) any = true;
    }
    if (!any) return info.right;
    var left_cols: u16 = 0;
    for (info.left) |s| left_cols += s.cols(ui);
    if (left_cols + lane_gap + rightWidth(ui, info.right, ground) <= width) return info.right;
    const copy = ui.arena.dupe(Seg, info.right) catch return info.right;
    for (copy) |*s| if (s.short) |sh| {
        s.text = sh;
        s.accent = null;
        s.tail = "";
        s.short = null;
    };
    return copy;
}

/// Rust's rule: the longest left chip gives way to the right lane plus
/// the gap, down to three cells. A clipped copy lives on the arena; OOM
/// keeps the lane as given and the paint clips it.
fn clipLeft(ui: Ui, width: u16, segs: []const Seg, right_w: u16, ground: Color) []const Seg {
    _ = ground;
    var left_cols: u16 = 0;
    var longest: ?usize = null;
    var longest_cols: u16 = 0;
    for (segs, 0..) |s, i| {
        const c = s.cols(ui);
        left_cols += c;
        if (longest == null or c > longest_cols) {
            longest = i;
            longest_cols = c;
        }
    }
    const avail = width -| (right_w + lane_gap);
    if (left_cols <= avail) return segs;
    const idx = longest orelse return segs;
    const overshoot = left_cols - avail;
    const target = @max(longest_cols -| overshoot, min_left_chip);
    if (target >= longest_cols) return segs;
    const copy = ui.arena.dupe(Seg, segs) catch return segs;
    copy[idx].text = ui.clipStr(copy[idx].text, target);
    return copy;
}

// ─── painting ────────────────────────────────────────────────────────────

/// Paints one chip at `x` and registers its hit; returns the cells used.
fn paintSeg(ui: Ui, x: u16, y: u16, max_w: u16, s: Seg) u16 {
    var used = ui.putStr(x, y, max_w, s.text, s.style());
    if (s.accent) |a| {
        var st = s.style();
        st.fg = a.fg;
        if (a.underline) st.ul_style = .single;
        if (a.bg) |bg| st.bg = bg;
        used += ui.putStr(x + used, y, max_w -| used, a.text, st);
    }
    used += ui.putStr(x + used, y, max_w -| used, s.tail, s.style());
    if (s.hit) |id| ui.hit(Rect.init(x, y, used, 1), .{ .statusline_seg = id });
    return used;
}

pub fn draw(ui: Ui, area: Rect, info: Info) void {
    const t = ui.theme;
    ui.fill(area, t.statusline);
    if (area.isEmpty()) return;
    const y = area.y;
    const ground = t.statusline.bg;
    const right_edge = area.right();
    const lanes = fit(ui, area.w, info, ground);
    const arrows = arrowsOn(ui);
    const pl_right = if (ui.ascii) pl_right_ascii else pl_right_nerd;
    const pl_left = if (ui.ascii) pl_left_ascii else pl_left_nerd;

    // ── left, with an arrow after each chip whose ground changes ──
    var x = area.x;
    for (lanes.left, 0..) |s, i| {
        x += paintSeg(ui, x, y, right_edge -| x, s);
        const next = if (i + 1 < lanes.left.len) lanes.left[i + 1].bg else ground;
        if (arrows and !Color.eql(next, s.bg)) {
            x += ui.putStr(x, y, right_edge -| x, pl_right, .{ .fg = s.bg, .bg = next });
        }
    }
    const left_end = x;

    // ── right, from where the lane starts, an arrow before a new ground;
    // a lane too wide for what the left leaves follows it and is cut at
    // the edge, as Rust's one line of spans is ──
    const right_w = rightWidth(ui, lanes.right, ground);
    var rx = @max(left_end, right_edge -| right_w);
    var prev = ground;
    for (lanes.right) |s| {
        // An arrow is the hand-off INTO its chip: when the edge would
        // leave the chip nothing past its leading blanks, the row would
        // end on a dangling arrow (the round-7 hunt's 80x24 row), so the
        // arrow goes with its chip.
        const lead: u16 = @intCast(std.mem.indexOfNone(u8, s.text, " ") orelse s.text.len);
        const arrow_w: u16 = if (arrows and !Color.eql(prev, s.bg)) 1 else 0;
        if (rx + arrow_w + @min(lead + 1, s.cols(ui)) > right_edge) break;
        if (arrows and !Color.eql(prev, s.bg)) {
            rx += ui.putStr(rx, y, right_edge -| rx, pl_left, .{ .fg = s.bg, .bg = prev });
        }
        rx += paintSeg(ui, rx, y, right_edge -| rx, s);
        prev = s.bg;
    }

    // ── middle: the pending chord, centred in what is left ──
    const mid_start = left_end;
    const mid_end = @max(left_end, right_edge -| right_w);
    if (info.middle) |m| if (m.len > 0 and mid_end > mid_start) {
        const avail = mid_end - mid_start;
        const text = ui.clipStr(ui.fmt(" {s} ", .{m}), avail);
        const w = ui.width(text);
        const mx = mid_start + (avail - w) / 2;
        _ = ui.putStr(mx, y, avail, text, .{ .fg = t.palette.yellow, .bg = ground, .bold = true });
    };
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const P = Theme.default.palette;

/// The fixture screen's chips, as the Rust editor painted them at
/// 120×40 (`docs/ui-spec/rust-120x40.txt`, row 38) — minus the cut
/// now-playing cluster, which `withCluster` puts back for the overflow
/// rows that Rust laid out with it present.
const spec_left = [_]Seg{
    Seg.init(" TREE ", P.bg_darker, P.blue).strong().withHit(seg_mode),
    Seg.init(" " ++ branch_glyph ++ " main  " ++ added_glyph ++ " 1 ", P.green, P.bg2).withHit(seg_app_base),
    Seg.init(" [no file] ", P.comment, P.statusline),
};
const spec_right = [_]Seg{
    .{ .text = " " ++ coverage_glyph ++ " F 57%", .fg = P.bg_darker, .bg = P.teal, .accent = .{ .text = " ▲1.0", .fg = P.green }, .tail = " ", .hit = seg_app_base + 1 },
    Seg.init(" WRAP ", P.bg_darker, P.purple).withHit(seg_app_base + 2),
    Seg.init(" " ++ bell_glyph ++ " ", P.comment, P.bg2).withHit(seg_app_base + 3),
    Seg.init(" 23:58 ", P.comment, P.bg2).withHit(seg_app_base + 4),
    Seg.init(folder_glyph ++ " ws ", P.blue, P.bg3).strong().withHit(seg_app_base + 5),
    Seg.init("  — ", P.bg_darker, P.blue).strong().withHit(seg_language),
};

/// The cut now-playing cluster: the mnml-baked Beatport mark and
/// nf-md-play_box_outline, as the Rust row had them.
fn withCluster(arena: std.mem.Allocator) ![]Seg {
    const out = try arena.alloc(Seg, spec_right.len + 2);
    out[0] = spec_right[0];
    out[1] = Seg.init(" " ++ cluster_brand_glyph ++ " ", Theme.rgb(0), Theme.rgb(0xa6e22e));
    out[2] = Seg.init(cluster_play_glyph ++ " ", Theme.rgb(0), Theme.rgb(0xa6e22e));
    @memcpy(out[3..], spec_right[1..]);
    return out;
}

// The rows below are the Rust dumps with the arrows written as their
// codepoints, so the glyph audit reads each as a test of the row.
const row_left = " TREE " ++ pl_right_nerd ++ " " ++ branch_glyph ++ " main  " ++ added_glyph ++ " 1 " ++ pl_right_nerd ++ " [no file]";
const row_right = pl_left_nerd ++ " " ++ coverage_glyph ++ " F 57% ▲1.0 " ++ pl_left_nerd ++ " WRAP " ++ pl_left_nerd ++ " " ++ bell_glyph ++ "  23:58 " ++ pl_left_nerd ++ folder_glyph ++ " ws " ++ pl_left_nerd ++ "  —";
const row_cluster = pl_left_nerd ++ " " ++ cluster_brand_glyph ++ " " ++ cluster_play_glyph ++ " ";
const row_tail = pl_left_nerd ++ " WRAP " ++ pl_left_nerd ++ " " ++ bell_glyph ++ "  23:58 " ++ pl_left_nerd ++ folder_glyph ++ " ws " ++ pl_left_nerd ++ "  —";

test "row 38 at 120 columns is the Rust dump, less the cut chips: arrows hand the colour over, same-ground neighbours fuse" {
    var f = try Fixture.init(120, 1);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .left = &spec_left, .right = &spec_right });
    try f.expectRow(0, row_left ++ " " ** 45 ++ row_right);
    // The arrow after TREE is blue on bg2; after the branch, bg2 on the ground.
    try testing.expect(Color.eql(f.style(6, 0).fg, P.blue));
    try testing.expect(Color.eql(f.style(6, 0).bg, P.bg2));
    try testing.expect(Color.eql(f.style(20, 0).fg, P.bg2));
    try testing.expect(Color.eql(f.style(20, 0).bg, P.statusline));
    // The bell and the clock share bg2: no arrow between them.
    try testing.expect(Color.eql(f.style(100, 0).bg, P.bg2));
    try testing.expect(Color.eql(f.style(103, 0).bg, P.bg2));
    // The coverage delta is tinted; the rest of the chip is not.
    try testing.expect(Color.eql(f.style(82, 0).fg, P.bg_darker));
    try testing.expect(Color.eql(f.style(87, 0).fg, P.green));
    try testing.expect(f.style(1, 0).bold);
    // With the cluster back, the row is the dump cell for cell.
    var g = try Fixture.init(120, 1);
    defer g.deinit();
    const ui = g.ui();
    draw(ui, g.full(), .{ .left = &spec_left, .right = try withCluster(ui.arena) });
    try g.expectRow(0, row_left ++ " " ** 39 ++ pl_left_nerd ++ " " ++ coverage_glyph ++ " F 57% ▲1.0 " ++ row_cluster ++ row_tail);
}

test "a right lane cut at the edge never ends on an arrow: the arrow goes with the chip it leads into" {
    // Round-7 hunt, 80x24: the cut landed just before the language chip
    // and the row ended on its arrow. Every width that cuts the lane.
    const right = [_]Seg{
        Seg.init(" 17:50 ", P.comment, P.bg2),
        Seg.init(folder_glyph ++ " ws ", P.blue, P.bg3).strong(),
        Seg.init(" zig ", P.bg_darker, P.blue).strong(),
    };
    const left = [_]Seg{Seg.init(" EDIT ", P.bg_darker, P.green).strong()};
    var cut_on_arrow_seen = false;
    var w: u16 = 12;
    while (w < 40) : (w += 1) {
        var f = try Fixture.init(w, 1);
        defer f.deinit();
        draw(f.ui(), f.full(), .{ .left = &left, .right = &right });
        // The last arrow on the row must be followed by something
        // other than blanks: an arrow then only its chip's padding
        // reads as the same dangle.
        var x: u16 = w;
        var arrow_at: ?u16 = null;
        while (x > 0) {
            x -= 1;
            if (std.mem.eql(u8, f.cell(x, 0).char.grapheme, pl_left_nerd)) {
                arrow_at = x;
                break;
            }
        }
        if (arrow_at) |ax| {
            var shown = false;
            var k = ax + 1;
            while (k < w) : (k += 1) {
                const g = f.cell(k, 0).char.grapheme;
                if (g.len > 0 and !std.mem.eql(u8, g, " ")) shown = true;
            }
            if (!shown) {
                std.debug.print("width {d} ends on an arrow\n", .{w});
                cut_on_arrow_seen = true;
            }
        }
    }
    try testing.expect(!cut_on_arrow_seen);
}

test "every chip is a hit over exactly its cells; arrows and the gap are not" {
    var f = try Fixture.init(120, 1);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .left = &spec_left, .right = &spec_right });
    try testing.expectEqual(seg_mode, f.hits.at(0, 0).?.statusline_seg);
    try testing.expectEqual(seg_mode, f.hits.at(5, 0).?.statusline_seg);
    try testing.expect(f.hits.at(6, 0) == null);
    try testing.expectEqual(seg_app_base, f.hits.at(7, 0).?.statusline_seg);
    try testing.expectEqual(seg_app_base, f.hits.at(19, 0).?.statusline_seg);
    try testing.expect(f.hits.at(20, 0) == null);
    try testing.expect(f.hits.at(25, 0) == null); // [no file] carries no hit
    try testing.expect(f.hits.at(60, 0) == null);
    try testing.expectEqual(seg_app_base + 1, f.hits.at(80, 0).?.statusline_seg);
    try testing.expectEqual(seg_app_base + 2, f.hits.at(93, 0).?.statusline_seg);
    try testing.expectEqual(seg_app_base + 3, f.hits.at(100, 0).?.statusline_seg);
    try testing.expectEqual(seg_app_base + 4, f.hits.at(106, 0).?.statusline_seg);
    try testing.expectEqual(seg_app_base + 5, f.hits.at(111, 0).?.statusline_seg);
    try testing.expectEqual(seg_language, f.hits.at(119, 0).?.statusline_seg);
}

/// The Rust editor's screen at 80×24 on the same fixture
/// (`docs/ui-spec/rust-80x24.txt`, row 22): its coverage ticker was on
/// the code half and its clock read 09:36 when it was dumped; the two
/// are the same width as the 120×40 spec's, so they are rewritten to
/// those before the compare.
const spec_80x24 = @embedFile("ui_spec_rust_80x24");

fn specRow80(arena: std.mem.Allocator) ![]const u8 {
    var it = std.mem.splitScalar(u8, spec_80x24, '\n');
    var i: usize = 0;
    const row = while (it.next()) |line| : (i += 1) {
        if (i == 22) break line;
    } else return error.NoRow22;
    const coverage = try std.mem.replaceOwned(u8, arena, row, "C 74% ±0.0", "F 57% ▲1.0");
    return std.mem.replaceOwned(u8, arena, coverage, "09:36", "23:58");
}

test "at 80 columns the longest left chip is clipped to make room, as Rust clipped it" {
    var f = try Fixture.init(80, 1);
    defer f.deinit();
    const ui = f.ui();
    draw(ui, f.full(), .{ .left = &spec_left, .right = try withCluster(ui.arena) });
    // The Rust 80×24 row on the same fixture: the branch chip lost its counts.
    const rust = try specRow80(ui.arena);
    try f.expectRow(0, std.mem.trimEnd(u8, rust, " "));
    try testing.expect(std.mem.indexOf(u8, rust, " main …" ++ pl_right_nerd) != null);
    // The clipped chip is still the branch's hit, over its new width.
    try testing.expectEqual(seg_app_base, f.hits.at(7, 0).?.statusline_seg);
    try testing.expectEqual(seg_app_base, f.hits.at(15, 0).?.statusline_seg);
    try testing.expect(f.hits.at(16, 0) == null);
}

// At 60 columns Rust paints the whole right lane from where it would
// start and lets the screen's edge cut it — the dump on the same
// fixture ends `WRAP    09:36`, the workspace and the language gone.
// Zig drops inner chips instead, so the far-right ones always show.
test "a transient chip takes its short form before the left lane is clipped; with room, it stays whole" {
    const left = [_]Seg{
        Seg.init(" VIEW ", P.bg_darker, P.blue).strong(),
        Seg.init(" CalcTests.cs ", P.fg, P.statusline),
    };
    var jobs = Seg.init(" ✗ tests: 1 failed, 1 passed ", P.comment, P.bg2);
    jobs.short = " ✗ tests ";
    const right = [_]Seg{ jobs, Seg.init(" 23:58 ", P.comment, P.bg2) };
    // 50 columns: the whole chip would clip the file name — it shrinks.
    var f = try Fixture.init(50, 1);
    defer f.deinit();
    draw(f.ui(), f.full(), .{ .left = &left, .right = &right });
    var buf: [512]u8 = undefined;
    const row = f.row(0, &buf);
    try testing.expect(std.mem.indexOf(u8, row, " CalcTests.cs ") != null);
    try testing.expect(std.mem.indexOf(u8, row, " ✗ tests ") != null);
    try testing.expect(std.mem.indexOf(u8, row, "1 failed") == null);
    // 120 columns: room for both, the words stay.
    var g = try Fixture.init(120, 1);
    defer g.deinit();
    draw(g.ui(), g.full(), .{ .left = &left, .right = &right });
    try testing.expect(std.mem.indexOf(u8, g.row(0, &buf), "✗ tests: 1 failed, 1 passed") != null);
}

test "at 60 columns the left lane is at its floor and the screen edge cuts the right lane, as the Rust row is cut" {
    var f = try Fixture.init(60, 1);
    defer f.deinit();
    const ui = f.ui();
    draw(ui, f.full(), .{ .left = &spec_left, .right = try withCluster(ui.arena) });
    // The Rust editor at 60×24 on the fixture (`tools/ui-diff.sh`,
    // 2026-09-07): the branch is its glyph and `…`, the lanes touch, the
    // clock is the last whole chip; the workspace and the language are
    // past the edge.
    try f.expectRow(0, " TREE " ++ pl_right_nerd ++ " " ++ branch_glyph ++ "…" ++ pl_right_nerd ++ " [no file] " ++ pl_left_nerd ++ " " ++ coverage_glyph ++ " F 57% ▲1.0 " ++ row_cluster ++ pl_left_nerd ++ " WRAP " ++ pl_left_nerd ++ " " ++ bell_glyph ++ "  23:58");
    try testing.expectEqual(seg_app_base, f.hits.at(8, 0).?.statusline_seg);
    try testing.expect(f.hits.at(10, 0) == null);
    try testing.expectEqual(seg_app_base + 1, f.hits.at(24, 0).?.statusline_seg);
    try testing.expectEqual(seg_app_base + 4, f.hits.at(58, 0).?.statusline_seg);
    // Narrower still: the right lane starts at the left lane's end and
    // the edge takes the rest — an arrow with no room for its chip goes
    // with it rather than dangle; then the row itself clips.
    var g = try Fixture.init(24, 1);
    defer g.deinit();
    draw(g.ui(), g.full(), .{ .left = &spec_left, .right = &spec_right });
    try g.expectRow(0, " TREE " ++ pl_right_nerd ++ " " ++ branch_glyph ++ "…" ++ pl_right_nerd ++ " [no file]");
    var h = try Fixture.init(10, 1);
    defer h.deinit();
    draw(h.ui(), h.full(), .{ .left = &spec_left, .right = &spec_right });
    try h.expectRow(0, " TREE " ++ pl_right_nerd ++ " " ++ branch_glyph ++ "…");
    draw(h.ui(), Rect.empty, .{ .left = &spec_left, .right = &spec_right });
}

test "a right lane wider than the row follows the clipped left lane in order: the position stays, the far end goes" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const left = [_]Seg{ Seg.init(" EDIT ", P.bg_darker, P.green).strong(), Seg.init(" notes.txt ", P.fg, P.statusline) };
    const right = [_]Seg{
        Seg.init(" 11B ", P.comment, P.bg2),
        Seg.init(" Ln 2/2 Col 3 ", P.fg, P.bg2).withHit(seg_position),
        Seg.init(" " ++ bell_glyph ++ " ", P.comment, P.bg2),
        Seg.init(" 23:58 ", P.comment, P.bg2),
        Seg.init(folder_glyph ++ " tmp ", P.blue, P.bg3).strong(),
        Seg.init("  — ", P.bg_darker, P.blue).strong(),
    };
    draw(f.ui(), f.full(), .{ .left = &left, .right = &right });
    // The name pays down to its floor; the right lane (37 with its
    // arrows) then runs from column 10 and the edge takes the workspace
    // and the language whole.
    try f.expectRow(0, " EDIT " ++ pl_right_nerd ++ " n…" ++ pl_left_nerd ++ " 11B  Ln 2/2 Col 3  " ++ bell_glyph ++ "  23:58");
    try testing.expectEqual(seg_position, f.hits.at(20, 0).?.statusline_seg);
    try testing.expect(f.hits.at(39, 0) == null);
}

test "--ascii: no arrows, the chips meet edge to edge, the ellipsis is dots" {
    var f = try Fixture.init(120, 1);
    defer f.deinit();
    f.ascii = true;
    draw(f.ui(), f.full(), .{ .left = &spec_left, .right = &spec_right });
    try f.expectRow(0, " TREE  " ++ branch_glyph ++ " main  " ++ added_glyph ++ " 1  [no file]" ++ " " ** 52 ++ " " ++ coverage_glyph ++ " F 57% ▲1.0  WRAP  " ++ bell_glyph ++ "  23:58 " ++ folder_glyph ++ " ws   —");
    var g = try Fixture.init(70, 1);
    defer g.deinit();
    g.ascii = true;
    draw(g.ui(), g.full(), .{ .left = &spec_left, .right = &spec_right });
    // 70 - 39 - 4 = 27 for a 30-cell left lane: the branch chip clips to 10.
    try g.expectRow(0, " TREE  " ++ branch_glyph ++ " main... [no file]      " ++ coverage_glyph ++ " F 57% ▲1.0  WRAP  " ++ bell_glyph ++ "  23:58 " ++ folder_glyph ++ " ws   —");
}

test "the pending chord sits centred in the gap, bold yellow; a two-seg mode chip fuses on one ground" {
    var f = try Fixture.init(60, 1);
    defer f.deinit();
    const left = [_]Seg{
        Seg.init(" " ++ vim_glyph ++ " ", P.orange, P.red).strong().withHit(seg_mode),
        Seg.init("NORMAL ", P.bg_darker, P.red).strong().withHit(seg_mode),
        Seg.init(" notes.txt ● ", P.fg, P.statusline).withHit(seg_file),
    };
    const right = [_]Seg{Seg.init(" Ln 3/12 Col 7 ", P.fg, P.bg2).withHit(seg_position)};
    draw(f.ui(), f.full(), .{ .left = &left, .right = &right, .middle = "2d" });
    // 60 - 24 - 16 = 20 cells of gap; ` 2d ` sits 8 in from either side.
    try f.expectRow(0, " " ++ vim_glyph ++ " NORMAL " ++ pl_right_nerd ++ " notes.txt ●          2d         " ++ pl_left_nerd ++ " Ln 3/12 Col 7");
    try testing.expect(Color.eql(f.style(34, 0).fg, P.yellow));
    try testing.expect(f.style(34, 0).bold);
    // One arrow after the label, none between the glyph and the label.
    try testing.expect(Color.eql(f.style(2, 0).bg, P.red));
    try testing.expect(Color.eql(f.style(9, 0).bg, P.red));
    try testing.expectEqual(seg_mode, f.hits.at(1, 0).?.statusline_seg);
    try testing.expectEqual(seg_mode, f.hits.at(8, 0).?.statusline_seg);
    try testing.expectEqual(seg_file, f.hits.at(12, 0).?.statusline_seg);
    try testing.expectEqual(seg_position, f.hits.at(50, 0).?.statusline_seg);
    try testing.expect(f.hits.at(34, 0) == null);
}

test "mode grounds follow the theme roles; byte sizes pick their unit" {
    const t = &Theme.default;
    try testing.expect(Color.eql(modeBg(t, .normal), t.mode_normal.bg));
    try testing.expect(Color.eql(modeBg(t, .insert), t.palette.green));
    try testing.expect(Color.eql(modeBg(t, .visual), t.palette.purple));
    try testing.expect(Color.eql(modeBg(t, .replace), t.palette.orange));
    try testing.expect(Color.eql(modeBg(t, .tree), t.palette.blue));
    try testing.expect(Color.eql(modeBg(t, .view), t.palette.cyan));
    try testing.expect(Color.eql(modeBg(t, .edit), t.palette.green));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("13B", formatByteSize(&buf, 13));
    try testing.expectEqualStrings("1.5K", formatByteSize(&buf, 1536));
    try testing.expectEqualStrings("12K", formatByteSize(&buf, 12 * 1024 + 7));
    try testing.expectEqualStrings("2.5M", formatByteSize(&buf, 2621440));
    try testing.expectEqualStrings("40M", formatByteSize(&buf, 40 * 1024 * 1024 + 1));
}
