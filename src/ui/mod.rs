//! The render path — backend-agnostic, so the same `draw` serves the real
//! terminal (`tui.rs`) and the headless virtual screen (`headless.rs`). Layout
//! mirrors NvChad: the file-tree rail is a full-height column on the left (the
//! buffer tabs do NOT sit above it); the right column is a one-line bufferline
//! over the pane body; the statusline spans the full width at the bottom.
//!
//! ```text
//! ┌──────────┬────────────────────────────────────┐
//! │  tree    │ bufferline (open buffers)        h1 │
//! │  rail    ├────────────────────────────────────┤
//! │ (full    │ active pane body                   │
//! │  height) │ (editor view / welcome)            │
//! ├──────────┴────────────────────────────────────┤
//! │ statusline (mode · git · file … Ln:Col · lang) │
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
use ratatui::layout::{Constraint, Layout as RLayout};
use ratatui::style::Style;
use ratatui::widgets::Block;

use crate::app::App;
use crate::focus::Focus;
use crate::pane::Pane;

pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().bg(theme::BG_DARK)),
        area,
    );

    // Split off the bottom statusline (full width).
    let v = RLayout::vertical([Constraint::Min(1), Constraint::Length(1)]).split(area);
    let (upper, statusline_area) = (v[0], v[1]);

    // tree rail | right column
    let (tree_area, right) = if app.tree_visible {
        let w = app
            .config
            .ui
            .tree_width
            .min(upper.width.saturating_sub(20))
            .max(8);
        let cols = RLayout::horizontal([Constraint::Length(w), Constraint::Min(1)]).split(upper);
        (Some(cols[0]), cols[1])
    } else {
        (None, upper)
    };

    // right column: bufferline (h1) over the body
    let r = RLayout::vertical([Constraint::Length(1), Constraint::Min(1)]).split(right);
    let (bufferline_area, body_area) = (r[0], r[1]);

    // ── tree rail (full height of `upper`) ──
    if let Some(ta) = tree_area {
        tree_view::draw(frame, app, ta);
        app.rects.tree = Some(ta);
    } else {
        app.rects.tree = None;
    }

    // ── bufferline ──
    bufferline::draw(frame, app, bufferline_area);
    app.rects.bufferline = Some(bufferline_area);

    // ── active pane body ──
    app.rects.body = Some(body_area);
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
    statusline::draw(frame, app, statusline_area);
    app.rects.statusline = Some(statusline_area);

    // ── terminal cursor (only when the editor pane has focus) ──
    if app.focus == Focus::Pane
        && let Some((x, y)) = cursor_pos
    {
        frame.set_cursor_position((x, y));
    }
}
