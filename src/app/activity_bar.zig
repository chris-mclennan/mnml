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
//! // changed: `view.activity_debug` / `view.activity_agents` /
//! `view.activity_cloud_agents` had specs and no runners; they run here
//! (the DAP pane, the agents dashboard, the honest "not in this build").
//! `view.activity_bar_cycle` is Zig-only, the twin of `view.menu_bar_cycle`.

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
const tooltip = @import("../ui/tooltip.zig");
const context_menus = @import("context_menus.zig");
const settings = @import("settings.zig");
const side = @import("side.zig");
const dap = @import("dap.zig");
const git_palette = @import("git_palette.zig");

pub const Section = rail.Section;
pub const Part = rail.Part;

pub const table = .{
    .@"view.activity_debug" = &activityDebug,
    .@"view.activity_agents" = &activityAgents,
    .@"view.activity_cloud_agents" = &activityCloudAgents,
    .@"view.activity_bar_cycle" = &cycleCmd,
};

/// The badge pulse (Rust): the glyph for four seconds, the count for one.
const pulse_icon_ms: i64 = 4000;
const pulse_period_ms: i64 = 5000;

/// The section's palette command — what a click runs and what the
/// right-click menu's first row names.
pub fn commandOf(s: Section) command.CommandId {
    return switch (s) {
        .explorer => .@"view.activity_explorer",
        .search => .@"view.activity_search",
        .git => .@"view.activity_git",
        .debug => .@"view.activity_debug",
        .integrations => .@"view.activity_integrations",
        .sessions => .@"view.activity_sessions",
        .agents => .@"view.activity_agents",
        .cloud_agents => .@"view.activity_cloud_agents",
        .http => .@"view.activity_http",
        .notes => .@"view.activity_notes",
        .todos => .@"view.activity_todos",
        .findings => .@"view.activity_findings",
        .diagnostics => .@"lsp.diagnostics",
        .outline => .@"outline.show",
    };
}

/// Whether the rail paints this frame. `auto`: the pointer in column 0
/// reveals it, and it stays while the pointer rests on it — read off
/// the previous frame's hits, so this runs before the frame resets them.
pub fn shown(app: *const App) bool {
    return switch (app.cfg.ui.activity_bar) {
        .always => true,
        .hidden => false,
        .auto => blk: {
            const h = app.hover orelse break :blk false;
            if (h.x == 0) break :blk true;
            break :blk if (app.hits.at(h.x, h.y)) |under| under == .rail else false;
        },
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
        .pane => |id| if (sectionOfPane(app, id)) |s| return s,
        .overlay => {},
    }
    if (side.shown(app, .right)) |s| if (onRail(s)) |r| return r;
    if (app.active) |id| if (sectionOfPane(app, id)) |s| return s;
    if (side.shown(app, .left)) |s| if (onRail(s)) |r| return r;
    return .explorer;
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
        .debug, .dap_repl => .debug,
        .claude_agents => .agents,
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
}

/// What the painter needs this frame.
pub fn props(app: *App) rail.Props {
    var p: rail.Props = .{
        .active = active(app),
        // The pinned launcher slots are not painted (they need the
        // integrations), but Rust's density rule counts them.
        .extra_items = app.cfg.ui.activity_bar_pinned_integrations.len,
        .show_counts = @mod(app.now_ms, pulse_period_ms) >= pulse_icon_ms,
    };
    for (Section.all) |s| p.badges[@intFromEnum(s)] = app.ipc_fx.badge(s.badgeKey());
    return p;
}

/// A press on the rail: left shows the section (the gear opens
/// Settings), right opens its menu. Wheel and motion do nothing.
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
    }
}

pub fn show(app: *App, s: Section) Allocator.Error!void {
    try run(app, commandOf(s));
}

fn run(app: *App, id: command.CommandId) Allocator.Error!void {
    command.run(app, .{ .static = id }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// The hover copy (Rust `ui/tooltip.rs`): what a click shows, and what
/// the section holds.
pub fn describe(part: Part) tooltip.Tip {
    return switch (part) {
        .gear => .{ .title = "Settings", .detail = "click opens Settings · right-click: Settings / Command Palette / Cheatsheet / Themes / About" },
        .section => |s| .{ .title = s.meta().label, .detail = switch (s) {
            .explorer => "click: Files rail · workspace file tree · new file / folder · right-click: menu",
            .search => "click: Search rail · ripgrep across the workspace · right-click: menu",
            .git => "click: Git rail · status · commits · branches · worktrees · stash · right-click: menu",
            .debug => "click: Debug rail · breakpoints · watches · call stack · right-click: menu",
            .integrations => "click: Integrations rail · browser / mixr / integration tools · + to add · right-click: menu",
            .sessions => "click: Sessions rail · Claude / Codex / shell sessions · right-click: menu",
            .agents => "click: Agents rail · running Claude Code + Codex sessions · right-click: menu",
            .cloud_agents => "click: Cloud Agents rail · ECS runner + Anthropic managed sessions · right-click: menu",
            .http => "click: HTTP rail · requests · recent · captured · envs · collections · right-click: menu",
            .notes => "click: Notes rail · .mnml/notes/*.md persistent scratch · right-click: menu",
            .todos => "click: TODOs rail · TODO / FIXME / XXX / HACK / REVIEW hits · right-click: menu",
            .findings => "click: Findings rail · .mnml/findings/*.md tester / review reports · right-click: menu",
            .diagnostics => "click: Diagnostics · the language servers' problems list",
            .outline => "click: Outline · the symbols of the active file",
        } },
    };
}

// ─── the runners ────────────────────────────────────────────────────────

fn activityDebug(app: *App) CommandError!void {
    enter(app, .debug);
    return dap.showDebug(app);
}

fn activityAgents(app: *App) CommandError!void {
    enter(app, .agents);
    return command.run(app, .{ .static = .@"ai.dashboard" });
}

fn activityCloudAgents(app: *App) CommandError!void {
    enter(app, .cloud_agents);
    return app.diag.fail(app.frame.allocator(), "cloud agents (AWS ECS / Managed Agents) are not in this build yet", .{});
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
    // A pane surface: Search opens the grep prompt; Debug the DAP pane.
    try press(&app, 1, sectionRow(&app, .debug), .left);
    try t.expectEqual(Section.debug, active(&app));
    // Right-click: the section's menu, "Show X" first, then its verbs.
    try press(&app, 1, sectionRow(&app, .git), .right);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Source control", app.overlay.menu.title);
    try t.expectEqualStrings("Show Source control", app.overlay.menu.items[0].label);
    try t.expectEqual(command.CommandId.@"view.activity_git", app.overlay.menu.items[0].action.command);
    try t.expectEqualStrings("Move to right side", app.overlay.menu.items[1].label);
    try t.expectEqual(Section.git, app.overlay.menu.items[1].action.move_section.section);
    try t.expectEqual(Config.Side.right, app.overlay.menu.items[1].action.move_section.side);
    try t.expectEqualStrings("Open git graph", app.overlay.menu.items[2].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try press(&app, 1, sectionRow(&app, .http), .right);
    try t.expectEqualStrings("+ New request", app.overlay.menu.items[2].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // A section on the right offers the way back; a pane section
    // (Search) has no side and no such row.
    try press(&app, 1, sectionRow(&app, .notes), .right);
    try t.expectEqualStrings("Move to left side", app.overlay.menu.items[1].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try press(&app, 1, sectionRow(&app, .search), .right);
    try t.expectEqualStrings("New search", app.overlay.menu.items[1].label);
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
    const home = (try settings.configPath(&app, .home)).?;
    const text = try std.Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".activity_bar = .always") != null);
}

test "describe: every rail part has words, and the section's says what a click shows" {
    for (Section.rail) |s| {
        const tip = describe(.{ .section = s });
        try t.expectEqualStrings(s.meta().label, tip.title);
        try t.expect(std.mem.startsWith(u8, tip.detail.?, "click: "));
    }
    try t.expectEqualStrings("Settings", describe(.gear).title);
}
