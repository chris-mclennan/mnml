//! `Pane::ClaudeUsage` renderer — the full Claude usage panel, ported
//! from the retired centered-modal overlay into a proper pane.
//! Shows the same content: session %, weekly %, per-model scoped
//! limits, resets, retry-after status, last error.
//!
//! Data source is `App::ai_usage_claude_accounts` (populated by
//! the per-account fetchers that also feed the statusline chip).
//! Task #944 (2026-08-16) — one titled section per configured
//! account, stacked vertically. Header advertises the `r refresh
//! · esc close` hints; the actual key handler lives in
//! `src/tui/handlers/pane.rs`.
//!
//! 2026-08-16 — this file was `ai_usage_view.rs` before the
//! `Pane::AiUsage` → `Pane::ClaudeUsage`/`Pane::CodexUsage` split;
//! the Codex-side renderer lives in `codex_usage_view.rs`.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::layout::PaneId;
use crate::ui::theme;
use crate::ui::usage_time::{format_long_time, format_short_time};

/// Bar width in cells. Was hard-coded to 60 in the overlay; here we
/// clamp to the available body width minus the `" N% used"` suffix
/// so a narrow pane still renders a bar rather than clipping off.
const MAX_BAR_WIDTH: u16 = 60;
const SUFFIX_CELLS: u16 = 10; // ` 100% used` = 10 cells

pub fn draw(frame: &mut Frame, app: &mut App, pid: PaneId, area: Rect, focused: bool) {
    if area.width == 0 || area.height == 0 {
        app.rects.claude_usage_pencils.clear();
        return;
    }
    let t = theme::cur();
    // Task #944 rename UX (2026-08-16) — clear + repopulate pencil
    // hitrects for the mouse handler. Same pattern as the other
    // per-render rect vecs (help_section_headers, request_vars_rows).
    app.rects.claude_usage_pencils.clear();

    // Header row inside the pane body — mirrors the "Esc to dismiss"
    // affordance the overlay had, adjusted for the pane world where
    // Esc focuses the tree and `r` refreshes.
    let header_color = if focused { t.fg } else { t.comment };
    let mut rows: Vec<Line<'static>> = vec![
        Line::from(vec![
            Span::styled(
                " Claude usage ".to_string(),
                Style::default()
                    .fg(header_color)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(
                "· r refresh · esc close".to_string(),
                Style::default()
                    .fg(t.comment)
                    .add_modifier(Modifier::ITALIC),
            ),
        ]),
        Line::from(""),
    ];

    let bar_w = area
        .width
        .saturating_sub(SUFFIX_CELLS + 2)
        .min(MAX_BAR_WIDTH);

    // Task #944 (2026-08-16) — one titled section per configured
    // account. Sections are `── personal (active) ──` style; each
    // shows Session + Weekly + scoped limits + retry-after + errors
    // for that account, identical to the pre-multi-account render
    // (which was implicitly a single-account view).
    let accounts = app.ai_usage_claude_accounts.clone();
    // #1049 (2026-08-20) — resolve active-account name fresh from
    // config every render. Each `ClaudeAccountUsage.is_active` was
    // stamped when its last fetch drained; a mid-session switch
    // (config edit or `:ai.set_active_claude_account`) leaves those
    // flags stale for up to the poll interval (~5 min). Reading
    // config here means the `(active)` tail label always tracks the
    // *current* selection.
    let active_name_now: Option<String> = app
        .config
        .claude_accounts()
        .into_iter()
        .find(|a| a.active)
        .map(|a| a.name);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Task #944 rename UX (2026-08-16) — record per-section
    // header info (row_index_within_rows, x_offset_of_pencil,
    // account_name) so the mouse hitrect can be computed once we
    // know the final scroll offset. Left-clean at empty state.
    let mut pencil_meta: Vec<(usize, u16, String)> = Vec::new();
    if accounts.is_empty() {
        rows.push(Line::from(Span::styled(
            "fetching… (link a token via `:ai.link_claude_token`)".to_string(),
            Style::default().fg(t.comment),
        )));
    } else {
        for (i, account) in accounts.iter().enumerate() {
            let usage = &account.usage;
            // Header shape: `── <name> ✎ · <email> · <org> · (active) ──`.
            // Pencil is a discrete Span so we can pin the hitrect to
            // its cell. Email + org come from Anthropic's OAuth
            // `/api/oauth/profile` endpoint (best-effort populate on
            // each fetch — `None` when the endpoint returns 404 or
            // the token can't authenticate). When both `None` the
            // header collapses to just `── <name> ✎ · (active) ──`.
            let prefix = format!("── {} ", account.name);
            let prefix_cells = prefix.chars().count() as u16;
            let pencil = "\u{F040}"; // nf-fa-pencil — safer than F02EC across the Nerd Font builds we ship against
            // Build the identity middle-piece — `· email · org`,
            // any/all optional. Rendered in comment tone so it reads
            // as metadata not part of the header structure.
            let mut identity = String::new();
            if let Some(email) = account.email.as_deref() {
                identity.push_str(" · ");
                identity.push_str(email);
            }
            if let Some(org) = account.org_name.as_deref() {
                identity.push_str(" · ");
                identity.push_str(org);
            }
            let tail = if active_name_now.as_deref() == Some(account.name.as_str()) {
                " · (active) ──".to_string()
            } else {
                " ──".to_string()
            };
            let header_row_idx = rows.len();
            rows.push(Line::from(vec![
                Span::styled(
                    prefix,
                    Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
                ),
                // Pencil chip — subtly de-emphasized (comment tone
                // + no bold) so it reads as an affordance, not part
                // of the name. Hover-tinting would be nice; deferred
                // to a follow-up.
                Span::styled(pencil.to_string(), Style::default().fg(t.comment)),
                Span::styled(identity, Style::default().fg(t.comment)),
                Span::styled(tail, Style::default().fg(t.fg).add_modifier(Modifier::BOLD)),
            ]));
            pencil_meta.push((header_row_idx, prefix_cells, account.name.clone()));
            rows.push(Line::from(""));

            // Session
            rows.push(Line::from(Span::styled(
                "Current session".to_string(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            )));
            rows.push(bar_row(usage.percent, bar_w, &t));
            rows.push(reset_row(usage.resets_at, &t));
            rows.push(Line::from(""));

            // Weekly (all models)
            rows.push(Line::from(Span::styled(
                "Current week (all models)".to_string(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            )));
            rows.push(bar_row(usage.weekly_percent, bar_w, &t));
            rows.push(reset_row_weekly(usage.weekly_resets_at, &t));
            rows.push(Line::from(""));

            // Per-model scoped limits (e.g. Fable)
            for scoped in &usage.scoped_limits {
                rows.push(Line::from(Span::styled(
                    format!("Current week ({})", scoped.model_display_name),
                    Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
                )));
                rows.push(bar_row(scoped.percent, bar_w, &t));
                if scoped.resets_at > 0 {
                    rows.push(reset_row_weekly(scoped.resets_at, &t));
                }
                rows.push(Line::from(""));
            }

            // Retry-after — surfaced when Anthropic told THIS account
            // to back off.
            if usage.retry_after_at > now {
                let remaining = usage.retry_after_at - now;
                rows.push(Line::from(Span::styled(
                    format!("  Anthropic asked us to retry in {}s (429)", remaining),
                    Style::default().fg(t.yellow),
                )));
                rows.push(Line::from(""));
            }

            // Per-account empty state / stale-data hint
            if usage.percent == 0 && usage.weekly_percent == 0 && usage.scoped_limits.is_empty() {
                rows.push(Line::from(Span::styled(
                    match usage.last_error {
                        Some(ref e) => format!("no data yet · last error: {e}"),
                        None => "fetching…".to_string(),
                    },
                    Style::default().fg(t.comment),
                )));
            } else if let Some(ref e) = usage.last_error {
                rows.push(Line::from(Span::styled(
                    format!("  last fetch error: {e}"),
                    Style::default().fg(t.red),
                )));
            }

            // Blank separator between accounts (skip after the last)
            if i + 1 < accounts.len() {
                rows.push(Line::from(""));
            }
        }
    }

    // Footer hint
    rows.push(Line::from(""));
    rows.push(Line::from(Span::styled(
        " `:ai.refresh_usage` to force fetch · `:ai.show_last_response` for raw JSON ".to_string(),
        Style::default()
            .fg(t.comment)
            .add_modifier(Modifier::ITALIC),
    )));

    // Apply the pane's scroll offset. Clamp so `j` past the end
    // doesn't blank the pane.
    let total = rows.len();
    let visible = area.height as usize;
    let max_scroll = total.saturating_sub(visible.max(1));
    let scroll = if let Some(crate::pane::Pane::ClaudeUsage(p)) = app.panes.get_mut(pid) {
        p.scroll = p.scroll.min(max_scroll);
        p.scroll
    } else {
        0
    };

    // Populate pencil hitrects — one per section header that's on
    // screen after the scroll offset is applied. The pencil is a
    // 2-cell-wide clickable target (glyph + a 1-cell hover slop
    // so a slightly-off click still lands).
    for (row_idx, x_off, name) in pencil_meta {
        if row_idx < scroll {
            continue;
        }
        let visible_y = (row_idx - scroll) as u16;
        if visible_y >= area.height {
            continue;
        }
        // Clip against the pane's right edge — a narrow pane can
        // scroll the pencil off-screen; skip the rect entirely
        // rather than reporting an out-of-bounds hitrect.
        if x_off >= area.width {
            continue;
        }
        let pencil_x = area.x + x_off;
        let pencil_w = 2u16.min(area.width.saturating_sub(x_off));
        app.rects.claude_usage_pencils.push((
            Rect {
                x: pencil_x,
                y: area.y + visible_y,
                width: pencil_w,
                height: 1,
            },
            name,
        ));
    }

    let visible_rows: Vec<Line<'static>> = rows.into_iter().skip(scroll).collect();
    frame.render_widget(
        Paragraph::new(visible_rows).style(Style::default().fg(t.fg).bg(t.bg)),
        area,
    );
}

/// Progress bar row — full-width filled/empty frame + `N% used`
/// suffix. Color: green <60%, yellow 60-85%, red 85%+. The empty
/// portion uses a solid mid-tone background so the FRAME is always
/// visible even at 0% (overlay-era report 2026-08-05: 0% Fable
/// rendered as "nothing there").
fn bar_row(percent: u16, bar_w: u16, t: &crate::ui::theme::Theme) -> Line<'static> {
    let clamped = percent.min(100);
    let filled_w = ((bar_w as u32) * (clamped as u32) / 100) as u16;
    let empty_w = bar_w.saturating_sub(filled_w);
    let color = if percent >= 85 {
        t.red
    } else if percent >= 60 {
        t.yellow
    } else {
        t.purple
    };
    let filled: String = " ".repeat(filled_w as usize);
    let empty: String = " ".repeat(empty_w as usize);
    Line::from(vec![
        Span::styled(filled, Style::default().bg(color)),
        Span::styled(empty, Style::default().bg(t.bg2)),
        Span::styled(
            format!(" {}% used", percent),
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
        ),
    ])
}

fn reset_row(resets_at: u64, t: &crate::ui::theme::Theme) -> Line<'static> {
    if resets_at == 0 {
        return Line::from(Span::styled(
            "  (reset time not available)".to_string(),
            Style::default().fg(t.comment),
        ));
    }
    let short = format_short_time(resets_at);
    Line::from(Span::styled(
        format!("  Resets {short}"),
        Style::default().fg(t.comment),
    ))
}

fn reset_row_weekly(resets_at: u64, t: &crate::ui::theme::Theme) -> Line<'static> {
    if resets_at == 0 {
        return Line::from(Span::styled(
            "  (reset time not available)".to_string(),
            Style::default().fg(t.comment),
        ));
    }
    let full = format_long_time(resets_at);
    Line::from(Span::styled(
        format!("  Resets {full}"),
        Style::default().fg(t.comment),
    ))
}
