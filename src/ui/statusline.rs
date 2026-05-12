//! The bottom statusline — NvChad-style powerline segments. The mode chip is
//! the only place that reads `EditingMode` (it shows the editing mode if there
//! is one, else a context label — `TREE` when the tree has focus, `VIEW` for a
//! read-only buffer). Left: mode · git · file. Right: position · language. The
//! gap between holds a centered toast / pending-key hint.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::App;
use crate::focus::Focus;
use crate::input::EditingMode;
use crate::ui::theme;

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
        Seg { text: text.into(), fg, bg, bold: false }
    }
    fn bold(mut self) -> Self {
        self.bold = true;
        self
    }
    fn style(&self) -> Style {
        let s = Style::default().fg(self.fg).bg(self.bg);
        if self.bold { s.add_modifier(Modifier::BOLD) } else { s }
    }
    fn cols(&self) -> usize {
        self.text.chars().count()
    }
}

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    frame.render_widget(Paragraph::new("").style(Style::default().bg(theme::STATUSLINE)), area);
    if area.width == 0 {
        return;
    }
    let width = area.width as usize;
    let arrows = !app.config.ui.ascii_icons;

    // ── left segments ──
    let (mode_label, mode_bg) = mode_chip(app);
    let mut left = vec![Seg::new(format!(" {mode_label} "), theme::BG_DARKER, mode_bg).bold()];
    if let Some(branch) = &app.git.snapshot().branch {
        let n = app.git.snapshot().change_count();
        let txt = if n > 0 { format!("  {branch}  +{n} ") } else { format!("  {branch} ") };
        left.push(Seg::new(txt, theme::GREEN, theme::BG2));
    }
    let (fname, lang) = match app.active_editor() {
        Some(b) => (
            format!("{}{}", b.display_name(), if b.dirty { " ●" } else { "" }),
            b.language_ext.clone().unwrap_or_else(|| "text".to_string()),
        ),
        None => ("[no file]".to_string(), "—".to_string()),
    };
    left.push(Seg::new(format!("  {fname} "), theme::FG, theme::STATUSLINE));

    // ── right segments ──
    let mut right: Vec<Seg> = Vec::new();
    if let Some(b) = app.active_editor() {
        let (row, col) = b.editor.row_col();
        right.push(Seg::new(format!(" Ln {} Col {} ", row + 1, col + 1), theme::FG, theme::BG2));
    }
    right.push(Seg::new(format!("  {lang} "), theme::BG_DARKER, theme::BLUE).bold());

    // ── render ──
    let mut spans: Vec<Span> = Vec::new();
    let mut used = 0usize;

    // left, with `` transitions; the trailing arrow blends into the spacer.
    for (i, s) in left.iter().enumerate() {
        spans.push(Span::styled(s.text.clone(), s.style()));
        used += s.cols();
        let next_bg = left.get(i + 1).map(|n| n.bg).unwrap_or(theme::STATUSLINE);
        if arrows {
            spans.push(Span::styled(PL_RIGHT, Style::default().fg(s.bg).bg(next_bg)));
            used += 1;
        }
    }
    // right, built so the leading `` blends from the spacer.
    let mut right_spans: Vec<Span> = Vec::new();
    let mut right_used = 0usize;
    for (i, s) in right.iter().enumerate() {
        let prev_bg = if i == 0 { theme::STATUSLINE } else { right[i - 1].bg };
        if arrows {
            right_spans.push(Span::styled(PL_LEFT, Style::default().fg(s.bg).bg(prev_bg)));
            right_used += 1;
        }
        right_spans.push(Span::styled(s.text.clone(), s.style()));
        right_used += s.cols();
    }

    // middle: toast / pending-key hint, centered in the leftover space.
    let mid_avail = width.saturating_sub(used + right_used);
    let middle = app
        .pending_display()
        .or_else(|| app.live_toast().map(|s| s.to_string()))
        .unwrap_or_default();
    let is_pending = app.pending_display().is_some();
    let mid_text: String = {
        let m = if middle.is_empty() { String::new() } else { format!(" {middle} ") };
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
        Style::default().fg(theme::YELLOW).bg(theme::STATUSLINE).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(theme::COMMENT).bg(theme::STATUSLINE)
    };
    spans.push(Span::styled(mid_text, mid_style));
    spans.extend(right_spans);

    frame.render_widget(Paragraph::new(Line::from(spans)), area);
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
