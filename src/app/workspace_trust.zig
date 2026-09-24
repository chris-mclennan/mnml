//! Reviewing and revoking workspace trust after the first dialog.
//!
//! `workspace.review_trust` re-opens the question. On an untrusted
//! workspace that is the first-launch dialog again (`trust.promptIfNeeded`
//! — the claims, Don't trust focused). On a trusted one it lists the
//! same claims, re-read from `.mnml/config.zon`, with Keep focused and
//! Forget beside it. `trusted.forget` drops the workspace from
//! `trusted_workspaces.zon` and reloads the config with the exec-bearing
//! keys stripped, so the `RESTRICTED` chip comes back at once and the
//! next launch asks again.
//!
//! The store is one line per workspace (`config/trusted.zig`), so
//! forgetting is a line delete: the file keeps every other entry and
//! any comment the user added.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Confirm = app_mod.Confirm;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const config = @import("../config/root.zig");
const trust_app = @import("trust.zig");
const canvas = @import("../ui/canvas.zig");

pub const table = .{
    .@"workspace.review_trust" = &reviewTrust,
    .@"trusted.forget" = &forget,
};

pub const review_choices = [_]Confirm.Choice{ .{ .key = 'k', .label = "Keep" }, .{ .key = 'f', .label = "Forget" } };

/// The exec-bearing claims of the workspace layer as it is on disk.
fn currentClaims(app: *App, arena: Allocator) Allocator.Error![]const config.trust.Claim {
    const l = app.loaded orelse return &.{};
    const src = Io.Dir.cwd().readFileAllocOptions(app.io, l.workspace_path, arena, .limited(config.load.max_file_bytes), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    var diags = config.diag.Diagnostics.init(arena);
    const patch = try config.load.parseLayer(arena, src, l.workspace_path, &diags);
    const init_lua = try std.fs.path.join(arena, &.{ app.workspace, ".mnml", "init.lua" });
    const facts: config.trust.Facts = .{
        .init_lua = if (Io.Dir.cwd().access(app.io, init_lua, .{})) true else |_| false,
        .manifests = try config.trust.manifestNames(arena, app.io, app.workspace),
    };
    return config.trust.claimsWith(arena, patch, facts);
}

fn reviewTrust(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    // A 0.2 `.mnml/config.toml` with no `.zon` beside it: nothing to
    // trust or forget — the whole file is unread, and the chip's click
    // says how to convert it (the notice itself shows once per data
    // root, `App.noticeUnreadToml`).
    app.probeWorkspaceToml();
    if (app.workspace_toml) |p| if (app.loaded == null or app.loaded.?.trust_prompt == null) {
        try app.toastLevel(.warn, "{s}", .{try app.unreadTomlText(arena, p, true)});
        return;
    };
    const l = app.loaded orelse return app.diag.fail(arena, "no workspace config loaded", .{});
    if (l.trust_prompt != null) return trust_app.promptIfNeeded(app);
    const claims = try currentClaims(app, arena);
    if (claims.len == 0) return app.diag.fail(arena, "{s} declares nothing that runs a program — nothing to trust", .{app.relPath(app.workspace)});
    const gpa = app.gpa;
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    errdefer msg.deinit(gpa);
    try msg.print(gpa, "{s} is trusted to run, from its .mnml/config.zon:", .{app.relPath(app.workspace)});
    for (claims) |c| try msg.print(gpa, "\n  • {f}", .{c});
    try msg.appendSlice(gpa, "\nForget stops these now and asks again next launch.");
    const owned = try msg.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Workspace trust", .message = owned, .choices = &review_choices, .selected = 0 },
        .purpose = .review_trust,
        .message = owned,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The review dialog's answer: index 1 is Forget.
pub fn answerReview(app: *App, choice: usize) Allocator.Error!void {
    if (choice != 1) return;
    forget(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (app.diag.msg) |m| app.toast("{s}", .{m}),
    };
}

fn forget(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (app.loaded == null) return app.diag.fail(arena, "no workspace config loaded", .{});
    const store = try config.trusted.storePath(arena, app.data_root);
    const removed = removeEntry(app.gpa, app.io, store, app.workspace) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "could not update {s}: {s}", .{ store, @errorName(err) }),
    };
    // `.ask` re-derives the prompt from the store, which no longer has
    // us: the layer is stripped and the RESTRICTED chip is back.
    try app.reloadConfig(.ask);
    if (removed) app.toast("forgot this workspace's trust — exec-bearing settings are off", .{}) else app.toast("this workspace was not trusted", .{});
}

/// Drop `workspace`'s line from the store. True when a line went.
pub fn removeEntry(gpa: Allocator, io: Io, path: []const u8, workspace: []const u8) !bool {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    defer gpa.free(text);
    const needle = try std.fmt.allocPrint(gpa, ".@\"{s}\" =", .{workspace});
    defer gpa.free(needle);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    var removed = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!removed and std.mem.indexOf(u8, std.mem.trimStart(u8, line, " \t"), needle) == 0) {
            removed = true;
            continue;
        }
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, line);
    }
    if (!removed) return false;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    return true;
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "review on a trusted workspace lists the claims; Forget drops the store line and restricts again" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.createDirPath(t.io, "data");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data = ".{ .lsp = .{ .zig = .{ .cmd = \"zls\" } } }" });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    try vars.put("MNML_DATA_ROOT", data);
    const opts: config.load.Options = .{ .workspace = ws, .trust = .ask, .data_root = data, .env = .{ .vars = &vars } };
    const loaded = try config.load.load(t.allocator, t.io, opts);
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    // Untrusted: the chip paints; review is the first dialog again.
    try t.expect(app.overlay == .confirm);
    try app.handle(.{ .key = app_mod.Key.named(.enter) }); // Don't trust
    try app.render();
    const screen_mod = @import("../ipc/screen.zig");
    {
        const text = try screen_mod.toTestText(t.allocator, &app.screen);
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, "RESTRICTED") != null);
    }
    try command.run(&app, .{ .static = .@"workspace.review_trust" });
    try t.expect(app.overlay == .confirm and app.overlay.confirm.purpose == .trust_workspace);
    try app.handle(.{ .key = app_mod.Key.char('t') });
    try t.expect(app.workspace_trusted);
    try t.expectEqualStrings("zls", app.cfg.lsp.get("zig").?.cmd.?);
    try app.render();
    {
        const text = try screen_mod.toTestText(t.allocator, &app.screen);
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, "RESTRICTED") == null);
    }
    // Trusted: review lists the claim with Keep focused; Forget revokes.
    try command.run(&app, .{ .static = .@"workspace.review_trust" });
    try t.expect(app.overlay == .confirm and app.overlay.confirm.purpose == .review_trust);
    try t.expectEqual(@as(usize, 0), app.overlay.confirm.state.selected);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "runs `zls`") != null);
    try app.handle(.{ .key = app_mod.Key.char('f') });
    try t.expect(app.overlay == .none);
    try t.expect(!app.workspace_trusted);
    try t.expect(app.cfg.lsp.get("zig").?.cmd == null);
    const store = try tmp.dir.readFileAlloc(t.io, "data/trusted_workspaces.zon", t.allocator, .unlimited);
    defer t.allocator.free(store);
    try t.expect(std.mem.indexOf(u8, store, ws) == null);
    try app.render();
    {
        const text = try screen_mod.toTestText(t.allocator, &app.screen);
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, "RESTRICTED") != null);
    }
    // Forgetting again is a no-op that says so.
    try command.run(&app, .{ .static = .@"trusted.forget" });
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "was not trusted") != null);
}

test "a cloned repo's scripts.dev_roots runs nothing until the workspace is trusted, and the dialog names it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.createDirPath(t.io, "ws/tools/hello");
    try tmp.dir.createDirPath(t.io, "data");
    // The repo as it would be cloned: its config names its own folder,
    // and the script there shells out the moment it loads.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data = ".{ .scripts = .{ .dev_roots = .{\"tools\"} } }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/tools/hello/script.zon", .data = ".{ .name = \"hello\", .version = \"1.0.0\", .api = 1 }" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/tools/hello/init.lua", .data = "mnml.task.run{ cmd = 'touch RAN_WITHOUT_TRUST', hidden = true }\n" });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    try vars.put("MNML_DATA_ROOT", data);
    const opts: config.load.Options = .{ .workspace = ws, .trust = .ask, .data_root = data, .env = .{ .vars = &vars } };
    const loaded = try config.load.load(t.allocator, t.io, opts);
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data, .cols = 120, .rows = 30, .env = &vars });
    defer app.deinit();
    // The question is up, and it names the folder and what runs from it.
    try t.expect(app.overlay == .confirm and app.overlay.confirm.purpose == .trust_workspace);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "script folder dev_roots — runs `tools/*/init.lua`") != null);
    // Unanswered: the script is not even adopted, and nothing ran.
    try t.expect(app.scripts.find("hello") == null);
    try t.io.sleep(.fromMilliseconds(300), .awake);
    try app.tick(App.nowMs(app.io));
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "ws/RAN_WITHOUT_TRUST", .{}));
    // Trust: the folder is scanned now and its script runs.
    try app.handle(.{ .key = app_mod.Key.char('t') });
    try t.expect(app.workspace_trusted);
    const e = app.scripts.find("hello") orelse return error.TestUnexpectedResult;
    try t.expect(e.state != null);
    var waited: u32 = 0;
    while (true) : (waited += 20) {
        if (tmp.dir.access(t.io, "ws/RAN_WITHOUT_TRUST", .{})) |_| break else |_| {}
        if (waited > 5000) return error.Timeout;
        try t.io.sleep(.fromMilliseconds(20), .awake);
        try app.tick(App.nowMs(app.io));
    }
}

test "removeEntry keeps the other lines and the comments" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const path = try std.fs.path.join(t.allocator, &.{ buf[0..n], "store.zon" });
    defer t.allocator.free(path);
    try t.expect(!try removeEntry(t.allocator, t.io, path, "/w/a"));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "store.zon", .data = "// mine\n.{\n    .@\"/w/a\" = \"1\",\n    .@\"/w/ab\" = \"2\",\n}\n" });
    try t.expect(try removeEntry(t.allocator, t.io, path, "/w/a"));
    const text = try tmp.dir.readFileAlloc(t.io, "store.zon", t.allocator, .unlimited);
    defer t.allocator.free(text);
    try t.expectEqualStrings("// mine\n.{\n    .@\"/w/ab\" = \"2\",\n}\n", text);
}

test "a 0.2 .mnml/config.toml with no .zon: RESTRICTED on the statusline, the converter toasted once per data root (ui.config_toml_notice_shown), :messages every launch, the chip's click says why" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.createDirPath(t.io, "data");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.toml", .data = "[ui]\ntheme = \"gruvbox\"\n" });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    try vars.put("MNML_DATA_ROOT", data);
    const opts: config.load.Options = .{ .workspace = ws, .trust = .ask, .data_root = data, .env = .{ .vars = &vars } };
    // First launch on this data root: the toast, the flag written, the chip.
    {
        const loaded = try config.load.load(t.allocator, t.io, opts);
        try t.expect(loaded.workspace_toml != null);
        try t.expectEqual(@as(usize, 0), loaded.diagnostics.count());
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data, .cols = 120, .rows = 40 });
        defer app.deinit();
        try t.expect(app.workspace_toml != null);
        try t.expect(app.overlay == .none); // nothing to trust: no dialog
        const first = app.lastToast() orelse return error.TestUnexpectedResult;
        try t.expect(std.mem.indexOf(u8, first, "export-config-zon --out .mnml/config.zon") != null);
        try t.expect(app.cfg.ui.config_toml_notice_shown);
        const home = try tmp.dir.readFileAlloc(t.io, "data/config.zon", t.allocator, .limited(1 << 20));
        defer t.allocator.free(home);
        try t.expect(std.mem.indexOf(u8, home, "config_toml_notice_shown = true") != null);
        try app.render();
        var rbuf: [1024]u8 = undefined;
        try t.expect(std.mem.indexOf(u8, canvas.rowText(&app.screen, 38, &rbuf), "RESTRICTED") != null);
    }
    // Every later launch: no toast, the message logged, the chip still up,
    // and the chip's click (workspace.review_trust) toasts the converter.
    {
        const loaded = try config.load.load(t.allocator, t.io, opts);
        try t.expect(loaded.config.ui.config_toml_notice_shown);
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data, .cols = 120, .rows = 40 });
        defer app.deinit();
        try t.expectEqual(@as(usize, 0), app.toasts.items.len);
        var logged = false;
        for (app.messages.items.items) |m| if (std.mem.indexOf(u8, m.text, "export-config-zon") != null) {
            logged = true;
        };
        try t.expect(logged);
        try app.render();
        var rbuf: [1024]u8 = undefined;
        try t.expect(std.mem.indexOf(u8, canvas.rowText(&app.screen, 38, &rbuf), "RESTRICTED") != null);
        try command.run(&app, .{ .static = .@"workspace.review_trust" });
        const clicked = app.lastToast() orelse return error.TestUnexpectedResult;
        try t.expect(std.mem.indexOf(u8, clicked, "export-config-zon") != null);
        // Converted (a .zon beside it): the chip goes on the next probe.
        try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data = ".{}" });
        app.probeWorkspaceToml();
        try t.expect(app.workspace_toml == null);
        try app.render();
        try t.expect(std.mem.indexOf(u8, canvas.rowText(&app.screen, 38, &rbuf), "RESTRICTED") == null);
    }
}
