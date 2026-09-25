//! The one table of bindings. Dispatch reads it, the hint row under the
//! list reads it, the `?` key sheet reads it and the row menus name
//! their actions from it — so no hint can drift from what a key does,
//! which is the fault the reference's hand-written footer had.
//!
//! The keys are the reference's (`keys.rs`): `q` quits, `r` refreshes,
//! `j`/`k` and the arrows move, `enter`/`space` toggle a tree row,
//! `o` opens on the web, `y` copies the URL, `d` the detail, `a` the
//! approval, `m` open↔merged, `tab` the next tab, `1`–`9` a tab by
//! number, `E`/`C` (and the reference's `e`/`c`) open / close every repo, `x` hides one, `H` un-hides
//! them all, `s` cycles the scope, `alt+↑`/`alt+↓` reorder, `ctrl+u` /
//! `ctrl+d` scroll the detail. Added here: `?` for this sheet, `/`
//! for the filter, `esc` to leave either, and the toolbar's chips —
//! `S` `U` `T` `A` on a pull-request tab (Status, aUthor, Target
//! branch, the All / reviewing / awaiting selector), `U` `B` `P` `S`
//! `T` on a pipelines tab (rUn by, Branch, Pipeline type, Status,
//! Trigger type) — so every chip has a key as well as a click.

const std = @import("std");
const cfg = @import("config.zig");
const sdk = @import("mnml_sdk");

pub const Action = enum {
    quit,
    refresh,
    refresh_full,
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    /// Enter / space on a tree row: expand or collapse it; on a
    /// `Show more (N)` row, lift the filter; on a flat row, open.
    activate,
    open_web,
    yank_url,
    next_tab,
    prev_tab,
    /// `m` — the reference's open↔merged toggle (the next tab).
    toggle_merged,
    tab_1,
    tab_2,
    tab_3,
    tab_4,
    tab_5,
    tab_6,
    tab_7,
    tab_8,
    tab_9,
    toggle_detail,
    detail_up,
    detail_down,
    toggle_approval,
    /// The `show:` chip — all → reviewing → awaiting me → all.
    cycle_show,
    /// The PR family's other three chips: each opens its picker.
    filter_status,
    filter_author,
    filter_target,
    /// The pipelines family's five chips: each opens its picker.
    filter_run_by,
    filter_branch,
    filter_type,
    filter_pstatus,
    filter_trigger,
    /// Merge the focused pull request — through a Claude Code session,
    /// and only when it may.
    merge_pr,
    expand,
    collapse,
    expand_all,
    collapse_all,
    hide_repo,
    unhide_all,
    cycle_scope,
    reorder_up,
    reorder_down,
    filter,
    help,
    escape,
    /// Stop waiting out a 429's pause (the budget chip's click, too).
    cancel_wait,
    /// Dry run on / off: nothing is sent while it is on.
    toggle_dry_run,

    /// Which tab, for the numbered actions.
    pub fn tabNumber(a: Action) ?u8 {
        const i = @intFromEnum(a);
        const first = @intFromEnum(Action.tab_1);
        if (i < first or i > @intFromEnum(Action.tab_9)) return null;
        return @intCast(i - first);
    }
};

/// Where a binding applies.
pub const Scope = enum {
    any,
    /// The two workspace trees.
    tree,
    /// A row that has a URL (a PR, a branch, a pipeline, a repo header).
    row,
    /// While the detail is open.
    detail,
    /// A pull-request tab (the two workspace trees, a flat PR list).
    prs,
    /// A pipelines tab.
    pipelines,
    /// A row, on a pull-request tab — what only a pull request has
    /// (its merge).
    pr_row,
    /// The detail open, on a pull-request tab.
    pr_detail,
};

pub const Binding = struct {
    /// The specs mnml sends (`src/core/key.zig`'s grammar), first is
    /// the one the hint shows.
    keys: []const []const u8,
    action: Action,
    /// What the sheet says.
    title: []const u8,
    scope: Scope = .any,
    /// Painted on the hint row (in table order) when it applies.
    hint: bool = false,
    /// The sheet's section.
    section: []const u8 = "navigation",
};

pub const table = [_]Binding{
    .{ .keys = &.{ "down", "j" }, .action = .down, .title = "move down", .hint = true },
    .{ .keys = &.{ "up", "k" }, .action = .up, .title = "move up" },
    .{ .keys = &.{"pagedown"}, .action = .page_down, .title = "page down" },
    .{ .keys = &.{"pageup"}, .action = .page_up, .title = "page up" },
    .{ .keys = &.{ "home", "g" }, .action = .home, .title = "first row" },
    .{ .keys = &.{ "end", "shift+g" }, .action = .end, .title = "last row" },
    .{ .keys = &.{ "enter", "space" }, .action = .activate, .title = "expand / collapse the row", .scope = .tree, .hint = true, .section = "tree" },
    .{ .keys = &.{ "right", "l" }, .action = .expand, .title = "expand, or step into the first child", .scope = .tree, .section = "tree" },
    .{ .keys = &.{ "left", "h" }, .action = .collapse, .title = "collapse, or step up to the repo", .scope = .tree, .section = "tree" },
    .{ .keys = &.{ "shift+e", "e" }, .action = .expand_all, .title = "expand every repo", .scope = .tree, .section = "tree" },
    .{ .keys = &.{ "shift+c", "c" }, .action = .collapse_all, .title = "collapse every repo", .scope = .tree, .section = "tree" },
    .{ .keys = &.{"x"}, .action = .hide_repo, .title = "hide this repo (persists)", .scope = .tree, .section = "tree" },
    .{ .keys = &.{"shift+h"}, .action = .unhide_all, .title = "un-hide every repo (persists)", .scope = .tree, .section = "tree" },
    .{ .keys = &.{"s"}, .action = .cycle_scope, .title = "cycle the scope: all → recent → explicit (persists)", .scope = .tree, .section = "tree" },
    .{ .keys = &.{"alt+up"}, .action = .reorder_up, .title = "move this repo up (persists)", .scope = .tree, .section = "tree" },
    .{ .keys = &.{"alt+down"}, .action = .reorder_down, .title = "move this repo down (persists)", .scope = .tree, .section = "tree" },
    .{ .keys = &.{"o"}, .action = .open_web, .title = "open on the web", .scope = .row, .hint = true, .section = "row" },
    .{ .keys = &.{"y"}, .action = .yank_url, .title = "copy the URL", .scope = .row, .section = "row" },
    .{ .keys = &.{"d"}, .action = .toggle_detail, .title = "the pull request's detail", .scope = .prs, .hint = true, .section = "row" },
    .{ .keys = &.{"a"}, .action = .toggle_approval, .title = "approve / withdraw the approval", .scope = .pr_detail, .hint = true, .section = "row" },
    .{ .keys = &.{"ctrl+d"}, .action = .detail_down, .title = "scroll the detail down", .scope = .detail, .section = "row" },
    .{ .keys = &.{"ctrl+u"}, .action = .detail_up, .title = "scroll the detail up", .scope = .detail, .section = "row" },
    .{ .keys = &.{"shift+m"}, .action = .merge_pr, .title = "merge (through Claude Code)", .scope = .pr_row, .section = "row" },
    .{ .keys = &.{"shift+s"}, .action = .filter_status, .title = "status: Open / Draft / Merged / Declined", .scope = .prs, .section = "filters" },
    .{ .keys = &.{"shift+u"}, .action = .filter_author, .title = "author: all / me / one seen", .scope = .prs, .section = "filters" },
    .{ .keys = &.{"shift+t"}, .action = .filter_target, .title = "target branch", .scope = .prs, .section = "filters" },
    .{ .keys = &.{"shift+a"}, .action = .cycle_show, .title = "show: all → reviewing → awaiting me", .scope = .prs, .section = "filters" },
    .{ .keys = &.{"shift+u"}, .action = .filter_run_by, .title = "run by", .scope = .pipelines, .section = "filters" },
    .{ .keys = &.{"shift+b"}, .action = .filter_branch, .title = "branch", .scope = .pipelines, .section = "filters" },
    .{ .keys = &.{"shift+p"}, .action = .filter_type, .title = "pipeline type", .scope = .pipelines, .section = "filters" },
    .{ .keys = &.{"shift+s"}, .action = .filter_pstatus, .title = "status: successful / failed / …", .scope = .pipelines, .section = "filters" },
    .{ .keys = &.{"shift+t"}, .action = .filter_trigger, .title = "trigger type", .scope = .pipelines, .section = "filters" },
    .{ .keys = &.{"m"}, .action = .toggle_merged, .title = "open ↔ merged", .scope = .prs, .hint = true, .section = "tabs" },
    .{ .keys = &.{"tab"}, .action = .next_tab, .title = "next tab", .section = "tabs" },
    .{ .keys = &.{ "backtab", "shift+tab" }, .action = .prev_tab, .title = "previous tab", .section = "tabs" },
    .{ .keys = &.{"1"}, .action = .tab_1, .title = "tab 1", .section = "tabs" },
    .{ .keys = &.{"2"}, .action = .tab_2, .title = "tab 2", .section = "tabs" },
    .{ .keys = &.{"3"}, .action = .tab_3, .title = "tab 3", .section = "tabs" },
    .{ .keys = &.{"4"}, .action = .tab_4, .title = "tab 4", .section = "tabs" },
    .{ .keys = &.{"5"}, .action = .tab_5, .title = "tab 5", .section = "tabs" },
    .{ .keys = &.{"6"}, .action = .tab_6, .title = "tab 6", .section = "tabs" },
    .{ .keys = &.{"7"}, .action = .tab_7, .title = "tab 7", .section = "tabs" },
    .{ .keys = &.{"8"}, .action = .tab_8, .title = "tab 8", .section = "tabs" },
    .{ .keys = &.{"9"}, .action = .tab_9, .title = "tab 9", .section = "tabs" },
    .{ .keys = &.{"/"}, .action = .filter, .title = "filter the rows", .section = "pane" },
    .{ .keys = &.{"r"}, .action = .refresh, .title = "refresh this tab", .hint = true, .section = "pane" },
    .{ .keys = &.{"shift+r"}, .action = .refresh_full, .title = "full refresh (ignore every cache)", .section = "pane" },
    .{ .keys = &.{"ctrl+x"}, .action = .cancel_wait, .title = "stop waiting out a rate-limit pause", .section = "pane" },
    .{ .keys = &.{"shift+n"}, .action = .toggle_dry_run, .title = "dry run on / off (nothing is sent)", .section = "pane" },
    .{ .keys = &.{"?"}, .action = .help, .title = "this key sheet", .hint = true, .section = "pane" },
    .{ .keys = &.{"esc"}, .action = .escape, .title = "close the sheet / clear the filter", .section = "pane" },
    .{ .keys = &.{ "q", "ctrl+c" }, .action = .quit, .title = "quit", .hint = true, .section = "pane" },
};

pub const sections = [_][]const u8{ "navigation", "tree", "row", "filters", "tabs", "pane" };

/// What is true of the focused row, for scope checks.
pub const Context = struct {
    on_tree: bool = false,
    on_row: bool = false,
    detail_open: bool = false,
    /// The active tab's family; the chip keys are per family, so `S`
    /// is the Status chip on either and never both.
    family: cfg.Family = .prs,

    pub fn allows(c: Context, scope: Scope) bool {
        return switch (scope) {
            .any => true,
            .tree => c.on_tree,
            .row => c.on_row,
            .detail => c.detail_open,
            .prs => c.family == .prs,
            .pipelines => c.family == .pipelines,
            .pr_row => c.family == .prs and c.on_row,
            .pr_detail => c.family == .prs and c.detail_open,
        };
    }
};

/// mnml spells an upper-case letter `shift+<lower>` and a back-tab
/// `backtab`; the table spells them that way too, so a spec matches
/// as it arrives.
pub fn lookup(spec: []const u8, ctx: Context) ?Action {
    for (&table) |b| {
        if (!ctx.allows(b.scope)) continue;
        for (b.keys) |k| if (std.mem.eql(u8, k, spec)) return b.action;
    }
    return null;
}

pub fn bindingOf(action: Action) ?Binding {
    for (&table) |b| if (b.action == action) return b;
    return null;
}

/// The key a hint or the sheet shows for a spec: `↑`, `Enter`,
/// `Tab`, `Alt+↑`, `Ctrl+D`, or the letter — the family's one spelling
/// (`sdk.pane.keysheet.chord`), the words the Jira pane uses too.
pub fn keyLabel(spec: []const u8) []const u8 {
    return sdk.pane.keysheet.chord(spec);
}

/// The bindings the hint row paints, in table order, for the context.
pub fn hints(ctx: Context, out: []Binding) []const Binding {
    var n: usize = 0;
    for (&table) |b| {
        if (!b.hint or !ctx.allows(b.scope)) continue;
        if (n == out.len) break;
        out[n] = b;
        n += 1;
    }
    return out[0..n];
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "the reference's keys dispatch to their actions, scoped to where they apply" {
    const tree: Context = .{ .on_tree = true, .on_row = true };
    try t.expectEqual(Action.quit, lookup("q", .{}).?);
    try t.expectEqual(Action.quit, lookup("ctrl+c", .{}).?);
    try t.expectEqual(Action.down, lookup("j", .{}).?);
    try t.expectEqual(Action.end, lookup("shift+g", .{}).?);
    try t.expectEqual(Action.unhide_all, lookup("shift+h", tree).?);
    // E / C: the integration tree convention's pair, the one the Jira
    // pane binds; the reference's e / c still work
    // (hunt/findings-2026-09-23/integ-tree-nav-convention.md).
    try t.expectEqual(Action.expand_all, lookup("shift+e", tree).?);
    try t.expectEqual(Action.collapse_all, lookup("shift+c", tree).?);
    try t.expectEqual(Action.expand_all, lookup("e", tree).?);
    try t.expectEqual(Action.collapse_all, lookup("c", tree).?);
    try t.expectEqual(Action.activate, lookup("enter", tree).?);
    try t.expectEqual(Action.expand, lookup("right", tree).?);
    try t.expectEqual(Action.reorder_up, lookup("alt+up", tree).?);
    try t.expectEqual(Action.tab_3, lookup("3", .{}).?);
    try t.expectEqual(@as(?u8, 2), Action.tab_3.tabNumber());
    try t.expect(Action.quit.tabNumber() == null);
    try t.expectEqual(Action.prev_tab, lookup("backtab", .{}).?);
    // Off a tree, the tree keys are not bound: `e` does nothing on a flat list.
    try t.expect(lookup("e", .{}) == null);
    try t.expect(lookup("enter", .{ .on_row = true }) == null);
    // `a` only while the detail is open, as in the reference.
    try t.expect(lookup("a", .{}) == null);
    try t.expectEqual(Action.toggle_approval, lookup("a", .{ .detail_open = true }).?);
    // The chips and the keys are the same doors: a chip nobody can
    // reach from the keyboard is half a feature. Per family — `S` is
    // the Status chip of whichever tab is on.
    try t.expectEqual(Action.cycle_show, lookup("shift+a", .{}).?);
    try t.expectEqual(Action.filter_status, lookup("shift+s", .{ .family = .prs }).?);
    try t.expectEqual(Action.filter_pstatus, lookup("shift+s", .{ .family = .pipelines }).?);
    try t.expectEqual(Action.filter_author, lookup("shift+u", .{}).?);
    try t.expectEqual(Action.filter_run_by, lookup("shift+u", .{ .family = .pipelines }).?);
    try t.expectEqual(Action.filter_target, lookup("shift+t", .{}).?);
    try t.expectEqual(Action.filter_trigger, lookup("shift+t", .{ .family = .pipelines }).?);
    try t.expectEqual(Action.filter_branch, lookup("shift+b", .{ .family = .pipelines }).?);
    try t.expectEqual(Action.filter_type, lookup("shift+p", .{ .family = .pipelines }).?);
    try t.expect(lookup("shift+b", .{}) == null);
    try t.expect(lookup("shift+a", .{ .family = .pipelines }) == null);
    // The button is a convenience; the key is the guarantee. A pane
    // too narrow to paint `[ Merge ]` must still be able to merge.
    try t.expectEqual(Action.merge_pr, lookup("shift+m", .{ .on_row = true }).?);
    // The budget's two keys, the tracker pane's too, on every family.
    try t.expectEqual(Action.cancel_wait, lookup("ctrl+x", .{}).?);
    try t.expectEqual(Action.toggle_dry_run, lookup("shift+n", .{ .family = .pipelines }).?);
    try t.expect(lookup("z", tree) == null);
}

test "a pipelines tab binds and offers only what does something there" {
    // hunt/findings-2026-09-23/integ-bb-pipelines-dead-actions.md: the
    // hint row offered `d detail` (a `(no PR focused)` panel), `m
    // open↔merged` (no merged view) and then `a approve`.
    const pipes: Context = .{ .on_tree = true, .on_row = true, .detail_open = true, .family = .pipelines };
    for ([_][]const u8{ "d", "a", "m", "shift+m" }) |k| try t.expect(lookup(k, pipes) == null);
    var buf: [table.len]Binding = undefined;
    for (hints(pipes, &buf)) |b| switch (b.action) {
        .toggle_detail, .toggle_approval, .toggle_merged, .merge_pr => return error.TestUnexpectedResult,
        else => {},
    };
    // The PR family keeps all four.
    const prs: Context = .{ .on_tree = true, .on_row = true, .detail_open = true, .family = .prs };
    try t.expectEqual(Action.toggle_detail, lookup("d", prs).?);
    try t.expectEqual(Action.toggle_approval, lookup("a", prs).?);
    try t.expectEqual(Action.toggle_merged, lookup("m", prs).?);
    try t.expectEqual(Action.merge_pr, lookup("shift+m", prs).?);
}

test "every action in the table is reachable and the hint row is a subset of it" {
    var seen = std.enums.EnumSet(Action).initEmpty();
    for (&table) |b| seen.insert(b.action);
    inline for (@typeInfo(Action).@"enum".fields) |f| {
        try t.expect(seen.contains(@field(Action, f.name)));
    }
    var buf: [table.len]Binding = undefined;
    const hs = hints(.{ .on_tree = true, .on_row = true, .detail_open = true }, &buf);
    try t.expect(hs.len >= 6);
    try t.expectEqual(Action.down, hs[0].action);
    try t.expectEqual(Action.quit, hs[hs.len - 1].action);
    for (hs) |b| try t.expect(bindingOf(b.action) != null);
    // On a flat list without a detail the tree-only and detail-only hints are gone.
    const flat = hints(.{}, &buf);
    for (flat) |b| try t.expect(b.scope == .any or b.scope == .prs);
    try t.expectEqualStrings("Enter", keyLabel("enter"));
    try t.expectEqualStrings("Alt+↑", keyLabel("alt+up"));
    try t.expectEqualStrings("E", keyLabel("shift+e"));
    try t.expectEqualStrings("q", keyLabel("q"));
}
