//! Design tokens — the app-wide "style guide" for overlay chrome.
//!
//! Two overlay shapes are recognized:
//!
//! - **Modal** — big-panel style, input-stealing. Picker, settings,
//!   help, integration edit, glyph builder. Square borders,
//!   `fg`-colored border stroke, `bg_dark` background, cyan title bar.
//!   Used by ~30 of the ~35 overlays in the app; this is the default
//!   for anything that reads as "a real panel."
//!
//! - **Popup** — transient / anchored / non-input-stealing. Hover
//!   tooltip, signature-help, right-click menu, cmdline popup,
//!   whichkey, close-prompt. Rounded borders, blue border stroke,
//!   `bg_darker` background, no strong title bar. Reads visually as
//!   "a floating chip" rather than a page.
//!
//! To change the app-wide look, edit these functions. Overlays that
//! call `modal_panel(title)` / `popup_panel(title)` automatically
//! pick up the change; overlays that still hand-roll their Block
//! stay put (migrate them opportunistically).

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};

use crate::ui::theme;

/// Modal-panel chrome. Returns a configured `Block` ready to render.
/// The caller emits the widget + uses `block.inner()` for its content.
/// Passing an empty title skips the title span so the border draws
/// continuously.
pub fn modal_panel(title: impl AsRef<str>) -> Block<'static> {
    let t = theme::cur();
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Plain)
        .border_style(Style::default().fg(t.fg).bg(t.bg_dark))
        .style(Style::default().fg(t.fg).bg(t.bg_dark));
    let title = title.as_ref().trim();
    if title.is_empty() {
        block
    } else {
        block.title(Span::styled(
            format!(" {title} "),
            Style::default()
                .fg(t.bg_dark)
                .bg(t.cyan)
                .add_modifier(Modifier::BOLD),
        ))
    }
}

/// Bordered panel with a plain-text legend title — no colored chip,
/// title reads as inline text along the top border. Used by the
/// Request pane's stacked sub-panels (Request/Response/AI + Method/
/// URL/Send/Clear/etc.) where the goal is a clean "loaded file"
/// aesthetic, not the highlighted overlay look of `modal_panel`.
pub fn bordered_plain(title: impl AsRef<str>) -> Block<'static> {
    let t = theme::cur();
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Plain)
        .border_style(Style::default().fg(t.bg3).bg(t.bg_dark))
        .style(Style::default().fg(t.fg).bg(t.bg_dark));
    let title = title.as_ref().trim();
    if title.is_empty() {
        block
    } else {
        block.title(Span::styled(
            format!(" {title} "),
            Style::default().fg(t.comment).bg(t.bg_dark),
        ))
    }
}

/// Menu-style chrome — for menu bar dropdowns, right-click context
/// menus, and inline pickers where the visual weight should sit on
/// the SELECTED ROW, not the frame. Square border, default fg color,
/// `bg2` fill. Matches the pre-design-system menu_bar look; the
/// aesthetic is macOS/VS Code menu, quiet frame + prominent row.
pub fn popup_menu(title: impl AsRef<str>) -> Block<'static> {
    let t = theme::cur();
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Plain)
        .style(Style::default().fg(t.fg).bg(t.bg2));
    let title = title.as_ref().trim();
    if title.is_empty() {
        block
    } else {
        block.title(Span::styled(
            format!(" {title} "),
            Style::default().fg(t.comment).add_modifier(Modifier::BOLD),
        ))
    }
}

/// Popup-style chrome for anchored / transient overlays. Rounded
/// border, subtle color accent, `bg_darker` fill. Passing an empty
/// title skips the title span entirely so the top border draws
/// continuously (tooltip / menu-bar dropdown / titleless
/// context menus).
pub fn popup_panel(title: impl AsRef<str>) -> Block<'static> {
    let t = theme::cur();
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(t.blue).bg(t.bg_darker))
        .style(Style::default().fg(t.fg).bg(t.bg_darker));
    let title = title.as_ref().trim();
    if title.is_empty() {
        block
    } else {
        block.title(Span::styled(
            format!(" {title} "),
            Style::default()
                .fg(t.blue)
                .bg(t.bg_darker)
                .add_modifier(Modifier::BOLD),
        ))
    }
}

/// Style for the hint line at the bottom of a modal panel — the
/// `↵ save · esc cancel · …` help row that every panel-form uses.
pub fn hint_style() -> Style {
    let t = theme::cur();
    Style::default().fg(t.comment).bg(t.bg_dark)
}

/// Row-highlight style for the *menu* family — menu-bar dropdowns,
/// right-click context menus, workspaces_editor list. Reads as
/// "commit action on Enter": cyan bg + bg_dark fg + bold. Pair with
/// [`popup_menu`] chrome so the row is the visual weight, not the
/// frame.
pub fn row_highlight_menu() -> Style {
    let t = theme::cur();
    Style::default()
        .fg(t.bg_dark)
        .bg(t.cyan)
        .add_modifier(Modifier::BOLD)
}

/// Unselected row style inside the menu family. Plain fg on the
/// `bg2` panel fill — matches [`popup_menu`]'s background.
pub fn row_plain_menu() -> Style {
    let t = theme::cur();
    Style::default().fg(t.fg).bg(t.bg2)
}

/// Paint the standard hint row at the bottom of a modal panel — the
/// `Tab field · ↵ save · esc cancel` style help line. Centered
/// horizontally on the last row of `inner`, `hint_style()` colors
/// (comment fg on the panel's own `bg_dark`). Used by any modal
/// whose bottom row is just a shortcut hint (no chip cluster).
pub fn paint_hint_row(frame: &mut Frame, inner: Rect, hint: &str) {
    if inner.width == 0 || inner.height == 0 {
        return;
    }
    let y = inner.y + inner.height.saturating_sub(1);
    let row = Rect {
        x: inner.x,
        y,
        width: inner.width,
        height: 1,
    };
    let pad = inner.width.saturating_sub(hint.chars().count() as u16) / 2;
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(
            format!("{}{hint}", " ".repeat(pad as usize)),
            hint_style(),
        ))),
        row,
    );
}

/// A palette-bar chip — a 3-cell ` glyph ` span on the chrome row's
/// `bg_dark`. Active chips (an open panel toggle, a focused tool)
/// use cyan fg; inactive use `comment` fg. Used by the sidebar +
/// right-panel toggles, launcher icons, integration icons, and any
/// future top-row chip. Keeps all top-row glyphs reading as the
/// same primitive.
pub fn chip_bar_span(glyph: impl AsRef<str>, active: bool) -> Span<'static> {
    let t = theme::cur();
    let fg = if active { t.cyan } else { t.comment };
    Span::styled(
        format!(" {} ", glyph.as_ref()),
        Style::default().fg(fg).bg(t.bg_dark),
    )
}

/// Style for a section-label row inside a modal — the dim italic
/// tag above a group of related fields (e.g. `preview` label above
/// the preview area). Optional; use where visual grouping helps.
pub fn section_label_style() -> Style {
    let t = theme::cur();
    Style::default()
        .fg(t.comment)
        .bg(t.bg_dark)
        .add_modifier(Modifier::ITALIC)
}
