//! Launchers — integration manifests without a binary. A launcher's
//! commands carry `run` lines (`:term htop`, `:term code --goto
//! {{current_file_abs}}:{{cursor_line}}:{{cursor_col}}`) that start
//! programs already on the machine; mnml expands the `{{tokens}}`
//! (`launcher_template.zig`) and runs the line through the ex
//! dispatcher when the command fires — from the palette, its chord,
//! the Installed row, the palette-bar chip, or a pinned activity-bar
//! icon. A `term <prog>` line whose program is not on PATH toasts the
//! install hint the `tools.*` commands give instead of opening a pane
//! that dies at once.
//!
//! Install is the file appearing in `<data root>/integrations/`: the
//! Marketplace tab (a `github_launcher_folder` / `local_folder` source),
//! the Dev tab (an SDK checkout's own `launchers/`), and
//! `launcher.add_local` (a path typed into a prompt) all end in
//! `installFile`. Uninstall is deleting it, like any manifest.
//! Workspace-scoped manifests (`<ws>/.mnml/integrations/*.zon`) wait
//! for trust before the scan reads them (`integrations.refresh`), so an
//! untrusted checkout's `run` lines never fire.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const manifest_mod = @import("../bridge/manifest.zig");
const launcher_template = @import("launcher_template.zig");
const integrations = @import("integrations.zig");
const cmd_app = @import("cmd_app.zig");
const Prompt = app_mod.Prompt;

pub const table = .{
    .@"launcher.add_local" = &addLocalCmd,
};

// ─── firing ─────────────────────────────────────────────────────────────

/// A manifest command's line, expanded and run. The one runner every
/// `run` / `ex` line goes through (`command.runDyn`).
pub fn fire(app: *App, line_in: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const written = try launcher_template.expandFor(app, arena, line_in);
    const line = switch (try resolveTerm(app, arena, written)) {
        .run => |l| l,
        .missing => |prog| return app.diag.fail(arena, "{s} is not on PATH — {s}{s}", .{ prog, cmd_app.installHintPrefix(), prog }),
    };
    // A tool's `term` line keeps its own placement: the vim profile's
    // `:term` takes the current window, a tool still opens below. Its
    // tab reads the line as written, not the path it was resolved to.
    if (termArgs(line)) |args| return @import("cmd_term.zig").termToolAs(app, args, termArgs(written) orelse args);
    return app.runEx(line);
}

pub const Resolved = union(enum) {
    /// The line to run.
    run: []const u8,
    /// The program of a `term` line found nowhere.
    missing: []const u8,
};

/// The line `fire` runs. A `term <prog>` line runs the program an
/// integration's pane would (`integrations.resolveBinary`): one linked
/// into `<data root>/bin` — a Marketplace or local-folder install, the
/// demo's — is named by that path, since the shell the pane starts
/// does not look there; one only on PATH is left as it is. A program
/// in neither place is `.missing`.
pub fn resolveTerm(app: *App, arena: Allocator, line: []const u8) Allocator.Error!Resolved {
    const prog = termProgram(line) orelse return .{ .run = line };
    const path = integrations.resolveBinary(app, arena, prog) orelse return .{ .missing = prog };
    if (app.data_root.len == 0) return .{ .run = line };
    const bin_dir = try std.fs.path.join(arena, &.{ app.data_root, "bin" });
    if (!std.mem.startsWith(u8, path, bin_dir) or path.len <= bin_dir.len or !std.fs.path.isSep(path[bin_dir.len])) return .{ .run = line };
    const at = @intFromPtr(prog.ptr) - @intFromPtr(line.ptr);
    return .{ .run = try std.mem.concat(arena, u8, &.{ line[0..at], try shellWord(arena, path), line[at + prog.len ..] }) };
}

/// `path` as one word of the line the platform's shell runs (`sh -c`,
/// `cmd /d /c`): as it is when nothing in it needs quoting.
fn shellWord(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const plain = for (path) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/\\._-+:@,", c) != null)) break false;
    } else true;
    if (plain) return path;
    if (builtin.os.tag == .windows) return std.fmt.allocPrint(arena, "\"{s}\"", .{path});
    const inner = try std.mem.replaceOwned(u8, arena, path, "'", "'\\''");
    return std.fmt.allocPrint(arena, "'{s}'", .{inner});
}

/// What follows the verb of a `term …` / `terminal …` line (empty for a
/// bare one); null when the line is some other ex command.
pub fn termArgs(line_in: []const u8) ?[]const u8 {
    var line = std.mem.trim(u8, line_in, " \t");
    while (line.len > 0 and line[0] == ':') line = std.mem.trimStart(u8, line[1..], " \t");
    const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const verb = line[0..end];
    if (!std.mem.eql(u8, verb, "term") and !std.mem.eql(u8, verb, "terminal")) return null;
    return std.mem.trim(u8, line[end..], " \t");
}

/// The program a `term <prog> …` line starts, when it is a bare name
/// PATH resolves (not a path, an assignment, a variable or a quoted
/// word — those are the shell's to judge).
pub fn termProgram(line_in: []const u8) ?[]const u8 {
    var line = std.mem.trim(u8, line_in, " \t");
    while (line.len > 0 and line[0] == ':') line = std.mem.trimStart(u8, line[1..], " \t");
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const verb = it.next() orelse return null;
    if (!std.mem.eql(u8, verb, "term") and !std.mem.eql(u8, verb, "terminal")) return null;
    const prog = it.next() orelse return null;
    for (prog) |c| switch (c) {
        '/', '\\', '=', '$', '"', '\'', '`', '(', '{', '~' => return null,
        else => {},
    };
    return prog;
}

// ─── installing ─────────────────────────────────────────────────────────

/// Read a manifest file, refuse a broken one, and write it into the
/// data root under its own id; the Installed list follows.
pub fn installFile(app: *App, path: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    if (app.data_root.len == 0) return app.diag.fail(arena, "launcher: no data root to install into", .{});
    const text = Io.Dir.cwd().readFileAllocOptions(app.io, path, arena, .limited(1 << 20), .of(u8), 0) catch |err| {
        return app.diag.fail(arena, "launcher: cannot read {s}: {s}", .{ app.relPath(path), @errorName(err) });
    };
    var why: []const u8 = "";
    const m = manifest_mod.parse(arena, text, &why) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadManifest => return app.diag.fail(arena, "launcher: {s}: {s}", .{ app.relPath(path), why }),
    };
    const dest = manifest_mod.manifest.pathUnder(arena, app.data_root, m.id) catch return app.diag.fail(arena, "launcher: {s}: the id is not a file name", .{app.relPath(path)});
    Io.Dir.cwd().createDirPath(app.io, std.fs.path.dirname(dest).?) catch {};
    Io.Dir.cwd().writeFile(app.io, .{ .sub_path = dest, .data = text }) catch |err| {
        return app.diag.fail(arena, "launcher: cannot write {s}: {s}", .{ dest, @errorName(err) });
    };
    const id = try arena.dupe(u8, m.id);
    const shown = try arena.dupe(u8, app.relPath(dest));
    try integrations.refreshAfterInstall(app);
    app.toast("installed {s} — wrote {s}", .{ id, shown });
}

/// `launcher.add_local`: a prompt for the path of a `.zon` manifest on
/// this machine (`~` and workspace-relative paths fine), then `installFile`.
fn addLocalCmd(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    const state = Prompt.init(app.gpa, "Add launcher: path to its .zon manifest");
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .launcher_add_local } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The prompt's Enter.
pub fn addLocalAccept(app: *App, text: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const raw = std.mem.trim(u8, text, " \t\r\n");
    if (raw.len == 0) return app.diag.fail(arena, "launcher: no path given", .{});
    const expanded = try app.expandTilde(raw);
    const path = if (std.fs.path.isAbsolute(expanded)) expanded else try std.fs.path.join(arena, &.{ app.workspace, expanded });
    return installFile(app, path);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const build_options = @import("build_options");

test "launchers: every file in launchers/ is a launcher named for its file, with a fallback on its chip, a run line per command, and tokens the engine knows" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dir = try Io.Dir.cwd().openDir(t.io, build_options.launchers_dir, .{ .iterate = true });
    defer dir.close(t.io);
    var seen: usize = 0;
    var it = dir.iterate();
    while (try it.next(t.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const text = try dir.readFileAllocOptions(t.io, entry.name, arena, .limited(1 << 20), .of(u8), 0);
        var why: []const u8 = "";
        const m = manifest_mod.parse(arena, text, &why) catch {
            std.debug.print("launchers/{s}: {s}\n", .{ entry.name, why });
            return error.TestUnexpectedResult;
        };
        try t.expect(m.isLauncher());
        try t.expectEqualStrings(entry.name[0 .. entry.name.len - ".zon".len], m.id);
        try t.expect(m.label.len > 0 and m.description.len > 0);
        const chip = m.chip orelse return error.TestUnexpectedResult;
        try t.expect(chip.fallback.len >= 1 and chip.fallback.len <= 3);
        var gbuf: [4]u8 = undefined;
        try t.expect(chip.glyphText(&gbuf).len > 0);
        try t.expect(chip.color.len > 0);
        try t.expect(m.commands.len > 0);
        for (m.commands) |c| {
            const line = c.line() orelse return error.TestUnexpectedResult;
            try t.expect(std.mem.startsWith(u8, c.id, m.id));
            try t.expect(std.mem.startsWith(u8, line, ":term "));
            // Every `{{token}}` is one the engine expands.
            const expanded = try launcher_template.expand(arena, line, .{ .workspace = "/w", .current_file = "/w/f", .cursor_line = 1, .cursor_col = 1, .selection = "s" });
            try t.expect(std.mem.indexOf(u8, expanded, "{{") == null);
        }
        seen += 1;
    }
    try t.expectEqual(@as(usize, 4), seen);
}

test "termProgram: the bare program of a term line, with or without the colon; not a path, a variable, an assignment, another verb" {
    try t.expectEqualStrings("htop", termProgram(":term htop").?);
    try t.expectEqualStrings("htop", termProgram("term htop --tree").?);
    try t.expectEqualStrings("code", termProgram("  ::terminal code /x").?);
    try t.expect(termProgram(":term /usr/bin/htop") == null);
    try t.expect(termProgram(":term $EDITOR x") == null);
    try t.expect(termProgram(":term FOO=1 prog") == null);
    try t.expect(termProgram(":term 'a b'") == null);
    try t.expect(termProgram(":term") == null);
    try t.expect(termProgram(":echo hi") == null);
    try t.expect(termProgram("") == null);
}

test "fire: a term line whose program is not on PATH toasts the install hint and opens nothing; an ex line runs" {
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("PATH", "/definitely/not/a/dir");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = 12, .env = &env });
    defer app.deinit();
    try t.expectError(error.Failed, fire(&app, ":term nosuchprog-xyz --flag"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "nosuchprog-xyz is not on PATH — ") != null);
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, cmd_app.installHintPrefix()) != null);
    try t.expectEqual(@as(usize, 0), app.panes.count());
    app.diag.clear();
    try fire(&app, "echo from a {{workspace_name}} launcher");
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "from a ws launcher") != null);
}

test "resolveTerm: a term program linked into <data root>/bin runs by that path; one on PATH is left alone; one in neither is missing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.createDirPath(t.io, "data/bin");
    try tmp.dir.createDirPath(t.io, "path");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/bin/mnml-x", .data = "#!/bin/sh\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "path/onpath-x", .data = "#!/bin/sh\n" });
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = try std.fs.path.join(arena, &.{ root, "data" });
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("PATH", try std.fs.path.join(arena, &.{ root, "path" }));
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .data_root = data, .cols = 60, .rows = 12, .env = &env });
    defer app.deinit();
    const want = try std.fmt.allocPrint(arena, "term {s}/bin/mnml-x --refresh --workspace /w", .{data});
    try t.expectEqualStrings(want, (try resolveTerm(&app, arena, "term mnml-x --refresh --workspace /w")).run);
    try t.expectEqualStrings(":term onpath-x -v", (try resolveTerm(&app, arena, ":term onpath-x -v")).run);
    try t.expectEqualStrings("nosuch-x", (try resolveTerm(&app, arena, ":term nosuch-x")).missing);
    try t.expectEqualStrings("echo hi", (try resolveTerm(&app, arena, "echo hi")).run);
    try t.expectEqualStrings("'/a b/it'\\''s'", try shellWord(arena, "/a b/it's"));
    // And `fire` takes it: the data root's program opens, not a toast.
    try fire(&app, "term mnml-x --refresh");
    try t.expect(app.diag.msg == null);
    try t.expectEqual(@as(usize, 1), app.panes.count());
    // Its tab reads the line as written, not the resolved path.
    try t.expectEqualStrings("mnml-x --refresh", app.panes.get(app.active.?).?.title());
}

test "installFile: a good manifest lands in the data root and the list follows; a broken one is refused with its reason; add_local resolves a relative path" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(t.io, &pbuf)];
    try tmp.dir.createDirPath(t.io, "ws/launchers");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/launchers/htop.zon", .data = ".{ .id = \"htop\", .label = \"htop\", .chip = .{ .glyph_codepoint = \"F1D00\", .fallback = \"H\", .color = \"green\" }, .commands = .{ .{ .id = \"htop.open\", .title = \"htop: open\", .run = \":term htop\" } } }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/launchers/bad.zon", .data = ".{ .id = \"bad\", .label = \"bad\" }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/launchers/say.zon", .data = ".{ .id = \"say\", .label = \"Say\", .commands = .{ .{ .id = \"say.ws\", .title = \"Say: the workspace\", .run = \"echo in {{workspace_name}} at {{cursor_line}}\" } } }" });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    try env.put("PATH", "/definitely/not/a/dir");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = root, .cols = 80, .rows = 20, .env = &env });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"launcher.add_local" });
    try t.expect(app.overlay == .prompt);
    try t.expect(app.overlay.prompt.purpose == .launcher_add_local);
    try addLocalAccept(&app, "launchers/htop.zon");
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "installed htop") != null);
    const written = try tmp.dir.readFileAlloc(t.io, "integrations/htop.zon", t.allocator, .unlimited);
    defer t.allocator.free(written);
    try t.expect(std.mem.indexOf(u8, written, ".run = \":term htop\"") != null);
    try t.expectEqual(@as(usize, 1), app.integrations.list.len);
    try t.expect(app.integrations.list[0].manifest.isLauncher());
    try t.expect(command.resolve(&app, "htop.open") != null);
    // The registered command fires through `fire`: htop is not on this
    // PATH, so the hint toasts and no pane opens.
    try t.expectError(error.Failed, command.runNamed(&app, "htop.open"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "htop is not on PATH") != null);
    try t.expectEqual(@as(usize, 0), app.panes.count());
    app.diag.clear();
    // …and a line's tokens are expanded on the way.
    try addLocalAccept(&app, "launchers/say.zon");
    try command.runNamed(&app, "say.ws");
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "in ws at") != null);
    // Refused: nothing written, the reason in the diag.
    try t.expectError(error.Failed, addLocalAccept(&app, "launchers/bad.zon"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "no binary and no command") != null);
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "integrations/bad.zon", .{}));
    app.diag.clear();
    try t.expectError(error.Failed, addLocalAccept(&app, "launchers/nope.zon"));
    try t.expect(std.mem.indexOf(u8, app.diag.msg.?, "cannot read") != null);
    app.diag.clear();
    try t.expectError(error.Failed, addLocalAccept(&app, "  "));
}
