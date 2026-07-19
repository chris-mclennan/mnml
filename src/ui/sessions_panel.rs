//! cmux-style vertical session-tab strip. Renders in the rail
//! content area when `ActivitySection::Sessions` is active.
//!
//! Each tab shows the session's display name, the git branch of
//! its cwd, and the cwd basename. Click → focus that Pty pane.
//!
//! Slice 1 (this commit): basic list + click-to-focus. Bells,
//! status, ticket detection, right-click menu, drag-reorder, and
//! port detection land in slices 2-5.

use ratatui::{
    Frame,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Paragraph},
};

use crate::app::App;
use crate::pane::Pane;
use crate::ui::theme;

/// Height in rows for one session tab. 4 rows: name + 3 lines
/// of session summary. Old row 2 (⎇ branch · cwd) still lives in
/// the hover tooltip — user report 2026-07-18: "not sure line 2
/// is that helpful showing branch and repo, maybe we could still
/// show that but only on hover". Card grew from 2 → 3 → 4 rows
/// across follow-ups so the summary has real room.
const TAB_H: u16 = 4;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    app.rects.session_tabs.clear();
    app.rects.session_new_chip = None;
    app.rects.sessions_panel_filter_input = None;

    // Collect Pty panes first so the header can show the filtered
    // count. Index in `app.panes` doubles as the focus target for
    // the click handler.
    //
    // user report 2026-07-15 — "why is bitbucket showing up in
    // sessions? shouldn't a session just be Claude Code or Codex
    // though?". Yes — Sessions is the AI-agent panel, not a
    // "every process mnml has spawned" catchall. Filter to Pty
    // panes whose `exe` is one of the AI CLIs. Bare shells,
    // integrations (bitbucket / amplify / :term <binary>), and
    // task launches are all excluded — they show up in the
    // bufferline as regular Pty tabs but don't clutter the AI
    // Sessions view.
    fn is_ai_session_pane(p: &Pane) -> bool {
        let Pane::Pty(s) = p else { return false };
        // 2026-07-18 — was `exe basename == "claude"|"codex"`. That
        // broke when workspaces set a per-workspace launcher script
        // (`./bin/claude-multi.sh` etc.) via the chip's "Set launcher
        // script…" menu — the exe basename becomes `claude-multi.sh`
        // and misses the match, so real Claude Code sessions vanish
        // from this panel. Match against the stable BinaryProfile
        // label instead — it's `"claude code"` / `"claude code
        // (resumed)"` / `"codex"` regardless of what wrapper the
        // user runs it through.
        matches!(
            s.profile.label.as_str(),
            "Claude Code" | "Claude Code (resumed)" | "Codex"
        )
    }
    let all_pty_indices: Vec<usize> = app
        .panes
        .iter()
        .enumerate()
        .filter_map(|(i, p)| is_ai_session_pane(p).then_some(i))
        .collect();
    let filter_lc = app.sessions_panel_filter.to_ascii_lowercase();
    let pty_indices: Vec<usize> = if filter_lc.is_empty() {
        all_pty_indices.clone()
    } else {
        all_pty_indices
            .iter()
            .copied()
            .filter(|pid| session_matches_filter(app, *pid, &filter_lc))
            .collect()
    };
    let pty_indices = sort_sessions(app, pty_indices);

    // Header — appends `(N of M)` when the filter is active.
    let mut header_spans = vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled(
            "SESSIONS",
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
    ];
    if !filter_lc.is_empty() {
        header_spans.push(Span::styled(
            format!("  ({} of {})", pty_indices.len(), all_pty_indices.len()),
            Style::default()
                .fg(t.comment)
                .bg(bg)
                .add_modifier(Modifier::DIM),
        ));
    }
    frame.render_widget(
        Paragraph::new(Line::from(header_spans)),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );

    // Filter row (row 1). Same idiom as HTTP / Agents / TODOs /
    // Notes — chip background, magnifier glyph, `/ filter`
    // placeholder, `▏` cursor when focused.
    {
        let y_filter = area.y + 1;
        if y_filter < area.y + area.height {
            let focused = app.sessions_panel_filter_focused;
            let bg_chip = t.bg2;
            let fg_chip = if app.sessions_panel_filter.is_empty() && !focused {
                t.comment
            } else {
                t.fg
            };
            let display = if app.sessions_panel_filter.is_empty() {
                if focused {
                    "type to filter\u{2026}".to_string()
                } else {
                    "/ filter".to_string()
                }
            } else {
                app.sessions_panel_filter.clone()
            };
            let cursor = if focused { "\u{258F}" } else { " " };
            let pad = (area.width as usize).saturating_sub(3 + display.chars().count() + 1 + 1);
            let line = Line::from(vec![
                Span::styled(" ", Style::default().bg(bg)),
                Span::styled("\u{F0349} ", Style::default().fg(t.comment).bg(bg_chip)),
                Span::styled(display, Style::default().fg(fg_chip).bg(bg_chip)),
                Span::styled(cursor, Style::default().fg(t.cyan).bg(bg_chip)),
                Span::styled(" ".repeat(pad), Style::default().bg(bg_chip)),
                Span::styled(" ", Style::default().bg(bg)),
            ]);
            let row_rect = Rect {
                x: area.x,
                y: y_filter,
                width: area.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(line), row_rect);
            app.rects.sessions_panel_filter_input = Some(row_rect);
        }
    }
    let mut y = area.y + 3;

    if pty_indices.is_empty() {
        let msg = if !filter_lc.is_empty() {
            "No matches — Esc clears"
        } else {
            "No sessions yet."
        };
        let empty = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(msg, Style::default().fg(t.comment).bg(bg)),
        ]);
        frame.render_widget(
            Paragraph::new(empty),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        // Advance past the message + a gap, then fall through (don't
        // `return`) so the "+ New session" row below still renders — you
        // need it to start your *first* session from this panel.
        y += 2;
    }

    // Clamp the cursor to the filtered list so keyboard nav
    // stays in-bounds after a filter narrows.
    let clamped_cursor = app
        .sessions_panel_cursor
        .min(pty_indices.len().saturating_sub(1));
    app.sessions_panel_cursor = clamped_cursor;
    let active_pid = app.active;
    for (row_i, &pid) in pty_indices.iter().enumerate() {
        if y + TAB_H > area.y + area.height {
            break;
        }
        let pane = match app.panes.get(pid) {
            Some(p) => p,
            None => continue,
        };
        let Pane::Pty(s) = pane else { continue };

        let is_active = active_pid == Some(pid);
        let is_cursored = row_i == clamped_cursor;
        let tab_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: TAB_H,
        };

        // 1-cell accent on the left edge: user-set color always
        // wins; then keyboard-cursor cyan; then active green;
        // else transparent.
        let accent_color = match s.accent_color.as_deref() {
            Some("green") => t.green,
            Some("blue") => t.blue,
            Some("yellow") => t.yellow,
            Some("orange") => t.orange,
            Some("red") => t.red,
            Some("purple") => t.purple,
            Some("cyan") => t.cyan,
            _ => {
                if is_cursored && app.focus == crate::focus::Focus::Tree {
                    t.cyan
                } else if is_active {
                    t.green
                } else {
                    bg
                }
            }
        };
        for row in 0..TAB_H {
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    " ",
                    Style::default().bg(accent_color),
                ))),
                Rect {
                    x: area.x,
                    y: y + row,
                    width: 1,
                    height: 1,
                },
            );
        }

        // Row 1: name (bold when active) + optional bell badge.
        // 2026-07-18 — use `tab_label_with_prefixes` so the session
        // row shows the SAME name the bufferline tab shows. That
        // fn pulls from the pty's OSC title + a grid scrollback
        // scan for ticket tokens ("Review TE-1234 …"), so Jira
        // ticket auto-naming that lands in the tab lands here too.
        let cwd = s.profile.cwd.as_ref();
        let branch_for_lookup = cwd.and_then(|p| current_branch(p));
        let detected_ticket = detect_ticket(
            &app.config.ui.ticket_prefixes,
            s.display_name.as_deref(),
            branch_for_lookup.as_deref(),
            &s.profile.label,
        );
        let label = s.tab_label_with_prefixes(&app.config.ui.ticket_prefixes);
        let name_style = Style::default().fg(t.fg).bg(bg).add_modifier(if is_active {
            Modifier::BOLD
        } else {
            Modifier::empty()
        });
        let unread = s.unread_bytes();
        let is_pinned = app.sessions_pinned.contains(&pid);
        let mut name_spans = vec![Span::styled("  ", Style::default().bg(bg))];
        if is_pinned {
            let pin_glyph = if !app.config.ui.ascii_icons {
                "\u{F0403} "
            } else {
                "📌 "
            };
            name_spans.push(Span::styled(
                pin_glyph,
                Style::default().fg(t.orange).bg(bg),
            ));
        }
        name_spans.push(Span::styled(label, name_style));
        // "Unread" is a byte count of pty output since last focus.
        // Startup banner + ANSI escapes easily hit 500+ bytes, so
        // showing the raw number reads as "🔔 999+" on a session
        // you literally just opened (user report 2026-07-19).
        // Threshold at 1KB so noise doesn't fire the bell; drop
        // the count digits entirely — a single dot ("has activity
        // since you last looked at it") is the useful signal.
        const UNREAD_BYTES_THRESHOLD: u64 = 1024;
        if unread >= UNREAD_BYTES_THRESHOLD && !is_active {
            let bell_glyph = if !app.config.ui.ascii_icons {
                "\u{F0F89}" // Nerd Font bell
            } else {
                "•"
            };
            name_spans.push(Span::styled("  ", Style::default().bg(bg)));
            name_spans.push(Span::styled(
                bell_glyph,
                Style::default()
                    .fg(t.orange)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ));
        }
        frame.render_widget(
            Paragraph::new(Line::from(name_spans)),
            Rect {
                x: area.x + 1,
                y,
                width: area.width - 1,
                height: 1,
            },
        );

        // Row 2 (branch/cwd) is now hover-only — see the tooltip
        // pass at the bottom of `draw`. Still compute cwd_label
        // for the hover payload cached later.
        let _branch_kept_for_hover = branch_for_lookup.clone();

        // Rows 2 & 3: a two-line summary of what the session is
        // doing (Claude's activity verb line + one more recent
        // content line) — or `exited` for a dead child. The old
        // row-2 branch/cwd display moved to the hover tooltip.
        let (summary_lines, summary_color): (Vec<String>, _) = if s.is_exited() {
            (vec!["exited".to_string()], t.red)
        } else {
            let lines = session_lines_for_card(app, s, 3);
            if lines.is_empty() {
                (vec!["—".to_string()], t.grey)
            } else {
                (lines, t.comment)
            }
        };
        let truncate_to_row = |text: &str| -> String {
            let max = (area.width as usize).saturating_sub(6).max(4);
            let count = text.chars().count();
            if count > max {
                let take = max.saturating_sub(1);
                let mut out: String = text.chars().take(take).collect();
                out.push('…');
                out
            } else {
                text.to_string()
            }
        };
        // Capture the pid before the row paints so we can release
        // the &Pane borrow and re-borrow App mutably for the
        // session_ports cache lookup.
        let pty_pid_opt = s.pid();
        for (row_off, line_text) in summary_lines.iter().enumerate().take(3) {
            let truncated = truncate_to_row(line_text);
            let mut row_spans = vec![
                Span::styled("  ", Style::default().bg(bg)),
                Span::styled(truncated, Style::default().fg(summary_color).bg(bg)),
            ];
            // Ticket chip: append after the FIRST summary line only
            // (row 2). Same rule as before — hidden if the user set
            // a custom display name.
            if row_off == 0
                && let Some(ticket) = detected_ticket.as_deref()
                && s.display_name.is_none()
            {
                row_spans.push(Span::styled(" · ", Style::default().fg(t.comment).bg(bg)));
                row_spans.push(Span::styled(ticket, Style::default().fg(t.cyan).bg(bg)));
            }
            let row_rect = Rect {
                x: area.x + 1,
                y: y + 1 + row_off as u16,
                width: area.width - 1,
                height: 1,
            };
            frame.render_widget(Paragraph::new(Line::from(row_spans)), row_rect);
        }
        // Listening ports (cached) — right-anchored chip on row 2.
        if let Some(pid) = pty_pid_opt {
            let ports = app.session_ports(pid);
            if !ports.is_empty() {
                let chip_text: String = ports
                    .iter()
                    .map(|p| format!(":{p}"))
                    .collect::<Vec<_>>()
                    .join(" ");
                let chip_w = chip_text.chars().count() as u16;
                let row2_x = area.x + 1;
                let row2_w = area.width - 1;
                if row2_w > chip_w + 6 {
                    let chip_rect = Rect {
                        x: row2_x + row2_w - chip_w - 1,
                        y: y + 1,
                        width: chip_w,
                        height: 1,
                    };
                    frame.render_widget(
                        Paragraph::new(Line::from(Span::styled(
                            chip_text,
                            Style::default().fg(t.blue).bg(bg),
                        ))),
                        chip_rect,
                    );
                }
            }
        }

        app.rects.session_tabs.push((tab_rect, pid));
        y += TAB_H;
        // Blank line between sessions for breathing room.
        y += 1;
    }

    // External Claude sessions (#5) — sessions running elsewhere
    // (other mnml windows, bare shells) but rooted in this workspace.
    // Filter the agents-panel snapshot to rows whose cwd points at
    // this workspace, minus session_ids we already own as a Pty pane.
    let owned_sids: std::collections::HashSet<String> = app
        .panes
        .iter()
        .filter_map(|p| match p {
            Pane::Pty(s) => s.profile.session_id.clone(),
            _ => None,
        })
        .collect();
    let ws_str = app.workspace.to_string_lossy();
    let external: Vec<crate::claude_agents::AgentRow> = app
        .agents_panel_rows
        .iter()
        .filter(|row| {
            row.cwd
                .as_deref()
                .is_some_and(|c| c == ws_str.as_ref() || c.starts_with(ws_str.as_ref()))
                && !owned_sids.contains(&row.session_id)
        })
        .cloned()
        .collect();
    if !external.is_empty() && y + 2 < area.y + area.height {
        // Section divider.
        let hdr = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(
                "EXTERNAL",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
        ]);
        frame.render_widget(
            Paragraph::new(hdr),
            Rect {
                x: area.x,
                y,
                width: area.width,
                height: 1,
            },
        );
        y += 1;
        for row in external.iter().take(4) {
            if y >= area.y + area.height {
                break;
            }
            let branch = row
                .git_branch
                .as_deref()
                .filter(|b| !b.is_empty())
                .unwrap_or("—");
            let short_sid: String = row.session_id.chars().take(8).collect();
            let label = format!("  {branch}  ({short_sid})");
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    label,
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ))),
                Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                },
            );
            y += 1;
        }
        y += 1;
    }

    // `+ New session` row — last interactive row at the bottom
    // of the panel. Click → spawn a Claude Code pane (the most
    // common single-click case). A future picker could let the
    // user pick Claude / Codex / shell here.
    if y < area.y + area.height {
        let new_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        let line = Line::from(vec![
            Span::styled("  ", Style::default().bg(bg)),
            Span::styled(
                "+ New session",
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            ),
        ]);
        frame.render_widget(Paragraph::new(line), new_rect);
        app.rects.session_new_chip = Some(new_rect);
    }
    // Hover-tooltip content lives in `ui::tooltip::describe`
    // (`HoverChip::SessionsTab`) — enhanced to show the branch,
    // cwd, and grid lines. Painting a separate floating card
    // from here would double-render.
}

/// Find a Jira-style ticket (`PREFIX-<digits>`) in any of the
/// candidate strings, using the user's configured `[ui]
/// ticket_prefixes`. Returns the first match in display →
/// branch → label order, or `None`.
fn detect_ticket(
    prefixes: &[String],
    display_name: Option<&str>,
    branch: Option<&str>,
    label: &str,
) -> Option<String> {
    if prefixes.is_empty() {
        return None;
    }
    for candidate in [display_name.unwrap_or(""), branch.unwrap_or(""), label] {
        if candidate.is_empty() {
            continue;
        }
        for p in prefixes {
            let p = p.as_str();
            if p.is_empty() {
                continue;
            }
            // Find `<prefix><digits>`. Case-insensitive prefix
            // match; digits required.
            let needle = p.to_ascii_lowercase();
            let hay = candidate.to_ascii_lowercase();
            let mut idx = 0;
            while let Some(pos) = hay[idx..].find(&needle) {
                let start = idx + pos;
                let after = start + needle.len();
                let suffix = &candidate[after..];
                let digit_end = suffix
                    .char_indices()
                    .take_while(|(_, c)| c.is_ascii_digit())
                    .last()
                    .map(|(i, c)| i + c.len_utf8());
                if let Some(de) = digit_end
                    && de > 0
                {
                    return Some(candidate[start..after + de].to_string());
                }
                idx = after;
            }
        }
    }
    None
}

/// True when the Pty pane at `pid` matches the (already-lowercased)
/// `/`-filter — matched against the session's display name, its
/// profile label, git branch of the cwd, cwd basename, and any
/// detected Jira ticket. Substring match, case-insensitive on the
/// haystack (caller lowercases the needle). Non-Pty ids return
/// `false` so callers can trust the answer without checking again.
fn session_matches_filter(app: &App, pid: usize, needle_lc: &str) -> bool {
    let Some(Pane::Pty(s)) = app.panes.get(pid) else {
        return false;
    };
    let cwd = s.profile.cwd.as_ref();
    let branch = cwd.and_then(|p| current_branch(p));
    let ticket = detect_ticket(
        &app.config.ui.ticket_prefixes,
        s.display_name.as_deref(),
        branch.as_deref(),
        &s.profile.label,
    );
    let cwd_basename = cwd
        .and_then(|p| p.file_name().and_then(|n| n.to_str()))
        .unwrap_or_default();
    let candidates = [
        s.display_name.as_deref().unwrap_or_default(),
        s.profile.label.as_str(),
        branch.as_deref().unwrap_or_default(),
        cwd_basename,
        ticket.as_deref().unwrap_or_default(),
    ];
    candidates
        .iter()
        .any(|c| !c.is_empty() && c.to_ascii_lowercase().contains(needle_lc))
}

/// Order a filtered slice of session pane ids per the current
/// `sessions_sort_mode`. Pinned sessions always come first (in
/// their pinned-insertion order — the user's pin sequence).
/// Non-pinned sessions follow, in either Auto (running first) or
/// Manual (user's `sessions_manual_order`) order.
fn sort_sessions(app: &App, indices: Vec<usize>) -> Vec<usize> {
    use crate::app::SessionsSortMode;
    let (mut pinned, rest): (Vec<usize>, Vec<usize>) = indices
        .into_iter()
        .partition(|pid| app.sessions_pinned.contains(pid));
    // Pinned kept in their id order — simple + stable. The user's
    // pin action is a toggle; a per-pin timestamp isn't tracked.
    pinned.sort_unstable();
    let mut body = rest;
    match app.sessions_sort_mode {
        SessionsSortMode::Auto => {
            body.sort_by_key(|&pid| session_state_priority(app, pid));
        }
        SessionsSortMode::Manual => {
            body.sort_by_key(|&pid| {
                app.sessions_manual_order
                    .iter()
                    .position(|&x| x == pid)
                    .unwrap_or(usize::MAX)
            });
        }
    }
    pinned.into_iter().chain(body).collect()
}

/// Priority for Auto sort — lower is higher on the list.
///   0 = action needed (Claude waiting on user for approval)
///   1 = running (Claude or Codex actively thinking)
///   2 = idle
///   3 = exited
/// Card summary picker with a rest-only JSONL fallback:
///   - Thinking (spinner active, Codex working) → grid lines
///     (matches the live pane in real-time — "Sautéed for 27s"
///     etc.).
///   - At rest with a Claude session_id + on-disk transcript →
///     transcript exchange (`you: …`, `claude: …`). Uses
///     `claude_agents::transcript_summary_lines`.
///   - Fallback → grid lines (Codex, bare shells, no transcript,
///     any read failure).
///
/// Returned in READ order (top-to-bottom on the card) — grid
/// paths are scanned bottom-up so they're reversed here to
/// match the pty's natural reading direction.
fn session_lines_for_card(app: &App, s: &crate::pty_pane::PtySession, max: usize) -> Vec<String> {
    let thinking = s.current_spinner_glyph().is_some() || s.is_codex_thinking();
    if !thinking && let Some(sid) = s.profile.session_id.as_deref() {
        let lines = crate::claude_agents::transcript_summary_lines(sid, &app.workspace);
        if !lines.is_empty() {
            return lines.into_iter().take(max).collect();
        }
    }
    let mut lines = s.session_summary_lines(max);
    lines.reverse();
    lines
}

fn session_state_priority(app: &App, pid: usize) -> u8 {
    let Some(Pane::Pty(s)) = app.panes.get(pid) else {
        return 4;
    };
    if s.is_exited() {
        return 3;
    }
    // "Action needed" heuristic: the summary picker skips known
    // footer chips, so a summary that STILL mentions "approval"
    // or "accept" is likely Claude Code's confirmation prompt.
    if let Some(summary) = s.session_summary() {
        let lower = summary.to_ascii_lowercase();
        if lower.contains("approval") || lower.contains("do you want") {
            return 0;
        }
    }
    let thinking = s.current_spinner_glyph().is_some() || s.is_codex_thinking();
    if thinking {
        return 1;
    }
    2
}

/// Cheap git branch lookup — shells out to `git symbolic-ref --short HEAD`.
/// Returns None for non-repos / detached HEAD.
fn current_branch(cwd: &std::path::Path) -> Option<String> {
    let out = std::process::Command::new("git")
        .args(["symbolic-ref", "--short", "-q", "HEAD"])
        .current_dir(cwd)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let b = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!b.is_empty()).then_some(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_ticket_finds_jira_in_branch() {
        let prefixes = vec!["TKT-".to_string(), "MIX-".to_string()];
        assert_eq!(
            detect_ticket(&prefixes, None, Some("feature/TKT-123-fix"), "claude code"),
            Some("TKT-123".to_string())
        );
    }

    #[test]
    fn detect_ticket_case_insensitive() {
        let prefixes = vec!["TKT-".to_string()];
        assert_eq!(
            detect_ticket(&prefixes, Some("tkt-9 review"), None, "claude code"),
            Some("tkt-9".to_string())
        );
    }

    #[test]
    fn detect_ticket_skips_when_no_digits() {
        let prefixes = vec!["TKT-".to_string()];
        assert_eq!(
            detect_ticket(&prefixes, None, Some("TKT-foo"), "claude code"),
            None
        );
    }

    #[test]
    fn detect_ticket_returns_none_when_no_prefixes() {
        assert_eq!(detect_ticket(&[], None, Some("TKT-9"), "claude code"), None);
    }
}
