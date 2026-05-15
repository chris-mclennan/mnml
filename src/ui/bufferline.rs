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

use std::collections::HashMap;

use crate::app::App;
use crate::pane::Pane;
use crate::ui::{icons, theme};

/// `✗N` (errors) / `⚠N` (warnings) / `""` for editor panes; `""` for everything
/// else. Surfaced in the bufferline so broken buffers are visible without
/// switching to them.
fn diag_chip_for(p: &Pane) -> String {
    if let Pane::Editor(b) = p {
        let mut err = 0usize;
        let mut warn = 0usize;
        for d in &b.diagnostics {
            match d.severity {
                crate::lsp::Severity::Error => err += 1,
                crate::lsp::Severity::Warning => warn += 1,
                _ => {}
            }
        }
        if err > 0 {
            return format!("\u{2717}{err}");
        }
        if warn > 0 {
            return format!("\u{26A0}{warn}");
        }
    }
    String::new()
}

/// One label per pane in `app.panes`, in order. For editor panes whose bare
/// filename is shared with another open editor (e.g. five `mod.rs`), prepend
/// the immediate parent dir (`git/mod.rs`, `ai/mod.rs`) so the tabs are
/// distinguishable. Non-editor panes keep their original title.
fn tab_labels(panes: &[Pane]) -> Vec<String> {
    let mut name_counts: HashMap<String, usize> = HashMap::new();
    let mut titles: Vec<String> = Vec::with_capacity(panes.len());
    for p in panes {
        let t = p.title();
        titles.push(t.clone());
        if matches!(p, Pane::Editor(_)) {
            *name_counts.entry(t).or_default() += 1;
        }
    }
    for (i, p) in panes.iter().enumerate() {
        if let Pane::Editor(b) = p
            && let Some(path) = &b.path
            && name_counts.get(&titles[i]).copied().unwrap_or(0) > 1
            && let Some(parent) = path
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
        {
            titles[i] = format!("{parent}/{}", titles[i]);
        }
    }
    titles
}

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::cur().bg_darker)),
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

    // Disambiguated labels — when two open editors share a filename, prepend
    // the parent dir to both (`git/mod.rs` vs `ai/mod.rs`).
    let labels = tab_labels(&app.panes);
    // Per-tab diagnostic chip — `✗N` for any errors, else `⚠N` for warnings,
    // else empty. Surfaced so the user sees broken buffers without opening
    // them. The chip sits between the name and the dirty badge.
    let diag_chips: Vec<String> = app.panes.iter().map(diag_chip_for).collect();
    // Pre-compute each tab's display width so we can scroll the bufferline to
    // keep the active tab on screen (and show `‹`/`›` overflow indicators).
    // Each tab is ` <icon> <name>[ <diag>] <badge> ` — base chrome is 4 cells
    // + name; diag chip (if any) adds its own char count + a leading space.
    let widths: Vec<u16> = labels
        .iter()
        .zip(&diag_chips)
        .map(|(name, diag)| {
            let mut w = 4u16 + name.chars().count() as u16 + 1u16;
            if !diag.is_empty() {
                w += diag.chars().count() as u16 + 1; // leading space
            }
            w
        })
        .collect();
    let sep = 1u16; // cell between tabs (rendered as the bg color)
    // Reserve 2 cells on each side of the tab strip for the overflow chevrons
    // when there's content past the edge.
    let overflow_l = 1u16;
    let overflow_r = 1u16;
    let inner_left = area.x + overflow_l;
    let inner_right = tabs_max_x.saturating_sub(overflow_r);
    let inner_width = inner_right.saturating_sub(inner_left);

    // Adjust `bufferline_first_visible` so it (a) doesn't run off the end of
    // the pane list, (b) includes the active tab, (c) is the smallest start
    // that keeps the active tab visible.
    if app.bufferline_first_visible >= app.panes.len() {
        app.bufferline_first_visible = app.panes.len().saturating_sub(1);
    }
    if let Some(active) = app.active {
        if active < app.bufferline_first_visible {
            app.bufferline_first_visible = active;
        } else {
            // Walk back from `active` while the cumulative width fits.
            let mut used = 0u16;
            let mut first = active;
            loop {
                let w = widths[first] + if first > 0 { sep } else { 0 };
                if used + w > inner_width {
                    first += 1;
                    break;
                }
                used += w;
                if first == 0 {
                    break;
                }
                first -= 1;
            }
            if app.bufferline_first_visible < first {
                app.bufferline_first_visible = first;
            }
        }
    }
    let first_visible = app.bufferline_first_visible;

    let mut spans: Vec<Span> = Vec::new();
    // Left overflow chevron — only painted if there's a tab off the left edge.
    let left_chev_used = if first_visible > 0 {
        spans.push(Span::styled(
            "‹",
            Style::default()
                .fg(theme::cur().blue)
                .bg(theme::cur().bg_darker),
        ));
        1
    } else {
        spans.push(Span::styled(
            " ",
            Style::default().bg(theme::cur().bg_darker),
        ));
        1
    };
    let mut x = area.x + left_chev_used as u16;
    let mut last_drawn: usize = first_visible;
    let mut overflow_right = false;
    for (i, pane) in app.panes.iter().enumerate().skip(first_visible) {
        let active = app.active == Some(i);
        let name = labels[i].clone();
        let (glyph, icon_color) = match pane {
            Pane::Editor(b) => {
                let p = b.path.clone().unwrap_or_else(|| name.clone().into());
                icons::for_path(&p, false, false, nerd)
            }
            Pane::MdPreview(p) => icons::for_path(&p.path, false, false, nerd),
            Pane::Diff(_) => (if nerd { "\u{f0e7e}" } else { "±" }, theme::cur().orange),
            Pane::GitGraph(_) => (if nerd { "\u{f1d3}" } else { "⎇" }, theme::cur().orange),
            Pane::GitStatus(_) => (if nerd { "\u{f1d2}" } else { "±" }, theme::cur().green),
            Pane::Request(_) => (if nerd { "\u{f0a3e}" } else { "⚡" }, theme::cur().yellow),
            Pane::Pty(_) => (if nerd { "\u{f489}" } else { "▶" }, theme::cur().teal),
            Pane::Ai(_) => (if nerd { "\u{f0e0a}" } else { "✦" }, theme::cur().purple),
            Pane::Tests(_) => (if nerd { "\u{f0668}" } else { "✓" }, theme::cur().green),
            Pane::Trace(_) => (if nerd { "\u{f0e62}" } else { "⏱" }, theme::cur().teal),
            Pane::Browser(_) => (if nerd { "\u{f059f}" } else { "◉" }, theme::cur().blue),
            Pane::Diagnostics(_) => (if nerd { "\u{f0026}" } else { "⚠" }, theme::cur().red),
            Pane::Grep(_) => (if nerd { "\u{f0349}" } else { "⌕" }, theme::cur().yellow),
            Pane::Flaky(_) => (if nerd { "\u{f0668}" } else { "≋" }, theme::cur().purple),
            Pane::Outline(_) => (if nerd { "\u{f01bd}" } else { "⌥" }, theme::cur().purple),
            Pane::Quickfix(_) => (if nerd { "\u{f0349}" } else { "⌕" }, theme::cur().teal),
            Pane::CmdlineHistory(_) => (if nerd { "\u{eb15}" } else { "❯" }, theme::cur().comment),
            #[cfg(feature = "private")]
            Pane::TestExecutions(_) => (if nerd { "\u{f0668}" } else { "⏵" }, theme::cur().teal),
            #[cfg(feature = "private")]
            Pane::CodeBuilds(_) => (if nerd { "\u{f487}" } else { "⚒" }, theme::cur().orange),
        };
        let badge = if pane.is_dirty() { "●" } else { "×" };
        let diag = &diag_chips[i];
        // ` <icon> <name>[ <diag>] <badge> `
        let label = if diag.is_empty() {
            format!(" {glyph} {name} {badge} ")
        } else {
            format!(" {glyph} {name} {diag} {badge} ")
        };
        let cells = label.chars().count() as u16;
        if x + cells > inner_right {
            overflow_right = true;
            break;
        }
        last_drawn = i;
        let (bg, name_fg, badge_fg) = if active {
            (
                theme::cur().bg,
                theme::cur().fg,
                if pane.is_dirty() {
                    theme::cur().orange
                } else {
                    theme::cur().grey_fg
                },
            )
        } else {
            (
                theme::cur().bg_darker,
                theme::cur().grey_fg,
                theme::cur().grey,
            )
        };
        let mut name_style = Style::default().fg(name_fg).bg(bg);
        if active {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        spans.push(Span::styled(
            format!(" {glyph} "),
            Style::default()
                .fg(if active {
                    icon_color
                } else {
                    theme::cur().grey
                })
                .bg(bg),
        ));
        spans.push(Span::styled(format!("{name} "), name_style));
        if !diag.is_empty() {
            let diag_fg = if diag.starts_with('\u{2717}') {
                // `✗` chip — errors → red regardless of active state.
                theme::cur().red
            } else {
                // `⚠` chip — warnings → yellow.
                theme::cur().yellow
            };
            spans.push(Span::styled(
                format!("{diag} "),
                Style::default().fg(diag_fg).bg(bg),
            ));
        }
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
            spans.push(Span::styled(
                " ",
                Style::default().bg(theme::cur().bg_darker),
            ));
            x += 1;
        }
    }
    if app.panes.is_empty() {
        spans.push(Span::styled(
            "  no buffers ",
            Style::default()
                .fg(theme::cur().grey_fg)
                .bg(theme::cur().bg_darker),
        ));
        x += "  no buffers ".chars().count() as u16;
    }
    // Are there tabs past the right edge? (Either we broke out of the render
    // loop, or there are tabs after the last one we drew that we never reached.)
    let more_right = overflow_right || (last_drawn + 1 < app.panes.len());
    // fill the gap up to the cap, then the right overflow chevron (or a blank
    // cell when nothing's past the edge).
    let fill_end = inner_right;
    if x < fill_end {
        spans.push(Span::styled(
            " ".repeat((fill_end - x) as usize),
            Style::default().bg(theme::cur().bg_darker),
        ));
    }
    spans.push(Span::styled(
        if more_right { "›" } else { " " },
        Style::default()
            .fg(theme::cur().blue)
            .bg(theme::cur().bg_darker),
    ));
    let _ = last_drawn;
    // right cap
    spans.push(Span::styled(
        cap_label,
        Style::default()
            .fg(theme::cur().bg_darker)
            .bg(theme::cur().blue)
            .add_modifier(Modifier::BOLD),
    ));

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::buffer::Buffer;
    use crate::config::Config;
    use std::fs;
    use std::path::PathBuf;

    fn ed(path: PathBuf) -> Pane {
        let b = Buffer::open(&path, &Config::default()).unwrap();
        Pane::Editor(b)
    }

    #[test]
    fn diag_chip_prefers_errors_then_warnings_then_empty() {
        use crate::lsp::{Diagnostic, Pos, Range, Severity};
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.rs"), "").unwrap();
        let path = d.path().join("a.rs");
        let r = Range {
            start: Pos {
                line: 0,
                character: 0,
            },
            end: Pos {
                line: 0,
                character: 0,
            },
        };
        let mk = |diags: Vec<Diagnostic>| {
            let mut b = Buffer::open(&path, &Config::default()).unwrap();
            b.diagnostics = diags;
            Pane::Editor(b)
        };
        // clean
        assert_eq!(diag_chip_for(&mk(vec![])), "");
        // 2 warnings → ⚠2
        let warn = || Diagnostic {
            range: r,
            severity: Severity::Warning,
            message: "w".into(),
            source: None,
        };
        assert_eq!(diag_chip_for(&mk(vec![warn(), warn()])), "\u{26A0}2");
        // mix → errors win
        let err = Diagnostic {
            range: r,
            severity: Severity::Error,
            message: "e".into(),
            source: None,
        };
        assert_eq!(diag_chip_for(&mk(vec![warn(), warn(), err])), "\u{2717}1");
    }

    #[test]
    fn disambiguates_only_when_colliding() {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path();
        fs::create_dir(ws.join("git")).unwrap();
        fs::create_dir(ws.join("ai")).unwrap();
        fs::write(ws.join("git").join("mod.rs"), "// git\n").unwrap();
        fs::write(ws.join("ai").join("mod.rs"), "// ai\n").unwrap();
        fs::write(ws.join("lib.rs"), "// lib\n").unwrap();
        let panes = vec![
            ed(ws.join("git").join("mod.rs")),
            ed(ws.join("ai").join("mod.rs")),
            ed(ws.join("lib.rs")),
        ];
        let labels = tab_labels(&panes);
        assert_eq!(labels[0], "git/mod.rs");
        assert_eq!(labels[1], "ai/mod.rs");
        assert_eq!(labels[2], "lib.rs");
    }
}
