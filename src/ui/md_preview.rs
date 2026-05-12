//! The rendered-markdown preview pane (`Pane::MdPreview`). A line-oriented
//! renderer: headings, lists, fenced code blocks, blockquotes, horizontal rules
//! get block-level styling; inline `**bold**` / `*italic*` / `` `code` `` /
//! `[label](url)` markers are unwrapped to their text (full inline styling is a
//! later refinement). No wrapping yet — long lines clip. Read-only; scrolls.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    _focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    let bg = theme::cur().bg_dark;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(bg)), area);

    let Some(Pane::MdPreview(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    let lines = render_markdown(&p.source);
    let h = area.height as usize;
    let max_scroll = lines.len().saturating_sub(h.min(lines.len()));
    p.scroll = p.scroll.min(max_scroll);
    let scroll = p.scroll;

    // A one-cell left margin so the text isn't flush against the divider.
    let text_area = Rect {
        x: area.x + 1,
        y: area.y,
        width: area.width.saturating_sub(1),
        height: area.height,
    };
    let view: Vec<Line> = lines.into_iter().skip(scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(bg)),
        text_area,
    );

    // Record the pane's rect so a click focuses it / the wheel scrolls it.
    app.rects.editor_panes.push((text_area, pane_id));
    None // no caret in a preview
}

/// Strip inline markdown markers from a run of text, keeping the inner text.
fn unwrap_inline(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let rest = &s[i..];
        if rest.starts_with("**") || rest.starts_with("__") {
            i += 2; // bold markers — drop, keep the inner text
            continue;
        }
        if rest.starts_with('`') || rest.starts_with('*') || rest.starts_with('_') {
            i += 1; // code / italic markers — drop
            continue;
        }
        // [label](url) → "label (url)"
        if rest.starts_with('[')
            && let Some(rb) = rest.find(']')
            && rest[rb..].starts_with("](")
            && let Some(rp) = rest[rb + 2..].find(')')
        {
            let label = &rest[1..rb];
            let url = &rest[rb + 2..rb + 2 + rp];
            out.push_str(label);
            if !url.is_empty() {
                out.push_str(" (");
                out.push_str(url);
                out.push(')');
            }
            i += rb + 2 + rp + 1;
            continue;
        }
        let ch = rest.chars().next().unwrap();
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// Render markdown `src` to styled lines (block-level styling; inline markers unwrapped).
pub fn render_markdown(src: &str) -> Vec<Line<'static>> {
    let t = theme::cur();
    let plain = |s: String| Line::from(Span::styled(s, Style::default().fg(t.fg).bg(t.bg_dark)));
    let mut out: Vec<Line> = Vec::new();
    let mut in_code = false;
    for raw in src.lines() {
        let line = raw;
        let trimmed = line.trim_start();
        // fenced code blocks (the fence line itself isn't rendered)
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_code = !in_code;
            continue;
        }
        if in_code {
            out.push(Line::from(vec![
                Span::styled("▏", Style::default().fg(t.grey_fg).bg(t.bg2)),
                Span::styled(
                    format!(" {line}"),
                    Style::default().fg(t.base16[0x0b]).bg(t.bg2),
                ),
            ]));
            continue;
        }
        // headings
        if let Some(rest) = trimmed.strip_prefix('#') {
            let mut level = 1usize;
            let mut r = rest;
            while let Some(more) = r.strip_prefix('#') {
                level += 1;
                r = more;
                if level >= 6 {
                    break;
                }
            }
            let text = unwrap_inline(r.trim());
            let color = match level {
                1 => t.blue,
                2 => t.cyan,
                3 => t.green,
                4 => t.yellow,
                _ => t.purple,
            };
            let mut style = Style::default()
                .fg(color)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD);
            if level <= 2 {
                style = style.add_modifier(Modifier::UNDERLINED);
            }
            if !out.is_empty() {
                out.push(plain(String::new()));
            }
            out.push(Line::from(Span::styled(text, style)));
            continue;
        }
        // horizontal rule
        let hr = trimmed
            .chars()
            .all(|c| c == '-' || c == '*' || c == '_' || c == ' ');
        if hr && trimmed.chars().filter(|c| !c.is_whitespace()).count() >= 3 {
            out.push(Line::from(Span::styled(
                "─".repeat(40),
                Style::default().fg(t.grey).bg(t.bg_dark),
            )));
            continue;
        }
        // blockquote
        if let Some(q) = trimmed.strip_prefix('>') {
            out.push(Line::from(vec![
                Span::styled("▏ ", Style::default().fg(t.purple).bg(t.bg_dark)),
                Span::styled(
                    unwrap_inline(q.trim_start()),
                    Style::default()
                        .fg(t.comment)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::ITALIC),
                ),
            ]));
            continue;
        }
        // list items (preserve the source's leading indentation)
        let indent: String = line.chars().take_while(|c| *c == ' ').collect();
        if let Some(item) = trimmed
            .strip_prefix("- ")
            .or_else(|| trimmed.strip_prefix("* "))
            .or_else(|| trimmed.strip_prefix("+ "))
        {
            out.push(Line::from(vec![
                Span::styled(
                    format!("{indent}• "),
                    Style::default().fg(t.blue).bg(t.bg_dark),
                ),
                Span::styled(unwrap_inline(item), Style::default().fg(t.fg).bg(t.bg_dark)),
            ]));
            continue;
        }
        if let Some(dot) = trimmed.find(". ")
            && trimmed[..dot].chars().all(|c| c.is_ascii_digit())
            && !trimmed[..dot].is_empty()
        {
            let num = &trimmed[..dot];
            out.push(Line::from(vec![
                Span::styled(
                    format!("{indent}{num}. "),
                    Style::default().fg(t.blue).bg(t.bg_dark),
                ),
                Span::styled(
                    unwrap_inline(&trimmed[dot + 2..]),
                    Style::default().fg(t.fg).bg(t.bg_dark),
                ),
            ]));
            continue;
        }
        // plain paragraph line
        out.push(plain(unwrap_inline(line)));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unwrap_inline_strips_markers() {
        assert_eq!(
            unwrap_inline("a **bold** and `code` and *it*"),
            "a bold and code and it"
        );
        assert_eq!(
            unwrap_inline("see [the docs](http://x) ok"),
            "see the docs (http://x) ok"
        );
        assert_eq!(unwrap_inline("plain text"), "plain text");
    }

    #[test]
    fn render_handles_blocks() {
        let md = "# Title\n\nsome **text**\n\n- one\n- two\n\n```\ncode\n```\n> a quote\n---\n";
        let lines = render_markdown(md);
        // produced *something* for each block; not empty
        assert!(lines.len() >= 6, "got {} lines", lines.len());
    }
}
