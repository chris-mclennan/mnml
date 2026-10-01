//! Hover zones — the one place the chrome asks "has the pointer been
//! resting HERE long enough to reveal something?".
//!
//! Three surfaces want that question answered and, before this module,
//! each answered it for itself: the menu bar (`ui.menu_bar = .auto`)
//! against the bar's row, the activity bar (`ui.activity_bar = .auto`)
//! against column 0 and its own rect, and — the reason this module
//! exists — the side columns (`ui.sidebar = .auto`) against the same
//! column 0. Two of those claim the same cell, and a fourth is coming
//! (the dock's own edge), so the decision belongs in one dispatcher
//! rather than in three `shown()` functions that cannot see each other.
//!
//! A zone is `{ rect, id, dwell_ms, priority }`, registered per frame.
//! `winner` is the containing zone with the highest priority — the menu
//! bar outranks the columns, so the top-left cell summons the words and
//! not the sidebar — and `dwelled(id)` is true once the pointer has been
//! the winner's guest for that zone's `dwell_ms`. Zones with the same id
//! are one zone in two pieces (column 0 AND the rail it reveals): the
//! pointer moving between them never restarts the clock.
//!
//! Two lists, because of when the answers are needed. The geometric
//! zones — a screen edge, the bar's row — are computable from the screen
//! rect and the config, so `begin` registers them itself at the top of
//! the frame, before `frameRects` reads them. A zone only the painter
//! knows (the rail's rect, the revealed overlay's rect) is registered
//! during the paint into `next`, and `begin` swaps that in as the
//! frame's own — the same "read the previous frame's geometry" rule
//! `activity_bar.shown` already lived by.
//!
//! State lives in `App.hover_zones`; nothing here allocates.
//!
//! **The family rule for a hovered icon** (`ui/activity_bar.zig`, and
//! the dock when it lands): the row under the pointer sheds its `dim`,
//! takes the theme's full foreground — a coloured icon keeps its own
//! colour, which is its identity — and its whole cell row is filled one
//! step lighter (`palette.bg2`). The marked / active row is already at
//! full weight and is left exactly as it is, so a mark never moves
//! under the pointer, and nothing new is registered in the hit map: a
//! painter that can light a row already knows the row's rect, because
//! that is the rect it registered the click on.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = @import("../config/Config.zig");
const Rect = @import("../ui/rect.zig");

/// The surfaces that reveal on a dwell. One id may be registered as
/// several rects (see the header).
pub const Id = enum {
    /// The menu bar's row (`ui.menu_bar = .auto`).
    menu_bar_top,
    /// Column 0 and the rail's own rect (`ui.activity_bar = .auto`).
    rail_left,
    /// The left column's screen edge and, once revealed, the overlay.
    sidebar_left,
    /// The right column's, ditto.
    sidebar_right,
    /// // changed (launcher-dock): the launcher dock's edge — the
    /// outermost row or column of `ui.dock.edge`, and the strip itself
    /// once it is up (`app/launcher_dock.zig`).
    launcher_dock,
};

pub const Zone = struct {
    rect: Rect,
    id: Id,
    /// How long the pointer must rest before `dwelled` says yes.
    dwell_ms: u16 = 0,
    /// Higher wins the cells two zones share.
    priority: u8 = 0,
};

/// The menu bar owns the top-left cell; a column's edge outranks the
/// rail, which is carved out of that column in the first place.
/// // changed (launcher-dock): **the outer-band rule.** A launcher
/// dock on a side edge takes the OUTERMOST column of the frame and
/// nothing else does: it outranks every other zone on the cells it
/// claims, and `registerGeometric` moves the side column's own reveal
/// edge one cell inwards so both surfaces stay reachable rather than
/// one of them being unsummonable. The dock never claims the top row
/// (there is no `.top` edge), so the menu bar is never in contest.
pub const prio_dock: u8 = 4;
pub const prio_menu_bar: u8 = 3;
pub const prio_sidebar: u8 = 2;
pub const prio_rail: u8 = 1;

/// Five surfaces × two pieces each is the ceiling today; a zone past it
/// is dropped rather than growing the frame's state.
const max_zones = 16;

pub const State = struct {
    live: [max_zones]Zone = undefined,
    live_n: u8 = 0,
    /// What this frame's painters have registered for the next one.
    next: [max_zones]Zone = undefined,
    next_n: u8 = 0,
    /// The zone the pointer is the guest of, and since when.
    in: ?Id = null,
    since_ms: i64 = 0,
};

/// Start a frame: last frame's painter zones become this frame's, the
/// geometric ones are re-derived, and the dwell clock is advanced.
/// `full` is the whole screen.
pub fn begin(app: *App, full: Rect, now: i64) void {
    const s = &app.hover_zones;
    s.live = s.next;
    s.live_n = s.next_n;
    s.next_n = 0;
    registerGeometric(app, full);
    const w = winner(app);
    if (s.in == null or w == null or s.in.? != w.?) {
        s.in = w;
        s.since_ms = now;
    }
}

/// The zones that need no paint to know where they are: the bar's row
/// and each column's one-cell screen edge.
fn registerGeometric(app: *App, full: Rect) void {
    if (full.isEmpty()) return;
    const cfg = &app.cfg.ui;
    if (cfg.menu_bar == .auto) if (barRow(full)) |row| add(app, .{ .rect = row, .id = .menu_bar_top, .priority = prio_menu_bar });
    // The rail's reveal cell is column 0, whatever the row — the rule
    // `activity_bar.shown` shipped with.
    // // changed (sidebar-side-width): the rail lives in the sidebar's
    // column, so a sidebar moved right reveals its rail at that edge.
    const rail_x = if (cfg.sidebar_side == .left) full.x else full.right() -| 1;
    if (cfg.activity_bar == .auto) add(app, .{ .rect = Rect.init(rail_x, full.y, 1, full.h), .id = .rail_left, .priority = prio_rail });
    // // changed (launcher-dock): the dock's edge, and the outer-band
    // rule it imposes on a side column that wants the same screen edge.
    // // changed (edge-grip): a bottom strip reveals over the `:` line's
    // own row, so while a line is open the band is not registered AT
    // ALL rather than merely refused later — an un-registered zone
    // cannot be the pointer's guest, so the dwell clock is down for as
    // long as the line is, and closing the line asks for a fresh
    // `reveal_ms` instead of popping the strip up the same frame.
    // // changed (dock-shared): a strip that lives on the `:` line's
    // row has nothing to reveal, so its band is never watched.
    const ld = @import("launcher_dock.zig");
    const dock_band: ?Rect = if (ld.cmdlineBlocks(app) or ld.sharesCmdline(app)) null else dockBand(app, full);
    if (dock_band) |band| add(app, .{ .rect = band, .id = .launcher_dock, .dwell_ms = cfg.dock.reveal_ms, .priority = prio_dock });

    // The configured mode as the terminal's width reads it: a docked
    // column on a narrow screen is an auto one (`sidebar_auto.configured`).
    if (@import("sidebar_auto.zig").configured(app) == .auto and !app.zen) {
        const dwell = cfg.sidebar_reveal_ms;
        add(app, .{ .rect = sidebarEdge(app, full, .left), .id = .sidebar_left, .dwell_ms = dwell, .priority = prio_sidebar });
        add(app, .{ .rect = sidebarEdge(app, full, .right), .id = .sidebar_right, .dwell_ms = dwell, .priority = prio_sidebar });
    }
}

/// The one-cell edge a side column reveals through: the outermost
/// column of the area the column would itself occupy, which is also
/// where its grip goes — the grip names the zone's own cell and never
/// a second one (`ui/edge_grip.zig`).
///
/// // changed (side-band): that area is `frameRects(…).upper` — the
/// editor area, with the dock's band, the bottom panel, the palette
/// bar, the statusline and the `:` line all already taken off it — and
/// not the whole screen column it used to be. The band a surface
/// summons through belongs to that surface, so it can only be made of
/// cells no other surface owns, and the old rect was made of several:
/// its x ignored all but one cell of a side dock's three, so an
/// `always` dock and a hidden column shared an edge and the column's
/// grip painted over the dock's GLYPH column — blanking one dock icon
/// and replacing another with `⋮` over hits that still opened the
/// dock's items; and its height ran through the bottom panel and the
/// statusline, so with a panel open at 80×24 the right column's grip
/// landed on the panel's own header chip.
pub fn sidebarEdge(app: *const App, full: Rect, side: Config.ColumnSide) Rect {
    const upper = @import("render.zig").frameRects(full, @import("render.zig").chrome(app)).upper;
    if (upper.isEmpty()) return .empty;
    return switch (side) {
        .left => Rect.init(upper.x, upper.y, 1, upper.h),
        .right => Rect.init(upper.right() -| 1, upper.y, 1, upper.h),
    };
}

/// Which side a launcher dock has taken, or null when it has taken
/// neither (it is hidden, or it is on the bottom edge).
pub fn dockSide(app: *const App, full: Rect) ?Config.ColumnSide {
    if (dockBand(app, full) == null) return null;
    return switch (app.cfg.ui.dock.edge) {
        .bottom => null,
        .left => .left,
        .right => .right,
    };
}

/// The one-cell band the launcher dock reveals through, or null when
/// it is `hidden` (or zen, where no chrome shows).
///
/// // changed (edge-grip): the BOTTOM band is the row the strip
/// itself takes — under `.outer` the SCREEN's last row (the `:` line's
/// row while the strip is down, and the strip's own once it is up,
/// because an `always` dock is carved from that same row in
/// `render.frameRects`).
/// // changed (dock-grip-row): under `.inner` (the default) it is the
/// editor area's last row, above the statusline — where the strip
/// paints, carved or revealed. The items appear where the grip is,
/// never apart from it: a band on the screen's last row with the strip
/// two rows up sent the hand to one place and the items to another.
/// The grip marks the band, so nothing about it is unmarked. A side band is still the bare `upper`
/// `frameRects` would hand out with no columns and no dock at all —
/// never the top row, which is the menu bar's.
/// // changed (side-band): a SIDE band is the strip's own three
/// columns, not one of them — the band a surface owns and the band it
/// fills are the same band, so a reveal covers nothing that was not
/// already the dock's, the grip sits in its middle column, and the
/// zone the pointer dwells in is the whole strip rather than the one
/// column at its edge. It is `null` where `frameRects` would refuse to
/// carve it (`side_min_width`), so the zone, the grip and the carve
/// can never disagree about whether the dock is on this edge at all.
pub fn dockBand(app: *const App, full: Rect) ?Rect {
    if (app.zen or app.cfg.ui.dock.mode == .hidden or full.isEmpty()) return null;
    const render = @import("render.zig");
    const dock = @import("launcher_dock.zig");
    if (app.cfg.ui.dock.edge == .bottom) {
        if (full.h < render.dock_bottom_min_height) return null;
        // // changed (dock-grip-row): an `.inner` strip paints on the
        // editor area's last row, so that row is its band — the grip,
        // the dwell, the click and the strip are all one row.
        if (app.cfg.ui.dock.placement == .inner) return dock.innerRow(full);
        return Rect.init(full.x, full.bottom() -| 1, full.w, 1);
    }
    const upper = render.frameRects(full, .{}).upper;
    if (upper.isEmpty() or upper.w < dock.side_min_width) return null;
    return switch (app.cfg.ui.dock.edge) {
        .bottom => unreachable,
        .left => Rect.init(upper.x, upper.y, dock.width, upper.h),
        .right => Rect.init(upper.right() -| dock.width, upper.y, dock.width, upper.h),
    };
}

/// The row `render.frameRects` gives the palette bar, or null when the
/// screen is too small for one (its rule, kept in step by the test
/// below).
pub fn barRow(full: Rect) ?Rect {
    if (full.w < @import("render.zig").palette_bar_min_width or full.h < 5) return null;
    return Rect.init(full.x, full.y, full.w, 1);
}

fn add(app: *App, z: Zone) void {
    const s = &app.hover_zones;
    if (s.live_n == max_zones) return;
    s.live[s.live_n] = z;
    s.live_n += 1;
}

/// A painter's zone, for the NEXT frame — the rail's rect, the revealed
/// overlay's. Called in the statement that paints it, like a hit.
pub fn register(app: *App, z: Zone) void {
    const s = &app.hover_zones;
    if (s.next_n == max_zones or z.rect.isEmpty()) return;
    s.next[s.next_n] = z;
    s.next_n += 1;
}

/// The zone under the pointer, highest priority first. Null when the
/// pointer is off screen or in none of them.
pub fn winner(app: *const App) ?Id {
    const h = app.hover orelse return null;
    const s = &app.hover_zones;
    var best: ?Zone = null;
    for (s.live[0..s.live_n]) |z| {
        if (!z.rect.contains(h.x, h.y)) continue;
        if (best == null or z.priority > best.?.priority) best = z;
    }
    return if (best) |b| b.id else null;
}

/// The dwell a zone asks for — the largest of the pieces registered
/// under that id, so two pieces cannot disagree.
fn dwellOf(app: *const App, id: Id) u16 {
    const s = &app.hover_zones;
    var ms: u16 = 0;
    for (s.live[0..s.live_n]) |z| if (z.id == id) {
        ms = @max(ms, z.dwell_ms);
    };
    return ms;
}

/// Whether `id` has won the pointer and held it for its dwell.
pub fn dwelled(app: *const App, id: Id) bool {
    const s = &app.hover_zones;
    if (s.in == null or s.in.? != id) return false;
    return app.now_ms -| s.since_ms >= dwellOf(app, id);
}

/// Whether the pointer is in `id` at all, dwell or no dwell.
pub fn inZone(app: *const App, id: Id) bool {
    return app.hover_zones.in != null and app.hover_zones.in.? == id;
}

/// When the pointer entered whatever it is in, for a caller measuring
/// its own timeout off the same clock.
pub fn sinceMs(app: *const App) i64 {
    return app.hover_zones.since_ms;
}

/// A frame is due the moment an armed zone's dwell runs out.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    const s = &app.hover_zones;
    const id = s.in orelse return null;
    const ms = dwellOf(app, id);
    if (ms == 0) return null;
    const due = s.since_ms + ms;
    return if (due > app.now_ms) due else null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn zonedApp(app: *App, now: i64) void {
    begin(app, Rect.init(0, 0, 120, 40), now);
}

test "winner: the menu bar takes the top-left cell from both columns; the rail keeps column 0 below it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.menu_bar = .auto;
    app.cfg.ui.activity_bar = .auto;
    app.cfg.ui.sidebar = .auto;
    app.now_ms = 1000;
    app.hover = .{ .x = 0, .y = 0 };
    zonedApp(&app, 1000);
    try t.expectEqual(Id.menu_bar_top, winner(&app).?);
    // One row down, the column's edge outranks the rail.
    app.hover = .{ .x = 0, .y = 10 };
    zonedApp(&app, 1000);
    try t.expectEqual(Id.sidebar_left, winner(&app).?);
    // With the columns docked, column 0 is the rail's again.
    app.cfg.ui.sidebar = .always;
    zonedApp(&app, 1000);
    try t.expectEqual(Id.rail_left, winner(&app).?);
    // The far column is the right column's edge.
    app.cfg.ui.sidebar = .auto;
    app.hover = .{ .x = 119, .y = 10 };
    zonedApp(&app, 1000);
    try t.expectEqual(Id.sidebar_right, winner(&app).?);
    // Nowhere in particular.
    app.hover = .{ .x = 60, .y = 10 };
    zonedApp(&app, 1000);
    try t.expect(winner(&app) == null);
}

test "dwell: zero is instant, a reveal waits out its ms, and leaving restarts the clock" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.menu_bar = .auto;
    app.cfg.ui.sidebar = .auto;
    app.cfg.ui.sidebar_reveal_ms = 250;
    // The menu bar asks for no dwell: the first frame is enough.
    app.now_ms = 1000;
    app.hover = .{ .x = 20, .y = 0 };
    zonedApp(&app, 1000);
    try t.expect(dwelled(&app, .menu_bar_top));
    try t.expect(nextDeadlineMs(&app) == null);
    // The column asks for 250.
    app.hover = .{ .x = 0, .y = 10 };
    zonedApp(&app, 1000);
    try t.expect(inZone(&app, .sidebar_left));
    try t.expect(!dwelled(&app, .sidebar_left));
    try t.expectEqual(@as(i64, 1250), nextDeadlineMs(&app).?);
    app.now_ms = 1249;
    zonedApp(&app, 1249);
    try t.expect(!dwelled(&app, .sidebar_left));
    app.now_ms = 1250;
    zonedApp(&app, 1250);
    try t.expect(dwelled(&app, .sidebar_left));
    try t.expect(nextDeadlineMs(&app) == null);
    // Away and back: the clock starts over, it does not resume.
    app.hover = .{ .x = 60, .y = 10 };
    app.now_ms = 1300;
    zonedApp(&app, 1300);
    try t.expect(!dwelled(&app, .sidebar_left));
    app.hover = .{ .x = 0, .y = 10 };
    app.now_ms = 1400;
    zonedApp(&app, 1400);
    try t.expect(!dwelled(&app, .sidebar_left));
    app.now_ms = 1650;
    zonedApp(&app, 1650);
    try t.expect(dwelled(&app, .sidebar_left));
}

test "a painter's zone joins its id's other piece: moving from column 0 onto the rail does not restart the dwell" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.sidebar = .auto;
    app.cfg.ui.sidebar_reveal_ms = 100;
    app.now_ms = 500;
    app.hover = .{ .x = 0, .y = 10 };
    // Frame 1: the painter registers the revealed panel for frame 2.
    zonedApp(&app, 500);
    register(&app, .{ .rect = Rect.init(0, 1, 30, 37), .id = .sidebar_left, .dwell_ms = 100, .priority = prio_sidebar });
    app.now_ms = 600;
    zonedApp(&app, 600);
    try t.expect(dwelled(&app, .sidebar_left));
    // The pointer walks into the panel: same id, same clock. (A painter
    // registers its zone EVERY frame, like a hit.)
    register(&app, .{ .rect = Rect.init(0, 1, 30, 37), .id = .sidebar_left, .dwell_ms = 100, .priority = prio_sidebar });
    app.hover = .{ .x = 12, .y = 10 };
    app.now_ms = 610;
    zonedApp(&app, 610);
    try t.expectEqual(Id.sidebar_left, winner(&app).?);
    try t.expect(dwelled(&app, .sidebar_left));
    // The clock is still the one that started when the pointer first
    // reached column 0 — crossing from one piece of a zone to the
    // other is not leaving it.
    try t.expectEqual(@as(i64, 500), sinceMs(&app));
}

test "barRow agrees with frameRects about where the palette bar is" {
    const render = @import("render.zig");
    const wide = Rect.init(0, 0, 120, 40);
    try t.expect(barRow(wide).?.eql(render.frameRects(wide, .{}).bar));
    // Too narrow, and too short: no bar either way.
    const slim = Rect.init(0, 0, 39, 40);
    try t.expect(barRow(slim) == null and render.frameRects(slim, .{}).bar.isEmpty());
    const short = Rect.init(0, 0, 120, 4);
    try t.expect(barRow(short) == null and render.frameRects(short, .{}).bar.isEmpty());
}
