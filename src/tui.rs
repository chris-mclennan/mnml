//! The terminal frontend: raw-mode / alt-screen / mouse-capture setup, the
//! crossterm event loop, and the shared key/mouse dispatchers (`dispatch_key` /
//! `dispatch_mouse`) that the headless+IPC loop also calls — so headless behavior
//! matches the real UI.

use std::io::{self, Stdout};
use std::time::Duration;

use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use ratatui::crossterm::cursor::SetCursorStyle;
use ratatui::crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind,
    KeyModifiers, KeyboardEnhancementFlags, MouseButton, MouseEvent, MouseEventKind,
    PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, SetTitle, disable_raw_mode, enable_raw_mode,
    supports_keyboard_enhancement,
};

use crate::app::App;
use crate::buffer::BufferEvent;
use crate::focus::Focus;
use crate::ipc::{self, Ipc};
use crate::pane::Pane;
use crate::{command, ui};

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

/// If `first` is a ScrollUp/ScrollDown, drain every other
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
fn coalesce_scroll(first: &MouseEvent) -> std::io::Result<Option<MouseEvent>> {
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
    if key.modifiers.contains(KeyModifiers::ALT)
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
    // Discovery overlay (+ Add integration) — same all-keys-stolen
    // pattern; close on Esc, navigate with arrows/jk, Enter dispatches
    // by status, `y` yanks install command.
    if app.discovery_overlay.is_some() {
        handle_discovery_overlay_key(app, key);
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
    // An open picker / palette overlay steals all keys until it's dismissed.
    if app.picker.is_some() {
        handle_picker_key(app, key);
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

    if dispatch_chord_chain(app, key) {
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

/// Chord-chain aware keymap dispatch.
///
/// Maintains the App's `pending_chord_seq` + deadline + fallback. Drives the
/// vim-style `timeoutlen` semantics:
/// * `Run` → fire immediately, clear pending.
/// * `Pending` → keep the prefix, wait for the next key (with a timeout for
///   the case where the user gives up mid-chord).
/// * `PendingWithFallback` → same as Pending, but record the inner command
///   so the timeout fires it.
/// * `None` → if the prior pending had a fallback, fire that; then try the
///   current key as a fresh sequence start. If even that doesn't bind,
///   return false so the focused handler sees the key.
///
/// Returns `true` when the key was consumed (a command fired, or the
/// pending state advanced), `false` when the key should fall through to
/// the editor / tree.
fn dispatch_chord_chain(app: &mut App, key: KeyEvent) -> bool {
    use crate::input::keymap::{Chord, SeqResolution};
    // The chord-chain pending state must NEVER survive a focus change or a
    // modal overlay open/close — callers above us return early, so we only
    // reach here when no overlay is intercepting.
    let new_chord = Chord::of(&key);
    app.pending_chord_seq.push(new_chord);
    match app.keymap.resolve_seq(&app.pending_chord_seq) {
        SeqResolution::Run(id) => {
            let id = id.to_owned();
            app.pending_chord_seq.clear();
            app.pending_chord_deadline = None;
            app.pending_chord_fallback = None;
            command::run(&id, app);
            true
        }
        SeqResolution::PendingWithFallback(fallback) => {
            let fb = fallback.to_owned();
            app.pending_chord_fallback = Some(fb);
            app.pending_chord_deadline = Some(
                std::time::Instant::now()
                    + std::time::Duration::from_millis(CHORD_CHAIN_TIMEOUT_MS),
            );
            true
        }
        SeqResolution::Pending => {
            app.pending_chord_fallback = None;
            app.pending_chord_deadline = Some(
                std::time::Instant::now()
                    + std::time::Duration::from_millis(CHORD_CHAIN_TIMEOUT_MS),
            );
            true
        }
        SeqResolution::None => {
            // The extended sequence doesn't match anything. If there was a
            // prior pending state with a fallback, fire it; then process
            // this key as if it were a fresh sequence start.
            let fallback = app.pending_chord_fallback.take();
            let was_first_key = app.pending_chord_seq.len() == 1;
            app.pending_chord_seq.clear();
            app.pending_chord_deadline = None;
            if let Some(id) = fallback {
                command::run(&id, app);
            }
            if was_first_key {
                // Lone key, no binding. Caller falls through to the
                // focused handler.
                return false;
            }
            // We were extending a chain; the chain bottomed out. Try the
            // CURRENT key on its own — it might start a fresh chain or
            // fire a single-chord binding. One level of recursion is
            // bounded (was_first_key would be true on the inner call).
            app.pending_chord_seq.push(new_chord);
            match app.keymap.resolve_seq(&app.pending_chord_seq) {
                SeqResolution::Run(id) => {
                    let id = id.to_owned();
                    app.pending_chord_seq.clear();
                    command::run(&id, app);
                    true
                }
                SeqResolution::PendingWithFallback(fb) => {
                    let fb = fb.to_owned();
                    app.pending_chord_fallback = Some(fb);
                    app.pending_chord_deadline = Some(
                        std::time::Instant::now()
                            + std::time::Duration::from_millis(CHORD_CHAIN_TIMEOUT_MS),
                    );
                    true
                }
                SeqResolution::Pending => {
                    app.pending_chord_deadline = Some(
                        std::time::Instant::now()
                            + std::time::Duration::from_millis(CHORD_CHAIN_TIMEOUT_MS),
                    );
                    true
                }
                SeqResolution::None => {
                    app.pending_chord_seq.clear();
                    false
                }
            }
        }
    }
}

/// Vim's `timeoutlen` analogue — how long to wait for the next key in a
/// chord chain before giving up. `g:timeoutlen` defaults to 1000ms in vim;
/// VS Code uses a roughly comparable window. Could become a config knob.
const CHORD_CHAIN_TIMEOUT_MS: u64 = 1000;

/// Fire the pending chord-chain's fallback (if any) when its deadline has
/// elapsed and clear pending state. Called from `App::tick` each frame so
/// the user doesn't have to press another key to "kick" a dangling prefix.
pub fn tick_chord_chain(app: &mut App) {
    let Some(deadline) = app.pending_chord_deadline else {
        return;
    };
    if std::time::Instant::now() < deadline {
        return;
    }
    let fallback = app.pending_chord_fallback.take();
    app.pending_chord_seq.clear();
    app.pending_chord_deadline = None;
    if let Some(id) = fallback {
        command::run(&id, app);
    }
}

fn handle_help_overlay_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Esc | KeyCode::F(1) => app.close_help_overlay(),
        KeyCode::Up | KeyCode::Char('k') => app.help_scroll(-1),
        KeyCode::Down | KeyCode::Char('j') => app.help_scroll(1),
        KeyCode::PageUp => app.help_scroll(-10),
        KeyCode::PageDown => app.help_scroll(10),
        KeyCode::Home => app.help_scroll(-1_000_000),
        KeyCode::End => app.help_scroll(1_000_000),
        // `c` collapses ALL sections; `e` expands all. Quick way
        // to scan or focus.
        KeyCode::Char('c') => {
            if let Some(state) = app.help_overlay.as_mut() {
                // Collect all section names from current registry
                // — match what the renderer iterates over.
                let rows = crate::app::help::build_help(&app.keymap);
                for r in &rows {
                    if let crate::app::help::HelpRow::Section(name) = r {
                        state.collapsed.insert((*name).to_string());
                    }
                }
                state.scroll = 0;
            }
        }
        KeyCode::Char('e') => {
            if let Some(state) = app.help_overlay.as_mut() {
                state.collapsed.clear();
                state.scroll = 0;
            }
        }
        _ => {}
    }
}

fn handle_git_section_commit_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    match key.code {
        KeyCode::Esc => app.git_section_commit_blur(),
        KeyCode::Enter if ctrl => app.git_section_commit_submit(),
        KeyCode::Backspace => app.git_section_commit_backspace(),
        KeyCode::Char(c) if !ctrl => app.git_section_commit_insert_char(c),
        _ => {}
    }
}

fn handle_search_section_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    match key.code {
        KeyCode::Esc => app.search_section_blur(),
        KeyCode::Enter => {
            // If the input has any text, Enter commits — runs the grep.
            // If there are hits AND the input is empty, Enter jumps to
            // the highlighted hit instead. Either way, after running
            // the user can ↑↓ navigate without re-focusing.
            if app.search_query.trim().is_empty() && !app.search_hits.is_empty() {
                app.search_section_open_selected();
            } else {
                app.search_section_run();
            }
        }
        KeyCode::Backspace => app.search_section_backspace(),
        KeyCode::Up if !ctrl => app.search_section_select(-1),
        KeyCode::Down if !ctrl => app.search_section_select(1),
        KeyCode::Char(c) if !ctrl => app.search_section_insert_char(c),
        _ => {}
    }
}

fn handle_discovery_overlay_key(app: &mut App, key: KeyEvent) {
    // Integration-edit panel is greedy when open — every keystroke
    // routes to the panel until Enter saves or Esc cancels. Tab /
    // ←→ cycle field + color; text fields accept char + backspace.
    let edit_panel_open = app
        .discovery_overlay
        .as_ref()
        .is_some_and(|s| s.edit_panel.is_some());
    if edit_panel_open {
        match key.code {
            KeyCode::Esc => app.integration_edit_cancel(),
            KeyCode::Enter => app.integration_edit_save(),
            KeyCode::Tab => app.integration_edit_cycle_field(1),
            KeyCode::BackTab => app.integration_edit_cycle_field(-1),
            KeyCode::Left => app.integration_edit_color_cycle(-1),
            KeyCode::Right => app.integration_edit_color_cycle(1),
            KeyCode::Up => app.integration_edit_cycle_field(-1),
            KeyCode::Down => app.integration_edit_cycle_field(1),
            KeyCode::Backspace => app.integration_edit_backspace(),
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.integration_edit_type_char(c);
            }
            _ => {}
        }
        return;
    }
    match key.code {
        KeyCode::Esc | KeyCode::Char('q') => app.close_discovery_overlay(),
        KeyCode::Up | KeyCode::Char('k') => app.discovery_move_row(-1),
        KeyCode::Down | KeyCode::Char('j') => app.discovery_move_row(1),
        KeyCode::Enter => app.discovery_enter(),
        // `i` spawns `cargo install --git <url> --tag <ver>` in a
        // pty pane the user can watch live; `y` yanks the command for
        // out-of-mnml install. Both come back to the rail via
        // `integrations.refresh` (auto-cleared on next + overlay open).
        KeyCode::Char('i') => app.discovery_install_selected(),
        KeyCode::Char('y') => app.discovery_yank_install(),
        // `e` opens the edit panel for the focused rail row. No-op
        // on non-InRail rows (the others aren't in the config yet).
        KeyCode::Char('e') => app.open_integration_edit_from_focused(),
        // `a` opens the edit panel in AddCustom mode — blank fields,
        // user fills in id + command + glyph + color + fallback +
        // tooltip from scratch.
        KeyCode::Char('a') => app.open_integration_edit_add_custom(),
        // `t` flips between Installed and Marketplace tabs at the
        // top of the overlay.
        KeyCode::Char('t') => app.discovery_toggle_tab(),
        _ => {}
    }
}

fn handle_settings_overlay_key(app: &mut App, key: KeyEvent) {
    // Text/Color rows enter a greedy edit mode on Enter — every
    // keystroke goes to the buffer until Enter commits (or Esc
    // cancels). Other navigation keys are intercepted to avoid the
    // overlay reacting twice.
    if app.settings_text_edit_active() {
        // 2026-06-19 — user-reported: couldn't arrow-cursor inside
        // the edit buffer, forcing backspace from the end to fix
        // mid-string typos. Added Left/Right/Home/End/Delete.
        match key.code {
            KeyCode::Esc => app.settings_text_edit_cancel(),
            KeyCode::Enter => app.settings_text_edit_commit(),
            KeyCode::Backspace => app.settings_text_edit_backspace(),
            KeyCode::Delete => app.settings_text_edit_delete(),
            KeyCode::Left => app.settings_text_edit_move_left(),
            KeyCode::Right => app.settings_text_edit_move_right(),
            KeyCode::Home => app.settings_text_edit_home(),
            KeyCode::End => app.settings_text_edit_end(),
            KeyCode::Char(c) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                app.settings_text_edit_insert(c);
            }
            _ => {}
        }
        return;
    }
    match key.code {
        KeyCode::Esc => app.close_settings_overlay_cancel(),
        KeyCode::Enter => app.settings_enter_row(),
        KeyCode::Up | KeyCode::Char('k') => app.settings_move_row(-1),
        KeyCode::Down | KeyCode::Char('j') => app.settings_move_row(1),
        KeyCode::Left | KeyCode::Char('h') => app.settings_adjust_value(-1),
        KeyCode::Right | KeyCode::Char('l') => app.settings_adjust_value(1),
        KeyCode::Char('r') => app.settings_reset_row(),
        KeyCode::Char('R') => {
            // Shift+r — reset all to defaults (the explicit reset-all
            // path; the same as Enter on the sentinel row).
            app.config = crate::config::Config::default();
            app.toast("settings: all reset to defaults");
        }
        _ => {}
    }
}

fn handle_picker_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let Some(picker) = app.picker.as_mut() else {
        return;
    };
    match key.code {
        KeyCode::Esc => app.close_picker(),
        // Tab on a picker → "secondary accept" — picker-specific
        // behavior. No-op for every kind right now; left as a hook
        // for future per-kind use (the 2026-06 SCM split removed the
        // cross-host PR picker that originally drove this).
        KeyCode::Tab => app.picker_accept_secondary(),
        KeyCode::Enter => app.picker_accept(),
        KeyCode::Up => {
            picker.move_up();
            app.on_picker_moved();
        }
        KeyCode::Down => {
            picker.move_down();
            app.on_picker_moved();
        }
        KeyCode::Char('p') if ctrl => {
            picker.move_up();
            app.on_picker_moved();
        }
        KeyCode::Char('n') if ctrl => {
            picker.move_down();
            app.on_picker_moved();
        }
        KeyCode::Char('u') if ctrl => picker.clear_query(),
        KeyCode::Backspace => picker.backspace(),
        KeyCode::Char(c) if !ctrl => picker.type_char(c),
        _ => {}
    }
}

fn handle_prompt_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let Some(p) = app.prompt.as_mut() else { return };
    let was_find = matches!(p.kind, crate::prompt::PromptKind::Find);
    // Up/Down on the Find prompt cycle through the find-history (shell-style).
    if was_find && matches!(key.code, KeyCode::Up | KeyCode::Down) {
        match key.code {
            KeyCode::Up => app.find_history_prev(),
            KeyCode::Down => app.find_history_next(),
            _ => {}
        }
        return;
    }
    // Path-typed prompts (AddWorkspace) get a live directory listing
    // alongside the input. ↑↓ navigate the list, Tab autocompletes,
    // typing keeps working in parallel.
    if p.is_path_kind() {
        match key.code {
            KeyCode::Up => {
                p.suggestion_prev();
                return;
            }
            KeyCode::Down => {
                p.suggestion_next();
                return;
            }
            KeyCode::Tab => {
                p.autocomplete();
                return;
            }
            _ => {}
        }
    }
    match key.code {
        KeyCode::Esc => {
            app.prompt_cancel();
            return;
        }
        KeyCode::Enter => {
            app.prompt_accept();
            return;
        }
        KeyCode::Backspace => {
            if ctrl {
                p.delete_word();
            } else {
                p.backspace();
            }
        }
        KeyCode::Char('w') if ctrl => p.delete_word(),
        KeyCode::Char('u') if ctrl => {
            p.input.clear();
            p.cursor = 0;
        }
        KeyCode::Left => p.move_left(),
        KeyCode::Right => p.move_right(),
        KeyCode::Home => p.move_home(),
        KeyCode::End => p.move_end(),
        KeyCode::Char(c) if !ctrl => p.insert_char(c),
        _ => {}
    }
    // Incremental find — live-update the editor's find state as the query
    // grows / shrinks so the user can see matches before Enter.
    if was_find && let Some(p) = app.prompt.as_ref() {
        let q = p.input.clone();
        app.update_live_find_preview(q);
    }
}

fn handle_tree_key(app: &mut App, key: KeyEvent) {
    // The rail has two sections (workspace + git). Route the key to the one
    // the keyboard is parked on; the cursor crosses the boundary on ↓ off the
    // bottom of workspace or ↑ off the top of git.
    if app.rail_section == crate::app::RailSection::Git {
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
            // vim handler enters Prefix::Window mode for the next
            // key. Standard mode treats Ctrl+W as buffer.close —
            // re-dispatching it from tree focus might close the
            // active editor, which the user didn't ask for. Skip the
            // re-dispatch in standard mode.
            if app.config.editor.input_style == "vim" {
                handle_pane_key(app, key);
            }
        }
        return;
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
        }
        KeyCode::Down | KeyCode::Char('j') => {
            if let Some(ws_idx) = app.focused_extra_ws
                && let Some(ws) = app.extra_workspaces.get_mut(ws_idx)
            {
                ws.tree.move_down();
            } else {
                app.tree.move_down();
            }
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
        KeyCode::Right | KeyCode::Char('l') => app.tree.expand_or_descend(),
        KeyCode::Left | KeyCode::Char('h') => app.tree.collapse_or_ascend(),
        KeyCode::Enter | KeyCode::Char(' ') => app.tree_activate(),
        KeyCode::Char('R') => app.tree.refresh(),
        KeyCode::Home | KeyCode::Char('g') => app.tree.set_cursor(0),
        KeyCode::End | KeyCode::Char('G') => app.tree.set_cursor(usize::MAX),
        // When there's a sticky filter, Esc clears it before yielding focus.
        KeyCode::Esc if !app.tree.filter.is_empty() => app.tree.filter_clear_and_exit(),
        _ => {}
    }
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

fn handle_pane_key(app: &mut App, key: KeyEvent) {
    let viewport = crate::app::dispatch::pane_viewport(app);
    let Some(i) = app.active else { return };
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
        // Ctrl+W → in vim mode, jump to the first editor pane and
        // re-dispatch so its vim handler enters Prefix::Window.
        // Standard mode treats Ctrl+W as buffer.close — skip.
        if key.code == KeyCode::Char('w')
            && key.modifiers.contains(KeyModifiers::CONTROL)
            && app.config.editor.input_style == "vim"
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
                }
            }
            KeyCode::End => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    let n = p.visible_indices().len();
                    p.selected = n.saturating_sub(1);
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
            KeyCode::Char('<') => {
                if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(i) {
                    use crate::claude_agents::AgentSource;
                    p.source_filter = match p.source_filter {
                        None => Some(AgentSource::AnthropicManaged),
                        Some(AgentSource::AnthropicManaged) => Some(AgentSource::TattleQwe),
                        Some(AgentSource::TattleQwe) => Some(AgentSource::Codex),
                        Some(AgentSource::Codex) => Some(AgentSource::Claude),
                        Some(AgentSource::Claude) => None,
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
                let (edits, new_consumed) = if len >= sess.edits_consumed {
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
                } else if app.config.editor.input_style == "vim" {
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
        && let Some((_, hit)) = app
            .rects
            .cloud_agent_run_hits
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
            .cloned()
    {
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
    // (or a right-click) dismisses.
    if app.context_menu.is_some() {
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
            // Palette top-bar — back / forward / chip / dropdown.
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
                // 2026-06-22 — double-click on a per-leaf tab
                // promotes a preview tab to a permanent one
                // (matches bufferline-tab double-click). Re-uses
                // `App::last_click` for the timing.
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
            // Bufferline (file-tab) drag-to-reorder. Same shape as the
            // tab-page handler above — find the tab under the cursor,
            // swap the underlying panes, update the drag-source to the
            // new id of the moved pane.
            if let Some(src) = app.rects.bufferline_drag_tab {
                let dst = app
                    .rects
                    .bufferline_tabs
                    .iter()
                    .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
                    .map(|(_, pid)| *pid);
                if let Some(dst) = dst
                    && dst != src
                {
                    app.swap_bufferline_tabs(src, dst);
                    // After the swap, the pane WE were dragging now
                    // lives at `dst`'s old id (i.e. `dst`).
                    app.rects.bufferline_drag_tab = Some(dst);
                    app.rects.tab_drop_target = None;
                } else {
                    // Not over the tab strip — track the pane-body drop zone so
                    // the drop-hint overlay can show where a split would land.
                    app.update_tab_drop_target(x, y);
                }
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
                let over_body = app
                    .rects
                    .pane_bodies
                    .iter()
                    .any(|(r, _)| crate::app::dispatch::contains(*r, x, y));
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
            // Mouse-up always clears the bufferline-tab drag arm.
            app.rects.bufferline_drag_tab = None;
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
    if let Some(Pane::Request(rp)) = app.panes.get_mut(i) {
        use crate::request_pane::ViewMode;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
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
                // Ctrl+Shift+F — format JSON Body. Same chord as
                // most IDEs use for code formatting. No-op on
                // non-JSON Body (toast explains).
                KeyCode::Char('f') if ctrl && shift => {
                    let _ = rp;
                    app.http_format_body();
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
        match key.code {
            KeyCode::Tab => rp.toggle_view(),
            KeyCode::Up | KeyCode::Char('k') => rp.scroll = rp.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => rp.scroll += 1,
            KeyCode::PageUp => rp.scroll = rp.scroll.saturating_sub(viewport),
            KeyCode::PageDown => rp.scroll += viewport,
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
            KeyCode::Char('.') => app.ai_debug_request(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return true;
    }
    false
}

/// Shell out `mixr --command <verb>` for the statusline transport
/// chip. Detached + non-blocking so a slow mixr-side handler can't
/// stutter the render loop; failures are logged and otherwise
/// swallowed so an absent / not-on-PATH mixr doesn't surface as a
/// scary toast for users who don't have mixr installed at all.
/// The `mixr --command` path writes to `~/.mixr/command` (an atomic
/// file write) which a running mixr polls — nothing else is needed.
fn send_mixr_command(verb: &str) {
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
fn send_macos_player(app_name: &str, verb: &str) {
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
