//! The browser pane (`Pane::Browser`) — a Chrome driven over CDP: a header with
//! the current URL + either a scrollable log of console output / navigations /
//! `eval` results (colour-coded by kind) or — when the `n` network panel is on —
//! a selectable list of the captured requests. Read-only render; keys (`g`
//! navigate, `e` eval, `r` reload, `n` toggle the panel, `y` copy-as-curl, Enter
//! → re-send, scroll, Esc → tree) are wired in `tui.rs`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::browser_pane::LogKind;
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
    let t = theme::cur();
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.editor_panes.push((area, pane_id));
    // Detach `list_rows` so each panel branch below can push interactive
    // row rects (network / DOM / cookies / storage) while still holding a
    // mutable borrow on `app.panes` via `b`. The Vec is owned locally
    // throughout the function body and put back before every return point.
    let mut list_rows = std::mem::take(&mut app.rects.list_rows);

    let Some(Pane::Browser(b)) = app.panes.get_mut(pane_id) else {
        app.rects.list_rows = list_rows;
        return None;
    };

    let mut lines: Vec<Line> = Vec::new();
    // ── header ─────────────────────────────────────────────────────
    let url = if b.url.trim().is_empty() {
        "about:blank"
    } else {
        b.url.trim()
    };
    let target_chip = if b.targets.len() > 1 {
        format!("   [target: {} · T to switch]", b.current_target_label())
    } else {
        String::new()
    };
    let device_chip = match b
        .current_device
        .and_then(|i| crate::browser_pane::DEVICE_PRESETS.get(i))
    {
        Some(p) => format!("   [📱 {} · {}×{}]", p.label, p.width, p.height),
        None => String::new(),
    };
    lines.push(Line::from(vec![
        Span::styled("  ", Style::default().bg(t.bg_dark)),
        Span::styled(
            if b.closed { "● " } else { "◉ " },
            Style::default()
                .fg(if b.closed { t.comment } else { t.green })
                .bg(t.bg_dark),
        ),
        Span::styled(
            url.to_string(),
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(target_chip, Style::default().fg(t.yellow).bg(t.bg_dark)),
        Span::styled(device_chip, Style::default().fg(t.purple).bg(t.bg_dark)),
        Span::styled(
            if b.closed { "   (session ended)" } else { "" },
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
    ]));
    let hint = if b.dom_focus {
        if b.dom_filter_mode {
            format!(
                "  DOM filter: {}_ · Backspace deletes · Enter applies · Esc clears",
                b.dom_filter
            )
        } else if !b.dom_filter.is_empty() {
            format!(
                "  DOM ({}/{}) · / filter · ↑↓ select · h highlight · Z scroll · S screenshot · esc clear",
                b.visible_dom_indices().len(),
                b.dom.len()
            )
        } else {
            format!(
                "  DOM ({}) · / filter · h highlight · Z scroll · S shot · c copy · R re-fetch · esc back",
                b.dom.len()
            )
        }
    } else if b.cookies_focus {
        if b.cookies_filter_mode {
            format!(
                "  cookies filter: {}_ · Backspace deletes · Enter applies · Esc clears",
                b.cookies_filter
            )
        } else if !b.cookies_filter.is_empty() {
            format!(
                "  cookies ({}/{}) · / filter · y copy · e edit · a add · d delete · esc clear",
                b.visible_cookies_indices().len(),
                b.cookies.len()
            )
        } else {
            format!(
                "  cookies ({}) · / filter · y copy · e edit · a add · d delete · R re-fetch · esc back",
                b.cookies.len()
            )
        }
    } else if b.storage_focus {
        if b.storage_filter_mode {
            format!(
                "  storage filter: {}_ · Backspace deletes · Enter applies · Esc clears",
                b.storage_filter
            )
        } else if !b.storage_filter.is_empty() {
            format!(
                "  storage ({}/{}) · / filter · y copy · e edit · a add · d delete · esc clear",
                b.visible_storage_indices().len(),
                b.storage.len()
            )
        } else {
            format!(
                "  storage ({}) · / filter · y copy · e edit · a add · d delete · R re-fetch · esc back",
                b.storage.len()
            )
        }
    } else if b.perf_focus {
        "  performance · R re-fetch · esc back".to_string()
    } else if b.net_focus {
        if b.net_filter_mode {
            format!(
                "  network filter: {}_ · Backspace deletes · Enter applies · Esc clears",
                b.net_filter
            )
        } else if !b.net_filter.is_empty() {
            format!(
                "  network ({}/{}) · / filter · ↑↓ select · y curl · enter re-send · esc clear",
                b.visible_net_indices().len(),
                b.net.len()
            )
        } else {
            format!(
                "  network ({}) · / filter · ↑↓ select · y curl · enter re-send · n logs · esc back",
                b.net.len()
            )
        }
    } else if b.snapshot_diff_open {
        format!(
            "  diff (snap {})  ↑↓/PgUp/PgDn scroll · x close · esc back",
            b.snapshots.last().map(|s| s.label.as_str()).unwrap_or("?")
        )
    } else {
        "  g nav · ^R hist · e eval · r reload · s shot · n net · D DOM · K cookies · L storage · P perf · esc → tree"
            .to_string()
    };
    lines.push(Line::from(Span::styled(
        hint,
        Style::default().fg(t.comment).bg(t.bg_dark),
    )));
    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));
    let header_rows = lines.len();
    let h = area.height as usize;
    let body_rows = h.saturating_sub(header_rows);

    if b.dom_focus {
        // ── DOM panel: one selectable row per parsed node, indent = depth ──
        let visible = b.visible_dom_indices();
        if b.dom.is_empty() {
            lines.push(Line::from(Span::styled(
                if b.pending_dom.is_some() {
                    "  fetching DOM…"
                } else {
                    "  (no DOM loaded yet — R re-fetches)"
                },
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else if visible.is_empty() {
            lines.push(Line::from(Span::styled(
                format!("  (no matches for '{}')", b.dom_filter),
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else {
            let sel = b.dom_sel.min(visible.len() - 1);
            let first = if body_rows == 0 || sel < body_rows {
                0
            } else {
                sel + 1 - body_rows
            };
            for (row_idx, &raw_idx) in visible.iter().enumerate().skip(first).take(body_rows) {
                let Some(row) = b.dom.get(raw_idx) else {
                    continue;
                };
                let on = row_idx == sel;
                let row_bg = if on { t.bg2 } else { t.bg_dark };
                let marker = if on { "▶ " } else { "  " };
                // Two spaces per depth level, capped so very deep trees don't run off.
                let indent = "  ".repeat(row.depth.min(20));
                let color = if row.label.starts_with('<') && !row.label.starts_with("<!") {
                    t.blue
                } else if row.label.starts_with('“') {
                    t.fg
                } else {
                    t.comment
                };
                let y_off = lines.len() as u16;
                list_rows.push((
                    Rect {
                        x: area.x,
                        y: area.y + y_off,
                        width: area.width,
                        height: 1,
                    },
                    pane_id,
                    row_idx,
                ));
                lines.push(Line::from(vec![
                    Span::styled(marker, Style::default().fg(t.cyan).bg(row_bg)),
                    Span::styled(indent, Style::default().bg(row_bg)),
                    Span::styled(row.label.clone(), Style::default().fg(color).bg(row_bg)),
                ]));
            }
        }
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        app.rects.list_rows = list_rows;
        return None;
    }

    if b.cookies_focus {
        // ── cookies panel: one selectable row per cookie ───────────
        let visible = b.visible_cookies_indices();
        if b.cookies.is_empty() {
            lines.push(Line::from(Span::styled(
                if b.pending_cookies.is_some() {
                    "  fetching cookies…"
                } else {
                    "  (no cookies for this page — R re-fetches)"
                },
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else if visible.is_empty() {
            lines.push(Line::from(Span::styled(
                format!("  (no matches for '{}')", b.cookies_filter),
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else {
            let sel = b.cookies_sel.min(visible.len() - 1);
            let first = if body_rows == 0 || sel < body_rows {
                0
            } else {
                sel + 1 - body_rows
            };
            for (row_idx, &raw_idx) in visible.iter().enumerate().skip(first).take(body_rows) {
                let c = match b.cookies.get(raw_idx) {
                    Some(c) => c,
                    None => continue,
                };
                let idx = row_idx;
                let on = idx == sel;
                let row_bg = if on { t.bg2 } else { t.bg_dark };
                let marker = if on { "▶ " } else { "  " };
                let y_off = lines.len() as u16;
                list_rows.push((
                    Rect {
                        x: area.x,
                        y: area.y + y_off,
                        width: area.width,
                        height: 1,
                    },
                    pane_id,
                    idx,
                ));
                // Flags chip: S = Secure (green), H = HttpOnly (yellow).
                // Both shown when set; trailing space pads non-set so the
                // value-column alignment is stable.
                let s_chip = if c.secure { "S" } else { "·" };
                let h_chip = if c.http_only { "H" } else { "·" };
                let s_color = if c.secure { t.green } else { t.comment };
                let h_color = if c.http_only { t.yellow } else { t.comment };
                // Truncate the value so a long token doesn't blow the row.
                let value: String = c.value.chars().take(40).collect();
                let value = if value.chars().count() < c.value.chars().count() {
                    format!("{value}…")
                } else {
                    value
                };
                let expires = if c.expires <= 0 {
                    "session".to_string()
                } else {
                    // Coarse humanized age vs now. Avoids dragging in chrono.
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    let secs = c.expires - now;
                    if secs <= 0 {
                        "expired".to_string()
                    } else if secs < 60 {
                        format!("{secs}s")
                    } else if secs < 3600 {
                        format!("{}m", secs / 60)
                    } else if secs < 86_400 {
                        format!("{}h", secs / 3600)
                    } else {
                        format!("{}d", secs / 86_400)
                    }
                };
                let same_site = if c.same_site.is_empty() {
                    String::new()
                } else {
                    format!(" {}", c.same_site)
                };
                lines.push(Line::from(vec![
                    Span::styled(marker, Style::default().fg(t.cyan).bg(row_bg)),
                    Span::styled(
                        format!("[{s_chip}"),
                        Style::default().fg(s_color).bg(row_bg),
                    ),
                    Span::styled(h_chip, Style::default().fg(h_color).bg(row_bg)),
                    Span::styled("] ", Style::default().fg(t.comment).bg(row_bg)),
                    Span::styled(c.name.clone(), Style::default().fg(t.cyan).bg(row_bg)),
                    Span::styled("=", Style::default().fg(t.comment).bg(row_bg)),
                    Span::styled(value, Style::default().fg(t.fg).bg(row_bg)),
                    Span::styled("  ", Style::default().bg(row_bg)),
                    Span::styled(c.domain.clone(), Style::default().fg(t.purple).bg(row_bg)),
                    Span::styled(c.path.clone(), Style::default().fg(t.comment).bg(row_bg)),
                    Span::styled(
                        format!("  {expires}{same_site}"),
                        Style::default().fg(t.comment).bg(row_bg),
                    ),
                ]));
            }
        }
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        app.rects.list_rows = list_rows;
        return None;
    }

    if b.perf_focus {
        // ── performance panel: a fixed list of timings, color-coded ──
        let m = &b.perf;
        let fmt = |v: Option<f64>| match v {
            Some(n) if n < 1000.0 => format!("{:.0} ms", n),
            Some(n) => format!("{:.2} s", n / 1000.0),
            None => "—".to_string(),
        };
        // Core Web Vitals thresholds (Google): LCP < 2.5s = green,
        // < 4s = yellow, ≥ 4s = red. Used for FCP + LCP coloring.
        let vital_color = |v: Option<f64>, good: f64, poor: f64| -> ratatui::style::Color {
            match v {
                Some(n) if n < good => t.green,
                Some(n) if n < poor => t.yellow,
                Some(_) => t.red,
                None => t.comment,
            }
        };
        let row = |label: &str, v: Option<f64>, color: ratatui::style::Color| -> Line<'static> {
            Line::from(vec![
                Span::styled("  ", Style::default().bg(t.bg_dark)),
                Span::styled(
                    format!("{label:<18}"),
                    Style::default().fg(t.comment).bg(t.bg_dark),
                ),
                Span::styled(fmt(v), Style::default().fg(color).bg(t.bg_dark)),
            ])
        };
        if b.pending_perf.is_some() && *m == crate::browser_pane::PerfMetrics::default() {
            lines.push(Line::from(Span::styled(
                "  fetching performance metrics…",
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else {
            lines.push(row("DNS lookup", m.dns, t.fg));
            lines.push(row("TCP connect", m.tcp, t.fg));
            lines.push(row("TTFB", m.ttfb, vital_color(m.ttfb, 800.0, 1800.0)));
            lines.push(row("Response", m.response, t.fg));
            lines.push(row("DOM interactive", m.dom_interactive, t.fg));
            lines.push(row("Load event", m.load, t.fg));
            lines.push(Line::from(Span::styled("", Style::default().bg(t.bg_dark))));
            lines.push(row(
                "First contentful paint",
                m.fcp,
                vital_color(m.fcp, 1800.0, 3000.0),
            ));
            lines.push(row(
                "Largest contentful paint",
                m.lcp,
                vital_color(m.lcp, 2500.0, 4000.0),
            ));
        }
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        app.rects.list_rows = list_rows;
        return None;
    }

    if b.storage_focus {
        // ── Web Storage panel: one row per localStorage / sessionStorage entry ──
        let visible = b.visible_storage_indices();
        if b.storage.is_empty() {
            lines.push(Line::from(Span::styled(
                if b.pending_storage.is_some() {
                    "  fetching localStorage / sessionStorage…"
                } else {
                    "  (no Web Storage entries for this page — R re-fetches)"
                },
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else if visible.is_empty() {
            lines.push(Line::from(Span::styled(
                format!("  (no matches for '{}')", b.storage_filter),
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else {
            let sel = b.storage_sel.min(visible.len() - 1);
            let first = if body_rows == 0 || sel < body_rows {
                0
            } else {
                sel + 1 - body_rows
            };
            for (row_idx, &raw_idx) in visible.iter().enumerate().skip(first).take(body_rows) {
                let e = match b.storage.get(raw_idx) {
                    Some(e) => e,
                    None => continue,
                };
                let idx = row_idx;
                let on = idx == sel;
                let row_bg = if on { t.bg2 } else { t.bg_dark };
                let marker = if on { "▶ " } else { "  " };
                // Chip: `[L]` for localStorage (purple), `[S]` for
                // sessionStorage (yellow). Both fixed-width so columns
                // align across heterogeneous lists.
                let (chip, chip_color) = if e.is_local {
                    ("[L] ", t.purple)
                } else {
                    ("[S] ", t.yellow)
                };
                // Truncate the value column so a JWT-sized entry doesn't
                // blow the row apart.
                let value: String = e.value.chars().take(60).collect();
                let value = if value.chars().count() < e.value.chars().count() {
                    format!("{value}…")
                } else {
                    value
                };
                let y_off = lines.len() as u16;
                list_rows.push((
                    Rect {
                        x: area.x,
                        y: area.y + y_off,
                        width: area.width,
                        height: 1,
                    },
                    pane_id,
                    idx,
                ));
                lines.push(Line::from(vec![
                    Span::styled(marker, Style::default().fg(t.cyan).bg(row_bg)),
                    Span::styled(chip, Style::default().fg(chip_color).bg(row_bg)),
                    Span::styled(e.key.clone(), Style::default().fg(t.cyan).bg(row_bg)),
                    Span::styled("=", Style::default().fg(t.comment).bg(row_bg)),
                    Span::styled(value, Style::default().fg(t.fg).bg(row_bg)),
                ]));
            }
        }
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        app.rects.list_rows = list_rows;
        return None;
    }

    if b.net_focus {
        // ── network panel: one selectable row per captured request ─────
        // When `net_detail_open`, split the area in two: list on top,
        // a per-request detail (full headers + body + response status)
        // on the bottom. The detail tracks the selected row.
        let (list_area, detail_area) = if b.net_detail_open {
            let lh = area.height / 2;
            let dh = area.height.saturating_sub(lh);
            (
                Rect {
                    x: area.x,
                    y: area.y,
                    width: area.width,
                    height: lh,
                },
                Some(Rect {
                    x: area.x,
                    y: area.y + lh,
                    width: area.width,
                    height: dh,
                }),
            )
        } else {
            (area, None)
        };
        let list_body_rows = list_area.height.saturating_sub(1) as usize;
        let visible = b.visible_net_indices();
        if b.net.is_empty() {
            lines.push(Line::from(Span::styled(
                "  (no network requests captured yet — Document / XHR / Fetch only)",
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else if visible.is_empty() {
            lines.push(Line::from(Span::styled(
                format!("  (no matches for '{}')", b.net_filter),
                Style::default().fg(t.comment).bg(t.bg_dark),
            )));
        } else {
            let sel = b.net_sel.min(visible.len() - 1);
            // Keep the selected row inside the viewport.
            let first = if list_body_rows == 0 || sel < list_body_rows {
                0
            } else {
                sel + 1 - list_body_rows
            };
            for (row_idx, &raw_idx) in visible.iter().enumerate().skip(first).take(list_body_rows) {
                let Some(e) = b.net.get(raw_idx) else {
                    continue;
                };
                let on = row_idx == sel;
                let row_bg = if on { t.bg2 } else { t.bg_dark };
                let y_off = lines.len() as u16;
                list_rows.push((
                    Rect {
                        x: list_area.x,
                        y: list_area.y + y_off,
                        width: list_area.width,
                        height: 1,
                    },
                    pane_id,
                    row_idx,
                ));
                let status = e.status_text();
                let status_color = if e.failed.is_some() {
                    t.red
                } else {
                    match e.status {
                        Some(s) if (200..300).contains(&s) => t.green,
                        Some(s) if (300..400).contains(&s) => t.yellow,
                        Some(s) if s >= 400 => t.red,
                        Some(_) => t.fg,
                        None => t.comment,
                    }
                };
                let marker = if on { "▶ " } else { "  " };
                let mut spans = vec![
                    Span::styled(marker, Style::default().fg(t.cyan).bg(row_bg)),
                    Span::styled(
                        format!("{:<6}", e.method),
                        Style::default().fg(t.blue).bg(row_bg),
                    ),
                    Span::styled(
                        format!("{:>4} ", status),
                        Style::default().fg(status_color).bg(row_bg),
                    ),
                    Span::styled(e.short_url(), Style::default().fg(t.fg).bg(row_bg)),
                ];
                if let Some(m) = &e.mime
                    && !m.is_empty()
                {
                    spans.push(Span::styled(
                        format!("  [{m}]"),
                        Style::default().fg(t.comment).bg(row_bg),
                    ));
                }
                lines.push(Line::from(spans));
            }
        }
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            list_area,
        );
        if let Some(detail) = detail_area
            && detail.height > 0
        {
            let sel_entry = b.selected_net();
            let mut det_lines: Vec<Line> = Vec::new();
            // Title with hint chip — make it clear `i` toggles back.
            det_lines.push(Line::from(Span::styled(
                " request detail  (i to close · [/] to scroll) ",
                Style::default()
                    .fg(t.bg_dark)
                    .bg(t.cyan)
                    .add_modifier(Modifier::BOLD),
            )));
            if let Some(e) = sel_entry {
                let raw = e.detail_lines();
                let body_rows = detail.height.saturating_sub(1) as usize;
                let start = b.net_detail_scroll.min(raw.len().saturating_sub(1));
                for line in raw.iter().skip(start).take(body_rows) {
                    let style = if line.starts_with('>') {
                        Style::default().fg(t.fg).bg(t.bg_dark)
                    } else if line.starts_with('<') {
                        Style::default().fg(t.green).bg(t.bg_dark)
                    } else {
                        Style::default().fg(t.comment).bg(t.bg_dark)
                    };
                    det_lines.push(Line::from(Span::styled(line.clone(), style)));
                }
            } else {
                det_lines.push(Line::from(Span::styled(
                    "  (no row selected)",
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )));
            }
            frame.render_widget(
                Paragraph::new(det_lines).style(Style::default().bg(t.bg_dark)),
                detail,
            );
        }
        app.rects.list_rows = list_rows;
        return None;
    }

    // ── snapshot diff panel: replaces the log when toggled on ───────
    if b.snapshot_diff_open {
        let diff = b.diff_against_latest_snapshot();
        match diff {
            None => {
                lines.push(Line::from(Span::styled(
                    "  (no snapshot to diff against — capture one with browser.snapshot)",
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )));
            }
            Some(rows) if rows.is_empty() => {
                lines.push(Line::from(Span::styled(
                    "  (no changes since last snapshot)",
                    Style::default().fg(t.comment).bg(t.bg_dark),
                )));
            }
            Some(rows) => {
                let max_w = area.width.saturating_sub(1) as usize;
                let start = b.snapshot_diff_scroll.min(rows.len().saturating_sub(1));
                for row in rows.iter().skip(start).take(body_rows) {
                    let (prefix, color) = match row.kind {
                        crate::browser_pane::DiffLineKind::Section => ("── ", t.fg),
                        crate::browser_pane::DiffLineKind::Removed => ("- ", t.red),
                        crate::browser_pane::DiffLineKind::Added => ("+ ", t.green),
                        crate::browser_pane::DiffLineKind::Changed => ("~ ", t.yellow),
                    };
                    let mut text = format!("{prefix}{}", row.text);
                    if text.chars().count() > max_w {
                        text = text
                            .chars()
                            .take(max_w.saturating_sub(1))
                            .collect::<String>()
                            + "…";
                    }
                    let style = match row.kind {
                        crate::browser_pane::DiffLineKind::Section => Style::default()
                            .fg(color)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::BOLD),
                        _ => Style::default().fg(color).bg(t.bg_dark),
                    };
                    lines.push(Line::from(Span::styled(text, style)));
                }
            }
        }
        frame.render_widget(
            Paragraph::new(lines).style(Style::default().bg(t.bg_dark)),
            area,
        );
        app.rects.list_rows = list_rows;
        return None;
    }

    // ── log (the line text carries its own marker — `→`, `←`, `»`, `= ` — so the
    // kind only drives colour, not a prefix glyph) ─────────────────
    for l in &b.log {
        let color = match l.kind {
            LogKind::System => t.comment,
            LogKind::Console => t.fg,
            LogKind::ConsoleErr => t.red,
            LogKind::Nav => t.blue,
            LogKind::Net => t.teal,
            LogKind::Eval => t.green,
        };
        lines.push(Line::from(vec![
            Span::styled("    ", Style::default().bg(t.bg_dark)),
            Span::styled(l.text.clone(), Style::default().fg(color).bg(t.bg_dark)),
        ]));
    }
    if b.log.is_empty() {
        lines.push(Line::from(Span::styled(
            "  (no console output yet)",
            Style::default().fg(t.comment).bg(t.bg_dark),
        )));
    }

    // ── scroll (follow the tail when pinned) ───────────────────────
    let max_scroll = lines.len().saturating_sub(h.min(lines.len()));
    if b.scroll >= max_scroll {
        b.scroll = max_scroll;
    }
    let view: Vec<Line> = lines.into_iter().skip(b.scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(view).style(Style::default().bg(t.bg_dark)),
        area,
    );
    app.rects.list_rows = list_rows;
    None
}
