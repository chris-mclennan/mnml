//! Which thing has the keyboard. P0: the tree rail or the active pane. Later:
//! `Picker` / `Palette` / `Prompt` overlays steal focus while open, and `Pane`
//! gains a pane-id once splits exist.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Tree,
    /// The currently-active pane (per `App::layout` / `App::active`).
    Pane,
    // Picker, Palette, Prompt,  // overlay tracks
}

impl Focus {
    /// `Ctrl+E` cycle order. With panes/overlays this grows; for now it's a flip.
    pub fn next(self, has_pane: bool) -> Focus {
        match self {
            Focus::Tree => {
                if has_pane {
                    Focus::Pane
                } else {
                    Focus::Tree
                }
            }
            Focus::Pane => Focus::Tree,
        }
    }
}
