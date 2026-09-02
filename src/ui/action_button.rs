//! Shared visual language for the "primary" and "secondary" action
//! chips that sit at the top of every activity-bar panel — the
//! `+ New session`, `+ New note`, `+ from PR`, `+ New Cloud Run`
//! family.
//!
//! Before this module lived here the chips had drifted individually:
//! agents_panel used a solid green + solid cyan (the reference the
//! user liked), but sessions_panel and notes_panel used `bg2` (grey)
//! chips with green text — which visually blended into the filter
//! row's grey chip immediately above. User ask 2026-08-23:
//! "lets set a constant for these buttons and keep them in sync ...
//! primary and secondary buttons ... each of these areas in
//! activity bar should have same look and feel".
//!
//! Two roles, sourced from the active theme so a theme change flows
//! through every panel automatically:
//!
//! - **Primary** — the panel's main call-to-action ("+ New X").
//!   Green fill, dark text.
//! - **Secondary** — a peer action on the same row ("+ from PR",
//!   "Import…"). Purple fill, dark text.
//!
//! Callers wrap a label in [`chip_line`] to render a full padded
//! button, or grab [`primary`]/[`secondary`] directly if they need
//! to compose spans by hand.

use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span},
};

use crate::ui::theme::Theme;

/// Pure black used as the label fg on filled `primary` /
/// `secondary` chips. The theme's `bg_darker` isn't dark enough
/// against mid-brightness fills (soft-green / soft-purple) —
/// user report 2026-08-23: chip label unreadable when routed
/// through `bg_darker`. Rgb(0,0,0) guarantees max contrast
/// across every theme.
const CHIP_LABEL_FG: Color = Color::Rgb(0, 0, 0);

/// Primary action chip style — the panel's main call-to-action.
/// Solid green fill + black text. Use for toolbar-level actions
/// (`+ New session`, `+ New note`).
#[inline]
pub fn primary(t: &Theme) -> Style {
    Style::default()
        .fg(CHIP_LABEL_FG)
        .bg(t.green)
        .add_modifier(Modifier::BOLD)
}

/// Secondary action chip style — a peer action on the same row.
/// Solid purple fill + black text. Use next to a `primary` chip
/// when the panel has two peer create-flows (`+ from PR`).
#[inline]
pub fn secondary(t: &Theme) -> Style {
    Style::default()
        .fg(CHIP_LABEL_FG)
        .bg(t.purple)
        .add_modifier(Modifier::BOLD)
}

/// Text-link "add row" style — green text on the panel's own
/// background, no chip fill. Use for inline "+ New X" prompts
/// that sit at the end of a listed section (HTTP's per-section
/// `+ New request` / `+ New env` / `+ New chain` /
/// `+ New collection`) where a filled chip would read as a
/// heavy button in the middle of a list.
#[inline]
pub fn link(t: &Theme, bg: Color) -> Style {
    Style::default()
        .fg(t.green)
        .bg(bg)
        .add_modifier(Modifier::BOLD)
}

/// Render a full labeled chip: 1-cell pad + label + 1-cell pad, all
/// on the given `role_style`'s background. Returns a `Line` the
/// caller can drop into a `Paragraph` at a `Rect` sized to
/// [`chip_width`]. `role_style` is either [`primary`] or
/// [`secondary`].
pub fn chip_line(label: &str, role_style: Style) -> Line<'_> {
    Line::from(vec![
        Span::styled(" ", role_style),
        Span::styled(label.to_string(), role_style),
        Span::styled(" ", role_style),
    ])
}

/// Cell width of the chip [`chip_line`] renders — label plus the
/// two 1-cell pads.
#[inline]
pub fn chip_width(label: &str) -> u16 {
    (label.chars().count() as u16).saturating_add(2)
}

// ──────────────────────────────────────────────────────────────────
// Button — the general component. Use this for ANY new button.
// ──────────────────────────────────────────────────────────────────

/// Visual state of a [`Button`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ButtonState {
    /// Normal, clickable.
    #[default]
    Normal,
    /// Inert — painted but not actionable. Dimmed, and callers should
    /// skip registering a click rect so a visible button is never a
    /// dead click.
    Disabled,
    /// Currently-active / toggled-on (a pressed tab, an enabled mode).
    Active,
}

/// One button, described declaratively.
///
/// Added 2026-08-29 on a user ask — "we should probably have a design
/// component for this stuff ... anywhere we want buttons we use that
/// component ... should support icon, label, bg, fg, font color, other
/// things too perhaps".
///
/// Before this, every surface hand-rolled its own chip and they drifted:
/// the git toolbar painted transparent labels separated by `│` dividers
/// (so they did not read as buttons at all), while activity panels used
/// the filled [`primary`] / [`secondary`] chips. This type is the single
/// description; the role constructors below are the house styles.
///
/// Build with a role constructor and override what you need:
///
/// ```ignore
/// let b = Button::toolbar(&t, "Pull").icon("\u{F0450}").accent(t.green);
/// let spans = b.spans();          // drop into a Line
/// let w = b.width();              // size the Rect / click target
/// ```
#[derive(Debug, Clone)]
pub struct Button<'a> {
    /// Optional leading glyph, rendered in [`Self::accent`].
    pub icon: Option<&'a str>,
    pub label: &'a str,
    /// Chip background.
    pub fill: Color,
    /// Label foreground.
    pub text: Color,
    /// Icon foreground. Falls back to [`Self::text`] when unset — an
    /// icon-less or single-colour button needs no accent.
    pub accent: Option<Color>,
    pub bold: bool,
    pub state: ButtonState,
}

impl<'a> Button<'a> {
    /// Neutral **toolbar** button — a raised chip on a darker strip.
    ///
    /// Distinct from [`primary`] / [`secondary`] because a toolbar is a
    /// ROW OF PEERS, not one call-to-action. The git toolbar carries a
    /// dozen buttons, each with its own accent on the icon (green Pull,
    /// blue Push, yellow Stash…), and those accents are what make the
    /// row scannable. Filling every chip green would shout AND destroy
    /// that signal — so the fill is neutral `bg2` and the accent stays
    /// on the icon.
    ///
    /// `bg2` is the same fill the tab chips and palette-bar chips use,
    /// so a toolbar button reads as the same physical object as the rest
    /// of mnml's chrome.
    pub fn toolbar(t: &Theme, label: &'a str) -> Self {
        Self {
            icon: None,
            label,
            fill: t.bg2,
            text: t.fg,
            accent: None,
            bold: true,
            state: ButtonState::Normal,
        }
    }

    /// The refresh affordance, in one of its two sizes.
    ///
    /// `label: None` is the COMPACT form — icon only, for a tight panel
    /// header. `Some(word)` is the EXPANDED form for a toolbar with
    /// room for it. Both are the same button with the same glyph, which
    /// is the point: the family had drifted to three different refresh
    /// icons — core's codicon, Jira's `⟳`, Bitbucket's `\u{f0450}` —
    /// each with its own spacing.
    ///
    /// Deliberately a constructor on THIS component rather than a
    /// `RefreshChip` of its own: `Button` already carries icon, label,
    /// fill, accent and state, so a second chip type would be a
    /// parallel system to keep in sync (user: "i have asked for
    /// components before ... we may have some already").
    ///
    /// The glyph still comes from [`crate::ui::refresh_glyph`], which
    /// stays the single source of truth for WHICH glyph; this decides
    /// how it is dressed.
    pub fn refresh(t: &Theme, ascii: bool, label: Option<&'a str>) -> Self {
        Self {
            icon: Some(crate::ui::refresh_glyph::for_ascii(ascii)),
            label: label.unwrap_or(""),
            fill: t.bg2,
            text: t.fg,
            accent: Some(t.blue),
            bold: false,
            state: ButtonState::Normal,
        }
    }

    /// The panel's main call-to-action — green fill, black text. Same
    /// visual as the free function [`primary`].
    pub fn primary(t: &Theme, label: &'a str) -> Self {
        Self {
            icon: None,
            label,
            fill: t.green,
            text: CHIP_LABEL_FG,
            accent: None,
            bold: true,
            state: ButtonState::Normal,
        }
    }

    /// A peer create-flow beside a [`Self::primary`] — purple fill.
    pub fn secondary(t: &Theme, label: &'a str) -> Self {
        Self {
            icon: None,
            label,
            fill: t.purple,
            text: CHIP_LABEL_FG,
            accent: None,
            bold: true,
            state: ButtonState::Normal,
        }
    }

    pub fn icon(mut self, icon: &'a str) -> Self {
        self.icon = Some(icon);
        self
    }
    pub fn accent(mut self, c: Color) -> Self {
        self.accent = Some(c);
        self
    }
    pub fn fill(mut self, c: Color) -> Self {
        self.fill = c;
        self
    }
    pub fn text(mut self, c: Color) -> Self {
        self.text = c;
        self
    }
    pub fn bold(mut self, on: bool) -> Self {
        self.bold = on;
        self
    }
    pub fn state(mut self, s: ButtonState) -> Self {
        self.state = s;
        self
    }

    /// Cell width: 1 pad + (icon + 1 space, when present) + label + 1
    /// pad. Size the click rect to this — the pads are part of the
    /// target, which matters for a 1-cell glyph.
    pub fn width(&self) -> u16 {
        let icon_w = self.icon.map(|i| i.chars().count() as u16 + 1).unwrap_or(0);
        icon_w
            .saturating_add(self.label.chars().count() as u16)
            .saturating_add(2)
    }

    /// Render to spans. Owned (`'static`) so callers can build a row of
    /// buttons without fighting the borrow checker over theme lifetimes.
    pub fn spans(&self, t: &Theme) -> Vec<Span<'static>> {
        let (fill, text, dim) = match self.state {
            ButtonState::Normal => (self.fill, self.text, false),
            // Inert: keep the chip shape so the row does not reflow, but
            // drop it back so it never reads as actionable.
            ButtonState::Disabled => (self.fill, t.comment, true),
            ButtonState::Active => (t.blue, CHIP_LABEL_FG, false),
        };
        let mut base = Style::default().fg(text).bg(fill);
        if self.bold {
            base = base.add_modifier(Modifier::BOLD);
        }
        if dim {
            base = base.add_modifier(Modifier::DIM);
        }
        let mut out = vec![Span::styled(" ".to_string(), base)];
        if let Some(icon) = self.icon {
            let icon_style = match self.state {
                // A disabled button's accent would still draw the eye.
                ButtonState::Disabled => base,
                _ => base.fg(self.accent.unwrap_or(text)),
            };
            out.push(Span::styled(icon.to_string(), icon_style));
            out.push(Span::styled(" ".to_string(), base));
        }
        out.push(Span::styled(self.label.to_string(), base));
        out.push(Span::styled(" ".to_string(), base));
        out
    }
}

/// Lay a row of buttons out with 1-cell gaps, centred in `width`.
///
/// Returns the leading pad and the per-button x offsets (relative to the
/// row's own x), so the caller can register click rects that line up
/// with the paint. Centring is the point: a left-aligned toolbar on a
/// wide window leaves the whole right half empty, which the user
/// reported as "when zoomed out it looks pretty bad".
pub fn centred_row(buttons: &[Button<'_>], width: u16, gap: u16) -> (u16, Vec<u16>) {
    let total: u16 = buttons
        .iter()
        .map(|b| b.width())
        .sum::<u16>()
        .saturating_add(gap.saturating_mul(buttons.len().saturating_sub(1) as u16));
    let lead = width.saturating_sub(total) / 2;
    let mut xs = Vec::with_capacity(buttons.len());
    let mut x = lead;
    for b in buttons {
        xs.push(x);
        x += b.width() + gap;
    }
    (lead, xs)
}

#[cfg(test)]
mod button_tests {
    use super::*;
    use crate::ui::theme;

    /// The refresh button's two modes must carry the SAME glyph. That
    /// is the whole reason it is a constructor here rather than each
    /// caller assembling its own chip: the family had drifted to three
    /// different refresh icons.
    #[test]
    fn both_refresh_modes_use_one_glyph() {
        let t = crate::ui::theme::cur();
        let compact = Button::refresh(&t, false, None);
        let expanded = Button::refresh(&t, false, Some("Refresh"));
        assert_eq!(
            compact.icon, expanded.icon,
            "the compact and expanded refresh buttons disagree on the glyph"
        );
        assert_eq!(
            compact.icon,
            Some(crate::ui::refresh_glyph::NERD),
            "the refresh button stopped using the canonical glyph"
        );
    }

    /// ASCII mode must reach the icon, or a non-Nerd-Font terminal gets
    /// a replacement box in both modes.
    #[test]
    fn refresh_honours_ascii_mode() {
        let t = crate::ui::theme::cur();
        assert_eq!(
            Button::refresh(&t, true, Some("Refresh")).icon,
            Some(crate::ui::refresh_glyph::ASCII)
        );
    }

    /// Compact is icon-only; expanded adds the word. Asserted through
    /// `width()` because that is what callers size their click rect
    /// with — a chip wider than its rect clips itself.
    #[test]
    fn expanded_is_wider_than_compact_by_its_label() {
        let t = crate::ui::theme::cur();
        let compact = Button::refresh(&t, false, None);
        let expanded = Button::refresh(&t, false, Some("Refresh"));
        assert_eq!(
            expanded.width() - compact.width(),
            "Refresh".chars().count() as u16,
            "the expanded button is not exactly its label wider"
        );
    }

    #[test]
    fn width_counts_the_pads_and_the_icon_space() {
        let t = theme::cur();
        assert_eq!(
            Button::toolbar(&t, "Pull").width(),
            6,
            "` Pull ` = 4 + 2 pads"
        );
        assert_eq!(
            Button::toolbar(&t, "Pull").icon("x").width(),
            8,
            "` x Pull ` = icon + space + label + 2 pads"
        );
    }

    /// The rendered span run must be exactly as wide as `width()` claims,
    /// or every click rect in every toolbar is off by a cell.
    #[test]
    fn rendered_width_matches_the_declared_width() {
        let t = theme::cur();
        for b in [
            Button::toolbar(&t, "Pull"),
            Button::toolbar(&t, "Pull").icon("\u{F0450}"),
            Button::primary(&t, "+ New session"),
            Button::secondary(&t, "+ from PR").icon("*"),
        ] {
            let painted: usize = b.spans(&t).iter().map(|s| s.content.chars().count()).sum();
            assert_eq!(
                painted as u16,
                b.width(),
                "label {:?}: painted {painted} cells but width() said {}",
                b.label,
                b.width()
            );
        }
    }

    /// #1229 — the whole point of the row helper. A left-aligned toolbar
    /// on a wide window leaves the right half empty ("when zoomed out it
    /// looks pretty bad").
    #[test]
    fn centred_row_leaves_equal_margins() {
        let t = theme::cur();
        let bs = [Button::toolbar(&t, "A"), Button::toolbar(&t, "B")];
        // Each ` A ` = 3 cells, gap 1 => total 7. In 21 cells, lead = 7.
        let (lead, xs) = centred_row(&bs, 21, 1);
        assert_eq!(lead, 7);
        assert_eq!(xs, vec![7, 11]);
        let right_margin = 21 - (xs[1] + bs[1].width());
        assert_eq!(
            lead, right_margin,
            "margins are not equal: {lead} vs {right_margin}"
        );
    }

    /// Must not underflow or misplace when the row is wider than the
    /// space — the caller drops buttons, but this must stay sane meanwhile.
    #[test]
    fn centred_row_degrades_to_zero_lead_when_too_narrow() {
        let t = theme::cur();
        let bs = [Button::toolbar(&t, "Wide label here")];
        let (lead, xs) = centred_row(&bs, 4, 1);
        assert_eq!(lead, 0);
        assert_eq!(xs, vec![0]);
    }

    /// A disabled button keeps its footprint so the row does not reflow,
    /// but must not carry its accent colour — that would still draw the
    /// eye to something inert.
    #[test]
    fn disabled_keeps_its_width_but_drops_the_accent() {
        let t = theme::cur();
        let normal = Button::toolbar(&t, "Pop").icon("x").accent(t.yellow);
        let off = normal.clone().state(ButtonState::Disabled);
        assert_eq!(normal.width(), off.width());
        let accent_used = off.spans(&t).iter().any(|s| s.style.fg == Some(t.yellow));
        assert!(!accent_used, "disabled button still painted its accent");
    }
}
