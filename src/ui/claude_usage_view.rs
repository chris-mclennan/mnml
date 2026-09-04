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
                "· r refresh · L claude login · R capture · esc close".to_string(),
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
    // #1150 f/u (2026-08-23) — autodetect from the live Claude Code
    // Keychain blob first (matches which account is CURRENTLY the
    // Claude Code CLI login). Falls back to the manual `active = true`
    // config flag when autodetect has no answer yet (Keychain worker
    // hasn't returned, non-macOS, no configured account matches).
    let active_name_now: Option<String> =
        app.autodetected_active_claude_account_name().or_else(|| {
            app.config
                .claude_accounts()
                .into_iter()
                .find(|a| a.active)
                .map(|a| a.name)
        });
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
            // #1103 f/u (2026-08-20) — active-account visual cues:
            //   (A) `(active)` tail becomes a green bold pill.
            //   (B) Left gutter accent bar (1 col `┃`) painted
            //       alongside every row in the account's block —
            //       green for active, dim for inactive. Together
            //       they answer "which one is active" at a glance
            //       and give clear vertical section boundaries.
            let is_active = active_name_now.as_deref() == Some(account.name.as_str());
            let gutter_style = if is_active {
                Style::default().fg(t.green).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(t.bg_darker)
            };
            // #1103 f/u2 (2026-08-20) — heavier accent bar. `▌` (left
            // half-block) renders as a solid pixel column vs the
            // narrow line `┃` gave us; feels like a proper design-
            // system gutter, not a text glyph.
            let gutter_span = || Span::styled(crate::ui::gutter::GLYPH, gutter_style);
            // Helper: wrap a Line so every row in this account's
            // block is prefixed with the gutter span. Consumes the
            // input Line's spans and re-emits them after the gutter.
            let with_gutter = |line: Line<'static>| -> Line<'static> {
                let mut spans: Vec<Span<'static>> = vec![gutter_span()];
                spans.extend(line.spans);
                Line::from(spans)
            };
            // #1103 f/u2 (2026-08-20) — dropped the `── … ──` decoration
            // (visual noise, not structure) and moved the `(active)`
            // pill to the LEFT (right after the gutter) so the green
            // gutter + green (active) pill sit adjacent — much
            // punchier signal than a far-right label. Header shape:
            //   active:   `▌ (active) <name> ✎ · <email> · <org>`
            //   inactive: `▌ <name> ✎ · <email> · <org>`
            let pencil = "\u{F040}"; // nf-fa-pencil
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
            let header_row_idx = rows.len();
            let mut header_spans: Vec<Span<'static>> = vec![gutter_span()];
            // Cumulative cell offset used to pin the pencil hitrect.
            // Starts at the gutter's width.
            //
            // 2026-09-03 — this was the literal 2, from when the gutter
            // was `▌ `. Making the gutter one cell (`ui::gutter`) left
            // the literal stale, so the ✎ painted one cell left of its
            // own click rect. Derive it so the two cannot drift again.
            let mut cursor_cells: u16 = crate::ui::gutter::WIDTH;
            if is_active {
                let pill = "(active) ";
                header_spans.push(Span::styled(
                    pill.to_string(),
                    Style::default().fg(t.green).add_modifier(Modifier::BOLD),
                ));
                cursor_cells += pill.chars().count() as u16;
            }
            let name = format!("{} ", account.name);
            let name_cells = name.chars().count() as u16;
            header_spans.push(Span::styled(
                name,
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            ));
            cursor_cells += name_cells;
            let prefix_cells = cursor_cells;
            header_spans.push(Span::styled(
                pencil.to_string(),
                Style::default().fg(t.comment),
            ));
            header_spans.push(Span::styled(identity, Style::default().fg(t.comment)));
            rows.push(Line::from(header_spans));
            pencil_meta.push((header_row_idx, prefix_cells, account.name.clone()));
            rows.push(with_gutter(Line::from("")));

            // Session
            rows.push(with_gutter(Line::from(Span::styled(
                "Current session".to_string(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            ))));
            rows.push(with_gutter(bar_row(usage.percent, bar_w, &t)));
            rows.push(with_gutter(reset_row(usage.resets_at, &t)));
            rows.push(with_gutter(Line::from("")));

            // Weekly (all models)
            rows.push(with_gutter(Line::from(Span::styled(
                "Current week (all models)".to_string(),
                Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
            ))));
            rows.push(with_gutter(bar_row(usage.weekly_percent, bar_w, &t)));
            rows.push(with_gutter(reset_row_weekly(usage.weekly_resets_at, &t)));
            rows.push(with_gutter(Line::from("")));

            // Per-model scoped limits (e.g. Fable)
            for scoped in &usage.scoped_limits {
                rows.push(with_gutter(Line::from(Span::styled(
                    format!("Current week ({})", scoped.model_display_name),
                    Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
                ))));
                rows.push(with_gutter(bar_row(scoped.percent, bar_w, &t)));
                if scoped.resets_at > 0 {
                    rows.push(with_gutter(reset_row_weekly(scoped.resets_at, &t)));
                }
                rows.push(with_gutter(Line::from("")));
            }

            // Retry-after — surfaced when Anthropic told THIS account
            // to back off.
            if usage.retry_after_at > now {
                let remaining = usage.retry_after_at - now;
                rows.push(with_gutter(Line::from(Span::styled(
                    format!("  Anthropic asked us to retry in {}s (429)", remaining),
                    Style::default().fg(t.yellow),
                ))));
                rows.push(with_gutter(Line::from("")));
            }

            // #1232 — an account whose token can't be repaired
            // automatically. The keychain holds ONE Claude login, so a
            // token that has expired for an account the CLI isn't
            // currently logged into as cannot be refreshed without the
            // user re-authing that account. Say so, and say what to
            // press — a bare "fetch error" here reads as a network
            // blip and leaves the user with no next move.
            // Typed, not sniffed out of the message text: rewording
            // the producer's string must not silently drop the user
            // back to the generic "last fetch error" line.
            let needs_reauth = usage.needs_reauth;
            if needs_reauth {
                rows.push(with_gutter(Line::from(Span::styled(
                    "  ⚠ token expired — needs re-auth".to_string(),
                    Style::default().fg(t.yellow),
                ))));
                rows.push(with_gutter(Line::from(Span::styled(
                    format!("    1. press L to run `claude login` (as {})", account.name),
                    Style::default().fg(t.comment),
                ))));
                rows.push(with_gutter(Line::from(Span::styled(
                    "    2. press R to capture it from the keychain".to_string(),
                    Style::default().fg(t.comment),
                ))));
                // The detail carries WHICH account the loaded
                // credential actually is, which is the whole reason
                // the write was refused.
                if let Some(why) = usage.last_error.as_deref() {
                    rows.push(with_gutter(Line::from(Span::styled(
                        format!("    {why}"),
                        Style::default().fg(t.comment),
                    ))));
                }
                rows.push(with_gutter(Line::from("")));
            }

            // Per-account empty state / stale-data hint
            if needs_reauth {
                // Already explained above — don't repeat the raw error.
            } else if usage.percent == 0
                && usage.weekly_percent == 0
                && usage.scoped_limits.is_empty()
            {
                rows.push(with_gutter(Line::from(Span::styled(
                    match usage.last_error {
                        Some(ref e) => format!("no data yet · last error: {e}"),
                        None => "fetching…".to_string(),
                    },
                    Style::default().fg(t.comment),
                ))));
            } else if let Some(ref e) = usage.last_error {
                rows.push(with_gutter(Line::from(Span::styled(
                    format!("  last fetch error: {e}"),
                    Style::default().fg(t.red),
                ))));
            }

            // Blank separator between accounts (skip after the last).
            // Bare Line (no gutter) so the gap reads cleanly between
            // one account's gutter and the next.
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
