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

/// User actions invokable on the selected row.
#[derive(Debug, Clone, Copy)]
pub enum ClaudeAgentsAction {
    YankSessionId,
    YankCwd,
    OpenTranscript,
}

/// One session in the dashboard.
#[derive(Debug, Clone)]
pub struct AgentRow {
    /// Absolute path to the .jsonl transcript.
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

pub struct ClaudeAgentsPane {
    pub rows: Vec<AgentRow>,
    pub selected: usize,
    pub scroll: usize,
    /// When the snapshot was built — shown in the title for clarity.
    pub built_at: SystemTime,
}

impl ClaudeAgentsPane {
    pub fn build() -> Self {
        let pids = scan_running_claude_pids();
        let rows = collect_rows(&pids);
        ClaudeAgentsPane {
            rows,
            selected: 0,
            scroll: 0,
            built_at: SystemTime::now(),
        }
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

    pub fn selected_row(&self) -> Option<&AgentRow> {
        self.rows.get(self.selected)
    }

    pub fn move_up(&mut self) {
        self.selected = self.selected.saturating_sub(1);
    }

    pub fn move_down(&mut self) {
        if self.selected + 1 < self.rows.len() {
            self.selected += 1;
        }
    }
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
fn collect_rows(pids: &[(String, u32)]) -> Vec<AgentRow> {
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
                .find_map(|(sid, pid)| (sid == session_id).then_some(*pid));
            let state = derive_state(pid.is_some(), mtime, &stats);
            rows.push(AgentRow {
                transcript_path: p.clone(),
                session_id: session_id.to_string(),
                workspace: workspace.clone(),
                cwd: stats.cwd,
                git_branch: stats.git_branch,
                model: stats.model,
                last_activity: mtime,
                tokens: stats.tokens,
                event_count: stats.event_count,
                last_user_msg: stats.last_user_msg,
                last_assistant_msg: stats.last_assistant_msg,
                pid,
                state,
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
    event_count: usize,
    last_user_msg: Option<String>,
    last_assistant_msg: Option<String>,
    last_was_tool_call: bool,
}

/// Tail-parse the .jsonl file. Reads up to the last 256KB and walks
/// every fully-terminated line backward.
fn parse_tail(path: &std::path::Path) -> TailStats {
    let mut stats = TailStats::default();
    let Ok(text) = read_tail(path, 256 * 1024) else {
        return stats;
    };
    let lines: Vec<&str> = text.lines().collect();
    // Walk forward so the LAST occurrence wins for the "last *" fields.
    let mut seen_assistant_text = false;
    let mut seen_user_msg = false;
    let mut last_assistant_was_tool = false;
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
                    stats.tokens = stats.tokens.saturating_add(i + o);
                }
                if let Some(content) = msg.and_then(|m| m.get("content")).and_then(|c| c.as_array())
                {
                    // First text block, OR sentinel for tool_use.
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
                                if tool_name.is_none() {
                                    tool_name =
                                        block.get("name").and_then(|n| n.as_str()).map(String::from);
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
                        seen_assistant_text = true;
                    }
                }
            }
            "user" => {
                let content = v
                    .get("message")
                    .and_then(|m| m.get("content"));
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
                    // Filter out tool_result / system reminders / hook
                    // outputs masquerading as user messages — they
                    // don't add signal.
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
    let s = s.trim();
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let cut: String = s.chars().take(max).collect();
        format!("{cut}…")
    }
}

/// Pgrep for `claude` processes, parse out the `--session-id <uuid>`
/// arg. Returns `(session_id, pid)` tuples. Best-effort — silently
/// returns empty on any failure.
fn scan_running_claude_pids() -> Vec<(String, u32)> {
    let out = std::process::Command::new("pgrep")
        .args(["-af", "claude"])
        .output();
    let Ok(o) = out else {
        return Vec::new();
    };
    if !o.status.success() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&o.stdout);
    let mut found: Vec<(String, u32)> = Vec::new();
    for line in text.lines() {
        // pgrep -af shape: "<pid> <full cmdline>".
        let mut parts = line.splitn(2, ' ');
        let Some(pid_str) = parts.next() else { continue };
        let Some(cmdline) = parts.next() else { continue };
        let Ok(pid) = pid_str.parse::<u32>() else { continue };
        if let Some(sid) = parse_session_id_arg(cmdline) {
            found.push((sid, pid));
        }
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
