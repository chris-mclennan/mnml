//! The two picker shapes the reference has: the field picker (a typed
//! filter over `(id, label)` rows, single- or multi-select, one kind
//! per surface — assignee, fix version, team, tab fix version, action,
//! sprint, quick filters, type, label, assignees, board, epic) and the
//! transition picker (the issue's transitions, `1`–`9` jumps). State
//! only; the app decides what a commit does and the screen paints.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const text = @import("text.zig");

pub const Kind = enum {
    assignee,
    fix_version,
    team,
    tab_fix_version,
    action,
    sprint,
    quick_filter,
    issue_type,
    label,
    assignees,
    board,
    epic,

    pub fn multi(k: Kind) bool {
        return k == .quick_filter or k == .assignees or k == .epic;
    }

    /// The box title, the reference's words.
    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .assignee => "set assignee",
            .fix_version => "assign fixVersion on ticket",
            .team => "filter kanban by team",
            .tab_fix_version => "switch tab view to fixVersion",
            .action => "actions",
            .sprint => "switch sprint",
            .quick_filter => "toggle quick filters (Space)",
            .issue_type => "set type",
            .label => "set label",
            .assignees => "filter by assignees (Space toggles)",
            .board => "switch board",
            .epic => "filter by epic (Space toggles)",
        };
    }
};

pub const Item = struct { id: []const u8, label: []const u8 };

pub const FieldPicker = struct {
    gpa: Allocator,
    /// Owns the items and the multi-select keys.
    owned: std.heap.ArenaAllocator,
    kind: Kind,
    items: []const Item = &.{},
    loaded: bool = false,
    error_text: []const u8 = "",
    filter: std.ArrayList(u8) = .empty,
    /// Index into `items`.
    selected: usize = 0,
    /// The multi-select set, by id.
    multi: std.StringHashMapUnmanaged(void) = .empty,
    /// How many tickets the commit acts on (the title's `× N`).
    targets: usize = 1,
    /// The focused ticket's key, for the fix-version title.
    focused_key: []const u8 = "",

    pub fn init(gpa: Allocator, kind: Kind) FieldPicker {
        return .{ .gpa = gpa, .owned = std.heap.ArenaAllocator.init(gpa), .kind = kind };
    }

    pub fn deinit(p: *FieldPicker) void {
        p.filter.deinit(p.gpa);
        p.multi.deinit(p.gpa);
        p.owned.deinit();
        p.* = undefined;
    }

    pub fn arena(p: *FieldPicker) Allocator {
        return p.owned.allocator();
    }

    /// Copies the rows in; marks the picker loaded.
    pub fn setItems(p: *FieldPicker, items: []const Item) Allocator.Error!void {
        const a = p.owned.allocator();
        const copy = try a.alloc(Item, items.len);
        for (items, copy) |src, *dst| dst.* = .{ .id = try a.dupe(u8, src.id), .label = try a.dupe(u8, src.label) };
        p.items = copy;
        p.loaded = true;
        if (p.selected >= p.items.len) p.selected = 0;
    }

    pub fn fail(p: *FieldPicker, message: []const u8) Allocator.Error!void {
        p.error_text = try p.owned.allocator().dupe(u8, message);
        p.loaded = true;
    }

    /// Pre-select the row whose id is `id`.
    pub fn selectId(p: *FieldPicker, id: []const u8) void {
        for (p.items, 0..) |it, i| if (std.mem.eql(u8, it.id, id)) {
            p.selected = i;
            return;
        };
    }

    pub fn seedMulti(p: *FieldPicker, ids: []const []const u8) Allocator.Error!void {
        for (ids) |id| try p.multi.put(p.gpa, try p.owned.allocator().dupe(u8, id), {});
    }

    pub fn isChecked(p: *const FieldPicker, id: []const u8) bool {
        return p.multi.contains(id);
    }

    pub fn toggleSelected(p: *FieldPicker) Allocator.Error!void {
        if (!p.kind.multi() or p.selected >= p.items.len) return;
        const id = p.items[p.selected].id;
        if (p.multi.remove(id)) return;
        try p.multi.put(p.gpa, id, {});
    }

    /// The checked ids, in item order.
    pub fn checked(p: *const FieldPicker, out_arena: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (p.items) |it| if (p.multi.contains(it.id)) try out.append(out_arena, try out_arena.dupe(u8, it.id));
        return out.toOwnedSlice(out_arena);
    }

    /// The rows the filter keeps, as indices into `items`.
    pub fn visible(p: *const FieldPicker, out_arena: Allocator) Allocator.Error![]const usize {
        var out: std.ArrayList(usize) = .empty;
        for (p.items, 0..) |it, i| {
            if (p.filter.items.len == 0 or text.containsIgnoreCase(it.label, p.filter.items)) try out.append(out_arena, i);
        }
        return out.toOwnedSlice(out_arena);
    }

    pub fn insert(p: *FieldPicker, ch: []const u8) Allocator.Error!void {
        try p.filter.appendSlice(p.gpa, ch);
        try p.clamp();
    }

    pub fn backspace(p: *FieldPicker) Allocator.Error!void {
        if (p.filter.items.len == 0) return;
        var n: usize = 1;
        while (n < p.filter.items.len and (p.filter.items[p.filter.items.len - n] & 0xC0) == 0x80) : (n += 1) {}
        p.filter.items.len -= n;
        try p.clamp();
    }

    fn clamp(p: *FieldPicker) Allocator.Error!void {
        var a = std.heap.ArenaAllocator.init(p.gpa);
        defer a.deinit();
        const vis = try p.visible(a.allocator());
        if (vis.len == 0) return;
        for (vis) |i| if (i == p.selected) return;
        p.selected = vis[0];
    }

    pub fn move(p: *FieldPicker, delta: i32) Allocator.Error!void {
        var a = std.heap.ArenaAllocator.init(p.gpa);
        defer a.deinit();
        const vis = try p.visible(a.allocator());
        if (vis.len == 0) return;
        var pos: usize = 0;
        for (vis, 0..) |i, k| if (i == p.selected) {
            pos = k;
        };
        const np: i64 = @as(i64, @intCast(pos)) + delta;
        const clamped: usize = @intCast(std.math.clamp(np, 0, @as(i64, @intCast(vis.len)) - 1));
        p.selected = vis[clamped];
    }

    /// The row under the cursor, if the filter shows it.
    pub fn current(p: *const FieldPicker) ?Item {
        if (!p.loaded or p.selected >= p.items.len) return null;
        return p.items[p.selected];
    }
};

pub const TransitionPicker = struct {
    gpa: Allocator,
    owned: std.heap.ArenaAllocator,
    key: []const u8,
    /// Null while the fetch is out.
    transitions: ?[]const model.Transition = null,
    selected: usize = 0,
    error_text: []const u8 = "",
    targets: usize = 1,
    /// Typed while the list was still on the wire: a `1`–`9` jump, and
    /// an Enter — played when it lands.
    pending_jump: ?usize = null,
    pending_commit: bool = false,

    pub fn init(gpa: Allocator, key: []const u8) Allocator.Error!TransitionPicker {
        var owned = std.heap.ArenaAllocator.init(gpa);
        const k = try owned.allocator().dupe(u8, key);
        return .{ .gpa = gpa, .owned = owned, .key = k };
    }

    pub fn deinit(p: *TransitionPicker) void {
        p.owned.deinit();
        p.* = undefined;
    }

    pub fn setTransitions(p: *TransitionPicker, list: []const model.Transition) Allocator.Error!void {
        const a = p.owned.allocator();
        const copy = try a.alloc(model.Transition, list.len);
        for (list, copy) |src, *dst| dst.* = .{ .id = try a.dupe(u8, src.id), .name = try a.dupe(u8, src.name), .to_name = try a.dupe(u8, src.to_name) };
        p.transitions = copy;
    }

    pub fn fail(p: *TransitionPicker, message: []const u8) Allocator.Error!void {
        p.error_text = try p.owned.allocator().dupe(u8, message);
        if (p.transitions == null) p.transitions = &.{};
    }

    pub fn move(p: *TransitionPicker, delta: i32) void {
        const list = p.transitions orelse return;
        if (list.len == 0) return;
        const np: i64 = @as(i64, @intCast(p.selected)) + delta;
        p.selected = @intCast(std.math.clamp(np, 0, @as(i64, @intCast(list.len)) - 1));
    }

    pub fn jump(p: *TransitionPicker, idx: usize) void {
        const list = p.transitions orelse return;
        if (idx < list.len) p.selected = idx;
    }

    pub fn current(p: *const TransitionPicker) ?model.Transition {
        const list = p.transitions orelse return null;
        if (p.selected >= list.len) return null;
        return list[p.selected];
    }
};

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

test "a field picker filters as typed, keeps the cursor on a visible row, and moves within the filtered set" {
    var p = FieldPicker.init(testing.allocator, .assignee);
    defer p.deinit();
    try testing.expect(p.current() == null);
    try p.setItems(&.{ .{ .id = "", .label = "— Unassign —" }, .{ .id = "a1", .label = "Grace Hopper" }, .{ .id = "a2", .label = "Dennis Hopper" }, .{ .id = "a3", .label = "Alan Turing" } });
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 4), (try p.visible(a.allocator())).len);
    try p.move(1);
    try p.move(1);
    try testing.expectEqualStrings("a2", p.current().?.id);
    try p.insert("gra");
    const vis = try p.visible(a.allocator());
    try testing.expectEqual(@as(usize, 1), vis.len);
    try testing.expectEqualStrings("a1", p.current().?.id);
    try p.backspace();
    try p.backspace();
    try p.backspace();
    try testing.expectEqual(@as(usize, 4), (try p.visible(a.allocator())).len);
    try p.insert("hopper");
    try p.move(5);
    try testing.expectEqualStrings("a2", p.current().?.id);
    try p.move(-5);
    try testing.expectEqualStrings("a1", p.current().?.id);
    p.selectId("a3");
    try testing.expectEqualStrings("a3", p.current().?.id);
    try testing.expectEqualStrings("set assignee", Kind.assignee.title());
}

test "a multi-select picker toggles rows with a seed and reports the checked ids in item order" {
    var p = FieldPicker.init(testing.allocator, .quick_filter);
    defer p.deinit();
    try p.setItems(&.{ .{ .id = "1", .label = "Only bugs" }, .{ .id = "2", .label = "Mine" }, .{ .id = "3", .label = "Blocked" } });
    try p.seedMulti(&.{"3"});
    try testing.expect(p.isChecked("3") and !p.isChecked("1"));
    try p.toggleSelected();
    try testing.expect(p.isChecked("1"));
    try p.toggleSelected();
    try testing.expect(!p.isChecked("1"));
    try p.move(1);
    try p.toggleSelected();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const ids = try p.checked(a.allocator());
    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("2", ids[0]);
    try testing.expectEqualStrings("3", ids[1]);
    // A single-select picker ignores the toggle.
    var s = FieldPicker.init(testing.allocator, .label);
    defer s.deinit();
    try s.setItems(&.{.{ .id = "x", .label = "x" }});
    try s.toggleSelected();
    try testing.expect(!s.isChecked("x"));
    try s.fail("nope");
    try testing.expectEqualStrings("nope", s.error_text);
}

test "the transition picker moves, jumps by digit and clamps; an error leaves an empty list" {
    var p = try TransitionPicker.init(testing.allocator, "TE-1");
    defer p.deinit();
    try testing.expect(p.current() == null);
    try p.setTransitions(&.{ .{ .id = "11", .name = "Start review", .to_name = "In Review" }, .{ .id = "21", .name = "Block", .to_name = "Blocked" }, .{ .id = "31", .name = "Resolve", .to_name = "Done" } });
    p.move(1);
    try testing.expectEqualStrings("21", p.current().?.id);
    p.move(10);
    try testing.expectEqualStrings("31", p.current().?.id);
    p.move(-100);
    try testing.expectEqualStrings("11", p.current().?.id);
    p.jump(2);
    try testing.expectEqualStrings("31", p.current().?.id);
    p.jump(99);
    try testing.expectEqualStrings("31", p.current().?.id);
    var q = try TransitionPicker.init(testing.allocator, "TE-2");
    defer q.deinit();
    try q.fail("403 — not allowed");
    try testing.expectEqual(@as(usize, 0), q.transitions.?.len);
    q.move(1);
    try testing.expect(q.current() == null);
}
