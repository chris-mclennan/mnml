//! The render path — backend-agnostic, so the same `draw` serves the real
//! terminal (`tui.rs`) and the headless virtual screen (`headless.rs`). Layout:
//!
//! ```text
//! ┌───────────────────────────────────────────────┐
//! │ bufferline (open buffers · tabpages)        h1 │
//! ├──────────┬────────────────────────────────────┤
//! │  tree    │  active pane body                   │
//! │  rail    │  (editor view / welcome)            │
//! ├──────────┴────────────────────────────────────┤
//! │ statusline (mode · file · git · Ln:Col · lang) │
//! └───────────────────────────────────────────────┘
//! ```
//!
//! Later: a recursive split tree replaces "active pane body", and overlays
//! (picker / palette / which-key / popups) draw on top.

pub mod bufferline;
pub mod editor_view;
pub mod icons;
pub mod statusline;
pub mod theme;
pub mod tree_view;
pub mod welcome;

use ratatui::Frame;
use ratatui::layout::{Constraint, Direction, Layout as RLayout};
use ratatui::style::Style;
use ratatui::widgets::Block;

use crate::app::App;
use crate::focus::Focus;
use crate::pane::Pane;

pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();
    // Paint the whole frame with the editor background first so gaps look intentional.
    frame.render_widget(Block::default().style(Style::default().bg(theme::BG_DARK)), area);

    let rows = RLayout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(1), Constraint::Length(1)])
        .split(area);
    let (top, mid, bottom) = (rows[0], rows[1], rows[2]);

    // ── bufferline ──
    bufferline::draw(frame, app, top);
    app.rects.bufferline = Some(top);

    // ── tree | body ──
    let (tree_area, body_area) = if app.tree_visible {
        let w = app.config.ui.tree_width.min(mid.width.saturating_sub(20)).max(8);
        let cols = RLayout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(w), Constraint::Min(1)])
            .split(mid);
        (Some(cols[0]), cols[1])
    } else {
        (None, mid)
    };
    if let Some(ta) = tree_area {
        tree_view::draw(frame, app, ta);
        app.rects.tree = Some(ta);
    } else {
        app.rects.tree = None;
    }
    app.rects.body = Some(body_area);

    // ── active pane ──
    let mut cursor_pos: Option<(u16, u16)> = None;
    match app.active.and_then(|i| app.panes.get(i)) {
        Some(Pane::Editor(_)) => {
            cursor_pos = editor_view::draw(frame, app, body_area);
        }
        None => {
            welcome::draw(frame, app, body_area);
            app.rects.editor_text = None;
        }
    }

    // ── statusline ──
    statusline::draw(frame, app, bottom);
    app.rects.statusline = Some(bottom);

    // ── terminal cursor ──
    // Only show it when the editor pane has focus (P0 buffers are read-only, but
    // showing where the caret is still helps); otherwise hide it offscreen-ish.
    if app.focus == Focus::Pane {
        if let Some((x, y)) = cursor_pos {
            frame.set_cursor_position((x, y));
        }
    }
}
