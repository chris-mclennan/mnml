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
//! Single scrollable overlay, 6 sections top-to-bottom. Order matches
//! dependency flow (reordered 2026-08-17 — prior order asked ghost-text
//! backend first, before install / billing were even covered):
//! 1. Nerd Font check (Yes / No — visual foundation, affects rendering
//!    of everything below)
//! 2. Input style (standard / vim — fundamental interaction model)
//! 3. Claude Code + Codex CLI (detection badges + shell-installer
//!    action per `curl … | sh` docs, 2026-08-11 verified — install
//!    before choosing routing)
//! 4. AI billing preference (per-product routing — task #975,
//!    2026-08-17): Claude Code Sub/API/Off + Codex Sub/Off
//! 5. AI ghost-text backend (specific always-on feature — inherits
//!    from #4's Claude routing)
//! 6. VSCode `code` shim (detection badge; symlink helper —
//!    optional convenience)
//!
//! (Process monitors section removed 2026-08-11 — was inline
//! btop/htop/iftop checkboxes; discovered via the marketplace pane
//! instead so the wizard stays under 5 sections.)
//!
//! Answers commit to config on change so a mid-wizard crash doesn't
//! lose partial progress.

use super::*;

/// Read the DECLARED `[ai.routing.<product>] backend` value from the
/// config, if set. `None` when unset — the wizard treats that as "leave
/// the resolved default alone" (the Auto radio in the UI). Task #975.
fn declared_route(ai: &toml::Value, product: crate::ai::AiProduct) -> String {
    ai.get("routing")
        .and_then(|r| r.get(product.key()))
        .and_then(|p| p.get("backend"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default()
}

/// Which section the user is focused on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WizardSection {
    AiBackend,
    InputStyle,
    NerdFont,
    /// Per-product routing — task #975 (2026-08-17). Two rows inside
    /// (Claude Code + Codex); `focused_ai_route_row` tracks which
    /// one the caret is on.
    AiRouting,
    ClaudeCode,
    VscodeShim,
}

impl WizardSection {
    // 2026-08-17 — reordered so dependencies flow naturally:
    //   1. Nerd Font (visual foundation — affects everything rendered below)
    //   2. Input style (vim vs standard — fundamental interaction model)
    //   3. Claude Code + Codex install (install CLIs before choosing routing)
    //   4. AI billing preference (Sub option only usable once CLI installed)
    //   5. AI ghost-text (specific always-on feature — inherits backend from #4)
    //   6. VSCode `code` shim (optional convenience)
    // Prior order asked ghost-text FIRST, before install/billing were even
    // covered — user hit a chicken-and-egg wall and reported it.
    pub const ALL: &'static [WizardSection] = &[
        Self::NerdFont,
        Self::InputStyle,
        Self::ClaudeCode,
        Self::AiRouting,
        Self::AiBackend,
        Self::VscodeShim,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::AiBackend => "AI ghost-text",
            Self::InputStyle => "Input style",
            Self::NerdFont => "Nerd Font",
            Self::AiRouting => "AI billing preference",
            Self::ClaudeCode => "Claude Code + Codex",
            Self::VscodeShim => "VSCode `code` shim",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Self::AiBackend => {
                "Inline completions as you type. Claude Code sub reuses your Max/Pro \
                 plan via the OAuth token Claude Code already caches — no separate \
                 API key needed. Claude API bills to a pay-per-token console budget. \
                 Local runs a ~1GB quantized model on your machine (offline)."
            }
            Self::InputStyle => {
                "vim is modal (`i` to insert, `esc` to normal, `:` for ex-cmds); \
                 standard is modeless like VS Code. Switch anytime via \
                 `editor.use_vim` / `editor.use_standard`."
            }
            Self::NerdFont => {
                "mnml uses Nerd Font glyphs for icons throughout the UI. If the \
                 sample below renders as boxes instead of icons, your terminal \
                 font isn't a Nerd Font. Press Space to auto-install Symbols \
                 Nerd Font Mono (brew / winget / curl per OS) — you'll still \
                 need to point your terminal at the new font and restart it."
            }
            Self::AiRouting => {
                "For each AI product below, tell mnml where to route calls. \
                 Subscription = reuses your Max/Pro / ChatGPT Plus plan via the \
                 vendor's own CLI (no per-token charge). API = billed against your \
                 pay-per-token console budget (needs $ANTHROPIC_API_KEY). Off = \
                 hide the chips + disable the commands for that product entirely."
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
    /// True once the user has actively cycled the input_style row
    /// (via ←/→/h/l). Gates persistence on Finish: unchanged =
    /// don't rewrite `editor.input_style` even if the wizard's
    /// pre-select differs from the persisted value. Prevents a
    /// vim user who reopens the wizard for the Nerd Font check
    /// from silently losing their vim mode by hitting Enter.
    pub input_style_touched: bool,
    /// User self-reports whether Nerd glyphs render: `Some(true)` /
    /// `Some(false)` / `None` (unanswered).
    pub nerd_font_ok: Option<bool>,
    /// Per-product routing (task #975, 2026-08-17). One of "sub",
    /// "api", "off", or "" (leave the resolved default alone).
    /// Persists to `[ai.routing.claude] backend = ...`.
    pub route_claude: String,
    /// Sibling to `route_claude`. One of "sub", "off", or "" (Codex
    /// has no API-passthrough today, so "api" isn't offered). Persists
    /// to `[ai.routing.codex] backend = ...`.
    pub route_codex: String,
    /// True once the user has actively cycled either AI-routing row —
    /// same guard as `input_style_touched`. Prevents a returning user
    /// who reopens the wizard from silently overwriting their existing
    /// `[ai.routing.*]` pins by hitting Enter without visiting the row.
    pub ai_routing_touched: bool,
    /// Deferred to Phase 2 — install actions. In P1 these carry the
    /// detected-installed state as a hint for the renderer.
    pub claude_code_installed: bool,
    pub codex_installed: bool,
    pub vscode_shim_ok: bool,
}

/// Live state while the wizard overlay is open. `None` ⇒ closed.
#[derive(Debug, Clone)]
pub struct FirstLaunchState {
    pub focused_section: usize,
    pub answers: WizardAnswers,
    /// Row index inside the AI-routing section (0 = Claude, 1 = Codex).
    /// Sections without inner rows ignore this. Tracked because the
    /// AI-routing section has TWO rows the user can independently
    /// cycle. j/k move rows within the section; the section-move
    /// arrows (up/down at section boundaries) still cycle sections.
    pub focused_ai_route_row: usize,
}

impl FirstLaunchState {
    pub fn new() -> Self {
        Self {
            focused_section: 0,
            answers: WizardAnswers::default(),
            focused_ai_route_row: 0,
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
        // Reset the AI-route sub-row when leaving/re-entering; matches
        // the "top row when a section becomes focused" convention.
        self.focused_ai_route_row = 0;
    }
}

impl App {
    /// Populate initial answers from the current config + detected
    /// state so the wizard reflects what the user has already picked.
    fn wizard_snapshot_current(&self) -> WizardAnswers {
        // Pre-select the ghost-text backend from config. When empty,
        // default to "claude-code" if we have decent signal that
        // Claude Code is set up on this machine — the `claude` binary
        // is on PATH AND `~/.claude/` exists (created on first
        // `claude` launch, so its presence is a good "user has been
        // through Claude Code sign-in at least once" proxy). Neither
        // proves a valid token exists, but a Keychain probe would
        // risk a macOS auth-prompt modal that freezes the TUI —
        // better to auto-select and let the first ghost-text call
        // fail with the actionable "run `claude` to sign in" toast.
        let ai_backend = self
            .config
            .ai
            .get("suggest_backend")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                let has_claude_cli = crate::integration_detect::is_binary_installed("claude");
                let has_claude_home = std::env::var_os("HOME")
                    .map(|h| std::path::PathBuf::from(h).join(".claude").is_dir())
                    .unwrap_or(false);
                if has_claude_cli && has_claude_home {
                    "claude-code".to_string()
                } else {
                    String::new()
                }
            });
        // Input style: pre-select from the persisted config when set
        // (returning users see their current ● selection), else fall
        // back to the app default "standard". The "(current)" tag in
        // the overlay marks the persisted value regardless of what
        // the radio is on. `input_style_touched` starts false — the
        // wizard's Finish path only rewrites `editor.input_style` if
        // the user actively cycled the row (via ←/→/h/l). Prevents a
        // vim user who reopens the wizard for the Nerd Font check
        // from silently losing their vim mode by hitting Enter.
        let input_style = if self.config.editor.input_style.is_empty() {
            "standard".to_string()
        } else {
            self.config.editor.input_style.clone()
        };
        // Pre-select each AI-routing row from the DECLARED config
        // choice (not the resolved one) so a returning user sees their
        // pinned selection. Empty when the key isn't set — the "Auto"
        // radio shown in the overlay maps to "" here so the wizard's
        // touched-guard keeps the file untouched on Finish.
        let route_claude = declared_route(&self.config.ai, crate::ai::AiProduct::Claude);
        let route_codex = declared_route(&self.config.ai, crate::ai::AiProduct::Codex);
        WizardAnswers {
            ai_backend,
            input_style,
            input_style_touched: false,
            nerd_font_ok: None,
            route_claude,
            route_codex,
            ai_routing_touched: false,
            claude_code_installed: crate::integration_detect::is_binary_installed("claude"),
            codex_installed: crate::integration_detect::is_binary_installed("codex"),
            vscode_shim_ok: crate::integration_detect::is_binary_installed("code"),
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
        // AI backend: "claude-code" | "claude-api" | "local" all
        // enable inline suggestions + set the backend; "skip" (or
        // empty) leaves both defaulted (backend stays Unset,
        // inline_suggestions stays false).
        use crate::app::discovery::{
            persist_ai_bool, persist_ai_string, persist_editor_string, persist_ui_bool,
        };
        // R8 keyboard-tester SEV-1 (2026-08-11): every persist call
        // here used to be `let _ =`, so a write failure (missing
        // $HOME, non-writable config dir, portable-mode path drift)
        // silently left the file untouched and the wizard reopened
        // every launch. Collect any errors and surface them via toast
        // so the user sees WHY the setup didn't stick instead of a
        // silent phantom reset.
        let mut errs: Vec<String> = Vec::new();
        match state.answers.ai_backend.as_str() {
            "claude-code" | "claude-api" | "local" => {
                self.set_ai_suggest_backend(crate::ai::SuggestBackend::parse(
                    &state.answers.ai_backend,
                ));
                if let Err(e) = persist_ai_string("suggest_backend", &state.answers.ai_backend) {
                    errs.push(format!("ai.suggest_backend: {e}"));
                }
                if let Err(e) = persist_ai_bool("inline_suggestions", true) {
                    errs.push(format!("ai.inline_suggestions: {e}"));
                }
            }
            _ => {}
        }
        // Gate persistence on `input_style_touched` — the wizard's
        // pre-select is a display convenience, not user intent. A
        // returning vim user reopening the wizard for the Nerd Font
        // check must not have their input_style silently rewritten
        // to standard just because they hit Enter without visiting
        // the Input Style row. Only persist when the user actively
        // cycled the row via ←/→/h/l (see `cycle_input_style` in
        // `src/tui/handlers/overlay.rs`, which sets touched=true).
        if state.answers.input_style_touched && !state.answers.input_style.is_empty() {
            self.config.editor.input_style = state.answers.input_style.clone();
            if let Err(e) = persist_editor_string("input_style", &state.answers.input_style) {
                errs.push(format!("editor.input_style: {e}"));
            }
        }
        // AI billing preference (task #975). Same touched-guard as
        // input_style so a returning user can't have their existing
        // pins silently rewritten by hitting Enter. Empty value =
        // "Auto" radio in the UI = clear any pin (but we don't rewrite
        // the file in that case — leaving keys undefined is what Auto
        // means at the config level).
        if state.answers.ai_routing_touched {
            for (product, choice) in [
                ("claude", state.answers.route_claude.as_str()),
                ("codex", state.answers.route_codex.as_str()),
            ] {
                if choice.is_empty() {
                    continue;
                }
                if let Err(e) = crate::app::discovery::persist_ai_routing(product, choice) {
                    errs.push(format!("ai.routing.{product}: {e}"));
                    continue;
                }
                // Reflect the change in the live in-memory config so
                // the next-tick chip / gate behaviour matches without
                // a restart.
                self.write_live_ai_routing(product, choice);
            }
        }
        self.config.ui.first_launch_complete = true;
        if let Err(e) = persist_ui_bool("first_launch_complete", true) {
            errs.push(format!("ui.first_launch_complete: {e}"));
        }
        if errs.is_empty() {
            self.toast("Setup saved. Reopen anytime via `first_launch.show`.");
        } else {
            // Show the first error verbatim; the rest are the same
            // root cause 99% of the time (missing writable config dir).
            self.toast(format!(
                "Setup save failed — {} (wizard will reopen next launch)",
                errs[0]
            ));
        }
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
            s.answers.input_style_touched = true;
        }
    }

    /// Set the wizard's Claude routing pick. `choice` is "sub" / "api"
    /// / "off" / "" (empty = Auto — leave existing pin alone). Sets
    /// the touched-guard so Finish knows to persist. Task #975.
    pub fn wizard_set_route_claude(&mut self, choice: &str) {
        if let Some(s) = self.first_launch.as_mut() {
            s.answers.route_claude = choice.to_string();
            s.answers.ai_routing_touched = true;
        }
    }

    /// Sibling to `wizard_set_route_claude` for Codex. Task #975.
    pub fn wizard_set_route_codex(&mut self, choice: &str) {
        if let Some(s) = self.first_launch.as_mut() {
            s.answers.route_codex = choice.to_string();
            s.answers.ai_routing_touched = true;
        }
    }

    /// Mirror a persisted `[ai.routing.<product>] backend = <choice>`
    /// into the live `self.config.ai` toml tree so the next-tick
    /// chip / gate behavior matches without a full restart. The
    /// on-disk write is done by `persist_ai_routing`; this is the
    /// in-memory twin.
    pub(super) fn write_live_ai_routing(&mut self, product: &str, choice: &str) {
        if !self.config.ai.is_table() {
            self.config.ai = toml::Value::Table(toml::value::Table::new());
        }
        let Some(ai_tbl) = self.config.ai.as_table_mut() else {
            return;
        };
        let routing = ai_tbl
            .entry("routing".to_string())
            .or_insert_with(|| toml::Value::Table(toml::value::Table::new()));
        if !routing.is_table() {
            *routing = toml::Value::Table(toml::value::Table::new());
        }
        let Some(routing_tbl) = routing.as_table_mut() else {
            return;
        };
        let product_tbl = routing_tbl
            .entry(product.to_string())
            .or_insert_with(|| toml::Value::Table(toml::value::Table::new()));
        if !product_tbl.is_table() {
            *product_tbl = toml::Value::Table(toml::value::Table::new());
        }
        if let Some(t) = product_tbl.as_table_mut() {
            t.insert(
                "backend".to_string(),
                toml::Value::String(choice.to_string()),
            );
        }
    }

    pub fn wizard_set_nerd_font_ok(&mut self, ok: bool) {
        if let Some(s) = self.first_launch.as_mut() {
            s.answers.nerd_font_ok = Some(ok);
            if !ok {
                self.toast(
                    "Press Space to install Symbols Nerd Font, or install manually from \
                     https://www.nerdfonts.com/font-downloads.",
                );
            }
        }
    }

    /// Install a Nerd Font + surface the terminal-specific configure
    /// step the user needs to do themselves. Font install is
    /// automatable per OS (brew / winget / apt); pointing the
    /// terminal at the new font mostly isn't (iTerm2 / Terminal.app
    /// are GUI-only, ghostty / alacritty / kitty have config files
    /// we could edit but the safer path is to instruct + let the
    /// user restart the terminal).
    ///
    /// Font choice: `Symbols Nerd Font Mono` — the small (~2MB)
    /// symbols-only variant, matches mnml's `font-codepoint-map`
    /// routing (see CLAUDE.md ranges E5FA-E8FF / EA60-EC1E /
    /// F0001-F1AFF). The full Nerd Font packs replace the entire
    /// mono font which most users don't want.
    ///
    /// 2026-08-11 install-command verification:
    /// - macOS: `brew install --cask font-symbols-only-nerd-font`
    ///   (homebrew/cask-fonts) — verified brew.sh.
    /// - Linux: falls back to a `curl | unzip` since distros'
    ///   nerd-font packages vary wildly (arch has aur, debian has
    ///   no upstream package, nix has one). Downloads
    ///   NerdFontsSymbolsOnly.zip from the latest GH release
    ///   into `~/.local/share/fonts/` and runs `fc-cache -f`.
    /// - Windows: `winget install --id NerdFonts.SymbolsOnly`
    ///   (or a curl fallback).
    pub fn wizard_install_nerd_font(&mut self) {
        let os = std::env::consts::OS;
        let install_cmd: String = match os {
            "macos" => "brew install --cask font-symbols-only-nerd-font".to_string(),
            "linux" => {
                // Download → unzip → fc-cache. `~/.local/share/fonts`
                // is the user-scope XDG dir; fc-cache -f rebuilds
                // the fontconfig index so the new font is visible
                // to applications without a reboot.
                let dl = "https://github.com/ryanoasis/nerd-fonts/releases/latest/\
                          download/NerdFontsSymbolsOnly.zip";
                format!(
                    "set -e; \
                     mkdir -p ~/.local/share/fonts/nerd-symbols; \
                     cd ~/.local/share/fonts/nerd-symbols; \
                     curl -fsSL '{dl}' -o pack.zip; \
                     unzip -o pack.zip; \
                     rm pack.zip; \
                     fc-cache -f; \
                     echo 'Symbols Nerd Font Mono installed to ~/.local/share/fonts/nerd-symbols'"
                )
            }
            "windows" => "winget install --id NerdFonts.SymbolsOnly -e".to_string(),
            other => {
                self.toast(format!(
                    "No auto-install for OS '{other}' — download from https://www.nerdfonts.com."
                ));
                return;
            }
        };
        // Follow-up: what the user does after the font's on disk.
        // `$TERM_PROGRAM` is macOS-canonical (`ghostty` / `iTerm.app` /
        // `Apple_Terminal`), often set on Linux (ghostty / kitty
        // export it), unreliable on Windows.
        let term_hint = match std::env::var("TERM_PROGRAM").ok().as_deref() {
            Some("ghostty") => {
                "Then: add `font-family = Symbols Nerd Font Mono` (or `font-codepoint-map = ...` \
                 for icon-glyph ranges — see CLAUDE.md) to `~/.config/ghostty/config`, restart \
                 ghostty."
            }
            Some("iTerm.app") => {
                "Then: iTerm2 → Preferences → Profiles → Text → Font → choose Symbols Nerd Font \
                 Mono. Restart iTerm2."
            }
            Some("Apple_Terminal") => {
                "Then: Terminal → Preferences → Profiles → Text → Font → choose Symbols Nerd \
                 Font Mono. Restart Terminal.app."
            }
            Some("WezTerm") => {
                "Then: add `Symbols Nerd Font Mono` to `font` fallback in \
                 `~/.wezterm.lua`, restart WezTerm."
            }
            _ => {
                if os == "windows" {
                    "Then: Windows Terminal → Settings → your profile → Appearance → Font \
                     face → Symbols Nerd Font Mono. Restart the terminal."
                } else {
                    "Then: point your terminal's font (or its fallback list) at 'Symbols \
                     Nerd Font Mono'. Restart the terminal so it re-reads the font list."
                }
            }
        };
        self.close_first_launch_defer();
        self.toast(term_hint);
        self.open_pty(crate::pty_pane::BinaryProfile::task(
            "install: nerd font",
            &install_cmd,
            self.workspace.clone(),
        ));
    }

    /// Phase 2 install-action dispatcher. Each action spawns a Pty
    /// pane running the corresponding shell command so the user sees
    /// the install output live + can respond to sudo prompts. The
    /// wizard closes (as "Ask me later" — the flag stays false)
    /// so the Pty pane is visible; user re-opens with
    /// `first_launch.show` after install is done.
    ///
    /// Install commands verified 2026-08-11 against
    /// https://code.claude.com/docs/en/setup and
    /// https://developers.openai.com/codex. Both CLIs converged on
    /// `curl … | sh` shell installers as the recommended path;
    /// homebrew casks + npm are documented fallbacks. Windows PS
    /// arm uses `irm | iex`.
    pub fn wizard_install_ai_clis(&mut self) {
        let mut cmds: Vec<String> = Vec::new();
        let claude_missing = !crate::integration_detect::is_binary_installed("claude");
        let codex_missing = !crate::integration_detect::is_binary_installed("codex");
        let is_windows = std::env::consts::OS == "windows";
        if claude_missing {
            cmds.push(if is_windows {
                "powershell -c \"irm https://claude.ai/install.ps1 | iex\"".to_string()
            } else {
                "curl -fsSL https://claude.ai/install.sh | bash".to_string()
            });
        }
        if codex_missing {
            cmds.push(if is_windows {
                "powershell -ExecutionPolicy ByPass -c \
                 \"irm https://chatgpt.com/codex/install.ps1 | iex\""
                    .to_string()
            } else {
                "curl -fsSL https://chatgpt.com/codex/install.sh | sh".to_string()
            });
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
}
