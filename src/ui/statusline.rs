//! The bottom statusline — NvChad-style powerline segments. The mode chip is the
//! only place that reads `EditingMode` (it shows the editing mode if there is
//! one, else a context label — `TREE` / `VIEW` / `EDIT`).
//!
//! Left:  `[mode] [git branch +N] [<icon> file ●]`
//! Right: `[Ln:Col] [<folder> workspace] [language]`
//! The gap holds a centered toast / pending-key hint.
//!
//! TODO: when the git track lands, flesh the left side out — split git changes
//! into `+N ~N -N`, add a sync/ahead-behind indicator, a GitHub/PR badge, etc.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::focus::Focus;
use crate::input::EditingMode;
use crate::ui::{icons, theme};

const PL_RIGHT: &str = "\u{e0b0}"; //
const PL_LEFT: &str = "\u{e0b2}"; //

struct Seg {
    text: String,
    fg: Color,
    bg: Color,
    bold: bool,
}

impl Seg {
    fn new(text: impl Into<String>, fg: Color, bg: Color) -> Self {
        Seg {
            text: text.into(),
            fg,
            bg,
            bold: false,
        }
    }
    fn bold(mut self) -> Self {
        self.bold = true;
        self
    }
    fn style(&self) -> Style {
        let s = Style::default().fg(self.fg).bg(self.bg);
        if self.bold {
            s.add_modifier(Modifier::BOLD)
        } else {
            s
        }
    }
    fn cols(&self) -> usize {
        self.text.chars().count()
    }
}

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(theme::STATUSLINE)),
        area,
    );
    if area.width == 0 {
        return;
    }
    let width = area.width as usize;
    let arrows = !app.config.ui.ascii_icons;
    let nerd = !app.config.ui.ascii_icons;

    // ── left ──
    let (mode_label, mode_bg) = mode_chip(app);
    let mut left = vec![Seg::new(format!(" {mode_label} "), theme::BG_DARKER, mode_bg).bold()];
    if let Some(branch) = &app.git.snapshot().branch {
        let n = app.git.snapshot().change_count();
        let txt = if n > 0 {
            format!("  {branch}  +{n} ")
        } else {
            format!("  {branch} ")
        };
        left.push(Seg::new(txt, theme::GREEN, theme::BG2));
    }
    // file segment: icon (its devicon color) + name + dirty marker, both on STATUSLINE bg.
    match app.active_editor() {
        Some(b) => {
            let p = b.path.clone().unwrap_or_else(|| b.display_name().into());
            let (glyph, gc) = icons::for_path(&p, false, false, nerd);
            left.push(Seg::new(format!(" {glyph} "), gc, theme::STATUSLINE));
            let name = format!("{}{} ", b.display_name(), if b.dirty { " ●" } else { "" });
            left.push(Seg::new(name, theme::FG, theme::STATUSLINE));
        }
        None => left.push(Seg::new(" [no file] ", theme::COMMENT, theme::STATUSLINE)),
    }

    // ── right ──
    let mut right: Vec<Seg> = Vec::new();
    if let Some(b) = app.active_editor() {
        let (row, col) = b.editor.row_col();
        right.push(Seg::new(
            format!(" Ln {} Col {} ", row + 1, col + 1),
            theme::FG,
            theme::BG2,
        ));
    }
    // workspace / cwd block (the name that used to sit atop the file tree).
    let ws_name = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workspace");
    let folder_glyph = if nerd { "\u{f07b}" } else { "" };
    right.push(
        Seg::new(
            format!(" {folder_glyph} {ws_name} "),
            theme::BLUE,
            theme::BG3,
        )
        .bold(),
    );
    // language block.
    let lang = app
        .active_editor()
        .and_then(|b| b.language_ext.clone())
        .unwrap_or_else(|| "—".to_string());
    right.push(Seg::new(format!("  {lang} "), theme::BG_DARKER, theme::BLUE).bold());

    // ── render: left segments + spacer + right segments, with `` / `` transitions ──
    let (mut spans, used) = render_left(&left, arrows, theme::STATUSLINE);
    let (right_spans, right_used) = render_right(&right, arrows, theme::STATUSLINE);

    // middle: toast / pending-key hint, centered in the leftover space.
    let mid_avail = width.saturating_sub(used + right_used);
    let middle = app
        .pending_display()
        .or_else(|| app.live_toast().map(|s| s.to_string()))
        .unwrap_or_default();
    let is_pending = app.pending_display().is_some();
    let mid_text: String = {
        let m = if middle.is_empty() {
            String::new()
        } else {
            format!(" {middle} ")
        };
        let mc = m.chars().count();
        if mc >= mid_avail {
            m.chars().take(mid_avail).collect()
        } else {
            let total = mid_avail - mc;
            let lp = total / 2;
            format!("{}{}{}", " ".repeat(lp), m, " ".repeat(total - lp))
        }
    };
    let mid_style = if is_pending {
        Style::default()
            .fg(theme::YELLOW)
            .bg(theme::STATUSLINE)
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(theme::COMMENT).bg(theme::STATUSLINE)
    };
    spans.push(Span::styled(mid_text, mid_style));
    spans.extend(right_spans);

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

/// Left-anchored segments; a `` after each (its fg = this bg, bg = next bg),
/// skipped between two same-bg neighbors so a multi-span segment looks unified.
fn render_left(segs: &[Seg], arrows: bool, tail_bg: Color) -> (Vec<Span<'static>>, usize) {
    let mut out = Vec::new();
    let mut used = 0;
    for (i, s) in segs.iter().enumerate() {
        out.push(Span::styled(s.text.clone(), s.style()));
        used += s.cols();
        let next_bg = segs.get(i + 1).map(|n| n.bg).unwrap_or(tail_bg);
        if arrows && next_bg != s.bg {
            out.push(Span::styled(
                PL_RIGHT,
                Style::default().fg(s.bg).bg(next_bg),
            ));
            used += 1;
        }
    }
    (out, used)
}

/// Right-anchored segments; a `` before each (its fg = this bg, bg = prev bg),
/// skipped between two same-bg neighbors.
fn render_right(segs: &[Seg], arrows: bool, head_bg: Color) -> (Vec<Span<'static>>, usize) {
    let mut out = Vec::new();
    let mut used = 0;
    for (i, s) in segs.iter().enumerate() {
        let prev_bg = if i == 0 { head_bg } else { segs[i - 1].bg };
        if arrows && prev_bg != s.bg {
            out.push(Span::styled(PL_LEFT, Style::default().fg(s.bg).bg(prev_bg)));
            used += 1;
        }
        out.push(Span::styled(s.text.clone(), s.style()));
        used += s.cols();
    }
    (out, used)
}

/// `(label, bg_color)` for the mode chip.
fn mode_chip(app: &App) -> (&'static str, Color) {
    match app.editing_mode() {
        EditingMode::Insert => ("INSERT", theme::GREEN),
        EditingMode::Visual => ("VISUAL", theme::PURPLE),
        EditingMode::Normal => ("NORMAL", theme::RED),
        EditingMode::None => match app.focus {
            Focus::Tree => ("TREE", theme::BLUE),
            Focus::Pane => {
                if app.active_editor().map(|b| b.read_only).unwrap_or(true) {
                    ("VIEW", theme::CYAN)
                } else {
                    ("EDIT", theme::GREEN)
                }
            }
        },
    }
}
