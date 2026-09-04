//! Workspace trust, app side: the one-time dialog and what each answer
//! does. The decision itself is the loader's (`config.load` with
//! `.trust = .ask` consults `trusted_workspaces.zon` and hands back a
//! `TrustPrompt` when the workspace's exec-bearing claims are new); this
//! module turns that prompt into a Confirm, and Trust into a remembered
//! fingerprint plus a reload with the workspace layer applied in full.
//!
//! Don't trust is the focused choice: the safe answer is the one a
//! reflexive Enter gives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Confirm = app_mod.Confirm;
const config = @import("../config/root.zig");

pub const choices = [_]Confirm.Choice{ .{ .key = 't', .label = "Trust" }, .{ .key = 'd', .label = "Don't trust" } };

/// Open the dialog when the loader asked for one. A no-op otherwise.
pub fn promptIfNeeded(app: *App) Allocator.Error!void {
    const l = app.loaded orelse return;
    const prompt = l.trust_prompt orelse return;
    const gpa = app.gpa;
    var msg: std.ArrayListUnmanaged(u8) = .empty;
    errdefer msg.deinit(gpa);
    try msg.print(gpa, "{s} runs programs from its .mnml/config.zon:", .{app.relPath(app.workspace)});
    for (prompt.claims) |c| try msg.print(gpa, "\n  • {f}", .{c});
    try msg.appendSlice(gpa, "\nUntil trusted these settings are ignored; the rest apply.");
    const owned = try msg.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    app.overlay.deinit(gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Trust this workspace?", .message = owned, .choices = &choices, .selected = 1 },
        .purpose = .trust_workspace,
        .message = owned,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `choice` is an index into `choices`.
pub fn answer(app: *App, choice: usize) Allocator.Error!void {
    if (choice != 0) {
        app.toast("workspace not trusted — exec-bearing settings stay off (asked again next launch)", .{});
        return;
    }
    const l = &(app.loaded orelse return);
    const prompt = l.trust_prompt orelse return;
    const store = try config.trusted.storePath(app.frame.allocator(), app.data_root);
    config.trusted.remember(app.gpa, app.io, store, app.workspace, prompt.fingerprint) catch |err| {
        app.toast("could not record trust in {s}: {s}", .{ store, @errorName(err) });
        return;
    };
    try app.reloadConfig(.trusted);
    app.toast("workspace trusted — {d} setting(s) now apply", .{prompt.claims.len});
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "a workspace with exec claims is asked once; Trust remembers and reloads; Don't trust leaves it stripped" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.createDirPath(t.io, "data");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data =
        \\.{
        \\    .editor = .{ .tab_width = 3 },
        \\    .lsp = .{ .zig = .{ .cmd = "zls" } },
        \\    .formatters = .{ .zig = .{ .cmd = .{ "zig", "fmt" } } },
        \\}
    });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    try vars.put("MNML_DATA_ROOT", data);
    const opts: config.load.Options = .{ .workspace = ws, .trust = .ask, .data_root = data, .env = .{ .vars = &vars } };

    // First open: stripped, and the dialog is up with both claims listed.
    {
        const loaded = try config.load.load(t.allocator, t.io, opts);
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data });
        defer app.deinit();
        try t.expect(app.cfg.lsp.get("zig").?.cmd == null);
        try t.expectEqual(@as(u8, 3), app.cfg.editor.tab_width);
        try t.expect(app.overlay == .confirm);
        try t.expect(app.overlay.confirm.purpose == .trust_workspace);
        try t.expectEqual(@as(usize, 1), app.overlay.confirm.state.selected);
        try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "language server zig — runs `zls`") != null);
        try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "format on save zig — runs `zig fmt`") != null);
        // Don't trust: nothing recorded, nothing applied.
        try app.handle(.{ .key = app_mod.Key.named(.enter) });
        try t.expect(app.overlay == .none);
        try t.expect(app.cfg.lsp.get("zig").?.cmd == null);
        try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "data/trusted_workspaces.zon", .{}));
    }
    // Second open: asked again; Trust applies the layer and records it.
    {
        const loaded = try config.load.load(t.allocator, t.io, opts);
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data });
        defer app.deinit();
        try t.expect(app.overlay == .confirm);
        try app.handle(.{ .key = app_mod.Key.char('t') });
        try t.expect(app.overlay == .none);
        try t.expectEqualStrings("zls", app.cfg.lsp.get("zig").?.cmd.?);
        try t.expectEqual(@as(usize, 2), app.cfg.formatters.get("zig").?.cmd.len);
        try t.expect(app.loaded.?.trust_prompt == null);
        try tmp.dir.access(t.io, "data/trusted_workspaces.zon", .{});
    }
    // Third open: remembered — no dialog, layer applied.
    {
        const loaded = try config.load.load(t.allocator, t.io, opts);
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data });
        defer app.deinit();
        try t.expect(app.overlay == .none);
        try t.expectEqualStrings("zls", app.cfg.lsp.get("zig").?.cmd.?);
    }
    // A changed command: asked again.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data = ".{ .lsp = .{ .zig = .{ .cmd = \"curl x | sh\" } } }" });
    {
        const loaded = try config.load.load(t.allocator, t.io, opts);
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data });
        defer app.deinit();
        try t.expect(app.overlay == .confirm);
        try t.expect(app.cfg.lsp.get("zig").?.cmd == null);
    }
    // No claims at all: nothing to ask.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data = ".{ .editor = .{ .tab_width = 5 } }" });
    {
        const loaded = try config.load.load(t.allocator, t.io, opts);
        var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = data });
        defer app.deinit();
        try t.expect(app.overlay == .none);
        try t.expectEqual(@as(u8, 5), app.cfg.editor.tab_width);
    }
}
