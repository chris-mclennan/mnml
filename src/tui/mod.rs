//! The terminal frontend: raw-mode / alt-screen / mouse-capture setup, the
//! crossterm event loop, and the shared key/mouse dispatchers (`dispatch_key` /
//! `dispatch_mouse`) that the headless+IPC loop also calls — so headless behavior
//! matches the real UI.

pub mod chord;
pub mod handlers;
pub mod mouse;
pub use chord::{CHORD_CHAIN_TIMEOUT_MS, dispatch_chord_chain, tick_chord_chain};
use handlers::overlay::{
    handle_git_section_commit_key, handle_glyph_builder_key, handle_help_overlay_key,
    handle_integration_edit_key, handle_picker_key, handle_prompt_key, handle_search_section_key,
    handle_settings_overlay_key,
};
use handlers::pane::{handle_pane_key, handle_tree_key};
pub(crate) use mouse::coalesce_scroll;
pub use mouse::dispatch_mouse;

use std::io::{self, Stdout};
use std::time::Duration;

use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::cursor::SetCursorStyle;
use ratatui::crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind,
    KeyModifiers, KeyboardEnhancementFlags, PopKeyboardEnhancementFlags,
    PushKeyboardEnhancementFlags,
};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, SetTitle, disable_raw_mode, enable_raw_mode,
    supports_keyboard_enhancement,
};

use crate::app::App;
use crate::focus::Focus;
use crate::ipc::{self, Ipc};
use crate::pane::Pane;
use crate::ui;

/// Drain queued OS notifications from `app.pending_os_notifications`
/// and emit each as an OSC 9 + OSC 777 escape sequence (with an
/// optional BEL for sound). Ghostty / iTerm2 / kitty / WezTerm
/// route these to native OS notification banners; other
/// terminals silently consume the sequence.
fn emit_pending_os_notifications(
    app: &mut App,
    backend: &mut CrosstermBackend<Stdout>,
) -> io::Result<()> {
    use ratatui::crossterm::style::Print;
    for (title, body, sound) in app.take_pending_os_notifications() {
        // OSC 9 — the de facto standard used by iTerm2 (and now
        // Ghostty, WezTerm, kitty, Windows Terminal). Body-only.
        let osc9 = format!("\x1b]9;{title}: {body}\x07");
        // OSC 777 — xterm / gnome-terminal / older kitty format.
        // Takes title + body separately.
        let osc777 = format!("\x1b]777;notify;{title};{body}\x07");
        let bel = if sound { "\x07" } else { "" };
        let _ = execute!(backend, Print(osc9), Print(osc777), Print(bel));
    }
    Ok(())
}

/// Run the terminal UI. `Ok(true)` ⇒ exit for a rebuild+relaunch (the `run.sh`
/// wrapper watches for that); `Ok(false)` ⇒ normal quit.
pub fn run(mut app: App) -> Result<bool, String> {
    // Workspace basename for the terminal-window title — picks up the
    // current project name so multiple mnml tabs are distinguishable
    // ("mnml — mnml", "mnml — work", …).
    let title = match app.workspace.file_name().and_then(|s| s.to_str()) {
        Some(name) if !name.is_empty() => format!("mnml — {name}"),
        _ => "mnml".to_string(),
    };
    let mut term = setup_terminal(&title).map_err(|e| format!("terminal setup failed: {e}"))?;
    let result = run_loop(&mut term, &mut app);
    let _ = restore_terminal(&mut term);
    result
        .map(|()| app.restart_requested)
        .map_err(|e| format!("{e}"))
}

fn setup_terminal(title: &str) -> io::Result<Terminal<CrosstermBackend<Stdout>>> {
    enable_raw_mode()?;
    let mut out = io::stdout();
    if let Err(e) = execute!(
        out,
        EnterAlternateScreen,
        EnableMouseCapture,
        // Enable all-motion mouse events (?1003h) so hover-without-button
        // generates `MouseEventKind::Moved`. crossterm's `EnableMouseCapture`
        // only turns on button + drag tracking by default. Needed for the
        // statusline chip tooltips.
        ratatui::crossterm::style::Print("\x1b[?1003h"),
        SetCursorStyle::SteadyBar,
        // OSC 0/2 — sets the terminal window/tab title.
        SetTitle(title),
    ) {
        let _ = disable_raw_mode();
        return Err(e);
    }
    // Ask for the kitty keyboard protocol so chords the legacy encoding can't
    // express — `Ctrl+Shift+P`, `Ctrl+I` vs `Tab`, etc. — come through distinctly.
    // No-op on terminals that don't support it.
    if supports_keyboard_enhancement().unwrap_or(false) {
        let _ = execute!(
            out,
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
        );
    }
    Terminal::new(CrosstermBackend::new(out)).inspect_err(|_| {
        let _ = disable_raw_mode();
    })
}

fn restore_terminal(term: &mut Terminal<CrosstermBackend<Stdout>>) -> io::Result<()> {
    if supports_keyboard_enhancement().unwrap_or(false) {
        let _ = execute!(term.backend_mut(), PopKeyboardEnhancementFlags);
    }
    disable_raw_mode()?;
    execute!(
        term.backend_mut(),
        LeaveAlternateScreen,
        // Pair with the ?1003h we set in setup_terminal so the host terminal
        // returns to standard tracking.
        ratatui::crossterm::style::Print("\x1b[?1003l"),
        DisableMouseCapture,
        SetCursorStyle::DefaultUserShape
    )?;
    term.show_cursor()?;
    Ok(())
}

fn run_loop(term: &mut Terminal<CrosstermBackend<Stdout>>, app: &mut App) -> io::Result<()> {
    // The interactive loop also speaks the file-IPC channel (so `./run.sh restart`,
    // E2E driving, and "agent inspects the live UI" work against the real terminal,
    // not just headless). Best-effort: if the workspace fs is read-only, skip it.
    let mut ipc = Ipc::init(&app.workspace).ok();
    if let Some(ipc) = ipc.as_mut() {
        let (w, h) = term.size().map(|s| (s.width, s.height)).unwrap_or((0, 0));
        ipc.append_event(&format!(
            "{{\"event\":\"start\",\"mode\":\"tui\",\"cols\":{w},\"rows\":{h}}}"
        ));
    }

    app.run_startup_tasks();
    // Background now-playing poller for the statusline miniplayer —
    // real terminal loop only (headless / e2e skip it).
    app.start_now_playing_poller();

    loop {
        app.tick();
        // Chord-chain timeout — fires the pending fallback (if any)
        // when the user pauses past `CHORD_CHAIN_TIMEOUT_MS`. Must run
        // every frame regardless of redraw so a dangling prefix
        // doesn't sit forever after the user gives up.
        tick_chord_chain(app);
        if app.redraw_requested {
            app.redraw_requested = false;
            // Force a fresh paint over a cleared buffer (an external process
            // can leave the terminal in any state).
            term.clear()?;
        }
        term.draw(|f| ui::draw(f, app))?;
        emit_pending_os_notifications(app, term.backend_mut())?;
        crate::app::dispatch::emit_image_placements(app);
        if let Some(ipc) = ipc.as_mut() {
            ipc::dump_screen_status(ipc, term.current_buffer_mut(), app);
            ipc::drain_commands(ipc, app);
            ipc::drain_plugin_events(ipc, app);
        }
        if app.should_quit {
            app.save_session_on_quit();
            break;
        }
        // Poll faster while a pty is open so streaming output stays smooth.
        // DAP sessions also need fast polling so stopped/output events
        // surface promptly.
        let timeout = Duration::from_millis(
            if app.has_pty_pane() || app.has_pending_ai() || app.dap.is_some() {
                40
            } else {
                120
            },
        );
        if event::poll(timeout)? {
            match event::read()? {
                Event::Key(k) if k.kind != KeyEventKind::Release => dispatch_key(app, k),
                Event::Mouse(m) => {
                    // Wheel coalescing: when the read event is a
                    // ScrollUp/ScrollDown, drain every other
                    // immediately-available scroll event of the
                    // same direction from crossterm's queue, sum
                    // them, dispatch ONE batched scroll. Fixes
                    // post-release over-scroll — macOS produces
                    // 30+ events per spin; without this they queue
                    // and keep applying for ~2s after release.
                    if let Some(batched) = coalesce_scroll(&m)? {
                        dispatch_mouse(app, batched);
                    } else {
                        dispatch_mouse(app, m);
                    }
                    // code-reviewer W-2 2026-06-28: coalesce_scroll
                    // may have read a non-scroll event from the
                    // queue while looking for more wheel events.
                    // Drain the stash so the click/key isn't lost.
                    if let Some(leftover) = mouse::take_coalesce_leftover() {
                        match leftover {
                            Event::Key(k) if k.kind != KeyEventKind::Release => {
                                dispatch_key(app, k)
                            }
                            Event::Mouse(m) => dispatch_mouse(app, m),
                            _ => {}
                        }
                    }
                }
                Event::Resize(_, _) => {}
                _ => {}
            }
        }
    }

    if let Some(ipc) = ipc.as_mut() {
        term.draw(|f| ui::draw(f, app))?;
        ipc::dump_screen_status(ipc, term.current_buffer_mut(), app);
        ipc.append_event(if app.restart_requested {
            "{\"event\":\"exit\",\"restart\":true}"
        } else {
            "{\"event\":\"exit\"}"
        });
    }
    Ok(())
}

// T-2: coalesce_scroll + SCROLL_BATCH_COUNT + take_scroll_batch_count
// moved to src/tui/mouse.rs (re-exported above).

// ─── key dispatch (shared with headless/IPC) ────────────────────────

/// Translate a startup-picker selection into the corresponding command
/// or App method. Called from `dispatch_key` after the user commits.
fn fire_startup_action(action: crate::app::StartupPickerAction, app: &mut App) {
    use crate::app::StartupPickerAction::*;
    match action {
        NewFile => {
            crate::command::run("file.new", app);
        }
        OpenFile => {
            crate::command::run("view.discovery", app);
        }
        OpenFolder => {
            // Opens the AddWorkspace path prompt (`~/` is supported);
            // accepting it canonicalizes the path + adds it as an
            // extra workspace via `App::add_workspace_runtime`.
            crate::command::run("view.add_workspace", app);
        }
        SwitchWorkspace(idx) => {
            app.switch_workspace(idx);
        }
        OpenProject(path) => {
            // Same path as `view.add_workspace` once it has the
            // resolved path — registers the folder as an extra
            // workspace + switches focus to it.
            app.add_workspace_runtime(path, None);
        }
    }
}

/// Try to summon a menu via Alt+<letter> or F10. Returns true when a
/// menu was opened (caller should stop further key dispatch). Called
/// from `dispatch_key` only when no menu is currently open and the
/// `[ui] menu_bar` mode isn't `"hidden"`.
fn try_open_menu_from_key(app: &mut App, key: KeyEvent) -> bool {
    let menus = crate::menu_bar::bar();
    // F10 — open the first menu whose label is alphabetic
    // (skip the brand menu, whose label starts with a Nerd Font
    // glyph). Falls back to index 0 if no alphabetic menu exists.
    if key.code == KeyCode::F(10) && key.modifiers.is_empty() && !menus.is_empty() {
        let target = menus
            .iter()
            .position(|m| {
                m.label
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_alphabetic())
            })
            .unwrap_or(0);
        app.menu_open = Some(crate::menu_bar::MenuOpenState::new_keyboard(target));
        return true;
    }
    // Alt+<letter> — open the menu whose FIRST ALPHABETIC char
    // matches. For the brand menu (`>  mnml`), that's `m`; for
    // `File`, `f`; etc. Matching the first alpha char (instead of
    // strictly the first char) lets the brand menu have an Alt
    // shortcut too, despite leading with a non-alpha prompt mark.
    //
    // input-handler-reviewer 2026-06-29 SEV-2: must NOT match
    // Ctrl+Alt+<letter> — those are global chords (Ctrl+Alt+W
    // closes right-panel tab, etc.) that the chord layer claims.
    // `modifiers.contains(ALT)` is a subset check, so without the
    // explicit `!contains(CONTROL)` exclusion, Ctrl+Alt+W was
    // being consumed by the menu-bar accelerator (matching 'W' →
    // Window menu) before reaching dispatch_chord_chain.
    if key.modifiers.contains(KeyModifiers::ALT)
        && !key.modifiers.contains(KeyModifiers::CONTROL)
        && let KeyCode::Char(ch) = key.code
    {
        let ch_lower = ch.to_ascii_lowercase();
        if let Some((i, _)) = menus.iter().enumerate().find(|(_, m)| {
            m.label
                .chars()
                .find(|c| c.is_ascii_alphabetic())
                .is_some_and(|c| c.to_ascii_lowercase() == ch_lower)
        }) {
            app.menu_open = Some(crate::menu_bar::MenuOpenState::new_keyboard(i));
            return true;
        }
    }
    false
}

/// Handle a key while a menu dropdown is open. Returns true when the
/// key was consumed by the menu (caller should stop dispatch).
fn handle_menu_key(app: &mut App, key: KeyEvent) -> bool {
    let menus = crate::menu_bar::bar();
    let Some(open) = app.menu_open.as_ref().cloned() else {
        return false;
    };
    let Some(menu) = menus.get(open.menu_idx) else {
        return false;
    };
    match key.code {
        KeyCode::Esc => {
            app.menu_open = None;
            true
        }
        KeyCode::Left => {
            let n = menus.len();
            if n > 1 {
                let prev = (open.menu_idx + n - 1) % n;
                app.menu_open = Some(crate::menu_bar::MenuOpenState::new_keyboard(prev));
            }
            true
        }
        KeyCode::Right => {
            let n = menus.len();
            if n > 1 {
                let next = (open.menu_idx + 1) % n;
                app.menu_open = Some(crate::menu_bar::MenuOpenState::new_keyboard(next));
            }
            true
        }
        KeyCode::Up => {
            let n = menu.items.len();
            if n > 0 {
                // Skip past Separators by walking until we hit an
                // Action. `usize::MAX` (fresh-mouse-open) wraps to last.
                let start = if open.item_idx == usize::MAX {
                    n - 1
                } else {
                    (open.item_idx + n - 1) % n
                };
                let new_idx = walk_to_action(&menu.items, start, false);
                if let Some(s) = app.menu_open.as_mut() {
                    s.item_idx = new_idx;
                    s.keyboard_opened = true;
                }
            }
            true
        }
        KeyCode::Down => {
            let n = menu.items.len();
            if n > 0 {
                let start = if open.item_idx == usize::MAX {
                    0
                } else {
                    (open.item_idx + 1) % n
                };
                let new_idx = walk_to_action(&menu.items, start, true);
                if let Some(s) = app.menu_open.as_mut() {
                    s.item_idx = new_idx;
                    s.keyboard_opened = true;
                }
            }
            true
        }
        KeyCode::Enter => {
            if let Some(crate::menu_bar::MenuItem::Action { command_id, .. }) =
                menu.items.get(open.item_idx)
            {
                let id = *command_id;
                app.menu_open = None;
                crate::command::run(id, app);
            }
            true
        }
        _ => false,
    }
}

/// Walk through `items` starting at `start`, in the given direction
/// (`true` = forward, `false` = backward), returning the index of the
/// first Action found. Returns `start` if no Action exists.
fn walk_to_action(items: &[crate::menu_bar::MenuItem], start: usize, forward: bool) -> usize {
    let n = items.len();
    let mut idx = start;
    for _ in 0..n {
        if matches!(
            items.get(idx),
            Some(crate::menu_bar::MenuItem::Action { .. })
        ) {
            return idx;
        }
        idx = if forward {
            (idx + 1) % n
        } else {
            (idx + n - 1) % n
        };
    }
    start
}

pub fn dispatch_key(app: &mut App, key: KeyEvent) {
    // Any keystroke cancels a pending hover tooltip / divider highlight —
    // the user moved on to typing, the hover-cue is no longer relevant.
    app.hover_chip = None;
    app.hover_divider_idx = None;
    // Zen-mode escape hatch: when zen is on and no overlay is
    // claiming Esc, treat Esc as "exit zen" so the user is never
    // trapped. Overlays (picker / prompt / which-key) get first
    // dibs by returning before this check below.
    if app.zen_mode
        && key.code == KeyCode::Esc
        && app.picker.is_none()
        && app.prompt.is_none()
        && app.whichkey.is_none()
        && app.context_menu.is_none()
        && app.menu_open.is_none()
    {
        app.toggle_zen_mode();
        return;
    }
    // Workspace-picker dropdown — when open, intercept keys so they
    // navigate the picker (not the editor below).
    if app.workspace_picker_open {
        match key.code {
            KeyCode::Esc => {
                app.workspace_picker_open = false;
                app.workspace_picker_filter.clear();
                return;
            }
            KeyCode::Backspace => {
                app.workspace_picker_filter.pop();
                return;
            }
            KeyCode::Char(c)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                app.workspace_picker_filter.push(c);
                return;
            }
            _ => {}
        }
    }
    // Workspaces editor overlay — intercept keyboard so arrows
    // navigate, Enter edits, n adds, d deletes, Esc closes.
    if app.workspaces_editor_open && app.prompt.is_none() && app.context_menu.is_none() {
        let total = app.config.workspaces.len() + 1; // +1 for the "Add" action row
        match key.code {
            KeyCode::Esc => {
                app.close_workspaces_editor();
                return;
            }
            // Reorder (Shift+↑/↓ and `K`/`J`) MUST be matched
            // before the bare Up/Down arms below — otherwise the
            // unguarded ↑/↓ arms swallow the Shift variant.
            KeyCode::Up if key.modifiers.contains(KeyModifiers::SHIFT) => {
                let sel = app.workspaces_editor_selected;
                if sel < app.config.workspaces.len() {
                    app.workspaces_editor_move_up(sel);
                }
                return;
            }
            KeyCode::Down if key.modifiers.contains(KeyModifiers::SHIFT) => {
                let sel = app.workspaces_editor_selected;
                if sel < app.config.workspaces.len() {
                    app.workspaces_editor_move_down(sel);
                }
                return;
            }
            KeyCode::Char('K') => {
                let sel = app.workspaces_editor_selected;
                if sel < app.config.workspaces.len() {
                    app.workspaces_editor_move_up(sel);
                }
                return;
            }
            KeyCode::Char('J') => {
                let sel = app.workspaces_editor_selected;
                if sel < app.config.workspaces.len() {
                    app.workspaces_editor_move_down(sel);
                }
                return;
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if app.workspaces_editor_selected > 0 {
                    app.workspaces_editor_selected -= 1;
                } else {
                    app.workspaces_editor_selected = total.saturating_sub(1);
                }
                return;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                app.workspaces_editor_selected =
                    (app.workspaces_editor_selected + 1) % total.max(1);
                return;
            }
            KeyCode::Enter => {
                let sel = app.workspaces_editor_selected;
                if sel < app.config.workspaces.len() {
                    app.workspaces_editor_open_rename(sel);
                } else {
                    // + Add row.
                    crate::command::run("view.add_workspace", app);
                }
                return;
            }
            KeyCode::Char('n') => {
                crate::command::run("view.add_workspace", app);
                return;
            }
            KeyCode::Char('d') => {
                let sel = app.workspaces_editor_selected;
                if sel < app.config.workspaces.len() {
                    app.workspaces_editor_delete(sel);
                }
                return;
            }
            _ => {}
        }
    }
    // Dock widget kebab menu — when open, intercept keys so they
    // navigate the menu rather than falling through to editor /
    // tree handlers.
    if app.dock_kebab_menu.is_some() {
        let menu = app.dock_kebab_menu.as_ref().unwrap();
        let items_len = menu.items.len();
        match key.code {
            KeyCode::Esc => {
                app.dock_kebab_menu = None;
                return;
            }
            KeyCode::Down | KeyCode::Tab => {
                if let Some(m) = app.dock_kebab_menu.as_mut() {
                    let mut i = m.selected;
                    for _ in 0..items_len {
                        i = (i + 1) % items_len;
                        if matches!(
                            m.items[i],
                            crate::dock::KebabMenuItem::Header(_)
                                | crate::dock::KebabMenuItem::Separator
                        ) {
                            continue;
                        }
                        break;
                    }
                    m.selected = i;
                }
                return;
            }
            KeyCode::Up | KeyCode::BackTab => {
                if let Some(m) = app.dock_kebab_menu.as_mut() {
                    let mut i = m.selected;
                    for _ in 0..items_len {
                        i = if i == 0 { items_len - 1 } else { i - 1 };
                        if matches!(
                            m.items[i],
                            crate::dock::KebabMenuItem::Header(_)
                                | crate::dock::KebabMenuItem::Separator
                        ) {
                            continue;
                        }
                        break;
                    }
                    m.selected = i;
                }
                return;
            }
            KeyCode::Enter => {
                let (wid, item) = {
                    let m = app.dock_kebab_menu.as_ref().unwrap();
                    (m.widget_id, m.items.get(m.selected).copied())
                };
                if let Some(item) = item {
                    crate::dock::apply_kebab_choice(app, wid, item);
                }
                return;
            }
            _ => {}
        }
    }
    // Integrations rail filter — explicit focus (was auto-focused,
    // but that stole `:` / palette shortcuts / any global char while
    // the section was open; kept accreting gates for every collision
    // until 2026-07-04 flipped it to explicit). Focus is set by
    // pressing `/` in the panel or clicking the filter chip.
    if app.focus == crate::focus::Focus::Tree
        && app.active_section == crate::app::ActivitySection::Integrations
        && app.picker.is_none()
        && app.integration_edit.is_none()
    {
        // Not-yet-focused: `/` enters filter mode (matches vim /
        // less search idiom). All other chars flow through so
        // global shortcuts still fire from the panel.
        if !app.integrations_panel_filter_focused {
            if let KeyCode::Char('/') = key.code
                && !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
            {
                app.integrations_panel_filter_focused = true;
                return;
            }
        } else {
            // Focused: chars append, Backspace pops, Esc clears +
            // unfocuses, Enter commits + unfocuses.
            match key.code {
                KeyCode::Esc => {
                    app.integrations_panel_filter.clear();
                    app.integrations_panel_filter_focused = false;
                    return;
                }
                KeyCode::Enter => {
                    app.integrations_panel_filter_focused = false;
                    return;
                }
                KeyCode::Backspace => {
                    app.integrations_panel_filter.pop();
                    return;
                }
                KeyCode::Char(c)
                    if !key
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    app.integrations_panel_filter.push(c);
                    return;
                }
                _ => {}
            }
        }
    }
    // Agents rail filter — when focused, intercept typing /
    // backspace / Esc.
    if app.agents_panel_filter_focused {
        match key.code {
            KeyCode::Esc => {
                app.agents_panel_filter.clear();
                app.agents_panel_filter_focused = false;
                return;
            }
            KeyCode::Backspace => {
                app.agents_panel_filter.pop();
                return;
            }
            KeyCode::Enter => {
                app.agents_panel_filter_focused = false;
                return;
            }
            KeyCode::Char(c)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                app.agents_panel_filter.push(c);
                return;
            }
            _ => {}
        }
    }
    // Cloud Agents quick-fire prompt input (hybrid UX — daily-driver
    // path that uses the saved [cloud_run.defaults]).
    if app.cloud_run_prompt_focused {
        match key.code {
            KeyCode::Esc => {
                app.cloud_run_prompt_input.clear();
                app.cloud_run_prompt_focused = false;
                return;
            }
            KeyCode::Backspace => {
                app.cloud_run_prompt_input.pop();
                return;
            }
            KeyCode::Enter => {
                app.cloud_run_quick_send();
                return;
            }
            KeyCode::Char(c)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                app.cloud_run_prompt_input.push(c);
                return;
            }
            _ => {}
        }
    }
    // Same idiom for the Cloud Agents panel filter.
    if app.cloud_agents_filter_focused {
        match key.code {
            KeyCode::Esc => {
                app.cloud_agents_filter.clear();
                app.cloud_agents_filter_focused = false;
                return;
            }
            KeyCode::Backspace => {
                app.cloud_agents_filter.pop();
                return;
            }
            KeyCode::Enter => {
                app.cloud_agents_filter_focused = false;
                return;
            }
            KeyCode::Char(c)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                app.cloud_agents_filter.push(c);
                return;
            }
            _ => {}
        }
    }
    // NewCloudRunWizard (Cloud Agents version) keys.
    if app
        .active
        .and_then(|i| app.panes.get(i))
        .map(|p| matches!(p, crate::pane::Pane::NewCloudRunWizard(_)))
        .unwrap_or(false)
    {
        match key.code {
            KeyCode::Esc => {
                app.new_cloud_run_wizard_close();
                return;
            }
            KeyCode::Up | KeyCode::Char('k') => {
                app.new_cloud_run_wizard_move(-1);
                return;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                app.new_cloud_run_wizard_move(1);
                return;
            }
            KeyCode::Backspace => {
                app.new_cloud_run_wizard_backspace();
                return;
            }
            KeyCode::Tab | KeyCode::Enter => {
                app.new_cloud_run_wizard_next();
                return;
            }
            KeyCode::Char(ch)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                app.new_cloud_run_wizard_type(ch);
                return;
            }
            _ => {}
        }
    }
    // NewCloudAgentWizard pane — when active, intercept arrows,
    // Tab, Enter, Esc, and typing so the keys don't fall through
    // to the editor underneath.
    if app
        .active
        .and_then(|i| app.panes.get(i))
        .map(|p| matches!(p, crate::pane::Pane::NewCloudAgentWizard(_)))
        .unwrap_or(false)
    {
        match key.code {
            KeyCode::Esc => {
                app.new_cloud_agent_wizard_close();
                return;
            }
            KeyCode::Up | KeyCode::Char('k') => {
                app.new_cloud_agent_wizard_move(-1);
                return;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                app.new_cloud_agent_wizard_move(1);
                return;
            }
            KeyCode::Backspace => {
                app.new_cloud_agent_wizard_backspace();
                return;
            }
            KeyCode::Tab => {
                app.new_cloud_agent_wizard_next();
                return;
            }
            KeyCode::Enter => {
                app.new_cloud_agent_wizard_next();
                return;
            }
            KeyCode::Char(' ') => {
                app.new_cloud_agent_wizard_toggle();
                return;
            }
            KeyCode::Char('a') => {
                app.new_cloud_agent_wizard_select_all();
                return;
            }
            KeyCode::Char(ch)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                app.new_cloud_agent_wizard_type(ch);
                return;
            }
            _ => {}
        }
    }
    // Git-palette filter input — when focused, intercept typing /
    // backspace / Esc here so the keys don't fall through to the
    // editor.
    if app.git_palette_filter_focused {
        match key.code {
            KeyCode::Esc => {
                app.git_palette_filter.clear();
                app.git_palette_filter_focused = false;
                return;
            }
            KeyCode::Backspace => {
                app.git_palette_filter.pop();
                return;
            }
            KeyCode::Enter => {
                app.git_palette_filter_focused = false;
                return;
            }
            KeyCode::Char(c)
                if !key
                    .modifiers
                    .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
            {
                app.git_palette_filter.push(c);
                return;
            }
            _ => {}
        }
    }
    // Menu-bar dropdown — intercept keys before anything else so
    // Esc / arrows / Enter target the menu instead of the editor.
    if app.menu_open.is_some() && handle_menu_key(app, key) {
        return;
    }
    // Menu summon — Alt+letter opens the corresponding menu,
    // F10 opens the first menu. Gated by menu_bar mode != "hidden".
    if app.menu_open.is_none()
        && app.config.ui.menu_bar != "hidden"
        && try_open_menu_from_key(app, key)
    {
        return;
    }
    // 2026-06-22 — Esc during an in-flight tree-file drag aborts
    // the drag: clears tree_drag + the drop-zone overlay. User
    // can release the mouse anywhere safely after that without
    // triggering drag-to-split. Matches the VS Code / macOS
    // convention of Esc-cancels-drag.
    if key.code == KeyCode::Esc && app.tree_drag.is_some() {
        app.tree_drag = None;
        app.rects.tab_drop_target = None;
        return;
    }
    // AI ghost-text: while a suggestion is showing, bare `Tab` accepts
    // all of it, `Ctrl+Right` accepts the next word, `Ctrl+Down` the
    // next line (both leave the remainder as a ghost); any other key
    // dismisses it (and then does its normal thing).
    if app.has_ghost_suggestion() {
        if key.code == KeyCode::Tab && key.modifiers.is_empty() {
            app.accept_ghost_suggestion();
            return;
        }
        if key.code == KeyCode::Right && key.modifiers == KeyModifiers::CONTROL {
            app.accept_ghost_word();
            return;
        }
        if key.code == KeyCode::Down && key.modifiers == KeyModifiers::CONTROL {
            app.accept_ghost_line();
            return;
        }
        app.clear_ghost_suggestion();
    }
    // 2026-06-08 vscode hunt SEV-2: `Ctrl+S` (Save) is a global
    // muscle-memory reflex — VS Code fires it from any focus. mnml
    // used to swallow it inside every overlay (palette, prompts,
    // settings) which led to silent data loss: "find something,
    // hit Ctrl+S to checkpoint, keep going" left the file dirty
    // with no toast, no error. Intercept here before any
    // overlay-consuming branch runs. Overlay state is untouched —
    // save fires, the user keeps doing whatever they were doing.
    // Skip when a pty pane has the focus (the shell legitimately
    // wants `Ctrl+S` for XOFF flow control); the keymap below
    // handles the not-in-overlay case the same way it did before.
    if key.code == KeyCode::Char('s')
        && key.modifiers == KeyModifiers::CONTROL
        && !matches!(
            app.active.and_then(|i| app.panes.get(i)),
            Some(Pane::Pty(_))
        )
    {
        // Anything in flight that would have consumed the chord
        // (palette / prompt / settings) is still alive afterwards;
        // we just don't let it eat the save.
        app.save_active();
        return;
    }
    // Scratch terminal — when focused, route keystrokes to the pty
    // (with Esc as the way out). The chord that toggles it (`term.
    // scratch_toggle`) still works as the close gesture because the
    // command resolver runs against the keymap below — but only when
    // the scratch term isn't focused.
    if let Some(scratch) = app.scratch_term.as_mut()
        && scratch.focused
    {
        if key.code == KeyCode::Esc {
            scratch.focused = false;
            return;
        }
        let bytes = crate::app::dispatch::pty_key_bytes(key);
        if !bytes.is_empty() {
            scratch.session.write_bytes(&bytes);
        }
        return;
    }
    // Native mixr panel — when focused, route *every* key (incl. Esc,
    // which mixr uses for back-navigation) to mixr over the wire.
    // Startup picker intercept — when the launch-time chooser is up,
    // it owns the keyboard. Esc / q dismisses; arrows + digits move /
    // commit; everything else is swallowed so it doesn't leak through
    // to the underlying editor.
    if app.startup_picker.is_some() {
        match key.code {
            KeyCode::Esc | KeyCode::Char('q') => {
                app.dismiss_startup_picker();
            }
            KeyCode::Up | KeyCode::Char('k') => {
                app.startup_picker_move(-1);
            }
            KeyCode::Down | KeyCode::Char('j') => {
                app.startup_picker_move(1);
            }
            KeyCode::Enter => {
                if let Some(action) = app.startup_picker_commit() {
                    fire_startup_action(action, app);
                }
            }
            KeyCode::Char(c) if c.is_ascii_digit() && c != '0' => {
                if let Some(action) = app.startup_picker_press_digit(c) {
                    fire_startup_action(action, app);
                }
            }
            _ => {}
        }
        return;
    }
    // Macro recording — capture every keystroke that flows through here.
    // Replaying explicitly skips this so it doesn't re-record into a new
    // macro mid-replay.
    if let crate::app::MacroState::Recording { keys, .. } = &mut app.macro_state {
        keys.push(key);
    }
    // Esc dismisses any visible toast (visual fluff the user explicitly
    // said "go away" to). Doesn't return — other Esc handlers further
    // down still fire (e.g. exit overlays, leave visual mode).
    if key.code == KeyCode::Esc {
        app.toast = None;
        app.toast_stack.clear();
        // F1 discovery overlay closes on Esc too — same dismiss gesture as
        // tooltips/toasts.
        app.show_discovery_overlay = false;
        // Welcome overlay also dismisses on Esc (and persists the marker
        // so it doesn't auto-reopen next launch).
        if app.show_welcome {
            app.dismiss_welcome();
        }
        app.show_about = false;
    }
    // Flash intercept: when label overlay is up, Esc cancels; a printable
    // char matching a label commits the jump; an unmatched key cancels
    // and falls through to normal dispatch.
    if app.flash_state.is_some() {
        if key.code == KeyCode::Esc {
            app.flash_cancel();
            return;
        }
        if let KeyCode::Char(c) = key.code
            && app.flash_consume_char(c)
        {
            return;
        }
        // No match — drop state and re-dispatch the keystroke normally.
        app.flash_cancel();
    }
    // The settings overlay steals all keys until it's saved (Enter) or
    // cancelled (Esc). Keyboard-only — see CLAUDE.md's "Family settings
    // UI convention".
    if app.settings_overlay.is_some() {
        handle_settings_overlay_key(app, key);
        return;
    }
    // An open picker / palette overlay steals all keys until it's
    // dismissed. Checked BEFORE the integration-edit panel so Ctrl+G
    // from inside the edit panel (which opens the glyph picker on
    // top) routes subsequent keys to the picker's filter input,
    // not back into the Glyph field char-by-char.
    if app.picker.is_some() {
        handle_picker_key(app, key);
        return;
    }
    // Integration edit panel — all-keys-stolen while open; Enter
    // saves, Esc cancels, Tab cycles fields, ←→ cycles color, other
    // chars type into the focused text field.
    // Glyph builder is checked BEFORE integration_edit because when
    // both are open (edit panel → glyph action menu → builder), the
    // builder is the visual front layer. Reverse order made Esc
    // close the edit panel first (behind) then the builder — user
    // saw two Escs to close what they expected to be one.
    if app.glyph_builder.is_some() {
        handle_glyph_builder_key(app, key);
        return;
    }
    if app.integration_edit.is_some() {
        handle_integration_edit_key(app, key);
        return;
    }
    // Search activity-bar section: input focused → printable keys
    // append to the query, Backspace deletes, Enter runs the grep,
    // ↑↓ navigates results, Esc blurs.
    if app.search_input_focused {
        handle_search_section_key(app, key);
        return;
    }
    // Git activity-bar section: commit textarea focused → printables
    // append to the buffer, Backspace deletes, Ctrl+Enter commits,
    // Esc blurs.
    if app.git_section_commit_focused {
        handle_git_section_commit_key(app, key);
        return;
    }
    // Help overlay — scroll + dismiss. No editing.
    if app.help_overlay.is_some() {
        handle_help_overlay_key(app, key);
        return;
    }
    // The LSP signature-help popup: Esc dismisses; Up / Down cycle through
    // overload signatures (only when there's more than one — otherwise the
    // arrow keys still navigate the editor). Any other key falls through (we
    // want typing to continue updating the popup, not dismiss it). Cursor
    // jumps via commands clear the popup separately.
    if let Some(sig) = app.signature.as_mut() {
        match key.code {
            KeyCode::Esc => {
                app.signature = None;
                return;
            }
            KeyCode::Down if sig.signatures.len() > 1 => {
                sig.cycle();
                return;
            }
            KeyCode::Up if sig.signatures.len() > 1 => {
                sig.cycle_prev();
                return;
            }
            _ => {}
        }
    }
    // Peek-definition overlay — Esc closes; arrows / j / k / PgUp /
    // PgDn scroll within the box; anything else closes + falls
    // through to normal handling.
    if app.peek_overlay.is_some() {
        match key.code {
            KeyCode::Esc => {
                app.peek_overlay = None;
                return;
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(po) = &mut app.peek_overlay {
                    po.scroll_up();
                }
                return;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(po) = &mut app.peek_overlay {
                    po.scroll_down();
                }
                return;
            }
            KeyCode::PageUp => {
                if let Some(po) = &mut app.peek_overlay {
                    for _ in 0..5 {
                        po.scroll_up();
                    }
                }
                return;
            }
            KeyCode::PageDown => {
                if let Some(po) = &mut app.peek_overlay {
                    for _ in 0..5 {
                        po.scroll_down();
                    }
                }
                return;
            }
            _ => {
                // 2026-06-21 lsp-cheat-test SEV-2: was falling
                // through to the editor, so in vim mode pressing
                // `x` to dismiss the overlay also deleted the
                // char under cursor. Now: close + EAT the
                // keystroke. User can re-issue if they actually
                // wanted to do something with it.
                app.peek_overlay = None;
                return;
            }
        }
    }
    // An LSP hover popup is up: arrows / j / k / PgUp / PgDn scroll it; Esc
    // closes it; anything else closes it and is then handled normally.
    if app.hover.is_some() {
        match key.code {
            KeyCode::Esc => {
                app.hover = None;
                return;
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(h) = &mut app.hover {
                    h.scroll_by(-1);
                }
                return;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(h) = &mut app.hover {
                    h.scroll_by(1);
                }
                return;
            }
            KeyCode::PageUp => {
                if let Some(h) = &mut app.hover {
                    h.scroll_by(-6);
                }
                return;
            }
            KeyCode::PageDown => {
                if let Some(h) = &mut app.hover {
                    h.scroll_by(6);
                }
                return;
            }
            _ => app.hover = None, // fall through to normal handling
        }
    }
    // An as-you-type LSP completion popup is up: arrows / Ctrl+N·P move the
    // selection, Tab / Enter accept, Esc dismisses it; identifier keys (and `.`,
    // `:`, Backspace) fall through to the editor — the resulting edit re-filters
    // it (`App::completion_on_edit`); anything else dismisses it and is handled
    // normally.
    if app.completion.is_some() {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Esc => {
                app.completion = None;
                return;
            }
            KeyCode::Tab | KeyCode::Enter => {
                // While a snippet placeholder cycle is active, Tab / Shift+Tab
                // navigate placeholders (dismissing this popup) instead of
                // accepting a completion — otherwise an as-you-type popup that
                // happened to be open races with the snippet's Tab and steals
                // it (the flaky-on-CI snippet failures). Enter still accepts.
                // SHIFT modifier honoured so Shift+Tab retreats rather than
                // inadvertently advancing forward (latent bug surfaced by the
                // 2026-06-26 review of the flake).
                if key.code == KeyCode::Tab && app.snippet_session.is_some() {
                    app.completion = None;
                    if key.modifiers.contains(KeyModifiers::SHIFT) {
                        app.snippet_prev_placeholder();
                    } else {
                        app.snippet_next_placeholder();
                    }
                } else {
                    app.completion_accept();
                }
                return;
            }
            KeyCode::Up => {
                app.completion_move(-1);
                return;
            }
            KeyCode::Down => {
                app.completion_move(1);
                return;
            }
            KeyCode::Char('p') if ctrl => {
                app.completion_move(-1);
                return;
            }
            KeyCode::Char('n') if ctrl => {
                app.completion_move(1);
                return;
            }
            // Ctrl+K / Ctrl+J — vim-style alternates for Up / Down.
            KeyCode::Char('k') if ctrl => {
                app.completion_move(-1);
                return;
            }
            KeyCode::Char('j') if ctrl => {
                app.completion_move(1);
                return;
            }
            KeyCode::PageUp => {
                app.completion_move(-8);
                return;
            }
            KeyCode::PageDown => {
                app.completion_move(8);
                return;
            }
            KeyCode::Char(c)
                if !ctrl && (c.is_alphanumeric() || c == '_' || c == '.' || c == ':') => {}
            KeyCode::Backspace => {}
            _ => app.completion = None, // fall through, handled normally
        }
    }
    // A snippet placeholder cycle is active: Tab jumps forward to the next
    // `$N` / `$0` stop; Shift-Tab walks back to the previous stop; Esc
    // dismisses. Anything else falls through (typing, arrows, etc. all work
    // normally — the session just tracks length deltas so the next Tab
    // targets the right spot).
    if app.snippet_session.is_some() {
        match key.code {
            // Shift+Tab (some terminals only synthesize BackTab; kitty etc.
            // send Tab+Shift) → previous placeholder.
            KeyCode::Tab if key.modifiers.contains(KeyModifiers::SHIFT) => {
                app.snippet_prev_placeholder();
                return;
            }
            KeyCode::Tab => {
                app.snippet_next_placeholder();
                return;
            }
            KeyCode::BackTab => {
                app.snippet_prev_placeholder();
                return;
            }
            KeyCode::Esc => {
                app.snippet_session = None;
                return;
            }
            _ => {} // fall through, handled normally
        }
    }
    // The right-click context menu steals keys: ↑↓/jk move, Enter runs, Esc closes.
    if app.context_menu.is_some() {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => app.context_menu_move(-1),
            KeyCode::Down | KeyCode::Char('j') => app.context_menu_move(1),
            KeyCode::Enter => app.context_menu_accept(),
            KeyCode::Esc => app.context_menu_cancel(),
            _ => {} // keep the menu up
        }
        return;
    }
    // The interactive replace overlay (`:%s/.../.../c`) steals keys:
    // y = replace this, n = skip, a = replace all remaining, q/Esc = quit.
    // Per-match cursor jump is handled by App; we just route the key.
    if app.replace_confirm.is_some() {
        match key.code {
            KeyCode::Char('y' | 'Y') => app.replace_confirm_yes(),
            KeyCode::Char('n' | 'N') => app.replace_confirm_no(),
            KeyCode::Char('a' | 'A') => app.replace_confirm_all(),
            KeyCode::Char('q' | 'Q') | KeyCode::Esc => app.replace_confirm_quit(),
            _ => {}
        }
        return;
    }
    // The "unsaved changes" confirm overlay steals keys: s/Enter = Save, d = Discard, c/Esc = Cancel.
    if app.close_prompt.is_some() {
        match key.code {
            KeyCode::Char('s' | 'S') | KeyCode::Enter => app.close_prompt_resolve(0),
            KeyCode::Char('d' | 'D') => app.close_prompt_resolve(1),
            KeyCode::Char('c' | 'C') | KeyCode::Esc => app.close_prompt_resolve(2),
            _ => {}
        }
        return;
    }
    // The single-line text-input overlay (commit message, …) steals keys.
    if app.prompt.is_some() {
        handle_prompt_key(app, key);
        return;
    }
    // A leader sequence in flight: walk the which-key trie until a leaf / dead end / Esc.
    if app.whichkey.is_some() {
        match key.code {
            KeyCode::Esc => app.whichkey_cancel(),
            KeyCode::Backspace => app.whichkey_cancel(),
            KeyCode::Char(c) => app.whichkey_feed(c),
            _ => {} // other keys: keep the popup up
        }
        return;
    }

    // Esc aborts an in-flight chord-chain pending WITHOUT firing the
    // inner fallback. Vim's convention — without this, `ctrl+k` then
    // Esc would still commit to `whichkey.leader` via the timeout
    // fallback, defeating the purpose of an abort.
    if matches!(key.code, KeyCode::Esc) && !app.pending_chord_seq.is_empty() {
        app.pending_chord_seq.clear();
        app.pending_chord_deadline = None;
        app.pending_chord_fallback = None;
        return;
    }

    // 2026-06-20 — Esc on bare focus with in-flight HTTP work
    // aborts. Runs AFTER overlay/cmdline gates so it doesn't
    // steal Esc from picker / prompt / cmdline cancellation,
    // but BEFORE the pane-focused handlers so users don't lose
    // the chord to a deeper handler. Idempotent — also fine if
    // no work is in flight.
    if matches!(key.code, KeyCode::Esc)
        && app.picker.is_none()
        && app.prompt.is_none()
        && app.context_menu.is_none()
        && app.no_pane_cmdline.is_none()
        && (app.http_bench_rx.is_some()
            || app.http_sync_rx.is_some()
            || app.lookup_fire_rx.is_some())
    {
        app.http_abort_all();
        return;
    }

    // App-level chords (any focus) resolve through the one keymap table — registry
    // defaults overlaid with `[keys.*]` config. These win over the focused pane;
    // all built-in defaults are modified/F-keys the editor doesn't want anyway.
    //
    // Chord-chain aware: feeds the key into the pending sequence and dispatches
    // based on the resolve_seq result. See `dispatch_chord_chain` for the full
    // state machine. Returns true if the key was consumed (no fall-through);
    // false if it wasn't (fall through to the focused handler).
    // Ctrl+; → open the ex-cmdline regardless of focus, input mode,
    // or any pending chord-chain state. Sits ABOVE dispatch_chord_chain
    // because a half-typed leader sequence in editor focus would
    // otherwise push this key onto pending_chord_seq and either fire
    // a multi-key chord or leave the cmdline open silently swallowed.
    // User-reported 2026-06-18 that Ctrl+; worked in tree focus but
    // failed in pane focus — symptom of a leader chord left dangling
    // in the pane's interaction.
    if key.code == KeyCode::Char(';') && key.modifiers.contains(KeyModifiers::CONTROL) {
        // Clear any in-flight chord chain — fresh chord, fresh state.
        app.pending_chord_seq.clear();
        app.pending_chord_deadline = None;
        app.pending_chord_fallback = None;
        if app.no_pane_cmdline.is_none() {
            app.open_ex_command_prompt();
        }
        return;
    }

    // 2026-06-19 — Ctrl+] / Ctrl+[ in a Request pane's Edit view
    // cycle the tab strip (Body/Headers/Params/Vars/Source). In
    // standard input mode, the global chord chain binds these to
    // editor.indent_line / outdent_line, which would otherwise
    // swallow them. Intercept first when we're on a Request pane
    // in Edit view so tab cycling works in both input modes.
    // api-workflow third hunt SEV-2.
    if matches!(key.code, KeyCode::Char(']') | KeyCode::Char('['))
        && key.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(app.focus, Focus::Pane)
        && let Some(cur) = app.active
        && let Some(Pane::Request(rp)) = app.panes.get_mut(cur)
        && rp.view == crate::request_pane::ViewMode::Edit
    {
        rp.edit_tab = if key.code == KeyCode::Char(']') {
            rp.edit_tab.next()
        } else {
            rp.edit_tab.prev()
        };
        // When jumping to the Source tab, focus the Source field
        // so the user can immediately type. When leaving Source,
        // restore URL focus (the natural default for the other
        // tabs).
        if rp.edit_tab == crate::request_pane::EditTab::Source {
            rp.focus = crate::request_pane::EditField::Source;
        } else if rp.focus == crate::request_pane::EditField::Source {
            rp.focus = crate::request_pane::EditField::Url;
        }
        return;
    }
    // 2026-06-19 — keyboard hunt SEV-2: Ctrl+1..5 jumps directly
    // to the matching Edit-view tab. Same Request-pane-only gate as
    // Ctrl+]/Ctrl+[. Same standard-mode chord-chain bypass needed
    // for the same reason.
    if key.modifiers.contains(KeyModifiers::CONTROL)
        && matches!(
            key.code,
            KeyCode::Char('1')
                | KeyCode::Char('2')
                | KeyCode::Char('3')
                | KeyCode::Char('4')
                | KeyCode::Char('5')
                | KeyCode::Char('6')
        )
        && matches!(app.focus, Focus::Pane)
        && let Some(cur) = app.active
        && let Some(Pane::Request(rp)) = app.panes.get_mut(cur)
        && rp.view == crate::request_pane::ViewMode::Edit
    {
        use crate::request_pane::EditTab;
        rp.edit_tab = match key.code {
            KeyCode::Char('1') => EditTab::Body,
            KeyCode::Char('2') => EditTab::Headers,
            KeyCode::Char('3') => EditTab::Params,
            KeyCode::Char('4') => EditTab::Auth,
            KeyCode::Char('5') => EditTab::Vars,
            KeyCode::Char('6') => EditTab::Source,
            _ => rp.edit_tab,
        };
        if rp.edit_tab == EditTab::Source {
            rp.focus = crate::request_pane::EditField::Source;
        } else if rp.focus == crate::request_pane::EditField::Source {
            rp.focus = crate::request_pane::EditField::Url;
        }
        return;
    }

    // vscode-user-keyboard SEV-2: when the chord chain bottoms out
    // and fires its fallback (typically `whichkey.leader`), the
    // current key was being dropped instead of fed into the just-
    // opened whichkey overlay — making `<leader>tr` need three
    // keys (`Ctrl+K t t r`) instead of two. Now: if whichkey was
    // NOT open before chord-dispatch but IS open after, re-route
    // the current key to the overlay's char-feed.
    let whichkey_was_open = app.whichkey.is_some();
    if dispatch_chord_chain(app, key) {
        return;
    }
    if !whichkey_was_open
        && app.whichkey.is_some()
        && let KeyCode::Char(c) = key.code
    {
        app.whichkey_feed(c);
        return;
    }

    // When the no-pane cmdline is open, it owns every keystroke
    // regardless of which side of the focus boundary the user
    // started typing from. Without this gate a pane-focused user
    // who hit Ctrl+; would land in the cmdline visually but their
    // typing would still go to the editor.
    if app.no_pane_cmdline.is_some() {
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        match key.code {
            KeyCode::Esc => app.no_pane_cmdline_cancel(),
            // Enter runs whatever is currently in the cmdline.
            // 2026-06-19 — earlier impl auto-substituted the
            // popup match, but that breaks legitimate vim
            // abbreviations (`:reg`, `:wq`, …). Users wanting
            // the popup match use Tab/click first to put it
            // into the line.
            KeyCode::Enter => {
                // 2026-06-24 — if the user has navigated the popup
                // with ↑/↓/Tab (selected index != 0), accept the
                // highlighted match before committing. Index 0 is
                // the auto-selected first match — leaving it
                // unaccepted preserves the vim convention where
                // `:reg<Enter>` fires the literal `:reg` instead
                // of whatever `:registers`/etc. matched first.
                if app.cmdline_popup_is_showing() && app.cmdline_popup_selected > 0 {
                    app.cmdline_popup_accept_current();
                }
                app.no_pane_cmdline_commit();
            }
            KeyCode::Backspace => app.no_pane_cmdline_backspace(),
            // 2026-06-19 — popup nav. Tab / Down advance the
            // highlighted match; Shift+Tab / Up retreat. Rewrites
            // the cmdline to the new selection so Enter fires
            // whatever's highlighted. No-op when popup isn't
            // showing (compute returns <2 matches).
            KeyCode::Tab if shift => app.cmdline_popup_move(-1),
            KeyCode::Tab => app.cmdline_popup_move(1),
            KeyCode::Down => app.cmdline_popup_move(1),
            KeyCode::Up => app.cmdline_popup_move(-1),
            KeyCode::PageDown => app.cmdline_popup_move(8),
            KeyCode::PageUp => app.cmdline_popup_move(-8),
            KeyCode::Home => app.cmdline_popup_move_to(0),
            KeyCode::End => app.cmdline_popup_move_to(usize::MAX),
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.no_pane_cmdline_push_char(c);
            }
            _ => {}
        }
        return;
    }

    match app.focus {
        Focus::Tree => handle_tree_key(app, key),
        Focus::Pane => handle_pane_key(app, key),
    }
}

// T-1: chord-chain dispatch + tick + timeout const moved to src/tui/chord.rs.
// Re-exported above (`pub use chord::*`) so existing call sites work.

// T-3: overlay key handlers moved to src/tui/handlers/overlay.rs.
// Imported above so existing dispatch_key call sites work.

// T-4: handle_tree_key, handle_pane_key, handle_md_preview_key,
// handle_diff_key, handle_request_key, is_view_only_pane moved to
// src/tui/handlers/pane.rs (imported above).

/// Shell out `mixr --command <verb>` for the statusline transport
/// chip. Detached + non-blocking so a slow mixr-side handler can't
/// stutter the render loop; failures are logged and otherwise
/// swallowed so an absent / not-on-PATH mixr doesn't surface as a
/// scary toast for users who don't have mixr installed at all.
/// The `mixr --command` path writes to `~/.mixr/command` (an atomic
/// file write) which a running mixr polls — nothing else is needed.
pub(crate) fn send_mixr_command(verb: &str) {
    let result = std::process::Command::new("mixr")
        .args(["--command", verb])
        .spawn();
    if let Err(e) = result {
        eprintln!("mnml: send_mixr_command({verb:?}) failed: {e}");
    }
}

/// Drive Apple Music / Spotify via AppleScript for the statusline
/// transport chips. `app_name` is the source string mnml reads from
/// `now_playing` (`"Music"` / `"Spotify"`), `verb` is an AppleScript
/// transport command — `"playpause"`, `"next track"`, etc.
///
/// Detached + non-blocking; failures log and are swallowed so a user
/// without the named app installed doesn't get a scary toast.
pub(crate) fn send_macos_player(app_name: &str, verb: &str) {
    // Whitelist the source names we recognize so a malformed
    // `np.source` can't be coerced into arbitrary AppleScript.
    let app = match app_name {
        s if s.eq_ignore_ascii_case("Music") => "Music",
        s if s.eq_ignore_ascii_case("Spotify") => "Spotify",
        _ => return,
    };
    let script = format!("tell application \"{app}\" to {verb}");
    let result = std::process::Command::new("osascript")
        .args(["-e", &script])
        .spawn();
    if let Err(e) = result {
        eprintln!("mnml: send_macos_player({app_name:?}, {verb:?}) failed: {e}");
    }
}
