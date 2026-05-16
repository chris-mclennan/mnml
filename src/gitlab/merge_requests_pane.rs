//! `Pane::GitlabMergeRequests` state.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GlMrViewMode {
    #[default]
    PerProject,
    Mine,
}

impl GlMrViewMode {
    pub fn cycle(self) -> Self {
        match self {
            Self::PerProject => Self::Mine,
            Self::Mine => Self::PerProject,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Self::PerProject => "per-project",
            Self::Mine => "mine",
        }
    }
}

#[derive(Debug, Default)]
pub struct GitlabMergeRequestsPane {
    pub selected: usize,
    pub scroll: usize,
}

impl GitlabMergeRequestsPane {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn tab_title(&self) -> String {
        "GitLab MRs".to_string()
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
