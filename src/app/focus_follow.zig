//! Focus follows the mouse — `ui.focus_follows_mouse`, opt-in.
//!
//! `off` (the default) is click-to-focus. `panes`: the pointer moving
//! onto a different split's body — an editor, a terminal, a session —
//! focuses that pane. `all`: the side columns and the dock too, so the
//! pointer over the tree hands the tree the keys.
//!
//! The rules that keep it usable, every one checked on every motion:
//!   - nothing moves while a menu, picker, prompt, confirm, the
//!     which-key popup or any other overlay is up, while the `:` line
//!     or the find bar is open, or while a chord is half-typed — the
//!     keys are promised to that surface;
//!   - nothing moves while a mouse button is held (`State.button_down`
//!     or an `App.drag` gesture in flight), so a drag across a divider
//!     or a selection past a split's edge never refocuses mid-drag;
//!   - only a pane the current layout shows can take it — a slot the
//!     store no longer has, or a pane with no leaf, is never focused;
//!   - a hover-focus is `pointerFocus`, the call a press on a pane
//!     makes, and nothing else: no scroll, no cursor move, no overlay
//!     closed. The focus cue, the statusline, the info view and the
//!     sessions card follow because they read `App.focus`.
//!
//! `ui.focus_follows_mouse_delay_ms` is the dwell. 0 focuses on the
//! motion that arrived; anything else arms `State.pending`, which
//! `tick` fires through the app's timer (`nextDeadlineMs`) once the
//! pointer has rested on the same target that long — never a sleep.
//!
//! The routing is `dispatch.mouse`'s: a `.motion` event lands here
//! before its early return, and the target comes from the frame's hit
//! map (`App.hits`), never from a painter.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const FocusId = app_mod.FocusId;
const Config = @import("../config/Config.zig");
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const Rect = @import("../ui/rect.zig");
const HitTarget = @import("../ui/hit.zig").HitTarget;
const render = @import("render.zig");
const side_mod = @import("side.zig");
const sidebar_auto = @import("sidebar_auto.zig");

/// What a hover would focus.
pub const Target = union(enum) {
    pane: PaneId,
    section: side_mod.Section,

    fn eql(a: Target, b: Target) bool {
        return std.meta.eql(a, b);
    }
};

pub const State = struct {
    /// A press without its release yet. The terminal reports motion
    /// with a button held as `.drag`, but the headless driver's
    /// `hover` step does not, and a press whose release went missing
    /// must not have the focus wander either.
    button_down: bool = false,
    /// The dwell in progress: the target the pointer is resting on and
    /// when it takes the focus.
    pending: ?Pending = null,

    pub const Pending = struct { target: Target, due_ms: i64 };
};

/// The press / release bookkeeping, before anything else sees the event.
pub fn track(app: *App, m: Mouse) void {
    switch (m.kind) {
        .press => app.focus_follow.button_down = true,
        .release => app.focus_follow.button_down = false,
        else => {},
    }
    if (m.kind != .motion) app.focus_follow.pending = null;
}

/// A press on a pane's body focuses it — this is that call, shared with
/// the hover so the two cannot drift: a different pane is shown and
/// activated (`App.showPane`), the active one only takes the keys back.
pub fn pointerFocus(app: *App, id: PaneId) void {
    if (app.active != id) app.showPane(id) else app.focus = .{ .pane = id };
}

/// A plain pointer motion. Focuses — or arms the dwell for — whatever
/// the pointer is over, when the rules allow it.
pub fn onMotion(app: *App, m: Mouse) void {
    const mode = app.cfg.ui.focus_follows_mouse;
    if (mode == .off) return;
    if (m.kind != .motion or m.button != .none) return;
    if (!allowed(app)) {
        app.focus_follow.pending = null;
        return;
    }
    const target = targetAt(app, mode, m.x, m.y) orelse {
        app.focus_follow.pending = null;
        return;
    };
    if (holds(app, target)) {
        app.focus_follow.pending = null;
        return;
    }
    const delay = app.cfg.ui.focus_follows_mouse_delay_ms;
    if (delay == 0) {
        app.focus_follow.pending = null;
        return apply(app, target);
    }
    if (app.focus_follow.pending) |p| if (p.target.eql(target)) return;
    app.focus_follow.pending = .{ .target = target, .due_ms = app.now_ms + delay };
    app.needs_render = true;
}

/// The dwell's timer: a pending target whose time has come takes the
/// focus, if the pointer is still on it and the rules still allow it.
pub fn tick(app: *App, now: i64) void {
    const p = app.focus_follow.pending orelse return;
    if (now < p.due_ms) return;
    app.focus_follow.pending = null;
    const mode = app.cfg.ui.focus_follows_mouse;
    if (mode == .off or !allowed(app)) return;
    const h = app.hover orelse return;
    const still = targetAt(app, mode, h.x, h.y) orelse return;
    if (!still.eql(p.target) or holds(app, still)) return;
    apply(app, still);
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    return if (app.focus_follow.pending) |p| p.due_ms else null;
}

/// Everything that keeps the focus where it is: an overlay, a typed
/// line, a half-typed chord, a held button, a gesture in flight.
fn allowed(app: *const App) bool {
    if (app.overlay != .none) return false;
    if (app.cmdline != null or app.find_bar != null) return false;
    if (app.chord.len > 0) return false;
    if (app.focus_follow.button_down or app.drag != null) return false;
    if (app.focus == .overlay) return false;
    return true;
}

/// Whether the focus already sits on `t`.
fn holds(app: *const App, target: Target) bool {
    return switch (target) {
        .pane => |id| app.focus == .pane and app.focus.pane == id and app.active == id,
        .section => |s| if (side_mod.focusOf(s)) |f| std.meta.eql(app.focus, f) else true,
    };
}

fn apply(app: *App, target: Target) void {
    switch (target) {
        .pane => |id| pointerFocus(app, id),
        .section => |s| side_mod.focusSection(app, s),
    }
    app.needs_render = true;
}

/// What the cell at (`x`, `y`) would hand the keys to under `mode`.
/// The callers have already returned on `off`.
pub fn targetAt(app: *App, mode: Config.FocusFollowsMouse, x: u16, y: u16) ?Target {
    if (mode == .all) if (sectionAt(app, x, y)) |s| return .{ .section = s };
    const hit = app.hits.at(x, y) orelse return null;
    const id = paneOf(hit) orelse return null;
    if (!shownPane(app, id)) return null;
    return .{ .pane = id };
}

/// The pane a hit belongs to: its body, an editor cell, the gutter, a
/// pane-hosted component's part, the pane's own scrollbar. The tab
/// strip, the dividers, the overlays and the chrome belong to no pane.
fn paneOf(hit: HitTarget) ?PaneId {
    return switch (hit) {
        .pane => |id| id,
        .editor_cell => |c| c.pane,
        .gutter => |g| g.pane,
        .fold_arrow => |g| g.pane,
        .breadcrumb => |b| b.pane,
        .script_hit => |sh| sh.pane,
        .scrollbar => |sb| switch (sb.owner) {
            .pane => |id| id,
            else => null,
        },
        else => null,
    };
}

/// A pane the current layout shows as its leaf's tab — never one the
/// store has dropped or one that has no leaf (a pane being closed, a
/// dock-hosted one, the overlays' scrollbar owners).
fn shownPane(app: *App, id: PaneId) bool {
    if (app.panes.get(id) == null) return false;
    const layout = app.layouts.current();
    const lid = layout.leafOf(id) orelse return false;
    const leaf = layout.leaf(lid) orelse return false;
    return leaf.active == id;
}

/// `all`: the section a side column — docked, slid in over the
/// editor, or the dock under it — shows under the pointer.
fn sectionAt(app: *App, x: u16, y: u16) ?side_mod.Section {
    if (app.zen) return null;
    if (app.sidebar_auto.open) |cs| if (app.sidebar_auto.rect.contains(x, y)) {
        return side_mod.shown(app, if (cs == .left) .left else .right);
    };
    const fr = render.frameRects(Rect.init(0, 0, app.screen.width, app.screen.height), render.chrome(app));
    const side: side_mod.Side = if (fr.sidebar.contains(x, y)) .left else if (fr.right.contains(x, y)) .right else if (fr.bottom.contains(x, y)) .bottom else return null;
    const s = side_mod.shown(app, side) orelse return null;
    return if (side_mod.focusOf(s) != null) s else null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const command = @import("../core/command.zig");

fn motion(app: *App, x: u16, y: u16) !void {
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .motion } });
}

/// Three editor splits side by side, the tree hidden: the panes'
/// ids left to right.
fn threeSplits(app: *App) ![3]PaneId {
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(app, .{ .static = .@"view.split_right" });
    try command.run(app, .{ .static = .@"view.split_right" });
    try command.run(app, .{ .static = .@"view.equalize_splits" });
    try app.render();
    var ids: [3]PaneId = undefined;
    var n: usize = 0;
    var x: u16 = 0;
    while (x < app.screen.width) : (x += 1) {
        const id = paneOf(app.hits.at(x, 10) orelse continue) orelse continue;
        if (n > 0 and ids[n - 1] == id) continue;
        ids[n] = id;
        n += 1;
        if (n == 3) break;
    }
    try t.expectEqual(@as(usize, 3), n);
    return ids;
}

fn xOf(app: *App, id: PaneId) u16 {
    for (app.hits.items.items) |e| if (e.target == .pane and e.target.pane == id) return e.rect.x + e.rect.w / 2;
    unreachable;
}

test "focus follows mouse: `panes` — hovering across three splits focuses each; `off` never does" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const ids = try threeSplits(&app);
    app.showPane(ids[2]);
    try app.render();
    // `off`, the default: a hover is only a hover.
    try motion(&app, xOf(&app, ids[0]), 10);
    try t.expectEqual(ids[2], app.active.?);
    app.cfg.ui.focus_follows_mouse = .panes;
    for ([_]usize{ 0, 1, 2, 1, 0 }) |i| {
        try motion(&app, xOf(&app, ids[i]), 10);
        try t.expectEqual(ids[i], app.active.?);
        try t.expect(app.focus == .pane and app.focus.pane == ids[i]);
    }
}

test "focus follows mouse: a held button, a drag gesture, an open picker, the which-key popup and a pending chord all keep the focus" {
    // The picker opened below is the file picker, which walks the
    // workspace as it opens: a workspace of its own, two files deep,
    // not `/tmp` — the shared /tmp walked in 99 s in Debug.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(t.io, &root_buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.focus_follows_mouse = .panes;
    const ids = try threeSplits(&app);
    app.showPane(ids[0]);
    try app.render();
    // A press in pane 0, then the pointer crosses into pane 2 with the
    // button still down — as the headless `hover` step reports it and
    // as a terminal's `.drag` does.
    try app.handle(.{ .mouse = .{ .x = xOf(&app, ids[0]), .y = 10, .kind = .press, .button = .left } });
    try t.expectEqual(ids[0], app.active.?);
    try motion(&app, xOf(&app, ids[2]), 10);
    try t.expectEqual(ids[0], app.active.?);
    try app.handle(.{ .mouse = .{ .x = xOf(&app, ids[2]), .y = 10, .kind = .drag, .button = .left } });
    try t.expectEqual(ids[0], app.active.?);
    try app.handle(.{ .mouse = .{ .x = xOf(&app, ids[2]), .y = 10, .kind = .release, .button = .left } });
    // Released: the next motion is free to move it.
    try motion(&app, xOf(&app, ids[1]), 10);
    try t.expectEqual(ids[1], app.active.?);
    // An open picker keeps it.
    try command.run(&app, .{ .static = .@"picker.files" });
    try t.expect(app.overlay == .picker);
    try t.expect(app.overlay.picker.labels.len >= 2);
    try app.render();
    try motion(&app, xOf(&app, ids[2]) + 20, 3);
    try motion(&app, 2, 20);
    try t.expectEqual(ids[1], app.active.?);
    try app.handle(.{ .key = key_mod.Key.named(.esc) });
    try t.expect(app.overlay == .none);
    // The which-key popup keeps it.
    app.overlay = .{ .which_key = .{} };
    try motion(&app, xOf(&app, ids[2]), 10);
    try t.expectEqual(ids[1], app.active.?);
    app.overlay = .none;
    // A half-typed chord keeps it.
    app.chord.len = 1;
    try motion(&app, xOf(&app, ids[2]), 10);
    try t.expectEqual(ids[1], app.active.?);
    app.chord.len = 0;
    try motion(&app, xOf(&app, ids[2]), 10);
    try t.expectEqual(ids[2], app.active.?);
}

test "focus follows mouse: a hover-focus moves neither the target's view nor its cursor" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.focus_follows_mouse = .panes;
    const ids = try threeSplits(&app);
    // Pane 1 has text, a cursor at the top, and a view scrolled past it.
    app.showPane(ids[1]);
    const e = app.activeEditor().?;
    var i: usize = 0;
    while (i < 200) : (i += 1) _ = try app.applyOps(e, &.{.{ .insert_str = "line\n" }});
    e.buf.editor.cursor = 0;
    app.showPane(ids[0]);
    try app.render();
    const before_cursor = e.buf.editor.cursor;
    // Where a wheel over it leaves it: the view scrolled, pinned
    // until the cursor moves.
    e.view.scroll_line = 120;
    e.view.pinAt(e.buf.editor.cursor);
    try app.render();
    const before_top = e.view.scroll_line;
    try motion(&app, xOf(&app, ids[1]), 10);
    try t.expectEqual(ids[1], app.active.?);
    try app.render();
    try t.expectEqual(before_cursor, e.buf.editor.cursor);
    try t.expectEqual(before_top, e.view.scroll_line);
    try t.expectEqual(@as(u32, 120), e.view.scroll_line);
}

test "focus follows mouse: `all` hands the tree the keys, `panes` leaves the tree alone" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.loaded = true;
    const a = try app.openScratch();
    try app.render();
    try t.expect(app.focus == .pane);
    const fr = render.frameRects(Rect.init(0, 0, app.screen.width, app.screen.height), render.chrome(&app));
    try t.expect(!fr.sidebar.isEmpty());
    const tx = fr.sidebar.x + 2;
    const ty = fr.sidebar.y + 3;
    app.cfg.ui.focus_follows_mouse = .panes;
    try motion(&app, tx, ty);
    try t.expect(app.focus == .pane and app.focus.pane == a);
    app.cfg.ui.focus_follows_mouse = .all;
    try motion(&app, tx, ty);
    try t.expect(app.focus == .tree);
    // And back onto the pane: `all` includes the panes.
    try motion(&app, fr.body.x + fr.body.w / 2, fr.body.y + 10);
    try t.expect(app.focus == .pane and app.focus.pane == a);
}

test "focus follows mouse: the dwell arms on the motion and fires from tick, only if the pointer stayed" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.focus_follows_mouse = .panes;
    app.cfg.ui.focus_follows_mouse_delay_ms = 300;
    const ids = try threeSplits(&app);
    app.showPane(ids[0]);
    try app.render();
    app.now_ms = 1000;
    try motion(&app, xOf(&app, ids[2]), 10);
    try t.expectEqual(ids[0], app.active.?);
    try t.expectEqual(@as(?i64, 1300), nextDeadlineMs(&app));
    tick(&app, 1200);
    try t.expectEqual(ids[0], app.active.?);
    tick(&app, 1300);
    try t.expectEqual(ids[2], app.active.?);
    try t.expect(nextDeadlineMs(&app) == null);
    // Passing over pane 1 on the way back to pane 0: the dwell restarts
    // on each new target, and a pointer that moved on focuses nothing.
    app.now_ms = 2000;
    try motion(&app, xOf(&app, ids[1]), 10);
    app.now_ms = 2100;
    try motion(&app, xOf(&app, ids[0]), 10);
    try t.expectEqual(@as(?i64, 2400), nextDeadlineMs(&app));
    tick(&app, 2400);
    try t.expectEqual(ids[0], app.active.?);
}

test "focus follows mouse: only a pane its leaf shows is a target — never a background tab or an id the store dropped" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.focus_follows_mouse = .panes;
    const ids = try threeSplits(&app);
    try t.expect(shownPane(&app, ids[1]));
    try t.expect(!shownPane(&app, 9999));
    // A second tab in the first leaf: the first pane is still in the
    // layout but no longer shown, so it can never take a hover-focus.
    app.showPane(ids[0]);
    const tab = try app.openScratch();
    try t.expect(tab != ids[0]);
    try t.expect(!shownPane(&app, ids[0]));
    try t.expect(shownPane(&app, tab));
}

test "focus follows mouse: an open context menu keeps the focus" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    app.cfg.ui.focus_follows_mouse = .panes;
    const ids = try threeSplits(&app);
    // A right press on the middle split focuses it and opens its menu.
    try app.handle(.{ .mouse = .{ .x = xOf(&app, ids[1]), .y = 10, .kind = .press, .button = .right } });
    try app.handle(.{ .mouse = .{ .x = xOf(&app, ids[1]), .y = 10, .kind = .release, .button = .right } });
    try t.expect(app.overlay == .menu);
    try t.expectEqual(ids[1], app.active.?);
    try motion(&app, xOf(&app, ids[0]), 30);
    try motion(&app, xOf(&app, ids[2]), 30);
    try t.expectEqual(ids[1], app.active.?);
}
