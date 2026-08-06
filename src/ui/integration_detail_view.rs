//! `Pane::IntegrationDetail` — the VS-Code-extension-detail-page
//! equivalent for ONE mnml integration. Shows title / byline /
//! description, a horizontal button strip (Enable/Disable, Uninstall,
//! Bake glyph, Refresh, Edit manifest, Copy id), the palette
//! commands the integration declares, and Homepage / Repository /
//! Docs links.
//!
//! Read-only apart from the button strip — every action dispatches
//! through an existing command / helper on `App` (the pane never
//! mutates the integration itself, matching the architecture
//! spine's "no special-casing across layers" rule).
//!
//! Hosted in the right side panel by default (mirrors `outline_view`
//! / `diagnostics_view`); can also render in a body split when the
//! panel is closed.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::config::{IntegrationIcon, IntegrationIconCommand};
use crate::layout::PaneId;
use crate::pane::Pane;
use crate::ui::theme::{self, Theme};

/// How long an inline "✓ …" post-action toast lingers under the
/// button strip.
pub const TOAST_TTL_SECS: u64 = 3;

/// One clickable button on the detail pane.
#[derive(Debug, Clone)]
pub(crate) struct DetailButton {
    pub(crate) label: String,
    /// Command id or `":ex …"` string to fire on activation.
    /// `open_manifest` / `copy_id` / etc route through per-button
    /// dispatch in `run_button` (they need the integration id).
    pub(crate) action: DetailAction,
}

#[derive(Debug, Clone)]
pub(crate) enum DetailAction {
    /// Fire a registered command by id.
    Command(&'static str),
    /// Toggle enabled state for this integration id.
    ToggleEnabled(String),
    /// Prompt-remove this integration.
    Uninstall(String),
    /// Open the on-disk manifest for this id (workspace, else user).
    OpenManifest(String),
    /// Copy the integration id to the clipboard.
    CopyId(String),
    /// Open the glyph builder pre-loaded at this integration's
    /// current codepoint.
    BakeGlyph(u32),
    /// Fire the integration's own primary command
    /// (`icon.command` — either an id or a `:ex` string).
    RunPrimary(String),
    /// 2026-08-06 — for marketplace-only entries (id in
    /// `App::marketplace_entries` but not yet in
    /// `config.ui.integration_icons`), the detail pane surfaces an
    /// `[Install]` button. Firing it routes to the same
    /// `open_marketplace_install_prompt` the row-click uses so the
    /// user always lands on the confirm dialog before cargo runs.
    InstallFromMarketplace(String),
}

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

    // Paint the panel bg first so partial paints don't leave
    // through-holes.
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_dark)),
        area,
    );

    // Register the pane's body for editor-hover/click bookkeeping
    // (matches diagnostics_view's convention — skip when hosted in
    // the right panel to avoid pointless goto-def / hover tries).
    if !app.right_panel_panes.contains(&pane_id) {
        app.rects.editor_panes.push((area, pane_id));
    }

    // Snapshot everything we need before the mutable borrow on the
    // pane itself. Icon lookup is deliberately done every draw so a
    // config-toggle / manifest refresh is picked up without touching
    // pane state.
    let id = match app.panes.get(pane_id) {
        Some(Pane::IntegrationDetail(d)) => d.id.clone(),
        _ => return None,
    };
    let icon: Option<IntegrationIcon> = app
        .config
        .ui
        .integration_icons
        .iter()
        .find(|i| i.id == id)
        .cloned();
    // 2026-08-06 — marketplace-only fallback so the detail pane
    // renders full metadata (label, description, source) for entries
    // the user hasn't installed yet, not just the "not found"
    // placeholder. Synthesize an IntegrationIcon from the
    // marketplace entry's fields.
    let marketplace_entry = if icon.is_none() {
        app.marketplace_entries.iter().find(|e| e.id == id).cloned()
    } else {
        None
    };
    let synthesized_icon: Option<IntegrationIcon> =
        marketplace_entry
            .as_ref()
            .map(|e| crate::config::IntegrationIcon {
                id: e.id.clone(),
                glyph: e.glyph.clone().unwrap_or_default(),
                fallback: String::new(),
                command: String::new(),
                color: e.color.clone().unwrap_or_else(|| "fg".to_string()),
                label: Some(e.label.clone()),
                enabled: false,
                in_palette_bar: false,
                description: e.description.clone(),
                homepage: None,
                docs: None,
                repository: None,
                author: None,
                version: None,
                commands: Vec::new(),
            });
    let installed_icon = icon.clone();
    // For rendering, prefer the real installed icon; fall back to
    // the marketplace-synthesized one so display fields (label,
    // description, glyph, color) always show.
    let icon: Option<IntegrationIcon> = icon.or(synthesized_icon);
    let nerd = !app.config.ui.ascii_icons;

    // Build the button set + link set + command-row set. This drives
    // both the visible layout and the cursor's actionable-row
    // mapping, so it MUST match what the click-router walks below.
    // Pass the ORIGINAL icon (None for marketplace-only) so the
    // helper switches on the marketplace-only path and emits just
    // an [Install] button rather than the installed-integration
    // button set.
    let is_marketplace_only = marketplace_entry.is_some();
    let (buttons, commands, links) =
        build_actionable_with_marketplace(&id, installed_icon.as_ref(), is_marketplace_only);
    let total_actions = buttons.len() + commands.len() + links.len();

    // Clamp + read the pane's cursor.
    let Some(Pane::IntegrationDetail(d)) = app.panes.get_mut(pane_id) else {
        return None;
    };
    if total_actions == 0 {
        d.cursor = 0;
    } else if d.cursor >= total_actions {
        d.cursor = total_actions - 1;
    }
    let cursor = d.cursor;
    // Expire the inline confirmation toast after TTL.
    if let Some((at, _)) = d.last_action.as_ref()
        && at.elapsed().as_secs() >= TOAST_TTL_SECS
    {
        d.last_action = None;
    }
    let action_toast = d.last_action.as_ref().map(|(_, s)| s.clone());
    // End of mutable-borrow scope.

    // ── Compose the lines. Track which visual y-row corresponds
    //    to which actionable index, so the click-router + the
    //    keyboard cursor's highlight line up. ──────────────────
    let mut lines: Vec<Line<'static>> = Vec::new();
    // `(line_index_in_lines, actionable_index)` — used later to
    // register click rects at the correct screen y.
    let mut row_to_action: Vec<(usize, usize)> = Vec::new();

    // ── Title ────────────────────────────────────────────────
    let title_glyph = icon
        .as_ref()
        .map(|i| {
            if nerd {
                i.glyph.clone()
            } else {
                i.fallback.clone()
            }
        })
        .unwrap_or_default();
    let title_color = icon
        .as_ref()
        .map(|i| theme::color_from_slot(i.color.as_str(), &t))
        .unwrap_or(t.fg);
    let title_name = icon
        .as_ref()
        .and_then(|i| i.label.clone().filter(|s| !s.is_empty()))
        .unwrap_or_else(|| id.clone());
    lines.push(Line::from(vec![
        Span::styled(
            format!("  {title_glyph}  "),
            Style::default().fg(title_color).bg(t.bg_dark),
        ),
        Span::styled(
            title_name,
            Style::default()
                .fg(t.fg)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
    ]));

    // ── Byline (version + author). Omit both if neither present.
    let byline = build_byline(icon.as_ref());
    if let Some(byline) = byline {
        lines.push(Line::from(vec![
            Span::styled("      ", Style::default().bg(t.bg_dark)),
            Span::styled(byline, Style::default().fg(t.comment).bg(t.bg_dark)),
        ]));
    }
    // Blank spacer.
    lines.push(Line::from(Span::styled(
        " ",
        Style::default().bg(t.bg_dark),
    )));

    // ── Description (paragraph — soft-wrapped to width). ────
    if let Some(desc) = icon.as_ref().and_then(|i| i.description.clone())
        && !desc.trim().is_empty()
    {
        let wrap_w = (area.width as usize).saturating_sub(4);
        for chunk in wrap_paragraph(&desc, wrap_w.max(20)) {
            lines.push(Line::from(vec![
                Span::styled("  ", Style::default().bg(t.bg_dark)),
                Span::styled(chunk, Style::default().fg(t.fg).bg(t.bg_dark)),
            ]));
        }
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
    } else if icon.is_some() {
        lines.push(Line::from(vec![
            Span::styled("  ", Style::default().bg(t.bg_dark)),
            Span::styled(
                "(no description provided — add one via the manifest TOML)",
                Style::default()
                    .fg(t.comment)
                    .bg(t.bg_dark)
                    .add_modifier(Modifier::ITALIC),
            ),
        ]));
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
    } else {
        lines.push(Line::from(vec![
            Span::styled("  ", Style::default().bg(t.bg_dark)),
            Span::styled(
                format!("integration `{id}` not found — was it uninstalled?"),
                Style::default().fg(t.red).bg(t.bg_dark),
            ),
        ]));
    }

    // ── Buttons row(s) ─────────────────────────────────────
    // At narrow widths (right-panel default 32 cells) buttons
    // wrap; at wide widths they pack onto fewer rows. Keep the
    // per-button ratui Span so we can emit one Rect per button
    // for click routing.
    let mut action_idx_running = 0usize;
    if !buttons.is_empty() {
        // Split into rows so each row fits in area.width - 2.
        let max_w = (area.width as usize).saturating_sub(2).max(8);
        let mut row_spans: Vec<Span<'static>> = Vec::new();
        let mut row_action_idxs: Vec<usize> = Vec::new();
        let mut row_width_used = 0usize;
        let flush_row = |lines: &mut Vec<Line<'static>>,
                         row_to_action: &mut Vec<(usize, usize)>,
                         row_spans: &mut Vec<Span<'static>>,
                         row_action_idxs: &mut Vec<usize>| {
            if row_spans.is_empty() {
                return;
            }
            let line_idx = lines.len();
            // Prepend the indent.
            let mut spans: Vec<Span<'static>> =
                vec![Span::styled("  ", Style::default().bg(t.bg_dark))];
            spans.append(row_spans);
            lines.push(Line::from(spans));
            // Every button on this row shares a y-line.
            for aidx in row_action_idxs.drain(..) {
                row_to_action.push((line_idx, aidx));
            }
        };
        for b in &buttons {
            let chip = format!("[ {} ]", b.label);
            let chip_w = chip.chars().count() + 1; // + 1-space gap
            if row_width_used + chip_w > max_w && !row_spans.is_empty() {
                flush_row(
                    &mut lines,
                    &mut row_to_action,
                    &mut row_spans,
                    &mut row_action_idxs,
                );
                row_width_used = 0;
            }
            let focused = action_idx_running == cursor;
            let style = if focused {
                Style::default()
                    .fg(t.bg_dark)
                    .bg(title_color)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(t.fg).bg(t.bg2)
            };
            row_spans.push(Span::styled(chip, style));
            row_spans.push(Span::styled(" ", Style::default().bg(t.bg_dark)));
            row_action_idxs.push(action_idx_running);
            row_width_used += chip_w;
            action_idx_running += 1;
        }
        flush_row(
            &mut lines,
            &mut row_to_action,
            &mut row_spans,
            &mut row_action_idxs,
        );
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
    }

    // ── Inline post-action confirmation. ────────────────────
    if let Some(msg) = action_toast {
        lines.push(Line::from(vec![
            Span::styled("  ", Style::default().bg(t.bg_dark)),
            Span::styled(
                format!("\u{2713} {msg}"),
                Style::default().fg(t.green).bg(t.bg_dark),
            ),
        ]));
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
    }

    // ── Commands section ───────────────────────────────────
    if !commands.is_empty() {
        lines.push(section_header("Commands", area.width, &t));
        for c in &commands {
            let focused = action_idx_running == cursor;
            let arrow = if focused { "\u{25B6} " } else { "  " };
            let bg = if focused { t.bg2 } else { t.bg_dark };
            let arrow_fg = if focused { t.cyan } else { t.comment };
            let line_idx = lines.len();
            let title = format!(
                "{:<28} {}",
                truncate(&c.id, 28),
                truncate(&c.title, area.width.saturating_sub(30) as usize)
            );
            lines.push(Line::from(vec![
                Span::styled(arrow.to_string(), Style::default().fg(arrow_fg).bg(bg)),
                Span::styled(title, Style::default().fg(t.fg).bg(bg)),
            ]));
            row_to_action.push((line_idx, action_idx_running));
            action_idx_running += 1;
        }
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
    }

    // ── Links section ─────────────────────────────────────
    if !links.is_empty() {
        lines.push(section_header("Links", area.width, &t));
        for (label, url) in &links {
            let focused = action_idx_running == cursor;
            let arrow = if focused { "\u{25B6} " } else { "  " };
            let bg = if focused { t.bg2 } else { t.bg_dark };
            let arrow_fg = if focused { t.cyan } else { t.blue };
            let line_idx = lines.len();
            let disp_url = truncate(url, area.width.saturating_sub(16) as usize);
            lines.push(Line::from(vec![
                Span::styled(arrow.to_string(), Style::default().fg(arrow_fg).bg(bg)),
                Span::styled(
                    format!("\u{2197} {label:<10} "),
                    Style::default().fg(t.blue).bg(bg),
                ),
                Span::styled(
                    disp_url,
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::UNDERLINED),
                ),
            ]));
            row_to_action.push((line_idx, action_idx_running));
            action_idx_running += 1;
        }
        lines.push(Line::from(Span::styled(
            " ",
            Style::default().bg(t.bg_dark),
        )));
    }

    // ── README section ────────────────────────────────────
    // Phase-1 rich detail (2026-08-06). Fetched async by
    // `App::spawn_readme_fetch`; delivered by
    // `drain_readme_fetches` on subsequent ticks. Rendered as
    // wrapped plain text (no markdown styling yet — Phase 2).
    match app.readme_cache.get(&id) {
        Some(crate::app::integration_detail::ReadmeState::Loading) => {
            lines.push(section_header("README", area.width, &t));
            lines.push(Line::from(vec![
                Span::styled("  ", Style::default().bg(t.bg_dark)),
                Span::styled(
                    "Fetching README…",
                    Style::default()
                        .fg(t.comment)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::ITALIC),
                ),
            ]));
            lines.push(Line::from(Span::styled(
                " ",
                Style::default().bg(t.bg_dark),
            )));
        }
        Some(crate::app::integration_detail::ReadmeState::Text(body)) => {
            lines.push(section_header("README", area.width, &t));
            let wrap_w = (area.width as usize).saturating_sub(4);
            // README rendering — cap paragraph length so a monster
            // README doesn't OOM the wrap. Long tail is reachable
            // by scrolling; hard cap at ~10k chars keeps the wrap
            // bounded.
            let capped: String = body.chars().take(10_000).collect();
            for raw_line in capped.lines() {
                let trimmed = raw_line.trim_end();
                if trimmed.is_empty() {
                    lines.push(Line::from(Span::styled(
                        " ",
                        Style::default().bg(t.bg_dark),
                    )));
                    continue;
                }
                // Wrap each source line independently — README
                // authors often use hard breaks.
                for chunk in wrap_paragraph(trimmed, wrap_w.max(20)) {
                    lines.push(Line::from(vec![
                        Span::styled("  ", Style::default().bg(t.bg_dark)),
                        Span::styled(chunk, Style::default().fg(t.fg).bg(t.bg_dark)),
                    ]));
                }
            }
            if body.chars().count() > 10_000 {
                lines.push(Line::from(vec![
                    Span::styled("  ", Style::default().bg(t.bg_dark)),
                    Span::styled(
                        "… (README truncated at 10k chars)",
                        Style::default()
                            .fg(t.comment)
                            .bg(t.bg_dark)
                            .add_modifier(Modifier::ITALIC),
                    ),
                ]));
            }
            lines.push(Line::from(Span::styled(
                " ",
                Style::default().bg(t.bg_dark),
            )));
        }
        Some(crate::app::integration_detail::ReadmeState::NotFound) | None => {
            // Nothing to render — either the fetch hasn't been
            // triggered (`None`, shouldn't happen once
            // `open_integration_detail_pane` runs) or the source
            // has no README / GitHub URL. Skip silently rather
            // than showing an empty "README" header.
        }
    }

    // ── Footer hint ───────────────────────────────────────
    let hint = if area.width >= 60 {
        "  ↑↓ / Tab move · Enter fire · Esc close · right-click link copies url"
    } else if area.width >= 30 {
        "  ↑↓ move · ⏎ fire · esc close"
    } else {
        "  ⏎ / esc"
    };
    lines.push(Line::from(Span::styled(
        hint,
        Style::default()
            .fg(t.comment)
            .bg(t.bg_dark)
            .add_modifier(Modifier::DIM),
    )));

    // ── Scroll math: keep the focused actionable row visible. ─
    let h = area.height as usize;
    let cursor_line = row_to_action
        .iter()
        .find(|(_, aidx)| *aidx == cursor)
        .map(|(li, _)| *li)
        .unwrap_or(0);
    let mut scroll = 0usize;
    if lines.len() > h {
        let max_scroll = lines.len() - h;
        scroll = cursor_line.saturating_sub(h / 2).min(max_scroll);
    }

    // ── Register click rects. Buttons are grouped on a row, so
    //    a click routes by button index — the click-router falls
    //    back to y-row match. Simpler: per-line rect works
    //    because each command / link is on its own line, and the
    //    button strip picks whichever button is under the x.
    let btn_count = buttons.len();
    for (line_y, aidx) in &row_to_action {
        if *line_y < scroll || *line_y >= scroll + h {
            continue;
        }
        let visible_y = line_y - scroll;
        let screen_y = area.y.saturating_add(visible_y as u16);
        if screen_y >= area.y.saturating_add(area.height) {
            continue;
        }
        // For button rows, register a per-button rect stacked at
        // the same y. For command/link rows, one full-width rect.
        if *aidx < btn_count {
            // Buttons on this y-row: replay layout math cheaply —
            // walk buttons ONCE per screen y so multiple buttons on
            // the same row each get their own rect.
            let mut x_off: u16 = area.x + 2;
            let mut on_this_row = false;
            for (i, b) in buttons.iter().enumerate() {
                // A button belongs to this y-row if its row_to_action entry matches.
                let this_line = row_to_action
                    .iter()
                    .find(|(_, ai)| *ai == i)
                    .map(|(l, _)| *l);
                if this_line != Some(*line_y) {
                    if on_this_row {
                        // We've passed the target row; break early.
                        // (Buttons on later rows won't share this line_y.)
                        break;
                    }
                    continue;
                }
                on_this_row = true;
                let chip_w = ("[ ".len() + b.label.chars().count() + " ]".len()) as u16;
                if x_off + chip_w > area.x + area.width {
                    break;
                }
                app.rects.integration_detail_buttons.push((
                    Rect {
                        x: x_off,
                        y: screen_y,
                        width: chip_w,
                        height: 1,
                    },
                    pane_id,
                    i,
                ));
                x_off = x_off.saturating_add(chip_w).saturating_add(1);
            }
        } else if *aidx < btn_count + commands.len() {
            app.rects.integration_detail_buttons.push((
                Rect {
                    x: area.x,
                    y: screen_y,
                    width: area.width,
                    height: 1,
                },
                pane_id,
                *aidx,
            ));
        } else {
            // Link row — register both a button rect (click fires
            // Open) and a link rect (right-click copies URL).
            let link_idx = *aidx - btn_count - commands.len();
            let url = links[link_idx].1.clone();
            let row = Rect {
                x: area.x,
                y: screen_y,
                width: area.width,
                height: 1,
            };
            app.rects
                .integration_detail_buttons
                .push((row, pane_id, *aidx));
            app.rects.integration_detail_links.push((row, pane_id, url));
        }
    }

    // ── Paint. ────────────────────────────────────────────
    let visible: Vec<Line> = lines.into_iter().skip(scroll).take(h).collect();
    frame.render_widget(
        Paragraph::new(visible).style(Style::default().bg(t.bg_dark)),
        area,
    );
    None
}

fn section_header(label: &str, width: u16, t: &Theme) -> Line<'static> {
    let bar_w = (width as usize).saturating_sub(label.chars().count() + 6);
    let bar: String = "\u{2500}".repeat(bar_w.max(1));
    Line::from(vec![
        Span::styled(
            "  \u{2500}\u{2500} ",
            Style::default().fg(t.comment).bg(t.bg_dark),
        ),
        Span::styled(
            label.to_string(),
            Style::default()
                .fg(t.fg)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ),
        Span::styled(" ", Style::default().bg(t.bg_dark)),
        Span::styled(bar, Style::default().fg(t.comment).bg(t.bg_dark)),
    ])
}

fn build_byline(icon: Option<&IntegrationIcon>) -> Option<String> {
    let ic = icon?;
    match (ic.version.as_deref(), ic.author.as_deref()) {
        (Some(v), Some(a)) if !v.is_empty() && !a.is_empty() => Some(format!("v{v} · by {a}")),
        (Some(v), _) if !v.is_empty() => Some(format!("v{v}")),
        (_, Some(a)) if !a.is_empty() => Some(format!("by {a}")),
        _ => None,
    }
}

/// Assemble the ordered actionable-row lists for a given
/// integration. Public-in-module so `App::handle_integration_detail_*`
/// can rebuild the same list to route Enter / clicks by index
/// without duplicating the layout decisions.
pub(crate) fn build_actionable(
    id: &str,
    icon: Option<&IntegrationIcon>,
) -> (
    Vec<DetailButton>,
    Vec<IntegrationIconCommand>,
    Vec<(String, String)>,
) {
    build_actionable_with_marketplace(id, icon, false)
}

/// Extended form that also emits the `[Install]` button when the id
/// refers to a marketplace-only entry (not yet installed). Callers
/// with access to `App::marketplace_entries` pass `true` when the
/// id resolves to a marketplace row.
pub(crate) fn build_actionable_with_marketplace(
    id: &str,
    icon: Option<&IntegrationIcon>,
    is_marketplace_only: bool,
) -> (
    Vec<DetailButton>,
    Vec<IntegrationIconCommand>,
    Vec<(String, String)>,
) {
    let mut buttons: Vec<DetailButton> = Vec::new();
    let mut commands: Vec<IntegrationIconCommand> = Vec::new();
    let mut links: Vec<(String, String)> = Vec::new();

    if icon.is_none() && is_marketplace_only {
        // Marketplace-only entry — one button: [Install]. Routes
        // through the same confirm-prompt path as row-click so cargo
        // install doesn't fire from a stray Enter/click.
        buttons.push(DetailButton {
            label: "Install".to_string(),
            action: DetailAction::InstallFromMarketplace(id.to_string()),
        });
        return (buttons, commands, links);
    }

    if let Some(ic) = icon {
        // Primary Enable/Disable toggle — label reflects state.
        let toggle_label = if ic.enabled { "Disable" } else { "Enable" };
        buttons.push(DetailButton {
            label: toggle_label.to_string(),
            action: DetailAction::ToggleEnabled(id.to_string()),
        });
        // Fire the integration's primary command (only useful
        // when enabled; still shown so a Marketplace-tab detail
        // pane surfaces the primary action as an obvious button).
        if !ic.command.is_empty() {
            buttons.push(DetailButton {
                label: "Open".to_string(),
                action: DetailAction::RunPrimary(ic.command.clone()),
            });
        }
        // Uninstall — only meaningful for non-built-ins (i.e.
        // things a sibling manifest or the user added). For
        // built-ins Removing == "remove from your rail", which
        // is a valid action too, so we always surface it.
        buttons.push(DetailButton {
            label: "Uninstall".to_string(),
            action: DetailAction::Uninstall(id.to_string()),
        });
        // Bake glyph — only when we have a codepoint. The
        // integration icon's first char IS the codepoint.
        if let Some(cp) = ic.glyph.chars().next() {
            buttons.push(DetailButton {
                label: "Bake glyph".to_string(),
                action: DetailAction::BakeGlyph(cp as u32),
            });
        }
        // Refresh — palette command; useful when a sibling was
        // just installed on disk and the user wants to pick up
        // the new manifest without restarting mnml.
        buttons.push(DetailButton {
            label: "Refresh".to_string(),
            action: DetailAction::Command("integrations.refresh"),
        });
        // Edit manifest — opens the on-disk TOML in an editor pane.
        buttons.push(DetailButton {
            label: "Edit manifest".to_string(),
            action: DetailAction::OpenManifest(id.to_string()),
        });
        // Copy id — everyday convenience for pasting into a
        // chord binding / palette command / sibling install
        // script.
        buttons.push(DetailButton {
            label: "Copy id".to_string(),
            action: DetailAction::CopyId(id.to_string()),
        });

        commands = ic.commands.clone();
        for (label, opt_url) in [
            ("Homepage", ic.homepage.as_ref()),
            ("Repository", ic.repository.as_ref()),
            ("Docs", ic.docs.as_ref()),
        ] {
            if let Some(url) = opt_url
                && !url.trim().is_empty()
            {
                links.push((label.to_string(), url.trim().to_string()));
            }
        }
    }

    (buttons, commands, links)
}

/// Fire the action at `action_idx` for the integration `id`
/// currently open in `pane_id`. Called by both the keyboard
/// Enter path and the mouse click-router.
pub(crate) fn fire_action(app: &mut App, pane_id: PaneId, action_idx: usize) {
    let id = match app.panes.get(pane_id) {
        Some(Pane::IntegrationDetail(d)) => d.id.clone(),
        _ => return,
    };
    let icon = app
        .config
        .ui
        .integration_icons
        .iter()
        .find(|i| i.id == id)
        .cloned();
    let is_marketplace_only = icon.is_none() && app.marketplace_entries.iter().any(|e| e.id == id);
    let (buttons, commands, links) =
        build_actionable_with_marketplace(&id, icon.as_ref(), is_marketplace_only);
    let btn_n = buttons.len();
    let cmd_n = commands.len();
    let toast_msg = if action_idx < btn_n {
        let b = &buttons[action_idx];
        dispatch_detail_action(app, &b.action, &b.label)
    } else if action_idx < btn_n + cmd_n {
        let c = &commands[action_idx - btn_n];
        let ran = crate::command::run(&c.id, app);
        if ran {
            format!("Ran {}", c.id)
        } else {
            format!("Command `{}` not found", c.id)
        }
    } else {
        let (label, url) = &links[action_idx - btn_n - cmd_n];
        open_url(url);
        format!("Opened {label}")
    };
    if let Some(Pane::IntegrationDetail(d)) = app.panes.get_mut(pane_id) {
        d.set_action_toast(toast_msg);
    }
}

pub(crate) fn copy_link_url(app: &mut App, pane_id: PaneId, url: String) {
    let mut clip = crate::clipboard::Clipboard::new();
    clip.set(url.clone(), false);
    app.toast(format!("copied {url}"));
    if let Some(Pane::IntegrationDetail(d)) = app.panes.get_mut(pane_id) {
        d.set_action_toast(format!("Copied {url}"));
    }
}

fn dispatch_detail_action(app: &mut App, action: &DetailAction, label: &str) -> String {
    match action {
        DetailAction::Command(id) => {
            crate::command::run(id, app);
            format!("Fired {id}")
        }
        DetailAction::ToggleEnabled(id) => {
            // Route through the same helper the right-click menu
            // uses so behavior stays in ONE place (persist,
            // toast, etc).
            app.toggle_integration_enabled_by_id(id.as_str());
            format!("{label} · {id}")
        }
        DetailAction::Uninstall(id) => {
            app.open_integration_remove_confirm(id.clone());
            format!("Confirm to uninstall {id}")
        }
        DetailAction::OpenManifest(id) => {
            app.open_integration_manifest_by_id(id.as_str());
            format!("Opened manifest for {id}")
        }
        DetailAction::CopyId(id) => {
            let mut clip = crate::clipboard::Clipboard::new();
            clip.set(id.clone(), false);
            app.toast(format!("copied `{id}` to clipboard"));
            format!("Copied {id}")
        }
        DetailAction::BakeGlyph(cp) => {
            app.open_glyph_builder_for_cp(*cp);
            "Opened glyph builder".to_string()
        }
        DetailAction::RunPrimary(cmd) => {
            if let Some(rest) = cmd.strip_prefix(':') {
                app.run_ex_command(rest);
            } else {
                crate::command::run(cmd, app);
            }
            format!("Ran {cmd}")
        }
        DetailAction::InstallFromMarketplace(id) => {
            if let Some(idx) = app.marketplace_entries.iter().position(|e| e.id == *id) {
                app.open_marketplace_install_prompt(idx);
                format!("Confirm to install {id}")
            } else {
                app.toast(format!("marketplace entry `{id}` not found"));
                format!("no marketplace entry {id}")
            }
        }
    }
}

fn open_url(url: &str) {
    // Same fallback chain the tree / bufferline uses for external
    // paths — one attempt per platform.
    #[cfg(target_os = "macos")]
    let _ = std::process::Command::new("open").arg(url).spawn();
    #[cfg(target_os = "linux")]
    let _ = std::process::Command::new("xdg-open").arg(url).spawn();
    #[cfg(target_os = "windows")]
    let _ = std::process::Command::new("cmd")
        .args(["/C", "start", url])
        .spawn();
}

/// Return the count of actionable rows on the pane (buttons +
/// declared commands + links). Used by the keyboard handler to
/// clamp `cursor` on ↑/↓/Tab moves.
pub(crate) fn action_count(app: &App, pane_id: PaneId) -> usize {
    let id = match app.panes.get(pane_id) {
        Some(Pane::IntegrationDetail(d)) => d.id.clone(),
        _ => return 0,
    };
    let icon = app
        .config
        .ui
        .integration_icons
        .iter()
        .find(|i| i.id == id)
        .cloned();
    let (b, c, l) = build_actionable(&id, icon.as_ref());
    b.len() + c.len() + l.len()
}

fn truncate(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    let n = s.chars().count();
    if n <= max {
        return s.to_string();
    }
    let take = max.saturating_sub(1);
    let mut out: String = s.chars().take(take).collect();
    out.push('\u{2026}');
    out
}

/// Naive word-wrap for the description paragraph. Splits on
/// whitespace, greedy-fits words into rows up to `width` chars.
/// Preserves the caller's line breaks (an explicit `\n` in the
/// description becomes a paragraph break).
fn wrap_paragraph(text: &str, width: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if width == 0 {
        return out;
    }
    for para in text.split('\n') {
        let mut line = String::new();
        for word in para.split_whitespace() {
            if line.is_empty() {
                if word.chars().count() > width {
                    // Very long word — hard-split at width. Rare
                    // for descriptions but shows up for URLs
                    // accidentally pasted inline.
                    let mut buf = String::new();
                    for c in word.chars() {
                        if buf.chars().count() >= width {
                            out.push(std::mem::take(&mut buf));
                        }
                        buf.push(c);
                    }
                    line = buf;
                } else {
                    line.push_str(word);
                }
                continue;
            }
            if line.chars().count() + 1 + word.chars().count() > width {
                out.push(std::mem::take(&mut line));
                line.push_str(word);
            } else {
                line.push(' ');
                line.push_str(word);
            }
        }
        if !line.is_empty() {
            out.push(line);
        } else if para.is_empty() {
            out.push(String::new());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, IntegrationIcon, IntegrationIconCommand};

    fn sample_icon() -> IntegrationIcon {
        IntegrationIcon {
            id: "slack".to_string(),
            glyph: "S".to_string(),
            fallback: "Sk".to_string(),
            command: "slack.open".to_string(),
            color: "purple".to_string(),
            label: Some("Slack".to_string()),
            enabled: true,
            in_palette_bar: false,
            description: Some("Slack browse + post".to_string()),
            homepage: Some("https://example.com".to_string()),
            docs: None,
            repository: Some("https://github.com/example/slack".to_string()),
            author: Some("chris".to_string()),
            version: Some("0.1.0".to_string()),
            commands: vec![IntegrationIconCommand {
                id: "slack.open".to_string(),
                title: "Slack: open panel".to_string(),
            }],
        }
    }

    #[test]
    fn build_actionable_populates_buttons_commands_links() {
        let icon = sample_icon();
        let (buttons, commands, links) = build_actionable(&icon.id, Some(&icon));
        // Enable/Disable + Open + Uninstall + Bake + Refresh + Edit + Copy = 7.
        assert_eq!(
            buttons.len(),
            7,
            "expected 7 buttons, got {}",
            buttons.len()
        );
        assert_eq!(commands.len(), 1);
        // Only homepage + repository (no docs).
        assert_eq!(links.len(), 2);
        assert_eq!(links[0].0, "Homepage");
        assert_eq!(links[1].0, "Repository");
    }

    #[test]
    fn build_actionable_disable_label_flips_with_enabled() {
        let mut icon = sample_icon();
        icon.enabled = true;
        let (buttons, _, _) = build_actionable(&icon.id, Some(&icon));
        assert_eq!(buttons[0].label, "Disable");
        icon.enabled = false;
        let (buttons, _, _) = build_actionable(&icon.id, Some(&icon));
        assert_eq!(buttons[0].label, "Enable");
    }

    #[test]
    fn build_actionable_no_bake_when_glyph_empty() {
        let mut icon = sample_icon();
        icon.glyph.clear();
        let (buttons, _, _) = build_actionable(&icon.id, Some(&icon));
        assert!(!buttons.iter().any(|b| b.label == "Bake glyph"));
    }

    #[test]
    fn build_actionable_missing_icon_is_empty() {
        let (b, c, l) = build_actionable("missing-id", None);
        assert!(b.is_empty());
        assert!(c.is_empty());
        assert!(l.is_empty());
    }

    #[test]
    fn open_pane_creates_and_reveals() {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.ui.integration_icons.push(sample_icon());
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        // 2026-08-01 — detail pane now hosts in the center like
        // Editor/Request (user asked to move it out of the right
        // panel). Find the pane by its kind.
        app.open_integration_detail_pane("slack");
        let pid = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::IntegrationDetail(d) if d.id == "slack"))
            .unwrap();
        assert!(matches!(
            app.panes.get(pid),
            Some(Pane::IntegrationDetail(d)) if d.id == "slack"
        ));
        // Warm open (same id): reuses the pane instead of stacking.
        let before = app.panes.len();
        app.open_integration_detail_pane("slack");
        assert_eq!(app.panes.len(), before);
    }

    #[test]
    fn open_pane_refuses_unknown_id_with_toast() {
        let d = tempfile::tempdir().unwrap();
        let cfg = Config::default();
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        let panes_before = app.panes.len();
        app.open_integration_detail_pane("definitely-not-installed");
        assert_eq!(app.panes.len(), panes_before);
        assert!(app.toast.is_some());
    }

    #[test]
    fn action_count_matches_button_set() {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.ui.integration_icons.push(sample_icon());
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_integration_detail_pane("slack");
        // 2026-08-01 — detail pane hosts in the center now, not
        // the right panel. Find the newly-created pane by kind.
        let pid = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::IntegrationDetail(d) if d.id == "slack"))
            .unwrap();
        // 7 buttons + 1 command + 2 links = 10.
        assert_eq!(action_count(&app, pid), 10);
    }

    #[test]
    fn cursor_move_clamps_to_action_count() {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.ui.integration_icons.push(sample_icon());
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        app.open_integration_detail_pane("slack");
        // 2026-08-01 — detail pane hosts in the center now, not
        // the right panel. Find the newly-created pane by kind.
        let pid = app
            .panes
            .iter()
            .position(|p| matches!(p, Pane::IntegrationDetail(d) if d.id == "slack"))
            .unwrap();
        // Overshoot down + up — cursor must land at valid bounds.
        app.integration_detail_cursor_move(999);
        let cursor = match app.panes.get(pid) {
            Some(Pane::IntegrationDetail(d)) => d.cursor,
            _ => panic!(),
        };
        assert_eq!(cursor, action_count(&app, pid) - 1);
        app.integration_detail_cursor_move(-999);
        let cursor = match app.panes.get(pid) {
            Some(Pane::IntegrationDetail(d)) => d.cursor,
            _ => panic!(),
        };
        assert_eq!(cursor, 0);
    }

    #[test]
    fn toggle_enabled_helper_flips_state_and_toasts() {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.ui.integration_icons.push(sample_icon());
        let mut app = crate::app::App::new(d.path().to_path_buf(), cfg).unwrap();
        assert!(
            app.config
                .ui
                .integration_icons
                .iter()
                .find(|i| i.id == "slack")
                .unwrap()
                .enabled
        );
        app.toggle_integration_enabled_by_id("slack");
        assert!(
            !app.config
                .ui
                .integration_icons
                .iter()
                .find(|i| i.id == "slack")
                .unwrap()
                .enabled
        );
        assert!(app.toast.is_some());
    }
}
