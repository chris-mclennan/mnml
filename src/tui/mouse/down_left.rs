//! Left-click (`MouseEventKind::Down(MouseButton::Left)`) dispatch
//! — extracted from `mouse/mod.rs` (T-5 of the file-split refactor,
//! 2026-06-29). At ~1700 lines this was the biggest chunk of
//! dispatch_mouse: every clickable surface — rail rows, palette
//! bar buttons, statusline chips, panel chrome, dock widgets,
//! pane bodies, scrollbars, drag-start, drop targets, and so on.
//!
//! Public surface: `handle_down_left(app, m, x, y, ...)`. Called
//! from `dispatch_mouse`'s left-Down arm. Returns nothing; each
//! consuming branch uses `return` to exit this function only,
//! leaving the outer match arm to complete naturally.

use ratatui::crossterm::event::{KeyModifiers, MouseEvent};

use super::{send_macos_player, send_mixr_command};
use crate::app::App;
use crate::command;
use crate::pane::Pane;

/// Rows for the `Create…` menu shared by all three `+` chips: the
/// per-leaf tab-strip `+`, the empty-state `+` on the top row, and
/// the top-right cluster's `+`.
///
/// #1210 — this used to be inlined three times, and the third copy
/// didn't exist at all: the top-right `+` fired `tab_new` directly,
/// so with every pane closed (the one situation where it's the ONLY
/// `+` on screen) there was no route back to a closed tab. One
/// builder means a row added here shows up on every `+`, which is
/// what "behavior parity between the `+` chips" was already trying
/// to promise.
fn plus_menu_items(app: &App) -> Vec<crate::context_menu::MenuItem> {
    use crate::context_menu::{MenuAction, MenuItem};
    // Grouped into submenus rather than one flat list.
    //
    // The flat form had grown to ~15 rows and gained one more per enabled
    // integration, so it got taller forever and scanning it cost more than
    // the palette it was meant to shortcut. Grouping is what submenus are
    // actually for — and the `▸` is a VISIBLE affordance, which a
    // right-click never is.
    //
    // What deliberately does NOT become a submenu: the action rows. A row
    // carrying `▸` conventionally means "clicking me does nothing, I just
    // open more", so making an action row a parent would make it lie about
    // itself. Per-row extras hang off the row's own `⋮` instead.
    let mut items = vec![
        MenuItem::submenu(
            "New",
            vec![
                MenuItem::new("Scratch buffer", MenuAction::Command("scratch.new")),
                MenuItem::new(
                    "From clipboard",
                    MenuAction::Command("scratch.from_clipboard"),
                ),
                MenuItem::new("HTTP request", MenuAction::Command("http.new")),
                MenuItem::new("Shell", MenuAction::Command("term.shell")),
                MenuItem::new("Browser tab", MenuAction::Command("browser.open")),
                MenuItem::new("Tab page", MenuAction::Command("tab.new")),
            ],
        ),
        MenuItem::submenu(
            "Open",
            vec![
                MenuItem::new("File…", MenuAction::Command("picker.files")),
                MenuItem::new("Recent files", MenuAction::Command("picker.recent")),
                MenuItem::new("File browser", MenuAction::Command("files.open")),
                MenuItem::new(
                    "Dual file panes (commander)",
                    MenuAction::Command("files.open_split"),
                ),
                MenuItem::new("Trash", MenuAction::Command("files.trash")),
            ],
        ),
        MenuItem::submenu(
            "AI",
            vec![
                MenuItem::new(
                    "Claude Code session",
                    MenuAction::Command("ai.claude_code_new"),
                ),
                MenuItem::new("Codex session", MenuAction::Command("ai.codex_new")),
            ],
        ),
        MenuItem::submenu(
            "Dock",
            vec![
                MenuItem::new("Note", MenuAction::Command("dock.new_text")),
                MenuItem::new("Log tail", MenuAction::Command("dock.new_log_tail")),
            ],
        ),
    ];
    // Integrations get their own group, which is the whole reason the
    // flat list could not stay flat: this one grows without bound as the
    // user enables more.
    let integrations: Vec<MenuItem> = app
        .config
        .ui
        .integration_icons
        .iter()
        .filter(|i| i.enabled)
        .map(|icon| {
            let label = icon
                .label
                .clone()
                .unwrap_or_else(|| icon.id.replace('_', " "));
            MenuItem::new(label, MenuAction::RunCmd(icon.command.clone()))
        })
        .collect();
    if !integrations.is_empty() {
        items.push(MenuItem::submenu("Integrations", integrations));
    }
    // Every row above opens something NEW. After closing your tabs the
    // thing you actually want is them BACK, and the only route was
    // Ctrl+Shift+T (undiscoverable) or restarting mnml, which restores the
    // session. Prepended so it's first under the cursor, and only when
    // there IS something to reopen — an always-present row that usually
    // toasts "nothing to reopen" just teaches people to skip it.
    //
    // Stays a top-level ACTION row, not a submenu member: it is the one
    // thing here you want in a single click.
    if !app.closed_buffers.is_empty() {
        items.insert(
            0,
            MenuItem::new(
                format!("Reopen last closed ({})", app.closed_buffers.len()),
                MenuAction::Command("buffer.reopen"),
            ),
        );
    }
    apply_plus_menu_curation(app, items)
}

/// Command id a row acts on, for curation. `None` for rows that are not
/// curatable (a parent, or anything without a command behind it).
fn menu_row_command(item: &crate::context_menu::MenuItem) -> Option<String> {
    match &item.action {
        crate::context_menu::MenuAction::Command(c) => Some((*c).to_string()),
        crate::context_menu::MenuAction::RunCmd(c) => Some(c.clone()),
        _ => None,
    }
}

/// Drop hidden rows and float pinned ones to the top.
///
/// Runs over the WHOLE tree, so hiding a row inside a group works and a
/// pinned row escapes its group to the top level — which is the point of
/// pinning. A group left empty by hiding is dropped too, since a parent
/// that opens nothing is a dead click.
fn apply_plus_menu_curation(
    app: &App,
    items: Vec<crate::context_menu::MenuItem>,
) -> Vec<crate::context_menu::MenuItem> {
    use crate::context_menu::MenuItem;
    let hidden = &app.config.ui.plus_menu_hidden;
    let pinned = &app.config.ui.plus_menu_pinned;
    if hidden.is_empty() && pinned.is_empty() {
        return items;
    }
    let is_hidden = |it: &MenuItem| menu_row_command(it).is_some_and(|c| hidden.contains(&c));
    // Collect the pinned rows wherever they live, in the order the user
    // pinned them rather than the order the menu happens to list them.
    let mut found: Vec<(usize, MenuItem)> = Vec::new();
    let rank =
        |it: &MenuItem| menu_row_command(it).and_then(|c| pinned.iter().position(|p| *p == c));
    let mut keep: Vec<MenuItem> = Vec::new();
    for mut it in items {
        if is_hidden(&it) {
            continue;
        }
        if let Some(kids) = it.submenu.take() {
            let mut kept_kids = Vec::new();
            for k in kids {
                if is_hidden(&k) {
                    continue;
                }
                match rank(&k) {
                    Some(r) => found.push((r, k)),
                    None => kept_kids.push(k),
                }
            }
            if kept_kids.is_empty() {
                // Every child pinned away or hidden — the parent would
                // open an empty menu.
                continue;
            }
            it.submenu = Some(kept_kids);
            keep.push(it);
            continue;
        }
        match rank(&it) {
            Some(r) => found.push((r, it)),
            None => keep.push(it),
        }
    }
    found.sort_by_key(|(r, _)| *r);
    let mut out: Vec<MenuItem> = found.into_iter().map(|(_, it)| it).collect();
    out.extend(keep);
    out
}

/// Max gap between two clicks at the same (x, y) that still counts
/// as a double-click. mouse-round-14 SEV-2 F1 2026-07-14 — bumped
/// from 450 → 700 ms because natural trackpad cadence lands
/// around 350-600 ms between clicks (particularly for the
/// divider-equalize / tab-close double-click paths), and the render
/// + poll_sleep + drain-iter overhead under the IPC channel eats
/// another ~40-80 ms on top of the human timing. 700 ms is macOS
/// System-Preferences → Trackpad's "slow" end and still fast
/// enough that two intentionally-separate clicks don't misfire as
/// a double.
const DOUBLE_CLICK_MAX_MS: u128 = 700;

pub(super) fn handle_down_left(app: &mut App, m: MouseEvent, x: u16, y: u16) {
    if app.debug_click_inspector {
        let hits = app.rects.inspect_click_targets(x, y);
        let msg = if hits.is_empty() {
            format!("click @ ({x}, {y}): no PaneRects hit")
        } else {
            format!("click @ ({x}, {y}): {}", hits.join(" · "))
        };
        app.toast(msg);
    }
    // #20 Pattern B — confirm modal takes priority over every
    // other click when it's up.
    if app.pending_confirm.is_some() {
        if let Some(r) = app.rects.confirm_modal_cancel
            && crate::app::dispatch::contains(r, x, y)
        {
            app.dismiss_pending_confirm();
            return;
        }
        if let Some(r) = app.rects.confirm_modal_confirm
            && crate::app::dispatch::contains(r, x, y)
        {
            app.commit_pending_confirm();
            return;
        }
        // Click outside modal — swallow the click so users don't
        // accidentally trigger stuff underneath.
        return;
    }
    // #20 — undo chip wins the click over almost anything else so
    // it's easy to hit. Only anchored while `pending_undo` is set,
    // so no ordinary flow is stolen from.
    if let Some(r) = app.rects.pending_undo_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.commit_pending_undo();
        return;
    }
    // First-launch wizard hit rects (2026-08-14 — fixes the
    // "yes/no rows not clickable" bug). Only registered while the
    // wizard overlay is up, so no ordinary flow is intercepted.
    if app.first_launch.is_some()
        && let Some(&(_, hit)) = app
            .rects
            .first_launch_hits
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        match hit {
            crate::ui::first_launch_overlay::FirstLaunchHit::NerdFontOk(ok) => {
                app.wizard_set_nerd_font_ok(ok);
            }
        }
        return;
    }
    // vscode-mouse SEV-2 2026-08-05 — when a menu dropdown is open,
    // handle its clicks BEFORE any body-of-app rect check so a click
    // on a menu item doesn't fall through to the tree/pane rect
    // underneath. Previously the menu_bar_items check ran after
    // marketplace/integration/tree checks, and if the current
    // frame's rects had already been reset but the menu hadn't
    // re-rendered yet, the item click would silently activate the
    // element behind the dropdown.
    if let Some(open) = app.menu_open.as_ref().cloned() {
        // 1. Item hit — fire the palette command + close, OR open a
        // submenu, OR fire a submenu item.
        if let Some(&(_, encoded_idx)) = app
            .rects
            .menu_bar_items
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        {
            let menus = crate::menu_bar::bar(app);
            if encoded_idx >= 1000 {
                // Submenu Action row: encoded as `1000 + parent*100 + sub`.
                let rest = encoded_idx - 1000;
                let parent_idx = rest / 100;
                let sub_idx = rest % 100;
                if let Some(menu) = menus.get(open.menu_idx)
                    && let Some(crate::menu_bar::MenuItem::Submenu { items, .. }) =
                        menu.items.get(parent_idx)
                    && let Some(crate::menu_bar::MenuItem::Action { command_id, .. }) =
                        items.get(sub_idx)
                {
                    let id = command_id.clone();
                    app.menu_open = None;
                    crate::command::run(&id, app);
                }
                return;
            }
            if let Some(menu) = menus.get(open.menu_idx) {
                match menu.items.get(encoded_idx) {
                    Some(crate::menu_bar::MenuItem::Action { command_id, .. }) => {
                        let id = command_id.clone();
                        app.menu_open = None;
                        crate::command::run(&id, app);
                    }
                    Some(crate::menu_bar::MenuItem::Submenu { .. }) => {
                        // Open (or re-open) the submenu with its first
                        // action highlighted.
                        if let Some(state) = app.menu_open.as_mut() {
                            state.item_idx = encoded_idx;
                            state.sub_item_idx = Some(0);
                        }
                    }
                    _ => {}
                }
            }
            return;
        }
        // 2. Word hit on the SAME menu — toggle (close). Different
        // word → let the normal menu_bar_words handler switch.
        if let Some(&(_, menu_idx)) = app
            .rects
            .menu_bar_words
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            && menu_idx == open.menu_idx
        {
            app.menu_open = None;
            return;
        }
        // 3. Click anywhere else with menu open → close menu and
        // swallow the click. The user's intent was "dismiss," not
        // "activate what's behind the panel."
        //
        // If the click hit a different menu word (case 2), fall
        // through so the menu_bar_words handler below can switch.
        // R11 vscode-mouse SEV-2 — the `»` overflow chip's own rect
        // isn't in `menu_bar_words`, so before this exception a
        // click on `»` matched the outside-click null path here,
        // wiping `menu_open` BEFORE the overflow-chip handler
        // below could read it to compute the next hidden menu.
        // Result: every `»` click bounced back to first-hidden.
        // Treat overflow-chip clicks as inside-the-menu-bar too.
        let click_on_menu_word = app
            .rects
            .menu_bar_words
            .iter()
            .any(|(r, _)| crate::app::dispatch::contains(*r, x, y));
        let click_on_overflow_chip = app
            .rects
            .menu_bar_overflow
            .is_some_and(|(r, _)| crate::app::dispatch::contains(r, x, y));
        if !click_on_menu_word && !click_on_overflow_chip {
            app.menu_open = None;
            return;
        }
    }
    // 2026-07-19 — the activity-bar icons live on a 4-cell strip at
    // the far-left of the rail; hover-tooltips consistently report
    // the correct section but clicks were being swallowed by stale
    // rects from other panels (session_tabs, extra_workspace_bodies,
    // right_panel_empty_*, and so on) that carried over from prior
    // frames when their host panel wasn't the active section. Every
    // fix we've shipped for that class of bug patched one panel at a
    // time; move the activity-bar check ABOVE all the other cascade
    // arms so no stale integration-panel rect can ever shadow the icon
    // strip. Small blast radius — the activity bar is a 4-column
    // sliver and its icons are ONLY there.
    if let Some(&(_, section)) = app
        .rects
        .activity_bar_icons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // 2026-07-20 — LauncherIcon is a pinned-integration shortcut:
        // fire the underlying chip's command (spawns a Pty pane in
        // the main area, no side panel). Skip set_activity_section
        // so the sidebar doesn't flip to a nonexistent "Launcher"
        // section.
        if let crate::app::ActivitySection::LauncherIcon(idx) = section {
            let cmd = app
                .config
                .ui
                .activity_bar_pinned_integrations
                .get(idx as usize)
                .and_then(|id| app.config.ui.integration_icons.iter().find(|i| &i.id == id))
                .map(|ic| ic.command.clone());
            if let Some(cmd) = cmd {
                if let Some(rest) = cmd.strip_prefix(':') {
                    app.run_ex_command(rest);
                } else {
                    crate::command::run(&cmd, app);
                }
            }
            return;
        }
        // 2026-08-24 — Git-section entry now auto-opens the
        // multi-repo tab strip via the `entering_git` hook in
        // `set_activity_section` itself. No follow-up
        // `git.graph` needed.
        app.set_activity_section(section);
        if let crate::app::ActivitySection::Mount(idx) = section {
            app.open_mount_from_manifest(idx);
        }
        return;
    }
    // The notifications bell opens the message history.
    if let Some(r) = app.rects.activity_bar_bell
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::command::run("messages.show", app);
        return;
    }
    if let Some(r) = app.rects.activity_bar_gear
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_settings_overlay();
        return;
    }
    // #polish 2026-07-06 — click on the `· <repo-name>` chip in
    // the GIT rail header opens the repo switcher picker.
    if let Some(r) = app.rects.git_repo_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        // A MENU, not a straight switch.
        //
        // It used to fire `git.switch_repo`, which toasts "only one repo
        // in this workspace" — exactly when the user has closed their
        // repo tabs and is looking for the way back. `git.reopen_repo`
        // existed but had no keybinding and lived only in the palette,
        // so the one place they looked was the one place that told them
        // no. User: "i closed the tabs for the repos and now i cant
        // bring one back, any of them, i tried dropdown at top left."
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let mut items: Vec<MenuItem> = Vec::new();
        for (i, repo) in app.repos.iter().enumerate() {
            let marker = if i == app.active_repo { "● " } else { "  " };
            items.push(MenuItem::new(
                format!("{marker}{}", repo.name),
                MenuAction::GitSwitchRepo(i),
            ));
        }
        let mut closed: Vec<std::path::PathBuf> = app.git_closed_repos.iter().cloned().collect();
        closed.sort();
        for p in closed {
            let name = p
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("repo")
                .to_string();
            items.push(MenuItem::new(
                format!("  Reopen: {name}"),
                MenuAction::GitReopenRepo(p),
            ));
        }
        // Always last, and always present: the answer when the workspace
        // holds nothing to switch to or reopen.
        items.push(MenuItem::new(
            "  Add workspace\u{2026}",
            MenuAction::Command("view.add_workspace"),
        ));
        app.context_menu = Some(ContextMenu::new(
            Some("Repos".into()),
            (r.x, r.y + 1),
            items,
        ));
        return;
    }
    // #polish 2026-07-06 — click the right-panel `+` chip opens
    // a small menu with the 5 panel kinds.
    if let Some(r) = app.rects.right_panel_new_button
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let items = vec![
            MenuItem::new("Outline", MenuAction::Command("outline.show")),
            MenuItem::new("Problems", MenuAction::Command("lsp.diagnostics")),
            MenuItem::new("AI chat", MenuAction::Command("ai.chat")),
            MenuItem::new("Grep", MenuAction::Command("find.grep")),
            MenuItem::new("Tests", MenuAction::Command("test.run")),
        ];
        app.context_menu = Some(ContextMenu::new(
            Some("Add panel".to_string()),
            (x, y),
            items,
        ));
        return;
    }
    // Grab the rail's right-edge resize handle first — its grip
    // band shares the rail's rightmost column with the file-tree
    // scrollbar, so the (specific, ~4-row) resize zone must win
    // there before the (full-height) scrollbar claims the click.
    // #polish 2026-07-06 — double-click on a rail edge resets
    // the width to the config default before drag-detection
    // consumes the click. Same VS Code / Chrome tab-strip
    // convention: click-drag to resize, double-click to reset.
    let is_double_click = {
        let now = std::time::Instant::now();
        matches!(app.last_click, Some((t, lx, ly, count))
            if count >= 1
                && (x as i32 - lx as i32).abs() <= 1
                && (y as i32 - ly as i32).abs() <= 1
                && now.duration_since(t) < std::time::Duration::from_millis(500))
    };
    if is_double_click
        && let Some(r) = app.rects.tree_edge
        && crate::app::dispatch::contains(r, x, y)
    {
        app.tree_width = app.config.ui.tree_width;
        app.toast("tree width reset");
        return;
    }
    if is_double_click
        && let Some(r) = app.rects.right_panel_edge
        && crate::app::dispatch::contains(r, x, y)
    {
        app.right_panel_width = app.config.ui.right_panel_width;
        app.toast("right panel width reset");
        return;
    }
    if app.begin_tree_edge_drag(x, y) {
        return;
    }
    // vscode-user-mouse SEV-1 — mirror for the right-panel
    // grip. Without this, the field stayed false and the
    // grip was decorative.
    if app.maybe_start_right_panel_edge_drag(x, y) {
        return;
    }
    // Right-panel v3: tab strip click → switch active tab.
    // Checked BEFORE the × close since the tabs occupy the
    // left half of the same row.
    if let Some(&(_, tab_idx)) = app
        .rects
        .right_panel_tabs
        .iter()
        .find(|(rect, _)| crate::app::dispatch::contains(*rect, x, y))
    {
        app.right_panel_active_idx = tab_idx;
        return;
    }
    // mouse-polish F-2 — empty-state command lines as
    // click targets so a mouse-first user can populate
    // the panel without typing.
    if let Some(rect) = app.rects.right_panel_empty_outline
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("outline.show", app);
        return;
    }
    if let Some(rect) = app.rects.right_panel_empty_diagnostics
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("lsp.diagnostics", app);
        return;
    }
    // design-critic 2026-06-28 #3 — 3 more empty-state
    // click rects so all 5 routable commands are mouse
    // reachable from the empty state.
    if let Some(rect) = app.rects.right_panel_empty_ai
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("ai.chat", app);
        return;
    }
    if let Some(rect) = app.rects.right_panel_empty_grep
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("find.grep", app);
        return;
    }
    if let Some(rect) = app.rects.right_panel_empty_test
        && crate::app::dispatch::contains(rect, x, y)
    {
        // mouse-round-7 SEV-2 2026-07-11 — `test.run` didn't exist,
        // so the click silently no-op'd. Fall through the `_file` /
        // `_all` variants; `_file` toasts helpfully when no editor is
        // open.
        if crate::command::registry().get("test.run_file").is_some() {
            crate::command::run("test.run_file", app);
        } else {
            crate::command::run("test.run_all", app);
        }
        return;
    }
    // Right-panel v3 `×` on the header closes the active
    // tab (panel stays open; next tab takes its place, or
    // empty-state returns if it was the last).
    if let Some(rect) = app.rects.right_panel_close
        && crate::app::dispatch::contains(rect, x, y)
    {
        if let Some(pid) = app.right_panel_active_pane_id() {
            // crash-investigator SEV-1 #3: close_pane FIRST.
            // On a dirty editor this exits early with a close
            // prompt; the pane is still in right_panel_panes
            // so confirm-discard routes through
            // remove_pane_storage which now also drops the
            // right-panel record. For non-dirty panes,
            // remove_pane_storage takes care of the shift.
            app.close_pane(pid);
        }
        return;
    }
    // 2026-08-07 vscode-user r2 F1 SEV-2 — bottom-panel `×` chip
    // was drawn but never wired to a click handler. Hides the
    // panel (mirrors Ctrl+Shift+J), which also drains hosted
    // panes so they don't linger as ghost bufferline entries.
    if let Some(rect) = app.rects.bottom_panel_close
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("view.toggle_bottom_panel", app);
        return;
    }
    // qa-feature 2026-07-02 — markdown pane swap chips at the top of
    // MdPreview + Editor(.md) panes. Checked BEFORE scrollbars so the
    // chip at the far-right of the banner row isn't shadowed by
    // anything below.
    if let Some(&(_, pid)) = app
        .rects
        .md_preview_edit_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.md_preview_to_edit(pid);
        return;
    }
    if let Some(&(_, pid)) = app
        .rects
        .editor_md_preview_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.md_edit_to_preview(pid);
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
    // mouse-round-12 SEV-2 F2 2026-07-14 — divider double-click
    // equalize must be checked BEFORE begin_divider_drag; the
    // round-11 fallback at ~line 2760 was unreachable because
    // begin_divider_drag returns unconditionally on divider hit.
    // Match the same 450 ms double-click window, then consume.
    if app
        .rects
        .split_dividers
        .iter()
        .any(|d| crate::app::dispatch::contains(d.rect, x, y))
    {
        let now = std::time::Instant::now();
        let is_double = matches!(
            app.last_click,
            Some((prev, px, py, c))
                if px == x
                    && py == y
                    && c >= 1
                    && now.duration_since(prev) < std::time::Duration::from_millis(DOUBLE_CLICK_MAX_MS as u64)
        );
        app.last_click = Some((now, x, y, if is_double { 2 } else { 1 }));
        if is_double {
            app.equalize_splits();
            // mouse-round-15 SEV-2 F1 2026-07-15 — don't early-return.
            // The user's second Down may be intended as a drag start,
            // not a "dbl-click to equalize" (unambiguous only at Up
            // time). Fall through to begin_divider_drag so the drag
            // still arms — the user's drag continues from the just-
            // equalized position, which is a strictly better outcome
            // than "click-then-drag within 700 ms silently drops the
            // drag."
        }
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
    // VS Code-style fold arrow in the sign column → toggle the fold
    // at that line. `toggle_fold_at_cursor` uses the cursor's
    // position, so seek the cursor to the clicked line first
    // (its first non-whitespace char, matching how vim's `za` on a
    // header line behaves). 2026-07-11.
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
        app.toggle_fold_at_cursor();
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
    // Click on the "▶ Send" button in the Request pane's top row
    // → fires the request. During Sending the button flips to
    // "⟳ Abort" (see `draw_send_box`) and the click routes to
    // `http.abort` instead. Same effect as the `r` chord over the
    // Request pane and the `http.send` / `http.abort` commands.
    if let Some(r) = app.rects.request_send_button
        && crate::app::dispatch::contains(r, x, y)
    {
        // vscode-user-mouse SEV-2 2026-07-10: a click on any Request-
        // pane chrome (send/save/clear/…) fires the action but never
        // switched focus to the pane, so the follow-up keystroke
        // routed to wherever focus WAS (usually Tree, after opening
        // via the file browser). Snap focus so `r` / typing lands
        // where the user just clicked.
        app.focus_pane();
        let is_sending = matches!(
            app.active.and_then(|i| app.panes.get(i)),
            Some(crate::pane::Pane::Request(rp))
                if matches!(rp.state, crate::request_pane::RunState::Sending)
        );
        if is_sending {
            crate::command::run("http.abort", app);
        } else {
            crate::command::run("http.send", app);
        }
        return;
    }
    // Click on the "⎘ Save" button → save the active Request
    // pane's fields to its source file, or open a Save-As prompt
    // when no source file is set yet.
    if let Some(r) = app.rects.request_save_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.focus_pane();
        app.http_save_or_prompt_save_as();
        return;
    }
    // Click on the "✕ Clear" button → reset the active Request
    // pane's fields to a blank template. Same code path as the
    // sidebar's `+ New request` chip; toasts a hint.
    if let Some(r) = app.rects.request_clear_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.focus_pane();
        // #20 v2 — snapshot the pane before clearing so `↶ Undo`
        // can restore the URL / body / headers / etc. Skips the
        // snapshot when the active pane isn't a Request (no-op
        // clear anyway).
        if let Some(cur) = app.active
            && let Some(crate::pane::Pane::Request(rp)) = app.panes.get(cur)
        {
            let action = crate::app::UndoAction::RestoreRequestPane {
                pane_id: cur,
                method: rp.request.method.clone(),
                url: rp.request.url.clone(),
                body: rp.request.body.clone(),
                headers_buffer: rp.headers_buffer.clone(),
                source_buffer: rp.source_buffer.clone(),
            };
            app.http_panel_new_request();
            app.set_pending_undo("cleared request".to_string(), action);
            app.toast("cleared");
        } else {
            app.http_panel_new_request();
            app.toast("cleared");
        }
        return;
    }
    // Click on the "{ } Format" button → prettify the JSON body
    // in place. No-op + toast on non-JSON bodies. Same as
    // Shift+Alt+F chord.
    if let Some(r) = app.rects.request_format_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.focus_pane();
        app.http_format_body();
        return;
    }
    // Click on the "↻ Reroll" chip → regenerate body dynamic values.
    if let Some(r) = app.rects.request_regenerate_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.focus_pane();
        app.http_regenerate_body();
        return;
    }
    // Click on "</> Code" → open the Generate Code language
    // picker (Bruno-style).
    if let Some(r) = app.rects.request_code_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.focus_pane();
        app.http_generate_code_prompt();
        return;
    }
    // Click on the Env chip → open the env picker.
    if let Some(r) = app.rects.request_env_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.focus_pane();
        app.open_http_env_picker();
        return;
    }
    // Click on the "JSON ▼" content-type chip → open the
    // response-format override picker.
    if let Some(r) = app.rects.request_response_type_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_response_format_prompt();
        return;
    }
    // Click on the "copy" chip → copy whatever the active response
    // sub-tab is currently showing. R11 api-workflow SEV-2
    // (2026-08-23): was always `http_copy_response_body()`, so
    // clicking copy while viewing the Headers tab silently copied
    // the Body — the toast literally said "response body copied"
    // even though headers were on screen. Route per sub-tab.
    if let Some(r) = app.rects.request_response_copy_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let tab = if let Some(idx) = app.active
            && let Some(crate::pane::Pane::Request(rp)) = app.panes.get(idx)
        {
            rp.response_tab
        } else {
            crate::request_pane::ResponseTab::Body
        };
        // R12 vscode-mouse SEV-2 2026-08-23 — Timeline / Tests
        // used to silently fall back to Body copy + a lying
        // `response body copied` toast. Route each tab to its own
        // handler.
        match tab {
            crate::request_pane::ResponseTab::Body => app.http_copy_response_body(),
            crate::request_pane::ResponseTab::Headers => app.http_copy_response_headers(),
            crate::request_pane::ResponseTab::Cookies => app.http_copy_response_cookies(),
            crate::request_pane::ResponseTab::Timeline => app.http_copy_response_timeline(),
            crate::request_pane::ResponseTab::Tests => app.http_copy_response_tests(),
        }
        return;
    }
    // Click on the "wrap" chip → toggle body wrap.
    if let Some(r) = app.rects.request_response_wrap_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_toggle_response_wrap();
        return;
    }
    // Click on the `⚡ AI` chip → copy AI-ready debug prompt.
    if let Some(r) = app.rects.request_response_ai_prompt_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_copy_ai_prompt();
        return;
    }
    // Click on the split-orientation toggle chip → cycle
    // Vertical <-> Horizontal for the active Request pane. Same
    // as `Ctrl+\` chord.
    if let Some(r) = app.rects.request_split_toggle
        && crate::app::dispatch::contains(r, x, y)
    {
        if let Some(cur) = app.active
            && let Some(crate::pane::Pane::Request(rp)) = app.panes.get_mut(cur)
        {
            rp.split_orientation = rp.split_orientation.toggle();
        }
        return;
    }
    // Click on a Response sub-tab chip (Body / Headers / Timeline
    // / Tests) → switch the active pane's `response_tab`.
    // api-round-14 SEV-2 2026-07-16 — also snap the pane's view
    // to Response AND focus_pane() so the documented `/`-search
    // and `j`/`k` scroll bindings actually reach the response
    // renderer. Was: only set `response_tab` — the pane could
    // still be in ViewMode::Edit or focus could still be on the
    // tree, so the next keystroke silently corrupted the URL
    // instead of scrolling / searching.
    if let Some((_, tab)) = app
        .rects
        .request_response_tabs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let tab = *tab;
        if let Some(cur) = app.active
            && let Some(crate::pane::Pane::Request(rp)) = app.panes.get_mut(cur)
        {
            rp.response_tab = tab;
            rp.view = crate::request_pane::ViewMode::Response;
        }
        app.focus_pane();
        return;
    }
    // Click on a Vars-tab row → cell-level routing (#23 v3).
    // Sentinel keys work the same as Params / Headers:
    //   `\0VAL<key>`  → start inline value edit
    //   `\0NAME<key>` → start inline rename
    //   `\0DEL<key>`  → delete env var
    //   `\0COMMIT`    → no-op for Vars (no draft-add row)
    //   ""            → add-row (falls through to palette prompt)
    //   any other     → whole-row click (falls through to palette prompt)
    if let Some((_, key, _)) = app
        .rects
        .request_vars_rows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        // api-round-13 SEV-2 A 2026-07-15 — a click that starts an
        // inline KV edit must also move keyboard focus to the pane,
        // otherwise every subsequent keystroke routes to whichever
        // handler currently owns focus (typically the tree, if the
        // request pane was opened as a preview from the tree/
        // COLLECTIONS list). Symptom: the cell renders `value▏` but
        // every key/backspace/Enter/Tab/Esc is silently swallowed;
        // only another mouse click elsewhere recovers.
        app.focus_pane();
        if key == "\0COMMIT" {
            return;
        }
        if let Some(row_key) = key.strip_prefix("\0VAL") {
            app.http_kv_edit_begin(crate::request_pane::KvEditKind::Vars, row_key.to_string());
            return;
        }
        if let Some(row_key) = key.strip_prefix("\0NAME") {
            app.http_kv_edit_begin_name(crate::request_pane::KvEditKind::Vars, row_key.to_string());
            return;
        }
        if let Some(row_key) = key.strip_prefix("\0DEL") {
            app.http_delete_env_key(row_key);
            return;
        }
        if key.is_empty() {
            app.accept_env_vars("+add");
        } else {
            app.accept_env_vars(&key);
        }
        return;
    }
    // Click on a Params- or Headers-tab row → empty key
    // (`+ Add row`) starts the inline draft; non-empty key
    // deletes that row (whole-row hitbox for v1). The dispatch
    // routes to params vs headers based on the active pane's
    // current edit_tab.
    if let Some((_, key, kind)) = app
        .rects
        .request_params_rows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        // api-round-13 SEV-2 A 2026-07-15 — same pane-focus fix
        // as request_vars_rows above. See comment there.
        app.focus_pane();
        // Kind is now carried on the rect itself (fix 2026-07-07) so
        // secondary-side clicks in a side-by-side edit split route
        // to the right params/headers path even when the primary
        // tab is something else. Was: read rp.edit_tab, which
        // reflected only the primary side.
        let is_headers = matches!(kind, crate::ui::request_view::KvTableKind::Headers);
        // Sentinel-key routing. The `\0` prefix can't appear in
        // any HTTP header name or URL query key, so no user data
        // collides:
        //   `\0COMMIT`    — draft-row ✓ cell → commit + new row
        //   `\0VAL<name>` — value cell     → start value edit
        //   `\0NAME<name>` — name cell     → start rename edit
        //   `\0DEL<name>`  — ✕ cell        → delete row
        if key == "\0COMMIT" {
            if is_headers {
                app.http_headers_add_commit(true);
            } else {
                app.http_params_add_commit(true);
            }
            return;
        }
        if let Some(row_key) = key.strip_prefix("\0VAL") {
            let kind = if is_headers {
                crate::request_pane::KvEditKind::Headers
            } else {
                crate::request_pane::KvEditKind::Params
            };
            app.http_kv_edit_begin(kind, row_key.to_string());
            return;
        }
        if let Some(row_key) = key.strip_prefix("\0NAME") {
            let kind = if is_headers {
                crate::request_pane::KvEditKind::Headers
            } else {
                crate::request_pane::KvEditKind::Params
            };
            app.http_kv_edit_begin_name(kind, row_key.to_string());
            return;
        }
        if let Some(row_key) = key.strip_prefix("\0DEL") {
            if is_headers {
                app.http_headers_delete(row_key);
            } else {
                app.http_params_delete(row_key);
            }
            return;
        }
        if key.is_empty() {
            if is_headers {
                app.http_headers_add();
            } else {
                app.http_params_add();
            }
        } else if is_headers {
            // Backwards-compat with whole-row rects registered
            // outside render_kv_table (Vars tab still uses them).
            app.http_headers_delete(&key);
        } else {
            app.http_params_delete(&key);
        }
        return;
    }
    // Click on a `{{VAR}}` token in a Request pane's URL / body.
    // Resolved var (defined in active env) → jump to the env-file
    // definition line so the user can inspect/edit the value.
    // Unresolved var (red) → open the env-value edit prompt
    // directly, so defining a missing var is one click instead of
    // right-click → Set value…. Dynamic `$foo` vars keep the
    // jump-to-def behavior (they resolve to built-ins; there's no
    // env file to prompt for). #polish 2026-07-07.
    if let Some((_, name)) = app
        .rects
        .request_var_click_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let name = name.clone();
        // api-round-12 SEV-2 2026-07-14 — was 2-tier
        // `EnvSet::select` (empty on `.mnml`-only workspaces),
        // so `resolved` was always `false` and a click on a
        // GREEN (resolved) var wrongly opened the "Set value…"
        // prompt instead of jump-to-definition. Route through
        // the shared 5-tier helper.
        let envset = app.active_envset();
        let resolved = match name.strip_prefix('$') {
            Some(dyn_name) => crate::http::template::dynamic_var(dyn_name).is_some(),
            None => envset.lookup(&name).is_some(),
        };
        if resolved || name.starts_with('$') {
            app.open_env_var_definition(&name);
        } else {
            app.accept_env_vars(&name);
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
    // Click on the SECONDARY tab strip (right side of a side-by-side
    // edit split) → change `edit_tab_split`, not the primary tab.
    if let Some(&(_, pid, tab)) = app
        .rects
        .request_edit_tabs_split
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.edit_tab_split = Some(tab);
        }
        return;
    }
    // Click on the `⇔` edit-split chip → toggle the split.
    if let Some(r) = app.rects.request_edit_split_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        if let Some(pid) = app.active
            && let Some(Pane::Request(rp)) = app.panes.get_mut(pid)
        {
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.toggle_edit_split();
        }
        return;
    }
    // Click on the edit-split divider → cycle the ratio (30/50/70).
    // A cheap replacement for full drag-resize until it's needed.
    if let Some(r) = app.rects.request_edit_split_divider
        && crate::app::dispatch::contains(r, x, y)
    {
        if let Some(pid) = app.active
            && let Some(Pane::Request(rp)) = app.panes.get_mut(pid)
        {
            rp.edit_split_ratio = match rp.edit_split_ratio {
                0..=39 => 50,
                40..=59 => 70,
                _ => 30,
            };
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
            // Method box click opens the verb-picker context
            // menu (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS →
            // click one to set). No width guard needed anymore —
            // Method has its own bordered sub-panel (width 14)
            // and can't be confused with a headers or body row
            // click.
            if matches!(field, crate::request_pane::EditField::Method) {
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
                //
                // 2026-07-24 fix: request_view.rs moved "URL" to
                // the pane border title; the value row now starts
                // just 1 cell in (a single leading space padding).
                // Old `label_offset = 6` (from the inline
                // " URL  <value>" layout) mis-clamped clicks by 5
                // chars. api-workflow-user finding 2026-07-24.
                let dx = x.saturating_sub(rect.x);
                let label_offset: u16 = 1;
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
    // #1209 — a leaf tab strip's overflow chevrons scroll THAT leaf
    // by one. The painter only registers a chevron when it has room
    // to move, so no bounds check is needed here beyond the
    // saturating decrement.
    if let Some(&(_, leaf_key, is_left)) = app
        .rects
        .leaf_tab_arrows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let cur = app.leaf_tab_scroll.get(&leaf_key).copied().unwrap_or(0);
        let next = if is_left {
            cur.saturating_sub(1)
        } else {
            cur.saturating_add(1)
        };
        app.leaf_tab_scroll.insert(leaf_key, next);
        return;
    }
    // qa-feature 2026-07-01 — click the [×] on an exited pty's banner
    // to close the pane (alternative to Ctrl+W).
    if let Some(&(_, id)) = app
        .rects
        .pty_exit_close_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.close_pane(id);
        return;
    }
    // qa-feature 2026-07-01 — Installed / Marketplace tab chips in the
    // Integrations panel. Click switches the active sub-view.
    // 2026-07-25 — move focus to Tree so subsequent keyboard nav
    // (arrows, `/` filter, Enter) targets the panel instead of a
    // previously-focused pane.
    // 2026-08-05 — scroll is per-tab now; switching preserves the
    // last scroll position on each tab (removed the reset-to-top).
    if let Some(rect) = app.rects.integrations_tab_installed
        && crate::app::dispatch::contains(rect, x, y)
    {
        app.focus = crate::focus::Focus::Tree;
        app.integrations_panel_tab = crate::app::IntegrationsPanelTab::Installed;
        return;
    }
    if let Some(rect) = app.rects.integrations_tab_marketplace
        && crate::app::dispatch::contains(rect, x, y)
    {
        app.focus = crate::focus::Focus::Tree;
        app.integrations_panel_tab = crate::app::IntegrationsPanelTab::Marketplace;
        return;
    }
    // #1056 — third tab (In-Development). Only registered when
    // `[marketplace] show_dev_tab = true`, so this branch is inert
    // when the option is off.
    if let Some(rect) = app.rects.integrations_tab_in_dev
        && crate::app::dispatch::contains(rect, x, y)
    {
        app.focus = crate::focus::Focus::Tree;
        app.integrations_panel_tab = crate::app::IntegrationsPanelTab::InDev;
        return;
    }
    // 2026-08-04 — click the ⟳ chip on the tab row → refresh the
    // active tab's data source. Marketplace: re-fetch crates.io +
    // GitHub launcher entries (async, doesn't block the tick).
    // Installed: re-scan `<ws>/.mnml/integrations/` and
    // `~/.config/mnml/integrations/` so a manifest just-written by
    // an integration `<name> --install` surfaces immediately.
    if let Some(rect) = app.rects.integrations_tab_refresh
        && crate::app::dispatch::contains(rect, x, y)
    {
        app.focus = crate::focus::Focus::Tree;
        match app.integrations_panel_tab {
            crate::app::IntegrationsPanelTab::Marketplace
            | crate::app::IntegrationsPanelTab::InDev => app.refresh_marketplace(),
            crate::app::IntegrationsPanelTab::Installed => app.refresh_integration_manifests(),
        }
        return;
    }
    // 2026-08-07 — click the sort chip → cycle the active tab's sort
    // mode. Per-tab so switching Installed ↔ Marketplace preserves
    // each side's selected mode.
    if let Some(rect) = app.rects.integrations_tab_sort
        && crate::app::dispatch::contains(rect, x, y)
    {
        app.focus = crate::focus::Focus::Tree;
        match app.integrations_panel_tab {
            crate::app::IntegrationsPanelTab::Installed => {
                app.installed_sort = app.installed_sort.cycle();
                app.toast(format!("sort: {}", app.installed_sort.label()));
            }
            crate::app::IntegrationsPanelTab::Marketplace
            | crate::app::IntegrationsPanelTab::InDev => {
                app.marketplace_sort = app.marketplace_sort.cycle();
                app.toast(format!("sort: {}", app.marketplace_sort.label()));
            }
        }
        return;
    }
    // Integrations filter chip — click to focus filter input.
    // 2026-07-25 — also move `app.focus` back to Tree. Otherwise if
    // the user had an integration pane open (focus == Focus::Pane),
    // clicking the filter chip flipped `_filter_focused` but the
    // key-absorption block in tui/mod.rs is gated on `focus == Tree`,
    // so typed chars fell through to the open pane instead.
    if let Some(rect) = app.rects.integrations_filter_chip
        && crate::app::dispatch::contains(rect, x, y)
    {
        app.focus = crate::focus::Focus::Tree;
        app.integrations_panel_filter_focused = true;
        return;
    }
    // `+ Add integration` chip at the bottom → switch the panel to
    // the Marketplace tab. Same discoverable entry point as `+ New
    // note` on Notes and `+ New session` on Sessions.
    if let Some(rect) = app.rects.integrations_add_chip
        && crate::app::dispatch::contains(rect, x, y)
    {
        app.integrations_panel_tab = crate::app::IntegrationsPanelTab::Marketplace;
        app.toast("switched to Marketplace — pick an integration to install");
        return;
    }
    // Bufferline tab — clicking the close badge closes; clicking elsewhere on the tab activates.
    if let Some(&(_, id)) = app
        .rects
        .bufferline_tab_close
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // mouse-round-16 SEV-2 F1 2026-07-16 — require physical
        // mouse movement between tab-close clicks. Round-15's
        // `last_click = None` reset only broke dbl-CLICK state;
        // the raw second click at the same coord still closed
        // whatever tab had slid into that slot. Now: if the last
        // close fired at this exact (col, row) AND the pointer
        // hasn't moved since, swallow the click. The user must
        // physically move the mouse to close the next tab —
        // matches VS Code / Chrome tab-close behavior.
        if app.last_tab_close_at == Some((x, y)) {
            return;
        }
        app.close_pane(id);
        app.last_tab_close_at = Some((x, y));
        // Also reset last_click for the round-15 double-click
        // state (harmless if already None; kept for defense in depth).
        app.last_click = None;
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
        // `integrations.add` was never a registered command, so this
        // click toasted "no such command" instead of doing anything.
        // The Marketplace tab IS the add-an-integration surface.
        let _ = crate::command::run("integrations.show_marketplace", app);
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
    // 2026-08-01 (P2) — launcher_icon_rects click routing deleted.
    if let Some(r) = app.rects.bufferline_new_tab_button
        && crate::app::dispatch::contains(r, x, y)
    {
        // #1210 — was `app.tab_new(None)` with no menu. This is the
        // top-right cluster's `+`, and with every pane closed it is
        // the ONLY `+` on screen — so the one state where you most
        // need "reopen what I just closed" was the one state with no
        // menu to offer it. Now shows the same rows as the other two
        // chips; "New tab page" is still in there, one row down, so
        // the old action isn't lost.
        use crate::context_menu::ContextMenu;
        let items = plus_menu_items(app);
        let mut menu = ContextMenu::new(Some("Create…".into()), (r.x, r.y + 1), items);
        // Only the `+` menu opts into curation — Pin / Hide make sense
        // for a launcher you own, not for a file's right-click menu.
        menu.curatable = true;
        menu.selected = 0;
        menu.interacted = true;
        app.context_menu = Some(menu);
        return;
    }
    // Inline `+` new-request chip — sits just past the last tab in
    // the bufferline. Only rendered when at least one Request pane
    // is already open (see `paint` in bufferline.rs).
    if let Some(r) = app.rects.bufferline_new_request_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_new_request_pane();
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
    // AI launch button in the split-strip cluster. Focus the clicked
    // leaf, then fire the matching `ai.*_new` command so each click
    // spawns a fresh session (#19). The chip's `tag` disambiguates
    // Claude vs. Codex for the `"both"` config mode.
    if let Some(&(_, leaf_active, tag)) = app
        .rects
        .split_strip_ai_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // 2026-07-18 — aligned with the sidebar integration chip:
        // `ai.claude_code` / `ai.codex` (reveal-or-open) instead of
        // the always-spawn `_new` variants. Click reveals an
        // existing pane if one is open, or spawns one if not.
        // Right-click's menu still offers explicit New / Fork for
        // multi-session workflows. User complaint: split-strip chip
        // and sidebar chip did different things.
        let cmd = if tag == 1 {
            "ai.codex"
        } else {
            "ai.claude_code"
        };
        if let Some(la) = leaf_active {
            app.active = Some(la);
            app.focus = crate::focus::Focus::Pane;
        }
        crate::command::run(cmd, app);
        return;
    }
    // Terminal button in the split-strip cluster.
    // Focus the clicked leaf (if any), then open a shell in a
    // split (mirrors the `term.shell` palette command). In the
    // "no files open" state the button still fires; open_shell
    // creates the first pane.
    if let Some(&(_, leaf_active)) = app
        .rects
        .split_strip_term_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(la) = leaf_active {
            app.active = Some(la);
            app.focus = crate::focus::Focus::Pane;
        }
        app.open_shell();
        return;
    }
    // one-tab-type 2026-07-18 — `+` chip in a per-leaf tab strip.
    // Click → focus that leaf + open the SAME 10-item context menu
    // the empty-state `+` chip uses (user report: "when I have a
    // file open and click +, I expected the menu like we did
    // earlier"). Behavior parity between the two `+` chips means
    // muscle memory carries over.
    if let Some(&(r, leaf_active)) = app
        .rects
        .split_tab_plus_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(leaf_active);
        app.focus = crate::focus::Focus::Pane;
        use crate::context_menu::ContextMenu;
        let items = plus_menu_items(app);
        let mut menu = ContextMenu::new(Some("Create…".into()), (r.x, r.y + 1), items);
        // Only the `+` menu opts into curation — Pin / Hide make sense
        // for a launcher you own, not for a file's right-click menu.
        menu.curatable = true;
        menu.selected = 0;
        menu.interacted = true;
        app.context_menu = Some(menu);
        return;
    }
    // #1222 (2026-08-28) — `+N hidden` chip in a per-leaf tab strip.
    // Click → focus that leaf + open the buffer picker, which lists
    // every open pane whether or not it fit on the strip. The chip
    // shipped as paint-only, so the affordance whose whole job is to
    // say "these tabs still exist" was the one place you couldn't
    // reach them from.
    if let Some(&(_, leaf_active)) = app
        .rects
        .split_tab_hidden_chips
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(leaf_active);
        app.focus = crate::focus::Focus::Pane;
        app.open_buffer_picker();
        return;
    }
    // Claude 2×2 auto-tile placeholder card — click fills the BR
    // quadrant with a fresh Claude session.
    if let Some(r) = app.rects.ai_placeholder_card
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_claude_code_new();
        return;
    }
    // one-tab-type 2026-07-18 — empty-state `+` chip on the top
    // row. Click opens a positional context menu anchored at the
    // chip (not a centered picker) with 10 "create something"
    // options. Default highlight is "New scratch buffer" so Enter
    // fires it instantly.
    if let Some(r) = app.rects.bufferline_empty_plus
        && crate::app::dispatch::contains(r, x, y)
    {
        use crate::context_menu::ContextMenu;
        let items = plus_menu_items(app);
        // Anchor the menu near the chip so it doesn't fly to the
        // screen center — sits just below-left of the click.
        let mut menu = ContextMenu::new(Some("Create…".into()), (r.x, r.y + 1), items);
        // Only the `+` menu opts into curation — Pin / Hide make sense
        // for a launcher you own, not for a file's right-click menu.
        menu.curatable = true;
        // Default highlight = New scratch (index 0). Force
        // interacted=true so the highlight is visible immediately.
        menu.selected = 0;
        menu.interacted = true;
        app.context_menu = Some(menu);
        return;
    }
    // 2026-06-22 — per-split split-editor buttons at the right of
    // the strip. Focus the clicked leaf's active pane, then dispatch
    // split_active(dir). 2026-07-18 — when there's no active pane
    // (fresh workspace, all tabs closed) use `open_scratch_split`
    // which lays out two empty scratch editors in the direction.
    if let Some(&(_, leaf_active, dir)) = app
        .rects
        .split_strip_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(la) = leaf_active {
            app.active = Some(la);
            app.focus = crate::focus::Focus::Pane;
            app.split_active(dir);
        } else {
            app.open_scratch_split(dir);
        }
        return;
    }
    // #1018 — maximize / restore button (rightmost in the per-leaf
    // strip cluster). Click → focus this leaf so the toggle acts on
    // the leaf whose button was clicked (not whichever pane happened
    // to hold focus), then flip the zoom.
    if let Some(&(_, leaf_active)) = app
        .rects
        .split_strip_maximize_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(la) = leaf_active {
            app.active = Some(la);
            app.focus = crate::focus::Focus::Pane;
        }
        // #1096 (2026-08-20) — in full-screen, the button's glyph
        // flipped to the compress arrows so it reads as "exit
        // full-screen." Route accordingly instead of firing
        // toggle_zoom (which would flip an unrelated per-leaf zoom
        // that has no visible effect while chrome is hidden).
        if app.fullscreen_mode {
            app.toggle_fullscreen_mode();
        } else {
            app.toggle_zoom_active_leaf();
        }
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
                    && now.duration_since(prev) < std::time::Duration::from_millis(DOUBLE_CLICK_MAX_MS as u64)
        );
        app.last_click = Some((now, x, y, if is_double { 2 } else { 1 }));
        if is_double && let Some(Pane::Editor(b)) = app.panes.get_mut(tab_pane) {
            b.is_preview = false;
        }
        // qa-feature 2026-07-02 — preserve tree focus across
        // split-tab double-click promote. Same rationale as the
        // bufferline path in up_left.rs — arrow-browsing survives.
        let was_tree_focus = matches!(app.focus, crate::focus::Focus::Tree);
        app.switch_split_tab(leaf_active, tab_pane);
        if was_tree_focus {
            app.focus_tree();
        }
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
        // The × in the top-right cluster is a "close mnml" affordance
        // (matches the tooltip). Was routing to close_active_pane which
        // no-oped when nothing was open; users hovering "close mnml"
        // and clicking got no response.
        app.request_quit();
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
    // Hover-help panel → left-click on the `⋮` kebab opens the
    // per-panel context menu (Close, later: About, settings). The
    // rest of the panel body is inert; the old click-anywhere-
    // closes behavior surprised users who clicked to read a shortcut
    // and lost the panel. 2026-08-11.
    if let Some(r) = app.rects.hover_help_kebab
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_hover_help_kebab_menu((r.x, r.y + 1));
        return;
    }
    // Hover-help `Try it →` action buttons — checked before the
    // whole-panel inert-click catch-all below, so a click landing on
    // one of these narrow rows fires its palette command instead of
    // being swallowed. 2026-08-16 — wires up `InfoViewCopy::try_it`,
    // which the framework carried since Phase 1 but never dispatched.
    if let Some((_, cmd_id)) = app
        .rects
        .hover_help_try_it
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        let _ = crate::command::run(&cmd_id, app);
        return;
    }
    // Hover-help `→ Manual` docs link — opens the site manual page.
    if let Some((r, url)) = app.rects.hover_help_docs.clone()
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::app::open_url_external(&url);
        app.toast("opened in browser");
        return;
    }
    // Body clicks inside the info panel are swallowed so they don't
    // fall through to tree / statusline hit-tests below.
    if let Some(r) = app.rects.hover_help_strip
        && crate::app::dispatch::contains(r, x, y)
    {
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
    // Statusline AI Claude chip — unlinked → link prompt;
    // linked → open the Claude usage pane. #876.
    // 2026-08-16 — Pane::AiUsage was split into two per-product
    // panes; Claude chip now opens Pane::ClaudeUsage.
    if let Some(r) = app.rects.statusline_ai_claude_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        if crate::ai_usage::read_claude_token().is_none() {
            app.open_link_claude_token_prompt();
        } else {
            app.open_claude_usage_pane();
        }
        return;
    }
    // Task #944 rename UX (2026-08-16) — pencil hitrect on a
    // Claude Usage pane section header. Click → open the rename
    // prompt seeded with that account's current name. Checked
    // BEFORE generic pane-body clicks so a click on the pencil
    // doesn't get consumed by the pane's focus-then-nothing path.
    {
        let hit = app
            .rects
            .claude_usage_pencils
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .map(|(_, name)| name.clone());
        if let Some(name) = hit {
            app.open_claude_account_rename_prompt(name);
            return;
        }
    }
    // Statusline AI Codex chip → open the Codex usage pane.
    // 2026-08-16 — was a toast + refresh; the pane surface makes
    // the tokens/sessions/last-error legible without hover, matches
    // the Claude chip's affordance, and still nudges a refresh via
    // `open_codex_usage_pane`.
    if let Some(r) = app.rects.statusline_ai_codex_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_codex_usage_pane();
        return;
    }
    // Statusline coverage chip (#889) → open the coverage integration
    // Pty pane (provided by `mnml-tattle-coverage`). The built-in
    // Pane::Coverage was removed in favor of the external tool, which
    // also shows Istanbul coverage alongside the feature-coverage
    // sparklines this chip renders.
    if let Some(r) = app.rects.statusline_coverage_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        // R12 vscode-mouse SEV-3 2026-08-23 — check the command
        // exists (built-in or dynamic) before firing, so a user
        // without `mnml-tattle-coverage` installed doesn't get the
        // opaque `no such command: tattle_coverage_ext.open` toast.
        let id = "tattle_coverage_ext.open";
        let known = crate::command::registry().get(id).is_some()
            || app.dynamic_commands.iter().any(|c| c.id == id);
        if known {
            let _ = crate::command::run(id, app);
        } else {
            app.toast("coverage integration not installed — right-click for options");
        }
        return;
    }
    // Statusline mode chip → toggle input style (vim ↔ standard).
    if let Some(r) = app.rects.statusline_mode_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("editor.toggle_keymap", app);
        return;
    }
    // Dynamic statusline segments — both manifest-declared
    // `[[statusline_segments]]` chips (see
    // `src/app/statusline_segments.rs`) and IPC-driven segments
    // set via an integration's `statusline_set_segment` call. Both use
    // the same `DynamicSegment.click_command` field so a click
    // fires whichever palette command the source declared.
    // 2026-08-17 (data-driven statusline chips).
    if let Some((_, seg_id)) = app
        .rects
        .statusline_segment_hits
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let seg_id = seg_id.clone();
        if let Some(cmd) = app
            .dynamic_segments
            .iter()
            .find(|d| d.id == seg_id)
            .and_then(|d| d.click_command.clone())
        {
            let _ = crate::command::run(&cmd, app);
        }
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
    // Sonos cluster (2026-08-22). Checked before the music cluster
    // because the two sit adjacent on the right lane.
    //   speaker glyph → send / stop sending this Mac's audio (the
    //                   headline action; AirPlay when Music.app is the
    //                   source, loopback stream otherwise)
    //   play / next   → transport on the active room
    //   Room · Track  → room picker
    if let Some(r) = app.rects.statusline_sonos_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.sonos_toggle_mac_audio();
        return;
    }
    if let Some(r) = app.rects.statusline_sonos_play_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.sonos_play_pause();
        return;
    }
    if let Some(r) = app.rects.statusline_sonos_next_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.sonos_send(crate::sonos::Cmd::Next);
        return;
    }
    if let Some(r) = app.rects.statusline_sonos_label_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.sonos_pick_room();
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
    // 2026-08-22 — idle-state play-glyph chip: one-tap start-playing.
    // Bound to `mixr.play_now` (spawns `mixr --play --panel browse`
    // when Beatport-authed; falls back to a browser-only open with
    // a "sign in first" toast otherwise). Checked BEFORE the label
    // chip so the split rects behave as two distinct clicks.
    if let Some(r) = app.rects.statusline_music_action_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        // Only mixr backs a play-a-chart flow today; Music/Spotify
        // idle clicks still fire below via the label chip. Route
        // through the command dispatcher so palette / chord users
        // get the same behavior.
        match app.config.ui.preferred_music_app.as_str() {
            "music" => send_macos_player("Music", "playpause"),
            "spotify" => send_macos_player("Spotify", "playpause"),
            _ => {
                command::run("mixr.play_now", app);
            }
        }
        return;
    }
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
    // The notification badge opens the message history — the badge is
    // the only on-screen sign the log has anything in it, so it has to be
    // the way in as well.
    if let Some(r) = app.rects.statusline_notif_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::command::run("messages.show", app);
        return;
    }
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
        app.toggle_wrap();
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
    // #polish 2026-07-06 — file chip → reveal active buffer in tree.
    if let Some(r) = app.rects.statusline_file_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("view.reveal_active", app);
        return;
    }
    // #polish 2026-07-06 — diagnostics chip → open diagnostics panel.
    if let Some(r) = app.rects.statusline_diagnostics_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("lsp.diagnostics", app);
        return;
    }
    // #polish 2026-07-06 — symbol crumb → open outline pane.
    if let Some(r) = app.rects.statusline_symbol_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("outline.show", app);
        return;
    }
    // #polish 2026-07-06 — PR badge → open web URL.
    if let Some(r) = app.rects.statusline_pr_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        if let Some(pr) = app
            .git_rail
            .pulls
            .iter()
            .find(|p| p.is_current_branch)
            .cloned()
        {
            crate::app::open_url_external(&pr.web_url);
            app.toast(format!("opened {}{}", pr.host_tag, pr.number_label));
        }
        return;
    }
    // #polish 2026-07-06 — macro rec chip → stop recording.
    if let Some(r) = app.rects.statusline_macro_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("vim.macro_toggle", app);
        return;
    }
    // #polish 2026-07-06 — find chip → reopen find prompt.
    if let Some(r) = app.rects.statusline_find_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("find.find", app);
        return;
    }
    // #polish 2026-07-06 — language chip → toast the detected
    // language + hint the editorconfig / extension source.
    if let Some(r) = app.rects.statusline_language_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let lang = app
            .active_editor()
            .and_then(|b| b.language_ext.clone())
            .unwrap_or_else(|| "—".to_string());
        app.toast(format!("language: {lang} (via file extension)"));
        return;
    }
    // (activity-bar icons + gear are handled near the top of the
    // cascade now — 2026-07-19 — to keep stale integration-panel rects
    // from ever shadowing them.)
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
    // #1112 f/u (2026-08-21) — Search section flag chips: click
    // toggles + re-runs the current query. Dispatches through the
    // palette command so state flip, toast, and rerun all happen
    // atomically (no drift with the keyboard entry path).
    if let Some(&(_, ch)) = app
        .rects
        .search_section_flag_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let cmd = match ch {
            'c' => "search.toggle_case_sensitive",
            'w' => "search.toggle_whole_word",
            'r' => "search.toggle_regex",
            _ => return,
        };
        let _ = crate::command::run(cmd, app);
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
    // 2026-07-31 — Integration detail pane button click. Focus the
    // pane, move the cursor to the clicked row, then fire it. Runs
    // BEFORE the activity-panel `integration_icon_rects` cascade
    // because the detail pane's own rects overlay the same area
    // if a click lands there.
    if let Some(&(_, pane_id, action_idx)) = app
        .rects
        .integration_detail_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pane_id);
        // If it's a right-panel host, refocus the right panel too.
        if app.right_panel_panes.contains(&pane_id) {
            app.focus = crate::focus::Focus::RightPanel;
        } else {
            app.focus_pane();
        }
        if let Some(crate::pane::Pane::IntegrationDetail(d)) = app.panes.get_mut(pane_id) {
            d.cursor = action_idx;
        }
        crate::ui::integration_detail_view::fire_action(app, pane_id, action_idx);
        return;
    }
    // INTEGRATIONS icon — hand off to the configured command.
    // Two command forms supported:
    //   `:<ex>`  → mnml ex command
    //   `<id>`   → mnml registered command id
    // Check BEFORE the section-toggle below.
    // 2026-08-16 — "↑ Update to <ver>" chip on an installed
    // marketplace row. Checked BEFORE marketplace_row_rects (a
    // superset rect) so the chip click doesn't fall through to
    // "open detail pane" behavior. Silent no-op if we can't
    // classify the entry's InstallSpec (shouldn't happen — the
    // chip only renders for entries we know how to update).
    if let Some(id) = app
        .rects
        .update_chip_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, id)| id.clone())
    {
        // #992 (2026-08-18) — routing moved to
        // App::apply_integration_update so the chip-click here and
        // the right-click "Update to X" menu item stay in lockstep.
        app.apply_integration_update(&id);
        return;
    }
    // #1202 (2026-08-25) — "↑ Update" chip on a FONTS row → run the
    // brew upgrade in a Pty pane so the user sees the install live.
    // After it finishes, `integrations.refresh` re-scans versions.
    if let Some(family) = app
        .rects
        .font_update_chip_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, f)| f.clone())
    {
        match crate::font_scan::update_command(&family) {
            Some(cmd) => {
                let ws = app.workspace.clone();
                app.open_pty_dir(
                    crate::pty_pane::BinaryProfile::task(
                        &format!("font update: {family}"),
                        &cmd,
                        ws,
                    ),
                    crate::layout::SplitDir::Horizontal,
                );
                app.toast(format!(
                    "updating {family} — run `:integrations.refresh` after it finishes"
                ));
            }
            None => app.toast(format!("no update command known for {family}")),
        }
        return;
    }
    // P4c (2026-08-01) — click on a marketplace entry row → install
    // action. Checked BEFORE the integration icon row cascade below,
    // so a marketplace row doesn't get swallowed by a co-located
    // icon rect (unlikely — different tabs — but safest).
    if let Some(&(_, mp_idx)) = app
        .rects
        .marketplace_row_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // 2026-08-06 — was `install_marketplace_entry(mp_idx)`
        // (immediate install, zero confirmation — user surprise).
        // Then briefly a confirm dialog. Now: opens the existing
        // integration-detail pane in the main area so the user
        // sees description / source / links first, and the pane's
        // `[Install]` button routes to the same confirm dialog.
        if let Some(entry) = app.marketplace_entries.get(mp_idx) {
            let id = entry.id.clone();
            app.open_integration_detail_pane(&id);
        }
        return;
    }
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
                .label
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
    // Menu-bar item click — handled earlier by the menu-open
    // early guard (see the `if let Some(open) = app.menu_open ...`
    // block near the top of this handler). By the time execution
    // reaches here `menu_open` is always None and this rect check
    // was previously guarded on `menu_open.is_some()`, so it's
    // dead code — removed 2026-08-05 per reviewer drift-risk
    // note. Menu-bar word click below is still live (it fires
    // when NO menu is open yet).

    // Menu-bar overflow chip (`»`) — click cycles through the
    // hidden menus. First click opens the first hidden; subsequent
    // clicks advance to the next hidden one, wrapping when past
    // the last. R9 vscode-mouse SEV-2 + R10 follow-up (was: click
    // always opened the SAME first-hidden menu, so 5 other menus
    // stayed unreachable at 120-cell width).
    if let Some((rect, first_hidden_idx)) = app.rects.menu_bar_overflow
        && crate::app::dispatch::contains(rect, x, y)
    {
        let total_menus = crate::menu_bar::bar(app).len();
        let next_idx = match app.menu_open.as_ref().map(|s| s.menu_idx) {
            Some(cur) if cur + 1 < total_menus => {
                // Advance to next menu, wrap to first-hidden if
                // we walked off the last menu entirely.
                let candidate = cur + 1;
                if candidate < total_menus {
                    candidate
                } else {
                    first_hidden_idx
                }
            }
            _ => first_hidden_idx,
        };
        app.menu_open = Some(crate::menu_bar::MenuOpenState::new_mouse(next_idx));
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
    // qa-feature 2026-07-01 — Alt+click on the header ALSO fully
    // expands or fully collapses every dir inside the primary tree,
    // matching the recursive alt-click gesture on individual dir rows.
    if let Some(tr) = app.rects.tree_toggle
        && crate::app::dispatch::contains(tr, x, y)
    {
        if m.modifiers.contains(KeyModifiers::ALT) {
            let was_expanded = app.tree_root_expanded;
            if was_expanded {
                app.tree.collapse_all();
            } else {
                app.tree.expand_all_dirs();
            }
        }
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
    // qa-feature 2026-06-30 — GitGraph repo-switch pill. The
    // sidebar's pill is anchored to the GIT pane's repo, so the
    // most useful click action is `switch_active_repo` (changes
    // what the git pane is looking at, which is what the user
    // expects from a dropdown next to the repo name). Fallback
    // cascade: 2+ repos → open_repo_picker; extras configured →
    // open_workspace_picker; else open_workspaces_editor so the
    // click leads somewhere even on a single-repo single-WS setup.
    if let Some(rect) = app.rects.git_graph_repo_switch
        && crate::app::dispatch::contains(rect, x, y)
    {
        if app.repos.len() > 1 {
            app.open_repo_picker();
        } else if !app.extra_workspaces.is_empty() {
            app.open_workspace_picker();
        } else {
            app.open_workspaces_editor();
        }
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
    // qa-feature 2026-07-01 — click on an extra's `○` marker
    // promotes it to primary (same as right-click → Set as
    // workspace). Sits inside the toggle rect; this check has to
    // come FIRST so the promotion wins over the section-toggle.
    if let Some(&(_, ws_idx)) = app
        .rects
        .extra_workspace_promote_dots
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(path) = app.extra_workspaces.get(ws_idx).map(|w| w.root.clone()) {
            app.set_workspace_to(path);
        }
        return;
    }
    // Extra-workspace section header → toggle expansion.
    // qa-feature 2026-07-01 — Alt+click on an extra's header ALSO
    // fully expands/collapses every dir inside that extra's tree,
    // matching the recursive alt-click gesture on individual dir
    // rows. Symmetrical with the primary header handling above.
    if let Some(&(_, ws_idx)) = app
        .rects
        .extra_workspace_toggles
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if m.modifiers.contains(KeyModifiers::ALT)
            && let Some(ws) = app.extra_workspaces.get_mut(ws_idx)
        {
            let was_expanded = ws.expanded;
            if was_expanded {
                ws.tree.collapse_all();
            } else {
                ws.tree.expand_all_dirs();
            }
        }
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
        let alt = m.modifiers.contains(KeyModifiers::ALT);
        app.click_extra_workspace_row_ex(ws_idx, row_idx, alt);
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
                    && now.duration_since(prev)
                        < std::time::Duration::from_millis(DOUBLE_CLICK_MAX_MS as u64) =>
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
                // directory row. Alt held = copy instead of move
                // (Finder / VS Code convention). Read the modifier
                // at drag-start; the state at drop time is assumed
                // to match, matching how OS file managers behave.
                if let Some(row) = app.tree.selected_row() {
                    let alt = m.modifiers.contains(KeyModifiers::ALT);
                    app.begin_tree_drag_with_mode(row.path.clone(), row.is_dir, y, alt);
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
                    // qa-feature 2026-07-01 — Alt+click on a dir
                    // row recursively expands/collapses that
                    // subtree. Was originally Shift+click but
                    // Ghostty (and most terminals) reserve
                    // Shift+click for text-selection, so the
                    // modifier never reaches mnml. Alt+click
                    // (⌥+click on macOS) passes through cleanly
                    // and is what VS Code uses for the same
                    // gesture anyway.
                    if m.modifiers.contains(KeyModifiers::ALT) {
                        app.tree.toggle_current_recursive();
                    } else {
                        app.tree.toggle_current();
                    }
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
    // Empty-state `+ dock` chip → fire dock.new_text_br.
    // 2026-08-07 vscode-mouse r1 F1 SEV-2 — was `dock.new_text`
    // (BottomLeft), but the chip itself is painted at bottom-RIGHT
    // (`ui/dock.rs:482-486`). Corner mismatch surprised users who
    // expect the button to act where it sits.
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
    // qa-feature 2026-06-30 — click a section header in the git
    // palette toggles collapse. Wins over the filter / row hit-tests
    // since headers are exclusive rows.
    if let Some((_, label)) = app
        .rects
        .git_palette_section_headers
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        if app.git_palette_collapsed_sections.contains(&label) {
            app.git_palette_collapsed_sections.remove(&label);
        } else {
            app.git_palette_collapsed_sections.insert(label);
        }
        return;
    }
    // qa-feature 2026-06-30 — click a folder header (`▾ chore (4)`)
    // toggles its collapse. Key is `SECTION:folder` so the same
    // folder name under LOCAL vs REMOTE doesn't clash.
    if let Some((_, key)) = app
        .rects
        .git_palette_folder_headers
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        if app.git_palette_collapsed_folders.contains(&key) {
            app.git_palette_collapsed_folders.remove(&key);
        } else {
            app.git_palette_collapsed_folders.insert(key);
        }
        return;
    }
    // Git-palette refresh chip in the GIT header — click to
    // re-scan branches / tags / worktrees. Checked BEFORE the
    // filter input so the chip in the row-1 area doesn't get
    // shadowed by another handler.
    if let Some(r) = app.rects.git_palette_refresh_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.rediscover_repos();
        app.toast("git: refreshed".to_string());
        return;
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
    // Sessions panel `/` filter row → focus. Checked BEFORE the
    // chip / tab handlers below so it wins when the row overlaps.
    //
    // R15 vscode-mouse M-01 (2026-08-23) — was setting only the
    // filter-focused flag; typing after the click still routed to
    // the underlying Pty because the char-dispatch gate ANDs
    // `filter_focused && focus == Tree`. Focus the rail here so
    // the click actually captures keystrokes.
    if let Some(r) = app.rects.sessions_panel_filter_input
        && crate::app::dispatch::contains(r, x, y)
    {
        app.focus_tree();
        app.sessions_panel_filter_focused = true;
        return;
    }
    // Sessions panel `+ New session` chip → spawn a NEW Claude
    // Code pane. Checked BEFORE tab clicks so a click on the chip
    // wins.
    //
    // 2026-07-18 — was `ai.claude_code`, which is the "reveal or
    // open" command that re-focuses an existing Claude Code pane
    // instead of spawning a fresh one. User: "when I open a Claude
    // Code session and then click new session again, nothing
    // happens" — because the existing pane was already focused,
    // the reveal became a no-op. Use `ai.claude_code_new`
    // (always-spawn) instead.
    if let Some(r) = app.rects.session_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::command::run("ai.claude_code_new", app);
        return;
    }
    // HTTP panel — sectioned sidebar (#10 v2). Order: chip rects
    // first (they sit inside header rows), then row rects, then
    // header rows themselves (the collapse-toggle catch-all).
    // Per-section chip cluster (filter / refresh / capture / clear).
    // Checked before the older section-specific rect handlers below so
    // routing goes through the shared HttpChipKind dispatch.
    if let Some((_, section, kind)) = app
        .rects
        .http_panel_section_chips
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
        .copied()
    {
        use crate::app::HttpChipKind;
        match kind {
            HttpChipKind::Filter => {
                // Same focus + section snap as the filter-input rect
                // click above — otherwise keystrokes route to the
                // previously-focused pane. vscode-user-mouse SEV-2
                // 2026-07-10.
                app.focus = crate::focus::Focus::Tree;
                app.active_section = crate::app::ActivitySection::Http;
                app.http_panel_filter_focused = true;
            }
            HttpChipKind::Refresh => {
                crate::command::run("http.refresh", app);
            }
            HttpChipKind::Capture => {
                crate::command::run("http.capture_start", app);
            }
            HttpChipKind::Clear => match section {
                1 => app.http_panel_clear_recent(),
                2 => app.http_panel_clear_captured(),
                _ => {
                    // MOCKS / COLLECTIONS — the ✕ chip clears the
                    // filter as a safe default (destructive delete-
                    // all was too dangerous to bind to a single
                    // click).
                    app.http_panel_filter.clear();
                    app.http_panel_filter_focused = false;
                }
            },
            HttpChipKind::New => match section {
                3 => {
                    crate::command::run("http.new_env", app);
                }
                6 => {
                    crate::command::run("http.new_collection", app);
                }
                _ => app.toast("no `new` action for this section"),
            },
        }
        return;
    }
    if let Some(r) = app.rects.http_panel_capture_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::command::run("http.capture_start", app);
        return;
    }
    if let Some(r) = app.rects.http_panel_captured_clear_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_panel_clear_captured();
        return;
    }
    if let Some(r) = app.rects.http_panel_recent_clear_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_panel_clear_recent();
        return;
    }
    if let Some(r) = app.rects.http_panel_discover_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::command::run("http.paste_curl", app);
        return;
    }
    if let Some(r) = app.rects.http_panel_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_panel_new_request();
        return;
    }
    if let Some(r) = app.rects.http_panel_filter_input
        && crate::app::dispatch::contains(r, x, y)
    {
        // vscode-user-mouse SEV-2 2026-07-10 fix: setting the panel
        // filter focus flag alone wasn't enough — the keystroke
        // absorber in `dispatch_key` also gates on `app.focus ==
        // Focus::Tree` + `app.active_section == Http`. Without also
        // moving focus + section, typing after the click still
        // routed to whatever pane last had focus. Snap both to
        // match the visual focus indicator.
        app.focus = crate::focus::Focus::Tree;
        app.active_section = crate::app::ActivitySection::Http;
        app.http_panel_filter_focused = true;
        return;
    }
    if let Some((_, path)) = app
        .rects
        .http_panel_files
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let path = path.clone();
        app.open_path(&path);
        return;
    }
    if let Some((_, idx)) = app
        .rects
        .http_panel_recent_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let idx = *idx;
        if let Some(entry) = app.http_panel_recent_cache.get(idx).cloned() {
            let (curl, method, url) = crate::http::history::entry_to_curl(&entry);
            app.open_curl_scratch(&curl, &method, &url);
        }
        return;
    }
    if let Some((_, idx)) = app
        .rects
        .http_panel_captured_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let idx = *idx;
        if let Some(row) = app.http_panel_captured_cache.get(idx).cloned() {
            app.open_curl_scratch(&row.to_curl(), &row.method, &row.url);
        }
        return;
    }
    if let Some((_, section)) = app
        .rects
        .http_panel_section_headers
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let idx = *section as usize;
        if idx < app.http_panel_section_collapsed.len() {
            app.http_panel_section_collapsed[idx] = !app.http_panel_section_collapsed[idx];
        }
        return;
    }
    // ENVS section — env-row click switches active env; new chip
    // opens the create-env prompt.
    if let Some((_, name)) = app
        .rects
        .http_panel_env_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.accept_http_env(&name);
        return;
    }
    if let Some(r) = app.rects.http_panel_env_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_new_env_prompt();
        return;
    }
    // #polish 2026-07-06 — `+ New chain` / `+ New collection` chips
    // mirror the `+ New env` idiom for creation from the sidebar.
    if let Some(r) = app.rects.http_panel_chain_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_new_chain_prompt();
        return;
    }
    if let Some(r) = app.rects.http_panel_collection_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_new_collection_prompt();
        return;
    }
    // CHAINS row → run that chain.
    if let Some((_, path)) = app
        .rects
        .http_panel_chain_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.http_chain_run_path(path);
        return;
    }
    // MOCKS row → replay that mock into the active Request pane.
    if let Some((_, path)) = app
        .rects
        .http_panel_mock_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.http_replay_mock_from_path(&path);
        return;
    }
    // #22 — Collections file row → open the file as a Request pane.
    if let Some((_, path)) = app
        .rects
        .http_panel_collection_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.open_path(&path);
        return;
    }
    // #polish 2026-07-06 — per-collection `+` chip (new request in
    // THIS collection). Checked BEFORE the row-wide collapse toggle
    // so the chip cell wins over the row body.
    if let Some((_, root)) = app
        .rects
        .http_panel_collection_new_request_chips
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.http_new_request_in_collection(&root);
        return;
    }
    // #polish 2026-07-06 — HTTP panel header toolbar chips (↺ refresh,
    // ↕ collapse-all). Runs the mapped command directly.
    if let Some((_, cmd_id)) = app
        .rects
        .http_panel_icon_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        let _ = crate::command::run(cmd_id, app);
        return;
    }
    // #22 v2 — Collections folder row → toggle expand/collapse.
    if let Some((_, dir)) = app
        .rects
        .http_panel_collection_folder_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        if !app.http_panel_collections_collapsed_dirs.remove(&dir) {
            app.http_panel_collections_collapsed_dirs.insert(dir);
        }
        return;
    }
    // `↓ Import…` → open the import picker (Postman / HAR).
    if let Some(r) = app.rects.http_panel_import_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_import_prompt();
        return;
    }
    // Notes panel — filter row, file rows, `+ New note` chip (#8).
    if let Some(r) = app.rects.notes_panel_filter_input
        && crate::app::dispatch::contains(r, x, y)
    {
        app.notes_panel_filter_focused = true;
        return;
    }
    if let Some(r) = app.rects.notes_panel_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.notes_panel_new_note();
        return;
    }
    if let Some((_, path)) = app
        .rects
        .notes_panel_files
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let path = path.clone();
        app.open_path(&path);
        return;
    }
    // Findings panel — row click opens the .md file (2026-08-07).
    if let Some((_, path)) = app
        .rects
        .findings_panel_files
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let path = path.clone();
        app.open_path(&path);
        return;
    }
    // TODOs panel — refresh chip + row click (#9).
    if let Some(r) = app.rects.todos_panel_filter_input
        && crate::app::dispatch::contains(r, x, y)
    {
        app.todos_panel_filter_focused = true;
        return;
    }
    if let Some(r) = app.rects.todos_panel_refresh_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.todos_panel_refresh();
        app.toast("todos: rescanned".to_string());
        return;
    }
    // 2026-08-24 — Notes / Findings refresh chips (header ↻).
    if let Some(r) = app.rects.notes_panel_refresh_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.notes_panel_refresh();
        app.toast("notes: refreshed".to_string());
        return;
    }
    if let Some(r) = app.rects.findings_panel_refresh_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.findings_panel_refresh();
        app.toast("findings: refreshed".to_string());
        return;
    }
    if let Some(r) = app.rects.sessions_panel_refresh_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.sessions_panel_refresh();
        app.toast("sessions: refreshed".to_string());
        return;
    }
    // The kebab sits inside the row rect, so it must be tested BEFORE
    // the row or the row always wins.
    if let Some((kr, row)) = app.rects.todos_panel_kebab
        && crate::app::dispatch::contains(kr, x, y)
    {
        app.open_todos_action_menu(row, (kr.x, kr.y + 1));
        return;
    }
    if let Some(&(_, row)) = app
        .rects
        .todos_panel_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // Move the panel's selection to the clicked row and PREVIEW it,
        // staying in the panel. Clicking used to `open_path`, which sets
        // `Focus::Pane`, so the arrows immediately afterwards drove the
        // editor instead of the list — and the panel cursor was never
        // updated either, so arrowing resumed from wherever it had last
        // been. User: "i should be able to click on todo on left and
        // arrow up and down and keep focus on left panel".
        app.focus = crate::focus::Focus::Tree;
        app.active_section = crate::app::ActivitySection::Todos;
        app.todos_panel_cursor = row;
        app.todos_panel_preview();
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
    // 2026-08-24 (user ask) — refresh chip in the AGENTS header
    // top-right forces a rescan of local Claude/Codex sessions +
    // (when configured) cloud runs. Auto-refresh runs every 30s
    // anyway; this is the click affordance for impatience.
    if let Some(r) = app.rects.agents_panel_refresh_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.agents_panel_built_at = None;
        app.refresh_agents_panel_if_due();
        app.toast("agents: refreshing…".to_string());
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
                crate::claude_agents::AgentSource::Ecs => {
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
    // R16 (2026-08-24) — refresh chip on the CLOUD AGENTS header
    // top-right forces a rescan of the ECS runner rows (auto-poll
    // is on a 2-minute cadence; this is for impatience). Reuses
    // the same "reset built_at + call refresh" path AGENTS uses.
    if let Some(r) = app.rects.cloud_agents_refresh_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.agents_panel_built_at = None;
        app.refresh_agents_panel_if_due();
        app.toast("cloud agents: refreshing…".to_string());
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
    if app.http_panel_filter_focused {
        app.http_panel_filter_focused = false;
    }
    if app.todos_panel_filter_focused {
        app.todos_panel_filter_focused = false;
    }
    if app.notes_panel_filter_focused {
        app.notes_panel_filter_focused = false;
    }
    if app.sessions_panel_filter_focused {
        app.sessions_panel_filter_focused = false;
    }
    // Sessions panel tab (vertical-tab strip shown when
    // `ActivitySection::Sessions` is active). Click →
    // focus that Pty pane. Also arms a drag — mouse-up
    // over another tab swaps them.
    //
    // #1184 (2026-08-23) — route through `reveal_pane` so a
    // rail click on a Claude living in another desktop tab
    // (layout page) flips to that layout instead of silently
    // no-oping. `reveal_pane` handles the cross-layout switch
    // + `remember_active_for_tab` bookkeeping.
    if let Some(&(_, pid)) = app
        .rects
        .session_tabs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.reveal_pane(pid);
        app.focus_pane();
        app.session_drag_pid = Some(pid);
        return;
    }
    // Git-palette row (the GitKraken-style panel shown when
    // `ActivitySection::Git` is active). Maps to the same
    // `GitRailHit` dispatch as the legacy rail.
    // Editor breadcrumb — each segment opens a Files pane at its
    // directory. The Files pane's own breadcrumb was already clickable;
    // the editor's registered no rects at all, so two rows that look
    // identical behaved differently (user: "should this line with
    // breadcrumb be clickable at all?").
    if let Some((_, dir)) = app
        .rects
        .editor_breadcrumbs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.open_files_pane(Some(dir));
        return;
    }
    // ── Files pane breadcrumb ──
    //
    // Checked BEFORE the row list because the header sits above the rows
    // and a stale row rect must never win over a live header rect.
    if let Some((r, pane_id)) = app.rects.file_pane_sort_label
        && crate::app::dispatch::contains(r, x, y)
    {
        app.active = Some(pane_id);
        app.focus_pane();
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pane_id) {
            use crate::file_browser::Sort;
            let next = match f.sort {
                Sort::DirsFirstName => Sort::Size,
                Sort::Size => Sort::Modified,
                Sort::Modified => Sort::DirsFirstName,
            };
            f.set_sort(next);
        }
        return;
    }
    if let Some((r, pane_id)) = app.rects.file_pane_places_chevron
        && crate::app::dispatch::contains(r, x, y)
    {
        app.active = Some(pane_id);
        app.focus_pane();
        app.open_files_destinations_picker();
        return;
    }
    if let Some((_, pane_id, dir)) = app
        .rects
        .file_pane_breadcrumbs
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.active = Some(pane_id);
        app.focus_pane();
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pane_id) {
            f.navigate_to(&dir);
        }
        return;
    }
    // ── Files pane rows ──
    //
    // First click selects, a click on the ALREADY-selected row activates
    // (descend / open) — the same single-click-then-confirm shape the
    // file tree uses, and it avoids the double-click timing guess.
    if let Some(&(_, pane_id, idx)) = app
        .rects
        .file_pane_rows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pane_id);
        app.focus_pane();
        // #files — MOUSE PATH TO MARKING.
        //
        // The mouse tester's sharpest finding: marking is the pane's
        // headline feature and had no mouse path whatsoever — ctrl-click,
        // shift-click, middle-click and clicking the green mark gutter all
        // did nothing, and the footer's only guidance was three chords.
        //
        // Ctrl/Cmd+click toggles one, Shift+click extends a range from the
        // cursor. Both are the file-manager conventions (Finder, Explorer,
        // VS Code's explorer), so nothing new has to be learned.
        let ctrl = m.modifiers.contains(KeyModifiers::CONTROL)
            || m.modifiers.contains(KeyModifiers::SUPER);
        let shift = m.modifiers.contains(KeyModifiers::SHIFT);
        if (ctrl || shift) && idx != crate::ui::file_browser_view::PARENT_ROW {
            if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pane_id) {
                if shift {
                    f.shift_extend_to(idx);
                } else {
                    if let Some(e) = f.entries.get(idx) {
                        let p = e.path.clone();
                        f.toggle_mark_path(p);
                    }
                    f.selected = idx;
                }
            }
            return;
        }
        // The pinned `..` row is not an entry index — it means "go up".
        if idx == crate::ui::file_browser_view::PARENT_ROW {
            if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pane_id) {
                f.go_parent();
            }
            return;
        }
        let was_selected = matches!(
            app.panes.get(pane_id),
            Some(crate::pane::Pane::Files(f)) if f.selected == idx
        );
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pane_id) {
            f.selected = idx;
        }
        if was_selected {
            app.files_pane_activate(pane_id);
        }
        return;
    }

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
        // qa-feature 2026-06-30 — stamp the clicked row's
        // identifier so git_palette::draw can paint the
        // highlight bg on its render call. Click feedback was
        // missing — clicking a branch jumped the graph but the
        // sidebar row looked unselected.
        match &hit {
            crate::ui::git_palette::GitPaletteHit::Branch(i) => {
                if let Some(b) = app.git_rail.branches.get(*i) {
                    app.git_palette_selected = Some(b.name.clone());
                }
            }
            crate::ui::git_palette::GitPaletteHit::Worktree(i) => {
                if let Some(wt) = app.git_rail.worktrees.get(*i) {
                    app.git_palette_selected = Some(wt.label.clone());
                }
            }
            crate::ui::git_palette::GitPaletteHit::RemoteBranch(i) => {
                if let Some(name) = app.git_rail.remote_branches.get(*i).cloned() {
                    app.git_palette_selected = Some(name);
                }
            }
            crate::ui::git_palette::GitPaletteHit::Stash(i) => {
                if let Some(st) = app.git_rail.stashes.get(*i) {
                    app.git_palette_selected = Some(st.id.clone());
                }
            }
            crate::ui::git_palette::GitPaletteHit::Tag(i) => {
                if let Some(name) = app.git_rail.tags.get(*i).cloned() {
                    app.git_palette_selected = Some(name);
                }
            }
            crate::ui::git_palette::GitPaletteHit::Pull(_) => {
                // PRs open in browser; no in-sidebar selection
                // semantics.
            }
        }
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
                    && now.duration_since(prev)
                        < std::time::Duration::from_millis(DOUBLE_CLICK_MAX_MS as u64) =>
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
    // Click on a toast box → dismiss that toast. mouse-round-10
    // SEV-2 2026-07-12 — was silent fall-through into the pane
    // beneath.
    if let Some((idx, _)) = app
        .rects
        .toast_stack_rects
        .iter()
        .enumerate()
        .find(|(_, r)| crate::app::dispatch::contains(**r, x, y))
    {
        if idx < app.toast_stack.len() {
            app.toast_stack.remove(idx);
            // The primary `App.toast` field mirrors the newest
            // stack entry; if we just dismissed it, clear the
            // legacy slot too so the fade-out picks up.
            if idx == 0 {
                app.toast = None;
            }
        }
        return;
    }
    // Double-click on a split divider → equalize splits (VS Code
    // convention — double-click a resize handle to reset the ratio).
    // mouse-round-9 SEV-2 2026-07-11. mouse-round-11 SEV-2
    // 2026-07-12 — was gated on `hover_divider_idx` which never
    // gets set under IPC-driven click-only sequences (no Moved
    // events precede the click). Fall back to a direct hit-test
    // against `split_dividers` so the IPC harness + real mouse
    // both work.
    let over_divider = app.hover_divider_idx.is_some()
        || app
            .rects
            .split_dividers
            .iter()
            .any(|d| crate::app::dispatch::contains(d.rect, x, y));
    if over_divider {
        let now = std::time::Instant::now();
        let is_double = matches!(
            app.last_click,
            Some((prev, px, py, c))
                if px == x
                    && py == y
                    && c >= 1
                    && now.duration_since(prev) < std::time::Duration::from_millis(DOUBLE_CLICK_MAX_MS as u64)
        );
        app.last_click = Some((now, x, y, if is_double { 2 } else { 1 }));
        if is_double {
            app.equalize_splits();
            return;
        }
    }
    // Left-click on an editor's gutter → select the whole line.
    // Shift+gutter-click extends the selection down / up from
    // the anchor to that line. VS Code's line-numbers convention.
    // mouse-round-8 SEV-2 2026-07-11.
    if let Some(&(gr, pid)) = app
        .rects
        .editor_gutters
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let row_in_pane = (y - gr.y) as usize;
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            let line = b.scroll + row_in_pane;
            let clamped = line.min(b.editor.line_count().saturating_sub(1));
            let clip = &mut app.clipboard;
            let shift = m.modifiers.contains(KeyModifiers::SHIFT);
            // For shift+gutter-click: DON'T place_cursor first (it
            // wipes the anchor); jump the cursor byte directly.
            if shift && b.editor.selection().is_some() {
                let (_lo, hi) = b.editor.line_byte_range(clamped);
                b.editor.set_cursor_byte(hi);
            } else {
                // Non-shift path: place cursor at line start, then
                // fire SelectLineToEnd — matches Ctrl+L semantics.
                b.editor.place_cursor(clamped, 0);
                b.apply_edit_ops(vec![crate::edit_op::EditOp::SelectLineToEnd], clip, 0);
            }
        }
        return;
    }
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
                    && now.duration_since(prev)
                        < std::time::Duration::from_millis(DOUBLE_CLICK_MAX_MS as u64) =>
            {
                (c + 1).min(3)
            }
            _ => 1,
        };
        app.last_click = Some((now, x, y, count));
        // Ctrl+click → place cursor + fire `lsp.goto_definition`
        // (VS Code convention — "click through" identifiers).
        let ctrl_click = m.modifiers.contains(KeyModifiers::CONTROL);
        // Shift+click → extend the current selection to the click.
        // mouse-round-8 SEV-2 2026-07-11.
        let shift_click = m.modifiers.contains(KeyModifiers::SHIFT) && !ctrl_click;
        let wrap = app.config.ui.wrap;
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
            if shift_click {
                // Establish anchor at current cursor first (if not
                // already selecting), then extend cursor to click.
                // mouse-round-9 fix: was using place_cursor which
                // wipes the anchor immediately — use extend_cursor_to
                // for the click destination.
                let clip = &mut app.clipboard;
                if b.editor.selection().is_none() {
                    b.apply_edit_ops(vec![crate::edit_op::EditOp::SelectStart], clip, 0);
                }
                b.editor.extend_cursor_to(row, col);
            } else {
                b.editor.place_cursor(row, col);
                if count >= 2 {
                    let clip = &mut app.clipboard;
                    if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                        // mouse-round-8 SEV-3 2026-07-12 — triple-click
                        // in STANDARD mode fires SelectLineToEnd so
                        // typing replaces the whole line (matches
                        // VS Code / Sublime / GUI-editor convention).
                        // In vim mode, keep SelectLine (V-visual line)
                        // so muscle memory still yields the vim shape.
                        let op = if count == 2 {
                            crate::edit_op::EditOp::SelectWord
                        } else if b.editing_mode() == crate::input::EditingMode::None {
                            crate::edit_op::EditOp::SelectLineToEnd
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

#[cfg(test)]
mod plus_menu_tests {
    use super::*;
    use crate::config::Config;

    fn app() -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        (d, app)
    }

    fn labels(app: &App) -> Vec<String> {
        plus_menu_items(app).into_iter().map(|i| i.label).collect()
    }

    /// #1210 — the reported flow: close everything, click `+`, get
    /// back what you closed. The row is the whole point of the fix,
    /// and it must be FIRST so it's under the cursor when the menu
    /// opens.
    #[test]
    fn reopen_row_is_first_when_there_is_something_to_reopen() {
        let (_d, mut app) = app();
        app.closed_buffers
            .push((std::path::PathBuf::from("/tmp/a.txt"), 0, 0));
        app.closed_buffers
            .push((std::path::PathBuf::from("/tmp/b.txt"), 0, 0));
        let l = labels(&app);
        assert_eq!(
            l.first().map(String::as_str),
            Some("Reopen last closed (2)"),
            "menu was: {l:?}"
        );
    }

    /// Nothing closed ⇒ no row. An always-present entry that usually
    /// toasts "nothing to reopen" just trains people to skip it.
    #[test]
    fn reopen_row_absent_with_nothing_closed() {
        let (_d, app) = app();
        assert!(app.closed_buffers.is_empty(), "precondition");
        let l = labels(&app);
        assert!(
            !l.iter().any(|s| s.starts_with("Reopen last closed")),
            "menu was: {l:?}"
        );
    }

    /// Every command reachable from the menu, at any depth.
    ///
    /// Grouping moved rows into submenus, so a flat label check stopped
    /// meaning anything. This asks the question that actually matters —
    /// can the user still GET to it — and keeps meaning it if the
    /// grouping is rearranged again.
    fn reachable_commands(app: &App) -> Vec<String> {
        fn walk(items: &[crate::context_menu::MenuItem], out: &mut Vec<String>) {
            for it in items {
                if let crate::context_menu::MenuAction::Command(c) = &it.action {
                    out.push((*c).to_string());
                }
                if let Some(kids) = &it.submenu {
                    walk(kids, out);
                }
            }
        }
        let mut out = Vec::new();
        walk(&plus_menu_items(app), &mut out);
        out
    }

    /// The top-right `+` traded an immediate `tab_new` for this menu,
    /// so the action it used to perform has to still be reachable —
    /// otherwise the change is a straight regression for anyone with
    /// that click in muscle memory.
    #[test]
    fn new_tab_page_survives_the_move_to_a_menu() {
        let (_d, app) = app();
        let cmds = reachable_commands(&app);
        assert!(cmds.iter().any(|c| c == "tab.new"), "menu was: {cmds:?}");
    }

    /// Grouping must not silently drop anything. Every command the flat
    /// menu offered is still reachable at some depth.
    #[test]
    fn grouping_did_not_lose_a_single_command() {
        let (_d, app) = app();
        let cmds = reachable_commands(&app);
        for want in [
            "scratch.new",
            "scratch.from_clipboard",
            "picker.files",
            "picker.recent",
            "http.new",
            "term.shell",
            "browser.open",
            "files.open",
            "files.open_split",
            "ai.claude_code_new",
            "ai.codex_new",
            "tab.new",
            // The dock's rows, which the retired `+ dock` chip used to
            // be the only mouse route to.
            "dock.new_text",
            "dock.new_log_tail",
        ] {
            assert!(
                cmds.iter().any(|c| c == want),
                "{want} unreachable: {cmds:?}"
            );
        }
    }

    /// A parent row must never carry an action of its own — clicking it
    /// opens its child. If one ever gained a real action, the click
    /// would both open and fire, which is how a menu loses your trust.
    #[test]
    fn every_parent_row_is_inert_and_every_leaf_acts() {
        let (_d, app) = app();
        for it in plus_menu_items(&app) {
            if it.has_submenu() {
                assert!(
                    matches!(it.action, crate::context_menu::MenuAction::Submenu),
                    "parent row {:?} carries a real action",
                    it.label
                );
                assert!(
                    !it.submenu.as_ref().unwrap().is_empty(),
                    "parent row {:?} opens an empty menu — a dead click",
                    it.label
                );
            } else {
                assert!(
                    !matches!(it.action, crate::context_menu::MenuAction::Submenu),
                    "row {:?} is marked as a parent but has no children",
                    it.label
                );
            }
        }
    }

    /// Hiding a row must remove it wherever it lives, including inside a
    /// group — the whole point of curation is that the user does not have
    /// to know how the menu is organised.
    #[test]
    fn hiding_a_row_removes_it_from_inside_its_group() {
        let (_d, mut app) = app();
        assert!(
            reachable_commands(&app).iter().any(|c| c == "http.new"),
            "precondition"
        );
        app.config.ui.plus_menu_hidden = vec!["http.new".into()];
        assert!(
            !reachable_commands(&app).iter().any(|c| c == "http.new"),
            "hidden row survived: {:?}",
            reachable_commands(&app)
        );
    }

    /// Pinning floats a row OUT of its group to the top level. A pin that
    /// left the row where it was would be indistinguishable from doing
    /// nothing.
    #[test]
    fn pinning_lifts_a_row_out_of_its_group_to_the_top() {
        let (_d, mut app) = app();
        assert!(
            !labels(&app).iter().any(|l| l == "Shell"),
            "precondition: Shell starts inside the New group"
        );
        app.config.ui.plus_menu_pinned = vec!["term.shell".into()];
        let l = labels(&app);
        assert_eq!(
            l.first().map(String::as_str),
            Some("Shell"),
            "pinned row did not reach the top: {l:?}"
        );
    }

    /// Pins apply in the order the user pinned them, not the order the
    /// menu happens to list them.
    #[test]
    fn pins_keep_the_users_order() {
        let (_d, mut app) = app();
        app.config.ui.plus_menu_pinned = vec!["term.shell".into(), "scratch.new".into()];
        let l = labels(&app);
        assert_eq!(
            &l[..2],
            &["Shell".to_string(), "Scratch buffer".to_string()],
            "{l:?}"
        );
    }

    /// A group emptied by hiding or pinning must go too — a parent row
    /// whose `▸` opens nothing is a dead click.
    #[test]
    fn a_group_emptied_by_curation_disappears() {
        let (_d, mut app) = app();
        assert!(labels(&app).iter().any(|l| l == "AI"), "precondition");
        app.config.ui.plus_menu_hidden = vec!["ai.claude_code_new".into(), "ai.codex_new".into()];
        assert!(
            !labels(&app).iter().any(|l| l == "AI"),
            "an empty group survived: {:?}",
            labels(&app)
        );
    }

    /// Hiding something already pinned has to unpin it, or it stays on
    /// screen and the Hide row looks broken.
    ///
    /// `plus_menu_curate` PERSISTS, so this test redirects HOME to a
    /// tempdir first. Without that it writes to the developer's own
    /// `~/.config/mnml/config.toml` — which it did, once, and actually
    /// hid a row from their real `+` menu.
    #[test]
    fn hiding_a_pinned_row_also_unpins_it() {
        // `MNML_DATA_ROOT` is the established redirect for this — added
        // in #1041 after `cargo test` was found silently mutating the
        // developer's real `~/.config/mnml/config.toml` through exactly
        // this kind of persisted toggle. Without it this test writes a
        // real `plus_menu_hidden` entry and actually hides a row from
        // the developer's own `+` menu, which is what it did before this
        // line existed.
        let root = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _h = crate::EnvGuard::set("MNML_DATA_ROOT", root.path());
        let (_d, mut app) = app();

        app.plus_menu_curate("term.shell", crate::app::context_menus::PlusCuration::Pin);
        assert!(labels(&app).iter().any(|l| l == "Shell"), "precondition");
        app.plus_menu_curate("term.shell", crate::app::context_menus::PlusCuration::Hide);
        assert!(
            !labels(&app).iter().any(|l| l == "Shell"),
            "a hidden row stayed visible because it was still pinned: {:?}",
            labels(&app)
        );

        // And it must have gone to disk, under the redirected HOME. A
        // curation that reverts on restart is worse than none.
        let written = std::fs::read_to_string(root.path().join("config.toml"))
            .expect("nothing was persisted");
        assert!(
            written.contains("term.shell"),
            "curation did not reach the config file:\n{written}"
        );
    }

    /// The flat menu was ~15 rows and grew by one per enabled
    /// integration. Grouping is worth nothing if the top level creeps
    /// back up.
    #[test]
    fn the_top_level_stays_short() {
        let (_d, app) = app();
        let n = plus_menu_items(&app).len();
        assert!(n <= 7, "top level is back to {n} rows: {:?}", labels(&app));
    }
}
