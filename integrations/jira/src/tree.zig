//! The status-grouped tree — the reference's `tree.rs` as pure
//! functions: tickets bucketed by their effective status (a bump rule
//! may promote one), the groups in the tab's `status_order` with the
//! rest alphabetical, each ticket expandable to its linked PRs (capped,
//! with a show-all row), each merged PR expandable to its post-merge
//! pipelines. `State` is what the user opened and what has been
//! fetched; `computeRows` turns it into the row list the cursor walks.
//!
//! One deliberate difference from the reference: `computeRows` takes a
//! `visible` mask, so the text / assignee / scope filters actually
//! narrow the tree (in the reference they only ever narrowed the
//! kanban), and a group left with nothing is dropped rather than
//! painted as `Done (0)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const model = @import("model.zig");
const sdk = @import("mnml_sdk");

const Issue = model.Issue;
const LinkedPr = model.LinkedPr;
const Pipeline = model.Pipeline;

/// A `release_cut` rule's `top`: before every other group.
pub const top_sentinel = "__TOP__";
/// PRs shown under a ticket before the show-all row.
pub const pr_cap: usize = 3;

pub const State = struct {
    gpa: Allocator,
    /// Owns every key and every cached slice.
    owned: std.heap.ArenaAllocator,
    collapsed_groups: std.StringHashMapUnmanaged(void) = .empty,
    expanded_tickets: std.StringHashMapUnmanaged(void) = .empty,
    /// `KEY\x00#id`.
    expanded_prs: std.StringHashMapUnmanaged(void) = .empty,
    show_all: std.StringHashMapUnmanaged(void) = .empty,
    pr_cache: std.StringHashMapUnmanaged([]const LinkedPr) = .empty,
    pipeline_cache: std.StringHashMapUnmanaged([]const Pipeline) = .empty,
    pipeline_errors: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The pull request's `updated_on` when its runs were read, and the
    /// commit they ran on. The stamp is the cache key: while it has not
    /// moved, the pipelines list need not be asked for again.
    pipeline_meta: std.StringHashMapUnmanaged(PipelineMeta) = .empty,
    /// May each pull request merge, and the `updated_on` it was true
    /// at. One cached look per PR, exactly like the runs above.
    readiness: std.StringHashMapUnmanaged(ReadinessEntry) = .empty,
    /// The created-date window the tab's query carries, in days, or
    /// null on a tab that has none — every tab but Reported by me. 0 is
    /// the last step: widened out to all time. Runtime only; a restart
    /// opens the tab back on its configured window.
    window_days: ?u16 = null,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa, .owned = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(s: *State) void {
        s.collapsed_groups.deinit(s.gpa);
        s.expanded_tickets.deinit(s.gpa);
        s.expanded_prs.deinit(s.gpa);
        s.show_all.deinit(s.gpa);
        s.pr_cache.deinit(s.gpa);
        s.pipeline_cache.deinit(s.gpa);
        s.pipeline_errors.deinit(s.gpa);
        s.pipeline_meta.deinit(s.gpa);
        s.readiness.deinit(s.gpa);
        s.owned.deinit();
        s.* = undefined;
    }

    fn keep(s: *State, bytes: []const u8) Allocator.Error![]const u8 {
        return s.owned.allocator().dupe(u8, bytes);
    }

    pub fn arena(s: *State) Allocator {
        return s.owned.allocator();
    }

    pub fn prKey(s: *State, issue_key: []const u8, pr_id: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(s.owned.allocator(), "{s}\x00{s}", .{ issue_key, pr_id });
    }

    pub fn isCollapsed(s: *const State, status: []const u8) bool {
        return s.collapsed_groups.contains(status);
    }

    pub fn toggleGroup(s: *State, status: []const u8) Allocator.Error!void {
        if (s.collapsed_groups.remove(status)) return;
        try s.collapsed_groups.put(s.gpa, try s.keep(status), {});
    }

    pub fn setGroup(s: *State, status: []const u8, collapsed: bool) Allocator.Error!void {
        if (collapsed) {
            if (!s.collapsed_groups.contains(status)) try s.collapsed_groups.put(s.gpa, try s.keep(status), {});
        } else _ = s.collapsed_groups.remove(status);
    }

    pub fn isExpanded(s: *const State, key: []const u8) bool {
        return s.expanded_tickets.contains(key);
    }

    pub fn setExpanded(s: *State, key: []const u8, on: bool) Allocator.Error!void {
        if (on) {
            if (!s.expanded_tickets.contains(key)) try s.expanded_tickets.put(s.gpa, try s.keep(key), {});
        } else _ = s.expanded_tickets.remove(key);
    }

    pub fn isPrExpanded(s: *State, issue_key: []const u8, pr_id: []const u8) bool {
        var buf: [256]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ issue_key, pr_id }) catch return false;
        return s.expanded_prs.contains(k);
    }

    pub fn setPrExpanded(s: *State, issue_key: []const u8, pr_id: []const u8, on: bool) Allocator.Error!void {
        const k = try s.prKey(issue_key, pr_id);
        if (on) {
            if (!s.expanded_prs.contains(k)) try s.expanded_prs.put(s.gpa, k, {});
        } else _ = s.expanded_prs.remove(k);
    }

    pub fn showAll(s: *State, key: []const u8) Allocator.Error!void {
        if (!s.show_all.contains(key)) try s.show_all.put(s.gpa, try s.keep(key), {});
    }

    /// The cached PRs of a ticket: null = not fetched yet.
    pub fn prs(s: *const State, key: []const u8) ?[]const LinkedPr {
        return s.pr_cache.get(key);
    }

    /// `list` is copied onto the state's arena.
    pub fn putPrs(s: *State, key: []const u8, list: []const LinkedPr) Allocator.Error!void {
        const a = s.owned.allocator();
        const copy = try a.alloc(LinkedPr, list.len);
        for (list, copy) |src, *dst| {
            const rs = try a.alloc(model.Reviewer, src.reviewers.len);
            for (src.reviewers, rs) |r, *d| d.* = .{ .name = try a.dupe(u8, r.name), .approved = r.approved };
            dst.* = .{
                .id = try a.dupe(u8, src.id),
                .name = try a.dupe(u8, src.name),
                .status = try a.dupe(u8, src.status),
                .url = try a.dupe(u8, src.url),
                .repo = try a.dupe(u8, src.repo),
                .source_branch = try a.dupe(u8, src.source_branch),
                .dest_branch = try a.dupe(u8, src.dest_branch),
                .reviewers = rs,
            };
        }
        try s.pr_cache.put(s.gpa, try s.keep(key), copy);
    }

    pub fn dropPrs(s: *State, key: []const u8) void {
        _ = s.pr_cache.remove(key);
    }

    pub fn pipelines(s: *State, issue_key: []const u8, pr_id: []const u8) ?[]const Pipeline {
        var buf: [256]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ issue_key, pr_id }) catch return null;
        return s.pipeline_cache.get(k);
    }

    pub fn pipelineError(s: *State, issue_key: []const u8, pr_id: []const u8) ?[]const u8 {
        var buf: [256]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ issue_key, pr_id }) catch return null;
        return s.pipeline_errors.get(k);
    }

    pub fn putPipelines(s: *State, issue_key: []const u8, pr_id: []const u8, list: []const Pipeline) Allocator.Error!void {
        const a = s.owned.allocator();
        const copy = try a.alloc(Pipeline, list.len);
        for (list, copy) |src, *dst| dst.* = .{
            .uuid = try a.dupe(u8, src.uuid),
            .build_number = src.build_number,
            .state = try a.dupe(u8, src.state),
            .result = try a.dupe(u8, src.result),
            .branch = try a.dupe(u8, src.branch),
            .commit = try a.dupe(u8, src.commit),
            .created_on = try a.dupe(u8, src.created_on),
            .duration_secs = src.duration_secs,
        };
        try s.pipeline_cache.put(s.gpa, try s.prKey(issue_key, pr_id), copy);
    }

    pub fn putPipelineError(s: *State, issue_key: []const u8, pr_id: []const u8, message: []const u8) Allocator.Error!void {
        try s.pipeline_errors.put(s.gpa, try s.prKey(issue_key, pr_id), try s.keep(message));
    }

    pub fn readinessOf(s: *State, issue_key: []const u8, pr_id: []const u8) ?ReadinessEntry {
        var buf: [256]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ issue_key, pr_id }) catch return null;
        return s.readiness.get(k);
    }

    pub fn putReadiness(s: *State, issue_key: []const u8, pr_id: []const u8, e: ReadinessEntry) Allocator.Error!void {
        try s.readiness.put(s.gpa, try s.prKey(issue_key, pr_id), .{
            .updated_on = try s.keep(e.updated_on),
            .readiness = e.readiness,
        });
    }

    pub fn pipelineMeta(s: *State, issue_key: []const u8, pr_id: []const u8) ?PipelineMeta {
        var buf: [256]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ issue_key, pr_id }) catch return null;
        return s.pipeline_meta.get(k);
    }

    pub fn putPipelineMeta(s: *State, issue_key: []const u8, pr_id: []const u8, meta: PipelineMeta) Allocator.Error!void {
        try s.pipeline_meta.put(s.gpa, try s.prKey(issue_key, pr_id), .{
            .updated_on = try s.keep(meta.updated_on),
            .commit = try s.keep(meta.commit),
            .on_merge = meta.on_merge,
        });
    }
};

/// What one readiness look found, and the stamp it was true at.
pub const ReadinessEntry = struct { updated_on: []const u8, readiness: sdk.pane.merge.Readiness };

/// What the cached runs of one pull request are keyed by.
pub const PipelineMeta = struct {
    updated_on: []const u8 = "",
    commit: []const u8 = "",
    on_merge: bool = false,
};

/// A row under a PR: the ticket and the PR it hangs from.
pub const PrRef = struct { issue_idx: usize, pr_idx: usize };

pub const Row = union(enum) {
    group: struct { status: []const u8, count: usize, expanded: bool },
    ticket: struct { issue_idx: usize, effective_status: []const u8, bumped: bool },
    pr: PrRef,
    pr_loading: struct { issue_idx: usize },
    pipeline_loading: PrRef,
    pipeline_empty: PrRef,
    pipeline_error: PrRef,
    pipeline: struct { issue_idx: usize, pr_idx: usize, pipeline_idx: usize },
    show_more: struct { issue_idx: usize, hidden: usize },
    /// The tab's trailing row on a windowed listing: press it and the
    /// window widens one step. `window` is what the rows on screen
    /// came back under, `next` what pressing it asks for (0 = none).
    show_older: struct { window: u16, next: u16 },

    /// The ticket a row belongs to.
    pub fn issueIdx(r: Row) ?usize {
        return switch (r) {
            .group => null,
            .ticket => |t| t.issue_idx,
            .pr => |p| p.issue_idx,
            .pr_loading => |p| p.issue_idx,
            .pipeline_loading, .pipeline_empty, .pipeline_error => |p| p.issue_idx,
            .pipeline => |p| p.issue_idx,
            .show_more => |p| p.issue_idx,
            .show_older => null,
        };
    }

    /// The same row in a list rebuilt around it: the same kind, on the
    /// same ticket, PR and build (a group by its status). What the cursor
    /// holds on to when a ticket's rows change under it — an index would
    /// land on whatever moved into its place.
    pub fn same(r: Row, o: Row) bool {
        if (std.meta.activeTag(r) != std.meta.activeTag(o)) return false;
        return switch (r) {
            .group => |g| std.mem.eql(u8, g.status, o.group.status),
            .ticket => |x| x.issue_idx == o.ticket.issue_idx,
            .pr => |x| x.issue_idx == o.pr.issue_idx and x.pr_idx == o.pr.pr_idx,
            .pr_loading => |x| x.issue_idx == o.pr_loading.issue_idx,
            .pipeline_loading => |x| x.issue_idx == o.pipeline_loading.issue_idx and x.pr_idx == o.pipeline_loading.pr_idx,
            .pipeline_empty => |x| x.issue_idx == o.pipeline_empty.issue_idx and x.pr_idx == o.pipeline_empty.pr_idx,
            .pipeline_error => |x| x.issue_idx == o.pipeline_error.issue_idx and x.pr_idx == o.pipeline_error.pr_idx,
            .pipeline => |x| x.issue_idx == o.pipeline.issue_idx and x.pr_idx == o.pipeline.pr_idx and x.pipeline_idx == o.pipeline.pipeline_idx,
            .show_more => |x| x.issue_idx == o.show_more.issue_idx,
            .show_older => true,
        };
    }

    /// A row that hangs under a ticket (any PR-level row).
    pub fn isChild(r: Row) bool {
        return switch (r) {
            // The widen row hangs off the TAB, not a ticket: it is no
            // more a child than a group header is.
            .group, .ticket, .show_older => false,
            else => true,
        };
    }
};

pub const Rows = struct {
    rows: []const Row,
    /// Tickets on screen (after the mask).
    ticket_count: usize,
};

/// The PR-review statuses the bump rules consider.
pub fn isPrReviewStatus(status: []const u8) bool {
    const table = [_][]const u8{ "in pr review", "in code review", "code review", "pr review", "in review", "awaiting review" };
    for (table) |t| if (std.ascii.eqlIgnoreCase(status, t)) return true;
    return false;
}

/// The group a bump rule moves a ticket into, or null. In order: the
/// `release_cut` map when the global flag is on (its `top` is the
/// sentinel); `pr_approved` when a cached PR is approved; `no_open_prs`
/// when the PRs are cached, at least one exists and none is open. The
/// last two only see fetched PRs — an unexpanded ticket cannot bump.
pub fn applyBumps(iss: Issue, raw_status: []const u8, bumps: config.Bumps, state: *const State, release_cut: bool) ?[]const u8 {
    if (release_cut) {
        for (bumps.release_cut) |rule| if (std.mem.eql(u8, rule.status, raw_status)) {
            return if (std.mem.eql(u8, rule.target, "top")) top_sentinel else rule.target;
        };
    }
    if (!isPrReviewStatus(raw_status)) return null;
    const prs = state.prs(iss.key) orelse return null;
    if (bumps.pr_approved.len > 0) {
        for (prs) |p| if (p.isApproved()) return bumps.pr_approved;
    }
    if (bumps.no_open_prs.len > 0 and prs.len > 0) {
        var any_open = false;
        for (prs) |p| if (p.isOpen()) {
            any_open = true;
        };
        if (!any_open) return bumps.no_open_prs;
    }
    return null;
}

const Group = struct { status: []const u8, idxs: std.ArrayList(usize) };

/// The row list. `visible[i]` masks ticket `i` (a null mask shows all).
/// // changed (focus-row): the group a ticket sits in — its status, or
/// wherever a `bumps` rule moves it. Independent of what is collapsed,
/// which is the point: `--focus` has to name the section to open
/// BEFORE the ticket has a row to read it off.
pub const Placement = struct { status: []const u8, bumped: bool };

pub fn groupOf(iss: Issue, state: *const State, tab: config.Tab, release_cut: bool) Placement {
    const raw = if (iss.status.len > 0) iss.status else "Unknown";
    const bumped_to = if (tab.bumps) |b| applyBumps(iss, raw, b, state, release_cut) else null;
    return if (bumped_to) |g| .{ .status = g, .bumped = true } else .{ .status = raw, .bumped = false };
}

pub fn computeRows(arena: Allocator, issues: []const Issue, state: *State, tab: config.Tab, release_cut: bool, visible: ?[]const bool) Allocator.Error!Rows {
    const effective = try arena.alloc(Placement, issues.len);
    for (issues, 0..) |iss, i| effective[i] = groupOf(iss, state, tab, release_cut);

    var groups: std.ArrayList(Group) = .empty;
    var ticket_count: usize = 0;
    for (issues, 0..) |_, i| {
        if (visible) |m| if (!m[i]) continue;
        ticket_count += 1;
        const st = effective[i].status;
        var found: ?*Group = null;
        for (groups.items) |*g| if (std.mem.eql(u8, g.status, st)) {
            found = g;
            break;
        };
        if (found == null) {
            try groups.append(arena, .{ .status = st, .idxs = .empty });
            found = &groups.items[groups.items.len - 1];
        }
        try found.?.idxs.append(arena, i);
    }

    var out: std.ArrayList(Row) = .empty;
    const emitted = try arena.alloc(bool, groups.items.len);
    @memset(emitted, false);
    // The sentinel first, then the configured order, then the rest by name.
    for (groups.items, 0..) |g, gi| if (std.mem.eql(u8, g.status, top_sentinel)) {
        try emitGroup(arena, &out, g, issues, state);
        emitted[gi] = true;
    };
    for (tab.statusOrder()) |status| {
        for (groups.items, 0..) |g, gi| if (!emitted[gi] and std.mem.eql(u8, g.status, status)) {
            try emitGroup(arena, &out, g, issues, state);
            emitted[gi] = true;
        };
    }
    while (true) {
        var best: ?usize = null;
        for (groups.items, 0..) |g, gi| {
            if (emitted[gi]) continue;
            if (best == null or std.mem.order(u8, g.status, groups.items[best.?].status) == .lt) best = gi;
        }
        const gi = best orelse break;
        try emitGroup(arena, &out, groups.items[gi], issues, state);
        emitted[gi] = true;
    }
    // The effective status a ticket row carries is the group's.
    for (out.items) |*r| if (r.* == .ticket) {
        r.ticket.effective_status = effective[r.ticket.issue_idx].status;
        r.ticket.bumped = effective[r.ticket.issue_idx].bumped;
    };
    // The widen row, last, below every group — and emitted even on an
    // empty listing, because an empty two weeks is exactly when you
    // want the next step. It goes once the window is all time.
    if (state.window_days) |w| if (config.nextReportedWindow(w)) |next| {
        try out.append(arena, .{ .show_older = .{ .window = w, .next = next } });
    };
    return .{ .rows = try out.toOwnedSlice(arena), .ticket_count = ticket_count };
}

fn emitGroup(arena: Allocator, out: *std.ArrayList(Row), g: Group, issues: []const Issue, state: *State) Allocator.Error!void {
    const expanded = !state.isCollapsed(g.status);
    try out.append(arena, .{ .group = .{ .status = g.status, .count = g.idxs.items.len, .expanded = expanded } });
    if (!expanded) return;
    for (g.idxs.items) |i| {
        try out.append(arena, .{ .ticket = .{ .issue_idx = i, .effective_status = g.status, .bumped = false } });
        try emitTicketChildren(arena, out, i, issues[i], state);
    }
}

fn emitTicketChildren(arena: Allocator, out: *std.ArrayList(Row), issue_idx: usize, iss: Issue, state: *State) Allocator.Error!void {
    if (!state.isExpanded(iss.key)) return;
    const prs = state.prs(iss.key) orelse {
        try out.append(arena, .{ .pr_loading = .{ .issue_idx = issue_idx } });
        return;
    };
    if (prs.len == 0) return;
    const cap = if (state.show_all.contains(iss.key)) prs.len else pr_cap;
    // The newest PRs are at the end: show the tail, then the show-all row.
    const start = if (prs.len > cap) prs.len - cap else 0;
    var pr_idx = start;
    while (pr_idx < prs.len) : (pr_idx += 1) {
        try out.append(arena, .{ .pr = .{ .issue_idx = issue_idx, .pr_idx = pr_idx } });
        const pr = prs[pr_idx];
        if (!state.isPrExpanded(iss.key, pr.id)) continue;
        if (state.pipelineError(iss.key, pr.id) != null) {
            try out.append(arena, .{ .pipeline_error = .{ .issue_idx = issue_idx, .pr_idx = pr_idx } });
        } else if (state.pipelines(iss.key, pr.id)) |list| {
            if (list.len == 0) {
                try out.append(arena, .{ .pipeline_empty = .{ .issue_idx = issue_idx, .pr_idx = pr_idx } });
            } else for (list, 0..) |_, k| {
                try out.append(arena, .{ .pipeline = .{ .issue_idx = issue_idx, .pr_idx = pr_idx, .pipeline_idx = k } });
            }
        } else {
            try out.append(arena, .{ .pipeline_loading = .{ .issue_idx = issue_idx, .pr_idx = pr_idx } });
        }
    }
    if (prs.len > cap) try out.append(arena, .{ .show_more = .{ .issue_idx = issue_idx, .hidden = prs.len - cap } });
}

/// The ticket row for `key`, if it is on screen.
pub fn rowOfKey(rows: []const Row, issues: []const Issue, key: []const u8) ?usize {
    for (rows, 0..) |r, i| if (r == .ticket and std.mem.eql(u8, issues[r.ticket.issue_idx].key, key)) return i;
    return null;
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn issue(key: []const u8, status: []const u8) Issue {
    return .{ .key = key, .status = status, .summary = key };
}

fn fixTab() config.Tab {
    return .{ .name = "Current", .kind = .fix_version_tree, .project = "TE" };
}

const approved_reviewer = [_]model.Reviewer{.{ .name = "r", .approved = true }};

fn mkPr(id: []const u8, status: []const u8, approved: bool) LinkedPr {
    return .{ .id = id, .status = status, .reviewers = if (approved) &approved_reviewer else &.{} };
}

test "groups follow the default order, the rest alphabetical at the end; a collapsed group hides its tickets" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = [_]Issue{ issue("TE-1", "Done"), issue("TE-2", "Testing"), issue("TE-3", "To Do"), issue("TE-4", "Zombie"), issue("TE-5", "Aardvark") };
    const r = try computeRows(a.allocator(), &issues, &st, fixTab(), false, null);
    try testing.expectEqual(@as(usize, 5), r.ticket_count);
    try testing.expectEqualStrings("Testing", r.rows[0].group.status);
    try testing.expectEqualStrings("To Do", r.rows[2].group.status);
    try testing.expectEqualStrings("Done", r.rows[4].group.status);
    try testing.expectEqualStrings("Aardvark", r.rows[6].group.status);
    try testing.expectEqualStrings("Zombie", r.rows[8].group.status);
    try st.toggleGroup("Done");
    const folded = try computeRows(a.allocator(), &issues, &st, fixTab(), false, null);
    try testing.expect(!folded.rows[4].group.expanded);
    try testing.expectEqualStrings("Aardvark", folded.rows[5].group.status);
    try st.toggleGroup("Done");
    try testing.expect((try computeRows(a.allocator(), &issues, &st, fixTab(), false, null)).rows[4].group.expanded);
}

test "the widen row is the last row on a windowed tab, widens 14 -> 30 -> 90 -> none, and is gone at none" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = [_]Issue{issue("TE-1", "To Do")};
    var tab = fixTab();
    tab.kind = .work_reported;
    // No window: no row. Every other tab is this one.
    try testing.expectEqual(@as(usize, 2), (try computeRows(a.allocator(), &issues, &st, tab, false, null)).rows.len);

    // The tab opens on two weeks; the row sits below the group, last.
    st.window_days = 14;
    const wk2 = try computeRows(a.allocator(), &issues, &st, tab, false, null);
    try testing.expectEqual(@as(usize, 3), wk2.rows.len);
    try testing.expectEqual(@as(u16, 14), wk2.rows[2].show_older.window);
    try testing.expectEqual(@as(u16, 30), wk2.rows[2].show_older.next);
    // It belongs to no ticket and folds nothing.
    try testing.expect(wk2.rows[2].issueIdx() == null);
    try testing.expect(!wk2.rows[2].isChild());

    // One press per step: 30, then 90, then all time.
    st.window_days = 30;
    const d30 = try computeRows(a.allocator(), &issues, &st, tab, false, null);
    try testing.expectEqual(@as(u16, 30), d30.rows[2].show_older.window);
    try testing.expectEqual(@as(u16, 90), d30.rows[2].show_older.next);
    st.window_days = 90;
    const d90 = try computeRows(a.allocator(), &issues, &st, tab, false, null);
    try testing.expectEqual(@as(u16, 90), d90.rows[2].show_older.window);
    try testing.expectEqual(@as(u16, 0), d90.rows[2].show_older.next);
    // All time is the last step: nothing left to press.
    st.window_days = 0;
    const all = try computeRows(a.allocator(), &issues, &st, tab, false, null);
    try testing.expectEqual(@as(usize, 2), all.rows.len);
    try testing.expect(all.rows[1] == .ticket);

    // An empty two weeks still offers the step out — that is when it
    // matters most.
    st.window_days = 14;
    const none = [_]bool{false};
    const empty = try computeRows(a.allocator(), &issues, &st, tab, false, &none);
    try testing.expectEqual(@as(usize, 1), empty.rows.len);
    try testing.expectEqual(@as(usize, 0), empty.ticket_count);
    try testing.expectEqual(@as(u16, 30), empty.rows[0].show_older.next);
}

test "the mask narrows the tree and drops an emptied group; a custom status_order wins" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = [_]Issue{ issue("TE-1", "To Do"), issue("TE-2", "Testing"), issue("TE-3", "Testing") };
    var tab = fixTab();
    tab.status_order = &.{ "To Do", "Testing" };
    const mask = [_]bool{ true, false, true };
    const r = try computeRows(a.allocator(), &issues, &st, tab, false, &mask);
    try testing.expectEqual(@as(usize, 2), r.ticket_count);
    try testing.expectEqualStrings("To Do", r.rows[0].group.status);
    try testing.expectEqual(@as(usize, 1), r.rows[2].group.count);
    try testing.expectEqual(@as(usize, 2), r.rows[3].ticket.issue_idx);
    const none = [_]bool{ false, false, false };
    try testing.expectEqual(@as(usize, 0), (try computeRows(a.allocator(), &issues, &st, tab, false, &none)).rows.len);
}

test "bumps: pr_approved and no_open_prs promote a PR-review ticket once its PRs are cached; release_cut needs the flag" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = [_]Issue{issue("TE-1", "In PR Review")};
    var tab = fixTab();
    tab.bumps = .{ .pr_approved = "Testing", .no_open_prs = "Testing" };
    // Nothing cached: no bump.
    const cold = try computeRows(a.allocator(), &issues, &st, tab, false, null);
    try testing.expectEqualStrings("In PR Review", cold.rows[0].group.status);
    try testing.expect(!cold.rows[1].ticket.bumped);
    // One approved open PR: pr_approved.
    try st.putPrs("TE-1", &.{mkPr("#1", "OPEN", true)});
    const warm = try computeRows(a.allocator(), &issues, &st, tab, false, null);
    try testing.expectEqualStrings("Testing", warm.rows[0].group.status);
    try testing.expect(warm.rows[1].ticket.bumped);
    try testing.expectEqualStrings("Testing", warm.rows[1].ticket.effective_status);
    // One merged, unapproved PR: no_open_prs.
    try st.putPrs("TE-1", &.{mkPr("#1", "MERGED", false)});
    tab.bumps = .{ .no_open_prs = "Testing" };
    try testing.expectEqualStrings("Testing", (try computeRows(a.allocator(), &issues, &st, tab, false, null)).rows[0].group.status);
    // An empty cache is "unknown", not "none open".
    try st.putPrs("TE-1", &.{});
    try testing.expectEqualStrings("In PR Review", (try computeRows(a.allocator(), &issues, &st, tab, false, null)).rows[0].group.status);
    // release_cut: off, nothing; on, Done goes to the top sentinel.
    const done = [_]Issue{ issue("TE-2", "Done"), issue("TE-3", "Testing") };
    tab.bumps = .{ .release_cut = &.{.{ .status = "Done", .target = "top" }} };
    try testing.expectEqualStrings("Testing", (try computeRows(a.allocator(), &done, &st, tab, false, null)).rows[0].group.status);
    const cut = try computeRows(a.allocator(), &done, &st, tab, true, null);
    try testing.expectEqualStrings(top_sentinel, cut.rows[0].group.status);
    try testing.expect(cut.rows[1].ticket.bumped);
}

test "an expanded ticket shows a loading row, then its PRs capped at three with a show-all row, then all; a merged PR expands to its pipelines" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var st = State.init(testing.allocator);
    defer st.deinit();
    const issues = [_]Issue{issue("TE-1", "Testing")};
    try st.setExpanded("TE-1", true);
    const loading = try computeRows(a.allocator(), &issues, &st, fixTab(), false, null);
    try testing.expect(loading.rows[2] == .pr_loading);
    try st.putPrs("TE-1", &.{ mkPr("#1", "MERGED", true), mkPr("#2", "OPEN", false), mkPr("#3", "MERGED", false), mkPr("#4", "DECLINED", false), mkPr("#5", "OPEN", false) });
    const capped = try computeRows(a.allocator(), &issues, &st, fixTab(), false, null);
    // group, ticket, #3 #4 #5, show-more(2)
    try testing.expectEqual(@as(usize, 6), capped.rows.len);
    try testing.expectEqual(@as(usize, 2), capped.rows[2].pr.pr_idx);
    try testing.expectEqual(@as(usize, 2), capped.rows[5].show_more.hidden);
    try st.showAll("TE-1");
    const all = try computeRows(a.allocator(), &issues, &st, fixTab(), false, null);
    try testing.expectEqual(@as(usize, 7), all.rows.len);
    try testing.expectEqual(@as(usize, 0), all.rows[2].pr.pr_idx);
    // Expand #1 (merged): loading, then pipelines, then an error wins over a cache.
    try st.setPrExpanded("TE-1", "#1", true);
    try testing.expect((try computeRows(a.allocator(), &issues, &st, fixTab(), false, null)).rows[3] == .pipeline_loading);
    try st.putPipelines("TE-1", "#1", &.{ .{ .build_number = 1 }, .{ .build_number = 2 } });
    const piped = try computeRows(a.allocator(), &issues, &st, fixTab(), false, null);
    try testing.expect(piped.rows[3] == .pipeline and piped.rows[4] == .pipeline);
    try testing.expectEqual(@as(usize, 1), piped.rows[4].pipeline.pipeline_idx);
    try testing.expect(piped.rows[5] == .pr);
    try st.putPipelines("TE-1", "#1", &.{});
    try testing.expect((try computeRows(a.allocator(), &issues, &st, fixTab(), false, null)).rows[3] == .pipeline_empty);
    try st.putPipelineError("TE-1", "#1", "not a bitbucket PR URL");
    try testing.expect((try computeRows(a.allocator(), &issues, &st, fixTab(), false, null)).rows[3] == .pipeline_error);
    try testing.expectEqualStrings("not a bitbucket PR URL", st.pipelineError("TE-1", "#1").?);
    try st.setPrExpanded("TE-1", "#1", false);
    try testing.expect((try computeRows(a.allocator(), &issues, &st, fixTab(), false, null)).rows[3] == .pr);
    // A collapsed ticket has no children even with a full cache.
    try st.setExpanded("TE-1", false);
    try testing.expectEqual(@as(usize, 2), (try computeRows(a.allocator(), &issues, &st, fixTab(), false, null)).rows.len);
    try testing.expectEqual(@as(usize, 1), rowOfKey(all.rows, &issues, "TE-1").?);
    try testing.expect(rowOfKey(all.rows, &issues, "TE-9") == null);
}
