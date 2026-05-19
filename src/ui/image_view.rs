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
                        "  Image preview requires Kitty or iTerm2 inline-image protocol.",
                        dim,
                    )),
                    Line::from(""),
                    Line::from(Span::styled(
                        "  Supported terminals: Kitty, WezTerm, Ghostty, iTerm2, recent Konsole.",
                        dim,
                    )),
                    Line::from(Span::styled(
                        "  Set $KITTY_WINDOW_ID or $TERM_PROGRAM accordingly when running mnml.",
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
                    app.image_paint_requests.push(crate::image::PaintRequest {
                        pane_id,
                        area: body_area,
                        png_bytes,
                    });
                }
            }
        }
    }

    None
}
