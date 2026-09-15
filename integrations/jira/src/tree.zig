//! The ticket tree: a flat list of rows built from a flat list of
//! issues, plus the fold state that survives a refresh.
//!
//! **The shape.** `group_by = .hierarchy` (the default) builds Jira's
//! own hierarchy — epic → story → sub-task — out of `parent`, and hangs
//! each ticket's pull requests under it as leaves:
//!
//!     ▼ ENG-1   Checkout rewrite
//!       ▼ ENG-2   Card form validates on blur
//!           ENG-4   Wire the blur handler
//!           MERGED  checkout #2023  feat/blur → main (2✓)
//!         ENG-3   Apple Pay button on the basket
//!       ENG-5   Basket total wrong with a voucher
//!
//! `group_by = .status` buckets by workflow status instead, in the tab's
//! `status_order` and then alphabetically — the Rust tracker's shape,
//! kept because a release tab reads better that way.
//!
//! **Fold state is keyed by name, never by index** (`collapsed`,
//! `hidden`, `pr_shown`), so a refresh that reorders or drops rows
//! cannot scramble it. Nothing here persists: the state dies with the
//! pane, as the Rust tracker's does.
//!
//! **Nav** is the family convention: `→`/`l` expand, `←`/`h` collapse
//! (and from a leaf, jump to the parent), Enter / Space toggle, `E`/`C`
//! expand / collapse everything, `x` hides a row, `H` unhides. `x` hides
//! the **branch** — a ticket's children go with it, because a sub-task
//! left behind by a hidden story is a row with nowhere to sit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const jira = @import("jira.zig");
const config = @import("config.zig");

pub const Issue = model.Issue;
pub const PullRequest = jira.PullRequest;

pub const Row = union(enum) {
    /// A status bucket (`group_by = .status`) — never emitted by the
    /// hierarchy shape, which has real epics instead.
    group: Group,
    issue: IssueRow,
    /// A linked pull request under its ticket.
    pr: PrRow,
    /// The PRs for this ticket have not been fetched yet.
    pr_loading: usize,
    /// `Show all N pull requests` — the cap's escape hatch.
    pr_more: PrMore,

    pub const Group = struct { label: []const u8, count: usize, expanded: bool };
    pub const IssueRow = struct {
        index: usize,
        depth: u8,
        expanded: bool,
        /// Something would appear under it if it were open.
        has_children: bool,
    };
    pub const PrRow = struct { issue: usize, pr: usize, depth: u8 };
    pub const PrMore = struct { issue: usize, hidden: usize, depth: u8 };

    /// The issue a row belongs to, for the detail pane and every action.
    pub fn issueIndex(r: Row) ?usize {
        return switch (r) {
            .group => null,
            .issue => |i| i.index,
            .pr => |p| p.issue,
            .pr_loading => |i| i,
            .pr_more => |m| m.issue,
        };
    }

    pub fn depth(r: Row) u8 {
        return switch (r) {
            .group => 0,
            .issue => |i| i.depth,
            .pr => |p| p.depth,
            .pr_loading => 1,
            .pr_more => |m| m.depth,
        };
    }
};

/// A set of keys, which is all the fold state needs.
const KeySet = std.StringHashMapUnmanaged(void);

pub const State = struct {
    gpa: Allocator,
    /// Groups and issues the user closed. Absence means open, so a fresh
    /// tree is fully expanded — a release tab is unreadable otherwise.
    collapsed: KeySet = .empty,
    /// Rows `x` took out of the list. `H` empties it.
    hidden: KeySet = .empty,
    /// Tickets whose PR cap the user lifted.
    pr_shown: KeySet = .empty,
    /// `key` → the PRs Jira knows about. Absent means "not asked yet";
    /// present and empty means "asked, there are none", which is why the
    /// two cannot be one field.
    prs: std.StringHashMapUnmanaged([]const PullRequest) = .empty,
    /// Every key `build` saw, so `expandAll` has something to fill.
    seen: std.ArrayListUnmanaged([]const u8) = .empty,
    /// The strings the sets own.
    owned: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa, .owned = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(s: *State) void {
        s.collapsed.deinit(s.gpa);
        s.hidden.deinit(s.gpa);
        s.pr_shown.deinit(s.gpa);
        s.prs.deinit(s.gpa);
        s.seen.deinit(s.gpa);
        s.owned.deinit();
        s.* = undefined;
    }

    fn keep(s: *State, key: []const u8) Allocator.Error![]const u8 {
        return s.owned.allocator().dupe(u8, key);
    }

    pub fn isCollapsed(s: *const State, key: []const u8) bool {
        return s.collapsed.contains(key);
    }

    pub fn isHidden(s: *const State, key: []const u8) bool {
        return s.hidden.contains(key);
    }

    pub fn setCollapsed(s: *State, key: []const u8, yes: bool) Allocator.Error!void {
        if (yes) {
            try s.collapsed.put(s.gpa, try s.keep(key), {});
        } else {
            _ = s.collapsed.remove(key);
        }
    }

    pub fn toggle(s: *State, key: []const u8) Allocator.Error!void {
        try s.setCollapsed(key, !s.isCollapsed(key));
    }

    pub fn hide(s: *State, key: []const u8) Allocator.Error!void {
        try s.hidden.put(s.gpa, try s.keep(key), {});
    }

    /// `H` — everything comes back.
    pub fn unhideAll(s: *State) void {
        s.hidden.clearRetainingCapacity();
    }

    pub fn hiddenCount(s: *const State) usize {
        return s.hidden.count();
    }

    /// `C` — every key the last build saw is closed.
    pub fn collapseAll(s: *State) Allocator.Error!void {
        for (s.seen.items) |k| try s.collapsed.put(s.gpa, k, {});
    }

    /// `E` — nothing is closed.
    pub fn expandAll(s: *State) void {
        s.collapsed.clearRetainingCapacity();
    }

    pub fn setPrs(s: *State, key: []const u8, list: []const PullRequest) Allocator.Error!void {
        try s.prs.put(s.gpa, try s.keep(key), list);
    }

    pub fn prsOf(s: *const State, key: []const u8) ?[]const PullRequest {
        return s.prs.get(key);
    }

    pub fn showAllPrs(s: *State, key: []const u8) Allocator.Error!void {
        try s.pr_shown.put(s.gpa, try s.keep(key), {});
    }

    /// Everything a refresh should forget: the PR lists (they may have
    /// merged) but not the folds (the user chose those).
    pub fn forgetPrs(s: *State) void {
        s.prs.clearRetainingCapacity();
    }

    fn note(s: *State, key: []const u8) Allocator.Error!void {
        try s.seen.append(s.gpa, try s.keep(key));
    }
};

pub const Options = struct {
    group_by: config.GroupBy = .hierarchy,
    status_order: []const []const u8 = &.{},
    /// How many PRs a ticket shows before `Show all`.
    max_prs: u8 = 3,
    /// A case-insensitive substring the key or the summary must contain.
    filter: []const u8 = "",
};

/// The rows to paint. `arena` owns the slice; `state` is updated with
/// the keys this build saw (for `E` / `C`).
pub fn build(arena: Allocator, state: *State, issues: []const Issue, opts: Options) Allocator.Error![]const Row {
    state.seen.clearRetainingCapacity();
    var rows: std.ArrayListUnmanaged(Row) = .empty;

    // Which issues survive the filter. A parent is kept when a child
    // matches, so a filter never orphans a row it did keep.
    const keep = try arena.alloc(bool, issues.len);
    for (issues, 0..) |it, i| keep[i] = matches(it, opts.filter) and !state.isHidden(it.key);
    if (opts.filter.len > 0) {
        var again = true;
        while (again) {
            again = false;
            for (issues, 0..) |it, i| {
                if (!keep[i]) continue;
                if (it.parent_key.len == 0) continue;
                if (indexOfKey(issues, it.parent_key)) |p| {
                    if (!keep[p] and !state.isHidden(issues[p].key)) {
                        keep[p] = true;
                        again = true;
                    }
                }
            }
        }
    }

    switch (opts.group_by) {
        .hierarchy => {
            // A root is an issue whose parent is not in this result set.
            for (issues, 0..) |it, i| {
                if (!keep[i]) continue;
                if (it.parent_key.len > 0 and indexOfKey(issues, it.parent_key) != null) continue;
                try emitIssue(arena, &rows, state, issues, keep, i, 0, opts);
            }
        },
        .status => {
            var order: std.ArrayListUnmanaged([]const u8) = .empty;
            for (opts.status_order) |s| {
                if (!hasStatus(issues, keep, s)) continue;
                try order.append(arena, s);
            }
            // Whatever the order list did not name, alphabetically.
            var extra: std.ArrayListUnmanaged([]const u8) = .empty;
            for (issues, 0..) |it, i| {
                if (!keep[i]) continue;
                if (containsStr(order.items, it.status) or containsStr(extra.items, it.status)) continue;
                try extra.append(arena, it.status);
            }
            std.mem.sort([]const u8, extra.items, {}, lessStr);
            try order.appendSlice(arena, extra.items);

            for (order.items) |status| {
                var count: usize = 0;
                for (issues, 0..) |it, i| {
                    if (keep[i] and std.mem.eql(u8, it.status, status)) count += 1;
                }
                if (count == 0) continue;
                try state.note(status);
                const open = !state.isCollapsed(status);
                try rows.append(arena, .{ .group = .{ .label = status, .count = count, .expanded = open } });
                if (!open) continue;
                for (issues, 0..) |it, i| {
                    if (!keep[i] or !std.mem.eql(u8, it.status, status)) continue;
                    try emitIssue(arena, &rows, state, issues, keep, i, 1, opts);
                }
            }
        },
    }
    return rows.toOwnedSlice(arena);
}

fn emitIssue(
    arena: Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    state: *State,
    issues: []const Issue,
    keep: []const bool,
    index: usize,
    depth: u8,
    opts: Options,
) Allocator.Error!void {
    const it = issues[index];
    try state.note(it.key);
    const children = childCount(issues, keep, it.key, opts.group_by);
    const prs = state.prsOf(it.key);
    // A ticket with children, or with PRs we have (or have not yet
    // asked about), is worth a chevron.
    const pr_rows: usize = if (prs) |p| p.len else 0;
    const has_children = children > 0 or pr_rows > 0;
    const open = !state.isCollapsed(it.key);
    try rows.append(arena, .{ .issue = .{ .index = index, .depth = depth, .expanded = open, .has_children = has_children } });
    if (!open) return;

    if (opts.group_by == .hierarchy) {
        for (issues, 0..) |child, ci| {
            if (!keep[ci]) continue;
            if (!std.mem.eql(u8, child.parent_key, it.key)) continue;
            try emitIssue(arena, rows, state, issues, keep, ci, depth + 1, opts);
        }
    }

    if (prs) |list| {
        const all = state.pr_shown.contains(it.key);
        const cap: usize = if (all) list.len else @min(list.len, opts.max_prs);
        // The newest are the ones worth seeing; the cap takes the tail.
        const start = list.len - cap;
        var n = start;
        while (n < list.len) : (n += 1) try rows.append(arena, .{ .pr = .{ .issue = index, .pr = n, .depth = depth + 1 } });
        if (start > 0) try rows.append(arena, .{ .pr_more = .{ .issue = index, .hidden = start, .depth = depth + 1 } });
    }
}

fn childCount(issues: []const Issue, keep: []const bool, key: []const u8, group_by: config.GroupBy) usize {
    if (group_by != .hierarchy) return 0;
    var n: usize = 0;
    for (issues, 0..) |it, i| {
        if (keep[i] and std.mem.eql(u8, it.parent_key, key)) n += 1;
    }
    return n;
}

fn indexOfKey(issues: []const Issue, key: []const u8) ?usize {
    for (issues, 0..) |it, i| if (std.mem.eql(u8, it.key, key)) return i;
    return null;
}

fn hasStatus(issues: []const Issue, keep: []const bool, status: []const u8) bool {
    for (issues, 0..) |it, i| if (keep[i] and std.mem.eql(u8, it.status, status)) return true;
    return false;
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn matches(i: Issue, filter: []const u8) bool {
    if (filter.len == 0) return true;
    const t = @import("text.zig");
    return t.containsIgnoreCase(i.key, filter) or t.containsIgnoreCase(i.summary, filter) or
        t.containsIgnoreCase(i.assignee, filter) or t.containsIgnoreCase(i.status, filter);
}

// ─── navigation ──────────────────────────────────────────────────────────

pub const Move = enum { expand, collapse, toggle };

/// What `→` / `←` / Enter do to the row at `cursor`. Returns the row the
/// cursor should end on — `←` on a leaf climbs to its parent rather than
/// doing nothing, which is the one thing that makes a deep tree usable.
pub fn navigate(state: *State, rows: []const Row, issues: []const Issue, cursor: usize, move: Move) Allocator.Error!usize {
    if (rows.len == 0) return 0;
    const at = @min(cursor, rows.len - 1);
    const key: []const u8 = switch (rows[at]) {
        .group => |g| g.label,
        .issue => |i| issues[i.index].key,
        // A PR row is a leaf: the keys act on the ticket above it.
        .pr, .pr_loading, .pr_more => return parentRow(rows, at) orelse at,
    };
    const foldable = switch (rows[at]) {
        .group => |g| g.count > 0,
        .issue => |i| i.has_children,
        else => false,
    };
    switch (move) {
        .expand => {
            if (!foldable) return at;
            try state.setCollapsed(key, false);
        },
        .collapse => {
            if (!foldable or state.isCollapsed(key)) return parentRow(rows, at) orelse at;
            try state.setCollapsed(key, true);
        },
        .toggle => {
            if (!foldable) return at;
            try state.toggle(key);
        },
    }
    return at;
}

/// The row above `at` at a shallower depth.
pub fn parentRow(rows: []const Row, at: usize) ?usize {
    if (at == 0) return null;
    const d = rows[at].depth();
    if (d == 0) return null;
    var i = at;
    while (i > 0) {
        i -= 1;
        if (rows[i].depth() < d) return i;
    }
    return null;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn fixture() [5]Issue {
    return .{
        .{ .key = "ENG-1", .summary = "Checkout rewrite", .level = .epic, .status = "In Progress", .category = .indeterminate, .assignee = "Ada" },
        .{ .key = "ENG-2", .summary = "Card form validates on blur", .level = .story, .status = "In Review", .category = .indeterminate, .parent_key = "ENG-1", .assignee = "Ada" },
        .{ .key = "ENG-3", .summary = "Apple Pay button", .level = .story, .status = "To Do", .category = .new, .parent_key = "ENG-1" },
        .{ .key = "ENG-4", .summary = "Wire the blur handler", .level = .subtask, .status = "Done", .category = .done, .parent_key = "ENG-2", .assignee = "Sam" },
        .{ .key = "ENG-5", .summary = "Basket total wrong", .level = .story, .status = "To Do", .category = .new, .assignee = "Ada" },
    };
}

fn keysOf(arena: Allocator, rows: []const Row, issues: []const Issue) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (rows) |r| switch (r) {
        .group => |g| try out.writer.print("[{s} {d}] ", .{ g.label, g.count }),
        .issue => |i| try out.writer.print("{d}:{s} ", .{ i.depth, issues[i.index].key }),
        .pr => |p| try out.writer.print("{d}:pr{d} ", .{ p.depth, p.pr }),
        .pr_loading => try out.writer.writeAll("pr? "),
        .pr_more => |m| try out.writer.print("+{d} ", .{m.hidden}),
    };
    return std.mem.trimEnd(u8, out.written(), " ");
}

test "hierarchy: epic over stories over a sub-task, with an unparented ticket at the top level" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = fixture();
    const rows = try build(arena, &st, &issues, .{});
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 2:ENG-4 1:ENG-3 0:ENG-5", try keysOf(arena, rows, &issues));
    try testing.expect(rows[0].issue.has_children);
    try testing.expect(rows[1].issue.has_children);
    try testing.expect(!rows[2].issue.has_children);
    try testing.expectEqual(@as(?usize, 1), rows[1].issueIndex());
}

test "an orphan whose epic is not in the result set is a root, not a lost row" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    // ENG-2 says its parent is ENG-1, but the search did not return it.
    const issues = [_]Issue{
        .{ .key = "ENG-2", .summary = "s", .parent_key = "ENG-1" },
        .{ .key = "ENG-4", .summary = "t", .parent_key = "ENG-2" },
    };
    const rows = try build(arena, &st, &issues, .{});
    try testing.expectEqualStrings("0:ENG-2 1:ENG-4", try keysOf(arena, rows, &issues));
}

test "collapsing a key hides its subtree, and the state is keyed by name so a refresh keeps it" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = fixture();
    try st.setCollapsed("ENG-2", true);
    const rows = try build(arena, &st, &issues, .{});
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 1:ENG-3 0:ENG-5", try keysOf(arena, rows, &issues));
    try testing.expect(!rows[1].issue.expanded);
    // The same tree in a different order still folds ENG-2.
    const reordered = [_]Issue{ issues[4], issues[0], issues[2], issues[1], issues[3] };
    const again = try build(arena, &st, &reordered, .{});
    try testing.expectEqualStrings("0:ENG-5 0:ENG-1 1:ENG-3 1:ENG-2", try keysOf(arena, again, &reordered));
    // Collapsing the epic takes the whole subtree with it.
    try st.setCollapsed("ENG-1", true);
    const folded = try build(arena, &st, &issues, .{});
    try testing.expectEqualStrings("0:ENG-1 0:ENG-5", try keysOf(arena, folded, &issues));
}

test "E and C reach every key the last build saw" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = fixture();
    _ = try build(arena, &st, &issues, .{});
    try st.collapseAll();
    const folded = try build(arena, &st, &issues, .{});
    try testing.expectEqualStrings("0:ENG-1 0:ENG-5", try keysOf(arena, folded, &issues));
    st.expandAll();
    const open = try build(arena, &st, &issues, .{});
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 2:ENG-4 1:ENG-3 0:ENG-5", try keysOf(arena, open, &issues));
}

test "x hides a row (and its subtree), H brings everything back" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = fixture();
    try st.hide("ENG-2");
    const rows = try build(arena, &st, &issues, .{});
    // `x` hides the branch, not just the row: ENG-4 hangs off ENG-2 and
    // goes with it. `H` is the way back, and the header says how many.
    try testing.expectEqualStrings("0:ENG-1 1:ENG-3 0:ENG-5", try keysOf(arena, rows, &issues));
    try testing.expectEqual(@as(usize, 1), st.hiddenCount());
    st.unhideAll();
    try testing.expectEqual(@as(usize, 0), st.hiddenCount());
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 2:ENG-4 1:ENG-3 0:ENG-5", try keysOf(arena, try build(arena, &st, &issues, .{}), &issues));
}

test "the filter keeps a matching row's ancestors, so nothing is orphaned by it" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = fixture();
    // Only ENG-4 matches, but its story and its epic come with it.
    const rows = try build(arena, &st, &issues, .{ .filter = "blur handler" });
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 2:ENG-4", try keysOf(arena, rows, &issues));
    // The filter reads the key, the summary, the assignee and the status.
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 2:ENG-4", try keysOf(arena, try build(arena, &st, &issues, .{ .filter = "eng-4" }), &issues));
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 2:ENG-4", try keysOf(arena, try build(arena, &st, &issues, .{ .filter = "sam" }), &issues));
    // Nothing matching is no rows, not every row.
    try testing.expectEqual(@as(usize, 0), (try build(arena, &st, &issues, .{ .filter = "zzz" })).len);
}

test "status grouping follows status_order, then whatever is left alphabetically" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = fixture();
    const rows = try build(arena, &st, &issues, .{
        .group_by = .status,
        .status_order = &.{ "To Do", "In Progress" },
    });
    // The two named buckets first, in their order; then `Done` and
    // `In Review` alphabetically. Every ticket is depth 1 under its head.
    try testing.expectEqualStrings(
        "[To Do 2] 1:ENG-3 1:ENG-5 [In Progress 1] 1:ENG-1 [Done 1] 1:ENG-4 [In Review 1] 1:ENG-2",
        try keysOf(arena, rows, &issues),
    );
    // A group folds by its own name.
    try st.setCollapsed("To Do", true);
    const folded = try build(arena, &st, &issues, .{ .group_by = .status, .status_order = &.{ "To Do", "In Progress" } });
    try testing.expectEqualStrings(
        "[To Do 2] [In Progress 1] 1:ENG-1 [Done 1] 1:ENG-4 [In Review 1] 1:ENG-2",
        try keysOf(arena, folded, &issues),
    );
    // A status in the order list with no tickets emits nothing.
    const sparse = try build(arena, &st, &issues, .{ .group_by = .status, .status_order = &.{"Blocked"} });
    try testing.expect(std.mem.indexOf(u8, try keysOf(arena, sparse, &issues), "Blocked") == null);
}

test "PR rows hang under their ticket, capped, with Show-all lifting the cap" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = fixture();
    const prs = [_]PullRequest{
        .{ .id = "#1", .title = "a", .status = "MERGED", .url = "", .repo = "r", .source_branch = "", .dest_branch = "", .approvals = 1 },
        .{ .id = "#2", .title = "b", .status = "MERGED", .url = "", .repo = "r", .source_branch = "", .dest_branch = "", .approvals = 0 },
        .{ .id = "#3", .title = "c", .status = "OPEN", .url = "", .repo = "r", .source_branch = "", .dest_branch = "", .approvals = 0 },
        .{ .id = "#4", .title = "d", .status = "OPEN", .url = "", .repo = "r", .source_branch = "", .dest_branch = "", .approvals = 0 },
    };
    try st.setPrs("ENG-2", &prs);
    const rows = try build(arena, &st, &issues, .{ .max_prs = 2 });
    // The two newest, then the escape hatch for the one hidden pair.
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 2:ENG-4 2:pr2 2:pr3 +2 1:ENG-3 0:ENG-5", try keysOf(arena, rows, &issues));
    try st.showAllPrs("ENG-2");
    const all = try build(arena, &st, &issues, .{ .max_prs = 2 });
    try testing.expectEqualStrings("0:ENG-1 1:ENG-2 2:ENG-4 2:pr0 2:pr1 2:pr2 2:pr3 1:ENG-3 0:ENG-5", try keysOf(arena, all, &issues));
    // A ticket asked about with no PRs shows none and loses its chevron.
    try st.setPrs("ENG-5", &.{});
    const none = try build(arena, &st, &issues, .{ .max_prs = 2 });
    try testing.expect(!none[none.len - 1].issue.has_children);
    // A refresh forgets the PRs but keeps the folds.
    try st.setCollapsed("ENG-1", true);
    st.forgetPrs();
    try testing.expect(st.prsOf("ENG-2") == null);
    try testing.expect(st.isCollapsed("ENG-1"));
}

test "navigation: right opens, left closes then climbs, Enter toggles, a PR row acts on its ticket" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = fixture();
    var rows = try build(arena, &st, &issues, .{});
    // ENG-2 is row 1 and open: left closes it in place.
    try testing.expectEqual(@as(usize, 1), try navigate(&st, rows, &issues, 1, .collapse));
    try testing.expect(st.isCollapsed("ENG-2"));
    rows = try build(arena, &st, &issues, .{});
    // Left again on a closed row climbs to the epic.
    try testing.expectEqual(@as(usize, 0), try navigate(&st, rows, &issues, 1, .collapse));
    // Right opens it again.
    _ = try navigate(&st, rows, &issues, 1, .expand);
    try testing.expect(!st.isCollapsed("ENG-2"));
    rows = try build(arena, &st, &issues, .{});
    // Enter on the leaf sub-task does nothing at all, and stays put.
    try testing.expectEqual(@as(usize, 2), try navigate(&st, rows, &issues, 2, .toggle));
    try testing.expect(!st.isCollapsed("ENG-4"));
    // Left at the top level has nowhere to climb.
    try testing.expectEqual(@as(usize, 0), try navigate(&st, rows, &issues, 0, .collapse));
    // A PR row's keys land on the ticket above it.
    const prs = [_]PullRequest{.{ .id = "#1", .title = "a", .status = "OPEN", .url = "", .repo = "r", .source_branch = "", .dest_branch = "", .approvals = 0 }};
    try st.setPrs("ENG-2", &prs);
    rows = try build(arena, &st, &issues, .{});
    // …ENG-1(0) ENG-2(1) ENG-4(2) pr(3)…
    try testing.expectEqual(@as(usize, 1), try navigate(&st, rows, &issues, 3, .collapse));
    // An empty tree does not index into nothing.
    try testing.expectEqual(@as(usize, 0), try navigate(&st, &.{}, &issues, 7, .toggle));
}

test "parentRow walks up by depth, and stops at the top" {
    const rows = [_]Row{
        .{ .issue = .{ .index = 0, .depth = 0, .expanded = true, .has_children = true } },
        .{ .issue = .{ .index = 1, .depth = 1, .expanded = true, .has_children = true } },
        .{ .issue = .{ .index = 2, .depth = 2, .expanded = true, .has_children = false } },
        .{ .pr = .{ .issue = 1, .pr = 0, .depth = 2 } },
    };
    try testing.expectEqual(@as(?usize, 1), parentRow(&rows, 2));
    try testing.expectEqual(@as(?usize, 1), parentRow(&rows, 3));
    try testing.expectEqual(@as(?usize, 0), parentRow(&rows, 1));
    try testing.expect(parentRow(&rows, 0) == null);
}
