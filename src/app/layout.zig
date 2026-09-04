//! The window layout: a binary split tree over the central pane area,
//! stored in a node pool (indices, no boxes). The bufferline and the
//! statusline live outside this tree.
//!
//! Invariants the app maintains: no pane is in two leaves at once, and
//! the active pane is always in a leaf (so it identifies the focused
//! leaf). Panes in no leaf are allowed (background tabs); revealing one
//! shows it in the focused leaf.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ids = @import("../core/ids.zig");
const Rect = @import("../ui/rect.zig");

pub const PaneId = ids.PaneId;
pub const NodeId = u32;

pub const SplitDir = enum {
    /// Side by side — `first` left, `second` right, vertical divider.
    horizontal,
    /// Stacked — `first` on top, `second` below, horizontal divider.
    vertical,
};

pub const Leaf = struct {
    active: PaneId,
    /// Insertion order; never empty while the leaf is live.
    tabs: std.ArrayListUnmanaged(PaneId) = .empty,
};

pub const Node = union(enum) {
    leaf: Leaf,
    split: struct { dir: SplitDir, ratio: u16, first: NodeId, second: NodeId },
    /// A freed slot.
    free,
};

pub const PaneRect = struct { pane: PaneId, rect: Rect, leaf: NodeId };
pub const Rects = struct { panes: []PaneRect, dividers: []Rect };

pub const Layout = struct {
    gpa: Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    root: ?NodeId = null,

    pub fn init(gpa: Allocator) Layout {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Layout) void {
        for (self.nodes.items) |*n| switch (n.*) {
            .leaf => |*l| l.tabs.deinit(self.gpa),
            else => {},
        };
        self.nodes.deinit(self.gpa);
    }

    pub fn isEmpty(self: *const Layout) bool {
        return self.root == null;
    }

    fn alloc(self: *Layout, fresh: Node) Allocator.Error!NodeId {
        for (self.nodes.items, 0..) |n, i| if (n == .free) {
            self.nodes.items[i] = fresh;
            return @intCast(i);
        };
        try self.nodes.append(self.gpa, fresh);
        return @intCast(self.nodes.items.len - 1);
    }

    fn release(self: *Layout, id: NodeId) void {
        switch (self.nodes.items[id]) {
            .leaf => |*l| l.tabs.deinit(self.gpa),
            else => {},
        }
        self.nodes.items[id] = .free;
    }

    pub fn node(self: *Layout, id: NodeId) *Node {
        return &self.nodes.items[id];
    }

    /// The leaf showing `pane` as a tab, if any.
    pub fn leafOf(self: *Layout, pane: PaneId) ?NodeId {
        for (self.nodes.items, 0..) |n, i| switch (n) {
            .leaf => |l| for (l.tabs.items) |t| if (t == pane) return @intCast(i),
            else => {},
        };
        return null;
    }

    pub fn leaf(self: *Layout, id: NodeId) ?*Leaf {
        return switch (self.nodes.items[id]) {
            .leaf => |*l| l,
            else => null,
        };
    }

    /// Leaves in tree order (left/top first).
    pub fn leaves(self: *const Layout, arena: Allocator) Allocator.Error![]NodeId {
        var out: std.ArrayListUnmanaged(NodeId) = .empty;
        if (self.root) |r| try self.collectLeaves(r, arena, &out);
        return out.items;
    }

    fn collectLeaves(self: *const Layout, id: NodeId, arena: Allocator, out: *std.ArrayListUnmanaged(NodeId)) Allocator.Error!void {
        switch (self.nodes.items[id]) {
            .leaf => try out.append(arena, id),
            .split => |s| {
                try self.collectLeaves(s.first, arena, out);
                try self.collectLeaves(s.second, arena, out);
            },
            .free => {},
        }
    }

    pub fn firstLeaf(self: *const Layout) ?NodeId {
        var id = self.root orelse return null;
        while (true) switch (self.nodes.items[id]) {
            .leaf => return id,
            .split => |s| id = s.first,
            .free => return null,
        };
    }

    /// Show `pane` in leaf `where` (appending a tab when new). A pane
    /// already tabbed in another leaf is moved out of it first.
    pub fn showIn(self: *Layout, where: ?NodeId, pane: PaneId) Allocator.Error!NodeId {
        if (self.leafOf(pane)) |owner| {
            if (where == null or where.? == owner) {
                self.leaf(owner).?.active = pane;
                return owner;
            }
            _ = self.removePane(pane);
        }
        const target = where orelse self.firstLeaf() orelse {
            var l: Leaf = .{ .active = pane };
            try l.tabs.append(self.gpa, pane);
            const id = try self.alloc(.{ .leaf = l });
            self.root = id;
            return id;
        };
        const l = self.leaf(target).?;
        try l.tabs.append(self.gpa, pane);
        l.active = pane;
        return target;
    }

    /// Drop `pane` from its leaf. The leaf's active falls to the right
    /// neighbour, else the left; an emptied leaf collapses its split.
    /// Returns the pane that became active in that leaf (null when the
    /// leaf is gone).
    pub fn removePane(self: *Layout, pane: PaneId) ?PaneId {
        const lid = self.leafOf(pane) orelse return null;
        const l = self.leaf(lid).?;
        const idx = std.mem.indexOfScalar(PaneId, l.tabs.items, pane) orelse return null;
        _ = l.tabs.orderedRemove(idx);
        if (l.tabs.items.len == 0) {
            self.removeLeaf(lid);
            return null;
        }
        if (l.active == pane) l.active = l.tabs.items[@min(idx, l.tabs.items.len - 1)];
        return l.active;
    }

    fn parentOf(self: *const Layout, id: NodeId) ?NodeId {
        for (self.nodes.items, 0..) |n, i| switch (n) {
            .split => |s| if (s.first == id or s.second == id) return @intCast(i),
            else => {},
        };
        return null;
    }

    /// The sibling takes the split's place in the grandparent (or as
    /// the root); its own id stays, so a `NodeId` a caller is holding
    /// for it — `showIn`'s target while it drops a tab elsewhere — is
    /// still that leaf.
    fn removeLeaf(self: *Layout, lid: NodeId) void {
        if (self.parentOf(lid)) |pid| {
            const s = self.nodes.items[pid].split;
            const sibling = if (s.first == lid) s.second else s.first;
            if (self.parentOf(pid)) |gp| {
                const g = &self.nodes.items[gp].split;
                if (g.first == pid) g.first = sibling else g.second = sibling;
            } else self.root = sibling;
            self.nodes.items[pid] = .free;
            self.release(lid);
        } else {
            self.release(lid);
            self.root = null;
        }
    }

    /// Split the leaf holding `pane`: the new leaf shows `new_pane` and
    /// sits after (right / below). Returns the new leaf.
    pub fn split(self: *Layout, pane: PaneId, dir: SplitDir, new_pane: PaneId) Allocator.Error!?NodeId {
        const lid = self.leafOf(pane) orelse return null;
        var nl: Leaf = .{ .active = new_pane };
        try nl.tabs.append(self.gpa, new_pane);
        const new_leaf = try self.alloc(.{ .leaf = nl });
        errdefer self.release(new_leaf);
        // Move the old leaf's content into a fresh slot so `lid` becomes the split.
        const moved = try self.alloc(self.nodes.items[lid]);
        self.nodes.items[lid] = .{ .split = .{ .dir = dir, .ratio = 50, .first = moved, .second = new_leaf } };
        return new_leaf;
    }

    /// Every pane rect plus divider rects for `area`.
    pub fn computeRects(self: *const Layout, area: Rect, arena: Allocator) Allocator.Error!Rects {
        var panes: std.ArrayListUnmanaged(PaneRect) = .empty;
        var dividers: std.ArrayListUnmanaged(Rect) = .empty;
        if (self.root) |r| try self.rectsFor(r, area, arena, &panes, &dividers);
        return .{ .panes = panes.items, .dividers = dividers.items };
    }

    fn rectsFor(self: *const Layout, id: NodeId, area: Rect, arena: Allocator, panes: *std.ArrayListUnmanaged(PaneRect), dividers: *std.ArrayListUnmanaged(Rect)) Allocator.Error!void {
        switch (self.nodes.items[id]) {
            .leaf => |l| try panes.append(arena, .{ .pane = l.active, .rect = area, .leaf = id }),
            .split => |s| {
                const ratio: u32 = std.math.clamp(s.ratio, 10, 90);
                switch (s.dir) {
                    .horizontal => {
                        const first_w: u16 = @intCast(@as(u32, area.w) * ratio / 100);
                        const a = area.splitLeft(first_w);
                        const div = a.rest.splitLeft(1);
                        try dividers.append(arena, div.left);
                        try self.rectsFor(s.first, a.left, arena, panes, dividers);
                        try self.rectsFor(s.second, div.rest, arena, panes, dividers);
                    },
                    .vertical => {
                        const first_h: u16 = @intCast(@as(u32, area.h) * ratio / 100);
                        const a = area.splitTop(first_h);
                        const div = a.rest.splitTop(1);
                        try dividers.append(arena, div.top);
                        try self.rectsFor(s.first, a.top, arena, panes, dividers);
                        try self.rectsFor(s.second, div.rest, arena, panes, dividers);
                    },
                }
            },
            .free => {},
        }
    }

    /// Every pane in every leaf, tabs included, in tree + tab order.
    pub fn allPanes(self: *const Layout, arena: Allocator) Allocator.Error![]PaneId {
        var out: std.ArrayListUnmanaged(PaneId) = .empty;
        for (try self.leaves(arena)) |lid| {
            for (self.nodes.items[lid].leaf.tabs.items) |t| try out.append(arena, t);
        }
        return out.items;
    }
};

/// Tab pages: a list of layouts and which one is showing.
pub const LayoutState = struct {
    gpa: Allocator,
    layouts: std.ArrayListUnmanaged(Layout) = .empty,
    active: usize = 0,

    pub fn init(gpa: Allocator) Allocator.Error!LayoutState {
        var s: LayoutState = .{ .gpa = gpa };
        try s.layouts.append(gpa, Layout.init(gpa));
        return s;
    }

    pub fn deinit(self: *LayoutState) void {
        for (self.layouts.items) |*l| l.deinit();
        self.layouts.deinit(self.gpa);
    }

    pub fn current(self: *LayoutState) *Layout {
        return &self.layouts.items[self.active];
    }
};

test "layout: leaf tabs, close falls to the right neighbour then left, split + collapse, rects" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const leaf0 = try l.showIn(null, 0);
    _ = try l.showIn(leaf0, 1);
    _ = try l.showIn(leaf0, 2);
    try std.testing.expectEqualSlices(PaneId, &.{ 0, 1, 2 }, try l.allPanes(a));
    try std.testing.expectEqual(@as(PaneId, 2), l.leaf(leaf0).?.active);
    // Re-showing an existing tab just activates it.
    _ = try l.showIn(leaf0, 0);
    try std.testing.expectEqual(@as(PaneId, 0), l.leaf(leaf0).?.active);
    try std.testing.expectEqual(@as(usize, 3), l.leaf(leaf0).?.tabs.items.len);
    // Closing the active tab in the middle → the right neighbour.
    l.leaf(leaf0).?.active = 1;
    try std.testing.expectEqual(@as(PaneId, 2), l.removePane(1).?);
    // Closing the last tab → the left neighbour.
    try std.testing.expectEqual(@as(PaneId, 0), l.removePane(2).?);
    // Split right, then rects.
    const right = (try l.split(0, .horizontal, 7)).?;
    const rects = try l.computeRects(Rect.init(0, 1, 100, 20), a);
    try std.testing.expectEqual(@as(usize, 2), rects.panes.len);
    try std.testing.expectEqual(@as(usize, 1), rects.dividers.len);
    try std.testing.expectEqual(@as(u16, 50), rects.panes[0].rect.w);
    try std.testing.expectEqual(@as(u16, 51), rects.panes[1].rect.x);
    try std.testing.expectEqual(@as(u16, 49), rects.panes[1].rect.w);
    try std.testing.expectEqual(right, l.leafOf(7).?);
    // Removing the right pane collapses the split back into one leaf.
    try std.testing.expect(l.removePane(7) == null);
    const after = try l.computeRects(Rect.init(0, 1, 100, 20), a);
    try std.testing.expectEqual(@as(usize, 1), after.panes.len);
    try std.testing.expectEqual(@as(u16, 100), after.panes[0].rect.w);
    try std.testing.expectEqual(@as(PaneId, 0), after.panes[0].pane);
    // Removing the last pane empties the layout.
    try std.testing.expect(l.removePane(0) == null);
    try std.testing.expect(l.isEmpty());
}

test "layout: showing the last tab of one leaf in another keeps the target leaf's id" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const left = try l.showIn(null, 0);
    const right = (try l.split(0, .horizontal, 1)).?;
    // Move pane 0 (alone in `left`) into `right`: `left` collapses and
    // `right` must still be the node the caller named.
    const shown = try l.showIn(right, 0);
    try std.testing.expectEqual(right, shown);
    try std.testing.expect(l.leaf(right) != null);
    try std.testing.expectEqualSlices(PaneId, &.{ 1, 0 }, l.leaf(right).?.tabs.items);
    try std.testing.expectEqual(right, l.root.?);
    try std.testing.expect(l.leaf(left) == null);
    const rects = try l.computeRects(Rect.init(0, 1, 100, 20), arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), rects.panes.len);
    // Three leaves: dropping the middle one re-hangs its sibling on the grandparent.
    const l3 = (try l.split(0, .vertical, 2)).?;
    _ = try l.split(2, .horizontal, 3);
    try std.testing.expect(l.removePane(2) == null);
    try std.testing.expect(l.leaf(l3) == null);
    const after = try l.computeRects(Rect.init(0, 1, 100, 20), arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), after.panes.len);
}
