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

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    if area.width == 0 || area.height == 0 {
        app.rects.cmdline_bar = None;
        return;
    }
    // Register the bar's rect so a click here opens the ex-cmdline.
    // Same affordance as typing `:` from anywhere — gives the user
    // a mouse path to the cmdline that doesn't require knowing the
    // chord. User-requested 2026-06-18.
    app.rects.cmdline_bar = Some(area);
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

    // 2026-06-19 polish — show in-flight async HTTP work as a
    // persistent status indicator. Transient toasts fade after
    // ~3s; long-running ops (bench, sync, lookup) used to leave
    // the user with no visible progress signal. Right side of
    // the bar so it doesn't fight with the toast echo.
    let mut inflight: Vec<&str> = Vec::new();
    if app.http_bench_rx.is_some() {
        inflight.push("bench");
    }
    if app.http_sync_rx.is_some() {
        inflight.push("sync");
    }
    if app.lookup_fire_rx.is_some() {
        inflight.push("lookup");
    }

    // No cmdline → mirror the live toast (dim) so messages persist in a
    // known location, not just floating top-right.
    let toast = app.live_toast().map(|s| s.to_string());
    let inflight_text = if inflight.is_empty() {
        String::new()
    } else {
        format!("⟳ {} running…", inflight.join(", "))
    };

    let mut spans: Vec<Span<'static>> = Vec::new();
    if let Some(t_msg) = toast {
        spans.push(Span::styled(
            t_msg,
            Style::default().fg(t.comment).bg(bg),
        ));
    }
    if !inflight_text.is_empty() {
        // Pad to right-align the inflight indicator. Computed
        // against the visible width of the toast on the left.
        let toast_w: usize = spans
            .iter()
            .map(|s| s.content.chars().count())
            .sum();
        let pad = (area.width as usize)
            .saturating_sub(toast_w + inflight_text.chars().count())
            .saturating_sub(1);
        spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
        spans.push(Span::styled(
            inflight_text,
            Style::default()
                .fg(t.yellow)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
    }

    if spans.is_empty() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::raw(""))).style(Style::default().bg(bg)),
            area,
        );
    } else {
        frame.render_widget(
            Paragraph::new(Line::from(spans)).style(Style::default().bg(bg)),
            area,
        );
    }
}
