//! Renderer for `Pane::NewCloudAgentWizard` (v2 — Claude Agent SDK).
//! Stacked-form layout:
//!   • Header (step indicator + breadcrumb)
//!   • Step content (radio list / checkbox PR list / text input)
//!   • Footer (Back / Next / Submit + hint or last_message)

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::new_cloud_agent_wizard::{Action, Source, WizardStep};
use crate::pane::Pane;
use crate::ui::theme;

/// Click-rect kinds inside the wizard.
#[derive(Debug, Clone)]
pub enum WizardHit {
    /// Pick a radio option / toggle a checkbox row. Payload is the
    /// row index — handler interprets per-step.
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
    app.rects.new_cloud_agent_wizard_hits.clear();

    let (step, last_message) = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => (p.step, p.last_message.clone()),
        _ => return,
    };

    let mut y = area.y;

    if y < area.y + area.height {
        let title = format!(
            "  + New Agent from PR (Claude Agent SDK)   ·   {}",
            step_label(step)
        );
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
                format!("  {}", breadcrumbs(step)),
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
        WizardStep::Source => draw_step_source(frame, app, body, pane_id),
        WizardStep::PrList => draw_step_pr_list(frame, app, body, pane_id),
        WizardStep::Action => draw_step_action(frame, app, body, pane_id),
        WizardStep::CustomPrompt => draw_step_custom_prompt(frame, app, body, pane_id),
        WizardStep::Review => draw_step_review(frame, app, body, pane_id),
    }

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
    let back_style = if matches!(step, WizardStep::Source) {
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

    let default_hint = match step {
        WizardStep::PrList => "  ↑↓/jk move · Space toggle · a all/none · Enter next · Esc close",
        WizardStep::CustomPrompt => "  Type your prompt · Enter advances · Esc close",
        _ => "  ↑↓/jk select · Enter advance · Esc close",
    };
    let hint = if let Some(msg) = last_message.as_ref() {
        format!("  {msg}")
    } else {
        default_hint.to_string()
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
        WizardStep::Source => "Step 1 · Source",
        WizardStep::PrList => "Step 2 · Pick PRs",
        WizardStep::Action => "Step 3 · Action",
        WizardStep::CustomPrompt => "Step · Prompt",
        WizardStep::Review => "Step · Review & submit",
    }
}

fn breadcrumbs(s: WizardStep) -> String {
    match s {
        WizardStep::Source => "Source".to_string(),
        WizardStep::PrList => "Source › PRs".to_string(),
        WizardStep::Action => "Source › PRs › Action".to_string(),
        WizardStep::CustomPrompt => "… › Prompt".to_string(),
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

fn draw_step_source(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let source = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.source,
        _ => return,
    };
    let rows: Vec<(&'static str, &'static str, bool)> = Source::all()
        .iter()
        .map(|s| (s.label(), s.hint(), *s == source))
        .collect();
    draw_radio_list(frame, app, area, pane_id, &rows);
}

fn draw_step_pr_list(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let t = theme::cur();
    let bg = t.bg_dark;
    let (rows, loading, err, focus, total_selected) = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => (
            p.pr_rows.clone(),
            p.pr_loading,
            p.pr_err.clone(),
            p.focus_row,
            p.selected_count(),
        ),
        _ => return,
    };
    let mut y = area.y;
    if loading && y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  Fetching open PRs…",
                Style::default().fg(t.comment).bg(bg),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        return;
    }
    if let Some(e) = err.as_ref() {
        if y < area.y + area.height {
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    format!("  ✗ {e}"),
                    Style::default().fg(t.red).bg(bg),
                ))),
                Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                },
            );
        }
        return;
    }
    if rows.is_empty() && y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  No open PRs found.",
                Style::default().fg(t.comment).bg(bg),
            ))),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        return;
    }
    // Counter at top.
    if y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!(
                    "  {} of {} selected  ·  Space to toggle  ·  a = all/none",
                    total_selected,
                    rows.len()
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
    for (i, r) in rows.iter().enumerate() {
        if y >= area.y + area.height {
            break;
        }
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        let chk = if r.selected { "[x]" } else { "[ ]" };
        let chk_style = if r.selected {
            Style::default().fg(t.green).bg(bg)
        } else {
            Style::default().fg(t.comment).bg(bg)
        };
        let cursor = if i == focus { "▸" } else { " " };
        let row_style = if i == focus {
            Style::default()
                .fg(t.fg)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(bg)
        };
        let title: String = r.title.chars().take(60).collect();
        let line = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(format!("{cursor} "), Style::default().fg(t.cyan).bg(bg)),
            Span::styled(format!("{chk}  "), chk_style),
            Span::styled(
                format!("#{}", r.number),
                Style::default()
                    .fg(t.yellow)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(title, row_style),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                format!("by {}", r.author),
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
        y += 1;
    }
}

fn draw_step_action(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let action = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.action,
        _ => return,
    };
    let rows: Vec<(&'static str, &'static str, bool)> = Action::all()
        .iter()
        .map(|a| (a.label(), a.hint(), *a == action))
        .collect();
    draw_radio_list(frame, app, area, pane_id, &rows);
}

fn draw_step_custom_prompt(frame: &mut Frame, app: &mut App, area: Rect, pane_id: PaneId) {
    let t = theme::cur();
    let bg = t.bg_dark;
    let prompt = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p.custom_prompt.clone(),
        _ => return,
    };
    let mut y = area.y;
    if y < area.y + area.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  Type a prompt — the agent receives this verbatim plus the PR context.",
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
    let p = match app.panes.get(pane_id) {
        Some(Pane::NewCloudAgentWizard(p)) => p,
        _ => return,
    };
    let summary: Vec<(&str, String)> = match p.source {
        Source::ManualPrompt => vec![
            ("Source ", "Manual prompt (no PR list)".to_string()),
            ("Action ", p.action.label().to_string()),
            (
                "Prompt ",
                if matches!(p.action, Action::Custom) {
                    p.custom_prompt.clone()
                } else {
                    p.action.prompt_template().to_string()
                },
            ),
        ],
        _ => {
            let picks: Vec<String> = p
                .pr_rows
                .iter()
                .filter(|r| r.selected)
                .map(|r| format!("#{} {}", r.number, r.title))
                .collect();
            vec![
                ("Source ", p.source.label().to_string()),
                ("PRs    ", format!("{} selected", picks.len())),
                ("Detail ", picks.join(" · ")),
                ("Action ", p.action.label().to_string()),
                (
                    "Prompt ",
                    if matches!(p.action, Action::Custom) {
                        p.custom_prompt.clone()
                    } else {
                        p.action.prompt_template().to_string()
                    },
                ),
            ]
        }
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
