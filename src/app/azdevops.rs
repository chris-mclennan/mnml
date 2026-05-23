//! Azure DevOps Builds / Pull Requests dashboard methods on `App`.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//! (`.local/PLAN.md` Phase A.4). Pure non-destructive move: no API
//! change. The methods here all manipulate `App` state declared in
//! `app/mod.rs` and use `Azdevops*` / `Build*` / `PullRequest*`
//! types from `crate::azdevops`.

use super::*;

impl App {
    /// `L` on the selected Azure DevOps build row — open a log viewer pane
    /// and kick off a background fetch of the build's combined per-log
    /// output. Azure splits a build into many `logs/{logId}` resources;
    /// we concatenate them with `══ log N ══` separators.
    pub fn open_azdevops_build_log(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::AzDevOpsBuilds(pane)) = self.panes.get(id) else {
            self.toast("not an Azure DevOps builds pane");
            return;
        };
        let Some(build) = crate::ui::azdevops_builds_view::selected_build(self, pane) else {
            self.toast("no build selected");
            return;
        };
        // `BuildRecord.label` is `"org/project/repo"` — the log endpoint
        // only needs org/project so split out the first two segments.
        let mut parts = build.label.splitn(3, '/');
        let org = parts.next().unwrap_or("").to_string();
        let project = parts.next().unwrap_or("").to_string();
        if org.is_empty() || project.is_empty() {
            self.toast(format!("bad AZ build label: {}", build.label));
            return;
        }
        let title = format!("{org}/{project} · build #{}", build.build_number);
        let job_id = self.pipeline_log_next_job;
        self.pipeline_log_next_job = self.pipeline_log_next_job.wrapping_add(1);
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let log_pane = crate::bitbucket::PipelineLogPane::new_with_host(
            title,
            crate::bitbucket::LogHost::Azure,
            org.clone(),
            project.clone(),
            build.id.to_string(),
            build.web_url.clone(),
            job_id,
            cancel.clone(),
        );
        let pane_v = Pane::BitbucketPipelineLog(log_pane);
        let new_id = self.split_leaf_with(id, crate::layout::SplitDir::Horizontal, pane_v);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
        let auth_env = self
            .config
            .azdevops
            .auth_env
            .clone()
            .unwrap_or_else(|| "AZDO_TOKEN".to_string());
        self.spawn_log_fetch_inner(
            job_id,
            crate::bitbucket::LogHost::Azure,
            auth_env,
            org,
            project,
            build.id.to_string(),
            String::new(),
            cancel,
        );
    }

    pub fn ensure_azdevops_worker(&mut self) {
        if self.azdevops_handle.is_some() {
            return;
        }
        if !self.config.azdevops.any_configured() {
            return;
        }
        self.azdevops_handle = Some(crate::azdevops::spawn(self.config.azdevops.clone()));
    }

    pub fn open_azdevops_builds_pane(&mut self) {
        if !self.config.azdevops.any_configured() {
            self.toast("azdevops: add a [[azdevops.projects]] entry first");
            return;
        }
        self.ensure_azdevops_worker();
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::AzDevOpsBuilds(_)))
        {
            if let Some(h) = &self.azdevops_handle {
                h.force_refresh();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::AzDevOpsBuilds(crate::azdevops::AzDevOpsBuildsPane::new());
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
        self.toast("azdevops: builds (loading…)");
    }

    pub fn open_azdevops_pull_requests_pane(&mut self) {
        if !self.config.azdevops.any_configured() {
            self.toast("azdevops: add a [[azdevops.projects]] entry first");
            return;
        }
        self.ensure_azdevops_worker();
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::AzDevOpsPullRequests(_)))
        {
            if let Some(h) = &self.azdevops_handle {
                h.force_refresh();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::AzDevOpsPullRequests(crate::azdevops::AzDevOpsPullRequestsPane::new());
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
        self.toast("azdevops: pull requests (loading…)");
    }

    pub fn refresh_active_azdevops_pane(&mut self) {
        if let Some(h) = &self.azdevops_handle {
            h.force_refresh();
            self.toast("azdevops: refreshing…");
        }
    }

    pub fn open_selected_azdevops_build_url(&mut self) {
        let Some(url) = self.selected_azdevops_build_url() else {
            self.toast("no build selected");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened build in browser");
    }

    pub fn copy_selected_azdevops_build_url(&mut self) {
        let Some(url) = self.selected_azdevops_build_url() else {
            self.toast("no build selected");
            return;
        };
        self.clipboard.set_yank(url, false);
        self.toast("copied build URL");
    }

    fn selected_azdevops_build_url(&self) -> Option<String> {
        let id = self.active?;
        let Pane::AzDevOpsBuilds(pane) = self.panes.get(id)? else {
            return None;
        };
        crate::ui::azdevops_builds_view::selected_build(self, pane).map(|r| r.web_url)
    }

    pub fn open_selected_azdevops_pr_url(&mut self) {
        let Some(url) = self.selected_azdevops_pr_url() else {
            self.toast("no PR selected");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened PR in browser");
    }

    pub fn copy_selected_azdevops_pr_url(&mut self) {
        let Some(url) = self.selected_azdevops_pr_url() else {
            self.toast("no PR selected");
            return;
        };
        self.clipboard.set_yank(url, false);
        self.toast("copied PR URL");
    }

    fn selected_azdevops_pr_url(&self) -> Option<String> {
        let id = self.active?;
        let Pane::AzDevOpsPullRequests(pane) = self.panes.get(id)? else {
            return None;
        };
        crate::ui::azdevops_pull_requests_view::selected_pr(self, pane).map(|r| r.web_url)
    }

    /// `c` on an Azure DevOps PR row — open / focus the builds pane and
    /// select the most-recent build whose `target_ref` matches the PR's
    /// `source_branch`.
    pub fn jump_from_az_pr_to_build(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::AzDevOpsPullRequests(pane)) = self.panes.get(id) else {
            self.toast("not an Azure PR pane");
            return;
        };
        let Some(pr) = crate::ui::azdevops_pull_requests_view::selected_pr(self, pane) else {
            self.toast("no PR selected");
            return;
        };
        let Some(branch) = pr.source_branch.clone() else {
            self.toast("PR has no source branch");
            return;
        };
        // Azure DevOps build records carry the org/project label; PRs add
        // a /repo suffix. Try the exact label first, then walk the
        // (org/project) prefix as a fallback so the lookup still works
        // when a project has multiple repos.
        let pr_label = pr.label.clone();
        let project_label = pr_label
            .rsplit_once('/')
            .map(|(p, _)| p.to_string())
            .unwrap_or_else(|| pr_label.clone());
        let builds = self
            .azdevops_builds
            .get(&pr_label)
            .or_else(|| self.azdevops_builds.get(&project_label));
        let Some(builds) = builds else {
            self.toast(format!("no builds cached for {pr_label}"));
            return;
        };
        let Some(build) = builds
            .iter()
            .find(|b| b.target_ref.as_deref() == Some(branch.as_str()))
            .cloned()
        else {
            self.toast(format!("no build on branch '{branch}' yet"));
            return;
        };
        self.az_builds_view_mode = crate::azdevops::AzBuildsViewMode::Recent;
        self.open_azdevops_builds_pane();
        let flat = crate::ui::azdevops_builds_view::flatten_builds(self);
        let target_idx = flat
            .iter()
            .position(|r| r.build.as_ref().map(|b| b.id == build.id).unwrap_or(false));
        if let Some(idx) = target_idx
            && let Some(active) = self.active
            && let Some(Pane::AzDevOpsBuilds(p)) = self.panes.get_mut(active)
        {
            p.selected = idx;
            p.scroll = 0;
        }
        self.toast(format!("→ build #{}", build.id));
    }

    /// `P` on an Azure DevOps build row — open / focus the PRs pane and
    /// select the open PR whose `source_branch` matches the build's
    /// `target_ref`.
    pub fn jump_from_az_build_to_pr(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::AzDevOpsBuilds(pane)) = self.panes.get(id) else {
            self.toast("not an Azure builds pane");
            return;
        };
        let Some(build) = crate::ui::azdevops_builds_view::selected_build(self, pane) else {
            self.toast("no build selected");
            return;
        };
        let Some(branch) = build.target_ref.clone() else {
            self.toast("build has no target ref");
            return;
        };
        // Build label is "org/project"; PRs are keyed "org/project/repo".
        // Pick the first PR-label whose source_branch matches AND whose
        // prefix is the build's label.
        let build_label = build.label.clone();
        let Some(matched) = self.azdevops_pull_requests.iter().find_map(|(label, prs)| {
            if !(label == &build_label || label.starts_with(&format!("{build_label}/"))) {
                return None;
            }
            prs.iter()
                .find(|p| p.source_branch.as_deref() == Some(branch.as_str()))
                .cloned()
        }) else {
            self.toast(format!("no open PR for branch '{branch}'"));
            return;
        };
        self.az_prs_view_mode = crate::azdevops::AzPrViewMode::PerRepo;
        self.open_azdevops_pull_requests_pane();
        let flat = crate::ui::azdevops_pull_requests_view::flatten_prs(self);
        let target_idx = flat
            .iter()
            .position(|r| r.pr.as_ref().map(|p| p.id == matched.id).unwrap_or(false));
        if let Some(idx) = target_idx
            && let Some(active) = self.active
            && let Some(Pane::AzDevOpsPullRequests(p)) = self.panes.get_mut(active)
        {
            p.selected = idx;
            p.scroll = 0;
        }
        self.toast(format!("→ PR #{}", matched.id));
    }

    pub(super) fn drain_azdevops_events(&mut self) {
        use crate::azdevops::AzDevOpsEvent;
        let Some(handle) = &self.azdevops_handle else {
            return;
        };
        while let Ok(ev) = handle.rx.try_recv() {
            match ev {
                AzDevOpsEvent::Builds { label, builds } => {
                    self.azdevops_builds.insert(label, builds);
                    self.azdevops_last_error = None;
                }
                AzDevOpsEvent::BranchBuilds { label, per_branch } => {
                    self.azdevops_branch_builds.insert(label, per_branch);
                    self.azdevops_last_error = None;
                }
                AzDevOpsEvent::PullRequests {
                    label,
                    pull_requests,
                } => {
                    self.azdevops_pull_requests.insert(label, pull_requests);
                    self.azdevops_last_error = None;
                }
                AzDevOpsEvent::MyPullRequests(prs) => {
                    self.azdevops_my_pull_requests = prs;
                    self.azdevops_last_error = None;
                }
                AzDevOpsEvent::Connected => {
                    self.azdevops_connected = true;
                }
                AzDevOpsEvent::Failed(msg) => {
                    self.azdevops_last_error = Some(msg);
                }
            }
        }
        self.refresh_rail_pulls();
    }
}
