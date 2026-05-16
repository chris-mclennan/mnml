//! `Pane::BitbucketPullRequests` state. Two view-modes, toggled with `v`:
//!
//! * [`PrViewMode::PerRepo`] — for each configured repo, list the open
//!   PRs (grouped by repo header). Good for "what's pending review on
//!   the repos I track."
//! * [`PrViewMode::Mine`] — cross-repo flat list of every non-merged PR
//!   I authored across every accessible repo (NOT scoped to configured
//!   `[[bitbucket.repos]]`). Good for "what am I on the hook for."
//!
//! Both surfaces are kept fresh by the same worker thread, so flipping
//! is instant.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PrViewMode {
    /// PRs per configured repo. The original pane.
    #[default]
    PerRepo,
    /// PRs I authored across every accessible repo. James's `--mine`.
    Mine,
}

impl PrViewMode {
    pub fn cycle(self) -> Self {
        match self {
            Self::PerRepo => Self::Mine,
            Self::Mine => Self::PerRepo,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::PerRepo => "per-repo",
            Self::Mine => "mine",
        }
    }
}

#[derive(Debug, Default)]
pub struct BitbucketPullRequestsPane {
    pub selected: usize,
    pub scroll: usize,
    pub view_mode: PrViewMode,
}

impl BitbucketPullRequestsPane {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn tab_title(&self) -> String {
        format!("Bitbucket PRs · {}", self.view_mode.label())
    }

    pub fn cycle_view(&mut self) -> PrViewMode {
        self.view_mode = self.view_mode.cycle();
        self.selected = 0;
        self.scroll = 0;
        self.view_mode
    }
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
    fn move_selection_clamps() {
        let mut p = BitbucketPullRequestsPane::new();
        p.move_selection(5, 3);
        assert_eq!(p.selected, 2);
        p.move_selection(-100, 3);
        assert_eq!(p.selected, 0);
    }
}
