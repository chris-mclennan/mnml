//! VSCode-style activity bar — a 4-cell vertical strip on the far left
//! of the rail, with one icon per [`ActivitySection`]. Clicking an
//! icon switches `App.active_section`, which the rail layout uses to
//! pick which content pane fills the area to the right of this strip.
//!
//! v1 only fully wires `Explorer` (the existing file tree); the other
//! sections render a "Coming soon" placeholder pane drawn by the
//! activity-section dispatcher. The activity bar itself ships with
//! all five icons so the shape is visible from day one.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::Line;
use ratatui::widgets::Paragraph;

use crate::app::{ActivitySection, App};
use crate::ui::theme;

/// Width of the activity bar strip in cells. 4 cells = 1 padding + 1
/// glyph + 1 padding + 1 spacer. Matches vscode's visual weight at
/// this terminal-cell density.
pub const ACTIVITY_BAR_WIDTH: u16 = 4;

/// Paint the activity bar into `area`. Registers a click rect per
/// icon on `app.rects.activity_bar_icons` so mouse handling can
/// resolve a click → `ActivitySection`.
pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    app.rects.activity_bar_icons.clear();
    app.rects.activity_bar_gear = None;

    let t = theme::cur();
    let bar_bg = t.bg_darker;
    let nerd = !app.config.ui.ascii_icons;

    // Solid background fill so the strip is visually distinct from
    // the section content area to its right.
    frame.render_widget(
        ratatui::widgets::Block::default().style(Style::default().bg(bar_bg)),
        area,
    );

    // Gear icon at the BOTTOM of the activity bar (VS Code's
    // customary settings position). Click pops a context menu with
    // Settings / Command Palette / Cheatsheet / Themes / About.
    // Painted before the section icons so it has dibs on the bottom
    // row; sections that would overflow into it are clipped.
    let gear_glyph = if nerd { "\u{F013}" } else { "*" }; // nf-fa-cog
    if area.height >= 2 {
        let gear_y = area.y + area.height - 2;
        let gear_row = Rect {
            x: area.x,
            y: gear_y,
            width: area.width,
            height: 1,
        };
        let gear_rect = Rect {
            x: area.x + 1,
            y: gear_y,
            width: area.width.saturating_sub(1),
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(gear_glyph)).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bar_bg)
                    .add_modifier(Modifier::DIM),
            ),
            gear_rect,
        );
        app.rects.activity_bar_gear = Some(gear_row);
    }
    // Carve the section-icon paint area so it stops above the gear.
    let icons_end_y = area.y + area.height.saturating_sub(3);

    let icon_x = area.x + 1; // 1 cell of left padding
    let mut y = area.y + 1; // start 1 row down for top padding

    for section in ActivitySection::all() {
        if y >= icons_end_y {
            break;
        }
        let (glyph_nerd, fallback, _tooltip, _cmd) = section.meta();
        let glyph = if nerd { glyph_nerd } else { fallback };
        let is_active = app.active_section == *section;

        // Active icon: blue fg, bold, with a left-edge accent bar.
        // Inactive: dim fg, no accent.
        let style = if is_active {
            Style::default()
                .fg(t.blue)
                .bg(bar_bg)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
                .fg(t.comment)
                .bg(bar_bg)
                .add_modifier(Modifier::DIM)
        };
        let row = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        // Accent bar on the leftmost column when active.
        if is_active && area.width >= 1 {
            let accent_rect = Rect {
                x: area.x,
                y,
                width: 1,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from("▌")).style(Style::default().fg(t.blue).bg(bar_bg)),
                accent_rect,
            );
        }
        let glyph_rect = Rect {
            x: icon_x,
            y,
            width: area.width.saturating_sub(1),
            height: 1,
        };
        frame.render_widget(Paragraph::new(Line::from(glyph)).style(style), glyph_rect);
        app.rects.activity_bar_icons.push((row, *section));
        // 2 rows per icon for breathing room.
        y = y.saturating_add(2);
    }
}
