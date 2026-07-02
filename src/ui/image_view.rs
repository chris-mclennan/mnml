//! `Pane::Image` renderer. Reserves the pane area with a dim placeholder
//! background; `tui.rs` emits the terminal-specific image escape after
//! `terminal.draw()` so the image paints on top of the reserved cells.
//!
//! When the terminal doesn't support an image protocol, the body shows
//! the file's metadata + a one-line hint ("preview requires Kitty /
//! iTerm2 protocol") so the user knows what they'd be seeing.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::image::ImageProtocol;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    _focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    let t = theme::cur();
    let protocol = app.image_protocol;
    app.rects.editor_panes.push((area, pane_id));

    let Some(Pane::Image(p)) = app.panes.get(pane_id) else {
        return None;
    };
    // Paint the pane background first (so the image overlay has a clean
    // canvas; ratatui re-draws will erase whatever stomped over it on the
    // previous frame).
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );

    // Optional header row with file metadata.
    let header_h: u16 = if p.show_header { 2 } else { 0 };
    let header_area = Rect::new(area.x, area.y, area.width, header_h.min(area.height));
    let body_area = Rect::new(
        area.x,
        area.y + header_h.min(area.height),
        area.width,
        area.height.saturating_sub(header_h),
    );

    if header_h > 0 {
        let size_kb = (p.data.bytes.len() as f64) / 1024.0;
        let size_label = if size_kb >= 1024.0 {
            format!("{:.1} MB", size_kb / 1024.0)
        } else {
            format!("{size_kb:.0} KB")
        };
        let proto_label = match protocol {
            ImageProtocol::Kitty => "kitty protocol",
            ImageProtocol::Iterm2 => "iterm2 inline",
            ImageProtocol::Sixel => "sixel",
            ImageProtocol::None => "no inline protocol — metadata only",
        };
        let rel = p
            .data
            .path
            .strip_prefix(&app.workspace)
            .unwrap_or(&p.data.path)
            .display()
            .to_string();
        let header = Paragraph::new(vec![
            Line::from(vec![
                Span::styled(
                    rel,
                    Style::default()
                        .fg(t.fg)
                        .bg(t.bg_darker)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!("  · {size_label}  ·  {proto_label}"),
                    Style::default().fg(t.comment).bg(t.bg_darker),
                ),
            ]),
            Line::from(Span::styled(
                "  i header · r reload · Esc tree",
                Style::default().fg(t.comment).bg(t.bg_darker),
            )),
        ])
        .style(Style::default().bg(t.bg_darker));
        frame.render_widget(header, header_area);
    }

    // Body: paint a subtle placeholder grid so the user can see the
    // reserved area even before the image escape arrives. The image
    // overlay paints over this on the next stdout flush.
    if body_area.width > 0 && body_area.height > 0 {
        match protocol {
            ImageProtocol::None => {
                // No protocol: explain what's missing rather than leaving
                // an empty rectangle.
                let dim = Style::default().fg(t.comment).bg(t.bg_dark);
                let lines: Vec<Line> = vec![
                    Line::from(""),
                    Line::from(Span::styled(
                        "  Image preview requires Kitty, iTerm2, or sixel inline-image protocol.",
                        dim,
                    )),
                    Line::from(""),
                    Line::from(Span::styled(
                        "  Supported terminals: Kitty, WezTerm, Ghostty, iTerm2, Konsole, foot, mlterm.",
                        dim,
                    )),
                    Line::from(Span::styled(
                        "  Override detection with MNML_IMAGE_PROTOCOL=kitty|iterm2|sixel.",
                        dim,
                    )),
                ];
                frame.render_widget(
                    Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
                    body_area,
                );
            }
            _ => {
                // Light placeholder dots — the image overlay will paint on
                // top of these next frame.
                let placeholder: Vec<Line> = (0..body_area.height)
                    .map(|_| {
                        Line::from(Span::styled(
                            " ".repeat(body_area.width as usize),
                            Style::default().bg(t.bg_dark),
                        ))
                    })
                    .collect();
                frame.render_widget(
                    Paragraph::new(placeholder).style(Style::default().bg(t.bg_dark)),
                    body_area,
                );
                // Stage a paint request for tui.rs to act on after draw.
                // Compute the PNG bytes first (decoding non-PNG sources
                // on first access) so the emitter can stay agnostic.
                if let Some(Pane::Image(p)) = app.panes.get_mut(pane_id)
                    && let Ok(png_bytes) = p.data.ensure_png_bytes()
                {
                    // qa-feature 2026-07-02 — shrink the paint rect to
                    // preserve aspect ratio inside body_area (Kitty
                    // stretches to fill the given cols×rows otherwise).
                    // Terminal cells are ~2:1 (h:w) — approximated
                    // here; fine adjustments are barely perceptible.
                    let fit_area = if let Some((iw, ih)) = p.data.pixel_size {
                        fit_area_aspect(body_area, iw, ih)
                    } else {
                        body_area
                    };
                    app.image_paint_requests.push(crate::image::PaintRequest {
                        pane_id,
                        area: fit_area,
                        png_bytes,
                    });
                }
            }
        }
    }

    None
}

/// qa-feature 2026-07-02 — compute the largest sub-rect of `body`
/// that preserves the image's pixel aspect ratio. Terminal cells
/// are approximated as 2:1 (height:width in pixels); the image
/// centers inside `body`.
fn fit_area_aspect(body: Rect, img_w_px: u32, img_h_px: u32) -> Rect {
    if body.width == 0 || body.height == 0 || img_w_px == 0 || img_h_px == 0 {
        return body;
    }
    // Cell aspect ratio (cell_h_px / cell_w_px). Ghostty on macOS with
    // SF Mono at typical sizes runs closer to 2.4 than the 2.0 flat
    // assumption. Higher cell_aspect ⇒ fewer rows per col ⇒ image
    // appears shorter, which is what the user asked for after a
    // wide landscape screenshot still looked tall at 2.0.
    const CELL_ASPECT: f32 = 2.4;
    let img_aspect = img_h_px as f32 / img_w_px as f32;
    // rows/cols needed to preserve aspect = img_aspect / CELL_ASPECT.
    let cells_ratio = img_aspect / CELL_ASPECT;
    let rows_if_full_cols = (body.width as f32 * cells_ratio).round() as u16;
    let cols_if_full_rows = (body.height as f32 / cells_ratio).round() as u16;
    let (cols, rows) = if rows_if_full_cols <= body.height {
        (body.width, rows_if_full_cols.max(1))
    } else {
        (cols_if_full_rows.max(1), body.height)
    };
    let x_pad = body.width.saturating_sub(cols) / 2;
    let y_pad = body.height.saturating_sub(rows) / 2;
    Rect {
        x: body.x + x_pad,
        y: body.y + y_pad,
        width: cols,
        height: rows,
    }
}
