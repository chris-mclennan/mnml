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
    /// A slot kept open in the tree: the AI grid's placeholder
    /// quadrant. It is laid out like a leaf (it gets a rect and a
    /// share of its split) but shows no pane; `fillFirstEmpty` turns
    /// it into a leaf, and it goes with its split when the sibling is
    /// removed, as an emptied leaf does.
    empty,
    /// A freed slot.
    free,
};

pub const PaneRect = struct { pane: PaneId, rect: Rect, leaf: NodeId };
/// A divider between the two halves of `split`, which was laid out in
/// `area` — what a drag needs to turn a pointer cell into a new ratio.
pub const DividerRect = struct { rect: Rect, split: NodeId, dir: SplitDir, area: Rect };
/// An `.empty` node's rect — what the placeholder card paints into.
pub const EmptyRect = struct { rect: Rect, node: NodeId };
pub const Rects = struct { panes: []PaneRect, dividers: []DividerRect, empties: []EmptyRect = &.{} };

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
    /// `view.toggle_zoom`: the pane whose leaf alone paints over this
    /// page's body. Per page — each tab page keeps its own, and
    /// `session.zon` writes it down per page. The tree underneath is
    /// untouched, so un-zooming is clearing this and nothing else: the
    /// ratios, the focus and the other leaves are where they were.
    ///
    /// Anything that changes the TREE drops it here, at the mutation,
    /// rather than at every command that happens to split, close or
    /// move: a split, a leaf going, a move to an edge, a merge or a
    /// spread. A tab switch inside the zoomed leaf, a resize or a new
    /// tab in it is not a change to the tree and keeps it.
    zoomed: ?PaneId = null,

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
    pub fn leafOf(self: *const Layout, pane: PaneId) ?NodeId {
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
            .empty, .free => {},
        }
    }

    /// The pane the focus lands on when this page comes on screen: the
    /// zoomed one on a zoomed page — landing anywhere else would move
    /// the zoom, which follows the focus — else the first leaf's shown
    /// tab.
    pub fn landing(self: *const Layout) ?PaneId {
        if (self.zoomed) |z| if (self.leafOf(z) != null) return z;
        const l = self.firstLeaf() orelse return null;
        return self.nodes.items[l].leaf.active;
    }

    /// The first leaf in tree order — past any `.empty` slot.
    pub fn firstLeaf(self: *const Layout) ?NodeId {
        return self.firstLeafUnder(self.root orelse return null);
    }

    fn firstLeafUnder(self: *const Layout, id: NodeId) ?NodeId {
        return switch (self.nodes.items[id]) {
            .leaf => id,
            .split => |s| self.firstLeafUnder(s.first) orelse self.firstLeafUnder(s.second),
            .empty, .free => null,
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
        // The zoomed pane closing is the zoom going, whatever its leaf
        // still holds.
        if (self.zoomed == pane) self.zoomed = null;
        if (l.tabs.items.len == 0) {
            self.removeNode(lid);
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

    /// Take a leaf or an `.empty` slot out of the tree. The sibling
    /// takes the split's place in the grandparent (or as the root); its
    /// own id stays, so a `NodeId` a caller is holding for it —
    /// `showIn`'s target while it drops a tab elsewhere — is still that
    /// leaf. A sibling that is itself `.empty` goes too: a split of
    /// nothing but a placeholder has no reason to stay.
    fn removeNode(self: *Layout, id: NodeId) void {
        self.zoomed = null;
        if (self.parentOf(id)) |pid| {
            const s = self.nodes.items[pid].split;
            const sibling = if (s.first == id) s.second else s.first;
            if (self.parentOf(pid)) |gp| {
                const g = &self.nodes.items[gp].split;
                if (g.first == pid) g.first = sibling else g.second = sibling;
            } else self.root = sibling;
            self.nodes.items[pid] = .free;
            self.release(id);
            if (self.nodes.items[sibling] == .empty) self.removeNode(sibling);
        } else {
            self.release(id);
            self.root = null;
        }
    }

    /// Split the leaf holding `pane`: the new leaf shows `new_pane` and
    /// sits after (right / below). Returns the new leaf.
    pub fn split(self: *Layout, pane: PaneId, dir: SplitDir, new_pane: PaneId) Allocator.Error!?NodeId {
        const lid = self.leafOf(pane) orelse return null;
        self.zoomed = null;
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
        self.zoomed = null;
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

    /// Every slot an equal share (vim `Ctrl+W =`): a split's ratio is
    /// the count of leaves (and `.empty` slots) under its first half
    /// over the count under both, so a row of three is 33 / 33 / 33
    /// and not 50 / 25 / 25. Clamped to 10..90 like a drag.
    pub fn equalize(self: *Layout) void {
        if (self.root) |r| _ = self.equalizeUnder(r);
    }

    fn equalizeUnder(self: *Layout, id: NodeId) u32 {
        return switch (self.nodes.items[id]) {
            .leaf, .empty => 1,
            .split => |*s| blk: {
                const first = self.equalizeUnder(s.first);
                const total = first + self.equalizeUnder(s.second);
                if (total > 0) s.ratio = @intCast(std.math.clamp(first * 100 / total, 10, 90));
                break :blk total;
            },
            .free => 0,
        };
    }

    /// Every slot along ONE axis an equal share: the run of
    /// same-direction splits that `split_id` belongs to is shared out
    /// between its halves, and a subtree that splits the OTHER way
    /// counts as one slot and keeps the proportions inside it. So a
    /// third pane opened into a row of two makes thirds without
    /// flattening the stack living in one of the columns — which is
    /// what `equalize`, weighing the whole tree by leaf count, does.
    pub fn equalizeAxis(self: *Layout, split_id: NodeId) void {
        const top = self.axisRoot(split_id);
        const dir = switch (self.nodes.items[top]) {
            .split => |s| s.dir,
            else => return,
        };
        self.equalizeAxisUnder(top, dir);
    }

    /// The highest split of the unbroken run of `id`-direction splits
    /// that `id` is part of. A non-split is its own root.
    pub fn axisRoot(self: *const Layout, id: NodeId) NodeId {
        const dir = switch (self.nodes.items[id]) {
            .split => |s| s.dir,
            else => return id,
        };
        var cur = id;
        while (self.parentOf(cur)) |p| {
            const up = switch (self.nodes.items[p]) {
                .split => |s| s,
                else => break,
            };
            if (up.dir != dir) break;
            cur = p;
        }
        return cur;
    }

    /// Slots `id` occupies along `dir`: a run of `dir` splits counts
    /// its halves, anything else — a leaf, an `.empty`, a subtree that
    /// splits the other way — is one.
    fn axisSlots(self: *const Layout, id: NodeId, dir: SplitDir) u32 {
        return switch (self.nodes.items[id]) {
            .split => |s| if (s.dir == dir) self.axisSlots(s.first, dir) + self.axisSlots(s.second, dir) else 1,
            .free => 0,
            .leaf, .empty => 1,
        };
    }

    fn equalizeAxisUnder(self: *Layout, id: NodeId, dir: SplitDir) void {
        switch (self.nodes.items[id]) {
            .split => |*s| {
                if (s.dir != dir) return;
                const first = self.axisSlots(s.first, dir);
                const total = first + self.axisSlots(s.second, dir);
                if (total > 0) s.ratio = @intCast(std.math.clamp(first * 100 / total, 10, 90));
                const halves = .{ s.first, s.second };
                self.equalizeAxisUnder(halves[0], dir);
                self.equalizeAxisUnder(halves[1], dir);
            },
            else => {},
        }
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
        var out: RectLists = .{};
        if (self.root) |r| try self.rectsFor(r, area, arena, &out);
        return .{ .panes = out.panes.items, .dividers = out.dividers.items, .empties = out.empties.items };
    }

    const RectLists = struct {
        panes: std.ArrayListUnmanaged(PaneRect) = .empty,
        dividers: std.ArrayListUnmanaged(DividerRect) = .empty,
        empties: std.ArrayListUnmanaged(EmptyRect) = .empty,
    };

    fn rectsFor(self: *const Layout, id: NodeId, area: Rect, arena: Allocator, out: *RectLists) Allocator.Error!void {
        const panes = &out.panes;
        const dividers = &out.dividers;
        const empties = &out.empties;
        switch (self.nodes.items[id]) {
            .leaf => |l| try panes.append(arena, .{ .pane = l.active, .rect = area, .leaf = id }),
            .split => |s| {
                switch (s.dir) {
                    .horizontal => {
                        const a = area.splitLeft(firstLen(area.w, s.ratio, min_pane_w));
                        const div = a.rest.splitLeft(1);
                        try dividers.append(arena, .{ .rect = div.left, .split = id, .dir = s.dir, .area = area });
                        try self.rectsFor(s.first, a.left, arena, out);
                        try self.rectsFor(s.second, div.rest, arena, out);
                    },
                    .vertical => {
                        const a = area.splitTop(firstLen(area.h, s.ratio, min_pane_h));
                        const div = a.rest.splitTop(1);
                        try dividers.append(arena, .{ .rect = div.top, .split = id, .dir = s.dir, .area = area });
                        try self.rectsFor(s.first, a.top, arena, out);
                        try self.rectsFor(s.second, div.rest, arena, out);
                    },
                }
            },
            .empty => try empties.append(arena, .{ .rect = area, .node = id }),
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

    /// `layout.merge_to_tabs`: every pane of the split tree becomes a
    /// tab of ONE leaf, in `allPanes` order; `active` stays the active
    /// tab when it is one of them (else the first). Returns how many
    /// leaves were merged; a single leaf (or an empty layout) is left
    /// as it is and reports its own count.
    pub fn mergeToTabs(self: *Layout, arena: Allocator, active: PaneId) Allocator.Error!usize {
        const ls = try self.leaves(arena);
        if (ls.len < 2) return ls.len;
        self.zoomed = null;
        const panes = try arena.dupe(PaneId, try self.allPanes(arena));
        const shown: PaneId = if (std.mem.indexOfScalar(PaneId, panes, active) != null) active else panes[0];
        // The merged leaf is filled before anything is torn down, so a
        // failed allocation leaves the tree as it was.
        var merged: Leaf = .{ .active = shown };
        errdefer merged.tabs.deinit(self.gpa);
        try merged.tabs.appendSlice(self.gpa, panes);
        for (self.nodes.items) |*n| switch (n.*) {
            .leaf => |*l| l.tabs.deinit(self.gpa),
            else => {},
        };
        self.nodes.clearRetainingCapacity();
        self.root = null;
        self.root = try self.alloc(.{ .leaf = merged });
        return ls.len;
    }

    /// `layout.spread_to_splits`: the inverse — a single leaf's tabs
    /// each get a leaf of their own, side by side in tab order (a
    /// chain of splits whose ratios give every leaf the same width).
    /// Returns the number of leaves made; a layout with splits, or a
    /// leaf with one tab, is left alone and reports 0.
    pub fn spreadToSplits(self: *Layout, arena: Allocator) Allocator.Error!usize {
        const root = self.root orelse return 0;
        const l = self.leaf(root) orelse return 0;
        if (l.tabs.items.len < 2) return 0;
        self.zoomed = null;
        const tabs = try arena.dupe(PaneId, l.tabs.items);
        const first = tabs[0];
        l.tabs.shrinkRetainingCapacity(1);
        l.active = first;
        var prev = first;
        for (tabs[1..]) |t| {
            _ = try self.split(prev, .horizontal, t);
            prev = t;
        }
        // a | (b | (c | d)): the i-th split's first half is one of the
        // `n - i` leaves left, so its share is 1/(n - i).
        var remaining: u16 = @intCast(tabs.len);
        var id = self.root.?;
        while (self.nodes.items[id] == .split) {
            const s = &self.nodes.items[id].split;
            s.ratio = @max(100 / remaining, 1);
            remaining -= 1;
            id = s.second;
        }
        return tabs.len;
    }

    // ─── the AI grid's slots ────────────────────────────────────────────

    /// Whether the tree holds an `.empty` slot.
    pub fn containsEmpty(self: *const Layout) bool {
        for (self.nodes.items) |n| if (n == .empty) return true;
        return false;
    }

    /// The first `.empty` slot in tree order becomes a leaf showing
    /// `pane`; returns that leaf, or null when there is no slot.
    pub fn fillFirstEmpty(self: *Layout, pane: PaneId) Allocator.Error!?NodeId {
        const id = self.firstEmptyUnder(self.root orelse return null) orelse return null;
        self.zoomed = null;
        var l: Leaf = .{ .active = pane };
        try l.tabs.append(self.gpa, pane);
        self.nodes.items[id] = .{ .leaf = l };
        return id;
    }

    fn firstEmptyUnder(self: *const Layout, id: NodeId) ?NodeId {
        return switch (self.nodes.items[id]) {
            .empty => id,
            .split => |s| self.firstEmptyUnder(s.first) orelse self.firstEmptyUnder(s.second),
            .leaf, .free => null,
        };
    }

    pub const PairSplit = struct { split: NodeId, dir: SplitDir };

    /// The split whose two halves are single-tab leaves of `a` and `b`
    /// (either order), if the tree has one — the shape the third AI
    /// session grows into a grid. A nested pair, a leaf with more tabs,
    /// or the two apart is null.
    pub fn findLeafPairSplit(self: *const Layout, a: PaneId, b: PaneId) ?PairSplit {
        for (self.nodes.items, 0..) |n, i| switch (n) {
            .split => |s| {
                if ((self.isSingleLeafOf(s.first, a) and self.isSingleLeafOf(s.second, b)) or
                    (self.isSingleLeafOf(s.first, b) and self.isSingleLeafOf(s.second, a)))
                    return .{ .split = @intCast(i), .dir = s.dir };
            },
            else => {},
        };
        return null;
    }

    fn isSingleLeafOf(self: *const Layout, id: NodeId, pane: PaneId) bool {
        return switch (self.nodes.items[id]) {
            .leaf => |l| l.tabs.items.len == 1 and l.tabs.items[0] == pane,
            else => false,
        };
    }

    /// The smallest subtree whose panes are exactly `set` — tabs
    /// included, `.empty` slots allowed — or null when the set is spread
    /// over unrelated parts of the tree or shares a subtree with other
    /// panes. The AI grid grows only such a cluster: anything else is a
    /// layout the user arranged, and is left alone.
    pub fn findPureCluster(self: *const Layout, arena: Allocator, set: []const PaneId) Allocator.Error!?NodeId {
        var id = self.root orelse return null;
        if (!try self.holdsAll(id, arena, set)) return null;
        // Descend while a child still holds the whole set.
        while (true) switch (self.nodes.items[id]) {
            .split => |s| {
                if (try self.holdsAll(s.first, arena, set)) {
                    id = s.first;
                } else if (try self.holdsAll(s.second, arena, set)) {
                    id = s.second;
                } else break;
            },
            else => break,
        };
        const under = try self.panesUnder(id, arena);
        if (under.len != set.len) return null;
        for (under) |p| if (std.mem.indexOfScalar(PaneId, set, p) == null) return null;
        return id;
    }

    fn holdsAll(self: *const Layout, id: NodeId, arena: Allocator, set: []const PaneId) Allocator.Error!bool {
        const under = try self.panesUnder(id, arena);
        for (set) |p| if (std.mem.indexOfScalar(PaneId, under, p) == null) return false;
        return true;
    }

    /// Every pane in every leaf under `id`, tabs included.
    fn panesUnder(self: *const Layout, id: NodeId, arena: Allocator) Allocator.Error![]PaneId {
        var out: std.ArrayListUnmanaged(PaneId) = .empty;
        try self.collectPanesUnder(id, arena, &out);
        return out.items;
    }

    fn collectPanesUnder(self: *const Layout, id: NodeId, arena: Allocator, out: *std.ArrayListUnmanaged(PaneId)) Allocator.Error!void {
        switch (self.nodes.items[id]) {
            .leaf => |l| try out.appendSlice(arena, l.tabs.items),
            .split => |s| {
                try self.collectPanesUnder(s.first, arena, out);
                try self.collectPanesUnder(s.second, arena, out);
            },
            .empty, .free => {},
        }
    }

    fn collectSubtree(self: *const Layout, id: NodeId, arena: Allocator, out: *std.ArrayListUnmanaged(NodeId)) Allocator.Error!void {
        try out.append(arena, id);
        switch (self.nodes.items[id]) {
            .split => |s| {
                try self.collectSubtree(s.first, arena, out);
                try self.collectSubtree(s.second, arena, out);
            },
            else => {},
        }
    }

    /// Rewrite the subtree at `root` as a grid: one row per entry of
    /// `rows`, stacked top to bottom; each row's slots side by side,
    /// left to right; a null slot an `.empty` placeholder. Every split
    /// gets an equal share (a row of three is 33 / 33 / 33). A pane
    /// already alone in a leaf of the subtree keeps that leaf, its id
    /// and its strip state; any other pane gets a fresh leaf. The node
    /// at `root` stays `root`, so a split above it still points at it;
    /// every other node of the old subtree is released — a pane of the
    /// subtree that `rows` does not name leaves the tree. A pane in a
    /// leaf outside the subtree is not allowed. Every allocation
    /// happens before the first mutation.
    pub fn buildGrid(self: *Layout, root: NodeId, rows: []const []const ?PaneId) Allocator.Error!void {
        self.zoomed = null;
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var old: std.ArrayListUnmanaged(NodeId) = .empty;
        try self.collectSubtree(root, arena, &old);
        var fresh: std.ArrayListUnmanaged(NodeId) = .empty;
        errdefer for (fresh.items) |id| self.release(id);
        var kept: std.ArrayListUnmanaged(NodeId) = .empty;
        // The slots: a reused leaf, a fresh leaf, or a fresh empty.
        const slots = try arena.alloc([]NodeId, rows.len);
        var count: usize = 0;
        for (rows, 0..) |row, ri| {
            slots[ri] = try arena.alloc(NodeId, row.len);
            for (row, 0..) |slot, ci| {
                count += 1;
                slots[ri][ci] = if (slot) |pane| blk: {
                    if (self.leafOf(pane)) |lid| {
                        std.debug.assert(std.mem.indexOfScalar(NodeId, old.items, lid) != null);
                        if (lid != root and self.nodes.items[lid].leaf.tabs.items.len == 1) {
                            try kept.append(arena, lid);
                            break :blk lid;
                        }
                    }
                    var nl: Leaf = .{ .active = pane };
                    try nl.tabs.append(self.gpa, pane);
                    errdefer nl.tabs.deinit(self.gpa);
                    const id = try self.alloc(.{ .leaf = nl });
                    try fresh.append(arena, id);
                    break :blk id;
                } else blk: {
                    const id = try self.alloc(.empty);
                    try fresh.append(arena, id);
                    break :blk id;
                };
            }
        }
        std.debug.assert(count >= 2);
        // The rows, then the column of rows.
        const row_nodes = try arena.alloc(NodeId, rows.len);
        for (slots, 0..) |row, ri| row_nodes[ri] = try self.chain(row, .horizontal, arena, &fresh);
        const top = try self.chain(row_nodes, .vertical, arena, &fresh);
        // Mutation: the old subtree goes, `root` takes the new top.
        for (old.items) |id| {
            if (id == root or std.mem.indexOfScalar(NodeId, kept.items, id) != null) continue;
            self.release(id);
        }
        switch (self.nodes.items[root]) {
            .leaf => |*l| l.tabs.deinit(self.gpa),
            else => {},
        }
        self.nodes.items[root] = self.nodes.items[top];
        self.nodes.items[top] = .free;
    }

    /// `a | (b | (c | d))`: the i-th split's first half is one of the
    /// `n - i` items left, so its share is 1/(n - i). One item is itself.
    fn chain(self: *Layout, items: []const NodeId, dir: SplitDir, arena: Allocator, fresh: *std.ArrayListUnmanaged(NodeId)) Allocator.Error!NodeId {
        var i = items.len - 1;
        var acc = items[i];
        while (i > 0) {
            i -= 1;
            const remaining: u16 = @intCast(items.len - i);
            const id = try self.alloc(.{ .split = .{ .dir = dir, .ratio = @max(100 / remaining, 1), .first = items[i], .second = acc } });
            try fresh.append(arena, id);
            acc = id;
        }
        return acc;
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

    /// The page whose split tree shows `pane`, if any.
    pub fn pageOf(self: *LayoutState, pane: PaneId) ?usize {
        for (self.layouts.items, 0..) |*l, i| if (l.leafOf(pane) != null) return i;
        return null;
    }

    /// How many leaves, over every page, show `pane` as a tab. The
    /// layout's invariant is that this is never more than one: a pane
    /// lives in one leaf of one page. Two would be one pty or buffer
    /// drawn in two places, and closing either copy would take the
    /// other's pane away from under it.
    pub fn holders(self: *LayoutState, pane: PaneId) usize {
        var n: usize = 0;
        for (self.layouts.items) |*l| for (l.nodes.items) |node| switch (node) {
            .leaf => |lf| for (lf.tabs.items) |tab| {
                if (tab == pane) n += 1;
            },
            else => {},
        };
        return n;
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

test "layout: equalizeAxis shares one axis out in equal slots and leaves the stack across it alone" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const area = Rect.init(0, 0, 120, 40);
    // A | (B over C), the stack dragged to 70 / 30.
    _ = try l.showIn(null, 0);
    _ = try l.split(0, .horizontal, 1);
    const stack = (try l.split(1, .vertical, 2)).?;
    const stack_split = l.parentOf(stack).?;
    l.setRatio(stack_split, 70);
    try std.testing.expectEqual(@as(u16, 28), (try rectOf(&l, area, a, 1)).?.h);

    // A third column: the axis is thirds, the stack keeps 70 / 30.
    const third = (try l.split(0, .horizontal, 3)).?;
    l.equalizeAxis(l.parentOf(third).?);
    try std.testing.expectEqual(@as(u16, 39), (try rectOf(&l, area, a, 0)).?.w);
    try std.testing.expectEqual(@as(u16, 39), (try rectOf(&l, area, a, 3)).?.w);
    try std.testing.expectEqual(@as(u16, 40), (try rectOf(&l, area, a, 1)).?.w);
    try std.testing.expectEqual(@as(u16, 28), (try rectOf(&l, area, a, 1)).?.h);
    try std.testing.expectEqual(@as(u16, 11), (try rectOf(&l, area, a, 2)).?.h);

    // A fourth: quarters, the stack still its own.
    const fourth = (try l.split(3, .horizontal, 4)).?;
    l.equalizeAxis(l.parentOf(fourth).?);
    var wide: u16 = 0;
    for ([_]PaneId{ 0, 3, 4, 1 }) |p| {
        const w = (try rectOf(&l, area, a, p)).?.w;
        // 120 cells less three dividers is 117: 29 apiece and one 30.
        try std.testing.expect(w == 29 or w == 30);
        wide += w;
    }
    try std.testing.expectEqual(@as(u16, 117), wide);
    try std.testing.expectEqual(@as(u16, 28), (try rectOf(&l, area, a, 1)).?.h);

    // `equalize` is the other rule: it weighs the whole tree by leaf
    // count, so the stack is flattened with everything else.
    l.equalize();
    try std.testing.expectEqual(@as(u16, 20), (try rectOf(&l, area, a, 1)).?.h);

    // The axis a stacked split names is the stack's own, not the row's.
    l.equalizeAxis(stack_split);
    try std.testing.expectEqual(@as(u16, 20), (try rectOf(&l, area, a, 1)).?.h);
    // A leaf names no axis; nothing moves and nothing panics.
    l.equalizeAxis(l.leafOf(0).?);
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

test "layout: mergeToTabs folds every leaf's tabs into one leaf in tree order, the active pane kept; spreadToSplits gives each tab an equal-width leaf; each refuses the other's shape" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const area = Rect.init(0, 1, 120, 40);
    // 0,1 | (2 / 3): three leaves, four panes, pane 3 in the bottom-right.
    const leaf0 = try l.showIn(null, 0);
    _ = try l.showIn(leaf0, 1);
    _ = try l.split(1, .horizontal, 2);
    _ = try l.split(2, .vertical, 3);
    try std.testing.expectEqual(@as(usize, 3), (try l.leaves(a)).len);
    // A single-leaf layout has nothing to spread.
    try std.testing.expectEqual(@as(usize, 0), try l.spreadToSplits(a));
    try std.testing.expectEqual(@as(usize, 3), (try l.leaves(a)).len);
    try std.testing.expectEqual(@as(usize, 3), try l.mergeToTabs(a, 3));
    const ls = try l.leaves(a);
    try std.testing.expectEqual(@as(usize, 1), ls.len);
    try std.testing.expectEqual(ls[0], l.root.?);
    try std.testing.expectEqualSlices(PaneId, &.{ 0, 1, 2, 3 }, l.leaf(ls[0]).?.tabs.items);
    try std.testing.expectEqual(@as(PaneId, 3), l.leaf(ls[0]).?.active);
    // No node outside the tree survived: one live slot.
    var live: usize = 0;
    for (l.nodes.items) |n| if (n != .free) {
        live += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), live);
    // Merging a single leaf is a no-op that reports one leaf; an active
    // hint that is no tab falls back to the first.
    try std.testing.expectEqual(@as(usize, 1), try l.mergeToTabs(a, 3));
    try std.testing.expectEqualSlices(PaneId, &.{ 0, 1, 2, 3 }, l.leaf(l.root.?).?.tabs.items);
    // Spread: four leaves side by side, tab order left to right, each
    // a quarter of the width (within a cell).
    try std.testing.expectEqual(@as(usize, 4), try l.spreadToSplits(a));
    const spread = try l.leaves(a);
    try std.testing.expectEqual(@as(usize, 4), spread.len);
    for (spread, 0..) |lid, i| {
        try std.testing.expectEqualSlices(PaneId, &.{@as(PaneId, @intCast(i))}, l.leaf(lid).?.tabs.items);
    }
    const rects = try l.computeRects(area, a);
    try std.testing.expectEqual(@as(usize, 4), rects.panes.len);
    var prev_x: u16 = 0;
    for (rects.panes, 0..) |pr, i| {
        try std.testing.expectEqual(@as(PaneId, @intCast(i)), pr.pane);
        try std.testing.expect(pr.rect.x >= prev_x);
        prev_x = pr.rect.x;
        // 120 columns less three dividers: 29 or 30 each.
        try std.testing.expect(pr.rect.w >= 28 and pr.rect.w <= 30);
    }
    // A layout with splits refuses to spread; a leaf with one tab too.
    try std.testing.expectEqual(@as(usize, 0), try l.spreadToSplits(a));
    _ = try l.mergeToTabs(a, 0);
    _ = l.removePane(1);
    _ = l.removePane(2);
    _ = l.removePane(3);
    try std.testing.expectEqual(@as(usize, 0), try l.spreadToSplits(a));
    // Round trip on the merged leaf's active tab: it stays the focus.
    var m = Layout.init(gpa);
    defer m.deinit();
    const only = try m.showIn(null, 5);
    _ = try m.showIn(only, 6);
    _ = try m.showIn(only, 7);
    m.leaf(only).?.active = 6;
    try std.testing.expectEqual(@as(usize, 3), try m.spreadToSplits(a));
    try std.testing.expectEqual(@as(usize, 3), try m.mergeToTabs(a, 6));
    try std.testing.expectEqual(@as(PaneId, 6), m.leaf(m.root.?).?.active);
    try std.testing.expectEqualSlices(PaneId, &.{ 5, 6, 7 }, m.leaf(m.root.?).?.tabs.items);
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

test "grid: a pair split of two lone leaves is found in either order, not a nested or multi-tab one" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    _ = try l.showIn(null, 0);
    _ = try l.split(0, .horizontal, 1);
    const pair = l.findLeafPairSplit(0, 1).?;
    try std.testing.expectEqual(SplitDir.horizontal, pair.dir);
    try std.testing.expectEqual(l.root.?, pair.split);
    try std.testing.expectEqual(pair.split, l.findLeafPairSplit(1, 0).?.split);
    try std.testing.expect(l.findLeafPairSplit(0, 7) == null);
    // A third leaf under pane 1: {0, {1, 2}} — 0 and 1 are no pair now.
    _ = try l.split(1, .vertical, 2);
    try std.testing.expect(l.findLeafPairSplit(0, 1) == null);
    const inner = l.findLeafPairSplit(1, 2).?;
    try std.testing.expectEqual(SplitDir.vertical, inner.dir);
    // A second tab on pane 2's leaf breaks the pair.
    _ = try l.showIn(l.leafOf(2).?, 3);
    try std.testing.expect(l.findLeafPairSplit(1, 2) == null);
}

test "grid: buildGrid makes a 2×2 with an empty slot; the empty is laid out, filled, and collapses with its split" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const area = Rect.init(0, 1, 100, 41);
    _ = try l.showIn(null, 0);
    _ = try l.split(0, .horizontal, 1);
    const leaf0 = l.leafOf(0).?;
    const leaf1 = l.leafOf(1).?;
    const root = l.root.?;
    try std.testing.expect(!l.containsEmpty());
    // {0, 1} on top, {2, empty} below.
    try l.buildGrid(root, &.{ &.{ 0, 1 }, &.{ 2, null } });
    try std.testing.expectEqual(root, l.root.?);
    try std.testing.expect(l.containsEmpty());
    // The old leaves kept their ids; pane 2 got a fresh one.
    try std.testing.expectEqual(leaf0, l.leafOf(0).?);
    try std.testing.expectEqual(leaf1, l.leafOf(1).?);
    try std.testing.expectEqualSlices(PaneId, &.{ 0, 1, 2 }, try l.allPanes(a));
    const rects = try l.computeRects(area, a);
    try std.testing.expectEqual(@as(usize, 3), rects.panes.len);
    try std.testing.expectEqual(@as(usize, 1), rects.empties.len);
    try std.testing.expectEqual(@as(usize, 3), rects.dividers.len);
    // Four equal quadrants: the empty is the bottom-right one.
    const r0 = (try rectOf(&l, area, a, 0)).?;
    const r1 = (try rectOf(&l, area, a, 1)).?;
    const r2 = (try rectOf(&l, area, a, 2)).?;
    const e = rects.empties[0].rect;
    try std.testing.expectEqual(r0.y, r1.y);
    try std.testing.expectEqual(r2.y, e.y);
    try std.testing.expect(r2.y > r0.y);
    try std.testing.expectEqual(r0.x, r2.x);
    try std.testing.expectEqual(r1.x, e.x);
    try std.testing.expectEqual(r0.w, r1.w + 1);
    try std.testing.expectEqual(r0.h, r2.h);
    try std.testing.expectEqual(@as(u16, 20), r0.h);
    // Filling the slot: the fourth pane lands in it, same node id.
    const filled = (try l.fillFirstEmpty(3)).?;
    try std.testing.expectEqual(rects.empties[0].node, filled);
    try std.testing.expect(!l.containsEmpty());
    try std.testing.expect((try l.fillFirstEmpty(9)) == null);
    try std.testing.expect((try rectOf(&l, area, a, 3)).?.eql(e));
    try std.testing.expectEqual(@as(usize, 0), (try l.computeRects(area, a)).empties.len);
    // No node outside the tree survived: 4 leaves + 3 splits.
    var live: usize = 0;
    for (l.nodes.items) |n| if (n != .free) {
        live += 1;
    };
    try std.testing.expectEqual(@as(usize, 7), live);
    // Back to a placeholder, then closing its sibling takes both: the
    // top row is the whole tree again.
    _ = l.removePane(3);
    try l.buildGrid(l.root.?, &.{ &.{ 0, 1 }, &.{ 2, null } });
    try std.testing.expect(l.containsEmpty());
    try std.testing.expect(l.removePane(2) == null);
    try std.testing.expect(!l.containsEmpty());
    try std.testing.expectEqualSlices(PaneId, &.{ 0, 1 }, try l.allPanes(a));
    try std.testing.expectEqual(@as(u16, 41), (try rectOf(&l, area, a, 0)).?.h);
    // A placeholder alone at the root goes with the last pane.
    try l.buildGrid(l.root.?, &.{ &.{ 0, null }, &.{ 1, null } });
    _ = l.removePane(0);
    _ = l.removePane(1);
    try std.testing.expect(l.isEmpty());
    try std.testing.expect(!l.containsEmpty());
    try std.testing.expect(l.firstLeaf() == null);
}

test "grid: findPureCluster is the smallest subtree of exactly the set, empties allowed; buildGrid grows it to 3×2 with equal thirds" {
    const gpa = std.testing.allocator;
    var l = Layout.init(gpa);
    defer l.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const area = Rect.init(0, 1, 121, 41);
    // An editor (pane 9) on the left; the cluster {0, 1, 2, empty} on the right.
    _ = try l.showIn(null, 9);
    _ = try l.split(9, .horizontal, 0);
    _ = try l.split(0, .horizontal, 1);
    const cluster = l.parentOf(l.leafOf(0).?).?;
    try l.buildGrid(cluster, &.{ &.{ 0, 1 }, &.{ 2, null } });
    try std.testing.expectEqual(cluster, (try l.findPureCluster(a, &.{ 0, 1, 2 })).?);
    try std.testing.expectEqual(cluster, (try l.findPureCluster(a, &.{ 2, 0, 1 })).?);
    // A pane that is not there: no cluster. The top row is the cluster
    // of {0, 1} — the smallest subtree wins. The whole tree is the
    // cluster of everything — until a tab beside the editor (pane 8)
    // is left out of the set.
    try std.testing.expect((try l.findPureCluster(a, &.{ 0, 1, 7 })) == null);
    try std.testing.expectEqual(l.parentOf(l.leafOf(0).?).?, (try l.findPureCluster(a, &.{ 0, 1 })).?);
    try std.testing.expectEqual(l.root.?, (try l.findPureCluster(a, &.{ 9, 0, 1, 2 })).?);
    _ = try l.showIn(l.leafOf(9).?, 8);
    try std.testing.expect((try l.findPureCluster(a, &.{ 0, 1, 2, 9 })) == null);
    try std.testing.expectEqual(cluster, (try l.findPureCluster(a, &.{ 0, 1, 2 })).?);
    // Fill the slot, then grow to 3×2: 0 1 2 on top, 3 4 empty below.
    _ = try l.fillFirstEmpty(3);
    try l.buildGrid(cluster, &.{ &.{ 0, 1, 2 }, &.{ 3, 4, null } });
    try std.testing.expectEqualSlices(PaneId, &.{ 9, 8, 0, 1, 2, 3, 4 }, try l.allPanes(a));
    try std.testing.expectEqual(cluster, (try l.findPureCluster(a, &.{ 0, 1, 2, 3, 4 })).?);
    const rects = try l.computeRects(area, a);
    try std.testing.expectEqual(@as(usize, 1), rects.empties.len);
    // The cluster's 60 columns less two dividers: 19 or 20 each.
    const r0 = (try rectOf(&l, area, a, 0)).?;
    const r1 = (try rectOf(&l, area, a, 1)).?;
    const r2 = (try rectOf(&l, area, a, 2)).?;
    const r4 = (try rectOf(&l, area, a, 4)).?;
    try std.testing.expect(r0.w >= 18 and r0.w <= 20);
    try std.testing.expect(r1.w >= 18 and r1.w <= 20);
    try std.testing.expect(r2.w >= 18 and r2.w <= 20);
    try std.testing.expectEqual(r1.x, r4.x);
    try std.testing.expectEqual(r1.w, r4.w);
    try std.testing.expectEqual(r2.x, rects.empties[0].rect.x);
    try std.testing.expect(r4.y > r1.y);
    // `equalize` gives every slot the same share, empties counted: the
    // editor's leaf is one slot of seven (14 % of 121 columns), the
    // cluster's three columns stay within a cell of each other.
    l.setRatio(cluster, 80);
    l.equalize();
    try std.testing.expectEqual(@as(u16, 16), (try rectOf(&l, area, a, 8)).?.w); // the leaf shows tab 8
    const q0 = (try rectOf(&l, area, a, 0)).?.w;
    const q1 = (try rectOf(&l, area, a, 1)).?.w;
    const q2 = (try rectOf(&l, area, a, 2)).?.w;
    try std.testing.expect(@max(q0, q1) - @min(q0, q1) <= 1);
    try std.testing.expect(@max(q1, q2) - @min(q1, q2) <= 1);
    try std.testing.expect(q0 > r0.w);
    // A cluster held as tabs of one leaf still matches, and the grid
    // gives each tab a leaf of its own.
    var m = Layout.init(gpa);
    defer m.deinit();
    const only = try m.showIn(null, 5);
    _ = try m.showIn(only, 6);
    try std.testing.expectEqual(only, (try m.findPureCluster(a, &.{ 5, 6 })).?);
    try m.buildGrid(only, &.{ &.{ 5, 6 }, &.{ 7, null } });
    try std.testing.expectEqual(only, m.root.?);
    try std.testing.expectEqual(@as(usize, 3), (try m.leaves(a)).len);
    try std.testing.expectEqual(@as(usize, 1), m.leaf(m.leafOf(5).?).?.tabs.items.len);
}
