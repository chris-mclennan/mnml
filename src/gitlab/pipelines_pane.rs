//! `Pane::GitlabPipelines` state. Mirrors the BB/GH pipelines panes —
//! view-mode + collapse state live on `App`.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GlPipelineViewMode {
    #[default]
    Recent,
    PerBranch,
}

impl GlPipelineViewMode {
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
pub struct GitlabPipelinesPane {
    pub selected: usize,
    pub scroll: usize,
}

impl GitlabPipelinesPane {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn tab_title(&self) -> String {
        "GitLab".to_string()
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
