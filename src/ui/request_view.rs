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
/// look (cyan bg + bg_dark fg + BOLD). Was used for inline
/// `response`/`ai` labels before the three-zone bordered layout
/// took over the section-title role; retained for potential
/// future use inside sub-sections (e.g. Response body vs. headers).
#[allow(dead_code)]
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

/// Snap `idx` down to the nearest UTF-8 char boundary in `s`. Used
/// by [`colored_line`] to keep `str` slicing safe when tree-sitter
/// returns byte offsets that land mid-multi-byte. (Nightly's
/// `floor_char_boundary` isn't available on stable yet.)
fn floor_boundary(s: &str, mut idx: usize) -> usize {
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

/// Count filter matches across request headers + response headers +
/// response body lines. Returns `(matched, total)` for the filter
/// chip's hit indicator. Returns `None` when the filter is empty. (#11)
/// Body walk is capped at 20 000 lines so pathological 10 MB+ JSON
/// bodies don't tie up the render loop; the counter shows the sum
/// up to that cap (`total` reflects actual work, not headline size).
fn compute_filter_hits(rp: &crate::request_pane::RequestPane) -> Option<(usize, usize)> {
    const BODY_LINE_CAP: usize = 20_000;
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
        for line in r.body.lines().take(BODY_LINE_CAP) {
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
    // before the current cursor. All byte boundaries snap down to
    // the nearest UTF-8 char boundary so spans that end mid-multi-
    // byte (CJK, emoji in a JSON string) never slice a codepoint
    // in half.
    let mut ordered: Vec<crate::highlight::ColoredSpan> = spans.to_vec();
    ordered.sort_by_key(|(s, _, _)| *s);
    let mut out: Vec<Span<'static>> = Vec::new();
    let mut cursor = 0usize;
    let src_len = src.len();
    for (s, e, color) in ordered {
        let s = floor_boundary(src, s.min(src_len));
        let e = floor_boundary(src, e.min(src_len));
        if e <= cursor {
            continue;
        }
        if s > cursor {
            out.push(Span::styled(
                src[cursor..s].to_string(),
                Style::default().fg(base_fg).bg(t.bg_dark),
            ));
        }
        let start = s.max(cursor);
        out.push(Span::styled(
            src[start..e].to_string(),
            Style::default().fg(color).bg(t.bg_dark),
        ));
        cursor = e;
    }
    if cursor < src_len {
        out.push(Span::styled(
            src[cursor..].to_string(),
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
    // Backfill so any negative-space cells within `area` render the
    // pane's own bg color, matching the previous impl.
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );
    // Detach the click-target registries so the draw fns below can push
    // into them while `rp` is borrowed from `app.panes`. Restored at
    // the bottom (and at the early-return below).
    let mut fields = std::mem::take(&mut app.rects.request_fields);
    let Some(Pane::Request(rp)) = app.panes.get_mut(pane_id) else {
        app.rects.request_fields = fields;
        return None;
    };

    // ── caret position to return.
    //
    // Two sources can set it:
    //   * `draw_url_box` writes ABSOLUTE screen coords for the URL
    //     field's caret. Goes into `caret_abs`.
    //   * `draw_edit` writes a ROW-INDEX y (0-based within the
    //     tabs_rect content area) for Body/Headers/etc. fields.
    //     Goes into `caret` and is translated later.
    //
    // Splitting the two slots avoids the earlier ambiguity where
    // `y < edit_h` was used as a discriminator — URL box `inner.y`
    // is an absolute screen coord that can numerically land in the
    // row-index range (`0..edit_h`), which caused the URL caret to
    // be re-translated and end up in empty space below Body.
    let mut caret: Option<(u16, u16)> = None;
    let mut caret_abs: Option<(u16, u16)> = None;

    // Edit-tab chip rects — collected with `y` = row index within the
    // Request zone, translated to a screen-y after we know that
    // zone's inner rect.
    let mut edit_tabs_local: Vec<(Rect, PaneId, crate::request_pane::EditTab)> = Vec::new();
    app.rects
        .request_edit_tabs
        .retain(|(_, p, _)| *p != pane_id);

    let show_ws = app.config.ui.show_whitespace;
    let workspace = app.workspace.clone();
    let env_override = app.http_env_override.clone();
    let mut vars_rows_local: Vec<(Rect, String)> = Vec::new();
    let mut params_rows_local: Vec<(Rect, String)> = Vec::new();
    let mut auth_rows_local: Vec<(Rect, String)> = Vec::new();

    // ── Layout: split the pane into three bordered zones, top-down.
    // Request  — form editor (URL/method + tabs + tab content)
    // Response — status + body + assertions
    // AI       — quick prompt line, always visible (Postman feel)
    //
    // AI is a fixed 3-row block at the bottom (2 border + 1 content).
    // Above AI, Request + Response split by the pane's stored
    // orientation:
    //   Vertical (default): Request top ~55%, Response bottom ~45%.
    //   Horizontal:         Request left  ~50%, Response right ~50%.
    // AI always spans the full width at the bottom.
    let ai_height = 3u16.min(area.height);
    let non_ai = area.height.saturating_sub(ai_height);
    let ai_rect = Rect {
        x: area.x,
        y: area.y.saturating_add(non_ai),
        width: area.width,
        height: ai_height,
    };
    let (request_rect, response_rect) = match rp.split_orientation {
        crate::request_pane::SplitOrientation::Vertical => {
            let request_height = ((non_ai as u32 * 55 / 100) as u16).max(6.min(non_ai));
            let response_height = non_ai.saturating_sub(request_height);
            (
                Rect {
                    x: area.x,
                    y: area.y,
                    width: area.width,
                    height: request_height,
                },
                Rect {
                    x: area.x,
                    y: area.y.saturating_add(request_height),
                    width: area.width,
                    height: response_height,
                },
            )
        }
        crate::request_pane::SplitOrientation::Horizontal => {
            let request_width = area.width / 2;
            let response_width = area.width.saturating_sub(request_width);
            (
                Rect {
                    x: area.x,
                    y: area.y,
                    width: request_width,
                    height: non_ai,
                },
                Rect {
                    x: area.x.saturating_add(request_width),
                    y: area.y,
                    width: response_width,
                    height: non_ai,
                },
            )
        }
    };

    // ── Zone 1: Request ─────────────────────────────────────────
    // Fully-connected border — no "Request" title text on the top
    // border since the sub-panels (Method, URL, Send, Clear) label
    // themselves. Split-orientation chip still floats on the right.
    let request_block = crate::ui::design_tokens::bordered_plain("");
    let request_inner = request_block.inner(request_rect);
    frame.render_widget(request_block, request_rect);
    // Split-orientation toggle — floats at the top-right of the
    // Request block's border row. `▤` = horizontal, `▥` = vertical
    // (matches the mockup). Current orientation renders in cyan,
    // the other in comment fg. Click cycles.
    app.rects.request_split_toggle =
        paint_split_toggle_chip(frame, rp.split_orientation, request_rect, t);

    // Method + URL sub-panels sit at the TOP of the Request zone,
    // side-by-side, each with its own legend outline. Method is
    // fixed-width (space for the widest verb + " ▼ " dropdown
    // affordance); URL takes the rest of the width out to the
    // right edge. Under those two, the tabs + tab content flow
    // (rendered by draw_edit into `tabs_rect`).
    //
    // Layout math:
    //   method_url_row height = 3 (border top + content + border bottom)
    //   method_rect   width  = METHOD_BOX_WIDTH
    //   url_rect      width  = request_inner.width - method_rect.width
    //
    // If the pane is too narrow to fit both boxes side-by-side
    // (< METHOD_BOX_WIDTH + MIN_URL_WIDTH), we fall back to the
    // old single-row rendering path below (skips the sub-panels).
    const METHOD_BOX_WIDTH: u16 = 14;
    const MIN_URL_WIDTH: u16 = 20;
    const METHOD_URL_ROW_H: u16 = 3;
    // 1-cell padding on the outer edges of the Method/URL row so
    // the sub-panels don't kiss the parent Request block's border.
    const EDGE_PAD: u16 = 1;
    // 2026-07-05 — dropped the 1-cell top pad above Method/URL now
    // that the parent Request block uses plain-text titles (no
    // colored chip). Sub-panels can sit flush against the parent's
    // top border without visual crowding.
    const TOP_PAD: u16 = 0;
    // Right-side action boxes — Postman/Bruno idiom for firing and
    // resetting the current request. Widths sized to fit each box's
    // content plus 2-cell border chrome:
    //   Send   = " ▶ Send "    (7 chars) + 2 border → 10 min, padded
    //   Clear  = " ✕ Clear "   (8 chars) + 2 border → 11 min
    //
    // Format lives INSIDE the Body tab now (right-aligned on the
    // tab strip), so it only shows up when it's applicable.
    const SEND_BOX_WIDTH: u16 = 10;
    const CLEAR_BOX_WIDTH: u16 = 11;
    let show_sub_panels = request_inner.width
        >= METHOD_BOX_WIDTH + MIN_URL_WIDTH + SEND_BOX_WIDTH + CLEAR_BOX_WIDTH + 2 * EDGE_PAD
        && request_inner.height >= METHOD_URL_ROW_H + TOP_PAD + 3;

    let mut edit_rows: Vec<Line> = Vec::new();
    // Absolute-coord click rects for the Method + URL sub-panels.
    // Registered directly into `app.rects.request_fields` below the
    // tab-strip translation loop — the loop treats every entry in
    // its `fields` vec as row-index-y and would double-translate
    // these if we mixed them in.
    let mut method_url_absolute: Vec<(Rect, EditField)> = Vec::new();
    let mut send_button_rect: Option<Rect> = None;
    let mut clear_button_rect: Option<Rect> = None;
    let tabs_rect = if show_sub_panels {
        // Layout: [top-pad blank][pad][Method][URL][Send][Clear][pad]
        let row_y = request_inner.y.saturating_add(TOP_PAD);
        let method_rect = Rect {
            x: request_inner.x.saturating_add(EDGE_PAD),
            y: row_y,
            width: METHOD_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        let url_x = method_rect.x.saturating_add(METHOD_BOX_WIDTH);
        let url_width = request_inner
            .width
            .saturating_sub(EDGE_PAD)
            .saturating_sub(METHOD_BOX_WIDTH)
            .saturating_sub(SEND_BOX_WIDTH)
            .saturating_sub(CLEAR_BOX_WIDTH)
            .saturating_sub(EDGE_PAD);
        let url_rect = Rect {
            x: url_x,
            y: row_y,
            width: url_width,
            height: METHOD_URL_ROW_H,
        };
        let send_rect = Rect {
            x: url_x.saturating_add(url_width),
            y: row_y,
            width: SEND_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        let clear_rect = Rect {
            x: send_rect.x.saturating_add(SEND_BOX_WIDTH),
            y: row_y,
            width: CLEAR_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        if let Some(mr) = draw_method_box(frame, rp, method_rect, focused, t) {
            method_url_absolute.push((mr, EditField::Method));
        }
        if let Some(ur) = draw_url_box(frame, rp, url_rect, focused, &mut caret_abs, t) {
            method_url_absolute.push((ur, EditField::Url));
        }
        send_button_rect = draw_send_box(frame, rp, send_rect, t);
        clear_button_rect = draw_clear_box(frame, clear_rect, t);
        // Tabs pick up IMMEDIATELY after the Method/URL bottom
        // border — no extra spacer between them.
        let used = TOP_PAD.saturating_add(METHOD_URL_ROW_H);
        Rect {
            x: request_inner.x,
            y: request_inner.y.saturating_add(used),
            width: request_inner.width,
            height: request_inner.height.saturating_sub(used),
        }
    } else {
        request_inner
    };

    if tabs_rect.width > 0 && tabs_rect.height > 0 {
        draw_edit(
            rp,
            t,
            &mut edit_rows,
            tabs_rect,
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
        // Edit content clips (no scroll for v1 — the Response zone
        // is the main scrollable area; Edit fits by ratio).
        let edit_view: Vec<Line> = edit_rows
            .iter()
            .take(tabs_rect.height as usize)
            .cloned()
            .collect();
        frame.render_widget(
            Paragraph::new(edit_view).style(Style::default().bg(t.bg_dark)),
            tabs_rect,
        );
        // Format chip — top-right of the Body tab area. Only shown
        // when the current tab is Body AND detected content is
        // JSON. Painted as an overlay AFTER the tab strip so it
        // sits on the same row (the top of tabs_rect).
        app.rects.request_format_button = paint_body_format_chip(frame, rp, tabs_rect, t);
    } else {
        app.rects.request_format_button = None;
    }

    // ── Zone 2: Response ─────────────────────────────────────────
    // Bruno-style status chip on the right side of the Response
    // block's top border: "200 OK · 165ms · 263 B" colored per
    // status class (2xx green / 3xx yellow / 4xx orange / 5xx red).
    // Sending / Streaming / Failed states render their own subtle
    // status text; empty pane shows nothing.
    let response_block = {
        // Fully-connected border — no "Response" title text; the
        // sub-tab strip (Body / Headers / Timeline / Tests) is the
        // label. Status chip still floats on the right.
        let mut block = crate::ui::design_tokens::bordered_plain("");
        if let Some(status_line) = response_status_title(rp, t) {
            block = block.title_top(ratatui::text::Line::from(status_line).right_aligned());
        }
        block
    };
    let response_inner = response_block.inner(response_rect);
    frame.render_widget(response_block, response_rect);
    // Response sub-tab strip — Bruno-style: Body / Headers /
    // Timeline / Tests. Two rows tall: row 0 is the labels + type
    // chip, row 1 is the `─` underline bar under the active tab.
    // The actual response content flows below starting at
    // `content_inner`.
    let content_inner = if response_inner.height >= 3 {
        app.rects.request_response_tabs = paint_response_tab_strip(frame, rp, response_inner, t);
        Rect {
            x: response_inner.x,
            y: response_inner.y.saturating_add(2),
            width: response_inner.width,
            height: response_inner.height.saturating_sub(2),
        }
    } else {
        app.rects.request_response_tabs.clear();
        response_inner
    };
    let mut response_rows: Vec<Line> = Vec::new();
    if content_inner.width > 0 && content_inner.height > 0 {
        // Filter chip lives at the top of the Response content — visible
        // whenever the filter is active OR focused (so users see the
        // "/" hint even before typing). Empty + unfocused = hidden.
        if !rp.filter.is_empty() || rp.filter_focused {
            let hits = compute_filter_hits(rp);
            response_rows.push(filter_row(&rp.filter, rp.filter_focused, hits, t));
        }
        let wrap_width = if rp.body_wrap {
            Some(content_inner.width.saturating_sub(2).max(20))
        } else {
            None
        };
        draw_response(rp, t, &mut response_rows, wrap_width);
        // `rp.scroll` now applies to the Response content area
        // (below the sub-tab strip). Clamp against content length.
        let h = content_inner.height as usize;
        let max_scroll = response_rows
            .len()
            .saturating_sub(h.min(response_rows.len()));
        rp.scroll = rp.scroll.min(max_scroll);
        let scroll = rp.scroll;
        let response_view: Vec<Line> = response_rows.into_iter().skip(scroll).take(h).collect();
        frame.render_widget(
            Paragraph::new(response_view).style(Style::default().bg(t.bg_dark)),
            content_inner,
        );
    }

    // ── Zone 3: AI ─────────────────────────────────────────
    let ai_block = crate::ui::design_tokens::bordered_plain("AI");
    let ai_inner = ai_block.inner(ai_rect);
    frame.render_widget(ai_block, ai_rect);
    if ai_inner.width > 0 && ai_inner.height > 0 {
        let ai_line = Line::from(vec![
            Span::styled(" ", Style::default().bg(t.bg_dark)),
            Span::styled(
                "click here to ask a custom question".to_string(),
                crate::ui::design_tokens::hint_style(),
            ),
            Span::styled(
                "   \u{00B7} `a` quick debug".to_string(),
                Style::default().fg(t.comment).bg(t.bg_dark),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(vec![ai_line]).style(Style::default().bg(t.bg_dark)),
            ai_inner,
        );
        app.rects.request_ai_section = Some(ai_inner);
    } else {
        app.rects.request_ai_section = None;
    }

    // Register the whole pane area for wheel + fallback routing.
    app.rects.editor_panes.push((area, pane_id));

    // ── Rect adjustment: edit_rows rects were collected with y = row
    // index within `edit_rows` (0-based relative to `tabs_rect`).
    // Translate to screen y = tabs_rect.y + row_index, clipped to
    // tabs_rect.height so a click past the visible content doesn't
    // fire. Uses `tabs_rect` (NOT `request_inner`) because that's
    // the area `draw_edit` was passed — using `request_inner.y`
    // would offset every tab-click by METHOD_URL_ROW_H (3 rows)
    // and route Method-box clicks to the tab strip.
    let edit_h = tabs_rect.height as usize;
    let edit_origin_y = tabs_rect.y;
    for (mut r, pid, f) in fields.drain(..) {
        let row_off = r.y as usize;
        if row_off >= edit_h {
            continue;
        }
        r.y = edit_origin_y.saturating_add(row_off as u16);
        app.rects.request_fields.push((r, pid, f));
    }
    // Method + URL sub-panel rects were built with ABSOLUTE
    // screen coords by `draw_method_box` / `draw_url_box`; they
    // don't go through the row-index → screen-y translation.
    for (rect, field) in method_url_absolute.drain(..) {
        app.rects.request_fields.push((rect, pane_id, field));
    }
    app.rects.request_send_button = send_button_rect;
    app.rects.request_clear_button = clear_button_rect;
    // request_format_button is now set inside draw_edit's Body
    // rendering path (right-aligned chip on the top-right of the
    // body area, visible only when the body is JSON).
    for (mut r, pid, tab) in edit_tabs_local.drain(..) {
        let row_off = r.y as usize;
        if row_off >= edit_h {
            continue;
        }
        r.y = edit_origin_y.saturating_add(row_off as u16);
        app.rects.request_edit_tabs.push((r, pid, tab));
    }
    app.rects.request_vars_rows.clear();
    for (mut r, key) in vars_rows_local.drain(..) {
        let row_off = r.y as usize;
        if row_off >= edit_h {
            continue;
        }
        r.y = edit_origin_y.saturating_add(row_off as u16);
        app.rects.request_vars_rows.push((r, key));
    }
    app.rects.request_params_rows.clear();
    for (mut r, key) in params_rows_local.drain(..) {
        let row_off = r.y as usize;
        if row_off >= edit_h {
            continue;
        }
        r.y = edit_origin_y.saturating_add(row_off as u16);
        app.rects.request_params_rows.push((r, key));
    }
    app.rects.request_auth_rows.clear();
    for (mut r, id) in auth_rows_local.drain(..) {
        let row_off = r.y as usize;
        if row_off >= edit_h {
            continue;
        }
        r.y = edit_origin_y.saturating_add(row_off as u16);
        app.rects.request_auth_rows.push((r, id));
    }

    // Caret — two sources can set it:
    //   * `caret_abs` — URL sub-panel's caret in absolute screen
    //     coords (set by `draw_url_box`).
    //   * `caret` — row-index y from `draw_edit` for Body/Headers/
    //     etc. fields (translated below).
    //
    // URL wins when both are set (matches the pane's default focus
    // = URL). Row-index carets get translated against `tabs_rect`.
    if caret_abs.is_some() {
        return caret_abs;
    }
    caret.map(|(x, y)| {
        let y = (y as usize).min(edit_h.saturating_sub(1)) as u16;
        (x, edit_origin_y.saturating_add(y))
    })
}

// Border color override was removed 2026-07-05 — every
// modal_panel(title) now uses the design-token default border
// (t.fg on t.bg_dark), matching the rest of the app's bordered
// panels instead of a per-pane blue-on-focus override.

/// Compute the right-aligned status title for the Response block —
/// Bruno-style "200 OK · 165ms · 263 B" on green (or matching status
/// color). Returns `None` when there's no interesting state to show
/// (fresh pane / placeholder). Sending / Streaming / non-placeholder
/// Failed states each get their own compact title so the user can
/// see the pane's state without reading the body.
fn response_status_title(
    rp: &crate::request_pane::RequestPane,
    t: theme::Theme,
) -> Option<Vec<Span<'static>>> {
    match &rp.state {
        RunState::Sending => Some(vec![Span::styled(
            " \u{27F3} sending\u{2026} ",
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        )]),
        RunState::Streaming(r) => Some(vec![Span::styled(
            format!(" \u{25B6} streaming \u{00B7} {} events ", r.sse_event_count),
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        )]),
        RunState::Failed(e) if is_not_sent_placeholder(e) => None,
        RunState::Failed(_) => Some(vec![Span::styled(
            " \u{2717} failed ",
            Style::default()
                .fg(t.red)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        )]),
        RunState::Done(r) => {
            let status_color = match r.status {
                200..=299 => t.green,
                300..=399 => t.yellow,
                400..=499 => t.orange,
                500..=599 => t.red,
                _ => t.bg3,
            };
            let sep = |t: theme::Theme| {
                Span::styled(" \u{00B7} ", Style::default().fg(t.comment).bg(t.bg_dark))
            };
            Some(vec![
                Span::styled(
                    format!(" {} {} ", r.status, r.status_text),
                    Style::default()
                        .fg(status_color)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                ),
                sep(t),
                Span::styled(
                    format!("{}ms", r.elapsed.as_millis()),
                    Style::default().fg(t.comment).bg(t.bg_dark),
                ),
                sep(t),
                Span::styled(
                    format!("{} ", human_bytes(r.body.len())),
                    Style::default().fg(t.comment).bg(t.bg_dark),
                ),
            ])
        }
    }
}

/// Response sub-tab strip — Bruno-style Body / Headers / Timeline
/// / Tests row with an UNDERLINED active tab and plain-fg inactive
/// tabs (no chip bg). A right-aligned `JSON ▼` chip shows the
/// detected response content type. Returns the click rects for
/// each tab.
fn paint_response_tab_strip(
    frame: &mut Frame,
    rp: &crate::request_pane::RequestPane,
    response_inner: Rect,
    t: theme::Theme,
) -> Vec<(Rect, crate::request_pane::ResponseTab)> {
    let mut rects = Vec::new();
    if response_inner.width == 0 || response_inner.height < 2 {
        return rects;
    }
    let active = rp.response_tab;
    let label_rect = Rect {
        x: response_inner.x,
        y: response_inner.y,
        width: response_inner.width,
        height: 1,
    };
    let bar_rect = Rect {
        x: response_inner.x,
        y: response_inner.y.saturating_add(1),
        width: response_inner.width,
        height: 1,
    };
    let mut label_spans: Vec<Span> = Vec::new();
    label_spans.push(Span::styled("  ", Style::default().bg(t.bg_dark)));
    let mut bar_spans: Vec<Span> = Vec::new();
    bar_spans.push(Span::styled("  ", Style::default().bg(t.bg_dark)));
    let mut col: u16 = 2;
    for tab in crate::request_pane::ResponseTab::ALL {
        let label = tab.label();
        let is_cur = active == *tab;
        let label_style = if is_cur {
            Style::default()
                .fg(t.fg)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg_dark)
        };
        let chip_w = label.chars().count() as u16;
        label_spans.push(Span::styled(label.to_string(), label_style));
        label_spans.push(Span::styled(
            "  ".to_string(),
            Style::default().bg(t.bg_dark),
        ));
        // Underline bar row — `─` under the active tab, blanks
        // under the inactive tabs. The bar renders on the SECOND
        // row of the tab strip so it's visually detached from the
        // label baseline (matches the mockup's
        // `Response\n────────` look).
        // `━` (U+2501, box-drawings-heavy-horizontal) painted in
        // theme yellow so the active-tab indicator pops without
        // being harsh (matches Bruno's brand-color underline
        // treatment while staying inside our theme palette).
        let bar_glyph = if is_cur { "\u{2501}" } else { " " };
        let bar_style = if is_cur {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().bg(t.bg_dark)
        };
        bar_spans.push(Span::styled(bar_glyph.repeat(chip_w as usize), bar_style));
        bar_spans.push(Span::styled(
            "  ".to_string(),
            Style::default().bg(t.bg_dark),
        ));
        rects.push((
            Rect {
                x: response_inner.x.saturating_add(col),
                y: response_inner.y,
                width: chip_w,
                height: 1,
            },
            *tab,
        ));
        col += chip_w + 2;
    }
    frame.render_widget(
        Paragraph::new(vec![Line::from(label_spans)]).style(Style::default().bg(t.bg_dark)),
        label_rect,
    );
    frame.render_widget(
        Paragraph::new(vec![Line::from(bar_spans)]).style(Style::default().bg(t.bg_dark)),
        bar_rect,
    );
    // Right-aligned content-type chip on the labels row.
    let type_label = detect_response_content_type(rp);
    let chip_text = format!(" {type_label} \u{25BC} ");
    let chip_w = chip_text.chars().count() as u16;
    if label_rect.width >= chip_w + 2 {
        let chip_x = label_rect
            .x
            .saturating_add(label_rect.width)
            .saturating_sub(chip_w)
            .saturating_sub(1);
        let chip_rect = Rect {
            x: chip_x,
            y: label_rect.y,
            width: chip_w,
            height: 1,
        };
        let chip_line = Line::from(vec![Span::styled(
            chip_text,
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        )]);
        frame.render_widget(
            Paragraph::new(vec![chip_line]).style(Style::default().bg(t.bg_dark)),
            chip_rect,
        );
    }
    rects
}

/// Detect the response body's content type for the sub-tab strip's
/// right-aligned chip. Prefers the `content-type` header when
/// present, falls back to body-shape sniffing. Returns "—" when
/// there's no response.
fn detect_response_content_type(rp: &crate::request_pane::RequestPane) -> String {
    let r = match &rp.state {
        RunState::Done(r) => r,
        RunState::Streaming(r) => r,
        _ => return "\u{2014}".to_string(),
    };
    for (k, v) in &r.headers {
        if k.eq_ignore_ascii_case("content-type") {
            let vlow = v.to_ascii_lowercase();
            if vlow.contains("json") {
                return "JSON".to_string();
            }
            if vlow.contains("html") {
                return "HTML".to_string();
            }
            if vlow.contains("xml") {
                return "XML".to_string();
            }
            if vlow.contains("javascript") || vlow.contains("ecmascript") {
                return "JS".to_string();
            }
            if vlow.contains("css") {
                return "CSS".to_string();
            }
            if vlow.contains("plain") || vlow.contains("text/") {
                return "TEXT".to_string();
            }
        }
    }
    let head = r.body.trim_start();
    match head.chars().next() {
        Some('{') | Some('[') => "JSON".to_string(),
        Some('<') => "XML".to_string(),
        _ => "TEXT".to_string(),
    }
}

/// Split-orientation toggle chip — floats at the top-right of the
/// Request block's border row. Renders `[▥][▤]` where the active
/// orientation is bold-cyan and the other is dim-comment. Click
/// cycles orientation.
fn paint_split_toggle_chip(
    frame: &mut Frame,
    orient: crate::request_pane::SplitOrientation,
    request_rect: Rect,
    t: theme::Theme,
) -> Option<Rect> {
    let chip_text = "[ ▥ ▤ ]";
    let chip_w = chip_text.chars().count() as u16;
    if request_rect.width < chip_w + 4 || request_rect.height == 0 {
        return None;
    }
    let chip_x = request_rect
        .x
        .saturating_add(request_rect.width)
        .saturating_sub(chip_w)
        .saturating_sub(2);
    let chip_rect = Rect {
        x: chip_x,
        y: request_rect.y,
        width: chip_w,
        height: 1,
    };
    let vert_active = matches!(orient, crate::request_pane::SplitOrientation::Vertical);
    let horiz_active = matches!(orient, crate::request_pane::SplitOrientation::Horizontal);
    let active_style = Style::default()
        .fg(t.cyan)
        .bg(t.bg_dark)
        .add_modifier(Modifier::BOLD);
    let inactive_style = Style::default().fg(t.comment).bg(t.bg_dark);
    let bracket = Style::default().fg(t.bg3).bg(t.bg_dark);
    let line = Line::from(vec![
        Span::styled("[ ", bracket),
        Span::styled(
            "▥",
            if vert_active {
                active_style
            } else {
                inactive_style
            },
        ),
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            "▤",
            if horiz_active {
                active_style
            } else {
                inactive_style
            },
        ),
        Span::styled(" ]", bracket),
    ]);
    frame.render_widget(
        Paragraph::new(vec![line]).style(Style::default().bg(t.bg_dark)),
        chip_rect,
    );
    Some(chip_rect)
}

/// Body tab's Format chip — floats at the top-right of `tabs_rect`
/// (same row as the tab strip). Rendered only when the current
/// Edit-tab is Body AND the body is detected as JSON. Reads as
/// `[ { } Format ]` on the panel bg, cyan text so it stands out
/// from the tab strip's chips (which use the row-highlight cyan bg).
/// Returns the absolute-coord click rect for the pane-level
/// mouse handler.
fn paint_body_format_chip(
    frame: &mut Frame,
    rp: &crate::request_pane::RequestPane,
    tabs_rect: Rect,
    t: theme::Theme,
) -> Option<Rect> {
    if rp.edit_tab != crate::request_pane::EditTab::Body {
        return None;
    }
    let body = rp.request.body.as_deref().unwrap_or("");
    if !matches!(detect_body_kind(body), Some("JSON")) {
        return None;
    }
    let chip_text = " { } Format ";
    let chip_w = chip_text.chars().count() as u16;
    if tabs_rect.width < chip_w + 2 || tabs_rect.height == 0 {
        return None;
    }
    // Right-aligned on the tab-strip row (row 0 of tabs_rect).
    let chip_x = tabs_rect
        .x
        .saturating_add(tabs_rect.width)
        .saturating_sub(chip_w)
        .saturating_sub(1); // 1-cell right pad
    let chip_y = tabs_rect.y;
    let chip_rect = Rect {
        x: chip_x,
        y: chip_y,
        width: chip_w,
        height: 1,
    };
    let line = Line::from(vec![Span::styled(
        chip_text.to_string(),
        Style::default()
            .fg(t.cyan)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    )]);
    frame.render_widget(
        Paragraph::new(vec![line]).style(Style::default().bg(t.bg_dark)),
        chip_rect,
    );
    Some(chip_rect)
}

/// Clear sub-panel — modal_panel titled "Clear" with a bold red-ish
/// "✕ Clear" label. Click resets the active Request pane's fields
/// (URL, headers, body, method → GET). Same code path as
/// `+ New request` on the sidebar. No y/n prompt — the action is
/// non-destructive vs. the workspace (source_path is preserved
/// only if it exists), and Recent has one-click restore.
fn draw_clear_box(frame: &mut Frame, rect: Rect, t: theme::Theme) -> Option<Rect> {
    let block = crate::ui::design_tokens::bordered_plain("Clear");
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    if inner.width == 0 || inner.height == 0 {
        return None;
    }
    let text = " \u{2715} Clear ";
    let text_w = text.chars().count() as u16;
    let mid_pad = inner.width.saturating_sub(text_w) / 2;
    let content = Line::from(vec![
        Span::styled(" ".repeat(mid_pad as usize), Style::default().bg(t.bg_dark)),
        Span::styled(
            text.to_string(),
            Style::default()
                .fg(t.orange)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(vec![content]).style(Style::default().bg(t.bg_dark)),
        inner,
    );
    Some(inner)
}

/// Send sub-panel — modal_panel titled "Send" with a bold green
/// "▶ Send" label inside. Click routes to the `http.send` palette
/// command via the pane-level mouse handler (via
/// `App::rects::request_send_button`). Returns the absolute-coord
/// click rect for the whole box.
fn draw_send_box(
    frame: &mut Frame,
    rp: &crate::request_pane::RequestPane,
    rect: Rect,
    t: theme::Theme,
) -> Option<Rect> {
    let block = crate::ui::design_tokens::bordered_plain("Send");
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    if inner.width == 0 || inner.height == 0 {
        return None;
    }
    // Green (▶ Send) when we have a URL to fire, dim (▶ Send) when
    // the URL is empty so the button reads as "not ready" without
    // being an error color. State-in-flight (Sending) gets the
    // running-yellow spinner treatment.
    let (glyph, color) = match &rp.state {
        crate::request_pane::RunState::Sending => ("\u{27F3}", t.yellow), // ⟳
        crate::request_pane::RunState::Streaming(_) => ("\u{25B6}", t.cyan),
        _ if rp.request.url.trim().is_empty() => ("\u{25B6}", t.comment),
        _ => ("\u{25B6}", t.green),
    };
    let text = format!(" {glyph} Send ");
    let text_w = text.chars().count() as u16;
    let mid_pad = inner.width.saturating_sub(text_w) / 2;
    let content = Line::from(vec![
        Span::styled(" ".repeat(mid_pad as usize), Style::default().bg(t.bg_dark)),
        Span::styled(
            text,
            Style::default()
                .fg(color)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(vec![content]).style(Style::default().bg(t.bg_dark)),
        inner,
    );
    Some(inner)
}

/// Method sub-panel — legend-outline modal_panel titled "Method" with
/// the verb rendered as COLORED TEXT (not a colored bg chip) and a
/// trailing `▼` down-arrow so the box reads as a dropdown affordance.
/// Colors follow `method_color` (GET green, POST orange, PUT blue,
/// PATCH cyan, DELETE red, HEAD yellow, OPTIONS purple). Returns the
/// absolute-coord click rect for the whole Method box (the caller
/// registers it directly into `app.rects.request_fields`, skipping
/// the row-index translation loop that the tab-strip rects go
/// through).
fn draw_method_box(
    frame: &mut Frame,
    rp: &crate::request_pane::RequestPane,
    rect: Rect,
    _focused: bool,
    t: theme::Theme,
) -> Option<Rect> {
    let block = crate::ui::design_tokens::bordered_plain("Method");
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    if inner.width == 0 || inner.height == 0 {
        return None;
    }
    let method = rp.request.method.to_uppercase();
    let m_color = method_color(&method, t);
    // Content row: " [ GET ]   ▼ " — verb rendered as a solid
    // colored CHIP (verb color as bg, bg_dark as text color) so it
    // reads as a button. Dropdown arrow dim-comment on right.
    let chip_text = format!(" {method} ");
    let chip_width = chip_text.chars().count() as u16;
    let mid_pad = inner
        .width
        .saturating_sub(1) // leading pad
        .saturating_sub(chip_width)
        .saturating_sub(2); // arrow + trailing pad
    let content = Line::from(vec![
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(
            chip_text,
            Style::default()
                .fg(t.bg_dark)
                .bg(m_color)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(" ".repeat(mid_pad as usize), Style::default().bg(t.bg_dark)),
        Span::styled("\u{25BC}", Style::default().fg(t.comment).bg(t.bg_dark)),
        Span::styled(" ", Style::default().bg(t.bg_dark)),
    ]);
    frame.render_widget(
        Paragraph::new(vec![content]).style(Style::default().bg(t.bg_dark)),
        inner,
    );
    Some(inner)
}

/// URL sub-panel — legend-outline modal_panel titled "URL" spanning
/// the remainder of the row's width. Renders the URL as editable
/// text; when the URL field is focused, positions the terminal caret
/// at the character offset that corresponds to `url_cursor`. Returns
/// the absolute-coord click rect for the URL box.
fn draw_url_box(
    frame: &mut Frame,
    rp: &crate::request_pane::RequestPane,
    rect: Rect,
    focused: bool,
    caret: &mut Option<(u16, u16)>,
    t: theme::Theme,
) -> Option<Rect> {
    let block = crate::ui::design_tokens::bordered_plain("URL");
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    if inner.width == 0 || inner.height == 0 {
        return None;
    }
    let url_text = rp.request.url.clone();
    // Placeholder shown any time the URL is empty — even when the
    // field has focus. Matches HTML input placeholder semantics
    // (Postman/Bruno/Insomnia all keep the hint visible under the
    // caret until the first keystroke). A new Request pane defaults
    // focus to `EditField::Url`, so gating on `!focused` here would
    // hide the hint entirely.
    let content = if url_text.is_empty() {
        Line::from(vec![
            Span::styled(" ", Style::default().bg(t.bg_dark)),
            Span::styled(
                "Enter request URL".to_string(),
                Style::default()
                    .fg(t.comment)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::ITALIC),
            ),
        ])
    } else {
        Line::from(vec![
            Span::styled(" ", Style::default().bg(t.bg_dark)),
            Span::styled(url_text.clone(), Style::default().fg(t.fg).bg(t.bg_dark)),
        ])
    };
    frame.render_widget(
        Paragraph::new(vec![content]).style(Style::default().bg(t.bg_dark)),
        inner,
    );
    if focused && rp.focus == EditField::Url {
        let caret_col = 1u16 + url_chars_before_cursor(&url_text, rp.url_cursor) as u16;
        let cx = inner.x + caret_col.min(inner.width.saturating_sub(1));
        *caret = Some((cx, inner.y));
    }
    Some(inner)
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

    // Method + URL rows are drawn by the top-level `draw()` as two
    // side-by-side bordered sub-panels (Method box + URL box) so
    // each has its own legend outline. draw_edit no longer paints
    // that row — the URL caret + method/url click rects are also
    // registered by the top-level. draw_edit picks up from the tab
    // strip.
    let _ = focused;
    let _ = caret;

    // Tab strip (Body / Headers / Params / Auth / Vars / Source).
    // Bruno-style: 2 rows tall — row 0 = labels (active = fg BOLD,
    // inactive = comment fg, no chip bg), row 1 = `━` bar under
    // the active tab. Matches the Response sub-tab strip so both
    // sides read as the same primitive.
    {
        use crate::request_pane::EditTab;
        let label_y = rows.len() as u16;
        let bar_y = label_y + 1;
        let mut label_spans: Vec<Span> = Vec::new();
        let mut bar_spans: Vec<Span> = Vec::new();
        let mut col: u16 = 2;
        label_spans.push(Span::styled("  ", Style::default().bg(t.bg_dark)));
        bar_spans.push(Span::styled("  ", Style::default().bg(t.bg_dark)));
        for tab in EditTab::ALL {
            let label = tab.label();
            let is_cur = rp.edit_tab == *tab;
            let label_style = if is_cur {
                Style::default()
                    .fg(t.fg)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(t.comment).bg(t.bg_dark)
            };
            let chip_w = label.chars().count() as u16;
            label_spans.push(Span::styled(label.to_string(), label_style));
            // 2-cell gap between labels (breathing room for the
            // underline bar).
            label_spans.push(Span::styled(
                "  ".to_string(),
                Style::default().bg(t.bg_dark),
            ));
            // Underline bar row — `━` under active in theme yellow
            // (matches the Response strip), blank under inactive.
            let bar_glyph = if is_cur { "\u{2501}" } else { " " };
            let bar_style = if is_cur {
                Style::default()
                    .fg(t.yellow)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().bg(t.bg_dark)
            };
            bar_spans.push(Span::styled(bar_glyph.repeat(chip_w as usize), bar_style));
            bar_spans.push(Span::styled(
                "  ".to_string(),
                Style::default().bg(t.bg_dark),
            ));
            tabs.push((
                Rect {
                    x: area.x + col,
                    y: label_y,
                    width: chip_w,
                    height: 1,
                },
                pane_id,
                *tab,
            ));
            col += chip_w + 2;
        }
        rows.push(Line::from(label_spans));
        rows.push(Line::from(bar_spans));
        let _ = bar_y;
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
        // Body — no header/label row. The tab strip above already
        // says "Body"; the body content starts at the first line
        // right below it, matching Bruno/Postman's "the body IS
        // the pane" idiom.
        //
        // Format chip lives at the top-right of the body area for
        // JSON bodies — see the block below where we register
        // `request_format_button`.
        let b_focus = rp.focus == EditField::Body;
        let body = rp.request.body.as_deref().unwrap_or("");
        let detected = detect_body_kind(body);
        if body.is_empty() {
            let empty_y = rows.len() as u16;
            rows.push(Line::from(vec![Span::styled(
                "    (empty)".to_string(),
                dim,
            )]));
            register_field(fields, empty_y, EditField::Body);
        } else {
            // JSON body: pre-compute tree-sitter colored spans per
            // line so keys/strings/numbers/keywords are colored the
            // same way as the response view's JSON body. Falls back
            // to plain-fg on non-JSON.
            let json_spans: Vec<Vec<crate::highlight::ColoredSpan>> = if detected == Some("JSON") {
                crate::highlight::highlight_lines(body, "json")
            } else {
                Vec::new()
            };
            // Line-number gutter — mirrors the Response body's
            // treatment so both read as "loaded file" views.
            let total_lines = body.lines().count().max(1);
            let gutter_w = total_lines.to_string().len();
            let gutter = |n: usize, t: theme::Theme| {
                Span::styled(
                    format!(" {:>width$} ", n, width = gutter_w),
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )
            };
            for (i, line) in body.lines().enumerate() {
                let row_y = rows.len() as u16;
                let n = i + 1;
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
                // JSON gets colored_line (per-token color); other
                // content types keep the plain grey_fg rendering.
                let content_line = if let Some(spans) = json_spans.get(i) {
                    let mut inner = colored_line(&rendered, spans, t.grey_fg, t);
                    inner.spans.insert(0, gutter(n, t));
                    inner
                } else {
                    Line::from(vec![
                        gutter(n, t),
                        Span::styled(rendered, Style::default().fg(t.grey_fg).bg(t.bg_dark)),
                    ])
                };
                rows.push(content_line);
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
                        // Caret sits after the gutter: " NN " = gutter_w + 2 cols.
                        let prefix_cols = (gutter_w as u16).saturating_add(2);
                        *caret = Some((area.x + prefix_cols + col_in_line, y));
                    }
                }
            }
            // Trailing newline ⇒ caret on an empty line at the end.
            if b_focus && focused && caret.is_none() && body.ends_with('\n') {
                let y = rows.len() as u16;
                rows.push(plain(String::new(), body_style));
                let prefix_cols = (gutter_w as u16).saturating_add(2);
                *caret = Some((area.x + prefix_cols, y));
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
                // Hover highlight — when the mouse is over this row,
                // paint it with the shared menu-family highlight so
                // it reads as the row that'll react to a click.
                // (#11 v13)
                let is_hover = rp.hover_params_key.as_deref() == Some(k.as_str());
                let row_bg = if is_hover { t.cyan } else { t.bg_dark };
                let key_fg = if is_hover { t.bg_dark } else { t.cyan };
                let sep_fg = if is_hover { t.bg_dark } else { t.comment };
                let val_fg = if is_hover { t.bg_dark } else { t.fg };
                let chev_fg = if is_hover { t.bg_dark } else { t.comment };
                rows.push(Line::from(vec![
                    Span::styled("  ", Style::default().bg(row_bg)),
                    Span::styled("› ", Style::default().fg(chev_fg).bg(row_bg)),
                    Span::styled(
                        k.clone(),
                        Style::default()
                            .fg(key_fg)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(" = ".to_string(), Style::default().fg(sep_fg).bg(row_bg)),
                    Span::styled(v.clone(), Style::default().fg(val_fg).bg(row_bg)),
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
            let base_color = match *id {
                "clear" => t.red,
                "save_preset" => t.green,
                _ => t.fg,
            };
            // Hover highlight — same treatment as Params / Vars.
            // Hovered row keeps its semantic color but paints on the
            // cyan bg so users know which row will fire. (#11 v13)
            let is_hover = rp.hover_auth_id.as_deref() == Some(*id);
            let row_bg = if is_hover { t.cyan } else { t.bg_dark };
            let text_fg = if is_hover { t.bg_dark } else { base_color };
            rows.push(Line::from(vec![
                Span::styled("  ", Style::default().bg(row_bg)),
                Span::styled(
                    format!("{icon} {label}"),
                    Style::default()
                        .fg(text_fg)
                        .bg(row_bg)
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
                // Hover highlight — same treatment as Params. (#11 v13)
                let is_hover = rp.hover_vars_key.as_deref() == Some(k.as_str());
                let row_bg = if is_hover { t.cyan } else { t.bg_dark };
                let key_fg = if is_hover { t.bg_dark } else { t.cyan };
                let sep_fg = if is_hover { t.bg_dark } else { t.comment };
                let val_fg = if is_hover { t.bg_dark } else { t.fg };
                let chev_fg = if is_hover { t.bg_dark } else { t.comment };
                rows.push(Line::from(vec![
                    Span::styled("  ", Style::default().bg(row_bg)),
                    Span::styled("› ", Style::default().fg(chev_fg).bg(row_bg)),
                    Span::styled(
                        k.clone(),
                        Style::default()
                            .fg(key_fg)
                            .bg(row_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(" = ".to_string(), Style::default().fg(sep_fg).bg(row_bg)),
                    Span::styled(preview, Style::default().fg(val_fg).bg(row_bg)),
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

    // Sending/Streaming/Done indicator (small). Skip entirely
    // when the pane is in the "not yet fired" placeholder state
    // — a red ✗ on a brand new blank request reads as an error
    // when nothing has actually failed. Real transport errors
    // still render red.
    if !matches!(&rp.state, RunState::Failed(e) if is_not_sent_placeholder(e)) {
        rows.push(plain(String::new(), body_style));
    }
    match &rp.state {
        RunState::Sending => rows.push(plain(
            "  ⟳ sending…".to_string(),
            Style::default().fg(t.yellow).bg(t.bg_dark),
        )),
        RunState::Streaming(r) => rows.push(plain(
            format!("  ▶ streaming · {} events received", r.sse_event_count),
            Style::default().fg(t.cyan).bg(t.bg_dark),
        )),
        RunState::Failed(e) if !is_not_sent_placeholder(e) => rows.push(plain(
            format!("  ✗ last send: {e}"),
            Style::default().fg(t.red).bg(t.bg_dark),
        )),
        RunState::Failed(_) => {}
        RunState::Done(r) => rows.push(plain(
            format!("  ✓ last: {} ({} ms)", r.status, r.elapsed.as_millis()),
            Style::default().fg(t.green).bg(t.bg_dark),
        )),
    }
}

/// True when a `Failed(msg)` state is the "not sent yet" placeholder
/// (blank Request pane, before the user fires anything) rather than
/// a real transport / assertion failure. Used by both the Request and
/// Response sections to skip the red ✗ error style on a fresh pane.
fn is_not_sent_placeholder(msg: &str) -> bool {
    msg.contains("not sent")
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
    let plain = |s: String, st: Style| Line::from(Span::styled(s, st));

    // The Response zone no longer echoes the request-line (▶ METHOD
    // URL) at the top — the Request zone above already shows that
    // exact info. Duplicating it read as a "here comes another
    // request" line inside what should be a response-only section.
    // Same reasoning skips the request-headers / request-body echo:
    // that content is authoritative in the Request zone's Headers /
    // Body tabs. Keep the `q_lower` filter binding — the
    // response-header render below still uses it.
    let q_lower = rp.filter.trim().to_ascii_lowercase();

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
        RunState::Failed(e) if is_not_sent_placeholder(e) => {
            // Fresh Request pane — nothing has failed yet. Render
            // as a subtle hint on comment fg, no ✗ glyph, so a
            // blank pane doesn't LOOK like an error state.
            rows.push(plain(
                format!("  {e}"),
                Style::default().fg(t.comment).bg(t.bg_dark),
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
            // Response sub-tabs (Body / Headers / Timeline / Tests).
            // The sub-tab strip is painted outside this fn; here we
            // branch on `rp.response_tab` to render only the active
            // tab's content.
            use crate::request_pane::ResponseTab;
            match rp.response_tab {
                ResponseTab::Headers => {
                    // Headers tab: full response-header list, filtered.
                    for (k, v) in &r.headers {
                        if header_matches_filter(k, v, &q_lower) {
                            rows.push(header_row(k, v, t));
                        }
                    }
                    return;
                }
                ResponseTab::Timeline => {
                    // v1 placeholder — a full request timeline
                    // (DNS/connect/TLS/send/receive) is a follow-up.
                    // For now show the total elapsed as the one
                    // number we do have.
                    rows.push(plain(
                        format!("  ⟳ total elapsed: {} ms", r.elapsed.as_millis()),
                        Style::default().fg(t.fg).bg(t.bg_dark),
                    ));
                    rows.push(plain(String::new(), body_style));
                    rows.push(plain(
                        "  (per-phase timing is a follow-up)".to_string(),
                        Style::default().fg(t.comment).bg(t.bg_dark),
                    ));
                    return;
                }
                ResponseTab::Tests => {
                    // Tests tab: assertion results (@assert directives
                    // in the .http file).
                    if r.assertions.is_empty() {
                        rows.push(plain(
                            "  (no assertions in this request)".to_string(),
                            Style::default().fg(t.comment).bg(t.bg_dark),
                        ));
                        return;
                    }
                    for a in &r.assertions {
                        if a.passed {
                            rows.push(plain(
                                format!("  ✓ {}", a.label),
                                Style::default().fg(t.green).bg(t.bg_dark),
                            ));
                        } else {
                            rows.push(plain(
                                format!("  ✗ {}", a.label),
                                Style::default()
                                    .fg(t.red)
                                    .bg(t.bg_dark)
                                    .add_modifier(Modifier::BOLD),
                            ));
                        }
                    }
                    return;
                }
                ResponseTab::Body => {}
            }
            // Body tab (default) — the pretty JSON body flows below
            // starting fresh at row 0 (no header echo).
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
            // Line-number gutter — like the editor's. Width tracks
            // the total-line-count digits so wide files (1000+ lines)
            // don't crowd the body. Rendered on `bg_dark` in
            // `comment` fg — same subdued treatment as the editor.
            let total_lines = pretty.lines().count().max(1);
            let gutter_w = total_lines.to_string().len();
            let gutter = |n: usize, t: theme::Theme| {
                Span::styled(
                    format!(" {:>width$} ", n, width = gutter_w),
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )
            };
            // Optional word-wrap — soft-wraps each line at the pane
            // width so long JSON strings stay visible. `w` in Response
            // view toggles. Wrapped continuation rows show a blank
            // gutter so the number aligns with the FIRST wrapped chunk.
            let wrap_plain =
                |s: &str, out: &mut Vec<Line<'static>>, style: Style, n: usize, t: theme::Theme| {
                    let blank_gutter =
                        Span::styled(" ".repeat(gutter_w + 2), Style::default().bg(t.bg_dark));
                    match body_wrap_width {
                        Some(w) if s.chars().count() > w as usize => {
                            let chars: Vec<char> = s.chars().collect();
                            for (chunk_i, chunk) in chars.chunks(w as usize).enumerate() {
                                let g = if chunk_i == 0 {
                                    gutter(n, t)
                                } else {
                                    blank_gutter.clone()
                                };
                                let text: String = chunk.iter().collect();
                                out.push(Line::from(vec![g, Span::styled(text, style)]));
                            }
                        }
                        _ => out.push(Line::from(vec![
                            gutter(n, t),
                            Span::styled(s.to_string(), style),
                        ])),
                    }
                };
            let with_gutter =
                |mut line: Line<'static>, n: usize, t: theme::Theme| -> Line<'static> {
                    line.spans.insert(0, gutter(n, t));
                    line
                };
            // Body filter — same query as the header filter. A line
            // shows if it contains the query (case-insensitive) OR
            // its neighbors do (±1 for context). Empty filter shows
            // every line. Original line numbers are preserved in the
            // gutter even when non-matching lines are hidden.
            if q_lower.is_empty() {
                for (i, l) in pretty.lines().enumerate() {
                    let n = i + 1;
                    let spans = get_spans(i);
                    if body_wrap_width.is_none() && !spans.is_empty() {
                        rows.push(with_gutter(colored_line(l, spans, t.fg, t), n, t));
                    } else {
                        wrap_plain(l, rows, body_style, n, t);
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
                    let n = i + 1;
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
                        rows.push(with_gutter(colored_line(l, spans, t.fg, t), n, t));
                    } else {
                        wrap_plain(l, rows, style, n, t);
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
