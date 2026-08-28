//! First-launch wizard renderer — centered modal, 7 sections, keyboard-
//! driven. Matches the About / Welcome / Settings overlay idiom
//! (bordered floating card, Esc-dismissible, non-blocking bg).
//!
//! Phase 1: sections rendered, sections 1-3 interactive, 4-6 badges +
//! stub buttons. Phase 2 wires the install actions.
//!
//! See `src/app/first_launch.rs` for the state + answer commits.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph};

use crate::app::App;
use crate::app::first_launch::WizardSection;
use crate::ui::theme;

/// Click hits registered per-frame by the wizard renderer, consumed
/// by the mouse down_left handler. 2026-08-14 — added to fix the
/// "the yes / no rows aren't clickable" bug on the Nerd Font
/// section. `NerdFontOk(true)` = "yes, glyphs render as icons",
/// `NerdFontOk(false)` = "no, they render as boxes". Both route to
/// `App::wizard_set_nerd_font_ok`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FirstLaunchHit {
    NerdFontOk(bool),
}

/// Fixed inner width — modeled on Settings overlay to feel like family.
const INNER_W: u16 = 74;
/// Padding around the content column.
const PAD_X: u16 = 2;

pub fn draw(frame: &mut Frame, app: &mut App, screen: Rect) {
    let Some(state) = app.first_launch.clone() else {
        return;
    };
    let state = &state;
    app.rects.first_launch_hits.clear();
    // Stand down if a smaller modal is on top — prompt/picker/context
    // menu take precedence so Esc dismisses the smaller thing first.
    if app.prompt.is_some() || app.picker.is_some() || app.context_menu.is_some() {
        return;
    }
    let t = theme::cur();
    let (lines, section_starts) = render_lines(app, state, &t);
    let total_h = lines.len() as u16 + 2; // + top/bottom border
    // Collect hit tags before the immutable-borrow-heavy draw loop so
    // we can register rects mutably after positioning is decided.
    let hit_tags: Vec<Option<FirstLaunchHit>> = lines.iter().map(|(_, hit)| *hit).collect();
    let lines: Vec<Line> = lines.into_iter().map(|(l, _)| l).collect();
    let inner_w = INNER_W;
    let outer_w = inner_w + 2;
    let outer_h = total_h.min(screen.height.saturating_sub(2));
    // #987 (2026-08-18) — when the wizard is taller than the terminal,
    // scroll so the focused section stays visible. Without this the
    // top of the content shows and later sections clip off the bottom
    // (user hits `j` past section 4, focus moves but the screen never
    // follows). `visible_h` = interior rows between borders. Compute
    // scroll s.t. focused section's [start, end) fits in that window.
    let visible_h = outer_h.saturating_sub(2) as usize;
    let scroll = if lines.len() <= visible_h {
        0
    } else {
        let focused = state
            .focused_section
            .min(section_starts.len().saturating_sub(1));
        let start = section_starts.get(focused).copied().unwrap_or(0);
        let end = section_starts
            .get(focused + 1)
            .copied()
            .unwrap_or(lines.len());
        let max_scroll = lines.len().saturating_sub(visible_h);
        // If focused section fits below current scroll, scroll up to
        // its start; else scroll down so its end aligns with the
        // bottom of the window.
        if end.saturating_sub(start) >= visible_h {
            start.min(max_scroll)
        } else if end > visible_h {
            end.saturating_sub(visible_h).min(max_scroll)
        } else {
            0
        }
    };
    let x = screen.x + screen.width.saturating_sub(outer_w) / 2;
    let y = screen.y + screen.height.saturating_sub(outer_h) / 2;
    let outer = Rect {
        x,
        y,
        width: outer_w,
        height: outer_h,
    };
    // Full-screen dim backdrop so tree / editor content stops
    // bleeding through past the wizard's right edge — matches the
    // modal convention (About / Settings overlays). One flat pass;
    // theme's bg is layered over via Clear on `outer` next.
    frame.render_widget(Clear, screen);
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(t.bg_darker)),
        screen,
    );
    frame.render_widget(Clear, outer);
    let panel_bg = Style::default().bg(t.bg_dark);
    frame.render_widget(Paragraph::new("").style(panel_bg), outer);

    // Draw top border with title.
    let title = " First-launch setup — Enter to Finish, Esc to Ask me later ";
    let title_padded = center_title(title, inner_w as usize);
    let border_top = format!("╭{}╮", title_padded);
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            border_top,
            Style::default()
                .fg(t.cyan)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD),
        ))),
        Rect {
            x,
            y,
            width: outer_w,
            height: 1,
        },
    );

    // Draw content lines with left/right border chars. Skip the first
    // `scroll` lines when the wizard exceeds the terminal height
    // (#987) — hit-tag lookups use the source `line_idx = scroll + i`
    // so clicks still target the correct answer.
    for (i, line_body) in lines.iter().skip(scroll).enumerate() {
        let row_y = y.saturating_add(1 + i as u16);
        if row_y >= y + outer_h.saturating_sub(1) {
            break;
        }
        let line_idx = scroll + i;
        let border_style = Style::default().fg(t.cyan).bg(t.bg_dark);
        // Left border
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled("│", border_style))),
            Rect {
                x,
                y: row_y,
                width: 1,
                height: 1,
            },
        );
        // Content
        let content_rect = Rect {
            x: x + 1,
            y: row_y,
            width: inner_w,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(line_body.clone()).style(panel_bg),
            content_rect,
        );
        // Register click hit for this row's tag, if any. Uses the
        // content rect (excluding borders) so the click target
        // matches the visible row.
        if let Some(hit) = hit_tags.get(line_idx).and_then(|h| h.as_ref()) {
            app.rects.first_launch_hits.push((content_rect, *hit));
        }
        // Right border
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled("│", border_style))),
            Rect {
                x: x + outer_w - 1,
                y: row_y,
                width: 1,
                height: 1,
            },
        );
    }

    // Bottom border.
    let border_bot = format!("╰{}╯", "─".repeat(inner_w as usize));
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            border_bot,
            Style::default().fg(t.cyan).bg(t.bg_dark),
        ))),
        Rect {
            x,
            y: y + outer_h - 1,
            width: outer_w,
            height: 1,
        },
    );
}

fn center_title(title: &str, width: usize) -> String {
    let title_w = title.chars().count();
    if title_w >= width {
        return "─".repeat(width);
    }
    let side = (width - title_w) / 2;
    let left = "─".repeat(side);
    let right = "─".repeat(width - side - title_w);
    format!("{left}{title}{right}")
}

/// Compose the full content — one Line per screen row plus an
/// optional click-hit tag per row (2026-08-14). The section currently
/// focused gets a `▸ ` marker + accent color on its title. Tags let
/// the draw loop register click rects for interactive widgets like
/// the Nerd Font Yes/No radios.
fn render_lines<'a>(
    app: &App,
    state: &crate::app::first_launch::FirstLaunchState,
    t: &theme::Theme,
) -> (Vec<(Line<'a>, Option<FirstLaunchHit>)>, Vec<usize>) {
    let mut out: Vec<(Line<'a>, Option<FirstLaunchHit>)> = Vec::new();
    // #987 (2026-08-18) — line-index of each section's `section_rule`
    // (or its header for i == 0). `draw()` uses this to compute a
    // scroll offset that keeps the focused section on-screen when
    // the wizard's total lines exceed the terminal's height.
    let mut section_starts: Vec<usize> = Vec::with_capacity(WizardSection::ALL.len());
    out.push((spacer(t), None));

    for (i, section) in WizardSection::ALL.iter().enumerate() {
        let focused = i == state.focused_section;
        section_starts.push(out.len());
        // A subtle rule above each section (skip the first) — turns
        // the run-together wall of text into visually-parseable
        // sections. The numbers connect with the [1-6] jump hint in
        // the footer.
        if i > 0 {
            out.push((section_rule(t), None));
        }
        // #986 (2026-08-18) — pulse the arrow on the NerdFont
        // section header while it's focused AND unanswered, so
        // the user knows to answer y/n. Wall-clock cadence keeps
        // the pulse frame-rate-independent.
        let pulse = focused
            && matches!(*section, WizardSection::NerdFont)
            && state.answers.nerd_font_ok.is_none();
        // Section header row with a leading number.
        out.push((section_header(i + 1, *section, focused, pulse, t), None));
        // 1-2 wrapped body-description rows.
        for wrapped in wrap_body(section.description(), (INNER_W - PAD_X * 2) as usize) {
            out.push((body_line(&wrapped, t), None));
        }
        // Interactive row(s) per section.
        for row in section_widgets(
            *section,
            &state.answers,
            app,
            t,
            state.focused_ai_route_row,
            focused,
        ) {
            out.push(row);
        }
        out.push((spacer(t), None));
    }

    // Footer with actions.
    out.push((footer(t), None));
    (out, section_starts)
}

fn spacer<'a>(t: &theme::Theme) -> Line<'a> {
    Line::from(Span::styled(
        " ".repeat(INNER_W as usize),
        Style::default().bg(t.bg_dark),
    ))
}

fn section_header<'a>(
    number: usize,
    section: WizardSection,
    focused: bool,
    pulse: bool,
    t: &theme::Theme,
) -> Line<'a> {
    // Focused = cyan + arrow prefix + bold. Unfocused = fg + bold
    // still (headers always pop against the body's dim comment
    // color) — otherwise the sections read as a single wall.
    let arrow = if focused { "▸ " } else { "  " };
    // #986 (2026-08-18) — when pulse is set, alternate the arrow
    // fg between accent cyan and warm orange on a ~700ms cadence.
    // Draws attention to an unanswered section (currently: the
    // NerdFont y/n) without adding characters or changing width.
    // Uses wall-clock so the pulse advances even without input.
    let arrow_fg = if pulse {
        let phase = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() / 700 % 2)
            .unwrap_or(0);
        if phase == 0 { t.cyan } else { t.orange }
    } else if focused {
        t.cyan
    } else {
        t.fg
    };
    let body_fg = if focused { t.cyan } else { t.fg };
    let arrow_span = Span::styled(
        format!(" {}", arrow),
        Style::default()
            .fg(arrow_fg)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    );
    let body_text = format!("{}. {}", number, section.title());
    let padded_body = pad_to(&body_text, (INNER_W as usize).saturating_sub(3));
    let body_span = Span::styled(
        padded_body,
        Style::default()
            .fg(body_fg)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    );
    Line::from(vec![arrow_span, body_span])
}

/// Thin horizontal rule between sections — same background as the
/// modal, dim comment-color glyph so it reads as a separator without
/// competing with the section titles. Two-cell inset matches PAD_X.
fn section_rule<'a>(t: &theme::Theme) -> Line<'a> {
    let bar = "─".repeat((INNER_W - 4) as usize);
    let text = format!("  {}  ", bar);
    Line::from(Span::styled(
        text,
        Style::default().fg(t.comment).bg(t.bg_dark),
    ))
}

fn body_line<'a>(text: &str, t: &theme::Theme) -> Line<'a> {
    let padded = pad_to(&format!("   {}", text), INNER_W as usize);
    Line::from(Span::styled(
        padded,
        Style::default().fg(t.comment).bg(t.bg_dark),
    ))
}

fn footer<'a>(t: &theme::Theme) -> Line<'a> {
    // Six sections now (task #975 added AI billing preference). The
    // digit hint keeps its 1-6 range — the parser at
    // `handle_first_launch_key` already accepts `1..='6'`.
    let text = "   [1-6] jump section  · [↑↓] move  · [Enter] Finish  · [Esc] Ask me later";
    let padded = pad_to(text, INNER_W as usize);
    Line::from(Span::styled(
        padded,
        Style::default().fg(t.comment).bg(t.bg_dark),
    ))
}

/// One or more rows of interactive widgets per section, styled to
/// match the answer state. Each row can carry an optional hit tag
/// (2026-08-14) so the draw loop registers click rects.
fn section_widgets<'a>(
    section: WizardSection,
    answers: &crate::app::first_launch::WizardAnswers,
    app: &App,
    t: &theme::Theme,
    focused_ai_route_row: usize,
    section_focused: bool,
) -> Vec<(Line<'a>, Option<FirstLaunchHit>)> {
    match section {
        WizardSection::AiBackend => radio_rows(
            &[
                (
                    "claude-code",
                    "Claude Code sub — uses your Max/Pro plan (recommended)",
                ),
                ("claude-api", "Claude API — needs $ANTHROPIC_API_KEY"),
                ("local", "Local model — ~1GB download on first use"),
                (
                    "skip",
                    "Skip for now — decide later via `ai.setup_suggestions`",
                ),
            ],
            &answers.ai_backend,
            t,
        )
        .into_iter()
        .map(|l| (l, None))
        .collect(),
        WizardSection::InputStyle => {
            // Tag the row that matches the persisted config with
            // "(current)" so a returning-user vim setting stays visible
            // as a fact — the pre-selected radio (● standard) reflects
            // the recommended default, and hitting Enter converts. Esc
            // preserves the persisted choice.
            let persisted = app.config.editor.input_style.as_str();
            let std_label = if persisted == "standard" {
                "standard — modeless, VS Code / macOS shortcuts (current)"
            } else {
                "standard — modeless, VS Code / macOS shortcuts"
            };
            let vim_label = if persisted == "vim" {
                "vim — modal, hjkl / i / esc / :cmds (current)"
            } else {
                "vim — modal, hjkl / i / esc / :cmds"
            };
            radio_rows(
                &[("standard", std_label), ("vim", vim_label)],
                &answers.input_style,
                t,
            )
            .into_iter()
            .map(|l| (l, None))
            .collect()
        }
        WizardSection::NerdFont => {
            // R11 2026-08-14 — tag the yes/no radio rows so mouse
            // clicks can dispatch to `wizard_set_nerd_font_ok`. The
            // sample-glyph body row and the radios use the same
            // shape; the tags are attached in the same order the
            // renderer emits them.
            let sample = "Sample glyphs:   ▸   󰈙   󰅖   ●";
            let choice = match answers.nerd_font_ok {
                Some(true) => "yes",
                Some(false) => "no",
                None => "",
            };
            let mut out: Vec<(Line<'a>, Option<FirstLaunchHit>)> =
                vec![(body_line(sample, t), None)];
            let radios = radio_rows(
                &[
                    ("yes", "Render as icons — Nerd Font detected"),
                    ("no", "Render as boxes — no Nerd Font"),
                ],
                choice,
                t,
            );
            let tags = [
                FirstLaunchHit::NerdFontOk(true),
                FirstLaunchHit::NerdFontOk(false),
            ];
            for (row, tag) in radios.into_iter().zip(tags.iter()) {
                out.push((row, Some(*tag)));
            }
            out
        }
        WizardSection::Keyboard => {
            // A live checklist rather than a radio: the user presses
            // each chord and watches it tick. Ticks are facts about
            // the environment, not answers, so nothing here persists.
            let doc = app.first_launch.as_ref().map(|s| &s.key_doctor);
            let mut out: Vec<(Line<'a>, Option<FirstLaunchHit>)> = Vec::new();
            for (i, p) in crate::key_doctor::PROBES.iter().enumerate() {
                let seen = doc.map(|d| d.is_seen(i)).unwrap_or(false);
                let mark = if seen { "✓" } else { "·" };
                let row = format!("  {mark}  {:<14}  {}", p.label, p.purpose);
                let style = if seen {
                    Style::default().fg(t.green).bg(t.bg_dark)
                } else {
                    Style::default().fg(t.comment).bg(t.bg_dark)
                };
                out.push((
                    Line::from(Span::styled(pad_to(&row, INNER_W as usize), style)),
                    None,
                ));
            }
            if let Some(d) = doc {
                out.push((body_line(&crate::key_doctor::summary(d), t), None));
                // Remedy for the FIRST missing chord — one clear next
                // step beats a wall of conditional advice.
                if let Some(first) = d.missing().first() {
                    let r = crate::key_doctor::remedy(
                        first.id,
                        crate::key_doctor::detect_terminal(),
                        cfg!(target_os = "macos"),
                    );
                    for chunk in wrap_body(&r.text, INNER_W as usize - 4) {
                        out.push((body_line(&format!("  {chunk}"), t), None));
                    }
                    if r.fix.is_some() {
                        out.push((body_line("  Space — apply this fix", t), None));
                    }
                }
                if let Some(note) = app
                    .first_launch
                    .as_ref()
                    .and_then(|s| s.keyboard_fix_note.as_ref())
                {
                    for chunk in wrap_body(note, INNER_W as usize - 4) {
                        out.push((body_line(&format!("  {chunk}"), t), None));
                    }
                }
            }
            out
        }
        WizardSection::AiRouting => {
            // Two rows — Claude Code (Sub / API / Off) and Codex
            // (Sub / API / Off). Same visual as the input-style radio but
            // arranged inline (label + Sub | API | Off chips) so both
            // rows fit at 74 cells. The row currently focused shows a
            // `▸` marker; ←/→/h/l cycle its choices. Empty answer
            // means Auto — rendered as an unmarked `[Auto]` chip.
            let mut out: Vec<(Line<'a>, Option<FirstLaunchHit>)> = Vec::new();
            let claude_focused = section_focused && focused_ai_route_row == 0;
            let codex_focused = section_focused && focused_ai_route_row == 1;
            out.push((
                ai_routing_row(
                    "Claude Code:",
                    &answers.route_claude,
                    &[("", "Auto"), ("sub", "Sub"), ("api", "API"), ("off", "Off")],
                    claude_focused,
                    t,
                ),
                None,
            ));
            out.push((
                ai_routing_row(
                    "Codex:",
                    &answers.route_codex,
                    &[("", "Auto"), ("sub", "Sub"), ("api", "API"), ("off", "Off")],
                    codex_focused,
                    t,
                ),
                None,
            ));
            out
        }
        WizardSection::ClaudeCode => vec![
            (
                badge_row(
                    "Claude Code CLI (`claude`)",
                    answers.claude_code_installed,
                    t,
                ),
                None,
            ),
            (
                badge_row("Codex CLI (`codex`)", answers.codex_installed, t),
                None,
            ),
        ],
        WizardSection::VscodeShim => {
            vec![(badge_row("`code` on PATH", answers.vscode_shim_ok, t), None)]
        }
    }
}

/// Single-line horizontal-chip row for the AI-routing section
/// (task #975, 2026-08-17). Shape:
///
/// ```text
///      ▸ Claude Code:   [Sub]  API   Off   Auto
/// ```
///
/// The `▸` marker is drawn only when this row is focused (so a user
/// sees which of Claude / Codex their ←/→ will cycle); the current
/// choice is bracketed and colored green. Empty `current` maps to the
/// `""` entry in `options`, which we style as "Auto".
fn ai_routing_row<'a>(
    label: &str,
    current: &str,
    options: &[(&str, &str)],
    focused: bool,
    t: &theme::Theme,
) -> Line<'a> {
    let marker = if focused { "▸" } else { " " };
    let mut spans: Vec<Span<'a>> = Vec::new();
    spans.push(Span::styled(
        format!("    {marker} {label:<14}  "),
        Style::default()
            .fg(if focused { t.cyan } else { t.fg })
            .bg(t.bg_dark)
            .add_modifier(if focused {
                Modifier::BOLD
            } else {
                Modifier::empty()
            }),
    ));
    for (i, (key, label)) in options.iter().enumerate() {
        let is_current = *key == current;
        let chip = if is_current {
            format!("[{label}]")
        } else {
            format!(" {label} ")
        };
        let style = if is_current {
            Style::default()
                .fg(t.green)
                .bg(t.bg_dark)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.comment).bg(t.bg_dark)
        };
        spans.push(Span::styled(chip, style));
        if i + 1 < options.len() {
            spans.push(Span::styled(" ", Style::default().bg(t.bg_dark)));
        }
    }
    // Pad to inner width so the row's bg fills the modal.
    let used: usize = spans.iter().map(|s| s.content.chars().count()).sum();
    if used < INNER_W as usize {
        spans.push(Span::styled(
            " ".repeat(INNER_W as usize - used),
            Style::default().bg(t.bg_dark),
        ));
    }
    Line::from(spans)
}

/// One row per option, `●` for selected / `○` for unselected. Vertical
/// layout so labels can be full sentences without overflow.
fn radio_rows<'a>(options: &[(&str, &str)], current: &str, t: &theme::Theme) -> Vec<Line<'a>> {
    options
        .iter()
        .map(|(key, label)| {
            let is_current = *key == current;
            let (marker, style) = if is_current {
                (
                    "●",
                    Style::default()
                        .fg(t.green)
                        .bg(t.bg_dark)
                        .add_modifier(Modifier::BOLD),
                )
            } else {
                ("○", Style::default().fg(t.comment).bg(t.bg_dark))
            };
            let content = format!("     {} {}", marker, label);
            Line::from(Span::styled(pad_to(&content, INNER_W as usize), style))
        })
        .collect()
}

fn badge_row<'a>(label: &str, installed: bool, t: &theme::Theme) -> Line<'a> {
    let (badge, color) = if installed {
        ("[✓ installed]", t.green)
    } else {
        ("[ not installed — Space to install ]", t.orange)
    };
    let text = format!("     {label}");
    let mut spans = vec![
        Span::styled(
            pad_to(&text, INNER_W as usize / 2),
            Style::default().fg(t.fg).bg(t.bg_dark),
        ),
        Span::styled(badge.to_string(), Style::default().fg(color).bg(t.bg_dark)),
    ];
    let used: usize = spans.iter().map(|s| s.content.chars().count()).sum();
    if used < INNER_W as usize {
        spans.push(Span::styled(
            " ".repeat(INNER_W as usize - used),
            Style::default().bg(t.bg_dark),
        ));
    }
    Line::from(spans)
}

/// Simple word-wrap into `width` char columns.
fn wrap_body(text: &str, width: usize) -> Vec<String> {
    if width == 0 {
        return vec![text.to_string()];
    }
    let mut out = Vec::new();
    let mut line = String::new();
    for word in text.split_whitespace() {
        let needed = if line.is_empty() {
            word.chars().count()
        } else {
            line.chars().count() + 1 + word.chars().count()
        };
        if needed > width && !line.is_empty() {
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

fn pad_to(s: &str, width: usize) -> String {
    let w = s.chars().count();
    if w >= width {
        s.to_string()
    } else {
        format!("{}{}", s, " ".repeat(width - w))
    }
}
