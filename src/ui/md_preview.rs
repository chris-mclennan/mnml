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
    let t = theme::cur();
    frame.render_widget(Paragraph::new("").style(Style::default().bg(bg)), area);

    // #polish 2026-07-06 — the `✏ Edit` chip moved to the
    // bufferline (right side, left of the terminal icon). No
    // per-pane banner row anymore; the pane gets the whole area.
    let banner_h: u16 = 0;
    let _ = pane_id; // reserved: chip registration now lives in bufferline
    let _ = t;

    let protocol = app.image_protocol;
    let image_rows = app.config.ui.md_image_rows;
    let engine = app.config.ui.md_preview_engine.clone();
    let Some(Pane::MdPreview(p)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    // A one-cell left margin so the text isn't flush against the divider.
    // Banner (if drawn) claims the top row.
    let text_area = Rect {
        x: area.x + 1,
        y: area.y + banner_h,
        width: area.width.saturating_sub(1),
        height: area.height.saturating_sub(banner_h),
    };
    // Choose the rendering path once per frame. Builtin is the default
    // (image-aware, cursor-tracking); glow / custom-cmd is the opt-in
    // richer path (no images, but nicer typography). Failure to spawn
    // the external tool falls back to builtin with a one-shot toast.
    let use_external = engine != "builtin" && !engine.is_empty();
    let mut external_lines: Option<Vec<Line<'static>>> = None;
    let mut external_error: Option<String> = None;
    if use_external {
        if p.external_cache
            .is_fresh(&engine, text_area.width, &p.source)
        {
            external_lines = Some(p.external_cache.lines.clone());
        } else {
            match crate::ui::md_preview_external::render(&engine, text_area.width, &p.source) {
                Ok(lines) => {
                    p.external_cache = crate::ui::md_preview_external::ExternalCache {
                        key: (engine.clone(), text_area.width, {
                            use std::hash::{Hash, Hasher};
                            let mut h = std::collections::hash_map::DefaultHasher::new();
                            p.source.hash(&mut h);
                            h.finish()
                        }),
                        lines: lines.clone(),
                    };
                    p.external_error_toasted = false;
                    external_lines = Some(lines);
                }
                Err(reason) => {
                    if !p.external_error_toasted {
                        p.external_error_toasted = true;
                        external_error = Some(reason);
                    }
                }
            }
        }
    }
    // Image-aware render path: when the terminal can paint images, reserve
    // rows for `![alt](path)` references so the post-draw overlay has a
    // place to land. Plain-text terminal (no image protocol) still gets
    // the placeholder rows + dim caption — keeps line-count math
    // identical between the two paths so scroll position is stable.
    let directives = parse_image_directives(&p.source, image_rows);
    let lines = if let Some(ext) = external_lines {
        ext
    } else {
        wrap_lines(
            render_markdown_with_image_placeholders(&p.source, image_rows),
            text_area.width as usize,
        )
    };
    let h = area.height as usize;
    let max_scroll = lines.len().saturating_sub(h.min(lines.len()));
    p.scroll = p.scroll.min(max_scroll);
    let scroll = p.scroll;

    let view: Vec<Line> = lines.iter().skip(scroll).take(h).cloned().collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(bg)),
        text_area,
    );

    // Record the pane's rect so a click focuses it / the wheel scrolls it.
    app.rects.editor_panes.push((text_area, pane_id));

    // Stage image paint requests for any directive whose row range
    // intersects the viewport. Skip when the terminal has no image
    // protocol — the dim alt-text caption already covers that case.
    let mut requests: Vec<crate::image::PaintRequest> = Vec::new();
    if !matches!(protocol, crate::image::ImageProtocol::None) {
        let base_dir = p
            .path
            .parent()
            .map(|d| d.to_path_buf())
            .unwrap_or_else(|| std::path::PathBuf::from("."));
        let mut needed_paths: std::collections::HashSet<std::path::PathBuf> =
            std::collections::HashSet::new();
        for d in &directives {
            // Resolve `d.path` relative to the .md file's directory.
            let raw = std::path::Path::new(&d.path);
            let resolved = if raw.is_absolute() {
                raw.to_path_buf()
            } else {
                base_dir.join(raw)
            };
            let resolved = resolved.canonicalize().unwrap_or(resolved);
            needed_paths.insert(resolved.clone());
            // Lazy-load + cache.
            if !p.image_cache.contains_key(&resolved)
                && let Ok(data) = crate::image::load(&resolved)
            {
                p.image_cache.insert(resolved.clone(), data);
            }
            // Is this directive's row range inside the visible window?
            let start = d.line_idx;
            let end = d.line_idx + d.rows as usize;
            let v_start = scroll;
            let v_end = scroll + h;
            if end <= v_start || start >= v_end {
                continue;
            }
            // Clip to the viewport.
            let visible_start = start.max(v_start);
            let visible_end = end.min(v_end);
            let visible_rows = (visible_end - visible_start) as u16;
            if visible_rows == 0 {
                continue;
            }
            // The first placeholder row holds the caption; offset the
            // image start by 1 so the caption stays visible.
            let row_offset_in_doc = visible_start - start;
            let caption_offset: u16 = if row_offset_in_doc == 0 { 1 } else { 0 };
            let image_rows = visible_rows.saturating_sub(caption_offset);
            if image_rows == 0 {
                continue;
            }
            let image_y = text_area
                .y
                .saturating_add((visible_start - scroll) as u16)
                .saturating_add(caption_offset);
            let image_area = ratatui::layout::Rect {
                x: text_area.x.saturating_add(2),
                y: image_y,
                width: text_area.width.saturating_sub(4),
                height: image_rows,
            };
            // Compute the PNG bytes (decoding non-PNG on first access).
            // The cache holds the ImageData; ensure_png_bytes is &mut.
            if let Some(data) = p.image_cache.get_mut(&resolved)
                && let Ok(png_bytes) = data.ensure_png_bytes()
            {
                requests.push(crate::image::PaintRequest {
                    pane_id,
                    area: image_area,
                    png_bytes,
                });
            }
        }
        // Drop stale cache entries.
        p.image_cache.retain(|k, _| needed_paths.contains(k));
    }
    // Re-borrow `app` to push the staged requests now that `p` is dropped.
    app.image_paint_requests.extend(requests);
    // One-shot toast when the external renderer failed and we fell
    // back to builtin. Latched via `external_error_toasted` on the
    // pane so we don't spam the user every frame while the tool is
    // still missing.
    if let Some(msg) = external_error {
        app.toast(msg);
        app.toast("md-preview: falling back to builtin renderer");
    }

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

/// One inline-image reference parsed out of a markdown source. Lives on a
/// single source line (the renderer expects standalone `![alt](path)` rows;
/// images embedded mid-paragraph fall through to the link parser and render
/// as normal text).
#[derive(Debug, Clone)]
pub struct ImageDirective {
    /// Index into `render_markdown`'s returned `Vec<Line>` where this
    /// image's placeholder rows start.
    pub line_idx: usize,
    /// How many rows the image occupies (the renderer pads with that many
    /// blank lines so caller can paint the image overlay on top).
    pub rows: u16,
    /// Image-source path as written in the markdown — relative to the
    /// `.md` file's directory. The caller resolves it to an absolute
    /// path against `MdPreview.path`'s parent before loading.
    pub path: String,
    /// `![alt](path)` — alt text, shown as the placeholder caption when
    /// the terminal has no image protocol or the file can't be loaded.
    pub alt: String,
}

/// Default height in cells for an embedded image. Configurable via
/// `[ui] md_image_rows`. Picked to be unobtrusive inside paragraphs.
pub const DEFAULT_IMAGE_ROWS: u16 = 12;

/// Walk the markdown source and pick out every standalone-line
/// `![alt](path)` image. Returns directives keyed by the rendered
/// `Vec<Line>` index — the caller is responsible for slicing visible
/// rows + staging paint requests. Pair with [`render_markdown_with_image_placeholders`]
/// (called with the same `rows` value) so the renderer reserves the
/// matching number of blank lines.
pub fn parse_image_directives(src: &str, rows: u16) -> Vec<ImageDirective> {
    let mut out: Vec<ImageDirective> = Vec::new();
    let mut rendered_idx: usize = 0;
    let mut in_code = false;
    let mut prev_was_content = false;
    for raw in src.lines() {
        let trimmed = raw.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            in_code = !in_code;
            continue; // fence lines aren't rendered
        }
        if in_code {
            rendered_idx += 1;
            prev_was_content = true;
            continue;
        }
        // Headings emit a blank line before them when prev was content —
        // mirror the same logic so rendered_idx tracks correctly.
        let is_heading = trimmed.starts_with('#');
        if is_heading && prev_was_content {
            rendered_idx += 1;
        }
        // Detect a standalone `![alt](path)` line. Tolerate trailing
        // whitespace / surrounding punctuation? No — keep strict so we
        // don't mis-fire on inline references.
        if let Some(img) = parse_image_line(trimmed) {
            out.push(ImageDirective {
                line_idx: rendered_idx,
                rows,
                path: img.0,
                alt: img.1,
            });
            // Renderer will emit `rows` blanks for this.
            rendered_idx += rows as usize;
        } else {
            rendered_idx += 1;
        }
        prev_was_content = !trimmed.is_empty();
    }
    out
}

/// Parse a single line for the standalone `![alt](path)` shape.
/// Returns `(path, alt)`. The opening `![` must be at the start of the
/// trimmed line and the `)` must be the last char (no trailing text).
fn parse_image_line(line: &str) -> Option<(String, String)> {
    let line = line.trim_end();
    if !line.starts_with("![") || !line.ends_with(')') {
        return None;
    }
    let alt_close = line.find("](")?;
    let alt = &line[2..alt_close];
    let path = &line[alt_close + 2..line.len() - 1];
    if path.is_empty() {
        return None;
    }
    Some((path.to_string(), alt.to_string()))
}

/// Render markdown `src` to styled lines (block-level styling + inline spans).
/// Standalone image lines render as normal markdown text (the inline parser
/// handles the link syntax). For an image-placeholder-reserving variant pair
/// with [`render_markdown_with_image_placeholders`] + [`parse_image_directives`].
pub fn render_markdown(src: &str) -> Vec<Line<'static>> {
    render_markdown_with_options(src, false, 0)
}

/// Same as [`render_markdown`] but reserves `rows` blank lines for each
/// inline image embed. Pair with [`parse_image_directives`] called
/// with the same `rows` so the directive indices line up.
pub fn render_markdown_with_image_placeholders(src: &str, rows: u16) -> Vec<Line<'static>> {
    render_markdown_with_options(src, true, rows)
}

fn render_markdown_with_options(
    src: &str,
    with_image_placeholders: bool,
    image_rows: u16,
) -> Vec<Line<'static>> {
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
        // Standalone image line: emit `DEFAULT_IMAGE_ROWS` placeholder
        // rows so the caller can paint the image overlay on top. First
        // row is a dim caption (alt text); the rest are blank with the
        // body background color so the overlay has a clean canvas.
        if with_image_placeholders
            && image_rows > 0
            && let Some((_path, alt)) = parse_image_line(trimmed)
        {
            let caption = if alt.is_empty() {
                "  [image]".to_string()
            } else {
                format!("  [image: {alt}]")
            };
            out.push(Line::from(Span::styled(
                caption,
                body.fg(t.comment).add_modifier(Modifier::ITALIC),
            )));
            for _ in 1..image_rows {
                out.push(Line::from(Span::styled(" ".repeat(0), body)));
            }
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

    #[test]
    fn parse_image_line_picks_path_and_alt() {
        assert_eq!(
            parse_image_line("![diagram](img/foo.png)"),
            Some(("img/foo.png".to_string(), "diagram".to_string()))
        );
        assert_eq!(
            parse_image_line("![](a.png)"),
            Some(("a.png".to_string(), String::new()))
        );
    }

    #[test]
    fn parse_image_line_refuses_non_image_lines() {
        // Not an image — a link with `![text]` adjacent to something else.
        assert!(parse_image_line("text ![alt](foo.png)").is_none());
        assert!(parse_image_line("![alt](foo.png) extra").is_none());
        assert!(parse_image_line("![alt without close").is_none());
        assert!(parse_image_line("plain line").is_none());
        // Empty path is refused.
        assert!(parse_image_line("![alt]()").is_none());
    }

    #[test]
    fn parse_image_directives_finds_standalone_images() {
        let md = "# Title\n\nsome text\n\n![diagram](img/a.png)\n\nmore text\n\n![second](b.jpg)";
        let dirs = parse_image_directives(md, DEFAULT_IMAGE_ROWS);
        assert_eq!(dirs.len(), 2);
        assert_eq!(dirs[0].path, "img/a.png");
        assert_eq!(dirs[0].alt, "diagram");
        assert_eq!(dirs[0].rows, DEFAULT_IMAGE_ROWS);
        assert_eq!(dirs[1].path, "b.jpg");
        assert_eq!(dirs[1].alt, "second");
    }

    #[test]
    fn parse_image_directives_respects_custom_rows() {
        let md = "![a](x.png)";
        let dirs = parse_image_directives(md, 6);
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].rows, 6);
    }

    #[test]
    fn parse_image_directives_skips_inline_image_refs() {
        let md = "see ![alt](foo.png) inline";
        assert!(parse_image_directives(md, DEFAULT_IMAGE_ROWS).is_empty());
    }

    #[test]
    fn parse_image_directives_skips_images_in_code_fences() {
        let md = "```\n![not](real.png)\n```\n";
        assert!(parse_image_directives(md, DEFAULT_IMAGE_ROWS).is_empty());
    }
}
