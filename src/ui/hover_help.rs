//! Ableton-style hover-help — a small info box docked at the bottom
//! of the left panel that describes whatever the mouse is over — chip,
//! menu item, tree row, tab — in plain English. Updates on every move.
//! Zero-delay unlike the popup tooltip (`src/ui/tooltip.rs`), which
//! waits `HOVER_TOOLTIP_DELAY_MS`. When nothing's under the mouse the
//! box shows a subtle hint about the current focus so it never goes
//! blank-and-purposeless.
//!
//! 2026-08-09 — moved off the bottom-of-window full-width strip onto
//! the bottom-of-left-panel boxed layout modelled on Ableton's Info
//! View. Same feed (`pick_help_text`), new shape: narrower, taller,
//! word-wrapped, always in the same corner so the eye knows where to
//! look. Toggled by `view.toggle_hover_help` and the `[ui] hover_help`
//! config key. When off, the box's rows aren't reserved on the left
//! panel and the tree gets that space back.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::ui::theme;

/// Number of rows the box occupies at the bottom of the left panel.
/// 1 separator + 1 header + up to `INFO_BOX_HEIGHT - 3` wrapped
/// content rows + 1 blank trailer so the last text line isn't
/// flush against the statusbar directly below (breathing room
/// requested 2026-08-10). R8 vscode-mouse feedback: without the
/// separator the box shares tree_rail bg and reads as accidental
/// tree overflow. Adding a dim `─` rule at row 0 draws the eye
/// without bumping to a bordered card.
pub const INFO_BOX_HEIGHT: u16 = 8;

/// Paint the info box over `area`. Caller reserves the rows only when
/// `app.config.ui.hover_help` is on AND the left panel is tall enough
/// to spare `INFO_BOX_HEIGHT`.
///
/// Layout (Info View v0.3 Phase 1.6, matches `docs/design/info-view-v0.3.md`):
///
/// ```text
///   ─────────────────────────  ← row 0: divider from tree rail
///    Slack Boards              ← row 1: TITLE bar (distinct bg, bold)
///                              ← row 2: spacer
///    Slack Canvases share the  ← row 3+: body (word-wrapped, regular)
///    same OAuth token…
///    [Ctrl+K b] Toggle bufferline  ← shortcuts (bracket accent + label)
///                              ← trailing blank (cushion for statusbar)
/// ```
/// Delay between the mouse settling on a new hover target and the
/// info-box swapping to its copy. Suppresses rapid text flashes when
/// the user drags across tree rows or chips (2026-08-12 report). Set
/// low enough that a purposeful hover feels instant — 120ms is right
/// at the edge of "immediate" perception. First swap ever renders
/// with no delay so opening the panel isn't laggy.
const HOVER_HELP_DEBOUNCE_MS: u128 = 120;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    if area.height == 0 || area.width == 0 {
        return;
    }
    app.rects.hover_help_strip = Some(area);
    let t = theme::cur();
    // Body bg is slightly darker than the tree rail so the box reads
    // as its own pane. Title bar uses `bg2` (the menu / popup fill,
    // usually noticeably lighter than the tree rail's bg_dark) so the
    // topic band reads as a distinct "help header" — user 2026-08-11
    // feedback: prior `bg_dark` was visually indistinguishable from
    // the tree above it, so the title looked like accidental text
    // rather than a titled help pane.
    let body_bg = t.bg_darker;
    let title_bg = t.bg2;
    frame.render_widget(Paragraph::new("").style(Style::default().bg(body_bg)), area);

    let copy = debounced_help_copy(app);

    // Row 0 — divider + drag-to-resize grip. Center 4 cells switch to
    // `═` (double horizontal) so users can see the panel is draggable.
    // Whole row is the hit-target — see `tui/mouse/mod.rs`'s drag
    // handler on `rects.hover_help_strip`.
    let w = area.width as usize;
    let grip_w = 4usize.min(w);
    let grip_lead = (w.saturating_sub(grip_w)) / 2;
    let grip_trail = w.saturating_sub(grip_lead + grip_w);
    let sep_style = Style::default()
        .fg(t.comment)
        .bg(body_bg)
        .add_modifier(Modifier::DIM);
    let grip_style = Style::default().fg(t.comment).bg(body_bg);
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled("─".repeat(grip_lead), sep_style),
            Span::styled("═".repeat(grip_w), grip_style),
            Span::styled("─".repeat(grip_trail), sep_style),
        ])),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );
    if area.height <= 1 {
        return;
    }

    // Row 1 — TITLE bar (topic name, distinct bg, bold) + kebab
    // affordance at the right edge. `⋮` (U+22EE, vertical 3-dot)
    // matches the widget kebab glyph in `src/ui/dock.rs`.
    let kebab_glyph = "⋮";
    // Reserve 2 cells at the right for the glyph + 1 padding cell
    // (so it doesn't butt against the frame). Title text truncates
    // to fit; area.width >= 3 is required for the kebab to appear.
    let kebab_cells = 2u16;
    let title_avail = area.width.saturating_sub(kebab_cells);
    // Title starts flush-left with 1-cell inset. The `?` prefix
    // (2026-08-11) got dropped 2026-08-12 — user feedback: the glyph
    // read as accidental character in the corner, not a help sigil.
    // The distinct title-bar bg (`bg2`) already differentiates the
    // help header from the body without needing a leading icon.
    let prefix_cells = 1u16;
    let title_body_avail = title_avail.saturating_sub(prefix_cells);
    let title_text: String = copy
        .title
        .chars()
        .take(title_body_avail.saturating_sub(1) as usize)
        .collect();
    let title_body = pad_line(&title_text, title_body_avail as usize);
    let mut title_spans = vec![
        Span::styled(" ", Style::default().bg(title_bg)),
        Span::styled(
            title_body,
            Style::default()
                .fg(t.fg)
                .bg(title_bg)
                .add_modifier(Modifier::BOLD),
        ),
    ];
    if area.width >= 3 {
        title_spans.push(Span::styled(
            kebab_glyph,
            Style::default().fg(t.comment).bg(title_bg),
        ));
        title_spans.push(Span::styled(" ", Style::default().bg(title_bg)));
        app.rects.hover_help_kebab = Some(Rect {
            x: area.x + area.width - kebab_cells,
            y: area.y + 1,
            width: 1,
            height: 1,
        });
    } else {
        app.rects.hover_help_kebab = None;
    }
    frame.render_widget(
        Paragraph::new(Line::from(title_spans)),
        Rect {
            x: area.x,
            y: area.y + 1,
            width: area.width,
            height: 1,
        },
    );
    if area.height <= 2 {
        return;
    }

    // Rows 2..N — spacer + body + optional aside + optional shortcuts.
    // 1-cell gutter left + right; trailing row stays blank as cushion
    // before the statusbar directly below.
    let content_w = area.width.saturating_sub(2) as usize;
    let mut lines: Vec<Line<'static>> = Vec::new();
    // Spacer row between title bar and body.
    lines.push(spacer(body_bg));
    // Body — regular weight, comment-color (softer than fg-bold so the
    // TITLE bar owns the visual weight).
    for line in wrap_words(&copy.body, content_w) {
        lines.push(Line::from(vec![
            Span::styled(" ", Style::default().bg(body_bg)),
            Span::styled(line, Style::default().fg(t.fg).bg(body_bg)),
        ]));
    }
    // Aside — italic caveat.
    if let Some(aside) = &copy.aside {
        for line in wrap_words(aside, content_w) {
            lines.push(Line::from(vec![
                Span::styled(" ", Style::default().bg(body_bg)),
                Span::styled(
                    line,
                    Style::default()
                        .fg(t.comment)
                        .bg(body_bg)
                        .add_modifier(Modifier::ITALIC),
                ),
            ]));
        }
    }
    // Shortcut hints — `[Chord] Label` per row. Only if there's room
    // after the body; otherwise skip (body reads first).
    let max_body_rows = area.height.saturating_sub(3) as usize;
    let rows_left = max_body_rows.saturating_sub(lines.len());
    if rows_left > 0 && !copy.shortcuts.is_empty() {
        // Blank spacer between prose and shortcuts.
        lines.push(spacer(body_bg));
        for hint in copy.shortcuts.iter().take(rows_left.saturating_sub(1)) {
            lines.push(Line::from(vec![
                Span::styled(" ", Style::default().bg(body_bg)),
                Span::styled(
                    format!("[{}]", hint.chord),
                    Style::default()
                        .fg(t.cyan)
                        .bg(body_bg)
                        .add_modifier(Modifier::BOLD),
                ),
                Span::styled(
                    format!(" {}", hint.label),
                    Style::default().fg(t.fg).bg(body_bg),
                ),
            ]));
        }
    }

    // Body starts at row 2 (after divider + title). Height reserves
    // 1 trailing row as cushion.
    let body_rect = Rect {
        x: area.x,
        y: area.y + 2,
        width: area.width,
        height: area.height.saturating_sub(3),
    };
    let cap = body_rect.height as usize;
    let total_lines = lines.len();
    let overflow = total_lines > cap;
    // Clamp scroll so we can always fill the visible window from the
    // scroll offset. `hover_help_scroll` is user-controlled via wheel
    // (see mouse handler); clamp here so a stale value on a shorter
    // committed body doesn't paint blank rows.
    let max_scroll = total_lines.saturating_sub(cap) as u16;
    let scroll = app.hover_help_scroll.min(max_scroll);
    // Persist the clamp so subsequent wheel events see the true value.
    app.hover_help_scroll = scroll;
    let visible: Vec<Line<'static>> = lines.into_iter().skip(scroll as usize).take(cap).collect();
    if overflow {
        // Reserve 1 col on the right for the scrollbar; render body in
        // the remaining width.
        let scrollbar_col = body_rect.x + body_rect.width.saturating_sub(1);
        let content_rect = Rect {
            width: body_rect.width.saturating_sub(1),
            ..body_rect
        };
        frame.render_widget(Paragraph::new(visible), content_rect);
        // Scrollbar: full track in comment color, thumb in cyan sized
        // proportional to visible/total ratio, positioned per scroll
        // offset. Min thumb = 1 row.
        let track_h = body_rect.height as usize;
        let thumb_h = ((cap * track_h) / total_lines).max(1);
        let thumb_y_off = if max_scroll == 0 {
            0
        } else {
            ((scroll as usize) * (track_h.saturating_sub(thumb_h))) / (max_scroll as usize)
        };
        for i in 0..track_h {
            let is_thumb = i >= thumb_y_off && i < thumb_y_off + thumb_h;
            let (glyph, color) = if is_thumb {
                ("┃", t.cyan)
            } else {
                ("│", t.comment)
            };
            frame.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    glyph,
                    Style::default().fg(color).bg(body_bg),
                ))),
                Rect {
                    x: scrollbar_col,
                    y: body_rect.y + i as u16,
                    width: 1,
                    height: 1,
                },
            );
        }
    } else {
        frame.render_widget(Paragraph::new(visible), body_rect);
    }
}

fn spacer<'a>(bg: ratatui::style::Color) -> Line<'a> {
    Line::from(Span::styled(" ", Style::default().bg(bg)))
}

fn pad_line(s: &str, width: usize) -> String {
    let w = s.chars().count();
    if w >= width {
        s.to_string()
    } else {
        format!("{}{}", s, " ".repeat(width - w))
    }
}

/// Minimal word-wrap into lines of at most `width` chars. Preserves
/// word boundaries; oversized words get a hard break rather than
/// overflow. No hyphenation — this is UI help, not typesetting.
fn wrap_words(text: &str, width: usize) -> Vec<String> {
    if width == 0 || text.is_empty() {
        return vec![String::new()];
    }
    let mut out: Vec<String> = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        let word_len = word.chars().count();
        if word_len > width {
            // Push the current line, then hard-break the oversized word.
            if !line.is_empty() {
                out.push(std::mem::take(&mut line));
            }
            let mut chars = word.chars();
            loop {
                let chunk: String = chars.by_ref().take(width).collect();
                if chunk.is_empty() {
                    break;
                }
                if chunk.chars().count() == width {
                    out.push(chunk);
                } else {
                    line = chunk;
                    break;
                }
            }
            continue;
        }
        let needed = if line.is_empty() {
            word_len
        } else {
            line.chars().count() + 1 + word_len
        };
        if needed > width {
            out.push(std::mem::take(&mut line));
            line = word.to_string();
        } else {
            if !line.is_empty() {
                line.push(' ');
            }
            line.push_str(word);
        }
    }
    if !line.is_empty() {
        out.push(line);
    }
    if out.is_empty() {
        out.push(String::new());
    }
    out
}

/// The hover-help text pair: primary (bold) + optional secondary.
/// Delegates to the same describe logic as `ui::tooltip::describe`
/// but stripped down to just the text (no anchor rect needed here).
///
/// Fallback ladder when no chip is hovered:
///   1. Focus target — the tree row / right-panel pane / bottom-panel
///      pane the keyboard is on. Only when `app.focus != Pane`.
///      R6 nvchad SEV-3 2026-08-09: prior order swallowed tree focus
///      because the active-pane branch always matched — a vim user
///      on keyboard-only walking the tree never saw the row they were
///      hovering.
///   2. Active pane summary (file / URL / kind) — for `Focus::Pane`
///      or when the focus target had nothing useful to show.
///   3. Focus hint pointing at the palette (last resort).
/// Debounce wrapper around [`pick_help_copy`]. The panel only swaps
/// to a new copy after that copy has been the "current" pick for
/// [`HOVER_HELP_DEBOUNCE_MS`] straight. Rapid mouse drags across
/// rows/chips keep resetting the pending timer, so the committed
/// text stays stable. First paint (no committed yet) renders
/// immediately so opening isn't perceived as laggy.
///
/// Debounce key = `InfoViewCopy.title`. Two distinct targets that
/// produce identical titles will look like "same" for debounce
/// purposes — acceptable trade-off vs. plumbing a proper target key
/// or deriving PartialEq on the whole struct.
fn debounced_help_copy(app: &mut App) -> crate::ui::info_view::InfoViewCopy {
    let fresh = pick_help_copy(app);
    // Never any committed → first paint, render immediately.
    let Some(committed) = app.hover_help_committed.clone() else {
        app.hover_help_committed = Some(fresh.clone());
        app.hover_help_pending = None;
        return fresh;
    };
    // Fresh already matches committed → nothing to swap. Drop pending.
    if committed.title == fresh.title {
        app.hover_help_pending = None;
        return committed;
    }
    // Fresh differs. Check the pending slot.
    let now = std::time::Instant::now();
    match &app.hover_help_pending {
        Some((pending_copy, first_seen))
            if pending_copy.title == fresh.title
                && first_seen.elapsed().as_millis() >= HOVER_HELP_DEBOUNCE_MS =>
        {
            // Pending has settled long enough. Commit + reset scroll —
            // a new target means back to the top of the fresh content.
            app.hover_help_committed = Some(fresh.clone());
            app.hover_help_pending = None;
            app.hover_help_scroll = 0;
            fresh
        }
        Some((pending_copy, _)) if pending_copy.title == fresh.title => {
            // Same pending target still settling. Keep old committed.
            committed
        }
        _ => {
            // New pending candidate (or first pending). Reset timer.
            app.hover_help_pending = Some((fresh.clone(), now));
            committed
        }
    }
}

fn pick_help_copy(app: &App) -> crate::ui::info_view::InfoViewCopy {
    use crate::ui::info_view::InfoViewCopy;
    // Info View v0.3 Phase 1.6 — InfoViewCopy is now the primary shape.
    // Curated `info_view_copy::lookup` entries render richly (title +
    // body + shortcuts). Legacy tooltip callers get their
    // (primary, secondary) pair mapped onto title + body so nothing
    // regresses while the copy dictionary catches up.
    if let Some((chip, _)) = app.hover_chip {
        let target = crate::ui::info_view::InfoViewTarget::Chip(chip);
        if let Some(copy) = crate::ui::info_view_copy::lookup(app, &target) {
            return copy;
        }
        if let Some((primary, secondary)) = crate::ui::tooltip::describe_text(chip, app) {
            return InfoViewCopy {
                title: primary,
                body: secondary.unwrap_or_default(),
                ..Default::default()
            };
        }
    }
    if let Some(copy) = describe_focus_target_copy(app) {
        return copy;
    }
    if let Some(cur) = app.active
        && let Some(pane) = app.panes.get(cur)
        && let Some((primary, secondary)) = describe_active_pane(pane)
    {
        return InfoViewCopy {
            title: primary,
            body: secondary.unwrap_or_default(),
            ..Default::default()
        };
    }
    // Empty state — one-liner per focus surface. Title names the
    // surface; body gives the essential action.
    let (title, body) = match app.focus {
        crate::focus::Focus::Tree => (
            "Sidebar",
            "Arrows or j/k walk rows. Enter opens the selection. Ctrl+Shift+P opens the palette.",
        ),
        crate::focus::Focus::Pane => (
            "Editor",
            "Hover a chip, tab, or tree row for help. Ctrl+Shift+P opens the palette.",
        ),
        crate::focus::Focus::RightPanel => (
            "Right panel",
            "Arrows walk rows. Enter jumps to the source. Ctrl+E cycles focus.",
        ),
        crate::focus::Focus::BottomPanel => (
            "Bottom panel",
            "Arrows walk rows. Ctrl+Shift+J hides. Ctrl+E cycles focus.",
        ),
    };
    InfoViewCopy {
        title: title.to_string(),
        body: body.to_string(),
        ..Default::default()
    }
}

/// InfoViewCopy shape of describe_focus_target. When the focus target
/// has a curated tree-row entry, prefer that; else synthesize from
/// the ad-hoc friendly-lang strings.
fn describe_focus_target_copy(app: &App) -> Option<crate::ui::info_view::InfoViewCopy> {
    use crate::ui::info_view::InfoViewCopy;
    let (primary, secondary) = describe_focus_target(app)?;
    Some(InfoViewCopy {
        title: primary,
        body: secondary.unwrap_or_default(),
        ..Default::default()
    })
}

/// Describe whatever is under keyboard focus when it's NOT a pane —
/// tree cursor row, right-panel pane, or bottom-panel pane. Returns
/// None when focus IS on a pane (caller falls through to
/// `describe_active_pane`) or when the focus target has no useful
/// description (empty tree / empty panel).
fn describe_focus_target(app: &App) -> Option<(String, Option<String>)> {
    match app.focus {
        crate::focus::Focus::Pane => None,
        crate::focus::Focus::Tree => {
            // At rest on the auto-selected row 0, the panel used to
            // narrate `.cargo/` (or whatever the first workspace child
            // was) — clutter, not signal. Fall through to the Sidebar
            // empty-state hint until the user actually navigates.
            // Mouse hover keeps working through the chip path. 2026-08-11.
            if app.tree.cursor() == 0 {
                return None;
            }
            let row = app.tree.selected_row()?;
            let name = row
                .path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| row.path.to_string_lossy().into_owned());
            // Info View v0.3 Phase 1.5 — prefer a curated tree-row
            // entry when one exists (language-specific hint copy).
            let target = crate::ui::info_view::InfoViewTarget::TreeRow {
                label: name.clone(),
                is_dir: row.is_dir,
            };
            if let Some(copy) = crate::ui::info_view_copy::lookup(app, &target) {
                return Some(copy.to_flat_pair());
            }
            let (primary, secondary) = if row.is_dir {
                (
                    format!("{name}/"),
                    Some("Directory. Enter or Right expands / opens. j/k walks rows.".to_string()),
                )
            } else {
                // R6 R2 multilang-dev SEV-3 2026-08-09 — show the
                // file's language on the tree row (`App.tsx` → "TypeScript
                // (JSX)"), not just the generic "File." blurb. The
                // editor-pane branch already surfaces `language_ext`
                // once a file is open; users deserve the same signal
                // while browsing so they can decide whether to open
                // an unfamiliar file without opening it first.
                let ext = row
                    .path
                    .extension()
                    .and_then(|e| e.to_str())
                    .map(|s| s.to_ascii_lowercase())
                    .unwrap_or_default();
                let lang = friendly_lang(&ext);
                let primary_with_lang = if lang.is_empty() {
                    name
                } else {
                    format!("{name}  ·  {lang}")
                };
                (
                    primary_with_lang,
                    Some(
                        "File. Enter opens it in a new tab. Right-click for cut / copy / paste / rename."
                            .to_string(),
                    ),
                )
            };
            Some((primary, secondary))
        }
        crate::focus::Focus::RightPanel => {
            let pane_idx = *app.right_panel_panes.get(app.right_panel_active_idx)?;
            let pane = app.panes.get(pane_idx)?;
            let (primary, _) = describe_active_pane(pane)?;
            Some((
                primary,
                Some(
                    "Right-panel focus. Arrows walk rows. Enter jumps. Ctrl+E cycles focus."
                        .to_string(),
                ),
            ))
        }
        crate::focus::Focus::BottomPanel => {
            let pane_idx = *app.bottom_panel_panes.get(app.bottom_panel_active_idx)?;
            let pane = app.panes.get(pane_idx)?;
            let (primary, _) = describe_active_pane(pane)?;
            Some((
                primary,
                Some(
                    "Bottom-panel focus. Arrows walk rows. Ctrl+Shift+J hides. Ctrl+E cycles focus."
                        .to_string(),
                ),
            ))
        }
    }
}

/// Map a lower-case file extension to a friendly language name for
/// the hover-help tree-row line. Unknown extensions fall back to
/// the uppercased ext (`.foo` → "FOO"). Empty ext (no extension)
/// returns "" — caller skips the ` · LANG` suffix.
///
/// R6 R2 multilang-dev SEV-3 2026-08-09 — the editor-pane branch
/// exposes `language_ext.to_ascii_uppercase()`; this widens the same
/// signal to the tree-row branch AND gives a friendly display name
/// for the common cases so a `.tsx` file reads "TypeScript (JSX)"
/// instead of "TSX".
fn friendly_lang(ext: &str) -> String {
    match ext {
        "" => String::new(),
        "rs" => "Rust".into(),
        "ts" => "TypeScript".into(),
        "tsx" => "TypeScript (JSX)".into(),
        "js" => "JavaScript".into(),
        "jsx" => "JavaScript (JSX)".into(),
        "py" => "Python".into(),
        "go" => "Go".into(),
        "rb" => "Ruby".into(),
        "java" => "Java".into(),
        "kt" | "kts" => "Kotlin".into(),
        "swift" => "Swift".into(),
        "c" => "C".into(),
        "cpp" | "cc" | "cxx" | "hpp" | "hxx" | "hh" => "C++".into(),
        "h" => "C header".into(),
        "cs" => "C#".into(),
        "php" => "PHP".into(),
        "sh" | "bash" | "zsh" => "Shell".into(),
        "lua" => "Lua".into(),
        "vim" => "Vim script".into(),
        "md" | "markdown" => "Markdown".into(),
        "json" => "JSON".into(),
        "yaml" | "yml" => "YAML".into(),
        "toml" => "TOML".into(),
        "xml" => "XML".into(),
        "html" | "htm" => "HTML".into(),
        "css" => "CSS".into(),
        "scss" | "sass" => "Sass".into(),
        "sql" => "SQL".into(),
        "dockerfile" => "Dockerfile".into(),
        "makefile" | "mk" => "Makefile".into(),
        "proto" => "Protobuf".into(),
        "graphql" | "gql" => "GraphQL".into(),
        "http" | "curl" | "rest" => "HTTP request".into(),
        "svg" => "SVG".into(),
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "bmp" => "Image".into(),
        "pdf" => "PDF".into(),
        "txt" | "text" => "Text".into(),
        _ => ext.to_ascii_uppercase(),
    }
}

fn describe_active_pane(pane: &crate::pane::Pane) -> Option<(String, Option<String>)> {
    use crate::pane::Pane;
    match pane {
        Pane::Editor(b) => {
            let title = pane.title();
            let lang = b
                .language_ext
                .as_deref()
                .map(|e| e.to_ascii_uppercase())
                .unwrap_or_else(|| "TEXT".to_string());
            let lines = b.editor.text().lines().count().max(1);
            let dirty = if b.dirty { " · unsaved" } else { "" };
            let primary = format!("{title}  ·  {lang}  ·  {lines} lines{dirty}");
            let secondary = if b.is_preview {
                Some("Preview tab — first edit or double-click promotes it.".to_string())
            } else if b.is_pinned {
                Some("Pinned — stays at the front of the bufferline.".to_string())
            } else {
                None
            };
            Some((primary, secondary))
        }
        Pane::Request(_) => Some((
            pane.title(),
            Some("Request pane — Enter to send, Ctrl+S saves as .http/.curl.".into()),
        )),
        Pane::Pty(_) => Some((
            pane.title(),
            Some("Terminal pane — Ctrl+Alt+H to detach, Ctrl+Alt+K to kill.".into()),
        )),
        Pane::MdPreview(_) => Some((
            pane.title(),
            Some("Rendered markdown preview — click header chip to jump back to source.".into()),
        )),
        Pane::Ai(_) => Some((
            pane.title(),
            Some("Claude / Codex session — type at the bottom prompt.".into()),
        )),
        Pane::ClaudeAgents(p) => {
            // R6 R2 claude-agents-power SEV-3 2026-08-09 — the
            // Agents dashboard is dense enough that the generic
            // pane title tells the user nothing. Pull the
            // currently-selected row and describe it: source /
            // workspace / state / model / last activity.
            //
            // R8 fix 2026-08-10 — go through `selected_row()` so a
            // filtered / sorted list picks the ROW UNDER THE CURSOR,
            // not `rows[i]` at the raw underlying index (which reads
            // out of sync when either filter or sort is active).
            if let Some(row) = p.selected_row() {
                let source = match row.source {
                    crate::claude_agents::AgentSource::Claude => "Claude Code",
                    crate::claude_agents::AgentSource::Codex => "Codex",
                    crate::claude_agents::AgentSource::Ecs => "ECS runner",
                    crate::claude_agents::AgentSource::AnthropicManaged => "Anthropic Managed",
                };
                let state = format!("{:?}", row.state);
                let workspace = if row.workspace.is_empty() {
                    "(unknown)".to_string()
                } else {
                    row.workspace.clone()
                };
                let short_id = row.session_id.chars().take(8).collect::<String>();
                let primary = format!("{source} · {workspace} · {state} · {short_id}");
                let secondary = Some(
                    "Agents dashboard — j/k walks rows, K kills, Enter drills in, / filters."
                        .to_string(),
                );
                Some((primary, secondary))
            } else {
                Some((
                    pane.title(),
                    Some(
                        "Agents dashboard — no sessions found. j/k walks rows once populated, / filters."
                            .into(),
                    ),
                ))
            }
        }
        _ => Some((pane.title(), None)),
    }
}

#[cfg(test)]
mod tests {
    use super::wrap_words;

    #[test]
    fn wrap_preserves_word_boundaries() {
        let out = wrap_words("the quick brown fox jumps over", 10);
        // Each line ≤ 10 chars, words intact.
        for line in &out {
            assert!(line.chars().count() <= 10, "line {line:?} exceeds width");
        }
        assert!(
            out.join(" ")
                .split_whitespace()
                .eq("the quick brown fox jumps over".split_whitespace())
        );
    }

    #[test]
    fn wrap_handles_oversized_word_hard_break() {
        let out = wrap_words("supercalifragilisticexpialidocious", 8);
        for line in &out {
            assert!(line.chars().count() <= 8);
        }
        assert_eq!(out.concat(), "supercalifragilisticexpialidocious");
    }

    #[test]
    fn wrap_empty_input_returns_one_empty_line() {
        assert_eq!(wrap_words("", 10), vec![String::new()]);
    }

    #[test]
    fn wrap_zero_width_returns_one_empty_line() {
        assert_eq!(wrap_words("hello world", 0), vec![String::new()]);
    }

    use super::friendly_lang;

    #[test]
    fn friendly_lang_known_extensions() {
        assert_eq!(friendly_lang("rs"), "Rust");
        assert_eq!(friendly_lang("tsx"), "TypeScript (JSX)");
        assert_eq!(friendly_lang("py"), "Python");
        assert_eq!(friendly_lang("go"), "Go");
        assert_eq!(friendly_lang("md"), "Markdown");
        assert_eq!(friendly_lang("yaml"), "YAML");
        assert_eq!(friendly_lang("yml"), "YAML");
    }

    #[test]
    fn friendly_lang_empty_ext_returns_empty() {
        assert_eq!(friendly_lang(""), "");
    }

    #[test]
    fn friendly_lang_unknown_ext_uppercased_fallback() {
        assert_eq!(friendly_lang("xyz"), "XYZ");
    }
}
