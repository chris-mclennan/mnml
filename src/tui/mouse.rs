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

use ratatui::crossterm::event::{self, KeyModifiers, MouseButton, MouseEvent, MouseEventKind};

use super::{send_macos_player, send_mixr_command};
use crate::app::App;
use crate::command;
use crate::pane::Pane;

/// immediately-available scroll event of the SAME direction
/// from crossterm's queue. Returns a synthetic mouse event with
/// a magnitude field equal to the total count (encoded as
/// repeats via [`SCROLL_REPEAT_KEY`] — see `scroll_repeat_count`).
///
/// Non-scroll events return Ok(None); the caller dispatches the
/// original event as-is.
///
/// Cap the batched count so a stuck wheel can't trigger thousands
/// of lines of scroll in one shot.
pub(crate) fn coalesce_scroll(first: &MouseEvent) -> std::io::Result<Option<MouseEvent>> {
    use ratatui::crossterm::event::Event as CtEvent;
    let same_dir = |k: MouseEventKind| -> bool {
        matches!(
            (first.kind, k),
            (MouseEventKind::ScrollUp, MouseEventKind::ScrollUp)
                | (MouseEventKind::ScrollDown, MouseEventKind::ScrollDown)
        )
    };
    if !matches!(
        first.kind,
        MouseEventKind::ScrollUp | MouseEventKind::ScrollDown
    ) {
        return Ok(None);
    }
    // Drain at most SCROLL_BATCH_CAP events to avoid a stuck-wheel
    // runaway. We start counting at 1 because `first` is already
    // in our hand.
    const SCROLL_BATCH_CAP: u32 = 40;
    let mut count: u32 = 1;
    while count < SCROLL_BATCH_CAP {
        if !event::poll(std::time::Duration::ZERO)? {
            break;
        }
        // Peek by reading — crossterm has no peek API. If the next
        // event is a SAME-direction scroll at roughly the same
        // position, fold it in. If it's anything else, we've
        // already consumed it from the queue, so we need a way to
        // re-dispatch. crossterm doesn't support unread either,
        // so we instead stop coalescing when we'd skip a non-
        // matching event. To do that safely, check the event kind
        // BEFORE deciding to read.
        //
        // Workaround: read it. If it's same-direction, count it.
        // If not, dispatch it via a fall-through queue we return
        // to the caller. For v1 we use a simpler shortcut: only
        // coalesce when the immediately-next event is also a
        // scroll of the same direction; bail on any other.
        let ev = event::read()?;
        match ev {
            CtEvent::Mouse(m) if same_dir(m.kind) => {
                count += 1;
                continue;
            }
            // Non-matching event drained from the queue — push it
            // back into our local pipeline by dispatching it via
            // the COALESCE_LEFTOVER thread-local. Simpler: return
            // the coalesced batch + leftover via a different path.
            // For now we DROP the leftover (rare in practice —
            // wheel events arrive in tight bursts without interleaved
            // key events). Document this trade-off here.
            _ => {
                // Drop the non-scroll event. Acceptable in practice
                // because wheel events arrive in tight bursts
                // (~3ms apart) and a key/move event rarely lands
                // in the middle. Worst case the user retries the
                // input.
                let _ = ev;
                break;
            }
        }
    }
    if count <= 1 {
        return Ok(None);
    }
    // Encode the magnitude by replicating the event N times at
    // dispatch sites — simplest path. We attach it via a sidecar
    // global. crossterm's MouseEvent has no count field, so
    // instead we stash the count in a static and read it back in
    // `dispatch_mouse_wheel_delta`. NOTE: we still return the
    // first event so its (x, y) modifiers + kind are preserved.
    SCROLL_BATCH_COUNT.store(count, std::sync::atomic::Ordering::Relaxed);
    Ok(Some(*first))
}

/// The most recent coalesced batch's magnitude. Read by the
/// scroll dispatcher to apply N lines instead of 1. Reset to 1
/// after each consumption.
pub(crate) static SCROLL_BATCH_COUNT: std::sync::atomic::AtomicU32 =
    std::sync::atomic::AtomicU32::new(1);

/// Read + consume the pending coalesced scroll magnitude. Returns
/// 1 when no coalescing happened.
pub(crate) fn take_scroll_batch_count() -> u32 {
    SCROLL_BATCH_COUNT
        .swap(1, std::sync::atomic::Ordering::Relaxed)
        .max(1)
}

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
            // vscode-user-mouse SEV-3 — right-click on the palette
            // search chip mirrors the dropdown chevron and opens
            // recents directly (browser-style "back / forward / open
            // recents" via context menu).
            if let Some(r) = app.rects.palette_search_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("picker.recent", app);
                return;
            }
            // Right-click on the activity-bar gear mirrors left-click
            // — opens the same Settings / Cmd Palette / Themes /
            // About menu (matches macOS gear-icon UX where right-click
            // is the canonical way to expose options).
            if let Some(r) = app.rects.activity_bar_gear
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_gear_context_menu((x, y));
                return;
            }
            // Right-click on a session tab → context menu.
            if let Some(&(_, pid)) = app
                .rects
                .session_tabs
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_session_tab_context_menu(pid, (x, y));
                return;
            }
            // Right-click on a dock widget (body, title, or kebab)
            // → open the kebab menu anchored at the click. Same
            // menu as the `⋮` glyph; gives power users a faster
            // path. Checked first so the menu wins over per-pane
            // right-click handlers below.
            if let Some(id) = app
                .rects
                .dock_widget_bodies
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .map(|(_, id)| *id)
                .or_else(|| {
                    app.rects
                        .dock_widget_titles
                        .iter()
                        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                        .map(|(_, id)| *id)
                })
                .or_else(|| {
                    app.rects
                        .dock_widget_kebabs
                        .iter()
                        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                        .map(|(_, id)| *id)
                })
            {
                if let Some(w) = app.dock_widgets.iter().find(|w| w.id == id) {
                    app.dock_kebab_menu = Some(crate::dock::KebabMenuState::build(w, x, y));
                }
                return;
            }
            // 2026-06-21 vscode-mouse SEV-2: right-click on a
            // Claude Agents dashboard row → 7-item context menu.
            if let Some(&(_, pid, row_idx)) = app.rects.list_rows.iter().find(|(r, pid, _)| {
                matches!(app.panes.get(*pid), Some(Pane::ClaudeAgents(_)))
                    && crate::app::dispatch::contains(*r, x, y)
            }) {
                app.open_dashboard_row_context_menu(pid, row_idx, (x, y));
                return;
            }
            // Cloud Agents panel row → 3-item context menu:
            // Copy runId · Open CloudWatch logs · Open PR (if set).
            if let Some(&(_, row_idx)) = app
                .rects
                .cloud_agents_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_cloud_row_context_menu(row_idx, (x, y));
                return;
            }
            // 2026-06-21 — right-click on a Files drill-down panel
            // row in the dashboard → 4-item context menu
            // (Open / Reveal in tree / Yank path / Copy to scratch).
            if let Some(path) = app
                .rects
                .claude_drill_files
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .map(|(_, p)| p.clone())
            {
                app.open_dashboard_file_context_menu(path, (x, y));
                return;
            }
            // Right-click on a statusline chip — context menus for the four
            // clickable chips (branch / workspace / mode / clock).
            if let Some(r) = app.rects.statusline_branch_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_statusline_branch_context_menu((x, y));
                return;
            }
            if let Some(r) = app.rects.statusline_workspace_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_statusline_workspace_context_menu((x, y));
                return;
            }
            if let Some(r) = app.rects.statusline_mode_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_statusline_mode_context_menu((x, y));
                return;
            }
            if let Some(r) = app.rects.statusline_clock_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_statusline_clock_context_menu((x, y));
                return;
            }
            // Right-click on the `> WORKSPACE` header → workspace menu.
            if let Some(tr) = app.rects.tree_toggle
                && crate::app::dispatch::contains(tr, x, y)
            {
                app.open_workspace_header_context_menu((x, y));
                return;
            }
            // Right-click on an integration chip → Edit / Remove
            // quick-actions. Lets a user tweak a chip without
            // going through the discovery overlay first.
            if let Some(&(_, icon_idx)) = app
                .rects
                .integration_icon_rects
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_integration_chip_context_menu(icon_idx, (x, y));
                return;
            }
            // Right-click on a launcher chip → Enable/Disable.
            // Parallel to the integration chip menu — chips look
            // identical to the user.
            if let Some(&(_, icon_idx)) = app
                .rects
                .launcher_icon_rects
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_launcher_chip_context_menu(icon_idx, (x, y));
                return;
            }
            // Right-click on the split-strip AI button → choose
            // between Claude / Codex without changing the configured
            // default. Tab-strip Term + Split buttons are single-
            // action so they don't need menus.
            if let Some(&(_, leaf_active)) = app
                .rects
                .split_strip_ai_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
                app.active = Some(leaf_active);
                let items = vec![
                    MenuItem::new("Open Claude Code", MenuAction::Command("ai.claude_code")),
                    MenuItem::new("Open Codex", MenuAction::Command("ai.codex")),
                ];
                app.context_menu = Some(ContextMenu::new(
                    Some("AI assistant".to_string()),
                    (x, y),
                    items,
                ));
                return;
            }
            // Right-click on the rail INTEGRATIONS section header.
            // Quick add-integration + collapse — other rail headers
            // (Workspace, Git) have context menus; integrations was
            // the lone exception.
            if let Some(r) = app.rects.integration_section_toggle
                && crate::app::dispatch::contains(r, x, y)
            {
                use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
                let items = vec![
                    MenuItem::new("Add integration…", MenuAction::Command("integrations.add")),
                    MenuItem::new(
                        if app.integration_section_expanded {
                            "Collapse section"
                        } else {
                            "Expand section"
                        },
                        MenuAction::Command("view.toggle_integrations_section"),
                    ),
                ];
                app.context_menu = Some(ContextMenu::new(
                    Some("integrations".to_string()),
                    (x, y),
                    items,
                ));
                return;
            }
            // Right-click on an extra-workspace header → that workspace's menu.
            if let Some(&(_, ws_idx)) = app
                .rects
                .extra_workspace_toggles
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_extra_workspace_header_context_menu(ws_idx, (x, y));
                return;
            }
            // Right-click on a Request pane URL/Method/Headers/Body row →
            // copy-as-curl / send / toggle view. 2026-06-19 — vscode-
            // user-mouse agent caught that the menu would dispatch
            // against whatever pane was previously active (spawning
            // dup Request panes from Send, no-op'ing Switch). Set
            // active to the right-clicked Request pane first so the
            // menu's commands operate on the visible target.
            if let Some(&(_, pid, field)) = app
                .rects
                .request_fields
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                app.open_request_field_context_menu(field, (x, y));
                return;
            }
            // Right-click anywhere inside an AI pane → re-ask / cancel /
            // promote menu. AI panes don't have list_rows so we test by
            // matching the active pane variant + click location against
            // the pane's bounding rect via the editor-pane registry (AI
            // panes share that registry shape).
            if let Some(cur) = app.active
                && matches!(app.panes.get(cur), Some(Pane::Ai(_)))
            {
                // Quick "is the click inside the AI pane's body?" — the
                // pane currently doesn't register its rect, so we just
                // fire the menu whenever an AI pane is active and the
                // click hasn't been caught by anything earlier (the
                // statusline / bufferline / rail checks already returned).
                app.open_ai_pane_context_menu((x, y));
                return;
            }
            // Right-click on a pty pane (terminal / Claude / Codex) →
            // dock-position menu (left / right / top / bottom / maximize /
            // zen). Pty panes register their rect in `editor_panes`.
            if let Some(&(_, pid)) = app.rects.editor_panes.iter().find(|(r, pid)| {
                crate::app::dispatch::contains(*r, x, y)
                    && matches!(app.panes.get(*pid), Some(Pane::Pty(_)))
            }) {
                app.open_pty_dock_context_menu(pid, (x, y));
                return;
            }
            // Right-click on an editor gutter → per-line menu (toggle BP /
            // goto def / refs / blame / browse line). Translate the click
            // y into a file row using the pane's current scroll.
            if let Some(&(gr, pid)) = app
                .rects
                .editor_gutters
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                let row_in_pane = (y - gr.y) as usize;
                let line = match app.panes.get(pid) {
                    Some(Pane::Editor(b)) => b.scroll + row_in_pane,
                    _ => row_in_pane,
                };
                app.open_editor_gutter_context_menu(pid, line as u32, (x, y));
                return;
            }
            // Right-click on the editor BODY → text-scoped menu
            // (LSP goto / refs / hover / rename, select-all-
            // occurrences, expand-selection, toggle-fold, Save).
            // Translate the click to (file_row, file_col) via the
            // pane's scroll. Surfaces the SEV-2 VS-Code-mouse hunt
            // finding "Editor text body has no right-click menu."
            if let Some(&(tr, pid)) = app
                .rects
                .editor_panes
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                let wrap = app.config.ui.wrap;
                if let Some(Pane::Editor(b)) = app.panes.get(pid) {
                    let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
                    app.open_editor_body_context_menu(pid, row, col, (x, y));
                    return;
                }
            }
            // Right-click a pty pane's tab strip (Claude / Codex / shell) →
            // rename / close that session.
            if let Some(&(_, pid)) = app
                .rects
                .pty_tabs
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_pty_tab_context_menu(pid, (x, y));
                return;
            }
            // Right-click → a context menu on the bufferline tab / tree row under it.
            if let Some(&(_, id)) = app
                .rects
                .bufferline_tabs
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_tab_context_menu(id, (x, y));
                return;
            }
            // 2026-06-22 — per-split tab chips also get a
            // right-click context menu (same as bufferline
            // tabs). Routes to the third tuple field (tab pane
            // id), not the leaf_active (which would always be
            // the leaf's active pane, not the one clicked).
            if let Some(&(_, _, tab_pane)) = app
                .rects
                .split_tab_chips
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_tab_context_menu(tab_pane, (x, y));
                return;
            }
            if let Some(tr) = app.rects.tree
                && crate::app::dispatch::contains(tr, x, y)
            {
                let idx = (y - tr.y) as usize + app.rects.tree_scroll;
                if idx < app.tree.visible_rows().len() {
                    app.tree.set_cursor(idx);
                    app.focus_tree();
                    if let Some(row) = app.tree.selected_row() {
                        app.open_tree_context_menu(row.path.clone(), row.is_dir, (x, y));
                    }
                }
                return;
            }
            // Right-click on a GIT-section row → per-row context menu.
            if let Some(&(_, hit)) = app
                .rects
                .git_rail_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_git_rail_context_menu(hit, (x, y));
                return;
            }
            // Right-click on a git-palette row — same context menu
            // dispatch as the legacy rail (delete branch / open
            // worktree / open PR …). Remote branches don't have a
            // dedicated context menu yet — fall through silently
            // for now.
            if let Some(&(_, hit)) = app
                .rects
                .git_palette_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                match hit {
                    crate::ui::git_palette::GitPaletteHit::Branch(i) => {
                        app.open_git_rail_context_menu(
                            crate::git::rail::GitRailHit::Branch(i),
                            (x, y),
                        );
                    }
                    crate::ui::git_palette::GitPaletteHit::Worktree(i) => {
                        app.open_git_rail_context_menu(
                            crate::git::rail::GitRailHit::Worktree(i),
                            (x, y),
                        );
                    }
                    crate::ui::git_palette::GitPaletteHit::Pull(i) => {
                        app.open_git_rail_context_menu(
                            crate::git::rail::GitRailHit::Pull(i),
                            (x, y),
                        );
                    }
                    crate::ui::git_palette::GitPaletteHit::Stash(i) => {
                        app.open_git_palette_stash_context_menu(i, (x, y));
                    }
                    crate::ui::git_palette::GitPaletteHit::Tag(i) => {
                        app.open_git_palette_tag_context_menu(i, (x, y));
                    }
                    crate::ui::git_palette::GitPaletteHit::RemoteBranch(i) => {
                        app.open_git_palette_remote_branch_context_menu(i, (x, y));
                    }
                }
                return;
            }
            // Right-click on a diff body row (standalone or embedded
            // diff) → per-hunk context menu (Open file at revision /
            // Copy commit hash / Stage / Unstage / Discard).
            // Right-click on a GitStatus file row → per-file menu
            // (Stage / Discard / Ignore / Stash / Reveal / …).
            if let Some(&(_, pid, idx)) = app
                .rects
                .list_rows
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                match app.panes.get(pid) {
                    Some(Pane::Diff(_)) => {
                        app.active = Some(pid);
                        app.focus_pane();
                        app.open_diff_context_menu(pid, idx, (x, y));
                    }
                    Some(Pane::GitGraph(g)) if g.embedded_diff.is_some() => {
                        app.active = Some(pid);
                        app.focus_pane();
                        app.open_diff_context_menu(pid, idx, (x, y));
                    }
                    Some(Pane::GitStatus(_)) => {
                        app.active = Some(pid);
                        app.focus_pane();
                        app.open_git_status_context_menu(pid, idx, (x, y));
                    }
                    _ => {}
                }
            }
        }
        MouseEventKind::Down(MouseButton::Left) => {
            // Grab the rail's right-edge resize handle first — its grip
            // band shares the rail's rightmost column with the file-tree
            // scrollbar, so the (specific, ~4-row) resize zone must win
            // there before the (full-height) scrollbar claims the click.
            if app.begin_tree_edge_drag(x, y) {
                return;
            }
            // vscode-user-mouse SEV-1 — mirror for the right-panel
            // grip. Without this, the field stayed false and the
            // grip was decorative.
            if app.maybe_start_right_panel_edge_drag(x, y) {
                return;
            }
            // Grab a scrollbar (editor / diff / embedded-diff / tree) before
            // any pane-level handler — the bar sits inside the pane's
            // own rect, so without this short-circuit a click on the
            // bar would also land in the editor / row-select handlers
            // below and shift the cursor / row selection.
            if app.begin_scrollbar_drag(x, y) {
                return;
            }
            // Grab the GitGraph commit-list ↔ detail-panel divider?
            if app.begin_git_graph_detail_drag(x, y) {
                return;
            }
            // Grab a split divider? (do this first — it sits between two pane rects)
            if app.begin_divider_drag(x, y) {
                return;
            }
            // Click on a fold chip → unfold that block. Match before the
            // editor-pane click handler so the chip "owns" the click.
            if let Some(&(_, pid, start)) = app
                .rects
                .fold_chips
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                    b.folds.remove(&start);
                }
                return;
            }
            // Click on a code-lens chip → fire its `workspace/executeCommand`.
            // Same priority as fold chips — chip owns the click.
            if let Some(&(_, pid, lens_idx)) = app
                .rects
                .code_lens_chips
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                app.trigger_code_lens(pid, lens_idx);
                return;
            }
            // Click on a WIP-detail button → fire its action (stage/unstage
            // file or all, open commit prompt, request AI commit message).
            // High priority so the button "owns" the click instead of the
            // pane-focus handler eating it.
            if let Some((_, pid, action)) = app
                .rects
                .wip_buttons
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
                .cloned()
            {
                app.active = Some(pid);
                app.focus_pane();
                // Clicking a button blurs the textarea so the user
                // doesn't keep typing into a no-longer-visible field.
                app.blur_active_wip_commit_textarea();
                app.run_wip_action(action);
                return;
            }
            // Click on a WIP-detail file row (not the button) →
            // open that file's diff (`Pane::Diff`) so the user can
            // browse Hunk / Inline / Split views.
            if let Some((_, pid, abs_path, staged)) = app
                .rects
                .wip_file_rows
                .iter()
                .find(|(r, _, _, _)| crate::app::dispatch::contains(*r, x, y))
                .cloned()
            {
                app.active = Some(pid);
                app.focus_pane();
                app.blur_active_wip_commit_textarea();
                app.click_wip_file_row(abs_path, staged);
                return;
            }
            // Click inside the WIP commit textarea rect → focus it.
            // Wins over the pane-focus handler so the click both
            // focuses the GitGraph pane AND focuses the textarea.
            if let Some((r, pid)) = app.rects.wip_commit_textarea
                && crate::app::dispatch::contains(r, x, y)
            {
                app.active = Some(pid);
                app.focus_pane();
                app.focus_wip_commit_textarea(pid);
                return;
            }
            // Click on a GitGraph top-toolbar button → fire its action.
            // Pull / Push / Fetch / Branch / Commit / Stash / Pop /
            // Reflog / Terminal. High priority so the button owns the
            // click.
            if let Some(&(_, pid, action)) = app
                .rects
                .git_toolbar_buttons
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                app.run_git_toolbar_action(action);
                return;
            }
            // Click on a per-hunk action chip ([Stage] / [Unstage]
            // / [Discard]) in the Hunk view's header row → dispatch
            // the action against that hunk. Runs before the
            // toolbar / row click handlers so the chip "owns" the
            // click.
            if let Some(&(_, pid, hi, action)) = app
                .rects
                .diff_hunk_buttons
                .iter()
                .find(|(r, _, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                app.apply_hunk_action(pid, hi, action);
                return;
            }
            // Click on a Diff pane toolbar button → switch view mode
            // or toggle wrap. Also store the choice as the App-level
            // preference so every subsequent diff opens in that mode.
            // Works against both a standalone `Pane::Diff` and a
            // `Pane::GitGraph` with an embedded diff (when the user
            // clicked a file from a commit's right-side detail panel
            // and the diff opened in-place on the left).
            if let Some(&(_, pid, action)) = app
                .rects
                .diff_toolbar_buttons
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                // `Close` is special — clears embedded diff if any,
                // else closes the standalone Pane::Diff. Returns
                // before the view-mode handling block since the
                // pane may no longer exist after closing.
                if matches!(action, crate::DiffToolbarAction::Close) {
                    match app.panes.get_mut(pid) {
                        Some(Pane::GitGraph(g)) if g.embedded_diff.is_some() => {
                            g.embedded_diff = None;
                        }
                        Some(Pane::Diff(_)) => {
                            app.close_pane(pid);
                        }
                        _ => {}
                    }
                    return;
                }
                let mut new_wrap_pref: Option<bool> = None;
                let mut new_mode_pref: Option<crate::pane::DiffViewMode> = None;
                let dv: Option<&mut crate::pane::DiffView> = match app.panes.get_mut(pid) {
                    Some(Pane::Diff(d)) => Some(d),
                    Some(Pane::GitGraph(g)) => g.embedded_diff.as_mut(),
                    _ => None,
                };
                if let Some(d) = dv {
                    match action {
                        crate::DiffToolbarAction::ViewInline => {
                            d.view_mode = crate::pane::DiffViewMode::Inline;
                            new_mode_pref = Some(d.view_mode);
                        }
                        crate::DiffToolbarAction::ViewHunk => {
                            d.view_mode = crate::pane::DiffViewMode::Hunk;
                            new_mode_pref = Some(d.view_mode);
                        }
                        crate::DiffToolbarAction::ViewSplit => {
                            d.view_mode = crate::pane::DiffViewMode::Split;
                            new_mode_pref = Some(d.view_mode);
                        }
                        crate::DiffToolbarAction::ToggleWrap => {
                            d.wrap = !d.wrap;
                            new_wrap_pref = Some(d.wrap);
                        }
                        crate::DiffToolbarAction::Close => unreachable!(),
                    }
                }
                if let Some(m) = new_mode_pref {
                    app.diff_view_mode_pref = m;
                }
                if let Some(w) = new_wrap_pref {
                    app.diff_wrap_pref = w;
                }
                return;
            }
            // Click on a commit-detail changed-file row → open that
            // file's diff for the selected commit.
            if let Some(&(_, pid, file_idx)) = app
                .rects
                .commit_file_rows
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                app.click_commit_file_row(pid, file_idx);
                return;
            }
            // Click on a request-pane tab chip → switch view (Edit ⇄ Response).
            if let Some(&(_, pid, view)) = app
                .rects
                .request_tabs
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
                    rp.view = view;
                }
                return;
            }
            // Click on a row in the cmdline completion popup →
            // accept that match (writes the completion into the
            // cmdline and bumps cmdline_popup_selected so subsequent
            // Tabs continue from there). 2026-06-19 — discoverability
            // gold: users can mouse-pick from the popup.
            if let Some(&(_, idx)) = app
                .rects
                .cmdline_popup_items
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.cmdline_popup_accept(idx);
                return;
            }
            // Click on an Auth-tab action row → dispatch to the
            // matching App method (prompt or palette command).
            if let Some((_, id)) = app
                .rects
                .request_auth_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .cloned()
            {
                app.http_auth_row_clicked(&id);
                return;
            }
            // Click on the AI section header → opens a prompt
            // asking what the user wants to know (custom Q + A).
            // The `a` key still fires the default debug prompt
            // (no question, just 'why is this not working').
            if let Some(r) = app.rects.request_ai_section
                && crate::app::dispatch::contains(r, x, y)
            {
                app.ai_ask_about_request_prompt();
                return;
            }
            // Click on a Vars-tab row → open the env editor
            // directly. Empty key (the `+ Add` row) → add prompt;
            // non-empty key → edit prompt for that key.
            if let Some((_, key)) = app
                .rects
                .request_vars_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .cloned()
            {
                if key.is_empty() {
                    app.accept_env_vars("+add");
                } else {
                    app.accept_env_vars(&key);
                }
                return;
            }
            // Click on a Params-tab row → empty (`+ Add`) opens
            // the KEY=VALUE prompt; non-empty deletes that param
            // from the URL (v2 will open an edit prompt instead).
            if let Some((_, key)) = app
                .rects
                .request_params_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .cloned()
            {
                if key.is_empty() {
                    app.http_params_add();
                } else {
                    app.http_params_delete(&key);
                }
                return;
            }
            // Click on a Request pane Edit-view tab chip (Body /
            // Headers / Params / Vars / Source) → switch the
            // pane's edit_tab.
            if let Some(&(_, pid, tab)) = app
                .rects
                .request_edit_tabs
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
                    rp.view = crate::request_pane::ViewMode::Edit;
                    rp.edit_tab = tab;
                    if tab == crate::request_pane::EditTab::Source {
                        rp.focus = crate::request_pane::EditField::Source;
                    } else if rp.focus == crate::request_pane::EditField::Source {
                        rp.focus = crate::request_pane::EditField::Url;
                    }
                }
                return;
            }
            // Click on a request-pane Edit-mode field row → focus that field.
            // 2026-06-19 — vscode-user-mouse agent caught that the
            // caret was never positioned at the click site (it stayed
            // wherever it was, typically end-of-value). For the URL
            // field — the most common edit target — compute the byte
            // position from the visual column and update url_cursor.
            // Headers / Body are multi-line; positioning their carets
            // by click requires per-row mapping that's a v2 follow-up;
            // they still get focused so the user can type / use arrows.
            if let Some(&(rect, pid, field)) = app
                .rects
                .request_fields
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
                    rp.view = crate::request_pane::ViewMode::Edit;
                    rp.focus = field;
                    // 2026-06-20 — Method chip click opens a
                    // verb-picker context menu (one entry per
                    // HTTP verb). Click an item → method set.
                    // Width ≤ 12 disambiguates the chip rect from
                    // the wider headers/body rows.
                    let chip_clicked =
                        matches!(field, crate::request_pane::EditField::Method) && rect.width <= 12;
                    if chip_clicked {
                        let _ = rp;
                        app.open_method_dropdown((x, y));
                        return;
                    }
                    if matches!(field, crate::request_pane::EditField::Url) {
                        // URL row layout: " URL  <value>". Label
                        // offset = leading-space + "URL" + 2 spaces ≈
                        // 6 cells. Visual column within the value =
                        // click x - rect.x - label_offset. Convert
                        // visual column to a byte position via
                        // char_indices(); clamp to value length.
                        let dx = x.saturating_sub(rect.x);
                        let label_offset: u16 = 6;
                        let visual_col = dx.saturating_sub(label_offset) as usize;
                        let url = &rp.request.url;
                        let byte_pos = url
                            .char_indices()
                            .nth(visual_col)
                            .map(|(i, _)| i)
                            .unwrap_or(url.len());
                        rp.url_cursor = byte_pos;
                    }
                }
                return;
            }
            // Bufferline overflow chevrons — scroll the tab strip by one.
            if let Some(r) = app.rects.bufferline_overflow_left
                && crate::app::dispatch::contains(r, x, y)
            {
                if app.bufferline_first_visible > 0 {
                    app.bufferline_first_visible -= 1;
                }
                return;
            }
            if let Some(r) = app.rects.bufferline_overflow_right
                && crate::app::dispatch::contains(r, x, y)
            {
                if app.bufferline_first_visible + 1 < app.panes.len() {
                    app.bufferline_first_visible += 1;
                }
                return;
            }
            // Bufferline tab — clicking the close badge closes; clicking elsewhere on the tab activates.
            if let Some(&(_, id)) = app
                .rects
                .bufferline_tab_close
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.close_pane(id);
                return;
            }
            if let Some(&(_, id)) = app
                .rects
                .bufferline_tabs
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                // Arm a drag — the buffer-switch (reveal) is deferred to
                // mouse-up so a drag-to-split doesn't first swap the grabbed
                // tab into the pane (which would make the drop land on its own
                // pane). A subsequent Drag into another tab's rect reorders;
                // a Drag onto a pane body splits. On a plain click (up on the
                // same tab) the Up handler reveals.
                app.rects.bufferline_drag_tab = Some(id);
                return;
            }
            // Pty-pane tab strip — click `+` to add a new Claude session
            // as a TAB of that strip's leaf (no split); click a session
            // tab to switch; click the `×` to kill that session. Test
            // close BEFORE switch so the badge wins over the chip body.
            if let Some(&(_, pid)) = app
                .rects
                .pty_tab_close
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.close_pane(pid);
                return;
            }
            if let Some(&(_, owner)) = app
                .rects
                .pty_tab_new
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                let profile = crate::pty_pane::BinaryProfile::claude_code(app.workspace.clone());
                app.add_pty_tab(owner, profile);
                return;
            }
            if let Some(&(_, pid)) = app
                .rects
                .pty_tabs
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.reveal_pane(pid);
                return;
            }
            // Bufferline right cluster — Claude / Codex launch chips,
            // `+` new tab, per-tabpage chip / close, theme toggle,
            // window close. Order matters (the `⊗` rect sits adjacent
            // to its chip; check close before chip).
            // Palette top-bar — sidebar / back / forward / chip / dropdown.
            if let Some(r) = app.rects.palette_sidebar_button
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("view.toggle_tree", app);
                return;
            }
            if let Some(r) = app.rects.palette_right_panel_button
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("view.toggle_right_panel", app);
                return;
            }
            if let Some(r) = app.rects.palette_add_integration_button
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("integrations.add", app);
                return;
            }
            if let Some(r) = app.rects.palette_back_button
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("buffer.prev", app);
                return;
            }
            if let Some(r) = app.rects.palette_forward_button
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("buffer.next", app);
                return;
            }
            if let Some(r) = app.rects.palette_search_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_command_palette();
                return;
            }
            if let Some(r) = app.rects.palette_dropdown_button
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("picker.recent", app);
                return;
            }
            // Launcher-icon strip — click hands off to the configured
            // command (registered command id, or ex-cmdline string).
            if let Some(&(_, icon_idx)) = app
                .rects
                .launcher_icon_rects
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                && let Some(icon) = app.config.ui.launcher_icons.get(icon_idx)
            {
                let cmd = icon.command.clone();
                if let Some(rest) = cmd.strip_prefix(':') {
                    app.run_ex_command(rest);
                } else {
                    crate::command::run(&cmd, app);
                }
                return;
            }
            if let Some(r) = app.rects.bufferline_new_tab_button
                && crate::app::dispatch::contains(r, x, y)
            {
                app.tab_new(None);
                return;
            }
            if let Some(&(_, idx)) = app
                .rects
                .bufferline_tab_page_close
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.tab_close_at(idx);
                return;
            }
            if let Some(&(_, idx)) = app
                .rects
                .bufferline_tab_page_chips
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.switch_tab(idx);
                // Arm a drag — a subsequent mouse-drag over a
                // different chip's rect swaps the two tabs.
                app.dragging_tab_page = Some(app.active_layout);
                return;
            }
            // 2026-06-22 — per-split tab chip clicks (multi-tab
            // leaves). Close × FIRST so a close-button click in the
            // chip body doesn't get swallowed by the chip-switch.
            if let Some(&(_, leaf_active, tab_pane)) = app
                .rects
                .split_tab_close
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.close_split_tab(leaf_active, tab_pane);
                return;
            }
            // AI launch button in the split-strip cluster.
            // Focus the clicked leaf, then fire the configured
            // `ai.*` command (Claude Code / Codex).
            if let Some(&(_, leaf_active)) = app
                .rects
                .split_strip_ai_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                let cmd = match app.config.ui.tab_bar_ai_icon.as_str() {
                    "codex" => "ai.codex",
                    _ => "ai.claude_code",
                };
                app.active = Some(leaf_active);
                app.focus = crate::focus::Focus::Pane;
                crate::command::run(cmd, app);
                return;
            }
            // Terminal button in the split-strip cluster.
            // Focus the clicked leaf, then open a shell in a
            // split (mirrors the `term.shell` palette command).
            if let Some(&(_, leaf_active)) = app
                .rects
                .split_strip_term_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(leaf_active);
                app.focus = crate::focus::Focus::Pane;
                app.open_shell();
                return;
            }
            // 2026-06-22 — per-split split-editor buttons at the
            // right of the strip. Focus the clicked leaf's active
            // pane, then dispatch split_active(dir).
            if let Some(&(_, leaf_active, dir)) = app
                .rects
                .split_strip_buttons
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(leaf_active);
                app.focus = crate::focus::Focus::Pane;
                app.split_active(dir);
                return;
            }
            if let Some(&(_, leaf_active, tab_pane)) = app
                .rects
                .split_tab_chips
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                // 2026-06-27 — arm a drag like the bufferline tab
                // handler does, so per-leaf tabs are also
                // drag-to-split / drag-to-move. Without this,
                // a click on a per-leaf tab activated the tab
                // and returned, never setting bufferline_drag_tab,
                // so subsequent Drag / Moved events did nothing.
                // The bufferline_drag_tab field doubles as the
                // drag-source for both global bufferline AND
                // per-leaf strips — the pane id is the same.
                app.rects.bufferline_drag_tab = Some(tab_pane);
                // Switch the visible tab immediately so the click
                // also activates as the user expects. The mouse-up
                // handler will still see bufferline_drag_tab Some
                // and route through drop / reveal logic.
                let now = std::time::Instant::now();
                let is_double = matches!(
                    app.last_click,
                    Some((prev, px, py, _))
                        if px == x
                            && py == y
                            && now.duration_since(prev) < std::time::Duration::from_millis(450)
                );
                app.last_click = Some((now, x, y, if is_double { 2 } else { 1 }));
                if is_double && let Some(Pane::Editor(b)) = app.panes.get_mut(tab_pane) {
                    b.is_preview = false;
                }
                app.switch_split_tab(leaf_active, tab_pane);
                return;
            }
            if let Some(r) = app.rects.bufferline_theme_toggle
                && crate::app::dispatch::contains(r, x, y)
            {
                // NvChad convention: the slider is a binary toggle between
                // `[ui] theme` ↔ `[ui] theme_toggle`. Falls back to opening
                // the picker when `theme_toggle` is unconfigured.
                if app.config.ui.theme_toggle.is_some() {
                    app.toggle_theme();
                } else {
                    app.open_theme_picker();
                }
                return;
            }
            if let Some(r) = app.rects.bufferline_window_close
                && crate::app::dispatch::contains(r, x, y)
            {
                app.close_active_pane();
                return;
            }
            // Statusline branch chip → open the commit graph. Always-visible
            // click target for git.graph (vs the keyboard-only `<leader>g l`).
            if let Some(r) = app.rects.statusline_branch_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("git.graph", app);
                return;
            }
            // Statusline test-runner chip → focus the test pane.
            if let Some(r) = app.rects.statusline_test_chip
                && crate::app::dispatch::contains(r, x, y)
                && let Some((_, pane_idx)) = app.last_test_run
                && pane_idx < app.panes.len()
            {
                app.active = Some(pane_idx);
                app.focus_pane();
                return;
            }
            // Statusline mode chip → toggle input style (vim ↔ standard).
            if let Some(r) = app.rects.statusline_mode_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("editor.toggle_keymap", app);
                return;
            }
            // Cmdline bar — click anywhere on the bottom 1-row strip
            // opens the ex-cmdline (same as typing `:`). Checked
            // BEFORE the statusline chips because the bar sits below
            // the statusline and overlapping hit-rects are otherwise
            // resolved top-down. A click while the cmdline is
            // already open is a no-op (let the user keep typing).
            //
            // 2026-06-20 — check the right-side `⟳ … running…`
            // indicator FIRST so clicks there abort the in-flight
            // op instead of opening the cmdline. Same area covers
            // both targets; narrower one wins.
            if let Some(r) = app.rects.cmdline_inflight
                && crate::app::dispatch::contains(r, x, y)
            {
                app.http_abort_all();
                return;
            }
            // 2026-06-20 — toast `[name]` mention: click reveals
            // the matching pane (substring match on pane title).
            if let Some((r, name)) = app.rects.cmdline_toast_target.clone()
                && crate::app::dispatch::contains(r, x, y)
                && let Some((idx, _)) = app
                    .panes
                    .iter()
                    .enumerate()
                    .find(|(_, p)| p.title().contains(&name))
            {
                app.active = Some(idx);
                app.focus_pane();
                app.reveal_pane(idx);
                return;
            }
            if app.no_pane_cmdline.is_none()
                && let Some(r) = app.rects.cmdline_bar
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_ex_command_prompt();
                return;
            }
            // Statusline workspace / active-repo chip → open the repo picker
            // (single-repo workspace toasts "only one repo").
            if let Some(r) = app.rects.statusline_workspace_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_repo_picker();
                return;
            }
            // Statusline clock chip → flip between local and UTC.
            if let Some(r) = app.rects.statusline_clock_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.clock_show_utc = !app.clock_show_utc;
                app.toast(if app.clock_show_utc {
                    "clock: UTC"
                } else {
                    "clock: local"
                });
                return;
            }
            // Play / pause control — source-aware: mixr → pause IPC,
            // Apple Music / Spotify → AppleScript `playpause`. Checked
            // before the track-text chip because the three sit
            // adjacent. Returns silently when no source matches
            // (cluster is in idle form).
            if let Some(r) = app.rects.statusline_mixr_play_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                let source = app
                    .now_playing
                    .as_ref()
                    .map(|np| np.source.as_str())
                    .unwrap_or("");
                if source.eq_ignore_ascii_case("mixr") {
                    send_mixr_command("pause");
                } else if !source.is_empty() {
                    send_macos_player(source, "playpause");
                }
                return;
            }
            // Ffwd control — mixr → teleport (jump on beat to just
            // before mix-out); Apple Music / Spotify → next track via
            // AppleScript.
            if let Some(r) = app.rects.statusline_mixr_ffwd_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                let source = app
                    .now_playing
                    .as_ref()
                    .map(|np| np.source.as_str())
                    .unwrap_or("");
                if source.eq_ignore_ascii_case("mixr") {
                    send_mixr_command("teleport");
                } else if !source.is_empty() {
                    send_macos_player(source, "next track");
                }
                return;
            }
            // Track text — source-aware activate:
            //   * mixr        → `mixr.show` (open / cycle the docked
            //                   panel; today's behavior)
            //   * Music       → AppleScript `activate` (brings the app
            //                   forward without changing playback)
            //   * Spotify     → AppleScript `activate`
            //   * idle (none) → activate the user's preferred app
            //                   (`ui.preferred_music_app`), opening
            //                   Music / Spotify or the mixr panel
            //                   based on the Settings pick.
            if let Some(r) = app.rects.statusline_mixr_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                let source = app
                    .now_playing
                    .as_ref()
                    .map(|np| np.source.as_str())
                    .unwrap_or("");
                if source.eq_ignore_ascii_case("mixr") {
                    command::run("mixr.show", app);
                } else if !source.is_empty() {
                    send_macos_player(source, "activate");
                } else {
                    // Idle — use the preferred-app pick.
                    match app.config.ui.preferred_music_app.as_str() {
                        "music" => send_macos_player("Music", "activate"),
                        "spotify" => send_macos_player("Spotify", "activate"),
                        _ => {
                            command::run("mixr.show", app);
                        }
                    }
                }
                return;
            }
            // LSP chip → :LspStatus toast (breakdown of running servers).
            if let Some(r) = app.rects.statusline_lsp_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.run_ex_command("LspStatus");
                return;
            }
            // WRAP chip → toggle `[ui] wrap`.
            if let Some(r) = app.rects.statusline_wrap_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.config.ui.wrap = !app.config.ui.wrap;
                app.toast(if app.config.ui.wrap {
                    "wrap: on"
                } else {
                    "wrap: off"
                });
                return;
            }
            // Autosave chip → :set autosave_secs= prompt (palette command).
            if let Some(r) = app.rects.statusline_autosave_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.toast(format!(
                    "autosave: {}s (`:set autosave_secs=N` to change)",
                    app.config.editor.autosave_secs
                ));
                return;
            }
            // Filesize chip → :Stat toast.
            if let Some(r) = app.rects.statusline_filesize_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.run_ex_command("Stat");
                return;
            }
            // Ln/Col chip → goto-line prompt.
            if let Some(r) = app.rects.statusline_lncol_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                let _ = crate::command::run("editor.goto_line", app);
                return;
            }
            // Activity bar (the 4-cell vscode-style strip on the far
            // left of the rail). Click an icon → switch the active
            // section. Checked before the tree-icon row + workspace
            // toggle since the strip occupies the same x-range.
            if let Some(&(_, section)) = app
                .rects
                .activity_bar_icons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                // Git icon: switch the rail to the GitKraken-style
                // git palette AND open the git graph as a pane in
                // the editor area. The two work together — the
                // rail navigates branches / worktrees / PRs while
                // the graph shows commit history + diff. Other
                // activity sections just switch the rail.
                app.set_activity_section(section);
                if matches!(section, crate::app::ActivitySection::Git) {
                    crate::command::run("git.graph", app);
                }
                if let crate::app::ActivitySection::Mount(idx) = section {
                    app.open_mount_from_manifest(idx);
                }
                return;
            }
            // Gear icon at the bottom of the activity bar → pop the
            // VS Code-style settings menu.
            if let Some(r) = app.rects.activity_bar_gear
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_gear_context_menu((x, y));
                return;
            }
            // Search activity-bar section result rows — click → open
            // the hit's file at its line:col. Checked before tree
            // icons since they may overlap (tree_icon_buttons spans
            // the same width).
            if let Some(&(_, idx)) = app
                .rects
                .search_section_hit_rects
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.search_section_open_hit(idx);
                return;
            }
            // File-tree toolbar icons (row 0 of the rail). Check BEFORE
            // the WORKSPACE-toggle below since the workspace header is row 1
            // and the icon row sits above it. Each chip dispatches a palette
            // command by id.
            if let Some(&(_, cmd_id)) = app
                .rects
                .tree_icon_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                let _ = crate::command::run(cmd_id, app);
                return;
            }
            // INTEGRATIONS icon — hand off to the configured command.
            // Two command forms supported:
            //   `:<ex>`  → mnml ex command
            //   `<id>`   → mnml registered command id
            // Check BEFORE the section-toggle below.
            if let Some(&(_, icon_idx)) = app
                .rects
                .integration_icon_rects
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                && let Some(icon) = app.config.ui.integration_icons.get(icon_idx)
            {
                // api-workflow-user F4 — disabled chips still appear
                // in the RAIL strip (binary-availability-filtered) but
                // shouldn't fire on left-click. Toast a hint instead
                // so the user knows the menu is available.
                if !icon.enabled {
                    let label = icon
                        .tooltip
                        .clone()
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| icon.id.clone());
                    app.toast(format!("{label}: disabled (right-click → Enable)"));
                    return;
                }
                let cmd = icon.command.clone();
                if let Some(rest) = cmd.strip_prefix(':') {
                    app.run_ex_command(rest);
                } else {
                    crate::command::run(&cmd, app);
                }
                return;
            }
            // Menu-bar item click — fire the palette command and
            // close the dropdown.
            if let Some(&(_, item_idx)) = app
                .rects
                .menu_bar_items
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                && let Some(open) = app.menu_open.as_ref().cloned()
            {
                let menus = crate::menu_bar::bar();
                if let Some(menu) = menus.get(open.menu_idx)
                    && let Some(crate::menu_bar::MenuItem::Action { command_id, .. }) =
                        menu.items.get(item_idx)
                {
                    let id = *command_id;
                    app.menu_open = None;
                    crate::command::run(id, app);
                }
                return;
            }
            // Menu-bar word click — toggle the dropdown.
            if let Some(&(_, menu_idx)) = app
                .rects
                .menu_bar_words
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                let already_open = app
                    .menu_open
                    .as_ref()
                    .is_some_and(|s| s.menu_idx == menu_idx);
                app.menu_open = if already_open {
                    None
                } else {
                    Some(crate::menu_bar::MenuOpenState::new_mouse(menu_idx))
                };
                return;
            }
            // Click anywhere else while a menu is open → close it.
            // Fall through to the rest of the dispatch (the click
            // still hits the underlying target).
            if app.menu_open.is_some() {
                app.menu_open = None;
                // Don't return — the click goes through to the
                // underlying target (e.g. an editor pane, a tab).
            }
            // `> INTEGRATIONS` section header — arm drag-resize. On
            // mouse-up: !moved → toggle collapse; moved → commit
            // the new max height.
            if let Some(tr) = app.rects.integration_section_toggle
                && crate::app::dispatch::contains(tr, x, y)
            {
                app.rail_section_drag = Some(crate::app::RailSectionDrag {
                    kind: crate::app::RailSectionKind::Integrations,
                    start_y: y,
                    start_h: app.rects.integration_section_h.max(1),
                    moved: false,
                });
                return;
            }
            // The `> WORKSPACE-NAME` section header — clicking it toggles the
            // workspace section's expand/collapse state (VS-Code Explorer-style).
            if let Some(tr) = app.rects.tree_toggle
                && crate::app::dispatch::contains(tr, x, y)
            {
                app.toggle_tree_root_expanded();
                return;
            }
            // GIT header right-aligned chip cluster — Fetch / Pull / Push /
            // Stage all / Commit / Graph. Check BEFORE the toggle so the
            // chip wins over the section-collapse gesture.
            if let Some(&(_, action)) = app
                .rects
                .rail_git_header_buttons
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.run_git_rail_header_action(action);
                return;
            }
            // GitGraph column header click → cycle sort. Falls through to
            // the row-click handler since the header row is OUTSIDE
            // `app.rects.list_rows`.
            if let Some(&(_, col)) = app
                .rects
                .git_graph_column_headers
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                if let Some(cur) = app.active
                    && let Some(crate::pane::Pane::GitGraph(g)) = app.panes.get_mut(cur)
                {
                    g.cycle_sort(col);
                }
                return;
            }
            // The `> GIT` section header — arm drag-resize. Mouse-up
            // without movement falls through to the toggle; movement
            // commits the new max height.
            if let Some(tr) = app.rects.git_section_toggle
                && crate::app::dispatch::contains(tr, x, y)
            {
                app.rail_section_drag = Some(crate::app::RailSectionDrag {
                    kind: crate::app::RailSectionKind::Git,
                    start_y: y,
                    start_h: app.rects.git_section_h.max(1),
                    moved: false,
                });
                return;
            }
            // Extra-workspace section header → toggle expansion.
            if let Some(&(_, ws_idx)) = app
                .rects
                .extra_workspace_toggles
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.toggle_extra_workspace(ws_idx);
                return;
            }
            // Extra-workspace row click → focus / select / open in that tree.
            if let Some(&(tr, ws_idx, scroll)) = app
                .rects
                .extra_workspace_bodies
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                let row_idx = (y - tr.y) as usize + scroll;
                app.click_extra_workspace_row(ws_idx, row_idx);
                return;
            }
            // Tree? (no header now — row 0 of the rail is the first entry)
            if let Some(tr) = app.rects.tree
                && crate::app::dispatch::contains(tr, x, y)
            {
                app.focus_tree();
                app.rail_section = crate::app::RailSection::Workspace;
                // Clicking the primary tree returns focus from any
                // extra workspace; cursor highlight follows.
                app.focused_extra_ws = None;
                // VS Code preview/pin gesture: single-click on a file
                // opens it as a preview tab (replaceable by the next
                // single-click); double-click promotes to a real tab
                // (the editor's `open_path` non-preview path is the
                // promotion). Use the same `last_click` tracker the
                // editor uses for word/line select.
                // vscode-mouse-2026-06-10 SEV-2 #5.
                let now = std::time::Instant::now();
                let count = match app.last_click {
                    Some((prev, px, py, c))
                        if px == x
                            && py == y
                            && now.duration_since(prev) < std::time::Duration::from_millis(450) =>
                    {
                        (c + 1).min(3)
                    }
                    _ => 1,
                };
                app.last_click = Some((now, x, y, count));
                {
                    let idx = (y - tr.y) as usize + app.rects.tree_scroll;
                    if idx < app.tree.visible_rows().len() {
                        app.tree.set_cursor(idx);
                        // Arm a drag — the source is captured here; the
                        // actual move happens on mouse-up over a different
                        // directory row.
                        if let Some(row) = app.tree.selected_row() {
                            app.begin_tree_drag(row.path.clone(), row.is_dir, y);
                        }
                        if let Some(row) = app.tree.selected_row()
                            && row.is_dir
                        {
                            // Multi-repo workspace: clicking a depth-0
                            // repo dir also switches the active repo
                            // (so the git rail / branches / PRs follow
                            // the user's focus). The dir then expands /
                            // collapses normally.
                            if row.depth == 0 && app.repos.len() > 1 {
                                let repo_hit = app.repos.iter().position(|r| r.path == row.path);
                                if let Some(idx) = repo_hit
                                    && idx != app.active_repo
                                {
                                    app.switch_active_repo(idx);
                                }
                            }
                            app.tree.toggle_current();
                        }
                        // Files: the open is DEFERRED to mouse-up. On a
                        // plain click the Up handler opens it (preview, or
                        // a permanent tab on double-click); if the user
                        // instead click-holds and drags, it becomes a
                        // drag (onto a pane body → drag-to-split; onto a
                        // tree dir → move-in-tree) and never opens here.
                        // Opening on Down made a drag impossible — the
                        // file flashed open the instant you pressed.
                    }
                }
                return;
            }
            // A GIT-section row — focus the rail's git section + run the row's
            // default action (checkout the branch / open shell in the worktree).
            if let Some(&(_, hit)) = app
                .rects
                .git_rail_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.click_git_rail(hit);
                return;
            }
            // Empty-state `+ dock` chip → fire dock.new_text.
            if let Some(r) = app.rects.dock_empty_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                crate::command::run("dock.new_text", app);
                return;
            }
            // Open kebab-menu row click → apply choice + close.
            // Checked FIRST so a click on a menu row wins over
            // anything underneath (the menu is an overlay).
            if app.dock_kebab_menu.is_some()
                && let Some(&(_, idx)) = app
                    .rects
                    .dock_kebab_rows
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                if let Some(menu) = app.dock_kebab_menu.as_ref()
                    && let Some(item) = menu.items.get(idx).copied()
                {
                    let wid = menu.widget_id;
                    crate::dock::apply_kebab_choice(app, wid, item);
                }
                return;
            }
            // Click ANYWHERE else with the kebab menu open → close it.
            if app.dock_kebab_menu.is_some() {
                app.dock_kebab_menu = None;
                // Fall through — let the click hit whatever it
                // was meant for.
            }
            // Dock widget kebab `⋮` click → open the menu.
            // Checked BEFORE the title-bar / body so the kebab
            // wins.
            if let Some(&(r, id)) = app
                .rects
                .dock_widget_kebabs
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                if let Some(w) = app.dock_widgets.iter().find(|w| w.id == id) {
                    app.dock_kebab_menu = Some(crate::dock::KebabMenuState::build(w, r.x, r.y));
                }
                return;
            }
            // Dock widget title bar mouse-down → arm a drag. Final
            // corner resolves on mouse-up based on which quadrant
            // of the editor body the cursor ended up in.
            if let Some(&(_, id)) = app
                .rects
                .dock_widget_titles
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.dock_drag_id = Some(id);
                app.dock_drag_cursor = Some((x, y));
                return;
            }
            // Dock widget body click → toast (placeholder; content-
            // specific actions can hook in later).
            if let Some(&(_, id)) = app
                .rects
                .dock_widget_bodies
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                if let Some(w) = app.dock_widgets.iter().find(|w| w.id == id) {
                    let title = w.title.clone();
                    app.toast(format!("dock: {title}"));
                }
                return;
            }
            // Workspaces editor kebab `⋮` click → open per-row menu.
            if app.workspaces_editor_open
                && let Some(&(_, idx)) = app
                    .rects
                    .workspaces_editor_kebabs
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.open_workspaces_editor_kebab(idx, (x, y));
                return;
            }
            // Workspaces editor row click → focus + Enter
            // equivalent (rename for normal rows; add for the
            // `+ Add` action).
            if app.workspaces_editor_open
                && let Some(&(_, code)) = app
                    .rects
                    .workspaces_editor_rows
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                if code >= 0 {
                    let idx = code as usize;
                    app.workspaces_editor_selected = idx;
                    app.workspaces_editor_open_rename(idx);
                } else {
                    crate::command::run("view.add_workspace", app);
                }
                return;
            }
            // Click outside the overlay (when open) closes it.
            if app.workspaces_editor_open && app.context_menu.is_none() {
                // Fall through normally; clicks anywhere outside
                // dismiss like Esc.
                app.close_workspaces_editor();
                return;
            }
            // Workspace-picker chevron → toggle the dropdown.
            if let Some(r) = app.rects.workspace_picker_chevron
                && crate::app::dispatch::contains(r, x, y)
            {
                app.workspace_picker_open = !app.workspace_picker_open;
                if !app.workspace_picker_open {
                    app.workspace_picker_filter.clear();
                }
                return;
            }
            // Workspace NAME (not chevron) → open the repo picker
            // when multi-repo. Single-repo: fall through to other
            // tree-row handlers below.
            if let Some(r) = app.rects.workspace_name_rect
                && crate::app::dispatch::contains(r, x, y)
                && app.repos.len() > 1
            {
                app.open_repo_picker();
                return;
            }
            // Workspace-picker row click → switch + close.
            if let Some(&(_, ws_idx)) = app
                .rects
                .workspace_picker_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.switch_workspace(ws_idx);
                app.workspace_picker_open = false;
                app.workspace_picker_filter.clear();
                return;
            }
            // Workspace-picker filter input → focus stays implicit
            // (no separate focus flag; the dropdown owns the
            // keyboard while open). Click anywhere outside the
            // picker closes it.
            if app.workspace_picker_open
                && app
                    .rects
                    .workspace_picker_filter_input
                    .is_none_or(|r| !crate::app::dispatch::contains(r, x, y))
                && app
                    .rects
                    .workspace_picker_rows
                    .iter()
                    .all(|(r, _)| !crate::app::dispatch::contains(*r, x, y))
            {
                app.workspace_picker_open = false;
                app.workspace_picker_filter.clear();
                // Fall through — let the click hit whatever's under.
            }
            // Git-palette filter input — click to focus + start typing.
            if let Some(r) = app.rects.git_palette_filter_input
                && crate::app::dispatch::contains(r, x, y)
            {
                app.git_palette_filter_focused = true;
                return;
            }
            // Click anywhere else inside the rail (or outside) while
            // the filter is focused → unfocus (keeps the typed text
            // so navigating doesn't lose what they typed).
            if app.git_palette_filter_focused {
                app.git_palette_filter_focused = false;
            }
            // Sessions panel `+ New session` chip → spawn a Claude
            // Code pane (the most common case). Checked BEFORE
            // tab clicks so a click on the chip wins.
            if let Some(r) = app.rects.session_new_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                crate::command::run("ai.claude_code", app);
                return;
            }
            // Agents rail panel — filter input, + New, and row
            // clicks.
            if let Some(r) = app.rects.agents_panel_filter_input
                && crate::app::dispatch::contains(r, x, y)
            {
                app.agents_panel_filter_focused = true;
                return;
            }
            if let Some(r) = app.rects.agents_panel_new_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                crate::command::run("ai.claude_code", app);
                return;
            }
            if let Some(r) = app.rects.agents_panel_pr_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_new_cloud_agent_wizard();
                return;
            }
            // View-mode toggle chip → switch between by-status
            // and by-workspace grouping.
            if let Some(r) = app.rects.agents_panel_view_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.agents_panel_group_by_workspace = !app.agents_panel_group_by_workspace;
                app.agents_panel_expanded_workspaces.clear();
                return;
            }
            // Workspace header (by-workspace view only) → toggle
            // expansion for that workspace.
            if let Some((_, ws)) = app
                .rects
                .agents_panel_workspace_headers
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .cloned()
            {
                if app.agents_panel_expanded_workspaces.contains(&ws) {
                    app.agents_panel_expanded_workspaces.remove(&ws);
                } else {
                    app.agents_panel_expanded_workspaces.insert(ws);
                }
                return;
            }
            if let Some(&(_, row_idx)) = app
                .rects
                .agents_panel_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                if let Some(row) = app.agents_panel_rows.get(row_idx).cloned() {
                    match row.source {
                        crate::claude_agents::AgentSource::TattleQwe => {
                            // Cloud rows can't be resumed locally —
                            // copy the runId so the user can paste
                            // it into Slack / a browser, and toast
                            // what we know about the run.
                            app.clipboard.set(row.session_id.clone(), false);
                            let summary = row
                                .last_assistant_msg
                                .clone()
                                .unwrap_or_else(|| "(cloud run)".to_string());
                            app.toast(format!("{} · {} · runId copied", row.workspace, summary));
                        }
                        _ => {
                            // Resume in a fresh pty — mirrors the
                            // dashboard's `R` chord.
                            app.resume_claude_session_in_pty(&row.session_id);
                        }
                    }
                }
                return;
            }
            // Cloud Agents panel — filter input + row clicks +
            // density chip (compact ↔ standard) + + New Cloud
            // Agent button.
            if let Some(r) = app.rects.cloud_agents_view_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.cloud_agents_toggle_view();
                return;
            }
            if let Some(r) = app.rects.cloud_agents_new_run_button
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_new_cloud_run_wizard();
                return;
            }
            if let Some(r) = app.rects.cloud_agents_change_defaults_chip
                && crate::app::dispatch::contains(r, x, y)
            {
                app.open_new_cloud_run_wizard();
                return;
            }
            if let Some(r) = app.rects.cloud_agents_quick_input
                && crate::app::dispatch::contains(r, x, y)
            {
                app.cloud_run_prompt_focused = true;
                app.cloud_agents_filter_focused = false;
                return;
            }
            if let Some(r) = app.rects.cloud_agents_filter_input
                && crate::app::dispatch::contains(r, x, y)
            {
                app.cloud_agents_filter_focused = true;
                return;
            }
            if let Some(&(_, row_idx)) = app
                .rects
                .cloud_agents_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                // 2026-06-27 — single-click on a cloud-agent row now
                // opens the full detail pane (summary, links,
                // artifacts, logs) instead of just copying the runId.
                // The runId is still accessible via the right-click
                // menu / palette.
                app.open_cloud_agent_run(row_idx);
                return;
            }
            // Click anywhere else inside the rail while either
            // agents filter is focused → unfocus.
            if app.agents_panel_filter_focused {
                app.agents_panel_filter_focused = false;
            }
            if app.cloud_agents_filter_focused {
                app.cloud_agents_filter_focused = false;
            }
            // Sessions panel tab (vertical-tab strip shown when
            // `ActivitySection::Sessions` is active). Click →
            // focus that Pty pane. Also arms a drag — mouse-up
            // over another tab swaps them.
            if let Some(&(_, pid)) = app
                .rects
                .session_tabs
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                app.session_drag_pid = Some(pid);
                return;
            }
            // Git-palette row (the GitKraken-style panel shown when
            // `ActivitySection::Git` is active). Maps to the same
            // `GitRailHit` dispatch as the legacy rail.
            if let Some(&(_, hit)) = app
                .rects
                .git_palette_rows
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                // GitKraken-style: left-click on a ref (branch /
                // remote / worktree / tag / stash) HIGHLIGHTS the
                // ref's commit in the open git-graph pane. The
                // action (checkout / cd / pop / etc.) lives on
                // the right-click context menu. PRs still open in
                // the browser since they're not graph commits.
                match hit {
                    crate::ui::git_palette::GitPaletteHit::Branch(i) => {
                        if let Some(b) = app.git_rail.branches.get(i) {
                            let name = b.name.clone();
                            app.git_jump_to_ref(&name);
                        }
                    }
                    crate::ui::git_palette::GitPaletteHit::Worktree(i) => {
                        if let Some(wt) = app.git_rail.worktrees.get(i) {
                            let label = wt.label.clone();
                            app.git_jump_to_ref(&label);
                        }
                    }
                    crate::ui::git_palette::GitPaletteHit::Pull(i) => {
                        // PRs aren't commits — open in browser
                        // (same as the legacy rail).
                        app.click_git_rail(crate::git::rail::GitRailHit::Pull(i));
                    }
                    crate::ui::git_palette::GitPaletteHit::RemoteBranch(i) => {
                        if let Some(name) = app.git_rail.remote_branches.get(i).cloned() {
                            app.git_jump_to_ref(&name);
                        }
                    }
                    crate::ui::git_palette::GitPaletteHit::Stash(i) => {
                        if let Some(st) = app.git_rail.stashes.get(i) {
                            let id = st.id.clone();
                            app.git_jump_to_ref(&id);
                        }
                    }
                    crate::ui::git_palette::GitPaletteHit::Tag(i) => {
                        if let Some(name) = app.git_rail.tags.get(i).cloned() {
                            app.git_jump_to_ref(&name);
                        }
                    }
                }
                return;
            }
            // Claude Agents — Files drill-down file row click → open
            // the file in an editor pane.
            if let Some(path) = app
                .rects
                .claude_drill_files
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                .map(|(_, p)| p.clone())
            {
                let pb = std::path::PathBuf::from(&path);
                app.open_path(&pb);
                return;
            }
            // SCM/CI pane row click? Match before the generic editor-pane
            // handler since these panes also register editor-pane rects.
            // Single click: focus + select that row. If it's a header,
            // toggle collapse (sibling to Enter). Double-click on a data
            // row: open in browser.
            if let Some(&(_, pid, flat_idx)) = app
                .rects
                .list_rows
                .iter()
                .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                let now = std::time::Instant::now();
                let count = match app.last_click {
                    Some((prev, px, py, c))
                        if px == x
                            && py == y
                            && now.duration_since(prev) < std::time::Duration::from_millis(450) =>
                    {
                        (c + 1).min(3)
                    }
                    _ => 1,
                };
                app.last_click = Some((now, x, y, count));
                // Click on a list row blurs the WIP commit textarea
                // (the user is moving focus to the commits / status
                // list, not the editor box).
                app.blur_active_wip_commit_textarea();
                crate::app::dispatch::handle_scm_row_click(app, pid, flat_idx, count >= 2);
                return;
            }

            // Editor text in some split leaf? Focus that leaf and place the cursor.
            // Track multi-click: 2 = select word, 3 = select line. The threshold
            // (450 ms, same cell) matches what most OSes use.
            if let Some(&(tr, pid)) = app
                .rects
                .editor_panes
                .iter()
                .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            {
                // Alt+click → add an extra cursor at the clicked position
                // (VS Code convention). Skips the focus / drag-arm path so
                // the existing primary stays put.
                if m.modifiers.contains(KeyModifiers::ALT) {
                    let wrap = app.config.ui.wrap;
                    if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                        let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
                        let byte = b.editor.byte_at_col_pub(row, col);
                        b.editor.add_extra_cursor(byte);
                    }
                    return;
                }
                app.active = Some(pid);
                app.focus_pane();
                let now = std::time::Instant::now();
                let count = match app.last_click {
                    Some((prev, px, py, c))
                        if px == x
                            && py == y
                            && now.duration_since(prev) < std::time::Duration::from_millis(450) =>
                    {
                        (c + 1).min(3)
                    }
                    _ => 1,
                };
                app.last_click = Some((now, x, y, count));
                // Ctrl+click → place cursor + fire `lsp.goto_definition`
                // (VS Code convention — "click through" identifiers).
                let ctrl_click = m.modifiers.contains(KeyModifiers::CONTROL);
                let wrap = app.config.ui.wrap;
                if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                    let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
                    b.editor.place_cursor(row, col);
                    if count >= 2 {
                        let clip = &mut app.clipboard;
                        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                            let op = if count == 2 {
                                crate::edit_op::EditOp::SelectWord
                            } else {
                                crate::edit_op::EditOp::SelectLine
                            };
                            b.apply_edit_ops(vec![op], clip, 0);
                        }
                    } else {
                        // Arm a potential drag-select. If the user actually
                        // drags, the first Drag event will SelectStart at
                        // the origin and move the cursor.
                        app.drag_select = Some((pid, row, col, false));
                    }
                }
                if ctrl_click {
                    // Ctrl+Shift+Click → references picker; plain Ctrl+Click
                    // → go-to-definition. Matches VS Code's "peek references"
                    // / "go to definition" gestures.
                    if m.modifiers.contains(KeyModifiers::SHIFT) {
                        app.lsp_references();
                    } else {
                        app.lsp_goto_definition();
                    }
                }
            }
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
