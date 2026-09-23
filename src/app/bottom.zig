//! The bottom dock — Rust's bottom panel, and the third host in the
//! section-placement model (`app/side.zig`). It sits under the whole
//! frame, spanning its width, with a one-row divider above it that
//! drags to resize; `ui.bottom_panel_height` is its height in rows and
//! `ui.bottom_panel_visible` opens it at start, the way
//! `ui.right_panel_width` / `_visible` do for the right column.
//!
//! It shows one of two things:
//!
//!   * a **section**, exactly as a column does — the diagnostics live
//!     here by default (Rust's `lsp.diagnostics` opens a pane under the
//!     editor, not a right-panel list), and `Ctrl-W J` / the rail's
//!     *Move to bottom dock* put any other section here;
//!   * a **hosted pane** (`view.host_active_in_bottom_panel`), which
//!     leaves the split tree and lives here instead. Hosted panes keep
//!     a tab strip, take the keys as `.pane` focus, and close like any
//!     tab. Running the command on a pane already docked sends it back
//!     out to the splits.
//!
//! A hosted pane stays in `App.panes` but out of the layout — the same
//! shape `App.outline_panel` uses. `App.forceClosePane` calls `forget`
//! so a closed pane cannot linger in the list.
//!
//! // changed (bottom-dock): `view.toggle_bottom_panel` and
//! `view.host_active_in_bottom_panel` were `cutRunner`s in
//! `cmd_app.zig` ("mnml-zig has no bottom panel"). No new command ids:
//! those two are Rust's, and they are the two this file runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const side = @import("side.zig");
const Rect = @import("../ui/rect.zig");

pub const table = .{
    .@"view.toggle_bottom_panel" = &toggleCmd,
    .@"view.host_active_in_bottom_panel" = &hostCmd,
};

/// The `.tab` hits the dock's strip registers carry this instead of a
/// leaf index — the hosted panes are not in the split tree, so the
/// number must not collide with a real leaf.
pub const strip_leaf: u32 = std.math.maxInt(u32);

pub const State = struct {
    /// The panes the dock hosts, in strip order; they live in
    /// `App.panes` but not in the layout.
    panes: std.ArrayListUnmanaged(PaneId) = .empty,
    /// Index into `panes` of the one on screen.
    active: usize = 0,

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.panes.deinit(gpa);
    }
};

/// The dock is on screen: it hosts a pane, or its side shows a section.
pub fn open(app: *const App) bool {
    return app.bottom.panes.items.len > 0 or side.shown(app, .bottom) != null;
}

/// The hosted pane on screen, if the dock hosts any.
pub fn activePane(app: *const App) ?PaneId {
    const list = app.bottom.panes.items;
    if (list.len == 0) return null;
    return list[@min(app.bottom.active, list.len - 1)];
}

pub fn hosts(app: *const App, id: PaneId) bool {
    return std.mem.indexOfScalar(PaneId, app.bottom.panes.items, id) != null;
}

/// Drop `id` from the host list without touching the pane — the pane
/// was closed, or has gone back to the splits.
pub fn forget(app: *App, id: PaneId) void {
    const at = std.mem.indexOfScalar(PaneId, app.bottom.panes.items, id) orelse return;
    _ = app.bottom.panes.orderedRemove(at);
    if (app.bottom.active >= app.bottom.panes.items.len) app.bottom.active = app.bottom.panes.items.len -| 1;
    app.needs_render = true;
}

/// Take `id` out of the split tree and host it in the dock.
pub fn host(app: *App, id: PaneId) Allocator.Error!void {
    if (hosts(app, id)) {
        app.bottom.active = std.mem.indexOfScalar(PaneId, app.bottom.panes.items, id).?;
    } else {
        _ = app.layouts.current().removePane(id);
        try app.bottom.panes.append(app.gpa, id);
        app.bottom.active = app.bottom.panes.items.len - 1;
    }
    app.setActive(id);
    app.needs_render = true;
}

/// Put `id` back where a pane normally lives: the current page's
/// splits, beside whatever is active there.
pub fn unhost(app: *App, id: PaneId) void {
    if (!hosts(app, id)) return;
    forget(app, id);
    // `showPane` reads `app.active` for the leaf to land in, and that
    // is the pane leaving the dock — aim at the layout instead.
    const back: ?PaneId = for (app.pane_mru.items) |p| {
        if (p != id and app.layouts.current().leafOf(p) != null) break p;
    } else null;
    app.active = back;
    app.showPane(id);
}

/// Send every hosted pane back to the splits (the dock closing).
pub fn drain(app: *App) void {
    while (app.bottom.panes.items.len > 0) unhost(app, app.bottom.panes.items[app.bottom.panes.items.len - 1]);
}

/// `view.toggle_bottom_panel` (Rust's `Ctrl+Shift+J`): close the dock —
/// hosted panes going back to the splits, as Rust drains them — or
/// bring back what it showed last.
fn toggleCmd(app: *App) CommandError!void {
    if (open(app)) {
        drain(app);
        side.hideColumn(app, .bottom);
        app.needs_render = true;
        return;
    }
    return side.toggleColumn(app, .bottom);
}

/// `view.host_active_in_bottom_panel`: the active pane moves into the
/// dock — and, run again on the pane already docked, back out.
fn hostCmd(app: *App) CommandError!void {
    const id = app.active orelse return app.diag.fail(app.frame.allocator(), "no active pane to dock", .{});
    if (hosts(app, id)) {
        unhost(app, id);
        app.toast("{s} → splits", .{app.panes.get(id).?.title()});
        return;
    }
    try host(app, id);
    app.toast("{s} → bottom dock", .{app.panes.get(id).?.title()});
}

/// The dock's height after a drag of its divider to row `y`: every row
/// from under the pointer to the bottom of the frame's upper area. The
/// upper area is measured WITHOUT the dock — the divider's own row
/// belongs to whichever side the pointer is on, so the sum stays put.
pub fn dragTo(app: *App, y: u16) void {
    const render = @import("render.zig");
    const bare = render.frameRects(Rect.init(0, 0, app.screen.width, app.screen.height), .{});
    side.setSize(app, .bottom, bare.upper.bottom() -| (y + 1));
    app.needs_render = true;
}

/// Whether the keys are in the dock: its section, or its hosted pane.
pub fn focused(app: *const App) bool {
    if (side.shown(app, .bottom)) |s| if (side.focusOf(s)) |f| if (std.meta.eql(app.focus, f)) return true;
    if (activePane(app)) |p| return app.focus == .pane and app.active == p;
    return false;
}
