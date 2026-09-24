//! The startup picker — what to do when mnml opens on nothing in
//! particular. Shown from the `startup` hook when `MNML_STARTUP_PICKER=1`
//! is set (the way a Finder / desktop launcher asks for it) or when the
//! workspace is `$HOME` (a launch with no argument from the home
//! directory); `app.startup_picker` opens it any time. Rows: a new file,
//! the file finder, the most recent files of this workspace, and the
//! configured `.workspaces`.
//!
//! // changed: Rust's picker switched workspaces in place. mnml-zig has
//! one workspace per process, so a workspace row tells you the command
//! to relaunch with instead — in-app switching is on the Remaining list
//! in `docs/PARITY.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const hooks = @import("../core/hooks.zig");
const os_path = @import("../core/os_path.zig");
const cmd_picker = @import("cmd_picker.zig");

pub const table = .{
    .@"app.startup_picker" = &show,
};

const new_file = "New file";
const open_file = "Open file…";
const ws_prefix = "workspace: ";
const max_recent = 9;

pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    if (!wanted(app)) return;
    // The trust dialog and the first-launch wizard come first.
    if (app.overlay != .none) return;
    show(app) catch {};
}

fn wanted(app: *App) bool {
    if (app.env.get("MNML_STARTUP_PICKER")) |v| if (std.mem.eql(u8, v, "1")) return true;
    // `HOME`, else `USERPROFILE`: launched from the Windows home too.
    const home = os_path.home(&app.env) orelse return false;
    const seps = if (os_path.Rules.native.drives) "/\\" else "/";
    return std.mem.eql(u8, std.mem.trimEnd(u8, home, seps), std.mem.trimEnd(u8, app.workspace, seps));
}

pub fn show(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    var hints: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
        for (hints.items) |h| gpa.free(h);
        hints.deinit(gpa);
    }
    try labels.append(gpa, try gpa.dupe(u8, new_file));
    try details.append(gpa, try gpa.dupe(u8, "a scratch buffer"));
    try hints.append(gpa, try gpa.dupe(u8, "1"));
    try labels.append(gpa, try gpa.dupe(u8, open_file));
    try details.append(gpa, try gpa.dupe(u8, "the file finder"));
    try hints.append(gpa, try gpa.dupe(u8, "2"));
    var n: usize = 3;
    var i = app.recent.items.len;
    while (i > 0 and n <= 2 + max_recent) {
        i -= 1;
        try labels.append(gpa, try gpa.dupe(u8, app.relPath(app.recent.items[i])));
        try details.append(gpa, try gpa.dupe(u8, "recent"));
        try hints.append(gpa, if (n <= 9) try std.fmt.allocPrint(gpa, "{d}", .{n}) else try gpa.dupe(u8, ""));
        n += 1;
    }
    for (app.cfg.workspaces) |w| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ ws_prefix, if (w.name.len > 0) w.name else w.path }));
        try details.append(gpa, try gpa.dupe(u8, w.path));
        try hints.append(gpa, try gpa.dupe(u8, ""));
    }
    try cmd_picker.openPickerWith(app, "mnml — where to?", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try hints.toOwnedSlice(gpa));
    app.overlay.picker.on_accept = &accept;
}

fn accept(app: *App, idx: usize, label: []const u8) Allocator.Error!void {
    _ = idx;
    if (std.mem.eql(u8, label, new_file)) {
        _ = app.openScratch() catch return error.OutOfMemory;
        return;
    }
    if (std.mem.eql(u8, label, open_file)) {
        command.run(app, .{ .static = .@"picker.files" }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        return;
    }
    if (std.mem.startsWith(u8, label, ws_prefix)) {
        const name = label[ws_prefix.len..];
        for (app.cfg.workspaces) |w| {
            if (std.mem.eql(u8, name, if (w.name.len > 0) w.name else w.path)) {
                app.toast("open it with: mnml-zig {s}", .{w.path});
                return;
            }
        }
        return;
    }
    const abs = try app.absPath(label);
    _ = app.openPath(abs) catch |err| {
        app.toast("open {s}: {s}", .{ label, @errorName(err) });
    };
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "startup picker: rows for new / open / recent / workspaces; 1 opens a scratch buffer; shown for $HOME" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "r.txt", .data = "r" });
    var cfg: app_mod.Config = .{};
    const ws = [_]app_mod.Config.Workspace{.{ .name = "site", .path = "/srv/site" }};
    cfg.workspaces = &ws;
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = cfg, .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    const r = try std.fs.path.join(t.allocator, &.{ root, "r.txt" });
    defer t.allocator.free(r);
    try app.noteRecent(r);
    try command.run(&app, .{ .static = .@"app.startup_picker" });
    try t.expect(app.overlay == .picker);
    const p = &app.overlay.picker;
    try t.expectEqual(@as(usize, 4), p.labels.len);
    try t.expectEqualStrings("Open file…", p.labels[1]);
    try t.expectEqualStrings("r.txt", p.labels[2]);
    try t.expectEqualStrings("workspace: site", p.labels[3]);
    // Enter on the first row: a scratch buffer.
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("[scratch]", app.panes.get(app.active.?).?.title());
    // The workspace row explains the relaunch.
    try show(&app);
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try app.handle(.{ .key = app_mod.Key.named(.down) });
    try app.handle(.{ .key = app_mod.Key.named(.enter) });
    try t.expectEqualStrings("open it with: mnml-zig /srv/site", app.lastToast().?);
    // Not wanted for an ordinary workspace; wanted when it is $HOME or asked for.
    try t.expect(!wanted(&app));
    try app.env.put("MNML_STARTUP_PICKER", "1");
    try t.expect(wanted(&app));
    _ = app.env.swapRemove("MNML_STARTUP_PICKER");
    try app.env.put("HOME", root);
    try t.expect(wanted(&app));
}
