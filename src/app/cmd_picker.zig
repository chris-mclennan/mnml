//! `picker.*` runners and the palette: the buffer switcher, the
//! workspace file picker, the recent-files list, the tab-page switcher
//! and the command palette. All fill the one picker overlay;
//! `dispatch.refilterPicker` scores the labels against the query and
//! `accept` acts on the pick by kind.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gitignore = @import("gitignore.zig");
const tree_mod = @import("tree.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Picker = app_mod.Picker;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const dispatch = @import("dispatch.zig");
const zen = @import("zen.zig");
const keymap = @import("../core/keymap.zig");
const cmd_tab = @import("cmd_tab.zig");
const runners = @import("runners.zig");
const tasks = @import("tasks.zig");
const ai_app = @import("ai.zig");
const dap = @import("dap.zig");
const lsp = @import("lsp.zig");
const context_menus = @import("context_menus.zig");
const picker_preview = @import("picker_preview.zig");
const grep_picker = @import("grep_picker.zig");
const MenuItem = command.MenuItem;
const text_field = @import("../ui/text_field.zig");

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
/// Ctrl+P's own bound: the whole tree of any ordinary monorepo (the
/// walk lists 50k files in well under a second), with a ceiling so a
/// workspace opened on a home directory cannot stall the UI thread.
pub const max_picker_files = 200_000;

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
    // open in the background — the order `:b N` counts along.
    for (try @import("cmd_buffer.zig").listOrder(app, app.frame.allocator())) |id| try pushBuffer(app, &labels, &panes, id);
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no open buffers", .{});
    try openPicker(app, "Buffers", .buffers, try labels.toOwnedSlice(gpa), try panes.toOwnedSlice(gpa));
    app.overlay.picker.state.has_preview = true;
    preview(app);
}

fn pushBuffer(app: *App, labels: *std.ArrayListUnmanaged([]u8), panes: *std.ArrayListUnmanaged(PaneId), id: PaneId) CommandError!void {
    const gpa = app.gpa;
    const p = app.panes.get(id) orelse return;
    const label = switch (p.*) {
        .editor => |*e| try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (e.buf.doc.path) |path| app.relPath(path) else e.label orelse "[scratch]", if (e.buf.doc.dirty) " ●" else "" }),
        .outline => |*o| try std.fmt.allocPrint(gpa, "outline: {s}", .{o.title}),
        .md_preview => |*m| try std.fmt.allocPrint(gpa, "{s} (preview)", .{app.relPath(m.path)}),
        .pty => |*term| try std.fmt.allocPrint(gpa, "{s} [term]", .{term.label}),
        else => try gpa.dupe(u8, p.title()),
    };
    errdefer gpa.free(label);
    try labels.append(gpa, label);
    try panes.append(gpa, id);
}

/// `Open file` — Rust's list: the workspace's recent files first,
/// then every file the tree would list, in the tree's order
/// (directories first, names folded), then recents from other
/// workspaces (their name alone, the directory as the detail, a tier
/// below). The detail is the file's directory.
fn files(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    var prio: std.ArrayListUnmanaged(u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
        prio.deinit(gpa);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    // The recents, newest first, those inside the workspace.
    var i = app.recent.items.len;
    while (i > 0) {
        i -= 1;
        const path = app.recent.items[i];
        if (!inWorkspace(app, path) or isNoise(app, app.relPath(path))) continue;
        if (!exists(app, path)) continue;
        if (seen.contains(path)) continue;
        try seen.put(gpa, path, {});
        try pushFile(gpa, &labels, &details, &prio, app.relPath(path), 2);
    }
    // The tree's files, in its order.
    var tree_files: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (tree_files.items) |f| gpa.free(f);
        tree_files.deinit(gpa);
    }
    const truncated = try walkTree(app, &tree_files);
    for (tree_files.items) |rel| {
        const abs = try app.absPath(rel);
        if (seen.contains(abs)) continue;
        try seen.put(gpa, try app.frame.allocator().dupe(u8, abs), {});
        try pushFile(gpa, &labels, &details, &prio, rel, 2);
    }
    // Recents from elsewhere, a tier below.
    i = app.recent.items.len;
    while (i > 0) {
        i -= 1;
        const path = app.recent.items[i];
        if (inWorkspace(app, path) or seen.contains(path) or !exists(app, path)) continue;
        try seen.put(gpa, path, {});
        try labels.append(gpa, try gpa.dupe(u8, std.fs.path.basename(path)));
        try details.append(gpa, try gpa.dupe(u8, std.fs.path.dirname(path) orelse ""));
        try prio.append(gpa, 1);
    }
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no files under {s}", .{app.workspace});
    const title = if (truncated) std.fmt.comptimePrint("Open file (first {d})", .{max_picker_files}) else "Open file";
    try openPickerWith(app, title, .files, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.priority = try prio.toOwnedSlice(gpa);
    app.overlay.picker.state.has_preview = true;
    try dispatch.refilterPicker(app);
    preview(app);
}

fn pushFile(gpa: Allocator, labels: *std.ArrayListUnmanaged([]u8), details: *std.ArrayListUnmanaged([]u8), prio: *std.ArrayListUnmanaged(u8), rel: []const u8, tier: u8) Allocator.Error!void {
    const label = try gpa.dupe(u8, rel);
    errdefer gpa.free(label);
    const dir = try gpa.dupe(u8, std.fs.path.dirname(rel) orelse "");
    errdefer gpa.free(dir);
    try labels.append(gpa, label);
    try details.append(gpa, dir);
    try prio.append(gpa, tier);
}

fn inWorkspace(app: *App, path: []const u8) bool {
    return std.mem.startsWith(u8, path, app.workspace) and path.len > app.workspace.len and std.fs.path.isSep(path[app.workspace.len]);
}

fn exists(app: *App, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(app.io, path, .{}) catch return false;
    return true;
}

/// Rust's `is_noise`: what Ctrl+P never lists, whatever the tree shows.
/// `.git` and `.mnml` always; `node_modules` / `.next` unless ignored
/// files are on; `target` / `dist` / `build` only outside a git repo —
/// inside one the `.gitignore`s decide, so a tracked `build/` is found.
fn isNoise(app: *App, rel: []const u8) bool {
    const all = app.tree.show_ignored;
    const in_repo = app.tree.inRepo(app);
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".git") or std.mem.eql(u8, part, ".mnml")) return true;
        if (all) continue;
        for ([_][]const u8{ "node_modules", ".next" }) |n| if (std.mem.eql(u8, part, n)) return true;
        if (in_repo) continue;
        for ([_][]const u8{ "target", "dist", "build" }) |n| if (std.mem.eql(u8, part, n)) return true;
    }
    return false;
}

/// Every file the tree would list, in the tree's order — directories
/// first, names folded to lower case, each directory's `.gitignore`
/// honoured, the artifact directories and Rust's noise skipped, hidden
/// entries as the tree shows them. Returns whether the cap hit.
pub fn walkTree(app: *App, out: *std.ArrayListUnmanaged([]u8)) CommandError!bool {
    var ignores = gitignore.Stack.init(app.gpa);
    defer ignores.deinit();
    return walkDir(app, out, "", &ignores, false);
}

fn walkDir(app: *App, out: *std.ArrayListUnmanaged([]u8), rel_dir: []const u8, ignores: *gitignore.Stack, under_ignored: bool) CommandError!bool {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const abs = if (rel_dir.len == 0) app.workspace else try std.fs.path.join(arena, &.{ app.workspace, rel_dir });
    var dir = std.Io.Dir.cwd().openDir(app.io, abs, .{ .iterate = true }) catch return false;
    defer dir.close(app.io);
    var pushed = false;
    if (dir.readFileAlloc(app.io, ".gitignore", gpa, .limited(256 * 1024))) |text| {
        defer gpa.free(text);
        try ignores.push(try gitignore.Rules.parse(gpa, rel_dir, text));
        pushed = true;
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    defer if (pushed) {
        var layer = ignores.layers.pop().?;
        layer.deinit(gpa);
    };
    const Entry = struct { rel: []u8, is_dir: bool, ignored: bool };
    var names: std.ArrayListUnmanaged(Entry) = .empty;
    defer {
        for (names.items) |n| gpa.free(n.rel);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (it.next(app.io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .file and entry.kind != .sym_link) continue;
        // A link to a folder is not a file to open, and the walk does
        // not follow it (a link can loop); the tree expands it instead.
        if (entry.kind == .sym_link) {
            const st = dir.statFile(app.io, entry.name, .{}) catch null;
            if (st != null and st.?.kind == .directory) continue;
        }
        const is_dir = entry.kind == .directory;
        if (!app.tree.show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        if (is_dir and isNoise(app, entry.name)) continue;
        const rel = if (rel_dir.len == 0) try gpa.dupe(u8, entry.name) else try std.fs.path.join(gpa, &.{ rel_dir, entry.name });
        errdefer gpa.free(rel);
        const ignored = under_ignored or (is_dir and app.tree.artifactHidden(app, entry.name)) or ignores.ignored(rel, is_dir);
        if (ignored and !app.tree.show_ignored) {
            gpa.free(rel);
            continue;
        }
        try names.append(gpa, .{ .rel = rel, .is_dir = is_dir, .ignored = ignored });
    }
    std.mem.sort(Entry, names.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.is_dir != b.is_dir) return a.is_dir;
            return std.ascii.lessThanIgnoreCase(std.fs.path.basename(a.rel), std.fs.path.basename(b.rel));
        }
    }.lt);
    for (names.items) |n| {
        if (n.is_dir) {
            if (try walkDir(app, out, n.rel, ignores, n.ignored)) return true;
        } else {
            if (out.items.len >= max_picker_files) return true;
            try out.append(gpa, try gpa.dupe(u8, n.rel));
        }
    }
    return false;
}

/// Every regular file under the workspace, workspace-relative, hidden
/// entries and the usual build dirs skipped. Returns whether the cap hit.
pub fn walk(app: *App, out: *std.ArrayListUnmanaged([]u8)) CommandError!bool {
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
    const back = app.overlayReturnFocus();
    app.overlay.deinit(app.gpa);
    const anchor: @import("../ui/overlay.zig").Anchor = if (app.cfg.ui.picker_position == .top) .top else .center;
    app.overlay = .{ .picker = .{ .state = .{ .title = title, .anchor = anchor }, .kind = kind, .labels = labels, .panes = panes, .details = details, .hints = hints, .filtered = .empty, .return_focus = back } };
    try dispatch.refilterPicker(app);
    app.focus = .overlay;
    app.needs_render = true;
}

/// The recent files, newest first, on `arena` — absolute paths
/// borrowed from `App.recent`. The active file is left out, so the top
/// row is the one to switch back to. `picker.recent` lists these, and
/// the start surface's RECENT FILES (`app/welcome.zig`) does too.
pub fn recentFiles(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    const active_path: ?[]const u8 = if (app.activeEditor()) |e| e.buf.doc.path else null;
    var i = app.recent.items.len;
    while (i > 0) {
        i -= 1;
        const path = app.recent.items[i];
        if (active_path != null and std.mem.eql(u8, active_path.?, path)) continue;
        try out.append(arena, path);
    }
    return out.items;
}

/// `Recent files` — `recentFiles`, workspace-relative.
fn recent(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    for (try recentFiles(app, app.frame.allocator())) |path| {
        const label = try gpa.dupe(u8, app.relPath(path));
        errdefer gpa.free(label);
        try labels.append(gpa, label);
    }
    if (labels.items.len == 0) return app.diag.fail(app.frame.allocator(), "no recent files", .{});
    try openPicker(app, "Recent files", .recent, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0));
    app.overlay.picker.state.has_preview = true;
    preview(app);
}

/// `Command palette` — every static command and every registered one
/// as Rust lists them: the row is `group  ·  title  ·  id` (the id in
/// the row is what lets a typed id find it), the detail its default
/// chords joined by ` / `. Commands of the active pane's family score
/// twenty more, Rust's pane-scoped nudge; the recently-run ones
/// (`App.recent_commands`) fifty more and a `★` on the label, and on
/// an empty query they head the list newest first (Rust's recents >
/// pane-scoped > the rest). The pick's index maps back through
/// `commandAt`.
fn palette(app: *App) CommandError!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    var bonus: std.ArrayListUnmanaged(i64) = .empty;
    var order: std.ArrayListUnmanaged(u32) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
        bonus.deinit(gpa);
        order.deinit(gpa);
    }
    const namespaces = paneNamespaces(app);
    const star: []const u8 = if (app.cfg.ui.ascii_icons) "* " else "★ ";
    var i: usize = 0;
    while (i < command.count) : (i += 1) {
        const id: command.CommandId = @enumFromInt(i);
        // A stateful row reads its state: full screen's title is the way out while inside.
        const title_text: []const u8 = if (id == .@"view.fullscreen") zen.title(app) else command.title(id);
        const rank = app.recentCommandRank(command.name(id));
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}  ·  {s}  ·  {s}", .{ if (rank != null) star else "", command.group(id), title_text, command.name(id) }));
        try details.append(gpa, try chordHint(app, gpa, command.spec(id).keys));
        const scoped: i64 = if (inNamespaces(command.name(id), namespaces)) 20 else 0;
        try bonus.append(gpa, if (rank != null) @max(scoped, 50) else scoped);
        try order.append(gpa, if (rank) |r| @intCast(r) else std.math.maxInt(u32));
    }
    for (app.dyn_commands.list.items, app.dyn_commands.live.items) |c, alive| {
        if (!alive) continue;
        const rank = app.recentCommandRank(c.id);
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}  ·  {s}", .{ if (rank != null) star else "", c.group, c.title }));
        try details.append(gpa, try std.mem.join(gpa, " / ", c.keys));
        try bonus.append(gpa, if (rank != null) 50 else 0);
        try order.append(gpa, if (rank) |r| @intCast(r) else std.math.maxInt(u32));
    }
    try openPickerWith(app, "Command palette", .commands, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.score_bonus = try bonus.toOwnedSlice(gpa);
    app.overlay.picker.order = try order.toOwnedSlice(gpa);
    try dispatch.refilterPicker(app);
}

/// The default chords of a spec under the active profile (`both` and
/// the profile's own), joined by ` / ` — Rust's `key_hint`.
pub fn chordHint(app: *App, gpa: Allocator, keys: command.Keys) Allocator.Error![]u8 {
    const vim = App.profileOf(app.input_style) == .vim;
    const own = if (vim) keys.vim else keys.standard;
    const handler: []const []const u8 = if (vim) keys.vim_handler else &.{};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for ([_][]const []const u8{ keys.both, own, handler }) |list| for (list) |spec| {
        if (out.items.len > 0) try out.appendSlice(gpa, " / ");
        var buf: [64]u8 = undefined;
        try out.appendSlice(gpa, keymap.normalizeSpec(spec, &buf) orelse spec);
    };
    return out.toOwnedSlice(gpa);
}

/// The id prefixes Rust nudges for the active pane's kind.
fn paneNamespaces(app: *App) []const []const u8 {
    const p = app.panes.get(app.active orelse return &.{}) orelse return &.{};
    return switch (p.*) {
        .pty => &.{ "term.", "pty.", "session." },
        .editor => &.{ "editor.", "buffer.", "lsp.", "vim." },
        .request => &.{ "http.", "chain." },
        .diff => &.{ "diff.", "git." },
        .md_preview => &.{ "md.", "editor." },
        .zon => &.{ "zon.", "file." },
        else => &.{},
    };
}

fn inNamespaces(id: []const u8, namespaces: []const []const u8) bool {
    for (namespaces) |ns| if (std.mem.startsWith(u8, id, ns)) return true;
    return false;
}

/// The command ids of the palette's rows, for `Picker.rank`'s boosts.
pub fn commandIds(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    const p = &app.overlay.picker;
    const out = try arena.alloc([]const u8, p.labels.len);
    for (out, 0..) |*slot, i| slot.* = if (commandAt(app, i)) |ref| switch (ref) {
        .static => |id| command.name(id),
        .dyn => |slot_i| app.dyn_commands.list.items[slot_i].id,
    } else "";
    return out;
}

/// The command a palette row (unfiltered index) names.
pub fn commandAt(app: *const App, i: usize) ?command.CommandRef {
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

/// // changed (lua-track): the id of a command, built-in or script.
pub fn idOf(app: *App, ref: command.CommandRef) []const u8 {
    return switch (ref) {
        .static => |id| command.name(id),
        .dyn => |slot| app.dyn_commands.list.items[slot].id,
    };
}

/// // changed (lua-track): right-click on a palette row — Run, Bind in
/// init.lua…, Copy id. The menu takes the palette's place.
pub fn openRowMenu(app: *App, idx: usize, x: u16, y: u16) Allocator.Error!void {
    const p = &app.overlay.picker;
    if (idx >= p.filtered.items.len) return;
    const ref = commandAt(app, p.filtered.items[idx]) orelse return;
    var mem = std.heap.ArenaAllocator.init(app.gpa);
    errdefer mem.deinit();
    const id = try mem.allocator().dupe(u8, idOf(app, ref));
    const rows = try app.gpa.dupe(MenuItem, &.{
        .{ .label = "Run", .action = switch (ref) {
            .static => |s| .{ .command = s },
            .dyn => |d| .{ .dyn = d },
        } },
        .{ .label = "Bind in init.lua\u{2026}", .action = .{ .lua_bind = id }, .separator_before = true },
        .{ .label = "Copy id", .action = .{ .copy_text = id } },
    });
    errdefer app.gpa.free(rows);
    try context_menus.openOwned(app, id, rows, x, y, mem);
}

/// The pick at `idx` (an index into the filtered order) is chosen.
/// Shift+Delete on a `.custom` picker that can remove its rows: the
/// cursor row goes to `on_delete`, which asks through the shared confirm
/// (so the picker closes for the box).
pub fn deleteRow(app: *App) Allocator.Error!void {
    const p = &app.overlay.picker;
    const f = p.on_delete orelse return;
    if (p.state.cursor >= p.filtered.items.len) return;
    const i = p.filtered.items[p.state.cursor];
    const label = try app.frame.allocator().dupe(u8, p.labels[i]);
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    try f(app, i, label);
}

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
        .grep => {
            if (i >= p.grep_hits.len) return;
            const row = p.grep_hits[i];
            const owned: app_mod.GrepRow = .{ .path = try app.frame.allocator().dupe(u8, row.path), .line = row.line, .col = row.col, .len = row.len };
            grep_picker.stop(app);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            try grep_picker.accept(app, owned);
        },
        .integrations_details, .integrations_manifest, .integrations_toggle, .integrations_remove, .integrations_copy_id, .integrations_pin, .integrations_unpin, .integrations_toggle_bar => |kind| {
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            try @import("integrations.zig").acceptPicker(app, kind, i);
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
        .snippets => {
            const trigger = try app.frame.allocator().dupe(u8, p.labels[i]);
            const scope = try app.frame.allocator().dupe(u8, if (i < p.hints.len) p.hints[i] else "global");
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            try @import("snippets.zig").pickerAccept(app, trigger, scope);
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
            const sid = try app.frame.allocator().dupe(u8, if (i < p.values.len) p.values[i] else p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            ai_app.sessionAccept(app, sid) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => {},
                else => if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{@errorName(err)}),
            };
        },
        .lua => {
            // The marked rows when the picker is multi-select and any
            // are marked, else the row under the cursor.
            const arena = app.frame.allocator();
            var rows: std.ArrayListUnmanaged(usize) = .empty;
            var labels: std.ArrayListUnmanaged([]const u8) = .empty;
            for (p.marked, 0..) |on, n| if (on) {
                try rows.append(arena, n);
                try labels.append(arena, try arena.dupe(u8, p.labels[n]));
            };
            // Every field of `p` is read BEFORE the overlay goes: its
            // memory is the union's, and `deinit` leaves `.none` there.
            const multi_source = p.state.multi;
            const multi = multi_source and rows.items.len > 0;
            if (!multi) {
                rows.clearRetainingCapacity();
                labels.clearRetainingCapacity();
                try rows.append(arena, i);
                try labels.append(arena, try arena.dupe(u8, p.labels[i]));
            }
            const source_id = try arena.dupe(u8, p.lua_source);
            // The state that registered the source — an installed
            // script's own, or `init.lua`'s — holds its rows and refs.
            const lua = app.luaState(p.lua_state) orelse app.script();
            const source_accept: ?command.LuaRef = if (lua.findSource(source_id)) |src| src.on_accept else null;
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            // The row's own `on_accept` first (the shape that shipped),
            // then the source's — a source may have either or both.
            if (!multi) lua.acceptItem(i, labels.items[0]);
            if (source_accept) |r| lua.acceptSource(r, rows.items, labels.items, multi_source);
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
        .icon_glyphs => try @import("icon_picker.zig").accept(app, i),
        .bookmarks => {
            const url = try app.frame.allocator().dupe(u8, if (i < p.details.len) p.details[i] else "");
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            @import("git.zig").openExternal(app, url);
        },
        .custom => {
            const f = p.on_accept orelse {
                app.overlay.deinit(app.gpa);
                app.focus = if (app.active) |a| .{ .pane = a } else .tree;
                return;
            };
            const label = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            try f(app, i, label);
        },
        .http_env_vars, .http_env_delete, .http_env_pick, .http_history, .http_captured, .http_chains, .auth_presets, .cookies_show, .cookies_delete, .http_insert_header, .http_copy_as, .http_lookup_file, .http_lookup_item, .http_find_request, .http_move_target, .ws_history, .browser_device, .browser_throttle, .browser_url_history, .browser_tab => |kind| {
            const label = try app.frame.allocator().dupe(u8, p.labels[i]);
            app.overlay.deinit(app.gpa);
            app.focus = if (app.active) |a| .{ .pane = a } else .tree;
            switch (kind) {
                .ws_history => _ = @import("ws_pane.zig").open(app, label) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                },
                .browser_device, .browser_throttle, .browser_url_history, .browser_tab => try @import("cmd_browser.zig").acceptPicker(app, kind, i, label),
                else => try @import("cmd_http.zig").acceptPicker(app, kind, i, label),
            }
        },
    }
    app.needs_render = true;
}

/// The cursor moved or the filter changed: a themes picker paints the
/// candidate under the cursor; a picker with a preview column refills
/// it. Other kinds have nothing to preview.
pub fn preview(app: *App) void {
    if (app.overlay != .picker) return;
    if (app.overlay.picker.kind == .themes) return @import("cmd_view.zig").previewTheme(app);
    // A `.lua` source with a preview column: the cursor moved.
    if (app.overlay.picker.kind == .lua) return @import("../scripting/api.zig").refreshPreview(app) catch {};
    fillPreview(app) catch {};
}

/// The preview column's rows for the cursor row, by kind: a file picker
/// previews the file, a buffer picker the buffer's own bytes (dirty
/// ones included — a preview shows what you would switch to, not what
/// is on disk), a grep picker the file around the hit.
fn fillPreview(app: *App) Allocator.Error!void {
    const p = &app.overlay.picker;
    if (!p.state.has_preview) return;
    app_mod.Overlay.freePreview(app.gpa, p.preview);
    p.preview = &.{};
    p.state.preview_focus = null;
    p.state.preview_scroll = 0;
    app.needs_render = true;
    if (p.state.cursor >= p.filtered.items.len) return;
    const idx = p.filtered.items[p.state.cursor];
    switch (p.kind) {
        .buffers => {
            const id = if (idx < p.panes.len) p.panes[idx] else return;
            const pane = app.panes.get(id) orelse return;
            switch (pane.*) {
                .editor => |*e| {
                    const built = try picker_preview.build(app, e.buf.editor.bytes(), e.buf.doc.path, null);
                    p.preview = built.rows;
                    p.state.preview_focus = built.focus;
                },
                else => p.preview = try picker_preview.note(app, "  (no preview)"),
            }
        },
        .files, .recent, .grep => {
            const path = try previewPath(app, p, idx) orelse return;
            // An open buffer answers for its file: what you would see.
            if (app.panes.findPath(path)) |id| if (app.panes.get(id)) |pane| switch (pane.*) {
                .editor => |*e| {
                    const built = try picker_preview.build(app, e.buf.editor.bytes(), path, hitOf(p, idx));
                    p.preview = built.rows;
                    p.state.preview_focus = built.focus;
                    return;
                },
                else => {},
            };
            const text = (try readHead(app, path)) orelse {
                p.preview = try picker_preview.note(app, "  (cannot read)");
                return;
            };
            if (std.mem.indexOfScalar(u8, text, 0) != null) {
                p.preview = try picker_preview.note(app, "  (binary)");
                return;
            }
            const built = try picker_preview.build(app, text, path, hitOf(p, idx));
            p.preview = built.rows;
            p.state.preview_focus = built.focus;
        },
        else => {},
    }
}

/// The absolute path row `idx` names. A workspace file's label is its
/// relative path; a recent from elsewhere is a basename whose detail is
/// the absolute directory.
fn previewPath(app: *App, p: anytype, idx: usize) Allocator.Error!?[]const u8 {
    if (p.kind == .grep) return if (idx < p.grep_hits.len) p.grep_hits[idx].path else null;
    const label = p.labels[idx];
    if (idx < p.details.len and p.details[idx].len > 0 and std.fs.path.isAbsolute(p.details[idx])) {
        return try std.fs.path.join(app.frame.allocator(), &.{ p.details[idx], label });
    }
    return try app.absPath(label);
}

/// The line a grep row points at; null for every other kind.
fn hitOf(p: anytype, idx: usize) ?picker_preview.Hit {
    if (p.kind != .grep or idx >= p.grep_hits.len) return null;
    const h = p.grep_hits[idx];
    return .{ .line = h.line, .col = h.col, .len = h.len };
}

/// The first `picker_preview.max_bytes` of `path`, on the frame arena.
/// A file too big to read whole is read short rather than refused.
fn readHead(app: *App, path: []const u8) Allocator.Error!?[]const u8 {
    var file = std.Io.Dir.cwd().openFile(app.io, path, .{}) catch return null;
    defer file.close(app.io);
    const arena = app.frame.allocator();
    const buf = try arena.alloc(u8, picker_preview.max_bytes);
    var rbuf: [4096]u8 = undefined;
    var r = file.reader(app.io, &rbuf);
    const n = r.interface.readSliceShort(buf) catch 0;
    return buf[0..n];
}

/// Tab on a row of a multi-select picker: mark it, or unmark it.
pub fn toggleMark(app: *App, idx: usize) void {
    if (app.overlay != .picker) return;
    const p = &app.overlay.picker;
    if (idx >= p.filtered.items.len) return;
    const i = p.filtered.items[idx];
    if (i >= p.marked.len) return;
    p.marked[i] = !p.marked[i];
    // Tab steps on, so a run of rows is marked by holding it.
    p.state.cursor = @min(idx + 1, p.filtered.items.len -| 1);
    preview(app);
    app.needs_render = true;
}

/// The live source's debounce (`App.tick`).
pub fn tick(app: *App, now: i64) Allocator.Error!void {
    try @import("../scripting/api.zig").tickLivePicker(app, now);
    try grep_picker.tick(app, now);
}

pub fn nextDeadlineMs(app: *const App) ?i64 {
    const lua = @import("../scripting/api.zig").nextPickerDeadlineMs(app);
    const gp = grep_picker.nextDeadlineMs(app);
    if (lua == null) return gp;
    if (gp == null) return lua;
    return @min(lua.?, gp.?);
}

// ─── quick open's prefixes ──────────────────────────────────────────────

/// // changed (quickopen-prefixes): VS Code's quick open is ONE widget
/// with four modes, and the mode is the FIRST character typed — `>` the
/// command palette, `@` the symbols of this file, `:` a line number,
/// `?` the list of the four. It is how a keyboard-only user gets
/// anywhere, and here it matters more than an affordance: `palette` is
/// bound to `ctrl+shift+p` and nothing else, and a terminal without the
/// kitty keyboard protocol cannot tell that from `ctrl+p` — both are
/// byte 0x10 — so on Terminal.app, Alacritty's default config or plain
/// tmux, `>` in the file picker is the last door to every command with
/// no chord of its own.
pub const QuickOpenPrefix = struct { c: u8, what: []const u8 };
pub const quick_open_prefixes = [_]QuickOpenPrefix{
    .{ .c = '>', .what = "Command palette" },
    .{ .c = '@', .what = "Symbols in this file" },
    .{ .c = ':', .what = "Go to line — :12 or :12:4" },
    .{ .c = '?', .what = "This list" },
};

/// True when `text` opened one of the four modes, so the caller does not
/// also type it into the query. Only a LEADING prefix counts: the router
/// answers false unless the box is the files picker with an empty query,
/// so `src/a>b.txt` stays a path.
pub fn quickOpenPrefix(app: *App, text: []const u8) Allocator.Error!bool {
    if (app.overlay != .picker or text.len == 0) return false;
    const p = &app.overlay.picker;
    if (p.kind != .files or p.state.query.items.len != 0) return false;
    const rest = text[1..];
    switch (text[0]) {
        '>' => try switchTo(app, .palette, rest),
        '@' => try switchTo(app, .@"lsp.symbols", rest),
        ':' => try gotoLinePrefix(app, rest),
        '?' => try prefixHelp(app),
        else => return false,
    }
    return true;
}

/// Swap quick open for the picker `id` opens, carrying `rest` in as its
/// query. A command that cannot run (no LSP behind `@`) says so through
/// the diagnostic and the box closes, rather than being left holding a
/// prefix nothing will ever match.
fn switchTo(app: *App, id: command.CommandId, rest: []const u8) Allocator.Error!void {
    if (!try runOrToast(app, id)) return;
    if (rest.len == 0 or app.overlay != .picker) return;
    const st = &app.overlay.picker.state;
    try text_field.insert(&st.query, &st.caret, app.gpa, rest);
    try dispatch.refilterPicker(app);
}

/// `:12` / `:12:4` — the app's own Go-to-line prompt, seeded with the
/// digits already typed, so Enter is the only key left.
fn gotoLinePrefix(app: *App, rest: []const u8) Allocator.Error!void {
    if (!try runOrToast(app, .@"editor.goto_line")) return;
    if (rest.len == 0 or app.overlay != .prompt) return;
    try app.overlay.prompt.state.setText(app.gpa, rest);
}

/// Run `id`, reporting a failure the way every other command does.
/// False when it did not run — `@` on a file with no language server
/// says so and leaves quick open exactly as it was, rather than closing
/// the box or typing the prefix in as a filename.
fn runOrToast(app: *App, id: command.CommandId) Allocator.Error!bool {
    command.run(app, .{ .static = id }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("{s}", .{@errorName(err)});
            return false;
        },
    };
    return true;
}

/// The `?` list: every prefix with what it does, and picking a row puts
/// quick open into that mode.
fn prefixHelp(app: *App) Allocator.Error!void {
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (quick_open_prefixes) |pf| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{c}  ·  {s}", .{ pf.c, pf.what }));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{c} in Open file", .{pf.c}));
    }
    openPickerWith(app, "Quick open prefixes", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    app.overlay.picker.on_accept = &acceptPrefixHelp;
}

fn acceptPrefixHelp(app: *App, idx: usize, _: []const u8) Allocator.Error!void {
    if (idx >= quick_open_prefixes.len) return;
    const c = quick_open_prefixes[idx].c;
    // Back to quick open, then straight into the mode the row names.
    files(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    _ = try quickOpenPrefix(app, &[_]u8{c});
}

/// The picker is closing without a pick: put a previewed theme back.
pub fn cancel(app: *App) void {
    if (app.overlay != .picker) return;
    if (app.overlay.picker.restore_theme) |th| app.setTheme(th);
    if (app.overlay.picker.kind == .grep) grep_picker.stop(app);
    if (app.overlay.picker.kind == .lua) if (app.luaState(app.overlay.picker.lua_state)) |lua| lua.pickerClosed();
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;
const Key = app_mod.Key;

test "// changed (quickopen-prefixes): only a LEADING > @ : ? switches quick open's mode" {
    // The fixture is a file named `a>b.txt` — the point is a `>` that is
    // not leading — and Windows allows no `>` in a file name.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a>b.txt", .data = "x" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(t.allocator, &.{ root, "a>b.txt" });
    defer t.allocator.free(path);
    _ = try app.openPath(path);

    // `>` on an empty query is the palette, with the rest as its query.
    try command.run(&app, .{ .static = .@"picker.files" });
    try t.expectEqualStrings("Open file", app.overlay.picker.state.title);
    try t.expect(try quickOpenPrefix(&app, ">git"));
    try t.expectEqualStrings("Command palette", app.overlay.picker.state.title);
    try t.expectEqualStrings("git", app.overlay.picker.state.query.items);

    // `?` is the list of the four, and it names every one of them.
    try command.run(&app, .{ .static = .@"picker.files" });
    try t.expect(try quickOpenPrefix(&app, "?"));
    try t.expectEqualStrings("Quick open prefixes", app.overlay.picker.state.title);
    try t.expectEqual(quick_open_prefixes.len, app.overlay.picker.labels.len);

    // `:` is the app's own Go-to-line prompt, seeded with the digits.
    try command.run(&app, .{ .static = .@"picker.files" });
    try t.expect(try quickOpenPrefix(&app, ":12:4"));
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("12:4", app.overlay.prompt.state.text());
    try app.handle(.{ .key = Key.named(.esc) });

    // A prefix that is not leading is a path character: the router says
    // no, so `a>b.txt` is still typeable and still findable.
    try command.run(&app, .{ .static = .@"picker.files" });
    try Picker.paste(&app.overlay.picker.state, app.gpa, "a");
    try t.expect(!try quickOpenPrefix(&app, ">b"));
    try t.expectEqualStrings("Open file", app.overlay.picker.state.title);
    // And a character that is not a prefix at all is never the router's.
    try command.run(&app, .{ .static = .@"picker.files" });
    try t.expect(!try quickOpenPrefix(&app, "a"));
    // Nor is any of the four in a picker that is not quick open.
    try command.run(&app, .{ .static = .palette });
    try t.expect(!try quickOpenPrefix(&app, ">"));
}

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

    // Open file: the recents first (c, b, a — newest first), then the
    // tree's order (src/ before the root's files), a dotfile included.
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".env", .data = "x" });
    try command.run(&app, .{ .static = .@"picker.files" });
    try t.expectEqualStrings("Open file", app.overlay.picker.state.title);
    const labels = app.overlay.picker.labels;
    try t.expectEqual(@as(usize, 7), labels.len);
    try t.expectEqualStrings("c.txt", labels[0]);
    try t.expectEqualStrings("a.txt", labels[2]);
    try sdk_testing.expectPath("src/.hidden/no.zig", labels[3]);
    try sdk_testing.expectPath("src/main.zig", labels[4]);
    try t.expectEqualStrings("src", app.overlay.picker.details[4]);
    try t.expectEqualStrings(".env", labels[5]);
    try t.expectEqualStrings("README.md", labels[6]);
    try t.expectEqualStrings("", app.overlay.picker.details[6]);
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
    try t.expectEqualStrings("app  ·  Quit mnml  ·  app.quit", app.overlay.picker.labels[0]);
    try t.expectEqualStrings("ctrl+q", app.overlay.picker.details[0]);
    // An editor is active: its family scores twenty more.
    try t.expectEqual(@as(i64, 0), app.overlay.picker.score_bonus[0]);
    try t.expectEqual(@as(i64, 20), app.overlay.picker.score_bonus[@intFromEnum(command.CommandId.@"editor.undo")]);
    for ("view.toggle_wrap") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqualStrings("view  ·  Toggle word wrap (vim :set wrap)  ·  view.toggle_wrap", app.overlay.picker.labels[app.overlay.picker.filtered.items[0]]);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqual(true, app.activeEditor().?.wrap.?);
}

test "picker.files lists every file of a tree past 5000: the 5101st is found by name" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "aaa");
    try tmp.dir.createDirPath(t.io, "zzz");
    var nb: [32]u8 = undefined;
    for (0..5100) |i| try tmp.dir.writeFile(t.io, .{ .sub_path = try std.fmt.bufPrint(&nb, "aaa/f{d}.txt", .{i}), .data = "" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "zzz/zz_target.txt", .data = "" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"picker.files" });
    try t.expectEqualStrings("Open file", app.overlay.picker.state.title);
    try t.expectEqual(@as(usize, 5101), app.overlay.picker.labels.len);
    for ("zz_target") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expect(app.overlay.picker.filtered.items.len >= 1);
    try sdk_testing.expectPath("zzz/zz_target.txt", app.overlay.picker.labels[app.overlay.picker.filtered.items[0]]);
}

test "Ctrl+S saves from the palette and from the find bar; both stay open" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "alpha\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    const path = try std.fs.path.join(t.allocator, &.{ root, "a.txt" });
    defer t.allocator.free(path);
    _ = try app.openPath(path);
    const e = app.activeEditor().?;
    _ = try app.applyOps(e, &.{.{ .insert_str = "x" }});
    try t.expect(e.buf.doc.dirty);
    try command.run(&app, .{ .static = .palette });
    try app.handle(.{ .key = Key.ctrl('s') });
    try t.expect(!e.buf.doc.dirty);
    try t.expect(app.overlay == .picker);
    try app.handle(.{ .key = Key.named(.esc) });
    _ = try app.applyOps(e, &.{.{ .insert_str = "y" }});
    try command.run(&app, .{ .static = .@"find.find" });
    try app.handle(.{ .key = Key.char('a') });
    try app.handle(.{ .key = Key.ctrl('s') });
    try t.expect(!e.buf.doc.dirty);
    try t.expect(app.find_bar != null);
    try t.expectEqualStrings("a", app.find_bar.?.state.queryText());
    // A leader prefix stays with the widget: nothing pends, nothing opens.
    try app.handle(.{ .key = Key.ctrl('k') });
    try t.expect(app.find_bar != null);
    try t.expect(app.overlay == .none);
    try t.expectEqual(@as(usize, 0), app.chord.len);
    const saved = try tmp.dir.readFileAlloc(t.io, "a.txt", t.allocator, .limited(64));
    defer t.allocator.free(saved);
    try t.expectEqualStrings("xyalpha\n", saved);
}

test "right-click on a palette row: Run, Bind in init.lua…, Copy id — titled with the command's id" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try command.run(&app, .{ .static = .palette });
    for ("file.save") |c| try app.handle(.{ .key = Key.char(c) });
    try openRowMenu(&app, 0, 3, 3);
    try t.expect(app.overlay == .menu);
    try t.expect(std.mem.startsWith(u8, app.overlay.menu.title, "file.save"));
    const items = app.overlay.menu.items;
    try t.expectEqual(@as(usize, 3), items.len);
    try t.expectEqualStrings("Run", items[0].label);
    try t.expect(items[0].action == .command);
    try t.expectEqualStrings("Bind in init.lua…", items[1].label);
    try t.expectEqualStrings(app.overlay.menu.title, items[1].action.lua_bind);
    try t.expectEqualStrings("Copy id", items[2].label);
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

test "the empty palette pins the recently-run commands first, newest first and ★-marked; a query still ranks by match" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = App.scratch_workspace, .cols = 120, .rows = 40 });
    defer app.deinit();
    try command.run(&app, .{ .static = .noop });
    try command.run(&app, .{ .static = .@"view.toggle_line_numbers" });
    try command.run(&app, .{ .static = .noop });
    try std.testing.expectEqual(@as(usize, 2), app.recent_commands.items.len);
    try std.testing.expectEqualStrings("noop", app.recent_commands.items[0]);
    try std.testing.expectEqualStrings("view.toggle_line_numbers", app.recent_commands.items[1]);
    try command.run(&app, .{ .static = .palette });
    const p = &app.overlay.picker;
    try std.testing.expectEqualStrings("Command palette", p.state.title);
    const first = p.labels[p.filtered.items[0]];
    const second = p.labels[p.filtered.items[1]];
    const third = p.labels[p.filtered.items[2]];
    try std.testing.expect(std.mem.startsWith(u8, first, "★ "));
    try std.testing.expect(std.mem.endsWith(u8, first, "  ·  noop"));
    try std.testing.expect(std.mem.startsWith(u8, second, "★ "));
    try std.testing.expect(std.mem.endsWith(u8, second, "  ·  view.toggle_line_numbers"));
    try std.testing.expect(!std.mem.startsWith(u8, third, "★ "));
    // `palette` itself is not a recent; the picker's own run is not either.
    try std.testing.expect(app.recentCommandRank("palette") == null);
    // A typed id still wins on its match.
    try p.state.query.appendSlice(std.testing.allocator, "app.quit");
    try dispatch.refilterPicker(&app);
    try std.testing.expect(std.mem.endsWith(u8, p.labels[p.filtered.items[0]], "  ·  app.quit"));
}
