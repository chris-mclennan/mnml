//! HitMap — the frame's click targets, registered by the painter that
//! drew them (D6).
//!
//! A component paints a rect and, in the same statement, tells the map
//! what that rect means. Mouse dispatch is then one `switch` on `at(x, y)`
//! in the app; there is no second bookkeeping structure to clear or keep
//! in step with the paint. Storage is the frame arena: `reset` at the top
//! of a frame, `add` while painting, nothing to free.
//!
//! `at` scans back to front — the last thing painted is the thing on top,
//! so an overlay drawn after the panes wins the click. `writeRectsJson`
//! is the `rects.json` the IPC channel publishes, so a test can click by
//! label instead of by coordinate.

const std = @import("std");
const Rect = @import("rect.zig");
const ids = @import("../core/ids.zig");
const panel = @import("../core/panel.zig");

const Allocator = std.mem.Allocator;

pub const PaneId = ids.PaneId;
pub const PanelId = panel.PanelId;

pub const ChipKind = enum { sort, refresh, new, view };

/// The parts of a dock widget (`app/dock.zig`).
/// // changed (panels): `.dock` joins the target set — the widgets
/// register their title / kebab / close / body here like any component.
pub const DockPart = enum { body, title, kebab, close };

pub const Owner = union(enum) {
    pane: PaneId,
    panel: PanelId,
};

pub const Axis = enum { v, h };

/// A row of a list panel — shared by `.row` and `.kebab` so one
/// `switch` arm can capture both.
pub const PanelRow = struct { panel: PanelId, idx: u32 };

/// A tab on a leaf's strip, by the leaf's index and the tab's position
/// in it — shared by `.tab` and `.tab_close` so one arm captures both.
pub const TabRef = struct { leaf: u32, idx: u16 };

pub const HitTarget = union(enum) {
    pane: PaneId,
    divider: u32,
    tab: TabRef,
    /// The `×` on a pty tab (`bufferline.zig`): the same leaf / index
    /// as the `.tab` it sits on; a press closes that pane.
    tab_close: TabRef,
    row: PanelRow,
    kebab: PanelRow,
    chip: struct { panel: PanelId, kind: ChipKind },
    filter_input: PanelId,
    scrollbar: struct { owner: Owner, axis: Axis },
    button: u32,
    link: struct { url: []const u8 },
    menu_item: struct { menu: u32, idx: u16 },
    statusline_seg: u32,
    tree_node: u32,
    script_hit: struct { pane: PaneId, id: u32 },
    /// A visible editor cell; `line` is the 0-based document line and
    /// `col` the byte offset of the grapheme under the cell within that
    /// line (the line's length for cells past its end).
    editor_cell: struct { pane: PaneId, line: u32, col: u32 },
    overlay_item: u32,
    dock: struct { id: u32, part: DockPart },

    /// `@tagName` plus the payload, colon-separated: `row:todos:3`,
    /// `editor_cell:0:12:4`, `scrollbar:panel:notes:v`.
    pub fn writeLabel(t: HitTarget, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(@tagName(t));
        switch (t) {
            .pane, .divider, .button, .statusline_seg, .tree_node, .overlay_item => |n| try w.print(":{d}", .{n}),
            .tab, .tab_close => |v| try w.print(":{d}:{d}", .{ v.leaf, v.idx }),
            .row, .kebab => |v| try w.print(":{s}:{d}", .{ @tagName(v.panel), v.idx }),
            .chip => |v| try w.print(":{s}:{s}", .{ @tagName(v.panel), @tagName(v.kind) }),
            .filter_input => |p| try w.print(":{s}", .{@tagName(p)}),
            .scrollbar => |v| {
                switch (v.owner) {
                    .pane => |id| try w.print(":pane:{d}", .{id}),
                    .panel => |p| try w.print(":panel:{s}", .{@tagName(p)}),
                }
                try w.print(":{s}", .{@tagName(v.axis)});
            },
            .link => |v| try w.print(":{s}", .{v.url}),
            .menu_item => |v| try w.print(":{d}:{d}", .{ v.menu, v.idx }),
            .script_hit => |v| try w.print(":{d}:{d}", .{ v.pane, v.id }),
            .editor_cell => |v| try w.print(":{d}:{d}:{d}", .{ v.pane, v.line, v.col }),
            .dock => |v| try w.print(":{d}:{s}", .{ v.id, @tagName(v.part) }),
        }
    }
};

pub const HitMap = struct {
    pub const Entry = struct { rect: Rect, target: HitTarget };

    items: std.ArrayListUnmanaged(Entry) = .empty,

    /// Frame start. The entries lived on the frame arena, which the app
    /// resets; the list only forgets them.
    pub fn reset(h: *HitMap) void {
        h.items = .empty;
    }

    /// Registers `t` for `r`. Empty rects are skipped: they cannot be
    /// clicked and would only pad `rects.json`.
    pub fn add(h: *HitMap, arena: Allocator, r: Rect, t: HitTarget) Allocator.Error!void {
        if (r.isEmpty()) return;
        try h.items.append(arena, .{ .rect = r, .target = t });
    }

    /// Back to front: the last thing painted wins.
    pub fn at(h: *const HitMap, x: u16, y: u16) ?HitTarget {
        return if (h.entryAt(x, y)) |e| e.target else null;
    }

    /// Like `at`, with the rect — for callers that need the cell's
    /// offset inside its target (a scrollbar drag, a divider).
    pub fn entryAt(h: *const HitMap, x: u16, y: u16) ?Entry {
        var i = h.items.items.len;
        while (i > 0) {
            i -= 1;
            const e = h.items.items[i];
            if (e.rect.contains(x, y)) return e;
        }
        return null;
    }

    /// `[{"label":"row:todos:3","x":1,"y":4,"w":28,"h":1},…]` in paint
    /// order — the `rects.json` shape the IPC channel publishes.
    pub fn writeRectsJson(h: *const HitMap, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('[');
        for (h.items.items, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"label\":\"");
            var lw: LabelWriter = .{ .out = w };
            try e.target.writeLabel(&lw.writer);
            try lw.writer.flush();
            try w.print("\",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ e.rect.x, e.rect.y, e.rect.w, e.rect.h });
        }
        try w.writeByte(']');
    }
};

/// A writer that JSON-escapes what passes through it (a link's url may
/// carry a quote or a backslash).
const LabelWriter = struct {
    out: *std.Io.Writer,
    buf: [64]u8 = undefined,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &vtable },

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *LabelWriter = @alignCast(@fieldParentPtr("writer", w));
        var n: usize = 0;
        for (data, 0..) |chunk, i| {
            const reps: usize = if (i == data.len - 1) splat else 1;
            for (0..reps) |_| try self.escape(chunk);
            n += chunk.len * reps;
        }
        return n;
    }

    fn escape(self: *LabelWriter, s: []const u8) std.Io.Writer.Error!void {
        for (s) |c| switch (c) {
            '"' => try self.out.writeAll("\\\""),
            '\\' => try self.out.writeAll("\\\\"),
            '\n' => try self.out.writeAll("\\n"),
            '\r' => try self.out.writeAll("\\r"),
            '\t' => try self.out.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try self.out.print("\\u{x:0>4}", .{c}),
            else => try self.out.writeByte(c),
        };
    }
};

// ── tests ──

const testing = std.testing;

test "at scans back to front so the last painted target wins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var h: HitMap = .{};
    try h.add(arena, Rect.init(0, 0, 10, 10), .{ .pane = 1 });
    try h.add(arena, Rect.init(2, 2, 3, 3), .{ .row = .{ .panel = .todos, .idx = 3 } });
    try h.add(arena, Rect.init(3, 3, 1, 1), .{ .overlay_item = 7 });

    try testing.expectEqual(@as(u32, 1), h.at(0, 0).?.pane);
    try testing.expectEqual(@as(u32, 3), h.at(2, 2).?.row.idx);
    try testing.expectEqual(@as(u32, 7), h.at(3, 3).?.overlay_item);
    try testing.expect(h.at(10, 10) == null);
    try testing.expect(h.entryAt(4, 4).?.rect.eql(Rect.init(2, 2, 3, 3)));
    h.reset();
    try testing.expect(h.at(0, 0) == null);
}

test "empty rects are not registered" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var h: HitMap = .{};
    try h.add(arena_state.allocator(), Rect.init(5, 5, 0, 1), .{ .button = 1 });
    try testing.expectEqual(@as(usize, 0), h.items.items.len);
}

fn expectLabel(expected: []const u8, t: HitTarget) !void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.writeLabel(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "labels are the tag plus the payload" {
    try expectLabel("pane:4", .{ .pane = 4 });
    try expectLabel("tab:0:2", .{ .tab = .{ .leaf = 0, .idx = 2 } });
    try expectLabel("row:todos:3", .{ .row = .{ .panel = .todos, .idx = 3 } });
    try expectLabel("kebab:notes:0", .{ .kebab = .{ .panel = .notes, .idx = 0 } });
    try expectLabel("chip:findings:sort", .{ .chip = .{ .panel = .findings, .kind = .sort } });
    try expectLabel("filter_input:sessions", .{ .filter_input = .sessions });
    try expectLabel("scrollbar:pane:2:v", .{ .scrollbar = .{ .owner = .{ .pane = 2 }, .axis = .v } });
    try expectLabel("scrollbar:panel:todos:h", .{ .scrollbar = .{ .owner = .{ .panel = .todos }, .axis = .h } });
    try expectLabel("link:https://x.y/z", .{ .link = .{ .url = "https://x.y/z" } });
    try expectLabel("menu_item:1:5", .{ .menu_item = .{ .menu = 1, .idx = 5 } });
    try expectLabel("script_hit:3:9", .{ .script_hit = .{ .pane = 3, .id = 9 } });
    try expectLabel("editor_cell:0:12:4", .{ .editor_cell = .{ .pane = 0, .line = 12, .col = 4 } });
    try expectLabel("overlay_item:2", .{ .overlay_item = 2 });
    try expectLabel("statusline_seg:1", .{ .statusline_seg = 1 });
    try expectLabel("tree_node:8", .{ .tree_node = 8 });
    try expectLabel("divider:0", .{ .divider = 0 });
    try expectLabel("button:6", .{ .button = 6 });
}

test "rects.json shape, with a url that needs escaping" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var h: HitMap = .{};
    try h.add(arena, Rect.init(1, 4, 28, 1), .{ .row = .{ .panel = .todos, .idx = 3 } });
    try h.add(arena, Rect.init(0, 0, 5, 1), .{ .link = .{ .url = "a\"b\\c" } });

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try h.writeRectsJson(&aw.writer);
    try testing.expectEqualStrings(
        "[{\"label\":\"row:todos:3\",\"x\":1,\"y\":4,\"w\":28,\"h\":1}," ++
            "{\"label\":\"link:a\\\"b\\\\c\",\"x\":0,\"y\":0,\"w\":5,\"h\":1}]",
        aw.written(),
    );

    // It parses back as JSON with the label intact.
    const parsed = try std.json.parseFromSlice([]const struct { label: []const u8, x: u16, y: u16, w: u16, h: u16 }, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.value.len);
    try testing.expectEqualStrings("link:a\"b\\c", parsed.value[1].label);

    var empty: HitMap = .{};
    var ew: std.Io.Writer.Allocating = .init(testing.allocator);
    defer ew.deinit();
    try empty.writeRectsJson(&ew.writer);
    try testing.expectEqualStrings("[]", ew.written());
}
