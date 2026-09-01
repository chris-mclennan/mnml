//! Notes activity-bar panel — persistent workspace scratch notes
//! (`.mnml/notes/*.md`). (#8)
//!
//! v1 scope: flat list of note files under the workspace's
//! `.mnml/notes/` directory + a `+ New note` action. Click a row →
//! opens the file in an editor pane (goes through the same markdown
//! preview path as any other `.md`). Notes gitignore themselves by
//! default (the `.mnml/` prefix is already common for mnml-scoped
//! files); users can check them in per-workspace by removing them
//! from `.gitignore`.

use ratatui::{
    Frame,
    layout::Rect,
    style::Style,
    text::{Line, Span},
    widgets::{Block, Paragraph},
};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    app.rects.notes_panel_files.clear();
    app.rects.notes_panel_new_chip = None;
    app.rects.notes_panel_filter_input = None;

    // Files come from the cache — populated on first activation.
    // Keeps per-frame stat() calls off the render path.
    if !app.notes_panel_scanned_once {
        app.notes_panel_refresh();
    }
    let filter_lc = app.notes_panel_filter.to_ascii_lowercase();
    let all_files = app.notes_panel_files_cache.clone();
    let files: Vec<std::path::PathBuf> = if filter_lc.is_empty() {
        all_files.clone()
    } else {
        all_files
            .iter()
            .filter(|p| {
                p.file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_ascii_lowercase()
                    .contains(&filter_lc)
            })
            .cloned()
            .collect()
    };

    // 2026-08-24 (user ask) — refresh chip in top-right of the
    // panel header, matching git + todos. Count-in-parens always
    // shown (parity with FINDINGS): total when unfiltered,
    // `M of N` when a filter narrows it.
    let subtitle = if filter_lc.is_empty() {
        format!("  ({})", all_files.len())
    } else {
        format!("  ({} of {})", files.len(), all_files.len())
    };
    app.rects.notes_panel_refresh_chip = crate::ui::panel_chrome::draw_caps_header_with_refresh(
        frame,
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
        "NOTES",
        Some(&subtitle),
        bg,
        &t,
        app.config.ui.ascii_icons,
    );
    // Filter row (row 1). Same idiom as HTTP / Agents / TODOs.
    {
        let y_filter = area.y + 1;
        if y_filter < area.y + area.height {
            let focused = app.notes_panel_filter_focused;
            let bg_chip = crate::ui::panel_chrome::filter_chip_bg(&t);
            let fg_chip = if app.notes_panel_filter.is_empty() && !focused {
                t.comment
            } else {
                t.fg
            };
            let display = if app.notes_panel_filter.is_empty() {
                crate::ui::filter_placeholder::for_state(focused).to_string()
            } else {
                app.notes_panel_filter.clone()
            };
            let cursor = if focused { "\u{258F}" } else { " " };
            let pad = (area.width as usize).saturating_sub(3 + display.chars().count() + 1 + 1);
            let line = Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled(
                    format!("{} ", crate::ui::search_glyph::NERD),
                    Style::default().fg(t.comment).bg(bg_chip),
                ),
                Span::styled(display, Style::default().fg(fg_chip).bg(bg_chip)),
                Span::styled(cursor, Style::default().fg(t.cyan).bg(bg_chip)),
                Span::styled(" ".repeat(pad), Style::default().bg(bg_chip)),
                Span::styled(" ", Style::default().bg(bg)),
            ]);
            let row_rect = Rect {
                x: area.x,
                y: y_filter,
                width: area.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(line), row_rect);
            app.rects.notes_panel_filter_input = Some(row_rect);
        }
    }
    // 2026-08-23 — "+ New note" chip lives ABOVE the list now (was
    // pinned to the bottom, where it fell offscreen once the list
    // grew past the panel height). Same idiom as the sessions rail's
    // "+ New session": narrow chip + `bg2` background so it reads as
    // a distinct button instead of a floating bare-text label. Sits
    // one row below the filter (no blank in between) so the notes
    // panel matches every other panel's tighter header stack.
    let mut y = area.y + 2;
    if y < area.y + area.height {
        // 2026-08-23 (#1200) — routed through the shared
        // `action_button::primary` role so this chip matches every
        // other activity panel's primary action.
        let label = "+ New note";
        let chip_w = crate::ui::action_button::chip_width(label);
        let avail = area.width.saturating_sub(1);
        let new_rect = Rect {
            x: area.x + 1,
            y,
            width: chip_w.min(avail),
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(crate::ui::action_button::chip_line(
                label,
                crate::ui::action_button::primary(&t),
            )),
            new_rect,
        );
        app.rects.notes_panel_new_chip = Some(new_rect);
        y += 2;
    }

    if files.is_empty() && !filter_lc.is_empty() {
        y = crate::ui::empty_state::draw(
            frame,
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: area.height.saturating_sub(y - area.y),
            },
            "No matches — Esc clears",
            None,
            bg,
            &t,
        );
        y += 1; // extra breathing space to match prior layout
    } else if files.is_empty() {
        y = crate::ui::empty_state::draw(
            frame,
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: area.height.saturating_sub(y - area.y),
            },
            "No notes yet — click + New note above.",
            Some("Stored under .mnml/notes/*.md"),
            bg,
            &t,
        );
        y += 1;
    } else {
        // #polish 2026-07-06 — right-aligned age column. Users
        // reported it was hard to find "the note I edited yesterday"
        // among many notes — surfacing mtime does that at a glance.
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        // Clamp cursor to filtered length so a stale index
        // after a filter narrows doesn't paint invisibly.
        let clamped_cursor = app.notes_panel_cursor.min(files.len().saturating_sub(1));
        app.notes_panel_cursor = clamped_cursor;
        let visible_rows = (area.height as usize).saturating_sub(4);
        let mut scroll = app.notes_panel_scroll;
        let (first, shown, needs_sb) = crate::ui::panel_chrome::list_scroll_window(
            &mut scroll,
            clamped_cursor,
            files.len(),
            visible_rows,
        );
        app.notes_panel_scroll = scroll;
        let row_w = if needs_sb {
            area.width.saturating_sub(1)
        } else {
            area.width
        };
        for (row_i, path) in files.iter().enumerate().skip(first).take(shown) {
            if y >= area.y + area.height {
                break;
            }
            let is_focused_row = row_i == clamped_cursor;
            let row_bg = if is_focused_row { t.bg2 } else { bg };
            let name = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("note")
                .to_string();
            let icon = if app.config.ui.ascii_icons {
                "◧"
            } else {
                "\u{F249}"
            };
            // Age string from file mtime — falls back to empty on
            // any I/O error (rare; usually missing metadata).
            let age_str: String = std::fs::metadata(path)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| {
                    let secs = now.saturating_sub(d.as_secs() as i64);
                    crate::ui::git_graph_view::humanize_age(secs)
                })
                .unwrap_or_default();
            // Row is: 2 inset + 1 accent + 2 icon+space + name + gap +
            // age. That is 5 cells of prefix, so the name budget is
            // `row_w - 5 - gap - age`.
            //
            // The old arithmetic subtracted one too few and measured
            // against `area.width` rather than `row_w`, so the name ran
            // into the age column — worse once a scrollbar took a
            // column, and worse again for a two-character age (`14h`
            // fits where `1h` does not).
            //
            // GAP is 2, not 1: the user asked for one more cell of air
            // between the name and the age.
            const AGE_GAP: usize = 2;
            let name_width = (row_w as usize)
                .saturating_sub(5)
                .saturating_sub(AGE_GAP)
                .saturating_sub(age_str.chars().count());
            let name_clipped: String = name.chars().take(name_width).collect();
            let name_padded = format!("{name_clipped:<width$}", width = name_width);
            let row_rect = Rect {
                x: area.x,
                y,
                width: row_w,
                height: 1,
            };
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    // Two unhighlighted cells keep the band off the panel
                    // edge, then the focused row's blue `▌` accent — the
                    // same selected-row idiom as the palette picker /
                    // activity bar / sessions panel.
                    //
                    // This panel painted all three gutter cells in the
                    // row colour, so its band ran flush to the edge AND
                    // carried no accent; TODOS had already been inset
                    // without ever gaining the bar. Both are fixed here,
                    // together, so the two panels finally agree.
                    Span::styled(" ", Style::default().bg(bg)),
                    Span::styled(
                        if is_focused_row { "▌" } else { " " },
                        Style::default().fg(t.blue).bg(row_bg),
                    ),
                    Span::styled(format!("{icon} "), Style::default().fg(t.yellow).bg(row_bg)),
                    Span::styled(name_padded, Style::default().fg(t.fg).bg(row_bg)),
                    Span::styled(
                        format!("{}{age_str}", " ".repeat(AGE_GAP)),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                ])),
                row_rect,
            );
            app.rects.notes_panel_files.push((row_rect, path.clone()));
            y += 1;
        }
        // Content rect, so a wheel event over the list can be routed
        // to this panel's scroll offset.
        app.rects.notes_panel_area = Some(Rect {
            x: area.x,
            y: area.y + 4,
            width: area.width,
            height: visible_rows as u16,
        });
        if needs_sb {
            let sb = Rect {
                x: area.x + row_w,
                y: area.y + 4,
                width: 1,
                height: visible_rows as u16,
            };
            crate::ui::scrollbar::paint_simple_scrollbar(
                frame,
                sb,
                &t,
                files.len(),
                visible_rows,
                first,
            );
            app.rects.scrollbars.push(crate::app::ScrollbarHit {
                area: sb,
                pane_id: 0,
                total: files.len(),
                viewport: visible_rows,
                kind: crate::app::ScrollbarKind::NotesPanel,
            });
        }
    }
    let _ = y;
}

pub fn notes_dir(workspace: &std::path::Path) -> std::path::PathBuf {
    workspace.join(".mnml").join("notes")
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    /// The focused row must be inset off the panel edge AND carry the
    /// blue `▌` accent, matching TODOS.
    ///
    /// This panel painted all three gutter cells in the row colour, so
    /// its highlight ran flush to the left edge — the exact complaint
    /// that had already been fixed in TODOS — and it never painted an
    /// accent bar at all, so "the gutter" was invisible empty space.
    /// USER REPORT — "when creating or deleting notes, it does not auto
    /// refresh, if i click refresh icon i see the changes."
    ///
    /// The sidebar panels cache their own file list, and no filesystem
    /// mutation invalidated it. Asserted through `refresh_after_fs_change`
    /// — the shared chokepoint every create / delete / rename / transfer
    /// funnels through — rather than through one caller, so a new
    /// mutation path cannot reintroduce this by forgetting a call.
    #[test]
    fn creating_and_deleting_a_note_refreshes_the_panel_cache() {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        // From `app.workspace`, NOT `d.path()`: App::new canonicalizes
        // the workspace, so on macOS the raw tempdir is /var/... while
        // the panel scans /private/var/... — seeding the wrong one makes
        // this test fail against a correct fix.
        let nd = notes_dir(&app.workspace);
        std::fs::create_dir_all(&nd).unwrap();
        app.notes_panel_refresh();
        assert!(app.notes_panel_files_cache.is_empty(), "seeded dirty");

        // Create.
        let note = nd.join("fresh.md");
        std::fs::write(&note, "x").unwrap();
        app.refresh_after_fs_change();
        assert!(
            app.notes_panel_files_cache.iter().any(|p| p == &note),
            "a newly created note is missing until the user clicks refresh"
        );

        // Delete.
        std::fs::remove_file(&note).unwrap();
        app.refresh_after_fs_change();
        assert!(
            !app.notes_panel_files_cache.iter().any(|p| p == &note),
            "a deleted note lingers in the panel until the user clicks refresh"
        );
    }

    /// The same chokepoint must cover FINDINGS, whose cache has the
    /// identical lifecycle.
    #[test]
    fn creating_a_finding_refreshes_the_panel_cache() {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        let fd = crate::ui::findings_panel::findings_dir(&app.workspace);
        std::fs::create_dir_all(&fd).unwrap();
        app.findings_panel_refresh();
        let f = fd.join("report.md");
        std::fs::write(&f, "x").unwrap();
        app.refresh_after_fs_change();
        assert!(
            app.findings_panel_files_cache.iter().any(|p| p == &f),
            "a newly created finding is missing until the user clicks refresh"
        );
    }

    /// TODOS is deliberately NOT refreshed on every filesystem change:
    /// its refresh walks the whole workspace synchronously, and doing
    /// that per file operation is the exact per-frame full-scan shape
    /// behind this editor's previous freezes.
    #[test]
    fn an_fs_change_does_not_trigger_a_whole_workspace_todo_scan() {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        std::fs::write(d.path().join("a.rs"), "// TODO: marker\n").unwrap();
        app.todos_panel_scanned_once = false;
        app.refresh_after_fs_change();
        assert!(
            !app.todos_panel_scanned_once,
            "refresh_after_fs_change ran a full-workspace TODO scan — that \
             cost belongs on the panel's own refresh, not on every file op"
        );
    }

    #[test]
    fn the_focused_row_is_inset_and_carries_the_blue_accent_bar() {
        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        let nd = notes_dir(d.path());
        std::fs::create_dir_all(&nd).unwrap();
        std::fs::write(nd.join("a.md"), "hello").unwrap();
        app.notes_panel_files_cache = vec![nd.join("a.md")];
        app.notes_panel_scanned_once = true;

        let w = 60u16;
        let mut term = Terminal::new(TestBackend::new(w, 12)).unwrap();
        term.draw(|f| {
            draw(
                f,
                &mut app,
                Rect {
                    x: 0,
                    y: 0,
                    width: w,
                    height: 12,
                },
            )
        })
        .unwrap();

        let t = theme::cur();
        let buf = term.backend().buffer();
        let y = (0..12u16)
            .find(|&y| (0..w).any(|x| buf[(x, y)].symbol() == "▌"))
            .expect("no row carries an accent bar");

        assert_eq!(
            buf[(0, y)].bg,
            t.bg_darker,
            "column 0 is highlighted — the band is welded to the panel edge"
        );
        assert_eq!(
            buf[(1, y)].symbol(),
            "▌",
            "the accent bar is not at column 1 — it should sit under the \
             filter row's magnifier"
        );
        assert_eq!(buf[(1, y)].fg, t.blue, "the accent bar is not blue");
        assert_eq!(
            buf[(1, y)].bg,
            t.bg2,
            "the accent sits outside the highlight band"
        );
    }
}
