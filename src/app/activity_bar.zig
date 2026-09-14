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
const git_palette = @import("git_palette.zig");
const http_panel = @import("http_panel.zig");
const integrations = @import("integrations.zig");

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
    var p: rail.Props = .{
        .active = active(app),
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
    try t.expectEqualStrings("Move to right side", app.overlay.menu.items[1].label);
    try t.expectEqual(Section.git, app.overlay.menu.items[1].action.move_section.section);
    try t.expectEqual(Config.Side.right, app.overlay.menu.items[1].action.move_section.side);
    try t.expectEqualStrings("Open git graph", app.overlay.menu.items[2].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try press(&app, 1, sectionRow(&app, .http), .right);
    try t.expectEqualStrings("+ New request", app.overlay.menu.items[2].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // A section on the right offers the way back; SEARCH is a column
    // section too (// changed (search-section)), its verbs after the move.
    try press(&app, 1, sectionRow(&app, .notes), .right);
    try t.expectEqualStrings("Move to left side", app.overlay.menu.items[1].label);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try press(&app, 1, sectionRow(&app, .search), .right);
    try t.expectEqualStrings("Move to right side", app.overlay.menu.items[1].label);
    try t.expectEqualStrings("Refresh", app.overlay.menu.items[2].label);
    try t.expectEqualStrings("Open as pane", app.overlay.menu.items[3].label);
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
    // Pin from the Installed row (the row menu's "Add to activity bar" names the same command).
    try command.run(&app, .{ .static = .@"integrations.show_installed" });
    try command.run(&app, .{ .static = .@"integrations.pin_to_activity_bar" });
    try t.expectEqual(@as(usize, 1), app.cfg.ui.activity_bar_pinned_integrations.len);
    try t.expectEqualStrings("htop", app.cfg.ui.activity_bar_pinned_integrations[0]);
    const home = (try settings.configPath(&app, .home)).?;
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
    // The right click: the chip's menu, its four rows.
    try press(&app, 1, y, .right);
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("htop", app.overlay.menu.title);
    try t.expectEqualStrings("Disable", app.overlay.menu.items[0].label);
    try t.expectEqualStrings("Show on top bar", app.overlay.menu.items[1].label);
    try t.expectEqualStrings("Remove from activity bar", app.overlay.menu.items[2].label);
    try t.expectEqualStrings("Copy id", app.overlay.menu.items[3].label);
    try t.expectEqual(command.CommandId.@"integrations.unpin_from_activity_bar", app.overlay.menu.items[2].action.command);
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
