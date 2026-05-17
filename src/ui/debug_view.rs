//! `Pane::Debug` — live DAP session view. Two horizontal sections:
//! 1. Header chips: status (running / stopped / terminated) + thread id
//! 2. Call stack list — `App.dap.stack_frames` (selected row inverted)
//! 3. Output log — `App.dap_output_log` (recent at the bottom)
//!
//! Keyed handlers (see `tui::dispatch_key`'s Pane::Debug arm):
//! - `j`/`k` / arrows / PgUp/PgDn / g/G — move stack selection
//! - Enter — jump active editor to the selected frame's source line
//! - `r` — re-fetch the stack trace (no-op when not stopped)
//! - Esc — focus back to tree

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::{DebugPane, Pane};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, pane_id: PaneId, area: Rect) {
    let Some(Pane::Debug(p)) = app.panes.get(pane_id) else {
        return;
    };
    let t = theme::cur();
    // Split: 1 row header, 60% call stack, 40% output log.
    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Percentage(60),
        Constraint::Min(1),
    ])
    .split(area);
    draw_header(frame, app, chunks[0]);
    draw_stack(frame, app, p, chunks[1]);
    draw_output(frame, app, p, chunks[2]);
    let _ = t;
}

fn draw_header(frame: &mut Frame, app: &App, area: Rect) {
    let t = theme::cur();
    let (label, fg) = match app.dap.as_ref() {
        None => ("no session".to_string(), t.comment),
        Some(mgr) if !mgr.initialized => ("initializing…".to_string(), t.yellow),
        Some(mgr) if mgr.stopped_at.is_some() => {
            let reason = mgr
                .stopped_at
                .as_ref()
                .map(|s| s.3.as_str())
                .unwrap_or("stopped");
            (format!("● stopped ({reason})"), t.red)
        }
        Some(_) => ("▶ running".to_string(), t.green),
    };
    let thread = app
        .dap_thread
        .map(|t| format!("  · thread {t}"))
        .unwrap_or_default();
    let line = Line::from(vec![
        Span::styled(" Debug ", Style::default().fg(t.bg_dark).bg(t.cyan)),
        Span::raw(" "),
        Span::styled(label, Style::default().fg(fg).add_modifier(Modifier::BOLD)),
        Span::styled(thread, Style::default().fg(t.comment)),
    ]);
    frame.render_widget(
        Paragraph::new(line).style(Style::default().bg(t.bg_dark)),
        area,
    );
}

fn draw_stack(frame: &mut Frame, app: &App, p: &DebugPane, area: Rect) {
    let t = theme::cur();
    let frames: &[crate::dap::StackFrame] = app
        .dap
        .as_ref()
        .map(|m| m.stack_frames.as_slice())
        .unwrap_or(&[]);
    let body_h = area.height.saturating_sub(1) as usize;
    let mut lines: Vec<Line> = Vec::with_capacity(body_h + 1);
    lines.push(Line::from(Span::styled(
        " Call stack",
        Style::default()
            .fg(t.fg)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )));
    if frames.is_empty() {
        lines.push(Line::from(Span::styled(
            "  (no frames — start a session + hit a breakpoint)",
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
    } else {
        for (i, f) in frames.iter().enumerate().skip(p.scroll).take(body_h) {
            let sel = i == p.selected;
            let (bg, fg, marker) = if sel {
                (t.cyan, t.bg_darker, "▶ ")
            } else {
                (t.bg_dark, t.fg, "  ")
            };
            let src = f
                .source
                .as_ref()
                .and_then(|p| p.file_name())
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| "(no source)".into());
            let line = format!("{marker}{}:{}  {}", src, f.line, f.name);
            lines.push(Line::from(Span::styled(
                line,
                Style::default().fg(fg).bg(bg),
            )));
        }
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
        area,
    );
}

fn draw_output(frame: &mut Frame, app: &App, p: &DebugPane, area: Rect) {
    let t = theme::cur();
    let body_h = area.height.saturating_sub(1) as usize;
    let log = &app.dap_output_log;
    let mut lines: Vec<Line> = Vec::with_capacity(body_h + 1);
    lines.push(Line::from(Span::styled(
        " Output",
        Style::default()
            .fg(t.fg)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )));
    // Tail: show the last body_h entries (or scroll back via p.output_scroll).
    let total = log.len();
    let want = body_h.min(total);
    let start = total.saturating_sub(want).saturating_sub(p.output_scroll);
    let end = (start + want).min(total);
    for (cat, text) in &log[start..end] {
        let fg = match cat.as_str() {
            "stderr" | "important" => t.red,
            "stdout" | "console" => t.fg,
            "telemetry" => t.comment,
            _ => t.grey_fg,
        };
        // Truncate long lines.
        let mut s = text.clone();
        let max = area.width.saturating_sub(1) as usize;
        if s.chars().count() > max {
            s = s.chars().take(max.saturating_sub(1)).collect::<String>() + "…";
        }
        lines.push(Line::from(Span::styled(
            s,
            Style::default().fg(fg).bg(t.bg_dark),
        )));
    }
    frame.render_widget(
        Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
        area,
    );
}
