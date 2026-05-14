//! The `Pane::Request` view — two modes:
//!
//! * **Response (default)** — read-only summary of the last send: status,
//!   headers, pretty body, `@assert` results, `@capture`s. `r` re-fires.
//! * **Edit** — Postman-style form: URL, method, body editable in place. Tab
//!   toggles modes; in Edit, Shift-Tab / Tab cycle the focused field; typing /
//!   backspace / arrows / Home / End edit; Space on Method cycles HTTP verbs;
//!   `r` re-fires with the edited values.
//!
//! Long lines clip (no wrap yet).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::request_pane::{EditField, RunState, ViewMode};
use crate::ui::theme;

pub fn draw(
    frame: &mut Frame,
    app: &mut App,
    pane_id: PaneId,
    area: Rect,
    focused: bool,
) -> Option<(u16, u16)> {
    if area.width == 0 || area.height == 0 {
        return None;
    }
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );
    let Some(Pane::Request(rp)) = app.panes.get_mut(pane_id) else {
        return None;
    };

    let body_style = Style::default().fg(t.fg).bg(t.bg_dark);
    let dim = Style::default().fg(t.comment).bg(t.bg_dark);
    let mut rows: Vec<Line> = Vec::new();
    let plain = |s: String, st: Style| Line::from(Span::styled(s, st));

    // ── tab bar — [Edit] [Response] ──
    let active_edit = rp.view == ViewMode::Edit;
    let tab = |label: &str, active: bool| {
        let mut st = Style::default().fg(t.fg).bg(t.bg_dark);
        if active {
            st = st
                .fg(t.yellow)
                .add_modifier(Modifier::BOLD | Modifier::UNDERLINED);
        } else {
            st = st.fg(t.comment);
        }
        Span::styled(format!("  {label}  "), st)
    };
    rows.push(Line::from(vec![
        Span::styled(" ", body_style),
        tab("Edit", active_edit),
        tab("Response", !active_edit),
        Span::styled(
            "       (Tab toggles · r send · y copy curl · esc tree)",
            dim,
        ),
    ]));
    rows.push(plain(String::new(), body_style));

    // ── caret position to return (set when Edit-mode draws the focused field) ──
    let mut caret: Option<(u16, u16)> = None;

    if active_edit {
        draw_edit(rp, t, &mut rows, area, &mut caret, focused);
    } else {
        draw_response(rp, t, &mut rows);
    }

    // scroll — Response can be long; Edit is short
    let h = area.height as usize;
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    rp.scroll = rp.scroll.min(max_scroll);
    let scroll = rp.scroll;
    let view: Vec<Line> = rows.into_iter().skip(scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));

    // Adjust the caret for scroll + return it so the terminal cursor sits there.
    caret.and_then(|(x, y)| {
        let y_off = y.checked_sub(scroll as u16)?;
        if y_off < area.height {
            Some((x, area.y + y_off))
        } else {
            None
        }
    })
}

fn draw_edit(
    rp: &crate::request_pane::RequestPane,
    t: theme::Theme,
    rows: &mut Vec<Line<'static>>,
    area: Rect,
    caret: &mut Option<(u16, u16)>,
    focused: bool,
) {
    let body_style = Style::default().fg(t.fg).bg(t.bg_dark);
    let plain = |s: String, st: Style| Line::from(Span::styled(s, st));
    let dim = Style::default().fg(t.comment).bg(t.bg_dark);
    let label_style = |is_focus: bool| {
        let mut st = Style::default().bg(t.bg_dark);
        if is_focus {
            st = st.fg(t.yellow).add_modifier(Modifier::BOLD);
        } else {
            st = st.fg(t.comment);
        }
        st
    };
    let prefix = |is_focus: bool| if is_focus { "▸ " } else { "  " };

    // Method
    let m_focus = rp.focus == EditField::Method;
    rows.push(Line::from(vec![
        Span::styled(prefix(m_focus).to_string(), label_style(m_focus)),
        Span::styled("Method  ", label_style(m_focus)),
        Span::styled(
            rp.request.method.clone(),
            Style::default()
                .fg(t.green)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled("   (space → cycle)".to_string(), dim),
    ]));

    // URL (field — caret rendered when focused)
    let u_focus = rp.focus == EditField::Url;
    let url_text = rp.request.url.clone();
    let label_url = format!("{}URL     ", prefix(u_focus));
    let label_len = label_url.chars().count() as u16;
    rows.push(Line::from(vec![
        Span::styled(label_url, label_style(u_focus)),
        Span::styled(url_text.clone(), Style::default().fg(t.blue).bg(t.bg_dark)),
    ]));
    if u_focus && focused {
        // y = index of the row we just pushed (0-based from rows[0])
        let y = (rows.len() - 1) as u16;
        let caret_col = label_len + url_chars_before_cursor(&url_text, rp.url_cursor) as u16;
        *caret = Some((area.x + caret_col.min(area.width.saturating_sub(1)), y));
    }

    // Headers (editable as `Key: Value` text; one line per entry)
    let h_focus = rp.focus == EditField::Headers;
    rows.push(Line::from(vec![Span::styled(
        format!("{}Headers", prefix(h_focus)),
        label_style(h_focus),
    )]));
    let hb = &rp.headers_buffer;
    if hb.is_empty() {
        rows.push(Line::from(vec![Span::styled(
            "    (none — type `Name: value` to add)".to_string(),
            dim,
        )]));
        if h_focus && focused && caret.is_none() {
            let y = (rows.len() - 1) as u16;
            *caret = Some((area.x + 4, y));
        }
    } else {
        // Style each header line as `<key in cyan> : <value in fg>` —
        // editing model is still the flat textarea (the user types `Name:
        // value\n` like before), but at render time we split on the first
        // `:` to color-code. Lines without `:` (mid-edit) render in dim
        // gray as a hint they're not yet a valid header.
        let key_style = Style::default()
            .fg(t.cyan)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD);
        let sep_style = Style::default().fg(t.comment).bg(t.bg_dark);
        let val_style = Style::default().fg(t.fg).bg(t.bg_dark);
        let plain_dim = Style::default().fg(t.comment).bg(t.bg_dark);
        for (i, line) in hb.lines().enumerate() {
            let spans: Vec<Span> = if let Some(colon) = line.find(':') {
                let (k, rest) = line.split_at(colon);
                // Skip the `:` itself; preserve any leading space in the value.
                let v = &rest[1..];
                vec![
                    Span::styled("    ".to_string(), val_style),
                    Span::styled(k.to_string(), key_style),
                    Span::styled(":".to_string(), sep_style),
                    Span::styled(v.to_string(), val_style),
                ]
            } else {
                vec![Span::styled(format!("    {line}"), plain_dim)]
            };
            rows.push(Line::from(spans));
            if h_focus && focused && caret.is_none() {
                let start = nth_line_start(hb, i);
                let end = nth_line_end(hb, i);
                if rp.headers_cursor >= start && rp.headers_cursor <= end {
                    let col_in_line =
                        hb[start..rp.headers_cursor.min(hb.len())].chars().count() as u16;
                    let y = (rows.len() - 1) as u16;
                    *caret = Some((area.x + 4 + col_in_line, y));
                }
            }
        }
        if h_focus && focused && caret.is_none() && hb.ends_with('\n') {
            let y = rows.len() as u16;
            rows.push(plain(String::new(), body_style));
            *caret = Some((area.x + 4, y));
        }
    }

    // Body
    let b_focus = rp.focus == EditField::Body;
    rows.push(Line::from(vec![Span::styled(
        format!("{}Body", prefix(b_focus)),
        label_style(b_focus),
    )]));
    let body = rp.request.body.as_deref().unwrap_or("");
    if body.is_empty() {
        rows.push(Line::from(vec![Span::styled(
            "    (empty)".to_string(),
            dim,
        )]));
    } else {
        for (i, line) in body.lines().enumerate() {
            rows.push(Line::from(vec![Span::styled(
                format!("    {line}"),
                Style::default().fg(t.grey_fg).bg(t.bg_dark),
            )]));
            if b_focus && focused && caret.is_none() {
                let body_offset_of_line_start = nth_line_start(body, i);
                let body_offset_of_line_end = nth_line_end(body, i);
                if rp.body_cursor >= body_offset_of_line_start
                    && rp.body_cursor <= body_offset_of_line_end
                {
                    let col_in_line = body
                        [body_offset_of_line_start..rp.body_cursor.min(body.len())]
                        .chars()
                        .count() as u16;
                    let y = (rows.len() - 1) as u16;
                    let prefix_cols = 4u16;
                    *caret = Some((area.x + prefix_cols + col_in_line, y));
                }
            }
        }
        // Trailing newline ⇒ caret on an empty line at the end.
        if b_focus && focused && caret.is_none() && body.ends_with('\n') {
            let y = rows.len() as u16;
            rows.push(plain(String::new(), body_style));
            *caret = Some((area.x + 4, y));
        }
    }

    // Sending/Done indicator (small).
    rows.push(plain(String::new(), body_style));
    match &rp.state {
        RunState::Sending => rows.push(plain(
            "  ⟳ sending…".to_string(),
            Style::default().fg(t.yellow).bg(t.bg_dark),
        )),
        RunState::Failed(e) => rows.push(plain(
            format!("  ✗ last send: {e}"),
            Style::default().fg(t.red).bg(t.bg_dark),
        )),
        RunState::Done(r) => rows.push(plain(
            format!("  ✓ last: {} ({} ms)", r.status, r.elapsed.as_millis()),
            Style::default().fg(t.green).bg(t.bg_dark),
        )),
    }
}

fn url_chars_before_cursor(text: &str, byte_cursor: usize) -> usize {
    text[..byte_cursor.min(text.len())].chars().count()
}

fn nth_line_start(text: &str, n: usize) -> usize {
    let mut idx = 0usize;
    for _ in 0..n {
        match text[idx..].find('\n') {
            Some(off) => idx += off + 1,
            None => return text.len(),
        }
    }
    idx
}
fn nth_line_end(text: &str, n: usize) -> usize {
    let start = nth_line_start(text, n);
    match text[start..].find('\n') {
        Some(off) => start + off,
        None => text.len(),
    }
}

fn draw_response(
    rp: &crate::request_pane::RequestPane,
    t: theme::Theme,
    rows: &mut Vec<Line<'static>>,
) {
    let body_style = Style::default().fg(t.fg).bg(t.bg_dark);
    let dim = Style::default().fg(t.comment).bg(t.bg_dark);
    let plain = |s: String, st: Style| Line::from(Span::styled(s, st));

    // ── request line + headers + body (read-only summary) ──
    rows.push(Line::from(vec![
        Span::styled("▶ ", Style::default().fg(t.yellow).bg(t.bg_dark)),
        Span::styled(
            format!("{} ", rp.request.method),
            Style::default()
                .fg(t.green)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            rp.request.url.clone(),
            Style::default().fg(t.blue).bg(t.bg_dark),
        ),
    ]));
    for (k, v) in &rp.request.headers {
        rows.push(plain(format!("  {k}: {v}"), dim));
    }
    if let Some(b) = &rp.request.body {
        rows.push(plain(String::new(), body_style));
        for l in b.lines() {
            rows.push(plain(
                format!("  {l}"),
                Style::default().fg(t.grey_fg).bg(t.bg_dark),
            ));
        }
    }
    rows.push(plain(String::new(), body_style));

    // ── response ──
    match &rp.state {
        RunState::Sending => {
            rows.push(plain(
                "  ⟳ sending…".to_string(),
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ));
        }
        RunState::Failed(e) => {
            rows.push(plain(
                format!("  ✗ {e}"),
                Style::default()
                    .fg(t.red)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ));
        }
        RunState::Done(r) => {
            let status_color = match r.status {
                200..=299 => t.green,
                300..=399 => t.yellow,
                400..=499 => t.orange,
                _ => t.red,
            };
            rows.push(Line::from(vec![
                Span::styled("← ", Style::default().fg(t.yellow).bg(t.bg_dark)),
                Span::styled(
                    format!("{} {}", r.status, r.status_text),
                    Style::default()
                        .fg(status_color)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("   {} ms", r.elapsed.as_millis()), dim),
            ]));
            for (k, v) in &r.headers {
                rows.push(plain(format!("  {k}: {v}"), dim));
            }
            rows.push(plain(String::new(), body_style));
            let pretty = pretty_body(&r.body, &r.headers);
            for l in pretty.lines() {
                rows.push(plain(l.to_string(), body_style));
            }
            if !r.assertions.is_empty() {
                rows.push(plain(String::new(), body_style));
                for a in &r.assertions {
                    if a.passed {
                        rows.push(plain(
                            format!("  ✓ {}", a.label),
                            Style::default().fg(t.green).bg(t.bg_dark),
                        ));
                    } else {
                        let line = match &a.detail {
                            Some(d) => format!("  ✗ {} — {d}", a.label),
                            None => format!("  ✗ {}", a.label),
                        };
                        rows.push(plain(line, Style::default().fg(t.red).bg(t.bg_dark)));
                    }
                }
            }
            if !r.captures.is_empty() {
                rows.push(plain(String::new(), body_style));
                for (name, value) in &r.captures {
                    rows.push(Line::from(vec![
                        Span::styled(
                            format!("  ⇒ {name} = "),
                            Style::default().fg(t.cyan).bg(t.bg_dark),
                        ),
                        Span::styled(
                            value.clone(),
                            Style::default()
                                .fg(t.cyan)
                                .bg(t.bg_dark)
                                .add_modifier(Modifier::BOLD),
                        ),
                    ]));
                }
            }
        }
    }
}

/// Pretty-print a body if it looks like JSON; otherwise return it as-is.
fn pretty_body(body: &str, headers: &[(String, String)]) -> String {
    let is_json = headers
        .iter()
        .any(|(k, v)| k.eq_ignore_ascii_case("content-type") && v.contains("json"))
        || {
            let b = body.trim_start();
            b.starts_with('{') || b.starts_with('[')
        };
    if is_json
        && let Ok(v) = serde_json::from_str::<serde_json::Value>(body)
        && let Ok(p) = serde_json::to_string_pretty(&v)
    {
        return p;
    }
    body.to_string()
}
