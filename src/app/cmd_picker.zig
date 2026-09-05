//! `picker.*` runners and the palette: the buffer switcher, the
//! workspace file picker, the recent-files list, the tab-page switcher
//! and the command palette. All fill the one picker overlay;
//! `dispatch.refilterPicker` scores the labels against the query and
//! `accept` acts on the pick by kind.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Picker = app_mod.Picker;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const dispatch = @import("dispatch.zig");
const keymap = @import("../core/keymap.zig");
const cmd_tab = @import("cmd_tab.zig");
const runners = @import("runners.zig");
const tasks = @import("tasks.zig");
const ai_app = @import("ai.zig");
const dap = @import("dap.zig");
const lsp = @import("lsp.zig");

pub const table = .{
    .@"picker.buffers" = &buffers,
    .@"picker.files" = &files,
    .@"picker.recent" = &recent,
    .palette = &palette,
};

/// Open the one picker overlay over `labels` (gpa-owned, taken over)
/// with `panes` parallel to it (empty when not a buffer list).
pub fn open(app: *App, title: []const u8, kind: app_mod.PickerKind, labels: [][]u8, panes: []PaneId) CommandError!void {
    return openPicker(app, title, kind, labels, panes);
}

/// The label under the picker's cursor, or null on an empty list.
pub fn cursorLabel(app: *App) ?[]const u8 {
    const p = &app.overlay.picker;
    if (p.state.cursor >= p.filtered.items.len) return null;
    return p.labels[p.filtered.items[p.state.cursor]];
}

/// Directories a workspace walk never enters.
const skip_dirs = [_][]const u8{ ".git", "node_modules", "target", "zig-out", ".zig-cache", "zig-cache", ".mnml", "vendor", "dist", "build" };
/// Cap so a huge tree does not stall the UI thread; the picker says so.
pub const max_files = 5000;

fn buffers(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var panes: std.ArrayListUnmanaged(PaneId) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        panes.deinit(gpa);
    }
    // Tab order first (every leaf of the current layout), then anything
    // open in the background.
    const layout = app.layouts.current();
    const ordered = try layout.allPanes(app.frame.allocator());
    for (ordered) |id| try pushBuffer(app, &labels, &panes, id);
    for (app.panes.slots.items, 0..) |*slot, i| {
        if (slot.* == null) continue;
        const id: PaneId = @intCast(i);
        if (std.mem.indexOfScalar(PaneId, panes.items, id) != null) continue;
        try pushBuffer(app, &labels, &panes, id);
    }
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no open buffers", .{});
    try openPicker(app, "Buffers", .buffers, try labels.toOwnedSlice(gpa), try panes.toOwnedSlice(gpa));
}

fn pushBuffer(app: *App, labels: *std.ArrayListUnmanaged([]u8), panes: *std.ArrayListUnmanaged(PaneId), id: PaneId) CommandError!void {
    const gpa = app.gpa;
    const p = app.panes.get(id) orelse return;
    const label = switch (p.*) {
        .editor => |*e| try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (e.buf.path) |path| app.relPath(path) else "[scratch]", if (e.buf.dirty) " ●" else "" }),
        .outline => |*o| try std.fmt.allocPrint(gpa, "outline: {s}", .{o.title}),
        .md_preview => |*m| try std.fmt.allocPrint(gpa, "{s} (preview)", .{app.relPath(m.path)}),
        .pty => |*term| try std.fmt.allocPrint(gpa, "{s} [term]", .{term.label}),
        else => try gpa.dupe(u8, p.title()),
    };
    errdefer gpa.free(label);
    try labels.append(gpa, label);
    try panes.append(gpa, id);
}

fn files(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    const truncated = try walk(app, &labels);
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no files under {s}", .{app.workspace});
    std.mem.sort([]u8, labels.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try openPicker(app, if (truncated) "Files (first 5000)" else "Files", .files, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

/// Every regular file under the workspace, workspace-relative, hidden
/// entries and the usual build dirs skipped. Returns whether the cap hit.
fn walk(app: *App, out: *std.ArrayListUnmanaged([]u8)) CommandError!bool {
    const gpa = app.gpa;
    var dir = std.Io.Dir.cwd().openDir(app.io, app.workspace, .{ .iterate = true }) catch |err| return app.diag.fail(app.frame.allocator(), "cannot open {s}: {s}", .{ app.workspace, @errorName(err) });
    defer dir.close(app.io);
    var walker = dir.walk(gpa) catch return error.OutOfMemory;
    defer walker.deinit();
    while (walker.next(app.io) catch null) |entry| {
        if (entry.basename.len > 0 and entry.basename[0] == '.') {
            if (entry.kind == .directory) walker.leave(app.io);
            continue;
        }
        if (entry.kind == .directory) {
            for (skip_dirs) |s| if (std.mem.eql(u8, entry.basename, s)) {
                walker.leave(app.io);
                break;
            };
            continue;
        }
        if (entry.kind != .file) continue;
        if (out.items.len >= max_files) return true;
        const rel = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(rel);
        try out.append(gpa, rel);
    }
    return false;
}

/// Takes ownership of `labels` and `panes` (gpa).
pub fn openPicker(app: *App, title: []const u8, kind: app_mod.PickerKind, labels: [][]u8, panes: []PaneId) CommandError!void {
    return openPickerWith(app, title, kind, labels, panes, &.{}, &.{});
}

/// As `openPicker`, with the muted detail and the chord hint per row
/// (both owned; empty slices when the picker has none).
pub fn openPickerWith(app: *App, title: []const u8, kind: app_mod.PickerKind, labels: [][]u8, panes: []PaneId, details: [][]u8, hints: [][]u8) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .picker = .{ .state = .{ .title = title }, .kind = kind, .labels = labels, .panes = panes, .details = details, .hints = hints, .filtered = .empty } };
    try dispatch.refilterPicker(app);
    app.focus = .overlay;
    app.needs_render = true;
}

/// `Recent files` — newest first, the active file left out so the top
/// row is the one to switch back to.
fn recent(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    const active_path: ?[]const u8 = if (app.activeEditor()) |e| e.buf.path else null;
    var i = app.recent.items.len;
    while (i > 0) {
        i -= 1;
        const path = app.recent.items[i];
        if (active_path != null and std.mem.eql(u8, active_path.?, path)) continue;
        const label = try gpa.dupe(u8, app.relPath(path));
        errdefer gpa.free(label);
        try labels.append(gpa, label);
    }
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no recent files", .{});
    try openPicker(app, "Recent files", .recent, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
}

/// `Command palette` — every static command and every registered one,
/// title first, id as the detail, its first chord as the hint. The
/// pick's index maps back through `commandAt`.
fn palette(app: *App) CommandError!void {
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
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < command.count) : (i += 1) {
        const id: command.CommandId = @enumFromInt(i);
        try labels.append(gpa, try gpa.dupe(u8, command.title(id)));
        try details.append(gpa, try gpa.dupe(u8, command.name(id)));
        try hints.append(gpa, try gpa.dupe(u8, firstChord(app, command.spec(id).keys, &buf)));
    }
    for (app.dyn_commands.list.items, app.dyn_commands.live.items) |c, alive| {
        if (!alive) continue;
        try labels.append(gpa, try gpa.dupe(u8, c.title));
        try details.append(gpa, try gpa.dupe(u8, c.id));
        try hints.append(gpa, try gpa.dupe(u8, if (c.keys.len > 0) c.keys[0] else ""));
    }
    try openPickerWith(app, "Command palette", .commands, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try hints.toOwnedSlice(gpa));
}

/// The first default chord of a spec under the active profile, in its
/// canonical spelling.
fn firstChord(app: *App, keys: command.Keys, buf: []u8) []const u8 {
    const own = switch (App.profileOf(app.input_style)) {
        .vim => keys.vim,
        .standard => keys.standard,
    };
    const spec: []const u8 = if (keys.both.len > 0) keys.both[0] else if (own.len > 0) own[0] else return "";
    return keymap.normalizeSpec(spec, buf) orelse spec;
}

/// The command a palette row (unfiltered index) names.
fn commandAt(app: *App, i: usize) ?command.CommandRef {
    if (i < command.count) return .{ .static = @enumFromInt(i) };
    var slot: usize = 0;
    var seen: usize = command.count;
    while (slot < app.dyn_commands.list.items.len) : (slot += 1) {
        if (!app.dyn_commands.live.items[slot]) continue;
        if (seen == i) return .{ .dyn = @intCast(slot) };
        seen += 1;
    }
    return null;
}

/// The pick at `idx` (an index into the filtered order) is chosen.
pub fn accept(app: *App, idx: usize) Allocator.Error!void {
    const p = &app.overlay.picker;
    if (idx >= p.filtered.items.len) return;
    const i = p.filtered.items[idx];
    switch (p.kind) {
        .buffers => {
            const pane = p.panes[i];
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            if (app.panes.get(pane) != null) app.showPane(pane);
        },
        .files, .recent => {
            const rel = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            const abs = try app.absPath(rel);
            _ = app.openPath(abs) catch |err| {
                app.toast("open {s}: {s}", .{ rel, @errorName(err) });
                return;
            };
        },
        .themes => {
            const name = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            // The name came off the table, so the only way this fails is
            // the write — which acceptTheme has already toasted.
            @import("cmd_view.zig").acceptTheme(app, name) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
        .tabs => {
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            cmd_tab.switchTab(app, i);
        },
        .commands => {
            const ref = commandAt(app, i);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            if (ref) |r| command.run(app, r) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        },
        .lsp_locations, .lsp_code_actions, .lsp_symbols => |kind| {
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            try lsp.pickerAccept(app, kind, i);
        },
        .dap_remove_watch, .dap_exceptions, .dap_threads => |kind| {
            const label = try app.frame.allocator().dupe(u8, p.labels[i]);
            const detail = try app.frame.allocator().dupe(u8, if (i < p.details.len) p.details[i] else "");
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            try dap.pickerAccept(app, kind, label, detail);
        },
        .git => {
            const label = try app.frame.allocator().dupe(u8, p.labels[i]);
            const detail = try app.frame.allocator().dupe(u8, if (i < p.details.len) p.details[i] else "");
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            @import("git.zig").acceptPick(app, label, detail) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => {},
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("git: {s}", .{@errorName(err)}),
            };
        },
        .ai_suggest_backend => {
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            ai_app.setupAccept(app, i) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => {},
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{@errorName(err)}),
            };
        },
        .ai_session => {
            const sid = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            ai_app.sessionAccept(app, sid) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => {},
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{@errorName(err)}),
            };
        },
        .lua => {
            const label = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            const lua = app.script();
            lua.acceptItem(i, label);
            lua.pickerClosed();
        },
        .go_run_cmd, .tools, .tasks => |kind| {
            const label = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            const result = switch (kind) {
                .go_run_cmd => runners.goRunAccept(app, label),
                .tools => runners.toolAccept(app, label),
                .tasks => tasks.runNamed(app, label),
                else => unreachable,
            };
            result catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => {},
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{@errorName(err)}),
            };
        },
        .http_env_vars, .http_env_delete, .http_env_pick, .http_history, .http_captured, .http_chains, .auth_presets, .cookies_show, .cookies_delete, .http_insert_header, .http_copy_as, .http_lookup_file, .http_lookup_item, .ws_history, .browser_device, .browser_throttle, .browser_url_history => |kind| {
            const label = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            switch (kind) {
                .ws_history => _ = @import("ws_pane.zig").open(app, label) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                },
                .browser_device, .browser_throttle, .browser_url_history => try @import("cmd_browser.zig").acceptPicker(app, kind, i, label),
                else => try @import("cmd_http.zig").acceptPicker(app, kind, i, label),
            }
        },
    }
    app.needs_render = true;
}

/// The cursor moved or the filter changed: a themes picker paints the
/// candidate under the cursor. Other kinds have nothing to preview.
pub fn preview(app: *App) void {
    if (app.overlay != .picker or app.overlay.picker.kind != .themes) return;
    @import("cmd_view.zig").previewTheme(app);
}

/// The picker is closing without a pick: put a previewed theme back.
pub fn cancel(app: *App) void {
    if (app.overlay != .picker) return;
    if (app.overlay.picker.restore_theme) |th| app.setTheme(th);
    if (app.overlay.picker.kind == .lua) app.script().pickerClosed();
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const Key = app_mod.Key;

test "picker.buffers lists every open buffer, filters, and Enter switches; picker.files walks the workspace" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "src/.hidden");
    try tmp.dir.createDirPath(t.io, "node_modules/x");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.zig", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/.hidden/no.zig", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "node_modules/x/no.js", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "README.md", .data = "x" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = name });
        const path = try std.fs.path.join(t.allocator, &.{ root, name });
        defer t.allocator.free(path);
        _ = try app.openPath(path);
    }
    try command.run(&app, .{ .static = .@"picker.buffers" });
    try t.expect(app.overlay == .picker);
    try t.expectEqual(@as(usize, 3), app.overlay.picker.labels.len);
    try t.expectEqualStrings("a.txt", app.overlay.picker.labels[0]);
    // Type "a" — a.txt scores highest and sorts first; Enter switches.
    try app.handle(.{ .key = Key.char('a') });
    try t.expectEqualStrings("a.txt", app.overlay.picker.labels[app.overlay.picker.filtered.items[0]]);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqualStrings("a.txt", app.panes.get(app.active.?).?.title());

    try command.run(&app, .{ .static = .@"picker.files" });
    const labels = app.overlay.picker.labels;
    try t.expectEqual(@as(usize, 5), labels.len);
    try t.expectEqualStrings("README.md", labels[0]);
    try t.expectEqualStrings("src/main.zig", labels[4]);
    for ("main") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("main.zig", app.panes.get(app.active.?).?.title());
    try t.expectEqual(@as(usize, 4), app.panes.count());

    // Recent: newest first, the active file (main.zig) left out.
    try command.run(&app, .{ .static = .@"picker.recent" });
    try t.expectEqualStrings("Recent files", app.overlay.picker.state.title);
    try t.expectEqualStrings("c.txt", app.overlay.picker.labels[0]);
    try t.expectEqual(@as(usize, 3), app.overlay.picker.labels.len);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("c.txt", app.panes.get(app.active.?).?.title());

    // The palette lists every command with its id and chord; a pick runs it.
    try command.run(&app, .{ .static = .palette });
    try t.expectEqualStrings("Command palette", app.overlay.picker.state.title);
    try t.expectEqual(command.count, app.overlay.picker.labels.len);
    try t.expectEqualStrings("app.quit", app.overlay.picker.details[0]);
    try t.expectEqualStrings("ctrl+q", app.overlay.picker.hints[0]);
    for ("view.toggle_wrap") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqualStrings("view.toggle_wrap", app.overlay.picker.details[app.overlay.picker.filtered.items[0]]);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqual(true, app.activeEditor().?.wrap.?);
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}
