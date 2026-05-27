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

/// Map a `LauncherIcon.color` slot name (`"orange"`, `"cyan"`, …) to
/// the active theme's `Color`. Unknown slot ⇒ `bg2` (neutral chip).
fn launcher_color(t: &theme::Theme, name: &str) -> ratatui::style::Color {
    match name {
        "orange" => t.orange,
        "cyan" => t.cyan,
        "blue" => t.blue,
        "green" => t.green,
        "yellow" => t.yellow,
        "purple" => t.purple,
        "red" => t.red,
        "teal" => t.teal,
        _ => t.bg2,
    }
}

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
    titles
}

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::cur().bg_darker)),
        area,
    );
    app.rects.bufferline_tabs.clear();
    app.rects.bufferline_tab_close.clear();
    app.rects.bufferline_new_tab_button = None;
    app.rects.bufferline_tab_page_chips.clear();
    app.rects.bufferline_tab_page_close.clear();
    app.rects.bufferline_theme_toggle = None;
    app.rects.bufferline_window_close = None;
    app.rects.launcher_icon_rects.clear();
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
    let n_tabs = app.layouts.len();
    let n_launcher = app.config.ui.launcher_icons.len() as u16;
    let mut right_w: u16 = 3 * n_launcher + 3 + 6; // launchers + ` + ` + ` TABS `
    for i in 0..n_tabs {
        // Active = ` <n>󰅖 ` (3 cells label + 2 cells close glyph).
        // Inactive = ` <n> ` (3 cells label only). Dirty tab gets a
        // leading `●` → +1 cell.
        let dig = (i + 1).to_string().chars().count() as u16;
        let dirty = if app.tab_has_dirty_buffer(i) { 1 } else { 0 };
        right_w += 2 + dig + dirty;
        if i == app.active_layout {
            right_w += 2; // close glyph + trailing space
        }
    }
    right_w += 4 + 3; // ` ●━ ` + ` × `
    let tabs_max_x = area.x + area.width.saturating_sub(right_w);

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
    // pty panes (Claude / Codex / shell) carry their own in-pane tab
    // strip, so they don't also get a bufferline tab. `visible` is the
    // ordered PaneIds the strip shows; `bufferline_first_visible` and
    // the scroll math index into it, not `app.panes`.
    let visible: Vec<usize> = (0..app.panes.len())
        .filter(|&i| !matches!(app.panes[i], Pane::Pty(_)))
        .collect();
    let sep = 1u16; // cell between tabs (rendered as the bg color)
    // Reserve 2 cells on each side of the tab strip for the overflow chevrons
    // when there's content past the edge.
    let overflow_l = 1u16;
    let overflow_r = 1u16;
    let inner_left = area.x + overflow_l;
    let inner_right = tabs_max_x.saturating_sub(overflow_r);
    let inner_width = inner_right.saturating_sub(inner_left);

    // Adjust `bufferline_first_visible` so it (a) doesn't run off the end of
    // the pane list, (b) includes the active tab, (c) is the smallest start
    // that keeps the active tab visible.
    if app.bufferline_first_visible >= visible.len() {
        app.bufferline_first_visible = visible.len().saturating_sub(1);
    }
    if let Some(active_pos) = app
        .active
        .and_then(|a| visible.iter().position(|&p| p == a))
    {
        if active_pos < app.bufferline_first_visible {
            app.bufferline_first_visible = active_pos;
        } else {
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
    // Left overflow chevron — only painted if there's a tab off the left edge.
    let left_chev_used = if first_visible > 0 {
        spans.push(Span::styled(
            "‹",
            Style::default()
                .fg(theme::cur().blue)
                .bg(theme::cur().bg_darker),
        ));
        // Register the click rect so the mouse handler can scroll left on click.
        app.rects.bufferline_overflow_left = Some(ratatui::layout::Rect {
            x: area.x,
            y: area.y,
            width: 1,
            height: 1,
        });
        1
    } else {
        spans.push(Span::styled(
            " ",
            Style::default().bg(theme::cur().bg_darker),
        ));
        1
    };
    let mut x = area.x + left_chev_used as u16;
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
            Pane::Diff(_) => (if nerd { "\u{f0e7e}" } else { "±" }, theme::cur().orange),
            Pane::GitGraph(_) => (if nerd { "\u{f1d3}" } else { "⎇" }, theme::cur().orange),
            Pane::GitStatus(_) => (if nerd { "\u{f1d2}" } else { "±" }, theme::cur().green),
            Pane::Request(_) => (if nerd { "\u{f0a3e}" } else { "⚡" }, theme::cur().yellow),
            Pane::Pty(_) => (if nerd { "\u{f489}" } else { "▶" }, theme::cur().teal),
            Pane::Ai(_) => (if nerd { "\u{f0e0a}" } else { "✦" }, theme::cur().purple),
            Pane::Tests(_) => (if nerd { "\u{f0668}" } else { "✓" }, theme::cur().green),
            Pane::Trace(_) => (if nerd { "\u{f0e62}" } else { "⏱" }, theme::cur().teal),
            Pane::Browser(_) => (if nerd { "\u{f059f}" } else { "◉" }, theme::cur().blue),
            Pane::Diagnostics(_) => (if nerd { "\u{f0026}" } else { "⚠" }, theme::cur().red),
            Pane::Grep(_) => (if nerd { "\u{f0349}" } else { "⌕" }, theme::cur().yellow),
            Pane::Flaky(_) => (if nerd { "\u{f0668}" } else { "≋" }, theme::cur().purple),
            Pane::Outline(_) => (if nerd { "\u{f01bd}" } else { "⌥" }, theme::cur().purple),
            Pane::Quickfix(_) => (if nerd { "\u{f0349}" } else { "⌕" }, theme::cur().teal),
            Pane::CmdlineHistory(_) => (if nerd { "\u{eb15}" } else { "❯" }, theme::cur().comment),
            Pane::BitbucketPipelines(_) => (if nerd { "\u{f171}" } else { "⌥" }, theme::cur().cyan),
            Pane::BitbucketPullRequests(_) => {
                (if nerd { "\u{f407}" } else { "⇄" }, theme::cur().cyan)
            }
            Pane::BitbucketPipelineLog(_) => {
                (if nerd { "\u{f120}" } else { "≡" }, theme::cur().cyan)
            }
            Pane::GithubActions(_) => (if nerd { "\u{f09b}" } else { "⚙" }, theme::cur().purple),
            Pane::GithubPullRequests(_) => {
                (if nerd { "\u{f407}" } else { "⇄" }, theme::cur().purple)
            }
            Pane::GitlabPipelines(_) => (if nerd { "\u{f171}" } else { "▴" }, theme::cur().orange),
            Pane::GitlabMergeRequests(_) => {
                (if nerd { "\u{f407}" } else { "⇄" }, theme::cur().orange)
            }
            Pane::AzDevOpsBuilds(_) => (if nerd { "\u{f171}" } else { "⚡" }, theme::cur().blue),
            Pane::AzDevOpsPullRequests(_) => {
                (if nerd { "\u{f407}" } else { "⇄" }, theme::cur().blue)
            }
            #[cfg(feature = "aws-codebuild")]
            Pane::CodeBuilds(_) => (if nerd { "\u{f487}" } else { "⚒" }, theme::cur().orange),
            #[cfg(feature = "aws-codebuild")]
            Pane::LogTail(_) => (if nerd { "\u{f120}" } else { "≡" }, theme::cur().teal),
            // nf-mdi-application-cog — generic "hosted external app" glyph.
            Pane::BlitHost(_) => (if nerd { "\u{F0EAA}" } else { "▤" }, theme::cur().purple),
            Pane::Cheatsheet(_) => (if nerd { "\u{f128}" } else { "?" }, theme::cur().yellow),
            Pane::Debug(_) => (if nerd { "\u{f188}" } else { "🐛" }, theme::cur().red),
            // nf-md-console (terminal arrow) — REPL prompt vibe.
            Pane::DapRepl(_) => (if nerd { "\u{F018D}" } else { ">" }, theme::cur().cyan),
            // nf-md-image
            Pane::Image(_) => (if nerd { "\u{F021F}" } else { "▤" }, theme::cur().purple),
        };
        // Dirty: filled circle. Clean: `nf-md-close` (\u{F0156}) — same
        // Material-Design glyph NvChad uses for buffer close, renders
        // substantially larger than the ASCII `×` (which JetBrainsMono
        // Nerd Font draws as a tiny multiplication sign).
        let badge = if pane.is_dirty() { "●" } else { "\u{F0156}" };
        let diag = &diag_chips[i];
        // ` <icon> <name>[ <diag>] <badge> `
        let label = if diag.is_empty() {
            format!(" {glyph} {name} {badge} ")
        } else {
            format!(" {glyph} {name} {diag} {badge} ")
        };
        let cells = label.chars().count() as u16;
        if x + cells > inner_right {
            overflow_right = true;
            break;
        }
        last_drawn = vis_pos;
        let (bg, name_fg, badge_fg) = if active {
            (
                theme::cur().bg,
                theme::cur().fg,
                if pane.is_dirty() {
                    theme::cur().orange
                } else {
                    theme::cur().grey_fg
                },
            )
        } else {
            (
                theme::cur().bg_darker,
                theme::cur().grey_fg,
                theme::cur().grey,
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
        spans.push(Span::styled(
            format!(" {glyph} "),
            // Icons keep their natural devicon color on every tab — active
            // or inactive — so file types stay recognizable at a glance
            // (matches NvChad's tabufline). Only the name + close badge
            // dim on inactive chips.
            Style::default().fg(icon_color).bg(bg),
        ));
        spans.push(Span::styled(format!("{name} "), name_style));
        if !diag.is_empty() {
            let diag_fg = if diag.starts_with('\u{2717}') {
                // `✗` chip — errors → red regardless of active state.
                theme::cur().red
            } else {
                // `⚠` chip — warnings → yellow.
                theme::cur().yellow
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
            spans.push(Span::styled(
                " ",
                Style::default().bg(theme::cur().bg_darker),
            ));
            x += 1;
        }
    }
    if visible.is_empty() {
        spans.push(Span::styled(
            "  no buffers ",
            Style::default()
                .fg(theme::cur().grey_fg)
                .bg(theme::cur().bg_darker),
        ));
        x += "  no buffers ".chars().count() as u16;
    }
    // Are there tabs past the right edge? (Either we broke out of the render
    // loop, or there are tabs after the last one we drew that we never reached.)
    let more_right = overflow_right || (last_drawn + 1 < visible.len());
    // fill the gap up to the cap, then the right overflow chevron (or a blank
    // cell when nothing's past the edge).
    let fill_end = inner_right;
    if x < fill_end {
        spans.push(Span::styled(
            " ".repeat((fill_end - x) as usize),
            Style::default().bg(theme::cur().bg_darker),
        ));
    }
    spans.push(Span::styled(
        if more_right { "›" } else { " " },
        Style::default()
            .fg(theme::cur().blue)
            .bg(theme::cur().bg_darker),
    ));
    if more_right {
        // Right chevron sits at the cell just before the right cap, which
        // is at `inner_right` (= `fill_end`). The cap takes 1 cell after it.
        app.rects.bufferline_overflow_right = Some(ratatui::layout::Rect {
            x: inner_right,
            y: area.y,
            width: 1,
            height: 1,
        });
    }
    let _ = last_drawn;

    // ── Right cluster (NvChad-style chrome) ──
    //
    //   `+` new-tab · `TABS` label · `<n>` per-tabpage chips (`⊗` close on
    //   non-active) · `◯` theme toggle · `×` close-active-pane.
    //
    // Each segment registers its rect in `app.rects` so `tui::dispatch_mouse`
    // can route clicks. Painted left-to-right starting at `tabs_max_x`; the
    // bufferline scroll math reserved exactly `right_w` cells.
    let t = theme::cur();
    let mut cluster_x = tabs_max_x;

    // Launcher-icon strip — one chip per configured `[[ui.launcher_icon]]`.
    // Claude + Codex are built-in defaults; users can replace / append via
    // config (see `LauncherIcon` rustdoc). Each chip is 3 cells
    // (` <glyph> `), painted on its theme-slot color. Click hands off
    // to `dispatch_launcher_icon_click` in dispatch.rs.
    for (i, icon) in app.config.ui.launcher_icons.iter().enumerate() {
        let glyph = if nerd { &icon.glyph } else { &icon.fallback };
        let bg = launcher_color(&t, &icon.color);
        spans.push(Span::styled(
            format!(" {glyph} "),
            Style::default()
                .fg(t.bg_darker)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ));
        app.rects.launcher_icon_rects.push((
            ratatui::layout::Rect {
                x: cluster_x,
                y: area.y,
                width: 3,
                height: 1,
            },
            i,
        ));
        cluster_x += 3;
    }

    // New-tab button. `nf-md-plus` (\u{F0415}) — thicker than ASCII `+`,
    // same glyph NvChad uses for `TabNewBtn`. Colors match NvChad's
    // `TbTabNewBtn = { fg = white, bg = one_bg2 }` — dark chip, light glyph.
    spans.push(Span::styled(
        " \u{F0415} ",
        Style::default().fg(t.fg).bg(t.bg2),
    ));
    app.rects.bufferline_new_tab_button = Some(ratatui::layout::Rect {
        x: cluster_x,
        y: area.y,
        width: 3,
        height: 1,
    });
    cluster_x += 3;

    // `TABS` label (decorative). White-ish chip with dark bold text —
    // uses `t.fg` (NvChad's `white`, #abb2bf in onedark) for max
    // contrast against the dark chrome. `comment` was still rendering
    // too dim.
    spans.push(Span::styled(
        " TABS ",
        Style::default()
            .fg(t.bg_darker)
            .bg(t.fg)
            .add_modifier(Modifier::BOLD),
    ));
    cluster_x += 6;

    // Per-tabpage chips: active = ` <n>󰅖 ` (light-blue bg, dark text,
    // close glyph), inactive = ` <n> ` (dim bg2, comment-grey text, NO
    // close — keeps the strip uncluttered; users close via the active
    // chip or `:bd`). The close glyph is `nf-md-close` (\u{F0156}) —
    // same Material-Design glyph NvChad uses. Dirty tabs get a leading
    // `●`.
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
            // Inactive tab text: `fg` (white) is readable on `bg2`;
            // `comment` was washing out too dim for the number to
            // register at a glance.
            (t.fg, t.bg2)
        };
        let mut chip_style = Style::default().fg(chip_fg).bg(chip_bg);
        if active {
            chip_style = chip_style.add_modifier(Modifier::BOLD);
        }
        spans.push(Span::styled(label, chip_style));
        app.rects.bufferline_tab_page_chips.push((
            ratatui::layout::Rect {
                x: cluster_x,
                y: area.y,
                width: label_w,
                height: 1,
            },
            i,
        ));
        cluster_x += label_w;
        if active {
            // Close glyph + trailing space (2 cells). `nf-md-close`
            // (\u{F0156}) — the standard Material Design close X, same
            // glyph NvChad uses.
            spans.push(Span::styled(
                "\u{F0156} ",
                Style::default().fg(chip_fg).bg(chip_bg),
            ));
            app.rects.bufferline_tab_page_close.push((
                ratatui::layout::Rect {
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

    // Theme toggle — 2-cell composed pill: `●` handle (bright fg) + `━`
    // rail (dim comment grey). When a `[ui] theme_toggle` pair is
    // configured, the handle side flips based on which theme is active —
    // handle-LEFT (`●━`) when on the primary theme, handle-RIGHT (`━●`)
    // when on the alternate. Total slot is 4 cells: ` <pill> `.
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
    app.rects.bufferline_theme_toggle = Some(ratatui::layout::Rect {
        x: cluster_x,
        y: area.y,
        width: 4,
        height: 1,
    });
    cluster_x += 4;

    // Close-active-pane (matches `Ctrl+W` muscle memory). `nf-md-close`
    // (\u{F0156}) — thicker than Unicode `×`, matches the per-tab close.
    spans.push(Span::styled(
        " \u{F0156} ",
        Style::default()
            .fg(t.bg_darker)
            .bg(t.red)
            .add_modifier(Modifier::BOLD),
    ));
    app.rects.bufferline_window_close = Some(ratatui::layout::Rect {
        x: cluster_x,
        y: area.y,
        width: 3,
        height: 1,
    });
    let _ = cluster_x;

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
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
        let mut app = App::new(ws.clone(), Config::default()).unwrap();
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
}
