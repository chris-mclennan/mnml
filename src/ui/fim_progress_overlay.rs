//! Local-model download progress overlay — a small bottom-centered
//! progress bar shown while `fim-engine` pulls its ~1 GB model on the
//! first use of the local suggestion backend. Reads `App.fim_progress`
//! (written by the FIM worker thread's download callback).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    let progress = match app.fim_progress.lock() {
        Ok(g) => g.clone(),
        Err(p) => p.into_inner().clone(),
    };
    let Some(p) = progress else {
        return;
    };
    let t = theme::cur();

    // Box: ~52 cols, 4 rows, centered horizontally, near the bottom.
    let w = 52u16.min(screen.width);
    let h = 4u16.min(screen.height);
    let x = screen.x + (screen.width.saturating_sub(w)) / 2;
    let y = screen.y.saturating_add(screen.height.saturating_sub(h + 2));
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            " Downloading local model (one-time) ",
            Style::default()
                .fg(t.bg_darker)
                .bg(t.cyan)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width < 4 || inner.height < 2 {
        return;
    }

    // Line 1: label + received/total.
    let fmt_bytes = |b: u64| -> String {
        if b >= 1 << 30 {
            format!("{:.1} GB", b as f64 / (1u64 << 30) as f64)
        } else {
            format!("{:.0} MB", b as f64 / (1u64 << 20) as f64)
        }
    };
    let status = match p.total {
        Some(total) => format!(
            " {} · {} / {}",
            p.label,
            fmt_bytes(p.received),
            fmt_bytes(total)
        ),
        None => format!(" {} · {}", p.label, fmt_bytes(p.received)),
    };
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            status,
            Style::default().fg(t.comment),
        ))),
        Rect::new(inner.x, inner.y, inner.width, 1),
    );

    // Line 2: the bar — filled `█` portion + `░` remainder.
    let bar_w = inner.width as usize;
    let filled = match p.total {
        Some(total) if total > 0 => ((p.received as u128 * bar_w as u128) / total as u128) as usize,
        // Unknown length — show a near-full indeterminate-ish bar.
        _ => bar_w.saturating_sub(1),
    };
    let bar: String =
        "█".repeat(filled.min(bar_w)) + &"░".repeat(bar_w.saturating_sub(filled.min(bar_w)));
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            bar,
            Style::default().fg(t.cyan).bg(t.bg2),
        ))),
        Rect::new(inner.x, inner.y + 1, inner.width, 1),
    );
}
