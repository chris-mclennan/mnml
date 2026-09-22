//! Hover help for the two docks: the LAUNCHER dock (`app/launcher_dock.zig`
//! — the strip of things you start, along one edge of the editor area)
//! and the dock WIDGETS (`app/dock.zig` — the small panels pinned to a
//! corner of the buffer). Same word, different surfaces; each entry
//! says which it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../../app.zig");
const App = app_mod.App;
const copy = @import("../info_view_copy.zig");
const Entry = copy.Entry;
const hit = @import("../../ui/hit.zig");
const launcher_dock = @import("../launcher_dock.zig");
const dock_widgets = @import("../dock.zig");

// ─── the launcher dock ──────────────────────────────────────────────────

pub fn launcher(app: *App, arena: Allocator, part: hit.LauncherDockPart) Allocator.Error!?Entry {
    switch (part) {
        .pin => return .{
            .title = if (app.launcher_dock.pinned) "Launcher dock — pinned" else "Pin the launcher dock",
            .body = if (app.launcher_dock.pinned) "The dock is pinned: it stays up and the frame is carved out for it, as under `ui.dock.mode = always`. Click lets it go — it slides away when the pointer leaves the edge again. Right-click is the dock's menu: its mode, which edge it lives on, inner or outer placement, icons or labels, the settings row. The pin is remembered in the session; the mode is the config's." else "The chip at the end of the strip. Click keeps the dock open for the session — it stops sliding away and the frame is carved out for it; click again to let it go. Right-click is the dock's menu: its mode (always, auto-hide, hidden), which edge it lives on, inner or outer placement, icons or labels. The pin is remembered in the session, unlike the mode.",
            .links = &.{ .{ .command = .{ .id = .@"view.dock_pin", .label = "Pin / unpin" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.dock.mode"), .label = "Launcher dock in Settings" } }, comptime copy.docsSection("The launcher dock") },
        },
        .item => |i| {
            const list = try launcher_dock.items(app, arena);
            if (i >= list.len) return itemKind(.launcher, null, false);
            const it = list[i];
            return itemKind(it.kind, it.label, it.running);
        },
    }
}

/// The entry per item kind; the label and running flag are the item's
/// when one is under the pointer (the audit probes each kind bare).
pub fn itemKind(kind: launcher_dock.Kind, label: ?[]const u8, running: bool) Entry {
    _ = label;
    return switch (kind) {
        .plus => .{
            .title = "+ New…",
            .body = "The first item on the strip is the tab bar's own *Create…* menu, opened here where the click landed: a new file, a shell, a Claude or Codex session, a panel, a tool, an integration. Rows can be pinned to the top of that menu or hidden from it with their kebab. `ui.dock.plus` takes the button off the strip.",
            .keys = &.{.{ .command = .@"term.shell", .label = "New shell" }},
            .links = &.{ .{ .command = .{ .id = .@"file.new", .label = "New file…" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.dock.plus"), .label = "Show the + button" } } },
        },
        .pinned_panel => .{
            .title = "Panel on the dock",
            .body = "A sidebar section moved onto the strip from its activity-bar menu (*Show on dock instead*). Click opens the section as it always did; right-click offers *Move back to activity bar*, which unhides its row on the bar and takes it off the strip. `ui.rail.hidden` and `ui.dock.pins` hold the two halves of that move.",
            .links = &.{ .{ .command = .{ .id = .@"view.rail_show_sections", .label = "Hidden sections" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.dock.mode"), .label = "Launcher dock in Settings" } } },
        },
        .integration => .{
            .title = "Integration on the dock",
            .body = "An installed integration, on the strip because its manifest marks it for the dock or because you pinned it from its chip's menu. Click opens it — its pane, or its tool in a terminal split; right-click offers pin / unpin and its menu. The strip clips a long label; the tooltip carries the whole one. A disabled integration is dimmed and the click toasts.",
            .keys = &.{.{ .command = .@"view.activity_integrations", .label = "Integrations" }},
            .links = &.{ .{ .command = .{ .id = .@"integrations.unpin_from_dock", .label = "Take it off the dock" } }, .{ .command = .{ .id = .@"integrations.configure_picker", .label = "Configure it" } }, .{ .settings = .{ .row = comptime copy.settingsRow("ui.dock.labels"), .label = "Icons or labels" } } },
        },
        .launcher => .{
            .title = "Launcher",
            .body = "A launcher from `launchers` in config.zon — a program mnml starts for you in a terminal pane, with its own glyph and colour. Click runs it (a second click focuses the pane already running it); right-click offers pin / unpin. `launcher.add_local` makes one from a binary on this machine.",
            .links = &.{ .{ .command = .{ .id = .@"launcher.add_local", .label = "Add a launcher" } }, .{ .command = .{ .id = .@"file.open_settings", .label = "Open config.zon" } }, comptime copy.docsSection("Launchers and integration manifests") },
        },
        .terminal_new => .{
            .title = "New terminal",
            .body = "Opens a fresh shell in a split beside the active pane — your `$SHELL` in the workspace directory, rendered by libghostty-vt. Every shell that is open gets its own item after this one, so the strip doubles as the list of terminals. The terminal chip on the tab strip is the same door with a placement menu.",
            .keys = &.{ .{ .command = .@"term.shell", .label = "New shell" }, .{ .command = .@"term.scratch_toggle", .label = "Scratch terminal" } },
            .links = &.{ .{ .command = .{ .id = .@"term.shell", .label = "Open a shell" } }, .{ .command = .{ .id = .@"term.shell_bottom", .label = "A shell below" } } },
        },
        .terminal => .{
            .title = if (running) "An open terminal — running" else "An open terminal",
            .body = "One of the terminals open right now — a shell, a tool, a Claude session — named by its tab. Click focuses it, wherever it is: its tab is shown in its split and page. The dot marks one whose child is still running. Closing the tab takes the item off the strip.",
            .keys = &.{.{ .command = .@"buffer.close", .label = "Close it" }},
            .links = &.{ .{ .command = .{ .id = .@"term.rename", .label = "Rename it" } }, .{ .command = .{ .id = .@"view.activity_sessions", .label = "The sessions section" } } },
        },
        .pin => .{
            .title = "Pinned command",
            .body = "A palette command pinned onto the dock (`dock.pins` in the session, pinned from the palette's row menu) — any command, with its title as the label. Click runs it; right-click unpins. The strip clips a long title; the tooltip carries the whole one.",
            .keys = &.{.{ .command = .palette, .label = "The command palette" }},
            .links = &.{ .{ .command = .{ .id = .@"view.dock_unpin_item", .label = "Unpin it" } }, .{ .command = .{ .id = .palette, .label = "Pin another from the palette" } } },
        },
    };
}

// ─── the dock widgets ───────────────────────────────────────────────────

pub fn widget(app: *App, arena: Allocator, id: u32, part: hit.DockPart) Allocator.Error!?Entry {
    const w = app.dock.find(id);
    const kind: []const u8 = if (w) |wd| switch (wd.content) {
        .text => "a text note",
        .log_tail => "a log tail",
        .clock => "a clock",
        .git_branch => "the git branch",
    } else "a widget";
    return switch (part) {
        .body => .{
            .title = try std.fmt.allocPrint(arena, "Dock widget — {s}", .{kind}),
            .body = "A small panel pinned to a corner of the editor area — a text note, the tail of a log file, a clock, the branch — painted over the buffer or docked beside it. Click focuses it; the wheel scrolls its rows; right-click is the widget menu. These are the dock WIDGETS; the strip of launchers along an edge is the launcher dock, a different thing.",
            .links = &.{ .{ .command = .{ .id = .@"dock.new_text", .label = "New text widget" } }, .{ .command = .{ .id = .@"dock.toggle", .label = "Hide the widgets" } } },
        },
        .title => .{
            .title = try std.fmt.allocPrint(arena, "Dock widget title — {s}", .{kind}),
            .body = "The widget's header: drag it to move the widget to another corner, or click to focus. The kebab at its right end is the widget menu — rename, its corner, its size as a percent of the editor body, overlay or docked placement, opacity, close. The title is the widget's own (`dock.rename`).",
            .links = &.{ .{ .command = .{ .id = .@"dock.rename", .label = "Rename it" } }, .{ .command = .{ .id = .@"dock.move_corner_next", .label = "Move to the next corner" } } },
        },
        .kebab => .{
            .title = "Dock widget menu",
            .body = "Click opens the widget's rows: rename, the corner it sits in, its width and height as a percent of the editor body, overlay (over the buffer) or docked (beside it), opacity, close. Each row is one setting on this one widget; `dock.close_all` is the way to clear the corner in one go.",
            .links = &.{ .{ .command = .{ .id = .@"dock.edit", .label = "Edit it" } }, .{ .command = .{ .id = .@"dock.remove", .label = "Close it" } } },
        },
        .close => .{
            .title = "Close the dock widget",
            .body = "Takes this widget off the corner. A text widget's note is kept in the session's widget list until the session forgets it, so close is not a delete of the words; `dock.add_preset` puts a standard one back.",
            .links = &.{.{ .command = .{ .id = .@"dock.add_preset", .label = "Add a preset widget" } }},
        },
    };
}

/// For the AI: which dock item, its kind and whether it runs.
pub fn askContext(app: *App, arena: Allocator, part: hit.LauncherDockPart) Allocator.Error!?[]const u8 {
    switch (part) {
        .pin => return try std.fmt.allocPrint(arena, "- launcher dock pinned: {}; ui.dock.mode = {s}; edge = {s}\n", .{ app.launcher_dock.pinned, @tagName(app.cfg.ui.dock.mode), @tagName(app.cfg.ui.dock.edge) }),
        .item => |i| {
            const list = try launcher_dock.items(app, arena);
            if (i >= list.len) return null;
            return try std.fmt.allocPrint(arena, "- dock item: {s} (kind {s}, id {s}, running: {})\n", .{ list[i].label, @tagName(list[i].kind), list[i].id, list[i].running });
        },
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "every dock item kind, the pin chip and every widget part have entries" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 120, .rows = 40 });
    defer app.deinit();
    const a = app.frame.allocator();
    inline for (comptime std.enums.values(launcher_dock.Kind)) |k| try t.expect(itemKind(k, null, false).body.len >= 40);
    try t.expectEqualStrings("Pin the launcher dock", (try launcher(&app, a, .pin)).?.title);
    // The `+` is on a fresh app's strip — at whichever end `ui.dock.plus_at` puts it.
    const list = try launcher_dock.items(&app, a);
    var plus_seen = false;
    for (list, 0..) |it, i| if (it.kind == .plus) {
        try t.expectEqualStrings("+ New…", (try launcher(&app, a, .{ .item = @intCast(i) })).?.title);
        plus_seen = true;
    };
    try t.expect(plus_seen);
    inline for (comptime std.enums.values(hit.DockPart)) |p| try t.expect((try widget(&app, a, 999, p)) != null);
}
