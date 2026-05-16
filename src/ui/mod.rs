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
pub mod azdevops_builds_view;
pub mod azdevops_pull_requests_view;
pub mod bitbucket_pipelines_view;
pub mod bitbucket_pull_requests_view;
pub mod browser_view;
pub mod bufferline;
pub mod close_prompt;
pub mod cmdline_history_view;
#[cfg(feature = "private")]
pub mod codebuilds_view;
pub mod completion;
pub mod context_menu;
pub mod diagnostics_view;
pub mod diff_view;
pub mod editor_view;
pub mod flaky_view;
pub mod git_graph_view;
pub mod git_status_view;
pub mod github_actions_view;
pub mod github_pull_requests_view;
pub mod gitlab_merge_requests_view;
pub mod gitlab_pipelines_view;
pub mod grep_view;
pub mod hover;
pub mod icons;
pub mod md_preview;
pub mod outline_view;
pub mod picker;
pub mod prompt;
pub mod pty_view;
pub mod request_view;
pub mod signature;
pub mod statusline;
#[cfg(feature = "private")]
pub mod test_executions_view;
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
        app.rects.fold_chips.clear();
        app.rects.completion_rows.clear();
        app.rects.list_rows.clear();
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
        if app.signature.is_some() {
            signature::draw(frame, app, area, cursor_pos);
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
        let w = app.tree_width.min(upper.width.saturating_sub(20)).max(8);
        let cols = RLayout::horizontal([Constraint::Length(w), Constraint::Min(1)]).split(upper);
        // The rail's rightmost cell column is the resize handle.
        app.rects.tree_edge = Some(Rect {
            x: cols[0].x + cols[0].width.saturating_sub(1),
            y: cols[0].y,
            width: 1,
            height: cols[0].height,
        });
        (Some(cols[0]), cols[1])
    } else {
        app.rects.tree_edge = None;
        (None, upper)
    };

    // right column: optionally a 1-row bufferline above the body.
    // `app.bufferline_visible = false` ⇒ skip the strip; the body grows.
    let (bufferline_area, body_area) = if app.bufferline_visible {
        let r = RLayout::vertical([Constraint::Length(1), Constraint::Min(1)]).split(right);
        (Some(r[0]), r[1])
    } else {
        (None, right)
    };

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
    if let Some(ba) = bufferline_area {
        bufferline::draw(frame, app, ba);
        app.rects.bufferline = Some(ba);
    } else {
        app.rects.bufferline = None;
        app.rects.bufferline_tabs.clear();
        app.rects.bufferline_tab_close.clear();
    }

    // ── the split-tree of pane bodies ──
    app.rects.body = Some(body_area);
    app.rects.editor_panes.clear();
    app.rects.fold_chips.clear();
    app.rects.list_rows.clear();
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
    if app.signature.is_some() {
        signature::draw(frame, app, area, cursor_pos);
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
                Some(crate::pane::Pane::Outline(_)) => 14,
                Some(crate::pane::Pane::CmdlineHistory(_)) => 15,
                Some(crate::pane::Pane::Quickfix(_)) => 16,
                #[cfg(feature = "private")]
                Some(crate::pane::Pane::TestExecutions(_)) => 17,
                #[cfg(feature = "private")]
                Some(crate::pane::Pane::CodeBuilds(_)) => 18,
                Some(crate::pane::Pane::BitbucketPipelines(_)) => 19,
                Some(crate::pane::Pane::GithubActions(_)) => 20,
                Some(crate::pane::Pane::BitbucketPullRequests(_)) => 21,
                Some(crate::pane::Pane::GithubPullRequests(_)) => 22,
                Some(crate::pane::Pane::GitlabPipelines(_)) => 23,
                Some(crate::pane::Pane::GitlabMergeRequests(_)) => 24,
                Some(crate::pane::Pane::AzDevOpsBuilds(_)) => 25,
                Some(crate::pane::Pane::AzDevOpsPullRequests(_)) => 26,
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
                14 => outline_view::draw(frame, app, *id, area, focused),
                15 => cmdline_history_view::draw(frame, app, *id, area, focused),
                // Quickfix shares the Grep view — same shape, different
                // pane identity so `:grep` results don't clobber it.
                16 => grep_view::draw(frame, app, *id, area, focused),
                #[cfg(feature = "private")]
                17 => test_executions_view::draw(frame, app, *id, area, focused),
                #[cfg(feature = "private")]
                18 => codebuilds_view::draw(frame, app, *id, area, focused),
                19 => bitbucket_pipelines_view::draw(frame, app, *id, area, focused),
                20 => github_actions_view::draw(frame, app, *id, area, focused),
                21 => bitbucket_pull_requests_view::draw(frame, app, *id, area, focused),
                22 => github_pull_requests_view::draw(frame, app, *id, area, focused),
                23 => gitlab_pipelines_view::draw(frame, app, *id, area, focused),
                24 => gitlab_merge_requests_view::draw(frame, app, *id, area, focused),
                25 => azdevops_builds_view::draw(frame, app, *id, area, focused),
                26 => azdevops_pull_requests_view::draw(frame, app, *id, area, focused),
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
