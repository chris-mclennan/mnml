//! The AI track. Two backends, picked by `[ai] backend` (see [`AiBackend`]):
//! `Cli` shells out to one-shot `claude -p "<prompt>"` subprocesses (the Claude
//! Code CLI in print mode — full tool use, the user's auth); `Api` posts
//! directly to `api.anthropic.com/v1/messages` ([`api_client`]) with an agentic
//! loop of its own (read-only — and optionally write — workspace tools). A
//! [`Pane::Ai`](crate::pane::Pane::Ai) shows the answer (rendered as markdown);
//! on-selection actions (`ai.explain` / `ai.fix` / `ai.refactor` /
//! `ai.write_tests`) and a free-text `ai.ask` build the prompt and spawn the
//! run. The work happens on a thread; [`crate::app::App::tick`] polls the
//! result channel — same pattern as the HTTP request pane.
//!
//! Interactive agentic AI is the `Pane::Pty` `claude`/`codex` panes; the
//! `Pane::Ai` surface is the "ask / do one thing to this code" path.
//!
//! Each one-shot is given a session id, so a `Pane::Ai` can be *promoted* to a
//! full interactive Claude Code pane (`claude --resume <id>`) when you want to go
//! deeper — the quick answer isn't a dead end. A promoted (or any) session can
//! also be mirrored as a rendered transcript ([`transcript`], [`AiState::Live`]).
//!
//! An on-selection `fix`/`refactor` answer carries an [`ApplyTarget`] (the source
//! file + byte range it was asked about); the first `a` in the pane extracts the
//! answer's first fenced code block ([`first_code_block`]), diffs it against the
//! live range ([`line_diff`] → a [`PendingApply`] the pane previews), and a second
//! `a` writes it back over that range (left dirty for review).
//!
//! An in-flight `-p` run can be cancelled (`x` in the pane): the worker uses
//! [`stream_to_channel`] / [`one_shot_cancellable`], which poll an `AtomicBool`
//! and kill the child.
//!
//! Output is streamed: [`stream_to_channel`] forwards stdout chunks as
//! [`AiMsg::Delta`]s while the run is in flight (the pane shows them as they
//! arrive — [`AiState::Streaming`]), then a final [`AiMsg::Done`] with the clean
//! trimmed answer (or [`AiMsg::Failed`]).

pub mod api_client;
pub mod transcript;

/// Which backend an AI job hits. `Cli` shells out to `claude -p` (the
/// default — uses the user's Claude Code auth / subscription, full tool
/// use). `Api` posts directly to `https://api.anthropic.com/v1/messages`
/// with SSE streaming + its own agentic tool loop (read-only workspace
/// tools by default; see `[ai] api_tools`). Requires `$ANTHROPIC_API_KEY`
/// and bills API credits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AiBackend {
    Cli,
    Api,
}

impl AiBackend {
    pub fn parse(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "api" | "http" | "direct" => AiBackend::Api,
            _ => AiBackend::Cli,
        }
    }
}

/// Which engine produces inline ghost-text completions. `Unset` means
/// the user hasn't picked yet — enabling inline suggestions opens the
/// setup picker. `ClaudeApi` uses `api_client::complete_code`. `Local`
/// is the `fim-engine` candle-embedded model (a managed ~1 GB GGUF
/// download, runs in-process — offline, no API key).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SuggestBackend {
    Unset,
    ClaudeApi,
    Local,
}

impl SuggestBackend {
    pub fn parse(s: &str) -> Self {
        match s.to_ascii_lowercase().as_str() {
            "claude-api" | "claude" | "api" => SuggestBackend::ClaudeApi,
            "local" | "candle" => SuggestBackend::Local,
            _ => SuggestBackend::Unset,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            SuggestBackend::Unset => "unset",
            SuggestBackend::ClaudeApi => "claude-api",
            SuggestBackend::Local => "local",
        }
    }
}

use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// Where an on-selection AI action's suggested code can be applied back: the
/// source file + the byte range that was sent (a selection, or the whole
/// buffer). Captured at ask-time; on `a` in the answer pane the first fenced
/// code block replaces this range (left dirty for review). Offsets are clamped
/// to the buffer's current length on apply, so a since-then edit can't corrupt.
#[derive(Debug, Clone)]
pub struct ApplyTarget {
    pub path: PathBuf,
    pub start: usize,
    pub end: usize,
}

/// The contents of the first fenced code block (```… or ~~~…) in markdown `md`,
/// with the trailing newline trimmed. `None` if there's no fence. An unterminated
/// block returns whatever followed the opening fence.
pub fn first_code_block(md: &str) -> Option<String> {
    let mut in_block = false;
    let mut out = String::new();
    for line in md.lines() {
        let is_fence = {
            let t = line.trim_start();
            t.starts_with("```") || t.starts_with("~~~")
        };
        if !in_block {
            if is_fence {
                in_block = true;
            }
            continue;
        }
        if is_fence {
            return Some(out.trim_end_matches('\n').to_string());
        }
        out.push_str(line);
        out.push('\n');
    }
    in_block.then(|| out.trim_end_matches('\n').to_string())
}

/// One line of a [`line_diff`] preview.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffLine {
    /// Unchanged context (may be the synthetic `… N lines …` elision).
    Ctx(String),
    /// A removed line.
    Del(String),
    /// An added line.
    Add(String),
}

/// A minimal line diff `old` → `new`: trim the common prefix/suffix lines (keep
/// up to `CTX` of each, with an elision marker if more were dropped), then emit
/// the changed middle as `Del`s then `Add`s. Good enough for previewing an AI
/// suggestion over a selection (it's not a real LCS — two distant edit regions
/// collapse into one block, which is fine here).
pub fn line_diff(old: &str, new: &str) -> Vec<DiffLine> {
    const CTX: usize = 3;
    let o: Vec<&str> = old.split('\n').collect();
    let n: Vec<&str> = new.split('\n').collect();
    let mut pre = 0;
    while pre < o.len() && pre < n.len() && o[pre] == n[pre] {
        pre += 1;
    }
    let mut suf = 0;
    while suf < o.len() - pre && suf < n.len() - pre && o[o.len() - 1 - suf] == n[n.len() - 1 - suf]
    {
        suf += 1;
    }
    let mut out: Vec<DiffLine> = Vec::new();
    let push_ctx = |lines: &[&str], from_end: bool, out: &mut Vec<DiffLine>| {
        if lines.len() <= CTX {
            for l in lines {
                out.push(DiffLine::Ctx(l.to_string()));
            }
        } else if from_end {
            out.push(DiffLine::Ctx(format!(
                "… {} unchanged lines …",
                lines.len() - CTX
            )));
            for l in &lines[lines.len() - CTX..] {
                out.push(DiffLine::Ctx(l.to_string()));
            }
        } else {
            for l in &lines[..CTX] {
                out.push(DiffLine::Ctx(l.to_string()));
            }
            out.push(DiffLine::Ctx(format!(
                "… {} unchanged lines …",
                lines.len() - CTX
            )));
        }
    };
    if pre > 0 {
        // The leading context is the *suffix* of the common-prefix block.
        push_ctx(&o[..pre], true, &mut out);
    }
    for l in &o[pre..o.len() - suf] {
        out.push(DiffLine::Del(l.to_string()));
    }
    for l in &n[pre..n.len() - suf] {
        out.push(DiffLine::Add(l.to_string()));
    }
    if suf > 0 {
        push_ctx(&o[o.len() - suf..], false, &mut out);
    }
    out
}

/// A pending "apply this AI suggestion" awaiting confirmation: where it goes +
/// the new code + the preview diff (`a` again applies; `r` re-ask clears it).
#[derive(Debug, Clone)]
pub struct PendingApply {
    pub target: ApplyTarget,
    pub code: String,
    pub diff: Vec<DiffLine>,
}

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
    /// For an on-selection `fix`/`refactor`: where the suggested code can be
    /// applied back (`a` in the pane). `None` for explain / free-text asks / etc.
    pub target: Option<ApplyTarget>,
    /// First `a` stages the suggestion here (with a diff preview); a second `a`
    /// applies it. Cleared on apply / re-ask.
    pub pending_apply: Option<PendingApply>,
    /// Set this to ask an in-flight `claude -p` worker to kill its child and
    /// bail (`x` in the pane while `Asking`). Replaced on each re-ask.
    pub cancel: Arc<AtomicBool>,
}

pub enum AiState {
    /// A `claude -p` run is in flight; no output yet.
    Asking,
    /// A `claude -p` run is in flight and streaming — the text so far.
    Streaming(String),
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
    pub fn new(
        title: impl Into<String>,
        prompt: String,
        session_id: String,
        job_id: u64,
        cancel: Arc<AtomicBool>,
    ) -> Self {
        AiPane {
            title: title.into(),
            prompt,
            session_id,
            job_id,
            state: AiState::Asking,
            scroll: 0,
            target: None,
            pending_apply: None,
            cancel,
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
            target: None,
            pending_apply: None,
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn is_live(&self) -> bool {
        matches!(self.state, AiState::Live { .. })
    }

    /// The text the user sees in the answer body, suitable for copying.
    /// `None` while no answer is rendered yet (Asking with no deltas) or
    /// for `Live` mirrors (those are scroll-back transcripts, not a
    /// single answer body — copy via the buffer instead).
    pub fn answer_text(&self) -> Option<&str> {
        match &self.state {
            AiState::Streaming(s) | AiState::Done(s) => Some(s.as_str()),
            AiState::Failed(s) => Some(s.as_str()),
            AiState::Asking | AiState::Live { .. } => None,
        }
    }

    pub fn tab_title(&self) -> String {
        let marker = match self.state {
            AiState::Asking | AiState::Streaming(_) => "…",
            AiState::Failed(_) => "✗",
            AiState::Done(_) => "✦",
            AiState::Live { .. } => "●",
        };
        format!("{} {marker}", self.title)
    }
}

/// The binary used for one-shot prompts. (`codex exec` could be wired similarly.)
const CLI: &str = "claude";

/// A message a streaming `claude -p` worker sends back over `App.ai_chan`.
#[derive(Debug, Clone)]
pub enum AiMsg {
    /// More stdout text (append it to the pane's running buffer).
    Delta(String),
    /// The run finished — the full, trimmed answer (replaces the buffer).
    Done(String),
    /// The run failed (or was cancelled) — the reason.
    Failed(String),
    /// Token usage for the just-finished API request — sent just before
    /// `Done` by the direct-API workers (the CLI backend doesn't report
    /// it). Drives the session token/cost tally.
    Usage {
        input_tokens: u64,
        output_tokens: u64,
    },
    /// The agent loop wants to run a risky tool (a `write_file`) and is
    /// **blocked** waiting for the user to approve. The main thread opens
    /// a confirm prompt and replies through the job's confirm channel.
    /// `summary` describes the pending action.
    ConfirmTool { summary: String },
}

/// Run `claude -p --session-id <session_id> <prompt>`, forwarding stdout chunks
/// to `sink` as [`AiMsg::Delta`]s as they arrive, then a final [`AiMsg::Done`]
/// (trimmed stdout) or [`AiMsg::Failed`]. Checks `cancel` while the child runs
/// (kills it + reports `"cancelled"` if it goes true). Blocking — call from a
/// worker thread; every message is tagged with `job_id`.
pub fn stream_to_channel(
    prompt: &str,
    session_id: &str,
    cancel: &AtomicBool,
    sink: std::sync::mpsc::Sender<(u64, AiMsg)>,
    job_id: u64,
) {
    stream_cli_to_channel(
        CLI,
        &["-p", "--session-id", session_id, prompt],
        cancel,
        sink,
        job_id,
        "Claude Code",
    );
}

/// `codex exec <prompt>` variant. Mirrors [`stream_to_channel`] for the
/// OpenAI Codex CLI — used by `git.codex_commit` to get an AI-written
/// commit message from `codex` instead of `claude`. (No session id —
/// codex's invocation is stateless per call.)
pub fn stream_codex_to_channel(
    prompt: &str,
    cancel: &AtomicBool,
    sink: std::sync::mpsc::Sender<(u64, AiMsg)>,
    job_id: u64,
) {
    stream_cli_to_channel(
        "codex",
        &["exec", prompt],
        cancel,
        sink,
        job_id,
        "Codex CLI",
    );
}

/// Shared spawn-and-pump core. Splits out the bin / args from the
/// streaming machinery so `claude -p` and `codex exec` can both flow
/// through it without duplicating the reader-thread + cancel-loop logic.
fn stream_cli_to_channel(
    bin: &str,
    args: &[&str],
    cancel: &AtomicBool,
    sink: std::sync::mpsc::Sender<(u64, AiMsg)>,
    job_id: u64,
    friendly_name: &str,
) {
    use std::io::Read;
    use std::process::Stdio;
    let mut child = match Command::new(bin)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            let _ = sink.send((
                job_id,
                AiMsg::Failed(format!(
                    "running `{bin}`: {e} — is the {friendly_name} on PATH?"
                )),
            ));
            return;
        }
    };
    let mut so = child.stdout.take().expect("piped stdout");
    let mut se = child.stderr.take().expect("piped stderr");
    // Reader thread: pump stdout chunks straight to `sink` (lossy UTF-8 per
    // chunk — a split multibyte char is transient; the final `Done` is clean),
    // accumulating the raw bytes to return on join.
    let chunk_sink = sink.clone();
    let so_h = std::thread::spawn(move || {
        let mut acc = Vec::new();
        let mut buf = [0u8; 4096];
        loop {
            match so.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    acc.extend_from_slice(&buf[..n]);
                    let _ = chunk_sink.send((
                        job_id,
                        AiMsg::Delta(String::from_utf8_lossy(&buf[..n]).into_owned()),
                    ));
                }
            }
        }
        acc
    });
    let se_h = std::thread::spawn(move || {
        let mut v = Vec::new();
        let _ = se.read_to_end(&mut v);
        v
    });
    let mut killed = false;
    loop {
        if !killed && cancel.load(Ordering::Relaxed) {
            let _ = child.kill();
            killed = true;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                let out = so_h.join().unwrap_or_default();
                let err = se_h.join().unwrap_or_default();
                let _ = sink.send((job_id, settle(killed, status.success(), &out, &err)));
                return;
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(40)),
            Err(e) => {
                let _ = sink.send((job_id, AiMsg::Failed(format!("waiting on `{bin}`: {e}"))));
                return;
            }
        }
    }
}

/// Decide the final [`AiMsg`] for a finished `claude -p` from `(was it killed,
/// exited 0, stdout, stderr)`.
fn settle(killed: bool, success: bool, stdout: &[u8], stderr: &[u8]) -> AiMsg {
    if killed {
        return AiMsg::Failed("cancelled".to_string());
    }
    let out = String::from_utf8_lossy(stdout);
    if success {
        let s = out.trim();
        return if s.is_empty() {
            AiMsg::Failed("(empty response)".to_string())
        } else {
            AiMsg::Done(s.to_string())
        };
    }
    let err = String::from_utf8_lossy(stderr);
    let m = [err.trim(), out.trim()]
        .into_iter()
        .find(|s| !s.is_empty())
        .unwrap_or("`claude -p` failed");
    AiMsg::Failed(m.lines().next().unwrap_or(m).to_string())
}

/// Run `claude -p --session-id <session_id> <prompt>` to completion and return
/// its stdout (trimmed), or a one-line error. Blocking — call from a worker
/// thread. The session id lets the answer be resumed interactively later.
pub fn one_shot(prompt: &str, session_id: &str) -> Result<String, String> {
    one_shot_cancellable(prompt, session_id, &AtomicBool::new(false))
}

/// Like [`one_shot`], but checks `cancel` while the child runs: if it goes true,
/// the child is killed and `Err("cancelled")` returned. (Polls every ~40 ms;
/// stdout/stderr are drained on threads so a large answer can't deadlock the
/// pipes.) Blocking — call from a worker thread.
pub fn one_shot_cancellable(
    prompt: &str,
    session_id: &str,
    cancel: &AtomicBool,
) -> Result<String, String> {
    use std::io::Read;
    use std::process::Stdio;
    let mut child = Command::new(CLI)
        .args(["-p", "--session-id", session_id])
        .arg(prompt)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("running `{CLI} -p`: {e} — is the Claude Code CLI on PATH?"))?;
    let mut so = child.stdout.take().expect("piped stdout");
    let mut se = child.stderr.take().expect("piped stderr");
    let so_h = std::thread::spawn(move || {
        let mut v = Vec::new();
        let _ = so.read_to_end(&mut v);
        v
    });
    let se_h = std::thread::spawn(move || {
        let mut v = Vec::new();
        let _ = se.read_to_end(&mut v);
        v
    });
    let mut killed = false;
    loop {
        if !killed && cancel.load(Ordering::Relaxed) {
            let _ = child.kill();
            killed = true;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                let out = so_h.join().unwrap_or_default();
                let err = se_h.join().unwrap_or_default();
                if killed {
                    return Err("cancelled".to_string());
                }
                let stdout = String::from_utf8_lossy(&out);
                if status.success() {
                    let s = stdout.trim();
                    return if s.is_empty() {
                        Err("(empty response)".to_string())
                    } else {
                        Ok(s.to_string())
                    };
                }
                let stderr = String::from_utf8_lossy(&err);
                let msg = [stderr.trim(), stdout.trim()]
                    .into_iter()
                    .find(|s| !s.is_empty())
                    .unwrap_or("`claude -p` failed");
                return Err(msg.lines().next().unwrap_or(msg).to_string());
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(40)),
            Err(e) => return Err(format!("waiting on `{CLI} -p`: {e}")),
        }
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
    fn first_code_block_extracts_the_fence() {
        let md = "Here's the fix:\n\n```rust\nfn x() -> i32 { 1 }\n```\n\n- changed the return\n";
        assert_eq!(first_code_block(md).as_deref(), Some("fn x() -> i32 { 1 }"));
        assert_eq!(first_code_block("no code here").as_deref(), None);
        // unterminated → whatever followed the opener
        assert_eq!(first_code_block("```\na\nb\n").as_deref(), Some("a\nb"));
        // only the *first* block
        assert_eq!(
            first_code_block("```\nfirst\n```\n```\nsecond\n```").as_deref(),
            Some("first")
        );
    }

    #[test]
    fn settle_picks_the_right_outcome() {
        assert!(matches!(settle(true, false, b"x", b""), AiMsg::Failed(m) if m == "cancelled"));
        assert!(matches!(settle(false, true, b"  hello  \n", b""), AiMsg::Done(m) if m == "hello"));
        assert!(
            matches!(settle(false, true, b"   \n  ", b""), AiMsg::Failed(m) if m == "(empty response)")
        );
        // failure → first non-empty of stderr / stdout, first line only.
        assert!(
            matches!(settle(false, false, b"", b"boom: bad\nmore"), AiMsg::Failed(m) if m == "boom: bad")
        );
        assert!(
            matches!(settle(false, false, b"stdout err", b""), AiMsg::Failed(m) if m == "stdout err")
        );
        assert!(
            matches!(settle(false, false, b"", b""), AiMsg::Failed(m) if m == "`claude -p` failed")
        );
    }

    #[test]
    fn line_diff_trims_common_prefix_and_suffix() {
        use DiffLine::*;
        // A change in the middle, short context kept verbatim.
        let d = line_diff("a\nb\nOLD\nc\nd", "a\nb\nNEW1\nNEW2\nc\nd");
        assert_eq!(
            d,
            vec![
                Ctx("a".into()),
                Ctx("b".into()),
                Del("OLD".into()),
                Add("NEW1".into()),
                Add("NEW2".into()),
                Ctx("c".into()),
                Ctx("d".into()),
            ]
        );
        // Pure append: no Del, just the new tail.
        assert_eq!(
            line_diff("a\nb", "a\nb\nc"),
            vec![Ctx("a".into()), Ctx("b".into()), Add("c".into())]
        );
        // Long leading context is elided down to 3 lines (+ a marker).
        let d = line_diff("1\n2\n3\n4\n5\nX", "1\n2\n3\n4\n5\nY");
        assert_eq!(d[0], Ctx("… 2 unchanged lines …".into()));
        assert_eq!(
            &d[1..],
            &[
                Ctx("3".into()),
                Ctx("4".into()),
                Ctx("5".into()),
                Del("X".into()),
                Add("Y".into())
            ]
        );
        // Identical input ⇒ nothing changed (all context, no Del/Add).
        let d = line_diff("same\ntext", "same\ntext");
        assert!(d.iter().all(|l| matches!(l, Ctx(_))));
    }

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
