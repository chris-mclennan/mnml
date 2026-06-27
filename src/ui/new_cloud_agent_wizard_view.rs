//! Renderer for `Pane::NewCloudAgentWizard`. Stacked-form layout:
//!   • Header (step indicator)
//!   • Step content (radios / text input)
//!   • Footer (Back / Next / Submit + hint)

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::new_cloud_agent_wizard::{AgentKind, RemoteTarget, SandboxMode, WizardStep};
use crate::pane::Pane;
use crate::ui::theme;

/// Click-rect kinds inside the wizard.
#[derive(Debug, Clone)]
pub enum WizardHit {
    /// Pick a radio option on the current step. Payload is the row
    /// index — handler interprets per-step.
    Option(usize),
    /// Hit the Back button.
    Back,
    /// Hit the Next / Submit button.
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
    app.rects.new_cloud_agent_wizard_hits.clear();

    let step = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.step,
        _ => return,
    };
    let last_message = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.last_message.clone(),
        _ => None,
    };

    let mut y = area.y;

    // ── header ──────────────────────────────────────────────────
    if y < area.y + area.height {
        let title = format!("  + New Cloud Agent   ·   {}", step_label(step));
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
        let crumbs = breadcrumbs(step);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!("  {crumbs}"),
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

    // ── step body ───────────────────────────────────────────────
    let body_top = y;
    let body_h = area.y + area.height - y - 3; // 3 rows for footer + hint
    if body_h == 0 {
        return;
    }
    let body = Rect {
        x: area.x,
        y,
        width: area.width,
        height: body_h,
    };
    let _ = body_top;
    let next_y = match step {
        WizardStep::Kind => draw_step_kind(frame, app, body, pane_id),
        WizardStep::TattleTicket => draw_step_tattle_ticket(frame, app, body, pane_id),
        WizardStep::ClaudeAgent => draw_step_claude_agent(frame, app, body, pane_id),
        WizardStep::ClaudeSandbox => draw_step_claude_sandbox(frame, app, body, pane_id),
        WizardStep::ClaudeRemoteTarget => draw_step_claude_remote_target(frame, app, body, pane_id),
        WizardStep::Prompt => draw_step_prompt(frame, app, body, pane_id),
        WizardStep::Review => draw_step_review(frame, app, body, pane_id),
    };
    let _ = next_y;

    // ── footer (Back / Next) + hint ─────────────────────────────
    let footer_y = area.y + area.height - 2;
    let hint_y = area.y + area.height - 1;
    let back_chip = " ← Back ";
    let next_label = if matches!(step, WizardStep::Review) {
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
    let back_style = if matches!(step, WizardStep::Kind) {
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
        .new_cloud_agent_wizard_hits
        .push((back_rect, WizardHit::Back));
    app.rects
        .new_cloud_agent_wizard_hits
        .push((next_rect, WizardHit::Next));

    let hint = "  Tab move · ↑↓/jk select · Enter advance · Esc close ";
    let hint = if let Some(msg) = last_message.as_ref() {
        format!("  {msg}")
    } else {
        hint.to_string()
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

fn step_label(s: WizardStep) -> &'static str {
    match s {
        WizardStep::Kind => "Step 1 · Agent kind",
        WizardStep::TattleTicket => "Step 2 · Pick ticket",
        WizardStep::ClaudeAgent => "Step 2 · Agent",
        WizardStep::ClaudeSandbox => "Step 3 · Sandbox mode",
        WizardStep::ClaudeRemoteTarget => "Step 4 · Remote target",
        WizardStep::Prompt => "Step · Initial task",
        WizardStep::Review => "Step · Review & submit",
    }
}

fn breadcrumbs(s: WizardStep) -> String {
    match s {
        WizardStep::Kind => "Kind".to_string(),
        WizardStep::TattleTicket => "Kind › Ticket".to_string(),
        WizardStep::ClaudeAgent => "Kind › Agent".to_string(),
        WizardStep::ClaudeSandbox => "Kind › Agent › Sandbox".to_string(),
        WizardStep::ClaudeRemoteTarget => "Kind › Agent › Sandbox › Remote".to_string(),
        WizardStep::Prompt => "… › Task".to_string(),
        WizardStep::Review => "… › Review".to_string(),
    }
}

fn draw_radio_list(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    pane_id: PaneId,
    rows: &[(&'static str, &'static str, bool)],
) {
    let _ = pane_id;
    let t = theme::cur();
    let bg = t.bg_dark;
    let focus = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.focus_row,
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
            .new_cloud_agent_wizard_hits
            .push((row_rect, WizardHit::Option(i)));
    }
}

fn draw_step_kind(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) -> u16 {
    let kind = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.kind,
        _ => return area.y,
    };
    let rows = vec![
        (
            "Tattle QWE run",
            "Trigger a qwe-runner ECS task for a Jira ticket",
            matches!(kind, AgentKind::TattleQwe),
        ),
        (
            "Claude managed agent",
            "Anthropic-hosted Claude · cloud OR self-hosted sandbox",
            matches!(kind, AgentKind::ClaudeManaged),
        ),
    ];
    draw_radio_list(frame, app, area, pane_id, &rows);
    area.y + 2
}

fn draw_step_tattle_ticket(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) -> u16 {
    let t = theme::cur();
    let bg = t.bg_dark;
    let ticket = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.tattle_ticket.clone(),
        _ => return area.y,
    };
    let mut y = area.y;
    let hint = "  Type a Jira ticket id (e.g. TE-13877) — flow defaults to triage, env to prod.";
    if y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                hint,
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
        y += 1;
    }
    y
}

fn draw_step_claude_agent(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) -> u16 {
    let p = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => (
            p.claude_agent_create_new,
            p.claude_agent_new_name.clone(),
            p.claude_agent_id.clone(),
        ),
        _ => return area.y,
    };
    let (create_new, new_name, existing_id) = p;
    let rows = vec![
        (
            "Create a new agent",
            "POST /v1/agents — name + model + tools",
            create_new,
        ),
        (
            "Use existing agent",
            "Paste an ag_… id from console.anthropic.com",
            !create_new,
        ),
    ];
    draw_radio_list(frame, app, area, pane_id, &rows);
    let t = theme::cur();
    let bg = t.bg_dark;
    let extra_y = area.y + 3;
    if extra_y < area.y + area.height {
        let (label, val) = if create_new {
            ("Name   ", new_name)
        } else {
            ("ag_id  ", existing_id)
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
    area.y + 4
}

fn draw_step_claude_sandbox(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) -> u16 {
    let sandbox = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.claude_sandbox,
        _ => return area.y,
    };
    let rows = vec![
        (
            "Cloud sandbox (Anthropic-managed)",
            "Default · zero setup · tool calls run on Anthropic infra",
            matches!(sandbox, SandboxMode::CloudSandbox),
        ),
        (
            "Self-hosted · LOCAL worker",
            "ant beta:worker poll runs on this machine · uses local files + network",
            matches!(sandbox, SandboxMode::SelfHostedLocal),
        ),
        (
            "Self-hosted · REMOTE worker",
            "Worker on Vercel / Cloudflare / Modal / AWS · survives laptop close",
            matches!(sandbox, SandboxMode::SelfHostedRemote),
        ),
    ];
    draw_radio_list(frame, app, area, pane_id, &rows);
    area.y + 3
}

fn draw_step_claude_remote_target(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    pane_id: PaneId,
) -> u16 {
    let picked = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.claude_remote,
        _ => return area.y,
    };
    let rows: Vec<(&'static str, &'static str, bool)> = RemoteTarget::all()
        .iter()
        .map(|tgt| (tgt.label(), tgt.hint(), *tgt == picked))
        .collect();
    draw_radio_list(frame, app, area, pane_id, &rows);
    area.y + rows.len() as u16
}

fn draw_step_prompt(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) -> u16 {
    let t = theme::cur();
    let bg = t.bg_dark;
    let prompt = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.prompt.clone(),
        _ => return area.y,
    };
    let mut y = area.y;
    let hint = "  Initial task / prompt for the agent. Multi-line OK; metadata as KEY=VAL lines.";
    if y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                hint,
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
    let display = if prompt.is_empty() {
        "_".to_string()
    } else {
        prompt.replace('\n', " ⏎ ")
    };
    if y < area.y + area.height {
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
    y
}

fn draw_step_review(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) -> u16 {
    let t = theme::cur();
    let bg = t.bg_dark;
    let summary = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => match p.kind {
            AgentKind::TattleQwe => vec![
                ("Kind  ", "Tattle QWE run".to_string()),
                ("Ticket", p.tattle_ticket.clone()),
                ("Flow  ", "triage (default)".to_string()),
                ("Env   ", "prod (default)".to_string()),
                ("Prompt", p.prompt.clone()),
            ],
            AgentKind::ClaudeManaged => {
                let agent = if p.claude_agent_create_new {
                    format!("create new · {}", p.claude_agent_new_name)
                } else {
                    p.claude_agent_id.clone()
                };
                let sandbox = match p.claude_sandbox {
                    SandboxMode::CloudSandbox => "Anthropic cloud".to_string(),
                    SandboxMode::SelfHostedLocal => "self-hosted · LOCAL".to_string(),
                    SandboxMode::SelfHostedRemote => {
                        format!("self-hosted · REMOTE → {}", p.claude_remote.label())
                    }
                };
                vec![
                    ("Kind   ", "Claude managed agent".to_string()),
                    ("Agent  ", agent),
                    ("Sandbox", sandbox),
                    ("Prompt ", p.prompt.clone()),
                ]
            }
        },
        _ => return area.y,
    };
    let mut y = area.y;
    for (k, v) in summary {
        if y >= area.y + area.height {
            break;
        }
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("    ", Style::default().bg(bg)),
                Span::styled(format!("{k} "), Style::default().fg(t.comment).bg(bg)),
                Span::styled(
                    if v.is_empty() {
                        "—".to_string()
                    } else {
                        v.clone()
                    },
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
        y += 1;
    }
    y
}
