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
//! Follow-ups: stream the output incrementally instead of waiting for completion;
//! parse a returned patch into a `Pane::Diff` with accept/reject; tail the CLI
//! session JSONL so the pty pane and this view share a conversation.

use std::process::Command;

/// The `Pane::Ai` payload — one AI request and its answer.
pub struct AiPane {
    /// Short label for the bufferline / close prompt.
    pub title: String,
    /// The exact prompt sent to `claude -p` (re-sent on `r`).
    pub prompt: String,
    /// Matched against the worker's reply (re-fire / shifted indices ⇒ stale).
    pub job_id: u64,
    pub state: AiState,
    /// Top rendered row.
    pub scroll: usize,
}

pub enum AiState {
    Asking,
    Done(String),
    Failed(String),
}

impl AiPane {
    pub fn new(title: impl Into<String>, prompt: String, job_id: u64) -> Self {
        AiPane {
            title: title.into(),
            prompt,
            job_id,
            state: AiState::Asking,
            scroll: 0,
        }
    }
    pub fn tab_title(&self) -> String {
        let marker = match self.state {
            AiState::Asking => "…",
            AiState::Failed(_) => "✗",
            AiState::Done(_) => "✦",
        };
        format!("{} {marker}", self.title)
    }
}

/// The binary used for one-shot prompts. (`codex exec` could be wired similarly.)
const CLI: &str = "claude";

/// Run `claude -p <prompt>` to completion and return its stdout (trimmed), or a
/// one-line error. Blocking — call from a worker thread.
pub fn one_shot(prompt: &str) -> Result<String, String> {
    let out = Command::new(CLI)
        .arg("-p")
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
