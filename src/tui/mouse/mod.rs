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
use ratatui::layout::Rect;

use super::{send_macos_player, send_mixr_command};
use crate::app::App;
use crate::pane::Pane;
use crate::pty_pane::{PtySession, sgr_mouse_button_code, sgr_mouse_mod_bits};

/// Encode `event` as an SGR mouse report (CSI `<` … M/m) and
/// write it to `session`'s pty. `pane_rect` is the on-screen
/// rectangle occupied by the pane so we can translate absolute
/// terminal coordinates to 1-based pane-local cell coordinates.
fn forward_mouse_to_pty(session: &mut PtySession, pane_rect: Rect, event: MouseEvent) {
    // Reject events outside the rect (shouldn't happen if the
    // caller found it via `dispatch::contains`, but guards
    // against off-by-one bugs).
    if event.column < pane_rect.x || event.row < pane_rect.y {
        return;
    }
    let col = (event.column - pane_rect.x) + 1;
    let row = (event.row - pane_rect.y) + 1;
    let mods = sgr_mouse_mod_bits(event.modifiers);
    // Map crossterm's kind → SGR button code + press-vs-release.
    // Move (drag) events emit the same button code as Down but
    // with bit 5 set (+32) — a "motion" flag.
    let (button_code, pressed) = match event.kind {
        MouseEventKind::Down(btn) => (sgr_mouse_button_code(btn) + mods, true),
        MouseEventKind::Up(btn) => (sgr_mouse_button_code(btn) + mods, false),
        MouseEventKind::Drag(btn) => (sgr_mouse_button_code(btn) + 32 + mods, true),
        MouseEventKind::ScrollUp => (64 + mods, true),
        MouseEventKind::ScrollDown => (65 + mods, true),
        // ScrollLeft / ScrollRight aren't standard in SGR; skip.
        _ => return,
    };
    session.write_sgr_mouse_report(button_code, col, row, pressed);
}

mod coalesce;
mod down_left;
mod drag_left;
mod right_click;
mod up_left;
// Re-export the coalesce helpers so existing import paths
// (`tui::mouse::coalesce_scroll`, etc.) keep working without
// touching every callsite. T-3 of the file-split refactor —
// 2026-06-29, code-reviewer N-1 follow-through.
pub(crate) use coalesce::{coalesce_scroll, take_coalesce_leftover, take_scroll_batch_count};

// ─── mouse dispatch (shared with headless/IPC) ──────────────────────

pub fn dispatch_mouse(app: &mut App, m: MouseEvent) {
    let (x, y) = (m.column, m.row);

    // LSP hover popup takes precedence when the pointer is over
    // it: wheel scrolls the content, Moved is a no-op (so hover
    // doesn't dismiss just because the pointer walked onto the
    // popup itself). Click still dismisses via the generic
    // Down(_) handler below. 2026-07-12 user report — couldn't
    // scroll a tall hover.
    if let Some(rect) = app.rects.hover_popup_rect
        && crate::app::dispatch::contains(rect, x, y)
    {
        match m.kind {
            MouseEventKind::ScrollUp => {
                if let Some(h) = app.hover.as_mut() {
                    h.scroll_by(-2);
                }
                return;
            }
            MouseEventKind::ScrollDown => {
                if let Some(h) = app.hover.as_mut() {
                    h.scroll_by(2);
                }
                return;
            }
            MouseEventKind::Moved => return,
            _ => {}
        }
    }

    // 2026-07-03 — mouse-forwarding to Pty children. When the
    // child inside a Pty pane has enabled terminal-mouse
    // tracking (any of X10 / normal / button / any-event), the
    // event should reach it via an SGR mouse report instead of
    // being intercepted by mnml's own handlers (dock menu,
    // focus, scrollback). This unblocks click / right-click /
    // wheel inside every mouse-aware sibling (mnml-aws-amplify
    // and friends).
    // Left-click on a Pty pane WITHOUT mouse-tracking → arm a
    // drag-select. Origin cell captured in pane-relative coords
    // (col, row). The drag handler updates the current cell; mouse-up
    // extracts the text between origin/current and copies it to the
    // clipboard. mouse-round-9 SEV-2 2026-07-11.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
        && let Some(&(rect, pid)) = app.rects.editor_panes.iter().find(|(r, pid)| {
            crate::app::dispatch::contains(*r, x, y)
                && matches!(app.panes.get(*pid), Some(Pane::Pty(_)))
        })
        && let Some(Pane::Pty(session)) = app.panes.get(pid)
        && !session.is_mouse_tracking()
    {
        let col = x.saturating_sub(rect.x);
        let row = y.saturating_sub(rect.y);
        app.pty_drag_select = Some((pid, (col, row), (col, row)));
        // Don't return — let the click also focus the pane below.
    }
    // Middle-click on a Pty pane → paste from clipboard (X11 primary-
    // selection convention). Runs even when the child has mouse
    // tracking; the paste is the natural user intent. mouse-round-9
    // SEV-2 2026-07-11.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle))
        && let Some(&(_, pid)) = app.rects.editor_panes.iter().find(|(r, pid)| {
            crate::app::dispatch::contains(*r, x, y)
                && matches!(app.panes.get(*pid), Some(Pane::Pty(_)))
        })
    {
        app.active = Some(pid);
        app.focus_pane();
        app.pty_paste_clipboard();
        return;
    }
    if let Some(&(rect, pid)) = app.rects.editor_panes.iter().find(|(r, pid)| {
        crate::app::dispatch::contains(*r, x, y)
            && matches!(app.panes.get(*pid), Some(Pane::Pty(_)))
    }) && let Some(Pane::Pty(session)) = app.panes.get_mut(pid)
        && session.is_mouse_tracking()
    {
        forward_mouse_to_pty(session, rect, m);
        return;
    }

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
                    // Skip dead Ecs / AnthropicManaged stops — dashboard's
                    // rows are Claude+Codex only. See handlers/pane.rs.
                    // claude-agents SEV-2 2026-07-10.
                    p.source_filter = match p.source_filter {
                        None => Some(AgentSource::Claude),
                        Some(AgentSource::Claude) => Some(AgentSource::Codex),
                        Some(AgentSource::Codex) => None,
                        Some(AgentSource::Ecs) | Some(AgentSource::AnthropicManaged) => None,
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
        // mouse-round-12 SEV-2 F1 2026-07-14 — track raw pointer so
        // hover-only affordances (workspace-header action chips)
        // can gate their hit-rect registration on "mouse actually
        // over this row" without going through the tooltip debounce.
        app.mouse_pos = Some((x, y));
        // mouse-round-16 SEV-2 F1 2026-07-16 — clear the "just
        // closed a tab here" guard as soon as the pointer moves
        // to a different cell. See the guard site in down_left.rs
        // (`last_tab_close_at`).
        if app
            .last_tab_close_at
            .is_some_and(|(cx, cy)| cx != x || cy != y)
        {
            app.last_tab_close_at = None;
        }
        // 2026-07-12 — track which bufferline tab the mouse is over
        // so the renderer paints its close `×` glyph on hover (not
        // just when active). Rebuilt every Moved event so leaving
        // the strip clears it.
        app.hovered_bufferline_tab = app
            .rects
            .bufferline_tabs
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|&(_, pid)| pid);
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
        // Menu-bar hover-switch (mouse-round-10 SEV-2 → round-8
        // SEV-2). When a menu is open and the cursor hovers a
        // DIFFERENT top-level menu title, switch to that menu
        // without requiring a click. macOS / GTK / VS Code all do
        // this so keyboard-free menu-bar navigation works. Preserve
        // `keyboard_opened` so the highlight-on-open state matches
        // how the current menu was summoned.
        if app.menu_open.is_some()
            && let Some(&(_, hovered_idx)) = app
                .rects
                .menu_bar_words
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            let current = app.menu_open.as_ref().map(|s| s.menu_idx);
            if current != Some(hovered_idx) {
                let keyboard = app.menu_open.as_ref().is_some_and(|s| s.keyboard_opened);
                app.menu_open = Some(if keyboard {
                    crate::menu_bar::MenuOpenState::new_keyboard(hovered_idx)
                } else {
                    crate::menu_bar::MenuOpenState::new_mouse(hovered_idx)
                });
            }
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
        // VS Code-style fold-arrow tracking. When the mouse is over
        // an editor pane's body OR gutter, compute the file line
        // under the cursor and stash it so the next render can paint
        // a `↓` in the sign column for foldable lines on THAT line.
        // Clears otherwise so leaving the pane hides the arrows.
        // 2026-07-11.
        {
            let mut hit: Option<(crate::layout::PaneId, usize)> = None;
            let hit_body = app
                .rects
                .editor_panes
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .map(|&(r, pid)| (r, pid));
            let hit_gutter = app
                .rects
                .editor_gutters
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .map(|&(r, pid)| (r, pid));
            if let Some((tr, pid)) = hit_body.or(hit_gutter)
                && let Some(crate::pane::Pane::Editor(b)) = app.panes.get(pid)
            {
                let wrap = app.config.ui.wrap;
                let (row, _) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
                hit = Some((pid, row));
            }
            if app.hover_editor_line != hit {
                app.hover_editor_line = hit;
            }
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
        // Request-pane row hover — sync `hover_*` fields on the
        // active Request pane so the renderer can highlight the
        // row under the cursor (Params / Vars / Auth). Two passes:
        // first UNCONDITIONALLY clear every Request pane in
        // `app.panes` so a split with a Request pane that just
        // lost focus doesn't retain a phantom highlight (reviewer
        // catch — the guard on `app.active` alone would leave
        // stale state on inactive Request panes). Then set the
        // hovered keys on the active pane if it's a Request.
        // (#11 v13)
        {
            for pane in app.panes.iter_mut() {
                if let crate::pane::Pane::Request(rp) = pane {
                    rp.hover_params_key = None;
                    rp.hover_vars_key = None;
                    rp.hover_auth_id = None;
                }
            }
            let hp = app
                .rects
                .request_params_rows
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
                .map(|(_, k, _)| k.clone());
            let hv = app
                .rects
                .request_vars_rows
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
                .map(|(_, k, _)| k.clone());
            let ha = app
                .rects
                .request_auth_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .map(|(_, k)| k.clone());
            if let Some(cur) = app.active
                && let Some(crate::pane::Pane::Request(rp)) = app.panes.get_mut(cur)
            {
                rp.hover_params_key = hp;
                rp.hover_vars_key = hv;
                rp.hover_auth_id = ha;
            }
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
        // Track tree- / right-panel-edge hover so the renderer can
        // paint the border in an accent color instead of showing a
        // persistent grip glyph. 2026-07-08 user feedback.
        let new_tree_edge = app
            .rects
            .tree_edge
            .is_some_and(|r| crate::app::dispatch::contains(r, x, y));
        if new_tree_edge != app.hover_tree_edge {
            app.hover_tree_edge = new_tree_edge;
        }
        let new_right_edge = app
            .rects
            .right_panel_edge
            .is_some_and(|r| crate::app::dispatch::contains(r, x, y));
        if new_right_edge != app.hover_right_panel_edge {
            app.hover_right_panel_edge = new_right_edge;
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

    // Integration_edit modal overlay — vscode-user-mouse round 2
    // (2026-07-11) found clicks were leaking to the tree/pane under
    // it. Route field-row clicks to focus that field; swallow all
    // other mouse events inside the overlay footprint. Outside-panel
    // click cancels the edit (same "click-out = dismiss" idiom
    // Settings uses).
    if let Some(area) = app.rects.integration_edit_overlay_rect {
        match m.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(&(_, field)) = app
                    .rects
                    .integration_edit_field_rows
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                {
                    if let Some(panel) = app.integration_edit.as_mut() {
                        panel.focused_field = field;
                        // Clamp new field's cursor to its byte length.
                        use crate::app::discovery::IntegrationEditField as F;
                        match field {
                            F::Id => panel.id_cursor = panel.id_cursor.min(panel.id.len()),
                            F::Command => {
                                panel.command_cursor = panel.command_cursor.min(panel.command.len())
                            }
                            F::Glyph => {
                                panel.glyph_cursor = panel.glyph_cursor.min(panel.glyph.len())
                            }
                            F::Fallback => {
                                panel.fallback_cursor =
                                    panel.fallback_cursor.min(panel.fallback.len())
                            }
                            F::Tooltip => {
                                panel.tooltip_cursor = panel.tooltip_cursor.min(panel.tooltip.len())
                            }
                            F::Color => {}
                        }
                    }
                } else if !crate::app::dispatch::contains(area, x, y) {
                    // Click outside the panel — cancel.
                    app.integration_edit_cancel();
                }
                // Any click while the overlay is up is swallowed here.
                return;
            }
            _ => {
                // Non-left mouse events (scroll, right-click, middle,
                // moved) are swallowed too — don't leak.
                return;
            }
        }
    }
    // Glyph_builder modal overlay — same click-guard idiom.
    if let Some(area) = app.rects.glyph_builder_overlay_rect {
        match m.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(&(_, field)) = app
                    .rects
                    .glyph_builder_field_rows
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                {
                    if let Some(state) = app.glyph_builder.as_mut() {
                        state.focused_field = field;
                        use crate::glyph_builder::BuilderField as F;
                        match field {
                            F::Path => {
                                state.svg_path_cursor =
                                    state.svg_path_cursor.min(state.svg_path.len())
                            }
                            F::Name => state.name_cursor = state.name_cursor.min(state.name.len()),
                            F::Codepoint => {
                                state.codepoint_hex_cursor =
                                    state.codepoint_hex_cursor.min(state.codepoint_hex.len())
                            }
                            _ => {}
                        }
                    }
                } else if !crate::app::dispatch::contains(area, x, y) {
                    app.close_glyph_builder();
                }
                return;
            }
            _ => return,
        }
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
                // qa-6th mouse SEV-3 2026-06-29: Save / Cancel chips
                // at the bottom. Check before row clicks so the
                // user doesn't accidentally re-focus the bottom row.
                if let Some(rect) = app.rects.settings_save_button
                    && crate::app::dispatch::contains(rect, x, y)
                {
                    app.close_settings_overlay_save();
                    return;
                }
                if let Some(rect) = app.rects.settings_cancel_button
                    && crate::app::dispatch::contains(rect, x, y)
                {
                    app.close_settings_overlay_cancel();
                    return;
                }
                // mouse-round-12 SEV-2 F3 2026-07-14 — click on the
                // `/ filter` row focuses the filter so a mouse-first
                // user can type to narrow the list. Was: only `/`
                // on the keyboard did this; letters typed after a
                // row-click routed to the row keyboard handler and
                // cycled the row's value.
                if let Some(rect) = app.rects.settings_filter_row
                    && crate::app::dispatch::contains(rect, x, y)
                {
                    app.settings_filter_focus();
                    return;
                }
                // vscode-user-mouse SEV-2 2026-07-10: per-option
                // sub-rect wins over the row-level rect so a click on
                // a specific value (e.g. `relative` in Line numbers)
                // jumps to it instead of cycling forward. Also moves
                // focus to that row as a side-effect.
                if let Some(&(_, rc_idx, opt_idx)) = app
                    .rects
                    .settings_row_options
                    .iter()
                    .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
                {
                    let cur = app
                        .settings_overlay
                        .as_ref()
                        .map(|s| s.selected_row)
                        .unwrap_or(0);
                    let delta = rc_idx as isize - cur as isize;
                    if delta != 0 {
                        app.settings_move_row(delta);
                    }
                    app.settings_set_row_option(rc_idx, opt_idx);
                    return;
                }
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
                        // Already focused, click was NOT on a specific
                        // option value (handled above). Cycle the value
                        // forward as a fallback (vscode-mouse SEV-2
                        // 2026-06-10: "row title click moves the focus
                        // arrow; clicking value glyphs themselves does
                        // nothing"). Per-chip
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
    // F1 discovery overlay — intercept clicks on its rows so the user can
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

    // Quit-confirm overlay: only its buttons respond to clicks. This
    // runs BEFORE the generic-prompt swallow below because QuitConfirm
    // uses the Prompt state machine but wants button click routing.
    if app
        .prompt
        .as_ref()
        .is_some_and(|p| matches!(p.kind, crate::prompt::PromptKind::QuitConfirm))
    {
        if let MouseEventKind::Down(MouseButton::Left) = m.kind
            && let Some(&(_, code)) = app
                .rects
                .quit_prompt_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            use crate::ui::prompt::{
                QUIT_BTN_CANCEL, QUIT_BTN_QUIT_ANYWAY, QUIT_BTN_QUIT_CLEAN, QUIT_BTN_SAVE_ALL,
            };
            app.prompt = None;
            match code {
                QUIT_BTN_SAVE_ALL => {
                    app.save_all();
                    app.should_quit = true;
                }
                QUIT_BTN_QUIT_ANYWAY | QUIT_BTN_QUIT_CLEAN => app.should_quit = true,
                QUIT_BTN_CANCEL => {}
                _ => {}
            }
        }
        return;
    }

    // #polish 2026-07-06 — delete-confirm overlay: only its buttons
    // respond. Same shape as QuitConfirm above.
    if app
        .prompt
        .as_ref()
        .is_some_and(|p| matches!(p.kind, crate::prompt::PromptKind::DeleteConfirm))
    {
        if let MouseEventKind::Down(MouseButton::Left) = m.kind
            && let Some(&(_, code)) = app
                .rects
                .confirm_dialog_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            app.prompt = None;
            app.run_delete_button(code);
        }
        return;
    }
    // #polish 2026-07-06 — every other destructive confirm dialog
    // (git delete branch / stash drop / worktree remove / tag
    // delete / hunk discard / claude kill / merge / rebase). Same
    // click-target vec as DeleteConfirm.
    if app
        .prompt
        .as_ref()
        .is_some_and(|p| crate::ui::prompt::confirm_labels(&p.kind).is_some())
    {
        if let MouseEventKind::Down(MouseButton::Left) = m.kind
            && let Some(&(_, code)) = app
                .rects
                .confirm_dialog_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            // code == CONFIRM_BTN_PRIMARY (0) = primary; anything else = cancel.
            let primary = code == crate::ui::prompt::CONFIRM_BTN_PRIMARY;
            app.run_confirm_button(primary);
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
        // qa-7th code-review N-1 2026-06-30 — was a `Moved` guard
        // here that was unreachable (all Moved events returned
        // earlier in dispatch_mouse at the top-level Moved block).
        // Removed; Moved-over-menu hover lives in that earlier
        // block now.
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
    // Middle-click on a tree row closes the file if it's currently
    // open (VS Code convention: middle-click on file explorer entry
    // closes the tab). No-op if the file isn't open. mouse-round-9
    // SEV-2 2026-07-11.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle))
        && let Some(tr) = app.rects.tree
        && crate::app::dispatch::contains(tr, x, y)
    {
        let idx = (y - tr.y) as usize + app.rects.tree_scroll;
        let target_path = app.tree.visible_rows().get(idx).and_then(|row| {
            if row.is_dir {
                None
            } else {
                Some(row.path.clone())
            }
        });
        if let Some(path) = target_path {
            let pane_id = app.panes.iter().position(|p| match p {
                crate::pane::Pane::Editor(b) => b.path.as_deref() == Some(path.as_path()),
                _ => false,
            });
            if let Some(pid) = pane_id {
                app.close_pane(pid);
                return;
            }
        }
        return;
    }
    // vscode-user-mouse SEV-2 2026-07-10: after a split, per-leaf
    // tabs live in `split_tab_chips` (not `bufferline_tabs`), so
    // middle-click on a split-pane tab did nothing. Same close
    // semantics as the top-level bufferline tab. `split_tab_chips`
    // stores (_, leaf_active_pane, tab_pane) — close the tab_pane.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle))
        && let Some(&(_, _, tab_pane)) = app
            .rects
            .split_tab_chips
            .iter()
            .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.close_pane(tab_pane);
        return;
    }

    // #polish 2026-07-06 — middle-click on a tab-page chip
    // closes that tab page (parity with tab middle-click).
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle))
        && let Some(&(_, idx)) = app
            .rects
            .bufferline_tab_page_chips
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.tab_close_at(idx);
        return;
    }
    // #polish 2026-07-06 — middle-click on a right-panel tab
    // closes it (parity with bufferline). Looks up the pane id
    // for the specific tab index the click hit; falls back
    // silently when the panel state has shifted mid-frame.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle))
        && let Some(&(_, tab_idx)) = app
            .rects
            .right_panel_tabs
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(&pid) = app.right_panel_panes.get(tab_idx) {
            app.close_pane(pid);
        }
        return;
    }

    // #21 — middle-click on file-ish rows opens the file in a new
    // split (VS Code Cmd+click convention). Applies uniformly to
    // every list of paths across the app so users don't have to
    // remember which surface supports it.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle)) {
        // Tree files. Tree uses a single scrollable rect
        // (`tree_toggle` covers the body) + `tree_scroll` offset.
        if let Some(tr) = app.rects.tree_toggle
            && crate::app::dispatch::contains(tr, x, y)
        {
            let idx = (y - tr.y) as usize + app.rects.tree_scroll;
            let rows = app.tree.visible_rows();
            if let Some(row) = rows.get(idx)
                && !row.is_dir
            {
                let path = row.path.clone();
                app.split_active(crate::layout::SplitDir::Horizontal);
                app.open_path(&path);
            }
            return;
        }
        // HTTP sidebar file rows.
        if let Some(path) = app
            .rects
            .http_panel_files
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, p)| p.clone())
        {
            app.split_active(crate::layout::SplitDir::Horizontal);
            app.open_path(&path);
            return;
        }
        // HTTP chain rows — middle-click opens the file (Left click runs).
        if let Some(path) = app
            .rects
            .http_panel_chain_rows
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, p)| p.clone())
        {
            app.split_active(crate::layout::SplitDir::Horizontal);
            app.open_path(&path);
            return;
        }
        // HTTP mock rows — same treatment.
        if let Some(path) = app
            .rects
            .http_panel_mock_rows
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, p)| p.clone())
        {
            app.split_active(crate::layout::SplitDir::Horizontal);
            app.open_path(&path);
            return;
        }
        // Notes panel file rows.
        if let Some(path) = app
            .rects
            .notes_panel_files
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, p)| p.clone())
        {
            app.split_active(crate::layout::SplitDir::Horizontal);
            app.open_path(&path);
            return;
        }
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
            // T-6 file-split — extracted to mouse/drag_left.rs.
            drag_left::handle_drag_left(app, x, y);
        }
        MouseEventKind::Up(MouseButton::Left) => {
            // T-7 file-split — extracted to mouse/up_left.rs.
            up_left::handle_up_left(app, x, y);
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
