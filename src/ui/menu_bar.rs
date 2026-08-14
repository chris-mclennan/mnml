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
    // R6 R2 vscode-keyboard + claude-agents SEV-2 F1 (regression from
    // 195723ee) — if the parent chip word isn't in `menu_bar_words`
    // (menu word was clipped off the chrome by the workspace-chip
    // cluster), fall back to painting the dropdown just right of
    // the LAST visible menu word. Previously this early-returned,
    // leaving `menu_open = Some(idx)` set but nothing rendered — an
    // invisible input trap that swallowed keystrokes AND fired the
    // phantom first Action on Enter. Now the dropdown paints at a
    // sensible fallback position so the user always sees what
    // they're navigating.
    let word_rect = app
        .rects
        .menu_bar_words
        .iter()
        .find(|(_, i)| *i == open.menu_idx)
        .map(|(r, _)| *r)
        .unwrap_or_else(|| {
            // Compute a fallback origin: right after the last visible
            // menu word, or col 0 if nothing's visible.
            let fallback_x = app
                .rects
                .menu_bar_words
                .iter()
                .map(|(r, _)| r.x + r.width + 1)
                .max()
                .unwrap_or(0);
            let fallback_y = app
                .rects
                .menu_bar_words
                .first()
                .map(|(r, _)| r.y)
                .unwrap_or(0);
            Rect {
                x: fallback_x,
                y: fallback_y,
                width: 0,
                height: 1,
            }
        });

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
    // R7 vscode-keyboard SEV-1 2026-08-09: the height clamp was
    // missing, so a Window menu (25 items + 2 borders = 27 rows)
    // on a 25-row terminal painted past the buffer and panicked
    // inside ratatui (`index outside of buffer (0, 25)`). Clamp
    // both dimensions to the screen and drop y to 0 if height
    // consumed everything — the dropdown just truncates at the
    // bottom in that case, which is worse than we'd like but
    // infinitely better than a session-ending crash.
    let screen_w = frame.area().width;
    let screen_h = frame.area().height;
    let clamped_h = h.min(screen_h);
    let area = Rect {
        x: area.x.min(screen_w.saturating_sub(w)),
        y: area.y.min(screen_h.saturating_sub(clamped_h)),
        width: w,
        height: clamped_h,
    };
    frame.render_widget(Clear, area);

    let block = crate::ui::design_tokens::popup_menu("");
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let highlight_visible = open.keyboard_opened || open.item_idx != usize::MAX;

    // Task #886 — reserve an icon column only when at least one
    // Action/Submenu in this dropdown has an icon. Purely iconless
    // menus render flush-left as before (no wasted space). Width is
    // the char-count of the widest icon + 2-cell gap between icon
    // and label.
    let icon_col_w = menu
        .items
        .iter()
        .filter_map(|it| match it {
            MenuItem::Action { icon, .. } | MenuItem::Submenu { icon, .. } => icon.as_deref(),
            MenuItem::Separator => None,
        })
        .map(|s| s.chars().count() as u16)
        .max()
        .map(|max_icon| max_icon + 2)
        .unwrap_or(0);

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
        // Icon column rendered with dim comment fg so it reads as
        // chrome affordance, not label text. Preserves row bg via
        // `patch` so highlighted rows keep their fill.
        let icon_style = row_style.patch(Style::default().fg(t.comment));
        // Renders `icon` padded to the shared column width; empty
        // string when the item has no icon so labels still align.
        let icon_span = |icon: &Option<String>| -> Span<'static> {
            if icon_col_w == 0 {
                return Span::styled(String::new(), icon_style);
            }
            let s = icon.as_deref().unwrap_or("");
            let used = s.chars().count() as u16;
            let pad = icon_col_w.saturating_sub(used) as usize;
            Span::styled(format!("{s}{}", " ".repeat(pad)), icon_style)
        };
        let line = match item {
            MenuItem::Action { icon, label, .. } => {
                // nvchad-user + vscode-user-keyboard 2026-07-30 —
                // color-only highlight was invisible in headless
                // (screen.txt strips ANSI) and in low-color terminals.
                // Add a leading `▸ ` on the selected row so cursor
                // position reads in the text grid too.
                let marker = if is_highlighted { "\u{25B8} " } else { "  " };
                let used =
                    label.chars().count() as u16 + marker.chars().count() as u16 + icon_col_w;
                let pad = inner.width.saturating_sub(used) as usize;
                Line::from(vec![
                    Span::styled(marker, row_style),
                    icon_span(icon),
                    Span::styled(label.to_string(), row_style),
                    Span::styled(" ".repeat(pad), row_style),
                ])
            }
            MenuItem::Submenu { icon, label, .. } => {
                // Trailing ▸ signals nesting.
                let marker = if is_highlighted { "\u{25B8} " } else { "  " };
                let trail = " \u{25B8}";
                let used = label.chars().count() as u16
                    + marker.chars().count() as u16
                    + trail.chars().count() as u16
                    + icon_col_w;
                let pad = inner.width.saturating_sub(used) as usize;
                Line::from(vec![
                    Span::styled(marker, row_style),
                    icon_span(icon),
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
        // Same icon-column treatment as the top-level dropdown above
        // (#886) — reserved only if at least one submenu item has an
        // icon. Kept in-scope so the closure below can reference it.
        let sub_icon_col_w = sub_items
            .iter()
            .filter_map(|it| match it {
                MenuItem::Action { icon, .. } | MenuItem::Submenu { icon, .. } => icon.as_deref(),
                MenuItem::Separator => None,
            })
            .map(|s| s.chars().count() as u16)
            .max()
            .map(|max_icon| max_icon + 2)
            .unwrap_or(0);
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
            let icon_style = row_style.patch(Style::default().fg(t.comment));
            let icon_span = |icon: &Option<String>| -> Span<'static> {
                if sub_icon_col_w == 0 {
                    return Span::styled(String::new(), icon_style);
                }
                let s = icon.as_deref().unwrap_or("");
                let used = s.chars().count() as u16;
                let pad = sub_icon_col_w.saturating_sub(used) as usize;
                Span::styled(format!("{s}{}", " ".repeat(pad)), icon_style)
            };
            let line = match item {
                MenuItem::Action { icon, label, .. } => {
                    let marker = if is_hl { "\u{25B8} " } else { "  " };
                    let used = label.chars().count() as u16
                        + marker.chars().count() as u16
                        + sub_icon_col_w;
                    let pad = sub_inner.width.saturating_sub(used) as usize;
                    Line::from(vec![
                        Span::styled(marker, row_style),
                        icon_span(icon),
                        Span::styled(label.to_string(), row_style),
                        Span::styled(" ".repeat(pad), row_style),
                    ])
                }
                MenuItem::Submenu { icon, label, .. } => {
                    // Nested-nested: render the label + ▸, but the
                    // click / Enter is a no-op (we don't recurse).
                    let marker = if is_hl { "\u{25B8} " } else { "  " };
                    let trail = " \u{25B8}";
                    let used = label.chars().count() as u16
                        + marker.chars().count() as u16
                        + trail.chars().count() as u16
                        + sub_icon_col_w;
                    let pad = sub_inner.width.saturating_sub(used) as usize;
                    Line::from(vec![
                        Span::styled(marker, row_style),
                        icon_span(icon),
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
