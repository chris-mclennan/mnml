//! The window layout: a binary split tree over the central pane area. The tree
//! rail, the bufferline, and the statusline live *outside* this tree. Each
//! [`Layout::Leaf`] references a pane (buffer) in `App::panes`. Invariants the
//! `App` methods maintain: **no buffer is in two leaves at once**, and the
//! *focused* buffer (`App::active`) is always in a leaf — so `active` uniquely
//! identifies the focused leaf. Buffers in *no* leaf are allowed (background tabs
//! the bufferline still lists); revealing one shows it in the focused leaf.

use ratatui::layout::Rect;

/// Index of a pane in `App::panes`.
pub type PaneId = usize;

/// How a split arranges its two children.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitDir {
    /// Side by side — `first` on the left, `second` on the right, vertical divider.
    Horizontal,
    /// Stacked — `first` on top, `second` below, horizontal divider.
    Vertical,
}

#[derive(Debug, Clone)]
pub enum Layout {
    Empty,
    /// A single split / leaf in the layout tree. May hold multiple
    /// tabs (panes); `active` is the currently visible one and is
    /// always present in `tabs`. `tabs` is non-empty and preserves
    /// insertion order (newest at end, except when explicitly
    /// reordered by drag-to-rearrange).
    Leaf {
        active: PaneId,
        tabs: Vec<PaneId>,
    },
    Split {
        dir: SplitDir,
        /// Percent of the split's long axis given to `first` (clamped 10..=90).
        ratio: u16,
        first: Box<Layout>,
        second: Box<Layout>,
    },
}

impl Layout {
    /// Convenience: make a single-tab leaf showing `id`.
    pub fn leaf(id: PaneId) -> Self {
        Layout::Leaf {
            active: id,
            tabs: vec![id],
        }
    }

    /// Convenience: leaf with multiple tabs, the given one active.
    /// Session restore uses this to synthesize a layout when the
    /// saved file had a stale `layout: null` but a non-empty
    /// `open[]` (qa-5th 2026-06-29 SEV-2).
    pub fn leaf_with_tabs(active: PaneId, tabs: Vec<PaneId>) -> Self {
        Layout::Leaf { active, tabs }
    }

    /// The active (visible) pane id for every leaf in the tree.
    /// Tab-stack siblings are NOT included — see `all_panes()`.
    pub fn leaves(&self) -> Vec<PaneId> {
        let mut out = Vec::new();
        self.collect_leaves(&mut out);
        out
    }
    fn collect_leaves(&self, out: &mut Vec<PaneId>) {
        match self {
            Layout::Empty => {}
            Layout::Leaf { active, .. } => out.push(*active),
            Layout::Split { first, second, .. } => {
                first.collect_leaves(out);
                second.collect_leaves(out);
            }
        }
    }

    /// Every pane referenced by the tree, including background
    /// tabs in multi-tab leaves. Used by garbage-collection logic
    /// that needs to know which `panes[i]` entries are still
    /// reachable from the layout.
    pub fn all_panes(&self) -> Vec<PaneId> {
        let mut out = Vec::new();
        self.collect_all_panes(&mut out);
        out
    }
    fn collect_all_panes(&self, out: &mut Vec<PaneId>) {
        match self {
            Layout::Empty => {}
            Layout::Leaf { tabs, .. } => out.extend(tabs.iter().copied()),
            Layout::Split { first, second, .. } => {
                first.collect_all_panes(out);
                second.collect_all_panes(out);
            }
        }
    }

    /// Find the leaf containing `pane` (as active OR background
    /// tab) and return a mutable ref to its (active, tabs) for
    /// Immutable counterpart to `leaf_containing_mut` — returns the
    /// leaf's tab list (the per-split tab group `pane` is part of)
    /// for read-only queries like "what tabs share this split?".
    pub fn leaf_containing(&self, pane: PaneId) -> Option<&[PaneId]> {
        match self {
            Layout::Leaf { tabs, .. } if tabs.contains(&pane) => Some(tabs.as_slice()),
            Layout::Split { first, second, .. } => first
                .leaf_containing(pane)
                .or_else(|| second.leaf_containing(pane)),
            _ => None,
        }
    }

    /// in-place mutation.
    pub fn leaf_containing_mut(&mut self, pane: PaneId) -> Option<(&mut PaneId, &mut Vec<PaneId>)> {
        match self {
            Layout::Leaf { active, tabs } if tabs.contains(&pane) => Some((active, tabs)),
            Layout::Split { first, second, .. } => first
                .leaf_containing_mut(pane)
                .or_else(|| second.leaf_containing_mut(pane)),
            _ => None,
        }
    }

    /// Find the leaf whose `active` pane is `target`.
    pub fn active_leaf_mut(&mut self, target: PaneId) -> Option<(&mut PaneId, &mut Vec<PaneId>)> {
        match self {
            Layout::Leaf { active, tabs } if *active == target => Some((active, tabs)),
            Layout::Split { first, second, .. } => first
                .active_leaf_mut(target)
                .or_else(|| second.active_leaf_mut(target)),
            _ => None,
        }
    }

    /// True when this layout contains at least one `Split` node.
    /// Used by `ui::draw` to hide the global bufferline when the
    /// per-leaf tab strips above each split would otherwise
    /// duplicate it.
    pub fn has_splits(&self) -> bool {
        matches!(self, Layout::Split { .. })
            || match self {
                Layout::Split { first, second, .. } => first.has_splits() || second.has_splits(),
                _ => false,
            }
    }

    /// The first (leftmost / topmost) leaf's active pane, if any.
    pub fn first_leaf(&self) -> Option<PaneId> {
        match self {
            Layout::Empty => None,
            Layout::Leaf { active, .. } => Some(*active),
            Layout::Split { first, second, .. } => {
                first.first_leaf().or_else(|| second.first_leaf())
            }
        }
    }

    pub fn contains(&self, p: PaneId) -> bool {
        self.all_panes().contains(&p)
    }

    /// Re-point the leaf whose ACTIVE pane is `from` to show `to`
    /// instead. Also rewrites the entry in `tabs` so the tab list
    /// stays consistent.
    pub fn set_leaf_pane(&mut self, from: PaneId, to: PaneId) {
        match self {
            Layout::Leaf { active, tabs } if *active == from => {
                if let Some(pos) = tabs.iter().position(|&t| t == from) {
                    tabs[pos] = to;
                } else {
                    tabs.push(to);
                }
                *active = to;
            }
            Layout::Split { first, second, .. } => {
                first.set_leaf_pane(from, to);
                second.set_leaf_pane(from, to);
            }
            _ => {}
        }
    }

    /// Replace the leaf whose ACTIVE pane is `target` with the
    /// subtree `with`. Used by `splice_pane_at` to swap a leaf
    /// for a Split in-place.
    pub fn replace_leaf(&mut self, target: PaneId, with: Layout) -> bool {
        match self {
            Layout::Leaf { active, .. } if *active == target => {
                *self = with;
                true
            }
            Layout::Split { first, second, .. } => {
                first.replace_leaf(target, with.clone()) || second.replace_leaf(target, with)
            }
            _ => false,
        }
    }

    /// Remove `target` from the tree:
    ///   - If `target` is a BACKGROUND tab in some leaf, just drop
    ///     it from that leaf's `tabs` (the leaf shape stays).
    ///   - If `target` IS the active tab AND the leaf has other
    ///     tabs, pop another tab as active (rightward neighbour
    ///     preferred, falling back to leftward).
    ///   - If `target` is the active tab AND the leaf is single-
    ///     tab, the leaf is dropped: if it's a child of a split
    ///     the split collapses into its sibling; if it's the root
    ///     the tree becomes `Empty`.
    /// Returns true if `target` was found.
    pub fn remove_leaf(&mut self, target: PaneId) -> bool {
        match self {
            Layout::Empty => false,
            Layout::Leaf { active, tabs } => {
                if !tabs.contains(&target) {
                    return false;
                }
                let is_active = *active == target;
                if let Some(pos) = tabs.iter().position(|&t| t == target) {
                    tabs.remove(pos);
                }
                if tabs.is_empty() {
                    *self = Layout::Empty;
                } else if is_active {
                    // Pick the new active: same-index (rightward
                    // neighbour) if available, else the previous tab.
                    let pos = tabs.iter().position(|&t| t == *active);
                    if pos.is_none() {
                        let idx = tabs.len().saturating_sub(1);
                        *active = tabs[idx];
                    }
                }
                true
            }
            Layout::Split { first, second, .. } => {
                // Try to remove from each child; if a child becomes Empty,
                // collapse this split into its sibling.
                let hit = first.remove_leaf(target) || second.remove_leaf(target);
                if hit {
                    if matches!(**first, Layout::Empty) {
                        *self = std::mem::replace(second, Box::new(Layout::Empty))
                            .as_ref()
                            .clone();
                    } else if matches!(**second, Layout::Empty) {
                        *self = std::mem::replace(first, Box::new(Layout::Empty))
                            .as_ref()
                            .clone();
                    }
                }
                hit
            }
        }
    }

    /// Walk the tree, find the smallest `Split` of direction `dir` that
    /// contains `target` (the active leaf), and adjust its ratio so the
    /// side `target` is in *grows* by `grow_delta` percent (so the chord
    /// "Ctrl+W +" always grows whichever pane the cursor is in). Clamped
    /// to 10..=90. Returns `true` if a matching split was found.
    pub fn adjust_split_ratio_for(
        &mut self,
        target: PaneId,
        dir: SplitDir,
        grow_delta: i32,
    ) -> bool {
        match self {
            Layout::Split {
                dir: this_dir,
                ratio,
                first,
                second,
            } => {
                let in_first = first.contains(target);
                let in_second = second.contains(target);
                if !in_first && !in_second {
                    return false;
                }
                // Recurse first — find the deepest matching split.
                let recursed = if in_first {
                    first.adjust_split_ratio_for(target, dir, grow_delta)
                } else {
                    second.adjust_split_ratio_for(target, dir, grow_delta)
                };
                if recursed {
                    return true;
                }
                if *this_dir == dir {
                    // The ratio is the share that goes to `first`. If the
                    // active leaf is in `first`, grow ⇒ raise the ratio. If
                    // in `second`, grow ⇒ lower it.
                    let signed = if in_first { grow_delta } else { -grow_delta };
                    let new_ratio = (*ratio as i32 + signed).clamp(10, 90) as u16;
                    *ratio = new_ratio;
                    return true;
                }
                false
            }
            _ => false,
        }
    }

    /// vim `Ctrl+W _` (height) / `Ctrl+W |` (width) — maximize the
    /// active leaf's allocation in the matching-direction split. Walks
    /// to the smallest enclosing split whose `dir == dir`, then pushes
    /// the ratio toward the side that contains `target`. Returns `true`
    /// when a ratio was changed.
    pub fn maximize_split_ratio_for(&mut self, target: PaneId, dir: SplitDir) -> bool {
        match self {
            Layout::Split {
                dir: this_dir,
                ratio,
                first,
                second,
            } => {
                let in_first = first.contains(target);
                let in_second = second.contains(target);
                if !in_first && !in_second {
                    return false;
                }
                let recursed = if in_first {
                    first.maximize_split_ratio_for(target, dir)
                } else {
                    second.maximize_split_ratio_for(target, dir)
                };
                if recursed {
                    return true;
                }
                if *this_dir == dir {
                    *ratio = if in_first { 90 } else { 10 };
                    return true;
                }
                false
            }
            _ => false,
        }
    }

    /// Swap the two sides of the smallest split that contains `target`.
    /// Vim `Ctrl+W r` rotates the splits at the cursor's level. Returns
    /// `true` if a swap was made (target was in a Split node).
    pub fn swap_siblings_containing(&mut self, target: PaneId) -> bool {
        match self {
            Layout::Split { first, second, .. } => {
                // If either side is the target's leaf or a subtree containing
                // it, recurse first; if the recursion couldn't find a deeper
                // Split, swap our own children.
                let in_first = first.contains(target);
                let in_second = second.contains(target);
                if !in_first && !in_second {
                    return false;
                }
                let recursed_first = if in_first {
                    first.swap_siblings_containing(target)
                } else {
                    false
                };
                let recursed_second = if in_second {
                    second.swap_siblings_containing(target)
                } else {
                    false
                };
                // If a deeper Split handled it, don't swap here.
                if recursed_first || recursed_second {
                    return true;
                }
                // Both children are Leafs (or one is, the other is Leaf-equivalent
                // for our purposes) — swap.
                std::mem::swap(first, second);
                true
            }
            _ => false,
        }
    }

    /// Reposition the active leaf within its immediate parent split. Vim
    /// `Ctrl+W H/J/K/L` "move to far edge" — this is a poor-man's version
    /// that operates on the *immediate* parent (not the outermost), so
    /// nested layouts only see a one-level rearrangement.
    /// `target_dir` is the direction the parent should end up as
    /// (`Horizontal` = side-by-side; `Vertical` = stacked). `to_second`
    /// puts the active leaf in `second` (right / bottom); else `first`
    /// (left / top). Returns true on a change.
    pub fn move_active_to(
        &mut self,
        target: PaneId,
        target_dir: SplitDir,
        to_second: bool,
    ) -> bool {
        match self {
            Layout::Split {
                dir, first, second, ..
            } => {
                let in_first = first.contains(target);
                let in_second = second.contains(target);
                if !in_first && !in_second {
                    return false;
                }
                // Recurse to the deepest split first.
                let recursed = if in_first {
                    first.move_active_to(target, target_dir, to_second)
                } else {
                    second.move_active_to(target, target_dir, to_second)
                };
                if recursed {
                    return true;
                }
                let mut changed = false;
                if *dir != target_dir {
                    *dir = target_dir;
                    changed = true;
                }
                // If the active is on the wrong side, swap children.
                if (in_first && to_second) || (in_second && !to_second) {
                    std::mem::swap(first, second);
                    changed = true;
                }
                changed
            }
            _ => false,
        }
    }

    /// Reset every `Split` in the tree to a 50/50 ratio. Vim `Ctrl+W =` —
    /// "equalize all splits" with a poor-man's "even at every level".
    /// (True equalization across the *visible* viewport would weight by
    /// pane count rather than tree level; for a binary tree this is a
    /// good-enough approximation that matches how vim behaves on
    /// nested splits.)
    pub fn equalize_splits(&mut self) {
        match self {
            Layout::Split {
                ratio,
                first,
                second,
                ..
            } => {
                *ratio = 50;
                first.equalize_splits();
                second.equalize_splits();
            }
            Layout::Empty | Layout::Leaf { .. } => {}
        }
    }

    /// Set the `ratio` of the `Split` reached by following `path` from the root
    /// (`false` = into `first`, `true` = into `second`). No-op if the path doesn't
    /// land on a `Split`. The ratio is clamped to 10..=90.
    pub fn set_ratio_at(&mut self, path: &[bool], ratio: u16) {
        let mut node = self;
        for &go_second in path {
            match node {
                Layout::Split { first, second, .. } => {
                    node = if go_second { second } else { first };
                }
                _ => return,
            }
        }
        if let Layout::Split { ratio: r, .. } = node {
            *r = ratio.clamp(10, 90);
        }
    }

    /// Swap any leaf references pointing at `a` with `b` and vice versa.
    /// Used after `app.panes.swap(a, b)` so layout leaves still point at
    /// the correct pane after the storage move. Walks the whole tree.
    pub fn swap_leaf_refs(&mut self, a: PaneId, b: PaneId) {
        if a == b {
            return;
        }
        match self {
            Layout::Empty => {}
            Layout::Leaf { active, tabs } => {
                let swap = |x: &mut PaneId| {
                    if *x == a {
                        *x = b;
                    } else if *x == b {
                        *x = a;
                    }
                };
                swap(active);
                for t in tabs.iter_mut() {
                    swap(t);
                }
            }
            Layout::Split { first, second, .. } => {
                first.swap_leaf_refs(a, b);
                second.swap_leaf_refs(a, b);
            }
        }
    }

    /// After `app.panes.remove(removed)`, every leaf id past `removed` shifts down
    /// by one. Leaves pointing AT `removed` become `Empty` (the pane is gone —
    /// keeping the id would silently re-bind the leaf to whatever pane shifted
    /// down to take that index). Splits with an `Empty` child collapse to the
    /// other branch so the tree stays well-formed for re-rendering.
    pub fn shift_after(&mut self, removed: PaneId) {
        match self {
            Layout::Empty => {}
            Layout::Leaf { active, tabs } => {
                // Drop any tab pointing AT `removed`; shift higher ids down.
                tabs.retain(|t| *t != removed);
                for t in tabs.iter_mut() {
                    if *t > removed {
                        *t -= 1;
                    }
                }
                if tabs.is_empty() {
                    *self = Layout::Empty;
                } else if *active == removed {
                    *active = tabs[0];
                } else if *active > removed {
                    *active -= 1;
                }
            }
            Layout::Split { first, second, .. } => {
                first.shift_after(removed);
                second.shift_after(removed);
                // Collapse splits whose child became Empty. Take the
                // surviving branch's contents in place to avoid a
                // mid-tree placeholder.
                let collapse = match (&**first, &**second) {
                    (Layout::Empty, Layout::Empty) => Some(Layout::Empty),
                    (Layout::Empty, _) => Some((**second).clone()),
                    (_, Layout::Empty) => Some((**first).clone()),
                    _ => None,
                };
                if let Some(replacement) = collapse {
                    *self = replacement;
                }
            }
        }
    }

    /// Compute each leaf's body rect inside `area`, allowing one cell per divider.
    /// Returns `(leaf_rects, divider_rects)`.
    pub fn compute_rects(&self, area: Rect) -> (Vec<(PaneId, Rect)>, Vec<DividerRect>) {
        let mut leaves = Vec::new();
        let mut divs = Vec::new();
        self.walk_rects(area, &mut leaves, &mut divs);
        (leaves, divs)
    }
    fn walk_rects(
        &self,
        area: Rect,
        leaves: &mut Vec<(PaneId, Rect)>,
        divs: &mut Vec<DividerRect>,
    ) {
        match self {
            Layout::Empty => {}
            Layout::Leaf { active, .. } => leaves.push((*active, area)),
            Layout::Split {
                dir,
                ratio,
                first,
                second,
            } => {
                let (a, divider, b) = split_rects(area, *dir, *ratio);
                if divider.width > 0 && divider.height > 0 {
                    divs.push((divider, *dir));
                }
                first.walk_rects(a, leaves, divs);
                second.walk_rects(b, leaves, divs);
            }
        }
    }
}

/// A split divider's screen rect plus its orientation.
pub type DividerRect = (Rect, SplitDir);

/// Everything the event loop needs to drag-resize one split: the divider's
/// screen rect, the split's orientation, the area the whole split occupies (so a
/// drag position maps to a ratio), and the path to that `Split` node from the
/// root (for [`Layout::set_ratio_at`]).
#[derive(Debug, Clone)]
pub struct DividerHit {
    pub rect: Rect,
    pub dir: SplitDir,
    pub area: Rect,
    pub path: Vec<bool>,
}

impl DividerHit {
    /// The ratio (10..=90) implied by a pointer at `(x, y)` within `self.area`.
    pub fn ratio_for(&self, x: u16, y: u16) -> u16 {
        let (pos, start, span) = match self.dir {
            SplitDir::Horizontal => (x, self.area.x, self.area.width),
            SplitDir::Vertical => (y, self.area.y, self.area.height),
        };
        if span == 0 {
            return 50;
        }
        let off = pos.saturating_sub(start) as u32;
        ((off * 100) / span as u32).clamp(10, 90) as u16
    }
}

/// Carve `area` into `(first, divider, second)` for a split. The divider is one
/// cell on the split axis (omitted — zero-sized — if `area` is too small).
pub fn split_rects(area: Rect, dir: SplitDir, ratio: u16) -> (Rect, Rect, Rect) {
    let ratio = ratio.clamp(10, 90);
    match dir {
        SplitDir::Horizontal => {
            if area.width < 3 {
                return (
                    area,
                    Rect::new(area.x, area.y, 0, area.height),
                    Rect::new(area.x, area.y, 0, area.height),
                );
            }
            let usable = area.width - 1;
            let w1 = ((usable as u32 * ratio as u32) / 100).max(1) as u16;
            let w1 = w1.min(usable - 1);
            let a = Rect::new(area.x, area.y, w1, area.height);
            let d = Rect::new(area.x + w1, area.y, 1, area.height);
            let b = Rect::new(area.x + w1 + 1, area.y, usable - w1, area.height);
            (a, d, b)
        }
        SplitDir::Vertical => {
            if area.height < 3 {
                return (
                    area,
                    Rect::new(area.x, area.y, area.width, 0),
                    Rect::new(area.x, area.y, area.width, 0),
                );
            }
            let usable = area.height - 1;
            let h1 = ((usable as u32 * ratio as u32) / 100).max(1) as u16;
            let h1 = h1.min(usable - 1);
            let a = Rect::new(area.x, area.y, area.width, h1);
            let d = Rect::new(area.x, area.y + h1, area.width, 1);
            let b = Rect::new(area.x, area.y + h1 + 1, area.width, usable - h1);
            (a, d, b)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leaf_basics() {
        let mut l = Layout::leaf(0);
        assert_eq!(l.leaves(), vec![0]);
        assert_eq!(l.first_leaf(), Some(0));
        assert!(l.contains(0));
        l.set_leaf_pane(0, 3);
        assert_eq!(l.leaves(), vec![3]);
    }

    #[test]
    fn split_and_collapse() {
        let mut l = Layout::leaf(0);
        // split leaf 0 → Split(Leaf 0, Leaf 1)
        assert!(l.replace_leaf(
            0,
            Layout::Split {
                dir: SplitDir::Horizontal,
                ratio: 50,
                first: Box::new(Layout::leaf(0)),
                second: Box::new(Layout::leaf(1)),
            }
        ));
        assert_eq!(l.leaves(), vec![0, 1]);
        // nested split of leaf 1 → Split(Leaf 0, Split(Leaf 1, Leaf 2))
        assert!(l.replace_leaf(
            1,
            Layout::Split {
                dir: SplitDir::Vertical,
                ratio: 50,
                first: Box::new(Layout::leaf(1)),
                second: Box::new(Layout::leaf(2)),
            }
        ));
        assert_eq!(l.leaves(), vec![0, 1, 2]);
        // remove leaf 1 → its sibling (Leaf 2) takes its place
        assert!(l.remove_leaf(1));
        assert_eq!(l.leaves(), vec![0, 2]);
        // remove leaf 0 → collapses to just Leaf 2
        assert!(l.remove_leaf(0));
        assert_eq!(l.leaves(), vec![2]);
        assert!(matches!(l, Layout::Leaf { active: 2, .. }));
        // remove the last → Empty
        assert!(l.remove_leaf(2));
        assert!(matches!(l, Layout::Empty));
    }

    #[test]
    fn shift_after_reindexes() {
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::Split {
                dir: SplitDir::Vertical,
                ratio: 50,
                first: Box::new(Layout::leaf(1)),
                second: Box::new(Layout::leaf(3)),
            }),
        };
        l.shift_after(2); // pretend pane 2 was removed from app.panes
        assert_eq!(l.leaves(), vec![0, 1, 2]);
    }

    #[test]
    fn shift_after_drops_leaf_at_removed_id() {
        // A leaf pointing at the removed pane id must become Empty
        // (don't silently re-bind to whatever pane shifted into its
        // slot). Splits collapse around the missing leaf.
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        l.shift_after(0);
        // Pane 0 removed: first leaf gone, second was Leaf(1) → Leaf(0).
        // Split collapses to that leaf.
        assert!(matches!(l, Layout::Leaf { active: 0, .. }));
    }

    #[test]
    fn shift_after_collapses_nested_splits() {
        // Removing both children of a nested split should propagate
        // the Empty up so the parent collapses too.
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::Split {
                dir: SplitDir::Vertical,
                ratio: 50,
                first: Box::new(Layout::leaf(1)),
                second: Box::new(Layout::leaf(2)),
            }),
        };
        l.shift_after(1);
        // After removing pane 1, the nested split's first child is
        // dropped; the inner split collapses to Leaf(1) (was Leaf 2,
        // shifted). The outer split survives with both leaves.
        assert_eq!(l.leaves(), vec![0, 1]);
    }

    #[test]
    fn swap_siblings_swaps_immediate_parent() {
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        let swapped = l.swap_siblings_containing(0);
        assert!(swapped);
        let Layout::Split { first, second, .. } = &l else {
            panic!()
        };
        assert!(matches!(**first, Layout::Leaf { active: 1, .. }));
        assert!(matches!(**second, Layout::Leaf { active: 0, .. }));
    }

    #[test]
    fn swap_siblings_walks_to_deepest_split() {
        // Outer split holds leaf 0 + an inner split holding leaves 1 + 2.
        // Asking to swap siblings of leaf 1 should swap inner's children
        // (leaves 1 + 2), not the outer.
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::Split {
                dir: SplitDir::Vertical,
                ratio: 50,
                first: Box::new(Layout::leaf(1)),
                second: Box::new(Layout::leaf(2)),
            }),
        };
        let swapped = l.swap_siblings_containing(1);
        assert!(swapped);
        let Layout::Split { second, .. } = &l else {
            panic!()
        };
        let Layout::Split {
            first: f,
            second: s,
            ..
        } = &**second
        else {
            panic!()
        };
        assert!(matches!(**f, Layout::Leaf { active: 2, .. }));
        assert!(matches!(**s, Layout::Leaf { active: 1, .. }));
    }

    #[test]
    fn adjust_split_grows_first_side_when_target_in_first() {
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        // Active leaf is 0 (in `first`). Grow by 10 ⇒ ratio rises.
        assert!(l.adjust_split_ratio_for(0, SplitDir::Horizontal, 10));
        let Layout::Split { ratio, .. } = &l else {
            panic!()
        };
        assert_eq!(*ratio, 60);
    }

    #[test]
    fn adjust_split_grows_second_side_when_target_in_second() {
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        // Active leaf is 1 (in `second`). Grow by 10 ⇒ ratio FALLS (so
        // `first` shrinks, `second` grows).
        assert!(l.adjust_split_ratio_for(1, SplitDir::Horizontal, 10));
        let Layout::Split { ratio, .. } = &l else {
            panic!()
        };
        assert_eq!(*ratio, 40);
    }

    #[test]
    fn adjust_split_skips_wrong_direction() {
        // Outer is Vertical (stacked); active leaf is 0 (top).
        // A "grow width" (Horizontal) should miss — no enclosing horizontal split.
        let mut l = Layout::Split {
            dir: SplitDir::Vertical,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        let res = l.adjust_split_ratio_for(0, SplitDir::Horizontal, 10);
        assert!(!res);
    }

    #[test]
    fn move_active_to_changes_dir_and_swaps() {
        // Vertical split (stacked: 0 on top, 1 on bottom). Move active 1
        // to the LEFT (target dir = Horizontal, to_second = false).
        // After: dir = Horizontal, first = 1, second = 0.
        let mut l = Layout::Split {
            dir: SplitDir::Vertical,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        let changed = l.move_active_to(1, SplitDir::Horizontal, false);
        assert!(changed);
        let Layout::Split {
            dir, first, second, ..
        } = &l
        else {
            panic!()
        };
        assert_eq!(*dir, SplitDir::Horizontal);
        assert!(matches!(**first, Layout::Leaf { active: 1, .. }));
        assert!(matches!(**second, Layout::Leaf { active: 0, .. }));
    }

    #[test]
    fn move_active_to_noop_when_already_correct() {
        // Horizontal: 0 left, 1 right. Move active 1 to the right ⇒ no-op.
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        let changed = l.move_active_to(1, SplitDir::Horizontal, true);
        assert!(!changed);
    }

    #[test]
    fn equalize_splits_resets_every_ratio() {
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 75,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::Split {
                dir: SplitDir::Vertical,
                ratio: 20,
                first: Box::new(Layout::leaf(1)),
                second: Box::new(Layout::leaf(2)),
            }),
        };
        l.equalize_splits();
        let Layout::Split { ratio, second, .. } = &l else {
            panic!()
        };
        assert_eq!(*ratio, 50);
        let Layout::Split { ratio: inner, .. } = &**second else {
            panic!()
        };
        assert_eq!(*inner, 50);
    }

    #[test]
    fn set_ratio_walks_the_path() {
        let mut l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::Split {
                dir: SplitDir::Vertical,
                ratio: 50,
                first: Box::new(Layout::leaf(1)),
                second: Box::new(Layout::leaf(2)),
            }),
        };
        l.set_ratio_at(&[], 70); // the outer split
        l.set_ratio_at(&[true], 30); // the nested split (go into `second`)
        l.set_ratio_at(&[false], 99); // a Leaf — no-op
        let Layout::Split { ratio, second, .. } = &l else {
            panic!()
        };
        assert_eq!(*ratio, 70);
        let Layout::Split { ratio: inner, .. } = &**second else {
            panic!()
        };
        assert_eq!(*inner, 30);
    }

    #[test]
    fn leaf_containing_returns_tab_list_for_background_tab() {
        // A leaf with background tabs [10, 20, 30], active is 20.
        // leaf_containing(30) should return the full [10, 20, 30]
        // (not just the queried pane).
        let l = Layout::leaf_with_tabs(20, vec![10, 20, 30]);
        assert_eq!(l.leaf_containing(30), Some(&[10, 20, 30][..]));
        assert_eq!(l.leaf_containing(10), Some(&[10, 20, 30][..]));
        assert_eq!(l.leaf_containing(20), Some(&[10, 20, 30][..]));
        assert_eq!(l.leaf_containing(99), None);
    }

    #[test]
    fn leaf_containing_finds_across_splits() {
        let l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf_with_tabs(1, vec![1, 2])),
            second: Box::new(Layout::leaf_with_tabs(3, vec![3, 4])),
        };
        assert_eq!(l.leaf_containing(2), Some(&[1, 2][..]));
        assert_eq!(l.leaf_containing(4), Some(&[3, 4][..]));
        assert_eq!(l.leaf_containing(99), None);
    }

    #[test]
    fn all_panes_includes_background_tabs_across_splits() {
        // Regression check: `all_panes()` must surface background tabs on
        // BOTH sides of a split. This is what garbage-collection walks
        // rely on to know "pane X is still reachable somewhere".
        let l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf_with_tabs(1, vec![1, 2, 5])),
            second: Box::new(Layout::leaf_with_tabs(3, vec![3, 4])),
        };
        let mut panes = l.all_panes();
        panes.sort();
        assert_eq!(panes, vec![1, 2, 3, 4, 5]);
    }

    #[test]
    fn remove_background_tab_keeps_leaf_and_active() {
        // Regression: removing a BACKGROUND tab must not touch `active`
        // and must not collapse the leaf.
        let mut l = Layout::leaf_with_tabs(20, vec![10, 20, 30]);
        assert!(l.remove_leaf(10));
        let Layout::Leaf { active, tabs } = &l else {
            panic!("leaf collapsed unexpectedly");
        };
        assert_eq!(*active, 20);
        assert_eq!(*tabs, vec![20, 30]);
    }

    #[test]
    fn divider_hit_ratio_for() {
        let area = Rect::new(10, 0, 100, 20);
        let h = DividerHit {
            rect: Rect::new(60, 0, 1, 20),
            dir: SplitDir::Horizontal,
            area,
            path: vec![],
        };
        assert_eq!(h.ratio_for(60, 5), 50); // 50 cols into a 100-wide area at x=10
        assert_eq!(h.ratio_for(10, 5), 10); // clamped low
        assert_eq!(h.ratio_for(109, 5), 90); // clamped high
    }

    #[test]
    fn rects_sum_and_divide() {
        let area = Rect::new(0, 0, 80, 24);
        let l = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        let (leaves, divs) = l.compute_rects(area);
        assert_eq!(leaves.len(), 2);
        assert_eq!(divs.len(), 1);
        let (_, r0) = leaves[0];
        let (_, r1) = leaves[1];
        // widths + 1 divider == 80
        assert_eq!(r0.width + 1 + r1.width, 80);
        assert_eq!(r0.height, 24);
        assert_eq!(divs[0].0.width, 1);
    }
}
