//! Cloud-agent + Claude-agents dashboard methods on `App` (A-1 of
//! the file-split refactor — 2026-06-28). Owns the spawn_managed_agents
//! worker, the new-cloud-run + new-cloud-agent wizards, the cloud-run
//! pane drains, the claude-agents dashboard pane (refresh, filters,
//! kill confirmation, escalation, action dispatch, file/row context
//! menus), AI spend stats, AI session search.
//!
//! Extracted from `src/app/mod.rs`. Pure non-destructive move.

use super::*;

impl App {
    /// Spawn an `ant beta:worker poll` Pty pane for a self-hosted
    /// sandbox environment. User must have already created the
    /// environment in the Console and exported
    /// `ANTHROPIC_ENVIRONMENT_KEY` + `ANTHROPIC_ENVIRONMENT_ID`.
    /// Detects missing `ant` binary and routes through the
    /// `prompt_install_sibling` flow with a manual install hint
    /// in the toast.
    pub fn spawn_managed_agents_worker(&mut self) {
        if !binary_on_path("ant") {
            self.toast(
                {
                    let hint = match std::env::consts::OS {
                        "macos" => "run: brew install anthropics/tap/ant".to_string(),
                        _ => "see install docs (no brew tap on this platform)".to_string(),
                    };
                    format!(
                        "ant CLI not installed — see https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes#install-the-ant-cli or {hint}"
                    )
                },
            );
            return;
        }
        let workspace = self.workspace.clone();
        let profile = crate::pty_pane::BinaryProfile {
            label: "ant worker".to_string(),
            exe: "ant".to_string(),
            args: vec![
                "beta:worker".to_string(),
                "poll".to_string(),
                "--workdir".to_string(),
                workspace.display().to_string(),
            ],
            cwd: Some(workspace),
            env: Vec::new(),
            session_id: None,
        };
        self.open_pty(profile);
        self.toast(
            "ant beta:worker poll spawned — needs ANTHROPIC_ENVIRONMENT_KEY + ANTHROPIC_ENVIRONMENT_ID in env",
        );
    }

    /// Cycle the auto-refresh interval on the active CloudAgentRun
    /// pane: off → 10s → 30s → 60s → 5m → off. Resets
    /// `last_auto_refresh` so the new interval starts counting now.
    pub fn cloud_agent_run_cycle_auto(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::CloudAgentRun(p)) = self.panes.get_mut(id) else {
            return;
        };
        p.auto_refresh_secs = match p.auto_refresh_secs {
            0 => 10,
            10 => 30,
            30 => 60,
            60 => 300,
            _ => 0,
        };
        p.last_auto_refresh = Some(std::time::Instant::now());
        let label = if p.auto_refresh_secs == 0 {
            "auto-refresh off".to_string()
        } else if p.auto_refresh_secs < 60 {
            format!("auto-refresh every {}s", p.auto_refresh_secs)
        } else {
            format!("auto-refresh every {}m", p.auto_refresh_secs / 60)
        };
        self.toast(label);
    }

    /// For every CloudAgentRun pane with auto-refresh enabled and
    /// an elapsed interval ≥ its cadence, re-spawn the log +
    /// artifact workers. Called once per `tick()` — bails early
    /// when nothing is due.
    pub(crate) fn tick_cloud_agent_run_auto(&mut self) {
        let now = std::time::Instant::now();
        let due: Vec<usize> = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(i, p)| {
                if let Pane::CloudAgentRun(c) = p
                    && c.auto_refresh_secs > 0
                    && c.last_auto_refresh
                        .map(|t| now.duration_since(t).as_secs() >= c.auto_refresh_secs)
                        .unwrap_or(true)
                {
                    Some(i)
                } else {
                    None
                }
            })
            .collect();
        for i in due {
            // Save current active so we can swap, refresh, restore.
            let saved = self.active;
            self.active = Some(i);
            self.cloud_agent_run_refresh();
            if let Some(Pane::CloudAgentRun(p)) = self.panes.get_mut(i) {
                p.last_auto_refresh = Some(now);
            }
            self.active = saved;
        }
    }

    /// Re-spawn the log + artifact workers on the active
    /// CloudAgentRun pane. Wired to the `[↻ Refresh]` chip on
    /// the detail pane's sub-header. Useful when the run finished
    /// after the pane was opened (artifacts uploaded in the
    /// meantime) or when the user wants a fresh tail.
    pub fn cloud_agent_run_refresh(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::CloudAgentRun(p)) = self.panes.get_mut(id) else {
            return;
        };
        // Skip for managed-agent panes — they use the SSE event
        // stream (session_event_rx), not log_rx / artifacts_rx.
        // Restart the SSE stream so the user gets fresh events.
        if matches!(
            p.source,
            crate::cloud_agent_run::CloudRunSource::AnthropicManaged
        ) {
            let session_id = p.run_id.clone();
            p.logs.clear();
            p.logs_loading = true;
            p.logs_err = None;
            p.log_follow = true;
            p.log_scroll = 0;
            p.session_event_rx = Some(crate::anthropic_api::spawn_session_event_stream(session_id));
            self.toast("restarting session stream…");
            return;
        }
        // Tattle QWE: rebuild log + artifact workers from scratch.
        let run_id = p.run_id.clone();
        let state = p.state.clone();
        let s3_prefix = p.s3_artifact_prefix.clone();
        p.logs.clear();
        p.logs_loading = true;
        p.logs_err = None;
        p.log_follow = true;
        p.log_scroll = 0;
        p.artifacts.clear();
        p.artifacts_loading = true;
        p.artifacts_err = None;
        p.log_rx = Some(crate::cloud_agent_run::spawn_log_fetcher(
            run_id,
            state,
            "/ecs/qwe-runner/claude-runner".to_string(),
        ));
        p.artifacts_rx = Some(crate::cloud_agent_run::spawn_artifacts_fetcher(s3_prefix));
        self.toast("refreshing logs + artifacts…");
    }

    /// Daily-driver path: fire a Managed Agents session against
    /// the user's saved defaults, using whatever's in
    /// `cloud_run_prompt_input` as the user message. No wizard.
    /// Called on Enter from the panel's quick-fire input row.
    pub fn cloud_run_quick_send(&mut self) {
        let defaults = self.config.cloud_run.defaults.clone();
        if defaults.agent_id.is_empty() || defaults.env_id.is_empty() {
            self.toast("no defaults saved — open the wizard to set up an agent + env");
            self.open_new_cloud_run_wizard();
            return;
        }
        let prompt = self.cloud_run_prompt_input.trim().to_string();
        if prompt.is_empty() {
            self.toast("type a prompt first");
            return;
        }
        self.cloud_run_prompt_input.clear();
        self.cloud_run_prompt_focused = false;
        let agent_id = defaults.agent_id;
        let env_id = defaults.env_id;
        let tx = self.cloud_run_msg_tx.clone();
        std::thread::spawn(move || {
            macro_rules! emit { ($($t:tt)*) => { let _ = tx.send(format!($($t)*)); }; }
            let backend = match crate::anthropic_api::detect_backend() {
                Ok(b) => b,
                Err(e) => {
                    emit!("cloud-run · backend: {e}");
                    return;
                }
            };
            let session = match crate::anthropic_api::create_session(
                &backend,
                &agent_id,
                &env_id,
                "mnml quick send",
            ) {
                Ok(s) => s,
                Err(e) => {
                    emit!("cloud-run · create_session: {e}");
                    return;
                }
            };
            if let Err(e) = crate::anthropic_api::send_user_message(&backend, &session.id, &prompt)
            {
                emit!("cloud-run · send_user_message: {e}");
                return;
            }
            emit!("session running · {}", &session.id);
        });
        self.toast("firing Managed Agents session…");
    }

    /// Open the Cloud Agents wizard (runner picker — Managed Agents
    /// or Tattle QWE). Distinct from `open_new_cloud_agent_wizard`
    /// which opens the local-agents PR wizard.
    pub fn open_new_cloud_run_wizard(&mut self) {
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::NewCloudRunWizard(_)))
        {
            self.reveal_pane(id);
            return;
        }
        let pane =
            Pane::NewCloudRunWizard(crate::new_cloud_run_wizard::NewCloudRunWizardPane::new());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    pub fn new_cloud_run_wizard_move(&mut self, delta: isize) {
        let Some(id) = self.active else { return };
        let Some(Pane::NewCloudRunWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        use crate::new_cloud_run_wizard::{CloudRunStep, CloudRunner, SandboxLocation};
        let max = match w.step {
            CloudRunStep::Runner => CloudRunner::all().len(),
            CloudRunStep::ManagedAgent => 2,
            CloudRunStep::ManagedSandbox => SandboxLocation::all().len(),
            _ => 0,
        };
        if max == 0 {
            return;
        }
        let cur = w.focus_row as isize;
        let new = (cur + delta).rem_euclid(max as isize) as usize;
        w.focus_row = new;
        match w.step {
            CloudRunStep::Runner => w.runner = CloudRunner::all()[new],
            CloudRunStep::ManagedAgent => w.managed_agent_create_new = new == 0,
            CloudRunStep::ManagedSandbox => w.sandbox = SandboxLocation::all()[new],
            _ => {}
        }
    }

    pub fn new_cloud_run_wizard_next(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::NewCloudRunWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        if !w.next_step() {
            self.new_cloud_run_wizard_submit();
        }
    }

    pub fn new_cloud_run_wizard_back(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::NewCloudRunWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        w.prev_step();
    }

    pub fn new_cloud_run_wizard_type(&mut self, ch: char) {
        let Some(id) = self.active else { return };
        let Some(Pane::NewCloudRunWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        use crate::new_cloud_run_wizard::CloudRunStep;
        match w.step {
            CloudRunStep::ManagedAgent => {
                if w.managed_agent_create_new {
                    w.managed_agent_new_name.push(ch);
                } else {
                    w.managed_agent_id.push(ch);
                }
            }
            CloudRunStep::QweTicket => w.qwe_ticket.push(ch),
            CloudRunStep::Prompt => w.prompt.push(ch),
            _ => {}
        }
    }

    pub fn new_cloud_run_wizard_backspace(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::NewCloudRunWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        use crate::new_cloud_run_wizard::CloudRunStep;
        match w.step {
            CloudRunStep::ManagedAgent => {
                if w.managed_agent_create_new {
                    w.managed_agent_new_name.pop();
                } else {
                    w.managed_agent_id.pop();
                }
            }
            CloudRunStep::QweTicket => {
                w.qwe_ticket.pop();
            }
            CloudRunStep::Prompt => {
                w.prompt.pop();
            }
            _ => {}
        }
    }

    pub fn new_cloud_run_wizard_close(&mut self) {
        if let Some(id) = self.active
            && matches!(self.panes.get(id), Some(Pane::NewCloudRunWizard(_)))
        {
            self.close_pane(id);
        }
    }

    /// Submit. QWE path routes to existing fire_cloud_run.
    /// Managed Agents path spawns a worker thread that calls the
    /// Anthropic API (create agent if needed → create env if
    /// needed → create session). Result toasts back.
    pub fn new_cloud_run_wizard_submit(&mut self) {
        let Some(id) = self.active else { return };
        use crate::new_cloud_run_wizard::{CloudRunner, SandboxLocation};
        let cfg = match self.panes.get(id) {
            Some(Pane::NewCloudRunWizard(p)) => (
                p.runner,
                p.qwe_ticket.clone(),
                p.managed_agent_create_new,
                p.managed_agent_new_name.clone(),
                p.managed_agent_id.clone(),
                p.sandbox,
                p.managed_env_id.clone(),
                p.prompt.clone(),
            ),
            _ => return,
        };
        match cfg.0 {
            CloudRunner::TattleQwe => {
                let t = cfg.1.trim().to_string();
                if t.is_empty() {
                    self.toast("ticket is empty");
                    return;
                }
                self.fire_cloud_run(&t);
                self.toast(format!("fired Tattle QWE run for {t}"));
                self.new_cloud_run_wizard_close();
            }
            CloudRunner::ManagedAgents => {
                if cfg.7.trim().is_empty() {
                    self.toast("prompt is empty");
                    return;
                }
                // Mark submitting + spawn worker. Result drained
                // by the wizard's tick handler.
                if let Some(Pane::NewCloudRunWizard(w)) = self.panes.get_mut(id) {
                    w.submitting = true;
                    w.last_message = Some("Submitting to Anthropic API…".to_string());
                }
                let create_new = cfg.2;
                let agent_name = cfg.3;
                let agent_id_existing = cfg.4;
                let sandbox = cfg.5;
                let env_id_existing = cfg.6;
                let prompt = cfg.7;
                let tx = self.cloud_run_msg_tx.clone();
                std::thread::spawn(move || {
                    macro_rules! emit { ($($t:tt)*) => { let _ = tx.send(format!($($t)*)); }; }
                    let backend = match crate::anthropic_api::detect_backend() {
                        Ok(b) => b,
                        Err(e) => {
                            emit!("cloud-run · backend: {e}");
                            return;
                        }
                    };
                    let agent_id = if create_new {
                        match crate::anthropic_api::create_agent(
                            &backend,
                            &agent_name,
                            "claude-opus-4-8",
                            "You are a helpful coding agent.",
                        ) {
                            Ok(a) => a.id,
                            Err(e) => {
                                emit!("cloud-run · create_agent: {e}");
                                return;
                            }
                        }
                    } else {
                        agent_id_existing
                    };
                    let env_id = if env_id_existing.is_empty() {
                        let kind = match sandbox {
                            SandboxLocation::AnthropicCloud => "cloud",
                            SandboxLocation::SelfHostedLocal
                            | SandboxLocation::SelfHostedRemote => "self_hosted",
                        };
                        match crate::anthropic_api::create_environment(&backend, "ide-env", kind) {
                            Ok(e) => e.id,
                            Err(e) => {
                                emit!("cloud-run · create_environment: {e}");
                                return;
                            }
                        }
                    } else {
                        env_id_existing
                    };
                    let session = match crate::anthropic_api::create_session(
                        &backend,
                        &agent_id,
                        &env_id,
                        "mnml session",
                    ) {
                        Ok(s) => s,
                        Err(e) => {
                            emit!("cloud-run · create_session: {e}");
                            return;
                        }
                    };
                    // Critical step: a freshly-created session is
                    // idle until you POST a user.message to its
                    // /events endpoint. Without this, the session
                    // sits there forever showing "No events yet".
                    if let Err(e) =
                        crate::anthropic_api::send_user_message(&backend, &session.id, &prompt)
                    {
                        emit!("cloud-run · send_user_message: {e}");
                        return;
                    }
                    // Save defaults so the next run can be a
                    // one-line quick-fire from the panel input
                    // instead of the full wizard. The drainer
                    // parses this sentinel format and writes to
                    // ~/.config/mnml/config.toml.
                    let sandbox_kind = match sandbox {
                        SandboxLocation::AnthropicCloud => "cloud",
                        SandboxLocation::SelfHostedLocal | SandboxLocation::SelfHostedRemote => {
                            "self_hosted"
                        }
                    };
                    emit!(
                        "__persist_defaults__|{}|{}|{}|claude-opus-4-8",
                        agent_id,
                        env_id,
                        sandbox_kind
                    );
                    emit!("session running · {}", &session.id);
                });
                self.toast("submitting Managed Agents run…");
                self.new_cloud_run_wizard_close();
            }
        }
    }

    /// Open the multi-step wizard for creating a new cloud agent
    /// run. Routes to either Tattle QWE or Anthropic managed
    /// agents depending on the user's step-1 pick. The pane lives
    /// at the active leaf; close with Esc.
    pub fn open_new_cloud_agent_wizard(&mut self) {
        // Reuse an existing wizard pane if present — no point
        // letting the user pile multiple half-filled wizards.
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::NewCloudAgentWizard(_)))
        {
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::NewCloudAgentWizard(
            crate::new_cloud_agent_wizard::NewCloudAgentWizardPane::new(),
        );
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Move the wizard's focus row up/down. No-op when the active
    /// pane isn't a wizard.
    pub fn new_cloud_agent_wizard_move(&mut self, delta: isize) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::NewCloudAgentWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        use crate::new_cloud_agent_wizard::{Action, Source, WizardStep};
        let max = match w.step {
            WizardStep::Source => Source::all().len(),
            WizardStep::PrList => w.pr_rows.len(),
            WizardStep::Action => Action::all().len(),
            _ => 0,
        };
        if max == 0 {
            return;
        }
        let cur = w.focus_row as isize;
        let new = (cur + delta).rem_euclid(max as isize) as usize;
        w.focus_row = new;
        // Radio selections apply immediately so the user sees the
        // chosen option highlighted; PrList does NOT (Space toggles).
        match w.step {
            WizardStep::Source => w.source = Source::all()[new],
            WizardStep::Action => w.action = Action::all()[new],
            _ => {}
        }
    }

    /// Toggle the selected state of the focused PR row. No-op on
    /// other steps.
    pub fn new_cloud_agent_wizard_toggle(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::NewCloudAgentWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        if !matches!(w.step, crate::new_cloud_agent_wizard::WizardStep::PrList) {
            return;
        }
        let idx = w.focus_row;
        if let Some(r) = w.pr_rows.get_mut(idx) {
            r.selected = !r.selected;
        }
    }

    /// Select / deselect all PRs (only on PrList step).
    pub fn new_cloud_agent_wizard_select_all(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::NewCloudAgentWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        if !matches!(w.step, crate::new_cloud_agent_wizard::WizardStep::PrList) {
            return;
        }
        let any_selected = w.pr_rows.iter().any(|r| r.selected);
        for r in w.pr_rows.iter_mut() {
            r.selected = !any_selected;
        }
    }

    /// Advance the wizard to the next step OR submit if we're on
    /// Review. No-op when the active pane isn't a wizard. When
    /// stepping INTO PrList, kick off the PR-list fetcher worker
    /// for the picked source.
    pub fn new_cloud_agent_wizard_next(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::NewCloudAgentWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        let advanced = w.next_step();
        if !advanced {
            self.new_cloud_agent_wizard_submit();
            return;
        }
        // Side effect on step transition: load the PR list.
        if matches!(
            self.panes.get(id),
            Some(Pane::NewCloudAgentWizard(p)) if matches!(p.step, crate::new_cloud_agent_wizard::WizardStep::PrList)
        ) {
            self.kick_off_pr_list_load(id);
        }
    }

    fn kick_off_pr_list_load(&mut self, pane_id: usize) {
        let source = match self.panes.get(pane_id) {
            Some(Pane::NewCloudAgentWizard(p)) => p.source,
            _ => return,
        };
        let repo_path = self.active_repo_path().to_path_buf();
        if let Some(Pane::NewCloudAgentWizard(w)) = self.panes.get_mut(pane_id) {
            w.pr_rows.clear();
            w.pr_err = None;
            w.pr_loading = true;
            use crate::new_cloud_agent_wizard::Source;
            let rx = match source {
                Source::GitHubPr => Some(crate::new_cloud_agent_wizard::spawn_gh_pr_fetcher(
                    repo_path,
                )),
                Source::BitbucketPr => {
                    let slug = derive_bitbucket_slug(&repo_path)
                        .unwrap_or_else(|| "<workspace>/<repo>".to_string());
                    Some(crate::new_cloud_agent_wizard::spawn_bitbucket_pr_fetcher(
                        slug,
                    ))
                }
                Source::ManualPrompt => None,
            };
            w.pr_rx = rx;
            if w.pr_rx.is_none() {
                w.pr_loading = false;
            }
        }
    }

    pub fn new_cloud_agent_wizard_back(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::NewCloudAgentWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        w.prev_step();
    }

    /// Append a char to the focused text input on the CustomPrompt step.
    pub fn new_cloud_agent_wizard_type(&mut self, ch: char) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::NewCloudAgentWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        if matches!(
            w.step,
            crate::new_cloud_agent_wizard::WizardStep::CustomPrompt
        ) {
            w.custom_prompt.push(ch);
        }
    }

    pub fn new_cloud_agent_wizard_backspace(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        let Some(Pane::NewCloudAgentWizard(w)) = self.panes.get_mut(id) else {
            return;
        };
        if matches!(
            w.step,
            crate::new_cloud_agent_wizard::WizardStep::CustomPrompt
        ) {
            w.custom_prompt.pop();
        }
    }

    /// Close the wizard pane (Esc).
    pub fn new_cloud_agent_wizard_close(&mut self) {
        if let Some(id) = self.active
            && matches!(self.panes.get(id), Some(Pane::NewCloudAgentWizard(_)))
        {
            self.close_pane(id);
        }
    }

    /// Submit the wizard. Resolves the final prompt per the chosen
    /// Action template (or the user's CustomPrompt), then for each
    /// selected PR row spawns a Claude session in a Pty pane.
    pub fn new_cloud_agent_wizard_submit(&mut self) {
        let Some(id) = self.active else {
            return;
        };
        use crate::new_cloud_agent_wizard::{Action, Source};
        let cfg = match self.panes.get(id) {
            Some(Pane::NewCloudAgentWizard(w)) => (
                w.source,
                w.action,
                w.custom_prompt.clone(),
                w.pr_rows
                    .iter()
                    .filter(|r| r.selected)
                    .map(|r| (r.number, r.title.clone()))
                    .collect::<Vec<_>>(),
            ),
            _ => return,
        };
        let template = cfg.1.prompt_template();
        let make_prompt = |pr_num: u32| -> String {
            if matches!(cfg.1, Action::Custom) {
                format!("{}\n\n(context: PR #{})", cfg.2, pr_num)
            } else {
                template.replace("<num>", &pr_num.to_string())
            }
        };
        match cfg.0 {
            Source::ManualPrompt => {
                let prompt = if matches!(cfg.1, Action::Custom) {
                    cfg.2.clone()
                } else {
                    template.replace("<num>", "(no PR)")
                };
                if prompt.trim().is_empty() {
                    self.toast("prompt is empty");
                    return;
                }
                self.spawn_claude_session_pty(prompt, None, "manual");
                self.new_cloud_agent_wizard_close();
            }
            Source::GitHubPr | Source::BitbucketPr => {
                if cfg.3.is_empty() {
                    self.toast("no PRs selected — go back to step 2");
                    return;
                }
                let mut count = 0;
                for (num, title) in &cfg.3 {
                    let prompt = make_prompt(*num);
                    let label = format!("claude PR#{num}");
                    self.spawn_claude_session_pty(prompt, Some(*num), &label);
                    count += 1;
                    let _ = title;
                }
                self.toast(format!("fired {count} Claude session(s)"));
                self.new_cloud_agent_wizard_close();
            }
        }
    }

    /// Spawn a `claude --print <prompt>` Pty pane. When `pr_number`
    /// is Some, runs `gh pr checkout <num>` first so Claude works
    /// against the PR's branch. Worker runs in the active repo's
    /// directory.
    fn spawn_claude_session_pty(&mut self, prompt: String, pr_number: Option<u32>, label: &str) {
        let cwd = self.active_repo_path().to_path_buf();
        // Build a one-shot shell script: checkout (if PR) then claude.
        // The script runs in bash with `set -e` so a failing checkout
        // doesn't silently drop into the wrong branch.
        let escaped_prompt = prompt.replace('\'', "'\\''");
        let script = match pr_number {
            Some(n) => format!(
                "set -e\necho '→ gh pr checkout {n}'\ngh pr checkout {n}\necho '→ claude --print'\nclaude --print '{escaped_prompt}'\n"
            ),
            None => format!("set -e\necho '→ claude --print'\nclaude --print '{escaped_prompt}'\n"),
        };
        let profile = crate::pty_pane::BinaryProfile {
            label: label.to_string(),
            exe: "bash".to_string(),
            args: vec!["-c".to_string(), script],
            cwd: Some(cwd),
            env: Vec::new(),
            session_id: None,
        };
        self.open_pty(profile);
    }

    /// Drain the PR list fetcher on every wizard pane each tick.
    pub(crate) fn drain_new_cloud_agent_wizards(&mut self) {
        for pane in self.panes.iter_mut() {
            if let Pane::NewCloudAgentWizard(w) = pane {
                let _ = w.drain();
            }
        }
    }

    /// Open a comprehensive cloud-agent run detail pane for the
    /// row at `idx` in `cloud_agents_rows`. Aggregates summary,
    /// web links, S3 artifacts, and CloudWatch logs into one pane.
    /// Spawns the log + artifact fetcher workers immediately so
    /// data starts streaming in by the first frame. Used by the
    /// right-click "View run details" menu entry and the
    /// `:cloud_agents.open_run` palette command.
    pub fn open_cloud_agent_run(&mut self, idx: usize) {
        let Some(row) = self.cloud_agents_rows.get(idx).cloned() else {
            self.toast("cloud agent row not found");
            return;
        };
        // Branch on source — managed agents have no AWS bits.
        if matches!(
            row.source,
            crate::claude_agents::AgentSource::AnthropicManaged
        ) {
            let mut pane = crate::cloud_agent_run::CloudAgentRunPane::new_managed(
                row.session_id.clone(),
                row.last_assistant_msg.clone().unwrap_or_default(),
                row.state.badge().to_string(),
                None,
                Some(row.workspace.clone()),
            );
            // Live event stream from /v1/sessions/{id}/stream.
            // Worker shells out to `curl -N` (http::send is
            // sync); drained by the existing tick loop.
            pane.session_event_rx = Some(crate::anthropic_api::spawn_session_event_stream(
                row.session_id.clone(),
            ));
            // Open as a tab in the focused leaf, not as a split —
            // matches VS Code semantics. Push to panes vec, then
            // reveal_pane() adds it to the active leaf's tabs.
            self.panes.push(Pane::CloudAgentRun(pane));
            let new_id = self.panes.len() - 1;
            self.reveal_pane(new_id);
            self.focus = Focus::Pane;
            return;
        }
        let meta = self.cloud_agents_meta.get(&row.session_id).cloned();
        let ticket = meta
            .as_ref()
            .map(|m| m.ticket.clone())
            .unwrap_or_else(|| row.workspace.clone());
        let flow = meta.as_ref().map(|m| m.flow.clone()).unwrap_or_default();
        let state = meta
            .as_ref()
            .map(|m| m.state.clone())
            .unwrap_or_else(|| "—".to_string());
        let pr_url = meta.as_ref().and_then(|m| m.pr_url.clone());
        // Prefer DynamoDB's recorded prefix; fall back to the
        // standard qwe-runner upload path when missing. qwe-runner's
        // artifacts.py writes to `s3://tattle-claude-artifacts/
        // artifacts/{flow}/{run_id}/` regardless of whether the
        // post-upload DynamoDB write succeeded — so the derived
        // path is correct even for runs missing the meta field.
        let s3_prefix = meta
            .as_ref()
            .and_then(|m| m.s3_artifact_prefix.clone())
            .or_else(|| {
                if flow.is_empty() {
                    None
                } else {
                    Some(format!(
                        "s3://tattle-claude-artifacts/artifacts/{flow}/{}/",
                        row.session_id
                    ))
                }
            });
        let s3_console = s3_prefix
            .as_deref()
            .and_then(crate::cloud_agent_run::s3_console_url_for);
        let jira_url = crate::cloud_agent_run::jira_url_for(&ticket);
        let cloudwatch_url = meta
            .as_ref()
            .map(|m| m.cloudwatch_url(&row.session_id))
            .unwrap_or_default();

        let mut pane = crate::cloud_agent_run::CloudAgentRunPane::new(
            row.session_id.clone(),
            ticket,
            flow,
            state.clone(),
            row.workspace.clone(),
            row.last_activity,
            jira_url,
            pr_url,
            cloudwatch_url,
            s3_prefix.clone(),
            s3_console,
        );
        pane.log_rx = Some(crate::cloud_agent_run::spawn_log_fetcher(
            row.session_id.clone(),
            state,
            "/ecs/qwe-runner/claude-runner".to_string(),
        ));
        pane.artifacts_rx = Some(crate::cloud_agent_run::spawn_artifacts_fetcher(s3_prefix));
        self.panes.push(Pane::CloudAgentRun(pane));
        let new_id = self.panes.len() - 1;
        self.reveal_pane(new_id);
        self.focus = Focus::Pane;
    }

    /// Drain log + artifact channels on every CloudAgentRun pane.
    /// Called from `App::tick`.
    /// Pull any queued messages from cloud-run worker threads
    /// and route them through the toast queue. Workers send
    /// status / error strings; we surface them as toasts so the
    /// user sees what happened without `eprintln!` corrupting
    /// the ratatui frame.
    pub(crate) fn drain_cloud_run_msgs(&mut self) {
        let Some(rx) = self.cloud_run_msg_rx.as_ref() else {
            return;
        };
        let msgs: Vec<String> = rx.try_iter().collect();
        for msg in msgs {
            // Sentinel: `__persist_defaults__|agent_id|env_id|sandbox|model`
            // The wizard sends this after a successful submit so
            // the Cloud Agents panel's quick-fire input gets a
            // saved target. Don't toast it; route to config.
            if let Some(rest) = msg.strip_prefix("__persist_defaults__|") {
                let parts: Vec<&str> = rest.splitn(4, '|').collect();
                if parts.len() == 4 {
                    self.config.cloud_run.defaults.agent_id = parts[0].to_string();
                    self.config.cloud_run.defaults.env_id = parts[1].to_string();
                    self.config.cloud_run.defaults.sandbox = parts[2].to_string();
                    self.config.cloud_run.defaults.model = parts[3].to_string();
                    match crate::config::persist_cloud_run_defaults(&self.config.cloud_run.defaults)
                    {
                        Ok(_) => self.toast("saved cloud-run defaults"),
                        Err(e) => self.toast(format!("save defaults: {e}")),
                    }
                }
                continue;
            }
            self.toast(msg);
        }
    }

    pub(crate) fn drain_cloud_agent_run_panes(&mut self) {
        for pane in self.panes.iter_mut() {
            if let Pane::CloudAgentRun(p) = pane {
                let _ = p.drain();
            }
        }
    }

    pub fn open_claude_agents_pane(&mut self) {
        let anchor = self.workspace.clone();
        // If the pane is already open, just focus it — don't
        // rebuild. Rebuilding clobbers the user's sort key,
        // filter state, multi-select, etc. They can press `r`
        // inside the pane for a manual refresh.
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::ClaudeAgents(_)))
        {
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::ClaudeAgents(crate::claude_agents::ClaudeAgentsPane::build_anchored(
            anchor,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Vertical, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Refresh the active Claude Agents pane in place. Same effect
    /// as `r` key in the pane. Preserves filter/group state.
    pub fn refresh_claude_agents_pane(&mut self) {
        let Some(i) = self.active else { return };
        if matches!(self.panes.get(i), Some(Pane::ClaudeAgents(_)))
            && let Some(Pane::ClaudeAgents(c)) = self.panes.get_mut(i)
        {
            c.refresh_in_place();
        }
    }

    pub fn claude_agents_toggle_workspace_only(&mut self) {
        let Some(i) = self.active else { return };
        let on = if let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(i) {
            p.workspace_only = !p.workspace_only;
            p.selected = 0;
            Some(p.workspace_only)
        } else {
            None
        };
        if let Some(on) = on {
            self.toast(if on {
                "showing this workspace only"
            } else {
                "showing all workspaces"
            });
        }
    }

    pub fn claude_agents_clear_filters(&mut self) {
        let Some(i) = self.active else { return };
        if let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(i) {
            p.clear_filters();
        }
        self.toast("filters cleared");
    }

    /// `:ai.spend_today` — open the SpendReport pane: sortable
    /// per-workspace breakdown of token + cost spend across every
    /// Claude + Codex session touched in the last 24 hours.
    ///
    /// 2026-06-21 — was a Markdown scratch (table) that the
    /// editor rendered with full syntax-highlighting + cursor /
    /// find etc., none of which makes sense for a read-only
    /// financial report. Now a dedicated pane with clickable
    /// column headers, sort cycling (`s` chord), and the
    /// renderer is workspace / total counts in its title bar.
    pub fn ai_spend_today(&mut self) {
        // Re-use an existing SpendReport pane if one is open, else
        // open fresh. Avoids accumulating 5 spend panes after a
        // few uses.
        if let Some(pid) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::SpendReport(_)))
        {
            if let Some(Pane::SpendReport(sr)) = self.panes.get_mut(pid) {
                sr.refresh();
            }
            self.active = Some(pid);
            self.focus_pane();
        } else {
            let pane = Pane::SpendReport(crate::pane::SpendReportPane::fresh());
            match self.active {
                Some(cur) => {
                    let new_id =
                        self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                    self.active = Some(new_id);
                }
                None => {
                    self.panes.push(pane);
                    let id = self.panes.len() - 1;
                    *self.layout_mut() = crate::layout::Layout::leaf(id);
                    self.active = Some(id);
                }
            }
            self.focus_pane();
        }
        // Toast the totals so the user gets the punchline even if
        // they pop the pane closed quickly.
        if let Some(pid) = self.active
            && let Some(Pane::SpendReport(p)) = self.panes.get(pid)
        {
            self.toast(format!(
                "today: {} sessions · ${:.4}",
                p.snapshot.claude_sessions + p.snapshot.codex_sessions,
                p.snapshot.total_cost_usd
            ));
        }
    }

    /// `:ai.session_search` — open a prompt for a search term.
    /// Accept runs `claude_agents::search_all_transcripts` (greps
    /// every .jsonl under ~/.claude/projects/) and dumps the hits
    /// into a `[session-search]` scratch.
    pub fn ai_session_search_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::ClaudeSessionSearch,
            "search all Claude transcripts:".to_string(),
        ));
    }

    /// Accept handler — runs the search synchronously (grep is fast
    /// enough for a few hundred MB; if it ever gets too slow we can
    /// move to a worker).
    pub fn ai_session_search_run(&mut self, query: String) {
        let hits = crate::claude_agents::search_all_transcripts(&query);
        if hits.is_empty() {
            self.toast(format!("no matches for {query:?}"));
            return;
        }
        let mut body = String::new();
        body.push_str(&format!(
            "# {} hits for {:?} across ~/.claude/projects/\n\n",
            hits.len(),
            query
        ));
        // Group by workspace so the scratch reads top-down.
        use std::collections::BTreeMap;
        let mut grouped: BTreeMap<String, Vec<&crate::claude_agents::SearchHit>> = BTreeMap::new();
        for h in &hits {
            grouped.entry(h.workspace.clone()).or_default().push(h);
        }
        for (ws, hs) in grouped {
            body.push_str(&format!("\n## {ws}\n\n"));
            for h in hs {
                let sid_short: String = h.session_id.chars().take(8).collect();
                body.push_str(&format!(
                    "- [{}] {sid_short}  ·  {}\n  {}\n  {}\n",
                    h.role.glyph(),
                    h.transcript_path.display(),
                    h.snippet,
                    "",
                ));
            }
        }
        self.open_scratch_with_text("[session-search]".to_string(), body);
        self.toast(format!("{} hits → [session-search]", hits.len()));
    }

    /// Tick hook — two refresh rates:
    ///   - every ~3s rebuild the full row set (newly-active
    ///     sessions, state transitions) via `refresh_in_place`.
    ///   - every tick re-tail JUST the selected row's transcript
    ///     when it's a live Claude session (`live_tail_selected`),
    ///     so the drill-down (todos, recent files, bash, cost,
    ///     tokens) updates ~10×/sec without waiting on the global
    ///     rebuild. Cursor stays put.
    ///
    /// Both are paused by `paused_by_user` (toggle with `p`) and
    /// the transient `paused` (filter-mode input active).
    pub fn maybe_auto_refresh_claude_agents(&mut self) {
        const REFRESH_EVERY_SECS: u64 = 3;
        let now = std::time::SystemTime::now();
        for i in 0..self.panes.len() {
            let (do_full, do_tail) = match self.panes.get(i) {
                Some(Pane::ClaudeAgents(p)) if !p.paused && !p.paused_by_user => {
                    let full = now
                        .duration_since(p.built_at)
                        .map(|d| d.as_secs() >= REFRESH_EVERY_SECS)
                        .unwrap_or(false);
                    let tail = now
                        .duration_since(p.last_live_tail)
                        .map(|d| d.as_millis() >= 500)
                        .unwrap_or(true);
                    (full, tail)
                }
                _ => (false, false),
            };
            let transitions = if do_full && let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(i)
            {
                p.refresh_in_place();
                Some(p.compute_transitions())
            } else {
                None
            };
            if let Some(msgs) = transitions {
                for msg in msgs.into_iter().take(3) {
                    self.toast(msg);
                }
            }
            if do_tail && let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(i) {
                p.live_tail_selected();
            }
        }
    }

    /// 2026-06-21 — right-click on a Files drill-down row in the
    /// dashboard. Surfaces 4 actions for the clicked file:
    /// Open (single-pane), Reveal in tree, Yank workspace-relative
    /// path, Copy file contents to a scratch buffer.
    pub fn open_dashboard_file_context_menu(&mut self, path: String, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let pb = std::path::PathBuf::from(&path);
        let rel = crate::app::rel_path(&self.workspace, &pb);
        let title = pb
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| path.clone());
        let items = vec![
            MenuItem::new("Open", MenuAction::OpenPath(pb.clone())),
            MenuItem::new("Reveal in tree", MenuAction::RevealInFinder(pb.clone())),
            MenuItem::new("Yank path", MenuAction::CopyPath(rel)),
            MenuItem::new("Open externally", MenuAction::OpenExternally(pb)),
        ];
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// 2026-06-21 vscode-mouse SEV-2: right-click on a dashboard
    /// row opens a context menu with the 7 row actions surfaced.
    /// Row is selected at click time so the menu acts on the row
    /// the user actually clicked.
    pub fn open_dashboard_row_context_menu(
        &mut self,
        pid: usize,
        row_idx: usize,
        anchor: (u16, u16),
    ) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(pid) else {
            return;
        };
        p.selected = row_idx.min(p.visible_indices().len().saturating_sub(1));
        let title = p
            .selected_row()
            .map(|r| {
                let sid_short = &r.session_id[..8.min(r.session_id.len())];
                format!("{} · {}", r.workspace, sid_short)
            })
            .unwrap_or_else(|| "session".to_string());
        let items = vec![
            MenuItem::new(
                "Open transcript",
                MenuAction::Command("ai.dashboard.open_transcript"),
            ),
            MenuItem::new(
                "Resume in mnml pty",
                MenuAction::Command("ai.dashboard.resume_in_pty"),
            ),
            MenuItem::new(
                "Yank session id",
                MenuAction::Command("ai.dashboard.yank_session_id"),
            ),
            MenuItem::new("Yank cwd", MenuAction::Command("ai.dashboard.yank_cwd")),
            MenuItem::new(
                "Export as markdown",
                MenuAction::Command("ai.dashboard.export_markdown"),
            ),
            MenuItem::new("Kill session…", MenuAction::Command("ai.dashboard.kill")),
        ];
        self.active = Some(pid);
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Yank the selected row's session id (or open transcript) — `y` / `t`.
    pub fn claude_agents_action(&mut self, action: crate::claude_agents::ClaudeAgentsAction) {
        use crate::claude_agents::ClaudeAgentsAction;
        let Some(i) = self.active else { return };
        let Some(Pane::ClaudeAgents(p)) = self.panes.get(i) else {
            return;
        };
        let Some(row) = p.selected_row() else { return };
        match action {
            ClaudeAgentsAction::YankSessionId => {
                let sid = row.session_id.clone();
                self.clipboard.set(sid.clone(), false);
                self.toast(format!("yanked session id {sid}"));
            }
            ClaudeAgentsAction::OpenTranscript => {
                let path = row.transcript_path.clone();
                if path.as_os_str().is_empty() {
                    self.toast("no transcript on disk for this session");
                    return;
                }
                self.open_path(&path);
            }
            ClaudeAgentsAction::YankCwd => {
                if let Some(cwd) = row.cwd.clone() {
                    self.clipboard.set(cwd.clone(), false);
                    self.toast(format!("yanked cwd {cwd}"));
                } else {
                    self.toast("no cwd recorded for that session");
                }
            }
            ClaudeAgentsAction::KillPrompt => {
                // Batch mode: if any rows are multi-selected, kill
                // them all (after one confirm prompt).
                // claude-agents 2026-06-28 findings 2+3: count the
                // multi-selected set's TOTAL size (live + ended)
                // even though we only kill the live ones. The
                // confirm prompt now reads "kill N of M selected"
                // so the user understands ended sessions are
                // skipped, instead of seeing the chip say ☑5 then
                // the prompt say "SIGTERM 2 sessions" (silent loss
                // of 3 from the count).
                let (batch, total_selected): (Vec<(String, u32)>, usize) =
                    if let Some(Pane::ClaudeAgents(pane)) = self.panes.get(i) {
                        (pane.multi_selected_pids(), pane.multi_selected.len())
                    } else {
                        (Vec::new(), 0)
                    };
                // Finding #2: when the user multi-selected sessions
                // but they're ALL ended (batch empty, total > 0),
                // tell them — don't silently fall through to the
                // single-row "no PID" toast.
                if batch.is_empty() && total_selected > 0 {
                    self.toast(format!(
                        "all {total_selected} selected sessions already ended — nothing to kill"
                    ));
                    return;
                }
                if !batch.is_empty() {
                    self.pending_kill_batch = batch.clone();
                    self.pending_kill_pid = None;
                    let n = batch.len();
                    let prompt_text = if n == total_selected {
                        format!("type 'kill' to SIGTERM {n} selected session(s)")
                    } else {
                        let skipped = total_selected - n;
                        format!(
                            "type 'kill' to SIGTERM {n} of {total_selected} selected ({skipped} ended, skipped)"
                        )
                    };
                    self.prompt = Some(crate::prompt::Prompt::new(
                        crate::prompt::PromptKind::ClaudeKillConfirm,
                        prompt_text,
                    ));
                    return;
                }
                let Some(pid) = row.pid else {
                    self.toast("no PID — session already ended");
                    return;
                };
                let sid = row.session_id.clone();
                let workspace = row.workspace.clone();
                self.pending_kill_pid = Some(pid);
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::ClaudeKillConfirm,
                    format!(
                        "type 'kill' to SIGTERM PID {pid} ({workspace} · {})",
                        sid.chars().take(8).collect::<String>()
                    ),
                ));
            }
            ClaudeAgentsAction::ExportMarkdown => {
                match crate::claude_agents::export_transcript_as_markdown(row) {
                    Ok((stem, md)) => {
                        let dir = self.workspace.join(".mnml").join("claude-exports");
                        if let Err(e) = std::fs::create_dir_all(&dir) {
                            self.toast(format!("export: mkdir {}: {e}", dir.display()));
                            return;
                        }
                        let path = dir.join(format!("{stem}.md"));
                        match std::fs::write(&path, &md) {
                            Ok(()) => {
                                self.toast(format!("exported → {}", path.display()));
                                self.open_path(&path);
                            }
                            Err(e) => self.toast(format!("export write: {e}")),
                        }
                    }
                    Err(e) => self.toast(format!("export: {e}")),
                }
            }
            ClaudeAgentsAction::ResumeSession => {
                use crate::claude_agents::AgentSource;
                let sid = row.session_id.clone();
                let cwd = row
                    .cwd
                    .as_deref()
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(|| self.workspace.clone());
                match row.source {
                    AgentSource::Claude => {
                        let profile =
                            crate::pty_pane::BinaryProfile::claude_code_resume(cwd, sid.clone());
                        self.open_pty(profile);
                        self.toast(format!(
                            "resuming claude session {}…",
                            sid.chars().take(8).collect::<String>()
                        ));
                    }
                    AgentSource::Codex => {
                        // Codex CLI is stateless — open a fresh codex
                        // pty in the row's cwd. (If a future codex
                        // gains --resume, swap this for the resume
                        // profile.)
                        let profile = crate::pty_pane::BinaryProfile::codex(cwd);
                        self.open_pty(profile);
                        self.toast("opened fresh codex (CLI is stateless)");
                    }
                    AgentSource::TattleQwe => {
                        // Cloud row — no local resume. Surface
                        // the runId / state in a toast so the user
                        // can copy it / open CloudWatch logs.
                        self.toast(format!("tattle-qwe run {sid} — cloud row, no local resume"));
                    }
                    AgentSource::AnthropicManaged => {
                        // Managed Agents session lives on
                        // Anthropic's side — surface the
                        // session id so user can open it in the
                        // console.
                        self.toast(format!(
                            "managed-agent {sid} — open at https://platform.claude.com/sessions/{sid}"
                        ));
                    }
                }
            }
        }
    }

    /// Fire SIGTERM at the pending kill targets. Used by the
    /// `PromptKind::ClaudeKillConfirm` accept path. Handles both
    /// single-PID (`pending_kill_pid`) and batch
    /// (`pending_kill_batch`) targets. PIDs that survive 2s of
    /// TERM are escalated to SIGKILL by
    /// `maybe_escalate_claude_kills` (tick hook).
    pub fn claude_agents_kill_confirmed(&mut self) {
        let now = std::time::SystemTime::now();
        if !self.pending_kill_batch.is_empty() {
            let batch = std::mem::take(&mut self.pending_kill_batch);
            let mut killed = 0usize;
            let mut failed = 0usize;
            let mut killed_sids: Vec<String> = Vec::new();
            let mut escalation: Vec<(u32, std::time::SystemTime)> = Vec::new();
            for (sid, pid) in &batch {
                let out = std::process::Command::new("kill")
                    .arg("-TERM")
                    .arg(pid.to_string())
                    .output();
                match out {
                    Ok(o) if o.status.success() => {
                        killed += 1;
                        killed_sids.push(sid.clone());
                        escalation.push((*pid, now));
                    }
                    _ => failed += 1,
                }
            }
            if let Some(i) = self.active
                && let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(i)
            {
                for (pid, ts) in escalation {
                    p.kill_escalation.insert(pid, ts);
                }
            }
            // Drop the killed sids from the multi-select set.
            if let Some(i) = self.active
                && let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(i)
            {
                for sid in &killed_sids {
                    p.multi_selected.remove(sid);
                }
            }
            self.toast(format!("SIGTERM → {killed} killed, {failed} failed"));
            self.refresh_claude_agents_pane();
            return;
        }
        let Some(pid) = self.pending_kill_pid.take() else {
            return;
        };
        let out = std::process::Command::new("kill")
            .arg("-TERM")
            .arg(pid.to_string())
            .output();
        let mut sent_term = false;
        match out {
            Ok(o) if o.status.success() => {
                self.toast(format!("SIGTERM → {pid}"));
                sent_term = true;
            }
            Ok(o) => {
                let err = String::from_utf8_lossy(&o.stderr);
                self.toast(format!("kill {pid} failed: {err}"));
            }
            Err(e) => self.toast(format!("kill {pid}: {e}")),
        }
        if sent_term
            && let Some(i) = self.active
            && let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(i)
        {
            p.kill_escalation.insert(pid, now);
        }
        self.refresh_claude_agents_pane();
    }

    /// Tick hook — for every PID we SIGTERM'd more than 2s ago, if
    /// it's still alive escalate to SIGKILL. Drops the entry on
    /// successful escalation OR PID disappearance.
    pub fn maybe_escalate_claude_kills(&mut self) {
        const ESCALATE_AFTER_SECS: u64 = 2;
        let now = std::time::SystemTime::now();
        let mut to_kill: Vec<u32> = Vec::new();
        let mut to_drop: Vec<u32> = Vec::new();
        for i in 0..self.panes.len() {
            let Some(Pane::ClaudeAgents(p)) = self.panes.get(i) else {
                continue;
            };
            for (pid, ts) in &p.kill_escalation {
                let age = now.duration_since(*ts).map(|d| d.as_secs()).unwrap_or(0);
                if age < ESCALATE_AFTER_SECS {
                    continue;
                }
                // `kill -0 PID` returns 0 if the process is still
                // alive (without sending any signal).
                let alive = std::process::Command::new("kill")
                    .args(["-0", &pid.to_string()])
                    .output()
                    .map(|o| o.status.success())
                    .unwrap_or(false);
                if alive {
                    to_kill.push(*pid);
                } else {
                    to_drop.push(*pid);
                }
            }
        }
        for pid in to_kill {
            let out = std::process::Command::new("kill")
                .args(["-KILL", &pid.to_string()])
                .output();
            if let Ok(o) = out
                && o.status.success()
            {
                self.toast(format!("SIGKILL → {pid} (TERM ignored)"));
                to_drop.push(pid);
            }
        }
        for i in 0..self.panes.len() {
            if let Some(Pane::ClaudeAgents(p)) = self.panes.get_mut(i) {
                for pid in &to_drop {
                    p.kill_escalation.remove(pid);
                }
            }
        }
    }
}
