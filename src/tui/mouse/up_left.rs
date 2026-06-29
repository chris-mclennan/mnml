//! Up(Left) dispatch — extracted from `mouse/mod.rs` (T-7 of the
//! file-split refactor, 2026-06-29). Mouse-up is the
//! "drag completed; commit the drop" event: ends in-flight drags
//! (scrollbar, tree-edge, panel-edge, dock-widget, divider),
//! handles drop targets for tree-drag and bufferline-tab drag,
//! and clears all the drag-state rects.
//!
//! Public surface: `handle_up_left(app, x, y)`.

use crate::app::App;
use crate::pane::Pane;

pub(super) fn handle_up_left(app: &mut App, x: u16, y: u16) {
    app.end_scrollbar_drag();
    app.end_tree_edge_drag();
    app.end_right_panel_edge_drag();
    app.end_git_graph_detail_drag();
    app.end_divider_drag();
    app.drag_select = None;
    app.dragging_tab_page = None;
    // Dock widget drag — resolve the final cursor position.
    //
    // Magnetic snap first: if the cursor is near another
    // widget's body, place the dragged widget in that
    // widget's corner + reorder it adjacent in the vec
    // (above/below based on cursor Y vs target center).
    //
    // Fallback: existing quadrant-of-editor-body logic.
    // Sessions panel drag — released over another session
    // tab swaps the two panes in `app.panes` so the
    // visible order matches the drop position.
    if let Some(src_pid) = app.session_drag_pid.take()
        && let Some(&(_, dst_pid)) = app
            .rects
            .session_tabs
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        && src_pid != dst_pid
        && src_pid < app.panes.len()
        && dst_pid < app.panes.len()
    {
        app.panes.swap(src_pid, dst_pid);
        // The active pane id stays pointing at the same
        // physical pane (now at the dst index, since we
        // swapped). Re-route active so it follows the
        // drag.
        if app.active == Some(src_pid) {
            app.active = Some(dst_pid);
        } else if app.active == Some(dst_pid) {
            app.active = Some(src_pid);
        }
    }
    if let Some(drag_id) = app.dock_drag_id.take()
        && let Some(body) = app.rects.body
        && body.width > 0
        && body.height > 0
    {
        const SNAP_DIST: u32 = 8;
        // Find the closest non-self widget body rect by
        // Manhattan distance to its center.
        let snap_target = app
            .rects
            .dock_widget_bodies
            .iter()
            .filter(|(_, id)| *id != drag_id)
            .map(|(r, id)| {
                let cx = r.x + r.width / 2;
                let cy = r.y + r.height / 2;
                let dx = (cx as i32 - x as i32).unsigned_abs();
                let dy = (cy as i32 - y as i32).unsigned_abs();
                (dx + dy, *id, *r)
            })
            .min_by_key(|(d, _, _)| *d);

        if let Some((dist, target_id, target_rect)) = snap_target
            && dist <= SNAP_DIST
        {
            // Inherit target's corner + reorder so the
            // dragged widget sits adjacent to the target.
            let target_corner = app
                .dock_widgets
                .iter()
                .find(|w| w.id == target_id)
                .map(|w| w.corner);
            if let Some(corner) = target_corner {
                if let Some(w) = app.dock_widgets.iter_mut().find(|w| w.id == drag_id) {
                    w.corner = corner;
                }
                // Move the dragged widget in the vec to sit
                // either just before or just after the
                // target based on the cursor's side.
                let target_mid_y = target_rect.y + target_rect.height / 2;
                let put_before = y < target_mid_y;
                if let Some(src_idx) = app.dock_widgets.iter().position(|w| w.id == drag_id) {
                    let dragged = app.dock_widgets.remove(src_idx);
                    // Re-locate the target after removal.
                    let target_idx = app
                        .dock_widgets
                        .iter()
                        .position(|w| w.id == target_id)
                        .unwrap_or(app.dock_widgets.len());
                    let insert_at = if put_before {
                        target_idx
                    } else {
                        (target_idx + 1).min(app.dock_widgets.len())
                    };
                    app.dock_widgets.insert(insert_at, dragged);
                }
            }
        } else {
            let mid_x = body.x + body.width / 2;
            let mid_y = body.y + body.height / 2;
            let new_corner = match (x < mid_x, y < mid_y) {
                (true, true) => crate::dock::DockCorner::TopLeft,
                (false, true) => crate::dock::DockCorner::TopRight,
                (true, false) => crate::dock::DockCorner::BottomLeft,
                (false, false) => crate::dock::DockCorner::BottomRight,
            };
            if let Some(w) = app.dock_widgets.iter_mut().find(|w| w.id == drag_id) {
                w.corner = new_corner;
            }
        }
        app.dock_drag_cursor = None;
    }
    // Rail section drag-resize release. If the pointer never
    // moved, treat as a click → toggle the section's
    // collapse state. If it did move, commit the new
    // `*_user_max_h` (already updated on each drag tick).
    if let Some(drag) = app.rail_section_drag.take()
        && !drag.moved
    {
        match drag.kind {
            crate::app::RailSectionKind::Integrations => {
                app.integration_section_expanded = !app.integration_section_expanded;
            }
            crate::app::RailSectionKind::Git => {
                app.toggle_git_section_expanded();
            }
        }
    }
    // Tree drag-drop release. Three outcomes:
    //  1. over a pane body + the source is a FILE → drag-to-split:
    //     open the file in a split / move it into that pane.
    //  2. over the tree → complete a file/dir MOVE if the drag armed;
    //     otherwise it was a plain click on a file → the DEFERRED open
    //     (preview, or a permanent tab on double-click).
    //  3. released anywhere else → cancel.
    if let Some(drag) = app.tree_drag.as_ref() {
        let src_path = drag.src_path.clone();
        let src_is_dir = drag.src_is_dir;
        let armed = drag.armed;
        let over_body = app
            .rects
            .pane_bodies
            .iter()
            .any(|(r, _)| crate::app::dispatch::contains(*r, x, y));
        let tree_rect = app
            .rects
            .tree
            .filter(|tr| crate::app::dispatch::contains(*tr, x, y));
        // 2026-06-22 — when no editor pane is open
        // (`pane_bodies` is empty), a drop anywhere
        // outside the tree should still open the file.
        // drop_tree_file_on_pane already falls back to
        // open_path when there's no pane under the
        // cursor; we just need to call it.
        let empty_editor = app.rects.pane_bodies.is_empty() && tree_rect.is_none();
        if (over_body || empty_editor) && !src_is_dir {
            app.tree_drag = None;
            app.drop_tree_file_on_pane(src_path, x, y);
        } else if let Some(tr) = tree_rect {
            let idx = (y - tr.y) as usize + app.rects.tree_scroll;
            let target = (idx < app.tree.visible_rows().len()).then_some(idx);
            app.end_tree_drag(target); // moves if armed; no-op otherwise
            if !armed && !src_is_dir {
                // Plain click on a file → the deferred open.
                let permanent = matches!(app.last_click, Some((_, _, _, c)) if c >= 2);
                if permanent {
                    app.open_path(&src_path);
                } else {
                    app.open_path_preview(&src_path);
                }
            }
        } else {
            // Released in limbo (e.g. over chrome) → cancel.
            app.tree_drag = None;
        }
    }
    // Bufferline tab release. If it ended over a pane body, split that
    // pane (edge zone) or move the dragged pane into it (center zone).
    // Otherwise it was a plain click / a reorder release on the tab
    // strip → reveal the tab (deferred buffer-switch).
    //
    // 2026-06-21 — VS Code-style: double-click on a tab
    // promotes a preview tab to a regular tab (the italic
    // becomes plain). Single click just reveals.
    if let Some(src) = app.rects.bufferline_drag_tab {
        // Clear visuals first.
        app.rects.bufferline_drag_ghost = None;
        app.rects.tab_insert_hint = None;
        // Released on a per-leaf tab strip → insert at the
        // computed position. Tries this BEFORE other drop
        // handlers so the strip area wins over the pane
        // body just below it (drag-to-pane-body would
        // otherwise split unintentionally).
        if app.drop_tab_on_strip(src, x, y) {
            app.rects.bufferline_drag_tab = None;
            app.rects.tab_drop_target = None;
            return;
        }
        let over_body = app
            .rects
            .pane_bodies
            .iter()
            .any(|(r, _)| crate::app::dispatch::contains(*r, x, y));
        // Released over a different bufferline tab → swap
        // (kept as fallback for the single-leaf bufferline
        // strip; per-leaf strips go through drop_tab_on_strip
        // above which is positional).
        let dst_tab = app
            .rects
            .bufferline_tabs
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, pid)| *pid);
        if let Some(dst) = dst_tab
            && dst != src
        {
            app.swap_bufferline_tabs(src, dst);
            app.rects.bufferline_drag_tab = None;
            app.rects.tab_drop_target = None;
            return;
        }
        // vscode-user 2026-06-28 SEV-2: drag released past
        // the last tab on the bufferline row → drop on the
        // rightmost tab so the user gets a "move to end"
        // gesture. Without this, dragging slightly past
        // the rightmost tab fell through to reveal_pane
        // (click semantics), making drag-to-reorder feel
        // broken.
        if let Some(&(rect, rightmost_pid)) = app
            .rects
            .bufferline_tabs
            .iter()
            .filter(|(r, _)| r.y <= y && y < r.y + r.height)
            .max_by_key(|(r, _)| r.x + r.width)
            && x >= rect.x + rect.width
            && rightmost_pid != src
        {
            app.swap_bufferline_tabs(src, rightmost_pid);
            app.rects.bufferline_drag_tab = None;
            app.rects.tab_drop_target = None;
            return;
        }
        if over_body {
            app.drop_tab_on_pane(src, x, y);
        } else {
            // Detect double-click on the same tab rect.
            let now = std::time::Instant::now();
            let is_double = matches!(
                app.last_click,
                Some((prev, px, py, _))
                    if px == x
                        && py == y
                        && now.duration_since(prev) < std::time::Duration::from_millis(450)
            );
            app.last_click = Some((now, x, y, if is_double { 2 } else { 1 }));
            if is_double && let Some(Pane::Editor(b)) = app.panes.get_mut(src) {
                b.is_preview = false;
            }
            app.reveal_pane(src);
        }
    }
    app.rects.tab_drop_target = None;
    // Mouse-up always clears the bufferline-tab drag arm + ghost.
    app.rects.bufferline_drag_tab = None;
    app.rects.bufferline_drag_ghost = None;
}
