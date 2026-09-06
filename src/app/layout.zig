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

/// Where `moveToEdge` puts a pane: the far side of the whole tree.
pub const Edge = enum { left, right, top, bottom };

pub const Leaf = struct {
    active: PaneId,
    /// Insertion order; never empty while the leaf is live.
    tabs: std.ArrayListUnmanaged(PaneId) = .empty,
    /// The tab strip's window: the first painted position. The wheel
    /// and the `‹ ›` markers move it; a change of active tab re-fits
    /// it so the active tab is in view (`strip_anchor` remembers which
    /// active tab the window was fitted for).
    strip_first: usize = 0,
    strip_anchor: ?PaneId = null,
    /// Tabs past the window's right edge as of the last paint — what a
    /// wheel-down has to scroll into.
    strip_hidden_right: usize = 0,
};

pub const Node = union(enum) {
    leaf: Leaf,
    split: struct { dir: SplitDir, ratio: u16, first: NodeId, second: NodeId },
    /// A freed slot.
    free,
};

pub const PaneRect = struct { pane: PaneId, rect: Rect, leaf: NodeId };
/// A divider between the two halves of `split`, which was laid out in
/// `area` — what a drag needs to turn a pointer cell into a new ratio.
pub const DividerRect = struct { rect: Rect, split: NodeId, dir: SplitDir, area: Rect };
pub const Rects = struct { panes: []PaneRect, dividers: []DividerRect };

/// The smallest a half may be dragged to: a pane keeps a gutter and a
/// few text columns, a stacked pane keeps its strip and a couple of rows.
pub const min_pane_w: u16 = 10;
pub const min_pane_h: u16 = 3;

/// Cells the first half gets of `len` at `ratio` percent, keeping both
/// halves at least `min` when `len` allows it (the divider takes one).
pub fn firstLen(len: u16, ratio: u16, min: u16) u16 {
    const r: u32 = std.math.clamp(ratio, 1, 99);
    var first: u16 = @intCast(@as(u32, len) * r / 100);
    if (len >= 2 * min + 1) {
        first = std.math.clamp(first, min, len - 1 - min);
    }
    return first;
}

/// The ratio that puts the divider at `pos` cells into `len`: the
/// percent whose `firstLen` lands on that cell. `firstLen` floors, so
/// the percent is rounded up, not down — `⌊len · ⌊100·pos/len⌋ / 100⌋`
/// is one cell short whenever the division is inexact, and a dragged
/// divider settled a column left of the pointer every time. Past 100
/// cells a whole percent skips cells; the nearer of the two candidates
/// wins there.
pub fn ratioAt(len: u16, pos: u16) u16 {
    if (len == 0) return 50;
    const up: u16 = @intCast(std.math.clamp((@as(u32, pos) * 100 + len - 1) / len, 1, 99));
    const down: u16 = @max(up -| 1, 1);
    return if (distance(len, up, pos) <= distance(len, down, pos)) up else down;
}

fn distance(len: u16, ratio: u16, pos: u16) u32 {
    const at = @as(u32, len) * ratio / 100;
    return if (at > pos) at - pos else pos - at;
}

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

    pub fn parentOf(self: *const Layout, id: NodeId) ?NodeId {
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

    /// Take the leaf `lid` out of the tree without releasing it: its
    /// sibling takes the parent split's place (or the root). The leaf
    /// keeps its id and its tabs; the caller re-hangs it.
    fn detachLeaf(self: *Layout, lid: NodeId) void {
        const pid = self.parentOf(lid) orelse return;
        const s = self.nodes.items[pid].split;
        const sibling = if (s.first == lid) s.second else s.first;
        if (self.parentOf(pid)) |gp| {
            const g = &self.nodes.items[gp].split;
            if (g.first == pid) g.first = sibling else g.second = sibling;
        } else self.root = sibling;
        self.nodes.items[pid] = .free;
    }

    /// `Ctrl-W H/J/K/L`: `pane` becomes a full-height (left / right) or
    /// full-width (top / bottom) edge of the whole tree. A pane sharing
    /// its leaf with other tabs moves out into a leaf of its own; a pane
    /// alone in its leaf takes the leaf with it. A single-leaf layout is
    /// a no-op. The moved leaf stays the one holding `pane` (its active
    /// tab), so the focused pane is still in a leaf afterwards.
    pub fn moveToEdge(self: *Layout, pane: PaneId, edge: Edge) Allocator.Error!void {
        const lid = self.leafOf(pane) orelse return;
        const root = self.root orelse return;
        if (root == lid) return;
        const l = self.leaf(lid).?;
        const alone = l.tabs.items.len == 1;
        // Every allocation happens before the first mutation, so a
        // failed one leaves the tree as it was.
        const moved: NodeId = if (alone) lid else blk: {
            var nl: Leaf = .{ .active = pane };
            try nl.tabs.append(self.gpa, pane);
            errdefer nl.tabs.deinit(self.gpa);
            break :blk try self.alloc(.{ .leaf = nl });
        };
        errdefer if (!alone) self.release(moved);
        const dir: SplitDir = switch (edge) {
            .left, .right => .horizontal,
            .top, .bottom => .vertical,
        };
        // The halves are filled in after the detach; until then they
        // name no node, so `parentOf` cannot mistake this split for
        // the moved leaf's parent.
        const none = std.math.maxInt(NodeId);
        const new_root = try self.alloc(.{ .split = .{ .dir = dir, .ratio = 50, .first = none, .second = none } });
        if (alone) {
            self.detachLeaf(lid);
        } else {
            const old = self.leaf(lid).?;
            const idx = std.mem.indexOfScalar(PaneId, old.tabs.items, pane).?;
            _ = old.tabs.orderedRemove(idx);
            if (old.active == pane) old.active = old.tabs.items[@min(idx, old.tabs.items.len - 1)];
        }
        const rest = self.root.?;
        const s = &self.nodes.items[new_root].split;
        switch (edge) {
            .left, .top => {
                s.first = moved;
                s.second = rest;
            },
            .right, .bottom => {
                s.first = rest;
                s.second = moved;
            },
        }
        self.root = new_root;
    }

    /// Set a split's ratio so its divider lands `pos` cells into the
    /// split's `area` (which `computeRects` reports per divider).
    pub fn setRatio(self: *Layout, split_id: NodeId, ratio: u16) void {
        switch (self.nodes.items[split_id]) {
            .split => |*s| s.ratio = std.math.clamp(ratio, 1, 99),
            else => {},
        }
    }

    /// Every split back to 50/50 (vim `Ctrl+W =`).
    pub fn equalize(self: *Layout) void {
        for (self.nodes.items) |*n| switch (n.*) {
            .split => |*s| s.ratio = 50,
            else => {},
        };
    }

    /// Move `pane` to position `idx` among the tabs of the leaf it is
    /// in. Out-of-range appends.
    pub fn reorderTab(self: *Layout, pane: PaneId, idx: usize) void {
        const lid = self.leafOf(pane) orelse return;
        const l = self.leaf(lid).?;
        const cur = std.mem.indexOfScalar(PaneId, l.tabs.items, pane) orelse return;
        _ = l.tabs.orderedRemove(cur);
        const at = @min(idx, l.tabs.items.len);
        l.tabs.insertAssumeCapacity(at, pane);
    }

    /// Every pane rect plus divider rects for `area`.
    pub fn computeRects(self: *const Layout, area: Rect, arena: Allocator) Allocator.Error!Rects {
        var panes: std.ArrayListUnmanaged(PaneRect) = .empty;
        var dividers: std.ArrayListUnmanaged(DividerRect) = .empty;
        if (self.root) |r| try self.rectsFor(r, area, arena, &panes, &dividers);
        return .{ .panes = panes.items, .dividers = dividers.items };
    }

    fn rectsFor(self: *const Layout, id: NodeId, area: Rect, arena: Allocator, panes: *std.ArrayListUnmanaged(PaneRect), dividers: *std.ArrayListUnmanaged(DividerRect)) Allocator.Error!void {
        switch (self.nodes.items[id]) {
            .leaf => |l| try panes.append(arena, .{ .pane = l.active, .rect = area, .leaf = id }),
            .split => |s| {
                switch (s.dir) {
                    .horizontal => {
                        const a = area.splitLeft(firstLen(area.w, s.ratio, min_pane_w));
                        const div = a.rest.splitLeft(1);
                        try dividers.append(arena, .{ .rect = div.left, .split = id, .dir = s.dir, .area = area });
                        try self.rectsFor(s.first, a.left, arena, panes, dividers);
                        try self.rectsFor(s.second, div.rest, arena, panes, dividers);
                    },
                    .vertical => {
                        const a = area.splitTop(firstLen(area.h, s.ratio, min_pane_h));
                        const div = a.rest.splitTop(1);
                        try dividers.append(arena, .{ .rect = div.top, .split = id, .dir = s.dir, .area = area });
                        try self.rectsFor(s.first, a.top, arena, panes, dividers);
                        try self.rectsFor(s.second, div.rest, arena, panes, dividers);
                    },
                }
            },
            .free => {},
        }
    }

    /// The leaf at position `idx` of `leaves` order, if any.
    pub fn leafAt(self: *const Layout, arena: Allocator, idx: usize) Allocator.Error!?NodeId {
        const ls = try self.leaves(arena);
        return if (idx < ls.len) ls[idx] else null;
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

// ─── drop zones ─────────────────────────────────────────────────────────

/// Where a dragged tab or file lands on a pane body: an edge splits the
/// pane in that direction, the centre moves the drop into it.
pub const DropZone = enum { left, right, top, bottom, center };

/// The middle third on both axes is the centre; otherwise the nearest
/// edge, distances normalised so a tall narrow pane compares fairly.
pub fn zoneFor(r: Rect, x: u16, y: u16) DropZone {
    const w: u32 = @max(r.w, 1);
    const h: u32 = @max(r.h, 1);
    const dx: u32 = x -| r.x;
    const dy: u32 = y -| r.y;
    const center_x = dx * 3 >= w and dx * 3 < w * 2;
    const center_y = dy * 3 >= h and dy * 3 < h * 2;
    if (center_x and center_y) return .center;
    const left = dx * 1000 / w;
    const right = 1000 -| left;
    const top = dy * 1000 / h;
    const bottom = 1000 -| top;
    const m = @min(@min(left, right), @min(top, bottom));
    if (m == left) return .left;
    if (m == top) return .top;
    if (m == bottom) return .bottom;
    return .right;
}

/// The part of a pane body a zone covers — what the drop hint tints.
pub fn zoneRect(r: Rect, zone: DropZone) Rect {
    return switch (zone) {
        .left => Rect.init(r.x, r.y, r.w / 2, r.h),
        .right => Rect.init(r.x + (r.w - r.w / 2), r.y, r.w / 2, r.h),
        .top => Rect.init(r.x, r.y, r.w, r.h / 2),
        .bottom => Rect.init(r.x, r.y + (r.h - r.h / 2), r.w, r.h / 2),
        .center => Rect.init(r.x + r.w / 3, r.y + r.h / 3, @max(r.w / 3, 1), @max(r.h / 3, 1)),
    };
}

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

test "ratioAt lands the divider on the pointer's cell at every width up to 100, and within one past it" {
    var len: u16 = 2;
    while (len <= 100) : (len += 1) {
        var pos: u16 = 1;
        while (pos < len) : (pos += 1) try std.testing.expectEqual(pos, firstLen(len, ratioAt(len, pos), 0));
    }
    // 89 cells (120 columns less the tree): the finding's drags.
    try std.testing.expectEqual(@as(u16, 69), firstLen(89, ratioAt(89, 69), min_pane_w));
    try std.testing.expectEqual(@as(u16, 29), firstLen(89, ratioAt(89, 29), min_pane_w));
    try std.testing.expectEqual(@as(u16, 59), firstLen(89, ratioAt(89, 59), min_pane_w));
    // Past 100 cells a percent is more than a cell; inside the 1 %–99 %
    // range the divider lands within a cell of the pointer.
    len = 101;
    while (len <= 240) : (len += 1) {
        var pos: u16 = len / 50 + 1;
        while (pos + len / 50 + 1 < len) : (pos += 1) {
            const at = firstLen(len, ratioAt(len, pos), 0);
            try std.testing.expect(@max(at, pos) - @min(at, pos) <= 1);
        }
    }
}

test "layout: min sizes clamp a dragged ratio, equalize resets, tabs reorder, dividers name their split" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const left = try l.showIn(null, 0);
    _ = try l.showIn(left, 1);
    _ = try l.showIn(left, 2);
    l.reorderTab(2, 0);
    try std.testing.expectEqualSlices(PaneId, &.{ 2, 0, 1 }, l.leaf(left).?.tabs.items);
    l.reorderTab(2, 99);
    try std.testing.expectEqualSlices(PaneId, &.{ 0, 1, 2 }, l.leaf(left).?.tabs.items);
    _ = try l.split(0, .horizontal, 7);
    const rects = try l.computeRects(Rect.init(0, 1, 100, 20), a);
    try std.testing.expectEqual(@as(usize, 1), rects.dividers.len);
    const d = rects.dividers[0];
    try std.testing.expectEqual(SplitDir.horizontal, d.dir);
    try std.testing.expectEqual(@as(u16, 50), d.rect.x);
    try std.testing.expect(d.area.eql(Rect.init(0, 1, 100, 20)));
    // Drag the divider to column 3: the left half keeps its minimum.
    l.setRatio(d.split, ratioAt(d.area.w, 3));
    const dragged = try l.computeRects(Rect.init(0, 1, 100, 20), a);
    try std.testing.expectEqual(min_pane_w, dragged.panes[0].rect.w);
    // ...and to column 97: the right half keeps its minimum.
    l.setRatio(d.split, ratioAt(d.area.w, 97));
    const far = try l.computeRects(Rect.init(0, 1, 100, 20), a);
    try std.testing.expectEqual(min_pane_w, far.panes[1].rect.w);
    try std.testing.expectEqual(@as(u16, 100 - min_pane_w - 1), far.panes[0].rect.w);
    l.equalize();
    const eq = try l.computeRects(Rect.init(0, 1, 100, 20), a);
    try std.testing.expectEqual(@as(u16, 50), eq.panes[0].rect.w);
    // Too narrow for two minimums: the ratio rules, nothing panics.
    l.setRatio(d.split, 1);
    const tiny = try l.computeRects(Rect.init(0, 1, 12, 20), a);
    try std.testing.expectEqual(@as(usize, 2), tiny.panes.len);
    try std.testing.expectEqual(@as(u16, 0), tiny.panes[0].rect.w);
    // The leaf ids survive a remove: pane 7's leaf goes, pane 0's leaf
    // (the split moved it out of `left`, which became the split node)
    // keeps its id and is the first — only — leaf.
    const l0 = l.leafOf(0).?;
    try std.testing.expect(l.removePane(7) == null);
    try std.testing.expectEqual(l0, l.leafOf(0).?);
    try std.testing.expectEqual(l0, (try l.leafAt(a, 0)).?);
    try std.testing.expect((try l.leafAt(a, 1)) == null);
}

/// The rect `computeRects` gives `pane` over `area`, or null.
fn rectOf(l: *const Layout, area: Rect, arena: Allocator, pane: PaneId) !?Rect {
    const rects = try l.computeRects(area, arena);
    for (rects.panes) |pr| if (pr.pane == pane) return pr.rect;
    return null;
}

test "layout: moveToEdge makes the pane a full edge of the whole tree; the other leaves keep their ids" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const area = Rect.init(0, 1, 100, 40);
    // Three leaves: 0 | (1 / 2) — pane 2 is the bottom-right quarter.
    _ = try l.showIn(null, 0);
    _ = try l.split(0, .horizontal, 1);
    _ = try l.split(1, .vertical, 2);
    // `split` re-slots the leaf it splits, so read the ids after building.
    const leaf0 = l.leafOf(0).?;
    const leaf1 = l.leafOf(1).?;
    const leaf2 = l.leafOf(2).?;
    const before = (try rectOf(&l, area, a, 2)).?;
    try std.testing.expect(before.h < area.h and before.w < area.w);
    try std.testing.expectEqual(@as(usize, 3), (try l.leaves(a)).len);

    // Left: pane 2 spans the full height at x = 0; nothing else moved.
    try l.moveToEdge(2, .left);
    const left = (try rectOf(&l, area, a, 2)).?;
    try std.testing.expectEqual(@as(u16, 0), left.x);
    try std.testing.expectEqual(area.h, left.h);
    try std.testing.expectEqual(leaf2, l.leafOf(2).?);
    try std.testing.expectEqual(@as(PaneId, 2), l.leaf(leaf2).?.active);
    try std.testing.expectEqual(leaf0, l.leafOf(0).?);
    try std.testing.expectEqual(leaf1, l.leafOf(1).?);
    try std.testing.expectEqual(@as(usize, 3), (try l.leaves(a)).len);
    try std.testing.expectEqualSlices(NodeId, &.{ leaf2, leaf0, leaf1 }, try l.leaves(a));

    // Right: full height, flush with the right edge.
    try l.moveToEdge(2, .right);
    const right = (try rectOf(&l, area, a, 2)).?;
    try std.testing.expectEqual(area.right(), right.right());
    try std.testing.expectEqual(area.h, right.h);
    try std.testing.expectEqualSlices(NodeId, &.{ leaf0, leaf1, leaf2 }, try l.leaves(a));

    // Top: full width along the top row.
    try l.moveToEdge(2, .top);
    const top = (try rectOf(&l, area, a, 2)).?;
    try std.testing.expectEqual(area.y, top.y);
    try std.testing.expectEqual(area.w, top.w);
    try std.testing.expectEqualSlices(NodeId, &.{ leaf2, leaf0, leaf1 }, try l.leaves(a));

    // Bottom: full width along the bottom row; 0 and 1 still side by side.
    try l.moveToEdge(2, .bottom);
    const bottom = (try rectOf(&l, area, a, 2)).?;
    try std.testing.expectEqual(area.bottom(), bottom.bottom());
    try std.testing.expectEqual(area.w, bottom.w);
    const r0 = (try rectOf(&l, area, a, 0)).?;
    const r1 = (try rectOf(&l, area, a, 1)).?;
    try std.testing.expectEqual(r0.y, r1.y);
    try std.testing.expect(r1.x > r0.x);
    try std.testing.expectEqual(@as(usize, 3), (try l.leaves(a)).len);
    // Every node not in the tree is a freed slot: no split leaked.
    var live: usize = 0;
    for (l.nodes.items) |n| if (n != .free) {
        live += 1;
    };
    try std.testing.expectEqual(@as(usize, 5), live); // 3 leaves + 2 splits
}

test "layout: moveToEdge on a pane sharing its leaf moves only that tab; a single leaf is a no-op" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const area = Rect.init(0, 1, 100, 40);
    // One leaf with two tabs: nothing to move against.
    const only = try l.showIn(null, 0);
    _ = try l.showIn(only, 1);
    try l.moveToEdge(1, .left);
    try std.testing.expectEqual(only, l.root.?);
    try std.testing.expectEqualSlices(PaneId, &.{ 0, 1 }, l.leaf(only).?.tabs.items);
    // A pane in no leaf is a no-op too.
    try l.moveToEdge(9, .top);
    try std.testing.expectEqual(only, l.root.?);
    // Two leaves; pane 1 shares leaf0 with pane 0 and is its active tab.
    const leaf7 = (try l.split(0, .horizontal, 7)).?;
    const leaf0 = l.leafOf(0).?;
    l.leaf(leaf0).?.active = 1;
    try l.moveToEdge(1, .right);
    // Pane 1 left leaf0 (which fell back to pane 0) for a leaf of its own.
    try std.testing.expectEqualSlices(PaneId, &.{0}, l.leaf(leaf0).?.tabs.items);
    try std.testing.expectEqual(@as(PaneId, 0), l.leaf(leaf0).?.active);
    const leaf1 = l.leafOf(1).?;
    try std.testing.expect(leaf1 != leaf0 and leaf1 != leaf7);
    try std.testing.expectEqual(@as(PaneId, 1), l.leaf(leaf1).?.active);
    try std.testing.expectEqualSlices(NodeId, &.{ leaf0, leaf7, leaf1 }, try l.leaves(a));
    const r1 = (try rectOf(&l, area, a, 1)).?;
    try std.testing.expectEqual(area.right(), r1.right());
    try std.testing.expectEqual(area.h, r1.h);
    try std.testing.expectEqualSlices(PaneId, &.{ 0, 7, 1 }, try l.allPanes(a));
}

test "drop zones: the middle third is the centre, otherwise the nearest edge" {
    const r = Rect.init(10, 5, 30, 20);
    try std.testing.expectEqual(DropZone.center, zoneFor(r, 25, 15));
    try std.testing.expectEqual(DropZone.left, zoneFor(r, 11, 15));
    try std.testing.expectEqual(DropZone.right, zoneFor(r, 39, 15));
    try std.testing.expectEqual(DropZone.top, zoneFor(r, 25, 5));
    try std.testing.expectEqual(DropZone.bottom, zoneFor(r, 25, 24));
    try std.testing.expect(zoneRect(r, .left).eql(Rect.init(10, 5, 15, 20)));
    try std.testing.expect(zoneRect(r, .bottom).eql(Rect.init(10, 15, 30, 10)));
    try std.testing.expect(zoneRect(r, .center).eql(Rect.init(20, 11, 10, 6)));
    // A degenerate rect never divides by zero.
    _ = zoneFor(Rect.empty, 0, 0);
}
