//! Configuration. Merged from (lowest → highest precedence): built-in defaults,
//! `~/.config/mnml/config.toml`, `<workspace>/.mnml/config.toml`, then `--config PATH`.
//!
//! `[editor]`, `[ui]`, `[keys.*]`, `[tasks.*]`, `[startup]`, and `[snippets.*]`
//! are live. `[lsp.*]`, `[ai]`, `[tools]` are parsed-and-kept (so existing
//! config files keep working) but unused until their tracks land.
//!
//! `[tasks.<name>]` defines a shell command (`cmd = "..."`, optional `cwd`)
//! openable in a pty pane via the `task.run` command; `[startup] tasks = [...]`
//! lists task names auto-run in pty panes when a workspace opens.
//!
//! `[keys.*]` maps **key spec → command id**, like VSCode's `keybindings.json`
//! (the reverse direction is awkward — a key can only do one thing — and this way
//! `"ctrl+p" = "none"` cleanly unbinds a default). Sections: `[keys.global]`
//! applies always; `[keys.vim]` / `[keys.standard]` overlay it for that input
//! style. Unknown command ids are tolerated (they just never fire).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Deserialize;

#[derive(Debug, Clone)]
pub struct Config {
    pub editor: EditorConfig,
    pub ui: UiConfig,
    pub session: SessionConfig,
    /// `[cloud_run.defaults]` — what the Cloud Agents panel's
    /// quick-fire prompt input uses when you hit Enter. Populated
    /// by the wizard on submit; edited via the wizard's
    /// "change defaults" chip. Empty means "no defaults yet —
    /// route Enter to the wizard."
    pub cloud_run: CloudRunConfig,
    /// `[jira]` — org-specific Jira config. See [`JiraConfig`].
    pub jira: JiraConfig,
    /// `[cloud_agents]` — org-specific cloud-agent runner
    /// (ECS-backed). See [`CloudAgentsConfig`]. Empty by default;
    /// the cloud-agents feature is a no-op until configured.
    pub cloud_agents: CloudAgentsConfig,
    /// `[keys.<section>]` — key spec → command id. Sections: `global`, `vim`,
    /// `standard`. Resolved into an [`crate::input::keymap::Keymap`].
    pub keys: BTreeMap<String, BTreeMap<String, String>>,
    /// `[lsp.<lang>]` — raw tables, validated by the LSP track later.
    pub lsp: BTreeMap<String, toml::Value>,
    /// `[ai]` / `[tools]` — raw tables, validated by the AI track later.
    pub ai: toml::Value,
    pub tools: toml::Value,
    /// `[http]` config table. api 2nd 2026-06-28 SEV-3d added
    /// `default_env` (mnml-native equivalent of `.rqst/config`'s
    /// `default_env=…`). Other HTTP-track keys grow here later.
    pub http: HttpConfig,
    /// `[ws]` — WebSocket runtime knobs for `:ws.connect`.
    pub ws: WsConfig,
    /// `[git_graph]` — visual tuning of the git graph pane.
    pub git_graph: GitGraphConfig,
    /// `[tasks.<name>]` — named shell commands openable in a pty pane (`task.run`).
    pub tasks: BTreeMap<String, TaskDef>,
    /// `[startup] tasks = [...]` — task names auto-run in pty panes on workspace open.
    pub startup_tasks: Vec<String>,
    /// `[startup] default_workspace = "<path>"` — folder mnml opens when
    /// launched with no positional workspace arg. Falls back to
    /// `current_dir()` when unset. `~` is expanded. The folder is
    /// scaffolded (mkdir + a starter README) on first open if missing
    /// so the user gets a usable scratch/test workspace out of the box.
    pub default_workspace: Option<PathBuf>,
    /// `[snippets.<scope>]` — `<scope>` is a file extension (`"rs"`, `"py"`, …)
    /// or the literal `"global"`. Each entry is `<trigger> = "<expansion>"`;
    /// a single `$0` in the expansion picks the cursor landing spot. Resolved
    /// + expanded by [`crate::snippets`].
    pub snippets: BTreeMap<String, BTreeMap<String, String>>,
    /// `[abbr]` — vim abbreviations. Each entry is `<trigger> = "<expansion>"`;
    /// after the trigger word is followed by whitespace / punctuation while
    /// in Insert mode, the word is replaced with the expansion. Runtime
    /// `:ab` adds; `:una` removes.
    pub abbreviations: BTreeMap<String, String>,
    /// `[formatters.<ext>] cmd = "..."` (or a list of strings tried in
    /// order). External formatter command line(s) per file extension;
    /// the buffer is piped through `$SHELL -c <cmd>`. `{file}` in the
    /// template is substituted with the workspace-relative path (so
    /// `prettier --stdin-filepath {file}` picks the right rules).
    /// Config entries override the built-in `DEFAULT_FORMATTERS` table
    /// (`prettier` for js/ts/json/css/md, `ruff format -` for py, etc).
    pub formatters: BTreeMap<String, crate::formatter::FormatterEntry>,
    /// `[linters.<ext>] cmd = "..." parser = "eslint"` — external
    /// linters per file extension. Output goes through the named parser
    /// (`eslint` / `tsc` / `ruff` / `shellcheck` / `vimgrep` fallback)
    /// into LSP-shaped diagnostics that merge with the LSP set. Config
    /// entries override the built-in `DEFAULT_LINTERS` (eslint for
    /// js/ts, ruff for py, shellcheck for sh).
    pub linters: BTreeMap<String, crate::linter::LinterEntry>,
    /// `[dap.<lang>]` — debug adapter configs. Each entry is
    /// `cmd = "..."` + optional `args = [...]` + an optional
    /// `launch.*` sub-table that's substituted (`${file}`, `${workspace}`)
    /// and passed verbatim to the adapter on `launch`. Parsed into
    /// `crate::dap::AdapterConfig` at runtime via `dap::parse_adapters`.
    pub dap: BTreeMap<String, toml::Value>,
    pub browser: BrowserConfig,
    pub playwright: PlaywrightConfig,
    pub ci: CiConfig,
    // [gitlab] config moved to mnml-forge-gitlab.
    // [azdevops] config moved to mnml-forge-azdevops.
    /// `[[workspaces]]` — additional workspaces shown as sibling sections in
    /// the file-tree rail (alongside the launched workspace at the top).
    /// Each entry is a `(name, path)` pair; `~` is expanded.
    pub workspaces: Vec<WorkspaceConfig>,
}

/// One additional workspace surfaced alongside the launched one. Lets the
/// user keep a curated set of related repo groups visible together (e.g.
/// "work" + "mnml-family" in one mnml window). Each workspace gets its own
/// `Tree` rooted at `path`, its own discovered repos, and renders as a
/// collapsible section in the rail.
/// `[cloud_run]` / `[cloud_run.defaults]` — saved defaults for
/// the Cloud Agents quick-fire flow. Lets the user skip the
/// wizard for repeat runs once they've set up an agent + env once.
#[derive(Debug, Clone, Default)]
pub struct CloudRunConfig {
    pub defaults: CloudRunDefaults,
}

/// `[jira]` — org-specific Jira wiring. `domain` builds ticket
/// URLs; `ticket_prefix` validates ticket ids in cloud-agent
/// runners. Both empty by default (feature no-op). Env
/// overrides — `MNML_JIRA_DOMAIN` / `MNML_JIRA_TICKET_PREFIX`
/// — win over the file.
#[derive(Debug, Clone, Default)]
pub struct JiraConfig {
    pub domain: String,
    pub ticket_prefix: String,
}

/// `[cloud_agents]` — pointer at an org's cloud agent runner
/// (ECS-backed). All fields empty by default → the cloud agents
/// feature is a no-op (no rail rows, no wizard entry).
///
/// Everything mirrors the pieces of AWS infra the runner shells
/// out to via the `aws` CLI. Env overrides are supported for the
/// pieces most likely to differ per-machine (`MNML_AWS_PROFILE`,
/// `MNML_CLOUD_AGENTS_REGION`).
#[derive(Debug, Clone, Default)]
pub struct CloudAgentsConfig {
    /// Human label surfaced in the wizard / UI (e.g.
    /// `"Acme runner (ECS)"`). Falls back to `"ECS runner"`.
    pub label: String,
    /// Short id used in agent-row source-tag chips
    /// (e.g. `"acme-ecs"` renders as `"☁acme-ecs"`). Falls
    /// back to `"ecs"`.
    pub short_id: String,
    /// AWS region the runner stack lives in (e.g. `"us-east-1"`).
    pub region: String,
    /// AWS account id — used to build CloudWatch console URLs.
    pub account_id: String,
    /// DynamoDB table storing run records.
    pub runs_table: String,
    /// ECS cluster name.
    pub cluster: String,
    /// ECS task definition family the trigger fires.
    pub task_definition: String,
    /// CloudFormation export naming the ECS task's security group id.
    pub sg_export_name: String,
    /// CloudWatch log group for the runner container.
    pub log_group: String,
    /// AWS profile fallback tried when the caller's default
    /// profile isn't authenticated (e.g. `"acme-dev"`).
    pub aws_profile_fallback: String,
    /// S3 bucket where the runner writes per-run artifacts. Empty
    /// → no S3-console chip rendered.
    pub s3_artifacts_bucket: String,
    /// Display fallback used when a run row has no ticket id
    /// (e.g. `"acme"`). Cosmetic. Empty → `"cloud"`.
    pub default_workspace_label: String,
}

impl CloudAgentsConfig {
    /// True when the required minimum for scanning is set —
    /// region + runs_table. When false, cloud-agents features
    /// (rail rows, wizard entry, trigger) are all no-ops.
    pub fn is_enabled(&self) -> bool {
        !self.effective_region().is_empty() && !self.runs_table.is_empty()
    }

    /// Env-then-config lookup for region. Env: `MNML_CLOUD_AGENTS_REGION`.
    pub fn effective_region(&self) -> String {
        if let Ok(v) = std::env::var("MNML_CLOUD_AGENTS_REGION")
            && !v.is_empty()
        {
            return v;
        }
        self.region.clone()
    }

    /// Env-then-config lookup for the AWS profile fallback.
    /// Env: `MNML_AWS_PROFILE`.
    pub fn effective_aws_profile_fallback(&self) -> Option<String> {
        if let Ok(v) = std::env::var("MNML_AWS_PROFILE")
            && !v.is_empty()
        {
            return Some(v);
        }
        if self.aws_profile_fallback.is_empty() {
            None
        } else {
            Some(self.aws_profile_fallback.clone())
        }
    }

    pub fn effective_label(&self) -> &str {
        if self.label.is_empty() {
            "ECS runner"
        } else {
            &self.label
        }
    }

    pub fn effective_short_id(&self) -> &str {
        if self.short_id.is_empty() {
            "ecs"
        } else {
            &self.short_id
        }
    }

    pub fn effective_default_workspace_label(&self) -> &str {
        if self.default_workspace_label.is_empty() {
            "cloud"
        } else {
            &self.default_workspace_label
        }
    }
}

impl JiraConfig {
    /// Env-then-config lookup. `None` when neither is set.
    pub fn effective_domain(&self) -> Option<String> {
        if let Ok(v) = std::env::var("MNML_JIRA_DOMAIN")
            && !v.is_empty()
        {
            return Some(v);
        }
        if self.domain.is_empty() {
            None
        } else {
            Some(self.domain.clone())
        }
    }

    /// Env-then-config lookup. `None` when neither is set.
    pub fn effective_ticket_prefix(&self) -> Option<String> {
        if let Ok(v) = std::env::var("MNML_JIRA_TICKET_PREFIX")
            && !v.is_empty()
        {
            return Some(v);
        }
        if self.ticket_prefix.is_empty() {
            None
        } else {
            Some(self.ticket_prefix.clone())
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CloudRunDefaults {
    /// `agent_…` id of an already-existing managed agent. When
    /// empty the user hasn't set up defaults yet.
    pub agent_id: String,
    /// `env_…` id of the environment to use.
    pub env_id: String,
    /// `cloud` (Anthropic-managed sandbox) or `self_hosted`.
    pub sandbox: String,
    /// e.g. `claude-opus-4-8`. Not actively used (the agent
    /// carries its model), but kept so the Cloud Agents panel
    /// can show "Model: …" without an extra API lookup.
    pub model: String,
}

#[derive(Debug, Clone)]
pub struct WorkspaceConfig {
    /// Display name. Defaults to the path's basename when the config didn't
    /// supply one.
    pub name: String,
    /// Absolute path on disk. `~` is expanded at config-load time.
    pub path: PathBuf,
    /// Optional group label — drives section grouping in the
    /// workspace-picker dropdown (e.g. `"work"` / `"personal"`).
    /// `None` lands in the default ungrouped section.
    pub group: Option<String>,
}

// Bitbucket + GitHub panes + config moved out of mnml core in
// 2026-06. Live dashboards now ship in the standalone
// mnml-forge-bitbucket / mnml-forge-github binaries, hosted via
// `:term mnml-forge-bitbucket` / `:term mnml-forge-github`.
// The integration icon strip seeds rows pointing at them.

/// Long-lived branches the per-branch pipelines view defaults to
/// when a repo's `branches` field is empty.
pub fn default_branches() -> &'static [&'static str] {
    &["main", "master", "develop", "staging"]
}

// `[gitlab]` panes + config moved to mnml-forge-gitlab in 2026-06.
// `[azdevops]` panes + config moved to mnml-forge-azdevops in 2026-06.

/// `[ci]` — Continuous-integration provider settings. The original
/// consumer (the in-tree AWS CodeBuild pane) moved to mnml-aws-codebuild
/// in 2026-06; the struct stays as scaffolding so existing user configs
/// don't error on the section. Unconditional in `Config` so lean
/// builds parse it cleanly.
///
/// ```toml
/// [ci]
/// provider = "codebuild"           # only "codebuild" recognized today
/// project  = "my-playwright"       # required for codebuild
/// region   = "us-east-1"           # optional; falls back to AWS CLI defaults
/// ```
#[derive(Debug, Clone, Default)]
pub struct CiConfig {
    pub provider: Option<String>,
    pub project: Option<String>,
    pub region: Option<String>,
}

/// `[playwright]` — settings used by the Playwright integration. Reserved
/// for future expansion (currently empty after `[playwright.docdb]` moved
/// out to a private terminal integration).
#[derive(Debug, Clone, Default)]
pub struct PlaywrightConfig {}

#[derive(Debug, Clone)]
pub struct BrowserConfig {
    /// Launch Chrome with `--headless=new` (no window). The pane still
    /// receives network / console / DOM events; the user drives via `g`
    /// (navigate), `e` (eval), `s` (screenshot), etc. Default off — the
    /// visible window is what most users expect from `browser.open`.
    pub headless: bool,
    /// Auto-append every `Network.requestWillBeSent` captured by an
    /// open Browser pane to `<workspace>/.rqst/captured/log.jsonl` —
    /// same format `:http.view_captured` reads. When this is on,
    /// the rqst proxy/capture flow is transparent: you just browse,
    /// the log accumulates. Default on. Off ⇒ only explicit
    /// `:http.capture_now` writes to the log.
    pub autocapture_to_log: bool,
    /// Where Chrome's `--user-data-dir` (cookies, localStorage, login
    /// state) is stored. `"workspace"` (default) ⇒
    /// `<workspace>/.mnml/chrome-profile/` — workspace-scoped, persists
    /// across `browser.open` and across mnml relaunches in the same
    /// workspace. `"shared"` ⇒ `$HOME/.mnml/chrome-profile/` — one
    /// profile across every workspace (handy when you sign into the
    /// same services from multiple repos). `"ephemeral"` ⇒ a fresh
    /// `tempfile::tempdir()` per open — clean-slate for login testing /
    /// fresh-eyes debugging; state vanishes when the pane closes.
    pub profile_mode: String,
}

#[derive(Debug, Clone)]
pub struct TaskDef {
    /// The shell command line (run via `$SHELL -c`).
    pub cmd: String,
    /// Working directory — relative paths are resolved against the workspace; `None` ⇒ workspace.
    pub cwd: Option<String>,
}

/// `[http]` config table. api 2nd 2026-06-28 SEV-3d.
#[derive(Debug, Clone, Default)]
pub struct HttpConfig {
    /// `[http] default_env = "staging"` — when unset, EnvSet::select
    /// falls through to `$MNML_ENV` and then `.rqst/config`. Empty
    /// strings ignored.
    pub default_env: Option<String>,
}

/// `[ws]` config table (2026-07-03). Runtime knobs for
/// `:ws.connect` — subprotocol negotiation, keepalive ping, and
/// auto-reconnect on drop. See
/// [`crate::websocket::WsConnectOpts`] for the runtime shape.
#[derive(Debug, Clone)]
pub struct WsConfig {
    /// `[ws] subprotocols = ["json.chat", "graphql-transport-ws"]`
    /// Sec-WebSocket-Protocol values (preference order). Empty
    /// disables negotiation.
    pub subprotocols: Vec<String>,
    /// `[ws] ping_interval_secs = 30` — send a Ping frame every N
    /// seconds. 0 disables. Default 30 keeps most NAT/LB paths
    /// warm.
    pub ping_interval_secs: u32,
    /// `[ws] reconnect_max_attempts = 3` — retry a dropped
    /// connection up to N times with 1s/2s/4s/8s/16s backoff (cap
    /// 16s). 0 disables.
    pub reconnect_max_attempts: u32,
}

impl Default for WsConfig {
    fn default() -> Self {
        Self {
            subprotocols: Vec::new(),
            ping_interval_secs: 30,
            reconnect_max_attempts: 3,
        }
    }
}

#[derive(Debug, Clone)]
pub struct GitGraphConfig {
    /// `[git_graph] lane_spacing = <0-4>` — blank rows inserted between
    /// each commit line in the graph view. 0 = tight (old default,
    /// lanes packed), 1 = one blank row (current default, more
    /// readable), 2-4 = extra breathing room. Clamped to 4.
    pub lane_spacing: u16,
}

impl Default for GitGraphConfig {
    fn default() -> Self {
        Self { lane_spacing: 1 }
    }
}

#[derive(Debug, Clone)]
pub struct EditorConfig {
    /// `"vim"` or `"standard"`. Anything else falls back to `"standard"` at handler-make time.
    pub input_style: String,
    pub tab_width: usize,
    /// Auto-save a dirty buffer this many seconds after its last edit. `0` ⇒ off.
    pub autosave_secs: u64,
    /// When true, `Buffer::save_to_disk` strips trailing whitespace from each
    /// line before writing. Off by default (a non-destructive default —
    /// trailing-ws diff noise can be useful on someone else's repo).
    pub trim_trailing_ws_on_save: bool,
    /// When true, each editor pane shows the file's workspace-relative path
    /// as a dim one-row header above its body. Especially useful with splits
    /// (you can tell which pane is which without looking at the bufferline).
    pub breadcrumb: bool,
    /// Typing `(` `[` `{` `"` `'` `` ` `` also inserts the matching close
    /// char (cursor between). Off by default — surprises users who haven't
    /// opted in. `[editor] auto_pair = true` to enable.
    pub auto_pair: bool,
    /// On Enter, carry forward the previous line's leading whitespace. On by
    /// default — most users expect this from a modern editor.
    pub auto_indent: bool,
    /// Run `textDocument/formatting` before each save. Off by default — many
    /// repos don't want their files re-formatted; you opt in per-config /
    /// per-workspace when you do. If the LSP isn't attached (or doesn't
    /// implement formatting), the save proceeds normally.
    pub format_on_save: bool,
    /// Fire `textDocument/willSaveWaitUntil` before each save and apply
    /// the server-returned `TextEdit[]` *before* the file hits disk. Off
    /// by default — most servers don't register this; the ones that do
    /// (eslint --fix, organizeImports-on-save) use it as their canonical
    /// pre-save hook. Fires *before* `format_on_save`, so an
    /// organize-imports pass and a format pass can both run in order.
    pub will_save_wait_until: bool,
    /// When true, fire `textDocument/onTypeFormatting` after each typed
    /// trigger char (`}` / `;` / `\n`) and apply the resulting edits.
    /// Off by default — can be surprising to have an LSP rewrite your
    /// half-typed code. Vim canonical name is `formatoptions`; we keep
    /// the explicit `format_on_type` for parity with `format_on_save`.
    pub format_on_type: bool,
    /// Save dirty buffers automatically when they lose focus (switching
    /// to another buffer / pane). Off by default. Useful for the "never
    /// lose work" workflow but surprising for users who use buffer-switching
    /// for "compare-then-discard" gestures.
    pub autosave_on_focus_loss: bool,
    /// Show LSP inlay hints (type / parameter chips). Default `true` —
    /// painted in dim color at the end of each line that has hints. The
    /// LSP request is fired on open + save; hints persist on the buffer
    /// until refreshed.
    pub inlay_hints: bool,
    /// Use `semanticTokens/range` for just the visible viewport (instead
    /// of `full` / `full/delta` for the whole file). Off by default — only
    /// useful for very large files where full / delta is expensive. When
    /// on, the App re-fires range on scroll (debounced by per-buffer
    /// viewport diff). Requires server support for the `range` request;
    /// servers that only support full / delta are unaffected by this flag.
    pub semantic_tokens_viewport: bool,
    /// Show LSP code lenses (`5 references` / `Run | Debug`) as dim
    /// purple end-of-line chips. Default `true`. The MVP renderer is
    /// display-only — clicks aren't yet routed back to the server.
    pub code_lens: bool,
    /// Target line width for `editor.reflow_paragraph` (vim `gqq`) — greedy
    /// word-wrap at this many chars. Default 80.
    pub text_width: usize,
    /// On save, append a `\n` to the buffer if it doesn't already end with
    /// one (POSIX text file convention). On by default — flip with
    /// `[editor] ensure_trailing_newline = false` for files that need a
    /// strictly-no-trailing-newline format.
    pub ensure_trailing_newline: bool,
    /// Whether the mouse wheel + scrollbar drag also drag the cursor along.
    /// `"auto"` (default) picks per `input_style`: vim ⇒ cursor follows the
    /// viewport (matches `Ctrl+E`/`Ctrl+Y` vim canon); standard ⇒ viewport
    /// moves independently of the cursor (matches VS Code / Sublime — the
    /// cursor can leave the viewport and the scrollbar thumb anchors
    /// position). `"always"` and `"never"` force the policy regardless of
    /// input style.
    pub wheel_moves_cursor: String,
}

#[derive(Debug, Clone)]
pub struct SessionConfig {
    /// On quit, save the open editor buffers + cursors to `.mnml/session.json`,
    /// and re-open them on the next launch in the same workspace.
    pub restore: bool,
}

#[derive(Debug, Clone)]
pub struct UiConfig {
    pub theme: String,
    /// 2026-06-20 — first Color-row consumer in Settings. Hex
    /// `RRGGBB` (no `#`) for the cmdline completion popup's
    /// border. Empty string = use theme yellow. Validated at
    /// render time: invalid → fall back to theme yellow with no
    /// toast (Settings UI shows `(invalid)`).
    pub cmdline_popup_border_color: String,
    /// Optional alternate theme name. When set, the bufferline's theme-toggle
    /// slider swaps between `theme` ↔ `theme_toggle` (NvChad convention —
    /// users configure a light+dark pair, the button is a 1-press flip).
    /// When `None`, slider click falls back to opening the full theme picker.
    pub theme_toggle: Option<String>,
    pub ascii_icons: bool,
    pub tree_width: u16,
    /// Default visibility of the right side panel on launch.
    /// Toggled at runtime via `Ctrl+Shift+B` / `:set rightpanel`; the
    /// session.json round-trip preserves the last state. design-critic
    /// Issue 10.
    pub right_panel_visible: bool,
    /// Default width of the right side panel in cells. Drag-resize
    /// at runtime sticks via session.json.
    pub right_panel_width: u16,
    /// Hybrid relative line numbers — the cursor line shows its absolute number,
    /// every other line the distance from the cursor. `:set relativenumber`.
    pub relative_line_numbers: bool,
    /// Master switch for the line-number gutter. Default `true`. When
    /// `false`, the gutter is hidden entirely and the editor expands to
    /// fill the freed columns. `:set [no]number` runtime toggle.
    pub line_numbers: bool,
    /// Paint a subtle background tint on the cursor's row (vim
    /// `:set cursorline`). Off by default — some users find it noisy.
    pub cursor_line: bool,
    /// Vim `:set scrolloff=N` — keep the cursor at least N lines from
    /// the viewport's top / bottom edge (auto-scroll). Default 0
    /// (vim canonical default; many users set it to 5–10).
    pub scrolloff: usize,
    /// Vim `:set sidescrolloff=N` — horizontal counterpart. Keep cursor
    /// at least N columns from the viewport's left / right edge.
    pub sidescrolloff: usize,
    /// Show visible markers for whitespace (`·` for space, `→` for tab) in the
    /// editor. `:set list` / `:set nolist`. Off by default.
    pub show_whitespace: bool,
    /// Paint matched `()[]{}` brackets in cycling depth colors. `:set rainbow`
    /// / `:set norainbow`. Off by default.
    pub bracket_rainbow: bool,
    /// Master switch for tree-sitter syntax highlighting. `true` (default)
    /// runs the highlighter as usual; `false` paints all editor text in
    /// the theme's foreground color. `:syntax on` / `:syntax off` toggles
    /// at runtime.
    pub syntax: bool,
    /// Show a 1-column vertical scrollbar on the right edge of each editor
    /// pane (track + proportional thumb). `:set [no]scrollbar`. On by default
    /// — costs one column of usable text width.
    pub scrollbar: bool,
    /// Paint trailing whitespace cells with a red background so they're
    /// impossible to miss. `:set [no]trailing`. Off by default — many
    /// codebases intentionally use trailing whitespace (markdown line
    /// breaks, fixtures). Pair with `[editor] trim_trailing_ws_on_save`
    /// for the full "see and strip" loop.
    pub highlight_trailing_ws: bool,
    /// Show a `HH:MM` clock chip in the statusline. Default `true`.
    /// `:set [no]clock` toggles at runtime. Local-time offset is read
    /// from `$TZ_OFFSET_HOURS` (default 0 = UTC).
    pub clock: bool,
    /// When the cursor is on an identifier (`[A-Za-z0-9_]+`), paint other
    /// occurrences of the same word in the visible viewport with a subtle
    /// background tint. Off by default — can be noisy in dense files.
    /// `:set [no]hlword` / `view.toggle_highlight_word`.
    pub highlight_word_under_cursor: bool,
    /// Auto-open the rendered-markdown preview alongside any markdown file
    /// when it's first opened (the same flow as `markdown.preview` /
    /// right-click → "Preview markdown"). Off by default — opt in via
    /// `[ui] auto_md_preview = true` for a writing-focused workflow.
    pub auto_md_preview: bool,
    /// Paint a subtle column marker (the theme's `bg2` background) at this
    /// 1-based column on every line. `0` = off (default); `80` for the
    /// classic line-length hint. Vim's `:set colorcolumn=N` / `:set cc=N`.
    /// Toggles at runtime via `view.toggle_color_column`.
    pub color_column: usize,
    /// When true, render long lines wrapped to multiple visual rows
    /// instead of clipping at the viewport's right edge. Vim's `:set wrap`
    /// / `:set nowrap` / `:set wrap!`. Char-break (no word-boundary
    /// heuristic) — the simplest correct mode. `h_scroll` is forced to
    /// 0 when wrap is on.
    pub wrap: bool,
    /// When true, paint `TODO` / `FIXME` / `HACK` / `XXX` keywords in
    /// bright red/bold across every visible line. Whole-word match. Off
    /// by default (some users find it noisy). `:set [no]todohl` /
    /// `view.toggle_todo_highlight`.
    pub highlight_todo_keywords: bool,
    /// When true, paint inline markdown decorations (heading-line bold +
    /// colored, `**bold**` rendered bold with markers dimmed, `*italic*`
    /// italic with markers dimmed, `` `code` `` with bg2 background,
    /// `[text](url)` rendered as just `text` colored as a link) IN the
    /// editor pane — render-markdown.nvim style. Off by default — the
    /// markdown preview pane (`Pane::MdPreview`) is the canonical
    /// rendering. `:set [no]rendermarkdown` / `view.toggle_render_markdown`.
    pub render_markdown: bool,
    /// Sticky scope context — when on, paints the enclosing scope chain
    /// (functions / classes / methods that contain the cursor's line) as
    /// dim header rows at the top of each editor pane. Reuses
    /// `regex_outline::extract_symbols` so it works on rust/py/js/ts/go/
    /// rb/c/cpp without an LSP. Off by default — useful in long files but
    /// noisy for short ones. `:set [no]stickycontext` / `:set stickycontext!` /
    /// `view.toggle_sticky_context`.
    pub sticky_context: bool,
    /// Number of rows reserved for inline image embeds in markdown
    /// preview (`![alt](path)`). Default 12 — picked to be unobtrusive
    /// inside paragraphs. Bump for note files with screenshots; reduce
    /// for terse docs with many small thumbnails.
    pub md_image_rows: u16,
    /// Override the auto-sized branch/tag column width in `Pane::GitGraph`.
    /// `None` ⇒ size to fit visible refs (clamped 10..=35). `Some(0)`
    /// disables the column entirely.
    pub git_graph_branch_col: Option<usize>,
    /// Override the auto-sized author column width. `None` ⇒ size to fit
    /// visible authors (clamped 8..=22). `Some(0)` disables it.
    pub git_graph_author_col: Option<usize>,
    /// Override the right-side detail panel width. `None` ⇒ 40% of pane
    /// width (clamped 30..=70). The list area gets `pane_width - detail`.
    pub git_graph_detail_col: Option<usize>,
    /// Where the fuzzy picker / command palette anchors. `"center"`
    /// (default) floats it a bit above center; `"top"` drops it flush
    /// with the top edge — the common modern quick-open convention
    /// (palette appears where your eyes reach for it, and
    /// doesn't cover the code below). Any other value falls back to
    /// `"center"`.
    pub picker_position: String,
    /// Configurable launcher-icon strip on the right side of the
    /// bufferline. Each entry renders as a 4-cell colored chip that
    /// runs `command` on click. Default has Claude Code + Codex; users
    /// can append entries via `[[ui.launcher_icon]]` in their config to
    /// add `:term <binary>` shortcuts for sibling tool integrations
    /// (database viewers, ticket viewers, etc.) or any registered
    /// command. See [`LauncherIcon`].
    pub launcher_icons: Vec<LauncherIcon>,
    /// Plain-glyph icons stacked in the rail's INTEGRATIONS section
    /// (under GIT). Each runs `command` on click; no chip background.
    /// Defaults empty — populate via `[[ui.integration_icon]]` entries
    /// for shortcuts to Jira, Bitbucket, GitHub Actions, DB viewers,
    /// etc. See [`IntegrationIcon`].
    pub integration_icons: Vec<IntegrationIcon>,
    /// Per-project ticket-key prefixes — when set, pty session tabs
    /// (Claude Code / shell / Codex / etc.) WITHOUT a user-set name get
    /// their label auto-filled from the most-recently-mentioned ticket
    /// token in the session's visible scrollback. E.g. with
    /// `["TE-", "PROJ-"]`, a Claude Code session discussing `TE-1234`
    /// shows `TE-1234` as its tab label. The user's explicit `:rename`
    /// always wins.
    ///
    /// Empty (default) disables auto-naming entirely. Format: `["PFX-"]`
    /// — the prefix as it appears in tickets (including the trailing
    /// hyphen, since the digits follow it).
    ///
    /// ```toml
    /// [ui]
    /// ticket_prefixes = ["TE-", "MIX-", "PROJ-"]
    /// ```
    pub ticket_prefixes: Vec<String>,

    /// Which source the statusline `♪` miniplayer reads from.
    /// `"mixr"` (default) — the sibling mixr DJ app
    /// (`~/.mixr/quick.txt`). No permission prompts, cheap.
    /// `"macos"` — macOS Music / Spotify via AppleScript. First-run
    /// triggers macOS's "allow mnml to control Music" permission
    /// dialog; grant it once to enable.
    /// `"auto"` — mixr first, macOS as fallback. Same permission
    /// prompt as `"macos"` fires because we poll both.
    ///
    /// Default was `"auto"` before qa-feature 2026-07-02; changed
    /// to `"mixr"` so users who don't use mixr AND don't want
    /// macOS media integration aren't prompted for a permission
    /// they don't need.
    ///
    /// ```toml
    /// [ui]
    /// now_playing_source = "mixr"
    /// ```
    pub now_playing_source: String,
    /// Preferred default music app — what the statusline `♪` chip
    /// activates on click when nothing is currently playing. When a
    /// source IS playing, the chip activates that source's app
    /// (mixr panel for mixr, Music for Music, Spotify for Spotify)
    /// regardless of this preference. Idle chip label also follows
    /// this — `♪ mixr` / `♪ music` / `♪ spotify`. Values: `"mixr"`
    /// (default), `"music"`, `"spotify"`. Editable in `:settings`.
    ///
    /// ```toml
    /// [ui]
    /// preferred_music_app = "spotify"
    /// ```
    pub preferred_music_app: String,

    /// Directory whose immediate subdirectories are eligible
    /// project-roots — used by the startup picker as one-click
    /// rows alongside `[[workspaces]]` entries. Tilde-expanded
    /// at config load. Empty string disables the feature (the
    /// picker just shows New file / Open file / Open folder /
    /// configured workspaces as before).
    ///
    /// ```toml
    /// [ui]
    /// projects_dir = "~/Projects"
    /// ```
    pub projects_dir: String,

    /// VS Code-style menu bar (File / Edit / View / Go / Run / Term /
    /// Help) on the chrome row. Three modes:
    ///   - `"always"` (default) — words always visible; click to drop
    ///     down, Alt+F / F10 to open via keyboard.
    ///   - `"auto"` — hidden until summoned via Alt+letter, F10, or
    ///     mouse-at-top-row.
    ///   - `"hidden"` — never visible; palette-only flow stays pure.
    ///
    /// ```toml
    /// [ui]
    /// menu_bar = "always"
    /// ```
    pub menu_bar: String,

    /// Optional AI-launch button on the right end of every tab
    /// bar, immediately left of the terminal button. Click → fires
    /// the corresponding `ai.*` palette command (drops a Claude
    /// Code / Codex pane). Three values:
    ///   - `"none"` (default) — no AI button on the tab bar.
    ///   - `"claude_code"` — Claude Code launcher.
    ///   - `"codex"` — Codex launcher.
    ///
    /// ```toml
    /// [ui]
    /// tab_bar_ai_icon = "claude_code"
    /// ```
    pub tab_bar_ai_icon: String,

    /// Start the rail's `> GIT` section expanded on launch?
    /// Default `false` (collapsed) — keeps the rail compact when
    /// the user lands. Toggle in-session by clicking the section
    /// header; this pref only controls the initial state.
    ///
    /// ```toml
    /// [ui]
    /// git_section_default_expanded = false
    /// ```
    pub git_section_default_expanded: bool,

    /// Start the rail's `> INTEGRATIONS` section expanded on
    /// launch? Same shape as `git_section_default_expanded`.
    /// Default `false`.
    ///
    /// ```toml
    /// [ui]
    /// integrations_section_default_expanded = false
    /// ```
    pub integrations_section_default_expanded: bool,
}

/// One entry in the rail's INTEGRATIONS section. Same shape as
/// [`LauncherIcon`] but rendered as a plain monochrome glyph instead
/// of a colored chip — fits the muted "quick-launch row" aesthetic.
///
/// ```toml
/// [[ui.integration_icon]]
/// id       = "jira"
/// glyph    = "\U000F0411"            # nf-md-jira (TOML 8-digit form)
/// fallback = "J"
/// command  = ":term jira-viewer"
/// color    = "blue"
/// tooltip  = "Open Jira board"
/// ```
///
/// **TOML escape syntax for nerd-font codepoints**: TOML uses
/// `"\uXXXX"` (4 hex digits, BMP only) or `"\UXXXXXXXX"` (8 hex
/// digits, full Unicode, zero-padded). Do NOT use Rust's
/// `"\u{XXXXX}"` brace form — TOML will reject it as `invalid
/// unicode 4-digit hex code`. Nerd-Fonts v3 codepoints land in the
/// supplemental range (U+F0000–U+F1FFF), so they almost always
/// need the 8-digit form: `nf-md-jira` = `"\U000F0411"`,
/// `nf-md-music` = `"\U000F1011"`, etc.
#[derive(Debug, Clone)]
pub struct IntegrationIcon {
    pub id: String,
    pub glyph: String,
    pub fallback: String,
    pub command: String,
    pub color: String,
    pub tooltip: Option<String>,
    /// Visibility opt-in. Default `false` — chips don't show
    /// until the user explicitly enables them (via right-click →
    /// "Enable" or the discovery overlay). Only the browser
    /// integration is enabled by default. Keeps the palette bar
    /// quiet on first run; users build up their chip strip as
    /// they actually use each integration.
    pub enabled: bool,
    /// qa-feature 2026-07-01 — opt-in to painting this
    /// integration's chip in the palette bar (next to the
    /// command palette). Default `false`. Users can right-click
    /// an integration and toggle "Show in palette bar" to enable.
    /// Browser is the only default-on integration (its `browser.open`
    /// is a common enough action to warrant top-bar real estate).
    pub in_palette_bar: bool,
    /// True for built-in defaults that a sibling's manifest is
    /// allowed to override. Set to false as soon as the user
    /// authors a matching `[[ui.integration_icon]]` entry — user
    /// intent always beats sibling-authored manifests.
    #[doc(hidden)]
    pub manifest_can_override: bool,
}

/// One entry in the bufferline's right-side launcher-icon strip.
///
/// ```toml
/// # An icon for a private terminal binary you've built locally:
/// [[ui.launcher_icon]]
/// id       = "myapp"
/// glyph    = "\U000F0668"       # nf-md-test-tube (TOML 8-digit form)
/// fallback = "MA"               # when --ascii / [ui] ascii_icons = true
/// command  = ":term myapp"  # leading `:` ⇒ ex-cmdline string
/// color    = "teal"             # theme slot name for the chip bg
/// tooltip  = "My private terminal app"
///
/// # Or fire any registered command directly (no leading `:`):
/// [[ui.launcher_icon]]
/// id       = "mixr"
/// glyph    = "\U000F1011"       # nf-md-music (TOML 8-digit form)
/// fallback = "♪"
/// command  = "mixr.show"
/// color    = "purple"
/// ```
#[derive(Debug, Clone)]
pub struct LauncherIcon {
    /// Stable identifier — used for the hover-tooltip rect key + as a
    /// debug hint. Should be unique within the strip.
    pub id: String,
    /// Nerd-Font glyph (single char, e.g. `"\u{F0E2D}"`). The 4-cell
    /// chip paints the glyph centred on a colored background.
    pub glyph: String,
    /// ASCII fallback when `[ui] ascii_icons = true` or `--ascii` is on.
    /// Typically 1-2 chars (e.g. `"CC"`).
    pub fallback: String,
    /// What to fire on click. Either a registered command id
    /// (`"ai.claude_code"`, `"mixr.show"`) or a colon-prefixed cmdline
    /// string that goes through `run_ex_command` (`":term /bin"`).
    pub command: String,
    /// Theme slot name for the chip background. Recognized: `"orange"`,
    /// `"cyan"`, `"blue"`, `"green"`, `"yellow"`, `"purple"`, `"red"`,
    /// `"teal"`, `"bg2"`. Anything else falls back to `bg2` (dark chip).
    pub color: String,
    /// Optional hover-tooltip text. When `None`, the tooltip shows
    /// the `command` string verbatim as a debug hint.
    pub tooltip: Option<String>,
    /// Visibility opt-in. Default `false` — chips don't show
    /// until the user explicitly enables them. Only the browser
    /// launcher is enabled by default.
    pub enabled: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            editor: EditorConfig {
                input_style: "standard".to_string(),
                tab_width: 4,
                autosave_secs: 0,
                trim_trailing_ws_on_save: false,
                breadcrumb: false,
                auto_pair: false,
                auto_indent: true,
                format_on_save: false,
                will_save_wait_until: false,
                format_on_type: false,
                autosave_on_focus_loss: false,
                inlay_hints: true,
                semantic_tokens_viewport: false,
                code_lens: true,
                text_width: 80,
                ensure_trailing_newline: true,
                wheel_moves_cursor: "auto".to_string(),
            },
            ui: UiConfig {
                theme: "onedark".to_string(),
                cmdline_popup_border_color: String::new(),
                theme_toggle: None,
                ascii_icons: false,
                tree_width: 30,
                right_panel_visible: false,
                right_panel_width: 32,
                relative_line_numbers: false,
                line_numbers: true,
                cursor_line: false,
                scrolloff: 0,
                sidescrolloff: 0,
                show_whitespace: false,
                syntax: true,
                bracket_rainbow: false,
                scrollbar: true,
                highlight_trailing_ws: false,
                clock: true,
                highlight_word_under_cursor: false,
                auto_md_preview: false,
                color_column: 0,
                wrap: false,
                highlight_todo_keywords: false,
                render_markdown: false,
                sticky_context: false,
                md_image_rows: 12,
                git_graph_branch_col: None,
                git_graph_author_col: None,
                git_graph_detail_col: None,
                picker_position: "center".to_string(),
                // Launcher chips on the bufferline-right are empty by
                // default now — Claude + Codex moved into INTEGRATIONS
                // (rail) below. Users can still add chips here via
                // `[[ui.launcher_icon]]`.
                launcher_icons: vec![],
                // Default INTEGRATIONS row — Claude / Codex / Bitbucket /
                // GitHub. Replace or extend via `[[ui.integration_icon]]`
                // in user config; empty array there removes the section.
                // Only Claude + Codex are mnml-patched-only glyphs (PUA
                // U+F8B0 / U+F8B1) — users on vanilla JetBrainsMono Nerd
                // Font see blank cells there, so their fallbacks evoke
                // the brand with basic Unicode. The other entries
                // (Bitbucket E703, HTTP F1D8B, Playwright F0668,
                // CodeBuild F0492, GitHub F02A4) all ship with stock
                // Nerd Fonts; their `fallback` is just `--ascii`-mode
                // text and stays the boring single-char form.
                integration_icons: vec![
                    // Browser is the ONLY integration enabled by
                    // default. Click → browser.open (launches the
                    // CDP Chrome-for-testing window mnml drives via
                    // the dev-tools protocol; browser sessions can
                    // be captured back into mnml's debugger UI).
                    // 2026-06-27 — chips now opt-in per
                    // `enabled: bool`; first-run is intentionally
                    // quiet save for this single icon.
                    IntegrationIcon {
                        id: "browser".to_string(),
                        glyph: "\u{EB01}".to_string(), // codicon-browser
                        fallback: "B".to_string(),
                        command: "browser.open".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some(
                            "Browser (CDP Chrome-for-testing; can be captured in mnml)".to_string(),
                        ),
                        enabled: true,
                        in_palette_bar: true,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "claude_code".to_string(),
                        // Branded Claude Spark glyph patched into the
                        // user's Nerd Font at U+F8B0 by
                        // `scripts/patch_nerd_font.py`. Fallback `✻` is
                        // the heavy-teardrop-spoked asterisk Claude's
                        // CLI prints while thinking — Claude-recognizable
                        // shape with no Nerd Font required.
                        glyph: "\u{F8B0}".to_string(),
                        fallback: "\u{273B}".to_string(),
                        command: "ai.claude_code".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("Claude Code".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "codex".to_string(),
                        // Branded Codex glyph (cloud + `>_`) patched at
                        // U+F8B1. Fallback `▶_` evokes a terminal cursor
                        // — the OpenAI Codex CLI brand has the same
                        // `>_` motif in its wordmark.
                        glyph: "\u{F8B1}".to_string(),
                        fallback: "\u{25B8}_".to_string(),
                        command: "ai.codex".to_string(),
                        color: "cyan".to_string(),
                        tooltip: Some("Codex".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "bitbucket".to_string(),
                        glyph: "\u{E703}".to_string(), // nf-dev-bitbucket
                        fallback: "B".to_string(),
                        // Launches the standalone mnml-forge-bitbucket
                        // viewer as a Pty pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-forge-bitbucket`).
                        command: ":term mnml-forge-bitbucket".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("Bitbucket pipelines + PRs".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "jira".to_string(),
                        glyph: "\u{F0411}".to_string(), // nf-md-jira
                        fallback: "J".to_string(),
                        // Launches the standalone mnml-tracker-jira
                        // viewer as a Pty pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-tracker-jira`)
                        // and a populated `~/.config/mnml-tracker-jira{.toml,/token}`.
                        command: ":term mnml-tracker-jira".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("Jira tracker".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "http".to_string(),
                        // `\u{F1D8}` (nf-fa-paper_plane) is in every
                        // Nerd Font variant — was using `\u{F1D8B}`
                        // (nf-md-send) which is only in newer MDI
                        // ranges and missing from some standard Nerd
                        // Font Mono builds (renders as tofu / ?).
                        glyph: "\u{F1D8}".to_string(),
                        fallback: "→".to_string(),
                        command: "http.send".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("HTTP: send active request".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        // Postman-style "new request" chip — matches
                        // the palette-bar's add-integration `+`
                        // (\u{F0415} nf-md-plus) so the two `+`-style
                        // chips read as one family at a glance.
                        id: "http_new".to_string(),
                        glyph: "\u{F0415}".to_string(),
                        fallback: "+".to_string(),
                        command: "http.new".to_string(),
                        color: "green".to_string(),
                        tooltip: Some("HTTP: new blank request".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "codebuild".to_string(),
                        glyph: "\u{F0492}".to_string(), // nf-md-hammer-wrench
                        fallback: "C".to_string(),
                        // Launches the standalone mnml-aws-codebuild
                        // viewer as a Pty pane. User must have
                        // it installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-aws-codebuild`).
                        command: ":term mnml-aws-codebuild".to_string(),
                        color: "yellow".to_string(),
                        tooltip: Some("AWS CodeBuild + logs".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "github".to_string(),
                        glyph: "\u{F02A4}".to_string(), // nf-md-github
                        fallback: "G".to_string(),
                        // Launches the standalone mnml-forge-github
                        // viewer as a Pty pane. User must have
                        // it installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-forge-github`).
                        command: ":term mnml-forge-github".to_string(),
                        color: "fg".to_string(),
                        tooltip: Some("GitHub Actions + PRs".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "azdevops".to_string(),
                        glyph: "\u{EBE8}".to_string(), // nf-cod-azure
                        fallback: "A".to_string(),
                        // Launches the standalone mnml-forge-azdevops
                        // viewer as a Pty pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-forge-azdevops`).
                        command: ":term mnml-forge-azdevops".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("Azure DevOps PRs + builds".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "gitlab".to_string(),
                        glyph: "\u{F296}".to_string(), // nf-fa-gitlab
                        fallback: "L".to_string(),
                        // Launches the standalone mnml-forge-gitlab
                        // viewer as a Pty pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-forge-gitlab`).
                        command: ":term mnml-forge-gitlab".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("GitLab MRs + Pipelines".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "s3".to_string(),
                        glyph: "\u{F0EBC}".to_string(), // nf-md-aws
                        fallback: "S3".to_string(),
                        // Launches the standalone mnml-fs-s3 viewer
                        // as a Pty pane. User must have it
                        // installed (`cargo install --git
                        // https://github.com/chris-mclennan/mnml-fs-s3`).
                        command: ":term mnml-fs-s3".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("Amazon S3 browser".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "azure_blob".to_string(),
                        glyph: "\u{F0805}".to_string(), // nf-md-microsoft_azure
                        fallback: "Az".to_string(),
                        command: ":term mnml-fs-azure-blob".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("Azure Blob Storage browser".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    // Terminal-native diagnostic tools. Open as Pty
                    // panes inside mnml's layout. The sidebar filter
                    // shows them only when the binary is on PATH
                    // (`integration_detect`).
                    IntegrationIcon {
                        id: "htop".to_string(),
                        glyph: "\u{F085A}".to_string(), // nf-md-monitor_dashboard
                        fallback: "ht".to_string(),
                        command: "tools.htop".to_string(),
                        color: "green".to_string(),
                        tooltip: Some("htop — interactive process viewer".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "iftop".to_string(),
                        glyph: "\u{F048D}".to_string(), // nf-md-network
                        fallback: "if".to_string(),
                        command: "tools.iftop".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some(
                            "iftop — interactive bandwidth monitor (needs raw-socket privs)"
                                .to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "btop".to_string(),
                        glyph: "\u{F085F}".to_string(), // nf-md-monitor_eye (resource monitor look)
                        fallback: "bt".to_string(),
                        command: "tools.btop".to_string(),
                        color: "purple".to_string(),
                        tooltip: Some(
                            "btop — resource monitor (cpu / mem / disk / net)".to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "datadog".to_string(),
                        glyph: "\u{F1A0F}".to_string(), // nf-md-dog
                        fallback: "Dd".to_string(),
                        command: ":term mnml-obs-datadog".to_string(),
                        color: "purple".to_string(),
                        tooltip: Some(
                            "Datadog — monitors + dashboards + logs + incidents".to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "buttondown".to_string(),
                        glyph: "\u{F0EB1}".to_string(), // nf-md-email_newsletter
                        fallback: "Bd".to_string(),
                        command: ":term mnml-msg-buttondown".to_string(),
                        color: "green".to_string(),
                        tooltip: Some("Buttondown — drafts + sent + subscribers".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "slack".to_string(),
                        glyph: "\u{F03EF}".to_string(), // nf-md-slack
                        fallback: "Sk".to_string(),
                        command: ":term mnml-msg-slack".to_string(),
                        color: "magenta".to_string(),
                        tooltip: Some(
                            "Slack — channels + DMs + threads + search + post".to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "teams".to_string(),
                        glyph: "\u{F0FA1}".to_string(), // nf-md-microsoft_teams
                        fallback: "Tm".to_string(),
                        command: ":term mnml-msg-teams".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some(
                            "Microsoft Teams — teams + chats + threads + post".to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "mandrill".to_string(),
                        glyph: "\u{F01EF}".to_string(), // nf-md-email_check_outline
                        fallback: "Md".to_string(),
                        command: ":term mnml-msg-mandrill".to_string(),
                        color: "red".to_string(),
                        tooltip: Some(
                            "Mandrill — transactional email messages + templates + tags"
                                .to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "gmail".to_string(),
                        glyph: "\u{F03BC}".to_string(), // nf-md-gmail
                        fallback: "Gm".to_string(),
                        command: ":term mnml-msg-gmail".to_string(),
                        color: "red".to_string(),
                        tooltip: Some(
                            "Gmail — inbox + sent + labels + search + compose".to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "gcal".to_string(),
                        glyph: "\u{F0EDE}".to_string(), // nf-md-calendar_month
                        fallback: "Ca".to_string(),
                        command: ":term mnml-msg-gcal".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some(
                            "Google Calendar — today + week + upcoming meetings + create"
                                .to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "docker".to_string(),
                        glyph: "\u{F0868}".to_string(), // nf-md-docker
                        fallback: "Dk".to_string(),
                        command: ":term mnml-virt-docker".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some(
                            "Docker — containers + images + volumes + networks".to_string(),
                        ),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "cloudflare".to_string(),
                        glyph: "\u{F0E7B}".to_string(), // nf-md-cloud_outline
                        fallback: "Cf".to_string(),
                        command: ":term mnml-cdn-cloudflare".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("Cloudflare — zones + DNS + Workers + Pages".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "cloudwatch_logs".to_string(),
                        glyph: "\u{F0E5C}".to_string(), // nf-md-text-box-search
                        fallback: "CW".to_string(),
                        command: ":term mnml-aws-cloudwatch-logs".to_string(),
                        color: "yellow".to_string(),
                        tooltip: Some("CloudWatch Logs live tail".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "amplify".to_string(),
                        glyph: "\u{F087D}".to_string(), // nf-md-rocket-launch
                        fallback: "Am".to_string(),
                        command: ":term mnml-aws-amplify".to_string(),
                        color: "purple".to_string(),
                        tooltip: Some("Amplify apps + deploys".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "dynamodb".to_string(),
                        glyph: "\u{F1C0}".to_string(), // nf-fa-database
                        fallback: "Dy".to_string(),
                        command: ":term mnml-db-dynamodb".to_string(),
                        color: "teal".to_string(),
                        tooltip: Some("DynamoDB table browser".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "lambda".to_string(),
                        glyph: "\u{F0EBF}".to_string(), // nf-md-lambda
                        fallback: "La".to_string(),
                        command: ":term mnml-aws-lambda".to_string(),
                        color: "orange".to_string(),
                        tooltip: Some("Lambda function browser".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "eventbridge".to_string(),
                        glyph: "\u{F0CE0}".to_string(), // nf-md-bus
                        fallback: "EB".to_string(),
                        command: ":term mnml-aws-eventbridge".to_string(),
                        color: "pink".to_string(),
                        tooltip: Some("EventBridge buses + rules".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "rds".to_string(),
                        // code-reviewer S3-5 — was F1C0 (same as
                        // DynamoDB). F0F12 nf-md-server reads as
                        // "managed relational service" vs DDB's
                        // generic database glyph.
                        glyph: "\u{F0F12}".to_string(),
                        fallback: "RD".to_string(),
                        command: ":term mnml-aws-rds".to_string(),
                        color: "blue".to_string(),
                        tooltip: Some("RDS database browser".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "ecs".to_string(),
                        glyph: "\u{F0F12}".to_string(), // nf-md-server
                        fallback: "EC".to_string(),
                        command: ":term mnml-aws-ecs".to_string(),
                        color: "green".to_string(),
                        tooltip: Some("ECS clusters + services".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "ecr".to_string(),
                        glyph: "\u{F03D7}".to_string(), // nf-md-archive
                        fallback: "ER".to_string(),
                        command: ":term mnml-aws-ecr".to_string(),
                        color: "purple".to_string(),
                        tooltip: Some("ECR container registry".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "cognito".to_string(),
                        glyph: "\u{F0004}".to_string(), // nf-md-account_circle
                        fallback: "Co".to_string(),
                        command: ":term mnml-aws-cognito".to_string(),
                        color: "cyan".to_string(),
                        tooltip: Some("Cognito User Pools + users".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "sqs".to_string(),
                        glyph: "\u{F09FE}".to_string(), // nf-md-mailbox_outline
                        fallback: "Sq".to_string(),
                        command: ":term mnml-aws-sqs".to_string(),
                        color: "yellow".to_string(),
                        tooltip: Some("SQS queues".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    IntegrationIcon {
                        id: "sns".to_string(),
                        glyph: "\u{F0A0F}".to_string(), // nf-md-bullhorn_outline
                        fallback: "Sn".to_string(),
                        command: ":term mnml-aws-sns".to_string(),
                        color: "yellow".to_string(),
                        tooltip: Some("SNS topics + subscriptions".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    // mixr rail chip — opens the family DJ app via
                    // `mixr.show` as a Pty pane.
                    IntegrationIcon {
                        id: "mixr".to_string(),
                        glyph: "\u{F075A}".to_string(), // nf-md-music_note
                        fallback: "♪".to_string(),
                        command: "mixr.show".to_string(),
                        color: "pink".to_string(),
                        tooltip: Some("mixr DJ".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        manifest_can_override: true,
                    },
                    // 2026-06-19 — removed a duplicate `id: "http"`
                    // entry that lived here. The earlier `IntegrationIcon`
                    // around line 654 covers HTTP already (paper-plane
                    // glyph, `http.send` command). Having both produced
                    // two visually distinct rail chips for the same
                    // command — confusing on first launch. Reported
                    // by vscode-user-mouse second hunt as SEV-3.
                ],
                ticket_prefixes: Vec::new(),
                // qa-feature 2026-07-02 — default "mixr" instead of
                // "auto". Auto polled macOS Music/Spotify via
                // osascript every 3s, which triggers the
                // "allow mnml to control Music" permission dialog for
                // every macOS user (Music.app ships bundled). Opt in
                // to macOS polling explicitly via `now_playing_source
                // = "macos"` or `= "auto"`. mixr is a cheap file
                // read — no prompt fires.
                now_playing_source: "mixr".to_string(),
                preferred_music_app: "mixr".to_string(),
                projects_dir: String::new(),
                menu_bar: "always".to_string(),
                tab_bar_ai_icon: "none".to_string(),
                git_section_default_expanded: false,
                integrations_section_default_expanded: false,
            },
            session: SessionConfig { restore: true },
            keys: BTreeMap::new(),
            lsp: BTreeMap::new(),
            ai: toml::Value::Table(Default::default()),
            tools: toml::Value::Table(Default::default()),
            http: HttpConfig::default(),
            ws: WsConfig::default(),
            git_graph: GitGraphConfig::default(),
            tasks: BTreeMap::new(),
            startup_tasks: Vec::new(),
            default_workspace: None,
            snippets: BTreeMap::new(),
            abbreviations: BTreeMap::new(),
            formatters: BTreeMap::new(),
            linters: BTreeMap::new(),
            dap: BTreeMap::new(),
            browser: BrowserConfig {
                headless: false,
                profile_mode: "workspace".to_string(),
                autocapture_to_log: true,
            },
            playwright: PlaywrightConfig::default(),
            ci: CiConfig::default(),
            workspaces: Vec::new(),
            cloud_run: CloudRunConfig::default(),
            jira: JiraConfig::default(),
            cloud_agents: CloudAgentsConfig::default(),
        }
    }
}

#[derive(Debug, Default, Deserialize)]
struct RawConfig {
    #[serde(default)]
    editor: RawEditor,
    #[serde(default)]
    ui: RawUi,
    #[serde(default)]
    keys: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    lsp: BTreeMap<String, toml::Value>,
    #[serde(default)]
    ai: Option<toml::Value>,
    #[serde(default)]
    tools: Option<toml::Value>,
    #[serde(default)]
    http: RawHttp,
    #[serde(default)]
    ws: RawWs,
    #[serde(default)]
    git_graph: RawGitGraph,
    #[serde(default)]
    tasks: BTreeMap<String, RawTask>,
    #[serde(default)]
    startup: RawStartup,
    #[serde(default)]
    session: RawSession,
    #[serde(default)]
    snippets: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    abbr: BTreeMap<String, String>,
    #[serde(default)]
    formatters: BTreeMap<String, crate::formatter::FormatterEntry>,
    #[serde(default)]
    linters: BTreeMap<String, crate::linter::LinterEntry>,
    #[serde(default)]
    dap: BTreeMap<String, toml::Value>,
    #[serde(default)]
    browser: RawBrowser,
    #[serde(default)]
    ci: RawCi,
    #[serde(default)]
    workspaces: Vec<RawWorkspace>,
    #[serde(default)]
    cloud_run: RawCloudRun,
    #[serde(default)]
    jira: RawJira,
    #[serde(default)]
    cloud_agents: RawCloudAgents,
}

#[derive(Debug, Default, Deserialize)]
struct RawWorkspace {
    name: Option<String>,
    path: String,
    /// Optional group label — drives the picker grouping
    /// (e.g. `"work"` / `"personal"`).
    #[serde(default)]
    group: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawCi {
    provider: Option<String>,
    project: Option<String>,
    region: Option<String>,
}

/// `[http]` raw table (api 2nd 2026-06-28 SEV-3d).
#[derive(Debug, Default, Deserialize)]
struct RawHttp {
    default_env: Option<String>,
}

/// `[ws]` raw table (2026-07-03).
#[derive(Debug, Default, Deserialize)]
struct RawWs {
    subprotocols: Option<Vec<String>>,
    ping_interval_secs: Option<u32>,
    reconnect_max_attempts: Option<u32>,
}

/// `[git_graph]` raw table (qa-feature 2026-06-30).
#[derive(Debug, Default, Deserialize)]
struct RawGitGraph {
    lane_spacing: Option<u16>,
}

#[derive(Debug, Default, Deserialize)]
struct RawBrowser {
    headless: Option<bool>,
    profile_mode: Option<String>,
    autocapture_to_log: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct RawSession {
    restore: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct RawTask {
    cmd: String,
    cwd: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawStartup {
    #[serde(default)]
    tasks: Vec<String>,
    #[serde(default)]
    default_workspace: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawCloudRun {
    #[serde(default)]
    defaults: RawCloudRunDefaults,
}

#[derive(Debug, Default, Deserialize)]
struct RawJira {
    #[serde(default)]
    domain: Option<String>,
    #[serde(default)]
    ticket_prefix: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawCloudAgents {
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    short_id: Option<String>,
    #[serde(default)]
    region: Option<String>,
    #[serde(default)]
    account_id: Option<String>,
    #[serde(default)]
    runs_table: Option<String>,
    #[serde(default)]
    cluster: Option<String>,
    #[serde(default)]
    task_definition: Option<String>,
    #[serde(default)]
    sg_export_name: Option<String>,
    #[serde(default)]
    log_group: Option<String>,
    #[serde(default)]
    aws_profile_fallback: Option<String>,
    #[serde(default)]
    s3_artifacts_bucket: Option<String>,
    #[serde(default)]
    default_workspace_label: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawCloudRunDefaults {
    #[serde(default)]
    agent_id: Option<String>,
    #[serde(default)]
    env_id: Option<String>,
    #[serde(default)]
    sandbox: Option<String>,
    #[serde(default)]
    model: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawEditor {
    input_style: Option<String>,
    tab_width: Option<usize>,
    autosave_secs: Option<u64>,
    trim_trailing_ws_on_save: Option<bool>,
    breadcrumb: Option<bool>,
    auto_pair: Option<bool>,
    auto_indent: Option<bool>,
    format_on_save: Option<bool>,
    will_save_wait_until: Option<bool>,
    format_on_type: Option<bool>,
    autosave_on_focus_loss: Option<bool>,
    inlay_hints: Option<bool>,
    semantic_tokens_viewport: Option<bool>,
    code_lens: Option<bool>,
    text_width: Option<usize>,
    ensure_trailing_newline: Option<bool>,
    wheel_moves_cursor: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawUi {
    theme: Option<String>,
    cmdline_popup_border_color: Option<String>,
    theme_toggle: Option<String>,
    ascii_icons: Option<bool>,
    tree_width: Option<u16>,
    right_panel_visible: Option<bool>,
    right_panel_width: Option<u16>,
    relative_line_numbers: Option<bool>,
    line_numbers: Option<bool>,
    cursor_line: Option<bool>,
    scrolloff: Option<usize>,
    sidescrolloff: Option<usize>,
    show_whitespace: Option<bool>,
    syntax: Option<bool>,
    bracket_rainbow: Option<bool>,
    scrollbar: Option<bool>,
    highlight_trailing_ws: Option<bool>,
    clock: Option<bool>,
    highlight_word_under_cursor: Option<bool>,
    auto_md_preview: Option<bool>,
    color_column: Option<usize>,
    wrap: Option<bool>,
    highlight_todo_keywords: Option<bool>,
    render_markdown: Option<bool>,
    sticky_context: Option<bool>,
    md_image_rows: Option<u16>,
    git_graph_branch_col: Option<usize>,
    git_graph_author_col: Option<usize>,
    git_graph_detail_col: Option<usize>,
    picker_position: Option<String>,
    /// Array of `[[ui.launcher_icon]]` entries. When this key is present
    /// (even as `[]`), it **replaces** the built-in Claude+Codex defaults.
    /// Users who just want to *append* can copy the defaults from
    /// `LauncherIcon` docs and add their own entries.
    #[serde(default, rename = "launcher_icon")]
    launcher_icons: Option<Vec<RawLauncherIcon>>,
    /// Array of `[[ui.integration_icon]]` entries for the rail's
    /// INTEGRATIONS section. Replaces the built-in defaults (currently
    /// empty) when present.
    #[serde(default, rename = "integration_icon")]
    integration_icons: Option<Vec<RawLauncherIcon>>,
    /// Ticket prefixes for pty-tab auto-naming. See
    /// [`UiConfig::ticket_prefixes`].
    #[serde(default)]
    ticket_prefixes: Option<Vec<String>>,
    /// Statusline miniplayer source — `"auto"` / `"mixr"` / `"macos"`.
    /// See [`UiConfig::now_playing_source`].
    #[serde(default)]
    now_playing_source: Option<String>,
    /// Preferred default music app — `"mixr"` / `"music"` / `"spotify"`.
    /// See [`UiConfig::preferred_music_app`].
    #[serde(default)]
    preferred_music_app: Option<String>,
    /// Default projects folder for the startup picker. Tilde-expanded
    /// at config load. See [`UiConfig::projects_dir`].
    #[serde(default)]
    projects_dir: Option<String>,
    /// Menu-bar mode. `"always"` / `"auto"` / `"hidden"`.
    /// See [`UiConfig::menu_bar`].
    #[serde(default)]
    menu_bar: Option<String>,
    /// Tab-bar AI icon. `"none"` / `"claude_code"` / `"codex"`.
    /// See [`UiConfig::tab_bar_ai_icon`].
    #[serde(default)]
    tab_bar_ai_icon: Option<String>,
    /// Initial expanded state for the rail's `> GIT` section.
    /// Default `false` (collapsed). See
    /// [`UiConfig::git_section_default_expanded`].
    #[serde(default)]
    git_section_default_expanded: Option<bool>,
    /// Same shape, for the `> INTEGRATIONS` section.
    #[serde(default)]
    integrations_section_default_expanded: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct RawLauncherIcon {
    id: Option<String>,
    glyph: Option<String>,
    fallback: Option<String>,
    command: Option<String>,
    color: Option<String>,
    tooltip: Option<String>,
    /// Visibility opt-in. None in raw → false in resolved config.
    enabled: Option<bool>,
    /// qa-feature 2026-07-01 — palette-bar visibility. None → false.
    in_palette_bar: Option<bool>,
}

impl Config {
    /// Load + merge. Never fails — a malformed file is reported on stderr and skipped.
    pub fn load(explicit: Option<&Path>, workspace: &Path) -> Config {
        let mut cfg = Config::default();
        if let Some(home) = home_config_path() {
            cfg.apply_file(&home);
        }
        cfg.apply_file(&workspace.join(".mnml").join("config.toml"));
        if let Some(p) = explicit {
            cfg.apply_file(p);
        }
        cfg
    }

    /// Public entry to re-apply a single config file at runtime — `:source
    /// <path>` (vim convention). Layered on top of the current config so
    /// previous values stick if the file omits a key.
    pub fn apply_file_pub(&mut self, path: &Path) {
        self.apply_file(path);
    }

    fn apply_file(&mut self, path: &Path) {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(_) => return, // absent — fine
        };
        let raw: RawConfig = match toml::from_str(&text) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("mnml: ignoring bad config {}: {e}", path.display());
                return;
            }
        };
        if let Some(v) = raw.editor.input_style {
            self.editor.input_style = v;
        }
        if let Some(v) = raw.editor.tab_width {
            self.editor.tab_width = v.max(1);
        }
        if let Some(v) = raw.editor.autosave_secs {
            self.editor.autosave_secs = v;
        }
        if let Some(v) = raw.editor.trim_trailing_ws_on_save {
            self.editor.trim_trailing_ws_on_save = v;
        }
        if let Some(v) = raw.editor.breadcrumb {
            self.editor.breadcrumb = v;
        }
        if let Some(v) = raw.editor.auto_pair {
            self.editor.auto_pair = v;
        }
        if let Some(v) = raw.editor.auto_indent {
            self.editor.auto_indent = v;
        }
        if let Some(v) = raw.editor.format_on_type {
            self.editor.format_on_type = v;
        }
        if let Some(v) = raw.editor.format_on_save {
            self.editor.format_on_save = v;
        }
        if let Some(v) = raw.editor.will_save_wait_until {
            self.editor.will_save_wait_until = v;
        }
        if let Some(v) = raw.editor.autosave_on_focus_loss {
            self.editor.autosave_on_focus_loss = v;
        }
        if let Some(v) = raw.editor.inlay_hints {
            self.editor.inlay_hints = v;
        }
        if let Some(v) = raw.editor.semantic_tokens_viewport {
            self.editor.semantic_tokens_viewport = v;
        }
        if let Some(v) = raw.editor.code_lens {
            self.editor.code_lens = v;
        }
        if let Some(v) = raw.editor.text_width {
            self.editor.text_width = v.max(8);
        }
        if let Some(v) = raw.editor.ensure_trailing_newline {
            self.editor.ensure_trailing_newline = v;
        }
        if let Some(v) = raw.editor.wheel_moves_cursor {
            // Validate at merge time so a typo doesn't silently behave
            // as "never". Unknown values fall back to "auto".
            self.editor.wheel_moves_cursor = match v.as_str() {
                "auto" | "always" | "never" => v,
                _ => "auto".to_string(),
            };
        }
        if let Some(v) = raw.ui.theme {
            self.ui.theme = v;
        }
        if let Some(v) = raw.ui.cmdline_popup_border_color {
            self.ui.cmdline_popup_border_color = v;
        }
        if let Some(v) = raw.ui.theme_toggle {
            self.ui.theme_toggle = Some(v);
        }
        if let Some(v) = raw.ui.ascii_icons {
            self.ui.ascii_icons = v;
        }
        if let Some(v) = raw.ui.tree_width {
            self.ui.tree_width = v.clamp(10, 80);
        }
        if let Some(v) = raw.ui.right_panel_visible {
            self.ui.right_panel_visible = v;
        }
        if let Some(v) = raw.ui.right_panel_width {
            self.ui.right_panel_width = v.clamp(10, 80);
        }
        if let Some(v) = raw.ui.relative_line_numbers {
            self.ui.relative_line_numbers = v;
        }
        if let Some(v) = raw.ui.line_numbers {
            self.ui.line_numbers = v;
        }
        if let Some(v) = raw.ui.cursor_line {
            self.ui.cursor_line = v;
        }
        if let Some(v) = raw.ui.scrolloff {
            self.ui.scrolloff = v;
        }
        if let Some(v) = raw.ui.sidescrolloff {
            self.ui.sidescrolloff = v;
        }
        if let Some(v) = raw.ui.show_whitespace {
            self.ui.show_whitespace = v;
        }
        if let Some(v) = raw.ui.syntax {
            self.ui.syntax = v;
        }
        if let Some(v) = raw.ui.bracket_rainbow {
            self.ui.bracket_rainbow = v;
        }
        if let Some(v) = raw.ui.scrollbar {
            self.ui.scrollbar = v;
        }
        if let Some(v) = raw.ui.highlight_trailing_ws {
            self.ui.highlight_trailing_ws = v;
        }
        if let Some(v) = raw.ui.clock {
            self.ui.clock = v;
        }
        if let Some(v) = raw.ui.highlight_word_under_cursor {
            self.ui.highlight_word_under_cursor = v;
        }
        if let Some(v) = raw.ui.auto_md_preview {
            self.ui.auto_md_preview = v;
        }
        if let Some(v) = raw.ui.color_column {
            self.ui.color_column = v;
        }
        if let Some(v) = raw.ui.wrap {
            self.ui.wrap = v;
        }
        if let Some(v) = raw.ui.highlight_todo_keywords {
            self.ui.highlight_todo_keywords = v;
        }
        if let Some(v) = raw.ui.render_markdown {
            self.ui.render_markdown = v;
        }
        if let Some(v) = raw.ui.sticky_context {
            self.ui.sticky_context = v;
        }
        if let Some(v) = raw.ui.md_image_rows {
            self.ui.md_image_rows = v.clamp(2, 100);
        }
        if raw.ui.git_graph_branch_col.is_some() {
            self.ui.git_graph_branch_col = raw.ui.git_graph_branch_col;
        }
        if raw.ui.git_graph_author_col.is_some() {
            self.ui.git_graph_author_col = raw.ui.git_graph_author_col;
        }
        if raw.ui.git_graph_detail_col.is_some() {
            self.ui.git_graph_detail_col = raw.ui.git_graph_detail_col;
        }
        if let Some(v) = raw.ui.picker_position {
            self.ui.picker_position = v;
        }
        // `[[ui.launcher_icon]]` replaces the built-in defaults entirely
        // when set — that lets users start from scratch. Empty array is
        // valid and means "no launcher icons at all."
        if let Some(raws) = raw.ui.launcher_icons {
            self.ui.launcher_icons = raws
                .into_iter()
                .filter_map(|r| {
                    let glyph = r.glyph?;
                    let command = r.command?;
                    // Generate a stable id from the command if not given.
                    let id = r.id.unwrap_or_else(|| {
                        command
                            .trim_start_matches(':')
                            .split_whitespace()
                            .next()
                            .unwrap_or("launcher")
                            .to_string()
                    });
                    Some(LauncherIcon {
                        id,
                        glyph,
                        fallback: r.fallback.unwrap_or_else(|| "*".to_string()),
                        command,
                        color: r.color.unwrap_or_else(|| "bg2".to_string()),
                        tooltip: r.tooltip,
                        enabled: r.enabled.unwrap_or(false),
                    })
                })
                .collect();
        }
        // `[[ui.integration_icon]]` — rail INTEGRATIONS section.
        // 2026-06-19 — vscode-user-mouse second hunt SEV-3: prior
        // semantics replaced the entire default vec, so a user
        // with their own `[[ui.integration_icon]]` entries was
        // missing built-in chips (e.g. the new `http_new` `+`
        // button) entirely. Now merges by `id`: user entries
        // override built-ins of the same id; built-in ids not
        // mentioned in user config stay. Order: built-ins first
        // (preserving the default rail order), then any user-only
        // entries appended at the end.
        if let Some(raws) = raw.ui.integration_icons {
            // qa-feature 2026-07-01 — merge each user raw over the
            // matching built-in FIELD-BY-FIELD so unspecified fields
            // inherit from the built-in. Prior version rebuilt each
            // user entry from scratch with hard-coded fallbacks
            // (`in_palette_bar.unwrap_or(false)`), which meant users
            // who saved their config before a new field was added
            // silently lost the built-in's default (e.g. browser's
            // `in_palette_bar = true` vanished on config reload).
            let user_raws: Vec<RawLauncherIcon> = raws;
            let id_of_raw = |r: &RawLauncherIcon| -> Option<String> {
                if let Some(id) = &r.id {
                    return Some(id.clone());
                }
                r.command.as_ref().map(|c| {
                    c.trim_start_matches(':')
                        .split_whitespace()
                        .next()
                        .unwrap_or("integration")
                        .to_string()
                })
            };
            // 1. Built-ins (in order), with matching user raws
            //    layered on top field-by-field.
            let mut merged: Vec<IntegrationIcon> = self
                .ui
                .integration_icons
                .iter()
                .map(|builtin| {
                    let user = user_raws
                        .iter()
                        .find(|r| id_of_raw(r).as_deref() == Some(builtin.id.as_str()));
                    match user {
                        None => builtin.clone(),
                        Some(r) => IntegrationIcon {
                            id: builtin.id.clone(),
                            glyph: r.glyph.clone().unwrap_or_else(|| builtin.glyph.clone()),
                            fallback: r
                                .fallback
                                .clone()
                                .unwrap_or_else(|| builtin.fallback.clone()),
                            command: r.command.clone().unwrap_or_else(|| builtin.command.clone()),
                            color: r.color.clone().unwrap_or_else(|| builtin.color.clone()),
                            tooltip: r.tooltip.clone().or_else(|| builtin.tooltip.clone()),
                            enabled: r.enabled.unwrap_or(builtin.enabled),
                            in_palette_bar: r.in_palette_bar.unwrap_or(builtin.in_palette_bar),
                            // User explicitly authored this override —
                            // no sibling manifest may overwrite it.
                            manifest_can_override: false,
                        },
                    }
                })
                .collect();
            // 2. User-only entries (no matching built-in id) —
            //    still need glyph+command to be a valid chip.
            let builtin_ids: std::collections::HashSet<String> = self
                .ui
                .integration_icons
                .iter()
                .map(|e| e.id.clone())
                .collect();
            for r in &user_raws {
                let Some(id) = id_of_raw(r) else { continue };
                if builtin_ids.contains(&id) {
                    continue;
                }
                let (Some(glyph), Some(command)) = (r.glyph.clone(), r.command.clone()) else {
                    continue;
                };
                merged.push(IntegrationIcon {
                    id,
                    glyph,
                    fallback: r.fallback.clone().unwrap_or_else(|| "*".to_string()),
                    command,
                    color: r.color.clone().unwrap_or_else(|| "fg".to_string()),
                    tooltip: r.tooltip.clone(),
                    enabled: r.enabled.unwrap_or(false),
                    in_palette_bar: r.in_palette_bar.unwrap_or(false),
                    // User-authored — sibling manifests can't override.
                    manifest_can_override: false,
                });
            }
            self.ui.integration_icons = merged;
        }
        // `ticket_prefixes` — pty-tab auto-naming from scrollback.
        // Replaces the default (empty list) when set. Blank entries are
        // stripped at load time so users don't have to worry about it.
        if let Some(raws) = raw.ui.ticket_prefixes {
            self.ui.ticket_prefixes = raws
                .into_iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
        // `now_playing_source` — `"auto"` (default) / `"mixr"` / `"macos"`.
        // Unknown values fall back to the existing setting (so a typo
        // doesn't silently switch the source).
        if let Some(s) = raw.ui.now_playing_source {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "auto" | "mixr" | "macos") {
                self.ui.now_playing_source = normalized;
            }
        }
        if let Some(s) = raw.ui.preferred_music_app {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "mixr" | "music" | "spotify") {
                self.ui.preferred_music_app = normalized;
            }
        }
        if let Some(s) = raw.ui.menu_bar {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "always" | "auto" | "hidden") {
                self.ui.menu_bar = normalized;
            }
        }
        if let Some(s) = raw.ui.tab_bar_ai_icon {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "none" | "claude_code" | "codex") {
                self.ui.tab_bar_ai_icon = normalized;
            }
        }
        if let Some(b) = raw.ui.git_section_default_expanded {
            self.ui.git_section_default_expanded = b;
        }
        if let Some(b) = raw.ui.integrations_section_default_expanded {
            self.ui.integrations_section_default_expanded = b;
        }
        if let Some(s) = raw.ui.projects_dir {
            // Tilde-expand on load so renderers can use the value
            // straight as a path. Empty / blank → disabled.
            let trimmed = s.trim();
            if trimmed.is_empty() {
                self.ui.projects_dir = String::new();
            } else if let Some(rest) = trimmed.strip_prefix("~/")
                && let Some(home) = std::env::var_os("HOME")
            {
                self.ui.projects_dir = std::path::PathBuf::from(home)
                    .join(rest)
                    .to_string_lossy()
                    .into_owned();
            } else {
                self.ui.projects_dir = trimmed.to_string();
            }
        }
        if let Some(v) = raw.session.restore {
            self.session.restore = v;
        }
        for (k, v) in raw.keys {
            self.keys.entry(k).or_default().extend(v);
        }
        for (k, v) in raw.lsp {
            self.lsp.insert(k, v);
        }
        if let Some(v) = raw.ai {
            self.ai = v;
        }
        if let Some(v) = raw.tools {
            self.tools = v;
        }
        if let Some(name) = raw.http.default_env {
            let trimmed = name.trim();
            if !trimmed.is_empty() {
                self.http.default_env = Some(trimmed.to_string());
            }
        }
        if let Some(ps) = raw.ws.subprotocols {
            self.ws.subprotocols = ps
                .into_iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
        if let Some(v) = raw.ws.ping_interval_secs {
            self.ws.ping_interval_secs = v;
        }
        if let Some(v) = raw.ws.reconnect_max_attempts {
            self.ws.reconnect_max_attempts = v;
        }
        if let Some(rs) = raw.git_graph.lane_spacing {
            self.git_graph.lane_spacing = rs.min(4);
        }
        for (k, v) in raw.tasks {
            self.tasks.insert(
                k,
                TaskDef {
                    cmd: v.cmd,
                    cwd: v.cwd,
                },
            );
        }
        self.startup_tasks.extend(raw.startup.tasks);
        if let Some(s) = raw.startup.default_workspace
            && !s.trim().is_empty()
        {
            self.default_workspace = Some(expand_tilde(&s));
        }
        for (scope, map) in raw.snippets {
            self.snippets.entry(scope).or_default().extend(map);
        }
        for (k, v) in raw.abbr {
            self.abbreviations.insert(k, v);
        }
        for (ext, entry) in raw.formatters {
            self.formatters.insert(ext, entry);
        }
        for (ext, entry) in raw.linters {
            self.linters.insert(ext, entry);
        }
        for (name, v) in raw.dap {
            self.dap.insert(name, v);
        }
        if let Some(v) = raw.browser.headless {
            self.browser.headless = v;
        }
        if let Some(v) = raw.browser.profile_mode {
            // Validate the enum; unknown values silently fall back to
            // the default ("workspace") rather than rejecting the
            // whole config file.
            self.browser.profile_mode = match v.as_str() {
                "workspace" | "shared" | "ephemeral" => v,
                _ => "workspace".to_string(),
            };
        }
        if let Some(v) = raw.browser.autocapture_to_log {
            self.browser.autocapture_to_log = v;
        }
        if let Some(v) = raw.ci.provider {
            self.ci.provider = Some(v);
        }
        if let Some(v) = raw.ci.project {
            self.ci.project = Some(v);
        }
        if let Some(v) = raw.ci.region {
            self.ci.region = Some(v);
        }
        // `[bitbucket]` section is silently ignored — Bitbucket panes
        // moved to the standalone mnml-forge-bitbucket binary in
        // 2026-06; existing user configs may still mention it.
        // `[github]` section is silently ignored — GitHub panes
        // moved to the standalone mnml-forge-github binary in
        // 2026-06; existing user configs may still mention it.
        // `[gitlab]` section is silently ignored — GitLab panes
        // moved to mnml-forge-gitlab in 2026-06.
        // `[azdevops]` section is silently ignored — Azure DevOps
        // panes moved to mnml-forge-azdevops in 2026-06.
        // `[[workspaces]]` — additional sibling workspaces. Append (rather
        // than replace) so a workspace-local file can extend the homedir
        // set. Tilde-expanded so users can write `~/Projects/foo`. Missing
        // dirs are tolerated at config-load time (App::new logs + skips
        // the unloadable ones).
        for w in raw.workspaces {
            let expanded = expand_tilde(&w.path);
            let name = w.name.unwrap_or_else(|| {
                expanded
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| w.path.clone())
            });
            self.workspaces.push(WorkspaceConfig {
                name,
                path: expanded,
                group: w.group,
            });
        }
        // Cloud Run defaults — empty strings mean "not set yet"
        // (the UI checks .is_empty() to route Enter to the
        // wizard instead of firing a quick send).
        if let Some(v) = raw.cloud_run.defaults.agent_id {
            self.cloud_run.defaults.agent_id = v;
        }
        if let Some(v) = raw.cloud_run.defaults.env_id {
            self.cloud_run.defaults.env_id = v;
        }
        if let Some(v) = raw.cloud_run.defaults.sandbox {
            self.cloud_run.defaults.sandbox = v;
        }
        if let Some(v) = raw.cloud_run.defaults.model {
            self.cloud_run.defaults.model = v;
        }
        if let Some(v) = raw.jira.domain {
            self.jira.domain = v;
        }
        if let Some(v) = raw.jira.ticket_prefix {
            self.jira.ticket_prefix = v;
        }
        if let Some(v) = raw.cloud_agents.label {
            self.cloud_agents.label = v;
        }
        if let Some(v) = raw.cloud_agents.short_id {
            self.cloud_agents.short_id = v;
        }
        if let Some(v) = raw.cloud_agents.region {
            self.cloud_agents.region = v;
        }
        if let Some(v) = raw.cloud_agents.account_id {
            self.cloud_agents.account_id = v;
        }
        if let Some(v) = raw.cloud_agents.runs_table {
            self.cloud_agents.runs_table = v;
        }
        if let Some(v) = raw.cloud_agents.cluster {
            self.cloud_agents.cluster = v;
        }
        if let Some(v) = raw.cloud_agents.task_definition {
            self.cloud_agents.task_definition = v;
        }
        if let Some(v) = raw.cloud_agents.sg_export_name {
            self.cloud_agents.sg_export_name = v;
        }
        if let Some(v) = raw.cloud_agents.log_group {
            self.cloud_agents.log_group = v;
        }
        if let Some(v) = raw.cloud_agents.aws_profile_fallback {
            self.cloud_agents.aws_profile_fallback = v;
        }
        if let Some(v) = raw.cloud_agents.s3_artifacts_bucket {
            self.cloud_agents.s3_artifacts_bucket = v;
        }
        if let Some(v) = raw.cloud_agents.default_workspace_label {
            self.cloud_agents.default_workspace_label = v;
        }
    }
}

fn expand_tilde(s: &str) -> PathBuf {
    if let Some(rest) = s.strip_prefix("~/")
        && let Some(home) = std::env::var_os("HOME")
    {
        return PathBuf::from(home).join(rest);
    }
    PathBuf::from(s)
}

/// Public counterpart of [`home_config_path`] — exposed so `file.open_settings`
/// can resolve the same path as [`Config::load`].
pub fn user_config_path() -> Option<PathBuf> {
    home_config_path()
}

/// Peek `~/.config/mnml/config.toml` for `[startup] default_workspace`
/// without doing a full `Config::load`. Used by the CLI to resolve the
/// no-positional-arg workspace BEFORE the rest of config loads (which
/// itself takes the workspace as a parameter — chicken/egg).
///
/// Returns `None` when the config file is missing, the key is unset,
/// the value is empty, or the file fails to parse. (Errors are silent
/// here because `Config::load` will surface them later; this is just
/// an early peek.)
pub fn resolve_default_workspace() -> Option<PathBuf> {
    let path = home_config_path()?;
    let text = std::fs::read_to_string(&path).ok()?;
    let raw: RawConfig = toml::from_str(&text).ok()?;
    let s = raw.startup.default_workspace?;
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    Some(expand_tilde(s))
}

/// Surgically update `[startup] default_workspace` in the user's
/// `~/.config/mnml/config.toml` so a Settings-overlay edit survives
/// restart. Replaces an existing `default_workspace = ...` line in
/// the `[startup]` table; inserts the table when it doesn't exist;
/// drops the line entirely when `path` is `None` (the "clear the
/// preference" case). All other config lines pass through unchanged.
///
/// Returns the path written on success. Errors when `$HOME` /
/// `$XDG_CONFIG_HOME` are unset, when the file can't be read /
/// written, or when the existing TOML is invalid (we won't blindly
/// overwrite a config the user might be debugging).
/// Persist Cloud Run defaults into `~/.config/mnml/config.toml`.
/// Writes the `[cloud_run.defaults]` table fresh each time — the
/// section is small (4 string keys) so a clean rewrite is simpler
/// than an in-place line-edit. Other tables pass through unchanged.
pub fn persist_cloud_run_defaults(defaults: &CloudRunDefaults) -> Result<PathBuf, String> {
    let cfg_path =
        user_config_path().ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    if let Some(parent) = cfg_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&cfg_path).unwrap_or_default();
    let updated = upsert_cloud_run_defaults(&existing, defaults);
    std::fs::write(&cfg_path, &updated)
        .map_err(|e| format!("write {}: {e}", cfg_path.display()))?;
    Ok(cfg_path)
}

/// Drop the existing `[cloud_run.defaults]` block (if any) and
/// append a fresh one. Other tables pass through unchanged. Pure
/// string work — testable without the filesystem.
fn upsert_cloud_run_defaults(src: &str, defaults: &CloudRunDefaults) -> String {
    let mut out = String::with_capacity(src.len() + 256);
    let mut in_section = false;
    for line in src.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_section = trimmed == "[cloud_run.defaults]";
            if !in_section {
                out.push_str(line);
                out.push('\n');
            }
            continue;
        }
        if !in_section {
            out.push_str(line);
            out.push('\n');
        }
    }
    if !out.ends_with("\n\n") && !out.is_empty() {
        if !out.ends_with('\n') {
            out.push('\n');
        }
        out.push('\n');
    }
    out.push_str("[cloud_run.defaults]\n");
    out.push_str(&format!("agent_id = {}\n", toml_str(&defaults.agent_id)));
    out.push_str(&format!("env_id = {}\n", toml_str(&defaults.env_id)));
    out.push_str(&format!("sandbox = {}\n", toml_str(&defaults.sandbox)));
    out.push_str(&format!("model = {}\n", toml_str(&defaults.model)));
    out
}

/// Inline TOML-escape (same shape as the one in upsert_startup_default_workspace
/// but kept local so config.rs stays self-contained).
fn toml_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn persist_default_workspace(path: Option<&Path>) -> Result<PathBuf, String> {
    let cfg_path =
        user_config_path().ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    if let Some(parent) = cfg_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&cfg_path).unwrap_or_default();
    let updated = upsert_startup_default_workspace(&existing, path);
    std::fs::write(&cfg_path, &updated)
        .map_err(|e| format!("write {}: {e}", cfg_path.display()))?;
    Ok(cfg_path)
}

/// Pure-string TOML rewrite — separated so it's testable. Walks
/// lines, tracks the current table header, and mutates / inserts /
/// removes the `default_workspace` line as appropriate. Doesn't
/// understand multi-line TOML strings; that's fine here because the
/// value is always a single-line quoted path.
fn upsert_startup_default_workspace(src: &str, path: Option<&Path>) -> String {
    let want_line = path.map(|p| {
        let mut s = String::with_capacity(p.as_os_str().len() + 24);
        s.push_str("default_workspace = ");
        // Inline the same TOML-string escaping logic discovery.rs's
        // toml_str uses — kept here so config.rs doesn't depend on
        // discovery.rs.
        s.push('"');
        for c in p.display().to_string().chars() {
            match c {
                '"' => s.push_str("\\\""),
                '\\' => s.push_str("\\\\"),
                _ => s.push(c),
            }
        }
        s.push('"');
        s
    });
    let mut out = String::with_capacity(src.len() + 64);
    let mut in_startup = false;
    let mut replaced = false;
    let mut startup_seen = false;
    for line in src.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with('[') {
            let header = trimmed.trim_end();
            // Leaving the [startup] table without having replaced
            // the line — if we have a value to write, inject it
            // immediately before this next-table header.
            if in_startup
                && !replaced
                && let Some(w) = want_line.as_ref()
            {
                out.push_str(w);
                out.push('\n');
                replaced = true;
            }
            in_startup = header == "[startup]";
            if in_startup {
                startup_seen = true;
            }
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if in_startup && trimmed.starts_with("default_workspace") {
            // Drop the existing line; we'll write our replacement
            // (if any) right here.
            if let Some(w) = want_line.as_ref() {
                out.push_str(w);
                out.push('\n');
            }
            replaced = true;
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    // Reached EOF while still in [startup] without seeing the key —
    // append the line just before EOF.
    if in_startup
        && !replaced
        && let Some(w) = want_line.as_ref()
    {
        out.push_str(w);
        out.push('\n');
    }
    // The [startup] table didn't exist anywhere — create it at the
    // end of the file. Only when we have a value to write.
    if !startup_seen && let Some(w) = want_line.as_ref() {
        if !out.ends_with('\n') {
            out.push('\n');
        }
        if !out.is_empty() && !out.ends_with("\n\n") {
            out.push('\n');
        }
        out.push_str("[startup]\n");
        out.push_str(w);
        out.push('\n');
    }
    out
}

/// Persist `[ui] projects_dir = "..."` to the user-level config at
/// `~/.config/mnml/config.toml`. Empty string ⇒ remove the line.
/// Same shape as `persist_default_workspace`. Returns the path
/// written, or an error string when the existing TOML is malformed
/// enough that we'd rather not blindly overwrite.
pub fn persist_ui_projects_dir(value: Option<&str>) -> Result<PathBuf, String> {
    let cfg_path =
        user_config_path().ok_or_else(|| "no $HOME or $XDG_CONFIG_HOME set".to_string())?;
    if let Some(parent) = cfg_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&cfg_path).unwrap_or_default();
    let updated = upsert_global_string(&existing, "ui", "projects_dir", value);
    std::fs::write(&cfg_path, &updated)
        .map_err(|e| format!("write {}: {e}", cfg_path.display()))?;
    Ok(cfg_path)
}

/// Pure-string TOML rewrite — find `[table]` / `key = "value"` and
/// update / insert / remove. `None` ⇒ remove the line. Doesn't
/// understand multi-line strings (fine for single-line quoted
/// values). Same shape as `upsert_startup_default_workspace`; a
/// future refactor could collapse the two.
fn upsert_global_string(src: &str, table: &str, key: &str, value: Option<&str>) -> String {
    let want_line = value.filter(|v| !v.is_empty()).map(|v| {
        let mut s = String::with_capacity(key.len() + v.len() + 6);
        s.push_str(key);
        s.push_str(" = ");
        s.push_str(&toml_quote(v));
        s
    });
    let header_line = format!("[{table}]");
    let key_prefix = format!("{key} ");
    let key_eq = format!("{key}=");
    let mut out = String::with_capacity(src.len() + 64);
    let mut in_table = false;
    let mut replaced = false;
    let mut table_seen = false;
    for line in src.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with('[') {
            let header = trimmed.trim_end();
            if in_table
                && !replaced
                && let Some(w) = want_line.as_ref()
            {
                out.push_str(w);
                out.push('\n');
                replaced = true;
            }
            in_table = header == header_line;
            if in_table {
                table_seen = true;
            }
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if in_table && (trimmed.starts_with(&key_prefix) || trimmed.starts_with(&key_eq)) {
            if let Some(w) = want_line.as_ref() {
                out.push_str(w);
                out.push('\n');
            }
            replaced = true;
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    if in_table
        && !replaced
        && let Some(w) = want_line.as_ref()
    {
        out.push_str(w);
        out.push('\n');
    }
    if !table_seen && let Some(w) = want_line.as_ref() {
        if !out.ends_with('\n') {
            out.push('\n');
        }
        if !out.is_empty() && !out.ends_with("\n\n") {
            out.push('\n');
        }
        out.push_str(&header_line);
        out.push('\n');
        out.push_str(w);
        out.push('\n');
    }
    out
}

/// The per-workspace config file: `<workspace>/.mnml/config.toml`. This is
/// the checked-into-the-repo overrides file — `Config::load` already reads it
/// and layers it over the global `~/.config/mnml/config.toml`. The settings
/// overlay writes here so a project's settings travel with the repo.
pub fn workspace_config_path(workspace: &Path) -> PathBuf {
    workspace.join(".mnml").join("config.toml")
}

/// Quote + escape a string as a single-line TOML basic string.
pub fn toml_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            _ => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Upsert `key = value_toml` under `[section]` in `<workspace>/.mnml/config.toml`,
/// preserving every other line (comments, whitespace, unrelated sections).
/// Creates `.mnml/` + the file + the section as needed. `value_toml` is the
/// already-formatted RHS (`true`, `42`, `"onedark"` — use [`toml_quote`] for
/// strings). Returns the path written.
///
/// This is the generalization of [`upsert_startup_default_workspace`] from the
/// single `[startup] default_workspace` field to any `[section] key`.
pub fn persist_workspace_setting(
    workspace: &Path,
    section: &str,
    key: &str,
    value_toml: &str,
) -> Result<PathBuf, String> {
    let cfg_path = workspace_config_path(workspace);
    if let Some(parent) = cfg_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&cfg_path).unwrap_or_default();
    let updated = upsert_toml_kv(&existing, section, key, value_toml);
    std::fs::write(&cfg_path, &updated)
        .map_err(|e| format!("write {}: {e}", cfg_path.display()))?;
    Ok(cfg_path)
}

/// True when `trimmed` is an assignment line for exactly `key` — i.e. it
/// starts with `key` followed (ignoring spaces) by `=`. Guards against
/// `line_numbers` matching `relative_line_numbers`, `scrolloff` matching
/// `sidescrolloff`, etc.
fn line_assigns_key(trimmed: &str, key: &str) -> bool {
    let Some(rest) = trimmed.strip_prefix(key) else {
        return false;
    };
    matches!(rest.trim_start().chars().next(), Some('='))
}

/// Pure-string TOML upsert — same line-walk strategy as
/// [`upsert_startup_default_workspace`], generalized to any `[section] key`.
/// Doesn't understand multi-line TOML values; fine here because every settings
/// value is a single-line scalar.
fn upsert_toml_kv(src: &str, section: &str, key: &str, value_toml: &str) -> String {
    let want_line = format!("{key} = {value_toml}");
    let want_header = format!("[{section}]");
    let mut out = String::with_capacity(src.len() + want_line.len() + 8);
    let mut in_section = false;
    let mut replaced = false;
    let mut section_seen = false;
    for line in src.lines() {
        let trimmed = line.trim_start();
        if trimmed.starts_with('[') {
            // Leaving the target section without replacing — inject the line
            // immediately before this next-table header.
            if in_section && !replaced {
                out.push_str(&want_line);
                out.push('\n');
                replaced = true;
            }
            in_section = trimmed.trim_end() == want_header;
            if in_section {
                section_seen = true;
            }
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if in_section && !replaced && line_assigns_key(trimmed, key) {
            // Replace the existing assignment in place.
            out.push_str(&want_line);
            out.push('\n');
            replaced = true;
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    // EOF while still in the target section without seeing the key — append.
    if in_section && !replaced {
        out.push_str(&want_line);
        out.push('\n');
        replaced = true;
    }
    // Section never existed — create it at the end.
    if !section_seen && !replaced {
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        if !out.is_empty() && !out.ends_with("\n\n") {
            out.push('\n');
        }
        out.push_str(&want_header);
        out.push('\n');
        out.push_str(&want_line);
        out.push('\n');
    }
    out
}

/// Scaffold a workspace folder + a starter `README.md` if absent.
/// Idempotent — running twice on an existing folder is a no-op. Called
/// from the CLI when `resolve_default_workspace()` returns a path that
/// doesn't exist yet, so the user gets a usable scratch workspace on
/// first launch.
///
/// Returns `Ok(())` even when the README already exists (we don't
/// overwrite user content). The only error path is `std::fs::create_dir_all`
/// failing — e.g. permission-denied on the parent. The caller logs the
/// error to stderr and falls back to `cwd`.
pub fn scaffold_workspace(path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(path)?;
    let readme = path.join("README.md");
    if !readme.exists() {
        let body = "# mnml workspace\n\
                    \n\
                    This is your default workspace — the folder mnml opens when\n\
                    launched with no positional argument. Configured under\n\
                    `[startup] default_workspace` in `~/.config/mnml/config.toml`.\n\
                    \n\
                    Use it as scratch space, a test sandbox, or a quick place to\n\
                    drop notes / `.http` files / snippets. Open siblings (S3,\n\
                    Datadog, etc.) here to verify integration behavior in a\n\
                    known-clean state.\n";
        // Best-effort — if the README already vanished between exists()
        // and write(), we shrug.
        let _ = std::fs::write(&readme, body);
    }
    Ok(())
}

/// Rewrite the `[[workspaces]]` blocks in the global config file
/// (`~/.config/mnml/config.toml`) to match `workspaces`. Strips
/// every existing `[[workspaces]]` table-array entry (incl. any
/// blank line that immediately follows the closing field block)
/// and appends fresh entries at the end of the file. Used by the
/// in-app workspace editor — the existing `upsert_toml_kv` only
/// handles `[section] key = value` shapes, not table arrays.
pub fn persist_workspaces_to_global(workspaces: &[WorkspaceConfig]) -> Result<PathBuf, String> {
    let cfg_path = home_config_path().ok_or("no HOME / XDG_CONFIG_HOME")?;
    if let Some(parent) = cfg_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let existing = std::fs::read_to_string(&cfg_path).unwrap_or_default();
    let stripped = strip_workspaces_blocks(&existing);
    let mut out = stripped.trim_end().to_string();
    out.push_str(
        "\n\n# ── Workspace picker (auto-managed by Settings → Manage workspaces…) ─────────\n",
    );
    for w in workspaces {
        out.push_str("[[workspaces]]\n");
        out.push_str(&format!("name = {}\n", toml_quote(&w.name)));
        // Re-shorten absolute paths under HOME back to `~/…` for
        // readability — the loader tilde-expands on read.
        let path_str = w.path.to_string_lossy().into_owned();
        let path_display = if let Some(home) = std::env::var_os("HOME") {
            let home = home.to_string_lossy().into_owned();
            if path_str.starts_with(&home) {
                let rest = path_str.trim_start_matches(&home).trim_start_matches('/');
                format!("~/{rest}")
            } else {
                path_str.clone()
            }
        } else {
            path_str.clone()
        };
        out.push_str(&format!("path = {}\n", toml_quote(&path_display)));
        if let Some(group) = w.group.as_ref() {
            out.push_str(&format!("group = {}\n", toml_quote(group)));
        }
        out.push('\n');
    }
    std::fs::write(&cfg_path, &out).map_err(|e| format!("write {}: {e}", cfg_path.display()))?;
    Ok(cfg_path)
}

/// Remove every `[[workspaces]]` table-array entry from `src`,
/// including the lines until the next blank line or `[`-headed
/// table. Used by `persist_workspaces_to_global` before emitting
/// a fresh block from the current state.
fn strip_workspaces_blocks(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    let mut in_ws_block = false;
    for line in src.lines() {
        let trimmed = line.trim_start();
        if trimmed == "[[workspaces]]" {
            in_ws_block = true;
            continue;
        }
        if in_ws_block {
            if trimmed.is_empty() {
                in_ws_block = false;
                continue;
            }
            if trimmed.starts_with('[') {
                in_ws_block = false;
                out.push_str(line);
                out.push('\n');
                continue;
            }
            // Inside a workspace block — drop the line.
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

fn home_config_path() -> Option<PathBuf> {
    // Respect $XDG_CONFIG_HOME, else ~/.config.
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME")
        && !xdg.is_empty()
    {
        return Some(PathBuf::from(xdg).join("mnml").join("config.toml"));
    }
    std::env::var_os("HOME").map(|h| {
        PathBuf::from(h)
            .join(".config")
            .join("mnml")
            .join("config.toml")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn upsert_kv_creates_section_when_absent() {
        let out = upsert_toml_kv("", "ui", "scrollbar", "true");
        assert!(out.contains("[ui]"));
        assert!(out.contains("scrollbar = true"));
    }

    #[test]
    fn upsert_kv_replaces_in_existing_section() {
        let src = "[ui]\nscrollbar = false\ntheme = \"onedark\"\n";
        let out = upsert_toml_kv(src, "ui", "scrollbar", "true");
        assert!(out.contains("scrollbar = true"));
        assert!(!out.contains("scrollbar = false"));
        // The unrelated key in the same section survives.
        assert!(out.contains("theme = \"onedark\""));
        // Only one scrollbar line.
        assert_eq!(out.matches("scrollbar = ").count(), 1);
    }

    #[test]
    fn upsert_kv_is_idempotent() {
        let once = upsert_toml_kv("", "editor", "tab_width", "2");
        let twice = upsert_toml_kv(&once, "editor", "tab_width", "2");
        assert_eq!(once, twice);
        assert_eq!(twice.matches("tab_width = ").count(), 1);
    }

    #[test]
    fn upsert_kv_preserves_comments_and_other_sections() {
        let src = "# my workspace config\n\
                   [editor]\n\
                   tab_width = 4  # project default\n\
                   \n\
                   [browser]\n\
                   headless = true\n";
        let out = upsert_toml_kv(src, "ui", "theme", "\"gruvbox\"");
        assert!(out.contains("# my workspace config"));
        assert!(out.contains("tab_width = 4  # project default"));
        assert!(out.contains("[browser]"));
        assert!(out.contains("headless = true"));
        assert!(out.contains("[ui]"));
        assert!(out.contains("theme = \"gruvbox\""));
    }

    #[test]
    fn upsert_kv_key_boundary_does_not_clobber_prefixed_key() {
        // Writing `line_numbers` must not touch `relative_line_numbers`.
        let src = "[ui]\nrelative_line_numbers = true\n";
        let out = upsert_toml_kv(src, "ui", "line_numbers", "false");
        assert!(out.contains("relative_line_numbers = true"));
        assert!(out.contains("line_numbers = false"));
        assert_eq!(out.matches("relative_line_numbers = ").count(), 1);
    }

    #[test]
    fn persist_workspace_setting_writes_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = persist_workspace_setting(dir.path(), "editor", "tab_width", "2").unwrap();
        assert_eq!(path, dir.path().join(".mnml").join("config.toml"));
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("[editor]"));
        assert!(body.contains("tab_width = 2"));
    }

    #[test]
    fn workspaces_config_parses_and_appends() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[[workspaces]]
name = "work"
path = "/tmp/work-stuff"

[[workspaces]]
path = "/tmp/mnml-stuff"
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert_eq!(cfg.workspaces.len(), 2);
        assert_eq!(cfg.workspaces[0].name, "work");
        assert_eq!(
            cfg.workspaces[0].path,
            std::path::PathBuf::from("/tmp/work-stuff")
        );
        // Missing `name` defaults to the path's basename.
        assert_eq!(cfg.workspaces[1].name, "mnml-stuff");

        // A second config file appends (rather than replaces).
        let cfg_path2 = dir.path().join("local.toml");
        let mut f2 = std::fs::File::create(&cfg_path2).unwrap();
        writeln!(
            f2,
            r#"
[[workspaces]]
name  = "extra"
path  = "/tmp/extra"
"#
        )
        .unwrap();
        cfg.apply_file_pub(&cfg_path2);
        assert_eq!(cfg.workspaces.len(), 3);
        assert_eq!(cfg.workspaces[2].name, "extra");
    }

    #[test]
    fn default_workspace_parses_and_expands_tilde() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        std::fs::write(&cfg_path, "[startup]\ndefault_workspace = \"~/my-mnml\"\n").unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        let expected = std::env::var_os("HOME")
            .map(|h| std::path::PathBuf::from(h).join("my-mnml"))
            .unwrap_or_else(|| std::path::PathBuf::from("my-mnml"));
        assert_eq!(cfg.default_workspace, Some(expected));
    }

    #[test]
    fn default_workspace_unset_stays_none() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        std::fs::write(&cfg_path, "[startup]\ntasks = []\n").unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert!(cfg.default_workspace.is_none());
    }

    #[test]
    fn default_workspace_empty_string_treated_as_unset() {
        // An empty value shouldn't promote to `Some("")` — that would
        // canonicalize to whatever cwd resolves and surprise the user.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        std::fs::write(&cfg_path, "[startup]\ndefault_workspace = \"   \"\n").unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert!(cfg.default_workspace.is_none());
    }

    #[test]
    fn scaffold_workspace_creates_dir_and_readme() {
        let parent = tempfile::tempdir().unwrap();
        let ws = parent.path().join("mnml-workspace");
        assert!(!ws.exists());
        scaffold_workspace(&ws).unwrap();
        assert!(ws.is_dir());
        let readme = ws.join("README.md");
        assert!(readme.is_file());
        let body = std::fs::read_to_string(&readme).unwrap();
        assert!(body.contains("mnml workspace"));
        assert!(body.contains("default_workspace"));
    }

    #[test]
    fn scaffold_workspace_is_idempotent_and_preserves_existing_readme() {
        let parent = tempfile::tempdir().unwrap();
        let ws = parent.path().join("ws");
        std::fs::create_dir_all(&ws).unwrap();
        // User-written README — must NOT be overwritten.
        std::fs::write(ws.join("README.md"), "# my notes\n").unwrap();
        scaffold_workspace(&ws).unwrap();
        let body = std::fs::read_to_string(ws.join("README.md")).unwrap();
        assert_eq!(body, "# my notes\n");
        // Running again still doesn't touch it.
        scaffold_workspace(&ws).unwrap();
        let body = std::fs::read_to_string(ws.join("README.md")).unwrap();
        assert_eq!(body, "# my notes\n");
    }

    #[test]
    fn bitbucket_section_silently_ignored() {
        // Bitbucket panes moved to mnml-forge-bitbucket — existing user
        // configs may still mention `[bitbucket]`; parser should not
        // error on the unknown section.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[bitbucket]
auth_env  = "BB_TOKEN"
poll_secs = 60

[[bitbucket.repos]]
workspace = "exampleorg"
slug      = "example-api"
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        // No assertion needed — the test passes if apply_file_pub
        // didn't panic on the unknown `[bitbucket]` section.
        let _ = cfg;
    }

    #[test]
    fn azdevops_section_silently_ignored() {
        // Azure DevOps panes moved to mnml-forge-azdevops — parser
        // should not error on `[azdevops]` sections in existing user
        // configs.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[azdevops]
auth_env   = "AZDO_TOKEN"

[[azdevops.projects]]
org     = "exampleorg"
project = "Example"
repo    = "api"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        let _ = cfg;
    }

    #[test]
    fn github_section_silently_ignored() {
        // GitHub panes moved to mnml-forge-github — parser should not
        // error on `[github]` sections in existing user configs.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[github]
auth_env  = "GH_TOKEN"
poll_secs = 45

[[github.repos]]
owner = "exampleorg"
repo  = "example-knowledge"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        // No assertion needed — passes if apply_file_pub didn't panic.
        let _ = cfg;
    }

    #[test]
    fn default_integration_icons_has_claude_codex_bitbucket_github() {
        // Claude + Codex moved from the bufferline `launcher_icons` to
        // the rail's INTEGRATIONS row (`integration_icons`) so they sit
        // alongside Bitbucket / HTTP / Playwright / CodeBuild / GitHub
        // — see commit bf5c874 for the rail reorg. Launcher icons are
        // now empty by default; integration icons carry the AI + git
        // host defaults.
        let cfg = Config::default();
        assert!(
            cfg.ui.launcher_icons.is_empty(),
            "launcher_icons (bufferline chips) default to empty now"
        );
        let ids: Vec<&str> = cfg
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.as_str())
            .collect();
        assert!(
            ids.contains(&"claude_code"),
            "integration_icons must include claude_code"
        );
        assert!(
            ids.contains(&"codex"),
            "integration_icons must include codex"
        );
        assert!(
            ids.contains(&"bitbucket"),
            "integration_icons must include bitbucket"
        );
        assert!(
            ids.contains(&"github"),
            "integration_icons must include github"
        );
        // Spot-check the Claude entry to catch glyph/color regressions.
        let claude = cfg
            .ui
            .integration_icons
            .iter()
            .find(|i| i.id == "claude_code")
            .unwrap();
        assert_eq!(claude.command, "ai.claude_code");
        assert_eq!(claude.color, "orange");
    }

    #[test]
    fn launcher_icons_config_replaces_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[[ui.launcher_icon]]
glyph    = "M"
fallback = "MA"
command  = ":term myapp"
color    = "teal"
tooltip  = "myapp browser"

[[ui.launcher_icon]]
id       = "db"
glyph    = "D"
fallback = "DB"
command  = "psql-viewer"
color    = "purple"
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        // Setting `[[ui.launcher_icon]]` replaces, not appends — built-in
        // Claude+Codex defaults are gone.
        assert_eq!(cfg.ui.launcher_icons.len(), 2);
        // First entry — id auto-derived from the command's first token
        // when omitted (`term` here, leading `:` stripped).
        assert_eq!(cfg.ui.launcher_icons[0].id, "term");
        assert_eq!(cfg.ui.launcher_icons[0].command, ":term myapp");
        assert_eq!(cfg.ui.launcher_icons[0].color, "teal");
        assert_eq!(
            cfg.ui.launcher_icons[0].tooltip.as_deref(),
            Some("myapp browser")
        );
        // Second entry — explicit id, command without leading `:`
        // (interpreted as a registered command id by the dispatcher).
        assert_eq!(cfg.ui.launcher_icons[1].id, "db");
        assert_eq!(cfg.ui.launcher_icons[1].command, "psql-viewer");
        assert!(cfg.ui.launcher_icons[1].tooltip.is_none());
    }

    #[test]
    fn launcher_icons_empty_array_clears_defaults() {
        // `launcher_icon = []` would be ambiguous in TOML; the proper
        // form is no `[[ui.launcher_icon]]` blocks at all + the key
        // set explicitly to an empty array. Verify we accept it.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        // `launcher_icon = []` under `[ui]`.
        writeln!(
            f,
            r#"
[ui]
launcher_icon = []
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert!(cfg.ui.launcher_icons.is_empty());
    }
}
