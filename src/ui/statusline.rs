//! The bottom statusline — segmented; the only place that reads `EditingMode`.
//! Layout (left → right): mode chip · file · spacer · git · Ln:Col · language.
//! A live toast (if any) overlays the spacer area.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(theme::STATUSLINE)), area);
    if area.width == 0 {
        return;
    }
    let width = area.width as usize;

    // ── left segments ──
    let mut left: Vec<Span> = Vec::new();
    let mode = app.editing_mode();
    if let Some(label) = mode.label() {
        left.push(Span::styled(
            format!(" {label} "),
            Style::default().fg(theme::BG_DARKER).bg(mode_color(mode)).add_modifier(Modifier::BOLD),
        ));
    }
    // file name
    let (fname, lang) = match app.active_editor() {
        Some(b) => (
            b.display_name() + if b.dirty { " ●" } else { "" },
            b.language_ext.clone().unwrap_or_else(|| "text".to_string()),
        ),
        None => ("[no file]".to_string(), "text".to_string()),
    };
    left.push(Span::styled(format!(" {fname} "), Style::default().fg(theme::FG).bg(theme::STATUSLINE)));

    // ── right segments ──
    let mut right: Vec<Span> = Vec::new();
    if let Some(branch) = &app.git.snapshot().branch {
        let n = app.git.snapshot().change_count();
        let txt = if n > 0 { format!("  {branch} ±{n} ") } else { format!("  {branch} ") };
        right.push(Span::styled(txt, Style::default().fg(theme::GREEN).bg(theme::STATUSLINE)));
    }
    if let Some(b) = app.active_editor() {
        let (row, col) = b.editor.row_col();
        right.push(Span::styled(
            format!(" Ln {} Col {} ", row + 1, col + 1),
            Style::default().fg(theme::FG).bg(theme::BG2),
        ));
    }
    right.push(Span::styled(format!(" {lang} "), Style::default().fg(theme::BG_DARKER).bg(theme::BLUE).add_modifier(Modifier::BOLD)));

    // ── middle: toast or pending-key hint ──
    let middle = app
        .pending_display()
        .or_else(|| app.live_toast().map(|s| s.to_string()))
        .unwrap_or_default();

    let left_w: usize = left.iter().map(|s| s.content.chars().count()).sum();
    let right_w: usize = right.iter().map(|s| s.content.chars().count()).sum();
    let mid_avail = width.saturating_sub(left_w + right_w);
    let mid_text: String = {
        let m = format!(" {middle} ");
        if m.chars().count() > mid_avail {
            m.chars().take(mid_avail).collect()
        } else {
            let total_pad = mid_avail - m.chars().count();
            let lp = total_pad / 2;
            format!("{}{}{}", " ".repeat(lp), m, " ".repeat(total_pad - lp))
        }
    };
    let mid_style = if app.pending_display().is_some() {
        Style::default().fg(theme::YELLOW).bg(theme::STATUSLINE).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(theme::COMMENT).bg(theme::STATUSLINE)
    };

    let mut spans = left;
    spans.push(Span::styled(mid_text, mid_style));
    spans.extend(right);
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn mode_color(mode: crate::input::EditingMode) -> ratatui::style::Color {
    use crate::input::EditingMode::*;
    match mode {
        Insert => theme::GREEN,
        Visual => theme::PURPLE,
        Normal => theme::BLUE,
        None => theme::GREY,
    }
}
