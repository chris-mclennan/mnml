//! Dropdown overlay renderer for the menu bar. The bar words
//! themselves are painted by `draw_palette_bar` in `src/ui/mod.rs`;
//! this module draws the dropdown panel that appears when a menu
//! is open.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Clear, Paragraph},
};

use crate::app::App;
use crate::menu_bar::{MenuItem, bar};
use crate::ui::theme;

pub fn draw_dropdown(frame: &mut Frame, app: &mut App) {
    app.rects.menu_bar_items.clear();
    let Some(open) = app.menu_open.as_ref().cloned() else {
        return;
    };
    let menus = bar();
    let Some(menu) = menus.get(open.menu_idx) else {
        return;
    };
    let Some((word_rect, _)) = app
        .rects
        .menu_bar_words
        .iter()
        .find(|(_, i)| *i == open.menu_idx)
        .copied()
    else {
        return;
    };

    let t = theme::cur();
    // Widest label sets the panel width; +4 for padding + borders.
    let max_label = menu
        .items
        .iter()
        .map(|it| match it {
            MenuItem::Action { label, .. } => label.chars().count(),
            MenuItem::Separator => 0,
        })
        .max()
        .unwrap_or(10);
    let w = (max_label as u16 + 4).max(20);
    let h = menu.items.len() as u16 + 2; // +2 for borders
    let x = word_rect.x;
    // Drop the panel just below the chrome row.
    let y = word_rect.y + 1;
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    // Make sure we don't overflow the screen.
    let screen_w = frame.area().width;
    let screen_h = frame.area().height;
    let area = Rect {
        x: area.x.min(screen_w.saturating_sub(w)),
        y: area.y.min(screen_h.saturating_sub(h)),
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);

    let block = crate::ui::design_tokens::popup_panel("");
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let highlight_visible = open.keyboard_opened || open.item_idx != usize::MAX;

    for (i, item) in menu.items.iter().enumerate() {
        let row_rect = Rect {
            x: inner.x,
            y: inner.y + i as u16,
            width: inner.width,
            height: 1,
        };
        let is_highlighted = highlight_visible && i == open.item_idx;
        let row_bg = if is_highlighted { t.cyan } else { t.bg2 };
        let row_fg = if is_highlighted { t.bg_dark } else { t.fg };
        let line = match item {
            MenuItem::Action { label, .. } => {
                let pad = inner.width.saturating_sub(label.chars().count() as u16 + 1) as usize;
                Line::from(vec![
                    Span::styled(" ", Style::default().bg(row_bg)),
                    Span::styled(
                        label.to_string(),
                        Style::default()
                            .fg(row_fg)
                            .bg(row_bg)
                            .add_modifier(if is_highlighted {
                                Modifier::BOLD
                            } else {
                                Modifier::empty()
                            }),
                    ),
                    Span::styled(" ".repeat(pad), Style::default().bg(row_bg)),
                ])
            }
            MenuItem::Separator => Line::from(vec![Span::styled(
                "─".repeat(inner.width as usize),
                Style::default().fg(t.comment).bg(t.bg2),
            )]),
        };
        frame.render_widget(Paragraph::new(line), row_rect);
        if matches!(item, MenuItem::Action { .. }) {
            app.rects.menu_bar_items.push((row_rect, i));
        }
    }
}
