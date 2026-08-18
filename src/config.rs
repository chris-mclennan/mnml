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

/// Integration ids that were removed from mnml (either replaced by
/// split chips or deprecated entirely). Both the in-memory rail
/// retain and the on-disk manifest wipe key off this list — so a
/// stale `<id>.toml` or `[[ui.integration_icon]]` entry left over
/// from an older mnml release stops appearing after one restart.
///
/// Safety: these ids are known-retired. Every current sibling that
/// might collide (e.g. `mnml-msg-slack` writes `slack_channels` +
/// `slack_boards`; `mnml-forge-bitbucket` writes
/// `bitbucket_pipelines` + `bitbucket_prs`) uses DIFFERENT ids, and
/// the affected siblings themselves treat these as legacy/predecessor
/// ids they clean up on install. Verified 2026-08-16 against the
/// sibling install sources.
const DEAD_INTEGRATION_IDS: &[&str] = &["bitbucket", "linear", "gitlab", "cypress", "slack"];

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
    pub ci: CiConfig,
    // [gitlab] config moved to mnml-forge-gitlab.
    // [azdevops] config moved to mnml-forge-azdevops.
    /// `[[workspaces]]` — additional workspaces shown as integration sections in
    /// the file-tree rail (alongside the launched workspace at the top).
    /// Each entry is a `(name, path)` pair; `~` is expanded.
    pub workspaces: Vec<WorkspaceConfig>,
    /// `[marketplace]` — federated app + launcher discovery. See
    /// [`MarketplaceConfig`]. Defaults ship enabled with two sources
    /// (crates.io keyword + chris-mclennan/mnml-integrations).
    pub marketplace: MarketplaceConfig,
}

/// `[marketplace]` — federated app + launcher discovery config.
#[derive(Debug, Clone)]
pub struct MarketplaceConfig {
    /// Master switch. `false` disables all fetches — Marketplace tab
    /// stays empty. Default: `true`.
    pub enabled: bool,
    /// Cache TTL in seconds. Default 3600 (1h). Set to 0 to always
    /// refetch (not recommended — hits rate limits fast).
    pub cache_ttl_secs: u64,
    /// Merge user-configured `[[marketplace.source]]` entries with
    /// the shipping defaults when true (default); replace defaults
    /// entirely when false.
    pub use_defaults: bool,
    /// User-configured additional sources.
    pub sources: Vec<crate::marketplace::Source>,
}

impl Default for MarketplaceConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            cache_ttl_secs: 3600,
            use_defaults: true,
            sources: Vec::new(),
        }
    }
}

impl MarketplaceConfig {
    /// Effective source list — the shipping defaults + user-added
    /// entries (or just user entries when `use_defaults = false`).
    pub fn effective_sources(&self) -> Vec<crate::marketplace::Source> {
        let mut out = if self.use_defaults {
            crate::marketplace::default_sources()
        } else {
            Vec::new()
        };
        out.extend(self.sources.iter().cloned());
        out
    }
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
#[derive(Debug, Clone)]
pub struct HttpConfig {
    /// `[http] default_env = "staging"` — when unset, EnvSet::select
    /// falls through to `$MNML_ENV` and then `.rqst/config`. Empty
    /// strings ignored.
    pub default_env: Option<String>,
    /// `[http] collection_root = ".mnml/collections"` (default) or
    /// `"workspace"` — where `+ New collection` / `+ New request`
    /// write. Discovery is universal (both hidden `.mnml/collections/`
    /// and workspace-root folders with ≥2 http files are surfaced),
    /// so this only picks the DEFAULT write location. 2026-07-06.
    pub collection_root: HttpCollectionRoot,
    /// `[http] auto_format_body = true` — auto-prettify JSON request
    /// bodies at key touchpoints (paste, send, load-from-file).
    /// Same effect as clicking the `{ } Format` chip, but automatic.
    /// Skips when the body doesn't parse as JSON — leaves whatever
    /// the user typed intact. Default true (matches the "always
    /// pretty" ask from 2026-07-08). Set `false` to preserve
    /// hand-crafted compact bodies exactly.
    pub auto_format_body: bool,
    /// `[http] sync_normalize = true` — when running `:http.sync` or
    /// `:http.sync_check` from the palette, apply Tier-1 dynamic-value
    /// substitution: swap ISO 8601 timestamp strings for
    /// `{{$isoTimestamp}}` and lowercase UUIDs for `{{$uuid}}`. Kills
    /// swagger-side re-generation churn on re-syncs. Off by default —
    /// opting in means committing to the template placeholders.
    /// 2026-07-09.
    pub sync_normalize: bool,
}

/// Root for new HTTP collections + scratch requests. The default
/// keeps scratches out of the code tree; users who prefer the
/// Bruno-flavor (collections checked into git alongside code) set
/// `collection_root = "workspace"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HttpCollectionRoot {
    /// `.mnml/collections/` (hidden, per-user, gitignored). Default.
    #[default]
    Hidden,
    /// The workspace root (Bruno-flavor — collections are folders
    /// in your repo, git-tracked, shared with teammates).
    Workspace,
}

impl Default for HttpConfig {
    fn default() -> Self {
        HttpConfig {
            default_env: None,
            collection_root: HttpCollectionRoot::Hidden,
            auto_format_body: true,
            sync_normalize: false,
        }
    }
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
    /// char (cursor between). On by default (2026-08-14) — matches every
    /// modern editor's default and users can turn it off in Settings or
    /// via `[editor] auto_pair = false`.
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
    /// Blink the terminal cursor. Off by default — many terminals'
    /// default cursor is already blinking, so leaving mnml's request
    /// as SteadyBar lets the terminal decide. `true` requests
    /// BlinkingBar explicitly. mouse-round-9 SEV-3 2026-07-11.
    pub cursor_blink: bool,
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
    /// #1023 (2026-08-18) — when true, mnml polls the OS's
    /// dark/light preference every ~15s and auto-swaps the active
    /// theme so a system-wide dark-mode toggle propagates without
    /// re-firing `theme.auto_system`. Set by the same command;
    /// off by default so users on split-preference setups (dark
    /// system + light editor, etc.) aren't overridden.
    pub theme_auto_system: bool,
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
    /// Task #891 — auto-hide the tree rail + right panel when the
    /// terminal is narrower than this many cells. `0` disables (the
    /// default; existing users see no behavior change). When active,
    /// panels stay hidden on narrow terminals regardless of manual
    /// `tree_visible` / `right_panel_visible` state, then reappear
    /// automatically once the window is wide enough again. Useful on
    /// laptops that dock to a wide monitor — panels tuck away when
    /// undocked, come back when docked.
    pub auto_hide_narrow_width: u16,
    /// 2026-07-25 — after every split / close, rewrite every
    /// pane's ratio so all leaves render at equal size. Matches
    /// what a Ctrl+W= press would do, applied automatically.
    /// Off by default — users on manual-drag-resize workflows
    /// don't want their carefully-sized panes snapped back to
    /// equal every time they open a new one.
    pub auto_equalize_splits: bool,
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
    /// Show the four-block stress-meter chip in the statusline
    /// (statusline-right + palette-bar mirror). Default `true`.
    /// Right-click the chip to toggle. User asked 2026-07-20:
    /// "just show it all the time" + "add right click option to
    /// hide it" + "maybe add to settings the hide/show too".
    pub stress_meter: bool,
    /// Integration ids pinned as launcher icons at the bottom of
    /// the activity bar. Clicking an icon fires that integration
    /// chip's `command` (spawns a Pty pane in the main area) —
    /// NOT a docked Mount panel. Populated by right-click →
    /// "Add to activity bar" on an integration chip.
    /// 2026-07-20 user report: "I only wanted a fucking launcher
    /// icon in the activity bar" — this field is that surface.
    pub activity_bar_pinned_integrations: Vec<String>,
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
    /// When true, paint a dim fold-arrow (`▾`) in the gutter for every
    /// foldable header line, not just on hover. Matches VS Code's
    /// "Editor › Show Folding Controls: always" default. Off by default
    /// — the sign column is 1 cell, so persistent arrows compete with
    /// git-change bars and diagnostic dots; the persistent arrow
    /// renders at LOWEST priority so higher-signal marks still win.
    /// mouse-round-8 SEV-2 2026-07-12.
    pub always_show_fold_arrows: bool,
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
    // 2026-08-01 (P2) — `launcher_icons` field deleted; the
    // bufferline launcher strip is folded into `integration_icons`.
    // Every chip in mnml is now an IntegrationIcon; the rail
    // renderer filters/paints them. One type, one source of truth.
    /// Plain-glyph icons stacked in the rail's INTEGRATIONS section
    /// (under GIT). Each runs `command` on click; no chip background.
    /// Defaults empty — populate via `[[ui.integration_icon]]` entries
    /// for shortcuts to Jira, Bitbucket, GitHub Actions, DB viewers,
    /// etc. See [`IntegrationIcon`].
    pub integration_icons: Vec<IntegrationIcon>,
    /// #864 — persisted rail order for integration chips. Simple
    /// list of ids the user has explicitly moved via right-click
    /// menu → Move up/down/to top/to bottom. `finalize` sorts
    /// `integration_icons` by this order (ids listed here first,
    /// unlisted ids appended in their arrival order — so newly-
    /// installed chips land at the end without needing an
    /// order-list update).
    ///
    /// Lives HERE instead of the per-file override sidecar because
    /// order is a rail-wide property spanning multiple integrations
    /// — a single writer + a single reader beats N sidecars all
    /// carrying a sort-order field. Kept ordering-only (no chip
    /// visuals) so the 2026-08-01 config-flip drop rule doesn't
    /// bite: this key is a Vec<String>, not `[[ui.integration_icon]]`.
    pub integration_icon_order: Vec<String>,
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
    /// `"mixr"` (default) — the integration mixr DJ app
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

    /// How diagnostics render on editor bufferline tabs:
    /// - `"count"` (default) — `✗N` errors / `⚠N` warnings; the mnml
    ///   original + neovim ecosystem convention (bufferline.nvim +
    ///   lualine both count-by-default). Loud but info-dense.
    /// - `"dot"` — colored `●` (red for errors, yellow for warnings-
    ///   only); VS Code-style. Cleaner but hides magnitude.
    /// - `"off"` — no diagnostic chip on the tab. Rely on the
    ///   editor gutter + Problems panel + statusline diag chip.
    ///
    /// Palette: `view.set_bufferline_diag_style` (opens picker).
    /// Ex-command: `:set bufferline_diag_style=dot`.
    pub bufferline_diag_style: String,

    /// Statusline coverage chip filter — controls which halves render.
    /// Values: `"feature"` (default, F only), `"code"` (Istanbul only),
    /// `"both"` (side-by-side `F NN% · C NN%` — widest), `"ticker"`
    /// (auto-cycle F ↔ C every 4s — narrow like feature/code but
    /// eventually shows both). Right-click the chip for a picker;
    /// persisted here so it survives restart. 2026-08-16 — default
    /// flipped from "both" to "feature" (user report: too wide).
    pub coverage_chip_mode: String,

    /// Task #954 — Which glyph shape to use for expandable-section
    /// indicators throughout mnml (diff hunks, DAP debug pane, DAP
    /// REPL, etc.). File tree already uses chevrons, and users want a
    /// consistent shape. Two-value discrete choice:
    /// - `"chevron"` (default) — mnml uses `>`/`v` (or the Nerd Font
    ///   glyphs U+F460/U+F47C when available).
    /// - `"triangle"` — mnml uses `▸`/`▾` (small filled triangles),
    ///   the pre-2026-08-16 default.
    /// Runtime toggle via Settings; no direct ex-command yet.
    pub expand_indicator: String,

    /// Rows the hover-help panel occupies at the bottom of the left
    /// panel. Clamped to `[3, 20]` at load time (below 3 the title +
    /// body break; above 20 crowds out the tree).
    ///
    /// Runtime: dragging the panel's top border via the mouse
    /// updates a live `App` field; the config value is persisted on
    /// drag-end. Default 8 matches the pre-resize behavior.
    pub hover_help_height: u16,

    /// Custom label for the generic terminal (bare `:term` with no
    /// binary — shell/zsh/bash/etc). Default `"terminal"` matches
    /// the profile label; set to your terminal-of-choice's name
    /// (`"ghostty"`, `"kitty"`, `"wezterm"`, `"alacritty"`) to
    /// personalize how mnml renders the chip in the CC/H/V split
    /// cluster + tab bufferline. Renders as the label text next to
    /// the terminal glyph.
    ///
    /// ```toml
    /// [ui]
    /// terminal_label = "ghostty"
    /// ```
    pub terminal_label: String,

    /// Optional custom SVG for the terminal chip glyph, overriding
    /// the default `\u{ea85}` (nf-cod-terminal). Path to an SVG on
    /// disk; baked into MnmlSymbols.ttf on startup at a reserved
    /// codepoint (U+F0AF6). Empty = use the default glyph.
    ///
    /// ```toml
    /// [ui]
    /// terminal_glyph_svg = "~/Downloads/ghostty.svg"
    /// ```
    pub terminal_glyph_svg: String,

    /// Top-right chrome cluster mode. Values:
    ///   - `"auto"` (default) — show the full cluster if it fits, drop
    ///     to compact when horizontal space is tight, hide entirely if
    ///     even compact overlaps the workspace chip.
    ///   - `"expanded"` — force the full cluster (TABS + tab-pages);
    ///     fall back only when it truly doesn't fit.
    ///   - `"compact"` — force compact (`+` + theme + `×`); useful on
    ///     narrow terminals or by preference.
    ///
    /// ```toml
    /// [ui]
    /// top_bar_cluster_mode = "expanded"
    /// ```
    pub top_bar_cluster_mode: String,

    /// Optional AI-launch button(s) on the right end of every tab
    /// bar, immediately left of the terminal button. Click → spawns
    /// a NEW Claude Code / Codex session (via `ai.claude_code_new` /
    /// `ai.codex_new` when available) and jumps focus into it — the
    /// session shows up in the Sessions activity panel. Four values:
    ///   - `"none"` — no AI button on the tab bar.
    ///   - `"claude_code"` (default 2026-07-12) — Claude Code launcher only.
    ///   - `"codex"` — Codex launcher only.
    ///   - `"both"` — Claude Code + Codex.
    ///
    /// The default was `"both"` from 2026-07-09 through 2026-07-11 and
    /// then flipped to `"claude_code"` (Codex hidden by default) so users
    /// wouldn't see two AI launchers when they've only wired up one.
    /// Right-click the AI chip → visibility submenu to switch at runtime.
    ///
    /// ```toml
    /// [ui]
    /// tab_bar_ai_icon = "claude_code"
    /// ```
    pub tab_bar_ai_icon: String,

    /// How a new Claude / Codex session lays out relative to the
    /// existing panes. Two values:
    ///   - `"grid"` (default) — the auto-tile flow (2×2 → 3×2 →
    ///     4×2 grid with placeholders). Each session gets its own
    ///     pane; up to 8 sessions before falling back to a default
    ///     split.
    ///   - `"tabs"` — new sessions ADD a tab to the active leaf
    ///     instead of splitting. The Sessions activity panel
    ///     stays the way you switch between them. Cleaner when
    ///     running many agents on a single-monitor workspace.
    ///
    /// Right-click the palette-bar AI chip to switch at runtime.
    pub ai_layout_mode: String,

    /// Prefer the mnml-owned F1E00/F1E01 AI chip glyphs (baked
    /// into `MnmlSymbols.ttf` via `integrations.bake_ai_glyphs`)
    /// over the JBM-NF-patched F8B0/F8B1 defaults. The mnml
    /// copies have a tunable `center_frac` so the vertical
    /// baseline can actually be corrected — F8B0's drift is
    /// baked into the user's Nerd Font and can't be fixed at
    /// the codepoint layer.
    ///
    /// Off by default so users see SOMETHING (F8B0/F8B1 render
    /// out-of-the-box). Turn on after running the bake + verifying
    /// the mnml chips render — right-click the AI chip → "Use
    /// mnml AI glyphs (baked)" toggle.
    pub ai_chip_use_mnml_glyphs: bool,

    /// Auto-switch the activity panel to Sessions when a Claude
    /// Code / Codex Pty pane becomes active — via tab click,
    /// sidebar chip, split-strip cluster chip, `+ New session`,
    /// right-click "New ... on right half", `:bn`/`:bp` cycling, or
    /// any other activation route. Default `true` — matches the
    /// idea that AI panes live in Sessions and the sidebar should
    /// context-follow.
    /// one-tab-type 2026-07-18.
    pub auto_show_sessions_on_ai_activate: bool,

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

    /// Ableton-style hover-help footer strip. When true, mnml
    /// reserves 1 row at the very bottom of the screen (below the
    /// cmdline) that shows a plain-English description of whatever
    /// the mouse is currently hovering over — chip, menu item, tab,
    /// tree row, etc. Zero-delay (fires as the mouse enters the
    /// chip, unlike the popup tooltip which waits 500ms). Now ON by
    /// default (Info View v0.3 Phase 1, 2026-08-10) since the panel
    /// is populated with 49 curated entries — first-run users see
    /// them immediately. Toggle at runtime via
    /// `view.toggle_hover_help` or `:set nohoverhelp`.
    pub hover_help: bool,

    /// Small delayed popup that appears NEAR THE CURSOR after
    /// `HOVER_TOOLTIP_DELAY_MS` — distinct from the bottom-left
    /// hover-help panel (`hover_help` above). Default OFF (2026-08-14)
    /// since `hover_help` now defaults ON with 49 curated entries —
    /// two chrome elements describing the same target read as noise.
    /// Users who prefer the popup enable it in Settings or via
    /// `view.toggle_hover_tooltip` / `:set hovertooltip`.
    pub hover_tooltip: bool,

    /// True once the user has finished the first-launch wizard
    /// (`first_launch.show`). Default false → wizard opens on next
    /// mnml launch. Set true when the user hits Finish OR "Skip
    /// forever". Esc = "Ask me later" leaves it false so it
    /// prompts again next start. Palette command `first_launch.show`
    /// re-opens the wizard anytime.
    pub first_launch_complete: bool,

    /// Paint the `● ` / `○ ` workspace dots (● / ○) on the left of
    /// every workspace-root row in the tree. On by default —
    /// existing users see no change. Toggle at runtime via
    /// `view.toggle_workspace_dots` or `:set wsdots` / `:set nowsdots`.
    /// Right-click on a workspace-root row also toggles this via the
    /// context menu.
    ///
    /// R6 R2 request 2026-08-09: user finds the markers "convenient
    /// but a little ugly" and prefers right-click → "Set as workspace"
    /// as the discovery path. Cleared row uses zero-cell reservation
    /// (label reclaims the two cells cleanly).
    pub show_workspace_dots: bool,

    /// Markdown preview rendering engine. Values:
    ///   - `"builtin"` (default) — mnml's own line renderer
    ///     (`ui::md_preview::render_markdown`). Read-only, scrolls,
    ///     inline images via kitty/sixel/iterm2 protocols.
    ///   - `"glow"` — pipe the source through
    ///     `glow -s auto -w <cols>` and paint the ANSI output.
    ///     Requires `glow` on PATH; falls back to builtin with a
    ///     one-shot toast if missing.
    ///   - `"custom:<cmd>"` — pipe the source through `<cmd>` on
    ///     stdin, paint the ANSI output. `<cmd>` runs via
    ///     `sh -c` so args + pipes work naturally.
    /// 2026-07-07.
    pub md_preview_engine: String,
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
    /// Short display name (~20 chars). Rendered as the chip hover,
    /// the tree row label in the Integrations panel, the picker
    /// row, and the detail-pane header. Was `tooltip` before
    /// 2026-08-01 — renamed since it renders as more than a hover
    /// on most surfaces.
    pub label: Option<String>,
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
    // 2026-08-03 — `manifest_can_override: bool` deleted. Was written
    // (defaults, user overrides, merge callers) but never READ after
    // the 2026-08-01 config-flip made every match slot overwritable
    // regardless. Reviewer confirmed zero read sites; safe removal.
    /// 2026-07-31 — detail-pane metadata. All optional; a chip
    /// with none of these renders a bare-bones detail pane (just
    /// title + Install/Enable/etc. buttons). Populated either
    /// from a `[[ui.integration_icon]]` block or merged from an
    /// installed integration's `IntegrationManifest`. See
    /// `Pane::IntegrationDetail`.
    pub description: Option<String>,
    pub homepage: Option<String>,
    pub docs: Option<String>,
    pub repository: Option<String>,
    pub author: Option<String>,
    pub version: Option<String>,
    /// Palette commands this integration registers. Informational
    /// only — the actual command wiring stays with the manifest's
    /// `[[commands]]` array + `merge_integration_manifests`. The
    /// detail pane surfaces them as a click-to-fire list.
    pub commands: Vec<IntegrationIconCommand>,
}

/// One row in `IntegrationIcon::commands`. Mirrors the useful
/// subset of `integration_manifest::CommandSpec` — enough for the
/// detail pane to show a command list.
#[derive(Debug, Clone)]
pub struct IntegrationIconCommand {
    pub id: String,
    pub title: String,
}

// LauncherIcon type + docs deleted 2026-08-01 (P2). See git history.

impl Default for Config {
    fn default() -> Self {
        Config {
            editor: EditorConfig {
                input_style: "standard".to_string(),
                tab_width: 4,
                autosave_secs: 0,
                trim_trailing_ws_on_save: false,
                // 2026-08-14 — flipped `false → true`. The breadcrumb
                // header shows the full workspace-relative path (VS
                // Code parity), especially useful with splits.
                breadcrumb: true,
                // 2026-08-14 — flipped `false → true`. Matches every
                // modern editor's default; discoverable via Settings.
                auto_pair: true,
                auto_indent: true,
                format_on_save: false,
                will_save_wait_until: false,
                format_on_type: false,
                autosave_on_focus_loss: false,
                inlay_hints: true,
                cursor_blink: false,
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
                theme_auto_system: false,
                ascii_icons: false,
                tree_width: 30,
                right_panel_visible: false,
                right_panel_width: 32,
                auto_hide_narrow_width: 0,
                auto_equalize_splits: false,
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
                stress_meter: true,
                activity_bar_pinned_integrations: Vec::new(),
                highlight_word_under_cursor: false,
                auto_md_preview: false,
                color_column: 0,
                wrap: false,
                highlight_todo_keywords: false,
                render_markdown: false,
                always_show_fold_arrows: false,
                sticky_context: false,
                md_image_rows: 12,
                git_graph_branch_col: None,
                git_graph_author_col: None,
                git_graph_detail_col: None,
                picker_position: "center".to_string(),
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
                        label: Some("Browser".to_string()),
                        enabled: true,
                        in_palette_bar: true,
                        description: None,
                        homepage: None,
                        docs: None,
                        repository: None,
                        author: None,
                        version: None,
                        commands: Vec::new(),
                    },
                    IntegrationIcon {
                        id: "claude_code".to_string(),
                        // 2026-07-19 — swapped to the mnml-owned
                        // F1E00 SVG glyph (via MnmlSymbols.ttf, baked
                        // by `integrations.bake_ai_glyphs`). Matches
                        // what the palette-bar cluster uses when
                        // `ai_chip_use_mnml_glyphs = true`.
                        // Fallback is the empirically-measured Claude
                        // idle char (U+2733) so users who haven't
                        // baked yet still see SOMETHING recognisable.
                        glyph: "\u{F1E00}".to_string(),
                        fallback: "\u{2733}".to_string(),
                        command: "ai.claude_code".to_string(),
                        // 2026-08-08 — exact Anthropic Claude brand
                        // orange (matches the fill in the shipped
                        // claude-spark SVG). Was "orange" (theme slot,
                        // varies per theme + never quite matched).
                        color: "#D16D51".to_string(),
                        label: Some("Claude Code".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        description: None,
                        homepage: None,
                        docs: None,
                        repository: None,
                        author: None,
                        version: None,
                        commands: Vec::new(),
                    },
                    IntegrationIcon {
                        id: "codex".to_string(),
                        // 2026-07-19 — swapped to F1E01 SVG glyph
                        // (same bake path as F1E00). Fallback keeps
                        // the `❯_` wordmark for unbaked users.
                        glyph: "\u{F1E01}".to_string(),
                        fallback: "\u{276F}_".to_string(),
                        command: "ai.codex".to_string(),
                        color: "cyan".to_string(),
                        label: Some("Codex".to_string()),
                        enabled: false,
                        in_palette_bar: false,
                        description: None,
                        homepage: None,
                        docs: None,
                        repository: None,
                        author: None,
                        version: None,
                        commands: Vec::new(),
                    },
                    // 2026-08-01 — stripped ~35 hardcoded IntegrationIcon
                    // defaults from mnml core. Everything except the four
                    // first-party surfaces (browser, claude_code, codex, http)
                    // now lives in integration manifests at ~/.config/mnml/integrations/
                    // (installed via <integration> --install) or in launcher entries
                    // (planned P3). mnml no longer pretends to know about a fixed
                    // set of integrations — the manifest folder is ground truth.
                ],
                integration_icon_order: Vec::new(),
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
                bufferline_diag_style: "count".to_string(),
                coverage_chip_mode: "feature".to_string(),
                expand_indicator: "chevron".to_string(),
                hover_help_height: 8,
                terminal_label: "terminal".to_string(),
                terminal_glyph_svg: String::new(),
                top_bar_cluster_mode: "auto".to_string(),
                // 2026-07-12 user request — default to Claude Code
                // only (was "both", which added Codex right next to
                // Claude). Users who want Codex too can flip
                // `[ui] tab_bar_ai_icon = "both"` in config.
                tab_bar_ai_icon: "claude_code".to_string(),
                ai_layout_mode: "grid".to_string(),
                ai_chip_use_mnml_glyphs: false,
                auto_show_sessions_on_ai_activate: true,
                git_section_default_expanded: false,
                integrations_section_default_expanded: false,
                // Info View v0.3 Phase 1 (2026-08-10) — default flipped
                // `false → true` per the design doc §Defaults. The panel
                // is now populated with 49 curated entries, so first-run
                // users see rich hover copy immediately instead of a
                // hidden feature. `view.toggle_hover_help` hides it if
                // the reader dislikes the extra chrome (persists).
                hover_help: true,
                // 2026-08-14 — flipped `true → false`. The
                // hover-help panel (above) now defaults ON with 49
                // curated entries, so the popup near the cursor is
                // redundant — two chrome elements describing the
                // same target. Users who prefer the popup enable it
                // in Settings or via `view.toggle_hover_tooltip`.
                hover_tooltip: false,
                first_launch_complete: false,
                show_workspace_dots: true,
                md_preview_engine: "builtin".to_string(),
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
            ci: CiConfig::default(),
            workspaces: Vec::new(),
            marketplace: MarketplaceConfig::default(),
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
    #[serde(default)]
    marketplace: RawMarketplace,
}

/// Raw `[marketplace]` section — parses user-authored fields with
/// per-key defaults so a partial section (e.g. just `enabled = false`)
/// still validates. See [`MarketplaceConfig`] for the runtime form.
#[derive(Debug, Default, Deserialize)]
struct RawMarketplace {
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default)]
    cache_ttl_secs: Option<u64>,
    #[serde(default)]
    use_defaults: Option<bool>,
    #[serde(default, rename = "source")]
    sources: Vec<RawMarketplaceSource>,
}

/// One `[[marketplace.source]]` entry. Sum type over the two source
/// kinds — parsed via serde's `type = "..."` tag. Missing / invalid
/// entries are silently dropped on merge; only whole-config parse
/// errors bubble up (matches how `[[workspaces]]` etc. handle bad
/// input).
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum RawMarketplaceSource {
    CratesKeyword {
        #[serde(default)]
        id: Option<String>,
        keyword: String,
    },
    GithubLauncherFolder {
        #[serde(default)]
        id: Option<String>,
        repo: String,
        path: String,
    },
    /// Enumerate each sub-directory of `<repo>/<apps_dir>` as a
    /// Rust integration crate installable via `cargo install --git`.
    /// Intended for private GitHub-org monorepos (e.g. tattle's
    /// internal integrations) — employees see them in Marketplace
    /// once they've added their org's repo to
    /// `~/.config/mnml/config.toml` as
    /// `[[marketplace.source]] type = "github_monorepo_apps"`.
    /// 2026-08-15.
    GithubMonorepoApps {
        #[serde(default)]
        id: Option<String>,
        repo: String,
        #[serde(default = "default_apps_dir")]
        apps_dir: String,
    },
}

fn default_apps_dir() -> String {
    "apps".to_string()
}

impl RawMarketplaceSource {
    fn into_source(self) -> Option<crate::marketplace::Source> {
        match self {
            RawMarketplaceSource::CratesKeyword { id, keyword } => {
                Some(crate::marketplace::Source::CratesKeyword {
                    id: id.unwrap_or_else(|| format!("crates:{keyword}")),
                    keyword,
                })
            }
            RawMarketplaceSource::GithubLauncherFolder { id, repo, path } => {
                Some(crate::marketplace::Source::GithubLauncherFolder {
                    id: id.unwrap_or_else(|| repo.clone()),
                    repo,
                    path,
                })
            }
            RawMarketplaceSource::GithubMonorepoApps { id, repo, apps_dir } => {
                // Security boundary: `repo` and `apps_dir` are user-
                // configured strings that end up as substrings in the
                // shell command that runs `cargo install --git … --path
                // …`. Drop the source silently (matching how the other
                // bad-entry paths behave) if either is outside the safe
                // charset — never let a shell-metachar reach the
                // command line. 2026-08-15.
                if !crate::marketplace::is_safe_repo_slug(&repo)
                    || !crate::marketplace::is_safe_repo_subpath(&apps_dir)
                {
                    return None;
                }
                Some(crate::marketplace::Source::GithubMonorepoApps {
                    id: id.unwrap_or_else(|| repo.clone()),
                    repo,
                    apps_dir,
                })
            }
        }
    }
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
    /// `"hidden"` (or `".mnml/collections"`) → HttpCollectionRoot::Hidden.
    /// `"workspace"` (or `"in_tree"`) → HttpCollectionRoot::Workspace.
    /// Anything else → warn + default.
    collection_root: Option<String>,
    /// See [`HttpConfig::auto_format_body`]. Default on.
    auto_format_body: Option<bool>,
    /// See [`HttpConfig::sync_normalize`]. Default off.
    sync_normalize: Option<bool>,
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
    cursor_blink: Option<bool>,
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
    theme_auto_system: Option<bool>,
    ascii_icons: Option<bool>,
    tree_width: Option<u16>,
    right_panel_visible: Option<bool>,
    right_panel_width: Option<u16>,
    auto_hide_narrow_width: Option<u16>,
    auto_equalize_splits: Option<bool>,
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
    stress_meter: Option<bool>,
    activity_bar_pinned_integrations: Option<Vec<String>>,
    highlight_word_under_cursor: Option<bool>,
    auto_md_preview: Option<bool>,
    color_column: Option<usize>,
    wrap: Option<bool>,
    highlight_todo_keywords: Option<bool>,
    render_markdown: Option<bool>,
    always_show_fold_arrows: Option<bool>,
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
    // 2026-08-01 (P2) — `launcher_icon` parse entry deleted with the
    // LauncherIcon struct retirement. All chip config uses
    // `[[ui.integration_icon]]` now.
    /// Array of `[[ui.integration_icon]]` entries for the rail's
    /// INTEGRATIONS section. Replaces the built-in defaults (currently
    /// empty) when present.
    #[serde(default, rename = "integration_icon")]
    integration_icons: Option<Vec<RawIntegrationIcon>>,
    /// User-persisted rail order. See
    /// [`UiConfig::integration_icon_order`] + the sort pass in
    /// `finalize`.
    #[serde(default)]
    integration_icon_order: Option<Vec<String>>,
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
    /// Bufferline diagnostic-chip style: `"count"` / `"dot"` / `"off"`.
    /// See [`UiConfig::bufferline_diag_style`].
    #[serde(default)]
    bufferline_diag_style: Option<String>,
    /// Statusline coverage-chip mode: `"feature"` (default) / `"code"` /
    /// `"both"` / `"ticker"`.
    #[serde(default)]
    coverage_chip_mode: Option<String>,
    /// Task #954 — Which glyph shape to use for expandable-section
    /// indicators: `"chevron"` (default) or `"triangle"`.
    #[serde(default)]
    expand_indicator: Option<String>,
    /// Height (rows) of the hover-help panel — see
    /// [`UiConfig::hover_help_height`].
    #[serde(default)]
    hover_help_height: Option<u16>,
    /// See [`UiConfig::terminal_label`].
    #[serde(default)]
    terminal_label: Option<String>,
    /// See [`UiConfig::terminal_glyph_svg`].
    #[serde(default)]
    terminal_glyph_svg: Option<String>,
    /// See [`UiConfig::top_bar_cluster_mode`].
    #[serde(default)]
    top_bar_cluster_mode: Option<String>,
    /// Tab-bar AI icon. `"none"` / `"claude_code"` / `"codex"`.
    /// See [`UiConfig::tab_bar_ai_icon`].
    #[serde(default)]
    tab_bar_ai_icon: Option<String>,
    /// See [`UiConfig::ai_layout_mode`].
    #[serde(default)]
    ai_layout_mode: Option<String>,
    /// See [`UiConfig::ai_chip_use_mnml_glyphs`].
    #[serde(default)]
    ai_chip_use_mnml_glyphs: Option<bool>,
    /// See [`UiConfig::auto_show_sessions_on_ai_activate`].
    #[serde(default)]
    auto_show_sessions_on_ai_activate: Option<bool>,
    /// Initial expanded state for the rail's `> GIT` section.
    /// Default `false` (collapsed). See
    /// [`UiConfig::git_section_default_expanded`].
    #[serde(default)]
    git_section_default_expanded: Option<bool>,
    /// Same shape, for the `> INTEGRATIONS` section.
    #[serde(default)]
    integrations_section_default_expanded: Option<bool>,
    /// See [`UiConfig::hover_help`]. Ableton-style bottom-left help
    /// strip that describes whatever the mouse is over. Off by
    /// default — palette command `view.toggle_hover_help`.
    #[serde(default)]
    hover_help: Option<bool>,
    /// See [`UiConfig::hover_tooltip`]. Small popup near the cursor
    /// after a hover-hold delay. On by default; user can disable
    /// via `view.toggle_hover_tooltip` or `:set nohovertooltip`.
    #[serde(default)]
    hover_tooltip: Option<bool>,
    /// See [`UiConfig::first_launch_complete`]. Set by the wizard
    /// on Finish; default false so a fresh install prompts.
    #[serde(default)]
    first_launch_complete: Option<bool>,
    /// See [`UiConfig::show_workspace_dots`]. Workspace-root row
    /// `● ` / `○ ` markers. On by default — palette command
    /// `view.toggle_workspace_dots` or `:set nowsdots`.
    #[serde(default)]
    show_workspace_dots: Option<bool>,
    /// See [`UiConfig::md_preview_engine`]. `"builtin"` (default)
    /// / `"glow"` / `"custom:<cmd>"`. 2026-07-07.
    #[serde(default)]
    md_preview_engine: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawIntegrationIcon {
    id: Option<String>,
    // 2026-08-01 — glyph/fallback/color/tooltip fields dropped.
    // User config is slim (id + enabled + in_palette_bar); every
    // other field reads from the built-in default or the integration
    // manifest.
    command: Option<String>,
    /// Visibility opt-in. None in raw → false in resolved config.
    enabled: Option<bool>,
    /// qa-feature 2026-07-01 — palette-bar visibility. None → false.
    in_palette_bar: Option<bool>,
}

/// One Claude account declared under `[[ai.claude.accounts]]`.
/// `token_path` is relative to `data_root()` when non-absolute
/// (matches the default `ai_token` path); `~` is expanded. When
/// no `[[ai.claude.accounts]]` block is present at all, mnml
/// synthesizes a single-account default entry (`name = "default"`,
/// `token_path = "ai_token"`, `active = true`) so pre-multi-account
/// installs see zero behavior change. Task #944, 2026-08-16.
#[derive(Debug, Clone)]
pub struct ClaudeAccountConfig {
    pub name: String,
    pub token_path: String,
    pub active: bool,
}

impl ClaudeAccountConfig {
    /// Resolve `token_path` to an absolute filesystem path — `~`
    /// expands to the resolved home dir, relative paths anchor
    /// under `data_root()` (so `token_path = "ai_token.work"`
    /// lands next to the default `ai_token`).
    pub fn resolved_token_path(&self) -> PathBuf {
        let raw = self.token_path.trim();
        if let Some(rest) = raw.strip_prefix("~/")
            && let Some(home) = std::env::var_os("HOME")
        {
            return PathBuf::from(home).join(rest);
        }
        if raw == "~"
            && let Some(home) = std::env::var_os("HOME")
        {
            return PathBuf::from(home);
        }
        let p = PathBuf::from(raw);
        if p.is_absolute() {
            p
        } else {
            crate::data_root::data_root().join(raw)
        }
    }
}

impl Config {
    /// Resolve the `[[ai.claude.accounts]]` array from `config.ai`
    /// into a normalized list. Falls back to a single synthetic
    /// entry when no block is present (`name = "default"`,
    /// `token_path = "ai_token"`, `active = true`) — the pre-#944
    /// behavior is preserved for existing installs. Task #944.
    ///
    /// Also normalizes the `active = true` invariant: exactly one
    /// account is active. If none are declared active, the first
    /// wins; if multiple are, the first-declared active-true wins
    /// and the rest are flipped false.
    pub fn claude_accounts(&self) -> Vec<ClaudeAccountConfig> {
        let mut out: Vec<ClaudeAccountConfig> = Vec::new();
        let claude = self.ai.as_table().and_then(|t| t.get("claude"));
        let arr = claude
            .and_then(|c| c.as_table())
            .and_then(|c| c.get("accounts"))
            .and_then(|a| a.as_array());
        if let Some(arr) = arr {
            for entry in arr {
                let Some(tbl) = entry.as_table() else {
                    continue;
                };
                let name = tbl
                    .get("name")
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or("default")
                    .to_string();
                let token_path = tbl
                    .get("token_path")
                    .and_then(|v| v.as_str())
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or("ai_token")
                    .to_string();
                let active = tbl.get("active").and_then(|v| v.as_bool()).unwrap_or(false);
                out.push(ClaudeAccountConfig {
                    name,
                    token_path,
                    active,
                });
            }
        }
        if out.is_empty() {
            out.push(ClaudeAccountConfig {
                name: "default".to_string(),
                token_path: "ai_token".to_string(),
                active: true,
            });
            return out;
        }
        // Normalize `active` — exactly one wins.
        let mut seen_active = false;
        for acc in out.iter_mut() {
            if acc.active && !seen_active {
                seen_active = true;
            } else if acc.active {
                acc.active = false;
            }
        }
        if !seen_active && let Some(first) = out.first_mut() {
            first.active = true;
        }
        out
    }

    /// Config-backed flag: `[ai] claude_show_all_accounts = true`
    /// swaps the statusline chip to a compact per-account
    /// rendering. Default false — the chip shows the active
    /// account only. Task #944.
    ///
    /// 2026-08-17 — accepts a STRING for tri-state (`"off"` /
    /// `"compact"` / `"ticker"`). Bool for back-compat:
    /// `true` → "compact", `false` → "off". `ticker` rotates
    /// through accounts one per 4s and renders each with the
    /// full session+weekly detail (like the single-account chip).
    /// See `ai_claude_multi_mode()` for the string form.
    pub fn ai_claude_show_all(&self) -> bool {
        !matches!(self.ai_claude_multi_mode(), ClaudeMultiMode::Off)
    }

    /// Task #944 (extended 2026-08-17) — tri-state multi-account
    /// display mode for the statusline chip. Reads `[ai]
    /// claude_show_all_accounts` as either a bool (back-compat) or
    /// a string (`"off"` / `"compact"` / `"ticker"`).
    pub fn ai_claude_multi_mode(&self) -> ClaudeMultiMode {
        let value = self
            .ai
            .as_table()
            .and_then(|t| t.get("claude_show_all_accounts"));
        match value {
            Some(v) if v.as_bool() == Some(true) => ClaudeMultiMode::Compact,
            Some(v) if v.as_bool() == Some(false) => ClaudeMultiMode::Off,
            Some(v) => match v
                .as_str()
                .unwrap_or("")
                .trim()
                .to_ascii_lowercase()
                .as_str()
            {
                "compact" => ClaudeMultiMode::Compact,
                "ticker" => ClaudeMultiMode::Ticker,
                _ => ClaudeMultiMode::Off,
            },
            None => ClaudeMultiMode::Off,
        }
    }
}

/// Task #944 — tri-state multi-account statusline chip mode.
/// - `Off`: show only the active account (single-account render).
/// - `Compact`: show every account in a compact row (`P40% · W62%
///   · C12%`); worst-tier color; can clip for 4+ accounts on
///   busy right-side clusters.
/// - `Ticker`: rotate through accounts on wall-clock (4s per
///   window), rendering each with the full session+weekly detail
///   the single-account chip uses. Trades "see all at once" for
///   "see full detail for each in turn."
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClaudeMultiMode {
    Off,
    Compact,
    Ticker,
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
        // Ghost-manifest defense — wipe on-disk manifests for retired
        // integration ids on every config load, not just when the user
        // has explicit `[[ui.integration_icon]]` entries. Most users
        // don't declare those, so gating the cleanup on their presence
        // meant the "retired" retain (line ~2201) filtered them from
        // the rail while ~/.config/mnml/integrations/<id>.toml quietly
        // persisted — surfacing as ghost `(hidden)` rows in the
        // Installed tab. User report 2026-08-16: "S Slack (hidden)"
        // reappearing. See also `DEAD_IDS` below (same list).
        //
        // Best-effort per id: `uninstall_integration` tolerates
        // NotFound + wipes any leftover pending-glyph SVG in one call.
        for id in DEAD_INTEGRATION_IDS {
            let _ = mnml_bridge::uninstall_integration(id);
        }
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
        if let Some(v) = raw.editor.cursor_blink {
            self.editor.cursor_blink = v;
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
        if let Some(v) = raw.ui.theme_auto_system {
            self.ui.theme_auto_system = v;
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
        if let Some(v) = raw.ui.auto_hide_narrow_width {
            // 0 disables; otherwise clamp so nonsensical values
            // (would hide panels at any width) don't slip in.
            self.ui.auto_hide_narrow_width = if v == 0 { 0 } else { v.clamp(40, 300) };
        }
        if let Some(v) = raw.ui.auto_equalize_splits {
            self.ui.auto_equalize_splits = v;
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
        if let Some(v) = raw.ui.stress_meter {
            self.ui.stress_meter = v;
        }
        if let Some(v) = raw.ui.activity_bar_pinned_integrations {
            self.ui.activity_bar_pinned_integrations = v;
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
        if let Some(v) = raw.ui.always_show_fold_arrows {
            self.ui.always_show_fold_arrows = v;
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
        // 2026-08-01 (P2) — `[[ui.launcher_icon]]` parse block deleted
        // with LauncherIcon retirement. Config was already merged into
        // integration_icons semantics; the launcher_icons block was
        // dormant (empty by default) and dead surface anyway.
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
            //
            // 2026-07-03 — walk the user file's array FIRST so any
            // reorder the user made via the right-click "Move up /
            // to top / down / to bottom" menu survives a restart.
            // Prior version walked built-ins in default order and
            // layered users on top, which silently reset any manual
            // reorder back to the built-in sequence.
            let user_raws: Vec<RawIntegrationIcon> = raws;
            let id_of_raw = |r: &RawIntegrationIcon| -> Option<String> {
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
            // Snapshot the built-in defaults keyed by id — we'll
            // pull from this both to inherit unspecified fields and
            // to append built-ins the user file didn't list at all.
            let builtins_by_id: std::collections::HashMap<String, IntegrationIcon> = self
                .ui
                .integration_icons
                .iter()
                .map(|b| (b.id.clone(), b.clone()))
                .collect();
            let mut merged: Vec<IntegrationIcon> = Vec::new();
            let mut consumed: std::collections::HashSet<String> = std::collections::HashSet::new();
            // 1. User file order — this is the authoritative
            //    sequence. Each user raw gets built-in field
            //    inheritance if a matching built-in exists;
            //    otherwise it stands on its own (must carry
            //    glyph + command).
            // 2026-08-01 — precedence flip. User config is now
            // authoritative for order + `enabled` + `in_palette_bar`
            // ONLY. All other fields (glyph, tooltip, color, command,
            // fallback, description, links) come from the built-in
            // default (or, later, the integration manifest via
            // `merge_integration_manifests`). Fixes the "you changed
            // the default in Rust source but my chip still shows the
            // old snapshotted value" bug.
            //
            // Entries in user config for an unknown id (no matching
            // built-in) are dropped — an integration is either a
            // integration (which installs a manifest) or a built-in.
            // User config is not a valid source for a fresh chip
            // definition anymore; add `[[ui.integration_icon]]` there
            // was always meant for overrides, not authoring.
            for r in &user_raws {
                let Some(id) = id_of_raw(r) else { continue };
                if consumed.contains(&id) {
                    continue;
                }
                let Some(builtin) = builtins_by_id.get(&id) else {
                    // No built-in match — drop the entry. A integration
                    // manifest with this id (if any) will re-add it
                    // later via merge_integration_manifests, with
                    // its own enabled/in_palette_bar defaults.
                    consumed.insert(id);
                    continue;
                };
                let icon = IntegrationIcon {
                    id: builtin.id.clone(),
                    glyph: builtin.glyph.clone(),
                    fallback: builtin.fallback.clone(),
                    command: builtin.command.clone(),
                    color: builtin.color.clone(),
                    label: builtin.label.clone(),
                    // User-controlled fields:
                    enabled: r.enabled.unwrap_or(builtin.enabled),
                    // 2026-08-06 — an enabled integration defaults
                    // to showing on the palette bar unless the user
                    // explicitly opted out (raw TOML has
                    // `in_palette_bar = false`). Prior default
                    // (builtin's value, usually false) meant
                    // flipping `enabled` on didn't make the chip
                    // appear on the top bar — surprising because
                    // the rail chip DID appear.
                    in_palette_bar: r.in_palette_bar.unwrap_or_else(|| {
                        r.enabled.unwrap_or(builtin.enabled) || builtin.in_palette_bar
                    }),
                    description: builtin.description.clone(),
                    homepage: builtin.homepage.clone(),
                    docs: builtin.docs.clone(),
                    repository: builtin.repository.clone(),
                    author: builtin.author.clone(),
                    version: builtin.version.clone(),
                    commands: builtin.commands.clone(),
                    // Integration manifests may still override — they
                    // supersede built-in defaults for anything with
                    // an installed `~/.config/mnml/integrations/<id>.toml`.
                };
                consumed.insert(id);
                merged.push(icon);
            }
            // 2. Built-ins the user file didn't mention — append
            //    in original built-in-default order so newly-added
            //    built-ins land in a stable position rather than
            //    vanishing.
            for builtin in &self.ui.integration_icons {
                if !consumed.contains(&builtin.id) {
                    merged.push(builtin.clone());
                }
            }
            // 2026-07-18 — one-time migration: users who launched
            // mnml pre-v0.2 have persisted `glyph = ""` (U+F8B0,
            // patched Claude Spark) and `glyph = ""` (U+F8B1,
            // patched Codex). Those depend on the mnml Nerd Font
            // patch script having run — everyone else sees tofu.
            // Rewrite to the current defaults on load so the tab
            // icon matches the v0.2 look without hand-editing the
            // config.
            //
            // 2026-07-18 second pass — also migrate `✻` (U+273B) →
            // `✳` (U+2733) for claude_code. Post-empirical-research
            // we know Claude Code's own idle glyph is ✳; the ✻
            // default from the first migration was wrong.
            for icon in &mut merged {
                // 2026-07-19 — flip claude/codex to the mnml-owned
                // F1E00/F1E01 baked into MnmlSymbols.ttf. Aggressive
                // form: any glyph on the claude_code or codex row
                // that ISN'T already F1E00/F1E01 gets flipped. Prior
                // narrow-matches list missed several intermediate
                // values users had accumulated (fallback char used
                // as glyph, older bake results). User report:
                // "i can't seem to get codex icon to use the svg".
                if icon.id == "claude_code" && icon.glyph != "\u{F1E00}" {
                    icon.glyph = "\u{F1E00}".to_string();
                }
                if icon.id == "codex" && icon.glyph != "\u{F1E01}" {
                    icon.glyph = "\u{F1E01}".to_string();
                }
                // HTTP row — cloud (U+F0590 nf-md-web) → blue
                // paper-plane (U+F1D8 nf-fa-paper_plane). The
                // family_catalog default was updated 2026-07-19 but
                // saved user configs still carry the old cloud glyph
                // (user asked "3+ times, whats wrong"). Aggressive
                // flip so any non-F1D8 http glyph gets corrected.
                if icon.id == "http" && icon.glyph != "\u{F1D8}" {
                    icon.glyph = "\u{F1D8}".to_string();
                }
                // Amplify legacy codicon → baked AWS SVG at F1B00.
                if icon.id == "amplify" && icon.glyph == "\u{F087D}" {
                    icon.glyph = "\u{F1B00}".to_string();
                }
                // btop/htop/iftop legacy codicons → baked dev SVGs.
                if icon.id == "btop" && icon.glyph == "\u{F085F}" {
                    icon.glyph = "\u{F2000}".to_string();
                }
                if icon.id == "htop" && icon.glyph == "\u{F085A}" {
                    icon.glyph = "\u{F2001}".to_string();
                }
                if icon.id == "iftop" && icon.glyph == "\u{F048D}" {
                    icon.glyph = "\u{F2002}".to_string();
                }
            }
            // 2026-07-19 — the single "bitbucket" chip was split into
            // `bitbucket_pull_requests` + `bitbucket_pipelines` (each
            // launching the integration with a `--only` flag). Drop any
            // legacy `id = "bitbucket"` entries that survived the
            // merge so the old "Bitbucket pipelines + PRs" chip stops
            // showing up alongside the two new ones. Users who want
            // it back can add a `[[ui.integration_icon]]` block by
            // hand, but the split chips are the recommended UX.
            // 2026-07-19 — kill the "bitbucket" catch-all + three
            // legacy chips the user asked to remove ("linear",
            // "gitlab", "cypress"). Both the built-in defaults and
            // any installed integration manifests can re-inject these,
            // so the retain runs after both merge paths.
            // Belt-and-suspenders: delete any on-disk manifest for
            // these dead IDs at the same time we drop them from the
            // in-memory list. The Installed tab reads the raw
            // manifest dir (not the filtered rail list), so an
            // orphaned `slack.toml` would still surface as a ghost
            // "S Slack (hidden)" row — user report 2026-08-16. If a
            // future weird write path re-materializes the file, the
            // next startup wipes it. 2026-08-16.
            merged.retain(|i| !DEAD_INTEGRATION_IDS.contains(&i.id.as_str()));
            // fs-side wipe of these same ids runs at the top of
            // apply_file (unconditional, doesn't need
            // [[ui.integration_icon]] entries to fire).
            self.ui.integration_icons = merged;
        }
        // #864 — user-persisted rail order. Blanks stripped so a
        // trailing comma in TOML doesn't produce an empty id.
        if let Some(raws) = raw.ui.integration_icon_order {
            self.ui.integration_icon_order = raws
                .into_iter()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
        // Apply the order to integration_icons — ids listed in
        // `integration_icon_order` sort to the front in that order;
        // unlisted ids retain their arrival order at the tail so a
        // freshly-installed chip lands at the end without needing
        // an order-list bump.
        if !self.ui.integration_icon_order.is_empty() {
            let order = self.ui.integration_icon_order.clone();
            let rank =
                |id: &str| -> usize { order.iter().position(|o| o == id).unwrap_or(usize::MAX) };
            self.ui.integration_icons.sort_by_key(|a| rank(&a.id));
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
        if let Some(s) = raw.ui.bufferline_diag_style {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "count" | "dot" | "off") {
                self.ui.bufferline_diag_style = normalized;
            }
        }
        if let Some(s) = raw.ui.coverage_chip_mode {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "both" | "feature" | "code" | "ticker") {
                self.ui.coverage_chip_mode = normalized;
            }
        }
        if let Some(s) = raw.ui.expand_indicator {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "chevron" | "triangle") {
                self.ui.expand_indicator = normalized;
            }
        }
        if let Some(h) = raw.ui.hover_help_height {
            // Clamp to sane bounds — below 3 breaks the title+body
            // layout, above 20 crowds the tree.
            self.ui.hover_help_height = h.clamp(3, 20);
        }
        if let Some(s) = raw.ui.terminal_label {
            let trimmed = s.trim();
            if !trimmed.is_empty() {
                self.ui.terminal_label = trimmed.to_string();
            }
        }
        if let Some(s) = raw.ui.terminal_glyph_svg {
            self.ui.terminal_glyph_svg = s.trim().to_string();
        }
        if let Some(s) = raw.ui.top_bar_cluster_mode {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "auto" | "expanded" | "compact") {
                self.ui.top_bar_cluster_mode = normalized;
            }
        }
        if let Some(s) = raw.ui.tab_bar_ai_icon {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(
                normalized.as_str(),
                "none" | "claude_code" | "codex" | "both"
            ) {
                self.ui.tab_bar_ai_icon = normalized;
            }
        }
        if let Some(s) = raw.ui.ai_layout_mode {
            let normalized = s.trim().to_ascii_lowercase();
            if matches!(normalized.as_str(), "grid" | "tabs") {
                self.ui.ai_layout_mode = normalized;
            }
        }
        if let Some(b) = raw.ui.ai_chip_use_mnml_glyphs {
            self.ui.ai_chip_use_mnml_glyphs = b;
        }
        if let Some(b) = raw.ui.auto_show_sessions_on_ai_activate {
            self.ui.auto_show_sessions_on_ai_activate = b;
        }
        if let Some(b) = raw.ui.git_section_default_expanded {
            self.ui.git_section_default_expanded = b;
        }
        if let Some(b) = raw.ui.integrations_section_default_expanded {
            self.ui.integrations_section_default_expanded = b;
        }
        if let Some(b) = raw.ui.first_launch_complete {
            self.ui.first_launch_complete = b;
        }
        if let Some(b) = raw.ui.show_workspace_dots {
            self.ui.show_workspace_dots = b;
        }
        if let Some(b) = raw.ui.hover_tooltip {
            self.ui.hover_tooltip = b;
        }
        if let Some(b) = raw.ui.hover_help {
            self.ui.hover_help = b;
        }
        if let Some(s) = raw.ui.md_preview_engine {
            let trimmed = s.trim().to_string();
            if !trimmed.is_empty() {
                self.ui.md_preview_engine = trimmed;
            }
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
        if let Some(b) = raw.http.auto_format_body {
            self.http.auto_format_body = b;
        }
        if let Some(b) = raw.http.sync_normalize {
            self.http.sync_normalize = b;
        }
        if let Some(cr) = raw.http.collection_root {
            let trimmed = cr.trim().to_ascii_lowercase();
            self.http.collection_root = match trimmed.as_str() {
                "workspace" | "in_tree" | "in-tree" | "bruno" => {
                    crate::config::HttpCollectionRoot::Workspace
                }
                "hidden" | ".mnml/collections" | ".mnml" | "" => {
                    crate::config::HttpCollectionRoot::Hidden
                }
                other => {
                    eprintln!(
                        "mnml: [http] collection_root = {other:?} not recognised — using \"hidden\" (\".mnml/collections\")"
                    );
                    crate::config::HttpCollectionRoot::Hidden
                }
            };
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
        // `[[workspaces]]` — additional integration workspaces. Append (rather
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
        // [marketplace] — federated app + launcher discovery.
        if let Some(v) = raw.marketplace.enabled {
            self.marketplace.enabled = v;
        }
        if let Some(v) = raw.marketplace.cache_ttl_secs {
            self.marketplace.cache_ttl_secs = v;
        }
        if let Some(v) = raw.marketplace.use_defaults {
            self.marketplace.use_defaults = v;
        }
        for s in raw.marketplace.sources {
            if let Some(src) = s.into_source() {
                self.marketplace.sources.push(src);
            }
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

/// Directory where mnml keeps dated backups of the user config —
/// `~/.config/mnml/backups/`. Every write via `write_user_config`
/// copies the pre-write file here as
/// `config.YYYY-MM-DD-HHMMSS.toml` before overwriting. Kept for
/// disaster recovery when a bad serializer roundtrip or user typo
/// corrupts the live config (user report 2026-07-31).
pub fn config_backups_dir() -> Option<PathBuf> {
    home_config_path().and_then(|p| p.parent().map(|d| d.join("backups")))
}

/// Cap on the number of backups retained. Older ones get pruned
/// on each write. Enough to cover a full session's worth of edits
/// without unbounded growth.
const MAX_CONFIG_BACKUPS: usize = 50;

/// Write `contents` to the user config atomically, first copying
/// the current file (if any) to a dated backup under
/// `~/.config/mnml/backups/`. Prune old backups past `MAX_CONFIG_BACKUPS`.
///
/// Every user-facing config-write path (settings save, cloud-run
/// defaults, workspaces upsert, integration-icon persistence, …)
/// funnels through here so the recovery net is uniform.
pub fn write_user_config(cfg_path: &std::path::Path, contents: &str) -> std::io::Result<()> {
    // 1. Snapshot the current file (if it exists) to backups/.
    //    Skip silently if the backup dir can't be resolved or
    //    written — we don't want backup failure to block the
    //    primary write.
    if cfg_path.exists()
        && let Some(backups) = config_backups_dir()
        && std::fs::create_dir_all(&backups).is_ok()
        && let Ok(existing) = std::fs::read(cfg_path)
    {
        let stamp = backup_timestamp();
        let backup = backups.join(format!("config.{stamp}.toml"));
        // If two writes collide inside the same second, append a
        // small suffix so we don't clobber the earlier one.
        let backup = ensure_unique(backup);
        let _ = std::fs::write(&backup, existing);
        prune_old_backups(&backups, MAX_CONFIG_BACKUPS);
    }
    // 2. Write the new contents.
    std::fs::write(cfg_path, contents)
}

/// UTC-ish local timestamp — `YYYY-MM-DD-HHMMSS`. Uses SystemTime
/// so we don't drag in chrono; readable enough for backup filenames.
fn backup_timestamp() -> String {
    let now = std::time::SystemTime::now();
    let dur = now
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = dur.as_secs();
    // Local time via `libc::localtime_r` would need extra deps; the
    // UTC breakdown below is fine for a filename stamp and matches
    // real UTC when the machine's TZ is UTC. Users who care about
    // local time in the filename can `ls -lt`.
    let (y, mo, d, h, mi, s) = utc_ymdhms(secs);
    format!("{y:04}-{mo:02}-{d:02}-{h:02}{mi:02}{s:02}")
}

/// Classic epoch-seconds → (year, month, day, hour, minute, second)
/// breakdown. Anchored at 1970-01-01. Good through 2100+.
fn utc_ymdhms(mut secs: u64) -> (u32, u32, u32, u32, u32, u32) {
    let s = (secs % 60) as u32;
    secs /= 60;
    let mi = (secs % 60) as u32;
    secs /= 60;
    let h = (secs % 24) as u32;
    let mut days = (secs / 24) as i64;
    let mut year: i64 = 1970;
    loop {
        let leap = is_leap(year);
        let n = if leap { 366 } else { 365 };
        if days < n {
            break;
        }
        days -= n;
        year += 1;
    }
    let dim = [
        31,
        if is_leap(year) { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    let mut mo: i64 = 0;
    while mo < 12 && days >= dim[mo as usize] {
        days -= dim[mo as usize];
        mo += 1;
    }
    (year as u32, (mo + 1) as u32, (days + 1) as u32, h, mi, s)
}

fn is_leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn ensure_unique(mut path: PathBuf) -> PathBuf {
    if !path.exists() {
        return path;
    }
    let stem = path.file_stem().map(|s| s.to_owned()).unwrap_or_default();
    let ext = path.extension().map(|s| s.to_owned()).unwrap_or_default();
    let parent = path
        .parent()
        .unwrap_or(std::path::Path::new("."))
        .to_path_buf();
    for i in 1..1000 {
        let stem_s = stem.to_string_lossy();
        let ext_s = ext.to_string_lossy();
        let candidate = if ext_s.is_empty() {
            parent.join(format!("{stem_s}-{i}"))
        } else {
            parent.join(format!("{stem_s}-{i}.{ext_s}"))
        };
        if !candidate.exists() {
            return candidate;
        }
        path = candidate;
    }
    path
}

fn prune_old_backups(dir: &std::path::Path, keep: usize) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut files: Vec<(std::path::PathBuf, std::time::SystemTime)> = entries
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let p = e.path();
            let name = p.file_name()?.to_str()?.to_string();
            if !name.starts_with("config.") || !name.ends_with(".toml") {
                return None;
            }
            let mtime = e.metadata().ok().and_then(|m| m.modified().ok())?;
            Some((p, mtime))
        })
        .collect();
    if files.len() <= keep {
        return;
    }
    // Newest first — retain the first `keep`, delete the rest.
    files.sort_by_key(|b| std::cmp::Reverse(b.1));
    for (p, _) in files.into_iter().skip(keep) {
        let _ = std::fs::remove_file(p);
    }
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
    write_user_config(&cfg_path, &updated)
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
    write_user_config(&cfg_path, &updated)
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
    write_user_config(&cfg_path, &updated)
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
    write_user_config(&cfg_path, &updated)
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
                    drop notes / `.http` files / snippets. Open integrations (S3,\n\
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
    write_user_config(&cfg_path, &out).map_err(|e| format!("write {}: {e}", cfg_path.display()))?;
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
    // Portable-mode override wins over everything — the marker
    // folder next to the binary is explicit user intent (task
    // #858). When absent, `crate::data_root::data_root_kind()`
    // reports `Home` and this falls through to the historical
    // XDG / HOME layout unchanged.
    if crate::data_root::data_root_kind() == crate::data_root::DataRootKind::Portable {
        return Some(crate::data_root::data_root().join("config.toml"));
    }
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

    // Task #944 — multi-account Claude support. The migration path
    // must synthesize a single-account default when no
    // `[[ai.claude.accounts]]` block is present so existing installs
    // keep working with zero config edits.
    #[test]
    fn claude_accounts_defaults_to_single_account_when_absent() {
        let cfg = Config::default();
        let accounts = cfg.claude_accounts();
        assert_eq!(accounts.len(), 1);
        assert_eq!(accounts[0].name, "default");
        assert_eq!(accounts[0].token_path, "ai_token");
        assert!(accounts[0].active);
    }

    #[test]
    fn claude_accounts_parses_multi_account_block() {
        let src = "[ai]\n\
                   [[ai.claude.accounts]]\n\
                   name = \"personal\"\n\
                   token_path = \"ai_token\"\n\
                   active = true\n\
                   [[ai.claude.accounts]]\n\
                   name = \"work\"\n\
                   token_path = \"ai_token.work\"\n";
        let mut cfg = Config::default();
        // clippy field_reassign_with_default off here — the rest of
        // Config::default() is what we want; only `ai` needs
        // replacing for this test.
        #[allow(clippy::field_reassign_with_default)]
        {
            cfg.ai = toml::from_str::<toml::Value>(src)
                .unwrap()
                .get("ai")
                .cloned()
                .unwrap();
        }
        let accounts = cfg.claude_accounts();
        assert_eq!(accounts.len(), 2);
        assert_eq!(accounts[0].name, "personal");
        assert!(accounts[0].active);
        assert_eq!(accounts[1].name, "work");
        assert!(!accounts[1].active);
    }

    #[test]
    fn claude_accounts_normalizes_no_active_to_first_wins() {
        let src = "[ai]\n\
                   [[ai.claude.accounts]]\n\
                   name = \"personal\"\n\
                   token_path = \"ai_token\"\n\
                   [[ai.claude.accounts]]\n\
                   name = \"work\"\n\
                   token_path = \"ai_token.work\"\n";
        let mut cfg = Config::default();
        // clippy field_reassign_with_default off here — the rest of
        // Config::default() is what we want; only `ai` needs
        // replacing for this test.
        #[allow(clippy::field_reassign_with_default)]
        {
            cfg.ai = toml::from_str::<toml::Value>(src)
                .unwrap()
                .get("ai")
                .cloned()
                .unwrap();
        }
        let accounts = cfg.claude_accounts();
        assert_eq!(accounts.len(), 2);
        assert!(accounts[0].active);
        assert!(!accounts[1].active);
    }

    #[test]
    fn claude_accounts_show_all_flag_defaults_false() {
        let cfg = Config::default();
        assert!(!cfg.ai_claude_show_all());
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
    fn default_integration_icons_are_first_party_only() {
        // 2026-08-01 — mnml core stopped hardcoding integration
        // knowledge. Only the four first-party surfaces stay as
        // built-in defaults (browser, claude_code, codex, http).
        // Everything else comes from installed integration manifests
        // at ~/.config/mnml/integrations/ or (P3+) launcher entries.
        let cfg = Config::default();
        let ids: Vec<&str> = cfg
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.as_str())
            .collect();
        // First-party surfaces present.
        assert!(ids.contains(&"browser"));
        assert!(ids.contains(&"claude_code"));
        assert!(ids.contains(&"codex"));
        // Formerly-hardcoded entries are no longer built-in.
        assert!(!ids.contains(&"bitbucket_pull_requests"));
        assert!(!ids.contains(&"bitbucket_pipelines"));
        assert!(!ids.contains(&"github"));
        assert!(!ids.contains(&"dynamodb"));
        // Spot-check the Claude entry to catch glyph/color regressions.
        let claude = cfg
            .ui
            .integration_icons
            .iter()
            .find(|i| i.id == "claude_code")
            .unwrap();
        assert_eq!(claude.command, "ai.claude_code");
        // 2026-08-09 — updated from "orange" (theme slot) to the
        // exact Anthropic brand hex introduced 2026-08-08 alongside
        // the `#RRGGBB` literals-in-integration-icons feature.
        assert_eq!(claude.color, "#D16D51");
    }

    /// Regression 2026-07-03: reordering integration chips via
    /// the right-click "Move up / Move to top / Move down / Move
    /// to bottom" menu writes the whole `[[ui.integration_icon]]`
    /// array to config in the new order. On the NEXT load, the
    /// prior config-load code walked built-in defaults first and
    /// layered user overrides on top — so the user's reorder was
    /// silently reset to built-in-default order. Now the load
    /// honors the user file's order verbatim.
    #[test]
    fn user_reorder_of_integration_icons_survives_reload() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        // Write out a config that reorders the first-party built-ins.
        // 2026-08-01 — mnml core no longer hardcodes third-party
        // integrations, so the test uses only first-party surfaces
        // (browser, claude_code, codex) as the reorder subjects.
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[[ui.integration_icon]]
id = "codex"
[[ui.integration_icon]]
id = "claude_code"
[[ui.integration_icon]]
id = "browser"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file(&cfg_path);
        let ids: Vec<&str> = cfg
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.as_str())
            .collect();
        // The three user entries must appear FIRST, in file order.
        assert_eq!(
            &ids[..3],
            &["codex", "claude_code", "browser"],
            "user-file order must be preserved verbatim; got {ids:?}"
        );
    }

    // 2026-08-01 (P2) — launcher_icons_config_replaces_defaults +
    // launcher_icons_empty_array_clears_defaults tests deleted with
    // the LauncherIcon retirement.

    /// #864 — the `integration_icon_order` key sorts the effective
    /// icons list. Ids listed there come first in that order; ids
    /// NOT listed retain their arrival order at the tail so a
    /// freshly-installed chip lands at the end without needing an
    /// order-list bump. This covers the manifest-backed case which
    /// the older `user_reorder_of_integration_icons_survives_reload`
    /// couldn't exercise (that one only reorders first-party
    /// builtins, which the flip doesn't drop from raw config).
    #[test]
    fn integration_icon_order_sorts_effective_list() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[ui]
integration_icon_order = ["codex", "browser"]
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file(&cfg_path);
        let ids: Vec<&str> = cfg
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.as_str())
            .collect();
        // First two entries are the ordered ones, in order.
        assert_eq!(&ids[..2], &["codex", "browser"]);
        // `claude_code` (only remaining first-party default) unlisted
        // → lands after the two ordered ids.
        assert!(ids[2..].contains(&"claude_code"));
    }

    #[test]
    fn empty_integration_icon_order_leaves_order_untouched() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        // Explicitly-empty order — no reorder should apply.
        std::fs::write(&cfg_path, "[ui]\nintegration_icon_order = []\n").unwrap();
        let default_order: Vec<String> = Config::default()
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.clone())
            .collect();
        let mut cfg = Config::default();
        cfg.apply_file(&cfg_path);
        let after_order: Vec<String> = cfg
            .ui
            .integration_icons
            .iter()
            .map(|i| i.id.clone())
            .collect();
        assert_eq!(default_order, after_order);
    }

    #[test]
    fn marketplace_config_defaults() {
        let cfg = Config::default();
        assert!(cfg.marketplace.enabled);
        assert_eq!(cfg.marketplace.cache_ttl_secs, 3600);
        assert!(cfg.marketplace.use_defaults);
        assert!(cfg.marketplace.sources.is_empty());
        // Effective source list picks up the built-in defaults when
        // use_defaults is on and no user sources are set.
        assert_eq!(cfg.marketplace.effective_sources().len(), 2);
    }

    #[test]
    fn marketplace_user_source_appends_to_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[marketplace]
cache_ttl_secs = 7200

[[marketplace.source]]
type = "github_launcher_folder"
id = "acme"
repo = "acme-corp/mnml-launchers"
path = "."
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert_eq!(cfg.marketplace.cache_ttl_secs, 7200);
        assert_eq!(cfg.marketplace.sources.len(), 1);
        // Effective = built-in defaults + user entry (use_defaults on).
        let effective = cfg.marketplace.effective_sources();
        assert_eq!(effective.len(), 3);
        assert_eq!(effective[2].id(), "acme");
    }

    #[test]
    fn marketplace_use_defaults_false_replaces_them() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[marketplace]
use_defaults = false

[[marketplace.source]]
type = "crates_keyword"
keyword = "my-own-keyword"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        let effective = cfg.marketplace.effective_sources();
        assert_eq!(effective.len(), 1);
    }

    #[test]
    fn marketplace_disabled_still_parses_sources() {
        // A user can turn the marketplace off without losing their
        // configured sources — flipping enabled back on picks them
        // up unchanged.
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[marketplace]
enabled = false

[[marketplace.source]]
type = "crates_keyword"
keyword = "test"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert!(!cfg.marketplace.enabled);
        assert_eq!(cfg.marketplace.sources.len(), 1);
    }
}
