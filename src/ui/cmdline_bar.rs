//! A 1-row strip that sits BELOW the statusline. Hosts:
//!  - vim `:` ex-command line (when `pending_display()` starts with `:`)
//!  - the most recent toast message, dimmed, as a passive echo
//!  - blank otherwise
//!
//! The vim cmdline previously rendered into the statusline's middle gap;
//! moving it here puts it where vim/neovim users reach for it and gives
//! the statusline gap back to chord-pending state (`d`, `cw`, `gqap` …).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let t = theme::cur();
    // Default — blank line in the statusline's darker bg so it visually
    // belongs with the statusline above.
    let bg = t.bg_darker;

    // Vim cmdline takes priority — `pending_display()` returns `:foo▏bar`
    // form when the user is mid-`:`. Anything that doesn't start with `:`
    // is a chord-pending hint (`d`, `gq`, …) which still belongs in the
    // statusline mid space.
    let pending = app.pending_display();
    if let Some(line) = pending.as_deref()
        && line.starts_with(':')
    {
        let style = Style::default()
            .fg(t.yellow)
            .bg(bg)
            .add_modifier(Modifier::BOLD);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(line.to_string(), style)))
                .style(Style::default().bg(bg)),
            area,
        );
        return;
    }

    // No cmdline → mirror the live toast (dim) so messages persist in a
    // known location, not just floating top-right.
    if let Some(t_msg) = app.live_toast() {
        let style = Style::default().fg(t.comment).bg(bg);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(t_msg.to_string(), style)))
                .style(Style::default().bg(bg)),
            area,
        );
        return;
    }

    // Idle — paint the bg so we don't show a stripe of pane content peeking
    // through if the terminal hasn't been cleared by the parent layer.
    frame.render_widget(
        Paragraph::new(Line::from(Span::raw(""))).style(Style::default().bg(bg)),
        area,
    );
}
