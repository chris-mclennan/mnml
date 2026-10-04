//! ListPanel(Row) — the generic activity panel: a caps header with the
//! sort chip and the refresh glyph, a filter pill, an optional
//! ` + New … ` action row (Rust's `action_button::primary` chip, a
//! blank row on either side of it), a scrolling list of rows with a
//! selection marker, a scrollbar when the list is longer
//! than the panel (a cell of air kept between every row's text and the
//! bar), a kebab on the hovered row, and an empty state when
//! there is nothing to list. TODOS, NOTES, FINDINGS and SESSIONS are
//! all this type with a different `Row` and `paintRow`; an item may be
//! taller than a row (`Props.row_h` / `row_gap` — SESSIONS' four-row
//! card) and may paint its own selection signal (`own_marker`).
//!
//! The Rust mnml grew this shape four times and each copy missed
//! something — three panels shipped without scrolling at all, drawing
//! one screenful and dropping the rest. The arithmetic lives here once:
//! `scrollWindow` follows the cursor both ways and never leaves blank
//! rows under a full list.
//!
//! The panel owns only what is transient (`State`: scroll, cursor, the
//! filter text and its focus); the rows are the app's, already filtered
//! and sorted, handed in as a slice each frame. Every row registers a
//! `.row` hit over its width and the kebab a `.kebab` hit on top of it,
//! in the same statements as their paint.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const chip = @import("chip.zig");
const header = @import("header.zig");
const filter_input = @import("filter_input.zig");
const scrollbar = @import("scrollbar.zig");
const empty_state = @import("empty_state.zig");
const text_field = @import("text_field.zig");
const hit = @import("hit.zig");
const key_mod = @import("../core/key.zig");

const Allocator = std.mem.Allocator;
const Style = vaxis.Style;

pub const PanelId = hit.PanelId;
pub const EmptyState = empty_state.EmptyState;
pub const Caret = text_field.Caret;
pub const Key = key_mod.Key;

/// The selected-row marker: a left half block, so it carries its own
/// optical gap and no trailing space is ever added after it.
pub const marker_glyph = "\u{258c}";
pub const marker_ascii = ">";
pub const marker_w: u16 = 1;

/// The kebab on a hovered row.
pub const kebab_glyph = " \u{22ef} ";
pub const kebab_ascii = "...";
pub const kebab_w: u16 = 3;

pub const Window = struct { first: usize, visible: usize, needs_bar: bool };

/// The rows a panel spends above its list: the header, the filter
/// pill, the prelude, and the ` + New … ` chip with air either side
/// (or the filter's gap). `Panel.draw` lays them out in this order.
pub const Head = struct { show_filter: bool = true, prelude_rows: u16 = 0, has_new: bool = false, filter_gap: bool = false };

pub fn headRows(h: Head) u16 {
    return 1 + @as(u16, @intFromBool(h.show_filter)) + h.prelude_rows +
        (if (h.has_new) @as(u16, 3) else @intFromBool(h.filter_gap));
}

/// Items of `row_h` rows, `row_gap` apart, that fit in `list_h` rows
/// — the last needs no trailing gap.
pub fn perPage(list_h: u16, row_h: u16, row_gap: u16) usize {
    const stride: u16 = @max(1, row_h) + row_gap;
    return (list_h + row_gap) / stride;
}

/// Clamps `scroll` so `cursor` is inside `visible_rows` of `total`, and
/// reports the window. Follows the cursor both ways; never leaves blank
/// rows below a full list.
pub fn scrollWindow(scroll: *usize, cursor: usize, total: usize, visible_rows: usize) Window {
    if (visible_rows == 0 or total == 0) {
        scroll.* = 0;
        return .{ .first = 0, .visible = 0, .needs_bar = false };
    }
    const cur = @min(cursor, total - 1);
    if (cur < scroll.*) {
        scroll.* = cur;
    } else if (cur >= scroll.* + visible_rows) {
        scroll.* = cur + 1 - visible_rows;
    }
    const max_scroll = total -| visible_rows;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
    return .{
        .first = scroll.*,
        .visible = @min(visible_rows, total - scroll.*),
        .needs_bar = total > visible_rows,
    };
}

pub fn rowStyle(t: *const Theme, selected: bool) Style {
    return rowStyleOn(t, t.panel_bg, selected);
}

/// `rowStyle` on another ground — a panel drawn with `Props.ground`
/// (the start surface's lists sit on the editor area's ground, not the
/// side column's).
pub fn rowStyleOn(t: *const Theme, ground: Style, selected: bool) Style {
    return if (selected) Theme.onBg(ground, t.cursor_line.bg) else ground;
}

/// Where a panel's clicks go when it is not a side-column panel or a
/// pane-hosted one: the row's target by index, the ` + New … ` row's,
/// and the scrollbar's owner. The start surface's lists
/// (`ui/welcome.zig`) are the case — four lists that belong to no
/// panel id.
pub const Targets = struct {
    row: *const fn (idx: u32) hit.HitTarget,
    new: ?hit.HitTarget = null,
    bar: hit.Owner,
};

/// The selection gutter down the WHOLE of `r` — one marker cell per row
/// of the item, the accent when the panel has the keys and muted when
/// it does not. `ground` is the row's fill, so the marker keeps the
/// cursor-line background under it.
///
/// // changed (panel-consistency): an item taller than one row painted
/// its gutter on the first row alone, so SCRIPTS' and INTEGRATIONS'
/// two-row entries showed a half-height bar. The height is the knob:
/// every caller hands the item's whole rect, one row or four.
pub fn paintMarker(ui: Ui, r: Rect, ground: Style, focused: bool) void {
    if (r.w == 0) return;
    const t = ui.theme;
    const marker = if (ui.ascii) marker_ascii else marker_glyph;
    const style = Theme.withFg(ground, if (focused) t.accent.fg else t.muted.fg);
    var y: u16 = 0;
    while (y < r.h) : (y += 1) _ = ui.putStr(r.x, r.y + y, marker_w, marker, style);
}

/// How long ago `then_s` was, in one short token: `now`, `5m`, `3h`,
/// `2d`, `6w`, `4mo`, `2y`. On the frame arena; a future stamp is `now`.
pub fn ageText(ui: Ui, now_s: i64, then_s: i64) []const u8 {
    const d = now_s - then_s;
    if (d < 60) return "now";
    if (d < 3600) return ui.fmt("{d}m", .{@divFloor(d, 60)});
    if (d < 86_400) return ui.fmt("{d}h", .{@divFloor(d, 3600)});
    if (d < 7 * 86_400) return ui.fmt("{d}d", .{@divFloor(d, 86_400)});
    if (d < 30 * 86_400) return ui.fmt("{d}w", .{@divFloor(d, 7 * 86_400)});
    if (d < 365 * 86_400) return ui.fmt("{d}mo", .{@divFloor(d, 30 * 86_400)});
    return ui.fmt("{d}y", .{@divFloor(d, 365 * 86_400)});
}

/// Eight-dot braille, one dot dark and walking round: every frame fills
/// all four of the cell's dot rows, so the spinner sits on the text's
/// centre. The six-dot ring (`⠋⠙⠹…`) lit only the top three rows and
/// rode above the figure beside it.
pub const spinner_frames = [_][]const u8{ "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" };
pub const spinner_ascii = [_][]const u8{ "|", "/", "-", "\\" };

test "every spinner frame spans the braille cell's four dot rows, so it sits on the text's centre" {
    for (spinner_frames) |f| {
        const cp = try std.unicode.utf8Decode(f);
        try std.testing.expect(cp >= 0x2800 and cp <= 0x28ff);
        const dots: u8 = @intCast(cp - 0x2800);
        // Row one is dots 1 / 4, row four dots 7 / 8: a frame with
        // nothing in row four is the six-dot ring that rode high.
        try std.testing.expect(dots & (0x01 | 0x08) != 0);
        try std.testing.expect(dots & (0x40 | 0x80) != 0);
    }
}
/// One turn of the frame ring, in ms.
pub const spinner_step_ms: i64 = 80;

test "the SDK's spinner is this ring at this step, so an integration's header turns with the host's panels" {
    const sdk_chrome = @import("mnml_sdk").pane.chrome;
    try std.testing.expectEqual(spinner_frames.len, sdk_chrome.spinner_frames.len);
    for (spinner_frames, sdk_chrome.spinner_frames) |ours, theirs| try std.testing.expectEqualStrings(ours, theirs);
    for (spinner_ascii, sdk_chrome.spinner_ascii) |ours, theirs| try std.testing.expectEqualStrings(ours, theirs);
    try std.testing.expectEqual(spinner_step_ms, sdk_chrome.spinner_step_ms);
    try std.testing.expectEqualStrings(spinnerFrame(240, false), sdk_chrome.spinnerFrame(240, false));
}

/// The frame the whole app's spinners are on at `now_ms`. The panel
/// headers paint it themselves (`paintSpinner`); a statusline chip
/// that wants the same tick — `app/ghost_chip.zig` — asks for the text.
pub fn spinnerFrame(now_ms: i64, ascii: bool) []const u8 {
    const frames: []const []const u8 = if (ascii) &spinner_ascii else &spinner_frames;
    const idx: usize = @intCast(@mod(@divFloor(now_ms, spinner_step_ms), @as(i64, @intCast(frames.len))));
    return frames[idx];
}

/// While a scan runs the refresh chip shows a spinner. The chip's
/// cells are the header's last three when it fits (`header.zig`'s
/// ladder); they are overpainted and the hit registered under them
/// stays. `label` is the caps title, which decides whether the chip
/// fit at all.
/// // changed: `Props` has no `busy` flag — a `ui`-side addition would
/// let the header paint this itself. Shared by every list panel.
pub fn paintSpinner(ui: Ui, area: Rect, label: []const u8, now_ms: i64) void {
    const label_w = ui.width(label);
    if (area.w < label_w + 3 + 3 or area.h == 0) return;
    const style = chip.refreshStyle(ui.theme, ui.theme.panel_bg.bg);
    const x = area.right() - 3;
    _ = ui.putStr(x, area.y, 1, " ", style);
    _ = ui.putStr(x + 1, area.y, 1, spinnerFrame(now_ms, ui.ascii), style);
    _ = ui.putStr(x + 2, area.y, 1, " ", style);
}

/// `Ctrl` and nothing else: the list's own `Ctrl+N` / `Ctrl+P`, never
/// the app's `Ctrl+Alt+N` or `Ctrl+Shift+P`.
fn bareCtrl(m: anytype) bool {
    return m.ctrl and !m.alt and !m.shift and !m.super;
}

pub fn ListPanel(comptime Row: type) type {
    return struct {
        const Self = @This();

        pub const State = struct {
            scroll: usize = 0,
            cursor: usize = 0,
            filter: text_field.Buf = .empty,
            filter_caret: usize = 0,
            /// The filter's selection (`text_field.clickSelect`): from
            /// here to the caret; typing or a paste replaces it.
            filter_anchor: ?usize = null,
            filter_focused: bool = false,
            /// The cursor sits on the ` + New … ` row above row 0.
            on_new: bool = false,
            /// Set by `draw`, read by `handleKey` (paging, clamping).
            visible: usize = 0,
            total: usize = 0,
            /// Set by `draw`: the panel paints a New row this frame.
            has_new: bool = false,
            /// // changed (sessions-card): set by `draw` — the screen row
            /// after the last painted item (or after the empty state and
            /// a blank), where a panel's own footer starts.
            end_y: u16 = 0,

            pub fn deinit(s: *State, gpa: Allocator) void {
                s.filter.deinit(gpa);
                s.* = .{};
            }

            pub fn filterText(s: *const State) []const u8 {
                return s.filter.items;
            }

            /// The filter as a field the pointer edits (`dispatch.fieldRef`).
            pub fn filterField(s: *State) text_field.Ref {
                return .{ .buf = &s.filter, .caret = &s.filter_caret, .anchor = &s.filter_anchor };
            }
        };

        /// Paints one row's content into `r` (the cells after the
        /// marker, ending a cell before the scrollbar when there is
        /// one). The ground is already filled in `rowStyle`.
        pub const PaintRow = *const fn (ui: Ui, r: Rect, row: Row, selected: bool) void;

        pub const Props = struct {
            panel: PanelId,
            label: []const u8,
            /// `(3 of 40)` — the app knows the unfiltered count.
            subtitle: ?[]const u8 = null,
            /// The current sort's label (`ListSort.label()`); null = no chip.
            sort_chip: ?[]const u8 = null,
            /// `ListSort.widest_label` — the chip pads to it.
            sort_widest: usize = 0,
            rows: []const Row,
            paintRow: PaintRow,
            has_kebab: bool = false,
            empty: EmptyState,
            show_filter: bool = true,
            show_refresh: bool = true,
            /// A green ` + ` chip before the refresh glyph (`ChipKind.new`).
            new_chip: bool = false,
            /// `+ New todo`: the action row under the filter — a blank row,
            /// the chip ` label ` on the green fill at `x + 1`, a blank row.
            /// Its hit is `.chip{panel, .new}`; the cursor reaches it from
            /// row 0 with `k` / `↑`, and `⏎` there is `Outcome.new_activate`.
            new_label: ?[]const u8 = null,
            /// // changed (http-panel): one blank row between the filter
            /// and the list when there is no New row (which brings its
            /// own air) — the HTTP section's shape.
            filter_gap: bool = false,
            /// Rows under the header (and the filter pill, when shown)
            /// left to the panel's owner — painted in the panel's ground
            /// and otherwise untouched; the owner paints them after
            /// `draw` (the SEARCH section's query and status rows).
            prelude_rows: u16 = 0,
            /// Rows per item — SESSIONS' card is four — with `row_gap`
            /// blank rows between items. The scroll window counts items;
            /// an item's hit covers all its rows; the kebab sits on its
            /// first row.
            row_h: u16 = 1,
            row_gap: u16 = 0,
            /// The row paints its own selection signal (Rust's session
            /// card turns its accent cyan): no cursor-line ground, no
            /// marker, and `paintRow` gets the whole item rect from `x`.
            own_marker: bool = false,
            /// // changed (sessions-merge): a pane hosts the panel. Every
            /// target registers as the pane's `.script_hit` with a
            /// `hit.ListHit` id (rows, kebabs, chips, the filter), the
            /// scrollbar's owner is the pane, and `focused` says whether
            /// the pane has the keys (the `.panel` focus never does).
            pane: ?PaneId = null,
            /// Extra header chips (`header.ExtraChip`); pane-hosted only.
            extra_chips: []const header.ExtraChip = &.{},
            /// Null reads `ui.isFocused(.{ .panel })`.
            focused: ?bool = null,
            /// // changed (sessions-card): rows kept free under the list
            /// for the panel's own footer (SESSIONS' EXTERNAL / ENDED
            /// groups); the page counts items over the rest.
            reserve_bottom: u16 = 0,
            /// // changed (welcome): the panel's ground; null is the
            /// theme's `panel_bg`, the side column's.
            ground: ?Style = null,
            /// // changed (welcome): false paints no row as selected —
            /// a list that shares its screen with others and is not the
            /// one the keys walk.
            show_cursor: bool = true,
            /// // changed (welcome): the rows' / New row's / bar's hits
            /// for a panel that is neither a side panel nor pane-hosted.
            targets: ?Targets = null,
        };

        pub const PaneId = hit.PaneId;

        pub const Outcome = union(enum) {
            ignored,
            consumed,
            /// The filter text changed — re-filter the rows.
            filter_changed,
            /// Enter on a row.
            activate: usize,
            /// Enter on the ` + New … ` row.
            new_activate,
        };

        /// Paints the panel and returns the filter's caret when it has
        /// focus (the app places the terminal cursor there).
        pub fn draw(st: *State, ui: Ui, area: Rect, p: Props) ?Caret {
            const t = ui.theme;
            const ground = p.ground orelse t.panel_bg;
            ui.fill(area, ground);
            if (area.isEmpty()) return null;

            // Header.
            const top = area.splitTop(1);
            const mode_text: ?[]const u8 = if (p.sort_chip) |v| (chip.modeText(ui.arena, "sort", v, p.sort_widest) catch null) else null;
            const focused = p.focused orelse ui.isFocused(.{ .panel = p.panel });
            _ = header.draw(ui, top.top, .{
                .panel = p.panel,
                .label = p.label,
                .subtitle = p.subtitle,
                .mode_chip = mode_text,
                .mode_kind = .sort,
                .show_refresh = p.show_refresh,
                .new_chip = p.new_chip,
                .bg = ground,
                .pane = p.pane,
                .extra = p.extra_chips,
                .focused = focused,
            });

            // Filter pill.
            var caret: ?Caret = null;
            var rest = top.rest;
            if (p.show_filter) {
                const fr = rest.splitTop(1);
                caret = filter_input.draw(ui, fr.top, .{
                    .panel = p.panel,
                    .text = st.filter.items,
                    .caret = st.filter_caret,
                    .anchor = st.filter_anchor,
                    .focused = st.filter_focused,
                    .bg = ground,
                    .pane = p.pane,
                });
                rest = fr.rest;
                // The caret goes on to the terminal cursor, and only the
                // FOCUSED panel's may: `filter_focused` is the pill's own
                // state and survives stepping away from the panel, so a
                // panel you have left must not take the cursor off
                // whatever you stepped to (`app/cursor.zig`). The pill is
                // painted either way — that is how you find your way back.
                if (!focused) caret = null;
            }

            if (p.prelude_rows > 0) rest = rest.splitTop(@min(p.prelude_rows, rest.h)).rest;

            // The ` + New … ` row with a blank row on either side: the
            // filter, air, the chip, air, the list.
            st.has_new = p.new_label != null;
            if (p.new_label) |label| {
                if (rest.h > 0) rest = rest.splitTop(1).rest;
                if (rest.h > 0) {
                    const nr = rest.splitTop(1);
                    const row_rect = nr.top;
                    rest = nr.rest;
                    const on_new = st.on_new and p.show_cursor;
                    const style = rowStyleOn(t, ground, on_new);
                    ui.fill(row_rect, style);
                    if (on_new) paintMarker(ui, row_rect, style, focused);
                    const text = ui.fmt(" {s} ", .{label});
                    const cw = @min(ui.width(text), row_rect.w -| 1);
                    if (cw > 0) {
                        const cr = Rect.init(row_rect.x + 1, row_rect.y, cw, 1);
                        _ = ui.putStr(cr.x, cr.y, cw, ui.clipStr(text, cw), chip.newRowStyle(t));
                        const new_target = if (p.targets) |tg| (tg.new orelse hit.chipTarget(p.panel, .new, p.pane)) else hit.chipTarget(p.panel, .new, p.pane);
                        ui.hit(cr, new_target);
                    }
                }
                if (rest.h > 0) rest = rest.splitTop(1).rest;
            } else {
                st.on_new = false;
                if (p.filter_gap and rest.h > 0) rest = rest.splitTop(1).rest;
            }

            // Rows.
            st.total = p.rows.len;
            st.end_y = rest.y;
            if (st.cursor >= p.rows.len) st.cursor = p.rows.len -| 1;
            if (p.rows.len == 0) {
                st.visible = 0;
                st.scroll = 0;
                const used = empty_state.draw(ui, rest, p.empty, ground);
                st.end_y = @min(rest.y + used + 1, rest.bottom());
                return caret;
            }
            // Items per page: a trailing gap is not needed for the last
            // item, so `h + gap` over the stride.
            const stride: u16 = @max(1, p.row_h) + p.row_gap;
            const list_h: u16 = rest.h -| p.reserve_bottom;
            const per_page: usize = perPage(list_h, p.row_h, p.row_gap);
            const win = scrollWindow(&st.scroll, st.cursor, p.rows.len, per_page);
            st.visible = per_page;
            var list = rest;
            // The cell of air between a row's text and the bar: the row
            // (its ground, its hit) runs to the bar; the painter's content
            // stops one cell short of it.
            var air: u16 = 0;
            if (win.needs_bar and rest.w > marker_w + 1) {
                const split = rest.splitRight(1);
                list = split.left;
                air = 1;
                const owner: hit.Owner = if (p.targets) |tg| tg.bar else if (p.pane) |id| .{ .pane = id } else .{ .panel = p.panel };
                scrollbar.drawVertical(ui, split.rest, owner, p.rows.len, per_page, st.scroll);
            }
            if (list.w <= marker_w) return caret;
            st.end_y = @min(list.y + @as(u16, @intCast(win.visible)) * stride, rest.bottom());

            var i: usize = 0;
            while (i < win.visible) : (i += 1) {
                const idx = win.first + i;
                const row_rect = Rect.init(list.x, list.y + @as(u16, @intCast(i)) * stride, list.w, @max(1, p.row_h));
                const selected = p.show_cursor and idx == st.cursor and !st.on_new;
                const style = if (p.own_marker) ground else rowStyleOn(t, ground, selected);
                var content = row_rect;
                if (!p.own_marker) {
                    ui.fill(row_rect, style);
                    // The gutter runs the item's whole height, not its
                    // first row (`paintMarker`).
                    if (selected) paintMarker(ui, row_rect, style, focused);
                    content = row_rect.splitLeft(marker_w).rest;
                }
                const hovered = p.has_kebab and ui.hovered(row_rect);
                // The item's first row yields to the kebab a hover adds;
                // its other rows keep the width they had at rest, so a
                // card's body never re-clips as the pointer comes over.
                var first = content;
                if (content.w > air) content = content.splitRight(air).left;
                if (hovered and first.w > kebab_w) {
                    // The kebab's own trailing cell is the air.
                    first = first.splitRight(kebab_w).left;
                } else first = content;
                // The row's hit goes under the painter's own (a header's
                // chips, a link): last painted wins.
                // // changed (http-panel): was registered after `paintRow`,
                // so a painter's targets could never be clicked.
                // The hit takes the gap under the item as well, and the
                // last item of a list that scrolls the rows left under
                // it: the wheel over a gap between two cards, or under
                // the last whole one, lands on the list and scrolls it.
                const hit_h: u16 = if (i + 1 < win.visible) stride else if (win.needs_bar) (rest.y + list_h) -| row_rect.y else row_rect.h;
                const hit_rect = Rect.init(row_rect.x, row_rect.y, row_rect.w, @max(row_rect.h, hit_h));
                if (p.targets) |tg| ui.hit(hit_rect, tg.row(@intCast(idx))) else if (p.pane) |id| ui.hit(hit_rect, .{ .script_hit = .{ .pane = id, .id = hit.ListHit.row(@intCast(idx)) } }) else ui.hit(hit_rect, .{ .row = .{ .panel = p.panel, .idx = @intCast(idx) } });
                if (content.h > 1 and first.w != content.w) {
                    // Painted twice, each pass clipped to its rows: the
                    // first row against the narrow width, the rest
                    // against the full one — last, so their hits win.
                    p.paintRow(ui.withClip(first.row(0)), first, p.rows[idx], selected);
                    p.paintRow(ui.withClip(Rect.init(content.x, content.y + 1, content.w, content.h - 1)), content, p.rows[idx], selected);
                } else p.paintRow(ui.withClip(first), first, p.rows[idx], selected);
                if (hovered and row_rect.w > marker_w + kebab_w) {
                    const kr = row_rect.row(0).rightCells(kebab_w);
                    const kstyle = Theme.withFg(style, t.accent.fg);
                    _ = ui.putStr(kr.x, kr.y, kr.w, if (ui.ascii) kebab_ascii else kebab_glyph, kstyle);
                    if (p.pane) |id| ui.hit(kr, .{ .script_hit = .{ .pane = id, .id = hit.ListHit.kebab(@intCast(idx)) } }) else ui.hit(kr, .{ .kebab = .{ .panel = p.panel, .idx = @intCast(idx) } });
                }
            }
            return caret;
        }

        /// Up by `n`: from row 0 the cursor climbs onto the New row when
        /// there is one; from the New row it stays.
        fn moveUp(st: *State, n: usize) void {
            if (st.on_new) return;
            if (st.cursor == 0 and st.has_new) {
                st.on_new = true;
                return;
            }
            st.cursor -|= n;
        }

        /// Down by `n`: from the New row the cursor drops to row 0.
        fn moveDown(st: *State, n: usize, last: usize) void {
            if (st.on_new) {
                st.on_new = false;
                st.cursor = 0;
                return;
            }
            st.cursor = @min(st.cursor + n, last);
        }

        /// Keys for the panel: `/` focuses the filter, j/k and the arrows
        /// move (up from row 0 reaches the ` + New … ` row), g/G and
        /// home/end jump, page keys page, enter activates the row — or
        /// the New row. In the filter: esc clears then blurs, enter blurs,
        /// the arrows still move the selection, everything else edits
        /// the text.
        pub fn handleKey(st: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
            const total = st.total;
            const last = total -| 1;
            const page = @max(1, st.visible);
            const m = key.mods;
            if (st.filter_focused) {
                switch (key.code) {
                    .esc => {
                        st.filter_anchor = null;
                        if (st.filter.items.len > 0) {
                            st.filter.clearRetainingCapacity();
                            st.filter_caret = 0;
                            return .filter_changed;
                        }
                        st.filter_focused = false;
                        return .consumed;
                    },
                    .enter => {
                        st.filter_focused = false;
                        return .consumed;
                    },
                    .up => {
                        moveUp(st, 1);
                        return .consumed;
                    },
                    .down => {
                        moveDown(st, 1, last);
                        return .consumed;
                    },
                    .char => |c| if (bareCtrl(m) and (c == 'n' or c == 'p')) {
                        if (c == 'n') moveDown(st, 1, last) else moveUp(st, 1);
                        return .consumed;
                    },
                    else => {},
                }
                return switch (try text_field.editKey(&st.filter, &st.filter_caret, &st.filter_anchor, gpa, key)) {
                    .ignored => .ignored,
                    .moved => .consumed,
                    .changed => blk: {
                        st.cursor = 0;
                        st.on_new = false;
                        break :blk .filter_changed;
                    },
                };
            }
            switch (key.code) {
                .up => moveUp(st, 1),
                .down => moveDown(st, 1, last),
                .home => {
                    st.cursor = 0;
                    st.on_new = false;
                },
                .end => {
                    st.cursor = last;
                    st.on_new = false;
                },
                .page_up => moveUp(st, page),
                .page_down => moveDown(st, page, last),
                .enter => {
                    if (st.on_new) return .new_activate;
                    return if (total > 0) .{ .activate = st.cursor } else .ignored;
                },
                .esc => {
                    if (st.filter.items.len == 0) return .ignored;
                    st.filter.clearRetainingCapacity();
                    st.filter_caret = 0;
                    st.filter_anchor = null;
                    st.cursor = 0;
                    st.on_new = false;
                    return .filter_changed;
                },
                .char => |c| {
                    // The list binds bare `Ctrl+N/P/D/U` and plain keys
                    // only. Any other modified chord — `Ctrl+Alt+N`,
                    // `Ctrl+Shift+P`, `Alt+J` — is the app's, and goes
                    // on to the keymap, as it does from the tree.
                    if (m.alt or m.super or (m.ctrl and m.shift)) return .ignored;
                    if (m.ctrl) switch (c) {
                        'n' => moveDown(st, 1, last),
                        'p' => moveUp(st, 1),
                        'd' => moveDown(st, page / 2, last),
                        'u' => moveUp(st, page / 2),
                        else => return .ignored,
                    } else switch (c) {
                        '/' => st.filter_focused = true,
                        'j' => moveDown(st, 1, last),
                        'k' => moveUp(st, 1),
                        'g' => {
                            st.cursor = 0;
                            st.on_new = false;
                        },
                        'G' => {
                            st.cursor = last;
                            st.on_new = false;
                        },
                        else => return .ignored,
                    }
                },
                else => return .ignored,
            }
            return .consumed;
        }
    };
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const Todo = struct { title: []const u8, done: bool };

fn paintTodo(ui: Ui, r: Rect, row: Todo, selected: bool) void {
    const t = ui.theme;
    const style = rowStyle(t, selected);
    const box = if (row.done) "[x] " else "[ ] ";
    const x = r.x + ui.putStr(r.x, r.y, r.w, box, Theme.withFg(style, t.muted.fg));
    _ = ui.putStr(x, r.y, r.right() -| x, ui.clipStr(row.title, r.right() -| x), style);
}

/// The row starts with `left`, ends with `right`, and is spaces between.
fn expectRowLike(f: *Fixture, y: u16, left: []const u8, right: []const u8) !void {
    var buf: [256]u8 = undefined;
    const row = f.row(y, &buf);
    if (!std.mem.startsWith(u8, row, left) or !std.mem.endsWith(u8, row, right) or row.len < left.len + right.len) {
        std.debug.print("row {d} is {s}\n", .{ y, row });
        return error.TestUnexpectedRow;
    }
    for (row[left.len .. row.len - right.len]) |c| if (c != ' ') {
        std.debug.print("row {d} is {s}\n", .{ y, row });
        return error.TestUnexpectedRow;
    };
}

const Todos = ListPanel(Todo);

fn forty(arena: Allocator) ![]Todo {
    const rows = try arena.alloc(Todo, 40);
    for (rows, 0..) |*r, i| r.* = .{ .title = try std.fmt.allocPrint(arena, "todo {d}", .{i + 1}), .done = i % 3 == 0 };
    return rows;
}

fn props(rows: []const Todo) Todos.Props {
    return .{
        .panel = .todos,
        .label = "TODOS",
        .sort_chip = "Newest first",
        .sort_widest = 12,
        .rows = rows,
        .paintRow = paintTodo,
        .has_kebab = true,
        .empty = .{ .message = "No todos yet", .hint = "n adds one" },
    };
}

test "header, filter, rows, scrollbar: the shape at the shipped width" {
    var f = try Fixture.init(30, 12);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try forty(f.arena_state.allocator());
    const caret = Todos.draw(&st, f.ui(), f.full(), props(rows));
    try testing.expect(caret == null);
    // Row 0: the header with the icon rung (30 wide). Row 1: the pill.
    try f.expectRow(0, " TODOS" ++ " " ** 18 ++ "\u{f0dc}   \u{eb37}");
    try f.expectRow(1, "  \u{F0349} / filter");
    try f.expectRow(2, "\u{258c}[x] todo 1" ++ " " ** 18 ++ "█");
    try f.expectRow(3, " [ ] todo 2" ++ " " ** 18 ++ "█");
    try f.expectRow(11, " [x] todo 10" ++ " " ** 17 ++ "█");
    try testing.expectEqual(@as(usize, 10), st.visible);
    try testing.expectEqual(@as(usize, 40), st.total);
    // Hits: rows, the bar, the chips, the pill.
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 2).?.row.idx);
    try testing.expectEqual(@as(u32, 9), f.hits.at(0, 11).?.row.idx);
    try testing.expectEqual(hit.PanelId.todos, f.hits.at(28, 5).?.row.panel);
    try testing.expectEqual(hit.Axis.v, f.hits.at(29, 5).?.scrollbar.axis);
    try testing.expectEqual(hit.ChipKind.sort, f.hits.at(24, 0).?.chip.kind);
    try testing.expectEqual(hit.PanelId.todos, f.hits.at(10, 1).?.filter_input);
    try testing.expect(f.bgEql(5, 2, f.theme.cursor_line));
    try testing.expect(f.bgEql(5, 3, f.theme.panel_bg));
}

test "a cell of air before the bar at the shipped width: long labels clip with the ellipsis a cell short of it, on every row, and the row's ground and hit still reach it" {
    // `tree_width = 30` (Config's default) leaves the panel 26 cells:
    // rail 3, border 1, the panel, the divider at 30.
    var f = try Fixture.init(26, 8);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try f.arena_state.allocator().alloc(Todo, 12);
    for (rows, 0..) |*r, i| r.* = .{ .title = "a title long enough to overflow the row", .done = i % 2 == 0 };
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    try f.expectRow(2, "\u{258c}[x] a title long enoug… █");
    try f.expectRow(3, " [ ] a title long enoug… █");
    try f.expectRow(7, " [ ] a title long enoug… █");
    try f.expectAirBeforeBar(2, 8, 25);
    // The cursor row's ground runs up to the bar; the air cell is the row.
    try testing.expect(f.bgEql(24, 2, f.theme.cursor_line));
    try testing.expectEqual(@as(u32, 0), f.hits.at(24, 2).?.row.idx);
    try testing.expectEqual(hit.Axis.v, f.hits.at(25, 2).?.scrollbar.axis);
    // A kebab on the hovered row: its own trailing cell is the air.
    f.hover = .{ .x = 5, .y = 3 };
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    try f.expectRow(3, " [ ] a title long eno… \u{22ef} █");
    try f.expectAirBeforeBar(2, 8, 25);
}

test "the cursor scrolls the window both ways and the tail never goes blank" {
    var f = try Fixture.init(30, 12);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try forty(f.arena_state.allocator());
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    st.cursor = 25;
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    try testing.expectEqual(@as(usize, 16), st.scroll);
    try expectRowLike(&f, 11, "\u{258c}[ ] todo 26", "█");
    try testing.expectEqual(@as(u32, 25), f.hits.at(5, 11).?.row.idx);
    st.cursor = 3;
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    try testing.expectEqual(@as(usize, 3), st.scroll);
    try expectRowLike(&f, 2, "\u{258c}[x] todo 4", "█");
    // A scroll past the end is pulled back so the last screen is full.
    st.scroll = 39;
    st.cursor = 39;
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    try testing.expectEqual(@as(usize, 30), st.scroll);
    try expectRowLike(&f, 2, " [x] todo 31", "█");
    try expectRowLike(&f, 11, "\u{258c}[x] todo 40", "█");
    // Fewer rows than the window: no bar, no hit in the last column.
    f.hits.reset();
    st.cursor = 0;
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows[0..4]));
    try f.expectRow(2, "\u{258c}[x] todo 1");
    try f.expectRow(6, "");
    try testing.expect(f.hits.at(29, 2).? == .row);
    try testing.expectEqual(@as(usize, 0), st.scroll);
}

test "scrollWindow semantics" {
    var s: usize = 0;
    try testing.expectEqual(Window{ .first = 0, .visible = 0, .needs_bar = false }, scrollWindow(&s, 5, 0, 10));
    try testing.expectEqual(Window{ .first = 0, .visible = 0, .needs_bar = false }, scrollWindow(&s, 5, 40, 0));
    try testing.expectEqual(Window{ .first = 0, .visible = 10, .needs_bar = true }, scrollWindow(&s, 0, 40, 10));
    try testing.expectEqual(Window{ .first = 3, .visible = 10, .needs_bar = true }, scrollWindow(&s, 12, 40, 10));
    try testing.expectEqual(Window{ .first = 2, .visible = 10, .needs_bar = true }, scrollWindow(&s, 2, 40, 10));
    s = 35;
    try testing.expectEqual(Window{ .first = 30, .visible = 10, .needs_bar = true }, scrollWindow(&s, 39, 40, 10));
    s = 0;
    try testing.expectEqual(Window{ .first = 0, .visible = 4, .needs_bar = false }, scrollWindow(&s, 2, 4, 10));
    // A cursor past the end clamps to the last row.
    s = 0;
    try testing.expectEqual(Window{ .first = 30, .visible = 10, .needs_bar = true }, scrollWindow(&s, 99, 40, 10));
}

test "the kebab appears on the hovered row only, and its hit sits on top of the row's" {
    var f = try Fixture.init(30, 6);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try forty(f.arena_state.allocator());
    f.hover = .{ .x = 10, .y = 3 };
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    try expectRowLike(&f, 3, " [ ] todo 2", "\u{22ef} █");
    try expectRowLike(&f, 2, "\u{258c}[x] todo 1", "█");
    try testing.expectEqual(@as(u32, 1), f.hits.at(27, 3).?.kebab.idx);
    try testing.expectEqual(@as(u32, 1), f.hits.at(10, 3).?.row.idx);
    try testing.expect(f.hits.at(27, 2).? == .row);
    // Without a kebab the hovered row is plain.
    f.hits.reset();
    var p = props(rows);
    p.has_kebab = false;
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    try expectRowLike(&f, 3, " [ ] todo 2", "█");
    try testing.expect(f.hits.at(27, 3).? == .row);
}

test "empty rows paint the empty state; the header and pill stay" {
    var f = try Fixture.init(30, 6);
    defer f.deinit();
    var st: Todos.State = .{ .cursor = 7, .scroll = 3 };
    defer st.deinit(testing.allocator);
    _ = Todos.draw(&st, f.ui(), f.full(), props(&.{}));
    try f.expectRow(1, "  \u{F0349} / filter");
    try f.expectRow(2, "  No todos yet");
    try f.expectRow(3, "  n adds one");
    try testing.expectEqual(@as(usize, 0), st.cursor);
    try testing.expectEqual(@as(usize, 0), st.scroll);
    try testing.expect(f.hits.at(5, 2) == null);
}

test "keys: motion, paging, the filter's focus and clearing" {
    var f = try Fixture.init(30, 12);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try forty(f.arena_state.allocator());
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    const gpa = testing.allocator;
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.char('j')));
    try testing.expectEqual(@as(usize, 1), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.named(.page_down));
    try testing.expectEqual(@as(usize, 11), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.char('G'));
    try testing.expectEqual(@as(usize, 39), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.char('j'));
    try testing.expectEqual(@as(usize, 39), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.ctrl('u'));
    try testing.expectEqual(@as(usize, 34), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.char('g'));
    try testing.expectEqual(@as(usize, 0), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.named(.up));
    try testing.expectEqual(@as(usize, 0), st.cursor);
    try testing.expectEqual(@as(usize, 0), (try Todos.handleKey(&st, gpa, Key.named(.enter))).activate);
    try testing.expectEqual(Todos.Outcome.ignored, try Todos.handleKey(&st, gpa, Key.char('x')));
    try testing.expectEqual(Todos.Outcome.ignored, try Todos.handleKey(&st, gpa, Key.named(.esc)));

    // The filter.
    _ = try Todos.handleKey(&st, gpa, Key.char('j'));
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.char('/')));
    try testing.expect(st.filter_focused);
    try testing.expectEqual(Todos.Outcome.filter_changed, try Todos.handleKey(&st, gpa, Key.char('t')));
    try testing.expectEqual(Todos.Outcome.filter_changed, try Todos.handleKey(&st, gpa, Key.char('o')));
    try testing.expectEqualStrings("to", st.filterText());
    try testing.expectEqual(@as(usize, 0), st.cursor);
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.named(.down)));
    try testing.expectEqual(@as(usize, 1), st.cursor);
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.named(.left)));
    try testing.expectEqual(Todos.Outcome.ignored, try Todos.handleKey(&st, gpa, Key.ctrl('x')));
    // `.focused` because only the focused panel's caret comes back —
    // it is what the terminal cursor goes on.
    var focused_props = props(rows);
    focused_props.focused = true;
    const caret = Todos.draw(&st, f.ui(), f.full(), focused_props);
    try f.expectRow(1, "  \u{F0349} to");
    try testing.expectEqual(Caret{ .x = 5, .y = 1 }, caret.?); // after the ←
    try testing.expectEqual(Todos.Outcome.filter_changed, try Todos.handleKey(&st, gpa, Key.named(.esc)));
    try testing.expectEqualStrings("", st.filterText());
    try testing.expect(st.filter_focused);
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.named(.esc)));
    try testing.expect(!st.filter_focused);
    _ = try Todos.handleKey(&st, gpa, Key.char('/'));
    _ = try Todos.handleKey(&st, gpa, Key.char('q'));
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.named(.enter)));
    try testing.expect(!st.filter_focused);
    // Esc from the list clears a stale filter.
    try testing.expectEqual(Todos.Outcome.filter_changed, try Todos.handleKey(&st, gpa, Key.named(.esc)));
    try testing.expectEqualStrings("", st.filterText());
}

test "keys: the list binds bare Ctrl+N / Ctrl+P and plain keys; Ctrl+Alt+N, Ctrl+Shift+P and Alt+J are the app's" {
    var f = try Fixture.init(30, 12);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try forty(f.arena_state.allocator());
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    const gpa = testing.allocator;
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.ctrl('n')));
    try testing.expectEqual(@as(usize, 1), st.cursor);
    for ([_]Key{
        .{ .code = .{ .char = 'n' }, .mods = .{ .ctrl = true, .alt = true } },
        .{ .code = .{ .char = 'p' }, .mods = .{ .ctrl = true, .shift = true } },
        .{ .code = .{ .char = 'P' }, .mods = .{ .ctrl = true, .shift = true } },
        .{ .code = .{ .char = 'j' }, .mods = .{ .alt = true } },
    }) |k| {
        try testing.expectEqual(Todos.Outcome.ignored, try Todos.handleKey(&st, gpa, k));
        try testing.expectEqual(@as(usize, 1), st.cursor);
    }
    // In the filter too: the field keeps its own keys, not the app's.
    _ = try Todos.handleKey(&st, gpa, Key.char('/'));
    try testing.expect(st.filter_focused);
    _ = try Todos.handleKey(&st, gpa, .{ .code = .{ .char = 'n' }, .mods = .{ .ctrl = true, .alt = true } });
    try testing.expectEqual(@as(usize, 1), st.cursor);
}

test "narrow and short areas never panic and register nothing off-screen" {
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    inline for (.{ .{ 1, 1 }, .{ 3, 3 }, .{ 6, 2 }, .{ 12, 4 }, .{ 30, 2 } }) |wh| {
        var f = try Fixture.init(wh[0], wh[1]);
        defer f.deinit();
        const rows = try forty(f.arena_state.allocator());
        _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
        for (f.hits.items.items) |e| try testing.expect(f.full().intersect(e.rect).eql(e.rect));
    }
}

test "the + New row: under the filter with a blank row after it, in the empty and the populated state; its hit is the chip; it takes the cursor from row 0" {
    var f = try Fixture.init(30, 12);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try forty(f.arena_state.allocator());
    var p = props(rows);
    p.new_label = "+ New todo";
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    try f.expectRow(1, "  \u{F0349} / filter");
    try f.expectRow(2, "");
    try f.expectRow(3, "  + New todo");
    try f.expectRow(4, "");
    try f.expectRow(5, "\u{258c}[x] todo 1" ++ " " ** 18 ++ "█");
    try testing.expectEqual(@as(usize, 7), st.visible);
    // The chip: ` + New todo ` at x + 1 on the green fill, the hit over it alone.
    try testing.expect(vaxis.Color.eql(f.style(1, 3).bg, f.theme.palette.green));
    try testing.expect(f.style(2, 3).bold);
    try testing.expectEqual(hit.ChipKind.new, f.hits.at(1, 3).?.chip.kind);
    try testing.expectEqual(hit.ChipKind.new, f.hits.at(12, 3).?.chip.kind);
    try testing.expect(f.hits.at(13, 3) == null);
    try testing.expect(f.hits.at(5, 2) == null);
    try testing.expect(f.hits.at(5, 4) == null);
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 5).?.row.idx);
    // Keys: k from row 0 climbs onto the row; the marker moves with it.
    const gpa = testing.allocator;
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.char('k')));
    try testing.expect(st.on_new);
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    try f.expectRow(3, "\u{258c} + New todo");
    try f.expectRow(5, " [x] todo 1" ++ " " ** 18 ++ "█");
    try testing.expect(f.bgEql(20, 3, f.theme.cursor_line));
    try testing.expect(f.bgEql(20, 5, f.theme.panel_bg));
    try testing.expectEqual(Todos.Outcome.new_activate, try Todos.handleKey(&st, gpa, Key.named(.enter)));
    // k again stays; j drops back to row 0; G / g / home leave it.
    _ = try Todos.handleKey(&st, gpa, Key.named(.up));
    try testing.expect(st.on_new);
    try testing.expectEqual(Todos.Outcome.consumed, try Todos.handleKey(&st, gpa, Key.char('j')));
    try testing.expect(!st.on_new);
    try testing.expectEqual(@as(usize, 0), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.named(.page_up));
    try testing.expect(st.on_new);
    _ = try Todos.handleKey(&st, gpa, Key.char('G'));
    try testing.expect(!st.on_new);
    try testing.expectEqual(@as(usize, 39), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.ctrl('p'));
    try testing.expectEqual(@as(usize, 38), st.cursor);
    _ = try Todos.handleKey(&st, gpa, Key.char('g'));
    _ = try Todos.handleKey(&st, gpa, Key.ctrl('p'));
    try testing.expect(st.on_new);
    // The filter's arrows reach it too, and typing puts the cursor back on row 0.
    _ = try Todos.handleKey(&st, gpa, Key.named(.down));
    _ = try Todos.handleKey(&st, gpa, Key.char('/'));
    _ = try Todos.handleKey(&st, gpa, Key.named(.up));
    try testing.expect(st.on_new);
    try testing.expectEqual(Todos.Outcome.filter_changed, try Todos.handleKey(&st, gpa, Key.char('t')));
    try testing.expect(!st.on_new);
    _ = try Todos.handleKey(&st, gpa, Key.named(.esc));
    _ = try Todos.handleKey(&st, gpa, Key.named(.esc));
    // Empty state: the row stays, the cursor reaches it, enter is the New action.
    f.hits.reset();
    _ = Todos.draw(&st, f.ui(), f.full(), .{
        .panel = .todos,
        .label = "TODOS",
        .rows = &.{},
        .paintRow = paintTodo,
        .empty = .{ .message = "No todos yet", .hint = "n adds one" },
        .new_label = "+ New todo",
    });
    try f.expectRow(2, "");
    try f.expectRow(3, "  + New todo");
    try f.expectRow(4, "");
    try f.expectRow(5, "  No todos yet");
    try testing.expectEqual(hit.ChipKind.new, f.hits.at(3, 3).?.chip.kind);
    try testing.expectEqual(Todos.Outcome.ignored, try Todos.handleKey(&st, gpa, Key.named(.enter)));
    _ = try Todos.handleKey(&st, gpa, Key.char('k'));
    try testing.expect(st.on_new);
    try testing.expectEqual(Todos.Outcome.new_activate, try Todos.handleKey(&st, gpa, Key.named(.enter)));
    // Without a label there is no row and the flag clears.
    _ = Todos.draw(&st, f.ui(), f.full(), props(rows));
    try testing.expect(!st.on_new and !st.has_new);
    try f.expectRow(2, "\u{258c}[x] todo 1" ++ " " ** 18 ++ "█");
    // Narrow: the chip clips to the row, nothing off-screen.
    var g = try Fixture.init(6, 6);
    defer g.deinit();
    _ = Todos.draw(&st, g.ui(), g.full(), p);
    try g.expectRow(3, "  + N…");
    for (g.hits.items.items) |e| try testing.expect(g.full().intersect(e.rect).eql(e.rect));
}

test "a multi-row item keeps its gutter on every row, not the first alone" {
    var f = try Fixture.init(30, 10);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try forty(f.arena_state.allocator());
    var p = props(rows);
    p.row_h = 2;
    p.has_kebab = false;
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    // Item 0 is selected: the marker is on BOTH of its rows and the
    // cursor-line ground runs under both.
    try testing.expectEqualStrings(marker_glyph, f.cell(0, 2).char.grapheme);
    try testing.expectEqualStrings(marker_glyph, f.cell(0, 3).char.grapheme);
    try testing.expect(f.bgEql(5, 2, f.theme.cursor_line));
    try testing.expect(f.bgEql(5, 3, f.theme.cursor_line));
    // Item 1 is not: neither of its rows carries one.
    try testing.expect(!std.mem.eql(u8, marker_glyph, f.cell(0, 4).char.grapheme));
    try testing.expect(!std.mem.eql(u8, marker_glyph, f.cell(0, 5).char.grapheme));
}

/// A four-row card: the marker down `x + 1` (accent when selected), the
/// title and a status line at `x + 3`.
fn paintCard(ui: Ui, r: Rect, row: Todo, selected: bool) void {
    const t = ui.theme;
    const bar = Theme.withFg(t.panel_bg, if (selected) t.accent.fg else t.panel_bg.bg);
    var y: u16 = 0;
    while (y < r.h) : (y += 1) _ = ui.putStr(r.x + 1, r.y + y, 1, marker_glyph, bar);
    _ = ui.putStr(r.x + 3, r.y, r.right() -| (r.x + 3), row.title, t.panel_bg);
    _ = ui.putStr(r.x + 3, r.y + 1, r.right() -| (r.x + 3), if (row.done) "done" else "open", t.panel_bg);
}

test "cards: row_h items with a gap, the hit over every row of one, the window counted in items, the row's own marker" {
    var f = try Fixture.init(30, 14);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = try forty(f.arena_state.allocator());
    var p = props(rows);
    p.row_h = 4;
    p.row_gap = 1;
    p.own_marker = true;
    p.paintRow = paintCard;
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    // Twelve rows under the pill: (12 + 1) / 5 = two cards, a gap between.
    try expectRowLike(&f, 2, " \u{258c} todo 1", "█");
    try expectRowLike(&f, 3, " \u{258c} done", "█");
    try expectRowLike(&f, 5, " \u{258c}", "█");
    try expectRowLike(&f, 6, "", "█");
    try expectRowLike(&f, 7, " \u{258c} todo 2", "█");
    try expectRowLike(&f, 8, " \u{258c} open", "█");
    try testing.expectEqual(@as(usize, 2), st.visible);
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 2).?.row.idx);
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 5).?.row.idx);
    // The gap is the card's above it, and the rows under the last whole
    // card of a list that scrolls are that card's: the wheel anywhere
    // over the list lands on it.
    try testing.expectEqual(@as(u32, 0), f.hits.at(5, 6).?.row.idx);
    try testing.expectEqual(@as(u32, 1), f.hits.at(5, 7).?.row.idx);
    try testing.expectEqual(@as(u32, 1), f.hits.at(5, 13).?.row.idx);
    // The selected card keeps the panel ground: the row paints its own signal.
    try testing.expect(f.bgEql(10, 2, f.theme.panel_bg));
    try testing.expectEqualStrings("\u{258c}", f.cell(1, 2).char.grapheme);
    // The kebab on the hovered card's first row, its hit over the card's rows.
    f.hits.reset();
    f.hover = .{ .x = 10, .y = 8 };
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    try expectRowLike(&f, 7, " \u{258c} todo 2", "\u{22ef} █");
    try expectRowLike(&f, 8, " \u{258c} open", "█");
    try testing.expectEqual(@as(u32, 1), f.hits.at(27, 7).?.kebab.idx);
    try testing.expectEqual(@as(u32, 1), f.hits.at(27, 8).?.row.idx);
    f.hover = null;
    // The window follows the cursor in items: the last page is cards 39 and 40.
    st.cursor = 39;
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    try testing.expectEqual(@as(usize, 38), st.scroll);
    try expectRowLike(&f, 2, " \u{258c} todo 39", "█");
    try expectRowLike(&f, 7, " \u{258c} todo 40", "█");
    try testing.expectEqual(@as(u32, 39), f.hits.at(5, 9).?.row.idx);
    // Four rows left under the pill: one card, no gap needed.
    var g = try Fixture.init(30, 6);
    defer g.deinit();
    st.cursor = 0;
    _ = Todos.draw(&st, g.ui(), g.full(), p);
    try testing.expectEqual(@as(usize, 1), st.visible);
    try expectRowLike(&g, 5, " \u{258c}", "█");
    for (g.hits.items.items) |e| try testing.expect(g.full().intersect(e.rect).eql(e.rect));
}

/// Every row of the card the title, cut with an ellipsis at the edge it
/// is given: what a SESSIONS card's name and summary rows do.
fn paintLongCard(ui: Ui, r: Rect, row: Todo, _: bool) void {
    var y: u16 = 0;
    while (y < r.h) : (y += 1) _ = ui.putStr(r.x + 3, r.y + y, r.right() -| (r.x + 3), ui.clipStr(row.title, r.right() -| (r.x + 3)), ui.theme.panel_bg);
}

test "a hovered card: the kebab takes cells from the name row only — the body rows clip at the width they have at rest" {
    var f = try Fixture.init(30, 14);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    const rows = [_]Todo{.{ .title = "https://example.com/a/very/long/path", .done = false }};
    var p = props(&rows);
    p.row_h = 4;
    p.own_marker = true;
    p.paintRow = paintLongCard;
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    var rest: [4][256]u8 = undefined;
    var at_rest: [4][]const u8 = undefined;
    for (0..4) |i| at_rest[i] = try testing.allocator.dupe(u8, f.row(@intCast(2 + i), &rest[i]));
    defer for (at_rest) |r| testing.allocator.free(r);
    f.hits.reset();
    f.hover = .{ .x = 10, .y = 4 };
    _ = Todos.draw(&st, f.ui(), f.full(), p);
    var buf: [256]u8 = undefined;
    // The name row yields: shorter text, the kebab at its end.
    const name = f.row(2, &buf);
    try testing.expect(std.mem.endsWith(u8, name, "\u{22ef}"));
    try testing.expect(!std.mem.eql(u8, name, at_rest[0]));
    // The body rows are cell for cell what they were at rest.
    for (1..4) |i| try testing.expectEqualStrings(at_rest[i], f.row(@intCast(2 + i), &buf));
    try testing.expect(std.mem.indexOf(u8, at_rest[1], "\u{2026}") != null);
    // The kebab's hit is on the name row, the card's under the rest.
    try testing.expectEqual(@as(u32, 0), f.hits.at(27, 2).?.kebab.idx);
    try testing.expectEqual(@as(u32, 0), f.hits.at(27, 3).?.row.idx);
}

test "the filter caret goes only to the focused panel: the pill still paints on one you have left" {
    var f = try Fixture.init(40, 10);
    defer f.deinit();
    var st: Todos.State = .{};
    defer st.deinit(testing.allocator);
    st.filter_focused = true;
    try st.filter.appendSlice(testing.allocator, "bug");
    st.filter_caret = 3;
    const rows = [_]Todo{.{ .title = "a", .done = false }};

    // Focused: the caret comes back, so the terminal cursor lands on it.
    var p = props(&rows);
    p.focused = true;
    try testing.expect(Todos.draw(&st, f.ui(), f.full(), p) != null);

    // Stepped away: no caret — but the pill and its text are still
    // painted, or there would be no way to see the filter is set.
    var p2 = props(&rows);
    p2.focused = false;
    try testing.expect(Todos.draw(&st, f.ui(), f.full(), p2) == null);
    var buf: [256]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, f.row(1, &buf), "bug") != null);
}
