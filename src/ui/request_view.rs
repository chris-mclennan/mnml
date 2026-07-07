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
/// Which HTTP-tab is calling `render_kv_table` — controls `EditField`
/// registration and the hover-key lookup for the row-highlight.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KvTableKind {
    Params,
    Headers,
    /// #23 v3 — env var table (Vars tab). Rows come from the
    /// active .env file; commits write back through
    /// `write_env_var` / `http_delete_env_key`.
    Vars,
}

/// Excel-cell key/value table shared by the Params and Headers tabs.
///
/// Renders top border → header row → data rows (each with row
/// separator) → optional draft row → bottom border → `+ Add row`
/// chip (when no draft) or a hint line (when drafting).
///
/// Registers click rects into `params_rows_local` for:
/// - data rows — full row width, keyed on the row's name (click
///   anywhere on the row → delete).
/// - `+ Add row` — full area width, empty-string key.
/// - `✓` draft cell — 3 cells, `"\0COMMIT"` sentinel key.
///
/// Sentinels start with `\0` because HTTP header names + URL query
/// keys forbid the null byte, so no user data can collide with the
/// prefix. Was `__NAME:` / `__VAL:` etc. — a legitimately named
/// `__COMMIT__` header would have collided.
///
/// The `key_color_default` param lets Params (fg-BOLD) and Headers
/// (cyan-BOLD) render their key columns in their preferred color
/// without duplicating the rest of the 180-line render.
#[allow(clippy::too_many_arguments)]
pub(crate) fn render_kv_table(
    rows: &mut Vec<Line<'static>>,
    fields: &mut Vec<(Rect, PaneId, EditField)>,
    area: Rect,
    t: theme::Theme,
    dim: Style,
    data: &[(String, String)],
    draft: Option<&crate::request_pane::InlineKvDraft>,
    kv_edit: Option<&crate::request_pane::KvValueEdit>,
    kind: KvTableKind,
    hover_key: Option<&str>,
    pane_id: PaneId,
    params_rows_local: &mut Vec<(Rect, String)>,
) {
    const TABLE_MAX_W: u16 = 100;
    const TABLE_RIGHT_PAD: u16 = 3;
    let _table_x = area.x.saturating_add(2);
    let table_w = area
        .width
        .saturating_sub(2)
        .saturating_sub(TABLE_RIGHT_PAD)
        .clamp(20, TABLE_MAX_W);
    let x_col_w: u16 = 3;
    let inner_w = table_w.saturating_sub(x_col_w).saturating_sub(4);
    let name_w = (inner_w * 35 / 100).max(8);
    let value_w = inner_w.saturating_sub(name_w);

    // Field the row's fallback click focuses. Params rows map to
    // `Url` because query params live in the URL — a click that
    // misses the cell-level rects lands on the URL field, which
    // is the natural edit target for anything param-related.
    let edit_field = match kind {
        KvTableKind::Params => EditField::Url,
        KvTableKind::Headers => EditField::Headers,
        // Vars rows are file-backed; there's no in-pane edit
        // field. Fall back to Url so the tab-cycle stays valid
        // (any click that misses cell rects doesn't panic).
        KvTableKind::Vars => EditField::Url,
    };
    let register = |fields: &mut Vec<(Rect, PaneId, EditField)>, row_y: u16| {
        fields.push((
            Rect {
                x: area.x,
                y: row_y,
                width: area.width,
                height: 1,
            },
            pane_id,
            edit_field,
        ));
    };

    let make_border = |left: char, sep: char, right: char, fill: char| -> Line<'static> {
        let n_seg: String = std::iter::repeat_n(fill, (name_w + 2) as usize).collect();
        let v_seg: String = std::iter::repeat_n(fill, (value_w + 2) as usize).collect();
        let x_seg: String = std::iter::repeat_n(fill, x_col_w as usize).collect();
        Line::from(vec![
            Span::styled("  ", Style::default().bg(t.bg_dark)),
            Span::styled(
                format!("{}{}{}{}{}{}{}", left, n_seg, sep, v_seg, sep, x_seg, right),
                Style::default().fg(t.bg3).bg(t.bg_dark),
            ),
        ])
    };
    let make_row = |key_text: String,
                    val_text: String,
                    key_style: Style,
                    val_style: Style,
                    x_glyph: &str,
                    x_style: Style|
     -> Line<'static> {
        let mut key_s = key_text;
        if key_s.chars().count() > name_w as usize {
            let truncated: String = key_s.chars().take(name_w as usize).collect();
            key_s = truncated;
        }
        let pad_k = (name_w as usize).saturating_sub(key_s.chars().count());
        let mut val_s = val_text;
        if val_s.chars().count() > value_w as usize {
            let truncated: String = val_s.chars().take(value_w as usize).collect();
            val_s = truncated;
        }
        let pad_v = (value_w as usize).saturating_sub(val_s.chars().count());
        let border = Span::styled("│", Style::default().fg(t.bg3).bg(t.bg_dark));
        Line::from(vec![
            Span::styled("  ", Style::default().bg(t.bg_dark)),
            border.clone(),
            Span::styled(" ", Style::default().bg(t.bg_dark)),
            Span::styled(key_s, key_style),
            Span::styled(" ".repeat(pad_k), Style::default().bg(t.bg_dark)),
            Span::styled(" ", Style::default().bg(t.bg_dark)),
            border.clone(),
            Span::styled(" ", Style::default().bg(t.bg_dark)),
            Span::styled(val_s, val_style),
            Span::styled(" ".repeat(pad_v), Style::default().bg(t.bg_dark)),
            Span::styled(" ", Style::default().bg(t.bg_dark)),
            border.clone(),
            Span::styled(x_glyph.to_string(), x_style),
            border,
        ])
    };
    let key_color_default = match kind {
        KvTableKind::Params => t.fg,
        KvTableKind::Headers => t.cyan,
        KvTableKind::Vars => t.cyan,
    };

    // Top border + header + header separator.
    rows.push(make_border('┌', '┬', '┐', '─'));
    let hdr_style = Style::default()
        .fg(t.comment)
        .bg(t.bg_dark)
        .add_modifier(Modifier::BOLD);
    rows.push(make_row(
        "Name".to_string(),
        "Value".to_string(),
        hdr_style,
        hdr_style,
        "   ",
        Style::default().bg(t.bg_dark),
    ));
    rows.push(make_border('├', '┼', '┤', '─'));

    // Data rows.
    // Check whether this table's active kv_edit targets a row we're
    // about to render — matched by (kind, original_key).
    let edit_target = kv_edit.filter(|e| {
        matches!(
            (kind, e.kind),
            (KvTableKind::Params, crate::request_pane::KvEditKind::Params)
                | (
                    KvTableKind::Headers,
                    crate::request_pane::KvEditKind::Headers
                )
                | (KvTableKind::Vars, crate::request_pane::KvEditKind::Vars)
        )
    });
    // Column offsets used to build cell-level click rects.
    // Row layout (from x = area.x): 2 pad + 1 border + 1 space +
    // name_w + 1 pad + 1 space + 1 border + 1 space + value_w +
    // 1 pad + 1 space + 1 border + 3 X + 1 border
    let name_col_x_off: u16 = 2 + 1 + 1;
    let value_col_x_off: u16 = 2 + 1 + 1 + name_w + 1 + 1 + 1;
    let x_col_x_off: u16 = value_col_x_off + value_w + 1 + 1 + 1;
    for (i, (k, v)) in data.iter().enumerate() {
        let is_hover = hover_key == Some(k.as_str());
        let row_is_editing = edit_target.map(|e| e.original_key == *k).unwrap_or(false);
        let editing_name = row_is_editing && edit_target.map(|e| e.editing_name).unwrap_or(false);
        let editing_value = row_is_editing && !editing_name;
        let name_display = if editing_name {
            format!("{}▏", edit_target.unwrap().buffer)
        } else {
            k.clone()
        };
        let key_style = if editing_name {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else if is_hover {
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default()
                .fg(key_color_default)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        };
        let val_display = if editing_value {
            format!("{}▏", edit_target.unwrap().buffer)
        } else {
            v.clone()
        };
        let val_style = if editing_value {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(t.bg_dark)
        };
        let x_style = Style::default().fg(t.red).bg(t.bg_dark);
        let row_y = rows.len() as u16;
        rows.push(make_row(
            name_display,
            val_display,
            key_style,
            val_style,
            " ✕ ",
            x_style,
        ));
        // Cell-level click rects: name cell → rename edit,
        // value cell → value edit, X cell → delete.
        params_rows_local.push((
            Rect {
                x: area.x.saturating_add(name_col_x_off),
                y: row_y,
                width: name_w,
                height: 1,
            },
            format!("\0NAME{k}"),
        ));
        params_rows_local.push((
            Rect {
                x: area.x.saturating_add(value_col_x_off),
                y: row_y,
                width: value_w,
                height: 1,
            },
            format!("\0VAL{k}"),
        ));
        params_rows_local.push((
            Rect {
                x: area.x.saturating_add(x_col_x_off),
                y: row_y,
                width: 3,
                height: 1,
            },
            format!("\0DEL{k}"),
        ));
        register(fields, row_y);
        if i + 1 < data.len() || draft.is_some() {
            rows.push(make_border('├', '┼', '┤', '─'));
        }
    }

    // Draft row.
    if let Some(draft) = draft {
        let key_display = if draft.key.is_empty() && !draft.on_value {
            "▏".to_string()
        } else if draft.key.is_empty() {
            "(name)".to_string()
        } else if !draft.on_value {
            format!("{}▏", draft.key)
        } else {
            draft.key.clone()
        };
        let val_display = if draft.value.is_empty() && draft.on_value {
            "▏".to_string()
        } else if draft.value.is_empty() {
            "(value)".to_string()
        } else if draft.on_value {
            format!("{}▏", draft.value)
        } else {
            draft.value.clone()
        };
        let key_style = if draft.on_value {
            Style::default().fg(t.comment).bg(t.bg_dark)
        } else {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        };
        let val_style = if draft.on_value {
            Style::default()
                .fg(t.yellow)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg_dark)
        };
        let draft_y = rows.len() as u16;
        let ready = !draft.key.trim().is_empty() && !draft.value.trim().is_empty();
        let check_color = if ready { t.green } else { t.comment };
        rows.push(make_row(
            key_display,
            val_display,
            key_style,
            val_style,
            " ✓ ",
            Style::default()
                .fg(check_color)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ));
        // ✓ cell sits in the same X column as the data-row ✕ cell.
        // Reuse `x_col_x_off` — the earlier hand-computed offset
        // was 2 cells too far left, so the visible ✓ hit dead
        // space and clicks 2 columns to its left fired commit.
        let check_rect = Rect {
            x: area.x.saturating_add(x_col_x_off),
            y: draft_y,
            width: 3,
            height: 1,
        };
        params_rows_local.push((check_rect, "\0COMMIT".to_string()));
    }
    rows.push(make_border('└', '┴', '┘', '─'));

    // `+ Add row` chip (idle) or hint line (drafting).
    if draft.is_none() {
        let add_y = rows.len() as u16;
        rows.push(add_action_row("Add row", t));
        params_rows_local.push((
            Rect {
                x: area.x,
                y: add_y,
                width: area.width,
                height: 1,
            },
            String::new(),
        ));
        register(fields, add_y);
    } else {
        let hint_y = rows.len() as u16;
        rows.push(Line::from(vec![Span::styled(
            "    (Tab · `:`  ·  Enter → add + new row  ·  Shift+Enter → done  ·  Esc → cancel)"
                .to_string(),
            dim,
        )]));
        register(fields, hint_y);
    }
}

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

    // ── Layout: full-width top strip (Method / URL / Send / Save /
    // Clear) above two content zones (Request-tabs + Response) and
    // a pinned AI strip at the bottom. Bruno-style — the URL bar
    // spans the WHOLE pane width regardless of split orientation,
    // instead of being squeezed into the Request block's left
    // panel when Horizontal is selected.
    //
    // Row breakdown:
    //   top_bar (3 rows) — Method / URL / Send / Save / Clear
    //   Request + Response — split by orientation:
    //     Vertical  : Request top ~55%, Response bottom ~45%
    //     Horizontal: Request left ~50%, Response right ~50%
    //   ai (3 rows, always full width, always at the bottom)
    // Top pad: a blank row above the Method/URL top bar. Cheap
    // separation between the pane's tab strip and the URL row —
    // the top bar looked squashed against the tab strip without it.
    let top_pad = if area.height >= 8 { 1u16 } else { 0u16 };
    let top_bar_height = 3u16.min(area.height.saturating_sub(top_pad));
    let ai_height = 3u16.min(
        area.height
            .saturating_sub(top_pad)
            .saturating_sub(top_bar_height),
    );
    let middle_h = area
        .height
        .saturating_sub(top_pad)
        .saturating_sub(top_bar_height)
        .saturating_sub(ai_height);
    let top_bar_rect = Rect {
        x: area.x,
        y: area.y.saturating_add(top_pad),
        width: area.width,
        height: top_bar_height,
    };
    let ai_rect = Rect {
        x: area.x,
        y: area
            .y
            .saturating_add(top_pad)
            .saturating_add(top_bar_height)
            .saturating_add(middle_h),
        width: area.width,
        height: ai_height,
    };
    let (request_rect, response_rect) = match rp.split_orientation {
        crate::request_pane::SplitOrientation::Vertical => {
            // #polish 2026-07-06 — even 50/50 split. Was 55/45
            // biased toward Request; user reported Request looked
            // taller than Response and wanted a centered
            // division. `middle_h / 2` puts the divider on the
            // exact center row; any odd remainder goes to the
            // Response half (matches horizontal split's rounding
            // behavior for consistency).
            let req_h = (middle_h / 2).max(6.min(middle_h));
            let res_h = middle_h.saturating_sub(req_h);
            (
                Rect {
                    x: area.x,
                    y: area
                        .y
                        .saturating_add(top_pad)
                        .saturating_add(top_bar_height),
                    width: area.width,
                    height: req_h,
                },
                Rect {
                    x: area.x,
                    y: area
                        .y
                        .saturating_add(top_pad)
                        .saturating_add(top_bar_height)
                        .saturating_add(req_h),
                    width: area.width,
                    height: res_h,
                },
            )
        }
        crate::request_pane::SplitOrientation::Horizontal => {
            let req_w = area.width / 2;
            let res_w = area.width.saturating_sub(req_w);
            (
                Rect {
                    x: area.x,
                    y: area
                        .y
                        .saturating_add(top_pad)
                        .saturating_add(top_bar_height),
                    width: req_w,
                    height: middle_h,
                },
                Rect {
                    x: area.x.saturating_add(req_w),
                    y: area
                        .y
                        .saturating_add(top_pad)
                        .saturating_add(top_bar_height),
                    width: res_w,
                    height: middle_h,
                },
            )
        }
    };

    // ── Zone 1: Request ─────────────────────────────────────────
    // Fully-connected border — no "Request" title text on the top
    // border since the sub-panels (Method, URL, Send, Clear) label
    // themselves. Split-orientation chip still floats on the right.
    // ── Top bar (full width): Method / URL / Send / Save / Clear.
    // Painted OUTSIDE the Request block so the URL bar spans the
    // whole pane in both split orientations. The split-orientation
    // toggle chip floats on the top-right of the top bar (was on
    // the Request block's border in the earlier layout).
    const METHOD_BOX_WIDTH: u16 = 14;
    const MIN_URL_WIDTH: u16 = 20;
    const METHOD_URL_ROW_H: u16 = 3;
    // 2026-07-05: was `1` — the Method box's left border was
    // painted 1 cell right of the Request block's outer corner,
    // so the vertical rule from the block below didn't line up
    // with anything in the top bar. Zero the pad so the top-bar
    // boxes edge-to-edge match the block below. Right edge
    // (Code box) inherits the same treatment.
    const EDGE_PAD: u16 = 0;
    const SEND_BOX_WIDTH: u16 = 10;
    const SAVE_BOX_WIDTH: u16 = 10;
    const CLEAR_BOX_WIDTH: u16 = 11;
    const CODE_BOX_WIDTH: u16 = 12;
    // Env chip — sits between URL and Send. Fixed 14 cells so a
    // short env name (`staging`, `dev`, `prod`) fits with the
    // leading `env: ` label + trailing `▾` chevron.
    const ENV_BOX_WIDTH: u16 = 14;
    let show_sub_panels = top_bar_rect.width
        >= METHOD_BOX_WIDTH
            + MIN_URL_WIDTH
            + ENV_BOX_WIDTH
            + SEND_BOX_WIDTH
            + SAVE_BOX_WIDTH
            + CLEAR_BOX_WIDTH
            + CODE_BOX_WIDTH
            + 2 * EDGE_PAD
        && top_bar_rect.height >= METHOD_URL_ROW_H;

    let mut method_url_absolute: Vec<(Rect, EditField)> = Vec::new();
    let mut send_button_rect: Option<Rect> = None;
    let mut save_button_rect: Option<Rect> = None;
    let mut clear_button_rect: Option<Rect> = None;
    let mut code_button_rect: Option<Rect> = None;
    let mut env_button_rect: Option<Rect> = None;
    if show_sub_panels {
        // Layout across the top strip:
        //   [pad][Method][URL][Env][Send][Save][Clear][Code][pad]
        let row_y = top_bar_rect.y;
        let method_rect = Rect {
            x: top_bar_rect.x.saturating_add(EDGE_PAD),
            y: row_y,
            width: METHOD_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        let url_x = method_rect.x.saturating_add(METHOD_BOX_WIDTH);
        let url_width = top_bar_rect
            .width
            .saturating_sub(EDGE_PAD)
            .saturating_sub(METHOD_BOX_WIDTH)
            .saturating_sub(ENV_BOX_WIDTH)
            .saturating_sub(SEND_BOX_WIDTH)
            .saturating_sub(SAVE_BOX_WIDTH)
            .saturating_sub(CLEAR_BOX_WIDTH)
            .saturating_sub(CODE_BOX_WIDTH)
            .saturating_sub(EDGE_PAD);
        let url_rect = Rect {
            x: url_x,
            y: row_y,
            width: url_width,
            height: METHOD_URL_ROW_H,
        };
        let env_rect = Rect {
            x: url_x.saturating_add(url_width),
            y: row_y,
            width: ENV_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        let send_rect = Rect {
            x: env_rect.x.saturating_add(ENV_BOX_WIDTH),
            y: row_y,
            width: SEND_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        let save_rect = Rect {
            x: send_rect.x.saturating_add(SEND_BOX_WIDTH),
            y: row_y,
            width: SAVE_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        let clear_rect = Rect {
            x: save_rect.x.saturating_add(SAVE_BOX_WIDTH),
            y: row_y,
            width: CLEAR_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        let code_rect = Rect {
            x: clear_rect.x.saturating_add(CLEAR_BOX_WIDTH),
            y: row_y,
            width: CODE_BOX_WIDTH,
            height: METHOD_URL_ROW_H,
        };
        if let Some(mr) = draw_method_box(frame, rp, method_rect, focused, t) {
            method_url_absolute.push((mr, EditField::Method));
            app.rects.request_method_button = Some(mr);
        }
        if let Some(ur) = draw_url_box(frame, rp, url_rect, focused, &mut caret_abs, t) {
            method_url_absolute.push((ur, EditField::Url));
        }
        env_button_rect = draw_env_box(
            frame,
            env_rect,
            &workspace,
            env_override.as_deref(),
            &rp.request.url,
            t,
        );
        send_button_rect = draw_send_box(frame, rp, send_rect, t);
        save_button_rect = draw_save_box(frame, rp, save_rect, t);
        clear_button_rect = draw_clear_box(frame, clear_rect, t);
        code_button_rect = draw_code_box(frame, code_rect, t);
    }

    // ── Zone 1: Request (tab strip + tab content). Method/URL now
    // live in the top bar above; the Request block is just the
    // edit form for the currently-selected tab.
    let request_block = crate::ui::design_tokens::bordered_plain("");
    let request_inner = request_block.inner(request_rect);
    frame.render_widget(request_block, request_rect);
    // Split-orientation chip floats on the top-right of the Request
    // block's top border row (NOT the top bar — the top bar's
    // right end now hosts the Code chip and would collide). The
    // Request block's border row is a stable painted row we can
    // safely overwrite the rightmost few cells of.
    app.rects.request_split_toggle =
        paint_split_toggle_chip(frame, rp.split_orientation, request_rect, t);
    // The `⇔` chip that toggles a side-by-side edit split. Placed
    // to the LEFT of the split-orientation chip so both chrome chips
    // hug the right end of the Request block's border row.
    app.rects.request_edit_split_chip = paint_edit_split_chip(
        frame,
        rp.edit_tab_split.is_some(),
        request_rect,
        app.rects.request_split_toggle,
        t,
    );

    let tabs_rect = request_inner;
    let mut edit_tabs_split_local: Vec<(Rect, PaneId, crate::request_pane::EditTab)> = Vec::new();

    if tabs_rect.width > 0 && tabs_rect.height > 0 {
        let split_secondary = rp.edit_tab_split;
        // Slice tabs_rect into (left, divider, right) when a split
        // is active. Below the minimum width the split degrades to
        // primary-only so cells don't collide.
        let (left_rect, divider_rect, right_rect) = if let Some(_secondary) = split_secondary {
            const MIN_SIDE: u16 = 24;
            if tabs_rect.width > MIN_SIDE * 2 {
                let ratio = rp.edit_split_ratio.clamp(10, 90) as u32;
                let left_w = ((tabs_rect.width as u32 * ratio) / 100) as u16;
                let left_w = left_w.max(MIN_SIDE).min(tabs_rect.width - MIN_SIDE - 1);
                let left = Rect {
                    x: tabs_rect.x,
                    y: tabs_rect.y,
                    width: left_w,
                    height: tabs_rect.height,
                };
                let divider = Rect {
                    x: tabs_rect.x + left_w,
                    y: tabs_rect.y,
                    width: 1,
                    height: tabs_rect.height,
                };
                let right = Rect {
                    x: tabs_rect.x + left_w + 1,
                    y: tabs_rect.y,
                    width: tabs_rect.width - left_w - 1,
                    height: tabs_rect.height,
                };
                (left, Some(divider), Some(right))
            } else {
                (tabs_rect, None, None)
            }
        } else {
            (tabs_rect, None, None)
        };

        // Primary side (left when split, or whole tabs_rect otherwise).
        let mut edit_rows: Vec<Line> = Vec::new();
        draw_edit(
            rp,
            t,
            &mut edit_rows,
            left_rect,
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
            None,
        );
        let edit_view: Vec<Line> = edit_rows
            .iter()
            .take(left_rect.height as usize)
            .cloned()
            .collect();
        frame.render_widget(
            Paragraph::new(edit_view).style(Style::default().bg(t.bg_dark)),
            left_rect,
        );
        // Format chip (JSON) sits above the primary side only —
        // the secondary side has its own tab strip + content.
        app.rects.request_format_button = paint_body_format_chip(frame, rp, left_rect, t);

        // Divider (bg2 vertical bar between the two sides). Draggable.
        if let Some(div_rect) = divider_rect {
            let divider_line = Line::from(Span::styled(
                "\u{2502}".to_string(),
                Style::default().fg(t.bg3).bg(t.bg_dark),
            ));
            let divider_rows: Vec<Line> =
                (0..div_rect.height).map(|_| divider_line.clone()).collect();
            frame.render_widget(
                Paragraph::new(divider_rows).style(Style::default().bg(t.bg_dark)),
                div_rect,
            );
            app.rects.request_edit_split_divider = Some(div_rect);
        }

        // Secondary side.
        if let (Some(secondary), Some(right)) = (split_secondary, right_rect) {
            let mut edit_rows_r: Vec<Line> = Vec::new();
            let mut fields_r: Vec<(Rect, PaneId, EditField)> = Vec::new();
            let mut vars_rows_r: Vec<(Rect, String)> = Vec::new();
            let mut params_rows_r: Vec<(Rect, String)> = Vec::new();
            let mut auth_rows_r: Vec<(Rect, String)> = Vec::new();
            let mut caret_r: Option<(u16, u16)> = None;
            draw_edit(
                rp,
                t,
                &mut edit_rows_r,
                right,
                &mut caret_r,
                false, // secondary side does not own the caret
                pane_id,
                &mut fields_r,
                &mut edit_tabs_split_local,
                show_ws,
                &workspace,
                env_override.as_deref(),
                &mut vars_rows_r,
                &mut params_rows_r,
                &mut auth_rows_r,
                Some(secondary),
            );
            let edit_view_r: Vec<Line> = edit_rows_r
                .iter()
                .take(right.height as usize)
                .cloned()
                .collect();
            frame.render_widget(
                Paragraph::new(edit_view_r).style(Style::default().bg(t.bg_dark)),
                right,
            );
            // Secondary side's rects are relative to `right` — translate
            // y with `right.y` as origin.
            let right_h = right.height as usize;
            let right_origin = right.y;
            for (mut r, pid, f) in fields_r.drain(..) {
                let row_off = r.y as usize;
                if row_off >= right_h {
                    continue;
                }
                r.y = right_origin.saturating_add(row_off as u16);
                app.rects.request_fields.push((r, pid, f));
            }
            for (mut r, key) in vars_rows_r.drain(..) {
                let row_off = r.y as usize;
                if row_off >= right_h {
                    continue;
                }
                r.y = right_origin.saturating_add(row_off as u16);
                app.rects.request_vars_rows.push((r, key));
            }
            for (mut r, key) in params_rows_r.drain(..) {
                let row_off = r.y as usize;
                if row_off >= right_h {
                    continue;
                }
                r.y = right_origin.saturating_add(row_off as u16);
                app.rects.request_params_rows.push((r, key));
            }
            for (mut r, id) in auth_rows_r.drain(..) {
                let row_off = r.y as usize;
                if row_off >= right_h {
                    continue;
                }
                r.y = right_origin.saturating_add(row_off as u16);
                app.rects.request_auth_rows.push((r, id));
            }
        }
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
        let mut type_chip: Option<Rect> = None;
        let mut copy_chip: Option<Rect> = None;
        let mut wrap_chip: Option<Rect> = None;
        app.rects.request_response_tabs = paint_response_tab_strip(
            frame,
            rp,
            response_inner,
            t,
            &mut type_chip,
            &mut copy_chip,
            &mut wrap_chip,
        );
        app.rects.request_response_type_chip = type_chip;
        app.rects.request_response_copy_chip = copy_chip;
        app.rects.request_response_wrap_chip = wrap_chip;
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
    app.rects.request_save_button = save_button_rect;
    app.rects.request_clear_button = clear_button_rect;
    app.rects.request_code_button = code_button_rect;
    app.rects.request_env_button = env_button_rect;
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
    // Secondary tab strip — same y-translation shape but pushed into
    // a distinct rect vec so click routing knows which side to update.
    for (mut r, pid, tab) in edit_tabs_split_local.drain(..) {
        let row_off = r.y as usize;
        if row_off >= edit_h {
            continue;
        }
        r.y = edit_origin_y.saturating_add(row_off as u16);
        app.rects.request_edit_tabs_split.push((r, pid, tab));
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
#[allow(clippy::too_many_arguments)]
fn paint_response_tab_strip(
    frame: &mut Frame,
    rp: &crate::request_pane::RequestPane,
    response_inner: Rect,
    t: theme::Theme,
    type_chip_out: &mut Option<Rect>,
    copy_chip_out: &mut Option<Rect>,
    wrap_chip_out: &mut Option<Rect>,
) -> Vec<(Rect, crate::request_pane::ResponseTab)> {
    *type_chip_out = None;
    *copy_chip_out = None;
    *wrap_chip_out = None;
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
    // Response-header count for the "Headers" tab label — matches
    // Bruno's "Headers 24" affordance. Only shown when there's a
    // Done response with headers; otherwise the label stays bare.
    let header_count: Option<usize> = match &rp.state {
        RunState::Done(r) if !r.headers.is_empty() => Some(r.headers.len()),
        _ => None,
    };
    let mut label_spans: Vec<Span> = Vec::new();
    label_spans.push(Span::styled("  ", Style::default().bg(t.bg_dark)));
    let mut bar_spans: Vec<Span> = Vec::new();
    bar_spans.push(Span::styled("  ", Style::default().bg(t.bg_dark)));
    let mut col: u16 = 2;
    for tab in crate::request_pane::ResponseTab::ALL {
        let base = tab.label();
        // Append " N" to the Headers label when we know the count.
        let label = if matches!(tab, crate::request_pane::ResponseTab::Headers)
            && let Some(n) = header_count
        {
            format!("{base} {n}")
        } else {
            base.to_string()
        };
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
        label_spans.push(Span::styled(label.clone(), label_style));
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
    // Right-aligned content-type chip on the labels row. Reflects
    // the *effective* format (override if set, else auto-detect).
    // Click routes to `http_response_format_prompt` via
    // `App::rects::request_response_type_chip`.
    // Right-aligned chips, laid out from right to left:
    //   type chip ("JSON ▼") — always shown
    //   copy chip ("copy")   — always shown; toasts on empty body
    //   wrap chip ("wrap")   — always shown; on = cyan, off = dim
    //
    // Each chip is painted with a per-slot right-x that tracks how
    // much space the ones to its right already consumed.
    let type_label = effective_response_type_label(rp);
    let type_text = format!(" {type_label} \u{25BC} ");
    let type_w = type_text.chars().count() as u16;
    let copy_text = " copy ".to_string();
    let copy_w = copy_text.chars().count() as u16;
    let wrap_text = " wrap ".to_string();
    let wrap_w = wrap_text.chars().count() as u16;

    let mut right_edge = label_rect
        .x
        .saturating_add(label_rect.width)
        .saturating_sub(1);
    if label_rect.width >= type_w + 2 {
        let chip_x = right_edge.saturating_sub(type_w);
        let chip_rect = Rect {
            x: chip_x,
            y: label_rect.y,
            width: type_w,
            height: 1,
        };
        *type_chip_out = Some(chip_rect);
        frame.render_widget(
            Paragraph::new(vec![Line::from(vec![Span::styled(
                type_text,
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            )])])
            .style(Style::default().bg(t.bg_dark)),
            chip_rect,
        );
        right_edge = chip_x.saturating_sub(1);
    }
    if right_edge > label_rect.x + copy_w + 2 {
        let chip_x = right_edge.saturating_sub(copy_w);
        let chip_rect = Rect {
            x: chip_x,
            y: label_rect.y,
            width: copy_w,
            height: 1,
        };
        *copy_chip_out = Some(chip_rect);
        frame.render_widget(
            Paragraph::new(vec![Line::from(vec![Span::styled(
                copy_text,
                Style::default().fg(t.comment).bg(t.bg_dark),
            )])])
            .style(Style::default().bg(t.bg_dark)),
            chip_rect,
        );
        right_edge = chip_x.saturating_sub(1);
    }
    if right_edge > label_rect.x + wrap_w + 2 {
        let chip_x = right_edge.saturating_sub(wrap_w);
        let chip_rect = Rect {
            x: chip_x,
            y: label_rect.y,
            width: wrap_w,
            height: 1,
        };
        *wrap_chip_out = Some(chip_rect);
        let wrap_style = if rp.body_wrap {
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg_dark)
        };
        frame.render_widget(
            Paragraph::new(vec![Line::from(vec![Span::styled(wrap_text, wrap_style)])])
                .style(Style::default().bg(t.bg_dark)),
            chip_rect,
        );
    }
    rects
}

/// Effective response-type label — override wins over auto-detect.
fn effective_response_type_label(rp: &crate::request_pane::RequestPane) -> String {
    use crate::request_pane::ResponseBodyFormat;
    match rp.response_body_format {
        ResponseBodyFormat::Auto => detect_response_content_type(rp),
        ResponseBodyFormat::Json => "JSON".to_string(),
        ResponseBodyFormat::Xml => "XML".to_string(),
        ResponseBodyFormat::Html => "HTML".to_string(),
        ResponseBodyFormat::Text => "TEXT".to_string(),
    }
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
    // Layout: `[▥ ▤]` (5 chars). The old `[ ▥ ▤ ]` (7 chars)
    // rendered with visibly asymmetric inner gutters — `▥` and
    // `▤` have different left/right sidebearings in most Nerd
    // Fonts, so a symmetric space on each side visually collapses
    // one and inflates the other. Pinning the icons directly to
    // the brackets removes the asymmetry.
    let chip_w: u16 = 5;
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
        Span::styled("[", bracket),
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
        Span::styled("]", bracket),
    ]);
    frame.render_widget(
        Paragraph::new(vec![line]).style(Style::default().bg(t.bg_dark)),
        chip_rect,
    );
    Some(chip_rect)
}

/// The `⇔` chip that opens (or closes) a side-by-side split of the
/// Request pane's Edit content area. Sits on the Request block's
/// top border row, immediately to the LEFT of the split-orientation
/// `[▥ ▤]` chip. Active (split open) = cyan bold; inactive = comment.
/// 2026-07-07.
fn paint_edit_split_chip(
    frame: &mut Frame,
    split_open: bool,
    request_rect: Rect,
    orient_chip: Option<Rect>,
    t: theme::Theme,
) -> Option<Rect> {
    let chip_w: u16 = 3; // `[⇔]`
    let right_edge_x = match orient_chip {
        Some(r) => r.x,
        None => request_rect
            .x
            .saturating_add(request_rect.width)
            .saturating_sub(2),
    };
    if right_edge_x <= request_rect.x + 4 || request_rect.height == 0 {
        return None;
    }
    let chip_x = right_edge_x.saturating_sub(chip_w).saturating_sub(1);
    let chip_rect = Rect {
        x: chip_x,
        y: request_rect.y,
        width: chip_w,
        height: 1,
    };
    let bracket = Style::default().fg(t.bg3).bg(t.bg_dark);
    let icon_style = if split_open {
        Style::default()
            .fg(t.cyan)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(t.comment).bg(t.bg_dark)
    };
    let line = Line::from(vec![
        Span::styled("[", bracket),
        Span::styled("\u{21D4}", icon_style),
        Span::styled("]", bracket),
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

/// Save sub-panel — click writes the current fields back to
/// `source_path`. When `source_path` is None, opens a Save-As
/// prompt. Rendered as a bold blue "⎘ Save" label. Dim when
/// the pane has no URL yet (nothing meaningful to save).
fn draw_save_box(
    frame: &mut Frame,
    rp: &crate::request_pane::RequestPane,
    rect: Rect,
    t: theme::Theme,
) -> Option<Rect> {
    let block = crate::ui::design_tokens::bordered_plain("Save");
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    if inner.width == 0 || inner.height == 0 {
        return None;
    }
    let color = if rp.request.url.trim().is_empty() {
        t.comment
    } else {
        t.blue
    };
    let text = " \u{2398} Save ";
    let text_w = text.chars().count() as u16;
    let mid_pad = inner.width.saturating_sub(text_w) / 2;
    let content = Line::from(vec![
        Span::styled(" ".repeat(mid_pad as usize), Style::default().bg(t.bg_dark)),
        Span::styled(
            text.to_string(),
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

/// Env sub-panel — modal_panel titled "Env" with the active env
/// name + a ▾ chevron so the box reads as a dropdown affordance.
/// Left-click → env picker (`open_http_env_picker`); right-click
/// opens a small context menu. Cyan when a per-pane override is
/// active, dim when no env is available at all, normal fg otherwise.
fn draw_env_box(
    frame: &mut Frame,
    rect: Rect,
    workspace: &std::path::Path,
    env_override: Option<&str>,
    url: &str,
    t: theme::Theme,
) -> Option<Rect> {
    let block = crate::ui::design_tokens::bordered_plain("Env");
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    if inner.width == 0 || inner.height == 0 {
        return None;
    }
    let envset = crate::http::template::EnvSet::select(workspace, env_override);
    let env_name = envset.name().map(str::to_string);
    let has_override = env_override.is_some();
    // #24 v2 — detect unresolved `{{VAR}}` refs in the URL to
    // decide whether the chip should carry a warning color.
    // Only checks vars against the currently-loaded EnvSet; if
    // ANY referenced var is missing, the chip turns yellow.
    let has_unresolved = has_unresolved_var(url, &envset);
    let (label, color) = match env_name {
        _ if has_unresolved => (env_name.unwrap_or_else(|| "none".to_string()), t.yellow),
        Some(n) if has_override => (n, t.cyan),
        Some(n) => (n, t.fg),
        None => ("none".to_string(), t.comment),
    };
    // Truncate at 6 chars + ellipsis so a long env name stays
    // within the fixed chip width. Room budget: `NAME ▾ ` (7 cells)
    // inside a 14-wide inner (12 minus border).
    let short = if label.chars().count() > 6 {
        let mut s: String = label.chars().take(5).collect();
        s.push('\u{2026}');
        s
    } else {
        label
    };
    let text = format!(" {short} \u{25BE} ");
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

/// #24 v2 — thin wrapper around `template::unresolved` for the
/// env chip's warning-color check. Returns true when the URL
/// references any `{{VAR}}` that's missing from `envset`.
fn has_unresolved_var(text: &str, envset: &crate::http::template::EnvSet) -> bool {
    !crate::http::template::unresolved(text, envset).is_empty()
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

/// Code sub-panel — Bruno-style `</>` "Generate Code" button.
/// Click opens a language picker (curl / Python / JS / Go / wget /
/// HTTPie) and copies the rendered snippet to the clipboard.
fn draw_code_box(frame: &mut Frame, rect: Rect, t: theme::Theme) -> Option<Rect> {
    let block = crate::ui::design_tokens::bordered_plain("Code");
    let inner = block.inner(rect);
    frame.render_widget(block, rect);
    if inner.width == 0 || inner.height == 0 {
        return None;
    }
    let text = " </> Code ";
    let text_w = text.chars().count() as u16;
    let mid_pad = inner.width.saturating_sub(text_w) / 2;
    let content = Line::from(vec![
        Span::styled(" ".repeat(mid_pad as usize), Style::default().bg(t.bg_dark)),
        Span::styled(
            text.to_string(),
            Style::default()
                .fg(t.purple)
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
    // Sending → the button flips to "⟳ Abort" (yellow) so users
    // have a mouse-reachable cancel affordance. Click during Sending
    // routes to `http.abort` instead of `http.send`. Other states
    // show ▶ Send with per-state color: cyan while Streaming, dim
    // when URL is empty ("not ready"), green when ready to fire.
    // #polish — `⟳` (U+27F3) needs an extra space; ▶ (U+25B6)
    // renders fine with a single space. Encode the gap per glyph.
    let (glyph, gap, label, color) = match &rp.state {
        crate::request_pane::RunState::Sending => ("\u{27F3}", "  ", "Abort", t.yellow),
        crate::request_pane::RunState::Streaming(_) => ("\u{25B6}", " ", "Send", t.cyan),
        _ if rp.request.url.trim().is_empty() => ("\u{25B6}", " ", "Send", t.comment),
        _ => ("\u{25B6}", " ", "Send", t.green),
    };
    let text = format!(" {glyph}{gap}{label} ");
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
    // When `Some`, render this tab instead of `rp.edit_tab` — used by
    // the right side of a side-by-side edit split.
    tab_override: Option<crate::request_pane::EditTab>,
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
    // `label_style` + `bar_span` closures were used by the old
    // section-header rows (Body / Headers / Params labels above
    // their content). The redundant labels were removed 2026-07-05
    // since the tab strip already labels the active view. The
    // closures are kept commented out here as a note; if a future
    // sub-section header inside a tab needs the focus-bar treatment
    // it can re-introduce them.
    let _ = t;

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
        let strip_tab = tab_override.unwrap_or(rp.edit_tab);
        for tab in EditTab::ALL {
            let label = tab.label();
            let is_cur = strip_tab == *tab;
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
    let cur_tab = tab_override.unwrap_or(rp.edit_tab);

    if cur_tab == crate::request_pane::EditTab::Headers {
        // Headers tab — Excel-cell table shared with Params
        // (`render_kv_table`). Rows come from parsing
        // `headers_buffer`; the inline draft appends
        // `Name: value\n` on commit + re-parses.
        let headers: Vec<(String, String)> = rp
            .headers_buffer
            .lines()
            .filter_map(|l| {
                let t = l.trim();
                if t.is_empty() || t.starts_with('#') {
                    return None;
                }
                let (k, v) = crate::request_pane::split_header_line(t)?;
                Some((k.trim().to_string(), v.trim().to_string()))
            })
            .collect();
        render_kv_table(
            rows,
            fields,
            area,
            t,
            dim,
            &headers,
            rp.headers_add.as_ref(),
            rp.kv_edit.as_ref(),
            KvTableKind::Headers,
            None,
            pane_id,
            params_rows_local,
        );
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
            // Empty body: render a numbered "line 1" so the pane
            // reads as a ready-to-type editor (not a status
            // message). Caret sits at column 4 (after the ` 1 `
            // gutter) when Body has focus so typing lands directly
            // on that line.
            let empty_y = rows.len() as u16;
            rows.push(Line::from(vec![
                Span::styled(" 1 ", Style::default().fg(t.comment).bg(t.bg_dark)),
                Span::styled(String::new(), Style::default().bg(t.bg_dark)),
            ]));
            register_field(fields, empty_y, EditField::Body);
            if b_focus && focused && caret.is_none() {
                *caret = Some((area.x + 3, empty_y));
            }
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
    // ── Params tab — inline `+ Add` row + clickable existing
    //     params. Click `+ Add` → start an inline key/value draft
    //     row (Tab cycles fields, Enter commits, Esc cancels).
    //     No section label (the tab strip already labels this view).
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
        render_kv_table(
            rows,
            fields,
            area,
            t,
            dim,
            &params,
            rp.params_add.as_ref(),
            rp.kv_edit.as_ref(),
            KvTableKind::Params,
            rp.hover_params_key.as_deref(),
            pane_id,
            params_rows_local,
        );
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
        // Some glyphs (⟳, ⇓, ×) render tight against the following
        // char in Nerd Font / CoreText combos — the ⟳ especially
        // eats its right sidebearing. Encode each row as `(icon,
        // space, label)` so we can bump the gap on those glyphs
        // without unbalancing the `+` rows.
        let actions: &[(&str, &str, &str, char)] = &[
            ("set_bearer", " ", "Set Bearer token…", '+'),
            ("set_basic", " ", "Set Basic auth (user:pass)…", '+'),
            ("set_api_key", " ", "Set X-Api-Key…", '+'),
            ("apply_preset", "  ", "Apply saved preset…", '⟳'),
            ("save_preset", " ", "Save current as preset…", '⇓'),
            ("clear", " ", "Clear Authorization", '×'),
        ];
        for (id, gap, label, icon) in actions {
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
                    format!("{icon}{gap}{label}"),
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
        // Read active env's vars. Runtime override wins first; then
        // .rqst → .mnml order with last-wins on same key. Matches
        // EnvSet::load precedence exactly.
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
        // Header line: env name + hint (v3 supports cell inline edit).
        let name_y = rows.len() as u16;
        rows.push(Line::from(vec![
            Span::styled("    env: ", dim),
            Span::styled(
                format!("{env_name}.env"),
                Style::default()
                    .fg(t.cyan)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled("   · click cell to edit · Tab commits · Esc cancels", dim),
        ]));
        register_tab_row(fields, name_y);
        rows.push(plain(String::new(), body_style));

        // #23 v3 — Vars now uses the shared render_kv_table helper
        // (same table shape as Params / Headers), with a Vars-scoped
        // KvEditKind so cell edits commit through
        // `App::commit_vars_kv_edit` (writes back to .env). No
        // draft-add row for Vars in v3 — the `+ Add new variable…`
        // action row below still opens the palette prompt.
        let data: Vec<(String, String)> = by_key.into_iter().collect();
        render_kv_table(
            rows,
            fields,
            area,
            t,
            dim,
            &data,
            None, // no draft/add-row support for Vars in v3
            rp.kv_edit.as_ref(),
            KvTableKind::Vars,
            rp.hover_vars_key.as_deref(),
            pane_id,
            vars_rows_local,
        );
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
            "  ⟳  sending…".to_string(),
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
                "  ⟳  sending…".to_string(),
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
                    // Per-phase timing bars. reqwest::blocking only
                    // exposes two natural boundaries — `send()`
                    // returning (DNS + connect + TLS + request-send
                    // + response-headers all bundled as "wait") and
                    // the body-read loop after ("receive"). Render
                    // as horizontal bars scaled to the max of the
                    // two phases so the ratio is obvious at a glance.
                    let wait_ms = r.timing.wait.as_millis() as u64;
                    let recv_ms = r.timing.receive.as_millis() as u64;
                    let total_ms = r.elapsed.as_millis() as u64;
                    let max = wait_ms.max(recv_ms).max(1);
                    const BAR_W: u64 = 40;
                    let make_bar = |ms: u64, color: ratatui::style::Color| {
                        let filled = (ms * BAR_W / max) as usize;
                        Line::from(vec![
                            Span::styled("  ".to_string(), Style::default().bg(t.bg_dark)),
                            Span::styled(
                                "█".repeat(filled),
                                Style::default().fg(color).bg(t.bg_dark),
                            ),
                            Span::styled(
                                "░".repeat(BAR_W as usize - filled),
                                Style::default().fg(t.bg3).bg(t.bg_dark),
                            ),
                            Span::styled(
                                format!("  {ms} ms"),
                                Style::default().fg(t.comment).bg(t.bg_dark),
                            ),
                        ])
                    };
                    rows.push(Line::from(vec![
                        Span::styled(
                            "  Wait     ".to_string(),
                            Style::default()
                                .fg(t.comment)
                                .bg(t.bg_dark)
                                .add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(
                            "(connect + TLS + send + headers received)".to_string(),
                            Style::default().fg(t.comment).bg(t.bg_dark),
                        ),
                    ]));
                    rows.push(make_bar(wait_ms, t.blue));
                    rows.push(plain(String::new(), body_style));
                    rows.push(Line::from(vec![
                        Span::styled(
                            "  Receive  ".to_string(),
                            Style::default()
                                .fg(t.comment)
                                .bg(t.bg_dark)
                                .add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(
                            "(body read)".to_string(),
                            Style::default().fg(t.comment).bg(t.bg_dark),
                        ),
                    ]));
                    rows.push(make_bar(recv_ms, t.green));
                    rows.push(plain(String::new(), body_style));
                    rows.push(plain(
                        format!("  Total    {total_ms} ms"),
                        Style::default()
                            .fg(t.fg)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::BOLD),
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
            // Pick the syntax-highlighter language. Override wins
            // over auto-detect. XML aliases to HTML (same grammar).
            // Text = no highlight.
            use crate::request_pane::ResponseBodyFormat;
            let highlight_lang: Option<&'static str> = match rp.response_body_format {
                ResponseBodyFormat::Json => Some("json"),
                ResponseBodyFormat::Xml | ResponseBodyFormat::Html => Some("html"),
                ResponseBodyFormat::Text => None,
                ResponseBodyFormat::Auto => {
                    let ct = r
                        .headers
                        .iter()
                        .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
                        .map(|(_, v)| v.to_ascii_lowercase())
                        .unwrap_or_default();
                    if ct.contains("json") {
                        Some("json")
                    } else if ct.contains("html") || ct.contains("xml") {
                        Some("html")
                    } else {
                        let b = pretty.trim_start();
                        if b.starts_with('{') || b.starts_with('[') {
                            Some("json")
                        } else if b.starts_with('<') {
                            Some("html")
                        } else {
                            None
                        }
                    }
                }
            };
            // Per-line tree-sitter spans. Empty when no highlighter
            // was picked — body renders in the plain body_style then.
            let json_spans: Vec<Vec<crate::highlight::ColoredSpan>> = match highlight_lang {
                Some(lang) => crate::highlight::highlight_lines(&pretty, lang),
                None => Vec::new(),
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
