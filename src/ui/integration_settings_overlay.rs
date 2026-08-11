//! Per-integration Settings pane renderer — modal form of the
//! integration's `[[auth]]` fields. Companion to `first_launch_overlay`
//! (same visual family: centered bordered card, cyan accent, bg_dark
//! panel). Save writes back to the manifest TOML under `[auth_values]`.
//!
//! See `src/app/integration_settings.rs` for the state + save path.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

const INNER_W: u16 = 74;

pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    let Some(state) = app.integration_settings.as_ref() else {
        return;
    };
    if app.prompt.is_some() || app.picker.is_some() || app.context_menu.is_some() {
        return;
    }
    let t = theme::cur();
    let lines = render_lines(state, &t);
    let inner_w = INNER_W;
    let outer_w = inner_w + 2;
    let outer_h = (lines.len() as u16 + 2).min(screen.height.saturating_sub(2));
    let x = screen.x + screen.width.saturating_sub(outer_w) / 2;
    let y = screen.y + screen.height.saturating_sub(outer_h) / 2;
    let outer = Rect {
        x,
        y,
        width: outer_w,
        height: outer_h,
    };
    frame.render_widget(Clear, outer);
    let panel_bg = Style::default().bg(t.bg_dark);
    frame.render_widget(Paragraph::new("").style(panel_bg), outer);

    let title = format!(
        " Configure `{}` — Ctrl+S save, Esc close ",
        state.integration_id
    );
    let title_padded = center_title(&title, inner_w as usize);
    let border_top = format!("╭{}╮", title_padded);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            border_top,
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ))),
        Rect {
            x,
            y,
            width: outer_w,
            height: 1,
        },
    );

    for (i, line_body) in lines.iter().enumerate() {
        let row_y = y.saturating_add(1 + i as u16);
        if row_y >= y + outer_h.saturating_sub(1) {
            break;
        }
        let border_style = Style::default().fg(t.cyan).bg(t.bg_dark);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled("│", border_style))),
            Rect {
                x,
                y: row_y,
                width: 1,
                height: 1,
            },
        );
        frame.render_widget(
            Paragraph::new(line_body.clone()).style(panel_bg),
            Rect {
                x: x + 1,
                y: row_y,
                width: inner_w,
                height: 1,
            },
        );
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled("│", border_style))),
            Rect {
                x: x + outer_w - 1,
                y: row_y,
                width: 1,
                height: 1,
            },
        );
    }

    let border_bot = format!("╰{}╯", "─".repeat(inner_w as usize));
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            border_bot,
            Style::default().fg(t.cyan).bg(t.bg_dark),
        ))),
        Rect {
            x,
            y: y + outer_h - 1,
            width: outer_w,
            height: 1,
        },
    );
}

fn center_title(title: &str, width: usize) -> String {
    let title_w = title.chars().count();
    if title_w >= width {
        return "─".repeat(width);
    }
    let side = (width - title_w) / 2;
    let left = "─".repeat(side);
    let right = "─".repeat(width - side - title_w);
    format!("{left}{title}{right}")
}

fn render_lines<'a>(
    state: &crate::app::integration_settings::IntegrationSettingsState,
    t: &theme::Theme,
) -> Vec<Line<'a>> {
    let mut out: Vec<Line<'a>> = Vec::new();
    out.push(spacer(t));
    for (i, field) in state.schema.iter().enumerate() {
        let focused = i == state.focused;
        let value = state.values.get(i).cloned().unwrap_or_default();
        // If we're editing THIS field, show the live buffer instead
        // of the committed value + a trailing block cursor.
        let (display, is_editing) = if focused && let Some(buf) = state.editing.as_ref() {
            (buf.text.clone(), true)
        } else {
            (value, false)
        };
        // Label row.
        let arrow = if focused { "▸ " } else { "  " };
        let (label_fg, mod_) = if focused {
            (t.cyan, Modifier::BOLD)
        } else {
            (t.fg, Modifier::empty())
        };
        let req = if field.required { " *" } else { "" };
        let head = format!(" {}{}{}  ", arrow, field.label, req);
        out.push(Line::from(Span::styled(
            pad_to(&head, INNER_W as usize),
            Style::default()
                .fg(label_fg)
                .bg(t.bg_dark)
                .add_modifier(mod_),
        )));
        // Optional help row.
        if let Some(help) = field.help.as_ref() {
            out.push(body_line(help, t));
        }
        // Value row.
        let rendered = render_value(&display, &field.kind);
        let value_style = if is_editing {
            Style::default()
                .fg(t.green)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else if display.is_empty() {
            Style::default().fg(t.orange).bg(t.bg_dark)
        } else {
            Style::default().fg(t.fg).bg(t.bg_dark)
        };
        let cursor = if is_editing { "▏" } else { "" };
        let value_line = format!("     {}{}", rendered, cursor);
        out.push(Line::from(Span::styled(
            pad_to(&value_line, INNER_W as usize),
            value_style,
        )));
        // Optional help_url row.
        if let Some(help_url) = field.help_url.as_ref() {
            let help = format!("Get one: {}", help_url);
            out.push(body_line(&help, t));
        }
        // Env-fallback annotation row.
        if let Some(env_name) = field.env_fallback.as_ref() {
            let env_line = if std::env::var(env_name).is_ok() {
                format!("Env fallback: ${env_name} ✓ set")
            } else {
                format!("Env fallback: ${env_name} — not set")
            };
            out.push(body_line(&env_line, t));
        }
        out.push(spacer(t));
    }
    // Footer.
    let footer = "   [↑↓] move  · [Enter] edit  · [Ctrl+S] save  · [Esc] close";
    out.push(Line::from(Span::styled(
        pad_to(footer, INNER_W as usize),
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));
    out
}

fn render_value(value: &str, kind: &str) -> String {
    if value.is_empty() {
        return "(unset — Enter to configure)".to_string();
    }
    if kind == "secret" {
        // Mask entirely — showing even a prefix leaks
        // partial-token entropy that attackers can exploit.
        return "•".repeat(value.chars().count().min(40));
    }
    value.to_string()
}

fn body_line<'a>(text: &str, t: &theme::Theme) -> Line<'a> {
    let padded = pad_to(&format!("     {}", text), INNER_W as usize);
    Line::from(Span::styled(
        padded,
        Style::default().fg(t.comment).bg(t.bg_dark),
    ))
}

fn spacer<'a>(t: &theme::Theme) -> Line<'a> {
    Line::from(Span::styled(
        " ".repeat(INNER_W as usize),
        Style::default().bg(t.bg_dark),
    ))
}

fn pad_to(s: &str, width: usize) -> String {
    let w = s.chars().count();
    if w >= width {
        s.to_string()
    } else {
        format!("{}{}", s, " ".repeat(width - w))
    }
}
