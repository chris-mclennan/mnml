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
//! the same list, so a row index means the same thing in both. Five
//! sections in a fixed order: LOCAL, REMOTE (each remote with its
//! branches under it), WORKTREES, STASHES, TAGS. A section folds on a
//! click on its header or Enter; the folds live in `State.collapsed`
//! for the whole run (they survive leaving and re-entering the mode
//! and switching repos).
//!
//! The pill names the repo the rows read; its chevrons (`[` / `]`)
//! step through the discovered repos in order, wrapping. The pill's
//! menu also offers `All repos` (`State.all`, kept in the session
//! file): every open repo's rail is listed at once, each section
//! grouped under a muted sub-header per repo — a row's action is its
//! own repo's, so acting on one first makes that repo the active one
//! (`git.switchTo` moves the parked rail into `rail_*`, its graph tab
//! comes to the front) and then runs as it does with one repo.
//!
//! The mouse follows the reference client: one click on an item row is
//! a hover — the keys go to the panel and nothing is selected (the
//! cursor stays where the keys left it; `j` / `k` move it). A
//! DOUBLE-CLICK acts, as Enter does on the cursor row: a local branch
//! checks out, a remote branch becomes a local tracking branch of its
//! short name, a worktree opens (its directory joins the tree as a
//! workspace root and the graph tab switches to it — the tab's name
//! and its content are that worktree's), a stash shows its files, a
//! tag checks out detached after the confirm. A right-click opens the
//! row's menu, built from the row under the pointer, and leaves the
//! cursor alone. A section header or a repo sub-header is no item: one
//! click folds it / shows that repo. The row menus do the rest (pop /
//! drop a stash, delete a tag, remove a worktree, …).
//! // changed (git-panel): the Rust panel selects on one click and acts
//! on the second click of the selected row; the double-click model is
//! the user's call (2026-09-15).
//!
//! // changed: Rust keeps `active_section` and `pre_git_layout` on the
//! app; here the mode is `State.active` and the stash `State.pre`, and
//! `activity_bar.enter` is the one place every other section leaves it.
//! // changed (git-palette): the branches panel replaces Rust's GIT
//! header / `⎇ branch` row / folder-grouped LOCAL / PULL REQUESTS; the
//! Rust dump's sidebar rows are the accepted difference.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const PaneId = app_mod.PaneId;
const Io = std.Io;
const dispatch = @import("dispatch.zig");
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
const side = @import("side.zig");
const graph_view = @import("../ui/git_graph_view.zig");
const list_panel = @import("../ui/list_panel.zig");
const pty_pane = @import("pty_pane.zig");
const cmd_tab = @import("cmd_tab.zig");
const files_pane = @import("files_pane.zig");
const remote_mod = @import("../git/remote.zig");
const settings = @import("settings.zig");
const alloc = @import("../core/alloc.zig");
const context_menus = @import("context_menus.zig");
const accent_color = @import("../ui/accent_color.zig");
const sessions = @import("../sessions.zig");
const session_worktree = @import("session_worktree.zig");
const Theme = @import("../ui/theme.zig");

pub const Section = view.Section;
pub const Row = view.Row;
pub const Part = view.Part;

/// A row menu's action, with the index the row named.
pub const MenuAct = command.GitPaletteAct;

const Stash = struct { layout: Layout, active: ?PaneId };
pub const PreSize = struct { side: side.Side, n: u16 };

pub const State = struct {
    /// Git is the active section.
    active: bool = false,
    /// The layout that was showing before Git took it over.
    pre: ?Stash = null,
    /// The width of the palette's column before the mode's snap took it
    /// to a fifth of the screen, and the column it was — what `leave`
    /// puts back. The sections share one column width; the snap is the
    /// mode's, so the explorer (or whatever follows) gets the column
    /// back at the width it had, never at the git mode's.
    pre_size: ?PreSize = null,
    /// Repos whose tab was closed this session (their paths, owned):
    /// not reopened on re-entry until `reopen`.
    closed: std.ArrayListUnmanaged([]u8) = .empty,
    /// The folded sections, kept for the run.
    collapsed: std.enums.EnumSet(Section) = .initEmpty(),
    /// All repos: every open repo's rows at once, grouped per repo.
    /// Saved with the session.
    all: bool = false,
    filter: text_field.Buf = .empty,
    filter_caret: usize = 0,
    filter_focused: bool = false,
    /// The last selected ref's name (a click, Enter). Owned.
    selected: ?[]u8 = null,
    scroll: usize = 0,
    /// The keyboard cursor over the rows.
    cursor: usize = 0,
    /// What the last paint measured: rows of room, rows in all.
    visible: usize = 0,
    total: usize = 0,
    /// // changed (colors): the repo accents by name — what the home
    /// config's `git.repo_colors` holds plus this run's assignments,
    /// `none` for an auto slot. Owned.
    colors: std.ArrayListUnmanaged(RepoColor) = .empty,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.pre) |*p| p.layout.deinit();
        for (self.closed.items) |c| gpa.free(c);
        self.closed.deinit(gpa);
        for (self.colors.items) |c| {
            gpa.free(c.name);
            gpa.free(c.color);
        }
        self.colors.deinit(gpa);
        self.filter.deinit(gpa);
        if (self.selected) |s| gpa.free(s);
        self.* = .{};
    }

    pub fn isClosed(self: *const State, path: []const u8) bool {
        for (self.closed.items) |c| if (std.mem.eql(u8, c, path)) return true;
        return false;
    }
};

pub const RepoColor = struct { name: []u8, color: []u8 };

test "remove worktree and delete branch: the confirm names the tree, the branch and the dirty count; Remove refuses a dirty tree and names Force, Force sends it; the main tree, the tree on show and a branchless tree are refused by name" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    seed(app);
    // The main tree (the workspace) and, with its `main` flag off, the
    // tree the panels are showing.
    try testing.expectError(error.Failed, confirmRemoveWorktreeBranch(app, seed_worktrees[0]));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "main worktree") != null);
    app.diag.clear();
    var on_show = seed_worktrees[0];
    on_show.main = false;
    on_show.path = app.git.activeRepo().?.path;
    on_show.branch = "main";
    try testing.expectError(error.Failed, confirmRemoveWorktreeBranch(app, on_show));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "tree on show") != null);
    app.diag.clear();
    // A detached tree has no branch to delete.
    var detached = seed_worktrees[1];
    detached.branch = "";
    try testing.expectError(error.Failed, confirmRemoveWorktreeBranch(app, detached));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "no branch of its own") != null);
    app.diag.clear();

    // The linked tree: the confirm names both, and its dirty count.
    try confirmRemoveWorktreeBranch(app, seed_worktrees[1]);
    try testing.expect(app.overlay == .confirm);
    try testing.expectEqualStrings("Remove worktree", app.overlay.confirm.state.title);
    const msg = app.overlay.confirm.state.message;
    try testing.expect(std.mem.indexOf(u8, msg, "/repo/wt-fix") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "delete branch fix") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "2 uncommitted files") != null);
    try testing.expectEqual(@as(usize, 3), app.overlay.confirm.state.choices.len);
    try testing.expectEqualStrings("Force", app.overlay.confirm.state.choices[1].label);

    // Remove on a dirty tree refuses and names the way through.
    const busy_before = app.git.busy;
    try testing.expectError(error.Failed, git.acceptConfirm(app, 0));
    try testing.expect(std.mem.indexOf(u8, app.diag.msg.?, "pick Force") != null);
    app.diag.clear();
    try testing.expectEqual(busy_before, app.git.busy);

    // Force sends it to the worker.
    try confirmRemoveWorktreeBranch(app, seed_worktrees[1]);
    try git.acceptConfirm(app, 1);
    try testing.expectEqual(busy_before + 1, app.git.busy);
    try testing.expect(app.git.confirm == .none);

    // Cancel sends nothing.
    try confirmRemoveWorktreeBranch(app, seed_worktrees[1]);
    try git.acceptConfirm(app, 2);
    try testing.expectEqual(busy_before + 1, app.git.busy);
}

// ─── the accent (colors) ────────────────────────────────────────────────

/// Repo accents tell repos apart, so a workspace with one repo shows
/// none — as the tree marks repo rows only past one.
pub fn colorsShown(app: *const App) bool {
    return app.git.repos.items.len >= 2;
}

fn storedColor(app: *const App, name: []const u8) ?[]const u8 {
    for (app.git_palette.colors.items) |c| if (std.mem.eql(u8, c.name, name)) return c.color;
    return app.cfg.git.repo_colors.get(name);
}

/// The palette name repo `idx` paints with: the stored one (this run's
/// or the home config's), else its slot in discovery order; null with
/// fewer than two repos, or past the list.
pub fn repoColorName(app: *const App, idx: usize) ?[]const u8 {
    if (!colorsShown(app)) return null;
    if (idx >= app.git.repos.items.len) return null;
    const r = app.git.repos.items[idx];
    if (storedColor(app, r.name)) |c| if (accent_color.canonical(c)) |canon| return canon;
    return accent_color.auto(idx);
}

/// The accent of the repo with `id`, resolved on the theme.
pub fn repoAccent(app: *const App, id: u32) ?Theme.Color {
    const idx = app.git.indexOfId(id) orelse return null;
    const name = repoColorName(app, idx) orelse return null;
    return accent_color.resolve(name, &app.theme);
}

fn rememberColor(app: *App, name: []const u8, color: []const u8) Allocator.Error!void {
    const st = &app.git_palette;
    const fresh = try app.gpa.dupe(u8, color);
    errdefer app.gpa.free(fresh);
    for (st.colors.items) |*c| if (std.mem.eql(u8, c.name, name)) {
        app.gpa.free(c.color);
        c.color = fresh;
        return;
    };
    const owned = try app.gpa.dupe(u8, name);
    errdefer app.gpa.free(owned);
    try st.colors.append(app.gpa, .{ .name = owned, .color = fresh });
}

/// Every repo without a stored colour takes its slot, written to the
/// home config's `git.repo_colors` so it holds across restarts (the
/// first assignment wins); nothing with fewer than two repos. Cheap
/// once every repo is known.
pub fn ensureRepoColors(app: *App) Allocator.Error!void {
    if (!colorsShown(app)) return;
    for (app.git.repos.items, 0..) |r, i| {
        if (storedColor(app, r.name) != null) continue;
        const slot = accent_color.auto(i);
        try rememberColor(app, r.name, slot);
        if ((try settings.configPath(app, .home)) != null) _ = try settings.persist(app, .home, &.{ "git", "repo_colors", r.name }, slot);
    }
}

/// A `Color: …` row on the pill's menu: `name` becomes repo `idx`'s
/// accent, `none` puts it back on its slot; both persist home.
pub fn setRepoColor(app: *App, idx: u32, name: []const u8) Allocator.Error!void {
    if (idx >= app.git.repos.items.len) return;
    const r = app.git.repos.items[idx];
    const value: []const u8 = accent_color.canonical(name) orelse accent_color.none;
    try rememberColor(app, r.name, value);
    if ((try settings.configPath(app, .home)) != null) _ = try settings.persist(app, .home, &.{ "git", "repo_colors", r.name }, value);
    app.needs_render = true;
}

/// The pill's right-click: `Color: …` per palette entry in order, then
/// `Color: Auto`, the current one ticked — for the active repo (All
/// repos has none).
pub fn openRepoColorMenu(app: *App, x: u16, y: u16) Allocator.Error!void {
    const gs = &app.git;
    const idx = gs.active orelse return;
    if (idx >= gs.repos.items.len or !colorsShown(app)) return;
    const stored = storedColor(app, gs.repos.items[idx].name);
    const override: ?[]const u8 = if (stored) |s| accent_color.canonical(s) else null;
    var items: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer items.deinit(app.gpa);
    for (accent_color.palette) |name| try items.append(app.gpa, .{
        .label = accent_color.label(name),
        .action = .{ .repo_color = .{ .idx = @intCast(idx), .name = name } },
        .checked = if (override) |o| std.mem.eql(u8, o, name) else false,
    });
    try items.append(app.gpa, .{
        .label = accent_color.label(accent_color.none),
        .action = .{ .repo_color = .{ .idx = @intCast(idx), .name = accent_color.none } },
        .checked = override == null,
        .separator_before = true,
    });
    const title = try std.fmt.allocPrint(app.frame.allocator(), "{s} · color", .{gs.repos.items[idx].name});
    try app.openMenu(title, try items.toOwnedSlice(app.gpa), x, y);
}

/// The repo's gutter on a pane that belongs to it — a one-cell `▌`
/// down the left edge in the repo's accent, as the pty identity strip
/// — and the rect left for the pane's own painter. `area` itself when
/// the repo has no accent.
pub fn repoGutter(app: *const App, ui: Ui, repo_id: u32, area: Rect) Rect {
    const accent = repoAccent(app, repo_id) orelse return area;
    if (area.w < 2 or area.h == 0) return area;
    const bar = Rect.init(area.x, area.y, 1, area.h);
    ui.fill(bar, ui.theme.bg);
    const glyph = if (ui.ascii) list_panel.marker_ascii else list_panel.marker_glyph;
    var y: u16 = 0;
    while (y < area.h) : (y += 1) _ = ui.putStr(area.x, area.y + y, 1, glyph, Theme.withFg(ui.theme.bg, accent));
    return Rect.init(area.x + 1, area.y, area.w - 1, area.h);
}

// ─── entering and leaving ───────────────────────────────────────────────

/// Rust's snap: the palette's column takes a fifth of the screen when
/// that is at least eight cells (`side.snapGit`), and shows the palette.
pub fn snapSidebar(app: *App) void {
    side.snapGit(app);
    side.place(app, .git, false);
}

/// Enter git mode (idempotent): the sidebar becomes the palette, the
/// layout one graph tab per open repo, the palette takes the keys.
pub fn enter(app: *App) CommandError!void {
    const st = &app.git_palette;
    // Rediscovered on every entry: the workspace roots may have landed
    // after the first tick's look, and a repo may have been made since.
    try git.discover(app);
    if (!st.active) {
        const gs = side.sideOf(app, .git);
        st.pre_size = if (gs == .bottom) null else .{ .side = gs, .n = side.size(app, gs) };
    }
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

/// A column's width as the session should remember it: the width it
/// had before git mode's snap while the mode holds it, so a session
/// saved in the mode does not bring the explorer back at a fifth.
pub fn restingSize(app: *const App, s: side.Side) u16 {
    if (app.git_palette.active) if (app.git_palette.pre_size) |ps| if (ps.side == s) return ps.n;
    return side.size(app, s);
}

/// Leave git mode: the stashed layout comes back, the graph panes stay
/// in the store. A no-op outside the mode.
pub fn leave(app: *App) void {
    const st = &app.git_palette;
    if (!st.active) return;
    st.active = false;
    st.filter_focused = false;
    if (st.pre_size) |ps| side.setSize(app, ps.side, ps.n);
    st.pre_size = null;
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
    // The palette leaves its column; the explorer takes the column back
    // when it is its own (Rust's tree returns with the layout).
    side.remove(app, .git);
    if (side.sideOf(app, .explorer) == side.sideOf(app, .git) and side.shown(app, side.sideOf(app, .git)) == null) side.place(app, .explorer, false);
    if (app.focus == .panel and app.focus.panel == .git) app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    app.needs_render = true;
}

/// `git.branch_rail_toggle`: in and out of the mode.
pub fn toggle(app: *App) CommandError!void {
    if (app.git_palette.active) {
        leave(app);
        side.place(app, .explorer, true);
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
    var active_tab: ?PaneId = null;
    var leaf: ?layout_mod.NodeId = null;
    for (repos.items) |r| {
        const id = try git.ensureGraphPane(app, r);
        leaf = try layout.showIn(leaf, id);
        if (first == null) first = id;
        if (prev_repo != null and prev_repo.? == r.id) want = id;
        if (gs.activeRepo()) |ar| if (ar.id == r.id) {
            active_tab = id;
        };
    }
    // The tab shown: the graph that was active, else the ACTIVE repo's
    // (the workspace root's, unless the panel switched) — Rust's
    // `open_git_graph` — and only then the first.
    app.setActive(want orelse active_tab orelse first);
    app.afterSplitChange();
}

/// A repo a closed tab hid comes back when a command asks for it by
/// name. True when it was hidden.
pub fn unclose(app: *App, path: []const u8) bool {
    const st = &app.git_palette;
    for (st.closed.items, 0..) |c, i| if (std.mem.eql(u8, c, path)) {
        app.gpa.free(st.closed.orderedRemove(i));
        return true;
    };
    return false;
}

/// The ACTIVE repo's graph is the tab shown — `git.graph` and the
/// commit box land there, never on whichever repo's tab was first —
/// reopened when an `esc` on it had closed it (the close hides the
/// repo for the session; asking for its graph un-hides it).
pub fn showActiveGraph(app: *App) CommandError!PaneId {
    const repo = try git.requireRepo(app);
    if (unclose(app, repo.path) and app.git_palette.active) try rebuildTabs(app);
    const id = try git.ensureGraphPane(app, repo);
    app.showPane(id);
    return id;
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
    // The labels outlive this frame — the menu stays open — so they
    // live on an arena the menu owns, not the frame's (which the next
    // frame reuses: every row past the first painted whatever the
    // frame wrote there).
    var mem = std.heap.ArenaAllocator.init(gpa);
    errdefer mem.deinit();
    const a = mem.allocator();
    var items: std.ArrayListUnmanaged(MenuItem) = .empty;
    errdefer items.deinit(gpa);
    try items.append(gpa, .{
        .label = if (st.all) "\u{25CF} All repos" else "  All repos",
        .action = .{ .git_palette = .{ .what = .all_repos, .idx = 0 } },
    });
    for (gs.repos.items, 0..) |r, i| {
        try items.append(gpa, .{
            .label = try std.fmt.allocPrint(a, "{s}{s}", .{ if (!st.all and gs.active != null and gs.active.? == i) "\u{25CF} " else "  ", r.name }),
            .action = .{ .git_palette = .{ .what = .switch_repo, .idx = @intCast(i) } },
        });
    }
    for (st.closed.items, 0..) |p, i| {
        try items.append(gpa, .{
            .label = try std.fmt.allocPrint(a, "  Reopen: {s}", .{std.fs.path.basename(p)}),
            .action = .{ .git_palette = .{ .what = .reopen_repo, .idx = @intCast(i) } },
        });
    }
    try items.append(gpa, .{ .label = "  Add workspace\u{2026}", .action = .{ .command = .@"view.add_workspace" } });
    try context_menus.openOwned(app, "Repos", try items.toOwnedSlice(gpa), x, y, mem);
}

// ─── which repo ─────────────────────────────────────────────────────────

/// `idx` becomes the active repo and its graph tab comes to the front;
/// the palette keeps the focus.
pub fn selectRepo(app: *App, idx: usize) CommandError!void {
    const gs = &app.git;
    if (idx >= gs.repos.items.len) return;
    try git.switchTo(app, idx);
    showRepoTab(app, idx);
}

/// After a workspace switch (`workspace_switch.zig`): in git mode the
/// tabs are rebuilt for the new repo list and the active repo's graph
/// comes to the front. Nothing outside the mode.
pub fn followActiveRepo(app: *App) CommandError!void {
    if (!app.git_palette.active) return;
    try rebuildTabs(app);
    if (app.git.active) |i| showRepoTab(app, i);
}

/// The graph tab of repo `idx` comes to the front, when it is open.
fn showRepoTab(app: *App, idx: usize) void {
    const gs = &app.git;
    if (idx >= gs.repos.items.len) return;
    const id = gs.repos.items[idx].id;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .git_graph => |*g| if (g.repo == id and app.layouts.current().leafOf(@intCast(i)) != null) {
            const focus = app.focus;
            app.setActive(@intCast(i));
            app.focus = focus;
            app.needs_render = true;
            return;
        },
        else => {},
    };
}

/// `]` / `[` and the pill's chevrons: the next / previous repo in
/// discovery order, wrapping; under All repos the first / last, which
/// leaves it. Nothing to step through with one repo.
pub fn stepRepo(app: *App, forward: bool) CommandError!void {
    const st = &app.git_palette;
    const gs = &app.git;
    const n = gs.repos.items.len;
    if (n < 2) return;
    var idx: usize = undefined;
    if (st.all) {
        idx = if (forward) 0 else n - 1;
        st.all = false;
    } else {
        const cur = gs.active orelse 0;
        idx = if (forward) (cur + 1) % n else (cur + n - 1) % n;
    }
    st.cursor = 0;
    st.scroll = 0;
    try selectRepo(app, idx);
}

/// All repos on or off; on asks every open repo for its rail.
pub fn setAll(app: *App, on: bool) CommandError!void {
    const st = &app.git_palette;
    if (st.all == on) return;
    st.all = on;
    st.cursor = 0;
    st.scroll = 0;
    if (on) try requestRailAll(app, false);
    app.needs_render = true;
}

/// `git.palette_all`: All repos toggles (entering the mode first).
pub fn toggleAll(app: *App) CommandError!void {
    const st = &app.git_palette;
    if (!st.active) try enter(app);
    try setAll(app, !st.all);
}

/// Every open repo asked for its rail; `force` asks again for the
/// ones that have landed.
fn requestRailAll(app: *App, force: bool) CommandError!void {
    const st = &app.git_palette;
    const gs = &app.git;
    for (gs.repos.items) |r| if (!st.isClosed(r.path)) try git.requestRailFor(app, r, force);
}

/// The repo a row belongs to under All repos: the sub-header above it
/// (null on a section header, or with one repo).
fn repoOfRow(list: []const Row, idx: usize) ?u32 {
    var i = idx + 1;
    while (i > 0) : (i -= 1) switch (list[i - 1]) {
        .repo => |r| return r.idx,
        .section, .gap => return null,
        else => {},
    };
    return null;
}

/// Under All repos a row's action is its own repo's: that repo becomes
/// the active one before the action reads the rail by the row's index.
/// The rows' slices stay valid — `git.switchTo` moves the arenas.
fn switchToRowRepo(app: *App, idx: usize) Allocator.Error!void {
    const st = &app.git_palette;
    const gs = &app.git;
    if (!st.all) return;
    const list = try rows(app, app.frame.allocator());
    if (idx >= list.len) return;
    const ri = repoOfRow(list, idx) orelse return;
    if (gs.active != null and gs.active.? == ri) return;
    git.runToast(app, selectRepo(app, ri));
}

// ─── the rows ───────────────────────────────────────────────────────────

fn matches(filter: []const u8, s: []const u8) bool {
    if (filter.len == 0) return true;
    if (filter.len > s.len) return false;
    var i: usize = 0;
    while (i + filter.len <= s.len) : (i += 1) if (std.ascii.eqlIgnoreCase(s[i .. i + filter.len], filter)) return true;
    return false;
}

/// A worktree's text: `branch (dir)`, the branch alone when it is the
/// directory's name, `dir (detached)` for a tree on no branch.
fn worktreeShown(arena: Allocator, w: parse.Worktree) Allocator.Error![]const u8 {
    const label = w.label();
    const dir = std.fs.path.basename(w.path);
    if (std.mem.eql(u8, label, dir)) return label;
    if (label.len > 0 and label[0] == '(') return try std.fmt.allocPrint(arena, "{s} {s}", .{ dir, label });
    return try std.fmt.allocPrint(arena, "{s} ({s})", .{ label, dir });
}

/// Whether two directory paths name the same place, through symlinks
/// (`git worktree list` prints the real path; a workspace may not be).
fn samePath(app: *App, arena: Allocator, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const ra = std.Io.Dir.realPathFileAbsoluteAlloc(app.io, a, arena) catch return false;
    const rb = std.Io.Dir.realPathFileAbsoluteAlloc(app.io, b, arena) catch return false;
    return std.mem.eql(u8, ra, rb);
}

/// The rail branch of `name`, if listed.
fn branchNamed(branches: []const parse.Branch, name: []const u8) ?parse.Branch {
    for (branches) |b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}

const SortCtx = struct {
    bs: []const parse.Branch,
    fn lt(c: @This(), a: u32, b: u32) bool {
        return std.mem.lessThan(u8, c.bs[a].name, c.bs[b].name);
    }
};

/// One repo's rail as the rows read it: the active repo's from
/// `git.State.rail_*`, another's from `rails` (All repos), a repo
/// whose rail has not landed as empty lists.
const RailView = struct {
    repo_idx: u32 = 0,
    name: []const u8 = "",
    path: []const u8 = "",
    branches: []const parse.Branch = &.{},
    worktrees: []const parse.Worktree = &.{},
    remotes: []const parse.Remote = &.{},
    stashes: []const parse.Stash = &.{},
    tags: []const parse.Tag = &.{},
};

fn railView(gs: *const git.State, idx: usize) RailView {
    const r = gs.repos.items[idx];
    var v: RailView = .{ .repo_idx = @intCast(idx), .name = r.name, .path = r.path };
    if (gs.active != null and gs.active.? == idx) {
        v.branches = gs.rail_branches;
        v.worktrees = gs.rail_worktrees;
        v.remotes = gs.rail_remotes;
        v.stashes = gs.rail_stashes;
        v.tags = gs.rail_tags;
    } else if (gs.rails.get(r.id)) |e| {
        v.branches = e.branches;
        v.worktrees = e.worktrees;
        v.remotes = e.remotes;
        v.stashes = e.stashes;
        v.tags = e.tags;
    }
    return v;
}

/// The repos the rows list: every open one under All repos, else the
/// active one — an empty view outside any repo, so the sections still
/// head the list.
fn railViews(app: *App, arena: Allocator) Allocator.Error![]RailView {
    const st = &app.git_palette;
    const gs = &app.git;
    var out: std.ArrayListUnmanaged(RailView) = .empty;
    if (st.all) {
        for (gs.repos.items, 0..) |r, i| if (!st.isClosed(r.path)) try out.append(arena, railView(gs, i));
    } else if (gs.active) |i| {
        if (i < gs.repos.items.len) try out.append(arena, railView(gs, i));
    }
    if (out.items.len == 0) try out.append(arena, .{});
    return out.items;
}

// LOCAL — A–Z.
fn localRows(arena: Allocator, v: RailView, filter: []const u8, out: *std.ArrayListUnmanaged(Row)) Allocator.Error!u32 {
    var idxs: std.ArrayListUnmanaged(u32) = .empty;
    for (v.branches, 0..) |b, i| if (!b.remote and matches(filter, b.name)) try idxs.append(arena, @intCast(i));
    std.mem.sort(u32, idxs.items, SortCtx{ .bs = v.branches }, SortCtx.lt);
    for (idxs.items) |i| {
        const b = v.branches[i];
        try out.append(arena, .{ .branch = .{ .idx = i, .name = b.name, .current = b.current, .ahead = b.ahead, .behind = b.behind } });
    }
    return @intCast(idxs.items.len);
}

// REMOTE — each remote, its branches under it without the prefix.
fn remoteRows(arena: Allocator, v: RailView, filter: []const u8, out: *std.ArrayListUnmanaged(Row)) Allocator.Error!u32 {
    var idxs: std.ArrayListUnmanaged(u32) = .empty;
    for (v.branches, 0..) |b, i| if (b.remote and !std.mem.endsWith(u8, b.name, "/HEAD") and matches(filter, b.name)) try idxs.append(arena, @intCast(i));
    std.mem.sort(u32, idxs.items, SortCtx{ .bs = v.branches }, SortCtx.lt);
    // The remotes `git remote -v` lists, then any prefix a branch
    // carries that none of them named.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (v.remotes) |r| try names.append(arena, r.name);
    for (idxs.items) |i| {
        const full = v.branches[i].name;
        const prefix = full[0 .. std.mem.indexOfScalar(u8, full, '/') orelse full.len];
        var known = false;
        for (names.items) |n| if (std.mem.eql(u8, n, prefix)) {
            known = true;
        };
        if (!known) try names.append(arena, prefix);
    }
    for (names.items, 0..) |name, ri| {
        var any = false;
        for (idxs.items) |i| if (std.mem.startsWith(u8, v.branches[i].name, name) and v.branches[i].name.len > name.len and v.branches[i].name[name.len] == '/') {
            any = true;
        };
        if (!any and filter.len > 0) continue;
        const github = if (ri < v.remotes.len) v.remotes[ri].provider == .github else false;
        try out.append(arena, .{ .remote = .{ .idx = @intCast(ri), .name = name, .github = github } });
        for (idxs.items) |i| {
            const full = v.branches[i].name;
            if (!(std.mem.startsWith(u8, full, name) and full.len > name.len and full[name.len] == '/')) continue;
            try out.append(arena, .{ .remote_branch = .{ .idx = i, .name = full, .shown = full[name.len + 1 ..] } });
        }
    }
    return @intCast(idxs.items.len);
}

// WORKTREES — git's order, the main tree first.
fn worktreeRows(app: *App, arena: Allocator, v: RailView, filter: []const u8, out: *std.ArrayListUnmanaged(Row)) Allocator.Error!u32 {
    var count: u32 = 0;
    for (v.worktrees, 0..) |w, i| {
        const shown = try worktreeShown(arena, w);
        if (!matches(filter, w.label()) and !matches(filter, std.fs.path.basename(w.path))) continue;
        count += 1;
        const current = (v.path.len > 0 and samePath(app, arena, w.path, v.path)) or (v.path.len == 0 and i == 0);
        const b = if (w.branch.len > 0) branchNamed(v.branches, w.branch) else null;
        try out.append(arena, .{ .worktree = .{
            .idx = @intCast(i),
            .shown = shown,
            .main = w.main,
            .current = current,
            .locked = w.locked,
            .dirty = w.dirty,
            .ahead = if (b) |x| x.ahead else 0,
            .behind = if (b) |x| x.behind else 0,
            .accent = sessionAccent(app, w.path),
            .session = app.sessions.worktrees.byPath(w.path) != null,
        } });
    }
    return count;
}

/// The accent of the session whose worktree `path` is
/// (sessions-worktree): the session's colour by its id, else its open
/// pane's — as the SESSIONS card paints it. Null for a tree that is no
/// session's, or one whose session has no colour yet.
pub fn sessionAccent(app: *App, path: []const u8) ?Theme.Color {
    const e = app.sessions.worktrees.byPath(path) orelse return null;
    const by_id: ?[]const u8 = if (e.session_id) |sid| sessions.colorNameOf(app, sid) else null;
    const name = by_id orelse paneAccentByCwd(app, path) orelse return null;
    return accent_color.resolve(name, &app.theme);
}

/// The accent of the pty pane running in `cwd`, if one is.
fn paneAccentByCwd(app: *App, cwd: []const u8) ?[]const u8 {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .pty => |*pt| if (pt.cwd) |c| if (std.mem.eql(u8, c, cwd)) {
            if (pt.accent_color) |a| return a;
        },
        else => {},
    };
    return null;
}

// STASHES — newest first, as `stash list` prints them.
fn stashRows(arena: Allocator, v: RailView, filter: []const u8, out: *std.ArrayListUnmanaged(Row)) Allocator.Error!u32 {
    var count: u32 = 0;
    for (v.stashes, 0..) |st, i| {
        if (!matches(filter, st.message) and !matches(filter, st.ref) and !matches(filter, st.sha)) continue;
        count += 1;
        try out.append(arena, .{ .stash = .{ .idx = @intCast(i), .sha = st.sha, .message = st.message } });
    }
    return count;
}

// TAGS — newest first, as the worker sorted them.
fn tagRows(arena: Allocator, v: RailView, filter: []const u8, out: *std.ArrayListUnmanaged(Row)) Allocator.Error!u32 {
    var count: u32 = 0;
    for (v.tags, 0..) |t, i| {
        if (!matches(filter, t.name)) continue;
        count += 1;
        try out.append(arena, .{ .tag = .{ .idx = @intCast(i), .name = t.name } });
    }
    return count;
}

/// The palette's rows for this frame, on `arena`: the five sections in
/// their order with the filter applied, a folded section keeping its
/// header (its count is the filtered one), a gap row after each. Under
/// All repos every section holds a `.repo` sub-header per open repo
/// with that repo's rows beneath it (a repo the filter leaves empty is
/// skipped, as an empty remote is) and its count is the sum.
pub fn rows(app: *App, arena: Allocator) Allocator.Error![]Row {
    const st = &app.git_palette;
    const filter = st.filter.items;
    const views = try railViews(app, arena);
    var out: std.ArrayListUnmanaged(Row) = .empty;
    for (std.enums.values(Section)) |sec| {
        var items: std.ArrayListUnmanaged(Row) = .empty;
        var count: u32 = 0;
        for (views) |v| {
            var mine: std.ArrayListUnmanaged(Row) = .empty;
            count += switch (sec) {
                .local => try localRows(arena, v, filter, &mine),
                .remote => try remoteRows(arena, v, filter, &mine),
                .worktrees => try worktreeRows(app, arena, v, filter, &mine),
                .stashes => try stashRows(arena, v, filter, &mine),
                .tags => try tagRows(arena, v, filter, &mine),
            };
            if (st.all) {
                if (mine.items.len == 0 and filter.len > 0) continue;
                try items.append(arena, .{ .repo = .{ .idx = v.repo_idx, .name = v.name, .accent = repoAccent(app, app.git.repos.items[v.repo_idx].id) } });
            }
            try items.appendSlice(arena, mine.items);
        }
        const collapsed = st.collapsed.contains(sec);
        try out.append(arena, .{ .section = .{ .s = sec, .count = count, .collapsed = collapsed } });
        if (!collapsed) try out.appendSlice(arena, items.items);
        try out.append(arena, .gap);
    }
    return out.items;
}

/// `Viewing N`: the item rows in `list`.
pub fn viewing(list: []const Row) usize {
    var n: usize = 0;
    for (list) |r| if (r.isItem()) {
        n += 1;
    };
    return n;
}

// ─── draw (D6) ──────────────────────────────────────────────────────────

pub fn draw(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    // colors: every repo has its accent before the pill paints.
    try ensureRepoColors(app);
    const st = &app.git_palette;
    const gs = &app.git;
    if (!gs.discovered) git.discover(app) catch {};
    if (gs.activeRepo() != null and gs.status == null and !gs.status_pending) git.requestStatus(app) catch {};
    if (gs.activeRepo() != null and !gs.rail_loaded and !gs.rail_pending) git.requestRail(app) catch {};
    if (st.all) requestRailAll(app, false) catch {};
    const list = try rows(app, ui.arena);
    if (st.cursor >= list.len) st.cursor = list.len -| 1;
    const repo_name: []const u8 = if (st.all) "All repos" else if (gs.activeRepo()) |r| r.name else std.fs.path.basename(app.workspace);
    const painted = view.draw(ui, area, .{
        .rows = list,
        .repo = repo_name,
        .viewing = viewing(list),
        .filter = st.filter.items,
        .filter_caret = st.filter_caret,
        .filter_focused = st.filter_focused,
        .cursor = st.cursor,
        .scroll = st.scroll,
        .repo_count = gs.repos.items.len,
        .accent = if (st.all) null else (if (gs.activeRepo()) |r| repoAccent(app, r.id) else null),
        .grouped = st.all,
    });
    st.scroll = painted.scroll;
    st.visible = painted.visible;
    st.total = list.len;
    if (painted.caret) |c| if (st.filter_focused and app.focus == .panel and app.focus.panel == .git) {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
    if (gs.busy > 0 or gs.rail_pending or git.anyRailPending(gs)) list_panel.paintSpinner(ui, area, repo_name, app.now_ms);
}

// ─── acting on a row ────────────────────────────────────────────────────

fn rowAt(app: *App, idx: usize) Allocator.Error!?Row {
    const list = try rows(app, app.frame.allocator());
    if (idx >= list.len) return null;
    return list[idx];
}

/// The branch the cursor's row names (local or remote), for
/// `git.reset_*` from the row menu; null on any other row.
pub fn cursorBranch(app: *App) Allocator.Error!?[]const u8 {
    const row = (try rowAt(app, app.git_palette.cursor)) orelse return null;
    return switch (row) {
        .branch => |b| b.name,
        .remote_branch => |m| m.name,
        else => null,
    };
}

/// The stash the cursor's row names (`stash@{N}`), for the stash
/// commands off the panel; null on any other row.
pub fn cursorStash(app: *App) Allocator.Error!?[]const u8 {
    const row = (try rowAt(app, app.git_palette.cursor)) orelse return null;
    return switch (row) {
        .stash => |s| if (s.idx < app.git.rail_stashes.len) app.git.rail_stashes[s.idx].ref else null,
        else => null,
    };
}

/// The worktree the cursor's row names, for the WORKTREES commands off
/// the panel; null on any other row.
pub fn cursorWorktree(app: *App) Allocator.Error!?parse.Worktree {
    const row = (try rowAt(app, app.git_palette.cursor)) orelse return null;
    return switch (row) {
        .worktree => |w| if (w.idx < app.git.rail_worktrees.len) app.git.rail_worktrees[w.idx] else null,
        else => null,
    };
}

pub fn cursorStashMessage(app: *App) ?[]const u8 {
    const row = (rowAt(app, app.git_palette.cursor) catch return null) orelse return null;
    return switch (row) {
        .stash => |s| s.message,
        else => null,
    };
}

fn setSelected(app: *App, name: ?[]const u8) Allocator.Error!void {
    const st = &app.git_palette;
    if (st.selected) |s| app.gpa.free(s);
    st.selected = if (name) |n| try app.gpa.dupe(u8, n) else null;
}

/// The active graph's cursor lands on `sha`'s commit; the palette keeps
/// the focus. A commit the graph has not loaded is said, not sought.
fn jumpToSha(app: *App, sha: []const u8, name: []const u8) void {
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

/// Enter on the cursor row, or a double-click on a row: the row's action.
pub fn activate(app: *App, idx: usize) Allocator.Error!void {
    const st = &app.git_palette;
    const gs = &app.git;
    const gpa = app.gpa;
    const row = (try rowAt(app, idx)) orelse return;
    st.cursor = idx;
    try switchToRowRepo(app, idx);
    const result: CommandError!void = blk: {
        switch (row) {
            .gap, .remote => {},
            .repo => |r| break :blk selectRepo(app, r.idx),
            .section => |s| st.collapsed.toggle(s.s),
            .branch => |b| {
                try setSelected(app, b.name);
                if (b.current) {
                    app.toast("already on {s}", .{b.name});
                    break :blk;
                }
                const repo = git.requireRepo(app) catch |err| break :blk err;
                break :blk git.submitOp(app, repo, .{ .checkout = try gpa.dupe(u8, b.name) });
            },
            .remote_branch => |b| {
                try setSelected(app, b.name);
                break :blk checkoutTracking(app, b.name);
            },
            .worktree => |w| {
                if (w.idx >= gs.rail_worktrees.len) break :blk;
                try setSelected(app, gs.rail_worktrees[w.idx].label());
                break :blk openWorktree(app, gs.rail_worktrees[w.idx]);
            },
            .stash => |s| {
                // // changed (git-more2): Enter shows the stash's files;
                // the row menu applies / pops.
                if (s.idx >= gs.rail_stashes.len) break :blk;
                const ref = gs.rail_stashes[s.idx].ref;
                try setSelected(app, ref);
                break :blk git.stashShow(app, ref);
            },
            .tag => |t| {
                try setSelected(app, t.name);
                break :blk git.openConfirm(app, .{ .checkout = try gpa.dupe(u8, t.name) }, try std.fmt.allocPrint(gpa, "Checkout tag {s}? (detached HEAD)", .{t.name}));
            },
        }
    };
    git.runToast(app, result);
    app.needs_render = true;
}

/// A remote branch checks out as a local tracking branch of its short
/// name — git's own guess, as the checkout picker does it.
fn checkoutTracking(app: *App, full: []const u8) CommandError!void {
    const repo = try git.requireRepo(app);
    const local = if (std.mem.indexOfScalar(u8, full, '/')) |s| full[s + 1 ..] else full;
    try git.submitOp(app, repo, .{ .checkout = try app.gpa.dupe(u8, local) });
}

/// Open a worktree: its directory joins the tree as a workspace root
/// (unless it is one, or the workspace itself), the repos are
/// rediscovered so it has a graph tab, and that tab comes to the front
/// — its name and its log are the tree's — the palette then lists
/// that tree's refs. `rebuildTabs` alone would keep the graph that was
/// showing (its rule for re-entering the mode), so the tree's tab is
/// shown after it, explicitly.
pub fn openWorktree(app: *App, w: parse.Worktree) CommandError!void {
    const st = &app.git_palette;
    const gs = &app.git;
    const arena = app.frame.allocator();
    // Already the active repo: nothing to open.
    if (gs.activeRepo()) |r| if (samePath(app, arena, r.path, w.path)) {
        if (w.head.len > 0) jumpToSha(app, w.head, w.label());
        return;
    };
    // Known already (a nested tree, an extra root): switch to it.
    for (gs.repos.items, 0..) |r, i| if (samePath(app, arena, r.path, w.path)) {
        try git.switchTo(app, i);
        if (st.active) try rebuildTabs(app);
        showRepoTab(app, i);
        return;
    };
    const idx = (try ensureWorktreeRepo(app, w)) orelse {
        app.toast("worktree: {s} added to the workspace", .{w.path});
        return;
    };
    try git.switchTo(app, idx);
    if (st.active) try rebuildTabs(app);
    showRepoTab(app, idx);
    app.toast("worktree: {s}", .{w.path});
}

/// The worktree's directory as a workspace root and a repo of its own,
/// discovered if it was not one already: its index in `git.repos`, or
/// null when the discovery did not find a repository there.
fn ensureWorktreeRepo(app: *App, w: parse.Worktree) CommandError!?usize {
    const gs = &app.git;
    const arena = app.frame.allocator();
    for (gs.repos.items, 0..) |r, i| if (samePath(app, arena, r.path, w.path)) return i;
    _ = app.tree.addRoot(app, w.path, null) catch |err| switch (err) {
        error.AlreadyOpen => {},
        error.NotADirectory => return app.diag.fail(arena, "worktree: {s} is not a directory", .{w.path}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    try git.discover(app);
    for (gs.repos.items, 0..) |r, i| if (samePath(app, arena, r.path, w.path)) return i;
    return null;
}

/// *Open worktree in new tab* (git-menus): the tree opens on a tab page
/// of its own, this page left as it is — where *Open this worktree*
/// turns THIS page's git tab to the tree's graph, per tab. The new page
/// holds the tree's files, and the tree becomes the repo the panels
/// read.
pub fn openWorktreeInTab(app: *App, w: parse.Worktree) CommandError!void {
    const idx = (try ensureWorktreeRepo(app, w)) orelse {
        app.toast("worktree: {s} added to the workspace", .{w.path});
        return;
    };
    try cmd_tab.tabNewEmpty(app);
    _ = try files_pane.open(app, w.path);
    try git.switchTo(app, idx);
    app.toast("worktree {s}: tab {d}/{d}", .{ std.fs.path.basename(w.path), app.layouts.active + 1, app.layouts.layouts.items.len });
}

/// The tree's path for a confirm: workspace-relative when it is under
/// the workspace, through symlinks (`git worktree list` prints the real
/// path, a workspace may be the symlinked one).
fn treeLabel(app: *App, arena: Allocator, path: []const u8) []const u8 {
    const rel = app.relPath(path);
    if (rel.len < path.len) return rel;
    const real = std.Io.Dir.realPathFileAbsoluteAlloc(app.io, app.workspace, arena) catch return path;
    if (std.mem.startsWith(u8, path, real) and path.len > real.len and std.fs.path.isSep(path[real.len])) return path[real.len + 1 ..];
    return path;
}

/// A WORKTREES row's *Remove worktree and delete branch…* (git-menus):
/// the confirm names the tree, its branch and, when the tree is dirty,
/// how many files it would throw away. The main tree, the tree on show
/// and a tree with no branch of its own are refused by name — the row
/// is always there, as every WORKTREES row's is.
pub fn confirmRemoveWorktreeBranch(app: *App, wt: parse.Worktree) CommandError!void {
    const arena = app.frame.allocator();
    const gpa = app.gpa;
    if (wt.main) return app.diag.fail(arena, "remove worktree: {s} is the main worktree", .{wt.path});
    if (app.git.activeRepo()) |r| if (samePath(app, arena, r.path, wt.path)) return app.diag.fail(arena, "remove worktree: {s} is the tree on show \u{2014} switch to another first", .{wt.path});
    if (wt.branch.len == 0) return app.diag.fail(arena, "remove worktree: {s} has no branch of its own \u{2014} use Remove this worktree", .{wt.path});
    const path = try gpa.dupe(u8, wt.path);
    errdefer gpa.free(path);
    const branch = try gpa.dupe(u8, wt.branch);
    errdefer gpa.free(branch);
    // The box shows one line: a long absolute path would push the
    // branch and the count off the end, so the tree is named the way
    // the panels name it — workspace-relative where it is under one.
    const shown = treeLabel(app, arena, wt.path);
    const message = if (wt.dirty_files > 0)
        try std.fmt.allocPrint(gpa, "Remove worktree {s} and delete branch {s}? {d} uncommitted file{s} \u{2014} Force throws {s} away.", .{ shown, wt.branch, wt.dirty_files, if (wt.dirty_files == 1) "" else "s", if (wt.dirty_files == 1) "it" else "them" })
    else
        try std.fmt.allocPrint(gpa, "Remove worktree {s} and delete branch {s}? Force deletes the branch even when it is not merged.", .{ shown, wt.branch });
    errdefer gpa.free(message);
    try git.openConfirmWith(app, .{ .worktree_remove_branch = .{ .path = path, .branch = branch, .dirty_files = wt.dirty_files } }, "Remove worktree", message, &git.remove_branch_choices);
}

/// One row menu's rows as they are built: the labels on the arena the
/// menu will own, every act carrying the row's repo.
const MenuBuilder = struct {
    items: std.ArrayListUnmanaged(MenuItem) = .empty,
    a: Allocator,
    gpa: Allocator,
    repo: ?u32,

    fn fmt(b: *MenuBuilder, comptime f: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(b.a, f, args);
    }

    fn act(b: *MenuBuilder, label: []const u8, what: command.GitPaletteWhat, idx: u32, sep: bool) Allocator.Error!void {
        try b.items.append(b.gpa, .{ .label = label, .action = .{ .git_palette = .{ .what = what, .idx = idx, .repo = b.repo } }, .separator_before = sep });
    }

    /// `Reset <head> to this commit ▸`: soft / mixed / hard to the right.
    fn reset(b: *MenuBuilder, head: []const u8, idx: u32, sep: bool) Allocator.Error!void {
        const sub = try b.a.alloc(MenuItem, 3);
        sub[0] = .{ .label = "Soft (keep the changes staged)", .action = .{ .git_palette = .{ .what = .reset_soft, .idx = idx, .repo = b.repo } } };
        sub[1] = .{ .label = "Mixed (keep the changes)", .action = .{ .git_palette = .{ .what = .reset_mixed, .idx = idx, .repo = b.repo } } };
        sub[2] = .{ .label = "Hard (discard the changes)\u{2026}", .action = .{ .git_palette = .{ .what = .reset_hard, .idx = idx, .repo = b.repo } } };
        try b.items.append(b.gpa, .{ .label = try b.fmt("Reset {s} to this commit", .{head}), .action = .none, .submenu = sub, .separator_before = sep });
    }

    /// The four copies every branch row ends with.
    fn copies(b: *MenuBuilder, idx: u32) Allocator.Error!void {
        try b.act("Copy branch name", .copy_name, idx, true);
        try b.act("Copy commit sha", .copy_sha, idx, false);
        try b.act("Copy link to branch", .copy_branch_link, idx, false);
        try b.act("Copy link to this commit on remote", .copy_commit_link, idx, false);
    }

    fn tags(b: *MenuBuilder, idx: u32) Allocator.Error!void {
        try b.act("Create tag here\u{2026}", .tag_here, idx, true);
        try b.act("Create annotated tag here\u{2026}", .tag_annotated_here, idx, false);
    }
};

/// The row a never-pushed branch has in place of Pull / Push: a
/// `push -u` to the remote (VS Code's word for it).
pub const publish_label = "Publish branch (set upstream)";

/// Whether the remote has local branch `b`: it tracks a branch there
/// that still exists, or a remote carries a branch of its name (what
/// `Delete on the remote…` would delete).
fn onRemote(v: RailView, b: parse.Branch) bool {
    if (b.upstream.len > 0 and !b.gone) return true;
    for (v.branches) |r| if (r.remote) {
        const sl = std.mem.indexOfScalar(u8, r.name, '/') orelse continue;
        if (std.mem.eql(u8, r.name[sl + 1 ..], b.name)) return true;
    };
    return false;
}

/// The checked-out branch of a rail, for the labels (`Merge x into
/// main`); `HEAD` when detached or before the rail landed.
fn headName(v: RailView) []const u8 {
    for (v.branches) |b| if (b.current and !b.remote) return b.name;
    return "HEAD";
}

/// The row menus (a right-click, `m`, `contextMenuAtFocus`). Built from
/// the row under the pointer — `idx` is the hit's index into this
/// frame's rows — never from the cursor, which stays where it is. One
/// shape per row kind, whatever the cursor, the tree on show, the main
/// tree or All repos say: a row a verb cannot take says so when the
/// verb runs rather than losing the row (the kinds: a local branch, the
/// checked-out local branch, a remote, a remote branch, a worktree, a
/// session's worktree, a stash, a tag, a section header, a repo
/// sub-header). The labels live on an arena the menu owns — the frame's
/// is reused by the next paint, which scribbled over them. Under All
/// repos the row's repo rides on every act (`GitPaletteAct.repo`) and
/// the rows are read from that repo's parked rail: opening the menu
/// switches nothing; running a row does.
pub fn openRowMenu(app: *App, idx: usize, x: u16, y: u16) Allocator.Error!void {
    const gpa = app.gpa;
    const gs = &app.git;
    const st = &app.git_palette;
    const list = try rows(app, app.frame.allocator());
    if (idx >= list.len) {
        app.toast("git: the row changed under the pointer \u{2014} try again", .{});
        return;
    }
    const row = list[idx];
    if (row == .gap) return;
    const repo_idx: ?u32 = if (st.all) repoOfRow(list, idx) else null;
    const v: RailView = if (repo_idx) |ri| railView(gs, ri) else if (gs.active) |ai| (if (ai < gs.repos.items.len) railView(gs, ai) else RailView{}) else RailView{};
    var mem = std.heap.ArenaAllocator.init(gpa);
    errdefer mem.deinit();
    var b: MenuBuilder = .{ .a = mem.allocator(), .gpa = gpa, .repo = repo_idx };
    errdefer b.items.deinit(gpa);
    const title: []const u8 = switch (row) {
        .gap => unreachable,
        .section => |s| blk: {
            try b.act(if (s.collapsed) "Unfold" else "Fold", .fold, @intFromEnum(s.s), false);
            try b.act("Refresh", .refresh, 0, false);
            break :blk s.s.label();
        },
        .repo => |r| blk: {
            try b.act(try b.fmt("Show only {s}", .{r.name}), .switch_repo, r.idx, false);
            try b.act("Refresh", .refresh, 0, false);
            break :blk r.name;
        },
        // LOCAL: the reference client's rows in its order — the sync
        // verbs, merge / rebase, a worktree, the commit verbs (Reset a
        // submenu), rename / delete and this panel's own diff and force
        // verbs, the copies, the tags. The checked-out branch keeps the
        // rows that apply to itself (no checkout, merge, cherry-pick or
        // reset onto itself) — its own kind.
        //
        // The sync rows follow the upstream: a branch that tracks one
        // pulls and pushes; one that has never been pushed (no upstream,
        // or one the remote has since deleted) is offered `Publish
        // branch (set upstream)` — a `push -u` — and no pull, which would
        // have nothing to pull from. `Delete on the remote…` is offered
        // only for a branch the remote has.
        .branch => |br| blk: {
            const name = br.name;
            const head = headName(v);
            const bb: ?parse.Branch = if (br.idx < v.branches.len) v.branches[br.idx] else null;
            const published = if (bb) |rb| rb.upstream.len > 0 and !rb.gone else true;
            const remote_has = if (bb) |rb| onRemote(v, rb) else true;
            if (br.current) {
                if (published) {
                    try b.act("Pull (fast-forward if possible)", .pull, br.idx, false);
                    try b.act("Push", .push, br.idx, false);
                    try b.act("Push --force-with-lease\u{2026}", .push_force, br.idx, false);
                } else try b.act(publish_label, .push, br.idx, false);
                try b.act("Push and start PR", .push_start_pr, br.idx, false);
                try b.act("Set upstream\u{2026}", .set_upstream, br.idx, false);
                try b.act(try b.fmt("Open worktree from {s}\u{2026}", .{name}), .branch_worktree, br.idx, true);
                try b.act("Create branch here\u{2026}", .new_branch, br.idx, true);
                try b.act("Revert commit", .revert, br.idx, false);
                try b.act(try b.fmt("Rename {s}\u{2026}", .{name}), .rename, br.idx, true);
                if (remote_has) try b.act("Delete on the remote\u{2026}", .delete_remote, br.idx, false);
                try b.act("Explain branch changes (AI)", .explain_branch, br.idx, true);
                try b.copies(br.idx);
                try b.tags(br.idx);
                break :blk try b.fmt("\u{25CF} {s}", .{name});
            }
            try b.act(try b.fmt("Checkout {s}", .{name}), .checkout, br.idx, false);
            if (published) {
                try b.act("Pull (fast-forward if possible)", .fast_forward, br.idx, true);
                try b.act("Push", .push_branch, br.idx, false);
            } else try b.act(publish_label, .push_branch, br.idx, true);
            try b.act("Push and start PR", .push_start_pr, br.idx, false);
            try b.act("Set upstream\u{2026}", .set_upstream, br.idx, false);
            try b.act(try b.fmt("Merge {s} into {s}", .{ name, head }), .merge, br.idx, true);
            try b.act(try b.fmt("Rebase {s} onto {s}", .{ head, name }), .rebase, br.idx, false);
            try b.act(try b.fmt("Interactive rebase {s} onto {s}\u{2026}", .{ head, name }), .rebase_interactive, br.idx, false);
            try b.act(try b.fmt("Open worktree from {s}\u{2026}", .{name}), .branch_worktree, br.idx, true);
            try b.act("Create branch here\u{2026}", .new_branch, br.idx, true);
            try b.act("Cherry pick commit", .cherry_pick, br.idx, false);
            try b.reset(head, br.idx, false);
            try b.act("Revert commit", .revert, br.idx, false);
            try b.act(try b.fmt("Rename {s}\u{2026}", .{name}), .rename, br.idx, true);
            try b.act(try b.fmt("Delete {s}\u{2026}", .{name}), .delete_branch, br.idx, false);
            if (remote_has) try b.act("Delete on the remote\u{2026}", .delete_remote, br.idx, false);
            try b.act(try b.fmt("Force checkout {s}\u{2026}", .{name}), .checkout_force, br.idx, false);
            try b.act(try b.fmt("Diff against {s}", .{head}), .diff_current, br.idx, false);
            try b.act("Explain branch changes (AI)", .explain_branch, br.idx, false);
            try b.copies(br.idx);
            try b.tags(br.idx);
            break :blk name;
        },
        // REMOTE: merge / rebase, checkout and a worktree, the commit
        // verbs, delete and this panel's diff, the copies, the tags.
        .remote_branch => |m| blk: {
            const head = headName(v);
            try b.act(try b.fmt("Merge {s} into {s}", .{ m.name, head }), .merge, m.idx, false);
            try b.act(try b.fmt("Rebase {s} onto {s}", .{ head, m.name }), .rebase, m.idx, false);
            try b.act(try b.fmt("Checkout {s}", .{m.name}), .checkout, m.idx, true);
            try b.act(try b.fmt("Create worktree from {s}\u{2026}", .{m.name}), .branch_worktree, m.idx, false);
            try b.act("Create branch here\u{2026}", .new_branch, m.idx, true);
            try b.act("Cherry pick commit", .cherry_pick, m.idx, false);
            try b.reset(head, m.idx, false);
            try b.act("Revert commit", .revert, m.idx, false);
            try b.act(try b.fmt("Delete {s}\u{2026}", .{m.name}), .delete_remote, m.idx, true);
            try b.act(try b.fmt("Diff against {s}", .{head}), .diff_current, m.idx, false);
            try b.act("Explain branch changes (AI)", .explain_branch, m.idx, false);
            try b.copies(m.idx);
            try b.tags(m.idx);
            break :blk m.name;
        },
        .remote => |r| blk: {
            // A prefix no `git remote` names (a branch `fork/x` without
            // a remote `fork`) has no URL: the row stays, the copy says so.
            try b.act("Fetch", .remote_fetch, r.idx, false);
            try b.act("Copy URL", .remote_copy_url, r.idx, false);
            break :blk r.name;
        },
        .worktree => |w| blk: {
            if (w.idx >= v.worktrees.len) {
                app.toast("git: the row changed under the pointer \u{2014} try again", .{});
                return;
            }
            const wt = v.worktrees[w.idx];
            try b.act("Open this worktree", .worktree_open, w.idx, false);
            try b.act("Open worktree in new tab", .worktree_open_tab, w.idx, false);
            try b.act("Open shell here", .worktree_shell, w.idx, false);
            if (wt.locked) {
                try b.act("Unlock worktree", .worktree_unlock, w.idx, false);
            } else {
                try b.act("Lock worktree\u{2026}", .worktree_lock, w.idx, false);
            }
            try b.act("Copy path", .worktree_copy_path, w.idx, false);
            try b.act("New worktree\u{2026}", .worktree_new, w.idx, false);
            // sessions-worktree: a session's tree merges and removes
            // through the session verbs (the branch goes with it).
            if (app.sessions.worktrees.byPath(wt.path)) |e| {
                const into = session_worktree.currentBranch(app, b.a, e.repo) catch "HEAD";
                try b.act(try b.fmt("Merge into {s}\u{2026}", .{into}), .session_merge, w.idx, true);
                try b.act("Remove worktree and delete branch\u{2026}", .session_remove, w.idx, false);
            } else {
                // The main tree and the tree on show keep the row; the
                // verb refuses them by name.
                try b.act("Remove this worktree\u{2026}", .worktree_remove, w.idx, true);
                try b.act("Remove worktree and delete branch\u{2026}", .worktree_remove_branch, w.idx, false);
            }
            break :blk try b.fmt("{s}  {s}", .{ wt.label(), wt.path });
        },
        .stash => |sh| blk: {
            if (sh.idx >= v.stashes.len) {
                app.toast("git: the row changed under the pointer \u{2014} try again", .{});
                return;
            }
            try b.act("Show files (Enter)", .stash_show, sh.idx, false);
            try b.act("Apply (keep)", .stash_apply, sh.idx, true);
            try b.act("Pop (apply + drop)", .stash_pop, sh.idx, false);
            try b.act("Drop\u{2026}", .stash_drop, sh.idx, false);
            try b.act("Branch from stash\u{2026}", .stash_branch, sh.idx, true);
            try b.act("Rename\u{2026}", .stash_rename, sh.idx, false);
            break :blk try b.fmt("{s} {s}", .{ v.stashes[sh.idx].ref, sh.message });
        },
        .tag => |t| blk: {
            try b.act(try b.fmt("Checkout {s} (detached)", .{t.name}), .tag_checkout, t.idx, false);
            try b.act(try b.fmt("Copy name ({s})", .{t.name}), .tag_copy, t.idx, false);
            try b.act(try b.fmt("Delete {s}\u{2026}", .{t.name}), .tag_delete, t.idx, false);
            try b.act("New branch from tag\u{2026}", .new_branch_from, t.idx, true);
            try b.act("New worktree from tag\u{2026}", .worktree_from, t.idx, false);
            break :blk t.name;
        },
    };
    try context_menus.openOwned(app, title, try b.items.toOwnedSlice(gpa), x, y, mem);
}

/// A menu row picked. Under All repos the row's repo goes active first
/// (`a.repo`): everything below reads the live rail, which is then
/// that repo's.
pub fn menuAction(app: *App, a: MenuAct) Allocator.Error!void {
    const gs = &app.git;
    const st = &app.git_palette;
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    if (a.repo) |r| if (gs.active == null or gs.active.? != r) {
        git.runToast(app, selectRepo(app, r));
        if (gs.active == null or gs.active.? != r) return;
    };
    const result: CommandError!void = blk: {
        switch (a.what) {
            .fold => {
                st.collapsed.toggle(@enumFromInt(a.idx));
                break :blk;
            },
            .refresh => {
                try chipMouse(app, .refresh, .{ .x = 0, .y = 0, .kind = .press, .button = .left });
                break :blk;
            },
            .pull => break :blk command.run(app, .{ .static = .@"git.pull" }),
            .push => break :blk command.run(app, .{ .static = .@"git.push" }),
            .worktree_new => break :blk command.run(app, .{ .static = .@"git.worktree_add" }),
            .switch_repo => {
                app.git_palette.all = false;
                app.git_palette.cursor = 0;
                app.git_palette.scroll = 0;
                break :blk selectRepo(app, a.idx);
            },
            .all_repos => break :blk setAll(app, true),
            .reopen_repo => break :blk reopen(app, a.idx),
            .remote_fetch => break :blk command.run(app, .{ .static = .@"git.fetch" }),
            .remote_copy_url => {
                if (a.idx >= gs.rail_remotes.len) break :blk app.diag.fail(arena, "copy URL: no such git remote \u{2014} the row is a ref prefix, not a remote", .{});
                const url = gs.rail_remotes[a.idx].url;
                try app.clipboard.setYank(url, false);
                app.toast("copied {s}", .{url});
                break :blk;
            },
            .worktree_open, .worktree_open_tab, .worktree_shell, .worktree_copy_path, .worktree_remove, .worktree_remove_branch, .worktree_lock, .worktree_unlock, .session_merge, .session_remove => {
                if (a.idx >= gs.rail_worktrees.len) break :blk;
                const wt = gs.rail_worktrees[a.idx];
                switch (a.what) {
                    .worktree_open => break :blk openWorktree(app, wt),
                    .worktree_open_tab => break :blk openWorktreeInTab(app, wt),
                    .worktree_remove_branch => break :blk confirmRemoveWorktreeBranch(app, wt),
                    .worktree_lock => break :blk git.lockWorktreePrompt(app, wt.path, wt.label()),
                    .worktree_unlock => break :blk git.unlockWorktree(app, wt.path),
                    .session_merge, .session_remove => {
                        const e = app.sessions.worktrees.byPath(wt.path) orelse break :blk app.diag.fail(arena, "{s} is no session worktree", .{wt.path});
                        break :blk if (a.what == .session_merge) session_worktree.confirmMerge(app, e.*) else session_worktree.confirmRemove(app, e.*);
                    },
                    .worktree_copy_path => {
                        try app.clipboard.setYank(wt.path, false);
                        app.toast("copied {s}", .{wt.path});
                    },
                    .worktree_shell => {
                        const opened = pty_pane.open(app, .{ .cwd = wt.path, .label = try std.fmt.allocPrint(arena, "shell: {s}", .{std.fs.path.basename(wt.path)}), .placement = .below, .kind = .shell });
                        _ = opened catch |err| break :blk err;
                    },
                    else => {
                        // The row is always there; the main tree and the
                        // tree on show are refused by name.
                        if (wt.main) break :blk app.diag.fail(arena, "remove worktree: {s} is the main worktree", .{wt.path});
                        if (gs.activeRepo()) |r| if (samePath(app, arena, r.path, wt.path)) break :blk app.diag.fail(arena, "remove worktree: {s} is the tree on show \u{2014} switch to another first", .{wt.path});
                        break :blk git.openConfirm(app, .{ .worktree_remove = try gpa.dupe(u8, wt.path) }, try std.fmt.allocPrint(gpa, "Remove worktree {s}?", .{wt.path}));
                    },
                }
                break :blk;
            },
            .stash_apply, .stash_pop, .stash_drop, .stash_show, .stash_branch, .stash_rename => {
                if (a.idx >= gs.rail_stashes.len) break :blk;
                const ref = gs.rail_stashes[a.idx].ref;
                const repo = git.requireRepo(app) catch |err| break :blk err;
                switch (a.what) {
                    .stash_apply => break :blk git.submitOp(app, repo, .{ .stash_apply = try gpa.dupe(u8, ref) }),
                    .stash_pop => break :blk git.submitOp(app, repo, .{ .stash_pop = try gpa.dupe(u8, ref) }),
                    .stash_show => break :blk git.stashShow(app, ref),
                    .stash_branch => break :blk git.stashBranchPrompt(app, ref),
                    .stash_rename => break :blk git.stashRenamePrompt(app, ref, gs.rail_stashes[a.idx].message),
                    else => break :blk git.askStashDrop(app, ref),
                }
            },
            .tag_checkout, .tag_delete, .tag_copy, .new_branch_from, .worktree_from => {
                if (a.idx >= gs.rail_tags.len) break :blk;
                const name = gs.rail_tags[a.idx].name;
                switch (a.what) {
                    .tag_checkout => break :blk git.openConfirm(app, .{ .checkout = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "Checkout tag {s}? (detached HEAD)", .{name})),
                    .tag_delete => break :blk git.openConfirm(app, .{ .tag_delete = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "Delete tag {s}?", .{name})),
                    .new_branch_from => break :blk git.newBranchFrom(app, name),
                    .worktree_from => break :blk git.worktreeFrom(app, name),
                    else => {
                        try app.clipboard.setYank(name, false);
                        app.toast("copied {s}", .{name});
                    },
                }
                break :blk;
            },
            else => {},
        }
        // The branch actions: `idx` is a rail branch, local or remote.
        if (a.idx >= gs.rail_branches.len) break :blk;
        const b = gs.rail_branches[a.idx];
        const name = b.name;
        const repo = git.requireRepo(app) catch |err| break :blk err;
        switch (a.what) {
            .checkout => break :blk if (b.remote) checkoutTracking(app, name) else git.submitOp(app, repo, .{ .checkout = try gpa.dupe(u8, name) }),
            .merge => break :blk git.submitOp(app, repo, .{ .merge = try gpa.dupe(u8, name) }),
            .rebase => break :blk git.submitOp(app, repo, .{ .rebase = try gpa.dupe(u8, name) }),
            // The plan modal over `name..HEAD`; the graph must be open,
            // which in git mode it is (one tab per repo).
            .rebase_interactive => break :blk git.openPlanOnto(app, git.activeGraph(app) orelse break :blk app.diag.fail(arena, "rebase: open the commit graph first (git.graph)", .{}), name),
            // From the row's branch, not HEAD (the current row's is HEAD).
            .new_branch => break :blk git.newBranchFrom(app, name),
            .delete_branch => break :blk git.openConfirm(app, .{ .delete_branch = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "Delete branch {s}? (git branch -D)", .{name})),
            .diff_current => break :blk git.diffAgainstCurrent(app, repo, name),
            .reset_soft => break :blk git.resetTo(app, .soft, name),
            .reset_mixed => break :blk git.resetTo(app, .mixed, name),
            .reset_hard => break :blk git.resetTo(app, .hard, name),
            .cherry_pick => break :blk git.submitOp(app, repo, .{ .cherry_pick = try gpa.dupe(u8, b.sha) }),
            .revert => break :blk git.submitOp(app, repo, .{ .revert = try gpa.dupe(u8, b.sha) }),
            .branch_worktree => break :blk git.worktreeFrom(app, name),
            .tag_here => break :blk git.tagAt(app, name, false),
            .tag_annotated_here => break :blk git.tagAt(app, name, true),
            .push_branch => break :blk git.pushBranch(app, name),
            .push_start_pr => break :blk git.pushStartPr(app, name),
            .copy_sha => {
                if (b.sha.len == 0) break :blk app.diag.fail(arena, "copy sha: {s} has none on the rail yet", .{name});
                try app.clipboard.setYank(b.sha, false);
                app.toast("copied {s}", .{b.sha});
            },
            .copy_branch_link, .copy_commit_link => {
                // The remote: a remote branch's own prefix, a local
                // branch's upstream's, else the first `git remote`.
                var remote_name: []const u8 = "";
                if (b.remote) {
                    if (std.mem.indexOfScalar(u8, name, '/')) |sl| remote_name = name[0..sl];
                } else if (b.upstream.len > 0) {
                    if (std.mem.indexOfScalar(u8, b.upstream, '/')) |sl| remote_name = b.upstream[0..sl];
                }
                var url: ?[]const u8 = null;
                for (gs.rail_remotes) |r| if (std.mem.eql(u8, r.name, remote_name)) {
                    url = r.url;
                };
                if (url == null and gs.rail_remotes.len > 0) url = gs.rail_remotes[0].url;
                const remote_url = url orelse break :blk app.diag.fail(arena, "copy link: no remote", .{});
                const short = if (b.remote) (if (std.mem.indexOfScalar(u8, name, '/')) |sl| name[sl + 1 ..] else name) else name;
                const link = if (a.what == .copy_branch_link) try remote_mod.branchUrl(arena, remote_url, short) else blk2: {
                    if (b.sha.len == 0) break :blk app.diag.fail(arena, "copy link: {s} has no sha on the rail yet", .{name});
                    break :blk2 try remote_mod.commitUrl(arena, remote_url, b.sha);
                };
                try app.clipboard.setYank(link, false);
                app.toast("copied {s}", .{link});
            },
            .explain_branch => break :blk git.explainBranch(app, name),
            .rename => break :blk git.branchRename(app, name),
            .fast_forward => break :blk git.fastForward(app, name),
            .set_upstream => break :blk git.setUpstream(app, name),
            .checkout_force => break :blk git.checkoutForce(app, name),
            .delete_remote => break :blk git.deleteRemote(app, name, null),
            .push_force => break :blk git.pushForce(app),
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

/// A press on a row (D6 `.row` hit, the row under the pointer). Left:
/// the keys go to the panel; an item row acts on the second press of a
/// double-click only (`dispatch.clickCount`), a header on every press.
/// Right: the row's menu, the cursor untouched.
pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.git_palette;
    if (m.kind != .press) return;
    st.filter_focused = false;
    switch (m.button) {
        .left => {
            const clicks = dispatch.clickCount(app, m);
            focusPalette(app);
            const row = (try rowAt(app, idx)) orelse return;
            const header = row == .section or row == .repo;
            if (header or clicks >= 2) try activate(app, idx);
        },
        .right => {
            focusPalette(app);
            try openRowMenu(app, idx, m.x, m.y);
        },
        else => {},
    }
    app.needs_render = true;
}

/// The hover tip of row `idx` (`discovery.describe`): the row's name
/// and what a double-click does to it.
pub fn hoverTip(app: *App, arena: Allocator, idx: u32) Allocator.Error!?@import("../ui/tooltip.zig").Tip {
    const row = (try rowAt(app, idx)) orelse return null;
    const menu = "right-click: the row menu";
    return switch (row) {
        .branch => |b| .{ .title = try std.fmt.allocPrint(arena, "Branch: {s}", .{b.name}), .detail = if (b.current) "checked out · " ++ menu else "double-click / Enter: checkout · " ++ menu },
        .remote_branch => |r| .{ .title = try std.fmt.allocPrint(arena, "Remote branch: {s}", .{r.name}), .detail = "double-click / Enter: checkout as a local tracking branch · " ++ menu },
        .worktree => |w| .{ .title = try std.fmt.allocPrint(arena, "Worktree: {s}", .{w.shown}), .detail = if (w.current) "the graph tab shown · " ++ menu else "double-click / Enter: switch the graph tab to this worktree · " ++ menu },
        .stash => |s| .{ .title = try std.fmt.allocPrint(arena, "Stash {s}: {s}", .{ s.sha, s.message }), .detail = "double-click / Enter: show its files · " ++ menu },
        .tag => |t| .{ .title = try std.fmt.allocPrint(arena, "Tag: {s}", .{t.name}), .detail = "double-click / Enter: checkout (detached) · " ++ menu },
        .remote => |r| .{ .title = try std.fmt.allocPrint(arena, "Remote: {s}", .{r.name}), .detail = menu },
        .section => |s| .{ .title = s.s.label(), .detail = "click: fold / unfold the section" },
        .repo => |r| .{ .title = try std.fmt.allocPrint(arena, "Repo: {s}", .{r.name}), .detail = "click: show this repo's graph tab · " ++ menu },
        .gap => null,
    };
}

pub fn partMouse(app: *App, part: Part, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    app.git_palette.filter_focused = false;
    focusPalette(app);
    switch (part) {
        // colors: the right button lists the active repo's colours.
        .repo => if (m.button == .right and !app.git_palette.all and colorsShown(app)) try openRepoColorMenu(app, m.x, m.y + 1) else try openReposMenu(app, m.x, m.y + 1),
        .repo_prev => git.runToast(app, stepRepo(app, false)),
        .repo_next => git.runToast(app, stepRepo(app, true)),
    }
}

pub fn chipMouse(app: *App, kind: hit.ChipKind, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    switch (kind) {
        .refresh => {
            // right-click: the ⟳ menu every list panel has (Refresh now,
            // the auto-refresh toggle).
            if (m.button == .right) return @import("auto_refresh.zig").openRefreshMenu(app, .git, m.x, m.y);
            git.runToast(app, git.discover(app));
            if (app.git.activeRepo() != null) {
                app.git.status_pending = false;
                git.runToast(app, git.requestStatus(app));
                git.runToast(app, git.requestRail(app));
            }
            if (app.git_palette.all) git.runToast(app, requestRailAll(app, true));
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
    const total = st.total;
    if (total == 0 or bar.h == 0) return;
    const max = total -| st.visible;
    switch (m.kind) {
        .press, .drag => {
            focusPalette(app);
            const off: usize = m.y -| bar.y;
            st.scroll = @min(off * total / bar.h, max);
            // The cursor follows so the paint's clamp keeps the scroll.
            st.cursor = @min(@max(st.cursor, st.scroll), st.scroll + st.visible -| 1);
        },
        else => {},
    }
    app.needs_render = true;
}

/// The wheel anywhere over the palette. The cursor stays inside the
/// window so the paint's clamp does not pull the scroll back.
pub fn wheel(app: *App, down: bool, n: usize) void {
    const st = &app.git_palette;
    if (down) st.scroll = @min(st.scroll + n, st.total -| st.visible) else st.scroll -|= n;
    st.cursor = @min(@max(st.cursor, st.scroll), st.scroll + st.visible -| 1);
    app.needs_render = true;
}

// ─── keys ───────────────────────────────────────────────────────────────

/// The next stop from `from` in the direction, skipping gaps; `from`
/// when there is none.
fn step(list: []const Row, from: usize, down: bool, n: usize) usize {
    if (list.len == 0) return 0;
    var i = from;
    var left = n;
    var last = from;
    while (left > 0) {
        if (down) {
            if (i + 1 >= list.len) break;
            i += 1;
        } else {
            if (i == 0) break;
            i -= 1;
        }
        if (list[i].isStop()) {
            last = i;
            left -= 1;
        }
    }
    return last;
}

fn lastStop(list: []const Row) usize {
    var i = list.len;
    while (i > 0) : (i -= 1) if (list[i - 1].isStop()) return i - 1;
    return 0;
}

/// The palette's keys, the list panels' contract: in the filter Esc
/// clears then blurs, Enter blurs, the arrows still move; otherwise
/// j/k and the arrows move, g/G and Home/End jump, the page keys page,
/// Enter acts, `m` opens the row's menu, `/` focuses the filter, `r`
/// refreshes, `c` commits, `n` makes a branch, `[` / `]` step to the
/// previous / next repo, Esc hands the focus to the graph.
pub fn handleKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.git_palette;
    const list = try rows(app, app.frame.allocator());
    const page = @max(1, st.visible);
    if (st.filter_focused) {
        switch (k.code) {
            .esc => {
                if (st.filter.items.len > 0) {
                    st.filter.clearRetainingCapacity();
                    st.filter_caret = 0;
                } else st.filter_focused = false;
            },
            .enter => st.filter_focused = false,
            .up => st.cursor = step(list, st.cursor, false, 1),
            .down => st.cursor = step(list, st.cursor, true, 1),
            else => {
                if (k.mods.ctrl and k.code == .char and (k.code.char == 'n' or k.code.char == 'p')) {
                    st.cursor = step(list, st.cursor, k.code.char == 'n', 1);
                } else switch (try text_field.handleKey(&st.filter, &st.filter_caret, app.gpa, k)) {
                    .ignored => return false,
                    .moved => {},
                    .changed => st.cursor = 0,
                }
            },
        }
        app.needs_render = true;
        return true;
    }
    switch (k.code) {
        .up => st.cursor = step(list, st.cursor, false, 1),
        .down => st.cursor = step(list, st.cursor, true, 1),
        .home => st.cursor = 0,
        .end => st.cursor = lastStop(list),
        .page_up => st.cursor = step(list, st.cursor, false, page),
        .page_down => st.cursor = step(list, st.cursor, true, page),
        .enter => try activate(app, st.cursor),
        .esc => {
            if (st.filter.items.len > 0) {
                st.filter.clearRetainingCapacity();
                st.filter_caret = 0;
                st.cursor = 0;
            } else if (app.active) |a| app.focus = .{ .pane = a };
        },
        .char => |c| {
            if (k.mods.ctrl) switch (c) {
                'n' => st.cursor = step(list, st.cursor, true, 1),
                'p' => st.cursor = step(list, st.cursor, false, 1),
                'd' => st.cursor = step(list, st.cursor, true, page / 2),
                'u' => st.cursor = step(list, st.cursor, false, page / 2),
                else => return false,
            } else if (k.mods.alt or k.mods.super) return false else switch (c) {
                'j' => st.cursor = step(list, st.cursor, true, 1),
                'k' => st.cursor = step(list, st.cursor, false, 1),
                'g' => st.cursor = 0,
                'G' => st.cursor = lastStop(list),
                '/' => st.filter_focused = true,
                'm' => try openRowMenu(app, st.cursor, 6, 8),
                'r' => try chipMouse(app, .refresh, .{ .x = 0, .y = 0, .kind = .press, .button = .left }),
                'c' => git.runToast(app, command.run(app, .{ .static = .@"git.commit" })),
                'n' => git.runToast(app, command.run(app, .{ .static = .@"git.new_branch" })),
                '[' => git.runToast(app, stepRepo(app, false)),
                ']' => git.runToast(app, stepRepo(app, true)),
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

/// A test app on a fresh `git init` workspace; each test discovers it
/// up front so the actions that need a repo find this one and never
/// re-discover (which would drop the seed). The worker runs against
/// the empty repo; nothing the tests submit lands anywhere else.
const TestApp = struct {
    tmp: testing.TmpDir,
    root: []u8,
    app: App,

    fn init() !TestApp {
        return initWith(&.{});
    }

    /// `repos` empty: the workspace is the repo. Otherwise the workspace
    /// is none and holds one fresh repo per name (discovery lists them
    /// A–Z).
    fn initWith(repos: []const []const u8) !TestApp {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        if (repos.len == 0) {
            try gitInit(root);
        } else for (repos) |name| {
            try tmp.dir.createDirPath(testing.io, name);
            const dir = try std.fs.path.join(testing.allocator, &.{ root, name });
            defer testing.allocator.free(dir);
            try gitInit(dir);
        }
        const app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = root, .cols = 120, .rows = 40 });
        return .{ .tmp = tmp, .root = root, .app = app };
    }

    fn gitInit(dir: []const u8) !void {
        const res = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "git", "init", "-q", "-b", "main" }, .cwd = .{ .path = dir } });
        testing.allocator.free(res.stdout);
        testing.allocator.free(res.stderr);
    }

    /// `git <args>` in the workspace, the test's own git (not the worker's).
    fn sh(t: *TestApp, args: []const []const u8) !void {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ "git", "-c", "user.email=t@mnml.dev", "-c", "user.name=tester" });
        try argv.appendSlice(testing.allocator, args);
        const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = t.root } });
        defer testing.allocator.free(res.stdout);
        defer testing.allocator.free(res.stderr);
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("git {s} failed: {s}\n", .{ args[0], res.stderr });
            return error.GitFailed;
        }
    }

    fn write(t: *TestApp, rel: []const u8, data: []const u8) !void {
        try t.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    /// Tick until the worker has answered everything (or `max` ticks pass).
    fn settle(t: *TestApp, max: usize) !void {
        var i: usize = 0;
        while (i < max) : (i += 1) {
            try t.app.tick(App.nowMs(testing.io));
            const gs = &t.app.git;
            if (!gs.status_pending and gs.busy == 0 and !gs.rail_pending and !git.anyRailPending(gs) and !graphPending(&t.app)) return;
            testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        }
    }

    fn graphPending(app: *App) bool {
        for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .git_graph => |*g| if (g.pending) return true,
            else => {},
        };
        return false;
    }

    fn deinit(t: *TestApp) void {
        unseed(&t.app);
        t.app.deinit();
        testing.allocator.free(t.root);
        t.tmp.cleanup();
    }
};

/// Two locals, a github remote with three branches, two worktrees (the
/// workspace itself, and one locked and dirty), a stash, two tags — the
/// seed every palette test reads.
var seed_branches = [_]parse.Branch{
    .{ .name = "main", .time = 0, .current = true, .remote = false, .upstream = "origin/main", .sha = "aaaa111", .ahead = 1, .behind = 3 },
    .{ .name = "feature", .time = 0, .current = false, .remote = false, .upstream = "origin/feature", .sha = "bbbb222" },
    .{ .name = "origin/main", .time = 0, .current = false, .remote = true, .sha = "aaaa111" },
    .{ .name = "origin/feature", .time = 0, .current = false, .remote = true, .sha = "bbbb222" },
    .{ .name = "origin/hotfix", .time = 0, .current = false, .remote = true, .sha = "cccc333" },
    .{ .name = "origin/HEAD", .time = 0, .current = false, .remote = true },
};
var seed_worktrees = [_]parse.Worktree{
    .{ .path = "", .branch = "main", .head = "aaaa111", .main = true },
    .{ .path = "/repo/wt-fix", .branch = "fix", .head = "cccc333", .locked = true, .lock_reason = "keep", .dirty = true, .dirty_files = 2 },
};
var seed_remotes = [_]parse.Remote{.{ .name = "origin", .url = "git@github.com:me/thing.git", .provider = .github }};
var seed_stashes = [_]parse.Stash{.{ .sha = "ab12cd3", .ref = "stash@{0}", .message = "On main: half done" }};
var seed_tags = [_]parse.Tag{ .{ .name = "v2.0", .sha = "aaaa111", .annotated = true }, .{ .name = "v1.0", .sha = "bbbb222", .annotated = false } };

/// Seeds the ACTIVE repo's rail as landed. Entering the mode
/// rediscovers and clears the rail, so a test that enters seeds after.
fn seed(app: *App) void {
    seed_worktrees[0].path = app.workspace;
    app.git.rail_branches = &seed_branches;
    app.git.rail_worktrees = &seed_worktrees;
    app.git.rail_remotes = &seed_remotes;
    app.git.rail_stashes = &seed_stashes;
    app.git.rail_tags = &seed_tags;
    app.git.rail_loaded = true;
}

/// A second repo's seed, parked as All repos keeps it: two locals (dev
/// checked out), one tag, nothing else.
var seed_beta_branches = [_]parse.Branch{
    .{ .name = "dev", .time = 0, .current = true, .remote = false, .sha = "dddd444" },
    .{ .name = "main", .time = 0, .current = false, .remote = false, .sha = "eeee555" },
};
var seed_beta_tags = [_]parse.Tag{.{ .name = "v0.1", .sha = "eeee555", .annotated = false }};

fn seedBeta(app: *App) !void {
    const e = try git.railEntry(app, app.git.repos.items[1].id);
    e.branches = &seed_beta_branches;
    e.tags = &seed_beta_tags;
    e.loaded = true;
}

fn unseed(app: *App) void {
    app.git.rail_branches = &.{};
    app.git.rail_worktrees = &.{};
    app.git.rail_remotes = &.{};
    app.git.rail_stashes = &.{};
    app.git.rail_tags = &.{};
    app.git.rail_loaded = false;
    var it = app.git.rails.valueIterator();
    while (it.next()) |r| {
        r.branches = &.{};
        r.worktrees = &.{};
        r.remotes = &.{};
        r.stashes = &.{};
        r.tags = &.{};
        r.prs = &.{};
    }
}

test "git.graph shows the ACTIVE repo's graph: with two discovered repos the first's tab comes back after a close hid it, and the other's is the one shown only once the panel switched to it" {
    var t = try TestApp.initWith(&.{ "alpha", "beta" });
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try command.run(app, .{ .static = .@"git.graph" });
    const alpha = app.git.repos.items[0];
    const beta = app.git.repos.items[1];
    try testing.expectEqual(alpha.id, app.git.activeRepo().?.id);
    try testing.expectEqual(alpha.id, git.activeGraph(app).?.repo);
    // Esc on the graph closes the tab and hides the repo for the
    // session; the other repo's tab is what is left on screen.
    try app.closePane(app.active.?, true);
    try testing.expect(app.git_palette.isClosed(alpha.path));
    try testing.expectEqual(beta.id, git.activeGraph(app).?.repo);
    // `git.graph` asks for the ACTIVE repo's graph: alpha's, reopened —
    // not whichever tab the layout had first.
    try command.run(app, .{ .static = .@"git.graph" });
    try testing.expectEqual(alpha.id, git.activeGraph(app).?.repo);
    try testing.expect(!app.git_palette.isClosed(alpha.path));
    const tabs = try app.layouts.current().allPanes(app.frame.allocator());
    try testing.expectEqual(@as(usize, 2), tabs.len);
    // The panel switched to beta: its graph is where `git.graph` lands.
    try git.switchTo(app, 1);
    try command.run(app, .{ .static = .@"git.graph" });
    try testing.expectEqual(beta.id, app.git.activeRepo().?.id);
    try testing.expectEqual(beta.id, git.activeGraph(app).?.repo);
    try testing.expect(app.focus == .pane and app.focus.pane == app.active.?);
}

test "the chevrons and `[` / `]` step through the repos in discovery order and wrap, the graph tab following; the rail moves with the switch; one repo leaves them inert" {
    var t = try TestApp.initWith(&.{ "alpha", "beta" });
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try testing.expectEqual(@as(usize, 2), app.git.repos.items.len);
    try testing.expectEqualStrings("alpha", app.git.repos.items[0].name);
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    try command.run(app, .{ .static = .@"view.activity_git" });
    seed(app);
    try seedBeta(app);
    const st = &app.git_palette;
    const press: Mouse = .{ .x = 9, .y = 4, .kind = .press, .button = .left };
    // `]` → beta: the active repo and the graph tab; the rows read its rail.
    try testing.expect(try handleKey(app, .{ .code = .{ .char = ']' } }));
    try testing.expectEqual(@as(usize, 1), app.git.active.?);
    try testing.expectEqual(app.git.repos.items[1].id, git.activeGraph(app).?.repo);
    var list = try rows(app, app.frame.allocator());
    try testing.expectEqual(@as(u32, 2), list[0].section.count);
    try testing.expectEqualStrings("dev", list[1].branch.name);
    try testing.expect(list[1].branch.current);
    // `]` wraps to alpha, `[` back to beta; the chevrons do the same.
    _ = try handleKey(app, .{ .code = .{ .char = ']' } });
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    _ = try handleKey(app, .{ .code = .{ .char = '[' } });
    try testing.expectEqual(@as(usize, 1), app.git.active.?);
    try partMouse(app, .repo_prev, press);
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    try testing.expectEqual(app.git.repos.items[0].id, git.activeGraph(app).?.repo);
    try partMouse(app, .repo_next, press);
    try testing.expectEqual(@as(usize, 1), app.git.active.?);
    try partMouse(app, .repo_prev, press);
    // alpha's rail came back whole (parked, not dropped): main, current, 1↑ 3↓.
    list = try rows(app, app.frame.allocator());
    try testing.expectEqualStrings("main", list[2].branch.name);
    try testing.expect(list[2].branch.current);
    try testing.expectEqual(@as(u32, 3), list[2].branch.behind);
    try testing.expectEqual(@as(usize, 0), st.cursor);
    try command.run(app, .{ .static = .@"view.activity_explorer" });
}

test "one repo: `]` is taken and does nothing" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    seed(app);
    try testing.expect(try handleKey(app, .{ .code = .{ .char = ']' } }));
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    try testing.expect(app.lastToast() == null);
}

test "All repos: every section groups per repo under a sub-header with the count summed and Viewing N over every row; a row's action makes its repo the active one and the graph tab follows; the filter skips an empty repo; the pill menu leads with it; `]` leaves it at the first repo; the flag rides the session" {
    var t = try TestApp.initWith(&.{ "alpha", "beta" });
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try command.run(app, .{ .static = .@"view.activity_git" });
    seed(app);
    try seedBeta(app);
    const st = &app.git_palette;
    try command.run(app, .{ .static = .@"git.palette_all" });
    try testing.expect(st.all);
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var list = try rows(app, arena);
    // LOCAL 4: alpha (feature, main ✓), beta (dev ✓, main).
    try testing.expectEqual(@as(u32, 4), list[0].section.count);
    try testing.expectEqualStrings("alpha", list[1].repo.name);
    try testing.expectEqual(@as(u32, 0), list[1].repo.idx);
    try testing.expectEqualStrings("feature", list[2].branch.name);
    try testing.expectEqualStrings("main", list[3].branch.name);
    try testing.expect(list[3].branch.current);
    try testing.expectEqualStrings("beta", list[4].repo.name);
    try testing.expectEqualStrings("dev", list[5].branch.name);
    try testing.expect(list[5].branch.current);
    try testing.expectEqualStrings("main", list[6].branch.name);
    try testing.expect(!list[6].branch.current);
    try testing.expect(list[7] == .gap);
    // REMOTE: alpha's origin and its three; beta's sub-header alone.
    try testing.expectEqual(@as(u32, 3), list[8].section.count);
    try testing.expectEqualStrings("alpha", list[9].repo.name);
    try testing.expectEqualStrings("origin", list[10].remote.name);
    try testing.expectEqualStrings("beta", list[14].repo.name);
    try testing.expect(list[15] == .gap);
    // alpha's 10 items + beta's 2 branches + 1 tag.
    try testing.expectEqual(@as(usize, 13), viewing(list));
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    // Enter on beta's `main`: beta becomes the active repo, its graph
    // tab comes to the front, and the checkout goes to its worker.
    try activate(app, 6);
    try testing.expectEqual(@as(usize, 1), app.git.active.?);
    try testing.expectEqual(app.git.repos.items[1].id, git.activeGraph(app).?.repo);
    try testing.expect(st.all);
    // The rows keep their shape: alpha's rail is parked, beta's live.
    list = try rows(app, arena);
    try testing.expectEqualStrings("main", list[3].branch.name);
    try testing.expect(list[3].branch.current);
    try testing.expectEqualStrings("dev", list[5].branch.name);
    try testing.expectEqual(@as(usize, 13), viewing(list));
    // The filter: under TAGS only alpha has a `v1.` (the dot keeps the
    // probe off the tmp workspace's random name, which the worktree row
    // matches by basename); beta's sub-header goes.
    try st.filter.appendSlice(testing.allocator, "v1.");
    list = try rows(app, arena);
    const tags = list[list.len - 4];
    try testing.expectEqual(Section.tags, tags.section.s);
    try testing.expectEqual(@as(u32, 1), tags.section.count);
    try testing.expectEqualStrings("alpha", list[list.len - 3].repo.name);
    try testing.expectEqualStrings("v1.0", list[list.len - 2].tag.name);
    try testing.expectEqual(@as(usize, 1), viewing(list));
    st.filter.clearRetainingCapacity();
    // The pill menu: All repos first and marked; the repos unmarked.
    try openReposMenu(app, 2, 4);
    try testing.expect(std.mem.startsWith(u8, app.overlay.menu.items[0].label, "\u{25CF} All repos"));
    try testing.expect(std.mem.startsWith(u8, app.overlay.menu.items[1].label, "  alpha"));
    try testing.expect(std.mem.startsWith(u8, app.overlay.menu.items[2].label, "  beta"));
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // The session carries the flag.
    try @import("session.zig").save(app);
    st.all = false;
    try @import("session.zig").restore(app);
    try testing.expect(st.all);
    // `]` under All repos: the first repo, All repos off.
    _ = try handleKey(app, .{ .code = .{ .char = ']' } });
    try testing.expect(!st.all);
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    list = try rows(app, arena);
    try testing.expectEqual(@as(u32, 2), list[0].section.count);
    try testing.expect(list[1] == .branch);
    try command.run(app, .{ .static = .@"view.activity_explorer" });
}

test "rows: the five sections in order with their counts; LOCAL A–Z with the current one and its ahead / behind; each remote with its branches stripped of the prefix; the worktrees' lock and dirty state; stashes and tags" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try testing.expect(app.git.activeRepo() != null);
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    seed(app);
    const list = try rows(app, arena);
    // LOCAL 2 + gap, REMOTE (origin + 3) + gap, WORKTREES 2 + gap, STASHES 1 + gap, TAGS 2 + gap.
    try testing.expectEqual(@as(usize, 21), list.len);
    try testing.expectEqual(Section.local, list[0].section.s);
    try testing.expectEqual(@as(u32, 2), list[0].section.count);
    try testing.expectEqualStrings("feature", list[1].branch.name);
    try testing.expectEqualStrings("main", list[2].branch.name);
    try testing.expect(list[2].branch.current);
    try testing.expectEqual(@as(u32, 1), list[2].branch.ahead);
    try testing.expectEqual(@as(u32, 3), list[2].branch.behind);
    try testing.expect(list[3] == .gap);
    try testing.expectEqual(Section.remote, list[4].section.s);
    try testing.expectEqual(@as(u32, 3), list[4].section.count);
    try testing.expectEqualStrings("origin", list[5].remote.name);
    try testing.expect(list[5].remote.github);
    try testing.expectEqualStrings("feature", list[6].remote_branch.shown);
    try testing.expectEqualStrings("origin/feature", list[6].remote_branch.name);
    try testing.expectEqualStrings("hotfix", list[7].remote_branch.shown);
    try testing.expectEqualStrings("main", list[8].remote_branch.shown);
    try testing.expect(list[9] == .gap);
    try testing.expectEqual(Section.worktrees, list[10].section.s);
    try testing.expect(std.mem.startsWith(u8, list[11].worktree.shown, "main ("));
    try testing.expect(list[11].worktree.main);
    try testing.expect(!list[11].worktree.locked);
    // The workspace's own tree is the current one, with main's counts.
    try testing.expect(list[11].worktree.current);
    try testing.expectEqual(@as(u32, 1), list[11].worktree.ahead);
    try testing.expectEqualStrings("fix (wt-fix)", list[12].worktree.shown);
    try testing.expect(list[12].worktree.locked and list[12].worktree.dirty and !list[12].worktree.main);
    // sessions-worktree: neither tree is a session's yet.
    try testing.expect(!list[11].worktree.session and list[11].worktree.accent == null);
    try testing.expect(!list[12].worktree.session and list[12].worktree.accent == null);
    try openRowMenu(app, 12, 0, 0);
    for (app.overlay.menu.items) |mi| try testing.expect(!std.mem.startsWith(u8, mi.label, "Merge into "));
    try app.handle(.{ .key = Key.named(.esc) });
    // The registry names wt-fix as sid-1's tree and sid-1 is pink: the
    // row carries the accent, and its menu the session verbs.
    try app.sessions.worktrees.add(app.gpa, "/repo/wt-fix", "wt-fix", "fix", app.workspace, "sid-1");
    try app.sessions.setColor(app.gpa, "sid-1", "pink");
    const list2 = try rows(app, arena);
    try testing.expect(list2[12].worktree.session);
    try testing.expect(Theme.Color.eql(list2[12].worktree.accent.?, app.theme.palette.pink));
    try testing.expect(list2[11].worktree.accent == null);
    try openRowMenu(app, 12, 0, 0);
    var merge_row: ?command.GitPaletteAct = null;
    var remove_row: ?command.GitPaletteAct = null;
    for (app.overlay.menu.items) |mi| {
        if (std.mem.startsWith(u8, mi.label, "Merge into ")) merge_row = mi.action.git_palette;
        if (std.mem.eql(u8, mi.label, "Remove worktree and delete branch\u{2026}")) remove_row = mi.action.git_palette;
    }
    try testing.expect(merge_row.?.what == .session_merge and merge_row.?.idx == 1);
    try testing.expect(remove_row.?.what == .session_remove);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expectEqual(Section.stashes, list[14].section.s);
    try testing.expectEqualStrings("ab12cd3", list[15].stash.sha);
    try testing.expectEqualStrings("On main: half done", list[15].stash.message);
    try testing.expectEqual(Section.tags, list[17].section.s);
    try testing.expectEqualStrings("v2.0", list[18].tag.name);
    try testing.expectEqualStrings("v1.0", list[19].tag.name);
    try testing.expectEqual(@as(usize, 10), viewing(list));
}

test "the filter narrows every section by substring and Viewing N follows; a folded section keeps its header and count; the folds survive the mode's leave and re-entry" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try testing.expect(app.git.activeRepo() != null);
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    seed(app);
    try app.git_palette.filter.appendSlice(testing.allocator, "fea");
    var list = try rows(app, arena);
    // LOCAL feature; REMOTE origin/feature; the rest empty but headed.
    try testing.expectEqual(@as(u32, 1), list[0].section.count);
    try testing.expectEqualStrings("feature", list[1].branch.name);
    try testing.expectEqual(@as(u32, 1), list[3].section.count);
    try testing.expectEqualStrings("origin", list[4].remote.name);
    try testing.expectEqualStrings("feature", list[5].remote_branch.shown);
    try testing.expectEqual(@as(u32, 0), list[7].section.count);
    try testing.expect(list[8] == .gap);
    try testing.expectEqual(@as(u32, 0), list[9].section.count);
    try testing.expectEqual(@as(u32, 0), list[11].section.count);
    try testing.expectEqual(@as(usize, 2), viewing(list));
    app.git_palette.filter.clearRetainingCapacity();
    try app.git_palette.filter.appendSlice(testing.allocator, "v1.");
    list = try rows(app, arena);
    try testing.expectEqual(@as(u32, 1), list[list.len - 3].section.count);
    try testing.expectEqualStrings("v1.0", list[list.len - 2].tag.name);
    try testing.expectEqual(@as(usize, 1), viewing(list));
    app.git_palette.filter.clearRetainingCapacity();
    // Fold LOCAL through Enter on its header; the count stays.
    try activate(app, 0);
    list = try rows(app, arena);
    try testing.expect(list[0].section.collapsed);
    try testing.expectEqual(@as(u32, 2), list[0].section.count);
    try testing.expect(list[1] == .gap);
    try testing.expectEqual(@as(usize, 8), viewing(list));
    // Leave and re-enter the mode: the fold is still there.
    try command.run(app, .{ .static = .@"view.activity_git" });
    try command.run(app, .{ .static = .@"view.activity_explorer" });
    try command.run(app, .{ .static = .@"view.activity_git" });
    try testing.expect(app.git_palette.collapsed.contains(.local));
    try command.run(app, .{ .static = .@"view.activity_explorer" });
}

test "the click model: one click on an item row gives the panel the keys and moves nothing, a double-click acts (the stash shows its files, Enter on the tag row names detached HEAD), a right-click opens the row's menu with the cursor where it was, two clicks apart are two hovers; the keys skip the gaps" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try testing.expect(app.git.activeRepo() != null);
    seed(app);
    const st = &app.git_palette;
    // Down from LOCAL's header lands on feature, then main, then skips the gap to REMOTE.
    try testing.expect(try handleKey(app, .{ .code = .down }));
    try testing.expectEqual(@as(usize, 1), st.cursor);
    _ = try handleKey(app, .{ .code = .{ .char = 'j' } });
    _ = try handleKey(app, .{ .code = .{ .char = 'j' } });
    try testing.expectEqual(@as(usize, 4), st.cursor);
    _ = try handleKey(app, .{ .code = .{ .char = 'G' } });
    try testing.expectEqual(@as(usize, 19), st.cursor);
    _ = try handleKey(app, .{ .code = .{ .char = 'g' } });
    try testing.expectEqual(@as(usize, 0), st.cursor);
    // One click on the stash row: the panel has the keys; the cursor
    // stays on row 0, nothing is selected, nothing is said.
    const press: Mouse = .{ .x = 5, .y = 20, .kind = .press, .button = .left };
    app.focus = .tree;
    try rowMouse(app, 15, press);
    try testing.expect(app.focus == .panel and app.focus.panel == .git);
    try testing.expectEqual(@as(usize, 0), st.cursor);
    try testing.expect(st.selected == null);
    try testing.expect(app.lastToast() == null);
    // A second click past the double-click window is one more hover.
    app.now_ms += app_mod.double_click_ms + 1;
    try rowMouse(app, 15, press);
    try testing.expectEqual(@as(usize, 0), st.cursor);
    try testing.expect(st.selected == null);
    // The second press of a double-click acts: the row is selected and
    // the stash's files are asked for (the seeded ref is not in the
    // repo, so the worker says so; the point is that it ran).
    try rowMouse(app, 15, press);
    try testing.expectEqual(@as(usize, 15), st.cursor);
    try testing.expectEqualStrings("stash@{0}", st.selected.?);
    // A right-click on the tag row: its menu, the cursor still on the stash.
    try rowMouse(app, 18, .{ .x = 5, .y = 23, .kind = .press, .button = .right });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("v2.0", app.overlay.menu.title);
    try testing.expectEqual(@as(usize, 15), st.cursor);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // Enter on the tag row opens the confirm.
    st.cursor = 18;
    _ = try handleKey(app, .{ .code = .enter });
    try testing.expect(app.git.confirm == .checkout);
    try testing.expectEqualStrings("v2.0", app.git.confirm.checkout);
    try testing.expect(std.mem.indexOf(u8, app.overlay.confirm.message, "detached HEAD") != null);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    try testing.expect(app.overlay == .none);
    // `/` focuses the filter; typing narrows and puts the cursor back on top; Esc clears.
    _ = try handleKey(app, .{ .code = .{ .char = '/' } });
    try testing.expect(st.filter_focused);
    _ = try handleKey(app, .{ .code = .{ .char = 'v' } });
    try testing.expectEqualStrings("v", st.filter.items);
    try testing.expectEqual(@as(usize, 0), st.cursor);
    _ = try handleKey(app, .{ .code = .esc });
    try testing.expectEqual(@as(usize, 0), st.filter.items.len);
    try testing.expect(st.filter_focused);
    _ = try handleKey(app, .{ .code = .esc });
    try testing.expect(!st.filter_focused);
}

test "a double-click on a worktree row, through the painted panel's hit map, switches the graph tab to THAT worktree — the tab's name and its repo are the tree's, not its neighbour's — and one click there switches nothing" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try t.write("a.txt", "one\n");
    try t.sh(&.{ "add", "a.txt" });
    try t.sh(&.{ "commit", "-q", "-m", "init" });
    try t.sh(&.{ "worktree", "add", "-q", "wt-a", "-b", "feat-a" });
    try t.sh(&.{ "worktree", "add", "-q", "wt-b", "-b", "feat-b" });
    try command.run(app, .{ .static = .@"view.activity_git" });
    try t.settle(600);
    try testing.expect(app.git.rail_loaded);
    const ws = app.git.activeRepo().?;
    const ws_id = ws.id;
    try app.render();
    // The two linked trees' rows, neighbours under WORKTREES.
    const list = try rows(app, app.frame.allocator());
    var a_idx: ?usize = null;
    var b_idx: ?usize = null;
    for (list, 0..) |r, i| switch (r) {
        .worktree => |w| {
            if (std.mem.startsWith(u8, w.shown, "feat-a")) a_idx = i;
            if (std.mem.startsWith(u8, w.shown, "feat-b")) b_idx = i;
        },
        else => {},
    };
    const ra = rowRect(app, @intCast(a_idx.?)) orelse return error.TestUnexpectedResult;
    const rb = rowRect(app, @intCast(b_idx.?)) orelse return error.TestUnexpectedResult;
    // The hits are one row each, the full column across.
    try testing.expectEqual(ra.y + 1, rb.y);
    try testing.expectEqual(@as(u16, 1), rb.h);
    try testing.expect(rb.w >= 16);
    const x = rb.x + 3;
    const y = rb.y;
    // One click: the panel has the keys; the tab is still the workspace's.
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .release, .button = .left } });
    try testing.expect(app.focus == .panel and app.focus.panel == .git);
    try testing.expectEqual(ws_id, app.git.activeRepo().?.id);
    try testing.expectEqual(ws_id, git.activeGraph(app).?.repo);
    // The second press of the double-click: the tab is wt-b's — its
    // name, its repo — not wt-a's above it.
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = x, .y = y, .kind = .release, .button = .left } });
    try t.settle(600);
    const now = app.git.activeRepo().?;
    try testing.expect(now.id != ws_id);
    try testing.expectEqualStrings("wt-b", std.fs.path.basename(now.path));
    const g = git.activeGraph(app) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(now.id, g.repo);
    try testing.expectEqualStrings("wt-b", g.name);
    try testing.expect(app.active != null);
    try testing.expect(app.panes.get(app.active.?).?.* == .git_graph);
    try command.run(app, .{ .static = .@"view.activity_explorer" });
}

/// The labels of the open menu's rows, on `arena`.
fn menuLabels(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (app.overlay.menu.items) |it| try out.append(arena, it.label);
    return out.items;
}

fn expectMenu(app: *App, idx: usize, labels: []const []const u8) !void {
    try openRowMenu(app, idx, 3, 3);
    if (app.overlay != .menu) {
        std.debug.print("row {d}: no menu opened\n", .{idx});
        return error.TestUnexpectedResult;
    }
    const got = try menuLabels(app, app.frame.allocator());
    if (got.len != labels.len) {
        std.debug.print("row {d}: {d} rows, want {d}:\n", .{ idx, got.len, labels.len });
        for (got) |l| std.debug.print("  {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
    for (got, labels) |g, w| try testing.expectEqualStrings(w, g);
}

/// The last toast's text, empty when there is none — a missing toast
/// fails an expect instead of unwrapping null.
fn lastToastText(app: *App) []const u8 {
    return app.lastToast() orelse "";
}

/// The WORKTREES menu, whose lock row reads the tree's own state: the
/// seed's main tree is unlocked, its linked tree locked.
const worktree_menu_unlocked = [_][]const u8{ "Open this worktree", "Open worktree in new tab", "Open shell here", "Lock worktree\u{2026}", "Copy path", "New worktree\u{2026}", "Remove this worktree\u{2026}", "Remove worktree and delete branch\u{2026}" };
const worktree_menu_locked = [_][]const u8{ "Open this worktree", "Open worktree in new tab", "Open shell here", "Unlock worktree", "Copy path", "New worktree\u{2026}", "Remove this worktree\u{2026}", "Remove worktree and delete branch\u{2026}" };

test "row menus: one shape per row kind, built from the row under the pointer while the cursor stays; the main tree and the tree on show keep Remove and are refused by name; a prefix-only remote keeps Copy URL and says so; Reset targets the row, not the cursor; a stale index opens nothing; under All repos a right-click on another repo's row switches nothing and its rows carry the repo, which the act switches to" {
    var t = try TestApp.initWith(&.{ "alpha", "beta" });
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try command.run(app, .{ .static = .@"view.activity_git" });
    seed(app);
    try seedBeta(app);
    const st = &app.git_palette;
    st.cursor = 0;
    // alpha's seed: LOCAL 0, feature 1, main 2, gap, REMOTE 4, origin 5,
    // feature 6, hotfix 7, main 8, gap, WORKTREES 10, main 11, wt-fix
    // 12, gap, STASHES 14, stash 15, gap, TAGS 17, v2.0 18, v1.0 19.
    try expectMenu(app, 0, &.{ "Fold", "Refresh" });
    try testing.expectEqualStrings("LOCAL", app.overlay.menu.title);
    try app.handle(.{ .key = Key.named(.esc) });
    try expectMenu(app, 1, &.{ "Checkout feature", "Pull (fast-forward if possible)", "Push", "Push and start PR", "Set upstream\u{2026}", "Merge feature into main", "Rebase main onto feature", "Interactive rebase main onto feature\u{2026}", "Open worktree from feature\u{2026}", "Create branch here\u{2026}", "Cherry pick commit", "Reset main to this commit", "Revert commit", "Rename feature\u{2026}", "Delete feature\u{2026}", "Delete on the remote\u{2026}", "Force checkout feature\u{2026}", "Diff against main", "Explain branch changes (AI)", "Copy branch name", "Copy commit sha", "Copy link to branch", "Copy link to this commit on remote", "Create tag here\u{2026}", "Create annotated tag here\u{2026}" });
    try testing.expectEqualStrings("feature", app.overlay.menu.title);
    // The Reset row opens to the right: soft / mixed / hard, each an
    // act on feature; the row itself runs nothing.
    const reset_row = app.overlay.menu.items[11];
    try testing.expect(reset_row.action == .none);
    try testing.expectEqual(@as(usize, 3), reset_row.submenu.len);
    try testing.expectEqual(command.GitPaletteWhat.reset_soft, reset_row.submenu[0].action.git_palette.what);
    try testing.expectEqual(command.GitPaletteWhat.reset_hard, reset_row.submenu[2].action.git_palette.what);
    try testing.expectEqual(@as(u32, 1), reset_row.submenu[2].action.git_palette.idx);
    try app.handle(.{ .key = Key.named(.esc) });
    try expectMenu(app, 2, &.{ "Pull (fast-forward if possible)", "Push", "Push --force-with-lease\u{2026}", "Push and start PR", "Set upstream\u{2026}", "Open worktree from main\u{2026}", "Create branch here\u{2026}", "Revert commit", "Rename main\u{2026}", "Delete on the remote\u{2026}", "Explain branch changes (AI)", "Copy branch name", "Copy commit sha", "Copy link to branch", "Copy link to this commit on remote", "Create tag here\u{2026}", "Create annotated tag here\u{2026}" });
    try testing.expectEqualStrings("\u{25CF} main", app.overlay.menu.title);
    try app.handle(.{ .key = Key.named(.esc) });
    try expectMenu(app, 5, &.{ "Fetch", "Copy URL" });
    try app.handle(.{ .key = Key.named(.esc) });
    try expectMenu(app, 6, &.{ "Merge origin/feature into main", "Rebase main onto origin/feature", "Checkout origin/feature", "Create worktree from origin/feature\u{2026}", "Create branch here\u{2026}", "Cherry pick commit", "Reset main to this commit", "Revert commit", "Delete origin/feature\u{2026}", "Diff against main", "Explain branch changes (AI)", "Copy branch name", "Copy commit sha", "Copy link to branch", "Copy link to this commit on remote", "Create tag here\u{2026}", "Create annotated tag here\u{2026}" });
    try app.handle(.{ .key = Key.named(.esc) });
    // The main tree (the workspace, on show) and the locked linked tree:
    // the same five rows.
    try expectMenu(app, 11, &worktree_menu_unlocked);
    try testing.expect(std.mem.startsWith(u8, app.overlay.menu.title, "main  "));
    try app.handle(.{ .key = Key.named(.esc) });
    try expectMenu(app, 12, &worktree_menu_locked);
    try testing.expect(std.mem.startsWith(u8, app.overlay.menu.title, "fix  /repo/wt-fix"));
    try app.handle(.{ .key = Key.named(.esc) });
    try expectMenu(app, 15, &.{ "Show files (Enter)", "Apply (keep)", "Pop (apply + drop)", "Drop\u{2026}", "Branch from stash\u{2026}", "Rename\u{2026}" });
    try app.handle(.{ .key = Key.named(.esc) });
    try expectMenu(app, 18, &.{ "Checkout v2.0 (detached)", "Copy name (v2.0)", "Delete v2.0\u{2026}", "New branch from tag\u{2026}", "New worktree from tag\u{2026}" });
    try app.handle(.{ .key = Key.named(.esc) });
    // None of that moved the cursor, and outside All repos no act names a repo.
    try testing.expectEqual(@as(usize, 0), st.cursor);
    try openRowMenu(app, 12, 3, 3);
    for (app.overlay.menu.items) |it| try testing.expect(it.action.git_palette.repo == null);
    try app.handle(.{ .key = Key.named(.esc) });
    // Remove on the main tree: refused by name. On a linked tree that is
    // the one on show: refused too. On wt-fix: the confirm.
    try menuAction(app, .{ .what = .worktree_remove, .idx = 0 });
    try testing.expect(std.mem.indexOf(u8, lastToastText(app), "main worktree") != null);
    try testing.expect(app.overlay != .confirm);
    // (In this two-repo fixture the seed's first tree is the workspace,
    // not alpha's path: point it at the repo on show for the probe.)
    seed_worktrees[0].main = false;
    seed_worktrees[0].path = app.git.activeRepo().?.path;
    try menuAction(app, .{ .what = .worktree_remove, .idx = 0 });
    seed_worktrees[0].main = true;
    seed_worktrees[0].path = app.workspace;
    try testing.expect(std.mem.indexOf(u8, lastToastText(app), "tree on show") != null);
    try testing.expect(app.overlay != .confirm);
    try menuAction(app, .{ .what = .worktree_remove, .idx = 1 });
    try testing.expect(app.git.confirm == .worktree_remove);
    try testing.expectEqualStrings("/repo/wt-fix", app.git.confirm.worktree_remove);
    try app.handle(.{ .key = Key.named(.esc) });
    // Reset reads the ROW's branch: the cursor is on LOCAL's header, the
    // menu was opened on feature, the confirm names feature.
    try testing.expectEqual(@as(usize, 0), st.cursor);
    try openRowMenu(app, 1, 3, 3);
    const hard = app.overlay.menu.items[11].submenu[2];
    try testing.expectEqualStrings("Hard (discard the changes)\u{2026}", hard.label);
    try dispatch.runMenuActionForTest(app, hard.action);
    try testing.expect(app.git.confirm == .reset_hard);
    try testing.expectEqualStrings("feature", app.git.confirm.reset_hard);
    try app.handle(.{ .key = Key.named(.esc) });
    // The reference client's verbs on feature (rail idx 1, sha bbbb222,
    // origin at github.com:me/thing): the copies land on the clipboard
    // with the forge's URLs; a tag prompt keeps the row as its start;
    // cherry-pick, revert and push go to the worker.
    try menuAction(app, .{ .what = .copy_sha, .idx = 1 });
    try testing.expectEqualStrings("bbbb222", app.clipboard.text());
    try menuAction(app, .{ .what = .copy_branch_link, .idx = 1 });
    try testing.expectEqualStrings("https://github.com/me/thing/tree/feature", app.clipboard.text());
    try menuAction(app, .{ .what = .copy_commit_link, .idx = 1 });
    try testing.expectEqualStrings("https://github.com/me/thing/commit/bbbb222", app.clipboard.text());
    // A remote branch's link drops its prefix.
    try menuAction(app, .{ .what = .copy_branch_link, .idx = 4 });
    try testing.expectEqualStrings("https://github.com/me/thing/tree/hotfix", app.clipboard.text());
    try menuAction(app, .{ .what = .tag_annotated_here, .idx = 1 });
    try testing.expect(app.overlay == .prompt);
    try testing.expect(app.git.prompt == .tag_annotated_at);
    try testing.expectEqualStrings("feature", app.git.verb_start.?);
    try app.handle(.{ .key = Key.named(.esc) });
    const busy_before = app.git.busy;
    try menuAction(app, .{ .what = .cherry_pick, .idx = 1 });
    try menuAction(app, .{ .what = .revert, .idx = 1 });
    try menuAction(app, .{ .what = .push_branch, .idx = 1 });
    try testing.expectEqual(busy_before + 3, app.git.busy);
    try testing.expect(std.mem.indexOf(u8, lastToastText(app), "pushing feature to origin") != null);
    // A branch under a prefix no `git remote` names: its remote row
    // keeps both rows; Copy URL says there is none.
    var fork_branches = seed_branches ++ [_]parse.Branch{.{ .name = "fork/x", .time = 0, .current = false, .remote = true, .sha = "ffff666" }};
    app.git.rail_branches = &fork_branches;
    const forked = try rows(app, app.frame.allocator());
    var fork_row: ?usize = null;
    for (forked, 0..) |r, i| if (r == .remote and std.mem.eql(u8, r.remote.name, "fork")) {
        fork_row = i;
    };
    try expectMenu(app, fork_row.?, &.{ "Fetch", "Copy URL" });
    const copy = app.overlay.menu.items[1];
    try app.handle(.{ .key = Key.named(.esc) });
    try dispatch.runMenuActionForTest(app, copy.action);
    try testing.expect(std.mem.indexOf(u8, lastToastText(app), "no such git remote") != null);
    app.git.rail_branches = &seed_branches;
    // A stale index (the rows changed under the pointer): no menu, a word.
    try openRowMenu(app, 999, 3, 3);
    try testing.expect(app.overlay != .menu);
    try testing.expect(std.mem.indexOf(u8, lastToastText(app), "row changed") != null);
    // All repos: beta's `dev` (row 5) with alpha active and the cursor
    // on row 0 — the menu is dev's, alpha stays active, every row
    // carries beta; Copy name switches to beta and copies.
    try command.run(app, .{ .static = .@"git.palette_all" });
    st.cursor = 0;
    const all = try rows(app, app.frame.allocator());
    try testing.expectEqualStrings("dev", all[5].branch.name);
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    try openRowMenu(app, 5, 3, 3);
    try testing.expectEqualStrings("\u{25CF} dev", app.overlay.menu.title);
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    try testing.expectEqual(@as(usize, 0), st.cursor);
    var copy_dev: ?command.MenuAction = null;
    for (app.overlay.menu.items) |it| {
        try testing.expectEqual(@as(?u32, 1), it.action.git_palette.repo);
        if (std.mem.eql(u8, it.label, "Copy branch name")) copy_dev = it.action;
    }
    try app.handle(.{ .key = Key.named(.esc) });
    try dispatch.runMenuActionForTest(app, copy_dev.?);
    try testing.expectEqual(@as(usize, 1), app.git.active.?);
    try testing.expectEqualStrings("dev", app.clipboard.text());
    // beta's sub-header: show only beta / refresh.
    try expectMenu(app, 4, &.{ "Show only beta", "Refresh" });
    try app.handle(.{ .key = Key.named(.esc) });
    try command.run(app, .{ .static = .@"git.palette_all" });
    try command.run(app, .{ .static = .@"view.activity_explorer" });
}

test "All repos is discoverable: the pill's hover help names it and its command, the pill's menu leads with it, and the toggle, the chevrons and `]` all reach it" {
    var t = try TestApp.initWith(&.{ "alpha", "beta" });
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try command.run(app, .{ .static = .@"view.activity_git" });
    seed(app);
    try seedBeta(app);
    const st = &app.git_palette;
    const discovery = @import("discovery.zig");
    const tip = (try discovery.describe(app, app.frame.allocator(), .{ .git_palette = .repo })).?;
    try testing.expect(std.mem.indexOf(u8, tip.detail.?, "All repos") != null);
    try testing.expect(std.mem.indexOf(u8, tip.detail.?, "git.palette_all") != null);
    const next = (try discovery.describe(app, app.frame.allocator(), .{ .git_palette = .repo_next })).?;
    try testing.expect(std.mem.indexOf(u8, next.detail.?, "]") != null);
    // The pill's menu: All repos first; picking it turns the mode on.
    try openReposMenu(app, 2, 4);
    try testing.expect(std.mem.endsWith(u8, app.overlay.menu.items[0].label, "All repos"));
    const all_row = app.overlay.menu.items[0].action;
    try app.handle(.{ .key = Key.named(.esc) });
    try dispatch.runMenuActionForTest(app, all_row);
    try testing.expect(st.all);
    // The command toggles it off and on; a chevron leaves it at a repo.
    try command.run(app, .{ .static = .@"git.palette_all" });
    try testing.expect(!st.all);
    try command.run(app, .{ .static = .@"git.palette_all" });
    try testing.expect(st.all);
    try partMouse(app, .repo_next, .{ .x = 9, .y = 4, .kind = .press, .button = .left });
    try testing.expect(!st.all);
    try testing.expectEqual(@as(usize, 0), app.git.active.?);
    try command.run(app, .{ .static = .@"view.activity_explorer" });
}

test "every row menu names actions that resolve, and each menu action reaches the worker or a confirm" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try testing.expect(app.git.activeRepo() != null);
    seed(app);
    const list = try rows(app, app.frame.allocator());
    // Open the menu on every stop — the headers included: no crash, a
    // title, at least one row, every row a palette act (a command id
    // would resolve by construction — `MenuAction.command` is the enum).
    for (list, 0..) |r, i| {
        if (!r.isStop()) continue;
        try openRowMenu(app, i, 3, 3);
        try testing.expect(app.overlay == .menu);
        try testing.expect(app.overlay.menu.items.len > 0);
        for (app.overlay.menu.items) |it| switch (it.action) {
            .command => |id| try testing.expect(command.by_name.get(command.name(id)) != null),
            .git_palette => {},
            // A row that opens to the right runs nothing itself; its
            // children are acts.
            .none => {
                try testing.expect(it.submenu.len > 0);
                for (it.submenu) |sub| try testing.expect(sub.action == .git_palette);
            },
            else => return error.TestUnexpectedResult,
        };
        try app.handle(.{ .key = app_mod.Key.named(.esc) });
    }
    // The tag delete confirm.
    try menuAction(app, .{ .what = .tag_delete, .idx = 1 });
    try testing.expect(app.git.confirm == .tag_delete);
    try testing.expectEqualStrings("v1.0", app.git.confirm.tag_delete);
    try app.handle(.{ .key = app_mod.Key.named(.esc) });
    // The copies land on the clipboard.
    try menuAction(app, .{ .what = .remote_copy_url, .idx = 0 });
    try testing.expectEqualStrings("git@github.com:me/thing.git", app.clipboard.text());
    try menuAction(app, .{ .what = .tag_copy, .idx = 0 });
    try testing.expectEqualStrings("v2.0", app.clipboard.text());
    try menuAction(app, .{ .what = .worktree_copy_path, .idx = 1 });
    try testing.expectEqualStrings("/repo/wt-fix", app.clipboard.text());
}

// ─── the accent (colors) ───────────────────────────────────────────────

const load_mod = @import("../config/load.zig");

/// The pane rect of `id` from the last frame's hit map.
fn paneRect(app: *App, id: PaneId) ?Rect {
    for (app.hits.items.items) |h| switch (h.target) {
        .pane => |p| if (p == id) return h.rect,
        else => {},
    };
    return null;
}

fn rowRect(app: *App, idx: u32) ?Rect {
    for (app.hits.items.items) |h| switch (h.target) {
        .row => |r| if (r.panel == .git and r.idx == idx) return h.rect,
        else => {},
    };
    return null;
}

fn pillRect(app: *App) ?Rect {
    for (app.hits.items.items) |h| switch (h.target) {
        .git_palette => |part| if (part == .repo) return h.rect,
        else => {},
    };
    return null;
}

test "colors: two repos take the palette in discovery order and one repo none; a pick persists home and wins on a reload, the slot written on first sight holds, Auto goes back to the slot" {
    var t = try TestApp.initWith(&.{ "alpha", "beta" });
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try ensureRepoColors(app);
    try testing.expectEqualStrings("green", repoColorName(app, 0).?);
    try testing.expectEqualStrings("blue", repoColorName(app, 1).?);
    try testing.expect(repoColorName(app, 2) == null);
    try testing.expect(Theme.Color.eql(repoAccent(app, app.git.repos.items[1].id).?, app.theme.palette.blue));
    try setRepoColor(app, 1, "red");
    try testing.expectEqualStrings("red", repoColorName(app, 1).?);
    try setRepoColor(app, 1, "mauve");
    try testing.expectEqualStrings("blue", repoColorName(app, 1).?);
    try setRepoColor(app, 1, "red");
    // The home config holds both: alpha's slot, beta's pick.
    const path = try std.fs.path.join(testing.allocator, &.{ t.root, "config.zon" });
    defer testing.allocator.free(path);
    const text = try Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".alpha = \"green\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".beta = \"red\"") != null);
    // A fresh app on that config: beta's pick wins over its slot, and
    // alpha keeps green even after a repo sorted before it joins.
    try t.tmp.dir.createDirPath(testing.io, "aardvark");
    {
        const dir = try std.fs.path.join(testing.allocator, &.{ t.root, "aardvark" });
        defer testing.allocator.free(dir);
        try TestApp.gitInit(dir);
    }
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    const loaded = try load_mod.load(testing.allocator, testing.io, .{ .explicit = path, .workspace = t.root, .trust = .trusted, .env = .{ .vars = &env } });
    var app2 = try App.initWith(testing.allocator, testing.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = t.root, .data_root = t.root, .cols = 120, .rows = 40 });
    defer app2.deinit();
    try git.discover(&app2);
    try ensureRepoColors(&app2);
    try testing.expectEqualStrings("aardvark", app2.git.repos.items[0].name);
    try testing.expectEqualStrings("green", repoColorName(&app2, 0).?);
    try testing.expectEqualStrings("green", repoColorName(&app2, 1).?);
    try testing.expectEqualStrings("red", repoColorName(&app2, 2).?);
    // Auto: back on the slot, persisted as `none`.
    try setRepoColor(&app2, 2, accent_color.none);
    try testing.expectEqualStrings("yellow", repoColorName(&app2, 2).?);
}

test "the repos menu keeps its labels while open: the frame arena's reuse cannot scribble them" {
    // The frame arena over a fixed buffer: a reset hands the same bytes
    // back, so the next frame's allocations land exactly where the
    // last frame's did — which is what the app's allocator does in
    // steady state, and what painted garbage in every row but the
    // first when the labels lived there.
    var frame_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&frame_buf);
    var t = try TestApp.initWith(&.{ "alpha", "beta" });
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    app.frame.deinit();
    app.frame = alloc.FrameArena.init(fba.allocator());
    try openReposMenu(app, 5, 5);
    try testing.expect(app.overlay == .menu);
    app.frame.begin();
    for (0..1024) |_| {
        const chunk = try app.frame.allocator().alloc(u8, 16);
        @memset(chunk, 'X');
    }
    try testing.expect(std.mem.endsWith(u8, app.overlay.menu.items[1].label, "alpha"));
    try testing.expect(std.mem.endsWith(u8, app.overlay.menu.items[2].label, "beta"));
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    // Hand the app back a heap-backed frame before it tears down.
    app.frame.deinit();
    app.frame = alloc.FrameArena.init(app.gpa);
}

test "a row menu keeps its labels while open: the frame arena's reuse cannot scribble them" {
    // The other half of the row-menu fix: every label carries the row's
    // name, so they live on the arena the menu owns. Backed by a fixed
    // buffer, where a reset hands the same bytes back — a gpa-backed
    // arena moves its node instead and the dead bytes stay readable,
    // which is how a test of this shape passes while the app paints tofu.
    var frame_buf: [256 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&frame_buf);
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try command.run(app, .{ .static = .@"view.activity_git" });
    seed(app);
    app.frame.deinit();
    app.frame = alloc.FrameArena.init(fba.allocator());
    // Row 1 is the `feature` branch: most of its rows name it.
    try openRowMenu(app, 1, 3, 3);
    try testing.expect(app.overlay == .menu);
    app.frame.begin();
    for (0..1024) |_| {
        const chunk = try app.frame.allocator().alloc(u8, 16);
        @memset(chunk, 'X');
    }
    try testing.expectEqualStrings("Checkout feature", app.overlay.menu.items[0].label);
    try testing.expectEqualStrings("Merge feature into main", app.overlay.menu.items[5].label);
    try testing.expectEqualStrings("Delete feature\u{2026}", app.overlay.menu.items[14].label);
    app.overlay.deinit(app.gpa);
    app.overlay = .none;
    app.frame.deinit();
    app.frame = alloc.FrameArena.init(app.gpa);
}

test "one repo: no accent anywhere — the pill, the panes and the tree paint as before, and the pill's right-click is the repos menu" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try command.run(app, .{ .static = .@"view.activity_git" });
    seed(app);
    try app.render();
    try testing.expect(repoColorName(app, 0) == null);
    const pill = pillRect(app) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(" ", app.screen.readCell(pill.x - 1, pill.y).?.char.grapheme);
    const pane = paneRect(app, app.active.?) orelse return error.TestUnexpectedResult;
    // // changed (pane-rail): the pane's left column IS a rail now —
    // every pane has one — but it is the pane's own slot off the
    // shared ladder, not a repo accent. One repo has nothing to tell
    // apart, so no repo colour reaches it.
    const edge = app.screen.readCell(pane.x, pane.y + 1).?;
    try testing.expectEqualStrings("\u{258c}", edge.char.grapheme);
    try testing.expect(repoAccent(app, 0) == null);
    try app.handle(.{ .mouse = .{ .x = pill.x + 1, .y = pill.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("Repos", app.overlay.menu.title);
    try app.handle(.{ .key = Key.named(.esc) });
}

test "colors on screen: the pill's column 0, the All-repos sub-headers' gutters, the graph and status panes' left edge and their tab glyphs carry each repo's accent; the pill's right-click lists the colours" {
    var t = try TestApp.initWith(&.{ "alpha", "beta" });
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try command.run(app, .{ .static = .@"view.activity_git" });
    seed(app);
    try seedBeta(app);
    try app.render();
    const green = app.theme.palette.green;
    const blue = app.theme.palette.blue;
    // The pill: alpha is active, its `▌` at the column before the pill.
    const pill = pillRect(app) orelse return error.TestUnexpectedResult;
    const pill_cell = app.screen.readCell(pill.x - 1, pill.y).?;
    try testing.expectEqualStrings("\u{258c}", pill_cell.char.grapheme);
    try testing.expect(Theme.Color.eql(pill_cell.style.fg, green));
    // The graph pane: the strip row, then the bar down the body.
    const graph_id = app.active.?;
    const pane = paneRect(app, graph_id) orelse return error.TestUnexpectedResult;
    const bar = app.screen.readCell(pane.x, pane.y + 1).?;
    try testing.expectEqualStrings("\u{258c}", bar.char.grapheme);
    try testing.expect(Theme.Color.eql(bar.style.fg, green));
    try testing.expectEqualStrings("\u{258c}", app.screen.readCell(pane.x, pane.y + pane.h - 1).?.char.grapheme);
    // The tab's glyph, at the chip's second cell.
    var tab_x: ?u16 = null;
    for (app.hits.items.items) |h| switch (h.target) {
        .tab => |tb| {
            const leaf = app.layouts.current().leaf(tb.leaf) orelse continue;
            if (tb.idx < leaf.tabs.items.len and leaf.tabs.items[tb.idx] == graph_id) tab_x = h.rect.x;
        },
        else => {},
    };
    try testing.expect(Theme.Color.eql(app.screen.readCell(tab_x.? + 1, pane.y).?.style.fg, green));
    // Beta's turn: `]` switches, everything follows in blue.
    try stepRepo(app, true);
    try app.render();
    const pill2 = pillRect(app) orelse return error.TestUnexpectedResult;
    try testing.expect(Theme.Color.eql(app.screen.readCell(pill2.x - 1, pill2.y).?.style.fg, blue));
    const beta_graph = app.active.?;
    const pane2 = paneRect(app, beta_graph) orelse return error.TestUnexpectedResult;
    try testing.expect(Theme.Color.eql(app.screen.readCell(pane2.x, pane2.y + 1).?.style.fg, blue));
    // The status pane of beta carries blue too.
    const status_id = try git.openStatusPane(app, app.git.repos.items[1]);
    try app.render();
    const pane3 = paneRect(app, status_id) orelse return error.TestUnexpectedResult;
    const sbar = app.screen.readCell(pane3.x, pane3.y + 1).?;
    try testing.expectEqualStrings("\u{258c}", sbar.char.grapheme);
    try testing.expect(Theme.Color.eql(sbar.style.fg, blue));
    // All repos: no pill accent; each sub-header's gutter in its repo's.
    try command.run(app, .{ .static = .@"git.palette_all" });
    try app.render();
    const pill3 = pillRect(app) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(" ", app.screen.readCell(pill3.x - 1, pill3.y).?.char.grapheme);
    const alpha_row = rowRect(app, 1) orelse return error.TestUnexpectedResult;
    const beta_row = rowRect(app, 4) orelse return error.TestUnexpectedResult;
    const ag = app.screen.readCell(alpha_row.x, alpha_row.y).?;
    const bg_ = app.screen.readCell(beta_row.x, beta_row.y).?;
    try testing.expectEqualStrings("\u{258c}", ag.char.grapheme);
    try testing.expect(Theme.Color.eql(ag.style.fg, green));
    try testing.expectEqualStrings("\u{258c}", bg_.char.grapheme);
    try testing.expect(Theme.Color.eql(bg_.style.fg, blue));
    // Under All the pill's right-click is still the repos menu.
    try app.handle(.{ .mouse = .{ .x = pill3.x + 1, .y = pill3.y, .kind = .press, .button = .right } });
    try testing.expectEqualStrings("Repos", app.overlay.menu.title);
    try app.handle(.{ .key = Key.named(.esc) });
    try command.run(app, .{ .static = .@"git.palette_all" });
    try app.render();
    // One repo again, alpha: the right-click lists the colours with the
    // stored slot ticked (Auto only once chosen); choosing one ticks it
    // and recolours the pill.
    try selectRepo(app, 0);
    try app.render();
    const pill4 = pillRect(app) orelse return error.TestUnexpectedResult;
    try app.handle(.{ .mouse = .{ .x = pill4.x + 1, .y = pill4.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    const items = app.overlay.menu.items;
    try testing.expectEqual(accent_color.palette.len + 1, items.len);
    for (items, 0..) |it, i| {
        try testing.expect(it.action == .repo_color);
        try testing.expectEqualStrings(accent_color.label(it.action.repo_color.name), it.label);
        if (i < accent_color.palette.len) try testing.expect(accent_color.resolve(it.action.repo_color.name, &app.theme) != null);
    }
    try testing.expect(items[0].checked and !items[items.len - 1].checked);
    try dispatch.runMenuActionForTest(app, items[4].action); // red
    try app.render();
    const pill5 = pillRect(app) orelse return error.TestUnexpectedResult;
    try testing.expect(Theme.Color.eql(app.screen.readCell(pill5.x - 1, pill5.y).?.style.fg, app.theme.palette.red));
    try app.handle(.{ .mouse = .{ .x = pill5.x + 1, .y = pill5.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay.menu.items[4].checked and !app.overlay.menu.items[0].checked);
    try dispatch.runMenuActionForTest(app, app.overlay.menu.items[items.len - 1].action); // Auto
    try app.render();
    const pill6 = pillRect(app) orelse return error.TestUnexpectedResult;
    try testing.expect(Theme.Color.eql(app.screen.readCell(pill6.x - 1, pill6.y).?.style.fg, green));
    try app.handle(.{ .mouse = .{ .x = pill6.x + 1, .y = pill6.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay.menu.items[items.len - 1].checked and !app.overlay.menu.items[4].checked);
    try app.handle(.{ .key = Key.named(.esc) });
}
