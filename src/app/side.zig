//! Which side of the screen each activity section lives on. The frame
//! has two columns — left, with the rail down its edge, and right —
//! and every section that owns a column surface (the tree, git mode's
//! palette, a list panel) sits in one of them. A column shows one
//! section at a time; the explorer on the left and TODOS on the right
//! are both on screen, which is the point.
//!
//! Rust has one sidebar (`active_section` swaps its content) and a
//! separate tabbed right panel. Here the two are one idea: a section
//! has a `Side`, and `view.move_section_left` / `_right` move it. The
//! Rust look is the default — TODOS / NOTES / FINDINGS are sidebar
//! sections there, so they start on the left; the outline and the
//! diagnostics were right-panel panes, so they start on the right.
//!
//! State: `App.side` (`State`). The explorer's own open flag stays
//! `tree.visible` (Rust's `tree_visible`, read all over); `open` is the
//! truth for the rest, and `shown` reconciles the two. Every write goes
//! through `place` / `remove` so the two cannot drift.
//!
//! // changed (section-side): replaces `App.right_panel` (one `PanelId`
//! slot) and the sidebar-or-right-panel split in `render.frameRects`.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PanelId = app_mod.PanelId;
const FocusId = app_mod.FocusId;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Key = @import("../core/key.zig").Key;
const rail = @import("../ui/activity_bar.zig");
const git_palette = @import("git_palette.zig");

pub const Section = rail.Section;
pub const Side = Config.Side;

pub const table = .{
    .@"view.move_section_left" = &moveLeftCmd,
    .@"view.move_section_right" = &moveRightCmd,
};

/// What a section paints in its column. Null: the section opens a
/// pane (search, debug, …) and has no side.
pub const Surface = union(enum) { tree, panel: PanelId };

pub fn surface(s: Section) ?Surface {
    return switch (s) {
        .explorer => .tree,
        .git => .{ .panel = .git },
        .sessions => .{ .panel = .sessions },
        .http => .{ .panel = .http },
        .notes => .{ .panel = .notes },
        .todos => .{ .panel = .todos },
        .findings => .{ .panel = .findings },
        .diagnostics => .{ .panel = .diagnostics },
        .outline => .{ .panel = .outline },
        .search, .debug, .integrations, .agents, .cloud_agents => null,
    };
}

pub fn sectionOfPanel(p: PanelId) Section {
    return switch (p) {
        .todos => .todos,
        .notes => .notes,
        .findings => .findings,
        .sessions => .sessions,
        .git => .git,
        .diagnostics => .diagnostics,
        .http => .http,
        .outline => .outline,
    };
}

/// The focus a shown section holds.
pub fn focusOf(s: Section) ?FocusId {
    const sf = surface(s) orelse return null;
    return switch (sf) {
        .tree => .tree,
        .panel => |p| .{ .panel = p },
    };
}

pub const State = struct {
    /// Where each section lives.
    of: std.EnumArray(Section, Side),
    /// The section each column shows; null is a closed column. The
    /// explorer is shown only while `tree.visible` too (`shown`).
    open: std.EnumArray(Side, ?Section) = .initFill(null),
    /// The section a column showed last — what a toggle brings back.
    last: std.EnumArray(Side, ?Section) = .initFill(null),
    /// The section a column showed before the current one — what the
    /// column falls back to when the current one moves away.
    prev: std.EnumArray(Side, ?Section) = .initFill(null),
    /// The right column's width (`ui.right_panel_width`); the left's
    /// is `tree.width` (`ui.tree_width`).
    right_width: u16 = 32,
    /// vim: a `Ctrl-W` arrived with a panel focused; the next key names
    /// the window move (`ctrlW`).
    ctrl_w_pending: bool = false,

    pub fn init(cfg: *const Config) State {
        var st: State = .{ .of = .initFill(.left) };
        for (Section.all) |s| st.of.set(s, configuredSide(cfg, s));
        st.right_width = @max(cfg.ui.right_panel_width, 8);
        return st;
    }
};

pub fn opposite(s: Side) Side {
    return if (s == .left) .right else .left;
}

/// The config's answer for a section: its `ui.section_side` entry,
/// else `ui.sidebar_side` — the Rust right-panel panes take the other
/// side of that.
pub fn configuredSide(cfg: *const Config, s: Section) Side {
    if (overrideOf(&cfg.ui.section_side, s)) |o| return o;
    return switch (s) {
        .outline, .diagnostics => opposite(cfg.ui.sidebar_side),
        else => cfg.ui.sidebar_side,
    };
}

pub fn overrideOf(ss: *const Config.SectionSide, s: Section) ?Side {
    inline for (@typeInfo(Config.SectionSide).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, @tagName(s))) return @field(ss, f.name);
    }
    return null;
}

pub fn sideOf(app: *const App, s: Section) Side {
    return app.side.of.get(s);
}

/// The section `side` shows, or null when the column is closed.
pub fn shown(app: *const App, side: Side) ?Section {
    const s = app.side.open.get(side) orelse return null;
    if (s == .explorer and !app.tree.visible) return null;
    return s;
}

pub fn isShown(app: *const App, s: Section) bool {
    return shown(app, sideOf(app, s)) == s;
}

pub fn width(app: *const App, side: Side) u16 {
    return switch (side) {
        .left => app.tree.width,
        .right => app.side.right_width,
    };
}

pub fn setWidth(app: *App, side: Side, w: u16) void {
    switch (side) {
        .left => app.tree.width = w,
        .right => app.side.right_width = w,
    }
}

/// The section the keyboard is in, if it is in a column.
pub fn sectionOfFocus(app: *const App) ?Section {
    return switch (app.focus) {
        .tree => .explorer,
        .panel => |p| sectionOfPanel(p),
        .pane, .overlay => null,
    };
}

/// The section's column-relative label for toasts and menus.
pub fn label(s: Section) []const u8 {
    return s.meta().label;
}

/// Put `s` in its column — closing what the column showed — and, with
/// `focus`, hand it the keys. Git mode ends when its palette is the
/// thing being replaced, so the layout it stashed comes back.
pub fn place(app: *App, s: Section, focus: bool) void {
    std.debug.assert(surface(s) != null);
    const side = sideOf(app, s);
    const prev = shown(app, side);
    if (prev != null and prev.? == .git and s != .git and app.git_palette.active) git_palette.leave(app);
    if (prev != null and prev.? != s) app.side.prev.set(side, prev);
    app.side.open.set(side, s);
    app.side.last.set(side, s);
    if (sideOf(app, .explorer) == side) app.tree.visible = s == .explorer;
    if (focus) focusSection(app, s);
    app.needs_render = true;
}

pub fn focusSection(app: *App, s: Section) void {
    const f = focusOf(s) orelse return;
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = f;
    app.needs_render = true;
}

/// Close `s` if its column shows it (the column's own bookkeeping —
/// git mode is left to `hide`). The keys fall back to the active pane.
pub fn remove(app: *App, s: Section) void {
    const side = sideOf(app, s);
    if (app.side.open.get(side) == s) app.side.open.set(side, null);
    if (s == .explorer) app.tree.visible = false;
    if (focusOf(s)) |f| if (std.meta.eql(app.focus, f)) dropFocus(app);
    app.needs_render = true;
}

fn dropFocus(app: *App) void {
    if (app.active) |a| {
        app.focus = .{ .pane = a };
        return;
    }
    for ([_]Side{ .left, .right }) |side| if (shown(app, side)) |s| if (focusOf(s)) |f| {
        app.focus = f;
        return;
    };
    app.focus = .tree;
}

/// Close `s`: git mode ends with its palette.
pub fn hide(app: *App, s: Section) void {
    if (s == .git and app.git_palette.active) return git_palette.leave(app);
    remove(app, s);
}

pub fn hideColumn(app: *App, side: Side) void {
    if (shown(app, side)) |s| hide(app, s);
}

/// The sections that live on `side` and own a surface, in rail order.
pub fn sectionsOn(app: *const App, side: Side, buf: *[Section.all.len]Section) []const Section {
    var n: usize = 0;
    for (Section.all) |s| if (surface(s) != null and sideOf(app, s) == side) {
        buf[n] = s;
        n += 1;
    };
    return buf[0..n];
}

/// Open `s` the way its rail command does (git enters its mode, the
/// keys go to the section).
pub fn show(app: *App, s: Section) CommandError!void {
    const activity_bar = @import("activity_bar.zig");
    // `outline.show` splits while the column is closed (Rust's rule);
    // the column's own walk always wants the column.
    if (s == .outline) return @import("outline.zig").showInColumn(app, true);
    return command.run(app, .{ .static = activity_bar.commandOf(s) });
}

/// Open `s` in its column without taking the keys unless `focus` —
/// a toggle or a tab walk leaves the editor where it is, as Rust's
/// right panel does. Git always enters its mode.
pub fn open(app: *App, s: Section, focus: bool) CommandError!void {
    if (s == .git) return show(app, s);
    if (s == .outline) return @import("outline.zig").showInColumn(app, focus);
    place(app, s, focus);
}

/// `view.toggle_right_panel` / `view.toggle_tree`: close the column, or
/// bring back what it showed last (else the first section on that side).
pub fn toggleColumn(app: *App, side: Side) CommandError!void {
    if (shown(app, side) != null) return hideColumn(app, side);
    var buf: [Section.all.len]Section = undefined;
    const here = sectionsOn(app, side, &buf);
    const s = app.side.last.get(side) orelse (if (here.len > 0) here[0] else null) orelse
        return app.diag.fail(app.frame.allocator(), "nothing lives on the {s} side — right-click a rail icon: Move to {s} side", .{ @tagName(side), @tagName(side) });
    try open(app, s, false);
}

/// The next / previous section along `side`'s list, opened; the keys
/// follow when they were in that column.
pub fn step(app: *App, side: Side, by: isize) CommandError!void {
    var buf: [Section.all.len]Section = undefined;
    const here = sectionsOn(app, side, &buf);
    if (here.len == 0) return app.diag.fail(app.frame.allocator(), "nothing lives on the {s} side", .{@tagName(side)});
    const cur = shown(app, side) orelse return open(app, here[0], false);
    const had_focus = if (focusOf(cur)) |f| std.meta.eql(app.focus, f) else false;
    var idx: usize = 0;
    for (here, 0..) |s, i| if (s == cur) {
        idx = i;
    };
    const n: isize = @intCast(here.len);
    const next: usize = @intCast(@mod(@as(isize, @intCast(idx)) + by, n));
    try open(app, here[next], had_focus);
}

/// Move `s` to `dest`: closed on one side, open on the other, the keys
/// staying with it.
pub fn move(app: *App, s: Section, dest: Side) CommandError!void {
    const arena = app.frame.allocator();
    if (surface(s) == null) return app.diag.fail(arena, "{s} opens as a pane; it has no side", .{label(s)});
    const from = sideOf(app, s);
    if (from == dest) {
        app.toast("{s} is already on the {s}", .{ label(s), @tagName(dest) });
        return;
    }
    const was_shown = isShown(app, s);
    const had_focus = if (focusOf(s)) |f| std.meta.eql(app.focus, f) else false;
    if (was_shown) remove(app, s);
    app.side.of.set(s, dest);
    if (was_shown) place(app, s, had_focus);
    // The vacated column shows what it showed before (the explorer, as
    // a rule) — TODOS on the right beside the tree, not beside a gap.
    if (was_shown and shown(app, from) == null) if (fallbackFor(app, from, s)) |back| place(app, back, false);
    app.toast("{s} → {s} side", .{ label(s), @tagName(dest) });
    app.needs_render = true;
}

/// What a column shows once `gone` has left it: the section it showed
/// before, else the explorer when it lives there. Git is not brought
/// back (its palette is a mode, entered through its command).
fn fallbackFor(app: *const App, side: Side, gone: Section) ?Section {
    if (app.side.prev.get(side)) |p| if (p != gone and p != .git and surface(p) != null and sideOf(app, p) == side) return p;
    if (sideOf(app, .explorer) == side and gone != .explorer) return .explorer;
    return null;
}

/// Re-read every section's side from the config (a `ui.sidebar_side`
/// change): a shown section whose side changed moves.
pub fn reseed(app: *App) void {
    for (Section.all) |s| {
        const want = configuredSide(&app.cfg, s);
        if (want == sideOf(app, s)) continue;
        const was_shown = isShown(app, s);
        const had_focus = if (focusOf(s)) |f| std.meta.eql(app.focus, f) else false;
        if (was_shown) remove(app, s);
        app.side.of.set(s, want);
        if (was_shown) place(app, s, had_focus);
    }
    app.needs_render = true;
}

/// The section the move commands act on: the focused one, else the
/// rail's mark.
fn target(app: *App) Section {
    const activity_bar = @import("activity_bar.zig");
    return sectionOfFocus(app) orelse activity_bar.active(app);
}

fn moveLeftCmd(app: *App) CommandError!void {
    return move(app, target(app), .left);
}

fn moveRightCmd(app: *App) CommandError!void {
    return move(app, target(app), .right);
}

/// Git mode's snap: the palette's column takes a fifth of the screen
/// when that is at least eight cells (Rust `open_git_graph`).
pub fn snapGit(app: *App) void {
    const side = sideOf(app, .git);
    const fifth: u16 = @intCast(@as(u32, app.screen.width) * 20 / 100);
    if (fifth >= 8) setWidth(app, side, fifth);
}

/// vim's `Ctrl-W` family from a column: `w` / `p` / `h` / `j` / `k` /
/// `l` (and the arrows) move on from it the way `Ctrl-L` does; `H` and
/// `L` are Neovim's window moves — the section goes to that edge.
pub fn ctrlWCommand(k: Key) ?command.CommandId {
    return switch (k.code) {
        .char => |c| switch (if (k.mods.ctrl and c < 0x80) @as(u21, std.ascii.toLower(@intCast(c))) else c) {
            'w', 'p' => .@"view.focus_next_split",
            'l' => .@"view.focus_right",
            'h' => .@"view.focus_left",
            'j' => .@"view.focus_down",
            'k' => .@"view.focus_up",
            'H' => .@"view.move_section_left",
            'L' => .@"view.move_section_right",
            else => null,
        },
        .right => .@"view.focus_right",
        .left => .@"view.focus_left",
        .down => .@"view.focus_down",
        .up => .@"view.focus_up",
        else => null,
    };
}

/// A bare `Ctrl-W` under the vim profile.
pub fn isCtrlW(app: *const App, k: Key) bool {
    return app.input_style == .vim and k.mods.ctrl and !k.mods.shift and !k.mods.alt and !k.mods.super and k.code == .char and std.ascii.toLower(@intCast(@min(k.code.char, 0x7F))) == 'w';
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const render = @import("render.zig");
const Rect = @import("../ui/rect.zig");

fn rects(app: *App) render.FrameRects {
    return render.frameRects(Rect.init(0, 0, app.screen.width, app.screen.height), render.chrome(app));
}

test "defaults: every section is on the left but the outline and the diagnostics; the explorer is open on the left, the right column closed" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    for (Section.all) |s| try t.expectEqual(if (s == .outline or s == .diagnostics) Side.right else Side.left, sideOf(&app, s));
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expect(shown(&app, .right) == null);
    const fr = rects(&app);
    try t.expect(fr.sidebar.eql(Rect.init(4, 1, 26, 37)));
    try t.expect(fr.right.isEmpty() and fr.right_divider.isEmpty());
    try t.expect(fr.body.eql(Rect.init(31, 1, 89, 37)));
}

test "configuredSide: the overrides win, then sidebar_side, the Rust right-panel panes on the other side of it" {
    var cfg = Config{};
    try t.expectEqual(Side.left, configuredSide(&cfg, .todos));
    try t.expectEqual(Side.right, configuredSide(&cfg, .outline));
    cfg.ui.sidebar_side = .right;
    try t.expectEqual(Side.right, configuredSide(&cfg, .todos));
    try t.expectEqual(Side.left, configuredSide(&cfg, .diagnostics));
    cfg.ui.section_side.todos = .left;
    cfg.ui.section_side.outline = .right;
    try t.expectEqual(Side.left, configuredSide(&cfg, .todos));
    try t.expectEqual(Side.right, configuredSide(&cfg, .outline));
    const st = State.init(&cfg);
    try t.expectEqual(Side.left, st.of.get(.todos));
    try t.expectEqual(Side.right, st.of.get(.notes));
}

test "move: a shown section closes on one side and opens on the other with the keys; the explorer stays; a pane section has no side; the same side is a no-op" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try t.expectEqual(Section.todos, shown(&app, .left).?);
    try t.expect(!app.tree.visible);
    try t.expect(app.focus == .panel and app.focus.panel == .todos);
    // Left → right: TODOS shows on the right with the keys, and the
    // explorer — what the left column showed before — is back beside it.
    try command.run(&app, .{ .static = .@"view.move_section_right" });
    try t.expectEqual(Side.right, sideOf(&app, .todos));
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expect(app.tree.visible);
    try t.expectEqual(Section.todos, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .todos);
    var fr = rects(&app);
    try t.expect(fr.right.eql(Rect.init(88, 1, 32, 37)));
    try t.expect(fr.right_divider.eql(Rect.init(87, 1, 1, 37)));
    // Closing the left column leaves TODOS alone on the right.
    try command.run(&app, .{ .static = .@"view.toggle_tree" });
    try t.expect(shown(&app, .left) == null);
    fr = rects(&app);
    try t.expect(fr.sidebar.isEmpty());
    try t.expect(fr.body.eql(Rect.init(0, 1, 87, 37)));
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expectEqual(Section.todos, shown(&app, .right).?);
    fr = rects(&app);
    try t.expect(fr.sidebar.eql(Rect.init(4, 1, 26, 37)));
    try t.expect(fr.right.eql(Rect.init(88, 1, 32, 37)));
    try t.expect(fr.body.eql(Rect.init(31, 1, 56, 37)));
    // Back left: TODOS takes the explorer's column; the right column
    // has nothing to fall back to and closes.
    app.focus = .{ .panel = .todos };
    try command.run(&app, .{ .static = .@"view.move_section_left" });
    try t.expectEqual(Section.todos, shown(&app, .left).?);
    try t.expect(shown(&app, .right) == null);
    try t.expect(!app.tree.visible);
    try command.run(&app, .{ .static = .@"view.move_section_left" });
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "already on the left") != null);
    // A closed section moves without opening.
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try t.expect(!isShown(&app, .todos));
    app.focus = .tree;
    try t.expectEqual(Section.explorer, target(&app));
    try move(&app, .notes, .right);
    try t.expectEqual(Side.right, sideOf(&app, .notes));
    try t.expect(shown(&app, .right) == null);
    try t.expectError(error.Failed, move(&app, .search, .right));
}

test "the right column: toggle brings back the last section shown there, else the first on that side; next / prev walk the side; focus opens it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    // Fresh: the diagnostics and the outline live on the right, in
    // section order; the toggle opens the first, the next walks on (the
    // outline lands on the open scratch).
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expectEqual(Section.diagnostics, shown(&app, .right).?);
    // A toggle and a tab walk leave the keys in the editor (Rust's
    // right panel); the keys follow only when they were in the column.
    try t.expect(app.focus == .pane);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(Section.outline, shown(&app, .right).?);
    try t.expect(app.outline_panel != null);
    try t.expect(app.focus == .pane);
    focusSection(&app, .outline);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(Section.diagnostics, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .diagnostics);
    try command.run(&app, .{ .static = .@"view.right_panel_prev_tab" });
    try t.expectEqual(Section.outline, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .outline);
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expect(shown(&app, .right) == null);
    try t.expect(app.focus == .pane);
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expectEqual(Section.outline, shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_close_tab" });
    try t.expect(shown(&app, .right) == null);
    try command.run(&app, .{ .static = .@"view.focus_right_panel" });
    try t.expectEqual(Section.outline, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .outline);
    // With TODOS moved right it joins the walk, in section order.
    try move(&app, .todos, .right);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(Section.todos, shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_next_tab" });
    try t.expectEqual(Section.diagnostics, shown(&app, .right).?);
    try command.run(&app, .{ .static = .@"view.right_panel_prev_tab" });
    try t.expectEqual(Section.todos, shown(&app, .right).?);
}

test "layout: sections on one side, both sides, none; the right column keeps the panes 21 columns and floors at 8" {
    // None: the whole width is the body.
    const none = render.frameRects(Rect.init(0, 0, 120, 40), .{});
    try t.expect(none.sidebar.isEmpty() and none.right.isEmpty());
    try t.expect(none.body.eql(Rect.init(0, 1, 120, 37)));
    // Right only: no rail (it rides the left column), the divider at 79.
    const right = render.frameRects(Rect.init(0, 0, 120, 40), .{ .right = 40 });
    try t.expect(right.sidebar.isEmpty() and right.rail.isEmpty());
    try t.expect(right.right.eql(Rect.init(80, 1, 40, 37)));
    try t.expect(right.right_divider.eql(Rect.init(79, 1, 1, 37)));
    try t.expect(right.body.eql(Rect.init(0, 1, 79, 37)));
    // Both: 30 on the left (rail 3 + border + 26), 40 on the right.
    const both = render.frameRects(Rect.init(0, 0, 120, 40), .{ .sidebar = 30, .right = 40 });
    try t.expect(both.rail.eql(Rect.init(0, 1, 3, 37)));
    try t.expect(both.sidebar.eql(Rect.init(4, 1, 26, 37)));
    try t.expect(both.sidebar_divider.eql(Rect.init(30, 1, 1, 37)));
    try t.expect(both.right_divider.eql(Rect.init(79, 1, 1, 37)));
    try t.expect(both.right.eql(Rect.init(80, 1, 40, 37)));
    try t.expect(both.body.eql(Rect.init(31, 1, 48, 37)));
    // A wide right column is clamped so the panes keep 21 cells.
    // (Rust's clamp counts the divider inside the 21: the panes keep 20.)
    const wide = render.frameRects(Rect.init(0, 0, 120, 40), .{ .sidebar = 30, .right = 100 });
    try t.expect(wide.right.w == 89 - 21);
    try t.expect(wide.body.w == 20);
    // Too narrow for a right column: none is carved.
    const tiny = render.frameRects(Rect.init(0, 0, 60, 40), .{ .sidebar = 30, .right = 40 });
    try t.expect(tiny.right.isEmpty());
    try t.expect(tiny.body.eql(Rect.init(31, 1, 29, 37)));
}

test "ctrlWCommand: the vim window family from a column, H / L the section moves" {
    try t.expectEqual(command.CommandId.@"view.focus_left", ctrlWCommand(Key.char('h')).?);
    try t.expectEqual(command.CommandId.@"view.move_section_left", ctrlWCommand(Key.char('H')).?);
    try t.expectEqual(command.CommandId.@"view.move_section_right", ctrlWCommand(Key.char('L')).?);
    try t.expectEqual(command.CommandId.@"view.focus_next_split", ctrlWCommand(Key.char('w')).?);
    try t.expectEqual(command.CommandId.@"view.focus_up", ctrlWCommand(Key.named(.up)).?);
    try t.expect(ctrlWCommand(Key.char('x')) == null);
}

test "vim: ctrl+w L on a focused TODOS panel moves it to the right edge; ctrl+w H on the tree moves the explorer to the left (a no-op there); an editor keeps the split meaning" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try app.handle(.{ .key = Key.ctrl('w') });
    try t.expect(app.side.ctrl_w_pending);
    try app.handle(.{ .key = Key.char('L') });
    try t.expectEqual(Side.right, sideOf(&app, .todos));
    try t.expectEqual(Section.todos, shown(&app, .right).?);
    try t.expect(app.focus == .panel and app.focus.panel == .todos);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('H') });
    try t.expectEqual(Side.left, sideOf(&app, .todos));
    try t.expectEqual(Section.todos, shown(&app, .left).?);
    // The tree: its own pending flag, the same table.
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('L') });
    try t.expectEqual(Side.right, sideOf(&app, .explorer));
    try t.expectEqual(Section.explorer, shown(&app, .right).?);
    try t.expect(app.tree.visible);
    try t.expect(app.focus == .tree);
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('H') });
    try t.expectEqual(Side.left, sideOf(&app, .explorer));
    // An editor: `Ctrl-W L` is the split move, not a section move.
    app.focus = .{ .pane = app.active.? };
    try app.handle(.{ .key = Key.ctrl('w') });
    try app.handle(.{ .key = Key.char('L') });
    try t.expectEqual(Side.left, sideOf(&app, .explorer));
    try t.expectEqual(Side.left, sideOf(&app, .todos));
}

test "git mode follows its section's side: on the right, entering snaps the right column to a fifth and the palette paints there; leaving puts the explorer back only on its own side" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    try move(&app, .git, .right);
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try t.expect(app.git_palette.active);
    try t.expectEqual(Section.git, shown(&app, .right).?);
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    try t.expectEqual(@as(u16, 24), app.side.right_width);
    try t.expectEqual(@as(u16, 30), app.tree.width);
    const fr = rects(&app);
    try t.expect(fr.right.eql(Rect.init(96, 1, 24, 37)));
    try command.run(&app, .{ .static = .@"view.toggle_right_panel" });
    try t.expect(!app.git_palette.active);
    try t.expect(shown(&app, .right) == null);
    try t.expectEqual(Section.explorer, shown(&app, .left).?);
    // On the left (the default) the snap is the tree's width, as before.
    try move(&app, .git, .left);
    try command.run(&app, .{ .static = .@"view.activity_git" });
    try t.expectEqual(Section.git, shown(&app, .left).?);
    try t.expectEqual(@as(u16, 24), app.tree.width);
    try t.expect(!app.tree.visible);
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try t.expect(!app.git_palette.active);
    try t.expectEqual(Section.todos, shown(&app, .left).?);
}
