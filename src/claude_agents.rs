//! Claude Code agents dashboard pane — `Pane::ClaudeAgents`.
//!
//! Scans `~/.claude/projects/<encoded-workspace>/<session_id>.jsonl`
//! for every session and tail-parses the last ~50 events to derive
//! one row per session:
//!
//!   workspace · short session id · model · state · age · tokens
//!
//! Cross-references `pgrep -af claude` (cmdline parse) so rows for
//! actually-running processes get a PID + a "live" badge.
//!
//! v1: read-only dashboard. Actions (Enter to focus, t to open
//! transcript, c to cancel, y to yank session id, r to refresh)
//! live on the App / pane key handler — see App::open_claude_agents.
//!
//! Implementation notes:
//!  * The full .jsonl files run hundreds of MB on long sessions —
//!    we stream the last N lines via a 64KB tail buffer, not a
//!    full read.
//!  * The Anthropic project path is `~/.claude/projects/<encoded>`
//!    where `encoded` is `/Users/foo/Projects/bar` → `-Users-foo-Projects-bar`.
//!    Reverse mapping isn't perfect (a literal `-` in a path becomes
//!    ambiguous) but the dashboard treats the encoded form as the
//!    workspace label for display purposes.

use std::path::PathBuf;
use std::time::SystemTime;

/// Which CLI agent backend a row comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentSource {
    /// Claude Code — `~/.claude/projects/<encoded>/<sid>.jsonl`,
    /// `claude --session-id <uuid>` pgrep target.
    Claude,
    /// OpenAI Codex CLI — `~/.codex/sessions/<sid>.jsonl` (when
    /// present; the dashboard falls back to PID-only when not).
    /// pgrep matches the `codex` exe.
    Codex,
}

impl AgentSource {
    pub fn label(self) -> &'static str {
        match self {
            AgentSource::Claude => "claude",
            AgentSource::Codex => "codex",
        }
    }
    pub fn exe_name(self) -> &'static str {
        match self {
            AgentSource::Claude => "claude",
            AgentSource::Codex => "codex",
        }
    }
}

/// User actions invokable on the selected row.
#[derive(Debug, Clone, Copy)]
pub enum ClaudeAgentsAction {
    YankSessionId,
    YankCwd,
    OpenTranscript,
    /// Open a confirm prompt before SIGTERM'ing the row's PID.
    KillPrompt,
    /// Spawn `claude --resume <session_id>` in a new pty pane in
    /// the row's `cwd` (or the current workspace if cwd is missing).
    /// For codex rows, opens `codex` (no resume — stateless).
    ResumeSession,
    /// Export the focused row's transcript as markdown into the
    /// current workspace's `.mnml/claude-exports/` and open it in
    /// an editor pane.
    ExportMarkdown,
}

/// One session in the dashboard.
#[derive(Debug, Clone)]
pub struct AgentRow {
    /// Which CLI agent this row comes from.
    pub source: AgentSource,
    /// Absolute path to the .jsonl transcript (may be a sentinel
    /// for Codex rows when no transcript file is available — check
    /// `transcript_path.is_file()` before opening).
    pub transcript_path: PathBuf,
    /// Session id (UUID, no `.jsonl`).
    pub session_id: String,
    /// Decoded workspace label (`-Users-foo-Projects-bar` → `bar`
    /// for display).
    pub workspace: String,
    /// Last seen `cwd` field from any event (richer than the
    /// encoded directory).
    pub cwd: Option<String>,
    /// Last seen `gitBranch` from any event.
    pub git_branch: Option<String>,
    /// Most recent assistant `message.model`.
    pub model: Option<String>,
    /// Most recent event's timestamp (as a system time).
    pub last_activity: Option<SystemTime>,
    /// Sum of `usage.input_tokens + output_tokens` across every
    /// assistant event in the tail window. Lower-bound estimate
    /// if the tail truncated.
    pub tokens: u64,
    /// Input tokens (sum across the tail window).
    pub input_tokens: u64,
    /// Output tokens (sum across the tail window).
    pub output_tokens: u64,
    /// Cache-creation input tokens (5m/1h ephemeral). Billed full
    /// rate on creation, then 10% on subsequent reads — we attribute
    /// at write rate here (so the cost shows the upper bound).
    pub cache_create_tokens: u64,
    /// Cache-read input tokens (10% rate).
    pub cache_read_tokens: u64,
    /// Estimated USD cost based on a hardcoded per-model pricing
    /// table. Lower bound when the tail window truncated, or `0.0`
    /// when the model is unknown.
    pub cost_usd: f64,
    /// Total events in the tail window.
    pub event_count: usize,
    /// First non-empty text from the most recent user `message`.
    pub last_user_msg: Option<String>,
    /// First text block from the most recent assistant message,
    /// or `(<tool_use>: <name>)` if the last assistant turn was
    /// a tool call.
    pub last_assistant_msg: Option<String>,
    /// PID if `pgrep claude` matched this session's id.
    pub pid: Option<u32>,
    /// Derived activity state for the row badge.
    pub state: AgentState,
    /// Tool name from the last assistant tool_use block (e.g.
    /// "Bash", "Edit", "Agent"), when `state == ToolCall`.
    pub current_tool: Option<String>,
    /// Most recent TodoList state (from a TaskCreate/TodoWrite
    /// tool_use input in the tail).
    pub todos: Vec<TodoEntry>,
    /// Recent Bash commands run in this session (newest first,
    /// max 10).
    pub recent_bash: Vec<String>,
    /// Recent Edit/Write/NotebookEdit files (newest first, max 10).
    pub recent_files: Vec<RecentFile>,
    /// Recent Agent (subagent) dispatches (newest first, max 5).
    pub recent_subagents: Vec<String>,
    /// Pending tool_use ids — assistant emitted a tool_use that
    /// hasn't gotten a matching tool_result back yet. Lower bound;
    /// useful as a "waiting on you to confirm" badge counter.
    pub pending_tool_uses: usize,
    /// Tokens/min, derived by diff'ing this row's `tokens` against
    /// the previous refresh sample (`token_samples` on the pane).
    /// `None` when there's no prior sample yet, or when the rate is
    /// effectively zero. Only populated for live sessions.
    pub tokens_per_min: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentState {
    /// `pgrep` matched + last event within the last 60s.
    Streaming,
    /// `pgrep` matched but last event >60s ago.
    Idle,
    /// `pgrep` did NOT match — the process exited. Transcript is
    /// historical.
    Ended,
    /// Last assistant turn was a tool_use without a matching
    /// tool_result yet. (Best-effort — full pairing is expensive.)
    ToolCall,
}

impl AgentRow {
    /// Compact state badge — when the row is in ToolCall state and
    /// we know the tool name, surfaces it (`▸ Bash`); otherwise falls
    /// back to the generic badge.
    pub fn state_badge(&self) -> String {
        if matches!(self.state, AgentState::ToolCall)
            && let Some(name) = &self.current_tool
        {
            let short: String = name.chars().take(8).collect();
            return format!("▸ {short}");
        }
        self.state.badge().to_string()
    }
}

impl AgentState {
    pub fn badge(self) -> &'static str {
        match self {
            AgentState::Streaming => "● live",
            AgentState::Idle => "○ idle",
            AgentState::Ended => "· ended",
            AgentState::ToolCall => "▸ tool",
        }
    }
}

/// Which detail-panel view to show under the row list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DetailView {
    /// Default — last user msg + last assistant msg + meta.
    Summary,
    /// Most recent TodoList from a TaskCreate/TodoWrite event.
    Todos,
    /// Recent files touched via Edit/Write.
    Files,
    /// Recent Bash commands run.
    Bash,
    /// Recent Agent (subagent) dispatches.
    Subagents,
}

impl DetailView {
    pub fn label(self) -> &'static str {
        match self {
            DetailView::Summary => "Summary",
            DetailView::Todos => "Todos",
            DetailView::Files => "Files",
            DetailView::Bash => "Bash",
            DetailView::Subagents => "Agents",
        }
    }
    pub fn cycle(self) -> Self {
        match self {
            DetailView::Summary => DetailView::Todos,
            DetailView::Todos => DetailView::Files,
            DetailView::Files => DetailView::Bash,
            DetailView::Bash => DetailView::Subagents,
            DetailView::Subagents => DetailView::Summary,
        }
    }
}

pub struct ClaudeAgentsPane {
    pub rows: Vec<AgentRow>,
    pub selected: usize,
    /// Vim `gg` first-press latch. When true, the next `g` jumps
    /// to the top and clears the flag. A non-`g` key clears it
    /// silently. 2026-06-21 nvchad SEV-2 chord-collision fix.
    pub pending_g: bool,
    /// When the snapshot was last built — used by App::tick to
    /// rate-limit auto-refresh and shown in the title.
    pub built_at: SystemTime,
    /// `/` filter — narrows rows by workspace / id / model /
    /// last-msg substring. Lowercase substring match.
    pub query: String,
    pub filter_mode: bool,
    /// Which drill-down view shows under the row list.
    pub detail: DetailView,
    /// True to suppress auto-refresh (e.g. user is typing into the
    /// filter input, or the user toggled `p`).
    pub paused: bool,
    /// User-toggled pause (separate from `paused`, which is also
    /// set by filter-mode entry/exit so the user's preference
    /// isn't clobbered).
    pub paused_by_user: bool,
    /// Filter rows to one specific state (1/2/3/4 chord). `None` =
    /// show all.
    pub state_filter: Option<AgentState>,
    /// Filter rows to a specific source (Claude / Codex). `None` =
    /// show both. Cycled by `>` / `<`.
    pub source_filter: Option<AgentSource>,
    /// Filter rows to sessions whose cwd is inside the user's
    /// current mnml workspace. Toggled by `w`. Lets you focus on
    /// "what's running in THIS project" when several projects
    /// have active CC sessions side by side.
    pub workspace_only: bool,
    /// The workspace path the pane was opened in — used by
    /// `workspace_only`. Set by `App::open_claude_agents_pane`.
    pub anchor_workspace: PathBuf,
    /// Toggle the `?` help overlay rendered above the row list.
    pub show_help: bool,
    /// Scroll offset within the drill-down panel — for lists too
    /// long to fit (Bash history, recent files, todos). Reset to 0
    /// when the user picks a different row or cycles `v`.
    pub detail_scroll: usize,
    /// Last time the SELECTED row was re-tailed (live tail). The
    /// global refresh runs every 3s and rebuilds the row set; this
    /// tracks the more-frequent (every-tick) per-row poll that
    /// keeps the drill-down feeling alive on the active session.
    pub last_live_tail: SystemTime,
    /// `(session_id → (state, pending_tool_uses))` snapshot taken
    /// after every refresh. `refresh_in_place` compares the new
    /// snapshot to the previous one and surfaces transitions as
    /// toasts (`prior_state_snapshot` is empty on first build to
    /// avoid spamming the user on dashboard open).
    pub prior_state_snapshot: std::collections::HashMap<String, (AgentState, usize)>,
    /// `(session_id → ring of (sample_time, tokens))` — used to
    /// derive `tokens_per_min` as a moving average over the last
    /// few samples. Capped at `TOKEN_SAMPLE_RING` entries per
    /// session; oldest fall off.
    pub token_samples:
        std::collections::HashMap<String, std::collections::VecDeque<(SystemTime, u64)>>,
    /// PIDs we've sent SIGTERM to, with the timestamp. Polled on
    /// the next refresh: if the PID is still alive 2s+ after our
    /// TERM, escalate to SIGKILL.
    pub kill_escalation: std::collections::HashMap<u32, SystemTime>,
    /// `(session_id → (last_seen_file_size, lifetime_tokens,
    /// lifetime_cost_usd))`. The tail-window parse can under-count
    /// on long sessions whose tail truncated; this cache stores
    /// the full-file totals from the first read and incrementally
    /// updates them on each refresh by reading only the new bytes.
    pub lifetime_cache: std::collections::HashMap<String, LifetimeTotals>,
    /// Multi-select set — `space` toggles a row's session id into
    /// this set; `K` kills every row in the set (falling back to
    /// the focused row when the set is empty).
    pub multi_selected: std::collections::HashSet<String>,
    /// Grouping mode for section headers in the row list. `g`
    /// cycles between source (current default) and workspace.
    pub group_by: GroupBy,
    /// Sort key for rows within each section. `s` cycles.
    pub sort_by: SortBy,
}

/// How rows are ordered within each section.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortBy {
    /// State first (live → tool → idle → ended), then activity. v1 default.
    StateActivity,
    /// Highest token spend first.
    TokensDesc,
    /// Highest cost first.
    CostDesc,
    /// Most recent activity first.
    ActivityDesc,
}

impl SortBy {
    pub fn label(self) -> &'static str {
        match self {
            SortBy::StateActivity => "state",
            SortBy::TokensDesc => "tokens↓",
            SortBy::CostDesc => "cost↓",
            SortBy::ActivityDesc => "recent",
        }
    }
    pub fn cycle(self) -> Self {
        match self {
            SortBy::StateActivity => SortBy::TokensDesc,
            SortBy::TokensDesc => SortBy::CostDesc,
            SortBy::CostDesc => SortBy::ActivityDesc,
            SortBy::ActivityDesc => SortBy::StateActivity,
        }
    }
}

/// Section grouping for the row list — what the colored section
/// headers between row blocks indicate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupBy {
    /// One section per `AgentSource` (Claude / Codex). v1 default.
    Source,
    /// One section per workspace (cwd basename). Useful when you've
    /// got several projects with multiple sessions each.
    Workspace,
}

impl GroupBy {
    pub fn label(self) -> &'static str {
        match self {
            GroupBy::Source => "source",
            GroupBy::Workspace => "workspace",
        }
    }
    pub fn cycle(self) -> Self {
        match self {
            GroupBy::Source => GroupBy::Workspace,
            GroupBy::Workspace => GroupBy::Source,
        }
    }
}

impl ClaudeAgentsPane {
    pub fn build() -> Self {
        Self::build_anchored(PathBuf::new())
    }

    /// Build with an anchor workspace path stored so the `w`
    /// workspace-only filter has something to compare cwds
    /// against.
    pub fn build_anchored(anchor: PathBuf) -> Self {
        let claude_pids = scan_running_pids(AgentSource::Claude);
        let codex_pids = scan_running_pids(AgentSource::Codex);
        let mut rows = collect_rows(&claude_pids);
        rows.extend(collect_codex_rows(&codex_pids));
        rows.sort_by(|a, b| {
            state_rank(a.state)
                .cmp(&state_rank(b.state))
                .then_with(|| b.last_activity.cmp(&a.last_activity))
        });
        let mut pane = ClaudeAgentsPane::empty_with_rows(rows);
        pane.anchor_workspace = anchor;
        pane.merge_lifetime_totals();
        pane.recompute_token_rates();
        pane
    }

    fn empty_with_rows(rows: Vec<AgentRow>) -> Self {
        ClaudeAgentsPane {
            rows,
            selected: 0,
            pending_g: false,
            built_at: SystemTime::now(),
            query: String::new(),
            filter_mode: false,
            detail: DetailView::Summary,
            paused: false,
            paused_by_user: false,
            state_filter: None,
            source_filter: None,
            workspace_only: false,
            anchor_workspace: PathBuf::new(),
            sort_by: SortBy::StateActivity,
            show_help: false,
            detail_scroll: 0,
            last_live_tail: SystemTime::now(),
            prior_state_snapshot: std::collections::HashMap::new(),
            token_samples: std::collections::HashMap::new(),
            kill_escalation: std::collections::HashMap::new(),
            lifetime_cache: std::collections::HashMap::new(),
            multi_selected: std::collections::HashSet::new(),
            group_by: GroupBy::Source,
        }
    }

    /// For each Claude row, update `lifetime_cache` by reading
    /// only the bytes past `last_seen_bytes` and folding usage
    /// blocks into the running totals. Lower-bound on first call
    /// per session (since we start from 0, not the file start);
    /// for accuracy on long-running existing sessions, the first
    /// pass scans the whole file once.
    pub fn merge_lifetime_totals(&mut self) {
        for row in &mut self.rows {
            if row.source != AgentSource::Claude {
                continue;
            }
            let path = &row.transcript_path;
            if !path.is_file() {
                continue;
            }
            let cur_size = match std::fs::metadata(path) {
                Ok(m) => m.len(),
                Err(_) => continue,
            };
            let totals = self
                .lifetime_cache
                .entry(row.session_id.clone())
                .or_default();
            if cur_size > totals.last_seen_bytes {
                let delta = read_byte_range(path, totals.last_seen_bytes, cur_size);
                if let Some(text) = delta {
                    let mut model = row.model.clone();
                    for line in text.lines() {
                        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
                            continue;
                        };
                        if v.get("type").and_then(|t| t.as_str()) != Some("assistant") {
                            continue;
                        }
                        let msg = v.get("message");
                        if let Some(m) = msg.and_then(|m| m.get("model")).and_then(|m| m.as_str()) {
                            model = Some(m.to_string());
                        }
                        let usage = match msg.and_then(|m| m.get("usage")) {
                            Some(u) => u,
                            None => continue,
                        };
                        let i = usage
                            .get("input_tokens")
                            .and_then(|n| n.as_u64())
                            .unwrap_or(0);
                        let o = usage
                            .get("output_tokens")
                            .and_then(|n| n.as_u64())
                            .unwrap_or(0);
                        let cc = usage
                            .get("cache_creation_input_tokens")
                            .and_then(|n| n.as_u64())
                            .unwrap_or(0);
                        let cr = usage
                            .get("cache_read_input_tokens")
                            .and_then(|n| n.as_u64())
                            .unwrap_or(0);
                        totals.tokens = totals.tokens.saturating_add(i + o);
                        totals.input_tokens = totals.input_tokens.saturating_add(i);
                        totals.output_tokens = totals.output_tokens.saturating_add(o);
                        totals.cache_create_tokens = totals.cache_create_tokens.saturating_add(cc);
                        totals.cache_read_tokens = totals.cache_read_tokens.saturating_add(cr);
                    }
                    if let Some(m) = model {
                        let extra_cost = estimate_cost(
                            &m,
                            totals.input_tokens,
                            totals.output_tokens,
                            totals.cache_create_tokens,
                            totals.cache_read_tokens,
                        );
                        // Recompute cost from totals (not delta-add)
                        // because the model might have switched mid-
                        // session, and the per-million-token pricing
                        // table is the source of truth.
                        totals.cost_usd = extra_cost;
                    }
                }
                totals.last_seen_bytes = cur_size;
            }
            // Override per-tail values with lifetime totals so the
            // top bar + per-row chip show full-session truth.
            if totals.tokens > row.tokens {
                row.tokens = totals.tokens;
                row.input_tokens = totals.input_tokens;
                row.output_tokens = totals.output_tokens;
                row.cache_create_tokens = totals.cache_create_tokens;
                row.cache_read_tokens = totals.cache_read_tokens;
            }
            if totals.cost_usd > row.cost_usd {
                row.cost_usd = totals.cost_usd;
            }
        }
    }

    /// Walk `self.rows`, compute `tokens_per_min` as a moving
    /// average over `TOKEN_SAMPLE_RING` recent samples. Smoother
    /// than the single-prev-sample delta — irregular bursts during
    /// tool-call stretches don't whip the rate around.
    pub fn recompute_token_rates(&mut self) {
        const RING: usize = 5;
        let now = SystemTime::now();
        for row in &mut self.rows {
            let entry = self
                .token_samples
                .entry(row.session_id.clone())
                .or_default();
            // Append latest sample.
            entry.push_back((now, row.tokens));
            while entry.len() > RING {
                entry.pop_front();
            }
            // Only live sessions get a rate.
            if !matches!(row.state, AgentState::Streaming | AgentState::ToolCall) {
                row.tokens_per_min = None;
                continue;
            }
            // Need ≥2 samples and at least 0.5s of span to compute.
            if entry.len() < 2 {
                row.tokens_per_min = None;
                continue;
            }
            let (oldest_ts, oldest_tokens) = entry[0];
            let dt = now
                .duration_since(oldest_ts)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0);
            let dtok = row.tokens.saturating_sub(oldest_tokens);
            if dt > 0.5 && dtok > 0 {
                row.tokens_per_min = Some((dtok as f64) * 60.0 / dt);
            } else {
                row.tokens_per_min = None;
            }
        }
        // Prune samples for sessions that have rolled off.
        let live_sids: std::collections::HashSet<String> =
            self.rows.iter().map(|r| r.session_id.clone()).collect();
        self.token_samples.retain(|sid, _| live_sids.contains(sid));
    }

    /// Re-tail JUST the selected row's transcript (if it's a live
    /// session) and write updated drill-down fields back into the
    /// row. No re-sort, no PID re-scan — much cheaper than the
    /// full `refresh_in_place`, and stable for the cursor. Returns
    /// `true` if the row was actually updated.
    pub fn live_tail_selected(&mut self) -> bool {
        let Some(vi) = self.visible_indices().get(self.selected).copied() else {
            return false;
        };
        let Some(row) = self.rows.get(vi) else {
            return false;
        };
        if !matches!(row.state, AgentState::Streaming | AgentState::ToolCall) {
            return false;
        }
        if row.source != AgentSource::Claude {
            return false; // we only parse Claude transcripts deeply
        }
        let path = row.transcript_path.clone();
        if !path.is_file() {
            return false;
        }
        let stats = parse_tail(&path);
        let cost = stats
            .model
            .as_deref()
            .map(|m| {
                estimate_cost(
                    m,
                    stats.input_tokens,
                    stats.output_tokens,
                    stats.cache_create_tokens,
                    stats.cache_read_tokens,
                )
            })
            .unwrap_or(0.0);
        let mtime = std::fs::metadata(&path)
            .ok()
            .and_then(|m| m.modified().ok());
        // 2026-06-21 claude-agents SEV-2 `token-flicker`: live tail
        // ONLY sees the last 256 KB of the transcript. The full
        // `lifetime_cache` is the right source of truth for long
        // sessions. Was: tail values unconditionally overwrote
        // tokens / cost, making chips oscillate every 500ms. Now:
        // keep the higher of (lifetime, tail) so the user always
        // sees monotonically-growing totals while still picking up
        // freshly-streamed lifelike updates.
        let lifetime = self.lifetime_cache.get(&self.rows[vi].session_id).cloned();
        if let Some(row) = self.rows.get_mut(vi) {
            if let Some(m) = stats.model.clone() {
                row.model = Some(m);
            }
            if let Some(c) = stats.cwd.clone() {
                row.cwd = Some(c);
            }
            if let Some(b) = stats.git_branch.clone() {
                row.git_branch = Some(b);
            }
            // Pick the larger of (lifetime cache, fresh tail).
            let lt = lifetime.as_ref();
            row.tokens = lt
                .map(|l| l.tokens.max(stats.tokens))
                .unwrap_or(stats.tokens);
            row.input_tokens = lt
                .map(|l| l.input_tokens.max(stats.input_tokens))
                .unwrap_or(stats.input_tokens);
            row.output_tokens = lt
                .map(|l| l.output_tokens.max(stats.output_tokens))
                .unwrap_or(stats.output_tokens);
            row.cache_create_tokens = lt
                .map(|l| l.cache_create_tokens.max(stats.cache_create_tokens))
                .unwrap_or(stats.cache_create_tokens);
            row.cache_read_tokens = lt
                .map(|l| l.cache_read_tokens.max(stats.cache_read_tokens))
                .unwrap_or(stats.cache_read_tokens);
            row.cost_usd = lt.map(|l| l.cost_usd.max(cost)).unwrap_or(cost);
            row.event_count = stats.event_count;
            row.last_user_msg = stats.last_user_msg;
            row.last_assistant_msg = stats.last_assistant_msg;
            row.current_tool = stats.last_tool_name;
            row.todos = stats.todos;
            row.recent_bash = stats.recent_bash;
            row.recent_files = stats.recent_files;
            row.recent_subagents = stats.recent_subagents;
            row.pending_tool_uses = stats.pending_tool_uses;
            if mtime.is_some() {
                row.last_activity = mtime;
            }
        }
        // Update rate from latest sample.
        self.recompute_token_rates();
        self.last_live_tail = SystemTime::now();
        true
    }

    /// Diff the current row set against the previous snapshot and
    /// return user-facing transition messages — "session X went
    /// live", "session Y now waiting on tool confirm", etc.
    /// Updates `prior_state_snapshot` in place. Returns an empty
    /// Vec on the first call after `build()` (initial snapshot,
    /// no spammy toasts on dashboard open).
    pub fn compute_transitions(&mut self) -> Vec<String> {
        let mut messages: Vec<String> = Vec::new();
        let was_empty = self.prior_state_snapshot.is_empty();
        let mut new_snapshot: std::collections::HashMap<String, (AgentState, usize)> =
            std::collections::HashMap::new();
        for row in &self.rows {
            let sid_short: String = row.session_id.chars().take(8).collect();
            new_snapshot.insert(row.session_id.clone(), (row.state, row.pending_tool_uses));
            if was_empty {
                continue;
            }
            let prev = self.prior_state_snapshot.get(&row.session_id);
            match prev {
                None => {
                    // Brand-new session.
                    if matches!(row.state, AgentState::Streaming | AgentState::ToolCall) {
                        messages.push(format!(
                            "{} new {} session ({})",
                            row.source.label(),
                            row.state.badge(),
                            sid_short
                        ));
                    }
                }
                Some(&(prev_state, prev_pending)) => {
                    if prev_state != row.state {
                        messages.push(format!(
                            "{} {} → {} ({})",
                            row.source.label(),
                            prev_state.badge(),
                            row.state.badge(),
                            sid_short
                        ));
                    }
                    if row.pending_tool_uses > prev_pending {
                        messages.push(format!(
                            "{} ⚠ pending tool ({})",
                            row.source.label(),
                            sid_short
                        ));
                    }
                }
            }
        }
        self.prior_state_snapshot = new_snapshot;
        messages
    }

    /// Rebuild rows in place, preserving the user's selection +
    /// scroll if the selected session is still present.
    pub fn refresh_in_place(&mut self) {
        let prior_sid = self.selected_row().map(|r| r.session_id.clone());
        let claude_pids = scan_running_pids(AgentSource::Claude);
        let codex_pids = scan_running_pids(AgentSource::Codex);
        let mut rows = collect_rows(&claude_pids);
        rows.extend(collect_codex_rows(&codex_pids));
        rows.sort_by(|a, b| {
            state_rank(a.state)
                .cmp(&state_rank(b.state))
                .then_with(|| b.last_activity.cmp(&a.last_activity))
        });
        self.rows = rows;
        self.built_at = SystemTime::now();
        // Prune multi-select set so it doesn't accumulate sids for
        // sessions that have rolled off (older than 7 days, etc.).
        let live_sids: std::collections::HashSet<String> =
            self.rows.iter().map(|r| r.session_id.clone()).collect();
        self.multi_selected.retain(|sid| live_sids.contains(sid));
        self.merge_lifetime_totals();
        self.recompute_token_rates();
        // 2026-06-21 claude-agents SEV-2: when the prior session
        // is no longer in the visible set (filter / rolloff /
        // kill), `selected` used to stay at the stale out-of-bounds
        // index — cursor invisible, j/k from a bogus origin. Now:
        // if we find the prior session, jump to it; otherwise
        // clamp to the new visible range.
        let new_visible = self.visible_indices();
        let resolved = prior_sid.and_then(|sid| {
            new_visible
                .iter()
                .position(|&i| self.rows.get(i).map(|r| &r.session_id) == Some(&sid))
        });
        self.selected = resolved.unwrap_or_default();
        // Belt-and-suspenders clamp: if filter+rolloff produced
        // an empty visible set, leave selected at 0.
        if !new_visible.is_empty() {
            self.selected = self.selected.min(new_visible.len() - 1);
        }
    }

    /// Aggregate stats across the full row set (not filtered).
    pub fn aggregate(&self) -> Aggregate {
        let mut a = Aggregate::default();
        for r in &self.rows {
            match r.state {
                AgentState::Streaming => a.streaming += 1,
                AgentState::ToolCall => a.tool_calls += 1,
                AgentState::Idle => a.idle += 1,
                AgentState::Ended => a.ended += 1,
            }
            a.total_tokens = a.total_tokens.saturating_add(r.tokens);
            a.pending_confirms = a
                .pending_confirms
                .saturating_add(r.pending_tool_uses as u64);
            a.total_cost_usd += r.cost_usd;
        }
        a
    }

    pub fn tab_title(&self) -> String {
        let live = self
            .rows
            .iter()
            .filter(|r| matches!(r.state, AgentState::Streaming | AgentState::ToolCall))
            .count();
        let total = self.rows.len();
        if live > 0 {
            format!("claude agents ({live} live / {total})")
        } else {
            format!("claude agents ({total})")
        }
    }

    /// Rows that pass the current filter (state + text query),
    /// returned as indices into `self.rows` so the renderer can map
    /// row index ↔ original row without copying.
    pub fn visible_indices(&self) -> Vec<usize> {
        let q = self.query.to_lowercase();
        let mut idx: Vec<usize> = self
            .rows
            .iter()
            .enumerate()
            .filter(|(_, r)| {
                if let Some(sf) = self.state_filter
                    && r.state != sf
                {
                    return false;
                }
                if let Some(src) = self.source_filter
                    && r.source != src
                {
                    return false;
                }
                if self.workspace_only && !self.anchor_workspace.as_os_str().is_empty() {
                    let cwd_ok = r
                        .cwd
                        .as_deref()
                        .map(|c| std::path::Path::new(c).starts_with(&self.anchor_workspace))
                        .unwrap_or(false);
                    if !cwd_ok {
                        return false;
                    }
                }
                if q.is_empty() {
                    return true;
                }
                let hay = format!(
                    "{} {} {} {} {} {}",
                    r.workspace,
                    r.session_id,
                    r.model.as_deref().unwrap_or(""),
                    r.last_user_msg.as_deref().unwrap_or(""),
                    r.last_assistant_msg.as_deref().unwrap_or(""),
                    r.git_branch.as_deref().unwrap_or(""),
                );
                hay.to_lowercase().contains(&q)
            })
            .map(|(i, _)| i)
            .collect();
        // Apply the per-section sort key. StateActivity is the
        // build-time default (rows come pre-sorted), but the other
        // modes re-sort so the user can flip without an external
        // rebuild.
        match self.sort_by {
            SortBy::StateActivity => {}
            SortBy::TokensDesc => {
                idx.sort_by(|&a, &b| self.rows[b].tokens.cmp(&self.rows[a].tokens));
            }
            SortBy::CostDesc => {
                idx.sort_by(|&a, &b| {
                    self.rows[b]
                        .cost_usd
                        .partial_cmp(&self.rows[a].cost_usd)
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
            }
            SortBy::ActivityDesc => {
                idx.sort_by(|&a, &b| self.rows[b].last_activity.cmp(&self.rows[a].last_activity));
            }
        }
        idx
    }

    pub fn selected_row(&self) -> Option<&AgentRow> {
        let vis = self.visible_indices();
        vis.get(self.selected).and_then(|&i| self.rows.get(i))
    }

    pub fn move_up(&mut self) {
        self.selected = self.selected.saturating_sub(1);
        self.detail_scroll = 0;
    }

    pub fn move_down(&mut self) {
        let n = self.visible_indices().len();
        if self.selected + 1 < n {
            self.selected += 1;
            self.detail_scroll = 0;
        }
    }

    pub fn cycle_detail(&mut self) {
        self.detail = self.detail.cycle();
        self.detail_scroll = 0;
    }

    pub fn cycle_group_by(&mut self) {
        self.group_by = self.group_by.cycle();
    }

    pub fn cycle_sort(&mut self) {
        self.sort_by = self.sort_by.cycle();
        self.selected = 0;
    }

    pub fn clear_multi_selected(&mut self) {
        self.multi_selected.clear();
    }

    /// Drop every narrow — text query, state filter, source
    /// filter, workspace-only. Cursor falls back to row 0.
    pub fn clear_filters(&mut self) {
        self.query.clear();
        self.filter_mode = false;
        self.state_filter = None;
        self.source_filter = None;
        self.workspace_only = false;
        self.selected = 0;
    }

    /// True when any filter is non-default (used to show a
    /// "filtered" chip in the title).
    pub fn any_filter_active(&self) -> bool {
        !self.query.is_empty()
            || self.state_filter.is_some()
            || self.source_filter.is_some()
            || self.workspace_only
    }

    /// Toggle the focused row's session id into `multi_selected`.
    /// Returns the new size of the set, for toast messages.
    pub fn toggle_multi_selected(&mut self) -> usize {
        if let Some(sid) = self.selected_row().map(|r| r.session_id.clone()) {
            if self.multi_selected.contains(&sid) {
                self.multi_selected.remove(&sid);
            } else {
                self.multi_selected.insert(sid);
            }
        }
        self.multi_selected.len()
    }

    /// Return the PIDs of all sessions in `multi_selected` that
    /// actually have a PID (live ones). Used by the batch-kill path.
    pub fn multi_selected_pids(&self) -> Vec<(String, u32)> {
        self.rows
            .iter()
            .filter(|r| self.multi_selected.contains(&r.session_id))
            .filter_map(|r| r.pid.map(|p| (r.session_id.clone(), p)))
            .collect()
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Aggregate {
    pub streaming: usize,
    pub tool_calls: usize,
    pub idle: usize,
    pub ended: usize,
    pub total_tokens: u64,
    pub pending_confirms: u64,
    /// Sum of `cost_usd` across all rows.
    pub total_cost_usd: f64,
}

fn home_projects_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".claude/projects"))
}

/// Decode a `-Users-foo-Projects-bar`-style directory name into
/// the last component (`bar`) for display purposes. Not invertible
/// with literal dashes in path segments; the dashboard accepts that
/// for v1.
fn decode_workspace_label(encoded: &str) -> String {
    encoded
        .trim_start_matches('-')
        .rsplit('-')
        .next()
        .unwrap_or(encoded)
        .to_string()
}

/// Collect rows from every recent `.jsonl` under
/// `~/.claude/projects/`. Skips files larger than 256 MB (the tail
/// parser still handles them fast, but a 500 MB file is almost
/// always the active session being written this very second — we
/// pick those up anyway because their mtime is fresh).
fn collect_rows(pids: &[(String, u32, String)]) -> Vec<AgentRow> {
    let Some(root) = home_projects_dir() else {
        return Vec::new();
    };
    let mut rows: Vec<AgentRow> = Vec::new();
    let Ok(rd) = std::fs::read_dir(&root) else {
        return rows;
    };
    for entry in rd.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let encoded = dir
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_string();
        let workspace = decode_workspace_label(&encoded);
        let Ok(files) = std::fs::read_dir(&dir) else {
            continue;
        };
        for f in files.flatten() {
            let p = f.path();
            let Some(name) = p.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            let Some(session_id) = name.strip_suffix(".jsonl") else {
                continue;
            };
            // Skip files we don't care about right now.
            let Ok(meta) = f.metadata() else { continue };
            let mtime = meta.modified().ok();
            // Last 7 days only — keeps the dashboard from
            // ballooning. The user can scroll older transcripts via
            // :ai.session_picker.
            if let Some(t) = mtime
                && let Ok(age) = SystemTime::now().duration_since(t)
                && age.as_secs() > 7 * 24 * 3600
            {
                continue;
            }
            let stats = parse_tail(&p);
            let pid = pids
                .iter()
                .find_map(|(sid, pid, _)| (sid == session_id).then_some(*pid));
            let state = derive_state(pid.is_some(), mtime, &stats);
            // Prefer the workspace label derived from the actual
            // `cwd` field in the transcript — encoded-dir parsing
            // (`-Users-x-Projects-y` → `y`) breaks on paths that
            // contain literal dashes, but `cwd` is authoritative.
            let workspace = stats
                .cwd
                .as_deref()
                .and_then(|c| std::path::Path::new(c).file_name())
                .and_then(|s| s.to_str())
                .map(String::from)
                .unwrap_or_else(|| workspace.clone());
            let current_tool = stats.last_tool_name.clone();
            let cost = stats
                .model
                .as_deref()
                .map(|m| {
                    estimate_cost(
                        m,
                        stats.input_tokens,
                        stats.output_tokens,
                        stats.cache_create_tokens,
                        stats.cache_read_tokens,
                    )
                })
                .unwrap_or(0.0);
            rows.push(AgentRow {
                source: AgentSource::Claude,
                transcript_path: p.clone(),
                session_id: session_id.to_string(),
                workspace: workspace.clone(),
                cwd: stats.cwd,
                git_branch: stats.git_branch,
                model: stats.model,
                last_activity: mtime,
                tokens: stats.tokens,
                input_tokens: stats.input_tokens,
                output_tokens: stats.output_tokens,
                cache_create_tokens: stats.cache_create_tokens,
                cache_read_tokens: stats.cache_read_tokens,
                cost_usd: cost,
                event_count: stats.event_count,
                last_user_msg: stats.last_user_msg,
                last_assistant_msg: stats.last_assistant_msg,
                pid,
                state,
                current_tool,
                todos: stats.todos,
                recent_bash: stats.recent_bash,
                recent_files: stats.recent_files,
                recent_subagents: stats.recent_subagents,
                pending_tool_uses: stats.pending_tool_uses,
                tokens_per_min: None,
            });
        }
    }
    // Sort: live first, then idle, then ended; within each group,
    // most recent first.
    rows.sort_by(|a, b| {
        let aw = state_rank(a.state);
        let bw = state_rank(b.state);
        aw.cmp(&bw)
            .then_with(|| b.last_activity.cmp(&a.last_activity))
    });
    rows
}

/// Codex CLI rows. The OpenAI codex stores sessions at
/// `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<sid>.jsonl` — nested
/// by date. We walk recursively to find them, then parse each via
/// `parse_codex_tail` (codex's transcript format differs from
/// Claude's — see that fn for the event shape). Codex sessions
/// don't appear to emit Bash/Edit tool_use events in this version
/// (v0.141.0); the drill-down's Files/Bash views stay empty for
/// codex rows until that lands.
fn collect_codex_rows(pids: &[(String, u32, String)]) -> Vec<AgentRow> {
    let mut rows: Vec<AgentRow> = Vec::new();
    let sessions_dir = std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".codex/sessions"));

    // 2026-06-21 — Codex CLI doesn't emit `--session-id <uuid>` in
    // its cmdline (only Claude does), so the sid-based pgrep match
    // returns "" for every Codex PID. Pre-resolve each PID's cwd
    // so disk rows can match by cwd as a fallback. Then a single
    // claimed-pids set ensures: (1) each disk row claims at most
    // one PID, (2) PIDs claimed by a disk row don't generate a
    // duplicate stub row in stage 2 of this fn.
    let pid_cwds: Vec<(u32, Option<String>)> = pids
        .iter()
        .map(|(_, pid, _)| (*pid, read_pid_cwd(*pid)))
        .collect();
    let mut claimed_pids: std::collections::HashSet<u32> = std::collections::HashSet::new();

    if let Some(dir) = sessions_dir.as_deref() {
        for p in walk_codex_sessions(dir) {
            let name = match p.file_name().and_then(|s| s.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            // Filename shape: rollout-<ts>-<UUIDv7>.jsonl. Session id
            // is the trailing UUID (36 chars before the extension).
            let stem = match name.strip_suffix(".jsonl") {
                Some(s) => s,
                None => continue,
            };
            let session_id = stem
                .rsplit('-')
                .take(5)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect::<Vec<_>>()
                .join("-");
            // Sanity: UUID is 36 chars with 4 dashes.
            if session_id.len() != 36 || session_id.matches('-').count() != 4 {
                continue;
            }
            let Ok(meta) = std::fs::metadata(&p) else {
                continue;
            };
            let mtime = meta.modified().ok();
            if let Some(t) = mtime
                && let Ok(age) = SystemTime::now().duration_since(t)
                && age.as_secs() > 7 * 24 * 3600
            {
                continue;
            }
            let stats = parse_codex_tail(&p);
            let pid = pids
                .iter()
                .find_map(|(sid, pid, _)| (sid == &session_id).then_some(*pid))
                .or_else(|| {
                    // Codex sid-fallback: match a not-yet-claimed
                    // running PID whose cwd matches this transcript's
                    // recorded cwd. First match wins. Works for the
                    // common case (one codex per cwd); multiple
                    // sessions in the same cwd will assign the PID
                    // to whichever disk row comes up first in the
                    // filesystem walk.
                    stats.cwd.as_ref().and_then(|disk_cwd| {
                        pid_cwds.iter().find_map(|(p_pid, p_cwd)| {
                            if claimed_pids.contains(p_pid) {
                                return None;
                            }
                            (p_cwd.as_deref() == Some(disk_cwd.as_str())).then_some(*p_pid)
                        })
                    })
                });
            if let Some(p) = pid {
                claimed_pids.insert(p);
            }
            let state = if pid.is_some() {
                if stats.last_was_tool_call {
                    AgentState::ToolCall
                } else {
                    let fresh = mtime
                        .and_then(|t| SystemTime::now().duration_since(t).ok())
                        .is_some_and(|d| d.as_secs() < 60);
                    if fresh {
                        AgentState::Streaming
                    } else {
                        AgentState::Idle
                    }
                }
            } else {
                AgentState::Ended
            };
            let workspace = stats
                .cwd
                .as_deref()
                .and_then(|c| std::path::Path::new(c).file_name())
                .and_then(|s| s.to_str())
                .map(String::from)
                .unwrap_or_else(|| "?".to_string());
            // OpenAI's `input_tokens` INCLUDES `cached_input_tokens`
            // (Anthropic separates them; OpenAI nests). Subtract so
            // we don't bill the cached portion at BOTH the full
            // input rate AND the cache-read rate.
            let net_input = stats.input_tokens.saturating_sub(stats.cache_read_tokens);
            let cost = stats
                .model
                .as_deref()
                .map(|m| {
                    estimate_cost(
                        m,
                        net_input,
                        stats.output_tokens,
                        0,
                        stats.cache_read_tokens,
                    )
                })
                .unwrap_or(0.0);
            rows.push(AgentRow {
                source: AgentSource::Codex,
                transcript_path: p.clone(),
                session_id,
                workspace,
                cwd: stats.cwd,
                git_branch: None,
                model: stats.model,
                last_activity: mtime,
                tokens: stats.tokens,
                input_tokens: stats.input_tokens,
                output_tokens: stats.output_tokens,
                cache_create_tokens: 0,
                cache_read_tokens: stats.cache_read_tokens,
                cost_usd: cost,
                event_count: stats.event_count,
                last_user_msg: stats.last_user_msg,
                last_assistant_msg: stats.last_assistant_msg,
                pid,
                state,
                current_tool: if stats.last_was_tool_call {
                    Some("exec".to_string())
                } else {
                    None
                },
                todos: Vec::new(),
                recent_bash: stats.recent_bash,
                recent_files: Vec::new(),
                recent_subagents: Vec::new(),
                pending_tool_uses: stats.pending_tool_uses,
                tokens_per_min: None,
            });
        }
    }

    // 2. Running PIDs that don't map to a known on-disk session —
    //    add stub rows so the user still sees them. Distinguish via
    //    session_id == "" (placeholder). Pre-`claimed_pids` this
    //    used to scan `rows.iter().filter_map(.pid)` which always
    //    came up empty for Codex (sids never matched), so every
    //    running codex PID got both an "ended" disk row AND a
    //    "live" stub — the SEV-1 fixed in 2026-06-21.
    for (_, pid, cmdline) in pids {
        if claimed_pids.contains(pid) {
            continue;
        }
        let cwd = read_pid_cwd(*pid);
        let workspace = cwd
            .as_deref()
            .and_then(|c| std::path::Path::new(c).file_name())
            .and_then(|s| s.to_str())
            .unwrap_or("?")
            .to_string();
        rows.push(AgentRow {
            source: AgentSource::Codex,
            transcript_path: PathBuf::new(),
            session_id: format!("pid-{pid}"),
            workspace,
            cwd,
            git_branch: None,
            model: None,
            last_activity: Some(SystemTime::now()),
            tokens: 0,
            input_tokens: 0,
            output_tokens: 0,
            cache_create_tokens: 0,
            cache_read_tokens: 0,
            cost_usd: 0.0,
            event_count: 0,
            last_user_msg: None,
            last_assistant_msg: Some(format!("(running) {}", truncate(cmdline, 160))),
            pid: Some(*pid),
            state: AgentState::Streaming,
            current_tool: None,
            todos: Vec::new(),
            recent_bash: Vec::new(),
            recent_files: Vec::new(),
            recent_subagents: Vec::new(),
            pending_tool_uses: 0,
            tokens_per_min: None,
        });
    }

    rows
}

/// Walk `~/.codex/sessions/` recursively (codex nests sessions by
/// `YYYY/MM/DD/`). Returns every `rollout-*.jsonl`. Bounded — only
/// descends 3 levels (year/month/day).
fn walk_codex_sessions(root: &std::path::Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    let Ok(years) = std::fs::read_dir(root) else {
        return out;
    };
    for y in years.flatten() {
        let Ok(months) = std::fs::read_dir(y.path()) else {
            continue;
        };
        for m in months.flatten() {
            let Ok(days) = std::fs::read_dir(m.path()) else {
                continue;
            };
            for d in days.flatten() {
                let Ok(files) = std::fs::read_dir(d.path()) else {
                    continue;
                };
                for f in files.flatten() {
                    let p = f.path();
                    if p.extension().is_some_and(|e| e == "jsonl") {
                        out.push(p);
                    }
                }
            }
        }
    }
    out
}

#[derive(Default)]
struct CodexTailStats {
    cwd: Option<String>,
    model: Option<String>,
    tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    event_count: usize,
    last_user_msg: Option<String>,
    last_assistant_msg: Option<String>,
    /// Recent `exec_command` invocations (newest first, max 10).
    recent_bash: Vec<String>,
    /// Unresolved call_ids — used to derive `pending_tool_uses` +
    /// `last_was_tool_call` for state derivation.
    pending_tool_uses: usize,
    last_was_tool_call: bool,
}

/// Codex transcript tail-parse. Codex's format:
///   { "timestamp": "...", "type": "session_meta",   "payload": {...} }
///   { "timestamp": "...", "type": "turn_context",   "payload": {...} }
///   { "timestamp": "...", "type": "response_item",  "payload": {
///       "type": "message", "role": "user|assistant|developer",
///       "content": [{"type": "input_text"|"output_text", "text": "..."}]
///     } }
///   { "timestamp": "...", "type": "event_msg",      "payload": {
///       "type": "token_count",
///       "info": { "total_token_usage": { input_tokens, output_tokens,
///                                        cached_input_tokens,
///                                        reasoning_output_tokens } }
///     } }
///
/// We track the running token_count (total_token_usage is cumulative
/// per-event, not per-turn, so the LAST seen value is the running
/// total — we don't sum).
fn parse_codex_tail(path: &std::path::Path) -> CodexTailStats {
    let mut stats = CodexTailStats::default();
    let Ok(text) = read_tail(path, 256 * 1024) else {
        return stats;
    };
    // Pair function_call ↔ function_call_output by call_id so we
    // can derive pending tool count.
    let mut pending_calls: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut last_assistant_was_tool = false;
    for line in text.lines() {
        stats.event_count += 1;
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let ty = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        let payload = v.get("payload");
        match ty {
            "session_meta" => {
                if let Some(c) = payload.and_then(|p| p.get("cwd")).and_then(|c| c.as_str()) {
                    stats.cwd = Some(c.to_string());
                }
            }
            "turn_context" => {
                if let Some(c) = payload.and_then(|p| p.get("cwd")).and_then(|c| c.as_str()) {
                    stats.cwd = Some(c.to_string());
                }
                if let Some(m) = payload
                    .and_then(|p| p.get("model"))
                    .and_then(|m| m.as_str())
                {
                    stats.model = Some(m.to_string());
                }
            }
            "response_item" => {
                let inner_type = payload
                    .and_then(|p| p.get("type"))
                    .and_then(|t| t.as_str())
                    .unwrap_or("");
                match inner_type {
                    "function_call" => {
                        // Codex's only tool is `exec_command`. The
                        // arguments are a JSON-encoded string in
                        // payload.arguments — parse it to extract
                        // the actual `cmd`.
                        let call_id = payload
                            .and_then(|p| p.get("call_id"))
                            .and_then(|c| c.as_str())
                            .unwrap_or("")
                            .to_string();
                        if !call_id.is_empty() {
                            pending_calls.insert(call_id);
                        }
                        last_assistant_was_tool = true;
                        let args_str = payload
                            .and_then(|p| p.get("arguments"))
                            .and_then(|a| a.as_str())
                            .unwrap_or("");
                        if let Ok(args) = serde_json::from_str::<serde_json::Value>(args_str)
                            && let Some(cmd) = args.get("cmd").and_then(|c| c.as_str())
                        {
                            stats.recent_bash.insert(0, truncate(cmd, 96));
                            stats.recent_bash.truncate(10);
                        }
                        continue;
                    }
                    "function_call_output" => {
                        if let Some(call_id) = payload
                            .and_then(|p| p.get("call_id"))
                            .and_then(|c| c.as_str())
                        {
                            pending_calls.remove(call_id);
                        }
                        continue;
                    }
                    "message" => {} // fall through to text extraction
                    _ => continue,
                }
                let role = payload
                    .and_then(|p| p.get("role"))
                    .and_then(|r| r.as_str())
                    .unwrap_or("");
                let content = payload
                    .and_then(|p| p.get("content"))
                    .and_then(|c| c.as_array());
                let text = content.and_then(|arr| {
                    arr.iter().find_map(|b| {
                        let bt = b.get("type").and_then(|t| t.as_str()).unwrap_or("");
                        if bt == "input_text" || bt == "output_text" {
                            b.get("text").and_then(|t| t.as_str()).map(String::from)
                        } else {
                            None
                        }
                    })
                });
                let Some(text) = text else { continue };
                let text = text.trim();
                if text.starts_with("<environment_context>")
                    || text.starts_with("<permissions instructions>")
                    || text.starts_with("<task_complete>")
                    || text.is_empty()
                {
                    continue;
                }
                match role {
                    "user" => stats.last_user_msg = Some(truncate(text, 200)),
                    "assistant" => {
                        stats.last_assistant_msg = Some(truncate(text, 200));
                        last_assistant_was_tool = false;
                    }
                    _ => {}
                }
            }
            "event_msg" => {
                let inner_type = payload
                    .and_then(|p| p.get("type"))
                    .and_then(|t| t.as_str())
                    .unwrap_or("");
                if inner_type == "token_count"
                    && let Some(info) = payload.and_then(|p| p.get("info"))
                {
                    let total = info.get("total_token_usage");
                    let i = total
                        .and_then(|t| t.get("input_tokens"))
                        .and_then(|n| n.as_u64())
                        .unwrap_or(0);
                    let o = total
                        .and_then(|t| t.get("output_tokens"))
                        .and_then(|n| n.as_u64())
                        .unwrap_or(0);
                    let ro = total
                        .and_then(|t| t.get("reasoning_output_tokens"))
                        .and_then(|n| n.as_u64())
                        .unwrap_or(0);
                    let cached = total
                        .and_then(|t| t.get("cached_input_tokens"))
                        .and_then(|n| n.as_u64())
                        .unwrap_or(0);
                    // `total_token_usage` is cumulative — overwrite,
                    // don't sum.
                    stats.input_tokens = i;
                    stats.output_tokens = o.saturating_add(ro);
                    stats.cache_read_tokens = cached;
                    stats.tokens = i.saturating_add(o).saturating_add(ro);
                }
            }
            _ => {}
        }
    }
    stats.pending_tool_uses = pending_calls.len();
    stats.last_was_tool_call = last_assistant_was_tool && stats.pending_tool_uses > 0;
    stats
}

/// Return the cwd of a running process. Uses `lsof -p PID` on macOS,
/// `/proc/<pid>/cwd` on Linux. Best-effort; returns `None` on any
/// failure.
fn read_pid_cwd(pid: u32) -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let p = std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
        // Tail expression (this is the whole fn body on Linux; the
        // non-Linux block is cfg'd out) — no `return` needed.
        Some(p.to_string_lossy().into_owned())
    }
    #[cfg(not(target_os = "linux"))]
    {
        // macOS / BSD: `lsof -p <pid>` line where COL[3] == "cwd".
        let out = std::process::Command::new("lsof")
            .args(["-p", &pid.to_string()])
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.get(3).copied() == Some("cwd") {
                return Some(cols[8..].join(" "));
            }
        }
        None
    }
}

fn state_rank(s: AgentState) -> u8 {
    match s {
        AgentState::Streaming => 0,
        AgentState::ToolCall => 1,
        AgentState::Idle => 2,
        AgentState::Ended => 3,
    }
}

fn derive_state(has_pid: bool, mtime: Option<SystemTime>, stats: &TailStats) -> AgentState {
    if !has_pid {
        return AgentState::Ended;
    }
    if stats.last_was_tool_call {
        return AgentState::ToolCall;
    }
    let fresh = mtime
        .and_then(|t| SystemTime::now().duration_since(t).ok())
        .is_some_and(|d| d.as_secs() < 60);
    if fresh {
        AgentState::Streaming
    } else {
        AgentState::Idle
    }
}

#[derive(Default)]
struct TailStats {
    cwd: Option<String>,
    git_branch: Option<String>,
    model: Option<String>,
    tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_create_tokens: u64,
    cache_read_tokens: u64,
    event_count: usize,
    last_user_msg: Option<String>,
    last_assistant_msg: Option<String>,
    last_was_tool_call: bool,
    last_tool_name: Option<String>,
    /// Most recent TodoList state — extracted from the last
    /// TaskCreate/TaskUpdate tool_use input we see in the tail.
    todos: Vec<TodoEntry>,
    /// Recent Bash invocations (most recent first, capped at 10).
    recent_bash: Vec<String>,
    /// Recent Edit/Write file events (most recent first, capped at 10).
    recent_files: Vec<RecentFile>,
    /// Subagent dispatches via the Agent tool (newest first, capped
    /// at 5).
    recent_subagents: Vec<String>,
    /// `tool_use_id`s that haven't yet seen a matching tool_result.
    /// Lower-bound count for "pending tool" badges.
    pending_tool_uses: usize,
}

#[derive(Debug, Clone)]
pub struct TodoEntry {
    pub content: String,
    pub status: String,
}

/// One recent Edit/Write/NotebookEdit event — the tool name and
/// the full file path. The drill-down's Files view renders these
/// as clickable rows (Enter / click opens the file in an editor
/// pane).
#[derive(Debug, Clone)]
pub struct RecentFile {
    pub tool: String,
    pub path: String,
}

/// Per-session lifetime totals — accurate even when the
/// `parse_tail` window truncates. Maintained incrementally by
/// `merge_lifetime_totals`.
#[derive(Debug, Clone, Default)]
pub struct LifetimeTotals {
    /// File size as of the last refresh. Reads on the next refresh
    /// only need to cover bytes past this offset.
    pub last_seen_bytes: u64,
    pub tokens: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_create_tokens: u64,
    pub cache_read_tokens: u64,
    pub cost_usd: f64,
}

/// Tail-parse the .jsonl file. Reads up to the last 256KB and walks
/// every fully-terminated line backward.
fn parse_tail(path: &std::path::Path) -> TailStats {
    let mut stats = TailStats::default();
    let Ok(text) = read_tail(path, 256 * 1024) else {
        return stats;
    };
    let lines: Vec<&str> = text.lines().collect();
    let mut seen_assistant_text = false;
    let mut seen_user_msg = false;
    let mut last_assistant_was_tool = false;
    // Track tool_use_id → not-yet-completed for the pending count.
    let mut pending: std::collections::HashSet<String> = std::collections::HashSet::new();
    for line in &lines {
        stats.event_count += 1;
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if let Some(cwd) = v.get("cwd").and_then(|c| c.as_str()) {
            stats.cwd = Some(cwd.to_string());
        }
        if let Some(b) = v.get("gitBranch").and_then(|c| c.as_str()) {
            stats.git_branch = Some(b.to_string());
        }
        let ty = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        match ty {
            "assistant" => {
                last_assistant_was_tool = false;
                let msg = v.get("message");
                if let Some(model) = msg.and_then(|m| m.get("model")).and_then(|m| m.as_str()) {
                    stats.model = Some(model.to_string());
                }
                if let Some(usage) = msg.and_then(|m| m.get("usage")) {
                    let i = usage
                        .get("input_tokens")
                        .and_then(|n| n.as_u64())
                        .unwrap_or(0);
                    let o = usage
                        .get("output_tokens")
                        .and_then(|n| n.as_u64())
                        .unwrap_or(0);
                    let cc = usage
                        .get("cache_creation_input_tokens")
                        .and_then(|n| n.as_u64())
                        .unwrap_or(0);
                    let cr = usage
                        .get("cache_read_input_tokens")
                        .and_then(|n| n.as_u64())
                        .unwrap_or(0);
                    stats.tokens = stats.tokens.saturating_add(i + o);
                    stats.input_tokens = stats.input_tokens.saturating_add(i);
                    stats.output_tokens = stats.output_tokens.saturating_add(o);
                    stats.cache_create_tokens = stats.cache_create_tokens.saturating_add(cc);
                    stats.cache_read_tokens = stats.cache_read_tokens.saturating_add(cr);
                }
                if let Some(content) = msg
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_array())
                {
                    let mut text_acc: Option<String> = None;
                    let mut tool_name: Option<String> = None;
                    for block in content {
                        let bt = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
                        match bt {
                            "text" if text_acc.is_none() => {
                                text_acc = block
                                    .get("text")
                                    .and_then(|t| t.as_str())
                                    .map(|s| truncate(s, 200));
                            }
                            "tool_use" => {
                                let name = block
                                    .get("name")
                                    .and_then(|n| n.as_str())
                                    .unwrap_or("?")
                                    .to_string();
                                let id = block
                                    .get("id")
                                    .and_then(|i| i.as_str())
                                    .unwrap_or("")
                                    .to_string();
                                let input = block.get("input");
                                if !id.is_empty() {
                                    pending.insert(id);
                                }
                                if tool_name.is_none() {
                                    tool_name = Some(name.clone());
                                }
                                // Per-tool sidecars.
                                match name.as_str() {
                                    "TaskCreate" | "TodoWrite" => {
                                        if let Some(arr) = input
                                            .and_then(|i| i.get("todos"))
                                            .and_then(|t| t.as_array())
                                        {
                                            stats.todos = arr
                                                .iter()
                                                .filter_map(|t| {
                                                    let content = t
                                                        .get("content")
                                                        .or_else(|| t.get("activeForm"))
                                                        .and_then(|c| c.as_str())?;
                                                    let status = t
                                                        .get("status")
                                                        .and_then(|s| s.as_str())
                                                        .unwrap_or("pending");
                                                    Some(TodoEntry {
                                                        content: content.to_string(),
                                                        status: status.to_string(),
                                                    })
                                                })
                                                .collect();
                                        }
                                    }
                                    "Bash" => {
                                        if let Some(cmd) = input
                                            .and_then(|i| i.get("command"))
                                            .and_then(|c| c.as_str())
                                        {
                                            stats.recent_bash.insert(0, truncate(cmd, 96));
                                            stats.recent_bash.truncate(10);
                                        }
                                    }
                                    "Edit" | "Write" | "NotebookEdit" => {
                                        if let Some(p) = input
                                            .and_then(|i| i.get("file_path"))
                                            .and_then(|f| f.as_str())
                                        {
                                            let entry = RecentFile {
                                                tool: name.clone(),
                                                path: p.to_string(),
                                            };
                                            if !stats.recent_files.iter().any(|e| {
                                                e.tool == entry.tool && e.path == entry.path
                                            }) {
                                                stats.recent_files.insert(0, entry);
                                                stats.recent_files.truncate(10);
                                            }
                                        }
                                    }
                                    "Agent" => {
                                        let sub_type = input
                                            .and_then(|i| i.get("subagent_type"))
                                            .and_then(|s| s.as_str())
                                            .unwrap_or("?");
                                        let desc = input
                                            .and_then(|i| i.get("description"))
                                            .and_then(|s| s.as_str())
                                            .unwrap_or("");
                                        stats
                                            .recent_subagents
                                            .insert(0, format!("{sub_type}: {desc}"));
                                        stats.recent_subagents.truncate(5);
                                    }
                                    _ => {}
                                }
                            }
                            _ => {}
                        }
                    }
                    if let Some(t) = text_acc {
                        stats.last_assistant_msg = Some(t);
                        seen_assistant_text = true;
                    } else if let Some(n) = tool_name {
                        stats.last_assistant_msg = Some(format!("⚙ {n}"));
                        last_assistant_was_tool = true;
                        stats.last_tool_name = Some(n);
                        seen_assistant_text = true;
                    }
                }
            }
            "user" => {
                let content = v.get("message").and_then(|m| m.get("content"));
                // Look for tool_result blocks first — match them
                // against the pending set so we can compute pending
                // tool-use count.
                if let Some(serde_json::Value::Array(arr)) = content {
                    for b in arr {
                        if b.get("type").and_then(|t| t.as_str()) == Some("tool_result")
                            && let Some(id) = b.get("tool_use_id").and_then(|i| i.as_str())
                        {
                            pending.remove(id);
                        }
                    }
                }
                let text = match content {
                    Some(serde_json::Value::String(s)) => Some(s.clone()),
                    Some(serde_json::Value::Array(arr)) => arr
                        .iter()
                        .filter_map(|b| {
                            if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                                b.get("text").and_then(|t| t.as_str()).map(String::from)
                            } else {
                                None
                            }
                        })
                        .next(),
                    _ => None,
                };
                if let Some(t) = text {
                    let t = t.trim();
                    if !t.is_empty()
                        && !t.starts_with("<system-reminder>")
                        && !t.starts_with("<command-")
                        && !t.starts_with("Caveat:")
                    {
                        stats.last_user_msg = Some(truncate(t, 200));
                        seen_user_msg = true;
                    }
                }
            }
            _ => {}
        }
        let _ = seen_assistant_text;
        let _ = seen_user_msg;
    }
    stats.last_was_tool_call = last_assistant_was_tool;
    stats.pending_tool_uses = pending.len();
    stats
}

/// Read bytes `[start, end)` from `path`. Used by lifetime cost
/// merging to scan only the new tail of a transcript.
fn read_byte_range(path: &std::path::Path, start: u64, end: u64) -> Option<String> {
    use std::io::{Read, Seek, SeekFrom};
    if end <= start {
        return Some(String::new());
    }
    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::with_capacity((end - start) as usize);
    f.take(end - start).read_to_end(&mut buf).ok()?;
    let s = String::from_utf8_lossy(&buf).into_owned();
    // If `start > 0`, the first line is partial — drop it.
    if start > 0
        && let Some(nl) = s.find('\n')
    {
        return Some(s[nl + 1..].to_string());
    }
    Some(s)
}

/// Read up to `cap` bytes from the END of `path`. Returns a String
/// containing the last `cap` bytes; the first (probably-partial)
/// line is discarded.
fn read_tail(path: &std::path::Path, cap: usize) -> std::io::Result<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path)?;
    let len = f.metadata()?.len();
    let start = len.saturating_sub(cap as u64);
    f.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::with_capacity(cap);
    f.take(cap as u64).read_to_end(&mut buf)?;
    // If we seeked past byte 0, the first line is partial — drop it.
    let s = String::from_utf8_lossy(&buf).into_owned();
    if start > 0
        && let Some(nl) = s.find('\n')
    {
        return Ok(s[nl + 1..].to_string());
    }
    Ok(s)
}

fn truncate(s: &str, max: usize) -> String {
    // Collapse all whitespace (including newlines) to single spaces
    // so multi-line messages render as one row.
    let mut collapsed = String::with_capacity(s.len());
    let mut last_was_space = false;
    for c in s.trim().chars() {
        if c.is_whitespace() {
            if !last_was_space {
                collapsed.push(' ');
            }
            last_was_space = true;
        } else {
            collapsed.push(c);
            last_was_space = false;
        }
    }
    if collapsed.chars().count() <= max {
        collapsed
    } else {
        let cut: String = collapsed.chars().take(max).collect();
        format!("{cut}…")
    }
}

/// One hit from `search_all_transcripts`.
#[derive(Debug, Clone)]
pub struct SearchHit {
    pub transcript_path: PathBuf,
    pub workspace: String,
    pub session_id: String,
    /// User-facing snippet — the message text trimmed + truncated.
    pub snippet: String,
    /// Which side of the conversation the match came from.
    pub role: SearchRole,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchRole {
    User,
    Assistant,
    ToolBash,
    ToolEdit,
}

impl SearchRole {
    pub fn glyph(self) -> &'static str {
        match self {
            SearchRole::User => "user",
            SearchRole::Assistant => "asst",
            SearchRole::ToolBash => "bash",
            SearchRole::ToolEdit => "edit",
        }
    }
}

/// Grep every transcript under `~/.claude/projects/*/<sid>.jsonl`
/// for `query` (lowercase substring). Returns hits ordered by
/// transcript mtime (newest first). Hard-caps at 200 hits to keep
/// the scratch readable.
pub fn search_all_transcripts(query: &str) -> Vec<SearchHit> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return Vec::new();
    }
    let Some(root) = home_projects_dir() else {
        return Vec::new();
    };
    let Ok(dirs) = std::fs::read_dir(&root) else {
        return Vec::new();
    };

    // Collect (path, mtime, workspace_label) tuples first so we can
    // process newest-first.
    let mut files: Vec<(PathBuf, SystemTime, String)> = Vec::new();
    for d in dirs.flatten() {
        let dir = d.path();
        if !dir.is_dir() {
            continue;
        }
        let workspace = dir
            .file_name()
            .and_then(|s| s.to_str())
            .map(decode_workspace_label)
            .unwrap_or_else(|| "?".to_string());
        let Ok(rd) = std::fs::read_dir(&dir) else {
            continue;
        };
        for f in rd.flatten() {
            let p = f.path();
            if p.extension().is_none_or(|e| e != "jsonl") {
                continue;
            }
            let mtime = f
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            files.push((p, mtime, workspace.clone()));
        }
    }
    files.sort_by_key(|b| std::cmp::Reverse(b.1));

    let mut hits: Vec<SearchHit> = Vec::new();
    const HIT_CAP: usize = 200;
    'outer: for (path, _mtime, workspace) in files {
        let session_id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("?")
            .to_string();
        // Stream-read line-by-line; transcripts can be huge so a
        // BufReader keeps memory bounded.
        let Ok(f) = std::fs::File::open(&path) else {
            continue;
        };
        use std::io::BufRead;
        let reader = std::io::BufReader::new(f);
        for line in reader.lines().map_while(Result::ok) {
            if !line.to_lowercase().contains(&q) {
                continue;
            }
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
                continue;
            };
            // Find the role-tagged text snippet that contains the
            // match. Prefer matches in user / asst text first, then
            // Bash commands and Edit file paths.
            let ty = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
            let extracted = match ty {
                "user" => extract_user_snippet(&v, &q),
                "assistant" => extract_assistant_snippet(&v, &q),
                _ => None,
            };
            if let Some((role, snippet)) = extracted {
                hits.push(SearchHit {
                    transcript_path: path.clone(),
                    workspace: workspace.clone(),
                    session_id: session_id.clone(),
                    snippet,
                    role,
                });
                if hits.len() >= HIT_CAP {
                    break 'outer;
                }
            }
        }
    }
    hits
}

fn extract_user_snippet(v: &serde_json::Value, q: &str) -> Option<(SearchRole, String)> {
    let content = v.get("message").and_then(|m| m.get("content"))?;
    let text = match content {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Array(arr) => arr
            .iter()
            .filter_map(|b| {
                if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                    b.get("text").and_then(|t| t.as_str()).map(String::from)
                } else {
                    None
                }
            })
            .next()?,
        _ => return None,
    };
    if !text.to_lowercase().contains(q) {
        return None;
    }
    if text.starts_with("<system-reminder>")
        || text.starts_with("<command-")
        || text.starts_with("Caveat:")
    {
        return None;
    }
    Some((SearchRole::User, truncate(&text, 160)))
}

fn extract_assistant_snippet(v: &serde_json::Value, q: &str) -> Option<(SearchRole, String)> {
    let content = v
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(|c| c.as_array())?;
    for block in content {
        let bt = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
        match bt {
            "text" => {
                if let Some(s) = block.get("text").and_then(|t| t.as_str())
                    && s.to_lowercase().contains(q)
                {
                    return Some((SearchRole::Assistant, truncate(s, 160)));
                }
            }
            "tool_use" => {
                let name = block.get("name").and_then(|n| n.as_str()).unwrap_or("");
                let input = block.get("input");
                match name {
                    "Bash" => {
                        if let Some(cmd) = input
                            .and_then(|i| i.get("command"))
                            .and_then(|c| c.as_str())
                            && cmd.to_lowercase().contains(q)
                        {
                            return Some((SearchRole::ToolBash, truncate(cmd, 160)));
                        }
                    }
                    "Edit" | "Write" | "Read" => {
                        if let Some(p) = input
                            .and_then(|i| i.get("file_path"))
                            .and_then(|f| f.as_str())
                            && p.to_lowercase().contains(q)
                        {
                            return Some((SearchRole::ToolEdit, format!("{name} {p}")));
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    None
}

/// Format a row's transcript as a markdown export. Returns
/// `(filename_stem, markdown_text)` for the caller to write/open.
/// For Codex rows (no parsable transcript), returns a minimal
/// metadata-only export so the user still has something to file.
pub fn export_transcript_as_markdown(row: &AgentRow) -> Result<(String, String), String> {
    let sid_short: String = row.session_id.chars().take(8).collect();
    // Workspace folded into filename for at-a-glance triage —
    // "20260621-095422-mnml-019ee836.md" is more meaningful than
    // "20260621-095422-019ee836.md". Strip anything that isn't
    // ascii-alnum so the filename stays portable.
    let ws_safe: String = row
        .workspace
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let ws_safe = if ws_safe.is_empty() {
        "workspace".to_string()
    } else {
        ws_safe
    };
    let stem = format!("{}-{ws_safe}-{sid_short}", utc_stamp());

    if row.source == AgentSource::Codex {
        let mut out = String::new();
        out.push_str(&format!(
            "# Codex session {sid_short}\n\n_workspace: {} · pid: {} · state: {} · model: {}_\n\n",
            row.workspace,
            row.pid
                .map(|p| p.to_string())
                .unwrap_or_else(|| "—".to_string()),
            row.state.badge(),
            row.model.as_deref().unwrap_or("?"),
        ));
        if let Some(cwd) = &row.cwd {
            out.push_str(&format!("**cwd**: `{cwd}`\n\n"));
        }
        // 2026-06-21 claude-agents SEV-3: walk the codex transcript
        // (parse_codex_tail-style) and emit the conversation. Was:
        // stubbed-out with "format isn't parsed yet" comment 3
        // commits after the parser actually shipped (ff174d2).
        let path = row.transcript_path.clone();
        if path.is_file()
            && let Ok(f) = std::fs::File::open(&path)
        {
            use std::io::BufRead;
            let reader = std::io::BufReader::new(f);
            for line in reader.lines().map_while(Result::ok) {
                let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
                    continue;
                };
                // Codex transcript shape (rollout-*.jsonl):
                // each line has a `payload.type`. user_message
                // / assistant_message carry `content` strings;
                // function_call / function_call_output carry
                // tool invocations. Stream them as headings.
                let payload = v.get("payload").unwrap_or(&v);
                let ty = payload.get("type").and_then(|t| t.as_str()).unwrap_or("");
                match ty {
                    "user_message" => {
                        if let Some(c) = payload.get("content").and_then(|c| c.as_str()) {
                            out.push_str(&format!("## User\n\n{c}\n\n"));
                        }
                    }
                    "assistant_message" => {
                        if let Some(c) = payload.get("content").and_then(|c| c.as_str()) {
                            out.push_str(&format!("## Codex\n\n{c}\n\n"));
                        }
                    }
                    "function_call" => {
                        let name = payload.get("name").and_then(|s| s.as_str()).unwrap_or("?");
                        let args = payload
                            .get("arguments")
                            .and_then(|s| s.as_str())
                            .unwrap_or("");
                        out.push_str(&format!("### tool: `{name}`\n\n```\n{args}\n```\n\n"));
                    }
                    _ => {}
                }
            }
        }
        return Ok((stem, out));
    }

    let path = row.transcript_path.clone();
    if !path.is_file() {
        return Err("no transcript on disk".to_string());
    }
    let f = std::fs::File::open(&path).map_err(|e| format!("open: {e}"))?;
    use std::io::BufRead;
    let reader = std::io::BufReader::new(f);
    let mut out = String::new();
    out.push_str(&format!(
        "# Claude session {sid_short}\n\n_workspace: {} · branch: {} · model: {}_\n\n",
        row.workspace,
        row.git_branch.as_deref().unwrap_or("?"),
        row.model.as_deref().unwrap_or("?"),
    ));
    for line in reader.lines().map_while(Result::ok) {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let ty = v.get("type").and_then(|t| t.as_str()).unwrap_or("");
        match ty {
            "user" => {
                if let Some(txt) = extract_user_message_text(&v) {
                    if txt.starts_with("<system-reminder>") {
                        continue;
                    }
                    out.push_str("## 👤 User\n\n");
                    out.push_str(&txt);
                    out.push_str("\n\n");
                }
            }
            "assistant" => {
                if let Some(content) = v
                    .get("message")
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_array())
                {
                    let mut header_written = false;
                    for block in content {
                        let bt = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
                        match bt {
                            "text" => {
                                if !header_written {
                                    out.push_str("## 🤖 Assistant\n\n");
                                    header_written = true;
                                }
                                if let Some(t) = block.get("text").and_then(|t| t.as_str()) {
                                    out.push_str(t);
                                    out.push_str("\n\n");
                                }
                            }
                            "tool_use" => {
                                let name =
                                    block.get("name").and_then(|n| n.as_str()).unwrap_or("?");
                                let input = block.get("input").unwrap_or(&serde_json::Value::Null);
                                if !header_written {
                                    out.push_str("## 🤖 Assistant\n\n");
                                    header_written = true;
                                }
                                out.push_str(&format!("_⚙ tool: {name}_\n\n```json\n"));
                                if let Ok(s) = serde_json::to_string_pretty(input) {
                                    let trimmed: String = s.chars().take(2000).collect();
                                    out.push_str(&trimmed);
                                }
                                out.push_str("\n```\n\n");
                            }
                            _ => {}
                        }
                    }
                }
            }
            _ => {}
        }
    }
    Ok((stem, out))
}

/// `YYYYMMDD-HHMMSS` from the system clock, computed via plain
/// integer math against the Unix epoch. Used for export filenames
/// so each `e` writes a distinct file.
fn utc_stamp() -> String {
    let secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Civil-from-days algorithm (Howard Hinnant). Works for any
    // year >= 1970.
    let days_since_epoch = (secs / 86400) as i64;
    let time_of_day = secs % 86400;
    let h = time_of_day / 3600;
    let m = (time_of_day % 3600) / 60;
    let s = time_of_day % 60;
    let z = days_since_epoch + 719468;
    let era = z.div_euclid(146097);
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m_civil = if mp < 10 { mp + 3 } else { mp - 9 };
    let y_civil = if m_civil <= 2 { y + 1 } else { y };
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        y_civil, m_civil, d, h, m, s
    )
}

fn extract_user_message_text(v: &serde_json::Value) -> Option<String> {
    let content = v.get("message").and_then(|m| m.get("content"))?;
    match content {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Array(arr) => arr
            .iter()
            .filter_map(|b| {
                if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                    b.get("text").and_then(|t| t.as_str()).map(String::from)
                } else {
                    None
                }
            })
            .next(),
        _ => None,
    }
}

/// One-stop "today's AI spend" — sums tokens + cost across every
/// session (Claude + Codex) whose transcript was touched in the
/// last 24 hours. Used by `:ai.spend_today` palette command.
#[derive(Debug, Clone, Default)]
pub struct SpendToday {
    pub claude_sessions: usize,
    pub codex_sessions: usize,
    pub total_tokens: u64,
    pub total_cost_usd: f64,
    pub per_workspace: Vec<(String, u64, f64)>,
}

pub fn spend_today() -> SpendToday {
    let mut s = SpendToday::default();
    let mut by_workspace: std::collections::BTreeMap<String, (u64, f64)> =
        std::collections::BTreeMap::new();
    let cutoff = SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(24 * 3600))
        .unwrap_or(SystemTime::UNIX_EPOCH);
    // Claude
    if let Some(root) = home_projects_dir()
        && let Ok(dirs) = std::fs::read_dir(&root)
    {
        for d in dirs.flatten() {
            let p = d.path();
            let workspace = p
                .file_name()
                .and_then(|s| s.to_str())
                .map(decode_workspace_label)
                .unwrap_or_else(|| "?".to_string());
            let Ok(rd) = std::fs::read_dir(&p) else {
                continue;
            };
            for f in rd.flatten() {
                let fp = f.path();
                if fp.extension().is_none_or(|e| e != "jsonl") {
                    continue;
                }
                let Ok(meta) = f.metadata() else { continue };
                let Ok(mt) = meta.modified() else { continue };
                if mt < cutoff {
                    continue;
                }
                let stats = parse_tail(&fp);
                let cost = stats
                    .model
                    .as_deref()
                    .map(|m| {
                        estimate_cost(
                            m,
                            stats.input_tokens,
                            stats.output_tokens,
                            stats.cache_create_tokens,
                            stats.cache_read_tokens,
                        )
                    })
                    .unwrap_or(0.0);
                s.claude_sessions += 1;
                s.total_tokens += stats.tokens;
                s.total_cost_usd += cost;
                let bucket = by_workspace.entry(workspace.clone()).or_default();
                bucket.0 += stats.tokens;
                bucket.1 += cost;
            }
        }
    }
    // Codex
    if let Some(root) = std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".codex/sessions")) {
        for fp in walk_codex_sessions(&root) {
            let Ok(meta) = std::fs::metadata(&fp) else {
                continue;
            };
            let Ok(mt) = meta.modified() else { continue };
            if mt < cutoff {
                continue;
            }
            let stats = parse_codex_tail(&fp);
            let net_input = stats.input_tokens.saturating_sub(stats.cache_read_tokens);
            let cost = stats
                .model
                .as_deref()
                .map(|m| {
                    estimate_cost(
                        m,
                        net_input,
                        stats.output_tokens,
                        0,
                        stats.cache_read_tokens,
                    )
                })
                .unwrap_or(0.0);
            let workspace = stats
                .cwd
                .as_deref()
                .and_then(|c| std::path::Path::new(c).file_name())
                .and_then(|s| s.to_str())
                .map(String::from)
                .unwrap_or_else(|| "?".to_string());
            s.codex_sessions += 1;
            s.total_tokens += stats.tokens;
            s.total_cost_usd += cost;
            let bucket = by_workspace.entry(workspace).or_default();
            bucket.0 += stats.tokens;
            bucket.1 += cost;
        }
    }
    // Sort workspaces by cost descending.
    let mut per_ws: Vec<(String, u64, f64)> = by_workspace
        .into_iter()
        .map(|(k, (tok, cost))| (k, tok, cost))
        .collect();
    per_ws.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));
    s.per_workspace = per_ws;
    s
}

/// Hardcoded per-model USD pricing (input / output / cache-write /
/// cache-read), all in dollars per 1M tokens. Numbers are public
/// pricing as of mid-2026; if Anthropic adjusts them, edit this
/// table. Unknown models return all-zeros so cost shows as 0.0
/// instead of a wrong number.
fn price_per_mt(model: &str) -> (f64, f64, f64, f64) {
    // Strip the trailing date suffix if present (e.g.
    // claude-haiku-4-5-20251001 → claude-haiku-4-5).
    let trimmed = model
        .rsplit_once('-')
        .map(|(stem, tail)| {
            if tail.chars().all(|c| c.is_ascii_digit()) && tail.len() >= 6 {
                stem
            } else {
                model
            }
        })
        .unwrap_or(model);
    match trimmed {
        "claude-opus-4-8" | "claude-opus-4-7" | "claude-opus-4-6" => (15.0, 75.0, 18.75, 1.50),
        "claude-sonnet-4-6" | "claude-sonnet-4-5" => (3.0, 15.0, 3.75, 0.30),
        "claude-haiku-4-5" | "claude-haiku-4-4" => (1.0, 5.0, 1.25, 0.10),
        // OpenAI codex models — placeholders. Cache cells (3rd / 4th)
        // are: write-rate / read-rate-per-MT. Codex's transcript
        // doesn't separate cache-write from regular input; we map
        // codex's `cached_input_tokens` to the cache-read column.
        "gpt-5" | "gpt-5.5" => (5.0, 30.0, 0.0, 0.50),
        "gpt-5-mini" | "gpt-5.5-mini" => (0.50, 2.0, 0.0, 0.05),
        "gpt-4o" => (2.50, 10.0, 0.0, 1.25),
        "gpt-4o-mini" => (0.15, 0.60, 0.0, 0.075),
        // Older / legacy / unknown.
        _ => (0.0, 0.0, 0.0, 0.0),
    }
}

/// Estimate cost for a row's accumulated tokens. Returns USD.
fn estimate_cost(model: &str, input: u64, output: u64, cache_create: u64, cache_read: u64) -> f64 {
    let (in_pmt, out_pmt, cw_pmt, cr_pmt) = price_per_mt(model);
    let f = |n: u64| n as f64 / 1_000_000.0;
    f(input) * in_pmt + f(output) * out_pmt + f(cache_create) * cw_pmt + f(cache_read) * cr_pmt
}

/// Pgrep for `claude` or `codex` processes. Returns either:
///   - `(session_id, pid, cmdline)` when `--session-id <uuid>` is in
///     the cmdline (Claude),
///   - `("", pid, cmdline)` for entries we can't tag with a session
///     id (Codex — usually no session arg).
fn scan_running_pids(source: AgentSource) -> Vec<(String, u32, String)> {
    let exe = source.exe_name();
    let out = std::process::Command::new("pgrep")
        .args(["-af", exe])
        .output();
    let Ok(o) = out else {
        return Vec::new();
    };
    if !o.status.success() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&o.stdout);
    let mut found: Vec<(String, u32, String)> = Vec::new();
    for line in text.lines() {
        let mut parts = line.splitn(2, ' ');
        let Some(pid_str) = parts.next() else {
            continue;
        };
        let Some(cmdline) = parts.next() else {
            continue;
        };
        let Ok(pid) = pid_str.parse::<u32>() else {
            continue;
        };
        // Defensive: pgrep -af "claude" hits any cmdline containing
        // "claude" — filter to ones where the binary actually
        // matches. The first token is the exe path.
        let first = cmdline.split_whitespace().next().unwrap_or("");
        let basename = std::path::Path::new(first)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        if basename != exe && !first.ends_with(&format!("/{exe}")) {
            continue;
        }
        let sid = parse_session_id_arg(cmdline).unwrap_or_default();
        found.push((sid, pid, cmdline.to_string()));
    }
    found
}

/// Walk a cmdline string for `--session-id <uuid>` (or `--resume <uuid>`).
fn parse_session_id_arg(cmdline: &str) -> Option<String> {
    let mut tokens = cmdline.split_whitespace();
    while let Some(t) = tokens.next() {
        if (t == "--session-id" || t == "--resume")
            && let Some(v) = tokens.next()
        {
            // UUID sanity check.
            if v.len() == 36 && v.matches('-').count() == 4 {
                return Some(v.to_string());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn parse_session_id_finds_uuid_after_flag() {
        let id = parse_session_id_arg(
            "/usr/bin/claude --session-id 12345678-1234-1234-1234-1234567890ab --foo bar",
        )
        .unwrap();
        assert_eq!(id.len(), 36);
    }

    #[test]
    fn parse_session_id_finds_resume_flag() {
        let id =
            parse_session_id_arg("claude --resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee").unwrap();
        assert!(id.contains("aaaa"));
    }

    #[test]
    fn parse_session_id_returns_none_when_absent() {
        assert!(parse_session_id_arg("claude --help").is_none());
    }

    #[test]
    fn workspace_decoder_takes_last_segment() {
        assert_eq!(decode_workspace_label("-Users-chris-Projects-mnml"), "mnml");
        assert_eq!(decode_workspace_label("-tmp-foo"), "foo");
    }

    #[test]
    fn tail_parses_assistant_event_with_tokens() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("session.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        let line = serde_json::json!({
            "type": "assistant",
            "timestamp": "2026-06-20T12:00:00Z",
            "cwd": "/Users/x/Projects/mnml",
            "gitBranch": "main",
            "message": {
                "model": "claude-opus-4-7",
                "content": [{"type":"text","text":"Hello back"}],
                "usage": {"input_tokens": 50, "output_tokens": 10}
            }
        });
        writeln!(f, "{line}").unwrap();
        let stats = parse_tail(&p);
        assert_eq!(stats.model.as_deref(), Some("claude-opus-4-7"));
        assert_eq!(stats.tokens, 60);
        assert_eq!(stats.cwd.as_deref(), Some("/Users/x/Projects/mnml"));
        assert_eq!(stats.git_branch.as_deref(), Some("main"));
        assert_eq!(stats.last_assistant_msg.as_deref(), Some("Hello back"));
    }

    #[test]
    fn tail_marks_last_assistant_as_tool_when_tool_use_only() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("session.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        let line = serde_json::json!({
            "type": "assistant",
            "message": {
                "model": "claude-opus-4-7",
                "content": [{"type":"tool_use","name":"Bash","input":{"command":"ls"}}],
                "usage": {"input_tokens": 5, "output_tokens": 2}
            }
        });
        writeln!(f, "{line}").unwrap();
        let stats = parse_tail(&p);
        assert!(stats.last_was_tool_call);
        assert_eq!(stats.last_assistant_msg.as_deref(), Some("⚙ Bash"));
    }

    #[test]
    fn parse_codex_tail_extracts_user_assistant_tokens_and_model() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("rollout-2026-06-20T23-25-18-abc.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        use std::io::Write;
        writeln!(
            f,
            r#"{{"timestamp":"2026-06-21T03:25:20.758Z","type":"session_meta","payload":{{"id":"x","cwd":"/Users/chrismclennan","cli_version":"0.141.0"}}}}"#
        )
        .unwrap();
        writeln!(
            f,
            r#"{{"timestamp":"2026-06-21T03:25:20.763Z","type":"turn_context","payload":{{"model":"gpt-5.5","cwd":"/Users/chrismclennan"}}}}"#
        )
        .unwrap();
        writeln!(
            f,
            r#"{{"timestamp":"2026-06-21T03:25:21.0Z","type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"hello"}}]}}}}"#
        )
        .unwrap();
        writeln!(
            f,
            r#"{{"timestamp":"2026-06-21T03:25:22.0Z","type":"response_item","payload":{{"type":"message","role":"assistant","content":[{{"type":"output_text","text":"Hello back"}}]}}}}"#
        )
        .unwrap();
        writeln!(
            f,
            r#"{{"timestamp":"2026-06-21T03:25:22.145Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":12229,"cached_input_tokens":9600,"output_tokens":15,"reasoning_output_tokens":0,"total_tokens":12244}}}}}}}}"#
        )
        .unwrap();
        let stats = parse_codex_tail(&p);
        assert_eq!(stats.cwd.as_deref(), Some("/Users/chrismclennan"));
        assert_eq!(stats.model.as_deref(), Some("gpt-5.5"));
        assert_eq!(stats.last_user_msg.as_deref(), Some("hello"));
        assert_eq!(stats.last_assistant_msg.as_deref(), Some("Hello back"));
        assert_eq!(stats.input_tokens, 12229);
        assert_eq!(stats.output_tokens, 15);
        assert_eq!(stats.cache_read_tokens, 9600);
        assert_eq!(stats.tokens, 12244);
    }

    #[test]
    fn parse_codex_tail_extracts_function_call_as_bash_and_tracks_pending() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("rollout-x.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        use std::io::Write;
        // function_call event (codex's only tool is exec_command;
        // the JSON-encoded `arguments` string carries the `cmd`).
        writeln!(
            f,
            r#"{{"timestamp":"t","type":"response_item","payload":{{"type":"function_call","name":"exec_command","arguments":"{{\"cmd\":\"cat /tmp/foo\"}}","call_id":"call_A"}}}}"#
        )
        .unwrap();
        // Matching output — pairs by call_id so pending drops to 0.
        writeln!(
            f,
            r#"{{"timestamp":"t","type":"response_item","payload":{{"type":"function_call_output","call_id":"call_A","output":"hello\n"}}}}"#
        )
        .unwrap();
        let stats = parse_codex_tail(&p);
        assert_eq!(stats.recent_bash, vec!["cat /tmp/foo".to_string()]);
        assert_eq!(stats.pending_tool_uses, 0);
        assert!(!stats.last_was_tool_call);
    }

    #[test]
    fn parse_codex_tail_marks_pending_when_function_call_has_no_output() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("rollout-x.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        use std::io::Write;
        writeln!(
            f,
            r#"{{"timestamp":"t","type":"response_item","payload":{{"type":"function_call","name":"exec_command","arguments":"{{\"cmd\":\"sleep 5\"}}","call_id":"call_B"}}}}"#
        )
        .unwrap();
        let stats = parse_codex_tail(&p);
        assert_eq!(stats.pending_tool_uses, 1);
        assert!(stats.last_was_tool_call);
        assert_eq!(stats.recent_bash, vec!["sleep 5".to_string()]);
    }

    #[test]
    fn parse_codex_tail_filters_environment_context_blocks() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("rollout-x.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        use std::io::Write;
        writeln!(
            f,
            r#"{{"timestamp":"x","type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"<environment_context>...</environment_context>"}}]}}}}"#
        )
        .unwrap();
        writeln!(
            f,
            r#"{{"timestamp":"x","type":"response_item","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"real message"}}]}}}}"#
        )
        .unwrap();
        let stats = parse_codex_tail(&p);
        assert_eq!(stats.last_user_msg.as_deref(), Some("real message"));
    }

    #[test]
    fn openai_cost_does_not_double_count_cached_portion() {
        // input_tokens=12229 with cached_input_tokens=9600 → only
        // 2629 tokens billed at full input rate, 9600 at cache rate.
        // gpt-5.5: input $5/MT, cache_read $0.50/MT.
        // Expected: 2629/1e6 × 5 + 9600/1e6 × 0.50 = 0.01315 + 0.0048
        //         = 0.01795
        // (Output omitted from this assertion — it's a separate axis.)
        let net = 12229u64.saturating_sub(9600);
        let cost = estimate_cost("gpt-5.5", net, 0, 0, 9600);
        // Tolerance for f64 wiggle.
        assert!((cost - 0.01795).abs() < 0.0001, "got {cost}");
    }

    #[test]
    fn gpt_5_5_pricing_is_in_table() {
        let (i, o, _, cr) = price_per_mt("gpt-5.5");
        assert!(i > 0.0 && o > 0.0 && cr > 0.0);
        assert!(o > i, "output should cost more than input");
    }

    #[test]
    fn read_byte_range_skips_partial_first_line_when_offset_nonzero() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("rolling.jsonl");
        std::fs::write(
            &p,
            b"line one is long here\n{\"k\":\"v\"}\n{\"second\":true}\n",
        )
        .unwrap();
        let s = read_byte_range(&p, 5, 50).unwrap();
        // First line is partial — should be dropped.
        assert!(!s.contains("line one"));
        assert!(s.contains("\"k\":\"v\""));
    }

    #[test]
    fn read_byte_range_returns_empty_when_no_new_bytes() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("rolling.jsonl");
        std::fs::write(&p, b"hello").unwrap();
        let s = read_byte_range(&p, 5, 5).unwrap();
        assert_eq!(s, "");
    }

    #[test]
    fn utc_stamp_has_yyyymmdd_hhmmss_shape() {
        let s = utc_stamp();
        // 8 + 1 + 6 = 15 chars: `YYYYMMDD-HHMMSS`.
        assert_eq!(s.len(), 15);
        assert_eq!(s.as_bytes()[8], b'-');
        // Year starts with 20 (test will only run past 2000).
        assert!(s.starts_with("20"));
        // Every other char is an ASCII digit.
        for (i, c) in s.char_indices() {
            if i == 8 {
                continue;
            }
            assert!(c.is_ascii_digit(), "non-digit at pos {i}: {c}");
        }
    }

    #[test]
    fn export_markdown_walks_user_and_assistant_blocks() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("session.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        use std::io::Write;
        writeln!(
            f,
            r#"{{"type":"user","message":{{"role":"user","content":"hello there"}}}}"#
        )
        .unwrap();
        writeln!(
            f,
            r#"{{"type":"assistant","message":{{"model":"x","content":[{{"type":"text","text":"hi back"}}]}}}}"#
        )
        .unwrap();
        writeln!(
            f,
            r#"{{"type":"assistant","message":{{"model":"x","content":[{{"type":"tool_use","name":"Bash","input":{{"command":"ls"}}}}]}}}}"#
        )
        .unwrap();
        let row = AgentRow {
            source: AgentSource::Claude,
            transcript_path: p.clone(),
            session_id: "abcdef12-3456-7890-aaaa-bbbbbbbbbbbb".to_string(),
            workspace: "x".to_string(),
            cwd: Some("/Users/x".to_string()),
            git_branch: Some("main".to_string()),
            model: Some("claude-opus-4-7".to_string()),
            last_activity: None,
            tokens: 0,
            input_tokens: 0,
            output_tokens: 0,
            cache_create_tokens: 0,
            cache_read_tokens: 0,
            cost_usd: 0.0,
            event_count: 0,
            last_user_msg: None,
            last_assistant_msg: None,
            pid: None,
            state: AgentState::Ended,
            current_tool: None,
            todos: Vec::new(),
            recent_bash: Vec::new(),
            recent_files: Vec::new(),
            recent_subagents: Vec::new(),
            pending_tool_uses: 0,
            tokens_per_min: None,
        };
        let (_stem, md) = export_transcript_as_markdown(&row).unwrap();
        assert!(md.contains("hello there"));
        assert!(md.contains("hi back"));
        assert!(md.contains("Bash"));
        assert!(md.contains("ls"));
        assert!(md.contains("# Claude session"));
    }

    #[test]
    fn search_finds_substring_across_transcripts() {
        // We can't easily redirect HOME, but we CAN unit-test the
        // helper that extracts the snippet from a single line.
        let v: serde_json::Value = serde_json::from_str(
            r#"{"type":"user","message":{"role":"user","content":"please run cargo build for me"}}"#,
        )
        .unwrap();
        let s = extract_user_snippet(&v, "cargo");
        assert!(s.is_some());
        assert_eq!(s.unwrap().0, SearchRole::User);
    }

    #[test]
    fn search_skips_system_reminder_user_messages() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"type":"user","message":{"role":"user","content":"<system-reminder>cargo info</system-reminder>"}}"#,
        )
        .unwrap();
        let s = extract_user_snippet(&v, "cargo");
        assert!(s.is_none());
    }

    #[test]
    fn search_extracts_bash_command_from_assistant_tool_use() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"type":"assistant","message":{"model":"x","content":[{"type":"tool_use","name":"Bash","input":{"command":"cargo build --release"}}]}}"#,
        )
        .unwrap();
        let s = extract_assistant_snippet(&v, "cargo build");
        assert!(s.is_some());
        let (role, snippet) = s.unwrap();
        assert_eq!(role, SearchRole::ToolBash);
        assert!(snippet.contains("cargo build"));
    }

    #[test]
    fn pricing_table_handles_known_models_and_falls_back_to_zero() {
        // Known opus model — non-zero pricing.
        let (i, o, _, _) = price_per_mt("claude-opus-4-7");
        assert!(i > 0.0 && o > 0.0);
        // Dated suffix is stripped.
        let (i2, o2, _, _) = price_per_mt("claude-haiku-4-5-20251001");
        assert!(i2 > 0.0 && o2 > 0.0);
        // Unknown model — zero (so cost displays "—" instead of wrong).
        let (i3, o3, _, _) = price_per_mt("gpt-5-turbo");
        assert_eq!(i3, 0.0);
        assert_eq!(o3, 0.0);
    }

    #[test]
    fn cost_computes_dollars_per_million_tokens() {
        // 1M input tokens at $15/MT = $15.
        let c = estimate_cost("claude-opus-4-7", 1_000_000, 0, 0, 0);
        assert!((c - 15.0).abs() < 0.001);
        // 1M output at $75/MT = $75.
        let c2 = estimate_cost("claude-opus-4-7", 0, 1_000_000, 0, 0);
        assert!((c2 - 75.0).abs() < 0.001);
    }

    #[test]
    fn agent_source_labels_are_unique() {
        // Sanity for the visual identity — labels are user-visible.
        assert_eq!(AgentSource::Claude.label(), "claude");
        assert_eq!(AgentSource::Codex.label(), "codex");
        assert_eq!(AgentSource::Claude.exe_name(), "claude");
        assert_eq!(AgentSource::Codex.exe_name(), "codex");
    }

    #[test]
    fn tail_filters_system_reminder_user_messages() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("session.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        let real_msg = serde_json::json!({
            "type": "user",
            "message": {"role": "user", "content": "Hello there"}
        });
        let reminder = serde_json::json!({
            "type": "user",
            "message": {"role": "user", "content": "<system-reminder>noise</system-reminder>"}
        });
        writeln!(f, "{real_msg}").unwrap();
        writeln!(f, "{reminder}").unwrap();
        let stats = parse_tail(&p);
        // Real message should win — reminder is filtered.
        assert_eq!(stats.last_user_msg.as_deref(), Some("Hello there"));
    }
}
