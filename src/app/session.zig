//! The session — `<workspace>/.mnml/session.zon` (E1: persisted state is
//! ZON). What the workspace looked like when mnml last ran: the open
//! panes (path, cursor, scroll, wrap, folds, marks; a pty's command
//! line), every tab page's split tree, the active pane, the tree rail,
//! the right panel, zen, the theme, the harpoon pins, the `:` history,
//! the recent files, the closed-buffer list and the toast log.
//!
//! Saved on quit (the `exit` hook) and every `autosave_ms` from `tick`;
//! restored from the `startup` hook when `session.restore` is on. A
//! file for another workspace, from another format version, or one
//! that does not parse is ignored with one toast — never a crash, never
//! a half-restored layout.
//!
//! The `.test` runner and the headless loop never emit `startup`, so a
//! test never autosaves into its temp dir unless it asks
//! (`session.save`). The `Loaded` rules apply on the way in: the file is
//! parsed into an arena and every string that lands in `App` is duped
//! onto the gpa by the owner that keeps it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Config = app_mod.Config;
const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const pty_pane = @import("pty_pane.zig");
const md_preview = @import("md_preview.zig");
const hooks = @import("../core/hooks.zig");
const panel = @import("../core/panel.zig");
const theme_mod = @import("../ui/theme.zig");
const zen = @import("zen.zig");
const command = @import("../core/command.zig");

pub const format_version: u32 = 1;
pub const rel_path = ".mnml/session.zon";
pub const autosave_ms: i64 = 30_000;
/// A pane index the file names that did not come back; swept out of
/// the rebuilt tree before it is installed.
const sentinel: PaneId = std.math.maxInt(PaneId);

// ─── the on-disk shape ───────────────────────────────────────────────────

pub const Level = enum { info, warn, err };
pub const Mark = struct { letter: u8, row: usize, col: usize };
pub const Fold = struct { start: usize, end: usize };
pub const PaneKind = enum { editor, md_preview, pty };

pub const Pane = struct {
    kind: PaneKind = .editor,
    /// Absolute. Editors and previews; a scratch buffer is not saved.
    path: []const u8 = "",
    cursor: usize = 0,
    scroll_line: u32 = 0,
    scroll_col: u32 = 0,
    wrap: ?bool = null,
    folds: []const Fold = &.{},
    marks: []const Mark = &.{},
    /// pty: the command line (empty = the shell), its cwd and tab label.
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

/// The split tree as the node pool it is in memory: leaves name pane
/// indices into `Saved.panes`, splits name node indices.
pub const Node = union(enum) {
    leaf: struct { active: u32 = 0, tabs: []const u32 = &.{} },
    split: struct { dir: layout_mod.SplitDir = .horizontal, ratio: u16 = 50, first: u32 = 0, second: u32 = 0 },
};
pub const Tab = struct { nodes: []const Node = &.{}, root: ?u32 = null };
pub const Closed = struct { path: []const u8 = "", cursor: usize = 0 };
pub const Message = struct { level: Level = .info, age_ms: i64 = 0, text: []const u8 = "" };
/// SESSIONS: a display name for a session id.
pub const SessionAlias = struct { id: []const u8 = "", name: []const u8 = "" };

pub const Saved = struct {
    version: u32 = format_version,
    workspace: []const u8 = "",
    panes: []const Pane = &.{},
    tabs: []const Tab = &.{},
    active_tab: usize = 0,
    /// Index into `panes`.
    active: ?u32 = null,
    tree_visible: bool = true,
    tree_width: u16 = 30,
    tree_show_hidden: bool = false,
    tree_expanded: []const []const u8 = &.{},
    right_panel: ?panel.PanelId = null,
    right_panel_width: u16 = 40,
    zen: bool = false,
    theme: []const u8 = "",
    /// Nine entries; `""` is an empty slot.
    harpoon: []const []const u8 = &.{},
    ex_history: []const []const u8 = &.{},
    /// Oldest first, as `App.recent`.
    recent: []const []const u8 = &.{},
    closed: []const Closed = &.{},
    messages: []const Message = &.{},
    /// SESSIONS: the manual order (session ids, first on top) and the aliases.
    sessions_order: []const []const u8 = &.{},
    sessions_aliases: []const SessionAlias = &.{},
};

// ─── app-side state ──────────────────────────────────────────────────────

pub const State = struct {
    /// Set by the `startup` hook: the terminal loop is running, so the
    /// timer and the exit hook may write. `session.clear` turns it off.
    autosave: bool = false,
    last_save_ms: i64 = 0,
    /// The file came back on this launch.
    restored: bool = false,
};

pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    app.session.autosave = true;
    app.session.last_save_ms = app.now_ms;
    if (!app.cfg.session.restore) return;
    restore(app) catch |err| app.toast("session: {s}", .{@errorName(err)});
}

pub fn onExit(app: *App, _: hooks.HookArgs) void {
    if (!app.session.autosave) return;
    save(app) catch {};
}

/// The 30 s timer.
pub fn tick(app: *App, now: i64) void {
    if (!app.session.autosave) return;
    if (now - app.session.last_save_ms < autosave_ms) return;
    save(app) catch {};
}

pub fn path(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ app.workspace, rel_path });
}

// ─── save ────────────────────────────────────────────────────────────────

pub const SaveError = Allocator.Error || error{WriteFailed};

/// Serialize the app into the session file. Best-effort by design —
/// the caller decides whether a failure is worth a toast.
pub fn save(app: *App) SaveError!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = try capture(app, arena);
    const text = try render(arena, saved);
    const file = try path(app, arena);
    const dir = std.fs.path.dirname(file) orelse return error.WriteFailed;
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, dir) catch return error.WriteFailed;
    cwd.writeFile(app.io, .{ .sub_path = file, .data = text }) catch return error.WriteFailed;
    app.session.last_save_ms = app.now_ms;
}

/// `Saved` as ZON text on `arena`.
pub fn render(arena: Allocator, saved: Saved) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// mnml session — written on quit and every 30 s; delete it (or `session.clear`) to start clean.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(saved, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

/// The app as a `Saved`, every slice on `arena`.
pub fn capture(app: *App, arena: Allocator) Allocator.Error!Saved {
    var saved: Saved = .{ .workspace = app.workspace };

    // Panes: every slot that can come back, remembering which index it got.
    const slot_count = app.panes.slots.items.len;
    const index_of = try arena.alloc(?u32, slot_count);
    @memset(index_of, null);
    var panes: std.ArrayListUnmanaged(Pane) = .empty;
    for (app.panes.slots.items, 0..) |*slot, i| {
        const p = &(slot.* orelse continue);
        const sp: ?Pane = switch (p.*) {
            .editor => |*e| blk: {
                const file = e.buf.path orelse break :blk null;
                var folds: std.ArrayListUnmanaged(Fold) = .empty;
                for (e.buf.folds.keys(), e.buf.folds.values()) |s, en| try folds.append(arena, .{ .start = s, .end = en });
                var marks: std.ArrayListUnmanaged(Mark) = .empty;
                var it = e.buf.marks.iterator();
                while (it.next()) |m| try marks.append(arena, .{ .letter = m.key_ptr.*, .row = m.value_ptr.row, .col = m.value_ptr.col });
                break :blk .{
                    .kind = .editor,
                    .path = file,
                    .cursor = e.buf.editor.cursor,
                    .scroll_line = e.view.scroll_line,
                    .scroll_col = e.view.scroll_col,
                    .wrap = e.wrap,
                    .folds = folds.items,
                    .marks = marks.items,
                };
            },
            .md_preview => |*m| .{ .kind = .md_preview, .path = m.path },
            .pty => |*pt| blk: {
                // Runner and task ptys are re-created by their owners.
                if (pt.kind != .shell and pt.kind != .command) break :blk null;
                const argv = try arena.alloc([]const u8, pt.argv.len);
                for (pt.argv, 0..) |a, k| argv[k] = a;
                break :blk .{ .kind = .pty, .argv = argv, .cwd = pt.cwd, .label = pt.label };
            },
            else => null,
        };
        const sp_val = sp orelse continue;
        index_of[i] = @intCast(panes.items.len);
        try panes.append(arena, sp_val);
    }
    saved.panes = panes.items;
    if (app.active) |a| if (a < slot_count) {
        saved.active = index_of[a];
    };

    // Tab pages: the node pools, compacted (free slots dropped).
    var tabs: std.ArrayListUnmanaged(Tab) = .empty;
    for (app.layouts.layouts.items) |*l| try tabs.append(arena, try captureLayout(arena, l, index_of));
    saved.tabs = tabs.items;
    saved.active_tab = app.layouts.active;

    // Chrome.
    saved.tree_visible = app.tree.visible;
    saved.tree_width = app.tree.width;
    saved.tree_show_hidden = app.tree.show_hidden;
    var expanded: std.ArrayListUnmanaged([]const u8) = .empty;
    var kit = app.tree.expanded.keyIterator();
    while (kit.next()) |k| try expanded.append(arena, k.*);
    std.mem.sort([]const u8, expanded.items, {}, lessThan);
    saved.tree_expanded = expanded.items;
    saved.right_panel = app.right_panel;
    saved.right_panel_width = app.right_panel_width;
    saved.zen = app.zen;
    saved.theme = app.theme.name;

    // Lists.
    const pins = try arena.alloc([]const u8, app.harpoon.paths.len);
    for (app.harpoon.paths, 0..) |p, i| pins[i] = p orelse "";
    saved.harpoon = pins;
    saved.ex_history = try dupeList(arena, app.cmd_history.items);
    saved.recent = try dupeList(arena, app.recent.items);
    const closed = try arena.alloc(Closed, app.closed.items.len);
    for (app.closed.items, 0..) |c, i| closed[i] = .{ .path = c.path, .cursor = c.cursor };
    saved.closed = closed;
    const msgs = try arena.alloc(Message, app.messages.items.items.len);
    for (app.messages.items.items, 0..) |m, i| msgs[i] = .{
        .level = switch (m.level) {
            .info => .info,
            .warn => .warn,
            .err => .err,
        },
        .age_ms = @max(app.now_ms - m.at_ms, 0),
        .text = m.text,
    };
    saved.messages = msgs;
    saved.sessions_order = try dupeList(arena, app.sessions.order.items);
    const aliases = try arena.alloc(SessionAlias, app.sessions.aliases.items.len);
    for (app.sessions.aliases.items, 0..) |a, i| aliases[i] = .{ .id = a.id, .name = a.name };
    saved.sessions_aliases = aliases;
    return saved;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn dupeList(arena: Allocator, items: []const []u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, items.len);
    for (items, 0..) |s, i| out[i] = s;
    return out;
}

fn captureLayout(arena: Allocator, l: *const Layout, index_of: []const ?u32) Allocator.Error!Tab {
    // Compact node ids: free slots go, the rest renumber in order.
    const remap = try arena.alloc(?u32, l.nodes.items.len);
    var next: u32 = 0;
    for (l.nodes.items, 0..) |n, i| {
        remap[i] = if (n == .free) null else next;
        if (n != .free) next += 1;
    }
    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    for (l.nodes.items) |n| switch (n) {
        .free => {},
        .leaf => |lf| {
            var tabs: std.ArrayListUnmanaged(u32) = .empty;
            var active: ?u32 = null;
            for (lf.tabs.items) |pid| {
                const idx = (if (pid < index_of.len) index_of[pid] else null) orelse continue;
                try tabs.append(arena, idx);
                if (pid == lf.active) active = idx;
            }
            try nodes.append(arena, .{ .leaf = .{ .active = active orelse (if (tabs.items.len > 0) tabs.items[0] else 0), .tabs = tabs.items } });
        },
        .split => |s| try nodes.append(arena, .{ .split = .{
            .dir = s.dir,
            .ratio = s.ratio,
            .first = remap[s.first] orelse 0,
            .second = remap[s.second] orelse 0,
        } }),
    };
    return .{ .nodes = nodes.items, .root = if (l.root) |r| remap[r] else null };
}

// ─── restore ─────────────────────────────────────────────────────────────

pub const RestoreError = Allocator.Error;

/// Read the file and rebuild the app from it. A missing file is
/// nothing; a foreign / stale / unreadable one is one toast.
pub fn restore(app: *App) RestoreError!void {
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = try path(app, arena);
    const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, file, arena, .limited(32 * 1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return,
        else => {
            app.toast("session: cannot read {s}: {s}", .{ rel_path, @errorName(err) });
            return;
        },
    };
    const saved = parse(arena, src) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            app.toast("session: {s} does not parse — ignored", .{rel_path});
            return;
        },
    };
    if (saved.version != format_version) {
        app.toast("session: {s} is format v{d}, this build writes v{d} — ignored", .{ rel_path, saved.version, format_version });
        return;
    }
    if (!std.mem.eql(u8, saved.workspace, app.workspace)) {
        app.toast("session: {s} belongs to {s} — ignored", .{ rel_path, saved.workspace });
        return;
    }
    try apply(app, arena, saved);
    app.session.restored = true;
}

pub fn parse(arena: Allocator, src: [:0]const u8) error{ OutOfMemory, ParseZon }!Saved {
    // The parser is instantiated per field of `Saved`; the default quota
    // ran out when the SESSIONS lists joined the file.
    @setEvalBranchQuota(4000);
    return std.zon.parse.fromSliceAlloc(Saved, arena, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false });
}

/// Rebuild the app from `saved`. Panes are opened first (each lands in
/// whatever leaf the openers pick), then the layouts are replaced
/// wholesale with the saved trees, then the chrome and the lists.
pub fn apply(app: *App, arena: Allocator, saved: Saved) RestoreError!void {
    const gpa = app.gpa;
    // Panes → ids.
    const ids = try arena.alloc(?PaneId, saved.panes.len);
    for (saved.panes, 0..) |sp, i| ids[i] = openSaved(app, sp) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };

    // Layouts: the saved trees replace whatever the opens built.
    if (saved.tabs.len > 0) {
        var fresh: std.ArrayListUnmanaged(Layout) = .empty;
        errdefer {
            for (fresh.items) |*l| l.deinit();
            fresh.deinit(gpa);
        }
        for (saved.tabs) |tab| try fresh.append(gpa, try buildLayout(gpa, tab, ids));
        app.setActive(null);
        const ls = &app.layouts;
        for (ls.layouts.items) |*l| l.deinit();
        ls.layouts.deinit(gpa);
        ls.layouts = fresh;
        ls.active = @min(saved.active_tab, ls.layouts.items.len - 1);
    }
    // The active pane, or the first leaf's.
    const want: ?PaneId = if (saved.active) |a| (if (a < ids.len) ids[a] else null) else null;
    if (want) |id| {
        app.showPane(id);
    } else {
        const layout = app.layouts.current();
        if (layout.firstLeaf()) |l| app.setActive(layout.leaf(l).?.active);
    }

    // Chrome.
    app.tree.visible = saved.tree_visible;
    app.tree.width = std.math.clamp(saved.tree_width, Config.tree_width_min, Config.tree_width_max);
    app.tree.show_hidden = saved.tree_show_hidden;
    for (saved.tree_expanded) |rel| {
        if (app.tree.expanded.contains(rel)) continue;
        const key = try gpa.dupe(u8, rel);
        errdefer gpa.free(key);
        try app.tree.expanded.put(gpa, key, {});
    }
    app.tree.loaded = false; // re-listed on the next frame with the expansions applied
    app.right_panel = saved.right_panel;
    app.right_panel_width = @max(saved.right_panel_width, 8);
    zen.set(app, saved.zen);
    if (saved.theme.len > 0) if (theme_mod.byName(saved.theme)) |th| {
        if (!std.mem.eql(u8, th.name, app.theme.name)) app.setTheme(th);
    };

    // Lists.
    for (saved.harpoon, 0..) |p, i| {
        if (i >= app.harpoon.paths.len or p.len == 0) continue;
        try app.harpoon.set(gpa, i, p);
    }
    for (saved.ex_history) |line| try app.noteCmdLine(line);
    for (saved.sessions_order) |id| {
        if (id.len == 0 or app.sessions.orderIndex(id) != null) continue;
        const owned = try gpa.dupe(u8, id);
        errdefer gpa.free(owned);
        try app.sessions.order.append(gpa, owned);
    }
    for (saved.sessions_aliases) |a| if (a.id.len > 0) try app.sessions.setAlias(gpa, a.id, a.name);
    for (saved.recent) |p| try app.noteRecent(p);
    for (saved.closed) |c| {
        if (c.path.len == 0) continue;
        const copy = try gpa.dupe(u8, c.path);
        errdefer gpa.free(copy);
        if (app.closed.items.len >= App.max_closed) gpa.free(app.closed.orderedRemove(0).path);
        try app.closed.append(gpa, .{ .path = copy, .cursor = c.cursor });
    }
    for (saved.messages) |m| try app.messages.record(gpa, m.text, switch (m.level) {
        .info => .info,
        .warn => .warn,
        .err => .err,
    }, app.now_ms - m.age_ms);
    app.messages.markRead();
    app.needs_render = true;
}

const OpenError = Allocator.Error || error{Skipped};

/// One saved pane back into the store. `Skipped` for anything that
/// cannot be reopened (a file that went away, a pty where there is none).
fn openSaved(app: *App, sp: Pane) OpenError!?PaneId {
    switch (sp.kind) {
        .editor => {
            if (sp.path.len == 0) return null;
            // A file that went away is not recreated as an empty buffer.
            Io.Dir.cwd().access(app.io, sp.path, .{}) catch return null;
            const id = app.openEditor(sp.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
            const e = app.panes.editor(id) orelse return null;
            e.buf.editor.setCursor(@min(sp.cursor, e.buf.editor.len()));
            const lines: u32 = @intCast(@max(e.buf.editor.lineCount(), 1));
            e.view.scroll_line = @min(sp.scroll_line, lines - 1);
            e.view.scroll_col = sp.scroll_col;
            e.view.pinAt(e.buf.editor.cursor);
            e.wrap = sp.wrap;
            for (sp.folds) |f| {
                if (f.start >= lines or f.end >= lines or f.end < f.start) continue;
                try e.buf.folds.put(app.gpa, f.start, f.end);
            }
            for (sp.marks) |m| try e.buf.marks.put(app.gpa, m.letter, .{ .row = m.row, .col = m.col });
            return id;
        },
        .md_preview => {
            if (sp.path.len == 0) return null;
            Io.Dir.cwd().access(app.io, sp.path, .{}) catch return null;
            return md_preview.open(app, sp.path, .here, null) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        },
        .pty => {
            if (!pty_pane.supported) return null;
            return pty_pane.open(app, .{
                .argv = sp.argv,
                .cwd = sp.cwd,
                .label = sp.label,
                .placement = .tab,
                .kind = if (sp.argv.len == 0) .shell else .command,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return null,
            };
        },
    }
}

/// A `Layout` from a saved tab. Pane indices that did not come back
/// become `sentinel` tabs and are swept; a pool that is not a tree
/// (a node referenced twice, an index out of range) is an empty layout.
fn buildLayout(gpa: Allocator, tab: Tab, ids: []const ?PaneId) Allocator.Error!Layout {
    var l = Layout.init(gpa);
    errdefer l.deinit();
    if (!wellFormed(tab)) return l;
    for (tab.nodes) |n| switch (n) {
        .leaf => |lf| {
            var leaf: layout_mod.Leaf = .{ .active = sentinel, .tabs = .empty };
            errdefer leaf.tabs.deinit(gpa);
            for (lf.tabs) |ti| try leaf.tabs.append(gpa, if (ti < ids.len) (ids[ti] orelse sentinel) else sentinel);
            if (leaf.tabs.items.len == 0) try leaf.tabs.append(gpa, sentinel);
            const want: PaneId = if (lf.active < ids.len) (ids[lf.active] orelse sentinel) else sentinel;
            leaf.active = if (std.mem.indexOfScalar(PaneId, leaf.tabs.items, want) != null) want else leaf.tabs.items[0];
            try l.nodes.append(gpa, .{ .leaf = leaf });
        },
        .split => |s| try l.nodes.append(gpa, .{ .split = .{
            .dir = s.dir,
            .ratio = std.math.clamp(s.ratio, 10, 90),
            .first = s.first,
            .second = s.second,
        } }),
    };
    l.root = tab.root;
    while (l.leafOf(sentinel) != null) _ = l.removePane(sentinel);
    return l;
}

/// Every node referenced at most once, every reference in range, the
/// root in range, and a split's halves distinct.
fn wellFormed(tab: Tab) bool {
    const n = tab.nodes.len;
    if (n == 0) return tab.root == null;
    const root = tab.root orelse return false;
    if (root >= n or n > 4096) return false;
    var refs: [4096]u8 = @splat(0);
    refs[root] += 1;
    for (tab.nodes) |node| switch (node) {
        .leaf => {},
        .split => |s| {
            if (s.first >= n or s.second >= n or s.first == s.second) return false;
            refs[s.first] += 1;
            refs[s.second] += 1;
        },
    };
    for (refs[0..n]) |r| if (r != 1) return false;
    return true;
}

// ─── the commands ────────────────────────────────────────────────────────

pub fn saveCmd(app: *App) command.CommandError!void {
    save(app) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return app.diag.fail(app.frame.allocator(), "session: could not write {s}", .{rel_path}),
    };
    app.toast("session saved ({d} pane(s), {d} tab(s))", .{ app.panes.count(), app.layouts.layouts.items.len });
}

pub fn restoreCmd(app: *App) command.CommandError!void {
    app.session.restored = false;
    try restore(app);
    if (!app.session.restored) return app.diag.fail(app.frame.allocator(), "session: nothing restored from {s}", .{rel_path});
    app.toast("session restored", .{});
}

pub fn clearCmd(app: *App) command.CommandError!void {
    const file = try path(app, app.frame.allocator());
    Io.Dir.cwd().deleteFile(app.io, file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return app.diag.fail(app.frame.allocator(), "session: could not delete {s}: {s}", .{ rel_path, @errorName(err) }),
    };
    // Off until `session.save` asks again, so quitting does not bring it back.
    app.session.autosave = false;
    app.toast("session cleared — the next launch starts clean", .{});
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Fixture = struct {
    tmp: t.TmpDir,
    root: []u8,

    fn init() !Fixture {
        var tmp = t.tmpDir(.{});
        errdefer tmp.cleanup();
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(t.io, &pbuf);
        return .{ .tmp = tmp, .root = try t.allocator.dupe(u8, pbuf[0..n]) };
    }

    fn deinit(f: *Fixture) void {
        t.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn app(f: *Fixture) !App {
        return App.initWith(t.allocator, t.io, .{ .workspace = f.root, .cols = 120, .rows = 40 });
    }

    fn abs(f: *Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(t.allocator, &.{ f.root, rel });
    }
};

test "session: save → restore brings back the panes, the split, the tab pages, the cursor, folds, pins and history" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "a.txt", .data = "one\ntwo\nthree\nfour\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "b.txt", .data = "b\n" });
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = "c.md", .data = "# c\n" });
    const a = try f.abs("a.txt");
    defer t.allocator.free(a);
    const b = try f.abs("b.txt");
    defer t.allocator.free(b);
    const c = try f.abs("c.md");
    defer t.allocator.free(c);
    {
        var app = try f.app();
        defer app.deinit();
        const ida = try app.openPath(a);
        const e = app.panes.editor(ida).?;
        e.buf.editor.setCursor(9); // "three"
        e.wrap = true;
        try e.buf.folds.put(t.allocator, 1, 2);
        try e.buf.marks.put(t.allocator, 'q', .{ .row = 3, .col = 0 });
        // A second file split to the right, a markdown preview on a second tab page.
        _ = try app.openPath(b);
        try command.run(&app, .{ .static = .@"view.split_right" });
        try command.run(&app, .{ .static = .@"tab.new" });
        _ = try md_preview.open(&app, c, .here, null);
        try command.run(&app, .{ .static = .@"tab.prev" });
        app.setActive(ida);
        try app.harpoon.set(t.allocator, 2, a);
        try app.noteCmdLine("set wrap");
        app.tree.width = 44;
        app.tree.visible = false;
        try app.toastLevel(.warn, "remember me", .{});
        app.zen = true;
        try save(&app);
    }
    {
        var app = try f.app();
        defer app.deinit();
        try restore(&app);
        try t.expect(app.session.restored);
        // Two tab pages; the first is active and holds a split.
        try t.expectEqual(@as(usize, 2), app.layouts.layouts.items.len);
        try t.expectEqual(@as(usize, 0), app.layouts.active);
        const leaves = try app.layouts.current().leaves(app.frame.allocator());
        try t.expectEqual(@as(usize, 2), leaves.len);
        // The active pane is a.txt with its cursor, wrap, fold and mark.
        const e = app.activeEditor().?;
        try t.expectEqualStrings(a, e.buf.path.?);
        try t.expectEqual(@as(usize, 9), e.buf.editor.cursor);
        try t.expectEqual(true, e.wrap.?);
        try t.expectEqual(@as(usize, 2), e.buf.folds.get(1).?);
        try t.expectEqual(@as(usize, 3), e.buf.marks.get('q').?.row);
        // The preview came back on the second page.
        try t.expect(app.panes.findPreview(c) != null);
        // Chrome and lists.
        try t.expectEqual(@as(u16, 44), app.tree.width);
        try t.expect(!app.tree.visible);
        try t.expect(app.zen);
        try t.expectEqualStrings(a, app.harpoon.paths[2].?);
        try t.expectEqualStrings("set wrap", app.cmd_history.items[0]);
        try t.expect(app.recent.items.len >= 2);
        var found = false;
        for (app.messages.items.items) |m| if (std.mem.eql(u8, m.text, "remember me")) {
            found = true;
        };
        try t.expect(found);
        // Round-trip: what the restored app would save equals what was read.
        var arena_state = std.heap.ArenaAllocator.init(t.allocator);
        defer arena_state.deinit();
        const again = try capture(&app, arena_state.allocator());
        try t.expectEqual(@as(usize, 3), again.panes.len);
        try t.expectEqual(@as(usize, 2), again.tabs.len);
        try t.expectEqual(@as(usize, 9), again.panes[again.active.?].cursor);
    }
}

test "session: a foreign workspace, a future version and a broken file are one toast each; a vanished file is skipped" {
    var f = try Fixture.init();
    defer f.deinit();
    var app = try f.app();
    defer app.deinit();
    try f.tmp.dir.createDirPath(t.io, ".mnml");
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = ".{ .workspace = \"/elsewhere\" }" });
    try restore(&app);
    try t.expect(!app.session.restored);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "belongs to /elsewhere") != null);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = ".{ .version = 99 }" });
    try restore(&app);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "format v99") != null);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = ".{ .workspace = " });
    try restore(&app);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "does not parse") != null);
    // A well-formed file naming a file that no longer exists restores nothing for it.
    const text = try std.fmt.allocPrint(t.allocator, ".{{ .workspace = \"{s}\", .panes = .{{ .{{ .path = \"{s}/gone.txt\" }} }}, .tabs = .{{ .{{ .nodes = .{{ .{{ .leaf = .{{ .active = 0, .tabs = .{{0}} }} }} }}, .root = 0 }} }}, .active = 0 }}", .{ f.root, f.root });
    defer t.allocator.free(text);
    try f.tmp.dir.writeFile(t.io, .{ .sub_path = rel_path, .data = text });
    try restore(&app);
    try t.expect(app.session.restored);
    try t.expectEqual(@as(usize, 0), app.panes.count());
    try t.expect(app.layouts.current().isEmpty());
    // A pool that is not a tree is an empty layout, not a hang.
    try t.expect(!wellFormed(.{ .nodes = &.{ .{ .split = .{ .first = 0, .second = 1 } }, .{ .leaf = .{} } }, .root = 0 }));
    try t.expect(wellFormed(.{ .nodes = &.{ .{ .split = .{ .first = 1, .second = 2 } }, .{ .leaf = .{} }, .{ .leaf = .{} } }, .root = 0 }));
}

test "session: clear deletes the file and stops the autosave; the timer writes every 30 s" {
    var f = try Fixture.init();
    defer f.deinit();
    var app = try f.app();
    defer app.deinit();
    app.session.autosave = true;
    app.session.last_save_ms = app.now_ms;
    tick(&app, app.now_ms + autosave_ms - 1);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, rel_path, .{}));
    tick(&app, app.now_ms + autosave_ms);
    _ = try f.tmp.dir.statFile(t.io, rel_path, .{});
    try clearCmd(&app);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, rel_path, .{}));
    try t.expect(!app.session.autosave);
    onExit(&app, .exit);
    try t.expectError(error.FileNotFound, f.tmp.dir.statFile(t.io, rel_path, .{}));
    try saveCmd(&app);
    _ = try f.tmp.dir.statFile(t.io, rel_path, .{});
}
