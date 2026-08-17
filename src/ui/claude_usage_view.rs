//! `Pane::ClaudeUsage` renderer — the full Claude usage panel, ported
//! from the retired centered-modal overlay into a proper pane.
//! Shows the same content: session %, weekly %, per-model scoped
//! limits, resets, retry-after status, last error.
//!
//! Data source is `App::ai_usage_claude_accounts` (populated by
//! the per-account fetchers that also feed the statusline chip).
//! Task #944 (2026-08-16) — one titled section per configured
//! account, stacked vertically. Header advertises the `r refresh
//! · esc close` hints; the actual key handler lives in
//! `src/tui/handlers/pane.rs`.
//!
//! 2026-08-16 — this file was `ai_usage_view.rs` before the
//! `Pane::AiUsage` → `Pane::ClaudeUsage`/`Pane::CodexUsage` split;
//! the Codex-side renderer lives in `codex_usage_view.rs`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::ui::theme;
use crate::ui::usage_time::{format_long_time, format_short_time};

/// Bar width in cells. Was hard-coded to 60 in the overlay; here we
/// clamp to the available body width minus the `" N% used"` suffix
/// so a narrow pane still renders a bar rather than clipping off.
const MAX_BAR_WIDTH: u16 = 60;
const SUFFIX_CELLS: u16 = 10; // ` 100% used` = 10 cells

pub fn draw(frame: &mut Frame, app: &mut App, pid: PaneId, area: Rect, focused: bool) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let t = theme::cur();

    // Header row inside the pane body — mirrors the "Esc to dismiss"
    // affordance the overlay had, adjusted for the pane world where
    // Esc focuses the tree and `r` refreshes.
    let header_color = if focused { t.fg } else { t.comment };
    let mut rows: Vec<Line<'static>> = vec![
        Line::from(vec![
            Span::styled(
                " Claude usage ".to_string(),
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

    let bar_w = area
        .width
        .saturating_sub(SUFFIX_CELLS + 2)
        .min(MAX_BAR_WIDTH);

    // Task #944 (2026-08-16) — one titled section per configured
    // account. Sections are `── personal (active) ──` style; each
    // shows Session + Weekly + scoped limits + retry-after + errors
    // for that account, identical to the pre-multi-account render
    // (which was implicitly a single-account view).
    let accounts = app.ai_usage_claude_accounts.clone();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    if accounts.is_empty() {
        rows.push(Line::from(Span::styled(
            "fetching… (link a token via `:ai.link_claude_token`)".to_string(),
            Style::default().fg(t.comment),
        )));
    } else {
        for (i, account) in accounts.iter().enumerate() {
            let usage = &account.usage;
            let heading = if account.is_active {
                format!("── {} (active) ──", account.name)
            } else {
                format!("── {} ──", account.name)
            };
            rows.push(Line::from(Span::styled(
                heading,
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            )));
            rows.push(Line::from(""));

            // Session
            rows.push(Line::from(Span::styled(
                "Current session".to_string(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            )));
            rows.push(bar_row(usage.percent, bar_w, &t));
            rows.push(reset_row(usage.resets_at, &t));
            rows.push(Line::from(""));

            // Weekly (all models)
            rows.push(Line::from(Span::styled(
                "Current week (all models)".to_string(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            )));
            rows.push(bar_row(usage.weekly_percent, bar_w, &t));
            rows.push(reset_row_weekly(usage.weekly_resets_at, &t));
            rows.push(Line::from(""));

            // Per-model scoped limits (e.g. Fable)
            for scoped in &usage.scoped_limits {
                rows.push(Line::from(Span::styled(
                    format!("Current week ({})", scoped.model_display_name),
                    Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
                )));
                rows.push(bar_row(scoped.percent, bar_w, &t));
                if scoped.resets_at > 0 {
                    rows.push(reset_row_weekly(scoped.resets_at, &t));
                }
                rows.push(Line::from(""));
            }

            // Retry-after — surfaced when Anthropic told THIS account
            // to back off.
            if usage.retry_after_at > now {
                let remaining = usage.retry_after_at - now;
                rows.push(Line::from(Span::styled(
                    format!("  Anthropic asked us to retry in {}s (429)", remaining),
                    Style::default().fg(t.yellow),
                )));
                rows.push(Line::from(""));
            }

            // Per-account empty state / stale-data hint
            if usage.percent == 0 && usage.weekly_percent == 0 && usage.scoped_limits.is_empty() {
                rows.push(Line::from(Span::styled(
                    match usage.last_error {
                        Some(ref e) => format!("no data yet · last error: {e}"),
                        None => "fetching…".to_string(),
                    },
                    Style::default().fg(t.comment),
                )));
            } else if let Some(ref e) = usage.last_error {
                rows.push(Line::from(Span::styled(
                    format!("  last fetch error: {e}"),
                    Style::default().fg(t.red),
                )));
            }

            // Blank separator between accounts (skip after the last)
            if i + 1 < accounts.len() {
                rows.push(Line::from(""));
            }
        }
    }

    // Footer hint
    rows.push(Line::from(""));
    rows.push(Line::from(Span::styled(
        " `:ai.refresh_usage` to force fetch · `:ai.show_last_response` for raw JSON ".to_string(),
        Style::default()
            .fg(t.comment)
            .add_modifier(Modifier::ITALIC),
    )));

    // Apply the pane's scroll offset. Clamp so `j` past the end
    // doesn't blank the pane.
    let total = rows.len();
    let visible = area.height as usize;
    let max_scroll = total.saturating_sub(visible.max(1));
    let scroll = if let Some(crate::pane::Pane::ClaudeUsage(p)) = app.panes.get_mut(pid) {
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

/// Progress bar row — full-width filled/empty frame + `N% used`
/// suffix. Color: green <60%, yellow 60-85%, red 85%+. The empty
/// portion uses a solid mid-tone background so the FRAME is always
/// visible even at 0% (overlay-era report 2026-08-05: 0% Fable
/// rendered as "nothing there").
fn bar_row(percent: u16, bar_w: u16, t: &crate::ui::theme::Theme) -> Line<'static> {
    let clamped = percent.min(100);
    let filled_w = ((bar_w as u32) * (clamped as u32) / 100) as u16;
    let empty_w = bar_w.saturating_sub(filled_w);
    let color = if percent >= 85 {
        t.red
    } else if percent >= 60 {
        t.yellow
    } else {
        t.purple
    };
    let filled: String = " ".repeat(filled_w as usize);
    let empty: String = " ".repeat(empty_w as usize);
    Line::from(vec![
        Span::styled(filled, Style::default().bg(color)),
        Span::styled(empty, Style::default().bg(t.bg2)),
        Span::styled(
            format!(" {}% used", percent),
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
        ),
    ])
}

fn reset_row(resets_at: u64, t: &crate::ui::theme::Theme) -> Line<'static> {
    if resets_at == 0 {
        return Line::from(Span::styled(
            "  (reset time not available)".to_string(),
            Style::default().fg(t.comment),
        ));
    }
    let short = format_short_time(resets_at);
    Line::from(Span::styled(
        format!("  Resets {short}"),
        Style::default().fg(t.comment),
    ))
}

fn reset_row_weekly(resets_at: u64, t: &crate::ui::theme::Theme) -> Line<'static> {
    if resets_at == 0 {
        return Line::from(Span::styled(
            "  (reset time not available)".to_string(),
            Style::default().fg(t.comment),
        ));
    }
    let full = format_long_time(resets_at);
    Line::from(Span::styled(
        format!("  Resets {full}"),
        Style::default().fg(t.comment),
    ))
}
