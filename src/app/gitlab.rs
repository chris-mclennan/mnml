//! GitLab CI / Merge Requests dashboard methods on `App`.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//! (`.local/PLAN.md` Phase A.3). Pure non-destructive move: no API
//! change. The methods here all manipulate `App` state declared in
//! `app/mod.rs` and use `Gitlab*` / `MergeRequest*` types from
//! `crate::gitlab`.

use super::*;

impl App {
    /// `L` on the selected GitLab pipeline row — open a log viewer pane
    /// and kick off a background fetch of the pipeline's combined per-job
    /// trace. Same scaffolding as [`Self::open_github_run_log`].
    pub fn open_gitlab_pipeline_log(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::GitlabPipelines(pane)) = self.panes.get(id) else {
            self.toast("not a GitLab pipelines pane");
            return;
        };
        let Some(pipeline) = crate::ui::gitlab_pipelines_view::selected_pipeline(self, pane) else {
            self.toast("no pipeline selected");
            return;
        };
        let base_url = self.config.gitlab.base_url_or_default().to_string();
        let title = format!("{} · pipeline #{}", pipeline.project, pipeline.iid);
        let job_id = self.pipeline_log_next_job;
        self.pipeline_log_next_job = self.pipeline_log_next_job.wrapping_add(1);
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let log_pane = crate::bitbucket::PipelineLogPane::new_with_host(
            title,
            crate::bitbucket::LogHost::Gitlab,
            pipeline.project.clone(),
            pipeline.id.to_string(),
            String::new(),
            pipeline.web_url.clone(),
            job_id,
            cancel.clone(),
        )
        .with_host_extra(base_url.clone());
        let pane_v = Pane::BitbucketPipelineLog(log_pane);
        let new_id = self.split_leaf_with(id, crate::layout::SplitDir::Horizontal, pane_v);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
        let auth_env = self
            .config
            .gitlab
            .auth_env
            .clone()
            .unwrap_or_else(|| "GITLAB_TOKEN".to_string());
        self.spawn_log_fetch_inner(
            job_id,
            crate::bitbucket::LogHost::Gitlab,
            auth_env,
            pipeline.project,
            pipeline.id.to_string(),
            String::new(),
            base_url,
            cancel,
        );
    }

    pub fn ensure_gitlab_worker(&mut self) {
        if self.gitlab_handle.is_some() {
            return;
        }
        if !self.config.gitlab.any_configured() {
            return;
        }
        self.gitlab_handle = Some(crate::gitlab::spawn(self.config.gitlab.clone()));
    }

    pub fn open_gitlab_pipelines_pane(&mut self) {
        if !self.config.gitlab.any_configured() {
            self.toast(
                "gitlab: add a [[gitlab.projects]] entry to ~/.config/mnml/config.toml first",
            );
            return;
        }
        self.ensure_gitlab_worker();
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::GitlabPipelines(_)))
        {
            if let Some(h) = &self.gitlab_handle {
                h.force_refresh();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::GitlabPipelines(crate::gitlab::GitlabPipelinesPane::new());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
        self.toast("gitlab: pipelines (loading…)");
    }

    pub fn open_gitlab_merge_requests_pane(&mut self) {
        if !self.config.gitlab.any_configured() {
            self.toast(
                "gitlab: add a [[gitlab.projects]] entry to ~/.config/mnml/config.toml first",
            );
            return;
        }
        self.ensure_gitlab_worker();
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::GitlabMergeRequests(_)))
        {
            if let Some(h) = &self.gitlab_handle {
                h.force_refresh();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::GitlabMergeRequests(crate::gitlab::GitlabMergeRequestsPane::new());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
        self.toast("gitlab: merge requests (loading…)");
    }

    pub fn refresh_active_gitlab_pane(&mut self) {
        if let Some(h) = &self.gitlab_handle {
            h.force_refresh();
            self.toast("gitlab: refreshing…");
        }
    }

    pub fn open_selected_gitlab_pipeline_url(&mut self) {
        let Some(url) = self.selected_gitlab_pipeline_url() else {
            self.toast("no pipeline selected");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened pipeline in browser");
    }

    pub fn copy_selected_gitlab_pipeline_url(&mut self) {
        let Some(url) = self.selected_gitlab_pipeline_url() else {
            self.toast("no pipeline selected");
            return;
        };
        self.clipboard.set_yank(url, false);
        self.toast("copied pipeline URL");
    }

    fn selected_gitlab_pipeline_url(&self) -> Option<String> {
        let id = self.active?;
        let Pane::GitlabPipelines(pane) = self.panes.get(id)? else {
            return None;
        };
        crate::ui::gitlab_pipelines_view::selected_pipeline(self, pane).map(|r| r.web_url)
    }

    pub fn open_selected_gitlab_mr_url(&mut self) {
        let Some(url) = self.selected_gitlab_mr_url() else {
            self.toast("no MR selected");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened MR in browser");
    }

    pub fn copy_selected_gitlab_mr_url(&mut self) {
        let Some(url) = self.selected_gitlab_mr_url() else {
            self.toast("no MR selected");
            return;
        };
        self.clipboard.set_yank(url, false);
        self.toast("copied MR URL");
    }

    fn selected_gitlab_mr_url(&self) -> Option<String> {
        let id = self.active?;
        let Pane::GitlabMergeRequests(pane) = self.panes.get(id)? else {
            return None;
        };
        crate::ui::gitlab_merge_requests_view::selected_mr(self, pane).map(|r| r.web_url)
    }

    /// `c` on a GitLab MR row — open / focus the pipelines pane and select
    /// the most-recent pipeline whose `target_ref` matches the MR's
    /// `source_branch`.
    pub fn jump_from_gl_mr_to_pipeline(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::GitlabMergeRequests(pane)) = self.panes.get(id) else {
            self.toast("not a GitLab MR pane");
            return;
        };
        let Some(mr) = crate::ui::gitlab_merge_requests_view::selected_mr(self, pane) else {
            self.toast("no MR selected");
            return;
        };
        let Some(branch) = mr.source_branch.clone() else {
            self.toast("MR has no source branch");
            return;
        };
        let Some(pipelines) = self.gitlab_pipelines.get(&mr.project) else {
            self.toast(format!("no pipelines cached for {}", mr.project));
            return;
        };
        let Some(pipeline) = pipelines
            .iter()
            .find(|p| p.target_ref.as_deref() == Some(branch.as_str()))
            .cloned()
        else {
            self.toast(format!("no pipeline on branch '{branch}' yet"));
            return;
        };
        self.gl_pipelines_view_mode = crate::gitlab::GlPipelineViewMode::Recent;
        self.open_gitlab_pipelines_pane();
        let flat = crate::ui::gitlab_pipelines_view::flatten_pipelines(self);
        let target_idx = flat.iter().position(|r| {
            r.pipeline
                .as_ref()
                .map(|p| p.id == pipeline.id)
                .unwrap_or(false)
        });
        if let Some(idx) = target_idx
            && let Some(active) = self.active
            && let Some(Pane::GitlabPipelines(p)) = self.panes.get_mut(active)
        {
            p.selected = idx;
            p.scroll = 0;
        }
        self.toast(format!("→ pipeline #{}", pipeline.id));
    }

    /// `P` on a GitLab pipeline row — open / focus the MRs pane and select
    /// the open MR whose `source_branch` matches the pipeline's
    /// `target_ref`.
    pub fn jump_from_gl_pipeline_to_mr(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::GitlabPipelines(pane)) = self.panes.get(id) else {
            self.toast("not a GitLab pipelines pane");
            return;
        };
        let Some(pipeline) = crate::ui::gitlab_pipelines_view::selected_pipeline(self, pane) else {
            self.toast("no pipeline selected");
            return;
        };
        let Some(branch) = pipeline.target_ref.clone() else {
            self.toast("pipeline has no target ref");
            return;
        };
        let Some(mrs) = self.gitlab_merge_requests.get(&pipeline.project) else {
            self.toast(format!("no MRs cached for {}", pipeline.project));
            return;
        };
        let Some(mr) = mrs
            .iter()
            .find(|m| m.source_branch.as_deref() == Some(branch.as_str()))
            .cloned()
        else {
            self.toast(format!("no open MR for branch '{branch}'"));
            return;
        };
        self.gl_mrs_view_mode = crate::gitlab::GlMrViewMode::PerProject;
        self.open_gitlab_merge_requests_pane();
        let flat = crate::ui::gitlab_merge_requests_view::flatten_mrs(self);
        let target_idx = flat
            .iter()
            .position(|r| r.mr.as_ref().map(|m| m.iid == mr.iid).unwrap_or(false));
        if let Some(idx) = target_idx
            && let Some(active) = self.active
            && let Some(Pane::GitlabMergeRequests(p)) = self.panes.get_mut(active)
        {
            p.selected = idx;
            p.scroll = 0;
        }
        self.toast(format!("→ MR !{}", mr.iid));
    }

    pub(super) fn drain_gitlab_events(&mut self) {
        use crate::gitlab::GitlabEvent;
        let Some(handle) = &self.gitlab_handle else {
            return;
        };
        while let Ok(ev) = handle.rx.try_recv() {
            match ev {
                GitlabEvent::Pipelines { project, pipelines } => {
                    self.gitlab_pipelines.insert(project, pipelines);
                    self.gitlab_last_error = None;
                }
                GitlabEvent::BranchPipelines {
                    project,
                    per_branch,
                } => {
                    self.gitlab_branch_pipelines.insert(project, per_branch);
                    self.gitlab_last_error = None;
                }
                GitlabEvent::MergeRequests {
                    project,
                    merge_requests,
                } => {
                    self.gitlab_merge_requests.insert(project, merge_requests);
                    self.gitlab_last_error = None;
                }
                GitlabEvent::MyMergeRequests(mrs) => {
                    self.gitlab_my_merge_requests = mrs;
                    self.gitlab_last_error = None;
                }
                GitlabEvent::Connected => {
                    self.gitlab_connected = true;
                }
                GitlabEvent::Failed(msg) => {
                    self.gitlab_last_error = Some(msg);
                }
            }
        }
        self.refresh_rail_pulls();
    }
}
