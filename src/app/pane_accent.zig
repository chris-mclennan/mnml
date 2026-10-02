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
//!
//! // changed (accent-defaults, the user's call 2026-09-22): the FIRST
//! pane of a kind opens in a colour of its own before the ladder — a
//! plain terminal in white, a Claude session in Claude's orange, a
//! Codex session in its chip's cyan (`ui.accent_defaults`). "First" is
//! by the live set, not by count: while a pane of the kind holds the
//! default, the next of its kind takes a free ladder slot as before,
//! and once it closes the default is free for the next one. A pick
//! from the tab's or the session card's Color menu wins over the rule
//! and rides in the session file as it always has; a restored pane
//! with no remembered colour goes through the rule like a new one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const pane_mod = @import("pane.zig");
const pty_pane = @import("pty_pane.zig");
const git_palette = @import("git_palette.zig");
const Config = @import("../config/Config.zig");
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

/// Hand a pane with no colour its kind's default while that is free,
/// else the next free ladder slot. `PaneStore.add` hands out the slot
/// for every pane it opens (`pty_pane.open` asks `defaultFor` first);
/// this is the way back after a name was cleared to Auto, and it asks
/// the same rule, so a cleared first terminal is white again.
pub fn assign(app: *App, id: PaneId) Allocator.Error!void {
    const p = app.panes.get(id) orelse return;
    if (p.* == .pty and p.pty.accent_color == null) {
        if (defaultFor(app, kindOfArgv(app, p.pty.argv))) |name| {
            p.pty.accent_color = try app.gpa.dupe(u8, name);
            return;
        }
    }
    try app.panes.assignAccent(id, p);
}

// ─── the kind defaults (accent-defaults) ────────────────────────────────

/// The kinds of pane that open in a colour of their own: what a pty
/// runs, by its command line. Every other pane is on the ladder alone.
pub const Kind = enum { shell, claude, codex };

/// The kind a command line makes a pty: Claude's binary or one of its
/// profile shims, Codex's, or — anything else, the user's shell
/// included — a plain terminal.
pub fn kindOfArgv(app: *const App, argv: []const []const u8) Kind {
    return switch (pty_pane.productOfArgv(app, argv) orelse return .shell) {
        .claude => .claude,
        .codex => .codex,
    };
}

fn kindOf(app: *const App, p: *const pane_mod.Pane) ?Kind {
    if (p.* != .pty) return null;
    return kindOfArgv(app, p.pty.argv);
}

/// The colour `ui.accent_defaults` names for a kind, a palette name;
/// null for `auto`.
pub fn configuredDefault(app: *const App, kind: Kind) ?[]const u8 {
    const d = app.cfg.ui.accent_defaults;
    const choice: Config.AccentName = switch (kind) {
        .shell => d.shell,
        .claude => d.claude,
        .codex => d.codex,
    };
    if (choice == .auto) return null;
    return accent_color.canonical(@tagName(choice));
}

/// The colour a pane of `kind` opens in, or null to take a ladder
/// slot: the kind's default while no live pane of the same kind is
/// wearing it — whether it took it by this rule or the user picked it.
/// A closed pane is out of the live set, so the default comes back
/// with the next one of its kind.
pub fn defaultFor(app: *const App, kind: Kind) ?[]const u8 {
    const want = configuredDefault(app, kind) orelse return null;
    for (app.panes.slots.items) |*slot| if (slot.*) |*other| {
        if (kindOf(app, other) != kind) continue;
        const worn = other.pty.accent_color orelse continue;
        if (std.mem.eql(u8, worn, want)) return null;
    };
    return want;
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
        // sessiondiff: a session's changes view is the session's — its
        // rail is the card's colour, so the two read as one thing.
        .session_changes => |*v| if (app.panes.pty(v.session)) |pt| if (pty_pane.accentOf(app, pt, theme)) |c| return c,
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

/// A pane that already paints a stripe down its own first column, so
/// the rail would be a second one beside it in the same colour.
///
/// Two do. A mounted integration owns every cell of its grid: the app
/// colour there is the sibling's to paint, and mnml taking a column
/// would narrow the sibling for nothing. A git status / diff / graph
/// pane paints its repo's gutter (`git_palette.repoGutter`) — but only
/// while a repo HAS an accent, which is only while there is more than
/// one repo to tell apart; the single-repo pane paints none and takes
/// the rail like anything else.
fn paintsOwnStripe(app: *App, p: *const pane_mod.Pane) bool {
    return switch (p.*) {
        .mount => |*mp| mp.integration != null,
        .git_status => |*s| git_palette.repoAccent(app, s.repo) != null,
        .diff => |*d| git_palette.repoAccent(app, d.repo) != null,
        .git_graph => |*g| git_palette.repoAccent(app, g.repo) != null,
        else => false,
    };
}

/// The colour of the stripe a pane paints down its own first column
/// (`paintsOwnStripe`) — the one the focus cue steps back while the
/// pane does not have the keys (`pane_rail.recolor`) — under the same
/// `ui.pane_rail = .all` that gives every other pane its rail. Null for
/// a pane that paints none.
pub fn ownStripeColorOf(app: *App, id: PaneId, theme: *const Theme) ?Color {
    const p = app.panes.get(id) orelse return null;
    if (!paintsOwnStripe(app, p)) return null;
    if (app.cfg.ui.pane_rail != .all) return null;
    return colorOf(app, id, theme);
}

/// The rail colour for a pane under the current `ui.pane_rail` setting:
/// `.all` paints every pane, `.sessions` only the AI session panes that
/// wore one before the rail was a rule, `.off` none.
pub fn railColorOf(app: *App, id: PaneId, theme: *const Theme) ?Color {
    const p = app.panes.get(id) orelse return null;
    if (paintsOwnStripe(app, p)) return null;
    return switch (app.cfg.ui.pane_rail) {
        .off => null,
        .sessions => blk: {
            if (p.* != .pty) break :blk null;
            if (@import("launch_profiles.zig").productOfPane(app, &p.pty) == null) break :blk null;
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

// ─── the kind defaults (accent-defaults) ────────────────────────────────

/// A pane that runs `argv` without starting anything (`dormant`), so a
/// test can open a "Claude session" or a "terminal" with no binary.
fn openDormant(app: *App, argv: []const []const u8, label: []const u8) !PaneId {
    return pty_pane.open(app, .{ .argv = argv, .label = label, .kind = .command, .placement = .tab, .dormant = true });
}

const brand = @import("../ui/brand.zig");

test "accent defaults: the first terminal opens in white, the first Claude pane in Claude's orange, the first Codex pane in cyan; the next of each kind takes a ladder slot; an editor is on the ladder alone" {
    if (!pty_pane.supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .cols = 80, .rows = 24 });
    defer app.deinit();
    const sh1 = try openDormant(&app, &.{}, "sh");
    const cl1 = try openDormant(&app, &.{"claude"}, "claude");
    const sh2 = try openDormant(&app, &.{ "/bin/sh", "-c", "sleep 30" }, "sh");
    const cl2 = try openDormant(&app, &.{ "claude", "--session-id", "x" }, "claude");
    const cx1 = try openDormant(&app, &.{"codex"}, "codex");
    const cx2 = try openDormant(&app, &.{"codex"}, "codex");
    try t.expectEqualStrings(accent_color.white, nameOf(&app, sh1).?);
    try t.expectEqualStrings(accent_color.claude_orange, nameOf(&app, cl1).?);
    try t.expectEqualStrings("cyan", nameOf(&app, cx1).?);
    // The second of each kind: the ladder, in its order, skipping the
    // worn — cyan is cx1's, so cx2 steps past it.
    try t.expectEqualStrings("green", nameOf(&app, sh2).?);
    try t.expectEqualStrings("blue", nameOf(&app, cl2).?);
    try t.expectEqualStrings("yellow", nameOf(&app, cx2).?);
    // The rail is that colour: the theme's text colour, the brand's orange.
    try t.expect(Color.eql(colorOf(&app, sh1, &app.theme).?, app.theme.palette.fg));
    try t.expect(Color.eql(colorOf(&app, cl1, &app.theme).?, brand.claude));
    try t.expect(Color.eql(colorOf(&app, cx1, &app.theme).?, app.theme.palette.cyan));
    // The kinds, as the rule sees them.
    try t.expectEqual(Kind.shell, kindOfArgv(&app, &.{}));
    try t.expectEqual(Kind.shell, kindOfArgv(&app, &.{ "/bin/sh", "-c", "x" }));
    try t.expectEqual(Kind.claude, kindOfArgv(&app, &.{ "/usr/local/bin/claude", "--resume" }));
    try t.expectEqual(Kind.codex, kindOfArgv(&app, &.{"codex"}));
    // An editor has no kind with a default: it takes the next slot.
    const ed = try app.openScratch();
    try t.expectEqualStrings("orange", nameOf(&app, ed).?);
}

test "accent defaults: closing the white terminal frees white for the next one; a pick wins and holds the kind's default; Auto asks the rule again" {
    if (!pty_pane.supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .cols = 80, .rows = 24 });
    defer app.deinit();
    const sh1 = try openDormant(&app, &.{}, "sh");
    const sh2 = try openDormant(&app, &.{}, "sh");
    try t.expectEqualStrings(accent_color.white, nameOf(&app, sh1).?);
    try t.expectEqualStrings("green", nameOf(&app, sh2).?);
    // The white one closes: the next terminal is the first again.
    try app.closePane(sh1, true);
    const sh3 = try openDormant(&app, &.{}, "sh");
    try t.expectEqualStrings(accent_color.white, nameOf(&app, sh3).?);
    // A pick wins, and a picked white counts as the default worn: the
    // next terminal goes to the ladder, and so does one cleared to
    // Auto while another terminal still wears white.
    try setName(&app, sh2, accent_color.white);
    try t.expectEqualStrings(accent_color.white, nameOf(&app, sh2).?);
    const sh4 = try openDormant(&app, &.{}, "sh");
    try t.expectEqualStrings("green", nameOf(&app, sh4).?);
    try setName(&app, sh4, accent_color.none);
    try t.expectEqualStrings("green", nameOf(&app, sh4).?);
    // Both whites gone, Auto is white again.
    try app.closePane(sh2, true);
    try app.closePane(sh3, true);
    try setName(&app, sh4, accent_color.none);
    try t.expectEqualStrings(accent_color.white, nameOf(&app, sh4).?);
    // A Claude pane's orange is a pick another kind may take too — the
    // rule is per kind, so a terminal in Claude's orange leaves the
    // first Claude pane its default.
    try setName(&app, sh4, accent_color.claude_orange);
    const cl1 = try openDormant(&app, &.{"claude"}, "claude");
    try t.expectEqualStrings(accent_color.claude_orange, nameOf(&app, cl1).?);
    // A remembered colour — a restored pane's — wins over the rule; a
    // restored pane with none goes through it.
    const cl2 = try pty_pane.open(&app, .{ .argv = &.{"claude"}, .label = "claude", .kind = .command, .placement = .tab, .dormant = true, .accent_color = "pink" });
    try t.expectEqualStrings("pink", nameOf(&app, cl2).?);
    try app.closePane(cl1, true);
    const cl3 = try pty_pane.open(&app, .{ .argv = &.{"claude"}, .label = "claude", .kind = .command, .placement = .tab, .dormant = true });
    try t.expectEqualStrings(accent_color.claude_orange, nameOf(&app, cl3).?);
}

test "accent defaults: `ui.accent_defaults` is the rule — auto puts a kind on the ladder, a ladder colour by name is that kind's first" {
    if (!pty_pane.supported) return error.SkipZigTest;
    var app = try App.initWith(t.allocator, t.io, .{ .cols = 80, .rows = 24 });
    defer app.deinit();
    try t.expectEqualStrings(accent_color.white, configuredDefault(&app, .shell) orelse return error.TestUnexpectedResult);
    try t.expectEqualStrings(accent_color.claude_orange, configuredDefault(&app, .claude) orelse return error.TestUnexpectedResult);
    try t.expectEqualStrings("cyan", configuredDefault(&app, .codex) orelse return error.TestUnexpectedResult);
    app.cfg.ui.accent_defaults = .{ .shell = .auto, .claude = .pink, .codex = .auto };
    try t.expect(configuredDefault(&app, .shell) == null);
    try t.expectEqualStrings("pink", configuredDefault(&app, .claude) orelse return error.TestUnexpectedResult);
    const sh1 = try openDormant(&app, &.{}, "sh");
    const cl1 = try openDormant(&app, &.{"claude"}, "claude");
    const cl2 = try openDormant(&app, &.{"claude"}, "claude");
    const cx1 = try openDormant(&app, &.{"codex"}, "codex");
    try t.expectEqualStrings("green", nameOf(&app, sh1).?);
    try t.expectEqualStrings("pink", nameOf(&app, cl1).?);
    try t.expectEqualStrings("blue", nameOf(&app, cl2).?);
    try t.expectEqualStrings("yellow", nameOf(&app, cx1).?);
    // A ladder colour as a default is worn, so the ladder skips it for
    // everything else while the pane lives.
    const ed = try app.openScratch();
    try t.expectEqualStrings("orange", nameOf(&app, ed).?);
}
