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

pub mod ai_view;
pub mod browser_view;
pub mod bufferline;
pub mod close_prompt;
pub mod completion;
pub mod context_menu;
pub mod diagnostics_view;
pub mod diff_view;
pub mod editor_view;
pub mod flaky_view;
pub mod git_graph_view;
pub mod git_status_view;
pub mod grep_view;
pub mod hover;
pub mod icons;
pub mod md_preview;
pub mod picker;
pub mod prompt;
pub mod pty_view;
pub mod request_view;
pub mod statusline;
pub mod tests_view;
pub mod theme;
pub mod trace_view;
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

    // Zen mode: skip the tree, bufferline, and statusline — the editor takes
    // the full window. Returning early keeps the toggle a flat opt-out from
    // the rest of the layout pipeline.
    if app.zen_mode {
        app.rects.tree = None;
        app.rects.tree_toggle = None;
        app.rects.bufferline = None;
        app.rects.bufferline_tabs.clear();
        app.rects.bufferline_tab_close.clear();
        app.rects.statusline = None;
        app.rects.body = Some(area);
        app.rects.editor_panes.clear();
        app.rects.split_dividers.clear();
        let layout = app.layout.clone();
        let cursor_pos: Option<(u16, u16)> = if matches!(layout, Layout::Empty) {
            welcome::draw(frame, app, area);
            None
        } else {
            let mut path = Vec::new();
            render_layout(frame, app, &layout, area, &mut path)
        };
        // Overlays still work in zen — picker, prompt, which-key, popups.
        if app.picker.is_some() {
            picker::draw(frame, app, area);
        }
        if app.whichkey.is_some() {
            whichkey::draw(frame, app, area);
        }
        if app.prompt.is_some() {
            prompt::draw(frame, app, area);
        }
        if app.hover.is_some() {
            hover::draw(frame, app, area, cursor_pos);
        }
        if app.completion.is_some() {
            completion::draw(frame, app, area, cursor_pos);
        }
        if let Some((x, y)) = app.rects.prompt_caret.or(app.rects.picker_caret) {
            frame.set_cursor_position((x, y));
        } else if app.focus == Focus::Pane
            && let Some((x, y)) = cursor_pos
        {
            frame.set_cursor_position((x, y));
        }
        return;
    }

    // Split off the bottom statusline (full width).
    let v = RLayout::vertical([Constraint::Min(1), Constraint::Length(1)]).split(area);
    let (upper, statusline_area) = (v[0], v[1]);

    // tree rail | right column. `tree_visible` here means "the rail itself is
    // showing" (toggled by `Ctrl+B`); a separate `tree_root_expanded` flag,
    // read by `tree_view::draw`, controls whether the file list under the
    // workspace-name header is shown (the VS-Code-style section collapse).
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
        app.rects.tree_toggle = None;
        app.rects.git_section_toggle = None;
        app.rects.git_rail_rows.clear();
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
    if app.prompt.is_some() {
        prompt::draw(frame, app, area);
    } else {
        app.rects.prompt_caret = None;
    }
    if app.context_menu.is_some() {
        context_menu::draw(frame, app, area);
    } else {
        app.rects.context_menu_box = None;
        app.rects.context_menu_items.clear();
    }
    if app.hover.is_some() {
        hover::draw(frame, app, area, cursor_pos);
    }
    if app.completion.is_some() {
        completion::draw(frame, app, area, cursor_pos);
    }

    // ── terminal cursor ──
    // An overlay's text caret (picker query, prompt input) wins when it's open;
    // otherwise the editor caret when the editor pane has focus and no overlay is
    // up; otherwise nothing.
    if let Some((x, y)) = app.rects.prompt_caret.or(app.rects.picker_caret) {
        frame.set_cursor_position((x, y));
    } else if app.focus == Focus::Pane
        && app.whichkey.is_none()
        && app.close_prompt.is_none()
        && app.prompt.is_none()
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
            // Resolve the variant first so the immutable peek doesn't outlive into
            // the `&mut App` draw call.
            let kind: u8 = match app.panes.get(*id) {
                Some(crate::pane::Pane::MdPreview(_)) => 1,
                Some(crate::pane::Pane::Diff(_)) => 2,
                Some(crate::pane::Pane::Request(_)) => 3,
                Some(crate::pane::Pane::Pty(_)) => 4,
                Some(crate::pane::Pane::Ai(_)) => 5,
                Some(crate::pane::Pane::Tests(_)) => 6,
                Some(crate::pane::Pane::GitGraph(_)) => 7,
                Some(crate::pane::Pane::GitStatus(_)) => 8,
                Some(crate::pane::Pane::Diagnostics(_)) => 9,
                Some(crate::pane::Pane::Trace(_)) => 10,
                Some(crate::pane::Pane::Browser(_)) => 11,
                Some(crate::pane::Pane::Grep(_)) => 12,
                Some(crate::pane::Pane::Flaky(_)) => 13,
                _ => 0,
            };
            match kind {
                1 => md_preview::draw(frame, app, *id, area, focused),
                2 => diff_view::draw(frame, app, *id, area, focused),
                3 => request_view::draw(frame, app, *id, area, focused),
                4 => pty_view::draw(frame, app, *id, area, focused),
                5 => ai_view::draw(frame, app, *id, area, focused),
                6 => tests_view::draw(frame, app, *id, area, focused),
                7 => git_graph_view::draw(frame, app, *id, area, focused),
                8 => git_status_view::draw(frame, app, *id, area, focused),
                9 => diagnostics_view::draw(frame, app, *id, area, focused),
                10 => trace_view::draw(frame, app, *id, area, focused),
                11 => browser_view::draw(frame, app, *id, area, focused),
                12 => grep_view::draw(frame, app, *id, area, focused),
                13 => flaky_view::draw(frame, app, *id, area, focused),
                _ => editor_view::draw_pane(frame, app, *id, area, focused),
            }
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
