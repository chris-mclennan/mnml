//! MnmlSymbols: the face mnml's own block is drawn from, and the one
//! command that builds it.
//!
//! mnml paints six marks that exist in no font anywhere — the Claude
//! and Codex product marks, the two tree connectors, the terminal icon
//! and the unfocused pane's hollow cursor — so it carries them itself,
//! at codepoints in the private plane nothing else claims
//! (`U+F1B00–U+F20FF`). A terminal renders them by
//! routing that range at a font named `MnmlSymbols`; ghostty spells
//! that `font-codepoint-map` (`ghostty_config.zig` reads it back).
//!
//! Two builds come out of here:
//!
//!   - the shipped face, `share/mnml/fonts/MnmlSymbols.ttf`, built by
//!     `zig build` from the SVGs under `data/glyphs/` (`tools/
//!     build_font.zig` is the `zig build font` entry point);
//!   - the user's own, `<data root>/fonts/MnmlSymbols.ttf`, which the
//!     same code writes when the terminal icon or the Claude icon is
//!     set to a custom SVG (`Sources` names those two slots). Same
//!     family name, same codepoints — only the replaced mark differs —
//!     so a terminal already routed at `MnmlSymbols` picks the new one
//!     up with nothing to reconfigure.
//!
//! `merge` is the third path: the face this build bakes folded INTO an
//! already-installed one, so `run.sh install-font` keeps whatever
//! codepoints that file carries which this repo has no source for.
//!
//! The two connectors and the hollow cursor are drawn here rather than
//! imported: they are rectangles that have to touch the cell edge
//! exactly, and an SVG rasterised at those coordinates leaves hairline
//! gaps between rows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const svg = @import("svg.zig");
const ttf = @import("ttf.zig");
const data = @import("data");

pub const family = "MnmlSymbols";
pub const version = "1.0";
/// The file name both the shipped face and the user's build carry.
pub const file_name = "MnmlSymbols.ttf";
/// `<data root>/fonts/` — where a custom build lands.
pub const user_dir = "fonts";

/// mnml's codepoints, all inside its own private block.
pub const claude: u21 = 0xF1E00;
pub const codex: u21 = 0xF1E01;
/// The Anthropic spark — the mark Claude Code wore before the figure
/// took `claude`'s codepoint, kept as the alternate `ui.claude_mark`
/// offers. One along, so the face carries both and the choice is a
/// repaint rather than a re-bake (`ui/bufferline.zig`'s `spark_cp`,
/// which is the chrome's copy of this number).
pub const claude_spark: u21 = 0xF1E02;
pub const tree_vertical: u21 = 0xF1F04;
pub const tree_corner: u21 = 0xF1F05;
/// The terminal mark — Ghostty's ghost by default, whatever SVG the
/// user names when the icon is set to custom. One codepoint either
/// way, so the routing never has to change.
pub const terminal: u21 = 0xF2000;
/// The stand-in cursor an UNFOCUSED pty pane paints: a hollow block
/// that fills the whole cell, which is the shape ghostty draws in
/// pixels for a surface that is not the focused one. Drawn here for
/// the same reason the connectors are — it has to meet the cell edge
/// exactly, and nothing in Unicode is a full-cell outline.
pub const cursor_hollow: u21 = 0xF2001;

pub const Error = svg.Error || ttf.Error;

/// One SVG to bake: where it goes and what it is called.
pub const Spec = struct {
    codepoint: u21,
    name: []const u8,
    /// The SVG's bytes — embedded for the shipped marks, read off disk
    /// for a custom one.
    source: []const u8,
    fit: ttf.Fit = .{},
};

/// The three marks that come from SVGs, embedded so a build needs no
/// files beside it. `data/glyphs/` holds the sources — the main module
/// is rooted at `src/` and cannot reach a sibling directory, so they
/// come through the `data` module as everything else there does.
pub const claude_svg = data.claude_svg;
pub const claude_spark_svg = data.claude_spark_svg;
pub const codex_svg = data.codex_svg;
pub const ghostty_svg = data.ghostty_svg;

/// The art behind the two marks a user may replace. Each field
/// defaults to the shipped drawing, so a build that only swaps one
/// names only that one — and a bake of either keeps the other, which is
/// the whole reason this is a struct and not two entry points.
pub const Sources = struct {
    /// `U+F1E00`, the Claude Code figure (`ui.claude_mark = .custom`).
    claude: []const u8 = claude_svg,
    /// `U+F2000`, Ghostty's ghost (`ui.terminal_glyph = .custom`).
    terminal: []const u8 = ghostty_svg,
};

/// The shipped set, in codepoint order, with `src`'s art in the two
/// replaceable slots. Both Claude marks are baked: which one the chrome
/// paints is `ui.claude_mark`'s to say, and a face that carried only
/// one would turn the other into tofu. The spark is not replaceable —
/// it is Anthropic's mark, offered as the alternate rather than as a
/// slot.
pub fn defaultSpecs(src: Sources) [4]Spec {
    return .{
        .{ .codepoint = claude, .name = "claude-mark", .source = src.claude },
        .{ .codepoint = codex, .name = "codex-mark", .source = codex_svg },
        .{ .codepoint = claude_spark, .name = "claude-spark", .source = claude_spark_svg },
        .{ .codepoint = terminal, .name = "terminal-mark", .source = src.terminal },
    };
}

// ─── the connectors ─────────────────────────────────────────────────────

// JetBrainsMono's box-drawing metrics, so mnml's `│` lines up with the
// `│` of the font beside it: a 100-unit stroke in the x band 250–350,
// spanning y −400…1120 so one row's vertical touches the next one's.
// mnml shifts the band right by 100 to sit under the tree's chevron.
const stroke: f64 = 100;
const band_left: f64 = 250 + 100;
const v_top: f64 = 1120;
const v_bottom: f64 = -400;
// The corner's arms are narrower than the plain bar (70 rather than
// 100) and centred on the same axis: at a terminal's ppem the
// rasteriser was snapping a 100-unit arm one pixel wider than the bar
// above it, and the L read heavier than the line it continued.
const arm: f64 = 70;
const elbow_top: f64 = 620;
const horiz_right: f64 = 620 + (band_left - 250);

/// A closed rectangle, wound clockwise in the y-up em square — the
/// direction TrueType fills.
fn rect(arena: Allocator, x0: f64, y0: f64, x1: f64, y1: f64) Allocator.Error!svg.Contour {
    const p = try arena.alloc(svg.Point, 4);
    p[0] = .{ .x = x0, .y = y1 };
    p[1] = .{ .x = x1, .y = y1 };
    p[2] = .{ .x = x1, .y = y0 };
    p[3] = .{ .x = x0, .y = y0 };
    return p;
}

fn verticalContours(arena: Allocator) Allocator.Error![]const svg.Contour {
    const out = try arena.alloc(svg.Contour, 1);
    out[0] = try rect(arena, band_left, v_bottom, band_left + stroke, v_top);
    return out;
}

/// The L, as one contour traced clockwise from the top of its stem.
fn cornerContours(arena: Allocator) Allocator.Error![]const svg.Contour {
    const center = band_left + stroke / 2;
    const left = center - arm / 2;
    const right = center + arm / 2;
    const bottom = elbow_top - arm;
    const p = try arena.alloc(svg.Point, 6);
    p[0] = .{ .x = left, .y = v_top };
    p[1] = .{ .x = right, .y = v_top };
    p[2] = .{ .x = right, .y = elbow_top };
    p[3] = .{ .x = horiz_right, .y = elbow_top };
    p[4] = .{ .x = horiz_right, .y = bottom };
    p[5] = .{ .x = left, .y = bottom };
    const out = try arena.alloc(svg.Contour, 1);
    out[0] = p;
    return out;
}

// ─── the hollow cursor ──────────────────────────────────────────────────

// The same cell the connectors measure themselves against: the full
// advance across, and `v_bottom`…`v_top` down — so the outline sits on
// the cell's own edges rather than inside them, which is what makes it
// read as ghostty's rectangle and not as `□`, a small centred square.
// The stroke is the tree line's, so the two weigh the same on screen.
const cell_left: f64 = 0;
const cell_right: f64 = @floatFromInt(ttf.advance_width);

/// Four bars — left, right, bottom, top — each wound clockwise. They
/// overlap at the corners; TrueType fills by non-zero winding, so a
/// doubly-wound corner is still solid.
fn hollowContours(arena: Allocator) Allocator.Error![]const svg.Contour {
    const out = try arena.alloc(svg.Contour, 4);
    out[0] = try rect(arena, cell_left, v_bottom, cell_left + stroke, v_top);
    out[1] = try rect(arena, cell_right - stroke, v_bottom, cell_right, v_top);
    out[2] = try rect(arena, cell_left, v_bottom, cell_right, v_bottom + stroke);
    out[3] = try rect(arena, cell_left, v_top - stroke, cell_right, v_top);
    return out;
}

// ─── the build ──────────────────────────────────────────────────────────

/// The glyphs THIS build bakes: `specs` are the SVG-backed marks, and
/// the connectors, the hollow cursor and the blank space are added
/// here. Unsorted — the callers sort what they end up with.
fn ownGlyphs(arena: Allocator, specs: []const Spec) Error![]ttf.Glyph {
    var glyphs: std.ArrayListUnmanaged(ttf.Glyph) = .empty;
    for (specs) |s| {
        const img = try svg.parse(arena, s.source);
        try glyphs.append(arena, .{ .codepoint = s.codepoint, .name = s.name, .contours = try ttf.place(arena, img, s.fit) });
    }
    try glyphs.append(arena, .{ .codepoint = tree_vertical, .name = "tree-line-vertical", .contours = try verticalContours(arena) });
    try glyphs.append(arena, .{ .codepoint = tree_corner, .name = "tree-line-corner", .contours = try cornerContours(arena) });
    try glyphs.append(arena, .{ .codepoint = cursor_hollow, .name = "cursor-hollow", .contours = try hollowContours(arena) });
    // A blank U+0020: a rasteriser that refuses a font with no text
    // character at all will still load this one.
    try glyphs.append(arena, .{ .codepoint = ' ', .name = "space", .contours = ttf.Glyph.empty });
    return glyphs.toOwnedSlice(arena);
}

/// `cmap` format 4 wants its segments in codepoint order, and format 12
/// its groups; one sort serves both.
fn sortByCodepoint(glyphs: []ttf.Glyph) void {
    std.mem.sort(ttf.Glyph, glyphs, {}, struct {
        fn lt(_: void, a: ttf.Glyph, b: ttf.Glyph) bool {
            return a.codepoint < b.codepoint;
        }
    }.lt);
}

/// Every glyph the face carries, as bytes.
pub fn build(arena: Allocator, specs: []const Spec) Error![]u8 {
    const glyphs = try ownGlyphs(arena, specs);
    sortByCodepoint(glyphs);
    return ttf.build(arena, glyphs, family, version);
}

/// The face as it ships: every mark the repo's own drawing.
pub fn buildDefault(arena: Allocator) Error![]u8 {
    return buildWith(arena, .{});
}

/// The face with the user's art in whichever slots `src` names.
pub fn buildWith(arena: Allocator, src: Sources) Error![]u8 {
    const specs = defaultSpecs(src);
    return build(arena, &specs);
}

// ─── the merge ──────────────────────────────────────────────────────────

pub const MergeError = Error || ttf.ReadError;

/// What a merge did, for the line the installer prints.
pub const MergeReport = struct {
    /// Codepoints lifted from the installed face untouched.
    kept: usize = 0,
    /// Codepoints this build bakes that the installed face also had.
    replaced: usize = 0,
    /// Codepoints this build bakes that it did not have.
    added: usize = 0,
    /// Glyphs in the installed file that no cmap pointed at.
    stripped: usize = 0,
    /// Codepoints in the merged face.
    total: usize = 0,
};

/// This build's glyphs merged INTO an already-installed face.
///
/// The installed MnmlSymbols may carry codepoints this repo has no
/// source for — the Rust-era integration chips, spinners and marks
/// around `U+F1C03…F1F00` — and overwriting the file would silently
/// take them away. So every codepoint the installed face maps is
/// lifted back out and kept; the ones this build bakes replace theirs;
/// the ones it bakes and they lack are added; and an outline the
/// installed `cmap` does not point at is dropped, since nothing could
/// ever have rendered it.
pub fn merge(arena: Allocator, installed: []const u8, src: Sources, report: ?*MergeReport) MergeError![]u8 {
    const specs = defaultSpecs(src);
    const own = try ownGlyphs(arena, &specs);
    var mine: std.AutoHashMapUnmanaged(u21, void) = .empty;
    for (own) |g| try mine.put(arena, g.codepoint, {});

    var out: std.ArrayListUnmanaged(ttf.Glyph) = .empty;
    try out.appendSlice(arena, own);
    var r: MergeReport = .{ .added = own.len };
    var seen: std.AutoHashMapUnmanaged(u21, void) = .empty;
    for (try ttf.read(arena, installed)) |g| {
        // A face may map two codepoints at one glyph; each comes out as
        // its own entry, and a repeat is not a second keep.
        if (seen.contains(g.codepoint)) continue;
        try seen.put(arena, g.codepoint, {});
        if (mine.contains(g.codepoint)) {
            r.replaced += 1;
            r.added -= 1;
            continue;
        }
        try out.append(arena, g);
        r.kept += 1;
    }
    r.stripped = ttf.glyphCount(installed) -| (seen.count() + 1); // +1: .notdef
    r.total = out.items.len;
    if (report) |p| p.* = r;
    sortByCodepoint(out.items);
    return ttf.build(arena, out.items, family, version);
}

/// How big a custom SVG may be. An icon is a few KB; anything past
/// this is a map or a mistake, and every point of it would land in the
/// font.
pub const max_svg_bytes: usize = 512 * 1024;

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

/// Does the built face's `cmap` carry `cp`? Walks the table directory
/// to `cmap`, then its format-12 subtable — the one that can address a
/// codepoint above U+FFFF, which is where mnml's whole block lives.
/// Deliberately local: this module is also the `zig build font` tool's
/// root, which cannot reach into `src/app/`. `font_scan.cmapCodepoints`
/// reads the same table, and `app/terminal_glyph.zig` asserts through
/// it — so the two readers are held against one writer.
fn cmapHas(bytes: []const u8, cp: u21) bool {
    const n_tables = std.mem.readInt(u16, bytes[4..6], .big);
    var cmap: usize = 0;
    for (0..n_tables) |i| {
        const rec = bytes[12 + 16 * i ..][0..16];
        if (std.mem.eql(u8, rec[0..4], "cmap")) cmap = std.mem.readInt(u32, rec[8..12], .big);
    }
    if (cmap == 0) return false;
    const n_sub = std.mem.readInt(u16, bytes[cmap + 2 ..][0..2], .big);
    for (0..n_sub) |i| {
        const enc = bytes[cmap + 4 + 8 * i ..][0..8];
        const sub = cmap + std.mem.readInt(u32, enc[4..8], .big);
        if (std.mem.readInt(u16, bytes[sub..][0..2], .big) != 12) continue;
        const groups = std.mem.readInt(u32, bytes[sub + 12 ..][0..4], .big);
        for (0..groups) |g| {
            const row = bytes[sub + 16 + 12 * g ..][0..12];
            const lo = std.mem.readInt(u32, row[0..4], .big);
            const hi = std.mem.readInt(u32, row[4..8], .big);
            if (cp >= lo and cp <= hi) return true;
        }
    }
    return false;
}

test "the shipped face carries every codepoint mnml's own block needs, and nothing it was not asked for" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try buildDefault(arena);
    for ([_]u21{ claude, claude_spark, codex, tree_vertical, tree_corner, terminal, cursor_hollow, ' ' }) |cp| {
        errdefer std.debug.print("missing U+{X}\n", .{cp});
        try t.expect(cmapHas(bytes, cp));
    }
    try t.expect(!cmapHas(bytes, 0xF1B00));
    try t.expect(!cmapHas(bytes, 'A'));
}

test "a custom terminal SVG replaces the ghost at the same codepoint; the rest of the face is unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const custom = try buildWith(arena, .{ .terminal = "<svg viewBox=\"0 0 10 10\"><path d=\"M1 1 L9 1 L9 9 L1 9 Z\"/></svg>" });
    try t.expect(!std.mem.eql(u8, custom, try buildDefault(arena)));
    for ([_]u21{ claude, claude_spark, codex, tree_vertical, tree_corner, terminal }) |cp| try t.expect(cmapHas(custom, cp));
}

test "a broken SVG fails the build rather than baking an empty mark" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectError(error.NoViewBox, buildWith(arena, .{ .terminal = "<svg><path d=\"M0 0 L1 0 L1 1 Z\"/></svg>" }));
    try t.expectError(error.Empty, buildWith(arena, .{ .terminal = "<svg viewBox=\"0 0 1 1\"></svg>" }));
    try t.expectError(error.Malformed, buildWith(arena, .{ .terminal = "not an svg at all" }));
}

test "the connectors are the cell-edge rectangles the tree draws, not scaled art" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const v = try verticalContours(arena);
    try t.expectEqual(@as(usize, 1), v.len);
    // Full height, so one row's `│` meets the next one's.
    var min_y: f64 = 1e30;
    var max_y: f64 = -1e30;
    for (v[0]) |p| {
        min_y = @min(min_y, p.y);
        max_y = @max(max_y, p.y);
    }
    try t.expectEqual(v_bottom, min_y);
    try t.expectEqual(v_top, max_y);
    // Clockwise in y-up: TrueType's filled direction.
    try t.expect(svg.signedArea(v[0]) < 0);
    const c = try cornerContours(arena);
    try t.expectEqual(@as(usize, 6), c[0].len);
    try t.expect(svg.signedArea(c[0]) < 0);
    // The corner's stem shares the bar's axis, so the L continues the
    // line above it instead of stepping sideways.
    var stem_min: f64 = 1e30;
    var stem_max: f64 = -1e30;
    for (c[0]) |p| if (p.y > elbow_top) {
        stem_min = @min(stem_min, p.x);
        stem_max = @max(stem_max, p.x);
    };
    try t.expectApproxEqAbs(band_left + stroke / 2, (stem_min + stem_max) / 2, 0.001);
}

test "the hollow cursor spans the whole cell — each bar on its own edge" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = try hollowContours(arena);
    try t.expectEqual(@as(usize, 4), h.len);

    const Box = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
    // Each bar checked WHERE IT IS, not as part of the union: a bar
    // pulled off its edge still leaves the union spanning the cell, so
    // the union alone would not notice.
    const want = [_]Box{
        .{ .x0 = cell_left, .y0 = v_bottom, .x1 = cell_left + stroke, .y1 = v_top },
        .{ .x0 = cell_right - stroke, .y0 = v_bottom, .x1 = cell_right, .y1 = v_top },
        .{ .x0 = cell_left, .y0 = v_bottom, .x1 = cell_right, .y1 = v_bottom + stroke },
        .{ .x0 = cell_left, .y0 = v_top - stroke, .x1 = cell_right, .y1 = v_top },
    };
    for (h, want, 0..) |c, w, i| {
        errdefer std.debug.print("bar {d}\n", .{i});
        // Clockwise in y-up, like every other bar here: TrueType fills
        // the overlapping corners by winding rather than cancelling them.
        try t.expect(svg.signedArea(c) < 0);
        var b: Box = .{ .x0 = 1e30, .y0 = 1e30, .x1 = -1e30, .y1 = -1e30 };
        for (c) |p| {
            b.x0 = @min(b.x0, p.x);
            b.x1 = @max(b.x1, p.x);
            b.y0 = @min(b.y0, p.y);
            b.y1 = @max(b.y1, p.y);
        }
        try t.expectEqual(w, b);
    }
    // Hollow, not filled: the middle of the cell is inside no bar.
    const mid: svg.Point = .{ .x = (cell_left + cell_right) / 2, .y = (v_bottom + v_top) / 2 };
    for (h) |c| try t.expect(!svg.contains(c, mid));
}

/// The codepoints a built face maps, via the same format-12 walk
/// `cmapHas` does.
fn mappedCount(bytes: []const u8) usize {
    var n: usize = 0;
    var cp: u21 = 0;
    while (cp < 0x20) : (cp += 1) n += @intFromBool(cmapHas(bytes, cp));
    // The blocks these faces actually use, rather than all of Unicode.
    cp = 0x20;
    while (cp <= 0x7E) : (cp += 1) n += @intFromBool(cmapHas(bytes, cp));
    cp = 0xF1B00;
    while (cp <= 0xF20FF) : (cp += 1) n += @intFromBool(cmapHas(bytes, cp));
    return n;
}

test "merge: the installed face keeps its own codepoints, this build replaces and adds its own" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An "installed" face standing in for the user's: two codepoints
    // this repo has no source for (Rust-era chips), plus two it does.
    const box = try rect(arena, 100, 100, 500, 500);
    const one = [_]svg.Contour{box};
    const installed = try ttf.build(arena, &.{
        .{ .codepoint = ' ', .name = "space", .contours = ttf.Glyph.empty },
        .{ .codepoint = 0xF1C03, .name = "chip-a", .contours = &one },
        .{ .codepoint = 0xF1C04, .name = "chip-b", .contours = &one },
        .{ .codepoint = claude, .name = "old-claude", .contours = &one },
        .{ .codepoint = terminal, .name = "old-ghost", .contours = &one },
    }, family, version);

    var report: MergeReport = .{};
    const merged = try merge(arena, installed, .{}, &report);
    // Kept: the two chips. Replaced: space, claude, terminal — and
    // nothing else of this build's was in there, the spark included,
    // which is why it counts as added.
    try t.expectEqual(@as(usize, 2), report.kept);
    try t.expectEqual(@as(usize, 3), report.replaced);
    try t.expectEqual(@as(usize, 5), report.added);
    try t.expectEqual(@as(usize, 10), report.total);
    // Everything the installed face had is still addressable…
    for ([_]u21{ ' ', 0xF1C03, 0xF1C04, claude, terminal }) |cp| {
        errdefer std.debug.print("lost U+{X}\n", .{cp});
        try t.expect(cmapHas(merged, cp));
    }
    // …and everything this build bakes is too, the new one included.
    for ([_]u21{ claude, claude_spark, codex, tree_vertical, tree_corner, terminal, cursor_hollow }) |cp| {
        errdefer std.debug.print("missing U+{X}\n", .{cp});
        try t.expect(cmapHas(merged, cp));
    }
    // Replaced means replaced: the chip's plain box is NOT what the
    // terminal mark now carries.
    try t.expect(!std.mem.eql(u8, merged, installed));
}

test "merge: an outline no cmap points at does not survive" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const one = [_]svg.Contour{try rect(arena, 100, 100, 500, 500)};
    const installed = try ttf.build(arena, &.{
        .{ .codepoint = 0xF1C03, .name = "chip-a", .contours = &one },
        .{ .codepoint = 0xF1C04, .name = "chip-b", .contours = &one },
        .{ .codepoint = 0xF1C05, .name = "chip-c", .contours = &one },
    }, family, version);
    // Orphan the last one by shortening the format-12 group list: its
    // outline is still in `glyf`, but no codepoint reaches it. (Reaching
    // into the writer's own layout is fair here — it is the same file.)
    const orphaned = try arena.dupe(u8, installed);
    const cmap_off = blk: {
        const n = std.mem.readInt(u16, orphaned[4..6], .big);
        for (0..n) |i| {
            const rec = orphaned[12 + 16 * i ..][0..16];
            if (std.mem.eql(u8, rec[0..4], "cmap")) break :blk std.mem.readInt(u32, rec[8..12], .big);
        }
        return error.NoCmap;
    };
    const sub = cmap_off + std.mem.readInt(u32, orphaned[cmap_off + 4 + 8 + 4 ..][0..4], .big);
    try t.expectEqual(@as(u16, 12), std.mem.readInt(u16, orphaned[sub..][0..2], .big));
    const groups = std.mem.readInt(u32, orphaned[sub + 12 ..][0..4], .big);
    std.mem.writeInt(u32, orphaned[sub + 12 ..][0..4], groups - 1, .big);

    var report: MergeReport = .{};
    const merged = try merge(arena, orphaned, .{}, &report);
    try t.expectEqual(@as(usize, 1), report.stripped);
    try t.expect(cmapHas(merged, 0xF1C03));
    try t.expect(!cmapHas(merged, 0xF1C05));
    // The guarantee behind the number: every outline in the merged face
    // is reachable, so nothing dead was carried forward.
    try t.expectEqual(mappedCount(merged) + 1, ttf.glyphCount(merged));
}

test "U+F1E00 is the Claude Code figure, with its two eye holes — not the old spark" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const img = try svg.parse(arena, claude_svg);
    // The figure's viewBox is 24 × 24 and what it draws inside it is
    // 24 wide by 15 tall. The spark's was 94 × 94 and square — so the
    // ratio is what tells the two apart after `place` has scaled
    // whichever one it got to fill the cell.
    try t.expectEqual(@as(f64, 24), img.view.w);
    const placed = try ttf.place(arena, img, .{});
    try t.expectEqual(@as(usize, 3), placed.len);
    var min_x: f64 = 1e30;
    var max_x: f64 = -1e30;
    var min_y: f64 = 1e30;
    var max_y: f64 = -1e30;
    for (placed) |c| for (c) |p| {
        min_x = @min(min_x, p.x);
        max_x = @max(max_x, p.x);
        min_y = @min(min_y, p.y);
        max_y = @max(max_y, p.y);
    };
    // Width-limited, so it fills `Fit.width` × the advance exactly…
    try t.expectApproxEqAbs(@as(f64, @floatFromInt(ttf.advance_width)) * 1.25, max_x - min_x, 0.01);
    // …and is 15/24 as tall. The spark came out square (ratio ~1.0).
    try t.expectApproxEqAbs(15.0 / 24.0, (max_y - min_y) / (max_x - min_x), 0.01);

    // The eyes are holes: two contours inside the third, wound the
    // other way. `fill-rule="evenodd"` on the path is exactly the rule
    // `place` applies by nesting depth, so they cut out rather than
    // filling in.
    var holes: usize = 0;
    var body: usize = 0;
    for (placed, 0..) |c, i| {
        var inside = false;
        for (placed, 0..) |other, j| if (i != j and svg.contains(other, c[0])) {
            inside = true;
        };
        if (inside) {
            holes += 1;
            try t.expect(svg.signedArea(c) > 0); // counter-clockwise in y-up
        } else {
            body += 1;
            try t.expect(svg.signedArea(c) < 0);
        }
    }
    try t.expectEqual(@as(usize, 2), holes);
    try t.expectEqual(@as(usize, 1), body);
}

test "U+F1E02 is the Anthropic spark — the other art, at its own codepoint, so a face carries both marks" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The two marks are different art. Same bytes at two codepoints
    // would make the menu's choice a no-op that still looked wired.
    try t.expect(!std.mem.eql(u8, claude_svg, claude_spark_svg));
    const img = try svg.parse(arena, claude_spark_svg);
    // The spark's viewBox is 94 × 94, square — the one measurement the
    // figure's own test uses to say it is NOT this.
    try t.expectEqual(@as(f64, 94), img.view.w);
    try t.expectEqual(@as(f64, 94), img.view.h);
    // One contour and no holes: a star, where the figure is a body
    // with two eyes cut out of it.
    const placed = try ttf.place(arena, img, .{});
    try t.expectEqual(@as(usize, 1), placed.len);
    var min_x: f64 = 1e30;
    var max_x: f64 = -1e30;
    var min_y: f64 = 1e30;
    var max_y: f64 = -1e30;
    for (placed[0]) |p| {
        min_x = @min(min_x, p.x);
        max_x = @max(max_x, p.x);
        min_y = @min(min_y, p.y);
        max_y = @max(max_y, p.y);
    }
    // Square after `place` has scaled it, where the figure comes out
    // 15/24 as tall as it is wide.
    try t.expectApproxEqAbs(@as(f64, 1.0), (max_y - min_y) / (max_x - min_x), 0.01);

    // And the two are baked at the codepoints the chrome names, in one
    // face: the figure the default, the spark the alternate the
    // `Icon ▸` menu offers. Read off the spec list rather than the
    // cmap, so a swap of the two sources fails here.
    const specs = defaultSpecs(.{});
    var figure_src: ?[]const u8 = null;
    var spark_src: ?[]const u8 = null;
    for (specs) |s| {
        if (s.codepoint == claude) figure_src = s.source;
        if (s.codepoint == claude_spark) spark_src = s.source;
    }
    try t.expectEqualStrings(claude_svg, figure_src.?);
    try t.expectEqualStrings(claude_spark_svg, spark_src.?);
}
