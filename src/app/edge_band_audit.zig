//! The edge-band audit — the structural guard behind **one rule**:
//!
//! > **An edge band belongs to one surface.** A surface that lives on a
//! > screen edge owns a band there; everything else is laid out inside
//! > it, and the surface's `⋯` / `⋮` grip marks that band and only that
//! > band. A grip never takes a cell another interactive surface paints
//! > or hits.
//!
//! Three findings of 2026-09-21 were the same break of it, all on a
//! SIDE edge, where a grip's three-cell run is three ROWS of one
//! column: the right-edge dock's grip owned three rows of the editor's
//! scrollbar (a press pinned the dock and never scrolled), the
//! left-edge dock's grip owned column 0 of three activity-bar rows, and
//! a left dock with the side columns on `auto` had the sidebar's grip
//! paint over the dock's own item glyphs while their hits still fired.
//! A fourth, from the `daily` hunter, was the layout half of it: a
//! REVEALED left dock painted the activity bar out of existence, and
//! which of the two survived depended on the order the two commands ran
//! in.
//!
//! Nothing caught any of them. The e2e gate (`tools/gate.txt` with
//! `--sizes`) is 47 editor-and-keyboard files: it drives no dock, no
//! grip and no pointer, so there was no configuration in it for the
//! collision to happen in — and the `.test` language has no way to ask
//! about a hit rect anyway, only about the screen. The only sweep that
//! could have seen it was the `mouse` hunter's own by-hand audit, which
//! is what found all three.
//!
//! So the audit lives here, as a unit test over a MATRIX: every dock
//! edge × mode × strip state, against both side columns, the menu bar,
//! the right column, the bottom panel and the activity bar in each of
//! their states, at 80×24, 120×40 and 376×92. Each frame is rendered
//! for real and asked three questions:
//!
//!   A. **Grip exclusivity.** No cell of a grip's run carries any other
//!      surface's hit. The one exception is written down below, not
//!      waved through: the bottom dock's grip shares the screen's last
//!      row with the `:` line, the one band mnml deliberately shares,
//!      and `launcher_dock.gripBlocked` is what governs it.
//!   B. **Control integrity.** Every cell of a scrollbar, an activity
//!      bar row and a launcher-dock item still answers as that control
//!      — the whole painted extent, not most of it.
//!   C. **Two strips, two bands.** A side dock and the activity bar
//!      never share a column, whichever of them was asked for first.
//!
//! A new surface on an edge fails A the moment it lands on someone
//! else's cells, which is the direction this guard is meant to fail in.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Rect = @import("../ui/rect.zig");
const hit_mod = @import("../ui/hit.zig");
const render = @import("render.zig");

pub const Button = render.Button;

/// What went wrong, for a failure message that names the cell.
pub const Break = struct {
    kind: enum { grip_over_other, control_shadowed, strips_share_a_column },
    x: u16 = 0,
    y: u16 = 0,
    what: []const u8 = "",
};

fn isGrip(target: hit_mod.HitTarget) bool {
    if (target != .button) return false;
    return switch (@as(Button, @enumFromInt(target.button))) {
        .edge_grip_menu_bar, .edge_grip_sidebar_left, .edge_grip_sidebar_right, .edge_grip_dock => true,
        else => false,
    };
}

/// The two things a grip may legitimately stand on, written down
/// rather than waved through.
///
///  * **A pane's own CONTENT.** The rule is about controls, not about
///    text: the whole point of an auto-hiding side column is that it
///    reveals as paint over the editor with no relayout, so its dwell
///    band IS the editor's outermost column and its grip names that
///    band. The surface it summons covers that text a moment later
///    anyway, and text reflows; a scrollbar, an icon or a dock item
///    does not.
///  * **The `:` line's row.** A bottom grip sits on it BY DESIGN — the
///    row is the frame's outermost edge and the `:` line's home at
///    once, the one band mnml shares on purpose — and
///    `launcher_dock.gripBlocked` stands the grip down whenever the
///    line is actually in use.
///
/// Nothing else is exempt: a control under a grip is the family this
/// audit exists for.
fn gripMayStandOn(target: hit_mod.HitTarget) bool {
    return switch (target) {
        .pane, .editor_cell => true,
        .button => |id| id == @intFromEnum(Button.cmdline_bar),
        else => false,
    };
}

/// The controls this audit insists stay whole. Each is a surface with
/// no over-registration of its own, so "every cell answers as me" is
/// exactly true of them when nothing has stolen their cells (unlike,
/// say, an editor row, whose gutter and fold arrow are registered over
/// its cells on purpose).
fn controlTag(target: hit_mod.HitTarget) ?[]const u8 {
    return switch (target) {
        .scrollbar => "scrollbar",
        .rail => "rail",
        .launcher_dock => "launcher_dock",
        else => null,
    };
}

/// Audit the frame `app` has just rendered. Null when it holds.
pub fn audit(app: *const App) ?Break {
    const items = app.hits.items.items;
    // ── A. grip exclusivity ──
    for (items, 0..) |e, i| {
        if (!isGrip(e.target)) continue;
        var y = e.rect.y;
        while (y < e.rect.bottom()) : (y += 1) {
            var x = e.rect.x;
            while (x < e.rect.right()) : (x += 1) {
                for (items, 0..) |o, j| {
                    if (i == j or !o.rect.contains(x, y)) continue;
                    if (isGrip(o.target)) return .{ .kind = .grip_over_other, .x = x, .y = y, .what = "another grip" };
                    if (gripMayStandOn(o.target)) continue;
                    return .{ .kind = .grip_over_other, .x = x, .y = y, .what = @tagName(o.target) };
                }
            }
        }
    }
    // ── B. control integrity ──
    for (items) |e| {
        const tag = controlTag(e.target) orelse continue;
        var y = e.rect.y;
        while (y < e.rect.bottom()) : (y += 1) {
            var x = e.rect.x;
            while (x < e.rect.right()) : (x += 1) {
                const top = app.hits.at(x, y) orelse return .{ .kind = .control_shadowed, .x = x, .y = y, .what = tag };
                const top_tag = controlTag(top) orelse return .{ .kind = .control_shadowed, .x = x, .y = y, .what = tag };
                if (!std.mem.eql(u8, tag, top_tag)) return .{ .kind = .control_shadowed, .x = x, .y = y, .what = tag };
            }
        }
    }
    return null;
}

/// C, which is about the frame's rects rather than its hits: a side
/// dock and the activity bar are two strips and want two bands.
pub fn stripsDisjoint(fr: render.FrameRects) ?Break {
    if (fr.launcher_dock.isEmpty() or fr.rail.isEmpty()) return null;
    const both = fr.launcher_dock.intersect(fr.rail);
    if (both.isEmpty()) return null;
    return .{ .kind = .strips_share_a_column, .x = both.x, .y = both.y, .what = "dock and activity bar" };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Config = @import("../config/Config.zig");
const launcher_dock = @import("launcher_dock.zig");

const Case = struct {
    dock_edge: Config.DockEdge,
    dock_mode: Config.DockMode,
    dock_open: bool,
    sidebar: Config.Sidebar,
    sidebar_pinned: bool,
    menu_bar: Config.MenuBar,
    rail: Config.ActivityBar,
    right_column: bool,
    bottom_panel: bool,
    /// // changed (dock-shared): a bottom strip's row — `.shared` puts
    /// it on the `:` line's, where its items share the row's hits.
    dock_placement: Config.DockPlacement = .inner,
};

fn apply(app: *App, c: Case) void {
    app.cfg.ui.dock.edge = c.dock_edge;
    app.cfg.ui.dock.mode = c.dock_mode;
    app.cfg.ui.dock.placement = c.dock_placement;
    app.launcher_dock.pinned = false;
    app.launcher_dock.open = c.dock_mode == .auto_hide and c.dock_open;
    app.launcher_dock.by_key = app.launcher_dock.open;
    app.cfg.ui.sidebar = c.sidebar;
    app.sidebar_auto.pinned = c.sidebar_pinned;
    app.cfg.ui.menu_bar = c.menu_bar;
    app.menu_bar.pinned = false;
    app.cfg.ui.activity_bar = c.rail;
    app.side.open.set(.right, if (c.right_column) .outline else null);
    app.side.open.set(.bottom, if (c.bottom_panel) .diagnostics else null);
}

fn describe(c: Case) void {
    std.debug.print(
        "case: dock {s}/{s}/{s}{s} · sidebar {s}{s} · menu_bar {s} · rail {s} · right {} · bottom {}\n",
        .{
            @tagName(c.dock_edge), @tagName(c.dock_mode),                     @tagName(c.dock_placement), if (c.dock_open) " (revealed)" else "",
            @tagName(c.sidebar),   if (c.sidebar_pinned) " (pinned)" else "", @tagName(c.menu_bar),       @tagName(c.rail),
            c.right_column,        c.bottom_panel,
        },
    );
}

test "the edge-band audit: no grip ever takes another surface's cell, and no control is ever shadowed — every dock edge × placement × mode × state, at 80x24, 120x40 and 376x92" {
    const sizes = [_]struct { cols: u16, rows: u16 }{
        .{ .cols = 80, .rows = 24 },
        .{ .cols = 120, .rows = 40 },
        .{ .cols = 376, .rows = 92 },
    };
    for (sizes) |size| {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = size.cols, .rows = size.rows });
        defer app.deinit();
        _ = try app.openScratch();
        for ([_]Config.DockEdge{ .bottom, .left, .right }) |dock_edge| for (std.enums.values(Config.DockPlacement)) |dock_placement| {
            // A side dock ignores the placement: one pass is all of it.
            if (dock_edge != .bottom and dock_placement != .inner) continue;
            for ([_]Config.DockMode{ .always, .auto_hide, .hidden }) |dock_mode| {
                for ([_]bool{ false, true }) |dock_open| {
                    if (dock_open and dock_mode != .auto_hide) continue;
                    for ([_]Config.Sidebar{ .always, .auto }) |sidebar| {
                        for ([_]bool{ false, true }) |sidebar_pinned| {
                            if (sidebar_pinned and sidebar != .auto) continue;
                            for ([_]Config.MenuBar{ .always, .auto }) |menu_bar| {
                                for ([_]Config.ActivityBar{ .always, .auto }) |rail| {
                                    for ([_]bool{ false, true }) |right_column| {
                                        for ([_]bool{ false, true }) |bottom_panel| {
                                            const c: Case = .{
                                                .dock_edge = dock_edge,
                                                .dock_mode = dock_mode,
                                                .dock_open = dock_open,
                                                .sidebar = sidebar,
                                                .sidebar_pinned = sidebar_pinned,
                                                .menu_bar = menu_bar,
                                                .rail = rail,
                                                .right_column = right_column,
                                                .bottom_panel = bottom_panel,
                                                .dock_placement = dock_placement,
                                            };
                                            apply(&app, c);
                                            try app.render();
                                            if (audit(&app)) |b| {
                                                describe(c);
                                                std.debug.print("  {s} at ({d},{d}): {s} — {d}x{d}\n", .{ @tagName(b.kind), b.x, b.y, b.what, size.cols, size.rows });
                                                return error.EdgeBandBroken;
                                            }
                                            if (stripsDisjoint(render.frameRects(Rect.init(0, 0, size.cols, size.rows), render.chrome(&app)))) |b| {
                                                describe(c);
                                                std.debug.print("  {s} at ({d},{d}): {s} — {d}x{d}\n", .{ @tagName(b.kind), b.x, b.y, b.what, size.cols, size.rows });
                                                return error.TwoStripsOneBand;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        };
    }
}

test "the audit holds with sections hidden from the activity bar: the rail's rows close up inside the same band, and a moved section on the dock is one more item, never one more band" {
    // // changed (railmove): `ui.rail.hidden` changes which ROWS the
    // rail paints, never its columns, so every grip and control rule
    // above must hold unchanged — including a side dock beside a
    // shortened rail, and a dock carrying a pinned panel.
    const sizes = [_]struct { cols: u16, rows: u16 }{
        .{ .cols = 80, .rows = 24 },
        .{ .cols = 120, .rows = 40 },
        .{ .cols = 376, .rows = 92 },
    };
    const hidden_sets = [_][]const Config.RailSection{
        &.{ .explorer, .git, .todos, .scripts },
        &.{ .explorer, .search, .git, .debug, .integrations, .sessions, .http, .notes, .todos, .findings, .scripts },
    };
    for (sizes) |size| {
        var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = size.cols, .rows = size.rows });
        defer app.deinit();
        _ = try app.openScratch();
        app.cfg.ui.dock.pins = &.{ "view.activity_todos", "view.activity_git" };
        for (hidden_sets) |hidden| {
            app.cfg.ui.rail.hidden = hidden;
            for ([_]Config.DockEdge{ .bottom, .left, .right }) |dock_edge| {
                for ([_]Config.DockMode{ .always, .auto_hide }) |dock_mode| {
                    for ([_]bool{ false, true }) |dock_open| {
                        if (dock_open and dock_mode != .auto_hide) continue;
                        for ([_]Config.ActivityBar{ .always, .auto }) |rail| {
                            for ([_]Config.Sidebar{ .always, .auto }) |sidebar| {
                                const c: Case = .{
                                    .dock_edge = dock_edge,
                                    .dock_mode = dock_mode,
                                    .dock_open = dock_open,
                                    .sidebar = sidebar,
                                    .sidebar_pinned = false,
                                    .menu_bar = .always,
                                    .rail = rail,
                                    .right_column = false,
                                    .bottom_panel = false,
                                };
                                apply(&app, c);
                                try app.render();
                                if (audit(&app)) |b| {
                                    describe(c);
                                    std.debug.print("  {s} at ({d},{d}): {s} — {d}x{d}, {d} hidden\n", .{ @tagName(b.kind), b.x, b.y, b.what, size.cols, size.rows, hidden.len });
                                    return error.EdgeBandBroken;
                                }
                                if (stripsDisjoint(render.frameRects(Rect.init(0, 0, size.cols, size.rows), render.chrome(&app)))) |b| {
                                    describe(c);
                                    std.debug.print("  {s} at ({d},{d}): {s} — {d}x{d}, {d} hidden\n", .{ @tagName(b.kind), b.x, b.y, b.what, size.cols, size.rows, hidden.len });
                                    return error.TwoStripsOneBand;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

test "a side dock's band is the strip's own columns, reserved up or down, and everything else starts where it ends" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    const full = Rect.init(0, 0, 120, 40);
    app.cfg.ui.dock.edge = .left;
    app.cfg.ui.dock.mode = .auto_hide;
    try app.render();
    // The band is three columns wide — the strip's own — and it is
    // there while the strip is DOWN.
    const band = @import("hover_zones.zig").dockBand(&app, full).?;
    try t.expectEqual(@as(u16, 0), band.x);
    try t.expectEqual(launcher_dock.width, band.w);
    try t.expect(!launcher_dock.shown(&app));
    // The frame carved it, so the activity bar starts after it.
    const fr = render.frameRects(full, render.chrome(&app));
    try t.expectEqual(band.x, fr.launcher_dock.x);
    try t.expectEqual(launcher_dock.width, fr.launcher_dock.w);
    try t.expectEqual(launcher_dock.width, fr.rail.x);
    try t.expect(stripsDisjoint(fr) == null);
    // The grip is in the band's MIDDLE column, where the items paint
    // their glyphs, and nothing else answers for its cells.
    const grip = @import("../ui/edge_grip.zig").place(band, .left).?;
    try t.expectEqual(@as(u16, 1), grip.x);
    try t.expectEqual(@intFromEnum(Button.edge_grip_dock), app.hits.at(grip.x, grip.y).?.button);
    try t.expect(audit(&app) == null);
    // Revealing fills the band it already owned: same columns, and the
    // activity bar has not moved a cell.
    app.launcher_dock.open = true;
    app.launcher_dock.by_key = true;
    try app.render();
    try t.expect(launcher_dock.shown(&app));
    const revealed = render.frameRects(full, render.chrome(&app));
    try t.expectEqual(fr.launcher_dock, revealed.launcher_dock);
    try t.expectEqual(fr.rail, revealed.rail);
    try t.expect(audit(&app) == null);
}
