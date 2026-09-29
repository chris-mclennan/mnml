//! The kanban board — four columns by status family, the cards laid
//! out as the reference draws them (a key line, the summary wrapped,
//! the assignee, the label chips when expanded, the action buttons, a
//! blank line), and the per-column scroll. Pure: the app hands in the
//! tickets and the mask, gets back what to paint and where each card
//! and chevron landed, so a click can be routed by rect.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const text = @import("text.zig");
const dispatch = @import("dispatch.zig");

const Issue = model.Issue;

pub const Col = enum(u8) {
    todo = 0,
    in_progress = 1,
    testing = 2,
    done = 3,

    pub fn title(c: Col) []const u8 {
        return switch (c) {
            .todo => "To Do",
            .in_progress => "In Progress",
            .testing => "Testing",
            .done => "Done",
        };
    }

    /// The reference's bucketing by status name; anything unknown is
    /// In Progress so it is seen rather than hidden.
    pub fn of(status: []const u8) Col {
        const todo = [_][]const u8{ "to do", "backlog", "open", "reopened", "selected for development" };
        const done = [_][]const u8{ "done", "closed", "resolved", "released" };
        const testing_ = [_][]const u8{ "testing", "in pr review", "in review", "qa", "ready for qa", "code review" };
        for (todo) |s| if (std.ascii.eqlIgnoreCase(status, s)) return .todo;
        for (done) |s| if (std.ascii.eqlIgnoreCase(status, s)) return .done;
        for (testing_) |s| if (std.ascii.eqlIgnoreCase(status, s)) return .testing;
        return .in_progress;
    }
};

pub const count = 4;

/// The ticket indices per column, in fetch (rank) order.
pub fn bucket(arena: Allocator, issues: []const Issue, visible: ?[]const bool) Allocator.Error![count][]const usize {
    var lists: [count]std.ArrayList(usize) = .{ .empty, .empty, .empty, .empty };
    for (issues, 0..) |iss, i| {
        if (visible) |m| if (!m[i]) continue;
        try lists[@intFromEnum(Col.of(iss.status))].append(arena, i);
    }
    var out: [count][]const usize = undefined;
    for (&lists, 0..) |*l, k| out[k] = try l.toOwnedSlice(arena);
    return out;
}

/// The column the cursor's ticket is in (In Progress when there is none).
pub fn colOf(issues: []const Issue, selected: usize) Col {
    if (selected >= issues.len) return .in_progress;
    return Col.of(issues[selected].status);
}

pub const CardLine = union(enum) {
    /// `▶ <glyph> KEY` — the first line, the click target for expand.
    head,
    summary: []const u8,
    assignee: []const u8,
    labels,
    /// A line of `(click card for full details)`, wrapped to the card.
    hint: []const u8,
    actions: []const dispatch.Button,
    blank,
};

pub const hint_text = "(click card for full details)";

pub const Card = struct {
    issue_idx: usize,
    lines: []const CardLine,
};

/// The lines of one card at `inner_w` cells.
pub fn layoutCard(arena: Allocator, issue_idx: usize, iss: Issue, expanded: bool, inner_w: u16) Allocator.Error!Card {
    var lines: std.ArrayList(CardLine) = .empty;
    try lines.append(arena, .head);
    const wrap_w: u16 = @max(inner_w -| 4, 10);
    const wrapped = try text.wrap(arena, iss.summary, wrap_w);
    for (wrapped) |w| try lines.append(arena, .{ .summary = w });
    if (iss.assignee) |a| if (a.display_name.len > 0) try lines.append(arena, .{ .assignee = a.display_name });
    if (expanded and iss.labels.len > 0) try lines.append(arena, .labels);
    if (expanded) for (try text.wrap(arena, hint_text, wrap_w)) |l| try lines.append(arena, .{ .hint = l });
    const buttons = dispatch.buttonsForTicket(iss);
    if (buttons.len > 0) try lines.append(arena, .{ .actions = buttons });
    try lines.append(arena, .blank);
    return .{ .issue_idx = issue_idx, .lines = try lines.toOwnedSlice(arena) };
}

/// The type glyph and its plain twin for the card's key line.
pub fn typeGlyph(issuetype: []const u8, ascii: bool) []const u8 {
    if (std.ascii.eqlIgnoreCase(issuetype, "bug")) return if (ascii) "B" else "\u{F188}";
    if (std.ascii.eqlIgnoreCase(issuetype, "story")) return if (ascii) "S" else "\u{F02D}";
    if (std.ascii.eqlIgnoreCase(issuetype, "task")) return if (ascii) "T" else "\u{F0139}";
    if (std.ascii.eqlIgnoreCase(issuetype, "epic")) return if (ascii) "E" else "\u{F0E7}";
    if (std.ascii.eqlIgnoreCase(issuetype, "sub-task") or std.ascii.eqlIgnoreCase(issuetype, "subtask")) return if (ascii) "s" else "\u{F149}";
    if (std.ascii.eqlIgnoreCase(issuetype, "spike")) return if (ascii) "K" else "\u{F0EB}";
    return if (ascii) "-" else "\u{F02B}";
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "statuses bucket into the four columns, unknown ones into In Progress" {
    try testing.expectEqual(Col.todo, Col.of("To Do"));
    try testing.expectEqual(Col.todo, Col.of("Selected for Development"));
    try testing.expectEqual(Col.testing, Col.of("In PR Review"));
    try testing.expectEqual(Col.testing, Col.of("QA"));
    try testing.expectEqual(Col.done, Col.of("Released"));
    try testing.expectEqual(Col.in_progress, Col.of("Agent In Progress"));
    try testing.expectEqual(Col.in_progress, Col.of(""));
    try testing.expectEqualStrings("In Progress", Col.in_progress.title());
}

test "bucket keeps rank order and honours the mask; colOf follows the cursor" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const issues = [_]Issue{
        .{ .key = "ENG-1", .status = "To Do" },
        .{ .key = "ENG-2", .status = "Testing" },
        .{ .key = "ENG-3", .status = "To Do" },
        .{ .key = "ENG-4", .status = "Done" },
    };
    const b = try bucket(a.allocator(), &issues, null);
    try testing.expectEqual(@as(usize, 2), b[0].len);
    try testing.expectEqual(@as(usize, 2), b[0][1]);
    try testing.expectEqual(@as(usize, 1), b[2].len);
    try testing.expectEqual(@as(usize, 0), b[1].len);
    const mask = [_]bool{ false, true, true, true };
    try testing.expectEqual(@as(usize, 1), (try bucket(a.allocator(), &issues, &mask))[0].len);
    try testing.expectEqual(Col.done, colOf(&issues, 3));
    try testing.expectEqual(Col.in_progress, colOf(&issues, 9));
}

test "a card is a head, the wrapped summary, the assignee, the actions and a blank; expanded adds labels and the hint" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const iss: Issue = .{ .key = "ENG-1", .status = "To Do", .issuetype = "Story", .summary = "Reporting API > Export > Create Download returns 500", .assignee = .{ .display_name = "Chris" }, .labels = &.{"admin"} };
    const c = try layoutCard(a.allocator(), 0, iss, false, 28);
    try testing.expect(c.lines[0] == .head);
    try testing.expect(c.lines[1] == .summary);
    try testing.expect(c.lines[c.lines.len - 1] == .blank);
    var saw_actions = false;
    var saw_labels = false;
    for (c.lines) |l| {
        if (l == .actions) saw_actions = true;
        if (l == .labels) saw_labels = true;
    }
    try testing.expect(saw_actions and !saw_labels);
    const e = try layoutCard(a.allocator(), 0, iss, true, 28);
    var saw_hint = false;
    for (e.lines) |l| {
        if (l == .labels) saw_labels = true;
        if (l == .hint) saw_hint = true;
    }
    try testing.expect(saw_labels and saw_hint);
    try testing.expect(e.lines.len > c.lines.len);
    try testing.expectEqualStrings("B", typeGlyph("Bug", true));
    try testing.expectEqualStrings("\u{F02D}", typeGlyph("story", false));
}
