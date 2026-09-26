//! The activity bar's side of the app: which section the rail marks,
//! what a click on it does, its hover copy, and `ui.activity_bar`
//! (`always` / `auto` / `hidden` — the menu bar's three words, per the
//! Rust header's own TODO). The painter is `ui/activity_bar.zig`;
//! `render.frameRects` carves its rect off the sidebar.
//!
//! Rust keeps `active_section` as state and swaps the sidebar's content
//! on it. Here the sections already have surfaces of their own — a
//! column (`app/side.zig`), a pane — so the marked section is read off
//! them: the focused surface first, then the right column, then the
//! left. A click runs the section's `view.activity_*` command, the
//! same id the right-click menu's first row names, so the palette and
//! the rail cannot drift apart.
//!
//! // changed: `view.activity_debug` had a spec and no runner; it runs
//! here (the DAP section). `view.activity_bar_cycle` is Zig-only, the
//! twin of `view.menu_bar_cycle`.
//! // changed (sessions-merge): the AGENTS and CLOUD AGENTS sections are
//! gone; `view.activity_agents` opens the sessions table and
//! `view.activity_cloud_agents` the SESSIONS section, so scripts naming
//! them keep working.
//!
//! // changed (railmove): **the activity bar is for panels, the launcher
//! dock is for launchers** — two strips split by kind
//! (`ui/activity_bar.zig`'s `StripKind`), with two membership knobs.
//! `ui.rail.hidden` is the sections the bar leaves out (`setHidden`);
//! `ui.dock.pins` is what the dock carries besides its launchers, and
//! a section's `view.activity_*` command pinned there is what *Show on
//! dock instead* means (`showOnDock`) — the dock lists it as a
//! `.pinned_panel`, and *Move back to activity bar* (`moveBackFromDock`)
//! is the way home. A hidden section keeps its command and its keys:
//! hiding a row hides a ROW.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const PanelId = app_mod.PanelId;
const Config = @import("../config/Config.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Mouse = @import("../core/key.zig").Mouse;
const rail = @import("../ui/activity_bar.zig");
const hover_zones = @import("hover_zones.zig");
const tooltip = @import("../ui/tooltip.zig");
const context_menus = @import("context_menus.zig");
const settings = @import("settings.zig");
const side = @import("side.zig");
const git_palette = @import("git_palette.zig");
const http_panel = @import("http_panel.zig");
const integrations = @import("integrations.zig");
const script_section = @import("script_section.zig");

pub const Section = rail.Section;
pub const Part = rail.Part;

pub const table = .{
    .@"view.activity_debug" = &activityDebug,
    .@"view.activity_agents" = &activityAgents,
    .@"view.activity_cloud_agents" = &activityCloudAgents,
    .@"view.activity_bar_cycle" = &cycleCmd,
    .@"view.rail_hide_section" = &hideSectionCmd,
    .@"view.rail_show_on_dock" = &showOnDockCmd,
    .@"view.rail_show_sections" = &showSectionsCmd,
};

/// // changed (railmove): `ui.rail.hidden` after a hide / show, owned
/// here so the config field cannot dangle — `integrations.State`'s
/// `dock_pins_owned` is the pattern.
pub const State = struct {
    hidden_owned: ?[]Config.RailSection = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.hidden_owned) |h| gpa.free(h);
        self.hidden_owned = null;
    }
};

// ─── membership: ui.rail.hidden ─────────────────────────────────────────

/// A rail section as the config spells it — null for the two that
/// have no rail row and for a script's section.
pub fn toRail(s: Section) ?Config.RailSection {
    return std.meta.stringToEnum(Config.RailSection, @tagName(s));
}

pub fn fromRail(r: Config.RailSection) Section {
    // Every `RailSection` tag is a `Section.rail` tag — the test below
    // holds the two lists together — so this cannot miss.
    return std.meta.stringToEnum(Section, @tagName(r)).?;
}

/// Whether `ui.rail.hidden` names `s`.
pub fn isHidden(app: *const App, s: Section) bool {
    const r = toRail(s) orelse return false;
    for (app.cfg.ui.rail.hidden) |h| if (h == r) return true;
    return false;
}

/// The hidden sections, in the rail's own order, on `arena`.
pub fn hiddenSections(app: *const App, arena: Allocator) Allocator.Error![]const Section {
    var out: std.ArrayListUnmanaged(Section) = .empty;
    for (Section.rail) |s| if (isHidden(app, s)) try out.append(arena, s);
    return out.toOwnedSlice(arena);
}

/// The section a `view.activity_*` command id opens — how the dock
/// knows a pin is a section (`launcher_dock.Kind.pinned_panel`).
pub fn sectionOfCommandName(id: []const u8) ?Section {
    for (Section.rail) |s| {
        const c = commandOf(s) orelse continue;
        if (std.mem.eql(u8, command.name(c), id)) return s;
    }
    return null;
}

/// Put `s` into, or take it out of, `ui.rail.hidden`; write it home.
/// A hidden section's column stays exactly as it was — hiding a row
/// hides a row, and the section's command and keys still open it.
pub fn setHidden(app: *App, s: Section, hide: bool) CommandError!void {
    const arena = app.frame.allocator();
    if (toRail(s) == null) return app.diag.fail(arena, "activity bar: {s} has no rail row to hide", .{s.meta().label});
    if (isHidden(app, s) == hide) {
        app.toast("{s}: already {s} the activity bar", .{ s.meta().label, if (hide) "hidden from" else "on" });
        return;
    }
    var next: std.ArrayListUnmanaged(Config.RailSection) = .empty;
    // Kept in the rail's order, so the file reads top to bottom.
    for (Section.rail) |sec| {
        const sr = toRail(sec) orelse continue;
        const was = isHidden(app, sec);
        if (if (sec == s) hide else was) try next.append(arena, sr);
    }
    try setHiddenList(app, next.items);
    if (hide) {
        const cmd = if (commandOf(s)) |c| command.name(c) else "its command";
        app.toast("{s}: hidden from the activity bar — {s} still opens it", .{ s.meta().label, cmd });
    } else {
        app.toast("{s}: back on the activity bar", .{s.meta().label});
    }
}

/// The new `ui.rail.hidden`, gpa-owned by `App.activity_bar` and
/// persisted home.
fn setHiddenList(app: *App, list: []const Config.RailSection) Allocator.Error!void {
    const gpa = app.gpa;
    const owned = try gpa.dupe(Config.RailSection, list);
    app.activity_bar.deinit(gpa);
    app.activity_bar.hidden_owned = owned;
    app.cfg.ui.rail.hidden = owned;
    _ = try settings.persist(app, .home, &.{ "ui", "rail", "hidden" }, app.cfg.ui.rail.hidden);
    app.needs_render = true;
}

/// *Show on dock instead*: pin the section's command onto the launcher
/// dock, then hide its rail row. The pin goes first, so a section with
/// no command (a script's) is refused before anything is hidden.
pub fn showOnDock(app: *App, s: Section) CommandError!void {
    const arena = app.frame.allocator();
    const c = commandOf(s) orelse return app.diag.fail(arena, "activity bar: {s} has no command to pin", .{s.meta().label});
    const id = command.name(c);
    if (!integrations.isPinnedToDock(app, id)) try integrations.pinDockId(app, id);
    if (!isHidden(app, s)) try setHidden(app, s, true);
    app.toast("{s}: on the launcher dock now — its row is off the activity bar", .{s.meta().label});
}

/// *Move back to activity bar*: the reverse — the row back, the pin off.
pub fn moveBackFromDock(app: *App, s: Section) CommandError!void {
    if (commandOf(s)) |c| {
        const id = command.name(c);
        if (integrations.isPinnedToDock(app, id)) try integrations.unpinDockId(app, id);
    }
    if (isHidden(app, s)) try setHidden(app, s, false);
    app.toast("{s}: back on the activity bar", .{s.meta().label});
}

/// `view.rail_hide_section`: the marked section leaves the bar.
fn hideSectionCmd(app: *App) CommandError!void {
    return setHidden(app, active(app), true);
}

/// `view.rail_show_on_dock`: the marked section moves to the dock.
fn showOnDockCmd(app: *App) CommandError!void {
    return showOnDock(app, active(app));
}

/// `view.rail_show_sections`: every hidden section back on the bar.
/// The dock keeps whatever was pinned there — a pin is the dock's own
/// business, and *Move back* on the item takes it off.
fn showSectionsCmd(app: *App) CommandError!void {
    if (app.cfg.ui.rail.hidden.len == 0) {
        app.toast("activity bar: nothing is hidden", .{});
        return;
    }
    try setHiddenList(app, &.{});
    app.toast("activity bar: every section is shown", .{});
}

/// The screen row section `s` sits on at the last frame's geometry, or
/// null when it is hidden or off the bottom — for the tests, which can
/// no longer take a row off `Section`'s ordinal.
pub fn rowY(app: *App, area: Rect, s: Section) Allocator.Error!?u16 {
    const arena = app.frame.allocator();
    const p = try props(app, arena);
    var buf: [Section.rail.len]rail.RailRow = undefined;
    const rows: []const rail.RailRow = if (p.rows.len > 0) p.rows else rail.defaultRows(&buf, p.hidden);
    const lay = rail.layoutRows(area, rows.len + p.pins.len);
    for (rows, 0..) |rr, i| if (rr == .section and rr.section == s) return lay.ordinalY(i);
    return null;
}

/// The badge pulse (Rust): the glyph for four seconds, the count for one.
const pulse_icon_ms: i64 = 4000;
const pulse_period_ms: i64 = 5000;

/// The section's palette command — what a click runs and what the
/// right-click menu's first row names.
/// Null for a script's section: it has no static id — a click goes
/// through `script_section.show` instead (`app/script_section.zig`).
pub fn commandOf(s: Section) ?command.CommandId {
    return switch (s) {
        .script => null,
        .explorer => .@"view.activity_explorer",
        .search => .@"view.activity_search",
        .git => .@"view.activity_git",
        .debug => .@"view.activity_debug",
        .integrations => .@"view.activity_integrations",
        .sessions => .@"view.activity_sessions",
        .http => .@"view.activity_http",
        .notes => .@"view.activity_notes",
        .todos => .@"view.activity_todos",
        .findings => .@"view.activity_findings",
        .scripts => .@"view.activity_scripts",
        .diagnostics => .@"lsp.diagnostics",
        .outline => .@"outline.show",
    };
}

/// Whether the rail paints this frame. `auto`: the pointer in column 0
/// reveals it, and it stays while the pointer rests on it.
/// // changed (sidebar-autohide): the two rects — column 0 and the
/// rail's own — are now zones registered with `hover_zones`, which
/// arbitrates them against the menu bar's row and the side columns'
/// edges. Same rects, same instant dwell; what changed is the top-left
/// cell, which the menu bar now wins outright, and column 0 under
/// `ui.sidebar = .auto`, which belongs to the column the pointer is
/// asking for (the rail comes back inside it).
pub fn shown(app: *const App) bool {
    return switch (app.cfg.ui.activity_bar) {
        .always => true,
        .hidden => false,
        .auto => hover_zones.dwelled(app, .rail_left),
    };
}

/// The section the rail marks. Git mode is a state (Rust's
/// `active_section == Git`): while it is on, the mark is Git whatever
/// has the focus.
pub fn active(app: *App) Section {
    if (app.git_palette.active) return .git;
    switch (app.focus) {
        .tree => return .explorer,
        .panel => |p| if (onRail(side.sectionOfPanel(p))) |s| return s,
        // A pane that belongs to a section (a grep results pane is
        // Search's) takes the mark only while no column shows another
        // section: the rail and the column must not disagree about
        // what is up (round-7 hunt: Ctrl+Shift+F lit Search over the
        // Explorer tree).
        .pane => |id| if (sectionOfPane(app, id)) |s| {
            if (shownOnRail(app) == null) return s;
        },
        .overlay, .welcome, .info_view => {},
    }
    if (shownOnRail(app)) |s| return s;
    if (app.active) |id| if (sectionOfPane(app, id)) |s| return s;
    return .explorer;
}

/// A rail section a column shows, the right one first.
fn shownOnRail(app: *App) ?Section {
    if (side.shown(app, .right)) |s| if (onRail(s)) |r| return r;
    if (side.shown(app, .left)) |s| if (onRail(s)) |r| return r;
    return null;
}

/// The hidden sections (the outline, the diagnostics — Rust's
/// right-panel panes) never take the mark.
fn onRail(s: Section) ?Section {
    for (Section.rail) |r| if (r == s) return s;
    return null;
}

fn sectionOfPane(app: *App, id: PaneId) ?Section {
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .grep => .search,
        .debug => .debug,
        .sessions_table => .sessions,
        .integrations => .integrations,
        // Rust keeps the rail marker on Files for the status pane; only
        // the graph (git mode) moves it to Git.
        .git_graph => .git,
        else => null,
    };
}

/// Every `view.activity_*` runner's first line: entering a section
/// other than Git leaves git mode (Rust `set_activity_section`'s
/// `leaving_git`), which puts the stashed layout back.
pub fn enter(app: *App, s: Section) void {
    if (s != .git) git_palette.leave(app);
    if (s != .http) http_panel.leave(app) catch {};
}

/// What the painter needs this frame. The pins are the chips
/// `ui.activity_bar_pinned_integrations` names, in that order, on the
/// frame arena; an id no chip answers to is skipped, as Rust skips it.
pub fn props(app: *App, arena: Allocator) Allocator.Error!rail.Props {
    const pinned = try integrations.pinnedChips(app, arena);
    const pins = try arena.alloc(rail.Pin, pinned.len);
    for (pinned, 0..) |pc, i| pins[i] = .{ .glyph = pc.chip.glyph, .fallback = pc.chip.fallback, .color = pc.chip.color };
    // // changed (lua-plumbing): the script sections' own rail rows,
    // spliced into the built-in order at the place their `after` names.
    // // changed (railmove): both orders drop `ui.rail.hidden`.
    const hidden = try hiddenSections(app, arena);
    const scripts = try script_section.railRows(app, arena);
    const rows = if (scripts.len == 0) &.{} else try rail.railOrder(arena, scripts, hidden);
    var p: rail.Props = .{
        .active = active(app),
        .active_script = app.script_sections.active,
        .scripts = scripts,
        .rows = rows,
        .hidden = hidden,
        .pins = pins,
        .show_counts = @mod(app.now_ms, pulse_period_ms) >= pulse_icon_ms,
    };
    for (Section.all) |s| p.badges[@intFromEnum(s)] = app.ipc_fx.badge(s.badgeKey());
    return p;
}

/// A press on the rail: left shows the section (the gear opens
/// Settings; a pinned icon fires its chip's command), right opens its
/// menu. Wheel and motion do nothing.
pub fn mouse(app: *App, part: Part, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (part) {
        .section => |s| switch (m.button) {
            .left => try show(app, s),
            .right => try context_menus.openRailMenu(app, s, m.x, m.y),
            else => {},
        },
        .gear => switch (m.button) {
            .left => try run(app, .@"view.settings"),
            .right => try context_menus.openGearMenu(app, m.x, m.y),
            else => {},
        },
        .pin => |i| switch (m.button) {
            .left => try integrations.pinClick(app, i),
            .right => try integrations.openPinMenu(app, i, m.x, m.y),
            else => {},
        },
        // // changed (lua-plumbing): a script section's own rail row.
        .script => |i| switch (m.button) {
            .left => script_section.show(app, i, true),
            .right => {
                script_section.show(app, i, false);
                try context_menus.openRailMenu(app, .script, m.x, m.y);
            },
            else => {},
        },
    }
}

pub fn show(app: *App, s: Section) Allocator.Error!void {
    if (commandOf(s)) |id| return run(app, id);
    script_section.show(app, app.script_sections.active, true);
}

fn run(app: *App, id: command.CommandId) Allocator.Error!void {
    command.run(app, .{ .static = id }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// `describe` with the app at hand: a pinned icon's tip names its chip.
pub fn describeIn(app: *App, arena: Allocator, part: Part) Allocator.Error!tooltip.Tip {
    switch (part) {
        .pin => |i| {
            const pins = try integrations.pinnedChips(app, arena);
            if (i >= pins.len) return .{ .title = "Pinned launcher", .detail = "click runs it · right-click: menu" };
            return .{ .title = pins[i].chip.tooltip, .detail = "click runs the integration's command · right-click: menu" };
        },
        else => return describe(part),
    }
}

/// The hover copy (Rust `ui/tooltip.rs`): what a click shows, and what
/// the section holds.
pub fn describe(part: Part) tooltip.Tip {
    return switch (part) {
        .pin => .{ .title = "Pinned launcher", .detail = "click runs it · right-click: menu" },
        .gear => .{ .title = "Settings", .detail = "click opens Settings · right-click: Settings / Command Palette / Cheatsheet / Themes / About" },
        .script => .{ .title = "Script section", .detail = "click: the section a script registered · right-click: menu" },
        .section => |s| .{ .title = s.meta().label, .detail = switch (s) {
            .explorer => "click: Files rail · workspace file tree · new file / folder · right-click: menu",
            .search => "click: Search rail · ripgrep across the workspace · right-click: menu",
            .git => "click: Git rail · status · commits · branches · worktrees · stash · right-click: menu",
            .debug => "click: Debug rail · variables · watch · call stack · breakpoints · right-click: menu",
            .integrations => "click: Integrations rail · browser / mixr / integration tools · + to add · right-click: menu",
            .sessions => "click: Sessions rail · Claude Code / Codex sessions, the cloud runs · t opens the table · right-click: menu",
            .http => "click: HTTP rail · requests · recent · captured · envs · collections · right-click: menu",
            .notes => "click: Notes rail · .mnml/notes/*.md persistent scratch · right-click: menu",
            .todos => "click: TODOs rail · TODO / FIXME / XXX / HACK / REVIEW hits · right-click: menu",
            .script => "click: this script's section · its rows, filter, sort and folds · right-click: menu",
            .findings => "click: Findings rail · .mnml/findings/*.md tester / review reports · right-click: menu",
            .scripts => "click: Scripts rail · what init.lua registered, with file:line · ⟳ reloads · right-click: menu",
            .diagnostics => "click: Diagnostics · the language servers' problems list",
            .outline => "click: Outline · the symbols of the active file",
        } },
    };
}

// ─── the runners ────────────────────────────────────────────────────────

/// `view.activity_debug`: the DEBUG section in its column, the keys
/// with it (`ctrl+shift+d`). The console pane is `dap.show` / `dap.repl`.
fn activityDebug(app: *App) CommandError!void {
    enter(app, .debug);
    side.place(app, .debug, true);
}

/// `view.activity_agents`: an alias — the sessions table.
fn activityAgents(app: *App) CommandError!void {
    enter(app, .sessions);
    return command.run(app, .{ .static = .@"sessions.table" });
}

/// `view.activity_cloud_agents`: an alias — the SESSIONS section, where
/// the cloud rows list.
fn activityCloudAgents(app: *App) CommandError!void {
    enter(app, .sessions);
    return command.run(app, .{ .static = .@"view.activity_sessions" });
}

/// `view.activity_bar_cycle`: always → auto → hidden → always, persisted.
fn cycleCmd(app: *App) CommandError!void {
    const next: Config.ActivityBar = switch (app.cfg.ui.activity_bar) {
        .always => .auto,
        .auto => .hidden,
        .hidden => .always,
    };
    app.cfg.ui.activity_bar = next;
    _ = try settings.persist(app, .home, &.{ "ui", "activity_bar" }, next);
    app.toast("activity bar: {s}", .{@tagName(next)});
    app.needs_render = true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const screen_mod = @import("../ipc/screen.zig");
const render = @import("render.zig");
const Rect = @import("../ui/rect.zig");
const config_mod = @import("../config/root.zig");

fn testApp(tmp: *std.testing.TmpDir, buf: []u8) !App {
    const n = try tmp.dir.realPath(t.io, buf);
    return App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n], .data_root = buf[0..n], .cols = 120, .rows = 40 });
}

/// The rail's rect at the last render, from `frameRects`.
fn railRect(app: *App) Rect {
    return render.frameRects(Rect.init(0, 0, app.screen.width, app.screen.height), render.chrome(app)).rail;
}

fn sectionRow(app: *App, s: Section) u16 {
    return rail.layout(railRect(app), app.cfg.ui.activity_bar_pinned_integrations.len).sectionY(s).?;
}

/// Whether the last frame registered any rail hit.
fn hasRail(app: *const App) bool {
    for (app.hits.items.items) |e| if (e.target == .rail) return true;
    return false;
}

fn press(app: *App, x: u16, y: u16, button: @import("../core/key.zig").MouseButton) !void {
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .press, .button = button } });
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .release, .button = button } });
}

test "the rail: every section and the gear have a hit in columns 0..2; the indicator follows the focused surface; a left click shows the section, a right click opens its menu; the gear opens Settings" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.render();
    const r = railRect(&app);
    try t.expect(r.eql(Rect.init(0, 1, rail.width, 37)));
    // The border column beside it, in the tree's own rows.
    try t.expectEqualStrings("│", app.screen.readCell(3, 2).?.char.grapheme);
    for (Section.rail) |s| {
        const y = sectionRow(&app, s);
        try t.expectEqual(s, app.hits.at(0, y).?.rail.section);
        try t.expectEqual(s, app.hits.at(2, y).?.rail.section);
    }
    try t.expect(app.hits.at(1, 36).?.rail == .gear);
    // Fresh: the tree has focus, Explorer is marked.
    try t.expectEqual(Section.explorer, active(&app));
    try t.expectEqualStrings("▌", app.screen.readCell(0, sectionRow(&app, .explorer)).?.char.grapheme);
    try t.expectEqualStrings(" ", app.screen.readCell(0, sectionRow(&app, .todos)).?.char.grapheme);
    // Click TODOs: it takes the tree's column (a left section, as in
    // Rust), the mark moves.
    try press(&app, 1, sectionRow(&app, .todos), .left);
    try t.expectEqual(Section.todos, side.shown(&app, .left).?);
    try t.expect(!app.tree.visible);
    try t.expectEqual(Section.todos, active(&app));
    try app.render();
    try t.expectEqualStrings("▌", app.screen.readCell(0, sectionRow(&app, .todos)).?.char.grapheme);
    try t.expectEqualStrings(" ", app.screen.readCell(0, sectionRow(&app, .explorer)).?.char.grapheme);
    // Notes on the right, then Explorer: the tree takes focus back and
    // the mark with it, NOTES staying open on the right.
    try side.move(&app, .notes, .right);
    try press(&app, 1, sectionRow(&app, .notes), .left);
    try t.expectEqual(Section.notes, side.shown(&app, .right).?);
    try t.expectEqual(Section.notes, active(&app));
    try press(&app, 1, sectionRow(&app, .explorer), .left);
    try t.expect(app.focus == .tree);
    try t.expectEqual(Section.explorer, active(&app));
    try t.expectEqual(Section.notes, side.shown(&app, .right).?);
    // Debug: a column section as well.
    try press(&app, 1, sectionRow(&app, .debug), .left);
    try t.expectEqual(Section.debug, active(&app));
    // Right-click: the section's menu, "Show X" first, then its verbs.
    try press(&app, 1, sectionRow(&app, .git), .right);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Source control", app.overlay.menu.title);
    try t.expectEqualStrings("Show Source control", app.overlay.menu.items[0].label);
    try t.expectEqual(command.CommandId.@"view.activity_git", app.overlay.menu.items[0].action.command);
    // // changed (bottom-dock): two move rows — the other column and
    // the dock — so a section's own verbs start at item 3.
    try t.expectEqualStrings("Move to right side", app.overlay.menu.items[1].label);
    try t.expectEqual(Section.git, app.overlay.menu.items[1].action.move_section.section);
    try t.expectEqual(Config.Side.right, app.overlay.menu.items[1].action.move_section.side);
    try t.expectEqualStrings("Move to bottom dock", app.overlay.menu.items[2].label);
    try t.expectEqual(Config.Side.bottom, app.overlay.menu.items[2].action.move_section.side);
    try t.expectEqualStrings("Open git graph", app.overlay.menu.items[3].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try press(&app, 1, sectionRow(&app, .http), .right);
    try t.expectEqualStrings("+ New request", app.overlay.menu.items[3].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // A section on the right offers the way back; SEARCH is a column
    // section too (// changed (search-section)), its verbs after the move.
    try press(&app, 1, sectionRow(&app, .notes), .right);
    try t.expectEqualStrings("Move to left side", app.overlay.menu.items[1].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try press(&app, 1, sectionRow(&app, .search), .right);
    try t.expectEqualStrings("Move to right side", app.overlay.menu.items[1].label);
    try t.expectEqualStrings("Move to bottom dock", app.overlay.menu.items[2].label);
    try t.expectEqualStrings("Refresh", app.overlay.menu.items[3].label);
    try t.expectEqualStrings("Open as pane", app.overlay.menu.items[4].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // The gear: Settings on the left, the mnml menu on the right.
    try press(&app, 1, 36, .right);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("mnml", app.overlay.menu.title);
    try t.expectEqualStrings("Settings…", app.overlay.menu.items[0].label);
    try t.expectEqualStrings("About mnml", app.overlay.menu.items[4].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try press(&app, 1, 36, .left);
    try t.expect(app.overlay == .settings);
}

test "ui.activity_bar: hidden gives the tree the columns back; auto paints the rail only with the pointer in column 0 or on the rail; cycle persists" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    try app.render();
    try t.expect(hasRail(&app));
    try t.expectEqualStrings("│", app.screen.readCell(3, 2).?.char.grapheme);
    app.cfg.ui.activity_bar = .hidden;
    try app.render();
    try t.expect(railRect(&app).isEmpty());
    try t.expect(!hasRail(&app));
    // The tree paints from column 0; its divider has not moved.
    try t.expect(!std.mem.eql(u8, "│", app.screen.readCell(3, 2).?.char.grapheme));
    try t.expect(app.hits.at(30, 2).? == .divider);
    // Auto: nothing until the pointer reaches column 0.
    app.cfg.ui.activity_bar = .auto;
    try app.render();
    try t.expect(!hasRail(&app));
    try app.handle(.{ .mouse = .{ .x = 0, .y = 10, .kind = .motion } });
    try app.render();
    try t.expect(hasRail(&app));
    // It stays while the pointer is on it, and goes when it leaves.
    try app.handle(.{ .mouse = .{ .x = 2, .y = 12, .kind = .motion } });
    try app.render();
    try t.expect(hasRail(&app));
    try app.handle(.{ .mouse = .{ .x = 20, .y = 12, .kind = .motion } });
    try app.render();
    try t.expect(!hasRail(&app));
    // Cycle: auto → hidden → always, written to the home config.
    try command.run(&app, .{ .static = .@"view.activity_bar_cycle" });
    try t.expectEqual(Config.ActivityBar.hidden, app.cfg.ui.activity_bar);
    try command.run(&app, .{ .static = .@"view.activity_bar_cycle" });
    try t.expectEqual(Config.ActivityBar.always, app.cfg.ui.activity_bar);
    // Owned: `configPath` answers on the frame arena, and the steps
    // below render frames before it is read again.
    const home = try t.allocator.dupe(u8, (try settings.configPath(&app, .home)).?);
    defer t.allocator.free(home);
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".activity_bar = .always") != null);
}

test "Config.RailSection spells exactly the rail's rows — the config layer and the painter cannot drift" {
    try t.expectEqual(Section.rail.len, std.enums.values(Config.RailSection).len);
    for (Section.rail, std.enums.values(Config.RailSection)) |s, r| {
        try t.expectEqualStrings(@tagName(s), @tagName(r));
        try t.expectEqual(s, fromRail(r));
        try t.expectEqual(r, toRail(s).?);
    }
    try t.expect(toRail(.script) == null);
    try t.expect(toRail(.outline) == null);
    try t.expectEqual(Section.todos, sectionOfCommandName("view.activity_todos").?);
    try t.expect(sectionOfCommandName("picker.files") == null);
}

test "ui.rail.hidden: a hidden section has no rail row and the rows close up; it persists and reloads; its command still opens it; Show on dock pins it and the dock lists a pinned panel; Move back restores; the menus carry the rows" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try testApp(&tmp, &buf);
    defer app.deinit();
    const launcher_dock = @import("launcher_dock.zig");
    try app.render();
    const todos_y = sectionRow(&app, .todos);
    const findings_y = sectionRow(&app, .findings);
    try t.expectEqual(todos_y, (try rowY(&app, railRect(&app), .todos)).?);
    // Hide TODOs: no row, no hit; FINDINGS moves up into its row.
    try setHidden(&app, .todos, true);
    try t.expect(isHidden(&app, .todos));
    try app.render();
    try t.expect((try rowY(&app, railRect(&app), .todos)) == null);
    try t.expectEqual(todos_y, (try rowY(&app, railRect(&app), .findings)).?);
    try t.expectEqual(Section.findings, app.hits.at(1, todos_y).?.rail.section);
    try t.expect(app.hits.at(1, findings_y) == null or app.hits.at(1, findings_y).? != .rail or app.hits.at(1, findings_y).?.rail != .section or app.hits.at(1, findings_y).?.rail.section != .todos);
    for (app.hits.items.items) |e| if (e.target == .rail and e.target.rail == .section) try t.expect(e.target.rail.section != .todos);
    // Persisted home, and a fresh App on the same root reads it back.
    // Owned: `configPath` answers on the frame arena, and the steps
    // below render frames before it is read again.
    const home = try t.allocator.dupe(u8, (try settings.configPath(&app, .home)).?);
    defer t.allocator.free(home);
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".hidden = ") != null);
    try t.expect(std.mem.indexOf(u8, text, ".todos") != null);
    // The real loader reads it back — the enum slice survives the
    // layer parse and the patch overlay (`config/patch.zig`).
    {
        var vars = std.process.Environ.Map.init(t.allocator);
        defer vars.deinit();
        try vars.put("MNML_DATA_ROOT", app.data_root);
        var loaded = try config_mod.load.load(t.allocator, t.io, .{ .workspace = app.workspace, .env = .{ .vars = &vars } });
        defer loaded.deinit();
        try t.expectEqualStrings(home, loaded.home_path.?);
        try t.expectEqual(@as(usize, 1), loaded.config.ui.rail.hidden.len);
        try t.expectEqual(Config.RailSection.todos, loaded.config.ui.rail.hidden[0]);
    }
    // The command still opens it — hiding a row hides a row.
    try command.run(&app, .{ .static = .@"view.activity_todos" });
    try t.expect(side.isShown(&app, .todos));
    try t.expectEqual(Section.todos, active(&app));
    // Hiding twice is a toast, not a second entry.
    try setHidden(&app, .todos, true);
    try t.expectEqual(@as(usize, 1), app.cfg.ui.rail.hidden.len);
    // Show on dock: NOTES leaves the bar and its command is pinned; the
    // dock lists it as a pinned panel wearing the section's glyph.
    try showOnDock(&app, .notes);
    try t.expect(isHidden(&app, .notes));
    try t.expect(integrations.isPinnedToDock(&app, "view.activity_notes"));
    try app.render();
    const items = try launcher_dock.items(&app, app.frame.allocator());
    var found = false;
    for (items) |it| if (it.kind == .pinned_panel) {
        found = true;
        try t.expectEqualStrings("Notes", it.label);
        try t.expectEqualStrings(Section.notes.meta().glyph, it.glyph);
        try t.expectEqualStrings("view.activity_notes", launcher_dock.commandIdOf(&app, it).?);
        try t.expectEqual(rail.StripKind.pinned_panel, launcher_dock.stripKind(it.kind));
    };
    try t.expect(found);
    // The hidden set is in the rail's order whatever the order of asking.
    try t.expectEqual(Config.RailSection.notes, app.cfg.ui.rail.hidden[0]);
    try t.expectEqual(Config.RailSection.todos, app.cfg.ui.rail.hidden[1]);
    // Move back: unpinned, row restored; TODOs still hidden.
    try moveBackFromDock(&app, .notes);
    try t.expect(!isHidden(&app, .notes));
    try t.expect(!integrations.isPinnedToDock(&app, "view.activity_notes"));
    try t.expectEqual(@as(usize, 1), app.cfg.ui.rail.hidden.len);
    try app.render();
    try t.expect((try rowY(&app, railRect(&app), .notes)) != null);
    // The rail menu's two rows sit after the section's verbs, before
    // the Sidebar row; the gear menu grows the submenu while anything
    // is hidden, and its child restores the section.
    try press(&app, 1, sectionRow(&app, .git), .right);
    const m = app.overlay.menu;
    try t.expectEqualStrings("Hide from activity bar", m.items[m.items.len - 3].label);
    try t.expectEqual(Section.git, m.items[m.items.len - 3].action.rail_hide);
    try t.expectEqualStrings("Show on dock instead", m.items[m.items.len - 2].label);
    try t.expectEqual(Section.git, m.items[m.items.len - 2].action.rail_to_dock);
    try t.expectEqualStrings("Sidebar", m.items[m.items.len - 1].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try press(&app, 1, 36, .right);
    const g = app.overlay.menu;
    try t.expectEqualStrings("Show hidden sections", g.items[g.items.len - 1].label);
    try t.expectEqual(@as(usize, 1), g.items[g.items.len - 1].submenu.len);
    try t.expectEqualStrings("TODOs", g.items[g.items.len - 1].submenu[0].label);
    try t.expectEqual(Section.todos, g.items[g.items.len - 1].submenu[0].action.rail_show);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // `view.rail_show_sections` clears the set; the gear menu loses the row.
    try command.run(&app, .{ .static = .@"view.rail_show_sections" });
    try t.expectEqual(@as(usize, 0), app.cfg.ui.rail.hidden.len);
    try press(&app, 1, 36, .right);
    try t.expectEqualStrings("About mnml", app.overlay.menu.items[app.overlay.menu.items.len - 1].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // The two commands act on the marked section: back on the tree,
    // Explorer is marked, so Explorer goes — and comes back.
    try command.run(&app, .{ .static = .@"view.activity_explorer" });
    try t.expectEqual(Section.explorer, active(&app));
    try command.run(&app, .{ .static = .@"view.rail_hide_section" });
    try t.expect(isHidden(&app, .explorer));
    try command.run(&app, .{ .static = .@"view.rail_show_sections" });
    try command.run(&app, .{ .static = .@"view.rail_show_on_dock" });
    try t.expect(isHidden(&app, .explorer));
    try t.expect(integrations.isPinnedToDock(&app, "view.activity_explorer"));
    try moveBackFromDock(&app, .explorer);
    try t.expect(!isHidden(&app, .explorer));
    try t.expect(!integrations.isPinnedToDock(&app, "view.activity_explorer"));
}

test "describe: every rail part has words, and the section's says what a click shows" {
    for (Section.rail) |s| {
        const tip = describe(.{ .section = s });
        try t.expectEqualStrings(s.meta().label, tip.title);
        try t.expect(std.mem.startsWith(u8, tip.detail.?, "click: "));
    }
    try t.expectEqualStrings("Settings", describe(.gear).title);
    try t.expectEqualStrings("Pinned launcher", describe(.{ .pin = 0 }).title);
}

test "pinned icons: pinning an installed launcher paints its chip after the sections and persists; a click fires its command; the right click opens its menu; Remove clears it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "integrations");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "integrations/htop.zon", .data = ".{ .id = \"htop\", .label = \"htop\", .chip = .{ .glyph_codepoint = \"F1D00\", .fallback = \"H\", .color = \"green\", .in_palette_bar = false }, .commands = .{ .{ .id = \"htop.open\", .title = \"htop: open\", .run = \":term htop\" } } }" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("PATH", "/definitely/not/a/dir");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40, .env = &env });
    defer app.deinit();
    try app.render();
    // Nothing pinned: no pin hit anywhere on the rail.
    for (app.hits.items.items) |e| if (e.target == .rail) try t.expect(e.target.rail != .pin);
    // Pin from the Installed row (the row menu's "Add to activity bar"
    // names the same command). The cursor starts on the first of the
    // four first-party rows, whose commands cannot back a docked icon;
    // the manifest is the row after them.
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    app.integrations.panel.cursor = integrations.first_party.len;
    try command.run(&app, .{ .static = .@"integrations.pin_to_activity_bar" });
    try t.expectEqual(@as(usize, 1), app.cfg.ui.activity_bar_pinned_integrations.len);
    try t.expectEqualStrings("htop", app.cfg.ui.activity_bar_pinned_integrations[0]);
    // Owned: `configPath` answers on the frame arena, and the steps
    // below render frames before it is read again.
    const home = try t.allocator.dupe(u8, (try settings.configPath(&app, .home)).?);
    defer t.allocator.free(home);
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".activity_bar_pinned_integrations = .{\"htop\"}") != null);
    // Painted after SCRIPTS on the rail's step, in green, with a pin hit.
    try app.render();
    const lay = rail.layout(railRect(&app), 1);
    const y = lay.pinY(0).?;
    try t.expectEqual(lay.sectionY(.scripts).? + lay.step, y);
    try t.expectEqualStrings("\u{F1D00}", app.screen.readCell(1, y).?.char.grapheme);
    try t.expectEqual(app.theme.palette.green, app.screen.readCell(1, y).?.style.fg);
    try t.expectEqual(@as(u16, 0), app.hits.at(1, y).?.rail.pin);
    try t.expectEqualStrings("htop", (try describeIn(&app, app.frame.allocator(), .{ .pin = 0 })).title);
    // Pinning again is a no-op toast, not a second row.
    try command.run(&app, .{ .static = .@"integrations.pin_to_activity_bar" });
    try t.expectEqual(@as(usize, 1), app.cfg.ui.activity_bar_pinned_integrations.len);
    // A click fires htop.open: htop is not on this PATH, so the hint toasts and no pane opens.
    try press(&app, 1, y, .left);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "htop is not on PATH") != null);
    try t.expectEqual(@as(usize, 0), app.panes.count());
    // The right click: the chip's menu, its five rows.
    // // changed (launcher-dock): *Pin to dock* joined them, between
    // the rail's own Remove row and Copy id.
    try press(&app, 1, y, .right);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("htop", app.overlay.menu.title);
    try t.expectEqualStrings("Disable", app.overlay.menu.items[0].label);
    try t.expectEqualStrings("Show on top bar", app.overlay.menu.items[1].label);
    try t.expectEqualStrings("Remove from activity bar", app.overlay.menu.items[2].label);
    try t.expectEqualStrings("Pin to dock", app.overlay.menu.items[3].label);
    try t.expectEqualStrings("Copy id", app.overlay.menu.items[4].label);
    try t.expectEqual(command.CommandId.@"integrations.unpin_from_activity_bar", app.overlay.menu.items[2].action.command);
    try t.expectEqual(command.CommandId.@"integrations.pin_to_dock", app.overlay.menu.items[3].action.command);
    // Choose Remove: the pin goes from the config, the file and the rail.
    var steps: usize = 0;
    while (!std.mem.eql(u8, app.overlay.menu.items[app.overlay.menu.cursor].label, "Remove from activity bar") or !app.overlay.menu.highlight) : (steps += 1) {
        try t.expect(steps < 6);
        try app.handle(.{ .key = app_mod.Key.named(.down) });
    }
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqual(@as(usize, 0), app.cfg.ui.activity_bar_pinned_integrations.len);
    const after = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(after);
    try t.expect(std.mem.indexOf(u8, after, ".activity_bar_pinned_integrations = .{}") != null);
    try app.render();
    try t.expect(app.hits.at(1, y) == null or app.hits.at(1, y).? != .rail or app.hits.at(1, y).?.rail != .pin);
    // A pinned id that no chip answers to paints nothing and breaks nothing.
    app.cfg.ui.activity_bar_pinned_integrations = &.{"vanished"};
    try app.render();
    try t.expectEqual(@as(usize, 0), (try props(&app, app.frame.allocator())).pins.len);
}
