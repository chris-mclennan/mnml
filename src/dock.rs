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
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
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
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub enum DockContent {
    /// Static text — wraps within the widget body. v1 content
    /// variant; the simplest possible payload so the dock chrome
    /// can be exercised before specific data sources land.
    Text(String),
    /// Live tail of a file's last `max_lines` rows. Re-read each
    /// frame (cheap — files are small). Useful for build logs,
    /// test output, AI-session jsonl files, etc.
    LogTail {
        path: std::path::PathBuf,
        max_lines: usize,
    },
}

/// A single corner-pinned widget.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
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
    /// Default `0.5 × 0.25` bottom-left text widget. Convenience
    /// for the bare `dock.new_text` palette command.
    pub fn new_text<S: Into<String>>(id: usize, title: S, body: S) -> Self {
        Self::new_text_at(id, DockCorner::BottomLeft, title, body)
    }

    /// Place a default-sized text widget at any corner. The 4
    /// per-corner palette commands (`dock.new_text_bl` etc.) use
    /// this so they share the default sizing without diverging.
    pub fn new_text_at<S: Into<String>>(
        id: usize,
        corner: DockCorner,
        title: S,
        body: S,
    ) -> Self {
        DockWidget {
            id,
            corner,
            width_frac: 0.5,
            height_frac: 0.25,
            title: title.into(),
            content: DockContent::Text(body.into()),
        }
    }
}

/// Push a new text widget at `corner`. Title increments with each
/// call (`Note 1`, `Note 2`, …) so multiple stacked widgets are
/// visually distinguishable. Shared helper for the 4 per-corner
/// palette commands.
pub fn push_text_at(app: &mut crate::app::App, corner: DockCorner) {
    let id = app.dock_widget_next_id;
    app.dock_widget_next_id += 1;
    let n = app.dock_widgets.len() + 1;
    app.dock_widgets.push(DockWidget::new_text_at(
        id,
        corner,
        format!("Note {n}"),
        format!(
            "Dock widget #{n} at {corner:?}.\nClick × to close, or run `dock.close_all` to clear them all."
        ),
    ));
}

/// Push a log-tail widget. `path` is whatever the user supplied
/// (tilde-expanded by the prompt before this is called).
pub fn push_log_tail(
    app: &mut crate::app::App,
    corner: DockCorner,
    path: std::path::PathBuf,
) {
    let id = app.dock_widget_next_id;
    app.dock_widget_next_id += 1;
    let title = path
        .file_name()
        .and_then(|n| n.to_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| "log".to_string());
    app.dock_widgets.push(DockWidget {
        id,
        corner,
        width_frac: 0.5,
        height_frac: 0.25,
        title,
        content: DockContent::LogTail {
            path,
            max_lines: 16,
        },
    });
}

/// Cycle the most recently added widget to the next corner
/// (BottomLeft → BottomRight → TopRight → TopLeft → BottomLeft).
/// Convenience until right-click move lands.
pub fn cycle_focused_corner(app: &mut crate::app::App) {
    let Some(last) = app.dock_widgets.last_mut() else {
        return;
    };
    last.corner = match last.corner {
        DockCorner::BottomLeft => DockCorner::BottomRight,
        DockCorner::BottomRight => DockCorner::TopRight,
        DockCorner::TopRight => DockCorner::TopLeft,
        DockCorner::TopLeft => DockCorner::BottomLeft,
    };
}
