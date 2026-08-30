//! Renders a [`crate::file_browser::FileBrowserPane`] — path header, then
//! `icon name … size … modified` rows.
//!
//! Column layout degrades by width rather than truncating names: the
//! modified column drops first, then size, so a narrow pane still shows
//! full filenames. Names are what you navigate by; a date you cannot read
//! is worth less than a name you can.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::ui::theme;

/// Width at which the modified column appears, and then the size column.
const W_FOR_MODIFIED: u16 = 46;
const W_FOR_SIZE: u16 = 30;
const SIZE_COL: usize = 8;
const MOD_COL: usize = 12;

/// Human-readable size in the same idiom as `ls -h`.
///
/// One decimal place below 10 units and none above, so the column stays
/// narrow while `4.1 M` and `210 K` both read exactly.
pub fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "K", "M", "G", "T"];
    let mut v = bytes as f64;
    let mut u = 0usize;
    while v >= 1024.0 && u + 1 < UNITS.len() {
        v /= 1024.0;
        u += 1;
    }
    if u == 0 {
        format!("{bytes} {}", UNITS[0])
    } else if v < 10.0 {
        format!("{v:.1} {}", UNITS[u])
    } else {
        format!("{v:.0} {}", UNITS[u])
    }
}

/// `MM/DD HH:MM`, matching the git graph's date column so the two panes
/// read consistently.
pub fn short_time(secs: u64) -> String {
    crate::ui::git_graph_view::format_commit_datetime(secs as i64)
}

pub fn draw(frame: &mut Frame, app: &mut App, pane_id: PaneId, area: Rect) {
    let t = theme::cur();
    let nerd = !app.config.ui.ascii_icons;
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );
    if area.height < 2 || area.width < 8 {
        return;
    }

    // ── path header ──
    let header = Rect {
        x: area.x,
        y: area.y,
        width: area.width,
        height: 1,
    };
    let path_text = {
        let full = app
            .panes
            .get(pane_id)
            .and_then(|p| match p {
                crate::pane::Pane::Files(f) => Some(f.cwd.display().to_string()),
                _ => None,
            })
            .unwrap_or_default();
        // Elide from the LEFT — the tail of a path is the part that
        // identifies where you are.
        let avail = area.width.saturating_sub(2) as usize;
        if full.chars().count() > avail {
            let tail: String = full
                .chars()
                .rev()
                .take(avail.saturating_sub(1))
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            format!("…{tail}")
        } else {
            full
        }
    };
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            format!(" {path_text}"),
            Style::default()
                .fg(t.blue)
                .bg(t.bg_darker)
                .add_modifier(Modifier::BOLD),
        )))
        .style(Style::default().bg(t.bg_darker)),
        header,
    );

    let body = Rect {
        x: area.x,
        y: area.y + 1,
        width: area.width,
        height: area.height - 1,
    };
    let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pane_id) else {
        return;
    };

    if let Some(err) = f.error.clone() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                format!("  {err}"),
                Style::default().fg(t.red).bg(t.bg_dark),
            ))),
            body,
        );
        return;
    }
    if f.entries.is_empty() {
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "  (empty directory)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            ))),
            body,
        );
        return;
    }

    // ── scroll ──
    // Same two-policy split as the git graph (#1229): a jump gets context,
    // a step scrolls minimally.
    let h = body.height as usize;
    let want_center = std::mem::take(&mut f.center_on_next_draw);
    f.scroll = reveal_scroll(f.selected, f.scroll, h, want_center);
    let max_scroll = f.entries.len().saturating_sub(h.min(f.entries.len()));
    f.scroll = f.scroll.min(max_scroll);

    let show_mod = area.width >= W_FOR_MODIFIED;
    let show_size = area.width >= W_FOR_SIZE;
    let sb_w: u16 = if f.entries.len() > h { 1 } else { 0 };
    let name_w = (area.width.saturating_sub(sb_w) as usize)
        .saturating_sub(4) // icon + pads
        .saturating_sub(if show_size { SIZE_COL + 1 } else { 0 })
        .saturating_sub(if show_mod { MOD_COL + 1 } else { 0 });

    let selected = f.selected;
    let scroll = f.scroll;
    let rows: Vec<(Rect, usize)> = {
        let mut out = Vec::new();
        for (row, idx) in (scroll..f.entries.len()).take(h).enumerate() {
            let e = &f.entries[idx];
            let is_cur = idx == selected;
            let row_bg = if is_cur { t.bg2 } else { t.bg_dark };
            let (icon, icon_fg) = crate::ui::icons::for_path(&e.path, e.is_dir, false, nerd);
            let mut name: String = e.name.chars().take(name_w).collect();
            if e.is_symlink {
                name.push('@');
            }
            let pad = name_w.saturating_sub(name.chars().count());
            let mut spans = vec![
                // Leading cell keeps the pane bg so a selected row never
                // butts against the pane's left edge — the same rule the
                // tree and git palette follow (#970 / #1229).
                Span::styled(" ", Style::default().bg(t.bg_dark)),
                Span::styled(format!("{icon} "), Style::default().fg(icon_fg).bg(row_bg)),
                Span::styled(
                    name,
                    Style::default()
                        .fg(if e.is_dir { t.blue } else { t.fg })
                        .bg(row_bg)
                        .add_modifier(if e.is_dir {
                            Modifier::BOLD
                        } else {
                            Modifier::empty()
                        }),
                ),
                Span::styled(" ".repeat(pad), Style::default().bg(row_bg)),
            ];
            if show_size {
                let s = e.size.map(human_size).unwrap_or_else(|| "—".into());
                spans.push(Span::styled(
                    format!("{s:>SIZE_COL$} "),
                    Style::default().fg(t.comment).bg(row_bg),
                ));
            }
            if show_mod {
                let m = e.modified.map(short_time).unwrap_or_else(|| "—".into());
                spans.push(Span::styled(
                    format!("{m:>MOD_COL$} "),
                    Style::default().fg(t.comment).bg(row_bg),
                ));
            }
            let r = Rect {
                x: body.x,
                y: body.y + row as u16,
                width: body.width.saturating_sub(sb_w),
                height: 1,
            };
            frame.render_widget(Paragraph::new(Line::from(spans)), r);
            out.push((r, idx));
        }
        out
    };

    let total = f.entries.len();
    if sb_w > 0 {
        let sb = Rect {
            x: body.x + body.width - 1,
            y: body.y,
            width: 1,
            height: body.height,
        };
        crate::ui::scrollbar::paint_simple_scrollbar(frame, sb, &t, total, h, scroll);
        app.rects.scrollbars.push(crate::app::ScrollbarHit {
            area: sb,
            pane_id,
            total,
            viewport: h,
            kind: crate::app::ScrollbarKind::FilesPane,
        });
    }
    for (r, idx) in rows {
        app.rects.file_pane_rows.push((r, pane_id, idx));
    }
    app.rects.editor_panes.push((area, pane_id));
}

/// Where the listing should scroll to. See
/// [`crate::ui::git_graph_view`]'s equivalent — a jump gets context, a
/// step scrolls minimally, and centring only applies when the target is
/// off-screen.
fn reveal_scroll(selected: usize, scroll: usize, h: usize, want_center: bool) -> usize {
    if h == 0 {
        return scroll;
    }
    let visible = selected >= scroll && selected < scroll + h;
    if want_center && !visible {
        return selected.saturating_sub(h / 3);
    }
    if selected < scroll {
        selected
    } else if selected >= scroll + h {
        selected + 1 - h
    } else {
        scroll
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn human_size_reads_exactly_at_every_scale() {
        assert_eq!(human_size(0), "0 B");
        assert_eq!(human_size(512), "512 B");
        assert_eq!(human_size(1024), "1.0 K");
        assert_eq!(human_size(4_300_000), "4.1 M");
        // Above 10 units, drop the decimal so the column stays narrow.
        assert_eq!(human_size(210 * 1024), "210 K");
    }

    /// The column budget must never exceed the pane, or names overflow
    /// into the scrollbar column.
    #[test]
    fn narrow_panes_drop_columns_rather_than_names() {
        // (No assertion that W_FOR_SIZE < W_FOR_MODIFIED — both are
        // consts, so it is a compile-time truth and clippy rightly calls
        // it noise. The real invariant is the name-column budget below.)
        // At the narrowest width that still shows both, the fixed columns
        // must leave room for a usable name.
        let fixed = 4 + SIZE_COL + 1 + MOD_COL + 1;
        assert!(
            (W_FOR_MODIFIED as usize) > fixed + 8,
            "at {W_FOR_MODIFIED} cells the fixed columns ({fixed}) leave under \
             8 cells for the name"
        );
    }

    #[test]
    fn a_jump_is_revealed_with_context_and_a_step_is_not() {
        // Jump far below the viewport → not pinned to the last row.
        let s = reveal_scroll(500, 0, 30, true);
        assert!(500 - s > 2 && 500 - s < 28);
        // Already visible → no movement.
        assert_eq!(reveal_scroll(105, 100, 30, true), 100);
        // Step off the bottom → exactly one row.
        assert_eq!(reveal_scroll(130, 100, 30, false), 101);
    }
}

#[cfg(test)]
mod render_tests {
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    /// End-to-end: a Files pane opened through the App renders its
    /// directory. Compiling is not the same as rendering — this is the
    /// check that the pane is actually wired into the draw dispatch.
    #[test]
    fn a_files_pane_renders_its_directory_listing() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::fs::create_dir(d.path().join("subdir")).unwrap();
        std::fs::write(d.path().join("readme.md"), "hello").unwrap();

        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(None);
        let pid = app.active.expect("open_files_pane did not focus the pane");

        let mut term = Terminal::new(TestBackend::new(60, 10)).unwrap();
        term.draw(|f| {
            draw(
                f,
                &mut app,
                pid,
                Rect {
                    x: 0,
                    y: 0,
                    width: 60,
                    height: 10,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        let screen: String = (0..10)
            .map(|y| (0..60).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(
            screen.contains("subdir"),
            "directory row missing:\n{screen}"
        );
        assert!(screen.contains("readme.md"), "file row missing:\n{screen}");
        assert!(
            screen.contains("5 B"),
            "size column missing (readme.md is 5 bytes):\n{screen}"
        );
        // Row rects must be registered, or clicks land nowhere.
        assert!(
            app.rects.file_pane_rows.iter().any(|(_, p, _)| *p == pid),
            "no click rects registered for the Files pane"
        );
    }

    /// Enter on a directory descends; Enter on a file opens it as an
    /// editor pane rather than descending.
    #[test]
    fn activate_descends_a_directory_and_opens_a_file() {
        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::fs::create_dir(d.path().join("subdir")).unwrap();
        std::fs::write(d.path().join("subdir").join("inner.txt"), "x").unwrap();

        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.open_files_pane(None);
        let pid = app.active.unwrap();

        // Cursor is on `subdir` (the only entry) — activate descends.
        app.files_pane_activate(pid);
        let cwd = match app.panes.get(pid) {
            Some(crate::pane::Pane::Files(f)) => f.cwd.clone(),
            _ => panic!("pane is no longer a Files pane"),
        };
        // Canonicalise BOTH sides: `App::new` canonicalises the
        // workspace, so on macOS the pane's cwd is `/private/var/...`
        // while `tempdir()` hands back `/var/...`. Comparing raw paths
        // reported "did not descend" when the descent had worked
        // perfectly.
        let want = d.path().join("subdir").canonicalize().unwrap();
        assert_eq!(
            cwd.canonicalize().unwrap(),
            want,
            "did not descend into subdir"
        );

        // Now the cursor is on `inner.txt` — activate opens it.
        let panes_before = app.panes.len();
        app.files_pane_activate(pid);
        assert!(
            app.panes.len() > panes_before,
            "activating a file opened no editor pane"
        );
        assert!(
            app.panes.iter().any(|p| match p {
                crate::pane::Pane::Editor(b) =>
                    b.path.as_ref().and_then(|p| p.canonicalize().ok())
                        == d.path()
                            .join("subdir")
                            .join("inner.txt")
                            .canonicalize()
                            .ok(),
                _ => false,
            }),
            "the opened pane is not an editor on inner.txt"
        );
    }
}
