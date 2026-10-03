//! The Files pane — a directory listing as a `Pane`, so a browser is
//! one more thing a split or a tab can hold and two of them side by
//! side are a layout, not a mode. Navigation, three sort orders, the
//! hidden toggle, a `/` filter, a clickable breadcrumb, marks keyed by
//! path, and a preview of the file under the cursor.
//!
//! State lives here (`FilesPane`); the paint is `ui/files_view.zig`;
//! the file verbs act on the pane through `file_clipboard.targetPaths`,
//! which prefers a FOCUSED Files pane over the tree — a browser that is
//! merely open must never retarget the tree's own Ctrl+X.
//!
//! Marks are keyed by absolute path rather than row index: a re-sort, a
//! reload or a hidden-file toggle moves every index, and a mark set
//! that silently re-pointed at different files would be the worst bug
//! a file manager can have. Marks survive navigating away and back, so
//! "gather from several directories, then act" works.

const std = @import("std");
/// The one "does this pane have the keys" (`render.paneFocused`).
const paneFocused = @import("render.zig").paneFocused;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const PaneId = app_mod.PaneId;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const alloc = @import("../core/alloc.zig");
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const text_field = @import("../ui/text_field.zig");
const files_view = @import("../ui/files_view.zig");
const cmd_view = @import("cmd_view.zig");
const cmd_picker = @import("cmd_picker.zig");
const git_app = @import("git.zig");
const trash = @import("trash.zig");
const watch = @import("watch.zig");

pub const Hit = files_view.Hit;

pub const table = .{
    .@"files.open" = &openCmd,
    .@"files.open_split" = &openSplitCmd,
    .@"files.up" = &upCmd,
    .@"files.refresh" = &refreshCmd,
    .@"files.toggle_hidden" = &toggleHiddenCmd,
    .@"files.cycle_sort" = &cycleSortCmd,
    .@"files.sort_name" = &sortNameCmd,
    .@"files.sort_size" = &sortSizeCmd,
    .@"files.sort_modified" = &sortModifiedCmd,
    .@"files.activate" = &activateCmd,
    .@"files.preview" = &previewCmd,
    .@"files.mark_toggle" = &markToggleCmd,
    .@"files.mark_all" = &markAllCmd,
    .@"files.mark_invert" = &markInvertCmd,
    .@"files.mark_clear" = &markClearCmd,
    .@"files.copy_path" = &copyPathCmd,
    .@"files.new_file" = &newFileCmd,
    .@"files.new_folder" = &newFolderCmd,
    .@"files.destinations" = &destinationsCmd,
};

/// A second left press on the selected row within this window opens it.
const double_click_ms: i64 = 500;
/// How much of the cursor file the preview column reads.
const preview_bytes: usize = 4096;

pub const Sort = enum {
    name,
    size,
    modified,

    pub const all = [_]Sort{ .name, .size, .modified };

    pub fn label(s: Sort) []const u8 {
        return switch (s) {
            .name => "Name",
            .size => "Size",
            .modified => "Modified",
        };
    }

    pub fn next(s: Sort) Sort {
        return switch (s) {
            .name => .size,
            .size => .modified,
            .modified => .name,
        };
    }
};

/// One listing row. Slices borrow the pane's snapshot arena.
pub const Entry = struct {
    name: []const u8,
    /// Absolute.
    path: []const u8,
    is_dir: bool,
    is_link: bool = false,
    size: ?u64 = null,
    mtime: ?i64 = null,
};

pub const FilesPane = struct {
    gpa: Allocator,
    /// Absolute. Owned.
    cwd: []u8,
    /// The listing is replaced wholesale on every reload.
    snapshot: alloc.SnapshotArena,
    /// Borrowed from `snapshot`, sorted by `sort`, unfiltered.
    entries: []Entry = &.{},
    /// Indices into `entries` that pass the filter, in display order.
    visible: std.ArrayListUnmanaged(u32) = .empty,
    sort: Sort = .name,
    show_hidden: bool = false,
    filter: text_field.Buf = .empty,
    filter_caret: usize = 0,
    /// The filter's selection (`text_field.clickSelect`), to the caret.
    filter_anchor: ?usize = null,
    filter_focused: bool = false,
    /// Into `visible`.
    cursor: usize = 0,
    scroll: usize = 0,
    /// Marked entries by absolute path. Owned keys.
    marks: std.StringHashMapUnmanaged(void) = .empty,
    /// Where a range (`v`, shift-click) measures from. Owned; null falls
    /// back to the cursor.
    anchor: ?[]u8 = null,
    /// The last read error, shown in the pane. Owned.
    err: ?[]u8 = null,
    /// The pane a preview last opened into.
    preview_pane: ?PaneId = null,
    /// The head of the cursor file and which file it is. Owned.
    preview_text: ?[]u8 = null,
    preview_for: ?[]u8 = null,
    /// vim's two-key `yy` / `dd`: the first key, until the next key.
    pending: ?u8 = null,
    last_click: ?struct { idx: usize, at_ms: i64 } = null,
    loaded: bool = false,
    /// The workspace trash: the title says so and delete is permanent.
    in_trash: bool = false,
    /// `cwd` as it was when the listing was read (`watch.check`
    /// re-reads when the directory's mtime moves — an entry added,
    /// removed or renamed by another tool).
    dir_stamp: ?watch.DiskStamp = null,

    pub fn init(gpa: Allocator, dir: []const u8) Allocator.Error!FilesPane {
        return .{
            .gpa = gpa,
            .cwd = try gpa.dupe(u8, dir),
            .snapshot = alloc.SnapshotArena.init(gpa),
        };
    }

    pub fn deinit(self: *FilesPane) void {
        const gpa = self.gpa;
        var it = self.marks.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.marks.deinit(gpa);
        if (self.anchor) |a| gpa.free(a);
        if (self.err) |e| gpa.free(e);
        if (self.preview_text) |p| gpa.free(p);
        if (self.preview_for) |p| gpa.free(p);
        self.filter.deinit(gpa);
        self.visible.deinit(gpa);
        self.snapshot.deinit();
        gpa.free(self.cwd);
    }

    /// The tab label: the directory's name, `Trash` for the trash, the
    /// whole path for a root.
    pub fn title(self: *const FilesPane) []const u8 {
        if (self.in_trash) return "Trash";
        const base = std.fs.path.basename(self.cwd);
        return if (base.len == 0) self.cwd else base;
    }

    /// Re-read `cwd`. Keeps the cursor on the same NAME where possible so
    /// a reload after an external change does not teleport the selection.
    pub fn reload(self: *FilesPane, io: Io) Allocator.Error!void {
        const gpa = self.gpa;
        const keep: ?[]u8 = if (self.selected()) |e| try gpa.dupe(u8, e.name) else null;
        defer if (keep) |k| gpa.free(k);
        self.loaded = true;
        if (self.err) |e| gpa.free(e);
        self.err = null;
        self.snapshot.reset();
        self.entries = &.{};
        const arena = self.snapshot.allocator();
        var out: std.ArrayListUnmanaged(Entry) = .empty;
        self.dir_stamp = watch.stamp(io, self.cwd);
        var dir = Io.Dir.cwd().openDir(io, self.cwd, .{ .iterate = true }) catch |err| {
            self.err = try gpa.dupe(u8, @errorName(err));
            self.visible.clearRetainingCapacity();
            self.cursor = 0;
            return;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |ent| {
            if (!self.show_hidden and ent.name.len > 0 and ent.name[0] == '.') continue;
            const name = try arena.dupe(u8, ent.name);
            const path = try std.fs.path.join(arena, &.{ self.cwd, ent.name });
            var e: Entry = .{ .name = name, .path = path, .is_dir = ent.kind == .directory, .is_link = ent.kind == .sym_link };
            // Follow a link for its kind and size so a linked directory is
            // still enterable; a dangling one stays listed as a link.
            if (dir.statFile(io, ent.name, .{})) |st| {
                e.is_dir = st.kind == .directory;
                e.size = if (e.is_dir) null else st.size;
                e.mtime = st.mtime.toSeconds();
            } else |_| {}
            try out.append(arena, e);
        }
        self.entries = out.items;
        self.sortEntries();
        try self.applyFilter();
        // Marks an operation consumed point at paths that have moved.
        try self.dropDeadMarks(io);
        if (keep) |name| {
            for (self.visible.items, 0..) |idx, i| if (std.mem.eql(u8, self.entries[idx].name, name)) {
                self.cursor = i;
                break;
            };
        }
        self.clamp();
    }

    fn dropDeadMarks(self: *FilesPane, io: Io) Allocator.Error!void {
        var dead: std.ArrayListUnmanaged([]const u8) = .empty;
        defer dead.deinit(self.gpa);
        var it = self.marks.keyIterator();
        while (it.next()) |k| {
            Io.Dir.cwd().access(io, k.*, .{}) catch try dead.append(self.gpa, k.*);
        }
        for (dead.items) |k| if (self.marks.fetchRemove(k)) |kv| self.gpa.free(kv.key);
    }

    fn lessName(a: []const u8, b: []const u8) bool {
        const n = @min(a.len, b.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ca = std.ascii.toLower(a[i]);
            const cb = std.ascii.toLower(b[i]);
            if (ca != cb) return ca < cb;
        }
        return a.len < b.len;
    }

    /// Directories first in every mode; then name (case-insensitive),
    /// largest first, or newest first — name breaking the ties.
    fn sortEntries(self: *FilesPane) void {
        const Ctx = struct {
            sort: Sort,
            fn lt(ctx: @This(), a: Entry, b: Entry) bool {
                if (a.is_dir != b.is_dir) return a.is_dir;
                switch (ctx.sort) {
                    .name => {},
                    .size => {
                        const sa = a.size orelse 0;
                        const sb = b.size orelse 0;
                        if (sa != sb) return sa > sb;
                    },
                    .modified => {
                        const ma = a.mtime orelse 0;
                        const mb = b.mtime orelse 0;
                        if (ma != mb) return ma > mb;
                    },
                }
                return lessName(a.name, b.name);
            }
        };
        std.mem.sort(Entry, self.entries, Ctx{ .sort = self.sort }, Ctx.lt);
    }

    /// The filter is a case-insensitive substring over the name.
    pub fn applyFilter(self: *FilesPane) Allocator.Error!void {
        self.visible.clearRetainingCapacity();
        const q = self.filter.items;
        for (self.entries, 0..) |e, i| {
            if (q.len > 0 and !containsIgnoreCase(e.name, q)) continue;
            try self.visible.append(self.gpa, @intCast(i));
        }
        self.clamp();
    }

    fn clamp(self: *FilesPane) void {
        if (self.visible.items.len == 0) {
            self.cursor = 0;
            self.scroll = 0;
            return;
        }
        self.cursor = @min(self.cursor, self.visible.items.len - 1);
    }

    /// Re-sort keeping the cursor on the same entry.
    pub fn setSort(self: *FilesPane, sort: Sort) Allocator.Error!void {
        const gpa = self.gpa;
        const keep: ?[]u8 = if (self.selected()) |e| try gpa.dupe(u8, e.name) else null;
        defer if (keep) |k| gpa.free(k);
        self.sort = sort;
        self.sortEntries();
        try self.applyFilter();
        if (keep) |name| {
            for (self.visible.items, 0..) |idx, i| if (std.mem.eql(u8, self.entries[idx].name, name)) {
                self.cursor = i;
                break;
            };
        }
    }

    pub fn count(self: *const FilesPane) usize {
        return self.visible.items.len;
    }

    /// The entry at display row `i`.
    pub fn entryAt(self: *const FilesPane, i: usize) ?Entry {
        if (i >= self.visible.items.len) return null;
        return self.entries[self.visible.items[i]];
    }

    pub fn selected(self: *const FilesPane) ?Entry {
        return self.entryAt(self.cursor);
    }

    pub fn rowOfPath(self: *const FilesPane, path: []const u8) ?usize {
        for (self.visible.items, 0..) |idx, i| if (std.mem.eql(u8, self.entries[idx].path, path)) return i;
        return null;
    }

    /// Change directory. Marks survive (that is what makes them useful);
    /// the filter is dropped, since it described the old listing.
    pub fn navigate(self: *FilesPane, io: Io, dir: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, dir);
        self.gpa.free(self.cwd);
        self.cwd = copy;
        self.filter.clearRetainingCapacity();
        self.filter_caret = 0;
        self.filter_anchor = null;
        self.filter_focused = false;
        self.cursor = 0;
        self.scroll = 0;
        try self.reload(io);
    }

    /// The parent directory, with the cursor on the directory just left.
    /// The trash is a root of its own: `↑` from it goes nowhere — the
    /// directory above it is the data root's trash of every workspace.
    pub fn up(self: *FilesPane, io: Io) Allocator.Error!void {
        if (self.in_trash) return;
        const parent = std.fs.path.dirname(self.cwd) orelse return;
        if (parent.len == 0) return;
        const was = try self.gpa.dupe(u8, self.cwd);
        defer self.gpa.free(was);
        try self.navigate(io, parent);
        if (self.rowOfPath(was)) |i| self.cursor = i;
    }

    pub fn moveBy(self: *FilesPane, delta: i64) void {
        const n = self.visible.items.len;
        if (n == 0) return;
        const cur: i64 = @intCast(self.cursor);
        self.cursor = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(n - 1))));
    }

    // ── marks (keyed by path) ──

    pub fn isMarked(self: *const FilesPane, path: []const u8) bool {
        return self.marks.contains(path);
    }

    /// The one definition of "toggle": the keyboard, ctrl-click and the
    /// menu all land here, and re-anchor a later range at this path.
    pub fn toggleMarkPath(self: *FilesPane, path: []const u8) Allocator.Error!void {
        try self.setAnchor(path);
        if (self.marks.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
            return;
        }
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        try self.marks.put(self.gpa, key, {});
    }

    fn setAnchor(self: *FilesPane, path: []const u8) Allocator.Error!void {
        const copy = try self.gpa.dupe(u8, path);
        if (self.anchor) |a| self.gpa.free(a);
        self.anchor = copy;
    }

    /// Toggle the cursor row's mark, then advance — one keypress per file.
    pub fn toggleMark(self: *FilesPane) Allocator.Error!void {
        const e = self.selected() orelse return;
        try self.toggleMarkPath(e.path);
        self.moveBy(1);
    }

    /// Mark every row between the anchor and `idx` (inclusive).
    pub fn markRange(self: *FilesPane, idx: usize) Allocator.Error!void {
        if (idx >= self.visible.items.len) return;
        var from = self.cursor;
        if (self.anchor) |a| if (self.rowOfPath(a)) |i| {
            from = i;
        };
        const lo = @min(from, idx);
        const hi = @max(from, idx);
        var i = lo;
        while (i <= hi) : (i += 1) {
            const e = self.entryAt(i) orelse continue;
            if (self.marks.contains(e.path)) continue;
            const key = try self.gpa.dupe(u8, e.path);
            errdefer self.gpa.free(key);
            try self.marks.put(self.gpa, key, {});
        }
        self.cursor = idx;
    }

    /// Every VISIBLE row — a filtered-out file must not be swept in.
    pub fn markAll(self: *FilesPane) Allocator.Error!void {
        for (self.visible.items) |idx| {
            const e = self.entries[idx];
            if (self.marks.contains(e.path)) continue;
            const key = try self.gpa.dupe(u8, e.path);
            errdefer self.gpa.free(key);
            try self.marks.put(self.gpa, key, {});
        }
    }

    pub fn invertMarks(self: *FilesPane) Allocator.Error!void {
        for (self.visible.items) |idx| {
            const e = self.entries[idx];
            if (self.marks.fetchRemove(e.path)) |kv| {
                self.gpa.free(kv.key);
            } else {
                const key = try self.gpa.dupe(u8, e.path);
                errdefer self.gpa.free(key);
                try self.marks.put(self.gpa, key, {});
            }
        }
    }

    pub fn clearMarks(self: *FilesPane) void {
        var it = self.marks.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.marks.clearRetainingCapacity();
    }

    /// Marks in the listing (visible ones first, in display order, then
    /// the ones gathered elsewhere), or the cursor row. Marks win over
    /// the cursor: a user who marked ten files and moved the cursor
    /// must not delete one and wonder where the other nine went.
    pub fn actionPaths(self: *const FilesPane, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        if (self.marks.count() > 0) {
            for (self.visible.items) |idx| {
                const e = self.entries[idx];
                if (self.marks.contains(e.path)) try out.append(arena, try arena.dupe(u8, e.path));
            }
            var it = self.marks.keyIterator();
            while (it.next()) |k| {
                if (self.rowOfPath(k.*) != null) continue;
                try out.append(arena, try arena.dupe(u8, k.*));
            }
            return out.items;
        }
        if (self.selected()) |e| try out.append(arena, try arena.dupe(u8, e.path));
        return out.items;
    }

    /// The head of the cursor file for the preview column, re-read when
    /// the cursor lands on another file. Binary files show nothing.
    fn refreshPreview(self: *FilesPane, io: Io) Allocator.Error!void {
        const gpa = self.gpa;
        const e = self.selected() orelse return self.dropPreview();
        if (e.is_dir) return self.dropPreview();
        if (self.preview_for) |p| if (std.mem.eql(u8, p, e.path)) return;
        self.dropPreview();
        self.preview_for = try gpa.dupe(u8, e.path);
        const text = Io.Dir.cwd().readFileAlloc(io, e.path, gpa, .limited(preview_bytes)) catch return;
        if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) {
            gpa.free(text);
            return;
        }
        self.preview_text = text;
    }

    fn dropPreview(self: *FilesPane) void {
        if (self.preview_text) |p| self.gpa.free(p);
        if (self.preview_for) |p| self.gpa.free(p);
        self.preview_text = null;
        self.preview_for = null;
    }
};

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ─── the app side ───────────────────────────────────────────────────────

pub const Focused = struct { id: PaneId, pane: *FilesPane };

/// The Files pane that owns the keyboard, if the active pane is one and
/// the focus is on it — never a browser that is merely open.
pub fn focused(app: *App) ?Focused {
    if (app.focus != .pane) return null;
    const id = app.active orelse return null;
    const p = app.panes.get(id) orelse return null;
    return switch (p.*) {
        .files => |*f| .{ .id = id, .pane = f },
        else => null,
    };
}

fn require(app: *App) CommandError!Focused {
    return focused(app) orelse app.diag.fail(app.frame.allocator(), "no Files pane has focus", .{});
}

/// Open a Files pane at `dir` (absolute), shown and focused.
pub fn open(app: *App, dir: []const u8) Allocator.Error!PaneId {
    var pane = try FilesPane.init(app.gpa, dir);
    errdefer pane.deinit();
    pane.in_trash = trash.isTrashDir(app, dir);
    try pane.reload(app.io);
    const id = try app.panes.add(.{ .files = pane });
    app.showPane(id);
    return id;
}

/// Re-read every Files pane — a move changes two directories, so all of
/// them reload rather than the one that happened to be touched.
pub fn reloadAll(app: *App) Allocator.Error!void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .files => |*f| try f.reload(app.io),
        else => {},
    };
    app.needs_render = true;
}

/// The one place a filesystem change announces itself: the tree and
/// every Files pane re-read.
pub fn refreshAfterFsChange(app: *App) Allocator.Error!void {
    try app.tree.refresh(app);
    try reloadAll(app);
}

/// Enter the selected directory, or open the selected file — one
/// gesture (`Enter` / `l` / double-click), the way every file manager
/// has it.
pub fn activate(app: *App, id: PaneId, f: *FilesPane) Allocator.Error!void {
    const e = f.selected() orelse return;
    if (e.is_dir) {
        const dir = try app.frame.allocator().dupe(u8, e.path);
        try f.navigate(app.io, dir);
        app.needs_render = true;
        return;
    }
    const path = try app.frame.allocator().dupe(u8, e.path);
    _ = id;
    _ = app.openPath(path) catch |err| app.toast("open {s}: {s}", .{ app.relPath(path), @errorName(err) });
}

/// Preview the cursor file WITHOUT leaving the pane: it opens in a leaf
/// of its own (reused on the next `p`, so glancing down a listing does
/// not stack tabs) and focus comes straight back to the browser.
pub fn preview(app: *App, id: PaneId, f: *FilesPane) CommandError!void {
    const arena = app.frame.allocator();
    const e = f.selected() orelse return app.diag.fail(arena, "nothing selected", .{});
    if (e.is_dir) return app.diag.fail(arena, "{s} is a folder — Enter descends", .{e.name});
    const path = try arena.dupe(u8, e.path);
    const layout = app.layouts.current();
    const my_leaf = layout.leafOf(id);
    const prev: ?PaneId = if (f.preview_pane) |pp| (if (app.panes.get(pp) != null and layout.leafOf(pp) != null and layout.leafOf(pp).? != my_leaf.?) pp else null) else null;
    var opened: PaneId = undefined;
    if (prev) |pp| {
        // Land in the preview's leaf, then retire the old preview.
        app.setActive(pp);
        opened = app.openPath(path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                app.setActive(id);
                return app.diag.fail(arena, "open {s}: {s}", .{ app.relPath(path), @errorName(err) });
            },
        };
        if (opened != pp) {
            const old = app.panes.get(pp);
            if (old != null and !old.?.dirty()) try app.forceClosePane(pp);
        }
    } else {
        const before = app.panes.findPath(path);
        opened = app.openPath(path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return app.diag.fail(arena, "open {s}: {s}", .{ app.relPath(path), @errorName(err) }),
        };
        // A file that was not open landed as a tab beside the browser:
        // give it a leaf of its own.
        if (before == null and layout.leafOf(opened) != null and layout.leafOf(opened).? == my_leaf.?) {
            app.setActive(id);
            try cmd_view.splitWith(app, .horizontal, opened);
        }
    }
    // `p` is the same gesture as a tree click — "show me this, I am
    // still browsing" — so the tab it leaves is a preview, italic like
    // the tree's. The leaf it lands in is this pane's own bookkeeping
    // above, not `leafPreview`'s.
    if (app.panes.get(opened)) |p| if (app.previewTabs()) p.setPreview(true);
    // `f` points into `panes.slots`, which `openPath` may have grown:
    // re-fetch the pane rather than write through a stale pointer.
    if (app.panes.get(id)) |p| if (p.asFiles()) |ff| {
        ff.preview_pane = opened;
    };
    app.showPane(id);
}

/// Every Files pane forgets a preview pane that closed.
pub fn onPaneClosed(app: *App, closed: PaneId) void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .files => |*f| if (f.preview_pane == closed) {
            f.preview_pane = null;
        },
        else => {},
    };
}

// ─── commands ───────────────────────────────────────────────────────────

fn openCmd(app: *App) CommandError!void {
    const dir = try app.frame.allocator().dupe(u8, app.workspace);
    _ = try open(app, dir);
}

/// Two browsers side by side — the commander layout. The focused
/// browser is the left side when there is one (a fresh one otherwise);
/// the second pane IS the new side, so exactly one pane is added.
fn openSplitCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const dir = try arena.dupe(u8, if (focused(app)) |fp| fp.pane.cwd else app.workspace);
    const left = if (focused(app)) |fp| fp.id else try open(app, dir);
    var second = try FilesPane.init(app.gpa, dir);
    errdefer second.deinit();
    second.in_trash = trash.isTrashDir(app, dir);
    try second.reload(app.io);
    const right = try app.panes.add(.{ .files = second });
    app.setActive(left);
    try cmd_view.splitWith(app, .horizontal, right);
}

fn upCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try fp.pane.up(app.io);
    fp.pane.in_trash = trash.isTrashDir(app, fp.pane.cwd);
    app.needs_render = true;
}

fn refreshCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try fp.pane.reload(app.io);
    app.needs_render = true;
}

fn toggleHiddenCmd(app: *App) CommandError!void {
    const fp = try require(app);
    fp.pane.show_hidden = !fp.pane.show_hidden;
    try fp.pane.reload(app.io);
    app.toast("hidden files {s}", .{if (fp.pane.show_hidden) "shown" else "hidden"});
}

fn cycleSortCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try fp.pane.setSort(fp.pane.sort.next());
    app.toast("sort: {s}", .{fp.pane.sort.label()});
}

fn sortNameCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try fp.pane.setSort(.name);
    app.needs_render = true;
}

fn sortSizeCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try fp.pane.setSort(.size);
    app.needs_render = true;
}

fn sortModifiedCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try fp.pane.setSort(.modified);
    app.needs_render = true;
}

fn activateCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try activate(app, fp.id, fp.pane);
}

fn previewCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try preview(app, fp.id, fp.pane);
}

fn markToggleCmd(app: *App) CommandError!void {
    const fp = try require(app);
    const e = fp.pane.selected() orelse return app.diag.fail(app.frame.allocator(), "nothing selected", .{});
    try fp.pane.toggleMarkPath(e.path);
    app.needs_render = true;
}

fn markAllCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try fp.pane.markAll();
    app.toast("{d} marked", .{fp.pane.marks.count()});
}

fn markInvertCmd(app: *App) CommandError!void {
    const fp = try require(app);
    try fp.pane.invertMarks();
    app.toast("{d} marked", .{fp.pane.marks.count()});
}

fn markClearCmd(app: *App) CommandError!void {
    const fp = try require(app);
    fp.pane.clearMarks();
    app.needs_render = true;
}

fn copyPathCmd(app: *App) CommandError!void {
    const fp = try require(app);
    const e = fp.pane.selected() orelse return app.diag.fail(app.frame.allocator(), "nothing selected", .{});
    const rel = app.relPath(e.path);
    try app.clipboard.copy(rel);
    app.toast("copied {s}", .{rel});
}

/// `New file…` in the pane's directory; the prompt takes a name.
pub fn newFileCmd(app: *App) CommandError!void {
    const fp = try require(app);
    const dir = try app.gpa.dupe(u8, fp.pane.cwd);
    errdefer app.gpa.free(dir);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "New file (name, or a path)"), .purpose = .{ .new_file = dir } } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn newFolderCmd(app: *App) CommandError!void {
    const fp = try require(app);
    const dir = try app.gpa.dupe(u8, fp.pane.cwd);
    errdefer app.gpa.free(dir);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "New folder (name, or a path)"), .purpose = .{ .new_folder = dir } } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `Rename…` on the cursor row (the tree's runner defers here).
pub fn renameCmd(app: *App) CommandError!void {
    const fp = try require(app);
    const e = fp.pane.selected() orelse return app.diag.fail(app.frame.allocator(), "nothing selected", .{});
    const from = try app.gpa.dupe(u8, e.path);
    errdefer app.gpa.free(from);
    app.overlay.deinit(app.gpa);
    var state = app_mod.Prompt.init(app.gpa, "Rename to");
    try state.setText(app.gpa, e.name);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .rename = from } } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `Move to…`: a folder for every marked path (or the cursor row). The
/// move itself is a background transfer, so ten marked trees behave
/// like one file.
pub fn moveToCmd(app: *App) CommandError!void {
    const fp = try require(app);
    const arena = app.frame.allocator();
    const paths = try fp.pane.actionPaths(arena);
    if (paths.len == 0) return app.diag.fail(arena, "nothing selected", .{});
    const gpa = app.gpa;
    const owned = try gpa.alloc([]u8, paths.len);
    var n: usize = 0;
    errdefer {
        for (owned[0..n]) |q| gpa.free(q);
        gpa.free(owned);
    }
    for (paths) |q| {
        owned[n] = try gpa.dupe(u8, q);
        n += 1;
    }
    const title = if (paths.len == 1)
        try std.fmt.allocPrint(gpa, "Move {s} to folder", .{std.fs.path.basename(paths[0])})
    else
        try std.fmt.allocPrint(gpa, "Move {d} items to folder", .{paths.len});
    errdefer gpa.free(title);
    app.overlay.deinit(gpa);
    var state = app_mod.Prompt.init(gpa, title);
    // Prefilled with this directory as a prefix to type after (empty at
    // the workspace root, whose relPath is the absolute path itself).
    if (!std.mem.eql(u8, fp.pane.cwd, app.workspace)) {
        try state.setText(gpa, try std.fmt.allocPrint(arena, "{s}/", .{app.relPath(fp.pane.cwd)}));
    }
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .move_paths = owned }, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The folder typed into the `Move to…` prompt: absolute, or
/// workspace-relative. It must exist; a path already taken at the
/// destination is skipped with a toast, a path already there is a no-op.
pub fn acceptMoveTo(app: *App, paths: []const []const u8, text: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const typed = try app.expandTilde(std.mem.trim(u8, text, " \t"));
    const dir = try arena.dupe(u8, std.mem.trimEnd(u8, try app.absPath(if (typed.len == 0) "" else typed), "/"));
    const dir_ok = if (Io.Dir.cwd().statFile(app.io, if (dir.len == 0) "/" else dir, .{})) |st| st.kind == .directory else |_| false;
    if (!dir_ok) {
        app.toast("not a folder: {s}", .{app.relPath(dir)});
        return;
    }
    const transfers = @import("transfers.zig");
    var items: std.ArrayListUnmanaged(transfers.Item) = .empty;
    for (paths) |src| {
        const name = std.fs.path.basename(src);
        if (name.len == 0) continue;
        const dst = try std.fs.path.join(arena, &.{ dir, name });
        if (std.mem.eql(u8, dst, src)) continue;
        if (std.mem.startsWith(u8, dst, src) and dst.len > src.len and std.fs.path.isSep(dst[src.len])) {
            app.toast("cannot move {s} into itself", .{name});
            continue;
        }
        if (Io.Dir.cwd().access(app.io, dst, .{})) {
            app.toast("already exists: {s}", .{app.relPath(dst)});
            continue;
        } else |_| {}
        try items.append(arena, .{ .src = try arena.dupe(u8, src), .dst = dst });
    }
    if (items.items.len == 0) {
        app.toast("nothing to move", .{});
        return;
    }
    if (transfers.clash(app, items.items)) |busy| {
        app.toast("already writing {s} — wait for it to finish", .{app.relPath(busy)});
        return;
    }
    _ = transfers.start(app, .move, items.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m});
            app.diag.clear();
            return;
        },
    };
    app.toast("moving {d} item{s} into {s}", .{ items.items.len, if (items.items.len == 1) "" else "s", app.relPath(dir) });
}

/// The breadcrumb's picker: Home, the workspace, the usual folders,
/// the trash, the root and every other browser's directory.
fn destinationsCmd(app: *App) CommandError!void {
    _ = try require(app);
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    const arena = app.frame.allocator();
    try addDestination(app, &labels, &details, app.workspace, "workspace");
    if (app.userHome()) |home| {
        try addDestination(app, &labels, &details, home, "home");
        for ([_][]const u8{ "Downloads", "Desktop", "Documents", "Projects" }) |sub| {
            try addDestination(app, &labels, &details, try std.fs.path.join(arena, &.{ home, sub }), sub);
        }
    }
    try addDestination(app, &labels, &details, try trash.dir(app, arena), "trash");
    try addDestination(app, &labels, &details, "/", "root");
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .files => |*f| try addDestination(app, &labels, &details, f.cwd, "open browser"),
        else => {},
    };
    try cmd_picker.openPickerWith(app, "Go to", .custom, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
    app.overlay.picker.on_accept = &acceptDestination;
}

fn addDestination(app: *App, labels: *std.ArrayListUnmanaged([]u8), details: *std.ArrayListUnmanaged([]u8), path: []const u8, what: []const u8) Allocator.Error!void {
    if (Io.Dir.cwd().statFile(app.io, path, .{})) |st| {
        if (st.kind != .directory) return;
    } else |_| return;
    for (labels.items) |l| if (std.mem.eql(u8, l, path)) return;
    try labels.append(app.gpa, try app.gpa.dupe(u8, path));
    errdefer app.gpa.free(labels.pop().?);
    try details.append(app.gpa, try app.gpa.dupe(u8, what));
}

fn acceptDestination(app: *App, idx: usize, label: []const u8) Allocator.Error!void {
    _ = idx;
    const fp = focused(app) orelse return;
    try fp.pane.navigate(app.io, label);
    fp.pane.in_trash = trash.isTrashDir(app, label);
    app.needs_render = true;
}

// ─── keys ───────────────────────────────────────────────────────────────

/// The keys the pane answers. Returns false for a key the chord chain
/// should see (`delete` → `file.delete`, `f2` → `file.rename`, …).
pub fn handleKey(app: *App, id: PaneId, f: *FilesPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    if (f.filter_focused) return filterKey(app, f, k);
    const n = f.count();
    const page = @max(app.pane_rows, 1);
    const standard = app.input_style == .standard;
    // vim's two-key clipboard verbs: a stray press must not move files.
    const pending = f.pending;
    f.pending = null;
    if (k.mods.ctrl and !k.mods.alt and !k.mods.super and k.code == .char) {
        switch (k.code.char) {
            'd' => {
                if (standard) runCmd(app, .@"file.duplicate") else f.moveBy(@intCast(page / 2));
                return true;
            },
            'u' => {
                f.moveBy(-@as(i64, @intCast(page / 2)));
                return true;
            },
            'x', 'c', 'v' => {
                if (!standard) return false;
                const id_: command.CommandId = switch (k.code.char) {
                    'x' => .@"file.cut",
                    'c' => .@"file.copy",
                    else => .@"file.paste",
                };
                runCmd(app, id_);
                return true;
            },
            else => return false,
        }
    }
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    switch (k.code) {
        .down => f.moveBy(1),
        .up => f.moveBy(-1),
        .home => f.cursor = 0,
        .end => f.cursor = n -| 1,
        .page_down => f.moveBy(@intCast(page)),
        .page_up => f.moveBy(-@as(i64, @intCast(page))),
        .enter, .right => try activate(app, id, f),
        .left, .backspace => try f.up(app.io),
        .esc => {
            if (f.filter.items.len > 0) {
                f.filter.clearRetainingCapacity();
                f.filter_caret = 0;
                f.filter_anchor = null;
                try f.applyFilter();
            } else if (f.marks.count() > 0) {
                f.clearMarks();
            } else return false;
        },
        .char => |c| switch (c) {
            'j' => f.moveBy(1),
            'k' => f.moveBy(-1),
            'g' => f.cursor = 0,
            'G' => f.cursor = n -| 1,
            'l' => try activate(app, id, f),
            'h' => try f.up(app.io),
            ' ' => try f.toggleMark(),
            'a' => try f.markAll(),
            'v' => try f.markRange(f.cursor),
            '*' => try f.invertMarks(),
            '/' => f.filter_focused = true,
            'r' => try f.reload(app.io),
            's' => runToast(app, cycleSortCmd(app)),
            '.', 'H' => runToast(app, toggleHiddenCmd(app)),
            'p' => runToast(app, preview(app, id, f)),
            'b' => runToast(app, destinationsCmd(app)),
            'q' => try app.closePane(id, true),
            'D' => runCmd(app, .@"file.duplicate"),
            'y', 'd' => {
                if (standard) return false;
                if (pending != null and pending.? == c) {
                    runCmd(app, if (c == 'y') .@"file.copy" else .@"file.cut");
                } else {
                    f.pending = @intCast(c);
                    app.toast("{c} — press again to {s}", .{ @as(u8, @intCast(c)), if (c == 'y') "copy" else "cut" });
                }
            },
            'P' => {
                if (standard) return false;
                runCmd(app, .@"file.paste");
            },
            else => return false,
        },
        else => return false,
    }
    return true;
}

/// Type-to-narrow beats every navigation key while the filter has focus.
fn filterKey(app: *App, f: *FilesPane, k: Key) Allocator.Error!bool {
    switch (k.code) {
        .esc => {
            if (f.filter.items.len > 0) {
                f.filter.clearRetainingCapacity();
                f.filter_caret = 0;
                f.filter_anchor = null;
                try f.applyFilter();
            } else f.filter_focused = false;
            return true;
        },
        .enter => {
            f.filter_focused = false;
            return true;
        },
        .up => {
            f.moveBy(-1);
            return true;
        },
        .down => {
            f.moveBy(1);
            return true;
        },
        else => {},
    }
    switch (try text_field.editKey(&f.filter, &f.filter_caret, &f.filter_anchor, app.gpa, k)) {
        .ignored => return false,
        .moved => return true,
        .changed => {
            f.cursor = 0;
            try f.applyFilter();
            return true;
        },
    }
}

/// A command reached from a key: `command.run` toasts the reason itself.
fn runCmd(app: *App, id: command.CommandId) void {
    command.run(app, .{ .static = id }) catch {};
}

/// A command reached outside `command.run`: toast its reason the same way.
fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("files: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

// ─── mouse ──────────────────────────────────────────────────────────────

/// A press on one of the pane's targets (`dispatch.zig` routes
/// `.script_hit` here). Ctrl-click toggles a mark, shift-click extends
/// a range, a second click on the row opens it, a right click opens
/// the row's menu — which acts on the marks when there are any.
pub fn click(app: *App, id: PaneId, f: *FilesPane, hit_id: u32, m: Mouse) Allocator.Error!void {
    app.needs_render = true;
    switch (Hit.decode(hit_id)) {
        .row => |i| {
            if (i >= f.count()) return;
            f.filter_focused = false;
            if (m.button == .right) {
                if (!f.isMarked(f.entryAt(i).?.path)) f.cursor = i;
                return openRowMenu(app, f, m.x, m.y);
            }
            if (m.button != .left) return;
            if (m.mods.ctrl or m.mods.super) {
                f.cursor = i;
                return f.toggleMarkPath(f.entryAt(i).?.path);
            }
            if (m.mods.shift) return f.markRange(i);
            const again = if (f.last_click) |lc| lc.idx == i and app.now_ms - lc.at_ms <= double_click_ms else false;
            f.last_click = .{ .idx = i, .at_ms = app.now_ms };
            f.cursor = i;
            if (f.entryAt(i)) |e| try f.setAnchor(e.path);
            if (again) {
                f.last_click = null;
                try activate(app, id, f);
            }
        },
        .kebab => |i| {
            if (i >= f.count()) return;
            f.cursor = i;
            try openRowMenu(app, f, m.x, m.y);
        },
        .crumb => |i| {
            const arena = app.frame.allocator();
            const cs = try crumbs(app, f, arena);
            if (i >= cs.paths.len) return;
            const dir = cs.paths[i];
            try f.navigate(app.io, dir);
            f.in_trash = trash.isTrashDir(app, dir);
        },
        .chip => |c| switch (c) {
            .sort => if (m.button == .right) try openSortMenu(app, f, m.x, m.y) else runToast(app, cycleSortCmd(app)),
            .hidden => runToast(app, toggleHiddenCmd(app)),
            .refresh => try f.reload(app.io),
            .up => {
                try f.up(app.io);
                f.in_trash = trash.isTrashDir(app, f.cwd);
            },
        },
        .body => if (m.button == .right) try openDirMenu(app, f, m.x, m.y),
        .filter => f.filter_focused = true,
        .column => |col| try f.setSort(switch (col) {
            .name, .kind => .name,
            .size => .size,
            .modified => .modified,
        }),
    }
}

pub fn scrollBy(f: *FilesPane, delta: i64) void {
    f.moveBy(delta);
}

fn openRowMenu(app: *App, f: *FilesPane, x: u16, y: u16) Allocator.Error!void {
    const e = f.selected() orelse return;
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    const marked = f.marks.count();
    if (f.in_trash) {
        try rows.append(app.gpa, .{ .label = "Restore", .action = .{ .command = .@"files.restore_from_trash" } });
    }
    try rows.appendSlice(app.gpa, &.{
        .{ .label = if (e.is_dir) "Enter" else "Open", .action = .{ .command = .@"files.activate" } },
        .{ .label = "Preview", .action = .{ .command = .@"files.preview" } },
        .{ .label = if (f.isMarked(e.path)) "Unmark" else "Mark", .action = .{ .command = .@"files.mark_toggle" }, .separator_before = true },
        .{ .label = "Cut", .action = .{ .command = .@"file.cut" }, .separator_before = true },
        .{ .label = "Copy", .action = .{ .command = .@"file.copy" } },
        .{ .label = "Paste here", .action = .{ .command = .@"file.paste" } },
        .{ .label = "Duplicate", .action = .{ .command = .@"file.duplicate" } },
        .{ .label = "Rename…", .action = .{ .command = .@"file.rename" }, .separator_before = true },
        .{ .label = "Move to…", .action = .{ .command = .@"file.move_to" } },
        .{ .label = if (f.in_trash) "Delete permanently…" else "Delete…", .action = .{ .command = .@"file.delete" } },
        .{ .label = "Copy path", .action = .{ .command = .@"files.copy_path" }, .separator_before = true },
        .{ .label = "Refresh", .action = .{ .command = .@"files.refresh" } },
    });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    // Literal titles: a reload while the menu is up would drop `e.name`.
    const title: []const u8 = if (marked > 1) "Marked" else if (e.is_dir) "Folder" else "File";
    try app.openMenu(title, owned, x, y);
}

fn openDirMenu(app: *App, f: *FilesPane, x: u16, y: u16) Allocator.Error!void {
    var rows: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer rows.deinit(app.gpa);
    try rows.appendSlice(app.gpa, &.{
        .{ .label = "New file…", .action = .{ .command = .@"files.new_file" } },
        .{ .label = "New folder…", .action = .{ .command = .@"files.new_folder" } },
        .{ .label = "Paste here", .action = .{ .command = .@"file.paste" }, .separator_before = true },
        .{ .label = "Mark all", .action = .{ .command = .@"files.mark_all" }, .separator_before = true },
        .{ .label = "Clear marks", .action = .{ .command = .@"files.mark_clear" } },
        .{ .label = "Show hidden", .action = .{ .command = .@"files.toggle_hidden" }, .checked = f.show_hidden, .separator_before = true },
        .{ .label = "Go to…", .action = .{ .command = .@"files.destinations" } },
        .{ .label = "Up", .action = .{ .command = .@"files.up" } },
        .{ .label = "Refresh", .action = .{ .command = .@"files.refresh" } },
    });
    if (f.in_trash) try rows.append(app.gpa, .{ .label = "Empty trash…", .action = .{ .command = .@"files.empty_trash" }, .separator_before = true });
    const owned = try rows.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(owned);
    try app.openMenu(if (f.in_trash) "Trash" else "Directory", owned, x, y);
}

fn openSortMenu(app: *App, f: *FilesPane, x: u16, y: u16) Allocator.Error!void {
    const items = try app.gpa.dupe(MenuItem, &.{
        .{ .label = "Name", .action = .{ .command = .@"files.sort_name" }, .checked = f.sort == .name },
        .{ .label = "Size", .action = .{ .command = .@"files.sort_size" }, .checked = f.sort == .size },
        .{ .label = "Modified", .action = .{ .command = .@"files.sort_modified" }, .checked = f.sort == .modified },
    });
    errdefer app.gpa.free(items);
    try app.openMenu("Sort by", items, x, y);
}

// ─── draw ───────────────────────────────────────────────────────────────

const Crumbs = struct { labels: []const []const u8, paths: []const []const u8 };

fn under(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or (std.mem.startsWith(u8, path, root) and path.len > root.len and std.fs.path.isSep(path[root.len]));
}

/// The path as crumbs: the workspace name then the relative segments
/// when inside the workspace; `Trash` then the segments when inside the
/// workspace's trash (its data-root path is an implementation detail,
/// and nothing above it belongs to this workspace); else the absolute
/// components.
fn crumbs(app: *App, f: *const FilesPane, arena: Allocator) Allocator.Error!Crumbs {
    var labels: std.ArrayListUnmanaged([]const u8) = .empty;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    const inside = under(f.cwd, app.workspace);
    const trash_dir = try trash.dir(app, arena);
    var base: []const u8 = "/";
    var rest: []const u8 = f.cwd;
    if (under(f.cwd, trash_dir)) {
        try labels.append(arena, "Trash");
        try paths.append(arena, trash_dir);
        base = trash_dir;
        rest = if (f.cwd.len > trash_dir.len) f.cwd[trash_dir.len + 1 ..] else "";
    } else if (inside) {
        const ws_name = std.fs.path.basename(app.workspace);
        try labels.append(arena, if (ws_name.len == 0) "workspace" else ws_name);
        try paths.append(arena, app.workspace);
        base = app.workspace;
        rest = if (f.cwd.len > app.workspace.len) f.cwd[app.workspace.len + 1 ..] else "";
    } else {
        try labels.append(arena, "/");
        try paths.append(arena, "/");
        rest = std.mem.trimStart(u8, f.cwd, "/");
    }
    var it = std.mem.splitScalar(u8, rest, '/');
    var acc = base;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        acc = try std.fs.path.join(arena, &.{ acc, seg });
        try labels.append(arena, seg);
        try paths.append(arena, acc);
    }
    return .{ .labels = labels.items, .paths = paths.items };
}

/// The git porcelain letter for `abs` (a directory carries the first
/// letter of anything inside it), or 0.
fn gitBadge(app: *App, abs: []const u8, is_dir: bool) u8 {
    const st = &app.git;
    const r = st.activeRepo() orelse return 0;
    if (st.status_repo != r.id) return 0;
    const status = st.status orelse return 0;
    const rel = git_app.relToRepo(r, abs);
    if (rel.len == 0 or std.fs.path.isAbsolute(rel)) return 0;
    for (status.entries) |e| {
        if (std.mem.eql(u8, e.path, rel)) return e.code;
        if (is_dir and std.mem.startsWith(u8, e.path, rel) and e.path.len > rel.len and e.path[rel.len] == '/') return e.code;
    }
    return 0;
}

pub fn draw(app: *App, ui: Ui, id: PaneId, f: *FilesPane, area: Rect) Allocator.Error!void {
    if (!f.loaded) try f.reload(app.io);
    try f.refreshPreview(app.io);
    const arena = ui.arena;
    const rows = try arena.alloc(files_view.Row, f.visible.items.len);
    for (f.visible.items, 0..) |idx, i| {
        const e = f.entries[idx];
        rows[i] = .{
            .name = e.name,
            .is_dir = e.is_dir,
            .is_link = e.is_link,
            .size = e.size,
            .mtime = e.mtime,
            .marked = f.isMarked(e.path),
            .git = gitBadge(app, e.path, e.is_dir),
        };
    }
    const cs = try crumbs(app, f, arena);
    const focused_ = paneFocused(app, id);
    const empty: []const u8 = if (f.filter.items.len > 0) "No matches — Esc clears" else if (f.in_trash) "The trash is empty" else "Empty directory";
    const caret = files_view.draw(ui, id, area, .{
        .crumbs = cs.labels,
        .rows = rows,
        .cursor = f.cursor,
        .focused = focused_,
        .sort_label = f.sort.label(),
        .sort_widest = files_view.sort_widest,
        .show_hidden = f.show_hidden,
        .filter = .{ .text = f.filter.items, .caret = f.filter_caret, .focused = f.filter_focused, .anchor = f.filter_anchor },
        .marked = f.marks.count(),
        .total = f.entries.len,
        .err = f.err,
        .preview = f.preview_text,
        .now_s = Io.Timestamp.now(app.io, .real).toSeconds(),
        .empty = empty,
    }, &f.scroll);
    if (app.active == id) {
        app.pane_rows = @max(area.h -| 2, 1);
        if (focused_) if (caret) |c| {
            app.cursor_pos = .{ .x = c.x, .y = c.y };
        };
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;
const sdk_testing = @import("mnml_sdk").testing;

fn realRoot(tmp: *std.testing.TmpDir, gpa: Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}

fn seed(tmp: *std.testing.TmpDir) !void {
    try tmp.dir.createDirPath(t.io, "src/deep");
    try tmp.dir.createDirPath(t.io, "docs");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/main.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "src/deep/z.zig", .data = "z" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "README.md", .data = "# hi\nsecond line\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "big.bin", .data = "x" ** 5000 });
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".hidden", .data = "h" });
}

fn names(f: *const FilesPane, gpa: Allocator) ![][]const u8 {
    const out = try gpa.alloc([]const u8, f.count());
    for (f.visible.items, 0..) |idx, i| out[i] = f.entries[idx].name;
    return out;
}

test "listing: dirs first by name, the three sorts keep the cursor, hidden toggles, the filter narrows" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try seed(&tmp);
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var f = try FilesPane.init(t.allocator, root);
    defer f.deinit();
    try f.reload(t.io);
    var ns = try names(&f, t.allocator);
    try t.expectEqualStrings("docs", ns[0]);
    try t.expectEqualStrings("src", ns[1]);
    try t.expectEqualStrings("big.bin", ns[2]);
    try t.expectEqualStrings("README.md", ns[3]);
    try t.expectEqual(@as(usize, 4), ns.len);
    t.allocator.free(ns);
    // Size: the big file first among the files; the cursor follows README.
    f.cursor = 3;
    try f.setSort(.size);
    ns = try names(&f, t.allocator);
    try t.expectEqualStrings("big.bin", ns[2]);
    try t.expectEqualStrings("README.md", f.selected().?.name);
    t.allocator.free(ns);
    try f.setSort(.modified);
    try t.expectEqualStrings("README.md", f.selected().?.name);
    try t.expectEqual(Sort.name, Sort.modified.next());
    // Hidden.
    f.show_hidden = true;
    try f.reload(t.io);
    try t.expectEqual(@as(usize, 5), f.count());
    try t.expect(f.rowOfPath(f.entries[f.visible.items[2]].path) != null);
    f.show_hidden = false;
    try f.reload(t.io);
    try t.expectEqual(@as(usize, 4), f.count());
    // Filter.
    try f.filter.appendSlice(t.allocator, "ReAd");
    try f.applyFilter();
    try t.expectEqual(@as(usize, 1), f.count());
    try t.expectEqualStrings("README.md", f.selected().?.name);
    try t.expectEqual(@as(usize, 4), f.entries.len);
    f.filter.clearRetainingCapacity();
    try f.applyFilter();
    // Navigate down and up: the cursor lands on the directory just left.
    const src = try std.fs.path.join(t.allocator, &.{ root, "src" });
    defer t.allocator.free(src);
    try f.navigate(t.io, src);
    try t.expectEqualStrings("src", f.title());
    try t.expectEqual(@as(usize, 2), f.count());
    try t.expect(f.selected().?.is_dir);
    try f.up(t.io);
    try t.expectEqualStrings("src", f.selected().?.name);
    // A directory that cannot be read reports its error and lists nothing.
    const nope = try std.fs.path.join(t.allocator, &.{ root, "nope" });
    defer t.allocator.free(nope);
    try f.navigate(t.io, nope);
    try t.expect(f.err != null);
    try t.expectEqual(@as(usize, 0), f.count());
}

test "marks are keyed by path: toggle advances, a range fills, invert and all respect the filter, a re-sort and a reload keep them" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try seed(&tmp);
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var f = try FilesPane.init(t.allocator, root);
    defer f.deinit();
    try f.reload(t.io);
    try f.toggleMark();
    try t.expectEqual(@as(usize, 1), f.cursor);
    try t.expect(f.isMarked(f.entryAt(0).?.path));
    // v from the anchor (row 0) to row 2.
    try f.markRange(2);
    try t.expectEqual(@as(usize, 3), f.marks.count());
    try t.expectEqual(@as(usize, 2), f.cursor);
    // Invert: the three go, README comes.
    try f.invertMarks();
    try t.expectEqual(@as(usize, 1), f.marks.count());
    try t.expect(f.isMarked(f.entryAt(3).?.path));
    // Mark all under a filter marks only what is listed.
    try f.filter.appendSlice(t.allocator, "src");
    try f.applyFilter();
    try f.markAll();
    try t.expectEqual(@as(usize, 2), f.marks.count());
    f.filter.clearRetainingCapacity();
    try f.applyFilter();
    // The marks survive a re-sort and a reload, by path.
    try f.setSort(.size);
    try f.reload(t.io);
    try t.expect(f.isMarked(f.entryAt(1).?.path)); // src
    try t.expectEqual(@as(usize, 2), f.marks.count());
    // Action paths list marks in display order, and the cursor row otherwise.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const paths = try f.actionPaths(arena_state.allocator());
    try t.expectEqual(@as(usize, 2), paths.len);
    try t.expect(sdk_testing.pathEndsWith(paths[0], "/src"));
    try t.expect(sdk_testing.pathEndsWith(paths[1], "/README.md"));
    f.clearMarks();
    f.cursor = 0;
    const one = try f.actionPaths(arena_state.allocator());
    try t.expectEqual(@as(usize, 1), one.len);
    try t.expect(sdk_testing.pathEndsWith(one[0], "/docs"));
    // A mark whose file vanished is dropped on reload.
    try f.toggleMarkPath(f.entryAt(3).?.path);
    try tmp.dir.deleteFile(t.io, "README.md");
    try f.reload(t.io);
    try t.expectEqual(@as(usize, 0), f.marks.count());
}

test "the pane in the app: files.open, keys, enter descends and opens, the preview column, files.open_split" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try seed(&tmp);
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"files.open" });
    const id = app.active.?;
    try t.expectEqualStrings(std.fs.path.basename(root), app.panes.get(id).?.title());
    try t.expect(focused(&app) != null);
    try app.render();
    const txt = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "README.md") != null);
    try t.expect(std.mem.indexOf(u8, txt, "sort: Name") != null);
    try t.expect(std.mem.indexOf(u8, txt, "Modified") != null);
    // j to README, the preview column shows its head.
    try app.handle(.{ .key = Key.char('G') });
    try app.render();
    const txt2 = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt2);
    try t.expect(std.mem.indexOf(u8, txt2, "│ # hi") != null);
    // Enter on a file opens it; the browser keeps its tab.
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("README.md", app.panes.get(app.active.?).?.title());
    app.showPane(id);
    // Enter on a directory descends; h goes back up.
    try app.handle(.{ .key = Key.char('g') });
    try app.handle(.{ .key = Key.char('j') });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expectEqualStrings("src", app.panes.get(id).?.title());
    try app.handle(.{ .key = Key.char('h') });
    try t.expectEqualStrings("src", app.panes.get(id).?.files.selected().?.name);
    // Space marks and advances; esc clears the marks.
    try app.handle(.{ .key = Key.char(' ') });
    try t.expectEqual(@as(usize, 1), app.panes.get(id).?.files.marks.count());
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqual(@as(usize, 0), app.panes.get(id).?.files.marks.count());
    // The filter: `/` then typing narrows; Enter leaves the pill.
    try app.handle(.{ .key = Key.char('/') });
    try app.handle(.{ .key = Key.char('b') });
    try app.handle(.{ .key = Key.char('i') });
    try t.expectEqual(@as(usize, 1), app.panes.get(id).?.files.count());
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(!app.panes.get(id).?.files.filter_focused);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqual(@as(usize, 4), app.panes.get(id).?.files.count());
    // s cycles the sort; . toggles hidden.
    try app.handle(.{ .key = Key.char('s') });
    try t.expectEqual(Sort.size, app.panes.get(id).?.files.sort);
    try app.handle(.{ .key = Key.char('.') });
    try t.expectEqual(@as(usize, 5), app.panes.get(id).?.files.count());
    // A key the pane does not own falls through to the chord chain.
    try t.expect(!try handleKey(&app, id, &app.panes.get(id).?.files, Key.ctrl('p')));
    // open_split: the focused browser plus ONE beside it, the right one
    // focused, no scratch tab. (This pinned 3 browsers once — the
    // duplicate tab the finding reported.)
    try command.run(&app, .{ .static = .@"files.open_split" });
    var browsers: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| if (p.* == .files) {
        browsers += 1;
    };
    try t.expectEqual(@as(usize, 2), browsers);
    try t.expect(app.panes.get(app.active.?).?.* == .files);
    try t.expect(app.active.? != id);
    try t.expectEqual(@as(usize, 3), app.panes.count()); // 2 browsers + README
}

test "mouse: a row press moves the cursor, a second press opens, ctrl-click marks, shift-click extends, the crumb navigates, the sort chip cycles" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try seed(&tmp);
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 70, .rows = 16 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"files.open" });
    const id = app.active.?;
    const f = &app.panes.get(id).?.files;
    try app.render();
    // Row 0 is the palette bar (width < 80: none), row 0 = strip, row 1 = crumbs,
    // row 2 = columns, rows 3.. entries.
    var y: u16 = 0;
    var row_y: ?u16 = null;
    while (y < 16) : (y += 1) if (app.hits.at(10, y)) |h| if (h == .script_hit and h.script_hit.id == 1) {
        row_y = y;
        break;
    };
    const ry = row_y.?;
    try app.handle(.{ .mouse = .{ .x = 10, .y = ry, .kind = .press, .button = .left } });
    try t.expectEqual(@as(usize, 1), f.cursor);
    try app.handle(.{ .mouse = .{ .x = 10, .y = ry + 2, .kind = .press, .button = .left, .mods = .{ .shift = true } } });
    try t.expectEqual(@as(usize, 3), f.marks.count());
    try app.handle(.{ .mouse = .{ .x = 10, .y = ry, .kind = .press, .button = .left, .mods = .{ .ctrl = true } } });
    try t.expectEqual(@as(usize, 2), f.marks.count());
    f.clearMarks();
    // A second press within the window enters `src`.
    try app.handle(.{ .mouse = .{ .x = 10, .y = ry, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = 10, .y = ry, .kind = .press, .button = .left } });
    try t.expectEqualStrings("src", f.title());
    try app.render();
    // The first crumb is the workspace: click it to go back.
    var crumb_x: ?u16 = null;
    var crumb_y: u16 = 0;
    for (app.hits.items.items) |h| if (h.target == .script_hit and Hit.decode(h.target.script_hit.id) == .crumb and h.target.script_hit.id == Hit.crumb_base) {
        crumb_x = h.rect.x;
        crumb_y = h.rect.y;
    };
    // The crumb row sits two above the FIRST entry row; `ry` is row 1.
    try t.expectEqual(ry - 3, crumb_y);
    try app.handle(.{ .mouse = .{ .x = crumb_x.?, .y = crumb_y, .kind = .press, .button = .left } });
    try t.expectEqualStrings(root, f.cwd);
    try app.render();
    // The sort chip.
    var chip_x: ?u16 = null;
    for (app.hits.items.items) |h| if (h.target == .script_hit and h.target.script_hit.id == Hit.chip_base + @intFromEnum(Hit.Chip.sort)) {
        chip_x = h.rect.x;
    };
    try app.handle(.{ .mouse = .{ .x = chip_x.?, .y = crumb_y, .kind = .press, .button = .left } });
    try t.expectEqual(Sort.size, f.sort);
    try app.handle(.{ .mouse = .{ .x = chip_x.?, .y = crumb_y, .kind = .press, .button = .right } });
    try t.expect(app.overlay == .menu);
    try t.expectEqualStrings("Size", app.overlay.menu.items[1].label);
    try t.expect(app.overlay.menu.items[1].checked);
    app.overlay.deinit(app.gpa);
    app.focus = .{ .pane = id };
    // A right press on a row opens the row menu on that row.
    try app.render();
    try app.handle(.{ .mouse = .{ .x = 10, .y = ry, .kind = .press, .button = .right } });
    try t.expect(app.overlay == .menu);
    try t.expectEqual(@as(usize, 1), f.cursor);
    try t.expectEqualStrings("Rename…", app.overlay.menu.items[7].label);
}

test "preview: p opens the file in its own leaf and keeps the browser focused; a second p reuses it" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try seed(&tmp);
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 120, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"files.open" });
    const id = app.active.?;
    try app.handle(.{ .key = Key.char('G') });
    try app.handle(.{ .key = Key.char('p') });
    try t.expectEqual(id, app.active.?);
    const first = app.panes.get(id).?.files.preview_pane.?;
    try t.expectEqualStrings("README.md", app.panes.get(first).?.title());
    // The same gesture as a tree click, so the same italic tab.
    try t.expect(app.panes.get(first).?.preview());
    const layout = app.layouts.current();
    try t.expect(layout.leafOf(first).? != layout.leafOf(id).?);
    try app.handle(.{ .key = Key.char('k') });
    try app.handle(.{ .key = Key.char('p') });
    try t.expectEqual(id, app.active.?);
    const second = app.panes.get(id).?.files.preview_pane.?;
    try t.expectEqualStrings("big.bin", app.panes.get(second).?.title());
    try t.expect(app.panes.get(first) == null);
    try t.expectEqual(@as(usize, 2), app.panes.count());
    // A directory does not preview.
    try app.handle(.{ .key = Key.char('g') });
    try t.expectError(error.Failed, command.run(&app, .{ .static = .@"files.preview" }));
}

/// Pump the app until no transfer runs (bounded).
fn settle(app: *App) !void {
    const transfers = @import("transfers.zig");
    var i: usize = 0;
    while (transfers.running(app) > 0 and i < 4000) : (i += 1) {
        try app.tick(app.now_ms + 5);
        std.Io.sleep(app.io, .fromMilliseconds(2), .awake) catch {};
    }
    try t.expectEqual(@as(usize, 0), transfers.running(app));
}

test "move_to acts on the marks: the prompt names the count, the typed folder takes every marked path on the worker" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try seed(&tmp);
    const root = try realRoot(&tmp, t.allocator);
    defer t.allocator.free(root);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .cols = 100, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    try command.run(&app, .{ .static = .@"files.open" });
    const id = app.active.?;
    // Mark README.md and big.bin (rows 3 and 2; Space on the last row
    // cannot advance), then Move to… docs.
    try app.handle(.{ .key = Key.char('G') });
    try app.handle(.{ .key = Key.char(' ') });
    try app.handle(.{ .key = Key.char('k') });
    try app.handle(.{ .key = Key.char(' ') });
    try t.expectEqual(@as(usize, 2), app.panes.get(id).?.files.marks.count());
    try command.run(&app, .{ .static = .@"file.move_to" });
    try t.expect(app.overlay == .prompt);
    try t.expectEqualStrings("Move 2 items to folder", app.overlay.prompt.state.title);
    try t.expect(app.overlay.prompt.purpose == .move_paths);
    for ("docs") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try settle(&app);
    try tmp.dir.access(t.io, "docs/README.md", .{});
    try tmp.dir.access(t.io, "docs/big.bin", .{});
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "README.md", .{}));
    // The marks pointed at paths that moved: the reload dropped them.
    try t.expectEqual(@as(usize, 0), app.panes.get(id).?.files.marks.count());
    try t.expectEqual(@as(usize, 2), app.panes.get(id).?.files.count()); // docs/, src/
    // A folder that does not exist is refused with a toast, nothing moves.
    try app.handle(.{ .key = Key.char('G') });
    try command.run(&app, .{ .static = .@"file.move_to" });
    try t.expectEqualStrings("Move src to folder", app.overlay.prompt.state.title);
    for ("nope") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "not a folder") != null);
    try tmp.dir.access(t.io, "src/main.zig", .{});
}
