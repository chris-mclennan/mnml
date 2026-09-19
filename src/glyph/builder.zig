//! MnmlSymbols: the face mnml's own block is drawn from, and the one
//! command that builds it.
//!
//! mnml paints five marks that exist in no font anywhere — the Claude
//! and Codex product marks, the two tree connectors, and the terminal
//! icon — so it carries them itself, at codepoints in the private plane
//! nothing else claims (`U+F1B00–U+F20FF`). A terminal renders them by
//! routing that range at a font named `MnmlSymbols`; ghostty spells
//! that `font-codepoint-map` (`ghostty_config.zig` reads it back).
//!
//! Two builds come out of here:
//!
//!   - the shipped face, `share/mnml/fonts/MnmlSymbols.ttf`, built by
//!     `zig build` from the SVGs under `data/glyphs/` (`tools/
//!     build_font.zig` is the `zig build font` entry point);
//!   - the user's own, `<data root>/fonts/MnmlSymbols.ttf`, which the
//!     same code writes when the terminal icon is set to a custom SVG.
//!     Same family name, same codepoints — only the terminal mark
//!     differs — so a terminal already routed at `MnmlSymbols` picks
//!     the new one up with nothing to reconfigure.
//!
//! The two connectors are drawn here rather than imported: they are
//! rectangles that have to touch the cell edge exactly, and an SVG
//! rasterised at those coordinates leaves hairline gaps between rows.

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
pub const tree_vertical: u21 = 0xF1F04;
pub const tree_corner: u21 = 0xF1F05;
/// The terminal mark — Ghostty's ghost by default, whatever SVG the
/// user names when the icon is set to custom. One codepoint either
/// way, so the routing never has to change.
pub const terminal: u21 = 0xF2000;

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
pub const codex_svg = data.codex_svg;
pub const ghostty_svg = data.ghostty_svg;

/// The shipped set, in codepoint order. `terminal_svg` replaces the
/// ghost when the user has named their own.
pub fn defaultSpecs(terminal_svg: []const u8) [3]Spec {
    return .{
        .{ .codepoint = claude, .name = "claude-mark", .source = claude_svg },
        .{ .codepoint = codex, .name = "codex-mark", .source = codex_svg },
        .{ .codepoint = terminal, .name = "terminal-mark", .source = terminal_svg },
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

// ─── the build ──────────────────────────────────────────────────────────

/// Every glyph the face carries, as bytes. `specs` are the SVG-backed
/// marks; the connectors and the blank space are added here.
pub fn build(arena: Allocator, specs: []const Spec) Error![]u8 {
    var glyphs: std.ArrayListUnmanaged(ttf.Glyph) = .empty;
    for (specs) |s| {
        const img = try svg.parse(arena, s.source);
        try glyphs.append(arena, .{ .codepoint = s.codepoint, .name = s.name, .contours = try ttf.place(arena, img, s.fit) });
    }
    try glyphs.append(arena, .{ .codepoint = tree_vertical, .name = "tree-line-vertical", .contours = try verticalContours(arena) });
    try glyphs.append(arena, .{ .codepoint = tree_corner, .name = "tree-line-corner", .contours = try cornerContours(arena) });
    // A blank U+0020: a rasteriser that refuses a font with no text
    // character at all will still load this one.
    try glyphs.append(arena, .{ .codepoint = ' ', .name = "space", .contours = ttf.Glyph.empty });
    // `cmap` format 4 wants its segments in codepoint order, and
    // format 12 its groups; one sort serves both.
    std.mem.sort(ttf.Glyph, glyphs.items, {}, struct {
        fn lt(_: void, a: ttf.Glyph, b: ttf.Glyph) bool {
            return a.codepoint < b.codepoint;
        }
    }.lt);
    return ttf.build(arena, glyphs.items, family, version);
}

/// The face as it ships: the Ghostty ghost as the terminal mark.
pub fn buildDefault(arena: Allocator) Error![]u8 {
    const specs = defaultSpecs(ghostty_svg);
    return build(arena, &specs);
}

/// The face with `terminal_svg` in place of the ghost.
pub fn buildWithTerminal(arena: Allocator, terminal_svg: []const u8) Error![]u8 {
    const specs = defaultSpecs(terminal_svg);
    return build(arena, &specs);
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
    for ([_]u21{ claude, codex, tree_vertical, tree_corner, terminal, ' ' }) |cp| {
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
    const custom = try buildWithTerminal(arena, "<svg viewBox=\"0 0 10 10\"><path d=\"M1 1 L9 1 L9 9 L1 9 Z\"/></svg>");
    try t.expect(!std.mem.eql(u8, custom, try buildDefault(arena)));
    for ([_]u21{ claude, codex, tree_vertical, tree_corner, terminal }) |cp| try t.expect(cmapHas(custom, cp));
}

test "a broken SVG fails the build rather than baking an empty mark" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectError(error.NoViewBox, buildWithTerminal(arena, "<svg><path d=\"M0 0 L1 0 L1 1 Z\"/></svg>"));
    try t.expectError(error.Empty, buildWithTerminal(arena, "<svg viewBox=\"0 0 1 1\"></svg>"));
    try t.expectError(error.Malformed, buildWithTerminal(arena, "not an svg at all"));
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
