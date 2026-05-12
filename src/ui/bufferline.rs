//! The top "tabufline" — a strip of all open buffers, NvChad-style. (Tabpage
//! indicators / theme toggle on the right come later; for now it's just the
//! buffer strip.)

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::pane::Pane;
use crate::ui::{icons, theme};

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(theme::BG_DARKER)), area);
    app.rects.bufferline_tabs.clear();
    if area.width == 0 {
        return;
    }
    let nerd = !app.config.ui.ascii_icons;

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
        let dirty = if pane.is_dirty() { " ●" } else { "" };
        let label = format!(" {glyph} {name}{dirty} ");
        let cells = label.chars().count() as u16;
        if x + cells > area.x + area.width {
            break;
        }
        let (bg, fg) = if active { (theme::BG, theme::FG) } else { (theme::BG_DARKER, theme::GREY_FG) };
        // icon segment + label segment so the icon keeps its color
        let icon_seg = format!(" {glyph} ");
        let rest = format!("{name}{dirty} ");
        let mut name_style = Style::default().fg(fg).bg(bg);
        if active {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        spans.push(Span::styled(icon_seg.clone(), Style::default().fg(if active { icon_color } else { theme::GREY }).bg(bg)));
        spans.push(Span::styled(rest.clone(), name_style));
        app.rects.bufferline_tabs.push((Rect { x, y: area.y, width: cells, height: 1 }, i));
        x += cells;
    }
    if app.panes.is_empty() {
        spans.push(Span::styled(" mnml ", Style::default().fg(theme::GREY_FG).bg(theme::BG_DARKER)));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}
