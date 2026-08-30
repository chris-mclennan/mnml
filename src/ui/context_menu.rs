//! Renders the right-click context menu — a small bordered floating list at the
//! click cell (clamped to the screen), the selected row highlighted. State lives
//! in `crate::context_menu`; key + mouse handling is in `tui.rs` (it records the
//! per-row hitboxes here).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(menu) = &app.context_menu else {
        return;
    };
    app.rects.context_menu_items.clear();
    app.rects.context_menu_box = None;
    if menu.items.is_empty() || screen.width < 4 || screen.height < 3 {
        return;
    }

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
    // Context menus use the quiet menu chrome — square border,
    // default fg color, `bg2` fill — so visual weight sits on the
    // selected row, not the frame. Matches macOS / VS Code menus.
    let block = crate::ui::design_tokens::popup_menu(menu.title.as_deref().unwrap_or(""));
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
        let mut style = if selected {
            crate::ui::design_tokens::row_highlight_menu()
        } else {
            crate::ui::design_tokens::row_plain_menu()
        };
        // Destructive rows (Close / Delete) paint red when idle.
        // Selection style still wins so the row isn't red-on-red-
        // highlight — matches the widget-kebab convention in
        // `src/ui/dock.rs`.
        if item.destructive && !selected {
            style = style.fg(crate::ui::theme::cur().red);
        }
        // Pad the label so the highlight fills the row. A submenu row
        // reserves its last two cells for the `\u{25b8}` — the visible
        // affordance that is the whole reason to prefer a submenu over a
        // right-click for grouping.
        let want = inner.width as usize;
        let marker = if item.has_submenu() { "\u{25b8} " } else { "" };
        let mut label = format!(" {} ", item.label);
        let room = want.saturating_sub(marker.chars().count());
        if label.chars().count() < room {
            label.push_str(&" ".repeat(room - label.chars().count()));
        }
        label.push_str(marker);
        frame.render_widget(Paragraph::new(Line::from(Span::styled(label, style))), r);
        app.rects.context_menu_items.push((r, row));
    }
    app.rects.context_menu_box = Some(area);

    draw_submenu(frame, app, screen, area);
}

/// Paint the open child menu beside its parent row.
///
/// Opens rightward, and flips to the left when there is no room — the
/// pointer has to be able to travel from the parent row into the child
/// without leaving the chain, and a child clipped at the screen edge
/// makes that impossible.
fn draw_submenu(frame: &mut Frame, app: &mut App, screen: Rect, parent: Rect) {
    app.rects.context_submenu_items.clear();
    app.rects.context_submenu_box = None;
    let Some((prow, menu)) = &app.context_submenu else {
        return;
    };
    if menu.items.is_empty() {
        return;
    }
    let inner_w = menu.content_width();
    let w = ((inner_w as u16) + 2).min(screen.width.saturating_sub(1));
    let h = (menu.items.len() as u16 + 2).min(screen.height.saturating_sub(1));

    // Prefer the right edge of the parent; flip left when that would run
    // off screen.
    let right = parent.x + parent.width;
    let x = if right + w <= screen.x + screen.width {
        right
    } else {
        parent.x.saturating_sub(w)
    };
    // Line the child's first row up with its parent row, then clamp.
    let y = (parent.y + 1 + *prow as u16)
        .min(screen.y + screen.height.saturating_sub(h))
        .max(screen.y);
    let area = Rect {
        x: x.max(screen.x),
        y,
        width: w,
        height: h,
    };

    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::popup_menu("");
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }
    let visible = (inner.height as usize).min(menu.items.len());
    for (row, item) in menu.items.iter().take(visible).enumerate() {
        let r = Rect::new(inner.x, inner.y + row as u16, inner.width, 1);
        let selected = row == menu.selected && menu.interacted;
        let mut style = if selected {
            crate::ui::design_tokens::row_highlight_menu()
        } else {
            crate::ui::design_tokens::row_plain_menu()
        };
        if item.destructive && !selected {
            style = style.fg(crate::ui::theme::cur().red);
        }
        let mut label = format!(" {} ", item.label);
        let want = inner.width as usize;
        if label.chars().count() < want {
            label.push_str(&" ".repeat(want - label.chars().count()));
        }
        frame.render_widget(Paragraph::new(Line::from(Span::styled(label, style))), r);
        app.rects.context_submenu_items.push((r, row));
    }
    app.rects.context_submenu_box = Some(area);
}
