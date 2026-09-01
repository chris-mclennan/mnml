//! TODOs activity-bar panel — surfaces `TODO` / `FIXME` / `XXX` /
//! `HACK` / `REVIEW` markers found in source-code comments across
//! the workspace. (#9)
//!
//! v1 scope: workspace-wide scan on activation + rescan via
//! `todos.refresh`. One row per hit: `TAG  path:line  title`.
//! Click → jump to the file at that line. Deletion / test-tags /
//! `.mnml/notes/` markdown checkbox integration are follow-ups.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph},
};

use crate::app::App;
use crate::ui::theme;

/// One found marker. Populated by `App::todos_panel_refresh`.
#[derive(Debug, Clone)]
pub struct TodoHit {
    pub tag: &'static str,
    pub path: std::path::PathBuf,
    pub line: u32,
    pub title: String,
}

/// Marker patterns scanned in comments. Case-sensitive, matched
/// followed by non-alphanumeric so `TODOLIST` doesn't false-trip.
pub const MARKERS: &[&str] = &["TODO", "FIXME", "XXX", "HACK", "REVIEW"];

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    app.rects.todos_panel_rows.clear();
    app.rects.todos_panel_refresh_chip = None;
    app.rects.todos_panel_filter_input = None;
    app.rects.todos_panel_kebab = None;

    // Trigger a background rescan the first time this panel appears
    // in a session (todos_hits is empty and no scan yet).
    if !app.todos_panel_scanned_once {
        app.todos_panel_scanned_once = true;
        app.todos_panel_refresh();
    }

    // Apply the `/`-filter to the hit list — matches tag, path, or
    // title case-insensitively. Filter row is drawn between the
    // section header and the results (parity with HTTP / Agents).
    let filter_lc = app.todos_panel_filter.to_ascii_lowercase();
    let filtered: Vec<(usize, &TodoHit)> = app
        .todos_hits
        .iter()
        .enumerate()
        .filter(|(_, hit)| {
            if filter_lc.is_empty() {
                return true;
            }
            hit.tag.to_ascii_lowercase().contains(&filter_lc)
                || hit
                    .path
                    .to_string_lossy()
                    .to_ascii_lowercase()
                    .contains(&filter_lc)
                || hit.title.to_ascii_lowercase().contains(&filter_lc)
        })
        .collect();

    // 2026-08-24 (user ask) — TODOS header now sits alongside a
    // right-aligned ↻ Refresh chip (was a bottom-of-panel
    // "Rescan" row that didn't match the git-panel refresh idiom
    // a scroll away). Routed through the shared
    // `panel_chrome::draw_caps_header_with_refresh` helper so
    // every future panel that wants a refresh chip gets the same
    // shape.
    // 2026-08-24 (user ask) — always show a count-in-parens
    // (parity with FINDINGS): total when unfiltered, `M of N`
    // when a filter narrows it.
    let subtitle = if filter_lc.is_empty() {
        format!("  ({})", app.todos_hits.len())
    } else {
        format!("  ({} of {})", filtered.len(), app.todos_hits.len())
    };
    app.rects.todos_panel_refresh_chip = crate::ui::panel_chrome::draw_caps_header_with_refresh(
        frame,
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
        "TODOS",
        Some(&subtitle),
        bg,
        &t,
        app.config.ui.ascii_icons,
    );
    // Filter row (row 1). Matches `http_panel::draw` visual — chip
    // background, magnifier glyph, `/ filter` placeholder, `▏` cursor
    // when focused.
    {
        let y_filter = area.y + 1;
        if y_filter < area.y + area.height {
            let focused = app.todos_panel_filter_focused;
            let bg_chip = crate::ui::panel_chrome::filter_chip_bg(&t);
            let fg_chip = if app.todos_panel_filter.is_empty() && !focused {
                t.comment
            } else {
                t.fg
            };
            let display = if app.todos_panel_filter.is_empty() {
                crate::ui::filter_placeholder::for_state(focused).to_string()
            } else {
                app.todos_panel_filter.clone()
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
            app.rects.todos_panel_filter_input = Some(row_rect);
        }
    }
    // R16 design-critic (2026-08-24) — `area.y + 3` (blank row under
    // filter) is intentional: TODOS has no `+ New todo` CTA chip like
    // NOTES/SESSIONS do, so the row acts as breathing room instead of
    // a chip slot. Matches `findings_panel.rs`.
    let mut y = area.y + 3;

    if app.todos_hits.is_empty() {
        // Interpolate the same glyph the header refresh chip uses
        // so the hint stays in sync in every mode.
        let ascii = app.config.ui.ascii_icons;
        let hint_msg = format!(
            "No markers found — click {} in the header to rescan.",
            crate::ui::refresh_glyph::for_ascii(ascii)
        );
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(hint_msg, Style::default().fg(t.comment).bg(bg)),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    "Scans for TODO / FIXME / XXX / HACK / REVIEW.",
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
            ])),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 2;
    } else if filtered.is_empty() {
        crate::ui::empty_state::draw(
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
        y += 2;
    } else {
        // Clamp the cursor to the filtered length so a stale
        // cursor after a filter narrows doesn't paint nothing.
        let clamped_cursor = app.todos_panel_cursor.min(filtered.len().saturating_sub(1));
        app.todos_panel_cursor = clamped_cursor;
        for (row_i, (idx, hit)) in filtered
            .iter()
            .copied()
            .take(area.height.saturating_sub(5) as usize)
            .enumerate()
        {
            if y >= area.y + area.height {
                break;
            }
            let is_focused_row = row_i == clamped_cursor;
            let row_bg = if is_focused_row { t.bg2 } else { bg };
            let rel = hit
                .path
                .strip_prefix(&app.workspace)
                .unwrap_or(&hit.path)
                .to_string_lossy()
                .into_owned();
            let tag_fg = match hit.tag {
                "TODO" => t.blue,
                "FIXME" => t.orange,
                "XXX" | "HACK" => t.red,
                "REVIEW" => t.purple,
                _ => t.comment,
            };
            let row_rect = Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            };
            let path_line = format!(" {rel}:{}", hit.line);
            // Budget the text against the ROW WIDTH, not a fixed 40
            // characters. The old constant meant a long path pushed the
            // title straight through the right border (user report:
            // "the todos area has same issue where text goes to the
            // right all the way up against the border").
            //
            // `RIGHT_PAD` is the blank cell the user asked for; the
            // kebab is drawn over the row's right edge on the focused
            // row, so it needs that gap too.
            const RIGHT_PAD: usize = 2;
            const MIN_TITLE: usize = 8;
            let budget = (area.width as usize).saturating_sub(RIGHT_PAD);
            let lead = 2 + hit.tag.chars().count() + 1;
            // Clip the path first if it alone would fill the row, so a
            // deep path can never squeeze the title out entirely.
            let path_budget = budget.saturating_sub(lead + MIN_TITLE);
            let path_line: String = if path_line.chars().count() > path_budget {
                let keep = path_budget.saturating_sub(1);
                path_line.chars().take(keep).collect::<String>() + "\u{2026}"
            } else {
                path_line
            };
            let title_budget = budget.saturating_sub(lead + path_line.chars().count());
            let title: String = hit.title.chars().take(title_budget.min(40)).collect();
            // Pad the highlight across to the kebab.
            //
            // The band used to close one cell past the title, which was
            // right until the actions kebab appeared at the row's right
            // edge — then a focused row read as a highlighted stretch, a
            // dead gap, and a floating kebab. The row's content now ends
            // AT the kebab, so the band runs to it (user report).
            //
            // `- 2` leaves the kebab's own two cells, which paint with
            // the same background, so the run is continuous.
            let used =
                2 + hit.tag.chars().count() + path_line.chars().count() + 1 + title.chars().count();
            let pad = (area.width as usize).saturating_sub(used + RIGHT_PAD);
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    // The selection highlight is INSET by one cell rather
                    // than running to the panel edge, and closes one cell
                    // past the last character. It used to start at column
                    // 0, so a focused row read as a full-width band
                    // welded to the panel's left edge (user report).
                    //
                    // Text still begins at column 2, matching FINDINGS /
                    // NOTES list rows and this panel's own hint rows —
                    // the first of those two cells is simply outside the
                    // highlight now.
                    // Two unhighlighted cells, then the band. Matches
                    // FINDINGS / NOTES at 3 cells to the text.
                    Span::styled(" ", Style::default().bg(bg)),
                    // The focused row's accent bar. mnml marks a selected
                    // row with a blue `▌` everywhere else it has one —
                    // the palette picker, the activity bar, the sessions
                    // panel, the Claude accounts view. This panel
                    // RESERVED the column but never painted the bar, so
                    // the only cue was a background shift, and the gutter
                    // read as empty space (user report: "when i think
                    // gutter i was thinking vertical COLORED bar like we
                    // do in sessions view").
                    Span::styled(
                        if is_focused_row { "▌" } else { " " },
                        Style::default().fg(t.blue).bg(row_bg),
                    ),
                    Span::styled(
                        hit.tag,
                        Style::default()
                            .fg(tag_fg)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(path_line, Style::default().fg(t.comment).bg(row_bg)),
                    Span::styled(" ", Style::default().bg(row_bg)),
                    Span::styled(title, Style::default().fg(t.fg).bg(row_bg)),
                    // Runs to the kebab rather than stopping at the
                    // text — see `pad` above.
                    Span::styled(" ".repeat(pad), Style::default().bg(row_bg)),
                ])),
                row_rect,
            );
            // The FILTERED position, not the index into `todos_hits`.
            // `todos_panel_cursor` indexes the filtered list, so storing
            // the raw index made a click set the cursor to a different
            // TODO than the one clicked whenever a filter was active.
            let _ = idx;
            // Actions kebab, focused row only — the hover-reveal idiom
            // the `+` menu uses. Visible when you are on the row, no
            // marker repeated down all thirty-nine, and it leaves the
            // other rows their full width for the path.
            if is_focused_row && area.width > 4 {
                let kr = Rect {
                    x: area.x + area.width - 2,
                    y,
                    width: 2,
                    height: 1,
                };
                frame.render_widget(
                    Paragraph::new(Line::from(Span::styled(
                        if app.config.ui.ascii_icons {
                            ": "
                        } else {
                            "\u{22ee} "
                        },
                        Style::default().fg(t.comment).bg(row_bg),
                    ))),
                    kr,
                );
                app.rects.todos_panel_kebab = Some((kr, row_i));
            }
            app.rects.todos_panel_rows.push((row_rect, row_i));
            y += 1;
        }
        y += 1;
    }

    // 2026-08-24 (user ask) — Rescan chip moved from a bottom-of-
    // panel row into the top-right of the TODOS caps header via
    // `panel_chrome::draw_caps_header_with_refresh` so it lines up
    // with the git panel's refresh chip a scroll away. The rect
    // now populates from the header helper above.
    let _ = y;
}

/// Grab the first double-quoted or single-quoted string on the
/// slice — the Playwright/Jest test title when the modifier call
/// looks like `.fixme("title", async ({ page }) => …)`.
fn extract_first_quoted(s: &str) -> Option<String> {
    let mut chars = s.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        if c == '"' || c == '\'' {
            let quote = c;
            let start = i + c.len_utf8();
            for (j, cc) in chars.by_ref() {
                if cc == quote {
                    return Some(s[start..j].chars().take(120).collect());
                }
            }
            return None;
        }
    }
    None
}

/// Playwright/Jest test-modifier markers picked up in `.spec.ts`,
/// `.test.ts`, `.spec.js`, `.test.js`. These are call-site tokens
/// (`test.fixme(...)`, `test.fail(...)`, `test.skip(...)`) that
/// tag a test as pending / expected-to-fail / disabled — user
/// feedback: they belong in the TODOs surface even though they're
/// not in a comment.
const TEST_MODIFIER_MARKERS: &[&str] = &["fixme", "fail", "skip"];

fn is_playwright_test_file(path: &std::path::Path) -> bool {
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    name.ends_with(".spec.ts")
        || name.ends_with(".test.ts")
        || name.ends_with(".spec.js")
        || name.ends_with(".test.js")
}

/// Scan a file for marker patterns in comments. Cheap enough per
/// file for a workspace-wide scan (~200 typical), but skips large
/// files, binaries, and generated dirs.
pub fn scan_file(path: &std::path::Path) -> Vec<TodoHit> {
    let Ok(meta) = std::fs::metadata(path) else {
        return Vec::new();
    };
    if meta.len() > 1024 * 1024 {
        return Vec::new(); // skip huge files
    }
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new(); // non-UTF-8 → binary → skip
    };
    let is_markdown = path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("md") || e.eq_ignore_ascii_case("markdown"));
    let mut out = Vec::new();
    let scan_test_modifiers = is_playwright_test_file(path);
    for (i, line) in content.lines().enumerate() {
        // Playwright/Jest test modifiers first — `.fixme(` / `.fail(`
        // / `.skip(` are call-site tokens, not comment markers, so
        // they get their own detection path per line. FIXME wins
        // (higher-severity mapping) if both match.
        if scan_test_modifiers {
            let mut matched = false;
            for &modifier in TEST_MODIFIER_MARKERS {
                let needle = format!(".{modifier}(");
                if let Some(pos) = line.find(&needle) {
                    let tag: &'static str = match modifier {
                        "fixme" => "FIXME",
                        "fail" => "XXX",
                        "skip" => "REVIEW",
                        _ => continue,
                    };
                    let after = pos + needle.len();
                    // Grab the test title if the call is
                    // `.fixme("title", …)` — first quoted string on
                    // the same line.
                    let title = extract_first_quoted(&line[after..])
                        .unwrap_or_else(|| format!(".{modifier}(...)"));
                    out.push(TodoHit {
                        tag,
                        path: path.to_path_buf(),
                        line: (i + 1) as u32,
                        title,
                    });
                    matched = true;
                    break;
                }
            }
            if matched {
                continue;
            }
        }
        for &tag in MARKERS {
            if let Some(pos) = line.find(tag) {
                // Rough "is this in a comment?" heuristic: at least
                // one comment char (`//`, `#`, `/*`, `--`, `<!--`)
                // appears BEFORE the marker on the same line.
                let prefix = &line[..pos];
                let looks_like_comment = prefix.contains("//")
                    || prefix.contains('#')
                    || prefix.contains("/*")
                    || prefix.contains("--")
                    || prefix.contains("<!--");
                // MARKDOWN has no code comments — a `- TODO: …` line in
                // prose IS the item, and requiring a comment char meant
                // a whole TODO.md scanned to a single hit: the `#` in
                // its own title heading. Accept a marker preceded only
                // by list / heading / quote punctuation.
                //
                // Still anchored to the START of the line, so a passing
                // mention of TODO mid-sentence is not collected.
                let markdown_item = is_markdown
                    && prefix
                        .trim_start_matches(|c: char| {
                            c.is_whitespace()
                                || c.is_ascii_digit()
                                || matches!(c, '-' | '*' | '+' | '#' | '>' | '.' | ')' | '[' | ']')
                        })
                        .is_empty();
                if !looks_like_comment && !markdown_item {
                    continue;
                }
                // Confirm word-boundary on the right so `TODOLIST`
                // doesn't match `TODO`.
                let after = line[pos + tag.len()..].chars().next();
                if let Some(c) = after
                    && (c.is_alphanumeric() || c == '_')
                {
                    continue;
                }
                let title: String = line[pos + tag.len()..]
                    .trim_start_matches([':', '(', ')', ' '])
                    .trim()
                    .chars()
                    .take(120)
                    .collect();
                out.push(TodoHit {
                    tag,
                    path: path.to_path_buf(),
                    line: (i + 1) as u32,
                    title,
                });
                break; // one marker per line
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// User report — the focused row's highlight started at column 0, so
    /// it read as a full-width band welded to the panel's left edge; and
    /// once the actions kebab appeared at the right edge, closing the
    /// band just past the title left a dead gap with a floating kebab
    /// beyond it. It should be inset one cell on the left and run
    /// CONTINUOUSLY to the kebab on the right.
    #[test]
    fn the_focused_rows_highlight_is_inset_and_runs_to_the_kebab() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.todos_panel_scanned_once = true;
        app.todos_hits = vec![TodoHit {
            tag: "TODO",
            path: d.path().join("a.rs"),
            line: 1,
            title: "x".into(),
        }];

        let w = 80u16;
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

        let buf = term.backend().buffer();
        let panel_bg = theme::cur().bg_darker;
        let hl = theme::cur().bg2;
        let mut row_y = None;
        for y in 0..12u16 {
            let line: String = (0..w).map(|x| buf[(x, y)].symbol()).collect();
            if line.contains("TODO") && !line.contains("TODOS") {
                row_y = Some(y);
                break;
            }
        }
        let y = row_y.expect("no list row rendered");

        assert_eq!(
            buf[(0, y)].bg,
            panel_bg,
            "column 0 is highlighted — the band still touches the panel edge"
        );
        assert_eq!(
            buf[(1, y)].bg,
            hl,
            "the highlight does not start at column 1 — the list rows sit one \
             cell in, so the accent lands under the filter row's magnifier"
        );

        // Continuous from column 1 through the kebab: no unhighlighted
        // gap between the text and the kebab.
        let gaps: Vec<u16> = (1..w - 1).filter(|&x| buf[(x, y)].bg != hl).collect();
        assert!(
            gaps.is_empty(),
            "unhighlighted gap(s) at columns {gaps:?} — the band stops \
             before the kebab instead of running to it"
        );
        // The kebab itself is inside the band, and is a click target.
        assert!(
            app.rects.todos_panel_kebab.is_some(),
            "the focused row shows no actions kebab"
        );

        // The focused row carries the blue `▌` accent at column 2 — the
        // selected-row idiom mnml uses in the palette picker, the
        // activity bar and the sessions panel. The gutter column was
        // reserved but never painted, so a focused row was distinguished
        // only by its background: "when i think gutter i was thinking
        // vertical COLORED bar like we do in sessions view".
        assert_eq!(
            buf[(1, y)].symbol(),
            "▌",
            "the focused row has no accent bar in its gutter"
        );
        assert_eq!(
            buf[(1, y)].fg,
            theme::cur().blue,
            "the accent bar is not the blue every other selected-row \
             marker in mnml uses"
        );
    }

    /// USER REPORT — after 9 items were appended to TODO.md the panel
    /// count moved by ONE. "where are yours on this list, those 9".
    ///
    /// `scan_file` required a comment character before the marker, so a
    /// markdown list item (`- TODO: …`) never matched; the only hit in
    /// a whole TODO.md was the `#` in its own title heading.
    #[test]
    fn markdown_list_items_are_collected_without_a_comment_char() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("TODO.md");
        std::fs::write(
            &f,
            "# mnml TODO\n\n             - TODO: first queued item\n             - TODO: second queued item\n             * FIXME: a starred one\n             1. TODO: a numbered one\n             > TODO: a quoted one\n",
        )
        .unwrap();
        let hits = scan_file(&f);
        assert!(
            hits.len() >= 6,
            "markdown TODOs were skipped — only {} hit(s): {:?}",
            hits.len(),
            hits.iter().map(|h| h.title.clone()).collect::<Vec<_>>()
        );
    }

    /// ...but a passing MENTION mid-sentence is still not an item, or
    /// every doc discussing TODOs would flood the panel.
    #[test]
    fn a_mid_sentence_mention_in_markdown_is_not_collected() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("notes.md");
        std::fs::write(
            &f,
            "The scanner looks for TODO markers in comments.\n             Nothing here should be collected.\n",
        )
        .unwrap();
        let hits = scan_file(&f);
        assert!(
            hits.is_empty(),
            "a prose mention was collected as an item: {:?}",
            hits.iter().map(|h| h.title.clone()).collect::<Vec<_>>()
        );
    }

    /// Code files must be UNCHANGED — the comment requirement is what
    /// stops `let todo = ...` from being collected there.
    #[test]
    fn code_files_still_require_a_comment_char() {
        let d = tempfile::tempdir().unwrap();
        let f = d.path().join("a.rs");
        std::fs::write(
            &f,
            "let TODO_LIST = 1;\nlet x = \"TODO: not a comment\";\n// TODO: a real one\n",
        )
        .unwrap();
        let hits = scan_file(&f);
        assert_eq!(
            hits.len(),
            1,
            "expected only the commented marker, got: {:?}",
            hits.iter().map(|h| h.title.clone()).collect::<Vec<_>>()
        );
    }

    /// USER REPORT — "the todos area has same issue where text goes to
    /// the right all the way up against the border."
    ///
    /// The title was clipped to a fixed 40 chars regardless of panel
    /// width, so a long path pushed the row straight through the edge.
    #[test]
    fn a_long_row_keeps_a_blank_cell_before_the_right_border() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.todos_panel_scanned_once = true;
        app.todos_hits = vec![TodoHit {
            tag: "REVIEW",
            path: d.path().join("src/app/a_very_deeply_nested_module_path.rs"),
            line: 1998,
            title: "a title long enough to run past any sane panel width".into(),
        }];

        // Narrow, like the real activity panel.
        let w = 34u16;
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
        let buf = term.backend().buffer();

        let mut saw_row = false;
        for y in 0..12u16 {
            let line: String = (0..w).map(|x| buf[(x, y)].symbol()).collect();
            if !line.contains("REVIEW") {
                continue;
            }
            saw_row = true;
            // The assertion is that the TITLE SURVIVES, not that the
            // last cell is blank.
            //
            // A blank last cell proves nothing: ratatui clips at the
            // rect either way, so that held with the fix removed too —
            // the first version of this test passed against the bug.
            // What actually breaks without the width-derived budget is
            // that a long path consumes the whole row and the title is
            // pushed out entirely, which is the difference the user
            // sees.
            assert!(
                line.contains("a title"),
                "the path consumed the row and the title vanished:\n{line:?}"
            );
            assert!(
                line.contains('\u{2026}'),
                "the path was hard-clipped instead of elided:\n{line:?}"
            );
        }
        assert!(saw_row, "no TODO row rendered at all");
    }

    /// User report — "the list appears too far left, shift 1 cell right".
    ///
    /// The list rows carried a one-cell indent while FINDINGS and NOTES
    /// list rows, and this panel's own hint and empty-state rows, all
    /// used two. Asserted against a sibling panel rather than a literal
    /// so the two cannot drift apart again silently.
    #[test]
    fn list_rows_are_indented_like_the_sibling_panels() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let mut app =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        app.config.ui.ascii_icons = true;
        app.todos_panel_scanned_once = true; // don't kick off a rescan
        app.todos_hits = vec![TodoHit {
            tag: "TODO",
            path: d.path().join("src/thing.rs"),
            line: 12,
            title: "wire the thing".into(),
        }];

        let mut term = Terminal::new(TestBackend::new(80, 12)).unwrap();
        term.draw(|f| {
            draw(
                f,
                &mut app,
                Rect {
                    x: 0,
                    y: 0,
                    width: 80,
                    height: 12,
                },
            )
        })
        .unwrap();

        let buf = term.backend().buffer();
        let rows: Vec<String> = (0..12)
            .map(|y| (0..80).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect();
        // "TODOS" is the caps header; the list row is the other one.
        let todo_row = rows
            .iter()
            .find(|r| r.contains("TODO") && !r.contains("TODOS"))
            .unwrap_or_else(|| panic!("no TODO row rendered:\n{}", rows.join("\n")));
        // Where the TEXT begins — not the leading-space count, which
        // stopped measuring the indent once the focused row's accent
        // bar started occupying the third gutter cell.
        let text_start = |row: &str| {
            row.chars()
                .position(|c| c != ' ' && c != '▌')
                .unwrap_or(usize::MAX)
        };
        let todos_col = text_start(todo_row);

        // Render NOTES and compare against it directly. The docstring
        // above has always claimed this was "asserted against a sibling
        // panel"; it asserted a literal `3`, so the two could drift
        // apart in either direction without this test noticing.
        let mut napp =
            crate::app::App::new(d.path().to_path_buf(), crate::config::Config::default()).unwrap();
        napp.config.ui.ascii_icons = true;
        let nd = crate::ui::notes_panel::notes_dir(d.path());
        std::fs::create_dir_all(&nd).unwrap();
        std::fs::write(nd.join("zzmarker.md"), "x").unwrap();
        napp.notes_panel_files_cache = vec![nd.join("zzmarker.md")];
        napp.notes_panel_scanned_once = true;
        let mut nterm = Terminal::new(TestBackend::new(80, 12)).unwrap();
        nterm
            .draw(|f| {
                crate::ui::notes_panel::draw(
                    f,
                    &mut napp,
                    Rect {
                        x: 0,
                        y: 0,
                        width: 80,
                        height: 12,
                    },
                )
            })
            .unwrap();
        let nbuf = nterm.backend().buffer();
        let notes_row: String = (0..12)
            .map(|y| (0..80).map(|x| nbuf[(x, y)].symbol()).collect::<String>())
            .find(|r| r.contains("zzmarker"))
            .expect("no NOTES list row rendered");
        let notes_col = text_start(&notes_row);

        assert_eq!(
            todos_col, notes_col,
            "TODOS text starts at column {todos_col}, NOTES at {notes_col} — \
             the sibling panels have drifted apart:\n{todo_row:?}\n{notes_row:?}"
        );
        assert_eq!(
            todos_col, 2,
            "list text should start at column 2 (one inset cell + the \
             accent-bar cell, which sits under the filter magnifier):\n{todo_row:?}"
        );
    }

    #[test]
    fn playwright_scanner_picks_up_fixme_and_fail_and_skip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("example.spec.ts");
        std::fs::write(
            &path,
            r#"import { test } from '@playwright/test';

test.fixme('renders survey card', async ({ page }) => {
  await page.goto('/');
});

test.fail('editor accepts nested lists', async ({ page }) => {
  await page.goto('/');
});

test.skip('legacy filter', async ({ page }) => { });
"#,
        )
        .unwrap();
        let hits = scan_file(&path);
        assert_eq!(hits.len(), 3);
        assert_eq!(hits[0].tag, "FIXME");
        assert_eq!(hits[0].title, "renders survey card");
        assert_eq!(hits[1].tag, "XXX");
        assert_eq!(hits[1].title, "editor accepts nested lists");
        assert_eq!(hits[2].tag, "REVIEW");
        assert_eq!(hits[2].title, "legacy filter");
    }

    #[test]
    fn playwright_scanner_ignores_regular_files() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("index.ts");
        std::fs::write(&path, "// TODO: hook this up\nconst x = 1;\n").unwrap();
        let hits = scan_file(&path);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].tag, "TODO");
    }

    #[test]
    fn extract_first_quoted_handles_single_and_double_quotes() {
        assert_eq!(
            extract_first_quoted(r#"("hello", async () => {})"#),
            Some("hello".to_string())
        );
        assert_eq!(
            extract_first_quoted(r#"('hi there', () => {})"#),
            Some("hi there".to_string())
        );
        assert_eq!(extract_first_quoted("(no quotes here)"), None);
    }
}
