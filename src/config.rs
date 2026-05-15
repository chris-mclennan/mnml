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
    /// `[keys.<section>]` — key spec → command id. Sections: `global`, `vim`,
    /// `standard`. Resolved into an [`crate::input::keymap::Keymap`].
    pub keys: BTreeMap<String, BTreeMap<String, String>>,
    /// `[lsp.<lang>]` — raw tables, validated by the LSP track later.
    pub lsp: BTreeMap<String, toml::Value>,
    /// `[ai]` / `[tools]` — raw tables, validated by the AI track later.
    pub ai: toml::Value,
    pub tools: toml::Value,
    /// `[tasks.<name>]` — named shell commands openable in a pty pane (`task.run`).
    pub tasks: BTreeMap<String, TaskDef>,
    /// `[startup] tasks = [...]` — task names auto-run in pty panes on workspace open.
    pub startup_tasks: Vec<String>,
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
    pub browser: BrowserConfig,
    pub playwright: PlaywrightConfig,
    pub ci: CiConfig,
    pub bitbucket: BitbucketConfig,
    pub github: GithubConfig,
}

/// `[bitbucket]` — Bitbucket Cloud REST API integration. Powers the
/// `Pane::BitbucketPipelines` and `Pane::BitbucketPr` live dashboards
/// (phases 2–3); phase 1 just wires the worker so the API call shape
/// is verifiable in isolation.
///
/// ```toml
/// [bitbucket]
/// auth_env  = "BITBUCKET_TOKEN"   # optional, defaults to BITBUCKET_TOKEN
/// poll_secs = 30                  # optional, defaults to 30
///
/// [[bitbucket.repos]]
/// workspace = "exampleorg"
/// slug      = "example-api"
///
/// [[bitbucket.repos]]
/// workspace = "exampleorg"
/// slug      = "private-playwright"
/// ```
///
/// The worker reads the auth token from `$<auth_env>` at spawn time —
/// the value never lands in config files. With no `[[bitbucket.repos]]`
/// entries, the worker stays idle.
#[derive(Debug, Clone, Default)]
pub struct BitbucketConfig {
    /// Env var name to read the API token from. `None` ⇒ `"BITBUCKET_TOKEN"`.
    pub auth_env: Option<String>,
    /// Seconds between poll cycles per repo. `None` ⇒ 30.
    pub poll_secs: Option<u64>,
    /// Repos to watch. Order is meaningful — picker / pane lists render in this order.
    pub repos: Vec<BitbucketRepo>,
}

#[derive(Debug, Clone)]
pub struct BitbucketRepo {
    pub workspace: String,
    pub slug: String,
}

/// `[github]` — GitHub Actions / Pull Requests integration. Mirrors the
/// shape of [`BitbucketConfig`] — the worker, panes, and view are parallel
/// modules so the two hosts can evolve independently without forcing a
/// premature shared abstraction.
///
/// ```toml
/// [github]
/// auth_env  = "GITHUB_TOKEN"   # optional, defaults to GITHUB_TOKEN
/// poll_secs = 30                # optional, defaults to 30
///
/// [[github.repos]]
/// owner = "exampleorg"
/// repo  = "private-claude-knowledge"
/// ```
#[derive(Debug, Clone, Default)]
pub struct GithubConfig {
    /// Env var name to read the API token from. `None` ⇒ `"GITHUB_TOKEN"`.
    /// Classic PATs (`ghp_*`), fine-grained PATs (`github_pat_*`), app
    /// tokens (`ghs_*`), and OAuth tokens (`gho_*`) all use the same
    /// `Authorization: Bearer <token>` shape.
    pub auth_env: Option<String>,
    /// Seconds between poll cycles per repo. `None` ⇒ 30.
    pub poll_secs: Option<u64>,
    /// Repos to watch. Order is meaningful — picker / pane lists render in this order.
    pub repos: Vec<GithubRepo>,
}

#[derive(Debug, Clone)]
pub struct GithubRepo {
    pub owner: String,
    pub repo: String,
}

impl GithubConfig {
    pub fn any_configured(&self) -> bool {
        !self.repos.is_empty()
    }
    pub fn auth_env_name(&self) -> &str {
        self.auth_env.as_deref().unwrap_or("GITHUB_TOKEN")
    }
    pub fn poll_secs_or_default(&self) -> u64 {
        self.poll_secs.unwrap_or(30).max(5)
    }
}

impl BitbucketConfig {
    /// `true` when at least one repo is configured — the worker can start.
    pub fn any_configured(&self) -> bool {
        !self.repos.is_empty()
    }
    /// Env var name to source the API token from. Defaults to `BITBUCKET_TOKEN`.
    pub fn auth_env_name(&self) -> &str {
        self.auth_env.as_deref().unwrap_or("BITBUCKET_TOKEN")
    }
    /// Poll interval in seconds. Defaults to 30.
    pub fn poll_secs_or_default(&self) -> u64 {
        self.poll_secs.unwrap_or(30).max(5)
    }
}

/// `[ci]` — Continuous-integration provider settings. Consumed by the
/// `private` Cargo feature's CodeBuild integration (`Pane::CodeBuilds`).
/// Unconditional in `Config` so lean builds parse it cleanly.
///
/// ```toml
/// [ci]
/// provider = "codebuild"           # only "codebuild" recognized today
/// project  = "private-playwright"   # required for codebuild
/// region   = "us-east-1"           # optional; falls back to AWS CLI defaults
/// ```
#[derive(Debug, Clone, Default)]
pub struct CiConfig {
    pub provider: Option<String>,
    pub project: Option<String>,
    pub region: Option<String>,
}

/// `[playwright]` — settings used by the Playwright integration and (when
/// the `private` Cargo feature is built) the DocumentDB live-executions
/// browser. The config struct lives unconditionally so a private-built mnml
/// can read URIs out of a lean-built user's config file without forcing
/// every user to install the feature.
#[derive(Debug, Clone, Default)]
pub struct PlaywrightConfig {
    pub docdb: PlaywrightDocDbConfig,
}

/// `[playwright.docdb]` — per-env DocumentDB connection strings consumed
/// by the `private` feature. Each field is `None` until the user sets it
/// in `~/.config/mnml/config.toml` (or a workspace `.mnml/config.toml`):
///
/// ```toml
/// [playwright.docdb]
/// dev_uri     = "mongodb://…/test_db?replicaSet=rs0&tlsCAFile=…"
/// staging_uri = "mongodb://…"
/// prod_uri    = "mongodb://…"
/// database    = "playwright"         # optional, defaults to "playwright"
/// collection  = "TestExecutions"     # optional, defaults to "TestExecutions"
/// ```
///
/// Connection strings stay out of the codebase. When all three URIs are
/// `None`, the private worker thread emits a "configure [playwright.docdb]"
/// status event and stays idle.
#[derive(Debug, Clone, Default)]
pub struct PlaywrightDocDbConfig {
    pub dev_uri: Option<String>,
    pub staging_uri: Option<String>,
    pub prod_uri: Option<String>,
    /// Defaults to `"playwright"` at consumer-site if `None`.
    pub database: Option<String>,
    /// Defaults to `"TestExecutions"` at consumer-site if `None`.
    pub collection: Option<String>,
    /// Live-feed strategy. Recognized values: `"polling"` (default),
    /// `"stream"` (DocumentDB change streams; requires the cluster's
    /// `change_stream_log_retention_duration` > 0), or `"auto"` (try
    /// streams; fall back to polling if `watch()` fails). Unrecognized
    /// values are treated as `"polling"`.
    pub mode: Option<String>,
}

impl PlaywrightDocDbConfig {
    /// `true` when at least one env URI is set — the worker can connect.
    pub fn any_configured(&self) -> bool {
        self.dev_uri.is_some() || self.staging_uri.is_some() || self.prod_uri.is_some()
    }
}

#[derive(Debug, Clone)]
pub struct BrowserConfig {
    /// Launch Chrome with `--headless=new` (no window). The pane still
    /// receives network / console / DOM events; the user drives via `g`
    /// (navigate), `e` (eval), `s` (screenshot), etc. Default off — the
    /// visible window is what most users expect from `browser.open`.
    pub headless: bool,
}

#[derive(Debug, Clone)]
pub struct TaskDef {
    /// The shell command line (run via `$SHELL -c`).
    pub cmd: String,
    /// Working directory — relative paths are resolved against the workspace; `None` ⇒ workspace.
    pub cwd: Option<String>,
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
    pub ascii_icons: bool,
    pub tree_width: u16,
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
}

impl Default for Config {
    fn default() -> Self {
        Config {
            editor: EditorConfig {
                input_style: "standard".to_string(),
                tab_width: 4,
                autosave_secs: 0,
                trim_trailing_ws_on_save: false,
                breadcrumb: true,
                auto_pair: false,
                auto_indent: true,
                format_on_save: false,
                format_on_type: false,
                autosave_on_focus_loss: false,
                inlay_hints: true,
                code_lens: true,
                text_width: 80,
                ensure_trailing_newline: true,
            },
            ui: UiConfig {
                theme: "onedark".to_string(),
                ascii_icons: false,
                tree_width: 30,
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
            },
            session: SessionConfig { restore: true },
            keys: BTreeMap::new(),
            lsp: BTreeMap::new(),
            ai: toml::Value::Table(Default::default()),
            tools: toml::Value::Table(Default::default()),
            tasks: BTreeMap::new(),
            startup_tasks: Vec::new(),
            snippets: BTreeMap::new(),
            abbreviations: BTreeMap::new(),
            browser: BrowserConfig { headless: false },
            playwright: PlaywrightConfig::default(),
            ci: CiConfig::default(),
            bitbucket: BitbucketConfig::default(),
            github: GithubConfig::default(),
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
    browser: RawBrowser,
    #[serde(default)]
    playwright: RawPlaywright,
    #[serde(default)]
    ci: RawCi,
    #[serde(default)]
    bitbucket: RawBitbucket,
    #[serde(default)]
    github: RawGithub,
}

#[derive(Debug, Default, Deserialize)]
struct RawBitbucket {
    auth_env: Option<String>,
    poll_secs: Option<u64>,
    #[serde(default)]
    repos: Vec<RawBitbucketRepo>,
}

#[derive(Debug, Default, Deserialize)]
struct RawBitbucketRepo {
    workspace: String,
    slug: String,
}

#[derive(Debug, Default, Deserialize)]
struct RawGithub {
    auth_env: Option<String>,
    poll_secs: Option<u64>,
    #[serde(default)]
    repos: Vec<RawGithubRepo>,
}

#[derive(Debug, Default, Deserialize)]
struct RawGithubRepo {
    owner: String,
    repo: String,
}

#[derive(Debug, Default, Deserialize)]
struct RawCi {
    provider: Option<String>,
    project: Option<String>,
    region: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct RawBrowser {
    headless: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct RawPlaywright {
    #[serde(default)]
    docdb: RawPlaywrightDocDb,
}

#[derive(Debug, Default, Deserialize)]
struct RawPlaywrightDocDb {
    dev_uri: Option<String>,
    staging_uri: Option<String>,
    prod_uri: Option<String>,
    database: Option<String>,
    collection: Option<String>,
    mode: Option<String>,
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
    format_on_type: Option<bool>,
    autosave_on_focus_loss: Option<bool>,
    inlay_hints: Option<bool>,
    code_lens: Option<bool>,
    text_width: Option<usize>,
    ensure_trailing_newline: Option<bool>,
}

#[derive(Debug, Default, Deserialize)]
struct RawUi {
    theme: Option<String>,
    ascii_icons: Option<bool>,
    tree_width: Option<u16>,
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
        if let Some(v) = raw.editor.autosave_on_focus_loss {
            self.editor.autosave_on_focus_loss = v;
        }
        if let Some(v) = raw.editor.inlay_hints {
            self.editor.inlay_hints = v;
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
        if let Some(v) = raw.ui.theme {
            self.ui.theme = v;
        }
        if let Some(v) = raw.ui.ascii_icons {
            self.ui.ascii_icons = v;
        }
        if let Some(v) = raw.ui.tree_width {
            self.ui.tree_width = v.clamp(10, 80);
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
        for (scope, map) in raw.snippets {
            self.snippets.entry(scope).or_default().extend(map);
        }
        for (k, v) in raw.abbr {
            self.abbreviations.insert(k, v);
        }
        if let Some(v) = raw.browser.headless {
            self.browser.headless = v;
        }
        // `[playwright.docdb]` — overlay only the fields that are set, so a
        // workspace-level file can override the home file's defaults per-key.
        let docdb_raw = raw.playwright.docdb;
        if let Some(v) = docdb_raw.dev_uri {
            self.playwright.docdb.dev_uri = Some(v);
        }
        if let Some(v) = docdb_raw.staging_uri {
            self.playwright.docdb.staging_uri = Some(v);
        }
        if let Some(v) = docdb_raw.prod_uri {
            self.playwright.docdb.prod_uri = Some(v);
        }
        if let Some(v) = docdb_raw.database {
            self.playwright.docdb.database = Some(v);
        }
        if let Some(v) = docdb_raw.collection {
            self.playwright.docdb.collection = Some(v);
        }
        if let Some(v) = docdb_raw.mode {
            self.playwright.docdb.mode = Some(v);
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
        // `[bitbucket]` — per-field overlay so workspace files can refine
        // home defaults. Repos *append* (rather than replace) so a
        // workspace-local file can add repos without re-listing the homedir set.
        if let Some(v) = raw.bitbucket.auth_env {
            self.bitbucket.auth_env = Some(v);
        }
        if let Some(v) = raw.bitbucket.poll_secs {
            self.bitbucket.poll_secs = Some(v);
        }
        for r in raw.bitbucket.repos {
            self.bitbucket.repos.push(BitbucketRepo {
                workspace: r.workspace,
                slug: r.slug,
            });
        }
        // `[github]` — same per-field overlay shape as `[bitbucket]`.
        if let Some(v) = raw.github.auth_env {
            self.github.auth_env = Some(v);
        }
        if let Some(v) = raw.github.poll_secs {
            self.github.poll_secs = Some(v);
        }
        for r in raw.github.repos {
            self.github.repos.push(GithubRepo {
                owner: r.owner,
                repo: r.repo,
            });
        }
    }
}

/// Public counterpart of [`home_config_path`] — exposed so `file.open_settings`
/// can resolve the same path as [`Config::load`].
pub fn user_config_path() -> Option<PathBuf> {
    home_config_path()
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
    fn playwright_docdb_config_parses() {
        let dir = tempfile::tempdir().unwrap();
        let cfg_path = dir.path().join("config.toml");
        let mut f = std::fs::File::create(&cfg_path).unwrap();
        writeln!(
            f,
            r#"
[playwright.docdb]
dev_uri     = "mongodb://dev.example/test_db"
staging_uri = "mongodb://stg.example/test_db"
database    = "playwright"
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert_eq!(
            cfg.playwright.docdb.dev_uri.as_deref(),
            Some("mongodb://dev.example/test_db")
        );
        assert_eq!(
            cfg.playwright.docdb.staging_uri.as_deref(),
            Some("mongodb://stg.example/test_db")
        );
        assert!(cfg.playwright.docdb.prod_uri.is_none());
        assert_eq!(cfg.playwright.docdb.database.as_deref(), Some("playwright"));
        assert!(cfg.playwright.docdb.any_configured());
    }

    #[test]
    fn playwright_docdb_default_is_empty() {
        let cfg = Config::default();
        assert!(!cfg.playwright.docdb.any_configured());
    }

    #[test]
    fn bitbucket_config_parses_multi_repo() {
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

[[bitbucket.repos]]
workspace = "exampleorg"
slug      = "private-playwright"
"#
        )
        .unwrap();

        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert_eq!(cfg.bitbucket.auth_env_name(), "BB_TOKEN");
        assert_eq!(cfg.bitbucket.poll_secs_or_default(), 60);
        assert_eq!(cfg.bitbucket.repos.len(), 2);
        assert_eq!(cfg.bitbucket.repos[0].workspace, "exampleorg");
        assert_eq!(cfg.bitbucket.repos[0].slug, "example-api");
        assert_eq!(cfg.bitbucket.repos[1].slug, "private-playwright");
        assert!(cfg.bitbucket.any_configured());
    }

    #[test]
    fn bitbucket_default_is_empty_with_safe_defaults() {
        let cfg = Config::default();
        assert!(!cfg.bitbucket.any_configured());
        // Defaults so the worker has sensible values even without a config.
        assert_eq!(cfg.bitbucket.auth_env_name(), "BITBUCKET_TOKEN");
        assert_eq!(cfg.bitbucket.poll_secs_or_default(), 30);
    }

    #[test]
    fn bitbucket_poll_secs_floor_5() {
        // Don't let the user accidentally hammer the API at 1s intervals.
        let mut cfg = BitbucketConfig {
            poll_secs: Some(1),
            ..Default::default()
        };
        assert_eq!(cfg.poll_secs_or_default(), 5);
        cfg.poll_secs = Some(30);
        assert_eq!(cfg.poll_secs_or_default(), 30);
    }

    #[test]
    fn github_config_parses_multi_repo() {
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
repo  = "private-claude-knowledge"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&cfg_path);
        assert_eq!(cfg.github.auth_env_name(), "GH_TOKEN");
        assert_eq!(cfg.github.poll_secs_or_default(), 45);
        assert_eq!(cfg.github.repos.len(), 1);
        assert_eq!(cfg.github.repos[0].owner, "exampleorg");
        assert_eq!(cfg.github.repos[0].repo, "private-claude-knowledge");
        assert!(cfg.github.any_configured());
    }

    #[test]
    fn github_default_is_empty_with_safe_defaults() {
        let cfg = Config::default();
        assert!(!cfg.github.any_configured());
        assert_eq!(cfg.github.auth_env_name(), "GITHUB_TOKEN");
        assert_eq!(cfg.github.poll_secs_or_default(), 30);
    }

    #[test]
    fn bitbucket_repos_append_across_files() {
        // Workspace-local file should add to the homedir list, not replace it.
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home.toml");
        let mut f = std::fs::File::create(&home).unwrap();
        writeln!(
            f,
            r#"
[[bitbucket.repos]]
workspace = "exampleorg"
slug      = "example-api"
"#
        )
        .unwrap();
        let ws = dir.path().join("ws.toml");
        let mut f = std::fs::File::create(&ws).unwrap();
        writeln!(
            f,
            r#"
[[bitbucket.repos]]
workspace = "exampleorg"
slug      = "private-playwright"
"#
        )
        .unwrap();
        let mut cfg = Config::default();
        cfg.apply_file_pub(&home);
        cfg.apply_file_pub(&ws);
        assert_eq!(cfg.bitbucket.repos.len(), 2);
    }
}
