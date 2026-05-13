//! The rendered-markdown preview pane (`Pane::MdPreview`). A line-oriented
//! renderer: headings, lists, fenced code blocks, blockquotes, horizontal rules
//! get block-level styling; inline `**bold**` / `*italic*` / `` `code` `` /
//! `[label](url)` are rendered as styled spans. Long lines are word-wrapped to
//! the pane width ([`wrap_lines`], with a hanging indent for lists/quotes).
//! Read-only; scrolls.

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
    // A one-cell left margin so the text isn't flush against the divider.
    let text_area = Rect {
        x: area.x + 1,
        y: area.y,
        width: area.width.saturating_sub(1),
        height: area.height,
    };
    let lines = wrap_lines(render_markdown(&p.source), text_area.width as usize);
    let h = area.height as usize;
    let max_scroll = lines.len().saturating_sub(h.min(lines.len()));
    p.scroll = p.scroll.min(max_scroll);
    let scroll = p.scroll;

    let view: Vec<Line> = lines.into_iter().skip(scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(bg)),
        text_area,
    );

    // Record the pane's rect so a click focuses it / the wheel scrolls it.
    app.rects.editor_panes.push((text_area, pane_id));
    None // no caret in a preview
}

fn push_text(out: &mut Vec<Span<'static>>, buf: &mut String, style: Style) {
    if !buf.is_empty() {
        out.push(Span::styled(std::mem::take(buf), style));
    }
}

/// Parse a run of text into styled spans, honouring `**bold**`, `*italic*`,
/// `` `code` ``, and `[label](url)` links. `base` is the style for plain text
/// (it carries the fg/bg from the surrounding block, so e.g. a list item's text
/// stays on the list line's background). Underscores are left literal — they're
/// far more often `snake_case` than markdown emphasis.
fn inline_spans(s: &str, base: Style) -> Vec<Span<'static>> {
    let t = theme::cur();
    let code_style = Style::default().fg(t.base16[0x0b]).bg(t.bg2);
    let link_style = base.fg(t.cyan).add_modifier(Modifier::UNDERLINED);
    let url_style = Style::default().fg(t.comment).bg(t.bg_dark);

    let mut out: Vec<Span> = Vec::new();
    let mut buf = String::new();
    let mut i = 0;
    while i < s.len() {
        let rest = &s[i..];

        // strong: **...**
        if let Some(after) = rest.strip_prefix("**")
            && let Some(end) = after.find("**")
            && end > 0
        {
            push_text(&mut out, &mut buf, base);
            out.push(Span::styled(
                after[..end].to_string(),
                base.add_modifier(Modifier::BOLD),
            ));
            i += 2 + end + 2;
            continue;
        }
        // code: `...`
        if rest.starts_with('`')
            && let Some(end) = rest[1..].find('`')
            && end > 0
        {
            push_text(&mut out, &mut buf, base);
            out.push(Span::styled(rest[1..1 + end].to_string(), code_style));
            i += 1 + end + 1;
            continue;
        }
        // italic: *...* (single asterisk; `**` was handled above)
        if rest.starts_with('*')
            && !rest.starts_with("**")
            && let Some(end) = rest[1..].find('*')
            && end > 0
            && !rest[1..1 + end].starts_with(' ')
        {
            push_text(&mut out, &mut buf, base);
            out.push(Span::styled(
                rest[1..1 + end].to_string(),
                base.add_modifier(Modifier::ITALIC),
            ));
            i += 1 + end + 1;
            continue;
        }
        // link: [label](url)
        if rest.starts_with('[')
            && let Some(rb) = rest.find(']')
            && rest[rb..].starts_with("](")
            && let Some(rp) = rest[rb + 2..].find(')')
        {
            let label = &rest[1..rb];
            let url = &rest[rb + 2..rb + 2 + rp];
            push_text(&mut out, &mut buf, base);
            out.push(Span::styled(label.to_string(), link_style));
            if !url.is_empty() && url != label {
                out.push(Span::styled(format!(" ({url})"), url_style));
            }
            i += rb + 2 + rp + 1;
            continue;
        }

        let ch = rest.chars().next().unwrap();
        buf.push(ch);
        i += ch.len_utf8();
    }
    push_text(&mut out, &mut buf, base);
    if out.is_empty() {
        out.push(Span::styled(String::new(), base));
    }
    out
}

/// Build a styled line from an optional prefix span plus inline-parsed `text`.
fn styled_line(prefix: Option<Span<'static>>, text: &str, base: Style) -> Line<'static> {
    let mut spans = Vec::new();
    if let Some(p) = prefix {
        spans.push(p);
    }
    spans.extend(inline_spans(text, base));
    Line::from(spans)
}

/// Render markdown `src` to styled lines (block-level styling + inline spans).
pub fn render_markdown(src: &str) -> Vec<Line<'static>> {
    let t = theme::cur();
    let body = Style::default().fg(t.fg).bg(t.bg_dark);
    let blank = || Line::from(Span::styled(String::new(), body));
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
            let color = match level {
                1 => t.blue,
                2 => t.cyan,
                3 => t.green,
                4 => t.yellow,
                _ => t.purple,
            };
            let mut style = body.fg(color).add_modifier(Modifier::BOLD);
            if level <= 2 {
                style = style.add_modifier(Modifier::UNDERLINED);
            }
            if !out.is_empty() {
                out.push(blank());
            }
            out.push(styled_line(None, r.trim(), style));
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
            let quote = body.fg(t.comment).add_modifier(Modifier::ITALIC);
            out.push(styled_line(
                Some(Span::styled(
                    "▏ ",
                    Style::default().fg(t.purple).bg(t.bg_dark),
                )),
                q.trim_start(),
                quote,
            ));
            continue;
        }
        // list items (preserve the source's leading indentation)
        let indent: String = line.chars().take_while(|c| *c == ' ').collect();
        if let Some(item) = trimmed
            .strip_prefix("- ")
            .or_else(|| trimmed.strip_prefix("* "))
            .or_else(|| trimmed.strip_prefix("+ "))
        {
            out.push(styled_line(
                Some(Span::styled(
                    format!("{indent}• "),
                    Style::default().fg(t.blue).bg(t.bg_dark),
                )),
                item,
                body,
            ));
            continue;
        }
        if let Some(dot) = trimmed.find(". ")
            && !trimmed[..dot].is_empty()
            && trimmed[..dot].chars().all(|c| c.is_ascii_digit())
        {
            let num = &trimmed[..dot];
            out.push(styled_line(
                Some(Span::styled(
                    format!("{indent}{num}. "),
                    Style::default().fg(t.blue).bg(t.bg_dark),
                )),
                &trimmed[dot + 2..],
                body,
            ));
            continue;
        }
        // plain paragraph line
        out.push(styled_line(None, line, body));
    }
    out
}

/// Word-wrap each rendered line to `width` columns, preserving span styles.
/// Continuation rows are indented to match the original line's leading
/// whitespace (so list items / blockquotes stay visually aligned, capped at
/// half the width). A word longer than a row is hard-split. `width < 4` (or a
/// line that already fits) is returned unchanged.
pub fn wrap_lines(lines: Vec<Line<'static>>, width: usize) -> Vec<Line<'static>> {
    if width < 4 {
        return lines;
    }
    let mut out: Vec<Line<'static>> = Vec::with_capacity(lines.len());
    for line in lines {
        let chars: Vec<(char, Style)> = line
            .spans
            .iter()
            .flat_map(|s| {
                let st = s.style;
                s.content.chars().map(move |c| (c, st))
            })
            .collect();
        if chars.len() <= width {
            out.push(line);
            continue;
        }
        let lead = chars.iter().take_while(|(c, _)| *c == ' ').count();
        let hang = lead.min(width / 2);
        let lead_style = chars.first().map(|(_, s)| *s).unwrap_or_default();

        let mut i = 0usize;
        let mut first = true;
        while i < chars.len() {
            let avail = (if first {
                width
            } else {
                width.saturating_sub(hang)
            })
            .max(1);
            let remaining = chars.len() - i;
            let take = if remaining <= avail {
                remaining
            } else {
                match chars[i..i + avail].iter().rposition(|(c, _)| *c == ' ') {
                    Some(p) if p > 0 => p, // wrap before that space (consumed below)
                    _ => avail,            // no break point → hard split
                }
            };
            let mut row: Vec<(char, Style)> = Vec::with_capacity(take + hang);
            if !first {
                row.extend(std::iter::repeat_n((' ', lead_style), hang));
            }
            row.extend_from_slice(&chars[i..i + take]);
            i += take;
            // Drop a single space sitting at the wrap point.
            if i < chars.len() && chars[i].0 == ' ' && take < remaining {
                i += 1;
            }
            while matches!(row.last(), Some((' ', _))) {
                row.pop();
            }
            out.push(coalesce_chars(row));
            first = false;
        }
    }
    out
}

/// Collapse a `(char, style)` run into a [`Line`] of minimal same-style spans.
fn coalesce_chars(chars: Vec<(char, Style)>) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut buf = String::new();
    let mut cur: Option<Style> = None;
    for (c, st) in chars {
        if cur == Some(st) {
            buf.push(c);
        } else {
            if let Some(s) = cur {
                spans.push(Span::styled(std::mem::take(&mut buf), s));
            }
            buf.push(c);
            cur = Some(st);
        }
    }
    if let Some(s) = cur {
        spans.push(Span::styled(buf, s));
    }
    Line::from(spans)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_spans_styles_markers() {
        let base = Style::default();
        let spans = inline_spans("a **bold** and `code` and *it*", base);
        let text: String = spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(text, "a bold and code and it");
        let bold = spans.iter().find(|s| s.content == "bold").unwrap();
        assert!(bold.style.add_modifier.contains(Modifier::BOLD));
        let it = spans.iter().find(|s| s.content == "it").unwrap();
        assert!(it.style.add_modifier.contains(Modifier::ITALIC));
        // `code` gets a distinct background, not the base style.
        let code = spans.iter().find(|s| s.content == "code").unwrap();
        assert!(code.style.bg.is_some());
    }

    #[test]
    fn inline_spans_renders_links_and_keeps_underscores() {
        let base = Style::default();
        let spans = inline_spans("see [docs](http://x) for some_snake_case", base);
        let text: String = spans.iter().map(|s| s.content.as_ref()).collect();
        assert_eq!(text, "see docs (http://x) for some_snake_case");
        assert!(
            spans
                .iter()
                .any(|s| s.content == "docs" && s.style.add_modifier.contains(Modifier::UNDERLINED))
        );
    }

    #[test]
    fn wrap_lines_wraps_and_hangs() {
        let st = Style::default();
        // 3 leading spaces → hanging indent on continuations.
        let src = Line::from(Span::styled("   alpha beta gamma delta", st));
        let wrapped = wrap_lines(vec![src], 12);
        let texts: Vec<String> = wrapped
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect();
        assert!(texts.len() >= 2, "expected a wrap, got {texts:?}");
        assert_eq!(texts[0], "   alpha", "first row keeps the indent");
        for t in &texts {
            assert!(t.chars().count() <= 12, "row over width: {t:?}");
        }
        assert!(
            texts[1..].iter().all(|t| t.starts_with("   ")),
            "continuations hang-indented: {texts:?}"
        );
        // A single short line is untouched.
        let short = Line::from(Span::styled("hi", st));
        assert_eq!(wrap_lines(vec![short.clone()], 12).len(), 1);
    }

    #[test]
    fn wrap_lines_hard_splits_long_words() {
        let st = Style::default();
        let src = Line::from(Span::styled("abcdefghijklmnop", st));
        let wrapped = wrap_lines(vec![src], 6);
        assert!(wrapped.len() >= 3);
        for l in &wrapped {
            let n: usize = l.spans.iter().map(|s| s.content.chars().count()).sum();
            assert!(n <= 6);
        }
    }

    #[test]
    fn render_handles_blocks() {
        let md = "# Title\n\nsome **text**\n\n- one\n- two\n\n```\ncode\n```\n> a quote\n---\n";
        let lines = render_markdown(md);
        assert!(lines.len() >= 6, "got {} lines", lines.len());
    }
}
