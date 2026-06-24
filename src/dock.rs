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

/// How the widget interacts with the editor body:
///   - `Overlay` — paints on top of the editor (today's default).
///     Widgets at the same edge stack vertically.
///   - `Inline` — claims its own strip; editor reflows around it.
///     Multiple inline widgets at the same edge tile horizontally
///     by `width_frac`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Layout {
    Overlay,
    Inline,
}

/// Background fill policy. `Solid` paints a full bg under the
/// widget (today's default). `Translucent` skips the body bg fill
/// so the editor text underneath shows through; title bar + border
/// still get a bg so the widget remains visible.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Opacity {
    Solid,
    Translucent,
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
    /// Overlay (default) vs Inline. See `Layout` docs.
    #[serde(default = "default_layout")]
    pub layout: Layout,
    /// Solid (default) vs Translucent. See `Opacity` docs.
    #[serde(default = "default_opacity")]
    pub opacity: Opacity,
}

fn default_layout() -> Layout {
    Layout::Overlay
}
fn default_opacity() -> Opacity {
    Opacity::Solid
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
            layout: Layout::Overlay,
            opacity: Opacity::Solid,
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
        layout: Layout::Overlay,
        opacity: Opacity::Solid,
    });
}

/// Named size presets surfaced in the kebab menu's `Resize ▸`
/// sub-list. Mapping to `(width_frac, height_frac)`:
///   - Small  → 0.25 × 0.15
///   - Medium → 0.5  × 0.25  (default)
///   - Large  → 0.5  × 0.4
///   - Wide   → 0.9  × 0.25
///   - Tall   → 0.5  × 0.5
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SizePreset {
    Small,
    Medium,
    Large,
    Wide,
    Tall,
}

impl SizePreset {
    pub fn fractions(self) -> (f32, f32) {
        match self {
            SizePreset::Small => (0.25, 0.15),
            SizePreset::Medium => (0.5, 0.25),
            SizePreset::Large => (0.5, 0.4),
            SizePreset::Wide => (0.9, 0.25),
            SizePreset::Tall => (0.5, 0.5),
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            SizePreset::Small => "Small",
            SizePreset::Medium => "Medium",
            SizePreset::Large => "Large",
            SizePreset::Wide => "Wide",
            SizePreset::Tall => "Tall",
        }
    }
}

/// One row in the kebab menu. Flat-list shape so the dispatcher
/// can pick by index — sub-menus are inlined under their headers
/// for v1 (no nested popups).
#[derive(Debug, Clone, Copy)]
pub enum KebabMenuItem {
    /// Header row, not selectable.
    Header(&'static str),
    Separator,
    Resize(SizePreset),
    MoveTo(DockCorner),
    SetLayout(Layout),
    SetOpacity(Opacity),
    Close,
}

/// Open kebab-menu state.
#[derive(Debug, Clone)]
pub struct KebabMenuState {
    /// Which widget the menu belongs to.
    pub widget_id: usize,
    /// Anchor cell (where the `⋮` was). The menu renders just
    /// below this; clamped to screen edges on the right / bottom.
    pub anchor_x: u16,
    pub anchor_y: u16,
    /// Highlighted row (used by keyboard nav; click bypasses it).
    pub selected: usize,
    /// Materialized item list — built once at open so renderer +
    /// dispatcher agree on indices.
    pub items: Vec<KebabMenuItem>,
}

impl KebabMenuState {
    pub fn build(widget_id: usize, anchor_x: u16, anchor_y: u16) -> Self {
        let mut items = Vec::new();
        items.push(KebabMenuItem::Header("Resize"));
        for p in [
            SizePreset::Small,
            SizePreset::Medium,
            SizePreset::Large,
            SizePreset::Wide,
            SizePreset::Tall,
        ] {
            items.push(KebabMenuItem::Resize(p));
        }
        items.push(KebabMenuItem::Separator);
        items.push(KebabMenuItem::Header("Move to"));
        for c in [
            DockCorner::BottomLeft,
            DockCorner::BottomRight,
            DockCorner::TopLeft,
            DockCorner::TopRight,
        ] {
            items.push(KebabMenuItem::MoveTo(c));
        }
        items.push(KebabMenuItem::Separator);
        items.push(KebabMenuItem::Header("Layout"));
        items.push(KebabMenuItem::SetLayout(Layout::Overlay));
        items.push(KebabMenuItem::SetLayout(Layout::Inline));
        items.push(KebabMenuItem::Separator);
        items.push(KebabMenuItem::Header("Opacity"));
        items.push(KebabMenuItem::SetOpacity(Opacity::Solid));
        items.push(KebabMenuItem::SetOpacity(Opacity::Translucent));
        items.push(KebabMenuItem::Separator);
        items.push(KebabMenuItem::Close);
        KebabMenuState {
            widget_id,
            anchor_x,
            anchor_y,
            selected: 1, // skip the leading "Resize" header
            items,
        }
    }
}

/// Apply a kebab-menu choice to its widget. The dispatcher calls
/// this when the user clicks a row or presses Enter on a
/// keyboard-selected row.
pub fn apply_kebab_choice(app: &mut crate::app::App, widget_id: usize, item: KebabMenuItem) {
    match item {
        KebabMenuItem::Header(_) | KebabMenuItem::Separator => {}
        KebabMenuItem::Resize(preset) => {
            if let Some(w) = app.dock_widgets.iter_mut().find(|w| w.id == widget_id) {
                let (wf, hf) = preset.fractions();
                w.width_frac = wf;
                w.height_frac = hf;
            }
        }
        KebabMenuItem::MoveTo(corner) => {
            if let Some(w) = app.dock_widgets.iter_mut().find(|w| w.id == widget_id) {
                w.corner = corner;
            }
        }
        KebabMenuItem::SetLayout(layout) => {
            if let Some(w) = app.dock_widgets.iter_mut().find(|w| w.id == widget_id) {
                w.layout = layout;
            }
        }
        KebabMenuItem::SetOpacity(opacity) => {
            if let Some(w) = app.dock_widgets.iter_mut().find(|w| w.id == widget_id) {
                w.opacity = opacity;
            }
        }
        KebabMenuItem::Close => {
            app.dock_widgets.retain(|w| w.id != widget_id);
        }
    }
    app.dock_kebab_menu = None;
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
