//! Wizard state for `Pane::NewCloudAgentWizard`. v2 redesigned
//! around the **Claude Agent SDK** as the only agent (per user
//! 2026-06-27). Picks a SOURCE (GitHub PR / Bitbucket PR / manual
//! prompt), optionally multi-selects N items from a list,
//! picks an ACTION template (triage/review/test/custom), then
//! fires one Claude Code session per selected item.
//!
//! Steps:
//!   1. Pick source
//!   2. (PR sources) Multi-select PR list
//!   3. Pick action
//!   4. (Custom action) Type the prompt
//!   5. Review + submit
//!
//! On submit, for each selected PR:
//!   - `gh pr checkout <num>` (or Bitbucket equivalent)
//!   - Spawn `claude --print "<action prompt> for PR #<num>"` in
//!     a Pty pane scoped to the worktree
//!
//! For the manual prompt source, spawn one Claude session in the
//! current workspace with the user-typed prompt.

use std::sync::mpsc::Receiver;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Source {
    /// Pick from `gh pr list` on the user's active repo.
    #[default]
    GitHubPr,
    /// Pick from the user's Bitbucket repo PRs (requires
    /// BITBUCKET_PERSONAL_TOKEN + BITBUCKET_USERNAME env vars).
    BitbucketPr,
    /// No list — type a single prompt, fire one agent in the
    /// current workspace.
    ManualPrompt,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Source::GitHubPr => "GitHub PR",
            Source::BitbucketPr => "Bitbucket PR",
            Source::ManualPrompt => "Manual prompt",
        }
    }
    pub fn hint(self) -> &'static str {
        match self {
            Source::GitHubPr => "Open PRs from `gh pr list` on the active repo",
            Source::BitbucketPr => "Open PRs from Bitbucket (BITBUCKET_PERSONAL_TOKEN required)",
            Source::ManualPrompt => "Skip the list — type a single task and fire one agent",
        }
    }
    pub fn all() -> &'static [Source] {
        &[Source::GitHubPr, Source::BitbucketPr, Source::ManualPrompt]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Action {
    /// "Triage this PR — summarise the change, list risks,
    /// suggest follow-up tickets."
    #[default]
    Triage,
    /// "Review this PR — find correctness / security / style
    /// issues; suggest fixes."
    Review,
    /// "Run the relevant tests for this PR and report results."
    Test,
    /// User types the prompt verbatim.
    Custom,
}

impl Action {
    pub fn label(self) -> &'static str {
        match self {
            Action::Triage => "Triage",
            Action::Review => "Review",
            Action::Test => "Test",
            Action::Custom => "Custom prompt",
        }
    }
    pub fn hint(self) -> &'static str {
        match self {
            Action::Triage => "Summarise the change, list risks, suggest follow-ups",
            Action::Review => "Find correctness / security / style issues; suggest fixes",
            Action::Test => "Run the relevant tests and report results",
            Action::Custom => "Type your own prompt — full agentic autonomy",
        }
    }
    pub fn all() -> &'static [Action] {
        &[Action::Triage, Action::Review, Action::Test, Action::Custom]
    }
    /// Render the action's default prompt as a template — the
    /// `<num>` placeholder is replaced with the actual PR number
    /// at submit time. Manual / Custom action returns the user's
    /// typed prompt verbatim from `pane.custom_prompt`.
    pub fn prompt_template(self) -> &'static str {
        match self {
            Action::Triage => {
                "Triage PR #<num>: summarise the change in 3-5 bullets, \
                 enumerate risks (regressions, security, perf), and suggest \
                 follow-up tickets. Read the diff first, then any touched \
                 modules to ground the risk assessment."
            }
            Action::Review => {
                "Review PR #<num>: act as a senior reviewer. Find \
                 correctness issues, security issues, style nits, and \
                 missing tests. Comment with file:line citations. \
                 Prioritise blockers."
            }
            Action::Test => {
                "Run the relevant tests for PR #<num>. Identify which test \
                 suites cover the changed code, run them, and report any \
                 failures with reproduction steps."
            }
            Action::Custom => "<custom>",
        }
    }
}

/// One row in the PR multi-select list.
#[derive(Debug, Clone)]
pub struct PrRow {
    pub number: u32,
    pub title: String,
    pub author: String,
    pub state: String,
    /// True when the user has checked this row for inclusion.
    pub selected: bool,
}

/// Worker events for the PR-list fetcher (gh or Bitbucket).
pub enum PrListEvent {
    Rows(Vec<PrRow>),
    Done,
    Error(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WizardStep {
    Source,
    PrList,
    Action,
    CustomPrompt,
    Review,
}

#[derive(Debug)]
pub struct NewCloudAgentWizardPane {
    pub step: WizardStep,
    /// Cursor row over the focused step.
    pub focus_row: usize,

    // ─── source step ────────────────────────────────────────────
    pub source: Source,

    // ─── PR list step ───────────────────────────────────────────
    pub pr_rows: Vec<PrRow>,
    pub pr_loading: bool,
    pub pr_err: Option<String>,
    pub pr_rx: Option<Receiver<PrListEvent>>,
    /// `gh pr list` doesn't paginate by default; we cap display at
    /// 50 to keep things scannable.
    pub pr_cap: usize,

    // ─── action step ───────────────────────────────────────────
    pub action: Action,

    // ─── custom prompt step ─────────────────────────────────────
    pub custom_prompt: String,

    // ─── submission state ──────────────────────────────────────
    pub submitting: bool,
    pub last_message: Option<String>,
}

impl NewCloudAgentWizardPane {
    pub fn new() -> Self {
        Self {
            step: WizardStep::Source,
            focus_row: 0,
            source: Source::default(),
            pr_rows: Vec::new(),
            pr_loading: false,
            pr_err: None,
            pr_rx: None,
            pr_cap: 50,
            action: Action::default(),
            custom_prompt: String::new(),
            submitting: false,
            last_message: None,
        }
    }

    pub fn title(&self) -> &'static str {
        "+ New Cloud Agent"
    }

    /// Move forward in the step graph. Returns false on Review
    /// (caller should fire submit).
    pub fn next_step(&mut self) -> bool {
        let next = match self.step {
            WizardStep::Source => match self.source {
                Source::ManualPrompt => WizardStep::CustomPrompt,
                _ => WizardStep::PrList,
            },
            WizardStep::PrList => WizardStep::Action,
            WizardStep::Action => match self.action {
                Action::Custom => WizardStep::CustomPrompt,
                _ => WizardStep::Review,
            },
            WizardStep::CustomPrompt => WizardStep::Review,
            WizardStep::Review => return false,
        };
        self.step = next;
        self.focus_row = 0;
        true
    }

    pub fn prev_step(&mut self) {
        let prev = match self.step {
            WizardStep::Source => WizardStep::Source,
            WizardStep::PrList => WizardStep::Source,
            WizardStep::Action => match self.source {
                Source::ManualPrompt => WizardStep::CustomPrompt, // ManualPrompt skips PrList; back goes Source via prev
                _ => WizardStep::PrList,
            },
            WizardStep::CustomPrompt => match self.source {
                Source::ManualPrompt => WizardStep::Source,
                _ => WizardStep::Action,
            },
            WizardStep::Review => match self.action {
                Action::Custom => WizardStep::CustomPrompt,
                _ => WizardStep::Action,
            },
        };
        self.step = prev;
        self.focus_row = 0;
    }

    /// How many PRs are currently checked.
    pub fn selected_count(&self) -> usize {
        self.pr_rows.iter().filter(|r| r.selected).count()
    }

    /// Drain the PR-list worker channel.
    pub fn drain(&mut self) -> bool {
        let mut changed = false;
        if let Some(rx) = self.pr_rx.take() {
            let mut still_open = true;
            while let Ok(ev) = rx.try_recv() {
                changed = true;
                match ev {
                    PrListEvent::Rows(mut rows) => self.pr_rows.append(&mut rows),
                    PrListEvent::Done => {
                        self.pr_loading = false;
                        still_open = false;
                    }
                    PrListEvent::Error(e) => {
                        self.pr_err = Some(e);
                        self.pr_loading = false;
                        still_open = false;
                    }
                }
            }
            if still_open {
                self.pr_rx = Some(rx);
            }
        }
        changed
    }
}

impl Default for NewCloudAgentWizardPane {
    fn default() -> Self {
        Self::new()
    }
}

/// Spawn a worker that runs `gh pr list --json number,title,state,author` on
/// `repo_dir` and streams parsed rows back via the channel.
pub fn spawn_gh_pr_fetcher(repo_dir: std::path::PathBuf) -> Receiver<PrListEvent> {
    use std::process::{Command, Stdio};
    use std::sync::mpsc::{Sender, channel};

    let (tx, rx): (Sender<PrListEvent>, Receiver<PrListEvent>) = channel();
    std::thread::spawn(move || {
        let out = Command::new("gh")
            .args([
                "pr",
                "list",
                "--state",
                "open",
                "--limit",
                "50",
                "--json",
                "number,title,state,author",
            ])
            .current_dir(&repo_dir)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();
        let out = match out {
            Ok(o) => o,
            Err(e) => {
                let _ = tx.send(PrListEvent::Error(format!("spawn gh: {e}")));
                return;
            }
        };
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
            let _ = tx.send(PrListEvent::Error(format!("gh pr list failed: {stderr}")));
            return;
        }
        let parsed: Result<Vec<GhPr>, _> = serde_json::from_slice(&out.stdout);
        let rows: Vec<PrRow> = match parsed {
            Ok(v) => v
                .into_iter()
                .map(|p| PrRow {
                    number: p.number,
                    title: p.title,
                    author: p.author.map(|a| a.login).unwrap_or_default(),
                    state: p.state,
                    selected: false,
                })
                .collect(),
            Err(e) => {
                let _ = tx.send(PrListEvent::Error(format!("parse gh JSON: {e}")));
                return;
            }
        };
        let _ = tx.send(PrListEvent::Rows(rows));
        let _ = tx.send(PrListEvent::Done);
    });
    rx
}

#[derive(serde::Deserialize)]
struct GhPr {
    number: u32,
    title: String,
    state: String,
    author: Option<GhAuthor>,
}

#[derive(serde::Deserialize)]
struct GhAuthor {
    login: String,
}

/// Spawn a worker that fetches Bitbucket PRs for the given repo.
/// Reads BITBUCKET_PERSONAL_TOKEN + BITBUCKET_USERNAME from the
/// environment; bails with an error if either is missing.
/// `repo_slug` is `<workspace>/<repo>` (Bitbucket convention).
pub fn spawn_bitbucket_pr_fetcher(repo_slug: String) -> Receiver<PrListEvent> {
    use std::sync::mpsc::{Sender, channel};

    let (tx, rx): (Sender<PrListEvent>, Receiver<PrListEvent>) = channel();
    std::thread::spawn(move || {
        let token = match std::env::var("BITBUCKET_PERSONAL_TOKEN") {
            Ok(t) => t,
            Err(_) => {
                let _ = tx.send(PrListEvent::Error(
                    "BITBUCKET_PERSONAL_TOKEN not set in environment".to_string(),
                ));
                return;
            }
        };
        let user = match std::env::var("BITBUCKET_USERNAME") {
            Ok(u) => u,
            Err(_) => {
                let _ = tx.send(PrListEvent::Error(
                    "BITBUCKET_USERNAME not set in environment".to_string(),
                ));
                return;
            }
        };
        // Bitbucket Cloud API:
        //   GET /2.0/repositories/{workspace}/{repo}/pullrequests
        // Basic auth: BB username + app password (the "personal token" is
        // typically an app password in the Bitbucket Cloud sense).
        let url = format!(
            "https://api.bitbucket.org/2.0/repositories/{repo_slug}/pullrequests?state=OPEN&pagelen=50"
        );
        use base64::Engine;
        let basic = base64::engine::general_purpose::STANDARD.encode(format!("{user}:{token}"));
        let req = crate::http::Request {
            method: "GET".to_string(),
            url,
            headers: vec![
                ("Authorization".to_string(), format!("Basic {basic}")),
                ("Accept".to_string(), "application/json".to_string()),
            ],
            body: None,
        };
        let resp = match crate::http::send(&req) {
            Ok(r) => r,
            Err(e) => {
                let _ = tx.send(PrListEvent::Error(format!("bitbucket fetch: {e}")));
                return;
            }
        };
        if resp.status < 200 || resp.status >= 300 {
            let _ = tx.send(PrListEvent::Error(format!(
                "bitbucket HTTP {} — check token + repo slug",
                resp.status
            )));
            return;
        }
        let body = resp.body;
        let parsed: Result<BbPrPage, _> = serde_json::from_str(&body);
        let rows: Vec<PrRow> = match parsed {
            Ok(p) => p
                .values
                .into_iter()
                .map(|pr| PrRow {
                    number: pr.id,
                    title: pr.title,
                    author: pr.author.map(|a| a.display_name).unwrap_or_default(),
                    state: pr.state,
                    selected: false,
                })
                .collect(),
            Err(e) => {
                let _ = tx.send(PrListEvent::Error(format!("parse bitbucket JSON: {e}")));
                return;
            }
        };
        let _ = tx.send(PrListEvent::Rows(rows));
        let _ = tx.send(PrListEvent::Done);
    });
    rx
}

#[derive(serde::Deserialize)]
struct BbPrPage {
    values: Vec<BbPr>,
}

#[derive(serde::Deserialize)]
struct BbPr {
    id: u32,
    title: String,
    state: String,
    author: Option<BbAuthor>,
}

#[derive(serde::Deserialize)]
struct BbAuthor {
    display_name: String,
}
