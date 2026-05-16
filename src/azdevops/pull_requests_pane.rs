//! `Pane::AzDevOpsPullRequests` state.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AzPrViewMode {
    #[default]
    PerRepo,
    Mine,
}

impl AzPrViewMode {
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
pub struct AzDevOpsPullRequestsPane {
    pub selected: usize,
    pub scroll: usize,
}

impl AzDevOpsPullRequestsPane {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn tab_title(&self) -> String {
        "Azure PRs".to_string()
    }
    pub fn move_selection(&mut self, delta: i64, max_idx: usize) {
        if max_idx == 0 {
            self.selected = 0;
            return;
        }
        let max = (max_idx - 1) as i64;
        self.selected = (self.selected as i64 + delta).clamp(0, max) as usize;
    }
}
