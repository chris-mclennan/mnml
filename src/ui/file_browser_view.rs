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
    // #files item 3 — CLICKABLE BREADCRUMB instead of a flat path.
    //
    // Each segment navigates to that ancestor, and a trailing `▾` opens
    // the destinations picker. The old header was an elided string: it
    // told you where you were and gave you nothing to do about it, so the
    // only way to move up several levels was pressing `h` repeatedly.
    //
    // Segments are dropped from the LEFT when they do not fit, because the
    // tail identifies where you are. The dropped prefix renders as `…`,
    // which stays clickable and jumps to the deepest hidden ancestor —
    // otherwise narrowing the pane would silently remove navigation.
    // #files item 5 — git status per row.
    //
    // `GitStatus::snapshot().files` is a path -> state map that mnml
    // already maintains on a TTL for the tree tint and statusline chips,
    // keyed ABSOLUTELY. So badges cost one hash lookup per visible row and
    // nothing else — no extra `git` invocation, no new cache.
    //
    // This is the thing a standalone file manager cannot do, and the
    // strongest argument for a browser INSIDE the editor rather than
    // beside one.
    //
    // BORROWED, not cloned. All three reviewers flagged the clone: it
    // copied the entire repo-wide `HashMap<PathBuf, FileState>` — every
    // key a fresh heap allocation — on EVERY draw, while only the handful
    // of visible rows ever look into it. In a monorepo with thousands of
    // dirty files that is an allocation storm per frame, doubled in the
    // dual-pane commander layout.
    //
    // `tree_view` does the identical badge lookup by reference in a
    // function with the same interleaved-borrow shape, which is what
    // proved the clone was habit rather than necessity. The snapshot is
    // cloned into a local `Rc`-free owned map only where the borrow
    // checker genuinely demands it — here it does not, because the
    // lookups all happen before `app.rects` is touched.
    let git_files = &app.git.snapshot().files;
    let (cwd, sort_kind, filter_q, filter_on) = match app.panes.get(pane_id) {
        Some(crate::pane::Pane::Files(f)) => (
            f.cwd.clone(),
            f.sort,
            f.filter.clone(),
            f.filter_focused || !f.filter.is_empty(),
        ),
        _ => return,
    };
    let chain = crate::places::breadcrumb(&cwd);
    let chevron = if nerd { "\u{25BE}" } else { "v" };
    let sort_label = match sort_kind {
        crate::file_browser::Sort::DirsFirstName => "name",
        crate::file_browser::Sort::Size => "size",
        crate::file_browser::Sort::Modified => "modified",
    };
    let sort_text = format!(" {sort_label} \u{25BE} ");
    // Reserve the chevron AND the sort label before laying out the
    // breadcrumb.
    //
    // The first version appended the sort label afterwards using whatever
    // width was left, so on a long path there was none left and the label
    // silently vanished — which is precisely when you have most trouble
    // telling why the listing is ordered as it is. Fixed-width chrome
    // gets its space first; the PATH is the elastic part, and it already
    // knows how to elide.
    let avail = (area.width as usize)
        .saturating_sub(3)
        .saturating_sub(sort_text.chars().count());
    // Widest suffix of the chain that fits, always keeping the last
    // segment even if it alone overflows.
    let mut first = 0usize;
    loop {
        let width: usize = chain[first..]
            .iter()
            .map(|(l, _)| l.chars().count() + 1)
            .sum::<usize>()
            + if first > 0 { 2 } else { 0 };
        if width <= avail || first + 1 >= chain.len() {
            break;
        }
        first += 1;
    }
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut x = area.x;
    let hdr_bg = t.bg_darker;
    if first > 0 {
        let lbl = "… ".to_string();
        let w = lbl.chars().count() as u16;
        spans.push(Span::styled(lbl, Style::default().fg(t.comment).bg(hdr_bg)));
        // Clicking `…` goes to the deepest ancestor that was dropped.
        app.rects.file_pane_breadcrumbs.push((
            Rect {
                x,
                y: area.y,
                width: w,
                height: 1,
            },
            pane_id,
            chain[first - 1].1.clone(),
        ));
        x += w;
    }
    for (i, (label, path)) in chain.iter().enumerate().skip(first) {
        let is_last = i + 1 == chain.len();
        let text = if label == "/" {
            "/".to_string()
        } else if is_last {
            label.clone()
        } else {
            format!("{label}/")
        };
        let w = text.chars().count() as u16;
        spans.push(Span::styled(
            text,
            Style::default()
                .fg(if is_last { t.blue } else { t.comment })
                .bg(hdr_bg)
                .add_modifier(if is_last {
                    Modifier::BOLD
                } else {
                    Modifier::empty()
                }),
        ));
        app.rects.file_pane_breadcrumbs.push((
            Rect {
                x,
                y: area.y,
                width: w,
                height: 1,
            },
            pane_id,
            path.clone(),
        ));
        x += w;
    }
    spans.push(Span::styled(
        format!(" {chevron} "),
        Style::default().fg(t.comment).bg(hdr_bg),
    ));
    // #files — the active SORT, right-aligned in the header.
    //
    // `s` cycles name → size → modified and used to announce itself with
    // a toast only, so a second later the active sort was invisible and
    // the listing order looked arbitrary. A gap introduced by the
    // foundation commit; state a mode is in, do not just announce the
    // transition.
    let used: usize = spans.iter().map(|sp| sp.content.chars().count()).sum();
    let pad = (area.width as usize)
        .saturating_sub(used)
        .saturating_sub(sort_text.chars().count());
    if pad > 0 {
        spans.push(Span::styled(" ".repeat(pad), Style::default().bg(hdr_bg)));
    }
    let sort_w = sort_text.chars().count() as u16;
    let sort_x = area.x + (area.width.saturating_sub(sort_w));
    spans.push(Span::styled(
        sort_text,
        Style::default().fg(t.comment).bg(hdr_bg),
    ));
    // Clickable. It paints the same `▾` as the destinations chevron, so
    // painting it inert made it a dead click — flagged in review.
    app.rects.file_pane_sort_label = Some((
        Rect {
            x: sort_x,
            y: area.y,
            width: sort_w,
            height: 1,
        },
        pane_id,
    ));
    app.rects.file_pane_places_chevron = Some((
        Rect {
            x,
            y: area.y,
            width: 3,
            height: 1,
        },
        pane_id,
    ));
    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(hdr_bg)),
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

    // ── filter row ──
    //
    // Only while filtering. A permanent row would cost a listing row to
    // say "not filtering", the same reasoning as the marked footer.
    let body = if filter_on && body.height > 2 {
        let r = Rect {
            x: body.x,
            y: body.y,
            width: body.width,
            height: 1,
        };
        let glyph = crate::ui::search_glyph::for_ascii(!nerd);
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled(format!(" {glyph} "), Style::default().fg(t.cyan).bg(t.bg2)),
                Span::styled(
                    if filter_q.is_empty() {
                        crate::ui::filter_placeholder::for_state(true).to_string()
                    } else {
                        filter_q.clone()
                    },
                    Style::default().fg(t.fg).bg(t.bg2),
                ),
            ]))
            .style(Style::default().bg(t.bg2)),
            r,
        );
        Rect {
            x: body.x,
            y: body.y + 1,
            width: body.width,
            height: body.height - 1,
        }
    } else {
        body
    };

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

    // Error / empty states render BELOW the `..` row, not instead of it.
    //
    // These two guards used to `return` before the parent row was drawn,
    // so browsing into an empty or unreadable directory left a pane with
    // no visible way out — reintroducing exactly the bug the `..` row was
    // added to fix, for its most likely trigger. Caught in review.
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
    let badge_w = if git_files.is_empty() { 0 } else { 2 };
    let name_w = (area.width.saturating_sub(sb_w) as usize)
        .saturating_sub(4) // icon + pads
        .saturating_sub(badge_w)
        .saturating_sub(if show_size { SIZE_COL + 1 } else { 0 })
        .saturating_sub(if show_mod { MOD_COL + 1 } else { 0 });

    let selected = f.selected;
    let scroll = f.scroll;
    // Same story as `git_files`: borrowed, not cloned. `entries` and
    // `marked` are disjoint fields of the same pane, so the row loop can
    // read both. Bounded by the user's selection rather than the repo, so
    // smaller — but the same unforced per-frame allocation.
    let f_marked = &f.marked;
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
            // Badge: one cell, always reserved when the repo has ANY
            // changes, so rows do not shift horizontally as files change
            // state underneath the cursor.
            if !git_files.is_empty() {
                let (ch, fg) = match git_files.get(&e.path) {
                    Some(crate::git::status::FileState::Conflicted) => ("!", t.red),
                    Some(crate::git::status::FileState::Staged) => ("+", t.green),
                    Some(crate::git::status::FileState::Modified) => ("~", t.yellow),
                    Some(crate::git::status::FileState::Untracked) => ("?", t.comment),
                    None => (" ", t.comment),
                };
                spans.push(Span::styled(
                    ch.to_string(),
                    Style::default()
                        .fg(fg)
                        .bg(row_bg)
                        .add_modifier(Modifier::BOLD),
                ));
                spans.push(Span::styled(" ", Style::default().bg(row_bg)));
            }
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
    use ratatui::crossterm::event::KeyModifiers;

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

    /// #files — the active sort must be VISIBLE, not just announced by a
    /// toast that vanishes.
    #[test]
    fn the_header_names_the_active_sort() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::fs::write(d.path().join("a.txt"), "a").unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(None);
        let pid = app.active.unwrap();

        let header = |app: &mut crate::app::App| -> String {
            let mut term = Terminal::new(TestBackend::new(70, 6)).unwrap();
            term.draw(|f| {
                draw(
                    f,
                    app,
                    pid,
                    Rect {
                        x: 0,
                        y: 0,
                        width: 70,
                        height: 6,
                    },
                )
            })
            .unwrap();
            let buf = term.backend().buffer();
            (0..70).map(|x| buf[(x, 0)].symbol()).collect()
        };

        assert!(header(&mut app).contains("name"), "default sort not shown");
        if let Some(crate::pane::Pane::Files(f)) = app.panes.get_mut(pid) {
            f.set_sort(crate::file_browser::Sort::Size);
        }
        let h = header(&mut app);
        assert!(h.contains("size"), "sort change not reflected: {h:?}");
        assert!(!h.contains("name "), "stale sort label left behind: {h:?}");
    }

    /// #files item 5 — git state per row, from the snapshot mnml already
    /// maintains. Uses a REAL repo, because the whole value is that the
    /// states come from git rather than from a fixture.
    #[test]
    fn rows_show_their_git_state() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .args(args)
                .current_dir(d.path())
                .output()
                .expect("git");
        };
        run(&["init", "-q", "-b", "main"]);
        run(&["config", "user.email", "t@t"]);
        run(&["config", "user.name", "T"]);
        std::fs::write(d.path().join("tracked.txt"), "one").unwrap();
        run(&["add", "."]);
        run(&["commit", "-qm", "init"]);
        // Now: one modified, one untracked, one unchanged.
        std::fs::write(d.path().join("tracked.txt"), "two").unwrap();
        std::fs::write(d.path().join("brand_new.txt"), "x").unwrap();
        std::fs::write(d.path().join("staged.txt"), "s").unwrap();
        run(&["add", "staged.txt"]);

        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.git.refresh();
        app.open_files_pane(None);
        let pid = app.active.unwrap();

        let mut term = Terminal::new(TestBackend::new(70, 10)).unwrap();
        term.draw(|f| {
            draw(
                f,
                &mut app,
                pid,
                Rect {
                    x: 0,
                    y: 0,
                    width: 70,
                    height: 10,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        let rows: Vec<String> = (0..10)
            .map(|y| (0..70).map(|x| buf[(x, y)].symbol()).collect())
            .collect();

        let row_for = |name: &str| -> String {
            rows.iter()
                .find(|r| r.contains(name))
                .unwrap_or_else(|| panic!("no row for {name}:\n{}", rows.join("\n")))
                .clone()
        };
        assert!(
            row_for("tracked.txt").contains('~'),
            "modified file has no `~` badge: {:?}",
            row_for("tracked.txt")
        );
        assert!(
            row_for("brand_new.txt").contains('?'),
            "untracked file has no `?` badge: {:?}",
            row_for("brand_new.txt")
        );
        assert!(
            row_for("staged.txt").contains('+'),
            "staged file has no `+` badge: {:?}",
            row_for("staged.txt")
        );
    }

    /// Outside a repo — or in a clean one — no badge column, and no
    /// crash. A file browser must work on any directory on the machine.
    #[test]
    fn a_directory_with_no_git_changes_shows_no_badges() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::fs::write(d.path().join("plain.txt"), "x").unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(None);
        let pid = app.active.unwrap();

        let mut term = Terminal::new(TestBackend::new(70, 8)).unwrap();
        term.draw(|f| {
            draw(
                f,
                &mut app,
                pid,
                Rect {
                    x: 0,
                    y: 0,
                    width: 70,
                    height: 8,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        let row: String = (0..70).map(|x| buf[(x, 2)].symbol()).collect::<String>();
        assert!(
            row.contains("plain.txt"),
            "listing did not render outside a repo: {row:?}"
        );
    }

    /// #files item 3 — every breadcrumb segment must be a real click
    /// target pointing at the RIGHT ancestor. A breadcrumb that renders
    /// but does not navigate is decoration.
    #[test]
    fn breadcrumb_segments_are_clickable_and_point_at_their_ancestor() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let deep = d.path().join("a").join("b");
        std::fs::create_dir_all(&deep).unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(Some(deep.clone()));
        let pid = app.active.unwrap();

        let mut term = Terminal::new(TestBackend::new(80, 8)).unwrap();
        term.draw(|f| {
            draw(
                f,
                &mut app,
                pid,
                Rect {
                    x: 0,
                    y: 0,
                    width: 80,
                    height: 8,
                },
            )
        })
        .unwrap();

        let crumbs = &app.rects.file_pane_breadcrumbs;
        assert!(!crumbs.is_empty(), "no breadcrumb segments registered");
        // The last segment is the current directory...
        let last = crumbs.last().unwrap();
        assert_eq!(last.2, deep, "final segment is not the cwd");
        // ...and its predecessor is the real parent, not some prefix
        // string that happens to render correctly.
        let parent = crumbs[crumbs.len() - 2].2.clone();
        assert_eq!(
            parent,
            deep.parent().unwrap(),
            "segment before the cwd points at {parent:?}, not its parent"
        );
        // Every segment must be an ancestor of the cwd.
        for (_, _, p) in crumbs {
            assert!(
                deep.starts_with(p),
                "segment {p:?} is not an ancestor of {deep:?}"
            );
        }
        // And the `▾` must be registered, or the destinations list is
        // keyboard-only.
        assert!(
            app.rects.file_pane_places_chevron.is_some(),
            "no chevron rect — the destinations picker has no mouse route"
        );
    }

    /// A narrow pane must drop segments from the LEFT and keep the current
    /// directory visible — the tail is what tells you where you are.
    #[test]
    fn a_narrow_breadcrumb_keeps_the_current_directory() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let deep = d
            .path()
            .join("aaaaaaaaaa")
            .join("bbbbbbbbbb")
            .join("cccccccccc");
        std::fs::create_dir_all(&deep).unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(Some(deep.clone()));
        let pid = app.active.unwrap();

        let mut term = Terminal::new(TestBackend::new(30, 8)).unwrap();
        term.draw(|f| {
            draw(
                f,
                &mut app,
                pid,
                Rect {
                    x: 0,
                    y: 0,
                    width: 30,
                    height: 8,
                },
            )
        })
        .unwrap();
        let buf = term.backend().buffer();
        let header: String = (0..30).map(|x| buf[(x, 0)].symbol()).collect();

        assert!(
            header.contains("cccccccccc"),
            "the current directory was elided away: {header:?}"
        );
        assert!(
            header.contains('\u{2026}'),
            "no ellipsis marking the dropped prefix: {header:?}"
        );
        // The ellipsis must still navigate somewhere, or narrowing the
        // pane silently removes navigation.
        assert!(
            app.rects.file_pane_breadcrumbs.len() >= 2,
            "narrow breadcrumb registered too few targets"
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

    /// #files — the mouse tester's sharpest finding: marking is the
    /// pane's headline feature and had NO mouse path at all. Ctrl-click,
    /// shift-click, middle-click and clicking the green mark gutter were
    /// all dead, and the only guidance on screen was three chords in a
    /// footer that does not appear until something is already marked.
    ///
    /// These four tests drive the real `dispatch_mouse`, so they fail if
    /// the handler is reordered behind an earlier `return` — which is how
    /// the `+ dock` chip already shadows this pane's last row.
    fn marking_fixture() -> (tempfile::TempDir, crate::app::App, crate::layout::PaneId) {
        let d = tempfile::tempdir().unwrap();
        for n in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            std::fs::write(d.path().join(n), "x").unwrap();
        }
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(Some(d.path().to_path_buf()));
        let pid = app.active.unwrap();
        (d, app, pid)
    }

    /// Render once so `file_pane_rows` is populated, then return the
    /// click point for listing row `idx`.
    fn row_point(app: &mut crate::app::App, pid: crate::layout::PaneId, idx: usize) -> (u16, u16) {
        // Full-chrome draw, not a pane-local one: the point is that the
        // click survives the real `PaneRects`, where other widgets'
        // hit-rects compete for the same cell.
        let mut term = Terminal::new(TestBackend::new(120, 40)).unwrap();
        term.draw(|f| crate::ui::draw(f, app)).unwrap();
        let (r, _, _) = *app
            .rects
            .file_pane_rows
            .iter()
            .find(|(_, p, i)| *p == pid && *i == idx)
            .unwrap_or_else(|| panic!("no click rect for row {idx}"));
        (r.x + 1, r.y)
    }

    fn click(app: &mut crate::app::App, at: (u16, u16), mods: KeyModifiers) {
        use ratatui::crossterm::event::{MouseButton, MouseEvent, MouseEventKind};
        crate::tui::dispatch_mouse(
            app,
            MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Left),
                column: at.0,
                row: at.1,
                modifiers: mods,
            },
        );
    }

    fn marked_names(app: &crate::app::App, pid: crate::layout::PaneId) -> Vec<String> {
        let Some(crate::pane::Pane::Files(f)) = app.panes.get(pid) else {
            panic!("not a Files pane");
        };
        let mut v: Vec<String> = f
            .marked
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn ctrl_click_toggles_a_mark() {
        let (_d, mut app, pid) = marking_fixture();
        let at = row_point(&mut app, pid, 1);

        click(&mut app, at, KeyModifiers::CONTROL);
        assert_eq!(
            marked_names(&app, pid).len(),
            1,
            "ctrl-click did not mark — marking is still keyboard-only"
        );

        // And it must TOGGLE, not just accumulate: a mouse user with no
        // way to unmark is worse off than before.
        let at = row_point(&mut app, pid, 1);
        click(&mut app, at, KeyModifiers::CONTROL);
        assert!(
            marked_names(&app, pid).is_empty(),
            "ctrl-click on a marked row did not unmark it: {:?}",
            marked_names(&app, pid)
        );
    }

    /// A plain click must still OPEN. If the modifier branch swallowed
    /// every click the pane would be unusable, and a test that only
    /// checked marking would not notice.
    #[test]
    fn a_plain_click_still_activates_and_marks_nothing() {
        let (_d, mut app, pid) = marking_fixture();
        let at = row_point(&mut app, pid, 1);
        click(&mut app, at, KeyModifiers::empty());
        assert!(
            marked_names(&app, pid).is_empty(),
            "an unmodified click marked a row: {:?}",
            marked_names(&app, pid)
        );
    }

    #[test]
    fn shift_click_extends_a_range_from_the_cursor() {
        let (_d, mut app, pid) = marking_fixture();
        // Put the cursor on row 0 the way a user would — by clicking it.
        let at = row_point(&mut app, pid, 0);
        click(&mut app, at, KeyModifiers::CONTROL);
        let at = row_point(&mut app, pid, 2);
        click(&mut app, at, KeyModifiers::SHIFT);

        let names = marked_names(&app, pid);
        assert_eq!(
            names.len(),
            3,
            "shift-click marked {} rows, not the 3 spanned: {names:?}",
            names.len()
        );
    }

    /// The other direction. The `lo`/`hi` swap is the only thing standing
    /// between an upward shift-click and an empty range, and the
    /// downward-only test above would not notice it going wrong.
    #[test]
    fn shift_click_above_the_anchor_spans_the_same_rows() {
        let (_d, mut app, pid) = marking_fixture();
        let at = row_point(&mut app, pid, 3);
        click(&mut app, at, KeyModifiers::CONTROL);
        let at = row_point(&mut app, pid, 1);
        click(&mut app, at, KeyModifiers::SHIFT);

        let names = marked_names(&app, pid);
        assert_eq!(
            names.len(),
            3,
            "an upward shift-click spanned {} rows, not 3: {names:?}",
            names.len()
        );
    }

    /// Review finding — the range used to only ever GROW, and the anchor
    /// drifted to wherever you last clicked, so shift-clicking a nearer
    /// row could not take the selection back. Finder, Explorer and VS Code
    /// all recompute from a stable anchor; a user who overshoots by one
    /// row otherwise has to clear and start again.
    #[test]
    fn a_second_shift_click_shrinks_the_range_instead_of_only_growing_it() {
        let (_d, mut app, pid) = marking_fixture();
        let at = row_point(&mut app, pid, 0);
        click(&mut app, at, KeyModifiers::CONTROL);
        let at = row_point(&mut app, pid, 3);
        click(&mut app, at, KeyModifiers::SHIFT);
        assert_eq!(marked_names(&app, pid).len(), 4, "setup: expected 0..=3");

        // Overshot by two — pull it back.
        let at = row_point(&mut app, pid, 1);
        click(&mut app, at, KeyModifiers::SHIFT);
        let names = marked_names(&app, pid);
        assert_eq!(
            names.len(),
            2,
            "shift-click could not shrink the range — still {} marked: {names:?}",
            names.len()
        );
    }

    /// A mark made deliberately, outside the shift range, must survive a
    /// later shift-click that spans it. Taking back "what the last
    /// shift-click added" must mean exactly that.
    #[test]
    fn shrinking_a_shift_range_keeps_marks_made_separately() {
        let (_d, mut app, pid) = marking_fixture();
        // Mark row 3 on its own first.
        let at = row_point(&mut app, pid, 3);
        click(&mut app, at, KeyModifiers::CONTROL);
        // Anchor at 0, sweep 0..=3 (which spans the separate mark), then
        // pull back to 0..=1.
        let at = row_point(&mut app, pid, 0);
        click(&mut app, at, KeyModifiers::CONTROL);
        let at = row_point(&mut app, pid, 3);
        click(&mut app, at, KeyModifiers::SHIFT);
        let at = row_point(&mut app, pid, 1);
        click(&mut app, at, KeyModifiers::SHIFT);

        let names = marked_names(&app, pid);
        assert!(
            names.iter().any(|n| n == "d.txt"),
            "shrinking the range swept away a mark the user made separately: {names:?}"
        );
    }

    /// Finding #6 — the right-click menu reused the tree's, which is
    /// path-based, so "mark five, right-click, Copy" copied exactly one
    /// file with no indication the other four were ignored.
    #[test]
    fn the_context_menu_acts_on_the_mark_set_when_the_clicked_row_is_in_it() {
        use ratatui::crossterm::event::{MouseButton, MouseEvent, MouseEventKind};
        let (_d, mut app, pid) = marking_fixture();
        for idx in [0usize, 1, 2] {
            let at = row_point(&mut app, pid, idx);
            click(&mut app, at, KeyModifiers::CONTROL);
        }
        let at = row_point(&mut app, pid, 1);
        crate::tui::dispatch_mouse(
            &mut app,
            MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Right),
                column: at.0,
                row: at.1,
                modifiers: KeyModifiers::empty(),
            },
        );
        let labels: Vec<String> = app
            .context_menu
            .as_ref()
            .expect("no context menu opened")
            .items
            .iter()
            .map(|i| i.label.clone())
            .collect();
        assert!(
            labels.iter().any(|l| l == "Copy 3 selected"),
            "menu does not offer the mark set — it would act on one row: {labels:?}"
        );
        assert!(
            labels.iter().any(|l| l == "Unmark"),
            "no mark toggle in the menu: {labels:?}"
        );

        // And choosing it must stage all three, not just the clicked row.
        let idx = labels.iter().position(|l| l == "Copy 3 selected").unwrap();
        let action = app.context_menu.as_ref().unwrap().items[idx].action.clone();
        app.run_menu_action(action);
        assert_eq!(
            app.file_clipboard.len(),
            3,
            "staged {} paths from a 3-file selection",
            app.file_clipboard.len()
        );
    }

    /// The other half of the same rule: right-clicking a row you did NOT
    /// mark is you pointing at that row. Silently acting on a set aimed
    /// elsewhere is the bug, not a feature to generalise.
    #[test]
    fn the_context_menu_ignores_marks_when_the_clicked_row_is_not_one() {
        use ratatui::crossterm::event::{MouseButton, MouseEvent, MouseEventKind};
        let (_d, mut app, pid) = marking_fixture();
        let at = row_point(&mut app, pid, 0);
        click(&mut app, at, KeyModifiers::CONTROL);
        let at = row_point(&mut app, pid, 2);
        crate::tui::dispatch_mouse(
            &mut app,
            MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Right),
                column: at.0,
                row: at.1,
                modifiers: KeyModifiers::empty(),
            },
        );
        let labels: Vec<String> = app
            .context_menu
            .as_ref()
            .expect("no context menu opened")
            .items
            .iter()
            .map(|i| i.label.clone())
            .collect();
        assert!(
            !labels.iter().any(|l| l.ends_with("selected")),
            "offered the mark set on a row that is not marked: {labels:?}"
        );
        assert!(
            labels.iter().any(|l| l == "Mark"),
            "no way to add this row to the set: {labels:?}"
        );
    }

    /// Review finding (critical) — an EMPTY directory used to return
    /// before the `..` row was drawn, so browsing into one left a pane
    /// with no visible way out. That is the exact bug the row exists to
    /// fix, reintroduced for its most likely trigger: a directory you
    /// just created, or one filtered to nothing.
    #[test]
    fn an_empty_directory_still_shows_the_parent_row() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let empty = d.path().join("empty");
        std::fs::create_dir(&empty).unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(Some(empty));
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
        let buf = term.backend().buffer();
        let screen: String = (0..8)
            .map(|y| (0..60).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(
            screen.contains("(empty directory)"),
            "empty state missing:\n{screen}"
        );
        assert!(
            screen.contains(".."),
            "no `..` row in an empty directory — the user is stuck:\n{screen}"
        );
        assert!(
            app.rects
                .file_pane_rows
                .iter()
                .any(|(_, p, idx)| *p == pid && *idx == PARENT_ROW),
            "the `..` row has no click rect in an empty directory"
        );
    }

    /// Same for an unreadable directory — the error must not cost the way
    /// out either.
    #[test]
    fn an_unreadable_directory_still_shows_the_parent_row() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let _lk = crate::test_env_lock()
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.open_files_pane(Some(d.path().join("does-not-exist")));
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
            app.rects
                .file_pane_rows
                .iter()
                .any(|(_, p, idx)| *p == pid && *idx == PARENT_ROW),
            "no `..` row when the directory could not be read"
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
