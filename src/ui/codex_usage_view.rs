//! `Pane::CodexUsage` renderer — a lightweight usage panel for the
//! Codex CLI (`~/.codex/sessions/*.jsonl`).
//!
//! Codex's telemetry surface is much smaller than Claude's — no
//! session %, no weekly %, no per-model scoped limits, no 429
//! negotiation — so this pane is deliberately spare: tokens today,
//! session count, last fetch time, last error if any. Header
//! advertises `r refresh · esc close`; key handling lives in
//! `src/tui/handlers/pane.rs`.
//!
//! 2026-08-16 — new file, split off from the shared `ai_usage_view`
//! when `Pane::AiUsage` fissioned into `Pane::ClaudeUsage` +
//! `Pane::CodexUsage`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::ui::theme;
use crate::ui::usage_time::format_short_time;

pub fn draw(frame: &mut Frame, app: &mut App, pid: PaneId, area: Rect, focused: bool) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let t = theme::cur();
    let header_color = if focused { t.fg } else { t.comment };

    let mut rows: Vec<Line<'static>> = vec![
        Line::from(vec![
            Span::styled(
                " Codex usage ".to_string(),
                Style::default()
                    .fg(header_color)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                "· r refresh · esc close".to_string(),
                Style::default()
                    .fg(t.comment)
                    .add_modifier(Modifier::ITALIC),
            ),
        ]),
        Line::from(""),
    ];

    match &app.ai_usage_codex {
        None => {
            rows.push(Line::from(Span::styled(
                "fetching… (scans ~/.codex/sessions/*.jsonl once mnml boots)".to_string(),
                Style::default().fg(t.comment),
            )));
        }
        Some(u) => {
            // Tokens today
            rows.push(Line::from(Span::styled(
                "Tokens today".to_string(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            )));
            rows.push(Line::from(Span::styled(
                format!("  {}", format_thousands(u.tokens_today)),
                Style::default().fg(t.green),
            )));
            rows.push(Line::from(""));

            // Sessions today
            rows.push(Line::from(Span::styled(
                "Sessions today".to_string(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            )));
            rows.push(Line::from(Span::styled(
                format!(
                    "  {} session{}",
                    u.sessions_today,
                    if u.sessions_today == 1 { "" } else { "s" }
                ),
                Style::default().fg(t.comment),
            )));
            rows.push(Line::from(""));

            // Last fetch
            if u.fetched_at > 0 {
                rows.push(Line::from(Span::styled(
                    format!("  Last scan: {}", format_short_time(u.fetched_at)),
                    Style::default().fg(t.comment),
                )));
                rows.push(Line::from(""));
            }

            // Last error, if any
            if let Some(ref e) = u.last_error {
                rows.push(Line::from(Span::styled(
                    format!("  last scan error: {e}"),
                    Style::default().fg(t.red),
                )));
                rows.push(Line::from(""));
            }

            // Empty-state prompt when nothing was found today
            if u.tokens_today == 0 && u.sessions_today == 0 && u.last_error.is_none() {
                rows.push(Line::from(Span::styled(
                    "  (no Codex sessions today yet — run `codex` to record one)".to_string(),
                    Style::default().fg(t.comment),
                )));
            }
        }
    }

    // Footer hint
    rows.push(Line::from(""));
    rows.push(Line::from(Span::styled(
        " `:ai.refresh_usage` to force scan ".to_string(),
        Style::default()
            .fg(t.comment)
            .add_modifier(Modifier::ITALIC),
    )));

    let total = rows.len();
    let visible = area.height as usize;
    let max_scroll = total.saturating_sub(visible.max(1));
    let scroll = if let Some(crate::pane::Pane::CodexUsage(p)) = app.panes.get_mut(pid) {
        p.scroll = p.scroll.min(max_scroll);
        p.scroll
    } else {
        0
    };

    let visible_rows: Vec<Line<'static>> = rows.into_iter().skip(scroll).collect();
    frame.render_widget(
        Paragraph::new(visible_rows).style(Style::default().fg(t.fg).bg(t.bg)),
        area,
    );
}

/// `1234567` → `1,234,567`. Purely visual — the token counts easily
/// clear a million for a heavy Codex day, and unbroken digit runs
/// are hard to eyeball.
fn format_thousands(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    for (i, ch) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            out.push(',');
        }
        out.push(ch);
    }
    out.chars().rev().collect()
}

#[cfg(test)]
mod tests {
    use super::format_thousands;

    #[test]
    fn thousands_formatting() {
        assert_eq!(format_thousands(0), "0");
        assert_eq!(format_thousands(999), "999");
        assert_eq!(format_thousands(1_000), "1,000");
        assert_eq!(format_thousands(12_345), "12,345");
        assert_eq!(format_thousands(1_234_567), "1,234,567");
        assert_eq!(format_thousands(1_000_000_000), "1,000,000,000");
    }
}
