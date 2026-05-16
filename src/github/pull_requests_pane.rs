//! `Pane::GithubPullRequests` state — sibling of
//! [`crate::bitbucket::BitbucketPullRequestsPane`]. View-mode +
//! collapse state live on `App`.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
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
}

impl GithubPullRequestsPane {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn tab_title(&self) -> String {
        "GitHub PRs".to_string()
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
