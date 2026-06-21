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
    pub recent_files: Vec<String>,
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
        if matches!(self.state, AgentState::ToolCall) {
            if let Some(name) = &self.current_tool {
                let short: String = name.chars().take(8).collect();
                return format!("▸ {short}");
            }
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
    pub scroll: usize,
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
    /// Toggle the `?` help overlay rendered above the row list.
    pub show_help: bool,
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
    /// `(session_id → (sample_time, tokens))` — used to derive
    /// `tokens_per_min` between refreshes. Decays naturally as
    /// sessions roll off.
    pub token_samples: std::collections::HashMap<String, (SystemTime, u64)>,
    /// Multi-select set — `space` toggles a row's session id into
    /// this set; `K` kills every row in the set (falling back to
    /// the focused row when the set is empty).
    pub multi_selected: std::collections::HashSet<String>,
    /// Grouping mode for section headers in the row list. `g`
    /// cycles between source (current default) and workspace.
    pub group_by: GroupBy,
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
        let claude_pids = scan_running_pids(AgentSource::Claude);
        let codex_pids = scan_running_pids(AgentSource::Codex);
        let mut rows = collect_rows(&claude_pids);
        rows.extend(collect_codex_rows(&codex_pids));
        // Re-sort after merge so live entries from both backends
        // bubble to the top.
        rows.sort_by(|a, b| {
            state_rank(a.state)
                .cmp(&state_rank(b.state))
                .then_with(|| b.last_activity.cmp(&a.last_activity))
        });
        ClaudeAgentsPane {
            rows,
            selected: 0,
            scroll: 0,
            built_at: SystemTime::now(),
            query: String::new(),
            filter_mode: false,
            detail: DetailView::Summary,
            paused: false,
            paused_by_user: false,
            state_filter: None,
            show_help: false,
            last_live_tail: SystemTime::now(),
            prior_state_snapshot: std::collections::HashMap::new(),
            token_samples: std::collections::HashMap::new(),
            multi_selected: std::collections::HashSet::new(),
            group_by: GroupBy::Source,
        }
    }

    /// Walk `self.rows`, compute `tokens_per_min` from the
    /// `token_samples` cache. Updates the cache with the latest
    /// sample for each row. Called from `refresh_in_place` after
    /// row data is settled, and from `live_tail_selected` for the
    /// single row.
    pub fn recompute_token_rates(&mut self) {
        let now = SystemTime::now();
        let mut new_samples: std::collections::HashMap<String, (SystemTime, u64)> =
            std::collections::HashMap::new();
        for row in &mut self.rows {
            // Only live sessions get a rate.
            if !matches!(row.state, AgentState::Streaming | AgentState::ToolCall) {
                row.tokens_per_min = None;
                new_samples.insert(row.session_id.clone(), (now, row.tokens));
                continue;
            }
            if let Some(&(prev_ts, prev_tokens)) = self.token_samples.get(&row.session_id) {
                let dt = now.duration_since(prev_ts).map(|d| d.as_secs_f64()).unwrap_or(0.0);
                let dtok = row.tokens.saturating_sub(prev_tokens);
                if dt > 0.5 && dtok > 0 {
                    row.tokens_per_min = Some((dtok as f64) * 60.0 / dt);
                } else {
                    row.tokens_per_min = None;
                }
            } else {
                row.tokens_per_min = None;
            }
            new_samples.insert(row.session_id.clone(), (now, row.tokens));
        }
        self.token_samples = new_samples;
    }

    /// Re-tail JUST the selected row's transcript (if it's a live
    /// session) and write updated drill-down fields back into the
    /// row. No re-sort, no PID re-scan — much cheaper than the
    /// full `refresh_in_place`, and stable for the cursor. Returns
    /// `true` if the row was actually updated.
    pub fn live_tail_selected(&mut self) -> bool {
        let Some(vi) = self
            .visible_indices()
            .get(self.selected)
            .copied()
        else {
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
            row.tokens = stats.tokens;
            row.input_tokens = stats.input_tokens;
            row.output_tokens = stats.output_tokens;
            row.cache_create_tokens = stats.cache_create_tokens;
            row.cache_read_tokens = stats.cache_read_tokens;
            row.cost_usd = cost;
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
            new_snapshot.insert(
                row.session_id.clone(),
                (row.state, row.pending_tool_uses),
            );
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
        self.recompute_token_rates();
        if let Some(sid) = prior_sid
            && let Some(new_idx) = self
                .visible_indices()
                .iter()
                .position(|&i| self.rows.get(i).map(|r| &r.session_id) == Some(&sid))
        {
            self.selected = new_idx;
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
            a.pending_confirms =
                a.pending_confirms.saturating_add(r.pending_tool_uses as u64);
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
        self.rows
            .iter()
            .enumerate()
            .filter(|(_, r)| {
                if let Some(sf) = self.state_filter
                    && r.state != sf
                {
                    return false;
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
            .collect()
    }

    pub fn selected_row(&self) -> Option<&AgentRow> {
        let vis = self.visible_indices();
        vis.get(self.selected).and_then(|&i| self.rows.get(i))
    }

    pub fn move_up(&mut self) {
        self.selected = self.selected.saturating_sub(1);
    }

    pub fn move_down(&mut self) {
        let n = self.visible_indices().len();
        if self.selected + 1 < n {
            self.selected += 1;
        }
    }

    pub fn cycle_detail(&mut self) {
        self.detail = self.detail.cycle();
    }

    pub fn cycle_group_by(&mut self) {
        self.group_by = self.group_by.cycle();
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

/// Codex CLI rows. The OpenAI codex stores session jsonl at
/// `~/.codex/sessions/<sid>.jsonl` (best-effort detection — falls
/// back to PID+cmdline-only rows when the directory doesn't exist).
/// We don't claim drill-down parity with Claude: per-tool sidecars
/// (TodoList, Bash, recent files) all stay empty for codex rows
/// for now. If/when the codex transcript format stabilizes we can
/// teach `parse_tail` about it.
fn collect_codex_rows(pids: &[(String, u32, String)]) -> Vec<AgentRow> {
    let mut rows: Vec<AgentRow> = Vec::new();
    let sessions_dir = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".codex/sessions"));

    // 1. Sessions on disk (Codex writes one .jsonl per session under
    //    ~/.codex/sessions/ when present).
    if let Some(dir) = sessions_dir.as_deref()
        && let Ok(files) = std::fs::read_dir(dir)
    {
        for f in files.flatten() {
            let p = f.path();
            let name = match p.file_name().and_then(|s| s.to_str()) {
                Some(n) => n.to_string(),
                None => continue,
            };
            let Some(session_id) = name.strip_suffix(".jsonl") else {
                continue;
            };
            let session_id = session_id.to_string();
            let Ok(meta) = f.metadata() else { continue };
            let mtime = meta.modified().ok();
            if let Some(t) = mtime
                && let Ok(age) = SystemTime::now().duration_since(t)
                && age.as_secs() > 7 * 24 * 3600
            {
                continue;
            }
            let pid = pids
                .iter()
                .find_map(|(sid, pid, _)| (sid == &session_id).then_some(*pid));
            let state = if pid.is_some() {
                let fresh = mtime
                    .and_then(|t| SystemTime::now().duration_since(t).ok())
                    .is_some_and(|d| d.as_secs() < 60);
                if fresh {
                    AgentState::Streaming
                } else {
                    AgentState::Idle
                }
            } else {
                AgentState::Ended
            };
            // Try a generic last-line peek so the user sees SOMETHING
            // in the detail panel for codex sessions. Best-effort.
            let blurb = peek_last_text_line(&p);
            rows.push(AgentRow {
                source: AgentSource::Codex,
                transcript_path: p,
                session_id,
                workspace: "?".to_string(),
                cwd: None,
                git_branch: None,
                model: None,
                last_activity: mtime,
                tokens: 0,
                input_tokens: 0,
                output_tokens: 0,
                cache_create_tokens: 0,
                cache_read_tokens: 0,
                cost_usd: 0.0,
                event_count: 0,
                last_user_msg: None,
                last_assistant_msg: blurb,
                pid,
                state,
                current_tool: None,
                todos: Vec::new(),
                recent_bash: Vec::new(),
                recent_files: Vec::new(),
                recent_subagents: Vec::new(),
                pending_tool_uses: 0,
                tokens_per_min: None,
            });
        }
    }

    // 2. Running PIDs that don't map to a known on-disk session —
    //    add stub rows so the user still sees them. Distinguish via
    //    session_id == "" (placeholder).
    let on_disk_pids: std::collections::HashSet<u32> =
        rows.iter().filter_map(|r| r.pid).collect();
    for (_, pid, cmdline) in pids {
        if on_disk_pids.contains(pid) {
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

/// Return the cwd of a running process. Uses `lsof -p PID` on macOS,
/// `/proc/<pid>/cwd` on Linux. Best-effort; returns `None` on any
/// failure.
fn read_pid_cwd(pid: u32) -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let p = std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
        return Some(p.to_string_lossy().into_owned());
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

/// Quick peek at the last line of a Codex transcript — returns the
/// first text field we can extract for the detail panel. Best-effort.
fn peek_last_text_line(path: &std::path::Path) -> Option<String> {
    let text = read_tail(path, 32 * 1024).ok()?;
    let last = text.lines().last()?;
    let v: serde_json::Value = serde_json::from_str(last).ok()?;
    let content = v
        .get("content")
        .or_else(|| v.get("text"))
        .or_else(|| v.get("message").and_then(|m| m.get("content")))
        .and_then(|x| x.as_str())?;
    Some(truncate(content, 200))
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
    /// Recent Edit/Write file paths (most recent first, capped at 10).
    recent_files: Vec<String>,
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
                    let i = usage.get("input_tokens").and_then(|n| n.as_u64()).unwrap_or(0);
                    let o = usage.get("output_tokens").and_then(|n| n.as_u64()).unwrap_or(0);
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
                if let Some(content) = msg.and_then(|m| m.get("content")).and_then(|c| c.as_array())
                {
                    let mut text_acc: Option<String> = None;
                    let mut tool_name: Option<String> = None;
                    for block in content {
                        let bt = block.get("type").and_then(|t| t.as_str()).unwrap_or("");
                        match bt {
                            "text" => {
                                if text_acc.is_none() {
                                    text_acc = block
                                        .get("text")
                                        .and_then(|t| t.as_str())
                                        .map(|s| truncate(s, 200));
                                }
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
                                        if let Some(arr) =
                                            input.and_then(|i| i.get("todos")).and_then(|t| t.as_array())
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
                                        if let Some(cmd) =
                                            input.and_then(|i| i.get("command")).and_then(|c| c.as_str())
                                        {
                                            stats.recent_bash.insert(0, truncate(cmd, 96));
                                            stats.recent_bash.truncate(10);
                                        }
                                    }
                                    "Edit" | "Write" | "NotebookEdit" => {
                                        if let Some(p) =
                                            input.and_then(|i| i.get("file_path")).and_then(|f| f.as_str())
                                        {
                                            // Trim long paths to the last 2 segments.
                                            let short = std::path::Path::new(p)
                                                .components()
                                                .rev()
                                                .take(2)
                                                .collect::<Vec<_>>()
                                                .into_iter()
                                                .rev()
                                                .map(|c| c.as_os_str().to_string_lossy().into_owned())
                                                .collect::<Vec<_>>()
                                                .join("/");
                                            let entry = format!("{name} {short}");
                                            if !stats.recent_files.iter().any(|e| e == &entry) {
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
                                        stats.recent_subagents
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
                let content = v
                    .get("message")
                    .and_then(|m| m.get("content"));
                // Look for tool_result blocks first — match them
                // against the pending set so we can compute pending
                // tool-use count.
                if let Some(serde_json::Value::Array(arr)) = content {
                    for b in arr {
                        if b.get("type").and_then(|t| t.as_str()) == Some("tool_result") {
                            if let Some(id) =
                                b.get("tool_use_id").and_then(|i| i.as_str())
                            {
                                pending.remove(id);
                            }
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
    if start > 0 {
        if let Some(nl) = s.find('\n') {
            return Ok(s[nl + 1..].to_string());
        }
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
        // Older / legacy / unknown.
        _ => (0.0, 0.0, 0.0, 0.0),
    }
}

/// Estimate cost for a row's accumulated tokens. Returns USD.
fn estimate_cost(
    model: &str,
    input: u64,
    output: u64,
    cache_create: u64,
    cache_read: u64,
) -> f64 {
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
        let Some(pid_str) = parts.next() else { continue };
        let Some(cmdline) = parts.next() else { continue };
        let Ok(pid) = pid_str.parse::<u32>() else { continue };
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
        if t == "--session-id" || t == "--resume" {
            if let Some(v) = tokens.next() {
                // UUID sanity check.
                if v.len() == 36 && v.matches('-').count() == 4 {
                    return Some(v.to_string());
                }
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
