//! The file tree: the left panel every session starts with, listing the
//! workspace one directory deep with expandable folders. Its rows are a
//! flat list rebuilt from the expanded set, so drawing and keyboard
//! navigation are index arithmetic; the file system is only touched on
//! `refresh`.
//!
//! State (rows, cursor, expanded set) lives here; `draw` turns the rows
//! into the painter's items (`ui/tree_view.zig`) — the section headers,
//! the entries with their git badges, the separators — and the painter
//! registers the hits; keys reach it through `handleKey` when
//! `app.focus == .tree`. Hidden files show by default and `.git` never
//! does, as in Rust; each directory's `.gitignore` is honoured. The file verbs
//! (new / rename / delete / move) act on the cursor row through a
//! prompt or a confirm, so the right-click menu and the keys share them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const KeyCode = @import("../core/key.zig").KeyCode;
const command = @import("../core/command.zig");
const side = @import("side.zig");
const CommandError = command.CommandError;
const Rect = @import("../ui/rect.zig");
const context = @import("../ui/context.zig");
const Ui = context;
const files_pane = @import("files_pane.zig");
const file_clipboard = @import("file_clipboard.zig");
const trash = @import("trash.zig");
const lsp = @import("lsp.zig");
const watch = @import("watch.zig");
const gitignore = @import("gitignore.zig");
const tree_view = @import("../ui/tree_view.zig");
const sidebar_auto = @import("sidebar_auto.zig");
const Mouse = @import("../core/key.zig").Mouse;

pub const table = .{
    .@"view.add_workspace" = &addWorkspace,
    .@"view.switch_workspace" = &switchWorkspace,
    .@"view.remove_workspace" = &removeWorkspace,
    .@"view.open_default_workspace" = &openDefaultWorkspace,
    .@"view.manage_workspaces" = &manageWorkspaces,
    .@"view.reveal_in_tree" = &revealInTree,
    .@"view.toggle_tree_section" = &toggleTreeSection,
    .@"view.toggle_tree" = &toggle,
    .@"view.focus_tree" = &focus,
    .@"view.toggle_hidden" = &toggleHidden,
    .@"view.toggle_hidden_all" = &toggleHidden,
    .@"tree.refresh" = &refreshCmd,
    .@"tree.collapse_all" = &collapseAll,
    .@"tree.expand_all" = &expandAll,
    .@"tree.toggle_ignored" = &toggleIgnored,
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
/// Folders a package manager or a build fills and nobody writes source
/// in: hidden even without a `.gitignore` — the same set the file
/// picker skips, so the two surfaces agree. Unlike a dot entry, `H`
/// does not reveal them (Rust); `tree.toggle_ignored` (`I`) does.
pub const artifact_dirs = [_][]const u8{ "node_modules", "__pycache__", ".next", ".venv", "venv", ".zig-cache", "zig-cache" };
/// Build-output names that are ALSO where committed source lives — a Go
/// `vendor/`, a tracked `build/deploy.yaml`, a docs site's `dist/`.
/// Hidden by name outside a git repo; inside one the `.gitignore`s
/// alone decide, so tracked files there are listed and found.
pub const build_dirs = [_][]const u8{ "dist", "build", "target", "vendor", "zig-out" };

pub fn isArtifactDir(name: []const u8) bool {
    for (artifact_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
    return isBuildDir(name);
}

pub fn isBuildDir(name: []const u8) bool {
    for (build_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
    return false;
}

pub const Row = struct {
    /// Workspace-relative for the primary root; absolute under an
    /// extra root (`App.absPath` passes an absolute path through, so
    /// every file verb works unchanged). Owned.
    rel: []u8,
    depth: u8,
    is_dir: bool,
    /// 0 = the primary workspace, i + 1 = `Tree.roots[i]`.
    root: u8 = 0,
    /// A root's section header (`▾ name`); `rel` is the root's path
    /// (`""` for the primary).
    header: bool = false,
    /// Listed only because `show_ignored` is on: a `.gitignore` names it
    /// (or, outside a git repo, it is an artifact directory). Painted dim.
    ignored: bool = false,
    /// A symbolic link. A link to a directory is a directory row that
    /// expands like one; `expand_all` never enters it (a link can loop).
    link: bool = false,

    pub fn name(r: Row) []const u8 {
        return std.fs.path.basename(r.rel);
    }
};

/// An extra workspace root (`cfg.workspaces`, `view.add_workspace`).
pub const Root = struct {
    /// Owned.
    name: []u8,
    /// Absolute, canonical. Owned.
    path: []u8,
    expanded: bool = false,
};

/// Directories `Tree` has listed since the process started — what a test
/// reads to show `expand_all` lists each folder once.
pub var dirs_listed: usize = 0;

/// `expand_all` opens folders this deep and no deeper (the old walk's
/// 64-pass guard).
const max_expand_depth = 64;

pub const Tree = struct {
    gpa: Allocator,
    /// `expandAllDirs` is listing: every folder met is opened on the way.
    expanding_all: bool = false,
    visible: bool = true,
    /// A `Ctrl-W` arrived with the tree focused; the next key names the
    /// window to move to.
    ctrl_w_pending: bool = false,
    width: u16 = default_width,
    /// Dot entries show (Rust's default); `H` hides them. `.git` and the
    /// artifact directories stay out either way.
    show_hidden: bool = true,
    /// Git-ignored entries (and, outside a repo, the artifact
    /// directories) listed, dim — nvim-tree's `I`. Off by default; the
    /// file picker follows the same switch.
    show_ignored: bool = false,
    /// Whether the workspace sits in a git work tree, asked once.
    in_repo: ?bool = null,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    /// Expanded directories, workspace-relative, owned keys.
    expanded: std.StringHashMapUnmanaged(void) = .empty,
    /// Top-level directories a refresh has already met (owned keys).
    seen_top: std.StringHashMapUnmanaged(void) = .empty,
    /// The expansion set came from a saved session: the next listing
    /// records the top-level directories as seen without opening them
    /// (Rust's `set_expanded_dirs` replaces the set and opens nothing).
    restored: bool = false,
    /// Every directory the rows were read from, by absolute path
    /// (owned keys), stamped as it was read. `watch.check` refreshes
    /// the tree when one of them moves on disk.
    dir_stamps: std.StringHashMapUnmanaged(watch.DiskStamp) = .empty,
    /// Extra roots, in section order. With none, the tree is the
    /// primary workspace alone and paints no headers.
    roots: std.ArrayListUnmanaged(Root) = .empty,
    /// `cfg.workspaces` has been read into `roots`.
    roots_synced: bool = false,
    /// The primary section's fold, once there are headers.
    primary_expanded: bool = true,
    cursor: usize = 0,
    scroll: usize = 0,
    loaded: bool = false,
    /// vim's two-key `yy` / `dd` (ranger's vocabulary): the first key,
    /// until the next key. Two keys so a stray press cannot move a file.
    pending: ?u8 = null,

    pub fn init(gpa: Allocator) Tree {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tree) void {
        self.clearRows();
        self.rows.deinit(self.gpa);
        self.dir_stamps.deinit(self.gpa);
        var it = self.expanded.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.expanded.deinit(self.gpa);
        var st = self.seen_top.keyIterator();
        while (st.next()) |k| self.gpa.free(k.*);
        self.seen_top.deinit(self.gpa);
        for (self.roots.items) |r| {
            self.gpa.free(r.name);
            self.gpa.free(r.path);
        }
        self.roots.deinit(self.gpa);
    }

    /// `cfg.workspaces` → `roots`, once. A path is expanded (`~`) and
    /// canonicalised; one that is the workspace itself, missing, or
    /// already listed is skipped.
    pub fn syncRoots(self: *Tree, app: *App) Allocator.Error!void {
        if (self.roots_synced) return;
        self.roots_synced = true;
        for (app.cfg.workspaces) |w| {
            if (w.path.len == 0) continue;
            _ = self.addRoot(app, w.path, if (w.name.len > 0) w.name else null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
        }
    }

    pub const AddError = error{ NotADirectory, AlreadyOpen } || Allocator.Error;

    /// `path_in` as a root path: `~` and workspace-relative forms
    /// expanded, then the directory's canonical path (frame arena).
    pub fn canonicalRoot(app: *App, path_in: []const u8) error{ NotADirectory, OutOfMemory }![]const u8 {
        const arena = app.frame.allocator();
        var path = path_in;
        if (path.len > 0 and path[0] == '~') {
            const home = app.homeDir() orelse return error.NotADirectory;
            path = try std.fs.path.join(arena, &.{ home, std.mem.trimStart(u8, path[1..], "/") });
        } else if (!std.fs.path.isAbsolute(path)) {
            path = try std.fs.path.join(arena, &.{ app.workspace, path });
        }
        var dir = std.Io.Dir.cwd().openDir(app.io, path, .{}) catch return error.NotADirectory;
        defer dir.close(app.io);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = dir.realPath(app.io, &buf) catch return error.NotADirectory;
        return try arena.dupe(u8, buf[0..n]);
    }

    /// The section a canonical path is the root of: 0 the workspace,
    /// i + 1 the i-th extra root, null when it is neither.
    pub fn indexOfRoot(self: *const Tree, app: *const App, canon: []const u8) ?usize {
        if (std.mem.eql(u8, canon, app.workspace)) return 0;
        for (self.roots.items, 0..) |r, i| if (std.mem.eql(u8, r.path, canon)) return i + 1;
        return null;
    }

    /// Add `path_in` as an extra root (collapsed). Returns its index.
    pub fn addRoot(self: *Tree, app: *App, path_in: []const u8, name_in: ?[]const u8) AddError!usize {
        const gpa = self.gpa;
        const canon = try canonicalRoot(app, path_in);
        if (self.indexOfRoot(app, canon) != null) return error.AlreadyOpen;
        const owned_path = try gpa.dupe(u8, canon);
        errdefer gpa.free(owned_path);
        const base = std.fs.path.basename(canon);
        const owned_name = try gpa.dupe(u8, name_in orelse (if (base.len > 0) base else canon));
        errdefer gpa.free(owned_name);
        try self.roots.append(gpa, .{ .name = owned_name, .path = owned_path });
        self.loaded = false;
        return self.roots.items.len - 1;
    }

    /// The row index of root `idx`'s header (0 = primary), if painted.
    pub fn headerRow(self: *const Tree, idx: usize) ?usize {
        for (self.rows.items, 0..) |r, i| if (r.header and r.root == idx) return i;
        return null;
    }

    /// `view.switch_workspace`'s pick: `idx` opens, every other root
    /// folds, the cursor lands on its header.
    pub fn switchTo(self: *Tree, app: *App, idx: usize) Allocator.Error!void {
        self.primary_expanded = idx == 0;
        for (self.roots.items, 0..) |*r, i| r.expanded = i + 1 == idx;
        try self.refresh(app);
        if (self.headerRow(idx)) |row| self.cursor = row;
        if (app.activeBuffer()) |b| b.input.onBlur();
        self.visible = true;
        app.focus = .tree;
        app.needs_render = true;
    }

    /// `view.remove_workspace`'s pick: extra root `idx` (0-based into
    /// `roots`) leaves the tree with the folds under it; the rows are
    /// read again and the cursor stays in range.
    pub fn removeRoot(self: *Tree, app: *App, idx: usize) Allocator.Error!void {
        if (idx >= self.roots.items.len) return;
        const gone = self.roots.orderedRemove(idx);
        defer {
            self.gpa.free(gone.name);
            self.gpa.free(gone.path);
        }
        // Rows under an extra root are absolute, so its folds are the
        // expanded keys that start with its path.
        var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.expanded.keyIterator();
        while (it.next()) |k| if (underRoot(gone.path, k.*) != null) try doomed.append(self.gpa, k.*);
        for (doomed.items) |k| try self.setExpanded(k, false);
        try self.refresh(app);
        if (self.cursor >= self.rows.items.len) self.cursor = self.rows.items.len -| 1;
        app.needs_render = true;
    }

    /// `view.reveal_in_tree`: the tree comes up focused with `abs`'s
    /// section and every directory above the file open, the cursor on
    /// its row (`draw` scrolls it into view). A file under no root, or
    /// one the listing leaves out (ignored, hidden), is a failure.
    pub fn revealPath(self: *Tree, app: *App, abs: []const u8) CommandError!void {
        const arena = app.frame.allocator();
        try self.syncRoots(app);
        var root: u8 = 0;
        var rel: []const u8 = undefined;
        var base: []const u8 = app.workspace;
        if (underRoot(app.workspace, abs)) |r| {
            rel = try rowRel(arena, r);
        } else {
            var found = false;
            for (self.roots.items, 0..) |r, i| if (underRoot(r.path, abs) != null) {
                root = @intCast(i + 1);
                // An extra root's rows are native absolute paths.
                rel = try nativeRel(arena, abs);
                base = r.path;
                found = true;
                break;
            };
            if (!found) return app.diag.fail(arena, "{s}: not under a workspace root", .{std.fs.path.basename(abs)});
        }
        side.place(app, .explorer, true);
        try self.setRootExpanded(root, true);
        // Every directory between the root and the file — the order
        // does not matter to the set, only that each one is in it
        // before the rows are read.
        var dir = std.fs.path.dirname(rel);
        while (dir) |d| : (dir = std.fs.path.dirname(d)) {
            if (d.len == 0 or (root != 0 and d.len <= base.len)) break;
            try self.setExpanded(d, true);
        }
        try self.refresh(app);
        const row = self.rowOf(rel) orelse return app.diag.fail(arena, "{s} is not in the file tree", .{app.relPath(abs)});
        self.cursor = row;
        app.needs_render = true;
    }

    fn clearRows(self: *Tree) void {
        for (self.rows.items) |r| self.gpa.free(r.rel);
        self.rows.clearRetainingCapacity();
        self.clearDirStamps();
    }

    fn clearDirStamps(self: *Tree) void {
        var it = self.dir_stamps.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.dir_stamps.clearRetainingCapacity();
    }

    fn noteDirStamp(self: *Tree, app: *App, abs: []const u8) Allocator.Error!void {
        const st = watch.stamp(app.io, abs) orelse return;
        if (self.dir_stamps.getPtr(abs)) |slot| {
            slot.* = st;
            return;
        }
        const key = try self.gpa.dupe(u8, abs);
        errdefer self.gpa.free(key);
        try self.dir_stamps.put(self.gpa, key, st);
    }

    /// Whether any listed directory's mtime moved since it was read —
    /// an entry another tool added, removed or renamed.
    pub fn dirsChanged(self: *const Tree, io: std.Io) bool {
        var it = self.dir_stamps.iterator();
        while (it.next()) |kv| {
            const now_st = watch.stamp(io, kv.key_ptr.*) orelse return true;
            if (now_st.mtime_ns != kv.value_ptr.mtime_ns) return true;
        }
        return false;
    }

    /// Rebuild the rows from disk: the root's entries, then each
    /// expanded directory's, depth first. Directories first, then
    /// files, each sorted by name. A top-level directory seen for the
    /// first time opens by itself (the noisy ones stay shut), so a
    /// folder that appears after startup is not a closed chevron the
    /// user has to find.
    pub fn refresh(self: *Tree, app: *App) Allocator.Error!void {
        try self.syncRoots(app);
        self.clearRows();
        const first = !self.loaded;
        self.loaded = true;
        if (self.roots.items.len > 0) {
            try self.refreshRoots(app);
            // Rust's cursor starts on the first entry — its section
            // header is not a row — so three arrows from a fresh start
            // land on the same file here.
            if (first and self.cursor == 0 and self.rows.items.len > 1 and self.rows.items[0].header and self.primary_expanded) self.cursor = 1;
            return;
        }
        // The primary section folded: no rows, the header alone.
        if (!self.primary_expanded) {
            self.cursor = 0;
            return;
        }
        try self.listInto(app, "", 0, 0);
        if (try self.openNewTopDirs(0)) {
            self.clearRows();
            try self.listInto(app, "", 0, 0);
        }
        if (self.cursor >= self.rows.items.len) self.cursor = self.rows.items.len -| 1;
    }

    /// Expands every top-level directory of the primary (at `depth`) met
    /// for the first time, the noisy ones excepted. True when one opened
    /// and the rows must be read again.
    fn openNewTopDirs(self: *Tree, depth: u8) Allocator.Error!bool {
        var opened = false;
        const open = !self.restored;
        self.restored = false;
        for (self.rows.items) |row| {
            if (row.header or row.root != 0 or !row.is_dir or row.depth != depth or self.seen_top.contains(row.rel)) continue;
            const key = try self.gpa.dupe(u8, row.rel);
            errdefer self.gpa.free(key);
            try self.seen_top.put(self.gpa, key, {});
            if (!open or isNoisy(row.name())) continue;
            try self.setExpanded(row.rel, true);
            opened = true;
        }
        return opened;
    }

    /// Several roots: one header per root, its entries under it (one
    /// deeper) while it is open. Rows under an extra root carry
    /// absolute paths.
    fn refreshRoots(self: *Tree, app: *App) Allocator.Error!void {
        const gpa = self.gpa;
        try self.rows.append(gpa, .{ .rel = try gpa.dupe(u8, ""), .depth = 0, .is_dir = true, .root = 0, .header = true });
        if (self.primary_expanded) {
            try self.listInto(app, "", 1, 0);
            if (try self.openNewTopDirs(1)) {
                self.clearRows();
                try self.rows.append(gpa, .{ .rel = try gpa.dupe(u8, ""), .depth = 0, .is_dir = true, .root = 0, .header = true });
                try self.listInto(app, "", 1, 0);
            }
        }
        for (self.roots.items, 0..) |r, i| {
            try self.rows.append(gpa, .{ .rel = try gpa.dupe(u8, r.path), .depth = 0, .is_dir = true, .root = @intCast(i + 1), .header = true });
            if (r.expanded) try self.listInto(app, r.path, 1, @intCast(i + 1));
        }
        if (self.cursor >= self.rows.items.len) self.cursor = self.rows.items.len -| 1;
    }

    /// List `rel_dir` (workspace-relative, or absolute under an extra
    /// root) at `depth`; a listed directory that is expanded recurses.
    fn listInto(self: *Tree, app: *App, rel_dir: []const u8, depth: u8, root: u8) Allocator.Error!void {
        var ignores = gitignore.Stack.init(self.gpa);
        defer ignores.deinit();
        try self.listWith(app, rel_dir, depth, root, &ignores, false);
    }

    /// The workspace is inside a git work tree (a `.git` at it or above).
    /// Inside one the `.gitignore`s say whether a `build/` or `vendor/`
    /// is listed; outside one its name is the only guide (`build_dirs`).
    pub fn inRepo(self: *Tree, app: *App) bool {
        if (self.in_repo) |v| return v;
        var dir: []const u8 = app.workspace;
        const found = while (true) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const probe = std.fmt.bufPrint(&buf, "{s}/.git", .{dir}) catch break false;
            if (std.Io.Dir.cwd().statFile(app.io, probe, .{})) |_| break true else |_| {}
            dir = std.fs.path.dirname(dir) orelse break false;
        };
        self.in_repo = found;
        return found;
    }

    /// Whether a listing leaves directory `name` out by its name alone
    /// (`artifact_dirs` always, `build_dirs` outside a repo).
    pub fn artifactHidden(self: *Tree, app: *App, name: []const u8) bool {
        for (artifact_dirs) |d| if (std.mem.eql(u8, name, d)) return true;
        return isBuildDir(name) and !self.inRepo(app);
    }

    /// The path of `rel_dir` relative to its root — what a `.gitignore`
    /// pattern is matched against. Rows under an extra root are absolute.
    fn rootRel(self: *const Tree, app: *const App, rel_dir: []const u8, root: u8) []const u8 {
        if (root == 0) return rel_dir;
        const base = self.roots.items[root - 1].path;
        _ = app;
        if (std.mem.startsWith(u8, rel_dir, base) and rel_dir.len > base.len and std.fs.path.isSep(rel_dir[base.len])) return rel_dir[base.len + 1 ..];
        return "";
    }

    fn listWith(self: *Tree, app: *App, rel_dir: []const u8, depth: u8, root: u8, ignores: *gitignore.Stack, under_ignored: bool) Allocator.Error!void {
        const gpa = self.gpa;
        dirs_listed += 1;
        const arena = app.frame.allocator();
        const abs = if (rel_dir.len == 0) app.workspace else if (std.fs.path.isAbsolute(rel_dir)) rel_dir else try std.fs.path.join(arena, &.{ app.workspace, rel_dir });
        var dir = std.Io.Dir.cwd().openDir(app.io, abs, .{ .iterate = true }) catch return;
        defer dir.close(app.io);
        try self.noteDirStamp(app, abs);
        // This directory's `.gitignore` joins the stack while its
        // entries are read; the rules name paths relative to the root.
        // Root-relative and `/`-joined: what a `.gitignore` rule reads
        // (an extra root's rows are native absolute paths).
        const here = try rowRel(arena, self.rootRel(app, rel_dir, root));
        var pushed = false;
        if (dir.readFileAlloc(app.io, ".gitignore", gpa, .limited(256 * 1024))) |text| {
            defer gpa.free(text);
            try ignores.push(try gitignore.Rules.parse(gpa, here, text));
            pushed = true;
        } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
        defer if (pushed) {
            var layer = ignores.layers.pop().?;
            layer.deinit(gpa);
        };
        var names: std.ArrayListUnmanaged(Row) = .empty;
        defer names.deinit(gpa);
        var it = dir.iterate();
        while (it.next(app.io) catch null) |entry| {
            if (entry.kind != .directory and entry.kind != .file and entry.kind != .sym_link) continue;
            const link = entry.kind == .sym_link;
            // A link is a folder row when its target is one (the stat
            // follows the link); a dangling link stays a file row.
            const is_dir = entry.kind == .directory or (link and linkIsDir(app, dir, entry.name));
            if (is_dir and std.mem.eql(u8, entry.name, ".git")) continue;
            if (!self.show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            // A row's `rel` joins with `/` on every platform: the
            // `.gitignore` rules, the git status map and every prefix
            // test in this file read it that way, and Windows opens a
            // `/`-joined path as readily as a `\`-joined one.
            const here_rel = if (here.len == 0) entry.name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ here, entry.name });
            const ignored = under_ignored or (is_dir and self.artifactHidden(app, entry.name)) or ignores.ignored(here_rel, is_dir);
            if (ignored and !self.show_ignored) continue;
            // Under an extra root the row is its absolute path, joined
            // natively like any other absolute path; under the workspace
            // it is `/`-joined.
            const rel = if (rel_dir.len == 0)
                try gpa.dupe(u8, entry.name)
            else if (std.fs.path.isAbsolute(rel_dir))
                try std.fs.path.join(gpa, &.{ rel_dir, entry.name })
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel_dir, entry.name });
            errdefer gpa.free(rel);
            try names.append(gpa, .{ .rel = rel, .depth = depth, .is_dir = is_dir, .root = root, .ignored = ignored, .link = link });
        }
        // Directories first, then names folded to lower case (Rust).
        std.mem.sort(Row, names.items, {}, struct {
            fn lt(_: void, a: Row, b: Row) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                return std.ascii.lessThanIgnoreCase(a.name(), b.name());
            }
        }.lt);
        for (names.items) |row| {
            try self.rows.append(gpa, row);
            if (self.expanding_all and autoExpands(row)) try self.setExpanded(row.rel, true);
            if (row.is_dir and self.expanded.contains(row.rel)) try self.listWith(app, row.rel, depth + 1, root, ignores, row.ignored);
        }
    }

    pub fn isExpanded(self: *const Tree, rel: []const u8) bool {
        return self.expanded.contains(rel);
    }

    pub fn setExpanded(self: *Tree, rel: []const u8, on: bool) Allocator.Error!void {
        if (on) {
            if (self.expanded.contains(rel)) return;
            const key = try self.gpa.dupe(u8, rel);
            errdefer self.gpa.free(key);
            try self.expanded.put(self.gpa, key, {});
        } else if (self.expanded.fetchRemove(rel)) |kv| self.gpa.free(kv.key);
    }

    /// Enter / a double-click: a file opens as a tab of its own, a
    /// directory toggles. Rust's `tree_activate` pins the same way —
    /// the arrows are what browses.
    pub fn activate(self: *Tree, app: *App, idx: usize) Allocator.Error!void {
        return self.activateHow(app, idx, false);
    }

    /// A single left click on a file row: the file opens as a glance
    /// (VS Code's preview tab). A directory still toggles.
    pub fn activateGlance(self: *Tree, app: *App, idx: usize) Allocator.Error!void {
        return self.activateHow(app, idx, true);
    }

    fn activateHow(self: *Tree, app: *App, idx: usize, glance: bool) Allocator.Error!void {
        if (idx >= self.rows.items.len) return;
        self.cursor = idx;
        const row = self.rows.items[idx];
        if (row.header) {
            try self.setRootExpanded(row.root, !self.rootExpanded(row.root));
            try self.refresh(app);
        } else if (row.is_dir) {
            try self.setExpanded(row.rel, !self.isExpanded(row.rel));
            try self.refresh(app);
        } else {
            const rel = try app.frame.allocator().dupe(u8, row.rel);
            const abs = try app.absPath(rel);
            const opened = if (glance) app.openPreview(abs) else app.openPath(abs);
            _ = opened catch |err| app.toast("open {s}: {s}", .{ rel, @errorName(err) });
        }
        app.needs_render = true;
    }

    /// The keys the tree answers when it has focus. Returns false for a
    /// key it does not want (the chord chain gets it).
    pub fn handleKey(self: *Tree, app: *App, k: Key) Allocator.Error!bool {
        // A pending `y` / `d` must not survive an unrelated key.
        const pending = self.pending;
        self.pending = null;
        // The tree is a window to vim's `Ctrl-W` family: `w` / `l` / `h`
        // / `j` / `k` (and `Ctrl-W Ctrl-W`) move on from it the way
        // `Ctrl-L` does. The chord owns its second key whatever it is.
        if (self.ctrl_w_pending) {
            self.ctrl_w_pending = false;
            // // changed (bottom-dock): `J` / `K` dock the explorer and
            // bring it back up, as they do from any other section.
            if (side.ctrlWSectionSide(app, k, .explorer)) |dest| {
                side.move(app, .explorer, dest) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
                return true;
            }
            if (side.ctrlWCommand(k)) |cid| try runCmd(app, cid);
            return true;
        }
        if (side.isCtrlW(app, k)) {
            self.ctrl_w_pending = true;
            return true;
        }
        // The file clipboard's chords: Ctrl+X/C/V/D in both profiles —
        // the tree never edits text, so nothing else can want them here
        // (Rust parity). Plain ctrl only: Ctrl+Shift+D is Activity: Debug
        // and the shifted forms of the others are the chord chain's too —
        // a modifier-mismatched chord must never touch the file system.
        // vim also gets ranger's `yy` / `dd` / `P` below.
        if (k.mods.ctrl or k.mods.alt or k.mods.super) {
            if (k.mods.ctrl and !k.mods.shift and !k.mods.alt and !k.mods.super and k.code == .char) {
                const id: ?command.CommandId = switch (k.code.char) {
                    'x' => .@"file.cut",
                    'c' => .@"file.copy",
                    'v' => .@"file.paste",
                    'd' => .@"file.duplicate",
                    else => null,
                };
                if (id) |cid| {
                    try runCmd(app, cid);
                    return true;
                }
            }
            return false;
        }
        const n = self.rows.items.len;
        // A shifted letter arrives as `W` from one parser and as
        // `shift+w` from another: one spelling here.
        const code: KeyCode = switch (k.code) {
            .char => |c| if (k.mods.shift and c >= 'a' and c <= 'z') .{ .char = c - ('a' - 'A') } else .{ .char = c },
            else => |other| other,
        };
        switch (code) {
            .down => {
                self.cursor = @min(self.cursor + 1, n -| 1);
                try self.previewCursor(app);
            },
            .up => {
                self.cursor -|= 1;
                try self.previewCursor(app);
            },
            .home => {
                self.cursor = 0;
                try self.previewCursor(app);
            },
            .end => {
                self.cursor = n -| 1;
                try self.previewCursor(app);
            },
            .page_down => {
                self.cursor = @min(self.cursor + 10, n -| 1);
                try self.previewCursor(app);
            },
            .page_up => {
                self.cursor -|= 10;
                try self.previewCursor(app);
            },
            .enter => try self.activate(app, self.cursor),
            .right => {
                try self.expandOrOpen(app);
                try self.previewCursor(app);
            },
            .left => {
                try self.collapseOrParent(app);
                try self.previewCursor(app);
            },
            .esc => {
                if (app.active) |a| app.focus = .{ .pane = a };
            },
            // F2 renames the row (VS Code's Explorer chord). The global
            // `lsp.rename` on F2 is an editor's; taking it here is how a
            // tree-focused key wins over the chord chain.
            .f => |fn_key| {
                if (fn_key != 2) return false;
                try runCmd(app, .@"file.rename");
            },
            .char => |c| switch (c) {
                'j' => {
                    self.cursor = @min(self.cursor + 1, n -| 1);
                    try self.previewCursor(app);
                },
                'k' => {
                    self.cursor -|= 1;
                    try self.previewCursor(app);
                },
                'g' => {
                    self.cursor = 0;
                    try self.previewCursor(app);
                },
                'G' => {
                    self.cursor = n -| 1;
                    try self.previewCursor(app);
                },
                'l' => try self.expandOrOpen(app),
                // Space is the vim profile's leader in the tree as in
                // every window (NvChad: nvim-tree maps no `<Space>`, so
                // `Space f f` from the tree is Telescope's): the chord
                // chain arms it. The standard profile opens the row.
                ' ' => {
                    if (app.input_style == .vim) return false;
                    try self.expandOrOpen(app);
                },
                'h' => try self.collapseOrParent(app),
                'o' => try self.activate(app, self.cursor),
                // nvim-tree's verbs under vim (its default `on_attach`:
                // `a` create, `r` rename, `d` delete, `x` cut, `R`
                // refresh, `E` expand all, `W` collapse all); `r` stays
                // refresh for the standard profile.
                'r' => if (app.input_style == .vim) try runCmd(app, .@"file.rename") else try self.refresh(app),
                'a' => {
                    if (app.input_style != .vim) return false;
                    try runCmd(app, .@"file.new");
                },
                'R' => {
                    if (app.input_style != .vim) return false;
                    try self.refresh(app);
                },
                'x' => {
                    if (app.input_style != .vim) return false;
                    try runCmd(app, .@"file.cut");
                },
                'E' => {
                    if (app.input_style != .vim) return false;
                    try runCmd(app, .@"tree.expand_all");
                },
                'W' => {
                    if (app.input_style != .vim) return false;
                    try runCmd(app, .@"tree.collapse_all");
                },
                'H' => {
                    self.show_hidden = !self.show_hidden;
                    try self.refresh(app);
                },
                // nvim-tree's `I`: git-ignored entries in and out.
                'I' => try runCmd(app, .@"tree.toggle_ignored"),
                'D' => try runCmd(app, .@"file.duplicate"),
                'd' => {
                    if (app.input_style != .vim) return false;
                    try runCmd(app, .@"file.delete");
                },
                'y' => {
                    // ranger's `yy`: two keys so a stray press copies nothing.
                    if (app.input_style != .vim) return false;
                    if (pending != null and pending.? == c) {
                        try runCmd(app, .@"file.copy");
                    } else {
                        self.pending = @intCast(c);
                        app.toast("y — press again to copy", .{});
                    }
                },
                'P' => {
                    if (app.input_style != .vim) return false;
                    try runCmd(app, .@"file.paste");
                },
                // The tree is a window like any other to a vim user: `:`
                // opens the command line (`:e file`, `:w`, `:q`), and the
                // letters typed next go to it, never to the tree's verbs.
                ':' => {
                    if (app.input_style != .vim) return false;
                    try runCmd(app, .@"app.command_line");
                },
                else => return false,
            },
            else => return false,
        }
        app.needs_render = true;
        return true;
    }

    /// VS Code's preview: under the standard profile (and
    /// `ui.tree_preview_on_arrow`) the file the cursor lands on opens
    /// as the preview pane, the focus staying in the tree so the next
    /// arrow keeps browsing. A directory or header row opens nothing.
    fn previewCursor(self: *Tree, app: *App) Allocator.Error!void {
        if (app.input_style != .standard or !app.cfg.ui.tree_preview_on_arrow) return;
        if (self.cursor >= self.rows.items.len) return;
        const row = self.rows.items[self.cursor];
        if (row.header or row.is_dir) return;
        const rel = try app.frame.allocator().dupe(u8, row.rel);
        const abs = try app.absPath(rel);
        // The cursor only passed over it: a file too heavy to glance at
        // is named, not loaded — Enter still opens it.
        if (try previewTooHeavy(app, abs)) |why| {
            app.toast("{s}: {s} — not previewed; Enter opens it", .{ rel, why });
            return;
        }
        _ = app.openPreview(abs) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                app.toast("open {s}: {s}", .{ rel, @errorName(err) });
                return;
            },
        };
        app.focus = .tree;
    }

    fn rootExpanded(self: *const Tree, root: u8) bool {
        return if (root == 0) self.primary_expanded else self.roots.items[root - 1].expanded;
    }

    fn setRootExpanded(self: *Tree, root: u8, on: bool) Allocator.Error!void {
        if (root == 0) self.primary_expanded = on else self.roots.items[root - 1].expanded = on;
    }

    /// The row's root: the workspace, or the extra root's path.
    fn rootPath(self: *const Tree, app: *const App, root: u8) []const u8 {
        return if (root == 0) app.workspace else self.roots.items[root - 1].path;
    }

    fn expandOrOpen(self: *Tree, app: *App) Allocator.Error!void {
        if (self.cursor >= self.rows.items.len) return;
        const row = self.rows.items[self.cursor];
        if (row.header) {
            if (!self.rootExpanded(row.root)) {
                try self.setRootExpanded(row.root, true);
                try self.refresh(app);
            }
            return;
        }
        if (row.is_dir and !self.isExpanded(row.rel)) {
            try self.setExpanded(row.rel, true);
            try self.refresh(app);
        } else if (!row.is_dir) try self.activate(app, self.cursor);
    }

    fn collapseOrParent(self: *Tree, app: *App) Allocator.Error!void {
        if (self.cursor >= self.rows.items.len) return;
        const row = self.rows.items[self.cursor];
        if (row.header) {
            if (self.rootExpanded(row.root)) {
                try self.setRootExpanded(row.root, false);
                try self.refresh(app);
            }
            return;
        }
        if (row.is_dir and self.isExpanded(row.rel)) {
            try self.setExpanded(row.rel, false);
            try self.refresh(app);
            return;
        }
        // Jump to the parent row — the root's header at the top level.
        const parent = std.fs.path.dirname(row.rel) orelse "";
        const at_top = parent.len == 0 or (row.root != 0 and std.mem.eql(u8, parent, self.rootPath(app, row.root)));
        if (at_top) {
            if (self.headerRow(row.root)) |h| self.cursor = h;
            return;
        }
        for (self.rows.items, 0..) |r, i| if (!r.header and std.mem.eql(u8, r.rel, parent)) {
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

    /// Turns the rows into the painter's items — one per screen row —
    /// keeps the cursor's item on screen, and paints. With no extra root
    /// the primary's header is chrome, not a row; with roots the header
    /// rows are in `rows` and entries sit one deeper.
    pub fn draw(self: *Tree, app: *App, ui: Ui, area: Rect) Allocator.Error!void {
        if (area.isEmpty()) return;
        if (!self.loaded) try self.refresh(app);
        const arena = ui.arena;
        const multi = self.roots.items.len > 0;
        const states = try gitStates(app, arena);
        var items: std.ArrayListUnmanaged(tree_view.Item) = .empty;
        var cursor_item: ?usize = null;
        const primary: tree_view.Section = .{
            .root = 0,
            .label = try wsLabel(app, arena),
            .expanded = self.primary_expanded,
            .italic = self.show_hidden,
            .fully_collapsed = self.isFullyCollapsed(),
        };
        if (!multi) try items.append(arena, .{ .section = primary });
        for (self.rows.items, 0..) |row, i| {
            if (row.header) {
                if (items.items.len > 0) try items.append(arena, .blank);
                if (i == self.cursor) cursor_item = items.items.len;
                const section: tree_view.Section = if (row.root == 0) primary else .{
                    .root = row.root,
                    .label = self.roots.items[row.root - 1].name,
                    .expanded = self.roots.items[row.root - 1].expanded,
                };
                try items.append(arena, .{ .section = section });
                continue;
            }
            if (i == self.cursor) cursor_item = items.items.len;
            const depth = row.depth - @as(u8, if (multi) 1 else 0);
            // The name and the badges (a path join, the git map, every
            // open buffer) are filled below for the rows on screen only:
            // an expanded 50k-row tree paid them per row on every repaint.
            try items.append(arena, .{ .entry = .{
                .idx = @intCast(i),
                .name = "",
                .depth = depth,
                .is_dir = row.is_dir,
                .expanded = row.is_dir and self.isExpanded(row.rel),
                .ignored = row.ignored,
            } });
        }
        try items.append(arena, .blank);
        try items.append(arena, .add_workspace);
        const h: usize = area.h;
        if (cursor_item) |ci| {
            if (ci < self.scroll) self.scroll = ci;
            if (ci >= self.scroll + h) self.scroll = ci + 1 - h;
        }
        self.scroll = @min(self.scroll, tree_view.contentLen(items.items) -| h);
        // A pinned header may shift the painted window by a row or two.
        const lo = self.scroll -| 2;
        const hi = @min(items.items.len, self.scroll + h + 2);
        for (items.items[lo..hi]) |*it| switch (it.*) {
            .entry => |*en| {
                const row = self.rows.items[en.idx];
                en.name = row.name();
                const abs = try app.absPath(row.rel);
                if (!row.is_dir) {
                    en.git = states.get(abs);
                    en.dirty = dirtyInEditor(app, abs);
                } else if (row.root == 0 and en.depth == 0) en.repo = repoMark(app, abs);
            },
            else => {},
        };
        _ = tree_view.draw(ui, area, .{
            .items = items.items,
            .cursor = cursor_item,
            .focused = app.focus == .tree,
            .scroll = self.scroll,
            .show_dots = app.cfg.ui.show_workspace_dots,
        });
    }

    /// No directory open: the header's toggle chip offers expand-all.
    pub fn isFullyCollapsed(self: *const Tree) bool {
        return self.expanded.count() == 0;
    }

    /// A press on a section header folds it (Rust `tree_toggle` /
    /// `extra_workspace_toggles`); Alt on the primary also folds or
    /// opens every directory inside it.
    pub fn toggleRoot(self: *Tree, app: *App, root: u8, alt: bool) Allocator.Error!void {
        if (root == 0) {
            if (alt) {
                if (self.primary_expanded) try self.collapseAllDirs() else try self.expandAllDirs(app);
            }
            self.primary_expanded = !self.primary_expanded;
        } else {
            if (root - 1 >= self.roots.items.len) return;
            self.roots.items[root - 1].expanded = !self.roots.items[root - 1].expanded;
        }
        try self.refresh(app);
        app.needs_render = true;
    }

    fn collapseAllDirs(self: *Tree) Allocator.Error!void {
        var it = self.expanded.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.expanded.clearRetainingCapacity();
    }

    /// Every folder open, in one listing: the walk expands each folder
    /// it meets and descends into it. It used to re-list the whole tree
    /// once per level — 44 listings of a tree growing to 55k rows, a
    /// five-second freeze on a deep workspace.
    pub fn expandAllDirs(self: *Tree, app: *App) Allocator.Error!void {
        self.expanding_all = true;
        defer self.expanding_all = false;
        try self.refresh(app);
    }

    /// `expand_all`'s rule for one listed folder: not noisy, not a link
    /// (followed in one walk, a link to an ancestor recurses until the
    /// depth cap on every branch), and not past the depth the old
    /// level-by-level walk stopped at. An ignored folder the tree shows
    /// (`show_ignored`) opens like any other, as it did.
    fn autoExpands(row: Row) bool {
        return row.is_dir and !row.header and !row.link and !isNoisy(row.name()) and row.depth < max_expand_depth;
    }

    /// The scrollbar in the tree's last column: a press or drag lands
    /// the cursor proportionally (the wheel over it is the tree's,
    /// `dispatch.treeWheel`).
    pub fn scrollbarMouse(self: *Tree, app: *App, bar: Rect, m: Mouse) void {
        const n = self.rows.items.len;
        if (n == 0 or bar.h == 0) return;
        switch (m.kind) {
            .press, .drag => {
                if (app.activeBuffer()) |b| b.input.onBlur();
                app.focus = .tree;
                const off: usize = m.y -| bar.y;
                self.cursor = @min(off * n / bar.h, n - 1);
            },
            else => {},
        }
        app.needs_render = true;
    }
};

/// What a header chip runs (Rust `workspace_action_chip_specs`).
pub fn chipCommand(c: tree_view.Chip) command.CommandId {
    return switch (c) {
        .new_folder => .@"file.new_folder",
        .new_file => .@"file.new",
        .pull => .@"git.pull",
        .collapse => .@"tree.toggle_collapse_all",
        .refresh => .@"tree.refresh",
        .add_workspace => .@"view.add_workspace",
    };
}

/// A press on a header chip. The new-file / new-folder chips are the
/// tree's own verbs: the tree takes focus first so the prompt opens on
/// its cursor row, not on a Files pane's.
pub fn chipClick(app: *App, c: tree_view.Chip) Allocator.Error!void {
    if (c == .new_file or c == .new_folder) {
        if (app.activeBuffer()) |b| b.input.onBlur();
        app.focus = .tree;
    }
    try runCmd(app, chipCommand(c));
    app.needs_render = true;
}

/// The primary header's label: the workspace path with `$HOME` as `~`
/// and a trailing slash (neo-tree's root row).
pub fn wsLabel(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    const full = app.workspace;
    const home = app.userHome();
    if (home) |h| if (h.len > 0 and std.mem.startsWith(u8, full, h)) return std.fmt.allocPrint(arena, "~{s}/", .{full[h.len..]});
    return std.fmt.allocPrint(arena, "{s}/", .{full});
}

/// Absolute path → git state, from the active repo's status (Rust's
/// `FileState` fold: conflicted, then a working-tree change, then a
/// staged one, then untracked).
fn gitStates(app: *App, arena: Allocator) Allocator.Error!std.StringHashMapUnmanaged(tree_view.GitState) {
    var map: std.StringHashMapUnmanaged(tree_view.GitState) = .empty;
    const git = @import("git.zig");
    // The badges need a status: the tree asks for the repos and the
    // first snapshot itself, as the rail does, so a workspace with no
    // git surface open still gets its `?` / `M` marks.
    if (!app.git.discovered) git.discover(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    const repo = app.git.activeRepo() orelse return map;
    if (app.git.status == null and !app.git.status_pending) git.requestStatus(app) catch {};
    const st = app.git.status orelse return map;
    if (app.git.status_repo != repo.id) return map;
    for (st.entries) |e| {
        const abs = try std.fs.path.join(arena, &.{ repo.path, e.path });
        const state: tree_view.GitState = switch (e.group) {
            .conflicted => .conflicted,
            .unstaged => .modified,
            .staged => switch (e.code) {
                'A' => .added,
                'R', 'C' => .renamed,
                else => .staged,
            },
            .untracked => .untracked,
        };
        const gop = try map.getOrPut(arena, abs);
        gop.value_ptr.* = if (gop.found_existing) foldState(gop.value_ptr.*, state) else state;
    }
    return map;
}

fn foldState(a: tree_view.GitState, b: tree_view.GitState) tree_view.GitState {
    if (a == .conflicted or b == .conflicted) return .conflicted;
    if (a == .modified or b == .modified) return .modified;
    inline for (.{ .staged, .added, .renamed }) |k| if (a == k or b == k) return k;
    return .untracked;
}

/// An editor on `abs` with unsaved changes.
fn dirtyInEditor(app: *App, abs: []const u8) bool {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asEditor()) |e| if (e.buf.doc.path) |bp| {
        if (std.mem.eql(u8, bp, abs)) return p.dirty();
    };
    return false;
}

/// In a multi-repo workspace a top-level directory that is one of the
/// repos gets the repo glyph; the active repo is the lit one.
fn repoMark(app: *App, abs: []const u8) ?tree_view.RepoMark {
    if (app.git.repos.items.len < 2) return null;
    for (app.git.repos.items, 0..) |r, i| if (std.mem.eql(u8, r.path, abs)) return .{ .active = app.git.active == i, .accent = @import("git_palette.zig").repoAccent(app, r.id) };
    return null;
}

/// A command reached from a key: `command.run` toasts the reason.
fn runCmd(app: *App, id: command.CommandId) Allocator.Error!void {
    command.run(app, .{ .static = id }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// `path` relative to `base` when it lies under it, else null.
/// The arrow-key preview's bounds: past either, the file is not
/// loaded as the cursor goes by (a 42 MB one-line bundle costs the
/// editor seconds and gigabytes; a 2 GB blob would be read whole).
pub const preview_max_bytes: u64 = 4 * 1024 * 1024;
pub const preview_max_line: usize = 16 * 1024;
/// How much of a file's head is scanned for a line that long.
const preview_head_bytes: usize = 64 * 1024;

/// Why `abs` is too heavy for an arrow-key preview, or null. Reads at
/// most `preview_head_bytes`, never the whole file.
pub fn previewTooHeavy(app: *App, abs: []const u8) Allocator.Error!?[]const u8 {
    const arena = app.frame.allocator();
    const st = std.Io.Dir.cwd().statFile(app.io, abs, .{}) catch return null;
    if (st.kind != .file) return null;
    if (st.size > preview_max_bytes) return try std.fmt.allocPrint(arena, "{d} MB", .{st.size / (1024 * 1024)});
    const file = std.Io.Dir.cwd().openFile(app.io, abs, .{}) catch return null;
    defer file.close(app.io);
    const head = try arena.alloc(u8, @min(preview_head_bytes, st.size));
    const n = file.readPositionalAll(app.io, head, 0) catch return null;
    var run: usize = 0;
    for (head[0..n]) |c| {
        if (c == '\n') {
            run = 0;
        } else {
            run += 1;
            if (run > preview_max_line) return try std.fmt.allocPrint(arena, "a line over {d} KB", .{preview_max_line / 1024});
        }
    }
    return null;
}

/// `path` below `base`, relative to it; null when it is not under it.
pub fn underRoot(base: []const u8, path: []const u8) ?[]const u8 {
    if (path.len > base.len + 1 and std.mem.startsWith(u8, path, base) and std.fs.path.isSep(path[base.len])) return path[base.len + 1 ..];
    return null;
}

/// `path` with Windows' own separator throughout (itself elsewhere).
fn nativeRel(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (builtin.os.tag != .windows or std.mem.indexOfScalar(u8, path, '/') == null) return path;
    const out = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '/', '\\');
    return out;
}

/// `rel` spelled as a row spells it: `/` between the parts (Windows'
/// own paths come in with `\`). On the frame arena when it had to change.
fn rowRel(arena: Allocator, rel: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, rel, '\\') == null or builtin.os.tag != .windows) return rel;
    const out = try arena.dupe(u8, rel);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

/// `name` in `dir` is a link whose target is a directory.
fn linkIsDir(app: *App, dir: std.Io.Dir, name: []const u8) bool {
    const st = dir.statFile(app.io, name, .{}) catch return false;
    return st.kind == .directory;
}

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
    if (row.header) return if (row.root == 0) "" else row.rel;
    return if (row.is_dir) row.rel else (std.fs.path.dirname(row.rel) orelse "");
}

// ─── workspace roots ────────────────────────────────────────────────────

/// `view.add_workspace`: a folder prompt. Tab completes a path segment
/// (`dispatch.promptPathComplete`); `~` and workspace-relative paths
/// are accepted. The root is not persisted — `workspaces` in
/// `config.zon` is.
fn addWorkspace(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    var state = app_mod.Prompt.init(app.gpa, "Add folder to workspace");
    state.placeholder = "path — tab completes";
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .add_workspace } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The add-workspace prompt's accept.
pub fn acceptAddWorkspace(app: *App, text: []const u8) Allocator.Error!void {
    const typed = std.mem.trim(u8, text, " \t");
    if (typed.len == 0) return;
    const idx = app.tree.addRoot(app, typed, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotADirectory => {
            app.toast("can't open workspace: {s} is not a directory", .{typed});
            return;
        },
        error.AlreadyOpen => {
            app.toast("workspace already open", .{});
            return;
        },
    };
    try app.tree.refresh(app);
    if (app.tree.headerRow(idx + 1)) |row| app.tree.cursor = row;
    app.tree.visible = true;
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .tree;
    // The root's repos join the switcher and the status pipeline.
    @import("git.zig").discover(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    app.toast("workspace added: {s} (add it to `workspaces` in config.zon to persist)", .{app.tree.roots.items[idx].name});
    app.needs_render = true;
}

/// `view.switch_workspace`: a picker over the primary and every extra
/// root; the pick opens that section and folds the others.
/// One workspace the switcher offers: the primary first, then the
/// extra roots, in the tree's order — `Tree.switchTo`'s index.
pub const WorkspaceRow = struct {
    name: []const u8,
    path: []const u8,
    /// The tree shows this root's files.
    expanded: bool,
};

/// The workspaces `view.switch_workspace` lists, on `arena` — the
/// picker's rows and the start surface's WORKSPACES
/// (`app/welcome.zig`) read the same list. Borrowed slices: the names
/// and paths are the tree's.
pub fn workspaceRows(app: *App, arena: Allocator) Allocator.Error![]const WorkspaceRow {
    try app.tree.syncRoots(app);
    const out = try arena.alloc(WorkspaceRow, 1 + app.tree.roots.items.len);
    const primary = std.fs.path.basename(app.workspace);
    out[0] = .{ .name = if (primary.len > 0) primary else app.workspace, .path = app.workspace, .expanded = app.tree.primary_expanded };
    for (app.tree.roots.items, out[1..]) |r, *o| o.* = .{ .name = r.name, .path = r.path, .expanded = r.expanded };
    return out;
}

fn switchWorkspace(app: *App) CommandError!void {
    const gpa = app.gpa;
    const rows = try workspaceRows(app, app.frame.allocator());
    if (rows.len == 1) return app.diag.fail(app.frame.allocator(), "one workspace open — view.add_workspace adds another", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (rows) |r| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (r.expanded) "* " else "", r.name }));
        try details.append(gpa, try gpa.dupe(u8, r.path));
    }
    const cmd_picker = @import("cmd_picker.zig");
    try cmd_picker.openPickerWith(app, "Switch workspace", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(app_mod.PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &acceptSwitch;
}

fn acceptSwitch(app: *App, idx: usize, label: []const u8) Allocator.Error!void {
    _ = label;
    if (idx > app.tree.roots.items.len) return;
    try app.tree.switchTo(app, idx);
}

/// `view.remove_workspace`: a picker over the extra roots (never the
/// primary); the pick drops that root for this run — `workspaces` in
/// `config.zon` is where it is kept.
fn removeWorkspace(app: *App) CommandError!void {
    try app.tree.syncRoots(app);
    const gpa = app.gpa;
    if (app.tree.roots.items.len == 0) return app.diag.fail(app.frame.allocator(), "no extra workspace to remove", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (app.tree.roots.items) |r| {
        try labels.append(gpa, try gpa.dupe(u8, r.name));
        try details.append(gpa, try gpa.dupe(u8, r.path));
    }
    const cmd_picker = @import("cmd_picker.zig");
    try cmd_picker.openPickerWith(app, "Remove workspace", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(app_mod.PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &acceptRemove;
}

fn acceptRemove(app: *App, idx: usize, label: []const u8) Allocator.Error!void {
    if (idx >= app.tree.roots.items.len) return;
    const name = try app.frame.allocator().dupe(u8, label);
    try app.tree.removeRoot(app, idx);
    // Its repos leave the switcher with it.
    try @import("git.zig").discover(app);
    app.toast("workspace removed: {s} (drop it from `workspaces` in config.zon to persist)", .{name});
}

/// `view.open_default_workspace`: `.startup.default_workspace` opens
/// as the tree's section — added as an extra root when it is new,
/// switched to when it is the workspace or a root already.
fn openDefaultWorkspace(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const path = app.cfg.startup.default_workspace orelse return app.diag.fail(arena, "no default_workspace configured (set `.startup.default_workspace` in config.zon)", .{});
    try app.tree.syncRoots(app);
    const canon = Tree.canonicalRoot(app, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotADirectory => return app.diag.fail(arena, "can't open workspace: {s} is not a directory", .{path}),
    };
    const idx = app.tree.indexOfRoot(app, canon) orelse blk: {
        const i = app.tree.addRoot(app, canon, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotADirectory => return app.diag.fail(arena, "can't open workspace: {s} is not a directory", .{path}),
            error.AlreadyOpen => unreachable,
        };
        try @import("git.zig").discover(app);
        break :blk i + 1;
    };
    try app.tree.switchTo(app, idx);
}

/// `view.manage_workspaces`: the roots are the `.workspaces` list of
/// the home config (the settings overlay never edits a list), so this
/// opens that file and puts the cursor on the list when it has one.
fn manageWorkspaces(app: *App) CommandError!void {
    try command.run(app, .{ .static = .@"file.open_settings" });
    if (app.activeEditor()) |e| {
        const text = e.buf.editor.bytes();
        if (std.mem.indexOf(u8, text, ".workspaces")) |pos| {
            const line = std.mem.count(u8, text[0..pos], "\n");
            e.buf.editor.placeCursor(line, 0);
        }
    }
    app.toast("workspaces are the `.workspaces` list in config.zon", .{});
    app.needs_render = true;
}

/// `view.reveal_in_tree`: the active pane's file — an editor with a
/// path, or a preview — selected in the tree (`Tree.revealPath`).
fn revealInTree(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const id = app.active orelse return app.diag.fail(arena, "no file to reveal", .{});
    const p = app.panes.get(id) orelse return app.diag.fail(arena, "no file to reveal", .{});
    const path: ?[]const u8 = switch (p.*) {
        .editor => |*e| e.buf.doc.path,
        .md_preview => |*m| m.path,
        else => null,
    };
    const abs = try arena.dupe(u8, path orelse return app.diag.fail(arena, "no file to reveal", .{}));
    try app.tree.revealPath(app, abs);
}

/// `view.toggle_tree_section`: the primary section folds or opens;
/// opening puts the keys in the tree (Rust `toggle_tree_root_expanded`).
fn toggleTreeSection(app: *App) CommandError!void {
    const open = !app.tree.primary_expanded;
    app.tree.primary_expanded = open;
    if (open) side.place(app, .explorer, true);
    try app.tree.refresh(app);
    app.needs_render = true;
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

/// `file.new` from anywhere but the tree: "New file in <dir>/", empty,
/// as the Rust app asks — a bare name lands in `dir` (workspace root
/// for ""), a path with `/` where it says.
pub fn promptNewFileIn(app: *App, dir_in: []const u8) CommandError!void {
    const dir = try app.gpa.dupe(u8, dir_in);
    errdefer app.gpa.free(dir);
    const title = try std.fmt.allocPrint(app.gpa, "New file in {s}/", .{dir});
    errdefer app.gpa.free(title);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, title), .purpose = .{ .new_file = dir }, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn newFolder(app: *App) CommandError!void {
    if (files_pane.focused(app) != null) return files_pane.newFolderCmd(app);
    const dir = try app.gpa.dupe(u8, dirBeside(app));
    errdefer app.gpa.free(dir);
    try openPathPrompt(app, "New folder (workspace-relative)", .{ .new_folder = dir }, dir);
}

fn rename(app: *App) CommandError!void {
    if (files_pane.focused(app) != null) return files_pane.renameCmd(app);
    const row = try app.tree.selected(app);
    const rel = try app.gpa.dupe(u8, row.rel);
    errdefer app.gpa.free(rel);
    app.overlay.deinit(app.gpa);
    // Rust's prompt: `Rename <rel>` seeded with the name alone — a bare
    // name stays beside the file; a path with `/` moves it there.
    const title = try std.fmt.allocPrint(app.gpa, "Rename {s}", .{app.relPath(rel)});
    errdefer app.gpa.free(title);
    var state = app_mod.Prompt.init(app.gpa, title);
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    try state.seed(app.gpa, row.name());
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .rename = rel }, .title_owned = title, .return_focus = promptReturnFocus(app) } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// A prompt the tree opened hands focus back to the tree — Esc and
/// Enter both — so the next arrow key moves the tree cursor, not the
/// editor's. Opened from anywhere else, the active pane takes it.
fn promptReturnFocus(app: *App) ?app_mod.FocusId {
    return if (app.focus == .tree) .tree else null;
}

pub const move_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'm', .label = "Move" }, .{ .key = 'c', .label = "Cancel" } };

/// `Delete…` on the cursor row — or a focused Files pane's marks. The
/// confirm offers the trash and the permanent form (`trash.zig`).
fn delete(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const paths = try file_clipboard.targetPaths(app, arena);
    if (paths.len == 0) return app.diag.fail(arena, "no tree row selected", .{});
    try trash.confirmDelete(app, paths);
}

/// `Move to…`: a prompt for the destination folder.
/// `file.move_to`: a prompt seeded with the row's folder — Tab
/// completes folders, `~` is home — that moves the row into the typed
/// folder (`acceptRename` joins the name when the target is a folder).
fn moveTo(app: *App) CommandError!void {
    if (files_pane.focused(app) != null) return files_pane.moveToCmd(app);
    const row = try app.tree.selected(app);
    const rel = try app.gpa.dupe(u8, row.rel);
    errdefer app.gpa.free(rel);
    app.overlay.deinit(app.gpa);
    const title = try std.fmt.allocPrint(app.gpa, "Move {s} to folder", .{row.name()});
    errdefer app.gpa.free(title);
    var state = app_mod.Prompt.init(app.gpa, title);
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    if (std.fs.path.dirname(row.rel)) |parent| try state.setText(app.gpa, try std.fmt.allocPrint(app.frame.allocator(), "{s}/", .{parent}));
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .rename = rel }, .title_owned = title, .return_focus = promptReturnFocus(app) } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub const copy_choices = [_]app_mod.Confirm.Choice{ .{ .key = 'y', .label = "Copy" }, .{ .key = 'c', .label = "Cancel" } };

/// A drag of row `from` released on directory row `into`: ask first.
/// An Alt-drag (`copy`) copies instead of moving.
pub fn confirmMove(app: *App, from_idx: usize, into_idx: usize, copy: bool) Allocator.Error!void {
    if (from_idx >= app.tree.rows.items.len or into_idx >= app.tree.rows.items.len) return;
    const from = app.tree.rows.items[from_idx];
    const into = app.tree.rows.items[into_idx];
    if (!into.is_dir or from_idx == into_idx) return;
    if (std.mem.startsWith(u8, into.rel, from.rel) and (into.rel.len == from.rel.len or std.fs.path.isSep(into.rel[from.rel.len]))) return;
    const from_rel = try app.gpa.dupe(u8, from.rel);
    errdefer app.gpa.free(from_rel);
    const into_rel = try app.gpa.dupe(u8, into.rel);
    errdefer app.gpa.free(into_rel);
    const msg = try std.fmt.allocPrint(app.gpa, "  {s} {s} into {s}/?", .{ if (copy) "Copy" else "Move", from.name(), into.rel });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = if (copy) "Copy to folder" else "Move to folder", .message = msg, .choices = if (copy) &copy_choices else &move_choices },
        .purpose = .{ .move_path = .{ .from = from_rel, .into = into_rel, .copy = copy } },
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

// ─── the file verbs, once confirmed ─────────────────────────────────────

/// The typed target as a workspace-relative path: `~` is home, an
/// absolute path under the workspace is made relative, one outside it
/// stays absolute. Slashes at the ends go; empty is null.
fn cleanRel(app: *App, text: []const u8) ?[]const u8 {
    const expanded = app.expandTilde(std.mem.trim(u8, text, " \t")) catch text;
    // Before any slash trimming: a POSIX absolute path IS its leading slash.
    const rel = if (std.fs.path.isAbsolute(expanded)) app.relPath(expanded) else expanded;
    if (std.fs.path.isAbsolute(rel)) {
        const outside = std.mem.trimEnd(u8, rel, "/");
        return if (outside.len == 0) null else outside;
    }
    const trimmed = std.mem.trim(u8, rel, " \t/");
    if (trimmed.len == 0) return null;
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
        lsp.notifyWatched(app, abs, .created);
    };
    try files_pane.refreshAfterFsChange(app);
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
    try files_pane.refreshAfterFsChange(app);
    if (app.tree.rowOf(full)) |i| app.tree.cursor = i;
    app.toast("created {s}/", .{full});
}

/// Rename / move `from` to the prompt's text — a path, or a folder
/// (existing) the entry moves into keeping its name.
pub fn acceptRename(app: *App, from: []const u8, text: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    var to = cleanRel(app, text) orelse return;
    // A bare name stays beside the source — a rename, not a move to the
    // workspace root (or, for a Files pane's absolute row, to the cwd).
    if (std.mem.indexOfScalar(u8, to, '/') == null and !std.fs.path.isAbsolute(to)) {
        if (std.fs.path.dirname(from)) |dir| to = try std.fs.path.join(arena, &.{ dir, to });
    }
    if (std.mem.eql(u8, to, from)) return;
    // A trailing slash names a folder, as it does for `mv` and the
    // New-file prompt: `newdir/` moves the file INTO newdir (made when
    // missing), keeping its name — never renames it to `newdir`.
    const into_dir = std.mem.endsWith(u8, std.mem.trimEnd(u8, text, " \t"), "/");
    const to_abs = try app.absPath(to);
    if (into_dir) {
        to = try std.fs.path.join(arena, &.{ to, std.fs.path.basename(from) });
    } else if (std.Io.Dir.cwd().statFile(app.io, to_abs, .{})) |st| {
        if (st.kind == .directory) to = try std.fs.path.join(arena, &.{ to, std.fs.path.basename(from) });
    } else |_| {}
    try movePath(app, from, to);
}

pub fn acceptMove(app: *App, from: []const u8, into: []const u8) Allocator.Error!void {
    const to = try std.fs.path.join(app.frame.allocator(), &.{ into, std.fs.path.basename(from) });
    try movePath(app, from, to);
}

/// An Alt-drag confirmed: `from` is copied into `into` on the transfer
/// worker (a directory recursively), the original untouched.
pub fn acceptCopy(app: *App, from: []const u8, into: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const transfers = @import("transfers.zig");
    const src = try app.absPath(from);
    const dst = try std.fs.path.join(arena, &.{ try app.absPath(into), std.fs.path.basename(from) });
    if (std.Io.Dir.cwd().access(app.io, dst, .{})) {
        app.toast("already exists: {s}", .{app.relPath(dst)});
        return;
    } else |_| {}
    const items = [_]transfers.Item{.{ .src = src, .dst = dst }};
    if (transfers.clash(app, &items)) |busy| {
        app.toast("already writing {s} — wait for it to finish", .{app.relPath(busy)});
        return;
    }
    _ = transfers.start(app, .copy, &items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m});
            app.diag.clear();
        },
    };
}

fn movePath(app: *App, from: []const u8, to: []const u8) Allocator.Error!void {
    const from_abs = try app.absPath(from);
    const to_abs = try app.absPath(to);
    // A taken name is refused — a rename never replaces what is already
    // there. The one exception is the same file under another spelling
    // (a case-only rename on a case-insensitive volume): same inode.
    if (std.Io.Dir.cwd().statFile(app.io, to_abs, .{ .follow_symlinks = false })) |to_st| {
        const same = if (std.Io.Dir.cwd().statFile(app.io, from_abs, .{ .follow_symlinks = false })) |from_st| from_st.inode == to_st.inode else |_| false;
        if (!same) {
            app.toast("already exists: {s} — nothing moved", .{app.relPath(to)});
            return;
        }
    } else |_| {}
    if (std.fs.path.dirname(to)) |parent| std.Io.Dir.cwd().createDirPath(app.io, try app.absPath(parent)) catch {};
    std.Io.Dir.rename(std.Io.Dir.cwd(), from_abs, std.Io.Dir.cwd(), to_abs, app.io) catch |err| {
        app.toast("move {s}: {s}", .{ from, @errorName(err) });
        return;
    };
    lsp.notifyWatched(app, from_abs, .deleted);
    lsp.notifyWatched(app, to_abs, .created);
    try retargetBuffers(app, from_abs, to_abs);
    try files_pane.refreshAfterFsChange(app);
    if (app.tree.rowOf(to)) |i| app.tree.cursor = i;
    app.toast("moved {s} → {s}", .{ app.relPath(from), app.relPath(to) });
}

/// An open buffer follows its file: every editor on `from_abs` — or,
/// a folder, under it — now points at the same file under `to_abs`.
/// Every move calls this: a rename, a drag, `file.move_to`, and the
/// clipboard's cut-and-paste when its transfer lands.
pub fn retargetBuffers(app: *App, from_abs: []const u8, to_abs: []const u8) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.asEditor()) |e| if (e.buf.doc.path) |bp| {
        if (std.mem.eql(u8, bp, from_abs)) {
            try e.buf.setPath(to_abs);
        } else if (std.mem.startsWith(u8, bp, from_abs) and bp.len > from_abs.len and std.fs.path.isSep(bp[from_abs.len])) {
            const moved = try std.fs.path.join(app.frame.allocator(), &.{ to_abs, bp[from_abs.len + 1 ..] });
            try e.buf.setPath(moved);
        }
    };
}

/// Delete `rel` into the trash (`trash.deletePaths`); buffers on the
/// path close and the tree and every browser re-read.
pub fn acceptDelete(app: *App, rel: []const u8) Allocator.Error!void {
    const abs = try app.frame.allocator().dupe(u8, try app.absPath(rel));
    try trash.deletePaths(app, &.{abs}, false);
}

/// `view.toggle_tree` (Ctrl+B / vim's Ctrl+N): the left column —
/// whatever section it shows — closes, or comes back on what it showed
/// last. Under vim the tree that comes back takes the keys, as
/// NvChad's `<C-n>` (`NvimTreeToggle`) does; VS Code's Ctrl+B leaves
/// the focus where it was.
fn toggle(app: *App) CommandError!void {
    // // changed (sidebar-autohide): under `ui.sidebar = .auto` /
    // `.hidden` the column is not docked, so the toggle is the
    // overlay's — up if it is down, away if it is up. `.hidden` has no
    // other door, which is the point of the one-shot.
    if (sidebar_auto.keyboardReach(app, .left, true)) return;
    const opening = side.shown(app, .left) == null;
    try side.toggleColumn(app, .left);
    if (opening and app.input_style == .vim and app.tree.visible) side.focusSection(app, .explorer);
}

/// `view.focus_tree` (Ctrl+Shift+E / vim's `<leader>e`): the tree takes
/// the keys, opened first when it was hidden — NvChad's `<leader>e`
/// (`NvimTreeFocus`) — never hidden.
/// `space e` / Ctrl+Shift+E: the tree takes the keys, on the active
/// file's row — NvChad's nvim-tree `update_focused_file` and VS Code's
/// `explorer.autoReveal`. A buffer with no file (or one outside every
/// root) leaves the tree cursor where it was.
fn focus(app: *App) CommandError!void {
    side.place(app, .explorer, true);
    const id = app.active orelse return;
    const p = app.panes.get(id) orelse return;
    const path: []const u8 = switch (p.*) {
        .editor => |*e| e.buf.doc.path orelse return,
        .md_preview => |*m| m.path,
        else => return,
    };
    const abs = try app.frame.allocator().dupe(u8, path);
    app.tree.revealPath(app, abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            app.diag.clear();
            side.place(app, .explorer, true);
        },
    };
}

fn toggleHidden(app: *App) CommandError!void {
    app.tree.show_hidden = !app.tree.show_hidden;
    try app.tree.refresh(app);
    app.toast("hidden files {s}", .{if (app.tree.show_hidden) "shown" else "hidden"});
}

fn refreshCmd(app: *App) CommandError!void {
    // `git init` / a clone since the last look: ask again.
    app.tree.in_repo = null;
    try app.tree.refresh(app);
    app.needs_render = true;
}

fn collapseAll(app: *App) CommandError!void {
    var it = app.tree.expanded.keyIterator();
    while (it.next()) |k| app.gpa.free(k.*);
    app.tree.expanded.clearRetainingCapacity();
    try app.tree.refresh(app);
}

fn toggleIgnored(app: *App) CommandError!void {
    app.tree.show_ignored = !app.tree.show_ignored;
    try app.tree.refresh(app);
    app.toast("git-ignored files {s}", .{if (app.tree.show_ignored) "shown (dim)" else "hidden"});
    app.needs_render = true;
}

fn toggleCollapseAll(app: *App) CommandError!void {
    if (app.tree.expanded.count() > 0) return collapseAll(app);
    return expandAll(app);
}

/// Expand every directory (the noisy ones stay closed).
fn expandAll(app: *App) CommandError!void {
    try app.tree.expandAllDirs(app);
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

test "tree: lists dirs first, expands on Enter, opens a file, shows dot entries until H hides them" {
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
    // A top-level directory opens on its first refresh; the dot file
    // shows, sorted case-blind ahead of README.md.
    try t.expectEqual(@as(usize, 4), app.tree.rows.items.len);
    try t.expectEqualStrings("src", app.tree.rows.items[0].rel);
    try t.expect(app.tree.rows.items[0].is_dir);
    try t.expectEqualStrings(".hidden", app.tree.rows.items[2].rel);
    try t.expectEqualStrings("README.md", app.tree.rows.items[3].rel);
    app.focus = .tree;
    // Enter closes it; Enter again re-opens it (a second refresh does not).
    try t.expect(try app.tree.handleKey(&app, Key.named(.enter)));
    try t.expectEqual(@as(usize, 3), app.tree.rows.items.len);
    try app.tree.refresh(&app);
    try t.expectEqual(@as(usize, 3), app.tree.rows.items.len);
    try t.expect(try app.tree.handleKey(&app, Key.named(.enter)));
    try t.expectEqual(@as(usize, 4), app.tree.rows.items.len);
    try t.expectEqualStrings("src/main.zig", app.tree.rows.items[1].rel);
    try t.expectEqual(@as(u8, 1), app.tree.rows.items[1].depth);
    _ = try app.tree.handleKey(&app, Key.char('j'));
    _ = try app.tree.handleKey(&app, Key.named(.enter));
    try t.expectEqualStrings("main.zig", app.panes.get(app.active.?).?.title());
    _ = try app.tree.handleKey(&app, Key.char('H'));
    try t.expectEqual(@as(usize, 3), app.tree.rows.items.len);
    try t.expect(app.tree.rowOf(".hidden") == null);
    try t.expect(!try app.tree.handleKey(&app, Key.ctrl('p')));
    try command.run(&app, .{ .static = .@"tree.collapse_all" });
    try t.expectEqual(@as(usize, 2), app.tree.rows.items.len);
}

test "tree, vim profile: nvim-tree's a / r / d / x / R / E / W — create, rename, delete (confirmed), cut, refresh, expand all, collapse all" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    try tmp.dir.createDirPath(t.io, "sub");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sub/cc.txt", .data = "cc" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "aa.txt", .data = "aa" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n] });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try app.tree.refresh(&app);
    app.focus = .tree;
    // `E` expands every folder, `W` folds them back.
    try command.run(&app, .{ .static = .@"tree.collapse_all" });
    try t.expect(app.tree.rowOf("sub/cc.txt") == null);
    try app.handle(.{ .key = Key.char('E') });
    try t.expect(app.tree.rowOf("sub/cc.txt") != null);
    try app.handle(.{ .key = Key.char('W') });
    try t.expect(app.tree.rowOf("sub/cc.txt") == null);
    // `a` prompts for a new file; typing a name and Enter creates it.
    app.tree.cursor = app.tree.rowOf("aa.txt").?;
    try app.handle(.{ .key = Key.char('a') });
    try t.expect(app.overlay == .prompt);
    for ("bb.txt") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expect(app.tree.rowOf("bb.txt") != null);
    // `r` is rename (the standard profile's `r` refreshes); `R` refreshes.
    app.focus = .tree;
    app.tree.cursor = app.tree.rowOf("bb.txt").?;
    try app.handle(.{ .key = Key.char('r') });
    try t.expect(app.overlay == .prompt);
    try t.expect(std.mem.indexOf(u8, app.overlay.prompt.state.buf.items, "bb.txt") != null);
    try app.handle(.{ .key = Key.named(.esc) });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "zz.txt", .data = "zz" });
    try t.expect(app.tree.rowOf("zz.txt") == null);
    app.focus = .tree;
    try app.handle(.{ .key = Key.char('R') });
    try t.expect(app.tree.rowOf("zz.txt") != null);
    // `x` cuts (one key, nvim-tree's); `d` asks before deleting.
    app.tree.cursor = app.tree.rowOf("zz.txt").?;
    try app.handle(.{ .key = Key.char('x') });
    try t.expect(app.file_clipboard.cut);
    try t.expectEqual(@as(usize, 1), app.file_clipboard.paths.items.len);
    try app.handle(.{ .key = Key.char('d') });
    try t.expect(app.overlay == .confirm);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.tree.rowOf("zz.txt") != null);
    // Standard profile: `a` / `x` / `E` are not the tree's, `r` refreshes.
    try command.run(&app, .{ .static = .@"editor.use_standard" });
    app.focus = .tree;
    try t.expect(!try app.tree.handleKey(&app, Key.char('a')));
    try t.expect(!try app.tree.handleKey(&app, Key.char('x')));
    try t.expect(!try app.tree.handleKey(&app, Key.char('E')));
    try t.expect(try app.tree.handleKey(&app, Key.char('r')));
    try t.expect(app.overlay == .none);
}

test "expand all lists each folder once, however deep — not the whole tree once per level" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    // A 12-deep chain beside a few wide folders, a file at every level.
    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(t.allocator);
    for (0..12) |i| {
        if (i > 0) try path.append(t.allocator, '/');
        try path.print(t.allocator, "d{d}", .{i});
        try tmp.dir.createDirPath(t.io, path.items);
        const f = try std.fmt.allocPrint(t.allocator, "{s}/f.txt", .{path.items});
        defer t.allocator.free(f);
        try tmp.dir.writeFile(t.io, .{ .sub_path = f, .data = "x" });
    }
    for ([_][]const u8{ "w1/a", "w1/b", "w2/a", "w3" }) |d| try tmp.dir.createDirPath(t.io, d);
    try tmp.dir.createDirPath(t.io, "node_modules/pkg");
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n] });
    defer app.deinit();
    try app.tree.refresh(&app);
    try command.run(&app, .{ .static = .@"tree.collapse_all" });
    const before = dirs_listed;
    try command.run(&app, .{ .static = .@"tree.expand_all" });
    // 12 chain + 6 wide + node_modules (listed, never entered) + the root;
    // a second listing of the top level when the first opens new
    // top-level folders is allowed.
    try t.expect(dirs_listed - before <= 2 * 20);
    try t.expect(app.tree.rowOf("d0/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/f.txt") != null);
    try t.expect(app.tree.rowOf("w1/b") != null);
    try t.expect(app.tree.rowOf("node_modules/pkg") == null);
}

test "the arrow preview skips a file too heavy to glance at — a very long line, or too many bytes — and says so" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    const one_line = try t.allocator.alloc(u8, 40 * 1024);
    defer t.allocator.free(one_line);
    @memset(one_line, 'x');
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.min.json", .data = one_line });
    const big = try t.allocator.alloc(u8, preview_max_bytes + 4096);
    defer t.allocator.free(big);
    for (big, 0..) |*c, i| c.* = if (i % 64 == 63) '\n' else 'y';
    try tmp.dir.writeFile(t.io, .{ .sub_path = "c.log", .data = big });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "d.txt", .data = "d" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n] });
    defer app.deinit();
    app.input_style = .standard;
    app.cfg.ui.tree_preview_on_arrow = true;
    try app.tree.refresh(&app);
    app.focus = .tree;
    app.tree.cursor = app.tree.rowOf("a.txt").?;
    _ = try app.tree.handleKey(&app, Key.named(.down));
    try t.expectEqual(app.tree.rowOf("b.min.json").?, app.tree.cursor);
    try t.expect(app.panes.findPath(try app.absPath("b.min.json")) == null);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "b.min.json: a line over 16 KB — not previewed") != null);
    _ = try app.tree.handleKey(&app, Key.named(.down));
    try t.expect(app.panes.findPath(try app.absPath("c.log")) == null);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "c.log: 4 MB — not previewed") != null);
    // An ordinary file still previews.
    _ = try app.tree.handleKey(&app, Key.named(.down));
    try t.expect(app.panes.findPath(try app.absPath("d.txt")) != null);
}

test "rename / move onto a taken name is refused — the existing bytes survive" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    try tmp.dir.createDirPath(t.io, "sub");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "AAA" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "BBB" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sub/a.txt", .data = "SUBA" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n] });
    defer app.deinit();
    try app.tree.refresh(&app);
    var got: [16]u8 = undefined;
    // F2 onto a sibling's name.
    try acceptRename(&app, "a.txt", "b.txt");
    try t.expectEqualStrings("BBB", try tmp.dir.readFile(t.io, "b.txt", &got));
    try t.expectEqualStrings("AAA", try tmp.dir.readFile(t.io, "a.txt", &got));
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "already exists: b.txt"));
    // Into a folder that holds the same name (the rename prompt and `file.move_to`).
    try acceptRename(&app, "a.txt", "sub");
    try t.expectEqualStrings("SUBA", try tmp.dir.readFile(t.io, "sub/a.txt", &got));
    // A drag-move onto the same folder.
    try acceptMove(&app, "a.txt", "sub");
    try t.expectEqualStrings("SUBA", try tmp.dir.readFile(t.io, "sub/a.txt", &got));
    try t.expectEqualStrings("AAA", try tmp.dir.readFile(t.io, "a.txt", &got));
    // A free name still moves.
    try acceptRename(&app, "a.txt", "c.txt");
    try t.expectEqualStrings("AAA", try tmp.dir.readFile(t.io, "c.txt", &got));
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "moved"));
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
    try confirmMove(&app, bb, lib, false);
    try t.expect(app.overlay == .confirm);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.state.title, "Move to") != null);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    const expect_path = try std.fs.path.join(t.allocator, &.{ buf[0..n], "lib", "bb.txt" });
    defer t.allocator.free(expect_path);
    try t.expectEqualStrings(expect_path, app.activeEditor().?.buf.doc.path.?);
    // Delete closes the buffer and drops the row.
    try acceptDelete(&app, "lib/bb.txt");
    try t.expect(app.active == null);
    try t.expect(app.tree.rowOf("lib/bb.txt") == null);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"tree.open_in_split" }));
}

test "tree: Ctrl+Shift+X/C/V/D are not the clipboard chords — the tree declines them, the plain forms it takes" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "aa" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    app.tree.cursor = app.tree.rows.items.len - 1;
    try t.expectEqualStrings("a.txt", app.tree.rows.items[app.tree.cursor].rel);
    for ([_]u21{ 'd', 'x', 'c', 'v' }) |c| {
        const shifted = Key{ .code = .{ .char = c }, .mods = .{ .ctrl = true, .shift = true } };
        try t.expect(!try app.tree.handleKey(&app, shifted));
    }
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "a-copy.txt", .{}));
    try t.expect(app.file_clipboard.paths.items.len == 0);
    // The plain chord is still the clipboard's.
    try t.expect(try app.tree.handleKey(&app, Key.ctrl('x')));
    try t.expectEqual(@as(usize, 1), app.file_clipboard.paths.items.len);
}

test "tree: F2 opens the rename prompt seeded with the row; other function keys go to the chain" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "aa" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.tree.refresh(&app);
    app.focus = .tree;
    app.tree.cursor = app.tree.rows.items.len - 1;
    try t.expect(!try app.tree.handleKey(&app, Key{ .code = .{ .f = 3 }, .mods = .{} }));
    try t.expect(app.overlay == .none);
    try t.expect(try app.tree.handleKey(&app, Key{ .code = .{ .f = 2 }, .mods = .{} }));
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("Rename a.txt", app.overlay.prompt.state.title);
    try t.expectEqualStrings("a.txt", app.overlay.prompt.state.text());
    try t.expect(app.focus == .overlay);
}

test "tree: artifact directories and .git stay out of the rows without a .gitignore, with H either way; a build dir only outside a repo; a .gitignore hides what it names" {
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
    try tmp.dir.createDirPath(t.io, ".git/objects");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "build", .data = "a file named build stays" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.tree.refresh(&app);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(t.allocator);
    for (app.tree.rows.items) |r| try names.append(t.allocator, r.name());
    // A repo (the `.git` above): `vendor` is the .gitignore's call, and
    // none names it — it is listed; node_modules / __pycache__ never are.
    try t.expectEqual(@as(usize, 3), names.items.len);
    try t.expectEqualStrings("src", names.items[0]);
    try t.expectEqualStrings("vendor", names.items[1]);
    try t.expectEqualStrings("build", names.items[2]);
    app.tree.show_hidden = false;
    try app.tree.refresh(&app);
    try t.expectEqual(@as(usize, 3), app.tree.rows.items.len);
    // No repo: the name alone hides `vendor`.
    try tmp.dir.deleteTree(t.io, ".git");
    app.tree.in_repo = false;
    try app.tree.refresh(&app);
    try t.expectEqual(@as(usize, 2), app.tree.rows.items.len);
    try t.expect(app.tree.rowOf("vendor") == null);
    // `I` brings every one of them back, dim.
    app.tree.show_ignored = true;
    try app.tree.refresh(&app);
    try t.expect(app.tree.rows.items[app.tree.rowOf("node_modules").?].ignored);
    try t.expect(app.tree.rows.items[app.tree.rowOf("vendor").?].ignored);
    try t.expect(!app.tree.rows.items[app.tree.rowOf("src").?].ignored);
    app.tree.show_ignored = false;
    // A `.gitignore` in the root hides what it names — at any depth
    // for a bare name, under its own directory for an anchored one.
    app.tree.show_hidden = true;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/keep.zig", .data = "k" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/gen.zig", .data = "g" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/.cache", .data = "c" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".gitignore", .data = "gen.zig\n/build\n.cache\n" });
    try app.tree.refresh(&app);
    try t.expect(app.tree.rowOf("src/keep.zig") != null);
    try t.expect(app.tree.rowOf("src/gen.zig") == null);
    try t.expect(app.tree.rowOf("src/.cache") == null);
    try t.expect(app.tree.rowOf("build") == null);
    try t.expect(app.tree.rowOf(".gitignore") != null);
}

test "multi-root: cfg.workspaces become collapsed sections; a header opens on enter; rows under an extra root are absolute; ← lands on the header" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "main/src");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "main/src/a.zig", .data = "a" });
    try tmp.dir.createDirPath(t.io, "extra/lib");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extra/lib/b.zig", .data = "b" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extra/README.md", .data = "r" });
    const main_ws = try std.fs.path.join(t.allocator, &.{ root, "main" });
    defer t.allocator.free(main_ws);
    const extra_ws = try std.fs.path.join(t.allocator, &.{ root, "extra" });
    defer t.allocator.free(extra_ws);
    const workspaces = [_]@import("../config/Config.zig").Workspace{
        .{ .name = "sibling", .path = extra_ws },
        .{ .name = "", .path = main_ws }, // the workspace itself: skipped
        .{ .name = "", .path = "/nonexistent/dir" }, // missing: skipped
    };
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = main_ws, .cfg = .{ .workspaces = &workspaces } });
    defer app.deinit();
    try app.tree.refresh(&app);
    try t.expectEqual(@as(usize, 1), app.tree.roots.items.len);
    try t.expectEqualStrings("sibling", app.tree.roots.items[0].name);
    try t.expectEqualStrings(extra_ws, app.tree.roots.items[0].path);
    // Rows: the open `main` header + src (depth 1, opened on first sight)
    // + a.zig (depth 2) + the collapsed `sibling` header.
    try t.expectEqual(@as(usize, 4), app.tree.rows.items.len);
    try t.expect(app.tree.rows.items[0].header);
    try t.expectEqual(@as(u8, 0), app.tree.rows.items[0].root);
    try t.expectEqualStrings("src", app.tree.rows.items[1].rel);
    try t.expectEqual(@as(u8, 1), app.tree.rows.items[1].depth);
    try t.expectEqualStrings("src/a.zig", app.tree.rows.items[2].rel);
    try t.expect(app.tree.rows.items[3].header);
    try t.expect(!app.tree.roots.items[0].expanded);
    app.focus = .tree;
    app.tree.cursor = 3;
    try t.expect(try app.tree.handleKey(&app, Key.named(.enter)));
    try t.expect(app.tree.roots.items[0].expanded);
    // lib/ then README.md, absolute, one deeper than the header.
    try t.expectEqual(@as(usize, 6), app.tree.rows.items.len);
    try t.expect(std.fs.path.isAbsolute(app.tree.rows.items[4].rel));
    try t.expectEqualStrings("lib", app.tree.rows.items[4].name());
    try t.expectEqual(@as(u8, 1), app.tree.rows.items[4].root);
    try t.expectEqualStrings("README.md", app.tree.rows.items[5].name());
    // Open lib/, step onto b.zig, ← twice: lib, then the sibling header.
    app.tree.cursor = 4;
    _ = try app.tree.handleKey(&app, Key.char('l'));
    try t.expectEqualStrings("b.zig", app.tree.rows.items[5].name());
    app.tree.cursor = 5;
    _ = try app.tree.handleKey(&app, Key.char('h'));
    try t.expectEqual(@as(usize, 4), app.tree.cursor);
    _ = try app.tree.handleKey(&app, Key.char('h'));
    try t.expectEqual(@as(usize, 4), app.tree.cursor); // lib folds first
    _ = try app.tree.handleKey(&app, Key.char('h'));
    try t.expectEqual(@as(usize, 3), app.tree.cursor);
    // Enter on a file under the extra root opens it by its absolute path.
    app.tree.cursor = 4;
    _ = try app.tree.handleKey(&app, Key.char('l'));
    try t.expectEqualStrings("b.zig", app.tree.rows.items[5].name());
    app.tree.cursor = 5;
    _ = try app.tree.handleKey(&app, Key.named(.enter));
    try t.expectEqualStrings("b.zig", app.panes.get(app.active.?).?.title());
    try t.expect(std.mem.startsWith(u8, app.activeEditor().?.buf.doc.path.?, extra_ws));
    // The switcher: pick the primary → it opens, the extra folds.
    try app.tree.switchTo(&app, 0);
    try t.expect(app.tree.primary_expanded);
    try t.expect(!app.tree.roots.items[0].expanded);
    try t.expectEqual(@as(usize, 0), app.tree.cursor);
    try t.expectEqual(app_mod.FocusId.tree, app.focus);
    // The screen shows both headers: the primary's path, open, with
    // its chips; the extra's name, folded.
    app.cfg.ui.show_workspace_dots = false;
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "\u{f47c} ") != null);
    try t.expect(std.mem.indexOf(u8, txt, "\u{f460} sibling") != null);
    try t.expect(std.mem.indexOf(u8, txt, "\u{EB37}") != null);
}

test "mouse: one click opens a file (Rust), a click on a folder row folds it, the header folds the section, a chip prompts, the wheel steps the cursor" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "src");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.zig", .data = "x" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.render();
    const Hit = struct {
        fn of(a: *App, want: @import("../ui/hit.zig").HitTarget) ?Rect {
            for (a.hits.items.items) |e| if (std.meta.eql(e.target, want)) return e.rect;
            return null;
        }
    };
    // Press and release on notes.txt: the pane opens on the release.
    const notes = Hit.of(&app, .{ .tree_node = @intCast(app.tree.rowOf("notes.txt").?) }).?;
    try app.handle(.{ .mouse = .{ .x = notes.x + 8, .y = notes.y, .kind = .press, .button = .left } });
    try t.expect(app.active == null);
    try app.handle(.{ .mouse = .{ .x = notes.x + 8, .y = notes.y, .kind = .release, .button = .left } });
    try t.expectEqualStrings("notes.txt", app.panes.get(app.active.?).?.title());
    // A press on the folder row folds it at once; another opens it.
    try app.render();
    const src = Hit.of(&app, .{ .tree_node = @intCast(app.tree.rowOf("src").?) }).?;
    try app.handle(.{ .mouse = .{ .x = src.x + 3, .y = src.y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = src.x + 3, .y = src.y, .kind = .release, .button = .left } });
    try t.expect(app.tree.rowOf("src/main.zig") == null);
    try app.render();
    try app.handle(.{ .mouse = .{ .x = src.x + 3, .y = src.y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = src.x + 3, .y = src.y, .kind = .release, .button = .left } });
    try t.expect(app.tree.rowOf("src/main.zig") != null);
    // The header row folds the primary section: no rows, then back.
    try app.render();
    const header = Hit.of(&app, .{ .tree_root = 0 }).?;
    try app.handle(.{ .mouse = .{ .x = header.x + 5, .y = header.y, .kind = .press, .button = .left } });
    try t.expect(!app.tree.primary_expanded);
    try t.expectEqual(@as(usize, 0), app.tree.rows.items.len);
    try app.render();
    try app.handle(.{ .mouse = .{ .x = header.x + 5, .y = header.y, .kind = .press, .button = .left } });
    try t.expect(app.tree.primary_expanded);
    try t.expect(app.tree.rowOf("notes.txt") != null);
    // The new-file chip prompts, with the tree focused; the refresh chip is the last on the row.
    try app.render();
    const chip = Hit.of(&app, .{ .tree_chip = .new_file }).?;
    try t.expectEqual(header.y, chip.y);
    try t.expect(Hit.of(&app, .{ .tree_chip = .refresh }).?.x > chip.x);
    try app.handle(.{ .mouse = .{ .x = chip.x + 1, .y = chip.y, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("New file (workspace-relative)", app.overlay.prompt.state.title);
    try app.handle(.{ .key = Key.named(.esc) });
    // The wheel over a row steps the cursor by `wheel_lines`.
    try app.render();
    app.tree.cursor = 0;
    try app.handle(.{ .mouse = .{ .x = notes.x + 2, .y = notes.y, .kind = .scroll_down, .button = .none } });
    try app.tick(app.now_ms + 100);
    try t.expect(app.tree.cursor > 0);
}

test "a top-level directory the user folded stays folded when a root is added or the roots re-list — seen once is seen for good" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "extra/lib");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extra/lib/c.txt", .data = "c" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    try app.tree.refresh(&app);
    try t.expect(app.tree.rowOf("extra/lib") != null);
    try app.render();
    app.focus = .tree;
    app.tree.cursor = app.tree.rowOf("extra").?;
    _ = try app.tree.handleKey(&app, Key.char('h'));
    try t.expect(app.tree.rowOf("extra/lib") == null);
    try app.render();
    try app.tick(app.now_ms + 1000);
    try t.expect(app.tree.rowOf("extra/lib") == null);
    try acceptAddWorkspace(&app, "extra/");
    try t.expectEqual(@as(usize, 1), app.tree.roots.items.len);
    try t.expect(app.tree.rowOf("extra/lib") == null);
    try app.render();
    try app.tick(app.now_ms + 2000);
    try app.render();
    try t.expect(app.tree.rowOf("extra/lib") == null);
    try app.tree.refresh(&app);
    try t.expect(app.tree.rowOf("extra/lib") == null);
}

test "multi-root: view.add_workspace prompts, Tab completes a directory segment and cycles, enter adds the root; duplicates and files are refused" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "ws");
    try tmp.dir.createDirPath(t.io, "projects/alpha");
    try tmp.dir.createDirPath(t.io, "projects/alps");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "projects/alpha.txt", .data = "x" });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws });
    defer app.deinit();
    try app.tree.refresh(&app);
    try t.expectEqual(@as(usize, 0), app.tree.roots.items.len);
    try command.run(&app, .{ .static = .@"view.add_workspace" });
    try t.expect(app.overlay == .prompt);
    // Type the parent's path up to `al`, Tab: alpha/ (files are not offered); Tab again: alps/.
    const typed = try std.fmt.allocPrint(t.allocator, "{s}/projects/al", .{root});
    defer t.allocator.free(typed);
    for (typed) |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.tab) });
    const want_alpha = try std.fmt.allocPrint(t.allocator, "{s}/projects/alpha/", .{root});
    defer t.allocator.free(want_alpha);
    try t.expectEqualStrings(want_alpha, app.overlay.prompt.state.buf.items);
    try app.handle(.{ .key = Key.named(.tab) });
    const want_alps = try std.fmt.allocPrint(t.allocator, "{s}/projects/alps/", .{root});
    defer t.allocator.free(want_alps);
    try t.expectEqualStrings(want_alps, app.overlay.prompt.state.buf.items);
    try app.handle(.{ .key = Key.named(.tab) });
    try t.expectEqualStrings(want_alpha, app.overlay.prompt.state.buf.items);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expectEqual(@as(usize, 1), app.tree.roots.items.len);
    try t.expectEqualStrings("alpha", app.tree.roots.items[0].name);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "workspace added: alpha"));
    try t.expectEqual(app_mod.FocusId.tree, app.focus);
    try t.expectEqual(@as(usize, 1), app.tree.cursor); // its header, under `▾ ws`
    // The same folder again, and a file: refused with a reason.
    try acceptAddWorkspace(&app, want_alpha);
    try t.expectEqualStrings("workspace already open", app.lastToast().?);
    const file_path = try std.fmt.allocPrint(t.allocator, "{s}/projects/alpha.txt", .{root});
    defer t.allocator.free(file_path);
    try acceptAddWorkspace(&app, file_path);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "not a directory") != null);
    try t.expectEqual(@as(usize, 1), app.tree.roots.items.len);
    // A workspace-relative path resolves under the workspace.
    try tmp.dir.createDirPath(t.io, "ws/inner");
    try acceptAddWorkspace(&app, "inner");
    try t.expectEqual(@as(usize, 2), app.tree.roots.items.len);
    try t.expect(sdk_testing.pathEndsWith(app.tree.roots.items[1].path, "/ws/inner"));
    // view.switch_workspace lists primary + both roots; picking the second opens it.
    try command.run(&app, .{ .static = .@"view.switch_workspace" });
    try t.expect(app.overlay == .picker);
    try t.expectEqual(@as(usize, 3), app.overlay.picker.labels.len);
    try app.overlay.picker.on_accept.?(&app, 2, "inner");
    try t.expect(app.tree.roots.items[1].expanded);
    try t.expect(!app.tree.roots.items[0].expanded);
    try t.expect(!app.tree.primary_expanded);
}

fn settleTransfers(app: *App) !void {
    const transfers = @import("transfers.zig");
    var i: usize = 0;
    while (transfers.running(app) > 0 and i < 4000) : (i += 1) {
        try app.tick(app.now_ms + 5);
        std.Io.sleep(app.io, .fromMilliseconds(2), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 0), transfers.running(app));
}

test "an Alt-drag confirm copies the file into the folder, the original stays; `~` in a move-to destination is home" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "lib");
    try tmp.dir.createDirPath(t.io, "home/inbox");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "aa.txt", .data = "aa" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bb.txt", .data = "bb" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root });
    defer app.deinit();
    const home = try std.fs.path.join(t.allocator, &.{ root, "home" });
    defer t.allocator.free(home);
    try app.env.put("HOME", home);
    try app.tree.refresh(&app);
    app.focus = .tree;
    const aa = app.tree.rowOf("aa.txt").?;
    const lib = app.tree.rowOf("lib").?;
    try confirmMove(&app, aa, lib, true);
    try t.expect(app.overlay == .confirm);
    try t.expectEqualStrings("Copy to folder", app.overlay.confirm.state.title);
    try t.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "Copy aa.txt into lib/?") != null);
    try t.expect(app.overlay.confirm.purpose.move_path.copy);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try settleTransfers(&app);
    try tmp.dir.access(t.io, "lib/aa.txt", .{});
    try tmp.dir.access(t.io, "aa.txt", .{});
    // A move-to destination under `~` lands in the home directory.
    try acceptRename(&app, "bb.txt", "~/inbox");
    try tmp.dir.access(t.io, "home/inbox/bb.txt", .{});
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "bb.txt", .{}));
    // The move-to prompt is seeded with the row's folder.
    try app.tree.setExpanded("lib", true);
    try app.tree.refresh(&app);
    app.tree.cursor = app.tree.rowOf("lib/aa.txt").?;
    try command.run(&app, .{ .static = .@"file.move_to" });
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("lib/", app.overlay.prompt.state.text());
}

test "view.reveal_in_tree opens the section and every folder above the active file, puts the cursor on its row and the keys in the tree; a scratch, a file outside every root, and a preview each get their answer" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "ws/nest/hollow");
    try tmp.dir.createDirPath(t.io, "extra/lib");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/nest/hollow/file.txt", .data = "deep" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/top.txt", .data = "top" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/notes.md", .data = "# hi" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "outside.txt", .data = "out" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extra/lib/c.txt", .data = "c" });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .cols = 120, .rows = 40 });
    defer app.deinit();
    try app.tree.refresh(&app);
    const deep = try std.fs.path.join(t.allocator, &.{ ws, "nest", "hollow", "file.txt" });
    defer t.allocator.free(deep);
    _ = try app.openPath(deep);
    try command.run(&app, .{ .static = .@"tree.collapse_all" });
    try t.expect(app.tree.rowOf("nest/hollow") == null);
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"view.reveal_in_tree" });
    try t.expect(app.tree.visible);
    try t.expectEqual(app_mod.FocusId.tree, app.focus);
    try t.expect(app.tree.isExpanded("nest"));
    try t.expect(app.tree.isExpanded("nest/hollow"));
    try t.expectEqual(app.tree.rowOf("nest/hollow/file.txt").?, app.tree.cursor);
    // A scratch buffer has no file.
    _ = try app.openScratch();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.reveal_in_tree" }));
    try t.expectEqualStrings("no file to reveal", app.lastToast().?);
    // A file under no root.
    const outside = try std.fs.path.join(t.allocator, &.{ root, "outside.txt" });
    defer t.allocator.free(outside);
    _ = try app.openPath(outside);
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.reveal_in_tree" }));
    try t.expectEqualStrings("outside.txt: not under a workspace root", app.lastToast().?);
    // Under an extra root: the root's section opens and the row is the
    // absolute path.
    const extra = try std.fs.path.join(t.allocator, &.{ root, "extra" });
    defer t.allocator.free(extra);
    _ = try app.tree.addRoot(&app, extra, null);
    const c = try std.fs.path.join(t.allocator, &.{ root, "extra", "lib", "c.txt" });
    defer t.allocator.free(c);
    _ = try app.openPath(c);
    try command.run(&app, .{ .static = .@"view.reveal_in_tree" });
    try t.expect(app.tree.roots.items[0].expanded);
    try t.expectEqual(app.tree.rowOf(c).?, app.tree.cursor);
    // A markdown preview is the file it stands for.
    const md = try std.fs.path.join(t.allocator, &.{ ws, "notes.md" });
    defer t.allocator.free(md);
    _ = try app.openPath(md);
    try t.expect(app.panes.get(app.active.?).?.* == .md_preview);
    try command.run(&app, .{ .static = .@"view.reveal_in_tree" });
    try t.expectEqual(app.tree.rowOf("notes.md").?, app.tree.cursor);
}

test "vim: <leader>e focuses the tree (opening it), <C-n> toggles it and focuses on open; standard Ctrl+B toggles without focus" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    // A narrow screen with the column docked: this test is about
    // what sits beside it, not the width rule (`ui.sidebar_auto_below`).
    app.cfg.ui.sidebar_auto_below = 0;
    _ = try app.openScratch();
    const pane = app.active.?;
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try std.testing.expect(app.tree.visible);
    app.focus = .{ .pane = pane };
    // `<leader>e` on a visible tree: focus, not hide.
    try app.handle(.{ .key = Key.char(' ') });
    try app.handle(.{ .key = Key.char('e') });
    try std.testing.expect(app.tree.visible);
    try std.testing.expect(app.focus == .tree);
    // `j` now moves the tree cursor, not the editor's.
    const before = app.activeEditor().?.buf.editor.cursor;
    try app.handle(.{ .key = Key.char('j') });
    try std.testing.expectEqual(before, app.activeEditor().?.buf.editor.cursor);
    // `<C-n>` toggles: hidden, focus back on the pane; again: shown AND focused.
    try app.handle(.{ .key = Key.ctrl('n') });
    try std.testing.expect(!app.tree.visible);
    try std.testing.expect(app.focus == .pane);
    try app.handle(.{ .key = Key.ctrl('n') });
    try std.testing.expect(app.tree.visible);
    try std.testing.expect(app.focus == .tree);
    // `<leader>e` on a hidden tree opens it and focuses it.
    try app.handle(.{ .key = Key.ctrl('n') });
    try std.testing.expect(!app.tree.visible);
    try app.handle(.{ .key = Key.char(' ') });
    try app.handle(.{ .key = Key.char('e') });
    try std.testing.expect(app.tree.visible);
    try std.testing.expect(app.focus == .tree);
    // Standard: Ctrl+B shows the column and the focus stays in the pane.
    try command.run(&app, .{ .static = .@"editor.use_standard" });
    app.focus = .{ .pane = pane };
    try app.handle(.{ .key = Key.ctrl('b') });
    try std.testing.expect(!app.tree.visible);
    try app.handle(.{ .key = Key.ctrl('b') });
    try std.testing.expect(app.tree.visible);
    try std.testing.expect(app.focus == .pane);
}

test "view.toggle_tree_section folds the primary section to its header and opens it again with the tree focused" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "a" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = buf[0..n] });
    defer app.deinit();
    try app.tree.refresh(&app);
    _ = try app.openScratch();
    try t.expect(app.tree.rowOf("a.txt") != null);
    try command.run(&app, .{ .static = .@"view.toggle_tree_section" });
    try t.expect(!app.tree.primary_expanded);
    try t.expectEqual(@as(usize, 0), app.tree.rows.items.len);
    try t.expect(app.focus == .pane);
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"view.toggle_tree_section" });
    try t.expect(app.tree.primary_expanded);
    try t.expect(app.tree.visible);
    try t.expectEqual(app_mod.FocusId.tree, app.focus);
    try t.expect(app.tree.rowOf("a.txt") != null);
}

test "view.remove_workspace lists the extra roots, the pick drops that one with its folds; with none it says so" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "ws");
    try tmp.dir.createDirPath(t.io, "one/sub");
    try tmp.dir.createDirPath(t.io, "two");
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws });
    defer app.deinit();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.remove_workspace" }));
    try t.expectEqualStrings("no extra workspace to remove", app.lastToast().?);
    const one = try std.fs.path.join(t.allocator, &.{ root, "one" });
    defer t.allocator.free(one);
    const two = try std.fs.path.join(t.allocator, &.{ root, "two" });
    defer t.allocator.free(two);
    _ = try app.tree.addRoot(&app, one, null);
    _ = try app.tree.addRoot(&app, two, null);
    const sub = try std.fs.path.join(t.allocator, &.{ root, "one", "sub" });
    defer t.allocator.free(sub);
    try app.tree.setExpanded(sub, true);
    app.tree.roots.items[0].expanded = true;
    try app.tree.refresh(&app);
    try t.expect(app.tree.rowOf(sub) != null);
    try command.run(&app, .{ .static = .@"view.remove_workspace" });
    try t.expect(app.overlay == .picker);
    try t.expectEqual(@as(usize, 2), app.overlay.picker.labels.len);
    try t.expectEqualStrings("one", app.overlay.picker.labels[0]);
    try app.overlay.picker.on_accept.?(&app, 0, "one");
    try t.expectEqual(@as(usize, 1), app.tree.roots.items.len);
    try t.expectEqualStrings("two", app.tree.roots.items[0].name);
    try t.expect(!app.tree.isExpanded(sub));
    try t.expect(app.tree.rowOf(sub) == null);
    try t.expect(app.tree.cursor < app.tree.rows.items.len);
    try t.expect(std.mem.startsWith(u8, app.lastToast().?, "workspace removed: one"));
}

test "view.open_default_workspace adds and opens the configured folder, switches to it when it is open already, and names the missing key" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = try t.allocator.dupe(u8, buf[0..n]);
    defer t.allocator.free(root);
    try tmp.dir.createDirPath(t.io, "ws");
    try tmp.dir.createDirPath(t.io, "home/proj");
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws });
    defer app.deinit();
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.open_default_workspace" }));
    try t.expectEqualStrings("no default_workspace configured (set `.startup.default_workspace` in config.zon)", app.lastToast().?);
    const proj = try std.fs.path.join(t.allocator, &.{ root, "home", "proj" });
    defer t.allocator.free(proj);
    app.cfg.startup.default_workspace = proj;
    try command.run(&app, .{ .static = .@"view.open_default_workspace" });
    try t.expectEqual(@as(usize, 1), app.tree.roots.items.len);
    try t.expect(app.tree.roots.items[0].expanded);
    try t.expect(!app.tree.primary_expanded);
    try t.expectEqual(app_mod.FocusId.tree, app.focus);
    // Open already: no second root, just the switch.
    app.tree.primary_expanded = true;
    app.tree.roots.items[0].expanded = false;
    try command.run(&app, .{ .static = .@"view.open_default_workspace" });
    try t.expectEqual(@as(usize, 1), app.tree.roots.items.len);
    try t.expect(app.tree.roots.items[0].expanded);
    // The workspace itself: the primary section.
    app.cfg.startup.default_workspace = ws;
    try command.run(&app, .{ .static = .@"view.open_default_workspace" });
    try t.expectEqual(@as(usize, 1), app.tree.roots.items.len);
    try t.expect(app.tree.primary_expanded);
    try t.expect(!app.tree.roots.items[0].expanded);
    // A folder that is not there.
    const missing = try std.fs.path.join(t.allocator, &.{ root, "nope" });
    defer t.allocator.free(missing);
    app.cfg.startup.default_workspace = missing;
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"view.open_default_workspace" }));
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "not a directory") != null);
}

test "view.manage_workspaces opens the home config on its .workspaces line and says where the list lives" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.writeFile(t.io, .{ .sub_path = "config.zon", .data = ".{\n    .ui = .{},\n    .workspaces = .{},\n}\n" });
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"view.manage_workspaces" });
    const e = app.activeEditor().?;
    try t.expect(std.mem.endsWith(u8, e.buf.doc.path.?, "config.zon"));
    try t.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try t.expectEqualStrings("workspaces are the `.workspaces` list in config.zon", app.lastToast().?);
}
