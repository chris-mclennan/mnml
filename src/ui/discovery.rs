//! F1 discovery overlay — a centered floating panel listing every clickable
//! region category with live counts. Click a row to flash the matching
//! on-screen rects for ~2 seconds; the overlay becomes a "show me where"
//! guide instead of a passive list.
//!
//! Toggle with F1 (also `view.discovery`); Esc dismisses.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::DiscoveryCategory;
use crate::app::{App, DISCOVERY_FLASH_MS};
use crate::ui::theme;

/// `(category, label, detail, on-screen-rect-count)` tuples — single source of
/// truth so `draw()` and the click handler match.
fn rows(app: &App) -> Vec<(DiscoveryCategory, &'static str, &'static str, usize)> {
    use DiscoveryCategory::*;
    vec![
        (
            StatuslineMode,
            "Mode chip",
            "click: toggle vim/standard · right: input menu",
            usize::from(app.rects.statusline_mode_chip.is_some()),
        ),
        (
            StatuslineBranch,
            "Branch chip",
            "click: commit graph · right: git ops menu",
            usize::from(app.rects.statusline_branch_chip.is_some()),
        ),
        (
            StatuslineWorkspace,
            "Workspace chip",
            "click: switch repo · right: workspace menu",
            usize::from(app.rects.statusline_workspace_chip.is_some()),
        ),
        (
            StatuslineClock,
            "Clock chip",
            "click: local↔UTC · right: clock menu",
            usize::from(app.rects.statusline_clock_chip.is_some()),
        ),
        (
            BufferlineTabs,
            "Bufferline tabs",
            "click: focus · middle: close · right: tab menu",
            app.rects.bufferline_tabs.len(),
        ),
        (
            RailGitHeader,
            "> GIT rail header",
            "Fetch / Pull / Push / Stage all / Commit / Graph",
            app.rects.rail_git_header_buttons.len(),
        ),
        (
            EditorGutter,
            "Editor gutter",
            "right-click line: breakpoint / goto def / refs / blame…",
            app.rects.editor_gutters.len(),
        ),
        (
            DiffToolbar,
            "Diff toolbar",
            "Hunk / Inline / Split / Wrap / Close chips",
            app.rects.diff_toolbar_buttons.len(),
        ),
        (
            FoldChips,
            "Fold chips (⋯)",
            "click to expand the folded block",
            app.rects.fold_chips.len(),
        ),
        (
            CodeLensChips,
            "Code-lens chips (⚡)",
            "click to run the lens command",
            app.rects.code_lens_chips.len(),
        ),
        (
            SplitDividers,
            "Split dividers",
            "hover turns yellow · drag to resize",
            app.rects.split_dividers.len(),
        ),
    ]
}

/// Render the overlay if toggled on. Per-row rect tracking lets the click
/// dispatcher flash matching on-screen rects when a row is picked.
pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    if !app.show_discovery_overlay {
        app.rects.discovery_rows.clear();
        return;
    }
    let t = theme::cur();
    let rows = rows(app);

    let title = " Click Discovery — F1 / Esc to close · click row to flash ";
    let inner_w = rows
        .iter()
        .map(|(_, label, detail, _)| label.chars().count() + 2 + detail.chars().count() + 6)
        .max()
        .unwrap_or(50)
        .max(title.chars().count() + 4);
    let w = (inner_w as u16 + 4).min(screen.width);
    let h = (rows.len() as u16 + 2 + 2).min(screen.height);
    let x = screen
        .x
        .saturating_add((screen.width.saturating_sub(w)) / 2);
    let y = screen
        .y
        .saturating_add((screen.height.saturating_sub(h)) / 3);
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);

    // Pre-register the per-row click rects (each row is one terminal cell tall,
    // inside the bordered block — borders eat 1 cell on each side, plus we
    // leave a 1-cell gap at the bottom for the legend).
    app.rects.discovery_rows.clear();
    let inner_x = area.x + 1;
    let inner_w_cells = area.width.saturating_sub(2);
    for (i, (cat, _, _, _)) in rows.iter().enumerate() {
        let row_y = area.y + 1 + i as u16;
        if row_y >= area.y + area.height.saturating_sub(2) {
            break;
        }
        app.rects.discovery_rows.push((
            Rect {
                x: inner_x,
                y: row_y,
                width: inner_w_cells,
                height: 1,
            },
            *cat,
        ));
    }

    let block = Block::default()
        .borders(Borders::ALL)
        .title(Span::styled(
            title,
            Style::default()
                .fg(t.bg_darker)
                .bg(t.yellow)
                .add_modifier(Modifier::BOLD),
        ))
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let mut lines: Vec<Line<'static>> = Vec::with_capacity(rows.len() + 1);
    let active_flash = app
        .discovery_flash
        .filter(|(_, since)| since.elapsed().as_millis() < DISCOVERY_FLASH_MS as u128)
        .map(|(c, _)| c);
    for (cat, label, detail, count) in rows.iter() {
        let live = *count > 0;
        let is_flashing = active_flash == Some(*cat);
        let count_chip = if live {
            format!("[{count}]")
        } else {
            "[ ]".into()
        };
        let count_style = if is_flashing {
            Style::default()
                .fg(t.bg_darker)
                .bg(t.yellow)
                .add_modifier(Modifier::BOLD)
        } else if live {
            Style::default()
                .fg(t.bg_darker)
                .bg(t.green)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg2)
        };
        let label_style = if is_flashing {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED)
        } else if live {
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment)
        };
        let detail_style = if live {
            Style::default().fg(t.comment)
        } else {
            Style::default().fg(t.bg3)
        };
        let spans = vec![
            Span::styled(" ", Style::default().bg(t.bg2)),
            Span::styled(count_chip, count_style),
            Span::styled("  ", Style::default().bg(t.bg2)),
            Span::styled(label.to_string(), label_style),
            Span::styled("  ", Style::default().bg(t.bg2)),
            Span::styled(detail.to_string(), detail_style),
        ];
        lines.push(Line::from(spans));
    }
    lines.push(Line::from(Span::styled(
        " green count = visible now · click row to flash rects ".to_string(),
        Style::default()
            .fg(t.comment)
            .bg(t.bg2)
            .add_modifier(Modifier::ITALIC),
    )));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

/// Paint a yellow border on every on-screen rect matching the active
/// flash category. Called from `ui::draw` AFTER the rest of the UI so
/// the highlight sits on top of everything (including the discovery
/// panel — flashing a hidden chip would be pointless, so the highlight
/// can overlap the panel without harm).
pub fn draw_flash(frame: &mut Frame, app: &App, _screen: Rect) {
    let Some((cat, since)) = app.discovery_flash else {
        return;
    };
    if since.elapsed().as_millis() >= DISCOVERY_FLASH_MS as u128 {
        return;
    }
    let t = theme::cur();
    let highlight = Style::default()
        .fg(t.bg_darker)
        .bg(t.yellow)
        .add_modifier(Modifier::BOLD);
    // Gather every rect that belongs to the active category.
    let mut targets: Vec<Rect> = Vec::new();
    use DiscoveryCategory::*;
    match cat {
        StatuslineMode => targets.extend(app.rects.statusline_mode_chip),
        StatuslineBranch => targets.extend(app.rects.statusline_branch_chip),
        StatuslineWorkspace => targets.extend(app.rects.statusline_workspace_chip),
        StatuslineClock => targets.extend(app.rects.statusline_clock_chip),
        BufferlineTabs => targets.extend(app.rects.bufferline_tabs.iter().map(|(r, _)| *r)),
        RailGitHeader => {
            targets.extend(app.rects.rail_git_header_buttons.iter().map(|(r, _)| *r))
        }
        EditorGutter => targets.extend(app.rects.editor_gutters.iter().map(|(r, _)| *r)),
        DiffToolbar => targets.extend(app.rects.diff_toolbar_buttons.iter().map(|(r, _, _)| *r)),
        FoldChips => targets.extend(app.rects.fold_chips.iter().map(|(r, _, _)| *r)),
        CodeLensChips => targets.extend(app.rects.code_lens_chips.iter().map(|(r, _, _)| *r)),
        SplitDividers => targets.extend(app.rects.split_dividers.iter().map(|d| d.rect)),
    }
    for r in targets {
        if r.width == 0 || r.height == 0 {
            continue;
        }
        // Paint a yellow band over the rect — visible against any
        // background, and big enough that the eye lands on it without
        // visual hunting.
        frame.render_widget(Clear, r);
        frame.render_widget(
            Paragraph::new(Span::styled(
                " ".repeat(r.width as usize),
                highlight,
            )),
            r,
        );
    }
}
