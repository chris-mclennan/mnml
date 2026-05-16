//! `Pane::BitbucketPipelines` state. Two view-modes, toggled with `v`:
//!
//! * [`PipelineViewMode::Recent`] — newest-N pipelines per configured
//!   repo, grouped by repo header. Good for "what just ran across the
//!   org" — archeology mode.
//! * [`PipelineViewMode::PerBranch`] — for each configured repo, latest
//!   pipeline per long-lived branch (main / develop / staging / active
//!   release/hotfix + any user-configured `branches = […]`). Good for
//!   "where do my critical branches stand right now" — ops mode.
//!
//! Pipeline data for both views is fetched every poll cycle by the same
//! worker, so flipping with `v` is instant — no fetch latency.
//!
//! The pane is otherwise stateless beyond selection + scroll + which
//! view-mode is active. Data lives on `App.bitbucket_pipelines` (Recent)
//! and `App.bitbucket_branch_pipelines` (PerBranch).

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PipelineViewMode {
    /// Newest-N pipelines per repo, mixed branches. The original pane.
    #[default]
    Recent,
    /// Latest pipeline per long-lived branch per repo. James's
    /// `bbwatch.py pipelines` mental model.
    PerBranch,
}

impl PipelineViewMode {
    pub fn cycle(self) -> Self {
        match self {
            Self::Recent => Self::PerBranch,
            Self::PerBranch => Self::Recent,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::Recent => "recent",
            Self::PerBranch => "per-branch",
        }
    }
}

/// Per-pane ephemeral state. The persistent bits (view_mode +
/// `collapsed_repos`) live on `App` so they survive pane close +
/// session restore. The pane itself only tracks where the user is
/// looking right now.
#[derive(Debug, Default)]
pub struct BitbucketPipelinesPane {
    pub selected: usize,
    pub scroll: usize,
}

impl BitbucketPipelinesPane {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn tab_title(&self) -> String {
        "Bitbucket".to_string()
    }

    /// Move the selection by `delta` items, clamped to `[0, max_idx)`.
    /// A `max_idx` of `0` is a no-op (empty list — nothing to select).
    pub fn move_selection(&mut self, delta: i64, max_idx: usize) {
        if max_idx == 0 {
            self.selected = 0;
            return;
        }
        let max = (max_idx - 1) as i64;
        let next = (self.selected as i64 + delta).clamp(0, max) as usize;
        self.selected = next;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn move_selection_clamps_to_max() {
        let mut p = BitbucketPipelinesPane::new();
        p.move_selection(1, 3);
        assert_eq!(p.selected, 1);
        p.move_selection(100, 3);
        assert_eq!(p.selected, 2);
        p.move_selection(-100, 3);
        assert_eq!(p.selected, 0);
    }

    #[test]
    fn move_selection_noop_on_empty() {
        let mut p = BitbucketPipelinesPane::new();
        p.move_selection(5, 0);
        assert_eq!(p.selected, 0);
        // Once items exist, selection should land at 0 not stay invalid.
        p.move_selection(10, 1);
        assert_eq!(p.selected, 0);
    }
}
