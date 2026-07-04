//! Glyph builder panel — SVG → font glyph with a live rasterized
//! preview. Opened by `integrations.glyph_builder`.
//!
//! Layout (centered floating overlay, ~62 cells × ~18 rows):
//!
//!   ┌─ + Add custom glyph ─────────────────────────────────────┐
//!   │  ▸ path       [/path/to/logo.svg           ]              │
//!   │    category   ← [aws] gcp azure ai saas dev →             │
//!   │    name       aws-amplify-inv                             │
//!   │    codepoint  F1B00                                        │
//!   │    width      1.25    ←→                                  │
//!   │    height     0.80    ←→                                  │
//!   │    center     0.36    ←→                                  │
//!   │                                                            │
//!   │  ┌── preview ──────┐                                       │
//!   │  │                 │                                       │
//!   │  │     [sixel]     │                                       │
//!   │  │                 │                                       │
//!   │  └─────────────────┘                                       │
//!   │  Tab field · ←→ cycle value · ↵ bake · esc cancel          │
//!   └────────────────────────────────────────────────────────────┘
//!
//! Preview refresh: on every render tick the panel checks the current
//! state signature and calls `glyph_builder::maybe_refresh_preview` if
//! anything path/width/height/center changed. Rasterization runs at
//! ~10ms per frame, well under a keystroke debounce.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::glyph_builder::{BuilderCategory, BuilderField};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, parent: Rect) {
    if app.glyph_builder.is_none() {
        return;
    }
    let t = theme::cur();
    let width = 62.min(parent.width.saturating_sub(4));
    let height = 22.min(parent.height.saturating_sub(4));
    let x = parent.x + (parent.width.saturating_sub(width)) / 2;
    let y = parent.y + (parent.height.saturating_sub(height)) / 3;
    let area = Rect {
        x,
        y,
        width,
        height,
    };
    frame.render_widget(Clear, area);

    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            " + Add custom glyph ",
            Style::default()
                .fg(t.bg_dark)
                .bg(t.cyan)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg_dark));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Pull the panel state out for reading; refresh preview first so
    // the sixel emit path sees fresh bytes.
    let preview_w = ((inner.width as u32) * 8).min(256);
    let preview_h = 96u32; // ~6 cells at 16 px/cell
    if let Some(state) = app.glyph_builder.as_mut() {
        crate::glyph_builder::maybe_refresh_preview(state, preview_w, preview_h);
    }
    let state = match app.glyph_builder.as_ref() {
        Some(s) => s.clone(),
        None => return,
    };

    // Split inner rect into form rows and preview area.
    let form_rows = 7;
    let hint_rows = 1;
    let preview_rows = inner.height.saturating_sub(form_rows + hint_rows + 1);

    for (i, field) in [
        BuilderField::Path,
        BuilderField::Category,
        BuilderField::Name,
        BuilderField::Codepoint,
        BuilderField::WidthFrac,
        BuilderField::HeightFrac,
        BuilderField::CenterFrac,
    ]
    .iter()
    .enumerate()
    {
        let row_y = inner.y + i as u16;
        if row_y >= inner.y + inner.height {
            break;
        }
        let row_rect = Rect {
            x: inner.x,
            y: row_y,
            width: inner.width,
            height: 1,
        };
        let is_focused = state.focused_field == *field;
        let prefix = if is_focused { "▸ " } else { "  " };
        let label = field_label(*field);
        let value_line = value_span(*field, &state);
        let label_style = if is_focused {
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment)
        };
        let mut spans: Vec<Span<'static>> = Vec::new();
        spans.push(Span::styled(prefix, Style::default().fg(t.cyan)));
        spans.push(Span::styled(format!("{label:<11}"), label_style));
        spans.extend(value_line);
        if is_focused && is_cycled_field(*field) {
            spans.push(Span::styled("  ←→", Style::default().fg(t.comment)));
        }
        frame.render_widget(Paragraph::new(Line::from(spans)), row_rect);
    }

    // Preview area — draw a border, then have dispatch::emit_image_placements
    // paint the sixel bytes at this cell.
    let preview_top = inner.y + form_rows + 1;
    if preview_rows >= 3 {
        let preview_rect = Rect {
            x: inner.x + 2,
            y: preview_top,
            width: 20.min(inner.width.saturating_sub(4)),
            height: preview_rows,
        };
        let box_block = Block::default()
            .borders(Borders::ALL)
            .title(Span::styled(" preview ", Style::default().fg(t.comment)))
            .style(Style::default().fg(t.comment).bg(t.bg_dark));
        frame.render_widget(box_block, preview_rect);
        if let Some(err) = &state.error {
            let err_rect = Rect {
                x: preview_rect.x + 1,
                y: preview_rect.y + 1,
                width: preview_rect.width.saturating_sub(2),
                height: preview_rect.height.saturating_sub(2),
            };
            frame.render_widget(
                Paragraph::new(Span::styled(
                    err.clone(),
                    Style::default().fg(t.red).add_modifier(Modifier::ITALIC),
                )),
                err_rect,
            );
        } else if let Some(png) = state.preview_png.clone() {
            let inner_rect = Rect {
                x: preview_rect.x + 1,
                y: preview_rect.y + 1,
                width: preview_rect.width.saturating_sub(2),
                height: preview_rect.height.saturating_sub(2),
            };
            app.rects.glyph_builder_preview = Some(inner_rect);
            // Queue the sixel/kitty paint request. The dispatch loop
            // drains this at frame end and writes the escape to
            // stdout at `inner_rect`'s cursor position. pane_id 0
            // is synthetic — the emitter doesn't look it up.
            app.image_paint_requests.push(crate::image::PaintRequest {
                pane_id: 0,
                area: inner_rect,
                png_bytes: std::sync::Arc::new(png),
            });
        }
    }

    // Hint line at bottom of inner.
    let hint_y = inner.y + inner.height.saturating_sub(1);
    let hint_rect = Rect {
        x: inner.x,
        y: hint_y,
        width: inner.width,
        height: 1,
    };
    let hint = "Tab field · ←→ cycle value · ↵ bake · esc cancel";
    let pad = inner.width.saturating_sub(hint.chars().count() as u16) / 2;
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            format!("{}{hint}", " ".repeat(pad as usize)),
            Style::default().fg(t.comment),
        ))),
        hint_rect,
    );
}

fn field_label(f: BuilderField) -> &'static str {
    match f {
        BuilderField::Path => "path",
        BuilderField::Category => "category",
        BuilderField::Name => "name",
        BuilderField::Codepoint => "codepoint",
        BuilderField::WidthFrac => "width",
        BuilderField::HeightFrac => "height",
        BuilderField::CenterFrac => "center",
    }
}

fn is_cycled_field(f: BuilderField) -> bool {
    matches!(
        f,
        BuilderField::Category
            | BuilderField::WidthFrac
            | BuilderField::HeightFrac
            | BuilderField::CenterFrac
    )
}

fn value_span(
    f: BuilderField,
    state: &crate::glyph_builder::GlyphBuilderState,
) -> Vec<Span<'static>> {
    let t = theme::cur();
    let normal = Style::default().fg(t.fg);
    let dim = Style::default().fg(t.comment);
    match f {
        BuilderField::Path => {
            let v = state.svg_path.clone();
            if v.is_empty() {
                vec![Span::styled("(SVG file path)".to_string(), dim)]
            } else {
                vec![Span::styled(v, normal)]
            }
        }
        BuilderField::Name => {
            let v = state.name.clone();
            if v.is_empty() {
                vec![Span::styled("(auto from filename)".to_string(), dim)]
            } else {
                vec![Span::styled(v, normal)]
            }
        }
        BuilderField::Codepoint => vec![
            Span::styled("U+".to_string(), dim),
            Span::styled(state.codepoint_hex.clone(), normal),
        ],
        BuilderField::Category => {
            let mut out: Vec<Span<'static>> = Vec::new();
            for c in BuilderCategory::ALL {
                let is_active = *c == state.category;
                let style = if is_active {
                    Style::default().fg(t.cyan).add_modifier(Modifier::BOLD)
                } else {
                    dim
                };
                let s = if is_active {
                    format!("[{}]", c.label())
                } else {
                    format!(" {} ", c.label())
                };
                out.push(Span::styled(s, style));
            }
            out
        }
        BuilderField::WidthFrac => {
            vec![Span::styled(format!("{:.2}", state.width_frac), normal)]
        }
        BuilderField::HeightFrac => {
            vec![Span::styled(format!("{:.2}", state.height_frac), normal)]
        }
        BuilderField::CenterFrac => {
            vec![Span::styled(format!("{:.2}", state.center_frac), normal)]
        }
    }
}
