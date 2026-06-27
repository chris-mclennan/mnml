//! Renders the right-click context menu — a small bordered floating list at the
//! click cell (clamped to the screen), the selected row highlighted. State lives
//! in `crate::context_menu`; key + mouse handling is in `tui.rs` (it records the
//! per-row hitboxes here).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(menu) = &app.context_menu else {
        return;
    };
    app.rects.context_menu_items.clear();
    app.rects.context_menu_box = None;
    if menu.items.is_empty() || screen.width < 4 || screen.height < 3 {
        return;
    }
    let t = theme::cur();

    let inner_w = menu.content_width();
    let w = ((inner_w as u16) + 2).min(screen.width.saturating_sub(1));
    // Rows: optional title + one per item.
    let title_rows = if menu.title.is_some() { 1u16 } else { 0 };
    let h = (menu.items.len() as u16 + title_rows + 2).min(screen.height.saturating_sub(1));

    // Anchor near the click, but keep the box on screen.
    let (ax, ay) = menu.anchor;
    let x = ax.min(screen.x + screen.width.saturating_sub(w));
    let y = ay.min(screen.y + screen.height.saturating_sub(h));
    let area = Rect {
        x: x.max(screen.x),
        y: y.max(screen.y),
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t.grey_fg).bg(t.bg_darker))
        .style(Style::default().bg(t.bg_darker));
    // Title is just a dim label in the border area, NOT a chip.
    // The previous solid-blue chip styling visually merged with
    // the (auto-selected) first row's highlight, making it look
    // like the first row was part of the title. Match the
    // macOS / IDE menu-bar look — quiet header, no chip.
    let block = match &menu.title {
        Some(title) => block.title(Span::styled(
            format!(" {title} "),
            Style::default()
                .fg(t.comment)
                .bg(t.bg_darker)
                .add_modifier(Modifier::BOLD),
        )),
        None => block,
    };
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }

    let visible = (inner.height as usize).min(menu.items.len());
    for (row, item) in menu.items.iter().take(visible).enumerate() {
        let r = Rect::new(inner.x, inner.y + row as u16, inner.width, 1);
        // Only paint the highlight once the user has interacted
        // (mouse hover or arrow keys). On first open with no
        // interaction, rows render plain — matches the macOS /
        // VS Code menu-bar look the user prefers. Enter / click
        // still fire whatever's at `selected` (0 by default), so
        // the no-highlight state isn't inert.
        let selected = row == menu.selected && menu.interacted;
        let style = if selected {
            Style::default()
                .fg(t.bg_darker)
                .bg(t.blue)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(t.bg_darker)
        };
        // Pad the label so the highlight fills the row.
        let mut label = format!(" {} ", item.label);
        let want = inner.width as usize;
        if label.chars().count() < want {
            label.push_str(&" ".repeat(want - label.chars().count()));
        }
        frame.render_widget(Paragraph::new(Line::from(Span::styled(label, style))), r);
        app.rects.context_menu_items.push((r, row));
    }
    app.rects.context_menu_box = Some(area);
}
