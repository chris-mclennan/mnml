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
use crate::pane::{DebugPane, DebugSection, Pane};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, pane_id: PaneId, area: Rect) {
    let Some(Pane::Debug(p)) = app.panes.get(pane_id) else {
        return;
    };
    let t = theme::cur();
    // Split: 1-row header, then four equal-ish sections:
    //   call stack (35%) · variables (35%) · output log (rest)
    // Variables panel is read-from-mgr; output rounds out the bottom.
    let chunks = Layout::vertical([
        Constraint::Length(1),
        Constraint::Percentage(35),
        Constraint::Percentage(35),
        Constraint::Min(1),
    ])
    .split(area);
    draw_header(frame, app, chunks[0]);
    draw_stack(frame, app, p, chunks[1]);
    draw_variables(frame, app, p, chunks[2]);
    draw_output(frame, app, p, chunks[3]);
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
    let focused = p.section == DebugSection::Stack;
    let title_fg = if focused { t.yellow } else { t.fg };
    lines.push(Line::from(Span::styled(
        " Call stack",
        Style::default()
            .fg(title_fg)
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
            let (bg, fg, marker) = if sel && focused {
                (t.cyan, t.bg_darker, "▶ ")
            } else if sel {
                (t.bg2, t.fg, "▶ ")
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

fn draw_variables(frame: &mut Frame, app: &App, p: &DebugPane, area: Rect) {
    let t = theme::cur();
    let rows = app
        .dap
        .as_ref()
        .map(|m| m.variable_rows())
        .unwrap_or_default();
    let mut lines: Vec<Line> = Vec::new();
    let focused = p.section == DebugSection::Variables;
    let title_fg = if focused { t.yellow } else { t.fg };
    let watch_count = app.dap_watches.len();
    let title = if watch_count > 0 {
        format!(
            " Variables  ({watch_count} watch{})  (Tab · Enter expands · y yank · w +watch · s set)",
            if watch_count == 1 { "" } else { "es" }
        )
    } else {
        " Variables  (Tab to focus · Enter expands · y yank · w +watch · s set)".to_string()
    };
    lines.push(Line::from(Span::styled(
        title,
        Style::default()
            .fg(title_fg)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )));
    // Watches — render first so they always sit at the top of the panel.
    // Selection rendering targets scope/var rows only; the watches list
    // is read-only here.
    let max_w = area.width.saturating_sub(1) as usize;
    for expr in &app.dap_watches {
        let prefix = "👁 ";
        let value = match app.dap_watch_results.get(expr) {
            Some(r) if r.err.is_some() => {
                format!("err: {}", r.err.as_deref().unwrap_or(""))
            }
            Some(r) if !r.value.is_empty() => {
                if let Some(ty) = &r.ty {
                    format!("{} : {}", r.value, ty)
                } else {
                    r.value.clone()
                }
            }
            _ => "(no value)".to_string(),
        };
        let mut text = format!("{prefix}{expr} = {value}");
        if text.chars().count() > max_w {
            text = text
                .chars()
                .take(max_w.saturating_sub(1))
                .collect::<String>()
                + "…";
        }
        let err = app.dap_watch_results.get(expr).and_then(|r| r.err.clone());
        let fg = if err.is_some() { t.red } else { t.cyan };
        lines.push(Line::from(Span::styled(
            text,
            Style::default().fg(fg).bg(t.bg_dark),
        )));
    }
    if !app.dap_watches.is_empty() {
        // Separator row between watches and scope/var tree.
        lines.push(Line::from(Span::styled(
            " ──────────────",
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
    }
    // Recompute remaining height after rendering watches + separator
    // so the scope/var tree doesn't push past the pane.
    let remaining = area
        .height
        .saturating_sub(1)
        .saturating_sub(lines.len().saturating_sub(1) as u16);
    let scope_body_h = remaining as usize;
    if rows.is_empty() {
        let hint = if app.dap.is_some() {
            "  (waiting for stopped state…)"
        } else {
            "  (no session — start one with dap.run)"
        };
        lines.push(Line::from(Span::styled(
            hint,
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
    } else {
        for (i, row) in rows
            .iter()
            .enumerate()
            .skip(p.vars_scroll)
            .take(scope_body_h)
        {
            let sel = i == p.vars_selected;
            let (bg, fg) = if sel && focused {
                (t.cyan, t.bg_darker)
            } else if sel {
                (t.bg2, t.fg)
            } else {
                (t.bg_dark, t.fg)
            };
            let indent = "  ".repeat(row.depth);
            let chevron = if row.expandable {
                if row.expanded { "▾ " } else { "▸ " }
            } else {
                "  "
            };
            // Compose: indent + chevron + label = value
            // Scope rows render `▾ Locals`, leaf rows `   foo: i32 = 42`,
            // composite rows `▸ bar: Vec`.
            let mut text = format!("{indent}{chevron}{}", row.label);
            if !row.value.is_empty() {
                text.push_str(" = ");
                text.push_str(&row.value);
            }
            // Truncate to area width.
            let max = area.width.saturating_sub(1) as usize;
            if text.chars().count() > max {
                text = text.chars().take(max.saturating_sub(1)).collect::<String>() + "…";
            }
            let modifier = if row.is_scope {
                Modifier::BOLD
            } else {
                Modifier::empty()
            };
            lines.push(Line::from(Span::styled(
                text,
                Style::default().fg(fg).bg(bg).add_modifier(modifier),
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
