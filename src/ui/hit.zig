//! STUB — replaced by the ui branch at merge; keep signatures identical to docs/WAVE3_CONTRACT.md
//! The hit map (D6): every painted interactive rect, registered in the
//! same statement as its paint. `at` scans back-to-front so overlays win.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("rect.zig");
const ids = @import("../core/ids.zig");
const panel = @import("../core/panel.zig");

pub const PaneId = ids.PaneId;
pub const PanelId = panel.PanelId;

pub const ChipKind = enum { sort, refresh, new, view };

pub const Owner = union(enum) { pane: PaneId, panel: PanelId };

pub const HitTarget = union(enum) {
    pane: PaneId,
    divider: u32,
    tab: struct { leaf: u32, idx: u16 },
    row: struct { panel: PanelId, idx: u32 },
    kebab: struct { panel: PanelId, idx: u32 },
    chip: struct { panel: PanelId, kind: ChipKind },
    filter_input: PanelId,
    scrollbar: struct { owner: Owner, axis: enum { v, h } },
    button: u32,
    link: struct { url: []const u8 },
    menu_item: struct { menu: u32, idx: u16 },
    statusline_seg: u32,
    tree_node: u32,
    script_hit: struct { pane: PaneId, id: u32 },
    /// A visible editor cell; `line`/`col` are 0-based document coords.
    editor_cell: struct { pane: PaneId, line: u32, col: u32 },
    overlay_item: u32,
};

pub const HitMap = struct {
    pub const Entry = struct { rect: Rect, target: HitTarget };
    items: std.ArrayListUnmanaged(Entry) = .empty,

    /// Frame start. Storage is the frame arena, so nothing is freed.
    pub fn reset(h: *HitMap) void {
        h.items = .empty;
    }

    pub fn add(h: *HitMap, arena: Allocator, r: Rect, t: HitTarget) Allocator.Error!void {
        if (r.isEmpty()) return;
        try h.items.append(arena, .{ .rect = r, .target = t });
    }

    /// Back-to-front: the last painted rect under (x, y) wins.
    pub fn at(h: *const HitMap, x: u16, y: u16) ?HitTarget {
        var i = h.items.items.len;
        while (i > 0) {
            i -= 1;
            const e = h.items.items[i];
            if (e.rect.contains(x, y)) return e.target;
        }
        return null;
    }

    /// `[{"label","x","y","w","h"}]` — the `rects.json` body.
    pub fn writeRectsJson(h: *const HitMap, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("[");
        for (h.items.items, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("\n  {\"label\":\"");
            try writeLabel(w, e.target);
            try w.print("\",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ e.rect.x, e.rect.y, e.rect.w, e.rect.h });
        }
        if (h.items.items.len > 0) try w.writeByte('\n');
        try w.writeAll("]\n");
    }

    fn writeLabel(w: *std.Io.Writer, t: HitTarget) std.Io.Writer.Error!void {
        switch (t) {
            .pane => |id| try w.print("pane:{d}", .{id}),
            .divider => |d| try w.print("divider:{d}", .{d}),
            .tab => |tb| try w.print("tab:{d}:{d}", .{ tb.leaf, tb.idx }),
            .row => |r| try w.print("row:{s}:{d}", .{ @tagName(r.panel), r.idx }),
            .kebab => |k| try w.print("kebab:{s}:{d}", .{ @tagName(k.panel), k.idx }),
            .chip => |c| try w.print("chip:{s}:{s}", .{ @tagName(c.panel), @tagName(c.kind) }),
            .filter_input => |p| try w.print("filter_input:{s}", .{@tagName(p)}),
            .scrollbar => |s| try w.print("scrollbar:{s}", .{@tagName(s.axis)}),
            .button => |b| try w.print("button:{d}", .{b}),
            .link => try w.writeAll("link"),
            .menu_item => |m| try w.print("menu_item:{d}:{d}", .{ m.menu, m.idx }),
            .statusline_seg => |s| try w.print("statusline_seg:{d}", .{s}),
            .tree_node => |n| try w.print("tree_node:{d}", .{n}),
            .script_hit => |s| try w.print("script_hit:{d}:{d}", .{ s.pane, s.id }),
            .editor_cell => |c| try w.print("editor_cell:{d}:{d}:{d}", .{ c.pane, c.line, c.col }),
            .overlay_item => |i| try w.print("overlay_item:{d}", .{i}),
        }
    }
};

test "hit map: last painted wins; empty rects are not registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var h: HitMap = .{};
    h.reset();
    try h.add(arena.allocator(), Rect.init(0, 0, 10, 10), .{ .pane = 1 });
    try h.add(arena.allocator(), Rect.init(2, 2, 3, 3), .{ .overlay_item = 4 });
    try h.add(arena.allocator(), Rect.init(0, 0, 0, 5), .{ .button = 9 });
    try std.testing.expectEqual(@as(u32, 4), h.at(3, 3).?.overlay_item);
    try std.testing.expectEqual(@as(PaneId, 1), h.at(0, 0).?.pane);
    try std.testing.expect(h.at(20, 20) == null);
    var a: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer a.deinit();
    try h.writeRectsJson(&a.writer);
    try std.testing.expectEqualStrings("[\n  {\"label\":\"pane:1\",\"x\":0,\"y\":0,\"w\":10,\"h\":10},\n  {\"label\":\"overlay_item:4\",\"x\":2,\"y\":2,\"w\":3,\"h\":3}\n]\n", a.written());
}
