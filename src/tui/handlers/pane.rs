//! Pane key handlers (T-4 of the file-split refactor — 2026-06-28).
//! Owns `handle_tree_key` (rail), `handle_pane_key` (per-pane router),
//! `handle_md_preview_key` / `handle_diff_key` / `handle_request_key`,
//! plus the `is_view_only_pane` predicate.
//!
//! Extracted from `src/tui/mod.rs`. These are stateless dispatchers —
//! every effect flows through `App` methods so the move is mechanical.
//! `handle_tree_key` recurses into `handle_pane_key` for focus shifts;
//! both stay in this file so the call doesn't cross modules.

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::app::App;
use crate::buffer::BufferEvent;
use crate::pane::Pane;

pub(crate) fn handle_tree_key(app: &mut App, key: KeyEvent) {
    // The rail has two sections (workspace + git). Route the key to the one
    // the keyboard is parked on; the cursor crosses the boundary on ↓ off the
    // bottom of workspace or ↑ off the top of git.
    if app.rail_section == crate::app::RailSection::Git {
        // qa-feature 2026-06-30 — PageUp/PageDown on the rail
        // forward to the active GitGraph pane's selection so the
        // user doesn't have to click into the graph to scroll it
        // with the keyboard.
        if matches!(key.code, KeyCode::PageUp | KeyCode::PageDown) {
            let is_pgup = matches!(key.code, KeyCode::PageUp);
            if let Some(idx) = app.active
                && let Some(crate::pane::Pane::GitGraph(g)) = app.panes.get_mut(idx)
            {
                // Approximate viewport = 20 rows; the actual height
                // depends on pane layout but 20 matches the
                // pane-key handler's semantics for uninstrumented
                // cases.
                let step = 20isize;
                g.move_selection(if is_pgup { -step } else { step });
                return;
            }
        }
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => app.git_rail_move_up(),
            KeyCode::Down | KeyCode::Char('j') => app.git_rail_move_down(),
            KeyCode::Enter | KeyCode::Char(' ') => app.git_rail_activate(),
            // Esc / Left / `h` / Tab return to the workspace section.
            // Tab is the explicit cross-section affordance — symmetric
            // with the Tab from workspace below.
            KeyCode::Esc | KeyCode::Left | KeyCode::Char('h') | KeyCode::Tab => {
                app.rail_section = crate::app::RailSection::Workspace;
            }
            KeyCode::Char('R') => app.git_rail.refresh(&app.workspace.clone()),
            KeyCode::Home | KeyCode::Char('g') => app.git_rail.set_cursor(0),
            KeyCode::End | KeyCode::Char('G') => app.git_rail.set_cursor(usize::MAX),
            _ => {}
        }
        return;
    }
    // Filter mode — printable chars build the query; Backspace pops; Enter
    // exits filter mode (keeping the filter); Esc clears + exits.
    if app.tree.filter_mode {
        match key.code {
            KeyCode::Esc => app.tree.filter_clear_and_exit(),
            KeyCode::Enter => app.tree.filter_mode = false,
            KeyCode::Backspace => app.tree.filter_pop(),
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.tree.filter_push(c);
            }
            _ => {}
        }
        return;
    }
    // `Ctrl+W` from tree focus — vim window-prefix chord. Return focus
    // to the active editor pane so the next key (h/l/j/k/w/c) is
    // handled by the buffer's vim handler's Prefix::Window chain.
    // Without this, vim users would `Ctrl+W` from the tree and then
    // press `l` expecting "focus right pane" — but `l` got eaten by
    // the tree's expand_or_descend handler. nvchad-user-2026-06-10
    // S2-07.
    if key.code == KeyCode::Char('w') && key.modifiers.contains(KeyModifiers::CONTROL) {
        if app.active.is_some() {
            app.focus = crate::focus::Focus::Pane;
            // Forward the same Ctrl+W to the now-focused pane so its
            // handler enters window-nav mode. Standard / VS Code
            // treats Ctrl+W as buffer.close — re-dispatching it from
            // tree focus might close the active editor, which the
            // user didn't ask for.
            if app.ctrl_w_is_window_nav() {
                handle_pane_key(app, key);
            }
        }
        return;
    }
    // File-manager clipboard shortcuts — Ctrl+X/C/V/D from tree
    // focus map to the same commands the palette exposes. Tree
    // focus never edits text, so these don't fight the standard-
    // input meanings of Ctrl+X/C (which fire only from pane focus).
    if key.modifiers.contains(KeyModifiers::CONTROL) {
        match key.code {
            KeyCode::Char('x') => {
                crate::command::run("file.cut", app);
                return;
            }
            KeyCode::Char('c') => {
                crate::command::run("file.copy", app);
                return;
            }
            KeyCode::Char('v') => {
                crate::command::run("file.paste", app);
                return;
            }
            KeyCode::Char('d') => {
                crate::command::run("file.duplicate", app);
                return;
            }
            _ => {}
        }
    }
    // Note: the no_pane_cmdline keystroke gate lives in
    // `dispatch_key` above so it's enforced regardless of focus —
    // an opened cmdline owns input even when the user started
    // typing from the pane side. The tree handler only sees keys
    // when the cmdline is closed.
    match key.code {
        // `:` from tree focus → open the no-pane cmdline at the
        // bottom of the window. Same vim-style affordance the
        // in-buffer cmdline provides; user-reported 2026-06-18 that
        // having it render in the center looked inconsistent.
        KeyCode::Char(':') => {
            app.open_ex_command_prompt();
        }
        KeyCode::Char('/') => {
            app.tree.filter_mode = true;
        }
        KeyCode::Up | KeyCode::Char('k') => {
            if let Some(ws_idx) = app.focused_extra_ws
                && let Some(ws) = app.extra_workspaces.get_mut(ws_idx)
            {
                ws.tree.move_up();
            } else {
                app.tree.move_up();
            }
            // qa-feature 2026-07-01 — VS Code-style preview:
            // arrowing over a file loads it into the preview
            // pane, focus stays in the tree so the user can
            // keep arrowing to browse. Enter still opens fully
            // + shifts focus.
            preview_selected_tree_file(app);
        }
        KeyCode::Down | KeyCode::Char('j') => {
            if let Some(ws_idx) = app.focused_extra_ws
                && let Some(ws) = app.extra_workspaces.get_mut(ws_idx)
            {
                ws.tree.move_down();
            } else {
                app.tree.move_down();
            }
            preview_selected_tree_file(app);
        }
        // Tab is the explicit cross-section affordance — flips into the
        // git rail (when expanded + non-empty) and back. Replaces the
        // earlier ↓-at-bottom auto-flip behaviour, which silently spawned
        // terminals on Enter when the user's tree cursor "auto-moved"
        // into a Worktree row without their realising — `git_rail_activate`
        // on a Worktree fires `open_worktree_shell`. vscode-keyboard-
        // 2026-06-10 S2-09.
        KeyCode::Tab => {
            if app.git_section_expanded && !app.git_rail.is_empty() {
                app.rail_section = crate::app::RailSection::Git;
                app.git_rail.set_cursor(0);
            } else {
                app.toast("git rail not visible — toggle with the `git` chip");
            }
        }
        KeyCode::Right | KeyCode::Char('l') => {
            app.tree.expand_or_descend();
            preview_selected_tree_file(app);
        }
        KeyCode::Left | KeyCode::Char('h') => {
            app.tree.collapse_or_ascend();
            preview_selected_tree_file(app);
        }
        KeyCode::Enter | KeyCode::Char(' ') => app.tree_activate(),
        KeyCode::Char('R') => app.tree.refresh(),
        KeyCode::Home | KeyCode::Char('g') => {
            app.tree.set_cursor(0);
            preview_selected_tree_file(app);
        }
        KeyCode::End | KeyCode::Char('G') => {
            app.tree.set_cursor(usize::MAX);
            preview_selected_tree_file(app);
        }
        // When there's a sticky filter, Esc clears it before yielding focus.
        KeyCode::Esc if !app.tree.filter.is_empty() => app.tree.filter_clear_and_exit(),
        _ => {}
    }
}

/// qa-feature 2026-07-01 — VS Code-style tree preview. When the
/// cursor lands on a FILE row (primary or focused extra), open it
/// as a preview pane but keep focus on the tree so the user can
/// keep arrowing. No-op on dir rows. Callers should invoke this
/// after each move_up/move_down in the tree section. Only fires
/// when the "standard" input style is active (vim users don't
/// have preview panes by design — every file is its own tab).
fn preview_selected_tree_file(app: &mut App) {
    if app.config.editor.input_style != "standard" {
        return;
    }
    let selected: Option<std::path::PathBuf> = if let Some(ws_idx) = app.focused_extra_ws {
        app.extra_workspaces
            .get(ws_idx)
            .and_then(|ws| ws.tree.selected_file())
    } else {
        app.tree.selected_file()
    };
    let Some(path) = selected else {
        return;
    };
    app.open_path_preview(&path);
    // open_path_preview → open_path_inner → reveal_pane sets
    // Focus::Pane. Restore Focus::Tree so subsequent arrow keys
    // continue routing to the tree handler.
    app.focus_tree();
}

/// True for panes that should let `:` and `Ctrl+W` (the vim
/// ex-cmdline + window prefix) fall through to global handlers
/// before the per-pane key dispatcher runs. These are "view"
/// panes — the user isn't typing into them as a text-input
/// surface. Editor / Pty / Request / Browser / Ai / Websocket
/// keep their own input semantics. (The Request pane's bare
/// `r` / `a` reflex collisions are a separate finding —
/// `nvchad-request-pane-r-refires-a-spawns-ai`.)
fn is_view_only_pane(pane: Option<&Pane>) -> bool {
    matches!(
        pane,
        Some(Pane::Diagnostics(_))
            | Some(Pane::Cheatsheet(_))
            | Some(Pane::ClaudeAgents(_))
            | Some(Pane::Grep(_))
            | Some(Pane::Quickfix(_))
            | Some(Pane::CmdlineHistory(_))
            | Some(Pane::Outline(_))
            | Some(Pane::Tests(_))
            | Some(Pane::Flaky(_))
            | Some(Pane::Debug(_))
    )
}

pub(crate) fn handle_pane_key(app: &mut App, key: KeyEvent) {
    let viewport = crate::app::dispatch::pane_viewport(app);
    // keyboard-round-7 SEV-2 #1 — when focus is on the right panel,
    // route keys to the right-panel's active pane instead of the
    // main pane. The main pane index (`app.active`) is left alone
    // so Ctrl+E can cycle back.
    let Some(i) = (if app.focus == crate::focus::Focus::RightPanel {
        app.right_panel_active_pane_id().or(app.active)
    } else {
        app.active
    }) else {
        return;
    };
    // 2026-06-21 — nvchad SEV-1: every special-purpose pane has its
    // own `_ => {}` fall-through that ate Ctrl+W (vim window prefix)
    // and `:` (ex cmdline), so vim users lost both reflexes anywhere
    // outside the editor. Intercept BEFORE per-pane dispatch when
    // the active pane is a non-editor "view" pane (no text-input
    // role; Pty / Editor / Request / Browser / Pane::Ai keep their
    // own input semantics — the Request pane's bare `r` reflex is
    // a separate finding).
    if is_view_only_pane(app.panes.get(i)) {
        // `:` → open ex-command prompt, same as the tree handler.
        if matches!(key.code, KeyCode::Char(':')) && !key.modifiers.contains(KeyModifiers::CONTROL)
        {
            app.open_ex_command_prompt();
            return;
        }
        // Ctrl+W → if the current style treats it as window-nav,
        // jump to the first editor pane and re-dispatch so its
        // handler enters Prefix::Window. Standard / VS Code
        // treats Ctrl+W as buffer.close — skip.
        if key.code == KeyCode::Char('w')
            && key.modifiers.contains(KeyModifiers::CONTROL)
            && app.ctrl_w_is_window_nav()
        {
            if let Some(editor_id) = app.panes.iter().position(|p| matches!(p, Pane::Editor(_))) {
                app.active = Some(editor_id);
                app.focus = crate::focus::Focus::Pane;
                handle_pane_key(app, key);
            }
            return;
        }
    }
    if handle_md_preview_key(app, key, viewport, i) {
        return;
    }
    if handle_diff_key(app, key, viewport, i) {
        return;
    }
    if handle_request_key(app, key, viewport, i) {
        return;
    }
    // A tests pane: ↑↓ select, Enter → jump to the test's source, t → open the
    // selected test's trace, r re-run (same args), a/f run all/file, R re-run
    // last-failed, h heal-with-Claude, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::Tests(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => app.tests_move_selection(-1),
            KeyCode::Down | KeyCode::Char('j') => app.tests_move_selection(1),
            KeyCode::PageUp => {
                if let Some(Pane::Tests(t)) = app.panes.get_mut(i) {
                    t.scroll = t.scroll.saturating_sub(viewport);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::Tests(t)) = app.panes.get_mut(i) {
                    t.scroll += viewport;
                }
            }
            KeyCode::Char('g') => {
                if let Some(Pane::Tests(t)) = app.panes.get_mut(i) {
                    t.scroll = 0;
                }
            }
            KeyCode::Char('G') => {
                if let Some(Pane::Tests(t)) = app.panes.get_mut(i) {
                    t.scroll = usize::MAX;
                }
            }
            KeyCode::Enter => app.jump_to_selected_test(),
            KeyCode::Char('t') => app.open_selected_test_trace(),
            KeyCode::Char('r') => app.rerun_active_tests(),
            KeyCode::Char('R') => app.rerun_failed_tests(),
            KeyCode::Char('a') => app.run_tests_all(),
            KeyCode::Char('f') => app.run_tests_file(),
            KeyCode::Char('h') => app.heal_selected_test(),
            KeyCode::Char('s') => {
                if let Some(Pane::Tests(t)) = app.panes.get_mut(i) {
                    t.sort = t.sort.next();
                    t.scroll = 0; // sort changed — start from the top
                }
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // A browser pane (Chrome driven over CDP): scroll the console log, `n` toggles
    // the selectable network panel (then ↑↓ select, `y` copy-as-curl, Enter →
    // re-send in a request pane), `g` navigate, `e` eval JS, `r` reload, Esc →
    // (leave the net panel, else) tree. `Ctrl+W` closes it (which kills Chrome).
    if matches!(app.panes.get(i), Some(Pane::Browser(_))) {
        let (
            net_focus,
            dom_focus,
            cookies_focus,
            storage_focus,
            perf_focus,
            net_filter_mode,
            dom_filter_mode,
            cookies_filter_mode,
            storage_filter_mode,
        ) = match app.panes.get(i) {
            Some(Pane::Browser(b)) => (
                b.net_focus,
                b.dom_focus,
                b.cookies_focus,
                b.storage_focus,
                b.perf_focus,
                b.net_filter_mode,
                b.dom_filter_mode,
                b.cookies_filter_mode,
                b.storage_filter_mode,
            ),
            _ => (
                false, false, false, false, false, false, false, false, false,
            ),
        };
        let any_panel = net_focus || dom_focus || cookies_focus || storage_focus || perf_focus;
        // Filter-mode on either panel takes priority over every
        // navigation chord — printable keys narrow the list instead
        // of moving the cursor.
        if net_filter_mode {
            match key.code {
                KeyCode::Esc => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.net_filter_clear_and_exit();
                    }
                }
                KeyCode::Enter => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.net_filter_mode = false;
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.net_filter_pop();
                    }
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.net_filter_push(c);
                    }
                }
                _ => {}
            }
            return;
        }
        if dom_filter_mode {
            match key.code {
                KeyCode::Esc => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.dom_filter_clear_and_exit();
                    }
                }
                KeyCode::Enter => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.dom_filter_mode = false;
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.dom_filter_pop();
                    }
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.dom_filter_push(c);
                    }
                }
                _ => {}
            }
            return;
        }
        if cookies_filter_mode {
            match key.code {
                KeyCode::Esc => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.cookies_filter_clear_and_exit();
                    }
                }
                KeyCode::Enter => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.cookies_filter_mode = false;
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.cookies_filter_pop();
                    }
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.cookies_filter_push(c);
                    }
                }
                _ => {}
            }
            return;
        }
        if storage_filter_mode {
            match key.code {
                KeyCode::Esc => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.storage_filter_clear_and_exit();
                    }
                }
                KeyCode::Enter => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.storage_filter_mode = false;
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.storage_filter_pop();
                    }
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.storage_filter_push(c);
                    }
                }
                _ => {}
            }
            return;
        }
        // In the net / DOM panel ↑↓/jk/PgUp/PgDn/g/G/Home/End move the row
        // selection; otherwise they scroll the log.
        let scroll_or_select = |app: &mut App, delta: isize, jump: Option<usize>| {
            if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                if b.dom_focus {
                    let n = b.visible_dom_indices().len();
                    match jump {
                        Some(usize::MAX) => b.set_dom_sel(n.saturating_sub(1)),
                        Some(n) => b.set_dom_sel(n),
                        None => b.move_dom_sel(delta),
                    }
                } else if b.net_focus {
                    let n = b.visible_net_indices().len();
                    match jump {
                        Some(usize::MAX) => b.net_sel = n.saturating_sub(1),
                        Some(n) => b.net_sel = n,
                        None => b.move_net_sel(delta),
                    }
                } else if b.cookies_focus {
                    // Selection indexes into the *filtered* list now;
                    // clamp against that count so a held filter doesn't
                    // get out-of-range jumps.
                    let n = b.visible_cookies_indices().len();
                    match jump {
                        Some(usize::MAX) => b.cookies_sel = n.saturating_sub(1),
                        Some(n2) => b.cookies_sel = n2,
                        None => b.move_cookies_sel(delta),
                    }
                } else if b.storage_focus {
                    let n = b.visible_storage_indices().len();
                    match jump {
                        Some(usize::MAX) => b.storage_sel = n.saturating_sub(1),
                        Some(n2) => b.storage_sel = n2,
                        None => b.move_storage_sel(delta),
                    }
                } else if b.snapshot_diff_open {
                    // Scroll the diff panel. usize::MAX clamps to end —
                    // the next render reclamps.
                    match jump {
                        Some(usize::MAX) => b.snapshot_diff_scroll = usize::MAX,
                        Some(n) => b.snapshot_diff_scroll = n,
                        None => {
                            let cur = b.snapshot_diff_scroll as isize;
                            b.snapshot_diff_scroll = (cur + delta).max(0) as usize;
                        }
                    }
                } else {
                    match jump {
                        Some(usize::MAX) => b.scroll = usize::MAX,
                        Some(n) => b.scroll = n,
                        None => {
                            b.scroll = if delta < 0 {
                                b.scroll.saturating_sub(delta.unsigned_abs())
                            } else {
                                b.scroll.saturating_add(delta as usize)
                            };
                        }
                    }
                }
            }
        };
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => scroll_or_select(app, -1, None),
            KeyCode::Down | KeyCode::Char('j') => scroll_or_select(app, 1, None),
            KeyCode::PageUp => scroll_or_select(app, -(viewport as isize), None),
            KeyCode::PageDown => scroll_or_select(app, viewport as isize, None),
            KeyCode::Home => scroll_or_select(app, 0, Some(0)),
            KeyCode::End | KeyCode::Char('G') => scroll_or_select(app, 0, Some(usize::MAX)),
            KeyCode::Char('g') if any_panel => scroll_or_select(app, 0, Some(0)),
            KeyCode::Char('n') => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.net_focus = !b.net_focus;
                    if b.net_focus {
                        b.dom_focus = false;
                        let n = b.visible_net_indices().len();
                        b.net_sel = b.net_sel.min(n.saturating_sub(1));
                    }
                }
            }
            KeyCode::Char('/') if net_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.net_filter_mode = true;
                }
            }
            KeyCode::Char('/') if dom_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.dom_filter_mode = true;
                }
            }
            KeyCode::Char('/') if cookies_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.cookies_filter_mode = true;
                }
            }
            KeyCode::Char('/') if storage_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.storage_filter_mode = true;
                }
            }
            KeyCode::Char('D') => app.browser_open_dom(),
            KeyCode::Char('R') if dom_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.fetch_dom();
                }
            }
            KeyCode::Char('y') if net_focus => app.copy_net_entry_curl(),
            KeyCode::Char('i') if net_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.net_detail_open = !b.net_detail_open;
                    b.net_detail_scroll = 0;
                }
            }
            // Scroll the detail panel — `j`/`k` are taken by row
            // selection, so use `]`/`[` (pager convention) for the
            // detail-scroll chord. usize::MAX clamp is fine — the
            // next render re-clamps against the actual line count.
            KeyCode::Char(']') if net_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i)
                    && b.net_detail_open
                {
                    b.scroll_net_detail(1, usize::MAX);
                }
            }
            KeyCode::Char('[') if net_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i)
                    && b.net_detail_open
                {
                    b.scroll_net_detail(-1, usize::MAX);
                }
            }
            KeyCode::Char('K') => app.browser_open_cookies(),
            KeyCode::Char('y') if cookies_focus => app.copy_cookie_name_value(),
            KeyCode::Char('c') if cookies_focus => app.copy_cookie_value_only(),
            KeyCode::Char('d') if cookies_focus => app.delete_selected_cookie(),
            KeyCode::Char('e') if cookies_focus => app.edit_selected_cookie(),
            KeyCode::Char('a') if cookies_focus => app.add_cookie_prompt(),
            KeyCode::Char('R') if cookies_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.fetch_cookies();
                }
            }
            KeyCode::Char('P') => app.browser_open_perf(),
            KeyCode::Char('R') if perf_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.fetch_perf();
                }
            }
            KeyCode::Char('L') => app.browser_open_storage(),
            KeyCode::Char('y') if storage_focus => app.copy_storage_key_value(),
            KeyCode::Char('c') if storage_focus => app.copy_storage_value_only(),
            KeyCode::Char('e') if storage_focus => app.edit_selected_storage(),
            KeyCode::Char('a') if storage_focus => app.add_storage_prompt(),
            KeyCode::Char('d') if storage_focus => app.delete_selected_storage(),
            KeyCode::Char('R') if storage_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.fetch_storage();
                }
            }
            KeyCode::Char('c') if dom_focus => app.copy_dom_selector(),
            KeyCode::Char('h') if dom_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.highlight_selected_dom();
                }
            }
            KeyCode::Char('H') if dom_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.toggle_dom_hover_highlight();
                }
            }
            KeyCode::Char('S') if dom_focus => app.browser_screenshot_node(),
            KeyCode::Char('Z') if dom_focus => app.browser_scroll_node_into_view(),
            KeyCode::Enter if net_focus => app.open_net_entry_as_request(),
            KeyCode::Char('g') => app.browser_navigate_prompt(),
            KeyCode::Char('e') => app.browser_eval_prompt(),
            // Browser back/forward via Alt+Left/Alt+Right is routed
            // through nav.back / nav.forward (command.rs) — the
            // global chord layer fires first, so duplicating the
            // arm here is dead code. (Was dead in commit 4548d64;
            // input-handler-reviewer SEV-1 2026-06-28.)
            KeyCode::Char('r') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.open_browser_history_picker()
            }
            KeyCode::Char('r') => app.browser_reload(),
            KeyCode::Char('s') => app.browser_screenshot(),
            KeyCode::Char('p') if !any_panel => app.browser_print_pdf(),
            KeyCode::Char('m') if !any_panel => app.open_browser_device_picker(),
            // Snapshot/diff chords — `X` (shift+x) captures, `x`
            // toggles the diff panel. Only active when no other panel
            // has focus (DOM / cookies / storage / etc. own those
            // letters in their own contexts).
            KeyCode::Char('X') if !any_panel => app.browser_snapshot(),
            KeyCode::Char('x') if !any_panel => app.browser_diff_snapshot(),
            KeyCode::Char('T') => app.open_browser_target_picker(),
            KeyCode::Esc => {
                // On either panel, Esc-with-a-held-filter clears the
                // filter first (the "narrow → exit" two-step UX); a
                // second Esc actually leaves the panel.
                let has_net_filter = matches!(
                    app.panes.get(i),
                    Some(Pane::Browser(b)) if b.net_focus && !b.net_filter.is_empty()
                );
                let has_dom_filter = matches!(
                    app.panes.get(i),
                    Some(Pane::Browser(b)) if b.dom_focus && !b.dom_filter.is_empty()
                );
                let has_cookies_filter = matches!(
                    app.panes.get(i),
                    Some(Pane::Browser(b)) if b.cookies_focus && !b.cookies_filter.is_empty()
                );
                let has_storage_filter = matches!(
                    app.panes.get(i),
                    Some(Pane::Browser(b)) if b.storage_focus && !b.storage_filter.is_empty()
                );
                let diff_open = matches!(
                    app.panes.get(i),
                    Some(Pane::Browser(b)) if b.snapshot_diff_open
                );
                if has_net_filter {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.net_filter_clear_and_exit();
                    }
                } else if has_dom_filter {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.dom_filter_clear_and_exit();
                    }
                } else if has_cookies_filter {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.cookies_filter_clear_and_exit();
                    }
                } else if has_storage_filter {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.storage_filter_clear_and_exit();
                    }
                } else if any_panel {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        if b.dom_focus {
                            b.hide_highlight();
                            b.dom_hover_highlight = false;
                        }
                        b.net_focus = false;
                        b.dom_focus = false;
                        b.cookies_focus = false;
                        b.storage_focus = false;
                        b.perf_focus = false;
                    }
                } else if diff_open {
                    // First Esc closes the diff panel (returns to
                    // log view); second Esc → tree (the standard
                    // browser-pane path).
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        b.snapshot_diff_open = false;
                    }
                } else {
                    app.focus_tree();
                }
            }
            _ => {}
        }
        return;
    }
    // The outline pane: ↑↓ select, Enter → jump to the symbol in target editor,
    // r → refire documentSymbol for the target, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::Outline(_))) {
        // Filter mode — type-to-narrow takes priority over navigation chords.
        if matches!(app.panes.get(i), Some(Pane::Outline(o)) if o.filter_mode) {
            match key.code {
                KeyCode::Esc => {
                    if let Some(Pane::Outline(o)) = app.panes.get_mut(i) {
                        o.filter_clear_and_exit();
                    }
                }
                KeyCode::Enter => {
                    // Exit filter mode but keep the filter; Enter doesn't jump
                    // (use `Enter` again outside filter mode to do that).
                    if let Some(Pane::Outline(o)) = app.panes.get_mut(i) {
                        o.filter_mode = false;
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Pane::Outline(o)) = app.panes.get_mut(i) {
                        o.filter_pop();
                    }
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(Pane::Outline(o)) = app.panes.get_mut(i) {
                        o.filter_push(c);
                    }
                }
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => app.move_outline_selection(-1),
            KeyCode::Down | KeyCode::Char('j') => app.move_outline_selection(1),
            KeyCode::PageUp => app.move_outline_selection(-(viewport as isize)),
            KeyCode::PageDown => app.move_outline_selection(viewport as isize),
            KeyCode::Home | KeyCode::Char('g') => app.move_outline_selection(isize::MIN / 2),
            KeyCode::End | KeyCode::Char('G') => app.move_outline_selection(isize::MAX / 2),
            KeyCode::Enter => app.jump_to_selected_outline(),
            KeyCode::Char('r') => app.refresh_outline_pane(),
            KeyCode::Char('/') => {
                if let Some(Pane::Outline(o)) = app.panes.get_mut(i) {
                    o.filter_mode = true;
                }
            }
            KeyCode::Esc => {
                // Esc when an inactive filter is held clears it first; a second
                // Esc returns focus to the tree (the standard "narrow → exit").
                let had_filter =
                    matches!(app.panes.get(i), Some(Pane::Outline(o)) if !o.query.is_empty());
                if had_filter {
                    if let Some(Pane::Outline(o)) = app.panes.get_mut(i) {
                        o.filter_clear_and_exit();
                    }
                } else {
                    app.focus_tree();
                }
            }
            _ => {}
        }
        return;
    }
    // The image-viewer pane: `i` toggle the metadata header, `r` reload
    // from disk, Esc → tree. There's nothing to scroll — the image either
    // fits or gets scaled to the body area by the terminal.
    if matches!(app.panes.get(i), Some(Pane::Image(_))) {
        match key.code {
            KeyCode::Char('i') => app.toggle_active_image_header(),
            KeyCode::Char('r') => app.reload_active_image(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // SpendReport pane: j/k navigate, s cycles sort, r refresh, Esc/q closes.
    if matches!(app.panes.get(i), Some(Pane::SpendReport(_))) {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => app.focus_tree(),
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::SpendReport(p)) = app.panes.get_mut(i) {
                    p.selected = p.selected.saturating_sub(1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::SpendReport(p)) = app.panes.get_mut(i) {
                    let n = p.snapshot.per_workspace.len();
                    if n > 0 {
                        p.selected = (p.selected + 1).min(n - 1);
                    }
                }
            }
            KeyCode::Char('s') => {
                if let Some(Pane::SpendReport(p)) = app.panes.get_mut(i) {
                    p.sort_by = p.sort_by.cycle();
                }
            }
            KeyCode::Char('r') => {
                if let Some(Pane::SpendReport(p)) = app.panes.get_mut(i) {
                    p.refresh();
                }
            }
            _ => {}
        }
        return;
    }
    // Websocket pane — Enter sends, Esc focuses tree (consistent
    // with every other pane), printable chars edit the input,
    // PgUp/PgDn scroll the log. Explicit close paths:
    // `Ctrl+C` (universal cancel reflex), `:ws.disconnect`
    // palette command.
    //
    // 2026-06-21 nvchad/vscode-kbd/power-user-ws-git agents (4
    // separate finds!) flagged Esc → close as hostile to vim +
    // standard muscle memory and risky during typing. Was: Esc
    // killed the connection. Now: Esc focuses tree (same as every
    // other pane); to close, use Ctrl+C or the palette.
    if matches!(app.panes.get(i), Some(Pane::Websocket(_))) {
        match key.code {
            KeyCode::Esc => app.focus_tree(),
            KeyCode::Enter => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.send_input();
                }
            }
            KeyCode::Backspace => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.input_backspace();
                }
            }
            KeyCode::Delete => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.input_delete();
                }
            }
            KeyCode::Left => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.input_left();
                }
            }
            KeyCode::Right => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.input_right();
                }
            }
            KeyCode::Home => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.input_home();
                }
            }
            KeyCode::End => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.input_end();
                }
            }
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.close();
                }
                app.toast("ws: closing connection…");
            }
            KeyCode::Char('e') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.focus_tree();
            }
            KeyCode::PageUp => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.scroll = p.scroll.saturating_add(10);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.scroll = p.scroll.saturating_sub(10);
                }
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(Pane::Websocket(p)) = app.panes.get_mut(i) {
                    p.input_insert(c);
                }
            }
            _ => {}
        }
        return;
    }
    // Claude Agents dashboard
    if matches!(app.panes.get(i), Some(Pane::ClaudeAgents(_))) {
        use crate::claude_agents::ClaudeAgentsAction;
        // Filter mode owns keystrokes (matches the cheatsheet/grep
        // convention). Typing edits the query; Enter applies +
        // exits filter mode; Esc clears + exits.
        if matches!(app.panes.get(i), Some(Pane::ClaudeAgents(p)) if p.filter_mode) {
            match key.code {
                KeyCode::Esc => {
                    if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                        p.query.clear();
                        p.filter_mode = false;
                        p.paused = false;
                        p.selected = 0;
                    }
                }
                KeyCode::Enter => {
                    if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                        p.filter_mode = false;
                        p.paused = false;
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                        p.query.pop();
                        p.selected = 0;
                    }
                }
                // F1 toggles help even mid-filter so the user
                // doesn't have to escape just to consult the help.
                KeyCode::F(1) => {
                    if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                        p.show_help = !p.show_help;
                    }
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                        p.query.push(c);
                        p.selected = 0;
                    }
                }
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Up | KeyCode::Char('k') if !key.modifiers.contains(KeyModifiers::SHIFT) => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.move_up();
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.move_down();
                }
            }
            KeyCode::PageUp if key.modifiers.contains(KeyModifiers::SHIFT) => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.detail_scroll = p.detail_scroll.saturating_sub(4);
                }
            }
            KeyCode::PageDown if key.modifiers.contains(KeyModifiers::SHIFT) => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.detail_scroll = p.detail_scroll.saturating_add(4);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    for _ in 0..10 {
                        p.move_up();
                    }
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    for _ in 0..10 {
                        p.move_down();
                    }
                }
            }
            KeyCode::Home => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    // claude-agents 3rd 2026-06-29 SEV-3: parity
                    // with move_up/down/mouse-click — reset
                    // detail_scroll so the new row's drill-down
                    // doesn't inherit a stale offset.
                    p.detail_scroll = 0;
                }
            }
            KeyCode::End => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    let n = p.visible_indices().len();
                    p.selected = n.saturating_sub(1);
                    p.detail_scroll = 0;
                }
            }
            KeyCode::F(1) => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.show_help = !p.show_help;
                }
            }
            KeyCode::Char('r') => app.refresh_claude_agents_pane(),
            KeyCode::Char('y') => app.claude_agents_action(ClaudeAgentsAction::YankSessionId),
            KeyCode::Char('c') => app.claude_agents_action(ClaudeAgentsAction::YankCwd),
            KeyCode::Char('v') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.cycle_detail();
                }
            }
            KeyCode::Char('/') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.filter_mode = true;
                    p.paused = true;
                }
            }
            KeyCode::Char('K') => app.claude_agents_action(ClaudeAgentsAction::KillPrompt),
            KeyCode::Char(' ') => {
                let n = if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    Some(p.toggle_multi_selected())
                } else {
                    None
                };
                if let Some(n) = n {
                    if n == 0 {
                        app.toast("multi-select cleared");
                    } else {
                        app.toast(format!("{n} selected (K batch-kills all)"));
                    }
                }
            }
            // 2026-06-21 nvchad SEV-2 chord-collision: `gg` = top
            // of list (vim canonical). First `g` latches
            // `pending_g`; second `g` jumps. A non-`g` key clears
            // the latch silently. Group-by cycle moved to Ctrl+G.
            KeyCode::Char('g') if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    if p.pending_g {
                        p.selected = 0;
                        p.pending_g = false;
                    } else {
                        p.pending_g = true;
                    }
                }
            }
            KeyCode::Char('G') if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    let n = p.visible_indices().len();
                    p.selected = n.saturating_sub(1);
                    p.pending_g = false;
                }
            }
            KeyCode::Char('g') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.cycle_group_by();
                    p.pending_g = false;
                }
            }
            KeyCode::Char('o') => app.claude_agents_action(ClaudeAgentsAction::ResumeSession),
            KeyCode::Char('e') => app.claude_agents_action(ClaudeAgentsAction::ExportMarkdown),
            KeyCode::Char('p') => {
                let new_state = if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.paused_by_user = !p.paused_by_user;
                    Some(p.paused_by_user)
                } else {
                    None
                };
                if let Some(paused) = new_state {
                    app.toast(if paused {
                        "auto-refresh paused"
                    } else {
                        "auto-refresh resumed"
                    });
                }
            }
            KeyCode::Char('?') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.show_help = !p.show_help;
                }
            }
            KeyCode::Char('1') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.state_filter = Some(crate::claude_agents::AgentState::Streaming);
                    p.selected = 0;
                }
            }
            KeyCode::Char('2') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.state_filter = Some(crate::claude_agents::AgentState::ToolCall);
                    p.selected = 0;
                }
            }
            KeyCode::Char('3') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.state_filter = Some(crate::claude_agents::AgentState::Idle);
                    p.selected = 0;
                }
            }
            KeyCode::Char('4') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.state_filter = Some(crate::claude_agents::AgentState::Ended);
                    p.selected = 0;
                }
            }
            KeyCode::Char('0') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.state_filter = None;
                    p.selected = 0;
                }
            }
            // 2026-06-21 nvchad SEV-2 — was bare `w` (vim word
            // motion); moved to capital W so vim users can still
            // press `w` without altering the workspace filter.
            KeyCode::Char('W') => app.claude_agents_toggle_workspace_only(),
            // #25 v4 — `A` cycles the age filter (Today / 7d / 30d / All).
            KeyCode::Char('A') => app.claude_agents_cycle_age(),
            KeyCode::Char('s') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.cycle_sort();
                }
            }
            KeyCode::Char('R') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.clear_multi_selected();
                }
                app.toast("multi-select cleared");
            }
            KeyCode::Char('l') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.claude_agents_clear_filters();
            }
            KeyCode::Char('>') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    use crate::claude_agents::AgentSource;
                    // claude-agents SEV-2 2026-07-10: Ecs / AnthropicManaged
                    // are dead stops here — the dashboard's `rows` are
                    // populated exclusively by collect_rows (Claude) +
                    // collect_codex_rows (Codex). Cloud sources feed the
                    // separate rail Cloud Agents panel via
                    // App::refresh_agents_panel_if_due, so filtering to
                    // ecs/managed here always showed 0/N with a misleading
                    // "no Claude sessions" empty-state. Cycle just the
                    // sources this pane actually knows about.
                    p.source_filter = match p.source_filter {
                        None => Some(AgentSource::Claude),
                        Some(AgentSource::Claude) => Some(AgentSource::Codex),
                        Some(AgentSource::Codex) => None,
                        Some(AgentSource::Ecs) | Some(AgentSource::AnthropicManaged) => None,
                    };
                    p.selected = 0;
                }
            }
            KeyCode::Char('<') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    use crate::claude_agents::AgentSource;
                    p.source_filter = match p.source_filter {
                        None => Some(AgentSource::Codex),
                        Some(AgentSource::Codex) => Some(AgentSource::Claude),
                        Some(AgentSource::Claude) => None,
                        Some(AgentSource::Ecs) | Some(AgentSource::AnthropicManaged) => None,
                    };
                    p.selected = 0;
                }
            }
            KeyCode::Char('t') | KeyCode::Enter => {
                app.claude_agents_action(ClaudeAgentsAction::OpenTranscript);
            }
            KeyCode::Esc => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    p.pending_g = false;
                }
                app.focus_tree();
            }
            KeyCode::Char('q') => app.close_active_pane(),
            _ => {
                // Any non-`g` key clears the gg latch silently.
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i)
                    && p.pending_g
                {
                    p.pending_g = false;
                }
            }
        }
        return;
    }
    // The cheatsheet pane: ↑↓ select, Enter → run the highlighted command,
    // r refresh (rebuild from the active keymap), `/` filter, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::Cheatsheet(_))) {
        // Filter mode owns the keystroke stream until Enter / Esc.
        if matches!(app.panes.get(i), Some(Pane::Cheatsheet(c)) if c.filter_mode) {
            match key.code {
                KeyCode::Esc => {
                    if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                        c.query.clear();
                        c.filter_mode = false;
                        c.selected = 0;
                    }
                }
                KeyCode::Enter => {
                    if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                        c.filter_mode = false;
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                        c.query.pop();
                        c.selected = 0;
                    }
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(Pane::Cheatsheet(cp)) = app.panes.get_mut(i) {
                        cp.query.push(c);
                        cp.selected = 0;
                    }
                }
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    c.move_up();
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    c.move_down();
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    c.page_up(viewport);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    c.page_down(viewport);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    c.jump_top();
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    c.jump_bottom();
                }
            }
            // 2026-06-21 nvchad SEV-2 cheatsheet-z-collides-with-fold-prefix:
            // moved collapse to capitals so vim's `z` fold-prefix
            // + `ZZ` save-quit don't collide. `C` = toggle focused
            // section. `X` = toggle collapse-all ↔ expand-all.
            KeyCode::Char('C')
                if !key.modifiers.contains(KeyModifiers::CONTROL)
                    && !key.modifiers.contains(KeyModifiers::ALT) =>
            {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    c.toggle_collapsed_at_selection();
                }
            }
            KeyCode::Char('X')
                if !key.modifiers.contains(KeyModifiers::CONTROL)
                    && !key.modifiers.contains(KeyModifiers::ALT) =>
            {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    let total = c.sections.len();
                    if c.collapsed.len() == total && total > 0 {
                        c.expand_all();
                    } else {
                        c.collapse_all();
                    }
                }
            }
            KeyCode::Enter => {
                let cmd = match app.panes.get(i) {
                    Some(Pane::Cheatsheet(c)) => c.selected_command_id(),
                    _ => None,
                };
                if let Some(id) = cmd {
                    crate::command::run(&id, app);
                }
            }
            KeyCode::Char('/') => {
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    c.filter_mode = true;
                }
            }
            KeyCode::Char('r') => {
                let fresh = crate::cheatsheet::CheatsheetPane::build(&app.keymap);
                if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                    *c = fresh;
                }
            }
            KeyCode::Esc => {
                let had_filter =
                    matches!(app.panes.get(i), Some(Pane::Cheatsheet(c)) if !c.query.is_empty());
                if had_filter {
                    if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(i) {
                        c.query.clear();
                        c.selected = 0;
                    }
                } else {
                    app.focus_tree();
                }
            }
            _ => {}
        }
        return;
    }
    // The DAP debug pane: ↑↓ select within the focused section (call
    // stack OR variables — Tab toggles), Enter → jump (stack) or
    // expand/collapse (variables), r → re-fetch stack trace, Esc →
    // tree.
    if matches!(app.panes.get(i), Some(Pane::Debug(_))) {
        // Read focused section once per dispatch so the per-key
        // routing doesn't need to re-borrow the pane.
        let section = match app.panes.get(i) {
            Some(Pane::Debug(p)) => p.section,
            _ => crate::pane::DebugSection::Stack,
        };
        let move_fn = |app: &mut App, delta: isize| match section {
            crate::pane::DebugSection::Stack => app.debug_pane_move(delta),
            crate::pane::DebugSection::Variables => app.debug_pane_vars_move(delta),
        };
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => move_fn(app, -1),
            KeyCode::Down | KeyCode::Char('j') => move_fn(app, 1),
            KeyCode::PageUp => move_fn(app, -(viewport as isize)),
            KeyCode::PageDown => move_fn(app, viewport as isize),
            KeyCode::Home | KeyCode::Char('g') => move_fn(app, isize::MIN / 2),
            KeyCode::End | KeyCode::Char('G') => move_fn(app, isize::MAX / 2),
            KeyCode::Enter => app.debug_pane_accept(),
            KeyCode::Tab => app.debug_pane_toggle_section(),
            KeyCode::Char('r') => {
                let (mgr, tid) = (app.dap.as_mut(), app.dap_thread);
                if let (Some(mgr), Some(tid)) = (mgr, tid) {
                    let _ = mgr.client.stack_trace(tid);
                }
            }
            // `y` / `w` are variables-section chords: copy value /
            // promote to watch. Only active when that section has
            // focus; otherwise `y`/`w` are unused.
            KeyCode::Char('y') if section == crate::pane::DebugSection::Variables => {
                app.debug_pane_yank_var();
            }
            KeyCode::Char('w') if section == crate::pane::DebugSection::Variables => {
                app.debug_pane_watch_var();
            }
            KeyCode::Char('s') if section == crate::pane::DebugSection::Variables => {
                app.debug_pane_set_var();
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // The DAP REPL pane: text input on the bottom row, history above.
    // Enter submits, Up/Down walks command history, Esc → tree. Printable
    // chars / Left / Right / Backspace / Delete / Home / End / Ctrl+U/W
    // all edit the input line.
    if matches!(app.panes.get(i), Some(Pane::DapRepl(_))) {
        // While `filter_mode == true`, all keys feed the filter buffer
        // (mirrors cookies / storage / net / DOM filter UX). Bail early
        // so the regular input-editing arms don't double-handle.
        let in_filter_mode = matches!(
            app.panes.get(i),
            Some(Pane::DapRepl(p)) if p.filter_mode
        );
        if in_filter_mode {
            match key.code {
                KeyCode::Backspace => {
                    if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                        p.filter.pop();
                        p.selected = None;
                    }
                }
                KeyCode::Enter => {
                    // Exit filter mode but keep the narrow.
                    if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                        p.filter_mode = false;
                    }
                }
                KeyCode::Esc => {
                    // Clear filter + exit mode.
                    if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                        p.filter.clear();
                        p.filter_mode = false;
                        p.selected = None;
                    }
                }
                KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                        p.filter.push(c);
                        p.selected = None;
                    }
                }
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Enter => app.dap_repl_submit(),
            // Shift+Up/Down move row selection (for `o` expand).
            // Plain Up/Down still walk command history (cmdline-like).
            KeyCode::Up if key.modifiers.contains(KeyModifiers::SHIFT) => {
                app.dap_repl_select_move(-1)
            }
            KeyCode::Down if key.modifiers.contains(KeyModifiers::SHIFT) => {
                app.dap_repl_select_move(1)
            }
            KeyCode::Up => app.dap_repl_history_walk(-1),
            KeyCode::Down => app.dap_repl_history_walk(1),
            KeyCode::Esc => {
                // Esc cascade: first clears a held filter, then clears
                // row selection, then bails to tree. Mirrors the panel-
                // then-tree gesture elsewhere in the codebase.
                let (had_filter, had_sel) = match app.panes.get(i) {
                    Some(Pane::DapRepl(p)) => (!p.filter.is_empty(), p.selected.is_some()),
                    _ => (false, false),
                };
                if had_filter {
                    if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                        p.filter.clear();
                        p.selected = None;
                    }
                } else if had_sel {
                    if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                        p.selected = None;
                    }
                } else {
                    app.focus_tree();
                }
            }
            KeyCode::Backspace => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i)
                    && p.cursor > 0
                {
                    let prev = p.input[..p.cursor]
                        .char_indices()
                        .next_back()
                        .map(|(i, _)| i)
                        .unwrap_or(0);
                    p.input.replace_range(prev..p.cursor, "");
                    p.cursor = prev;
                }
            }
            KeyCode::Delete => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i)
                    && p.cursor < p.input.len()
                {
                    let next = p.input[p.cursor..]
                        .char_indices()
                        .nth(1)
                        .map(|(i, _)| p.cursor + i)
                        .unwrap_or(p.input.len());
                    p.input.replace_range(p.cursor..next, "");
                }
            }
            KeyCode::Left => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i)
                    && p.cursor > 0
                {
                    let prev = p.input[..p.cursor]
                        .char_indices()
                        .next_back()
                        .map(|(i, _)| i)
                        .unwrap_or(0);
                    p.cursor = prev;
                }
            }
            KeyCode::Right => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i)
                    && p.cursor < p.input.len()
                {
                    let next = p.input[p.cursor..]
                        .char_indices()
                        .nth(1)
                        .map(|(i, _)| p.cursor + i)
                        .unwrap_or(p.input.len());
                    p.cursor = next;
                }
            }
            KeyCode::Home => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                    p.cursor = 0;
                }
            }
            KeyCode::End => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                    p.cursor = p.input.len();
                }
            }
            KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                    p.input.clear();
                    p.cursor = 0;
                }
            }
            KeyCode::Char('w') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                    let head = &p.input[..p.cursor];
                    let trimmed = head.trim_end_matches(' ');
                    let cut = trimmed
                        .char_indices()
                        .rev()
                        .find(|(_, c)| c.is_whitespace() || matches!(*c, '.' | '/' | '(' | '['))
                        .map(|(i, c)| i + c.len_utf8())
                        .unwrap_or(0);
                    p.input.replace_range(cut..p.cursor, "");
                    p.cursor = cut;
                }
            }
            // `o` (open) on a selected REPL row expands a composite
            // result — fetches its children via `variables` and renders
            // them indented below. Only when a row is actually selected;
            // otherwise `o` is just a printable char going into the input.
            KeyCode::Char('o')
                if matches!(
                    app.panes.get(i),
                    Some(Pane::DapRepl(p)) if p.selected.is_some()
                ) =>
            {
                app.dap_repl_toggle_expand();
            }
            // `/` enters filter mode when (a) the input is empty so no
            // expression is in flight, or (b) a row is selected (user
            // has moved focus off the input). Otherwise it's a literal
            // char — `/` shows up in paths / division expressions.
            KeyCode::Char('/')
                if matches!(
                    app.panes.get(i),
                    Some(Pane::DapRepl(p)) if p.input.is_empty() || p.selected.is_some()
                ) =>
            {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                    p.filter_mode = true;
                }
            }
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                if let Some(Pane::DapRepl(p)) = app.panes.get_mut(i) {
                    p.input.insert(p.cursor, c);
                    p.cursor += c.len_utf8();
                }
            }
            _ => {}
        }
        return;
    }
    // The flaky-test dashboard: ↑↓ select, Enter → jump to the test in source,
    // r refresh (rebuild from the latest history), Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::Flaky(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => app.move_flaky_selection(-1),
            KeyCode::Down | KeyCode::Char('j') => app.move_flaky_selection(1),
            KeyCode::PageUp => app.move_flaky_selection(-(viewport as isize)),
            KeyCode::PageDown => app.move_flaky_selection(viewport as isize),
            KeyCode::Home | KeyCode::Char('g') => app.move_flaky_selection(isize::MIN / 2),
            KeyCode::End | KeyCode::Char('G') => app.move_flaky_selection(isize::MAX / 2),
            KeyCode::Enter => app.jump_to_selected_flaky(),
            KeyCode::Char('r') => app.refresh_flaky_panes(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // A diagnostics ("Problems") list: ↑↓ select, Enter → jump to the location,
    // r refresh, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::Diagnostics(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => app.move_diagnostics_selection(-1),
            KeyCode::Down | KeyCode::Char('j') => app.move_diagnostics_selection(1),
            KeyCode::PageUp => app.move_diagnostics_selection(-(viewport as isize)),
            KeyCode::PageDown => app.move_diagnostics_selection(viewport as isize),
            KeyCode::Home | KeyCode::Char('g') => app.move_diagnostics_selection(isize::MIN / 2),
            KeyCode::End | KeyCode::Char('G') => app.move_diagnostics_selection(isize::MAX / 2),
            KeyCode::Enter => app.jump_to_selected_diagnostic(),
            KeyCode::Char('r') => app.refresh_diagnostics_panes(),
            KeyCode::Char('s') => {
                if let Some(Pane::Diagnostics(d)) = app.panes.get_mut(i) {
                    d.cycle_severity_filter();
                }
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // A workspace-grep results list: ↑↓ select, Enter → jump to the file at
    // the matched line, r re-runs the same query, R replaces every hit across
    // every file, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::Grep(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => app.move_grep_selection(-1),
            KeyCode::Down | KeyCode::Char('j') => app.move_grep_selection(1),
            KeyCode::PageUp => app.move_grep_selection(-(viewport as isize)),
            KeyCode::PageDown => app.move_grep_selection(viewport as isize),
            KeyCode::Home | KeyCode::Char('g') => app.move_grep_selection(isize::MIN / 2),
            KeyCode::End | KeyCode::Char('G') => app.move_grep_selection(isize::MAX / 2),
            KeyCode::Enter => app.jump_to_selected_grep_hit(),
            KeyCode::Char('r') => app.rerun_active_grep(),
            KeyCode::Char('R') => app.open_grep_replace_prompt(),
            // Per-hit toggle — Space marks the row enabled/disabled;
            // `R` then replaces only enabled hits. `A` enables all,
            // `D` disables all.
            KeyCode::Char(' ') => {
                if let Some(Pane::Grep(g)) = app.panes.get_mut(i) {
                    g.toggle_selected();
                }
            }
            KeyCode::Char('A') => {
                if let Some(Pane::Grep(g)) = app.panes.get_mut(i) {
                    g.enable_all();
                }
            }
            KeyCode::Char('D') => {
                if let Some(Pane::Grep(g)) = app.panes.get_mut(i) {
                    g.disable_all();
                }
            }
            KeyCode::Char('y') => app.copy_selected_grep_hit(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // Quickfix pane — same nav as Grep but no `r` rerun / `R` replace
    // (the population path is external — `:cexpr`, LSP references, etc.).
    if matches!(app.panes.get(i), Some(Pane::Quickfix(_))) {
        let delta = match key.code {
            KeyCode::Up | KeyCode::Char('k') => Some(-1isize),
            KeyCode::Down | KeyCode::Char('j') => Some(1),
            KeyCode::PageUp => Some(-(viewport as isize)),
            KeyCode::PageDown => Some(viewport as isize),
            KeyCode::Home | KeyCode::Char('g') => Some(isize::MIN / 2),
            KeyCode::End | KeyCode::Char('G') => Some(isize::MAX / 2),
            _ => None,
        };
        if let Some(d) = delta
            && let Some(Pane::Quickfix(g)) = app.panes.get_mut(i)
        {
            g.move_selection(d);
            return;
        }
        match key.code {
            KeyCode::Enter => app.jump_to_selected_quickfix_hit(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // The cmdline-history pane (vim `q:`): ↑↓ / jk / PgUp/PgDn move the
    // selection, Enter re-fires the highlighted command, Esc closes the pane.
    if matches!(app.panes.get(i), Some(Pane::CmdlineHistory(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(i) {
                    h.move_selection(-1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(i) {
                    h.move_selection(1);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(i) {
                    h.move_selection(-(viewport as isize));
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(i) {
                    h.move_selection(viewport as isize);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(i) {
                    h.move_selection(isize::MIN / 2);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(i) {
                    h.move_selection(isize::MAX / 2);
                }
            }
            KeyCode::Enter => app.cmdline_history_accept(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // The git-graph pane: ↑↓ select a commit, Enter → open that commit's diff,
    // `r` refresh (re-run `git log`), `y` copy the commit hash, `/` enter
    // hash-filter mode (type a partial hash prefix to jump), Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::GitGraph(_))) {
        // Textarea focus wins — when the WIP commit textarea is
        // focused, every printable / motion / Enter / Backspace key
        // mutates the textarea instead of triggering the graph chord
        // table. Esc unfocuses; Ctrl+Enter commits.
        let textarea_focused = matches!(
            app.panes.get(i),
            Some(Pane::GitGraph(g)) if g.is_wip_selected() && g.wip_commit.focused
        );
        if textarea_focused {
            use ratatui::crossterm::event::KeyModifiers;
            // Ctrl+Enter (or Cmd+Enter where the terminal forwards it)
            // commits with the current textarea content.
            if key.code == KeyCode::Enter && key.modifiers.contains(KeyModifiers::CONTROL) {
                app.commit_from_active_wip_textarea_or_prompt();
                return;
            }
            match key.code {
                KeyCode::Esc => app.blur_active_wip_commit_textarea(),
                KeyCode::Enter => {
                    if let Some(ta) = app.active_wip_commit_textarea_mut() {
                        ta.insert_char('\n');
                    }
                }
                KeyCode::Backspace => {
                    if let Some(ta) = app.active_wip_commit_textarea_mut() {
                        ta.backspace();
                    }
                }
                KeyCode::Delete => {
                    if let Some(ta) = app.active_wip_commit_textarea_mut() {
                        ta.delete_forward();
                    }
                }
                KeyCode::Left => {
                    if let Some(ta) = app.active_wip_commit_textarea_mut() {
                        ta.move_left();
                    }
                }
                KeyCode::Right => {
                    if let Some(ta) = app.active_wip_commit_textarea_mut() {
                        ta.move_right();
                    }
                }
                KeyCode::Home => {
                    if let Some(ta) = app.active_wip_commit_textarea_mut() {
                        ta.move_line_start();
                    }
                }
                KeyCode::End => {
                    if let Some(ta) = app.active_wip_commit_textarea_mut() {
                        ta.move_line_end();
                    }
                }
                KeyCode::Char(ch)
                    if !key
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    if let Some(ta) = app.active_wip_commit_textarea_mut() {
                        ta.insert_char(ch);
                    }
                }
                _ => {}
            }
            return;
        }

        // Embedded diff wins — when the user clicked a file in the
        // right-side detail panel, a `DiffView` lives inside the
        // GitGraph and the commit-list area is replaced by it. Keys
        // route to the embedded diff (same chords as `Pane::Diff`).
        // Esc closes the embedded diff first; a second Esc bails to
        // the tree via the normal graph-pane path.
        let has_embedded =
            matches!(app.panes.get(i), Some(Pane::GitGraph(g)) if g.embedded_diff.is_some());
        if has_embedded {
            // Filter mode (embedded) — mirror the standalone path.
            let in_filter = matches!(
                app.panes.get(i),
                Some(Pane::GitGraph(g)) if g.embedded_diff.as_ref().map(|d| d.filter_mode).unwrap_or(false)
            );
            if in_filter {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i)
                    && let Some(d) = g.embedded_diff.as_mut()
                {
                    match key.code {
                        KeyCode::Esc => {
                            d.filter.clear();
                            d.filter_mode = false;
                        }
                        KeyCode::Enter => d.filter_mode = false,
                        KeyCode::Backspace => {
                            d.filter.pop();
                        }
                        KeyCode::Char(ch)
                            if !key
                                .modifiers
                                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                        {
                            d.filter.push(ch);
                        }
                        _ => {}
                    }
                }
                return;
            }
            if key.code == KeyCode::Esc {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                    g.embedded_diff = None;
                }
                return;
            }
            if matches!(key.code, KeyCode::Char('/')) {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i)
                    && let Some(d) = g.embedded_diff.as_mut()
                {
                    d.filter.clear();
                    d.filter_mode = true;
                }
                return;
            }
            // `f` / `F` walk between the commit's changed files
            // without going back to the right detail panel. Routed
            // through `App::diff_jump_file` which already knows how
            // to re-open the embedded diff against a sibling file.
            if matches!(key.code, KeyCode::Char('f')) {
                app.diff_jump_file(true);
                return;
            }
            if matches!(key.code, KeyCode::Char('F')) {
                app.diff_jump_file(false);
                return;
            }
            let mut new_mode_pref: Option<crate::pane::DiffViewMode> = None;
            let mut new_wrap_pref: Option<bool> = None;
            if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i)
                && let Some(d) = g.embedded_diff.as_mut()
            {
                let in_split = d.view_mode == crate::pane::DiffViewMode::Split;
                match key.code {
                    KeyCode::Up if in_split => d.scroll = d.scroll.saturating_sub(1),
                    KeyCode::Down if in_split => d.scroll += 1,
                    KeyCode::Up => d.cursor = d.cursor.saturating_sub(1),
                    KeyCode::Down => {
                        d.cursor = (d.cursor + 1).min(d.hunks.len().saturating_sub(1));
                    }
                    KeyCode::Char('k') => d.scroll = d.scroll.saturating_sub(1),
                    KeyCode::Char('j') => d.scroll += 1,
                    KeyCode::PageUp => d.scroll = d.scroll.saturating_sub(viewport),
                    KeyCode::PageDown => d.scroll += viewport,
                    KeyCode::Char('n') | KeyCode::Char(']') => {
                        d.cursor = (d.cursor + 1).min(d.hunks.len().saturating_sub(1));
                    }
                    KeyCode::Char('p') | KeyCode::Char('[') => {
                        d.cursor = d.cursor.saturating_sub(1)
                    }
                    KeyCode::Home => {
                        d.scroll = 0;
                        d.cursor = 0;
                    }
                    KeyCode::End => d.scroll = usize::MAX,
                    KeyCode::Char('w') => {
                        d.wrap = !d.wrap;
                        new_wrap_pref = Some(d.wrap);
                    }
                    KeyCode::Char('v') => {
                        d.view_mode = match d.view_mode {
                            crate::pane::DiffViewMode::Hunk => crate::pane::DiffViewMode::Inline,
                            crate::pane::DiffViewMode::Inline => crate::pane::DiffViewMode::Split,
                            crate::pane::DiffViewMode::Split => crate::pane::DiffViewMode::Hunk,
                        };
                        new_mode_pref = Some(d.view_mode);
                    }
                    _ => {}
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

        // Hash-filter mode wins — consume keystrokes until Enter / Esc.
        let in_filter_mode = matches!(
            app.panes.get(i),
            Some(Pane::GitGraph(g)) if g.hash_filter_mode
        );
        if in_filter_mode {
            match key.code {
                KeyCode::Esc => {
                    if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                        g.hash_filter.clear();
                        g.hash_filter_mode = false;
                    }
                }
                KeyCode::Enter => {
                    if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                        g.hash_filter_mode = false;
                    }
                }
                KeyCode::Backspace => {
                    if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                        g.hash_filter.pop();
                        if let Some(idx) = g.find_by_hash_prefix(&g.hash_filter) {
                            g.jump_to_commit(idx);
                        }
                    }
                }
                KeyCode::Char(ch) if ch.is_ascii_hexdigit() => {
                    let mut no_match: Option<String> = None;
                    if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                        g.hash_filter.push(ch.to_ascii_lowercase());
                        if let Some(idx) = g.find_by_hash_prefix(&g.hash_filter) {
                            g.jump_to_commit(idx);
                        } else {
                            no_match = Some(g.hash_filter.clone());
                        }
                    }
                    if let Some(s) = no_match {
                        app.toast(format!("no commit ~ {s}"));
                    }
                }
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                    g.move_selection(-1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                    g.move_selection(1);
                }
            }
            KeyCode::PageUp | KeyCode::Char('u') => {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                    g.move_selection(-(viewport as isize));
                }
            }
            KeyCode::PageDown | KeyCode::Char('d') => {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                    g.move_selection(viewport as isize);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                    g.move_selection(isize::MIN / 2);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                    g.move_selection(isize::MAX / 2);
                }
            }
            KeyCode::Char('/') => {
                if let Some(Pane::GitGraph(g)) = app.panes.get_mut(i) {
                    g.hash_filter_mode = true;
                    g.hash_filter.clear();
                }
            }
            // WIP-row chords: when the WIP virtual row at the top of the
            // list is selected, c/C/Enter trigger staging-ish flows that
            // operate on the working tree rather than a real commit.
            KeyCode::Char('c') if matches!(app.panes.get(i), Some(Pane::GitGraph(g)) if g.is_wip_selected()) =>
            {
                app.open_commit_prompt();
            }
            KeyCode::Char('C') if matches!(app.panes.get(i), Some(Pane::GitGraph(g)) if g.is_wip_selected()) =>
            {
                app.request_ai_commit_message();
            }
            KeyCode::Enter if matches!(app.panes.get(i), Some(Pane::GitGraph(g)) if g.is_wip_selected()) =>
            {
                // WIP row → open the full staging pane next to the graph.
                app.open_git_status();
            }
            KeyCode::Enter => app.open_selected_commit_diff(),
            KeyCode::Char('r') => app.refresh_active_git_graph(),
            KeyCode::Char('y') => app.copy_selected_commit_hash(),
            // Branch filter — `b` opens picker, `B` clears.
            KeyCode::Char('b') => app.open_git_graph_branch_filter_picker(),
            KeyCode::Char('B') => app.apply_git_graph_branch_filter(None),
            // Date / author / subject filters. `D` for date avoids the
            // lowercase `d` page-down chord already taken above.
            KeyCode::Char('D') => app.open_git_graph_date_filter_prompt(),
            KeyCode::Char('a') => app.open_git_graph_author_filter_prompt(),
            KeyCode::Char('s') => app.open_git_graph_grep_filter_prompt(),
            // Capital `F` clears every filter at once.
            KeyCode::Char('F') => {
                let _ = crate::command::run("git.graph_filter_reset_all", app);
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // The git-status / staging pane: ↑↓ select a file, `s`/`u`/Space stage/unstage,
    // `a`/`A` stage/unstage all, Enter → that file's diff, `c` commit, `C` AI commit
    // message, `r` refresh, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::GitStatus(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::GitStatus(g)) = app.panes.get_mut(i) {
                    g.move_selection(-1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::GitStatus(g)) = app.panes.get_mut(i) {
                    g.move_selection(1);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::GitStatus(g)) = app.panes.get_mut(i) {
                    g.move_selection(-(viewport as isize));
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::GitStatus(g)) = app.panes.get_mut(i) {
                    g.move_selection(viewport as isize);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::GitStatus(g)) = app.panes.get_mut(i) {
                    g.move_selection(isize::MIN / 2);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::GitStatus(g)) = app.panes.get_mut(i) {
                    g.move_selection(isize::MAX / 2);
                }
            }
            KeyCode::Char(' ') => app.git_toggle_selected(),
            KeyCode::Char('s') => app.git_stage_selected(),
            KeyCode::Char('u') => app.git_unstage_selected(),
            KeyCode::Char('a') => app.git_stage_all_active(),
            KeyCode::Char('A') => app.git_unstage_all_active(),
            KeyCode::Enter => app.git_status_open_diff(),
            KeyCode::Char('c') => app.open_commit_prompt(),
            KeyCode::Char('C') => app.request_ai_commit_message(),
            KeyCode::Char('b') => app.open_branch_picker(),
            KeyCode::Char('B') => app.open_new_branch_prompt(),
            KeyCode::Char('w') => app.open_worktree_picker(),
            KeyCode::Char('r') => {
                if let Some(Pane::GitStatus(g)) = app.panes.get_mut(i) {
                    g.refresh();
                }
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // An AI pane: read-only — scroll, `r` re-ask, `c` continue in interactive
    // Claude Code (resumes the session), `a` apply the suggested code, Esc → tree.
    if let Some(Pane::Ai(a)) = app.panes.get_mut(i) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => a.scroll = a.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => a.scroll += 1,
            KeyCode::PageUp => a.scroll = a.scroll.saturating_sub(viewport),
            KeyCode::PageDown => a.scroll += viewport,
            KeyCode::Home | KeyCode::Char('g') => a.scroll = 0,
            KeyCode::End | KeyCode::Char('G') => a.scroll = usize::MAX, // clamped on draw
            KeyCode::Char('r') => app.resend_active_ai(),
            KeyCode::Char('c') => app.continue_active_ai(),
            KeyCode::Char('a') => app.apply_ai_suggestion(),
            KeyCode::Char('x') => app.cancel_active_ai(),
            KeyCode::Char('y') => app.copy_active_ai_answer(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // A pty pane swallows almost everything (so readline / vim-in-pty work) and
    // forwards it to the child. The global chords (`Ctrl+E` cycle focus, `Ctrl+B`
    // tree, …) already had their shot in `dispatch_key` before us, so they remain
    // the way out — nothing here intercepts. (Esc is forwarded too — terminal apps
    // need it.) `Shift+PgUp/PgDn/Home/End` scroll the vt100 scroll-back instead of
    // being forwarded. An exited child swallows nothing; close it with `Ctrl+W`.
    // Ctrl+F in a focused Claude pty → inject the current file path
    // (claude-chat.nvim's filename-inject). Only Claude panes — shells
    // keep Ctrl+F as readline forward-char. Checked before the pty
    // borrow below so `inject_filename_to_claude` can read other panes.
    if key.code == KeyCode::Char('f')
        && key.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(
            app.panes.get(i),
            Some(Pane::Pty(s)) if !s.is_exited() && s.profile.label.starts_with("claude")
        )
    {
        app.inject_filename_to_claude(i);
        return;
    }
    if let Some(Pane::Pty(s)) = app.panes.get_mut(i) {
        if s.is_exited() {
            if key.code == KeyCode::Esc {
                app.focus_tree();
            }
            return;
        }
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        match key.code {
            KeyCode::PageUp if shift => {
                s.scroll_history(viewport.saturating_sub(1) as isize);
                return;
            }
            KeyCode::PageDown if shift => {
                s.scroll_history(-(viewport.saturating_sub(1) as isize));
                return;
            }
            KeyCode::Home if shift => {
                s.scroll_to_top();
                return;
            }
            KeyCode::End if shift => {
                s.scroll_to_bottom();
                return;
            }
            _ => {}
        }
        let bytes = crate::app::dispatch::pty_key_bytes(key);
        if !bytes.is_empty() {
            s.write_bytes(&bytes);
        }
        return;
    }
    // Esc on an editor with active find highlights clears them (the user is
    // "done with this search"). Still let the input handler see the Esc — vim
    // uses it to leave Insert/Visual, standard mode treats it as a no-op.
    if key.code == KeyCode::Esc
        && let Some(Pane::Editor(b)) = app.panes.get_mut(i)
        && b.find.is_some()
    {
        b.find = None;
    }
    // The plain character this key inserts (if any) — for the completion popup's
    // auto-trigger; captured before `feed_key` consumes `key`.
    let typed_char = match key.code {
        KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => Some(c),
        _ => None,
    };
    // Capture mode + pending-chord state BEFORE dispatch so the dot-
    // recorder can detect mode transitions and chord-completion. Only
    // meaningful for editor panes.
    let (mode_before, pending_before) = match app.panes.get(i) {
        Some(Pane::Editor(b)) => (Some(b.input.mode()), b.input.pending_display()),
        _ => (None, None),
    };
    // Skip dot recording for the `.` repeat key itself (we're replaying)
    // and during macro replay.
    let skip_dot = app.is_replaying_dot
        || matches!(key.code, KeyCode::Char('.'))
            && mode_before == Some(crate::input::EditingMode::Normal)
            && pending_before.is_none();
    // Pass the active pane's text width to `feed_key` so the input
    // handler's wrap-aware chords (vim `gj`/`gk`/`g0`/`g$`) can compute
    // visual rows. `None` ⇒ wrap is off.
    let wrap_width: Option<usize> = if app.config.ui.wrap {
        app.rects
            .editor_panes
            .iter()
            .find(|(_, pid)| *pid == i)
            .map(|(r, _)| r.width as usize)
            .filter(|w| *w > 0)
    } else {
        None
    };
    // `b` borrows app.panes; `&mut app.clipboard` is a disjoint field — fine.
    let ev = match app.panes.get_mut(i) {
        Some(Pane::Editor(b)) => b.feed_key(key, &mut app.clipboard, viewport, wrap_width),
        _ => return,
    };
    let edited = matches!(ev, BufferEvent::Edited);
    match ev {
        BufferEvent::Edited => {
            // Keep the snippet session's stop positions live, even when
            // the cursor wanders off the active stop and edits land
            // elsewhere. Read `pending_tree_edits` without consuming
            // them — `refresh_highlights` will drain them on the next
            // highlight pass. Only the slice past `edits_consumed`
            // counts: anything before that index was already folded into
            // the stops (either by the snippet's own insertion, baked
            // into the absolute stop positions, or by a previous run of
            // this branch). When the vec was drained between calls
            // (`len() < edits_consumed`), reset the baseline and treat
            // the full vec as new.
            if let Some(sess) = app.snippet_session.as_ref()
                && let Some(Pane::Editor(b)) = app.panes.get(i)
            {
                let len = b.pending_tree_edits.len();
                // 2026-07-11 macOS-CI snippet flake fix — the check
                // used to be `len >= edits_consumed`. In the
                // drain-then-edit race (refresh_highlights drains
                // pending_tree_edits between two feed_keys, then the
                // next feed_key adds one edit back), `len ==
                // edits_consumed` on entry — the slice `[len..len]`
                // is empty and the just-added edit's shift is
                // silently DROPPED, leaving the next stop's byte
                // position stale. Result on the failing snippet
                // test: `Tab → type items` inserts at $2's
                // pre-typing byte offset, producing
                // `for i initems  {` instead of `for i in items {`.
                // Under `>` the equal case correctly falls into the
                // whole-vec branch and the shift fires.
                let (edits, new_consumed) = if len > sess.edits_consumed {
                    (b.pending_tree_edits[sess.edits_consumed..].to_vec(), len)
                } else {
                    (b.pending_tree_edits.to_vec(), len)
                };
                if !edits.is_empty() {
                    app.apply_snippet_text_edits(i, &edits);
                }
                if let Some(sess) = app.snippet_session.as_mut() {
                    sess.edits_consumed = new_consumed;
                }
            }
            // Keep the LSP server's view in sync (full-text didChange).
            let upd = match app.panes.get(i) {
                Some(Pane::Editor(b)) => b.path.clone().map(|p| (p, b.editor.text().to_string())),
                _ => None,
            };
            if let Some((p, text)) = upd {
                app.lsp.did_change(&p, &text);
                // Live markdown preview: push the in-memory text to any open
                // `Pane::MdPreview` of this file so the preview tracks edits
                // instead of waiting for save. Covers `.md` / `.markdown` /
                // `.mdx` / `.mkd`.
                if matches!(
                    p.extension().and_then(|e| e.to_str()),
                    Some("md" | "markdown" | "mdx" | "mkd")
                ) {
                    app.refresh_md_previews_from_text(&p, &text);
                    // Cursor-sync as well so the preview tracks where the
                    // user is editing, not just what's in the buffer.
                    if let Some(Pane::Editor(b)) = app.panes.get(i) {
                        let row = b.editor.row_col().0;
                        app.sync_md_previews_to_cursor(&p, row);
                    }
                }
            }
            // Drive the as-you-type completion popup off the fresh buffer state.
            app.completion_on_edit(typed_char);
            // (Re)arm the AI ghost-text debounce — fires once typing pauses.
            app.note_edit_for_suggest();
            // `[editor] format_on_type` — fire `textDocument/onTypeFormatting`
            // when a trigger char lands. `}`, `;`, `\n` cover the canonical
            // formatters' triggers (rustfmt-ish, prettier, etc.).
            if app.config.editor.format_on_type
                && let Some(c) = typed_char
                && matches!(c, '}' | ';')
            {
                app.lsp_on_type_format(c);
            }
            if app.config.editor.format_on_type && matches!(key.code, KeyCode::Enter) {
                app.lsp_on_type_format('\n');
            }
            // Vim abbreviation expansion: if the typed char is a trigger
            // (whitespace / punctuation) AND the active handler is in
            // Insert, look back for an abbreviation word.
            if let Some(c) = typed_char
                && crate::app::dispatch::is_abbreviation_trigger(c)
                && let Some(Pane::Editor(b)) = app.panes.get(i)
                && b.input.mode() == crate::input::EditingMode::Insert
            {
                app.try_expand_abbreviation(i);
            }
        }
        BufferEvent::Redraw | BufferEvent::NoOp => {
            // Cursor-only motion in a markdown buffer — sync any open
            // preview pane's scroll. The Edited path handles its own sync.
            if let Some(Pane::Editor(b)) = app.panes.get(i)
                && let Some(p) = b.path.clone()
                && matches!(
                    p.extension().and_then(|e| e.to_str()),
                    Some("md" | "markdown" | "mdx" | "mkd")
                )
            {
                let row = b.editor.row_col().0;
                app.sync_md_previews_to_cursor(&p, row);
            }
        }
        BufferEvent::App(cmd) => crate::app::dispatch::apply_app_command(app, cmd),
        BufferEvent::Unhandled(k) => {
            // Esc escalation. Common to BOTH modes:
            //   1. clear extra cursors if multi-cursor mode is active
            //      (without this, the only keyboard exit was the
            //      palette — Esc on multi-cursor was a footgun in
            //      both editing styles).
            //   2. (selection-clear already happened inside the
            //      handler).
            //
            // Vim-only:
            //   3. release focus to the tree (no overlay-open path
            //      reached here; Esc has dropped through all of them).
            //
            // Standard mode SKIPS step 3 — VS Code purist convention
            // (Esc on a "clean" editor is a no-op).
            // vscode-keyboard-2026-06-10 S2-10.
            if k.code == KeyCode::Esc {
                let has_extras = matches!(
                    app.panes.get(i),
                    Some(Pane::Editor(b)) if !b.editor.extra_cursors.is_empty()
                );
                if has_extras {
                    app.run_editor_op(crate::edit_op::EditOp::ClearExtraCursors);
                } else if app.esc_blurs_pane_to_tree() {
                    app.focus_tree();
                }
            }
        }
    }
    // Dot-repeat recording — see App.dot_keys / dot_recording. Runs at
    // the bottom so we can compare mode_before / mode_after + chord state.
    if !skip_dot {
        let (mode_after, pending_after) = match app.panes.get(i) {
            Some(Pane::Editor(b)) => (Some(b.input.mode()), b.input.pending_display()),
            _ => (None, None),
        };
        crate::app::dispatch::record_dot(
            app,
            key,
            mode_before,
            mode_after,
            pending_before,
            pending_after,
            edited,
        );
    }
}

// T-2: dispatch_mouse moved to src/tui/mouse.rs (re-exported above).

fn handle_md_preview_key(app: &mut App, key: KeyEvent, viewport: usize, i: usize) -> bool {
    if let Some(Pane::MdPreview(p)) = app.panes.get_mut(i) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => p.scroll = p.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => p.scroll += 1,
            KeyCode::PageUp => p.scroll = p.scroll.saturating_sub(viewport),
            KeyCode::PageDown => p.scroll += viewport,
            KeyCode::Home | KeyCode::Char('g') => p.scroll = 0,
            KeyCode::End | KeyCode::Char('G') => p.scroll = usize::MAX, // clamped on draw
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return true;
    }
    false
}

fn handle_diff_key(app: &mut App, key: KeyEvent, viewport: usize, i: usize) -> bool {
    if let Some(Pane::Diff(d)) = app.panes.get_mut(i) {
        // Filter mode wins — `/` opens it; printable keys / Backspace
        // append / pop; Enter exits (keeping the filter); Esc clears.
        if d.filter_mode {
            match key.code {
                KeyCode::Esc => {
                    d.filter.clear();
                    d.filter_mode = false;
                }
                KeyCode::Enter => d.filter_mode = false,
                KeyCode::Backspace => {
                    d.filter.pop();
                }
                KeyCode::Char(ch)
                    if !key
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    d.filter.push(ch);
                }
                _ => {}
            }
            return true;
        }
        let in_split = d.view_mode == crate::pane::DiffViewMode::Split;
        match key.code {
            KeyCode::Char('/') => {
                d.filter.clear();
                d.filter_mode = true;
                return true;
            }
            // Up / Down — in Inline/Hunk mode they jump hunks
            // (user's preferred change-navigation gesture); in Split
            // mode they scroll by row since one "hunk" is a whole
            // file and the user is reading line-by-line.
            KeyCode::Up if in_split => d.scroll = d.scroll.saturating_sub(1),
            KeyCode::Down if in_split => d.scroll += 1,
            KeyCode::Up => d.cursor = d.cursor.saturating_sub(1),
            KeyCode::Down => {
                d.cursor = (d.cursor + 1).min(d.hunks.len().saturating_sub(1));
            }
            // j / k still scroll a single row (vim convention).
            KeyCode::Char('k') => d.scroll = d.scroll.saturating_sub(1),
            KeyCode::Char('j') => d.scroll += 1,
            KeyCode::PageUp => d.scroll = d.scroll.saturating_sub(viewport),
            KeyCode::PageDown => d.scroll += viewport,
            KeyCode::Char('n') | KeyCode::Char(']') => {
                if !d.filter.is_empty() {
                    if let Some(idx) = crate::ui::diff_view::next_filter_match(d, true) {
                        d.cursor = idx;
                    }
                } else {
                    d.cursor = (d.cursor + 1).min(d.hunks.len().saturating_sub(1));
                }
            }
            KeyCode::Char('p') | KeyCode::Char('[') => {
                if !d.filter.is_empty() {
                    if let Some(idx) = crate::ui::diff_view::next_filter_match(d, false) {
                        d.cursor = idx;
                    }
                } else {
                    d.cursor = d.cursor.saturating_sub(1);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                d.scroll = 0;
                d.cursor = 0;
            }
            KeyCode::End | KeyCode::Char('G') => d.scroll = usize::MAX,
            // `w` toggles wrap (sibling chord to the `[Wrap]` toolbar
            // button). Pref updated below after the borrow on `d`.
            KeyCode::Char('w') => d.wrap = !d.wrap,
            // `v` cycles view modes Hunk → Inline → Split → Hunk
            // (matches the toolbar button order so muscle-memory
            // lines up with the visual layout).
            KeyCode::Char('v') => {
                d.view_mode = match d.view_mode {
                    crate::pane::DiffViewMode::Hunk => crate::pane::DiffViewMode::Inline,
                    crate::pane::DiffViewMode::Inline => crate::pane::DiffViewMode::Split,
                    crate::pane::DiffViewMode::Split => crate::pane::DiffViewMode::Hunk,
                };
            }
            KeyCode::Char('s') => app.apply_cursor_hunk(false),
            KeyCode::Char('u') => app.apply_cursor_hunk(true),
            KeyCode::Char('r') => app.refresh_active_diff(),
            KeyCode::Char('f') => app.diff_jump_file(true),
            KeyCode::Char('F') => app.diff_jump_file(false),
            KeyCode::Enter => app.jump_to_cursor_hunk(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        // Sync App-level prefs from the (possibly just-updated) pane
        // state. `v` / `w` chords mutate `d` first; the next diff open
        // should pick up that mode/wrap as the new default.
        if let Some(Pane::Diff(d)) = app.panes.get(i) {
            app.diff_view_mode_pref = d.view_mode;
            app.diff_wrap_pref = d.wrap;
        }
        return true;
    }
    false
}

fn handle_request_key(app: &mut App, key: KeyEvent, viewport: usize, i: usize) -> bool {
    // nvchad SEV-1 fix 2026-07-10 — vim users hit `:` for ex-cmd
    // (`:w`, `:bn`, `:q`). The Request pane's URL/Method fields
    // ate the `:` literally; a subsequent Enter fired a real
    // network request against the mangled URL. Route `:` to the
    // ex-cmd prompt when the input style is vim + the pane's
    // active edit field is URL or Method (single-line "chip"
    // fields where colon-typing is rare) — Body / Headers /
    // Vars / Auth still accept literal `:` because those are
    // multi-line prose fields where a colon is expected
    // syntax.
    if app.config.editor.input_style == "vim"
        && key.code == KeyCode::Char(':')
        && !key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        && let Some(Pane::Request(rp)) = app.panes.get(i)
        && matches!(rp.view, crate::request_pane::ViewMode::Edit)
        && matches!(
            rp.focus,
            crate::request_pane::EditField::Url | crate::request_pane::EditField::Method
        )
    {
        app.open_ex_command_prompt();
        return true;
    }
    if let Some(Pane::Request(rp)) = app.panes.get_mut(i) {
        use crate::request_pane::ViewMode;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        // Promote out of preview on any edit-triggering keystroke.
        // Navigation-only keys (arrows, tab, esc, page-up/down)
        // leave preview intact so the user can arrow around the
        // pane without committing to keep the tab.
        // 2026-07-08 user report: preview → permanent on first edit.
        if rp.is_preview {
            let is_editing = matches!(
                key.code,
                KeyCode::Char(_) | KeyCode::Backspace | KeyCode::Delete | KeyCode::Enter
            );
            if is_editing {
                rp.is_preview = false;
            }
        }
        // In-place value-cell edit on an existing KV row. Same
        // Tab/Enter/Esc/text-input rhythm as the draft row, but
        // there's no `key` field — Tab does nothing, Enter
        // commits (replaces the row's value), Esc cancels.
        if rp.view == ViewMode::Edit && rp.kv_edit.is_some() {
            match key.code {
                KeyCode::Esc => {
                    let _ = rp;
                    app.http_kv_edit_cancel();
                    return true;
                }
                // Enter + Tab both commit. Tab is the spreadsheet-
                // native gesture and lets keyboard users chain
                // edits by clicking the next cell.
                KeyCode::Enter | KeyCode::Tab => {
                    let _ = rp;
                    app.http_kv_edit_commit();
                    return true;
                }
                KeyCode::Backspace => {
                    if let Some(e) = rp.kv_edit.as_mut() {
                        e.buffer.pop();
                        e.cursor = e.buffer.len();
                    }
                    return true;
                }
                KeyCode::Char(c) if !ctrl => {
                    if let Some(e) = rp.kv_edit.as_mut() {
                        e.buffer.push(c);
                        e.cursor = e.buffer.len();
                    }
                    return true;
                }
                _ => {}
            }
        }
        // Inline KV draft (Params OR Headers). Same key handling
        // for both — dispatch by which is currently active.
        let params_active = rp.view == ViewMode::Edit && rp.params_add.is_some();
        let headers_active = rp.view == ViewMode::Edit && rp.headers_add.is_some();
        if params_active || headers_active {
            let cancel = |app: &mut App| {
                if headers_active {
                    app.http_headers_add_cancel();
                } else {
                    app.http_params_add_cancel();
                }
            };
            let commit = |app: &mut App, cont: bool| {
                if headers_active {
                    app.http_headers_add_commit(cont);
                } else {
                    app.http_params_add_commit(cont);
                }
            };
            // Local helper — grab a &mut to whichever draft is
            // active. Inline to avoid closure lifetime pain.
            macro_rules! draft_mut {
                ($rp:expr) => {
                    if headers_active {
                        $rp.headers_add.as_mut()
                    } else {
                        $rp.params_add.as_mut()
                    }
                };
            }
            match key.code {
                KeyCode::Esc => {
                    let _ = rp;
                    cancel(app);
                    return true;
                }
                KeyCode::Enter if !shift => {
                    let _ = rp;
                    commit(app, true);
                    return true;
                }
                KeyCode::Enter if shift => {
                    let _ = rp;
                    commit(app, false);
                    return true;
                }
                KeyCode::Tab | KeyCode::BackTab => {
                    if let Some(d) = draft_mut!(rp) {
                        d.on_value = !d.on_value;
                    }
                    return true;
                }
                KeyCode::Char(':') => {
                    if let Some(d) = draft_mut!(rp) {
                        if d.on_value {
                            d.value.push(':');
                            d.value_cursor = d.value.len();
                        } else {
                            d.on_value = true;
                        }
                    }
                    return true;
                }
                KeyCode::Backspace => {
                    if let Some(d) = draft_mut!(rp) {
                        if d.on_value {
                            d.value.pop();
                            d.value_cursor = d.value.len();
                        } else {
                            d.key.pop();
                            d.key_cursor = d.key.len();
                        }
                    }
                    return true;
                }
                KeyCode::Char(c) if !ctrl => {
                    if let Some(d) = draft_mut!(rp) {
                        if d.on_value {
                            d.value.push(c);
                            d.value_cursor = d.value.len();
                        } else {
                            d.key.push(c);
                            d.key_cursor = d.key.len();
                        }
                    }
                    return true;
                }
                _ => {}
            }
        }
        if rp.view == ViewMode::Edit {
            match key.code {
                // Ctrl+Shift+V — paste curl from clipboard +
                // populate Method / URL / Headers / Body in one go.
                // The Postman-style "I just copied a curl from
                // Chrome DevTools" workflow. Plain Ctrl+V keeps
                // standard "paste into the focused field" behavior.
                KeyCode::Char('v') if ctrl && shift => {
                    let _ = rp;
                    app.http_paste_curl_to_active();
                    return true;
                }
                // Shift+Alt+F — format the Body (JSON reformat with
                // indentation). VS Code's format chord. Was Alt+F
                // but that opens the File menu bar dropdown; was
                // Ctrl+Shift+F before that but the global find.grep
                // keymap wins over pane-local handlers. Shift+Alt+F
                // doesn't collide with either. Users can also click
                // the Format button in the top-row action strip.
                // No-op on non-JSON Body (toast explains).
                KeyCode::Char('F') if shift && key.modifiers.contains(KeyModifiers::ALT) => {
                    let _ = rp;
                    app.http_format_body();
                    return true;
                }
                KeyCode::Char('f') if shift && key.modifiers.contains(KeyModifiers::ALT) => {
                    let _ = rp;
                    app.http_format_body();
                    return true;
                }
                // Ctrl+\ — cycle Request/Response split orientation
                // (Vertical top/bottom <-> Horizontal left/right).
                // Same effect as clicking the [ ▥ ▤ ] chip on the
                // Request block's title bar.
                KeyCode::Char('\\') if ctrl => {
                    rp.split_orientation = rp.split_orientation.toggle();
                    return true;
                }
                // Ctrl+Right / Ctrl+Left — cycle the Response
                // sub-tab (Body → Headers → Timeline → Tests).
                // Complements Ctrl+] / Ctrl+[ (which cycle the
                // Request-side tab strip).
                KeyCode::Right if ctrl => {
                    rp.response_tab = rp.response_tab.next();
                    return true;
                }
                KeyCode::Left if ctrl => {
                    rp.response_tab = rp.response_tab.prev();
                    return true;
                }
                // Ctrl+Enter — parse the Source-tab buffer into
                // the structured fields. Companion chord to
                // Ctrl+Shift+V for users who'd rather type/paste
                // into the Source field than work clipboard-first.
                KeyCode::Enter if ctrl => {
                    let _ = rp;
                    app.http_parse_source_buffer();
                    return true;
                }
                // Ctrl+] / Ctrl+[ cycle the Edit-view tab strip
                // (Body → Headers → Params → Vars → Source → Body).
                // VS Code-style "next/prev" chords. Distinct from
                // Tab (field cycle) and Ctrl+Shift+V (paste curl).
                KeyCode::Char(']') if ctrl => {
                    rp.edit_tab = rp.edit_tab.next();
                    return true;
                }
                KeyCode::Char('[') if ctrl => {
                    rp.edit_tab = rp.edit_tab.prev();
                    return true;
                }
                KeyCode::Tab if shift => rp.focus_prev_field(),
                // Tab inside Body inserts a literal `\t` (multi-line code-y
                // field — typing indented JSON / XML is common). Other
                // fields keep the form-cycle gesture so the user can walk
                // URL → Method → Headers → Body → URL.
                KeyCode::Tab if rp.focus == crate::request_pane::EditField::Body => {
                    rp.type_char('\t');
                }
                KeyCode::Tab => rp.focus_next_field(),
                KeyCode::BackTab => rp.focus_prev_field(),
                // 2026-06-19 — vscode-user-keyboard agent flagged
                // that Esc-from-Edit jumping to the tree was
                // unexpected (Tab toggles to Response; Esc should
                // be the inverse, not "leave the pane entirely").
                // Now Esc toggles back to Response view.
                KeyCode::Esc => rp.view = crate::request_pane::ViewMode::Response,
                KeyCode::Backspace => rp.backspace(),
                KeyCode::Left => rp.move_left(),
                KeyCode::Right => rp.move_right(),
                KeyCode::Home => rp.move_home(),
                KeyCode::End => rp.move_end(),
                KeyCode::Up
                    if matches!(
                        rp.focus,
                        crate::request_pane::EditField::Body
                            | crate::request_pane::EditField::Headers
                    ) =>
                {
                    // Cross-line motion for multi-line fields (URL is one line).
                    rp.move_left();
                    rp.move_home();
                }
                KeyCode::Down
                    if matches!(
                        rp.focus,
                        crate::request_pane::EditField::Body
                            | crate::request_pane::EditField::Headers
                    ) =>
                {
                    rp.move_end();
                    rp.move_right();
                }
                KeyCode::Enter => {
                    if matches!(
                        rp.focus,
                        crate::request_pane::EditField::Body
                            | crate::request_pane::EditField::Headers
                    ) {
                        rp.type_char('\n');
                    } else {
                        // Enter on URL/Method = fire the request.
                        app.send_request_from_active();
                    }
                }
                KeyCode::Char(c) if !ctrl => {
                    // `r` from URL / Method fires; `r` inside multi-line fields
                    // is a literal char (so typing "Authorization" etc. works).
                    // 2026-06-19 — vscode-user-keyboard agent caught
                    // SEV-1: the earlier `if c == 'r' && !multi_line`
                    // branch made it impossible to type any URL
                    // containing the letter 'r' (which is most URLs).
                    // `r` to re-fire belongs ONLY in Response view —
                    // see the `KeyCode::Char('r')` arm below at line
                    // 4723. In Edit view, every printable char goes
                    // to the focused field.
                    rp.type_char(c);
                }
                _ => {}
            }
            return true;
        }
        // Filter input has priority when focused — chars append to
        // the filter, Backspace pops, Enter commits + unfocuses, Esc
        // clears + unfocuses. Matches the sidebar-filter idiom (#11).
        // Tab exits filter mode AND falls through to the outer view-
        // toggle handler so the user never gets stuck with no way to
        // reach Edit view (reviewer catch — the sidebar-filter idiom
        // has nothing underneath it; here the Response view lives on).
        if rp.filter_focused {
            match key.code {
                KeyCode::Esc => {
                    rp.filter.clear();
                    rp.filter_focused = false;
                    return true;
                }
                KeyCode::Enter => {
                    rp.filter_focused = false;
                    return true;
                }
                KeyCode::Backspace => {
                    rp.filter.pop();
                    return true;
                }
                KeyCode::Tab => {
                    // Exit filter mode + fall through so Tab still
                    // toggles Edit ⇄ Response.
                    rp.filter_focused = false;
                }
                KeyCode::Char(c) if !ctrl => {
                    rp.filter.push(c);
                    return true;
                }
                _ => return true,
            }
        }
        match key.code {
            KeyCode::Tab => rp.toggle_view(),
            // `/` focuses the filter input — matches the
            // Integrations / Agents / Settings / Cloud Agents idiom.
            // Filter applies to header rows (Edit-tab Headers list,
            // request-summary headers, response headers).
            KeyCode::Char('/') if !ctrl => rp.filter_focused = true,
            KeyCode::Up | KeyCode::Char('k') => rp.scroll = rp.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => rp.scroll += 1,
            KeyCode::PageUp => rp.scroll = rp.scroll.saturating_sub(viewport),
            KeyCode::PageDown => rp.scroll += viewport,
            // Half-page motions — vim-consistent with editor + AI pane.
            // api-workflow round 5 SEV-3 2026-07-11.
            KeyCode::Char('d') if ctrl => rp.scroll += viewport / 2,
            KeyCode::Char('u') if ctrl => rp.scroll = rp.scroll.saturating_sub(viewport / 2),
            KeyCode::Home | KeyCode::Char('g') => rp.scroll = 0,
            KeyCode::End | KeyCode::Char('G') => rp.scroll = usize::MAX, // clamped on draw
            // 2026-06-21 nvchad SEV-2: bare `r` re-fired the
            // request — destructive on PUT/DELETE. Bare `a` opened
            // an AI debug pane that bills tokens. Both were a
            // hostile match for a vim user's `r<char>` (replace)
            // and `a` (append) reflexes. Now: capital `R` re-fires
            // (vim canon for replace-mode actions of consequence),
            // `.` keeps the AI debug binding (was paired with `a`),
            // and the `a` chord is removed. The cheatsheet headers
            // are updated separately.
            KeyCode::Char('R') => app.send_request_from_active(),
            KeyCode::Char('y') => app.copy_active_curl(),
            KeyCode::Char('Y') => app.copy_active_response_body(),
            KeyCode::Char('e') => rp.toggle_view(),
            // Toggle response body word-wrap. Off by default; long
            // lines clip. `w` = wrap on/off. (#11)
            KeyCode::Char('w') => rp.body_wrap = !rp.body_wrap,
            KeyCode::Char('.') => app.ai_debug_request(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return true;
    }
    false
}
