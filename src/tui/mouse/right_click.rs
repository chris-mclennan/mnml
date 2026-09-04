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

/// Right-click on any panel's ↻ chip opens the refresh menu. Listed in
/// one place so a new panel with a chip is one line, not a new idiom.
fn refresh_chip_menu_hit(app: &crate::app::App, x: u16, y: u16) -> Option<&'static str> {
    let chips: [(Option<ratatui::layout::Rect>, &'static str); 7] = [
        (app.rects.todos_panel_refresh_chip, "todos"),
        (app.rects.notes_panel_refresh_chip, "notes"),
        (app.rects.findings_panel_refresh_chip, "findings"),
        (app.rects.sessions_panel_refresh_chip, "sessions"),
        (app.rects.agents_panel_refresh_chip, "agents"),
        (app.rects.cloud_agents_refresh_chip, "cloud_agents"),
        (app.rects.git_palette_refresh_chip, "git"),
    ];
    chips
        .iter()
        .find(|(r, _)| r.is_some_and(|r| crate::app::dispatch::contains(r, x, y)))
        .map(|(_, id)| *id)
}

/// Right-click on any panel's `sort:` chip. Same one-line-per-panel
/// shape as [`refresh_chip_menu_hit`], and for the same reason.
fn sort_chip_hit(app: &crate::app::App, x: u16, y: u16) -> Option<&'static str> {
    let chips: [(Option<ratatui::layout::Rect>, &'static str); 3] = [
        (app.rects.todos_panel_sort_chip, "todos"),
        (app.rects.notes_panel_sort_chip, "notes"),
        (app.rects.findings_panel_sort_chip, "findings"),
    ];
    chips
        .iter()
        .find(|(r, _)| r.is_some_and(|r| crate::app::dispatch::contains(r, x, y)))
        .map(|(_, id)| *id)
}

pub(super) fn handle_right_click(app: &mut App, x: u16, y: u16) {
    // Checked FIRST: the chips sit inside their panels' headers, so a
    // later panel-body branch would otherwise swallow the click.
    if let Some(panel) = refresh_chip_menu_hit(app, x, y) {
        app.open_refresh_chip_menu(panel, (x, y));
        return;
    }
    if let Some(panel) = sort_chip_hit(app, x, y) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let cur = app.panel_sort(panel);
        let items = crate::ui::list_sort::ListSort::all()
            .iter()
            .map(|m| {
                // The ✓ marks the active mode, matching the CLOUD
                // AGENTS density menu. Two leading spaces on the
                // others so the labels stay column-aligned.
                let label = if *m == cur {
                    format!("\u{2713} {}", m.label())
                } else {
                    format!("  {}", m.label())
                };
                MenuItem::new(
                    label,
                    MenuAction::SetPanelSort(panel.to_string(), m.as_str().to_string()),
                )
            })
            .collect::<Vec<_>>();
        app.context_menu = Some(ContextMenu::new(Some("Sort by".to_string()), (x, y), items));
        return;
    }
    if let Some(r) = app.rects.sessions_panel_sort_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let cur = app.sessions_sort_mode;
        let items = crate::app::SessionsSortMode::all()
            .iter()
            .map(|m| {
                let label = if *m == cur {
                    format!("\u{2713} {}", m.label())
                } else {
                    format!("  {}", m.label())
                };
                MenuItem::new(
                    label,
                    MenuAction::Command(match m {
                        crate::app::SessionsSortMode::Auto => "sessions.sort_auto",
                        crate::app::SessionsSortMode::Manual => "sessions.sort_manual",
                    }),
                )
            })
            .collect::<Vec<_>>();
        app.context_menu = Some(ContextMenu::new(Some("Sort by".to_string()), (x, y), items));
        return;
    }
    if let Some(r) = app.rects.statusline_notif_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_notification_bell_menu((x, y));
        return;
    }
    if app.debug_click_inspector {
        let hits = app.rects.inspect_click_targets(x, y);
        let msg = if hits.is_empty() {
            format!("right-click @ ({x}, {y}): no PaneRects hit")
        } else {
            format!("right-click @ ({x}, {y}): {}", hits.join(" · "))
        };
        app.toast(msg);
    }
    // Right-click on a `{{var}}` token → var context menu (set
    // value, jump to definition, copy name). Checked first because
    // token rects overlap the URL / body / value-cell rects that
    // fall through to more generic menus below.
    if let Some((_, name)) = app
        .rects
        .request_var_click_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let name = name.clone();
        app.open_request_var_context_menu(&name, (x, y));
        return;
    }
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
    // Right-click on the "+ New session" chip → batch-spawn menu
    // (task #1181 f/u, 2026-08-23) — user asked: "right click on
    // new session and it should offer x2 or x4 or x8".
    if let Some(r) = app.rects.session_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_new_session_batch_menu((x, y));
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
    // Claude Agents dashboard row → context menu. Currently 6
    // items: Open transcript / Resume in mnml pty / Yank session
    // id / Yank cwd / Export as markdown / Kill session.
    // (qa-6th 2026-06-29 doc fix — was claiming 7.)
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
    // #polish 2026-07-06 — right-click on the GIT rail header
    // opens a small menu with Refresh / Collapse-section /
    // Fetch quick actions.
    if let Some(r) = app.rects.git_section_toggle
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Fetch", MenuAction::Command("git.fetch")),
            MenuItem::new("Pull", MenuAction::Command("git.pull")),
            MenuItem::new("Open graph", MenuAction::Command("git.graph")),
        ];
        app.context_menu = Some(ContextMenu::new(
            Some("Git rail".to_string()),
            (x, y),
            items,
        ));
        return;
    }
    // #polish 2026-07-06 — right-click on the Cloud Agents view
    // chip → density menu (both options + toggle for consistency).
    if let Some(r) = app.rects.cloud_agents_view_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let cur = app.cloud_agents_view;
        let compact_label = if cur == crate::app::CloudAgentsView::Compact {
            "✓ Compact"
        } else {
            "  Compact"
        };
        let standard_label = if cur == crate::app::CloudAgentsView::Standard {
            "✓ Standard"
        } else {
            "  Standard"
        };
        let items = vec![
            MenuItem::new(
                compact_label,
                MenuAction::Command("cloud_agents.view_compact"),
            ),
            MenuItem::new(
                standard_label,
                MenuAction::Command("cloud_agents.view_standard"),
            ),
        ];
        app.context_menu = Some(ContextMenu::new(
            Some("Row density".to_string()),
            (x, y),
            items,
        ));
        return;
    }
    // #polish 2026-07-06 — right-click on a Notes-panel file row.
    if let Some((i, path)) = app
        .rects
        .notes_panel_files
        .iter()
        .position(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|i| (i, app.rects.notes_panel_files[i].1.clone()))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        // Move the cursor to the row being acted on. The FINDINGS
        // branch below does this and its comment says it mirrors
        // NOTES — but NOTES never did, so the menu could name one row
        // while the highlight sat on another. Window index plus
        // scroll, not the list index.
        app.notes_panel_cursor = i + app.notes_panel_scroll;
        let rel = crate::app::rel_path(&app.workspace, &path);
        let title = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "note".to_string());
        let items = vec![
            MenuItem::new("Open", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Open in split", MenuAction::OpenInSplit(path.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInTree(path.clone())),
            MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(path.clone()),
            ),
            MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
            MenuItem::destructive("Delete…", MenuAction::Delete(path)),
        ];
        app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        return;
    }
    // 2026-09-03 — the top-right `+`. Its LEFT click makes a new tab
    // page (what its position promises); the full "Create…" menu that
    // #1210 put on the click lives here instead, so that affordance
    // survives without the button lying about what it does.
    if let Some(r) = app.rects.bufferline_new_tab_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::ContextMenu;
        let items = super::down_left::plus_menu_items(app);
        let mut menu = ContextMenu::new(Some("Create…".into()), (r.x, r.y + 1), items);
        // Only the `+` menu opts into curation — Pin / Hide make sense
        // for a launcher you own, not for a file's right-click menu.
        menu.curatable = true;
        menu.selected = 0;
        menu.interacted = true;
        app.context_menu = Some(menu);
        return;
    }
    // 2026-09-03 right-click audit — AGENTS rail rows. Both
    // neighbours in this rail (Cloud Agents rows, the Claude Agents
    // dashboard rows) open menus; these did not.
    //
    // The dashboard's `ai.dashboard.*` commands act on the ACTIVE
    // PANE's selection, so reusing that item list here would act on
    // whatever the dashboard has selected rather than the row under
    // the pointer. These items therefore carry the row's own data.
    if let Some(&(_, row_idx)) = app
        .rects
        .agents_panel_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(row) = app.agents_panel_rows.get(row_idx).cloned() {
            use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
            let mut items = vec![MenuItem::new(
                "Copy session id",
                MenuAction::CopyPath(row.session_id.clone()),
            )];
            // A Codex row's transcript path can be a sentinel, and a
            // cloud row has no local file at all — offering "Open
            // transcript" for either would be a dead row.
            if row.transcript_path.is_file() {
                items.insert(
                    0,
                    MenuItem::new(
                        "Open transcript",
                        MenuAction::OpenPath(row.transcript_path.clone()),
                    ),
                );
                items.push(MenuItem::new(
                    "Reveal in tree",
                    MenuAction::RevealInTree(row.transcript_path.clone()),
                ));
                items.push(MenuItem::new(
                    crate::app::reveal_in_files_label(),
                    MenuAction::RevealInFinder(row.transcript_path.clone()),
                ));
            }
            if let Some(cwd) = row.cwd.clone() {
                items.push(MenuItem::new(
                    "Copy workspace path",
                    MenuAction::CopyPath(cwd),
                ));
            }
            items.push(MenuItem::new(
                "Open agents dashboard",
                MenuAction::Command("ai.dashboard"),
            ));
            let title = if row.workspace.is_empty() {
                row.session_id.clone()
            } else {
                row.workspace.clone()
            };
            app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        }
        return;
    }
    // 2026-09-03 right-click audit — SEARCH result rows had a
    // left-click handler and no right-click branch, and nothing
    // enclosing them offers one. Same shape as the FINDINGS gap
    // below.
    if let Some(&(_, idx)) = app
        .rects
        .search_section_hit_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(hit) = app.search_hits.get(idx).cloned() {
            use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
            // Match the cursor to the row acted on, as the left-click
            // path does — otherwise the menu names one hit while the
            // highlight sits on another.
            app.search_selected = idx;
            let title = format!("{}:{}", hit.rel, hit.line + 1);
            let items = vec![
                MenuItem::new("Open", MenuAction::OpenPath(hit.path.clone())),
                MenuItem::new("Open in split", MenuAction::OpenInSplit(hit.path.clone())),
                MenuItem::new("Reveal in tree", MenuAction::RevealInTree(hit.path.clone())),
                MenuItem::new(
                    crate::app::reveal_in_files_label(),
                    MenuAction::RevealInFinder(hit.path.clone()),
                ),
                // The matched TEXT is the thing a user most often
                // wants off a search hit — more than the path.
                MenuItem::new("Copy match", MenuAction::CopyPath(hit.text.clone())),
                MenuItem::new(
                    "Copy path:line",
                    MenuAction::CopyPath(format!("{}:{}", hit.rel, hit.line + 1)),
                ),
            ];
            app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        }
        return;
    }
    // 2026-09-03 (user: "why cant i right click on findings?") — the
    // FINDINGS rows had rects and a left-click handler but were never
    // consulted here, so the right-click fell through to the generic
    // pane menu. Mirrors the NOTES branch above: both panels list
    // markdown files, so the same actions apply.
    if let Some((i, path)) = app
        .rects
        .findings_panel_files
        .iter()
        .position(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|i| (i, app.rects.findings_panel_files[i].1.clone()))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        // Move the cursor to the row being acted on, exactly as the
        // left-click path does — otherwise the menu names one row
        // while the highlight sits on another. Window index plus
        // scroll, not the list index.
        app.findings_panel_cursor = i + app.findings_panel_scroll;
        let rel = crate::app::rel_path(&app.workspace, &path);
        let title = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "finding".to_string());
        let items = vec![
            MenuItem::new("Open", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Open in split", MenuAction::OpenInSplit(path.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInTree(path.clone())),
            MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(path.clone()),
            ),
            MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
            MenuItem::destructive("Delete…", MenuAction::Delete(path)),
        ];
        app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        return;
    }
    // #polish 2026-07-06 — right-click on an activity-bar icon
    // opens a small menu with "Show / Focus this rail" (mirrors
    // left-click) + convenient jumps. Users familiar with VS
    // Code will recognize the pattern.
    if let Some(&(_, section)) = app
        .rects
        .activity_bar_icons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let (_, _, label, cmd_id) = section.meta();
        // Section-specific quick actions in addition to the
        // basic show/focus.
        let mut items: Vec<MenuItem> = Vec::new();
        items.push(MenuItem::new(
            format!("Show {label}"),
            MenuAction::Command(cmd_id),
        ));
        use crate::app::ActivitySection;
        match section {
            ActivitySection::Explorer => {
                items.push(MenuItem::new(
                    "Reveal active file",
                    MenuAction::Command("view.reveal_active"),
                ));
                items.push(MenuItem::new(
                    "Refresh tree",
                    MenuAction::Command("tree.refresh"),
                ));
            }
            ActivitySection::Http => {
                items.push(MenuItem::new(
                    "+ New request",
                    MenuAction::Command("http.new"),
                ));
                items.push(MenuItem::new(
                    "Paste curl from clipboard",
                    MenuAction::Command("http.paste_curl"),
                ));
            }
            ActivitySection::Notes => {
                items.push(MenuItem::new(
                    "+ New note",
                    MenuAction::Command("notes.new"),
                ));
            }
            ActivitySection::Todos => {
                items.push(MenuItem::new(
                    "Rescan",
                    MenuAction::Command("todos.refresh"),
                ));
            }
            ActivitySection::Agents => {
                items.push(MenuItem::new(
                    "Open dashboard",
                    MenuAction::Command("ai.dashboard"),
                ));
            }
            // mouse-round-16 F4 2026-07-17 — fill in the 5 sparse
            // "Show X"-only activity-bar menus with a section-
            // specific quick action. Each is a single well-scoped
            // verb the user hits most on that panel — not an
            // exhaustive list; users still have the palette for
            // everything else.
            ActivitySection::Search => {
                items.push(MenuItem::new(
                    "New search",
                    MenuAction::Command("find.grep"),
                ));
            }
            ActivitySection::Git => {
                items.push(MenuItem::new(
                    "Open git graph",
                    MenuAction::Command("git.graph"),
                ));
                items.push(MenuItem::new("Fetch", MenuAction::Command("git.fetch")));
                items.push(MenuItem::new("Commit…", MenuAction::Command("git.commit")));
            }
            ActivitySection::Debug => {
                items.push(MenuItem::new("Run", MenuAction::Command("dap.run")));
                items.push(MenuItem::new(
                    "Toggle breakpoint at cursor",
                    MenuAction::Command("dap.toggle_breakpoint"),
                ));
            }
            ActivitySection::Integrations => {
                items.push(MenuItem::new(
                    "Refresh integrations",
                    MenuAction::Command("integrations.refresh"),
                ));
                items.push(MenuItem::new(
                    "Refresh binary cache",
                    MenuAction::Command("integrations.refresh_binary_cache"),
                ));
            }
            ActivitySection::Sessions => {
                items.push(MenuItem::new(
                    "+ New Claude Code session",
                    MenuAction::Command("ai.claude_code_new"),
                ));
                items.push(MenuItem::new(
                    "+ New Codex session",
                    MenuAction::Command("ai.codex_new"),
                ));
            }
            ActivitySection::CloudAgents => {
                items.push(MenuItem::new(
                    "+ New cloud run",
                    MenuAction::Command("cloud_agents.new_run"),
                ));
                items.push(MenuItem::new(
                    "+ New from wizard",
                    MenuAction::Command("cloud_agents.new_run_wizard"),
                ));
            }
            // 2026-07-20 — LauncherIcon reorder + unpin actions.
            // Replace the default items entirely — "Show
            // Launcher" is not a real command (LauncherIcon is
            // click-to-fire, not a section). Then Move to
            // top / Move up / Move down / Move to bottom (matching
            // the sidebar chip right-click order the user
            // asked for) + Remove from activity bar.
            ActivitySection::LauncherIcon(idx) => {
                let idx_us = idx as usize;
                let list = &app.config.ui.activity_bar_pinned_integrations;
                let is_first = idx_us == 0;
                let is_last = idx_us + 1 >= list.len();
                let integ_id = list.get(idx_us).cloned();
                items.clear();
                if let Some(id) = integ_id.clone() {
                    // Custom launch item at the top so users can
                    // fire without hunting for the exact icon.
                    items.push(MenuItem::new(
                        "Launch",
                        MenuAction::LaunchPinnedIntegration(id.clone()),
                    ));
                    if !is_first {
                        items.push(MenuItem::new(
                            "Move to top",
                            MenuAction::MovePinnedIntegrationToTop(id.clone()),
                        ));
                        items.push(MenuItem::new(
                            "Move up",
                            MenuAction::MovePinnedIntegrationUp(id.clone()),
                        ));
                    }
                    if !is_last {
                        items.push(MenuItem::new(
                            "Move down",
                            MenuAction::MovePinnedIntegrationDown(id.clone()),
                        ));
                        items.push(MenuItem::new(
                            "Move to bottom",
                            MenuAction::MovePinnedIntegrationToBottom(id.clone()),
                        ));
                    }
                    items.push(MenuItem::new(
                        "Remove from activity bar",
                        MenuAction::RemoveIntegrationFromActivityBar(id),
                    ));
                }
            }
            _ => {}
        }
        app.context_menu = Some(ContextMenu::new(Some(label.to_string()), (x, y), items));
        return;
    }
    // #21 v6 — right-click on a response tab (Body / Headers /
    // Timeline / Tests) opens a small menu of tab-scoped actions.
    if let Some(tab) = app
        .rects
        .request_response_tabs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, t)| *t)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        use crate::request_pane::ResponseTab;
        let (title, items) = match tab {
            ResponseTab::Body => (
                "Response Body",
                vec![
                    MenuItem::new("Copy body", MenuAction::Command("http.copy_response_body")),
                    MenuItem::new("Format JSON", MenuAction::Command("http.format_body")),
                    MenuItem::new("Save to file…", MenuAction::Command("http.save_response")),
                ],
            ),
            ResponseTab::Headers => (
                "Response Headers",
                vec![MenuItem::new(
                    "Copy headers",
                    MenuAction::Command("http.copy_response_headers"),
                )],
            ),
            ResponseTab::Cookies => (
                "Response Cookies",
                vec![MenuItem::new(
                    "Copy Set-Cookie headers",
                    MenuAction::Command("http.copy_response_cookies"),
                )],
            ),
            ResponseTab::Timeline => (
                "Response Timeline",
                vec![
                    MenuItem::new(
                        "Copy timeline",
                        MenuAction::Command("http.copy_response_timeline"),
                    ),
                    MenuItem::new(
                        "Diff last two responses",
                        MenuAction::Command("http.diff_last_two"),
                    ),
                ],
            ),
            ResponseTab::Tests => (
                "Response Tests",
                vec![
                    MenuItem::new(
                        "Copy tests summary",
                        MenuAction::Command("http.copy_response_tests"),
                    ),
                    MenuItem::new("Re-run", MenuAction::Command("http.send")),
                ],
            ),
        };
        app.context_menu = Some(ContextMenu::new(Some(title.to_string()), (x, y), items));
        return;
    }
    // #21 v3 — right-click on Send / Save / Clear / Code chips
    // opens a small kebab-menu that surfaces the useful adjacent
    // actions (fire options for Send, save-as / open source for
    // Save, copy-as for Code).
    if let Some(r) = app.rects.request_send_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Send", MenuAction::Command("http.send")),
            MenuItem::new("Abort in-flight", MenuAction::Command("http.abort")),
            MenuItem::new(
                "Diff last two responses",
                MenuAction::Command("http.diff_last_two"),
            ),
        ];
        app.context_menu = Some(ContextMenu::new(Some("Send".to_string()), (x, y), items));
        return;
    }
    if let Some(r) = app.rects.request_save_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Save request", MenuAction::Command("http.save")),
            MenuItem::new(
                "Save response as mock",
                MenuAction::Command("http.save_mock"),
            ),
            MenuItem::new(
                "Save response to file…",
                MenuAction::Command("http.save_response"),
            ),
        ];
        app.context_menu = Some(ContextMenu::new(Some("Save".to_string()), (x, y), items));
        return;
    }
    // (Code chip menu references `http.generate_code`, which was
    // just added above alongside `http.save`.)
    if let Some(r) = app.rects.request_clear_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![MenuItem::new(
            "Clear request",
            MenuAction::Command("http.new"),
        )];
        app.context_menu = Some(ContextMenu::new(Some("Clear".to_string()), (x, y), items));
        return;
    }
    if let Some(r) = app.rects.request_code_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Copy as curl", MenuAction::Command("http.copy_curl")),
            MenuItem::new("Generate code…", MenuAction::Command("http.generate_code")),
        ];
        app.context_menu = Some(ContextMenu::new(Some("Code".to_string()), (x, y), items));
        return;
    }
    // #23 v2 — right-click on a Vars-tab row → Edit / Copy / Delete
    // shortcut menu (bypasses the two-step prompt for delete).
    if let Some(key) = app
        .rects
        .request_vars_rows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, k, _)| k.clone())
    {
        if !key.is_empty() {
            use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
            let items = vec![
                MenuItem::new("Edit…", MenuAction::CopyPath(format!("edit:{key}"))),
                MenuItem::new("Copy name", MenuAction::CopyPath(key.clone())),
                MenuItem::destructive("Delete…", MenuAction::Command("http.delete_env_key")),
            ];
            app.pending_env_key_delete = Some(key.clone());
            app.context_menu = Some(ContextMenu::new(Some(key), (x, y), items));
        }
        return;
    }
    // Right-click on the Request pane's Env chip — quick switch /
    // edit / clear-override menu.
    if let Some(r) = app.rects.request_env_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let has_override = app.http_env_override.is_some();
        let mut items = vec![
            MenuItem::new("Switch env…", MenuAction::Command("http.pick_env")),
            MenuItem::new("Edit env file", MenuAction::Command("http.edit_env")),
        ];
        if has_override {
            items.push(MenuItem::new(
                "Clear override",
                MenuAction::Command("http.reset_env"),
            ));
        }
        app.context_menu = Some(ContextMenu::new(Some("Env".to_string()), (x, y), items));
        return;
    }
    // Right-click on an HTTP-sidebar file row — Open / Reveal /
    // Delete / Copy path. Fixes the 9-scratch-file cleanup pain
    // from the mouse audit (was left-click-only = open, no way to
    // delete without dropping to the tree).
    if let Some(path) = app
        .rects
        .http_panel_files
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, p)| p.clone())
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let rel = crate::app::rel_path(&app.workspace, &path);
        let title = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| rel.clone());
        let items = vec![
            MenuItem::new("Open", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Open as text", MenuAction::OpenPathAsText(path.clone())),
            MenuItem::new("Open in split", MenuAction::OpenInSplit(path.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInTree(path.clone())),
            MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(path.clone()),
            ),
            MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
            MenuItem::destructive("Delete…", MenuAction::Delete(path)),
        ];
        app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        return;
    }
    // Right-click on RECENT row — open, copy curl, delete entry.
    if let Some(idx) = app
        .rects
        .http_panel_recent_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, i)| *i)
    {
        if let Some(entry) = app.http_panel_recent_cache.get(idx).cloned() {
            use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
            let (curl, method, url) = crate::http::history::entry_to_curl(&entry);
            let title = format!("{method} {}", &url[..40.min(url.len())]);
            let items = vec![
                MenuItem::new("Open as scratch", MenuAction::CopyPath(curl.clone())),
                MenuItem::new("Copy curl", MenuAction::CopyPath(curl)),
                MenuItem::new("Copy URL", MenuAction::CopyPath(url)),
            ];
            app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        }
        return;
    }
    // Right-click on CAPTURED row — open as curl / copy curl / copy URL.
    if let Some(idx) = app
        .rects
        .http_panel_captured_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, i)| *i)
    {
        if let Some(row) = app.http_panel_captured_cache.get(idx).cloned() {
            use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
            let curl = row.to_curl();
            let title = format!("{} {}", row.method, &row.url[..40.min(row.url.len())]);
            let items = vec![
                MenuItem::new("Open as scratch", MenuAction::CopyPath(curl.clone())),
                MenuItem::new("Copy curl", MenuAction::CopyPath(curl)),
                MenuItem::new("Copy URL", MenuAction::CopyPath(row.url)),
            ];
            app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        }
        return;
    }
    // Right-click on ENVS row — quick actions for that env file.
    if let Some(name) = app
        .rects
        .http_panel_env_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, n)| n.clone())
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        // Prefer `.mnml/env/<name>.env` (mnml-native), fall back to
        // `.rqst/env/<name>.env` (legacy). This matches
        // `EnvSet::load` precedence.
        let mnml_path = app
            .workspace
            .join(".mnml")
            .join("env")
            .join(format!("{name}.env"));
        let rqst_path = app
            .workspace
            .join(".rqst")
            .join("env")
            .join(format!("{name}.env"));
        let env_file = if mnml_path.exists() {
            mnml_path
        } else {
            rqst_path
        };
        let rel = crate::app::rel_path(&app.workspace, &env_file);
        let items = vec![
            MenuItem::new("Set active", MenuAction::Command("http.pick_env")),
            MenuItem::new("Open file", MenuAction::OpenPath(env_file.clone())),
            MenuItem::new("Copy name", MenuAction::CopyPath(name.clone())),
            MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(env_file.clone())),
            MenuItem::destructive("Delete…", MenuAction::Delete(env_file)),
        ];
        app.context_menu = Some(ContextMenu::new(Some(name), (x, y), items));
        return;
    }
    // Right-click on CHAINS row — Run / Open / Reveal / Delete.
    if let Some(path) = app
        .rects
        .http_panel_chain_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, p)| p.clone())
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "chain".to_string());
        let rel = crate::app::rel_path(&app.workspace, &path);
        let items = vec![
            MenuItem::new("Run chain", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Open file", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInTree(path.clone())),
            MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(path.clone()),
            ),
            MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            MenuItem::destructive("Delete…", MenuAction::Delete(path)),
        ];
        app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        return;
    }
    // #22 v4 — right-click on a Collections file row.
    if let Some(path) = app
        .rects
        .http_panel_collection_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, p)| p.clone())
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "request".to_string());
        let rel = crate::app::rel_path(&app.workspace, &path);
        let items = vec![
            MenuItem::new("Open", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Open as text", MenuAction::OpenPathAsText(path.clone())),
            MenuItem::new("Open in split", MenuAction::OpenInSplit(path.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInTree(path.clone())),
            MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(path.clone()),
            ),
            MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
            MenuItem::destructive("Delete…", MenuAction::Delete(path)),
        ];
        app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        return;
    }
    // #22 v4 — right-click on a Collections folder row.
    if let Some(dir) = app
        .rects
        .http_panel_collection_folder_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, d)| d.clone())
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = dir
            .file_name()
            .map(|s| format!("{}/", s.to_string_lossy()))
            .unwrap_or_else(|| "collection".to_string());
        let rel = crate::app::rel_path(&app.workspace, &dir);
        let items = vec![
            MenuItem::new("New request…", MenuAction::NewFile(dir.clone())),
            MenuItem::new("New sub-collection…", MenuAction::NewFolder(dir.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInTree(dir.clone())),
            MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(dir.clone()),
            ),
            MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(dir.clone())),
            MenuItem::destructive("Delete collection…", MenuAction::Delete(dir)),
        ];
        app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        return;
    }
    // Right-click on MOCKS row — Replay / Open / Reveal / Delete.
    if let Some(path) = app
        .rects
        .http_panel_mock_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, p)| p.clone())
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "mock".to_string());
        let rel = crate::app::rel_path(&app.workspace, &path);
        let items = vec![
            MenuItem::new("Replay mock", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Open file", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInTree(path.clone())),
            MenuItem::new(
                crate::app::reveal_in_files_label(),
                MenuAction::RevealInFinder(path.clone()),
            ),
            MenuItem::new("Copy path", MenuAction::CopyPath(rel)),
            MenuItem::destructive("Delete…", MenuAction::Delete(path)),
        ];
        app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
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
    // design-critic round-3 finding #3 2026-07-11 — the file chip's
    // tooltip promised a "buffer menu" on right-click but nothing
    // was wired. Fulfill the promise with a compact menu that
    // covers the common needs: reveal in tree, copy paths, close.
    if let Some(r) = app.rects.statusline_file_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_file_context_menu((x, y));
        return;
    }
    // design-critic round-3 finding #6 2026-07-11 — PR chip
    // right-click. Left-click already opens the URL; right-click
    // exposes copy actions so users can paste the URL / number into
    // a commit body, PR description, or chat message.
    if let Some(r) = app.rects.statusline_pr_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_pr_context_menu((x, y));
        return;
    }
    // mouse-round-9 SEV-3 2026-07-11 — palette back/forward buttons
    // right-click. Left-click steps buffer MRU; right-click shows
    // a picker of nav history + a "clear" option.
    if let Some(r) = app.rects.palette_back_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_palette_nav_context_menu(false, (x, y));
        return;
    }
    if let Some(r) = app.rects.palette_forward_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_palette_nav_context_menu(true, (x, y));
        return;
    }
    // mouse-round-7 SEV-2 2026-07-12 — sidebar / right-panel
    // toggle chips + dropdown chevron gained right-click menus so
    // the "chips have menus" mental model isn't broken on the
    // built-in chrome chips. Left-click on each is unchanged.
    if let Some(r) = app.rects.palette_sidebar_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let visible = app.tree_visible;
        let items = vec![
            MenuItem::new(
                if visible {
                    "Hide sidebar"
                } else {
                    "Show sidebar"
                },
                MenuAction::Command("view.toggle_tree"),
            ),
            MenuItem::new(
                "Reset sidebar width",
                MenuAction::Command("view.reset_tree_width"),
            ),
            MenuItem::new("Focus sidebar", MenuAction::Command("view.focus_tree")),
        ];
        app.context_menu = Some(ContextMenu::new(Some("Sidebar".to_string()), (x, y), items));
        return;
    }
    if let Some(r) = app.rects.palette_right_panel_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let visible = app.right_panel_visible;
        let items = vec![
            MenuItem::new(
                if visible {
                    "Hide right panel"
                } else {
                    "Show right panel"
                },
                MenuAction::Command("view.toggle_right_panel"),
            ),
            MenuItem::new(
                "Focus right panel",
                MenuAction::Command("view.focus_right_panel"),
            ),
            MenuItem::new("Add Outline", MenuAction::Command("outline.show")),
            MenuItem::new("Add Problems", MenuAction::Command("lsp.diagnostics")),
        ];
        app.context_menu = Some(ContextMenu::new(
            Some("Right panel".to_string()),
            (x, y),
            items,
        ));
        return;
    }
    if let Some(r) = app.rects.palette_dropdown_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Recent files", MenuAction::Command("picker.recent")),
            MenuItem::new(
                "Recent commands",
                MenuAction::Command("picker.recent_commands"),
            ),
            MenuItem::new("All files", MenuAction::Command("picker.files")),
            MenuItem::new("Command palette", MenuAction::Command("palette")),
        ];
        app.context_menu = Some(ContextMenu::new(Some("Open…".to_string()), (x, y), items));
        return;
    }
    // Stress meter — both the statusline chip and the top-right
    // mirror show the same menu. 2026-07-12 user request.
    if let Some(r) = app.rects.palette_stress_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_stress_meter_context_menu((x, y));
        return;
    }
    // Right-click on the bufferline `+` new-tab button — offer a
    // "New tab" menu with the reopen-closed action so users have a
    // mouse path to Ctrl+Shift+T. mouse-round-10 SEV-3 2026-07-12.
    if let Some(r) = app.rects.bufferline_new_tab_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_new_tab_context_menu((x, y));
        return;
    }
    // Right-click on the bufferline theme-toggle chip → theme menu.
    // Left-click already toggles primary ↔ configured alt; right-click
    // gives access to the picker + default reset. mouse-round-8 SEV-3
    // 2026-07-12.
    if let Some(r) = app.rects.bufferline_theme_toggle
        && crate::app::dispatch::contains(r, x, y)
    {
        // R7 vscode-mouse F1 2026-08-09 — enrich the theme menu with
        // a full theme list. Was: Pick theme… / Toggle / Reset — the
        // Pick opened a fuzzy picker overlay. That's one extra hop
        // when the user already knows which theme they want, and
        // Chrome's extension menu (the closest UI analog) lists
        // installed themes inline.
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let cur = crate::ui::theme::cur().name.to_string();
        let alt = app.config.ui.theme_toggle.clone();
        let mut items: Vec<MenuItem> = Vec::new();
        items.push(MenuItem::new(
            format!("Theme: {cur}"),
            MenuAction::Command("noop.info"),
        ));
        // The two "quick" actions stay at the top so muscle memory
        // survives — Toggle + Reset are the fastest common paths.
        items.push(MenuItem::new(
            match alt.as_deref() {
                Some(a) if !a.eq_ignore_ascii_case(&cur) => {
                    format!("Toggle → {a}")
                }
                Some(_) => "Toggle (primary ↔ alt)".to_string(),
                None => "Toggle (configure [ui] theme_toggle first)".to_string(),
            },
            MenuAction::Command("theme.toggle"),
        ));
        // #1023 (2026-08-18) — same command now enables tick-based
        // polling, so the menu label reflects the toggle state.
        if app.config.ui.theme_auto_system {
            items.push(MenuItem::new(
                "Auto: match system ● (stop syncing)",
                MenuAction::Command("theme.auto_system_off"),
            ));
        } else {
            items.push(MenuItem::new(
                "Auto: match system (light/dark)",
                MenuAction::Command("theme.auto_system"),
            ));
        }
        items.push(MenuItem::new(
            "Reset to config default",
            MenuAction::Command("theme.reset"),
        ));
        items.push(MenuItem::new(
            "Pick theme…  (fuzzy)",
            MenuAction::Command("theme.pick"),
        ));
        // Separator-style divider before the per-theme rows.
        items.push(MenuItem::new(
            "── themes ──".to_string(),
            MenuAction::Command("noop.info"),
        ));
        for name in crate::ui::theme::names() {
            let marker = if name.eq_ignore_ascii_case(&cur) {
                "●"
            } else {
                " "
            };
            items.push(MenuItem::new(
                format!("{marker} {name}"),
                MenuAction::SetTheme(name.to_string()),
            ));
        }
        app.context_menu = Some(ContextMenu::new(Some("Theme".to_string()), (x, y), items));
        return;
    }
    // vscode-user-mouse 2026-07-30 SEV-3 #10 — right-click on menu-
    // bar words. Was dead; users expect a "customize menu bar" or
    // mode-toggle affordance given every other chip has right-click.
    // Minimal menu: cycle menu-bar mode (auto / always / hidden).
    if app
        .rects
        .menu_bar_words
        .iter()
        .any(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let cur = app.config.ui.menu_bar.as_str();
        let items = vec![
            MenuItem::new(format!("Menu bar: {cur}"), MenuAction::Command("noop.info")),
            MenuItem::new(
                "Cycle mode (auto → always → hidden)",
                MenuAction::Command("view.menu_bar_cycle"),
            ),
        ];
        app.context_menu = Some(ContextMenu::new(
            Some("Menu Bar".to_string()),
            (x, y),
            items,
        ));
        return;
    }
    // vscode-user-mouse 2026-07-30 SEV-3 #6 — right-click on the
    // `×` window-close chip. Left-click always fires quit-confirm;
    // right-click gives quick access to Save-all-and-quit / Force-
    // quit (no-save) without going through the dialog.
    if let Some(r) = app.rects.bufferline_window_close
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Quit (with confirm)", MenuAction::Command("app.quit")),
            MenuItem::new("Save all", MenuAction::Command("file.save_all")),
            MenuItem::new("Restart", MenuAction::Command("app.restart")),
        ];
        app.context_menu = Some(ContextMenu::new(Some("mnml".to_string()), (x, y), items));
        return;
    }
    // Undo chip right-click — dismiss without committing. Left-click
    // commits; right-click cancels. mouse-round-10 SEV-3 2026-07-12.
    if let Some(r) = app.rects.pending_undo_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.pending_undo = None;
        app.toast("undo chip dismissed");
        return;
    }
    // Right-click on a toast body — offer a dismiss / dismiss-all
    // menu instead of falling through into the pane below.
    // mouse-round-10 SEV-2 2026-07-12.
    if let Some((idx, r)) = app
        .rects
        .toast_stack_rects
        .iter()
        .enumerate()
        .find(|(_, r)| crate::app::dispatch::contains(**r, x, y))
    {
        app.open_toast_context_menu(idx, (r.x, r.y));
        return;
    }
    if let Some(r) = app.rects.statusline_stress_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_stress_meter_context_menu((x, y));
        return;
    }
    // design-critic round-3 finding #6 batch 2 — remaining statusline
    // chips gain right-click menus.
    if let Some(r) = app.rects.statusline_diagnostics_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_diagnostics_context_menu((x, y));
        return;
    }
    if let Some(r) = app.rects.statusline_language_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_language_context_menu((x, y));
        return;
    }
    if let Some(r) = app.rects.statusline_lncol_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_lncol_context_menu((x, y));
        return;
    }
    if let Some(r) = app.rects.statusline_find_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_find_context_menu((x, y));
        return;
    }
    if let Some(r) = app.rects.statusline_sel_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_sel_context_menu((x, y));
        return;
    }
    if let Some(r) = app.rects.statusline_filesize_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_filesize_context_menu((x, y));
        return;
    }
    // #21 v2 — right-click coverage for the remaining statusline
    // chips (WRAP / LSP / Autosave / Test). Small menus that
    // surface the underlying palette commands so users can
    // discover config knobs without dropping to `:`.
    if let Some(r) = app.rects.statusline_wrap_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        // R9 vscode-mouse SEV-3 — the previous menu was a bare
        // one-item "Disable wrap" that hid the current state.
        // Now: title reveals state, single toggle row shows the
        // action that flips it, plus Settings jump for the
        // fold-arrows / per-buffer preferences a right-click user
        // would want next.
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let cur = app.config.ui.wrap;
        let title = format!("Wrap · {}", if cur { "on" } else { "off" });
        let toggle_label = if cur { "Disable wrap" } else { "Enable wrap" };
        let items = vec![
            MenuItem::new(toggle_label, MenuAction::Command("view.toggle_wrap")),
            MenuItem::new("Editor settings…", MenuAction::Command("view.settings")),
        ];
        app.context_menu = Some(ContextMenu::new(Some(title), (x, y), items));
        return;
    }
    // Autosave chip — no menu; the existing left-click already
    // toasts the current interval + how to change it. Adding a
    // right-click menu for "change interval" would just repeat
    // that toast (no dedicated command yet). Left-click is fine.
    if let Some(r) = app.rects.statusline_lsp_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        // mouse-round-8 SEV-3 2026-07-12 — was a single "Status" row
        // with a phantom empty row below. Now offers the LSP verbs a
        // user actually reaches for from the chip: symbols/references,
        // hover, code-actions, diagnostics, plus the raw status.
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            // `:LspStatus` is an EX-command, not a registered palette
            // id, so `MenuAction::Command` toasted `no such command`
            // — on the FIRST row of this menu. The left-click path
            // always used `run_ex_command`; `RunCmd` with a leading
            // colon is the menu equivalent.
            MenuItem::new("Status", MenuAction::RunCmd(":LspStatus".to_string())),
            MenuItem::new("Symbols in file", MenuAction::Command("lsp.symbols")),
            MenuItem::new(
                "Symbols in workspace",
                MenuAction::Command("lsp.workspace_symbols"),
            ),
            MenuItem::new("Diagnostics list", MenuAction::Command("lsp.diagnostics")),
            MenuItem::new("Find references", MenuAction::Command("lsp.references")),
            MenuItem::new("Rename symbol", MenuAction::Command("lsp.rename")),
            MenuItem::new("Format file", MenuAction::Command("lsp.format")),
            MenuItem::new("Code actions", MenuAction::Command("lsp.code_action")),
            MenuItem::new(
                "Toggle inlay hints",
                MenuAction::Command("lsp.inlay_hints_toggle"),
            ),
        ];
        app.context_menu = Some(ContextMenu::new(Some("LSP".to_string()), (x, y), items));
        return;
    }
    if let Some(r) = app.rects.statusline_test_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Run all", MenuAction::Command("test.run_all")),
            MenuItem::new("Run file", MenuAction::Command("test.run_file")),
            MenuItem::new("Run at cursor", MenuAction::Command("test.run_at_cursor")),
        ];
        app.context_menu = Some(ContextMenu::new(Some("Tests".to_string()), (x, y), items));
        return;
    }
    if let Some(r) = app.rects.statusline_clock_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_clock_context_menu((x, y));
        return;
    }
    // Task #915 (R5 SEV-2 F1) — AI Claude chip. Was silent on
    // right-click; menu now surfaces the same ai.* commands the
    // palette can invoke.
    if let Some(r) = app.rects.statusline_ai_claude_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_ai_context_menu((x, y), false);
        return;
    }
    // Task #915 (R5 SEV-2 F2) — AI Codex chip. Same menu.
    if let Some(r) = app.rects.statusline_ai_codex_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_ai_context_menu((x, y), true);
        return;
    }
    // Task #875 (R5 SEV-3 F8) — coverage chip right-click.
    if let Some(r) = app.rects.statusline_coverage_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_statusline_coverage_context_menu((x, y));
        return;
    }
    // #1102 (2026-08-20) — dynamic statusline segment (manifest-
    // declared / IPC-set). Walk `statusline_segment_hits` (already
    // in render order) and open the "Move left / Move right" menu
    // for whichever segment's rect contains (x, y).
    if let Some(idx) = app
        .rects
        .statusline_segment_hits
        .iter()
        .position(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.open_statusline_segment_context_menu(idx, (x, y));
        return;
    }
    // Sonos cluster right-click — every action the chip can take, in
    // one place, since three of the four click targets are glyphs.
    // Checked before the mixr chip: the clusters are adjacent.
    if [
        app.rects.statusline_sonos_chip,
        app.rects.statusline_sonos_play_chip,
        app.rects.statusline_sonos_next_chip,
        app.rects.statusline_sonos_label_chip,
    ]
    .into_iter()
    .flatten()
    .any(|r| crate::app::dispatch::contains(r, x, y))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        // Row 1 is a status read-out, not an action — same idiom as the
        // mixr menu's Beatport row.
        let status = app.sonos_status_line();
        let stream_label = if app.sonos.streaming {
            "Stop sending this Mac's audio"
        } else {
            "Send this Mac's audio here"
        };
        let mut items = vec![
            MenuItem::new(status, MenuAction::Command("sonos.status")),
            MenuItem::new(stream_label, MenuAction::Command("sonos.stream_mac_audio")),
            MenuItem::new(
                "Send Music.app here (AirPlay)…",
                MenuAction::Command("audio.airplay_music"),
            ),
            MenuItem::new(
                if app.sonos.state.is_playing() {
                    "Pause"
                } else {
                    "Play"
                },
                MenuAction::Command("sonos.play_pause"),
            ),
        ];
        // Skip rows only for a source that can actually skip — matching
        // the chip, which hides the glyph for TV / AirPlay / line-in.
        if matches!(app.sonos.track.source, crate::sonos::SourceKind::Queue) {
            items.push(MenuItem::new(
                "Next track",
                MenuAction::Command("sonos.next"),
            ));
            items.push(MenuItem::new(
                "Previous track",
                MenuAction::Command("sonos.previous"),
            ));
        }
        items.push(MenuItem::new(
            format!("Volume + (now {})", app.sonos.volume),
            MenuAction::Command("sonos.volume_up"),
        ));
        items.push(MenuItem::new(
            "Volume −",
            MenuAction::Command("sonos.volume_down"),
        ));
        items.push(MenuItem::new(
            if app.sonos.muted { "Unmute" } else { "Mute" },
            MenuAction::Command("sonos.mute"),
        ));
        items.push(MenuItem::new(
            "Favorites…",
            MenuAction::Command("sonos.favorites"),
        ));
        // Room switching / grouping only earn their rows in a household
        // that actually has more than one room.
        if app.sonos.players.len() > 1 {
            items.push(MenuItem::new("Room…", MenuAction::Command("sonos.rooms")));
            items.push(MenuItem::new(
                "Group all rooms here",
                MenuAction::Command("sonos.group_all"),
            ));
            items.push(MenuItem::new(
                "Ungroup this room",
                MenuAction::Command("sonos.ungroup"),
            ));
        }
        items.push(MenuItem::new(
            "Copy what's playing",
            MenuAction::Command("sonos.copy_track"),
        ));
        // Only worth a row when the output is actually parked on the
        // loopback device — otherwise it's a fix for a problem the user
        // doesn't have.
        #[cfg(target_os = "macos")]
        if crate::sonos::coreaudio::default_output().is_some_and(|d| {
            d.name
                .to_ascii_lowercase()
                .contains(crate::sonos::stream::LOOPBACK_NAME)
        }) {
            items.push(MenuItem::new(
                "Put my audio back on this Mac",
                MenuAction::Command("audio.restore_output"),
            ));
        }
        items.push(MenuItem::new(
            "Re-scan for speakers",
            MenuAction::Command("sonos.refresh"),
        ));
        items.push(MenuItem::new(
            "Hide chip",
            MenuAction::Command("sonos.hide"),
        ));
        app.context_menu = Some(ContextMenu::new(
            Some(app.sonos.room().to_string()),
            (x, y),
            items,
        ));
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
        // 2026-08-22 — menu shape:
        //   Row 1: Beatport auth status (● signed in / ○ not) —
        //           clicking toasts the same string, non-destructive.
        //   Row 2: Play a random chart (same as play-glyph click).
        //   Row 3: Open mixr (same as label click).
        //   Row 4: Copy track title (only when a track is playing).
        // The auto-play toggle from the previous menu was retired
        // once the chip split into [play] [label] — the play-glyph
        // IS the toggle-equivalent.
        let authed = crate::app::ai::mixr_beatport_authed();
        let favs = crate::app::ai::mixr_has_favorite_genres();
        let auth_label = match (authed, favs) {
            (true, true) => "● Beatport: signed in · favorites set",
            (true, false) => "● Beatport: signed in · no favorites",
            (false, _) => "○ Beatport: not signed in",
        };
        // 2026-08-22 — three-way preferred-app switcher rows. Radio-
        // style: `(●)` on the current pick, `( )` on the others. The
        // idle chip + play-glyph action follow this choice.
        let cur = app.config.ui.preferred_music_app.as_str();
        let mark = |v: &str| if cur == v { "(●)" } else { "( )" };
        let mut items = vec![
            MenuItem::new(auth_label, MenuAction::Command("mixr.show_auth_status")),
            MenuItem::new(
                format!("{} mixr (Beatport)", mark("mixr")),
                MenuAction::Command("mixr.set_preferred_mixr"),
            ),
            MenuItem::new(
                format!("{} Music", mark("music")),
                MenuAction::Command("mixr.set_preferred_music"),
            ),
            MenuItem::new(
                format!("{} Spotify", mark("spotify")),
                MenuAction::Command("mixr.set_preferred_spotify"),
            ),
            MenuItem::new("Play random chart", MenuAction::Command("mixr.play_now")),
            MenuItem::new("Open mixr", MenuAction::Command("mixr.show")),
            // #1130 — per-section shortcuts to mixr's four PanelSection
            // views. Browse is redundant with "Open mixr" (which
            // already targets browse) but keeping it in the list for
            // symmetry — matches what users see in mixr's own cycle.
            MenuItem::new("Show: Queue", MenuAction::Command("mixr.show_queue")),
            MenuItem::new("Show: History", MenuAction::Command("mixr.show_history")),
            MenuItem::new("Show: Browse", MenuAction::Command("mixr.show_browse")),
            MenuItem::new("Show: Log", MenuAction::Command("mixr.show_log")),
        ];
        if let Some(np) = app.now_playing.as_ref()
            && !np.track.is_empty()
        {
            items.push(MenuItem::new(
                "Copy track title",
                MenuAction::Command("mixr.copy_track"),
            ));
        }
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
    // 2026-07-31 — Right-click on a detail-pane link row → copy the
    // URL. Runs before the activity-panel chip check because a
    // click can land on both when the detail pane covers the
    // integration-panel area (right-panel host).
    if let Some((_, pane_id, url)) = app
        .rects
        .integration_detail_links
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(r, pid, url)| (*r, *pid, url.clone()))
    {
        crate::ui::integration_detail_view::copy_link_url(app, pane_id, url);
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
    // 2026-08-07 vscode-mouse r1 F2 — marketplace rows were the only
    // clickable list surface with a dead right-click. Simple menu
    // gives parity with other lists + saves the trip to the detail
    // pane for common quick-lookups.
    if let Some(&(_, entry_idx)) = app
        .rects
        .marketplace_row_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let entry = app.marketplace_entries.get(entry_idx).cloned();
        let items = if let Some(e) = entry {
            let is_installed = app.config.ui.integration_icons.iter().any(|i| i.id == e.id);
            let _ = &e;
            // 2026-08-07 design-critic r2 #3: lead with the state-
            // changing action (Install) when it's meaningful, matching
            // integration-chip menu convention. View details demoted
            // to second — it's a pure duplicate of left-click.
            let mut items: Vec<MenuItem> = Vec::new();
            if !is_installed {
                items.push(MenuItem::new(
                    "Install",
                    MenuAction::Command("marketplace.install_focused"),
                ));
            }
            items.push(MenuItem::new(
                "View details",
                MenuAction::Command("marketplace.open_detail_focused"),
            ));
            items.push(MenuItem::new(
                "Copy id",
                MenuAction::Command("marketplace.copy_id_focused"),
            ));
            items
        } else {
            vec![MenuItem::new(
                "View details",
                MenuAction::Command("marketplace.open_detail_focused"),
            )]
        };
        // Focus the row so the "focused" commands know which entry.
        app.pending_marketplace_install_idx = Some(entry_idx);
        app.context_menu = Some(ContextMenu::new(
            Some("Marketplace entry".into()),
            (x, y),
            items,
        ));
        return;
    }
    // 2026-08-01 (P2) — launcher-chip right-click routing deleted
    // with the LauncherIcon retirement. Integration chip menu covers
    // the surface.
    // Right-click on the TABS label → cluster mode chooser
    // (Expanded / Compact / Auto).
    if let Some(r) = app.rects.bufferline_tabs_label
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_top_bar_cluster_context_menu((x, y));
        return;
    }
    // mouse-round-16 F3 2026-07-17 — split-strip `[│]` / `[─]`
    // / `[$]` chips got no right-click menu. Left-click already
    // fires the primary action (H/V split; open shell) so this
    // is discoverability + orientation-choice for the split
    // arrows. Terminal chip gets Open shell / Open shell in split.
    if let Some(&(_, leaf_active, dir)) = app
        .rects
        .split_strip_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        if let Some(la) = leaf_active {
            app.active = Some(la);
        }
        let (title, items) = match dir {
            crate::layout::SplitDir::Horizontal => (
                "Split horizontal",
                vec![
                    MenuItem::new("Split right", MenuAction::Command("view.split_right")),
                    MenuItem::new(
                        "Equalize splits",
                        MenuAction::Command("view.equalize_splits"),
                    ),
                    MenuItem::new("Grow width", MenuAction::Command("view.split_grow_width")),
                    MenuItem::new(
                        "Shrink width",
                        MenuAction::Command("view.split_shrink_width"),
                    ),
                    MenuItem::new("Close active pane", MenuAction::Command("buffer.close")),
                ],
            ),
            crate::layout::SplitDir::Vertical => (
                "Split vertical",
                vec![
                    MenuItem::new("Split down", MenuAction::Command("view.split_down")),
                    MenuItem::new(
                        "Equalize splits",
                        MenuAction::Command("view.equalize_splits"),
                    ),
                    MenuItem::new("Grow height", MenuAction::Command("view.split_grow_height")),
                    MenuItem::new(
                        "Shrink height",
                        MenuAction::Command("view.split_shrink_height"),
                    ),
                    MenuItem::new("Close active pane", MenuAction::Command("buffer.close")),
                ],
            ),
        };
        app.context_menu = Some(ContextMenu::new(Some(title.into()), (x, y), items));
        return;
    }
    // R13 vscode-mouse SEV-3 2026-08-23 — maximize chip right-click
    // menu. Was missing, so mouse users couldn't discover
    // full-screen alongside per-leaf zoom (only left-click worked
    // and it flipped whichever state was already active).
    if let Some(&(_, leaf_active)) = app
        .rects
        .split_strip_maximize_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        if let Some(la) = leaf_active {
            app.active = Some(la);
        }
        let mut items = Vec::new();
        if app.zoomed_leaf.is_some() {
            items.push(MenuItem::new(
                "Restore split",
                MenuAction::Command("view.toggle_zoom"),
            ));
        } else {
            items.push(MenuItem::new(
                "Zoom this leaf",
                MenuAction::Command("view.toggle_zoom"),
            ));
        }
        if app.fullscreen_mode {
            items.push(MenuItem::new(
                "Exit full screen",
                MenuAction::Command("view.fullscreen"),
            ));
        } else {
            items.push(MenuItem::new(
                "Enter full screen",
                MenuAction::Command("view.fullscreen"),
            ));
        }
        items.push(MenuItem::new(
            "Equalize splits",
            MenuAction::Command("view.equalize_splits"),
        ));
        app.context_menu = Some(ContextMenu::new(Some("Maximize".into()), (x, y), items));
        return;
    }
    if let Some(&(_, leaf_active)) = app
        .rects
        .split_strip_term_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        if let Some(la) = leaf_active {
            app.active = Some(la);
        }
        // 2026-07-22 — match the AI-chip menu shape. Was: 2-item menu
        // (Open shell / Open scratch). User: "the terminal icon when
        // right clicked should allow more placement options."
        let items = vec![
            MenuItem::new("Open shell (beside)", MenuAction::Command("term.shell")),
            MenuItem::new(
                "Open shell in left half",
                MenuAction::Command("term.shell_left"),
            ),
            MenuItem::new(
                "Open shell in right half",
                MenuAction::Command("term.shell_right"),
            ),
            MenuItem::new(
                "Open shell in top half",
                MenuAction::Command("term.shell_top"),
            ),
            MenuItem::new(
                "Open shell in bottom half",
                MenuAction::Command("term.shell_bottom"),
            ),
            MenuItem::new(
                "Open scratch terminal",
                MenuAction::Command("term.scratch_toggle"),
            ),
        ];
        app.context_menu = Some(ContextMenu::new(Some("Terminal".into()), (x, y), items));
        return;
    }
    // Right-click on the split-strip AI button → choose
    // between Claude / Codex without changing the configured
    // default. Tab-strip Term + Split buttons are single-
    // action so they don't need menus.
    if let Some(&(_, leaf_active, tag)) = app
        .rects
        .split_strip_ai_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        if let Some(la) = leaf_active {
            app.active = Some(la);
        }
        // `tag == 1` = Codex chip; anything else (`0`) = Claude Code
        // — matches the down_left click routing.
        let is_codex = tag == 1;
        let (kind_label, new_cmd, toggle_cmd, left_cmd, right_cmd, top_cmd, bottom_cmd) =
            if is_codex {
                (
                    "Codex",
                    "ai.codex_new",
                    "ai.codex",
                    "ai.codex_new_left",
                    "ai.codex_new_right",
                    "ai.codex_new_top",
                    "ai.codex_new_bottom",
                )
            } else {
                (
                    "Claude Code",
                    "ai.claude_code_new",
                    "ai.claude_code",
                    "ai.claude_code_new_left",
                    "ai.claude_code_new_right",
                    "ai.claude_code_new_top",
                    "ai.claude_code_new_bottom",
                )
            };
        // design-critic 2026-07-09: the previous menu had two
        // items that ran the same code path — "Open new session
        // (right dock)" and "Place new session in right half"
        // both split horizontally and put the new pane on the
        // second (right) side. Dropped the parenthetical and
        // kept the four half-placement items so the six-item
        // menu now maps to five distinct outcomes: toggle
        // existing + place in {left, right, top, bottom}.
        // 2026-07-13 user requests — visibility toggles + glyph
        // edit access straight from the chip's own menu (was
        // config-only). Codepoint for the glyph builder is the
        // PUA slot each AI kind uses (F8B0 / F8B1); the builder
        // lets users nudge width/height/center to fix baseline
        // drift against integration codicons.
        // 2026-08-07 — dropped the `Show Claude only / Show Codex
        // only / Show both / Hide these icons` submenu. AI chip
        // visibility is now controlled per-chip through the
        // Integrations panel (right-click a chip → Enable/Disable,
        // persisted to ~/.config/mnml/integrations/<id>.toml). The
        // old `tab_bar_ai_icon` config knob is retained only for
        // backward-compat with older configs — new state should
        // never write it. `mark(...)` closure removed with the
        // items that used it.
        // 2026-07-19 — chip renderer moved from JBM-NF-patched
        // F8B0/F8B1 to mnml-owned F1E00/F1E01 in MnmlSymbols.ttf.
        // Point the glyph builder at the new codepoints so
        // "Edit glyph…" actually tunes what the chip renders.
        let glyph_cp: u32 = if is_codex { 0xF1E01 } else { 0xF1E00 };
        // Layout mode toggle — `[ui] ai_layout_mode` chooses
        // whether a new AI session grows the grid (auto-tile
        // splits, capped at 8) or just appends a tab to the
        // active leaf (single big pane, N tabs). 2026-07-19.
        let layout_mode = app.config.ui.ai_layout_mode.clone();
        let layout_mark = |val: &str| if layout_mode == val { "✓ " } else { "  " };
        // #1203 — launch-profile rows lead the menu when 2+ profiles
        // resolve (empty vec otherwise): pick a wrapper for one
        // session, or flip the persisted default.
        let chip_id = if is_codex { "codex" } else { "claude_code" };
        let mut items = app.ai_profile_menu_items(chip_id);
        items.extend(vec![
            MenuItem::new(
                format!("Toggle existing {kind_label} pane"),
                MenuAction::Command(toggle_cmd),
            ),
            MenuItem::new(
                format!("New {kind_label} session in left half"),
                MenuAction::Command(left_cmd),
            ),
            MenuItem::new(
                format!("New {kind_label} session in right half"),
                MenuAction::Command(right_cmd),
            ),
            MenuItem::new(
                format!("New {kind_label} session in top half"),
                MenuAction::Command(top_cmd),
            ),
            MenuItem::new(
                format!("New {kind_label} session in bottom half"),
                MenuAction::Command(bottom_cmd),
            ),
            // Layout mode toggle.
            MenuItem::new(
                format!("{}Layout: Grid (splits)", layout_mark("grid")),
                MenuAction::Command("view.ai_layout_grid"),
            ),
            MenuItem::new(
                format!("{}Layout: Tabs (stack in leaf)", layout_mark("tabs")),
                MenuAction::Command("view.ai_layout_tabs"),
            ),
            // Font glyph controls (2026-07-19). "Bake" installs the
            // AI chip glyphs into MnmlSymbols.ttf using the defaults
            // in `BUILTIN_GLYPHS`; "Edit" opens the glyph builder
            // for iterative center_frac tuning. (The "Use mnml AI
            // glyphs" toggle was retired 2026-08-25 with the F8B0/
            // F8B1 legacy pair — F1E00/F1E01 are unconditional now.)
            MenuItem::new(
                "Bake AI glyphs into MnmlSymbols",
                MenuAction::Command("integrations.bake_ai_glyphs"),
            ),
            MenuItem::new(
                format!("Edit {kind_label} glyph… (center)"),
                MenuAction::OpenGlyphBuilderForCp(glyph_cp),
            ),
        ]);
        // Suppress the unused vars from the earlier item set —
        // kept the local for the toggle path above.
        let _ = new_cmd;
        app.context_menu = Some(ContextMenu::new(
            Some(format!("{kind_label} launcher")),
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
        let items = vec![MenuItem::new(
            if app.integration_section_expanded {
                "Collapse section"
            } else {
                "Expand section"
            },
            MenuAction::Command("view.toggle_integrations_section"),
        )];
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
        // 2026-07-22 fix: also set `rp.focus` to the right-clicked
        // field. The Copy/Paste/Cut/Select-all menu items read
        // `rp.focus` — without this update they'd operate on
        // whichever field was previously focused via Tab/click,
        // silently producing wrong-field output that looked like
        // "the menu items are no-ops" from the user's perspective.
        if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
            rp.focus = field;
        }
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
    // Right-click on a fold arrow (visible `▾` on hover or `▸` when
    // folded) → seek cursor to that line and open the editor body
    // menu with Toggle Fold at the ready. vscode-user-mouse round 2
    // SEV-3 2026-07-11 — was routing to the editor line menu which
    // still has Toggle Fold but buried under 10+ items.
    if let Some(&(_, pid, line_no)) = app
        .rects
        .fold_arrows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            b.editor.place_cursor(line_no, 0);
        }
        app.open_editor_body_context_menu(pid, line_no, 0, (x, y));
        return;
    }
    // Right-click on the editor BODY → text-scoped menu.
    //
    // The hit test is widened to the right by the columns the editor
    // reserves but does not register: 1 cell of padding, the change-
    // density strip, and the scrollbar. `editor_panes` carries the TEXT
    // rect, so right-clicking any of those three produced no menu at all
    // — a dead zone in the last three columns at every width (tester,
    // 2026-09-02).
    //
    // The x is CLAMPED back into the text rect before mapping to a file
    // position: widening the rect itself would make those columns map to
    // a column past the end of the line.
    const RESERVED_RIGHT: u16 = 3;
    if let Some(&(tr, pid)) = app.rects.editor_panes.iter().find(|(r, _)| {
        let widened = ratatui::layout::Rect {
            width: r.width.saturating_add(RESERVED_RIGHT),
            ..*r
        };
        crate::app::dispatch::contains(widened, x, y)
    }) {
        let wrap = app.config.ui.wrap;
        if let Some(Pane::Editor(b)) = app.panes.get(pid) {
            let clamped_x = x.min(tr.x + tr.width.saturating_sub(1));
            let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, clamped_x, y);
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
    // mouse-round-11 SEV-2 2026-07-12 — right-click on an
    // HTTP-panel section header (COLLECTIONS / FILES / ENVS /
    // CHAINS / MOCKS / RECENT / CAPTURED). Section-level verbs.
    if let Some(&(_, section)) = app
        .rects
        .http_panel_section_headers
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.open_http_panel_section_context_menu(section, (x, y));
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
        } else {
            // mouse-round-16 F5 2026-07-17 — right-click on the
            // empty tree space below the last file was a dead
            // zone. Match VS Code's Explorer empty-space menu:
            // create-at-root verbs + refresh. Uses the workspace-
            // root context menu which already covers these verbs
            // (New file / New folder / Cut/Copy/Paste / Refresh).
            app.focus_tree();
            app.open_workspace_header_context_menu((x, y));
        }
        return;
    }
    // Right-click on an EXTRA workspace's file rows — was primary-only
    // until now, which read as broken (the primary tree ate the whole
    // right-click "space" but any secondary repo's rows had no menu).
    if let Some(&(tr, ws_idx, scroll)) = app
        .rects
        .extra_workspace_bodies
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let row_idx = (y - tr.y) as usize + scroll;
        app.open_extra_workspace_tree_row_context_menu(ws_idx, row_idx, (x, y));
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
    // ── Files pane rows ──
    //
    // #files — reuses `open_tree_context_menu`, which is already
    // PATH-based rather than tree-row-based, so the whole New / Rename /
    // Delete / Cut / Copy / Paste / Duplicate / Move-to / Reveal menu
    // comes across as one call. Selects the row first so the menu and the
    // cursor cannot disagree about which file is being acted on.
    if let Some(&(_, pane_id, idx)) = app
        .rects
        .file_pane_rows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if idx == crate::ui::file_browser_view::PARENT_ROW {
            return;
        }
        app.active = Some(pane_id);
        app.focus_pane();
        let target = match app.panes.get_mut(pane_id) {
            Some(crate::pane::Pane::Files(f)) => {
                f.selected = idx;
                f.selected_entry().map(|e| (e.path.clone(), e.is_dir))
            }
            _ => None,
        };
        if let Some((path, is_dir)) = target {
            app.open_tree_context_menu(path.clone(), is_dir, (x, y));
            // A trash entry gets Restore at the top — the whole reason
            // the 7-day retention is worth having.
            if path.parent() == Some(app.trash_dir().as_path())
                && let Some(menu) = app.context_menu.as_mut()
            {
                menu.items.insert(
                    0,
                    crate::context_menu::MenuItem::new(
                        "Restore to original location",
                        crate::context_menu::MenuAction::Command("files.restore_from_trash"),
                    ),
                );
                // "Delete…" is a lie in here — there is nowhere further
                // to defer to, so it removes the file outright. Say so
                // (user: "shouldn't delete say delete permanently?"),
                // and mark it destructive so it paints red like every
                // other unrecoverable action.
                for it in menu.items.iter_mut() {
                    if matches!(it.action, crate::context_menu::MenuAction::Delete(_)) {
                        it.label = "Delete permanently…".to_string();
                        it.destructive = true;
                    }
                }
            }
            // #files — the tree's menu is path-based and knows nothing
            // about marks, so prepend the two things only a Files pane
            // can offer. Prepending to the built menu rather than forking
            // `open_tree_context_menu` keeps ONE definition of the file-op
            // items; a Cut added to the tree menu shows up here for free.
            let (marked_here, marked_count) = match app.panes.get(pane_id) {
                Some(crate::pane::Pane::Files(f)) => (f.marked.contains(&path), f.marked.len()),
                _ => (false, 0),
            };
            if let Some(menu) = app.context_menu.as_mut() {
                let mut head = vec![crate::context_menu::MenuItem::new(
                    if marked_here { "Unmark" } else { "Mark" },
                    crate::context_menu::MenuAction::FilesToggleMark(pane_id, path),
                )];
                // Only when the clicked row is IN the set: right-clicking
                // an unmarked row is the user pointing at that row, and
                // silently acting on a set they aimed away from is the
                // bug this is fixing, not a feature to generalise.
                if marked_here && marked_count > 0 {
                    head.push(crate::context_menu::MenuItem::new(
                        format!("Cut {marked_count} selected"),
                        crate::context_menu::MenuAction::FilesCutMarked(pane_id),
                    ));
                    head.push(crate::context_menu::MenuItem::new(
                        format!("Copy {marked_count} selected"),
                        crate::context_menu::MenuAction::FilesCopyMarked(pane_id),
                    ));
                }
                head.append(&mut menu.items);
                menu.items = head;
            }
        }
        return;
    }

    // Right-click a TODO row opens the same action menu the kebab does
    // — the kebab is the discoverable route, right-click the fast one.
    if let Some(&(_, row)) = app
        .rects
        .todos_panel_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.open_todos_action_menu(row, (x, y));
        return;
    }
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

#[cfg(test)]
mod editor_deadzone_tests {
    use crate::app::App;
    use crate::config::Config;
    use ratatui::layout::Rect;

    /// TESTER SEV-2 — right-clicking the last three screen columns of an
    /// editor opened no menu at any width.
    ///
    /// The editor reserves three columns it does not register in
    /// `editor_panes` (padding + change-density strip + scrollbar), and
    /// that rect is what the right-click hit test used.
    #[test]
    fn right_click_in_the_reserved_right_columns_still_opens_a_menu() {
        let d = tempfile::tempdir().unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let f = app.workspace.join("a.rs");
        std::fs::write(&f, "fn main() {}\n").unwrap();
        app.open_path(&f);
        let pid = app.active.expect("no active pane");

        // A text rect that stops 3 columns short of the pane edge, as
        // the real renderer registers it.
        let text = Rect {
            x: 4,
            y: 1,
            width: 40,
            height: 20,
        };
        app.rects.editor_panes.clear();
        app.rects.editor_panes.push((text, pid));

        // Inside the text: must work (guards the test itself).
        super::handle_right_click(&mut app, text.x + 5, text.y + 2);
        assert!(app.context_menu.is_some(), "setup: no menu inside the text");
        app.context_menu = None;

        // The three reserved columns to its right: the dead zone.
        for off in 0..3u16 {
            let x = text.x + text.width + off;
            super::handle_right_click(&mut app, x, text.y + 2);
            assert!(
                app.context_menu.is_some(),
                "no menu at reserved column +{off} (x={x}) — the dead zone \
                 is still there"
            );
            app.context_menu = None;
        }
    }
}

#[cfg(test)]
mod right_click_coverage_tests {
    /// Rail list rows that have a left-click handler should also open a
    /// context menu — a user who right-clicks a row and gets the
    /// generic pane menu reads it as the feature being absent.
    ///
    /// The 2026-09-03 audit found three of this exact shape (FINDINGS,
    /// AGENTS, SEARCH), all discovered by noticing a `rects` field used
    /// in `down_left.rs` and absent here. This test names the ones that
    /// have been decided, so a future rail panel is a deliberate
    /// addition to the list rather than a silent omission.
    #[test]
    fn every_rail_row_family_with_a_left_handler_has_a_right_branch() {
        let src = std::fs::read_to_string(file!()).unwrap();
        for field in [
            "findings_panel_files",
            "notes_panel_files",
            "todos_panel_rows",
            "agents_panel_rows",
            "search_section_hit_rects",
        ] {
            assert!(
                src.contains(field),
                "`{field}` rows have no right-click branch — right-clicking \
                 one falls through to the generic pane menu"
            );
        }
    }

    /// Both reveal routes must be offered together wherever a row
    /// resolves to a real file on disk. Offering only the OS one was
    /// the defect the user hit; offering only the in-app one would be
    /// the same mistake mirrored.
    #[test]
    fn row_menus_offer_both_reveal_routes() {
        let src = std::fs::read_to_string(file!()).unwrap();
        let tree = src.matches("MenuAction::RevealInTree").count();
        let os = src.matches("MenuAction::RevealInFinder").count();
        assert!(tree > 0 && os > 0, "a reveal route vanished entirely");
        assert_eq!(
            tree, os,
            "the two reveal routes are offered an unequal number of times \
             ({tree} in-app vs {os} OS) — some menu offers one without the other"
        );
    }
}
