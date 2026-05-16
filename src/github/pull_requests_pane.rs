//! `Pane::GithubPullRequests` state — sibling of
//! [`crate::bitbucket::BitbucketPullRequestsPane`].

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum GhPrViewMode {
    #[default]
    PerRepo,
    Mine,
}

impl GhPrViewMode {
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
pub struct GithubPullRequestsPane {
    pub selected: usize,
    pub scroll: usize,
    pub view_mode: GhPrViewMode,
    pub collapsed_repos: std::collections::HashSet<String>,
}

impl GithubPullRequestsPane {
    pub fn toggle_collapsed(&mut self, header_label: &str) -> bool {
        if self.collapsed_repos.contains(header_label) {
            self.collapsed_repos.remove(header_label);
            false
        } else {
            self.collapsed_repos.insert(header_label.to_string());
            true
        }
    }
    pub fn is_collapsed(&self, header_label: &str) -> bool {
        self.collapsed_repos.contains(header_label)
    }
}

impl GithubPullRequestsPane {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn tab_title(&self) -> String {
        format!("GitHub PRs · {}", self.view_mode.label())
    }
    pub fn cycle_view(&mut self) -> GhPrViewMode {
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
        let mut p = GithubPullRequestsPane::new();
        p.move_selection(99, 5);
        assert_eq!(p.selected, 4);
    }
}
