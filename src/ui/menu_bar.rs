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
    // Task #886 — icon column width, computed HERE so the panel-width
    // math below can include it (was previously computed after the
    // panel was already sized, causing overflow + clip of long
    // labels + the submenu ▸ trail). 0 when no items have icons.
    // 2-cell gap between icon and label. `chars().count()` matches
    // the render-side math; assumes single-cell Nerd Font glyphs
    // (all our icons live in the `\u{Exxx}` / `\u{Fxxxx}` PUA ranges
    // which wcwidth reports as 1).
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
    // Widest label + icon column sets the panel width; +4 for padding
    // + borders. Submenu rows reserve extra space for the trailing `▸`.
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
    // #1097 (2026-08-20) — cache the visible index list under the
    // current filter. Empty filter → every index (existing render).
    // Non-empty filter → only items whose label matches (case-
    // insensitive substring); separators are dropped entirely so
    // filtered groups don't render disjoint horizontal rules.
    let visible_idxs: Vec<usize> = open.visible_indexes(&menu.items);
    let w = (max_label as u16 + icon_col_w + 4).max(20);
    // #1097 — reserve a filter row at the top when filter_focused
    // (or when a non-empty filter is left after a user unfocused
    // via `/`) so the current filter text is always visible while
    // it's affecting the list.
    let show_filter_row = open.filter_focused || !open.filter.is_empty();
    let filter_row_h: u16 = if show_filter_row { 1 } else { 0 };
    let h = visible_idxs.len() as u16 + 2 + filter_row_h; // +2 for borders
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
    // `icon_col_w` was computed above alongside `max_label` so the
    // panel-width math could include it.

    // #1097 — draw the filter row (`/ text│`) at the top when we're
    // in filter mode. Same "/" prefix as the palette + help overlay
    // so the input affordance reads consistently.
    let items_y_base = if show_filter_row {
        let filter_row = Rect {
            x: inner.x,
            y: inner.y,
            width: inner.width,
            height: 1,
        };
        let filter_style = if open.filter_focused {
            Style::default().fg(t.cyan)
        } else {
            Style::default().fg(t.comment)
        };
        let cursor = if open.filter_focused { "│" } else { "" };
        let empty_hint = if open.filter.is_empty() && open.filter_focused {
            "type to filter…"
        } else {
            ""
        };
        let filter_line = Line::from(vec![
            Span::styled(" / ", filter_style),
            Span::styled(open.filter.clone(), Style::default().fg(t.fg)),
            Span::styled(cursor.to_string(), filter_style),
            Span::styled(
                empty_hint.to_string(),
                Style::default()
                    .fg(t.comment)
                    .add_modifier(ratatui::style::Modifier::DIM),
            ),
        ]);
        frame.render_widget(Paragraph::new(filter_line), filter_row);
        inner.y + 1
    } else {
        inner.y
    };

    for (row_i, &i) in visible_idxs.iter().enumerate() {
        let item = &menu.items[i];
        let row_rect = Rect {
            x: inner.x,
            y: items_y_base + row_i as u16,
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
        // #1097 — under filter, the parent row's y is its position
        // in the visible slice, not `open.item_idx` directly. Fall
        // back to item_idx when filter is empty (original behavior).
        let parent_visible_row = visible_idxs
            .iter()
            .position(|&i| i == open.item_idx)
            .unwrap_or(open.item_idx);
        let parent_row_y = items_y_base + parent_visible_row as u16;
        // Same icon-column treatment as the top-level dropdown above
        // (#886) — hoisted BEFORE the panel-width math so `sub_w`
        // reserves room for icon + label + trail (was previously
        // computed after `sub_w`, causing long submenu labels to
        // overflow + clip).
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
        let sub_max_label = sub_items
            .iter()
            .map(|it| match it {
                MenuItem::Action { label, .. } => label.chars().count(),
                MenuItem::Submenu { label, .. } => label.chars().count() + 2,
                MenuItem::Separator => 0,
            })
            .max()
            .unwrap_or(10);
        let sub_w = (sub_max_label as u16 + sub_icon_col_w + 4).max(20);
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
