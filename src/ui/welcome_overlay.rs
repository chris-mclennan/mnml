//! First-launch welcome overlay — a centered floating panel listing the
//! handful of shortcuts new users most need to know. Auto-opens on the
//! first launch in a workspace (no `.mnml/.welcomed` marker); dismissible
//! with Esc / `view.welcome` / `:welcome`. After dismissal the marker is
//! written so the overlay doesn't reappear automatically.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    if !app.show_welcome {
        return;
    }
    // Stand down whenever another modal/overlay is open. The welcome
    // panel is centered and tall; without this, opening a prompt
    // (Ctrl+N → file name, `:` ex-command, `/` find, AI chat) or the
    // fuzzy picker (Ctrl+P / Ctrl+Shift+P) on first launch would
    // visibly bury the input under the welcome card and make the
    // advertised chord targets unreachable. The user still sees the
    // welcome card on next blank frame.
    if app.prompt.is_some()
        || app.picker.is_some()
        || app.help_overlay.is_some()
        || app.signature.is_some()
        || app.completion.is_some()
    {
        return;
    }
    let t = theme::cur();
    // Curated tips — the bare minimum a new user needs to click and chord
    // their way around.
    type Tip = (&'static str, &'static str);
    let tips: [Tip; 9] = [
        ("F1", "help overlay (this is similar — keymap reference)"),
        ("Ctrl+P", "fuzzy file picker"),
        ("Ctrl+Shift+P", "command palette"),
        ("Ctrl+B", "toggle the file tree (rail)"),
        ("Ctrl+T", "open a shell pane"),
        ("<leader>g l", "commit graph (or click branch chip)"),
        ("<leader>l h", "LSP hover info"),
        ("right-click anywhere", "context menu for that surface"),
        (":welcome / view.welcome", "reopen this overlay any time"),
    ];

    let title = " Welcome to mnml — Esc / click outside to dismiss ";
    let inner_w = tips
        .iter()
        .map(|(k, v)| k.chars().count() + 4 + v.chars().count())
        .max()
        .unwrap_or(50)
        .max(title.chars().count() + 4);
    let w = (inner_w as u16 + 4).min(screen.width);
    // Lines: 1 intro + tips + 1 spacer + 1 footer.
    let n_lines = 1 + tips.len() as u16 + 2;
    let h = (n_lines + 2).min(screen.height);
    let x = screen
        .x
        .saturating_add((screen.width.saturating_sub(w)) / 2);
    let y = screen
        .y
        .saturating_add((screen.height.saturating_sub(h)) / 3);
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_darker)
                .bg(t.green)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let key_w = tips
        .iter()
        .map(|(k, _)| k.chars().count())
        .max()
        .unwrap_or(8);
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(tips.len() + 3);
    lines.push(Line::from(Span::styled(
        " A handful of shortcuts to start with: ".to_string(),
        Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
    )));
    for (k, v) in tips.iter() {
        let key_padded = format!(" {k:<w$}  ", w = key_w);
        lines.push(Line::from(vec![
            Span::styled(
                key_padded,
                Style::default().fg(t.yellow).add_modifier(Modifier::BOLD),
            ),
            Span::styled(v.to_string(), Style::default().fg(t.comment)),
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        " Tip: hover any clickable chip ~500ms for a tooltip. ".to_string(),
        Style::default()
            .fg(t.comment)
            .add_modifier(Modifier::ITALIC),
    )));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}
