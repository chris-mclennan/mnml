//! Renderer for `Pane::NewCloudRunWizard` — Cloud Agents version
//! of the new-agent wizard. Picks a runner (Managed Agents / QWE),
//! collects per-runner config, fires the run.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::new_cloud_run_wizard::{CloudRunStep, CloudRunner, SandboxLocation};
use crate::pane::Pane;
use crate::ui::theme;

#[derive(Debug, Clone)]
pub enum CloudRunHit {
    Option(usize),
    Back,
    Next,
}

pub fn draw(frame: &mut Frame, app: &mut App, pane_id: PaneId, area: Rect, _focused: bool) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let t = theme::cur();
    let bg = t.bg_dark;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(bg)), area);
    app.rects.editor_panes.push((area, pane_id));
    app.rects.new_cloud_run_wizard_hits.clear();

    let (step, last_message) = match app.panes.get(pane_id) {
        Some(Pane::NewCloudRunWizard(p)) => (p.step, p.last_message.clone()),
        _ => return,
    };

    let mut y = area.y;

    if y < area.y + area.height {
        let title = format!("  + New Cloud Run   ·   {}", step_label(step));
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                title,
                Style::default()
                    .fg(t.fg)
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
    if y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!("  {}", crumbs(step)),
                Style::default().fg(t.comment).bg(bg),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 2;
    }

    let body_h = (area.y + area.height).saturating_sub(y + 3);
    if body_h == 0 {
        return;
    }
    let body = Rect {
        x: area.x,
        y,
        width: area.width,
        height: body_h,
    };
    match step {
        CloudRunStep::Runner => draw_step_runner(frame, app, body, pane_id),
        CloudRunStep::ManagedAgent => draw_step_managed_agent(frame, app, body, pane_id),
        CloudRunStep::ManagedSandbox => draw_step_managed_sandbox(frame, app, body, pane_id),
        CloudRunStep::QweTicket => draw_step_qwe_ticket(frame, app, body, pane_id),
        CloudRunStep::Prompt => draw_step_prompt(frame, app, body, pane_id),
        CloudRunStep::Review => draw_step_review(frame, app, body, pane_id),
    }

    // Footer
    let footer_y = area.y + area.height - 2;
    let hint_y = area.y + area.height - 1;
    let back_chip = " ← Back ";
    let next_label = if matches!(step, CloudRunStep::Review) {
        " Submit ✓ "
    } else {
        " Next → "
    };
    let back_w = back_chip.chars().count() as u16;
    let next_w = next_label.chars().count() as u16;
    let back_rect = Rect {
        x: area.x + 2,
        y: footer_y,
        width: back_w,
        height: 1,
    };
    let next_rect = Rect {
        x: area.x + 2 + back_w + 2,
        y: footer_y,
        width: next_w,
        height: 1,
    };
    let back_style = if matches!(step, CloudRunStep::Runner) {
        Style::default().fg(t.comment).bg(t.bg2)
    } else {
        Style::default().fg(t.fg).bg(t.bg2)
    };
    let next_style = Style::default()
        .fg(t.bg_dark)
        .bg(t.green)
        .add_modifier(Modifier::BOLD);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(back_chip.to_string(), back_style))),
        back_rect,
    );
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(next_label.to_string(), next_style))),
        next_rect,
    );
    app.rects
        .new_cloud_run_wizard_hits
        .push((back_rect, CloudRunHit::Back));
    app.rects
        .new_cloud_run_wizard_hits
        .push((next_rect, CloudRunHit::Next));

    let hint = match last_message {
        Some(m) => format!("  {m}"),
        None => "  ↑↓/jk select · Enter advance · Esc close ".to_string(),
    };
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            hint,
            Style::default().fg(t.comment).bg(bg),
        ))),
        Rect {
            x: area.x,
            y: hint_y,
            width: area.width,
            height: 1,
        },
    );
}

fn step_label(s: CloudRunStep) -> &'static str {
    match s {
        CloudRunStep::Runner => "Step 1 · Runner",
        CloudRunStep::ManagedAgent => "Step 2 · Managed agent",
        CloudRunStep::ManagedSandbox => "Step 3 · Sandbox",
        CloudRunStep::QweTicket => "Step 2 · Jira ticket",
        CloudRunStep::Prompt => "Step · Prompt",
        CloudRunStep::Review => "Step · Review & submit",
    }
}

fn crumbs(s: CloudRunStep) -> String {
    match s {
        CloudRunStep::Runner => "Runner".to_string(),
        CloudRunStep::ManagedAgent => "Runner › Agent".to_string(),
        CloudRunStep::ManagedSandbox => "Runner › Agent › Sandbox".to_string(),
        CloudRunStep::QweTicket => "Runner › Ticket".to_string(),
        CloudRunStep::Prompt => "… › Prompt".to_string(),
        CloudRunStep::Review => "… › Review".to_string(),
    }
}

fn draw_radio(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    pane_id: PaneId,
    rows: &[(&'static str, &'static str, bool)],
) {
    let t = theme::cur();
    let bg = t.bg_dark;
    let focus = match app.panes.get(pane_id) {
        Some(Pane::NewCloudRunWizard(p)) => p.focus_row,
        _ => 0,
    };
    for (i, (label, hint, picked)) in rows.iter().enumerate() {
        let y = area.y + i as u16;
        if y >= area.y + area.height {
            break;
        }
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        let glyph = if *picked { "●" } else { "○" };
        let glyph_style = if *picked {
            Style::default().fg(t.green).bg(bg)
        } else {
            Style::default().fg(t.comment).bg(bg)
        };
        let label_style = if i == focus {
            Style::default()
                .fg(t.fg)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(bg)
        };
        let cursor = if i == focus { "▸" } else { " " };
        let line = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(format!("{cursor} "), Style::default().fg(t.cyan).bg(bg)),
            Span::styled(format!("{glyph}  "), glyph_style),
            Span::styled(label.to_string(), label_style),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                hint.to_string(),
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
        ]);
        frame.render_widget(Paragraph::new(line), row_rect);
        app.rects
            .new_cloud_run_wizard_hits
            .push((row_rect, CloudRunHit::Option(i)));
    }
}

fn draw_step_runner(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let runner = match app.panes.get(pane_id) {
        Some(Pane::NewCloudRunWizard(p)) => p.runner,
        _ => return,
    };
    let rows: Vec<(&'static str, &'static str, bool)> = CloudRunner::all()
        .iter()
        .map(|r| (r.label(), r.hint(), *r == runner))
        .collect();
    draw_radio(frame, app, area, pane_id, &rows);
}

fn draw_step_managed_agent(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let (create_new, new_name, existing_id) = match app.panes.get(pane_id) {
        Some(Pane::NewCloudRunWizard(p)) => (
            p.managed_agent_create_new,
            p.managed_agent_new_name.clone(),
            p.managed_agent_id.clone(),
        ),
        _ => return,
    };
    let rows = vec![
        (
            "Create a new agent",
            "POST /v1/agents — name + claude-opus-4-8 + agent_toolset_20260401",
            create_new,
        ),
        (
            "Use existing agent",
            "Paste an agent_… id (from console.anthropic.com or earlier wizard run)",
            !create_new,
        ),
    ];
    draw_radio(frame, app, area, pane_id, &rows);
    let t = theme::cur();
    let bg = t.bg_dark;
    let extra_y = area.y + 3;
    if extra_y < area.y + area.height {
        let (label, val) = if create_new {
            ("Name   ", new_name)
        } else {
            ("agent_id ", existing_id)
        };
        let display = if val.is_empty() {
            " …".to_string()
        } else {
            val
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("    ", Style::default().bg(bg)),
                Span::styled(label.to_string(), Style::default().fg(t.comment).bg(bg)),
                Span::styled(format!(" {display} ▏"), Style::default().fg(t.fg).bg(t.bg2)),
            ])),
            Rect {
                x: area.x,
                y: extra_y,
                width: area.width,
                height: 1,
            },
        );
    }
}

fn draw_step_managed_sandbox(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let sandbox = match app.panes.get(pane_id) {
        Some(Pane::NewCloudRunWizard(p)) => p.sandbox,
        _ => return,
    };
    let rows: Vec<(&'static str, &'static str, bool)> = SandboxLocation::all()
        .iter()
        .map(|s| (s.label(), s.hint(), *s == sandbox))
        .collect();
    draw_radio(frame, app, area, pane_id, &rows);
}

fn draw_step_qwe_ticket(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let t = theme::cur();
    let bg = t.bg_dark;
    let ticket = match app.panes.get(pane_id) {
        Some(Pane::NewCloudRunWizard(p)) => p.qwe_ticket.clone(),
        _ => return,
    };
    let mut y = area.y;
    if y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  Jira ticket (TE-NNNNN). Flow defaults to triage; env to prod.",
                Style::default().fg(t.comment).bg(bg),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 2;
    }
    if y < area.y + area.height {
        let label = if ticket.is_empty() {
            "TE-".to_string()
        } else {
            ticket
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("    ", Style::default().bg(bg)),
                Span::styled("Ticket  ", Style::default().fg(t.comment).bg(bg)),
                Span::styled(
                    format!(" {label} ▏"),
                    Style::default()
                        .fg(t.fg)
                        .bg(t.bg2)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
    }
}

fn draw_step_prompt(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let t = theme::cur();
    let bg = t.bg_dark;
    let prompt = match app.panes.get(pane_id) {
        Some(Pane::NewCloudRunWizard(p)) => p.prompt.clone(),
        _ => return,
    };
    let mut y = area.y;
    if y < area.y + area.height {
        let hint_text = match app.panes.get(pane_id).and_then(|p| {
            if let Pane::NewCloudRunWizard(w) = p {
                Some(w.runner)
            } else {
                None
            }
        }) {
            Some(CloudRunner::ManagedAgents) => {
                "  Initial user message — what the agent should do."
            }
            Some(CloudRunner::TattleQwe) => {
                "  Free-form context for the qwe-runner triage (optional — ticket carries the work)."
            }
            None => "  Initial prompt",
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                hint_text,
                Style::default().fg(t.comment).bg(bg),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 2;
    }
    if y < area.y + area.height {
        let display = if prompt.is_empty() {
            "_".to_string()
        } else {
            prompt.replace('\n', " ⏎ ")
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("    ", Style::default().bg(bg)),
                Span::styled("Prompt  ", Style::default().fg(t.comment).bg(bg)),
                Span::styled(format!(" {display} ▏"), Style::default().fg(t.fg).bg(t.bg2)),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
    }
}

fn draw_step_review(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let t = theme::cur();
    let bg = t.bg_dark;
    let summary: Vec<(&str, String)> = match app.panes.get(pane_id) {
        Some(Pane::NewCloudRunWizard(p)) => match p.runner {
            CloudRunner::TattleQwe => vec![
                ("Runner ", "Tattle QWE (ECS)".to_string()),
                ("Ticket ", p.qwe_ticket.clone()),
                ("Flow   ", "triage (default)".to_string()),
                ("Env    ", "prod (default)".to_string()),
                ("Prompt ", p.prompt.clone()),
            ],
            CloudRunner::ManagedAgents => {
                let agent_desc = if p.managed_agent_create_new {
                    format!("create new · {}", p.managed_agent_new_name)
                } else {
                    p.managed_agent_id.clone()
                };
                let sandbox_desc = p.sandbox.label().to_string();
                vec![
                    ("Runner ", "Managed Agents (Anthropic)".to_string()),
                    ("Agent  ", agent_desc),
                    ("Sandbox", sandbox_desc),
                    ("Prompt ", p.prompt.clone()),
                ]
            }
        },
        _ => return,
    };
    for (i, (k, v)) in summary.into_iter().enumerate() {
        let y = area.y + i as u16;
        if y >= area.y + area.height {
            break;
        }
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("    ", Style::default().bg(bg)),
                Span::styled(format!("{k} "), Style::default().fg(t.comment).bg(bg)),
                Span::styled(
                    if v.is_empty() { "—".to_string() } else { v },
                    Style::default().fg(t.fg).bg(bg),
                ),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
    }
}
