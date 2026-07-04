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
    // Same fixed top-anchor as integration_edit_overlay so switching
    // between the two panels doesn't cause a vertical jump.
    let y = parent.y + parent.height / 6;
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

    // Preview pixel target — the rasterizer chooses the pixmap
    // dimensions from these while preserving the em-box aspect
    // (3:5). We aim for ~160 px tall so the sixel encoder has enough
    // resolution to render a crisp glyph inside the preview box.
    let preview_target_w = 96u32;
    let preview_target_h = 160u32;
    if let Some(state) = app.glyph_builder.as_mut() {
        crate::glyph_builder::maybe_refresh_preview(state, preview_target_w, preview_target_h);
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

    // Text-based "actual glyph" preview — the terminal renders the
    // character at the current codepoint using its loaded font, which
    // is the same MnmlSymbols.ttf mnml just baked to. Simpler, faster,
    // and more accurate than sixel-rasterizing the SVG separately;
    // caveat is that during pre-bake tuning, the char shows the LAST
    // baked version, not the currently-tuned parameters. Note printed
    // below reminds the user to bake if width/height/center changed.
    let preview_top = inner.y + form_rows + 1;
    let baked_char = u32::from_str_radix(&state.codepoint_hex, 16)
        .ok()
        .and_then(char::from_u32);
    if preview_rows >= 3
        && let Some(ch) = baked_char
    {
        let label_rect = Rect {
            x: inner.x + 2,
            y: preview_top,
            width: inner.width.saturating_sub(4),
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "preview (actual font glyph)",
                Style::default()
                    .fg(t.comment)
                    .add_modifier(Modifier::ITALIC),
            ))),
            label_rect,
        );

        // Row 1 — as it would appear in a bufferline tab.
        let tab_rect = Rect {
            x: inner.x + 4,
            y: preview_top + 2,
            width: inner.width.saturating_sub(6),
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("tab:  ", Style::default().fg(t.comment)),
                Span::styled(format!(" {ch}  "), Style::default().fg(t.orange)),
                Span::styled(state.name.clone(), Style::default().fg(t.fg)),
                Span::styled(" × ", Style::default().fg(t.grey)),
            ])),
            tab_rect,
        );

        // Row 2 — rail chip style.
        let chip_rect = Rect {
            x: inner.x + 4,
            y: preview_top + 3,
            width: inner.width.saturating_sub(6),
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("chip: ", Style::default().fg(t.comment)),
                Span::styled(format!("{ch} "), Style::default().fg(t.purple)),
                Span::styled(state.name.clone(), Style::default().fg(t.fg)),
            ])),
            chip_rect,
        );

        // Row 3 — bare char, several times so scale is visible.
        let bare_rect = Rect {
            x: inner.x + 4,
            y: preview_top + 4,
            width: inner.width.saturating_sub(6),
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("bare: ", Style::default().fg(t.comment)),
                Span::styled(
                    format!("{ch}  {ch}  {ch}  U+{:04X}", ch as u32),
                    Style::default().fg(t.fg),
                ),
            ])),
            bare_rect,
        );

        // Reminder row: shown when the currently-tuned params differ
        // from what's baked into the font (i.e. the user has been
        // tuning but hasn't re-baked yet).
        let stale = crate::glyph_builder::load_meta()
            .glyphs
            .iter()
            .find(|g| g.codepoint == state.codepoint_hex)
            .map(|g| {
                (g.width_frac - state.width_frac).abs() > 0.001
                    || (g.height_frac - state.height_frac).abs() > 0.001
                    || (g.center_frac - state.center_frac).abs() > 0.001
                    || g.svg != state.svg_path
            })
            .unwrap_or(true);
        if stale && preview_rows >= 6 {
            let note_rect = Rect {
                x: inner.x + 4,
                y: preview_top + 6,
                width: inner.width.saturating_sub(6),
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    "↵ bake to update — glyph above reflects last-baked version",
                    Style::default().fg(t.yellow).add_modifier(Modifier::ITALIC),
                ))),
                note_rect,
            );
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
