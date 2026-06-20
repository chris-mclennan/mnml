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
use ratatui::layout::Rect;

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
            return;
        }
        // Detach the dragged pane from the visible tree first. If it was a
        // background tab (not currently shown) this is a no-op; if it was a
        // visible split half, its split collapses into its sibling. `target`'s
        // id is stable across this — `remove_leaf` only reshapes the tree.
        self.layout_mut().remove_leaf(src);
        match zone {
            DropZone::Center => {
                // Target slot now shows `src`; whatever was there becomes a
                // background tab (still listed in the bufferline).
                self.layout_mut().replace_leaf(target, Layout::Leaf(src));
            }
            _ => {
                let (dir, src_first) = match zone {
                    DropZone::Left => (SplitDir::Horizontal, true),
                    DropZone::Right => (SplitDir::Horizontal, false),
                    DropZone::Top => (SplitDir::Vertical, true),
                    DropZone::Bottom => (SplitDir::Vertical, false),
                    DropZone::Center => unreachable!(),
                };
                let (first, second) = if src_first {
                    (Layout::Leaf(src), Layout::Leaf(target))
                } else {
                    (Layout::Leaf(target), Layout::Leaf(src))
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
        self.active = Some(src);
        self.focus = Focus::Pane;
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
            first: Box::new(Layout::Leaf(0)),
            second: Box::new(Layout::Leaf(1)),
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
                assert!(matches!(**first, Layout::Leaf(id) if id == target));
                assert!(matches!(**second, Layout::Leaf(id) if id == src));
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
        assert!(matches!(app.layout(), Layout::Leaf(id) if *id == src));
        assert_eq!(app.active, Some(src));
    }

    #[test]
    fn drop_on_own_pane_is_a_noop() {
        let mut app = app_two_panes();
        // Collapse to a single visible leaf (0) for the no-op check.
        *app.layout_mut() = Layout::Leaf(0);
        app.active = Some(0);
        let only = 0;
        let body = Rect::new(0, 1, 40, 20);
        app.rects.pane_bodies = vec![(body, only)];
        app.drop_tab_on_pane(only, body.x + body.width - 1, body.y + 1);
        assert!(matches!(app.layout(), Layout::Leaf(id) if *id == only));
    }
}
