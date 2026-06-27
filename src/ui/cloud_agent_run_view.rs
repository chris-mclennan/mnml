//! Renderer for `Pane::CloudAgentRun`. Lays out the pane top-to-bottom:
//!   1. Summary header (ticket / flow / state / timing)
//!   2. Web-link rows (Jira, PR, CloudWatch, S3) — each clickable
//!   3. Artifacts list (loading… / N rows / error)
//!   4. Logs viewport (scrollable, tail-follow when active)

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Paragraph};

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

/// Click-rect kinds inside a CloudAgentRun pane — used by the
/// mouse dispatcher to know what to do on left-click.
#[derive(Debug, Clone)]
pub enum CloudAgentRunHit {
    /// External URL — opened in the system browser.
    Url(String),
    /// An S3 artifact key — opened via the s3 sibling.
    Artifact(String),
}

pub fn draw(frame: &mut Frame, app: &mut App, pane_id: PaneId, area: Rect, _focused: bool) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let t = theme::cur();
    let bg = t.bg_dark;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(bg)), area);
    app.rects.editor_panes.push((area, pane_id));
    app.rects.cloud_agent_run_hits.clear();

    let Some(Pane::CloudAgentRun(p)) = app.panes.get(pane_id) else {
        return;
    };

    let mut y = area.y;
    let end_y = area.y + area.height;

    // ── header ───────────────────────────────────────────────────
    use crate::cloud_agent_run::CloudRunSource;
    let header_label = match p.source {
        CloudRunSource::TattleQwe => format!("☁ {} · {} · {}", p.ticket, p.flow, p.state),
        CloudRunSource::AnthropicManaged => {
            format!("☁ Managed Agents · {} · {}", p.workspace_name, p.state)
        }
    };
    let header_style = Style::default()
        .fg(t.fg)
        .bg(bg)
        .add_modifier(Modifier::BOLD);
    if y < end_y {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!("  {header_label}"),
                header_style,
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
    }
    if y < end_y {
        // Sub-header: run id + timing
        let when = p
            .last_activity
            .map(|s| {
                use std::time::SystemTime;
                let now = SystemTime::now();
                let secs = now.duration_since(s).map(|d| d.as_secs()).unwrap_or(0);
                if secs < 60 {
                    format!("{secs}s ago")
                } else if secs < 3600 {
                    format!("{}m ago", secs / 60)
                } else if secs < 86400 {
                    format!("{}h ago", secs / 3600)
                } else {
                    format!("{}d ago", secs / 86400)
                }
            })
            .unwrap_or_else(|| "—".to_string());
        let sub = format!("  runId  {} · last activity {when}", short_id(&p.run_id));
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                sub,
                Style::default().fg(t.comment).bg(bg),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 2; // blank gap
    }

    // ── links ────────────────────────────────────────────────────
    let links: Vec<(&str, Option<&String>, &str)> = match p.source {
        CloudRunSource::TattleQwe => vec![
            ("Jira     ", p.jira_url.as_ref(), "open ticket in browser"),
            ("PR       ", p.pr_url.as_ref(), "open pull request"),
            (
                "CloudWatch",
                Some(&p.cloudwatch_url),
                "open Logs Insights query",
            ),
            (
                "S3 console",
                p.s3_console_url.as_ref(),
                "browse artifacts in AWS console",
            ),
        ],
        CloudRunSource::AnthropicManaged => {
            vec![("Session  ", p.pr_url.as_ref(), "open in Anthropic Console")]
        }
    };
    if y < end_y {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  Links",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
    }
    for (label, url_opt, hint) in links {
        if y >= end_y {
            break;
        }
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        if let Some(url) = url_opt {
            let url_text = clip(url, area.width as usize - (label.len() + 6));
            let line = Line::from(vec![
                Span::styled("    ", Style::default().bg(bg)),
                Span::styled(label.to_string(), Style::default().fg(t.comment).bg(bg)),
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    url_text.clone(),
                    Style::default()
                        .fg(t.cyan)
                        .bg(bg)
                        .add_modifier(Modifier::UNDERLINED),
                ),
                Span::styled("   ", Style::default().bg(bg)),
                Span::styled(
                    format!("({hint})"),
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
            ]);
            frame.render_widget(Paragraph::new(line), row_rect);
            app.rects
                .cloud_agent_run_hits
                .push((row_rect, CloudAgentRunHit::Url((*url).clone())));
        } else {
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled("    ", Style::default().bg(bg)),
                    Span::styled(label.to_string(), Style::default().fg(t.comment).bg(bg)),
                    Span::styled("  ", Style::default().bg(bg)),
                    Span::styled(
                        "—",
                        Style::default()
                            .fg(t.comment)
                            .bg(bg)
                            .add_modifier(Modifier::DIM),
                    ),
                ])),
                row_rect,
            );
        }
        y += 1;
    }
    y += 1; // gap

    // ── artifacts ────────────────────────────────────────────────
    // Managed Agents don't write S3 artifacts. Skip.
    if matches!(p.source, CloudRunSource::AnthropicManaged) {
        // fall through to logs section (also stubbed for managed).
    } else if y < end_y {
        let count = p.artifacts.len();
        let header = if p.artifacts_loading {
            "  Artifacts (loading…)".to_string()
        } else if p.artifacts_err.is_some() {
            "  Artifacts (error)".to_string()
        } else if count == 0 {
            "  Artifacts (none)".to_string()
        } else {
            format!("  Artifacts ({count})")
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                header,
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
    }
    if let Some(err) = p.artifacts_err.as_ref()
        && y < end_y
    {
        {
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    format!("    {err}"),
                    Style::default().fg(t.red).bg(bg),
                ))),
                Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                },
            );
            y += 1;
        }
    }
    // Show up to 5 artifacts inline; the rest are reachable via the
    // S3 console URL above. Keeps the pane compact.
    let artifact_cap = 5usize;
    for art in p.artifacts.iter().take(artifact_cap) {
        if y >= end_y {
            break;
        }
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        let size_text = art
            .size_bytes
            .map(|b| format!(" ({} bytes)", b))
            .unwrap_or_default();
        let line = Line::from(vec![
            Span::styled("    ", Style::default().bg(bg)),
            Span::styled("·", Style::default().fg(t.comment).bg(bg)),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(art.display.clone(), Style::default().fg(t.fg).bg(bg)),
            Span::styled(size_text, Style::default().fg(t.comment).bg(bg)),
        ]);
        frame.render_widget(Paragraph::new(line), row_rect);
        app.rects
            .cloud_agent_run_hits
            .push((row_rect, CloudAgentRunHit::Artifact(art.key.clone())));
        y += 1;
    }
    if p.artifacts.len() > artifact_cap && y < end_y {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!(
                    "    + {} more (S3 console link above)",
                    p.artifacts.len() - artifact_cap
                ),
                Style::default().fg(t.comment).bg(bg),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
    }
    y += 1;

    // ── logs ─────────────────────────────────────────────────────
    // Both sources share the logs viewport. Tattle fills it from
    // CloudWatch via log_rx; managed agents fill it from the SSE
    // session-events stream via session_event_rx (drained in
    // CloudAgentRunPane::drain).
    if y >= end_y {
        return;
    }
    let log_box = Rect {
        x: area.x,
        y,
        width: area.width,
        height: end_y - y,
    };
    let title = if p.logs_loading {
        format!(" Logs (loading…) · {} ", p.run_id)
    } else if p.logs_err.is_some() {
        " Logs (error) ".to_string()
    } else if p.log_follow {
        format!(" Logs (following · {} lines) ", p.logs.len())
    } else {
        format!(" Logs ({} lines) ", p.logs.len())
    };
    let block = Block::default()
        .borders(Borders::TOP)
        .title(Span::styled(
            title,
            Style::default().fg(t.comment).add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(bg));
    let inner = block.inner(log_box);
    frame.render_widget(block, log_box);

    if let Some(err) = p.logs_err.as_ref() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!("  {err}"),
                Style::default().fg(t.red).bg(bg),
            ))),
            Rect {
                x: inner.x,
                y: inner.y,
                width: inner.width,
                height: 1,
            },
        );
        return;
    }
    if inner.height == 0 {
        return;
    }
    let visible_h = inner.height as usize;
    let total = p.logs.len();
    let start = if p.log_scroll == usize::MAX || total <= visible_h {
        total.saturating_sub(visible_h)
    } else {
        p.log_scroll.min(total.saturating_sub(visible_h))
    };
    let end_log = (start + visible_h).min(total);
    let lines: Vec<Line> = p
        .logs
        .get(start..end_log)
        .unwrap_or(&[])
        .iter()
        .map(|l| {
            Line::from(Span::styled(
                l.text.clone(),
                Style::default().fg(t.fg).bg(bg),
            ))
        })
        .collect();
    frame.render_widget(Paragraph::new(lines), inner);
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn short_id(id: &str) -> String {
    if id.chars().count() <= 12 {
        id.to_string()
    } else {
        let s: String = id.chars().take(8).collect();
        format!("{s}…")
    }
}
