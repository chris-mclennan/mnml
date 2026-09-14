//! `script.doctor` — one pane that says, for every Lua state the app is
//! running, what it is and what it is costing (§5 of the platform
//! design). The row per script carries its api version, where it came
//! from, whether it is enabled, how many times the 20 ms budget tripped
//! this session, the hooks it subscribed and its decoration namespaces
//! with the live counts.
//!
//! A scratch pane, not a panel: it is a report you read and close.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const scripts = @import("scripts.zig");
const script_decor = @import("script_decor.zig");
const manifest_mod = @import("../scripting/manifest.zig");
const lua_mod = @import("../scripting/lua.zig");

pub const table = .{
    .@"script.doctor" = &doctor,
};

pub const title = "script.doctor";

/// The whole report as text, on `arena`.
pub fn report(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.print(arena, "mnml script doctor — script api {d}\n", .{manifest_mod.api_version});
    try out.print(arena, "budget {d} ms per entry, checked every {d} instructions\n\n", .{ lua_mod.budget_ms, lua_mod.hook_count });
    const init_state = app.script();
    try out.appendSlice(arena, "init.lua\n");
    try out.print(arena, "  api {d}  source init  enabled yes  budget overruns {d}\n", .{ manifest_mod.api_version, init_state.budget_hits });
    try writeCommon(app, arena, &out, init_state, 0);
    if (app.scripts.entries.items.len == 0) {
        try out.appendSlice(arena, "\nNo installed scripts.\n");
        return out.items;
    }
    for (app.scripts.entries.items) |e| {
        try out.print(arena, "\n{s} {s}\n", .{ e.name, e.version });
        try out.print(arena, "  api {d}{s}  source {s}  enabled {s}  budget overruns {d}\n", .{
            e.api,
            if (e.supported()) "" else " (unsupported)",
            e.source.badge(),
            if (e.enabled) "yes" else "no",
            if (e.state) |l| l.budget_hits else 0,
        });
        try out.print(arena, "  folder {s}\n", .{e.dir});
        if (e.err) |m| try out.print(arena, "  error {s}\n", .{firstLine(m)});
        if (e.state) |l| try writeCommon(app, arena, &out, l, e.id) else try out.appendSlice(arena, "  not loaded\n");
    }
    return out.items;
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn writeCommon(app: *App, arena: Allocator, out: *std.ArrayListUnmanaged(u8), l: *lua_mod.Lua, state: u16) Allocator.Error!void {
    const s = l.summary();
    try out.print(arena, "  registered {d} command(s), {d} hook(s), {d} segment(s), {d} picker source(s), {d} operator(s), {d} list(s)\n", .{ s.commands, s.hooks, s.segments, s.sources, s.operators, s.lists });
    var hooks_line: std.ArrayListUnmanaged(u8) = .empty;
    for (l.origins.items) |o| {
        if (o.kind != .hook) continue;
        if (hooks_line.items.len > 0) try hooks_line.appendSlice(arena, ", ");
        try hooks_line.appendSlice(arena, o.name);
    }
    try out.print(arena, "  hooks {s}\n", .{if (hooks_line.items.len > 0) hooks_line.items else "none"});
    const counts = try script_decor.liveCounts(app, arena, state);
    if (counts.len == 0) {
        try out.appendSlice(arena, "  namespaces none\n");
        return;
    }
    for (counts) |c| try out.print(arena, "  namespace {s}: {d} decoration(s), {d} diagnostic(s)\n", .{ c.name, c.items, c.diagnostics });
}

/// `script.doctor`: the report in a scratch pane, reused across runs.
fn doctor(app: *App) CommandError!void {
    const text = try report(app, app.frame.allocator());
    const id = try app.openScratchWith(text);
    app.showPane(id);
    app.needs_render = true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "script.doctor names init.lua, its budget overruns and what it registered" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    try app.script().runString("mnml.command{ id = 'x', run = function() end } mnml.on('save_post', function() end)");
    const text = try report(&app, app.frame.allocator());
    try t.expect(std.mem.indexOf(u8, text, "init.lua") != null);
    try t.expect(std.mem.indexOf(u8, text, "registered 1 command(s), 1 hook(s)") != null);
    try t.expect(std.mem.indexOf(u8, text, "hooks save_post") != null);
    try t.expect(std.mem.indexOf(u8, text, "budget overruns 0") != null);
    try t.expect(std.mem.indexOf(u8, text, "No installed scripts.") != null);
    // A budget trip is counted and shows.
    try t.expectError(error.Failed, app.script().runString("while true do end"));
    const after = try report(&app, app.frame.allocator());
    try t.expect(std.mem.indexOf(u8, after, "budget overruns 1") != null);
    _ = scripts.SourceKind.directory;
}
