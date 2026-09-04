//! The file tree: the left panel every session starts with, listing the
//! workspace one directory deep with expandable folders. Its rows are a
//! flat list rebuilt from the expanded set, so drawing and keyboard
//! navigation are index arithmetic; the file system is only touched on
//! `refresh`.
//!
//! State (rows, cursor, expanded set) lives here; the draw glue paints
//! with the Canvas directly and registers `.tree_node` hits; keys reach
//! it through `handleKey` when `app.focus == .tree`. The file verbs
//! (new / rename / delete / move) act on the cursor row through a
//! prompt or a confirm, so the right-click menu and the keys share them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const Rect = @import("../ui/rect.zig");
const context = @import("../ui/context.zig");
const Ui = context;

pub const table = .{
    .@"view.toggle_tree" = &toggle,
    .@"view.focus_tree" = &focus,
    .@"view.toggle_hidden" = &toggleHidden,
    .@"tree.refresh" = &refreshCmd,
    .@"tree.collapse_all" = &collapseAll,
    .@"tree.expand_all" = &expandAll,
    .@"tree.toggle_collapse_all" = &toggleCollapseAll,
    .@"tree.open_selected" = &openSelected,
    .@"tree.open_in_split" = &openInSplit,
    .@"file.new_folder" = &newFolder,
    .@"file.rename" = &rename,
    .@"file.delete" = &delete,
    .@"file.move_to" = &moveTo,
};

/// Rust mnml's default; the divider takes one more column.
pub const default_width: u16 = 30;
/// Never entered by `expand_all`; a click still opens them.
const noisy_dirs = [_][]const u8{ ".git", "node_modules", "target", "zig-out", ".zig-cache", "zig-cache" };
/// Build artifacts hidden even without a `.gitignore` — the same set
/// the file picker skips, so the two surfaces agree. `H` (show hidden)
/// reveals them like any dot entry.
pub const artifact_dirs = [_][]const u8{ "node_modules", "__pycache__", ".next", "dist", "build", "target", "vendor", ".venv", "venv", "zig-out", ".zig-cache", "zig-cache" };

pub fn isArtifactDir(name: []const u8) bool {
    for (artifact_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

pub const Row = struct {
    /// Workspace-relative, owned.
    rel: []u8,
    depth: u8,
    is_dir: bool,

    pub fn name(r: Row) []const u8 {
        return std.fs.path.basename(r.rel);
    }
};

pub const Tree = struct {
    gpa: Allocator,
    visible: bool = true,
    width: u16 = default_width,
    show_hidden: bool = false,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    /// Expanded directories, workspace-relative, owned keys.
    expanded: std.StringHashMapUnmanaged(void) = .empty,
    /// Top-level directories a refresh has already met (owned keys).
    seen_top: std.StringHashMapUnmanaged(void) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,
    loaded: bool = false,

    pub fn init(gpa: Allocator) Tree {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tree) void {
        self.clearRows();
        self.rows.deinit(self.gpa);
        var it = self.expanded.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.expanded.deinit(self.gpa);
        var st = self.seen_top.keyIterator();
        while (st.next()) |k| self.gpa.free(k.*);
        self.seen_top.deinit(self.gpa);
    }

    fn clearRows(self: *Tree) void {
        for (self.rows.items) |r| self.gpa.free(r.rel);
        self.rows.clearRetainingCapacity();
    }

    /// Rebuild the rows from disk: the root's entries, then each
    /// expanded directory's, depth first. Directories first, then
    /// files, each sorted by name. A top-level directory seen for the
    /// first time opens by itself (the noisy ones stay shut), so a
    /// folder that appears after startup is not a closed chevron the
    /// user has to find.
    pub fn refresh(self: *Tree, app: *App) Allocator.Error!void {
        self.clearRows();
        self.loaded = true;
        try self.listInto(app, "", 0);
        var opened = false;
        for (self.rows.items) |row| {
            if (!row.is_dir or row.depth != 0 or self.seen_top.contains(row.rel)) continue;
            const key = try self.gpa.dupe(u8, row.rel);
            errdefer self.gpa.free(key);
            try self.seen_top.put(self.gpa, key, {});
            if (isNoisy(row.name())) continue;
            try self.setExpanded(row.rel, true);
            opened = true;
        }
        if (opened) {
            self.clearRows();
            try self.listInto(app, "", 0);
        }
        if (self.cursor >= self.rows.items.len) self.cursor = self.rows.items.len -| 1;
    }

    fn listInto(self: *Tree, app: *App, rel_dir: []const u8, depth: u8) Allocator.Error!void {
        const gpa = self.gpa;
        const abs = if (rel_dir.len == 0) app.workspace else try std.fs.path.join(app.frame.allocator(), &.{ app.workspace, rel_dir });
        var dir = std.Io.Dir.cwd().openDir(app.io, abs, .{ .iterate = true }) catch return;
        defer dir.close(app.io);
        var names: std.ArrayListUnmanaged(Row) = .empty;
        defer names.deinit(gpa);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |entry| {
            if (!self.show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            if (!self.show_hidden and entry.kind == .directory and isArtifactDir(entry.name)) continue;
            if (entry.kind != .directory and entry.kind != .file and entry.kind != .sym_link) continue;
            const rel = if (rel_dir.len == 0) try gpa.dupe(u8, entry.name) else try std.fs.path.join(gpa, &.{ rel_dir, entry.name });
            errdefer gpa.free(rel);
            try names.append(gpa, .{ .rel = rel, .depth = depth, .is_dir = entry.kind == .directory });
        }
        std.mem.sort(Row, names.items, {}, struct {
            fn lt(_: void, a: Row, b: Row) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.mem.lessThan(u8, a.name(), b.name());
            }
        }.lt);
        for (names.items) |row| {
            try self.rows.append(gpa, row);
            if (row.is_dir and self.expanded.contains(row.rel)) try self.listInto(app, row.rel, depth + 1);
        }
    }

    pub fn isExpanded(self: *const Tree, rel: []const u8) bool {
        return self.expanded.contains(rel);
    }

    fn setExpanded(self: *Tree, rel: []const u8, on: bool) Allocator.Error!void {
        if (on) {
            if (self.expanded.contains(rel)) return;
            const key = try self.gpa.dupe(u8, rel);
            errdefer self.gpa.free(key);
            try self.expanded.put(self.gpa, key, {});
        } else if (self.expanded.fetchRemove(rel)) |kv| self.gpa.free(kv.key);
    }

    /// Enter / click: a file opens, a directory toggles.
    pub fn activate(self: *Tree, app: *App, idx: usize) Allocator.Error!void {
        if (idx >= self.rows.items.len) return;
        self.cursor = idx;
        const row = self.rows.items[idx];
        if (row.is_dir) {
            try self.setExpanded(row.rel, !self.isExpanded(row.rel));
            try self.refresh(app);
        } else {
            const rel = try app.frame.allocator().dupe(u8, row.rel);
            const abs = try app.absPath(rel);
            _ = app.openPath(abs) catch |err| app.toast("open {s}: {s}", .{ rel, @errorName(err) });
        }
        app.needs_render = true;
    }

    /// The keys the tree answers when it has focus. Returns false for a
    /// key it does not want (the chord chain gets it).
    pub fn handleKey(self: *Tree, app: *App, k: Key) Allocator.Error!bool {
        if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
        const n = self.rows.items.len;
        switch (k.code) {
            .down => self.cursor = @min(self.cursor + 1, n -| 1),
            .up => self.cursor -|= 1,
            .home => self.cursor = 0,
            .end => self.cursor = n -| 1,
            .page_down => self.cursor = @min(self.cursor + 10, n -| 1),
            .page_up => self.cursor -|= 10,
            .enter => try self.activate(app, self.cursor),
            .right => try self.expandOrOpen(app),
            .left => try self.collapseOrParent(app),
            .esc => {
                if (app.active) |a| app.focus = .{ .pane = a };
            },
            .char => |c| switch (c) {
                'j' => self.cursor = @min(self.cursor + 1, n -| 1),
                'k' => self.cursor -|= 1,
                'g' => self.cursor = 0,
                'G' => self.cursor = n -| 1,
                'l', ' ' => try self.expandOrOpen(app),
                'h' => try self.collapseOrParent(app),
                'o' => try self.activate(app, self.cursor),
                'r' => try self.refresh(app),
                'H' => {
                    self.show_hidden = !self.show_hidden;
                    try self.refresh(app);
                },
                else => return false,
            },
            else => return false,
        }
        app.needs_render = true;
        return true;
    }

    fn expandOrOpen(self: *Tree, app: *App) Allocator.Error!void {
        if (self.cursor >= self.rows.items.len) return;
        const row = self.rows.items[self.cursor];
        if (row.is_dir and !self.isExpanded(row.rel)) {
            try self.setExpanded(row.rel, true);
            try self.refresh(app);
        } else if (!row.is_dir) try self.activate(app, self.cursor);
    }

    fn collapseOrParent(self: *Tree, app: *App) Allocator.Error!void {
        if (self.cursor >= self.rows.items.len) return;
        const row = self.rows.items[self.cursor];
        if (row.is_dir and self.isExpanded(row.rel)) {
            try self.setExpanded(row.rel, false);
            try self.refresh(app);
            return;
        }
        // Jump to the parent row.
        const parent = std.fs.path.dirname(row.rel) orelse return;
        for (self.rows.items, 0..) |r, i| if (std.mem.eql(u8, r.rel, parent)) {
            self.cursor = i;
            return;
        };
    }

    /// The cursor row, or the reason there is none.
    pub fn selected(self: *const Tree, app: *App) CommandError!Row {
        if (self.cursor >= self.rows.items.len) return app.diag.fail(app.frame.allocator(), "no tree row selected", .{});
        return self.rows.items[self.cursor];
    }

    /// The row with this workspace-relative path, if listed.
    pub fn rowOf(self: *const Tree, rel: []const u8) ?usize {
        for (self.rows.items, 0..) |r, i| if (std.mem.eql(u8, r.rel, rel)) return i;
        return null;
    }

    /// The cursor row's absolute path (frame arena), for `status.json`.
    pub fn selectionPath(self: *const Tree, app: *App) Allocator.Error![]const u8 {
        if (self.cursor >= self.rows.items.len) return "";
        return app.absPath(self.rows.items[self.cursor].rel);
    }

    // ─── draw ───

    pub fn draw(self: *Tree, app: *App, ui: Ui, area: Rect) Allocator.Error!void {
        if (area.isEmpty()) return;
        if (!self.loaded) try self.refresh(app);
        ui.canvas.fill(area, app.theme.panel_bg);
        const focused = app.focus == .tree;
        const header = area.row(0);
        const title = std.fs.path.basename(app.workspace);
        const label = try std.fmt.allocPrint(ui.arena, " {s}", .{if (title.len == 0) "workspace" else title});
        _ = ui.canvas.text(header, &.{.{ .text = label, .style = if (focused) app.theme.accent else app.theme.muted }}, .{});
        if (area.h < 2) return;
        const list = area.splitTop(1).rest;
        const rows: usize = list.h;
        if (self.cursor < self.scroll) self.scroll = self.cursor;
        if (self.cursor >= self.scroll + rows) self.scroll = self.cursor + 1 - rows;
        var y: u16 = 0;
        var i = self.scroll;
        while (i < self.rows.items.len and y < list.h) : ({
            i += 1;
            y += 1;
        }) {
            const row = self.rows.items[i];
            const r = list.row(y);
            const glyph: []const u8 = if (row.is_dir) (if (self.isExpanded(row.rel)) (if (ui.ascii) "v" else "▾") else (if (ui.ascii) ">" else "▸")) else " ";
            const line = try std.fmt.allocPrint(ui.arena, "{s}{s} {s}", .{ try indent(ui.arena, row.depth), glyph, row.name() });
            const style = if (i == self.cursor and focused) app.theme.chip_active else if (i == self.cursor) app.theme.cursor_line else if (row.is_dir) app.theme.accent else app.theme.panel_bg;
            ui.canvas.fill(r, style);
            _ = ui.canvas.text(r, &.{.{ .text = line, .style = style }}, .{});
            try ui.hits.add(ui.arena, r, .{ .tree_node = @intCast(i) });
        }
    }
};

fn isNoisy(name: []const u8) bool {
    for (noisy_dirs) |nd| if (std.mem.eql(u8, name, nd)) return true;
    return false;
}

fn indent(arena: Allocator, depth: u8) Allocator.Error![]const u8 {
    const s = try arena.alloc(u8, @as(usize, depth) * 2 + 1);
    @memset(s, ' ');
    return s;
}

// ─── commands ───────────────────────────────────────────────────────────

fn openSelected(app: *App) CommandError!void {
    const row = try app.tree.selected(app);
    _ = row;
    try app.tree.activate(app, app.tree.cursor);
}

/// The selected file in a new split beside the active pane.
fn openInSplit(app: *App) CommandError!void {
    const row = try app.tree.selected(app);
    if (row.is_dir) return app.diag.fail(app.frame.allocator(), "{s} is a folder", .{row.name()});
    const rel = try app.frame.allocator().dupe(u8, row.rel);
    const abs = try app.absPath(rel);
    const cur = app.active;
    const id = app.openPath(abs) catch |err| return app.diag.fail(app.frame.allocator(), "open {s}: {s}", .{ rel, @errorName(err) });
    if (cur != null and cur.? != id) {
        app.setActive(cur.?);
        try @import("cmd_view.zig").splitWith(app, .horizontal, id);
    }
}

/// The directory a new entry beside the cursor row goes in.
fn dirBeside(app: *App) []const u8 {
    if (app.tree.cursor >= app.tree.rows.items.len) return "";
    const row = app.tree.rows.items[app.tree.cursor];
    return if (row.is_dir) row.rel else (std.fs.path.dirname(row.rel) orelse "");
}

fn openPathPrompt(app: *App, title: []const u8, purpose: app_mod.PromptPurpose, dir: []const u8) Allocator.Error!void {
    app.overlay.deinit(app.gpa);
    var state = app_mod.Prompt.init(app.gpa, title);
    if (dir.len > 0) {
        const prefill = try std.fmt.allocPrint(app.frame.allocator(), "{s}/", .{dir});
        try state.setText(app.gpa, prefill);
    }
    app.overlay = .{ .prompt = .{ .state = state, .purpose = purpose } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `file.new` with the tree focused: a path prompt, prefilled with the
/// cursor row's directory.
pub fn promptNewFile(app: *App) CommandError!void {
    const dir = try app.gpa.dupe(u8, dirBeside(app));
    errdefer app.gpa.free(dir);
    try openPathPrompt(app, "New file (workspace-relative)", .{ .new_file = dir }, dir);
}

fn newFolder(app: *App) CommandError!void {
    const dir = try app.gpa.dupe(u8, dirBeside(app));
    errdefer app.gpa.free(dir);
    try openPathPrompt(app, "New folder (workspace-relative)", .{ .new_folder = dir }, dir);
}

fn rename(app: *App) CommandError!void {
    const row = try app.tree.selected(app);
    const rel = try app.gpa.dupe(u8, row.rel);
    errdefer app.gpa.free(rel);
    app.overlay.deinit(app.gpa);
    var state = app_mod.Prompt.init(app.gpa, "Rename to (workspace-relative)");
    try state.setText(app.gpa, rel);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .rename = rel } } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const delete_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'd', .label = "Delete" }, .{ .key = 'c', .label = "Cancel" } };
pub const move_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'm', .label = "Move" }, .{ .key = 'c', .label = "Cancel" } };

fn delete(app: *App) CommandError!void {
    const row = try app.tree.selected(app);
    const rel = try app.gpa.dupe(u8, row.rel);
    errdefer app.gpa.free(rel);
    const msg = try std.fmt.allocPrint(app.gpa, "  Delete {s}{s}? This cannot be undone.", .{ rel, if (row.is_dir) "/" else "" });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Delete", .message = msg, .choices = &delete_choices },
        .purpose = .{ .delete_path = rel },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `Move to…`: a prompt for the destination folder.
fn moveTo(app: *App) CommandError!void {
    const row = try app.tree.selected(app);
    const rel = try app.gpa.dupe(u8, row.rel);
    errdefer app.gpa.free(rel);
    app.overlay.deinit(app.gpa);
    const title = try std.fmt.allocPrint(app.gpa, "Move {s} to folder", .{row.name()});
    errdefer app.gpa.free(title);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, title), .purpose = .{ .rename = rel }, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// A drag of row `from` released on directory row `into`: ask first.
pub fn confirmMove(app: *App, from_idx: usize, into_idx: usize) Allocator.Error!void {
    if (from_idx >= app.tree.rows.items.len or into_idx >= app.tree.rows.items.len) return;
    const from = app.tree.rows.items[from_idx];
    const into = app.tree.rows.items[into_idx];
    if (!into.is_dir or from_idx == into_idx) return;
    if (std.mem.startsWith(u8, into.rel, from.rel) and (into.rel.len == from.rel.len or into.rel[from.rel.len] == '/')) return;
    const from_rel = try app.gpa.dupe(u8, from.rel);
    errdefer app.gpa.free(from_rel);
    const into_rel = try app.gpa.dupe(u8, into.rel);
    errdefer app.gpa.free(into_rel);
    const msg = try std.fmt.allocPrint(app.gpa, "  Move {s} into {s}/?", .{ from.name(), into.rel });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Move to folder", .message = msg, .choices = &move_choices },
        .purpose = .{ .move_path = .{ .from = from_rel, .into = into_rel } },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

// ─── the file verbs, once confirmed ─────────────────────────────────────

fn cleanRel(app: *App, text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t/");
    if (trimmed.len == 0) return null;
    if (std.fs.path.isAbsolute(trimmed)) return app.relPath(trimmed);
    return trimmed;
}

/// The prompt's text becomes a file under `dir` (a bare name) or a
/// workspace-relative path (with a slash); it opens once created.
pub fn acceptNewFile(app: *App, dir: []const u8, text: []const u8) Allocator.Error!void {
    const rel = cleanRel(app, text) orelse return;
    const full = if (std.mem.indexOfScalar(u8, rel, '/') == null and dir.len > 0) try std.fs.path.join(app.frame.allocator(), &.{ dir, rel }) else rel;
    const abs = try app.absPath(full);
    if (std.fs.path.dirname(full)) |parent| std.Io.Dir.cwd().createDirPath(app.io, try app.absPath(parent)) catch {};
    std.Io.Dir.cwd().access(app.io, abs, .{}) catch {
        std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = abs, .data = "" }) catch |err| {
            app.toast("create {s}: {s}", .{ full, @errorName(err) });
            return;
        };
    };
    try app.tree.refresh(app);
    _ = app.openPath(abs) catch |err| app.toast("open {s}: {s}", .{ full, @errorName(err) });
    if (app.tree.rowOf(full)) |i| app.tree.cursor = i;
}

pub fn acceptNewFolder(app: *App, dir: []const u8, text: []const u8) Allocator.Error!void {
    const rel = cleanRel(app, text) orelse return;
    const full = if (std.mem.indexOfScalar(u8, rel, '/') == null and dir.len > 0) try std.fs.path.join(app.frame.allocator(), &.{ dir, rel }) else rel;
    std.Io.Dir.cwd().createDirPath(app.io, try app.absPath(full)) catch |err| {
        app.toast("mkdir {s}: {s}", .{ full, @errorName(err) });
        return;
    };
    try app.tree.refresh(app);
    if (app.tree.rowOf(full)) |i| app.tree.cursor = i;
    app.toast("created {s}/", .{full});
}

/// Rename / move `from` to the prompt's text — a path, or a folder
/// (existing) the entry moves into keeping its name.
pub fn acceptRename(app: *App, from: []const u8, text: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    var to = cleanRel(app, text) orelse return;
    if (std.mem.eql(u8, to, from)) return;
    const to_abs = try app.absPath(to);
    if (std.Io.Dir.cwd().statFile(app.io, to_abs, .{})) |st| {
        if (st.kind == .directory) to = try std.fs.path.join(arena, &.{ to, std.fs.path.basename(from) });
    } else |_| {}
    try movePath(app, from, to);
}

pub fn acceptMove(app: *App, from: []const u8, into: []const u8) Allocator.Error!void {
    const to = try std.fs.path.join(app.frame.allocator(), &.{ into, std.fs.path.basename(from) });
    try movePath(app, from, to);
}

fn movePath(app: *App, from: []const u8, to: []const u8) Allocator.Error!void {
    const from_abs = try app.absPath(from);
    const to_abs = try app.absPath(to);
    if (std.fs.path.dirname(to)) |parent| std.Io.Dir.cwd().createDirPath(app.io, try app.absPath(parent)) catch {};
    std.Io.Dir.rename(std.Io.Dir.cwd(), from_abs, std.Io.Dir.cwd(), to_abs, app.io) catch |err| {
        app.toast("move {s}: {s}", .{ from, @errorName(err) });
        return;
    };
    // An open buffer follows its file.
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asEditor()) |e| if (e.buf.path) |bp| {
        if (std.mem.eql(u8, bp, from_abs)) {
            try e.buf.setPath(to_abs);
        } else if (std.mem.startsWith(u8, bp, from_abs) and bp.len > from_abs.len and bp[from_abs.len] == '/') {
            const moved = try std.fs.path.join(app.frame.allocator(), &.{ to_abs, bp[from_abs.len + 1 ..] });
            try e.buf.setPath(moved);
        }
    };
    try app.tree.refresh(app);
    if (app.tree.rowOf(to)) |i| app.tree.cursor = i;
    app.toast("moved {s} → {s}", .{ from, to });
}

pub fn acceptDelete(app: *App, rel: []const u8) Allocator.Error!void {
    const abs = try app.absPath(rel);
    const is_dir = if (std.Io.Dir.cwd().statFile(app.io, abs, .{})) |st| st.kind == .directory else |_| false;
    const result = if (is_dir) std.Io.Dir.cwd().deleteTree(app.io, abs) else std.Io.Dir.cwd().deleteFile(app.io, abs);
    result catch |err| {
        app.toast("delete {s}: {s}", .{ rel, @errorName(err) });
        return;
    };
    // Buffers on the deleted path close (their text is gone from disk).
    var i: usize = 0;
    while (i < app.panes.slots.items.len) : (i += 1) {
        const p = &(app.panes.slots.items[i] orelse continue);
        const e = p.asEditor() orelse continue;
        const bp = e.buf.path orelse continue;
        if (std.mem.eql(u8, bp, abs) or (is_dir and std.mem.startsWith(u8, bp, abs) and bp.len > abs.len and bp[abs.len] == '/')) {
            try app.forceClosePane(@intCast(i));
        }
    }
    try app.tree.refresh(app);
    app.toast("deleted {s}", .{rel});
}

fn toggle(app: *App) CommandError!void {
    app.tree.visible = !app.tree.visible;
    if (!app.tree.visible and app.focus == .tree) {
        app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    }
    app.needs_render = true;
}

fn focus(app: *App) CommandError!void {
    app.tree.visible = true;
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .tree;
    app.needs_render = true;
}

fn toggleHidden(app: *App) CommandError!void {
    app.tree.show_hidden = !app.tree.show_hidden;
    try app.tree.refresh(app);
    app.toast("hidden files {s}", .{if (app.tree.show_hidden) "shown" else "hidden"});
}

fn refreshCmd(app: *App) CommandError!void {
    try app.tree.refresh(app);
    app.needs_render = true;
}

fn collapseAll(app: *App) CommandError!void {
    var it = app.tree.expanded.keyIterator();
    while (it.next()) |k| app.gpa.free(k.*);
    app.tree.expanded.clearRetainingCapacity();
    try app.tree.refresh(app);
}

fn toggleCollapseAll(app: *App) CommandError!void {
    if (app.tree.expanded.count() > 0) return collapseAll(app);
    return expandAll(app);
}

/// Expand every directory (the noisy ones stay closed).
fn expandAll(app: *App) CommandError!void {
    var again = true;
    var guard: usize = 0;
    while (again and guard < 64) : (guard += 1) {
        again = false;
        try app.tree.refresh(app);
        for (app.tree.rows.items) |row| {
            if (!row.is_dir or app.tree.isExpanded(row.rel)) continue;
            if (isNoisy(row.name())) continue;
            try app.tree.setExpanded(row.rel, true);
            again = true;
        }
    }
    try app.tree.refresh(app);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "tree: lists dirs first, expands on Enter, opens a file, hides dot entries until H" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.zig", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "README.md", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".hidden", .data = "x" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.tree.refresh(&app);
    // A top-level directory opens on its first refresh.
    try t.expectEqual(@as(usize, 3), app.tree.rows.items.len);
    try t.expectEqualStrings("src", app.tree.rows.items[0].rel);
    try t.expect(app.tree.rows.items[0].is_dir);
    try t.expectEqualStrings("README.md", app.tree.rows.items[2].rel);
    app.focus = .tree;
    // Enter closes it; Enter again re-opens it (a second refresh does not).
    try t.expect(try app.tree.handleKey(&app, Key.named(.enter)));
    try t.expectEqual(@as(usize, 2), app.tree.rows.items.len);
    try app.tree.refresh(&app);
    try t.expectEqual(@as(usize, 2), app.tree.rows.items.len);
    try t.expect(try app.tree.handleKey(&app, Key.named(.enter)));
    try t.expectEqual(@as(usize, 3), app.tree.rows.items.len);
    try t.expectEqualStrings("src/main.zig", app.tree.rows.items[1].rel);
    try t.expectEqual(@as(u8, 1), app.tree.rows.items[1].depth);
    _ = try app.tree.handleKey(&app, Key.char('j'));
    _ = try app.tree.handleKey(&app, Key.named(.enter));
    try t.expectEqualStrings("main.zig", app.panes.get(app.active.?).?.title());
    _ = try app.tree.handleKey(&app, Key.char('H'));
    try t.expectEqual(@as(usize, 4), app.tree.rows.items.len);
    try t.expect(!try app.tree.handleKey(&app, Key.ctrl('p')));
    try command.run(&app, .{ .static = .@"tree.collapse_all" });
    try t.expectEqual(@as(usize, 3), app.tree.rows.items.len);
}

test "tree file verbs: new file, new folder, rename into a folder, move by drag-confirm, delete" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    try tmp.dir.createDirPath(t.io, "sub");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sub/cc.txt", .data = "cc" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "aa.txt", .data = "aa" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n] });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    app.tree.cursor = 1; // aa.txt
    try acceptNewFile(&app, "", "bb.txt");
    try t.expectEqualStrings("bb.txt", app.panes.get(app.active.?).?.title());
    try t.expect(app.tree.rowOf("bb.txt") != null);
    try acceptNewFolder(&app, "", "lib");
    try t.expect(app.tree.rows.items[app.tree.rowOf("lib").?].is_dir);
    // Rename aa.txt → a folder name: it moves in, keeping its name.
    try acceptRename(&app, "aa.txt", "sub");
    try t.expect(app.tree.rowOf("aa.txt") == null);
    try app.tree.setExpanded("sub", true);
    try app.tree.refresh(&app);
    try t.expect(app.tree.rowOf("sub/aa.txt") != null);
    // A drag-confirm moves bb.txt into lib/; the open buffer follows.
    const bb = app.tree.rowOf("bb.txt").?;
    const lib = app.tree.rowOf("lib").?;
    try confirmMove(&app, bb, lib);
    try t.expect(app.overlay == .confirm);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.state.title, "Move to") != null);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    const expect_path = try std.fs.path.join(t.allocator, &.{ buf[0..n], "lib", "bb.txt" });
    defer t.allocator.free(expect_path);
    try t.expectEqualStrings(expect_path, app.activeEditor().?.buf.path.?);
    // Delete closes the buffer and drops the row.
    try acceptDelete(&app, "lib/bb.txt");
    try t.expect(app.active == null);
    try t.expect(app.tree.rowOf("lib/bb.txt") == null);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"tree.open_in_split" }));
}

test "tree: artifact directories stay out of the rows without a .gitignore; H shows them" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "__pycache__");
    try tmp.dir.createDirPath(t.io, "node_modules/x");
    try tmp.dir.createDirPath(t.io, "vendor");
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build", .data = "a file named build stays" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.tree.refresh(&app);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(t.allocator);
    for (app.tree.rows.items) |r| try names.append(t.allocator, r.name());
    try t.expectEqual(@as(usize, 2), names.items.len);
    try t.expectEqualStrings("src", names.items[0]);
    try t.expectEqualStrings("build", names.items[1]);
    app.tree.show_hidden = true;
    try app.tree.refresh(&app);
    try t.expectEqual(@as(usize, 5), app.tree.rows.items.len);
}
