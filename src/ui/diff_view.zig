//! The diff pane's paint — the Rust editor's `diff_view.rs`, cell for
//! cell against `docs/ui-spec/rust-diff-120x40.txt`:
//!
//! ```text
//!  󰕌 Undo   󰑎 Redo    Pull    Push    Fetch    Branch    Commit    Stash   󰋚 Reflog
//!  Hunk   Inline   Split  │  Wrap                                                      ×
//! Hunk 1/1  src/main.rs                                                Stage   Discard
//!   1   1    fn main() {}
//!   2   2    y
//!       3 ▏+ z
//! ```
//!
//! Row 0 is the git toolbar (`git_toolbar.zig`), row 1 the diff toolbar
//! (the three view chips, a `│`, the Wrap toggle, the red `×`), then the
//! body: the `Hunk N/M  file` banner with the hunk's action chips
//! right-aligned (Stage / Discard on a worktree diff, Unstage on a
//! staged one), the `/` filter banner while one is set, and the rows.
//!
//! * **Inline** (the default) — the whole file as one column: a
//!   `<old> <new> ` gutter, the `▏` marker in the change's colour, the
//!   `+` / `-` sign, the text; changed rows sit on a tinted ground.
//! * **Hunk** — the same rows under a `▶ v @@ … @@  file +N -M` header
//!   per hunk with its own chips, a spacer row after each hunk.
//! * **Split** — old on the left, new on the right, hunks aligned pair
//!   by pair under a header row that spans both columns; a filler half
//!   is the `bg2` ground with a `·` sign.
//!
//! The right edge is three columns: a pad, the change-density strip
//! (`▎` per band — green / red / yellow for what the band holds; a
//! click jumps there) and the scrollbar (`bg2` track, `comment` thumb).
//!
//! A selection (`Doc.anchor`, the app's `v` / shift+arrows / a drag)
//! paints its rows on the editor's selection ground — the rows between
//! the anchor and the cursor that belong to the anchor's hunk — and the
//! app's line verbs act on those lines instead of the whole hunk.
//!
//! The app owns the parsed files and the flattened rows (`flatten`,
//! `pairs`); the view keeps only the scroll. Rows register
//! `.script_hit{ pane, id = row index }`; the toolbar chips, the banner
//! chips, the per-hunk chips and the strip use ids above `special_base`
//! so one prong in the app can tell them apart.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const list_panel = @import("list_panel.zig");
const git_toolbar = @import("git_toolbar.zig");
const parse = @import("../git/parse.zig");
const intraline = @import("../git/intraline.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;
const Color = vaxis.Color;
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
    hunk: HunkRef,
    line: struct { file: u32, hunk: u32, line: u32 },
    /// The spacer after a hunk.
    blank,
};

pub const HunkRef = struct { file: u32, hunk: u32 };

/// A split-view row: a hunk header spanning both columns, one aligned
/// pair — an index into the hunk's lines on each side, null for the
/// filler half — or the spacer after a hunk.
pub const SplitRow = union(enum) {
    hunk: HunkRef,
    pair: Pair,
    blank,
};

pub const Pair = struct { file: u32, hunk: u32, left: ?u32, right: ?u32 };

/// What a band of rows holds, for the density strip.
pub const Kind = enum { none, add, del, both };

/// Which action chips the diff's scope offers — Rust's
/// `chip_actions_for_scope`: a worktree / file / HEAD diff stages or
/// discards a hunk, a staged diff unstages one, a commit shows none.
pub const Actions = enum { none, unstaged, staged };

pub const Action = enum(u8) {
    stage,
    discard,
    unstage,

    pub fn label(a: Action) []const u8 {
        return switch (a) {
            .stage => " Stage ",
            .discard => " Discard ",
            .unstage => " Unstage ",
        };
    }

    fn color(a: Action, p: Theme.Palette) Color {
        return switch (a) {
            .stage => p.green,
            .discard => p.red,
            .unstage => p.orange,
        };
    }
};

pub fn actionsOf(actions: Actions) []const Action {
    return switch (actions) {
        .none => &.{},
        .unstaged => &.{ .stage, .discard },
        .staged => &.{.unstage},
    };
}

// ─── hit ids ────────────────────────────────────────────────────────────

/// Row ids stay below this; everything above names a control.
pub const special_base: u32 = 0xF000_0000;
/// The `/` filter banner: a press puts the keys in the filter.
pub const filter_id: u32 = 0xF000_0002;
/// The toolbar's ` Wrap ` toggle and its ` × `.
pub const wrap_id: u32 = 0xF000_0003;
pub const close_id: u32 = 0xF000_0004;
/// The banner's chips: the cursor hunk.
const action_base: u32 = 0xF000_0010;
const chip_base: u32 = 0xF100_0000;
const strip_base: u32 = 0xF200_0000;
/// A per-hunk header chip: `hunk_chip_base + row * 4 + action`.
const hunk_chip_base: u32 = 0xF400_0000;

pub fn chipId(m: Mode) u32 {
    return chip_base + @intFromEnum(m);
}

pub fn chipOf(id: u32) ?Mode {
    if (id < chip_base or id >= chip_base + 3) return null;
    return @enumFromInt(id - chip_base);
}

pub fn actionId(a: Action) u32 {
    return action_base + @intFromEnum(a);
}

pub fn actionOf(id: u32) ?Action {
    if (id < action_base or id >= action_base + 3) return null;
    return @enumFromInt(id - action_base);
}

pub fn stripId(cell: u16) u32 {
    return strip_base + cell;
}

pub fn stripCellOf(id: u32) ?u16 {
    if (id < strip_base or id >= strip_base + 0x1_0000) return null;
    return @intCast(id - strip_base);
}

pub const HunkChip = struct { row: u32, action: Action };

pub fn hunkChipId(row: u32, a: Action) u32 {
    return hunk_chip_base + row * 4 + @intFromEnum(a);
}

pub fn hunkChipOf(id: u32) ?HunkChip {
    if (id < hunk_chip_base or id >= hunk_chip_base + 0x0100_0000) return null;
    const off = id - hunk_chip_base;
    if (off % 4 >= 3) return null;
    return .{ .row = off / 4, .action = @enumFromInt(off % 4) };
}

// ─── rows ───────────────────────────────────────────────────────────────

/// The rows a diff paints: per hunk its header, its lines, a spacer.
pub fn flatten(arena: Allocator, files: []const parse.FileDiff) Allocator.Error![]Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    for (files, 0..) |f, fi| {
        for (f.hunks, 0..) |h, hi| {
            try out.append(arena, .{ .hunk = .{ .file = @intCast(fi), .hunk = @intCast(hi) } });
            for (h.lines, 0..) |_, li| try out.append(arena, .{ .line = .{ .file = @intCast(fi), .hunk = @intCast(hi), .line = @intCast(li) } });
            try out.append(arena, .blank);
        }
    }
    return out.items;
}

/// The split view's rows: per hunk its header, then context lines on
/// both sides, a run of removed lines zipped with the run of added
/// lines that follows it, the longer run's tail against a filler, and
/// a spacer.
pub fn pairs(arena: Allocator, files: []const parse.FileDiff) Allocator.Error![]SplitRow {
    var out: std.ArrayListUnmanaged(SplitRow) = .empty;
    for (files, 0..) |f, fi| {
        for (f.hunks, 0..) |h, hi| {
            try out.append(arena, .{ .hunk = .{ .file = @intCast(fi), .hunk = @intCast(hi) } });
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
            try out.append(arena, .blank);
        }
    }
    return out.items;
}

/// The hunk a row belongs to, if any.
pub fn rowHunk(row: Row) ?HunkRef {
    return switch (row) {
        .hunk => |h| h,
        .line => |l| .{ .file = l.file, .hunk = l.hunk },
        .blank => null,
    };
}

pub fn splitRowHunk(row: SplitRow) ?HunkRef {
    return switch (row) {
        .hunk => |h| h,
        .pair => |p| .{ .file = p.file, .hunk = p.hunk },
        .blank => null,
    };
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

/// The rows to show under `needle`: every row of a matching hunk,
/// nothing else. An empty needle keeps every row; `hide_hunks` drops
/// the hunk headers and the spacers (the Inline view is one continuous
/// file).
pub fn filterRows(arena: Allocator, files: []const parse.FileDiff, rows: []const Row, needle: []const u8, hide_hunks: bool) Allocator.Error![]u32 {
    var out: std.ArrayListUnmanaged(u32) = .empty;
    for (rows, 0..) |r, i| {
        const keep = switch (r) {
            .blank => !hide_hunks and needle.len == 0,
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
            .hunk => |h| hunkMatches(files[h.file].hunks[h.hunk], needle),
            .pair => |p| hunkMatches(files[p.file].hunks[p.hunk], needle),
        };
        if (keep) try out.append(arena, @intCast(i));
    }
    return out.toOwnedSlice(arena);
}

// ─── styles ─────────────────────────────────────────────────────────────

/// A whole added / removed line in its colour — the AI apply view's
/// unified preview (`ai_apply_view.zig`), which has no row tint.
pub fn addStyle(t: *const Theme, base: Style) Style {
    return Theme.withFg(base, t.syntax.string.fg);
}

pub fn delStyle(t: *const Theme, base: Style) Style {
    return Theme.withFg(base, t.error_fg.fg);
}

/// `fg` over `bg` at `alpha / 255` — Rust's `blend_over`; `fallback`
/// when either is not an RGB colour.
pub fn blendOver(fg: Color, bg: Color, alpha: u16, fallback: Color) Color {
    if (fg != .rgb or bg != .rgb) return fallback;
    const f = fg.rgb;
    const b = bg.rgb;
    const inv = 255 - alpha;
    var out: [3]u8 = undefined;
    for (0..3) |i| out[i] = @intCast((@as(u16, f[i]) * alpha + @as(u16, b[i]) * inv) / 255);
    return .{ .rgb = out };
}

/// The ground of an added row: the theme's green over the body at ~18 %.
pub fn addedRowBg(p: Theme.Palette) Color {
    return blendOver(p.green, p.bg_dark, 45, .{ .rgb = .{ 20, 48, 28 } });
}

pub fn removedRowBg(p: Theme.Palette) Color {
    return blendOver(p.red, p.bg_dark, 45, .{ .rgb = .{ 56, 22, 26 } });
}

fn digits(n: u32) u16 {
    var v = n;
    var d: u16 = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// Rust's `compute_gutter_width`: `<old> <new> `, each column sized to
/// its side's widest line number, three at least.
pub fn gutterWidth(files: []const parse.FileDiff) u16 {
    var max_old: u32 = 1;
    var max_new: u32 = 1;
    for (files) |f| for (f.hunks) |h| for (h.lines) |l| {
        if (l.old_no) |n| max_old = @max(max_old, n);
        if (l.new_no) |n| max_new = @max(max_new, n);
    };
    return @max(digits(max_old), 3) + 1 + @max(digits(max_new), 3) + 1;
}

/// `<old> <new> ` clamped to `gw` — empty slots are blank.
fn gutterText(ui: Ui, old_no: ?u32, new_no: ?u32, gw: u16) []const u8 {
    if (gw == 0) return "";
    const each: usize = (gw -| 2) / 2;
    const buf = ui.arena.alloc(u8, each * 2 + 2) catch return "";
    @memset(buf, ' ');
    inline for (.{ old_no, new_no }, 0..) |no, side| {
        if (no) |n| {
            var tmp: [12]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch "";
            const start = side * (each + 1);
            if (s.len <= each) @memcpy(buf[start + each - s.len .. start + each], s) else @memcpy(buf[start .. start + each], s[0..each]);
        }
    }
    return buf;
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
    mode: Mode = .flat,
    /// Index into `rows` (Hunk / Inline) or `split_rows` (Split).
    cursor: usize,
    /// The selection's other end (a row index like `cursor`); null when
    /// nothing is selected. The rows between it and the cursor that
    /// belong to ITS hunk paint on the editor's selection ground.
    anchor: ?usize = null,
    focused: bool,
    filter: []const u8 = "",
    filter_mode: bool = false,
    intraline: bool = true,
    /// The toolbar's Wrap: long lines continue on the next row.
    wrap: bool = false,
    /// Which chips the banner and the hunk headers carry.
    actions: Actions = .unstaged,
    /// The diff has not arrived yet (`  loading…` instead of `  (no changes)`).
    pending: bool = false,
    /// `Pop` joins the git toolbar after `Stash`.
    has_stash: bool = false,
    /// `ui.expand_indicator = triangle`: `▾` instead of `v` on hunk headers.
    triangle: bool = false,
};

/// What `draw` measured, for the app's click handling.
pub const Painted = struct {
    /// The rows' area (below the toolbars).
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

/// Rust's `draw`: the git toolbar when the pane is 8 rows and 40 cells
/// or more, the diff toolbar from 5 rows, the body below.
pub fn draw(ui: Ui, pane: PaneId, area: Rect, view: *State, doc: Doc) Painted {
    const p = ui.theme.palette;
    ui.fill(area, .{ .bg = p.bg_dark });
    var painted: Painted = .{};
    if (area.isEmpty()) return painted;
    var body = area;
    if (area.h >= 8 and area.w >= 40) {
        const s = body.splitTop(1);
        git_toolbar.draw(ui, s.top, .{ .pane = pane, .has_stash = doc.has_stash });
        body = s.rest;
    }
    if (area.h >= 5) {
        const s = body.splitTop(1);
        drawToolbar(ui, pane, s.top, doc);
        body = s.rest;
    }
    painted.body = body;
    if (body.isEmpty()) return painted;
    var hunks: usize = 0;
    for (doc.files) |f| hunks += f.hunks.len;
    if (hunks == 0) {
        // A binary file has no hunks; `(no changes)` is what the pane
        // says about a clean file, and the status pane had just called
        // this one modified. git's own line, with `--stat`'s sizes.
        const msg: []const u8 = if (doc.pending) "  loading\u{2026}" else if (binaryFile(doc.files)) |f| (if (f.bin_sizes) |sz|
            ui.fmt("  Binary file changed ({d} {s} {d} bytes)", .{ sz[0], if (ui.ascii) "->" else "\u{2192}", sz[1] })
        else
            "  Binary file changed") else "  (no changes)";
        _ = ui.putStr(body.x, body.y, body.w, msg, .{ .fg = p.comment, .bg = p.bg_dark });
        return painted;
    }
    // The right edge: a pad, the change strip, the scrollbar — when
    // the body is wide enough for them (Rust's per-view thresholds).
    const min_w: u16 = switch (doc.mode) {
        .flat => 18,
        .hunk => 17,
        .split => 34,
    };
    const pad_w: u16 = if (doc.mode == .hunk) 0 else 1;
    var rows_area = body;
    var strip: ?Rect = null;
    var bar: ?Rect = null;
    if (body.w >= min_w) {
        const reserved: u16 = 2 + pad_w;
        rows_area = Rect.init(body.x, body.y, body.w - reserved, body.h);
        strip = Rect.init(body.right() - 2, body.y, 1, body.h);
        bar = Rect.init(body.right() - 1, body.y, 1, body.h);
    }
    if (doc.mode == .split and rows_area.w < 16) {
        _ = ui.putStr(rows_area.x, rows_area.y, rows_area.w, " pane too narrow for split view ", .{ .fg = p.comment, .bg = p.bg_dark });
        return painted;
    }
    // The list: the banner, the filter banner, the shown rows.
    const list = List.init(ui, doc, rows_area.w);
    const total = list.len();
    const cursor_pos = list.prefix + shownIndex(doc);
    const win = list_panel.scrollWindow(&view.scroll, cursor_pos, total, rows_area.h);
    var y: u16 = 0;
    var i = win.first;
    while (i < total and y < rows_area.h) : (i += 1) {
        y += paintListRow(ui, pane, rows_area, y, list, i, doc);
    }
    if (strip) |s| {
        painted.strip_cells = s.h;
        drawStrip(ui, pane, s, list, doc);
    }
    if (bar) |b| drawScrollbar(ui, pane, b, total, win.first, rows_area.h);
    return painted;
}

/// Where the cursor's row sits in the shown list (the nearest shown row
/// before it when the cursor's own row is filtered out).
fn shownIndex(doc: Doc) usize {
    const shown = if (doc.mode == .split) doc.split_shown else doc.shown;
    var best: usize = 0;
    for (shown, 0..) |r, i| {
        if (r == doc.cursor) return i;
        if (r < doc.cursor) best = i;
    }
    return best;
}

/// The cursor's hunk, for the banner: the cursor row's, else the
/// first.
fn cursorHunk(doc: Doc) ?HunkRef {
    if (doc.mode == .split) {
        if (doc.cursor < doc.split_rows.len) if (splitRowHunk(doc.split_rows[doc.cursor])) |h| return h;
        for (doc.split_rows) |r| if (splitRowHunk(r)) |h| return h;
        return null;
    }
    if (doc.cursor < doc.rows.len) if (rowHunk(doc.rows[doc.cursor])) |h| return h;
    for (doc.rows) |r| if (rowHunk(r)) |h| return h;
    return null;
}

/// The selected rows: `lo..=hi` around the anchor and the cursor, and
/// the hunk the anchor sits in — a selection never crosses a hunk, so
/// a row of another hunk inside the range is not selected.
pub const Selection = struct { lo: usize, hi: usize, hunk: HunkRef };

pub fn selectionOf(doc: Doc) ?Selection {
    const a = doc.anchor orelse return null;
    const hunk = if (doc.mode == .split)
        (if (a < doc.split_rows.len) splitRowHunk(doc.split_rows[a]) else null)
    else
        (if (a < doc.rows.len) rowHunk(doc.rows[a]) else null);
    return .{ .lo = @min(a, doc.cursor), .hi = @max(a, doc.cursor), .hunk = hunk orelse return null };
}

/// Row `ri` (of the current view's list) is a selected line.
pub fn isSelected(doc: Doc, ri: usize) bool {
    const sel = selectionOf(doc) orelse return false;
    if (ri < sel.lo or ri > sel.hi) return false;
    if (doc.mode == .split) {
        if (ri >= doc.split_rows.len or doc.split_rows[ri] != .pair) return false;
        const h = splitRowHunk(doc.split_rows[ri]).?;
        return h.file == sel.hunk.file and h.hunk == sel.hunk.hunk;
    }
    if (ri >= doc.rows.len or doc.rows[ri] != .line) return false;
    const h = rowHunk(doc.rows[ri]).?;
    return h.file == sel.hunk.file and h.hunk == sel.hunk.hunk;
}

/// The hunk's ordinal across the files, 1-based, and the count.
fn hunkOrdinal(doc: Doc, at: HunkRef) struct { n: usize, of: usize } {
    var n: usize = 0;
    var of: usize = 0;
    for (doc.files, 0..) |f, fi| for (f.hunks, 0..) |_, hi| {
        of += 1;
        if (fi == at.file and hi == at.hunk) n = of;
    };
    return .{ .n = n, .of = of };
}

/// The virtual list the body scrolls: `prefix` rows (the banner while
/// the scope has actions, the filter banner while one is set) and then
/// the shown rows.
const List = struct {
    banner: bool,
    filter: bool,
    prefix: usize,
    shown: []const u32,
    /// The body width the banner's chips align to.
    w: u16,

    fn init(ui: Ui, doc: Doc, w: u16) List {
        _ = ui;
        var hunks: usize = 0;
        for (doc.files) |f| hunks += f.hunks.len;
        const banner = doc.actions != .none and hunks > 0;
        const filter = doc.filter_mode or doc.filter.len > 0;
        return .{
            .banner = banner,
            .filter = filter,
            .prefix = @as(usize, @intFromBool(banner)) + @intFromBool(filter),
            .shown = if (doc.mode == .split) doc.split_shown else doc.shown,
            .w = w,
        };
    }

    fn len(l: List) usize {
        return l.prefix + l.shown.len;
    }

    /// The kind of list row `i`, for the strip.
    fn kind(l: List, doc: Doc, i: usize) Kind {
        if (i < l.prefix) return .none;
        const ri = l.shown[i - l.prefix];
        return if (doc.mode == .split) splitRowKind(doc.files, doc.split_rows[ri]) else rowKind(doc.files, doc.rows[ri]);
    }
};

// ─── the toolbar ────────────────────────────────────────────────────────

/// ` Hunk   Inline   Split  │  Wrap … × ` — Rust's `draw_diff_toolbar`.
fn drawToolbar(ui: Ui, pane: PaneId, r: Rect, doc: Doc) void {
    const p = ui.theme.palette;
    const bg = p.bg_darker;
    ui.fill(r, .{ .bg = bg });
    const on: Style = .{ .fg = p.bg_dark, .bg = p.green, .bold = true };
    const off: Style = .{ .fg = p.fg, .bg = p.bg2, .bold = true };
    var x = r.x + 1;
    const Chip = struct { label: []const u8, id: u32, on: bool };
    const chips = [_]Chip{
        .{ .label = " Hunk ", .id = chipId(.hunk), .on = doc.mode == .hunk },
        .{ .label = " Inline ", .id = chipId(.flat), .on = doc.mode == .flat },
        .{ .label = " Split ", .id = chipId(.split), .on = doc.mode == .split },
        .{ .label = " Wrap ", .id = wrap_id, .on = doc.wrap },
    };
    for (chips, 0..) |c, i| {
        if (i == 3) x += ui.putStr(x, r.y, r.right() -| x, " \u{2502} ", .{ .fg = p.grey, .bg = bg });
        const w = ui.width(c.label);
        if (x + w > r.right()) break;
        _ = ui.putStr(x, r.y, w, c.label, if (c.on) on else off);
        ui.hit(Rect.init(x, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = c.id } });
        x += w;
        if (i < 2) x += 1;
    }
    // The red ` × ` at the right end, one cell in.
    const close = " \u{00D7} ";
    if (r.right() > 4) {
        const cx = r.right() - 4;
        if (cx >= x) {
            _ = ui.putStr(cx, r.y, 3, close, .{ .fg = p.bg_dark, .bg = p.red, .bold = true });
            ui.hit(Rect.init(cx, r.y, 3, 1), .{ .script_hit = .{ .pane = pane, .id = close_id } });
        }
    }
}

// ─── the body ───────────────────────────────────────────────────────────

/// Paints list row `i` at `y` and returns the screen rows it took (a
/// wrapped line takes several).
fn paintListRow(ui: Ui, pane: PaneId, area: Rect, y: u16, list: List, i: usize, doc: Doc) u16 {
    const r = area.row(y);
    if (i < list.prefix) {
        if (i == 0 and list.banner) drawBanner(ui, pane, r, doc) else drawFilterBanner(ui, pane, r, doc);
        return 1;
    }
    const ri = list.shown[i - list.prefix];
    return switch (doc.mode) {
        .hunk, .flat => drawUnifiedRow(ui, pane, area, y, ri, doc),
        .split => drawSplitRow(ui, pane, r, ri, doc),
    };
}

/// ` Hunk N/M  file` with the scope's chips right-aligned — Rust's
/// `active_hunk_chips_row`; the chips act on the cursor's hunk.
fn drawBanner(ui: Ui, pane: PaneId, r: Rect, doc: Doc) void {
    const p = ui.theme.palette;
    ui.fill(r, .{ .bg = p.bg_darker });
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = special_base } });
    const at = cursorHunk(doc) orelse return;
    const ord = hunkOrdinal(doc, at);
    const label = ui.fmt(" Hunk {d}/{d}  {s}", .{ ord.n, ord.of, doc.files[at.file].path() });
    const lw = ui.putStr(r.x, r.y, r.w, label, .{ .fg = p.cyan, .bg = p.bg_darker, .bold = true });
    const actions = actionsOf(doc.actions);
    var chips_w: u16 = 0;
    for (actions) |a| chips_w += ui.width(a.label()) + 1;
    if (r.w <= lw + chips_w) return;
    var x = r.right() - chips_w;
    for (actions) |a| {
        x += 1;
        const w = ui.width(a.label());
        _ = ui.putStr(x, r.y, w, a.label(), .{ .fg = p.bg_dark, .bg = a.color(p), .bold = true });
        ui.hit(Rect.init(x, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = actionId(a) } });
        x += w;
    }
}

/// ` / needle_  Backspace · Enter · Esc clears ` — Rust's `filter_status_line`.
fn drawFilterBanner(ui: Ui, pane: PaneId, r: Rect, doc: Doc) void {
    const p = ui.theme.palette;
    ui.fill(r, .{ .bg = p.bg_darker });
    const label = if (doc.filter_mode) ui.fmt(" / {s}_  ", .{doc.filter}) else ui.fmt(" filter: {s}  ", .{doc.filter});
    const hint: []const u8 = if (doc.filter_mode) " Backspace \u{00B7} Enter \u{00B7} Esc clears " else " Esc clears ";
    var x = r.x;
    x += ui.putStr(x, r.y, r.w, label, .{ .fg = p.bg_dark, .bg = p.yellow, .bold = true });
    _ = ui.putStr(x, r.y, r.right() -| x, hint, .{ .fg = p.comment, .bg = p.bg_darker });
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = filter_id } });
}

/// The row's ground: tinted for a change, `bg2` under the cursor.
fn rowGround(p: Theme.Palette, kind: parse.LineKind, on_cursor: bool) Color {
    if (on_cursor) return p.bg2;
    return switch (kind) {
        .add => addedRowBg(p),
        .del => removedRowBg(p),
        .context, .meta => p.bg_dark,
    };
}

fn drawUnifiedRow(ui: Ui, pane: PaneId, area: Rect, y0: u16, ri: u32, doc: Doc) u16 {
    const p = ui.theme.palette;
    const r = area.row(y0);
    const on_cursor = ri == doc.cursor and doc.focused;
    switch (doc.rows[ri]) {
        .blank => {
            ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = ri } });
            return 1;
        },
        .hunk => |h| {
            drawHunkHeader(ui, pane, r, ri, h, doc, on_cursor);
            return 1;
        },
        .line => |l| {
            const lines = doc.files[l.file].hunks[l.hunk].lines;
            const line = lines[l.line];
            const gw = gutterWidth(doc.files);
            const bg = if (!on_cursor and isSelected(doc, ri)) ui.theme.selection.bg else rowGround(p, line.kind, on_cursor);
            ui.fill(r, .{ .bg = bg });
            const marker: []const u8 = switch (line.kind) {
                .add, .del => if (ui.ascii) "|" else "\u{258F}",
                .context, .meta => " ",
            };
            const marker_fg = switch (line.kind) {
                .add => p.green,
                .del => p.red,
                .context, .meta => p.grey,
            };
            const sign: []const u8 = switch (line.kind) {
                .add => "+",
                .del => "-",
                .context => " ",
                .meta => "\\",
            };
            const text = if (line.kind == .meta) "No newline at end of file" else line.text;
            const fg = if (line.kind == .meta) p.comment else p.fg;
            var x = r.x;
            x += ui.putStr(x, r.y, r.right() -| x, gutterText(ui, line.old_no, line.new_no, gw), .{ .fg = p.comment, .bg = bg });
            x += ui.putStr(x, r.y, r.right() -| x, marker, .{ .fg = marker_fg, .bg = bg });
            const text_x = x + 2;
            const body_w = r.right() -| text_x;
            const ranges = rangesFor(ui, lines, l.line, doc);
            // Rust: `{sign} {prefix}` dim, the changed middle bold, the
            // suffix dim — when the line has a partner.
            const dim = ranges.len > 0;
            _ = ui.putStr(x, r.y, r.right() -| x, ui.fmt("{s} ", .{sign}), .{ .fg = if (dim) p.comment else fg, .bg = bg });
            const base: Style = .{ .fg = fg, .bg = bg };
            if (!doc.wrap or ui.width(text) <= body_w or body_w == 0) {
                paintLine(ui, text_x, r.y, body_w, text, base, ranges, doc, dim);
                ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = ri } });
                return 1;
            }
            // Wrapped: the rest continues on blank-gutter rows.
            var rows: u16 = 0;
            var rest = text;
            while (rest.len > 0 and y0 + rows < area.h) {
                const rr = area.row(y0 + rows);
                if (rows > 0) {
                    ui.fill(rr, .{ .bg = bg });
                    _ = ui.putStr(rr.x + gw, rr.y, 1, marker, .{ .fg = marker_fg, .bg = bg });
                }
                const cut = cutAt(ui, rest, body_w);
                paintLine(ui, text_x, rr.y, body_w, rest[0..cut], base, &.{}, doc, false);
                ui.hit(rr, .{ .script_hit = .{ .pane = pane, .id = ri } });
                rest = rest[cut..];
                rows += 1;
            }
            return @max(rows, 1);
        },
    }
}

/// The byte length of the longest prefix of `s` that fits `w` cells.
fn cutAt(ui: Ui, s: []const u8, w: u16) usize {
    var used: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(s);
    while (it.next()) |g| {
        const cw: u16 = @intCast(ui.canvas.cellWidth(g.bytes(s)));
        if (used + cw > w) return if (g.start == 0) g.len else g.start;
        used += cw;
    }
    return s.len;
}

/// `▶ v @@ -1,2 +1,3 @@  file +N -M` with the chips right-aligned —
/// Rust's per-hunk header in the Hunk view.
fn drawHunkHeader(ui: Ui, pane: PaneId, r: Rect, ri: u32, h: HunkRef, doc: Doc, on_cursor: bool) void {
    const p = ui.theme.palette;
    const hunk = doc.files[h.file].hunks[h.hunk];
    const bg = if (on_cursor) p.bg2 else p.bg_dark;
    ui.fill(r, .{ .bg = bg });
    var added: usize = 0;
    var removed: usize = 0;
    for (hunk.lines) |l| switch (l.kind) {
        .add => added += 1,
        .del => removed += 1,
        else => {},
    };
    var x = r.x;
    const end = r.right();
    x += ui.putStr(x, r.y, end -| x, if (on_cursor) (if (ui.ascii) "> " else "\u{25B6} ") else "  ", .{ .fg = p.yellow, .bg = bg });
    x += ui.putStr(x, r.y, end -| x, if (doc.triangle) (if (ui.ascii) "v " else "\u{25BE} ") else "v ", .{ .fg = p.purple, .bg = bg });
    x += ui.putStr(x, r.y, end -| x, ui.fmt("{s}  ", .{hunk.header}), .{ .fg = p.cyan, .bg = bg, .bold = on_cursor });
    x += ui.putStr(x, r.y, end -| x, doc.files[h.file].path(), .{ .fg = p.blue, .bg = bg });
    x += ui.putStr(x, r.y, end -| x, ui.fmt(" +{d} -{d}", .{ added, removed }), .{ .fg = p.comment, .bg = bg });
    ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = ri } });
    const actions = actionsOf(doc.actions);
    var chips_w: u16 = 0;
    for (actions) |a| chips_w += ui.width(a.label()) + 1;
    if (chips_w == 0 or r.w <= (x - r.x) + chips_w) return;
    var cx = end - chips_w;
    for (actions) |a| {
        cx += 1;
        const w = ui.width(a.label());
        _ = ui.putStr(cx, r.y, w, a.label(), .{ .fg = p.bg_dark, .bg = a.color(p), .bold = true });
        ui.hit(Rect.init(cx, r.y, w, 1), .{ .script_hit = .{ .pane = pane, .id = hunkChipId(ri, a) } });
        cx += w;
    }
}

/// Paints `text` from `x`, `base` styled; with `dim` the cells outside
/// the intraline `ranges` take the comment colour and those inside are
/// bold (Rust's paired-line treatment); the filter's matches paint
/// yellow. A tab paints as four cells; the ranges index the text as
/// given.
fn paintLine(ui: Ui, x: u16, y: u16, max_w: u16, text: []const u8, base: Style, ranges: []const intraline.Range, doc: Doc, dim: bool) void {
    const p = ui.theme.palette;
    var used: u16 = 0;
    var it = vaxis.unicode.graphemeIterator(text);
    while (it.next()) |g| {
        const bytes = g.bytes(text);
        var style = base;
        if (dim) {
            if (intraline.contains(ranges, g.start)) style.bold = true else style.fg = p.comment;
        }
        if (doc.filter.len > 0 and inFilterMatch(text, g.start, doc.filter)) {
            style.fg = p.yellow;
            style.bold = true;
        }
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
    if (a.text.len == 0 or b.text.len == 0) return &.{};
    if (a.kind == .del) {
        const r = intraline.diff(ui.arena, a.text, b.text) catch return &.{};
        return r.old;
    }
    const r = intraline.diff(ui.arena, b.text, a.text) catch return &.{};
    return r.new;
}

// ─── split ──────────────────────────────────────────────────────────────

/// Rust's `render_split`: a 5-cell gutter and a sign per side, ` │ `
/// between, each side's text padded to its column.
fn drawSplitRow(ui: Ui, pane: PaneId, r: Rect, ri: u32, doc: Doc) u16 {
    const p = ui.theme.palette;
    const on_cursor = ri == doc.cursor and doc.focused;
    switch (doc.split_rows[ri]) {
        .blank => {
            ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = ri } });
        },
        .hunk => |h| {
            const hunk = doc.files[h.file].hunks[h.hunk];
            const bg = if (on_cursor) p.bg2 else p.bg_darker;
            ui.fill(r, .{ .bg = bg });
            const text = ui.fmt("{s}{s}  {s}", .{ if (on_cursor) (if (ui.ascii) "> " else "\u{25B6} ") else "  ", hunk.header, doc.files[h.file].path() });
            _ = ui.putStr(r.x, r.y, r.w, text, .{ .fg = p.cyan, .bg = bg, .bold = on_cursor });
            ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = ri } });
        },
        .pair => |pr| {
            const lines = doc.files[pr.file].hunks[pr.hunk].lines;
            const gutter_w: u16 = 5;
            const col_w: u16 = (r.w -| 13) / 2;
            var x = r.x;
            const selected = !on_cursor and isSelected(doc, ri);
            x = drawSide(ui, r, x, lines, pr.left, gutter_w, col_w, true, doc, on_cursor, selected);
            x += ui.putStr(x, r.y, r.right() -| x, if (ui.ascii) " | " else " \u{2502} ", .{ .fg = p.grey, .bg = p.bg_dark });
            _ = drawSide(ui, r, x, lines, pr.right, gutter_w, col_w, false, doc, on_cursor, selected);
            ui.hit(r, .{ .script_hit = .{ .pane = pane, .id = ri } });
        },
    }
    return 1;
}

/// One side of a pair from `x0`; returns where it ended.
fn drawSide(ui: Ui, r: Rect, x0: u16, lines: []const parse.DiffLine, idx: ?u32, gutter_w: u16, col_w: u16, left: bool, doc: Doc, on_cursor: bool, selected: bool) u16 {
    const p = ui.theme.palette;
    const end = r.right();
    var x = x0;
    const side_w = gutter_w + 1 + col_w;
    const sel_bg = ui.theme.selection.bg;
    const li = idx orelse {
        // A filler half: the `bg2` ground, a `·` for a sign.
        const bg = if (selected) sel_bg else p.bg2;
        ui.fill(Rect.init(x, r.y, @min(side_w, end -| x), 1), .{ .bg = bg });
        x += gutter_w;
        _ = ui.putStr(x, r.y, end -| x, "\u{00B7}", .{ .fg = p.comment, .bg = bg, .bold = true });
        return x0 + side_w;
    };
    const line = lines[li];
    const bg = if (selected) sel_bg else rowGround(p, line.kind, on_cursor);
    ui.fill(Rect.init(x, r.y, @min(side_w, end -| x), 1), .{ .bg = bg });
    const no = if (left) line.old_no else line.new_no;
    if (no) |n| _ = ui.putStrRight(x + gutter_w - 1, r.y, gutter_w - 1, ui.fmt("{d}", .{n}), .{ .fg = p.comment, .bg = bg });
    x += gutter_w;
    const sign: []const u8 = switch (line.kind) {
        .add => "+",
        .del => "-",
        .context, .meta => " ",
    };
    const sign_fg = switch (line.kind) {
        .add => p.green,
        .del => p.red,
        .context, .meta => p.fg,
    };
    x += ui.putStr(x, r.y, end -| x, sign, .{ .fg = sign_fg, .bg = bg, .bold = true });
    x += 1;
    const ranges = rangesFor(ui, lines, li, doc);
    const fg = if (line.kind == .meta) p.comment else p.fg;
    paintLine(ui, x, r.y, @min(col_w -| 1, end -| x), line.text, .{ .fg = fg, .bg = bg }, ranges, doc, ranges.len > 0);
    return x0 + side_w;
}

// ─── the right edge ─────────────────────────────────────────────────────

/// The change strip: `▎` per band in the band's colour, blank elsewhere;
/// a click jumps to the band's first row.
fn drawStrip(ui: Ui, pane: PaneId, s: Rect, list: List, doc: Doc) void {
    const p = ui.theme.palette;
    const total = list.len();
    const kinds = ui.arena.alloc(Kind, total) catch return;
    for (0..total) |i| kinds[i] = list.kind(doc, i);
    const bands = density(ui.arena, kinds, s.h) catch return;
    for (bands, 0..) |k, cy| {
        const y: u16 = s.y + @as(u16, @intCast(cy));
        const fg: ?Color = switch (k) {
            .none => null,
            .add => p.green,
            .del => p.red,
            .both => p.yellow,
        };
        if (fg) |c| {
            _ = ui.putStr(s.x, y, 1, if (ui.ascii) "|" else "\u{258E}", .{ .fg = c, .bg = p.bg_dark });
        } else ui.fill(Rect.init(s.x, y, 1, 1), .{ .bg = p.bg_dark });
        ui.hit(Rect.init(s.x, y, 1, 1), .{ .script_hit = .{ .pane = pane, .id = stripId(@intCast(cy)) } });
    }
}

/// `bg2` track, `comment` thumb while the list overflows the body.
fn drawScrollbar(ui: Ui, pane: PaneId, b: Rect, total: usize, scroll: usize, visible: u16) void {
    const p = ui.theme.palette;
    ui.fill(b, .{ .bg = p.bg2 });
    const cells: usize = b.h;
    if (total > visible and visible > 0) {
        const thumb_h = @max(cells * visible / total, 1);
        const max_scroll = total - visible;
        const max_top = cells -| thumb_h;
        const top = if (max_scroll == 0) 0 else scroll * max_top / max_scroll;
        var cy = top;
        while (cy < @min(top + thumb_h, cells)) : (cy += 1) ui.fill(Rect.init(b.x, b.y + @as(u16, @intCast(cy)), 1, 1), .{ .bg = p.comment });
    }
    for (0..cells) |cy| ui.hit(Rect.init(b.x, b.y + @as(u16, @intCast(cy)), 1, 1), .{ .script_hit = .{ .pane = pane, .id = stripId(@intCast(cy)) } });
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

/// The spec's diff: `src/main.rs` with a line appended, as `git diff`
/// with the whole file for context reports it.
const spec_diff =
    "diff --git a/src/main.rs b/src/main.rs\n" ++
    "--- a/src/main.rs\n" ++
    "+++ b/src/main.rs\n" ++
    "@@ -1,2 +1,3 @@\n" ++
    " fn main() {}\n" ++
    " y\n" ++
    "+z\n";

fn identity(arena: Allocator, n: usize) ![]u32 {
    const out = try arena.alloc(u32, n);
    for (out, 0..) |*o, i| o.* = @intCast(i);
    return out;
}

fn glyph(a: git_toolbar.Action) []const u8 {
    return git_toolbar.glyphOf(a);
}

/// `s` padded with spaces to `cells` columns (every glyph here is one
/// cell), then `tail`.
fn padTo(arena: Allocator, s: []const u8, cells: usize, tail: []const u8) ![]const u8 {
    const w = try std.unicode.utf8CountCodepoints(s);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, s);
    try out.appendNTimes(arena, ' ', cells -| w);
    try out.appendSlice(arena, tail);
    return out.items;
}

test "the spec's diff pane, cell for cell: toolbar rows, the banner with its chips, the Inline rows; every control is a hit" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const files = try parse.parseDiff(arena, spec_diff);
    const rows = try flatten(arena, files);
    const shown = try filterRows(arena, files, rows, "", true);
    // `docs/ui-spec/rust-diff-120x40.txt` columns 31..120, rows 2..38.
    var f = try Fixture.init(89, 37);
    defer f.deinit();
    var st: State = .{};
    const painted = draw(f.ui(), 2, f.full(), &st, .{ .files = files, .rows = rows, .shown = shown, .cursor = 1, .focused = true });
    try f.expectRow(0, try std.fmt.allocPrint(arena, " {s} Undo   {s} Redo   {s} Pull   {s} Push   {s} Fetch   {s} Branch   {s} Commit   {s} Stash   {s} Reflog", .{
        glyph(.undo), glyph(.redo), glyph(.pull), glyph(.push), glyph(.fetch), glyph(.branch), glyph(.commit), glyph(.stash), glyph(.reflog),
    }));
    try f.expectRow(1, try padTo(arena, "  Hunk   Inline   Split  \u{2502}  Wrap", 86, "\u{00D7}"));
    try f.expectRow(2, try padTo(arena, " Hunk 1/1  src/main.rs", 70, "Stage   Discard"));
    try f.expectRow(3, "  1   1    fn main() {}");
    try f.expectRow(4, "  2   2    y");
    try f.expectRow(5, "      3 \u{258F}+ z");
    try f.expectRow(6, "");
    try testing.expectEqual(@as(u16, 2), painted.body.y);
    try testing.expectEqual(@as(u16, 35), painted.strip_cells);
    // The change strip: the added row is the last of four, so its
    // band is the bottom fifth — rows 29..36 of the pane at column 87.
    try f.expectRow(31, try std.fmt.allocPrint(arena, "{s:<87}\u{258E}", .{""}));
    try f.expectRow(28, "");
    // Hits: the toolbar chips, the close, the chips, the strip, the rows.
    try testing.expectEqual(git_toolbar.hitId(.undo), f.hits.at(3, 0).?.script_hit.id);
    try testing.expectEqual(chipId(.hunk), f.hits.at(2, 1).?.script_hit.id);
    try testing.expectEqual(chipId(.flat), f.hits.at(9, 1).?.script_hit.id);
    try testing.expectEqual(chipId(.split), f.hits.at(18, 1).?.script_hit.id);
    try testing.expectEqual(wrap_id, f.hits.at(28, 1).?.script_hit.id);
    try testing.expectEqual(close_id, f.hits.at(86, 1).?.script_hit.id);
    try testing.expectEqual(actionId(.stage), f.hits.at(72, 2).?.script_hit.id);
    try testing.expectEqual(actionId(.discard), f.hits.at(80, 2).?.script_hit.id);
    try testing.expectEqual(@as(u32, 1), f.hits.at(5, 3).?.script_hit.id);
    try testing.expectEqual(@as(u32, 3), f.hits.at(5, 5).?.script_hit.id);
    try testing.expect(stripCellOf(f.hits.at(87, 10).?.script_hit.id) != null);
    try testing.expect(stripCellOf(f.hits.at(88, 10).?.script_hit.id) != null);
    try testing.expectEqual(@as(?Action, .stage), actionOf(actionId(.stage)));
    try testing.expectEqual(@as(?Action, null), actionOf(chipId(.hunk)));
    // Colours: the active view chip on green, the close on red, the
    // added row on its tint with the marker green.
    try testing.expect(f.bgEql(9, 1, .{ .bg = f.theme.palette.green }));
    try testing.expect(f.bgEql(2, 1, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(86, 1, .{ .bg = f.theme.palette.red }));
    try testing.expect(f.bgEql(12, 5, .{ .bg = addedRowBg(f.theme.palette) }));
    try testing.expect(f.fgEql(8, 5, .{ .fg = f.theme.palette.green }));
    try testing.expect(f.fgEql(11, 5, .{ .fg = f.theme.palette.fg }));
}

test "flatten lists hunk, lines and spacer; the Hunk view paints the header with its chips; Wrap continues a long line" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const files = try parse.parseDiff(arena, sample);
    const rows = try flatten(arena, files);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expect(rows[0] == .hunk);
    try testing.expect(rows[1] == .line);
    try testing.expect(rows[3] == .blank);
    // Seven rows: under eight there is no git toolbar.
    var f = try Fixture.init(60, 7);
    defer f.deinit();
    var st: State = .{};
    _ = draw(f.ui(), 2, f.full(), &st, .{ .files = files, .rows = rows, .shown = try identity(arena, rows.len), .mode = .hunk, .cursor = 0, .focused = true });
    // The Hunk view has no pad column: the strip at 58, the bar at 59.
    try f.expectRow(0, try padTo(arena, "  Hunk   Inline   Split  \u{2502}  Wrap", 57, "\u{00D7}"));
    try f.expectRow(1, try padTo(arena, " Hunk 1/1  code.rs", 42, "Stage   Discard"));
    try f.expectRow(2, try padTo(arena, "\u{25B6} v @@ -1 +1 @@  code.rs +1 -1", 42, "Stage   Discard"));
    try f.expectRow(3, "  1     \u{258F}- fn alpha() {}");
    // The strip's band for the removed row lands on row 4.
    try f.expectRow(4, try padTo(arena, "      1 \u{258F}+ fn beta() {}", 58, "\u{258E}"));
    try testing.expectEqual(hunkChipId(0, .discard), f.hits.at(50, 2).?.script_hit.id);
    try testing.expectEqual(@as(?HunkChip, .{ .row = 0, .action = .discard }), hunkChipOf(hunkChipId(0, .discard)));
    try testing.expectEqual(@as(?HunkChip, null), hunkChipOf(actionId(.stage)));
    try testing.expect(stripCellOf(f.hits.at(58, 3).?.script_hit.id) != null);
    // A paired line: the changed word in the body colour, bold; the
    // rest dimmed.
    // `fn alpha() {}` from col 11: `alph` (14..17) is the change.
    try testing.expect(f.style(14, 3).bold);
    try testing.expect(!f.style(11, 3).bold);
    try testing.expect(f.fgEql(11, 3, .{ .fg = f.theme.palette.comment }));
    // Wrap: a 70-cell line at 40 columns continues on a second row.
    const long = "diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1 +1 @@\n-" ++ "a" ** 30 ++ "\n+" ++ "b" ** 30 ++ "\n";
    const lf = try parse.parseDiff(arena, long);
    const lrows = try flatten(arena, lf);
    var g = try Fixture.init(30, 8);
    defer g.deinit();
    var gst: State = .{};
    _ = draw(g.ui(), 2, g.full(), &gst, .{ .files = lf, .rows = lrows, .shown = try filterRows(arena, lf, lrows, "", true), .cursor = 1, .focused = false, .wrap = true, .intraline = false });
    // Both lines wrap: the `-` on rows 2 / 3, the `+` on 4 / 5; the
    // strip's removed band covers 4 / 5.
    try g.expectRow(2, "  1     \u{258F}- aaaaaaaaaaaaaaaa");
    try g.expectRow(3, "        \u{258F}  aaaaaaaaaaaaaa");
    try g.expectRow(4, try padTo(arena, "      1 \u{258F}+ bbbbbbbbbbbbbbbb", 28, "\u{258E}"));
    try g.expectRow(5, try padTo(arena, "        \u{258F}  bbbbbbbbbbbbbb", 28, "\u{258E}"));
    try testing.expectEqual(@as(u32, 2), g.hits.at(10, 5).?.script_hit.id);
    try testing.expectEqual(@as(u32, 1), g.hits.at(10, 3).?.script_hit.id);
}

/// The first file git called binary, or null.
fn binaryFile(files: []const parse.FileDiff) ?parse.FileDiff {
    for (files) |f| if (f.binary) return f;
    return null;
}

test "no hunks on a binary file: `Binary file changed (old → new bytes)`, the sizes off --stat; without them the line alone; `->` in ascii" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var f = try Fixture.init(50, 10);
    defer f.deinit();
    var st: State = .{};
    const files = try parse.parseDiff(arena,
        \\diff --git a/logo.png b/logo.png
        \\index e5d1ed1..99a4e9c 100644
        \\Binary files a/logo.png and b/logo.png differ
        \\
    );
    _ = draw(f.ui(), 1, f.full(), &st, .{ .files = files, .rows = &.{}, .shown = &.{}, .cursor = 0, .focused = true });
    try f.expectRow(2, "  Binary file changed");
    files[0].bin_sizes = .{ 33, 40 };
    _ = draw(f.ui(), 1, f.full(), &st, .{ .files = files, .rows = &.{}, .shown = &.{}, .cursor = 0, .focused = true });
    try f.expectRow(2, "  Binary file changed (33 \u{2192} 40 bytes)");
    f.ascii = true;
    _ = draw(f.ui(), 1, f.full(), &st, .{ .files = files, .rows = &.{}, .shown = &.{}, .cursor = 0, .focused = true });
    try f.expectRow(2, "  Binary file changed (33 -> 40 bytes)");
}

test "no hunks: `(no changes)`, or `loading…` while pending; a staged scope offers Unstage; a commit none" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var f = try Fixture.init(50, 10);
    defer f.deinit();
    var st: State = .{};
    _ = draw(f.ui(), 1, f.full(), &st, .{ .files = &.{}, .rows = &.{}, .shown = &.{}, .cursor = 0, .focused = true });
    try f.expectRow(2, "  (no changes)");
    _ = draw(f.ui(), 1, f.full(), &st, .{ .files = &.{}, .rows = &.{}, .shown = &.{}, .cursor = 0, .focused = true, .pending = true });
    try f.expectRow(2, "  loading\u{2026}");
    const files = try parse.parseDiff(arena, sample);
    const rows = try flatten(arena, files);
    const shown = try filterRows(arena, files, rows, "", true);
    _ = draw(f.ui(), 1, f.full(), &st, .{ .files = files, .rows = rows, .shown = shown, .cursor = 1, .focused = true, .actions = .staged });
    try f.expectRow(2, try padTo(arena, " Hunk 1/1  code.rs", 39, "Unstage"));
    try testing.expectEqual(actionId(.unstage), f.hits.at(44, 2).?.script_hit.id);
    _ = draw(f.ui(), 1, f.full(), &st, .{ .files = files, .rows = rows, .shown = shown, .cursor = 1, .focused = true, .actions = .none });
    try f.expectRow(2, try padTo(arena, "  1     \u{258F}- fn alpha() {}", 48, "\u{258E}"));
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

test "pairs: a header per hunk, context on both sides, removed runs zipped with added runs, the tail against a filler" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const files = try parse.parseDiff(a.allocator(), two_hunks);
    const sr = try pairs(a.allocator(), files);
    // hunk, keep, apple/apricot, keep2, blank, hunk, ctx, old one/new one, old two/new two, -/new three, ctx2, blank
    try testing.expectEqual(@as(usize, 12), sr.len);
    try testing.expect(sr[0] == .hunk);
    try testing.expectEqual(@as(?u32, 0), sr[1].pair.left);
    try testing.expectEqual(@as(?u32, 0), sr[1].pair.right);
    try testing.expectEqual(@as(?u32, 1), sr[2].pair.left);
    try testing.expectEqual(@as(?u32, 2), sr[2].pair.right);
    try testing.expect(sr[4] == .blank);
    try testing.expect(sr[5] == .hunk);
    try testing.expectEqual(@as(?u32, 1), sr[7].pair.left);
    try testing.expectEqual(@as(?u32, 3), sr[7].pair.right);
    try testing.expectEqual(@as(?u32, null), sr[9].pair.left);
    try testing.expectEqual(@as(?u32, 5), sr[9].pair.right);
    try testing.expectEqual(Kind.both, splitRowKind(files, sr[2]));
    try testing.expectEqual(Kind.add, splitRowKind(files, sr[9]));
    try testing.expectEqual(Kind.none, splitRowKind(files, sr[1]));
}

test "split draw: a header across both columns, old left, new right, a filler with a dot" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const files = try parse.parseDiff(arena, two_hunks);
    const rows = try flatten(arena, files);
    const sr = try pairs(arena, files);
    var f = try Fixture.init(60, 14);
    defer f.deinit();
    var st: State = .{};
    var ui = f.ui();
    ui.ascii = true;
    const p = draw(ui, 4, f.full(), &st, .{ .files = files, .rows = rows, .shown = try identity(arena, rows.len), .split_rows = sr, .split_shown = try identity(arena, sr.len), .mode = .split, .cursor = 2, .focused = true });
    // Both toolbars, then the banner: the rows start at 3.
    try testing.expectEqual(@as(u16, 2), p.body.y);
    // Body 57 wide (three reserved): col_w = (57 - 13) / 2 = 22, so a
    // side is 28 cells and the ` | ` sits at 28.
    try f.expectRow(3, "  @@ -1,3 +1,3 @@  a.txt");
    // Rows with a change end in the strip's ASCII `|` at 58.
    try f.expectRow(4, try padTo(arena, "   1   keep", 28, " |    1   keep"));
    try f.expectRow(5, try padTo(arena, try padTo(arena, "   2 - apple", 28, " |    2 + apricot"), 58, "|"));
    try f.expectRow(12, try padTo(arena, try padTo(arena, "     \u{00B7}", 28, " |   13 + new three"), 58, "|"));
    try testing.expectEqual(@as(u32, 9), f.hits.at(3, 12).?.script_hit.id);
    try testing.expect(f.bgEql(3, 12, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(3, 5, .{ .bg = f.theme.palette.bg2 }));
}

test "a selection paints its rows on the selection ground, inside the anchor's hunk only, in the unified and split views" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const files = try parse.parseDiff(arena, two_hunks);
    const rows = try flatten(arena, files);
    const shown = try identity(arena, rows.len);
    // rows: 0 hunk, 1 keep, 2 -apple, 3 +apricot, 4 keep2, 5 blank, 6 hunk, 7 ctx, …
    const doc: Doc = .{ .files = files, .rows = rows, .shown = shown, .mode = .hunk, .cursor = 7, .anchor = 2, .focused = true };
    const sel = selectionOf(doc).?;
    try testing.expectEqual(@as(usize, 2), sel.lo);
    try testing.expectEqual(@as(usize, 7), sel.hi);
    try testing.expectEqual(@as(u32, 0), sel.hunk.hunk);
    try testing.expect(isSelected(doc, 2));
    try testing.expect(isSelected(doc, 4));
    try testing.expect(!isSelected(doc, 1));
    try testing.expect(!isSelected(doc, 5));
    try testing.expect(!isSelected(doc, 6));
    // Row 7 is the cursor but another hunk's: not selected.
    try testing.expect(!isSelected(doc, 7));
    var f = try Fixture.init(60, 14);
    defer f.deinit();
    var st: State = .{};
    _ = draw(f.ui(), 1, f.full(), &st, doc);
    // Body from row 2: banner at 2, hunk header 3, keep 4, -apple 5, +apricot 6, keep2 7.
    const sel_bg = f.theme.selection.bg;
    try testing.expect(f.bgEql(12, 5, .{ .bg = sel_bg }));
    try testing.expect(f.bgEql(12, 6, .{ .bg = sel_bg }));
    try testing.expect(f.bgEql(12, 7, .{ .bg = sel_bg }));
    try testing.expect(!f.bgEql(12, 4, .{ .bg = sel_bg }));
    // No anchor: nothing selected, the added row keeps its tint.
    var plain = doc;
    plain.anchor = null;
    try testing.expect(selectionOf(plain) == null);
    _ = draw(f.ui(), 1, f.full(), &st, plain);
    try testing.expect(f.bgEql(12, 6, .{ .bg = addedRowBg(f.theme.palette) }));
    // Split: pairs 2..3 of hunk 1 (apple/apricot, keep2).
    const sr = try pairs(arena, files);
    const sdoc: Doc = .{ .files = files, .rows = rows, .shown = shown, .split_rows = sr, .split_shown = try identity(arena, sr.len), .mode = .split, .cursor = 3, .anchor = 2, .focused = true };
    try testing.expect(isSelected(sdoc, 2));
    try testing.expect(!isSelected(sdoc, 0));
    _ = draw(f.ui(), 1, f.full(), &st, sdoc);
    // Row 3 body = split row 0 (header), row 5 = pair 2 (apple/apricot): both sides on the selection ground.
    try testing.expect(f.bgEql(3, 5, .{ .bg = sel_bg }));
    try testing.expect(f.bgEql(40, 5, .{ .bg = sel_bg }));
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

test "filter: only the hunks holding the needle stay; the inline view drops hunk rows and spacers; the banner paints" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const files = try parse.parseDiff(arena, two_hunks);
    const rows = try flatten(arena, files);
    try testing.expectEqual(rows.len, (try filterRows(arena, files, rows, "", false)).len);
    const shown = try filterRows(arena, files, rows, "APRIC", false);
    // hunk 1 header and its four lines; the spacers go with a needle.
    try testing.expectEqual(@as(usize, 5), shown.len);
    try testing.expect(rows[shown[0]] == .hunk);
    try testing.expectEqual(@as(u32, 0), rows[shown[0]].hunk.hunk);
    const none = try filterRows(arena, files, rows, "zzz", false);
    try testing.expectEqual(@as(usize, 0), none.len);
    const inline_rows = try filterRows(arena, files, rows, "", true);
    for (inline_rows) |i| try testing.expect(rows[i] == .line);
    const sr = try pairs(arena, files);
    const split_shown = try filterSplitRows(arena, files, sr, "three");
    // The second hunk's header and five pairs.
    try testing.expectEqual(@as(usize, 6), split_shown.len);
    var f = try Fixture.init(60, 7);
    defer f.deinit();
    var st: State = .{};
    _ = draw(f.ui(), 1, f.full(), &st, .{ .files = files, .rows = rows, .shown = shown, .cursor = 0, .focused = true, .filter = "apric", .filter_mode = true, .actions = .none });
    try f.expectRow(1, " / apric_   Backspace \u{00B7} Enter \u{00B7} Esc clears");
    try testing.expectEqual(filter_id, f.hits.at(3, 1).?.script_hit.id);
    // `apricot` on row 5: the match paints yellow, the tail does not.
    try f.expectRow(5, try padTo(arena, "      2 \u{258F}+ apricot", 58, "\u{258E}"));
    try testing.expect(f.fgEql(11, 5, .{ .fg = f.theme.palette.yellow }));
    try testing.expect(!f.fgEql(17, 5, .{ .fg = f.theme.palette.yellow }));
}
