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
    KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::layout::Rect;

use crate::app::App;
use crate::edit_op::EditOp;
use crate::focus::Focus;
use crate::layout::Layout;
use crate::pane::Pane;
use crate::{command, ui};

/// Run the terminal UI. `Ok(true)` ⇒ exit for a rebuild+relaunch (the `run.sh`
/// wrapper watches for that); `Ok(false)` ⇒ normal quit.
pub fn run(mut app: App) -> Result<bool, String> {
    let mut term = setup_terminal().map_err(|e| format!("terminal setup failed: {e}"))?;
    let result = run_loop(&mut term, &mut app);
    let _ = restore_terminal(&mut term);
    result.map(|()| app.restart_requested).map_err(|e| format!("{e}"))
}

fn setup_terminal() -> io::Result<Terminal<CrosstermBackend<Stdout>>> {
    enable_raw_mode()?;
    let mut out = io::stdout();
    if let Err(e) = execute!(out, EnterAlternateScreen, EnableMouseCapture, SetCursorStyle::SteadyBar) {
        let _ = disable_raw_mode();
        return Err(e);
    }
    Terminal::new(CrosstermBackend::new(out)).inspect_err(|_| {
        let _ = disable_raw_mode();
    })
}

fn restore_terminal(term: &mut Terminal<CrosstermBackend<Stdout>>) -> io::Result<()> {
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
    loop {
        app.tick();
        term.draw(|f| ui::draw(f, app))?;
        if app.should_quit {
            break;
        }
        if event::poll(Duration::from_millis(120))? {
            match event::read()? {
                Event::Key(k) if k.kind != KeyEventKind::Release => dispatch_key(app, k),
                Event::Mouse(m) => dispatch_mouse(app, m),
                Event::Resize(_, _) => {}
                _ => {}
            }
        }
    }
    Ok(())
}

// ─── key dispatch (shared with headless/IPC) ────────────────────────

pub fn dispatch_key(app: &mut App, key: KeyEvent) {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);

    // Global chords (any focus). For P0 a small hardcoded set routed through the
    // command registry; the config-driven keymap resolver lands with P1.
    if ctrl {
        match key.code {
            KeyCode::Char('q') => {
                command::run("app.quit", app);
                return;
            }
            KeyCode::Char('b') => {
                command::run("view.toggle_tree", app);
                return;
            }
            KeyCode::Char('e') => {
                command::run("focus.cycle", app);
                return;
            }
            KeyCode::Char('s') => {
                command::run("file.save", app);
                return;
            }
            _ => {}
        }
    }

    match app.focus {
        Focus::Tree => handle_tree_key(app, key),
        Focus::Pane => handle_pane_key(app, key),
    }
}

fn handle_tree_key(app: &mut App, key: KeyEvent) {
    match key.code {
        KeyCode::Up | KeyCode::Char('k') => app.tree.move_up(),
        KeyCode::Down | KeyCode::Char('j') => app.tree.move_down(),
        KeyCode::Right | KeyCode::Char('l') => app.tree.expand_or_descend(),
        KeyCode::Left | KeyCode::Char('h') => app.tree.collapse_or_ascend(),
        KeyCode::Enter | KeyCode::Char(' ') => app.tree_activate(),
        KeyCode::Char('R') => app.tree.refresh(),
        KeyCode::Home | KeyCode::Char('g') => app.tree.set_cursor(0),
        KeyCode::End | KeyCode::Char('G') => app.tree.set_cursor(usize::MAX),
        _ => {}
    }
}

fn handle_pane_key(app: &mut App, key: KeyEvent) {
    // P0: buffers are read-only. We still want to navigate/scroll a file, so map
    // motion keys directly to editor ops here. P1 routes everything through the
    // buffer's `InputHandler` (`buffer.feed_key`) instead.
    let viewport = app
        .rects
        .editor_text
        .map(|r| r.height as usize)
        .unwrap_or(20)
        .max(1);
    let op: Option<EditOp> = match key.code {
        KeyCode::Esc => {
            app.focus_tree();
            return;
        }
        KeyCode::Up | KeyCode::Char('k') => Some(EditOp::MoveUp),
        KeyCode::Down | KeyCode::Char('j') => Some(EditOp::MoveDown),
        KeyCode::Left | KeyCode::Char('h') => Some(EditOp::MoveLeft),
        KeyCode::Right | KeyCode::Char('l') => Some(EditOp::MoveRight),
        KeyCode::PageUp => Some(EditOp::PageUp),
        KeyCode::PageDown => Some(EditOp::PageDown),
        KeyCode::Home | KeyCode::Char('0') => Some(EditOp::MoveLineStart),
        KeyCode::End | KeyCode::Char('$') => Some(EditOp::MoveLineEnd),
        KeyCode::Char('w') => Some(EditOp::MoveWordRight),
        KeyCode::Char('b') => Some(EditOp::MoveWordLeft),
        KeyCode::Char('G') => Some(EditOp::MoveBufferEnd),
        _ => None,
    };
    if let Some(op) = op {
        apply_to_active_editor(app, op, viewport);
    }
}

fn apply_to_active_editor(app: &mut App, op: EditOp, viewport: usize) {
    if let Some(i) = app.active
        && let Some(Pane::Editor(b)) = app.panes.get_mut(i) {
            b.editor.apply(op, viewport, &mut app.clipboard);
        }
}

// ─── mouse dispatch (shared with headless/IPC) ──────────────────────

pub fn dispatch_mouse(app: &mut App, m: MouseEvent) {
    let (x, y) = (m.column, m.row);
    match m.kind {
        MouseEventKind::Down(MouseButton::Left) => {
            // Bufferline tab?
            if let Some((_, id)) = app
                .rects
                .bufferline_tabs
                .iter()
                .find(|(r, _)| contains(*r, x, y))
                .map(|(r, id)| (*r, *id))
            {
                if id < app.panes.len() {
                    app.active = Some(id);
                    app.layout = Layout::Leaf(id);
                    app.focus_pane();
                }
                return;
            }
            // Tree?
            if let Some(tr) = app.rects.tree
                && contains(tr, x, y) {
                    app.focus_tree();
                    if y > tr.y {
                        let idx = (y - tr.y - 1) as usize + app.rects.tree_scroll;
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
            // Editor text?
            if let Some(tr) = app.rects.editor_text
                && contains(tr, x, y) {
                    app.focus_pane();
                    let row = app.active_editor().map(|b| b.scroll).unwrap_or(0) + (y - tr.y) as usize;
                    let col = app.active_editor().map(|b| b.h_scroll).unwrap_or(0) + (x - tr.x) as usize;
                    if let Some(i) = app.active
                        && let Some(Pane::Editor(b)) = app.panes.get_mut(i) {
                            b.editor.place_cursor(row, col);
                        }
                }
        }
        MouseEventKind::ScrollUp => scroll_under(app, x, y, -3),
        MouseEventKind::ScrollDown => scroll_under(app, x, y, 3),
        _ => {}
    }
}

fn scroll_under(app: &mut App, x: u16, y: u16, delta: i32) {
    if let Some(tr) = app.rects.tree
        && contains(tr, x, y) {
            for _ in 0..delta.unsigned_abs() {
                if delta < 0 {
                    app.tree.move_up();
                } else {
                    app.tree.move_down();
                }
            }
            return;
        }
    if let Some(tr) = app.rects.body
        && contains(tr, x, y) {
            let vp = app.rects.editor_text.map(|r| r.height as usize).unwrap_or(20).max(1);
            for _ in 0..delta.unsigned_abs() {
                apply_to_active_editor(app, if delta < 0 { EditOp::MoveUp } else { EditOp::MoveDown }, vp);
            }
        }
}

fn contains(r: Rect, x: u16, y: u16) -> bool {
    x >= r.x && x < r.x.saturating_add(r.width) && y >= r.y && y < r.y.saturating_add(r.height)
}
