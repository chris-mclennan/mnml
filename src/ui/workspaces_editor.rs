//! Modal overlay for managing `[[workspaces]]` entries in the
//! global config. Opened from Settings → `Manage workspaces…`.
//!
//! Lists every configured workspace with name + path + group +
//! kebab. Click the kebab (or right-click the row) → context
//! menu with Edit name / Edit path / Edit group / Delete. The
//! `+ Add workspace…` row at the bottom opens the existing
//! AddWorkspace prompt.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Clear, Paragraph},
};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App) {
    app.rects.workspaces_editor_rows.clear();
    app.rects.workspaces_editor_kebabs.clear();
    if !app.workspaces_editor_open {
        return;
    }
    let t = theme::cur();
    let screen = frame.area();
    let max_label = app
        .config
        .workspaces
        .iter()
        .map(|w| w.name.chars().count())
        .max()
        .unwrap_or(16);
    let max_path = app
        .config
        .workspaces
        .iter()
        .map(|w| w.path.to_string_lossy().chars().count())
        .max()
        .unwrap_or(24);
    let max_group = app
        .config
        .workspaces
        .iter()
        .map(|w| w.group.as_deref().map(|s| s.chars().count()).unwrap_or(0))
        .max()
        .unwrap_or(8);

    let inner_w = (max_label + max_path + max_group + 16).clamp(48, 96) as u16;
    let inner_h = (app.config.workspaces.len() + 6) as u16;
    let w = inner_w.min(screen.width.saturating_sub(4));
    let h = inner_h.min(screen.height.saturating_sub(4));
    let x = (screen.width.saturating_sub(w)) / 2;
    let y = (screen.height.saturating_sub(h)) / 2;
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::modal_panel("Manage workspaces");
    let inner = block.inner(area);
    frame.render_widget(block, area);

    let mut y = inner.y;
    let name_padded_hdr = format!("{:<width$}", "Name", width = max_label);
    let path_padded_hdr = format!("{:<width$}", "Path", width = max_path);
    let hdr_style = Style::default()
        .fg(t.comment)
        .bg(t.bg2)
        .add_modifier(Modifier::BOLD);
    let header = Line::from(vec![
        Span::styled("   ", Style::default().bg(t.bg2)),
        Span::styled(name_padded_hdr, hdr_style),
        Span::styled("  ", Style::default().bg(t.bg2)),
        Span::styled(path_padded_hdr, hdr_style),
        Span::styled("  ", Style::default().bg(t.bg2)),
        Span::styled("Group", hdr_style),
    ]);
    frame.render_widget(
        Paragraph::new(header).style(Style::default().bg(t.bg2)),
        Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        },
    );
    y += 1;
    // 1-row separator.
    if y < inner.y + inner.height {
        let sep = Line::from(Span::styled(
            "─".repeat(inner.width as usize),
            Style::default().fg(t.line).bg(t.bg2),
        ));
        frame.render_widget(
            Paragraph::new(sep),
            Rect {
                x: inner.x,
                y,
                width: inner.width,
                height: 1,
            },
        );
        y += 1;
    }

    let sel = app.workspaces_editor_selected;
    // Which workspaces are currently loaded? Primary + extras. Compare
    // by canonicalized path so we don't miss ones opened via a symlink.
    let loaded_paths: std::collections::HashSet<std::path::PathBuf> = {
        let mut s = std::collections::HashSet::new();
        s.insert(std::fs::canonicalize(&app.workspace).unwrap_or_else(|_| app.workspace.clone()));
        for ws in &app.extra_workspaces {
            s.insert(std::fs::canonicalize(&ws.root).unwrap_or_else(|_| ws.root.clone()));
        }
        s
    };
    for (i, w) in app.config.workspaces.iter().enumerate() {
        if y >= inner.y + inner.height {
            break;
        }
        let is_sel = i == sel;
        let bg = if is_sel { t.cyan } else { t.bg2 };
        let fg = if is_sel { t.bg } else { t.fg };
        let is_open = loaded_paths
            .contains(&std::fs::canonicalize(&w.path).unwrap_or_else(|_| w.path.clone()));
        // `●` for open, `○` for available-but-not-loaded — same
        // visual language as the tree section headers so users
        // can tell at a glance which ones are currently mounted.
        let dot_glyph = if is_open { "●" } else { "○" };
        let dot_fg = if is_sel {
            t.bg
        } else if is_open {
            t.green
        } else {
            t.comment
        };
        let name_padded = format!("{:<width$}", w.name, width = max_label);
        let path_str = w.path.to_string_lossy();
        let path_padded = format!("{:<width$}", path_str, width = max_path);
        let group_str = w.group.clone().unwrap_or_default();
        let group_padded = format!("{:<width$}", group_str, width = max_group);
        // #polish — colorize the group column so scanning a long
        // list of workspaces reads faster. Selected rows keep the
        // inverted-selection fg; unselected rows pick a color from
        // the group name (stable hash).
        let group_fg = if is_sel {
            t.bg
        } else if group_str.is_empty() {
            t.comment
        } else {
            group_color_for(&group_str, t)
        };
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(dot_glyph, Style::default().fg(dot_fg).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(name_padded, Style::default().fg(fg).bg(bg)),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                path_padded,
                Style::default()
                    .fg(if is_sel { t.bg } else { t.comment })
                    .bg(bg),
            ),
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                group_padded,
                Style::default()
                    .fg(group_fg)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
        ]);
        let row_rect = Rect {
            x: inner.x,
            y,
            width: inner.width.saturating_sub(3),
            height: 1,
        };
        // Paragraph style sets the bg of untouched cells — without
        // this the row past the group column paints black (raw
        // terminal bg). Was the "black next to work/persona" bug.
        frame.render_widget(
            Paragraph::new(line).style(Style::default().bg(bg)),
            row_rect,
        );
        // Kebab cell at the right edge of the row.
        let kebab_rect = Rect {
            x: inner.x + inner.width - 2,
            y,
            width: 1,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "⋮",
                Style::default().fg(fg).bg(bg),
            )))
            .style(Style::default().bg(bg)),
            kebab_rect,
        );
        app.rects.workspaces_editor_rows.push((row_rect, i as i32));
        app.rects.workspaces_editor_kebabs.push((kebab_rect, i));
        y += 1;
    }

    // `+ Add workspace…` action row.
    if y < inner.y + inner.height {
        let is_sel = sel == app.config.workspaces.len();
        let bg = if is_sel { t.cyan } else { t.bg2 };
        let fg = if is_sel { t.bg } else { t.green };
        let line = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                "+ Add workspace…",
                Style::default().fg(fg).bg(bg).add_modifier(Modifier::BOLD),
            ),
        ]);
        let row_rect = Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(line).style(Style::default().bg(bg)),
            row_rect,
        );
        app.rects.workspaces_editor_rows.push((row_rect, -1));
        y += 1;
    }

    // Footer.
    if y < inner.y + inner.height {
        let footer = Line::from(vec![Span::styled(
            "  ↑↓ select · Shift+↑↓ reorder · Enter edit · n new · d delete · Esc close",
            Style::default().fg(t.comment).bg(t.bg2),
        )]);
        frame.render_widget(
            Paragraph::new(footer),
            Rect {
                x: inner.x,
                y: inner.y + inner.height - 1,
                width: inner.width,
                height: 1,
            },
        );
    }
}

/// #polish — deterministic color mapping for group names. Same
/// group name always gets the same color slot; different names
/// spread across the theme's accent palette (7 slots).
fn group_color_for(name: &str, t: crate::ui::theme::Theme) -> ratatui::style::Color {
    let mut hash: u32 = 5381;
    for b in name.bytes() {
        hash = hash.wrapping_mul(33).wrapping_add(b as u32);
    }
    match hash % 7 {
        0 => t.cyan,
        1 => t.blue,
        2 => t.green,
        3 => t.yellow,
        4 => t.orange,
        5 => t.purple,
        _ => t.red,
    }
}
