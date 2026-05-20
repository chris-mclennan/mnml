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
    // Workspace basename for the terminal-window title — picks up the
    // current project name so multiple mnml tabs are distinguishable
    // ("mnml — mnml", "mnml — tmnl", "mnml — private", …).
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
        // OSC 0/2 — sets the terminal window/tab title. Most terminals
        // (Apple Terminal, iTerm2, tmnl, Kitty, WezTerm, …) read this
        // and display the title in the tab strip. Falls back silently on
        // terminals that don't honor OSC sequences.
        SetTitle(title),
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

    loop {
        app.tick();
        if app.redraw_requested {
            app.redraw_requested = false;
            // Force a fresh paint over a cleared buffer (an external process
            // can leave the terminal in any state).
            term.clear()?;
        }
        term.draw(|f| ui::draw(f, app))?;
        emit_image_placements(app);
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

/// Drain `app.image_paint_requests` and emit the protocol-specific image
/// escapes directly to stdout. Called after `terminal.draw()` so the
/// images paint *on top of* the placeholder cells ratatui reserved.
///
/// Also handles clearing stale placements: when image panes disappear
/// (closed / scrolled out), we emit a `clear-all` so the previous
/// frame's images don't linger.
fn emit_image_placements(app: &mut App) {
    use crate::image::ImageProtocol;
    use std::io::Write;
    let protocol = app.image_protocol;
    if matches!(protocol, ImageProtocol::None) {
        app.image_paint_requests.clear();
        app.had_image_pane = false;
        return;
    }
    let pending = std::mem::take(&mut app.image_paint_requests);
    let any_now = !pending.is_empty();
    let needs_clear = any_now || app.had_image_pane;
    let mut out = io::stdout();
    if needs_clear && matches!(protocol, ImageProtocol::Kitty) {
        let _ = out.write_all(crate::image::kitty::clear_all().as_bytes());
    }
    for req in pending {
        // Move cursor to the area's top-left (1-based row;col).
        let _ = write!(
            out,
            "\x1b[{};{}H",
            req.area.y.saturating_add(1),
            req.area.x.saturating_add(1)
        );
        match protocol {
            ImageProtocol::Kitty => {
                if let Ok(esc) = crate::image::kitty::encode_placement(
                    &req.png_bytes,
                    req.area.width,
                    req.area.height,
                ) {
                    let _ = out.write_all(esc.as_bytes());
                }
            }
            ImageProtocol::Iterm2 => {
                let esc = crate::image::iterm2::encode_placement(
                    &req.png_bytes,
                    req.area.width,
                    req.area.height,
                );
                let _ = out.write_all(esc.as_bytes());
            }
            ImageProtocol::None => {}
        }
    }
    let _ = out.flush();
    app.had_image_pane = any_now;
}

// ─── key dispatch (shared with headless/IPC) ────────────────────────

pub fn dispatch_key(app: &mut App, key: KeyEvent) {
    // Any keystroke cancels a pending hover tooltip / divider highlight —
    // the user moved on to typing, the hover-cue is no longer relevant.
    app.hover_chip = None;
    app.hover_divider_idx = None;
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
        let bytes = pty_key_bytes(key);
        if !bytes.is_empty() {
            scratch.session.write_bytes(&bytes);
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
        // Tab on a picker → "secondary accept" — picker-specific behavior.
        // For the cross-host PR picker (`PickerKind::OpenPullRequests`)
        // this jumps to the PR's matching pipeline/build instead of
        // opening the URL. Other picker kinds ignore Tab.
        KeyCode::Tab => app.picker_accept_secondary(),
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
    // A git diff pane: `↑↓` and `n`/`p` jump between hunks (the user's
    // primary navigation); `j`/`k` scroll one row at a time;
    // `s`/`u` stage/unstage the cursor hunk; `r` refresh; Enter jumps
    // to the hunk in the source; Esc → tree. View-mode + wrap toggle
    // are surfaced via the top-of-pane toolbar buttons (click).
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
            return;
        }
        let in_split = d.view_mode == crate::pane::DiffViewMode::Split;
        match key.code {
            KeyCode::Char('/') => {
                d.filter.clear();
                d.filter_mode = true;
                return;
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
                // Tab inside Body inserts a literal `\t` (multi-line code-y
                // field — typing indented JSON / XML is common). Other
                // fields keep the form-cycle gesture so the user can walk
                // URL → Method → Headers → Body → URL.
                KeyCode::Tab if rp.focus == crate::request_pane::EditField::Body => {
                    rp.type_char('\t');
                }
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
    // Bitbucket pipelines browser: ↑↓/jk/PgUp/PgDn/g/G navigate every
    // row (headers selectable too), Enter → toggle collapse on a
    // header / open in browser on a data row, y → copy URL,
    // r → refresh, v → flip view-mode, Esc → tree.
    if matches!(app.panes.get(i), Some(Pane::BitbucketPipelines(_))) {
        // Flatten with the pane's actual view-mode — otherwise key
        // handlers look up rows in the wrong layout and Right/Left
        // mis-target headers in PerBranch mode.
        let flat = match app.bb_pipelines_view_mode {
            crate::bitbucket::PipelineViewMode::Recent => {
                crate::ui::bitbucket_pipelines_view::flatten_pipelines(app)
            }
            crate::bitbucket::PipelineViewMode::PerBranch => {
                crate::ui::bitbucket_pipelines_view::flatten_branch_pipelines(app)
            }
        };
        let max_idx = flat.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1, max_idx);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(1, max_idx);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64), max_idx);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64, max_idx);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2, max_idx);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2, max_idx);
                }
            }
            // Right (or `l`): expand a collapsed header.
            KeyCode::Right | KeyCode::Char('l') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::BitbucketPipelines(p)) => p.selected,
                    _ => 0,
                };
                if let Some(row) = flat.get(sel)
                    && row.kind == crate::ui::bitbucket_pipelines_view::RowKind::Header
                    && app.bb_pipelines_collapsed.contains(&row.header_label)
                {
                    app.bb_pipelines_collapsed.remove(&row.header_label);
                }
            }
            // Left (or `h`): on an expanded header → collapse; on a child
            // row → jump up to the parent header (tree convention).
            KeyCode::Left | KeyCode::Char('h') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::BitbucketPipelines(p)) => p.selected,
                    _ => 0,
                };
                let header_kind = crate::ui::bitbucket_pipelines_view::RowKind::Header;
                if let Some(row) = flat.get(sel) {
                    if row.kind == header_kind {
                        if !app.bb_pipelines_collapsed.contains(&row.header_label) {
                            app.bb_pipelines_collapsed.insert(row.header_label.clone());
                        }
                    } else {
                        let parent_idx = (0..sel)
                            .rev()
                            .find(|&j| flat.get(j).map(|r| r.kind == header_kind).unwrap_or(false));
                        if let Some(idx) = parent_idx
                            && let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(i)
                        {
                            p.selected = idx;
                        }
                    }
                }
            }
            KeyCode::Enter => {
                // Header row ⇒ toggle collapse. Data row ⇒ open URL.
                let sel = match app.panes.get(i) {
                    Some(Pane::BitbucketPipelines(p)) => p.selected,
                    _ => 0,
                };
                let header_label = flat
                    .get(sel)
                    .filter(|r| r.kind == crate::ui::bitbucket_pipelines_view::RowKind::Header)
                    .map(|r| r.header_label.clone());
                if let Some(label) = header_label {
                    let now_collapsed = if app.bb_pipelines_collapsed.contains(&label) {
                        app.bb_pipelines_collapsed.remove(&label);
                        false
                    } else {
                        app.bb_pipelines_collapsed.insert(label.clone());
                        true
                    };
                    app.toast(format!(
                        "{label}: {}",
                        if now_collapsed {
                            "collapsed"
                        } else {
                            "expanded"
                        }
                    ));
                } else {
                    app.open_selected_bitbucket_pipeline_url();
                }
            }
            KeyCode::Char('y') => app.copy_selected_bitbucket_pipeline_url(),
            KeyCode::Char('r') => app.refresh_active_bitbucket_pane(),
            KeyCode::Char('P') => app.jump_from_bb_pipeline_to_pr(),
            KeyCode::Char('L') => app.open_bitbucket_pipeline_log(),
            KeyCode::Char('v') => {
                let new_mode = app.bb_pipelines_view_mode.cycle();
                app.bb_pipelines_view_mode = new_mode;
                if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    p.scroll = 0;
                }
                app.toast(format!("bitbucket pipelines: view → {}", new_mode.label()));
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // Bitbucket pipeline-log viewer: scrollable text, no list selection.
    if matches!(app.panes.get(i), Some(Pane::BitbucketPipelineLog(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::BitbucketPipelineLog(p)) = app.panes.get_mut(i) {
                    p.scroll = p.scroll.saturating_sub(1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::BitbucketPipelineLog(p)) = app.panes.get_mut(i) {
                    p.scroll = p.scroll.saturating_add(1);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::BitbucketPipelineLog(p)) = app.panes.get_mut(i) {
                    p.scroll = p.scroll.saturating_sub(10);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::BitbucketPipelineLog(p)) = app.panes.get_mut(i) {
                    p.scroll = p.scroll.saturating_add(10);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::BitbucketPipelineLog(p)) = app.panes.get_mut(i) {
                    p.scroll = 0;
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::BitbucketPipelineLog(p)) = app.panes.get_mut(i) {
                    p.scroll = usize::MAX; // clamped on next render
                }
            }
            KeyCode::Char('r') => app.refetch_active_pipeline_log(),
            KeyCode::Char('y') => app.copy_active_pipeline_log_url(),
            KeyCode::Enter => app.open_active_pipeline_log_url(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // Bitbucket pull requests browser: same key shape as the pipelines
    // pane; Enter / y act on the row's PR URL.
    if matches!(app.panes.get(i), Some(Pane::BitbucketPullRequests(_))) {
        let flat = match app.bb_prs_view_mode {
            crate::bitbucket::PrViewMode::PerRepo => {
                crate::ui::bitbucket_pull_requests_view::flatten_prs(app)
            }
            crate::bitbucket::PrViewMode::Mine => {
                crate::ui::bitbucket_pull_requests_view::flatten_my_prs(app)
            }
        };
        let max_idx = flat.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1, max_idx);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(1, max_idx);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64), max_idx);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64, max_idx);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2, max_idx);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2, max_idx);
                }
            }
            KeyCode::Right | KeyCode::Char('l') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::BitbucketPullRequests(p)) => p.selected,
                    _ => 0,
                };
                if let Some(row) = flat.get(sel)
                    && row.kind == crate::ui::bitbucket_pull_requests_view::RowKind::Header
                    && app.bb_prs_collapsed.contains(&row.header_label)
                {
                    app.bb_prs_collapsed.remove(&row.header_label);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::BitbucketPullRequests(p)) => p.selected,
                    _ => 0,
                };
                let header_kind = crate::ui::bitbucket_pull_requests_view::RowKind::Header;
                if let Some(row) = flat.get(sel) {
                    if row.kind == header_kind {
                        if !app.bb_prs_collapsed.contains(&row.header_label) {
                            app.bb_prs_collapsed.insert(row.header_label.clone());
                        }
                    } else {
                        let parent_idx = (0..sel)
                            .rev()
                            .find(|&j| flat.get(j).map(|r| r.kind == header_kind).unwrap_or(false));
                        if let Some(idx) = parent_idx
                            && let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(i)
                        {
                            p.selected = idx;
                        }
                    }
                }
            }
            KeyCode::Enter => {
                let sel = match app.panes.get(i) {
                    Some(Pane::BitbucketPullRequests(p)) => p.selected,
                    _ => 0,
                };
                let header_label = flat
                    .get(sel)
                    .filter(|r| r.kind == crate::ui::bitbucket_pull_requests_view::RowKind::Header)
                    .map(|r| r.header_label.clone());
                if let Some(label) = header_label {
                    let now_collapsed = if app.bb_prs_collapsed.contains(&label) {
                        app.bb_prs_collapsed.remove(&label);
                        false
                    } else {
                        app.bb_prs_collapsed.insert(label.clone());
                        true
                    };
                    app.toast(format!(
                        "{label}: {}",
                        if now_collapsed {
                            "collapsed"
                        } else {
                            "expanded"
                        }
                    ));
                } else {
                    app.open_selected_bitbucket_pr_url();
                }
            }
            KeyCode::Char('y') => app.copy_selected_bitbucket_pr_url(),
            KeyCode::Char('r') => app.refresh_active_bitbucket_pane(),
            KeyCode::Char('c') => app.jump_from_bb_pr_to_pipeline(),
            KeyCode::Char('v') => {
                let new_mode = app.bb_prs_view_mode.cycle();
                app.bb_prs_view_mode = new_mode;
                if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    p.scroll = 0;
                }
                app.toast(format!("bitbucket prs: view → {}", new_mode.label()));
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // GitHub pull requests browser — sibling of the BB PR pane above.
    if matches!(app.panes.get(i), Some(Pane::GithubPullRequests(_))) {
        let flat = match app.gh_prs_view_mode {
            crate::github::GhPrViewMode::PerRepo => {
                crate::ui::github_pull_requests_view::flatten_prs(app)
            }
            crate::github::GhPrViewMode::Mine => {
                crate::ui::github_pull_requests_view::flatten_my_prs(app)
            }
        };
        let max_idx = flat.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1, max_idx);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(1, max_idx);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64), max_idx);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64, max_idx);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2, max_idx);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2, max_idx);
                }
            }
            KeyCode::Right | KeyCode::Char('l') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GithubPullRequests(p)) => p.selected,
                    _ => 0,
                };
                if let Some(row) = flat.get(sel)
                    && row.kind == crate::ui::github_pull_requests_view::RowKind::Header
                    && app.gh_prs_collapsed.contains(&row.header_label)
                {
                    app.gh_prs_collapsed.remove(&row.header_label);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GithubPullRequests(p)) => p.selected,
                    _ => 0,
                };
                let header_kind = crate::ui::github_pull_requests_view::RowKind::Header;
                if let Some(row) = flat.get(sel) {
                    if row.kind == header_kind {
                        if !app.gh_prs_collapsed.contains(&row.header_label) {
                            app.gh_prs_collapsed.insert(row.header_label.clone());
                        }
                    } else {
                        let parent_idx = (0..sel)
                            .rev()
                            .find(|&j| flat.get(j).map(|r| r.kind == header_kind).unwrap_or(false));
                        if let Some(idx) = parent_idx
                            && let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(i)
                        {
                            p.selected = idx;
                        }
                    }
                }
            }
            KeyCode::Enter => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GithubPullRequests(p)) => p.selected,
                    _ => 0,
                };
                let header_label = flat
                    .get(sel)
                    .filter(|r| r.kind == crate::ui::github_pull_requests_view::RowKind::Header)
                    .map(|r| r.header_label.clone());
                if let Some(label) = header_label {
                    let now_collapsed = if app.gh_prs_collapsed.contains(&label) {
                        app.gh_prs_collapsed.remove(&label);
                        false
                    } else {
                        app.gh_prs_collapsed.insert(label.clone());
                        true
                    };
                    app.toast(format!(
                        "{label}: {}",
                        if now_collapsed {
                            "collapsed"
                        } else {
                            "expanded"
                        }
                    ));
                } else {
                    app.open_selected_github_pr_url();
                }
            }
            KeyCode::Char('y') => app.copy_selected_github_pr_url(),
            KeyCode::Char('r') => app.refresh_active_github_pane(),
            KeyCode::Char('c') => app.jump_from_gh_pr_to_run(),
            KeyCode::Char('v') => {
                let new_mode = app.gh_prs_view_mode.cycle();
                app.gh_prs_view_mode = new_mode;
                if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    p.scroll = 0;
                }
                app.toast(format!("github prs: view → {}", new_mode.label()));
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // GitHub Actions browser: ↑↓/jk/PgUp/PgDn/g/G navigate (header rows
    // auto-skipped), Enter → open in browser, y → copy URL, r → refresh,
    // Esc → tree. Symmetric to the Bitbucket pane above.
    if matches!(app.panes.get(i), Some(Pane::GithubActions(_))) {
        let flat = match app.gh_actions_view_mode {
            crate::github::ActionsViewMode::Recent => {
                crate::ui::github_actions_view::flatten_runs(app)
            }
            crate::github::ActionsViewMode::PerBranch => {
                crate::ui::github_actions_view::flatten_branch_runs(app)
            }
        };
        let max_idx = flat.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::GithubActions(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1, max_idx);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::GithubActions(p)) = app.panes.get_mut(i) {
                    p.move_selection(1, max_idx);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::GithubActions(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64), max_idx);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::GithubActions(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64, max_idx);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::GithubActions(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2, max_idx);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::GithubActions(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2, max_idx);
                }
            }
            KeyCode::Right | KeyCode::Char('l') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GithubActions(p)) => p.selected,
                    _ => 0,
                };
                if let Some(row) = flat.get(sel)
                    && row.kind == crate::ui::github_actions_view::RowKind::Header
                    && app.gh_actions_collapsed.contains(&row.header_label)
                {
                    app.gh_actions_collapsed.remove(&row.header_label);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GithubActions(p)) => p.selected,
                    _ => 0,
                };
                let header_kind = crate::ui::github_actions_view::RowKind::Header;
                if let Some(row) = flat.get(sel) {
                    if row.kind == header_kind {
                        if !app.gh_actions_collapsed.contains(&row.header_label) {
                            app.gh_actions_collapsed.insert(row.header_label.clone());
                        }
                    } else {
                        let parent_idx = (0..sel)
                            .rev()
                            .find(|&j| flat.get(j).map(|r| r.kind == header_kind).unwrap_or(false));
                        if let Some(idx) = parent_idx
                            && let Some(Pane::GithubActions(p)) = app.panes.get_mut(i)
                        {
                            p.selected = idx;
                        }
                    }
                }
            }
            KeyCode::Enter => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GithubActions(p)) => p.selected,
                    _ => 0,
                };
                let header_label = flat
                    .get(sel)
                    .filter(|r| r.kind == crate::ui::github_actions_view::RowKind::Header)
                    .map(|r| r.header_label.clone());
                if let Some(label) = header_label {
                    let now_collapsed = if app.gh_actions_collapsed.contains(&label) {
                        app.gh_actions_collapsed.remove(&label);
                        false
                    } else {
                        app.gh_actions_collapsed.insert(label.clone());
                        true
                    };
                    app.toast(format!(
                        "{label}: {}",
                        if now_collapsed {
                            "collapsed"
                        } else {
                            "expanded"
                        }
                    ));
                } else {
                    app.open_selected_github_run_url();
                }
            }
            KeyCode::Char('y') => app.copy_selected_github_run_url(),
            KeyCode::Char('r') => app.refresh_active_github_pane(),
            KeyCode::Char('P') => app.jump_from_gh_run_to_pr(),
            KeyCode::Char('L') => app.open_github_run_log(),
            KeyCode::Char('v') => {
                let new_mode = app.gh_actions_view_mode.cycle();
                app.gh_actions_view_mode = new_mode;
                if let Some(Pane::GithubActions(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    p.scroll = 0;
                }
                app.toast(format!("github actions: view → {}", new_mode.label()));
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // GitLab pipelines browser — sibling of the BB/GH pipeline panes.
    if matches!(app.panes.get(i), Some(Pane::GitlabPipelines(_))) {
        let flat = match app.gl_pipelines_view_mode {
            crate::gitlab::GlPipelineViewMode::Recent => {
                crate::ui::gitlab_pipelines_view::flatten_pipelines(app)
            }
            crate::gitlab::GlPipelineViewMode::PerBranch => {
                crate::ui::gitlab_pipelines_view::flatten_branch_pipelines(app)
            }
        };
        let max_idx = flat.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1, max_idx);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(1, max_idx);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64), max_idx);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64, max_idx);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2, max_idx);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2, max_idx);
                }
            }
            KeyCode::Right | KeyCode::Char('l') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GitlabPipelines(p)) => p.selected,
                    _ => 0,
                };
                if let Some(row) = flat.get(sel)
                    && row.kind == crate::ui::gitlab_pipelines_view::RowKind::Header
                    && app.gl_pipelines_collapsed.contains(&row.header_label)
                {
                    app.gl_pipelines_collapsed.remove(&row.header_label);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GitlabPipelines(p)) => p.selected,
                    _ => 0,
                };
                let header_kind = crate::ui::gitlab_pipelines_view::RowKind::Header;
                if let Some(row) = flat.get(sel) {
                    if row.kind == header_kind {
                        if !app.gl_pipelines_collapsed.contains(&row.header_label) {
                            app.gl_pipelines_collapsed.insert(row.header_label.clone());
                        }
                    } else {
                        let parent_idx = (0..sel)
                            .rev()
                            .find(|&j| flat.get(j).map(|r| r.kind == header_kind).unwrap_or(false));
                        if let Some(idx) = parent_idx
                            && let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(i)
                        {
                            p.selected = idx;
                        }
                    }
                }
            }
            KeyCode::Enter => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GitlabPipelines(p)) => p.selected,
                    _ => 0,
                };
                let header_label = flat
                    .get(sel)
                    .filter(|r| r.kind == crate::ui::gitlab_pipelines_view::RowKind::Header)
                    .map(|r| r.header_label.clone());
                if let Some(label) = header_label {
                    let now_collapsed = if app.gl_pipelines_collapsed.contains(&label) {
                        app.gl_pipelines_collapsed.remove(&label);
                        false
                    } else {
                        app.gl_pipelines_collapsed.insert(label.clone());
                        true
                    };
                    app.toast(format!(
                        "{label}: {}",
                        if now_collapsed {
                            "collapsed"
                        } else {
                            "expanded"
                        }
                    ));
                } else {
                    app.open_selected_gitlab_pipeline_url();
                }
            }
            KeyCode::Char('y') => app.copy_selected_gitlab_pipeline_url(),
            KeyCode::Char('r') => app.refresh_active_gitlab_pane(),
            KeyCode::Char('P') => app.jump_from_gl_pipeline_to_mr(),
            KeyCode::Char('L') => app.open_gitlab_pipeline_log(),
            KeyCode::Char('v') => {
                let new_mode = app.gl_pipelines_view_mode.cycle();
                app.gl_pipelines_view_mode = new_mode;
                if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    p.scroll = 0;
                }
                app.toast(format!("gitlab pipelines: view → {}", new_mode.label()));
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // GitLab merge requests browser.
    if matches!(app.panes.get(i), Some(Pane::GitlabMergeRequests(_))) {
        let flat = match app.gl_mrs_view_mode {
            crate::gitlab::GlMrViewMode::PerProject => {
                crate::ui::gitlab_merge_requests_view::flatten_mrs(app)
            }
            crate::gitlab::GlMrViewMode::Mine => {
                crate::ui::gitlab_merge_requests_view::flatten_my_mrs(app)
            }
        };
        let max_idx = flat.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1, max_idx);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(1, max_idx);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64), max_idx);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64, max_idx);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2, max_idx);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2, max_idx);
                }
            }
            KeyCode::Right | KeyCode::Char('l') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GitlabMergeRequests(p)) => p.selected,
                    _ => 0,
                };
                if let Some(row) = flat.get(sel)
                    && row.kind == crate::ui::gitlab_merge_requests_view::RowKind::Header
                    && app.gl_mrs_collapsed.contains(&row.header_label)
                {
                    app.gl_mrs_collapsed.remove(&row.header_label);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GitlabMergeRequests(p)) => p.selected,
                    _ => 0,
                };
                let header_kind = crate::ui::gitlab_merge_requests_view::RowKind::Header;
                if let Some(row) = flat.get(sel) {
                    if row.kind == header_kind {
                        if !app.gl_mrs_collapsed.contains(&row.header_label) {
                            app.gl_mrs_collapsed.insert(row.header_label.clone());
                        }
                    } else {
                        let parent_idx = (0..sel)
                            .rev()
                            .find(|&j| flat.get(j).map(|r| r.kind == header_kind).unwrap_or(false));
                        if let Some(idx) = parent_idx
                            && let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(i)
                        {
                            p.selected = idx;
                        }
                    }
                }
            }
            KeyCode::Enter => {
                let sel = match app.panes.get(i) {
                    Some(Pane::GitlabMergeRequests(p)) => p.selected,
                    _ => 0,
                };
                let header_label = flat
                    .get(sel)
                    .filter(|r| r.kind == crate::ui::gitlab_merge_requests_view::RowKind::Header)
                    .map(|r| r.header_label.clone());
                if let Some(label) = header_label {
                    let now_collapsed = if app.gl_mrs_collapsed.contains(&label) {
                        app.gl_mrs_collapsed.remove(&label);
                        false
                    } else {
                        app.gl_mrs_collapsed.insert(label.clone());
                        true
                    };
                    app.toast(format!(
                        "{label}: {}",
                        if now_collapsed {
                            "collapsed"
                        } else {
                            "expanded"
                        }
                    ));
                } else {
                    app.open_selected_gitlab_mr_url();
                }
            }
            KeyCode::Char('y') => app.copy_selected_gitlab_mr_url(),
            KeyCode::Char('r') => app.refresh_active_gitlab_pane(),
            KeyCode::Char('c') => app.jump_from_gl_mr_to_pipeline(),
            KeyCode::Char('v') => {
                let new_mode = app.gl_mrs_view_mode.cycle();
                app.gl_mrs_view_mode = new_mode;
                if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    p.scroll = 0;
                }
                app.toast(format!("gitlab mrs: view → {}", new_mode.label()));
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // Azure DevOps builds browser — same shape as GL pipelines.
    if matches!(app.panes.get(i), Some(Pane::AzDevOpsBuilds(_))) {
        let flat = match app.az_builds_view_mode {
            crate::azdevops::AzBuildsViewMode::Recent => {
                crate::ui::azdevops_builds_view::flatten_builds(app)
            }
            crate::azdevops::AzBuildsViewMode::PerBranch => {
                crate::ui::azdevops_builds_view::flatten_branch_builds(app)
            }
        };
        let max_idx = flat.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1, max_idx);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(1, max_idx);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64), max_idx);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64, max_idx);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2, max_idx);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2, max_idx);
                }
            }
            KeyCode::Right | KeyCode::Char('l') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::AzDevOpsBuilds(p)) => p.selected,
                    _ => 0,
                };
                if let Some(row) = flat.get(sel)
                    && row.kind == crate::ui::azdevops_builds_view::RowKind::Header
                    && app.az_builds_collapsed.contains(&row.header_label)
                {
                    app.az_builds_collapsed.remove(&row.header_label);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::AzDevOpsBuilds(p)) => p.selected,
                    _ => 0,
                };
                let header_kind = crate::ui::azdevops_builds_view::RowKind::Header;
                if let Some(row) = flat.get(sel) {
                    if row.kind == header_kind {
                        if !app.az_builds_collapsed.contains(&row.header_label) {
                            app.az_builds_collapsed.insert(row.header_label.clone());
                        }
                    } else {
                        let parent_idx = (0..sel)
                            .rev()
                            .find(|&j| flat.get(j).map(|r| r.kind == header_kind).unwrap_or(false));
                        if let Some(idx) = parent_idx
                            && let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(i)
                        {
                            p.selected = idx;
                        }
                    }
                }
            }
            KeyCode::Enter => {
                let sel = match app.panes.get(i) {
                    Some(Pane::AzDevOpsBuilds(p)) => p.selected,
                    _ => 0,
                };
                let header_label = flat
                    .get(sel)
                    .filter(|r| r.kind == crate::ui::azdevops_builds_view::RowKind::Header)
                    .map(|r| r.header_label.clone());
                if let Some(label) = header_label {
                    let now_collapsed = if app.az_builds_collapsed.contains(&label) {
                        app.az_builds_collapsed.remove(&label);
                        false
                    } else {
                        app.az_builds_collapsed.insert(label.clone());
                        true
                    };
                    app.toast(format!(
                        "{label}: {}",
                        if now_collapsed {
                            "collapsed"
                        } else {
                            "expanded"
                        }
                    ));
                } else {
                    app.open_selected_azdevops_build_url();
                }
            }
            KeyCode::Char('y') => app.copy_selected_azdevops_build_url(),
            KeyCode::Char('r') => app.refresh_active_azdevops_pane(),
            KeyCode::Char('P') => app.jump_from_az_build_to_pr(),
            KeyCode::Char('L') => app.open_azdevops_build_log(),
            KeyCode::Char('v') => {
                let new_mode = app.az_builds_view_mode.cycle();
                app.az_builds_view_mode = new_mode;
                if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    p.scroll = 0;
                }
                app.toast(format!("azure builds: view → {}", new_mode.label()));
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // Azure DevOps pull requests browser.
    if matches!(app.panes.get(i), Some(Pane::AzDevOpsPullRequests(_))) {
        let flat = match app.az_prs_view_mode {
            crate::azdevops::AzPrViewMode::PerRepo => {
                crate::ui::azdevops_pull_requests_view::flatten_prs(app)
            }
            crate::azdevops::AzPrViewMode::Mine => {
                crate::ui::azdevops_pull_requests_view::flatten_my_prs(app)
            }
        };
        let max_idx = flat.len();
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1, max_idx);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(1, max_idx);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64), max_idx);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64, max_idx);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2, max_idx);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2, max_idx);
                }
            }
            KeyCode::Right | KeyCode::Char('l') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::AzDevOpsPullRequests(p)) => p.selected,
                    _ => 0,
                };
                if let Some(row) = flat.get(sel)
                    && row.kind == crate::ui::azdevops_pull_requests_view::RowKind::Header
                    && app.az_prs_collapsed.contains(&row.header_label)
                {
                    app.az_prs_collapsed.remove(&row.header_label);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                let sel = match app.panes.get(i) {
                    Some(Pane::AzDevOpsPullRequests(p)) => p.selected,
                    _ => 0,
                };
                let header_kind = crate::ui::azdevops_pull_requests_view::RowKind::Header;
                if let Some(row) = flat.get(sel) {
                    if row.kind == header_kind {
                        if !app.az_prs_collapsed.contains(&row.header_label) {
                            app.az_prs_collapsed.insert(row.header_label.clone());
                        }
                    } else {
                        let parent_idx = (0..sel)
                            .rev()
                            .find(|&j| flat.get(j).map(|r| r.kind == header_kind).unwrap_or(false));
                        if let Some(idx) = parent_idx
                            && let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(i)
                        {
                            p.selected = idx;
                        }
                    }
                }
            }
            KeyCode::Enter => {
                let sel = match app.panes.get(i) {
                    Some(Pane::AzDevOpsPullRequests(p)) => p.selected,
                    _ => 0,
                };
                let header_label = flat
                    .get(sel)
                    .filter(|r| r.kind == crate::ui::azdevops_pull_requests_view::RowKind::Header)
                    .map(|r| r.header_label.clone());
                if let Some(label) = header_label {
                    let now_collapsed = if app.az_prs_collapsed.contains(&label) {
                        app.az_prs_collapsed.remove(&label);
                        false
                    } else {
                        app.az_prs_collapsed.insert(label.clone());
                        true
                    };
                    app.toast(format!(
                        "{label}: {}",
                        if now_collapsed {
                            "collapsed"
                        } else {
                            "expanded"
                        }
                    ));
                } else {
                    app.open_selected_azdevops_pr_url();
                }
            }
            KeyCode::Char('y') => app.copy_selected_azdevops_pr_url(),
            KeyCode::Char('r') => app.refresh_active_azdevops_pane(),
            KeyCode::Char('c') => app.jump_from_az_pr_to_build(),
            KeyCode::Char('v') => {
                let new_mode = app.az_prs_view_mode.cycle();
                app.az_prs_view_mode = new_mode;
                if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(i) {
                    p.selected = 0;
                    p.scroll = 0;
                }
                app.toast(format!("azure prs: view → {}", new_mode.label()));
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }

    // the private integration CodeBuilds browser (cfg-gated): ↑↓ select, Enter open URL,
    // y copy URL, r refresh, Esc → tree.
    #[cfg(feature = "private")]
    if matches!(app.panes.get(i), Some(Pane::CodeBuilds(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::CodeBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::CodeBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(1);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::CodeBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64));
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::CodeBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::CodeBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::CodeBuilds(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2);
                }
            }
            KeyCode::Enter => app.open_selected_codebuild_url(),
            KeyCode::Char('y') => app.copy_selected_codebuild_url(),
            KeyCode::Char('t') => app.tail_selected_codebuild_logs(),
            KeyCode::Char('T') => app.tail_selected_codebuild_logs_classified(),
            KeyCode::Char('x') => app.show_test_executions_for_selected_build(),
            KeyCode::Char('r') => app.refresh_active_codebuilds(),
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // the private integration LogTailPane — scrollable + severity-colored aws-logs tail.
    #[cfg(feature = "private")]
    if matches!(app.panes.get(i), Some(Pane::LogTail(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::LogTail(p)) = app.panes.get_mut(i) {
                    if p.scroll == usize::MAX {
                        p.scroll = p.lines.len().saturating_sub(1);
                    }
                    p.scroll = p.scroll.saturating_sub(1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::LogTail(p)) = app.panes.get_mut(i)
                    && p.scroll != usize::MAX
                {
                    p.scroll = p.scroll.saturating_add(1);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::LogTail(p)) = app.panes.get_mut(i) {
                    if p.scroll == usize::MAX {
                        p.scroll = p.lines.len().saturating_sub(1);
                    }
                    p.scroll = p.scroll.saturating_sub(10);
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::LogTail(p)) = app.panes.get_mut(i)
                    && p.scroll != usize::MAX
                {
                    p.scroll = p.scroll.saturating_add(10);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::LogTail(p)) = app.panes.get_mut(i) {
                    p.scroll = 0;
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::LogTail(p)) = app.panes.get_mut(i) {
                    p.scroll = usize::MAX;
                }
            }
            KeyCode::Char('F') => {
                // Toggle follow-the-tail mode.
                if let Some(Pane::LogTail(p)) = app.panes.get_mut(i) {
                    p.scroll = if p.scroll == usize::MAX {
                        p.lines.len().saturating_sub(1)
                    } else {
                        usize::MAX
                    };
                }
            }
            KeyCode::Esc => app.focus_tree(),
            _ => {}
        }
        return;
    }
    // the private integration TestExecutions browser (cfg-gated): ↑↓ move within the active
    // env column, ←→ cycle column (Dev/Staging/Prod), Esc → tree.
    #[cfg(feature = "private")]
    if matches!(app.panes.get(i), Some(Pane::TestExecutions(_))) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(i) {
                    p.move_selection(-1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(i) {
                    p.move_selection(1);
                }
            }
            KeyCode::PageUp => {
                if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(i) {
                    p.move_selection(-(viewport as i64));
                }
            }
            KeyCode::PageDown => {
                if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(i) {
                    p.move_selection(viewport as i64);
                }
            }
            KeyCode::Home | KeyCode::Char('g') => {
                if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MIN / 2);
                }
            }
            KeyCode::End | KeyCode::Char('G') => {
                if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(i) {
                    p.move_selection(i64::MAX / 2);
                }
            }
            KeyCode::Left | KeyCode::Char('h') => {
                if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(i) {
                    p.move_column(-1);
                }
            }
            KeyCode::Right | KeyCode::Char('l') => {
                if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(i) {
                    p.move_column(1);
                }
            }
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
                && is_abbreviation_trigger(c)
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
        BufferEvent::App(cmd) => apply_app_command(app, cmd),
        BufferEvent::Unhandled(k) => {
            // Not text-editing. Esc releases focus to the tree; the rest (config-
            // driven keymap → command resolver) lands with the keymap work in P3.
            if k.code == KeyCode::Esc {
                app.focus_tree();
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
        record_dot(
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

/// Update [`App::dot_recording`] / [`App::dot_keys`] based on the mode +
/// chord-state transition this dispatch caused. The recording starts
/// when a "change" begins and finalizes when it ends. Boundaries:
///
/// - Normal + no chord pending → Insert ⇒ start recording (this `key`).
/// - Normal + no chord pending → Normal + chord pending (e.g. `d` from
///   normal opens operator-pending) ⇒ start recording.
/// - During recording (chord still pending OR in Insert) ⇒ append.
/// - End of recording: chord cleared and (mode is Normal OR back from
///   Insert), AND a buffer mutation occurred ⇒ finalize into `dot_keys`.
/// - End of recording with no mutation (e.g. user `Esc`'d the operator
///   before completing it) ⇒ discard.
/// - One-shot Normal-mode mutation with no chord (e.g. `p`) ⇒ record this
///   `key` and finalize immediately.
fn record_dot(
    app: &mut crate::app::App,
    key: KeyEvent,
    mode_before: Option<crate::input::EditingMode>,
    mode_after: Option<crate::input::EditingMode>,
    pending_before: Option<String>,
    pending_after: Option<String>,
    edited: bool,
) {
    use crate::input::EditingMode;
    let (Some(before), Some(after)) = (mode_before, mode_after) else {
        return;
    };
    let recording = app.dot_recording.is_some();
    // 1. Already recording — append. Then check if we just finalized.
    if recording {
        if let Some(rec) = &mut app.dot_recording {
            rec.push(key);
        }
        if edited {
            app.dot_recording_saw_edit = true;
        }
        let in_flight = after == EditingMode::Insert || pending_after.is_some();
        if !in_flight {
            // Recording terminated. If any earlier keystroke in the
            // session produced a mutation, finalize. Otherwise discard
            // (the chord was cancelled — e.g. ESC out of operator-pending).
            if app.dot_recording_saw_edit {
                if let Some(rec) = app.dot_recording.take() {
                    app.dot_keys = rec;
                }
            } else {
                app.dot_recording = None;
            }
            app.dot_recording_saw_edit = false;
        }
        return;
    }
    // 2. Not currently recording — does this key start a new change?
    let in_flight_after = after == EditingMode::Insert || pending_after.is_some();
    let started_change =
        before == EditingMode::Normal && pending_before.is_none() && in_flight_after;
    if started_change {
        app.dot_recording = Some(vec![key]);
        app.dot_recording_saw_edit = edited;
        return;
    }
    // 3. Visual → Insert (visual `c`) starts a change too.
    if before == EditingMode::Visual && after == EditingMode::Insert {
        app.dot_recording = Some(vec![key]);
        app.dot_recording_saw_edit = edited;
        return;
    }
    // 4. One-shot Normal-mode mutation (`p`, `~`, `u`, etc.) — record the
    //    single key and finalize.
    if before == EditingMode::Normal
        && after == EditingMode::Normal
        && pending_before.is_none()
        && pending_after.is_none()
        && edited
    {
        app.dot_keys = vec![key];
    }
    // 5. Visual op (e.g. `vlld`) ⇒ also a one-shot capture.
    if before == EditingMode::Visual && after == EditingMode::Normal && edited {
        app.dot_keys = vec![key];
    }
}

/// Vim abbreviation trigger: chars that "complete" the previous word and
/// signal expansion. Roughly: whitespace + most punctuation. Letters /
/// digits / `_` are *not* triggers (they keep the word in flight).
fn is_abbreviation_trigger(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '.' | ',' | ';' | ':' | '!' | '?' | ')' | ']' | '}' | '"' | '\'' | '`'
        )
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
        ExCommand(s) => {
            // Push onto persistent ex history (de-duped against newest,
            // capped at 100). The handler-side history mirror is updated
            // on launch from `App.ex_history` via `set_ex_history`.
            if app.ex_history.last() != Some(&s) {
                app.ex_history.push(s.clone());
                if app.ex_history.len() > 100 {
                    let drop = app.ex_history.len() - 100;
                    app.ex_history.drain(..drop);
                }
            }
            app.run_ex_command(&s);
        }
        RunCommand(id) => {
            command::run(&id, app);
        }
        SetMark(c) => app.set_mark_at_cursor(c),
        JumpToMarkLine(c) => app.jump_to_mark(c, false),
        JumpToMarkExact(c) => app.jump_to_mark(c, true),
        MacroRecordInto(c) => {
            app.set_pending_macro_register(c);
            app.macro_toggle();
        }
        MacroReplayFrom(c) => {
            app.set_pending_macro_register(c);
            app.macro_replay();
        }
        BlockInsertStart { append } => app.block_insert_start(append),
        BlockChangeStart => app.block_change_start(),
        CmdlineTabComplete => app.cmdline_tab_complete(),
        RepeatInsertStart { count, above } => app.repeat_insert_start(count as usize, above),
        FlashStart(a, b) => app.flash_start(a, b),
    }
}

// ─── mouse dispatch (shared with headless/IPC) ──────────────────────

/// Translate a click within an editor pane's text rect to a `(file_row,
/// file_col)`. Wrap-aware: when `[ui] wrap` is on, the visible row is
/// walked via [`Buffer::wrap_to_file_pos`] so clicks inside a wrapped
/// continuation land on the right char column. With wrap off this is
/// the classic `visible_to_file_row` + `h_scroll` mapping.
fn click_to_file_pos(
    b: &crate::buffer::Buffer,
    tr: Rect,
    wrap: bool,
    x: u16,
    y: u16,
) -> (usize, usize) {
    let visible_row = (y.saturating_sub(tr.y)) as usize;
    let click_col = (x.saturating_sub(tr.x)) as usize;
    let tw = tr.width as usize;
    if wrap && tw > 0 {
        let (row, char_start) = b
            .wrap_to_file_pos(b.scroll, visible_row, tw)
            .unwrap_or((b.scroll, 0));
        (row, char_start + click_col)
    } else {
        let row = b
            .visible_to_file_row(b.scroll, visible_row)
            .unwrap_or(b.scroll);
        (row, b.h_scroll + click_col)
    }
}

/// Which clickable statusline chip (if any) sits under the given mouse coords.
/// Used by the hover-tooltip system; right-click + left-click handlers do their
/// own per-chip rect checks since they need to act, not just identify.
fn hover_chip_at(app: &App, x: u16, y: u16) -> Option<crate::HoverChip> {
    if let Some(r) = app.rects.statusline_mode_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineMode);
    }
    if let Some(r) = app.rects.statusline_branch_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineBranch);
    }
    if let Some(r) = app.rects.statusline_workspace_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineWorkspace);
    }
    if let Some(r) = app.rects.statusline_clock_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineClock);
    }
    if let Some(r) = app.rects.statusline_lsp_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineLsp);
    }
    if let Some(r) = app.rects.statusline_wrap_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineWrap);
    }
    if let Some(r) = app.rects.statusline_autosave_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineAutosave);
    }
    if let Some(r) = app.rects.statusline_filesize_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineFilesize);
    }
    if let Some(r) = app.rects.statusline_lncol_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineLnCol);
    }
    if let Some(&(_, action)) = app
        .rects
        .rail_git_header_buttons
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::RailHeaderChip(action));
    }
    if let Some(&(_, pid)) = app
        .rects
        .bufferline_tabs
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::BufferlineTab(pid));
    }
    if let Some(&(_, _, action)) = app
        .rects
        .diff_toolbar_buttons
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::DiffToolbar(action));
    }
    if app
        .rects
        .fold_chips
        .iter()
        .any(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::FoldChip);
    }
    if app
        .rects
        .code_lens_chips
        .iter()
        .any(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::CodeLensChip);
    }
    None
}

pub fn dispatch_mouse(app: &mut App, m: MouseEvent) {
    let (x, y) = (m.column, m.row);

    // Hover-tooltip tracking — `MouseEventKind::Moved` (no button) updates
    // which clickable chip the mouse is over; the overlay renders after a
    // 500ms stable hover. Compute the chip at (x, y) and stash on `App`.
    // A move OFF every chip clears the hover; click + key events also clear
    // it (handled elsewhere).
    if matches!(m.kind, MouseEventKind::Moved) {
        let now = std::time::Instant::now();
        let new_chip = hover_chip_at(app, x, y);
        let prev_chip = app.hover_chip.map(|(c, _)| c);
        if new_chip != prev_chip {
            app.hover_chip = new_chip.map(|c| (c, now));
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
        return;
    }

    // Welcome overlay — any left-click dismisses + persists the marker.
    if app.show_welcome
        && matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
    {
        app.dismiss_welcome();
        return;
    }
    // Discovery overlay — intercept clicks on its rows so the user can
    // flash the matching on-screen rects. A click outside the panel
    // closes the overlay (so it can't trap the user).
    if app.show_discovery_overlay
        && matches!(m.kind, MouseEventKind::Down(MouseButton::Left))
    {
        if let Some(&(_, cat)) = app
            .rects
            .discovery_rows
            .iter()
            .find(|(r, _)| contains(*r, x, y))
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
        if contains(strip, x, y) {
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
                    .find(|(r, _)| contains(*r, x, y))
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
            .find(|(r, _)| contains(*r, x, y))
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
            .find(|(r, _)| contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        let wrap = app.config.ui.wrap;
        let vp = tr.height as usize;
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            let (row, col) = click_to_file_pos(b, tr, wrap, x, y);
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
            // Right-click on a statusline chip — context menus for the four
            // clickable chips (branch / workspace / mode / clock).
            if let Some(r) = app.rects.statusline_branch_chip
                && contains(r, x, y)
            {
                app.open_statusline_branch_context_menu((x, y));
                return;
            }
            if let Some(r) = app.rects.statusline_workspace_chip
                && contains(r, x, y)
            {
                app.open_statusline_workspace_context_menu((x, y));
                return;
            }
            if let Some(r) = app.rects.statusline_mode_chip
                && contains(r, x, y)
            {
                app.open_statusline_mode_context_menu((x, y));
                return;
            }
            if let Some(r) = app.rects.statusline_clock_chip
                && contains(r, x, y)
            {
                app.open_statusline_clock_context_menu((x, y));
                return;
            }
            // Right-click on the `> WORKSPACE` header → workspace menu.
            if let Some(tr) = app.rects.tree_toggle
                && contains(tr, x, y)
            {
                app.open_workspace_header_context_menu((x, y));
                return;
            }
            // Right-click on an extra-workspace header → that workspace's menu.
            if let Some(&(_, ws_idx)) = app
                .rects
                .extra_workspace_toggles
                .iter()
                .find(|(r, _)| contains(*r, x, y))
            {
                app.open_extra_workspace_header_context_menu(ws_idx, (x, y));
                return;
            }
            // Right-click on a Request pane URL/Method/Headers/Body row →
            // copy-as-curl / send / toggle view.
            if app
                .rects
                .request_fields
                .iter()
                .any(|(r, _, _)| contains(*r, x, y))
            {
                app.open_request_url_context_menu((x, y));
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
            // Right-click on an editor gutter → per-line menu (toggle BP /
            // goto def / refs / blame / browse line). Translate the click
            // y into a file row using the pane's current scroll.
            if let Some(&(gr, pid)) = app
                .rects
                .editor_gutters
                .iter()
                .find(|(r, _)| contains(*r, x, y))
            {
                let row_in_pane = (y - gr.y) as usize;
                let line = match app.panes.get(pid) {
                    Some(Pane::Editor(b)) => b.scroll + row_in_pane,
                    _ => row_in_pane,
                };
                app.open_editor_gutter_context_menu(pid, line as u32, (x, y));
                return;
            }
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
                .find(|(r, _, _)| contains(*r, x, y))
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
            // Grab a scrollbar (editor / diff / embedded-diff) before
            // any pane-level handler — the bar sits inside the pane's
            // own rect, so without this short-circuit a click on the
            // bar would also land in the editor / row-select handlers
            // below and shift the cursor / row selection.
            if app.begin_scrollbar_drag(x, y) {
                return;
            }
            // Grab the rail's right-edge handle? (cheaper / more specific
            // than a split divider — try this first.)
            if app.begin_tree_edge_drag(x, y) {
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
                .find(|(r, _, _)| contains(*r, x, y))
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
                .find(|(r, _, _)| contains(*r, x, y))
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
                .find(|(r, _, _)| contains(*r, x, y))
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
                .find(|(r, _, _, _)| contains(*r, x, y))
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
                && contains(r, x, y)
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
                .find(|(r, _, _)| contains(*r, x, y))
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
                .find(|(r, _, _, _)| contains(*r, x, y))
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
                .find(|(r, _, _)| contains(*r, x, y))
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
                .find(|(r, _, _)| contains(*r, x, y))
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
                .find(|(r, _, _)| contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
                    rp.view = view;
                }
                return;
            }
            // Click on a request-pane Edit-mode field row → focus that field.
            if let Some(&(_, pid, field)) = app
                .rects
                .request_fields
                .iter()
                .find(|(r, _, _)| contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
                    rp.view = crate::request_pane::ViewMode::Edit;
                    rp.focus = field;
                }
                return;
            }
            // Bufferline overflow chevrons — scroll the tab strip by one.
            if let Some(r) = app.rects.bufferline_overflow_left
                && contains(r, x, y)
            {
                if app.bufferline_first_visible > 0 {
                    app.bufferline_first_visible -= 1;
                }
                return;
            }
            if let Some(r) = app.rects.bufferline_overflow_right
                && contains(r, x, y)
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
            // Bufferline right cluster — `+` new tab, per-tabpage chip / close,
            // theme toggle, window close. Order matters (the `⊗` rect sits
            // adjacent to its chip; check close before chip).
            if let Some(r) = app.rects.bufferline_new_tab_button
                && contains(r, x, y)
            {
                app.tab_new(None);
                return;
            }
            if let Some(&(_, idx)) = app
                .rects
                .bufferline_tab_page_close
                .iter()
                .find(|(r, _)| contains(*r, x, y))
            {
                app.tab_close_at(idx);
                return;
            }
            if let Some(&(_, idx)) = app
                .rects
                .bufferline_tab_page_chips
                .iter()
                .find(|(r, _)| contains(*r, x, y))
            {
                app.switch_tab(idx);
                // Arm a drag — a subsequent mouse-drag over a
                // different chip's rect swaps the two tabs.
                app.dragging_tab_page = Some(app.active_layout);
                return;
            }
            if let Some(r) = app.rects.bufferline_theme_toggle
                && contains(r, x, y)
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
                && contains(r, x, y)
            {
                app.close_active_pane();
                return;
            }
            // Statusline branch chip → open the commit graph. Always-visible
            // click target for git.graph (vs the keyboard-only `<leader>g l`).
            if let Some(r) = app.rects.statusline_branch_chip
                && contains(r, x, y)
            {
                let _ = crate::command::run("git.graph", app);
                return;
            }
            // Statusline mode chip → toggle input style (vim ↔ standard).
            if let Some(r) = app.rects.statusline_mode_chip
                && contains(r, x, y)
            {
                let _ = crate::command::run("editor.toggle_keymap", app);
                return;
            }
            // Statusline workspace / active-repo chip → open the repo picker
            // (single-repo workspace toasts "only one repo").
            if let Some(r) = app.rects.statusline_workspace_chip
                && contains(r, x, y)
            {
                app.open_repo_picker();
                return;
            }
            // Statusline clock chip → flip between local and UTC.
            if let Some(r) = app.rects.statusline_clock_chip
                && contains(r, x, y)
            {
                app.clock_show_utc = !app.clock_show_utc;
                app.toast(if app.clock_show_utc {
                    "clock: UTC"
                } else {
                    "clock: local"
                });
                return;
            }
            // LSP chip → :LspStatus toast (breakdown of running servers).
            if let Some(r) = app.rects.statusline_lsp_chip
                && contains(r, x, y)
            {
                app.run_ex_command("LspStatus");
                return;
            }
            // WRAP chip → toggle `[ui] wrap`.
            if let Some(r) = app.rects.statusline_wrap_chip
                && contains(r, x, y)
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
                && contains(r, x, y)
            {
                app.toast(format!(
                    "autosave: {}s (`:set autosave_secs=N` to change)",
                    app.config.editor.autosave_secs
                ));
                return;
            }
            // Filesize chip → :Stat toast.
            if let Some(r) = app.rects.statusline_filesize_chip
                && contains(r, x, y)
            {
                app.run_ex_command("Stat");
                return;
            }
            // Ln/Col chip → goto-line prompt.
            if let Some(r) = app.rects.statusline_lncol_chip
                && contains(r, x, y)
            {
                let _ = crate::command::run("editor.goto_line", app);
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
            // GIT header right-aligned chip cluster — Fetch / Pull / Push /
            // Stage all / Commit / Graph. Check BEFORE the toggle so the
            // chip wins over the section-collapse gesture.
            if let Some(&(_, action)) = app
                .rects
                .rail_git_header_buttons
                .iter()
                .find(|(r, _)| contains(*r, x, y))
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
                .find(|(r, _)| contains(*r, x, y))
            {
                if let Some(cur) = app.active
                    && let Some(crate::pane::Pane::GitGraph(g)) = app.panes.get_mut(cur)
                {
                    g.cycle_sort(col);
                }
                return;
            }
            // The `> GIT` section header — same idea for the git rail.
            if let Some(tr) = app.rects.git_section_toggle
                && contains(tr, x, y)
            {
                app.toggle_git_section_expanded();
                return;
            }
            // Extra-workspace section header → toggle expansion.
            if let Some(&(_, ws_idx)) = app
                .rects
                .extra_workspace_toggles
                .iter()
                .find(|(r, _)| contains(*r, x, y))
            {
                app.toggle_extra_workspace(ws_idx);
                return;
            }
            // Extra-workspace row click → focus / select / open in that tree.
            if let Some(&(tr, ws_idx, scroll)) = app
                .rects
                .extra_workspace_bodies
                .iter()
                .find(|(r, _, _)| contains(*r, x, y))
            {
                let row_idx = (y - tr.y) as usize + scroll;
                app.click_extra_workspace_row(ws_idx, row_idx);
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
                        // Arm a drag — the source is captured here; the
                        // actual move happens on mouse-up over a different
                        // directory row.
                        if let Some(row) = app.tree.selected_row() {
                            app.begin_tree_drag(row.path.clone(), row.is_dir, y);
                        }
                        if let Some(row) = app.tree.selected_row() {
                            if row.is_dir {
                                // Multi-repo workspace: clicking a depth-0
                                // repo dir also switches the active repo
                                // (so the git rail / branches / PRs follow
                                // the user's focus). The dir then expands /
                                // collapses normally.
                                if row.depth == 0 && app.repos.len() > 1 {
                                    let repo_hit =
                                        app.repos.iter().position(|r| r.path == row.path);
                                    if let Some(idx) = repo_hit
                                        && idx != app.active_repo
                                    {
                                        app.switch_active_repo(idx);
                                    }
                                }
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
            // SCM/CI pane row click? Match before the generic editor-pane
            // handler since these panes also register editor-pane rects.
            // Single click: focus + select that row. If it's a header,
            // toggle collapse (sibling to Enter). Double-click on a data
            // row: open in browser.
            if let Some(&(_, pid, flat_idx)) = app
                .rects
                .list_rows
                .iter()
                .find(|(r, _, _)| contains(*r, x, y))
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
                handle_scm_row_click(app, pid, flat_idx, count >= 2);
                return;
            }

            // TestExecutions pane row click. Multi-env column layout — the
            // row registry records env-idx + row-index per visible record
            // (and a sentinel for column headers).
            #[cfg(feature = "private")]
            if let Some(&(_, pid, env_idx, row_idx)) = app
                .rects
                .test_executions_rows
                .iter()
                .find(|(r, _, _, _)| contains(*r, x, y))
            {
                app.active = Some(pid);
                app.focus_pane();
                handle_test_executions_row_click(app, pid, env_idx, row_idx);
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
                // Alt+click → add an extra cursor at the clicked position
                // (VS Code convention). Skips the focus / drag-arm path so
                // the existing primary stays put.
                if m.modifiers.contains(KeyModifiers::ALT) {
                    let wrap = app.config.ui.wrap;
                    if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                        let (row, col) = click_to_file_pos(b, tr, wrap, x, y);
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
                    let (row, col) = click_to_file_pos(b, tr, wrap, x, y);
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
            // Tree drag — arm if armed, update target idx. Runs alongside
            // the other drag handlers since it doesn't conflict (the tree
            // drag only fires on tree rect coordinates).
            if app.tree_drag.is_some() {
                if let Some(tr) = app.rects.tree
                    && contains(tr, x, y)
                {
                    let idx = (y - tr.y) as usize + app.rects.tree_scroll;
                    let target = (idx < app.tree.visible_rows().len()).then_some(idx);
                    app.drag_tree_to(target, y);
                } else {
                    app.drag_tree_to(None, y);
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
                    .find(|(r, _)| contains(*r, x, y))
                    .map(|(_, idx)| *idx);
                if let Some(dst) = dst
                    && dst != src
                {
                    app.tab_swap(src, dst);
                    app.dragging_tab_page = Some(dst);
                }
                return;
            }
            if app.dragging_scrollbar.is_some() {
                app.drag_scrollbar_to(y);
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
            } else if let Some((pid, ox, oy, armed)) = app.drag_select {
                // Editor drag-select: drop the anchor at the click origin
                // (first drag only), then extend the cursor to the current
                // mouse position.
                let wrap = app.config.ui.wrap;
                if let Some(&(tr, p2)) = app
                    .rects
                    .editor_panes
                    .iter()
                    .find(|(r, _)| contains(*r, x, y))
                    && p2 == pid
                    && let Some(Pane::Editor(b)) = app.panes.get_mut(pid)
                {
                    let (row, col) = click_to_file_pos(b, tr, wrap, x, y);
                    if !armed {
                        b.editor.place_cursor(oy, ox);
                        b.editor.apply(
                            crate::edit_op::EditOp::SelectStart,
                            tr.height as usize,
                            &mut app.clipboard,
                        );
                        app.drag_select = Some((pid, ox, oy, true));
                    }
                    b.editor.place_cursor(row, col);
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
            // Tree drag-drop — complete the move if armed.
            if let Some(tr) = app.rects.tree
                && contains(tr, x, y)
            {
                let idx = (y - tr.y) as usize + app.rects.tree_scroll;
                let target = (idx < app.tree.visible_rows().len()).then_some(idx);
                app.end_tree_drag(target);
            } else {
                // Released outside tree → cancel any in-flight drag.
                app.tree_drag = None;
            }
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
    // Wheel over an extra workspace's tree body (the file list under
    // `> name`) → scroll that extra's tree cursor.
    if let Some(&(_, ws_idx, _)) = app
        .rects
        .extra_workspace_bodies
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        if let Some(ws) = app.extra_workspaces.get_mut(ws_idx) {
            for _ in 0..delta.unsigned_abs() {
                if delta < 0 {
                    ws.tree.move_up();
                } else {
                    ws.tree.move_down();
                }
            }
        }
        return;
    }
    // Wheel over the GIT section header → cycle the active repo in
    // multi-repo workspaces (no-op when there's only one repo, so the
    // wheel falls through to the next rect). Up = previous, Down = next
    // — matches the bufferline / tab-strip wheel convention.
    if let Some(hr) = app.rects.git_section_toggle
        && contains(hr, x, y)
        && app.repos.len() > 1
    {
        app.cycle_active_repo(delta > 0);
        return;
    }
    // Wheel over any row in the GIT section → scroll the git rail cursor.
    if app
        .rects
        .git_rail_rows
        .iter()
        .any(|(r, _)| contains(*r, x, y))
    {
        for _ in 0..delta.unsigned_abs() {
            if delta < 0 {
                app.git_rail_move_up();
            } else {
                app.git_rail_move_down();
            }
        }
        return;
    }
    // Wheel over the bufferline → scroll the tab strip by one per tick.
    if let Some(br) = app.rects.bufferline
        && contains(br, x, y)
    {
        if delta < 0 {
            app.bufferline_first_visible = app.bufferline_first_visible.saturating_sub(1);
        } else if app.bufferline_first_visible + 1 < app.panes.len() {
            app.bufferline_first_visible += 1;
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
                // Wheel over the embedded diff (file picked from the
                // right-side detail panel) scrolls the diff body
                // instead of moving the commit-list selection.
                if let Some(d) = g.embedded_diff.as_mut() {
                    let n = delta.unsigned_abs() as usize;
                    d.scroll = if delta < 0 {
                        d.scroll.saturating_sub(n)
                    } else {
                        d.scroll + n
                    };
                } else {
                    g.move_selection(if delta < 0 {
                        -(delta.unsigned_abs() as isize)
                    } else {
                        delta.unsigned_abs() as isize
                    });
                }
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
                let step = if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                };
                if b.dom_focus {
                    b.move_dom_sel(step);
                } else if b.net_focus {
                    b.move_net_sel(step);
                } else if b.cookies_focus {
                    b.move_cookies_sel(step);
                } else if b.storage_focus {
                    b.move_storage_sel(step);
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
            Some(Pane::CmdlineHistory(h)) => {
                h.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Quickfix(g)) => {
                g.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            #[cfg(feature = "private")]
            Some(Pane::TestExecutions(p)) => {
                p.move_selection(delta as i64);
            }
            #[cfg(feature = "private")]
            Some(Pane::CodeBuilds(p)) => {
                p.move_selection(delta as i64);
            }
            #[cfg(feature = "private")]
            Some(Pane::LogTail(p)) => {
                let n = delta.unsigned_abs() as usize;
                // Wheel-up = scroll up; if we were following (Max), break
                // out into a fixed position near the bottom so the user
                // can read older lines without the tail snapping back.
                if delta < 0 {
                    if p.scroll == usize::MAX {
                        p.scroll = p.lines.len().saturating_sub(1);
                    }
                    p.scroll = p.scroll.saturating_sub(n);
                } else {
                    p.scroll = p.scroll.saturating_add(n);
                }
            }
            Some(Pane::BitbucketPipelineLog(p)) => {
                let n = delta.unsigned_abs() as usize;
                p.scroll = if delta < 0 {
                    p.scroll.saturating_sub(n)
                } else {
                    p.scroll + n
                };
            }
            Some(Pane::BitbucketPipelines(_))
            | Some(Pane::BitbucketPullRequests(_))
            | Some(Pane::GithubActions(_))
            | Some(Pane::GithubPullRequests(_))
            | Some(Pane::GitlabPipelines(_))
            | Some(Pane::GitlabMergeRequests(_))
            | Some(Pane::AzDevOpsBuilds(_))
            | Some(Pane::AzDevOpsPullRequests(_)) => {
                // Wheel-scroll for the SCM/CI panes is handled below the
                // match so the borrow on `app.panes` releases first — we
                // need an immutable read of `app.config` to compute the
                // flat-list max index.
            }
            Some(Pane::Cheatsheet(c)) => {
                if delta < 0 {
                    c.move_up();
                } else {
                    c.move_down();
                }
            }
            Some(Pane::Debug(p)) => {
                // Wheel moves whichever sub-section currently has
                // keyboard focus — same routing rule as j/k.
                let d = delta.signum() as isize;
                let n = delta.unsigned_abs() as isize;
                let section = p.section;
                match section {
                    crate::pane::DebugSection::Stack => app.debug_pane_move(d * n),
                    crate::pane::DebugSection::Variables => app.debug_pane_vars_move(d * n),
                }
            }
            Some(Pane::DapRepl(_)) => {
                // Scroll the history. usize::MAX ⇒ pinned to tail;
                // any upward scroll lands at a concrete index.
                let mag = delta.unsigned_abs() as usize;
                if delta < 0 {
                    if let Some(Pane::DapRepl(p)) = app.panes.get_mut(pid) {
                        let total = p.history.len();
                        let cur = if p.scroll == usize::MAX {
                            total
                        } else {
                            p.scroll
                        };
                        p.scroll = cur.saturating_sub(mag);
                    }
                } else if let Some(Pane::DapRepl(p)) = app.panes.get_mut(pid) {
                    let total = p.history.len();
                    let new = if p.scroll == usize::MAX {
                        usize::MAX
                    } else {
                        let next = p.scroll.saturating_add(mag);
                        if next >= total { usize::MAX } else { next }
                    };
                    p.scroll = new;
                }
            }
            Some(Pane::Image(_)) => {
                // Nothing to scroll — the image pane is "what you see is
                // what you get". Future v2 could pan a too-large image.
            }
            None => {}
        }
        // Each SCM/CI pane's max_idx depends on which view-mode is
        // active — same trap as the key handlers above (flat must match
        // the rendered layout).
        if matches!(app.panes.get(pid), Some(Pane::BitbucketPipelines(_))) {
            let flat = match app.bb_pipelines_view_mode {
                crate::bitbucket::PipelineViewMode::Recent => {
                    crate::ui::bitbucket_pipelines_view::flatten_pipelines(app)
                }
                crate::bitbucket::PipelineViewMode::PerBranch => {
                    crate::ui::bitbucket_pipelines_view::flatten_branch_pipelines(app)
                }
            };
            let max_idx = flat.len();
            if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(pid) {
                p.move_selection(delta as i64, max_idx);
            }
        } else if matches!(app.panes.get(pid), Some(Pane::BitbucketPullRequests(_))) {
            let flat = match app.bb_prs_view_mode {
                crate::bitbucket::PrViewMode::PerRepo => {
                    crate::ui::bitbucket_pull_requests_view::flatten_prs(app)
                }
                crate::bitbucket::PrViewMode::Mine => {
                    crate::ui::bitbucket_pull_requests_view::flatten_my_prs(app)
                }
            };
            let max_idx = flat.len();
            if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(pid) {
                p.move_selection(delta as i64, max_idx);
            }
        } else if matches!(app.panes.get(pid), Some(Pane::GithubActions(_))) {
            let flat = match app.gh_actions_view_mode {
                crate::github::ActionsViewMode::Recent => {
                    crate::ui::github_actions_view::flatten_runs(app)
                }
                crate::github::ActionsViewMode::PerBranch => {
                    crate::ui::github_actions_view::flatten_branch_runs(app)
                }
            };
            let max_idx = flat.len();
            if let Some(Pane::GithubActions(p)) = app.panes.get_mut(pid) {
                p.move_selection(delta as i64, max_idx);
            }
        } else if matches!(app.panes.get(pid), Some(Pane::GithubPullRequests(_))) {
            let flat = match app.gh_prs_view_mode {
                crate::github::GhPrViewMode::PerRepo => {
                    crate::ui::github_pull_requests_view::flatten_prs(app)
                }
                crate::github::GhPrViewMode::Mine => {
                    crate::ui::github_pull_requests_view::flatten_my_prs(app)
                }
            };
            let max_idx = flat.len();
            if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(pid) {
                p.move_selection(delta as i64, max_idx);
            }
        } else if matches!(app.panes.get(pid), Some(Pane::GitlabPipelines(_))) {
            let flat = match app.gl_pipelines_view_mode {
                crate::gitlab::GlPipelineViewMode::Recent => {
                    crate::ui::gitlab_pipelines_view::flatten_pipelines(app)
                }
                crate::gitlab::GlPipelineViewMode::PerBranch => {
                    crate::ui::gitlab_pipelines_view::flatten_branch_pipelines(app)
                }
            };
            let max_idx = flat.len();
            if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(pid) {
                p.move_selection(delta as i64, max_idx);
            }
        } else if matches!(app.panes.get(pid), Some(Pane::GitlabMergeRequests(_))) {
            let flat = match app.gl_mrs_view_mode {
                crate::gitlab::GlMrViewMode::PerProject => {
                    crate::ui::gitlab_merge_requests_view::flatten_mrs(app)
                }
                crate::gitlab::GlMrViewMode::Mine => {
                    crate::ui::gitlab_merge_requests_view::flatten_my_mrs(app)
                }
            };
            let max_idx = flat.len();
            if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(pid) {
                p.move_selection(delta as i64, max_idx);
            }
        } else if matches!(app.panes.get(pid), Some(Pane::AzDevOpsBuilds(_))) {
            let flat = match app.az_builds_view_mode {
                crate::azdevops::AzBuildsViewMode::Recent => {
                    crate::ui::azdevops_builds_view::flatten_builds(app)
                }
                crate::azdevops::AzBuildsViewMode::PerBranch => {
                    crate::ui::azdevops_builds_view::flatten_branch_builds(app)
                }
            };
            let max_idx = flat.len();
            if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(pid) {
                p.move_selection(delta as i64, max_idx);
            }
        } else if matches!(app.panes.get(pid), Some(Pane::AzDevOpsPullRequests(_))) {
            let flat = match app.az_prs_view_mode {
                crate::azdevops::AzPrViewMode::PerRepo => {
                    crate::ui::azdevops_pull_requests_view::flatten_prs(app)
                }
                crate::azdevops::AzPrViewMode::Mine => {
                    crate::ui::azdevops_pull_requests_view::flatten_my_prs(app)
                }
            };
            let max_idx = flat.len();
            if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(pid) {
                p.move_selection(delta as i64, max_idx);
            }
        }
    }
}

fn contains(r: Rect, x: u16, y: u16) -> bool {
    x >= r.x && x < r.x.saturating_add(r.width) && y >= r.y && y < r.y.saturating_add(r.height)
}

/// Mouse click on a TestExecutions pane row. `env_idx` is 0/1/2 (dev/staging/prod).
/// `row_idx == HEADER_ROW_SENTINEL` ⇒ flip the active env without selecting
/// a record; otherwise also set the env's selected_row.
#[cfg(feature = "private")]
fn handle_test_executions_row_click(app: &mut App, pane_id: usize, env_idx: u8, row_idx: usize) {
    use crate::pane::Pane;
    use crate::ui::test_executions_view::{HEADER_ROW_SENTINEL, idx_to_env};
    let Some(env) = idx_to_env(env_idx) else {
        return;
    };
    if let Some(Pane::TestExecutions(p)) = app.panes.get_mut(pane_id) {
        p.selected_env = env;
        if row_idx != HEADER_ROW_SENTINEL {
            // Only set if the click was on a real data row.
            p.selected_row.insert(env, row_idx);
        }
    }
}

/// Mouse click on a list-style pane row. Dispatches based on the pane
/// at `pane_id`. `flat_idx` is the index into either the active view's
/// flatten output (SCM/CI panes) or directly into the pane's items vec
/// (plain list panes). `is_double_click` ⇒ trigger the primary action.
fn handle_scm_row_click(app: &mut App, pane_id: usize, flat_idx: usize, is_double_click: bool) {
    use crate::pane::Pane;
    // Plain list panes — set selected, optionally fire primary action.
    if matches!(app.panes.get(pane_id), Some(Pane::Diagnostics(_))) {
        if let Some(Pane::Diagnostics(d)) = app.panes.get_mut(pane_id)
            && flat_idx < d.items.len()
        {
            d.selected = flat_idx;
        }
        if is_double_click {
            app.jump_to_selected_diagnostic();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Outline(_))) {
        if let Some(Pane::Outline(o)) = app.panes.get_mut(pane_id) {
            let len = o.visible_indices().len();
            if flat_idx < len {
                o.selected = flat_idx;
            }
        }
        if is_double_click {
            app.jump_to_selected_outline();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Flaky(_))) {
        if let Some(Pane::Flaky(f)) = app.panes.get_mut(pane_id)
            && flat_idx < f.items.len()
        {
            f.selected = flat_idx;
        }
        if is_double_click {
            app.jump_to_selected_flaky();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Diff(_))) {
        if let Some(Pane::Diff(d)) = app.panes.get_mut(pane_id)
            && flat_idx < d.hunks.len()
        {
            d.cursor = flat_idx;
            // In Hunk mode, clicking a hunk row also toggles its
            // collapse (expanded-by-default — click chevron to
            // collapse one you don't need).
            if d.view_mode == crate::pane::DiffViewMode::Hunk {
                if d.hunk_collapsed.contains(&flat_idx) {
                    d.hunk_collapsed.remove(&flat_idx);
                } else {
                    d.hunk_collapsed.insert(flat_idx);
                }
            }
        }
        if is_double_click {
            app.jump_to_cursor_hunk();
        }
        return;
    }
    #[cfg(feature = "private")]
    if matches!(app.panes.get(pane_id), Some(Pane::CodeBuilds(_))) {
        if let Some(Pane::CodeBuilds(p)) = app.panes.get_mut(pane_id)
            && flat_idx < p.items.len()
        {
            p.selected = flat_idx;
        }
        if is_double_click {
            app.open_selected_codebuild_url();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::GitGraph(_))) {
        if let Some(Pane::GitGraph(g)) = app.panes.get_mut(pane_id) {
            // `flat_idx` is the *virtual* row index (0 = WIP if present,
            // then commits). `jump_to` clamps to total_rows AND calls
            // `reload_detail` so the right-side panel actually populates
            // — directly assigning `selected` skipped the reload, leaving
            // the detail empty after a click.
            g.jump_to(flat_idx);
        }
        if is_double_click {
            app.open_selected_commit_diff();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Cheatsheet(_))) {
        if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(pane_id) {
            let n = c.visible_rows_len();
            if flat_idx < n {
                c.selected = flat_idx;
            }
        }
        if is_double_click {
            app.cheatsheet_run_selected();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::CmdlineHistory(_))) {
        if let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(pane_id)
            && flat_idx < h.entries.len()
        {
            h.selected = flat_idx;
        }
        if is_double_click {
            app.cmdline_history_accept();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Tests(_))) {
        if let Some(Pane::Tests(t)) = app.panes.get_mut(pane_id)
            && let crate::playwright::TestsState::Done(r) = &t.state
            && flat_idx < r.tests.len()
        {
            t.selected = flat_idx;
        }
        if is_double_click {
            app.jump_to_selected_test();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::GitStatus(_))) {
        if let Some(Pane::GitStatus(g)) = app.panes.get_mut(pane_id) {
            let total = g.unstaged.len() + g.staged.len();
            if flat_idx < total {
                g.selected = flat_idx;
            }
        }
        if is_double_click {
            app.git_status_open_diff();
        }
        return;
    }
    if matches!(
        app.panes.get(pane_id),
        Some(Pane::Grep(_)) | Some(Pane::Quickfix(_))
    ) {
        // Both share the GrepPane struct; treat them identically.
        let len = match app.panes.get(pane_id) {
            Some(Pane::Grep(g)) | Some(Pane::Quickfix(g)) => g.hits.len(),
            _ => 0,
        };
        if let Some(pane) = app.panes.get_mut(pane_id) {
            let target = match pane {
                Pane::Grep(g) | Pane::Quickfix(g) => Some(g),
                _ => None,
            };
            if let Some(g) = target
                && flat_idx < len
            {
                g.selected = flat_idx;
            }
        }
        if is_double_click {
            app.jump_to_selected_grep_hit();
        }
        return;
    }
    // Browser sub-panels — clicks select the row inside whichever panel
    // is focused (network / DOM / cookies / storage). Double-click on a
    // network row opens it as a Request pane (sibling to Enter).
    if matches!(app.panes.get(pane_id), Some(Pane::Browser(_))) {
        let net_double_open = {
            let Some(Pane::Browser(b)) = app.panes.get_mut(pane_id) else {
                return;
            };
            if b.dom_focus {
                let n = b.visible_dom_indices().len();
                if flat_idx < n {
                    b.set_dom_sel(flat_idx);
                }
                false
            } else if b.cookies_focus {
                if flat_idx < b.cookies.len() {
                    b.cookies_sel = flat_idx;
                }
                false
            } else if b.storage_focus {
                if flat_idx < b.storage.len() {
                    b.storage_sel = flat_idx;
                }
                false
            } else if b.net_focus {
                let n = b.visible_net_indices().len();
                if flat_idx < n {
                    b.net_sel = flat_idx;
                }
                is_double_click
            } else {
                false
            }
        };
        if net_double_open {
            app.open_net_entry_as_request();
        }
        return;
    }
    // SCM/CI panes — header-vs-data dispatch with collapse + URL open.
    match app.panes.get(pane_id) {
        Some(Pane::BitbucketPipelines(_)) => {
            let flat = match app.bb_pipelines_view_mode {
                crate::bitbucket::PipelineViewMode::Recent => {
                    crate::ui::bitbucket_pipelines_view::flatten_pipelines(app)
                }
                crate::bitbucket::PipelineViewMode::PerBranch => {
                    crate::ui::bitbucket_pipelines_view::flatten_branch_pipelines(app)
                }
            };
            let Some(row) = flat.get(flat_idx) else {
                return;
            };
            let is_header = row.kind == crate::ui::bitbucket_pipelines_view::RowKind::Header;
            let header_label = row.header_label.clone();
            if let Some(Pane::BitbucketPipelines(p)) = app.panes.get_mut(pane_id) {
                p.selected = flat_idx;
            }
            if is_header {
                if app.bb_pipelines_collapsed.contains(&header_label) {
                    app.bb_pipelines_collapsed.remove(&header_label);
                } else {
                    app.bb_pipelines_collapsed.insert(header_label);
                }
            } else if is_double_click {
                app.open_selected_bitbucket_pipeline_url();
            }
        }
        Some(Pane::BitbucketPullRequests(_)) => {
            let flat = match app.bb_prs_view_mode {
                crate::bitbucket::PrViewMode::PerRepo => {
                    crate::ui::bitbucket_pull_requests_view::flatten_prs(app)
                }
                crate::bitbucket::PrViewMode::Mine => {
                    crate::ui::bitbucket_pull_requests_view::flatten_my_prs(app)
                }
            };
            let Some(row) = flat.get(flat_idx) else {
                return;
            };
            let is_header = row.kind == crate::ui::bitbucket_pull_requests_view::RowKind::Header;
            let header_label = row.header_label.clone();
            if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(pane_id) {
                p.selected = flat_idx;
            }
            if is_header {
                if app.bb_prs_collapsed.contains(&header_label) {
                    app.bb_prs_collapsed.remove(&header_label);
                } else {
                    app.bb_prs_collapsed.insert(header_label);
                }
            } else if is_double_click {
                app.open_selected_bitbucket_pr_url();
            }
        }
        Some(Pane::GithubActions(_)) => {
            let flat = match app.gh_actions_view_mode {
                crate::github::ActionsViewMode::Recent => {
                    crate::ui::github_actions_view::flatten_runs(app)
                }
                crate::github::ActionsViewMode::PerBranch => {
                    crate::ui::github_actions_view::flatten_branch_runs(app)
                }
            };
            let Some(row) = flat.get(flat_idx) else {
                return;
            };
            let is_header = row.kind == crate::ui::github_actions_view::RowKind::Header;
            let header_label = row.header_label.clone();
            if let Some(Pane::GithubActions(p)) = app.panes.get_mut(pane_id) {
                p.selected = flat_idx;
            }
            if is_header {
                if app.gh_actions_collapsed.contains(&header_label) {
                    app.gh_actions_collapsed.remove(&header_label);
                } else {
                    app.gh_actions_collapsed.insert(header_label);
                }
            } else if is_double_click {
                app.open_selected_github_run_url();
            }
        }
        Some(Pane::GithubPullRequests(_)) => {
            let flat = match app.gh_prs_view_mode {
                crate::github::GhPrViewMode::PerRepo => {
                    crate::ui::github_pull_requests_view::flatten_prs(app)
                }
                crate::github::GhPrViewMode::Mine => {
                    crate::ui::github_pull_requests_view::flatten_my_prs(app)
                }
            };
            let Some(row) = flat.get(flat_idx) else {
                return;
            };
            let is_header = row.kind == crate::ui::github_pull_requests_view::RowKind::Header;
            let header_label = row.header_label.clone();
            if let Some(Pane::GithubPullRequests(p)) = app.panes.get_mut(pane_id) {
                p.selected = flat_idx;
            }
            if is_header {
                if app.gh_prs_collapsed.contains(&header_label) {
                    app.gh_prs_collapsed.remove(&header_label);
                } else {
                    app.gh_prs_collapsed.insert(header_label);
                }
            } else if is_double_click {
                app.open_selected_github_pr_url();
            }
        }
        Some(Pane::GitlabPipelines(_)) => {
            let flat = match app.gl_pipelines_view_mode {
                crate::gitlab::GlPipelineViewMode::Recent => {
                    crate::ui::gitlab_pipelines_view::flatten_pipelines(app)
                }
                crate::gitlab::GlPipelineViewMode::PerBranch => {
                    crate::ui::gitlab_pipelines_view::flatten_branch_pipelines(app)
                }
            };
            let Some(row) = flat.get(flat_idx) else {
                return;
            };
            let is_header = row.kind == crate::ui::gitlab_pipelines_view::RowKind::Header;
            let header_label = row.header_label.clone();
            if let Some(Pane::GitlabPipelines(p)) = app.panes.get_mut(pane_id) {
                p.selected = flat_idx;
            }
            if is_header {
                if app.gl_pipelines_collapsed.contains(&header_label) {
                    app.gl_pipelines_collapsed.remove(&header_label);
                } else {
                    app.gl_pipelines_collapsed.insert(header_label);
                }
            } else if is_double_click {
                app.open_selected_gitlab_pipeline_url();
            }
        }
        Some(Pane::GitlabMergeRequests(_)) => {
            let flat = match app.gl_mrs_view_mode {
                crate::gitlab::GlMrViewMode::PerProject => {
                    crate::ui::gitlab_merge_requests_view::flatten_mrs(app)
                }
                crate::gitlab::GlMrViewMode::Mine => {
                    crate::ui::gitlab_merge_requests_view::flatten_my_mrs(app)
                }
            };
            let Some(row) = flat.get(flat_idx) else {
                return;
            };
            let is_header = row.kind == crate::ui::gitlab_merge_requests_view::RowKind::Header;
            let header_label = row.header_label.clone();
            if let Some(Pane::GitlabMergeRequests(p)) = app.panes.get_mut(pane_id) {
                p.selected = flat_idx;
            }
            if is_header {
                if app.gl_mrs_collapsed.contains(&header_label) {
                    app.gl_mrs_collapsed.remove(&header_label);
                } else {
                    app.gl_mrs_collapsed.insert(header_label);
                }
            } else if is_double_click {
                app.open_selected_gitlab_mr_url();
            }
        }
        Some(Pane::AzDevOpsBuilds(_)) => {
            let flat = match app.az_builds_view_mode {
                crate::azdevops::AzBuildsViewMode::Recent => {
                    crate::ui::azdevops_builds_view::flatten_builds(app)
                }
                crate::azdevops::AzBuildsViewMode::PerBranch => {
                    crate::ui::azdevops_builds_view::flatten_branch_builds(app)
                }
            };
            let Some(row) = flat.get(flat_idx) else {
                return;
            };
            let is_header = row.kind == crate::ui::azdevops_builds_view::RowKind::Header;
            let header_label = row.header_label.clone();
            if let Some(Pane::AzDevOpsBuilds(p)) = app.panes.get_mut(pane_id) {
                p.selected = flat_idx;
            }
            if is_header {
                if app.az_builds_collapsed.contains(&header_label) {
                    app.az_builds_collapsed.remove(&header_label);
                } else {
                    app.az_builds_collapsed.insert(header_label);
                }
            } else if is_double_click {
                app.open_selected_azdevops_build_url();
            }
        }
        Some(Pane::AzDevOpsPullRequests(_)) => {
            let flat = match app.az_prs_view_mode {
                crate::azdevops::AzPrViewMode::PerRepo => {
                    crate::ui::azdevops_pull_requests_view::flatten_prs(app)
                }
                crate::azdevops::AzPrViewMode::Mine => {
                    crate::ui::azdevops_pull_requests_view::flatten_my_prs(app)
                }
            };
            let Some(row) = flat.get(flat_idx) else {
                return;
            };
            let is_header = row.kind == crate::ui::azdevops_pull_requests_view::RowKind::Header;
            let header_label = row.header_label.clone();
            if let Some(Pane::AzDevOpsPullRequests(p)) = app.panes.get_mut(pane_id) {
                p.selected = flat_idx;
            }
            if is_header {
                if app.az_prs_collapsed.contains(&header_label) {
                    app.az_prs_collapsed.remove(&header_label);
                } else {
                    app.az_prs_collapsed.insert(header_label);
                }
            } else if is_double_click {
                app.open_selected_azdevops_pr_url();
            }
        }
        _ => {}
    }
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
