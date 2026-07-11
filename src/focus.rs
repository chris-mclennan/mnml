//! Which thing has the keyboard. P0: the tree rail or the active pane. Later:
//! `Picker` / `Palette` / `Prompt` overlays steal focus while open, and `Pane`
//! gains a pane-id once splits exist.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Tree,
    /// The currently-active pane (per `App::layout` / `App::active`).
    Pane,
    /// The right-side panel (outline / diagnostics / grep / …). Only
    /// reachable when `App::right_panel_visible` is true. Ctrl+E cycles
    /// through this when present. keyboard-round-7 SEV-2 #1 —
    /// previously the right panel had no keyboard focus path.
    RightPanel,
    // Picker, Palette, Prompt,  // overlay tracks
}

impl Focus {
    /// `Ctrl+E` cycle order. Tree → Pane → RightPanel → Tree.
    /// Skips panels that aren't currently reachable.
    pub fn next(self, has_pane: bool, has_right_panel: bool) -> Focus {
        match self {
            Focus::Tree => {
                if has_pane {
                    Focus::Pane
                } else if has_right_panel {
                    Focus::RightPanel
                } else {
                    Focus::Tree
                }
            }
            Focus::Pane => {
                if has_right_panel {
                    Focus::RightPanel
                } else {
                    Focus::Tree
                }
            }
            Focus::RightPanel => Focus::Tree,
        }
    }
}
