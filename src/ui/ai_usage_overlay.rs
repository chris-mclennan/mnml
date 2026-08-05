//! `:ai.usage` overlay — centered floating panel that mirrors what
//! Claude Code's `/usage` slash command shows. Progress bars for
//! session (5h) + weekly + any per-model scoped limits. Data comes
//! from the API fetch that also feeds the statusline chip.
//!
//! Sibling to `about_overlay` / `welcome_overlay`. Dismiss: Esc /
//! `:ai.usage` (toggles) / click outside.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::ui::theme;

const BAR_WIDTH: u16 = 60;

pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    // Two paths: pinned (`:ai.usage` toggled) or hovering the
    // statusline chip. Hover state is transient — moving the mouse
    // off the chip clears app.hover_chip which un-renders us next
    // frame. Pinned persists until Esc / `:ai.usage` again.
    let hovering = matches!(
        app.hover_chip,
        Some((crate::HoverChip::StatuslineAiClaude, _))
    );
    if !app.show_ai_usage && !hovering {
        return;
    }
    let t = theme::cur();
    let usage = app.ai_usage_claude.clone().unwrap_or_default();
    let mut rows: Vec<Line<'static>> = vec![
        Line::from(Span::styled(
            " Claude usage · Esc to dismiss ".to_string(),
            Style::default()
                .fg(t.comment)
                .add_modifier(Modifier::ITALIC),
        )),
        Line::from(""),
    ];

    // Session section
    rows.push(Line::from(Span::styled(
        "Current session".to_string(),
        Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
    )));
    rows.push(bar_row(usage.percent, &t));
    rows.push(reset_row(usage.resets_at, &t));
    rows.push(Line::from(""));

    // Weekly section (all models)
    rows.push(Line::from(Span::styled(
        "Current week (all models)".to_string(),
        Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
    )));
    rows.push(bar_row(usage.weekly_percent, &t));
    rows.push(reset_row_weekly(usage.weekly_resets_at, &t));
    rows.push(Line::from(""));

    // Per-model scoped limits (e.g. Fable)
    for scoped in &usage.scoped_limits {
        rows.push(Line::from(Span::styled(
            format!("Current week ({})", scoped.model_display_name),
            Style::default().fg(t.fg).add_modifier(Modifier::BOLD),
        )));
        rows.push(bar_row(scoped.percent, &t));
        if scoped.resets_at > 0 {
            rows.push(reset_row_weekly(scoped.resets_at, &t));
        }
        rows.push(Line::from(""));
    }

    // Empty state — if no data yet, tell the user
    if usage.percent == 0 && usage.weekly_percent == 0 && usage.scoped_limits.is_empty() {
        rows.push(Line::from(Span::styled(
            match usage.last_error {
                Some(ref e) => format!("no data yet · last error: {e}"),
                None => "fetching… (link a token via `:ai.link_claude_token`)".to_string(),
            },
            Style::default().fg(t.comment),
        )));
    }

    // Footer hint
    rows.push(Line::from(Span::styled(
        " `:ai.refresh_usage` to force fetch · `:ai.show_last_response` for raw JSON ".to_string(),
        Style::default()
            .fg(t.comment)
            .add_modifier(Modifier::ITALIC),
    )));

    let title = " Usage ";
    let inner_w = (BAR_WIDTH as usize) + 12;
    let w = (inner_w as u16 + 4).min(screen.width);
    let h = (rows.len() as u16 + 2).min(screen.height);
    let x = screen
        .x
        .saturating_add((screen.width.saturating_sub(w)) / 2);
    let y = screen
        .y
        .saturating_add((screen.height.saturating_sub(h)) / 3);
    let area = Rect {
        x,
        y,
        width: w,
        height: h,
    };
    frame.render_widget(Clear, area);
    let block = crate::ui::design_tokens::modal_panel(title);
    frame.render_widget(Paragraph::new(rows).block(block), area);
}

/// Progress bar row — full-width filled/empty frame + `N% used`
/// suffix. Color: green <60%, yellow 60-85%, red 85%+. The empty
/// portion uses a solid mid-tone background so the FRAME is always
/// visible even at 0% (user report 2026-08-05: 0% Fable rendered
/// as "nothing there").
fn bar_row(percent: u16, t: &crate::ui::theme::Theme) -> Line<'static> {
    let clamped = percent.min(100);
    let filled_w = ((BAR_WIDTH as u32) * (clamped as u32) / 100) as u16;
    let empty_w = BAR_WIDTH.saturating_sub(filled_w);
    let color = if percent >= 85 {
        t.red
    } else if percent >= 60 {
        t.yellow
    } else {
        t.purple
    };
    // Filled: solid background block. Empty: spaces on a slightly
    // darker background so the whole bar reads as one framed rect.
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

/// `6:50pm` shape — for session resets (same day).
fn format_short_time(unix_secs: u64) -> String {
    // Approximate local time by adding the TZ offset. Fall back to
    // UTC if offset can't be resolved.
    let (h, m) = split_hm(unix_secs);
    let (h12, ampm) = if h == 0 {
        (12, "am")
    } else if h < 12 {
        (h, "am")
    } else if h == 12 {
        (12, "pm")
    } else {
        (h - 12, "pm")
    };
    if m == 0 {
        format!("{h12}{ampm}")
    } else {
        format!("{h12}:{m:02}{ampm}")
    }
}

/// `Aug 10 at 2am` shape — for weekly resets (different day).
fn format_long_time(unix_secs: u64) -> String {
    let (h, m) = split_hm(unix_secs);
    let (_y, mo, d) = split_ymd(unix_secs);
    let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let month = months
        .get((mo as usize).saturating_sub(1))
        .copied()
        .unwrap_or("?");
    let (h12, ampm) = if h == 0 {
        (12, "am")
    } else if h < 12 {
        (h, "am")
    } else if h == 12 {
        (12, "pm")
    } else {
        (h - 12, "pm")
    };
    let time = if m == 0 {
        format!("{h12}{ampm}")
    } else {
        format!("{h12}:{m:02}{ampm}")
    };
    format!("{month} {d} at {time}")
}

/// Approximate local hour/minute from unix seconds using $TZ (or 0
/// if not set). Good enough for a reset-time label.
fn split_hm(unix_secs: u64) -> (u64, u64) {
    let offset = local_tz_offset_secs();
    let local = (unix_secs as i64 + offset).max(0) as u64;
    let total_mins = (local / 60) % (24 * 60);
    (total_mins / 60, total_mins % 60)
}

fn split_ymd(unix_secs: u64) -> (i32, u32, u32) {
    let offset = local_tz_offset_secs();
    let local = (unix_secs as i64 + offset).max(0) as u64;
    let days = (local / 86400) as i64;
    day_to_ymd(days)
}

fn day_to_ymd(days: i64) -> (i32, u32, u32) {
    let mut d = days + 719_162;
    let mut y: i32 = 400 * (d as i32 / 146_097);
    d %= 146_097;
    if d == 146_096 {
        y += 400;
        d = 0;
    }
    let (mut yi, mut di) = (y as i64, d);
    let c = (di / 36524).min(3);
    di -= c * 36524;
    yi += c * 100;
    let f = di / 1461;
    di -= f * 1461;
    yi += f * 4;
    let g = (di / 365).min(3);
    di -= g * 365;
    yi += g;
    let leap = (yi % 4 == 0) && (yi % 100 != 0 || yi % 400 == 0);
    let dpm = if leap {
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    } else {
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    };
    let mut m: u32 = 1;
    let mut rem = di as u32;
    for &v in dpm.iter() {
        if rem < v {
            break;
        }
        rem -= v;
        m += 1;
    }
    (yi as i32, m, rem + 1)
}

fn local_tz_offset_secs() -> i64 {
    use std::sync::OnceLock;
    static CACHE: OnceLock<i64> = OnceLock::new();
    *CACHE.get_or_init(|| {
        let Ok(out) = std::process::Command::new("date").arg("+%z").output() else {
            return 0;
        };
        let s = String::from_utf8_lossy(&out.stdout);
        let s = s.trim();
        if s.len() != 5 {
            return 0;
        }
        let sign: i64 = if s.starts_with('-') { -1 } else { 1 };
        let Ok(hh) = s[1..3].parse::<i64>() else {
            return 0;
        };
        let Ok(mm) = s[3..5].parse::<i64>() else {
            return 0;
        };
        sign * (hh * 3600 + mm * 60)
    })
}
