//! Bufferline — one row of tabs on `theme.bufferline`. Each tab is
//! ` title ` (plus `● ` when dirty, in `theme.tab_dirty`), the active one
//! in `theme.tab_active`, the rest in `theme.tab_inactive`, one cell of
//! strip between them. Every painted tab registers a `.tab{leaf, idx}`
//! hit in the same statement as its paint; the `+` after the last tab
//! registers the `.button` the caller names.
//!
//! // changed: the strip is per leaf (a tab drags between leaves), so
//! `draw` takes `Opts{ leaf, new_tab }` — the leaf index the hits carry
//! and the id of the `+` button, if wanted.
//!
//! Tabs that do not fit are not painted at all: a half tab is a dead
//! click target. The strip is a window: `Opts.first` is the first
//! painted position (the caller keeps it per leaf and re-fits it with
//! `fitActive` when the active tab changes); hidden tabs on either side
//! show as `‹` / `›` markers that register the caller's scroll buttons,
//! and the `+` keeps its place after the `›`, never pushed off.
//!
//! Pty tabs form the session strip: they are painted after the file
//! tabs behind a `│` divider, as ` label$ × ` — the `$` marks a
//! terminal, the `×` registers a `.tab_close` hit on top of the tab's
//! own so one click closes a session. The hits carry the leaf's tab
//! index, not the painted position, so the app never re-derives the
//! order.

const std = @import("std");
const vaxis = @import("vaxis");
const Rect = @import("rect.zig");
const Ui = @import("context.zig");
const Theme = @import("theme.zig");
const ids = @import("../core/ids.zig");

const Style = vaxis.Style;

pub const PaneId = ids.PaneId;

pub const Kind = enum { file, pty };

pub const Tab = struct {
    id: PaneId,
    title: []const u8,
    dirty: bool,
    active: bool,
    kind: Kind = .file,
    /// Paints the pin glyph before the title.
    pinned: bool = false,
};

/// The pin glyph (nf-fa-thumb_tack) and its ASCII twin, one cell each.
pub const pin_glyph = "\u{f08d}";
pub const pin_ascii = "^";

pub const Opts = struct {
    /// What the `.tab` hits carry as their leaf.
    leaf: u32 = 0,
    /// Paint ` + ` after the last tab and register it as this `.button`.
    new_tab: ?u32 = null,
    /// The first painted position (visual order); null fits the window
    /// to the active tab. Clamped so the strip never shows fewer tabs
    /// than it could.
    first: ?usize = null,
    /// The `.button` ids the `‹` / `›` markers register, when wanted.
    scroll_left: ?u32 = null,
    scroll_right: ?u32 = null,
};

/// What `draw` painted: the window it settled on and how many tabs
/// sit outside it on each side.
pub const Window = struct { first: usize = 0, hidden_left: usize = 0, hidden_right: usize = 0 };

/// The width of the `+` chip.
pub const plus_w: u16 = 3;
/// The width of a `‹ ` / ` ›` marker.
pub const marker_w: u16 = 2;

/// The tab positions a caller needs to route a drop: the `x` each tab
/// starts at and its width, in strip order from `first`.
pub const Slot = struct { idx: usize, x: u16, w: u16 };

/// ` title ` plus ` ●` when dirty; a pty tab is ` title$ × `.
fn tabWidth(ui: Ui, tab: Tab) u16 {
    const base = 2 + ui.width(tab.title) + @as(u16, if (tab.dirty) 2 else 0) + @as(u16, if (tab.pinned) 2 else 0);
    return if (tab.kind == .pty) base + 1 + close_w else base;
}

/// The ` ×` cells of a pty tab.
const close_w: u16 = 2;

fn countKind(tabs: []const Tab, kind: Kind) usize {
    var n: usize = 0;
    for (tabs) |tab| n += @intFromBool(tab.kind == kind);
    return n;
}

/// The tab at painted position `pos`: the file tabs in order, then
/// the pty tabs in order.
fn atVisual(tabs: []const Tab, pos: usize) usize {
    const files = countKind(tabs, .file);
    const want: Kind = if (pos < files) .file else .pty;
    var skip = if (pos < files) pos else pos - files;
    for (tabs, 0..) |tab, i| {
        if (tab.kind != want) continue;
        if (skip == 0) return i;
        skip -= 1;
    }
    unreachable;
}

pub fn draw(ui: Ui, area: Rect, tabs: []const Tab, opts: Opts) Window {
    const t = ui.theme;
    ui.fill(area, t.bufferline);
    if (area.isEmpty()) return .{};
    const y = area.y;
    const plus: u16 = if (opts.new_tab != null) plus_w else 0;
    // The window: never past the first position from which the rest fits.
    const want = opts.first orelse fitActive(ui, area, tabs, plus);
    const first = @min(want, maxFirst(ui, area, tabs, plus));
    var strip = area;
    if (first > 0) {
        // `‹ `: tabs are hidden on the left.
        const lr = Rect.init(area.x, y, marker_w, 1);
        _ = ui.putStr(lr.x, y, marker_w, if (ui.ascii) "< " else "‹ ", Theme.onBg(t.accent, t.bufferline.bg));
        if (opts.scroll_left) |id| ui.hit(lr, .{ .button = id });
        strip = Rect.init(area.x + marker_w, y, area.w -| marker_w, 1);
    }
    // Does the rest fit beside the `+`? If not, reserve the `›` too.
    const fit_all = countFit(ui, strip.w -| plus, tabs, first) == tabs.len - first;
    const reserve: u16 = plus + (if (fit_all) 0 else marker_w);
    const paint_w = strip.w -| reserve;
    var res = drawTabs(ui, Rect.init(strip.x, y, paint_w, 1), tabs, first, opts.leaf, null);
    // A strip too narrow to fit one tab beside the markers still shows
    // the first windowed tab (clipped): the active tab is never hidden
    // behind a marker it left no room for.
    if (res.painted == 0 and tabs.len > first)
        res = drawTabs(ui, Rect.init(strip.x, y, strip.w, 1), tabs, first, opts.leaf, null);
    var x = res.end;
    const hidden_right = tabs.len - first - res.painted;
    if (hidden_right > 0 and x + marker_w <= area.right()) {
        const rr = Rect.init(x, y, marker_w, 1);
        _ = ui.putStr(rr.x, y, marker_w, if (ui.ascii) " >" else " ›", Theme.onBg(t.accent, t.bufferline.bg));
        if (opts.scroll_right) |id| ui.hit(rr, .{ .button = id });
        x += marker_w + 1;
    }
    if (opts.new_tab) |id| {
        if (x + plus_w <= area.right()) {
            const r = Rect.init(x, y, plus_w, 1);
            _ = ui.putStr(x, y, plus_w, if (ui.ascii) " " ++ plus_ascii ++ " " else " " ++ plus_glyph ++ " ", Theme.onBg(t.muted, t.bufferline.bg));
            ui.hit(r, .{ .button = id });
        }
    }
    return .{ .first = first, .hidden_left = first, .hidden_right = hidden_right };
}

/// nf-md-plus — the `+` of the strip and of the chrome row's right
/// cluster (Rust paints both with it); nf-md-close is their `×`.
pub const plus_glyph = "\u{F0415}";
pub const plus_ascii = "+";
pub const close_glyph = "\u{F0156}";
pub const close_ascii = "x";

// ─── the chrome row's right cluster ─────────────────────────────────────
//
// Rust's `paint_right_cluster`: ` + ` (a new tab page), then in the
// full mode ` TABS ` and a chip per tab page (`●` when it holds a dirty
// buffer, ` × ` after the active one), a one-cell spacer, the theme
// pill `●━ ` (`━●` on the alternate theme) and the ` × ` that quits.
// The compact mode drops the label and shows the page chips only from
// the second page on. `pickCluster` is Rust's fit rule: the full
// cluster when it clears the workspace chip by `cluster_gap`, else the
// compact one, else nothing.

pub const Cluster = struct {
    /// Tab pages, and which one is showing.
    pages: u16 = 1,
    active: u16 = 0,
    /// Per page, whether a buffer in it is unsaved; a short slice reads false.
    dirty: []const bool = &.{},
    /// The theme pill's state: on the configured alternate theme.
    on_alt: bool = false,
    compact: bool = false,
};

pub const ClusterIds = struct {
    new_tab: u32,
    tabs_label: u32,
    /// Page `i` registers `page_base + i`; its `×` `page_close_base + i`.
    page_base: u32,
    page_close_base: u32,
    theme: u32,
    close: u32,
};

pub const ClusterPref = enum { auto, expanded, compact };
pub const ClusterFit = struct { w: u16, compact: bool };

/// The cells between the workspace chip's right edge and the cluster.
pub const cluster_gap: u16 = 4;

fn digits(n: usize) u16 {
    var d: u16 = 1;
    var v = n;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

/// The cluster's width in cells for `c` (its `compact` decides which).
pub fn clusterWidth(c: Cluster) u16 {
    var w: u16 = 3; // ` + `
    const chips = !c.compact or c.pages >= 2;
    if (!c.compact) w += 6; // ` TABS `
    if (chips) {
        var i: usize = 0;
        while (i < c.pages) : (i += 1) {
            w += 2 + digits(i + 1); // `{marker}{n} `
            if (i == c.active) w += 2; // `× `
        }
    }
    return w + 1 + 3 + 3; // spacer, `●━ `, ` × `
}

/// Which cluster fits at the right of `area` past `palette_right_edge`:
/// the full one, the compact one, or none. `expanded` still falls back
/// to compact when the full one will not fit; `compact` never tries the
/// full one.
pub fn pickCluster(area: Rect, palette_right_edge: u16, c: Cluster, pref: ClusterPref) ?ClusterFit {
    var full = c;
    full.compact = false;
    var compact = c;
    compact.compact = true;
    const full_w = clusterWidth(full);
    const compact_w = clusterWidth(compact);
    const full_fits = area.x + (area.w -| full_w) >= palette_right_edge + cluster_gap;
    const compact_fits = area.x + (area.w -| compact_w) >= palette_right_edge + cluster_gap;
    if (pref != .compact and full_fits) return .{ .w = full_w, .compact = false };
    if (compact_fits) return .{ .w = compact_w, .compact = true };
    return null;
}

/// Paints the cluster from `area.x` on `area.y`, registering each part.
pub fn drawCluster(ui: Ui, area: Rect, c: Cluster, id: ClusterIds) void {
    const t = ui.theme;
    const pal = t.palette;
    const y = area.y;
    var x = area.x;
    const chip_bg = pal.bg2;
    const plus = Rect.init(x, y, 3, 1);
    ui.fill(plus, .{ .fg = pal.fg, .bg = chip_bg });
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) plus_ascii else plus_glyph, .{ .fg = pal.fg, .bg = chip_bg });
    ui.hit(plus, .{ .button = id.new_tab });
    x += 3;
    const chips = !c.compact or c.pages >= 2;
    if (!c.compact) {
        const r = Rect.init(x, y, 6, 1);
        _ = ui.putStr(x, y, 6, " TABS ", .{ .fg = pal.bg_darker, .bg = pal.fg, .bold = true });
        ui.hit(r, .{ .button = id.tabs_label });
        x += 6;
    }
    if (chips) {
        var i: usize = 0;
        while (i < c.pages) : (i += 1) {
            const active = i == c.active;
            const dirty = i < c.dirty.len and c.dirty[i];
            const style: Style = if (active) .{ .fg = pal.bg_darker, .bg = pal.blue, .bold = true } else .{ .fg = pal.fg, .bg = chip_bg };
            const label = ui.fmt("{s}{d} ", .{ @as([]const u8, if (dirty) "\u{25CF}" else " "), i + 1 });
            const w = ui.width(label);
            const r = Rect.init(x, y, w, 1);
            ui.fill(r, style);
            _ = ui.putStr(x, y, w, label, style);
            ui.hit(r, .{ .button = id.page_base + @as(u32, @intCast(i)) });
            x += w;
            if (active) {
                const cr = Rect.init(x, y, 2, 1);
                ui.fill(cr, style);
                _ = ui.putStr(x, y, 1, if (ui.ascii) close_ascii else close_glyph, style);
                ui.hit(cr, .{ .button = id.page_close_base + @as(u32, @intCast(i)) });
                x += 2;
            }
        }
    }
    // The spacer paints in the chips' colour so it does not read as a
    // hole punched between two strips.
    ui.fill(Rect.init(x, y, 1, 1), .{ .bg = chip_bg });
    x += 1;
    const pill = Rect.init(x, y, 3, 1);
    ui.fill(pill, .{ .bg = chip_bg });
    const dot: Style = .{ .fg = pal.fg, .bg = chip_bg };
    const bar: Style = .{ .fg = pal.comment, .bg = chip_bg };
    if (c.on_alt) {
        _ = ui.putStr(x, y, 1, "\u{2501}", bar);
        _ = ui.putStr(x + 1, y, 1, "\u{25CF}", dot);
    } else {
        _ = ui.putStr(x, y, 1, "\u{25CF}", dot);
        _ = ui.putStr(x + 1, y, 1, "\u{2501}", bar);
    }
    ui.hit(pill, .{ .button = id.theme });
    x += 3;
    const close = Rect.init(x, y, 3, 1);
    const close_style: Style = .{ .fg = pal.bg_darker, .bg = pal.red, .bold = true };
    ui.fill(close, close_style);
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) close_ascii else close_glyph, close_style);
    ui.hit(close, .{ .button = id.close });
}

// ─── the strip's split buttons ──────────────────────────────────────────
//
// Rust's `paint_split_buttons`: at the strip's right end, the AI chips
// that are enabled, then ` $ ` (a shell in a split), `  ` (split
// right) and `  ` (split down). The three are never dropped; the AI
// chips go from the end when the strip is short of room.

pub const AiChip = struct { id: u32, glyph: []const u8, fallback: []const u8, live: bool };

pub const SplitIds = struct { term: u32, right: u32, down: u32, ai: []const AiChip = &.{} };

/// The three buttons, 3 cells each.
pub const split_buttons_w: u16 = 9;
/// codicon terminal / split-horizontal / split-vertical, with their
/// ASCII twins.
pub const term_glyph = "\u{EA85}";
pub const term_ascii = "$";
pub const split_right_glyph = "\u{EB56}";
pub const split_right_ascii = "|";
pub const split_down_glyph = "\u{EB57}";
pub const split_down_ascii = "-";

/// Paints the cluster at the right end of `area` and returns its width
/// (0 when the area cannot hold the three).
pub fn drawSplitButtons(ui: Ui, area: Rect, id: SplitIds) u16 {
    if (area.w < split_buttons_w) return 0;
    const t = ui.theme;
    const pal = t.palette;
    const y = area.y;
    var n_ai: usize = id.ai.len;
    while (n_ai > 0 and area.w < split_buttons_w + @as(u16, @intCast(n_ai)) * 3) n_ai -= 1;
    const total: u16 = split_buttons_w + @as(u16, @intCast(n_ai)) * 3;
    var x = area.right() - total;
    const bg = pal.bg_darker;
    for (id.ai[0..n_ai]) |chip| {
        const r = Rect.init(x, y, 3, 1);
        ui.fill(r, .{ .bg = bg });
        _ = ui.putStr(x + 1, y, 1, if (ui.ascii) chip.fallback else chip.glyph, if (chip.live) Theme.onBg(t.accent, bg) else Theme.onBg(t.muted, bg));
        ui.hit(r, .{ .button = chip.id });
        x += 3;
    }
    const term = Rect.init(x, y, 3, 1);
    ui.fill(term, .{ .bg = bg });
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) term_ascii else term_glyph, .{ .fg = pal.fg, .bg = bg });
    ui.hit(term, .{ .button = id.term });
    x += 3;
    const right = Rect.init(x, y, 3, 1);
    ui.fill(right, .{ .bg = bg });
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) split_right_ascii else split_right_glyph, .{ .fg = pal.comment, .bg = bg });
    ui.hit(right, .{ .button = id.right });
    x += 3;
    const down = Rect.init(x, y, 3, 1);
    ui.fill(down, .{ .bg = bg });
    _ = ui.putStr(x + 1, y, 1, if (ui.ascii) split_down_ascii else split_down_glyph, .{ .fg = pal.comment, .bg = bg });
    ui.hit(down, .{ .button = id.down });
    return total;
}

/// The first position from which the active tab is in view — the
/// window a change of active tab re-fits to. `area` is the whole
/// strip: the `+` and the markers a window needs are reserved here.
pub fn fitActive(ui: Ui, area: Rect, tabs: []const Tab, reserve: u16) usize {
    if (tabs.len == 0) return 0;
    var active: usize = 0;
    for (0..tabs.len) |pos| if (tabs[atVisual(tabs, pos)].active) {
        active = pos;
    };
    // Widen the window leftward from the active tab as far as the strip
    // holds, so the active tab is always the last one fully shown. A
    // window that starts past the first tab paints a `‹`; tabs after
    // the active one need the `›`.
    const right_marker: u16 = if (active + 1 < tabs.len) marker_w else 0;
    var first: usize = active;
    while (first > 0) {
        const cand = first - 1;
        const left_marker: u16 = if (cand > 0) marker_w else 0;
        const avail = area.w -| reserve -| right_marker -| left_marker;
        if (countFit(ui, avail, tabs, cand) < active - cand + 1) break;
        first = cand;
    }
    return first;
}

/// The smallest first position from which every remaining tab fits
/// beside `reserve` cells — a window past it hides tabs for nothing.
fn maxFirst(ui: Ui, area: Rect, tabs: []const Tab, reserve: u16) usize {
    var first: usize = 0;
    while (first + 1 < tabs.len) : (first += 1) {
        const w = area.w -| (if (first > 0) marker_w else 0) -| reserve;
        if (countFit(ui, w, tabs, first) == tabs.len - first) break;
    }
    return first;
}

/// How many tabs from `first` on paint whole in `width` cells.
fn countFit(ui: Ui, width: u16, tabs: []const Tab, first: usize) usize {
    const files = countKind(tabs, .file);
    const has_divider = files > 0 and files < tabs.len;
    var x: u16 = 0;
    var n: usize = 0;
    var pos = first;
    while (pos < tabs.len) : (pos += 1) {
        if (has_divider and pos == files and pos > first) {
            if (x + 2 > width) break;
            x += 2;
        }
        const w = tabWidth(ui, tabs[atVisual(tabs, pos)]);
        if (x + w > width) break;
        x += w + 1;
        n += 1;
    }
    return n;
}

/// Where each tab would sit for `area` — the drop router asks this to
/// place a dragged tab between two others without repainting.
pub fn slots(ui: Ui, area: Rect, tabs: []const Tab, out: []Slot) []Slot {
    return slotsFrom(ui, area, tabs, fitActive(ui, area, tabs, 0), out);
}

/// `slots` from a given window — the one the strip painted.
pub fn slotsFrom(ui: Ui, area: Rect, tabs: []const Tab, first: usize, out: []Slot) []Slot {
    var n: usize = 0;
    _ = drawTabs(ui, area, tabs, first, 0, .{ .out = out, .n = &n });
    return out[0..n];
}

const SlotSink = struct { out: []Slot, n: *usize };

const TabsResult = struct { end: u16, painted: usize };

/// Paints (or, with a sink, only measures) the tabs from `first`.
/// Returns the x just past the last painted tab (plus a cell of
/// strip) and how many were painted.
fn drawTabs(ui: Ui, area: Rect, tabs: []const Tab, first: usize, leaf: u32, sink: ?SlotSink) TabsResult {
    const t = ui.theme;
    const y = area.y;
    if (tabs.len == 0) return .{ .end = area.x, .painted = 0 };
    const files = countKind(tabs, .file);
    const has_divider = files > 0 and files < tabs.len;

    var x = area.x;
    var painted: usize = 0;
    var pos = first;
    while (pos < tabs.len) : (pos += 1) {
        if (has_divider and pos == files and pos > first) {
            // The strip divider sits in the gap after the last file tab.
            if (x + 2 > area.right()) break;
            if (sink == null) _ = ui.putStr(x, y, 1, if (ui.ascii) "|" else "│", Theme.onBg(t.muted, t.bufferline.bg));
            x += 2;
        }
        const i = atVisual(tabs, pos);
        const tab = tabs[i];
        const w = tabWidth(ui, tab);
        if (x + w > area.right()) break;
        painted += 1;
        if (sink) |sk| {
            if (sk.n.* < sk.out.len) {
                sk.out[sk.n.*] = .{ .idx = i, .x = x, .w = w };
                sk.n.* += 1;
            }
            x += w + 1;
            continue;
        }
        const style = if (tab.active) t.tab_active else t.tab_inactive;
        const r = Rect.init(x, y, w, 1);
        ui.fill(r, style);
        var tx = x + 1;
        if (tab.pinned) tx += ui.putStr(tx, y, 2, if (ui.ascii) pin_ascii ++ " " else pin_glyph ++ " ", Theme.onBg(t.tab_dirty, style.bg));
        tx += ui.putStr(tx, y, w - (tx - x), tab.title, style);
        if (tab.kind == .pty) tx += ui.putStr(tx, y, 1, "$", Theme.onBg(t.muted, style.bg));
        if (tab.dirty) tx += ui.putStr(tx, y, 2, " ●", Theme.onBg(t.tab_dirty, style.bg));
        ui.hit(r, .{ .tab = .{ .leaf = leaf, .idx = @intCast(i) } });
        if (tab.kind == .pty) {
            const cr = Rect.init(tx, y, close_w, 1);
            const hot = ui.hovered(cr);
            _ = ui.putStr(tx, y, close_w, if (ui.ascii) " x" else " ×", Theme.onBg(if (hot) t.error_fg else t.muted, style.bg));
            ui.hit(cr, .{ .tab_close = .{ .leaf = leaf, .idx = @intCast(i) } });
        }
        x += w + 1;
    }
    return .{ .end = x, .painted = painted };
}

// ── tests ──

const testing = std.testing;
const Fixture = @import("test_fixture.zig");

fn hasButton(f: *Fixture, id: u32) bool {
    for (f.hits.items.items) |h| if (h.target == .button and h.target.button == id) return true;
    return false;
}

fn hasTab(f: *Fixture, idx: u16) bool {
    for (f.hits.items.items) |h| if (h.target == .tab and h.target.tab.idx == idx) return true;
    return false;
}

test "an overflowing strip shows ‹ › markers with their buttons and keeps the + reachable; the window is clamped" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "one.txt", .dirty = false, .active = false },
        .{ .id = 2, .title = "two.txt", .dirty = false, .active = false },
        .{ .id = 3, .title = "three.txt", .dirty = false, .active = false },
        .{ .id = 4, .title = "four.txt", .dirty = false, .active = false },
        .{ .id = 5, .title = "five.txt", .dirty = false, .active = true },
    };
    // From the start: the ones that fit, then › and the +.
    const w0 = draw(f.ui(), f.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .first = 0 });
    try f.expectRow(0, " one.txt   two.txt   three.txt   ›  \u{F0415}");
    try testing.expectEqual(@as(usize, 0), w0.first);
    try testing.expectEqual(@as(usize, 2), w0.hidden_right);
    try testing.expect(hasButton(&f, 71)); // the › marker's scroll button
    try testing.expect(hasButton(&f, 77)); // the + is still reachable
    // The active tab is last: fitActive windows to it, ‹ marks the hidden ones.
    const first = fitActive(f.ui(), f.full(), &tabs, plus_w);
    try testing.expectEqual(@as(usize, 2), first);
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const w1 = draw(g.ui(), g.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71, .first = first });
    try g.expectRow(0, "‹  three.txt   four.txt   five.txt   \u{F0415}");
    try testing.expectEqual(@as(usize, 2), w1.hidden_left);
    try testing.expectEqual(@as(usize, 0), w1.hidden_right);
    try testing.expectEqual(@as(u32, 70), g.hits.at(0, 0).?.button); // the ‹ marker
    try testing.expect(hasButton(&g, 77)); // + still there
    try testing.expect(hasTab(&g, 4)); // five.txt (idx 4) visible
    // A window past the point where the rest fits is pulled back.
    var h = try Fixture.init(40, 1);
    defer h.deinit();
    const w2 = draw(h.ui(), h.full(), &tabs, .{ .new_tab = 77, .first = 4 });
    try testing.expectEqual(@as(usize, 2), w2.first);
    // Everything fits: no markers at all.
    var k = try Fixture.init(80, 1);
    defer k.deinit();
    const w3 = draw(k.ui(), k.full(), &tabs, .{ .new_tab = 77, .scroll_left = 70, .scroll_right = 71 });
    try testing.expectEqual(@as(usize, 0), w3.hidden_right);
    try k.expectLacks("›");
    try k.expectLacks("‹");
}

test "tabs paint in order with the active style and a dirty dot, and register hits" {
    var f = try Fixture.init(40, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "a.txt", .dirty = false, .active = false },
        .{ .id = 2, .title = "b.txt", .dirty = true, .active = true },
        .{ .id = 3, .title = "c.txt", .dirty = false, .active = false },
    };
    _ = draw(f.ui(), f.full(), &tabs, .{ .leaf = 3, .new_tab = 77 });
    try f.expectRow(0, " a.txt   b.txt ●   c.txt   \u{F0415}");
    try testing.expectEqual(@as(u32, 3), f.hits.at(3, 0).?.tab.leaf);
    try testing.expectEqual(@as(u32, 77), f.hits.at(26, 0).?.button);
    var slot_buf: [8]Slot = undefined;
    const sl = slots(f.ui(), f.full(), &tabs, &slot_buf);
    try testing.expectEqual(@as(usize, 3), sl.len);
    try testing.expectEqual(@as(u16, 8), sl[1].x);
    try testing.expectEqual(@as(u16, 9), sl[1].w);
    try testing.expect(f.bgEql(1, 0, f.theme.tab_inactive));
    try testing.expect(f.bgEql(9, 0, f.theme.tab_active));
    try testing.expect(f.style(9, 0).bold);
    try testing.expect(f.fgEql(15, 0, f.theme.tab_dirty));
    try testing.expectEqual(@as(u16, 0), f.hits.at(3, 0).?.tab.idx);
    try testing.expectEqual(@as(u16, 1), f.hits.at(15, 0).?.tab.idx);
    try testing.expectEqual(@as(u16, 2), f.hits.at(20, 0).?.tab.idx);
    // The gap between tabs is strip, not a tab.
    try testing.expect(f.hits.at(7, 0) == null);
    try testing.expect(f.bgEql(7, 0, f.theme.bufferline));
}

test "a tab that does not fit is dropped whole; the active tab is always shown" {
    var f = try Fixture.init(12, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = false },
        .{ .id = 2, .title = "beta", .dirty = false, .active = false },
        .{ .id = 3, .title = "gamma", .dirty = false, .active = true },
    };
    _ = draw(f.ui(), f.full(), &tabs, .{});
    // The active tab is last, so the window starts past the first: `‹`.
    try f.expectRow(0, "‹  gamma");
    try testing.expectEqual(@as(u16, 2), f.hits.at(2, 0).?.tab.idx);
    try testing.expect(f.hits.at(9, 0) == null);

    var g = try Fixture.init(14, 1);
    defer g.deinit();
    const two = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = true },
        .{ .id = 2, .title = "beta", .dirty = false, .active = false },
    };
    _ = draw(g.ui(), g.full(), &two, .{});
    try g.expectRow(0, " alpha   beta");
    _ = draw(g.ui(), Rect.empty, &two, .{});
    _ = draw(g.ui(), g.full(), &.{}, .{ .new_tab = 1 });
    try g.expectRow(0, " \u{F0415}");
}

test "pty tabs cluster after the files behind a divider, carry `$` and a close hit that keeps the leaf index" {
    var f = try Fixture.init(48, 1);
    defer f.deinit();
    const tabs = [_]Tab{
        .{ .id = 5, .title = "zsh", .dirty = false, .active = false, .kind = .pty },
        .{ .id = 1, .title = "a.txt", .dirty = false, .active = true },
        .{ .id = 2, .title = "b.txt", .dirty = false, .active = false },
    };
    _ = draw(f.ui(), f.full(), &tabs, .{ .leaf = 1, .new_tab = 9 });
    try f.expectRow(0, " a.txt   b.txt  │  zsh$ ×   \u{F0415}");
    // The file tabs keep their leaf indices; the pty tab is index 0.
    try testing.expectEqual(@as(u16, 1), f.hits.at(2, 0).?.tab.idx);
    try testing.expectEqual(@as(u16, 2), f.hits.at(10, 0).?.tab.idx);
    try testing.expectEqual(@as(u16, 0), f.hits.at(20, 0).?.tab.idx);
    // The `×` wins over the tab beneath it.
    const close = f.hits.at(24, 0).?;
    try testing.expect(close == .tab_close);
    try testing.expectEqual(@as(u16, 0), close.tab_close.idx);
    try testing.expectEqual(@as(u32, 1), close.tab_close.leaf);
    try testing.expectEqual(@as(u32, 9), f.hits.at(27, 0).?.button);
    // The divider is strip, not a tab.
    try testing.expect(f.hits.at(16, 0) == null);
    // Slots follow the painted order but name the leaf index.
    var slot_buf: [8]Slot = undefined;
    const sl = slots(f.ui(), f.full(), &tabs, &slot_buf);
    try testing.expectEqual(@as(usize, 3), sl.len);
    try testing.expectEqual(@as(usize, 1), sl[0].idx);
    try testing.expectEqual(@as(usize, 0), sl[2].idx);
    try testing.expectEqual(@as(u16, 18), sl[2].x);
    // ASCII: `x` for the close, `|` for the divider.
    f.ascii = true;
    _ = draw(f.ui(), f.full(), &tabs, .{});
    try f.expectRow(0, " a.txt   b.txt  |  zsh$ x");
    // An active pty on a narrow strip is still brought into view.
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    const two = [_]Tab{
        .{ .id = 1, .title = "alpha", .dirty = false, .active = false },
        .{ .id = 5, .title = "sh", .dirty = false, .active = true, .kind = .pty },
    };
    _ = draw(g.ui(), g.full(), &two, .{});
    try g.expectRow(0, "‹  sh$ ×");
    try testing.expect(hasTab(&g, 1)); // the active pty tab (idx 1) shows
}

const cluster_ids: ClusterIds = .{ .new_tab = 10, .tabs_label = 11, .page_base = 0x40, .page_close_base = 0x60, .theme = 12, .close = 13 };

test "the right cluster: compact is Rust's `+ ●━ ×` on one page, full adds TABS and the page chips; widths match the paint; every part is a hit" {
    var f = try Fixture.init(20, 1);
    defer f.deinit();
    const one: Cluster = .{ .compact = true };
    try testing.expectEqual(@as(u16, 10), clusterWidth(one));
    drawCluster(f.ui(), Rect.init(10, 0, 10, 1), one, cluster_ids);
    try f.expectRow(0, "           \u{F0415}  ●━  \u{F0156}");
    try testing.expectEqual(@as(u32, 10), f.hits.at(11, 0).?.button);
    try testing.expectEqual(@as(u32, 12), f.hits.at(15, 0).?.button);
    try testing.expectEqual(@as(u32, 13), f.hits.at(18, 0).?.button);
    try testing.expect(f.bgEql(18, 0, .{ .bg = f.theme.palette.red }));
    // Full, two pages, the second active and dirty.
    var g = try Fixture.init(40, 1);
    defer g.deinit();
    const two: Cluster = .{ .pages = 2, .active = 1, .dirty = &.{ false, true }, .on_alt = true };
    const w = clusterWidth(two);
    try testing.expectEqual(@as(u16, 3 + 6 + 3 + 3 + 2 + 1 + 3 + 3), w);
    drawCluster(g.ui(), Rect.init(0, 0, w, 1), two, cluster_ids);
    try g.expectRow(0, " \u{F0415}  TABS  1 ●2 \u{F0156}  ━●  \u{F0156}");
    try testing.expectEqual(@as(u32, 11), g.hits.at(5, 0).?.button);
    try testing.expectEqual(@as(u32, 0x40), g.hits.at(10, 0).?.button);
    try testing.expectEqual(@as(u32, 0x41), g.hits.at(13, 0).?.button);
    try testing.expectEqual(@as(u32, 0x61), g.hits.at(15, 0).?.button);
    try testing.expect(g.bgEql(13, 0, .{ .bg = g.theme.palette.blue }));
    // Compact with two pages keeps the chips, drops the label.
    var c = two;
    c.compact = true;
    try testing.expectEqual(w - 6, clusterWidth(c));
    // The fit rule: full when it clears the chip by 4, else compact, else none.
    const bar = Rect.init(0, 0, 120, 1);
    try testing.expectEqual(ClusterFit{ .w = 21, .compact = false }, pickCluster(bar, 84, .{}, .auto).?);
    try testing.expectEqual(ClusterFit{ .w = 10, .compact = true }, pickCluster(bar, 84, .{}, .compact).?);
    try testing.expectEqual(ClusterFit{ .w = 10, .compact = true }, pickCluster(Rect.init(0, 0, 80, 1), 64, .{}, .auto).?);
    try testing.expect(pickCluster(Rect.init(0, 0, 76, 1), 64, .{}, .expanded) == null);
}

test "the split buttons sit at the strip's right end; AI chips go first when there is no room for them" {
    var f = try Fixture.init(30, 1);
    defer f.deinit();
    const ai = [_]AiChip{ .{ .id = 4, .glyph = "\u{2733}", .fallback = "*", .live = true }, .{ .id = 5, .glyph = "\u{276F}", .fallback = ">", .live = false } };
    try testing.expectEqual(@as(u16, 15), drawSplitButtons(f.ui(), f.full(), .{ .term = 1, .right = 2, .down = 3, .ai = &ai }));
    try f.expectRow(0, "                ✳  ❯  \u{EA85}  \u{EB56}  \u{EB57}");
    try testing.expectEqual(@as(u32, 4), f.hits.at(16, 0).?.button);
    try testing.expectEqual(@as(u32, 1), f.hits.at(22, 0).?.button);
    try testing.expectEqual(@as(u32, 2), f.hits.at(25, 0).?.button);
    try testing.expectEqual(@as(u32, 3), f.hits.at(28, 0).?.button);
    var g = try Fixture.init(12, 1);
    defer g.deinit();
    try testing.expectEqual(@as(u16, 12), drawSplitButtons(g.ui(), g.full(), .{ .term = 1, .right = 2, .down = 3, .ai = &ai }));
    try g.expectRow(0, " ✳  \u{EA85}  \u{EB56}  \u{EB57}");
    var h = try Fixture.init(8, 1);
    defer h.deinit();
    try testing.expectEqual(@as(u16, 0), drawSplitButtons(h.ui(), h.full(), .{ .term = 1, .right = 2, .down = 3 }));
    h.ascii = true;
    var k = try Fixture.init(9, 1);
    defer k.deinit();
    k.ascii = true;
    _ = drawSplitButtons(k.ui(), k.full(), .{ .term = 1, .right = 2, .down = 3 });
    try k.expectRow(0, " $  |  -");
}
