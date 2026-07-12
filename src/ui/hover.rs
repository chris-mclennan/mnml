//! Renders the LSP hover popup ([`crate::hover::HoverPopup`]) — a small bordered
//! box anchored just below the cursor (flipped above if it won't fit, clamped to
//! the screen) with the language server's docs. j/k/arrows scroll it, any other
//! key dismisses it (handled in `tui.rs`).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect, cursor: Option<(u16, u16)>) {
    let Some(h) = &mut app.hover else {
        return;
    };
    if screen.width < 8 || screen.height < 5 || h.lines.is_empty() {
        return;
    }
    let t = theme::cur();

    let content_w = h.width().max(8) as u16;
    let w = (content_w + 2).min(screen.width.saturating_sub(2));
    let max_h = screen.height.saturating_sub(2).min(18);
    let hgt = (h.lines.len() as u16 + 2).min(max_h);
    let inner_rows = hgt.saturating_sub(2) as usize;

    // Anchor below the cursor; flip above if it doesn't fit; clamp to the screen.
    let (cx, cy) = cursor.unwrap_or((screen.x + 2, screen.y + 1));
    let below_y = cy.saturating_add(1);
    let y = if below_y + hgt <= screen.y + screen.height {
        below_y
    } else if cy >= screen.y + hgt {
        cy - hgt
    } else {
        screen.y
    };
    let x = cx
        .min(screen.x + screen.width.saturating_sub(w))
        .max(screen.x);
    let area = Rect {
        x,
        y,
        width: w,
        height: hgt,
    };

    let max_scroll = h.lines.len().saturating_sub(inner_rows);
    if h.scroll > max_scroll {
        h.scroll = max_scroll;
    }

    frame.render_widget(Clear, area);
    // 2026-07-12 user feedback — VS Code's hover popup has no
    // "hover" label; the box is anchored directly at the cursor
    // and the content itself carries the signal. Drop the title
    // entirely (subtitle-only pagination indicator when it
    // scrolls) so the popup reads as adjacent-to-cursor rather
    // than as a separate labeled overlay.
    let title = if h.lines.len() > inner_rows {
        format!(
            " {}–{}/{} ",
            h.scroll + 1,
            (h.scroll + inner_rows).min(h.lines.len()),
            h.lines.len()
        )
    } else {
        String::new()
    };
    let block = crate::ui::design_tokens::popup_panel(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.width == 0 || inner.height == 0 {
        return;
    }
    // Highlight common declaration shapes so `const x: Type`,
    // `function f(...): T`, `interface I { … }`, etc. read as
    // code — matching VS Code's styled hover content instead of
    // rendering as monotone text. Pattern-based (no tree-sitter
    // dependency); falls back to plain fg for lines that don't
    // match any shape.
    let view: Vec<Line> = h
        .lines
        .iter()
        .skip(h.scroll)
        .take(inner.height as usize)
        .map(|l| highlight_hover_line(l, &t))
        .collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_darker)),
        inner,
    );
}

/// Highlight a single hover-content line with per-token color.
/// Recognizes: leading TS/JS/Rust keywords (`const`/`let`/`fn`/
/// `function`/`interface`/`type`/`class`/`enum`/`pub`/`async`),
/// identifier-colon-type shape (`x: Type`), string literals in
/// double-quotes, and comments starting with `//`. Unknown shapes
/// fall through as plain fg.
fn highlight_hover_line(line: &str, t: &crate::ui::theme::Theme) -> Line<'static> {
    let plain = Style::default().fg(t.fg).bg(t.bg_darker);
    let kw = Style::default().fg(t.purple).bg(t.bg_darker);
    let ident = Style::default().fg(t.fg).bg(t.bg_darker);
    let ty = Style::default().fg(t.cyan).bg(t.bg_darker);
    let string_st = Style::default().fg(t.green).bg(t.bg_darker);
    let comment = Style::default().fg(t.comment).bg(t.bg_darker);

    // Comment line? Return as-is in comment color.
    if line.trim_start().starts_with("//") {
        return Line::from(Span::styled(line.to_string(), comment));
    }

    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut rest = line.to_string();

    // Consume leading indent as plain.
    let indent_end = rest.chars().take_while(|c| c.is_whitespace()).count();
    if indent_end > 0 {
        let indent: String = rest.chars().take(indent_end).collect();
        spans.push(Span::styled(indent, plain));
        rest = rest.chars().skip(indent_end).collect();
    }

    const KEYWORDS: &[&str] = &[
        "const",
        "let",
        "var",
        "function",
        "fn",
        "interface",
        "type",
        "class",
        "enum",
        "pub",
        "async",
        "await",
        "return",
        "import",
        "export",
        "default",
        "static",
        "readonly",
        "declare",
        "namespace",
        "module",
    ];

    // Leading keyword?
    let first_word: String = rest.chars().take_while(|c| c.is_alphabetic()).collect();
    if KEYWORDS.contains(&first_word.as_str()) {
        spans.push(Span::styled(format!("{first_word} "), kw));
        rest = rest.chars().skip(first_word.chars().count()).collect();
        if rest.starts_with(' ') {
            rest = rest[1..].to_string();
        }
    }

    // Walk the rest character-by-character to pick out
    // string literals (double-quoted) and `identifier: Type`
    // shapes. Everything else stays plain.
    let mut buf = String::new();
    let mut chars = rest.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '"' || c == '\'' || c == '`' {
            if !buf.is_empty() {
                spans.push(Span::styled(std::mem::take(&mut buf), ident));
            }
            let quote = c;
            let mut s = String::from(c);
            for nc in chars.by_ref() {
                s.push(nc);
                if nc == quote {
                    break;
                }
            }
            spans.push(Span::styled(s, string_st));
        } else if c == ':' {
            // `identifier: Type` — the type is everything from
            // here to end-of-line or a matching `,`/`;`/`)`/`}`.
            if !buf.is_empty() {
                spans.push(Span::styled(std::mem::take(&mut buf), ident));
            }
            spans.push(Span::styled(":".to_string(), plain));
            // Skip the space after `:` as plain, then color the
            // rest of the type.
            let mut type_str = String::new();
            let mut depth = 0i32;
            while let Some(&pc) = chars.peek() {
                match pc {
                    '(' | '{' | '[' | '<' => depth += 1,
                    ')' | '}' | ']' | '>' if depth > 0 => depth -= 1,
                    ',' | ';' if depth == 0 => break,
                    ')' | '}' | ']' if depth == 0 => break,
                    _ => {}
                }
                type_str.push(pc);
                chars.next();
            }
            spans.push(Span::styled(type_str, ty));
        } else {
            buf.push(c);
        }
    }
    if !buf.is_empty() {
        spans.push(Span::styled(buf, plain));
    }
    Line::from(spans)
}
