//! Which colour a pane is — the app side of the pane rail
//! (`ui/pane_rail.zig` paints it).
//!
//! Every pane opens wearing a colour, and keeps it until it closes.
//! Most take the next free slot off the shared accent ladder
//! (`ui/accent_color.zig` — the same ladder the SESSIONS panel draws
//! from), handed out by `PaneStore.add` so two terminals open at once
//! are never the same colour. A pane that already belongs to something
//! wears that owner's colour instead and takes no slot: a mounted
//! integration's app colour, a repo's accent (`colorOf`). A mounted
//! integration is also the one pane mnml does not stripe at all — the
//! sibling owns every cell of that grid, so the app colour is its own
//! gutter to paint, and a rail on top would be the same colour twice
//! and a column narrower for the sibling.
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
    try app.panes.assignAccent(id, p);
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
        // A repo's accent is what tells two repos' panes apart, so it
        // wins over the pane's own slot. One repo has no accent (there
        // is nothing to tell apart) and the pane falls back to its slot
        // like any other.
        .git_status => |*s| if (git_palette.repoAccent(app, s.repo)) |c| return c,
        .diff => |*d| if (git_palette.repoAccent(app, d.repo)) |c| return c,
        .git_graph => |*g| if (git_palette.repoAccent(app, g.repo)) |c| return c,
        // A pty's own precedence: its name, then its product's brand.
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
    const p = app.panes.get(id) orelse return null;
    // A mounted integration owns its own grid, first column included:
    // mnml painting a stripe there would take a cell off the sibling's
    // layout, and the app colour is the sibling's to paint. `colorOf`
    // still knows the colour — the pane just is not mnml's to stripe.
    if (p.wearsOwnAccent()) return null;
    return switch (app.cfg.ui.pane_rail) {
        .off => null,
        .sessions => blk: {
            if (p.* != .pty) break :blk null;
            if (pty_pane.productOf(app, &p.pty) == null) break :blk null;
            break :blk pty_pane.accentOf(app, &p.pty, theme);
        },
        .all => colorOf(app, id, theme),
    };
}
// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every pane opens wearing a colour, no two live panes share one, and a closed pane's colour comes back" {
    var app = try App.initWith(t.allocator, t.io, .{ .cols = 80, .rows = 24 });
    defer app.deinit();
    const a = try app.openScratch();
    const b = try app.openScratch();
    const c = try app.openScratch();
    try t.expectEqualStrings("green", nameOf(&app, a).?);
    try t.expectEqualStrings("blue", nameOf(&app, b).?);
    try t.expectEqualStrings("yellow", nameOf(&app, c).?);
    // The colour is the pane's rail colour, resolved through the theme.
    try t.expect(Color.eql(colorOf(&app, b, &app.theme).?, app.theme.palette.blue));
    // Close the middle one and blue is free: the next pane takes it
    // rather than marching on down the ladder.
    try app.closePane(b, true);
    const d = try app.openScratch();
    try t.expectEqualStrings("blue", nameOf(&app, d).?);
    // A pane keeps its colour while it lives, whatever opens after it.
    try t.expectEqualStrings("green", nameOf(&app, a).?);
    try t.expectEqualStrings("yellow", nameOf(&app, c).?);
}

test "the ladder cycles once every colour is worn, and a pick still wins" {
    var app = try App.initWith(t.allocator, t.io, .{ .cols = 80, .rows = 24 });
    defer app.deinit();
    var ids: [10]app_mod.PaneId = undefined;
    for (&ids) |*id| id.* = try app.openScratch();
    const ladder = @import("../ui/accent_color.zig").palette;
    for (ids[0..8], ladder) |id, want| try t.expectEqualStrings(want, nameOf(&app, id).?);
    // Nine panes, eight colours: the ninth wraps rather than going
    // colourless.
    try t.expect(nameOf(&app, ids[8]) != null);
    try t.expect(nameOf(&app, ids[9]) != null);
    // A pick wins over the slot, and `Auto` puts the pane back on the
    // ladder — onto the first colour nobody else holds.
    try setName(&app, ids[0], "pink");
    try t.expectEqualStrings("pink", nameOf(&app, ids[0]).?);
    try setName(&app, ids[0], "mauve");
    try t.expectEqualStrings("pink", nameOf(&app, ids[0]).?);
    try setName(&app, ids[0], "none");
    try t.expectEqualStrings("green", nameOf(&app, ids[0]).?);
}

test "the three settings: all paints every pane, sessions only an AI session pane, off none" {
    var app = try App.initWith(t.allocator, t.io, .{ .cols = 80, .rows = 24 });
    defer app.deinit();
    const ed = try app.openScratch();
    app.cfg.ui.pane_rail = .all;
    try t.expect(railColorOf(&app, ed, &app.theme) != null);
    // `sessions` is the look before the rail was a rule: a pane that is
    // not an AI session wears nothing, whatever colour it holds.
    app.cfg.ui.pane_rail = .sessions;
    try t.expect(railColorOf(&app, ed, &app.theme) == null);
    app.cfg.ui.pane_rail = .off;
    try t.expect(railColorOf(&app, ed, &app.theme) == null);
    // The colour itself is untouched by the setting — turning the rail
    // back on does not re-roll it.
    app.cfg.ui.pane_rail = .all;
    try t.expect(Color.eql(railColorOf(&app, ed, &app.theme).?, app.theme.palette.green));
}
