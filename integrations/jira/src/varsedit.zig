//! The vars editor — the small overlay behind `E` on a `jql_editable`
//! tab. It edits the tab's `{name}` holes, never the JQL itself: a
//! release list changes far more often than the query around it, and
//! typing a whole JQL to add a version is the thing this exists to
//! stop.
//!
//! State only, the way `pickers.zig` is: the app decides what a save
//! does and `screen.zig` paints it. The rows are flattened after every
//! mutation so the painter and the key handler cannot disagree about
//! what row 4 is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const textedit = @import("textedit.zig");

const TextEdit = textedit.TextEdit;

/// One var's working copy. A scalar var (`.value`) is a one-value list
/// that cannot grow or shrink; a list var (`.values`) can.
pub const Box = struct {
    name: []const u8,
    values: std.ArrayListUnmanaged([]const u8) = .empty,
    list: bool,
};

/// A line of the overlay. `add` is the `+ add` line under a list var.
pub const Row = union(enum) {
    name: usize,
    value: struct { v: usize, i: usize },
    add: usize,
};

pub const Editor = struct {
    gpa: Allocator,
    /// Owns every string on screen — the names, the values, and the
    /// text a commit takes out of the line editor.
    owned: std.heap.ArenaAllocator,
    /// The tab being edited, as the App indexes its tabs.
    tab_idx: usize,
    /// The tab's index in the config FILE's `.tabs` list, which is what
    /// the splice path names. The App's list is filtered by `--only`,
    /// so the two are not the same number.
    file_idx: usize,
    tab_name: []const u8,
    boxes: std.ArrayListUnmanaged(Box) = .empty,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    cursor: usize = 0,
    /// The line editor, while a value is being typed.
    edit: ?TextEdit = null,
    /// Where the open editor writes back. `null` on a fresh value that
    /// is discarded if the edit is cancelled.
    editing: ?Row = null,
    dirty: bool = false,
    error_text: []const u8 = "",

    pub fn init(gpa: Allocator, tab_idx: usize, file_idx: usize, tab_name: []const u8, vars: []const config.Var) Allocator.Error!Editor {
        var e: Editor = .{
            .gpa = gpa,
            .owned = std.heap.ArenaAllocator.init(gpa),
            .tab_idx = tab_idx,
            .file_idx = file_idx,
            .tab_name = "",
        };
        errdefer e.owned.deinit();
        const arena = e.owned.allocator();
        e.tab_name = try arena.dupe(u8, tab_name);
        for (vars) |v| {
            var box: Box = .{ .name = try arena.dupe(u8, v.name), .list = v.isList() };
            if (v.values.len > 0) {
                for (v.values) |one| try box.values.append(gpa, try arena.dupe(u8, one));
            } else if (v.value.len > 0) {
                try box.values.append(gpa, try arena.dupe(u8, v.value));
            } else try box.values.append(gpa, "");
            try e.boxes.append(gpa, box);
        }
        try e.rebuild();
        return e;
    }

    pub fn deinit(e: *Editor) void {
        for (e.boxes.items) |*b| b.values.deinit(e.gpa);
        e.boxes.deinit(e.gpa);
        e.rows.deinit(e.gpa);
        if (e.edit) |*t| t.deinit();
        e.owned.deinit();
        e.* = undefined;
    }

    /// The flattened lines, rebuilt after every change so a row index
    /// means the same thing to the painter and to the keys.
    pub fn rebuild(e: *Editor) Allocator.Error!void {
        e.rows.clearRetainingCapacity();
        for (e.boxes.items, 0..) |b, vi| {
            try e.rows.append(e.gpa, .{ .name = vi });
            for (0..b.values.items.len) |i| try e.rows.append(e.gpa, .{ .value = .{ .v = vi, .i = i } });
            if (b.list) try e.rows.append(e.gpa, .{ .add = vi });
        }
        if (e.cursor >= e.rows.items.len) e.cursor = e.rows.items.len -| 1;
    }

    pub fn rowAt(e: *const Editor, i: usize) ?Row {
        if (i >= e.rows.items.len) return null;
        return e.rows.items[i];
    }

    pub fn focused(e: *const Editor) ?Row {
        return e.rowAt(e.cursor);
    }

    pub fn move(e: *Editor, delta: i64) void {
        if (e.rows.items.len == 0) return;
        const cur: i64 = @intCast(e.cursor);
        e.cursor = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(e.rows.items.len)) - 1));
    }

    /// The text of a value row, for the painter.
    pub fn valueText(e: *const Editor, v: usize, i: usize) []const u8 {
        if (v >= e.boxes.items.len) return "";
        const b = e.boxes.items[v];
        if (i >= b.values.items.len) return "";
        return b.values.items[i];
    }

    // ─── the line editor ─────────────────────────────────────────────

    /// Open the line editor on the focused row: a value row edits its
    /// text, an `+ add` row starts an empty one.
    pub fn beginEdit(e: *Editor) Allocator.Error!void {
        const row = e.focused() orelse return;
        switch (row) {
            .name => return,
            .value => |p| {
                var t = TextEdit.init(e.gpa);
                try t.set(e.valueText(p.v, p.i));
                t.end();
                e.edit = t;
                e.editing = row;
            },
            .add => {
                e.edit = TextEdit.init(e.gpa);
                e.editing = row;
            },
        }
    }

    /// Take the line editor's text back into the box. An add-row commit
    /// with nothing typed is a cancel; an existing value emptied is a
    /// remove, so backspacing a version away does what it looks like.
    pub fn commitEdit(e: *Editor) Allocator.Error!void {
        var t = e.edit orelse return;
        const row = e.editing orelse return;
        defer {
            t.deinit();
            e.edit = null;
            e.editing = null;
        }
        const typed = std.mem.trim(u8, t.text(), " \t");
        switch (row) {
            .name => {},
            .value => |p| {
                if (p.v >= e.boxes.items.len) return;
                const b = &e.boxes.items[p.v];
                if (p.i >= b.values.items.len) return;
                if (typed.len == 0 and b.list and b.values.items.len > 1) {
                    _ = b.values.orderedRemove(p.i);
                } else b.values.items[p.i] = try e.owned.allocator().dupe(u8, typed);
                e.dirty = true;
            },
            .add => |vi| {
                if (typed.len == 0) return;
                if (vi >= e.boxes.items.len) return;
                const b = &e.boxes.items[vi];
                try b.values.append(e.gpa, try e.owned.allocator().dupe(u8, typed));
                e.dirty = true;
                e.cursor += 1;
            },
        }
        try e.rebuild();
    }

    pub fn cancelEdit(e: *Editor) void {
        if (e.edit) |*t| t.deinit();
        e.edit = null;
        e.editing = null;
    }

    /// `a` — a new empty value on the focused var, typed straight away.
    pub fn addValue(e: *Editor) Allocator.Error!void {
        const row = e.focused() orelse return;
        const vi = switch (row) {
            .name => |v| v,
            .value => |p| p.v,
            .add => |v| v,
        };
        if (vi >= e.boxes.items.len or !e.boxes.items[vi].list) return;
        // Put the cursor on that var's `+ add` line, then type into it.
        for (e.rows.items, 0..) |r, i| if (r == .add and r.add == vi) {
            e.cursor = i;
        };
        try e.beginEdit();
    }

    /// `d` — drop the focused value. The last value of a list var stays
    /// (an empty `.values` would silently widen the query), emptied
    /// instead, and a scalar var's one value is only ever emptied.
    pub fn removeValue(e: *Editor) Allocator.Error!void {
        const row = e.focused() orelse return;
        const p = switch (row) {
            .value => |p| p,
            else => return,
        };
        if (p.v >= e.boxes.items.len) return;
        const b = &e.boxes.items[p.v];
        if (p.i >= b.values.items.len) return;
        if (b.list and b.values.items.len > 1) {
            _ = b.values.orderedRemove(p.i);
        } else b.values.items[p.i] = "";
        e.dirty = true;
        try e.rebuild();
    }

    // ─── what a save writes ──────────────────────────────────────────

    /// The box as the config's own type, for the JQL to be re-expanded
    /// from without a round trip through the file.
    pub fn asVars(e: *const Editor, arena: Allocator) Allocator.Error![]const config.Var {
        var out: std.ArrayList(config.Var) = .empty;
        for (e.boxes.items) |b| {
            if (b.list) {
                var vals: std.ArrayList([]const u8) = .empty;
                for (b.values.items) |v| if (v.len > 0) try vals.append(arena, try arena.dupe(u8, v));
                try out.append(arena, .{ .name = try arena.dupe(u8, b.name), .values = try vals.toOwnedSlice(arena) });
            } else {
                try out.append(arena, .{ .name = try arena.dupe(u8, b.name), .value = try arena.dupe(u8, if (b.values.items.len > 0) b.values.items[0] else "") });
            }
        }
        return out.toOwnedSlice(arena);
    }

    /// One var's ZON literal — `.{ "a", "b" }` for a list, `"a"` for a
    /// scalar — and the key inside `vars` it belongs under.
    pub fn literalFor(e: *const Editor, arena: Allocator, vi: usize) Allocator.Error!?struct { key: []const u8, literal: []const u8 } {
        if (vi >= e.boxes.items.len) return null;
        const b = e.boxes.items[vi];
        if (!b.list) return .{ .key = "value", .literal = try quote(arena, if (b.values.items.len > 0) b.values.items[0] else "") };
        var parts: std.ArrayList([]const u8) = .empty;
        for (b.values.items) |v| if (v.len > 0) try parts.append(arena, try quote(arena, v));
        if (parts.items.len == 0) return .{ .key = "values", .literal = ".{}" };
        return .{ .key = "values", .literal = try std.fmt.allocPrint(arena, ".{{ {s} }}", .{try std.mem.join(arena, ", ", parts.items)}) };
    }
};

/// A ZON string literal: the bytes with `"` and `\` escaped.
pub fn quote(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

// ─── tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

const sample = [_]config.Var{
    .{ .name = "project", .value = "ENG" },
    .{ .name = "versions", .values = &.{ "1.2.0", "Mobile 1.0.X" } },
};

test "the rows flatten a scalar var and a list var, and only a list var gets an add line" {
    var e = try Editor.init(testing.allocator, 0, 2, "QA Actionable now", &sample);
    defer e.deinit();
    // project, ENG, versions, 1.2.0, Mobile 1.0.X, + add
    try testing.expectEqual(@as(usize, 6), e.rows.items.len);
    try testing.expectEqual(@as(usize, 0), e.rows.items[0].name);
    try testing.expectEqualStrings("ENG", e.valueText(0, 0));
    try testing.expect(e.rows.items[2] == .name);
    try testing.expect(e.rows.items[5] == .add);
    try testing.expect(!e.boxes.items[0].list and e.boxes.items[1].list);
    e.move(100);
    try testing.expectEqual(@as(usize, 5), e.cursor);
    e.move(-100);
    try testing.expectEqual(@as(usize, 0), e.cursor);
}

test "add types a new version in, rename replaces one, remove drops it" {
    var e = try Editor.init(testing.allocator, 0, 2, "QA", &sample);
    defer e.deinit();
    e.cursor = 3; // 1.2.0
    try e.addValue();
    try testing.expect(e.edit != null);
    try e.edit.?.insert("1.3.0");
    try e.commitEdit();
    try testing.expectEqual(@as(usize, 3), e.boxes.items[1].values.items.len);
    try testing.expectEqualStrings("1.3.0", e.valueText(1, 2));
    try testing.expect(e.dirty);

    // Rename the first version.
    e.cursor = 3;
    try e.beginEdit();
    e.edit.?.killToStart();
    try e.edit.?.insert("2.0.0");
    try e.commitEdit();
    try testing.expectEqualStrings("2.0.0", e.valueText(1, 0));

    // Remove it.
    e.cursor = 3;
    try e.removeValue();
    try testing.expectEqual(@as(usize, 2), e.boxes.items[1].values.items.len);
    try testing.expectEqualStrings("Mobile 1.0.X", e.valueText(1, 0));

    // A cancelled edit changes nothing.
    e.cursor = 1;
    try e.beginEdit();
    try e.edit.?.insert("XXX");
    e.cancelEdit();
    try testing.expectEqualStrings("ENG", e.valueText(0, 0));
    try testing.expect(e.edit == null);
}

test "the last value of a list is emptied rather than removed, and a scalar never loses its row" {
    var one = [_]config.Var{.{ .name = "versions", .values = &.{"1.2.0"} }};
    var e = try Editor.init(testing.allocator, 0, 0, "QA", &one);
    defer e.deinit();
    e.cursor = 1;
    try e.removeValue();
    try testing.expectEqual(@as(usize, 1), e.boxes.items[0].values.items.len);
    try testing.expectEqualStrings("", e.valueText(0, 0));
    // A name row and an add row are not values: `d` on them is a no-op.
    e.cursor = 0;
    try e.removeValue();
    try testing.expectEqual(@as(usize, 1), e.boxes.items[0].values.items.len);
    _ = &one;
}

test "the literals are the ZON a splice writes, quotes escaped" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var e = try Editor.init(testing.allocator, 0, 2, "QA", &sample);
    defer e.deinit();
    const scalar = (try e.literalFor(arena, 0)).?;
    try testing.expectEqualStrings("value", scalar.key);
    try testing.expectEqualStrings("\"ENG\"", scalar.literal);
    const list = (try e.literalFor(arena, 1)).?;
    try testing.expectEqualStrings("values", list.key);
    try testing.expectEqualStrings(".{ \"1.2.0\", \"Mobile 1.0.X\" }", list.literal);
    try testing.expect((try e.literalFor(arena, 9)) == null);
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", try quote(arena, "say \"hi\""));

    // An emptied list writes `.{}` rather than a stale value.
    e.cursor = 3;
    try e.removeValue();
    e.cursor = 3;
    try e.removeValue();
    try testing.expectEqualStrings(".{}", (try e.literalFor(arena, 1)).?.literal);

    // asVars drops the empty entries, so the JQL re-expands cleanly.
    const vars = try e.asVars(arena);
    try testing.expectEqual(@as(usize, 2), vars.len);
    try testing.expectEqualStrings("ENG", vars[0].value);
    try testing.expectEqual(@as(usize, 0), vars[1].values.len);
}
