//! The "tabufline" — a strip of open-buffer tabs (NvChad-style). It sits over
//! the pane body only, not above the tree rail. A small `TABS` cap is pinned to
//! the right.
//!
//! TODO(later): flesh out the right-hand cluster to match NvChad — a `+`
//! "new file" button, the `TABS` label, tabpage indicators (`1` `2` …), a
//! tabpage close `×`, a theme-toggle slider, and a window close `×`. Each is a
//! clickable segment (record its rect in `app.rects` like the buffer tabs).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::pane::Pane;
use crate::ui::{icons, theme};

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::BG_DARKER)),
        area,
    );
    app.rects.bufferline_tabs.clear();
    app.rects.bufferline_tab_close.clear();
    if area.width == 0 {
        return;
    }
    let nerd = !app.config.ui.ascii_icons;
    let cap_label = " TABS ";
    let cap_w = cap_label.chars().count() as u16;
    let tabs_max_x = area.x + area.width.saturating_sub(cap_w);

    let mut spans: Vec<Span> = Vec::new();
    let mut x = area.x;
    for (i, pane) in app.panes.iter().enumerate() {
        let active = app.active == Some(i);
        let name = pane.title();
        let (glyph, icon_color) = match pane {
            Pane::Editor(b) => {
                let p = b.path.clone().unwrap_or_else(|| name.clone().into());
                icons::for_path(&p, false, false, nerd)
            }
        };
        let badge = if pane.is_dirty() { "●" } else { "×" };
        // ` <icon> <name> <badge> `
        let label = format!(" {glyph} {name} {badge} ");
        let cells = label.chars().count() as u16;
        if x + cells > tabs_max_x {
            break;
        }
        let (bg, name_fg, badge_fg) = if active {
            (
                theme::BG,
                theme::FG,
                if pane.is_dirty() {
                    theme::ORANGE
                } else {
                    theme::GREY_FG
                },
            )
        } else {
            (theme::BG_DARKER, theme::GREY_FG, theme::GREY)
        };
        let mut name_style = Style::default().fg(name_fg).bg(bg);
        if active {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        spans.push(Span::styled(
            format!(" {glyph} "),
            Style::default()
                .fg(if active { icon_color } else { theme::GREY })
                .bg(bg),
        ));
        spans.push(Span::styled(format!("{name} "), name_style));
        spans.push(Span::styled(
            format!("{badge} "),
            Style::default().fg(badge_fg).bg(bg),
        ));
        app.rects.bufferline_tabs.push((
            Rect {
                x,
                y: area.y,
                width: cells,
                height: 1,
            },
            i,
        ));
        // the close target = the badge + its trailing space (the last 2 cells of the tab)
        if cells >= 2 {
            app.rects.bufferline_tab_close.push((
                Rect {
                    x: x + cells - 2,
                    y: area.y,
                    width: 2,
                    height: 1,
                },
                i,
            ));
        }
        x += cells;
        // thin separator into the strip background
        if i + 1 < app.panes.len() {
            spans.push(Span::styled(" ", Style::default().bg(theme::BG_DARKER)));
            x += 1;
        }
    }
    if app.panes.is_empty() {
        spans.push(Span::styled(
            "  no buffers ",
            Style::default().fg(theme::GREY_FG).bg(theme::BG_DARKER),
        ));
        x += "  no buffers ".chars().count() as u16;
    }
    // fill the gap up to the cap
    if x < tabs_max_x {
        spans.push(Span::styled(
            " ".repeat((tabs_max_x - x) as usize),
            Style::default().bg(theme::BG_DARKER),
        ));
    }
    // right cap
    spans.push(Span::styled(
        cap_label,
        Style::default()
            .fg(theme::BG_DARKER)
            .bg(theme::BLUE)
            .add_modifier(Modifier::BOLD),
    ));

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}
