//! The bindings — one table, three readers: the key dispatcher, the
//! `?` key sheet, and the hint row under the list. The reference wrote
//! its hint strip by hand, six literal strings that had already drifted
//! from the bindings; here a chord is on the screen because it is in
//! this table, and only then.
//!
//! Keys arrive as mnml spells them (`shift+d` for `D`, `space`,
//! `enter`, `ctrl+d`); the table is written that way too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const sdk = @import("mnml_sdk");

pub const Action = enum {
    quit,
    /// The cascade: selection → filter → detail → quit.
    escape,
    refresh,
    refresh_full,
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    open_browser,
    next_tab,
    prev_tab,
    /// `1`–`9`; the digit is on the key.
    switch_tab,
    toggle_details,
    detail_scroll_up,
    detail_scroll_down,
    filter,
    jql_editor,
    /// The vars editor, on a `jql_editable` tab (the same `E`).
    vars_editor,
    transition,
    watch,
    comment,
    toggle_select,
    assignee,
    fix_version,
    tab_fix_version,
    team,
    action_picker,
    tree_activate,
    tree_expand,
    tree_collapse,
    /// `E` / `C`: every group of the tree open / shut — the integration
    /// tree convention's keys, the same pair the Bitbucket pane binds.
    tree_expand_all,
    tree_collapse_all,
    dispatch_implement,
    dispatch_fix,
    dispatch_triage,
    dispatch_review,
    /// Merge the pull request under the cursor — through a Claude Code
    /// session, and only when it may.
    merge_pr,
    detail_modal,
    card_expand,
    help,
};

/// Where a binding applies. A tab is a tree (Work / Fix Versions), a
/// kanban (Boards) or a flat table (a legacy no-kind tab).
pub const Where = enum { any, tree, kanban, flat, fix_versions, work_or_boards, detail_open, editable_jql, fixed_jql };

pub const Section = enum {
    navigation,
    tabs,
    rows,
    ticket,
    filters,
    dispatch,
    view,

    pub fn title(s: Section) []const u8 {
        return switch (s) {
            .navigation => "navigation",
            .tabs => "tabs",
            .rows => "rows",
            .ticket => "ticket",
            .filters => "filters",
            .dispatch => "dispatch",
            .view => "view",
        };
    }
};

pub const Binding = struct {
    /// The chord as mnml spells it; several spellings share a row.
    keys: []const []const u8,
    action: Action,
    /// What the sheet and the hint row say.
    label: []const u8,
    section: Section,
    where: Where = .any,
    /// On the hint row, in this order (0 = not there).
    hint: u8 = 0,
    /// The hint row's shorter word for the label, when the label is long.
    short: []const u8 = "",
};

pub const bindings = [_]Binding{
    .{ .keys = &.{ "up", "k" }, .action = .up, .label = "up", .section = .navigation },
    .{ .keys = &.{ "down", "j" }, .action = .down, .label = "down", .section = .navigation },
    .{ .keys = &.{"pageup"}, .action = .page_up, .label = "page up", .section = .navigation },
    .{ .keys = &.{"pagedown"}, .action = .page_down, .label = "page down", .section = .navigation },
    .{ .keys = &.{ "home", "g" }, .action = .home, .label = "first row", .section = .navigation },
    .{ .keys = &.{ "end", "shift+g" }, .action = .end, .label = "last row", .section = .navigation },
    .{ .keys = &.{"ctrl+u"}, .action = .detail_scroll_up, .label = "scroll the detail up", .section = .navigation, .where = .detail_open },
    .{ .keys = &.{"ctrl+d"}, .action = .detail_scroll_down, .label = "scroll the detail down", .section = .navigation, .where = .detail_open },
    .{ .keys = &.{"tab"}, .action = .next_tab, .label = "next tab", .section = .tabs },
    .{ .keys = &.{"backtab"}, .action = .prev_tab, .label = "previous tab", .section = .tabs },
    .{ .keys = &.{"1-9"}, .action = .switch_tab, .label = "tab by number", .section = .tabs },
    .{ .keys = &.{ "enter", "space" }, .action = .tree_activate, .label = "fold a group · expand a ticket · open a PR", .section = .rows, .where = .tree },
    .{ .keys = &.{ "right", "l" }, .action = .tree_expand, .label = "expand", .section = .rows, .where = .tree },
    .{ .keys = &.{ "left", "h" }, .action = .tree_collapse, .label = "collapse", .section = .rows, .where = .tree },
    .{ .keys = &.{"shift+e"}, .action = .tree_expand_all, .label = "expand every group", .section = .rows, .where = .tree },
    .{ .keys = &.{"shift+c"}, .action = .tree_collapse_all, .label = "collapse every group", .section = .rows, .where = .tree },
    .{ .keys = &.{"shift+."}, .action = .card_expand, .label = "expand the card", .section = .rows, .where = .kanban, .hint = 6 },
    .{ .keys = &.{ "enter", "o" }, .action = .open_browser, .label = "open in the browser", .section = .rows, .where = .flat },
    .{ .keys = &.{"o"}, .action = .open_browser, .label = "open in the browser", .section = .rows, .where = .tree },
    .{ .keys = &.{"o"}, .action = .open_browser, .label = "open in the browser", .section = .rows, .where = .kanban },
    .{ .keys = &.{"space"}, .action = .toggle_select, .label = "select for a bulk action", .section = .rows, .where = .flat, .hint = 3, .short = "select" },
    .{ .keys = &.{"space"}, .action = .toggle_select, .label = "select for a bulk action", .section = .rows, .where = .kanban, .hint = 3, .short = "select" },
    .{ .keys = &.{"shift+s"}, .action = .toggle_select, .label = "select for a bulk action", .section = .rows, .where = .tree, .hint = 3, .short = "select" },
    .{ .keys = &.{"t"}, .action = .transition, .label = "transition", .section = .ticket, .hint = 1 },
    .{ .keys = &.{"a"}, .action = .assignee, .label = "assignee", .section = .ticket, .hint = 2 },
    .{ .keys = &.{"f"}, .action = .fix_version, .label = "fix version", .section = .ticket, .where = .work_or_boards, .hint = 4 },
    .{ .keys = &.{"shift+f"}, .action = .fix_version, .label = "fix version on the ticket", .section = .ticket, .where = .fix_versions },
    .{ .keys = &.{"w"}, .action = .watch, .label = "watch / unwatch", .section = .ticket },
    .{ .keys = &.{"c"}, .action = .comment, .label = "comment", .section = .ticket, .where = .detail_open, .hint = 6 },
    .{ .keys = &.{"d"}, .action = .toggle_details, .label = "detail pane", .section = .view, .hint = 5, .short = "detail" },
    .{ .keys = &.{"shift+d"}, .action = .detail_modal, .label = "detail modal", .section = .view },
    .{ .keys = &.{"."}, .action = .action_picker, .label = "actions", .section = .dispatch, .hint = 7 },
    .{ .keys = &.{"shift+i"}, .action = .dispatch_implement, .label = "dispatch: implement", .section = .dispatch, .where = .fix_versions },
    .{ .keys = &.{"shift+x"}, .action = .dispatch_fix, .label = "dispatch: fix", .section = .dispatch, .where = .fix_versions },
    .{ .keys = &.{"shift+t"}, .action = .dispatch_triage, .label = "dispatch: triage", .section = .dispatch, .where = .fix_versions },
    .{ .keys = &.{"shift+v"}, .action = .dispatch_review, .label = "dispatch: review the PR", .section = .dispatch, .where = .fix_versions },
    .{ .keys = &.{"shift+m"}, .action = .merge_pr, .label = "merge the PR (through Claude Code)", .section = .dispatch, .where = .fix_versions },
    .{ .keys = &.{"/"}, .action = .filter, .label = "filter", .section = .filters, .hint = 8 },
    // `J` — the JQL. `E` / `C` are the tree convention's expand /
    // collapse every group, on both integration panes.
    .{ .keys = &.{"shift+j"}, .action = .vars_editor, .label = "edit the tab's vars", .section = .filters, .where = .editable_jql },
    .{ .keys = &.{"shift+j"}, .action = .jql_editor, .label = "edit the JQL", .section = .filters, .where = .fixed_jql },
    .{ .keys = &.{"f"}, .action = .tab_fix_version, .label = "switch the release", .section = .filters, .where = .fix_versions, .hint = 4 },
    .{ .keys = &.{"shift+v"}, .action = .tab_fix_version, .label = "switch the fix version", .section = .filters, .where = .work_or_boards },
    .{ .keys = &.{"shift+t"}, .action = .team, .label = "team", .section = .filters, .where = .work_or_boards },
    .{ .keys = &.{"r"}, .action = .refresh, .label = "refresh", .section = .view, .hint = 9 },
    .{ .keys = &.{"shift+r"}, .action = .refresh_full, .label = "full refresh", .section = .view },
    .{ .keys = &.{ "?", "f1" }, .action = .help, .label = "keys", .section = .view, .hint = 10 },
    .{ .keys = &.{"esc"}, .action = .escape, .label = "clear the selection · the filter · close the detail", .section = .view },
    .{ .keys = &.{ "q", "ctrl+c" }, .action = .quit, .label = "quit", .section = .view },
};

pub const TabShape = enum { tree, kanban, flat };

pub const Context = struct {
    shape: TabShape,
    fix_versions: bool,
    /// A `jql_editable` tab, where `E` edits the vars rather than the
    /// JQL those vars fill in.
    editable_jql: bool = false,
    detail_open: bool,
};

fn applies(b: Binding, ctx: Context) bool {
    return switch (b.where) {
        .any => true,
        .tree => ctx.shape == .tree,
        .kanban => ctx.shape == .kanban,
        .flat => ctx.shape == .flat,
        .fix_versions => ctx.fix_versions,
        .work_or_boards => !ctx.fix_versions,
        .detail_open => ctx.detail_open,
        .editable_jql => ctx.editable_jql,
        .fixed_jql => !ctx.editable_jql,
    };
}

/// A digit key's tab index (0-based), or null.
pub fn tabDigit(key: []const u8) ?u8 {
    if (key.len != 1 or key[0] < '1' or key[0] > '9') return null;
    return key[0] - '1';
}

/// The action a key means in `ctx`. The first matching row wins, so a
/// context-specific row placed before a general one takes it.
pub fn resolve(key: []const u8, ctx: Context) ?Action {
    if (tabDigit(key) != null) return .switch_tab;
    for (bindings) |b| {
        if (!applies(b, ctx)) continue;
        for (b.keys) |k| if (std.mem.eql(u8, k, key)) return b.action;
    }
    return null;
}

/// The bindings that apply, in table order — the key sheet's rows.
pub fn active(arena: Allocator, ctx: Context) Allocator.Error![]const Binding {
    var out: std.ArrayList(Binding) = .empty;
    for (bindings) |b| if (applies(b, ctx)) try out.append(arena, b);
    return out.toOwnedSlice(arena);
}

/// The hint row's bindings, by their `hint` rank.
pub fn hints(arena: Allocator, ctx: Context) Allocator.Error![]const Binding {
    var out: std.ArrayList(Binding) = .empty;
    var rank: u8 = 1;
    while (rank <= 10) : (rank += 1) {
        for (bindings) |b| if (b.hint == rank and applies(b, ctx)) {
            try out.append(arena, b);
            break;
        };
    }
    return out.toOwnedSlice(arena);
}

/// The chord as the sheet and the hint row print it: `D` for
/// `shift+d`, `Space`, `Shift+Tab` — the family's one spelling
/// (`sdk.pane.keysheet.chord`). `buf` is kept for the callers.
pub fn displayKey(buf: []u8, key: []const u8) []const u8 {
    _ = buf;
    return sdk.pane.keysheet.chord(key);
}

/// `t transition · a assignee · …` from the hint rank, on `arena`.
pub fn hintRow(arena: Allocator, ctx: Context) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (try hints(arena, ctx)) |b| {
        if (out.items.len > 0) try out.appendSlice(arena, " · ");
        var buf: [16]u8 = undefined;
        try out.appendSlice(arena, displayKey(&buf, b.keys[0]));
        try out.append(arena, ' ');
        try out.appendSlice(arena, if (b.short.len > 0) b.short else b.label);
    }
    return out.toOwnedSlice(arena);
}

/// The static rows of a modal's help, shown in the sheet's last
/// section so a user inside a picker can still read them.
pub const modal_rows = [_]struct { keys: []const u8, label: []const u8 }{
    .{ .keys = "type ↑↓ Enter Esc", .label = "picker: filter · move · commit · cancel (Space toggles a multi-select row)" },
    .{ .keys = "1-9 ↑↓ Enter Esc", .label = "transition picker: jump · move · commit · cancel" },
    .{ .keys = "j k PgUp PgDn Esc", .label = "detail modal: scroll · close" },
    .{ .keys = "Enter Enter Ctrl+S Esc", .label = "comment: newline · an empty line or Ctrl+S sends · cancel" },
    .{ .keys = "Ctrl+A/E Alt+←/→", .label = "JQL editor: line ends · words; Ctrl+U/K/W kill; Enter runs, Esc cancels" },
    .{ .keys = "↑↓ ⏎ a d s Esc", .label = "vars editor: move · edit a value · add · remove · save (Ctrl+S too) · cancel" },
};

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const tree_ctx: Context = .{ .shape = .tree, .fix_versions = false, .detail_open = false };
const editable_ctx: Context = .{ .shape = .tree, .fix_versions = false, .editable_jql = true, .detail_open = false };
const fixv_ctx: Context = .{ .shape = .tree, .fix_versions = true, .detail_open = false };
const kanban_ctx: Context = .{ .shape = .kanban, .fix_versions = false, .detail_open = false };
const flat_ctx: Context = .{ .shape = .flat, .fix_versions = false, .detail_open = false };

test "the reference's chords resolve per context: f / F / V / T / space / > / c" {
    try testing.expectEqual(Action.fix_version, resolve("f", tree_ctx).?);
    try testing.expectEqual(Action.tab_fix_version, resolve("f", fixv_ctx).?);
    try testing.expectEqual(Action.fix_version, resolve("shift+f", fixv_ctx).?);
    try testing.expectEqual(Action.tab_fix_version, resolve("shift+v", kanban_ctx).?);
    try testing.expectEqual(Action.dispatch_review, resolve("shift+v", fixv_ctx).?);
    // The chip is a convenience; the key is the guarantee.
    try testing.expectEqual(Action.merge_pr, resolve("shift+m", fixv_ctx).?);
    try testing.expectEqual(Action.team, resolve("shift+t", tree_ctx).?);
    try testing.expectEqual(Action.dispatch_triage, resolve("shift+t", fixv_ctx).?);
    try testing.expectEqual(Action.tree_activate, resolve("space", tree_ctx).?);
    try testing.expectEqual(Action.toggle_select, resolve("space", flat_ctx).?);
    try testing.expectEqual(Action.toggle_select, resolve("space", kanban_ctx).?);
    try testing.expectEqual(Action.toggle_select, resolve("shift+s", tree_ctx).?);
    try testing.expectEqual(Action.card_expand, resolve("shift+.", kanban_ctx).?);
    try testing.expect(resolve("shift+.", tree_ctx) == null);
    try testing.expect(resolve("c", tree_ctx) == null);
    try testing.expectEqual(Action.comment, resolve("c", .{ .shape = .tree, .fix_versions = false, .detail_open = true }).?);
    try testing.expectEqual(Action.open_browser, resolve("enter", flat_ctx).?);
    try testing.expectEqual(Action.tree_activate, resolve("enter", tree_ctx).?);
    try testing.expectEqual(Action.switch_tab, resolve("3", tree_ctx).?);
    try testing.expectEqual(@as(u8, 2), tabDigit("3").?);
    try testing.expect(tabDigit("0") == null);
    try testing.expectEqual(Action.help, resolve("?", kanban_ctx).?);
    try testing.expectEqual(Action.quit, resolve("ctrl+c", kanban_ctx).?);
    try testing.expect(resolve("z", kanban_ctx) == null);
    // J is the JQL editor everywhere but a jql_editable tab, where the
    // JQL is the user's own text and the vars are the part worth typing.
    try testing.expectEqual(Action.jql_editor, resolve("shift+j", tree_ctx).?);
    try testing.expectEqual(Action.vars_editor, resolve("shift+j", editable_ctx).?);
    try testing.expectEqual(Action.jql_editor, resolve("shift+j", kanban_ctx).?);
    // E / C: the tree convention's expand / collapse every group
    // (hunt/findings-2026-09-23/integ-tree-nav-convention.md).
    try testing.expectEqual(Action.tree_expand_all, resolve("shift+e", tree_ctx).?);
    try testing.expectEqual(Action.tree_collapse_all, resolve("shift+c", tree_ctx).?);
    try testing.expect(resolve("shift+e", kanban_ctx) == null);
    var saw_jql = false;
    for (bindings) |b| if (b.action == .jql_editor and applies(b, editable_ctx)) {
        saw_jql = true;
    };
    try testing.expect(!saw_jql);
}

test "the hint row and the sheet are read from the table, so a chord cannot drift out of them" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const row = try hintRow(a.allocator(), tree_ctx);
    try testing.expectEqualStrings("t transition · a assignee · S select · f fix version · d detail · . actions · / filter · r refresh · ? keys", row);
    const fixv = try hintRow(a.allocator(), fixv_ctx);
    try testing.expect(std.mem.indexOf(u8, fixv, "f switch the release") != null);
    const kb = try hintRow(a.allocator(), kanban_ctx);
    try testing.expect(std.mem.indexOf(u8, kb, "Space select") != null and std.mem.indexOf(u8, kb, "> expand the card") != null);
    // Every action on the hint row resolves to itself.
    for (try hints(a.allocator(), tree_ctx)) |b| try testing.expectEqual(b.action, resolve(b.keys[0], tree_ctx).?);
    // The sheet lists every row that applies and none that does not.
    const sheet = try active(a.allocator(), fixv_ctx);
    var saw_implement = false;
    var saw_team = false;
    for (sheet) |b| {
        if (b.action == .dispatch_implement) saw_implement = true;
        if (b.action == .team) saw_team = true;
    }
    try testing.expect(saw_implement and !saw_team);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("D", displayKey(&buf, "shift+d"));
    try testing.expectEqualStrings(">", displayKey(&buf, "shift+."));
    try testing.expectEqualStrings("Shift+Tab", displayKey(&buf, "backtab"));
}

/// The first binding for an action, so a click on a hint or a key-sheet
/// row can spell the chord the action would have come in as.
pub fn bindingOf(action: Action) ?Binding {
    for (bindings) |b| if (b.action == action) return b;
    return null;
}
