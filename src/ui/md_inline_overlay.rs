//! Inline markdown rendering (render-markdown.nvim style). Post-process
//! pass that walks the visible rows of any markdown editor pane and
//! repaints select cell ranges to mimic rendered markdown:
//!
//! - Heading lines (`# `..`###### `) — line text rendered bold + depth-
//!   colored; the leading `#`s are dimmed.
//! - `**bold**` — markers dimmed, inner text bold.
//! - `*italic*` / `_italic_` — markers dimmed, inner text italic.
//! - `` `code` `` — backticks dimmed, inner text rendered with `bg2` bg.
//! - `[label](url)` — markers + URL hidden (rendered as spaces), label
//!   colored as a link (blue underline).
//!
//! Off by default — `[ui] render_markdown = true` / `:set rendermarkdown`.
//! The canonical rendering is still `Pane::MdPreview`; this is the
//! "I want to keep editing while seeing the styled view" middle ground.
//!
//! Single-pass per line, char-offset based. Wrap is not supported — when
//! `[ui] wrap` is on the overlay is skipped to avoid mispainting wrapped
//! continuation rows.

use ratatui::Frame;
use ratatui::style::{Color, Modifier, Style};

use crate::app::App;
use crate::flash::{FlashTarget, target_to_screen};
use crate::pane::Pane;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &App) {
    if !app.config.ui.render_markdown {
        return;
    }
    if app.config.ui.wrap {
        return; // bail rather than miscolor wrapped rows
    }
    // Walk every visible editor pane and overlay markdown buffers.
    let panes: Vec<(ratatui::layout::Rect, crate::layout::PaneId)> =
        app.rects.editor_panes.to_vec();
    for (text_rect, pid) in panes {
        let Some(Pane::Editor(buf)) = app.panes.get(pid) else {
            continue;
        };
        let ext = buf.language_ext.as_deref().unwrap_or("");
        if !matches!(ext, "md" | "markdown" | "mdx") {
            continue;
        }
        overlay_one_pane(frame, app, buf, pid, text_rect);
    }
}

fn overlay_one_pane(
    frame: &mut Frame,
    _app: &App,
    buf: &crate::buffer::Buffer,
    _pid: crate::layout::PaneId,
    text_rect: ratatui::layout::Rect,
) {
    let scroll = buf.scroll;
    let h_scroll = buf.h_scroll;
    let text_h = text_rect.height as usize;
    let t = theme::cur();

    let dim = Style::default().fg(t.comment);
    let link_style = Style::default()
        .fg(t.blue)
        .add_modifier(Modifier::UNDERLINED);
    let code_style = Style::default().fg(t.fg).bg(t.bg2);

    let text = buf.editor.text();
    let area_right = text_rect.x + text_rect.width;
    let area_bottom = text_rect.y + text_rect.height;
    for (row, line) in text.split('\n').enumerate().skip(scroll).take(text_h) {
        // Heading-line styling.
        let trim_start = line.trim_start();
        if let Some(depth) = heading_depth(trim_start) {
            paint_heading(
                frame,
                text_rect,
                row,
                scroll,
                h_scroll,
                line,
                depth,
                area_right,
                area_bottom,
            );
            continue;
        }
        // Inline pass: `**bold**`, `*italic*`, `` `code` ``, `[label](url)`.
        for span in scan_inline_spans(line) {
            paint_inline_span(
                frame,
                text_rect,
                row,
                scroll,
                h_scroll,
                line,
                span,
                area_right,
                area_bottom,
                dim,
                link_style,
                code_style,
            );
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn paint_cell(
    frame: &mut Frame,
    text_rect: ratatui::layout::Rect,
    row: usize,
    scroll: usize,
    h_scroll: usize,
    col_chars: usize,
    ch: char,
    style: Style,
    area_right: u16,
    area_bottom: u16,
) {
    let tgt = FlashTarget {
        row,
        col_chars,
        label: ch,
    };
    let Some((x, y)) = target_to_screen(&tgt, text_rect, scroll, h_scroll, None) else {
        return;
    };
    if x >= area_right || y >= area_bottom {
        return;
    }
    if let Some(dst) = frame.buffer_mut().cell_mut((x, y)) {
        dst.set_char(ch);
        dst.set_style(style);
    }
}

fn heading_color(depth: u8) -> Color {
    let t = theme::cur();
    match depth {
        1 => t.red,
        2 => t.orange,
        3 => t.yellow,
        4 => t.green,
        5 => t.cyan,
        _ => t.blue,
    }
}

fn heading_depth(s: &str) -> Option<u8> {
    let mut n: u8 = 0;
    let chars: Vec<char> = s.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        if c == '#' {
            n += 1;
            if n > 6 {
                return None;
            }
        } else if c == ' ' && n > 0 {
            // ATX heading requires at least one space between #s and text.
            if i == n as usize {
                return Some(n);
            }
            return None;
        } else {
            return None;
        }
    }
    None
}

#[allow(clippy::too_many_arguments)]
fn paint_heading(
    frame: &mut Frame,
    text_rect: ratatui::layout::Rect,
    row: usize,
    scroll: usize,
    h_scroll: usize,
    line: &str,
    depth: u8,
    area_right: u16,
    area_bottom: u16,
) {
    let t = theme::cur();
    let dim = Style::default().fg(t.comment);
    let head = Style::default()
        .fg(heading_color(depth))
        .add_modifier(Modifier::BOLD);
    // Leading-whitespace pass-through; then `#`s in dim; then `space` in dim;
    // then the rest in head color.
    let chars: Vec<char> = line.chars().collect();
    // Find the run of leading whitespace (kept as-is).
    let mut i = 0;
    while i < chars.len() && chars[i].is_whitespace() {
        i += 1;
    }
    // Paint each `#` in dim.
    let mut col = i;
    let depth_n = depth as usize;
    for _ in 0..depth_n {
        if col < chars.len() {
            paint_cell(
                frame,
                text_rect,
                row,
                scroll,
                h_scroll,
                col,
                chars[col],
                dim,
                area_right,
                area_bottom,
            );
            col += 1;
        }
    }
    // The single space after `#`s.
    if col < chars.len() {
        paint_cell(
            frame,
            text_rect,
            row,
            scroll,
            h_scroll,
            col,
            chars[col],
            dim,
            area_right,
            area_bottom,
        );
        col += 1;
    }
    // The heading text — rest of the line.
    while col < chars.len() {
        paint_cell(
            frame,
            text_rect,
            row,
            scroll,
            h_scroll,
            col,
            chars[col],
            head,
            area_right,
            area_bottom,
        );
        col += 1;
    }
}

#[derive(Debug, Clone)]
enum InlineSpan {
    /// `**…**` (both `**` and `__` are bold in CommonMark; we recognize `**`).
    Bold {
        start: usize, // first marker char
        end: usize,   // last marker char (inclusive)
    },
    /// `*…*` or `_…_`.
    Italic { start: usize, end: usize },
    /// `` `…` ``.
    InlineCode { start: usize, end: usize },
    /// `[label](url)`.
    Link {
        start: usize, // first `[`
        end: usize,   // last `)`
        label_start: usize,
        label_end: usize, // exclusive
    },
}

fn scan_inline_spans(line: &str) -> Vec<InlineSpan> {
    let chars: Vec<char> = line.chars().collect();
    let n = chars.len();
    let mut out: Vec<InlineSpan> = Vec::new();
    let mut i = 0usize;
    while i < n {
        let c = chars[i];
        // Inline code first — once inside backticks, no other markup runs.
        if c == '`'
            && let Some(end) = find_unescaped(&chars, i + 1, '`')
        {
            out.push(InlineSpan::InlineCode { start: i, end });
            i = end + 1;
            continue;
        }
        // Bold (`**…**`).
        if c == '*'
            && i + 1 < n
            && chars[i + 1] == '*'
            && let Some(end) = find_double(&chars, i + 2, '*')
        {
            out.push(InlineSpan::Bold {
                start: i,
                end: end + 1,
            });
            i = end + 2;
            continue;
        }
        // Italic — `*…*` or `_…_` (avoid colliding with `**`).
        if (c == '*' || c == '_')
            && !(i + 1 < n && chars[i + 1] == c)
            && !(i > 0 && chars[i - 1] == c)
            && let Some(end) = find_single(&chars, i + 1, c)
        {
            out.push(InlineSpan::Italic { start: i, end });
            i = end + 1;
            continue;
        }
        // Link — `[…](…)`.
        if c == '['
            && let Some(lbl_end) = find_unescaped(&chars, i + 1, ']')
            && lbl_end + 1 < n
            && chars[lbl_end + 1] == '('
            && let Some(url_end) = find_unescaped(&chars, lbl_end + 2, ')')
        {
            out.push(InlineSpan::Link {
                start: i,
                end: url_end,
                label_start: i + 1,
                label_end: lbl_end,
            });
            i = url_end + 1;
            continue;
        }
        i += 1;
    }
    out
}

fn find_unescaped(chars: &[char], start: usize, target: char) -> Option<usize> {
    let mut i = start;
    while i < chars.len() {
        if chars[i] == target && !(i > 0 && chars[i - 1] == '\\') {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn find_double(chars: &[char], start: usize, marker: char) -> Option<usize> {
    let mut i = start;
    while i + 1 < chars.len() {
        if chars[i] == marker && chars[i + 1] == marker {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn find_single(chars: &[char], start: usize, marker: char) -> Option<usize> {
    let mut i = start;
    while i < chars.len() {
        if chars[i] == marker
            && !(i + 1 < chars.len() && chars[i + 1] == marker)
            && !(i > 0 && chars[i - 1] == marker)
        {
            return Some(i);
        }
        i += 1;
    }
    None
}

#[allow(clippy::too_many_arguments)]
fn paint_inline_span(
    frame: &mut Frame,
    text_rect: ratatui::layout::Rect,
    row: usize,
    scroll: usize,
    h_scroll: usize,
    line: &str,
    span: InlineSpan,
    area_right: u16,
    area_bottom: u16,
    dim: Style,
    link_style: Style,
    code_style: Style,
) {
    let chars: Vec<char> = line.chars().collect();
    match span {
        InlineSpan::Bold { start, end } => {
            // Paint markers dim (2 chars at each end), inner bold.
            let bold = Style::default().add_modifier(Modifier::BOLD);
            for k in [start, start + 1, end - 1, end] {
                if let Some(&ch) = chars.get(k) {
                    paint_cell(
                        frame,
                        text_rect,
                        row,
                        scroll,
                        h_scroll,
                        k,
                        ch,
                        dim,
                        area_right,
                        area_bottom,
                    );
                }
            }
            for k in (start + 2)..(end - 1) {
                if let Some(&ch) = chars.get(k) {
                    paint_cell(
                        frame,
                        text_rect,
                        row,
                        scroll,
                        h_scroll,
                        k,
                        ch,
                        bold,
                        area_right,
                        area_bottom,
                    );
                }
            }
        }
        InlineSpan::Italic { start, end } => {
            let italic = Style::default().add_modifier(Modifier::ITALIC);
            if let Some(&ch) = chars.get(start) {
                paint_cell(
                    frame,
                    text_rect,
                    row,
                    scroll,
                    h_scroll,
                    start,
                    ch,
                    dim,
                    area_right,
                    area_bottom,
                );
            }
            if let Some(&ch) = chars.get(end) {
                paint_cell(
                    frame,
                    text_rect,
                    row,
                    scroll,
                    h_scroll,
                    end,
                    ch,
                    dim,
                    area_right,
                    area_bottom,
                );
            }
            for k in (start + 1)..end {
                if let Some(&ch) = chars.get(k) {
                    paint_cell(
                        frame,
                        text_rect,
                        row,
                        scroll,
                        h_scroll,
                        k,
                        ch,
                        italic,
                        area_right,
                        area_bottom,
                    );
                }
            }
        }
        InlineSpan::InlineCode { start, end } => {
            if let Some(&ch) = chars.get(start) {
                paint_cell(
                    frame,
                    text_rect,
                    row,
                    scroll,
                    h_scroll,
                    start,
                    ch,
                    dim,
                    area_right,
                    area_bottom,
                );
            }
            if let Some(&ch) = chars.get(end) {
                paint_cell(
                    frame,
                    text_rect,
                    row,
                    scroll,
                    h_scroll,
                    end,
                    ch,
                    dim,
                    area_right,
                    area_bottom,
                );
            }
            for k in (start + 1)..end {
                if let Some(&ch) = chars.get(k) {
                    paint_cell(
                        frame,
                        text_rect,
                        row,
                        scroll,
                        h_scroll,
                        k,
                        ch,
                        code_style,
                        area_right,
                        area_bottom,
                    );
                }
            }
        }
        InlineSpan::Link {
            start,
            end,
            label_start,
            label_end,
        } => {
            // `[`, `]`, `(`, `)` and URL chars all dim → leave the label visible.
            // For simplicity, paint everything outside the label as dim, label
            // chars as link_style.
            for k in start..=end {
                if let Some(&ch) = chars.get(k) {
                    let inside_label = k >= label_start && k < label_end;
                    let s = if inside_label { link_style } else { dim };
                    paint_cell(
                        frame,
                        text_rect,
                        row,
                        scroll,
                        h_scroll,
                        k,
                        ch,
                        s,
                        area_right,
                        area_bottom,
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn heading_depth_detects_atx_levels() {
        assert_eq!(heading_depth("# foo"), Some(1));
        assert_eq!(heading_depth("## foo"), Some(2));
        assert_eq!(heading_depth("###### foo"), Some(6));
        assert_eq!(heading_depth("####### foo"), None);
        assert_eq!(heading_depth("#foo"), None);
        assert_eq!(heading_depth("body"), None);
    }

    #[test]
    fn scan_inline_finds_bold_italic_code_and_link() {
        let line = "This is **bold** and *em* and `code` and [text](http://u.x)";
        let spans = scan_inline_spans(line);
        assert!(matches!(spans[0], InlineSpan::Bold { .. }));
        assert!(matches!(spans[1], InlineSpan::Italic { .. }));
        assert!(matches!(spans[2], InlineSpan::InlineCode { .. }));
        assert!(matches!(spans[3], InlineSpan::Link { .. }));
    }

    #[test]
    fn scan_inline_skips_markup_inside_code() {
        // Inside backticks, no further markup runs — the `*foo*` is literal code.
        let line = "see `*foo*` here";
        let spans = scan_inline_spans(line);
        assert_eq!(spans.len(), 1);
        assert!(matches!(spans[0], InlineSpan::InlineCode { .. }));
    }
}
