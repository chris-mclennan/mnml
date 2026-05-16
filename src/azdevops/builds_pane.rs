//! `Pane::AzDevOpsBuilds` state.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AzBuildsViewMode {
    #[default]
    Recent,
    PerBranch,
}

impl AzBuildsViewMode {
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
pub struct AzDevOpsBuildsPane {
    pub selected: usize,
    pub scroll: usize,
}

impl AzDevOpsBuildsPane {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn tab_title(&self) -> String {
        "Azure Builds".to_string()
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
