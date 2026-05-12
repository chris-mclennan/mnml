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
//! "active pane body" is actually a recursive split tree (`render_layout`) — one
//! editor per `Layout::Leaf`, 1-cell dividers between splits. Overlays (picker /
//! palette / which-key / popups) draw on top.

pub mod bufferline;
pub mod close_prompt;
pub mod editor_view;
pub mod icons;
pub mod picker;
pub mod statusline;
pub mod theme;
pub mod tree_view;
pub mod welcome;
pub mod whichkey;

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout as RLayout, Rect};
use ratatui::style::Style;
use ratatui::text::Span;
use ratatui::widgets::{Block, Paragraph};

use crate::app::App;
use crate::focus::Focus;
use crate::layout::{Layout, SplitDir, split_rects};

pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().bg(theme::cur().bg_dark)),
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
    // (tree_view records `app.rects.tree` itself — it's the inner rect below the
    // blank top line, so the mouse maths line up.)
    if let Some(ta) = tree_area {
        tree_view::draw(frame, app, ta);
    } else {
        app.rects.tree = None;
    }

    // ── bufferline ──
    bufferline::draw(frame, app, bufferline_area);
    app.rects.bufferline = Some(bufferline_area);

    // ── the split-tree of pane bodies ──
    app.rects.body = Some(body_area);
    app.rects.editor_panes.clear();
    app.rects.split_dividers.clear();
    let layout = app.layout.clone();
    let cursor_pos: Option<(u16, u16)> = if matches!(layout, Layout::Empty) {
        welcome::draw(frame, app, body_area);
        None
    } else {
        let mut path = Vec::new();
        render_layout(frame, app, &layout, body_area, &mut path)
    };

    // ── statusline ──
    statusline::draw(frame, app, statusline_area);
    app.rects.statusline = Some(statusline_area);

    // ── overlays (picker / palette, then which-key) ──
    if app.picker.is_some() {
        picker::draw(frame, app, area);
    } else {
        app.rects.picker_box = None;
        app.rects.picker_items.clear();
        app.rects.picker_caret = None;
    }
    if app.whichkey.is_some() {
        whichkey::draw(frame, app, area);
    }
    if app.close_prompt.is_some() {
        close_prompt::draw(frame, app, area);
    } else {
        app.rects.close_prompt_buttons.clear();
    }

    // ── terminal cursor ──
    // The picker's query caret wins when it's open; otherwise the editor caret
    // when the editor pane has focus and no overlay is up; otherwise nothing.
    if let Some((x, y)) = app.rects.picker_caret {
        frame.set_cursor_position((x, y));
    } else if app.focus == Focus::Pane
        && app.whichkey.is_none()
        && app.close_prompt.is_none()
        && let Some((x, y)) = cursor_pos
    {
        frame.set_cursor_position((x, y));
    }
}

/// Recursively render a layout subtree into `area`: leaves draw their editor;
/// splits draw a 1-cell divider and recurse. Only the focused leaf returns a
/// cursor cell, so the `.or` chain bubbles it up. `path` accumulates the
/// first(false)/second(true) choices to the current node, recorded with each
/// divider so the mouse can drag-resize a specific split.
fn render_layout(
    frame: &mut Frame,
    app: &mut App,
    layout: &Layout,
    area: Rect,
    path: &mut Vec<bool>,
) -> Option<(u16, u16)> {
    match layout {
        Layout::Empty => None,
        Layout::Leaf(id) => {
            let focused = app.active == Some(*id);
            editor_view::draw_pane(frame, app, *id, area, focused)
        }
        Layout::Split {
            dir,
            ratio,
            first,
            second,
        } => {
            let (a, divider, b) = split_rects(area, *dir, *ratio);
            if divider.width > 0 && divider.height > 0 {
                draw_divider(frame, divider, *dir);
                app.rects.split_dividers.push(crate::layout::DividerHit {
                    rect: divider,
                    dir: *dir,
                    area,
                    path: path.clone(),
                });
            }
            path.push(false);
            let c1 = render_layout(frame, app, first, a, path);
            path.pop();
            path.push(true);
            let c2 = render_layout(frame, app, second, b, path);
            path.pop();
            c1.or(c2)
        }
    }
}

fn draw_divider(frame: &mut Frame, rect: Rect, dir: SplitDir) {
    let style = Style::default()
        .fg(theme::cur().line)
        .bg(theme::cur().bg_dark);
    match dir {
        SplitDir::Horizontal => {
            for dy in 0..rect.height {
                frame.render_widget(
                    Paragraph::new(Span::styled("│", style)),
                    Rect::new(rect.x, rect.y + dy, 1, 1),
                );
            }
        }
        SplitDir::Vertical => {
            frame.render_widget(
                Paragraph::new(Span::styled("─".repeat(rect.width as usize), style)),
                rect,
            );
        }
    }
}
