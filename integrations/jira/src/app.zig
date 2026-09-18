//! The pane's state and every action on it — what is loaded, what is
//! selected, which overlay is up — with no painting in it. `screen.zig`
//! turns an `App` into a frame (and fills the hit map while it does);
//! `key`, `click` and `wheel` here turn what the user did into state.
//! Every fetch is synchronous through the client, the way the reference
//! does it; the loop in `main.zig` paints between them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config = @import("config.zig");
const model = @import("model.zig");
const jira = @import("jira.zig");
const bitbucket = @import("bitbucket.zig");
const tree = @import("tree.zig");
const kanban = @import("kanban.zig");
const filters = @import("filters.zig");
const dispatch = @import("dispatch.zig");
const hit = @import("hit.zig");
const keymap = @import("keymap.zig");
const pickers = @import("pickers.zig");
const textedit = @import("textedit.zig");
const os = @import("os.zig");

pub const Issue = model.Issue;
pub const TextEdit = textedit.TextEdit;
pub const Value = std.json.Value;

/// An assignee's presence on a tab, for the avatar cluster.
pub const AssigneeSummary = struct { account_id: []const u8, display_name: []const u8, count: usize };

pub const TabState = struct {
    cfg: config.Tab,
    /// The resolved JQL; replaced by the JQL editor and the tab-version picker.
    jql: []const u8,
    /// Owns the issues; reset on every refresh.
    data: std.heap.ArenaAllocator,
    /// Owns the caches that outlive a refresh.
    meta: std.heap.ArenaAllocator,
    issues: []const Issue = &.{},
    /// A row index on a tree tab, an issue index otherwise.
    selected: usize = 0,
    fetched: bool = false,
    last_error: []const u8 = "",
    tree: ?tree.State = null,
    sprints: ?[]const model.Sprint = null,
    selected_sprint: ?u64 = null,
    quick_filters: ?[]const model.QuickFilter = null,
    active_quick_filters: std.ArrayList(u64) = .empty,
    scope: filters.Scope = .all,
    assignees: []const AssigneeSummary = &.{},
    active_assignees: std.StringHashMapUnmanaged(void) = .empty,
    show_jql: bool = false,
    seeded: bool = false,
    boards: ?[]const model.Board = null,
    active_epics: std.StringHashMapUnmanaged(void) = .empty,
    team: []const u8,
    issue_type: []const u8,
    label: []const u8,
    board_id: u64,
    scroll: usize = 0,

    pub fn shape(t: *const TabState) keymap.TabShape {
        if (t.cfg.isKanban()) return .kanban;
        if (t.cfg.isTree()) return .tree;
        return .flat;
    }

    pub fn issue(t: *const TabState, idx: usize) ?Issue {
        if (idx >= t.issues.len) return null;
        return t.issues[idx];
    }

    fn activeIds(t: *const TabState, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = t.active_assignees.keyIterator();
        while (it.next()) |k| try out.append(arena, k.*);
        return out.toOwnedSlice(arena);
    }

    fn activeEpics(t: *const TabState, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = t.active_epics.keyIterator();
        while (it.next()) |k| try out.append(arena, k.*);
        return out.toOwnedSlice(arena);
    }
};

pub const Filter = struct { edit: TextEdit, editing: bool };

pub const Comment = struct { key: []const u8, edit: TextEdit, posting: bool = false, error_text: []const u8 = "" };

pub const Modal = struct {
    key: []const u8,
    arena: std.heap.ArenaAllocator,
    data: ?Value = null,
    scroll: u16 = 0,
    error_text: []const u8 = "",
};

pub const Rows = tree.Rows;

pub const App = struct {
    gpa: Allocator,
    io: Io,
    cfg: config.Config,
    family: ?config.Family,
    client: *jira.Client,
    forge: bitbucket.Client,
    /// Small owned strings: keys in sets, the status, resolved JQLs.
    keys: std.heap.ArenaAllocator,
    tabs: []TabState,
    active: usize = 0,
    status: std.ArrayList(u8) = .empty,
    details_visible: bool = false,
    details_scroll: u16 = 0,
    details: std.StringHashMapUnmanaged(*DetailEntry) = .empty,
    filter: ?Filter = null,
    jql: ?TextEdit = null,
    transition: ?pickers.TransitionPicker = null,
    picker: ?pickers.FieldPicker = null,
    comment: ?Comment = null,
    selection: std.StringHashMapUnmanaged(void) = .empty,
    modal: ?Modal = null,
    help: bool = false,
    help_scroll: usize = 0,
    me: ?model.User = null,
    me_failed: bool = false,
    board_names: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    kanban_scroll: [kanban.count]u16 = .{ 0, 0, 0, 0 },
    kanban_expanded: std.StringHashMapUnmanaged(void) = .empty,
    hits: hit.Map = .{},
    cols: u16 = 80,
    rows: u16 = 24,
    last_refresh_ms: i64 = 0,
    quit: bool = false,
    /// The count the statusline segment shows; null until a work tab loaded.
    assigned_open: ?usize = null,
    /// Set when `assigned_open` changed and has not been published.
    segment_dirty: bool = false,
    /// The last thing worth a toast (an action's outcome); the loop drains it.
    toast: std.ArrayList(u8) = .empty,
    toast_pending: bool = false,

    const DetailEntry = struct { arena: std.heap.ArenaAllocator, detail: model.IssueDetail };

    pub fn init(gpa: Allocator, io: Io, cfg: config.Config, family: ?config.Family, client: *jira.Client, forge: bitbucket.Client) Allocator.Error!App {
        var keys = std.heap.ArenaAllocator.init(gpa);
        errdefer keys.deinit();
        const cfg_tabs = try config.tabsOfFamily(keys.allocator(), cfg.tabs, family);
        const tabs = try gpa.alloc(TabState, cfg_tabs.len);
        errdefer gpa.free(tabs);
        for (cfg_tabs, tabs) |c, *t| {
            t.* = .{
                .cfg = c,
                .jql = (try c.staticJql(keys.allocator())) orelse "",
                .data = std.heap.ArenaAllocator.init(gpa),
                .meta = std.heap.ArenaAllocator.init(gpa),
                .tree = if (c.isTree() or c.isKanban()) tree.State.init(gpa) else null,
                .team = c.team,
                .issue_type = c.issue_type,
                .label = c.label,
                .board_id = c.board_id,
            };
        }
        return .{ .gpa = gpa, .io = io, .cfg = cfg, .family = family, .client = client, .forge = forge, .keys = keys, .tabs = tabs };
    }

    pub fn deinit(a: *App) void {
        for (a.tabs) |*t| {
            t.data.deinit();
            t.meta.deinit();
            if (t.tree) |*tr| tr.deinit();
            t.active_quick_filters.deinit(a.gpa);
            t.active_assignees.deinit(a.gpa);
            t.active_epics.deinit(a.gpa);
        }
        a.gpa.free(a.tabs);
        a.status.deinit(a.gpa);
        a.toast.deinit(a.gpa);
        var it = a.details.valueIterator();
        while (it.next()) |e| {
            e.*.arena.deinit();
            a.gpa.destroy(e.*);
        }
        a.details.deinit(a.gpa);
        if (a.filter) |*f| f.edit.deinit();
        if (a.jql) |*j| j.deinit();
        if (a.transition) |*t| t.deinit();
        if (a.picker) |*p| p.deinit();
        if (a.comment) |*c| c.edit.deinit();
        if (a.modal) |*m| m.arena.deinit();
        a.selection.deinit(a.gpa);
        a.board_names.deinit(a.gpa);
        a.kanban_expanded.deinit(a.gpa);
        a.hits.deinit(a.gpa);
        a.keys.deinit();
        a.* = undefined;
    }

    // ─── small helpers ───────────────────────────────────────────────────

    pub fn keep(a: *App, s: []const u8) Allocator.Error![]const u8 {
        return a.keys.allocator().dupe(u8, s);
    }

    pub fn setStatus(a: *App, comptime fmt: []const u8, args: anytype) void {
        a.status.clearRetainingCapacity();
        a.status.print(a.gpa, fmt, args) catch {};
    }

    /// A status that is also worth mnml's toast.
    pub fn say(a: *App, comptime fmt: []const u8, args: anytype) void {
        a.setStatus(fmt, args);
        a.toast.clearRetainingCapacity();
        a.toast.print(a.gpa, fmt, args) catch {};
        a.toast_pending = true;
    }

    pub fn nowMs(a: *App) i64 {
        return Io.Timestamp.now(a.io, .real).toMilliseconds();
    }

    pub fn tab(a: *App) *TabState {
        return &a.tabs[a.active];
    }

    pub fn tabConst(a: *const App) *const TabState {
        return &a.tabs[a.active];
    }

    pub fn hasTabs(a: *const App) bool {
        return a.tabs.len > 0;
    }

    pub fn context(a: *const App) keymap.Context {
        const t = a.tabConst();
        return .{ .shape = t.shape(), .fix_versions = t.cfg.isFixVersions(), .detail_open = a.details_visible };
    }

    pub fn isKanban(a: *const App) bool {
        return a.hasTabs() and a.tabConst().cfg.isKanban();
    }

    pub fn isTree(a: *const App) bool {
        return a.hasTabs() and a.tabConst().cfg.isTree();
    }

    /// The tree's team field as the JQL wants it.
    fn teamClause(a: *App, arena: Allocator, base: []const u8, team: []const u8) Allocator.Error![]const u8 {
        if (team.len == 0) return base;
        return jira.withTeam(arena, base, team, a.cfg.team_field_name, a.cfg.team_field_id);
    }

    fn teamFilterClause(a: *App, arena: Allocator, team: []const u8) Allocator.Error![]const u8 {
        const t = try jira.escapeQuotes(arena, team);
        const field = a.cfg.teamField();
        if (field.len > 0) return std.fmt.allocPrint(arena, "(\"{s}\" = \"{s}\" OR component = \"{s}\" OR labels = \"{s}\")", .{ field, t, t, t });
        return std.fmt.allocPrint(arena, "(component = \"{s}\" OR labels = \"{s}\")", .{ t, t });
    }

    // ─── the visible rows ────────────────────────────────────────────────

    pub fn criteria(a: *App, arena: Allocator, t: *const TabState) Allocator.Error!filters.Criteria {
        return .{
            .text = if (a.filter) |f| f.edit.text() else "",
            .assignees = try t.activeIds(arena),
            .epics = try t.activeEpics(arena),
            .issue_type = t.issue_type,
            .label = t.label,
            .team = if (t.cfg.isKanban()) t.team else "",
            .scope = t.scope,
        };
    }

    pub fn mask(a: *App, arena: Allocator, t: *const TabState) Allocator.Error![]const bool {
        return filters.mask(arena, t.issues, try a.criteria(arena, t));
    }

    /// The tree rows of the active tab (null on a kanban / flat tab).
    pub fn treeRows(a: *App, arena: Allocator) Allocator.Error!?Rows {
        const t = a.tab();
        if (!t.cfg.isTree()) return null;
        const st = &(t.tree.?);
        return try tree.computeRows(arena, t.issues, st, t.cfg, a.cfg.release_cut, try a.mask(arena, t));
    }

    /// The issue indices a flat or kanban tab shows, in order.
    pub fn visibleIssues(a: *App, arena: Allocator) Allocator.Error![]const usize {
        const t = a.tab();
        const m = try a.mask(arena, t);
        var out: std.ArrayList(usize) = .empty;
        for (m, 0..) |ok, i| if (ok) try out.append(arena, i);
        return out.toOwnedSlice(arena);
    }

    pub fn focusedIssueIdx(a: *App, arena: Allocator) Allocator.Error!?usize {
        if (!a.hasTabs()) return null;
        const t = a.tab();
        if (t.cfg.isTree()) {
            const r = (try a.treeRows(arena)) orelse return null;
            if (t.selected >= r.rows.len) return null;
            return r.rows[t.selected].issueIdx();
        }
        if (t.selected >= t.issues.len) return null;
        return t.selected;
    }

    pub fn focusedKey(a: *App, arena: Allocator) Allocator.Error!?[]const u8 {
        const idx = (try a.focusedIssueIdx(arena)) orelse return null;
        return a.tab().issues[idx].key;
    }

    pub fn focusedRow(a: *App, arena: Allocator) Allocator.Error!?tree.Row {
        const r = (try a.treeRows(arena)) orelse return null;
        const t = a.tab();
        if (t.selected >= r.rows.len) return null;
        return r.rows[t.selected];
    }

    // ─── the loop's entry points ─────────────────────────────────────────

    pub fn resize(a: *App, cols: u16, rows: u16) void {
        a.cols = cols;
        a.rows = rows;
    }

    /// The auto-refresh, on the reference's cadence.
    pub fn tick(a: *App, now: i64) Allocator.Error!void {
        const secs = a.cfg.refresh_interval_secs;
        if (secs == 0 or !a.hasTabs()) return;
        if (a.last_refresh_ms == 0 or now - a.last_refresh_ms < @as(i64, secs) * 1000) return;
        try a.refreshActive();
    }

    /// Fetch the active tab if it has not been.
    pub fn ensureLoaded(a: *App) Allocator.Error!void {
        if (!a.hasTabs()) return;
        if (!a.tab().fetched and a.tab().last_error.len == 0) try a.refreshActive();
    }

    // ─── refreshing ──────────────────────────────────────────────────────

    fn ensureMe(a: *App) Allocator.Error!void {
        if (a.me != null or a.me_failed) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        switch (jira.myself(a.client, scratch.allocator()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => {
                a.me_failed = true;
                return;
            },
        }) {
            .ok => |u| a.me = .{ .account_id = try a.keep(u.account_id), .display_name = try a.keep(u.display_name) },
            .failed => a.me_failed = true,
        }
    }

    pub fn refreshActive(a: *App) Allocator.Error!void {
        if (!a.hasTabs()) return;
        try a.refreshTab(a.active);
        a.last_refresh_ms = a.nowMs();
    }

    pub fn refreshTab(a: *App, idx: usize) Allocator.Error!void {
        const t = &a.tabs[idx];
        try a.ensureMe();
        // The reference seeds the assignee filter with "me" once.
        // The reference seeds the assignee filter with "me" once; on its
        // tree tabs the filter is inert, so the seed only lands where it
        // shows (flat and kanban) — here the chips work on trees too.
        if (!t.seeded and (a.me != null or a.me_failed)) {
            if (a.me) |me| if (!t.cfg.isTree() and t.active_assignees.count() == 0 and me.account_id.len > 0) try t.active_assignees.put(a.gpa, me.account_id, {});
            t.seeded = true;
        }
        if (t.jql.len == 0) try a.resolveJql(t);
        // The cursor survives a refetch: remember the ticket it is on.
        var keep_key: ?[]const u8 = null;
        var keep_buf: [64]u8 = undefined;
        if (idx == a.active) {
            var pre = std.heap.ArenaAllocator.init(a.gpa);
            defer pre.deinit();
            if (try a.focusedKey(pre.allocator())) |k| if (k.len <= keep_buf.len) {
                @memcpy(keep_buf[0..k.len], k);
                keep_key = keep_buf[0..k.len];
            };
        }
        // The issues slice into the JSON they came from, so the fetch
        // lands in a fresh arena that becomes the tab's on success and
        // is dropped on failure (the old issues stay on screen).
        var next = std.heap.ArenaAllocator.init(a.gpa);
        errdefer next.deinit();
        const arena = next.allocator();
        const extra: []const []const u8 = if (a.cfg.team_field_id.len > 0) &.{a.cfg.team_field_id} else &.{};
        const answer: jira.Answer([]const Value) = blk: {
            if (t.board_id != 0) {
                var clauses: std.ArrayList([]const u8) = .empty;
                if (t.team.len > 0) try clauses.append(arena, try a.teamFilterClause(arena, t.team));
                if (t.selected_sprint) |sp| try clauses.append(arena, try std.fmt.allocPrint(arena, "sprint = {d}", .{sp}));
                if (t.quick_filters) |qfs| for (qfs) |qf| {
                    for (t.active_quick_filters.items) |id| if (id == qf.id and std.mem.trim(u8, qf.jql, " ").len > 0) {
                        try clauses.append(arena, try std.fmt.allocPrint(arena, "({s})", .{std.mem.trim(u8, qf.jql, " ")}));
                    };
                };
                const extra_jql: ?[]const u8 = if (clauses.items.len == 0) null else try std.mem.join(arena, " AND ", clauses.items);
                break :blk jira.boardIssues(a.client, arena, t.board_id, extra_jql, extra) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Transport => jira.Answer([]const Value){ .failed = .{ .status = 0, .message = "the site did not answer" } },
                };
            }
            const q = try a.teamClause(arena, t.jql, t.team);
            break :blk jira.search(a.client, arena, q, extra) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer([]const Value){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            };
        };
        switch (answer) {
            .failed => |f| {
                t.last_error = try std.fmt.allocPrint(t.meta.allocator(), "{s}", .{f.message});
                a.setStatus("error: {s}", .{f.message});
                next.deinit();
            },
            .ok => |vals| {
                t.issues = try jira.parseIssues(arena, vals, a.cfg.team_field_id);
                t.data.deinit();
                t.data = next;
                t.fetched = true;
                t.last_error = "";
                // An action's message outlives the refetch it triggers;
                // an empty status gets the tab's summary.
                if (a.status.items.len == 0) a.setStatus("{s} · {d} issues", .{ t.cfg.name, t.issues.len });
                if (t.cfg.kind == .work_assigned) {
                    a.assigned_open = t.issues.len;
                    a.segment_dirty = true;
                }
                // The reference auto-expands unresolved tickets on tree tabs
                // and fetches their PRs; the kanban does the fetch too but
                // never shows it, so only the tree pays for it here.
                if (t.tree) |*st| if (t.cfg.isTree()) {
                    for (t.issues) |iss| if (iss.isUnresolved()) {
                        try st.setExpanded(iss.key, true);
                        try a.ensurePrs(idx, iss.key);
                    };
                };
                if (t.sprints == null and t.board_id != 0) try a.loadSprints(idx);
                try a.aggregateAssignees(t);
                // Put the cursor back on the ticket it was on (its row
                // may have moved), else on the first row.
                if (idx == a.active) {
                    if (t.cfg.isTree()) {
                        t.selected = 0;
                        if (keep_key) |k| {
                            var post = std.heap.ArenaAllocator.init(a.gpa);
                            defer post.deinit();
                            if (try a.treeRows(post.allocator())) |r| if (tree.rowOfKey(r.rows, t.issues, k)) |ri| {
                                t.selected = ri;
                            };
                        }
                    } else {
                        t.selected = 0;
                        if (keep_key) |k| for (t.issues, 0..) |iss, i| if (std.mem.eql(u8, iss.key, k)) {
                            t.selected = i;
                        };
                        try a.clampCursor();
                    }
                }
            },
        }
    }

    /// `--prefetch`'s JSON (`{"generated_at":…,"tabs":[{"name":…,"issues":[…]}]}`)
    /// into the tabs it names, so the first paint has tickets before any
    /// fetch; returns how many tabs took it.
    pub fn hydrate(a: *App, src: []const u8) Allocator.Error!usize {
        var n: usize = 0;
        for (a.tabs, 0..) |*t, idx| {
            var next = std.heap.ArenaAllocator.init(a.gpa);
            errdefer next.deinit();
            const arena = next.allocator();
            const doc = std.json.parseFromSliceLeaky(Value, arena, src, .{}) catch {
                next.deinit();
                return n;
            };
            const tabs_v = switch (doc) {
                .object => |o| o.get("tabs") orelse {
                    next.deinit();
                    return n;
                },
                else => {
                    next.deinit();
                    return n;
                },
            };
            const list = switch (tabs_v) {
                .array => |arr| arr.items,
                else => &.{},
            };
            var took = false;
            for (list) |tv| {
                const name = switch (tv) {
                    .object => |o| if (o.get("name")) |nv| (if (nv == .string) nv.string else "") else "",
                    else => "",
                };
                if (!std.mem.eql(u8, name, t.cfg.name)) continue;
                const issues_v = tv.object.get("issues") orelse continue;
                const vals = switch (issues_v) {
                    .array => |arr| arr.items,
                    else => continue,
                };
                t.issues = try jira.parseIssues(arena, vals, a.cfg.team_field_id);
                t.data.deinit();
                t.data = next;
                t.fetched = true;
                t.last_error = "";
                took = true;
                n += 1;
                if (t.cfg.kind == .work_assigned) {
                    a.assigned_open = t.issues.len;
                    a.segment_dirty = true;
                }
                if (t.tree) |*st| if (t.cfg.isTree()) {
                    for (t.issues) |iss| if (iss.isUnresolved()) try st.setExpanded(iss.key, true);
                };
                try a.aggregateAssignees(t);
                _ = idx;
                break;
            }
            if (!took) next.deinit();
        }
        return n;
    }

    fn resolveJql(a: *App, t: *TabState) Allocator.Error!void {
        const mode = t.cfg.mode orelse return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const versions = switch (jira.projectVersions(a.client, arena, t.cfg.project) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer([]const model.Version){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => |v| v,
            .failed => |f| {
                t.jql = "issuekey = ''";
                t.last_error = try std.fmt.allocPrint(t.meta.allocator(), "fetching unreleased versions: {s}", .{f.message});
                return;
            },
        };
        const open = try jira.unreleasedVersions(arena, versions, t.cfg.version_name_contains);
        const picked = jira.pickVersion(open, mode) orelse {
            t.jql = "issuekey = ''";
            t.last_error = try t.meta.allocator().dupe(u8, "no unreleased versions match (check version_name_contains)");
            return;
        };
        t.jql = try a.keep(try jira.fixVersionJql(arena, t.cfg.project, picked.name, t.cfg.component));
    }

    fn loadSprints(a: *App, idx: usize) Allocator.Error!void {
        const t = &a.tabs[idx];
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        switch (jira.sprintsForBoard(a.client, scratch.allocator(), t.board_id) catch return) {
            .ok => |list| {
                const copy = try t.meta.allocator().alloc(model.Sprint, list.len);
                for (list, copy) |src, *dst| dst.* = .{
                    .id = src.id,
                    .name = try t.meta.allocator().dupe(u8, src.name),
                    .state = try t.meta.allocator().dupe(u8, src.state),
                    .start_date = try t.meta.allocator().dupe(u8, src.start_date),
                    .end_date = try t.meta.allocator().dupe(u8, src.end_date),
                    .complete_date = try t.meta.allocator().dupe(u8, src.complete_date),
                };
                t.sprints = copy;
            },
            .failed => {},
        }
    }

    fn aggregateAssignees(a: *App, t: *TabState) Allocator.Error!void {
        const me_id = if (a.me) |m| m.account_id else "";
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        var list: std.ArrayList(AssigneeSummary) = .empty;
        for (t.issues) |iss| {
            const u = iss.assignee orelse continue;
            if (u.account_id.len == 0 or std.mem.eql(u8, u.account_id, me_id)) continue;
            var found = false;
            for (list.items) |*s| if (std.mem.eql(u8, s.account_id, u.account_id)) {
                s.count += 1;
                found = true;
            };
            if (!found) try list.append(scratch.allocator(), .{ .account_id = u.account_id, .display_name = u.display_name, .count = 1 });
        }
        std.mem.sort(AssigneeSummary, list.items, {}, struct {
            fn lt(_: void, x: AssigneeSummary, y: AssigneeSummary) bool {
                if (x.count != y.count) return x.count > y.count;
                return std.mem.order(u8, x.display_name, y.display_name) == .lt;
            }
        }.lt);
        const out = try t.meta.allocator().alloc(AssigneeSummary, list.items.len);
        for (list.items, out) |src, *dst| dst.* = .{
            .account_id = try t.meta.allocator().dupe(u8, src.account_id),
            .display_name = try t.meta.allocator().dupe(u8, src.display_name),
            .count = src.count,
        };
        t.assignees = out;
    }

    /// Fetch and cache a ticket's linked PRs once.
    pub fn ensurePrs(a: *App, idx: usize, key: []const u8) Allocator.Error!void {
        const t = &a.tabs[idx];
        const st = &(t.tree orelse return);
        if (st.prs(key) != null) return;
        var issue_id: []const u8 = "";
        for (t.issues) |iss| if (std.mem.eql(u8, iss.key, key)) {
            issue_id = iss.id;
        };
        if (issue_id.len == 0) {
            a.setStatus("{s}: no numeric id", .{key});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        switch (jira.pullRequests(a.client, scratch.allocator(), issue_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => {
                a.setStatus("{s}: linked-PR fetch failed", .{key});
                return;
            },
        }) {
            .ok => |list| {
                try st.putPrs(key, list);
                a.setStatus("{s}: {d} linked PR(s)", .{ key, list.len });
            },
            .failed => |f| a.setStatus("{s}: linked-PR fetch failed: {s}", .{ key, f.message }),
        }
    }

    pub fn ensurePipelines(a: *App, key: []const u8, pr: model.LinkedPr) Allocator.Error!void {
        const t = a.tab();
        const st = &(t.tree orelse return);
        if (st.pipelines(key, pr.id) != null or st.pipelineError(key, pr.id) != null) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        a.setStatus("fetching pipeline for {s} {s}…", .{ key, pr.id });
        switch (try a.forge.pipelinesForPrUrl(scratch.allocator(), pr.url)) {
            .ok => |list| {
                try st.putPipelines(key, pr.id, list);
                a.setStatus("{s} {s}: {d} pipeline(s) on merge commit", .{ key, pr.id, list.len });
            },
            .failed => |why| {
                try st.putPipelineError(key, pr.id, why);
                a.setStatus("{s} {s} pipeline lookup: {s}", .{ key, pr.id, why });
            },
        }
    }

    // ─── the detail ──────────────────────────────────────────────────────

    pub fn detailOf(a: *App, key: []const u8) ?model.IssueDetail {
        const e = a.details.get(key) orelse return null;
        return e.detail;
    }

    pub fn ensureDetail(a: *App, key: []const u8) Allocator.Error!void {
        if (a.details.contains(key)) return;
        const e = try a.gpa.create(DetailEntry);
        e.* = .{ .arena = std.heap.ArenaAllocator.init(a.gpa), .detail = .{} };
        switch (jira.issueDetail(a.client, e.arena.allocator(), key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(model.IssueDetail){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => |d| e.detail = d,
            .failed => |f| {
                e.detail.error_text = try e.arena.allocator().dupe(u8, f.message);
                a.setStatus("detail fetch failed for {s}: {s}", .{ key, f.message });
            },
        }
        try a.details.put(a.gpa, try a.keep(key), e);
    }

    pub fn invalidateDetail(a: *App, key: []const u8) void {
        if (a.details.fetchRemove(key)) |kv| {
            kv.value.arena.deinit();
            a.gpa.destroy(kv.value);
        }
    }

    fn ensureFocusedDetail(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        try a.ensureDetail(key);
    }

    pub fn toggleDetails(a: *App) Allocator.Error!void {
        a.details_visible = !a.details_visible;
        a.details_scroll = 0;
        if (a.details_visible) try a.ensureFocusedDetail();
    }

    // ─── navigation ──────────────────────────────────────────────────────

    fn afterMove(a: *App) Allocator.Error!void {
        if (a.details_visible) {
            a.details_scroll = 0;
            try a.ensureFocusedDetail();
        }
    }

    pub fn move(a: *App, delta: i64) Allocator.Error!void {
        if (!a.hasTabs()) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const t = a.tab();
        if (t.cfg.isTree()) {
            const r = (try a.treeRows(arena)) orelse return;
            if (r.rows.len == 0) return;
            const cur: i64 = @intCast(t.selected);
            t.selected = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(r.rows.len)) - 1));
        } else {
            const vis = try a.visibleIssues(arena);
            if (vis.len == 0) return;
            var pos: i64 = 0;
            for (vis, 0..) |i, k| if (i == t.selected) {
                pos = @intCast(k);
            };
            const np: usize = @intCast(std.math.clamp(pos + delta, 0, @as(i64, @intCast(vis.len)) - 1));
            t.selected = vis[np];
        }
        try a.afterMove();
    }

    pub fn moveHome(a: *App) Allocator.Error!void {
        try a.move(-std.math.maxInt(i32));
    }

    pub fn moveEnd(a: *App) Allocator.Error!void {
        try a.move(std.math.maxInt(i32));
    }

    /// Keep the tree cursor inside the row list after a fold or a filter.
    fn clampCursor(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const t = a.tab();
        if (t.cfg.isTree()) {
            const r = (try a.treeRows(scratch.allocator())) orelse return;
            if (r.rows.len == 0) t.selected = 0 else if (t.selected >= r.rows.len) t.selected = r.rows.len - 1;
        } else {
            const vis = try a.visibleIssues(scratch.allocator());
            if (vis.len == 0) return;
            for (vis) |i| if (i == t.selected) return;
            t.selected = vis[0];
        }
    }

    pub fn switchTab(a: *App, idx: usize) Allocator.Error!void {
        if (idx >= a.tabs.len) return;
        a.active = idx;
        if (!a.tabs[idx].fetched and a.tabs[idx].last_error.len == 0) {
            a.setStatus("loading {s}…", .{a.tabs[idx].cfg.name});
            try a.refreshActive();
        }
        try a.afterMove();
    }

    pub fn nextTab(a: *App) Allocator.Error!void {
        if (a.tabs.len == 0) return;
        try a.switchTab((a.active + 1) % a.tabs.len);
    }

    pub fn prevTab(a: *App) Allocator.Error!void {
        if (a.tabs.len == 0) return;
        try a.switchTab(if (a.active == 0) a.tabs.len - 1 else a.active - 1);
    }

    // ─── the tree ────────────────────────────────────────────────────────

    /// Enter / Space / a row click on a tree tab.
    pub fn treeActivate(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const row = (try a.focusedRow(scratch.allocator())) orelse {
            try a.openBrowser();
            return;
        };
        const t = a.tab();
        const st = &(t.tree.?);
        switch (row) {
            .group => |g| try st.toggleGroup(g.status),
            .ticket => |tk| {
                const key = t.issues[tk.issue_idx].key;
                if (st.isExpanded(key)) {
                    try st.setExpanded(key, false);
                } else {
                    try st.setExpanded(key, true);
                    try a.ensurePrs(a.active, key);
                }
            },
            .pr => |p| {
                const key = t.issues[p.issue_idx].key;
                if (st.prs(key)) |prs| if (p.pr_idx < prs.len and prs[p.pr_idx].url.len > 0) try a.openUrl(prs[p.pr_idx].url);
            },
            .show_more => |s| try st.showAll(t.issues[s.issue_idx].key),
            else => {},
        }
        try a.clampCursor();
    }

    pub fn treeExpand(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const row = (try a.focusedRow(scratch.allocator())) orelse return;
        const t = a.tab();
        const st = &(t.tree.?);
        switch (row) {
            .group => |g| if (!g.expanded) try st.setGroup(g.status, false),
            .ticket => |tk| {
                const key = t.issues[tk.issue_idx].key;
                if (!st.isExpanded(key)) {
                    try st.setExpanded(key, true);
                    try a.ensurePrs(a.active, key);
                }
            },
            .pr => |p| {
                const key = t.issues[p.issue_idx].key;
                const prs = st.prs(key) orelse return;
                if (p.pr_idx >= prs.len) return;
                const pr = prs[p.pr_idx];
                if (!pr.isMerged()) return;
                if (!st.isPrExpanded(key, pr.id)) {
                    try st.setPrExpanded(key, pr.id, true);
                    try a.ensurePipelines(key, pr);
                }
            },
            else => {},
        }
    }

    pub fn treeCollapse(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const row = (try a.focusedRow(scratch.allocator())) orelse return;
        const t = a.tab();
        const st = &(t.tree.?);
        switch (row) {
            .group => |g| if (g.expanded) try st.setGroup(g.status, true),
            .ticket => |tk| try st.setExpanded(t.issues[tk.issue_idx].key, false),
            .pr => |p| {
                const key = t.issues[p.issue_idx].key;
                if (st.prs(key)) |prs| if (p.pr_idx < prs.len) {
                    const pr = prs[p.pr_idx];
                    if (st.isPrExpanded(key, pr.id)) {
                        try st.setPrExpanded(key, pr.id, false);
                        return;
                    }
                };
                try st.setExpanded(key, false);
            },
            .pr_loading => |x| try st.setExpanded(t.issues[x.issue_idx].key, false),
            .show_more => |x| try st.setExpanded(t.issues[x.issue_idx].key, false),
            .pipeline_loading, .pipeline_empty, .pipeline_error => |x| {
                const k = t.issues[x.issue_idx].key;
                if (st.prs(k)) |prs| if (x.pr_idx < prs.len) try st.setPrExpanded(k, prs[x.pr_idx].id, false);
            },
            .pipeline => |x| {
                const k = t.issues[x.issue_idx].key;
                if (st.prs(k)) |prs| if (x.pr_idx < prs.len) try st.setPrExpanded(k, prs[x.pr_idx].id, false);
            },
        }
        try a.clampCursor();
    }

    // ─── the browser ─────────────────────────────────────────────────────

    pub fn openUrl(a: *App, url: []const u8) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        switch (os.open(a.io, scratch.allocator(), a.cfg.open_command, url)) {
            .ok => a.say("opened {s}", .{url}),
            .failed => |why| a.say("open failed: {s}", .{why}),
        }
    }

    pub fn openBrowser(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        try a.openUrl(try model.issueUrl(scratch.allocator(), a.cfg.jira_url, key));
    }

    // ─── the filter and the JQL editor ───────────────────────────────────

    pub fn openFilter(a: *App) Allocator.Error!void {
        if (a.filter) |*f| {
            f.editing = true;
            return;
        }
        a.filter = .{ .edit = TextEdit.init(a.gpa), .editing = true };
    }

    pub fn closeFilter(a: *App, commit: bool) Allocator.Error!void {
        var f = a.filter orelse return;
        if (commit and std.mem.trim(u8, f.edit.text(), " ").len > 0) {
            f.editing = false;
            a.filter = f;
        } else {
            f.edit.deinit();
            a.filter = null;
        }
        try a.clampCursor();
    }

    pub fn openJql(a: *App) Allocator.Error!void {
        if (a.jql != null or !a.hasTabs()) return;
        var e = TextEdit.init(a.gpa);
        try e.set(a.tab().jql);
        a.jql = e;
        a.tab().show_jql = true;
    }

    pub fn closeJql(a: *App, commit: bool) Allocator.Error!void {
        var e = a.jql orelse return;
        defer e.deinit();
        a.jql = null;
        if (!commit) return;
        const t = a.tab();
        t.jql = try a.keep(std.mem.trim(u8, e.text(), " "));
        t.fetched = false;
        try a.refreshActive();
    }

    // ─── selection ───────────────────────────────────────────────────────

    pub fn toggleSelection(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        if (a.selection.remove(key)) return;
        try a.selection.put(a.gpa, try a.keep(key), {});
    }

    pub fn clearSelection(a: *App) void {
        a.selection.clearRetainingCapacity();
    }

    pub fn isSelected(a: *const App, key: []const u8) bool {
        return a.selection.contains(key);
    }

    /// The keys an action runs on: the selection, else the focused row.
    pub fn bulkKeys(a: *App, arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (a.selection.count() > 0) {
            var it = a.selection.keyIterator();
            while (it.next()) |k| try out.append(arena, k.*);
            std.mem.sort([]const u8, out.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.order(u8, x, y) == .lt;
                }
            }.lt);
        } else if (try a.focusedKey(arena)) |k| try out.append(arena, k);
        return out.toOwnedSlice(arena);
    }

    // ─── the transition picker ───────────────────────────────────────────

    pub fn openTransition(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        var p = try pickers.TransitionPicker.init(a.gpa, key);
        p.targets = if (a.selection.count() > 0) a.selection.count() else 1;
        switch (jira.transitions(a.client, scratch.allocator(), key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer([]const model.Transition){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => |list| try p.setTransitions(list),
            .failed => |f| try p.fail(f.message),
        }
        a.transition = p;
    }

    pub fn closeTransition(a: *App) void {
        if (a.transition) |*p| p.deinit();
        a.transition = null;
    }

    pub fn commitTransition(a: *App) Allocator.Error!void {
        const p = &(a.transition orelse return);
        const chosen = p.current() orelse return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const to_name = if (chosen.to_name.len > 0) chosen.to_name else chosen.name;
        if (a.selection.count() == 0) {
            const key = p.key;
            switch (jira.doTransition(a.client, arena, key, chosen.id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => {
                    // The words are the picker's; say them before it goes.
                    a.say("{s} → {s}", .{ key, to_name });
                    a.closeTransition();
                    a.invalidateDetail(key);
                    try a.refreshActive();
                    if (a.details_visible) try a.ensureFocusedDetail();
                },
                .failed => |f| try p.fail(f.message),
            }
            return;
        }
        // Bulk: match by name on every selected ticket, skip the ones without it.
        const keys = try a.bulkKeys(arena);
        var ok: usize = 0;
        var skipped: std.ArrayList([]const u8) = .empty;
        var errors: std.ArrayList([]const u8) = .empty;
        for (keys) |key| {
            const list = switch (jira.transitions(a.client, arena, key) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer([]const model.Transition){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => |l| l,
                .failed => |f| {
                    try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ key, f.message }));
                    continue;
                },
            };
            var id: ?[]const u8 = null;
            for (list) |t| if (std.ascii.eqlIgnoreCase(t.name, chosen.name)) {
                id = t.id;
            };
            const tid = id orelse {
                try skipped.append(arena, key);
                continue;
            };
            switch (jira.doTransition(a.client, arena, key, tid) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => {
                    ok += 1;
                    a.invalidateDetail(key);
                },
                .failed => |f| try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ key, f.message })),
            }
        }
        if (errors.items.len == 0) {
            if (skipped.items.len > 0) {
                a.say("{d} ticket(s) → {s} · skipped {d}: {s}", .{ ok, to_name, skipped.items.len, try std.mem.join(arena, ", ", skipped.items) });
            } else a.say("{d} ticket(s) → {s}", .{ ok, to_name });
            a.closeTransition();
            a.clearSelection();
        } else {
            try p.fail(try std.fmt.allocPrint(arena, "{d} ok · {d} skipped · {d} failed — {s}", .{ ok, skipped.items.len, errors.items.len, try std.mem.join(arena, " / ", errors.items) }));
        }
        try a.refreshActive();
        if (a.details_visible) try a.ensureFocusedDetail();
    }

    // ─── the field pickers ───────────────────────────────────────────────

    fn startPicker(a: *App, kind: pickers.Kind) Allocator.Error!*pickers.FieldPicker {
        a.closePicker();
        a.picker = pickers.FieldPicker.init(a.gpa, kind);
        const p = &(a.picker.?);
        p.targets = if (a.selection.count() > 0) a.selection.count() else 1;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        if (try a.focusedKey(scratch.allocator())) |k| p.focused_key = try p.arena().dupe(u8, k);
        return p;
    }

    pub fn closePicker(a: *App) void {
        if (a.picker) |*p| p.deinit();
        a.picker = null;
    }

    fn failPicker(a: *App, p: *pickers.FieldPicker, err: jira.CallError) Allocator.Error!void {
        _ = a;
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => try p.fail("the site did not answer"),
        }
    }

    pub fn openAssignee(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const key = (try a.focusedKey(arena)) orelse return;
        const project = model.projectOf(key) orelse {
            a.setStatus("can't derive project from {s}", .{key});
            return;
        };
        const p = try a.startPicker(.assignee);
        switch (jira.assignableUsers(a.client, arena, project) catch |err| return a.failPicker(p, err)) {
            .ok => |users| {
                var items: std.ArrayList(pickers.Item) = .empty;
                try items.append(arena, .{ .id = "", .label = "— Unassign —" });
                for (users) |u| try items.append(arena, .{ .id = u.account_id, .label = u.display_name });
                try p.setItems(items.items);
            },
            .failed => |f| try p.fail(f.message),
        }
    }

    fn versionItems(a: *App, arena: Allocator, project: []const u8, clear_row: ?[]const u8) Allocator.Error!jira.Answer([]const pickers.Item) {
        switch (jira.projectVersions(a.client, arena, project) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => return .{ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .failed => |f| return .{ .failed = f },
            .ok => |all| {
                var items: std.ArrayList(pickers.Item) = .empty;
                if (clear_row) |c| try items.append(arena, .{ .id = "", .label = c });
                for (try jira.pickerVersions(arena, all)) |v| {
                    const label = if (v.released) try std.fmt.allocPrint(arena, "{s} (released)", .{v.name}) else v.name;
                    try items.append(arena, .{ .id = v.name, .label = label });
                }
                return .{ .ok = try items.toOwnedSlice(arena) };
            },
        }
    }

    pub fn openFixVersion(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const key = (try a.focusedKey(arena)) orelse return;
        const project = model.projectOf(key) orelse return;
        const p = try a.startPicker(.fix_version);
        switch (try a.versionItems(arena, project, "— Clear fixVersion —")) {
            .ok => |items| try p.setItems(items),
            .failed => |f| try p.fail(f.message),
        }
    }

    pub fn openTabFixVersion(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.cfg.project.len == 0) {
            a.setStatus("V: tab has no `project`", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const p = try a.startPicker(.tab_fix_version);
        switch (try a.versionItems(scratch.allocator(), t.cfg.project, null)) {
            .ok => |items| try p.setItems(items),
            .failed => |f| try p.fail(f.message),
        }
    }

    /// The distinct values of a field over the tab's tickets, sorted.
    fn distinct(a: *App, arena: Allocator, comptime pick: fn (Issue, *std.ArrayList([]const u8), Allocator) Allocator.Error!void) Allocator.Error![]const []const u8 {
        var seen: std.ArrayList([]const u8) = .empty;
        for (a.tab().issues) |iss| {
            var vals: std.ArrayList([]const u8) = .empty;
            try pick(iss, &vals, arena);
            for (vals.items) |v| {
                if (std.mem.trim(u8, v, " ").len == 0) continue;
                var dup = false;
                for (seen.items) |s| if (std.mem.eql(u8, s, v)) {
                    dup = true;
                };
                if (!dup) try seen.append(arena, v);
            }
        }
        std.mem.sort([]const u8, seen.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        return seen.toOwnedSlice(arena);
    }

    fn pickTeam(iss: Issue, out: *std.ArrayList([]const u8), arena: Allocator) Allocator.Error!void {
        for (iss.components) |c| try out.append(arena, c);
        for (iss.labels) |l| try out.append(arena, l);
        if (iss.team.len > 0) try out.append(arena, iss.team);
    }

    fn pickType(iss: Issue, out: *std.ArrayList([]const u8), arena: Allocator) Allocator.Error!void {
        try out.append(arena, iss.issuetype);
    }

    fn pickLabel(iss: Issue, out: *std.ArrayList([]const u8), arena: Allocator) Allocator.Error!void {
        for (iss.labels) |l| try out.append(arena, l);
    }

    fn openLocalPicker(a: *App, kind: pickers.Kind, clear_row: []const u8, comptime pick: fn (Issue, *std.ArrayList([]const u8), Allocator) Allocator.Error!void) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const values = try a.distinct(arena, pick);
        const p = try a.startPicker(kind);
        var items: std.ArrayList(pickers.Item) = .empty;
        try items.append(arena, .{ .id = "", .label = clear_row });
        for (values) |v| try items.append(arena, .{ .id = v, .label = v });
        try p.setItems(items.items);
    }

    pub fn openTeam(a: *App) Allocator.Error!void {
        try a.openLocalPicker(.team, "— Clear team —", pickTeam);
    }

    pub fn openIssueType(a: *App) Allocator.Error!void {
        try a.openLocalPicker(.issue_type, "— Clear type —", pickType);
    }

    pub fn openLabel(a: *App) Allocator.Error!void {
        try a.openLocalPicker(.label, "— Clear label —", pickLabel);
    }

    pub fn openActions(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const idx = (try a.focusedIssueIdx(arena)) orelse return;
        const iss = a.tab().issues[idx];
        const buttons = dispatch.buttonsForTicket(iss);
        if (buttons.len == 0) {
            a.setStatus(". actions: no ticket-level actions for {s} ({s} · {s})", .{ iss.key, if (iss.issuetype.len > 0) iss.issuetype else "?", if (iss.status.len > 0) iss.status else "?" });
            return;
        }
        const p = try a.startPicker(.action);
        var items: std.ArrayList(pickers.Item) = .empty;
        for (buttons) |b| try items.append(arena, .{ .id = b.kind(), .label = b.label() });
        try p.setItems(items.items);
    }

    pub fn openSprint(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.board_id == 0) {
            a.setStatus("sprint picker: this tab has no `board_id`", .{});
            return;
        }
        if (t.sprints == null) try a.loadSprints(a.active);
        const list = t.sprints orelse &.{};
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const sorted = try model.Sprint.sortForPicker(arena, list, 5);
        if (sorted.len == 0) {
            a.setStatus("sprint picker: this board has no sprints", .{});
            return;
        }
        const p = try a.startPicker(.sprint);
        var items: std.ArrayList(pickers.Item) = .empty;
        try items.append(arena, .{ .id = "", .label = "— Board default (active sprint) —" });
        for (sorted) |s| {
            const tag = if (std.ascii.eqlIgnoreCase(s.state, "active")) "active" else if (std.ascii.eqlIgnoreCase(s.state, "future")) "future" else "closed";
            try items.append(arena, .{ .id = try std.fmt.allocPrint(arena, "{d}", .{s.id}), .label = try std.fmt.allocPrint(arena, "{s}  [{s}]", .{ s.name, tag }) });
        }
        try p.setItems(items.items);
        if (t.selected_sprint) |id| p.selectId(try std.fmt.allocPrint(arena, "{d}", .{id}));
    }

    pub fn openQuickFilters(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.board_id == 0) {
            a.setStatus("quick filters: this tab has no `board_id`", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        if (t.quick_filters == null) {
            switch (jira.quickFilters(a.client, arena, t.board_id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer([]const model.QuickFilter){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => |list| {
                    const copy = try t.meta.allocator().alloc(model.QuickFilter, list.len);
                    for (list, copy) |src, *dst| dst.* = .{ .id = src.id, .name = try t.meta.allocator().dupe(u8, src.name), .jql = try t.meta.allocator().dupe(u8, src.jql) };
                    t.quick_filters = copy;
                },
                .failed => |f| {
                    const p = try a.startPicker(.quick_filter);
                    try p.fail(f.message);
                    return;
                },
            }
        }
        const qfs = t.quick_filters.?;
        if (qfs.len == 0) {
            a.setStatus("quick filters: this board defines none", .{});
            return;
        }
        const p = try a.startPicker(.quick_filter);
        var items: std.ArrayList(pickers.Item) = .empty;
        var seed: std.ArrayList([]const u8) = .empty;
        for (qfs) |q| {
            const id = try std.fmt.allocPrint(arena, "{d}", .{q.id});
            try items.append(arena, .{ .id = id, .label = q.name });
            for (t.active_quick_filters.items) |x| if (x == q.id) try seed.append(arena, id);
        }
        try p.setItems(items.items);
        try p.seedMulti(seed.items);
    }

    pub fn openBoard(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.cfg.project.len == 0) {
            a.setStatus("board picker: this tab has no `project`", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        if (t.boards == null) {
            switch (jira.boardsForProject(a.client, arena, t.cfg.project) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Transport => jira.Answer([]const model.Board){ .failed = .{ .status = 0, .message = "the site did not answer" } },
            }) {
                .ok => |list| {
                    const copy = try t.meta.allocator().alloc(model.Board, list.len);
                    for (list, copy) |src, *dst| dst.* = .{ .id = src.id, .name = try t.meta.allocator().dupe(u8, src.name), .kind = try t.meta.allocator().dupe(u8, src.kind) };
                    t.boards = copy;
                },
                .failed => |f| {
                    const p = try a.startPicker(.board);
                    try p.fail(f.message);
                    return;
                },
            }
        }
        const boards = t.boards.?;
        if (boards.len == 0) {
            a.setStatus("board picker: project {s} has no visible boards", .{t.cfg.project});
            return;
        }
        const p = try a.startPicker(.board);
        var items: std.ArrayList(pickers.Item) = .empty;
        try items.append(arena, .{ .id = "", .label = "— Board default —" });
        for (boards) |b| {
            const label = if (b.kind.len > 0) try std.fmt.allocPrint(arena, "{s}  [{s}]", .{ b.name, b.kind }) else b.name;
            try items.append(arena, .{ .id = try std.fmt.allocPrint(arena, "{d}", .{b.id}), .label = label });
        }
        try p.setItems(items.items);
        if (t.board_id != 0) p.selectId(try std.fmt.allocPrint(arena, "{d}", .{t.board_id}));
    }

    pub fn openEpic(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.issues.len == 0) {
            a.setStatus("Epic filter: no issues on this tab yet — refresh first", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var items: std.ArrayList(pickers.Item) = .empty;
        for (t.issues) |iss| {
            const key = iss.epicKey() orelse continue;
            var dup = false;
            for (items.items) |it| if (std.mem.eql(u8, it.id, key)) {
                dup = true;
            };
            if (dup) continue;
            const label = if (iss.parent_summary.len > 0) try std.fmt.allocPrint(arena, "{s}  {s}", .{ key, iss.parent_summary }) else key;
            try items.append(arena, .{ .id = key, .label = label });
        }
        if (items.items.len == 0) {
            a.setStatus("Epic filter: no epics found on current issues", .{});
            return;
        }
        std.mem.sort(pickers.Item, items.items, {}, struct {
            fn lt(_: void, x: pickers.Item, y: pickers.Item) bool {
                return std.mem.order(u8, x.id, y.id) == .lt;
            }
        }.lt);
        const p = try a.startPicker(.epic);
        try p.setItems(items.items);
        try p.seedMulti(try t.activeEpics(arena));
    }

    /// The avatar cluster's overflow / the Assignee chip: every assignee
    /// seen on the tab, Me and Unassigned first.
    pub fn openAssignees(a: *App) Allocator.Error!void {
        const t = a.tab();
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const p = try a.startPicker(.assignees);
        var items: std.ArrayList(pickers.Item) = .empty;
        if (a.me) |me| if (me.account_id.len > 0) try items.append(arena, .{ .id = me.account_id, .label = "— Me (Current User) —" });
        try items.append(arena, .{ .id = model.unassigned_sentinel, .label = "— Unassigned —" });
        for (t.assignees) |s| try items.append(arena, .{ .id = s.account_id, .label = try std.fmt.allocPrint(arena, "{s}  ({d})", .{ s.display_name, s.count }) });
        try p.setItems(items.items);
        try p.seedMulti(try t.activeIds(arena));
    }

    fn resetSet(a: *App, set: *std.StringHashMapUnmanaged(void), ids: []const []const u8) Allocator.Error!void {
        set.clearRetainingCapacity();
        for (ids) |id| try set.put(a.gpa, try a.keep(id), {});
    }

    /// Enter in a field picker.
    pub fn commitPicker(a: *App) Allocator.Error!void {
        const p = &(a.picker orelse return);
        if (!p.loaded) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const t = a.tab();
        switch (p.kind) {
            .team => {
                const it = p.current() orelse return;
                t.team = try a.keep(it.id);
                a.say("team filter: {s}", .{if (it.id.len == 0) "(cleared)" else it.label});
                a.closePicker();
                try a.refreshActive();
            },
            .issue_type => {
                const it = p.current() orelse return;
                t.issue_type = try a.keep(it.id);
                a.say("type filter: {s}", .{if (it.id.len == 0) "(cleared)" else it.label});
                a.closePicker();
                try a.clampCursor();
            },
            .label => {
                const it = p.current() orelse return;
                t.label = try a.keep(it.id);
                a.say("label filter: {s}", .{if (it.id.len == 0) "(cleared)" else it.label});
                a.closePicker();
                try a.clampCursor();
            },
            .tab_fix_version => {
                const it = p.current() orelse return;
                if (t.cfg.project.len == 0) {
                    a.closePicker();
                    return;
                }
                t.jql = try a.keep(try jira.fixVersionJql(arena, t.cfg.project, it.id, ""));
                a.say("tab view: fixVersion = {s}", .{it.id});
                a.closePicker();
                try a.refreshActive();
            },
            .action => {
                const it = p.current() orelse return;
                const kind = try arena.dupe(u8, it.id);
                a.closePicker();
                try a.dispatchTicket(kind);
            },
            .sprint => {
                const it = p.current() orelse return;
                t.selected_sprint = if (it.id.len == 0) null else std.fmt.parseInt(u64, it.id, 10) catch null;
                a.kanban_scroll = .{ 0, 0, 0, 0 };
                a.closePicker();
                if (t.selected_sprint) |id| a.say("sprint: pinned to {d}", .{id}) else a.say("sprint: back to board default (active)", .{});
                try a.refreshActive();
            },
            .quick_filter => {
                const ids = try p.checked(arena);
                t.active_quick_filters.clearRetainingCapacity();
                for (ids) |id| try t.active_quick_filters.append(a.gpa, std.fmt.parseInt(u64, id, 10) catch continue);
                a.closePicker();
                if (t.active_quick_filters.items.len == 0) a.say("quick filters: cleared", .{}) else a.say("quick filters: {d} active", .{t.active_quick_filters.items.len});
                try a.refreshActive();
            },
            .assignees => {
                const ids = try p.checked(arena);
                try a.resetSet(&t.active_assignees, ids);
                a.closePicker();
                if (ids.len == 0) a.say("assignees: all", .{}) else a.say("assignees: {d} active", .{ids.len});
                try a.clampCursor();
            },
            .board => {
                const it = p.current() orelse return;
                t.board_id = if (it.id.len == 0) 0 else std.fmt.parseInt(u64, it.id, 10) catch 0;
                t.sprints = null;
                t.quick_filters = null;
                t.selected_sprint = null;
                t.active_quick_filters.clearRetainingCapacity();
                a.kanban_scroll = .{ 0, 0, 0, 0 };
                a.closePicker();
                if (t.board_id != 0) a.say("board: switched to {d}", .{t.board_id}) else a.say("board: back to default (synthetic JQL)", .{});
                try a.refreshActive();
            },
            .epic => {
                const ids = try p.checked(arena);
                try a.resetSet(&t.active_epics, ids);
                a.closePicker();
                if (ids.len == 0) a.say("epic filter: cleared", .{}) else a.say("epic filter: {d} active", .{ids.len});
                try a.clampCursor();
            },
            .assignee, .fix_version => {
                const it = p.current() orelse return;
                const keys = try a.bulkKeys(arena);
                if (keys.len == 0) return;
                var ok: usize = 0;
                var errors: std.ArrayList([]const u8) = .empty;
                const id = try arena.dupe(u8, it.id);
                const label = try arena.dupe(u8, it.label);
                const kind = p.kind;
                for (keys) |key| {
                    const answer = (if (kind == .assignee) jira.setAssignee(a.client, arena, key, id) else jira.setFixVersion(a.client, arena, key, id)) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
                    };
                    switch (answer) {
                        .ok => {
                            ok += 1;
                            a.invalidateDetail(key);
                        },
                        .failed => |f| try errors.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ key, f.message })),
                    }
                }
                if (errors.items.len == 0) {
                    a.closePicker();
                    a.say("{d} ticket(s) · {s} = {s}", .{ ok, if (kind == .assignee) "assignee" else "fixVersion", label });
                    a.clearSelection();
                } else {
                    try p.fail(try std.fmt.allocPrint(arena, "{d} ok · {d} failed — {s}", .{ ok, errors.items.len, try std.mem.join(arena, " / ", errors.items) }));
                }
                try a.refreshActive();
                if (a.details_visible) try a.ensureFocusedDetail();
            },
        }
    }

    /// A click on an avatar / the `[?]` chip: toggle one id.
    pub fn toggleAssignee(a: *App, id: []const u8) Allocator.Error!void {
        const t = a.tab();
        if (t.active_assignees.remove(id)) {
            try a.clampCursor();
            return;
        }
        try t.active_assignees.put(a.gpa, try a.keep(id), {});
        try a.clampCursor();
    }

    /// The Status chip: All → Unresolved → Resolved → All.
    pub fn cycleScope(a: *App) Allocator.Error!void {
        const t = a.tab();
        t.scope = t.scope.cycle();
        try a.clampCursor();
    }

    /// The fixVersion pill's ⓧ: drop the clause and refetch.
    pub fn removeFixVersionClause(a: *App) Allocator.Error!void {
        const t = a.tab();
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        t.jql = try a.keep(try stripFixVersion(scratch.allocator(), t.jql));
        t.fetched = false;
        try a.refreshActive();
    }

    // ─── comments and watching ───────────────────────────────────────────

    pub fn openComment(a: *App) Allocator.Error!void {
        if (!a.details_visible) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const key = (try a.focusedKey(scratch.allocator())) orelse return;
        a.closeComment();
        a.comment = .{ .key = try a.keep(key), .edit = TextEdit.init(a.gpa) };
    }

    pub fn closeComment(a: *App) void {
        if (a.comment) |*c| c.edit.deinit();
        a.comment = null;
    }

    pub fn submitComment(a: *App) Allocator.Error!void {
        const c = &(a.comment orelse return);
        if (std.mem.trim(u8, c.edit.text(), " \n").len == 0 or c.posting) return;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        c.posting = true;
        c.error_text = "";
        switch (jira.addComment(a.client, scratch.allocator(), c.key, c.edit.text()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => {
                const key = c.key;
                a.closeComment();
                a.say("commented on {s}", .{key});
                a.invalidateDetail(key);
                if (a.details_visible) try a.ensureFocusedDetail();
            },
            .failed => |f| {
                c.posting = false;
                c.error_text = try a.keep(f.message);
            },
        }
    }

    pub fn toggleWatch(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const key = (try a.focusedKey(arena)) orelse return;
        try a.ensureDetail(key);
        const was = if (a.detailOf(key)) |d| d.watching else false;
        const answer = blk: {
            if (was) {
                try a.ensureMe();
                const me = a.me orelse {
                    a.say("can't unwatch — the account id is unknown (/myself failed)", .{});
                    return;
                };
                break :blk jira.unwatch(a.client, arena, key, me.account_id);
            }
            break :blk jira.watch(a.client, arena, key);
        } catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(void){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        };
        switch (answer) {
            .ok => {
                a.say("{s} {s}", .{ if (was) "unwatched" else "watched", key });
                a.invalidateDetail(key);
                if (a.details_visible) try a.ensureFocusedDetail();
            },
            .failed => |f| a.say("watch toggle failed for {s}: {s}", .{ key, f.message }),
        }
    }

    // ─── the dispatch queue ──────────────────────────────────────────────

    fn isoNow(a: *App, buf: *[24]u8) []const u8 {
        const secs: u64 = @intCast(@max(@divTrunc(a.nowMs(), 1000), 0));
        const es = std.time.epoch.EpochSeconds{ .secs = secs };
        const day = es.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch "";
    }

    pub fn dispatchTicket(a: *App, kind: []const u8) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const idx = (try a.focusedIssueIdx(arena)) orelse {
            a.setStatus("no ticket under cursor", .{});
            return;
        };
        const iss = a.tab().issues[idx];
        var buf: [24]u8 = undefined;
        const d = dispatch.Dispatch.forTicket(kind, iss, try model.issueUrl(arena, a.cfg.jira_url, iss.key), a.isoNow(&buf));
        const paths = try dispatch.workspacePaths(arena, a.io, a.cfg.dispatch_workspace);
        a.say("{s}", .{try dispatch.fire(arena, a.io, d, paths)});
    }

    pub fn dispatchReview(a: *App) Allocator.Error!void {
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const row = (try a.focusedRow(arena)) orelse {
            a.setStatus("no PR under cursor", .{});
            return;
        };
        const p = switch (row) {
            .pr => |p| p,
            else => {
                a.setStatus("no PR under cursor", .{});
                return;
            },
        };
        const t = a.tab();
        const iss = t.issues[p.issue_idx];
        const prs = t.tree.?.prs(iss.key) orelse return;
        if (p.pr_idx >= prs.len or prs[p.pr_idx].url.len == 0) {
            a.setStatus("PR has no URL", .{});
            return;
        }
        var buf: [24]u8 = undefined;
        const d = dispatch.Dispatch.forPr(iss, try model.issueUrl(arena, a.cfg.jira_url, iss.key), prs[p.pr_idx].url, a.isoNow(&buf));
        const paths = try dispatch.workspacePaths(arena, a.io, a.cfg.dispatch_workspace);
        a.say("{s}", .{try dispatch.fire(arena, a.io, d, paths)});
    }

    // ─── the detail modal ────────────────────────────────────────────────

    pub fn openModal(a: *App, key: []const u8) Allocator.Error!void {
        a.closeModal();
        var m: Modal = .{ .key = try a.keep(key), .arena = std.heap.ArenaAllocator.init(a.gpa) };
        var fields: std.ArrayList([]const u8) = .empty;
        const arena = m.arena.allocator();
        for (a.cfg.detail_modal.fields) |spec| try fields.append(arena, a.cfg.detail_modal.resolveId(spec));
        for ([_][]const u8{ "summary", "status", "issuetype", "priority", "assignee", "reporter", "labels", "components", "fixVersions", "parent", "description", "customfield_10020" }) |baked| {
            var dup = false;
            for (fields.items) |f| if (std.mem.eql(u8, f, baked)) {
                dup = true;
            };
            if (!dup) try fields.append(arena, baked);
        }
        switch (jira.issueFull(a.client, arena, key, fields.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(Value){ .failed = .{ .status = 0, .message = "the site did not answer" } },
        }) {
            .ok => |v| m.data = v,
            .failed => |f| m.error_text = try arena.dupe(u8, f.message),
        }
        a.modal = m;
    }

    pub fn closeModal(a: *App) void {
        if (a.modal) |*m| m.arena.deinit();
        a.modal = null;
    }

    pub fn modalScroll(a: *App, delta: i32) void {
        const m = &(a.modal orelse return);
        const cur: i32 = m.scroll;
        m.scroll = @intCast(@max(cur + delta, 0));
    }

    // ─── the kanban ──────────────────────────────────────────────────────

    pub fn toggleCard(a: *App, key: []const u8) Allocator.Error!void {
        if (a.kanban_expanded.remove(key)) return;
        try a.kanban_expanded.put(a.gpa, try a.keep(key), {});
    }

    pub fn isCardExpanded(a: *const App, key: []const u8) bool {
        return a.kanban_expanded.contains(key);
    }

    pub fn scrollColumn(a: *App, col: usize, delta: i32) void {
        if (col >= kanban.count) return;
        const cur: i32 = a.kanban_scroll[col];
        a.kanban_scroll[col] = @intCast(@max(cur + delta, 0));
    }

    pub fn boardName(a: *App, id: u64) Allocator.Error![]const u8 {
        if (a.board_names.get(id)) |n| return n;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const name: []const u8 = switch (jira.board(a.client, scratch.allocator(), id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Transport => jira.Answer(model.Board){ .failed = .{ .status = 0, .message = "" } },
        }) {
            .ok => |b| try a.keep(b.name),
            .failed => try std.fmt.allocPrint(a.keys.allocator(), "{d}", .{id}),
        };
        try a.board_names.put(a.gpa, id, name);
        return name;
    }

    pub fn openBoardSettings(a: *App) Allocator.Error!void {
        const t = a.tab();
        if (t.board_id == 0) {
            a.setStatus("board settings: this tab has no `board_id`", .{});
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const url = if (t.cfg.project.len > 0)
            try std.fmt.allocPrint(scratch.allocator(), "{s}/jira/software/c/projects/{s}/boards/{d}?config=filter", .{ a.cfg.jira_url, t.cfg.project, t.board_id })
        else
            try std.fmt.allocPrint(scratch.allocator(), "{s}/secure/RapidBoard.jspa?rapidView={d}&config=filter", .{ a.cfg.jira_url, t.board_id });
        try a.openUrl(url);
    }

    // ─── keys ────────────────────────────────────────────────────────────

    /// One key from the host. Returns false when nothing took it.
    pub fn onKey(a: *App, spec: []const u8) Allocator.Error!bool {
        if (a.help) {
            if (std.mem.eql(u8, spec, "esc") or std.mem.eql(u8, spec, "?") or std.mem.eql(u8, spec, "q") or std.mem.eql(u8, spec, "f1")) {
                a.help = false;
            } else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "j")) {
                a.help_scroll += 1;
            } else if (std.mem.eql(u8, spec, "up") or std.mem.eql(u8, spec, "k")) {
                a.help_scroll -|= 1;
            }
            return true;
        }
        if (a.modal != null) {
            if (std.mem.eql(u8, spec, "esc") or std.mem.eql(u8, spec, "q")) a.closeModal() else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "j")) a.modalScroll(2) else if (std.mem.eql(u8, spec, "up") or std.mem.eql(u8, spec, "k")) a.modalScroll(-2) else if (std.mem.eql(u8, spec, "pagedown")) a.modalScroll(10) else if (std.mem.eql(u8, spec, "pageup")) a.modalScroll(-10);
            return true;
        }
        if (a.comment) |*c| {
            if (std.mem.eql(u8, spec, "esc")) {
                a.closeComment();
            } else if (std.mem.eql(u8, spec, "ctrl+s")) {
                try a.submitComment();
            } else if (std.mem.eql(u8, spec, "enter")) {
                // Enter is a newline; Enter on an empty last line sends,
                // since a host keeps Ctrl+S for itself.
                if (c.posting) return true;
                const t = c.edit.text();
                if (t.len > 0 and t[t.len - 1] == '\n' and c.edit.cursor == t.len) {
                    c.edit.buf.items.len = std.mem.trimEnd(u8, t, "\n").len;
                    c.edit.cursor = c.edit.buf.items.len;
                    try a.submitComment();
                } else try c.edit.insert("\n");
            } else if (!c.posting) _ = try c.edit.key(spec);
            return true;
        }
        if (a.picker) |*p| {
            if (std.mem.eql(u8, spec, "esc")) {
                a.closePicker();
            } else if (std.mem.eql(u8, spec, "enter")) {
                try a.commitPicker();
            } else if (std.mem.eql(u8, spec, "up")) {
                try p.move(-1);
            } else if (std.mem.eql(u8, spec, "down")) {
                try p.move(1);
            } else if (std.mem.eql(u8, spec, "backspace")) {
                try p.backspace();
            } else if (std.mem.eql(u8, spec, "space") and p.kind.multi()) {
                try p.toggleSelected();
            } else if (std.mem.eql(u8, spec, "space")) {
                try p.insert(" ");
            } else if (TextEdit.printable(spec)) |s| try p.insert(s);
            return true;
        }
        if (a.transition) |*p| {
            if (std.mem.eql(u8, spec, "esc")) {
                a.closeTransition();
            } else if (std.mem.eql(u8, spec, "enter")) {
                try a.commitTransition();
            } else if (std.mem.eql(u8, spec, "up") or std.mem.eql(u8, spec, "k")) {
                p.move(-1);
            } else if (std.mem.eql(u8, spec, "down") or std.mem.eql(u8, spec, "j")) {
                p.move(1);
            } else if (keymap.tabDigit(spec)) |d| p.jump(d);
            return true;
        }
        if (a.filter) |*f| if (f.editing) {
            if (std.mem.eql(u8, spec, "esc")) {
                try a.closeFilter(false);
            } else if (std.mem.eql(u8, spec, "enter")) {
                try a.closeFilter(true);
            } else if (try f.edit.key(spec)) {
                try a.clampCursor();
            }
            return true;
        };
        if (a.jql) |*e| {
            if (std.mem.eql(u8, spec, "esc")) {
                try a.closeJql(false);
            } else if (std.mem.eql(u8, spec, "enter")) {
                try a.closeJql(true);
            } else _ = try e.key(spec);
            return true;
        }
        if (!a.hasTabs()) {
            if (std.mem.eql(u8, spec, "q") or std.mem.eql(u8, spec, "esc")) a.quit = true;
            return true;
        }
        const action = keymap.resolve(spec, a.context()) orelse return false;
        a.status.clearRetainingCapacity();
        try a.act(action, spec);
        return true;
    }

    pub fn act(a: *App, action: keymap.Action, spec: []const u8) Allocator.Error!void {
        switch (action) {
            .quit => a.quit = true,
            .escape => {
                if (a.selection.count() > 0) {
                    a.clearSelection();
                } else if (a.filter != null) {
                    try a.closeFilter(false);
                } else if (a.details_visible) {
                    try a.toggleDetails();
                } else a.quit = true;
            },
            .refresh => {
                if (a.details_visible) {
                    var scratch = std.heap.ArenaAllocator.init(a.gpa);
                    defer scratch.deinit();
                    if (try a.focusedKey(scratch.allocator())) |k| a.invalidateDetail(k);
                }
                try a.refreshActive();
                if (a.details_visible) try a.ensureFocusedDetail();
            },
            .up => try a.move(-1),
            .down => try a.move(1),
            .page_up => try a.move(-10),
            .page_down => try a.move(10),
            .home => try a.moveHome(),
            .end => try a.moveEnd(),
            .open_browser => try a.openBrowser(),
            .next_tab => try a.nextTab(),
            .prev_tab => try a.prevTab(),
            .switch_tab => if (keymap.tabDigit(spec)) |d| try a.switchTab(d),
            .toggle_details => try a.toggleDetails(),
            .detail_scroll_up => a.details_scroll -|= 4,
            .detail_scroll_down => a.details_scroll +|= 4,
            .filter => try a.openFilter(),
            .jql_editor => try a.openJql(),
            .transition => try a.openTransition(),
            .watch => try a.toggleWatch(),
            .comment => try a.openComment(),
            .toggle_select => try a.toggleSelection(),
            .assignee => try a.openAssignee(),
            .fix_version => try a.openFixVersion(),
            .tab_fix_version => try a.openTabFixVersion(),
            .team => try a.openTeam(),
            .action_picker => try a.openActions(),
            .tree_activate => try a.treeActivate(),
            .tree_expand => try a.treeExpand(),
            .tree_collapse => try a.treeCollapse(),
            .dispatch_implement => try a.dispatchTicket("implement"),
            .dispatch_fix => try a.dispatchTicket("fix"),
            .dispatch_triage => try a.dispatchTicket("triage"),
            .dispatch_review => try a.dispatchReview(),
            .detail_modal => {
                var scratch = std.heap.ArenaAllocator.init(a.gpa);
                defer scratch.deinit();
                if (try a.focusedKey(scratch.allocator())) |k| try a.openModal(k);
            },
            .card_expand => {
                var scratch = std.heap.ArenaAllocator.init(a.gpa);
                defer scratch.deinit();
                if (try a.focusedKey(scratch.allocator())) |k| try a.toggleCard(k);
            },
            .help => {
                a.help = true;
                a.help_scroll = 0;
            },
        }
    }

    pub fn paste(a: *App, text_in: []const u8) Allocator.Error!void {
        if (a.jql) |*e| try e.insert(text_in) else if (a.comment) |*c| try c.edit.insert(text_in) else if (a.filter) |*f| {
            if (f.editing) try f.edit.insert(text_in);
        } else if (a.picker) |*p| try p.insert(text_in);
    }

    // ─── the mouse ───────────────────────────────────────────────────────

    /// A press, routed by the hit map the last paint filled.
    pub fn click(a: *App, col: u16, row: u16, right: bool) Allocator.Error!void {
        const target = a.hits.at(col, row);
        if (a.help) {
            a.help = false;
            return;
        }
        if (a.jql != null) {
            switch (target orelse hit.Target.jql_body) {
                .jql_text => |t| {
                    const r = a.hits.rectOf(target.?) orelse return;
                    a.jql.?.setCursorCodepoints(@as(usize, t.row) * a.jqlWrapWidth() + (col -| r.x));
                },
                .jql_body => {},
                else => try a.closeJql(false),
            }
            return;
        }
        if (a.picker != null) {
            switch (target orelse hit.Target.picker_body) {
                .picker_row => |i| {
                    a.picker.?.selected = i;
                    try a.commitPicker();
                },
                .picker_body => {},
                else => a.closePicker(),
            }
            return;
        }
        if (a.transition != null) {
            switch (target orelse hit.Target.picker_body) {
                .picker_row => |i| {
                    a.transition.?.jump(i);
                    try a.commitTransition();
                },
                .picker_body => {},
                else => a.closeTransition(),
            }
            return;
        }
        if (a.modal != null) {
            switch (target orelse hit.Target.modal_close) {
                .modal_body => {},
                else => a.closeModal(),
            }
            return;
        }
        if (a.comment != null) return;
        const tg = target orelse return;
        switch (tg) {
            .row => |i| try a.clickRow(i, right),
            .chevron => |i| try a.clickChevron(i),
            .show_more => |i| {
                a.tab().selected = i;
                try a.treeActivate();
            },
            .pr_button => |b| try a.clickPrButton(b.row, b.which),
            .action => |x| {
                const iss = a.tab().issue(x.issue) orelse return;
                const buttons = dispatch.buttonsForTicket(iss);
                if (x.button < buttons.len) {
                    try a.selectIssue(x.issue);
                    try a.dispatchTicket(buttons[x.button].kind());
                }
            },
            .tab => |i| try a.switchTab(i),
            .chip => |c| try a.clickChip(c),
            .avatar => |i| {
                const t = a.tab();
                if (i < t.assignees.len) try a.toggleAssignee(t.assignees[i].account_id);
            },
            .filter => try a.openFilter(),
            .card => |i| {
                try a.selectIssue(i);
                if (right) {
                    try a.toggleCard(a.tab().issues[i].key);
                } else try a.openModal(a.tab().issues[i].key);
            },
            .card_chevron => |i| {
                try a.selectIssue(i);
                try a.toggleCard(a.tab().issues[i].key);
            },
            .column, .detail, .comment, .help_body, .picker_row, .picker_body, .modal_close, .modal_body, .jql_text, .jql_body => {},
        }
    }

    fn selectIssue(a: *App, idx: usize) Allocator.Error!void {
        const t = a.tab();
        if (t.cfg.isTree()) {
            var scratch = std.heap.ArenaAllocator.init(a.gpa);
            defer scratch.deinit();
            const r = (try a.treeRows(scratch.allocator())) orelse return;
            if (idx < t.issues.len) if (tree.rowOfKey(r.rows, t.issues, t.issues[idx].key)) |ri| {
                t.selected = ri;
            };
        } else t.selected = idx;
        try a.afterMove();
    }

    fn clickRow(a: *App, i: u32, right: bool) Allocator.Error!void {
        const t = a.tab();
        if (t.cfg.isTree()) {
            t.selected = i;
            try a.afterMove();
            if (right) try a.treeActivate();
            return;
        }
        t.selected = i;
        try a.afterMove();
        if (right) try a.toggleSelection();
    }

    fn clickChevron(a: *App, i: u32) Allocator.Error!void {
        const t = a.tab();
        if (!t.cfg.isTree()) return;
        t.selected = i;
        try a.treeActivate();
    }

    fn clickPrButton(a: *App, row: u32, which: hit.PrButton) Allocator.Error!void {
        const t = a.tab();
        t.selected = row;
        var scratch = std.heap.ArenaAllocator.init(a.gpa);
        defer scratch.deinit();
        const r = (try a.focusedRow(scratch.allocator())) orelse return;
        const p = switch (r) {
            .pr => |p| p,
            else => return,
        };
        const key = t.issues[p.issue_idx].key;
        const prs = t.tree.?.prs(key) orelse return;
        if (p.pr_idx >= prs.len) return;
        switch (which) {
            .review => try a.dispatchReview(),
            .open => if (prs[p.pr_idx].url.len > 0) try a.openUrl(prs[p.pr_idx].url),
            .merge => a.say("merge: use the Bitbucket pane (m) — this pane opens the PR", .{}),
        }
    }

    pub fn clickChip(a: *App, c: hit.Chip) Allocator.Error!void {
        switch (c) {
            .refresh => try a.act(.refresh, "r"),
            .help => try a.act(.help, "?"),
            .basic => {
                a.tab().show_jql = false;
                if (a.jql != null) try a.closeJql(false);
            },
            .jql => try a.openJql(),
            .search => try a.openFilter(),
            .space => a.setStatus("Space: the tab's project is {s}", .{if (a.tab().cfg.project.len > 0) a.tab().cfg.project else "unset"}),
            .assignee, .overflow => try a.openAssignees(),
            .type => try a.openIssueType(),
            .status => try a.cycleScope(),
            .more_filters => a.setStatus("More filters: not in the reference either", .{}),
            .save_filter => a.setStatus("Save filter: not in the reference either", .{}),
            .fixv_pill, .version => try a.openTabFixVersion(),
            .fixv_remove => try a.removeFixVersionClause(),
            .board => try a.openBoard(),
            .sprint => try a.openSprint(),
            .epic => try a.openEpic(),
            .label => try a.openLabel(),
            .quick_filters => try a.openQuickFilters(),
            .unassigned => try a.toggleAssignee(model.unassigned_sentinel),
            .settings => try a.openBoardSettings(),
        }
    }

    /// A wheel notch; positive is up.
    pub fn wheel(a: *App, col: u16, row: u16, dy: i16) Allocator.Error!void {
        const steps: i32 = if (dy > 0) -3 else 3;
        if (a.modal != null) {
            a.modalScroll(steps);
            return;
        }
        if (a.help) {
            if (steps > 0) a.help_scroll += 3 else a.help_scroll -|= 3;
            return;
        }
        switch (a.hits.at(col, row) orelse hit.Target.help_body) {
            .column => |c| a.scrollColumn(c, steps),
            .detail => {
                if (steps > 0) a.details_scroll +|= 3 else a.details_scroll -|= 3;
            },
            .picker_row, .picker_body => if (a.picker) |*p| try p.move(steps) else if (a.transition) |*t| t.move(steps),
            else => try a.move(steps),
        }
    }

    /// The JQL editor's wrap width, shared with the painter.
    pub fn jqlWrapWidth(a: *const App) usize {
        const w: usize = @max(@min(a.cols -| 8, 200), 20);
        return @max(w -| 2, 1);
    }
};

/// The reference's `strip_fix_version`: drop `fixVersion = "…"` and the
/// connector beside it.
pub fn stripFixVersion(arena: Allocator, jql: []const u8) Allocator.Error![]const u8 {
    var lower: [4096]u8 = undefined;
    const n = @min(jql.len, lower.len);
    for (jql[0..n], 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const start = std.mem.indexOf(u8, lower[0..n], "fixversion") orelse return jql;
    const after = jql[start + "fixversion".len ..];
    const eq = std.mem.indexOfScalar(u8, after, '=') orelse return jql;
    const after_eq = after[eq + 1 ..];
    const q1 = std.mem.indexOfScalar(u8, after_eq, '"') orelse return jql;
    const rest = after_eq[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse return jql;
    const clause_end = start + "fixversion".len + eq + 1 + q1 + 1 + q2 + 1;
    var before = std.mem.trimEnd(u8, jql[0..start], " ");
    var tail = std.mem.trimStart(u8, jql[clause_end..], " ");
    if (std.ascii.endsWithIgnoreCase(before, " and") or std.ascii.endsWithIgnoreCase(before, " or")) {
        before = std.mem.trimEnd(u8, before[0..std.mem.lastIndexOfScalar(u8, before, ' ').?], " ");
    } else if (std.ascii.startsWithIgnoreCase(tail, "and ") or std.ascii.startsWithIgnoreCase(tail, "or ")) {
        tail = std.mem.trimStart(u8, tail[std.mem.indexOfScalar(u8, tail, ' ').?..], " ");
    }
    if (before.len == 0) return tail;
    if (tail.len == 0) return before;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ before, tail });
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const auth = @import("auth.zig");

test "stripFixVersion drops the clause and its connector" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("project = TE ORDER BY rank", try stripFixVersion(a.allocator(), "project = TE AND fixVersion = \"13.19.0\" ORDER BY rank"));
    try testing.expectEqualStrings("ORDER BY rank", try stripFixVersion(a.allocator(), "fixVersion = \"1\" AND ORDER BY rank"));
    try testing.expectEqualStrings("a = 1", try stripFixVersion(a.allocator(), "a = 1"));
}

/// A pane against the fake server behind a real socket.
pub const Harness = struct {
    lb: jira.Loopback,
    store: *jira.fake.Store,
    server: *Io.net.Server,
    group: Io.Group = .init,
    client: *jira.Client,
    app: App,
    base: []const u8,

    pub fn start(cfg_in: config.Config, family: ?config.Family) !*Harness {
        const io = testing.io;
        const h = try testing.allocator.create(Harness);
        errdefer testing.allocator.destroy(h);
        h.store = try testing.allocator.create(jira.fake.Store);
        h.store.* = try jira.fake.Store.init(testing.allocator);
        h.server = try testing.allocator.create(Io.net.Server);
        var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        h.server.* = try addr.listen(io, .{ .reuse_address = true });
        h.lb = .{ .store = h.store, .server = h.server };
        h.group = .init;
        try h.group.concurrent(io, jira.Loopback.serve, .{ io, &h.lb });
        h.base = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{h.server.socket.address.getPort()});
        const authorization = try auth.basicHeader(testing.allocator, "fake@acme.com", "fake-token");
        defer testing.allocator.free(authorization);
        h.client = try testing.allocator.create(jira.Client);
        h.client.* = jira.Client.init(testing.allocator, io, h.base, try testing.allocator.dupe(u8, authorization), .v3);
        var cfg = cfg_in;
        cfg.jira_url = h.base;
        cfg.email = "fake@acme.com";
        cfg.refresh_interval_secs = 0;
        cfg.bitbucket_api_url = h.base;
        h.app = try App.init(testing.allocator, io, cfg, family, h.client, .{ .gpa = testing.allocator, .io = io, .base_url = h.base, .token = "fake-forge" });
        h.app.resize(120, 40);
        return h;
    }

    pub fn stop(h: *Harness) void {
        var scratch = std.heap.ArenaAllocator.init(testing.allocator);
        h.lb.finish(h.client, scratch.allocator()) catch {};
        scratch.deinit();
        h.group.await(testing.io) catch {};
        h.app.deinit();
        testing.allocator.free(h.client.authorization);
        testing.allocator.destroy(h.client);
        h.server.deinit(testing.io);
        testing.allocator.destroy(h.server);
        h.store.deinit();
        testing.allocator.destroy(h.store);
        testing.allocator.free(h.base);
        testing.allocator.destroy(h);
    }
};

pub const work_tabs = [_]config.Tab{
    .{ .name = "Assigned", .kind = .work_assigned },
    .{ .name = "Recently Done", .kind = .work_recently_done },
};

pub const fixv_tabs = [_]config.Tab{
    .{ .name = "Current Release", .kind = .fix_version_tree, .project = "ENG", .mode = .current_release, .status_order = &.{ "Testing", "In PR Review", "In Progress", "To Do", "Done" }, .bumps = .{ .pr_approved = "Testing", .no_open_prs = "Testing", .release_cut = &.{.{ .status = "Done", .target = "top" }} } },
};

pub const board_tabs = [_]config.Tab{
    .{ .name = "Sprint", .kind = .board_active_sprint, .project = "ENG", .board_id = 7 },
    .{ .name = "Backlog", .kind = .board_backlog, .project = "ENG" },
};

test "Work: the assigned tab loads the three tickets, auto-expands them with their PRs, and the tree keys fold and move" {
    const h = try Harness.start(.{ .tabs = &work_tabs, .team_field_id = "customfield_10056" }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    try testing.expectEqual(@as(usize, 3), a.tab().issues.len);
    try testing.expectEqual(@as(?usize, 3), a.assigned_open);
    try testing.expect(a.segment_dirty);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try a.treeRows(arena.allocator())).?;
    // No bumps on the Work tabs: the default order puts In PR Review
    // first, ENG-2 auto-expanded with its two PRs under it.
    try testing.expectEqualStrings("In PR Review", r.rows[0].group.status);
    try testing.expect(!r.rows[1].ticket.bumped);
    try testing.expect(r.rows[2] == .pr and r.rows[3] == .pr);
    // The last auto-expanded ticket's PR count is the status, as in the reference.
    try testing.expect(std.mem.endsWith(u8, a.status.items, "linked PR(s)"));
    // The focused row starts on the first group; j reaches the ticket.
    _ = try a.onKey("j");
    try testing.expectEqualStrings("ENG-2", (try a.focusedKey(arena.allocator())).?);
    // h folds the ticket, l opens it again; the cursor stays on ENG-2.
    _ = try a.onKey("h");
    const folded = (try a.treeRows(arena.allocator())).?;
    try testing.expect(folded.rows[2] != .pr);
    _ = try a.onKey("l");
    try testing.expect((try a.treeRows(arena.allocator())).?.rows[2] == .pr);
    // A refetch keeps the cursor on the same ticket.
    _ = try a.onKey("r");
    try testing.expectEqualStrings("ENG-2", (try a.focusedKey(arena.allocator())).?);
    // Tab switches; the second tab loads on arrival.
    _ = try a.onKey("tab");
    try testing.expectEqual(@as(usize, 1), a.active);
    try testing.expectEqual(@as(usize, 1), a.tab().issues.len);
    try testing.expectEqualStrings("ENG-12", a.tab().issues[0].key);
    _ = try a.onKey("1");
    try testing.expectEqual(@as(usize, 0), a.active);
}

test "Work: the filter narrows the tree (unlike the reference), the scope chip cycles, and Esc unwinds without quitting early" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try a.onKey("/");
    try testing.expect(a.filter.?.editing);
    for ("voucher") |c| _ = try a.onKey(&[_]u8{c});
    _ = try a.onKey("enter");
    try testing.expect(!a.filter.?.editing);
    const r = (try a.treeRows(arena.allocator())).?;
    try testing.expectEqual(@as(usize, 1), r.ticket_count);
    try testing.expectEqualStrings("ENG-5", a.tab().issues[r.rows[1].ticket.issue_idx].key);
    _ = try a.onKey("esc");
    try testing.expect(a.filter == null);
    try testing.expect(!a.quit);
    try a.cycleScope();
    try testing.expectEqual(filters.Scope.unresolved, a.tab().scope);
    try a.cycleScope();
    try testing.expectEqual(@as(usize, 0), (try a.treeRows(arena.allocator())).?.ticket_count);
    try a.cycleScope();
    try testing.expectEqual(filters.Scope.all, a.tab().scope);
    _ = try a.onKey("d");
    try testing.expect(a.details_visible);
    _ = try a.onKey("esc");
    try testing.expect(!a.details_visible and !a.quit);
    _ = try a.onKey("esc");
    try testing.expect(a.quit);
}

test "Work: the transition picker moves a ticket; the bulk selection transitions by name and skips" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    _ = try a.onKey("j");
    _ = try a.onKey("t");
    try testing.expect(a.transition != null);
    try testing.expectEqual(@as(usize, 4), a.transition.?.transitions.?.len);
    _ = try a.onKey("esc");
    try testing.expect(a.transition == null);
    // Select ENG-2 and ENG-5 (S on a tree tab), then move both to Testing.
    _ = try a.onKey("shift+s");
    try testing.expect(a.isSelected("ENG-2"));
    try a.moveEnd();
    try a.moveHome();
    // Find ENG-5's row.
    const r = (try a.treeRows(arena.allocator())).?;
    a.tab().selected = tree.rowOfKey(r.rows, a.tab().issues, "ENG-5").?;
    _ = try a.onKey("shift+s");
    try testing.expectEqual(@as(usize, 2), a.selection.count());
    _ = try a.onKey("t");
    try testing.expectEqual(@as(usize, 2), a.transition.?.targets);
    // Jump to "Ready to test" (Testing) and commit.
    for (a.transition.?.transitions.?, 0..) |t, i| if (std.mem.eql(u8, t.to_name, "Testing")) a.transition.?.jump(i);
    _ = try a.onKey("enter");
    try testing.expect(a.transition == null);
    try testing.expectEqualStrings("Testing", h.store.find("ENG-2").?.status);
    try testing.expectEqualStrings("Testing", h.store.find("ENG-5").?.status);
    try testing.expectEqual(@as(usize, 0), a.selection.count());
    try testing.expect(std.mem.startsWith(u8, a.status.items, "2 ticket(s) → Testing"));
}

test "Work: the assignee picker assigns, the fixVersion picker sets, watching toggles, a comment posts" {
    const h = try Harness.start(.{ .tabs = &work_tabs }, .work);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    _ = try a.onKey("j");
    _ = try a.onKey("a");
    try testing.expectEqual(pickers.Kind.assignee, a.picker.?.kind);
    try testing.expectEqualStrings("— Unassign —", a.picker.?.items[0].label);
    for ("lin") |c| _ = try a.onKey(&[_]u8{c});
    _ = try a.onKey("enter");
    try testing.expect(a.picker == null);
    try testing.expectEqualStrings(jira.fake.account_lin, h.store.find("ENG-2").?.assignee);
    // ENG-2 is Lin's now, so the assigned tab dropped it; the cursor is
    // back on the first group and j lands on ENG-1.
    try testing.expectEqual(@as(usize, 2), a.tab().issues.len);
    _ = try a.onKey("j");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("ENG-1", (try a.focusedKey(arena.allocator())).?);
    _ = try a.onKey("f");
    try testing.expectEqual(pickers.Kind.fix_version, a.picker.?.kind);
    a.picker.?.selectId("13.17.0");
    _ = try a.onKey("enter");
    try testing.expectEqualStrings("13.17.0", h.store.find("ENG-1").?.fix_version);
    try testing.expectEqualStrings("ENG-1", (try a.focusedKey(arena.allocator())).?);
    // Watching toggles against the site's list.
    const before = h.store.find("ENG-1").?.watchers.items.len;
    try a.ensureDetail("ENG-1");
    const was = a.detailOf("ENG-1").?.watching;
    _ = try a.onKey("w");
    try testing.expectEqual(if (was) before - 1 else before + 1, h.store.find("ENG-1").?.watchers.items.len);
    try a.ensureDetail("ENG-1");
    try testing.expectEqual(!was, a.detailOf("ENG-1").?.watching);
    _ = try a.onKey("w");
    try testing.expectEqual(before, h.store.find("ENG-1").?.watchers.items.len);
    // A comment needs the detail pane.
    const comments = h.store.find("ENG-1").?.comments.items.len;
    _ = try a.onKey("c");
    try testing.expect(a.comment == null);
    _ = try a.onKey("d");
    _ = try a.onKey("c");
    try testing.expect(a.comment != null);
    for ("on it") |c| _ = try a.onKey(if (c == ' ') "space" else &[_]u8{c});
    // Enter is a newline; a second Enter on the empty line sends.
    _ = try a.onKey("enter");
    try testing.expect(a.comment != null);
    _ = try a.onKey("enter");
    try testing.expect(a.comment == null);
    try testing.expectEqual(comments + 1, h.store.find("ENG-1").?.comments.items.len);
    const d = a.detailOf("ENG-1").?;
    try testing.expect(std.mem.indexOf(u8, d.comments[d.comments.len - 1].body, "on it") != null);
}

test "Fix Versions: the release resolves to 13.16.0, status_order and bumps group the tree, f switches the release, F assigns" {
    const h = try Harness.start(.{ .tabs = &fixv_tabs }, .fix_versions);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    try testing.expectEqualStrings("project = ENG AND fixVersion = \"13.16.0\" ORDER BY rank", a.tab().jql);
    try testing.expectEqual(@as(usize, 8), a.tab().issues.len);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = (try a.treeRows(arena.allocator())).?;
    try testing.expectEqualStrings("Testing", r.rows[0].group.status);
    // ENG-6 (Testing) and ENG-2 (bumped from In PR Review) share the
    // group — the tree is not narrowed to "me" the way a flat tab is.
    try testing.expectEqual(@as(usize, 2), r.rows[0].group.count);
    try testing.expect(r.rows[1].ticket.bumped);
    try testing.expectEqual(@as(usize, 0), a.tab().active_assignees.count());
    _ = try a.onKey("f");
    try testing.expectEqual(pickers.Kind.tab_fix_version, a.picker.?.kind);
    a.picker.?.selectId("13.15.0");
    _ = try a.onKey("enter");
    try testing.expectEqualStrings("project = ENG AND fixVersion = \"13.15.0\" ORDER BY rank", a.tab().jql);
    try testing.expectEqual(@as(usize, 1), a.tab().issues.len);
    _ = try a.onKey("j");
    _ = try a.onKey("shift+f");
    try testing.expectEqual(pickers.Kind.fix_version, a.picker.?.kind);
    _ = try a.onKey("esc");
    // Dispatch on a fresh workspace: nothing to write into, and it says so.
    _ = try a.onKey("shift+i");
    try testing.expect(std.mem.indexOf(u8, a.status.items, "no dispatch channels") != null);
    // The release-cut flag bumps Done to the top.
    a.cfg.release_cut = true;
    a.picker = null;
    a.tab().jql = "project = ENG AND fixVersion = \"13.16.0\" ORDER BY rank";
    try a.refreshActive();
    const cut = (try a.treeRows(arena.allocator())).?;
    try testing.expectEqualStrings(tree.top_sentinel, cut.rows[0].group.status);
}

test "Boards: the sprint loads from the board, the cursor is a card, the pickers open, and the backlog is the second tab" {
    const h = try Harness.start(.{ .tabs = &board_tabs, .team_field_id = "customfield_10056" }, .boards);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    try testing.expectEqual(@as(usize, 9), a.tab().issues.len);
    // The reference seeds the assignee filter with me.
    try testing.expect(a.tab().active_assignees.contains(jira.fake.account_me));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 3), (try a.visibleIssues(arena.allocator())).len);
    try a.toggleAssignee(jira.fake.account_me);
    try testing.expectEqual(@as(usize, 9), (try a.visibleIssues(arena.allocator())).len);
    try testing.expectEqualStrings("Checkout board", try a.boardName(7));
    try testing.expect(a.tab().sprints != null);
    try testing.expectEqual(@as(usize, 5), a.tab().assignees.len);
    _ = try a.onKey("shift+.");
    try testing.expect(a.isCardExpanded("ENG-1"));
    try a.openSprint();
    try testing.expectEqual(pickers.Kind.sprint, a.picker.?.kind);
    try testing.expectEqualStrings("Sprint 4  [active]", a.picker.?.items[1].label);
    _ = try a.onKey("esc");
    try a.openEpic();
    try testing.expectEqual(pickers.Kind.epic, a.picker.?.kind);
    try testing.expectEqualStrings("ENG-1", a.picker.?.items[0].id);
    _ = try a.onKey("esc");
    try a.openQuickFilters();
    try testing.expectEqual(pickers.Kind.quick_filter, a.picker.?.kind);
    _ = try a.onKey("space");
    _ = try a.onKey("enter");
    try testing.expectEqual(@as(usize, 1), a.tab().active_quick_filters.items.len);
    try testing.expectEqual(@as(usize, 2), a.tab().issues.len);
    try a.openBoard();
    try testing.expectEqualStrings("Checkout board  [scrum]", a.picker.?.items[1].label);
    _ = try a.onKey("esc");
    _ = try a.onKey("shift+t");
    try testing.expectEqual(pickers.Kind.team, a.picker.?.kind);
    _ = try a.onKey("esc");
    _ = try a.onKey("shift+d");
    try testing.expect(a.modal != null and a.modal.?.data != null);
    _ = try a.onKey("esc");
    _ = try a.onKey("2");
    try testing.expectEqual(@as(usize, 2), a.tab().issues.len);
    try testing.expectEqualStrings("ENG-10", a.tab().issues[0].key);
}

test "the dispatch queue writes the reference's line into the configured workspace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(testing.io, &pbuf)];
    try tmp.dir.createDirPath(testing.io, ".claude");
    const h = try Harness.start(.{ .tabs = &fixv_tabs, .dispatch_workspace = root }, .fix_versions);
    defer h.stop();
    const a = &h.app;
    try a.ensureLoaded();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Row 1 is ENG-2 (bumped into Testing, still In PR Review): Review.
    _ = try a.onKey("j");
    _ = try a.onKey(".");
    try testing.expectEqual(pickers.Kind.action, a.picker.?.kind);
    try testing.expectEqualStrings("[ Review ]", a.picker.?.items[0].label);
    _ = try a.onKey("enter");
    try testing.expectEqualStrings("review → queue", a.status.items);
    // Row 2 is ENG-6 (Testing, a Task): Test.
    _ = try a.onKey("j");
    _ = try a.onKey("j");
    _ = try a.onKey("j");
    try testing.expectEqualStrings("ENG-6", (try a.focusedKey(arena.allocator())).?);
    _ = try a.onKey(".");
    _ = try a.onKey("enter");
    try testing.expectEqualStrings("test → queue", a.status.items);
    const q = try tmp.dir.readFileAlloc(testing.io, ".claude/queue.jsonl", arena.allocator(), .unlimited);
    try testing.expect(std.mem.indexOf(u8, q, "\"kind\":\"review\",\"issue_key\":\"ENG-2\"") != null);
    try testing.expect(std.mem.indexOf(u8, q, "\"kind\":\"test\",\"issue_key\":\"ENG-6\"") != null);
}
