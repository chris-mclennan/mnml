//! Wizard state for `Pane::NewCloudRunWizard` — fires a job
//! against a Cloud Agents *runner* (something that survives the
//! laptop close). Two runner kinds shipped in Phase 3a:
//!
//!   • **Managed Agents** — Anthropic-hosted orchestration.
//!     Sandbox runs either in Anthropic's cloud (default) or on a
//!     self-hosted worker the user runs locally / remotely.
//!     API key billing.
//!   • **Tattle QWE** — ECS task fire path (existing
//!     `fire_cloud_run`). Tattle-specific infra; only useful if
//!     the user is on Tattle's AWS account.
//!
//! Steps:
//!   1. Pick runner (Managed | QWE)
//!   2a. (Managed) Configure agent + sandbox mode
//!   2b. (QWE) Ticket + flow
//!   3. Initial prompt
//!   4. Review + submit
//!
//! Submit:
//!   - Managed → POST /v1/sessions (with agent_id + environment_id)
//!   - QWE → `App::fire_cloud_run`

#[derive(Debug, Copy, Clone, PartialEq, Eq, Default)]
pub enum CloudRunner {
    /// Anthropic Managed Agents — hosted orchestration + sandbox
    /// (cloud or self-hosted worker). Requires ANTHROPIC_API_KEY.
    /// API rates billing.
    #[default]
    ManagedAgents,
    /// Tattle qwe-runner ECS task (existing path). Requires
    /// Tattle AWS SSO. Subscription billing irrelevant — runs on
    /// Tattle's own infra.
    TattleQwe,
}

impl CloudRunner {
    pub fn label(self) -> &'static str {
        match self {
            CloudRunner::ManagedAgents => "Managed Agents (Anthropic)",
            CloudRunner::TattleQwe => "Tattle QWE (ECS)",
        }
    }
    pub fn hint(self) -> &'static str {
        match self {
            CloudRunner::ManagedAgents => {
                "Anthropic-hosted Claude + sandbox · API key OR AWS SigV4 (SSO)"
            }
            CloudRunner::TattleQwe => "ECS task running qwe-runner container · Tattle AWS SSO",
        }
    }
    pub fn all() -> &'static [CloudRunner] {
        &[CloudRunner::ManagedAgents, CloudRunner::TattleQwe]
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Default)]
pub enum SandboxLocation {
    /// Anthropic's cloud sandbox (zero setup, default).
    #[default]
    AnthropicCloud,
    /// `self_hosted` environment + a worker running on the user's
    /// own infra. Phase 3b will wire the `ant beta:worker poll`
    /// spawn for local; remote workers (Vercel/Cloudflare/Modal)
    /// stay as the user's responsibility for now.
    SelfHostedLocal,
    /// Self-hosted environment, worker runs on a remote target
    /// (deferred — wizard captures the choice, user provisions the
    /// worker themselves).
    SelfHostedRemote,
}

impl SandboxLocation {
    pub fn label(self) -> &'static str {
        match self {
            SandboxLocation::AnthropicCloud => "Anthropic cloud sandbox",
            SandboxLocation::SelfHostedLocal => "Self-hosted · LOCAL worker",
            SandboxLocation::SelfHostedRemote => "Self-hosted · REMOTE worker",
        }
    }
    pub fn hint(self) -> &'static str {
        match self {
            SandboxLocation::AnthropicCloud => "Zero setup · default · pay per session",
            SandboxLocation::SelfHostedLocal => "ant beta:worker poll on this machine",
            SandboxLocation::SelfHostedRemote => {
                "Worker on your Vercel/Modal/AWS · survives laptop"
            }
        }
    }
    pub fn all() -> &'static [SandboxLocation] {
        &[
            SandboxLocation::AnthropicCloud,
            SandboxLocation::SelfHostedLocal,
            SandboxLocation::SelfHostedRemote,
        ]
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum CloudRunStep {
    Runner,
    ManagedAgent,
    ManagedSandbox,
    QweTicket,
    Prompt,
    Review,
}

#[derive(Debug)]
pub struct NewCloudRunWizardPane {
    pub step: CloudRunStep,
    pub focus_row: usize,
    pub runner: CloudRunner,

    // ─── Managed Agents path ─────────────────────────────────
    /// Existing agent id (`agent_…`) or empty if user wants the
    /// wizard to create one.
    pub managed_agent_id: String,
    pub managed_agent_create_new: bool,
    pub managed_agent_new_name: String,
    pub sandbox: SandboxLocation,
    /// Existing environment id (`env_…`) — when empty the wizard
    /// auto-creates one matching the sandbox choice.
    pub managed_env_id: String,

    // ─── QWE path ────────────────────────────────────────────
    pub qwe_ticket: String,

    // ─── final ───────────────────────────────────────────────
    pub prompt: String,
    pub submitting: bool,
    pub last_message: Option<String>,
}

impl NewCloudRunWizardPane {
    pub fn new() -> Self {
        Self {
            step: CloudRunStep::Runner,
            focus_row: 0,
            runner: CloudRunner::default(),
            managed_agent_id: String::new(),
            managed_agent_create_new: true,
            managed_agent_new_name: "ide-agent".to_string(),
            sandbox: SandboxLocation::default(),
            managed_env_id: String::new(),
            qwe_ticket: String::new(),
            prompt: String::new(),
            submitting: false,
            last_message: None,
        }
    }

    pub fn next_step(&mut self) -> bool {
        let next = match self.step {
            CloudRunStep::Runner => match self.runner {
                CloudRunner::ManagedAgents => CloudRunStep::ManagedAgent,
                CloudRunner::TattleQwe => CloudRunStep::QweTicket,
            },
            CloudRunStep::ManagedAgent => CloudRunStep::ManagedSandbox,
            CloudRunStep::ManagedSandbox => CloudRunStep::Prompt,
            CloudRunStep::QweTicket => CloudRunStep::Prompt,
            CloudRunStep::Prompt => CloudRunStep::Review,
            CloudRunStep::Review => return false,
        };
        self.step = next;
        self.focus_row = 0;
        true
    }

    pub fn prev_step(&mut self) {
        let prev = match self.step {
            CloudRunStep::Runner => CloudRunStep::Runner,
            CloudRunStep::ManagedAgent => CloudRunStep::Runner,
            CloudRunStep::ManagedSandbox => CloudRunStep::ManagedAgent,
            CloudRunStep::QweTicket => CloudRunStep::Runner,
            CloudRunStep::Prompt => match self.runner {
                CloudRunner::ManagedAgents => CloudRunStep::ManagedSandbox,
                CloudRunner::TattleQwe => CloudRunStep::QweTicket,
            },
            CloudRunStep::Review => CloudRunStep::Prompt,
        };
        self.step = prev;
        self.focus_row = 0;
    }
}

impl Default for NewCloudRunWizardPane {
    fn default() -> Self {
        Self::new()
    }
}
