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
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
    supports_keyboard_enhancement,
};
use ratatui::layout::Rect;

use crate::app::App;
use crate::buffer::BufferEvent;
use crate::edit_op::EditOp;
use crate::focus::Focus;
use crate::ipc::{self, Ipc};
use crate::pane::Pane;
use crate::{command, ui};

/// Run the terminal UI. `Ok(true)` ⇒ exit for a rebuild+relaunch (the `run.sh`
/// wrapper watches for that); `Ok(false)` ⇒ normal quit.
pub fn run(mut app: App) -> Result<bool, String> {
    let mut term = setup_terminal().map_err(|e| format!("terminal setup failed: {e}"))?;
    let result = run_loop(&mut term, &mut app);
    let _ = restore_terminal(&mut term);
    result
        .map(|()| app.restart_requested)
        .map_err(|e| format!("{e}"))
}

fn setup_terminal() -> io::Result<Terminal<CrosstermBackend<Stdout>>> {
    enable_raw_mode()?;
    let mut out = io::stdout();
    if let Err(e) = execute!(
        out,
        EnterAlternateScreen,
        EnableMouseCapture,
        SetCursorStyle::SteadyBar
    ) {
        let _ = disable_raw_mode();
        return Err(e);
    }
    // Ask for the kitty keyboard protocol so chords the legacy encoding can't
    // express — `Ctrl+Shift+P`, `Ctrl+I` vs `Tab`, etc. — come through distinctly.
    // No-op on terminals that don't support it; harmless if it errors.
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

    loop {
        app.tick();
        if app.redraw_requested {
            app.redraw_requested = false;
            // Force a fresh paint over a cleared buffer (an external process
            // can leave the terminal in any state).
            term.clear()?;
        }
        term.draw(|f| ui::draw(f, app))?;
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
        let timeout = Duration::from_millis(if app.has_pty_pane() || app.has_pending_ai() {
            40
        } else {
            120
        });
        if event::poll(timeout)? {
            match event::read()? {
                Event::Key(k) if k.kind != KeyEventKind::Release => dispatch_key(app, k),
                Event::Mouse(m) => dispatch_mouse(app, m),
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

// ─── key dispatch (shared with headless/IPC) ────────────────────────

pub fn dispatch_key(app: &mut App, key: KeyEvent) {
    // An open picker / palette overlay steals all keys until it's dismissed.
    if app.picker.is_some() {
        handle_picker_key(app, key);
        return;
    }
    // The LSP signature-help popup: Esc dismisses; any other key falls
    // through (we want typing to continue updating the popup, not dismiss
    // it). Cursor jumps via commands clear the popup separately.
    if app.signature.is_some() && key.code == KeyCode::Esc {
        app.signature = None;
        return;
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
                app.completion_accept();
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

    // App-level chords (any focus) resolve through the one keymap table — registry
    // defaults overlaid with `[keys.*]` config. These win over the focused pane;
    // all built-in defaults are modified/F-keys the editor doesn't want anyway.
    if let Some(id) = app.keymap.resolve(&key).map(str::to_owned) {
        command::run(&id, app);
        return;
    }

    match app.focus {
        Focus::Tree => handle_tree_key(app, key),
        Focus::Pane => handle_pane_key(app, key),
    }
}

fn handle_picker_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let Some(picker) = app.picker.as_mut() else {
        return;
    };
    match key.code {
        KeyCode::Esc => app.close_picker(),
        KeyCode::Enter => app.picker_accept(),
        KeyCode::Up => picker.move_up(),
        KeyCode::Down => picker.move_down(),
        KeyCode::Char('p') if ctrl => picker.move_up(),
        KeyCode::Char('n') if ctrl => picker.move_down(),
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
            KeyCode::Esc | KeyCode::Left | KeyCode::Char('h') => {
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
    match key.code {
        KeyCode::Char('/') => {
            app.tree.filter_mode = true;
        }
        KeyCode::Up | KeyCode::Char('k') => app.tree.move_up(),
        KeyCode::Down | KeyCode::Char('j') => {
            // At the bottom of the workspace list, ↓ crosses into the GIT
            // section (only when it's expanded + non-empty — otherwise it's
            // a no-op so the user doesn't fall into an empty section).
            let last = app.tree.visible_rows().len().saturating_sub(1);
            if app.tree.cursor() == last && app.git_section_expanded && !app.git_rail.is_empty() {
                app.rail_section = crate::app::RailSection::Git;
                app.git_rail.set_cursor(0);
            } else {
                app.tree.move_down();
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

fn handle_pane_key(app: &mut App, key: KeyEvent) {
    let viewport = pane_viewport(app);
    let Some(i) = app.active else { return };
    // A markdown preview is read-only: only scroll + Esc.
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
        return;
    }
    // A git diff pane: scroll, `n`/`p` move the cursor hunk, `s`/`u` stage/unstage,
    // `r` refresh, Enter jump to the hunk in the source, Esc → tree.
    if let Some(Pane::Diff(d)) = app.panes.get_mut(i) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => d.scroll = d.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => d.scroll += 1,
            KeyCode::PageUp => d.scroll = d.scroll.saturating_sub(viewport),
            KeyCode::PageDown => d.scroll += viewport,
            KeyCode::Char('n') | KeyCode::Char(']') => {
                d.cursor = (d.cursor + 1).min(d.hunks.len().saturating_sub(1));
            }
            KeyCode::Char('p') | KeyCode::Char('[') => d.cursor = d.cursor.saturating_sub(1),
            KeyCode::Home | KeyCode::Char('g') => {
                d.scroll = 0;
                d.cursor = 0;
            }
            KeyCode::End | KeyCode::Char('G') => d.scroll = usize::MAX,
            KeyCode::Char('s') => app.apply_cursor_hunk(false),
            KeyCode::Char('u') => app.apply_cursor_hunk(true),
            KeyCode::Char('r') => app.refresh_active_diff(),
            KeyCode::Enter => app.jump_to_cursor_hunk(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // A request pane: two modes. Response (default) is read-only — j/k scroll,
    // r re-fire, y copy-as-curl, Tab → Edit, Esc → tree. Edit is the Postman
    // form — Shift-Tab/Tab cycle the focused field, typing/backspace/arrows
    // edit, Space on Method cycles HTTP verbs, r re-fires with the current
    // values, Tab back to Response, Esc → tree.
    if let Some(Pane::Request(rp)) = app.panes.get_mut(i) {
        use crate::request_pane::ViewMode;
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        if rp.view == ViewMode::Edit {
            match key.code {
                KeyCode::Tab if shift => rp.focus_prev_field(),
                KeyCode::Tab => rp.focus_next_field(),
                KeyCode::BackTab => rp.focus_prev_field(),
                KeyCode::Esc => app.focus_tree(),
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
                        // Enter on URL/Method = fire (Postman-style "send").
                        app.send_request_from_active();
                    }
                }
                KeyCode::Char(c) if !ctrl => {
                    // `r` from URL / Method fires; `r` inside multi-line fields
                    // is a literal char (so typing "Authorization" etc. works).
                    let multi_line = matches!(
                        rp.focus,
                        crate::request_pane::EditField::Body
                            | crate::request_pane::EditField::Headers
                    );
                    if c == 'r' && !multi_line {
                        app.send_request_from_active();
                    } else {
                        rp.type_char(c);
                    }
                }
                _ => {}
            }
            return;
        }
        match key.code {
            KeyCode::Tab => rp.toggle_view(),
            KeyCode::Up | KeyCode::Char('k') => rp.scroll = rp.scroll.saturating_sub(1),
            KeyCode::Down | KeyCode::Char('j') => rp.scroll += 1,
            KeyCode::PageUp => rp.scroll = rp.scroll.saturating_sub(viewport),
            KeyCode::PageDown => rp.scroll += viewport,
            KeyCode::Home | KeyCode::Char('g') => rp.scroll = 0,
            KeyCode::End | KeyCode::Char('G') => rp.scroll = usize::MAX, // clamped on draw
            KeyCode::Char('r') => app.send_request_from_active(),
            KeyCode::Char('y') => app.copy_active_curl(),
            KeyCode::Char('Y') => app.copy_active_response_body(),
            KeyCode::Char('e') => rp.toggle_view(),
            KeyCode::Char('.') => app.ai_debug_request(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
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
    // A trace pane (parsed `trace.zip`): ↑↓/jk select, PgUp/PgDn/g/G jump, r
    // re-parse, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::Trace(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.move_selection(-1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.move_selection(1);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.move_selection(-(viewport as isize));
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.move_selection(viewport as isize);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.move_selection(isize::MIN / 2);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.move_selection(isize::MAX / 2);
                }
            }
            KeyCode::Char('h') => app.heal_from_active_trace(),
            KeyCode::Char('r') => app.refresh_active_trace(),
            // Per-kind filter toggles + presets (errors-only / show-all).
            KeyCode::Char('a') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.toggle_kind(crate::playwright::trace::EventKind::Action);
                }
            }
            KeyCode::Char('c') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.toggle_kind(crate::playwright::trace::EventKind::Console);
                }
            }
            KeyCode::Char('e') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.toggle_kind(crate::playwright::trace::EventKind::Error);
                }
            }
            KeyCode::Char('s') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.toggle_kind(crate::playwright::trace::EventKind::Stdio);
                }
            }
            KeyCode::Char('E') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.errors_only_preset();
                }
            }
            KeyCode::Char('A') => {
                if let Some(Pane::Trace(tr)) = app.panes.get_mut(i) {
                    tr.show_all_kinds();
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
        let (net_focus, dom_focus) = match app.panes.get(i) {
            Some(Pane::Browser(b)) => (b.net_focus, b.dom_focus),
            _ => (false, false),
        };
        let any_panel = net_focus || dom_focus;
        // In the net / DOM panel ↑↓/jk/PgUp/PgDn/g/G/Home/End move the row
        // selection; otherwise they scroll the log.
        let scroll_or_select = |app: &mut App, delta: isize, jump: Option<usize>| {
            if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                if b.dom_focus {
                    match jump {
                        Some(usize::MAX) => b.dom_sel = b.dom.len().saturating_sub(1),
                        Some(n) => b.dom_sel = n,
                        None => b.move_dom_sel(delta),
                    }
                } else if b.net_focus {
                    match jump {
                        Some(usize::MAX) => b.net_sel = b.net.len().saturating_sub(1),
                        Some(n) => b.net_sel = n,
                        None => b.move_net_sel(delta),
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
                        b.net_sel = b.net_sel.min(b.net.len().saturating_sub(1));
                    }
                }
            }
            KeyCode::Char('D') => app.browser_open_dom(),
            KeyCode::Char('R') if dom_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.fetch_dom();
                }
            }
            KeyCode::Char('y') if net_focus => app.copy_net_entry_curl(),
            KeyCode::Char('c') if dom_focus => app.copy_dom_selector(),
            KeyCode::Char('h') if dom_focus => {
                if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                    b.highlight_selected_dom();
                }
            }
            KeyCode::Enter if net_focus => app.open_net_entry_as_request(),
            KeyCode::Char('g') => app.browser_navigate_prompt(),
            KeyCode::Char('e') => app.browser_eval_prompt(),
            KeyCode::Char('r') => app.browser_reload(),
            KeyCode::Char('s') => app.browser_screenshot(),
            KeyCode::Char('T') => app.open_browser_target_picker(),
            KeyCode::Esc => {
                if any_panel {
                    if let Some(Pane::Browser(b)) = app.panes.get_mut(i) {
                        if b.dom_focus {
                            b.hide_highlight();
                        }
                        b.net_focus = false;
                        b.dom_focus = false;
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
            KeyCode::Char('y') => app.copy_selected_grep_hit(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // The git-graph pane: ↑↓ select a commit, Enter → open that commit's diff,
    // `r` refresh (re-run `git log`), `y` copy the commit hash, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::GitGraph(_))) {
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
            KeyCode::Enter => app.open_selected_commit_diff(),
            KeyCode::Char('r') => app.refresh_active_git_graph(),
            KeyCode::Char('y') => app.copy_selected_commit_hash(),
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
        let bytes = pty_key_bytes(key);
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
    // `b` borrows app.panes; `&mut app.clipboard` is a disjoint field — fine.
    let ev = match app.panes.get_mut(i) {
        Some(Pane::Editor(b)) => b.feed_key(key, &mut app.clipboard, viewport),
        _ => return,
    };
    match ev {
        BufferEvent::Edited => {
            // Keep the LSP server's view in sync (full-text didChange).
            let upd = match app.panes.get(i) {
                Some(Pane::Editor(b)) => b.path.clone().map(|p| (p, b.editor.text().to_string())),
                _ => None,
            };
            if let Some((p, text)) = upd {
                app.lsp.did_change(&p, &text);
                // Live markdown preview: push the in-memory text to any open
                // `Pane::MdPreview` of this file so the preview tracks edits
                // instead of waiting for save.
                if p.extension().and_then(|e| e.to_str()) == Some("md") {
                    app.refresh_md_previews_from_text(&p, &text);
                }
            }
            // Drive the as-you-type completion popup off the fresh buffer state.
            app.completion_on_edit(typed_char);
        }
        BufferEvent::Redraw | BufferEvent::NoOp => {}
        BufferEvent::App(cmd) => apply_app_command(app, cmd),
        BufferEvent::Unhandled(k) => {
            // Not text-editing. Esc releases focus to the tree; the rest (config-
            // driven keymap → command resolver) lands with the keymap work in P3.
            if k.code == KeyCode::Esc {
                app.focus_tree();
            }
        }
    }
}

fn pane_viewport(app: &App) -> usize {
    app.active
        .and_then(|cur| {
            app.rects
                .editor_panes
                .iter()
                .find(|(_, p)| *p == cur)
                .map(|(r, _)| r.height as usize)
        })
        .unwrap_or(20)
        .max(1)
}

fn apply_app_command(app: &mut App, cmd: crate::input::AppCommand) {
    use crate::input::AppCommand::*;
    match cmd {
        Save => {
            command::run("file.save", app);
        }
        SaveAll => {
            command::run("file.save_all", app);
        }
        Quit => app.request_quit(),
        ForceQuit => app.should_quit = true,
        CloseBuffer => {
            command::run("buffer.close", app);
        }
        NextBuffer => {
            command::run("buffer.next", app);
        }
        PrevBuffer => {
            command::run("buffer.prev", app);
        }
        GotoLine(n) => {
            if let Some(i) = app.active
                && let Some(Pane::Editor(b)) = app.panes.get_mut(i)
            {
                b.editor
                    .apply(EditOp::MoveToLine(n), 20, &mut app.clipboard);
            }
        }
        ExCommand(s) => app.run_ex_command(&s),
        RunCommand(id) => {
            command::run(&id, app);
        }
        SetMark(c) => app.set_mark_at_cursor(c),
        JumpToMarkLine(c) => app.jump_to_mark(c, false),
        JumpToMarkExact(c) => app.jump_to_mark(c, true),
    }
}

// ─── mouse dispatch (shared with headless/IPC) ──────────────────────

pub fn dispatch_mouse(app: &mut App, m: MouseEvent) {
    let (x, y) = (m.column, m.row);

    // A click anywhere dismisses the hover / completion / signature popups
    // (the click still lands).
    if matches!(m.kind, MouseEventKind::Down(_)) {
        app.hover = None;
        app.completion = None;
        app.signature = None;
    }

    // While the picker is open it owns the mouse.
    if app.picker.is_some() {
        match m.kind {
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(&(_, fi)) = app
                    .rects
                    .picker_items
                    .iter()
                    .find(|(r, _)| contains(*r, x, y))
                {
                    if let Some(p) = app.picker.as_mut() {
                        p.set_selected(fi);
                    }
                    app.picker_accept();
                } else if app
                    .rects
                    .picker_box
                    .map(|r| !contains(r, x, y))
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
                .find(|(r, _)| contains(*r, x, y))
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
                    .find(|(r, _)| contains(*r, x, y))
                {
                    app.context_menu_select(i);
                    app.context_menu_accept();
                } else {
                    app.context_menu_cancel();
                }
            }
            MouseEventKind::Down(MouseButton::Right) => app.context_menu_cancel(),
            _ => {}
        }
        return;
    }

    // Middle-click on a bufferline tab closes it (browser-tab pattern). Match
    // this before the per-button branch so it's a one-liner regardless of what
    // else the catch-all might do.
    if matches!(m.kind, MouseEventKind::Down(MouseButton::Middle))
        && let Some(&(_, id)) = app
            .rects
            .bufferline_tabs
            .iter()
            .find(|(r, _)| contains(*r, x, y))
    {
        app.close_pane(id);
        return;
    }

    match m.kind {
        MouseEventKind::Down(MouseButton::Right) => {
            // Right-click → a context menu on the bufferline tab / tree row under it.
            if let Some(&(_, id)) = app
                .rects
                .bufferline_tabs
                .iter()
                .find(|(r, _)| contains(*r, x, y))
            {
                app.open_tab_context_menu(id, (x, y));
                return;
            }
            if let Some(tr) = app.rects.tree
                && contains(tr, x, y)
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
                .find(|(r, _)| contains(*r, x, y))
            {
                app.open_git_rail_context_menu(hit, (x, y));
            }
        }
        MouseEventKind::Down(MouseButton::Left) => {
            // Grab the rail's right-edge handle? (cheaper / more specific
            // than a split divider — try this first.)
            if app.begin_tree_edge_drag(x, y) {
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
                .find(|(r, _, _)| contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                    b.folds.remove(&start);
                }
                return;
            }
            // Bufferline tab — clicking the close badge closes; clicking elsewhere on the tab activates.
            if let Some(&(_, id)) = app
                .rects
                .bufferline_tab_close
                .iter()
                .find(|(r, _)| contains(*r, x, y))
            {
                app.close_pane(id);
                return;
            }
            if let Some(&(_, id)) = app
                .rects
                .bufferline_tabs
                .iter()
                .find(|(r, _)| contains(*r, x, y))
            {
                app.reveal_pane(id);
                return;
            }
            // The `> WORKSPACE-NAME` section header — clicking it toggles the
            // workspace section's expand/collapse state (VS-Code Explorer-style).
            if let Some(tr) = app.rects.tree_toggle
                && contains(tr, x, y)
            {
                app.toggle_tree_root_expanded();
                return;
            }
            // The `> GIT` section header — same idea for the git rail.
            if let Some(tr) = app.rects.git_section_toggle
                && contains(tr, x, y)
            {
                app.toggle_git_section_expanded();
                return;
            }
            // Tree? (no header now — row 0 of the rail is the first entry)
            if let Some(tr) = app.rects.tree
                && contains(tr, x, y)
            {
                app.focus_tree();
                app.rail_section = crate::app::RailSection::Workspace;
                {
                    let idx = (y - tr.y) as usize + app.rects.tree_scroll;
                    if idx < app.tree.visible_rows().len() {
                        app.tree.set_cursor(idx);
                        if let Some(row) = app.tree.selected_row() {
                            if row.is_dir {
                                app.tree.toggle_current();
                            } else {
                                app.open_path(&row.path);
                            }
                        }
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
                .find(|(r, _)| contains(*r, x, y))
            {
                app.click_git_rail(hit);
                return;
            }
            // Editor text in some split leaf? Focus that leaf and place the cursor.
            // Track multi-click: 2 = select word, 3 = select line. The threshold
            // (450 ms, same cell) matches what most OSes use.
            if let Some(&(tr, pid)) = app
                .rects
                .editor_panes
                .iter()
                .find(|(r, _)| contains(*r, x, y))
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
                if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                    let visible_row = (y - tr.y) as usize;
                    let row = b
                        .visible_to_file_row(b.scroll, visible_row)
                        .unwrap_or(b.scroll);
                    let col = b.h_scroll + (x - tr.x) as usize;
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
                    }
                }
            }
        }
        MouseEventKind::Drag(MouseButton::Left) => {
            if app.dragging_tree_edge {
                // Hand the full screen width to the clamp logic.
                let screen_w = app
                    .rects
                    .body
                    .map(|r| r.x + r.width)
                    .or_else(|| app.rects.statusline.map(|r| r.x + r.width))
                    .unwrap_or(120);
                app.drag_tree_edge_to(x, screen_w);
            } else {
                app.drag_divider_to(x, y);
            }
        }
        MouseEventKind::Up(MouseButton::Left) => {
            app.end_tree_edge_drag();
            app.end_divider_drag();
        }
        MouseEventKind::ScrollUp => scroll_under(app, x, y, -3),
        MouseEventKind::ScrollDown => scroll_under(app, x, y, 3),
        _ => {}
    }
}

fn scroll_under(app: &mut App, x: u16, y: u16, delta: i32) {
    if let Some(tr) = app.rects.tree
        && contains(tr, x, y)
    {
        for _ in 0..delta.unsigned_abs() {
            if delta < 0 {
                app.tree.move_up();
            } else {
                app.tree.move_down();
            }
        }
        return;
    }
    // Scroll whichever split leaf is under the pointer (not necessarily the focused one).
    if let Some(&(tr, pid)) = app
        .rects
        .editor_panes
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        let vp = (tr.height as usize).max(1);
        match app.panes.get_mut(pid) {
            Some(Pane::Editor(b)) => {
                let op = if delta < 0 {
                    EditOp::MoveUp
                } else {
                    EditOp::MoveDown
                };
                for _ in 0..delta.unsigned_abs() {
                    b.editor.apply(op.clone(), vp, &mut app.clipboard);
                }
            }
            Some(Pane::MdPreview(p)) => {
                let n = delta.unsigned_abs() as usize;
                p.scroll = if delta < 0 {
                    p.scroll.saturating_sub(n)
                } else {
                    p.scroll + n
                };
            }
            Some(Pane::Diff(d)) => {
                let n = delta.unsigned_abs() as usize;
                d.scroll = if delta < 0 {
                    d.scroll.saturating_sub(n)
                } else {
                    d.scroll + n
                };
            }
            Some(Pane::Request(rp)) => {
                let n = delta.unsigned_abs() as usize;
                rp.scroll = if delta < 0 {
                    rp.scroll.saturating_sub(n)
                } else {
                    rp.scroll + n
                };
            }
            Some(Pane::Pty(s)) => s.scroll_history(if delta < 0 {
                delta.unsigned_abs() as isize
            } else {
                -(delta.unsigned_abs() as isize)
            }),
            Some(Pane::Ai(a)) => {
                let n = delta.unsigned_abs() as usize;
                a.scroll = if delta < 0 {
                    a.scroll.saturating_sub(n)
                } else {
                    a.scroll + n
                };
            }
            Some(Pane::Tests(t)) => {
                let n = delta.unsigned_abs() as usize;
                t.scroll = if delta < 0 {
                    t.scroll.saturating_sub(n)
                } else {
                    t.scroll + n
                };
            }
            Some(Pane::GitGraph(g)) => {
                g.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::GitStatus(g)) => {
                g.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Diagnostics(d)) => {
                d.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Grep(g)) => {
                g.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Trace(tr)) => {
                tr.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Browser(b)) => {
                if b.dom_focus {
                    b.move_dom_sel(if delta < 0 {
                        -(delta.unsigned_abs() as isize)
                    } else {
                        delta.unsigned_abs() as isize
                    });
                } else if b.net_focus {
                    b.move_net_sel(if delta < 0 {
                        -(delta.unsigned_abs() as isize)
                    } else {
                        delta.unsigned_abs() as isize
                    });
                } else {
                    let n = delta.unsigned_abs() as usize;
                    b.scroll = if delta < 0 {
                        b.scroll.saturating_sub(n)
                    } else {
                        b.scroll.saturating_add(n)
                    };
                }
            }
            Some(Pane::Flaky(f)) => {
                f.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Outline(o)) => {
                o.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            None => {}
        }
    }
}

fn contains(r: Rect, x: u16, y: u16) -> bool {
    x >= r.x && x < r.x.saturating_add(r.width) && y >= r.y && y < r.y.saturating_add(r.height)
}

/// Translate a key event into the byte sequence a pty child expects (xterm-ish).
fn pty_key_bytes(key: KeyEvent) -> Vec<u8> {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let alt = key.modifiers.contains(KeyModifiers::ALT);
    let prefix_alt = |b: Vec<u8>| {
        if alt {
            let mut v = vec![0x1b];
            v.extend(b);
            v
        } else {
            b
        }
    };
    match key.code {
        KeyCode::Char(c) => {
            if ctrl {
                // Control char: letters → 1..26, plus the usual @ [ \ ] ^ _.
                let b = match c.to_ascii_lowercase() {
                    'a'..='z' => Some((c.to_ascii_lowercase() as u8) - b'a' + 1),
                    ' ' | '@' => Some(0),
                    '[' => Some(0x1b),
                    '\\' => Some(0x1c),
                    ']' => Some(0x1d),
                    '^' => Some(0x1e),
                    '_' | '?' => Some(0x1f),
                    _ => None,
                };
                match b {
                    Some(b) => prefix_alt(vec![b]),
                    None => prefix_alt(c.to_string().into_bytes()),
                }
            } else {
                prefix_alt(c.to_string().into_bytes())
            }
        }
        KeyCode::Enter => prefix_alt(vec![b'\r']),
        KeyCode::Tab => prefix_alt(vec![b'\t']),
        KeyCode::BackTab => b"\x1b[Z".to_vec(),
        KeyCode::Backspace => prefix_alt(vec![0x7f]),
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => b"\x1b[A".to_vec(),
        KeyCode::Down => b"\x1b[B".to_vec(),
        KeyCode::Right => b"\x1b[C".to_vec(),
        KeyCode::Left => b"\x1b[D".to_vec(),
        KeyCode::Home => b"\x1b[H".to_vec(),
        KeyCode::End => b"\x1b[F".to_vec(),
        KeyCode::PageUp => b"\x1b[5~".to_vec(),
        KeyCode::PageDown => b"\x1b[6~".to_vec(),
        KeyCode::Insert => b"\x1b[2~".to_vec(),
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        KeyCode::F(n @ 1..=4) => format!("\x1bO{}", (b'P' + (n - 1)) as char).into_bytes(),
        KeyCode::F(n) => {
            // xterm "modifyOtherKeys"-ish CSI for F5..F12.
            let code = match n {
                5 => 15,
                6 => 17,
                7 => 18,
                8 => 19,
                9 => 20,
                10 => 21,
                11 => 23,
                12 => 24,
                _ => return Vec::new(),
            };
            format!("\x1b[{code}~").into_bytes()
        }
        _ => Vec::new(),
    }
}
