//! ListPanel(Row) — the generic activity panel: a caps header with the
//! sort chip and the refresh glyph, a filter pill, a scrolling list of
//! rows with a selection marker, a scrollbar when the list is longer
//! than the panel, a kebab on the hovered row, and an empty state when
//! there is nothing to list. TODOS, NOTES, FINDINGS and SESSIONS are
//! all this type with a different `Row` and `paintRow`.
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
    return if (selected) Theme.onBg(t.panel_bg, t.cursor_line.bg) else t.panel_bg;
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

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const spinner_ascii = [_][]const u8{ "|", "/", "-", "\\" };

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
    const frames: []const []const u8 = if (ui.ascii) &spinner_ascii else &spinner_frames;
    const idx: usize = @intCast(@mod(@divFloor(now_ms, 80), @as(i64, @intCast(frames.len))));
    const style = chip.refreshStyle(ui.theme, ui.theme.panel_bg.bg);
    const x = area.right() - 3;
    _ = ui.putStr(x, area.y, 1, " ", style);
    _ = ui.putStr(x + 1, area.y, 1, frames[idx], style);
    _ = ui.putStr(x + 2, area.y, 1, " ", style);
}

pub fn ListPanel(comptime Row: type) type {
    return struct {
        const Self = @This();

        pub const State = struct {
            scroll: usize = 0,
            cursor: usize = 0,
            filter: text_field.Buf = .empty,
            filter_caret: usize = 0,
            filter_focused: bool = false,
            /// Set by `draw`, read by `handleKey` (paging, clamping).
            visible: usize = 0,
            total: usize = 0,

            pub fn deinit(s: *State, gpa: Allocator) void {
                s.filter.deinit(gpa);
                s.* = .{};
            }

            pub fn filterText(s: *const State) []const u8 {
                return s.filter.items;
            }
        };

        /// Paints one row's content into `r` (the cells after the
        /// marker). The ground is already filled in `rowStyle`.
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
        };

        pub const Outcome = union(enum) {
            ignored,
            consumed,
            /// The filter text changed — re-filter the rows.
            filter_changed,
            /// Enter on a row.
            activate: usize,
        };

        /// Paints the panel and returns the filter's caret when it has
        /// focus (the app places the terminal cursor there).
        pub fn draw(st: *State, ui: Ui, area: Rect, p: Props) ?Caret {
            const t = ui.theme;
            ui.fill(area, t.panel_bg);
            if (area.isEmpty()) return null;

            // Header.
            const top = area.splitTop(1);
            const mode_text: ?[]const u8 = if (p.sort_chip) |v| (chip.modeText(ui.arena, "sort", v, p.sort_widest) catch null) else null;
            _ = header.draw(ui, top.top, .{
                .panel = p.panel,
                .label = p.label,
                .subtitle = p.subtitle,
                .mode_chip = mode_text,
                .mode_kind = .sort,
                .show_refresh = p.show_refresh,
                .bg = t.panel_bg,
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
                    .focused = st.filter_focused,
                    .bg = t.panel_bg,
                });
                rest = fr.rest;
            }

            // Rows.
            st.total = p.rows.len;
            if (st.cursor >= p.rows.len) st.cursor = p.rows.len -| 1;
            if (p.rows.len == 0) {
                st.visible = 0;
                st.scroll = 0;
                _ = empty_state.draw(ui, rest, p.empty, t.panel_bg);
                return caret;
            }
            const win = scrollWindow(&st.scroll, st.cursor, p.rows.len, rest.h);
            st.visible = rest.h;
            var list = rest;
            if (win.needs_bar and rest.w > marker_w + 1) {
                const split = rest.splitRight(1);
                list = split.left;
                scrollbar.drawVertical(ui, split.rest, .{ .panel = p.panel }, p.rows.len, rest.h, st.scroll);
            }
            if (list.w <= marker_w) return caret;

            const focused = ui.isFocused(.{ .panel = p.panel });
            var i: usize = 0;
            while (i < win.visible) : (i += 1) {
                const idx = win.first + i;
                const row_rect = list.row(@intCast(i));
                const selected = idx == st.cursor;
                const style = rowStyle(t, selected);
                ui.fill(row_rect, style);
                if (selected) {
                    const marker = if (ui.ascii) marker_ascii else marker_glyph;
                    const mstyle = Theme.withFg(style, if (focused) t.accent.fg else t.muted.fg);
                    _ = ui.putStr(row_rect.x, row_rect.y, marker_w, marker, mstyle);
                }
                var content = row_rect.splitLeft(marker_w).rest;
                const hovered = p.has_kebab and ui.hovered(row_rect);
                if (hovered and content.w > kebab_w) {
                    content = content.splitRight(kebab_w).left;
                }
                p.paintRow(ui.withClip(content), content, p.rows[idx], selected);
                ui.hit(row_rect, .{ .row = .{ .panel = p.panel, .idx = @intCast(idx) } });
                if (hovered and row_rect.w > marker_w + kebab_w) {
                    const kr = row_rect.rightCells(kebab_w);
                    const kstyle = Theme.withFg(style, t.accent.fg);
                    _ = ui.putStr(kr.x, kr.y, kr.w, if (ui.ascii) kebab_ascii else kebab_glyph, kstyle);
                    ui.hit(kr, .{ .kebab = .{ .panel = p.panel, .idx = @intCast(idx) } });
                }
            }
            return caret;
        }

        /// Keys for the panel: `/` focuses the filter, j/k and the arrows
        /// move, g/G and home/end jump, page keys page, enter activates.
        /// In the filter: esc clears then blurs, enter blurs, the arrows
        /// still move the selection, everything else edits the text.
        pub fn handleKey(st: *State, gpa: Allocator, key: Key) Allocator.Error!Outcome {
            const total = st.total;
            const last = total -| 1;
            const page = @max(1, st.visible);
            const m = key.mods;
            if (st.filter_focused) {
                switch (key.code) {
                    .esc => {
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
                        st.cursor -|= 1;
                        return .consumed;
                    },
                    .down => {
                        st.cursor = @min(st.cursor + 1, last);
                        return .consumed;
                    },
                    .char => |c| if (m.ctrl and (c == 'n' or c == 'p')) {
                        if (c == 'n') st.cursor = @min(st.cursor + 1, last) else st.cursor -|= 1;
                        return .consumed;
                    },
                    else => {},
                }
                return switch (try text_field.handleKey(&st.filter, &st.filter_caret, gpa, key)) {
                    .ignored => .ignored,
                    .moved => .consumed,
                    .changed => blk: {
                        st.cursor = 0;
                        break :blk .filter_changed;
                    },
                };
            }
            switch (key.code) {
                .up => st.cursor -|= 1,
                .down => st.cursor = @min(st.cursor + 1, last),
                .home => st.cursor = 0,
                .end => st.cursor = last,
                .page_up => st.cursor -|= page,
                .page_down => st.cursor = @min(st.cursor + page, last),
                .enter => return if (total > 0) .{ .activate = st.cursor } else .ignored,
                .esc => {
                    if (st.filter.items.len == 0) return .ignored;
                    st.filter.clearRetainingCapacity();
                    st.filter_caret = 0;
                    st.cursor = 0;
                    return .filter_changed;
                },
                .char => |c| {
                    if (m.ctrl) switch (c) {
                        'n' => st.cursor = @min(st.cursor + 1, last),
                        'p' => st.cursor -|= 1,
                        'd' => st.cursor = @min(st.cursor + page / 2, last),
                        'u' => st.cursor -|= page / 2,
                        else => return .ignored,
                    } else switch (c) {
                        '/' => st.filter_focused = true,
                        'j' => st.cursor = @min(st.cursor + 1, last),
                        'k' => st.cursor -|= 1,
                        'g' => st.cursor = 0,
                        'G' => st.cursor = last,
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
    const caret = Todos.draw(&st, f.ui(), f.full(), props(rows));
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
