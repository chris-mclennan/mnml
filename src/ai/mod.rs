//! The AI track — for now, one-shot `claude -p "<prompt>"` subprocesses (the
//! Claude Code CLI in print/non-interactive mode: it does tool use, returns text,
//! reuses the user's auth). A [`Pane::Ai`](crate::pane::Pane::Ai) shows the
//! answer (rendered as markdown); on-selection actions (`ai.explain` / `ai.fix` /
//! `ai.refactor` / `ai.write_tests`) and a free-text `ai.ask` build the prompt
//! and spawn the run. The work happens on a thread; [`crate::app::App::tick`]
//! polls the result channel — same pattern as the HTTP request pane.
//!
//! Deliberately *not* a raw Claude/OpenAI API client (see `.local/PLAN.md`):
//! interactive agentic AI is the `Pane::Pty` `claude`/`codex` panes; this is the
//! "do one thing to this code" surface.
//!
//! Each one-shot is given a session id, so a `Pane::Ai` can be *promoted* to a
//! full interactive Claude Code pane (`claude --resume <id>`) when you want to go
//! deeper — the quick answer isn't a dead end. A promoted (or any) session can
//! also be mirrored as a rendered transcript ([`transcript`], [`AiState::Live`]).
//!
//! Follow-ups: stream `claude -p` output incrementally instead of waiting for
//! completion; parse a returned patch into a `Pane::Diff` with accept/reject.

pub mod transcript;

use std::path::PathBuf;
use std::process::Command;

/// The `Pane::Ai` payload — either a `claude -p` one-shot (+ its answer) or a
/// live mirror of a Claude Code session transcript.
pub struct AiPane {
    /// Short label for the bufferline / close prompt.
    pub title: String,
    /// For a one-shot: the prompt sent to `claude -p` (re-sent on `r`). For a
    /// live mirror: a short label (the session id prefix).
    pub prompt: String,
    /// The Claude Code session id — `c` resumes it as an interactive pty pane.
    pub session_id: String,
    /// Matched against the worker's reply (re-fire / shifted indices ⇒ stale).
    pub job_id: u64,
    pub state: AiState,
    /// Top rendered row.
    pub scroll: usize,
}

pub enum AiState {
    /// A `claude -p` run is in flight.
    Asking,
    /// `claude -p` finished — its (markdown) answer.
    Done(String),
    /// `claude -p` failed — the error.
    Failed(String),
    /// A live mirror of a session transcript: `path` is the `.jsonl`, `last_len`
    /// the size we last parsed at, `turns` the parsed conversation.
    Live {
        path: PathBuf,
        last_len: u64,
        turns: Vec<transcript::Turn>,
    },
}

impl AiPane {
    pub fn new(title: impl Into<String>, prompt: String, session_id: String, job_id: u64) -> Self {
        AiPane {
            title: title.into(),
            prompt,
            session_id,
            job_id,
            state: AiState::Asking,
            scroll: 0,
        }
    }

    /// A live transcript mirror of `session_id` at `path` (read once now).
    pub fn live(session_id: String, path: PathBuf) -> Self {
        let turns = transcript::read(&path);
        let last_len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        let short: String = session_id.chars().take(8).collect();
        AiPane {
            title: format!("claude session {short}"),
            prompt: format!("session {short}"),
            session_id,
            job_id: 0,
            state: AiState::Live {
                path,
                last_len,
                turns,
            },
            scroll: usize::MAX, // start at the bottom (newest)
        }
    }

    pub fn is_live(&self) -> bool {
        matches!(self.state, AiState::Live { .. })
    }

    pub fn tab_title(&self) -> String {
        let marker = match self.state {
            AiState::Asking => "…",
            AiState::Failed(_) => "✗",
            AiState::Done(_) => "✦",
            AiState::Live { .. } => "●",
        };
        format!("{} {marker}", self.title)
    }
}

/// The binary used for one-shot prompts. (`codex exec` could be wired similarly.)
const CLI: &str = "claude";

/// Run `claude -p --session-id <session_id> <prompt>` to completion and return
/// its stdout (trimmed), or a one-line error. Blocking — call from a worker
/// thread. The session id lets the answer be resumed interactively later.
pub fn one_shot(prompt: &str, session_id: &str) -> Result<String, String> {
    let out = Command::new(CLI)
        .args(["-p", "--session-id", session_id])
        .arg(prompt)
        .output()
        .map_err(|e| format!("running `{CLI} -p`: {e} — is the Claude Code CLI on PATH?"))?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    if out.status.success() {
        let s = stdout.trim();
        if s.is_empty() {
            Err("(empty response)".to_string())
        } else {
            Ok(s.to_string())
        }
    } else {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let msg = [stderr.trim(), stdout.trim()]
            .into_iter()
            .find(|s| !s.is_empty())
            .unwrap_or("`claude -p` failed");
        Err(msg.lines().next().unwrap_or(msg).to_string())
    }
}

/// A fresh UUID-v4-shaped session id (from `/dev/urandom`, with a time+pid
/// fallback). Not crypto — just needs to be unique per `claude -p` run.
pub fn gen_session_id() -> String {
    let mut b = [0u8; 16];
    let filled = {
        use std::io::Read;
        std::fs::File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut b))
            .is_ok()
    };
    if !filled {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
            ^ ((std::process::id() as u128) << 64);
        let mut z = seed;
        for chunk in b.chunks_mut(8) {
            z = z.wrapping_add(0x9e37_79b9_7f4a_7c15);
            let mut x = z as u64;
            x = (x ^ (x >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
            x = (x ^ (x >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
            x ^= x >> 31;
            for (i, by) in chunk.iter_mut().enumerate() {
                *by = x.to_le_bytes()[i];
            }
        }
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let mut s = String::with_capacity(36);
    for (i, by) in b.iter().enumerate() {
        if matches!(i, 4 | 6 | 8 | 10) {
            s.push('-');
        }
        s.push_str(&format!("{by:02x}"));
    }
    s
}

// ── prompts for the on-selection actions ────────────────────────────

/// Wrap `code` in a fenced block tagged with `lang` (empty → untagged).
fn fenced(code: &str, lang: &str) -> String {
    format!("```{lang}\n{}\n```", code.trim_end_matches('\n'))
}

/// Build the prompt for an on-selection action. `what` is the kind id
/// (`explain`/`fix`/`refactor`/`write_tests`); `code` is the selection (or whole
/// buffer); `lang` is the buffer's language hint.
pub fn action_prompt(what: &str, code: &str, lang: &str) -> String {
    let block = fenced(code, lang);
    match what {
        "explain" => format!(
            "Explain what this {lang} code does, concisely. Cover its purpose, the \
             non-obvious bits, and anything that looks wrong.\n\n{block}"
        ),
        "fix" => format!(
            "Find and fix any bugs in this {lang} code. Reply with the corrected code \
             in a single fenced block, then a short bullet list of what you changed.\n\n{block}"
        ),
        "refactor" => format!(
            "Refactor this {lang} code for clarity without changing behaviour. Reply \
             with the refactored code in a single fenced block, then a short note on \
             what you did.\n\n{block}"
        ),
        "write_tests" => format!(
            "Write thorough unit tests for this {lang} code (idiomatic for the language; \
             cover the edge cases). Reply with the test code in a single fenced block.\n\n{block}"
        ),
        _ => format!("Look at this {lang} code:\n\n{block}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_prompt_includes_code_and_lang() {
        let p = action_prompt("explain", "fn x() {}", "rust");
        assert!(p.contains("```rust\nfn x() {}\n```"));
        assert!(p.to_lowercase().contains("explain"));
        let p = action_prompt("write_tests", "def f(): pass", "python");
        assert!(p.contains("```python"));
        assert!(p.to_lowercase().contains("test"));
    }
}
