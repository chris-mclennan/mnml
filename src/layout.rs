//! The window layout. The tree rail, the top bufferline, and the bottom
//! statusline live *outside* this tree; `Layout` describes how the central area
//! is carved into panes. P0 only ever holds `Empty` or a single `Leaf`; the
//! split variants land in P3 — keeping the type here from day one means splits
//! are additive.

/// Index of a pane in `App::panes`.
pub type PaneId = usize;

#[derive(Debug, Clone)]
pub enum Layout {
    Empty,
    Leaf(PaneId),
    // HSplit(Box<Layout>, Box<Layout>, /* ratio×100 of the top */ u16),   // P3
    // VSplit(Box<Layout>, Box<Layout>, /* ratio×100 of the left */ u16),  // P3
}

impl Layout {
    /// The id of the currently-focused leaf, if any. (With splits this will
    /// track a focus path; for now there's at most one leaf.)
    pub fn focused_leaf(&self) -> Option<PaneId> {
        match self {
            Layout::Empty => None,
            Layout::Leaf(id) => Some(*id),
        }
    }

    /// Every pane id referenced by the layout.
    pub fn leaves(&self) -> Vec<PaneId> {
        match self {
            Layout::Empty => Vec::new(),
            Layout::Leaf(id) => vec![*id],
        }
    }

    /// Re-point every leaf that referenced `old` at `new` (used when panes are
    /// removed and the `Vec<Pane>` is re-indexed).
    pub fn remap(&mut self, old: PaneId, new: PaneId) {
        match self {
            Layout::Empty => {}
            Layout::Leaf(id) => {
                if *id == old {
                    *id = new;
                }
            }
        }
    }
}
