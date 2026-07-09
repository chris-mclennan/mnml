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

/// If `name` starts with an HTTP verb followed by whitespace, split
/// into `(verb, rest)`. Used by the Request-pane tab label to paint
/// the verb in its method color while the URL/name takes the
/// regular fg. Returns `None` for non-Request labels or unusual
/// verbs — the caller falls back to a single-color label.
pub(crate) fn split_http_verb(name: &str) -> Option<(String, String)> {
    for verb in &["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"] {
        if let Some(rest) = name.strip_prefix(verb) {
            let rest = rest.trim_start();
            if !rest.is_empty() {
                return Some((verb.to_string(), rest.to_string()));
            }
        }
    }
    None
}

/// `✗N` (errors) / `⚠N` (warnings) / `""` for editor panes; `""` for everything
/// else. Surfaced in the bufferline so broken buffers are visible without
/// switching to them.
pub(crate) fn diag_chip_for(p: &Pane) -> String {
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

/// The shape of a single tab chip. Fed into `paint_tab_chip` by
/// both the top bufferline (`draw`) and the per-leaf strip
/// (`paint_leaf_tab_strip` in `ui::mod`). One source of truth for
/// how a tab looks — pin/dirty/preview/active/close, diagnostics
/// chip, Request-pane verb splitting. Callers stay responsible for
/// layout math (overflow, right-cluster reservation) + rect
/// registration.
///
/// 2026-07-08 — first cut of the tab-strip unification (stage 1 of
/// 3). Kept opaque so future fields don't break call sites.
#[derive(Clone)]
pub struct TabChipInputs {
    /// The pane id — carried through so the caller can register
    /// click rects. Not read by `paint_tab_chip` itself.
    pub id: crate::layout::PaneId,
    /// Nerd-Font (or ASCII fallback) glyph shown at the left of
    /// the chip. Empty string skips the icon slot (Request panes
    /// use the METHOD chip in its place).
    pub glyph: String,
    /// Foreground color for the icon glyph.
    pub icon_color: ratatui::style::Color,
    /// Human-readable label (usually the pane title). Clipped to
    /// the available width by the painter.
    pub name: String,
    pub is_active: bool,
    pub is_dirty: bool,
    pub is_pinned: bool,
    pub is_preview: bool,
    /// `""` for panes with no LSP / linter diagnostics; else a
    /// short `"✗3"` (errors) or `"⚠2"` (warnings) chip that renders
    /// between the name and the badge.
    pub diag_chip: String,
    /// `Some((verb, rest))` for Request panes whose label starts
    /// with an HTTP verb — the painter renders the verb as a
    /// solid-color badge on `icon_color`, then `rest` in the tab's
    /// normal text style. `None` for everything else.
    pub verb_split: Option<(String, String)>,
    /// Cap (in cells) for the visible name portion. Longer names
    /// get clipped with a `…` suffix. Chips still register a click
    /// rect for their full painted width.
    pub name_cap: usize,
}

/// Rects registered per-chip by `paint_tab_chip`. The caller
/// pushes these into whichever vector its strip owns
/// (`bufferline_tabs` vs `split_tab_chips`, etc.) — the painter
/// doesn't touch `app.rects` directly.
pub struct TabChipRects {
    /// The full painted rect (`chip.x`, `chip.y`, `painted_w`, 1).
    /// Click → switch active.
    pub chip: Rect,
    /// The trailing close/badge cells (last 2 cells) when the chip
    /// carries an ACTIVE close-× badge and there's room for one.
    /// `None` for pinned / dirty / inactive chips (their trailing
    /// badge isn't a close target).
    pub close: Option<Rect>,
}

/// Paint one tab chip at the given `area`, clipping to
/// `avail_width`. Returns the painted rect + optional close rect
/// so the caller can register click zones. `strip_bg` is the color
/// of the strip beneath inactive chips (usually `t.bg_darker`).
///
/// Layout (all cells, from left):
///
///     " {glyph}  {name}[ {diag}] {badge} "
///
/// - `glyph` is skipped (2-cell reservation dropped) when
///   `inputs.glyph.is_empty()`.
/// - `{name}` becomes the two-span verb-chip + rest when
///   `inputs.verb_split` is `Some`.
/// - `{diag}` is dropped when `inputs.diag_chip.is_empty()`.
/// - `{badge}` is the close/pin/dirty glyph.
///
/// 2026-07-08 stage-1 shared painter. Consumers: `bufferline::draw`
/// (top strip) + `ui::mod::paint_leaf_tab_strip` (per-leaf).
/// Compute the `Vec<Span>` sequence and painted width for one tab
/// chip, WITHOUT rendering. Used by both the top bufferline's
/// span-accumulator model (`draw`, extends a shared spans vec)
/// and per-leaf strips (`paint_tab_chip`, wraps in its own
/// Paragraph). Returns `None` when the chip is too wide for
/// `avail_width` to hold at least the icon/name/badge minimum.
///
/// This is the single source of truth for what a tab chip LOOKS
/// LIKE — layout, glyphs, colors, italics, bold — regardless of
/// which strip it ends up in. Adding a state (e.g. a new dirty
/// glyph) means editing this function once.
///
/// 2026-07-08 stage-2 unification.
pub fn tab_chip_spans(
    inputs: &TabChipInputs,
    strip_bg: ratatui::style::Color,
    avail_width: u16,
    nerd: bool,
) -> Option<(Vec<Span<'static>>, u16)> {
    if avail_width == 0 {
        return None;
    }
    let t = theme::cur();
    let name_clipped = crate::ui::clip_to_cells(&inputs.name, inputs.name_cap);
    let pin_glyph = if nerd { "\u{f08d}" } else { "P" };
    let close_glyph = if nerd { "\u{F0156}" } else { "x" };
    let (badge, badge_fg_active, badge_fg_inactive) = if inputs.is_pinned {
        (pin_glyph.to_string(), t.yellow, t.yellow)
    } else if inputs.is_dirty {
        ("●".to_string(), t.orange, t.orange)
    } else if inputs.is_active {
        (close_glyph.to_string(), t.red, t.grey)
    } else {
        (" ".to_string(), t.grey_fg, t.grey)
    };
    let skip_icon = inputs.glyph.is_empty();
    let name_cells = name_clipped.chars().count() as u16;
    let diag_cells = if inputs.diag_chip.is_empty() {
        0
    } else {
        inputs.diag_chip.chars().count() as u16 + 1
    };
    let verb_extra = inputs
        .verb_split
        .as_ref()
        .map(|(verb, _)| verb.chars().count() as u16 + 3);
    let icon_cells = if skip_icon { 1 } else { 4 };
    let base_cells = icon_cells + name_cells + 1 + diag_cells + 2;
    let chip_w = base_cells + verb_extra.unwrap_or(0);
    let painted_w = chip_w.min(avail_width);
    if painted_w == 0 {
        return None;
    }
    let bg = if inputs.is_active { t.bg } else { strip_bg };
    let name_fg = if inputs.is_active { t.fg } else { t.grey_fg };
    let mut name_style = Style::default().fg(name_fg).bg(bg);
    if inputs.is_active {
        name_style = name_style.add_modifier(Modifier::BOLD);
    }
    if inputs.is_preview {
        name_style = name_style.add_modifier(Modifier::ITALIC);
    }
    let badge_fg = if inputs.is_active {
        badge_fg_active
    } else {
        badge_fg_inactive
    };
    let mut spans: Vec<Span<'static>> = Vec::new();
    if skip_icon {
        spans.push(Span::styled(" ".to_string(), Style::default().bg(bg)));
    } else {
        spans.push(Span::styled(
            format!(" {}  ", inputs.glyph),
            Style::default().fg(inputs.icon_color).bg(bg),
        ));
    }
    if let Some((verb, rest)) = &inputs.verb_split {
        spans.push(Span::styled(
            format!(" {verb} "),
            Style::default()
                .fg(bg)
                .bg(inputs.icon_color)
                .add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(" ".to_string(), Style::default().bg(bg)));
        spans.push(Span::styled(format!("{rest} "), name_style));
    } else {
        spans.push(Span::styled(format!("{name_clipped} "), name_style));
    }
    if !inputs.diag_chip.is_empty() {
        let diag_fg = if inputs.diag_chip.starts_with('\u{2717}') {
            t.red
        } else {
            t.yellow
        };
        spans.push(Span::styled(
            format!("{} ", inputs.diag_chip),
            Style::default().fg(diag_fg).bg(bg),
        ));
    }
    spans.push(Span::styled(
        format!("{badge} "),
        Style::default().fg(badge_fg).bg(bg),
    ));
    Some((spans, painted_w))
}

pub fn paint_tab_chip(
    frame: &mut Frame,
    area: Rect,
    inputs: &TabChipInputs,
    strip_bg: ratatui::style::Color,
    avail_width: u16,
    nerd: bool,
) -> Option<TabChipRects> {
    let (spans, painted_w) = tab_chip_spans(inputs, strip_bg, avail_width, nerd)?;
    let chip_rect = Rect {
        x: area.x,
        y: area.y,
        width: painted_w,
        height: 1,
    };
    let bg = if inputs.is_active {
        theme::cur().bg
    } else {
        strip_bg
    };
    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(bg)),
        chip_rect,
    );
    let close = if inputs.is_active && !inputs.is_pinned && !inputs.is_dirty && painted_w >= 2 {
        Some(Rect {
            x: chip_rect.x + chip_rect.width - 2,
            y: chip_rect.y,
            width: 2,
            height: 1,
        })
    } else {
        None
    };
    Some(TabChipRects {
        chip: chip_rect,
        close,
    })
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
    //
    // #polish 2026-07-06 — plus a mode chip (`👁 Preview` when the
    // active pane is a markdown Editor, `✏ Edit` when it's an
    // MdPreview) sitting to the left of the split-button cluster.
    // Replaces the per-pane banner row that used to eat a full
    // content row per markdown pane.
    let mode_chip = mode_chip_for_active(app);
    let mode_chip_w = mode_chip
        .as_ref()
        .map(|(label, _, _)| label.chars().count() as u16)
        .unwrap_or(0);
    let cluster_w = split_buttons_width(app) + mode_chip_w;
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
    // Reclaim-slack pass (issue #3). When tabs on the right close, the
    // logic above may leave `first_visible > 0` while the visible range
    // no longer fills the strip. Walk LEFT while there's room, so
    // closed-tabs space stops being wasted and hidden tabs come back
    // into view automatically. Skipped while user_scroll_pinned so a
    // deliberate ‹ scroll isn't undone.
    if !user_scroll_pinned && app.bufferline_first_visible > 0 {
        let mut used: u16 = 0;
        for (i, &p) in visible
            .iter()
            .enumerate()
            .skip(app.bufferline_first_visible)
        {
            let w = widths[p]
                + if i > app.bufferline_first_visible {
                    sep
                } else {
                    0
                };
            used = used.saturating_add(w);
        }
        while app.bufferline_first_visible > 0 {
            let prev = app.bufferline_first_visible - 1;
            let extra = widths[visible[prev]] + sep;
            if used.saturating_add(extra) > inner_width {
                break;
            }
            used = used.saturating_add(extra);
            app.bufferline_first_visible = prev;
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
    // 2026-07-08 stage-2 unification: this loop now builds
    // `TabChipInputs` per pane and calls `tab_chip_spans` (shared
    // with per-leaf strips via `paint_tab_chip`). No more inline
    // label building / span construction — that lives in one place
    // now, so both strips can't drift.
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
            Pane::Request(r) => {
                // No icon glyph — the colored METHOD prefix in the
                // label (rendered below via `split_http_verb`) IS
                // the icon. Showing the paper-airplane glyph next
                // to a green "GET" was doubling up. Returns an
                // empty string; the label-render path checks for
                // Request panes and skips the icon span entirely.
                let m = r.request.method.to_uppercase();
                let color = match m.as_str() {
                    "GET" => tt.green,
                    "POST" => tt.orange,
                    "PUT" => tt.blue,
                    "PATCH" => tt.cyan,
                    "DELETE" => tt.red,
                    "HEAD" => tt.yellow,
                    "OPTIONS" => tt.purple,
                    _ => tt.blue,
                };
                ("", color)
            }
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
        // Build the chip inputs from pane state — one spec, one
        // painter across both strips.
        let diag = diag_chips[i].clone();
        let is_pinned = matches!(pane, Pane::Editor(b) if b.is_pinned);
        let is_preview = matches!(pane, Pane::Editor(b) if b.is_preview);
        let verb_split = if matches!(pane, Pane::Request(_)) {
            split_http_verb(&name)
        } else {
            None
        };
        let inputs = TabChipInputs {
            id: i,
            glyph: glyph.to_string(),
            icon_color,
            name: name.clone(),
            is_active: active,
            is_dirty: pane.is_dirty(),
            is_pinned,
            is_preview,
            diag_chip: diag,
            verb_split,
            // Top bufferline shows the whole title (labels[i] is
            // pre-clipped by `tab_labels` for ambiguity handling);
            // a large cap here means "trust the caller".
            name_cap: 64,
        };
        let avail = inner_right.saturating_sub(x);
        let Some((chip_spans, cells)) = tab_chip_spans(&inputs, tt.bg_darker, avail, nerd) else {
            overflow_right = true;
            break;
        };
        // Precise width check — the previous check was
        // approximate (`5 + name` vs the actual `7 + name`),
        // causing scroll drift. `tab_chip_spans` returns the
        // truthful width.
        if x + cells > inner_right {
            overflow_right = true;
            break;
        }
        last_drawn = vis_pos;
        spans.extend(chip_spans);
        app.rects.bufferline_tabs.push((
            Rect {
                x,
                y: area.y,
                width: cells,
                height: 1,
            },
            i,
        ));
        // Close target: last 2 cells (badge + trailing pad),
        // registered for every chip (pinned/dirty tabs also get
        // one so bulk close still fires — matches previous
        // behavior).
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
        // 1-cell strip-bg separator between chips.
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
    // Inline `+` chip just past the last tab — mirrors browser tab
    // strips (Chrome / Firefox / Safari). Appears only when at
    // least one Request pane exists so we don't clutter the strip
    // when there's nothing to add-more-of. Clicking it opens a
    // fresh Request pane. The far-right `bufferline_new_tab_button`
    // still exists and creates a new tab-page (window / split).
    let any_request_pane = app.panes.iter().any(|p| matches!(p, Pane::Request(_)));
    if any_request_pane && x + 3 <= inner_right {
        let plus_glyph = if nerd { "\u{F0415}" } else { "+" };
        spans.push(Span::styled(
            format!(" {plus_glyph} "),
            Style::default()
                .fg(theme::cur().green)
                .bg(theme::cur().bg_darker)
                .add_modifier(Modifier::BOLD),
        ));
        app.rects.bufferline_new_request_button = Some(Rect {
            x,
            y: area.y,
            width: 3,
            height: 1,
        });
        x += 3;
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
    // Left arrow (paints at inner_right..inner_right+3). Only rendered
    // when there's actual overflow on that side — the 3-cell footprint
    // is still reserved by the layout so tabs don't jitter when the
    // arrow appears / disappears, but idle chrome stays quiet.
    let left_enabled = first_visible > 0;
    if left_enabled {
        spans.push(Span::styled(
            " ‹ ",
            Style::default()
                .fg(theme::cur().blue)
                .bg(theme::cur().bg_darker)
                .add_modifier(Modifier::BOLD),
        ));
        app.rects.bufferline_overflow_left = Some(ratatui::layout::Rect {
            x: inner_right,
            y: area.y,
            width: 3,
            height: 1,
        });
    } else {
        spans.push(Span::styled(
            "   ",
            Style::default().bg(theme::cur().bg_darker),
        ));
        app.rects.bufferline_overflow_left = None;
    }
    // Right arrow (paints at inner_right+3..inner_right+6).
    if more_right {
        spans.push(Span::styled(
            " › ",
            Style::default()
                .fg(theme::cur().blue)
                .bg(theme::cur().bg_darker)
                .add_modifier(Modifier::BOLD),
        ));
        app.rects.bufferline_overflow_right = Some(ratatui::layout::Rect {
            x: inner_right + 3,
            y: area.y,
            width: 3,
            height: 1,
        });
    } else {
        spans.push(Span::styled(
            "   ",
            Style::default().bg(theme::cur().bg_darker),
        ));
        app.rects.bufferline_overflow_right = None;
    }
    let _ = last_drawn;

    // Right cluster (launcher icons, `+`, TABS chips, theme
    // toggle, close) lives on the palette-bar chrome row.
    // Bufferline paints the file-tab strip + the H/V split
    // buttons at the right end.
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
    // #polish 2026-07-06 — paint the mode chip (Preview / Edit)
    // in the gap between the tab-scroll cluster and the split
    // buttons. It sits to the LEFT of the terminal icon.
    if let Some((label, kind, pid)) = mode_chip {
        let chip_w = label.chars().count() as u16;
        let split_w = split_buttons_width(app);
        let chip_x = area.x + area.width.saturating_sub(split_w + chip_w);
        let chip_rect = Rect {
            x: chip_x,
            y: area.y,
            width: chip_w,
            height: 1,
        };
        let (fg, bg) = match kind {
            ModeChipKind::EditorMd => (theme::cur().bg_darker, theme::cur().purple),
            ModeChipKind::PreviewMd => (theme::cur().bg_darker, theme::cur().blue),
        };
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(
                label.to_string(),
                Style::default().fg(fg).bg(bg).add_modifier(Modifier::BOLD),
            ))),
            chip_rect,
        );
        match kind {
            ModeChipKind::EditorMd => app.rects.editor_md_preview_buttons.push((chip_rect, pid)),
            ModeChipKind::PreviewMd => app.rects.md_preview_edit_buttons.push((chip_rect, pid)),
        }
    }
    paint_split_buttons(frame, app, area);
}

/// Which mode-switch chip belongs on the bufferline for the currently
/// active pane. Returns `(label, kind, pane_id)` or `None` when the
/// active pane isn't markdown-shaped.
#[derive(Debug, Clone, Copy)]
pub(crate) enum ModeChipKind {
    /// Active pane is an editor with a `.md` path — chip toggles
    /// to a rendered preview.
    EditorMd,
    /// Active pane is a rendered preview — chip toggles back to
    /// the raw editor.
    PreviewMd,
}

fn mode_chip_for_active(app: &App) -> Option<(&'static str, ModeChipKind, crate::layout::PaneId)> {
    let pid = app.active?;
    mode_chip_for_pane(app, pid)
}

/// Same shape as `mode_chip_for_active` but for a specific pane id
/// — used by the per-leaf tab strip (`paint_leaf_tab_strip`) so
/// each leaf can host its own chip based on its active pane.
pub(crate) fn mode_chip_for_pane(
    app: &App,
    pid: crate::layout::PaneId,
) -> Option<(&'static str, ModeChipKind, crate::layout::PaneId)> {
    let pane = app.panes.get(pid)?;
    let ascii = app.config.ui.ascii_icons;
    match pane {
        crate::pane::Pane::Editor(b)
            if b.path.as_deref().is_some_and(crate::app::is_markdown_path) =>
        {
            let label = if ascii {
                " p Preview "
            } else {
                " \u{f06e} Preview "
            };
            Some((label, ModeChipKind::EditorMd, pid))
        }
        crate::pane::Pane::MdPreview(_) => {
            let label = if ascii { " e Edit " } else { " \u{f044} Edit " };
            Some((label, ModeChipKind::PreviewMd, pid))
        }
        _ => None,
    }
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
    // ` + ` new-tab button — always present.
    let mut w: u16 = 3;
    // ` TABS ` label + per-tab-page chips — always present in the
    // full cluster so the feature is discoverable even at 1 tab-page.
    // Compact fallback (when the full width doesn't fit or the user
    // chose compact) drops both — that path uses `compact_cluster_width`.
    w += 6;
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
/// and per-tab-page chips.
pub fn compact_cluster_width(_app: &App) -> u16 {
    // ` + ` (3) + theme toggle pill (4) + ` × ` (3)
    3 + 4 + 3
}

/// User-forced cluster mode overrides. Threaded from `[ui]
/// top_bar_cluster_mode`. `Auto` = pick whichever fits;
/// `Expanded` = always try full, fall back only if it won't fit;
/// `Compact` = always use compact (drops TABS + tab-page chips).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClusterModePref {
    Auto,
    Expanded,
    Compact,
}

impl ClusterModePref {
    pub fn parse(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "expanded" => Self::Expanded,
            "compact" => Self::Compact,
            _ => Self::Auto,
        }
    }
}

/// Pick the BEST cluster mode that fits — full, compact, or none.
/// Returns `(width, is_compact)`. Respects the user's preference:
/// `Expanded` forces full even if compact would also fit; `Compact`
/// forces compact; `Auto` picks whichever survives the space check.
pub fn pick_cluster_mode_tiered(
    app: &App,
    area_x: u16,
    area_w: u16,
    palette_right_edge: u16,
    full_w: u16,
    gap: u16,
    pref: ClusterModePref,
) -> Option<(u16, bool)> {
    let full_fits = pick_cluster_mode(area_x, area_w, palette_right_edge, full_w, gap);
    let compact_w = compact_cluster_width(app);
    let compact_left = area_x + area_w.saturating_sub(compact_w);
    let compact_fits = if compact_left >= palette_right_edge + gap {
        Some((compact_w, true))
    } else {
        None
    };
    match pref {
        ClusterModePref::Expanded => full_fits.map(|w| (w, false)).or(compact_fits),
        ClusterModePref::Compact => compact_fits,
        ClusterModePref::Auto => full_fits.map(|w| (w, false)).or(compact_fits),
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
    app.rects.bufferline_new_request_button = None;
    app.rects.bufferline_tab_page_chips.clear();
    app.rects.bufferline_tab_page_close.clear();
    app.rects.bufferline_tabs_label = None;
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
    // Full mode: always show the TABS label + per-tab-page chips
    // (with `1` visible even on a single-tab session so the feature
    // is discoverable). Compact mode drops both. User can force the
    // mode via `[ui] top_bar_cluster_mode = "compact" | "expanded"`,
    // otherwise the space-tight auto-fallback picks.
    if !compact {
        // `TABS` label — decorative click target: right-click opens
        // the Expanded/Compact/Auto mode chooser.
        spans.push(Span::styled(
            " TABS ",
            Style::default()
                .fg(t.bg_darker)
                .bg(t.fg)
                .add_modifier(Modifier::BOLD),
        ));
        app.rects.bufferline_tabs_label = Some(Rect {
            x: cluster_x,
            y: area.y,
            width: 6,
            height: 1,
        });
        cluster_x += 6;
        // Per-tab-page chips with close on active.
        for i in 0..app.layouts.len() {
            let active = i == app.active_layout;
            let dirty = app.tab_has_dirty_buffer(i);
            // #polish 2026-07-06 — reserve 1 cell for the dirty
            // marker regardless of state so chip widths stay
            // stable. Was: dirty added `●` prefix inline, shifting
            // sibling chips 1 cell every time the marker flipped.
            let marker = if dirty { "\u{25CF}" } else { " " };
            let label = format!(" {marker}{} ", i + 1);
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
    // Theme toggle pill — always visible. Click behavior adapts:
    // if `[ui] theme_toggle` is set, swap between primary and alt;
    // otherwise open the theme picker so the click never dead-ends.
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
    match app.config.ui.tab_bar_ai_icon.as_str() {
        "none" => SPLIT_BUTTONS_W,
        "both" => SPLIT_BUTTONS_W + 6, // 2 AI chips × 3 cells each
        _ => SPLIT_BUTTONS_W_WITH_AI,
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

    // AI button(s), leftmost in the cluster — configurable per
    // `[ui] tab_bar_ai_icon`. "none" hides them; "both" paints
    // Claude AND Codex chips (#19) so users can pick per-click
    // without changing config. Each chip registers its own click
    // rect; the handler in tui/mouse dispatches to the right
    // `ai.*_new` command based on which was hit.
    let ai_kind = app.config.ui.tab_bar_ai_icon.as_str();
    // Build the visible chip list. `"both"` gets two chips (Claude
    // then Codex); a single-mode config gets one chip; "none" gets
    // an empty list.
    let ai_kinds: Vec<&'static str> = match ai_kind {
        "none" => Vec::new(),
        "both" => vec!["claude_code", "codex"],
        "codex" => vec!["codex"],
        _ => vec!["claude_code"],
    };
    for kind in &ai_kinds {
        let (ai_glyph, ai_fallback, ai_fg) = theme::ai_chip_parts(kind, &t);
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
        // Tag the rect with which AI kind it is (0 = claude_code, 1 = codex)
        // so the click handler knows which command to fire without
        // re-reading config (matters for the "both" case).
        let tag = if *kind == "codex" { 1u8 } else { 0u8 };
        app.rects
            .split_strip_ai_buttons
            .push((ai_rect, active, tag));
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

    // ── Stage-3 contract tests: TabChipInputs → tab_chip_spans ──
    //
    // These lock the visual identity of a tab chip across every
    // combination of {active, dirty, pinned, preview, close, diag,
    // verb}. Both the top bufferline and per-leaf strips call
    // `tab_chip_spans`; if any state gets rendered inconsistently
    // between them, one of these tests fails.

    fn base_inputs() -> TabChipInputs {
        TabChipInputs {
            id: 0,
            glyph: "R".to_string(),
            icon_color: crate::ui::theme::cur().cyan,
            name: "file.rs".to_string(),
            is_active: false,
            is_dirty: false,
            is_pinned: false,
            is_preview: false,
            diag_chip: String::new(),
            verb_split: None,
            name_cap: 32,
        }
    }

    /// Concatenate a span vec into a raw string (glyphs, no
    /// styles) so tests can assert on what actually reads on
    /// screen.
    fn spans_to_text(spans: &[ratatui::text::Span<'_>]) -> String {
        spans.iter().map(|s| s.content.as_ref()).collect::<String>()
    }

    #[test]
    fn chip_inactive_reads_glyph_name_and_blank_badge() {
        let (spans, w) = tab_chip_spans(&base_inputs(), theme::cur().bg_darker, 40, true)
            .expect("chip should paint");
        let text = spans_to_text(&spans);
        assert!(text.contains("R"), "icon glyph missing: {text:?}");
        assert!(text.contains("file.rs"), "name missing: {text:?}");
        // ` R  file.rs   ` — trailing space is the "blank badge"
        // for inactive-clean chips.
        assert!(
            text.trim_end().ends_with("file.rs"),
            "trailing badge should be blank space: {text:?}"
        );
        assert_eq!(
            w,
            text.chars().count() as u16,
            "reported width must match painted width"
        );
    }

    #[test]
    fn chip_active_ends_with_close_glyph() {
        let inputs = TabChipInputs {
            is_active: true,
            ..base_inputs()
        };
        let (spans, _) = tab_chip_spans(&inputs, theme::cur().bg_darker, 40, true).unwrap();
        let text = spans_to_text(&spans);
        // Close glyph is nerd `\u{F0156}` in nerd mode.
        assert!(
            text.contains('\u{F0156}'),
            "active chip should render close glyph: {text:?}"
        );
    }

    #[test]
    fn chip_pinned_wins_over_dirty_over_close() {
        // pinned + dirty + active → pin glyph in badge slot.
        let pin_glyph = '\u{f08d}';
        let inputs = TabChipInputs {
            is_active: true,
            is_dirty: true,
            is_pinned: true,
            ..base_inputs()
        };
        let text = spans_to_text(
            &tab_chip_spans(&inputs, theme::cur().bg_darker, 40, true)
                .unwrap()
                .0,
        );
        assert!(
            text.contains(pin_glyph),
            "pinned should win over dirty/close: {text:?}"
        );
        assert!(
            !text.contains('\u{F0156}'),
            "close glyph should be absent when pinned: {text:?}"
        );
    }

    #[test]
    fn chip_dirty_shows_orange_dot_badge() {
        let inputs = TabChipInputs {
            is_dirty: true,
            ..base_inputs()
        };
        let text = spans_to_text(
            &tab_chip_spans(&inputs, theme::cur().bg_darker, 40, true)
                .unwrap()
                .0,
        );
        assert!(text.contains('●'), "dirty chip missing • badge: {text:?}");
    }

    #[test]
    fn chip_preview_carries_italic_modifier() {
        let inputs = TabChipInputs {
            is_preview: true,
            ..base_inputs()
        };
        let spans = tab_chip_spans(&inputs, theme::cur().bg_darker, 40, true)
            .unwrap()
            .0;
        let name_span = spans
            .iter()
            .find(|s| s.content.contains("file.rs"))
            .expect("name span present");
        assert!(
            name_span
                .style
                .add_modifier
                .contains(ratatui::style::Modifier::ITALIC),
            "preview name should be italic"
        );
    }

    #[test]
    fn chip_diagnostic_error_renders_red_chip_between_name_and_badge() {
        let inputs = TabChipInputs {
            diag_chip: "\u{2717}3".to_string(),
            ..base_inputs()
        };
        let spans = tab_chip_spans(&inputs, theme::cur().bg_darker, 40, true)
            .unwrap()
            .0;
        let text = spans_to_text(&spans);
        let name_idx = text.find("file.rs").unwrap();
        let diag_idx = text.find('\u{2717}').unwrap();
        assert!(
            diag_idx > name_idx,
            "diag chip should sit right of the name"
        );
        // Error-severity ⚠ chip gets red fg.
        let diag_span = spans
            .iter()
            .find(|s| s.content.contains('\u{2717}'))
            .expect("diag span present");
        assert_eq!(diag_span.style.fg, Some(theme::cur().red));
    }

    #[test]
    fn chip_verb_split_renders_solid_verb_bg_before_url() {
        let inputs = TabChipInputs {
            glyph: String::new(), // skip_icon path
            icon_color: theme::cur().green,
            name: "https://api.example.com/foo".to_string(),
            verb_split: Some(("GET".to_string(), "https://api.example.com/foo".to_string())),
            ..base_inputs()
        };
        let spans = tab_chip_spans(&inputs, theme::cur().bg_darker, 60, true)
            .unwrap()
            .0;
        let text = spans_to_text(&spans);
        let verb_idx = text.find("GET").unwrap();
        let url_idx = text.find("api.example.com").unwrap();
        assert!(verb_idx < url_idx, "verb should render before url");
        // The verb span itself carries a solid bg equal to the
        // method color (`icon_color`).
        let verb_span = spans
            .iter()
            .find(|s| s.content.contains(" GET "))
            .expect("verb span present");
        assert_eq!(verb_span.style.bg, Some(theme::cur().green));
    }

    #[test]
    fn chip_reports_true_painted_width_including_verb_extra() {
        // Verb splitting adds `verb_len + 3` cells. Regression
        // lock — the width the top bufferline uses for scroll
        // math has been off by these cells historically.
        let inputs = TabChipInputs {
            glyph: String::new(),
            icon_color: theme::cur().green,
            name: "url".to_string(),
            verb_split: Some(("GET".to_string(), "url".to_string())),
            ..base_inputs()
        };
        let (spans, w) = tab_chip_spans(&inputs, theme::cur().bg_darker, 40, true).unwrap();
        let painted = spans
            .iter()
            .map(|s| s.content.chars().count())
            .sum::<usize>() as u16;
        assert_eq!(w, painted, "reported width must match summed span chars");
    }

    #[test]
    fn chip_returns_none_when_avail_is_zero() {
        assert!(tab_chip_spans(&base_inputs(), theme::cur().bg_darker, 0, true).is_none());
    }

    #[test]
    fn chip_paint_registers_close_rect_only_for_active_clean_unpinned() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;
        // Grid so each case renders into its own scratch buffer.
        let cases: Vec<(TabChipInputs, bool, &str)> = vec![
            (base_inputs(), false, "inactive"),
            (
                TabChipInputs {
                    is_active: true,
                    ..base_inputs()
                },
                true,
                "active-clean-unpinned",
            ),
            (
                TabChipInputs {
                    is_active: true,
                    is_dirty: true,
                    ..base_inputs()
                },
                false,
                "active-dirty",
            ),
            (
                TabChipInputs {
                    is_active: true,
                    is_pinned: true,
                    ..base_inputs()
                },
                false,
                "active-pinned",
            ),
        ];
        for (inputs, expect_close, label) in cases {
            let mut term = Terminal::new(TestBackend::new(40, 1)).unwrap();
            let mut got_close = false;
            term.draw(|f| {
                let rects = paint_tab_chip(
                    f,
                    Rect::new(0, 0, 40, 1),
                    &inputs,
                    theme::cur().bg_darker,
                    40,
                    true,
                );
                got_close = rects.and_then(|r| r.close).is_some();
            })
            .unwrap();
            assert_eq!(
                got_close, expect_close,
                "close-rect presence mismatch for {label}"
            );
        }
    }
}
