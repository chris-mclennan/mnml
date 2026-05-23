//! AI subsystem methods on `App` — ghost-text suggestions,
//! AI panes / Claude Code / Codex pty spawning, AI session mirror,
//! commit-message + recompose generation, request-debug.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//! (`.local/PLAN.md` Phase C.5). Pure non-destructive move:
//! no API change.

use super::*;

/// Tidy a raw AI completion into ghost-text-insertable form. The model
/// is told to output bare text but occasionally wraps it in a markdown
/// fence or adds a stray leading newline — strip those. Caps the length
/// so a runaway completion can't paint half the screen grey.
fn clean_suggestion(raw: &str) -> String {
    let mut s = raw;
    // Strip an opening ``` / ```lang fence + its closing fence.
    if let Some(rest) = s.strip_prefix("```") {
        // Drop the optional language tag on the fence's first line.
        let after_lang = rest.find('\n').map(|i| &rest[i + 1..]).unwrap_or("");
        s = after_lang.strip_suffix("```").unwrap_or(after_lang);
        s = s.strip_suffix("```\n").unwrap_or(s);
    }
    // A model sometimes leads with a newline; don't insert a blank line
    // at the cursor. Trailing whitespace-only tails are also unhelpful.
    let s = s.trim_end_matches([' ', '\t']);
    let s = s.strip_prefix('\n').unwrap_or(s);
    // Cap — 600 chars is plenty for a ghost completion.
    s.chars().take(600).collect()
}

/// Byte index after the first "word" of a ghost suggestion — leading
/// whitespace (incl. newlines) plus the first non-whitespace run. Used
/// by `Ctrl+Right` accept-word. Returns `s.len()` when `s` is all
/// whitespace, `0` when empty.
fn ghost_word_boundary(s: &str) -> usize {
    let mut idx = 0;
    let mut chars = s.char_indices().peekable();
    while let Some(&(i, c)) = chars.peek() {
        if c.is_whitespace() {
            idx = i + c.len_utf8();
            chars.next();
        } else {
            break;
        }
    }
    while let Some(&(i, c)) = chars.peek() {
        if c.is_whitespace() {
            break;
        }
        idx = i + c.len_utf8();
        chars.next();
    }
    idx
}

/// Byte index after the first line of a ghost suggestion — through and
/// including the first newline (the whole string when single-line).
/// Used by `Ctrl+Down` accept-line.
fn ghost_line_boundary(s: &str) -> usize {
    match s.find('\n') {
        Some(i) => i + 1,
        None => s.len(),
    }
}

/// Estimate the USD cost of a request from its model + token counts.
fn estimate_ai_cost(model: Option<&str>, input: u64, output: u64) -> Option<f64> {
    let (pin, pout) = ai_price_per_mtok(model)?;
    Some((input as f64 * pin + output as f64 * pout) / 1_000_000.0)
}

/// Compact token count — `840`, `2.1k`, `1.2M`.
fn fmt_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

impl App {
    /// Right-click on an AI pane — exposes re-ask / cancel / promote
    /// without remembering single-letter chords.
    pub fn open_ai_pane_context_menu(&mut self, anchor: (u16, u16)) {
        use crate::context_menu::{ContextMenu, MenuAction, MenuItem};
        let title = "AI".to_string();
        let items = vec![
            MenuItem::new("Re-ask (fresh session)", MenuAction::Command("ai.reask")),
            MenuItem::new("Cancel running job", MenuAction::Command("ai.cancel")),
            MenuItem::new(
                "Promote to interactive (claude --resume)",
                MenuAction::Command("ai.promote"),
            ),
            MenuItem::new("Apply suggested change", MenuAction::Command("ai.apply")),
            MenuItem::new(
                "View session transcript",
                MenuAction::Command("ai.session_view"),
            ),
        ];
        self.context_menu = Some(ContextMenu::new(Some(title), anchor, items));
    }

    /// Called after every editor edit. Keeps an open completion popup in sync
    /// with what's being typed (re-filtering it, or closing it once the prefix
    /// empties / stops matching), and auto-triggers a fresh request on a member
    /// access (`.` / `:`) or the first character of a new word.
    /// Called whenever the active editor changes — clears any visible
    /// ghost suggestion + (re)arms the debounce timer so a fresh
    /// completion fires once typing pauses. Also drops any in-flight
    /// request (its reply will be stale).
    pub fn note_edit_for_suggest(&mut self) {
        if !self.ai_inline_suggestions() {
            return;
        }
        if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            b.editor.ghost_suggestion = None;
        }
        self.pending_suggest = None;
        self.suggest_dirty_at = Some(Instant::now());
    }

    /// True when the active editor is showing an AI ghost suggestion.
    pub fn has_ghost_suggestion(&self) -> bool {
        matches!(
            self.active.and_then(|i| self.panes.get(i)),
            Some(Pane::Editor(b)) if b.editor.ghost_suggestion.is_some()
        )
    }

    /// Drop any visible ghost suggestion on the active editor — used
    /// when the cursor moves (a stale completion for the old position
    /// would be wrong).
    pub fn clear_ghost_suggestion(&mut self) {
        if let Some(Pane::Editor(b)) = self.active.and_then(|i| self.panes.get_mut(i))
            && b.editor.ghost_suggestion.is_some()
        {
            b.editor.ghost_suggestion = None;
        }
    }

    /// True while an AI ghost-text request is in flight (sent to the
    /// backend, reply not yet drained). Drives the statusline `✦ AI`
    /// chip so the user knows a suggestion is coming.
    pub fn ai_suggestion_in_flight(&self) -> bool {
        self.pending_suggest.is_some()
    }

    /// `tick` hook — fire an AI ghost-text request once the debounce
    /// window has elapsed since the last edit. No-op when the feature
    /// is off, a request is already in flight, or a suggestion is
    /// already showing.
    pub(super) fn maybe_fire_suggestion(&mut self) {
        if !self.ai_inline_suggestions() || self.pending_suggest.is_some() {
            return;
        }
        let Some(dirty_at) = self.suggest_dirty_at else {
            return;
        };
        if dirty_at.elapsed().as_millis() < SUGGEST_DEBOUNCE_MS as u128 {
            return;
        }
        let Some(pane_id) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get(pane_id) else {
            return;
        };
        if b.editor.ghost_suggestion.is_some() {
            return;
        }
        let text = b.editor.text();
        let cursor = b.editor.cursor();
        // Cap context: last ~2000 chars before the cursor, first ~1000
        // after. Sending a 100 KB file per keystroke-pause is wasteful.
        let pre_start = text[..cursor]
            .char_indices()
            .rev()
            .nth(2000)
            .map(|(i, _)| i)
            .unwrap_or(0);
        let suf_end = text[cursor..]
            .char_indices()
            .nth(1000)
            .map(|(i, _)| cursor + i)
            .unwrap_or(text.len());
        let prefix = text[pre_start..cursor].to_string();
        let suffix = text[cursor..suf_end].to_string();
        let language = b.language_ext.clone().unwrap_or_default();
        self.suggest_dirty_at = None;
        // Dedup — if the context is byte-identical to the last request
        // fired, don't re-spend an API call / inference cycle (cursor
        // jiggle, type-then-undo back to the same state, etc.).
        if self.last_suggest_context.as_ref() == Some(&(prefix.clone(), suffix.clone())) {
            return;
        }
        self.last_suggest_context = Some((prefix.clone(), suffix.clone()));
        let id = self.next_suggest_id;
        self.next_suggest_id += 1;
        self.pending_suggest = Some((id, pane_id, cursor));
        match self.ai_suggest_backend() {
            crate::ai::SuggestBackend::Local => {
                // Local FIM — hand the request to the engine worker
                // (it owns the model + replies through `suggest_chan`).
                let max_tokens = self.ai_fim_max_tokens();
                let fim_tx = self.ensure_fim_worker();
                let _ = fim_tx.send((id, prefix, suffix, max_tokens));
            }
            // ClaudeApi (and Unset — shouldn't reach here since the
            // setup picker gates first-enable, but be safe).
            _ => {
                let tx = self
                    .suggest_chan
                    .get_or_insert_with(std::sync::mpsc::channel)
                    .0
                    .clone();
                let suggest_model = self.ai_suggest_model();
                std::thread::Builder::new()
                    .name("mnml-suggest".into())
                    .spawn(move || {
                        let result = crate::ai::api_client::complete_code(
                            &prefix,
                            &suffix,
                            &language,
                            suggest_model.as_deref(),
                        );
                        let _ = tx.send((id, result));
                    })
                    .ok();
            }
        }
    }

    /// The configured local FIM model size — `[ai] fim_model` (`"1.5b"`
    /// default / `"3b"`). 3B is smarter at multi-line completion but
    /// ~2x slower with a bigger download.
    pub(super) fn ai_fim_model(&self) -> fim_engine::ModelChoice {
        self.config
            .ai
            .get("fim_model")
            .and_then(|v| v.as_str())
            .map(fim_engine::ModelChoice::parse)
            .unwrap_or(fim_engine::ModelChoice::Qwen1_5B)
    }

    /// The per-request token cap for local FIM completions — `[ai]
    /// fim_max_tokens` (default 64, clamped 8..=512). Bigger = longer
    /// multi-line completions but slower per keystroke-pause.
    fn ai_fim_max_tokens(&self) -> usize {
        self.config
            .ai
            .get("fim_max_tokens")
            .and_then(|v| v.as_integer())
            .map(|n| (n.clamp(8, 512)) as usize)
            .unwrap_or(64)
    }

    /// `tick` hook — apply a ghost-text reply if it's still relevant
    /// (request id matches + the cursor hasn't moved).
    pub(super) fn drain_suggestions(&mut self) {
        let replies: Vec<SuggestReply> = match &self.suggest_chan {
            Some((_, rx)) => rx.try_iter().collect(),
            None => return,
        };
        for (id, result) in replies {
            // `u64::MAX` — a local-FIM load-status message, not a
            // completion. Toast it so the user sees download / ready /
            // failure state.
            if id == u64::MAX {
                match result {
                    Ok(msg) => self.toast(format!("fim-engine: {msg}")),
                    Err(msg) => self.toast(format!("fim-engine: {msg}")),
                }
                continue;
            }
            let Some((pending_id, pane_id, cursor)) = self.pending_suggest else {
                continue;
            };
            if pending_id != id {
                continue; // a newer request superseded this one
            }
            self.pending_suggest = None;
            let text = match result {
                Ok(t) => t,
                Err(_) => continue, // silent — ghost-text is best-effort
            };
            let cleaned = clean_suggestion(&text);
            if cleaned.is_empty() {
                continue;
            }
            // Only land it if the cursor is still where we asked.
            if let Some(Pane::Editor(b)) = self.panes.get_mut(pane_id)
                && b.editor.cursor() == cursor
            {
                b.editor.ghost_suggestion = Some(cleaned);
                self.suggest_shown = self.suggest_shown.saturating_add(1);
                self.suggest_current_accepted = false;
            }
        }
    }

    /// `Tab` accept of the active editor's ghost suggestion — inserts the
    /// whole suggestion at the cursor. Returns true if a suggestion was
    /// accepted (so the caller skips the normal Tab handling).
    pub fn accept_ghost_suggestion(&mut self) -> bool {
        self.accept_ghost_with(str::len)
    }

    /// Accept just the next word of the ghost suggestion (`Ctrl+Right` —
    /// Copilot convention). The rest stays as a ghost so the user can
    /// keep accepting word-by-word.
    pub fn accept_ghost_word(&mut self) -> bool {
        self.accept_ghost_with(ghost_word_boundary)
    }

    /// Accept the next line of the ghost suggestion (`Ctrl+Down`) —
    /// through the first newline; the whole thing when single-line.
    pub fn accept_ghost_line(&mut self) -> bool {
        self.accept_ghost_with(ghost_line_boundary)
    }

    /// Shared partial/full ghost-accept. `boundary(suggestion)` returns
    /// the byte count to accept now; the remainder (if any) stays as the
    /// ghost suggestion so accepts can chain.
    fn accept_ghost_with<F: Fn(&str) -> usize>(&mut self, boundary: F) -> bool {
        let Some(pane_id) = self.active else {
            return false;
        };
        let full = match self.panes.get(pane_id) {
            Some(Pane::Editor(b)) => b.editor.ghost_suggestion.clone(),
            _ => None,
        };
        let Some(full) = full.filter(|s| !s.is_empty()) else {
            return false;
        };
        let take = boundary(&full).min(full.len());
        if take == 0 {
            return false;
        }
        let accepted = full[..take].to_string();
        let remaining = full[take..].to_string();
        if let Some(Pane::Editor(b)) = self.panes.get_mut(pane_id) {
            let at = b.editor.cursor();
            let end = at + accepted.len();
            let clip = &mut self.clipboard;
            b.apply_edit_ops(
                vec![
                    crate::edit_op::EditOp::ReplaceRange {
                        start: at,
                        end: at,
                        text: accepted,
                    },
                    // Land the cursor past the accepted completion so the
                    // user keeps typing from there.
                    crate::edit_op::EditOp::SetCursorByte(end),
                ],
                clip,
                0,
            );
            b.editor.ghost_suggestion = (!remaining.is_empty()).then_some(remaining);
        }
        // Count the suggestion as accepted once — partial accepts of the
        // same suggestion chain, so only the first one bumps the tally.
        if !self.suggest_current_accepted {
            self.suggest_current_accepted = true;
            self.suggest_accepted = self.suggest_accepted.saturating_add(1);
        }
        true
    }

    /// `ai.suggestion_stats` — toast the inline-suggestion accept rate
    /// (accepted / shown, lifetime — persisted across launches). Helps
    /// gauge whether the chosen backend is pulling its weight.
    pub fn ai_suggestion_stats(&mut self) {
        if self.suggest_shown == 0 {
            self.toast("AI suggestions: none shown yet");
            return;
        }
        let pct = (self.suggest_accepted as u64 * 100) / self.suggest_shown as u64;
        self.toast(format!(
            "AI suggestions: {} accepted / {} shown ({}%)",
            self.suggest_accepted, self.suggest_shown, pct
        ));
    }

    /// Open an embedded terminal (`profile` = shell / `claude` / `codex`) as a
    /// stacked split below the focused leaf (a terminal "drawer"), and focus it.
    /// `Ctrl+F` while a Claude pty pane is focused — inject the most-
    /// recently-active editor's workspace-relative path into the pty's
    /// stdin (claude-chat.nvim's filename-inject gesture). Appends a
    /// trailing space, no Enter — the user keeps typing their prompt.
    pub fn inject_filename_to_claude(&mut self, pty_id: PaneId) {
        // The "current file" is the most-recent editor in the MRU list
        // (the Claude pane itself sits at the front; skip to the first
        // editor with a path).
        let rel = self
            .pane_mru
            .iter()
            .find_map(|&id| match self.panes.get(id) {
                Some(Pane::Editor(b)) => b.path.as_ref().map(|p| {
                    p.strip_prefix(&self.workspace)
                        .unwrap_or(p)
                        .to_string_lossy()
                        .into_owned()
                }),
                _ => None,
            });
        let Some(rel) = rel else {
            self.toast("no recent file to inject");
            return;
        };
        if let Some(Pane::Pty(s)) = self.panes.get_mut(pty_id) {
            s.write_bytes(format!("{rel} ").as_bytes());
        }
    }

    /// `ai.chat` — context-aware Claude dispatch (claude-chat.nvim-style
    /// wrapper). Opens a prompt; the title adapts to whether there's a
    /// selection. The accept routes to `dispatch_ai_chat`.
    pub fn open_ai_chat_prompt(&mut self) {
        let has_sel = self
            .active_editor()
            .map(|b| b.editor.has_selection())
            .unwrap_or(false);
        let title = if has_sel {
            "Ask Claude about the selection (empty = send selection only)"
        } else {
            "Ask Claude (empty = open plain Claude pane)"
        };
        let prompt = crate::prompt::Prompt::new(crate::prompt::PromptKind::AiChat, title);
        self.prompt = Some(prompt);
    }

    /// Build the file reference the `ai.chat` wrapper hands to Claude.
    /// Mirrors claude-chat.nvim's `context.format_*` exactly:
    /// `File: <rel> (lines N-M)` / `File: <rel> (line N)` / `File: <rel>`.
    /// A *reference*, not a paste — Claude reads fresh file state itself
    /// via its Read tool. `None` when there's no active editor with a path.
    fn ai_chat_context(&self) -> Option<String> {
        let b = self.active_editor()?;
        let path = b.path.as_ref()?;
        let rel = path
            .strip_prefix(&self.workspace)
            .unwrap_or(path)
            .to_string_lossy()
            .into_owned();
        // Live selection → include the 1-based inclusive line range.
        if let Some((lo, hi)) = b.editor.selection() {
            let (r1, _) = b.editor.row_col_at(lo);
            let (mut r2, c2) = b.editor.row_col_at(hi);
            // Roll back an exclusive end that sits at column 0 of the next
            // line so the range reflects the last content row.
            if r2 > r1 && c2 == 0 {
                r2 -= 1;
            }
            if r1 == r2 {
                Some(format!("File: {rel} (line {})", r1 + 1))
            } else {
                Some(format!("File: {rel} (lines {}-{})", r1 + 1, r2 + 1))
            }
        } else {
            Some(format!("File: {rel}"))
        }
    }

    /// Accept handler for `PromptKind::AiChat`. Composes the message in
    /// claude-chat.nvim's exact reference style:
    /// * query + selection ⇒ `File: <rel> (lines N-M).  Query: <prompt>`
    /// * query, no selection ⇒ `File: <rel>.  Query: <prompt>`
    /// * selection, no query ⇒ `File: <rel> (lines N-M). ` (bare ref)
    /// * neither ⇒ empty (plain Claude pane)
    ///
    /// Then: no Claude pane ⇒ spawn one seeded with the message; Claude
    /// pane already open + the user typed a query ⇒ bracketed-paste it
    /// into the live pty; Claude pane open + empty query ⇒ just focus it
    /// (claude-chat.nvim re-focuses an active session rather than
    /// re-seeding — we extend that with "but DO send if you asked
    /// something").
    pub fn dispatch_ai_chat(&mut self, typed: &str) {
        let typed = typed.trim();
        let context = self.ai_chat_context();
        let message = match (&context, typed.is_empty()) {
            // `format_prompt` joins `"File: x. "` + `"Query: q"` with a
            // space → the doubled space after the period is intentional.
            (Some(ctx), false) => format!("{ctx}.  Query: {typed}"),
            // `format_selection_prompt` — bare reference, no query part.
            (Some(ctx), true) => format!("{ctx}. "),
            (None, false) => typed.to_string(),
            (None, true) => String::new(),
        };
        if let Some(id) = self.find_claude_pty() {
            // Claude is already running. Only re-send when the user
            // actually typed a query — a bare focus / selection-only
            // gesture just reveals the pane (claude-chat.nvim's "active
            // session → focus" behavior).
            if !typed.is_empty()
                && let Some(Pane::Pty(s)) = self.panes.get_mut(id)
            {
                // Bracketed paste: `ESC[200~ … ESC[201~` keeps multi-line
                // text from submitting on each embedded newline; the
                // trailing `\r` then submits the whole message.
                let mut bytes = Vec::with_capacity(message.len() + 16);
                bytes.extend_from_slice(b"\x1b[200~");
                bytes.extend_from_slice(message.as_bytes());
                bytes.extend_from_slice(b"\x1b[201~\r");
                s.write_bytes(&bytes);
            }
            self.reveal_pane(id);
            return;
        }
        // No Claude pane yet — spawn one, seeded with the message if any.
        if message.is_empty() {
            self.open_pty_dir(
                crate::pty_pane::BinaryProfile::claude_code(self.workspace.clone()),
                crate::layout::SplitDir::Horizontal,
            );
        } else {
            self.open_pty_dir(
                crate::pty_pane::BinaryProfile::claude_code_with_prompt(
                    self.workspace.clone(),
                    message,
                ),
                crate::layout::SplitDir::Horizontal,
            );
        }
    }

    pub fn open_claude_code(&mut self) {
        // If a Claude pane is already open, toggle focus / visibility-ish
        // by revealing it instead of spawning a duplicate. (Claude
        // sessions are expensive to bootstrap — same gesture as the
        // claude-chat.nvim "toggle if already active" behavior.)
        if let Some(id) = self.find_claude_pty() {
            self.reveal_pane(id);
            return;
        }
        // AI panes dock as a vertical split on the right of the active
        // leaf — the IDE-canonical "chat panel" placement.
        self.open_pty_dir(
            crate::pty_pane::BinaryProfile::claude_code(self.workspace.clone()),
            crate::layout::SplitDir::Horizontal,
        );
    }

    /// Always spawn a *new* Claude pane (no toggle / reuse) — the
    /// `ai.claude_code_new` palette command. Splits the active leaf;
    /// the pty tab strip's `+` uses `add_pty_tab` instead (tab, not
    /// split).
    pub fn open_claude_code_new(&mut self) {
        self.open_pty_dir(
            crate::pty_pane::BinaryProfile::claude_code(self.workspace.clone()),
            crate::layout::SplitDir::Horizontal,
        );
    }

    pub fn open_codex(&mut self) {
        if let Some(id) = self.find_codex_pty() {
            self.reveal_pane(id);
            return;
        }
        self.open_pty_dir(
            crate::pty_pane::BinaryProfile::codex(self.workspace.clone()),
            crate::layout::SplitDir::Horizontal,
        );
    }

    /// Return the pane id of any open Claude Code pty pane (matched by
    /// `BinaryProfile.label`), or `None`.
    fn find_claude_pty(&self) -> Option<PaneId> {
        self.panes.iter().position(|p| match p {
            Pane::Pty(s) => s.profile.label.starts_with("claude"),
            _ => false,
        })
    }

    /// Return the pane id of any open Codex pty pane.
    fn find_codex_pty(&self) -> Option<PaneId> {
        self.panes.iter().position(|p| match p {
            Pane::Pty(s) => s.profile.label.starts_with("codex"),
            _ => false,
        })
    }

    /// True while a `claude -p` run is in flight (so the event loop polls faster
    /// and streamed deltas render promptly).
    pub fn has_pending_ai(&self) -> bool {
        self.pending_commit_msg_job.is_some()
            || self.panes.iter().any(|p| {
                matches!(p, Pane::Ai(a)
                    if matches!(a.state, crate::ai::AiState::Asking | crate::ai::AiState::Streaming(_)))
            })
    }

    /// Allocate a job id + fresh session id and spawn `claude -p --session-id …`
    /// on a worker thread. Returns `(job_id, session_id, cancel_flag)` — set the
    /// flag to ask the worker to kill its child and bail.
    fn spawn_ai_job(
        &mut self,
        prompt: String,
    ) -> (u64, String, std::sync::Arc<std::sync::atomic::AtomicBool>) {
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let session_id = crate::ai::gen_session_id();
        let tx = self
            .ai_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let sid = session_id.clone();
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        let backend = self.ai_backend();
        let model = self.ai_model();
        let system = self.ai_system_prompt();
        let max_tokens = self.ai_max_tokens();
        let api_tools = self.ai_api_tools();
        let api_write_tools = self.ai_api_write_tools();
        // Confirm before a write: on unless the user opted out.
        let write_confirm = api_write_tools && self.ai_api_write_confirm();
        let (confirm_tx, confirm_rx) = std::sync::mpsc::channel::<bool>();
        self.ai_confirm_senders.insert(job_id, confirm_tx);
        let workspace = self.workspace.clone();
        std::thread::spawn(move || match backend {
            crate::ai::AiBackend::Api => {
                if api_tools {
                    // Agentic loop — read-only workspace tools (read_file
                    // / list_directory / grep), plus write_file when the
                    // user opted in via `[ai] api_write_tools`.
                    crate::ai::api_client::agent_to_channel(
                        &prompt,
                        &workspace,
                        model.as_deref(),
                        system.as_deref(),
                        max_tokens,
                        api_write_tools,
                        write_confirm,
                        &confirm_rx,
                        &worker_cancel,
                        tx,
                        job_id,
                    );
                } else {
                    crate::ai::api_client::stream_to_channel(
                        &prompt,
                        model.as_deref(),
                        system.as_deref(),
                        max_tokens,
                        &worker_cancel,
                        tx,
                        job_id,
                    );
                }
            }
            crate::ai::AiBackend::Cli => {
                crate::ai::stream_to_channel(&prompt, &sid, &worker_cancel, tx, job_id);
            }
        });
        (job_id, session_id, cancel)
    }

    /// Optional `[ai] max_tokens = N` from the config — overrides the API
    /// backend's default output cap (4096). CLI backend ignores this.
    pub fn ai_max_tokens(&self) -> Option<u32> {
        self.config
            .ai
            .get("max_tokens")
            .and_then(|v| v.as_integer())
            .and_then(|n| u32::try_from(n).ok())
    }

    /// Optional `[ai] model = "..."` from the config — overrides the API
    /// backend's default model when set. CLI backend ignores this (the
    /// `claude` binary picks its own default).
    pub fn ai_model(&self) -> Option<String> {
        self.config
            .ai
            .get("model")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_string)
    }

    /// Optional `[ai] suggest_model = "..."` from the config — overrides
    /// the model used for inline ghost-text completion (the ClaudeApi
    /// suggestion backend). Defaults to the fast `claude-haiku-4-5`
    /// since latency matters more than depth for inline completion;
    /// distinct from `[ai] model` (the chat/explain default).
    pub fn ai_suggest_model(&self) -> Option<String> {
        self.config
            .ai
            .get("suggest_model")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_string)
    }

    /// `[ai] api_tools` — whether the direct-API backend runs the
    /// agentic loop with read-only workspace tools (`read_file` /
    /// `list_directory` / `grep`) vs plain text-in/text-out streaming.
    /// Default on — that's the point of the API backend being useful
    /// for more than short asks. CLI backend is unaffected (it always
    /// runs the full `claude` agent).
    pub fn ai_api_tools(&self) -> bool {
        self.config
            .ai
            .get("api_tools")
            .and_then(|v| v.as_bool())
            .unwrap_or(true)
    }

    /// `[ai] api_write_tools` — whether the direct-API agent loop also
    /// gets the `write_file` tool (it can create/overwrite workspace
    /// files autonomously). Default **off** — read-only keeps the API
    /// backend strictly safer than the CLI backend. Opt in deliberately.
    pub fn ai_api_write_tools(&self) -> bool {
        self.config
            .ai
            .get("api_write_tools")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
    }

    /// `[ai] api_write_confirm` — whether each agent `write_file` blocks
    /// for the user's approval before it runs. Default **on** — the
    /// human-in-the-loop safety net for `api_write_tools`. Set false for
    /// unattended writes.
    pub fn ai_api_write_confirm(&self) -> bool {
        self.config
            .ai
            .get("api_write_confirm")
            .and_then(|v| v.as_bool())
            .unwrap_or(true)
    }

    /// `ai.show_config` — toast the live AI backend + model + tool
    /// state. A reliable "what am I running" readout (asking the model
    /// itself doesn't work — LLMs don't know their own version).
    pub fn ai_show_config(&mut self) {
        match self.ai_backend() {
            crate::ai::AiBackend::Cli => {
                self.toast("AI: backend=cli (claude binary · your subscription)");
            }
            crate::ai::AiBackend::Api => {
                let model = self
                    .ai_model()
                    .unwrap_or_else(|| "claude-opus-4-7 (default)".to_string());
                let tools = if !self.ai_api_tools() {
                    "off"
                } else if self.ai_api_write_tools() {
                    "read+write"
                } else {
                    "read-only"
                };
                self.toast(format!("AI: backend=api · model={model} · tools={tools}"));
            }
        }
    }

    /// `ai.token_usage` — toast the direct-API token tally (summed
    /// across every job, lifetime — persisted across launches) + a
    /// rough cost estimate.
    pub fn ai_token_usage(&mut self) {
        if self.ai_tokens_in == 0 && self.ai_tokens_out == 0 {
            self.toast("AI usage: no direct-API calls recorded yet");
            return;
        }
        let model = self.ai_model();
        let base = format!(
            "AI usage: {} in · {} out",
            fmt_tokens(self.ai_tokens_in),
            fmt_tokens(self.ai_tokens_out)
        );
        let msg = match estimate_ai_cost(model.as_deref(), self.ai_tokens_in, self.ai_tokens_out) {
            Some(c) => format!("{base} (~${c:.2})"),
            None => base,
        };
        self.toast(msg);
    }

    /// Optional `[ai] system_prompt = "..."` from the config — prepended
    /// to every API-backend request as the `system` field. CLI backend
    /// ignores this (it has its own conversation system prompt).
    pub fn ai_system_prompt(&self) -> Option<String> {
        self.config
            .ai
            .get("system_prompt")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_string)
    }

    /// Read the user's `[ai] backend = "cli" | "api"` setting. Default
    /// `Cli` (no surprises for users without an API key set).
    /// `[ai] inline_suggestions` — whether Cursor-style AI ghost-text
    /// fires as you type. Off by default (it costs API tokens per
    /// suggestion). Toggle at runtime via `ai.toggle_inline_suggestions`.
    pub fn ai_inline_suggestions(&self) -> bool {
        self.config
            .ai
            .get("inline_suggestions")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
    }

    /// Flip `[ai] inline_suggestions` at runtime. Doesn't persist —
    /// restart re-reads the config file. Turning it ON for the first
    /// time (no backend chosen yet) opens the setup picker instead.
    pub fn toggle_inline_suggestions(&mut self) {
        let next = !self.ai_inline_suggestions();
        if next && self.ai_suggest_backend() == crate::ai::SuggestBackend::Unset {
            // First enable — let the user pick a backend. The picker's
            // accept turns the feature on once a choice is made.
            self.open_suggest_backend_picker();
            return;
        }
        if !self.config.ai.is_table() {
            self.config.ai = toml::Value::Table(toml::value::Table::new());
        }
        if let Some(t) = self.config.ai.as_table_mut() {
            t.insert("inline_suggestions".to_string(), toml::Value::Boolean(next));
        }
        if next {
            self.toast("AI ghost-text: on");
        } else {
            self.clear_ghost_suggestion();
            self.pending_suggest = None;
            self.suggest_dirty_at = None;
            self.last_suggest_context = None;
            self.toast("AI ghost-text: off");
        }
    }

    /// `ai.setup_suggestions` — open the inline-suggestion backend
    /// picker. Reachable any time, so the user can switch backends
    /// later (the answer to "pick + change later").
    pub fn open_suggest_backend_picker(&mut self) {
        use crate::picker::{Picker, PickerItem, PickerKind};
        let cur = self.ai_suggest_backend();
        let mark = |b: crate::ai::SuggestBackend| {
            if cur == b { "● " } else { "  " }
        };
        let items = vec![
            PickerItem::new(
                "claude-api",
                format!("{}Claude API", mark(crate::ai::SuggestBackend::ClaudeApi)),
                "needs $ANTHROPIC_API_KEY · ~1s · works now",
            ),
            PickerItem::new(
                "local",
                format!(
                    "{}Local model (embedded)",
                    mark(crate::ai::SuggestBackend::Local)
                ),
                "private · free · offline · one-time ~1GB download",
            ),
            PickerItem::new(
                "off",
                "  Turn off inline suggestions".to_string(),
                "disable AI ghost-text",
            ),
        ];
        self.open_picker(Picker::new(
            PickerKind::SuggestBackend,
            "AI inline suggestions — pick a backend",
            items,
        ));
    }

    /// Picker-accept for `PickerKind::SuggestBackend`.
    pub fn accept_suggest_backend(&mut self, id: &str) {
        match id {
            "off" => {
                if self.config.ai.is_table()
                    && let Some(t) = self.config.ai.as_table_mut()
                {
                    t.insert(
                        "inline_suggestions".to_string(),
                        toml::Value::Boolean(false),
                    );
                }
                self.clear_ghost_suggestion();
                self.toast("AI ghost-text: off");
            }
            other => {
                let backend = crate::ai::SuggestBackend::parse(other);
                self.set_ai_suggest_backend(backend);
                if !self.config.ai.is_table() {
                    self.config.ai = toml::Value::Table(toml::value::Table::new());
                }
                if let Some(t) = self.config.ai.as_table_mut() {
                    t.insert("inline_suggestions".to_string(), toml::Value::Boolean(true));
                }
                match backend {
                    crate::ai::SuggestBackend::ClaudeApi => {
                        self.toast("AI ghost-text: on · Claude API");
                    }
                    crate::ai::SuggestBackend::Local => {
                        self.toast("AI ghost-text: on · local model");
                        // Warm up now — spawn the worker so the one-time
                        // download/load starts immediately (the worker
                        // loads eagerly on spawn) rather than stalling
                        // the user's first keystroke-pause.
                        self.ensure_fim_worker();
                    }
                    crate::ai::SuggestBackend::Unset => {}
                }
            }
        }
    }

    /// `[ai] suggest_backend` — which engine powers inline ghost-text.
    /// `Unset` until the user picks via the setup picker.
    pub fn ai_suggest_backend(&self) -> crate::ai::SuggestBackend {
        let s = self
            .config
            .ai
            .get("suggest_backend")
            .and_then(|v| v.as_str())
            .unwrap_or("unset");
        crate::ai::SuggestBackend::parse(s)
    }

    /// Persist the inline-suggestion backend choice into the runtime
    /// config (`[ai] suggest_backend`). Not written to disk — restart
    /// re-reads the config file; the user pins it there for permanence.
    pub fn set_ai_suggest_backend(&mut self, backend: crate::ai::SuggestBackend) {
        if !self.config.ai.is_table() {
            self.config.ai = toml::Value::Table(toml::value::Table::new());
        }
        if let Some(t) = self.config.ai.as_table_mut() {
            t.insert(
                "suggest_backend".to_string(),
                toml::Value::String(backend.as_str().to_string()),
            );
        }
    }

    pub fn ai_backend(&self) -> crate::ai::AiBackend {
        let s = self
            .config
            .ai
            .get("backend")
            .and_then(|v| v.as_str())
            .unwrap_or("cli");
        crate::ai::AiBackend::parse(s)
    }

    /// Flip `[ai] backend` at runtime (`cli` ↔ `api`). Affects every
    /// AI job spawned after the toggle. Doesn't persist to the config
    /// file — restart re-reads from disk.
    pub fn toggle_ai_backend(&mut self) {
        let next = match self.ai_backend() {
            crate::ai::AiBackend::Cli => "api",
            crate::ai::AiBackend::Api => "cli",
        };
        // The raw `Value` may be Table or empty; we need a Table to set keys.
        if !self.config.ai.is_table() {
            self.config.ai = toml::Value::Table(toml::value::Table::new());
        }
        if let Some(t) = self.config.ai.as_table_mut() {
            t.insert("backend".to_string(), toml::Value::String(next.to_string()));
        }
        self.toast(format!("ai.backend: {next}"));
    }

    /// Open a `Pane::Ai` showing `title` and the answer to `prompt`, and kick off
    /// `claude -p <prompt>` on a background thread (`tick` delivers the answer).
    pub fn ask_ai(&mut self, title: impl Into<String>, prompt: String) {
        let (job_id, session_id, cancel) = self.spawn_ai_job(prompt.clone());
        let pane = Pane::Ai(crate::ai::AiPane::new(
            title, prompt, session_id, job_id, cancel,
        ));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Re-send the prompt an existing `Pane::Ai` holds (with a fresh session id).
    /// No-op for a live transcript mirror (it has no `-p` prompt). Signals any
    /// still-running worker for this pane to bail first.
    fn reask_ai(&mut self, pane_id: PaneId) {
        let prompt = match self.panes.get(pane_id) {
            Some(Pane::Ai(a)) if !a.is_live() => {
                a.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
                a.prompt.clone()
            }
            _ => return,
        };
        let (job_id, session_id, cancel) = self.spawn_ai_job(prompt);
        if let Some(Pane::Ai(a)) = self.panes.get_mut(pane_id) {
            a.job_id = job_id;
            a.session_id = session_id;
            a.state = crate::ai::AiState::Asking;
            a.scroll = 0;
            a.cancel = cancel;
            a.pending_apply = None;
        }
    }

    /// `x` in an `Asking` `Pane::Ai` — ask the worker to kill `claude -p` and bail
    /// (the reply lands as `Failed("cancelled")`).
    pub fn cancel_active_ai(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Ai(a)) = self.panes.get(cur)
            && matches!(
                a.state,
                crate::ai::AiState::Asking | crate::ai::AiState::Streaming(_)
            )
        {
            a.cancel.store(true, std::sync::atomic::Ordering::Relaxed);
            self.toast("cancelling…");
        }
    }

    /// `y` in a `Pane::Ai` — copy the rendered answer text to the clipboard.
    /// No-op for `Asking` (nothing typed yet) and `Live` mirrors (those are
    /// transcripts, not a single answer body).
    pub fn copy_active_ai_answer(&mut self) {
        let Some(cur) = self.active else { return };
        let text = match self.panes.get(cur) {
            Some(Pane::Ai(a)) => a.answer_text().map(str::to_string),
            _ => return,
        };
        match text {
            Some(t) if !t.is_empty() => {
                let chars = t.chars().count();
                self.clipboard.set(t, false);
                self.toast(format!("copied AI answer ({chars} chars)"));
            }
            _ => self.toast("no AI answer to copy yet"),
        }
    }

    /// `c` in a `Pane::Ai`: open `claude --resume <session>` interactively (a split
    /// below) so you can carry the conversation further — and flip this pane into
    /// a live transcript mirror of that session.
    pub fn continue_active_ai(&mut self) {
        let Some(cur) = self.active else { return };
        let sid = match self.panes.get(cur) {
            Some(Pane::Ai(a))
                if matches!(
                    a.state,
                    crate::ai::AiState::Asking | crate::ai::AiState::Streaming(_)
                ) =>
            {
                self.toast("wait for the answer first");
                return;
            }
            Some(Pane::Ai(a)) => a.session_id.clone(),
            _ => return,
        };
        // Flip the source pane to a live mirror (unless it already is one).
        if let Some(path) = crate::ai::transcript::session_path(&self.workspace, &sid)
            && let Some(Pane::Ai(a)) = self.panes.get_mut(cur)
            && !a.is_live()
        {
            let turns = crate::ai::transcript::read(&path);
            let last_len = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            a.state = crate::ai::AiState::Live {
                path,
                last_len,
                turns,
            };
            a.scroll = usize::MAX;
        }
        self.open_pty(crate::pty_pane::BinaryProfile::claude_code_resume(
            self.workspace.clone(),
            sid,
        ));
    }

    /// `ai.session_picker` — pick from past Claude sessions in this
    /// workspace (`~/.claude/projects/<dashed-cwd>/*.jsonl`, newest
    /// first). Accept opens a live mirror — read-only follow. Useful
    /// for revisiting prior conversations without spinning up a new
    /// pty.
    pub fn open_ai_session_picker(&mut self) {
        let sessions = crate::ai::transcript::list_sessions(&self.workspace);
        if sessions.is_empty() {
            self.toast("no Claude sessions found for this workspace");
            return;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let items: Vec<crate::picker::PickerItem> = sessions
            .into_iter()
            .map(|s| {
                let age = crate::ui::git_graph_view::humanize_age(now.saturating_sub(s.mtime));
                let preview = if s.preview.is_empty() {
                    "(no user message)".to_string()
                } else {
                    s.preview
                };
                let short_id: String = s.session_id.chars().take(8).collect();
                crate::picker::PickerItem::new(s.session_id, format!("{short_id}  {preview}"), age)
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::AiSessions,
            "Claude sessions",
            items,
        ));
    }

    /// Accept handler for `PickerKind::AiSessions` — open a live mirror
    /// for the chosen session id.
    pub fn open_ai_session_mirror(&mut self, session_id: &str) {
        let Some(path) = crate::ai::transcript::session_path(&self.workspace, session_id) else {
            self.toast("can't locate session transcript ($HOME unset?)");
            return;
        };
        // Focus an existing mirror if one is open.
        if let Some(i) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Ai(a) if a.is_live() && a.session_id == session_id))
        {
            self.reveal_pane(i);
            return;
        }
        let pane = Pane::Ai(crate::ai::AiPane::live(session_id.to_string(), path));
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Re-read any live transcript mirrors whose `.jsonl` has grown — incrementally:
    /// only the bytes past `last_len` are read and parsed (up to the last complete
    /// line) and their turns appended. A shrunk file (rotation / rewrite) triggers a
    /// full re-read.
    pub(super) fn refresh_live_ai_panes(&mut self) {
        use std::io::{Read, Seek, SeekFrom};
        for pane in &mut self.panes {
            let Pane::Ai(a) = pane else { continue };
            let crate::ai::AiState::Live {
                path,
                last_len,
                turns,
            } = &mut a.state
            else {
                continue;
            };
            let len = std::fs::metadata(&*path).map(|m| m.len()).unwrap_or(0);
            if len < *last_len {
                // file shrank / rotated — re-read from scratch.
                *turns = crate::ai::transcript::read(path);
                *last_len = std::fs::metadata(&*path).map(|m| m.len()).unwrap_or(0);
                continue;
            }
            if len == *last_len {
                continue;
            }
            // Append-only growth: read just the new tail, parse complete lines.
            let mut chunk = String::new();
            let ok = std::fs::File::open(&*path)
                .and_then(|mut f| {
                    f.seek(SeekFrom::Start(*last_len))?;
                    f.read_to_string(&mut chunk)
                })
                .is_ok();
            if !ok {
                continue;
            }
            let Some(cut) = chunk.rfind('\n').map(|i| i + 1) else {
                continue; // a partial line is still being written — wait for the rest
            };
            turns.extend(crate::ai::transcript::parse(&chunk[..cut]));
            *last_len += cut as u64;
        }
    }

    /// `ai.explain` / `ai.fix` / `ai.refactor` / `ai.write_tests` — feed the active
    /// editor's selection (or the whole buffer) + a task prompt to `claude -p`.
    /// For `fix`/`refactor` the source range is remembered as the answer pane's
    /// [`ApplyTarget`](crate::ai::ApplyTarget) so `a` can apply the suggested code.
    pub fn ai_action(&mut self, what: &str) {
        let (code, lang, target) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Editor(b)) => {
                let sel = b.editor.selected_text();
                let (code, range) = if sel.trim().is_empty() {
                    let t = b.editor.text();
                    (t.to_string(), (0usize, t.len()))
                } else {
                    let r = b.editor.selection().unwrap_or((0, 0));
                    (sel, r)
                };
                let target = if matches!(what, "fix" | "refactor") {
                    b.path.clone().map(|path| crate::ai::ApplyTarget {
                        path,
                        start: range.0.min(range.1),
                        end: range.0.max(range.1),
                    })
                } else {
                    None
                };
                (code, b.language_ext.clone().unwrap_or_default(), target)
            }
            // Re-fire from an existing AI pane.
            Some(Pane::Ai(_)) => {
                if let Some(cur) = self.active {
                    self.reask_ai(cur);
                }
                return;
            }
            _ => {
                self.toast("AI actions need an editor (select code, or use the whole file)");
                return;
            }
        };
        if code.trim().is_empty() {
            self.toast("nothing to send");
            return;
        }
        let title = format!("AI: {}", what.replace('_', " "));
        self.ask_ai(title, crate::ai::action_prompt(what, &code, &lang));
        if target.is_some()
            && let Some(Pane::Ai(a)) = self.active.and_then(|i| self.panes.get_mut(i))
        {
            a.target = target;
        }
    }

    /// `a` in a Done `Pane::Ai`: first press *stages* the first fenced code block
    /// from the answer against the range the AI was asked about — building a diff
    /// preview the pane renders. A second `a` applies it (a `ReplaceRange`, left
    /// dirty: review, undo to revert). `r` (re-ask) discards a staged suggestion.
    /// No-op without a recorded target / a code block in the answer.
    pub fn apply_ai_suggestion(&mut self) {
        let Some(cur) = self.active else { return };
        // If a suggestion is already staged, this press applies it.
        if let Some(Pane::Ai(a)) = self.panes.get_mut(cur)
            && let Some(p) = a.pending_apply.take()
        {
            self.do_apply_suggestion(p.target, p.code);
            return;
        }
        // Otherwise stage it: parse target + code, diff against the live range.
        let parsed: Result<(crate::ai::ApplyTarget, String), &'static str> =
            match self.panes.get(cur) {
                Some(Pane::Ai(a)) => match (&a.target, &a.state) {
                    (None, _) => Err("nothing to apply here (use AI `fix`/`refactor` on a buffer)"),
                    (Some(_), crate::ai::AiState::Asking | crate::ai::AiState::Streaming(_)) => {
                        Err("wait for the answer first")
                    }
                    (Some(t), crate::ai::AiState::Done(text)) => {
                        match crate::ai::first_code_block(text) {
                            Some(code) => Ok((t.clone(), code)),
                            None => Err("no code block in the answer to apply"),
                        }
                    }
                    (Some(_), _) => Err("nothing to apply (the run didn't finish ok)"),
                },
                _ => return,
            };
        let (target, code) = match parsed {
            Ok(v) => v,
            Err(msg) => {
                self.toast(msg);
                return;
            }
        };
        // The current text of the target range (from the open editor, or disk).
        let old = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(&target.path) => Some(b.editor.text().to_string()),
                _ => None,
            })
            .or_else(|| std::fs::read_to_string(&target.path).ok())
            .unwrap_or_default();
        let old_range = {
            let s = target.start.min(old.len());
            let e = target.end.min(old.len()).max(s);
            old[s..e].to_string()
        };
        if old_range == code {
            self.toast("the suggestion matches what's already there");
            return;
        }
        let diff = crate::ai::line_diff(&old_range, &code);
        if let Some(Pane::Ai(a)) = self.panes.get_mut(cur) {
            a.pending_apply = Some(crate::ai::PendingApply { target, code, diff });
            a.scroll = usize::MAX; // show the preview at the bottom
        }
        self.toast("review the diff below — press a again to apply (r re-asks)");
    }

    /// Actually splice the AI suggestion's `code` over `target` in the editor
    /// (opening the file if needed), left dirty.
    fn do_apply_suggestion(&mut self, target: crate::ai::ApplyTarget, code: String) {
        if !self
            .panes
            .iter()
            .any(|p| matches!(p, Pane::Editor(b) if b.is_at(&target.path)))
        {
            self.open_path(&target.path);
        }
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&target.path)))
        else {
            self.toast("couldn't open the source file");
            return;
        };
        let clip = &mut self.clipboard;
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let len = b.editor.text().len();
            let start = target.start.min(len);
            let end = target.end.min(len).max(start);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start,
                    end,
                    text: code,
                }],
                clip,
                0,
            );
        }
        if let Some(Pane::Editor(b)) = self.panes.get(idx)
            && let Some(p) = b.path.clone()
        {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&p, &t);
        }
        self.reveal_pane(idx);
        self.toast("applied — review it; undo to revert");
    }

    /// `rqst.ai_debug` (`.` in a request pane) — hand the request + its response
    /// (or transport error) to `claude -p` and ask why it's failing / how to fix.
    pub fn ai_debug_request(&mut self) {
        use crate::request_pane::RunState;
        let prompt = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Request(rp)) => {
                let req = &rp.request;
                let mut req_text = format!("{} {}\n", req.method, req.url);
                for (k, v) in &req.headers {
                    req_text.push_str(&format!("{k}: {v}\n"));
                }
                if let Some(b) = &req.body {
                    req_text.push_str(&format!("\n{b}\n"));
                }
                let resp_text = match &rp.state {
                    RunState::Sending => "(still in flight — wait for it)".to_string(),
                    RunState::Failed(e) => format!("transport error: {e}"),
                    RunState::Done(r) => {
                        let mut s = format!("{} {}\n", r.status, r.status_text);
                        for (k, v) in &r.headers {
                            s.push_str(&format!("{k}: {v}\n"));
                        }
                        let body: String = r.body.chars().take(4000).collect();
                        s.push_str(&format!("\n{body}\n"));
                        s
                    }
                };
                if matches!(rp.state, RunState::Sending) {
                    self.toast("wait for the response first");
                    return;
                }
                format!(
                    "This HTTP request isn't behaving. What's likely wrong and how do I fix it? \
                     Be concise.\n\n## Request\n```http\n{req_text}```\n\n## Response\n```\n{resp_text}```"
                )
            }
            _ => {
                self.toast("open a request pane first (rqst.send)");
                return;
            }
        };
        self.ask_ai("AI: debug request", prompt);
    }

    /// Re-fire the active `Pane::Ai`'s prompt (its `r` key).
    pub fn resend_active_ai(&mut self) {
        if let Some(cur) = self
            .active
            .filter(|&i| matches!(self.panes.get(i), Some(Pane::Ai(_))))
        {
            self.reask_ai(cur);
        }
    }

    /// `ai.ask` — accepted from the text-input prompt: a free-text question to `claude -p`.
    pub fn open_ai_ask_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::AiAsk,
            "Ask Claude",
        ));
    }

    /// Drain the streamed `claude -p` messages into their `Pane::Ai` (deltas
    /// accumulate; a final Done/Failed settles the pane). The commit-message job
    /// shares this channel — it ignores deltas and acts on the final text.
    pub(super) fn drain_ai_jobs(&mut self) {
        use crate::ai::{AiMsg, AiState};
        let Some((_, rx)) = &self.ai_chan else {
            return;
        };
        let msgs: Vec<AiJobMsg> = rx.try_iter().collect();
        let mut toasts: Vec<String> = Vec::new();
        for (job_id, msg) in msgs {
            // Token-usage report — accumulate the session tally + toast
            // this call's cost. Independent of which job kind it was.
            if let AiMsg::Usage {
                input_tokens,
                output_tokens,
            } = msg
            {
                self.ai_tokens_in = self.ai_tokens_in.saturating_add(input_tokens);
                self.ai_tokens_out = self.ai_tokens_out.saturating_add(output_tokens);
                let model = self.ai_model();
                let base = format!(
                    "AI: {} in · {} out",
                    fmt_tokens(input_tokens),
                    fmt_tokens(output_tokens)
                );
                toasts.push(
                    match estimate_ai_cost(model.as_deref(), input_tokens, output_tokens) {
                        Some(c) => format!("{base} (~${c:.4})"),
                        None => base,
                    },
                );
                continue;
            }
            // Tool-confirmation request — the agent worker is blocked
            // waiting for the user to approve a write. Open the prompt.
            if let AiMsg::ConfirmTool { summary } = &msg {
                self.pending_tool_confirm = Some(job_id);
                self.prompt = Some(crate::prompt::Prompt::seeded(
                    crate::prompt::PromptKind::AiToolConfirm,
                    format!("AI wants to {summary} — Enter: allow · Esc: deny"),
                    String::new(),
                ));
                continue;
            }
            // Job finished — drop its confirm channel.
            if matches!(msg, AiMsg::Done(_) | AiMsg::Failed(_)) {
                self.ai_confirm_senders.remove(&job_id);
            }
            // An "AI: rewrite HEAD's message" job? Route the final text to a
            // GitCommitAmend prompt (same shape as the GitCommit case below).
            if self.pending_amend_msg_job == Some(job_id) {
                let result = match msg {
                    AiMsg::Delta(_) => continue,
                    AiMsg::Usage { .. } | AiMsg::ConfirmTool { .. } => continue, // handled above
                    AiMsg::Done(text) => Ok(text),
                    AiMsg::Failed(e) => Err(e),
                };
                self.pending_amend_msg_job = None;
                match result {
                    Ok(text) => {
                        let summary = text
                            .lines()
                            .map(str::trim)
                            .find(|l| !l.is_empty())
                            .unwrap_or("")
                            .trim_matches('`')
                            .trim()
                            .to_string();
                        if summary.is_empty() {
                            toasts.push("AI returned an empty commit message".to_string());
                        } else {
                            self.prompt = Some(crate::prompt::Prompt::seeded(
                                crate::prompt::PromptKind::GitCommitAmend,
                                "Rewrite HEAD's message (AI draft — edit & Enter)",
                                summary,
                            ));
                        }
                    }
                    Err(e) => toasts.push(format!("AI recompose: {e}")),
                }
                continue;
            }
            // An "AI: write me a commit message" job? Route the final text to the
            // commit prompt; deltas are noise here.
            if self.pending_commit_msg_job == Some(job_id) {
                let result = match msg {
                    AiMsg::Delta(_) => continue,
                    AiMsg::Usage { .. } | AiMsg::ConfirmTool { .. } => continue, // handled above
                    AiMsg::Done(text) => Ok(text),
                    AiMsg::Failed(e) => Err(e),
                };
                self.pending_commit_msg_job = None;
                for pane in &mut self.panes {
                    if let Pane::GitStatus(g) = pane
                        && g.ai_msg_job == Some(job_id)
                    {
                        g.ai_msg_job = None;
                    }
                }
                // Inline-textarea path — fill the GitGraph pane's
                // WIP commit textarea instead of opening the modal.
                let wip_target = self
                    .pending_wip_commit_msg_pane
                    .take_if(|(jid, _)| *jid == job_id);
                if let Some((_, pane_id)) = wip_target {
                    match result {
                        Ok(text) => {
                            let clean = text
                                .trim()
                                .trim_start_matches("```")
                                .trim_end_matches("```")
                                .trim()
                                .to_string();
                            if let Some(Pane::GitGraph(g)) = self.panes.get_mut(pane_id) {
                                g.wip_commit.ai_streaming = false;
                                if clean.is_empty() {
                                    toasts.push("AI returned an empty commit message".to_string());
                                } else {
                                    g.wip_commit.set_text(clean);
                                    g.wip_commit.focused = true;
                                }
                            }
                        }
                        Err(e) => {
                            if let Some(Pane::GitGraph(g)) = self.panes.get_mut(pane_id) {
                                g.wip_commit.ai_streaming = false;
                            }
                            toasts.push(format!("AI commit message: {e}"));
                        }
                    }
                    continue;
                }
                match result {
                    Ok(text) => {
                        let summary = text
                            .lines()
                            .map(str::trim)
                            .find(|l| !l.is_empty())
                            .unwrap_or("")
                            .trim_matches('`')
                            .trim()
                            .to_string();
                        if summary.is_empty() {
                            toasts.push("AI returned an empty commit message".to_string());
                        } else {
                            self.prompt = Some(crate::prompt::Prompt::seeded(
                                crate::prompt::PromptKind::GitCommit,
                                "Commit message (AI draft — edit & Enter)",
                                summary,
                            ));
                        }
                    }
                    Err(e) => toasts.push(format!("AI commit message: {e}")),
                }
                continue;
            }
            let Some(Pane::Ai(a)) = self.panes.iter_mut().find(|p| {
                matches!(p, Pane::Ai(a)
                    if a.job_id == job_id
                    && matches!(a.state, AiState::Asking | AiState::Streaming(_)))
            }) else {
                continue;
            };
            match msg {
                AiMsg::Delta(s) => match &mut a.state {
                    AiState::Streaming(buf) => buf.push_str(&s),
                    _ => a.state = AiState::Streaming(s),
                },
                AiMsg::Done(text) => {
                    toasts.push(format!("{} — done", a.title));
                    a.state = AiState::Done(text);
                }
                AiMsg::Failed(e) => {
                    toasts.push(format!("AI: {e}"));
                    a.state = AiState::Failed(e);
                }
                AiMsg::Usage { .. } | AiMsg::ConfirmTool { .. } => {} // handled at the top
            }
        }
        for t in toasts {
            self.toast(t);
        }
    }

    /// `C` in the status pane — ask `claude -p` to write a commit message from the
    /// staged diff; when it lands, the commit prompt opens pre-seeded with the
    /// first line (`drain_ai_jobs` routes it via `pending_commit_msg_job`).
    ///
    /// When the active pane is a `Pane::GitGraph` with its WIP detail
    /// visible, the result fills that pane's inline textarea instead
    /// of opening the modal prompt. The textarea's `ai_streaming`
    /// flag is set so the buttons row shows the "AI writing…" state.
    pub fn request_ai_commit_message(&mut self) {
        if self.git.snapshot().staged == 0 {
            self.toast("nothing staged — stage some changes first");
            return;
        }
        let diff = crate::git::stage::staged_diff(self.active_repo_path());
        if diff.trim().is_empty() {
            self.toast("no staged diff to summarise");
            return;
        }
        // Keep the prompt from getting silly-long on huge diffs.
        let diff = if diff.len() > 24_000 {
            format!("{}\n…(diff truncated)…", &diff[..24_000])
        } else {
            diff
        };
        let prompt = format!(
            "Write a git commit message for the staged changes below. \
             First line: imperative mood, ≤72 chars, no trailing period. \
             Then a blank line and a short body ONLY if it adds something. \
             Output ONLY the commit message — no preamble, no code fences.\n\n\
             ```diff\n{diff}\n```"
        );
        let (job_id, _sid, _cancel) = self.spawn_ai_job(prompt);
        self.pending_commit_msg_job = Some(job_id);
        // Route the result to a GitGraph WIP textarea when one is
        // currently active — otherwise fall through to the existing
        // modal prompt flow.
        let active_id = self.active;
        if let Some(id) = active_id
            && let Some(Pane::GitGraph(g)) = self.panes.get_mut(id)
            && g.is_wip_selected()
        {
            g.wip_commit.ai_streaming = true;
            self.pending_wip_commit_msg_pane = Some((job_id, id));
        }
        if let Some(Pane::GitStatus(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.ai_msg_job = Some(job_id);
        }
        self.toast("asking Claude for a commit message…");
    }

    /// `git.codex_commit` — same shape as `request_ai_commit_message` but
    /// invokes the Codex CLI (`codex exec <prompt>`) instead of Claude.
    /// Useful when the user prefers OpenAI's model for commit messages.
    /// Routes the reply through the same `pending_commit_msg_job` channel,
    /// so the commit prompt opens pre-seeded just like the Claude flow.
    pub fn request_codex_commit_message(&mut self) {
        if self.git.snapshot().staged == 0 {
            self.toast("nothing staged — stage some changes first");
            return;
        }
        let diff = crate::git::stage::staged_diff(self.active_repo_path());
        if diff.trim().is_empty() {
            self.toast("no staged diff to summarise");
            return;
        }
        let diff = if diff.len() > 24_000 {
            format!("{}\n…(diff truncated)…", &diff[..24_000])
        } else {
            diff
        };
        let prompt = format!(
            "Write a git commit message for the staged changes below. \
             First line: imperative mood, ≤72 chars, no trailing period. \
             Then a blank line and a short body ONLY if it adds something. \
             Output ONLY the commit message — no preamble, no code fences.\n\n\
             ```diff\n{diff}\n```"
        );
        let job_id = self.spawn_codex_job(prompt);
        self.pending_commit_msg_job = Some(job_id);
        if let Some(Pane::GitStatus(g)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            g.ai_msg_job = Some(job_id);
        }
        self.toast("asking Codex for a commit message…");
    }

    /// Mirror of [`Self::spawn_ai_job`] for `codex exec` — codex is
    /// stateless per call so no session id; we still use the
    /// `App.ai_chan` for delivery (the messages share `AiMsg` shape).
    fn spawn_codex_job(&mut self, prompt: String) -> u64 {
        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let tx = self
            .ai_chan
            .get_or_insert_with(std::sync::mpsc::channel)
            .0
            .clone();
        let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        std::thread::spawn(move || {
            crate::ai::stream_codex_to_channel(&prompt, &worker_cancel, tx, job_id);
        });
        job_id
    }

    /// `git.ai_recompose` — ask Claude to rewrite HEAD's commit message based
    /// on its diff. The reply lands as a `PromptKind::GitCommitAmend` prompt;
    /// accept ⇒ `git commit --amend -m <new>`. Limited to HEAD for now —
    /// rewriting older commits would require interactive rebase machinery.
    pub fn request_ai_recompose_message(&mut self) {
        let diff = match crate::git::commit::show_head(self.active_repo_path()) {
            Ok(d) if d.trim().is_empty() => {
                self.toast("HEAD has no patch to summarise");
                return;
            }
            Ok(d) => d,
            Err(e) => {
                self.toast(format!("AI recompose: {e}"));
                return;
            }
        };
        let diff = if diff.len() > 24_000 {
            format!("{}\n…(diff truncated)…", &diff[..24_000])
        } else {
            diff
        };
        let existing = crate::git::commit::head_message(self.active_repo_path());
        let existing_block = if existing.is_empty() {
            String::new()
        } else {
            format!("Current message:\n```\n{existing}\n```\n\n")
        };
        let prompt = format!(
            "Rewrite this commit's message based on what actually changed. \
             First line: imperative mood, ≤72 chars, no trailing period. \
             Then a blank line and a short body ONLY if it adds something the \
             subject doesn't. Output ONLY the new message — no preamble, no \
             code fences.\n\n\
             {existing_block}\
             ```diff\n{diff}\n```"
        );
        let (job_id, _sid, _cancel) = self.spawn_ai_job(prompt);
        self.pending_amend_msg_job = Some(job_id);
        self.toast("asking Claude to rewrite HEAD's message…");
    }
}

#[cfg(test)]
mod ai_tests {
    use super::*;

    #[test]
    fn ghost_word_boundary_takes_leading_ws_plus_one_word() {
        // Leading whitespace + first non-ws run.
        assert_eq!(ghost_word_boundary(" + b\n}"), 2); // " +"
        assert_eq!(ghost_word_boundary("foo bar"), 3); // "foo"
        // Crosses a newline when the suggestion starts with one.
        assert_eq!(ghost_word_boundary("\n    foo bar"), 8); // "\n    foo"
        // All whitespace ⇒ take everything.
        assert_eq!(ghost_word_boundary("   "), 3);
        // Empty ⇒ 0 (caller treats as "nothing to accept").
        assert_eq!(ghost_word_boundary(""), 0);
    }

    #[test]
    fn ghost_line_boundary_takes_through_first_newline() {
        // Through and including the first newline.
        assert_eq!(ghost_line_boundary("a + b\n}\n"), 6);
        // Single-line ⇒ the whole string.
        assert_eq!(ghost_line_boundary("a + b"), 5);
        assert_eq!(ghost_line_boundary(""), 0);
    }

    #[test]
    fn estimate_ai_cost_uses_per_model_rates() {
        // Sonnet: $3/M in, $15/M out → 1M in + 1M out = $18.
        let c = estimate_ai_cost(Some("claude-sonnet-4-6"), 1_000_000, 1_000_000).unwrap();
        assert!((c - 18.0).abs() < 1e-9, "got {c}");
        // Haiku is cheaper than Sonnet for the same tokens.
        let haiku = estimate_ai_cost(Some("claude-haiku-4-5"), 100_000, 50_000).unwrap();
        let sonnet = estimate_ai_cost(Some("claude-sonnet-4-6"), 100_000, 50_000).unwrap();
        assert!(haiku < sonnet);
        // None model ⇒ defaults to Opus pricing (recognized).
        assert!(estimate_ai_cost(None, 1000, 1000).is_some());
        // Unrecognized model ⇒ no estimate.
        assert_eq!(estimate_ai_cost(Some("some-other-llm"), 1000, 1000), None);
    }

    #[test]
    fn fmt_tokens_is_compact() {
        assert_eq!(fmt_tokens(840), "840");
        assert_eq!(fmt_tokens(2_100), "2.1k");
        assert_eq!(fmt_tokens(1_200_000), "1.2M");
    }
}
