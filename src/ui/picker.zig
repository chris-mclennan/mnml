//! Picker — the fuzzy list overlay behind the buffer list, the file
//! finder and the command palette, painted as the Rust editor paints
//! its: a square box `clamp(W-8, 30, 90)` wide, as tall as its items up
//! to 22 rows (never more than four fifths of the screen), the title
//! an accent chip on the top edge, the query on the first inner row
//! with the count (` N ` / ` N of M `) flush right, then the ranked
//! rows: a `▌` on the selected one, the label with the matched
//! characters in the accent, and the detail (a chord, a directory)
//! right-aligned with a cell of air on each side. A list longer than
//! the box gets a scrollbar column. `ui.picker_position` drops the box
//! to the top edge or centres it.
//!
//! The app ranks (`rank` on `fuzzy.score`, Rust's `refilter`: priority
//! desc, score desc, index asc) and hands the filtered slice to `draw`;
//! `accept` is an index into THAT slice, so the app maps it back
//! through the order `rank` returned.
//!
//! Every visible row registers `.overlay_item(i)`; the scrollbar, when
//! the list outgrows the box, registers under `scrollbar_owner`. The
//! box never exceeds the screen — the Rust picker panicked below 30
//! columns because a comment said the clamp would "clip, fine".

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const overlay = @import("overlay.zig");
const text_field = @import("text_field.zig");
const scrollbar = @import("scrollbar.zig");
const fuzzy = @import("fuzzy.zig");
const list_panel = @import("list_panel.zig");
const script_view = @import("script_view.zig");
const key_mod = @import("../core/key.zig");
const ids = @import("../core/ids.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const Key = key_mod.Key;
pub const Caret = text_field.Caret;

pub const Item = struct {
    label: []const u8,
    /// Right-aligned, muted: a chord, a path, a time.
    detail: ?[]const u8 = null,
    /// After the label, muted: a note the row carries (Zig's pickers
    /// that say more than Rust's).
    hint: ?[]const u8 = null,
    /// Before the label: a glyph the row carries (a script's row `icon`).
    icon: ?[]const u8 = null,
    /// Tab-marked in a multi-select picker: the marker cell is a check.
    marked: bool = false,
};

/// One row of the preview column, in the script pane's segment shape —
/// already resolved against the theme by whoever filled it, so the
/// paint loop never enters Lua.
pub const PreviewRow = []const script_view.Segment;
pub const PreviewSegment = script_view.Segment;

/// The `.overlay_item` id of the query field — past every row index.
pub const query_item: u32 = std.math.maxInt(u32);

pub const State = struct {
    title: []const u8,
    query: text_field.Buf = .empty,
    caret: usize = 0,
    /// The query's selection (`text_field.clickSelect`), from here to the caret.
    sel_anchor: ?usize = null,
    cursor: usize = 0,
    scroll: usize = 0,
    /// The unfiltered count, for ` N of M `; null paints ` N `.
    total: ?usize = null,
    /// Rows the list had last frame — paging reads it.
    rows: usize = 0,
    /// `ui.picker_position`: `.top` or `.center`.
    anchor: overlay.Anchor = .center,
    /// A location list under the vim profile: while the filter is
    /// empty, `j` / `k` move the cursor (the rows are places, not names
    /// a `j` would start) and `g` / `G` jump; any other char filters.
    list_keys_when_empty: bool = false,
    /// // changed (lua-plumbing): the picker has a preview column —
    /// results left, the cursor row's preview right. The flag decides
    /// the geometry, so an empty preview still keeps the column rather
    /// than resizing the box under the reader.
    has_preview: bool = false,
    /// The cursor row's preview, filled by the app when the cursor moves.
    preview: []const PreviewRow = &.{},
    /// The row of `preview` the column must show — a grep hit's line.
    /// The column centres on it against its REAL height, so the app
    /// never rebuilds the rows just to re-centre them.
    preview_focus: ?usize = null,
    /// Rows the reader scrolled the preview by (`ctrl+u` / `ctrl+d`,
    /// PageUp / PageDown), on top of that centring.
    preview_scroll: usize = 0,
    /// The preview column's height last frame — the scroll keys' page.
    preview_h: u16 = 0,
    /// Tab marks a row and Enter passes every marked one.
    multi: bool = false,
    /// The screen row the box's top border landed on when it opened.
    /// The height comes from the filtered count, so re-placing the box
    /// every frame slid it DOWN the screen as the list shrank under the
    /// query — the reader's eye chased a moving box while typing. The
    /// top is decided once, on the first frame, and the list is the only
    /// thing that shrinks (VS Code's palette does the same).
    /// `null` again whenever the picker re-opens (`deinit` resets it).
    top: ?u16 = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.query.deinit(gpa);
        s.* = .{ .title = s.title };
    }

    pub fn queryText(s: *const State) []const u8 {
        return s.query.items;
    }
};

/// `ignored`: not a picker key and not a field key — a modified chord
/// the app may still resolve (Ctrl+S saves from the palette).
pub const Outcome = union(enum) {
    consumed,
    ignored,
    cancel,
    changed,
    accept: usize,
    /// Tab on a row of a multi-select picker.
    toggle: usize,
};

/// The `.scrollbar` owner the picker's bar registers under.
pub const scrollbar_owner: ids.PaneId = std.math.maxInt(ids.PaneId);

pub const min_width: u16 = 30;
pub const max_width: u16 = 90;
/// With a preview column the box may take more of the screen — the two
/// halves each need the room one list needed.
pub const max_width_preview: u16 = 120;
/// The preview column's share of the inner width, and the least it is
/// worth painting. Below that the box is all results: the picker must
/// never squeeze itself into a column it cannot read.
pub const preview_share_num: u16 = 2;
pub const preview_share_den: u16 = 5;
pub const min_preview: u16 = 20;
pub const min_height: u16 = 7;
pub const compact_height: u16 = 22;
pub const no_matches = "  (no matches)";
/// The label keeps at least this many cells; the detail gives way.
pub const min_label: u16 = 12;

/// ↑↓ / ctrl+p ctrl+n / ctrl+j ctrl+k move, page keys page, enter
/// accepts the cursor, esc cancels, typing changes the query (and
/// rewinds the cursor). `count` is the length of the slice last drawn.
///
/// With a preview column the four paging keys belong to the PREVIEW, as
/// the reference plugin binds them: `ctrl+u` / `ctrl+d` scroll it half a
/// screen, PageUp / PageDown a whole one. Without one they page the
/// list, as they always did.
pub fn handleKey(s: *State, gpa: Allocator, key: Key, count: usize) Allocator.Error!Outcome {
    const last = count -| 1;
    if (s.cursor > last) s.cursor = last;
    const page = @max(1, s.rows);
    switch (key.code) {
        .esc => return .cancel,
        .enter => return if (count > 0) .{ .accept = s.cursor } else .consumed,
        .tab => if (s.multi) return if (count > 0) .{ .toggle = s.cursor } else .consumed,
        .up => s.cursor -|= 1,
        .down => s.cursor = @min(s.cursor + 1, last),
        .page_up => if (s.has_preview) scrollPreview(s, -@as(isize, previewPage(s))) else {
            s.cursor -|= page;
        },
        .page_down => if (s.has_preview) scrollPreview(s, previewPage(s)) else {
            s.cursor = @min(s.cursor + page, last);
        },
        .char => |c| if (key.mods.ctrl and !key.mods.alt) switch (c) {
            'p', 'k' => s.cursor -|= 1,
            'n', 'j' => s.cursor = @min(s.cursor + 1, last),
            'u' => if (s.has_preview) scrollPreview(s, -halfPage(s)) else {
                s.cursor -|= page;
            },
            'd' => if (s.has_preview) scrollPreview(s, halfPage(s)) else {
                s.cursor = @min(s.cursor + page, last);
            },
            else => return editKey(s, gpa, key),
        } else if (s.list_keys_when_empty and s.query.items.len == 0 and !key.mods.alt and !key.mods.super) switch (c) {
            'j' => s.cursor = @min(s.cursor + 1, last),
            'k' => s.cursor -|= 1,
            'g' => s.cursor = 0,
            'G' => s.cursor = last,
            else => return editKey(s, gpa, key),
        } else return editKey(s, gpa, key),
        else => return editKey(s, gpa, key),
    }
    return .consumed;
}

/// The preview's page: the column's height last frame, or a sane guess
/// before the first paint.
fn previewPage(s: *const State) isize {
    return @max(1, @as(isize, s.preview_h));
}

/// Half of it, for `ctrl+u` / `ctrl+d`.
fn halfPage(s: *const State) isize {
    return @max(1, @divTrunc(previewPage(s), 2));
}

/// Scroll the preview column, never past its last row.
fn scrollPreview(s: *State, delta: isize) void {
    const last = s.preview.len -| 1;
    if (delta < 0) {
        s.preview_scroll -|= @intCast(-delta);
    } else {
        s.preview_scroll = @min(s.preview_scroll + @as(usize, @intCast(delta)), last);
    }
}

/// The wheel: `delta` rows (negative up), clamped to the list.
pub fn wheel(s: *State, delta: isize, count: usize) void {
    const last = count -| 1;
    if (delta < 0) {
        s.cursor -|= @intCast(-delta);
    } else {
        s.cursor = @min(s.cursor + @as(usize, @intCast(delta)), last);
    }
}

fn editKey(s: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
    switch (try text_field.editKey(&s.query, &s.caret, &s.sel_anchor, gpa, key)) {
        .changed => {
            s.cursor = 0;
            s.scroll = 0;
            return .changed;
        },
        .moved => return .consumed,
        .ignored => return .ignored,
    }
}

pub fn paste(s: *State, gpa: Allocator, text: []const u8) Allocator.Error!void {
    try text_field.insertSel(&s.query, &s.caret, &s.sel_anchor, gpa, text);
    s.cursor = 0;
    s.scroll = 0;
}

/// What the app knows about a row beyond its label — Rust's
/// `PickerItem.priority` (a hard tier that always beats the score) and
/// `score_bonus` (added to the score); `id` lets the palette pin an
/// exact id and boost a substring hit.
pub const RankOpts = struct {
    priority: []const u8 = &.{},
    score_bonus: []const i64 = &.{},
    /// The command ids, for the palette's boosts; empty otherwise.
    ids: []const []const u8 = &.{},
    /// Parallel to `items` (or empty): the tie-break before index —
    /// the palette's recents keep their newest-first order on an empty
    /// query, where every score is the same (`maxInt` for the rest).
    order: []const u32 = &.{},
    /// A path list: a query with spaces is also tried as separate terms,
    /// every one matching in any order (fzf's, VS Code's quick open) —
    /// `src main` finds `src/main.rs`. The whole query is tried first,
    /// so a name with a real space still ranks on it.
    terms: bool = false,
};

/// `query`'s score on `label`, or its space-separated terms' summed
/// scores when every term matches (see `RankOpts.terms`).
fn termScore(query: []const u8, label: []const u8, terms: bool) ?i64 {
    if (fuzzy.raw(query, label)) |r| return r;
    if (!terms or std.mem.indexOfScalar(u8, query, ' ') == null) return null;
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    var sum: i64 = 0;
    var n: usize = 0;
    while (it.next()) |term| {
        sum += fuzzy.raw(term, label) orelse return null;
        n += 1;
    }
    return if (n == 0) null else sum;
}

/// Indices into `items` that match `query`, best first: priority desc,
/// score desc, index asc — Rust's `refilter`. An empty query keeps
/// every item, ordered by priority and bonus alone.
pub fn rank(arena: Allocator, query: []const u8, items: []const Item, opts: RankOpts) Allocator.Error![]const usize {
    const Scored = struct { prio: u8, score: i64, order: u32, idx: usize };
    var scored: std.ArrayListUnmanaged(Scored) = .empty;
    var qlower_buf: [256]u8 = undefined;
    const q = std.ascii.lowerString(qlower_buf[0..@min(query.len, qlower_buf.len)], query[0..@min(query.len, qlower_buf.len)]);
    const id_boosts = opts.ids.len > 0 and q.len > 0;
    for (items, 0..) |it, i| {
        const raw = termScore(query, it.label, opts.terms) orelse continue;
        var prio: u8 = if (i < opts.priority.len) opts.priority[i] else 0;
        var sc: i64 = raw + (if (i < opts.score_bonus.len) opts.score_bonus[i] else 0);
        if (id_boosts and i < opts.ids.len) {
            var idbuf: [256]u8 = undefined;
            const id = opts.ids[i];
            const idl = std.ascii.lowerString(idbuf[0..@min(id.len, idbuf.len)], id[0..@min(id.len, idbuf.len)]);
            if (std.mem.eql(u8, idl, q)) {
                prio = @max(prio, 9);
            } else if (std.mem.indexOf(u8, idl, q) != null) {
                sc += 100;
            }
        }
        try scored.append(arena, .{ .prio = prio, .score = sc, .order = if (i < opts.order.len) opts.order[i] else std.math.maxInt(u32), .idx = i });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn less(_: void, a: Scored, b: Scored) bool {
            if (a.prio != b.prio) return a.prio > b.prio;
            if (a.score != b.score) return a.score > b.score;
            if (a.order != b.order) return a.order < b.order;
            return a.idx < b.idx;
        }
    }.less);
    const out = try arena.alloc(usize, scored.items.len);
    for (scored.items, 0..) |e, i| out[i] = e.idx;
    return out;
}

/// `items` in `order` — what `draw` takes.
pub fn gather(arena: Allocator, items: []const Item, order: []const usize) Allocator.Error![]const Item {
    const out = try arena.alloc(Item, order.len);
    for (order, 0..) |idx, i| out[i] = items[idx];
    return out;
}

/// The box's rect on `area` for `n` items — Rust's geometry, widened
/// when a preview column shares it.
pub fn place(area: Rect, n: usize, anchor: overlay.Anchor) Rect {
    return placeWith(area, n, anchor, false);
}

pub fn placeWith(area: Rect, n: usize, anchor: overlay.Anchor, has_preview: bool) Rect {
    const widest: u16 = if (has_preview) max_width_preview else max_width;
    const w = @min(std.math.clamp(area.w -| 8, min_width, widest), area.w);
    const compact = std.math.clamp(@as(u16, @intCast(@min(n, 1000))) + 3, min_height, compact_height);
    const generous = @max(@min(area.h -| 4, (area.h * 4) / 5), min_height);
    const h = @min(@min(compact, generous), area.h);
    return overlay.place(area, w, h, if (anchor == .top) .top else .center);
}

/// `placeWith`, anchored on the frame the picker opened on: the size
/// still follows the filtered count, but the top border stays on the
/// row it first landed on instead of re-centring under every keystroke.
/// Remembers that row the first time it is asked, and clamps it back on
/// screen if the terminal was resized since.
pub fn placeState(area: Rect, n: usize, s: *State) Rect {
    var r = placeWith(area, n, s.anchor, s.has_preview);
    const top = s.top orelse {
        s.top = r.y;
        return r;
    };
    r.y = @max(@min(top, area.bottom() -| r.h), area.y);
    return r;
}

/// The box: query row, then the rows. Registers `.overlay_item(i)` per
/// visible row. Returns the query caret.
pub fn draw(ui: Ui, area: Rect, s: *State, items: []const Item) ?Caret {
    const t = ui.theme;
    if (area.isEmpty()) return null;
    const inner = overlay.frameLook(ui, placeState(area, items.len, s), s.title, .modal);
    if (inner.isEmpty()) return null;
    const bg = t.overlay_bg.bg;

    // ── query row ──
    const qr = inner.row(0);
    const count_text = if (s.total) |total| blk: {
        if (s.query.items.len == 0 or items.len == total) break :blk ui.fmt(" {d} ", .{items.len});
        break :blk ui.fmt(" {d} of {d} ", .{ items.len, total });
    } else ui.fmt(" {d} ", .{items.len});
    const count_w = ui.width(count_text);
    var field_w = qr.w -| 2;
    if (qr.w >= count_w + 8) {
        _ = ui.putStrRight(qr.right(), qr.y, count_w, count_text, Theme.onBg(t.muted, bg));
        field_w = qr.w -| (2 + count_w + 1);
    }
    const qf = Rect.init(qr.x + 2, qr.y, field_w, 1);
    // The query's own hit, over the field: a click places the caret, a
    // double takes a word, a triple the query (`dispatch.fieldPress`).
    ui.hit(qf, .{ .overlay_item = query_item });
    const caret = text_field.draw(ui, qf, s.query.items, s.caret, .{ .style = Theme.onBg(t.fg, bg), .anchor = s.sel_anchor, .field = .picker_query });
    if (inner.h < 2) return caret;

    // ── the preview column ──
    // Results left, the cursor row's preview right, a rule between
    // them. It is taken off the width BEFORE the rows are laid out, so
    // the scrollbar, the detail budget and the hits all land inside the
    // left half. A box too narrow to read two columns in has none —
    // the picker never squeezes itself below what it can paint.
    var body = Rect.init(inner.x, inner.y + 1, inner.w, inner.h - 1);
    if (s.has_preview) {
        const want = @max(min_preview, body.w * preview_share_num / preview_share_den);
        if (body.w >= min_label + list_panel.marker_w + 1 + want) {
            const split = body.splitRight(want + 1);
            body = split.left;
            const rule = split.rest.splitLeft(1);
            ui.vrule(rule.left.x, rule.left.y, rule.left.h, Theme.onBg(t.border, bg));
            drawPreview(ui, rule.rest, s, bg);
        } else s.preview_h = 0;
    } else s.preview_h = 0;

    // ── rows ──
    const list_area = body;
    s.rows = list_area.h;
    if (s.cursor >= items.len) s.cursor = items.len -| 1;
    if (items.len == 0) {
        s.scroll = 0;
        _ = ui.putStr(list_area.x, list_area.y, list_area.w, no_matches, Theme.onBg(t.muted, bg));
        return caret;
    }
    const win = list_panel.scrollWindow(&s.scroll, s.cursor, items.len, list_area.h);
    var rows_rect = list_area;
    if (win.needs_bar and list_area.w > 4) {
        const split = list_area.splitRight(1);
        rows_rect = split.left;
        scrollbar.drawVertical(ui, split.rest, .{ .pane = scrollbar_owner }, items.len, list_area.h, s.scroll);
    }
    const marker = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
    const lw = rows_rect.w;
    var i: usize = 0;
    while (i < win.visible) : (i += 1) {
        const idx = win.first + i;
        const it = items[idx];
        const r = rows_rect.row(@intCast(i));
        const selected = idx == s.cursor;
        const row_bg = if (selected) t.chip.bg else bg;
        ui.fill(r, .{ .bg = row_bg });
        // The marker cell doubles as the multi-select tick: a marked row
        // keeps its check whether or not the cursor is on it.
        if (it.marked) {
            _ = ui.putStr(r.x, r.y, 1, if (ui.ascii) "*" else "\u{2713}", Theme.onBg(t.accent, row_bg));
        } else if (selected) _ = ui.putStr(r.x, r.y, 1, marker, Theme.onBg(t.accent, row_bg));
        // Rust's budget: the detail may take what is left past twelve
        // label cells, clipped with an ellipsis; it costs a cell of air
        // on each side, and a row without one still owes the edge one.
        const detail_budget = lw -| (list_panel.marker_w + min_label + 1);
        var detail: []const u8 = it.detail orelse "";
        const detail_orig_w = ui.width(detail);
        if (detail_orig_w > detail_budget) detail = if (detail_budget >= 2) ui.clipStr(detail, detail_budget) else "";
        const dw = ui.width(detail);
        const detail_cost: u16 = if (dw > 0) dw + 2 else 0;
        const right_pad: u16 = if (dw > 0) 0 else 1;
        const label_avail = lw -| (list_panel.marker_w + detail_cost + right_pad);
        const label = if (ui.width(it.label) > label_avail) ui.clipStr(it.label, label_avail) else it.label;
        var label_style = Theme.onBg(t.fg, row_bg);
        if (selected) label_style.bold = true;
        var hit_style = Theme.onBg(t.accent, row_bg);
        hit_style.bold = true;
        var x = r.x + list_panel.marker_w;
        var label_room = label_avail;
        if (it.icon) |g| if (g.len > 0 and label_room > 3) {
            const w = ui.putStr(x, r.y, label_room, ui.fmt("{s} ", .{g}), Theme.onBg(t.accent, row_bg));
            x += w;
            label_room -|= w;
        };
        x += drawLabel(ui, x, r.y, label_room, label, s.query.items, label_style, hit_style);
        if (it.hint) |hh| {
            const room = (r.right() -| detail_cost -| right_pad) -| x;
            if (room > 2) x += ui.putStr(x, r.y, room, ui.clipStr(ui.fmt(" {s}", .{hh}), room), Theme.onBg(t.muted, row_bg));
        }
        if (dw > 0) _ = ui.putStrRight(r.right(), r.y, dw + 2, ui.fmt(" {s} ", .{detail}), Theme.onBg(t.muted, row_bg));
        ui.hit(r, .{ .overlay_item = @intCast(idx) });
    }
    return caret;
}

/// The preview column: the cursor row's rows, in the script pane's
/// segment shape, clipped at the column's edges. A row past the bottom
/// is dropped; text past the right edge is clipped — the pane's rule.
///
/// The first row painted is the focus (a grep hit) centred against the
/// column's REAL height, plus whatever the reader scrolled — so the
/// centring is right at every box size and no rebuild re-centres it.
fn drawPreview(ui: Ui, area: Rect, s: *State, bg: vaxis.Color) void {
    s.preview_h = area.h;
    if (area.isEmpty()) return;
    const rows = s.preview;
    // The focus sits mid-column, but never past the last screenful: a
    // preview short enough to fit still starts at its first line.
    var off: usize = 0;
    if (s.preview_focus) |f| off = @min(f -| (area.h / 2), rows.len -| area.h);
    off += s.preview_scroll;
    if (off > rows.len -| 1) off = rows.len -| 1;
    var y: u16 = 0;
    while (off + y < rows.len and y < area.h) : (y += 1) {
        var x = area.x;
        for (rows[off + y]) |seg| {
            if (x >= area.right()) break;
            var st = seg.style;
            // A segment that names its own ground (a grep hit) keeps it.
            if (std.meta.activeTag(st.bg) == .default) st.bg = bg;
            x += ui.putStr(x, area.y + y, area.right() -| x, seg.text, st);
        }
    }
}

/// The label with the query's matched characters in `hit_style`;
/// returns the cells painted.
fn drawLabel(ui: Ui, x: u16, y: u16, max_w: u16, label: []const u8, query: []const u8, style: Style, hit_style: Style) u16 {
    if (query.len == 0) return ui.putStr(x, y, max_w, label, style);
    const m = (fuzzy.match(ui.arena, query, label) catch null) orelse return ui.putStr(x, y, max_w, label, style);
    var painted: u16 = 0;
    var pos: usize = 0;
    var hi: usize = 0;
    while (pos < label.len and painted < max_w) {
        // The run from `pos`: matched cells while `positions` say so,
        // else up to the next matched byte.
        const hit = hi < m.positions.len and m.positions[hi] == pos;
        var end = pos;
        if (hit) {
            while (hi < m.positions.len and m.positions[hi] == end) : (hi += 1) {
                end += std.unicode.utf8ByteSequenceLength(label[end]) catch 1;
                if (end >= label.len) break;
            }
        } else {
            end = if (hi < m.positions.len) @min(m.positions[hi], label.len) else label.len;
        }
        if (end <= pos) end = pos + 1;
        painted += ui.putStr(x + painted, y, max_w - painted, label[pos..end], if (hit) hit_style else style);
        pos = end;
    }
    return painted;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const files = [_]Item{
    .{ .label = "a.txt", .detail = "src/a.txt" },
    .{ .label = "b.txt", .detail = "src/b.txt", .hint = "ctrl+2" },
    .{ .label = "c.txt", .detail = "lib/c.txt" },
};

test "the box shows the title, the query, the count, ranked rows with hits, and the caret" {
    var f = try Fixture.init(80, 20);
    defer f.deinit();
    var s: State = .{ .title = "Buffers", .total = 3 };
    defer s.deinit(testing.allocator);
    const caret = draw(f.ui(), f.full(), &s, &files);
    try f.expectContains(" Buffers ");
    try f.expectContains("a.txt");
    try f.expectContains("c.txt");
    try f.expectContains("src/b.txt");
    try f.expectContains("ctrl+2");
    // 72 wide (80-8), 6 rows (3 items + 3 → min 7): box y = (20-7)/2 = 6.
    // Query row is inner row 7; rows 8..10.
    try testing.expectEqual(Caret{ .x = 7, .y = 7 }, caret.?);
    try testing.expectEqual(@as(u32, 0), f.hits.at(10, 8).?.overlay_item);
    try testing.expectEqual(@as(u32, 2), f.hits.at(10, 10).?.overlay_item);
    try testing.expect(f.hits.at(10, 11) == null);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, f.row(7, &buf), " 3 │"));
    // The selected row: marker + bold label + a chip ground; a square frame.
    try testing.expectEqualStrings("\u{258c}", f.cell(5, 8).char.grapheme);
    try testing.expect(f.style(6, 8).bold);
    try testing.expect(f.bgEql(6, 8, f.theme.chip));
    try testing.expect(!f.style(6, 9).bold);
    try testing.expect(std.mem.startsWith(u8, f.row(6, &buf), "    ┌ Buffers "));
    // The detail sits against the right edge with one cell of air.
    try testing.expect(std.mem.endsWith(u8, f.row(8, &buf), "src/a.txt │"));
}

const names = [_]Item{ .{ .label = "alpha" }, .{ .label = "beta" }, .{ .label = "gamma" } };

test "typing filters via rank + gather, the count says N of M, the cursor rewinds, the hits paint in the accent" {
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    var s: State = .{ .title = "Files", .total = names.len };
    defer s.deinit(testing.allocator);
    const gpa = testing.allocator;
    _ = try handleKey(&s, gpa, Key.named(.down), names.len);
    try testing.expectEqual(@as(usize, 1), s.cursor);
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.char('g'), names.len));
    try testing.expectEqual(@as(usize, 0), s.cursor);
    const order = try rank(f.arena_state.allocator(), s.queryText(), &names, .{});
    try testing.expectEqualSlices(usize, &.{2}, order);
    const shown = try gather(f.arena_state.allocator(), &names, order);
    _ = draw(f.ui(), f.full(), &s, shown);
    try f.expectContains("gamma");
    try f.expectLacks("alpha");
    try f.expectContains(" 1 of 3 ");
    // 52 wide at x 4; the row at y (12-7)/2 + 2 = 4; the `g` at cell 6 is the hit.
    try testing.expect(f.fgEql(6, 4, f.theme.accent));
    try testing.expect(f.style(6, 4).bold);
    try testing.expect(!f.fgEql(7, 4, f.theme.accent));
    try testing.expectEqual(@as(usize, 0), (try handleKey(&s, gpa, Key.named(.enter), shown.len)).accept);
    // No matches: the row says so and enter does nothing.
    try testing.expectEqual(Outcome.changed, try handleKey(&s, gpa, Key.char('z'), shown.len));
    const none = try rank(f.arena_state.allocator(), s.queryText(), &names, .{});
    try testing.expectEqual(@as(usize, 0), none.len);
    _ = draw(f.ui(), f.full(), &s, &.{});
    try f.expectContains("(no matches)");
    try testing.expectEqual(Outcome.consumed, try handleKey(&s, gpa, Key.named(.enter), 0));
    try testing.expectEqual(Outcome.cancel, try handleKey(&s, gpa, Key.named(.esc), 0));
    // An empty query keeps the app's order.
    const all = try rank(f.arena_state.allocator(), "", &files, .{});
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, all);
}

test "rank is Rust's refilter: priority beats score, bonuses tier the empty query, the palette pins an exact id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // priority_beats_score_in_refilter
    const items = [_]Item{ .{ .label = "lib.rs" }, .{ .label = "src/lib.rs" } };
    const by_prio = try rank(arena, "lib", &items, .{ .priority = &.{ 1, 2 } });
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, by_prio);
    // score_bonus_tiers_recents_beat_pane_scoped_beat_generic
    const cmds = [_]Item{ .{ .label = "Quit mnml" }, .{ .label = "Editor stats" }, .{ .label = "Insert last cmdline" } };
    const tiers = try rank(arena, "", &cmds, .{ .score_bonus = &.{ 0, 20, 50 } });
    try testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, tiers);
    // The exact id is tier 9; an id containing the query gains 100.
    const pal = [_]Item{ .{ .label = "file  ·  Save file as…  ·  file.save_as" }, .{ .label = "file  ·  Save file  ·  file.save" } };
    const pinned = try rank(arena, "file.save", &pal, .{ .ids = &.{ "file.save_as", "file.save" } });
    try testing.expectEqualSlices(usize, &.{ 1, 0 }, pinned);
}

test "a path list reads a spaced query as terms in any order; a literal space still matches; other lists do not split" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = [_]Item{ .{ .label = "src/main.rs" }, .{ .label = "src/domain/manager.rs" }, .{ .label = "docs/readme.md" }, .{ .label = "with space/my file.txt" } };
    const both = try rank(arena, "src main", &items, .{ .terms = true });
    try std.testing.expectEqual(@as(usize, 2), both.len);
    try std.testing.expectEqual(@as(usize, 0), both[0]);
    try std.testing.expectEqual(@as(usize, 2), (try rank(arena, "main src", &items, .{ .terms = true })).len);
    const lit = try rank(arena, "my file", &items, .{ .terms = true });
    try std.testing.expectEqual(@as(usize, 3), lit[0]);
    try std.testing.expectEqual(@as(usize, 0), (try rank(arena, "src main", &items, .{})).len);
}

test "the geometry at 80, 120 and 200 columns is Rust's; top anchors to the edge" {
    // w = clamp(W-8, 30, 90); h = clamp(n+3, 7, 22) capped at 4/5 of H; centred.
    try testing.expect(place(Rect.init(0, 0, 80, 24), 3, .center).eql(Rect.init(4, 8, 72, 7)));
    try testing.expect(place(Rect.init(0, 0, 120, 40), 321, .center).eql(Rect.init(15, 9, 90, 22)));
    try testing.expect(place(Rect.init(0, 0, 200, 60), 4, .center).eql(Rect.init(55, 26, 90, 7)));
    try testing.expect(place(Rect.init(0, 0, 120, 40), 321, .top).eql(Rect.init(15, 0, 90, 22)));
    try testing.expect(place(Rect.init(0, 0, 20, 5), 40, .center).eql(Rect.init(0, 0, 20, 5)));
}

test "a long list scrolls with the cursor, pages, wheels, and shows a bar" {
    var f = try Fixture.init(50, 16);
    defer f.deinit();
    const arena = f.arena_state.allocator();
    const many = try arena.alloc(Item, 40);
    for (many, 0..) |*it, i| it.* = .{ .label = try std.fmt.allocPrint(arena, "item {d}", .{i}) };
    var s: State = .{ .title = "Many" };
    defer s.deinit(testing.allocator);
    _ = draw(f.ui(), f.full(), &s, many);
    // h = min(43→22, min(12, 12)→12, 16) = 12 → 9 rows.
    try testing.expectEqual(@as(usize, 9), s.rows);
    try f.expectContains("item 8");
    try f.expectLacks("item 9");
    try testing.expect(f.hits.at(44, 5).? == .scrollbar);
    try testing.expectEqual(scrollbar_owner, f.hits.at(44, 5).?.scrollbar.owner.pane);
    _ = try handleKey(&s, testing.allocator, Key.named(.page_down), many.len);
    try testing.expectEqual(@as(usize, 9), s.cursor);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('n'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('j'), many.len);
    try testing.expectEqual(@as(usize, 11), s.cursor);
    f.hits.reset();
    _ = draw(f.ui(), f.full(), &s, many);
    try testing.expectEqual(@as(usize, 3), s.scroll);
    try f.expectContains("item 11");
    try f.expectLacks("item 2");
    try testing.expectEqual(@as(u32, 11), f.hits.at(10, 12).?.overlay_item);
    wheel(&s, 3, many.len);
    try testing.expectEqual(@as(usize, 14), s.cursor);
    wheel(&s, -100, many.len);
    try testing.expectEqual(@as(usize, 0), s.cursor);
    wheel(&s, 100, many.len);
    try testing.expectEqual(@as(usize, 39), s.cursor);
    // The window follows the wheel: the last page, the marker on its last row.
    f.hits.reset();
    _ = draw(f.ui(), f.full(), &s, many);
    try testing.expectEqual(@as(usize, 31), s.scroll);
    try f.expectContains("item 39");
    try f.expectLacks("item 30");
    try testing.expectEqual(@as(u32, 39), f.hits.at(10, 12).?.overlay_item);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    _ = try handleKey(&s, testing.allocator, Key.ctrl('u'), many.len);
    try testing.expectEqual(@as(usize, 0), s.cursor);
    try paste(&s, testing.allocator, "item 3");
    try testing.expectEqualStrings("item 3", s.queryText());
}

test "the palette row is Rust's: marker, label, gap, the chord with air on both sides, the bar" {
    var f = try Fixture.init(120, 40);
    defer f.deinit();
    const arena = f.arena_state.allocator();
    const many = try arena.alloc(Item, 30);
    for (many, 0..) |*it, i| it.* = .{ .label = try std.fmt.allocPrint(arena, "git  ·  Git: row {d}  ·  git.row_{d}", .{ i, i }), .detail = if (i == 1) "ctrl+k b" else "" };
    var s: State = .{ .title = "Command palette", .total = 796 };
    defer s.deinit(testing.allocator);
    try s.query.appendSlice(testing.allocator, "git");
    s.caret = 3;
    _ = draw(f.ui(), f.full(), &s, many);
    try f.expectRow(9, " " ** 15 ++ "┌ Command palette " ++ "─" ** 71 ++ "┐");
    try f.expectRow(10, " " ** 15 ++ "│  git" ++ " " ** 72 ++ " 30 of 796 │");
    try f.expectRow(11, " " ** 15 ++ "│▌git  ·  Git: row 0  ·  git.row_0" ++ " " ** 54 ++ "█│");
    try f.expectRow(12, " " ** 15 ++ "│ git  ·  Git: row 1  ·  git.row_1" ++ " " ** 45 ++ "ctrl+k b █│");
    try f.expectRow(30, " " ** 15 ++ "└" ++ "─" ** 88 ++ "┘");
    // The three `git` cells of every row are the hit; the rest is not.
    try testing.expect(f.fgEql(17, 11, f.theme.accent));
    try testing.expect(f.fgEql(19, 11, f.theme.accent));
    try testing.expect(!f.fgEql(20, 11, f.theme.accent));
    try testing.expectEqual(@as(u32, 1), f.hits.at(40, 12).?.overlay_item);
    try testing.expect(f.hits.at(103, 12).? == .scrollbar);
}

test "the box never exceeds a tiny screen" {
    var s: State = .{ .title = "Tiny" };
    defer s.deinit(testing.allocator);
    inline for (.{ .{ 29, 5 }, .{ 12, 3 }, .{ 2, 2 }, .{ 40, 1 }, .{ 1, 1 } }) |wh| {
        var f = try Fixture.init(wh[0], wh[1]);
        defer f.deinit();
        _ = draw(f.ui(), f.full(), &s, &files);
        for (f.hits.items.items) |e| try testing.expect(f.full().intersect(e.rect).eql(e.rect));
    }
}

test "a cell of air before the bar: a hint without a detail owes the edge the cell the label does" {
    var f = try Fixture.init(40, 12);
    defer f.deinit();
    var s: State = .{ .title = "Files" };
    defer s.deinit(testing.allocator);
    var items: [20]Item = undefined;
    for (&items) |*it| it.* = .{ .label = "a.txt", .hint = "a hint long enough to reach the edge of the row" };
    _ = draw(f.ui(), f.full(), &s, &items);
    const bar = for (f.hits.items.items) |e| {
        if (e.target == .scrollbar) break e.rect;
    } else return error.TestNoBar;
    try f.expectAirBeforeBar(bar.y, bar.y + bar.h, bar.x);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, f.row(bar.y, &buf), "… █│"));
}

test "list keys: with the flag and an empty query j / k / g / G move; a typed char filters and j types after it" {
    const gpa = std.testing.allocator;
    var s: State = .{ .title = "References", .list_keys_when_empty = true };
    defer s.deinit(gpa);
    try std.testing.expect((try handleKey(&s, gpa, Key.char('j'), 3)) == .consumed);
    try std.testing.expectEqual(@as(usize, 1), s.cursor);
    try std.testing.expect((try handleKey(&s, gpa, Key.char('G'), 3)) == .consumed);
    try std.testing.expectEqual(@as(usize, 2), s.cursor);
    try std.testing.expect((try handleKey(&s, gpa, Key.char('k'), 3)) == .consumed);
    try std.testing.expectEqual(@as(usize, 1), s.cursor);
    try std.testing.expect((try handleKey(&s, gpa, Key.char('g'), 3)) == .consumed);
    try std.testing.expectEqual(@as(usize, 0), s.cursor);
    try std.testing.expectEqualStrings("", s.queryText());
    try std.testing.expect((try handleKey(&s, gpa, Key.char('a'), 3)) == .changed);
    try std.testing.expect((try handleKey(&s, gpa, Key.char('j'), 3)) == .changed);
    try std.testing.expectEqualStrings("aj", s.queryText());
    // Without the flag `j` types from the start.
    var plain: State = .{ .title = "Files" };
    defer plain.deinit(gpa);
    try std.testing.expect((try handleKey(&plain, gpa, Key.char('j'), 3)) == .changed);
    try std.testing.expectEqualStrings("j", plain.queryText());
}

test "a preview column: results left, the preview right, a rule between; a narrow box keeps all its width for the rows" {
    var f = try Fixture.init(120, 20);
    defer f.deinit();
    const arena = f.arena_state.allocator();
    const rows = try arena.alloc(PreviewRow, 2);
    rows[0] = &[_]script_view.Segment{.{ .text = "file  ·  Save file", .style = f.theme.fg }};
    rows[1] = &[_]script_view.Segment{.{ .text = "ctrl+s", .style = f.theme.muted }};
    var s: State = .{ .title = "Recent commands", .total = 3, .has_preview = true, .preview = rows };
    defer s.deinit(testing.allocator);
    _ = draw(f.ui(), f.full(), &s, &files);
    try f.expectContains("a.txt");
    try f.expectContains("file  ·  Save file");
    try f.expectContains("ctrl+s");
    // 112 wide (120-8) at x 4; the preview takes 2/5 = 44 plus the rule.
    var buf: [256]u8 = undefined;
    const row = f.row(8, &buf);
    try testing.expect(std.mem.indexOf(u8, row, "\u{2502}file  \u{b7}") != null);
    // The rows' own right edge is inside the left half: the detail of
    // row 0 sits before the rule, not under the preview.
    const rule_at = std.mem.indexOf(u8, row, "\u{2502}file").?;
    try testing.expect(std.mem.indexOf(u8, row[0..rule_at], "src/a.txt") != null);
    // Below 30 columns the box paints at all — and has no preview column.
    var tiny = try Fixture.init(28, 10);
    defer tiny.deinit();
    var ts: State = .{ .title = "Tiny", .has_preview = true, .preview = rows };
    defer ts.deinit(testing.allocator);
    _ = draw(tiny.ui(), tiny.full(), &ts, &files);
    try tiny.expectContains("a.txt");
    try tiny.expectLacks("file  \u{b7}");
    for (tiny.hits.items.items) |e| try testing.expect(tiny.full().intersect(e.rect).eql(e.rect));
}

test "multi-select: tab marks a row and steps on, a marked row keeps its check, and without multi tab is not a picker key" {
    const gpa = testing.allocator;
    var s: State = .{ .title = "Rows", .multi = true };
    defer s.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), (try handleKey(&s, gpa, Key.named(.tab), 3)).toggle);
    // The picker's own list does not move the cursor — the app does,
    // through `toggleMark`. Here the outcome is all that is asserted.
    s.cursor = 1;
    try testing.expectEqual(@as(usize, 1), (try handleKey(&s, gpa, Key.named(.tab), 3)).toggle);
    try testing.expect((try handleKey(&s, gpa, Key.named(.tab), 0)) == .consumed);
    var single: State = .{ .title = "Rows" };
    defer single.deinit(gpa);
    const out = try handleKey(&single, gpa, Key.named(.tab), 3);
    try testing.expect(out != .toggle);
    // A marked row paints a check where the marker would go.
    var f = try Fixture.init(60, 12);
    defer f.deinit();
    const marked = [_]Item{ .{ .label = "one", .marked = true }, .{ .label = "two" }, .{ .label = "three", .icon = "+" } };
    var draw_state: State = .{ .title = "Rows", .multi = true, .cursor = 1 };
    defer draw_state.deinit(gpa);
    _ = draw(f.ui(), f.full(), &draw_state, &marked);
    try testing.expectEqualStrings("\u{2713}", f.cell(5, 4).char.grapheme);
    try testing.expectEqualStrings("\u{258c}", f.cell(5, 5).char.grapheme);
    try f.expectContains("+ three");
}

test "the preview centres its focus against the column's real height and the scroll keys move it, never the list" {
    const gpa = testing.allocator;
    // Twelve numbered rows; the focus is the ninth.
    var rows: [12]PreviewRow = undefined;
    var segs: [12][1]PreviewSegment = undefined;
    var texts: [12][8]u8 = undefined;
    for (&rows, 0..) |*r, i| {
        const text = std.fmt.bufPrint(&texts[i], "L{d}", .{i}) catch unreachable;
        segs[i] = .{.{ .text = text, .style = .{} }};
        r.* = &segs[i];
    }
    // A box tall enough for every row: nothing is scrolled off, even
    // with a focus, because the focus already fits.
    const many = [_]Item{ .{ .label = "a" }, .{ .label = "b" }, .{ .label = "c" }, .{ .label = "d" }, .{ .label = "e" }, .{ .label = "f" }, .{ .label = "g" }, .{ .label = "h" }, .{ .label = "i" }, .{ .label = "j" }, .{ .label = "k" }, .{ .label = "l" }, .{ .label = "m" }, .{ .label = "n" } };
    var f = try Fixture.init(100, 30);
    defer f.deinit();
    var s: State = .{ .title = "Grep", .has_preview = true, .preview = &rows, .preview_focus = 8 };
    defer s.deinit(gpa);
    _ = draw(f.ui(), f.full(), &s, &many);
    try testing.expect(s.preview_h >= rows.len);
    try f.expectContains("L0");
    try f.expectContains("L8");

    // A short box: the focus would fall off the bottom, so the column
    // starts part-way down and the focus lands near the middle.
    var short = try Fixture.init(100, 12);
    defer short.deinit();
    var ss: State = .{ .title = "Grep", .has_preview = true, .preview = &rows, .preview_focus = 8 };
    defer ss.deinit(gpa);
    _ = draw(short.ui(), short.full(), &ss, &files);
    try short.expectLacks("L0");
    try short.expectContains("L8");

    // ctrl+d scrolls the preview; the cursor stays on row 0.
    _ = try handleKey(&s, gpa, Key.ctrl('d'), files.len);
    try testing.expectEqual(@as(usize, 0), s.cursor);
    try testing.expect(s.preview_scroll > 0);
    const scrolled = s.preview_scroll;
    _ = try handleKey(&s, gpa, Key.ctrl('u'), files.len);
    try testing.expect(s.preview_scroll < scrolled);
    // PageDown scrolls a whole column, and never past the last row.
    var i: usize = 0;
    while (i < 20) : (i += 1) _ = try handleKey(&s, gpa, Key.named(.page_down), files.len);
    try testing.expectEqual(rows.len - 1, s.preview_scroll);
    try testing.expectEqual(@as(usize, 0), s.cursor);

    // Without a preview column the same keys page the list, as before.
    var plain: State = .{ .title = "Files", .rows = 2 };
    defer plain.deinit(gpa);
    _ = try handleKey(&plain, gpa, Key.named(.page_down), files.len);
    try testing.expectEqual(files.len - 1, plain.cursor);
    try testing.expectEqual(@as(usize, 0), plain.preview_scroll);
}
