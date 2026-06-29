//! Right-click (`MouseEventKind::Down(MouseButton::Right)`) dispatch
//! — extracted from `mouse/mod.rs` (T-4 of the file-split refactor,
//! 2026-06-29). The right-click handler is a ~440-line cascade of
//! `if let Some(rect) = ...rects.X && contains(*, x, y) { open_X_menu;
//! return; }` early-outs. Cleanly isolatable since every arm returns
//! after consuming.
//!
//! Public surface: `handle_right_click(app, x, y)`. Called from
//! `dispatch_mouse`'s `MouseEventKind::Down(MouseButton::Right)`
//! arm. Returns nothing — its `return;`s exit this function only,
//! after which the caller's match arm completes naturally.

use crate::app::App;
use crate::pane::Pane;

pub(super) fn handle_right_click(app: &mut App, x: u16, y: u16) {
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
    // mouse-hunter v3 SEV-2 F — right-click on a right-panel
    // tab chip opens a small context menu (switch to / close).
    if let Some(&(_, tab_idx)) = app
        .rects
        .right_panel_tabs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.open_right_panel_tab_context_menu(tab_idx, (x, y));
        return;
    }
    // vscode-user-mouse 2026-06-28 SEV-3 — right-click on the
    // panel × close button (was a 1-cell dead zone). Open
    // the same active-tab menu the right-click on a tab
    // chip would for parity. If no tab is hosted, toast.
    if let Some(rect) = app.rects.right_panel_close
        && crate::app::dispatch::contains(rect, x, y)
    {
        let idx = app.right_panel_active_idx;
        if !app.right_panel_panes.is_empty() && idx < app.right_panel_panes.len() {
            app.open_right_panel_tab_context_menu(idx, (x, y));
        } else {
            app.toast("right panel empty — Ctrl+Shift+B to hide");
        }
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
    // qa-6th mouse SEV-3 2026-06-29: mixr chip on the statusline
    // had a left-click action (mixr.show) but no right-click menu
    // and no hover tooltip — felt like a black box. Added a small
    // menu: open mixr in a pane, or copy the now-playing track.
    if let Some(r) = app.rects.statusline_mixr_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![MenuItem::new("Open mixr", MenuAction::Command("mixr.show"))];
        app.context_menu = Some(ContextMenu::new(Some("mixr".to_string()), (x, y), items));
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
    // copy-as-curl / send / toggle view.
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
    // promote menu.
    if let Some(cur) = app.active
        && matches!(app.panes.get(cur), Some(Pane::Ai(_)))
    {
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
    // Right-click on an editor gutter → per-line menu.
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
    // Right-click on the editor BODY → text-scoped menu.
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
    // 2026-06-22 — per-split tab chips also get a right-click context menu.
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
    // Right-click on a git-palette row.
    if let Some(&(_, hit)) = app
        .rects
        .git_palette_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        match hit {
            crate::ui::git_palette::GitPaletteHit::Branch(i) => {
                app.open_git_rail_context_menu(crate::git::rail::GitRailHit::Branch(i), (x, y));
            }
            crate::ui::git_palette::GitPaletteHit::Worktree(i) => {
                app.open_git_rail_context_menu(crate::git::rail::GitRailHit::Worktree(i), (x, y));
            }
            crate::ui::git_palette::GitPaletteHit::Pull(i) => {
                app.open_git_rail_context_menu(crate::git::rail::GitRailHit::Pull(i), (x, y));
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
    // Right-click on a Diff / GitStatus list-row.
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
