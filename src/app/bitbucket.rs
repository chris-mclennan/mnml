//! Bitbucket dashboard methods on `App`.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move: no API
//! change. The methods here all manipulate `App` state declared in
//! `app/mod.rs` and use `Bitbucket*` types from `crate::bitbucket`.

use super::*;

impl App {
    /// Lazily spawn the Bitbucket worker thread. No-op if one is already
    /// running, or if `[[bitbucket.repos]]` is empty (the worker would
    /// just exit with a `Failed` event — phase 2's pane handles the
    /// "configure this" banner instead). Called by future
    /// `bitbucket.pipelines` / `bitbucket.pr` commands before opening
    /// their panes.
    #[allow(dead_code)] // Phase 1: built but not called until phase 2.
    pub fn ensure_bitbucket_worker(&mut self) {
        if self.bitbucket_handle.is_some() {
            return;
        }
        if !self.config.bitbucket.any_configured() {
            return;
        }
        self.bitbucket_handle = Some(crate::bitbucket::spawn(self.config.bitbucket.clone()));
    }

    /// Open (or focus) the Bitbucket pipelines pane. Spawns the worker
    /// thread lazily if it's not already running. Lands the pane as a
    /// vertical split off the active leaf — same layout shape as the
    /// other dashboard panes.
    pub fn open_bitbucket_pipelines_pane(&mut self) {
        if !self.config.bitbucket.any_configured() {
            self.toast(
                "bitbucket: add a [[bitbucket.repos]] entry to ~/.config/mnml/config.toml first",
            );
            return;
        }
        self.ensure_bitbucket_worker();
        // Re-focus an existing pane if open.
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::BitbucketPipelines(_)))
        {
            // Pulse a refresh so re-opening is the easy way to get fresh data.
            if let Some(h) = &self.bitbucket_handle {
                h.force_refresh();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::BitbucketPipelines(crate::bitbucket::BitbucketPipelinesPane::new());
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
        self.toast("bitbucket: pipelines (loading…)");
    }

    /// `r` in a Bitbucket pane — wake the worker so the next poll fires
    /// immediately instead of waiting for the regular interval. No-op if
    /// no worker is running.
    pub fn refresh_active_bitbucket_pane(&mut self) {
        if let Some(h) = &self.bitbucket_handle {
            h.force_refresh();
            self.toast("bitbucket: refreshing…");
        }
    }

    /// `Enter` on the selected pipeline row — open its Bitbucket dashboard
    /// URL in the OS default browser.
    pub fn open_selected_bitbucket_pipeline_url(&mut self) {
        let Some(url) = self.selected_bitbucket_pipeline_url() else {
            self.toast("no pipeline selected");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened pipeline in browser");
    }

    /// `y` on the selected pipeline row — copy the URL to the clipboard.
    pub fn copy_selected_bitbucket_pipeline_url(&mut self) {
        let Some(url) = self.selected_bitbucket_pipeline_url() else {
            self.toast("no pipeline selected");
            return;
        };
        self.clipboard.set_yank(url, false);
        self.toast("copied pipeline URL");
    }

    fn selected_bitbucket_pipeline_url(&self) -> Option<String> {
        let id = self.active?;
        let Pane::BitbucketPipelines(pane) = self.panes.get(id)? else {
            return None;
        };
        crate::ui::bitbucket_pipelines_view::selected_pipeline(self, pane).map(|r| r.web_url)
    }

    /// `L` on the selected Bitbucket pipeline row — open / focus a
    /// `Pane::BitbucketPipelineLog` and kick off a background fetch of
    /// the combined per-step build log. Errors land in the pane's `Failed`
    /// state (e.g. missing auth env var, network, 404).
    pub fn open_bitbucket_pipeline_log(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::BitbucketPipelines(pane)) = self.panes.get(id) else {
            self.toast("not a Bitbucket pipelines pane");
            return;
        };
        let Some(pipeline) = crate::ui::bitbucket_pipelines_view::selected_pipeline(self, pane)
        else {
            self.toast("no pipeline selected");
            return;
        };
        let title = format!(
            "{}/{} · build #{}",
            pipeline.workspace, pipeline.slug, pipeline.build_number
        );
        let job_id = self.pipeline_log_next_job;
        self.pipeline_log_next_job = self.pipeline_log_next_job.wrapping_add(1);
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let log_pane = crate::bitbucket::PipelineLogPane::new(
            title,
            pipeline.workspace.clone(),
            pipeline.slug.clone(),
            pipeline.uuid.clone(),
            pipeline.web_url.clone(),
            job_id,
            cancel.clone(),
        );
        // Open in a split below the active pane.
        let pane_v = Pane::BitbucketPipelineLog(log_pane);
        let new_id = self.split_leaf_with(id, crate::layout::SplitDir::Horizontal, pane_v);
        self.active = Some(new_id);
        self.focus = Focus::Pane;
        // Kick off the worker.
        self.spawn_bitbucket_pipeline_log_fetch(
            job_id,
            pipeline.workspace,
            pipeline.slug,
            pipeline.uuid,
            cancel,
        );
    }

    /// Background-thread fetch of one pipeline's combined log. Reads the
    /// auth token from the configured env var; reply lands on
    /// `pipeline_log_chan` and is drained by `tick`.
    fn spawn_bitbucket_pipeline_log_fetch(
        &mut self,
        job_id: u64,
        workspace: String,
        slug: String,
        pipeline_uuid: String,
        cancel: std::sync::Arc<std::sync::atomic::AtomicBool>,
    ) {
        let auth_env = self
            .config
            .bitbucket
            .auth_env
            .clone()
            .unwrap_or_else(|| "BITBUCKET_TOKEN".to_string());
        self.spawn_log_fetch_inner(
            job_id,
            crate::bitbucket::LogHost::Bitbucket,
            auth_env,
            workspace,
            slug,
            pipeline_uuid,
            String::new(),
            cancel,
        );
    }

    /// Open / focus the Bitbucket pull requests pane. Shares the worker
    /// with the pipelines pane — both surfaces are fetched on the same
    /// poll cycle.
    pub fn open_bitbucket_pull_requests_pane(&mut self) {
        if !self.config.bitbucket.any_configured() {
            self.toast(
                "bitbucket: add a [[bitbucket.repos]] entry to ~/.config/mnml/config.toml first",
            );
            return;
        }
        self.ensure_bitbucket_worker();
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::BitbucketPullRequests(_)))
        {
            if let Some(h) = &self.bitbucket_handle {
                h.force_refresh();
            }
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::BitbucketPullRequests(crate::bitbucket::BitbucketPullRequestsPane::new());
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
        self.toast("bitbucket: pull requests (loading…)");
    }

    pub fn open_selected_bitbucket_pr_url(&mut self) {
        let Some(url) = self.selected_bitbucket_pr_url() else {
            self.toast("no PR selected");
            return;
        };
        crate::app::open_url_external(&url);
        self.toast("opened PR in browser");
    }

    pub fn copy_selected_bitbucket_pr_url(&mut self) {
        let Some(url) = self.selected_bitbucket_pr_url() else {
            self.toast("no PR selected");
            return;
        };
        self.clipboard.set_yank(url, false);
        self.toast("copied PR URL");
    }

    fn selected_bitbucket_pr_url(&self) -> Option<String> {
        let id = self.active?;
        let Pane::BitbucketPullRequests(pane) = self.panes.get(id)? else {
            return None;
        };
        crate::ui::bitbucket_pull_requests_view::selected_pr(self, pane).map(|r| r.web_url)
    }

    /// `c` on a Bitbucket PR row — open / focus the pipelines pane and
    /// select the most-recent pipeline whose `target_ref` matches the PR's
    /// `source_branch`. Toasts when there's no match (PR with no
    /// pipelines run yet, or the worker hasn't cycled).
    pub fn jump_from_bb_pr_to_pipeline(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::BitbucketPullRequests(pane)) = self.panes.get(id) else {
            self.toast("not a Bitbucket PR pane");
            return;
        };
        let Some(pr) = crate::ui::bitbucket_pull_requests_view::selected_pr(self, pane) else {
            self.toast("no PR selected");
            return;
        };
        let Some(branch) = pr.source_branch.clone() else {
            self.toast("PR has no source branch");
            return;
        };
        let key = (pr.workspace.clone(), pr.slug.clone());
        let Some(pipelines) = self.bitbucket_pipelines.get(&key) else {
            self.toast(format!(
                "no pipelines cached for {}/{}",
                pr.workspace, pr.slug
            ));
            return;
        };
        // Pipelines arrive sorted newest-first; first match by target_ref wins.
        let Some(pipeline) = pipelines
            .iter()
            .find(|p| p.target_ref.as_deref() == Some(branch.as_str()))
            .cloned()
        else {
            self.toast(format!("no pipeline on branch '{branch}' yet"));
            return;
        };
        // Force the next view-mode to Recent (PerBranch only shows latest per branch).
        self.bb_pipelines_view_mode = crate::bitbucket::PipelineViewMode::Recent;
        self.open_bitbucket_pipelines_pane();
        // Find the new pipelines pane and snap the selection onto the
        // matching pipeline by uuid.
        let flat = crate::ui::bitbucket_pipelines_view::flatten_pipelines(self);
        let target_idx = flat.iter().position(|r| {
            r.pipeline
                .as_ref()
                .map(|p| p.uuid == pipeline.uuid)
                .unwrap_or(false)
        });
        if let Some(idx) = target_idx
            && let Some(active) = self.active
            && let Some(Pane::BitbucketPipelines(p)) = self.panes.get_mut(active)
        {
            p.selected = idx;
            p.scroll = 0;
        }
        self.toast(format!("→ pipeline #{}", pipeline.build_number));
    }

    /// `P` on a Bitbucket pipeline row — open / focus the PRs pane and
    /// select the open PR whose `source_branch` matches the pipeline's
    /// `target_ref`. Toasts when there's no match.
    pub fn jump_from_bb_pipeline_to_pr(&mut self) {
        let id = match self.active {
            Some(id) => id,
            None => {
                self.toast("no pane focused");
                return;
            }
        };
        let Some(Pane::BitbucketPipelines(pane)) = self.panes.get(id) else {
            self.toast("not a Bitbucket pipelines pane");
            return;
        };
        let Some(pipeline) = crate::ui::bitbucket_pipelines_view::selected_pipeline(self, pane)
        else {
            self.toast("no pipeline selected");
            return;
        };
        let Some(branch) = pipeline.target_ref.clone() else {
            self.toast("pipeline has no target ref");
            return;
        };
        let key = (pipeline.workspace.clone(), pipeline.slug.clone());
        let Some(prs) = self.bitbucket_pull_requests.get(&key) else {
            self.toast(format!(
                "no PRs cached for {}/{}",
                pipeline.workspace, pipeline.slug
            ));
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
        self.bb_prs_view_mode = crate::bitbucket::PrViewMode::PerRepo;
        self.open_bitbucket_pull_requests_pane();
        let flat = crate::ui::bitbucket_pull_requests_view::flatten_prs(self);
        let target_idx = flat
            .iter()
            .position(|r| r.pr.as_ref().map(|p| p.id == pr.id).unwrap_or(false));
        if let Some(idx) = target_idx
            && let Some(active) = self.active
            && let Some(Pane::BitbucketPullRequests(p)) = self.panes.get_mut(active)
        {
            p.selected = idx;
            p.scroll = 0;
        }
        self.toast(format!("→ PR #{}", pr.id));
    }

    /// Pull pending pipeline updates off the Bitbucket channel into the
    /// per-repo cache. Phase 2 panes read from `self.bitbucket_pipelines`
    /// + `self.bitbucket_last_error` directly. Cheap when the channel is
    ///   idle (a no-op when no worker has been spawned).
    pub(super) fn drain_bitbucket_events(&mut self) {
        use crate::bitbucket::BitbucketEvent;
        let Some(handle) = &self.bitbucket_handle else {
            return;
        };
        while let Ok(ev) = handle.rx.try_recv() {
            match ev {
                BitbucketEvent::Pipelines {
                    workspace,
                    slug,
                    pipelines,
                } => {
                    self.bitbucket_pipelines
                        .insert((workspace, slug), pipelines);
                    self.bitbucket_last_error = None;
                }
                BitbucketEvent::PullRequests {
                    workspace,
                    slug,
                    pull_requests,
                } => {
                    self.bitbucket_pull_requests
                        .insert((workspace, slug), pull_requests);
                    self.bitbucket_last_error = None;
                }
                BitbucketEvent::BranchPipelines {
                    workspace,
                    slug,
                    per_branch,
                } => {
                    self.bitbucket_branch_pipelines
                        .insert((workspace, slug), per_branch);
                    self.bitbucket_last_error = None;
                }
                BitbucketEvent::MyPullRequests(prs) => {
                    self.bitbucket_my_pull_requests = prs;
                    self.bitbucket_last_error = None;
                }
                BitbucketEvent::Connected => {
                    self.bitbucket_connected = true;
                }
                BitbucketEvent::Failed(msg) => {
                    self.bitbucket_last_error = Some(msg);
                }
            }
        }
        // PR caches changed → rail's "open PRs" subsection follows.
        self.refresh_rail_pulls();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jump_from_bb_pr_to_pipeline_selects_match_by_branch() {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.bitbucket.repos = vec![crate::config::BitbucketRepo {
            workspace: "exampleorg".into(),
            slug: "example-api".into(),
            branches: Vec::new(),
        }];
        let mut app = App::new(d.path().to_path_buf(), cfg).unwrap();
        // Two pipelines on the repo — pipeline #200 sits on the PR's branch;
        // #100 is on a different branch (the "wrong" answer).
        app.bitbucket_pipelines.insert(
            ("exampleorg".into(), "example-api".into()),
            vec![
                crate::bitbucket::PipelineRecord {
                    workspace: "exampleorg".into(),
                    slug: "example-api".into(),
                    uuid: "uuid-200".into(),
                    build_number: 200,
                    state: crate::bitbucket::PipelineState::InProgress,
                    target_ref: Some("feature/cross-nav".into()),
                    target_kind: Some("BRANCH".into()),
                    commit_hash: None,
                    creator: None,
                    trigger: None,
                    created_on_ms: Some(2_000),
                    completed_on_ms: None,
                    duration_secs: None,
                    running_step: None,
                    web_url: "https://bitbucket.org/exampleorg/example-api/pipelines/results/200"
                        .into(),
                },
                crate::bitbucket::PipelineRecord {
                    workspace: "exampleorg".into(),
                    slug: "example-api".into(),
                    uuid: "uuid-100".into(),
                    build_number: 100,
                    state: crate::bitbucket::PipelineState::Successful,
                    target_ref: Some("main".into()),
                    target_kind: Some("BRANCH".into()),
                    commit_hash: None,
                    creator: None,
                    trigger: None,
                    created_on_ms: Some(1_000),
                    completed_on_ms: None,
                    duration_secs: None,
                    running_step: None,
                    web_url: "https://bitbucket.org/exampleorg/example-api/pipelines/results/100"
                        .into(),
                },
            ],
        );
        // One PR whose source branch matches the running pipeline.
        app.bitbucket_pull_requests.insert(
            ("exampleorg".into(), "example-api".into()),
            vec![crate::bitbucket::PullRequestRecord {
                workspace: "exampleorg".into(),
                slug: "example-api".into(),
                id: 42,
                title: "Feature".into(),
                state: crate::bitbucket::PullRequestState::Open,
                author: None,
                source_branch: Some("feature/cross-nav".into()),
                dest_branch: Some("main".into()),
                reviewer_count: 0,
                approved_count: 0,
                changes_count: 0,
                comment_count: 0,
                task_count: 0,
                created_on_ms: Some(1_000),
                updated_on_ms: Some(1_000),
                web_url: "https://bitbucket.org/exampleorg/example-api/pull-requests/42".into(),
            }],
        );
        // Open the PR pane (so jump_from_bb_pr_to_pipeline has an active
        // pane to inspect) and prime the selection on PR #42.
        app.open_bitbucket_pull_requests_pane();
        let prs_pane = app.active.unwrap();
        // The pane defaults to selected = 0; the flatten places header
        // first. The first PR-shape row is what we expect under it.
        // Force selection onto the PR data row (it's index 1 with the
        // header at 0; we set 1 explicitly so the test doesn't depend on
        // flatten internals beyond "the PR is the second visible row").
        if let Some(Pane::BitbucketPullRequests(p)) = app.panes.get_mut(prs_pane) {
            p.selected = 1;
        }
        app.jump_from_bb_pr_to_pipeline();
        // The active pane should now be the pipelines pane.
        let new_active = app.active.unwrap();
        assert!(
            matches!(app.panes.get(new_active), Some(Pane::BitbucketPipelines(_))),
            "active pane should be pipelines after jump"
        );
        // And the selected pipeline row should be uuid-200, not uuid-100.
        if let Some(Pane::BitbucketPipelines(p)) = app.panes.get(new_active) {
            let flat = crate::ui::bitbucket_pipelines_view::flatten_pipelines(&app);
            let selected = flat.get(p.selected).and_then(|r| r.pipeline.as_ref());
            assert!(selected.is_some(), "should land on a pipeline row");
            assert_eq!(selected.unwrap().uuid, "uuid-200");
        } else {
            panic!("not a pipelines pane");
        }
    }
}
