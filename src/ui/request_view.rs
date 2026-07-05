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
use crate::request_pane::{EditField, RunState};
use crate::ui::theme;

/// Section header chip — matches the app-wide `modal_panel` title
/// look (cyan bg + bg_dark fg + BOLD). Used for `response`, `ai`,
/// and any future section title inside the Request pane so all
/// section labels read as the same design primitive (#11).
fn section_header_chip(text: &'static str, t: theme::Theme) -> Line<'static> {
    Line::from(Span::styled(
        text,
        Style::default()
            .fg(t.bg_dark)
            .bg(t.cyan)
            .add_modifier(Modifier::BOLD),
    ))
}

/// Verb → chip color. Shared between the edit-row method chip and
/// the response-summary method chip so a new HTTP verb only needs to
/// land in one place.
fn method_color(method: &str, t: theme::Theme) -> ratatui::style::Color {
    match method.to_uppercase().as_str() {
        "GET" => t.green,
        "POST" => t.orange,
        "PUT" => t.blue,
        "PATCH" => t.cyan,
        "DELETE" => t.red,
        "HEAD" => t.yellow,
        "OPTIONS" => t.purple,
        _ => t.fg,
    }
}

/// One-line HTTP header row rendered as `<key in cyan bold> : <value>`.
/// Used everywhere a header list shows up (Edit-tab Headers section,
/// request-line summary in the response panel, actual response
/// headers) so the same styling reads across all three sites. (#11)
fn header_row(key: &str, value: &str, t: theme::Theme) -> Line<'static> {
    Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            key.to_string(),
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(": ", Style::default().fg(t.comment).bg(t.bg_dark)),
        Span::styled(value.to_string(), Style::default().fg(t.fg).bg(t.bg_dark)),
    ])
}

/// Case-insensitive substring match on either the key or the value.
/// Empty filter always matches. Used to hide header rows that don't
/// match the pane's `/` filter query (#11).
fn header_matches_filter(key: &str, value: &str, q_lower: &str) -> bool {
    if q_lower.is_empty() {
        return true;
    }
    key.to_ascii_lowercase().contains(q_lower) || value.to_ascii_lowercase().contains(q_lower)
}

/// Count filter matches across request headers + response headers +
/// response body lines. Returns `(matched, total)` for the filter
/// chip's hit indicator. Returns `None` when the filter is empty. (#11)
fn compute_filter_hits(rp: &crate::request_pane::RequestPane) -> Option<(usize, usize)> {
    let q = rp.filter.trim().to_ascii_lowercase();
    if q.is_empty() {
        return None;
    }
    let mut matched = 0usize;
    let mut total = 0usize;
    for (k, v) in &rp.request.headers {
        total += 1;
        if header_matches_filter(k, v, &q) {
            matched += 1;
        }
    }
    if let RunState::Done(r) = &rp.state {
        for (k, v) in &r.headers {
            total += 1;
            if header_matches_filter(k, v, &q) {
                matched += 1;
            }
        }
        for line in r.body.lines() {
            total += 1;
            if line.to_ascii_lowercase().contains(&q) {
                matched += 1;
            }
        }
    }
    Some((matched, total))
}

/// Filter chip row rendered at the top of the response section when
/// the pane's `/` filter is active. Placeholder reads `/ filter` when
/// unfocused, `type to filter…` when focused. `▏` cursor marks focus.
/// Matches the sidebar-filter idiom across the app (#11).
fn filter_row(
    filter: &str,
    focused: bool,
    hits: Option<(usize, usize)>,
    t: theme::Theme,
) -> Line<'static> {
    let display = if filter.is_empty() {
        if focused {
            "type to filter headers + body…".to_string()
        } else {
            "/ filter response".to_string()
        }
    } else {
        filter.to_string()
    };
    let fg = if !filter.is_empty() {
        t.fg
    } else if focused {
        t.cyan
    } else {
        t.comment
    };
    let cursor = if focused { "▏" } else { "" };
    let search_glyph = "\u{f002}";
    let mut spans = vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            format!("{search_glyph} "),
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
        Span::styled(display, Style::default().fg(fg).bg(t.bg_dark)),
        Span::styled(cursor, Style::default().fg(t.cyan).bg(t.bg_dark)),
    ];
    // Hit count chip — shows only when the filter is set. Colors track
    // whether there's a match (cyan) or none (red).
    if !filter.is_empty()
        && let Some((matched, total)) = hits
    {
        let count_color = if matched > 0 { t.cyan } else { t.red };
        spans.push(Span::styled(
            format!("   {matched}/{total}"),
            Style::default()
                .fg(count_color)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ));
    }
    Line::from(spans)
}

/// Convert a source line + tree-sitter colored spans into a ratatui
/// `Line` with per-token coloring on `bg_dark`. Bytes not covered by
/// any span render with the base `fg` color. Used to syntax-highlight
/// JSON response bodies. (#11)
fn colored_line(
    src: &str,
    spans: &[crate::highlight::ColoredSpan],
    base_fg: ratatui::style::Color,
    t: theme::Theme,
) -> Line<'static> {
    if spans.is_empty() {
        return Line::from(Span::styled(
            src.to_string(),
            Style::default().fg(base_fg).bg(t.bg_dark),
        ));
    }
    // Walk sorted spans and emit interleaved text — uncovered bytes
    // in `base_fg`, covered runs in their span color. Robust against
    // overlapping spans by ordering + skipping any span that ends
    // before the current cursor.
    let mut ordered: Vec<crate::highlight::ColoredSpan> = spans.to_vec();
    ordered.sort_by_key(|(s, _, _)| *s);
    let mut out: Vec<Span<'static>> = Vec::new();
    let mut cursor = 0usize;
    let bytes = src.as_bytes();
    for (s, e, color) in ordered {
        let s = s.min(bytes.len());
        let e = e.min(bytes.len());
        if e <= cursor {
            continue;
        }
        if s > cursor {
            // Emit uncovered chunk in the base fg.
            let chunk = String::from_utf8_lossy(&bytes[cursor..s]).into_owned();
            out.push(Span::styled(
                chunk,
                Style::default().fg(base_fg).bg(t.bg_dark),
            ));
        }
        let start = s.max(cursor);
        let chunk = String::from_utf8_lossy(&bytes[start..e]).into_owned();
        out.push(Span::styled(
            chunk,
            Style::default().fg(color).bg(t.bg_dark),
        ));
        cursor = e;
    }
    if cursor < bytes.len() {
        let tail = String::from_utf8_lossy(&bytes[cursor..]).into_owned();
        out.push(Span::styled(
            tail,
            Style::default().fg(base_fg).bg(t.bg_dark),
        ));
    }
    Line::from(out)
}

/// `+ <label>` action row — matches the "+ New note" / "+ New session"
/// / "+ New request" chip idiom used across the activity-bar panels
/// (Notes, Sessions, HTTP). Green fg + BOLD reads as "additive
/// affordance" everywhere in the app. Extracted so Params / Vars /
/// Auth-set rows all read the same. (#11)
fn add_action_row(label: &str, t: theme::Theme) -> Line<'static> {
    Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            format!("+ {label}"),
            Style::default()
                .fg(t.green)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ])
}

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
    // 2026-06-20 — `tabs` (the old Edit/Response chip rects) and
    // the top-level body_style/dim/plain locals went unused when
    // the tab strip was removed; cleaned up.
    let mut fields = std::mem::take(&mut app.rects.request_fields);
    let Some(Pane::Request(rp)) = app.panes.get_mut(pane_id) else {
        app.rects.request_fields = fields;
        return None;
    };
    let mut rows: Vec<Line> = Vec::new();

    // 2026-06-20 — removed [Edit][Response] tab strip. New
    // Postman-style layout shows Request / Response / AI sections
    // stacked vertically — both Edit and Response are always
    // visible. `rp.view` still gates the key handler routing
    // (edit-mode keys vs. response-mode scroll/refire) for now;
    // user can flip with Tab or just type to land in fields.
    // 2026-06-20 — removed Edit/Response click-rect registration
    // since the visual tab strip is gone. `tabs` (the App.rects
    // collection) is still drained/restored so the existing
    // caller pattern keeps working, but no chips push into it
    // from here anymore.
    let _ = pane_id;

    // ── caret position to return (set when Edit-mode draws the focused field) ──
    let mut caret: Option<(u16, u16)> = None;

    // Edit-tab chip rects collected with `y` = row index in
    // `rows`; corrected to screen y after scroll is computed
    // below (same shape as `request_fields`).
    let mut edit_tabs_local: Vec<(Rect, PaneId, crate::request_pane::EditTab)> = Vec::new();
    app.rects
        .request_edit_tabs
        .retain(|(_, p, _)| *p != pane_id);

    // 2026-06-20 — three-panel layout (Postman-style). Render all
    // three sections vertically: Request (URL+tabs+content),
    // Response (status+body), AI prompt at the bottom. The
    // Edit/Response tab strip above is now visual scaffolding;
    // the user can scroll the combined output to see whatever
    // they need. rp.view stays as an internal hint for the
    // tab-strip rendering above but doesn't gate which sections
    // draw — both always draw.
    let show_ws = app.config.ui.show_whitespace;
    let workspace = app.workspace.clone();
    let env_override = app.http_env_override.clone();
    let mut vars_rows_local: Vec<(Rect, String)> = Vec::new();
    let mut params_rows_local: Vec<(Rect, String)> = Vec::new();
    let mut auth_rows_local: Vec<(Rect, String)> = Vec::new();
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
        env_override.as_deref(),
        &mut vars_rows_local,
        &mut params_rows_local,
        &mut auth_rows_local,
    );

    // Section divider + Response panel. Design polish (#11): use a
    // consistent inline "chip" title matching the app-wide
    // `modal_panel` title-bar look (cyan bg + bg_dark fg + BOLD),
    // instead of per-section yellow / orange bold text. Reads as
    // the same design primitive as every other section title.
    rows.push(Line::from(Span::raw("")));
    rows.push(section_header_chip(" response ", t));
    // Filter chip lives directly under the response header — appears
    // whenever the filter is active OR focused (so users see the "/"
    // hint even before typing). Empty + unfocused = hidden to keep
    // the pane quiet on first render.
    if !rp.filter.is_empty() || rp.filter_focused {
        // Precompute matched/total for the hit-count chip so the
        // filter row itself carries the feedback. Walks request
        // headers + response headers + body lines. (#11 polish)
        let hits = compute_filter_hits(rp);
        rows.push(filter_row(&rp.filter, rp.filter_focused, hits, t));
    }
    rows.push(Line::from(Span::raw("")));
    let wrap_width = if rp.body_wrap {
        Some(area.width.saturating_sub(4).max(20))
    } else {
        None
    };
    draw_response(rp, t, &mut rows, wrap_width);

    // 2026-06-20 — AI section now PINNED to the bottom of the pane
    // (poor man's independent scrolling). The Request + Response
    // rows scroll within the top region; the AI header always
    // stays visible at the bottom 2 rows so the affordance never
    // hides itself. Saves a full per-section scroll refactor.
    const AI_ROWS: u16 = 2; // separator + header line

    // scroll — Response can be long; Edit is short. Scrollable
    // viewport is everything EXCEPT the bottom AI strip.
    let h = area.height.saturating_sub(AI_ROWS) as usize;
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    rp.scroll = rp.scroll.min(max_scroll);
    let scroll = rp.scroll;
    let view: Vec<Line> = rows.into_iter().skip(scroll).take(h).collect();
    let upper = Rect {
        x: area.x,
        y: area.y,
        width: area.width,
        height: area.height.saturating_sub(AI_ROWS),
    };
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        upper,
    );
    // Pinned AI strip — drawn as a fresh 2-row Paragraph at the
    // bottom. Click rect is registered against ai_strip.y.
    if area.height >= AI_ROWS {
        let ai_strip = Rect {
            x: area.x,
            y: area.y + area.height - AI_ROWS,
            width: area.width,
            height: AI_ROWS,
        };
        let ai_lines: Vec<Line> = vec![
            // Row 0: blank (breathing room above the chip).
            Line::from(Span::raw("")),
            // Row 1: `ai` chip + hint — click rect below points here.
            // Hint uses `hint_style()` (comment fg on the panel bg)
            // so the underline / attention treatment doesn't compete
            // with the cyan chip. Cleaner visual weight.
            Line::from(vec![
                section_header_chip(" ai ", t).spans[0].clone(),
                Span::styled(
                    "   click here to ask a custom question   ".to_string(),
                    crate::ui::design_tokens::hint_style(),
                ),
                Span::styled(
                    "· `a`  quick debug".to_string(),
                    Style::default()
                        .fg(t.comment)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::DIM),
                ),
            ]),
        ];
        frame.render_widget(
            Paragraph::new(ai_lines).style(Style::default().bg(t.bg_dark)),
            ai_strip,
        );
        // Header rect = the bottom row only.
        app.rects.request_ai_section = Some(Rect {
            x: ai_strip.x,
            y: ai_strip.y + 1,
            width: ai_strip.width,
            height: 1,
        });
    } else {
        app.rects.request_ai_section = None;
    }
    app.rects.editor_panes.push((area, pane_id));
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
    // Vars-row rects → screen-y, push into App.rects.
    app.rects.request_vars_rows.clear();
    for (mut r, key) in vars_rows_local.drain(..) {
        let row_off = r.y;
        if (row_off as usize) < scroll {
            continue;
        }
        let visible_off = row_off as usize - scroll;
        if visible_off >= h {
            continue;
        }
        r.y = area.y + visible_off as u16;
        app.rects.request_vars_rows.push((r, key));
    }
    // Params-row rects → screen-y.
    app.rects.request_params_rows.clear();
    for (mut r, key) in params_rows_local.drain(..) {
        let row_off = r.y;
        if (row_off as usize) < scroll {
            continue;
        }
        let visible_off = row_off as usize - scroll;
        if visible_off >= h {
            continue;
        }
        r.y = area.y + visible_off as u16;
        app.rects.request_params_rows.push((r, key));
    }
    // Auth-row rects → screen-y.
    app.rects.request_auth_rows.clear();
    for (mut r, id) in auth_rows_local.drain(..) {
        let row_off = r.y;
        if (row_off as usize) < scroll {
            continue;
        }
        let visible_off = row_off as usize - scroll;
        if visible_off >= h {
            continue;
        }
        r.y = area.y + visible_off as u16;
        app.rects.request_auth_rows.push((r, id));
    }
    // (AI section rect registered when its pinned strip is drawn.)

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
    env_override: Option<&str>,
    vars_rows_local: &mut Vec<(Rect, String)>,
    params_rows_local: &mut Vec<(Rect, String)>,
    auth_rows_local: &mut Vec<(Rect, String)>,
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
            // Cyan matches the tab-strip active color + the section
            // header chip, so every "this is the focused thing"
            // signal in the pane speaks the same accent.
            st = st.fg(t.cyan).add_modifier(Modifier::BOLD);
        } else {
            st = st.fg(t.comment);
        }
        st
    };
    // Left-edge focus bar — bold cyan `▌` when focused (matches the
    // menu-family focus indicator across settings + agents +
    // integrations); subtle `bg3` block when not, so the column is
    // still visually present and easy to anchor on.
    let bar_span = |is_focus: bool| {
        if is_focus {
            Span::styled(
                "▌ ".to_string(),
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )
        } else {
            Span::styled("▏ ".to_string(), Style::default().fg(t.bg3).bg(t.bg_dark))
        }
    };

    // 2026-06-20 — Method + URL on the same line, Postman-style.
    // Method renders as a colored chip — GET green, POST orange,
    // PUT blue, PATCH cyan, DELETE red, HEAD yellow, OPTIONS
    // magenta. Click the chip → :http.cycle_method advances the
    // verb (also Space when focused). URL fills the rest of the
    // line.
    let m_focus = rp.focus == EditField::Method;
    let u_focus = rp.focus == EditField::Url;
    let method = rp.request.method.to_uppercase();
    let m_color = method_color(&method, t);
    let method_chip = format!(" {method} ");
    let method_chip_len = method_chip.chars().count() as u16;
    let method_y = rows.len() as u16;
    let url_text = rp.request.url.clone();
    rows.push(Line::from(vec![
        bar_span(m_focus || u_focus),
        Span::styled(
            method_chip,
            Style::default()
                .fg(t.bg_dark)
                .bg(m_color)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled("  ".to_string(), Style::default().bg(t.bg_dark)),
        Span::styled(url_text.clone(), Style::default().fg(t.fg).bg(t.bg_dark)),
    ]));
    // Method chip rect — narrow (just the chip, no row-spanning).
    // Click triggers cycle in tui.rs (gated on `rect.width ≤ 12`).
    fields.push((
        Rect {
            x: area.x + 2, // skip bar
            y: method_y,
            width: method_chip_len,
            height: 1,
        },
        pane_id,
        EditField::Method,
    ));
    // URL field rect — area AFTER the method chip + 2 pad.
    fields.push((
        Rect {
            x: area.x + 2 + method_chip_len + 2,
            y: method_y,
            width: area.width.saturating_sub(2 + method_chip_len + 2),
            height: 1,
        },
        pane_id,
        EditField::Url,
    ));
    // Label offset for caret math now = bar (2) + chip + 2 spaces.
    let label_len = 2u16 + method_chip_len + 2;
    let _url_y = method_y; // kept for the URL caret-positioning math reference
    if u_focus && focused {
        // y = index of the row we just pushed (0-based from rows[0])
        let y = (rows.len() - 1) as u16;
        let caret_col = label_len + url_chars_before_cursor(&url_text, rp.url_cursor) as u16;
        *caret = Some((area.x + caret_col.min(area.width.saturating_sub(1)), y));
    }

    // Tab strip (Params / Headers / Body / Auth / Vars / Source).
    // Active tab uses the shared menu-family highlight (cyan bg +
    // bg_dark fg + BOLD) — the same primitive as menu bar / context
    // menu / settings row selection. Inactive tabs render as dim
    // comment-fg text on the panel bg. Visual cue survives
    // monochrome via BOLD on the active tab.
    {
        use crate::request_pane::EditTab;
        let strip_y = rows.len() as u16;
        // Leading blank row so the strip has breathing room from
        // the URL bar above.
        rows.push(Line::from(Span::raw("")));
        let mut spans: Vec<Span> = Vec::new();
        let strip_y = strip_y + 1;
        let mut col: u16 = 2;
        // Leading pad column so the strip aligns with the URL row.
        spans.push(Span::styled("  ", Style::default().bg(t.bg_dark)));
        for tab in EditTab::ALL {
            let label = tab.label();
            let is_cur = rp.edit_tab == *tab;
            let display = format!(" {label} ");
            let style = if is_cur {
                crate::ui::design_tokens::row_highlight_menu()
            } else {
                Style::default().fg(t.comment).bg(t.bg_dark)
            };
            let chip_w = display.chars().count() as u16;
            spans.push(Span::styled(display, style));
            // 1-cell separator between chips — panel bg so the
            // active chip's cyan doesn't smear into its neighbor.
            spans.push(Span::styled(
                " ".to_string(),
                Style::default().bg(t.bg_dark),
            ));
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
        // Count of header lines (non-empty, non-comment) — surfaced
        // in the section label as `Headers (N)` so users know the
        // list size without scrolling / counting. (#11 polish)
        let hdr_count = rp
            .headers_buffer
            .lines()
            .filter(|l| !l.trim().is_empty() && !l.trim().starts_with('#'))
            .count();
        let count_suffix = if hdr_count > 0 {
            format!(" ({hdr_count})")
        } else {
            String::new()
        };
        rows.push(Line::from(vec![
            bar_span(h_focus),
            Span::styled(format!("Headers{count_suffix}"), label_style(h_focus)),
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
        let body = rp.request.body.as_deref().unwrap_or("");
        // 2026-06-20 — detect content type from body shape so the
        // user sees what mnml thinks the body is. JSON / XML /
        // form-encoded / plain.
        let detected = detect_body_kind(body);
        let kind_label = if let Some(k) = detected {
            format!("  ({k}) — Ctrl+Shift+F formats JSON")
        } else {
            String::new()
        };
        rows.push(Line::from(vec![
            bar_span(b_focus),
            Span::styled("Body".to_string(), label_style(b_focus)),
            Span::styled(
                kind_label,
                Style::default()
                    .fg(t.comment)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::DIM),
            ),
        ]));
        register_field(fields, body_label_y, EditField::Body);
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
    // ── Params tab — `+ Add` row + clickable existing params.
    //     Click `+ Add` → :http.params_add prompt; click a row → no-op
    //     today (v2: edit prompt). Mirrors the Vars tab UX. ───
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
        // `+ Add new parameter…` action row — uses the shared
        // add_action_row helper so this reads the same as `+ New
        // request` / `+ New note` / `+ New session` chips across the
        // activity-bar panels.
        let add_y = rows.len() as u16;
        rows.push(add_action_row("Add new parameter…", t));
        params_rows_local.push((
            Rect {
                x: area.x,
                y: add_y,
                width: area.width,
                height: 1,
            },
            String::new(),
        ));
        register_tab_row(fields, add_y);
        if params.is_empty() {
            let row_y = rows.len() as u16;
            rows.push(Line::from(vec![Span::styled(
                "    (no query parameters yet — click + Add or :http.params_add)".to_string(),
                dim,
            )]));
            register_tab_row(fields, row_y);
        } else {
            for (k, v) in &params {
                let row_y = rows.len() as u16;
                params_rows_local.push((
                    Rect {
                        x: area.x,
                        y: row_y,
                        width: area.width,
                        height: 1,
                    },
                    k.clone(),
                ));
                register_tab_row(fields, row_y);
                // Chevron marker signals the row is clickable, so
                // Params / Vars / etc. lists read as interactive
                // menus instead of static text. (#11 v10)
                rows.push(Line::from(vec![
                    Span::styled("  ", body_style),
                    Span::styled("› ", Style::default().fg(t.comment).bg(t.bg_dark)),
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
                "    (click a row to delete — value-edit is v2)".to_string(),
                dim,
            )]));
        }
    }

    // ── Vars tab: read-only list of active env file's KEY=VALUE rows ──
    // ── Auth tab — Postman-style. Shows current Authorization
    //     header + quick-set rows (None / Bearer / Basic / API key /
    //     Apply saved preset). Each row clickable to dispatch the
    //     matching App method. ───
    if cur_tab == crate::request_pane::EditTab::Auth {
        // Detect current auth state from the Authorization header.
        let current = rp
            .request
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("authorization"))
            .map(|(_, v)| v.clone());
        let summary = match current.as_deref() {
            Some(v) if v.starts_with("Bearer ") => {
                format!("Bearer · {}", &v[7..].chars().take(20).collect::<String>())
            }
            Some(v) if v.starts_with("Basic ") => "Basic · (base64 user:pass)".to_string(),
            Some(v) if v.len() > 24 => format!("{}…", &v[..22]),
            Some(v) => v.to_string(),
            None => "(no Authorization header — request will be unauthenticated)".to_string(),
        };
        let summary_y = rows.len() as u16;
        rows.push(Line::from(vec![
            Span::styled("    Current:  ".to_string(), dim),
            Span::styled(
                summary,
                Style::default()
                    .fg(if current.is_some() { t.cyan } else { t.comment })
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ),
        ]));
        register_tab_row(fields, summary_y);
        rows.push(plain(String::new(), body_style));

        // Action rows. Icons match the rest of the app's nerd-font
        // vocabulary — `+` for additive actions, `⟳` for refresh
        // (Nerd Font U+27F3), `×` for destructive. No emoji so the
        // Auth section reads consistently with the rest of the pane.
        let actions: &[(&str, &str, char)] = &[
            ("set_bearer", "Set Bearer token…", '+'),
            ("set_basic", "Set Basic auth (user:pass)…", '+'),
            ("set_api_key", "Set X-Api-Key…", '+'),
            ("apply_preset", "Apply saved preset…", '⟳'),
            ("save_preset", "Save current as preset…", '⇓'),
            ("clear", "Clear Authorization", '×'),
        ];
        for (id, label, icon) in actions {
            let row_y = rows.len() as u16;
            // Color: `clear` red (destructive), `save_preset` green,
            // others normal fg. Matches the app-wide semantic-color
            // convention.
            let color = match *id {
                "clear" => t.red,
                "save_preset" => t.green,
                _ => t.fg,
            };
            rows.push(Line::from(vec![
                Span::styled("  ", Style::default().bg(t.bg_dark)),
                Span::styled(
                    format!("{icon} {label}"),
                    Style::default()
                        .fg(color)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ),
            ]));
            auth_rows_local.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                id.to_string(),
            ));
            register_tab_row(fields, row_y);
        }
    }

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
        // Runtime override (via `:http.pick_env`) wins first — matches
        // the precedence used at send time so what's shown in Vars is
        // what the request will resolve against.
        let env_name = crate::http::template::EnvSet::select(workspace, env_override)
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
        // 2026-06-20 polish — `+ Add new variable…` row at the
        // top, each existing var row clickable to edit. Both
        // register rects in App.rects.request_vars_rows; click
        // handler in tui.rs dispatches to the env editor.
        // #11 — uses the shared add_action_row helper.
        let add_y = rows.len() as u16;
        rows.push(add_action_row("Add new variable…", t));
        vars_rows_local.push((
            Rect {
                x: area.x,
                y: add_y,
                width: area.width,
                height: 1,
            },
            String::new(), // empty = add row
        ));
        register_tab_row(fields, add_y);
        if by_key.is_empty() {
            let y = rows.len() as u16;
            rows.push(Line::from(vec![Span::styled(
                "    (no env vars yet — click + Add or :http.edit_env)".to_string(),
                dim,
            )]));
            register_tab_row(fields, y);
        } else {
            for (k, v) in &by_key {
                let y = rows.len() as u16;
                vars_rows_local.push((
                    Rect {
                        x: area.x,
                        y,
                        width: area.width,
                        height: 1,
                    },
                    k.clone(),
                ));
                register_tab_row(fields, y);
                let preview = if v.len() > 56 {
                    format!("{}…", &v[..54])
                } else {
                    v.clone()
                };
                // Chevron marker signals the row is clickable — same
                // affordance as Params. (#11 v10)
                rows.push(Line::from(vec![
                    Span::styled("  ", body_style),
                    Span::styled("› ", Style::default().fg(t.comment).bg(t.bg_dark)),
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
            "    Source — type / paste curl or .http here · :http.paste_source (Ctrl+Enter)"
                .to_string(),
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
                        let col =
                            src[start..rp.source_cursor.min(src.len())].chars().count() as u16;
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

    // Sending/Streaming/Done indicator (small).
    rows.push(plain(String::new(), body_style));
    match &rp.state {
        RunState::Sending => rows.push(plain(
            "  ⟳ sending…".to_string(),
            Style::default().fg(t.yellow).bg(t.bg_dark),
        )),
        RunState::Streaming(r) => rows.push(plain(
            format!("  ▶ streaming · {} events received", r.sse_event_count),
            Style::default().fg(t.cyan).bg(t.bg_dark),
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

/// Render a byte count as a 2-3 char human string. 999 → 999 B,
/// 1234 → 1.2 KB, 1_234_567 → 1.2 MB.
fn human_bytes(n: usize) -> String {
    const KB: usize = 1024;
    const MB: usize = 1024 * 1024;
    if n < KB {
        format!("{n} B")
    } else if n < MB {
        format!("{:.1} KB", n as f64 / KB as f64)
    } else {
        format!("{:.1} MB", n as f64 / MB as f64)
    }
}

/// Lightweight content-type sniffing for the Body field label
/// hint. Walks at most the first ~512 bytes — runs every frame
/// on the body's leading prefix, so keep it cheap.
fn detect_body_kind(body: &str) -> Option<&'static str> {
    let head = body.trim_start();
    if head.is_empty() {
        return None;
    }
    let sample: String = head.chars().take(256).collect();
    let first = sample.chars().next()?;
    match first {
        '{' | '[' => Some("JSON"),
        '<' => {
            // XML or HTML — close enough; if it starts with `<?xml`
            // or a tag, call it XML.
            Some("XML")
        }
        _ => {
            // Form-encoded: `key=val&key=val` shape, no quotes/braces.
            if sample.contains('=')
                && sample.contains('&')
                && !sample.contains('{')
                && !sample.contains('[')
            {
                Some("form")
            } else {
                Some("text")
            }
        }
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
    body_wrap_width: Option<u16>,
) {
    let body_style = Style::default().fg(t.fg).bg(t.bg_dark);
    let dim = Style::default().fg(t.comment).bg(t.bg_dark);
    let plain = |s: String, st: Style| Line::from(Span::styled(s, st));

    // ── request-line summary — mirrors the method-chip + URL row
    // from the Edit section so the response is anchored to what
    // was fired. Method color routes through `method_color(...)` so
    // both sites stay in sync when a new verb is added. Arrow
    // indicator drops to cyan (matches the pane's active-focus
    // color, not the historical yellow "attention" color that read
    // as a warning). ──
    let method_upper = rp.request.method.to_uppercase();
    let m_color = method_color(&method_upper, t);
    rows.push(Line::from(vec![
        Span::styled("▶ ", Style::default().fg(t.cyan).bg(t.bg_dark)),
        Span::styled(
            format!(" {method_upper} "),
            Style::default()
                .fg(t.bg_dark)
                .bg(m_color)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(
            format!("  {}", rp.request.url),
            Style::default().fg(t.fg).bg(t.bg_dark),
        ),
    ]));
    // Request headers — color-coded (cyan key + comment `:` + fg
    // value) to match the Edit-tab Headers rendering. Same shape
    // makes the two sections read as the same primitive. Skips
    // rows that don't match the pane's `/` filter (#11).
    let q_lower = rp.filter.trim().to_ascii_lowercase();
    for (k, v) in &rp.request.headers {
        if header_matches_filter(k, v, &q_lower) {
            rows.push(header_row(k, v, t));
        }
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
            // Cyan matches the pane's focus family; the animated
            // spinner sits inside a compact chip so it reads as an
            // in-flight indicator, not a static label.
            rows.push(plain(
                "  ⟳ sending…".to_string(),
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ));
        }
        RunState::Streaming(r) => {
            // SSE in-flight — show status chip + accumulated body
            // (events appended as they arrive).
            rows.push(plain(
                format!("  ▶ streaming · {} {}", r.status, r.status_text),
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ));
            rows.push(plain(String::new(), body_style));
            for l in r.body.lines() {
                rows.push(plain(l.to_string(), body_style));
            }
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
            // 2026-06-20 — status code as a colored chip (matches
            // the Method chip styling for visual consistency).
            // 2xx green, 3xx yellow, 4xx orange, 5xx red, anything
            // else fg-on-bg3 (neutral).
            let status_color = match r.status {
                200..=299 => t.green,
                300..=399 => t.yellow,
                400..=499 => t.orange,
                500..=599 => t.red,
                _ => t.bg3,
            };
            // Wrap chip — reflects the current body_wrap setting so
            // users can see the mode at a glance + `w` to toggle.
            let wrap_chip = if rp.body_wrap {
                " wrap ON  "
            } else {
                " wrap OFF "
            };
            let wrap_chip_style = if rp.body_wrap {
                Style::default()
                    .fg(t.bg_dark)
                    .bg(t.cyan)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default()
                    .fg(t.comment)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::DIM)
            };
            rows.push(Line::from(vec![
                Span::styled("  ".to_string(), Style::default().bg(t.bg_dark)),
                Span::styled(
                    format!(" {} ", r.status),
                    Style::default()
                        .fg(t.bg_dark)
                        .bg(status_color)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!("  {}", r.status_text),
                    Style::default()
                        .fg(status_color)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("   {} ms", r.elapsed.as_millis()), dim),
                Span::styled(
                    format!(
                        "   {} lines · {}",
                        r.body.lines().count(),
                        human_bytes(r.body.len())
                    ),
                    dim,
                ),
                Span::styled("   ", Style::default().bg(t.bg_dark)),
                Span::styled(wrap_chip, wrap_chip_style),
            ]));
            // Response headers use the same color-coded row as the
            // Edit-tab headers + request-summary headers — consistent
            // rendering across every place a header list shows up.
            // Also honors the pane's `/` filter (#11).
            for (k, v) in &r.headers {
                if header_matches_filter(k, v, &q_lower) {
                    rows.push(header_row(k, v, t));
                }
            }
            rows.push(plain(String::new(), body_style));
            let pretty = pretty_body(&r.body, &r.headers);
            // Detect JSON so we can run the tree-sitter highlighter
            // over the body. Same predicate `pretty_body` uses so we
            // don't disagree with the pretty-printing decision.
            let is_json = r
                .headers
                .iter()
                .any(|(k, v)| k.eq_ignore_ascii_case("content-type") && v.contains("json"))
                || {
                    let b = pretty.trim_start();
                    b.starts_with('{') || b.starts_with('[')
                };
            // Per-line tree-sitter spans. Empty when non-JSON so the
            // body renders in the base body_style like before.
            let json_spans: Vec<Vec<crate::highlight::ColoredSpan>> = if is_json {
                crate::highlight::highlight_lines(&pretty, "json")
            } else {
                Vec::new()
            };
            let get_spans = |i: usize| -> &[crate::highlight::ColoredSpan] {
                json_spans.get(i).map(|v| v.as_slice()).unwrap_or(&[])
            };
            // Optional word-wrap — soft-wraps each line at the pane
            // width so long JSON strings stay visible. `w` in Response
            // view toggles. Wrapped chunks all render in the same
            // style since we can't easily reassemble spans across
            // wrap boundaries; small trade-off vs. the visual win.
            // (#11)
            let wrap_plain =
                |s: &str, out: &mut Vec<Line<'static>>, style: Style| match body_wrap_width {
                    Some(w) if s.chars().count() > w as usize => {
                        let chars: Vec<char> = s.chars().collect();
                        for chunk in chars.chunks(w as usize) {
                            out.push(plain(chunk.iter().collect(), style));
                        }
                    }
                    _ => out.push(plain(s.to_string(), style)),
                };
            // Body filter — same query as the header filter. A line
            // shows if it contains the query (case-insensitive) OR
            // its neighbors do (±1 for context). Empty filter shows
            // every line. #11.
            if q_lower.is_empty() {
                for (i, l) in pretty.lines().enumerate() {
                    let spans = get_spans(i);
                    if body_wrap_width.is_none() && !spans.is_empty() {
                        rows.push(colored_line(l, spans, t.fg, t));
                    } else {
                        wrap_plain(l, rows, body_style);
                    }
                }
            } else {
                let lines: Vec<&str> = pretty.lines().collect();
                let matches: Vec<bool> = lines
                    .iter()
                    .map(|l| l.to_ascii_lowercase().contains(&q_lower))
                    .collect();
                let hits = matches.iter().filter(|m| **m).count();
                for (i, l) in lines.iter().enumerate() {
                    // Show a matching line + its two neighbors on each
                    // side, so JSON context stays readable.
                    let show = matches[i]
                        || (i > 0 && matches[i - 1])
                        || (i > 1 && matches[i - 2])
                        || (i + 1 < matches.len() && matches[i + 1])
                        || (i + 2 < matches.len() && matches[i + 2]);
                    if !show {
                        continue;
                    }
                    // Highlight matching lines with a subtle bg tint
                    // so the match itself stands out from its context.
                    // Skip syntax highlighting for matched lines — the
                    // bg2 tint is the visual signal, and mixing tint +
                    // color is noisy.
                    let style = if matches[i] {
                        Style::default().fg(t.fg).bg(t.bg2)
                    } else {
                        body_style
                    };
                    let spans = get_spans(i);
                    if !matches[i] && body_wrap_width.is_none() && !spans.is_empty() {
                        rows.push(colored_line(l, spans, t.fg, t));
                    } else {
                        wrap_plain(l, rows, style);
                    }
                }
                if hits == 0 {
                    rows.push(plain(
                        format!("  (no lines match \"{}\")", rp.filter),
                        Style::default()
                            .fg(t.comment)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::DIM),
                    ));
                }
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
            if let Some(sr) = &r.schema_result {
                rows.push(plain(String::new(), body_style));
                rows.push(schema_footer_line(sr, &t));
            }
        }
    }
}

fn schema_footer_line(
    sr: &crate::http::schema::SchemaResult,
    t: &crate::ui::theme::Theme,
) -> Line<'static> {
    use crate::http::schema::SchemaStatus;
    let sidecar = sr
        .schema_path
        .as_ref()
        .and_then(|p| p.file_name())
        .and_then(|s| s.to_str())
        .unwrap_or("");
    match &sr.status {
        SchemaStatus::Valid => Line::from(vec![Span::styled(
            format!("  ✓ Schema valid ({sidecar})"),
            Style::default()
                .fg(t.green)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        )]),
        SchemaStatus::Invalid => {
            let n = sr.errors.len();
            let plural = if n == 1 { "error" } else { "errors" };
            Line::from(vec![Span::styled(
                format!("  ✗ Schema: {n} {plural} ({sidecar}) — :http.show_schema_errors"),
                Style::default()
                    .fg(t.red)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )])
        }
        SchemaStatus::NoSidecar => Line::from(vec![]),
        SchemaStatus::ReadError(e) => Line::from(vec![Span::styled(
            format!("  ⚠ Schema read error ({sidecar}): {e}"),
            Style::default().fg(t.yellow).bg(t.bg_dark),
        )]),
        SchemaStatus::SchemaParseError(e) => Line::from(vec![Span::styled(
            format!("  ⚠ Schema parse error ({sidecar}): {e}"),
            Style::default().fg(t.yellow).bg(t.bg_dark),
        )]),
        SchemaStatus::NotJson => Line::from(vec![Span::styled(
            format!("  ⚠ Body isn't JSON — schema ({sidecar}) skipped"),
            Style::default().fg(t.yellow).bg(t.bg_dark),
        )]),
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
