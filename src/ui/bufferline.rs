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

use crate::app::App;
use crate::pane::Pane;
use crate::ui::theme;

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

/// Severity carried alongside the diag chip so the renderer can
/// color it without string-sniffing (dot mode returns the same
/// glyph for either severity — see `diag_chip_for`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DiagChipSeverity {
    None,
    Warning,
    Error,
}

/// Style-driven diagnostic chip + severity for editor bufferline tabs.
/// Returns `("", None)` for non-editor panes or clean editors.
///
/// - `"count"` (default): `✗N` errors / `⚠N` warnings — neovim
///   ecosystem convention (bufferline.nvim / lualine), info-dense.
/// - `"dot"`: colored `●` (red for any error, yellow for warnings
///   only) — VS Code-style, magnitude hidden.
/// - `"off"`: always empty. User relies on the gutter + Problems
///   panel + statusline diag chip instead.
///
/// Reads style from `[ui] bufferline_diag_style`. No `EditingMode`
/// branching — the pluggable-input spine keeps the render layer out
/// of vim/standard bookkeeping.
pub(crate) fn diag_chip_for(p: &Pane, style: &str) -> (String, DiagChipSeverity) {
    if style == "off" {
        return (String::new(), DiagChipSeverity::None);
    }
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
        match style {
            "dot" => {
                if err > 0 {
                    return ("\u{25CF}".to_string(), DiagChipSeverity::Error);
                }
                if warn > 0 {
                    return ("\u{25CF}".to_string(), DiagChipSeverity::Warning);
                }
            }
            _ => {
                // "count" and any unknown value → neovim-style count
                if err > 0 {
                    return (format!("\u{2717}{err}"), DiagChipSeverity::Error);
                }
                if warn > 0 {
                    return (format!("\u{26A0}{warn}"), DiagChipSeverity::Warning);
                }
            }
        }
    }
    (String::new(), DiagChipSeverity::None)
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
    /// True when the mouse is hovering this tab. Renderer paints
    /// the close `×` glyph on hover (not just when active) so
    /// users can close an inactive tab in a single click.
    /// 2026-07-12.
    pub is_hovered: bool,
    /// `""` for panes with no LSP / linter diagnostics; else a
    /// short `"✗3"` (errors) or `"⚠2"` (warnings) chip that renders
    /// between the name and the badge.
    pub diag_chip: String,
    /// Severity backing the chip. Renderer uses this for color
    /// instead of string-sniffing (dot mode returns identical `●`
    /// glyphs regardless of severity — must know via this field).
    pub diag_severity: DiagChipSeverity,
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
/// ```text
/// " {glyph}  {name}[ {diag}] {badge} "
/// ```
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
    let pin_glyph = if nerd { "\u{f08d}" } else { "P" };
    let close_glyph = if nerd { "\u{F0156}" } else { "x" };
    // 2026-07-12 user request — hover reveals the close × on
    // non-active tabs so a single click closes an inactive tab
    // (previously required focus-then-click). Same close_glyph as
    // the active tab; different fg color so it reads as
    // "affordance revealed on hover" rather than "this is the
    // active tab."
    // design-round-4 issue 8 2026-07-14 — hover on a DIRTY inactive
    // tab now also reveals ×, painted in orange so it stays legible
    // that the tab has unsaved changes (the click still routes
    // through the existing unsaved-changes confirm flow on
    // `buffer.close`). Was: is_dirty won the branch before
    // is_hovered, so dirty inactive tabs stayed at the orange dot
    // and required focus-then-close — exactly the "quick dismiss"
    // case the hover fix was written for.
    // R12 vscode-mouse SEV-2 2026-08-23 — non-active/non-hovered
    // non-dirty tabs used to paint " " (a plain space) so users had
    // no visible × on background tabs. Middle-click DID close them,
    // but the affordance was invisible. Now paint the close glyph
    // dim so it reads as "you can click here to close"; active +
    // hover states brighten it further. Dirty stays as the orange
    // ● dot (that badge doubles as unsaved-changes signal — hover
    // still upgrades it to × for a one-click close).
    let (badge, badge_fg_active, badge_fg_inactive) = if inputs.is_pinned {
        (pin_glyph.to_string(), t.yellow, t.yellow)
    } else if inputs.is_active {
        (close_glyph.to_string(), t.red, t.grey)
    } else if inputs.is_hovered && inputs.is_dirty {
        (close_glyph.to_string(), t.orange, t.orange)
    } else if inputs.is_hovered {
        (close_glyph.to_string(), t.grey_fg, t.grey_fg)
    } else if inputs.is_dirty {
        ("●".to_string(), t.orange, t.orange)
    } else {
        (close_glyph.to_string(), t.grey, t.grey)
    };
    let skip_icon = inputs.glyph.is_empty();
    // Design-critic 2026-07-08 HIGH: `inputs.name` from real
    // callers is the FULL label (e.g. "GET /api/users") — verb
    // included. When `verb_split` is Some, the render path draws
    // `rest` in the name slot, not `name_clipped`. Cap `rest`
    // separately and use ITS clipped length for the width math;
    // otherwise the verb text is counted twice (once via
    // `name_cells`, once via `verb_extra`) and the chip paints a
    // dead trailing gap on Request-pane tabs. Symmetrically, an
    // unclipped `rest` on narrow per-leaf strips would blow past
    // `name_cap` mid-URL with no `…`.
    let (name_clipped, name_cells) = if let Some((_, rest)) = &inputs.verb_split {
        let clipped = crate::ui::clip_to_cells(rest, inputs.name_cap);
        let cells = clipped.chars().count() as u16;
        (clipped, cells)
    } else {
        let clipped = crate::ui::clip_to_cells(&inputs.name, inputs.name_cap);
        let cells = clipped.chars().count() as u16;
        (clipped, cells)
    };
    let diag_cells = if inputs.diag_chip.is_empty() {
        0
    } else {
        inputs.diag_chip.chars().count() as u16 + 1
    };
    let verb_extra = inputs
        .verb_split
        .as_ref()
        .map(|(verb, _)| verb.chars().count() as u16 + 3);
    // 2026-07-17 — icon width used to be hardcoded at 4 (assumed
    // 1-char glyph + `" X  "` padding). Codex's `❯_` is 2 chars, so
    // widen dynamically. 2026-07-18 tightened to `" X "` (single
    // trailing space) — user reported double-spaced feel. Fixed
    // padding is now 2 cells (1 leading + 1 trailing).
    let icon_cells = if skip_icon {
        1
    } else {
        2 + inputs.glyph.chars().count() as u16
    };
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
        // 2026-07-18 — was `" X  "` (icon + 2 trailing spaces). Read
        // as double-spaced between icon and label. Trim to a single
        // trailing space so the name sits one cell after the glyph.
        spans.push(Span::styled(
            format!(" {} ", inputs.glyph),
            Style::default().fg(inputs.icon_color).bg(bg),
        ));
    }
    if let Some((verb, _rest)) = &inputs.verb_split {
        // `name_clipped` above already clipped `rest` to `name_cap`.
        // Use it in place of `rest` so wide URLs get `…` truncation
        // instead of mid-character Paragraph hard-clip.
        spans.push(Span::styled(
            format!(" {verb} "),
            Style::default()
                .fg(bg)
                .bg(inputs.icon_color)
                .add_modifier(Modifier::BOLD),
        ));
        spans.push(Span::styled(" ".to_string(), Style::default().bg(bg)));
        spans.push(Span::styled(format!("{name_clipped} "), name_style));
    } else {
        spans.push(Span::styled(format!("{name_clipped} "), name_style));
    }
    if !inputs.diag_chip.is_empty() {
        let diag_fg = match inputs.diag_severity {
            DiagChipSeverity::Error => t.red,
            DiagChipSeverity::Warning => t.yellow,
            DiagChipSeverity::None => t.yellow, // shouldn't happen — clean editor has empty chip
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
    // Close hit-rect: any tab whose badge is `×` should route
    // a click on the badge cells to the close action. That's the
    // active tab OR — 2026-07-12 — a hovered non-active tab.
    // design-round-4 issue 8 2026-07-14 — was `&& !is_dirty`, which
    // meant a hovered dirty inactive tab painted its × (per the
    // badge chain above) but the click on it fell through to
    // "activate the tab" instead of closing. `buffer.close`'s
    // existing unsaved-changes confirm flow makes registering the
    // rect safe. Pinned tabs stay opt-out (explicit unpin verb).
    // R12 vscode-mouse SEV-2 2026-08-23 — was gated on
    // `is_active || is_hovered`, so background tabs had no visible
    // `×` and closing them required (a) middle-click (undocumented
    // affordance) or (b) two clicks (activate + close). VS Code /
    // Chrome / every mouse-driven tabbed UI paints the `×` on
    // every tab; hover styling still distinguishes. Pinned tabs
    // stay opt-out (need an explicit unpin verb before close).
    let close = if !inputs.is_pinned && painted_w >= 2 {
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
    app.rects.bufferline_overflow_left = None;
    app.rects.bufferline_overflow_right = None;
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
    // one-tab-type 2026-07-18 — retire the top bufferline's tab
    // strip. Per-leaf strips (paint_leaf_tab_strip in ui/mod.rs)
    // are now the ONLY tab UI. The bufferline row now only hosts:
    //   1. The mode chip (▶ Edit / 👁 Preview) — bottom-right of
    //      the tabs area, immediately left of the launcher cluster
    //   2. The launcher cluster (H/V/Term/Claude/Codex) via
    //      paint_split_buttons
    // Everything else (tab labels, diag chips, overflow arrows,
    // + new-request-chip) was tied to the top tab-strip and is
    // retired with it.
    paint_mode_chip_and_split_buttons(frame, app, area);
}

/// New (2026-07-18) — extracted from the tab-painting body of
/// `draw` so it can be called directly by the one-tab-type
/// short-circuit path. Paints the markdown mode-toggle chip
/// (Preview / Edit) in front of the launcher cluster, then the
/// cluster itself. Everything else in the old draw was tied to
/// the top tab strip.
fn paint_mode_chip_and_split_buttons(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    // 2026-07-18 — when the row is visible with zero panes (empty
    // workspace, all tabs closed), paint a `+` chip on the left
    // that opens the file picker. Same visual as the per-leaf
    // strip's `+` chip so the empty→populated transition reads as
    // continuity: your first tab starts here, click to fill it.
    // Once a pane exists, the row hides entirely and the per-leaf
    // strip's own `+` takes over.
    //
    // 2026-08-18 (#1019) — check the ACTIVE layout's emptiness, not
    // the global pane pool. Was: `app.panes.is_empty()` which only
    // fired on first-launch (fresh workspace, zero panes total). A
    // user clicking `+` in the top-right to open a new desktop tab
    // creates an Empty layout — but `app.panes` still has the OTHER
    // tab's panes, so the empty-state `+` never appeared. Now we
    // fire when the current tab's layout has no leaves.
    if matches!(app.layout(), crate::layout::Layout::Empty) {
        let nerd = !app.config.ui.ascii_icons;
        let plus_glyph = if nerd { "\u{F0415}" } else { "+" };
        let plus_w = 3u16;
        if area.width >= plus_w {
            let plus_rect = Rect {
                x: area.x,
                y: area.y,
                width: plus_w,
                height: 1,
            };
            let plus_bg = t.bg;
            frame.render_widget(
                Paragraph::new(Line::from(vec![
                    Span::styled(" ", Style::default().bg(plus_bg)),
                    Span::styled(
                        plus_glyph,
                        Style::default()
                            .fg(t.green)
                            .bg(plus_bg)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(" ", Style::default().bg(plus_bg)),
                ])),
                plus_rect,
            );
            app.rects.bufferline_empty_plus = Some(plus_rect);
        }
    }
    // Mode chip — sits immediately left of the launcher cluster.
    let cluster_w = split_buttons_width(app);
    if let Some((label, kind, pid)) = mode_chip_for_active(app) {
        let chip_w = label.chars().count() as u16;
        if area.width >= cluster_w + chip_w {
            let chip_rect = Rect {
                x: area.x + area.width - cluster_w - chip_w,
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
                ModeChipKind::EditorMd => {
                    app.rects.editor_md_preview_buttons.push((chip_rect, pid))
                }
                ModeChipKind::PreviewMd => app.rects.md_preview_edit_buttons.push((chip_rect, pid)),
            }
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
    // 2026-06-27 — launchers + integrations paint in the gap
    // between the palette dropdown and this cluster (closer to
    // where the user expects to find them). The right cluster
    // is just: ` + ` new-tab + ` TABS ` + tab-page chips + theme
    // + close.
    let _ = app;
    // ` + ` new-tab button — always present.
    let mut w: u16 = 3;
    // ` TABS ` label + per-tab-page chips — always present in the
    // full cluster so the feature is discoverable even at 1 tab-page.
    // Compact fallback (when the full width doesn't fit or the user
    // chose compact) drops both — that path uses `compact_cluster_width`.
    w += 6;
    for i in 0..app.layouts.len() {
        let dig = (i + 1).to_string().chars().count() as u16;
        // 2026-08-18 (#1020) — paint emits `{marker}{i+1} ` (marker
        // + digit(s) + space) = 2 + dig cells. Was `3 + dig` when
        // the paint included a leading space; user asked to tighten
        // gap from "1   2   3" to "1  2  3".
        w += 2 + dig;
        if i == app.active_layout {
            w += 2;
        }
    }
    // 1-cell neutral gap after the tab-strip (2026-08-23) +
    // theme toggle pill (3, #1189) + ` × ` window close (3)
    w += 1 + 3 + 3;
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
pub fn compact_cluster_width(app: &App) -> u16 {
    // ` + ` (3) + 1-cell neutral gap after tab-strip (2026-08-23)
    // + theme toggle pill (3, #1189) + ` × ` (3)
    let mut w: u16 = 3 + 1 + 3 + 3;
    // 2026-08-01 — compact mode now shows numbered chips + close
    // on active when there are 2+ tab pages (user asked). Reserve
    // that width so the picker knows compact is wider than the
    // no-chips minimum. Same shape as the expanded per-chip loop
    // — 3 cells for ` <marker><n> ` plus 2 for the × on active.
    // No TABS label in compact.
    if app.layouts.len() >= 2 {
        for i in 0..app.layouts.len() {
            let dig = (i + 1).to_string().chars().count() as u16;
            // 2026-08-18 (#1020) — 2 + dig (marker + digit + trailing
            // space). Was 3 + dig with a leading space; dropped to
            // tighten the visual gap between chips.
            w += 2 + dig;
            if i == app.active_layout {
                w += 2; // ` × `
            }
        }
    }
    w
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
    app.rects.palette_stress_chip = None;

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
    // 2026-08-01 — user redesign of compact mode: hide the "TABS"
    // label always; hide the numbered chip when there's only 1 tab
    // page (no switching to do); show chips + close only when 2+
    // tab pages exist. Expanded mode keeps the full "TABS 1 2 …"
    // layout with the label. Net: compact reads as `+ ●━ ×` on a
    // single-tab session and `+ 1 2 × ●━ ×` once you open a 2nd.
    let show_tabs_label = !compact;
    let show_chips = !compact || app.layouts.len() >= 2;
    if show_tabs_label {
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
    }
    if show_chips {
        // Per-tab-page chips with close on active.
        for i in 0..app.layouts.len() {
            let active = i == app.active_layout;
            let dirty = app.tab_has_dirty_buffer(i);
            // #polish 2026-07-06 — reserve 1 cell for the dirty
            // marker regardless of state so chip widths stay
            // stable. Was: dirty added `●` prefix inline, shifting
            // integration chips 1 cell every time the marker flipped.
            //
            // 2026-08-18 (#1020) — dropped the leading space. Was
            // ` {marker}{digit} ` (4 cells for 1-digit tab); adjacent
            // chips rendered with 3 spaces between digits which read
            // as "1   2   3". Now `{marker}{digit} ` (3 cells) so
            // adjacent chips render as "1  2  3" — one fewer cell
            // of gap. Dirty state still gets its marker cell.
            let marker = if dirty { "\u{25CF}" } else { " " };
            let label = format!("{marker}{} ", i + 1);
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
                // 2026-08-18 (#1022) — close rect covers both painted
                // cells (glyph + trailing space). Was width: 1 —
                // trailing space wasn't clickable; a tap on the
                // right half of the button read as clicking the
                // background instead of the ×.
                app.rects.bufferline_tab_page_close.push((
                    Rect {
                        x: cluster_x,
                        y: area.y,
                        width: 2,
                        height: 1,
                    },
                    i,
                ));
                cluster_x += 2;
            }
        }
    }
    // 2026-08-23 — 1-cell neutral spacer between the tab-page
    // strip and the theme toggle. The active tab-page chip paints
    // with a blue `chip_bg` all the way through its trailing space,
    // so without this gap the blue reads as touching the theme
    // toggle's ● dot on its right. See width helpers below —
    // `right_cluster_width` / `compact_cluster_width` add +1 to
    // match.
    // 2026-08-24 (user ask) — this 1-cell separator between the
    // last tab-page chip (`+` / `1` / `2`) and the theme-toggle
    // pill now paints in `t.bg2` (matching every neighbouring
    // chip) instead of the bar `bg`. Prior version made this
    // cell read as a punched-out gap between two chip strips.
    spans.push(Span::styled(" ", Style::default().bg(t.bg2)));
    cluster_x += 1;
    // Stress-meter mirror was added to the top-right cluster on
    // 2026-07-12 at user request, then removed on 2026-07-12 —
    // the statusline meter is enough; the mirror duplicated
    // signal without adding value. Keep the rect slot cleared so
    // the right-click / tooltip handlers don't fire on stale
    // coords, but paint nothing.
    app.rects.palette_stress_chip = None;
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
        // #1189 (2026-08-23) — was ` ●━ ` (4 cells with leading pad),
        // but the neighbor chip on the left (`+` or a tab-page chip)
        // already carries a trailing space of the same `bg2` bg. Two
        // padded cells between the two glyphs read as one dead cell
        // of gap. Drop the leading pad; keep the trailing so this
        // chip still separates from the ` × ` on its right (3 cells
        // now, and the click-rect width below matches).
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
            width: 3,
            height: 1,
        });
        cluster_x += 3;
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
/// 2026-08-07 — was `tab_bar_ai_icon`-based; that desynced from
/// `paint_split_buttons` which now derives AI chip count from the
/// `enabled` state of each integration. When only claude_code was
/// enabled but `tab_bar_ai_icon = "claude_code"`, both said 12 cells —
/// but flipping codex on made paint draw 15 cells while the
/// reservation stayed at 12, clobbering the mode chip. Now both
/// source the count from the same predicate.
pub fn split_buttons_width(app: &App) -> u16 {
    if app.config.ui.tab_bar_ai_icon == "none" {
        return SPLIT_BUTTONS_W;
    }
    let n_ai = ["claude_code", "codex"]
        .iter()
        .filter(|id| {
            app.config
                .ui
                .integration_icons
                .iter()
                .any(|ic| ic.id == **id && ic.enabled)
        })
        .count() as u16;
    SPLIT_BUTTONS_W + n_ai * 3
}

/// Paint the AI (optional) + terminal + H / V split buttons at the
/// right end of `area`. Registers click rects in:
///   - `app.rects.split_strip_ai_buttons` (AI launch)
///   - `app.rects.split_strip_term_buttons` (terminal)
///   - `app.rects.split_strip_buttons` (H/V)
/// No-op when there's no active leaf.
pub fn paint_split_buttons(frame: &mut Frame, app: &mut App, area: Rect) {
    // design-critic 2026-07-09 SEV-2: the previous all-or-nothing
    // gate (`if area.width < total_w { return }`) meant flipping
    // the `tab_bar_ai_icon` default from "none" to "both" raised
    // the min width from 9 → 15, silently killing terminal + split
    // buttons on leaves that used to render fine. Now: paint the
    // core cluster (terminal + H/V) whenever there's room for
    // those 9 cells, and add AI chips only when the area also
    // fits them. Users on narrow leaves get a partial cluster
    // instead of nothing.
    // 2026-07-18 — was: return if no active pane. That killed the
    // whole cluster in the "no files open" state. Now: paint the
    // full cluster (terminal + H/V + AI) regardless. H/V in the
    // empty state opens two scratch editors laid out in the
    // requested direction via `open_scratch_split`.
    let active_opt = app.active;
    if area.width < SPLIT_BUTTONS_W {
        return;
    }
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
    // Terminal glyph: if the user set `[ui] terminal_glyph_svg` and it
    // baked into a codepoint, use that; else fall back to
    // nf-cod-terminal (\u{ea85}).
    let term_glyph_owned: String = if nerd {
        app.integration_glyph_codepoints
            .get("terminal")
            .and_then(|&cp| char::from_u32(cp))
            .map(|c| c.to_string())
            .unwrap_or_else(|| "\u{ea85}".to_string())
    } else {
        "$".to_string()
    };
    let term_glyph = term_glyph_owned.as_str();
    let side_by_side_glyph = if nerd { "\u{eb56}" } else { "|" };
    let stacked_glyph = if nerd { "\u{eb57}" } else { "-" };
    let bg = t.bg_darker;
    // AI button(s), leftmost in the cluster — configurable per
    // `[ui] tab_bar_ai_icon`. "none" hides them; "both" paints
    // Claude AND Codex chips (#19) so users can pick per-click
    // without changing config. Each chip registers its own click
    // rect; the handler in tui/mouse dispatches to the right
    // `ai.*_new` command based on which was hit.
    // 2026-08-06 — chip visibility is now driven purely by the
    // integration's `enabled` + `in_palette_bar` state. Was: gated
    // by `[ui] tab_bar_ai_icon` which defaulted to "claude_code"
    // and hid Codex even when the user had enabled it. User
    // request: "if both on it should show both unless user chooses
    // to show only one with right click on icon" — right-click
    // toggles `in_palette_bar` on the integration.
    // 2026-08-06 — AI cluster chips ONLY check `enabled` (not
    // `in_palette_bar`). AI chips don't live in the palette-bar gap
    // — that gate belongs to `paint_integration_chips_in_gap`.
    // Using both flags here means enable+manifest-preserves-old-flag
    // creates a mismatched state where the panel says "hidden" but
    // the cluster paints it (or vice versa).
    let mut ai_kinds: Vec<&'static str> = Vec::new();
    let ic_enabled = |id: &str| -> bool {
        app.config
            .ui
            .integration_icons
            .iter()
            .any(|ic| ic.id == id && ic.enabled)
    };
    if ic_enabled("claude_code") {
        ai_kinds.push("claude_code");
    }
    if ic_enabled("codex") {
        ai_kinds.push("codex");
    }
    // Drop AI chips one at a time (from the end, i.e. Codex first
    // in "both" mode) until the total width fits. Terminal + H/V
    // are never dropped — they're the load-bearing part of the
    // cluster (SPLIT_BUTTONS_W = 9 cells for those three).
    while area.width < SPLIT_BUTTONS_W + (ai_kinds.len() as u16) * 3 {
        if ai_kinds.pop().is_none() {
            break;
        }
    }
    let total_w = SPLIT_BUTTONS_W + (ai_kinds.len() as u16) * 3;
    let mut bx = area.x + area.width - total_w;
    for kind in &ai_kinds {
        let (ai_glyph, ai_fallback, ai_fg) =
            theme::ai_chip_parts_for(kind, &t, app.config.ui.ai_chip_use_mnml_glyphs);
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
            .push((ai_rect, active_opt, tag));
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
        Span::styled(
            term_glyph,
            Style::default().fg(ratatui::style::Color::White).bg(bg),
        ),
        Span::styled(" ", Style::default().bg(bg)),
    ]);
    frame.render_widget(Paragraph::new(term_line), term_rect);
    app.rects
        .split_strip_term_buttons
        .push((term_rect, active_opt));
    bx += 3;

    // Split buttons — glyph paired with action that CREATES that
    // layout. Painted in both states: when an active pane exists
    // the click splits it; when no active pane, the click opens
    // two scratch editors laid out in the direction (empty-state
    // handled by `App::open_scratch_split` via the click handler).
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
        app.rects
            .split_strip_buttons
            .push((btn_rect, active_opt, dir));
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

    #[allow(dead_code)]
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
        assert_eq!(
            diag_chip_for(&mk(vec![]), "count"),
            (String::new(), DiagChipSeverity::None)
        );
        // 2 warnings → ⚠2 count-mode
        let warn = || Diagnostic {
            range: r,
            severity: Severity::Warning,
            message: "w".into(),
            source: None,
        };
        assert_eq!(
            diag_chip_for(&mk(vec![warn(), warn()]), "count"),
            ("\u{26A0}2".to_string(), DiagChipSeverity::Warning)
        );
        // dot mode: warn-only → yellow ●
        assert_eq!(
            diag_chip_for(&mk(vec![warn(), warn()]), "dot"),
            ("\u{25CF}".to_string(), DiagChipSeverity::Warning)
        );
        // off style always empty
        assert_eq!(
            diag_chip_for(&mk(vec![warn(), warn()]), "off"),
            (String::new(), DiagChipSeverity::None)
        );
        // mix → errors win
        let err = Diagnostic {
            range: r,
            severity: Severity::Error,
            message: "e".into(),
            source: None,
        };
        assert_eq!(
            diag_chip_for(&mk(vec![warn(), warn(), err.clone()]), "count"),
            ("\u{2717}1".to_string(), DiagChipSeverity::Error)
        );
        // dot mode with error present → red ● (severity distinguishes)
        assert_eq!(
            diag_chip_for(&mk(vec![warn(), err]), "dot"),
            ("\u{25CF}".to_string(), DiagChipSeverity::Error)
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
            is_hovered: false,
            diag_chip: String::new(),
            diag_severity: DiagChipSeverity::None,
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
    fn chip_inactive_reads_glyph_name_and_dim_close_glyph() {
        let (spans, w) = tab_chip_spans(&base_inputs(), theme::cur().bg_darker, 40, true)
            .expect("chip should paint");
        let text = spans_to_text(&spans);
        assert!(text.contains("R"), "icon glyph missing: {text:?}");
        assert!(text.contains("file.rs"), "name missing: {text:?}");
        // R12 vscode-mouse SEV-2 2026-08-23 — was ` R  file.rs   `
        // with a blank trailing badge; now paints a dim close glyph
        // so mouse users see the affordance without hover.
        assert!(
            text.contains('\u{F0156}'),
            "inactive chip should render close glyph (dim): {text:?}"
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
            diag_severity: DiagChipSeverity::Error,
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
        //
        // Design-critic 2026-07-08 HIGH: previous version set
        // `name == rest` so the double-count bug (name_cells
        // ALSO counting the verb via the full `name`) was
        // invisible. Realistic fixture: `name = "GET /api/foo"`,
        // `verb_split = Some(("GET", "/api/foo"))`.
        let inputs = TabChipInputs {
            glyph: String::new(),
            icon_color: theme::cur().green,
            name: "GET /api/foo".to_string(),
            verb_split: Some(("GET".to_string(), "/api/foo".to_string())),
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
    fn chip_verb_split_clips_long_url_with_ellipsis() {
        // Design-critic 2026-07-08 HIGH follow-up: when `rest`
        // exceeds `name_cap`, the painter should clip it with a
        // `…` suffix — same behavior as non-verb chips. Prior
        // to the fix, `rest` was rendered unclipped and got
        // hard-truncated mid-character by Paragraph.
        let inputs = TabChipInputs {
            glyph: String::new(),
            icon_color: theme::cur().green,
            name: "GET https://api.example.com/very/deep/nested/path/segment".to_string(),
            verb_split: Some((
                "GET".to_string(),
                "https://api.example.com/very/deep/nested/path/segment".to_string(),
            )),
            name_cap: 18,
            ..base_inputs()
        };
        let (spans, _) = tab_chip_spans(&inputs, theme::cur().bg_darker, 100, true).unwrap();
        let text = spans_to_text(&spans);
        assert!(
            text.contains('\u{2026}'),
            "long verb-split URL should end with `…`: {text:?}"
        );
    }

    #[test]
    fn chip_returns_none_when_avail_is_zero() {
        assert!(tab_chip_spans(&base_inputs(), theme::cur().bg_darker, 0, true).is_none());
    }

    #[test]
    fn chip_paint_registers_close_rect_only_for_active_or_hovered_unpinned() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;
        // R12 vscode-mouse SEV-2 2026-08-23 — inactive non-hovered
        // tabs now DO get a close rect (chrome / VS Code convention:
        // every unpinned tab is closable in one click). Only pinned
        // tabs stay opt-out.
        let cases: Vec<(TabChipInputs, bool, &str)> = vec![
            (base_inputs(), true, "inactive-not-hovered"),
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
                true,
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
            (
                TabChipInputs {
                    is_hovered: true,
                    ..base_inputs()
                },
                true,
                "inactive-hovered",
            ),
            (
                TabChipInputs {
                    is_hovered: true,
                    is_dirty: true,
                    ..base_inputs()
                },
                true,
                "inactive-hovered-dirty",
            ),
            (
                TabChipInputs {
                    is_hovered: true,
                    is_pinned: true,
                    ..base_inputs()
                },
                false,
                "hovered-pinned",
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
