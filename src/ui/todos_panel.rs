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

    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "TODOs",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                if filter_lc.is_empty() {
                    format!("  ({} hits)", app.todos_hits.len())
                } else {
                    format!("  ({} of {} hits)", filtered.len(), app.todos_hits.len())
                },
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
        ])),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );
    // Filter row (row 1). Matches `http_panel::draw` visual — chip
    // background, magnifier glyph, `/ filter` placeholder, `▏` cursor
    // when focused.
    {
        let y_filter = area.y + 1;
        if y_filter < area.y + area.height {
            let focused = app.todos_panel_filter_focused;
            let bg_chip = t.bg2;
            let fg_chip = if app.todos_panel_filter.is_empty() && !focused {
                t.comment
            } else {
                t.fg
            };
            let display = if app.todos_panel_filter.is_empty() {
                if focused {
                    "type to filter\u{2026}".to_string()
                } else {
                    "/ filter".to_string()
                }
            } else {
                app.todos_panel_filter.clone()
            };
            let cursor = if focused { "\u{258F}" } else { " " };
            let pad = (area.width as usize).saturating_sub(3 + display.chars().count() + 1 + 1);
            let line = Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled("\u{F0349} ", Style::default().fg(t.comment).bg(bg_chip)),
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
    let mut y = area.y + 3;

    if app.todos_hits.is_empty() {
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    "No markers found — click ⟳ Rescan below.",
                    Style::default().fg(t.comment).bg(bg),
                ),
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
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    "No matches — try clearing the filter (Esc).",
                    Style::default().fg(t.comment).bg(bg),
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
    } else {
        for (idx, hit) in filtered
            .iter()
            .copied()
            .take(area.height.saturating_sub(5) as usize)
        {
            if y >= area.y + area.height {
                break;
            }
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
            let title: String = hit.title.chars().take(40).collect();
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(" ", Style::default().bg(bg)),
                    Span::styled(
                        hit.tag,
                        Style::default()
                            .fg(tag_fg)
                            .bg(bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(path_line, Style::default().fg(t.comment).bg(bg)),
                    Span::styled(" ", Style::default().bg(bg)),
                    Span::styled(title, Style::default().fg(t.fg).bg(bg)),
                ])),
                row_rect,
            );
            app.rects.todos_panel_rows.push((row_rect, idx));
            y += 1;
        }
        y += 1;
    }

    if y < area.y + area.height {
        let refresh_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(Line::from(vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(
                    // `⟳` eats its right sidebearing in Nerd Font +
                    // CoreText; a 2-space gap keeps it visually
                    // matched to other action rows in the app.
                    "⟳  Rescan",
                    Style::default()
                        .fg(t.cyan)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD),
                ),
            ])),
            refresh_rect,
        );
        app.rects.todos_panel_refresh_chip = Some(refresh_rect);
    }
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
                if !looks_like_comment {
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
