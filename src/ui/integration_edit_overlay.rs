//! Integration-edit panel — overlays the discovery overlay when the
//! user presses `e` on a rail integration row (Edit mode) or selects
//! the `[+ Add custom integration]` row (AddCustom mode).
//!
//! Family-Settings-style row layout: `▸ <label>: <value>` per row,
//! Tab cycles focus, ←→ cycles the color value, typing edits text
//! fields, Enter saves, Esc cancels.
//!
//! Painted on top of the discovery overlay's box (not freestanding)
//! so the user keeps the discovery context visible at the edges.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::app::discovery::{
    INTEGRATION_EDIT_COLORS, IntegrationEditField, IntegrationEditMode, IntegrationEditState,
};
use crate::ui::theme;

/// Inner sub-rect of the discovery overlay's panel that the edit
/// panel occupies. Centered horizontally on `parent`; vertical
/// position floats with row count.
fn edit_rect(parent: Rect, mode: &IntegrationEditMode) -> Rect {
    let row_count = match mode {
        // 6 field rows + 2 spacer/hint rows + 2 border rows = 10.
        IntegrationEditMode::AddCustom => 10,
        // 4 field rows + 2 spacer/hint rows + 2 border rows = 8.
        IntegrationEditMode::Edit => 8,
    };
    let width = 60.min(parent.width.saturating_sub(4));
    let height = (row_count as u16).min(parent.height.saturating_sub(4));
    let x = parent.x + (parent.width.saturating_sub(width)) / 2;
    let y = parent.y + (parent.height.saturating_sub(height)) / 2;
    Rect {
        x,
        y,
        width,
        height,
    }
}

/// Paint the edit panel. No-op when the discovery overlay isn't open
/// or its `edit_panel` slot is empty. Caller (`ui::mod.rs::draw`)
/// runs this after the discovery overlay so the box stacks on top.
pub fn draw(frame: &mut Frame, app: &mut App, parent: Rect) {
    let Some(state) = app.discovery_overlay.as_ref() else {
        return;
    };
    let Some(panel) = state.edit_panel.as_ref().cloned() else {
        return;
    };
    let rect = edit_rect(parent, &panel.mode);
    let t = theme::cur();
    frame.render_widget(Clear, rect);
    let title = match panel.mode {
        IntegrationEditMode::Edit => format!(" edit · {} ", panel.id),
        IntegrationEditMode::AddCustom => " + add custom integration ".to_string(),
    };
    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_dark)
                .bg(t.cyan)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg_dark));
    let inner = block.inner(rect);
    frame.render_widget(block, rect);

    // Field rows.
    let rows = visible_fields(&panel);
    for (i, field) in rows.iter().enumerate() {
        let y = inner.y + i as u16;
        if y >= inner.y + inner.height {
            break;
        }
        let row_rect = Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        };
        let is_focused = panel.focused_field == *field;
        let prefix = if is_focused { "▸ " } else { "  " };
        let label = field_label(*field);
        let (value_text, value_style) = field_value(&panel, *field);
        let label_style = if is_focused {
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment)
        };
        // Read-only annotation for `Id` / `Command` in Edit mode —
        // those can't be changed once the integration exists; the
        // panel renders them dim with a `[fixed]` tail so the user
        // knows.
        let readonly = matches!(panel.mode, IntegrationEditMode::Edit)
            && matches!(field, IntegrationEditField::Id | IntegrationEditField::Command);
        let mut spans: Vec<Span<'static>> = Vec::new();
        spans.push(Span::styled(prefix, Style::default().fg(t.cyan)));
        spans.push(Span::styled(format!("{label:<12}"), label_style));
        spans.push(Span::styled(value_text, value_style));
        if is_focused && matches!(field, IntegrationEditField::Color) {
            spans.push(Span::styled(
                "  ←→ cycle".to_string(),
                Style::default().fg(t.comment),
            ));
        } else if is_focused && matches!(field, IntegrationEditField::Glyph) {
            spans.push(Span::styled(
                "  (one char or codepoint)".to_string(),
                Style::default().fg(t.comment),
            ));
        } else if is_focused && !readonly {
            // Caret on the focused text field — a thin block at end.
            spans.push(Span::styled(
                "▏".to_string(),
                Style::default().fg(t.cyan),
            ));
        }
        if readonly {
            spans.push(Span::styled(
                "  [fixed]".to_string(),
                Style::default().fg(t.comment),
            ));
        }
        frame.render_widget(Paragraph::new(Line::from(spans)), row_rect);
    }

    // Hint row at the bottom.
    let hint_y = inner.y + inner.height.saturating_sub(1);
    let hint_rect = Rect {
        x: inner.x,
        y: hint_y,
        width: inner.width,
        height: 1,
    };
    let hint = "Tab field · ←→ cycle color · ↵ save · esc cancel";
    let pad = inner.width.saturating_sub(hint.chars().count() as u16) / 2;
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            format!("{}{hint}", " ".repeat(pad as usize)),
            Style::default().fg(t.comment),
        ))),
        hint_rect,
    );
}

fn visible_fields(panel: &IntegrationEditState) -> Vec<IntegrationEditField> {
    match panel.mode {
        IntegrationEditMode::Edit => vec![
            IntegrationEditField::Id,
            IntegrationEditField::Command,
            IntegrationEditField::Glyph,
            IntegrationEditField::Fallback,
            IntegrationEditField::Color,
            IntegrationEditField::Tooltip,
        ],
        IntegrationEditMode::AddCustom => vec![
            IntegrationEditField::Id,
            IntegrationEditField::Command,
            IntegrationEditField::Glyph,
            IntegrationEditField::Fallback,
            IntegrationEditField::Color,
            IntegrationEditField::Tooltip,
        ],
    }
}

fn field_label(field: IntegrationEditField) -> &'static str {
    match field {
        IntegrationEditField::Id => "id",
        IntegrationEditField::Command => "command",
        IntegrationEditField::Glyph => "glyph",
        IntegrationEditField::Fallback => "fallback",
        IntegrationEditField::Color => "color",
        IntegrationEditField::Tooltip => "tooltip",
    }
}

fn field_value(
    panel: &IntegrationEditState,
    field: IntegrationEditField,
) -> (String, Style) {
    let t = theme::cur();
    let dim = Style::default().fg(t.comment);
    let normal = Style::default().fg(t.fg);
    let (raw, default_style) = match field {
        IntegrationEditField::Id => (panel.id.clone(), normal),
        IntegrationEditField::Command => (panel.command.clone(), normal),
        IntegrationEditField::Glyph => (panel.glyph.clone(), normal),
        IntegrationEditField::Fallback => (panel.fallback.clone(), dim),
        IntegrationEditField::Color => (panel.color.clone(), color_style(&panel.color)),
        IntegrationEditField::Tooltip => (panel.tooltip.clone(), dim),
    };
    if raw.is_empty() && !matches!(field, IntegrationEditField::Color) {
        ("(empty)".to_string(), dim)
    } else {
        (raw, default_style)
    }
}

fn color_style(name: &str) -> Style {
    let t = theme::cur();
    let fg = match name {
        "red" => t.red,
        "orange" => t.orange,
        "yellow" => t.yellow,
        "green" => t.green,
        "cyan" => t.cyan,
        "blue" => t.blue,
        "purple" => t.purple,
        "magenta" => t.purple,
        "dim" => t.comment,
        _ => t.fg,
    };
    Style::default().fg(fg).add_modifier(Modifier::BOLD)
}

/// Exposed for tests + the click router (none yet).
#[allow(dead_code)]
pub fn _silence_unused() {
    let _ = INTEGRATION_EDIT_COLORS;
}
