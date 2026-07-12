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
    if let Some(path) = app
        .rects
        .notes_panel_files
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, p)| p.clone())
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let rel = crate::app::rel_path(&app.workspace, &path);
        let title = path
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "note".to_string());
        let items = vec![
            MenuItem::new("Open", MenuAction::OpenPath(path.clone())),
            MenuItem::new("Open in split", MenuAction::OpenInSplit(path.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInFinder(path.clone())),
            MenuItem::new("Yank path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
            MenuItem::new("Delete…", MenuAction::Delete(path)),
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
            ResponseTab::Timeline => (
                "Response Timeline",
                vec![MenuItem::new(
                    "Diff last two responses",
                    MenuAction::Command("http.diff_last_two"),
                )],
            ),
            ResponseTab::Tests => (
                "Response Tests",
                vec![MenuItem::new("Re-run", MenuAction::Command("http.send"))],
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
                MenuItem::new("Yank name", MenuAction::CopyPath(key.clone())),
                MenuItem::new("Delete…", MenuAction::Command("http.delete_env_key")),
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
            MenuItem::new("Reveal in tree", MenuAction::RevealInFinder(path.clone())),
            MenuItem::new("Yank path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
            MenuItem::new("Delete…", MenuAction::Delete(path)),
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
                MenuItem::new("Yank curl", MenuAction::CopyPath(curl)),
                MenuItem::new("Yank URL", MenuAction::CopyPath(url)),
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
                MenuItem::new("Yank curl", MenuAction::CopyPath(curl)),
                MenuItem::new("Yank URL", MenuAction::CopyPath(row.url)),
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
            MenuItem::new("Yank name", MenuAction::CopyPath(name.clone())),
            MenuItem::new("Yank path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(env_file.clone())),
            MenuItem::new("Delete…", MenuAction::Delete(env_file)),
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
            MenuItem::new("Reveal in tree", MenuAction::RevealInFinder(path.clone())),
            MenuItem::new("Yank path", MenuAction::CopyPath(rel)),
            MenuItem::new("Delete…", MenuAction::Delete(path)),
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
            MenuItem::new("Reveal in tree", MenuAction::RevealInFinder(path.clone())),
            MenuItem::new("Yank path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(path.clone())),
            MenuItem::new("Delete…", MenuAction::Delete(path)),
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
            MenuItem::new("Reveal in tree", MenuAction::RevealInFinder(dir.clone())),
            MenuItem::new("Yank path", MenuAction::CopyPath(rel)),
            MenuItem::new("Rename…", MenuAction::Rename(dir.clone())),
            MenuItem::new("Delete collection…", MenuAction::Delete(dir)),
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
            MenuItem::new("Reveal in tree", MenuAction::RevealInFinder(path.clone())),
            MenuItem::new("Yank path", MenuAction::CopyPath(rel)),
            MenuItem::new("Delete…", MenuAction::Delete(path)),
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
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let cur = app.config.ui.wrap;
        let label = if cur { "Disable wrap" } else { "Enable wrap" };
        let items = vec![MenuItem::new(
            label,
            MenuAction::Command("view.toggle_wrap"),
        )];
        app.context_menu = Some(ContextMenu::new(Some("Wrap".to_string()), (x, y), items));
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
            MenuItem::new("Status", MenuAction::Command("LspStatus")),
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
    // qa-6th mouse SEV-3 2026-06-29: mixr chip on the statusline
    // had a left-click action (mixr.show) but no right-click menu
    // and no hover tooltip — felt like a black box. Added a small
    // menu: open mixr in a pane, or copy the now-playing track.
    if let Some(r) = app.rects.statusline_mixr_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let mut items = vec![MenuItem::new("Open mixr", MenuAction::Command("mixr.show"))];
        // qa-8th design MED-4 2026-06-30 — was 1-item menu that
        // just duplicated the left-click action. Add Copy-track
        // when something's playing so right-click feels useful.
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
    // Right-click on the TABS label → cluster mode chooser
    // (Expanded / Compact / Auto).
    if let Some(r) = app.rects.bufferline_tabs_label
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_top_bar_cluster_context_menu((x, y));
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
        app.active = Some(leaf_active);
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
        let items = vec![
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
        ];
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
