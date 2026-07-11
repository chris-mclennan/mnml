//! Integration-edit panel — opens from the chip right-click context
//! menu (Edit… / Add custom…). Reads from [`App::integration_edit`].
//!
//! Family-Settings-style row layout: `▸ <label>: <value>` per row,
//! Tab cycles focus, ←→ cycles the color value, typing edits text
//! fields, Enter saves, Esc cancels.
//!
//! Freestanding centered overlay — the browse-list overlay it used
//! to nest inside was removed 2026-07-03.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::app::discovery::{IntegrationEditField, IntegrationEditMode, IntegrationEditState};
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
    // Centered vertically — matches settings, help, and other panel
    // overlays so the workspace-level "modals appear here" convention
    // stays consistent across the app.
    let y = parent.y + parent.height.saturating_sub(height) / 2;
    Rect {
        x,
        y,
        width,
        height,
    }
}

/// Paint the edit panel. No-op when `App::integration_edit` is `None`.
///
/// Also skipped while the Glyph action picker is up — that chooser is
/// conceptually a submenu of the edit panel's Glyph field, so showing
/// both stacked reads as visual clutter. The edit panel reappears
/// automatically when the picker closes (Esc or accept).
pub fn draw(frame: &mut Frame, app: &mut App, parent: Rect) {
    let Some(panel) = app.integration_edit.as_ref().cloned() else {
        return;
    };
    if matches!(
        app.picker.as_ref().map(|p| p.kind),
        Some(crate::picker::PickerKind::GlyphAction)
    ) {
        return;
    }
    let rect = edit_rect(parent, &panel.mode);
    let t = theme::cur();
    frame.render_widget(Clear, rect);
    let title = match panel.mode {
        IntegrationEditMode::Edit => format!(" edit · {} ", panel.id),
        IntegrationEditMode::AddCustom => " + add custom integration ".to_string(),
    };
    let block = crate::ui::design_tokens::modal_panel(&title);
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
            && matches!(
                field,
                IntegrationEditField::Id | IntegrationEditField::Command
            );
        let mut spans: Vec<Span<'static>> = Vec::new();
        spans.push(Span::styled(prefix, Style::default().fg(t.cyan)));
        spans.push(Span::styled(format!("{label:<12}"), label_style));
        // Value with in-place caret when the field is focused, editable,
        // and text-y (2026-07-11 — was a trailing "▏" appended after
        // the value, which lied about caret position after mid-string
        // Left/Right motions). Placeholder-value case still gets a
        // caret cell before the placeholder.
        let text_field = matches!(
            field,
            IntegrationEditField::Id
                | IntegrationEditField::Command
                | IntegrationEditField::Fallback
                | IntegrationEditField::Tooltip
        );
        if is_focused && text_field && !readonly {
            let caret_style = Style::default().fg(t.bg_dark).bg(t.cyan);
            let raw = match field {
                IntegrationEditField::Id => &panel.id,
                IntegrationEditField::Command => &panel.command,
                IntegrationEditField::Fallback => &panel.fallback,
                IntegrationEditField::Tooltip => &panel.tooltip,
                _ => "",
            };
            let cursor = match field {
                IntegrationEditField::Id => panel.id_cursor,
                IntegrationEditField::Command => panel.command_cursor,
                IntegrationEditField::Fallback => panel.fallback_cursor,
                IntegrationEditField::Tooltip => panel.tooltip_cursor,
                _ => 0,
            }
            .min(raw.len());
            if raw.is_empty() {
                // Placeholder path — put a caret cell then dim
                // "(empty)".
                spans.push(Span::styled(" ".to_string(), caret_style));
                spans.push(Span::styled(
                    "(empty)".to_string(),
                    Style::default().fg(t.comment),
                ));
            } else {
                let (head, tail) = raw.split_at(cursor);
                let (caret_ch, rest) = match tail.chars().next() {
                    Some(c) => {
                        let rest = &tail[c.len_utf8()..];
                        (c.to_string(), rest.to_string())
                    }
                    None => (" ".to_string(), String::new()),
                };
                spans.push(Span::styled(head.to_string(), value_style));
                spans.push(Span::styled(caret_ch, caret_style));
                spans.push(Span::styled(rest, value_style));
            }
        } else {
            spans.push(Span::styled(value_text, value_style));
        }
        if is_focused && matches!(field, IntegrationEditField::Color) {
            spans.push(Span::styled(
                "  ←→ cycle".to_string(),
                Style::default().fg(t.comment),
            ));
        } else if is_focused && matches!(field, IntegrationEditField::Glyph) {
            spans.push(Span::styled(
                "  ↵ actions".to_string(),
                Style::default().fg(t.cyan).add_modifier(Modifier::BOLD),
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
    crate::ui::design_tokens::paint_hint_row(
        frame,
        inner,
        "Tab · text: ←→ Home End Ctrl+V · Color: ←→ cycle · ↵ save · esc",
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

fn field_value(panel: &IntegrationEditState, field: IntegrationEditField) -> (String, Style) {
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
    // S2-2 — special-case "dim" (not a slot name) before delegating.
    let fg = if name == "dim" {
        t.comment
    } else {
        theme::color_from_slot(name, &t)
    };
    Style::default().fg(fg).add_modifier(Modifier::BOLD)
}
