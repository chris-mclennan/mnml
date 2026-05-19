//! Hover-tooltip overlay — a small floating label rendered above (or below) the
//! currently-hovered clickable chip, ~500ms after the mouse settles on it. Closes
//! the discoverability loop: lets users learn what each chip does without trial-
//! and-error or memorizing the README.
//!
//! `App.hover_chip` carries `(HoverChip, Instant)`; `tui::dispatch_mouse` updates
//! it on every `MouseEventKind::Moved`. This module reads it and paints if the
//! delay has elapsed.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::Line;
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::HoverChip;
use crate::app::{App, HOVER_TOOLTIP_DELAY_MS};
use crate::ui::theme;

/// Render the tooltip overlay if a chip has been stably hovered for at least
/// `HOVER_TOOLTIP_DELAY_MS`. Called after every other UI layer so the popup
/// sits on top.
pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    let Some((chip, since)) = app.hover_chip else {
        return;
    };
    if since.elapsed().as_millis() < HOVER_TOOLTIP_DELAY_MS as u128 {
        return;
    }
    let Some((anchor, label, sublabel)) = describe(chip, app) else {
        return;
    };
    // Compose the label as up to two lines: primary action + secondary (right-
    // click) hint. Width = max line + 2 (padding) + 2 (borders).
    let prim_w = label.chars().count();
    let sub_w = sublabel.as_deref().map(|s| s.chars().count()).unwrap_or(0);
    let inner_w = prim_w.max(sub_w) as u16;
    let w = inner_w + 4; // 2 padding + 2 borders
    let h: u16 = if sublabel.is_some() { 4 } else { 3 };
    // Anchor: place above the chip when there's room; else below.
    let want_y = anchor.y.saturating_sub(h);
    let y = if anchor.y >= h {
        want_y
    } else {
        (anchor.y + 1).min(screen.height.saturating_sub(h))
    };
    let x = anchor
        .x
        .min(screen.width.saturating_sub(w))
        .max(screen.x);
    let area = Rect {
        x,
        y: y.max(screen.y),
        width: w.min(screen.width),
        height: h.min(screen.height),
    };
    let t = theme::cur();
    frame.render_widget(Clear, area);
    let mut lines: Vec<Line<'static>> = Vec::new();
    lines.push(Line::styled(
        format!(" {label} "),
        Style::default()
            .fg(t.bg_darker)
            .bg(t.yellow)
            .add_modifier(Modifier::BOLD),
    ));
    if let Some(s) = sublabel {
        lines.push(Line::styled(
            format!(" {s} "),
            Style::default().fg(t.comment).bg(t.bg2),
        ));
    }
    let block = Block::default()
        .borders(Borders::ALL)
        .style(Style::default().fg(t.comment).bg(t.bg2));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

/// `(anchor_rect, primary_line, secondary_line)`. None ⇒ chip's rect isn't
/// registered this frame (chip is hidden, terminal too narrow, etc.) — bail.
fn describe(chip: HoverChip, app: &App) -> Option<(Rect, String, Option<String>)> {
    match chip {
        HoverChip::StatuslineMode => Some((
            app.rects.statusline_mode_chip?,
            "click: toggle vim ⇄ standard".into(),
            Some("right-click: input-style menu".into()),
        )),
        HoverChip::StatuslineBranch => Some((
            app.rects.statusline_branch_chip?,
            "click: open commit graph".into(),
            Some("right-click: git ops menu".into()),
        )),
        HoverChip::StatuslineWorkspace => {
            let primary = if app.repos.len() > 1 {
                "click: switch repo"
            } else {
                "click: repo / worktree menu"
            };
            Some((
                app.rects.statusline_workspace_chip?,
                primary.into(),
                Some("right-click: workspace menu".into()),
            ))
        }
        HoverChip::StatuslineClock => Some((
            app.rects.statusline_clock_chip?,
            "click: local ⇄ UTC".into(),
            Some("right-click: clock menu".into()),
        )),
        HoverChip::RailHeaderChip(action) => {
            let rect = app
                .rects
                .rail_git_header_buttons
                .iter()
                .find(|(_, a)| *a == action)
                .map(|(r, _)| *r)?;
            let label = match action {
                crate::GitRailHeaderAction::Fetch => "fetch",
                crate::GitRailHeaderAction::Pull => "pull",
                crate::GitRailHeaderAction::Push => "push",
                crate::GitRailHeaderAction::StageAll => "stage all changes",
                crate::GitRailHeaderAction::Commit => "commit…",
                crate::GitRailHeaderAction::Graph => "open commit graph",
            };
            Some((rect, label.into(), None))
        }
    }
}
