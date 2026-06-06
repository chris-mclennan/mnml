//! GitHub Actions / Pull Requests dashboard methods on `App`.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move: no API
//! change. The methods here all manipulate `App` state declared in
//! `app/mod.rs` and use `Github*` / `WorkflowRun*` / `PullRequest*`
//! types from `crate::github`.

use super::*;

impl App {
    /// `L` on the selected GitHub workflow row — open a log viewer
    /// pane and kick off a background fetch of the run's combined
    /// per-job log. Sibling of [`Self::open_bitbucket_pipeline_log`];
    /// reuses the same `Pane::PipelineLog` variant via the
    /// new `LogHost::Github` tag.
    pub fn open_github_run_log(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::GithubActions(pane)) = self.panes.get(id) else {
            self.toast("not a GitHub Actions pane");
            return;
        };
        let Some(run) = crate::ui::github_actions_view::selected_run(self, pane) else {
            self.toast("no run selected");
            return;
        };
        let title = format!("{}/{} · run #{}", run.owner, run.repo, run.run_number);
        let job_id = self.pipeline_log_next_job;
        self.pipeline_log_next_job = self.pipeline_log_next_job.wrapping_add(1);
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let log_pane = crate::pipeline_log::PipelineLogPane::new_with_host(
            title,
            crate::pipeline_log::LogHost::Github,
            run.owner.clone(),
            run.repo.clone(),
            run.id.to_string(),
            run.web_url.clone(),
            job_id,
            cancel.clone(),
        );
        let pane_v = Pane::PipelineLog(log_pane);
        let new_id = self.split_leaf_with(id, crate::layout::SplitDir::Horizontal, pane_v);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
        let auth_env = self
            .config
            .github
            .auth_env
            .clone()
            .unwrap_or_else(|| "GITHUB_TOKEN".to_string());
        self.spawn_log_fetch_inner(
            job_id,
            crate::pipeline_log::LogHost::Github,
            auth_env,
            run.owner,
            run.repo,
            run.id.to_string(),
            String::new(),
            cancel,
        );
    }

    pub fn ensure_github_worker(&mut self) {
        if self.github_handle.is_some() {
            return;
        }
        if !self.config.github.any_configured() {
            return;
        }
        self.github_handle = Some(crate::github::spawn(self.config.github.clone()));
    }

    pub fn open_github_actions_pane(&mut self) {
        if !self.config.github.any_configured() {
            self.toast("github: add a [[github.repos]] entry to ~/.config/mnml/config.toml first");
            return;
        }
        self.ensure_github_worker();
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::GithubActions(_)))
        {
            if let Some(h) = &self.github_handle {
                h.force_refresh();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::GithubActions(crate::github::GithubActionsPane::new());
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
        self.toast("github: actions (loading…)");
    }

    pub fn refresh_active_github_pane(&mut self) {
        if let Some(h) = &self.github_handle {
            h.force_refresh();
            self.toast("github: refreshing…");
        }
    }

    pub fn open_selected_github_run_url(&mut self) {
        let Some(url) = self.selected_github_run_url() else {
            self.toast("no run selected");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened run in browser");
    }

    pub fn copy_selected_github_run_url(&mut self) {
        let Some(url) = self.selected_github_run_url() else {
            self.toast("no run selected");
            return;
        };
        self.clipboard.set_yank(url, false);
        self.toast("copied run URL");
    }

    fn selected_github_run_url(&self) -> Option<String> {
        let id = self.active?;
        let Pane::GithubActions(pane) = self.panes.get(id)? else {
            return None;
        };
        crate::ui::github_actions_view::selected_run(self, pane).map(|r| r.web_url)
    }

    pub fn open_github_pull_requests_pane(&mut self) {
        if !self.config.github.any_configured() {
            self.toast("github: add a [[github.repos]] entry to ~/.config/mnml/config.toml first");
            return;
        }
        self.ensure_github_worker();
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::GithubPullRequests(_)))
        {
            if let Some(h) = &self.github_handle {
                h.force_refresh();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::GithubPullRequests(crate::github::GithubPullRequestsPane::new());
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
        self.toast("github: pull requests (loading…)");
    }

    pub fn open_selected_github_pr_url(&mut self) {
        let Some(url) = self.selected_github_pr_url() else {
            self.toast("no PR selected");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened PR in browser");
    }

    pub fn copy_selected_github_pr_url(&mut self) {
        let Some(url) = self.selected_github_pr_url() else {
            self.toast("no PR selected");
            return;
        };
        self.clipboard.set_yank(url, false);
        self.toast("copied PR URL");
    }

    fn selected_github_pr_url(&self) -> Option<String> {
        let id = self.active?;
        let Pane::GithubPullRequests(pane) = self.panes.get(id)? else {
            return None;
        };
        crate::ui::github_pull_requests_view::selected_pr(self, pane).map(|r| r.web_url)
    }

    /// `c` on a GitHub PR row — open / focus the Actions pane and select
    /// the most-recent workflow run whose `target_ref` matches this PR's
    /// `source_branch`.
    pub fn jump_from_gh_pr_to_run(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::GithubPullRequests(pane)) = self.panes.get(id) else {
            self.toast("not a GitHub PR pane");
            return;
        };
        let Some(pr) = crate::ui::github_pull_requests_view::selected_pr(self, pane) else {
            self.toast("no PR selected");
            return;
        };
        let Some(branch) = pr.source_branch.clone() else {
            self.toast("PR has no source branch");
            return;
        };
        let key = (pr.owner.clone(), pr.repo.clone());
        let Some(runs) = self.github_workflow_runs.get(&key) else {
            self.toast(format!("no runs cached for {}/{}", pr.owner, pr.repo));
            return;
        };
        let Some(run) = runs
            .iter()
            .find(|r| r.target_ref.as_deref() == Some(branch.as_str()))
            .cloned()
        else {
            self.toast(format!("no workflow run on branch '{branch}' yet"));
            return;
        };
        self.gh_actions_view_mode = crate::github::ActionsViewMode::Recent;
        self.open_github_actions_pane();
        let flat = crate::ui::github_actions_view::flatten_runs(self);
        let target_idx = flat
            .iter()
            .position(|r| r.run.as_ref().map(|w| w.id == run.id).unwrap_or(false));
        if let Some(idx) = target_idx
            && let Some(active) = self.active
            && let Some(Pane::GithubActions(p)) = self.panes.get_mut(active)
        {
            p.selected = idx;
            p.scroll = 0;
        }
        self.toast(format!("→ run #{}", run.run_number));
    }

    /// `P` on a GitHub workflow-run row — open / focus the PRs pane and
    /// select the open PR whose `source_branch` matches the run's
    /// `target_ref`.
    pub fn jump_from_gh_run_to_pr(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::GithubActions(pane)) = self.panes.get(id) else {
            self.toast("not a GitHub Actions pane");
            return;
        };
        let Some(run) = crate::ui::github_actions_view::selected_run(self, pane) else {
            self.toast("no run selected");
            return;
        };
        let Some(branch) = run.target_ref.clone() else {
            self.toast("run has no target ref");
            return;
        };
        let key = (run.owner.clone(), run.repo.clone());
        let Some(prs) = self.github_pull_requests.get(&key) else {
            self.toast(format!("no PRs cached for {}/{}", run.owner, run.repo));
            return;
        };
        let Some(pr) = prs
            .iter()
            .find(|p| p.source_branch.as_deref() == Some(branch.as_str()))
            .cloned()
        else {
            self.toast(format!("no open PR for branch '{branch}'"));
            return;
        };
        self.gh_prs_view_mode = crate::github::GhPrViewMode::PerRepo;
        self.open_github_pull_requests_pane();
        let flat = crate::ui::github_pull_requests_view::flatten_prs(self);
        let target_idx = flat.iter().position(|r| {
            r.pr.as_ref()
                .map(|p| p.number == pr.number)
                .unwrap_or(false)
        });
        if let Some(idx) = target_idx
            && let Some(active) = self.active
            && let Some(Pane::GithubPullRequests(p)) = self.panes.get_mut(active)
        {
            p.selected = idx;
            p.scroll = 0;
        }
        self.toast(format!("→ PR #{}", pr.number));
    }

    pub(super) fn drain_github_events(&mut self) {
        use crate::github::GithubEvent;
        let Some(handle) = &self.github_handle else {
            return;
        };
        while let Ok(ev) = handle.rx.try_recv() {
            match ev {
                GithubEvent::WorkflowRuns { owner, repo, runs } => {
                    self.github_workflow_runs.insert((owner, repo), runs);
                    self.github_last_error = None;
                }
                GithubEvent::PullRequests {
                    owner,
                    repo,
                    pull_requests,
                } => {
                    self.github_pull_requests
                        .insert((owner, repo), pull_requests);
                    self.github_last_error = None;
                }
                GithubEvent::BranchRuns {
                    owner,
                    repo,
                    per_branch,
                } => {
                    self.github_branch_runs.insert((owner, repo), per_branch);
                    self.github_last_error = None;
                }
                GithubEvent::MyPullRequests(prs) => {
                    self.github_my_pull_requests = prs;
                    self.github_last_error = None;
                }
                GithubEvent::Connected => {
                    self.github_connected = true;
                }
                GithubEvent::Failed(msg) => {
                    self.github_last_error = Some(msg);
                }
            }
        }
        self.refresh_rail_pulls();
    }
}
