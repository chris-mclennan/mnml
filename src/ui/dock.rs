//! Renderer for `App::dock_widgets`. Paints each widget into a
//! corner of the editor body area, stacking inward when multiple
//! widgets share a corner.
//!
//! Slice 1 ships only `DockCorner::BottomLeft` painting + the
//! `DockContent::Text` variant + a close `×`. Other corners
//! match the same shape — the `corner_anchor_y` helper computes
//! the starting y per corner so adding them is a small follow-up.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph},
};

use crate::app::App;
use crate::dock::{DockContent, DockCorner, Layout as DockLayout, Opacity};
use crate::ui::theme;

/// Paint all dock widgets into the editor body area. Called from
/// `ui::draw` AFTER the editor / split tree paints, so the dock
/// chrome overlays the editor when they overlap.
pub fn draw(frame: &mut Frame, app: &mut App, editor_area: Rect) {
    app.rects.dock_widget_bodies.clear();
    app.rects.dock_widget_close_buttons.clear();
    app.rects.dock_widget_titles.clear();
    app.rects.dock_widget_kebabs.clear();
    app.rects.dock_empty_chip = None;
    if app.dock_widgets.is_empty() {
        // Empty-state discoverability chip — a faint `+ dock` at
        // the very bottom-right of the editor body. Click → open
        // the kebab-style new-widget picker (a stripped-down
        // menu with just the `Add` actions). Disappears the
        // moment any widget exists. Only render if there's
        // enough room AND no overlay is active that would
        // visually compete.
        if editor_area.width >= 14 && editor_area.height >= 2 {
            paint_empty_state_chip(frame, app, editor_area);
        }
        return;
    }
    if editor_area.width < 12 || editor_area.height < 4 {
        return;
    }
    let t = theme::cur();

    // ── Inline-mode widgets first: tile horizontally into the
    // top + bottom strips reserved by `ui::draw`. The editor
    // area parameter is ALREADY shrunk by these strips, so we
    // read the strips back from `app.rects`.
    let top_strip = app.rects.inline_dock_top_strip;
    let bottom_strip = app.rects.inline_dock_bottom_strip;
    paint_inline_strip(frame, app, top_strip, /*is_top=*/ true, t);
    paint_inline_strip(frame, app, bottom_strip, /*is_top=*/ false, t);

    // Group widgets by corner so we know how to stack inside each.
    // Iterate the four corners explicitly so painting order is
    // deterministic regardless of insertion order.
    for &corner in &[
        DockCorner::BottomLeft,
        DockCorner::BottomRight,
        DockCorner::TopLeft,
        DockCorner::TopRight,
    ] {
        paint_corner_stack(frame, app, editor_area, corner, t);
    }
    // Drop-zone preview during a dock drag — painted BEFORE the
    // kebab menu so an open menu still overlays it (drags don't
    // happen with a menu open anyway, but the layering is safer).
    paint_drag_preview(frame, app, editor_area, t);
    // Kebab menu — painted last so it overlays all widget chrome.
    paint_kebab_menu(frame, app, t);
}

fn paint_corner_stack(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    corner: DockCorner,
    t: crate::ui::theme::Theme,
) {
    // Collect widgets pinned to this corner, in the order they
    // were inserted. The order determines stack order: BottomLeft
    // stacks UPWARD (first widget sits at the very bottom),
    // TopLeft stacks DOWNWARD (first widget sits at the very top).
    let indexed: Vec<(usize, _)> = app
        .dock_widgets
        .iter()
        .enumerate()
        .filter(|(_, w)| {
            w.corner == corner && matches!(w.layout, crate::dock::Layout::Overlay)
        })
        .map(|(i, w)| (i, w.clone()))
        .collect();
    if indexed.is_empty() {
        return;
    }

    // Compute per-widget rect, then cap the total height per
    // corner to 50% of editor body so the stack can't smother
    // the editor underneath.
    let max_stack_h = area.height / 2;
    let mut painted_h: u16 = 0;
    // For bottom corners we stack from the bottom edge inward
    // (upward), so we iterate widgets in REVERSE so the
    // visually-topmost widget gets the last (smallest) y. For
    // top corners we stack downward, so iterate forward.
    let is_bottom = matches!(corner, DockCorner::BottomLeft | DockCorner::BottomRight);
    let order: Box<dyn Iterator<Item = &(usize, crate::dock::DockWidget)>> =
        if is_bottom {
            Box::new(indexed.iter().rev())
        } else {
            Box::new(indexed.iter())
        };

    for (_, w) in order {
        // Clamp the user's fractions to a sane range so a widget
        // is never unusably small or oversized.
        let w_frac = w.width_frac.clamp(0.15, 0.9);
        let h_frac = w.height_frac.clamp(0.15, 0.9);
        let widget_w = (area.width as f32 * w_frac) as u16;
        let widget_h = (area.height as f32 * h_frac) as u16;
        if widget_w < 8 || widget_h < 3 {
            continue;
        }
        // Skip if this widget would push the stack past 50%.
        if painted_h.saturating_add(widget_h) > max_stack_h {
            break;
        }

        // Position depends on corner. For bottom corners,
        // `painted_h` is the distance already consumed above the
        // bottom edge; the new widget sits with its bottom edge at
        // `area.y + area.height - painted_h - widget_h`.
        let (x, y) = match corner {
            DockCorner::BottomLeft => (
                area.x,
                area.y + area.height - painted_h - widget_h,
            ),
            DockCorner::BottomRight => (
                area.x + area.width - widget_w,
                area.y + area.height - painted_h - widget_h,
            ),
            DockCorner::TopLeft => (area.x, area.y + painted_h),
            DockCorner::TopRight => (
                area.x + area.width - widget_w,
                area.y + painted_h,
            ),
        };
        let widget_rect = Rect {
            x,
            y,
            width: widget_w,
            height: widget_h,
        };
        // Solid widgets get a Clear (wipes the editor cells
        // underneath) + a solid bg. Translucent widgets skip
        // the Clear so the editor text shows through the body;
        // border + title still get a bg so the chrome is
        // visible.
        let translucent = matches!(w.opacity, Opacity::Translucent);
        if !translucent {
            frame.render_widget(Clear, widget_rect);
        }

        // Block border + (maybe) bg.
        let block = if translucent {
            Block::default()
                .borders(Borders::ALL)
                .style(Style::default().fg(t.comment))
        } else {
            Block::default()
                .borders(Borders::ALL)
                .style(Style::default().fg(t.comment).bg(t.bg2))
        };
        let inner = block.inner(widget_rect);
        frame.render_widget(block, widget_rect);

        // Title bar (top row of inner area) + kebab `⋮` at the
        // rightmost cell. Close lives in the kebab menu now.
        if inner.width > 4 {
            // Widget being dragged → highlight the title bar with
            // an accent bg so the user knows the press registered
            // and mouse-up will move it.
            let is_dragging = app.dock_drag_id == Some(w.id);
            let title_bg = if is_dragging { t.cyan } else { t.bg2 };
            let title_fg = if is_dragging { t.bg } else { t.fg };
            let kebab_glyph = "⋮";
            let drag_hint = if is_dragging { " ⇲ " } else { "" };
            let title_w = inner.width.saturating_sub(2 + drag_hint.chars().count() as u16);
            let title_clipped: String = w.title.chars().take(title_w as usize).collect();
            let pad = (title_w as usize).saturating_sub(title_clipped.chars().count());
            let title_line = Line::from(vec![
                Span::styled(
                    title_clipped,
                    Style::default()
                        .fg(title_fg)
                        .bg(title_bg)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(" ".repeat(pad), Style::default().bg(title_bg)),
                Span::styled(drag_hint, Style::default().fg(title_fg).bg(title_bg)),
                Span::styled(
                    kebab_glyph,
                    Style::default().fg(title_fg).bg(title_bg),
                ),
                Span::styled(" ", Style::default().bg(title_bg)),
            ]);
            let title_rect = Rect {
                x: inner.x,
                y: inner.y,
                width: inner.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(title_line), title_rect);
            // Kebab `⋮` click rect — the rightmost 1 cell.
            let kebab_rect = Rect {
                x: inner.x + inner.width - 2,
                y: inner.y,
                width: 1,
                height: 1,
            };
            app.rects.dock_widget_kebabs.push((kebab_rect, w.id));
            // Title-bar drag-anchor rect — everything EXCEPT the
            // kebab glyph.
            let title_drag_rect = Rect {
                x: inner.x,
                y: inner.y,
                width: inner.width.saturating_sub(2),
                height: 1,
            };
            app.rects.dock_widget_titles.push((title_drag_rect, w.id));
        }

        // Body content (inner minus title row).
        if inner.height >= 2 {
            let body_rect = Rect {
                x: inner.x,
                y: inner.y + 1,
                width: inner.width,
                height: inner.height - 1,
            };
            match &w.content {
                DockContent::Text(s) => {
                    render_text_body(frame, body_rect, s, t);
                }
                DockContent::LogTail { path, max_lines } => {
                    render_log_tail_body(frame, body_rect, path, *max_lines, t);
                }
            }
            app.rects.dock_widget_bodies.push((body_rect, w.id));
        }

        painted_h = painted_h.saturating_add(widget_h);
    }
}

/// Tile inline widgets horizontally across `strip`. `is_top`
/// controls source ordering: top widgets are TL→TR (left→right by
/// corner, then by insertion); bottom widgets are BL→BR.
fn paint_inline_strip(
    frame: &mut Frame,
    app: &mut App,
    strip: Option<Rect>,
    is_top: bool,
    t: crate::ui::theme::Theme,
) {
    let Some(strip) = strip else {
        return;
    };
    // Collect inline widgets for this edge, in insertion order
    // within each corner. Left corner first → right corner
    // second, so widths-frac-of-editor lines up with corner
    // intent.
    let (left_corner, right_corner) = if is_top {
        (DockCorner::TopLeft, DockCorner::TopRight)
    } else {
        (DockCorner::BottomLeft, DockCorner::BottomRight)
    };
    let mut ordered: Vec<crate::dock::DockWidget> = Vec::new();
    for w in &app.dock_widgets {
        if matches!(w.layout, crate::dock::Layout::Inline) && w.corner == left_corner {
            ordered.push(w.clone());
        }
    }
    for w in &app.dock_widgets {
        if matches!(w.layout, crate::dock::Layout::Inline) && w.corner == right_corner {
            ordered.push(w.clone());
        }
    }
    if ordered.is_empty() {
        return;
    }
    // Tile left-to-right. Each widget gets its own
    // `width_frac × editor_width` slice; if their summed widths
    // exceed the strip, later widgets are dropped (rule we
    // settled on: first inline at this edge wins; subsequent
    // ones silently overflow).
    let strip_w = strip.width;
    let mut cur_x = strip.x;
    for w in &ordered {
        let w_frac = w.width_frac.clamp(0.15, 0.9);
        let widget_w = (strip_w as f32 * w_frac) as u16;
        if widget_w < 8 {
            continue;
        }
        if cur_x + widget_w > strip.x + strip.width {
            // Out of room — skip silently.
            break;
        }
        let widget_rect = Rect {
            x: cur_x,
            y: strip.y,
            width: widget_w,
            height: strip.height,
        };
        paint_one_widget(frame, app, w, widget_rect, t);
        cur_x += widget_w;
    }
}

/// Extracted single-widget paint so `paint_corner_stack` and
/// `paint_inline_strip` share the chrome / body code.
fn paint_one_widget(
    frame: &mut Frame,
    app: &mut App,
    w: &crate::dock::DockWidget,
    widget_rect: Rect,
    t: crate::ui::theme::Theme,
) {
    let translucent = matches!(w.opacity, Opacity::Translucent);
    if !translucent {
        frame.render_widget(Clear, widget_rect);
    }
    let block = if translucent {
        Block::default()
            .borders(Borders::ALL)
            .style(Style::default().fg(t.comment))
    } else {
        Block::default()
            .borders(Borders::ALL)
            .style(Style::default().fg(t.comment).bg(t.bg2))
    };
    let inner = block.inner(widget_rect);
    frame.render_widget(block, widget_rect);
    // Title + kebab.
    if inner.width > 4 {
        let is_dragging = app.dock_drag_id == Some(w.id);
        let title_bg = if is_dragging { t.cyan } else { t.bg2 };
        let title_fg = if is_dragging { t.bg } else { t.fg };
        let kebab_glyph = "⋮";
        let drag_hint = if is_dragging { " ⇲ " } else { "" };
        // Live-content tail-indicator chip — only meaningful for
        // content variants whose data CAN exceed the visible
        // body (LogTail today; future ClaudeTail / BuildStatus
        // will opt in by reporting their own "lines below").
        let tail_hint = match &w.content {
            DockContent::LogTail { path, .. } => {
                let body_h = inner.height.saturating_sub(1).max(1) as usize;
                let total = std::fs::read_to_string(path)
                    .map(|s| s.lines().count())
                    .unwrap_or(0);
                if total > body_h {
                    let hidden = total - body_h;
                    Some(format!(" ▼{hidden} "))
                } else {
                    None
                }
            }
            DockContent::Text(_) => None,
        };
        let tail_hint_str = tail_hint.as_deref().unwrap_or("");
        let title_w = inner.width.saturating_sub(
            2 + drag_hint.chars().count() as u16 + tail_hint_str.chars().count() as u16,
        );
        let title_clipped: String = w.title.chars().take(title_w as usize).collect();
        let pad = (title_w as usize).saturating_sub(title_clipped.chars().count());
        let title_line = Line::from(vec![
            Span::styled(
                title_clipped,
                Style::default()
                    .fg(title_fg)
                    .bg(title_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ".repeat(pad), Style::default().bg(title_bg)),
            Span::styled(
                tail_hint_str.to_string(),
                Style::default().fg(t.comment).bg(title_bg),
            ),
            Span::styled(drag_hint, Style::default().fg(title_fg).bg(title_bg)),
            Span::styled(kebab_glyph, Style::default().fg(title_fg).bg(title_bg)),
            Span::styled(" ", Style::default().bg(title_bg)),
        ]);
        let title_rect = Rect {
            x: inner.x,
            y: inner.y,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(Paragraph::new(title_line), title_rect);
        let kebab_rect = Rect {
            x: inner.x + inner.width - 2,
            y: inner.y,
            width: 1,
            height: 1,
        };
        app.rects.dock_widget_kebabs.push((kebab_rect, w.id));
        let title_drag_rect = Rect {
            x: inner.x,
            y: inner.y,
            width: inner.width.saturating_sub(2),
            height: 1,
        };
        app.rects.dock_widget_titles.push((title_drag_rect, w.id));
    }
    if inner.height >= 2 {
        let body_rect = Rect {
            x: inner.x,
            y: inner.y + 1,
            width: inner.width,
            height: inner.height - 1,
        };
        match &w.content {
            DockContent::Text(s) => render_text_body(frame, body_rect, s, t),
            DockContent::LogTail { path, max_lines } => {
                render_log_tail_body(frame, body_rect, path, *max_lines, t)
            }
        }
        app.rects.dock_widget_bodies.push((body_rect, w.id));
    }
}

/// While a dock widget is being dragged, paint:
///   - a translucent gray overlay over the quadrant the cursor
///     is currently in (where the widget will pin on release),
///   - a small ghost chip near the cursor showing the title.
fn paint_drag_preview(
    frame: &mut Frame,
    app: &mut App,
    editor_area: Rect,
    t: crate::ui::theme::Theme,
) {
    let Some(drag_id) = app.dock_drag_id else {
        return;
    };
    let Some((cx, cy)) = app.dock_drag_cursor else {
        return;
    };
    // Look up the title for the ghost chip.
    let title = match app.dock_widgets.iter().find(|w| w.id == drag_id) {
        Some(w) => w.title.clone(),
        None => return,
    };
    if editor_area.width < 4 || editor_area.height < 4 {
        return;
    }

    // Resolve cursor → quadrant.
    let mid_x = editor_area.x + editor_area.width / 2;
    let mid_y = editor_area.y + editor_area.height / 2;
    let (qx, qy, qw, qh) = match (cx < mid_x, cy < mid_y) {
        // TopLeft
        (true, true) => (
            editor_area.x,
            editor_area.y,
            editor_area.width / 2,
            editor_area.height / 2,
        ),
        // TopRight
        (false, true) => (
            mid_x,
            editor_area.y,
            editor_area.x + editor_area.width - mid_x,
            editor_area.height / 2,
        ),
        // BottomLeft
        (true, false) => (
            editor_area.x,
            mid_y,
            editor_area.width / 2,
            editor_area.y + editor_area.height - mid_y,
        ),
        // BottomRight
        (false, false) => (
            mid_x,
            mid_y,
            editor_area.x + editor_area.width - mid_x,
            editor_area.y + editor_area.height - mid_y,
        ),
    };
    let drop_rect = Rect {
        x: qx,
        y: qy,
        width: qw,
        height: qh,
    };
    // Translucent-ish gray fill — terminals can't do alpha so we
    // approximate by overpainting each cell with a single
    // shaded glyph + dim fg. This signals "drop zone" without
    // hiding what's underneath.
    let shade_style = Style::default().fg(t.comment).bg(t.bg_dark);
    for row in 0..drop_rect.height {
        let y = drop_rect.y + row;
        let line = Line::from(Span::styled(
            "░".repeat(drop_rect.width as usize),
            shade_style,
        ));
        frame.render_widget(
            Paragraph::new(line),
            Rect {
                x: drop_rect.x,
                y,
                width: drop_rect.width,
                height: 1,
            },
        );
    }
    // Corner-label so the user can tell which quadrant they're
    // targeting (handy when dragging across a busy split tree).
    let corner_label = match (cx < mid_x, cy < mid_y) {
        (true, true) => " ⤴ Top-left ",
        (false, true) => " ⤵ Top-right ",
        (true, false) => " ⤷ Bottom-left ",
        (false, false) => " ⤶ Bottom-right ",
    };
    let label_w = corner_label.chars().count() as u16;
    if drop_rect.width > label_w + 2 && drop_rect.height >= 1 {
        let label_rect = Rect {
            x: drop_rect.x + (drop_rect.width - label_w) / 2,
            y: drop_rect.y + drop_rect.height / 2,
            width: label_w,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                corner_label,
                Style::default()
                    .fg(t.fg)
                    .bg(t.bg2)
                    .add_modifier(Modifier::BOLD),
            ))),
            label_rect,
        );
    }
    // Ghost chip near the cursor — `⇲ <title>` so the user sees
    // what they're carrying. Offset 1 cell so it doesn't cover
    // the cursor itself.
    let chip_label = format!(" ⇲ {title} ");
    let chip_w = chip_label.chars().count() as u16;
    let chip_x = (cx + 2).min(editor_area.x + editor_area.width.saturating_sub(chip_w));
    let chip_y = cy.saturating_sub(1).max(editor_area.y);
    let chip_rect = Rect {
        x: chip_x,
        y: chip_y,
        width: chip_w.min(editor_area.width),
        height: 1,
    };
    frame.render_widget(Clear, chip_rect);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            chip_label,
            Style::default()
                .fg(t.bg)
                .bg(t.cyan)
                .add_modifier(Modifier::BOLD),
        ))),
        chip_rect,
    );
}

/// Paint the empty-state discoverability chip — a faint
/// `+ dock` at the bottom-right of the editor body. Click target
/// stored in `app.rects.dock_empty_chip` so the mouse handler
/// can fire `dock.new_text`.
fn paint_empty_state_chip(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let label = " + dock ";
    let lw = label.chars().count() as u16;
    if area.width <= lw + 2 {
        return;
    }
    let chip_rect = Rect {
        x: area.x + area.width - lw - 1,
        y: area.y + area.height - 1,
        width: lw,
        height: 1,
    };
    let line = Line::from(Span::styled(
        label,
        Style::default().fg(t.comment).bg(t.bg2),
    ));
    frame.render_widget(Paragraph::new(line), chip_rect);
    app.rects.dock_empty_chip = Some(chip_rect);
}

/// Paint the open kebab menu (if any). Anchored below the `⋮`
/// glyph that opened it; clamped to screen edges.
fn paint_kebab_menu(frame: &mut Frame, app: &mut App, t: crate::ui::theme::Theme) {
    app.rects.dock_kebab_rows = Vec::new();
    let Some(menu) = app.dock_kebab_menu.as_ref() else {
        return;
    };
    // Look up the widget so we can mark current values in the menu
    // (e.g. the active Layout / Opacity).
    let cur_layout = app
        .dock_widgets
        .iter()
        .find(|w| w.id == menu.widget_id)
        .map(|w| w.layout);
    let cur_opacity = app
        .dock_widgets
        .iter()
        .find(|w| w.id == menu.widget_id)
        .map(|w| w.opacity);
    let cur_corner = app
        .dock_widgets
        .iter()
        .find(|w| w.id == menu.widget_id)
        .map(|w| w.corner);

    // Compute panel dimensions.
    let max_label = 22u16; // widest item label (incl. "Inline (eats space)")
    let w = max_label + 4;
    let body_rows = menu.items.len() as u16;
    let h = body_rows + 2; // borders
    let screen = frame.area();
    // Don't paint over the statusline / cmdline strip at the
    // bottom — clamp to the statusline's top y if known. Falls
    // back to screen height - 1 if the statusline rect isn't
    // available yet.
    let bottom_limit = app
        .rects
        .statusline
        .map(|r| r.y)
        .unwrap_or_else(|| screen.y + screen.height.saturating_sub(1));
    let x = menu
        .anchor_x
        .saturating_sub(w / 2)
        .min(screen.x + screen.width.saturating_sub(w));
    let preferred_y = menu.anchor_y + 1;
    // If the menu would extend past the bottom limit, flip it
    // ABOVE the anchor (drop-up). Otherwise drop-down as usual.
    let y = if preferred_y + h > bottom_limit {
        menu.anchor_y.saturating_sub(h).max(screen.y)
    } else {
        preferred_y
    };
    let area = Rect {
        x,
        y,
        width: w.min(screen.width),
        height: h.min(screen.height),
    };
    frame.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let mut y = inner.y;
    let mut item_rects: Vec<(Rect, usize)> = Vec::new();
    for (idx, item) in menu.items.iter().enumerate() {
        if y >= inner.y + inner.height {
            break;
        }
        let is_selected = idx == menu.selected;
        let row_rect = Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        };
        // Selection style: bright cyan bg + dark fg + BOLD reads
        // strongly against `t.bg2`. The earlier "cyan bg + t.fg"
        // washed out because `t.fg` is light on light cyan.
        let sel_bg = t.cyan;
        let sel_fg = t.bg;
        let sel_mod = Modifier::BOLD;
        let (text, fg, bg, indent, modifier) = match item {
            crate::dock::KebabMenuItem::Header(h) => (
                h.to_string(),
                t.comment,
                t.bg2,
                "",
                Modifier::BOLD,
            ),
            crate::dock::KebabMenuItem::Separator => (
                "─".repeat(inner.width as usize),
                t.comment,
                t.bg2,
                "",
                Modifier::empty(),
            ),
            crate::dock::KebabMenuItem::Resize(p) => (
                p.label().to_string(),
                if is_selected { sel_fg } else { t.fg },
                if is_selected { sel_bg } else { t.bg2 },
                "  ",
                if is_selected { sel_mod } else { Modifier::empty() },
            ),
            crate::dock::KebabMenuItem::MoveTo(c) => {
                let label = match c {
                    DockCorner::BottomLeft => "Bottom-left",
                    DockCorner::BottomRight => "Bottom-right",
                    DockCorner::TopLeft => "Top-left",
                    DockCorner::TopRight => "Top-right",
                };
                let marker = if cur_corner == Some(*c) { "● " } else { "  " };
                (
                    format!("{marker}{label}"),
                    if is_selected { sel_fg } else { t.fg },
                    if is_selected { sel_bg } else { t.bg2 },
                    "",
                    if is_selected { sel_mod } else { Modifier::empty() },
                )
            }
            crate::dock::KebabMenuItem::SetLayout(l) => {
                let label = match l {
                    DockLayout::Overlay => "Overlay",
                    DockLayout::Inline => "Inline (eats space)",
                };
                let marker = if cur_layout == Some(*l) { "● " } else { "  " };
                (
                    format!("{marker}{label}"),
                    if is_selected { sel_fg } else { t.fg },
                    if is_selected { sel_bg } else { t.bg2 },
                    "",
                    if is_selected { sel_mod } else { Modifier::empty() },
                )
            }
            crate::dock::KebabMenuItem::SetOpacity(o) => {
                let label = match o {
                    Opacity::Solid => "Solid",
                    Opacity::Translucent => "Translucent",
                };
                let marker = if cur_opacity == Some(*o) { "● " } else { "  " };
                (
                    format!("{marker}{label}"),
                    if is_selected { sel_fg } else { t.fg },
                    if is_selected { sel_bg } else { t.bg2 },
                    "",
                    if is_selected { sel_mod } else { Modifier::empty() },
                )
            }
            crate::dock::KebabMenuItem::Rename => (
                "Rename…".to_string(),
                if is_selected { sel_fg } else { t.fg },
                if is_selected { sel_bg } else { t.bg2 },
                "  ",
                if is_selected { sel_mod } else { Modifier::empty() },
            ),
            crate::dock::KebabMenuItem::Close => (
                "Close".to_string(),
                if is_selected { sel_fg } else { t.red },
                if is_selected { sel_bg } else { t.bg2 },
                "  ",
                if is_selected { sel_mod } else { Modifier::empty() },
            ),
        };
        // Right-pad the row so the bg fills the full menu width
        // (otherwise the selection highlight stops at the end of
        // the text and looks like a stub).
        let text_w = indent.chars().count() + text.chars().count();
        let pad = (inner.width as usize).saturating_sub(text_w);
        let line = Line::from(vec![
            Span::styled(indent.to_string(), Style::default().bg(bg)),
            Span::styled(text, Style::default().fg(fg).bg(bg).add_modifier(modifier)),
            Span::styled(" ".repeat(pad), Style::default().bg(bg)),
        ]);
        frame.render_widget(Paragraph::new(line), row_rect);
        // Only register click rects for selectable items.
        if !matches!(
            item,
            crate::dock::KebabMenuItem::Header(_) | crate::dock::KebabMenuItem::Separator
        ) {
            item_rects.push((row_rect, idx));
        }
        y += 1;
    }
    app.rects.dock_kebab_rows = item_rects;
}

/// Render static text into the widget's body. Naive char-boundary
/// line-wrap; long single words just clip at the right edge. Good
/// enough for v1 — proper word-wrap can land later.
fn render_text_body(
    frame: &mut Frame,
    body_rect: Rect,
    text: &str,
    t: crate::ui::theme::Theme,
) {
    let mut lines: Vec<Line> = Vec::with_capacity(body_rect.height as usize);
    let max_w = body_rect.width as usize;
    for raw in text.lines() {
        let mut remaining = raw;
        while !remaining.is_empty() && lines.len() < body_rect.height as usize {
            let take = remaining.chars().take(max_w).collect::<String>();
            let take_len = take.chars().count();
            lines.push(Line::from(Span::styled(
                take,
                Style::default().fg(t.fg).bg(t.bg2),
            )));
            remaining = remaining
                .char_indices()
                .nth(take_len)
                .map(|(idx, _)| &remaining[idx..])
                .unwrap_or("");
        }
        if lines.len() >= body_rect.height as usize {
            break;
        }
    }
    frame.render_widget(Paragraph::new(lines), body_rect);
}

/// Render the last `max_lines` rows of `path` into the body. Re-
/// reads the file every frame; sufficient for the small log
/// tails this widget targets (tests + build output + AI session
/// jsonl), and avoids the complexity of mtime caching.
///
/// Empty / missing file → render a dim placeholder.
fn render_log_tail_body(
    frame: &mut Frame,
    body_rect: Rect,
    path: &std::path::Path,
    max_lines: usize,
    t: crate::ui::theme::Theme,
) {
    let max_w = body_rect.width as usize;
    let max_h = body_rect.height as usize;
    let take_n = max_lines.min(max_h);

    let mut lines_out: Vec<Line> = Vec::with_capacity(take_n);
    match std::fs::read_to_string(path) {
        Ok(s) => {
            let all_lines: Vec<&str> = s.lines().collect();
            let start = all_lines.len().saturating_sub(take_n);
            for raw in &all_lines[start..] {
                // Truncate to width — log tails are usually long-
                // line stdout; wrapping wastes vertical space.
                let display: String = raw.chars().take(max_w).collect();
                lines_out.push(Line::from(Span::styled(
                    display,
                    Style::default().fg(t.fg).bg(t.bg2),
                )));
            }
        }
        Err(_) => {
            // File missing / unreadable — show the path so the
            // user knows what we tried to open.
            let display: String = format!("(no file: {})", path.display())
                .chars()
                .take(max_w)
                .collect();
            lines_out.push(Line::from(Span::styled(
                display,
                Style::default().fg(t.comment).bg(t.bg2),
            )));
        }
    }
    frame.render_widget(Paragraph::new(lines_out), body_rect);
}
