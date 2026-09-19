//! An sfnt writer: the nine tables a monochrome symbols font needs and
//! nothing else.
//!
//! `head hhea maxp hmtx cmap name OS/2 post loca glyf` — no hinting, no
//! kerning, no layout tables. Outlines are all on-curve points, which
//! `glyf` allows and every rasteriser draws as straight edges between
//! them; `svg.zig` has already flattened the curves.
//!
//! The winding rule is TrueType's: non-zero, outer contours clockwise
//! in the y-up em square, holes counter-clockwise. `place` works out
//! which is which by nesting depth, so an SVG whose paths all run the
//! same way still gets its holes.
//!
//! Two cmap subtables are written: format 12 at (3, 10), which is the
//! one that can address mnml's block above U+FFFF, and format 4 at
//! (3, 1) for the BMP codepoints, because some rasterisers will not
//! load a font without a BMP subtable at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const svg = @import("svg.zig");

/// The em square. 1000 matches JetBrainsMono, so a glyph scaled to a
/// fraction of the em lines up with the text beside it.
pub const units_per_em: i32 = 1000;
/// The monospace advance JetBrainsMono Mono uses, in those units.
pub const advance_width: i32 = 600;

pub const Error = error{ TooManyPoints, CoordinateOverflow } || Allocator.Error;

/// One glyph: closed contours in font units (y up, origin on the
/// baseline at the left side bearing).
pub const Glyph = struct {
    codepoint: u21,
    /// PostScript-ish name for the `name` table's sake; not stored.
    name: []const u8,
    contours: []const svg.Contour,

    pub const empty: []const svg.Contour = &.{};
};

// ─── the outline transform ──────────────────────────────────────────────

/// How a source image is placed in the cell.
pub const Fit = struct {
    /// The glyph's height as a fraction of the em. 0.80 puts it a
    /// little above cap-height, which is the visual weight stock Nerd
    /// Font marks carry beside text.
    height: f64 = 0.80,
    /// The widest the glyph may get, as a fraction of the advance.
    /// Above 1.0 it bleeds into the neighbouring cell, which is fine in
    /// a fallback font — the cell beside a mark is background.
    width: f64 = 1.25,
    /// Where the glyph's middle sits, as a fraction of the em above the
    /// baseline. 0.36 is the mid-point of a 720-unit cap.
    center: f64 = 0.36,
};

/// Place an SVG image into the em square: scale to the fit, flip y,
/// centre, and set each contour's direction from its nesting depth.
pub fn place(arena: Allocator, img: svg.Image, fit: Fit) Allocator.Error![]const svg.Contour {
    // The drawn bounds, not the viewBox: an icon with padding baked
    // into its box would otherwise come out small.
    var min_x: f64 = std.math.floatMax(f64);
    var min_y: f64 = std.math.floatMax(f64);
    var max_x: f64 = -std.math.floatMax(f64);
    var max_y: f64 = -std.math.floatMax(f64);
    for (img.contours) |c| for (c) |p| {
        min_x = @min(min_x, p.x);
        min_y = @min(min_y, p.y);
        max_x = @max(max_x, p.x);
        max_y = @max(max_y, p.y);
    };
    const src_w = max_x - min_x;
    const src_h = max_y - min_y;
    if (src_w <= 0 or src_h <= 0) return &.{};

    const em: f64 = @floatFromInt(units_per_em);
    const cell: f64 = @floatFromInt(advance_width);
    const scale = @min(cell * fit.width / src_w, em * fit.height / src_h);
    const w = src_w * scale;
    const h = src_h * scale;
    const dx = (cell - w) / 2.0;
    const cy = em * fit.center;

    const out = try arena.alloc(svg.Contour, img.contours.len);
    for (img.contours, 0..) |c, i| {
        const pts = try arena.alloc(svg.Point, c.len);
        for (c, 0..) |p, j| pts[j] = .{
            .x = dx + (p.x - min_x) * scale,
            // Flip: SVG's y grows down, a font's grows up.
            .y = cy + h / 2.0 - (p.y - min_y) * scale,
        };
        out[i] = pts;
    }
    fixWinding(out);
    return out;
}

/// Give every contour the direction its nesting depth calls for: outer
/// clockwise (negative shoelace area in a y-up frame), holes the other
/// way. Depth is the even-odd count a browser uses for
/// `fill-rule="evenodd"`, which is also what the eye reads off a
/// layered icon: the second ring is a hole, the third is solid again.
fn fixWinding(contours: []const svg.Contour) void {
    for (contours, 0..) |c, i| {
        if (c.len < 3) continue;
        // A vertex of `c` is the probe: it sits on `c`'s own boundary,
        // which is never tested, and strictly inside or outside every
        // other contour — an icon's layers are nested, not crossing.
        const probe = c[0];
        var depth: usize = 0;
        for (contours, 0..) |other, j| {
            if (i == j or other.len < 3) continue;
            if (svg.contains(other, probe)) depth += 1;
        }
        const want_hole = depth % 2 == 1;
        const area = svg.signedArea(c);
        // `signedArea` is positive for counter-clockwise in y-up.
        const is_hole_dir = area > 0;
        if (is_hole_dir != want_hole) std.mem.reverse(svg.Point, c);
    }
}

// ─── the writer ─────────────────────────────────────────────────────────

const Buf = std.ArrayListUnmanaged(u8);

fn u8At(b: *Buf, a: Allocator, v: u8) Allocator.Error!void {
    try b.append(a, v);
}
fn u16At(b: *Buf, a: Allocator, v: u16) Allocator.Error!void {
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u16, v)));
}
fn i16At(b: *Buf, a: Allocator, v: i16) Allocator.Error!void {
    try u16At(b, a, @bitCast(v));
}
fn u32At(b: *Buf, a: Allocator, v: u32) Allocator.Error!void {
    try b.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, v)));
}

fn pad4(b: *Buf, a: Allocator) Allocator.Error!void {
    while (b.items.len % 4 != 0) try b.append(a, 0);
}

/// The sfnt checksum: the big-endian u32s of a table, summed with wrap,
/// the tail zero-padded.
fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 4) {
        var word: [4]u8 = .{ 0, 0, 0, 0 };
        const n = @min(4, data.len - i);
        @memcpy(word[0..n], data[i..][0..n]);
        sum +%= std.mem.readInt(u32, &word, .big);
    }
    return sum;
}

const Bounds = struct { x_min: i16 = 0, y_min: i16 = 0, x_max: i16 = 0, y_max: i16 = 0 };

/// One glyph's `glyf` entry. An empty outline writes nothing at all —
/// `loca` says so by repeating the previous offset.
fn glyfEntry(arena: Allocator, out: *Buf, contours: []const svg.Contour) Error!Bounds {
    var n_pts: usize = 0;
    var n_contours: usize = 0;
    for (contours) |c| if (c.len >= 3) {
        n_pts += c.len;
        n_contours += 1;
    };
    if (n_contours == 0) return .{};
    if (n_pts > 0x7FFF or n_contours > 0x7FFF) return error.TooManyPoints;

    var xs = try arena.alloc(i16, n_pts);
    var ys = try arena.alloc(i16, n_pts);
    var ends = try arena.alloc(u16, n_contours);
    var k: usize = 0;
    var ci: usize = 0;
    var b: Bounds = .{ .x_min = std.math.maxInt(i16), .y_min = std.math.maxInt(i16), .x_max = std.math.minInt(i16), .y_max = std.math.minInt(i16) };
    for (contours) |c| {
        if (c.len < 3) continue;
        for (c) |p| {
            const x = std.math.lossyCast(f64, @round(p.x));
            const y = std.math.lossyCast(f64, @round(p.y));
            if (x < -16384 or x > 16384 or y < -16384 or y > 16384) return error.CoordinateOverflow;
            xs[k] = @intFromFloat(x);
            ys[k] = @intFromFloat(y);
            b.x_min = @min(b.x_min, xs[k]);
            b.y_min = @min(b.y_min, ys[k]);
            b.x_max = @max(b.x_max, xs[k]);
            b.y_max = @max(b.y_max, ys[k]);
            k += 1;
        }
        ends[ci] = @intCast(k - 1);
        ci += 1;
    }

    try i16At(out, arena, @intCast(n_contours));
    try i16At(out, arena, b.x_min);
    try i16At(out, arena, b.y_min);
    try i16At(out, arena, b.x_max);
    try i16At(out, arena, b.y_max);
    for (ends) |e| try u16At(out, arena, e);
    try u16At(out, arena, 0); // instructionLength
    // Every point on-curve, every delta in the long signed form: the
    // short forms only save bytes, and a symbols font is small either
    // way.
    for (0..n_pts) |_| try u8At(out, arena, 0x01);
    var prev: i16 = 0;
    for (xs) |x| {
        try i16At(out, arena, x -% prev);
        prev = x;
    }
    prev = 0;
    for (ys) |y| {
        try i16At(out, arena, y -% prev);
        prev = y;
    }
    return b;
}

/// `cmap` format 12: every codepoint, one group each (the codepoints
/// mnml owns are scattered, so runs buy nothing).
fn cmap12(arena: Allocator, out: *Buf, glyphs: []const Glyph) Allocator.Error!void {
    try u16At(out, arena, 12);
    try u16At(out, arena, 0);
    try u32At(out, arena, @intCast(16 + 12 * glyphs.len));
    try u32At(out, arena, 0); // language
    try u32At(out, arena, @intCast(glyphs.len));
    for (glyphs, 0..) |g, i| {
        try u32At(out, arena, g.codepoint);
        try u32At(out, arena, g.codepoint);
        try u32At(out, arena, @intCast(i + 1)); // glyph 0 is .notdef
    }
}

/// `cmap` format 4 over the BMP codepoints only, each its own segment,
/// plus the mandatory `0xFFFF → 0` terminator.
fn cmap4(arena: Allocator, out: *Buf, glyphs: []const Glyph) Allocator.Error!void {
    var segs: std.ArrayListUnmanaged(struct { cp: u16, gid: u16 }) = .empty;
    for (glyphs, 0..) |g, i| if (g.codepoint <= 0xFFFE) try segs.append(arena, .{ .cp = @intCast(g.codepoint), .gid = @intCast(i + 1) });
    const n: u16 = @intCast(segs.items.len + 1);
    const len: u16 = @intCast(16 + 8 * @as(usize, n));
    try u16At(out, arena, 4);
    try u16At(out, arena, len);
    try u16At(out, arena, 0); // language
    try u16At(out, arena, n * 2);
    const search = @as(u16, 2) * (@as(u16, 1) << @intCast(std.math.log2_int(u16, n)));
    try u16At(out, arena, search);
    try u16At(out, arena, std.math.log2_int(u16, n));
    try u16At(out, arena, n * 2 - search);
    for (segs.items) |s| try u16At(out, arena, s.cp); // endCode
    try u16At(out, arena, 0xFFFF);
    try u16At(out, arena, 0); // reservedPad
    for (segs.items) |s| try u16At(out, arena, s.cp); // startCode
    try u16At(out, arena, 0xFFFF);
    for (segs.items) |s| try i16At(out, arena, @bitCast(s.gid -% s.cp)); // idDelta
    try i16At(out, arena, 1);
    for (0..n) |_| try u16At(out, arena, 0); // idRangeOffset
}

fn cmapTable(arena: Allocator, glyphs: []const Glyph) Allocator.Error![]u8 {
    var four: Buf = .empty;
    try cmap4(arena, &four, glyphs);
    var twelve: Buf = .empty;
    try cmap12(arena, &twelve, glyphs);
    var out: Buf = .empty;
    const header = 4 + 2 * 8;
    try u16At(&out, arena, 0);
    try u16At(&out, arena, 2);
    try u16At(&out, arena, 3); // Windows
    try u16At(&out, arena, 1); // BMP
    try u32At(&out, arena, header);
    try u16At(&out, arena, 3); // Windows
    try u16At(&out, arena, 10); // full repertoire
    try u32At(&out, arena, @intCast(header + four.items.len));
    try out.appendSlice(arena, four.items);
    try out.appendSlice(arena, twelve.items);
    return out.items;
}

/// The `name` table, on both the Windows platform (UTF-16BE, which is
/// what every modern shaper reads) and the Macintosh one (MacRoman,
/// which macOS Font Book still likes to see).
fn nameTable(arena: Allocator, family: []const u8, version: []const u8) Allocator.Error![]u8 {
    const ps = try std.fmt.allocPrint(arena, "{s}-Regular", .{family});
    const full = try std.fmt.allocPrint(arena, "{s} Regular", .{family});
    const unique = try std.fmt.allocPrint(arena, "{s} {s}", .{ family, version });
    const ver = try std.fmt.allocPrint(arena, "Version {s}", .{version});
    const records = [_]struct { id: u16, text: []const u8 }{
        .{ .id = 0, .text = "mnml — a layerable symbols font for mnml's own marks" },
        .{ .id = 1, .text = family },
        .{ .id = 2, .text = "Regular" },
        .{ .id = 3, .text = unique },
        .{ .id = 4, .text = full },
        .{ .id = 5, .text = ver },
        .{ .id = 6, .text = ps },
        .{ .id = 16, .text = family },
        .{ .id = 17, .text = "Regular" },
    };

    var recs: Buf = .empty;
    var strings: Buf = .empty;
    // Platform 3 (Windows), encoding 1 (UCS-2), language 0x409.
    for (records) |r| {
        const off = strings.items.len;
        for (r.text) |ch| try u16At(&strings, arena, ch);
        try u16At(&recs, arena, 3);
        try u16At(&recs, arena, 1);
        try u16At(&recs, arena, 0x409);
        try u16At(&recs, arena, r.id);
        try u16At(&recs, arena, @intCast(strings.items.len - off));
        try u16At(&recs, arena, @intCast(off));
    }
    // Platform 1 (Macintosh), encoding 0 (Roman), language 0.
    for (records) |r| {
        if (r.id >= 16) continue; // typographic names are Windows-only here
        const off = strings.items.len;
        for (r.text) |ch| try strings.append(arena, if (ch < 0x80) ch else '?');
        try u16At(&recs, arena, 1);
        try u16At(&recs, arena, 0);
        try u16At(&recs, arena, 0);
        try u16At(&recs, arena, r.id);
        try u16At(&recs, arena, @intCast(strings.items.len - off));
        try u16At(&recs, arena, @intCast(off));
    }
    const count = records.len + records.len - 2;
    var out: Buf = .empty;
    try u16At(&out, arena, 0);
    try u16At(&out, arena, @intCast(count));
    try u16At(&out, arena, @intCast(6 + 12 * count));
    try out.appendSlice(arena, recs.items);
    try out.appendSlice(arena, strings.items);
    return out.items;
}

const Table = struct { tag: [4]u8, data: []const u8 };

/// Write `glyphs` (plus `.notdef` and a blank space) as a TrueType
/// font. `family` becomes the family name every font-codepoint-map
/// line has to spell; `version` is the string `name` ID 5 carries,
/// which `font_scan` reads back.
pub fn build(arena: Allocator, glyphs: []const Glyph, family: []const u8, version: []const u8) Error![]u8 {
    var glyf: Buf = .empty;
    var loca: std.ArrayListUnmanaged(u32) = .empty;
    var all: Bounds = .{ .x_min = std.math.maxInt(i16), .y_min = std.math.maxInt(i16), .x_max = std.math.minInt(i16), .y_max = std.math.minInt(i16) };
    var max_points: u16 = 0;
    var max_contours: u16 = 0;

    // `loca` holds numGlyphs + 1 offsets. Glyph 0 is `.notdef` and it is
    // blank — a symbols font has nothing useful to say about a
    // codepoint it does not carry — so its start and its end are both
    // zero, and the real glyphs follow.
    try loca.append(arena, 0);
    try loca.append(arena, 0);
    for (glyphs) |g| {
        const b = try glyfEntry(arena, &glyf, g.contours);
        try pad4(&glyf, arena);
        try loca.append(arena, @intCast(glyf.items.len));
        var pts: usize = 0;
        var cs: usize = 0;
        for (g.contours) |c| if (c.len >= 3) {
            pts += c.len;
            cs += 1;
        };
        max_points = @max(max_points, @as(u16, @intCast(pts)));
        max_contours = @max(max_contours, @as(u16, @intCast(cs)));
        if (cs > 0) {
            all.x_min = @min(all.x_min, b.x_min);
            all.y_min = @min(all.y_min, b.y_min);
            all.x_max = @max(all.x_max, b.x_max);
            all.y_max = @max(all.y_max, b.y_max);
        }
    }
    if (all.x_min > all.x_max) all = .{};
    const n_glyphs: u16 = @intCast(glyphs.len + 1);

    var loca_buf: Buf = .empty;
    for (loca.items) |o| try u32At(&loca_buf, arena, o);

    var head: Buf = .empty;
    try u32At(&head, arena, 0x00010000);
    try u32At(&head, arena, 0x00010000); // fontRevision 1.0
    try u32At(&head, arena, 0); // checkSumAdjustment, filled in below
    try u32At(&head, arena, 0x5F0F3CF5);
    try u16At(&head, arena, 0b0000_0000_0000_1011); // baseline at y=0, lsb at x=0, integer ppem
    try u16At(&head, arena, @intCast(units_per_em));
    // created / modified: a fixed date, not the clock, so two builds of
    // the same sources are byte-identical. LONGDATETIME counts seconds
    // from 1904-01-01; this is 2026-01-01.
    const stamp: u32 = 3_849_984_000;
    try u32At(&head, arena, 0);
    try u32At(&head, arena, stamp);
    try u32At(&head, arena, 0);
    try u32At(&head, arena, stamp);
    try i16At(&head, arena, all.x_min);
    try i16At(&head, arena, all.y_min);
    try i16At(&head, arena, all.x_max);
    try i16At(&head, arena, all.y_max);
    try u16At(&head, arena, 0); // macStyle
    try u16At(&head, arena, 8); // lowestRecPPEM
    try i16At(&head, arena, 2); // fontDirectionHint
    try i16At(&head, arena, 1); // indexToLocFormat: long
    try i16At(&head, arena, 0);

    const ascender: i16 = 800;
    const descender: i16 = -200;

    var hhea: Buf = .empty;
    try u32At(&hhea, arena, 0x00010000);
    try i16At(&hhea, arena, ascender);
    try i16At(&hhea, arena, descender);
    try i16At(&hhea, arena, 0); // lineGap
    try u16At(&hhea, arena, @intCast(advance_width));
    try i16At(&hhea, arena, all.x_min);
    try i16At(&hhea, arena, 0); // minRightSideBearing
    try i16At(&hhea, arena, all.x_max);
    try i16At(&hhea, arena, 1); // caretSlopeRise
    try i16At(&hhea, arena, 0);
    try i16At(&hhea, arena, 0);
    for (0..4) |_| try i16At(&hhea, arena, 0);
    try i16At(&hhea, arena, 0); // metricDataFormat
    try u16At(&hhea, arena, n_glyphs);

    var hmtx: Buf = .empty;
    for (0..n_glyphs) |_| {
        try u16At(&hmtx, arena, @intCast(advance_width));
        try i16At(&hmtx, arena, 0);
    }

    var maxp: Buf = .empty;
    try u32At(&maxp, arena, 0x00010000);
    try u16At(&maxp, arena, n_glyphs);
    try u16At(&maxp, arena, max_points);
    try u16At(&maxp, arena, max_contours);
    try u16At(&maxp, arena, 0); // maxCompositePoints
    try u16At(&maxp, arena, 0);
    try u16At(&maxp, arena, 2); // maxZones
    // maxTwilightPoints, maxStorage, maxFunctionDefs,
    // maxInstructionDefs, maxStackElements, maxSizeOfInstructions —
    // all zero: the font carries no bytecode.
    for (0..6) |_| try u16At(&maxp, arena, 0);
    try u16At(&maxp, arena, 0); // maxComponentElements
    try u16At(&maxp, arena, 0); // maxComponentDepth

    var os2: Buf = .empty;
    try u16At(&os2, arena, 4); // version
    try i16At(&os2, arena, @intCast(advance_width)); // xAvgCharWidth
    try u16At(&os2, arena, 400); // usWeightClass
    try u16At(&os2, arena, 5); // usWidthClass
    try u16At(&os2, arena, 0); // fsType: installable
    try i16At(&os2, arena, 650); // ySubscriptXSize
    try i16At(&os2, arena, 600);
    try i16At(&os2, arena, 0);
    try i16At(&os2, arena, 75);
    try i16At(&os2, arena, 650); // ySuperscriptXSize
    try i16At(&os2, arena, 600);
    try i16At(&os2, arena, 0);
    try i16At(&os2, arena, 350);
    try i16At(&os2, arena, 50); // yStrikeoutSize
    try i16At(&os2, arena, 300);
    try i16At(&os2, arena, 0); // sFamilyClass
    // PANOSE: a monospaced pictorial face.
    const panose = [10]u8{ 5, 0, 0, 9, 0, 0, 0, 0, 0, 0 };
    try os2.appendSlice(arena, &panose);
    for (0..4) |_| try u32At(&os2, arena, 0); // ulUnicodeRange1-4
    try os2.appendSlice(arena, "MNML");
    try u16At(&os2, arena, 0b0100_0000); // fsSelection: REGULAR
    const first = if (glyphs.len == 0) @as(u16, 0) else @as(u16, @intCast(@min(glyphs[0].codepoint, 0xFFFF)));
    try u16At(&os2, arena, first);
    try u16At(&os2, arena, 0xFFFF);
    try i16At(&os2, arena, ascender); // sTypoAscender
    try i16At(&os2, arena, descender);
    try i16At(&os2, arena, 0); // sTypoLineGap
    try u16At(&os2, arena, @intCast(ascender)); // usWinAscent
    try u16At(&os2, arena, @intCast(-descender));
    try u32At(&os2, arena, 1); // ulCodePageRange1: Latin 1
    try u32At(&os2, arena, 0);
    try i16At(&os2, arena, 500); // sxHeight
    try i16At(&os2, arena, 720); // sCapHeight
    try u16At(&os2, arena, 0); // usDefaultChar
    try u16At(&os2, arena, 0x20); // usBreakChar
    try u16At(&os2, arena, 1); // usMaxContext

    var post: Buf = .empty;
    try u32At(&post, arena, 0x00030000); // version 3: no glyph names
    try u32At(&post, arena, 0); // italicAngle
    try i16At(&post, arena, -100); // underlinePosition
    try i16At(&post, arena, 50);
    try u32At(&post, arena, 1); // isFixedPitch
    for (0..4) |_| try u32At(&post, arena, 0);

    const tables = [_]Table{
        .{ .tag = "OS/2".*, .data = os2.items },
        .{ .tag = "cmap".*, .data = try cmapTable(arena, glyphs) },
        .{ .tag = "glyf".*, .data = glyf.items },
        .{ .tag = "head".*, .data = head.items },
        .{ .tag = "hhea".*, .data = hhea.items },
        .{ .tag = "hmtx".*, .data = hmtx.items },
        .{ .tag = "loca".*, .data = loca_buf.items },
        .{ .tag = "maxp".*, .data = maxp.items },
        .{ .tag = "name".*, .data = try nameTable(arena, family, version) },
        .{ .tag = "post".*, .data = post.items },
    };

    var out: Buf = .empty;
    const n: u16 = tables.len;
    const entry_selector: u16 = std.math.log2_int(u16, n);
    const search_range: u16 = @as(u16, 16) << @intCast(entry_selector);
    try u32At(&out, arena, 0x00010000);
    try u16At(&out, arena, n);
    try u16At(&out, arena, search_range);
    try u16At(&out, arena, entry_selector);
    try u16At(&out, arena, n * 16 - search_range);
    var offset: u32 = @intCast(12 + 16 * @as(usize, n));
    var head_offset: usize = 0;
    for (tables) |tb| {
        try out.appendSlice(arena, &tb.tag);
        try u32At(&out, arena, checksum(tb.data));
        try u32At(&out, arena, offset);
        try u32At(&out, arena, @intCast(tb.data.len));
        if (std.mem.eql(u8, &tb.tag, "head")) head_offset = offset;
        offset += @intCast((tb.data.len + 3) / 4 * 4);
    }
    for (tables) |tb| {
        try out.appendSlice(arena, tb.data);
        try pad4(&out, arena);
    }

    // `head.checkSumAdjustment` closes the loop: the whole file has to
    // sum to the magic constant.
    const adjust = 0xB1B0AFBA -% checksum(out.items);
    std.mem.writeInt(u32, out.items[head_offset + 8 ..][0..4], adjust, .big);
    return out.items;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn square(arena: Allocator, x0: f64, y0: f64, x1: f64, y1: f64) !svg.Contour {
    const p = try arena.alloc(svg.Point, 4);
    p[0] = .{ .x = x0, .y = y0 };
    p[1] = .{ .x = x1, .y = y0 };
    p[2] = .{ .x = x1, .y = y1 };
    p[3] = .{ .x = x0, .y = y1 };
    return p;
}

test "a built font is a well-formed sfnt: ten tables, the head magic, and the whole file sums to the magic constant" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = [_]svg.Contour{try square(arena, 100, 100, 500, 700)};
    const bytes = try build(arena, &.{
        .{ .codepoint = 0xF2000, .name = "ghostty", .contours = &c },
        .{ .codepoint = 0x20, .name = "space", .contours = Glyph.empty },
    }, "MnmlSymbols", "1.0");
    try t.expectEqual(@as(u32, 0x00010000), std.mem.readInt(u32, bytes[0..4], .big));
    try t.expectEqual(@as(u16, 10), std.mem.readInt(u16, bytes[4..6], .big));
    // The head table's magic, found through the directory.
    var head_off: usize = 0;
    for (0..10) |i| {
        const rec = bytes[12 + 16 * i ..][0..16];
        if (std.mem.eql(u8, rec[0..4], "head")) head_off = std.mem.readInt(u32, rec[8..12], .big);
    }
    try t.expect(head_off != 0);
    try t.expectEqual(@as(u32, 0x5F0F3CF5), std.mem.readInt(u32, bytes[head_off + 12 ..][0..4], .big));
    try t.expectEqual(@as(u16, @intCast(units_per_em)), std.mem.readInt(u16, bytes[head_off + 18 ..][0..2], .big));
    try t.expectEqual(@as(u32, 0xB1B0AFBA), checksum(bytes));
}

test "a hole is wound against its outer contour, and nesting decides which is which" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Outer box, a hole in it, and an island inside the hole — all
    // three drawn the same way round, as a layered icon's paths are.
    const raw = [_]svg.Contour{
        try square(arena, 0, 0, 100, 100),
        try square(arena, 20, 20, 80, 80),
        try square(arena, 40, 40, 60, 60),
    };
    const placed = try place(arena, .{ .view = .{ .w = 100, .h = 100 }, .contours = &raw }, .{});
    const a0 = svg.signedArea(placed[0]);
    const a1 = svg.signedArea(placed[1]);
    const a2 = svg.signedArea(placed[2]);
    try t.expect(a0 < 0); // outer: clockwise in y-up
    try t.expect(a1 > 0); // the hole runs the other way
    try t.expect(a2 < 0); // the island is back to the outer direction
}

test "placing scales to the fit, flips y and centres on the cell" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A tall 1×2 shape: height is the binding constraint at the
    // default fit, so it ends up 0.80 × em tall.
    const raw = [_]svg.Contour{try square(arena, 0, 0, 10, 20)};
    const placed = try place(arena, .{ .view = .{ .w = 10, .h = 20 }, .contours = &raw }, .{});
    var min_y: f64 = 1e30;
    var max_y: f64 = -1e30;
    var min_x: f64 = 1e30;
    var max_x: f64 = -1e30;
    for (placed[0]) |p| {
        min_y = @min(min_y, p.y);
        max_y = @max(max_y, p.y);
        min_x = @min(min_x, p.x);
        max_x = @max(max_x, p.x);
    }
    try t.expectApproxEqAbs(@as(f64, 800), max_y - min_y, 0.001);
    try t.expectApproxEqAbs(@as(f64, 400), max_x - min_x, 0.001);
    // Centred vertically on 0.36 em and horizontally in the advance.
    try t.expectApproxEqAbs(@as(f64, 360), (min_y + max_y) / 2, 0.001);
    try t.expectApproxEqAbs(@as(f64, 300), (min_x + max_x) / 2, 0.001);
}
