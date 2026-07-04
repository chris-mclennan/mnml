//! `:debug.rects` overlay — paints colored borders around every
//! registered click-rect so the user can SEE where clicks are caught
//! vs where the glyphs are visually rendered. Toggled via the
//! `:debug.rects` ex-command. Bug-hunt tool added 2026-06-19 after a
//! wide-glyph display-cell off-by-one (the workspace `+` chip used
//! `chip_w = 3` char-count but rendered 4 cells wide) hid for hours.
//!
//! Each rect family gets its own color so multiple families can be
//! seen at once. The overlay does NOT clip to its rect — it only
//! paints the edge cells, so the underlying content stays visible.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};

use crate::app::App;

/// Paint the debug-rect overlay if `app.debug_rects` is on. No-op
/// otherwise. Caller is `ui::draw`; runs LAST so the borders sit on
/// top of every other paint layer.
pub fn draw(frame: &mut Frame, app: &App) {
    if !app.debug_rects {
        return;
    }
    // Hot-path order matters only for layering; the per-family color
    // is what disambiguates. Anything that's `Some(Rect)` paints a
    // single bordered box; `Vec<(Rect, _)>` paints one per entry.
    use ratatui::style::Color;

    paint_single(frame, app.rects.tree_toggle, Color::Cyan);
    paint_single(frame, app.rects.tree_edge, Color::DarkGray);
    paint_single(frame, app.rects.integration_section_toggle, Color::Magenta);
    paint_single(frame, app.rects.statusline_workspace_chip, Color::Yellow);
    paint_single(frame, app.rects.statusline_branch_chip, Color::Yellow);
    paint_single(frame, app.rects.statusline_mode_chip, Color::Yellow);
    paint_single(frame, app.rects.statusline_clock_chip, Color::Yellow);
    paint_single(frame, app.rects.statusline_mixr_chip, Color::Green);
    paint_single(frame, app.rects.activity_bar_gear, Color::Cyan);
    paint_single(frame, app.rects.cmdline_bar, Color::DarkGray);

    for (r, _) in &app.rects.tree_icon_buttons {
        paint_single(frame, Some(*r), Color::LightGreen);
    }
    for (r, _) in &app.rects.integration_icon_rects {
        paint_single(frame, Some(*r), Color::Magenta);
    }
    for (r, _) in &app.rects.activity_bar_icons {
        paint_single(frame, Some(*r), Color::LightBlue);
    }
    for (r, _) in &app.rects.launcher_icon_rects {
        paint_single(frame, Some(*r), Color::LightYellow);
    }

    // 2026-06-19 — vscode-user-mouse agent flagged that ~30 of
    // ~40 rect families were uncovered. Adding the high-impact
    // ones that drive request-pane / picker / bufferline /
    // context-menu hit-testing. Less load-bearing families
    // (scrollbar thumbs, fold chips, completion items, settings
    // rows) stay out — `:debug.rects` is primarily a hunt aid
    // for clickable surfaces.
    paint_single(frame, app.rects.picker_box, Color::Blue);
    for (r, _) in &app.rects.picker_items {
        paint_single(frame, Some(*r), Color::LightCyan);
    }
    for (r, _, _) in &app.rects.request_fields {
        paint_single(frame, Some(*r), Color::LightMagenta);
    }
    for (r, _) in &app.rects.bufferline_tabs {
        paint_single(frame, Some(*r), Color::Yellow);
    }
    for (r, _) in &app.rects.context_menu_items {
        paint_single(frame, Some(*r), Color::LightRed);
    }
    for (r, _) in &app.rects.extra_workspace_toggles {
        paint_single(frame, Some(*r), Color::Cyan);
    }
    for (r, _) in &app.rects.git_rail_rows {
        paint_single(frame, Some(*r), Color::Green);
    }
}

/// Paint a single rect outline using box-drawing edge-only cells.
/// For 1-row rects, just colors the foreground of the existing cells
/// so the rect appears as an underline-style highlight. For taller
/// rects, draws a proper bordered box.
fn paint_single(frame: &mut Frame, r: Option<Rect>, color: ratatui::style::Color) {
    let Some(r) = r else { return };
    if r.width == 0 || r.height == 0 {
        return;
    }
    let buf = frame.buffer_mut();
    let style = Style::default()
        .fg(color)
        .add_modifier(Modifier::BOLD | Modifier::REVERSED);
    if r.height == 1 {
        // 1-row case — color the cells in place (don't overwrite the
        // glyph) so the user can see the rect's horizontal coverage
        // against the rendered content underneath.
        for x in r.x..r.x.saturating_add(r.width) {
            if let Some(cell) = buf.cell_mut((x, r.y)) {
                cell.set_style(cell.style().patch(style));
            }
        }
        return;
    }
    // Multi-row rect — draw a corner-and-edge box.
    let x0 = r.x;
    let x1 = r.x + r.width - 1;
    let y0 = r.y;
    let y1 = r.y + r.height - 1;
    if let Some(c) = buf.cell_mut((x0, y0)) {
        c.set_char('┌').set_style(style);
    }
    if let Some(c) = buf.cell_mut((x1, y0)) {
        c.set_char('┐').set_style(style);
    }
    if let Some(c) = buf.cell_mut((x0, y1)) {
        c.set_char('└').set_style(style);
    }
    if let Some(c) = buf.cell_mut((x1, y1)) {
        c.set_char('┘').set_style(style);
    }
    for x in (x0 + 1)..x1 {
        if let Some(c) = buf.cell_mut((x, y0)) {
            c.set_char('─').set_style(style);
        }
        if let Some(c) = buf.cell_mut((x, y1)) {
            c.set_char('─').set_style(style);
        }
    }
    for y in (y0 + 1)..y1 {
        if let Some(c) = buf.cell_mut((x0, y)) {
            c.set_char('│').set_style(style);
        }
        if let Some(c) = buf.cell_mut((x1, y)) {
            c.set_char('│').set_style(style);
        }
    }
}
