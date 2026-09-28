//! `script.doctor` — one pane that says, for every Lua state the app is
//! running, what it is and what it is costing (§5 of the platform
//! design). The row per script carries its api version, where it came
//! from, whether it is enabled, how many times the 20 ms budget tripped
//! this session, the hooks it subscribed, the directory its scoped
//! `require` may read under, and its decoration namespaces with the
//! live counts. The head of the report names the three places a script
//! can come from — the install root, the marketplace folder and the dev
//! roots — so "why is my script not listed" is one command and not a
//! hunt through the config.
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
const build_options = @import("build_options");
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
    // The frame budget is the promise a script author reads, and it is
    // the shipped build's (`scripting/lua.zig`). A Debug build runs a
    // runaway budget instead, and the row says so rather than quietly
    // reporting a figure no shipped build has.
    if (lua_mod.budget_ms == lua_mod.frame_budget_ms)
        try out.print(arena, "budget {d} ms per entry, checked every {d} instructions\n", .{ lua_mod.frame_budget_ms, lua_mod.hook_count })
    else
        try out.print(arena, "budget {d} ms per entry, checked every {d} instructions — {d} ms in this debug build\n", .{ lua_mod.frame_budget_ms, lua_mod.hook_count, lua_mod.budget_ms });
    try writeSources(app, arena, &out);
    const init_state = app.script();
    try out.appendSlice(arena, "\ninit.lua\n");
    try out.print(arena, "  api {d}  source init  enabled yes  budget overruns {d}\n", .{ manifest_mod.api_version, init_state.budget_hits });
    // The two `init.lua` files are one state and one file each: no
    // scoped `require`, which is why the row says so rather than
    // leaving a reader to wonder where it would look.
    try out.appendSlice(arena, "  require none (init.lua is one file)\n");
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
        // The one directory its `require` may read under — nothing
        // above it, nothing beside it.
        if (e.state) |l| {
            if (l.root) |r| try out.print(arena, "  require root {s}\n", .{r}) else try out.appendSlice(arena, "  require none\n");
        }
        if (e.err) |m| try out.print(arena, "  error {s}\n", .{firstLine(m)});
        if (e.state) |l| try writeCommon(app, arena, &out, l, e.id) else try out.appendSlice(arena, "  not loaded\n");
    }
    return out.items;
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

/// The three places a script can come from, resolved as the scan
/// resolves them (the environment overrides included), so a folder that
/// is not being read says so by name rather than by silence.
fn writeSources(app: *App, arena: Allocator, out: *std.ArrayListUnmanaged(u8)) Allocator.Error!void {
    try out.appendSlice(arena, "\nsources\n");
    if (try scripts.installRoot(app, arena)) |root|
        try out.print(arena, "  installed   {s}\n", .{root})
    else
        try out.appendSlice(arena, "  installed   (no data root)\n");
    const market = try scripts.marketplaceRoot(app, arena);
    if (market.len > 0)
        try out.print(arena, "  marketplace {s}\n", .{market})
    else
        try out.appendSlice(arena, "  marketplace (none: no share/mnml/lua beside the binary, no scripts.marketplace_local)\n");
    const dev = try scripts.devRoots(app, arena);
    if (dev.len == 0) {
        try out.appendSlice(arena, "  dev         (none)\n");
        return;
    }
    for (dev) |d| try out.print(arena, "  dev         {s}\n", .{d});
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
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    try app.script().runString("mnml.command{ id = 'x', run = function() end } mnml.on('save_post', function() end)");
    const text = try report(&app, app.frame.allocator());
    try t.expect(std.mem.indexOf(u8, text, "init.lua") != null);
    try t.expect(std.mem.indexOf(u8, text, "registered 1 command(s), 1 hook(s)") != null);
    try t.expect(std.mem.indexOf(u8, text, "hooks save_post") != null);
    try t.expect(std.mem.indexOf(u8, text, "budget overruns 0") != null);
    try t.expect(std.mem.indexOf(u8, text, "No installed scripts.") != null);
    // The three source folders are named before the first script, so
    // "why is my script not listed" is answered by the same command.
    try t.expect(std.mem.indexOf(u8, text, "sources") != null);
    try t.expect(std.mem.indexOf(u8, text, "installed   (no data root)") != null);
    // Nothing is configured here, so the marketplace row names the set
    // that ships with mnml — under a test, the checkout's own `lua/`.
    // A row that said "(none)" out of the box was the bug this replaced.
    try t.expect(std.mem.indexOf(u8, text, "marketplace " ++ build_options.scripts_dir) != null);
    try t.expect(std.mem.indexOf(u8, text, "dev         (none)") != null);
    // `init.lua` is one file: it has no scoped `require`, and the row
    // says so rather than leaving a reader to guess where it looks.
    try t.expect(std.mem.indexOf(u8, text, "require none (init.lua is one file)") != null);
    // A budget trip is counted and shows.
    try t.expectError(error.Failed, app.script().runString("while true do end"));
    const after = try report(&app, app.frame.allocator());
    try t.expect(std.mem.indexOf(u8, after, "budget overruns 1") != null);
    _ = scripts.SourceKind.directory;
}

test "script.doctor names each installed script's require root and the folders it was scanned from" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "installed/greeter");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "installed/greeter/script.zon", .data =
        \\.{ .name = "greeter", .version = "1.0.0", .api = 1, .description = "hi", .source = .community }
    });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "installed/greeter/init.lua", .data = "mnml.command{ id = 'greet', run = function() end }\n" });
    try tmp.dir.createDirPath(t.io, "market");
    try tmp.dir.createDirPath(t.io, "devroot");
    const installed = try std.fs.path.join(t.allocator, &.{ root, "installed" });
    defer t.allocator.free(installed);
    const market = try std.fs.path.join(t.allocator, &.{ root, "market" });
    defer t.allocator.free(market);
    const dev = try std.fs.path.join(t.allocator, &.{ root, "devroot" });
    defer t.allocator.free(dev);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("MNML_SCRIPTS_ROOT", installed);
    try env.put("MNML_SCRIPTS_MARKETPLACE", market);
    try env.put("MNML_SCRIPTS_DEV_ROOTS", dev);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .env = &env, .cols = 100, .rows = 30 });
    defer app.deinit();
    try scripts.scan(&app);
    const text = try report(&app, app.frame.allocator());
    // The scan's own three roots, and the one directory the script's
    // `require` may read under.
    try t.expect(std.mem.indexOf(u8, text, installed) != null);
    try t.expect(std.mem.indexOf(u8, text, market) != null);
    try t.expect(std.mem.indexOf(u8, text, dev) != null);
    const want = try std.fmt.allocPrint(t.allocator, "require root {s}{c}greeter", .{ installed, std.fs.path.sep });
    defer t.allocator.free(want);
    if (std.mem.indexOf(u8, text, want) == null) {
        std.debug.print("wanted `{s}` in:\n{s}\n", .{ want, text });
        return error.TestExpectedEqual;
    }
}
