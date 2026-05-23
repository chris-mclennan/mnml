//! Renderer for `Pane::LogTail` (`aws-codebuild`-feature only). A
//! scrollable list-of-lines view where each line is colored by its
//! classified severity (`Error` red, `Warn` yellow, `Info` cyan,
//! `Debug` dim, `Plain` foreground). Follows the tail when
//! `scroll == usize::MAX`.

#![cfg(feature = "aws-codebuild")]

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::aws::log_tail_pane::{LineSeverity, LogTailPane};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, pane: &mut LogTailPane, area: Rect) {
    let t = theme::cur();
    frame.render_widget(Paragraph::new("").style(Style::default().bg(t.bg)), area);
    if area.height < 2 || area.width == 0 {
        return;
    }

    // ── header ──
    let total = pane.lines.len();
    let exited = pane.exited.load(std::sync::atomic::Ordering::Relaxed);
    let status_glyph = if exited { "■" } else { "▶" };
    let status_color = if exited { t.comment } else { t.green };
    let header = Line::from(vec![
        Span::styled(
            format!(" {status_glyph} "),
            Style::default()
                .fg(status_color)
                .bg(t.bg)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(pane.title.clone(), Style::default().fg(t.fg).bg(t.bg)),
        Span::styled(
            format!("  · {total} line{}", if total == 1 { "" } else { "s" }),
            Style::default().fg(t.comment).bg(t.bg),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(header),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );

    // ── footer hint ──
    if area.height >= 3 {
        let following = pane.scroll == usize::MAX;
        let hint = Line::from(vec![Span::styled(
            format!(
                " j/k scroll · g/G top/bottom · F follow={} · Esc back ",
                if following { "on" } else { "off" }
            ),
            Style::default().fg(t.comment).bg(t.bg),
        )]);
        frame.render_widget(
            Paragraph::new(hint),
            Rect {
                x: area.x,
                y: area.y + area.height - 1,
                width: area.width,
                height: 1,
            },
        );
    }

    // ── body ──
    let body_top = area.y + 1;
    let body_height = area.height.saturating_sub(2);
    if body_height == 0 {
        return;
    }
    let body_rect = Rect {
        x: area.x,
        y: body_top,
        width: area.width,
        height: body_height,
    };

    // Resolve scroll. `usize::MAX` ⇒ follow the tail: show the last
    // `body_height` lines.
    let total = pane.lines.len();
    let max_top = total.saturating_sub(body_height as usize);
    let top = if pane.scroll == usize::MAX {
        max_top
    } else {
        pane.scroll.min(max_top)
    };
    pane.scroll = if pane.scroll == usize::MAX {
        usize::MAX
    } else {
        top
    };

    let lines: Vec<Line> = pane
        .lines
        .iter()
        .skip(top)
        .take(body_height as usize)
        .map(|l| {
            let fg = match l.severity {
                LineSeverity::Error => t.red,
                LineSeverity::Warn => t.yellow,
                LineSeverity::Info => t.cyan,
                LineSeverity::Debug => t.comment,
                LineSeverity::Plain => t.fg,
            };
            Line::from(Span::styled(
                l.text.clone(),
                Style::default().fg(fg).bg(t.bg),
            ))
        })
        .collect();
    frame.render_widget(Paragraph::new(lines), body_rect);
}
