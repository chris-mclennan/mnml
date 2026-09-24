//! `ui.sidebar = .auto` — the side column that hides itself and slides
//! back in over the editor when the pointer asks for it.
//!
//! **It draws over; it never re-lays-out.** `render.chrome` reports no
//! column while the overlay is up, so `frameRects` hands the whole body
//! to the split tree: every pane keeps the rect it had docked, and no
//! pty is resized. The panel is then painted on top, after the panes
//! and the dock, and registers its hits there — `HitMap.at` scans back
//! to front, so the overlay wins every cell it covers. Resizing instead
//! would reflow every split and re-size every terminal each time the
//! pointer brushed the screen edge, which is the reason this shape was
//! chosen over a docking one.
//!
//! The reveal is a dwell, arbitrated with the menu bar and the rail by
//! `hover_zones.zig`: the pointer rests in the column's one-cell screen
//! edge (or, once it is up, anywhere on the panel) for
//! `ui.sidebar_reveal_ms`. A keyboard command that targets the column
//! reveals it too — that is the only door under `ui.sidebar = .hidden`,
//! where hover is off.
//!
//! The hide is the mirror: `ui.sidebar_hide_ms` after the pointer
//! leaves. It is refused outright while something in the panel is being
//! used — a filter being typed into, an open context menu, a drag in
//! flight, or the keyboard itself being in the panel — because each of
//! those is the user's hand on it. A click that OPENS something (a file,
//! a pane, a session) hides it at once instead of waiting: the pointer
//! is about to be somewhere else. A fold arrow is not an open, and
//! neither is a right-click, so neither hides it.
//!
//! `view.sidebar_pin` ends the game: the panel docks like any other
//! column and `ui.sidebar` reads `.always` for the rest of the session
//! (nothing is persisted — unpinning is meant to be one keystroke, not
//! an edit to the config file).

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = @import("../config/Config.zig");
const Rect = @import("../ui/rect.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const hover_zones = @import("hover_zones.zig");
const side_mod = @import("side.zig");

pub const ColumnSide = Config.ColumnSide;

pub const table = .{
    .@"view.sidebar_pin" = &pinCmd,
    .@"view.sidebar_mode_always" = &modeAlwaysCmd,
    .@"view.sidebar_mode_auto" = &modeAutoCmd,
    .@"view.sidebar_mode_hidden" = &modeHiddenCmd,
};

/// The slide: three frames, each a third of the width. `ui.animations
/// = false`, `--headless` and the `.test` harness skip it — the panel
/// is at its full width on the frame it appears.
pub const slide_frames: u8 = 3;
/// A frame per this many ms while the panel slides (~20 fps, the rate
/// the spinners already wake the loop at).
pub const slide_frame_ms: i64 = 50;

pub const State = struct {
    /// The column the overlay is carrying; null when nothing is up.
    open: ?ColumnSide = null,
    /// Slide frames painted so far: `slide_frames` is full width.
    step: u8 = slide_frames,
    /// When the next slide frame is due.
    step_at_ms: i64 = 0,
    /// The overlay's rect at the last paint. The hide test reads it
    /// through `hover_zones` (the painter registers it as the zone).
    rect: Rect = .empty,
    /// Pinned for this session: the column docks and `mode` reads
    /// `.always`. Never written to the config.
    pinned: bool = false,
    /// A keyboard command opened it, so it is allowed under `.hidden`
    /// and does not start its hide clock until the pointer has been
    /// on it at least once — a panel summoned from the keyboard must
    /// not vanish because the mouse was nudged on the way to reading
    /// it. A key puts it away (`afterKey`, or the toggle again).
    by_key: bool = false,
    /// The pointer has been on the overlay since it opened.
    touched: bool = false,
    /// The pointer left the overlay at this ms; null while it is on it
    /// (or while the panel is closed).
    left_at_ms: ?i64 = null,
};

/// `ui.sidebar`, with the session's pin on top of it.
pub fn mode(app: *const App) Config.Sidebar {
    if (app.sidebar_auto.pinned) return .always;
    return configured(app);
}

/// `ui.sidebar` as this terminal's width reads it, before the pin: a
/// docked column on a terminal narrower than `ui.sidebar_auto_below`
/// is an auto-hiding one — at 80 columns a docked tree takes a third
/// of the screen — and it docks again once the terminal is that wide.
/// Only `.always` bends; a user who asked for `.auto` or `.hidden`
/// already has what the rule would give them.
pub fn configured(app: *const App) Config.Sidebar {
    const m = app.cfg.ui.sidebar;
    if (m == .always and narrowAuto(app)) return .auto;
    return m;
}

/// Whether the width rule is what makes the column auto-hide this frame.
pub fn narrowAuto(app: *const App) bool {
    const below = app.cfg.ui.sidebar_auto_below;
    const w = app.screen.width;
    return below > 0 and w > 0 and w < below;
}

/// Whether the columns are under the auto-hide regime at all: `.auto`
/// / `.hidden`, or a screen narrower than `ui.auto_hide_narrow_width`,
/// which drops both columns from the frame just the same — so a command
/// that hands a column the keys reveals it over the editor here too,
/// instead of focusing a column nobody can see.
pub fn autoHiding(app: *const App) bool {
    if (app.zen) return false;
    return mode(app) != .always or @import("render.zig").narrowAutoHidden(app, app.screen.width);
}

/// Whether `s` is being carried by the overlay this frame — the one
/// question `render.chrome` asks, so the column is not carved.
pub fn overlaid(app: *const App, s: ColumnSide) bool {
    const st = app.sidebar_auto;
    return st.open != null and st.open.? == s;
}

/// Whether the column is off screen entirely this frame: auto-hiding
/// and not being carried by the overlay either. `render.chrome` never
/// carves an auto-hidden column — overlaid or not, that is the point —
/// so this is for the surfaces that ask "is the tree on screen" (a
/// toggle chip's lit state, the info view).
pub fn suppressed(app: *const App, s: ColumnSide) bool {
    return autoHiding(app) and !overlaid(app, s);
}

/// // changed (edge-grip): whether the `⋮` grip paints on `s`'s screen
/// edge. Only `.auto` wears one — `.hidden` registers no hover zone,
/// so a grip there would be a handle that does nothing — and only
/// while the column is down: revealed, the pin chip in its header
/// strip is the handle, and pinned there is nothing left to summon.
pub fn gripShown(app: *const App, s: ColumnSide) bool {
    return app.cfg.ui.edge_grips and configured(app) == .auto and
        !app.sidebar_auto.pinned and !overlaid(app, s) and !app.zen;
}

/// The zone id a column reveals through.
pub fn zoneOf(s: ColumnSide) hover_zones.Id {
    return switch (s) {
        .left => .sidebar_left,
        .right => .sidebar_right,
    };
}

fn sideOf(s: ColumnSide) Config.Side {
    return switch (s) {
        .left => .left,
        .right => .right,
    };
}

/// Why the overlay is refusing to hide itself. `.none` means nothing
/// is holding it.
pub const Sticky = enum {
    none,
    /// A filter input in the panel has the keys.
    filter,
    /// A context menu — the panel's own row menu, as a rule — is open.
    menu,
    /// A drag is in flight (a divider, a file onto a split).
    drag,
    /// The keyboard is in the panel.
    focus,
};

/// What is holding the overlay open, if anything.
pub fn sticky(app: *const App) Sticky {
    const st = app.sidebar_auto;
    const s = st.open orelse return .none;
    const section = side_mod.shown(app, sideOf(s)) orelse return .none;
    if (filterFocused(app, section)) return .filter;
    if (app.overlay == .menu) return .menu;
    if (app.drag != null) return .drag;
    if (side_mod.focusOf(section)) |f| if (std.meta.eql(app.focus, f)) return .focus;
    return .none;
}

/// Whether the section's own filter field has the keys. A focused
/// filter always implies a focused panel, so the `.focus` rule would
/// catch it anyway; it is named separately because it is the case a
/// reader comes looking for — a half-typed query must never vanish.
fn filterFocused(app: *const App, section: side_mod.Section) bool {
    return switch (section) {
        .todos => app.todos.list.filter_focused,
        .notes => app.notes.list.filter_focused,
        .findings => app.findings.list.filter_focused,
        .sessions => app.sessions.list.filter_focused,
        .http => app.http_panel.list.filter_focused,
        .search => app.search_section.list.filter_focused,
        .debug => app.debug_panel.list.filter_focused,
        else => false,
    };
}

// ─── the state machine ──────────────────────────────────────────────────

/// One tick of the reveal / hide clock. Called from `App.tick` before
/// the frame, and from `render` so a `.test` script that only renders
/// still advances.
pub fn tick(app: *App, now: i64) void {
    const st = &app.sidebar_auto;
    if (!autoHiding(app)) {
        // Pinned, or back to `always`: nothing is overlaid any more.
        if (st.open != null) {
            st.open = null;
            st.by_key = false;
            st.touched = false;
            st.rect = .empty;
            app.needs_render = true;
        }
        return;
    }
    if (st.open) |s| {
        // The slide.
        if (st.step < slide_frames and now >= st.step_at_ms) {
            st.step += 1;
            st.step_at_ms = now + slide_frame_ms;
            app.needs_render = true;
        }
        // The hide clock. `by_key` panels wait for the pointer to
        // arrive before they start counting: a keyboard reveal on a
        // machine whose pointer is parked in the editor must not
        // vanish a beat later.
        if (hover_zones.inZone(app, zoneOf(s))) {
            st.left_at_ms = null;
            st.touched = true;
            return;
        }
        if (sticky(app) != .none) {
            st.left_at_ms = null;
            return;
        }
        // Summoned from the keyboard and never visited: it waits for a
        // key, or for the pointer to come and go.
        if (st.by_key and !st.touched) return;
        const left = st.left_at_ms orelse blk: {
            st.left_at_ms = now;
            app.needs_render = true;
            break :blk now;
        };
        if (now -| left >= app.cfg.ui.sidebar_hide_ms) hide(app);
        return;
    }
    // Closed: the dwell in a column's edge zone is what opens it, and
    // only under `.auto` — `.hidden` opens by command alone.
    if (mode(app) != .auto) return;
    for ([_]ColumnSide{ .left, .right }) |s| {
        if (!hover_zones.dwelled(app, zoneOf(s))) continue;
        if (!ensureSection(app, s)) continue;
        reveal(app, s, false);
        return;
    }
}

/// Whether the column has a section to show, opening the one it showed
/// last when it has none. A column closed with `Ctrl+B` (or one the
/// `.test` harness starts closed) must still answer the screen edge —
/// the pointer is asking for the sidebar, not for whatever was on it.
/// `toggleColumn` reveals as it opens, which `reveal` below then
/// re-stamps as a pointer reveal rather than a keyboard one.
fn ensureSection(app: *App, s: ColumnSide) bool {
    const sd = sideOf(s);
    if (side_mod.shown(app, sd) != null) return true;
    side_mod.toggleColumn(app, sd) catch return false;
    return side_mod.shown(app, sd) != null;
}

/// Bring the column up as an overlay. `by_key`: a command asked, so it
/// is allowed under `.hidden` and waits for the pointer.
pub fn reveal(app: *App, s: ColumnSide, by_key: bool) void {
    const st = &app.sidebar_auto;
    st.open = s;
    st.by_key = by_key;
    st.touched = false;
    st.left_at_ms = null;
    st.step = if (animate(app)) 0 else slide_frames;
    st.step_at_ms = app.now_ms + slide_frame_ms;
    app.needs_render = true;
}

/// Put it away.
pub fn hide(app: *App) void {
    const st = &app.sidebar_auto;
    if (st.open == null) return;
    st.open = null;
    st.by_key = false;
    st.touched = false;
    st.left_at_ms = null;
    st.rect = .empty;
    app.needs_render = true;
}

/// The overlay hides at once when a click on it opened something —
/// `App.routeMouse` asks after every press / release that landed on the
/// panel. A fold arrow leaves the keys in the panel and changes no
/// pane, so it is not an open.
pub fn afterClick(app: *App, opened_pane: bool) void {
    const st = &app.sidebar_auto;
    if (st.open == null or !opened_pane) return;
    if (app.overlay == .menu) return;
    hide(app);
}

/// A keyboard command that targets a column: `.always` does nothing
/// (the column is docked), `.auto` / `.hidden` reveal or, when the
/// overlay is already carrying that column, put it away. Returns true
/// when the overlay handled it, so the caller can skip the docked
/// toggle. `toggle`: `view.toggle_tree`'s semantics (a second press
/// closes); a focus command never closes.
pub fn keyboardReach(app: *App, s: ColumnSide, toggle: bool) bool {
    if (!autoHiding(app)) return false;
    if (overlaid(app, s)) {
        if (toggle) hide(app);
        return true;
    }
    if (side_mod.shown(app, sideOf(s)) == null) return false;
    reveal(app, s, true);
    return true;
}

/// After a key: the keys were in the panel and are not any more (Esc,
/// `Ctrl-W l`, a focus command), so the overlay goes with them rather
/// than waiting out `sidebar_hide_ms` over an editor the user is
/// already typing in. `before` is the focus as the key arrived.
pub fn afterKey(app: *App, before: app_mod.FocusId) void {
    const s = app.sidebar_auto.open orelse return;
    const section = side_mod.shown(app, sideOf(s)) orelse return;
    const f = side_mod.focusOf(section) orelse return;
    if (!std.meta.eql(before, f)) return;
    if (std.meta.eql(app.focus, f)) return;
    if (app.overlay == .menu) return;
    hide(app);
}

/// The slide runs only when the frame budget is a human's: not under
/// `--headless`, not in the `.test` harness, and not when the user has
/// asked for no motion.
fn animate(app: *const App) bool {
    return app.cfg.ui.animations and app.live_frames;
}

/// The moment `tick` has something to do.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const st = &app.sidebar_auto;
    var next: ?i64 = null;
    if (st.open != null) {
        if (st.step < slide_frames) next = st.step_at_ms;
        if (st.left_at_ms) |l| {
            const due = l + app.cfg.ui.sidebar_hide_ms;
            next = @min(next orelse std.math.maxInt(i64), due);
        }
    }
    return next;
}

// ─── the commands ───────────────────────────────────────────────────────

fn pinCmd(app: *App) CommandError!void {
    return togglePin(app);
}

pub fn togglePin(app: *App) CommandError!void {
    const st = &app.sidebar_auto;
    if (st.pinned) {
        st.pinned = false;
        if (app.cfg.ui.sidebar == .always and narrowAuto(app)) {
            app.toast("sidebar: auto-hide on (narrower than ui.sidebar_auto_below = {d})", .{app.cfg.ui.sidebar_auto_below});
        } else {
            app.toast("sidebar: auto-hide on (ui.sidebar = .{s})", .{@tagName(configured(app))});
        }
        app.needs_render = true;
        return;
    }
    if (configured(app) == .always) {
        return app.diag.fail(app.frame.allocator(), "the sidebar is already docked (ui.sidebar = .always)", .{});
    }
    // Pinning docks whatever is up; with nothing up it docks the side
    // the configured home column is on, so the chord works from the
    // keyboard too.
    st.pinned = true;
    st.open = null;
    st.by_key = false;
    st.touched = false;
    st.rect = .empty;
    if (side_mod.shown(app, .left) == null and side_mod.shown(app, .right) == null) {
        side_mod.place(app, .explorer, false);
    }
    app.toast("sidebar pinned — docked for this session", .{});
    app.needs_render = true;
}

/// // changed (edge-grip): the grip's click — reveal this side and pin
/// it in one gesture. `view.sidebar_pin` docks whatever is up and,
/// with nothing up, the side the configured home column is on; the
/// grip is asking for ITS side, so the section is opened there first
/// and the ordinary pin then docks it. No new command id.
pub fn gripPin(app: *App, s: ColumnSide) CommandError!void {
    if (!app.sidebar_auto.pinned) _ = ensureSection(app, s);
    return togglePin(app);
}

fn setMode(app: *App, m: Config.Sidebar) CommandError!void {
    app.sidebar_auto.pinned = false;
    app.cfg.ui.sidebar = m;
    if (m == .always) hide(app);
    _ = try @import("settings.zig").persist(app, .home, &.{ "ui", "sidebar" }, m);
    app.toast("sidebar: {s}", .{@tagName(m)});
    app.needs_render = true;
}

fn modeAlwaysCmd(app: *App) CommandError!void {
    return setMode(app, .always);
}
fn modeAutoCmd(app: *App) CommandError!void {
    return setMode(app, .auto);
}
fn modeHiddenCmd(app: *App) CommandError!void {
    return setMode(app, .hidden);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const render = @import("render.zig");
const Rect_ = Rect;

/// `ui.sidebar = .auto` with the explorer in its column, a pane open
/// and the keys in that pane — the state a user is in when they reach
/// for the screen edge. The panel starts down: `place(…, false)` never
/// reveals (only `focusSection` does), which is what keeps a `.auto`
/// launch from opening with the sidebar up.
fn autoApp(app: *App) !void {
    app.cfg.ui.sidebar = .auto;
    app.cfg.ui.sidebar_reveal_ms = 250;
    app.cfg.ui.sidebar_hide_ms = 400;
    side_mod.place(app, .explorer, false);
    _ = try app.openScratch();
    try t.expect(app.sidebar_auto.open == null);
}

/// Put the pointer at `(x, y)` and run one frame's worth of the clock.
fn point(app: *App, x: ?u16, y: u16, now: i64) !void {
    app.now_ms = now;
    app.hover = if (x) |xx| .{ .x = xx, .y = y } else null;
    try app.render();
}

test "reveal: the pointer at the column's edge opens it after the dwell, and not before" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    try point(&app, 60, 10, 1000);
    try t.expect(app.sidebar_auto.open == null);
    // The edge, but not long enough.
    try point(&app, 0, 10, 1000);
    try t.expect(app.sidebar_auto.open == null);
    try point(&app, 0, 10, 1249);
    try t.expect(app.sidebar_auto.open == null);
    try point(&app, 0, 10, 1250);
    try t.expectEqual(ColumnSide.left, app.sidebar_auto.open.?);
    // Unit tests are not live frames: no slide, full width at once.
    try t.expectEqual(slide_frames, app.sidebar_auto.step);
}

test "hide: the pointer leaving the panel closes it after sidebar_hide_ms" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    try point(&app, 0, 10, 1000);
    try point(&app, 0, 10, 1250);
    try t.expect(app.sidebar_auto.open != null);
    // Resting on the panel itself keeps it: the painter registered its
    // rect as the same zone.
    try point(&app, 12, 10, 1400);
    try t.expect(app.sidebar_auto.open != null);
    // Away: the clock starts, and 400 ms later it is gone.
    try point(&app, 90, 10, 1500);
    try t.expect(app.sidebar_auto.open != null);
    try point(&app, 90, 10, 1899);
    try t.expect(app.sidebar_auto.open != null);
    try point(&app, 90, 10, 1900);
    try t.expect(app.sidebar_auto.open == null);
}

test "hide is refused while the panel is in use: a focused filter, an open menu, a drag, the keyboard" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    try side_mod.open(&app, .todos, false);
    try point(&app, 0, 10, 1000);
    try point(&app, 0, 10, 1250);
    try t.expect(app.sidebar_auto.open != null);
    // A half-typed filter outlives any pointer wandering.
    app.todos.list.filter_focused = true;
    app.focus = .{ .panel = .todos };
    try t.expectEqual(Sticky.filter, sticky(&app));
    try point(&app, 90, 10, 5000);
    try t.expect(app.sidebar_auto.open != null);
    app.todos.list.filter_focused = false;
    // The keyboard alone still holds it.
    try t.expectEqual(Sticky.focus, sticky(&app));
    try point(&app, 90, 10, 9000);
    try t.expect(app.sidebar_auto.open != null);
    app.focus = .{ .pane = 0 };
    // A drag in flight holds it (a divider being dragged out).
    app.drag = .tree_divider;
    try t.expectEqual(Sticky.drag, sticky(&app));
    try point(&app, 90, 10, 12000);
    try t.expect(app.sidebar_auto.open != null);
    app.drag = null;
    // Nothing holding it now.
    try t.expectEqual(Sticky.none, sticky(&app));
    try point(&app, 90, 10, 13000);
    try point(&app, 90, 10, 13500);
    try t.expect(app.sidebar_auto.open == null);
}

test "no relayout: every pane keeps the rect it had docked while the overlay is up" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    // Hidden: the panes have the whole body.
    try point(&app, 60, 10, 1000);
    const closed = app.panes_area;
    const closed_chrome = render.chrome(&app);
    try t.expect(closed_chrome.sidebar == null);
    try point(&app, 0, 10, 1000);
    try point(&app, 0, 10, 1250);
    try t.expect(app.sidebar_auto.open != null);
    // Revealed: identical. The panel is paint, not layout.
    try t.expect(app.panes_area.eql(closed));
    try t.expect(render.chrome(&app).sidebar == null);
    // Pinned: NOW the layout changes — that is what pinning is for.
    try togglePin(&app);
    try app.render();
    try t.expect(render.chrome(&app).sidebar != null);
    try t.expect(!app.panes_area.eql(closed));
}

test "pin: the column docks, ui.sidebar reads always for the session, and unpinning gives it back" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    try t.expectEqual(Config.Sidebar.auto, mode(&app));
    try togglePin(&app);
    try t.expect(app.sidebar_auto.pinned);
    try t.expectEqual(Config.Sidebar.always, mode(&app));
    try t.expect(!autoHiding(&app));
    // The config itself is untouched — a pin is a session, not an edit.
    try t.expectEqual(Config.Sidebar.auto, app.cfg.ui.sidebar);
    // The hover zone is gone with it.
    try point(&app, 0, 10, 3000);
    try t.expect(app.sidebar_auto.open == null);
    try togglePin(&app);
    try t.expect(!app.sidebar_auto.pinned);
    try t.expectEqual(Config.Sidebar.auto, mode(&app));
    // Docked already: pinning is refused rather than doing nothing quietly.
    app.cfg.ui.sidebar = .always;
    try t.expectError(error.Failed, togglePin(&app));
}

test "ui.sidebar = .hidden: hover does nothing, view.toggle_tree gives a one-shot overlay that toggles away" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    app.cfg.ui.sidebar = .hidden;
    try point(&app, 0, 10, 1000);
    try point(&app, 0, 10, 5000);
    try t.expect(app.sidebar_auto.open == null);
    try command.run(&app, .{ .static = .@"view.toggle_tree" });
    try t.expectEqual(ColumnSide.left, app.sidebar_auto.open.?);
    try t.expect(app.sidebar_auto.by_key);
    try command.run(&app, .{ .static = .@"view.toggle_tree" });
    try t.expect(app.sidebar_auto.open == null);
}

test "the overlay's geometry: full docked width, the rail and strip inside it, the edge rule on the inner side; the slide moves the origin, never the content" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    const upper = Rect_.init(0, 1, 120, 37);
    app.sidebar_auto.step = slide_frames;
    const left = render.overlayRects(&app, upper, .left);
    try t.expect(left.all.eql(Rect_.init(0, 1, 30, 37)));
    try t.expect(left.edge.eql(Rect_.init(29, 1, 1, 37)));
    try t.expect(left.rail.eql(Rect_.init(0, 1, 3, 37)));
    try t.expect(left.rail_border.eql(Rect_.init(3, 1, 1, 37)));
    try t.expect(left.strip.eql(Rect_.init(4, 1, 25, 1)));
    try t.expect(left.body.eql(Rect_.init(4, 2, 25, 36)));
    // Done sliding: the clip is the whole panel.
    try t.expect(left.clip.eql(left.all));
    // Mid-slide: the panel is laid out identically and revealed through
    // a narrower clip — every row inside it is where it will end up.
    app.sidebar_auto.step = 0;
    const sliding = render.overlayRects(&app, upper, .left);
    try t.expect(sliding.all.eql(left.all));
    try t.expect(sliding.strip.eql(left.strip));
    try t.expect(sliding.body.eql(left.body));
    try t.expectEqual(@as(u16, 10), sliding.clip.w);
    // The right column mirrors: the edge is on ITS inner side.
    app.sidebar_auto.step = slide_frames;
    const right = render.overlayRects(&app, upper, .right);
    try t.expect(right.all.eql(Rect_.init(88, 1, 32, 37)));
    try t.expect(right.edge.eql(Rect_.init(88, 1, 1, 37)));
    try t.expect(right.rail.isEmpty());
}

test "the overlay paints over the editor and swallows the press that no row claimed" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    try point(&app, 0, 10, 1000);
    // A cell the editor owns, inside where the panel will be — and one
    // that RESOLVES to the editor, since a gutter or a scrollbar
    // painted later wins the same rect.
    const c = blk: {
        for (app.hits.items.items) |h| {
            if (h.target != .editor_cell or h.rect.x >= 25) continue;
            const under = app.hits.at(h.rect.x, h.rect.y) orelse continue;
            if (under == .editor_cell) break :blk h.rect;
        }
        return error.SkipZigTest;
    };
    try point(&app, 0, 10, 1250);
    // Revealed: the same cell is the panel's now — a tree row, or the
    // panel's own ground where it painted none, which swallows the
    // press rather than letting it through to the editor underneath.
    const under = app.hits.at(c.x, c.y).?;
    try t.expect(under != .editor_cell);
    // …and the strip's pin chip is a click target.
    var found_pin = false;
    for (app.hits.items.items) |h| if (h.target == .button and h.target.button == @intFromEnum(render.Button.sidebar_pin)) {
        found_pin = true;
    };
    try t.expect(found_pin);
}

test "a click that opens a file hides the overlay at once; a fold arrow and a right-click do not" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "zzz_click_me.txt", .data = "hello\n" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &path_buf);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = path_buf[0..n], .data_root = path_buf[0..n], .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    try point(&app, 0, 10, 1000);
    try point(&app, 0, 10, 1250);
    try t.expect(app.sidebar_auto.open != null);

    // The tree row for the seeded file, by the hit its paint registered.
    var row: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .tree_node) {
        const idx = h.target.tree_node;
        if (idx < app.tree.rows.items.len and std.mem.indexOf(u8, app.tree.rows.items[idx].rel, "zzz_click_me") != null) row = h.rect;
    };
    const r = row orelse return error.SkipZigTest;

    // A right press opens the row's menu and must NOT put the panel
    // away — the menu is anchored to it.
    try app.handle(.{ .mouse = .{ .x = r.x + 4, .y = r.y, .kind = .press, .button = .right } });
    try app.handle(.{ .mouse = .{ .x = r.x + 4, .y = r.y, .kind = .release, .button = .right } });
    try t.expect(app.sidebar_auto.open != null);
    try t.expectEqual(Sticky.menu, sticky(&app));
    app.overlay.deinit(app.gpa);
    app.overlay = .none;

    // A left press on the row opens the file: the keys go to the pane,
    // and the panel goes with them — no waiting out `sidebar_hide_ms`.
    try app.handle(.{ .mouse = .{ .x = r.x + 4, .y = r.y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = r.x + 4, .y = r.y, .kind = .release, .button = .left } });
    try t.expect(app.focus == .pane);
    try t.expect(app.sidebar_auto.open == null);
}

test "a keyboard reveal waits for the pointer: a nudge of the mouse does not take it away, a key does" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try autoApp(&app);
    reveal(&app, .left, true);
    try t.expect(app.sidebar_auto.by_key);
    // The pointer is parked in the editor and never comes near: the
    // hide clock does not even start.
    try point(&app, 90, 20, 2000);
    try point(&app, 90, 20, 9000);
    try t.expect(app.sidebar_auto.open != null);
    // Once it HAS been on the panel, leaving works as ever.
    try point(&app, 10, 10, 9100);
    try t.expect(app.sidebar_auto.touched);
    try point(&app, 90, 20, 9200);
    try point(&app, 90, 20, 9700);
    try t.expect(app.sidebar_auto.open == null);
}

test "ui.sidebar_auto_below: a docked column auto-hides on a narrow terminal and docks again when it widens" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    side_mod.place(&app, .explorer, false);
    _ = try app.openScratch();
    try t.expectEqual(Config.Sidebar.always, app.cfg.ui.sidebar);
    try t.expectEqual(@as(u16, 100), app.cfg.ui.sidebar_auto_below);
    // 80 columns: the column is not carved, and the edge summons it.
    try point(&app, 40, 10, 1000);
    try t.expect(narrowAuto(&app));
    try t.expectEqual(Config.Sidebar.auto, mode(&app));
    try t.expect(render.chrome(&app).sidebar == null);
    try t.expect(gripShown(&app, .left));
    try point(&app, 0, 10, 1000);
    try point(&app, 0, 10, 1000 + app.cfg.ui.sidebar_reveal_ms);
    try t.expectEqual(ColumnSide.left, app.sidebar_auto.open.?);
    // The config is not written: the rule is a reading of the width.
    try t.expectEqual(Config.Sidebar.always, app.cfg.ui.sidebar);
    // Widened past the threshold: docked, the overlay put away.
    try app.resize(120, 40);
    try point(&app, 60, 10, 5000);
    try t.expect(!narrowAuto(&app));
    try t.expectEqual(Config.Sidebar.always, mode(&app));
    try t.expect(app.sidebar_auto.open == null);
    try t.expect(render.chrome(&app).sidebar != null);
    // Exactly the threshold is wide enough.
    try app.resize(100, 30);
    try point(&app, 50, 10, 6000);
    try t.expect(render.chrome(&app).sidebar != null);
    try app.resize(99, 30);
    try point(&app, 50, 10, 7000);
    try t.expect(render.chrome(&app).sidebar == null);
}

test "ui.sidebar_auto_below leaves an explicit auto or hidden alone, and 0 turns the rule off" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    side_mod.place(&app, .explorer, false);
    // `.hidden` stays hidden: no hover reveal on a narrow screen either.
    app.cfg.ui.sidebar = .hidden;
    try t.expectEqual(Config.Sidebar.hidden, mode(&app));
    try t.expect(!gripShown(&app, .left));
    // …and on a wide one it is still the user's word.
    try app.resize(160, 40);
    try t.expectEqual(Config.Sidebar.hidden, mode(&app));
    app.cfg.ui.sidebar = .auto;
    try t.expectEqual(Config.Sidebar.auto, mode(&app));
    // 0: a docked column is docked at any width.
    try app.resize(60, 20);
    app.cfg.ui.sidebar = .always;
    app.cfg.ui.sidebar_auto_below = 0;
    try t.expectEqual(Config.Sidebar.always, mode(&app));
    try app.render();
    try t.expect(render.chrome(&app).sidebar != null);
}

test "a narrow terminal's auto column pins like a configured one, and the pin outlives a widen and a narrow again" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    side_mod.place(&app, .explorer, false);
    try togglePin(&app);
    try t.expectEqual(Config.Sidebar.always, mode(&app));
    try app.render();
    try t.expect(render.chrome(&app).sidebar != null);
    try app.resize(140, 40);
    try t.expectEqual(Config.Sidebar.always, mode(&app));
    // Wide, the column is docked by the config: nothing to pin.
    try togglePin(&app);
    try t.expectError(error.Failed, togglePin(&app));
    try app.resize(80, 24);
    try t.expectEqual(Config.Sidebar.auto, mode(&app));
}

test "under ui.auto_hide_narrow_width, focusing the tree brings it up over the editor instead of focusing a column nobody can see" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    _ = try app.openScratch();
    side_mod.place(&app, .explorer, false);
    // Only the frame rule under test: `ui.sidebar_auto_below` (which
    // reads a narrow `.always` as `.auto`) is off, so without the fix
    // the column stays docked-but-dropped.
    app.cfg.ui.sidebar_auto_below = 0;
    app.cfg.ui.auto_hide_narrow_width = 100;
    try app.render();
    // Narrow: no column is carved, and nothing is overlaid yet.
    try t.expect(app.sidebar_auto.open == null);
    try t.expect(suppressed(&app, .left));
    try command.run(&app, .{ .static = .@"view.focus_tree" });
    try t.expect(app.focus == .tree);
    // The keys went to the tree — so the tree is on screen, over the editor.
    try t.expectEqual(@as(?ColumnSide, .left), app.sidebar_auto.open);
    try t.expect(!suppressed(&app, .left));
    try app.render();
    try t.expect(!app.sidebar_auto.rect.isEmpty());
    // Wide again: the column docks, the overlay is gone.
    try app.resize(120, 40);
    tick(&app, 100);
    try t.expect(app.sidebar_auto.open == null);
}
