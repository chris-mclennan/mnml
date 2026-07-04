//! The "tabufline" — a strip of open-buffer tabs (NvChad-style). It sits over
//! the pane body only, not above the tree rail. A small `TABS` cap is pinned to
//! the right.
//!
//! Right-hand cluster (NvChad parity): `+` new-tab button, `TABS` label,
//! tab-page chips (with per-tab `⊗` close), theme toggle (`◯`), window close
//! (`×`). Every segment registers its rect on `app.rects` so clicks route
//! to the corresponding command. See `App::tab_*` for the tab-page state.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use std::collections::HashMap;

use crate::app::App;
use crate::pane::Pane;
use crate::ui::{icons, theme};

// code-reviewer S3-1 — the dead `launcher_color` fn was removed.
// All callers go through `theme::color_from_slot(name, &t)` now.

/// `✗N` (errors) / `⚠N` (warnings) / `""` for editor panes; `""` for everything
/// else. Surfaced in the bufferline so broken buffers are visible without
/// switching to them.
fn diag_chip_for(p: &Pane) -> String {
    if let Pane::Editor(b) = p {
        let mut err = 0usize;
        let mut warn = 0usize;
        for d in b.all_diagnostics() {
            match d.severity {
                crate::lsp::Severity::Error => err += 1,
                crate::lsp::Severity::Warning => warn += 1,
                _ => {}
            }
        }
        if err > 0 {
            return format!("\u{2717}{err}");
        }
        if warn > 0 {
            return format!("\u{26A0}{warn}");
        }
    }
    String::new()
}

/// One label per pane in `app.panes`, in order. For editor panes whose bare
/// filename is shared with another open editor (e.g. five `mod.rs`), prepend
/// the immediate parent dir (`git/mod.rs`, `ai/mod.rs`) so the tabs are
/// distinguishable. Non-editor panes keep their original title.
fn tab_labels(panes: &[Pane]) -> Vec<String> {
    let mut name_counts: HashMap<String, usize> = HashMap::new();
    let mut titles: Vec<String> = Vec::with_capacity(panes.len());
    for p in panes {
        let t = p.title();
        titles.push(t.clone());
        if matches!(p, Pane::Editor(_)) {
            *name_counts.entry(t).or_default() += 1;
        }
    }
    for (i, p) in panes.iter().enumerate() {
        if let Pane::Editor(b) = p
            && let Some(path) = &b.path
            && name_counts.get(&titles[i]).copied().unwrap_or(0) > 1
            && let Some(parent) = path
                .parent()
                .and_then(|p| p.file_name())
                .and_then(|n| n.to_str())
        {
            titles[i] = format!("{parent}/{}", titles[i]);
        }
    }
    // design-critic Issue 7 — Pty tabs need an at-a-glance visual
    // marker so they don't read as just-another-tab. Append ` $`
    // (terminal-prompt convention) so 'terminal (zsh)' becomes
    // 'terminal (zsh) $'. Cheap, no new style logic needed.
    for (i, p) in panes.iter().enumerate() {
        if matches!(p, Pane::Pty(_)) {
            titles[i] = format!("{} $", titles[i]);
        }
    }
    titles
}

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::cur().bg_darker)),
        area,
    );
    app.rects.bufferline_tabs.clear();
    app.rects.bufferline_tab_close.clear();
    // 2026-06-22 — the right-cluster chip rects
    // (launcher_icon_rects / bufferline_new_tab_button /
    // bufferline_tab_page_* / bufferline_theme_toggle /
    // bufferline_window_close) are now populated by
    // `draw_palette_bar` (which runs BEFORE us in ui::draw).
    // Clearing them here would wipe the click targets the palette
    // bar just registered — the chips would still render but
    // wouldn't respond to clicks. Leave them alone.
    if area.width == 0 {
        return;
    }
    let nerd = !app.config.ui.ascii_icons;
    // Right cluster: launcher-icon chips on the LEFT edge of the cluster
    // (configurable count — Claude + Codex by default, more via
    // `[[ui.launcher_icon]]`), then ` + ` ` TABS ` per-tabpage chips
    // ` ●━ ` ` × `. Each launcher chip is 4 cells (` <glyph> ` + label
    // space). Pre-compute the total so the per-buffer tab strip's
    // scroll math reserves enough width.
    // The cluster lives on the palette-bar chrome row, not the
    // bufferline itself. The terminal + H/V split buttons (+ the
    // optional AI button) DO live on the bufferline — reserve the
    // rightmost `split_buttons_width(app)` cells for them so the
    // tab strip's scroll math doesn't run them over.
    let cluster_w = split_buttons_width(app);
    let tabs_max_x = area.x.saturating_add(area.width.saturating_sub(cluster_w));

    // Disambiguated labels — when two open editors share a filename, prepend
    // the parent dir to both (`git/mod.rs` vs `ai/mod.rs`).
    let labels = tab_labels(&app.panes);
    // Per-tab diagnostic chip — `✗N` for any errors, else `⚠N` for warnings,
    // else empty. Surfaced so the user sees broken buffers without opening
    // them. The chip sits between the name and the dirty badge.
    let diag_chips: Vec<String> = app.panes.iter().map(diag_chip_for).collect();
    // Pre-compute each tab's display width so we can scroll the bufferline to
    // keep the active tab on screen (and show `‹`/`›` overflow indicators).
    // Each tab is ` <icon> <name>[ <diag>] <badge> ` — base chrome is 4 cells
    // + name; diag chip (if any) adds its own char count + a leading space.
    let widths: Vec<u16> = labels
        .iter()
        .zip(&diag_chips)
        .map(|(name, diag)| {
            let mut w = 4u16 + name.chars().count() as u16 + 1u16;
            if !diag.is_empty() {
                w += diag.chars().count() as u16 + 1; // leading space
            }
            w
        })
        .collect();
    // 2026-06-27 — Pty panes (Claude / Codex / shell) are now
    // included in the bufferline alongside editors. They keep
    // their per-pane session strip for in-leaf switching, but
    // also show up here so the user has a single visual place
    // to see + close any pane.
    //
    // 2026-06-21 — VS Code-style pinned tabs sort to the FRONT.
    // Within the pinned + unpinned groups, original pane order is
    // preserved (so the user can still reorder via close/reopen).
    // mouse-hunter v3 SEV-2 E: panes hosted in the right side panel
    // are visible there — they shouldn't ALSO appear as bufferline
    // tabs (ghost duplicates). Filter them out before rendering.
    // qa-feature 2026-06-30 — GitGraph panes are viewers, not files.
    // Showing them in the bufferline alongside .ts / .rs / etc. felt
    // wrong (no "Untitled Document" semantics, can't save, etc.).
    // They stay reachable via the Git activity-bar icon and the
    // `:git.graph` command. Same skip applies to BrowserView /
    // Diagnostics / Outline / Tests viewer panes that have their own
    // surfaces (the right panel + activity-bar sections).
    let mut visible: Vec<usize> = (0..app.panes.len())
        .filter(|i| !app.right_panel_panes.contains(i))
        .filter(|i| !matches!(app.panes.get(*i), Some(Pane::GitGraph(_))))
        .collect();
    visible.sort_by_key(|&i| {
        let pinned = matches!(app.panes.get(i), Some(Pane::Editor(b)) if b.is_pinned);
        if pinned { 0 } else { 1 }
    });
    let sep = 1u16; // cell between tabs (rendered as the bg color)
    // qa-feature 2026-07-02 — both 3-cell scroll buttons live on the
    // RIGHT edge, side-by-side, just before the H/V split buttons.
    // Tab strip starts at the far left. User preference — the
    // buttons feel more like a paired scroll widget when they're
    // next to each other.
    let overflow_l = 0u16;
    let overflow_r = 6u16; // ‹ (3) + › (3)
    let inner_left = area.x + overflow_l;
    let inner_right = tabs_max_x.saturating_sub(overflow_r);
    let inner_width = inner_right.saturating_sub(inner_left);

    // Adjust `bufferline_first_visible` so it (a) doesn't run off the end of
    // the pane list, (b) includes the active tab, (c) is the smallest start
    // that keeps the active tab visible.
    if app.bufferline_first_visible >= visible.len() {
        app.bufferline_first_visible = visible.len().saturating_sub(1);
    }
    // qa-7th vscode SEV-2 2026-06-30 — when the user clicks ‹/›
    // chevrons, the auto-scroll-to-keep-active-tab-visible
    // clobbered the manual scroll. The chevron handler now stamps
    // app.bufferline_active_at_scroll = app.active; while that
    // stamp matches the current active pane, the auto-scroll
    // back-snap is suppressed. As soon as the user switches tabs,
    // the stamp clears and auto-scroll resumes.
    let user_scroll_pinned = app
        .bufferline_active_at_scroll
        .is_some_and(|p| Some(p) == app.active);
    if let Some(active_pos) = app
        .active
        .and_then(|a| visible.iter().position(|&p| p == a))
    {
        if active_pos < app.bufferline_first_visible {
            // Active tab is OFF the left edge — always honor this;
            // even with user_scroll_pinned, scrolling so far left
            // that the active tab is invisible is non-sense.
            app.bufferline_first_visible = active_pos;
            app.bufferline_active_at_scroll = None;
        } else if !user_scroll_pinned {
            // Walk back from the active tab while the cumulative width fits.
            let mut used = 0u16;
            let mut first = active_pos;
            loop {
                let w = widths[visible[first]] + if first > 0 { sep } else { 0 };
                if used + w > inner_width {
                    first += 1;
                    break;
                }
                used += w;
                if first == 0 {
                    break;
                }
                first -= 1;
            }
            if app.bufferline_first_visible < first {
                app.bufferline_first_visible = first;
            }
        }
    }
    let first_visible = app.bufferline_first_visible;

    let mut spans: Vec<Span> = Vec::new();
    // qa-feature 2026-07-02 — both scroll buttons now live on the
    // RIGHT (side-by-side), so nothing here. Tab strip starts at
    // area.x. The buttons are painted at the very end of this
    // function, next to the H/V split cluster.
    app.rects.bufferline_overflow_left = None;
    let mut x = area.x;
    // render-reviewer #3 — hoist theme::cur() so the per-tab loop
    // doesn't acquire its RwLock 27× per tab. With 30 panes that's
    // ~810 lock acquisitions/frame just from this branch.
    let tt = theme::cur();
    let mut last_drawn: usize = first_visible;
    let mut overflow_right = false;
    for vis_pos in first_visible..visible.len() {
        let i = visible[vis_pos];
        let pane = &app.panes[i];
        let active = app.active == Some(i);
        let name = labels[i].clone();
        let (glyph, icon_color) = match pane {
            Pane::Editor(b) => {
                let p = b.path.clone().unwrap_or_else(|| name.clone().into());
                icons::for_path(&p, false, false, nerd)
            }
            Pane::MdPreview(p) => icons::for_path(&p.path, false, false, nerd),
            Pane::Diff(_) => (if nerd { "\u{f0e7e}" } else { "±" }, tt.orange),
            Pane::GitGraph(_) => (if nerd { "\u{f1d3}" } else { "⎇" }, tt.orange),
            Pane::GitStatus(_) => (if nerd { "\u{f1d2}" } else { "±" }, tt.green),
            Pane::Request(_) => (if nerd { "\u{f0a3e}" } else { "⚡" }, tt.yellow),
            Pane::Pty(s) => {
                // 2026-07-03 — sibling integrations that run as
                // Pty panes (mnml-aws-amplify etc.) inherit their
                // integration's chip glyph so the tab icon
                // matches the rail chip the user clicked. Match
                // the profile label ("amplify" / "lambda" / …)
                // against the label of any known integration_icon
                // whose `run` command mentions the same binary.
                // Falls back to the generic terminal glyph when
                // the Pty isn't a sibling (shell, npm run, etc).
                let profile_label = s.profile.label.as_str();
                let sibling_glyph = app
                    .config
                    .ui
                    .integration_icons
                    .iter()
                    .find(|ic| {
                        let cmd = ic.command.as_str();
                        cmd.starts_with(":term ")
                            && cmd
                                .strip_prefix(":term ")
                                .and_then(|bin| bin.split('-').next_back())
                                .map(|last| last == profile_label)
                                .unwrap_or(false)
                    })
                    .map(|ic| (ic.glyph.clone(), theme::color_from_slot(&ic.color, &tt)));
                match sibling_glyph {
                    Some((g, c)) if nerd => (Box::leak(g.into_boxed_str()) as &str, c),
                    _ => (if nerd { "\u{f489}" } else { "▶" }, tt.teal),
                }
            }
            Pane::Ai(_) => (if nerd { "\u{f0e0a}" } else { "✦" }, tt.purple),
            Pane::Tests(_) => (if nerd { "\u{f0668}" } else { "✓" }, tt.green),
            Pane::Browser(_) => (if nerd { "\u{f059f}" } else { "◉" }, tt.blue),
            Pane::Diagnostics(_) => (if nerd { "\u{f0026}" } else { "⚠" }, tt.red),
            Pane::Grep(_) => (if nerd { "\u{f0349}" } else { "⌕" }, tt.yellow),
            Pane::Flaky(_) => (if nerd { "\u{f0668}" } else { "≋" }, tt.purple),
            Pane::Outline(_) => (if nerd { "\u{f01bd}" } else { "⌥" }, tt.purple),
            Pane::Quickfix(_) => (if nerd { "\u{f0349}" } else { "⌕" }, tt.teal),
            Pane::CmdlineHistory(_) => (if nerd { "\u{eb15}" } else { "❯" }, tt.comment),
            Pane::Cheatsheet(_) => (if nerd { "\u{f128}" } else { "?" }, tt.yellow),
            Pane::Debug(_) => (if nerd { "\u{f188}" } else { "🐛" }, tt.red),
            Pane::DapRepl(_) => (if nerd { "\u{F018D}" } else { ">" }, tt.cyan),
            Pane::Image(_) => (if nerd { "\u{F021F}" } else { "▤" }, tt.purple),
            Pane::ClaudeAgents(_) => (if nerd { "\u{F06A9}" } else { "◆" }, tt.purple),
            Pane::Websocket(_) => (if nerd { "\u{F0317}" } else { "◇" }, tt.teal),
            Pane::SpendReport(_) => (if nerd { "\u{F01C2}" } else { "$" }, tt.orange),
            Pane::Mount(_) => (if nerd { "\u{F0BD3}" } else { "M" }, tt.cyan),
            Pane::CloudAgentRun(_) => (if nerd { "\u{F0956}" } else { "☁" }, tt.blue),
            Pane::NewCloudAgentWizard(_) => (if nerd { "\u{F0FB1}" } else { "+" }, tt.green),
            Pane::NewCloudRunWizard(_) => (if nerd { "\u{F0FB1}" } else { "+" }, tt.cyan),
        };
        // Status badge priority:
        //   dirty   → ● / *  (orange — any tab)
        //   pinned  → 📌 / P  (yellow — any tab)
        //   else    → close glyph (× / x)
        // Pinned-badge added 2026-06-22 — user-feedback: the
        // pin should appear where the close-X is, not by
        // replacing the file-type icon on the left.
        let pinned_here = matches!(pane, Pane::Editor(b) if b.is_pinned);
        // Pinned wins over dirty — a pinned tab should ALWAYS
        // surface its pin glyph (matching VS Code's "pinned
        // overrides everything in the close slot" behavior).
        let badge = if pinned_here {
            if nerd { "\u{f08d}" } else { "P" }
        } else if pane.is_dirty() {
            if nerd { "●" } else { "*" }
        } else if nerd {
            "\u{F0156}"
        } else {
            "x"
        };
        let diag = &diag_chips[i];
        // ` <icon>  <name>[ <diag>] <badge> `
        // Two spaces between icon + name — 2026-07-03 third pass:
        // three (the previous fix) looked too airy once the actual
        // render path was fixed to match. Two is the balance point
        // for the wide nf-oct-terminal glyph vs the rest of the
        // icon set.
        let label = if diag.is_empty() {
            format!(" {glyph}  {name} {badge} ")
        } else {
            format!(" {glyph}  {name} {diag} {badge} ")
        };
        let cells = label.chars().count() as u16;
        if x + cells > inner_right {
            overflow_right = true;
            break;
        }
        last_drawn = vis_pos;
        // qa-8th render W-1 2026-06-30 — was calling theme::cur()
        // 5-7 times per tab here (and 2 more times below for diag
        // chip + separator). With 30 tabs that's ~200 RwLock
        // acquisitions per frame. `tt` was already hoisted at
        // line 244 for the icon-color path; reuse it everywhere
        // the per-tab colors are read.
        let (bg, name_fg, badge_fg) = if active {
            (
                tt.bg,
                tt.fg,
                if pane.is_dirty() {
                    tt.orange
                } else if pinned_here {
                    tt.yellow
                } else {
                    tt.grey_fg
                },
            )
        } else {
            (
                tt.bg_darker,
                tt.grey_fg,
                if pinned_here { tt.yellow } else { tt.grey },
            )
        };
        let mut name_style = Style::default().fg(name_fg).bg(bg);
        if active {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        // VS Code preview tab: italic name (the visual signal that
        // this tab is replaceable on the next tree-click, until
        // promoted by an edit). Only Editor panes carry the flag.
        if let Pane::Editor(b) = pane
            && b.is_preview
        {
            name_style = name_style.add_modifier(Modifier::ITALIC);
        }
        // 2026-06-22 — pinned tabs keep the file-type glyph
        // (pin moved to the right-side badge). Icons keep their
        // natural devicon color on every tab — active or
        // inactive — so file types stay recognizable at a
        // glance (matches NvChad's tabufline).
        //
        // 2026-07-03 padding bug — earlier fixes touched the
        // width-precompute string at the top of this fn but
        // MISSED this actual span-render path. The " {glyph} "
        // single-space form was what actually painted, so the
        // wide-cell Nerd Font terminal glyph visually kissed
        // the label. Match the 3-space padding used in the
        // width string so hitboxes + visuals stay aligned.
        spans.push(Span::styled(
            format!(" {glyph}  "),
            Style::default().fg(icon_color).bg(bg),
        ));
        spans.push(Span::styled(format!("{name} "), name_style));
        if !diag.is_empty() {
            let diag_fg = if diag.starts_with('\u{2717}') {
                // `✗` chip — errors → red regardless of active state.
                tt.red
            } else {
                // `⚠` chip — warnings → yellow.
                tt.yellow
            };
            spans.push(Span::styled(
                format!("{diag} "),
                Style::default().fg(diag_fg).bg(bg),
            ));
        }
        spans.push(Span::styled(
            format!("{badge} "),
            Style::default().fg(badge_fg).bg(bg),
        ));
        app.rects.bufferline_tabs.push((
            Rect {
                x,
                y: area.y,
                width: cells,
                height: 1,
            },
            i,
        ));
        // the close target = the badge + its trailing space (the last 2 cells of the tab)
        if cells >= 2 {
            app.rects.bufferline_tab_close.push((
                Rect {
                    x: x + cells - 2,
                    y: area.y,
                    width: 2,
                    height: 1,
                },
                i,
            ));
        }
        x += cells;
        // thin separator into the strip background
        if vis_pos + 1 < visible.len() {
            spans.push(Span::styled(" ", Style::default().bg(tt.bg_darker)));
            x += 1;
        }
    }
    if visible.is_empty() {
        // qa-feature 2026-06-30 — "no buffers" is misleading when
        // a non-bufferline pane (GitGraph / Pty) is the only thing
        // open. Show a hint describing the pane instead.
        let hint = match app.active.and_then(|i| app.panes.get(i)) {
            Some(Pane::GitGraph(_)) => "  git graph ",
            Some(Pane::Pty(_)) => "  terminal ",
            _ => "  no buffers ",
        };
        spans.push(Span::styled(
            hint,
            Style::default()
                .fg(theme::cur().grey_fg)
                .bg(theme::cur().bg_darker),
        ));
        x += hint.chars().count() as u16;
    }
    // Are there tabs past the right edge? (Either we broke out of the render
    // loop, or there are tabs after the last one we drew that we never reached.)
    let more_right = overflow_right || (last_drawn + 1 < visible.len());
    // qa-feature 2026-07-02 — fill the gap up to the paired-arrow
    // cluster, then paint `‹` and `›` side-by-side.
    let fill_end = inner_right;
    if x < fill_end {
        spans.push(Span::styled(
            " ".repeat((fill_end - x) as usize),
            Style::default().bg(theme::cur().bg_darker),
        ));
    }
    // Left arrow (paints at inner_right..inner_right+3).
    let left_enabled = first_visible > 0;
    let l_fg = if left_enabled {
        theme::cur().blue
    } else {
        theme::cur().comment
    };
    spans.push(Span::styled(
        " ‹ ",
        Style::default()
            .fg(l_fg)
            .bg(theme::cur().bg_darker)
            .add_modifier(Modifier::BOLD),
    ));
    if left_enabled {
        app.rects.bufferline_overflow_left = Some(ratatui::layout::Rect {
            x: inner_right,
            y: area.y,
            width: 3,
            height: 1,
        });
    } else {
        app.rects.bufferline_overflow_left = None;
    }
    // Right arrow (paints at inner_right+3..inner_right+6).
    let r_fg = if more_right {
        theme::cur().blue
    } else {
        theme::cur().comment
    };
    spans.push(Span::styled(
        " › ",
        Style::default()
            .fg(r_fg)
            .bg(theme::cur().bg_darker)
            .add_modifier(Modifier::BOLD),
    ));
    if more_right {
        app.rects.bufferline_overflow_right = Some(ratatui::layout::Rect {
            x: inner_right + 3,
            y: area.y,
            width: 3,
            height: 1,
        });
    } else {
        app.rects.bufferline_overflow_right = None;
    }
    let _ = last_drawn;

    // Right cluster (launcher icons, `+`, TABS chips, theme
    // toggle, close) lives on the palette-bar chrome row.
    // Bufferline paints the file-tab strip + the H/V split
    // buttons at the right end.
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
    paint_split_buttons(frame, app, area);
}

/// Width in cells of the right-cluster chrome (launcher icons +
/// `+` + `TABS` + tab-page chips + theme toggle + close). Split
/// buttons are NOT part of this — they live on the bufferline
/// (tab bar) right end, not the chrome row.
pub fn right_cluster_width(app: &App) -> u16 {
    // 2026-06-27 — launchers + integrations now paint in the gap
    // between the palette dropdown and this cluster (closer to
    // where the user expects to find them). The right cluster
    // is just: ` + ` new-tab + ` TABS ` + tab-page chips + theme
    // + close.
    let _ = app.config.ui.launcher_icons.len();
    let mut w: u16 = 3 + 6;
    for i in 0..app.layouts.len() {
        let dig = (i + 1).to_string().chars().count() as u16;
        let dirty = if app.tab_has_dirty_buffer(i) { 1 } else { 0 };
        w += 2 + dig + dirty;
        if i == app.active_layout {
            w += 2;
        }
    }
    // theme toggle pill + ` × ` window close
    w += 4 + 3;
    w
}

/// 2026-06-22 — does the right cluster fit at full width without
/// overlapping the centered workspace chip? Returns `(cluster_left,
/// width)` to paint, or `None` to hide entirely. No intermediate
/// stages — user preference is "full or gone", not progressive.
///
/// Pure function — extracted so unit tests can exercise the
/// boundaries without spinning up a full ratatui Terminal. Used
/// by `draw_palette_bar` in `src/ui/mod.rs`.
pub fn pick_cluster_mode(
    area_x: u16,
    area_w: u16,
    palette_right_edge: u16,
    full_w: u16,
    gap: u16,
) -> Option<u16> {
    let cluster_left = area_x + area_w.saturating_sub(full_w);
    if cluster_left >= palette_right_edge + gap {
        Some(full_w)
    } else {
        None
    }
}

/// mouse-user SEV-2 — width of the compact cluster (when the full
/// cluster doesn't fit). Keeps the most-clicked chrome
/// (+ new-tab, theme toggle, × window-close); drops TABS label
/// and per-tab-page chips. Returns `(width, fits)`.
pub fn compact_cluster_width() -> u16 {
    // ` + ` (3) + theme toggle pill (4) + ` × ` (3)
    3 + 4 + 3
}

/// Pick the BEST cluster mode that fits — full, compact, or none.
/// Returns `(width, is_compact)`.
pub fn pick_cluster_mode_tiered(
    area_x: u16,
    area_w: u16,
    palette_right_edge: u16,
    full_w: u16,
    gap: u16,
) -> Option<(u16, bool)> {
    if let Some(w) = pick_cluster_mode(area_x, area_w, palette_right_edge, full_w, gap) {
        return Some((w, false));
    }
    let compact_w = compact_cluster_width();
    let cluster_left = area_x + area_w.saturating_sub(compact_w);
    if cluster_left >= palette_right_edge + gap {
        Some((compact_w, true))
    } else {
        None
    }
}

/// Paint the NvChad-style right cluster (launcher icons · `+` ·
/// `TABS` · tab-page chips · theme toggle · close) starting at
/// `area.x` for up to `area.width` cells. Each segment registers
/// its click rect in `app.rects` so the existing mouse dispatcher
/// continues to work. `bg` is the column background (palette bar
/// uses `bg_dark`, bufferline uses `bg_darker`).
///
/// Extracted from bufferline::draw so the palette bar (mnml's
/// chrome row) can host this cluster.
///
/// Always-clear semantics: callers don't need to pre-clear the
/// click-target rects. This fn resets every rect it might write
/// at entry, so a stale rect from a previous frame (cluster hidden
/// at a narrower width) can't steal a click.
pub fn paint_right_cluster(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    bg: ratatui::style::Color,
    compact: bool,
) {
    // Always-clear: stale rects from a prior-frame paint at a
    // wider width would otherwise stay registered and steal
    // clicks at cells we're no longer painting. (launcher_icon_rects
    // clear lives in ui::draw entry now — see api-workflow-user F2.)
    app.rects.bufferline_new_tab_button = None;
    app.rects.bufferline_tab_page_chips.clear();
    app.rects.bufferline_tab_page_close.clear();
    app.rects.bufferline_theme_toggle = None;
    app.rects.bufferline_window_close = None;

    if area.width == 0 {
        return;
    }
    let t = theme::cur();
    let nerd = !app.config.ui.ascii_icons;
    let mut spans: Vec<Span> = Vec::new();
    let mut cluster_x = area.x;

    // Split buttons moved to the bufferline (tab bar) right end —
    // see `paint_split_buttons` below.

    // Launcher icons moved to the gap painter — see
    // `paint_integration_chips_in_gap`. The far-right cluster is
    // chrome-only.
    // `+` new-tab button. api-workflow-user F5 — honor --ascii.
    let plus_glyph = if nerd { "\u{F0415}" } else { "+" };
    spans.push(Span::styled(
        format!(" {plus_glyph} "),
        Style::default().fg(t.fg).bg(t.bg2),
    ));
    app.rects.bufferline_new_tab_button = Some(Rect {
        x: cluster_x,
        y: area.y,
        width: 3,
        height: 1,
    });
    cluster_x += 3;
    if !compact {
        // `TABS` label (decorative).
        spans.push(Span::styled(
            " TABS ",
            Style::default()
                .fg(t.bg_darker)
                .bg(t.fg)
                .add_modifier(Modifier::BOLD),
        ));
        cluster_x += 6;
        // Per-tab-page chips with close on active.
        for i in 0..app.layouts.len() {
            let active = i == app.active_layout;
            let dirty = app.tab_has_dirty_buffer(i);
            let label = if dirty {
                format!(" \u{25CF}{} ", i + 1)
            } else {
                format!(" {} ", i + 1)
            };
            let label_w = label.chars().count() as u16;
            let (chip_fg, chip_bg) = if active {
                (t.bg_darker, t.blue)
            } else {
                (t.fg, t.bg2)
            };
            let mut chip_style = Style::default().fg(chip_fg).bg(chip_bg);
            if active {
                chip_style = chip_style.add_modifier(Modifier::BOLD);
            }
            spans.push(Span::styled(label, chip_style));
            app.rects.bufferline_tab_page_chips.push((
                Rect {
                    x: cluster_x,
                    y: area.y,
                    width: label_w,
                    height: 1,
                },
                i,
            ));
            cluster_x += label_w;
            if active {
                let close = if nerd { "\u{F0156} " } else { "x " };
                spans.push(Span::styled(
                    close,
                    Style::default().fg(chip_fg).bg(chip_bg),
                ));
                app.rects.bufferline_tab_page_close.push((
                    Rect {
                        x: cluster_x,
                        y: area.y,
                        width: 1,
                        height: 1,
                    },
                    i,
                ));
                cluster_x += 2;
            }
        }
    }
    // Theme toggle pill.
    {
        let on_alt = app
            .config
            .ui
            .theme_toggle
            .as_deref()
            .is_some_and(|alt| theme::cur().name.eq_ignore_ascii_case(alt));
        spans.push(Span::styled(" ", Style::default().bg(t.bg2)));
        if on_alt {
            spans.push(Span::styled(
                "\u{2501}",
                Style::default().fg(t.comment).bg(t.bg2),
            ));
            spans.push(Span::styled(
                "\u{25CF}",
                Style::default().fg(t.fg).bg(t.bg2),
            ));
        } else {
            spans.push(Span::styled(
                "\u{25CF}",
                Style::default().fg(t.fg).bg(t.bg2),
            ));
            spans.push(Span::styled(
                "\u{2501}",
                Style::default().fg(t.comment).bg(t.bg2),
            ));
        }
        spans.push(Span::styled(" ", Style::default().bg(t.bg2)));
        app.rects.bufferline_theme_toggle = Some(Rect {
            x: cluster_x,
            y: area.y,
            width: 4,
            height: 1,
        });
        cluster_x += 4;
    }
    // Window close (always present — Minimal still keeps it).
    spans.push(Span::styled(
        " \u{F0156} ",
        Style::default()
            .fg(t.bg_darker)
            .bg(t.red)
            .add_modifier(Modifier::BOLD),
    ));
    app.rects.bufferline_window_close = Some(Rect {
        x: cluster_x,
        y: area.y,
        width: 3,
        height: 1,
    });
    let _ = cluster_x;
    let _ = bg; // bg currently unused; future styling pass may use it.
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// Width in cells of the split-buttons cluster — terminal +
/// H + V buttons, 3 cells each = 9. Painted at the bufferline's
/// right end so single-leaf (no-split) layouts have a mouse-
/// discoverable split + terminal path even when the per-leaf
/// tab strip doesn't paint its own buttons.
pub const SPLIT_BUTTONS_W: u16 = 9;
/// Width when the optional AI button is enabled (3 base buttons + 1).
pub const SPLIT_BUTTONS_W_WITH_AI: u16 = 12;

/// Total width the cluster needs given the user's config.
pub fn split_buttons_width(app: &App) -> u16 {
    if app.config.ui.tab_bar_ai_icon == "none" {
        SPLIT_BUTTONS_W
    } else {
        SPLIT_BUTTONS_W_WITH_AI
    }
}

/// Paint the AI (optional) + terminal + H / V split buttons at the
/// right end of `area`. Registers click rects in:
///   - `app.rects.split_strip_ai_buttons` (AI launch)
///   - `app.rects.split_strip_term_buttons` (terminal)
///   - `app.rects.split_strip_buttons` (H/V)
/// No-op when there's no active leaf.
pub fn paint_split_buttons(frame: &mut Frame, app: &mut App, area: Rect) {
    let total_w = split_buttons_width(app);
    if area.width < total_w {
        return;
    }
    let Some(active) = app.active else {
        return;
    };
    let t = theme::cur();
    let nerd = !app.config.ui.ascii_icons;
    // Glyph naming follows the *visual* layout the icon depicts,
    // not the `SplitDir` axis label (which is the rotation that
    // CREATES that layout):
    //   - `\u{eb56}` nf-cod-split_horizontal — side-by-side boxes
    //     with a vertical divider; paired with SplitDir::Horizontal
    //     ("split right").
    //   - `\u{eb57}` nf-cod-split_vertical — stacked boxes with a
    //     horizontal divider; paired with SplitDir::Vertical
    //     ("split down").
    //   - `\u{ea85}` nf-cod-terminal — click opens a new shell in
    //     a split below the active leaf.
    //   - `\u{F8B0}` / `\u{F8B1}` — mnml-patched Claude Code / Codex
    //     brand glyphs. Painted only when `[ui] tab_bar_ai_icon` is
    //     set to a non-"none" value.
    let term_glyph = if nerd { "\u{ea85}" } else { "$" };
    let side_by_side_glyph = if nerd { "\u{eb56}" } else { "|" };
    let stacked_glyph = if nerd { "\u{eb57}" } else { "-" };
    let bg = t.bg_darker;
    let mut bx = area.x + area.width - total_w;

    // AI button (leftmost in the cluster) — only when configured.
    let ai_kind = app.config.ui.tab_bar_ai_icon.as_str();
    if ai_kind != "none" {
        let (ai_glyph, ai_fallback, ai_fg) = theme::ai_chip_parts(ai_kind, &t);
        let glyph = if nerd { ai_glyph } else { ai_fallback };
        let ai_rect = Rect {
            x: bx,
            y: area.y,
            width: 3,
            height: 1,
        };
        let ai_line = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(glyph, Style::default().fg(ai_fg).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
        ]);
        frame.render_widget(Paragraph::new(ai_line), ai_rect);
        app.rects.split_strip_ai_buttons.push((ai_rect, active));
        bx += 3;
    }

    // Terminal button.
    let term_rect = Rect {
        x: bx,
        y: area.y,
        width: 3,
        height: 1,
    };
    let term_line = Line::from(vec![
        Span::styled(" ", Style::default().bg(bg)),
        Span::styled(term_glyph, Style::default().fg(t.comment).bg(bg)),
        Span::styled(" ", Style::default().bg(bg)),
    ]);
    frame.render_widget(Paragraph::new(term_line), term_rect);
    app.rects.split_strip_term_buttons.push((term_rect, active));
    bx += 3;

    // Split buttons — glyph paired with action that CREATES that layout.
    for (glyph, dir) in [
        (side_by_side_glyph, crate::layout::SplitDir::Horizontal),
        (stacked_glyph, crate::layout::SplitDir::Vertical),
    ] {
        let btn_rect = Rect {
            x: bx,
            y: area.y,
            width: 3,
            height: 1,
        };
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(bg)),
            Span::styled(glyph, Style::default().fg(t.comment).bg(bg)),
            Span::styled(" ", Style::default().bg(bg)),
        ]);
        frame.render_widget(Paragraph::new(line), btn_rect);
        app.rects.split_strip_buttons.push((btn_rect, active, dir));
        bx += 3;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::buffer::Buffer;
    use crate::config::Config;
    use std::fs;
    use std::path::PathBuf;

    fn ed(path: PathBuf) -> Pane {
        let b = Buffer::open(&path, &Config::default()).unwrap();
        Pane::Editor(b)
    }

    #[test]
    fn diag_chip_prefers_errors_then_warnings_then_empty() {
        use crate::lsp::{Diagnostic, Pos, Range, Severity};
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.rs"), "").unwrap();
        let path = d.path().join("a.rs");
        let r = Range {
            start: Pos {
                line: 0,
                character: 0,
            },
            end: Pos {
                line: 0,
                character: 0,
            },
        };
        let mk = |diags: Vec<Diagnostic>| {
            let mut b = Buffer::open(&path, &Config::default()).unwrap();
            b.diagnostics = diags;
            Pane::Editor(b)
        };
        // clean
        assert_eq!(diag_chip_for(&mk(vec![])), "");
        // 2 warnings → ⚠2
        let warn = || Diagnostic {
            range: r,
            severity: Severity::Warning,
            message: "w".into(),
            source: None,
        };
        assert_eq!(diag_chip_for(&mk(vec![warn(), warn()])), "\u{26A0}2");
        // mix → errors win
        let err = Diagnostic {
            range: r,
            severity: Severity::Error,
            message: "e".into(),
            source: None,
        };
        assert_eq!(diag_chip_for(&mk(vec![warn(), warn(), err])), "\u{2717}1");
    }

    #[test]
    fn disambiguates_only_when_colliding() {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path();
        fs::create_dir(ws.join("git")).unwrap();
        fs::create_dir(ws.join("ai")).unwrap();
        fs::write(ws.join("git").join("mod.rs"), "// git\n").unwrap();
        fs::write(ws.join("ai").join("mod.rs"), "// ai\n").unwrap();
        fs::write(ws.join("lib.rs"), "// lib\n").unwrap();
        let panes = vec![
            ed(ws.join("git").join("mod.rs")),
            ed(ws.join("ai").join("mod.rs")),
            ed(ws.join("lib.rs")),
        ];
        let labels = tab_labels(&panes);
        assert_eq!(labels[0], "git/mod.rs");
        assert_eq!(labels[1], "ai/mod.rs");
        assert_eq!(labels[2], "lib.rs");
    }

    /// Render-assertion: paint the real `draw` into a `TestBackend` and
    /// check both open buffers' tab labels actually land on the strip.
    #[test]
    fn draw_paints_open_buffer_tabs() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        fs::write(ws.join("alpha.txt"), "first\n").unwrap();
        fs::write(ws.join("beta.txt"), "second\n").unwrap();
        // vim input_style so both opens produce pinned tabs — under
        // standard mode the second open would replace alpha's preview
        // and the bufferline would only show beta.
        let mut cfg = Config::default();
        cfg.editor.input_style = "vim".to_string();
        let mut app = App::new(ws.clone(), cfg).unwrap();
        app.open_path(&ws.join("alpha.txt"));
        app.open_path(&ws.join("beta.txt"));

        let mut term = Terminal::new(TestBackend::new(120, 1)).unwrap();
        term.draw(|f| draw(f, &mut app, f.area())).unwrap();
        let buf = term.backend().buffer();
        let row: String = (0..buf.area.width).map(|x| buf[(x, 0)].symbol()).collect();
        assert!(
            row.contains("alpha.txt"),
            "tab strip missing alpha.txt: {row:?}"
        );
        assert!(
            row.contains("beta.txt"),
            "tab strip missing beta.txt: {row:?}"
        );
    }

    // 2026-06-22 — full-or-hidden cluster-mode picker tests.
    // No intermediate stages — user preference is "if it fits
    // paint everything, else hide it all".
    #[test]
    fn pick_cluster_mode_shows_full_at_generous_width() {
        // 200 cells, chip ends at col 60. Full (50): left=150.
        // 150 >= 60+4 ✓.
        let mode = pick_cluster_mode(0, 200, 60, 50, 4);
        assert_eq!(mode, Some(50));
    }

    #[test]
    fn pick_cluster_mode_hides_when_cluster_would_overlap() {
        // 100 cells, chip ends at col 60. Full (50): left=50.
        // 50 < 60+4 — hide.
        let mode = pick_cluster_mode(0, 100, 60, 50, 4);
        assert_eq!(mode, None);
    }

    #[test]
    fn pick_cluster_mode_respects_area_x_offset() {
        // bar offset to col 5; full (50): left=5+100-50=55.
        // chip end 65, need >= 69. 55 < 69 → hide.
        let mode = pick_cluster_mode(5, 100, 65, 50, 4);
        assert_eq!(mode, None);
    }

    #[test]
    fn pick_cluster_mode_gap_zero_lets_cluster_touch_palette() {
        // gap=0; full (50) → left=50, ≥ 50. Paint.
        let mode = pick_cluster_mode(0, 100, 50, 50, 0);
        assert_eq!(mode, Some(50));
    }

    #[test]
    fn pick_cluster_mode_saturating_sub_doesnt_crash_on_tiny_widths() {
        let mode = pick_cluster_mode(0, 10, 60, 50, 4);
        assert_eq!(mode, None);
    }

    #[test]
    fn pick_cluster_mode_zero_width_returns_none() {
        let mode = pick_cluster_mode(0, 0, 0, 50, 4);
        assert_eq!(mode, None);
    }
}
