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
/// Entry index used for the pinned `..` row's click rect. Not a real
/// index into `entries` — the click handler maps it to `go_parent`.
pub const PARENT_ROW: usize = usize::MAX;
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

    let mut body = Rect {
        x: area.x,
        y: area.y + 1,
        width: area.width,
        height: area.height - 1,
    };
    // #files item 2 — a footer row while anything is marked. Only then:
    // a permanent status row would cost a listing row for information
    // that is usually "nothing selected".
    let marked_count = match app.panes.get(pane_id) {
        Some(crate::pane::Pane::Files(f)) => f.marked.len(),
        _ => 0,
    };
    let footer = if marked_count > 0 && body.height > 2 {
        let r = Rect {
            x: body.x,
            y: body.y + body.height - 1,
            width: body.width,
            height: 1,
        };
        body.height -= 1;
        Some(r)
    } else {
        None
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

    // ── `..` parent row ──
    //
    // User, having navigated into assets/: "how do i go up a level i wnt
    // into this folder and coudlnt get back up to mnml folder".
    //
    // Backspace / Left / h already worked — verified by probe — so this is
    // purely a DISCOVERABILITY failure: I shipped a file browser with no
    // visible way up. Every file manager has this row (ranger, mc,
    // superfile), and a keybinding nobody can see is not an affordance.
    //
    // Rendered by the VIEW and PINNED above the listing rather than
    // injected into `entries`, for two reasons: a synthetic entry in the
    // model would be a target for file operations ("delete .."), and
    // pinning means the way out never scrolls off the top of a long
    // directory. The cursor therefore only ever sits on real entries.
    let has_parent = f.cwd.parent().is_some();
    let (parent_row, body) = if has_parent && body.height > 1 {
        (
            Some(Rect {
                x: body.x,
                y: body.y,
                width: body.width,
                height: 1,
            }),
            Rect {
                x: body.x,
                y: body.y + 1,
                width: body.width,
                height: body.height - 1,
            },
        )
    } else {
        (None, body)
    };
    if let Some(r) = parent_row {
        let (icon, _) = crate::ui::icons::for_path(&f.cwd, true, false, nerd);
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(" ", Style::default().bg(t.bg_dark)),
                Span::styled(
                    format!("{icon} "),
                    Style::default().fg(t.blue).bg(t.bg_dark),
                ),
                Span::styled(
                    "..",
                    Style::default()
                        .fg(t.blue)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ),
                // Name the keys inline. The row itself is the affordance;
                // the hint teaches the keyboard route from it.
                Span::styled(
                    "   (⌫ / ← / h)",
                    Style::default().fg(t.comment).bg(t.bg_dark),
                ),
            ])),
            r,
        );
        app.rects.file_pane_rows.push((r, pane_id, PARENT_ROW));
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
    let f_marked = f.marked.clone();
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
            // Mark glyph occupies the leading cell, which otherwise keeps
            // the pane bg so a selected row never butts against the pane's
            // left edge (#970 / #1229). A marked row shows `▌` in green
            // there — visible at a glance down the column, and it cannot be
            // confused with the cursor highlight, which is a background.
            let is_marked = f_marked.contains(&e.path);
            let lead = if is_marked {
                Span::styled("\u{258C}", Style::default().fg(t.green).bg(t.bg_dark))
            } else {
                Span::styled(" ", Style::default().bg(t.bg_dark))
            };
            let mut spans = vec![
                lead,
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

    if let Some(r) = footer {
        let (n, bytes) = f.marked_summary();
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(
                    format!(" {n} selected"),
                    Style::default()
                        .fg(t.bg_darker)
                        .bg(t.green)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!("  {}  ", human_size(bytes)),
                    Style::default().fg(t.fg).bg(t.bg2),
                ),
                // Name the clearing key: a mode you cannot get out of is
                // worse than no mode.
                Span::styled(
                    "Esc clears · Ctrl+C/X acts on the set ",
                    Style::default().fg(t.comment).bg(t.bg2),
                ),
            ]))
            .style(Style::default().bg(t.bg2)),
            r,
        );
    }
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

    /// #files item 2 — a mark has to be VISIBLE, and the footer has to
    /// say how many. A selection you cannot see is a way to delete the
    /// wrong thing.
    #[test]
    fn marked_rows_show_a_marker_and_a_footer_count() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        for n in ["one.txt", "two.txt"] {
            std::fs::write(d.path().join(n), "xx").unwrap();
        }
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(None);
        let pid = app.active.unwrap();

        let area = Rect {
            x: 0,
            y: 0,
            width: 60,
            height: 10,
        };
        let render = |app: &mut crate::app::App| -> String {
            let mut term = Terminal::new(TestBackend::new(60, 10)).unwrap();
            term.draw(|f| draw(f, app, pid, area)).unwrap();
            let buf = term.backend().buffer();
            (0..10)
                .map(|y| (0..60).map(|x| buf[(x, y)].symbol()).collect::<String>())
                .collect::<Vec<_>>()
                .join("\n")
        };

        let before = render(&mut app);
        assert!(
            !before.contains("selected"),
            "footer showed with nothing marked — it costs a listing row:\n{before}"
        );

        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
            f.selected = 0;
            f.toggle_mark();
        }
        let after = render(&mut app);
        assert!(
            after.contains("\u{258C}"),
            "no mark glyph on the marked row:\n{after}"
        );
        assert!(
            after.contains("1 selected"),
            "footer does not report the count:\n{after}"
        );
        assert!(
            after.contains("Esc clears"),
            "footer does not name the way out of the selection:\n{after}"
        );
    }

    /// #1229 f/u — the way out must be VISIBLE.
    ///
    /// User: "how do i go up a level i wnt into this folder and coudlnt
    /// get back up to mnml folder". Backspace / Left / h all worked
    /// (verified by probe), so this was purely discoverability: a file
    /// browser with no `..` row.
    #[test]
    fn a_parent_row_is_rendered_and_clickable() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::fs::create_dir(d.path().join("assets")).unwrap();
        std::fs::write(d.path().join("assets").join("demo.gif"), "x").unwrap();

        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(Some(d.path().join("assets")));
        let pid = app.active.unwrap();

        let mut term = Terminal::new(TestBackend::new(60, 8)).unwrap();
        let area = Rect {
            x: 0,
            y: 0,
            width: 60,
            height: 8,
        };
        term.draw(|f| draw(f, &mut app, pid, area)).unwrap();
        let screen: String = {
            let buf = term.backend().buffer();
            (0..8)
                .map(|y| (0..60).map(|x| buf[(x, y)].symbol()).collect::<String>())
                .collect::<Vec<_>>()
                .join("\n")
        };

        assert!(
            screen.contains(".."),
            "no `..` row — the only way up is an invisible keybinding:\n{screen}"
        );
        // And it must be a click target, not just paint.
        assert!(
            app.rects
                .file_pane_rows
                .iter()
                .any(|(_, p, idx)| *p == pid && *idx == PARENT_ROW),
            "the `..` row registered no click rect"
        );
        // The real entry rows must still be registered and NOT collide
        // with the sentinel.
        assert!(
            app.rects
                .file_pane_rows
                .iter()
                .any(|(_, p, idx)| *p == pid && *idx == 0),
            "entry rows lost their rects when the parent row was added"
        );
    }

    /// The root of the filesystem has no parent, so no row — otherwise it
    /// is a dead click.
    #[test]
    fn the_filesystem_root_shows_no_parent_row() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.open_files_pane(Some(std::path::PathBuf::from("/")));
        let pid = app.active.unwrap();
        let mut term = Terminal::new(TestBackend::new(60, 8)).unwrap();
        term.draw(|f| {
            draw(
                f,
                &mut app,
                pid,
                Rect {
                    x: 0,
                    y: 0,
                    width: 60,
                    height: 8,
                },
            )
        })
        .unwrap();
        assert!(
            !app.rects
                .file_pane_rows
                .iter()
                .any(|(_, p, idx)| *p == pid && *idx == PARENT_ROW),
            "`/` has no parent, so a `..` row there would be a dead click"
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
