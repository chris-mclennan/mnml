//! First-launch wizard renderer — centered modal, 6 sections, keyboard-
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

/// Fixed inner width — modeled on Settings overlay to feel like family.
const INNER_W: u16 = 74;
/// Padding around the content column.
const PAD_X: u16 = 2;

pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    let Some(state) = app.first_launch.as_ref() else {
        return;
    };
    // Stand down if a smaller modal is on top — prompt/picker/context
    // menu take precedence so Esc dismisses the smaller thing first.
    if app.prompt.is_some() || app.picker.is_some() || app.context_menu.is_some() {
        return;
    }
    let t = theme::cur();
    let lines = render_lines(app, state, &t);
    let total_h = lines.len() as u16 + 2; // + top/bottom border
    let inner_w = INNER_W;
    let outer_w = inner_w + 2;
    let outer_h = total_h.min(screen.height.saturating_sub(2));
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

    // Draw content lines with left/right border chars.
    for (i, line_body) in lines.iter().enumerate() {
        let row_y = y.saturating_add(1 + i as u16);
        if row_y >= y + outer_h.saturating_sub(1) {
            break;
        }
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
        frame.render_widget(
            Paragraph::new(line_body.clone()).style(panel_bg),
            Rect {
                x: x + 1,
                y: row_y,
                width: inner_w,
                height: 1,
            },
        );
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

/// Compose the full content — one Line per screen row. The section
/// currently focused gets a `▸ ` marker + accent color on its title.
fn render_lines<'a>(
    app: &App,
    state: &crate::app::first_launch::FirstLaunchState,
    t: &theme::Theme,
) -> Vec<Line<'a>> {
    let mut out: Vec<Line<'a>> = Vec::new();
    out.push(spacer(t));

    for (i, section) in WizardSection::ALL.iter().enumerate() {
        let focused = i == state.focused_section;
        // A subtle rule above each section (skip the first) — turns
        // the run-together wall of text into visually-parseable
        // sections. The numbers connect with the [1-6] jump hint in
        // the footer.
        if i > 0 {
            out.push(section_rule(t));
        }
        // Section header row with a leading number.
        out.push(section_header(i + 1, *section, focused, t));
        // 1-2 wrapped body-description rows.
        for wrapped in wrap_body(section.description(), (INNER_W - PAD_X * 2) as usize) {
            out.push(body_line(&wrapped, t));
        }
        // Interactive row(s) per section.
        for row in section_widgets(*section, &state.answers, app, t) {
            out.push(row);
        }
        out.push(spacer(t));
    }

    // Footer with actions.
    out.push(footer(t));
    out
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
    t: &theme::Theme,
) -> Line<'a> {
    // Focused = cyan + arrow prefix + bold. Unfocused = fg + bold
    // still (headers always pop against the body's dim comment
    // color) — otherwise the sections read as a single wall.
    let arrow = if focused { "▸ " } else { "  " };
    let fg = if focused { t.cyan } else { t.fg };
    let text = format!(" {}{}. {}", arrow, number, section.title());
    let padded = pad_to(&text, INNER_W as usize);
    Line::from(Span::styled(
        padded,
        Style::default()
            .fg(fg)
            .bg(t.bg_dark)
            .add_modifier(Modifier::BOLD),
    ))
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
    let text = "   [1-6] jump section  · [↑↓] move  · [Enter] Finish  · [Esc] Ask me later";
    let padded = pad_to(text, INNER_W as usize);
    Line::from(Span::styled(
        padded,
        Style::default().fg(t.comment).bg(t.bg_dark),
    ))
}

/// One or more rows of interactive widgets per section, styled to
/// match the answer state.
fn section_widgets<'a>(
    section: WizardSection,
    answers: &crate::app::first_launch::WizardAnswers,
    _app: &App,
    t: &theme::Theme,
) -> Vec<Line<'a>> {
    match section {
        WizardSection::AiBackend => radio_rows(
            &[
                ("claude-api", "Claude API — fast, needs $ANTHROPIC_API_KEY"),
                ("local", "Local model — ~1GB download on first use"),
                (
                    "skip",
                    "Skip for now — decide later via `ai.setup_suggestions`",
                ),
            ],
            &answers.ai_backend,
            t,
        ),
        WizardSection::InputStyle => radio_rows(
            &[
                ("standard", "standard — modeless, VS Code / macOS shortcuts"),
                ("vim", "vim — modal, hjkl / i / esc / :cmds"),
            ],
            &answers.input_style,
            t,
        ),
        WizardSection::NerdFont => {
            let sample = "Sample glyphs:   ▸   󰈙   󰅖   ●";
            let choice = match answers.nerd_font_ok {
                Some(true) => "yes",
                Some(false) => "no",
                None => "",
            };
            let mut lines = vec![body_line(sample, t)];
            lines.extend(radio_rows(
                &[
                    ("yes", "Render as icons — Nerd Font detected"),
                    ("no", "Render as boxes — no Nerd Font"),
                ],
                choice,
                t,
            ));
            lines
        }
        WizardSection::ClaudeCode => vec![
            badge_row(
                "Claude Code CLI (`claude`)",
                answers.claude_code_installed,
                t,
            ),
            badge_row("Codex CLI (`codex`)", answers.codex_installed, t),
        ],
        WizardSection::VscodeShim => vec![badge_row("`code` on PATH", answers.vscode_shim_ok, t)],
    }
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
