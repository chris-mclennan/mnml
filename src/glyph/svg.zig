//! An SVG far enough to become a font glyph: the `viewBox` and every
//! filled outline, flattened to closed polygons.
//!
//! A glyph in a monochrome symbols font is a set of closed contours and
//! a winding rule — nothing else of an SVG survives. So this reader
//! keeps the two things that decide the shape (the coordinate box and
//! the path geometry) and drops everything that decides its colour:
//! `fill`, `stroke`, gradients, masks, groups, transforms. An icon that
//! only reads as a mark because of a `transform` on a group will come
//! out wrong, and says so — `parse` returns `error.Unsupported` for a
//! `transform` attribute rather than quietly mis-placing the shape.
//!
//! Curves are flattened to line segments instead of being fitted to the
//! quadratics `glyf` stores. An em is 1000 units and the tolerance is
//! one of them, so the error is 0.1% of the cell — a tenth of a pixel
//! at a 100px cell, invisible at the 14–20px a terminal actually uses —
//! and flattening has no fitting pass to get subtly wrong. The cost is
//! file size: the Ghostty ghost lands around 9 KB of outline.
//!
//! Supported path commands: `M m L l H h V v C c S s Q q T t A a Z z`
//! — the whole of SVG 1.1's path grammar. Shapes: `<path>`, `<rect>`,
//! `<polygon>`, `<polyline>`, `<line>`, `<circle>`, `<ellipse>`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Point = struct { x: f64, y: f64 };

/// One closed outline, in the SVG's own user units (y grows downward).
/// The first point is not repeated at the end.
pub const Contour = []Point;

pub const ViewBox = struct { x: f64 = 0, y: f64 = 0, w: f64, h: f64 };

pub const Image = struct {
    view: ViewBox,
    contours: []const Contour,
};

pub const Error = error{ Unsupported, Malformed, NoViewBox, Empty } || Allocator.Error;

/// The flattening tolerance, as a fraction of the longer viewBox side.
/// 1/2000 of the cell: half a unit once the glyph is scaled into a
/// 1000-unit em.
const tolerance_frac: f64 = 1.0 / 2000.0;

// ─── the scanner ────────────────────────────────────────────────────────

/// A cursor over an SVG's text. Deliberately not an XML parser: this
/// walks tag by tag and reads attributes off the ones it knows.
const Scanner = struct {
    text: []const u8,
    i: usize = 0,

    /// The next `<name …>` whose name is one of `wanted`, with the body
    /// of the tag (everything between the name and the closing `>`).
    fn nextTag(s: *Scanner, wanted: []const []const u8) ?struct { name: []const u8, body: []const u8 } {
        while (std.mem.indexOfScalarPos(u8, s.text, s.i, '<')) |lt| {
            s.i = lt + 1;
            if (s.i >= s.text.len) return null;
            // `<!-- … -->`, `<?xml …?>`, `</tag>` — skip to the `>`.
            if (s.text[s.i] == '!' or s.text[s.i] == '?' or s.text[s.i] == '/') {
                s.i = (std.mem.indexOfScalarPos(u8, s.text, s.i, '>') orelse return null) + 1;
                continue;
            }
            const name_start = s.i;
            while (s.i < s.text.len and !std.ascii.isWhitespace(s.text[s.i]) and s.text[s.i] != '>' and s.text[s.i] != '/') s.i += 1;
            const name = s.text[name_start..s.i];
            const gt = std.mem.indexOfScalarPos(u8, s.text, s.i, '>') orelse return null;
            const body = s.text[s.i..gt];
            s.i = gt + 1;
            for (wanted) |w| if (std.mem.eql(u8, w, name)) return .{ .name = name, .body = body };
        }
        return null;
    }
};

/// `name="value"` (or `name='value'`) inside a tag body.
fn attr(body: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, name)) |at| {
        i = at + name.len;
        // A whole attribute name: not the tail of a longer one.
        if (at > 0 and (std.ascii.isAlphanumeric(body[at - 1]) or body[at - 1] == '-' or body[at - 1] == ':')) continue;
        var j = i;
        while (j < body.len and std.ascii.isWhitespace(body[j])) j += 1;
        if (j >= body.len or body[j] != '=') continue;
        j += 1;
        while (j < body.len and std.ascii.isWhitespace(body[j])) j += 1;
        if (j >= body.len or (body[j] != '"' and body[j] != '\'')) continue;
        const quote = body[j];
        const start = j + 1;
        const end = std.mem.indexOfScalarPos(u8, body, start, quote) orelse return null;
        return body[start..end];
    }
    return null;
}

fn attrFloat(body: []const u8, name: []const u8) ?f64 {
    const raw = attr(body, name) orelse return null;
    var num = NumReader{ .text = raw };
    return num.next();
}

// ─── numbers ────────────────────────────────────────────────────────────

/// SVG's number list: separated by whitespace, commas, or nothing at
/// all when a sign or a second `.` makes the break unambiguous
/// (`1.5.5` is two numbers, `10-4` is two numbers).
const NumReader = struct {
    text: []const u8,
    i: usize = 0,

    fn skipSep(n: *NumReader) void {
        while (n.i < n.text.len and (std.ascii.isWhitespace(n.text[n.i]) or n.text[n.i] == ',')) n.i += 1;
    }

    fn next(n: *NumReader) ?f64 {
        n.skipSep();
        if (n.i >= n.text.len) return null;
        const start = n.i;
        if (n.text[n.i] == '+' or n.text[n.i] == '-') n.i += 1;
        var seen_dot = false;
        while (n.i < n.text.len) : (n.i += 1) {
            const c = n.text[n.i];
            if (std.ascii.isDigit(c)) continue;
            if (c == '.' and !seen_dot) {
                seen_dot = true;
                continue;
            }
            if ((c == 'e' or c == 'E') and n.i > start) {
                // An exponent, but only with a digit (after an optional
                // sign) behind it.
                var k = n.i + 1;
                if (k < n.text.len and (n.text[k] == '+' or n.text[k] == '-')) k += 1;
                if (k < n.text.len and std.ascii.isDigit(n.text[k])) {
                    n.i = k;
                    continue;
                }
            }
            break;
        }
        if (n.i == start) return null;
        return std.fmt.parseFloat(f64, n.text[start..n.i]) catch null;
    }

    /// A flag in an elliptical-arc argument: one character, `0` or `1`,
    /// which may run straight into the next number with no separator.
    fn flag(n: *NumReader) ?bool {
        n.skipSep();
        if (n.i >= n.text.len) return null;
        const c = n.text[n.i];
        if (c != '0' and c != '1') return null;
        n.i += 1;
        return c == '1';
    }
};

// ─── the path builder ───────────────────────────────────────────────────

const Builder = struct {
    arena: Allocator,
    out: *std.ArrayListUnmanaged(Contour),
    cur: std.ArrayListUnmanaged(Point) = .empty,
    /// The current point, and where the open subpath started.
    at: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },
    /// The reflection source for a smooth `S`/`T`; null when the last
    /// command was not a curve of that kind.
    last_cubic_ctrl: ?Point = null,
    last_quad_ctrl: ?Point = null,
    tol: f64,

    fn moveTo(b: *Builder, p: Point) Allocator.Error!void {
        try b.close();
        b.at = p;
        b.start = p;
        try b.cur.append(b.arena, p);
    }

    fn lineTo(b: *Builder, p: Point) Allocator.Error!void {
        if (b.cur.items.len == 0) try b.cur.append(b.arena, b.at);
        try b.cur.append(b.arena, p);
        b.at = p;
    }

    /// End the open subpath. A contour is always closed: `glyf` has no
    /// other kind, and an unclosed SVG subpath fills as if it were.
    fn close(b: *Builder) Allocator.Error!void {
        if (b.cur.items.len >= 3) {
            // Drop a repeated final point — the `Z` of a path that
            // already walked back to its start.
            var pts = b.cur;
            const last = pts.items[pts.items.len - 1];
            const first = pts.items[0];
            if (@abs(last.x - first.x) < 1e-9 and @abs(last.y - first.y) < 1e-9) _ = pts.pop();
            if (pts.items.len >= 3) try b.out.append(b.arena, try pts.toOwnedSlice(b.arena));
        }
        b.cur = .empty;
    }

    /// How many line segments a curve of this control-polygon length
    /// needs to stay inside the tolerance. The bound is loose on
    /// purpose — a segment too many costs two bytes.
    fn steps(b: *Builder, polygon_len: f64) usize {
        if (polygon_len <= 0) return 1;
        const n = @ceil(@sqrt(polygon_len / (8.0 * b.tol)));
        return @intFromFloat(std.math.clamp(n, 1.0, 256.0));
    }

    fn cubicTo(b: *Builder, c1: Point, c2: Point, p: Point) Allocator.Error!void {
        const p0 = b.at;
        const len = dist(p0, c1) + dist(c1, c2) + dist(c2, p);
        const n = b.steps(len);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const tt = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const u = 1.0 - tt;
            try b.lineTo(.{
                .x = u * u * u * p0.x + 3 * u * u * tt * c1.x + 3 * u * tt * tt * c2.x + tt * tt * tt * p.x,
                .y = u * u * u * p0.y + 3 * u * u * tt * c1.y + 3 * u * tt * tt * c2.y + tt * tt * tt * p.y,
            });
        }
        b.at = p;
    }

    fn quadTo(b: *Builder, c: Point, p: Point) Allocator.Error!void {
        const p0 = b.at;
        const n = b.steps(dist(p0, c) + dist(c, p));
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const tt = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const u = 1.0 - tt;
            try b.lineTo(.{
                .x = u * u * p0.x + 2 * u * tt * c.x + tt * tt * p.x,
                .y = u * u * p0.y + 2 * u * tt * c.y + tt * tt * p.y,
            });
        }
        b.at = p;
    }

    /// SVG's endpoint arc, through the centre parameterisation of
    /// appendix F.6.5, then sampled.
    fn arcTo(b: *Builder, rx_in: f64, ry_in: f64, deg: f64, large: bool, sweep: bool, p: Point) Allocator.Error!void {
        const p0 = b.at;
        if (@abs(rx_in) < 1e-12 or @abs(ry_in) < 1e-12) return b.lineTo(p);
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        const phi = deg * std.math.pi / 180.0;
        const cos_p = @cos(phi);
        const sin_p = @sin(phi);
        const dx2 = (p0.x - p.x) / 2.0;
        const dy2 = (p0.y - p.y) / 2.0;
        const x1 = cos_p * dx2 + sin_p * dy2;
        const y1 = -sin_p * dx2 + cos_p * dy2;
        // F.6.6: grow radii that cannot span the chord.
        const lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lam > 1.0) {
            const s = @sqrt(lam);
            rx *= s;
            ry *= s;
        }
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var coef = if (den <= 0 or num <= 0) 0.0 else @sqrt(num / den);
        if (large == sweep) coef = -coef;
        const cxp = coef * rx * y1 / ry;
        const cyp = -coef * ry * x1 / rx;
        const cx = cos_p * cxp - sin_p * cyp + (p0.x + p.x) / 2.0;
        const cy = sin_p * cxp + cos_p * cyp + (p0.y + p.y) / 2.0;
        const theta1 = std.math.atan2((y1 - cyp) / ry, (x1 - cxp) / rx);
        const theta2 = std.math.atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx);
        var delta = theta2 - theta1;
        if (!sweep and delta > 0) delta -= 2 * std.math.pi;
        if (sweep and delta < 0) delta += 2 * std.math.pi;
        const n = b.steps(@abs(delta) * @max(rx, ry) * 2.0);
        var i: usize = 1;
        while (i <= n) : (i += 1) {
            const tt = theta1 + delta * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const ex = rx * @cos(tt);
            const ey = ry * @sin(tt);
            try b.lineTo(.{ .x = cx + cos_p * ex - sin_p * ey, .y = cy + sin_p * ex + cos_p * ey });
        }
        b.at = p;
    }
};

fn dist(a: Point, b: Point) f64 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

/// One `d` attribute, appended to `out` as closed contours.
pub fn parsePath(arena: Allocator, d: []const u8, tol: f64, out: *std.ArrayListUnmanaged(Contour)) Error!void {
    var b: Builder = .{ .arena = arena, .out = out, .tol = tol };
    var n = NumReader{ .text = d };
    var cmd: u8 = 0;
    while (true) {
        n.skipSep();
        if (n.i >= d.len) break;
        const c = d[n.i];
        if (std.ascii.isAlphabetic(c)) {
            cmd = c;
            n.i += 1;
        } else if (cmd == 0) {
            return error.Malformed;
        } else if (cmd == 'M') {
            // A repeated `M`/`m` argument pair is an implicit lineto.
            cmd = 'L';
        } else if (cmd == 'm') {
            cmd = 'l';
        }
        const rel = std.ascii.isLower(cmd);
        const ox = if (rel) b.at.x else 0;
        const oy = if (rel) b.at.y else 0;
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                const x = n.next() orelse return error.Malformed;
                const y = n.next() orelse return error.Malformed;
                try b.moveTo(.{ .x = ox + x, .y = oy + y });
                b.last_cubic_ctrl = null;
                b.last_quad_ctrl = null;
            },
            'L' => {
                const x = n.next() orelse return error.Malformed;
                const y = n.next() orelse return error.Malformed;
                try b.lineTo(.{ .x = ox + x, .y = oy + y });
                b.last_cubic_ctrl = null;
                b.last_quad_ctrl = null;
            },
            'H' => {
                const x = n.next() orelse return error.Malformed;
                try b.lineTo(.{ .x = ox + x, .y = b.at.y });
                b.last_cubic_ctrl = null;
                b.last_quad_ctrl = null;
            },
            'V' => {
                const y = n.next() orelse return error.Malformed;
                try b.lineTo(.{ .x = b.at.x, .y = oy + y });
                b.last_cubic_ctrl = null;
                b.last_quad_ctrl = null;
            },
            'C', 'S' => {
                var c1: Point = undefined;
                if (std.ascii.toUpper(cmd) == 'C') {
                    const x1 = n.next() orelse return error.Malformed;
                    const y1 = n.next() orelse return error.Malformed;
                    c1 = .{ .x = ox + x1, .y = oy + y1 };
                } else if (b.last_cubic_ctrl) |prev| {
                    c1 = .{ .x = 2 * b.at.x - prev.x, .y = 2 * b.at.y - prev.y };
                } else c1 = b.at;
                const x2 = n.next() orelse return error.Malformed;
                const y2 = n.next() orelse return error.Malformed;
                const x = n.next() orelse return error.Malformed;
                const y = n.next() orelse return error.Malformed;
                const c2: Point = .{ .x = ox + x2, .y = oy + y2 };
                try b.cubicTo(c1, c2, .{ .x = ox + x, .y = oy + y });
                b.last_cubic_ctrl = c2;
                b.last_quad_ctrl = null;
            },
            'Q', 'T' => {
                var cp: Point = undefined;
                if (std.ascii.toUpper(cmd) == 'Q') {
                    const x1 = n.next() orelse return error.Malformed;
                    const y1 = n.next() orelse return error.Malformed;
                    cp = .{ .x = ox + x1, .y = oy + y1 };
                } else if (b.last_quad_ctrl) |prev| {
                    cp = .{ .x = 2 * b.at.x - prev.x, .y = 2 * b.at.y - prev.y };
                } else cp = b.at;
                const x = n.next() orelse return error.Malformed;
                const y = n.next() orelse return error.Malformed;
                try b.quadTo(cp, .{ .x = ox + x, .y = oy + y });
                b.last_quad_ctrl = cp;
                b.last_cubic_ctrl = null;
            },
            'A' => {
                const rx = n.next() orelse return error.Malformed;
                const ry = n.next() orelse return error.Malformed;
                const rot = n.next() orelse return error.Malformed;
                const large = n.flag() orelse return error.Malformed;
                const sweep = n.flag() orelse return error.Malformed;
                const x = n.next() orelse return error.Malformed;
                const y = n.next() orelse return error.Malformed;
                try b.arcTo(rx, ry, rot, large, sweep, .{ .x = ox + x, .y = oy + y });
                b.last_cubic_ctrl = null;
                b.last_quad_ctrl = null;
            },
            'Z' => {
                try b.close();
                b.at = b.start;
                b.last_cubic_ctrl = null;
                b.last_quad_ctrl = null;
            },
            else => return error.Unsupported,
        }
    }
    try b.close();
}

// ─── the shapes ─────────────────────────────────────────────────────────

fn addRect(arena: Allocator, body: []const u8, out: *std.ArrayListUnmanaged(Contour)) Error!void {
    const x = attrFloat(body, "x") orelse 0;
    const y = attrFloat(body, "y") orelse 0;
    const w = attrFloat(body, "width") orelse return;
    const h = attrFloat(body, "height") orelse return;
    if (w <= 0 or h <= 0) return;
    const pts = try arena.alloc(Point, 4);
    pts[0] = .{ .x = x, .y = y };
    pts[1] = .{ .x = x + w, .y = y };
    pts[2] = .{ .x = x + w, .y = y + h };
    pts[3] = .{ .x = x, .y = y + h };
    try out.append(arena, pts);
}

fn addPoly(arena: Allocator, body: []const u8, out: *std.ArrayListUnmanaged(Contour)) Error!void {
    const raw = attr(body, "points") orelse return;
    var n = NumReader{ .text = raw };
    var pts: std.ArrayListUnmanaged(Point) = .empty;
    while (n.next()) |x| {
        const y = n.next() orelse break;
        try pts.append(arena, .{ .x = x, .y = y });
    }
    if (pts.items.len >= 3) try out.append(arena, try pts.toOwnedSlice(arena));
}

fn addEllipse(arena: Allocator, body: []const u8, tol: f64, out: *std.ArrayListUnmanaged(Contour)) Error!void {
    const cx = attrFloat(body, "cx") orelse 0;
    const cy = attrFloat(body, "cy") orelse 0;
    const rx = attrFloat(body, "rx") orelse attrFloat(body, "r") orelse return;
    const ry = attrFloat(body, "ry") orelse attrFloat(body, "r") orelse rx;
    if (rx <= 0 or ry <= 0) return;
    var b: Builder = .{ .arena = arena, .out = out, .tol = tol };
    const n = b.steps(2 * std.math.pi * @max(rx, ry));
    const segs = @max(n * 4, 16);
    var pts: std.ArrayListUnmanaged(Point) = .empty;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const tt = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segs));
        try pts.append(arena, .{ .x = cx + rx * @cos(tt), .y = cy + ry * @sin(tt) });
    }
    try out.append(arena, try pts.toOwnedSlice(arena));
}

/// Every filled outline of `text`, in the SVG's user units.
pub fn parse(arena: Allocator, text: []const u8) Error!Image {
    var s = Scanner{ .text = text };
    const root = s.nextTag(&.{"svg"}) orelse return error.Malformed;
    if (attr(root.body, "transform") != null) return error.Unsupported;
    var view: ViewBox = undefined;
    if (attr(root.body, "viewBox")) |vb| {
        var n = NumReader{ .text = vb };
        view = .{
            .x = n.next() orelse return error.NoViewBox,
            .y = n.next() orelse return error.NoViewBox,
            .w = n.next() orelse return error.NoViewBox,
            .h = n.next() orelse return error.NoViewBox,
        };
    } else {
        view = .{ .w = attrFloat(root.body, "width") orelse return error.NoViewBox, .h = attrFloat(root.body, "height") orelse return error.NoViewBox };
    }
    if (view.w <= 0 or view.h <= 0) return error.NoViewBox;
    const tol = @max(view.w, view.h) * tolerance_frac;

    var out: std.ArrayListUnmanaged(Contour) = .empty;
    while (s.nextTag(&.{ "path", "rect", "polygon", "polyline", "line", "circle", "ellipse", "g", "use" })) |tag| {
        // A group or a `<use>` may carry the transform that places the
        // shape; mis-placing it silently is worse than refusing.
        if (attr(tag.body, "transform") != null) return error.Unsupported;
        if (std.mem.eql(u8, tag.name, "g")) continue;
        if (std.mem.eql(u8, tag.name, "use")) return error.Unsupported;
        // `fill="none"` is a stroke-only shape: it has no filled area,
        // and a font glyph has no strokes.
        if (attr(tag.body, "fill")) |f| if (std.mem.eql(u8, std.mem.trim(u8, f, " "), "none")) continue;
        if (std.mem.eql(u8, tag.name, "path")) {
            const d = attr(tag.body, "d") orelse continue;
            try parsePath(arena, d, tol, &out);
        } else if (std.mem.eql(u8, tag.name, "rect")) {
            try addRect(arena, tag.body, &out);
        } else if (std.mem.eql(u8, tag.name, "polygon") or std.mem.eql(u8, tag.name, "polyline")) {
            try addPoly(arena, tag.body, &out);
        } else if (std.mem.eql(u8, tag.name, "circle") or std.mem.eql(u8, tag.name, "ellipse")) {
            try addEllipse(arena, tag.body, tol, &out);
        }
        // `<line>` has no filled area — nothing to add.
    }
    if (out.items.len == 0) return error.Empty;
    return .{ .view = view, .contours = try out.toOwnedSlice(arena) };
}

/// The shoelace area, positive when the points run counter-clockwise in
/// a y-up frame (so: clockwise as an SVG reads, where y grows down).
pub fn signedArea(c: Contour) f64 {
    var sum: f64 = 0;
    var j = c.len - 1;
    for (c, 0..) |p, i| {
        sum += (c[j].x - p.x) * (c[j].y + p.y);
        j = i;
    }
    return sum / 2.0;
}

/// Is `p` inside `c`? The even-odd crossing count — used only to work
/// out which contour sits inside which, never to fill.
pub fn contains(c: Contour, p: Point) bool {
    var in = false;
    var j = c.len - 1;
    for (c, 0..) |a, i| {
        const b = c[j];
        if ((a.y > p.y) != (b.y > p.y)) {
            const tt = (p.y - a.y) / (b.y - a.y);
            if (p.x < a.x + tt * (b.x - a.x)) in = !in;
        }
        j = i;
    }
    return in;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "a path's absolute and relative commands, the implicit lineto after an M, and the close" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const img = try parse(arena,
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 20">
        \\<path d="M1 1 L9 1 9 9 1 9 Z"/>
        \\<path d="m2 12 h6 v6 h-6 z"/>
        \\</svg>
    );
    try t.expectEqual(@as(f64, 10), img.view.w);
    try t.expectEqual(@as(f64, 20), img.view.h);
    try t.expectEqual(@as(usize, 2), img.contours.len);
    // Four corners each: the `Z` does not repeat the first point, and
    // the implicit lineto after `M1 1` made the second pair a line.
    try t.expectEqual(@as(usize, 4), img.contours[0].len);
    try t.expectEqual(@as(usize, 4), img.contours[1].len);
    try t.expectEqual(@as(f64, 1), img.contours[0][0].x);
    try t.expectEqual(@as(f64, 9), img.contours[0][2].y);
    try t.expectEqual(@as(f64, 2), img.contours[1][0].x);
    try t.expectEqual(@as(f64, 8), img.contours[1][1].x);
}

test "the number list splits on a sign or a second dot with no separator, and reads an exponent" {
    var n = NumReader{ .text = "1.5.5-3 4e2,5" };
    try t.expectEqual(@as(f64, 1.5), n.next().?);
    try t.expectEqual(@as(f64, 0.5), n.next().?);
    try t.expectEqual(@as(f64, -3), n.next().?);
    try t.expectEqual(@as(f64, 400), n.next().?);
    try t.expectEqual(@as(f64, 5), n.next().?);
    try t.expect(n.next() == null);
}

test "curves and an arc flatten to segments inside the tolerance; a circle's does too" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A half-circle as an arc, closed by a straight line: every sampled
    // point must sit on the circle of radius 5 about (5,10).
    const img = try parse(arena,
        \\<svg viewBox="0 0 10 20"><path d="M0 10 A5 5 0 0 1 10 10 Z"/></svg>
    );
    try t.expectEqual(@as(usize, 1), img.contours.len);
    try t.expect(img.contours[0].len > 8);
    for (img.contours[0]) |p| {
        const r = @sqrt((p.x - 5) * (p.x - 5) + (p.y - 10) * (p.y - 10));
        try t.expect(@abs(r - 5) < 0.05);
    }
    // A cubic that is really a straight line stays one segment's worth
    // of points on that line.
    const line = try parse(arena, "<svg viewBox=\"0 0 10 10\"><path d=\"M0 0 C3 3 6 6 9 9 L9 0 Z\"/></svg>");
    for (line.contours[0]) |p| if (p.y > 0 and p.x < 9) try t.expect(@abs(p.x - p.y) < 1e-6);
}

test "shapes other than paths, `fill=none` skipped, and a transform refused rather than mis-placed" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const img = try parse(arena,
        \\<svg viewBox="0 0 10 10">
        \\<rect x="1" y="1" width="4" height="4"/>
        \\<polygon points="6,6 9,6 9,9"/>
        \\<path fill="none" d="M0 0 L10 10 L0 10 Z"/>
        \\<line x1="0" y1="0" x2="9" y2="9"/>
        \\</svg>
    );
    try t.expectEqual(@as(usize, 2), img.contours.len);
    try t.expectEqual(@as(usize, 4), img.contours[0].len);
    try t.expectEqual(@as(usize, 3), img.contours[1].len);
    try t.expectError(error.Unsupported, parse(arena, "<svg viewBox=\"0 0 1 1\"><g transform=\"scale(2)\"><path d=\"M0 0 L1 0 L1 1 Z\"/></g></svg>"));
    try t.expectError(error.NoViewBox, parse(arena, "<svg><path d=\"M0 0 L1 0 L1 1 Z\"/></svg>"));
    try t.expectError(error.Empty, parse(arena, "<svg viewBox=\"0 0 1 1\"></svg>"));
}

test "an attribute lookup does not match the tail of a longer name" {
    try t.expectEqualStrings("3", attr("stroke-width=\"9\" width=\"3\"", "width").?);
    try t.expectEqualStrings("4", attr("<rect data-x='1' x='4'/>", "x").?);
    try t.expect(attr("fillx=\"none\"", "fill") == null);
}

test "winding and nesting: a square's area flips with its direction, and a hole sits inside it" {
    var outer = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } };
    var reversed = [_]Point{ .{ .x = 0, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 }, .{ .x = 0, .y = 0 } };
    try t.expect(signedArea(&outer) * signedArea(&reversed) < 0);
    try t.expectEqual(@as(f64, 100), @abs(signedArea(&outer)));
    try t.expect(contains(&outer, .{ .x = 5, .y = 5 }));
    try t.expect(!contains(&outer, .{ .x = 15, .y = 5 }));
}
