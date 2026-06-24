//! Small corner-pinned dock widgets — a third tier of UI surface
//! between full editor panes and 1-row status chrome.
//!
//! Each widget occupies a fraction of the editor body
//! (`width_frac × height_frac`, default `0.5 × 0.25`), pinned to one
//! of four corners. Multiple widgets sharing a corner stack inward
//! from the corner.
//!
//! Use cases (future content variants):
//!   - Mini build / test status
//!   - Live-tail a Claude Code / Codex session's last few lines
//!   - Notification dock
//!   - Quick worktree status
//!
//! Slice 1 (this commit): data model + bottom-left rendering +
//! `Text` content variant + close × + palette commands. No
//! persistence; layout doesn't survive a restart.

/// Which corner of the editor body a dock widget is pinned to.
/// Stacking direction within a corner: bottom corners stack
/// UPWARD; top corners stack DOWNWARD.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DockCorner {
    BottomLeft,
    BottomRight,
    TopLeft,
    TopRight,
}

/// What the dock widget renders inside its body. Held as an enum
/// so future variants (live Claude tail, build status, log tail,
/// custom plugin content) can land without touching the renderer
/// for existing variants.
#[derive(Debug, Clone)]
pub enum DockContent {
    /// Static text — wraps within the widget body. v1 content
    /// variant; the simplest possible payload so the dock chrome
    /// can be exercised before specific data sources land.
    Text(String),
}

/// A single corner-pinned widget.
#[derive(Debug, Clone)]
pub struct DockWidget {
    /// Stable id used by the click-rect dispatch to look the
    /// widget back up. Assigned by `App` on insert; monotonically
    /// increasing within a session.
    pub id: usize,
    pub corner: DockCorner,
    /// Fraction of the editor-body WIDTH this widget should
    /// occupy. Clamped to `0.15..=0.9` at render time so a widget
    /// can never be unusably narrow or smother the editor.
    pub width_frac: f32,
    /// Fraction of the editor-body HEIGHT. Same clamp range.
    pub height_frac: f32,
    /// Title shown in the widget's 1-row title bar.
    pub title: String,
    /// Body payload.
    pub content: DockContent,
}

impl DockWidget {
    /// Default `0.5 × 0.25` bottom-left text widget. Used by the
    /// `dock.new_text` palette command when the user doesn't
    /// specify size / corner overrides.
    pub fn new_text<S: Into<String>>(id: usize, title: S, body: S) -> Self {
        DockWidget {
            id,
            corner: DockCorner::BottomLeft,
            width_frac: 0.5,
            height_frac: 0.25,
            title: title.into(),
            content: DockContent::Text(body.into()),
        }
    }
}
