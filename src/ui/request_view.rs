//! The `Pane::Request` view — two modes:
//!
//! * **Response (default)** — read-only summary of the last send: status,
//!   headers, pretty body, `@assert` results, `@capture`s. `r` re-fires.
//! * **Edit** — interactive form: URL, method, headers, body editable in
//!   place. Tab toggles modes; in Edit, Shift-Tab / Tab cycle the focused
//!   field (URL → Method → Headers → Body → URL); Tab inside Body inserts a
//!   literal `\t` (for typing indented JSON / XML); typing / backspace /
//!   arrows / Home / End edit; Space on Method cycles HTTP verbs;
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
    // Detach the click-target registries so the draw fns below can push
    // into them while `rp` is borrowed from `app.panes`. Restored at the
    // bottom (and at the early-return below).
    let mut tabs = std::mem::take(&mut app.rects.request_tabs);
    let mut fields = std::mem::take(&mut app.rects.request_fields);
    let Some(Pane::Request(rp)) = app.panes.get_mut(pane_id) else {
        app.rects.request_tabs = tabs;
        app.rects.request_fields = fields;
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
            "       (Tab toggles view · S-Tab cycles field · r send · y copy curl · esc tree)",
            dim,
        ),
    ]));
    // Register click rects for both tab chips. The tab bar is row 0
    // of the rendered output; layout is:
    //   leading space (1) + "  Edit  " (8) + "  Response  " (12) + hint.
    let tab_y = area.y;
    if area.width > 1 {
        let edit_x = area.x + 1;
        let edit_w = 8u16.min(area.width.saturating_sub(1));
        if edit_w > 0 {
            tabs.push((
                Rect {
                    x: edit_x,
                    y: tab_y,
                    width: edit_w,
                    height: 1,
                },
                pane_id,
                ViewMode::Edit,
            ));
        }
        let resp_x = area.x + 1 + 8;
        if area.x + area.width > resp_x {
            let resp_w = 12u16.min(area.x + area.width - resp_x);
            tabs.push((
                Rect {
                    x: resp_x,
                    y: tab_y,
                    width: resp_w,
                    height: 1,
                },
                pane_id,
                ViewMode::Response,
            ));
        }
    }
    rows.push(plain(String::new(), body_style));

    // ── caret position to return (set when Edit-mode draws the focused field) ──
    let mut caret: Option<(u16, u16)> = None;

    // Edit-tab chip rects collected with `y` = row index in
    // `rows`; corrected to screen y after scroll is computed
    // below (same shape as `request_fields`).
    let mut edit_tabs_local: Vec<(Rect, PaneId, crate::request_pane::EditTab)> = Vec::new();
    app.rects
        .request_edit_tabs
        .retain(|(_, p, _)| *p != pane_id);

    if active_edit {
        let show_ws = app.config.ui.show_whitespace;
        let workspace = app.workspace.clone();
        draw_edit(
            rp,
            t,
            &mut rows,
            area,
            &mut caret,
            focused,
            pane_id,
            &mut fields,
            &mut edit_tabs_local,
            show_ws,
            &workspace,
        );
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
    app.rects.request_tabs = tabs;
    // Field rects were collected with `y` as a row index within `rows`
    // (no scroll offset applied). Adjust by `scroll` + clip to area now
    // that the final scroll value is known.
    for (mut r, pid, f) in fields.drain(..) {
        let row_off = r.y; // row index within `rows`
        if (row_off as usize) < scroll {
            continue;
        }
        let visible_off = row_off as usize - scroll;
        if visible_off >= h {
            continue;
        }
        r.y = area.y + visible_off as u16;
        app.rects.request_fields.push((r, pid, f));
    }
    // 2026-06-19 — api-workflow third hunt SEV-1: tab chip rects
    // were registered with row-index y, but never adjusted for
    // scroll. Clicks compared against screen coords never matched
    // any chip. Apply the same scroll-offset translation as
    // request_fields.
    for (mut r, pid, t) in edit_tabs_local.drain(..) {
        let row_off = r.y;
        if (row_off as usize) < scroll {
            continue;
        }
        let visible_off = row_off as usize - scroll;
        if visible_off >= h {
            continue;
        }
        r.y = area.y + visible_off as u16;
        app.rects.request_edit_tabs.push((r, pid, t));
    }

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

#[allow(clippy::too_many_arguments)]
fn draw_edit(
    rp: &crate::request_pane::RequestPane,
    t: theme::Theme,
    rows: &mut Vec<Line<'static>>,
    area: Rect,
    caret: &mut Option<(u16, u16)>,
    focused: bool,
    pane_id: PaneId,
    fields: &mut Vec<(Rect, PaneId, EditField)>,
    tabs: &mut Vec<(Rect, PaneId, crate::request_pane::EditTab)>,
    show_ws: bool,
    workspace: &std::path::Path,
) {
    // Stash a click-target rect for the row at `row_idx_in_rows` covering
    // the full pane width (y stays as the *row index*; `draw` translates
    // it to a screen y after applying scroll).
    let register_field =
        |fields: &mut Vec<(Rect, PaneId, EditField)>, row_y: u16, field: EditField| {
            fields.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                pane_id,
                field,
            ));
        };
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
    // Left-edge focus bar — bold yellow `▌` when focused (matches the diff
    // swimlane style); subtle `bg2` block when not, so the column is
    // still visually present and easy to anchor on.
    let bar_span = |is_focus: bool| {
        if is_focus {
            Span::styled(
                "▌ ".to_string(),
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )
        } else {
            Span::styled("▏ ".to_string(), Style::default().fg(t.bg3).bg(t.bg_dark))
        }
    };

    // Method
    let m_focus = rp.focus == EditField::Method;
    let method_y = rows.len() as u16;
    rows.push(Line::from(vec![
        bar_span(m_focus),
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
    register_field(fields, method_y, EditField::Method);

    // URL (field — caret rendered when focused)
    let u_focus = rp.focus == EditField::Url;
    let url_text = rp.request.url.clone();
    let label_url = "URL     ".to_string();
    // 2-cell bar prefix + label text length = total prefix-before-input.
    let label_len = 2u16 + label_url.chars().count() as u16;
    let url_y = rows.len() as u16;
    rows.push(Line::from(vec![
        bar_span(u_focus),
        Span::styled(label_url, label_style(u_focus)),
        Span::styled(url_text.clone(), Style::default().fg(t.blue).bg(t.bg_dark)),
    ]));
    register_field(fields, url_y, EditField::Url);
    if u_focus && focused {
        // y = index of the row we just pushed (0-based from rows[0])
        let y = (rows.len() - 1) as u16;
        let caret_col = label_len + url_chars_before_cursor(&url_text, rp.url_cursor) as u16;
        *caret = Some((area.x + caret_col.min(area.width.saturating_sub(1)), y));
    }

    // 2026-06-19 — tabbed Edit view per the rqst Postman-style
    // layout. Tab strip sits between URL + the per-tab content.
    // Tab clicks switch via App.rects.request_tabs.
    {
        use crate::request_pane::EditTab;
        let strip_y = rows.len() as u16;
        let mut spans: Vec<Span> = Vec::new();
        let mut col: u16 = 2;
        for tab in EditTab::ALL {
            let label = tab.label();
            let is_cur = rp.edit_tab == *tab;
            // 2026-06-19 — keyboard hunt SEV-3: the prior cue was
            // BG color only (`bg3` vs `bg_dark`), which flattens
            // on themes with close BG steps + reads as identical
            // to colorblind users. Active tab now renders with
            // bracket markers + UNDERLINED + BOLD, so the cue
            // survives in monochrome.
            let (display, style) = if is_cur {
                (
                    format!("[{label}]"),
                    Style::default()
                        .fg(t.fg)
                        .bg(t.bg3)
                        .add_modifier(Modifier::BOLD | Modifier::UNDERLINED),
                )
            } else {
                (
                    format!(" {label} "),
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )
            };
            let chip_w = display.chars().count() as u16;
            spans.push(Span::styled(display, style));
            spans.push(Span::styled(" ".to_string(), Style::default().bg(t.bg_dark)));
            tabs.push((
                Rect {
                    x: area.x + col,
                    y: strip_y,
                    width: chip_w,
                    height: 1,
                },
                pane_id,
                *tab,
            ));
            col += chip_w + 1;
        }
        rows.push(Line::from(spans));
    }

    // ── Per-tab content ───────────────────────────────────────────────
    let cur_tab = rp.edit_tab;

    if cur_tab == crate::request_pane::EditTab::Headers {
    // Headers (editable as `Key: Value` text; one line per entry)
    let h_focus = rp.focus == EditField::Headers;
    let headers_label_y = rows.len() as u16;
    rows.push(Line::from(vec![
        bar_span(h_focus),
        Span::styled("Headers".to_string(), label_style(h_focus)),
    ]));
    register_field(fields, headers_label_y, EditField::Headers);
    let hb = &rp.headers_buffer;
    if hb.is_empty() {
        let empty_y = rows.len() as u16;
        rows.push(Line::from(vec![Span::styled(
            "    (none — type `Name: value` to add)".to_string(),
            dim,
        )]));
        register_field(fields, empty_y, EditField::Headers);
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
            let row_y = rows.len() as u16;
            rows.push(Line::from(spans));
            register_field(fields, row_y, EditField::Headers);
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
    } // end Headers tab

    if cur_tab == crate::request_pane::EditTab::Body {
    // Body
    let b_focus = rp.focus == EditField::Body;
    let body_label_y = rows.len() as u16;
    rows.push(Line::from(vec![
        bar_span(b_focus),
        Span::styled("Body".to_string(), label_style(b_focus)),
    ]));
    register_field(fields, body_label_y, EditField::Body);
    let body = rp.request.body.as_deref().unwrap_or("");
    if body.is_empty() {
        let empty_y = rows.len() as u16;
        rows.push(Line::from(vec![Span::styled(
            "    (empty)".to_string(),
            dim,
        )]));
        register_field(fields, empty_y, EditField::Body);
    } else {
        for (i, line) in body.lines().enumerate() {
            let row_y = rows.len() as u16;
            // 2026-06-19 — keyboard hunt SEV-3 v2: when
            // [ui] show_whitespace is on, render `\t` as `→` and
            // leading spaces as `·` (matching the editor view) so
            // a user typing Tab in the multi-line Body field
            // actually sees something happen.
            let rendered = if show_ws {
                line.replace('\t', "→")
            } else {
                line.to_string()
            };
            rows.push(Line::from(vec![Span::styled(
                format!("    {rendered}"),
                Style::default().fg(t.grey_fg).bg(t.bg_dark),
            )]));
            register_field(fields, row_y, EditField::Body);
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
    } // end Body tab

    // 2026-06-19 — mouse hunt SEV-2 #5: Params/Vars/Source content
    // rows didn't register click targets, so right-click anywhere
    // in those tabs got no context menu. Register the next-pushed
    // row as `EditField::Url` so the field-aware right-click works
    // (the URL-titled menu has Paste curl + Send + Copy as curl —
    // exactly what a user on the Source tab would want).
    let register_tab_row = |fields: &mut Vec<(Rect, PaneId, EditField)>, row_y: u16| {
        fields.push((
            Rect {
                x: area.x,
                y: row_y,
                width: area.width,
                height: 1,
            },
            pane_id,
            EditField::Url,
        ));
    };
    // ── Params tab: per-key=value rows parsed from URL query string ───
    if cur_tab == crate::request_pane::EditTab::Params {
        let url = &rp.request.url;
        let params: Vec<(String, String)> = match url.find('?') {
            Some(i) => url[i + 1..]
                .split('&')
                .filter(|s| !s.is_empty())
                .map(|kv| match kv.split_once('=') {
                    Some((k, v)) => (k.to_string(), v.to_string()),
                    None => (kv.to_string(), String::new()),
                })
                .collect(),
            None => Vec::new(),
        };
        if params.is_empty() {
            let row_y = rows.len() as u16;
            rows.push(Line::from(vec![Span::styled(
                "    (no query parameters — add ?key=value to URL)".to_string(),
                dim,
            )]));
            register_tab_row(fields, row_y);
        } else {
            for (k, v) in &params {
                let row_y = rows.len() as u16;
                register_tab_row(fields, row_y);
                rows.push(Line::from(vec![
                    Span::styled("    ".to_string(), body_style),
                    Span::styled(
                        k.clone(),
                        Style::default()
                            .fg(t.cyan)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        " = ".to_string(),
                        Style::default().fg(t.comment).bg(t.bg_dark),
                    ),
                    Span::styled(v.clone(), Style::default().fg(t.fg).bg(t.bg_dark)),
                ]));
            }
            rows.push(Line::from(vec![Span::styled(
                "    (edit the URL field to change — Params is read-only for now)".to_string(),
                dim,
            )]));
        }
    }

    // ── Vars tab: read-only list of active env file's KEY=VALUE rows ──
    if cur_tab == crate::request_pane::EditTab::Vars {
        let hint_y = rows.len() as u16;
        rows.push(Line::from(vec![Span::styled(
            "    Active env vars — edit with :http.edit_env".to_string(),
            dim,
        )]));
        register_tab_row(fields, hint_y);
        rows.push(plain(String::new(), body_style));
        // 2026-06-19 v2 — workspace plumbed; read both env files in
        // .rqst → .mnml order and last-wins on same key (matches
        // EnvSet::load precedence + the env editor picker).
        let env_name = crate::http::template::EnvSet::select(workspace, None)
            .name()
            .map(str::to_string)
            .unwrap_or_else(|| "dev".to_string());
        let mut by_key: std::collections::BTreeMap<String, String> =
            std::collections::BTreeMap::new();
        for sub in [".rqst", ".mnml"] {
            let path = workspace
                .join(sub)
                .join("env")
                .join(format!("{env_name}.env"));
            if let Ok(text) = std::fs::read_to_string(&path) {
                for line in text.lines() {
                    let trimmed = line.trim_start();
                    if trimmed.is_empty() || trimmed.starts_with('#') {
                        continue;
                    }
                    if let Some((k, v)) = trimmed.split_once('=') {
                        by_key.insert(k.trim().to_string(), v.trim().to_string());
                    }
                }
            }
        }
        let name_y = rows.len() as u16;
        rows.push(Line::from(vec![Span::styled(
            format!("    env: {env_name}.env"),
            Style::default().fg(t.cyan).bg(t.bg_dark),
        )]));
        register_tab_row(fields, name_y);
        rows.push(plain(String::new(), body_style));
        if by_key.is_empty() {
            let y = rows.len() as u16;
            rows.push(Line::from(vec![Span::styled(
                "    (no env vars in this workspace — :http.edit_env to add)".to_string(),
                dim,
            )]));
            register_tab_row(fields, y);
        } else {
            for (k, v) in &by_key {
                let y = rows.len() as u16;
                register_tab_row(fields, y);
                let preview = if v.len() > 56 {
                    format!("{}…", &v[..54])
                } else {
                    v.clone()
                };
                rows.push(Line::from(vec![
                    Span::styled("    ".to_string(), body_style),
                    Span::styled(
                        k.clone(),
                        Style::default()
                            .fg(t.cyan)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(
                        " = ".to_string(),
                        Style::default().fg(t.comment).bg(t.bg_dark),
                    ),
                    Span::styled(preview, Style::default().fg(t.fg).bg(t.bg_dark)),
                ]));
            }
        }
    }

    // ── Source tab: paste/type raw curl / .http source here, run
    //     `:http.paste_source` (Ctrl+Enter) to parse it into the
    //     structured fields. ──
    if cur_tab == crate::request_pane::EditTab::Source {
        let s_focus = rp.focus == EditField::Source;
        let hint_y = rows.len() as u16;
        rows.push(Line::from(vec![Span::styled(
            "    Source — type / paste curl or .http here · :http.paste_source (Ctrl+Enter)".to_string(),
            dim,
        )]));
        register_tab_row(fields, hint_y);
        rows.push(plain(String::new(), body_style));
        let src = &rp.source_buffer;
        let val_style = Style::default().fg(t.fg).bg(t.bg_dark);
        if src.is_empty() {
            let y = rows.len() as u16;
            rows.push(Line::from(vec![Span::styled(
                "    (empty — paste here, or Ctrl+Shift+V to read clipboard)".to_string(),
                dim,
            )]));
            register_tab_row(fields, y);
            // If focused, render caret at left margin so the user
            // sees where their typing will land.
            if s_focus && focused && caret.is_none() {
                let y = (rows.len() - 1) as u16;
                *caret = Some((area.x + 4, y));
            }
        } else {
            for (i, line) in src.lines().enumerate() {
                let y = rows.len() as u16;
                register_tab_row(fields, y);
                rows.push(Line::from(vec![Span::styled(
                    format!("    {line}"),
                    val_style,
                )]));
                if s_focus && focused && caret.is_none() {
                    let start = nth_line_start(src, i);
                    let end = nth_line_end(src, i);
                    if rp.source_cursor >= start && rp.source_cursor <= end {
                        let col = src[start..rp.source_cursor.min(src.len())]
                            .chars()
                            .count() as u16;
                        let yy = (rows.len() - 1) as u16;
                        *caret = Some((area.x + 4 + col, yy));
                    }
                }
            }
            if s_focus && focused && caret.is_none() && src.ends_with('\n') {
                let y = rows.len() as u16;
                rows.push(plain(String::new(), body_style));
                *caret = Some((area.x + 4, y));
            }
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
