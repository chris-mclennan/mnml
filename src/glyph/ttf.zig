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
    // Each glyph's left side bearing: its outline's own xMin. `head`'s
    // flag 1 promises the bearing point sits at x=0, so a rasteriser
    // slides the outline until xMin meets the bearing — with a bearing
    // of 0 for every glyph, the tree's centred bar landed on the cell's
    // left edge and every mark that bleeds left crept right.
    var lsb: std.ArrayListUnmanaged(i16) = .empty;
    try lsb.append(arena, 0); // .notdef
    for (glyphs) |g| {
        const b = try glyfEntry(arena, &glyf, g.contours);
        try lsb.append(arena, if (g.contours.len > 0) b.x_min else 0);
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
    for (lsb.items) |left| {
        try u16At(&hmtx, arena, @intCast(advance_width));
        try i16At(&hmtx, arena, left);
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

// ─── the reader ─────────────────────────────────────────────────────────
//
// Enough of a TrueType parser to LIFT glyphs back out of a font this
// writer (or one like it) produced: the table directory, `head` for the
// em square and the `loca` format, `maxp` for the glyph count, `cmap`
// for codepoint → glyph, `hmtx` for the cell the glyph was drawn for,
// and `glyf` for the outlines. Nothing else — no hinting, no layout,
// no composites.
//
// It exists for one job: `run.sh install-font` must not throw away the
// glyphs an already-installed MnmlSymbols carries that this build does
// not bake (the Rust-era integration chips). Reading them back and
// writing them out again is the only way to keep them, since the
// sources for them are not in this repo.
//
// The outlines come back as polygons. `glyf` allows quadratic curves
// and the older face uses them, so a curve is flattened here to within
// `flatten_tol` font units — invisible at any ppem a terminal uses, and
// what the writer wants anyway (it emits on-curve points only).

pub const ReadError = error{
    /// Not an sfnt this reader understands (a CFF/OTF, a collection).
    NotTrueType,
    /// A table the reader needs is not in the directory.
    MissingTable,
    /// A table ran past the end of the file, or said something absurd.
    BadTable,
    /// A composite glyph — one drawn out of other glyphs. The faces
    /// this reads are built glyph-per-outline and have none.
    Composite,
} || Allocator.Error;

/// How far a flattened curve may sit from the true one, in font units
/// of `units_per_em`. One unit of 1000 is 0.016 px in a 16 px cell, so
/// this is well under a pixel at any size a terminal uses.
const flatten_tol: f64 = 1.0;
/// The most segments one quadratic is cut into, whatever its bulge. A
/// symbol glyph's widest arc is a quarter circle, which lands well
/// inside this.
const flatten_max: usize = 16;

fn rdU16(b: []const u8, off: usize) ReadError!u16 {
    if (off + 2 > b.len) return error.BadTable;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn rdI16(b: []const u8, off: usize) ReadError!i16 {
    return @bitCast(try rdU16(b, off));
}

fn rdU32(b: []const u8, off: usize) ReadError!u32 {
    if (off + 4 > b.len) return error.BadTable;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

/// The bytes of one table, by tag; null when the directory has none.
fn tableOf(bytes: []const u8, tag: *const [4]u8) ReadError!?[]const u8 {
    const n = try rdU16(bytes, 4);
    for (0..n) |i| {
        const rec = 12 + 16 * i;
        if (rec + 16 > bytes.len) return error.BadTable;
        if (!std.mem.eql(u8, bytes[rec..][0..4], tag)) continue;
        const off = try rdU32(bytes, rec + 8);
        const len = try rdU32(bytes, rec + 12);
        if (@as(usize, off) + len > bytes.len) return error.BadTable;
        return bytes[off..][0..len];
    }
    return null;
}

fn needTable(bytes: []const u8, tag: *const [4]u8) ReadError![]const u8 {
    return (try tableOf(bytes, tag)) orelse error.MissingTable;
}

const CpGid = struct { cp: u21, gid: u16 };

/// Every codepoint the `cmap` maps, with its glyph. Format 12 is read
/// when present — it is the only one that reaches mnml's own block —
/// and format 4 fills in for a BMP-only face.
fn cmapPairs(arena: Allocator, cmap: []const u8) ReadError![]CpGid {
    var out: std.ArrayListUnmanaged(CpGid) = .empty;
    const n = try rdU16(cmap, 2);
    var best: ?usize = null;
    var best_fmt: u16 = 0;
    for (0..n) |i| {
        const off = try rdU32(cmap, 4 + 8 * i + 4);
        const sub: usize = off;
        const fmt = try rdU16(cmap, sub);
        // 12 beats 4: it is a superset here, and the only one that can
        // name a codepoint above U+FFFF.
        if (fmt == 12 or (fmt == 4 and best_fmt != 12)) {
            if (best_fmt != 12 or fmt == 12) {
                best = sub;
                best_fmt = fmt;
            }
        }
    }
    const sub = best orelse return out.toOwnedSlice(arena);
    if (best_fmt == 12) {
        const groups = try rdU32(cmap, sub + 12);
        for (0..groups) |g| {
            const row = sub + 16 + 12 * g;
            const lo = try rdU32(cmap, row);
            const hi = try rdU32(cmap, row + 4);
            const gid0 = try rdU32(cmap, row + 8);
            if (hi < lo or hi > 0x10FFFF) return error.BadTable;
            for (lo..hi + 1) |cp| {
                const gid = gid0 + (cp - lo);
                if (gid == 0 or gid > 0xFFFF) continue;
                try out.append(arena, .{ .cp = @intCast(cp), .gid = @intCast(gid) });
            }
        }
        return out.toOwnedSlice(arena);
    }
    // Format 4: four parallel arrays and the idRangeOffset indirection.
    const seg2 = try rdU16(cmap, sub + 6);
    const segs = seg2 / 2;
    const ends = sub + 14;
    const starts = ends + seg2 + 2;
    const deltas = starts + seg2;
    const ranges = deltas + seg2;
    for (0..segs) |s| {
        const end = try rdU16(cmap, ends + 2 * s);
        const start = try rdU16(cmap, starts + 2 * s);
        if (start > end) continue;
        const delta = try rdI16(cmap, deltas + 2 * s);
        const range = try rdU16(cmap, ranges + 2 * s);
        var cp: u32 = start;
        while (cp <= end) : (cp += 1) {
            if (cp == 0xFFFF) continue;
            var gid: u16 = 0;
            if (range == 0) {
                gid = @truncate(@as(u32, @intCast(@as(i32, @intCast(cp)) +% delta)));
            } else {
                const at = ranges + 2 * s + range + 2 * (cp - start);
                const raw = try rdU16(cmap, at);
                if (raw == 0) continue;
                gid = @truncate(@as(u32, raw) +% @as(u32, @bitCast(@as(i32, delta))));
            }
            if (gid == 0) continue;
            try out.append(arena, .{ .cp = @intCast(cp), .gid = gid });
        }
    }
    return out.toOwnedSlice(arena);
}

const RawPoint = struct { x: f64, y: f64, on: bool };

fn mid(a: RawPoint, b: RawPoint) svg.Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

/// One quadratic, as line segments from (but not including) `p0` up to
/// and including `p1`. The segment count comes from how far the control
/// point pulls the curve off the chord.
fn quadTo(arena: Allocator, out: *std.ArrayListUnmanaged(svg.Point), p0: svg.Point, c: svg.Point, p1: svg.Point) Allocator.Error!void {
    const dx = c.x - (p0.x + p1.x) / 2;
    const dy = c.y - (p0.y + p1.y) / 2;
    const bulge = @sqrt(dx * dx + dy * dy);
    // A quadratic cut into n equal pieces sits within |p0−2c+p1|/(8n²)
    // = bulge/(4n²) of the true curve, so n = √(bulge / 4·tol) is the
    // cheapest count that holds. (The polygon's own extremum can still
    // fall a little short of the curve's — that error is the same
    // order, and at this tolerance it is under a unit.)
    var n: usize = 1;
    if (bulge > 0) n = @intFromFloat(@ceil(@sqrt(bulge / (4 * flatten_tol))));
    n = std.math.clamp(n, 1, flatten_max);
    for (1..n + 1) |i| {
        const tt = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const u = 1 - tt;
        try out.append(arena, .{
            .x = u * u * p0.x + 2 * u * tt * c.x + tt * tt * p1.x,
            .y = u * u * p0.y + 2 * u * tt * c.y + tt * tt * p1.y,
        });
    }
}

/// One `glyf` contour's points as a closed polygon.
fn flattenContour(arena: Allocator, pts: []const RawPoint) Allocator.Error!?svg.Contour {
    if (pts.len == 0) return null;
    var out: std.ArrayListUnmanaged(svg.Point) = .empty;
    // The polygon has to start on the curve. When every point is a
    // control point (a circle drawn as four quadratics), the implied
    // on-curve start is the midpoint of the last and the first.
    var first: usize = 0;
    var start: svg.Point = undefined;
    var found = false;
    for (pts, 0..) |p, i| if (p.on) {
        start = .{ .x = p.x, .y = p.y };
        first = i + 1;
        found = true;
        break;
    };
    if (!found) start = mid(pts[pts.len - 1], pts[0]);
    try out.append(arena, start);
    var cur = start;
    var pending: ?svg.Point = null;
    const steps = if (found) pts.len - 1 else pts.len;
    for (0..steps) |k| {
        const p = pts[(first + k) % pts.len];
        const here: svg.Point = .{ .x = p.x, .y = p.y };
        if (p.on) {
            if (pending) |c| {
                try quadTo(arena, &out, cur, c, here);
                pending = null;
            } else try out.append(arena, here);
            cur = here;
        } else {
            // Two control points in a row imply an on-curve point
            // halfway between them.
            if (pending) |c| {
                const m: svg.Point = .{ .x = (c.x + here.x) / 2, .y = (c.y + here.y) / 2 };
                try quadTo(arena, &out, cur, c, m);
                cur = m;
            }
            pending = here;
        }
    }
    if (pending) |c| try quadTo(arena, &out, cur, c, start);
    // The closing point and the start are the same place; `glyf` closes
    // a contour implicitly, so drop the duplicate.
    if (out.items.len > 1) {
        const last = out.items[out.items.len - 1];
        if (@abs(last.x - start.x) < 0.001 and @abs(last.y - start.y) < 0.001) _ = out.pop();
    }
    if (out.items.len < 3) return null;
    return out.items;
}

/// One glyph's outlines, scaled by `scale`.
fn glyphContours(arena: Allocator, glyf: []const u8, from: usize, to: usize, scale: f64) ReadError![]const svg.Contour {
    if (to <= from or to > glyf.len) return Glyph.empty;
    const g = glyf[from..to];
    const n_contours = try rdI16(g, 0);
    if (n_contours < 0) return error.Composite;
    const nc: usize = @intCast(n_contours);
    if (nc == 0) return Glyph.empty;
    var ends = try arena.alloc(u16, nc);
    for (0..nc) |i| ends[i] = try rdU16(g, 10 + 2 * i);
    const n_pts: usize = @as(usize, ends[nc - 1]) + 1;
    const instr = try rdU16(g, 10 + 2 * nc);
    var p: usize = 12 + 2 * nc + instr;

    var flags = try arena.alloc(u8, n_pts);
    var i: usize = 0;
    while (i < n_pts) {
        if (p >= g.len) return error.BadTable;
        const f = g[p];
        p += 1;
        flags[i] = f;
        i += 1;
        if (f & 0x08 != 0) {
            if (p >= g.len) return error.BadTable;
            var r = g[p];
            p += 1;
            while (r > 0 and i < n_pts) : (r -= 1) {
                flags[i] = f;
                i += 1;
            }
        }
    }
    var xs = try arena.alloc(f64, n_pts);
    var ys = try arena.alloc(f64, n_pts);
    var v: i32 = 0;
    for (flags, 0..) |f, k| {
        if (f & 0x02 != 0) {
            if (p >= g.len) return error.BadTable;
            const d: i32 = g[p];
            p += 1;
            v += if (f & 0x10 != 0) d else -d;
        } else if (f & 0x10 == 0) {
            v += try rdI16(g, p);
            p += 2;
        }
        xs[k] = @as(f64, @floatFromInt(v)) * scale;
    }
    v = 0;
    for (flags, 0..) |f, k| {
        if (f & 0x04 != 0) {
            if (p >= g.len) return error.BadTable;
            const d: i32 = g[p];
            p += 1;
            v += if (f & 0x20 != 0) d else -d;
        } else if (f & 0x20 == 0) {
            v += try rdI16(g, p);
            p += 2;
        }
        ys[k] = @as(f64, @floatFromInt(v)) * scale;
    }

    var out: std.ArrayListUnmanaged(svg.Contour) = .empty;
    var at: usize = 0;
    for (ends) |e| {
        const stop: usize = @as(usize, e) + 1;
        if (stop > n_pts or stop < at) return error.BadTable;
        var raw = try arena.alloc(RawPoint, stop - at);
        for (at..stop) |k| raw[k - at] = .{ .x = xs[k], .y = ys[k], .on = flags[k] & 0x01 != 0 };
        if (try flattenContour(arena, raw)) |c| try out.append(arena, c);
        at = stop;
    }
    return out.toOwnedSlice(arena);
}

/// `maxp`'s glyph count, `.notdef` included — what a merge measures the
/// mapped count against to say how many outlines it dropped.
pub fn glyphCount(bytes: []const u8) usize {
    const maxp = needTable(bytes, "maxp") catch return 0;
    return rdU16(maxp, 4) catch 0;
}

/// Every mapped glyph of `bytes`, in codepoint order, in THIS writer's
/// em square and cell. A face drawn on a different em or a different
/// advance is scaled to ours, so a lifted glyph keeps its proportion
/// within the cell rather than its raw coordinates.
pub fn read(arena: Allocator, bytes: []const u8) ReadError![]Glyph {
    if (bytes.len < 12) return error.NotTrueType;
    const sfnt = try rdU32(bytes, 0);
    if (sfnt != 0x00010000 and sfnt != 0x74727565) return error.NotTrueType;
    const head = try needTable(bytes, "head");
    const maxp = try needTable(bytes, "maxp");
    const loca = try needTable(bytes, "loca");
    const glyf = try needTable(bytes, "glyf");
    const cmap = try needTable(bytes, "cmap");
    const upem = try rdU16(head, 18);
    if (upem == 0) return error.BadTable;
    const long_loca = (try rdI16(head, 50)) != 0;
    const n_glyphs = try rdU16(maxp, 4);
    var scale = @as(f64, @floatFromInt(units_per_em)) / @as(f64, @floatFromInt(upem));
    // `hmtx`: the cell the source drew for (these faces are monospace,
    // so the first metric is every glyph's). Scaled to our em it should
    // already be our advance; when it is not, the glyph is resized so
    // it keeps the same fraction of the cell it always had — the em
    // factor cancels and what is left is the two cells' ratio.
    if (try tableOf(bytes, "hmtx")) |hmtx| if (hmtx.len >= 4) {
        const adv = try rdU16(hmtx, 0);
        if (adv > 0) scale *= @as(f64, @floatFromInt(advance_width)) / (@as(f64, @floatFromInt(adv)) * scale);
    };

    var out: std.ArrayListUnmanaged(Glyph) = .empty;
    for (try cmapPairs(arena, cmap)) |pair| {
        if (pair.gid >= n_glyphs) continue;
        const i: usize = pair.gid;
        const from: usize = if (long_loca) try rdU32(loca, 4 * i) else @as(usize, try rdU16(loca, 2 * i)) * 2;
        const to: usize = if (long_loca) try rdU32(loca, 4 * (i + 1)) else @as(usize, try rdU16(loca, 2 * (i + 1))) * 2;
        try out.append(arena, .{
            .codepoint = pair.cp,
            // `post` is version 3 in the faces this reads, so there are
            // no names on disk to lift; the writer does not store them.
            .name = try std.fmt.allocPrint(arena, "uni{X:0>4}", .{pair.cp}),
            .contours = try glyphContours(arena, glyf, from, to, scale),
        });
    }
    std.mem.sort(Glyph, out.items, {}, struct {
        fn lt(_: void, a: Glyph, b: Glyph) bool {
            return a.codepoint < b.codepoint;
        }
    }.lt);
    return out.toOwnedSlice(arena);
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

// ─── the reader's tests ─────────────────────────────────────────────────

test "the reader lifts back exactly what the writer wrote" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = [_]svg.Contour{try square(arena, 100, 100, 500, 700)};
    const b = [_]svg.Contour{ try square(arena, 0, 0, 600, 600), try square(arena, 200, 200, 400, 400) };
    const bytes = try build(arena, &.{
        .{ .codepoint = 0x20, .name = "space", .contours = Glyph.empty },
        .{ .codepoint = 0xF1C03, .name = "chip", .contours = &a },
        .{ .codepoint = 0xF2000, .name = "ghostty", .contours = &b },
    }, "MnmlSymbols", "1.0");

    const back = try read(arena, bytes);
    try t.expectEqual(@as(usize, 3), back.len);
    try t.expectEqual(@as(u21, 0x20), back[0].codepoint);
    try t.expectEqual(@as(u21, 0xF1C03), back[1].codepoint);
    try t.expectEqual(@as(u21, 0xF2000), back[2].codepoint);
    // A blank glyph comes back blank, not as a stray contour.
    try t.expectEqual(@as(usize, 0), back[0].contours.len);
    try t.expectEqual(@as(usize, 1), back[1].contours.len);
    try t.expectEqual(@as(usize, 2), back[2].contours.len);
    // All-on-curve in, all-on-curve out: the coordinates are the same
    // integers, not an approximation of them.
    for (a[0], back[1].contours[0]) |want, got| {
        try t.expectApproxEqAbs(want.x, got.x, 0.001);
        try t.expectApproxEqAbs(want.y, got.y, 0.001);
    }
    // Three glyphs plus `.notdef`: nothing unmapped rides along.
    try t.expectEqual(back.len, glyphCount(bytes) - 1);
}

test "each glyph's left side bearing is its own xMin, so a centred outline stays centred on screen" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A bar in the middle of the cell (the tree's vertical), a mark
    // that bleeds left of the cell, and a blank.
    const bar = [_]svg.Contour{try square(arena, 350, -400, 450, 1120)};
    const bleed = [_]svg.Contour{try square(arena, -90, 0, 690, 500)};
    const bytes = try build(arena, &.{
        .{ .codepoint = 0x20, .name = "space", .contours = Glyph.empty },
        .{ .codepoint = 0xF1F04, .name = "bar", .contours = &bar },
        .{ .codepoint = 0xF1E00, .name = "bleed", .contours = &bleed },
    }, "MnmlSymbols", "1.0");
    const hmtx = (try tableOf(bytes, "hmtx")).?;
    // .notdef, space, bar, bleed — four longHorMetric of advance + lsb.
    try t.expectEqual(@as(usize, 16), hmtx.len);
    try t.expectEqual(@as(i16, 0), try rdI16(hmtx, 2));
    try t.expectEqual(@as(i16, 0), try rdI16(hmtx, 6));
    try t.expectEqual(@as(i16, 350), try rdI16(hmtx, 10));
    try t.expectEqual(@as(i16, -90), try rdI16(hmtx, 14));
}

test "the reader flattens a quadratic into the straight edges the writer needs" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // One arch: on (0,0) → control (100,200) → on (200,0). The control
    // point is NOT on the curve, so it must not appear in the polygon;
    // the curve's own apex is (100,100).
    const arch = [_]RawPoint{
        .{ .x = 0, .y = 0, .on = true },
        .{ .x = 100, .y = 200, .on = false },
        .{ .x = 200, .y = 0, .on = true },
    };
    const c = (try flattenContour(arena, &arch)).?;
    try t.expectApproxEqAbs(@as(f64, 0), c[0].x, 0.001);
    try t.expectApproxEqAbs(@as(f64, 200), c[c.len - 1].x, 0.001);
    var apex: f64 = 0;
    for (c) |p| apex = @max(apex, p.y);
    try t.expectApproxEqAbs(@as(f64, 100), apex, 0.001);
    // Never the control point itself, and never a straight chord.
    try t.expect(c.len > 3);
    for (c) |p| try t.expect(p.y <= 100.001);

    // A contour with NO on-curve point at all — four controls of a
    // circle — starts at the implied midpoint of the last and the first.
    const ring = [_]RawPoint{
        .{ .x = 0, .y = 100, .on = false },
        .{ .x = 100, .y = 100, .on = false },
        .{ .x = 100, .y = 0, .on = false },
        .{ .x = 0, .y = 0, .on = false },
    };
    const r = (try flattenContour(arena, &ring)).?;
    try t.expectApproxEqAbs(@as(f64, 0), r[0].x, 0.001);
    try t.expectApproxEqAbs(@as(f64, 50), r[0].y, 0.001);
    try t.expect(r.len >= 8);
}

test "the reader refuses what it cannot lift rather than returning half a face" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectError(error.NotTrueType, read(arena, "not a font"));
    try t.expectError(error.NotTrueType, read(arena, &[_]u8{ 'O', 'T', 'T', 'O', 0, 0, 0, 0, 0, 0, 0, 0 }));
    // A directory that promises a table the file does not hold.
    var headless: [12]u8 = .{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try t.expectError(error.MissingTable, read(arena, &headless));
}
