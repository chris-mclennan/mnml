//! The web bar's filters, as data. Bitbucket Cloud's pull-request page
//! narrows by search, then Status, then Author, then Target branch,
//! then the right-hand Reviewing / All dropdown; its pipelines page by
//! the people who ran them, Branch, Pipeline type, Status and Trigger
//! type. This is that bar for the pane: one `Filters` per tab, each
//! chip a field, each field a predicate over what the tab has already
//! loaded.
//!
//! Every predicate here is CLIENT-SIDE over the loaded set. The two
//! that can need rows the set does not have — a Status that adds an
//! API state, an Author that flips `mine_only` — are decided in
//! `app.zig`, which compares what is wanted with what was loaded
//! (`ApiStates.covers`) and asks for one refetch through the ordinary
//! path when it has to. Nothing in this file makes a request.
//!
//! `Show` folds the pane's older `awaiting:` chip in: the web's
//! dropdown says Reviewing / Watching / All, and "watching" needs a
//! watcher list Bitbucket's API does not expose, so the third value
//! here is the one the pane can answer — what is waiting on MY vote.

const std = @import("std");
const model = @import("model.zig");
const cfg = @import("config.zig");

/// The API states a pull-request listing is fetched with. `draft` is
/// not one of them: a draft is an OPEN pull request with a flag, so
/// Open and Draft share the one request.
pub const ApiStates = struct {
    open: bool = true,
    merged: bool = false,
    declined: bool = false,

    /// Does a listing fetched with `loaded` already hold everything
    /// `wanted` asks for? False is the one case a filter costs a fetch.
    pub fn covers(loaded: ApiStates, wanted: ApiStates) bool {
        if (wanted.open and !loaded.open) return false;
        if (wanted.merged and !loaded.merged) return false;
        if (wanted.declined and !loaded.declined) return false;
        return true;
    }

    /// The `state=` values, in the API's spelling, into `buf`.
    pub fn list(s: ApiStates, buf: *[3][]const u8) []const []const u8 {
        var n: usize = 0;
        if (s.open) {
            buf[n] = "OPEN";
            n += 1;
        }
        if (s.merged) {
            buf[n] = "MERGED";
            n += 1;
        }
        if (s.declined) {
            buf[n] = "DECLINED";
            n += 1;
        }
        return buf[0..n];
    }

    pub fn none(s: ApiStates) bool {
        return !s.open and !s.merged and !s.declined;
    }

    pub fn eql(x: ApiStates, y: ApiStates) bool {
        return x.open == y.open and x.merged == y.merged and x.declined == y.declined;
    }
};

/// The Status chip: a multi-select over the four the web offers.
pub const PrStatus = struct {
    open: bool = true,
    draft: bool = true,
    merged: bool = false,
    declined: bool = false,

    pub const Which = enum { open, draft, merged, declined };
    pub const all = [_]Which{ .open, .draft, .merged, .declined };

    /// What a tab starts with: what its kind lists. The web's default
    /// is Open + Draft, which is the open tree's; a merged tree starts
    /// on Merged, a per-repo tab on the state its config names.
    pub fn defaultFor(kind: cfg.Kind, state: []const u8) PrStatus {
        return switch (kind) {
            .workspace_open_prs => .{},
            .workspace_merged_prs => .{ .open = false, .draft = false, .merged = true },
            .pull_requests => blk: {
                if (std.ascii.eqlIgnoreCase(state, "MERGED")) break :blk .{ .open = false, .draft = false, .merged = true };
                if (std.ascii.eqlIgnoreCase(state, "DECLINED")) break :blk .{ .open = false, .draft = false, .declined = true };
                // "" is a tab that names no state — it shows whatever
                // came back, so every box is ticked; SUPERSEDED reads
                // as the open pair, the one the web opens on.
                if (state.len == 0) break :blk .{ .merged = true, .declined = true };
                break :blk .{};
            },
            else => .{},
        };
    }

    pub fn has(s: PrStatus, w: Which) bool {
        return switch (w) {
            .open => s.open,
            .draft => s.draft,
            .merged => s.merged,
            .declined => s.declined,
        };
    }

    pub fn toggle(s: *PrStatus, w: Which) void {
        switch (w) {
            .open => s.open = !s.open,
            .draft => s.draft = !s.draft,
            .merged => s.merged = !s.merged,
            .declined => s.declined = !s.declined,
        }
    }

    pub fn none(s: PrStatus) bool {
        return !s.open and !s.draft and !s.merged and !s.declined;
    }

    pub fn eql(x: PrStatus, y: PrStatus) bool {
        return x.open == y.open and x.draft == y.draft and x.merged == y.merged and x.declined == y.declined;
    }

    /// The states the API has to be asked for to answer this set.
    pub fn apiStates(s: PrStatus) ApiStates {
        return .{ .open = s.open or s.draft, .merged = s.merged, .declined = s.declined };
    }

    /// Does a pull request pass? A draft is OPEN with `draft` set, so
    /// Open alone hides drafts and Draft alone hides the rest.
    pub fn matches(s: PrStatus, pr: model.PullRequest) bool {
        if (std.ascii.eqlIgnoreCase(pr.state, "OPEN")) return if (pr.draft) s.draft else s.open;
        if (std.ascii.eqlIgnoreCase(pr.state, "MERGED")) return s.merged;
        if (std.ascii.eqlIgnoreCase(pr.state, "DECLINED")) return s.declined;
        return false;
    }

    pub fn wordOf(w: Which) []const u8 {
        return switch (w) {
            .open => "Open",
            .draft => "Draft",
            .merged => "Merged",
            .declined => "Declined",
        };
    }

    /// `Open + Draft` / `Merged` / `Open + Merged` / `none`, into `buf`.
    pub fn label(s: PrStatus, buf: []u8) []const u8 {
        var n: usize = 0;
        for (all) |w| {
            if (!s.has(w)) continue;
            const word = wordOf(w);
            if (n > 0) {
                if (n + 3 > buf.len) break;
                @memcpy(buf[n .. n + 3], " + ");
                n += 3;
            }
            if (n + word.len > buf.len) break;
            @memcpy(buf[n .. n + word.len], word);
            n += word.len;
        }
        return if (n == 0) "none" else buf[0..n];
    }
};

/// The Author chip: everyone, the account the pane runs as, or one
/// name seen in the loaded set. `me` is the pane's older mine-only
/// fetch (the account's pull requests, whatever the page held), so it
/// is the one value here that costs a request; a name is a predicate
/// over the rows already there.
pub const Author = union(enum) {
    all,
    me,
    named: []const u8,

    pub fn eql(x: Author, y: Author) bool {
        return switch (x) {
            .all => y == .all,
            .me => y == .me,
            .named => |n| y == .named and std.mem.eql(u8, n, y.named),
        };
    }

    /// `all` / the account's display name (or `me`) / the name.
    pub fn label(a: Author, me_name: []const u8) []const u8 {
        return switch (a) {
            .all => "all",
            .me => if (me_name.len > 0) me_name else "me",
            .named => |n| n,
        };
    }
};

/// The right-hand dropdown: everything, what I am a reviewer on, or
/// what is waiting on my vote (the pane's `awaiting:` chip, folded in).
pub const Show = enum {
    all,
    reviewing,
    awaiting,

    pub const cycle = [_]Show{ .all, .reviewing, .awaiting };

    pub fn next(s: Show) Show {
        return switch (s) {
            .all => .reviewing,
            .reviewing => .awaiting,
            .awaiting => .all,
        };
    }

    pub fn label(s: Show) []const u8 {
        return switch (s) {
            .all => "all",
            .reviewing => "reviewing",
            .awaiting => "awaiting me",
        };
    }

    /// The sentence the header and the status line use.
    pub fn sentence(s: Show) []const u8 {
        return switch (s) {
            .all => "every pull request",
            .reviewing => "what I am reviewing",
            .awaiting => "awaiting my review",
        };
    }
};

/// One tab's filters, the PR family's and the pipelines family's in one
/// struct so a tab carries whichever apply. Strings are borrowed here;
/// `app.zig`'s `TabState` owns them.
pub const Filters = struct {
    status: PrStatus = .{},
    author: Author = .all,
    /// The destination branch; "" is any.
    target: []const u8 = "",
    show: Show = .all,
    /// The pipelines family's five. "" is any on each.
    run_by: []const u8 = "",
    branch: []const u8 = "",
    ptype: []const u8 = "",
    pstatus: []const u8 = "",
    trigger: []const u8 = "",

    /// What a tab of `kind` starts on.
    pub fn defaultFor(kind: cfg.Kind, state: []const u8, mine_only: bool) Filters {
        return .{ .status = PrStatus.defaultFor(kind, state), .author = if (mine_only) .me else .all };
    }

    /// Is anything narrowing a PR tab beyond its kind's own default?
    pub fn prNarrowed(f: Filters, kind: cfg.Kind, state: []const u8) bool {
        return f.prNarrowedFrom(defaultFor(kind, state, false));
    }

    /// The same against a given baseline — a mine-only tab's baseline
    /// has `author = me`, which is that tab's own scope rather than a
    /// narrowing of it.
    pub fn prNarrowedFrom(f: Filters, base: Filters) bool {
        if (!f.status.eql(base.status)) return true;
        if (!f.author.eql(base.author)) return true;
        if (f.target.len > 0) return true;
        if (f.show != .all) return true;
        return false;
    }

    pub fn pipelinesNarrowed(f: Filters) bool {
        return f.run_by.len > 0 or f.branch.len > 0 or f.ptype.len > 0 or f.pstatus.len > 0 or f.trigger.len > 0;
    }

    /// Does a pull request pass every PR-family predicate? `me` is
    /// the account the `me` author and the Show values are about; ""
    /// makes those two match nothing rather than everything, since a
    /// pane that cannot say who it is cannot say what is its.
    pub fn prMatches(f: Filters, pr: model.PullRequest, me: []const u8) bool {
        if (!f.status.matches(pr)) return false;
        switch (f.author) {
            .all => {},
            // The listing was fetched under `author = me` already;
            // the row-level check is what keeps a page that mixed in
            // a merged peek from another author honest.
            .me => if (me.len > 0 and !std.mem.eql(u8, pr.author_id, me)) return false,
            .named => |n| if (!std.mem.eql(u8, pr.author, n)) return false,
        }
        if (f.target.len > 0 and !std.mem.eql(u8, pr.dest_branch, f.target)) return false;
        switch (f.show) {
            .all => {},
            .reviewing => if (!pr.reviewedBy(me)) return false,
            .awaiting => if (!pr.awaitingApproval(me)) return false,
        }
        return true;
    }

    /// Does a pipeline run pass every pipelines-family predicate?
    pub fn runMatches(f: Filters, run: model.Pipeline) bool {
        if (f.run_by.len > 0 and !std.mem.eql(u8, run.creator, f.run_by)) return false;
        if (f.branch.len > 0 and !std.mem.eql(u8, run.ref_name, f.branch)) return false;
        if (f.ptype.len > 0 and !std.ascii.eqlIgnoreCase(run.typeLabel(), f.ptype)) return false;
        if (f.pstatus.len > 0 and !std.ascii.eqlIgnoreCase(run.stateLabel(), f.pstatus)) return false;
        if (f.trigger.len > 0 and !std.ascii.eqlIgnoreCase(run.trigger, f.trigger)) return false;
        return true;
    }

    /// A branch row of the pipelines tree: its name against the Branch
    /// chip, its newest run against the rest. A branch with no run has
    /// no creator, type, status or trigger, so any of those four hides
    /// it; the Branch chip alone still finds it.
    pub fn branchMatches(f: Filters, name: []const u8, latest: ?model.Pipeline) bool {
        if (f.branch.len > 0 and !std.mem.eql(u8, name, f.branch)) return false;
        const needs_run = f.run_by.len > 0 or f.ptype.len > 0 or f.pstatus.len > 0 or f.trigger.len > 0;
        if (latest) |run| {
            var g = f;
            g.branch = "";
            return g.runMatches(run);
        }
        return !needs_run;
    }
};

/// The values a picker offers for one chip, gathered off the loaded
/// set: every distinct value seen, sorted, each once. `first` is the
/// clearing row (`any` / `all`) and always leads.
pub const Seen = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList([]const u8) = .empty,

    pub fn add(s: *Seen, v: []const u8) std.mem.Allocator.Error!void {
        if (v.len == 0) return;
        for (s.list.items) |have| if (std.mem.eql(u8, have, v)) return;
        try s.list.append(s.arena, try s.arena.dupe(u8, v));
    }

    /// The values, sorted case-insensitively.
    pub fn sorted(s: *Seen) []const []const u8 {
        std.mem.sort([]const u8, s.list.items, {}, lessThan);
        return s.list.items;
    }

    fn lessThan(_: void, x: []const u8, y: []const u8) bool {
        const n = @min(x.len, y.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = std.ascii.toLower(x[i]);
            const b = std.ascii.toLower(y[i]);
            if (a != b) return a < b;
        }
        return x.len < y.len;
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn mkPr(state: []const u8, draft: bool, author: []const u8, author_id: []const u8, dest: []const u8) model.PullRequest {
    return .{ .id = 1, .state = state, .draft = draft, .author = author, .author_id = author_id, .dest_branch = dest };
}

test "Status: Open alone hides drafts, Draft alone hides the rest, Merged and Declined are their own rows" {
    const open = mkPr("OPEN", false, "", "", "");
    const draft = mkPr("OPEN", true, "", "", "");
    const merged = mkPr("MERGED", false, "", "", "");
    const declined = mkPr("DECLINED", false, "", "", "");
    const dflt: PrStatus = .{};
    try t.expect(dflt.matches(open));
    try t.expect(dflt.matches(draft));
    try t.expect(!dflt.matches(merged));
    try t.expect(!dflt.matches(declined));
    var s: PrStatus = .{ .draft = false };
    try t.expect(s.matches(open));
    try t.expect(!s.matches(draft));
    s = .{ .open = false };
    try t.expect(!s.matches(open));
    try t.expect(s.matches(draft));
    s = .{ .open = false, .draft = false, .merged = true, .declined = true };
    try t.expect(s.matches(merged));
    try t.expect(s.matches(declined));
    try t.expect(!s.matches(open));
    // A state the set does not name never passes.
    try t.expect(!(PrStatus{ .open = true, .draft = true, .merged = true, .declined = true }).matches(mkPr("SUPERSEDED", false, "", "", "")));
    // The label reads the way the web's chip does.
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Open + Draft", dflt.label(&buf));
    try t.expectEqualStrings("Draft", (PrStatus{ .open = false }).label(&buf));
    try t.expectEqualStrings("Open + Draft + Merged", (PrStatus{ .merged = true }).label(&buf));
    try t.expectEqualStrings("none", (PrStatus{ .open = false, .draft = false }).label(&buf));
    // Toggling walks the set.
    s = .{};
    s.toggle(.merged);
    try t.expect(s.merged);
    s.toggle(.open);
    s.toggle(.draft);
    try t.expectEqualStrings("Merged", s.label(&buf));
}

test "Status: the API states behind a set, and whether a loaded listing already covers a wanted one" {
    // Open and Draft share the one OPEN request.
    try t.expect((PrStatus{}).apiStates().eql(.{ .open = true }));
    try t.expect((PrStatus{ .open = false }).apiStates().eql(.{ .open = true }));
    try t.expect((PrStatus{ .open = false, .draft = false }).apiStates().eql(.{ .open = false }));
    try t.expect((PrStatus{ .merged = true, .declined = true }).apiStates().eql(.{ .open = true, .merged = true, .declined = true }));
    // Adding Merged to an open listing needs a fetch; dropping it does not.
    const open_only: ApiStates = .{ .open = true };
    try t.expect(!open_only.covers(.{ .open = true, .merged = true }));
    try t.expect((ApiStates{ .open = true, .merged = true }).covers(open_only));
    try t.expect(open_only.covers(.{ .open = false }));
    var buf: [3][]const u8 = undefined;
    const l = (ApiStates{ .open = true, .merged = true }).list(&buf);
    try t.expectEqual(@as(usize, 2), l.len);
    try t.expectEqualStrings("OPEN", l[0]);
    try t.expectEqualStrings("MERGED", l[1]);
    try t.expect((ApiStates{ .open = false }).none());
    // The defaults per tab kind.
    try t.expect(PrStatus.defaultFor(.workspace_open_prs, "").eql(.{}));
    try t.expect(PrStatus.defaultFor(.workspace_merged_prs, "").eql(.{ .open = false, .draft = false, .merged = true }));
    try t.expect(PrStatus.defaultFor(.pull_requests, "DECLINED").eql(.{ .open = false, .draft = false, .declined = true }));
    try t.expect(PrStatus.defaultFor(.pull_requests, "OPEN").eql(.{}));
    try t.expect(PrStatus.defaultFor(.pull_requests, "").eql(.{ .merged = true, .declined = true }));
}

test "Author: all, me (by account), or one name seen; a pane that cannot say who it is matches nothing as me" {
    const mine = mkPr("OPEN", false, "Chris M", "acct-chris", "main");
    const danas = mkPr("OPEN", false, "Dana R", "acct-dana", "main");
    var f: Filters = .{};
    try t.expect(f.prMatches(mine, "acct-chris"));
    try t.expect(f.prMatches(danas, "acct-chris"));
    f.author = .me;
    try t.expect(f.prMatches(mine, "acct-chris"));
    try t.expect(!f.prMatches(danas, "acct-chris"));
    // No account known: `me` is decided by the fetch alone, so the
    // row-level check lets the listing through as it came.
    try t.expect(f.prMatches(danas, ""));
    f.author = .{ .named = "Dana R" };
    try t.expect(!f.prMatches(mine, "acct-chris"));
    try t.expect(f.prMatches(danas, "acct-chris"));
    try t.expectEqualStrings("all", (Author{ .all = {} }).label("Chris M"));
    try t.expectEqualStrings("Chris M", (Author{ .me = {} }).label("Chris M"));
    try t.expectEqualStrings("me", (Author{ .me = {} }).label(""));
    try t.expectEqualStrings("Dana R", (Author{ .named = "Dana R" }).label("Chris M"));
    try t.expect(Author.eql(.{ .named = "x" }, .{ .named = "x" }));
    try t.expect(!Author.eql(.{ .named = "x" }, .{ .named = "y" }));
    try t.expect(!Author.eql(.all, .me));
}

test "Target branch: the destination, exactly; any when empty" {
    const to_main = mkPr("OPEN", false, "", "", "main");
    const to_dev = mkPr("OPEN", false, "", "", "develop");
    var f: Filters = .{ .target = "main" };
    try t.expect(f.prMatches(to_main, ""));
    try t.expect(!f.prMatches(to_dev, ""));
    f.target = "";
    try t.expect(f.prMatches(to_dev, ""));
}

test "Show: reviewing is what I am a reviewer on; awaiting me is that minus what I have voted on; all is all" {
    const reviewer_unvoted = model.Participant{ .name = "Me", .account_id = "acct-me", .role = "REVIEWER" };
    const reviewer_voted = model.Participant{ .name = "Me", .account_id = "acct-me", .role = "REVIEWER", .approved = true, .state = "approved" };
    const commenter = model.Participant{ .name = "Me", .account_id = "acct-me", .role = "PARTICIPANT" };
    var waiting = mkPr("OPEN", false, "Dana R", "acct-dana", "main");
    waiting.participants = &.{reviewer_unvoted};
    var voted = waiting;
    voted.participants = &.{reviewer_voted};
    var only_commented = waiting;
    only_commented.participants = &.{commenter};
    var mine = mkPr("OPEN", false, "Me", "acct-me", "main");
    mine.participants = &.{reviewer_unvoted};
    var f: Filters = .{ .show = .reviewing };
    try t.expect(f.prMatches(waiting, "acct-me"));
    try t.expect(f.prMatches(voted, "acct-me"));
    try t.expect(!f.prMatches(only_commented, "acct-me"));
    // My own pull request is never something I review.
    try t.expect(!f.prMatches(mine, "acct-me"));
    f.show = .awaiting;
    try t.expect(f.prMatches(waiting, "acct-me"));
    try t.expect(!f.prMatches(voted, "acct-me"));
    try t.expect(!f.prMatches(only_commented, "acct-me"));
    f.show = .all;
    try t.expect(f.prMatches(only_commented, "acct-me"));
    try t.expect(f.prMatches(mine, ""));
    // Nobody to be: reviewing / awaiting match nothing rather than everything.
    f.show = .reviewing;
    try t.expect(!f.prMatches(waiting, ""));
    try t.expectEqual(Show.reviewing, Show.all.next());
    try t.expectEqual(Show.all, Show.awaiting.next());
    try t.expectEqualStrings("awaiting me", Show.awaiting.label());
}

fn mkRun(creator: []const u8, ref: []const u8, state: []const u8, result: []const u8, trigger: []const u8, selector: []const u8, target_type: []const u8) model.Pipeline {
    return .{ .build_number = 1, .creator = creator, .ref_name = ref, .state_name = state, .result_name = result, .trigger = trigger, .selector_type = selector, .target_type = target_type, .ref_type = "branch" };
}

test "Pipelines: run by, branch, type, status and trigger each narrow the loaded runs; case does not matter" {
    const main_ok = mkRun("Chris M", "main", "COMPLETED", "SUCCESSFUL", "PUSH", "branches", "pipeline_ref_target");
    const dev_bad = mkRun("Dana R", "develop", "COMPLETED", "FAILED", "SCHEDULE", "default", "pipeline_ref_target");
    const custom = mkRun("Chris M", "release/1.2", "COMPLETED", "STOPPED", "MANUAL", "custom", "pipeline_ref_target");
    const on_pr = mkRun("Sam K", "sam/x", "IN_PROGRESS", "", "PUSH", "pull-requests", "pipeline_pullrequest_target");
    var f: Filters = .{};
    for ([_]model.Pipeline{ main_ok, dev_bad, custom, on_pr }) |r| try t.expect(f.runMatches(r));
    f = .{ .run_by = "Chris M" };
    try t.expect(f.runMatches(main_ok));
    try t.expect(f.runMatches(custom));
    try t.expect(!f.runMatches(dev_bad));
    f = .{ .branch = "develop" };
    try t.expect(f.runMatches(dev_bad));
    try t.expect(!f.runMatches(main_ok));
    f = .{ .ptype = "custom" };
    try t.expect(f.runMatches(custom));
    try t.expect(!f.runMatches(main_ok));
    f = .{ .ptype = "pull-request" };
    try t.expect(f.runMatches(on_pr));
    try t.expect(!f.runMatches(dev_bad));
    f = .{ .ptype = "branch" };
    try t.expect(f.runMatches(main_ok));
    try t.expect(f.runMatches(dev_bad));
    try t.expect(!f.runMatches(custom));
    f = .{ .pstatus = "failed" };
    try t.expect(f.runMatches(dev_bad));
    try t.expect(!f.runMatches(main_ok));
    f = .{ .pstatus = "IN_PROGRESS" };
    try t.expect(f.runMatches(on_pr));
    f = .{ .trigger = "schedule" };
    try t.expect(f.runMatches(dev_bad));
    try t.expect(!f.runMatches(main_ok));
    f = .{ .trigger = "manual" };
    try t.expect(f.runMatches(custom));
    // Two at once is an AND.
    f = .{ .run_by = "Chris M", .trigger = "push" };
    try t.expect(f.runMatches(main_ok));
    try t.expect(!f.runMatches(custom));
    try t.expect(f.pipelinesNarrowed());
    try t.expect(!(Filters{}).pipelinesNarrowed());
}

test "a branch row of the tree: the Branch chip finds a branch with no run; every other chip needs one" {
    const ok = mkRun("Chris M", "main", "COMPLETED", "SUCCESSFUL", "PUSH", "branches", "");
    var f: Filters = .{ .branch = "staging" };
    try t.expect(f.branchMatches("staging", null));
    try t.expect(!f.branchMatches("main", ok));
    f = .{ .pstatus = "successful" };
    try t.expect(f.branchMatches("main", ok));
    try t.expect(!f.branchMatches("staging", null));
    f = .{};
    try t.expect(f.branchMatches("staging", null));
    // The Branch chip is compared to the branch's NAME, and the run's
    // other facts to the run — one chip, one column.
    f = .{ .branch = "main", .trigger = "push" };
    try t.expect(f.branchMatches("main", ok));
    f = .{ .branch = "main", .trigger = "manual" };
    try t.expect(!f.branchMatches("main", ok));
}

test "the PR filters know whether they narrow a tab beyond its kind's default" {
    var f = Filters.defaultFor(.workspace_open_prs, "", false);
    try t.expect(!f.prNarrowed(.workspace_open_prs, ""));
    f.status.toggle(.merged);
    try t.expect(f.prNarrowed(.workspace_open_prs, ""));
    f = Filters.defaultFor(.workspace_merged_prs, "", false);
    try t.expect(!f.prNarrowed(.workspace_merged_prs, ""));
    try t.expect(f.status.merged and !f.status.open);
    f.target = "main";
    try t.expect(f.prNarrowed(.workspace_merged_prs, ""));
    // A mine-only launch starts on `me`, which narrows the kind's
    // default but is that tab's own baseline.
    const mine = Filters.defaultFor(.workspace_open_prs, "", true);
    try t.expect(mine.author == .me);
    try t.expect(mine.prNarrowed(.workspace_open_prs, ""));
    try t.expect(!mine.prNarrowedFrom(mine));
}

test "the values seen: each once, sorted without regard to case, the empty value dropped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var s: Seen = .{ .arena = arena.allocator() };
    try s.add("main");
    try s.add("Develop");
    try s.add("main");
    try s.add("");
    try s.add("chris/fix");
    const got = s.sorted();
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("chris/fix", got[0]);
    try t.expectEqualStrings("Develop", got[1]);
    try t.expectEqualStrings("main", got[2]);
}
