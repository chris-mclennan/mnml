//! The chrome row — the Rust editor's `draw_palette_bar` look, cell for
//! cell. Left to right: the menu words (` ❯_  mnml  File  Edit …`), a
//! ` » ` chip once a word no longer fits before the centred cluster;
//! the centred nav cluster — the sidebar toggle, ` ← ` ` → `, the
//! workspace chip `  󰍉  <name padded to 24>  `, its ` ▾ ` dropdown and
//! the right-panel toggle — 48 cells, a one-cell gap between its
//! groups. The caller paints the right cluster and the gap chips after
//! it, from the `palette_right_edge` this reports.
//!
//! // changed (menu-bar-pin): a bar that can hide itself wears the
//! family's pin chip (`ui/pin_chip.zig`) at the right end of its own
//! run — past the last word, past the ` » ` when there is one — the
//! way the launcher dock wears one at the end of its strip. `Props.pin`
//! is null for a bar that never hides, which is the shipped default, so
//! the default chrome row is cell for cell what it was.
//!
//! Props only: the words, which one is open, the toggles' states, the
//! workspace name. Every element registers the `.button` the caller
//! names in the same statement it is painted. The hidden-word rule is
//! Rust's: a conservative 50-cell cluster estimate bounds the words, a
//! 3-cell slot is kept for the ` » ` while words remain.

const std = @import("std");
const vaxis = @import("vaxis");
const utf8 = @import("../core/utf8.zig");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const pin_chip = @import("pin_chip.zig");

const Style = vaxis.Style;

/// nf-md-magnify — the search glyph the Rust chrome uses everywhere.
pub const search_glyph = "\u{F0349}";
pub const search_ascii = "?";
/// codicon layout-sidebar-left-off / -right-off: the sidebar toggles.
pub const sidebar_glyph = "\u{EC02}";
pub const sidebar_ascii = "|";
pub const right_panel_glyph = "\u{EC00}";
pub const right_panel_ascii = "|";
/// codicon arrow-left / arrow-right.
pub const back_glyph = "\u{EA9B}";
pub const back_ascii = "<";
pub const forward_glyph = "\u{EA9C}";
pub const forward_ascii = ">";
/// codicon chevron-down (`EAA1` renders as chevron-up in Nerd Fonts).
pub const dropdown_glyph = "\u{EAB4}";
pub const dropdown_ascii = "v";
pub const overflow_chip = " » ";

/// The workspace name is padded / cut to this many code points so the
/// chip is one width whatever the name.
pub const chip_label_w: usize = 24;
/// `  󰍉  ` + the label + `  `.
pub const chip_w: u16 = 2 + 1 + 2 + chip_label_w + 2;
/// Sidebar 2 · gap · back 3 · fwd 3 · gap · chip · dropdown 3 · gap · right 3.
pub const cluster_w: u16 = 2 + 1 + 3 + 3 + 1 + chip_w + 3 + 1 + 3;
/// The words stop before this estimate of the cluster's left edge.
const conservative_cluster_w: u16 = 50;
const overflow_reserve: u16 = 3;
/// The pin chip's slot, kept back from the words the way the ` » `'s
/// is so the two never contend for the same cells.
const pin_reserve: u16 = pin_chip.width;
const nav_gap: u16 = 1;

pub const Ids = struct {
    /// Word `i` registers `word_base + i`.
    word_base: u32,
    overflow: u32,
    sidebar: u32,
    back: u32,
    forward: u32,
    chip: u32,
    dropdown: u32,
    right_panel: u32,
    /// The pin chip past the words (`view.menu_bar_pin`).
    pin: u32 = 0,
};

pub const Props = struct {
    /// The words, the brand first; empty when the bar hides them.
    labels: []const []const u8 = &.{},
    /// The open menu's index: its word inverts, every accelerator
    /// letter underlines.
    open: ?usize = null,
    workspace: []const u8,
    tree_open: bool = false,
    right_open: bool = false,
    /// Lit arrows: there is another buffer to go to.
    nav_enabled: bool = false,
    /// The pin chip's state, or null for no chip at all — which is
    /// what an `ui.menu_bar = .always` bar passes, since a bar that
    /// never hides has nothing to pin (`app/menu_bar.zig:pinShown`).
    pin: ?bool = null,
};

pub const Layout = struct {
    /// Just past the right-panel toggle — where the gap starts; null
    /// when the row was too narrow for more than the chip.
    palette_right_edge: ?u16 = null,
    /// The first word that did not fit, if any.
    first_hidden: ?usize = null,
    /// Where the words ended: past the ` » `, or the last word.
    words_end: u16 = 0,
    /// Each word's x, null when hidden (`labels.len` entries, arena).
    word_x: []const ?u16 = &.{},
    /// Where the pin chip landed; empty when none was asked for or the
    /// row had no cells left for it.
    pin: Rect = Rect.empty,
};

/// // changed (edge-grip): the run the WORDS take — the left of the
/// row, up to the nav cluster's safe left edge. The row's own centre
/// belongs to the workspace chip, which never hides, so a bar that can
/// hide itself wears its grip at the middle of THIS run instead: the
/// cells it is actually summoning.
pub fn wordsRun(area: Rect) Rect {
    if (area.isEmpty()) return .empty;
    return Rect.init(area.x, area.y, (area.w -| conservative_cluster_w) / 2, 1);
}

pub fn draw(ui: Ui, area: Rect, p: Props, ids: Ids) Layout {
    const th = ui.theme;
    const pal = th.palette;
    const bg = pal.bg_dark;
    ui.fill(area, Theme.onBg(th.fg, bg));
    if (area.isEmpty()) return .{};
    var out: Layout = .{};
    out.word_x = drawWords(ui, area, p, ids, &out);
    drawNav(ui, area, p, ids, &out);
    return out;
}

/// The words: ` label ` each, stopped before the cluster's safe left
/// edge (a 3-cell slot kept for the ` » ` while words remain), then
/// the ` » ` when one was skipped.
fn drawWords(ui: Ui, area: Rect, p: Props, ids: Ids, out: *Layout) []const ?u16 {
    const th = ui.theme;
    const pal = th.palette;
    const bg = pal.bg_dark;
    const xs = ui.arena.alloc(?u16, p.labels.len) catch return &.{};
    @memset(xs, null);
    const cluster_left_safe = area.x + (area.w -| conservative_cluster_w) / 2;
    // The pin's cells are taken off both ceilings before the first
    // word, so a word never lands where the chip is going.
    const pin_slot: u16 = if (p.pin == null) 0 else pin_reserve;
    var mx = area.x;
    const any_open = p.open != null;
    for (p.labels, 0..) |label, i| {
        const label_w = ui.width(label) + 2;
        const need_slot = i + 1 < p.labels.len;
        const reserve = pin_slot + @as(u16, if (need_slot) overflow_reserve else 0);
        const area_end = area.right() -| reserve;
        const bound = cluster_left_safe -| reserve;
        if (mx + label_w > area_end or mx + label_w > bound) {
            out.first_hidden = i;
            break;
        }
        const r = Rect.init(mx, area.y, label_w, 1);
        const is_open = p.open != null and p.open.? == i;
        const hot = !is_open and ui.hovered(r);
        const style: Style = if (is_open) .{ .fg = bg, .bg = pal.cyan, .bold = true } else if (hot) .{ .fg = pal.fg, .bg = bg, .bold = true } else .{ .fg = pal.grey, .bg = bg };
        ui.fill(r, style);
        // The brand is the first word whose leading char is not a letter:
        // its mark and wordmark paint bold, and it has no accelerator to
        // underline. The others underline their first letter while any
        // menu is open — the Alt+<letter> to reach them.
        const brand = label.len > 0 and !std.ascii.isAlphabetic(label[0]) and label[0] != ' ';
        var cx = mx + 1;
        var underlined = false;
        var it = utf8.graphemeIterator(label);
        while (it.next()) |g| {
            const bytes = g.bytes(label);
            var cs = style;
            if (brand and !(bytes.len == 1 and bytes[0] == ' ')) cs.bold = true;
            if (any_open and !brand and !underlined and bytes.len == 1 and std.ascii.isAlphabetic(bytes[0])) {
                cs.ul_style = .single;
                underlined = true;
            }
            cx += ui.putStr(cx, area.y, r.right() -| cx, bytes, cs);
        }
        ui.hit(r, .{ .button = ids.word_base + @as(u32, @intCast(i)) });
        xs[i] = mx;
        mx += label_w;
    }
    out.words_end = mx;
    if (out.first_hidden != null and mx + overflow_reserve <= area.right()) {
        const r = Rect.init(mx, area.y, overflow_reserve, 1);
        _ = ui.putStr(mx, area.y, overflow_reserve, overflow_chip, .{ .fg = pal.cyan, .bg = bg });
        ui.hit(r, .{ .button = ids.overflow });
        out.words_end = mx + overflow_reserve;
    }
    // The pin sits past the last word — past the ` » ` when there is
    // one — at the right end of the bar's own run, where the dock's
    // pin sits at the end of its strip. `words_end` is left where it
    // was: a menu dropped for a hidden word still lands beside the
    // ` » ` it was reached through, not under the chip.
    if (p.pin) |pinned| {
        const px = out.words_end;
        if (px + pin_reserve <= area.right()) {
            const r = Rect.init(px, area.y, pin_reserve, 1);
            pin_chip.draw(ui, r, .{ .pinned = pinned, .bg = bg, .hit = .{ .button = ids.pin } });
            out.pin = r;
        }
    }
    return xs;
}

/// The workspace chip's text: `  󰍉  <name>  `, the name cut to 23 code
/// points plus `…` or padded to 24. Returns the text and the visible
/// name's width (the chip's hit stops after it).
fn chipText(ui: Ui, workspace: []const u8) struct { text: []const u8, visible: u16 } {
    const magnify: []const u8 = if (ui.ascii) search_ascii else search_glyph;
    const n = std.unicode.utf8CountCodepoints(workspace) catch workspace.len;
    var label: []const u8 = workspace;
    var visible: u16 = @intCast(@min(n, chip_label_w));
    var pad: usize = 0;
    if (n > chip_label_w) {
        var end: usize = 0;
        var seen: usize = 0;
        var it = std.unicode.Utf8View.initUnchecked(workspace).iterator();
        while (it.nextCodepointSlice()) |cp| {
            if (seen == chip_label_w - 1) break;
            end += cp.len;
            seen += 1;
        }
        label = ui.fmt("{s}…", .{workspace[0..end]});
        visible = chip_label_w;
    } else pad = chip_label_w - n;
    const fill: []u8 = ui.arena.alloc(u8, pad) catch &.{};
    @memset(fill, ' ');
    return .{ .text = ui.fmt("  {s}  {s}{s}  ", .{ magnify, label, fill }), .visible = visible };
}

/// The centred cluster; the chip alone, centred, when the row cannot
/// hold the 48 cells.
fn drawNav(ui: Ui, area: Rect, p: Props, ids: Ids, out: *Layout) void {
    const th = ui.theme;
    const pal = th.palette;
    const bg = pal.bg_dark;
    const y = area.y;
    const chip = chipText(ui, p.workspace);
    const chip_style: Style = .{ .fg = pal.comment, .bg = pal.bg2 };
    if (cluster_w > area.w) {
        const w = @min(chip_w, area.w);
        const x = area.x + (area.w - w) / 2;
        const r = Rect.init(x, y, w, 1);
        ui.fill(r, chip_style);
        _ = ui.putStr(x, y, w, chip.text, chip_style);
        ui.hit(r, .{ .button = ids.chip });
        return;
    }
    var x = area.x + (area.w - cluster_w) / 2;
    ui.fill(Rect.init(x, y, cluster_w, 1), Theme.onBg(th.fg, bg));
    // Sidebar toggle: ` ▮` — its right pad is dropped so it sits a cell
    // closer to the arrows.
    const sidebar = Rect.init(x, y, 2, 1);
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) sidebar_ascii else sidebar_glyph, .{ .fg = if (p.tree_open) pal.cyan else pal.comment, .bg = bg });
    ui.hit(sidebar, .{ .button = ids.sidebar });
    x += 2 + nav_gap;
    const nav_fg = if (p.nav_enabled) pal.fg else pal.comment;
    const back = Rect.init(x, y, 3, 1);
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) back_ascii else back_glyph, .{ .fg = nav_fg, .bg = bg });
    ui.hit(back, .{ .button = ids.back });
    x += 3;
    const fwd = Rect.init(x, y, 3, 1);
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) forward_ascii else forward_glyph, .{ .fg = nav_fg, .bg = bg });
    ui.hit(fwd, .{ .button = ids.forward });
    x += 3 + nav_gap;
    // The chip: the hit stops after the visible name, not the padding.
    ui.fill(Rect.init(x, y, chip_w, 1), chip_style);
    _ = ui.putStr(x, y, chip_w, chip.text, chip_style);
    ui.hit(Rect.init(x, y, @min(2 + 1 + 2 + chip.visible + 2, chip_w), 1), .{ .button = ids.chip });
    x += chip_w;
    const drop = Rect.init(x, y, 3, 1);
    ui.fill(drop, chip_style);
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) dropdown_ascii else dropdown_glyph, chip_style);
    ui.hit(drop, .{ .button = ids.dropdown });
    x += 3 + nav_gap;
    const right = Rect.init(x, y, 3, 1);
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) right_panel_ascii else right_panel_glyph, .{ .fg = if (p.right_open) pal.cyan else pal.comment, .bg = bg });
    ui.hit(right, .{ .button = ids.right_panel });
    out.palette_right_edge = x + 3;
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

const test_labels = [_][]const u8{ "❯_  mnml", "File", "Edit", "Selection", "View", "Go", "Run", "Terminal", "Window", "Help" };
const test_ids: Ids = .{ .word_base = 100, .overflow = 200, .sidebar = 1, .back = 2, .forward = 3, .chip = 4, .dropdown = 5, .right_panel = 6 };

const spaces = " " ** 32;
/// Row 0 of `docs/ui-spec/rust-120x40.txt` up to the gap (the browser
/// chip and the right cluster are the caller's), and of the 80×24 dump.
const nav_cells = sidebar_glyph ++ "  " ++ back_glyph ++ "  " ++ forward_glyph ++ "    " ++ search_glyph ++ "  ws" ++ spaces[0..25] ++ dropdown_glyph ++ "   " ++ right_panel_glyph;
pub const rust_row_120: []const u8 = " \u{276F}_  mnml  File  Edit  \u{BB}" ++ spaces[0..13] ++ nav_cells;
pub const rust_row_80: []const u8 = " \u{276F}_  mnml  \u{BB}" ++ spaces[0..5] ++ nav_cells;

test "120 columns: the Rust row — brand, File, Edit, », the cluster centred at 36, every element a hit" {
    var f = try Fixture.init(120, 1);
    defer f.deinit();
    const l = draw(f.ui(), f.full(), .{ .labels = &test_labels, .workspace = "ws" }, test_ids);
    try f.expectRow(0, rust_row_120);
    try testing.expectEqual(@as(?usize, 3), l.first_hidden);
    try testing.expectEqual(@as(u16, 25), l.words_end);
    try testing.expectEqual(@as(?u16, 84), l.palette_right_edge);
    try testing.expectEqual(@as(?u16, 0), l.word_x[0]);
    try testing.expectEqual(@as(?u16, 10), l.word_x[1]);
    try testing.expectEqual(@as(?u16, 16), l.word_x[2]);
    try testing.expect(l.word_x[3] == null);
    try testing.expectEqual(@as(u32, 100), f.hits.at(1, 0).?.button);
    try testing.expectEqual(@as(u32, 101), f.hits.at(12, 0).?.button);
    try testing.expectEqual(@as(u32, 102), f.hits.at(20, 0).?.button);
    try testing.expectEqual(@as(u32, 200), f.hits.at(23, 0).?.button);
    try testing.expect(f.hits.at(30, 0) == null);
    try testing.expectEqual(@as(u32, 1), f.hits.at(37, 0).?.button);
    try testing.expectEqual(@as(u32, 2), f.hits.at(40, 0).?.button);
    try testing.expectEqual(@as(u32, 3), f.hits.at(43, 0).?.button);
    try testing.expectEqual(@as(u32, 4), f.hits.at(48, 0).?.button);
    try testing.expectEqual(@as(u32, 4), f.hits.at(54, 0).?.button);
    // The chip's hit stops after the name; the padding is inert.
    try testing.expect(f.hits.at(60, 0) == null);
    try testing.expectEqual(@as(u32, 5), f.hits.at(78, 0).?.button);
    try testing.expectEqual(@as(u32, 6), f.hits.at(82, 0).?.button);
    try testing.expect(f.hits.at(84, 0) == null);
    // The chip sits on the raised ground; the words on the bar's.
    try testing.expect(f.bgEql(50, 0, .{ .bg = f.theme.palette.bg2 }));
    try testing.expect(f.bgEql(12, 0, .{ .bg = f.theme.palette.bg_dark }));
}

test "80 columns: only the brand fits before the »; the cluster centres at 16" {
    var f = try Fixture.init(80, 1);
    defer f.deinit();
    const l = draw(f.ui(), f.full(), .{ .labels = &test_labels, .workspace = "ws", .tree_open = true }, test_ids);
    try f.expectRow(0, rust_row_80);
    try testing.expectEqual(@as(?usize, 1), l.first_hidden);
    try testing.expectEqual(@as(?u16, 64), l.palette_right_edge);
    try testing.expectEqual(@as(u32, 200), f.hits.at(11, 0).?.button);
    try testing.expectEqual(@as(u32, 1), f.hits.at(17, 0).?.button);
    try testing.expect(f.fgEql(17, 0, .{ .fg = f.theme.palette.cyan }));
}

test "the open word inverts and the accelerators underline; a long name is cut with …; too narrow leaves the chip alone" {
    var f = try Fixture.init(120, 1);
    defer f.deinit();
    _ = draw(f.ui(), f.full(), .{ .labels = &test_labels, .open = 1, .workspace = "a-very-long-workspace-name-indeed" }, test_ids);
    try testing.expect(f.bgEql(12, 0, .{ .bg = f.theme.palette.cyan }));
    try testing.expect(f.style(11, 0).ul_style == .single); // F of File
    try testing.expect(f.style(17, 0).ul_style == .single); // E of Edit
    try testing.expect(f.style(1, 0).ul_style != .single); // the brand has none
    try testing.expect(f.style(1, 0).bold);
    try f.expectContains("a-very-long-workspace-n…");
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const l = draw(g.ui(), g.full(), .{ .labels = &test_labels, .workspace = "ws" }, test_ids);
    try testing.expect(l.palette_right_edge == null);
    try g.expectContains("\u{F0349}  ws");
    try testing.expectEqual(@as(u32, 4), g.hits.at(20, 0).?.button);
    try g.expectLacks("\u{EA9B}");
    // Hidden words: nothing at the left, no ».
    var h = try Fixture.init(120, 1);
    defer h.deinit();
    _ = draw(h.ui(), h.full(), .{ .workspace = "ws" }, test_ids);
    try h.expectLacks("mnml");
    try h.expectLacks("»");
    // ASCII twins.
    var a = try Fixture.init(120, 1);
    defer a.deinit();
    a.ascii = true;
    _ = draw(a.ui(), a.full(), .{ .labels = &test_labels, .workspace = "ws" }, test_ids);
    try a.expectContains("|  <  >    ?  ws");
}

test "the pin chip: past the words under a bar that can hide, absent under one that cannot, and the words give up its cells" {
    var f = try Fixture.init(120, 1);
    defer f.deinit();
    // No pin asked for: the Rust row, untouched.
    const none = draw(f.ui(), f.full(), .{ .labels = &test_labels, .workspace = "ws" }, test_ids);
    try f.expectRow(0, rust_row_120);
    try testing.expect(none.pin.isEmpty());
    try f.expectLacks(pin_chip.pin_glyph);

    // Pinned-capable: the chip lands at `words_end`, three cells wide,
    // and is a hit over all three.
    var g = try Fixture.init(120, 1);
    defer g.deinit();
    const l = draw(g.ui(), g.full(), .{ .labels = &test_labels, .workspace = "ws", .pin = false }, test_ids);
    try testing.expectEqual(l.words_end, l.pin.x);
    try testing.expectEqual(pin_chip.width, l.pin.w);
    try g.expectContains(pin_chip.pin_glyph);
    try testing.expectEqual(test_ids.pin, g.hits.at(l.pin.x, 0).?.button);
    try testing.expectEqual(test_ids.pin, g.hits.at(l.pin.x + 2, 0).?.button);
    // The chip never reaches the centred cluster: the words gave up
    // its cells before the first of them was painted.
    try testing.expect(l.pin.right() <= 120 / 2 - cluster_w / 2 + 1);

    // Pinned: the same cells, the lit glyph.
    var h = try Fixture.init(120, 1);
    defer h.deinit();
    const lit = draw(h.ui(), h.full(), .{ .labels = &test_labels, .workspace = "ws", .pin = true }, test_ids);
    try testing.expect(lit.pin.eql(l.pin));
    try testing.expect(!vaxis.Color.eql(g.style(l.pin.x + 1, 0).fg, h.style(l.pin.x + 1, 0).fg));

    // A bar whose words are down still has no chip — there is nothing
    // for it to sit at the end of.
    var k = try Fixture.init(120, 1);
    defer k.deinit();
    const bare = draw(k.ui(), k.full(), .{ .workspace = "ws", .pin = false }, test_ids);
    try testing.expectEqual(@as(u16, 0), bare.pin.x);
    try k.expectLacks("mnml");
    // With no words the chip sits at the row's start, which is where
    // the words would have ended.
    try testing.expectEqual(pin_chip.width, bare.pin.w);
}

test "the pin chip's --ascii twin, and a row with no cells to spare drops it rather than clipping it" {
    var f = try Fixture.init(120, 1);
    defer f.deinit();
    f.ascii = true;
    _ = draw(f.ui(), f.full(), .{ .labels = &test_labels, .workspace = "ws", .pin = false }, test_ids);
    try f.expectContains(pin_chip.pin_ascii);
    try f.expectLacks(pin_chip.pin_glyph);
    // Two cells wide: no room for anything, and nothing half-painted.
    var g = try Fixture.init(2, 1);
    defer g.deinit();
    const l = draw(g.ui(), g.full(), .{ .labels = &test_labels, .workspace = "ws", .pin = false }, test_ids);
    try testing.expect(l.pin.isEmpty());
    try g.expectLacks(pin_chip.pin_glyph);
}
