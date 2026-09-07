//! Git mode — the Git activity section as the Rust editor has it: the
//! sidebar becomes the git palette (`ui/git_palette.zig`), the editor
//! area one `git_graph` tab per discovered repo, the sidebar snapped to
//! a fifth of the screen (Rust `open_git_graph`). Leaving the section
//! puts the layout that was there back; the graph panes stay in the
//! store so their scroll, sort and filters survive the round trip
//! (Rust `set_activity_section`'s `entering_git` / `leaving_git`).
//!
//! The palette's rows are built here from the rail data the worker
//! posts (`git.State.rail_*`), filtered and folded by this state, and
//! handed to the painter flat — the click and the key handlers rebuild
//! the same list, so a row index means the same thing in both.
//!
//! // changed: Rust keeps `active_section` and `pre_git_layout` on the
//! app; here the mode is `State.active` and the stash `State.pre`, and
//! `activity_bar.enter` is the one place every other section leaves it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const PaneId = app_mod.PaneId;
const Mouse = @import("../core/key.zig").Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const MenuItem = command.MenuItem;
const layout_mod = @import("layout.zig");
const Layout = layout_mod.Layout;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const hit = @import("../ui/hit.zig");
const text_field = @import("../ui/text_field.zig");
const view = @import("../ui/git_palette.zig");
const git = @import("git.zig");
const client = @import("../git/client.zig");
const parse = @import("../git/parse.zig");
const cmd_picker = @import("cmd_picker.zig");
const graph_view = @import("../ui/git_graph_view.zig");

pub const Section = view.Section;
pub const Row = view.Row;
pub const Part = view.Part;

/// A row menu's action, with the index the row named.
pub const MenuAct = command.GitPaletteAct;

const Stash = struct { layout: Layout, active: ?PaneId };

pub const State = struct {
    /// Git is the active section.
    active: bool = false,
    /// The layout that was showing before Git took it over.
    pre: ?Stash = null,
    /// Repos whose tab was closed this session (their paths, owned):
    /// not reopened on re-entry until `reopen`.
    closed: std.ArrayListUnmanaged([]u8) = .empty,
    collapsed: std.enums.EnumSet(Section) = .initEmpty(),
    /// `LOCAL:folder` keys of the folded branch groups. Owned.
    folded: std.ArrayListUnmanaged([]u8) = .empty,
    filter: text_field.Buf = .empty,
    filter_caret: usize = 0,
    filter_focused: bool = false,
    /// The last clicked ref's name. Owned.
    selected: ?[]u8 = null,
    scroll: usize = 0,
    /// The keyboard cursor over the rows.
    cursor: usize = 0,
    /// What the last paint measured.
    body_rows: usize = 0,
    total_items: usize = 0,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.pre) |*p| p.layout.deinit();
        for (self.closed.items) |c| gpa.free(c);
        self.closed.deinit(gpa);
        for (self.folded.items) |f| gpa.free(f);
        self.folded.deinit(gpa);
        self.filter.deinit(gpa);
        if (self.selected) |s| gpa.free(s);
        self.* = .{};
    }

    pub fn isClosed(self: *const State, path: []const u8) bool {
        for (self.closed.items) |c| if (std.mem.eql(u8, c, path)) return true;
        return false;
    }

    fn isFolded(self: *const State, key: []const u8) bool {
        for (self.folded.items) |f| if (std.mem.eql(u8, f, key)) return true;
        return false;
    }
};

// ─── entering and leaving ───────────────────────────────────────────────

/// Rust's snap: the sidebar takes a fifth of the screen when that is
/// at least eight cells.
pub fn snapSidebar(app: *App) void {
    const target: u16 = @intCast(@as(u32, app.screen.width) * 20 / 100);
    if (target >= 8) app.tree.width = target;
    app.tree.visible = true;
}

/// Enter git mode (idempotent): the sidebar becomes the palette, the
/// layout one graph tab per open repo, the palette takes the keys.
pub fn enter(app: *App) CommandError!void {
    const st = &app.git_palette;
    // Rediscovered on every entry: the workspace roots may have landed
    // after the first tick's look, and a repo may have been made since.
    try git.discover(app);
    snapSidebar(app);
    if (!st.active) {
        // A layout already made of graph tabs is not worth stashing —
        // it would come back as the "previous" screen.
        const cur = app.layouts.current();
        if (!layoutIsGit(app, cur)) {
            st.pre = .{ .layout = cur.*, .active = app.active };
            cur.* = Layout.init(app.gpa);
            app.active = null;
        }
        st.active = true;
    }
    if (app.right_panel != null and app.right_panel.? == .git) app.right_panel = null;
    try rebuildTabs(app);
    if (app.git.activeRepo() != null) {
        git.requestStatus(app) catch {};
        git.requestRail(app) catch {};
    }
    // Rust `open_git_graph` ends on `Focus::Pane`: the graph has the keys,
    // the palette takes them on a click.
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = if (app.active) |a| .{ .pane = a } else .{ .panel = .git };
    app.needs_render = true;
}

/// Leave git mode: the stashed layout comes back, the graph panes stay
/// in the store. A no-op outside the mode.
pub fn leave(app: *App) void {
    const st = &app.git_palette;
    if (!st.active) return;
    st.active = false;
    st.filter_focused = false;
    const cur = app.layouts.current();
    if (st.pre) |*p| {
        var gone = cur.*;
        cur.* = p.layout;
        gone.deinit();
        const now = cur.allPanes(app.frame.allocator()) catch &.{};
        const keep: ?PaneId = if (p.active) |a| (if (std.mem.indexOfScalar(PaneId, now, a) != null) a else null) else null;
        app.active = null;
        app.setActive(keep orelse (if (now.len > 0) now[0] else null));
        st.pre = null;
    } else {
        var gone = cur.*;
        cur.* = Layout.init(app.gpa);
        gone.deinit();
        app.active = null;
        app.setActive(null);
    }
    app.afterSplitChange();
    if (app.focus == .panel and app.focus.panel == .git) app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    app.needs_render = true;
}

/// `git.branch_rail_toggle`: in and out of the mode.
pub fn toggle(app: *App) CommandError!void {
    if (app.git_palette.active) {
        leave(app);
        app.focus = .tree;
        app.tree.visible = true;
        return;
    }
    try enter(app);
}

fn layoutIsGit(app: *App, l: *const Layout) bool {
    const ids = l.allPanes(app.frame.allocator()) catch return false;
    if (ids.len == 0) return false;
    for (ids) |id| if (app.panes.get(id)) |p| if (p.* != .git_graph) return false;
    return true;
}

/// One graph tab per discovered repo the user has not closed, reusing
/// the panes that exist; the previously active repo's tab stays active.
pub fn rebuildTabs(app: *App) CommandError!void {
    const st = &app.git_palette;
    const gs = &app.git;
    const arena = app.frame.allocator();
    const prev_repo: ?u32 = if (git.activeGraph(app)) |g| g.repo else null;
    var repos: std.ArrayListUnmanaged(*client.Repo) = .empty;
    for (gs.repos.items) |r| if (!st.isClosed(r.path)) try repos.append(arena, r);
    if (repos.items.len == 0) {
        // Nothing to walk up to either: the mode still shows.
        if (gs.repos.items.len == 0) _ = git.requireRepo(app) catch null;
        for (gs.repos.items) |r| if (!st.isClosed(r.path)) try repos.append(arena, r);
    }
    const layout = app.layouts.current();
    var gone = layout.*;
    layout.* = Layout.init(app.gpa);
    gone.deinit();
    app.active = null;
    if (repos.items.len == 0) {
        app.setActive(null);
        app.toast("no git repos open — use + to reopen", .{});
        return;
    }
    var first: ?PaneId = null;
    var want: ?PaneId = null;
    var leaf: ?layout_mod.NodeId = null;
    for (repos.items) |r| {
        const id = try git.ensureGraphPane(app, r);
        leaf = try layout.showIn(leaf, id);
        if (first == null) first = id;
        if (prev_repo != null and prev_repo.? == r.id) want = id;
    }
    app.setActive(want orelse first);
    app.afterSplitChange();
}

/// A graph tab closed: its repo stays out until reopened.
pub fn noteClosed(app: *App, path: []const u8) Allocator.Error!void {
    const st = &app.git_palette;
    if (st.isClosed(path)) return;
    try st.closed.append(app.gpa, try app.gpa.dupe(u8, path));
}

fn reopen(app: *App, idx: usize) CommandError!void {
    const st = &app.git_palette;
    if (idx >= st.closed.items.len) return;
    app.gpa.free(st.closed.orderedRemove(idx));
    if (st.active) try rebuildTabs(app) else try enter(app);
}

/// `git.reopen_repo`: a picker over the repos closed this session.
pub fn openReopenPicker(app: *App) CommandError!void {
    const st = &app.git_palette;
    const gpa = app.gpa;
    if (st.closed.items.len == 0) return app.diag.fail(app.frame.allocator(), "no closed repos to reopen", .{});
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (st.closed.items) |p| {
        try labels.append(gpa, try gpa.dupe(u8, std.fs.path.basename(p)));
        try details.append(gpa, try gpa.dupe(u8, p));
    }
    app.git.pick = .reopen_repo;
    try cmd_picker.openPickerWith(app, app.frame.allocator().dupe(u8, ui_title(st.closed.items.len)) catch "Reopen repo", .git, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), &.{});
}

fn ui_title(n: usize) []const u8 {
    return if (n == 1) "Reopen repo (1)" else "Reopen repo";
}

/// The picker's pick: the closed repo whose path is `detail`.
pub fn acceptReopen(app: *App, detail: []const u8) CommandError!void {
    const st = &app.git_palette;
    for (st.closed.items, 0..) |p, i| if (std.mem.eql(u8, p, detail)) return reopen(app, i);
}

/// The repo pill's menu (Rust's "Repos"): every repo, the closed ones
/// to reopen, and Add workspace.
pub fn openReposMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const st = &app.git_palette;
    const gs = &app.git;
    const gpa = app.gpa;
    var items: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer items.deinit(gpa);
    for (gs.repos.items, 0..) |r, i| {
        try items.append(gpa, .{
            .label = try std.fmt.allocPrint(app.frame.allocator(), "{s}{s}", .{ if (gs.active != null and gs.active.? == i) "\u{25CF} " else "  ", r.name }),
            .action = .{ .git_palette = .{ .what = .switch_repo, .idx = @intCast(i) } },
        });
    }
    for (st.closed.items, 0..) |p, i| {
        try items.append(gpa, .{
            .label = try std.fmt.allocPrint(app.frame.allocator(), "  Reopen: {s}", .{std.fs.path.basename(p)}),
            .action = .{ .git_palette = .{ .what = .reopen_repo, .idx = @intCast(i) } },
        });
    }
    try items.append(gpa, .{ .label = "  Add workspace\u{2026}", .action = .{ .command = .@"view.add_workspace" } });
    try app.openMenu("Repos", try items.toOwnedSlice(gpa), x, y);
}

// ─── the rows ───────────────────────────────────────────────────────────

fn matches(filter: []const u8, s: []const u8) bool {
    if (filter.len == 0) return true;
    if (filter.len > s.len) return false;
    var i: usize = 0;
    while (i + filter.len <= s.len) : (i += 1) if (std.ascii.eqlIgnoreCase(s[i .. i + filter.len], filter)) return true;
    return false;
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A worktree item's text: `branch (dir)`, or the label alone when it
/// is the directory's name or `(detached)`.
fn worktreeShown(arena: Allocator, item: []const u8) Allocator.Error!struct { path: []const u8, label: []const u8, shown: []const u8 } {
    const sep = std.mem.indexOfScalar(u8, item, '\x1f');
    const path = if (sep) |s| item[0..s] else item;
    var label: []const u8 = if (sep) |s| item[s + 1 ..] else "";
    if (label.len == 0) label = "(detached)";
    const dir = std.fs.path.basename(path);
    const shown = if (std.mem.eql(u8, label, dir) or (label.len > 0 and label[0] == '(')) label else try std.fmt.allocPrint(arena, "{s} ({s})", .{ label, dir });
    return .{ .path = path, .label = label, .shown = shown };
}

/// Whether two directory paths name the same place, through symlinks
/// (`git worktree list` prints the real path; a workspace may not be).
fn samePath(app: *App, arena: Allocator, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const ra = std.Io.Dir.realPathFileAbsoluteAlloc(app.io, a, arena) catch return false;
    const rb = std.Io.Dir.realPathFileAbsoluteAlloc(app.io, b, arena) catch return false;
    return std.mem.eql(u8, ra, rb);
}

/// The palette's rows for this frame, on `arena`: the sections in
/// Rust's order with the filter applied, a folded section keeping its
/// header, a gap row after each.
pub fn rows(app: *App, arena: Allocator) Allocator.Error![]Row {
    const st = &app.git_palette;
    const gs = &app.git;
    const filter = st.filter.items;
    var out: std.ArrayListUnmanaged(Row) = .empty;
    const repo_path: []const u8 = if (gs.activeRepo()) |r| r.path else "";

    // WORKTREES — the current one is the repo the palette is on.
    if (gs.rail_worktrees.len > 0) {
        try out.append(arena, .{ .section = .{ .s = .worktrees, .count = @intCast(gs.rail_worktrees.len), .collapsed = st.collapsed.contains(.worktrees) } });
        if (!st.collapsed.contains(.worktrees)) {
            for (gs.rail_worktrees, 0..) |item, i| {
                const w = try worktreeShown(arena, item);
                if (!matches(filter, w.label) and !matches(filter, std.fs.path.basename(w.path))) continue;
                try out.append(arena, .{ .worktree = .{ .idx = @intCast(i), .shown = w.shown, .current = (repo_path.len > 0 and samePath(app, arena, w.path, repo_path)) or (repo_path.len == 0 and i == 0) } });
            }
        }
        try out.append(arena, .gap);
    }

    // LOCAL — A–Z, grouped by the first `/`.
    {
        var idxs: std.ArrayListUnmanaged(u32) = .empty;
        for (gs.rail_branches, 0..) |b, i| if (!b.remote and matches(filter, b.name)) try idxs.append(arena, @intCast(i));
        const Ctx = struct {
            bs: []const parse.Branch,
            fn lt(c: @This(), a: u32, b: u32) bool {
                return std.mem.lessThan(u8, c.bs[a].name, c.bs[b].name);
            }
        };
        std.mem.sort(u32, idxs.items, Ctx{ .bs = gs.rail_branches }, Ctx.lt);
        if (idxs.items.len > 0) {
            const collapsed = st.collapsed.contains(.local);
            try out.append(arena, .{ .section = .{ .s = .local, .count = @intCast(idxs.items.len), .collapsed = collapsed } });
            if (!collapsed) {
                const names = try arena.alloc([]const u8, idxs.items.len);
                for (names, idxs.items) |*n, i| n.* = gs.rail_branches[i].name;
                for (try view.groupByFolder(arena, names)) |g| {
                    const in_folder = g.folder.len > 0;
                    if (in_folder) {
                        const key = try std.fmt.allocPrint(arena, "LOCAL:{s}", .{g.folder});
                        const folded = st.isFolded(key);
                        try out.append(arena, .{ .folder = .{ .s = .local, .name = g.folder, .count = @intCast(g.idxs.len), .collapsed = folded } });
                        if (folded) continue;
                    }
                    for (g.idxs) |k| {
                        const b = gs.rail_branches[idxs.items[k]];
                        const shown = if (in_folder) b.name[g.folder.len + 1 ..] else b.name;
                        try out.append(arena, .{ .branch = .{ .idx = idxs.items[k], .shown = shown, .name = b.name, .current = b.current, .in_folder = in_folder } });
                    }
                }
            }
            try out.append(arena, .gap);
        }
    }

    // REMOTE — the host prefix stripped for display, grouped the same way.
    {
        var idxs: std.ArrayListUnmanaged(u32) = .empty;
        for (gs.rail_branches, 0..) |b, i| if (b.remote and !std.mem.endsWith(u8, b.name, "/HEAD") and matches(filter, b.name)) try idxs.append(arena, @intCast(i));
        const Ctx = struct {
            bs: []const parse.Branch,
            fn lt(c: @This(), a: u32, b: u32) bool {
                return std.mem.lessThan(u8, c.bs[a].name, c.bs[b].name);
            }
        };
        std.mem.sort(u32, idxs.items, Ctx{ .bs = gs.rail_branches }, Ctx.lt);
        if (idxs.items.len > 0) {
            const collapsed = st.collapsed.contains(.remote);
            try out.append(arena, .{ .section = .{ .s = .remote, .count = @intCast(idxs.items.len), .collapsed = collapsed } });
            if (!collapsed) {
                const stripped = try arena.alloc([]const u8, idxs.items.len);
                for (stripped, idxs.items) |*s, i| {
                    const full = gs.rail_branches[i].name;
                    s.* = if (std.mem.indexOfScalar(u8, full, '/')) |sl| full[sl + 1 ..] else full;
                }
                for (try view.groupByFolder(arena, stripped)) |g| {
                    const in_folder = g.folder.len > 0;
                    if (in_folder) {
                        const key = try std.fmt.allocPrint(arena, "REMOTE:{s}", .{g.folder});
                        const folded = st.isFolded(key);
                        try out.append(arena, .{ .folder = .{ .s = .remote, .name = g.folder, .count = @intCast(g.idxs.len), .collapsed = folded } });
                        if (folded) continue;
                    }
                    for (g.idxs) |k| {
                        const shown = if (in_folder) stripped[k][g.folder.len + 1 ..] else stripped[k];
                        try out.append(arena, .{ .remote = .{ .idx = idxs.items[k], .shown = shown, .name = gs.rail_branches[idxs.items[k]].name, .in_folder = in_folder } });
                    }
                }
            }
            try out.append(arena, .gap);
        }
    }

    // PULL REQUESTS
    if (gs.rail_prs.len > 0) {
        const collapsed = st.collapsed.contains(.prs);
        try out.append(arena, .{ .section = .{ .s = .prs, .count = @intCast(gs.rail_prs.len), .collapsed = collapsed } });
        if (!collapsed) {
            const cur = gs.branchLabel() orelse "";
            for (gs.rail_prs, 0..) |pr, i| {
                if (!matches(filter, pr.title)) continue;
                try out.append(arena, .{ .pr = .{ .idx = @intCast(i), .number = pr.number, .title = pr.title, .current = std.mem.eql(u8, pr.branch, cur) } });
            }
        }
        try out.append(arena, .gap);
    }
    return out.items;
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const st = &app.git_palette;
    const gs = &app.git;
    if (!gs.discovered) git.discover(app) catch {};
    if (gs.activeRepo() != null and gs.status == null and !gs.status_pending) git.requestStatus(app) catch {};
    if (gs.activeRepo() != null and !gs.rail_loaded and !gs.rail_pending) git.requestRail(app) catch {};
    const list = try rows(app, ui.arena);
    if (st.cursor >= list.len) st.cursor = list.len -| 1;
    const repo_name: []const u8 = if (gs.activeRepo()) |r| r.name else std.fs.path.basename(app.workspace);
    const status = gs.status;
    const painted = view.draw(ui, area, .{
        .rows = list,
        .repo = repo_name,
        .branch = gs.branchLabel(),
        .ahead = if (status) |s| s.ahead else 0,
        .behind = if (status) |s| s.behind else 0,
        .filter = st.filter.items,
        .filter_focused = st.filter_focused,
        .selected = st.selected,
        .cursor = if (list.len > 0) st.cursor else null,
        .scroll = st.scroll,
    });
    st.body_rows = painted.body_rows;
    st.total_items = painted.total_items;
    if (st.scroll > painted.total_items -| 1) st.scroll = painted.total_items -| 1;
    if (gs.busy > 0 or gs.rail_pending) @import("../ui/list_panel.zig").paintSpinner(ui, area, "GIT", app.now_ms);
}

// ─── acting on a row ────────────────────────────────────────────────────

fn rowAt(app: *App, idx: usize) Allocator.Error!?Row {
    const list = try rows(app, app.frame.allocator());
    if (idx >= list.len) return null;
    return list[idx];
}

fn setSelected(app: *App, name: ?[]const u8) Allocator.Error!void {
    const st = &app.git_palette;
    if (st.selected) |s| app.gpa.free(s);
    st.selected = if (name) |n| try app.gpa.dupe(u8, n) else null;
}

fn toggleFold(app: *App, key: []const u8) Allocator.Error!void {
    const st = &app.git_palette;
    for (st.folded.items, 0..) |f, i| if (std.mem.eql(u8, f, key)) {
        app.gpa.free(st.folded.orderedRemove(i));
        return;
    };
    try st.folded.append(app.gpa, try app.gpa.dupe(u8, key));
}

/// The branch a worktree is on, else its own name (a detached one).
fn refSha(app: *App, name: []const u8) ?[]const u8 {
    for (app.git.rail_branches) |b| if (std.mem.eql(u8, b.name, name)) return b.sha;
    return null;
}

/// Rust `git_jump_to_ref`: the active graph's cursor lands on the ref's
/// commit; the palette keeps the focus.
fn jumpToRef(app: *App, name: []const u8) Allocator.Error!void {
    const sha = refSha(app, name) orelse {
        app.toast("git: cannot resolve `{s}`", .{name});
        return;
    };
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .git_graph => |*g| if (app.layouts.current().leafOf(@intCast(i)) != null) {
            if (graph_view.findByHashPrefix(g.commits, sha)) |ci| {
                git.syncWip(app, g);
                g.cursor = g.rowOfCommit(ci);
                g.view.center_next = true;
                if (!g.wipSelected()) git.requestDetail(app, g) catch {};
                const focus = app.focus;
                app.setActive(@intCast(i));
                app.focus = focus;
                app.needs_render = true;
                return;
            }
        },
        else => {},
    };
    app.toast("git: `{s}` is not in the open graph", .{name});
}

/// Enter / a left click: a header folds, a ref jumps the graph to its
/// commit, a PR opens in the browser.
pub fn activate(app: *App, idx: usize) Allocator.Error!void {
    const st = &app.git_palette;
    const row = (try rowAt(app, idx)) orelse return;
    switch (row) {
        .gap => {},
        .section => |s| st.collapsed.toggle(s.s),
        .folder => |f| try toggleFold(app, try std.fmt.allocPrint(app.frame.allocator(), "{s}:{s}", .{ f.s.label(), f.name })),
        .worktree => |w| {
            try setSelected(app, w.shown);
            if (w.idx < app.git.rail_worktrees.len) {
                const wt = try worktreeShown(app.frame.allocator(), app.git.rail_worktrees[w.idx]);
                try jumpToRef(app, wt.label);
            }
        },
        .branch => |b| {
            try setSelected(app, b.name);
            try jumpToRef(app, b.name);
        },
        .remote => |m| {
            try setSelected(app, m.name);
            try jumpToRef(app, m.name);
        },
        .pr => |pr| if (pr.idx < app.git.rail_prs.len) git.openExternal(app, app.git.rail_prs[pr.idx].url),
    }
    app.needs_render = true;
}

/// The row's menu (Rust `open_git_rail_context_menu`).
pub fn openRowMenu(app: *App, idx: usize, x: u16, y: u16) Allocator.Error!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const row = (try rowAt(app, idx)) orelse return;
    switch (row) {
        .branch => |b| {
            const name = b.name;
            const items: []const MenuItem = if (b.current) &.{
                .{ .label = "New branch from here\u{2026}", .action = .{ .git_palette = .{ .what = .new_branch, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Copy name ({s})", .{name}), .action = .{ .git_palette = .{ .what = .copy_name, .idx = b.idx } } },
            } else &.{
                .{ .label = try std.fmt.allocPrint(arena, "Checkout {s}", .{name}), .action = .{ .git_palette = .{ .what = .checkout, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Merge {s} into current", .{name}), .action = .{ .git_palette = .{ .what = .merge, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Rebase current onto {s}", .{name}), .action = .{ .git_palette = .{ .what = .rebase, .idx = b.idx } } },
                .{ .label = "New branch from here\u{2026}", .action = .{ .git_palette = .{ .what = .new_branch, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Copy name ({s})", .{name}), .action = .{ .git_palette = .{ .what = .copy_name, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Delete {s}\u{2026}", .{name}), .action = .{ .git_palette = .{ .what = .delete_branch, .idx = b.idx } } },
            };
            try app.openMenu(if (b.current) try std.fmt.allocPrint(arena, "\u{25CF} {s}", .{name}) else name, try gpa.dupe(MenuItem, items), x, y);
        },
        .remote => |m| {
            const items = try gpa.dupe(MenuItem, &.{
                .{ .label = try std.fmt.allocPrint(arena, "Checkout {s}", .{m.name}), .action = .{ .git_palette = .{ .what = .checkout, .idx = m.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Copy name ({s})", .{m.name}), .action = .{ .git_palette = .{ .what = .copy_name, .idx = m.idx } } },
            });
            try app.openMenu(m.name, items, x, y);
        },
        .worktree => |w| {
            if (w.idx >= app.git.rail_worktrees.len) return;
            const wt = try worktreeShown(arena, app.git.rail_worktrees[w.idx]);
            var items: std.ArrayListUnmanaged(MenuItem) = .empty;
            errdefer items.deinit(gpa);
            try items.append(gpa, .{ .label = "Open shell here", .action = .{ .git_palette = .{ .what = .worktree_shell, .idx = w.idx } } });
            try items.append(gpa, .{ .label = "Copy path", .action = .{ .git_palette = .{ .what = .worktree_copy_path, .idx = w.idx } } });
            try items.append(gpa, .{ .label = "New worktree\u{2026}", .action = .{ .command = .@"git.worktree_add" } });
            if (!w.current) try items.append(gpa, .{ .label = "Remove worktree\u{2026}", .action = .{ .git_palette = .{ .what = .worktree_remove, .idx = w.idx } } });
            try app.openMenu(try std.fmt.allocPrint(arena, "{s}  {s}", .{ wt.label, wt.path }), try items.toOwnedSlice(gpa), x, y);
        },
        .pr => |pr| {
            if (pr.idx >= app.git.rail_prs.len) return;
            const p = app.git.rail_prs[pr.idx];
            const items = try gpa.dupe(MenuItem, &.{
                .{ .label = "Open in browser", .action = .{ .git_palette = .{ .what = .pr_open, .idx = pr.idx } } },
                .{ .label = "Copy URL", .action = .{ .git_palette = .{ .what = .pr_copy, .idx = pr.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Checkout branch ({s})", .{p.branch}), .action = .{ .git_palette = .{ .what = .checkout, .idx = pr.idx } } },
            });
            try app.openMenu(try std.fmt.allocPrint(arena, "#{d} \u{2014} {s}", .{ p.number, p.title }), items, x, y);
        },
        .section, .folder, .gap => {},
    }
}

/// A menu row picked.
pub fn menuAction(app: *App, a: MenuAct) Allocator.Error!void {
    const gs = &app.git;
    const gpa = app.gpa;
    const result: CommandError!void = blk: {
        switch (a.what) {
            .switch_repo => break :blk git.switchTo(app, a.idx),
            .reopen_repo => break :blk reopen(app, a.idx),
            .pr_open, .pr_copy => {
                if (a.idx >= gs.rail_prs.len) break :blk;
                const url = gs.rail_prs[a.idx].url;
                if (a.what == .pr_open) git.openExternal(app, url) else {
                    try app.clipboard.setYank(url, false);
                    app.toast("copied {s}", .{url});
                }
                break :blk;
            },
            .worktree_shell, .worktree_copy_path, .worktree_remove => {
                if (a.idx >= gs.rail_worktrees.len) break :blk;
                const wt = try worktreeShown(app.frame.allocator(), gs.rail_worktrees[a.idx]);
                switch (a.what) {
                    .worktree_copy_path => {
                        try app.clipboard.setYank(wt.path, false);
                        app.toast("copied {s}", .{wt.path});
                    },
                    .worktree_shell => break :blk command.run(app, .{ .static = .@"git.worktrees" }),
                    else => break :blk git.openConfirm(app, .{ .worktree_remove = try gpa.dupe(u8, wt.path) }, try std.fmt.allocPrint(gpa, "  Remove worktree {s}?", .{wt.path})),
                }
                break :blk;
            },
            else => {},
        }
        // The branch actions: `idx` is a rail branch, or a PR's branch.
        const name: []const u8 = if (a.what == .checkout and a.idx < gs.rail_prs.len and a.idx >= gs.rail_branches.len) gs.rail_prs[a.idx].branch else if (a.idx < gs.rail_branches.len) gs.rail_branches[a.idx].name else break :blk;
        const repo = git.requireRepo(app) catch |err| break :blk err;
        switch (a.what) {
            .checkout => {
                // A remote ref checks out as a local branch of its short name.
                const b = if (a.idx < gs.rail_branches.len) gs.rail_branches[a.idx] else null;
                const local = if (b != null and b.?.remote) (if (std.mem.indexOfScalar(u8, name, '/')) |s| name[s + 1 ..] else name) else name;
                break :blk git.submitOp(app, repo, .{ .checkout = try gpa.dupe(u8, local) });
            },
            .merge => break :blk git.submitOp(app, repo, .{ .merge = try gpa.dupe(u8, name) }),
            .rebase => break :blk git.submitOp(app, repo, .{ .rebase = try gpa.dupe(u8, name) }),
            .new_branch => break :blk command.run(app, .{ .static = .@"git.new_branch" }),
            .delete_branch => break :blk git.openConfirm(app, .{ .delete_branch = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "  Delete branch {s}? (git branch -D)", .{name})),
            .copy_name => {
                try app.clipboard.setYank(name, false);
                app.toast("copied {s}", .{name});
            },
            else => {},
        }
    };
    git.runToast(app, result);
}

// ─── mouse (D6) ─────────────────────────────────────────────────────────

pub fn focusPalette(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .git };
    app.needs_render = true;
}

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.git_palette;
    switch (m.kind) {
        .press => {
            st.filter_focused = false;
            focusPalette(app);
            st.cursor = idx;
            switch (m.button) {
                .left => try activate(app, idx),
                .right => try openRowMenu(app, idx, m.x, m.y),
                else => {},
            }
        },
        .scroll_up => st.scroll -|= 3,
        .scroll_down => st.scroll = @min(st.scroll + 3, st.total_items -| 1),
        else => {},
    }
    app.needs_render = true;
}

pub fn partMouse(app: *App, part: Part, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    app.git_palette.filter_focused = false;
    focusPalette(app);
    switch (part) {
        .repo => try openReposMenu(app, m.x, m.y + 1),
        .branch => if (m.button == .left) git.runToast(app, command.run(app, .{ .static = .@"git.checkout" })) else try openReposMenu(app, m.x, m.y + 1),
    }
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .refresh => {
            git.runToast(app, git.discover(app));
            if (app.git.activeRepo() != null) {
                app.git.status_pending = false;
                git.runToast(app, git.requestStatus(app));
                git.runToast(app, git.requestRail(app));
            }
            app.toast("git: refreshed", .{});
        },
        else => {},
    }
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPalette(app);
    app.git_palette.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.git_palette;
    const total = st.total_items;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPalette(app);
            const off: usize = m.y -| bar.y;
            st.scroll = @min(off * total / bar.h, total - 1);
        },
        .scroll_up => st.scroll -|= 3,
        .scroll_down => st.scroll = @min(st.scroll + 3, total - 1),
        else => {},
    }
    app.needs_render = true;
}

/// The wheel anywhere over the palette.
pub fn wheel(app: *App, down: bool) void {
    const st = &app.git_palette;
    if (down) st.scroll = @min(st.scroll + 3, st.total_items -| 1) else st.scroll -|= 3;
    app.needs_render = true;
}

// ─── keys ───────────────────────────────────────────────────────────────

fn step(app: *App, list: []const Row, from: usize, down: bool) usize {
    _ = app;
    if (list.len == 0) return 0;
    var i = from;
    while (true) {
        if (down) {
            if (i + 1 >= list.len) return from;
            i += 1;
        } else {
            if (i == 0) return from;
            i -= 1;
        }
        if (list[i] != .gap) return i;
    }
}

/// The palette's keys: the filter when it has focus (Esc clears then
/// blurs, Enter blurs), else j/k and the arrows over the rows, Enter
/// acts, `m` opens the row's menu, `/` focuses the filter, `r`
/// refreshes, `c` commits, Esc hands the focus to the graph.
pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.git_palette;
    const list = try rows(app, app.frame.allocator());
    if (st.filter_focused) {
        switch (k.code) {
            .esc => {
                if (st.filter.items.len > 0) {
                    st.filter.clearRetainingCapacity();
                    st.filter_caret = 0;
                } else st.filter_focused = false;
            },
            .enter => st.filter_focused = false,
            .up => st.cursor = step(app, list, st.cursor, false),
            .down => st.cursor = step(app, list, st.cursor, true),
            else => {
                if (try text_field.handleKey(&st.filter, &st.filter_caret, app.gpa, k) == .ignored) return false;
                st.scroll = 0;
            },
        }
        app.needs_render = true;
        return true;
    }
    switch (k.code) {
        .up => st.cursor = step(app, list, st.cursor, false),
        .down => st.cursor = step(app, list, st.cursor, true),
        .home => st.cursor = 0,
        .end => st.cursor = list.len -| 1,
        .enter => try activate(app, st.cursor),
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                'j' => st.cursor = step(app, list, st.cursor, true),
                'k' => st.cursor = step(app, list, st.cursor, false),
                'g' => st.cursor = 0,
                'G' => st.cursor = list.len -| 1,
                '/' => st.filter_focused = true,
                'm' => try openRowMenu(app, st.cursor, 6, 8),
                'r' => try chipMouse(app, .refresh, .{ .x = 0, .y = 0, .kind = .press, .button = .left }),
                'c' => git.runToast(app, command.run(app, .{ .static = .@"git.commit" })),
                'n' => git.runToast(app, command.run(app, .{ .static = .@"git.new_branch" })),
                else => return false,
            }
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "rows: worktrees, local A–Z with the current one marked, remotes stripped of the host, a filter narrows and empties sections, a fold keeps its header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = buf[0..n], .data_root = buf[0..n], .cols = 120, .rows = 40 });
    defer app.deinit();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const bs = [_]parse.Branch{
        .{ .name = "main", .time = 0, .current = true, .remote = false, .sha = "aaaa" },
        .{ .name = "feature", .time = 0, .current = false, .remote = false, .sha = "bbbb" },
        .{ .name = "bugfix/two", .time = 0, .current = false, .remote = false },
        .{ .name = "bugfix/one", .time = 0, .current = false, .remote = false },
        .{ .name = "origin/main", .time = 0, .current = false, .remote = true },
        .{ .name = "origin/HEAD", .time = 0, .current = false, .remote = true },
    };
    app.git.rail_branches = @constCast(&bs);
    const wts = [_][]const u8{ "/repo/ws\x1fmain", "/repo/wt-feature\x1ffeature" };
    app.git.rail_worktrees = &wts;
    var list = try rows(&app, arena);
    // WORKTREES 2, gap, LOCAL 4 (bugfix folder first), gap, REMOTE 1, gap.
    try testing.expectEqual(@as(usize, 14), list.len);
    try testing.expectEqual(Section.worktrees, list[0].section.s);
    try testing.expectEqualStrings("main (ws)", list[1].worktree.shown);
    try testing.expectEqualStrings("feature (wt-feature)", list[2].worktree.shown);
    try testing.expect(list[3] == .gap);
    try testing.expectEqual(@as(u32, 4), list[4].section.count);
    try testing.expectEqualStrings("bugfix", list[5].folder.name);
    try testing.expectEqualStrings("one", list[6].branch.shown);
    try testing.expectEqualStrings("bugfix/one", list[6].branch.name);
    try testing.expect(list[6].branch.in_folder);
    try testing.expectEqualStrings("two", list[7].branch.shown);
    try testing.expectEqualStrings("feature", list[8].branch.shown);
    try testing.expectEqualStrings("main", list[9].branch.shown);
    try testing.expect(list[9].branch.current);
    try testing.expect(list[10] == .gap);
    try testing.expectEqual(@as(u32, 1), list[11].section.count);
    try testing.expectEqualStrings("main", list[12].remote.shown);
    try testing.expectEqualStrings("origin/main", list[12].remote.name);
    // The filter keeps LOCAL's matches and drops the sections without any.
    try app.git_palette.filter.appendSlice(testing.allocator, "feat");
    list = try rows(&app, arena);
    try testing.expectEqual(@as(usize, 6), list.len);
    try testing.expectEqualStrings("feature (wt-feature)", list[1].worktree.shown);
    try testing.expectEqualStrings("feature", list[4].branch.shown);
    app.git_palette.filter.clearRetainingCapacity();
    // A folded LOCAL keeps its header and count; a folded folder its row.
    app.git_palette.collapsed.insert(.local);
    list = try rows(&app, arena);
    try testing.expectEqual(@as(u32, 4), list[4].section.count);
    try testing.expect(list[4].section.collapsed);
    try testing.expect(list[5] == .gap);
    app.git_palette.collapsed.remove(.local);
    try toggleFold(&app, "LOCAL:bugfix");
    list = try rows(&app, arena);
    try testing.expect(list[5].folder.collapsed);
    try testing.expectEqualStrings("feature", list[6].branch.shown);
    // Enter on a header folds it; on a branch it selects and jumps.
    try activate(&app, 0);
    try testing.expect(app.git_palette.collapsed.contains(.worktrees));
    list = try rows(&app, arena);
    try activate(&app, 4);
    try testing.expectEqualStrings("feature", app.git_palette.selected.?);
    app.git.rail_branches = &.{};
    app.git.rail_worktrees = &.{};
}
