//! The diff pane's paint in its three views.
//!
//! * **Hunk** — one row per file header, hunk header and diff line, a
//!   two-column line-number gutter (old | new), `+` lines in the add
//!   colour and `-` lines in the delete colour.
//! * **Inline** — the whole file as one continuous column (the app
//!   fetches full context for it): no hunk headers, one line-number
//!   column, changed rows tinted.
//! * **Split** — old on the left, new on the right, hunks aligned pair
//!   by pair; a divider the pointer can drag.
//!
//! Every view shares the header (title, then the three view chips), the
//! `/` filter banner, intraline highlighting on a removed / added pair
//! (`src/git/intraline.zig`), and the change-density strip on the right
//! edge — one cell per band of rows, green / red / yellow for what the
//! band holds, clickable to jump there.
//!
//! The app owns the parsed files and the flattened rows (`flatten`,
//! `pairs`); the view keeps only the scroll. Rows register
//! `.script_hit{ pane, id = row index }`; the chips, the divider and the
//! strip use ids above `special_base` (`chipId`, `divider_id`,
//! `stripId`) so one prong in the app can tell them apart.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const parse = @import("../git/parse.zig");
const intraline = @import("../git/intraline.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;
const PaneId = ids.PaneId;

pub const Mode = enum {
    hunk,
    flat,
    split,

    pub fn label(m: Mode) []const u8 {
        return switch (m) {
            .hunk => "Hunk",
            .flat => "Inline",
            .split => "Split",
        };
    }

    pub fn next(m: Mode) Mode {
        return switch (m) {
            .hunk => .flat,
            .flat => .split,
            .split => .hunk,
        };
    }

    /// Inline and Split show the whole file, so they need every line.
    pub fn wantsFullContext(m: Mode) bool {
        return m != .hunk;
    }
};

/// One painted row of the diff, addressing the parsed structure.
pub const Row = union(enum) {
    file: u32,
    hunk: struct { file: u32, hunk: u32 },
    line: struct { file: u32, hunk: u32, line: u32 },
    blank,
};

/// A split-view row: a file header, or one aligned pair — an index into
/// the hunk's lines on each side, null for the filler half.
pub const SplitRow = union(enum) {
    file: u32,
    pair: Pair,
    blank,
};

pub const Pair = struct { file: u32, hunk: u32, left: ?u32, right: ?u32 };

/// What a band of rows holds, for the density strip.
pub const Kind = enum { none, add, del, both };

// ─── hit ids ────────────────────────────────────────────────────────────

/// Row ids stay below this; everything above names a control.
pub const special_base: u32 = 0xF000_0000;
pub const divider_id: u32 = 0xF000_0001;
pub const filter_id: u32 = 0xF000_0002;
const chip_base: u32 = 0xF100_0000;
const strip_base: u32 = 0xF200_0000;

pub fn chipId(m: Mode) u32 {
    return chip_base + @intFromEnum(m);
}

pub fn chipOf(id: u32) ?Mode {
    if (id < chip_base or id >= chip_base + 3) return null;
    return @enumFromInt(id - chip_base);
}

pub fn stripId(cell: u16) u32 {
    return strip_base + cell;
}

pub fn stripCellOf(id: u32) ?u16 {
    if (id < strip_base or id >= strip_base + 0x1_0000) return null;
    return @intCast(id - strip_base);
}

// ─── rows ───────────────────────────────────────────────────────────────

/// The rows a diff paints: a file header, then per hunk its header and
/// lines, a blank between files.
pub fn flatten(arena: Allocator, files: []const parse.FileDiff) Allocator.Error![]Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    for (files, 0..) |f, fi| {
        if (fi > 0) try out.append(arena, .blank);
        try out.append(arena, .{ .file = @intCast(fi) });
        for (f.hunks, 0..) |h, hi| {
            try out.append(arena, .{ .hunk = .{ .file = @intCast(fi), .hunk = @intCast(hi) } });
            for (h.lines, 0..) |_, li| try out.append(arena, .{ .line = .{ .file = @intCast(fi), .hunk = @intCast(hi), .line = @intCast(li) } });
        }
    }
    return out.items;
}

/// The split view's rows: context lines on both sides, a run of removed
/// lines zipped with the run of added lines that follows it, the longer
/// run's tail against a filler.
pub fn pairs(arena: Allocator, files: []const parse.FileDiff) Allocator.Error![]SplitRow {
    var out: std.ArrayListUnmanaged(SplitRow) = .empty;
    for (files, 0..) |f, fi| {
        if (fi > 0) try out.append(arena, .blank);
        try out.append(arena, .{ .file = @intCast(fi) });
        for (f.hunks, 0..) |h, hi| {
            var i: usize = 0;
            while (i < h.lines.len) {
                const l = h.lines[i];
                switch (l.kind) {
                    .context, .meta => {
                        try out.append(arena, .{ .pair = .{ .file = @intCast(fi), .hunk = @intCast(hi), .left = @intCast(i), .right = @intCast(i) } });
                        i += 1;
                    },
                    .del => {
                        const del_start = i;
                        while (i < h.lines.len and h.lines[i].kind == .del) i += 1;
                        const add_start = i;
                        while (i < h.lines.len and h.lines[i].kind == .add) i += 1;
                        const n_del = add_start - del_start;
                        const n_add = i - add_start;
                        var k: usize = 0;
                        while (k < @max(n_del, n_add)) : (k += 1) {
                            try out.append(arena, .{ .pair = .{
                                .file = @intCast(fi),
                                .hunk = @intCast(hi),
                                .left = if (k < n_del) @intCast(del_start + k) else null,
                                .right = if (k < n_add) @intCast(add_start + k) else null,
                            } });
                        }
                    },
                    .add => {
                        try out.append(arena, .{ .pair = .{ .file = @intCast(fi), .hunk = @intCast(hi), .left = null, .right = @intCast(i) } });
                        i += 1;
                    },
                }
            }
        }
    }
    return out.items;
}

pub fn rowKind(files: []const parse.FileDiff, row: Row) Kind {
    return switch (row) {
        .line => |l| switch (files[l.file].hunks[l.hunk].lines[l.line].kind) {
            .add => .add,
            .del => .del,
            else => .none,
        },
        else => .none,
    };
}

pub fn splitRowKind(files: []const parse.FileDiff, row: SplitRow) Kind {
    return switch (row) {
        .pair => |p| blk: {
            const h = files[p.file].hunks[p.hunk];
            const l = if (p.left) |i| h.lines[i].kind == .del else false;
            const r = if (p.right) |i| h.lines[i].kind == .add else false;
            break :blk if (l and r) .both else if (l) .del else if (r) .add else .none;
        },
        else => .none,
    };
}

/// The strip: `cells` bands over `kinds`, each the union of its rows.
pub fn density(arena: Allocator, kinds: []const Kind, cells: usize) Allocator.Error![]Kind {
    const out = try arena.alloc(Kind, cells);
    @memset(out, .none);
    if (kinds.len == 0 or cells == 0) return out;
    for (0..cells) |cy| {
        const lo = cy * kinds.len / cells;
        const hi = @min(@max((cy + 1) * kinds.len / cells, lo + 1), kinds.len);
        var add = false;
        var del = false;
        for (kinds[lo..hi]) |k| switch (k) {
            .add => add = true,
            .del => del = true,
            .both => {
                add = true;
                del = true;
            },
            .none => {},
        };
        out[cy] = if (add and del) .both else if (add) .add else if (del) .del else .none;
    }
    return out;
}

/// The row a strip cell stands for (its band's first row).
pub fn stripCellRow(cell: usize, cells: usize, total: usize) usize {
    if (cells == 0 or total == 0) return 0;
    return @min(cell * total / cells, total - 1);
}

// ─── the filter ─────────────────────────────────────────────────────────

/// Case-insensitive substring over the hunk's lines.
pub fn hunkMatches(h: parse.Hunk, needle: []const u8) bool {
    if (needle.len == 0) return true;
    for (h.lines) |l| if (containsIgnoreCase(l.text, needle)) return true;
    return false;
}

pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// The rows to show under `needle`: every row of a matching hunk, the
/// file headers of files with a match, nothing else. An empty needle
/// keeps every row; `hide_hunks` drops hunk-header rows (the Inline
/// view has no use for them).
pub fn filterRows(arena: Allocator, files: []const parse.FileDiff, rows: []const Row, needle: []const u8, hide_hunks: bool) Allocator.Error![]u32 {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    for (rows, 0..) |r, i| {
        const keep = switch (r) {
            .blank => needle.len == 0,
            .file => |fi| needle.len == 0 or fileMatches(files[fi], needle),
            .hunk => |h| !hide_hunks and hunkMatches(files[h.file].hunks[h.hunk], needle),
            .line => |l| hunkMatches(files[l.file].hunks[l.hunk], needle),
        };
        if (keep) try out.append(arena, @intCast(i));
    }
    // Exact-size: the app keeps this on the gpa and frees it whole.
    return out.toOwnedSlice(arena);
}

pub fn filterSplitRows(arena: Allocator, files: []const parse.FileDiff, rows: []const SplitRow, needle: []const u8) Allocator.Error![]u32 {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    for (rows, 0..) |r, i| {
        const keep = switch (r) {
            .blank => needle.len == 0,
            .file => |fi| needle.len == 0 or fileMatches(files[fi], needle),
            .pair => |p| hunkMatches(files[p.file].hunks[p.hunk], needle),
        };
        if (keep) try out.append(arena, @intCast(i));
    }
    return out.toOwnedSlice(arena);
}

fn fileMatches(f: parse.FileDiff, needle: []const u8) bool {
    for (f.hunks) |h| if (hunkMatches(h, needle)) return true;
    return false;
}

// ─── styles ─────────────────────────────────────────────────────────────

pub fn addStyle(t: *const Theme, base: Style) Style {
    return Theme.withFg(base, t.syntax.string.fg);
}

pub fn delStyle(t: *const Theme, base: Style) Style {
    return Theme.withFg(base, t.error_fg.fg);
}

/// The changed words inside a paired line: the same colour, the
/// selection ground behind it.
pub fn emphStyle(t: *const Theme, base: Style) Style {
    var s = Theme.onBg(base, t.selection.bg);
    s.bold = true;
    return s;
}

fn filterHitStyle(t: *const Theme, base: Style) Style {
    var s = Theme.onBg(base, t.match.bg);
    s.bold = true;
    return s;
}

/// Width of the two-column gutter for the widest line number in `files`.
fn gutterWidth(files: []const parse.FileDiff) u16 {
    return 2 * @max(digitsOf(files), 3) + 3;
}

fn digitsOf(files: []const parse.FileDiff) u16 {
    var max: u32 = 1;
    for (files) |f| for (f.hunks) |h| {
        max = @max(max, h.old_start + h.old_count);
        max = @max(max, h.new_start + h.new_count);
    };
    var digits: u16 = 1;
    while (max >= 10) : (max /= 10) digits += 1;
    return digits;
}

// ─── the document ───────────────────────────────────────────────────────

pub const State = struct { scroll: usize = 0 };

pub const Doc = struct {
    files: []const parse.FileDiff,
    rows: []const Row,
    /// Indices into `rows` that pass the filter (every row when it is
    /// empty), in order.
    shown: []const u32,
    split_rows: []const SplitRow = &.{},
    split_shown: []const u32 = &.{},
    mode: Mode = .hunk,
    /// Index into `rows` (Hunk / Inline) or `split_rows` (Split).
    cursor: usize,
    focused: bool,
    header: []const u8,
    filter: []const u8 = "",
    filter_mode: bool = false,
    /// The old side's share of the split body, in percent.
    ratio: u16 = 50,
    intraline: bool = true,
};

/// What `draw` measured, for the app's drag and click handling.
pub const Painted = struct {
    /// The rows' area (below the header and the filter banner).
    body: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// The strip's cell count.
    strip_cells: u16 = 0,
};

/// A removed line's added partner (or an added line's removed one):
/// a lone `-` directly followed by a lone `+`.
pub fn partnerOf(lines: []const parse.DiffLine, i: usize) ?usize {
    const l = lines[i];
    if (l.kind == .del) {
        if (i + 1 >= lines.len or lines[i + 1].kind != .add) return null;
        if (i > 0 and lines[i - 1].kind == .del) return null;
        if (i + 2 < lines.len and lines[i + 2].kind == .add) return null;
        return i + 1;
    }
    if (l.kind == .add) {
        if (i == 0 or lines[i - 1].kind != .del) return null;
        if (i + 1 < lines.len and lines[i + 1].kind == .add) return null;
        if (i >= 2 and lines[i - 2].kind == .del) return null;
        return i - 1;
    }
    return null;
}

pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *State, doc: Doc) Painted {
    const t = ui.theme;
    ui.fill(area, t.bg);
    var painted: Painted = .{};
    if (area.isEmpty()) return painted;
    drawHeader(ui, pane, area.row(0), doc);
    if (area.h < 2) return painted;
    var body = area.splitTop(1).rest;
    if (doc.filter_mode or doc.filter.len > 0) {
        drawFilterBanner(ui, pane, body.row(0), doc);
        body = body.splitTop(1).rest;
        if (body.isEmpty()) return painted;
    }
    painted.body = body;
    const total = if (doc.mode == .split) doc.split_shown.len else doc.shown.len;
    if (total == 0) {
        const msg: []const u8 = if (doc.files.len == 0) "No differences." else if (doc.filter.len > 0) "No hunk matches the filter." else "";
        _ = ui.putStr(body.x + 2, body.y + 1, body.w -| 2, msg, Theme.onBg(t.muted, t.bg.bg));
        return painted;
    }
    // The strip takes the right edge when there is room for it.
    var rows_area = body;
    var strip: ?Rect = null;
    if (body.w > 8) {
        const s = body.splitRight(1);
        rows_area = s.left;
        strip = s.rest;
    }
    const cursor_pos = shownIndex(doc, total);
    const win = list_panel.scrollWindow(&view.scroll, cursor_pos, total, rows_area.h);
    switch (doc.mode) {
        .hunk, .flat => drawUnified(ui, pane, rows_area, doc, win.first),
        .split => drawSplit(ui, pane, rows_area, doc, win.first),
    }
    if (strip) |s| {
        painted.strip_cells = s.h;
        drawStrip(ui, pane, s, doc, win.first, rows_area.h);
    }
    return painted;
}

/// Where the cursor's row sits in the shown list (the nearest shown row
/// before it when the cursor's own row is filtered out).
fn shownIndex(doc: Doc, total: usize) usize {
    const shown = if (doc.mode == .split) doc.split_shown else doc.shown;
    var best: usize = 0;
    for (shown[0..total], 0..) |r, i| {
        if (r == doc.cursor) return i;
        if (r < doc.cursor) best = i;
    }
    return best;
}

fn drawHeader(ui: Ui, pane: PaneId, r: Rect, doc: Doc) void {
    const t = ui.theme;
    var x = r.x;
    const end = r.right();
    x += ui.putStr(x, r.y, end -| x, ui.clipStr(doc.header, end -| x), Theme.onBg(t.accent, t.bg.bg));
    // The three view chips, `[Split]` for the active one.
    inline for (.{ Mode.hunk, Mode.flat, Mode.split }) |m| {
        const active = doc.mode == m;
        const label = if (active) ui.fmt("[{s}]", .{m.label()}) else ui.fmt(" {s} ", .{m.label()});
        const w = ui.width(label);
        if (x + w + 1 <= end) {
            const style = if (active) Theme.onBg(t.chip_active, t.bg.bg) else Theme.onBg(t.muted, t.bg.bg);
            const cr = Rect.init(x, r.y, w, 1);
            _ = ui.putStr(x, r.y, w, label, style);
            ui.hit(cr, .{ .script_hit = .{ .pane = pane, .id = chipId(m) } });
            x += w + 1;
        }
    }
}

fn drawFilterBanner(ui: Ui, pane: PaneId, r: Rect, doc: Doc) void {
    const t = ui.theme;
    const label = if (doc.filter_mode) ui.fmt(" / {s}_", .{doc.filter}) else ui.fmt(" filter: {s}", .{doc.filter});
    const hint: []const u8 = if (doc.filter_mode) "  enter keeps · esc clears" else "  n / p next match · esc clears";
    ui.fill(r, t.panel_bg);
    var x = r.x;
    x += ui.putStr(x, r.y, r.w, ui.clipStr(label, r.w), Theme.onBg(t.warn_fg, t.panel_bg.bg));
    _ = ui.putStr(x, r.y, r.right() -| x, hint, Theme.onBg(t.muted, t.panel_bg.bg));
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = filter_id } });
}

/// Paints `text` from `x`, `base` styled, the intraline `ranges` in the
/// emphasis style and the filter's matches in the match style. A tab
/// paints as four cells; the ranges index the text as given.
fn paintLine(ui: Ui, x: u16, y: u16, max_w: u16, text: []const u8, base: Style, ranges: []const intraline.Range, doc: Doc) void {
    const t = ui.theme;
    var used: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const bytes = g.bytes(text);
        var style = base;
        if (intraline.contains(ranges, g.start)) style = emphStyle(t, base);
        if (doc.filter.len > 0 and inFilterMatch(text, g.start, doc.filter)) style = filterHitStyle(t, style);
        if (bytes.len == 1 and bytes[0] == '\t') {
            var k: u16 = 0;
            while (k < 4 and used < max_w) : (k += 1) {
                ui.canvas.put(x + used, y, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
                used += 1;
            }
            continue;
        }
        const w = ui.canvas.cellWidth(bytes);
        if (w == 0) continue;
        if (used + w > max_w) break;
        ui.canvas.put(x + used, y, .{ .char = .{ .grapheme = bytes, .width = @intCast(w) }, .style = style });
        used += w;
    }
}

fn inFilterMatch(text: []const u8, b: usize, needle: []const u8) bool {
    if (needle.len == 0 or b >= text.len) return false;
    const lo = b -| (needle.len - 1);
    var i = lo;
    while (i <= b and i + needle.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// The intraline ranges of `lines[li]` when it has a partner.
fn rangesFor(ui: Ui, lines: []const parse.DiffLine, li: usize, doc: Doc) []const intraline.Range {
    if (!doc.intraline) return &.{};
    const p = partnerOf(lines, li) orelse return &.{};
    const a = lines[li];
    const b = lines[p];
    if (a.kind == .del) {
        const r = intraline.diff(ui.arena, a.text, b.text) catch return &.{};
        return r.old;
    }
    const r = intraline.diff(ui.arena, b.text, a.text) catch return &.{};
    return r.new;
}

fn fileLabel(ui: Ui, f: parse.FileDiff) []const u8 {
    const tag: []const u8 = switch (f.status) {
        .added => "new file",
        .deleted => "deleted",
        .renamed => "renamed",
        .modified => "modified",
    };
    const bar: []const u8 = if (ui.ascii) "==" else "──";
    if (f.status == .renamed and f.old_path != null)
        return ui.fmt("{s} {s} → {s}  ({d} hunk{s}, {s})", .{ bar, f.old_path.?, f.path(), f.hunks.len, if (f.hunks.len == 1) "" else "s", tag });
    return ui.fmt("{s} {s}  ({d} hunk{s}, {s}{s})", .{ bar, f.path(), f.hunks.len, if (f.hunks.len == 1) "" else "s", tag, if (f.binary) ", binary" else "" });
}

fn drawUnified(ui: Ui, pane: PaneId, body: Rect, doc: Doc, first: usize) void {
    const t = ui.theme;
    const digits = @max(digitsOf(doc.files), 3);
    const gw: u16 = if (doc.mode == .flat) digits + 2 else gutterWidth(doc.files);
    const num_w: u16 = if (doc.mode == .flat) digits else (gw - 3) / 2;
    var y: u16 = 0;
    var i = first;
    while (i < doc.shown.len and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const ri = doc.shown[i];
        const r = body.row(y);
        const sel = ri == doc.cursor and doc.focused;
        var base: Style = if (sel) Theme.onBg(t.fg, t.cursor_line.bg) else t.bg;
        if (sel) ui.fill(r, t.cursor_line);
        const text_x = r.x + gw;
        const text_w = r.w -| gw;
        switch (doc.rows[ri]) {
            .blank => {},
            .file => |fi| {
                var s = Theme.onBg(t.accent, base.bg);
                s.bold = true;
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(fileLabel(ui, doc.files[fi]), r.w), s);
            },
            .hunk => |h| {
                const hunk = doc.files[h.file].hunks[h.hunk];
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(hunk.header, r.w), Theme.onBg(t.info_fg, base.bg));
            },
            .line => |l| {
                const lines = doc.files[l.file].hunks[l.hunk].lines;
                const line = lines[l.line];
                // Inline tints the whole row so a change reads without
                // the sign column.
                if (doc.mode == .flat and !sel and line.kind != .context) {
                    base = Theme.onBg(base, t.panel_bg.bg);
                    ui.fill(r, base);
                }
                const style: Style = switch (line.kind) {
                    .add => addStyle(t, base),
                    .del => delStyle(t, base),
                    .context => base,
                    .meta => Theme.onBg(t.muted, base.bg),
                };
                const gstyle = Theme.onBg(t.gutter, base.bg);
                if (doc.mode == .flat) {
                    if (line.new_no orelse line.old_no) |n| _ = ui.putStrRight(r.x + num_w, r.y, num_w, ui.fmt("{d}", .{n}), gstyle);
                } else {
                    if (line.old_no) |n| _ = ui.putStrRight(r.x + num_w, r.y, num_w, ui.fmt("{d}", .{n}), gstyle);
                    if (line.new_no) |n| _ = ui.putStrRight(r.x + 2 * num_w + 1, r.y, num_w, ui.fmt("{d}", .{n}), gstyle);
                }
                const sign: []const u8 = switch (line.kind) {
                    .add => "+",
                    .del => "-",
                    .context => " ",
                    .meta => "\\",
                };
                _ = ui.putStr(r.x + gw - 1, r.y, 1, sign, style);
                paintLine(ui, text_x, r.y, text_w, line.text, style, rangesFor(ui, lines, l.line, doc), doc);
            },
        }
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = ri } });
    }
}

fn drawSplit(ui: Ui, pane: PaneId, body: Rect, doc: Doc, first: usize) void {
    const t = ui.theme;
    const num_w = @max(digitsOf(doc.files), 3);
    const ratio = std.math.clamp(doc.ratio, 15, 85);
    const left_w: u16 = @intCast(@as(u32, body.w -| 1) * ratio / 100);
    const div_x = body.x + left_w;
    const right_x = div_x + 1;
    const right_w = body.right() -| right_x;
    const div_glyph: []const u8 = if (ui.ascii) "|" else "│";
    var y: u16 = 0;
    var i = first;
    while (i < doc.split_shown.len and y < body.h) : ({
        i += 1;
        y += 1;
    }) {
        const ri = doc.split_shown[i];
        const r = body.row(y);
        const sel = ri == doc.cursor and doc.focused;
        const base: Style = if (sel) Theme.onBg(t.fg, t.cursor_line.bg) else t.bg;
        if (sel) ui.fill(r, t.cursor_line);
        switch (doc.split_rows[ri]) {
            .blank => {},
            .file => |fi| {
                var s = Theme.onBg(t.accent, base.bg);
                s.bold = true;
                _ = ui.putStr(r.x, r.y, r.w, ui.clipStr(fileLabel(ui, doc.files[fi]), r.w), s);
            },
            .pair => |p| {
                const lines = doc.files[p.file].hunks[p.hunk].lines;
                drawSide(ui, Rect.init(r.x, r.y, left_w, 1), lines, p.left, num_w, base, doc, true);
                drawSide(ui, Rect.init(right_x, r.y, right_w, 1), lines, p.right, num_w, base, doc, false);
            },
        }
        if (doc.split_rows[ri] == .pair) _ = ui.putStr(div_x, r.y, 1, div_glyph, Theme.onBg(t.border, base.bg));
        ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = ri } });
    }
    // Rows below the last one still carry the divider, and the whole
    // column is the drag handle — registered last so it wins the click.
    while (y < body.h) : (y += 1) _ = ui.putStr(div_x, body.y + y, 1, div_glyph, Theme.onBg(t.border, t.bg.bg));
    ui.hit(Rect.init(div_x, body.y, 1, body.h), .{ .script_hit = .{ .pane = pane, .id = divider_id } });
}

fn drawSide(ui: Ui, r: Rect, lines: []const parse.DiffLine, idx: ?u32, num_w: u16, base: Style, doc: Doc, left: bool) void {
    const t = ui.theme;
    const banded = !std.meta.eql(base.bg, t.bg.bg);
    const li = idx orelse {
        // A filler half: the panel ground so the alignment is visible.
        if (!banded) ui.fill(r, Theme.onBg(base, t.panel_bg.bg));
        return;
    };
    const line = lines[li];
    var side_base = base;
    if (line.kind != .context and !banded) {
        side_base = Theme.onBg(base, t.panel_bg.bg);
        ui.fill(r, side_base);
    }
    const style: Style = switch (line.kind) {
        .add => addStyle(t, side_base),
        .del => delStyle(t, side_base),
        .context => side_base,
        .meta => Theme.onBg(t.muted, side_base.bg),
    };
    const no = if (left) line.old_no else line.new_no;
    if (no) |n| _ = ui.putStrRight(r.x + num_w, r.y, num_w, ui.fmt("{d}", .{n}), Theme.onBg(t.gutter, side_base.bg));
    const text_x = r.x + num_w + 1;
    const text_w = r.right() -| text_x;
    paintLine(ui, text_x, r.y, text_w, line.text, style, rangesFor(ui, lines, li, doc), doc);
}

fn drawStrip(ui: Ui, pane: PaneId, s: Rect, doc: Doc, first: usize, visible: u16) void {
    const t = ui.theme;
    const total = if (doc.mode == .split) doc.split_shown.len else doc.shown.len;
    const kinds = ui.arena.alloc(Kind, total) catch return;
    for (0..total) |i| {
        kinds[i] = if (doc.mode == .split) splitRowKind(doc.files, doc.split_rows[doc.split_shown[i]]) else rowKind(doc.files, doc.rows[doc.shown[i]]);
    }
    const bands = density(ui.arena, kinds, s.h) catch return;
    // The visible window, as the thumb the strip doubles as.
    const scrolls = total > visible;
    const thumb_lo = if (total == 0) 0 else first * s.h / total;
    const thumb_hi = if (total == 0) 0 else @min(@max((first + visible) * s.h / total, thumb_lo + 1), s.h);
    for (bands, 0..) |k, cy| {
        const y: u16 = s.y + @as(u16, @intCast(cy));
        const in_thumb = scrolls and cy >= thumb_lo and cy < thumb_hi;
        const bg = if (in_thumb) t.cursor_line.bg else t.panel_bg.bg;
        const glyph: []const u8 = switch (k) {
            .none => if (in_thumb) (if (ui.ascii) "#" else "▌") else " ",
            else => if (ui.ascii) "|" else "▎",
        };
        const fg = switch (k) {
            .none => t.muted.fg,
            .add => t.syntax.string.fg,
            .del => t.error_fg.fg,
            .both => t.warn_fg.fg,
        };
        _ = ui.putStr(s.x, y, 1, glyph, Theme.onBg(Theme.withFg(t.bg, fg), bg));
        ui.hit(Rect.init(s.x, y, 1, 1), .{ .script_hit = .{ .pane = pane, .id = stripId(@intCast(cy)) } });
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const sample =
    "diff --git a/code.rs b/code.rs\n" ++
    "--- a/code.rs\n" ++
    "+++ b/code.rs\n" ++
    "@@ -1 +1 @@\n" ++
    "-fn alpha() {}\n" ++
    "+fn beta() {}\n";

fn identity(arena: Allocator, n: usize) ![]u32 {
    const out = try arena.alloc(u32, n);
    for (out, 0..) |*o, i| o.* = @intCast(i);
    return out;
}

test "flatten lists file, hunk and lines; draw paints the signs, the chips and registers row hits" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parse.parseDiff(a.allocator(), sample);
    const rows = try flatten(a.allocator(), files);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expect(rows[0] == .file);
    try testing.expect(rows[1] == .hunk);
    try testing.expect(rows[3] == .line);

    var f = try Fixture.init(60, 6);
    defer f.deinit();
    var st: State = .{};
    _ = draw(f.ui(), 2, Rect.init(0, 0, 60, 6), &st, .{ .files = files, .rows = rows, .shown = try identity(a.allocator(), rows.len), .cursor = 2, .focused = true, .header = " diff: code.rs " });
    try f.expectRow(0, " diff: code.rs [Hunk]  Inline   Split");
    try f.expectRow(1, "── code.rs  (1 hunk, modified)");
    try f.expectRow(2, "@@ -1 +1 @@");
    try f.expectRow(3, "  1     -fn alpha() {}");
    // The strip's band for the `-` line lands on this row: `▎` at x = 59.
    try f.expectRow(4, try std.fmt.allocPrint(a.allocator(), "{s:<59}▎", .{"      1 +fn beta() {}"}));
    try testing.expectEqual(@as(u32, 3), f.hits.at(5, 4).?.script_hit.id);
    try testing.expectEqual(chipId(.split), f.hits.at(33, 0).?.script_hit.id);
    // The strip sits on the right edge, one hit per cell.
    try testing.expect(stripCellOf(f.hits.at(59, 1).?.script_hit.id) != null);
}

test "intraline: the changed word of a paired line is emphasised, the rest is not" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parse.parseDiff(a.allocator(), sample);
    const rows = try flatten(a.allocator(), files);
    const lines = files[0].hunks[0].lines;
    try testing.expectEqual(@as(?usize, 1), partnerOf(lines, 0));
    try testing.expectEqual(@as(?usize, 0), partnerOf(lines, 1));
    var f = try Fixture.init(60, 6);
    defer f.deinit();
    var st: State = .{};
    _ = draw(f.ui(), 2, Rect.init(0, 0, 60, 6), &st, .{ .files = files, .rows = rows, .shown = try identity(a.allocator(), rows.len), .cursor = 0, .focused = false, .header = " d " });
    // Row 3 is `  1     -fn alpha() {}`: text starts at x = 9; the
    // changed span is `alph` (the trailing `a` is common with `beta`),
    // bytes 3..7 of the line → cells 12..15.
    const emph = emphStyle(&f.theme, delStyle(&f.theme, f.theme.bg));
    try testing.expect(f.bgEql(12, 3, emph));
    try testing.expect(f.bgEql(15, 3, emph));
    try testing.expect(!f.bgEql(9, 3, emph));
    try testing.expect(!f.bgEql(16, 3, emph));
    // The added side: `bet`, bytes 3..6 → cells 12..14.
    const emph_add = emphStyle(&f.theme, addStyle(&f.theme, f.theme.bg));
    try testing.expect(f.bgEql(12, 4, emph_add));
    try testing.expect(f.bgEql(14, 4, emph_add));
    try testing.expect(!f.bgEql(15, 4, emph_add));
}

const two_hunks =
    "diff --git a/a.txt b/a.txt\n" ++
    "--- a/a.txt\n" ++
    "+++ b/a.txt\n" ++
    "@@ -1,3 +1,3 @@\n" ++
    " keep\n" ++
    "-apple\n" ++
    "+apricot\n" ++
    " keep2\n" ++
    "@@ -10,3 +10,4 @@\n" ++
    " ctx\n" ++
    "-old one\n" ++
    "-old two\n" ++
    "+new one\n" ++
    "+new two\n" ++
    "+new three\n" ++
    " ctx2\n";

test "pairs: context on both sides, removed runs zipped with added runs, the tail against a filler" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parse.parseDiff(a.allocator(), two_hunks);
    const sr = try pairs(a.allocator(), files);
    // file, keep, apple/apricot, keep2, ctx, old one/new one, old two/new two, -/new three, ctx2
    try testing.expectEqual(@as(usize, 9), sr.len);
    try testing.expect(sr[0] == .file);
    try testing.expectEqual(@as(?u32, 0), sr[1].pair.left);
    try testing.expectEqual(@as(?u32, 0), sr[1].pair.right);
    try testing.expectEqual(@as(?u32, 1), sr[2].pair.left);
    try testing.expectEqual(@as(?u32, 2), sr[2].pair.right);
    try testing.expectEqual(@as(?u32, 1), sr[5].pair.left);
    try testing.expectEqual(@as(?u32, 3), sr[5].pair.right);
    try testing.expectEqual(@as(?u32, 2), sr[6].pair.left);
    try testing.expectEqual(@as(?u32, 4), sr[6].pair.right);
    try testing.expectEqual(@as(?u32, null), sr[7].pair.left);
    try testing.expectEqual(@as(?u32, 5), sr[7].pair.right);
    try testing.expectEqual(Kind.both, splitRowKind(files, sr[2]));
    try testing.expectEqual(Kind.add, splitRowKind(files, sr[7]));
    try testing.expectEqual(Kind.none, splitRowKind(files, sr[1]));
}

test "split draw: old left, new right, a divider hit spanning the body, aligned line numbers" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const files = try parse.parseDiff(arena, two_hunks);
    const rows = try flatten(arena, files);
    const sr = try pairs(arena, files);
    var f = try Fixture.init(61, 12);
    defer f.deinit();
    var st: State = .{};
    var ui = f.ui();
    ui.ascii = true;
    const p = draw(ui, 4, Rect.init(0, 0, 61, 12), &st, .{ .files = files, .rows = rows, .shown = try identity(arena, rows.len), .split_rows = sr, .split_shown = try identity(arena, sr.len), .mode = .split, .cursor = 2, .focused = true, .header = " d " });
    try testing.expectEqual(@as(u16, 1), p.body.y);
    // Body is 60 wide (strip takes 1); the left half is 29 cells, the
    // divider at x = 29, the right half from 30.
    // Column 60 is the density strip: a band with a change paints `|`.
    try f.expectRow(1, "== a.txt  (2 hunks, modified)");
    try f.expectRow(2, try std.fmt.allocPrint(arena, "{s:<29}|{s}", .{ "  1 keep", "  1 keep" }));
    try f.expectRow(3, try std.fmt.allocPrint(arena, "{s:<29}|{s}", .{ "  2 apple", "  2 apricot" }));
    try f.expectRow(8, try std.fmt.allocPrint(arena, "{s:<29}|{s:<30}|", .{ "", " 13 new three" }));
    try testing.expectEqual(divider_id, f.hits.at(29, 5).?.script_hit.id);
    try testing.expectEqual(divider_id, f.hits.at(29, 11).?.script_hit.id);
    try testing.expectEqual(@as(u32, 3), f.hits.at(3, 4).?.script_hit.id);
}

test "density: bands take the union of their rows; a strip cell maps back to its band's first row" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const kinds = [_]Kind{ .none, .add, .none, .del, .add, .none, .none, .none };
    const bands = try density(a.allocator(), &kinds, 4);
    try testing.expectEqual(Kind.add, bands[0]);
    try testing.expectEqual(Kind.del, bands[1]);
    try testing.expectEqual(Kind.add, bands[2]);
    try testing.expectEqual(Kind.none, bands[3]);
    const two = try density(a.allocator(), &[_]Kind{ .add, .del }, 1);
    try testing.expectEqual(Kind.both, two[0]);
    try testing.expectEqual(@as(usize, 4), stripCellRow(2, 4, 8));
    try testing.expectEqual(@as(usize, 7), stripCellRow(9, 4, 8));
    try testing.expectEqual(@as(usize, 0), stripCellRow(0, 0, 8));
}

test "filter: only the hunks holding the needle stay, with their file header; the inline view drops hunk rows" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parse.parseDiff(a.allocator(), two_hunks);
    const rows = try flatten(a.allocator(), files);
    try testing.expectEqual(rows.len, (try filterRows(a.allocator(), files, rows, "", false)).len);
    const shown = try filterRows(a.allocator(), files, rows, "APRIC", false);
    // file, hunk 1 header, its four lines.
    try testing.expectEqual(@as(usize, 6), shown.len);
    try testing.expect(rows[shown[0]] == .file);
    try testing.expect(rows[shown[1]] == .hunk);
    try testing.expectEqual(@as(u32, 0), rows[shown[1]].hunk.hunk);
    const none = try filterRows(a.allocator(), files, rows, "zzz", false);
    try testing.expectEqual(@as(usize, 0), none.len);
    const inline_rows = try filterRows(a.allocator(), files, rows, "", true);
    for (inline_rows) |i| try testing.expect(rows[i] != .hunk);
    const sr = try pairs(a.allocator(), files);
    const split_shown = try filterSplitRows(a.allocator(), files, sr, "three");
    // file + the second hunk's five pairs.
    try testing.expectEqual(@as(usize, 6), split_shown.len);
}
