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
//! A click on a row selects it — the cursor moves there and, for a
//! ref, the graph tab jumps to its commit. Enter, or a click on the row
//! the cursor is already on, ACTS: a local branch checks out, a remote
//! branch becomes a local tracking branch of its short name, a
//! worktree opens (its directory joins the tree as a workspace root
//! and the graph tab switches to it), a stash applies (and stays), a
//! tag checks out detached after the confirm. The row menus do the
//! rest (pop / drop a stash, delete a tag, remove a worktree, …).
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
const remote_mod = @import("../git/remote.zig");
const settings = @import("settings.zig");
const accent_color = @import("../ui/accent_color.zig");
const Theme = @import("../ui/theme.zig");

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
    try items.append(gpa, .{
        .label = if (st.all) "\u{25CF} All repos" else "  All repos",
        .action = .{ .git_palette = .{ .what = .all_repos, .idx = 0 } },
    });
    for (gs.repos.items, 0..) |r, i| {
        try items.append(gpa, .{
            .label = try std.fmt.allocPrint(app.frame.allocator(), "{s}{s}", .{ if (!st.all and gs.active != null and gs.active.? == i) "\u{25CF} " else "  ", r.name }),
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

// ─── which repo ─────────────────────────────────────────────────────────

/// `idx` becomes the active repo and its graph tab comes to the front;
/// the palette keeps the focus.
pub fn selectRepo(app: *App, idx: usize) CommandError!void {
    const gs = &app.git;
    if (idx >= gs.repos.items.len) return;
    try git.switchTo(app, idx);
    showRepoTab(app, idx);
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
        } });
    }
    return count;
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

/// The commit a row stands for: a branch's sha, a worktree's HEAD, a
/// stash's commit, a tag's peeled commit.
fn rowSha(app: *App, row: Row) ?[]const u8 {
    const gs = &app.git;
    return switch (row) {
        .branch => |b| if (b.idx < gs.rail_branches.len) gs.rail_branches[b.idx].sha else null,
        .remote_branch => |b| if (b.idx < gs.rail_branches.len) gs.rail_branches[b.idx].sha else null,
        .worktree => |w| if (w.idx < gs.rail_worktrees.len) gs.rail_worktrees[w.idx].head else null,
        .stash => |s| if (s.idx < gs.rail_stashes.len) gs.rail_stashes[s.idx].sha else null,
        .tag => |t| if (t.idx < gs.rail_tags.len) gs.rail_tags[t.idx].sha else null,
        else => null,
    };
}

/// The name a row selects: a branch's, a worktree's label, a stash's
/// ref, a tag's.
fn rowName(app: *App, row: Row) ?[]const u8 {
    const gs = &app.git;
    return switch (row) {
        .branch => |b| b.name,
        .remote_branch => |b| b.name,
        .worktree => |w| if (w.idx < gs.rail_worktrees.len) gs.rail_worktrees[w.idx].label() else null,
        .stash => |s| if (s.idx < gs.rail_stashes.len) gs.rail_stashes[s.idx].ref else null,
        .tag => |t| t.name,
        else => null,
    };
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

/// A click on a row: the cursor moves there; a ref is selected and the
/// graph jumps to its commit; a header folds.
pub fn select(app: *App, idx: usize) Allocator.Error!void {
    const st = &app.git_palette;
    const row = (try rowAt(app, idx)) orelse return;
    st.cursor = idx;
    try switchToRowRepo(app, idx);
    switch (row) {
        .gap, .remote => {},
        .repo => |r| git.runToast(app, selectRepo(app, r.idx)),
        .section => |s| st.collapsed.toggle(s.s),
        else => {
            const name = rowName(app, row) orelse return;
            try setSelected(app, name);
            if (rowSha(app, row)) |sha| jumpToSha(app, sha, name) else app.toast("git: cannot resolve `{s}`", .{name});
        },
    }
    app.needs_render = true;
}

/// Enter, or a click on the row the cursor is on: the row's action.
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
                break :blk git.openConfirm(app, .{ .checkout = try gpa.dupe(u8, t.name) }, try std.fmt.allocPrint(gpa, "  Checkout tag {s}? (detached HEAD)", .{t.name}));
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
/// rediscovered so it has a graph tab, and that tab becomes the active
/// one — the palette then lists that tree's refs.
fn openWorktree(app: *App, w: parse.Worktree) CommandError!void {
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
        try rebuildTabs(app);
        return;
    };
    _ = app.tree.addRoot(app, w.path, null) catch |err| switch (err) {
        error.AlreadyOpen => {},
        error.NotADirectory => return app.diag.fail(arena, "worktree: {s} is not a directory", .{w.path}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    try git.discover(app);
    for (gs.repos.items, 0..) |r, i| if (samePath(app, arena, r.path, w.path)) {
        try git.switchTo(app, i);
        if (st.active) try rebuildTabs(app);
        app.toast("worktree: {s}", .{w.path});
        return;
    };
    app.toast("worktree: {s} added to the workspace", .{w.path});
}

/// The row's menu.
pub fn openRowMenu(app: *App, idx: usize, x: u16, y: u16) Allocator.Error!void {
    const gpa = app.gpa;
    const gs = &app.git;
    const arena = app.frame.allocator();
    const row = (try rowAt(app, idx)) orelse return;
    try switchToRowRepo(app, idx);
    switch (row) {
        .branch => |b| {
            const name = b.name;
            const items: []const MenuItem = if (b.current) &.{
                .{ .label = "New branch from here\u{2026}", .action = .{ .git_palette = .{ .what = .new_branch, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Copy name ({s})", .{name}), .action = .{ .git_palette = .{ .what = .copy_name, .idx = b.idx } } },
                .{ .label = "Rename\u{2026}", .action = .{ .git_palette = .{ .what = .rename, .idx = b.idx } }, .separator_before = true },
                .{ .label = "Fast-forward to upstream", .action = .{ .git_palette = .{ .what = .fast_forward, .idx = b.idx } } },
                .{ .label = "Set upstream\u{2026}", .action = .{ .git_palette = .{ .what = .set_upstream, .idx = b.idx } } },
                .{ .label = "Push --force-with-lease\u{2026}", .action = .{ .git_palette = .{ .what = .push_force, .idx = b.idx } }, .separator_before = true },
                .{ .label = "Delete on the remote\u{2026}", .action = .{ .git_palette = .{ .what = .delete_remote, .idx = b.idx } } },
            } else &.{
                .{ .label = try std.fmt.allocPrint(arena, "Checkout {s}", .{name}), .action = .{ .git_palette = .{ .what = .checkout, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Merge {s} into current", .{name}), .action = .{ .git_palette = .{ .what = .merge, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Rebase current onto {s}", .{name}), .action = .{ .git_palette = .{ .what = .rebase, .idx = b.idx } } },
                .{ .label = "New branch from here\u{2026}", .action = .{ .git_palette = .{ .what = .new_branch, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Copy name ({s})", .{name}), .action = .{ .git_palette = .{ .what = .copy_name, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Delete {s}\u{2026}", .{name}), .action = .{ .git_palette = .{ .what = .delete_branch, .idx = b.idx } } },
                .{ .label = "Rename\u{2026}", .action = .{ .git_palette = .{ .what = .rename, .idx = b.idx } }, .separator_before = true },
                .{ .label = "Fast-forward to upstream", .action = .{ .git_palette = .{ .what = .fast_forward, .idx = b.idx } } },
                .{ .label = "Set upstream\u{2026}", .action = .{ .git_palette = .{ .what = .set_upstream, .idx = b.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Force checkout {s}\u{2026}", .{name}), .action = .{ .git_palette = .{ .what = .checkout_force, .idx = b.idx } } },
                .{ .label = "Delete on the remote\u{2026}", .action = .{ .git_palette = .{ .what = .delete_remote, .idx = b.idx } } },
                .{ .label = "Diff against current", .action = .{ .git_palette = .{ .what = .diff_current, .idx = b.idx } }, .separator_before = true },
                .{ .label = try std.fmt.allocPrint(arena, "Reset --soft to {s}", .{name}), .action = .{ .command = .@"git.reset_soft" }, .separator_before = true },
                .{ .label = try std.fmt.allocPrint(arena, "Reset --mixed to {s}", .{name}), .action = .{ .command = .@"git.reset_mixed" } },
                .{ .label = try std.fmt.allocPrint(arena, "Reset --hard to {s}\u{2026}", .{name}), .action = .{ .command = .@"git.reset_hard" } },
            };
            try app.openMenu(if (b.current) try std.fmt.allocPrint(arena, "\u{25CF} {s}", .{name}) else name, try gpa.dupe(MenuItem, items), x, y);
        },
        .remote_branch => |m| {
            const items = try gpa.dupe(MenuItem, &.{
                .{ .label = try std.fmt.allocPrint(arena, "Checkout {s}", .{m.name}), .action = .{ .git_palette = .{ .what = .checkout, .idx = m.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Merge {s} into current", .{m.name}), .action = .{ .git_palette = .{ .what = .merge, .idx = m.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Rebase current onto {s}", .{m.name}), .action = .{ .git_palette = .{ .what = .rebase, .idx = m.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Copy name ({s})", .{m.name}), .action = .{ .git_palette = .{ .what = .copy_name, .idx = m.idx } } },
                .{ .label = "Delete on the remote\u{2026}", .action = .{ .git_palette = .{ .what = .delete_remote, .idx = m.idx } }, .separator_before = true },
                .{ .label = "Diff against current", .action = .{ .git_palette = .{ .what = .diff_current, .idx = m.idx } }, .separator_before = true },
                .{ .label = try std.fmt.allocPrint(arena, "Reset --soft to {s}", .{m.name}), .action = .{ .command = .@"git.reset_soft" }, .separator_before = true },
                .{ .label = try std.fmt.allocPrint(arena, "Reset --mixed to {s}", .{m.name}), .action = .{ .command = .@"git.reset_mixed" } },
                .{ .label = try std.fmt.allocPrint(arena, "Reset --hard to {s}\u{2026}", .{m.name}), .action = .{ .command = .@"git.reset_hard" } },
            });
            try app.openMenu(m.name, items, x, y);
        },
        .remote => |r| {
            var items: std.ArrayListUnmanaged(MenuItem) = .empty;
            errdefer items.deinit(gpa);
            try items.append(gpa, .{ .label = "Fetch", .action = .{ .git_palette = .{ .what = .remote_fetch, .idx = r.idx } } });
            if (r.idx < gs.rail_remotes.len) try items.append(gpa, .{ .label = "Copy URL", .action = .{ .git_palette = .{ .what = .remote_copy_url, .idx = r.idx } } });
            try app.openMenu(r.name, try items.toOwnedSlice(gpa), x, y);
        },
        .worktree => |w| {
            if (w.idx >= gs.rail_worktrees.len) return;
            const wt = gs.rail_worktrees[w.idx];
            var items: std.ArrayListUnmanaged(MenuItem) = .empty;
            errdefer items.deinit(gpa);
            try items.append(gpa, .{ .label = "Open", .action = .{ .git_palette = .{ .what = .worktree_open, .idx = w.idx } } });
            try items.append(gpa, .{ .label = "Open shell here", .action = .{ .git_palette = .{ .what = .worktree_shell, .idx = w.idx } } });
            try items.append(gpa, .{ .label = "Copy path", .action = .{ .git_palette = .{ .what = .worktree_copy_path, .idx = w.idx } } });
            try items.append(gpa, .{ .label = "New worktree\u{2026}", .action = .{ .command = .@"git.worktree_add" } });
            if (!w.main and !w.current) try items.append(gpa, .{ .label = "Remove worktree\u{2026}", .action = .{ .git_palette = .{ .what = .worktree_remove, .idx = w.idx } } });
            try app.openMenu(try std.fmt.allocPrint(arena, "{s}  {s}", .{ wt.label(), wt.path }), try items.toOwnedSlice(gpa), x, y);
        },
        .stash => |s| {
            if (s.idx >= gs.rail_stashes.len) return;
            const items = try gpa.dupe(MenuItem, &.{
                .{ .label = "Show files (Enter)", .action = .{ .git_palette = .{ .what = .stash_show, .idx = s.idx } } },
                .{ .label = "Apply (keep)", .action = .{ .git_palette = .{ .what = .stash_apply, .idx = s.idx } }, .separator_before = true },
                .{ .label = "Pop (apply + drop)", .action = .{ .git_palette = .{ .what = .stash_pop, .idx = s.idx } } },
                .{ .label = "Drop\u{2026}", .action = .{ .git_palette = .{ .what = .stash_drop, .idx = s.idx } } },
                .{ .label = "Branch from stash\u{2026}", .action = .{ .git_palette = .{ .what = .stash_branch, .idx = s.idx } }, .separator_before = true },
                .{ .label = "Rename\u{2026}", .action = .{ .git_palette = .{ .what = .stash_rename, .idx = s.idx } } },
            });
            try app.openMenu(try std.fmt.allocPrint(arena, "{s} {s}", .{ gs.rail_stashes[s.idx].ref, s.message }), items, x, y);
        },
        .tag => |t| {
            const items = try gpa.dupe(MenuItem, &.{
                .{ .label = try std.fmt.allocPrint(arena, "Checkout {s} (detached)", .{t.name}), .action = .{ .git_palette = .{ .what = .tag_checkout, .idx = t.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Copy name ({s})", .{t.name}), .action = .{ .git_palette = .{ .what = .tag_copy, .idx = t.idx } } },
                .{ .label = try std.fmt.allocPrint(arena, "Delete {s}\u{2026}", .{t.name}), .action = .{ .git_palette = .{ .what = .tag_delete, .idx = t.idx } } },
                .{ .label = "New branch from tag\u{2026}", .action = .{ .git_palette = .{ .what = .new_branch_from, .idx = t.idx } }, .separator_before = true },
                .{ .label = "New worktree from tag\u{2026}", .action = .{ .git_palette = .{ .what = .worktree_from, .idx = t.idx } } },
            });
            try app.openMenu(t.name, items, x, y);
        },
        .section, .repo, .gap => {},
    }
}

/// A menu row picked.
pub fn menuAction(app: *App, a: MenuAct) Allocator.Error!void {
    const gs = &app.git;
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const result: CommandError!void = blk: {
        switch (a.what) {
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
                if (a.idx >= gs.rail_remotes.len) break :blk;
                const url = gs.rail_remotes[a.idx].url;
                try app.clipboard.setYank(url, false);
                app.toast("copied {s}", .{url});
                break :blk;
            },
            .worktree_open, .worktree_shell, .worktree_copy_path, .worktree_remove => {
                if (a.idx >= gs.rail_worktrees.len) break :blk;
                const wt = gs.rail_worktrees[a.idx];
                switch (a.what) {
                    .worktree_open => break :blk openWorktree(app, wt),
                    .worktree_copy_path => {
                        try app.clipboard.setYank(wt.path, false);
                        app.toast("copied {s}", .{wt.path});
                    },
                    .worktree_shell => {
                        const opened = pty_pane.open(app, .{ .cwd = wt.path, .label = try std.fmt.allocPrint(arena, "shell: {s}", .{std.fs.path.basename(wt.path)}), .placement = .below, .kind = .shell });
                        _ = opened catch |err| break :blk err;
                    },
                    else => break :blk git.openConfirm(app, .{ .worktree_remove = try gpa.dupe(u8, wt.path) }, try std.fmt.allocPrint(gpa, "  Remove worktree {s}?", .{wt.path})),
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
                    else => break :blk git.submitOp(app, repo, .{ .stash_drop = try gpa.dupe(u8, ref) }),
                }
            },
            .tag_checkout, .tag_delete, .tag_copy, .new_branch_from, .worktree_from => {
                if (a.idx >= gs.rail_tags.len) break :blk;
                const name = gs.rail_tags[a.idx].name;
                switch (a.what) {
                    .tag_checkout => break :blk git.openConfirm(app, .{ .checkout = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "  Checkout tag {s}? (detached HEAD)", .{name})),
                    .tag_delete => break :blk git.openConfirm(app, .{ .tag_delete = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "  Delete tag {s}?", .{name})),
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
            // From the row's branch, not HEAD (the current row's is HEAD).
            .new_branch => break :blk git.newBranchFrom(app, name),
            .delete_branch => break :blk git.openConfirm(app, .{ .delete_branch = try gpa.dupe(u8, name) }, try std.fmt.allocPrint(gpa, "  Delete branch {s}? (git branch -D)", .{name})),
            .diff_current => break :blk git.diffAgainstCurrent(app, repo, name),
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

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.git_palette;
    switch (m.kind) {
        .press => {
            st.filter_focused = false;
            const was_here = st.cursor == idx and app.focus == .panel and app.focus.panel == .git;
            focusPalette(app);
            switch (m.button) {
                .left => if (was_here) try activate(app, idx) else try select(app, idx),
                .right => {
                    st.cursor = idx;
                    try openRowMenu(app, idx, m.x, m.y);
                },
                else => {},
            }
        },
        .scroll_up => st.scroll -|= 3,
        .scroll_down => st.scroll = @min(st.scroll + 3, st.total -| st.visible),
        else => {},
    }
    app.needs_render = true;
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
        .scroll_up => st.scroll -|= 3,
        .scroll_down => st.scroll = @min(st.scroll + 3, max),
        else => {},
    }
    app.needs_render = true;
}

/// The wheel anywhere over the palette. The cursor stays inside the
/// window so the paint's clamp does not pull the scroll back.
pub fn wheel(app: *App, down: bool) void {
    const st = &app.git_palette;
    if (down) st.scroll = @min(st.scroll + 3, st.total -| st.visible) else st.scroll -|= 3;
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
    .{ .name = "main", .time = 0, .current = true, .remote = false, .sha = "aaaa111", .ahead = 1, .behind = 3 },
    .{ .name = "feature", .time = 0, .current = false, .remote = false, .sha = "bbbb222" },
    .{ .name = "origin/main", .time = 0, .current = false, .remote = true, .sha = "aaaa111" },
    .{ .name = "origin/feature", .time = 0, .current = false, .remote = true, .sha = "bbbb222" },
    .{ .name = "origin/hotfix", .time = 0, .current = false, .remote = true, .sha = "cccc333" },
    .{ .name = "origin/HEAD", .time = 0, .current = false, .remote = true },
};
var seed_worktrees = [_]parse.Worktree{
    .{ .path = "", .branch = "main", .head = "aaaa111", .main = true },
    .{ .path = "/repo/wt-fix", .branch = "fix", .head = "cccc333", .locked = true, .lock_reason = "keep", .dirty = true },
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
    // The filter: under TAGS only alpha has a `v1`; beta's sub-header goes.
    try st.filter.appendSlice(testing.allocator, "v1");
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
    try app.git_palette.filter.appendSlice(testing.allocator, "v1");
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

test "a click selects and a second click on the same row acts: the stash applies through the worker, a remote branch asks for its short name, the tag confirm names detached HEAD; the keys skip the gaps" {
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
    // A click on the stash row selects it (no repo: the graph jump only toasts).
    try rowMouse(app, 15, .{ .x = 5, .y = 20, .kind = .press, .button = .left });
    try testing.expectEqual(@as(usize, 15), st.cursor);
    try testing.expectEqualStrings("stash@{0}", st.selected.?);
    try testing.expect(app.focus == .panel and app.focus.panel == .git);
    // The second click acts: with no repo the action fails loudly, not silently.
    try rowMouse(app, 15, .{ .x = 5, .y = 20, .kind = .press, .button = .left });
    try testing.expect(app.lastToast() != null);
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

test "every row menu names actions that resolve, and each menu action reaches the worker or a confirm" {
    var t = try TestApp.init();
    defer t.deinit();
    const app = &t.app;
    try git.discover(app);
    try testing.expect(app.git.activeRepo() != null);
    seed(app);
    const list = try rows(app, app.frame.allocator());
    // Open the menu on every stop: no crash, a title, at least one row
    // whose command id — when it is a command — is a registered one.
    for (list, 0..) |r, i| {
        if (!r.isStop() or r == .section) continue;
        try openRowMenu(app, i, 3, 3);
        try testing.expect(app.overlay.menu.items.len > 0);
        for (app.overlay.menu.items) |it| switch (it.action) {
            .command => |id| try testing.expect(command.by_name.get(command.name(id)) != null),
            .git_palette => {},
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
    try testing.expect(!std.mem.eql(u8, app.screen.readCell(pane.x, pane.y + 1).?.char.grapheme, "\u{258c}"));
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
