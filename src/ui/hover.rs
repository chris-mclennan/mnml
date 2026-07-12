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
    // Clear the popup rect every frame so a stale rect from the
    // previous frame's `hover` state can't survive a dismiss.
    // 2026-07-12 mouse-scroll fix.
    app.rects.hover_popup_rect = None;
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
    // Track the popup rect so the mouse handler can (a) skip
    // dismissing when the pointer moves onto the popup and
    // (b) route wheel-scroll events into `HoverPopup::scroll_by`.
    app.rects.hover_popup_rect = Some(area);
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
    // 2026-07-12 user request — style the hover to match the
    // menu-bar dropdown (see `popup_menu`): square border, `t.bg2`
    // fill, default fg. Same visual vocabulary as every other
    // overlay in mnml (menu bar, context menus, pickers) instead
    // of inventing a per-popup style.
    let mut block = ratatui::widgets::Block::default()
        .borders(ratatui::widgets::Borders::ALL)
        .border_type(ratatui::widgets::BorderType::Plain)
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let title_trim = title.trim();
    if !title_trim.is_empty() {
        block = block.title(Span::styled(
            format!(" {title_trim} "),
            Style::default().fg(t.comment).bg(t.bg2),
        ));
    }
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
        Paragraph::new(view).style(Style::default().bg(t.bg2)),
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
    let plain = Style::default().fg(t.fg).bg(t.bg2);
    let kw = Style::default().fg(t.purple).bg(t.bg2);
    let ident = Style::default().fg(t.fg).bg(t.bg2);
    let ty = Style::default().fg(t.cyan).bg(t.bg2);
    let string_st = Style::default().fg(t.green).bg(t.bg2);
    let comment = Style::default().fg(t.comment).bg(t.bg2);

    // Comment line? Return as-is in comment color.
    if line.trim_start().starts_with("//") {
        return Line::from(Span::styled(line.to_string(), comment));
    }

    // Markdown-lite: LSP hover text often carries `**bold**`
    // (`**Usage**`, `**Example**`), inline `` `code` `` for
    // API names, and prose sentences. Detect any markdown
    // markers and route through the prose renderer; anything
    // else falls through to the code-shape highlighter below.
    // 2026-07-12 user report — was rendering markers literally.
    if line.contains('*') || line.contains('`') || line.starts_with("- ") {
        return render_markdown_line(line, t);
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

/// Render a line that carries markdown markers — `**bold**` and
/// `` `inline code` `` become styled spans; a leading `- ` list
/// marker gets a subtle bullet. Everything else renders as plain
/// prose. 2026-07-12 user report — `**Usage**` was appearing
/// verbatim in the hover popup.
fn render_markdown_line(line: &str, t: &crate::ui::theme::Theme) -> Line<'static> {
    use ratatui::style::Modifier;
    let plain = Style::default().fg(t.fg).bg(t.bg2);
    let bold = Style::default()
        .fg(t.fg)
        .bg(t.bg2)
        .add_modifier(Modifier::BOLD);
    let italic = Style::default()
        .fg(t.fg)
        .bg(t.bg2)
        .add_modifier(Modifier::ITALIC);
    // Inline code — cyan on the same bg as the popup so it lifts
    // subtly without breaking the panel's low-contrast feel.
    let code = Style::default().fg(t.cyan).bg(t.bg2);
    let bullet = Style::default().fg(t.comment).bg(t.bg2);

    let mut spans: Vec<Span<'static>> = Vec::new();
    let mut rest = line.to_string();
    // Leading `- ` → `• `.
    if let Some(after) = rest.strip_prefix("- ") {
        spans.push(Span::styled("• ".to_string(), bullet));
        rest = after.to_string();
    } else if let Some(after) = rest.strip_prefix("* ") {
        spans.push(Span::styled("• ".to_string(), bullet));
        rest = after.to_string();
    }

    // Walk the rest and split on `**…**` (bold), `*…*` (italic),
    // and `` `…` `` (inline code). Unclosed markers render as
    // literal text.
    let mut chars = rest.chars().peekable();
    let mut buf = String::new();
    while let Some(c) = chars.next() {
        if c == '*' && chars.peek() == Some(&'*') {
            // Opener `**` — try to find a closing `**`.
            chars.next(); // consume second *
            let mut inner = String::new();
            let mut closed = false;
            while let Some(nc) = chars.next() {
                if nc == '*' && chars.peek() == Some(&'*') {
                    chars.next();
                    closed = true;
                    break;
                }
                inner.push(nc);
            }
            if closed && !inner.is_empty() {
                if !buf.is_empty() {
                    spans.push(Span::styled(std::mem::take(&mut buf), plain));
                }
                spans.push(Span::styled(inner, bold));
            } else {
                // No matching close — emit `**` + inner literally.
                buf.push_str("**");
                buf.push_str(&inner);
            }
        } else if c == '*' {
            // Opener `*` (single) — italic. Look for a matching
            // single `*` that isn't part of a `**` pair.
            // 2026-07-12 user report — `*@param*` rendered
            // literally in TSDoc hover content.
            let mut inner = String::new();
            let mut closed = false;
            while let Some(&pc) = chars.peek() {
                if pc == '*' {
                    // Peek ahead — if it's `**` we abort this
                    // italic and treat the leading `*` as literal.
                    let mut lookahead = chars.clone();
                    lookahead.next();
                    if lookahead.peek() == Some(&'*') {
                        // Bail out — this `*` starts a bold pair,
                        // not our italic close.
                        break;
                    }
                    chars.next();
                    closed = true;
                    break;
                }
                inner.push(pc);
                chars.next();
            }
            if closed && !inner.is_empty() {
                if !buf.is_empty() {
                    spans.push(Span::styled(std::mem::take(&mut buf), plain));
                }
                spans.push(Span::styled(inner, italic));
            } else {
                buf.push('*');
                buf.push_str(&inner);
            }
        } else if c == '`' {
            // Opener `` ` `` — try to find a matching close.
            let mut inner = String::new();
            let mut closed = false;
            for nc in chars.by_ref() {
                if nc == '`' {
                    closed = true;
                    break;
                }
                inner.push(nc);
            }
            if closed && !inner.is_empty() {
                if !buf.is_empty() {
                    spans.push(Span::styled(std::mem::take(&mut buf), plain));
                }
                spans.push(Span::styled(inner, code));
            } else {
                buf.push('`');
                buf.push_str(&inner);
            }
        } else {
            buf.push(c);
        }
    }
    if !buf.is_empty() {
        spans.push(Span::styled(buf, plain));
    }
    Line::from(spans)
}
