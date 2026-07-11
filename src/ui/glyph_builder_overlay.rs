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
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::glyph_builder::{BuilderCategory, BuilderField};
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, parent: Rect) {
    if app.glyph_builder.is_none() {
        return;
    }
    let t = theme::cur();
    // Widened 2026-07-11 (was 62). macOS paths (`/Users/<name>/…/foo.svg`)
    // routinely blow past 60 chars; the previous width truncated with no
    // way to see the rest. 96 is a comfortable ceiling and still leaves
    // padding on a typical terminal window.
    let width = 96.min(parent.width.saturating_sub(4));
    let height = 22.min(parent.height.saturating_sub(4));
    let x = parent.x + (parent.width.saturating_sub(width)) / 2;
    // Centered vertically — matches integration_edit + settings +
    // help so overlay position is consistent across the app.
    let y = parent.y + parent.height.saturating_sub(height) / 2;
    let area = Rect {
        x,
        y,
        width,
        height,
    };
    frame.render_widget(Clear, area);
    // Modal-block rect — same click-guard idiom as
    // integration_edit_overlay. 2026-07-11.
    app.rects.glyph_builder_overlay_rect = Some(area);
    app.rects.glyph_builder_field_rows.clear();

    let block = crate::ui::design_tokens::modal_panel("+ Add custom glyph");
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
        app.rects.glyph_builder_field_rows.push((row_rect, *field));
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

    // No live preview — the terminal can't hot-reload the patched
    // font mid-session, so any "preview" would be either stale
    // (showing the last-baked version) or a lossy raster (the sixel
    // path we tried and users found visually misleading).
    //
    // Instead surface the character at the current codepoint on a
    // single line, styled as informational — user sees what the
    // terminal currently renders for this codepoint (whatever's in
    // the font today) without any "preview" framing that would
    // suggest live-updates.
    let _ = preview_rows;
    let baked_char = u32::from_str_radix(&state.codepoint_hex, 16)
        .ok()
        .and_then(char::from_u32);
    if let Some(ch) = baked_char {
        let info_rect = Rect {
            x: inner.x + 2,
            y: inner.y + form_rows + 1,
            width: inner.width.saturating_sub(4),
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("current glyph at U+", Style::default().fg(t.comment)),
                Span::styled(state.codepoint_hex.clone(), Style::default().fg(t.comment)),
                Span::styled(":  ", Style::default().fg(t.comment)),
                Span::styled(format!("{ch}  "), Style::default().fg(t.fg)),
                Span::styled(
                    "(restart terminal after bake to refresh)",
                    Style::default().fg(t.grey).add_modifier(Modifier::ITALIC),
                ),
            ])),
            info_rect,
        );
    }
    // Hint line at bottom of inner. Reflects the 2026-07-11 edit-
    // affordance polish: paste + cursor keys work on text fields;
    // ←→ cycles values on non-text fields.
    crate::ui::design_tokens::paint_hint_row(
        frame,
        inner,
        "Tab field · text: ←→ Home End Ctrl+V paste · other: ←→ cycle · ↵ bake · esc",
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
    let is_focused = state.focused_field == f;
    // Cursor rendering — inverted cell at the byte offset. Only paint
    // when focused AND the field is a text field (Path/Name/Codepoint).
    // Empty-value focused paints a single caret cell before the
    // placeholder. 2026-07-11.
    let text_field_caret = |value: &str, placeholder: &str| -> Vec<Span<'static>> {
        if !is_focused {
            if value.is_empty() {
                return vec![Span::styled(placeholder.to_string(), dim)];
            }
            return vec![Span::styled(value.to_string(), normal)];
        }
        let cur = state.active_text_cursor().unwrap_or(0).min(value.len());
        let caret_style = Style::default().fg(t.bg_dark).bg(t.fg);
        if value.is_empty() {
            return vec![
                Span::styled(" ".to_string(), caret_style),
                Span::styled(placeholder.to_string(), dim),
            ];
        }
        let (head, tail) = value.split_at(cur);
        // Split the tail into "caret char" + "rest" so the caret
        // occupies exactly one cell.
        let (caret_ch, rest) = match tail.chars().next() {
            Some(c) => {
                let rest = &tail[c.len_utf8()..];
                (c.to_string(), rest.to_string())
            }
            None => (" ".to_string(), String::new()),
        };
        vec![
            Span::styled(head.to_string(), normal),
            Span::styled(caret_ch, caret_style),
            Span::styled(rest, normal),
        ]
    };
    match f {
        BuilderField::Path => text_field_caret(&state.svg_path, "(SVG file path)"),
        BuilderField::Name => text_field_caret(&state.name, "(auto from filename)"),
        BuilderField::Codepoint => {
            let mut spans = vec![Span::styled("U+".to_string(), dim)];
            spans.extend(text_field_caret(&state.codepoint_hex, ""));
            spans
        }
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
