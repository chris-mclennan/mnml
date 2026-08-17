//! Mouse-drag interactions on `App` — tree-panel edge resize,
//! right-panel edge resize, editor scrollbar drag (vertical +
//! horizontal), and the shared `set_pane_scroll` writer that every
//! scrollbar-hit routes through.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    // ─── branches / worktrees ───────────────────────────────────────
    /// If `(x, y)` is on the rail's right-edge handle, start a tree-width drag.
    /// Returns true if so. (The drag continues with [`Self::drag_tree_edge_to`]
    /// + ends with [`Self::end_tree_edge_drag`].)
    pub fn begin_tree_edge_drag(&mut self, x: u16, y: u16) -> bool {
        // A registered click chip wins over the drag handle when
        // they overlap. The drag zone is wide (3 cells) for trackpad
        // discoverability, so it commonly overlaps small right-
        // aligned chips like the `+` workspace-add button. Without
        // this check, the chip was unclickable (the drag handle
        // swallowed the click first). 2026-06-19 user-reported.
        let on_chip = self
            .rects
            .tree_icon_buttons
            .iter()
            .any(|(r, _)| crate::app::dispatch::contains(*r, x, y));
        if on_chip {
            return false;
        }
        if let Some(r) = self.rects.tree_edge
            && x >= r.x
            && x < r.x + r.width
            && y >= r.y
            && y < r.y + r.height
        {
            self.dragging_tree_edge = true;
            return true;
        }
        false
    }
    /// Continue a tree-width drag: set the rail's width to the column under
    /// the pointer, clamped to `[16, min(80, screen_width - 20)]`. Bounds
    /// match the Settings schema's `ui.tree_width` clamp so a runtime drag
    /// can't put the tree into a state the config path forbids.
    /// mouse-round-11 SEV-2 2026-07-12 (min), mouse-round-16 F2 2026-07-17 (max).
    pub fn drag_tree_edge_to(&mut self, x: u16, screen_width: u16) {
        if !self.dragging_tree_edge {
            return;
        }
        const TREE_WIDTH_MIN: u16 = 16;
        const TREE_WIDTH_MAX: u16 = 80;
        let max = screen_width
            .saturating_sub(20)
            .clamp(TREE_WIDTH_MIN, TREE_WIDTH_MAX);
        let new = x.clamp(TREE_WIDTH_MIN, max);
        self.tree_width = new;
    }
    pub fn end_tree_edge_drag(&mut self) {
        self.dragging_tree_edge = false;
    }
    /// vscode-user-mouse SEV-1 — mirror of maybe-tree-edge-drag for
    /// the right panel. Returns true if the click landed on the
    /// panel's left-edge grip and a drag was started.
    pub fn maybe_start_right_panel_edge_drag(&mut self, x: u16, y: u16) -> bool {
        if let Some(r) = self.rects.right_panel_edge
            && x >= r.x
            && x < r.x + r.width
            && y >= r.y
            && y < r.y + r.height
        {
            self.dragging_right_panel_edge = true;
            return true;
        }
        false
    }
    pub fn end_right_panel_edge_drag(&mut self) {
        self.dragging_right_panel_edge = false;
    }

    /// If `(x, y)` lands on any rendered scrollbar, start a scrollbar
    /// drag + jump-scroll to the click position. Returns true on hit.
    /// Walks `rects.scrollbars` in reverse so a scrollbar painted over
    /// an earlier one (rare — embedded-diff over the graph's body)
    /// wins. Subsequent `Drag(Left)` events route to
    /// [`Self::drag_scrollbar_to`]; mouse-up clears via
    /// [`Self::end_scrollbar_drag`].
    pub fn begin_scrollbar_drag(&mut self, x: u16, y: u16) -> bool {
        for hit in self.rects.scrollbars.iter().rev().copied() {
            let r = hit.area;
            if x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height {
                self.dragging_scrollbar = Some(hit);
                self.apply_scrollbar_to(hit, x, y);
                return true;
            }
        }
        false
    }
    /// Continue a scrollbar drag — maps the current pointer position
    /// (X for horizontal bars, Y for vertical) to a proportional
    /// scroll offset and updates the underlying pane.
    pub fn drag_scrollbar_to(&mut self, x: u16, y: u16) -> bool {
        let Some(hit) = self.dragging_scrollbar else {
            return false;
        };
        self.apply_scrollbar_to(hit, x, y);
        true
    }
    pub fn end_scrollbar_drag(&mut self) {
        self.dragging_scrollbar = None;
    }
    /// Map `y` (a screen row) onto a new scroll value for the pane the
    /// `hit` references, then assign it. Used by both the initial
    /// click and the per-tick drag continuation.
    fn apply_scrollbar_to(&mut self, hit: ScrollbarHit, x: u16, y: u16) {
        let horizontal = hit.kind.is_horizontal();
        let span_cells = if horizontal {
            hit.area.width
        } else {
            hit.area.height
        };
        if hit.total <= hit.viewport || span_cells == 0 {
            return;
        }
        let cells = span_cells as usize;
        // Position the viewport so the clicked cell maps proportionally
        // into the document. Horizontal bars track X, vertical track Y.
        let (pos, origin) = if horizontal {
            (x, hit.area.x)
        } else {
            (y, hit.area.y)
        };
        let rel = pos
            .saturating_sub(origin)
            .min(cells.saturating_sub(1) as u16) as usize;
        let max_scroll = hit.total - hit.viewport;
        // Anchor the *middle* of the visible range to the click row
        // so big viewports don't snap to the very top when the click
        // is near the bottom edge.
        let half_vp_cells = (hit.viewport * cells / hit.total).max(1) / 2;
        let anchor = rel.saturating_sub(half_vp_cells);
        let max_anchor = cells.saturating_sub((hit.viewport * cells / hit.total).max(1));
        let new_scroll = if max_anchor == 0 {
            0
        } else {
            (anchor * max_scroll)
                .div_ceil(max_anchor.max(1))
                .min(max_scroll)
        };
        self.set_pane_scroll(hit.pane_id, hit.kind, new_scroll);
    }
    /// Dispatch a new scroll value into whichever pane field the kind
    /// names. No-op when the pane is gone or the variant doesn't match
    /// (the rect was painted last frame; the user could have closed
    /// the pane in between).
    pub fn set_pane_scroll(&mut self, pane_id: PaneId, kind: ScrollbarKind, scroll: usize) {
        // The file tree + agents panel aren't panes — their scroll lives on
        // dedicated App fields.
        // qa-feature 2026-07-01 — tree scrollbars also snap the
        // CURSOR to the new scroll top. Without this the per-frame
        // "keep cursor in view" logic in tree_view immediately
        // reverted scroll back to whatever row cursor pointed at,
        // so drag felt like it did nothing.
        if matches!(kind, ScrollbarKind::Tree) {
            self.tree.scroll = scroll;
            self.tree.set_cursor(scroll);
            return;
        }
        if let ScrollbarKind::ExtraTree(ws_idx) = kind {
            if let Some(w) = self.extra_workspaces.get_mut(ws_idx) {
                w.tree.scroll = scroll;
                w.tree.set_cursor(scroll);
            }
            return;
        }
        if matches!(kind, ScrollbarKind::AgentsPanel) {
            self.agents_panel_scroll = scroll;
            return;
        }
        // Resolved up-front: a scrollbar drag follows the same policy
        // as the mouse wheel (see `Self::cursor_follows_wheel`). Read
        // before the &mut borrow on `self.panes` below.
        let follows_cursor = matches!(kind, ScrollbarKind::Editor | ScrollbarKind::EditorHScroll)
            && self.cursor_follows_wheel();
        match (kind, self.panes.get_mut(pane_id)) {
            (ScrollbarKind::Editor, Some(Pane::Editor(b))) => {
                if follows_cursor {
                    // Drag cursor along — same as the editor wheel in
                    // cursor-follows mode. Renderer's keep-cursor-in-
                    // view will hold the scroll where the cursor is.
                    b.editor.place_cursor(scroll, 0);
                } else {
                    b.scroll = scroll;
                    b.scroll_pinned = true;
                }
            }
            (ScrollbarKind::EditorHScroll, Some(Pane::Editor(b))) => {
                b.h_scroll = scroll;
            }
            (ScrollbarKind::Diff, Some(Pane::Diff(d))) => {
                d.scroll = scroll;
            }
            (ScrollbarKind::EmbeddedDiff, Some(Pane::GitGraph(g))) => {
                if let Some(d) = g.embedded_diff.as_mut() {
                    d.scroll = scroll;
                }
            }
            (ScrollbarKind::GitGraphCommits, Some(Pane::GitGraph(g))) => {
                // Snap selection to the new scroll position so the
                // per-frame keep-selected-on-screen math (in
                // `git_graph_view::draw`) doesn't immediately fight
                // the scrollbar back to the old position.
                let total = g.total_rows();
                if total > 0 {
                    let new_scroll = scroll.min(total - 1);
                    g.scroll = new_scroll;
                    if g.selected != new_scroll {
                        g.selected = new_scroll;
                        g.reload_detail();
                    }
                }
            }
            // List panes — pull selection along with scroll for the
            // same reason: the per-frame keep-selected-on-screen math
            // in each renderer would otherwise snap scroll back.
            (ScrollbarKind::Tests, Some(Pane::Tests(p))) => {
                p.scroll = scroll;
                p.selected = scroll;
            }
            (ScrollbarKind::Flaky, Some(Pane::Flaky(p))) => {
                p.scroll = scroll;
                p.selected = scroll;
            }
            (ScrollbarKind::Diagnostics, Some(Pane::Diagnostics(p))) => {
                p.scroll = scroll;
                p.selected = scroll;
            }
            (ScrollbarKind::Outline, Some(Pane::Outline(p))) => {
                p.scroll = scroll;
                p.selected = scroll;
            }
            (ScrollbarKind::Grep, Some(Pane::Grep(p)))
            | (ScrollbarKind::Quickfix, Some(Pane::Quickfix(p))) => {
                p.scroll = scroll;
                p.selected = scroll;
            }
            (ScrollbarKind::GitStatus, Some(Pane::GitStatus(p))) => {
                p.scroll = scroll;
                p.selected = scroll;
            }
            (ScrollbarKind::CmdlineHistory, Some(Pane::CmdlineHistory(p))) => {
                p.scroll = scroll;
                p.selected = scroll;
            }
            _ => {}
        }
    }
}
