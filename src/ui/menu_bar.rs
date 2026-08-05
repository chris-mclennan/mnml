//! Dropdown overlay renderer for the menu bar. The bar words
//! themselves are painted by `draw_palette_bar` in `src/ui/mod.rs`;
//! this module draws the dropdown panel that appears when a menu
//! is open.

use ratatui::{
    Frame,
    layout::Rect,
    style::Style,
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
    let menus = bar(app);
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
    // Submenu rows reserve extra space for the trailing `▸`.
    let max_label = menu
        .items
        .iter()
        .map(|it| match it {
            MenuItem::Action { label, .. } => label.chars().count(),
            MenuItem::Submenu { label, .. } => label.chars().count() + 2,
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

    let block = crate::ui::design_tokens::popup_menu("");
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
        let row_style = if is_highlighted {
            crate::ui::design_tokens::row_highlight_menu()
        } else {
            crate::ui::design_tokens::row_plain_menu()
        };
        let line = match item {
            MenuItem::Action { label, .. } => {
                // nvchad-user + vscode-user-keyboard 2026-07-30 —
                // color-only highlight was invisible in headless
                // (screen.txt strips ANSI) and in low-color terminals.
                // Add a leading `▸ ` on the selected row so cursor
                // position reads in the text grid too.
                let marker = if is_highlighted { "\u{25B8} " } else { "  " };
                let pad = inner
                    .width
                    .saturating_sub(label.chars().count() as u16 + marker.chars().count() as u16)
                    as usize;
                Line::from(vec![
                    Span::styled(marker, row_style),
                    Span::styled(label.to_string(), row_style),
                    Span::styled(" ".repeat(pad), row_style),
                ])
            }
            MenuItem::Submenu { label, .. } => {
                // Trailing ▸ signals nesting.
                let marker = if is_highlighted { "\u{25B8} " } else { "  " };
                let trail = " \u{25B8}";
                let used = label.chars().count() + marker.chars().count() + trail.chars().count();
                let pad = inner.width.saturating_sub(used as u16) as usize;
                Line::from(vec![
                    Span::styled(marker, row_style),
                    Span::styled(label.to_string(), row_style),
                    Span::styled(" ".repeat(pad), row_style),
                    Span::styled(trail.to_string(), row_style),
                ])
            }
            MenuItem::Separator => Line::from(vec![Span::styled(
                "─".repeat(inner.width as usize),
                Style::default().fg(t.comment).bg(t.bg2),
            )]),
        };
        frame.render_widget(Paragraph::new(line), row_rect);
        if matches!(item, MenuItem::Action { .. } | MenuItem::Submenu { .. }) {
            app.rects.menu_bar_items.push((row_rect, i));
        }
    }

    // Draw an open submenu, if any, to the right of the parent panel.
    if let Some(sub_idx) = open.sub_item_idx
        && let Some(MenuItem::Submenu {
            items: sub_items, ..
        }) = menu.items.get(open.item_idx)
    {
        let parent_row_y = inner.y + open.item_idx as u16;
        let sub_max_label = sub_items
            .iter()
            .map(|it| match it {
                MenuItem::Action { label, .. } => label.chars().count(),
                MenuItem::Submenu { label, .. } => label.chars().count() + 2,
                MenuItem::Separator => 0,
            })
            .max()
            .unwrap_or(10);
        let sub_w = (sub_max_label as u16 + 4).max(20);
        let sub_h = sub_items.len() as u16 + 2;
        let mut sub_x = area.x + area.width;
        // Flip to the left if we'd overflow the right edge.
        if sub_x + sub_w > screen_w {
            sub_x = area.x.saturating_sub(sub_w);
        }
        let sub_y = parent_row_y.saturating_sub(1);
        let sub_area = Rect {
            x: sub_x,
            y: sub_y.min(screen_h.saturating_sub(sub_h)),
            width: sub_w,
            height: sub_h.min(screen_h.saturating_sub(sub_y)),
        };
        frame.render_widget(Clear, sub_area);
        let sub_block = crate::ui::design_tokens::popup_menu("");
        let sub_inner = sub_block.inner(sub_area);
        frame.render_widget(sub_block, sub_area);
        for (i, item) in sub_items.iter().enumerate() {
            let row_rect = Rect {
                x: sub_inner.x,
                y: sub_inner.y + i as u16,
                width: sub_inner.width,
                height: 1,
            };
            let is_hl = i == sub_idx;
            let row_style = if is_hl {
                crate::ui::design_tokens::row_highlight_menu()
            } else {
                crate::ui::design_tokens::row_plain_menu()
            };
            let line = match item {
                MenuItem::Action { label, .. } => {
                    let marker = if is_hl { "\u{25B8} " } else { "  " };
                    let pad = sub_inner.width.saturating_sub(
                        label.chars().count() as u16 + marker.chars().count() as u16,
                    ) as usize;
                    Line::from(vec![
                        Span::styled(marker, row_style),
                        Span::styled(label.to_string(), row_style),
                        Span::styled(" ".repeat(pad), row_style),
                    ])
                }
                MenuItem::Submenu { label, .. } => {
                    // Nested-nested: render the label + ▸, but the
                    // click / Enter is a no-op (we don't recurse).
                    let marker = if is_hl { "\u{25B8} " } else { "  " };
                    let trail = " \u{25B8}";
                    let used =
                        label.chars().count() + marker.chars().count() + trail.chars().count();
                    let pad = sub_inner.width.saturating_sub(used as u16) as usize;
                    Line::from(vec![
                        Span::styled(marker, row_style),
                        Span::styled(label.to_string(), row_style),
                        Span::styled(" ".repeat(pad), row_style),
                        Span::styled(trail.to_string(), row_style),
                    ])
                }
                MenuItem::Separator => Line::from(vec![Span::styled(
                    "─".repeat(sub_inner.width as usize),
                    Style::default().fg(t.comment).bg(t.bg2),
                )]),
            };
            frame.render_widget(Paragraph::new(line), row_rect);
            if matches!(item, MenuItem::Action { .. }) {
                // Encode as parent_item*1000 + sub_i so the click
                // dispatcher can decode which submenu row was hit
                // without a separate rect list.
                app.rects
                    .menu_bar_items
                    .push((row_rect, 1000 + open.item_idx * 100 + i));
            }
        }
    }
}
