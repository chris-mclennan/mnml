//! Mouse dispatch (T-2 of the file-split refactor — 2026-06-28).
//! The largest single chunk — `dispatch_mouse` is ~3300 lines covering
//! every clickable surface (rail rows, integration chips, palette
//! bar, dock widgets, pane bodies, scrollbars, drag handles, context
//! menus, ...) plus the scroll-coalescing helper and the
//! `SCROLL_BATCH_COUNT` atomic.
//!
//! Extracted from `src/tui/mod.rs`. Re-exported from `tui::mod` so
//! callers (`tui::run_loop`, `headless`, `ipc::drain_commands`,
//! `ui::draw` for synthetic mouse events) keep working unchanged.

use ratatui::crossterm::event::{MouseButton, MouseEvent, MouseEventKind};

use super::{send_macos_player, send_mixr_command};
use crate::app::App;
use crate::pane::Pane;

mod coalesce;
mod down_left;
mod right_click;
// Re-export the coalesce helpers so existing import paths
// (`tui::mouse::coalesce_scroll`, etc.) keep working without
// touching every callsite. T-3 of the file-split refactor —
// 2026-06-29, code-reviewer N-1 follow-through.
pub(crate) use coalesce::{coalesce_scroll, take_coalesce_leftover, take_scroll_batch_count};

// ─── mouse dispatch (shared with headless/IPC) ──────────────────────

pub fn dispatch_mouse(app: &mut App, m: MouseEvent) {
    let (x, y) = (m.column, m.row);

    // Cmdline popup wheel scroll — route ScrollUp/ScrollDown to
    // the popup nav when the cursor is over the popup body. Must
    // be checked BEFORE other handlers since the popup overlays
    // the chrome row and could otherwise leak to the underlying
    // pane wheel handler. Also handles click-to-select on a row.
    if app.cmdline_popup_is_showing() {
        let over_popup = app
            .rects
            .cmdline_popup_items
            .iter()
            .any(|(r, _)| crate::app::dispatch::contains(*r, x, y));
        if over_popup {
            match m.kind {
                MouseEventKind::ScrollUp => {
                    app.cmdline_popup_move(-1);
                    return;
                }
                MouseEventKind::ScrollDown => {
                    app.cmdline_popup_move(1);
                    return;
                }
                MouseEventKind::Down(MouseButton::Left) => {
                    if let Some(&(_, idx)) = app
                        .rects
                        .cmdline_popup_items
                        .iter()
                        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                    {
                        app.cmdline_popup_accept(idx);
                    }
                    return;
                }
                _ => {}
            }
        }
    }

    // NewCloudRunWizard hits — same shape as the other wizard.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some((_, hit)) = app
            .rects
            .new_cloud_run_wizard_hits
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .cloned()
    {
        use crate::ui::new_cloud_run_wizard_view::CloudRunHit;
        match hit {
            CloudRunHit::Option(idx) => {
                let cur = app
                    .active
                    .and_then(|i| match app.panes.get(i) {
                        Some(crate::pane::Pane::NewCloudRunWizard(w)) => Some(w.focus_row),
                        _ => None,
                    })
                    .unwrap_or(0);
                let delta = idx as isize - cur as isize;
                if delta != 0 {
                    app.new_cloud_run_wizard_move(delta);
                }
            }
            CloudRunHit::Back => app.new_cloud_run_wizard_back(),
            CloudRunHit::Next => app.new_cloud_run_wizard_next(),
        }
        return;
    }

    // NewCloudAgentWizard hits: radio rows + Back / Next buttons.
    // Defined before the CloudAgentRun hits below so the wizard's
    // own hit rects always win when both panes are open.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some((_, hit)) = app
            .rects
            .new_cloud_agent_wizard_hits
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .cloned()
    {
        use crate::ui::new_cloud_agent_wizard_view::WizardHit;
        match hit {
            WizardHit::Option(idx) => {
                let cur = app
                    .active
                    .and_then(|i| match app.panes.get(i) {
                        Some(crate::pane::Pane::NewCloudAgentWizard(w)) => Some(w.focus_row),
                        _ => None,
                    })
                    .unwrap_or(0);
                let delta = idx as isize - cur as isize;
                if delta != 0 {
                    app.new_cloud_agent_wizard_move(delta);
                }
            }
            WizardHit::Back => app.new_cloud_agent_wizard_back(),
            WizardHit::Next => app.new_cloud_agent_wizard_next(),
        }
        return;
    }

    // 2026-06-27 — CloudAgentRun pane: click on a URL row opens
    // it in the system browser; click on an artifact row opens
    // the s3 sibling pointed at that key. Hit rects come from
    // `cloud_agent_run_view::draw`.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some((_, pane_id, hit)) = app
            .rects
            .cloud_agent_run_hits
            .iter()
            .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            .cloned()
    {
        // cloud-power-user F1 — set active to the pane that owns the
        // clicked rect so chip clicks mutate the visible pane's
        // state, not whichever pane happened to be active.
        app.active = Some(pane_id);
        use crate::ui::cloud_agent_run_view::CloudAgentRunHit;
        match hit {
            CloudAgentRunHit::Url(u) => {
                crate::app::open_url_external(&u);
                let short: String = u.chars().take(72).collect();
                app.toast(format!("opened {short}"));
            }
            CloudAgentRunHit::Artifact(key) => {
                // S3 key shape: s3://bucket/path/to/file
                // The s3 sibling browses by bucket+prefix; here we
                // open it scoped to the parent prefix of the key so
                // the user lands at the right folder.
                let stripped = key.strip_prefix("s3://").unwrap_or(&key);
                let (bucket, rest) = match stripped.split_once('/') {
                    Some((b, r)) => (b, r),
                    None => (stripped, ""),
                };
                let parent = rest.rsplit_once('/').map(|(p, _)| p).unwrap_or("");
                app.open_s3_pane(bucket, parent, &format!("s3: {}", bucket));
            }
            CloudAgentRunHit::Refresh => {
                app.cloud_agent_run_refresh();
            }
            CloudAgentRunHit::CycleAutoRefresh => {
                app.cloud_agent_run_cycle_auto();
            }
            CloudAgentRunHit::ToggleLogFollow => {
                if let Some(crate::pane::Pane::CloudAgentRun(p)) =
                    app.active.and_then(|i| app.panes.get_mut(i))
                {
                    p.log_follow = !p.log_follow;
                    // render-reviewer #2 + cloud-power-user F6 —
                    // log_scroll==usize::MAX is the follow-tail
                    // sentinel. ENABLE: snap to MAX. DISABLE: pin
                    // to current tail (so new arrivals don't pull
                    // the view despite the title claiming follow
                    // is off).
                    if p.log_follow {
                        p.log_scroll = usize::MAX;
                    } else {
                        p.log_scroll = p.logs.len();
                    }
                }
            }
        }
        return;
    }

    // 2026-06-21 — Spend Report column header click: cycle
    // asc/desc on that column (or set it as the sort key).
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some(&(_, pid, key)) = app
            .rects
            .spend_headers
            .iter()
            .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        if let Some(Pane::SpendReport(p)) = app.panes.get_mut(pid) {
            if p.sort_by == key {
                p.sort_desc = !p.sort_desc;
            } else {
                p.sort_by = key;
                p.sort_desc = true;
            }
        }
        return;
    }

    // 2026-06-21 vscode-mouse SEV-2: Claude Agents topbar chip
    // clicks cycle the corresponding pane state. Was: chips
    // looked like buttons but weren't registered.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some(&(_, pid, kind)) = app
            .rects
            .claude_agents_topbar_chips
            .iter()
            .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        use crate::ui::TopbarChipKind;
        match kind {
            TopbarChipKind::View => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(pid) {
                    p.cycle_detail();
                }
            }
            TopbarChipKind::Sort => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(pid) {
                    p.cycle_sort();
                }
            }
            TopbarChipKind::Group => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(pid) {
                    p.cycle_group_by();
                }
            }
            TopbarChipKind::Source => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(pid) {
                    use crate::claude_agents::AgentSource;
                    p.source_filter = match p.source_filter {
                        None => Some(AgentSource::Claude),
                        Some(AgentSource::Claude) => Some(AgentSource::Codex),
                        Some(AgentSource::Codex) => Some(AgentSource::TattleQwe),
                        Some(AgentSource::TattleQwe) => Some(AgentSource::AnthropicManaged),
                        Some(AgentSource::AnthropicManaged) => None,
                    };
                    p.selected = 0;
                }
            }
            TopbarChipKind::Workspace => {
                app.claude_agents_toggle_workspace_only();
            }
        }
        return;
    }

    // 2026-06-21 vscode-mouse SEV-2: WS pane [Send] button click
    // sends the typed message (parity with Enter chord).
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some(&(_, pid)) = app
            .rects
            .ws_send_buttons
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        if let Some(Pane::Websocket(p)) = app.panes.get_mut(pid) {
            p.send_input();
        }
        return;
    }

    // 2026-06-21 vscode-mouse SEV-2: cheatsheet section header
    // click toggles collapse. Same intent as the `C` chord but
    // reachable via mouse — the chip didn't look clickable
    // before, now it acts on click.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some(group) = app
            .rects
            .cheatsheet_headers
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, g)| g.clone())
    {
        // Find the focused cheatsheet pane id; if none, no-op.
        if let Some(pid) = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Cheatsheet(_)))
        {
            if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(pid) {
                if c.collapsed.contains(&group) {
                    c.collapsed.remove(&group);
                } else {
                    c.collapsed.insert(group);
                }
            }
            app.active = Some(pid);
            app.focus_pane();
            return;
        }
    }

    // 2026-06-21 vscode SEV-2 peek-overlay-mouse-cannot-dismiss —
    // when the peek overlay is showing, intercept all clicks
    // FIRST. Click inside = no-op (don't bleed through to the
    // editor). Click outside = dismiss the overlay. Wheel inside
    // = scroll the overlay's content.
    if let Some(rect) = app.rects.peek_overlay {
        let inside =
            x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
        match m.kind {
            MouseEventKind::Down(_) => {
                if !inside {
                    app.peek_overlay = None;
                }
                // Either way, the editor underneath doesn't see it.
                return;
            }
            MouseEventKind::ScrollUp if inside => {
                if let Some(po) = &mut app.peek_overlay {
                    po.scroll_up();
                }
                return;
            }
            MouseEventKind::ScrollDown if inside => {
                if let Some(po) = &mut app.peek_overlay {
                    po.scroll_down();
                }
                return;
            }
            _ => {}
        }
    }

    // Hover-tooltip tracking — `MouseEventKind::Moved` (no button) updates
    // which clickable chip the mouse is over; the overlay renders after a
    // 500ms stable hover. Compute the chip at (x, y) and stash on `App`.
    // A move OFF every chip clears the hover; click + key events also clear
    // it (handled elsewhere).
    if matches!(m.kind, MouseEventKind::Moved) {
        // 2026-06-28 — hover-highlight on context menu items.
        // The hover-tooltip Moved handler used to return early,
        // which meant the dedicated context-menu hover block at
        // ~line 4762 never ran. Check the menu FIRST and update
        // its selection before falling through to tooltip logic.
        if app.context_menu.is_some()
            && let Some(&(_, i)) = app
                .rects
                .context_menu_items
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            app.context_menu_select(i);
            return;
        }
        // Same for the menu-bar dropdown — hovering an item should
        // move the highlight to that row. Without this, the cyan
        // row only ever follows arrow-key navigation.
        if app.menu_open.is_some()
            && let Some(&(_, item_idx)) = app
                .rects
                .menu_bar_items
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            && let Some(s) = app.menu_open.as_mut()
        {
            s.item_idx = item_idx;
            return;
        }
        let now = std::time::Instant::now();
        // 2026-06-22 — some terminals report Moved (no button)
        // even while a button is held during a drag. If
        // `tree_drag` is Some, the user is mid-drag (mouse-down
        // happened, mouse-up hasn't fired yet), so treat Moved
        // as a drag-tracking event too. Without this, the ghost
        // + drop overlay stay invisible because the cursor
        // never updates between Down and Up.
        if app.tree_drag.is_some() {
            app.set_tree_drag_cursor(x, y);
            let src_is_file = app
                .tree_drag
                .as_ref()
                .map(|d| !d.src_is_dir)
                .unwrap_or(false);
            let over_tree = app
                .rects
                .tree
                .map(|tr| crate::app::dispatch::contains(tr, x, y))
                .unwrap_or(false);
            if !over_tree && src_is_file {
                app.update_tab_drop_target(x, y);
            } else if !over_tree {
                app.rects.tab_drop_target = None;
            }
        }
        // Bufferline-tab drag fallback — same shape as the tree_drag
        // path above. Without this the ghost / drop overlay never
        // updates on terminals that emit Moved (no button) instead
        // of Drag(Left) while the button is held during a tab drag.
        if app.rects.bufferline_drag_tab.is_some() {
            app.rects.bufferline_drag_ghost = Some((x, y));
            app.update_tab_drop_target(x, y);
            app.update_tab_insert_hint(x, y);
        }
        let new_chip = crate::app::dispatch::hover_chip_at(app, x, y);
        let prev_chip = app.hover_chip.map(|(c, _)| c);
        if new_chip != prev_chip {
            app.hover_chip = new_chip.map(|c| (c, now));
        }
        // 2026-06-19 polish — cmdline popup row hover highlights
        // without requiring a click. Move into the row → that
        // row becomes the selected highlight. Move OFF the popup
        // → highlight stays on last hovered row (clicked behavior).
        if let Some(&(_, idx)) = app
            .rects
            .cmdline_popup_items
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            app.cmdline_popup_selected = idx;
        }
        // Track divider hover for the yellow drag-cue. Updated in lockstep
        // with chip hover; both are cleared on click / typing.
        let new_div = app.rects.split_dividers.iter().position(|d| {
            x >= d.rect.x
                && x < d.rect.x + d.rect.width
                && y >= d.rect.y
                && y < d.rect.y + d.rect.height
        });
        if new_div != app.hover_divider_idx {
            app.hover_divider_idx = new_div;
        }
        // Editor body hover → schedule an LSP hover request after a
        // debounce. The actual fire happens in `tick`; we just record
        // (pane, file_row, file_col, when) here. Moving to a new cell
        // resets the timer and clears the "already fired" marker so
        // a fresh request can go out. SEV-2 VS-Code-mouse hunt fix
        // 2026-06-08 ("Hover over editor text doesn't show LSP info").
        let body_target = app
            .rects
            .editor_panes
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|&(tr, pid)| {
                let wrap = app.config.ui.wrap;
                let (row, col) = if let Some(Pane::Editor(b)) = app.panes.get(pid) {
                    crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y)
                } else {
                    (0, 0)
                };
                (pid, row, col)
            });
        let cur_target = app.mouse_hover_at.map(|(p, r, c, _)| (p, r, c));
        if body_target != cur_target {
            app.mouse_hover_at = body_target.map(|(p, r, c)| (p, r, c, now));
            app.mouse_hover_fired = None;
            // Pointer moved off (or to a new cell) → close any popup
            // we put up. Avoids the popup hanging when the mouse has
            // already moved past the symbol.
            if body_target.is_none() {
                app.hover = None;
            }
        }
        return;
    }

    // Welcome overlay — any left-click dismisses + persists the marker.
    if app.show_welcome && matches!(m.kind, MouseEventKind::Down(MouseButton::Left)) {
        app.dismiss_welcome();
        return;
    }
    // About overlay — any left-click dismisses (no marker; pure in-memory).
    if app.show_about && matches!(m.kind, MouseEventKind::Down(MouseButton::Left)) {
        app.show_about = false;
        return;
    }
    // Settings overlay — wheel scrolls the focused row; left-click
    // on a row focuses it (then `←/→` to adjust the value); left-
    // click outside the panel saves + closes (matches Enter). Other
    // events swallowed so a stray click on the editor underneath
    // doesn't bleed through. 2026-06-07 SEV-2 VS-Code-mouse hunt fix
    // ("Settings overlay accepts no mouse input — swallows clicks").
    // Help overlay — section header click toggles collapse; wheel
    // scrolls. Same modal-overlay shape as Settings.
    if app.help_overlay.is_some() {
        match m.kind {
            MouseEventKind::ScrollUp => app.help_scroll(-1),
            MouseEventKind::ScrollDown => app.help_scroll(1),
            MouseEventKind::Down(MouseButton::Left) => {
                let header_hit = app
                    .rects
                    .help_section_headers
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                    .map(|(_, name)| name.clone());
                if let Some(name) = header_hit {
                    app.toggle_help_section(&name);
                }
            }
            _ => {}
        }
        return;
    }
    if app.settings_overlay.is_some() {
        match m.kind {
            MouseEventKind::ScrollUp => app.settings_move_row(-1),
            MouseEventKind::ScrollDown => app.settings_move_row(1),
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(&(_, rc_idx)) = app
                    .rects
                    .settings_rows
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                {
                    // Move focus to the clicked row. Use absolute
                    // delta from current to target since
                    // settings_move_row takes a relative step.
                    let cur = app
                        .settings_overlay
                        .as_ref()
                        .map(|s| s.selected_row)
                        .unwrap_or(0);
                    let delta = rc_idx as isize - cur as isize;
                    if delta == 0 {
                        // Already focused — click cycles the value
                        // forward (vscode-mouse SEV-2 2026-06-10:
                        // "row title click moves the focus arrow;
                        // clicking value glyphs themselves does
                        // nothing. Only ← / → keys mutate"). Per-chip
                        // hit-rects would be ideal, but click-to-
                        // advance is the small interaction win that
                        // makes the overlay feel responsive without
                        // a renderer rework.
                        app.settings_enter_row();
                    } else {
                        app.settings_move_row(delta);
                    }
                } else if let Some(area) = app.rects.settings_overlay_rect
                    && !crate::app::dispatch::contains(area, x, y)
                {
                    // Click outside the panel — save + close (matches
                    // Enter / VS Code's modal click-out semantic).
                    app.close_settings_overlay_save();
                }
            }
            _ => {}
        }
        return;
    }
    // "+ Add integration" overlay — scroll wheel moves the row cursor.
    // Left-click on a sibling row focuses + Enters that row (matches
    // the keyboard `↑↓ Enter` flow). Left-click outside any row
    // dismisses the overlay — preserves the no-mouse-trap semantic
    // from the 2026-06-07 fix without the row-swallow regression the
    // 2026-06-08 vscode-mouse hunt caught.
    if app.discovery_overlay.is_some() {
        match m.kind {
            MouseEventKind::ScrollUp => app.discovery_move_row(-1),
            MouseEventKind::ScrollDown => app.discovery_move_row(1),
            MouseEventKind::Down(MouseButton::Left) => {
                // Tab chip click first — flips Installed ↔ Marketplace.
                let chip_hit = app
                    .rects
                    .discovery_tab_chips
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                    .map(|(_, tab)| *tab);
                if let Some(tab) = chip_hit {
                    if let Some(o) = app.discovery_overlay.as_mut()
                        && o.tab != tab
                    {
                        o.tab = tab;
                        o.selected_row = 0;
                    }
                    return;
                }
                let row_hit = app
                    .rects
                    .discovery_integration_rows
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                    .map(|(_, idx)| *idx);
                if let Some(idx) = row_hit {
                    let cur = app
                        .discovery_overlay
                        .as_ref()
                        .map(|s| s.selected_row)
                        .unwrap_or(0);
                    let delta = idx as isize - cur as isize;
                    if delta != 0 {
                        app.discovery_move_row(delta);
                    }
                    app.discovery_enter();
                } else if let Some(area) = app.rects.discovery_overlay_rect
                    && !crate::app::dispatch::contains(area, x, y)
                {
                    // Only OUTSIDE-rect clicks dismiss. Clicks inside
                    // the overlay that miss a sibling row (e.g., on a
                    // section header or the hint footer) are no-ops —
                    // the user is still interacting with the overlay.
                    // 2026-06-13 vscode-mouse SEV-2 fix.
                    app.discovery_overlay = None;
                    app.rects.discovery_overlay_rect = None;
                }
            }
            _ => {}
        }
        return;
    }
    // Discovery overlay — intercept clicks on its rows so the user can
    // flash the matching on-screen rects. A click outside the panel
    // closes the overlay (so it can't trap the user).
    if app.show_discovery_overlay && matches!(m.kind, MouseEventKind::Down(MouseButton::Left)) {
        if let Some(&(_, cat)) = app
            .rects
            .discovery_rows
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            app.discovery_flash = Some((cat, std::time::Instant::now()));
            return;
        }
        // Click outside any row → dismiss the overlay.
        app.show_discovery_overlay = false;
        return;
    }
    // Scratch terminal — left-click on the strip focuses it; click off
    // the strip blurs (so the next keystroke goes to the editor again).
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some(strip) = app.rects.scratch_term_strip
    {
        if crate::app::dispatch::contains(strip, x, y) {
            if let Some(s) = app.scratch_term.as_mut() {
                s.focused = true;
            }
            return;
        }
        app.blur_scratch_term();
    }
    // A click anywhere dismisses the hover / signature popups (the click
    // still lands). Completion popup clicks are handled specially: a click
    // ON a row selects + accepts; a click anywhere else dismisses.
    if matches!(m.kind, MouseEventKind::Down(_)) {
        app.hover = None;
        app.signature = None;
        app.hover_chip = None;
        if app.completion.is_some() {
            if let MouseEventKind::Down(MouseButton::Left) = m.kind {
                let hit = app
                    .rects
                    .completion_rows
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                    .map(|(_, fi)| *fi);
                if let Some(fi) = hit {
                    if let Some(p) = app.completion.as_mut() {
                        p.set_selected(fi);
                    }
                    app.completion_accept();
                    return;
                }
            }
            app.completion = None;
        }
    }

    // While the picker is open it owns the mouse.
    if app.picker.is_some() {
        match m.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(&(_, fi)) = app
                    .rects
                    .picker_items
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                {
                    if let Some(p) = app.picker.as_mut() {
                        p.set_selected(fi);
                    }
                    app.picker_accept();
                } else if app
                    .rects
                    .picker_box
                    .map(|r| !crate::app::dispatch::contains(r, x, y))
                    .unwrap_or(true)
                {
                    app.close_picker(); // click outside dismisses
                }
            }
            MouseEventKind::ScrollUp => {
                if let Some(p) = app.picker.as_mut() {
                    p.move_up();
                }
            }
            MouseEventKind::ScrollDown => {
                if let Some(p) = app.picker.as_mut() {
                    p.move_down();
                }
            }
            _ => {}
        }
        return;
    }

    // The text-input prompt is modal — swallow mouse events while it's open.
    if app.prompt.is_some() {
        return;
    }

    // The "unsaved changes" overlay is modal too — only its buttons respond.
    if app.close_prompt.is_some() {
        if let MouseEventKind::Down(MouseButton::Left) = m.kind
            && let Some(&(_, choice)) = app
                .rects
                .close_prompt_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            app.close_prompt_resolve(choice);
        }
        return;
    }

    // The context menu is modal: a left-click on a row runs it; anywhere else
    // (or a right-click) dismisses. Mouse-move over a row highlights it
    // (matches macOS / VS Code menu hover).
    if app.context_menu.is_some() {
        if matches!(m.kind, MouseEventKind::Moved)
            && let Some(&(_, i)) = app
                .rects
                .context_menu_items
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            app.context_menu_select(i);
            return;
        }
        match m.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(&(_, i)) = app
                    .rects
                    .context_menu_items
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                {
                    app.context_menu_select(i);
                    app.context_menu_accept();
                } else {
                    app.context_menu_cancel();
                }
                return;
            }
            MouseEventKind::Down(MouseButton::Right) => {
                // Right-click while a context menu is OPEN. Cancel the
                // existing menu, then fall through to the normal right-
                // click dispatch so a fresh menu opens at the new
                // position. Prior behavior was "cancel + return" — the
                // user had to right-click twice to retarget the menu.
                // vscode-mouse-2026-06-10 SEV-2 #6 — "right-click on
                // bufferline tab sometimes fails to open the context
                // menu" was THIS, when an earlier context menu was
                // still open from a prior right-click.
                app.context_menu_cancel();
                // Fall through; no return.
            }
            _ => return,
        }
    }

    // Middle-click on a bufferline tab closes it (browser-tab pattern). Match
    // this before the per-button branch so it's a one-liner regardless of what
    // else the catch-all might do.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle))
        && let Some(&(_, id)) = app
            .rects
            .bufferline_tabs
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.close_pane(id);
        return;
    }

    // Dashboard (splash) recent-file click — only fires when Layout::Empty so
    // we don't shadow editor clicks. Routes through `open_path`, which sets
    // up the editor pane + LSP + tree state.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && matches!(app.layout(), crate::layout::Layout::Empty)
    {
        let target = app
            .rects
            .dashboard_rows
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, p)| p.clone());
        if let Some(path) = target {
            app.open_path(&path);
            return;
        }
    }

    // Middle-click in an editor pane pastes the clipboard at the clicked
    // position (X11 / GTK convention — "primary selection" paste). Helps
    // for terminal users coming from xterm. The press also focuses the
    // leaf + places the cursor first.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle))
        && let Some(&(tr, pid)) = app
            .rects
            .editor_panes
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        let wrap = app.config.ui.wrap;
        let vp = tr.height as usize;
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
            b.editor.place_cursor(row, col);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::PasteAfter],
                &mut app.clipboard,
                vp,
            );
        }
        return;
    }

    match m.kind {
        MouseEventKind::Down(MouseButton::Right) => {
            // T-4 file-split — extracted ~447-line block to
            // mouse/right_click.rs (code-reviewer N-1 follow-through).
            right_click::handle_right_click(app, x, y);
        }
        MouseEventKind::Down(MouseButton::Left) => {
            // T-5 file-split — extracted ~1700-line block to
            // mouse/down_left.rs (code-reviewer N-1 follow-through).
            down_left::handle_down_left(app, m, x, y);
        }
        MouseEventKind::Drag(MouseButton::Left) => {
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
        MouseEventKind::Up(MouseButton::Left) => {
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
                        if let Some(src_idx) = app.dock_widgets.iter().position(|w| w.id == drag_id)
                        {
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
        // Wheel sends one event per terminal-emitted tick (macOS Terminal /
        // Ghostty / iTerm2 fire several ticks per real wheel notch under
        // smooth-scrolling). Pass ±1 so tree / list / sidebar surfaces
        // scroll at the natural rate; the editor / md-preview / diff
        // arms in `scroll_under` amplify internally.
        MouseEventKind::ScrollUp => {
            let n = take_scroll_batch_count() as i32;
            crate::app::dispatch::scroll_under(app, x, y, -n);
        }
        MouseEventKind::ScrollDown => {
            let n = take_scroll_batch_count() as i32;
            crate::app::dispatch::scroll_under(app, x, y, n);
        }
        _ => {}
    }
}
