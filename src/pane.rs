//! The "open thing" abstraction. `Editor` is the workhorse; `MdPreview` is a
//! read-only rendered-markdown view; `Diff` is a `git diff` view with hunk
//! navigation + staging. Later tracks add `Pty`, `Request`, `Ai` — each is
//! additive (a new variant + a renderer + a `match` arm here), never a refactor.

use std::path::PathBuf;

use crate::ai::AiPane;
use crate::browser_pane::BrowserPane;
use crate::buffer::Buffer;
use crate::cheatsheet::CheatsheetPane;
use crate::git::diff::Hunk;
use crate::git::graph::GitGraphPane;
use crate::git::stage::GitStatusPane;
use crate::grep_pane::GrepPane;
use crate::image::ImagePane;
use crate::lsp::diagnostics_pane::DiagnosticsPane;
use crate::lsp::outline_pane::OutlinePane;
use crate::playwright::TestsPane;
use crate::playwright::flaky_pane::FlakyPane;
use crate::pty_pane::PtySession;
use crate::request_pane::RequestPane;

// `Editor`'s payload (`Buffer`) is much bigger than the others'; boxing it would
// ripple a `Box` through every `Pane::Editor(b)` site for a handful of bytes of
// slack in a Vec that holds ~1–10 panes. Not worth it (revisit if more chunky
// variants land).
#[allow(clippy::large_enum_variant)]
pub enum Pane {
    Editor(Buffer),
    /// A rendered-markdown view of `path`. `source` is a snapshot of the `.md`
    /// text (refreshed when the source buffer is saved); `scroll` is the top row.
    MdPreview(MdPreview),
    /// A `git diff` view (hunk nav + stage/unstage).
    Diff(DiffView),
    /// A coloured-lane commit-DAG browser (`git log --all` + commit details).
    GitGraph(GitGraphPane),
    /// A staging view — worktree/index file lists + stage/unstage + commit.
    GitStatus(GitStatusPane),
    /// A request fired from a `.http`/`.curl` file, with its response.
    Request(RequestPane),
    /// An embedded terminal (shell / `claude` / `codex`).
    Pty(PtySession),
    /// An AI one-shot (`claude -p`) prompt + its answer.
    Ai(AiPane),
    /// A Playwright test run + its results tree.
    Tests(TestsPane),
    /// The flaky-test dashboard — every wobbly test in the workspace's history.
    Flaky(FlakyPane),
    /// A persistent symbol outline for one editor — the `documentSymbol` reply,
    /// rendered as an indented list with click/Enter-to-jump.
    Outline(OutlinePane),
    /// A directory listing as a pane — the file-manager foundation
    /// (design conversation 2026-08-30, shape "C": no mode, just a pane,
    /// so side-by-side panels come free from `Layout::Split`).
    Files(crate::file_browser::FileBrowserPane),
    /// A Chrome the IDE is driving over CDP — a console / nav / eval log.
    Browser(BrowserPane),
    /// A workspace-wide LSP-diagnostics ("Problems") list.
    Diagnostics(DiagnosticsPane),
    /// A workspace-grep results list — browsable, jump-and-stay.
    Grep(GrepPane),
    /// Vim's quickfix list — same UI as `Grep` but a distinct pane so
    /// `:grep` results aren't clobbered when something else (an LSP
    /// references call, `:cexpr`, …) populates the quickfix.
    Quickfix(GrepPane),
    /// Vim's `q:` — a scrollable list of recent `:` cmdline entries.
    /// Enter re-fires the highlighted entry; Esc closes.
    CmdlineHistory(CmdlineHistoryPane),
    /// NvCheatsheet-style browseable list of every active chord → command,
    /// grouped by `Command::group`. `/`-filterable, scrollable. Opened
    /// via `view.cheatsheet` / `<leader>?`.
    Cheatsheet(CheatsheetPane),
    /// Live DAP session view — call stack + recent adapter output.
    /// `App.dap` is the source of truth; this pane is stateless beyond
    /// `{selected, scroll}`. Enter on a stack-frame row jumps the active
    /// editor to that frame's source line. Reads from
    /// `App.dap.stack_frames` + `App.dap_output_log`.
    Debug(DebugPane),
    /// DAP REPL — type an expression, see the adapter's `evaluate`
    /// result. Shares the watch-evaluation infrastructure but uses
    /// `context: "repl"` so adapters with REPL-specific shorthands
    /// (debugpy's `pp`, gdb's `info`) work as expected.
    DapRepl(DapReplPane),
    /// An image-file viewer (PNG/JPG/GIF/etc.). On terminals supporting
    /// the Kitty graphics or iTerm2 inline-image protocol, the image
    /// is painted over the pane's body via a post-ratatui escape
    /// emission. Otherwise the body shows a metadata-only placeholder.
    Image(ImagePane),
    /// Claude Code agents dashboard — one row per session.jsonl
    /// found under `~/.claude/projects/`, with live/idle/ended
    /// state, model, token spend, last user/assistant message, and
    /// PID where the session process is still running. Opened via
    /// `:ai.agents_dashboard`. v1 is read-only + browseable; v2
    /// will surface Enter-to-focus, transcript open, cancel, etc.
    ClaudeAgents(crate::claude_agents::ClaudeAgentsPane),
    /// A native WebSocket connection — top is a scrolling log of
    /// messages (← incoming / → outgoing), bottom is a single-line
    /// input where Enter sends. Multi-connection: each pane has
    /// its own worker thread + tungstenite socket. Opened via
    /// `:ws.connect`. Distinct from the scratch-buffer approach
    /// (v1) which only supported a single connection at a time.
    Websocket(crate::websocket::WebsocketPane),
    /// 2026-06-21 — `:ai.spend_today` now opens a real pane (was
    /// a Markdown scratch). Sortable per-workspace breakdown of
    /// tokens + cost in the last 24h. Click column headers (or
    /// press `s`) to cycle the sort key.
    SpendReport(SpendReportPane),
    /// A hosted integration tool — owns the pane's body via the Bridge
    /// tier-4 Mount protocol. The integration streams cell+style frames
    /// over a Unix socket; mnml stamps them into its own ratatui
    /// frame. Input flows the other way (key/mouse events forwarded
    /// when the pane has focus). See `src/mount.rs`.
    Mount(crate::mount::MountSession),
    /// Comprehensive view of a single cloud-agent run (ECS runner
    /// runner): ticket / flow / state header, web links (Jira, PR,
    /// CloudWatch console, S3 console), S3 artifacts list,
    /// CloudWatch logs viewport. Tail-follows when the run is
    /// still in flight; full historical fetch when it's done. See
    /// `src/cloud_agent_run.rs`.
    CloudAgentRun(crate::cloud_agent_run::CloudAgentRunPane),
    /// Multi-step wizard that fires a Cloud Agents run (Managed
    /// Agents OR ECS runner). Lives in the Cloud Agents panel,
    /// distinct from `NewCloudAgentWizard` which handles local
    /// Claude Code sessions from PR lists in the Agents panel.
    /// See `src/new_cloud_run_wizard.rs`.
    NewCloudRunWizard(crate::new_cloud_run_wizard::NewCloudRunWizardPane),
    /// Multi-step wizard that creates a new cloud agent run.
    /// Supports the existing ECS runner trigger path AND
    /// Anthropic's managed-agents API with cloud or self-hosted
    /// sandbox modes (per-machine local worker or remote
    /// Vercel/Cloudflare/Modal/etc). See
    /// `src/new_cloud_agent_wizard.rs`.
    NewCloudAgentWizard(crate::new_cloud_agent_wizard::NewCloudAgentWizardPane),
    /// 2026-07-31 — a VS-Code-extension-detail-style view of ONE
    /// integration. Description, byline, action buttons
    /// (Enable/Disable/Uninstall/Bake/Refresh + Edit manifest),
    /// declared palette commands, and Homepage / Repository /
    /// Docs links. Read-only apart from the buttons — never
    /// mutates the integration itself; every action dispatches
    /// through an existing command. Hosted in the right panel
    /// (same as Outline / Diagnostics), opened via
    /// `integrations.show_details`.
    IntegrationDetail(IntegrationDetailPane),
    /// 2026-08-16 — the Claude usage panel, ported from the old
    /// centered-modal overlay into a proper pane so it
    /// docks / splits / tabs like anything else. Same data source
    /// as the statusline chip (`App::ai_usage_claude_accounts`); scroll
    /// lives on the pane so long per-model scoped-limit lists can
    /// overflow. Opened via `ai.claude_usage`.
    ClaudeUsage(ClaudeUsagePane),
    /// 2026-08-16 — the Codex usage panel, split off from the shared
    /// `Pane::AiUsage` when Claude went multi-account (the two
    /// products' data shapes and refresh cadences diverged enough
    /// that one pane rendering both was doing neither justice).
    /// Opened via `ai.codex_usage`.
    CodexUsage(CodexUsagePane),
}

/// State for [`Pane::SpendReport`]. Re-snapshots
/// `claude_agents::spend_today()` every refresh; sort/scroll are
/// pane-local. Click on a header rect toggles asc/desc on that
/// column (mouse parity with `s` chord).
#[derive(Debug)]
pub struct SpendReportPane {
    pub snapshot: crate::claude_agents::SpendToday,
    pub built_at: std::time::SystemTime,
    pub selected: usize,
    pub scroll: usize,
    pub sort_by: SpendSortKey,
    pub sort_desc: bool,
    /// 2026-06-29 claude-agents-power-user SEV-2 follow-up: even
    /// with the 10MB-per-file cap, spend_today() can still take
    /// 1-2s on a machine with many active workspaces. Compute on
    /// a background thread and stream the result via mpsc — the
    /// pane shows "computing…" while pending is live, then
    /// swaps to the real snapshot when the worker finishes.
    /// `mnml::tick()` drains this on every loop iteration.
    pub pending: Option<std::sync::mpsc::Receiver<crate::claude_agents::SpendToday>>,
    /// True while a refresh is in flight. Renderer shows a hint
    /// in the title bar so the user knows it's not a stale view.
    pub loading: bool,
    /// code-reviewer 3rd 2026-06-29 W-3 fix: cooperative abort
    /// signal for the spend_today worker. Set on pane Drop /
    /// refresh so an in-flight worker stops reading multi-MB
    /// JSONL files for 1-2 seconds after the user closed the pane.
    pub abort_flag: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpendSortKey {
    Workspace,
    Tokens,
    Cost,
}

impl SpendSortKey {
    pub fn label(self) -> &'static str {
        match self {
            SpendSortKey::Workspace => "workspace",
            SpendSortKey::Tokens => "tokens",
            SpendSortKey::Cost => "cost",
        }
    }
    pub fn cycle(self) -> Self {
        match self {
            SpendSortKey::Workspace => SpendSortKey::Tokens,
            SpendSortKey::Tokens => SpendSortKey::Cost,
            SpendSortKey::Cost => SpendSortKey::Workspace,
        }
    }
}

impl Drop for SpendReportPane {
    fn drop(&mut self) {
        // code-reviewer 3rd 2026-06-29 W-3: tell the worker to
        // stop. The Arc clone the worker holds reads this flag
        // between every file; it'll exit at the next check.
        self.abort_flag
            .store(true, std::sync::atomic::Ordering::Relaxed);
    }
}

impl SpendReportPane {
    pub fn fresh() -> Self {
        let abort_flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (tx, rx) = std::sync::mpsc::channel();
        let abort_clone = abort_flag.clone();
        std::thread::spawn(move || {
            let _ = tx.send(crate::claude_agents::spend_today_with_abort(Some(
                abort_clone,
            )));
        });
        Self {
            snapshot: crate::claude_agents::SpendToday::default(),
            built_at: std::time::SystemTime::now(),
            selected: 0,
            scroll: 0,
            sort_by: SpendSortKey::Cost,
            sort_desc: true,
            pending: Some(rx),
            loading: true,
            abort_flag,
        }
    }
    pub fn refresh(&mut self) {
        // Signal the prior worker to abort. It'll stop at the next
        // per-file check (within ~10MB / a few hundred ms in the
        // worst case).
        self.abort_flag
            .store(true, std::sync::atomic::Ordering::Relaxed);
        // Fresh abort flag for the new worker.
        let abort_flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (tx, rx) = std::sync::mpsc::channel();
        let abort_clone = abort_flag.clone();
        std::thread::spawn(move || {
            let _ = tx.send(crate::claude_agents::spend_today_with_abort(Some(
                abort_clone,
            )));
        });
        self.abort_flag = abort_flag;
        self.pending = Some(rx);
        self.loading = true;
    }
    /// 2026-06-29: drain the background channel if a worker has
    /// finished. Called from `App::tick` so the pane swaps to
    /// the real snapshot without the user needing to do anything.
    /// Returns `true` when a snapshot just arrived — caller uses
    /// this to fire a totals toast (claude-agents 3rd 2026-06-29
    /// SEV-3: the totals toast was unreachable because the inline
    /// toast at fire-time always saw loading=true).
    pub fn poll_pending(&mut self) -> bool {
        if let Some(rx) = self.pending.as_ref()
            && let Ok(snap) = rx.try_recv()
        {
            self.snapshot = snap;
            self.built_at = std::time::SystemTime::now();
            self.pending = None;
            self.loading = false;
            if self.selected >= self.snapshot.per_workspace.len() {
                self.selected = self.snapshot.per_workspace.len().saturating_sub(1);
            }
            return true;
        }
        false
    }
    /// Return the rows sorted by current sort_by/sort_desc. Stable.
    pub fn sorted_rows(&self) -> Vec<(String, u64, f64)> {
        let mut v = self.snapshot.per_workspace.clone();
        match self.sort_by {
            SpendSortKey::Workspace => v.sort_by(|a, b| a.0.cmp(&b.0)),
            SpendSortKey::Tokens => v.sort_by_key(|a| a.1),
            SpendSortKey::Cost => {
                v.sort_by(|a, b| a.2.partial_cmp(&b.2).unwrap_or(std::cmp::Ordering::Equal))
            }
        }
        if self.sort_desc {
            v.reverse();
        }
        v
    }
}

/// State for [`Pane::DapRepl`]. `input` is the single-line entry;
/// `history` holds `(expression, value_or_error)` pairs in arrival
/// order (newest at the bottom). Scroll is row-based; usize::MAX ⇒
/// pinned to tail. Up/Down walk command history (Vec re-uses the
/// same expression strings).
#[derive(Debug, Clone, Default)]
pub struct DapReplPane {
    pub input: String,
    pub cursor: usize,
    pub history: Vec<DapReplEntry>,
    /// Command history for the Up/Down chord — distinct from
    /// `history` since failed evals shouldn't replay.
    pub command_history: Vec<String>,
    pub command_history_idx: Option<usize>,
    /// Top rendered row (in `history`). `usize::MAX` ⇒ follow tail.
    pub scroll: usize,
    /// Which history entry the `o` (expand) chord acts on. `None` ⇒
    /// no selection (the user hasn't moved focus off the input).
    /// Set when the user moves the selection with PgUp / Shift+Up.
    pub selected: Option<usize>,
    /// `/` filter — narrows history to entries whose expression
    /// fuzzy-matches the query. Mirrors the cookies / storage / net /
    /// DOM panel filter UX. While `filter_mode == true`, printable
    /// keys feed `filter` instead of `input`; Enter exits filter mode
    /// keeping the narrow; Esc clears + exits.
    pub filter: String,
    pub filter_mode: bool,
}

impl DapReplPane {
    /// History indices (into `self.history`) that match the current
    /// `filter` via fuzzy match against `entry.expression`. Empty filter
    /// returns every index. Used by both the renderer and the selection
    /// movement code so `selected` always indexes the filtered view.
    pub fn visible_history_indices(&self) -> Vec<usize> {
        if self.filter.is_empty() {
            return (0..self.history.len()).collect();
        }
        let q = &self.filter;
        self.history
            .iter()
            .enumerate()
            .filter(|(_, e)| crate::fuzzy::fuzzy_match(q, &e.expression).is_some())
            .map(|(i, _)| i)
            .collect()
    }
}

/// One row in the REPL history. `err` is set when the adapter
/// rejected the expression; otherwise `value` carries the formatted
/// result (and `ty` is the type when known).
#[derive(Debug, Clone)]
pub struct DapReplEntry {
    pub expression: String,
    pub value: String,
    pub ty: Option<String>,
    pub err: Option<String>,
    /// True while waiting for the adapter to reply. Renders as a dim
    /// "evaluating..." placeholder; flipped off when the matching
    /// `DapEvent::Evaluate` lands.
    pub pending: bool,
    /// Non-zero ⇒ the result is a composite (struct / object / array)
    /// and can be lazy-expanded via `variables(variables_ref)`. The
    /// reply lands on `DapManager.variables` keyed by ref. The user
    /// triggers the expansion via `o` (open) on the REPL row.
    pub variables_ref: i64,
    /// True ⇒ the user expanded this row + the variables landed.
    /// Children render indented below the value row. Toggled by `o`.
    pub expanded: bool,
}

/// Which sub-section of the debug pane has the keyboard. j/k/PgUp/etc.
/// move within the focused section; Tab cycles. Variables-section
/// keys also drive Enter (expand/collapse) so the dispatcher needs to
/// know which list it's targeting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DebugSection {
    #[default]
    Stack,
    Variables,
}

/// State for the live-DAP `Pane::Debug` — pure UI cursor; underlying
/// data lives on `App.dap`.
#[derive(Debug, Clone, Default)]
pub struct DebugPane {
    /// Selected stack-frame index (into `App.dap.stack_frames`).
    pub selected: usize,
    /// Scroll offset for the call-stack list.
    pub scroll: usize,
    /// Scroll offset for the output log section.
    pub output_scroll: usize,
    /// Selected row in the variables panel (into `mgr.variable_rows()`).
    pub vars_selected: usize,
    /// Scroll offset for the variables panel.
    pub vars_scroll: usize,
    /// Which sub-section (call stack vs variables) takes keyboard.
    pub section: DebugSection,
}

/// State for [`Pane::IntegrationDetail`] — the VS-Code-extension-
/// detail-page equivalent for one mnml integration.
///
/// Owns nothing but the integration's `id` + a cursor into the
/// button row. Everything visible on screen (name / description /
/// version / commands / links) is resolved on each `draw()` from
/// `App.config.ui.integration_icons` so a manifest refresh or a
/// user toggle is picked up without touching pane state.
///
/// `last_action_toast` is a per-pane one-shot for post-click
/// feedback ("Enabled", "Manifest opened", …) that the pane
/// renders inline so the user sees confirmation next to the
/// button, not just at the bottom of the screen.
#[derive(Debug, Clone)]
pub struct IntegrationDetailPane {
    /// Stable integration id. Immutable for the life of the pane
    /// — a different integration = a different pane.
    pub id: String,
    /// Cursor into the pane's actionable-button list. Row order:
    /// `[Enable/Disable] [Uninstall] [Bake glyph] [Refresh] [Edit
    /// manifest] [Copy id]` followed by one row per link, one row
    /// per command. Rebuilt on every draw so unavailable buttons
    /// (e.g. Bake when the glyph has no codepoint) are skipped.
    pub cursor: usize,
    /// Optional inline confirmation after the last button fire.
    /// Cleared by the pane after `TOAST_TTL` seconds — see
    /// `integration_detail_view::draw`.
    pub last_action: Option<(std::time::Instant, String)>,
    /// Per-pane scroll offset — advances 1 row per wheel notch.
    /// Rich detail (README body) can overflow the pane; scroll
    /// lets the user reach the tail without shrinking the pane.
    pub scroll: usize,
}

impl IntegrationDetailPane {
    pub fn new(id: String) -> Self {
        Self {
            id,
            cursor: 0,
            last_action: None,
            scroll: 0,
        }
    }
    /// Short chrome for the bufferline tab / right-panel tab strip.
    pub fn tab_title(&self) -> String {
        format!("Integration · {}", self.id)
    }
    /// Called by the App after a button dispatches. Renders as an
    /// inline "✓ {msg}" line under the button strip for a few
    /// seconds.
    pub fn set_action_toast(&mut self, msg: impl Into<String>) {
        self.last_action = Some((std::time::Instant::now(), msg.into()));
    }
}

/// State for [`Pane::ClaudeUsage`] — nothing but a scroll offset.
/// The underlying data lives in `App::ai_usage_claude_accounts`;
/// the pane is stateless beyond scroll so the App can hot-swap the
/// usage snapshot (fetcher pushes new frames every 5 min) without
/// touching the pane.
#[derive(Debug, Clone, Default)]
pub struct ClaudeUsagePane {
    pub scroll: usize,
}

impl ClaudeUsagePane {
    pub fn new() -> Self {
        Self { scroll: 0 }
    }
    pub fn tab_title(&self) -> String {
        "Claude Usage".to_string()
    }
}

/// State for [`Pane::CodexUsage`] — nothing but a scroll offset.
/// The underlying data lives in `App::ai_usage_codex` (a single
/// snapshot; Codex is per-machine, no multi-account concept).
#[derive(Debug, Clone, Default)]
pub struct CodexUsagePane {
    pub scroll: usize,
}

impl CodexUsagePane {
    pub fn new() -> Self {
        Self { scroll: 0 }
    }
    pub fn tab_title(&self) -> String {
        "Codex Usage".to_string()
    }
}

/// Vim's command-line window — `q:` opens a read-only list of recent ex
/// commands. Up/Down navigate; Enter re-fires the selected entry.
#[derive(Debug, Clone, Default)]
pub struct CmdlineHistoryPane {
    pub entries: Vec<String>,
    pub selected: usize,
    pub scroll: usize,
}

impl CmdlineHistoryPane {
    pub fn from_history(entries: &[String]) -> Self {
        // Newest entries first.
        let entries: Vec<String> = entries.iter().rev().cloned().collect();
        CmdlineHistoryPane {
            entries,
            selected: 0,
            scroll: 0,
        }
    }
    pub fn move_selection(&mut self, delta: isize) {
        if self.entries.is_empty() {
            return;
        }
        let max = self.entries.len() as isize - 1;
        self.selected = ((self.selected as isize + delta).clamp(0, max)) as usize;
    }
    pub fn selected_entry(&self) -> Option<&str> {
        self.entries.get(self.selected).map(String::as_str)
    }
}

pub struct MdPreview {
    pub path: PathBuf,
    /// Replaceable preview tab, like `Buffer::is_preview`.
    ///
    /// Markdown opens as THIS pane rather than an editor, and the flag
    /// only existed on `Buffer` — so previewing a `.md` file from the
    /// tree produced a permanent tab: never italic, never replaced by
    /// the next preview. Arrowing past five markdown files left five
    /// tabs (user report: End on TODO.md, "notice its not italic").
    pub is_preview: bool,
    pub source: String,
    pub scroll: usize,
    /// Cache of loaded images for inline embedding. Keyed by the absolute
    /// resolved path. Cleared when the source's image set changes
    /// (entries no longer referenced are dropped).
    pub image_cache: std::collections::HashMap<PathBuf, crate::image::ImageData>,
    /// External-renderer cache (glow / custom cmd). Empty on the
    /// builtin path. See `ui::md_preview_external::ExternalCache`.
    /// 2026-07-07.
    pub external_cache: crate::ui::md_preview_external::ExternalCache,
    /// One-shot toast latch — flips true after the first failed
    /// external render so we don't spam toasts every frame while
    /// the tool is missing. Cleared when the engine config changes.
    pub external_error_toasted: bool,
}

impl MdPreview {
    pub fn title(&self) -> String {
        let name = self
            .path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "markdown".to_string());
        // Just the filename. The rendered-preview marker is appended by
        // the bufferline, which can honour `[ui] ascii_icons` — this
        // function cannot see the config, and the marker used to be a
        // hardcoded `◳` that matched nothing else in the UI.
        name
    }

    /// Approximate cursor-tracking — scroll the preview so it lines up with
    /// the source buffer's cursor row. Uses a heading-aware heuristic: for
    /// each source line above `src_row`, count rendered rows as 1 for body
    /// lines and 2 for heading-introducing lines (`#…`) to mimic the
    /// renderer's padding around headings. Then clamp scroll to that count.
    pub fn sync_to_source_row(&mut self, src_row: usize) {
        let mut rendered = 0usize;
        for (i, line) in self.source.lines().enumerate() {
            if i >= src_row {
                break;
            }
            let t = line.trim_start();
            rendered += if t.starts_with('#') { 2 } else { 1 };
        }
        self.scroll = rendered;
    }
}

/// What a [`DiffView`] is showing.
#[derive(Debug, Clone)]
pub enum DiffScope {
    /// Unstaged changes — `git diff` for one file (`Some`) or the whole worktree.
    Unstaged(Option<PathBuf>),
    /// Staged changes — `git diff --cached`. `None` ⇒ all staged
    /// files; `Some(path)` ⇒ just that file.
    Staged,
    /// Staged changes for one file — `git diff --cached -- <path>`.
    /// Separate variant (rather than `Staged(Option<PathBuf>)`) so
    /// existing match arms that ignore the bare `Staged` variant
    /// don't silently pick up file-scoped diffs.
    StagedFile(PathBuf),
    /// The diff a commit introduced — `git show <hash>` (read-only, no staging).
    Commit(String),
    /// One file's contribution to a commit — `git show <hash> -- <rel>`
    /// (read-only, no staging). Carries the workspace-relative path so
    /// the title + the underlying command can use the same string.
    CommitFile { hash: String, rel_path: PathBuf },
    /// Buffer text vs its on-disk version (vim `:DiffOrig` shape).
    /// Read-only — hunks can't be staged.
    BufferVsDisk(PathBuf),
    /// `git diff HEAD` — every change vs the last commit, covering BOTH
    /// staged and unstaged. The diffview-style "show me everything I've
    /// changed across the workspace" entry-point.
    AllVsHead,
}

/// How a `DiffView` lays out its hunks visually. Cycle through with
/// the top-of-pane `[Inline] [Hunk] [Split]` buttons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum DiffViewMode {
    /// Unified inline rendering — `+` / `-` / context lines in a
    /// single column. The default (and the only mode pre-2026-05-18).
    #[default]
    Inline,
    /// Per-hunk collapsed view — every hunk renders only its header,
    /// surfacing structure across many hunks. Click a header to open
    /// just that hunk inline.
    Hunk,
    /// Side-by-side rendering — old on the left, new on the right.
    Split,
}

pub struct DiffView {
    pub scope: DiffScope,
    pub hunks: Vec<Hunk>,
    /// Top rendered row.
    pub scroll: usize,
    /// The "current" hunk index (what `s`/`u` act on, what `n`/`p` move).
    pub cursor: usize,
    /// Visual layout — `[Inline] [Hunk] [Split]` button selection.
    pub view_mode: DiffViewMode,
    /// True when long lines wrap to the pane width (`[Wrap]` button
    /// toggled on). Default off — clips long lines (the legacy
    /// behavior). Only meaningful for Inline + Hunk modes; Splitumn
    /// mode already constrains per-side width.
    pub wrap: bool,
    /// In `Hunk` mode, the set of hunk indices the user has
    /// collapsed. Hunks default to expanded — click a chevron to
    /// collapse one you don't care about.
    pub hunk_collapsed: std::collections::HashSet<usize>,
    /// Full-file-context hunks used by Splitumn rendering — the
    /// whole before/after of each file in one big "hunk" so the user
    /// sees unchanged surroundings too. Lazily fetched on first
    /// Split render; cleared on refresh.
    pub full_hunks: Option<Vec<Hunk>>,
    /// `/`-filter query — non-empty when the user is narrowing the
    /// diff body. Tinted-yellow highlight on every match; navigated
    /// via `n` / `N`. Cleared on Esc.
    pub filter: String,
    /// True while the filter input is accepting keystrokes (after
    /// `/`, before Enter / Esc). The renderer shows a `/<query>_`
    /// chip in the header when active.
    pub filter_mode: bool,
}

impl DiffView {
    pub fn new(scope: DiffScope, hunks: Vec<Hunk>) -> Self {
        DiffView {
            scope,
            hunks,
            scroll: 0,
            cursor: 0,
            view_mode: DiffViewMode::Inline,
            wrap: false,
            hunk_collapsed: std::collections::HashSet::new(),
            full_hunks: None,
            filter: String::new(),
            filter_mode: false,
        }
    }
    pub fn title(&self) -> String {
        match &self.scope {
            DiffScope::Unstaged(Some(p)) => format!(
                "diff: {}",
                p.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            ),
            DiffScope::Unstaged(None) => "diff: worktree".to_string(),
            DiffScope::Staged => "diff: staged".to_string(),
            DiffScope::StagedFile(p) => format!(
                "staged: {}",
                p.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            ),
            DiffScope::Commit(h) => format!("commit {}", h.chars().take(9).collect::<String>()),
            DiffScope::CommitFile { hash, rel_path } => format!(
                "{} @ {}",
                rel_path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| rel_path.display().to_string()),
                hash.chars().take(9).collect::<String>()
            ),
            DiffScope::BufferVsDisk(p) => format!(
                "buffer vs disk: {}",
                p.file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default()
            ),
            DiffScope::AllVsHead => "diff: all vs HEAD".to_string(),
        }
    }
}

impl Pane {
    /// Short title for the bufferline tab.
    pub fn title(&self) -> String {
        match self {
            Pane::Editor(b) => b.display_name(),
            Pane::MdPreview(p) => p.title(),
            Pane::Diff(d) => d.title(),
            Pane::GitGraph(g) => g.tab_title(),
            Pane::GitStatus(g) => g.tab_title(),
            Pane::Request(r) => r.title(),
            Pane::Pty(s) => s.title(),
            Pane::Ai(a) => a.tab_title(),
            Pane::Tests(t) => t.tab_title(),
            Pane::Flaky(f) => f.tab_title(),
            Pane::Outline(o) => o.tab_title(),
            Pane::Files(f) => f.tab_title(),
            Pane::Browser(b) => b.tab_title(),
            Pane::Diagnostics(d) => d.tab_title(),
            Pane::Grep(g) => g.tab_title(),
            Pane::Quickfix(g) => format!("Quickfix · {}", g.hits.len()),
            Pane::CmdlineHistory(_) => "q:".to_string(),
            Pane::Cheatsheet(_) => "Cheatsheet".to_string(),
            Pane::Debug(_) => "Debug".to_string(),
            Pane::DapRepl(_) => "DAP REPL".to_string(),
            Pane::Image(p) => p.tab_title(),
            Pane::ClaudeAgents(p) => p.tab_title(),
            Pane::Websocket(p) => p.tab_title(),
            Pane::SpendReport(_) => "AI spend (24h)".to_string(),
            Pane::Mount(m) => m.label.clone(),
            Pane::CloudAgentRun(p) => format!("☁ {}", p.ticket),
            Pane::NewCloudAgentWizard(_) => "+ New Agent from PR".to_string(),
            Pane::NewCloudRunWizard(_) => "+ New Cloud Run".to_string(),
            Pane::IntegrationDetail(d) => d.tab_title(),
            Pane::ClaudeUsage(p) => p.tab_title(),
            Pane::CodexUsage(p) => p.tab_title(),
        }
    }

    /// True if the pane has unsaved changes (drives the `●` marker).
    pub fn is_dirty(&self) -> bool {
        match self {
            Pane::Editor(b) => b.dirty,
            Pane::MdPreview(_)
            | Pane::Diff(_)
            | Pane::GitGraph(_)
            | Pane::GitStatus(_)
            | Pane::Request(_)
            | Pane::Pty(_)
            | Pane::Ai(_)
            | Pane::Tests(_)
            | Pane::Flaky(_)
            | Pane::Outline(_)
            | Pane::Files(_)
            | Pane::Browser(_)
            | Pane::Diagnostics(_)
            | Pane::Grep(_)
            | Pane::Quickfix(_)
            | Pane::CmdlineHistory(_)
            | Pane::Cheatsheet(_)
            | Pane::Debug(_)
            | Pane::DapRepl(_)
            | Pane::Image(_)
            | Pane::ClaudeAgents(_)
            | Pane::Websocket(_)
            | Pane::SpendReport(_)
            | Pane::Mount(_)
            | Pane::CloudAgentRun(_)
            | Pane::NewCloudAgentWizard(_)
            | Pane::NewCloudRunWizard(_)
            | Pane::IntegrationDetail(_)
            | Pane::ClaudeUsage(_)
            | Pane::CodexUsage(_) => false,
        }
    }

    pub fn as_editor(&self) -> Option<&Buffer> {
        match self {
            Pane::Editor(b) => Some(b),
            _ => None,
        }
    }

    pub fn as_editor_mut(&mut self) -> Option<&mut Buffer> {
        match self {
            Pane::Editor(b) => Some(b),
            _ => None,
        }
    }
}
