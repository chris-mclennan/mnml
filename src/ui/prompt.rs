//! The single-line text-input overlay (commit message, …) — a small centered
//! box with a title and one editable line. State lives in `crate::prompt`; key
//! handling lives in `tui.rs`. Records the caret cell in `app.rects.prompt_caret`
//! so `ui::draw` can place the terminal cursor here.
//!
//! Path-typed prompts (`AddWorkspace`) also render a live directory
//! listing below the input — the user can keep typing OR navigate the
//! list with ↑↓, Tab autocompletes, Enter accepts the focused row.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(p) = &app.prompt else { return };
    let title = format!(" {} ", p.title);
    let input = p.input.clone();
    let caret_col = p.caret_col();

    // Browse-mode prompts grow taller to fit the directory listing.
    let suggestion_count = p.suggestions.len() as u16;
    let extra_rows = if p.is_path_kind() && suggestion_count > 0 {
        suggestion_count + 1 // suggestions + a thin separator hint
    } else {
        0
    };

    let w = (title.chars().count().max(56) as u16 + 4).min(screen.width.saturating_sub(2));
    let base_h = 5u16;
    let h = (base_h + extra_rows).min(screen.height.saturating_sub(2));
    let area = Rect {
        x: screen.x + (screen.width.saturating_sub(w)) / 2,
        y: screen.y + (screen.height.saturating_sub(h)) / 3,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_menu(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height < 2 {
        return;
    }

    // Place the input field at a fixed offset from the top of the inner
    // area (row 1). For the no-suggestions case this matches the prior
    // centered layout pretty closely; with suggestions, the field moves
    // up so the suggestion list has room below.
    let field_y = inner.y + 1;
    let pad = 1u16;
    let avail = inner.width.saturating_sub(pad) as usize;
    let chars: Vec<char> = input.chars().collect();
    let start = caret_col.saturating_sub(avail.saturating_sub(1));
    let shown: String = chars.iter().skip(start).take(avail).collect();
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            shown,
            Style::default().fg(theme::cur().fg).bg(theme::cur().bg2),
        )))
        .style(Style::default().bg(theme::cur().bg2)),
        Rect::new(inner.x + pad, field_y, inner.width.saturating_sub(pad), 1),
    );

    // Hint row.
    let hint_y = field_y + 1;
    let hint = if p.is_path_kind() && !p.suggestions.is_empty() {
        "  enter submit · ↑↓ browse · tab complete · esc cancel"
    } else if p.is_path_kind() {
        "  enter submit · type to browse · esc cancel"
    } else {
        "  enter to submit · esc to cancel"
    };
    if hint_y < inner.y + inner.height {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                hint,
                Style::default()
                    .fg(theme::cur().comment)
                    .bg(theme::cur().bg2),
            ))),
            Rect::new(inner.x, hint_y, inner.width, 1),
        );
    }

    // Suggestion list (path-typed prompts only). Each row shows the
    // full path with the parent dim and the basename bold; the focused
    // row gets a cyan background highlight.
    if p.is_path_kind() && !p.suggestions.is_empty() {
        let list_top = hint_y + 1;
        for (i, path) in p.suggestions.iter().enumerate() {
            let y = list_top + i as u16;
            if y >= inner.y + inner.height {
                break;
            }
            let focused = p.selected_suggestion == Some(i);
            let row_rect = Rect::new(inner.x, y, inner.width, 1);
            let (parent, name) = split_for_display(path);
            // Focused row uses the menu-family highlight (cyan bg,
            // bg_dark fg); unfocused rows match the panel's own bg2.
            let bg = if focused {
                theme::cur().cyan
            } else {
                theme::cur().bg2
            };
            let fg_main = if focused {
                theme::cur().bg_dark
            } else {
                theme::cur().fg
            };
            let cursor = if focused { "▸" } else { " " };
            let line = Line::from(vec![
                Span::styled(format!(" {cursor} "), Style::default().fg(fg_main).bg(bg)),
                Span::styled(
                    parent,
                    Style::default()
                        .fg(if focused {
                            theme::cur().bg_dark
                        } else {
                            theme::cur().comment
                        })
                        .bg(bg),
                ),
                Span::styled(
                    name,
                    Style::default()
                        .fg(fg_main)
                        .bg(bg)
                        .add_modifier(if focused {
                            Modifier::BOLD
                        } else {
                            Modifier::empty()
                        }),
                ),
            ]);
            frame.render_widget(
                Paragraph::new(line).style(Style::default().bg(bg)),
                row_rect,
            );
        }
    }

    let cx = inner.x + pad + (caret_col - start) as u16;
    app.rects.prompt_caret = Some((cx.min(inner.x + inner.width.saturating_sub(1)), field_y));
}

/// Split a path into a dimmed parent prefix (with trailing `/`) and
/// the basename for highlighted rendering.
fn split_for_display(p: &std::path::Path) -> (String, String) {
    let parent = p
        .parent()
        .map(|q| {
            let mut s = q.to_string_lossy().to_string();
            if !s.ends_with('/') {
                s.push('/');
            }
            s
        })
        .unwrap_or_default();
    let name = p
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    (parent, name)
}
