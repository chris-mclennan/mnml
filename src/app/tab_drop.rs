//! Drag-a-tab-onto-a-pane → split (VS Code-style drag-to-split).
//!
//! Builds on the existing bufferline tab drag-reorder (`bufferline_drag_tab`
//! in `PaneRects`). When a tab drag ends over a *pane body* (rather than the
//! tab strip), the dragged pane is moved into the layout next to the pane under
//! the cursor:
//!
//! * an **edge** zone (left/right/top/bottom) splits the target pane in that
//!   direction and drops the dragged pane into the new half;
//! * the **center** zone moves the dragged pane *into* the target's slot
//!   (replacing what's shown there — the displaced pane stays open as a
//!   background bufferline tab, nothing is destroyed).
//!
//! Both are pure `Layout` mutations: `remove_leaf` detaches the dragged pane
//! from the visible tree (a no-op if it was already a background tab), then
//! `replace_leaf` re-inserts it. `App::panes` is never touched, so no buffer is
//! closed and no `PaneId` shifts.

use crate::app::App;
use crate::focus::Focus;
use crate::layout::{Layout, PaneId, SplitDir};
use crate::pane::Pane;
use ratatui::layout::Rect;
use std::path::PathBuf;

/// Which region of a pane body the cursor is over during a tab drag.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DropZone {
    Left,
    Right,
    Top,
    Bottom,
    Center,
}

impl App {
    /// While a bufferline tab is being dragged, record which pane body + zone
    /// the cursor is over (or clear it when over the tab strip / off any pane).
    /// Read by the drop-hint overlay in `ui::draw`.
    pub fn update_tab_drop_target(&mut self, x: u16, y: u16) {
        self.rects.tab_drop_target = hit_pane(self, x, y);
    }

    /// Complete a bufferline tab drag that ended at `(x, y)`. If it ended over
    /// a pane body, split that pane (edge zones) or move the dragged pane into
    /// it (center zone). No-op when released over the tab strip / off any pane,
    /// or when dropped onto its own pane.
    pub fn drop_tab_on_pane(&mut self, src: PaneId, x: u16, y: u16) {
        self.rects.tab_drop_target = None;
        let Some((target, zone)) = hit_pane(self, x, y) else {
            return;
        };
        if src == target {
            // Dropping a tab onto its own pane body — happens when
            // the user drags the active tab from the bufferline
            // onto the visible pane (the only pane in single-leaf
            // layouts). Center is a no-op; edges mean "split this
            // leaf and put src in the new half" — split_tab_into
            // already does that (finds a sibling tab, splices).
            if matches!(zone, DropZone::Center) {
                return;
            }
            self.split_tab_into(src, zone);
            return;
        }
        self.splice_pane_at(src, target, zone);
        self.active = Some(src);
        self.focus = Focus::Pane;
    }

    /// Complete a *file-tree* drag that ended at `(x, y)`: open `path` (reusing
    /// an already-open editor pane for it, else creating one) and place it next
    /// to the pane under the cursor — the tree-file twin of `drop_tab_on_pane`.
    /// Falls back to a plain `open_path` when not released over a pane body.
    pub fn drop_tree_file_on_pane(&mut self, path: PathBuf, x: u16, y: u16) {
        self.rects.tab_drop_target = None;
        let Some((target, zone)) = hit_pane(self, x, y) else {
            // Not over a pane — behave like a normal open.
            self.open_path(&path);
            return;
        };
        // Reuse an already-open editor pane for this file, else mint one.
        let src = match self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        {
            Some(id) => id,
            None => {
                let mut b = crate::buffer::Buffer::open(&path, &self.config)
                    .unwrap_or_else(|_| crate::buffer::Buffer::scratch(&self.config));
                b.apply_editorconfig(&self.workspace);
                self.panes.push(Pane::Editor(b));
                self.panes.len() - 1
            }
        };
        if src != target {
            self.splice_pane_at(src, target, zone);
        }
        self.active = Some(src);
        self.focus = Focus::Pane;
    }

    /// Split off `src` into a new half of the leaf containing it.
    /// Mirrors the drag-to-edge gesture but driven by the keyboard /
    /// right-click "Split right/down/left/up" menu items. Needs a
    /// surviving sibling tab in the current leaf — splitting a
    /// solo tab off itself is a no-op (just leaves an empty leaf).
    /// Drop a dragged tab onto a tab strip (Chrome / VS Code tab-bar
    /// drop). Finds the strip under `(x, y)`, computes the insert
    /// index from the cursor's x position relative to chips on
    /// that strip, and moves `src` into the strip's leaf at that
    /// index. Falls back to no-op when not over any strip.
    /// Returns true when the drop landed.
    pub fn drop_tab_on_strip(&mut self, src: PaneId, x: u16, y: u16) -> bool {
        // Hit the strip first.
        let strip_hit = self
            .rects
            .split_tab_strip_areas
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .copied();
        let Some((_strip_rect, leaf_active)) = strip_hit else {
            return false;
        };
        let insert_idx = self.tab_strip_insert_idx(leaf_active, x);
        // Remove src from wherever it lives, then insert at idx.
        self.layout_mut().remove_leaf(src);
        if let Some((_active, tabs)) = self.layout_mut().active_leaf_mut(leaf_active) {
            // Clamp index since remove_leaf may have shifted things.
            let idx = insert_idx.min(tabs.len());
            // Avoid double-insert if src is somehow already there.
            if !tabs.contains(&src) {
                tabs.insert(idx, src);
            }
        } else {
            // Target leaf vanished — fall back to making src the
            // visible leaf so we don't leave it orphaned.
            self.layout_mut()
                .replace_leaf(leaf_active, Layout::leaf(src));
        }
        // Flip the leaf's active to src so the drop is visible.
        if let Some((active, _tabs)) = self.layout_mut().active_leaf_mut(leaf_active) {
            *active = src;
        }
        self.active = Some(src);
        self.focus = Focus::Pane;
        true
    }

    /// Compute the insert index for a tab dropping at cursor `x`
    /// on the strip belonging to `leaf_active`. Walks the strip's
    /// chips in left-to-right order; the insert position is
    /// "before the first chip whose center is to the right of x"
    /// (or `tabs.len()` if no such chip — i.e. append).
    pub(crate) fn tab_strip_insert_idx(&self, leaf_active: PaneId, x: u16) -> usize {
        let mut chips: Vec<(u16, PaneId)> = self
            .rects
            .split_tab_chips
            .iter()
            .filter_map(|(r, leaf, pane)| {
                if *leaf == leaf_active {
                    Some((r.x + r.width / 2, *pane))
                } else {
                    None
                }
            })
            .collect();
        chips.sort_by_key(|(cx, _)| *cx);
        // Find the leaf's actual tab order so insert_idx maps to
        // the right position. The chips are stored in render
        // order which matches the tab vec.
        let mut idx = 0;
        for (cx, _pid) in &chips {
            if x < *cx {
                return idx;
            }
            idx += 1;
        }
        idx
    }

    /// Update `tab_insert_hint` while a tab drag is in flight.
    /// Called from the Drag / Moved handlers. Sets None when the
    /// cursor isn't over any strip.
    pub fn update_tab_insert_hint(&mut self, x: u16, y: u16) {
        let strip_hit = self
            .rects
            .split_tab_strip_areas
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .copied();
        let Some((strip_rect, leaf_active)) = strip_hit else {
            self.rects.tab_insert_hint = None;
            return;
        };
        let idx = self.tab_strip_insert_idx(leaf_active, x);
        // Pick the insertion-x: midpoint between the chip before
        // idx and the chip at idx. For idx==0 → left edge of strip.
        // For idx==len → right of the last chip.
        let mut chips: Vec<u16> = self
            .rects
            .split_tab_chips
            .iter()
            .filter(|(_, leaf, _)| *leaf == leaf_active)
            .map(|(r, _, _)| r.x + r.width)
            .collect();
        chips.sort();
        let insertion_x = if idx == 0 {
            strip_rect.x
        } else if idx >= chips.len() {
            chips.last().copied().unwrap_or(strip_rect.x)
        } else {
            let prev_end = chips[idx - 1];
            let next_start = self
                .rects
                .split_tab_chips
                .iter()
                .filter(|(_, leaf, _)| *leaf == leaf_active)
                .map(|(r, _, _)| r.x)
                .min()
                .unwrap_or(strip_rect.x);
            (prev_end + next_start) / 2
        };
        self.rects.tab_insert_hint = Some((strip_rect, insertion_x, leaf_active, idx));
    }

    pub fn split_tab_into(&mut self, src: PaneId, zone: DropZone) {
        // First try: a sibling tab in the same leaf (the
        // common case — splice_pane_at handles it cleanly).
        if let Some(target) = self
            .layout()
            .leaf_containing(src)
            .and_then(|tabs| tabs.iter().find(|&&t| t != src).copied())
        {
            self.splice_pane_at(src, target, zone);
            self.active = Some(src);
            self.focus = Focus::Pane;
            return;
        }
        // Fallback: src is alone in its leaf, but other panes
        // exist in `app.panes` as orphans (visible in the global
        // bufferline, not in any leaf — can happen via earlier
        // buggy layout transitions or background-tab edge cases).
        // Pick one orphan to fill the "stays behind" half of the
        // split so we don't lose layout coverage.
        let in_layout: std::collections::HashSet<PaneId> = (0..self.panes.len())
            .filter(|&i| self.layouts.iter().any(|l| l.leaf_containing(i).is_some()))
            .collect();
        let orphan = (0..self.panes.len()).find(|&i| {
            i != src
                && !in_layout.contains(&i)
                && !matches!(self.panes.get(i), Some(crate::pane::Pane::Pty(_)))
        });
        if let Some(orphan) = orphan {
            // Bring the orphan into src's leaf as a tab, then run
            // the normal split path. That way the orphan ends up
            // in the original leaf's spot and src goes into the
            // new half — same shape as the sibling case.
            if let Some((_active, tabs)) = self.layout_mut().leaf_containing_mut(src) {
                tabs.insert(0, orphan); // before src
            }
            self.splice_pane_at(src, orphan, zone);
            self.active = Some(src);
            self.focus = Focus::Pane;
            return;
        }
        self.toast("can't split: tab is alone in its pane");
    }

    /// Place pane `src` next to leaf `target` per `zone`. Detaches `src` from
    /// the visible tree first (a no-op if it was a background tab; if it was a
    /// visible split half, that split collapses into its sibling). `target`'s
    /// id is stable across this — `remove_leaf` only reshapes the tree.
    fn splice_pane_at(&mut self, src: PaneId, target: PaneId, zone: DropZone) {
        self.layout_mut().remove_leaf(src);
        match zone {
            DropZone::Center => {
                // 2026-06-22 multi-tab: add `src` as a new tab in
                // the target leaf and flip it active. Previously
                // replaced the leaf, orphaning the prior pane.
                if let Some((active, tabs)) = self.layout_mut().active_leaf_mut(target) {
                    if !tabs.contains(&src) {
                        tabs.push(src);
                    }
                    *active = src;
                } else {
                    self.layout_mut().replace_leaf(target, Layout::leaf(src));
                }
            }
            _ => {
                let (dir, src_first) = match zone {
                    DropZone::Left => (SplitDir::Horizontal, true),
                    DropZone::Right => (SplitDir::Horizontal, false),
                    DropZone::Top => (SplitDir::Vertical, true),
                    DropZone::Bottom => (SplitDir::Vertical, false),
                    DropZone::Center => unreachable!(),
                };
                // PRESERVE the target leaf's full tab list. Old code
                // built `Layout::leaf(target)` which silently
                // orphaned every other tab that shared the same
                // leaf (e.g. 3-tab leaf → split → 1 tab lost).
                // Pull the post-remove_leaf leaf's tabs + active and
                // use them for the target half. Fallback to
                // [target] solo when target isn't in a leaf for
                // some reason.
                let (target_active, target_tabs): (PaneId, Vec<PaneId>) =
                    if let Some((act, tabs)) = self.layout_mut().leaf_containing_mut(target) {
                        (*act, tabs.clone())
                    } else {
                        (target, vec![target])
                    };
                let target_leaf = Layout::Leaf {
                    tabs: target_tabs,
                    active: target_active,
                };
                let src_leaf = Layout::leaf(src);
                let (first, second) = if src_first {
                    (src_leaf, target_leaf)
                } else {
                    (target_leaf, src_leaf)
                };
                self.layout_mut().replace_leaf(
                    target,
                    Layout::Split {
                        dir,
                        ratio: 50,
                        first: Box::new(first),
                        second: Box::new(second),
                    },
                );
            }
        }
    }
}

/// Find the pane body under `(x, y)` and the zone within it.
fn hit_pane(app: &App, x: u16, y: u16) -> Option<(PaneId, DropZone)> {
    app.rects
        .pane_bodies
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(r, pid)| (*pid, zone_for(*r, x, y)))
}

/// Classify a point within a pane rect into a drop zone. The middle third on
/// both axes is `Center`; otherwise the nearest edge wins. Integer math only
/// (no float comparisons) so the result is deterministic and clippy-clean.
pub(crate) fn zone_for(r: Rect, x: u16, y: u16) -> DropZone {
    let w = r.width.max(1) as u32;
    let h = r.height.max(1) as u32;
    let dx = x.saturating_sub(r.x) as u32;
    let dy = y.saturating_sub(r.y) as u32;
    // Middle third on each axis (dx in [w/3, 2w/3)).
    let center_x = dx * 3 >= w && dx * 3 < w * 2;
    let center_y = dy * 3 >= h && dy * 3 < h * 2;
    if center_x && center_y {
        return DropZone::Center;
    }
    // Normalize the distance to each edge onto a common 0..=1000 scale so panes
    // of different proportions compare fairly, then pick the nearest edge.
    let left = (dx * 1000) / w;
    let right = 1000u32.saturating_sub(left);
    let top = (dy * 1000) / h;
    let bottom = 1000u32.saturating_sub(top);
    let min = left.min(right).min(top).min(bottom);
    if min == left {
        DropZone::Left
    } else if min == top {
        DropZone::Top
    } else if min == bottom {
        DropZone::Bottom
    } else {
        DropZone::Right
    }
}

/// The sub-rect of a pane body that a given drop zone occupies — used to paint
/// the drop-hint overlay so the user sees where the pane will land.
pub(crate) fn zone_rect(r: Rect, zone: DropZone) -> Rect {
    match zone {
        DropZone::Left => Rect::new(r.x, r.y, r.width / 2, r.height),
        DropZone::Right => {
            let w = r.width / 2;
            Rect::new(r.x + (r.width - w), r.y, w, r.height)
        }
        DropZone::Top => Rect::new(r.x, r.y, r.width, r.height / 2),
        DropZone::Bottom => {
            let h = r.height / 2;
            Rect::new(r.x, r.y + (r.height - h), r.width, h)
        }
        DropZone::Center => {
            // Middle third box.
            let w = (r.width / 3).max(1);
            let h = (r.height / 3).max(1);
            Rect::new(r.x + r.width / 3, r.y + r.height / 3, w, h)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::buffer::Buffer;
    use crate::config::Config;
    use crate::pane::Pane;

    fn r() -> Rect {
        Rect::new(10, 5, 30, 20)
    }

    /// An app with two editor panes (ids 0 | 1) shown as a horizontal split,
    /// active = 0. No files / no session — pure in-memory layout state.
    fn app_two_panes() -> App {
        let mut app = App::new(std::env::temp_dir(), Config::default()).unwrap();
        app.panes.clear();
        app.panes.push(Pane::Editor(Buffer::scratch(&app.config)));
        app.panes.push(Pane::Editor(Buffer::scratch(&app.config)));
        *app.layout_mut() = Layout::Split {
            dir: SplitDir::Horizontal,
            ratio: 50,
            first: Box::new(Layout::leaf(0)),
            second: Box::new(Layout::leaf(1)),
        };
        app.active = Some(0);
        app
    }

    #[test]
    fn zones_classify_by_region() {
        let rr = r();
        // Center of the rect → Center.
        assert_eq!(zone_for(rr, 10 + 15, 5 + 10), DropZone::Center);
        // Far left edge → Left.
        assert_eq!(zone_for(rr, 10, 5 + 10), DropZone::Left);
        // Far right edge → Right.
        assert_eq!(zone_for(rr, 10 + 29, 5 + 10), DropZone::Right);
        // Top edge → Top.
        assert_eq!(zone_for(rr, 10 + 15, 5), DropZone::Top);
        // Bottom edge → Bottom.
        assert_eq!(zone_for(rr, 10 + 15, 5 + 19), DropZone::Bottom);
    }

    #[test]
    fn drop_on_right_edge_splits_target_with_src_on_the_right() {
        let mut app = app_two_panes();
        let target = 0;
        let src = 1;
        // Pane 0 body rect — fabricate one and register it.
        let body = Rect::new(0, 1, 40, 20);
        app.rects.pane_bodies = vec![(body, target)];
        // Right edge of pane 0.
        app.drop_tab_on_pane(src, body.x + body.width - 1, body.y + body.height / 2);
        // Target should now be a Split whose right (second) child is `src`.
        match app.layout() {
            Layout::Split { first, second, .. } => {
                assert!(matches!(**first, Layout::Leaf { active: id, .. } if id == target));
                assert!(matches!(**second, Layout::Leaf { active: id, .. } if id == src));
            }
            other => panic!("expected a split, got {other:?}"),
        }
        assert_eq!(app.active, Some(src));
    }

    #[test]
    fn center_drop_moves_src_into_target_without_a_split() {
        let mut app = app_two_panes();
        let target = 0;
        let src = 1;
        let body = Rect::new(0, 1, 40, 20);
        app.rects.pane_bodies = vec![(body, target)];
        // Center of the target pane.
        app.drop_tab_on_pane(src, body.x + body.width / 2, body.y + body.height / 2);
        // remove_leaf(1) collapses the split to Leaf(0), then replace_leaf(0,
        // Leaf(1)) → the visible tree is just Leaf(1) (src moved in; old pane 0
        // survives as a background tab).
        assert!(matches!(app.layout(), Layout::Leaf { active: id, .. } if *id == src));
        assert_eq!(app.active, Some(src));
    }

    #[test]
    fn drop_on_own_pane_center_is_a_noop() {
        // Center-zone drop on the own pane stays a no-op even after
        // the 2026-06-27 edge-zone split fix — nothing to do when
        // dragging a tab onto its own slot's center.
        let mut app = app_two_panes();
        // Single visible leaf, no orphans → genuinely solo.
        app.panes.pop(); // drop the second pane so there's nothing to recover
        *app.layout_mut() = Layout::leaf(0);
        app.active = Some(0);
        let only = 0;
        let body = Rect::new(0, 1, 40, 20);
        app.rects.pane_bodies = vec![(body, only)];
        // Center of the pane body — landing zone for a center drop.
        app.drop_tab_on_pane(only, body.x + body.width / 2, body.y + body.height / 2);
        assert!(matches!(app.layout(), Layout::Leaf { active: id, .. } if *id == only));
    }
}
