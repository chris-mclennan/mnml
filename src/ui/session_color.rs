//! Single source of truth for per-session accent colors.
//!
//! Before this module, the palette + name→theme-color resolution +
//! menu labels existed in FIVE files:
//!   - `src/app/mod.rs::assign_auto_accent_color` (PALETTE)
//!   - `src/app/session_pane_methods.rs::set_session_color` (PALETTE)
//!   - `src/app/session_pane_methods.rs::session_color_menu_items`
//!     (MenuItem::new lines)
//!   - `src/ui/pty_view.rs::accent_color_for_pty` (match arms)
//!   - `src/ui/sessions_panel.rs::draw` (match arms)
//!   - `src/ui/mod.rs::pty_icon` (match arms)
//!
//! Adding a color to the palette (task #1179 f/u: user asked for
//! "8 colors, not 7 plus none" → had to touch every duplicate to
//! keep them in sync). Consolidated here so ONE list drives every
//! surface. If a color name isn't in [`PALETTE`], [`resolve`]
//! returns `None`.
//!
//! Convention: [`PALETTE`] slot 0 is the brand default ("orange"
//! for Claude Code — see `assign_auto_accent_color`); slots 1..
//! are the tell-them-apart palette.

use ratatui::style::Color;

use crate::ui::theme::Theme;

/// Ordered palette used by both the auto-color assigner and the
/// right-click "Color: …" menu. Slot 0 (green) is the first Claude
/// session's default so it also serves as the "active session"
/// visual cue that pre-existed the auto-color feature; slots 1..
/// rotate so multi-session Claude clusters stay visually distinct.
///
/// Order defines both the auto-cycle order AND the menu order —
/// user request 2026-08-23: "issue them in same order as show in
/// list". Add entries and every surface picks them up in the new
/// order automatically.
pub const PALETTE: &[&str] = &[
    "green", "blue", "yellow", "orange", "red", "purple", "cyan", "pink",
];

/// Resolve a stored color name (as written into
/// `PtySession.accent_color`) to a concrete theme color. Returns
/// `None` for unknown names OR the sentinel `"none"` string — call
/// sites decide what fallback to use.
pub fn resolve(name: &str, t: &Theme) -> Option<Color> {
    match name {
        "orange" => Some(t.orange),
        "blue" => Some(t.blue),
        "purple" => Some(t.purple),
        "cyan" => Some(t.cyan),
        "green" => Some(t.green),
        "yellow" => Some(t.yellow),
        "red" => Some(t.red),
        "pink" => Some(t.pink),
        _ => None,
    }
}

/// Human-readable menu label for a color name. Kept alongside
/// [`PALETTE`] so the right-click menu stays in lockstep — add a
/// color to PALETTE + here in one edit and every surface picks it up.
pub fn menu_label(name: &str) -> &'static str {
    match name {
        "orange" => "Color: Orange",
        "blue" => "Color: Blue",
        "purple" => "Color: Purple",
        "cyan" => "Color: Cyan",
        "green" => "Color: Green",
        "yellow" => "Color: Yellow",
        "red" => "Color: Red",
        "pink" => "Color: Pink",
        _ => "Color: ?",
    }
}
