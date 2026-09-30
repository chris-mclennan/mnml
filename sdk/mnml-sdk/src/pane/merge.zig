//! Whether a pull request may merge, and what the `[ Merge ]` button
//! does about it.
//!
//! A button that is always pressable teaches the reader nothing: you
//! press it, the forge refuses, and you go and find out why somewhere
//! else. So the button is **dim and not a hit** until every condition
//! holds, and hovering a dim one says which one does not. Five
//! conditions, in the order a reader thinks about them:
//!
//!   approvals  the required reviewers have approved
//!   tasks      every task on the pull request is resolved
//!   conflicts  it still merges cleanly into its target
//!   build      the latest run on the SOURCE commit is green
//!   comments   every comment is resolved or replied to
//!
//! The last one is the same rule the unresolved-thread count uses: a
//! reply is an answer whoever wrote it, and the resolve button is used
//! unevenly across teams, so counting only `resolution` would call
//! every answered thread unanswered.
//!
//! What a press does is deliberately NOT an API merge. It dispatches a
//! Claude Code session that merges through the Bitbucket API, so the
//! one destructive action in either pane goes through the thing the
//! user already supervises — it can read the PR first, say what it did,
//! and be watched while it does it (`sdk.pane.action`, `watch_session`).

const std = @import("std");
const frame_mod = @import("../frame.zig");
const theme_mod = @import("theme.zig");
const action_mod = @import("action.zig");
const text_mod = @import("text.zig");

pub const Style = frame_mod.Style;
pub const Theme = theme_mod.Theme;
pub const width = text_mod.width;

pub const label = "Merge";

/// The five, in the order they are reported.
pub const Condition = enum { approvals, tasks, conflicts, build, comments };

/// How a pull request merges. Which of these a repository allows is the
/// repo's own setting; a pane offers the ones it was told about and
/// falls back to a merge commit, which every repo allows.
pub const Strategy = enum {
    merge_commit,
    squash,
    fast_forward,

    /// The word the confirm shows and the prompt names — Bitbucket's
    /// own spelling for `merge_strategy`.
    pub fn apiName(s: Strategy) []const u8 {
        return switch (s) {
            .merge_commit => "merge_commit",
            .squash => "squash",
            .fast_forward => "fast_forward",
        };
    }

    pub fn title(s: Strategy) []const u8 {
        return switch (s) {
            .merge_commit => "merge commit",
            .squash => "squash",
            .fast_forward => "fast-forward",
        };
    }

    pub fn next(s: Strategy, allowed: []const Strategy) Strategy {
        if (allowed.len == 0) return .merge_commit;
        for (allowed, 0..) |a, i| if (a == s) return allowed[(i + 1) % allowed.len];
        return allowed[0];
    }
};

/// What one readiness look found. Everything defaults to the state that
/// BLOCKS, so a pull request nobody has looked at is never ready by
/// accident.
pub const Readiness = struct {
    /// Reviewers who have approved, and how many the repo asks for.
    approvals: usize = 0,
    required: usize = 1,
    /// Tasks still open on the pull request.
    open_tasks: usize = 0,
    /// It no longer merges cleanly.
    conflicts: bool = true,
    /// The newest run on the source commit succeeded.
    build_green: bool = false,
    /// A reviewer asked for changes and has not withdrawn it.
    changes_requested: bool = false,
    /// Comment threads neither resolved nor replied to.
    unanswered_comments: usize = 0,
    /// Nothing has been looked at yet: the button is dim and says so
    /// rather than claiming a blocker it has not checked.
    checked: bool = false,

    pub fn ready(r: Readiness) bool {
        return r.checked and r.firstBlocker() == null;
    }

    /// The condition a reader should fix first, in the order above.
    pub fn firstBlocker(r: Readiness) ?Condition {
        if (r.approvals < r.required or r.changes_requested) return .approvals;
        if (r.open_tasks > 0) return .tasks;
        if (r.conflicts) return .conflicts;
        if (!r.build_green) return .build;
        if (r.unanswered_comments > 0) return .comments;
        return null;
    }

    /// The sentence a dim button says on hover. Names the condition and
    /// the number behind it, because "not ready" on its own is exactly
    /// the answer that sends the reader to the web UI.
    pub fn reason(r: Readiness, buf: []u8) []const u8 {
        if (!r.checked) return "not checked yet \u{2014} open the row to look";
        const blocker = r.firstBlocker() orelse return "ready to merge";
        return switch (blocker) {
            .approvals => if (r.changes_requested)
                std.fmt.bufPrint(buf, "a reviewer asked for changes", .{}) catch "changes requested"
            else
                std.fmt.bufPrint(buf, "{d} of {d} approvals", .{ r.approvals, r.required }) catch "not approved",
            .tasks => std.fmt.bufPrint(buf, "{d} task{s} still open", .{ r.open_tasks, if (r.open_tasks == 1) "" else "s" }) catch "tasks open",
            .conflicts => "it no longer merges cleanly",
            .build => "the latest build on the source commit is not green",
            .comments => std.fmt.bufPrint(buf, "{d} comment{s} neither resolved nor replied to", .{ r.unanswered_comments, if (r.unanswered_comments == 1) "" else "s" }) catch "comments unanswered",
        };
    }

    /// `Merge: 2 of 2 approvals` — what the hint row shows while the
    /// pointer is on a dim button.
    pub fn hoverText(r: Readiness, buf: []u8) []const u8 {
        var inner: [160]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}: {s}", .{ label, r.reason(&inner) }) catch label;
    }
};

/// A dim `[ Merge ]` is not a hit: the pointer must find nothing there,
/// so a stray click cannot merge anything.
pub fn isPressable(r: Readiness) bool {
    return r.ready();
}

pub fn caption(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "[ {s} ]", .{label}) catch "[ Merge ]";
}

/// Ready wears the green every `final` button wears; blocked is the
/// muted one, dimmed, so it reads as "there is something here, and it
/// is not for you yet" rather than as an ordinary button you happened
/// to miss.
pub fn chipOf(th: Theme, r: Readiness) action_mod.Chip {
    if (r.ready()) return action_mod.chipOf(th, .idle, .final);
    const off: Style = .{ .fg = th.muted, .mods = .{ .dim = true } };
    return .{ .bracket = off, .word = off };
}

/// The same, for a caller that paints the caption in one style.
pub fn styleOf(th: Theme, r: Readiness) Style {
    return chipOf(th, r).flat();
}

/// The lines the confirm shows. Named, because a confirm that says
/// "Merge this pull request?" is a confirm nobody reads.
///
/// **Every string here is borrowed, and a confirm stays up across
/// frames**, so a pane that holds one has to own what it names — both
/// shipped panes wrap it in a `MergeConfirm { arena, … }` and dupe
/// each field onto that arena. A title taken off a frame or a job
/// result paints as garbage the moment the reader stops to read it.
pub const Confirm = struct {
    title: []const u8,
    source: []const u8,
    target: []const u8,
    strategy: Strategy,
    url: []const u8,

    pub fn heading(c: Confirm, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, " Merge {s} ", .{shortUrlTail(c.url)}) catch " Merge ";
    }

    pub fn branchLine(c: Confirm, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s} \u{2192} {s}", .{ c.source, c.target }) catch c.source;
    }

    pub fn strategyLine(c: Confirm, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "strategy: {s}   (\u{2190}\u{2192} changes it)", .{c.strategy.title()}) catch c.strategy.title();
    }
};

/// `acme/api#1234` out of a pull request's URL, for the confirm's
/// heading; the whole URL when it is not one.
pub fn shortUrlTail(url: []const u8) []const u8 {
    const marker = "bitbucket.org/";
    const at = std.mem.indexOf(u8, url, marker) orelse return url;
    return url[at + marker.len ..];
}

/// The prompt the dispatched session is started with. It names the
/// pull request by URL and the strategy by Bitbucket's own word, says
/// which environment variable holds the token, and asks for the
/// outcome on the LAST line — which is what the pane reads back off
/// the session when it ends.
pub fn prompt(arena: std.mem.Allocator, c: Confirm) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\/agents:merge-pr {s}
        \\
        \\<!-- context -->
        \\Merge this Bitbucket pull request through the REST API, using the
        \\token in $BITBUCKET_ACCESS_TOKEN:
        \\
        \\  pull request: {s}
        \\  title: {s}
        \\  {s} -> {s}
        \\  merge_strategy: {s}
        \\
        \\Check the pull request is still open and still mergeable before
        \\you do anything. Report the result on your LAST line, in one of
        \\these two shapes and nothing else:
        \\
        \\  merged {s} as {s}
        \\  refused <why>
    , .{
        c.url,
        c.url,
        c.title,
        c.source,
        c.target,
        c.strategy.apiName(),
        shortUrlTail(c.url),
        c.strategy.apiName(),
    });
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const green: Readiness = .{
    .approvals = 2,
    .required = 2,
    .open_tasks = 0,
    .conflicts = false,
    .build_green = true,
    .unanswered_comments = 0,
    .checked = true,
};

test "a pull request nobody has looked at is never ready by accident" {
    // Every default is the state that blocks.
    const fresh: Readiness = .{};
    try testing.expect(!fresh.ready());
    try testing.expect(!isPressable(fresh));
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings("not checked yet \u{2014} open the row to look", fresh.reason(&buf));
    // Checked and clean is the only way through.
    try testing.expect(green.ready());
    try testing.expect(isPressable(green));
    try testing.expectEqualStrings("ready to merge", green.reason(&buf));
}

test "the blocker a reader should fix first, and the sentence that names it" {
    var buf: [160]u8 = undefined;

    var r = green;
    r.approvals = 1;
    try testing.expectEqual(Condition.approvals, r.firstBlocker().?);
    try testing.expectEqualStrings("1 of 2 approvals", r.reason(&buf));
    // Changes requested outranks a count that otherwise adds up.
    r = green;
    r.changes_requested = true;
    try testing.expectEqual(Condition.approvals, r.firstBlocker().?);
    try testing.expectEqualStrings("a reviewer asked for changes", r.reason(&buf));

    r = green;
    r.open_tasks = 2;
    try testing.expectEqualStrings("2 tasks still open", r.reason(&buf));
    r.open_tasks = 1;
    try testing.expectEqualStrings("1 task still open", r.reason(&buf));

    r = green;
    r.conflicts = true;
    try testing.expectEqualStrings("it no longer merges cleanly", r.reason(&buf));

    r = green;
    r.build_green = false;
    try testing.expectEqualStrings("the latest build on the source commit is not green", r.reason(&buf));

    r = green;
    r.unanswered_comments = 3;
    try testing.expectEqualStrings("3 comments neither resolved nor replied to", r.reason(&buf));
    r.unanswered_comments = 1;
    try testing.expectEqualStrings("1 comment neither resolved nor replied to", r.reason(&buf));

    // The order: the earliest unmet condition is the one named, even
    // when several are unmet.
    r = .{ .checked = true };
    try testing.expectEqual(Condition.approvals, r.firstBlocker().?);

    // The hint row's form names the button as well as the reason.
    r = green;
    r.open_tasks = 1;
    try testing.expectEqualStrings("Merge: 1 task still open", r.hoverText(&buf));
}

test "a dim button is not a hit, and wears the muted colour rather than a chip's" {
    const th = Theme.fromHello(null);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("[ Merge ]", caption(&buf));
    // Ready and blocked must not look the same — that is the whole
    // point of dimming it.
    const ready_style = styleOf(th, green);
    const blocked_style = styleOf(th, .{});
    try testing.expect(!std.meta.eql(ready_style.fg, blocked_style.fg) or ready_style.mods.bits() != blocked_style.mods.bits());
    try testing.expect(blocked_style.mods.dim);
}

test "the strategy cycles through what the repo allows, and names itself Bitbucket's way" {
    try testing.expectEqualStrings("merge_commit", Strategy.merge_commit.apiName());
    try testing.expectEqualStrings("fast-forward", Strategy.fast_forward.title());
    const allowed = [_]Strategy{ .merge_commit, .squash };
    try testing.expectEqual(Strategy.squash, Strategy.merge_commit.next(&allowed));
    try testing.expectEqual(Strategy.merge_commit, Strategy.squash.next(&allowed));
    // One the repo does not allow lands on the first that it does.
    try testing.expectEqual(Strategy.merge_commit, Strategy.fast_forward.next(&allowed));
    // Nothing allowed at all falls back to the one every repo has.
    try testing.expectEqual(Strategy.merge_commit, Strategy.squash.next(&.{}));
}

test "the confirm names the pull request, its branches and its strategy" {
    const c: Confirm = .{
        .title = "Fix the login redirect",
        .source = "bug/fix-login",
        .target = "main",
        .strategy = .squash,
        .url = "https://bitbucket.org/acme/api/pull-requests/1234",
    };
    var buf: [160]u8 = undefined;
    try testing.expectEqualStrings(" Merge acme/api/pull-requests/1234 ", c.heading(&buf));
    try testing.expectEqualStrings("bug/fix-login \u{2192} main", c.branchLine(&buf));
    try testing.expectEqualStrings("strategy: squash   (\u{2190}\u{2192} changes it)", c.strategyLine(&buf));
    try testing.expectEqualStrings("acme/api/pull-requests/1234", shortUrlTail(c.url));
    try testing.expectEqualStrings("nothing/like/a/url", shortUrlTail("nothing/like/a/url"));
}

test "the prompt names the PR, the strategy and the variable, and asks for the outcome on the last line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const p = try prompt(arena_state.allocator(), .{
        .title = "Fix the login redirect",
        .source = "bug/fix-login",
        .target = "main",
        .strategy = .squash,
        .url = "https://bitbucket.org/acme/api/pull-requests/1234",
    });
    try testing.expect(std.mem.startsWith(u8, p, "/agents:merge-pr https://bitbucket.org/acme/api/pull-requests/1234\n"));
    try testing.expect(std.mem.indexOf(u8, p, "$BITBUCKET_ACCESS_TOKEN") != null);
    try testing.expect(std.mem.indexOf(u8, p, "merge_strategy: squash") != null);
    try testing.expect(std.mem.indexOf(u8, p, "bug/fix-login -> main") != null);
    try testing.expect(std.mem.indexOf(u8, p, "title: Fix the login redirect") != null);
    // The pane reads the session's last line back onto the button, so
    // the prompt has to ask for one it can read.
    try testing.expect(std.mem.indexOf(u8, p, "LAST line") != null);
    try testing.expect(std.mem.endsWith(u8, p, "  refused <why>"));
    // The token's VALUE is never in the prompt — only the name of the
    // variable that holds it.
    try testing.expect(std.mem.indexOf(u8, p, "ATCTT") == null);
}
