//! Which colour a pane is — the app side of the pane rail
//! (`ui/pane_rail.zig` paints it).
//!
//! Every pane opens wearing a colour, and keeps it until it closes.
//! Most take the next free slot off the shared accent ladder
//! (`ui/accent_color.zig` — the same ladder the SESSIONS panel draws
//! from), handed out by `PaneStore.add` so two terminals open at once
//! are never the same colour. A pane that already belongs to something
//! wears that owner's colour instead and takes no slot: an
//! integration's app colour, a repo's accent. That is the whole
//! exception list.
//!
//! Where the name lives is the one seam: a pty keeps its own in
//! `PtyPane.accent_color` (the SESSIONS card, the colour menu and the
//! session file have read it since the sessions work), everything else
//! in `PaneStore.accents`. `nameOf` / `setName` are the accessor over
//! both, so nothing else has to know which side a pane is on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const pane_mod = @import("pane.zig");
const Pane = pane_mod.Pane;
const pty_pane = @import("pty_pane.zig");
const git_palette = @import("git_palette.zig");
const accent_color = @import("../ui/accent_color.zig");
const integrations_view = @import("../ui/integrations_view.zig");
const Theme = @import("../ui/theme.zig");

pub const Color = Theme.Color;

/// The palette name a pane wears, wherever it is kept; null when the
/// pane wears an owner's colour instead, or has none at all.
pub fn nameOf(app: *App, id: PaneId) ?[]const u8 {
    const p = app.panes.get(id) orelse return null;
    if (p.* == .pty) return p.pty.accent_color;
    return app.panes.accent(id);
}

/// Give a pane a palette name; the `none` sentinel clears it and the
/// pane takes the next free slot instead. An unknown name is ignored.
pub fn setName(app: *App, id: PaneId, name: []const u8) Allocator.Error!void {
    const p = app.panes.get(id) orelse return;
    if (accent_color.isNone(name)) {
        if (p.* == .pty) {
            if (p.pty.accent_color) |c| app.gpa.free(c);
            p.pty.accent_color = null;
        } else {
            try app.panes.setAccent(id, null);
        }
        try assign(app, id);
    } else {
        const canon = accent_color.canonical(name) orelse return;
        if (p.* == .pty) {
            const fresh = try app.gpa.dupe(u8, canon);
            if (p.pty.accent_color) |c| app.gpa.free(c);
            p.pty.accent_color = fresh;
        } else {
            try app.panes.setAccent(id, canon);
        }
    }
    app.needs_render = true;
}

/// Hand a pane with no colour the next free slot. `PaneStore.add` does
/// this for every pane it opens; this is the way back after a name was
/// cleared.
pub fn assign(app: *App, id: PaneId) Allocator.Error!void {
    const p = app.panes.get(id) orelse return;
    if (p.wearsOwnAccent()) return;
    if (nameOf(app, id) != null) return;
    const taken = try app.gpa.alloc(?[]const u8, app.panes.slots.items.len);
    defer app.gpa.free(taken);
    var live: usize = 0;
    for (app.panes.slots.items, 0..) |*slot, i| {
        taken[i] = null;
        if (i == id) continue;
        if (slot.*) |*other| {
            live += 1;
            if (other.wearsOwnAccent()) continue;
            taken[i] = if (other.* == .pty) other.pty.accent_color else app.panes.accent(@intCast(i));
        }
    }
    try setNameRaw(app, id, accent_color.firstFree(taken, live));
}

fn setNameRaw(app: *App, id: PaneId, name: []const u8) Allocator.Error!void {
    const p = app.panes.get(id) orelse return;
    if (p.* == .pty) {
        const fresh = try app.gpa.dupe(u8, name);
        if (p.pty.accent_color) |c| app.gpa.free(c);
        p.pty.accent_color = fresh;
    } else {
        try app.panes.setAccent(id, name);
    }
}

/// The colour a pane's rail is painted in: the owner's when it has one
/// (an integration's app colour, a repo's accent), else the palette
/// name it wears, else — a pty that somehow has neither — its
/// product's brand. Null only when nothing names a colour at all.
pub fn colorOf(app: *App, id: PaneId, theme: *const Theme) ?Color {
    const p = app.panes.get(id) orelse return null;
    switch (p.*) {
        // An integration already owns a colour app-wide: its chip, its
        // rail row, its tab glyph. The rail is that colour, not a
        // second one on top of it.
        .mount => |*mp| if (mp.integration) |mid| return integrationColor(app, mid, theme),
        .integrations => return theme.palette.cyan,
        .git_status => |*s| return git_palette.repoAccent(app, s.repo) orelse theme.palette.green,
        .diff => |*d| return git_palette.repoAccent(app, d.repo) orelse theme.palette.green,
        .git_graph => |*g| return git_palette.repoAccent(app, g.repo) orelse theme.palette.green,
        .pty => |*pt| return pty_pane.accentOf(app, pt, theme),
        else => {},
    }
    const name = nameOf(app, id) orelse return null;
    return accent_color.resolve(name, theme);
}

/// The manifest colour of an installed integration, as its chip wears
/// it (`ui/integrations_view.paletteColor` takes both a palette name
/// and a `#RRGGBB`).
fn integrationColor(app: *App, mid: []const u8, theme: *const Theme) Color {
    const chip = @import("integrations.zig").chipOf(app, mid) orelse return theme.accent.fg;
    return integrations_view.paletteColor(theme, chip.color);
}

/// The rail colour for a pane under the current `ui.pane_rail` setting:
/// `.all` paints every pane, `.sessions` only the AI session panes that
/// wore one before the rail was a rule, `.off` none.
pub fn railColorOf(app: *App, id: PaneId, theme: *const Theme) ?Color {
    return switch (app.cfg.ui.pane_rail) {
        .off => null,
        .sessions => blk: {
            const p = app.panes.get(id) orelse break :blk null;
            if (p.* != .pty) break :blk null;
            if (pty_pane.productOf(app, &p.pty) == null) break :blk null;
            break :blk pty_pane.accentOf(app, &p.pty, theme);
        },
        .all => colorOf(app, id, theme),
    };
}
