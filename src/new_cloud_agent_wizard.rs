//! Wizard state for `Pane::NewCloudAgentWizard`. Multi-step form
//! that creates a new cloud agent run via one of two paths:
//!
//! - **Tattle QWE** — calls the existing
//!   `App::fire_cloud_run` path (qwe-runner ECS trigger).
//! - **Claude managed agent** — drives Anthropic's
//!   managed-agents-2026-04-01 API. Three sandbox modes: cloud
//!   (default), self-hosted local (ant CLI worker on the user's
//!   machine), self-hosted remote (worker on Vercel / Cloudflare
//!   / Modal / AWS Lambda etc).
//!
//! Steps:
//!   1. Pick path (Tattle | Claude)
//!   2a. Tattle: pick ticket + flow
//!   2b. Claude: pick / create agent
//!   3.  Claude: pick environment (cloud sandbox / self-hosted)
//!   4.  Claude: configure sandbox host (local / remote target)
//!   5.  Initial prompt + metadata
//!   6.  Review + submit
//!
//! Each step has a small set of inputs; navigation is `Tab` /
//! `Shift+Tab` between fields and `Enter` to advance.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentKind {
    /// Tattle's existing qwe-runner ECS path. Picks a Jira ticket,
    /// fires a triage run. Uses the same surface as
    /// `:cloud_agents.new_run`.
    TattleQwe,
    /// Anthropic-hosted Claude managed agent. The MODEL runs on
    /// Anthropic's side; sandbox is configurable separately
    /// (see `SandboxMode`).
    ClaudeManaged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SandboxMode {
    /// Tool calls execute in Anthropic's managed cloud sandboxes
    /// (default). No worker setup required.
    CloudSandbox,
    /// `self_hosted` environment + worker runs on the user's
    /// machine (`ant beta:worker poll`). Tool calls reach the
    /// local filesystem + network.
    SelfHostedLocal,
    /// `self_hosted` environment + worker runs on a remote target
    /// (Vercel / Cloudflare / Modal / AWS / GKE / custom). Worker
    /// survives the laptop closing.
    SelfHostedRemote,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteTarget {
    AwsLambda,
    Cloudflare,
    Modal,
    Vercel,
    Daytona,
    E2B,
    Gke,
    Custom,
}

impl RemoteTarget {
    pub fn label(self) -> &'static str {
        match self {
            RemoteTarget::AwsLambda => "AWS Lambda MicroVMs",
            RemoteTarget::Cloudflare => "Cloudflare Sandbox",
            RemoteTarget::Modal => "Modal",
            RemoteTarget::Vercel => "Vercel Sandbox",
            RemoteTarget::Daytona => "Daytona",
            RemoteTarget::E2B => "E2B",
            RemoteTarget::Gke => "GKE Agent Sandbox",
            RemoteTarget::Custom => "Custom Linux host",
        }
    }
    /// One-line docs hint shown under the option.
    pub fn hint(self) -> &'static str {
        match self {
            RemoteTarget::AwsLambda => "MicroVMs · pay-per-execution · AWS region",
            RemoteTarget::Cloudflare => "Workers · global edge · ~ms cold start",
            RemoteTarget::Modal => "Serverless container · GPU available",
            RemoteTarget::Vercel => "Vercel Sandbox · function runtime",
            RemoteTarget::Daytona => "Daytona-managed dev environments",
            RemoteTarget::E2B => "E2B firecracker microVMs",
            RemoteTarget::Gke => "Google Kubernetes Engine",
            RemoteTarget::Custom => "SSH/Docker into your own Linux box",
        }
    }
    pub fn all() -> &'static [RemoteTarget] {
        &[
            RemoteTarget::AwsLambda,
            RemoteTarget::Cloudflare,
            RemoteTarget::Modal,
            RemoteTarget::Vercel,
            RemoteTarget::Daytona,
            RemoteTarget::E2B,
            RemoteTarget::Gke,
            RemoteTarget::Custom,
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WizardStep {
    Kind,
    TattleTicket,
    ClaudeAgent,
    ClaudeSandbox,
    ClaudeRemoteTarget,
    Prompt,
    Review,
}

#[derive(Debug)]
pub struct NewCloudAgentWizardPane {
    pub step: WizardStep,
    pub kind: AgentKind,
    /// Cursor row over the radio options on the current step.
    pub focus_row: usize,

    // ─── Tattle path ─────────────────────────────────────────
    /// Ticket input on TattleTicket step (`TE-NNNNN`).
    pub tattle_ticket: String,

    // ─── Claude path ─────────────────────────────────────────
    /// Existing agent id (`ag_...`) or empty if user wants to create.
    pub claude_agent_id: String,
    /// "Create new agent" toggle vs use existing.
    pub claude_agent_create_new: bool,
    /// Name for a newly-created agent.
    pub claude_agent_new_name: String,
    /// Sandbox mode picked on Step 3.
    pub claude_sandbox: SandboxMode,
    /// Remote target picked on Step 4 (only when sandbox = SelfHostedRemote).
    pub claude_remote: RemoteTarget,
    /// Existing environment id, or empty to auto-create.
    pub claude_environment_id: String,

    // ─── final step ──────────────────────────────────────────
    /// Initial prompt / task description.
    pub prompt: String,
    /// Optional metadata as `key=value` lines (parsed at submit).
    pub metadata: String,

    /// Set when the user hits Submit and the API call is in flight.
    pub submitting: bool,
    /// Surfaced result of the last submit attempt (success message or error).
    pub last_message: Option<String>,
}

impl NewCloudAgentWizardPane {
    pub fn new() -> Self {
        Self {
            step: WizardStep::Kind,
            kind: AgentKind::TattleQwe,
            focus_row: 0,
            tattle_ticket: String::new(),
            claude_agent_id: String::new(),
            claude_agent_create_new: true,
            claude_agent_new_name: "ide-agent".to_string(),
            claude_sandbox: SandboxMode::CloudSandbox,
            claude_remote: RemoteTarget::Cloudflare,
            claude_environment_id: String::new(),
            prompt: String::new(),
            metadata: String::new(),
            submitting: false,
            last_message: None,
        }
    }

    pub fn title(&self) -> &'static str {
        "+ New Cloud Agent"
    }

    /// Move to the next step based on current selection. Returns
    /// true if we advanced (caller can fire submit on Review).
    pub fn next_step(&mut self) -> bool {
        let next = match self.step {
            WizardStep::Kind => match self.kind {
                AgentKind::TattleQwe => WizardStep::TattleTicket,
                AgentKind::ClaudeManaged => WizardStep::ClaudeAgent,
            },
            WizardStep::TattleTicket => WizardStep::Prompt,
            WizardStep::ClaudeAgent => WizardStep::ClaudeSandbox,
            WizardStep::ClaudeSandbox => match self.claude_sandbox {
                SandboxMode::SelfHostedRemote => WizardStep::ClaudeRemoteTarget,
                _ => WizardStep::Prompt,
            },
            WizardStep::ClaudeRemoteTarget => WizardStep::Prompt,
            WizardStep::Prompt => WizardStep::Review,
            WizardStep::Review => return false, // submit
        };
        self.step = next;
        self.focus_row = 0;
        true
    }

    pub fn prev_step(&mut self) {
        let prev = match self.step {
            WizardStep::Kind => WizardStep::Kind,
            WizardStep::TattleTicket => WizardStep::Kind,
            WizardStep::ClaudeAgent => WizardStep::Kind,
            WizardStep::ClaudeSandbox => WizardStep::ClaudeAgent,
            WizardStep::ClaudeRemoteTarget => WizardStep::ClaudeSandbox,
            WizardStep::Prompt => match (self.kind, self.claude_sandbox) {
                (AgentKind::TattleQwe, _) => WizardStep::TattleTicket,
                (AgentKind::ClaudeManaged, SandboxMode::SelfHostedRemote) => {
                    WizardStep::ClaudeRemoteTarget
                }
                (AgentKind::ClaudeManaged, _) => WizardStep::ClaudeSandbox,
            },
            WizardStep::Review => WizardStep::Prompt,
        };
        self.step = prev;
        self.focus_row = 0;
    }
}

impl Default for NewCloudAgentWizardPane {
    fn default() -> Self {
        Self::new()
    }
}
