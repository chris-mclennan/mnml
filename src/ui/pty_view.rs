//! Renders a `Pane::Pty` — the libghostty-vt grid (snapshotted into a flat
//! [`RenderGrid`](crate::pty_pane::RenderGrid)), cell by cell, into the pane's
//! area. Resizes the pty session to the rendered area first (so the child draws
//! at the right size). Returns the on-screen cursor cell when focused so
//! `ui::draw` can place the caret.

use libghostty_vt::style::RgbColor;
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::pty_pane::RenderCell;
use crate::ui::theme;

pub fn draw(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    if !matches!(app.panes.get(pane_id), Some(Pane::Pty(_))) {
        return None;
    }
    // Reserve the top row for a session tab strip only when the
    // strip would render 2+ tabs. qa-feature 2026-07-01 — was
    // always reserved even when the strip was empty (single pty
    // showed just a lone `+`); the row wasted space. Also
    // suppress when the leaf-tab strip (rendered by render_layout
    // for split leaves) already carries the same pty tabs — the
    // check is `ptys in this leaf >= 2`, not the global count.
    let mut grid_area = area;
    let leaf_pty_count: usize = app
        .layout()
        .leaf_containing(pane_id)
        .map(|leaf| {
            leaf.iter()
                .filter(|&&pid| matches!(app.panes.get(pid), Some(Pane::Pty(_))))
                .count()
        })
        .unwrap_or_else(|| {
            app.panes
                .iter()
                .filter(|p| matches!(p, Pane::Pty(_)))
                .count()
        });
    if area.height >= 3 && leaf_pty_count >= 2 {
        let strip = Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        };
        draw_tab_strip(frame, app, pane_id, strip);
        grid_area = Rect {
            x: area.x,
            y: area.y + 1,
            width: area.width,
            height: area.height - 1,
        };
    }
    let area = grid_area;
    let Some(Pane::Pty(session)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    session.resize(area.height, area.width);
    let exited = session.is_exited();
    let grid = session.render_grid();
    let (rows, cols) = (grid.rows, grid.cols);

    let def_fg = theme::cur().fg;
    let def_bg = theme::cur().bg_dark;
    // mouse-round-9 SEV-2 2026-07-11 — pty drag-select. If a drag is
    // in flight over THIS pane, precompute the row-major linear range
    // once so the inner loop can invert cells in constant time.
    let sel_range: Option<(usize, usize)> = match app.pty_drag_select {
        Some((sel_pid, origin, cur)) if sel_pid == pane_id => {
            let a_idx = origin.1 as usize * cols as usize + origin.0 as usize;
            let b_idx = cur.1 as usize * cols as usize + cur.0 as usize;
            if a_idx <= b_idx {
                Some((a_idx, b_idx))
            } else {
                Some((b_idx, a_idx))
            }
        }
        _ => None,
    };
    let mut lines: Vec<Line> = Vec::with_capacity(rows as usize);
    for r in 0..rows {
        let mut spans: Vec<Span> = Vec::new();
        let mut text = String::new();
        let mut style: Option<Style> = None;
        for c in 0..cols {
            let Some(cell) = grid.cell(r, c) else {
                push_run(&mut spans, &mut text, &mut style, " ", Style::default());
                continue;
            };
            let mut s = cell_style(cell, def_fg, def_bg, &grid.ansi_palette);
            if let Some((lo, hi)) = sel_range {
                let idx = r as usize * cols as usize + c as usize;
                if idx >= lo && idx <= hi {
                    s = s.add_modifier(Modifier::REVERSED);
                }
            }
            let g: &str = if cell.text.is_empty() {
                " "
            } else {
                &cell.text
            };
            push_run(&mut spans, &mut text, &mut style, g, s);
        }
        if let Some(s) = style {
            spans.push(Span::styled(text, s));
        }
        lines.push(Line::from(spans));
    }
    frame.render_widget(Paragraph::new(lines), area);

    if exited && area.height >= 1 {
        // A thin banner on the bottom row so the user knows the child is gone.
        let banner = Rect::new(area.x, area.y + area.height - 1, area.width, 1);
        let t = theme::cur();
        // qa-feature 2026-07-01 — clickable `[×]` on the banner's
        // right edge as an alternative to Ctrl+W. Reserves 5 cells
        // for the button; label truncates if the pane is very narrow.
        let close_w: u16 = 5;
        let label_w = area.width.saturating_sub(close_w);
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                " [process exited — Ctrl+W to close] ",
                Style::default()
                    .fg(t.bg_darker)
                    .bg(t.red)
                    .add_modifier(Modifier::BOLD),
            ))),
            Rect::new(area.x, banner.y, label_w, 1),
        );
        if area.width >= close_w {
            let close_rect = Rect::new(area.x + area.width - close_w, banner.y, close_w, 1);
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    " [×] ",
                    Style::default()
                        .fg(t.bg_darker)
                        .bg(t.orange)
                        .add_modifier(Modifier::BOLD),
                ))),
                close_rect,
            );
            app.rects.pty_exit_close_buttons.push((close_rect, pane_id));
        }
    }

    app.rects.editor_panes.push((area, pane_id));

    // `grid.cursor` is `Some((col, row))` only when the cursor is visible and
    // in the live viewport (libghostty returns `None` while scrolled back).
    if focused
        && !exited
        && let Some((cc, cr)) = grid.cursor
    {
        let cx = area.x + cc.min(area.width.saturating_sub(1));
        let cy = area.y + cr.min(area.height.saturating_sub(1));
        return Some((cx, cy));
    }
    None
}

/// Paint the pty-session tab strip into `strip` (1 row). Lists every
/// `Pane::Pty` in the app — the one for `active_id` is highlighted —
/// then a `+` chip. Registers click rects on `app.rects.pty_tabs` /
/// `pty_tab_new`. Appends (the registries are cleared once per frame
/// in `ui::draw`) so multiple visible pty panes can each carry a strip.
fn draw_tab_strip(frame: &mut Frame, app: &mut App, active_id: PaneId, strip: Rect) {
    let t = theme::cur();
    let prefixes = &app.config.ui.ticket_prefixes;
    // 2026-06-27 #613 — scope the tab strip to the SPLIT containing
    // `active_id`. Previously this enumerated every Pty pane in
    // `app.panes` globally, so two splits each with one Pty viewer
    // showed "two tabs" in each strip — user-reported as "4 tabs"
    // confusion. Filter via Layout::leaf_containing so a Pty in
    // another split doesn't appear here.
    let leaf_tabs: Option<Vec<PaneId>> =
        app.layout().leaf_containing(active_id).map(|s| s.to_vec());
    let ptys: Vec<(PaneId, String, bool)> = app
        .panes
        .iter()
        .enumerate()
        .filter_map(|(id, p)| match p {
            Pane::Pty(s) => {
                let in_this_leaf = leaf_tabs.as_ref().map(|t| t.contains(&id)).unwrap_or(true);
                if !in_this_leaf {
                    return None;
                }
                Some((id, s.tab_label_with_prefixes(prefixes), s.is_exited()))
            }
            _ => None,
        })
        .collect();

    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_darker)),
        strip,
    );
    let mut spans: Vec<Span> = Vec::new();
    let mut x = strip.x;
    let right_limit = strip.x + strip.width;
    // 2026-06-25 — when there's only ONE Pty pane, the bufferline at
    // the very top already shows it as a tab, so this strip's label
    // would just duplicate that info ("phantom" tab). Skip the label
    // chips and only paint the `+ new session` chip (which the
    // bufferline's `+` can't substitute for — that one opens a file
    // tab, not a Pty session). When there are 2+ Ptys the strip
    // earns its row by acting as a session-switcher.
    let labels: &[(PaneId, String, bool)] = if ptys.len() >= 2 { &ptys } else { &[] };
    for (id, label, exited) in labels {
        // ` <label> × ` — chip body (label) + close badge. Truncate
        // long names so the strip stays tidy.
        let mut shown: String = label.chars().take(18).collect();
        if *exited {
            shown.push_str(" ✗");
        }
        let label_chip = format!(" {shown} ");
        let close_chip = "× ";
        let label_w = label_chip.chars().count() as u16;
        let close_w = close_chip.chars().count() as u16;
        let total_w = label_w + close_w;
        if x + total_w + 4 > right_limit {
            break; // out of room — drop the rest (rare; many ptys)
        }
        let is_active = *id == active_id;
        let (label_style, close_style) = if is_active {
            (
                Style::default()
                    .fg(t.bg_darker)
                    .bg(t.orange)
                    .add_modifier(Modifier::BOLD),
                Style::default().fg(t.bg_darker).bg(t.orange),
            )
        } else {
            (
                Style::default().fg(t.comment).bg(t.bg2),
                Style::default().fg(t.fg).bg(t.bg2),
            )
        };
        spans.push(Span::styled(label_chip, label_style));
        spans.push(Span::styled(close_chip, close_style));
        spans.push(Span::styled(" ", Style::default().bg(t.bg_darker)));
        // Tab-switch rect covers the label only — the close badge gets
        // its own rect so a click there kills the pane instead of
        // switching to it.
        app.rects.pty_tabs.push((
            Rect {
                x,
                y: strip.y,
                width: label_w,
                height: 1,
            },
            *id,
        ));
        app.rects.pty_tab_close.push((
            Rect {
                x: x + label_w,
                y: strip.y,
                width: close_w,
                height: 1,
            },
            *id,
        ));
        x += total_w + 1;
    }
    // qa-feature 2026-07-01 — only paint the `+ new session` chip
    // when the strip already has other tabs. The lone `+` above a
    // solo pty was misleading (nothing to switch to) and the user
    // asked for it removed. Spawning a new pty session is still
    // reachable via `:ai.claude_code` or the palette bar.
    if !labels.is_empty() && x + 3 <= right_limit {
        spans.push(Span::styled(
            " + ",
            Style::default()
                .fg(t.fg)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD),
        ));
        app.rects.pty_tab_new.push((
            Rect {
                x,
                y: strip.y,
                width: 3,
                height: 1,
            },
            active_id,
        ));
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), strip);
}

fn push_run(
    spans: &mut Vec<Span<'static>>,
    text: &mut String,
    style: &mut Option<Style>,
    g: &str,
    s: Style,
) {
    match style {
        Some(cur) if *cur == s => text.push_str(g),
        _ => {
            if let Some(cur) = style.take() {
                spans.push(Span::styled(std::mem::take(text), cur));
            }
            text.push_str(g);
            *style = Some(s);
        }
    }
}

fn cell_style(
    cell: &RenderCell,
    def_fg: Color,
    def_bg: Color,
    ansi_palette: &[Option<RgbColor>; 16],
) -> Style {
    // #17 — libghostty resolves palette-indexed colors to RGB
    // against its OWN default palette. Remap: if the cell's RGB
    // exactly matches one of the ANSI 0-15 palette slots we
    // snapshotted, swap for the mnml theme's equivalent color
    // so terminal colors respect the active theme.
    let remap = |c: Option<RgbColor>, def: Color| -> Color {
        let Some(rgb) = c else {
            return def;
        };
        for (idx, slot) in ansi_palette.iter().enumerate() {
            if let Some(pal) = slot
                && pal.r == rgb.r
                && pal.g == rgb.g
                && pal.b == rgb.b
            {
                return theme_ansi_color(idx as u8);
            }
        }
        Color::Rgb(rgb.r, rgb.g, rgb.b)
    };
    let mut fg = remap(cell.fg, def_fg);
    let mut bg = remap(cell.bg, def_bg);
    if cell.inverse {
        std::mem::swap(&mut fg, &mut bg);
    }
    let mut s = Style::default().fg(fg).bg(bg);
    if cell.bold {
        s = s.add_modifier(Modifier::BOLD);
    }
    if cell.italic {
        s = s.add_modifier(Modifier::ITALIC);
    }
    if cell.underline {
        s = s.add_modifier(Modifier::UNDERLINED);
    }
    s
}

/// #17 — map an ANSI 0-15 palette index to the mnml theme's
/// equivalent color slot. Standard convention:
/// 0/8 = black/grey, 1/9 = red, 2/10 = green, 3/11 = yellow,
/// 4/12 = blue, 5/13 = magenta, 6/14 = cyan, 7/15 = white.
fn theme_ansi_color(idx: u8) -> Color {
    let t = crate::ui::theme::cur();
    match idx {
        0 => t.bg,
        1 => t.red,
        2 => t.green,
        3 => t.yellow,
        4 => t.blue,
        5 => t.purple,
        6 => t.cyan,
        7 => t.fg,
        8 => t.grey_fg,
        9 => t.red,
        10 => t.green,
        11 => t.yellow,
        12 => t.blue,
        13 => t.purple,
        14 => t.cyan,
        _ => t.fg,
    }
}
