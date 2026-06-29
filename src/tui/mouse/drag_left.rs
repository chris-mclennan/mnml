//! Drag(Left) dispatch — extracted from `mouse/mod.rs` (T-6 of
//! the file-split refactor, 2026-06-29). Drag is the "mouse moved
//! with the button held" event: tracks cursors / drop targets /
//! ghost positions for tree-drag, bufferline-tab drag, dock-widget
//! drag, scrollbar drag, and pane-divider drag.
//!
//! Public surface: `handle_drag_left(app, x, y)`.

use crate::app::App;
use crate::pane::Pane;

pub(super) fn handle_drag_left(app: &mut App, x: u16, y: u16) {
    // Dock widget drag — track cursor for the live ghost +
    // drop-zone overlay. We don't commit anything until
    // mouse-up; this just updates state so the renderer
    // can paint the preview.
    if app.dock_drag_id.is_some() {
        app.dock_drag_cursor = Some((x, y));
    }
    // Tree drag — arm if armed, update target idx. Runs alongside
    // the other drag handlers since it doesn't conflict (the tree
    // drag only fires on tree rect coordinates).
    if let Some(d) = app.tree_drag.as_ref() {
        let src_is_file = !d.src_is_dir;
        // 2026-06-22 — track cursor position for the drag-
        // ghost overlay. Updated on every move regardless of
        // which region the cursor is in.
        app.set_tree_drag_cursor(x, y);
        if let Some(tr) = app.rects.tree
            && crate::app::dispatch::contains(tr, x, y)
        {
            let idx = (y - tr.y) as usize + app.rects.tree_scroll;
            let target = (idx < app.tree.visible_rows().len()).then_some(idx);
            app.drag_tree_to(target, y);
            app.rects.tab_drop_target = None;
        } else {
            app.drag_tree_to(None, y);
            // Dragging a tree FILE over a pane body → show the
            // drag-to-split drop hint (dirs only move within the tree).
            if src_is_file {
                app.update_tab_drop_target(x, y);
            } else {
                app.rects.tab_drop_target = None;
            }
        }
    }
    // Tab-page chip drag-to-reorder. If the user pressed on a
    // chip and is dragging across another chip's rect, swap
    // the two tabs. Update dragging_tab_page so the cursor
    // can continue to drag the same tab further.
    if let Some(src) = app.dragging_tab_page {
        let dst = app
            .rects
            .bufferline_tab_page_chips
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, idx)| *idx);
        if let Some(dst) = dst
            && dst != src
        {
            app.tab_swap(src, dst);
            app.dragging_tab_page = Some(dst);
        }
        return;
    }
    // Bufferline (file-tab) drag — update visuals only.
    // Reorder + drop-to-pane both happen on mouse-UP. Doing
    // them on Drag caused thrash with 2+ tabs: hovering over
    // a sibling tab fired swap_bufferline_tabs, the cursor
    // ended up over the now-moved source, swap fired again,
    // and so on. Moving the swap to mouse-up makes drag-to-
    // pane-body work cleanly regardless of how many tabs.
    if app.rects.bufferline_drag_tab.is_some() {
        app.rects.bufferline_drag_ghost = Some((x, y));
        app.update_tab_drop_target(x, y);
        app.update_tab_insert_hint(x, y);
        return;
    }
    if let Some(mut drag) = app.rail_section_drag {
        // Drag-resize a rail section. `start_y - y` is the
        // upward pointer offset; that's how many extra rows
        // the section's top edge gets to claim (section
        // grows UP). Layout code caps at `content_needed`
        // automatically.
        drag.moved = true;
        let delta = drag.start_y as i32 - y as i32;
        let new_h = (drag.start_h as i32 + delta).clamp(1, 200) as u16;
        // Dragging the header down past where the section
        // would only show its own header (≤ 2 rows total)
        // → snap to collapsed. The collapsed header still
        // shows, just with the chevron pointing right;
        // a future expand resets `user_max_h` so the
        // section auto-sizes again.
        const COLLAPSE_THRESHOLD: u16 = 2;
        let collapse = new_h <= COLLAPSE_THRESHOLD;
        match drag.kind {
            crate::app::RailSectionKind::Integrations => {
                if collapse {
                    app.integration_section_expanded = false;
                    app.integrations_user_max_h = None;
                } else {
                    app.integration_section_expanded = true;
                    app.integrations_user_max_h = Some(new_h);
                }
            }
            crate::app::RailSectionKind::Git => {
                if collapse {
                    app.git_section_expanded = false;
                    app.git_user_max_h = None;
                } else {
                    app.git_section_expanded = true;
                    app.git_user_max_h = Some(new_h);
                }
            }
        }
        app.rail_section_drag = Some(drag);
        return;
    }
    if app.dragging_scrollbar.is_some() {
        app.drag_scrollbar_to(x, y);
    } else if app.dragging_tree_edge {
        // Hand the full screen width to the clamp logic.
        let screen_w = app
            .rects
            .body
            .map(|r| r.x + r.width)
            .or_else(|| app.rects.statusline.map(|r| r.x + r.width))
            .unwrap_or(120);
        app.drag_tree_edge_to(x, screen_w);
    } else if app.dragging_right_panel_edge {
        // vscode-user-mouse SEV-1 — mirror of dragging_tree_edge.
        // The grip glyph + edge rect were rendered but no drag
        // handler existed, so the panel was decorative.
        // mouse-verify follow-up — body.x + body.width is the
        // body's right edge, which is the PANEL's left edge
        // (not the screen's right edge) when the panel is
        // open; the drag direction worked but not 1:1.
        // Statusline spans full width so it's the reliable
        // screen-right reference.
        let screen_w = app
            .rects
            .statusline
            .map(|r| r.x + r.width)
            .or_else(|| app.rects.body.map(|r| r.x + r.width))
            .unwrap_or(120);
        let new_w = screen_w.saturating_sub(x).clamp(8, 120);
        app.right_panel_width = new_w;
    } else if app.dragging_git_graph_detail.is_some() {
        app.drag_git_graph_detail_to(x);
    } else if let Some((pid, orow, ocol, armed)) = app.drag_select {
        // Editor drag-select: drop the anchor at the click origin
        // (first drag only), then extend the cursor to the current
        // mouse position WITHOUT wiping the anchor on each tick —
        // `place_cursor` would clear it, so we use
        // `extend_cursor_to` here. This fixes the SEV-2 chrome-
        // hunt finding "drag-select moves cursor but doesn't
        // create selection." Vim mode: ditto, plus VISUAL chip
        // turns on because anchor != None ⇒ `has_selection`.
        //
        // The stored tuple is `(pid, row, col, armed)` — the
        // prior variable names `ox`/`oy` were misleading
        // (sounded like screen X/Y but actually carried file
        // row/col), and the place_cursor call below had the
        // args silently swapped. 2026-06-08 post-fix hunt
        // SEV-2: a single-line 10-cell drag produced `Sel 94`
        // instead of `Sel 10` because the anchor landed at
        // (file row=originalCol, col=originalRow).
        let wrap = app.config.ui.wrap;
        if let Some(&(tr, p2)) = app
            .rects
            .editor_panes
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            && p2 == pid
            && let Some(Pane::Editor(b)) = app.panes.get_mut(pid)
        {
            let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
            if !armed {
                b.editor.place_cursor(orow, ocol);
                b.editor.apply(
                    crate::edit_op::EditOp::SelectStart,
                    tr.height as usize,
                    &mut app.clipboard,
                );
                // Vim ⇒ flip to VISUAL so the mode chip + the
                // motion semantics agree the user is selecting.
                // Standard ⇒ no-op (selection is editor-driven,
                // see `InputHandler::request_visual_mode` docs).
                b.input.request_visual_mode();
                app.drag_select = Some((pid, orow, ocol, true));
            }
            b.editor.extend_cursor_to(row, col);
        }
    } else {
        app.drag_divider_to(x, y);
    }
}
