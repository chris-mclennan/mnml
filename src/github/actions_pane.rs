//! `Pane::GithubActions` state. Sibling of
//! [`crate::bitbucket::BitbucketPipelinesPane`] — `view_mode` and
//! `collapsed_repos` live on `App` so they persist across pane
//! close + session restore.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ActionsViewMode {
    #[default]
    Recent,
    PerBranch,
}

impl ActionsViewMode {
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

#[derive(Debug, Default)]
pub struct GithubActionsPane {
    pub selected: usize,
    pub scroll: usize,
}

impl GithubActionsPane {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn tab_title(&self) -> String {
        "GitHub Actions".to_string()
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
        let mut p = GithubActionsPane::new();
        p.move_selection(5, 3);
        assert_eq!(p.selected, 2);
        p.move_selection(-100, 3);
        assert_eq!(p.selected, 0);
    }

    #[test]
    fn move_selection_noop_on_empty() {
        let mut p = GithubActionsPane::new();
        p.move_selection(2, 0);
        assert_eq!(p.selected, 0);
    }
}
