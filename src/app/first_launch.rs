//! First-launch wizard — the modal overlay that asks new mnml users
//! about AI, input style, Nerd Font, tool installs, etc. Fires once
//! ever (gated by `[ui] first_launch_complete`, default false). Esc =
//! "Ask me later" (doesn't set complete → wizard reopens next launch).
//! Finish = commit + set complete = true.
//!
//! Complementary to `welcome_overlay` (per-workspace shortcut hints
//! gated by `<workspace>/.mnml/.welcomed`) — welcome fires once per
//! workspace, first-launch fires once ever globally.
//!
//! ## Design
//!
//! Single scrollable overlay, 6 sections top-to-bottom:
//! 1. AI ghost-text backend (Claude API / Local / Skip)
//! 2. Input style (vim / standard)
//! 3. Nerd Font check (Yes / No — diagnostic only)
//! 4. Claude Code + Codex CLI (detection badges; install stubbed in P1)
//! 5. VSCode `code` shim (detection badge; install stubbed in P1)
//! 6. Process monitors (btop / htop / iftop — detection badges;
//!    install stubbed in P1)
//!
//! Answers commit to config on change so a mid-wizard crash doesn't
//! lose partial progress.

use super::*;

/// Which section the user is focused on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WizardSection {
    AiBackend,
    InputStyle,
    NerdFont,
    ClaudeCode,
    VscodeShim,
    Monitors,
}

impl WizardSection {
    pub const ALL: &'static [WizardSection] = &[
        Self::AiBackend,
        Self::InputStyle,
        Self::NerdFont,
        Self::ClaudeCode,
        Self::VscodeShim,
        Self::Monitors,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::AiBackend => "AI ghost-text",
            Self::InputStyle => "Input style",
            Self::NerdFont => "Nerd Font",
            Self::ClaudeCode => "Claude Code + Codex",
            Self::VscodeShim => "VSCode `code` shim",
            Self::Monitors => "Process monitors",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Self::AiBackend => {
                "Inline completions as you type. Claude API is fastest but needs \
                 $ANTHROPIC_API_KEY; Local runs a ~1GB quantized model on your \
                 machine (downloaded on first use, cached forever)."
            }
            Self::InputStyle => {
                "vim is modal (`i` to insert, `esc` to normal, `:` for ex-cmds); \
                 standard is modeless like VS Code. Switch anytime via \
                 `editor.use_vim` / `editor.use_standard`."
            }
            Self::NerdFont => {
                "mnml uses Nerd Font glyphs for icons throughout the UI. If the \
                 sample below renders as boxes instead of icons, your terminal \
                 font isn't a Nerd Font — install one from nerdfonts.com."
            }
            Self::ClaudeCode => {
                "The two AI CLIs mnml integrates most deeply with. Not installed = \
                 you'll see \"not installed\" chips instead of live agent panels."
            }
            Self::VscodeShim => {
                "If VS Code.app is installed but its `code` CLI isn't on PATH, the \
                 VSCode integration reports `code not installed`. mnml can \
                 symlink the shim for you."
            }
            Self::Monitors => {
                "Optional process/network monitors reachable from mnml's `tools.*` \
                 palette. Nothing here is required to use mnml."
            }
        }
    }
}

/// One row-worth of user answers in the wizard.
#[derive(Debug, Clone, Default)]
pub struct WizardAnswers {
    /// One of "claude-api", "local", "skip", or "" (unanswered).
    pub ai_backend: String,
    /// One of "vim", "standard", or "" (unanswered).
    pub input_style: String,
    /// User self-reports whether Nerd glyphs render: `Some(true)` /
    /// `Some(false)` / `None` (unanswered).
    pub nerd_font_ok: Option<bool>,
    /// Deferred to Phase 2 — install actions. In P1 these carry the
    /// detected-installed state as a hint for the renderer.
    pub claude_code_installed: bool,
    pub codex_installed: bool,
    pub vscode_shim_ok: bool,
    /// Multi-select checkboxes for tools the user wants installed.
    /// Populated with defaults from detection; user toggles per row.
    pub install_btop: bool,
    pub install_htop: bool,
    pub install_iftop: bool,
}

/// Live state while the wizard overlay is open. `None` ⇒ closed.
#[derive(Debug, Clone)]
pub struct FirstLaunchState {
    pub focused_section: usize,
    pub answers: WizardAnswers,
}

impl FirstLaunchState {
    pub fn new() -> Self {
        Self {
            focused_section: 0,
            answers: WizardAnswers::default(),
        }
    }

    pub fn section(&self) -> WizardSection {
        WizardSection::ALL[self.focused_section.min(WizardSection::ALL.len() - 1)]
    }

    pub fn move_focus(&mut self, delta: i32) {
        let len = WizardSection::ALL.len() as i32;
        let cur = self.focused_section as i32;
        let next = (cur + delta).rem_euclid(len);
        self.focused_section = next as usize;
    }
}

impl App {
    /// Populate initial answers from the current config + detected
    /// state so the wizard reflects what the user has already picked.
    fn wizard_snapshot_current(&self) -> WizardAnswers {
        let ai_backend = self
            .config
            .ai
            .get("suggest_backend")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let input_style = self.config.editor.input_style.clone();
        WizardAnswers {
            ai_backend,
            input_style,
            nerd_font_ok: None,
            claude_code_installed: crate::integration_detect::is_binary_installed("claude"),
            codex_installed: crate::integration_detect::is_binary_installed("codex"),
            vscode_shim_ok: crate::integration_detect::is_binary_installed("code"),
            install_btop: false,
            install_htop: false,
            install_iftop: false,
        }
    }

    /// Open the wizard. Idempotent — if it's already open, no-op.
    pub fn open_first_launch(&mut self) {
        if self.first_launch.is_some() {
            return;
        }
        let mut state = FirstLaunchState::new();
        state.answers = self.wizard_snapshot_current();
        self.first_launch = Some(state);
    }

    /// Ask-me-later — close without setting the complete flag so
    /// the wizard reopens on next launch.
    pub fn close_first_launch_defer(&mut self) {
        self.first_launch = None;
        self.toast(
            "Wizard skipped — will ask again next launch. `first_launch.show` to reopen now.",
        );
    }

    /// Finish — persist `first_launch_complete = true`, apply any
    /// pending answers that weren't already live-committed, close.
    pub fn close_first_launch_finish(&mut self) {
        let Some(state) = self.first_launch.take() else {
            return;
        };
        // Commit each answer to config + persist to disk.
        // AI backend: "claude-api" | "local" both enable inline
        // suggestions + set the backend; "skip" leaves both defaulted
        // (backend stays Unset, inline_suggestions stays false).
        use crate::app::discovery::{
            persist_ai_bool, persist_ai_string, persist_editor_string, persist_ui_bool,
        };
        match state.answers.ai_backend.as_str() {
            "claude-api" | "local" => {
                self.set_ai_suggest_backend(crate::ai::SuggestBackend::parse(
                    &state.answers.ai_backend,
                ));
                let _ = persist_ai_string("suggest_backend", &state.answers.ai_backend);
                let _ = persist_ai_bool("inline_suggestions", true);
            }
            _ => {}
        }
        if !state.answers.input_style.is_empty() {
            self.config.editor.input_style = state.answers.input_style.clone();
            let _ = persist_editor_string("input_style", &state.answers.input_style);
        }
        self.config.ui.first_launch_complete = true;
        let _ = persist_ui_bool("first_launch_complete", true);
        self.toast("First-launch setup saved. Reopen anytime via `first_launch.show`.");
    }

    // ── Per-section update methods ───────────────────────────────

    pub fn wizard_set_ai_backend(&mut self, choice: &str) {
        if let Some(s) = self.first_launch.as_mut() {
            s.answers.ai_backend = choice.to_string();
        }
    }

    pub fn wizard_set_input_style(&mut self, choice: &str) {
        if let Some(s) = self.first_launch.as_mut() {
            s.answers.input_style = choice.to_string();
        }
    }

    pub fn wizard_set_nerd_font_ok(&mut self, ok: bool) {
        if let Some(s) = self.first_launch.as_mut() {
            s.answers.nerd_font_ok = Some(ok);
            if !ok {
                self.toast(
                    "Install a Nerd Font from https://www.nerdfonts.com/font-downloads then \
                     set it as your terminal's font.",
                );
            }
        }
    }

    pub fn wizard_toggle_monitor(&mut self, tool: &str) {
        if let Some(s) = self.first_launch.as_mut() {
            match tool {
                "btop" => s.answers.install_btop = !s.answers.install_btop,
                "htop" => s.answers.install_htop = !s.answers.install_htop,
                "iftop" => s.answers.install_iftop = !s.answers.install_iftop,
                _ => {}
            }
        }
    }

    /// Phase 2 install-action dispatcher. Each action spawns a Pty
    /// pane running the corresponding shell command so the user sees
    /// the install output live + can respond to sudo prompts. The
    /// wizard closes (as "Ask me later" — the flag stays false)
    /// so the Pty pane is visible; user re-opens with
    /// `first_launch.show` after install is done.
    pub fn wizard_install_ai_clis(&mut self) {
        let mut cmds: Vec<&str> = Vec::new();
        let claude_missing = !crate::integration_detect::is_binary_installed("claude");
        let codex_missing = !crate::integration_detect::is_binary_installed("codex");
        if claude_missing {
            cmds.push("npm install -g @anthropic-ai/claude-code");
        }
        if codex_missing {
            cmds.push("npm install -g @openai/codex");
        }
        if cmds.is_empty() {
            self.toast("Claude Code + Codex already installed.");
            return;
        }
        let combined = cmds.join(" && ");
        self.close_first_launch_defer();
        self.open_pty(crate::pty_pane::BinaryProfile::task(
            "install: ai clis",
            &combined,
            self.workspace.clone(),
        ));
    }

    pub fn wizard_install_vscode_shim(&mut self) {
        if crate::integration_detect::is_binary_installed("code") {
            self.toast("`code` shim already on PATH.");
            return;
        }
        // The .app bundle path — matches integration_detect's probe.
        let bundle_shim = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code";
        if !std::path::Path::new(bundle_shim).exists() {
            self.toast(
                "VS Code.app not found at /Applications/Visual Studio Code.app. \
                 Install VS Code first, then re-open the wizard.",
            );
            return;
        }
        // sudo ln needs a real terminal — spawn the Pty so the user
        // can enter their password interactively.
        let cmd = format!("sudo ln -sf \"{bundle_shim}\" /usr/local/bin/code");
        self.close_first_launch_defer();
        self.open_pty(crate::pty_pane::BinaryProfile::task(
            "install: code shim",
            &cmd,
            self.workspace.clone(),
        ));
    }

    pub fn wizard_install_monitors(&mut self) {
        let Some(state) = self.first_launch.as_ref() else {
            return;
        };
        let mut tools: Vec<&str> = Vec::new();
        if state.answers.install_btop {
            tools.push("btop");
        }
        if state.answers.install_htop {
            tools.push("htop");
        }
        if state.answers.install_iftop {
            tools.push("iftop");
        }
        if tools.is_empty() {
            self.toast(
                "Check the tools you want first (b / t / i to toggle), then Space to install.",
            );
            return;
        }
        let cmd = format!("brew install {}", tools.join(" "));
        self.close_first_launch_defer();
        self.open_pty(crate::pty_pane::BinaryProfile::task(
            "install: monitors",
            &cmd,
            self.workspace.clone(),
        ));
    }
}
