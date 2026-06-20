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
    // Reset the in-flight indicator rect on every frame; populated
    // below if any async HTTP op is running. Click on the indicator
    // → :http.abort (mirrors Esc-on-bar behavior).
    app.rects.cmdline_inflight = None;
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
    // Build a per-op `name (Ns)` entry so the user sees how long
    // each has been running. Elapsed comes from App.*_started
    // (Instant); falls back to no-suffix if a stamp is missing.
    let now = std::time::Instant::now();
    let fmt_with_elapsed = |name: &str, start: Option<std::time::Instant>| {
        match start {
            Some(s) => format!("{name} ({}s)", now.duration_since(s).as_secs()),
            None => name.to_string(),
        }
    };
    let mut inflight: Vec<String> = Vec::new();
    if app.http_bench_rx.is_some() {
        inflight.push(fmt_with_elapsed("bench", app.http_bench_started));
    }
    if app.http_sync_rx.is_some() {
        inflight.push(fmt_with_elapsed("sync", app.http_sync_started));
    }
    if app.lookup_fire_rx.is_some() {
        inflight.push(fmt_with_elapsed("lookup", app.lookup_fire_started));
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
        let inflight_chars = inflight_text.chars().count();
        let pad = (area.width as usize)
            .saturating_sub(toast_w + inflight_chars)
            .saturating_sub(1);
        spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
        spans.push(Span::styled(
            inflight_text,
            Style::default()
                .fg(t.yellow)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
        // Click rect spans the indicator text only.
        let indicator_x = area.x + (toast_w + pad) as u16;
        app.rects.cmdline_inflight = Some(Rect {
            x: indicator_x,
            y: area.y,
            width: inflight_chars as u16,
            height: 1,
        });
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
