//! Per-frame lifecycle on `App` — the master `tick()` method
//! (called every event-loop iteration by both `tui.rs` and
//! `headless.rs`), and the private helpers it fans out into
//! (yank-flash expiry, stale-highlight refresh, external-file
//! change detection, autosave-on-idle).
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    pub fn tick(&mut self) {
        // qa-bug 2026-06-30 — external git operations (user runs
        // `git checkout` in a terminal outside mnml) weren't
        // picked up by the rail's LOCAL branch list — only by the
        // statusline branch chip (whose snapshot self.git.tick
        // refreshes on a 3s TTL). Capture the branch snapshot
        // before+after the tick; if it changed, refresh git_rail
        // so the LOCAL `●` current-branch dot follows.
        let before_branch = self.git.snapshot().branch.clone();
        self.git.tick();
        if self.git.snapshot().branch != before_branch {
            let root = self.active_repo_path().to_path_buf();
            self.git_rail.refresh(&root);
        }
        // Per-frame pty maintenance: `pump` drains the reader thread's bytes
        // into each (!Send) libghostty terminal — done here (not just on draw)
        // so hidden panes keep processing output. `tick_activity` then bumps
        // the activity Instant the sessions panel's running/idle chip reads.
        let mut pending_spend_toast: Option<(usize, f64)> = None;
        for p in self.panes.iter_mut() {
            if let crate::pane::Pane::Pty(s) = p {
                s.pump();
                s.tick_activity();
            }
            if let crate::pane::Pane::Mount(m) = p {
                // Drain pending frames from the mount worker
                // thread + detect integration exit. Render reads
                // `latest_frame` set here.
                m.pump();
            }
            if let crate::pane::Pane::SpendReport(sr) = p {
                // 2026-06-29 claude-agents-power-user SEV-2: pull
                // the spend_today worker's snapshot if ready.
                // claude-agents 3rd SEV-3: when it arrives, queue a
                // totals toast. The inline toast from ai_spend_today
                // always sees loading=true (the worker hasn't run
                // yet), so the totals-ready toast must fire from here.
                if sr.poll_pending() {
                    pending_spend_toast = Some((
                        sr.snapshot.claude_sessions + sr.snapshot.codex_sessions,
                        sr.snapshot.total_cost_usd,
                    ));
                }
            }
        }
        if let Some((sessions, cost)) = pending_spend_toast {
            self.toast(format!("today: {sessions} sessions · ${cost:.4}"));
        }
        if let Some(scratch) = self.scratch_term.as_mut() {
            scratch.session.pump();
            scratch.session.tick_activity();
        }
        // Agents rail panel — pull the worker's snapshot if ready.
        self.drain_agents_panel_refresh();
        // Cloud-run trigger result, if a `+ New cloud run` is in flight.
        self.drain_cloud_run_trigger();
        // CloudAgentRun panes — pull fresh log lines + artifact rows
        // from their worker threads into the pane state.
        self.drain_cloud_agent_run_panes();
        // Auto-refresh cloud-run detail panes whose interval has
        // elapsed. No-op when no pane has auto enabled.
        self.tick_cloud_agent_run_auto();
        // Cloud-run worker messages — toast successes / errors from
        // managed-agents submit threads.
        self.drain_cloud_run_msgs();
        // NewCloudAgentWizard panes — drain PR-list fetcher.
        self.drain_new_cloud_agent_wizards();
        self.drain_git_results();
        self.maybe_announce_update();
        self.drain_now_playing();
        self.tick_now_playing_marquee();
        self.drain_sonos();
        self.drain_http_jobs();
        self.drain_sse_jobs();
        self.drain_websocket();
        self.drain_http_ai_build();
        self.drain_http_chain();
        self.drain_ws_send();
        self.maybe_auto_refresh_claude_agents();
        self.maybe_escalate_claude_kills();
        self.drain_http_sync_result();
        self.drain_http_sync_check_result();
        self.drain_http_bench_result();
        self.drain_lookup_fire_result();
        // 2026-06-19 — keep started stamps in sync with rx. When
        // a drain just cleared its rx, also clear the stamp so the
        // cmdline_bar's `⟳ … (Ns)` indicator turns off.
        if self.http_bench_rx.is_none() {
            self.http_bench_started = None;
            self.http_bench_progress = None;
        }
        if self.http_sync_rx.is_none() {
            self.http_sync_started = None;
        }
        if self.lookup_fire_rx.is_none() {
            self.lookup_fire_started = None;
        }
        self.drain_ai_jobs();
        self.drain_ai_session_search();
        self.drain_marketplace();
        self.drain_launcher_installs();
        self.drain_readme_fetches();
        self.maybe_refresh_ai_usage();
        self.drain_ai_usage();
        self.maybe_poll_system_theme();
        // 2026-08-17 — pull any completed manifest-declared
        // `[[values_sources]]` poll results into their snapshots
        // + re-render the `[[statusline_segments]]` chips that
        // depend on them. See `src/app/statusline_segments.rs`.
        self.drain_statusline_segments();
        self.drain_pending_keychain();
        self.drain_suggestions();
        self.maybe_fire_suggestion();
        self.drain_tests_jobs();
        self.drain_linter_jobs();
        self.drain_dap_events();
        self.drain_lsp_events();
        self.drain_cdp_events();
        self.refresh_live_ai_panes();
        self.drain_scm_pr_pending();
        self.autosave_idle_buffers();
        self.check_external_file_changes();
        self.check_format_save_deadline();
        self.block_insert_replay_if_done();
        self.repeat_insert_replay_if_done();
        self.expire_yank_flashes();
        self.refresh_stale_highlights();
        self.refresh_scroll_semantic_tokens();
        self.maybe_fire_mouse_hover();
        // mouse-round-10 SEV-2 2026-07-12 — hover on a toast pauses
        // its TTL so the user has time to read a long message
        // before it fades. The mouse handler sets
        // `hover_chip = ToastBox(idx)` when the cursor is over a
        // toast rect; here we bump the entry's `created_at` so its
        // age effectively stays at whatever it was when the hover
        // began. Also refreshes `App.toast`'s legacy timestamp
        // when the newest stack entry is under the cursor.
        if let Some((crate::HoverChip::ToastBox(hover_idx), _)) = self.hover_chip
            && hover_idx < self.toast_stack.len()
        {
            if let Some(entry) = self.toast_stack.get_mut(hover_idx) {
                entry.created_at = std::time::Instant::now();
            }
            if hover_idx == 0
                && let Some((_, t)) = self.toast.as_mut()
            {
                *t = std::time::Instant::now();
            }
        }
        if let Some((_, t)) = &self.toast
            && t.elapsed() >= TOAST_TTL
        {
            self.toast = None;
        }
        // Expire stacked toasts individually (entries are independent —
        // a rapid burst of toasts ages out one-by-one rather than all
        // at once).
        while self
            .toast_stack
            .back()
            .is_some_and(|e| e.created_at.elapsed() >= TOAST_TTL)
        {
            self.toast_stack.pop_back();
        }
        self.expire_progress_items();
        self.tick_pending_undo();
        self.tick_claude_agents_prefetch();
        // #993 step 2b (2026-08-20) — background auto-update firing.
        // Short-circuits when no opt-in is set (global OR per-integration).
        self.tick_auto_updates();
    }

    /// Lines of viewport drift before [`Self::refresh_scroll_semantic_tokens`]
    /// re-fires a `semanticTokens/range` request. 20 is a quiet middle
    /// ground — small scrolls don't mash the server, but any meaningful
    /// jump refreshes promptly.
    pub(crate) const VIEWPORT_REFIRE_THRESHOLD: u32 = 20;

    /// Clear `Buffer.yank_flash` entries older than ~200ms so the
    /// highlight-on-yank overlay fades naturally.
    fn expire_yank_flashes(&mut self) {
        const YANK_FLASH_TTL: std::time::Duration = std::time::Duration::from_millis(200);
        let now = std::time::Instant::now();
        for pane in self.panes.iter_mut() {
            if let Pane::Editor(b) = pane
                && let Some((_, _, started)) = b.yank_flash
                && now.duration_since(started) >= YANK_FLASH_TTL
            {
                b.yank_flash = None;
            }
        }
    }

    /// Re-run tree-sitter on any editor buffer whose `highlights_dirty` is
    /// set AND whose last edit was more than ~120ms ago. Lets rapid
    /// typing skip the re-parse hit; the next idle frame catches up.
    fn refresh_stale_highlights(&mut self) {
        const HIGHLIGHT_IDLE: std::time::Duration = std::time::Duration::from_millis(120);
        let now = std::time::Instant::now();
        for pane in self.panes.iter_mut() {
            if let Pane::Editor(b) = pane
                && b.highlights_dirty
                && b.last_edited
                    .map(|t| now.duration_since(t) >= HIGHLIGHT_IDLE)
                    .unwrap_or(true)
            {
                b.refresh_highlights();
            }
        }
    }

    /// Check every open editor buffer's path for an external mtime
    /// change vs the last-known `disk_mtime`. Throttled to once every
    /// ~2 seconds (stat is cheap but not free, and tick fires
    /// continuously). When divergence is detected:
    /// - Clean buffer (no unsaved edits) ⇒ silently reload from disk +
    ///   toast "<file> reloaded".
    /// - Dirty buffer ⇒ toast a warning ("<file> changed on disk —
    ///   :e! to discard / save to overwrite") and leave the buffer
    ///   alone. The mtime mirror is still updated so the warning fires
    ///   only once per change.
    fn check_external_file_changes(&mut self) {
        let now = std::time::Instant::now();
        if let Some(last) = self.last_external_check
            && now.duration_since(last) < std::time::Duration::from_secs(2)
        {
            return;
        }
        self.last_external_check = Some(now);
        // Collect the (idx, path, was_dirty) for buffers whose mtime
        // diverges. Done as a separate pass to avoid borrow conflicts.
        let mut diverged: Vec<(usize, std::path::PathBuf, bool)> = Vec::new();
        for (i, p) in self.panes.iter().enumerate() {
            let Pane::Editor(b) = p else { continue };
            let Some(path) = &b.path else { continue };
            let Some(last_known) = b.disk_mtime else {
                continue;
            };
            let Ok(now_mtime) = std::fs::metadata(path).and_then(|m| m.modified()) else {
                continue;
            };
            if now_mtime > last_known {
                diverged.push((i, path.clone(), b.dirty));
            }
        }
        for (idx, path, was_dirty) in diverged {
            if was_dirty {
                let rel = rel_path(&self.workspace, &path);
                self.toast(format!(
                    "{rel} changed on disk — :e! to discard / save to overwrite"
                ));
                // Update mtime so we don't re-toast next tick.
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.disk_mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
                }
            } else {
                // Clean ⇒ silently reload. Capture cursor + scroll, re-read,
                // restore.
                let (cursor, scroll) = if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                    (b.editor.cursor(), b.scroll)
                } else {
                    (0, 0)
                };
                if let Ok(text) = std::fs::read_to_string(&path)
                    && let Some(Pane::Editor(b)) = self.panes.get_mut(idx)
                {
                    let len = b.editor.text().len();
                    b.apply_edit_ops(
                        vec![crate::edit_op::EditOp::ReplaceRange {
                            start: 0,
                            end: len,
                            text: text.clone(),
                        }],
                        &mut self.clipboard,
                        0,
                    );
                    let new_len = b.editor.text().len();
                    b.editor.place_cursor(0, 0);
                    let _ = new_len; // placeholder if needed later
                    // Restore cursor + scroll best-effort.
                    let cur = cursor.min(b.editor.text().len());
                    let row = b.editor.text()[..cur]
                        .bytes()
                        .filter(|&c| c == b'\n')
                        .count();
                    let line_count = b.editor.line_count();
                    b.editor
                        .place_cursor(row.min(line_count.saturating_sub(1)), 0);
                    b.scroll = scroll.min(line_count.saturating_sub(1));
                    b.dirty = false;
                    b.disk_mtime = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
                    let rel = rel_path(&self.workspace, &path);
                    self.toast(format!("{rel} reloaded"));
                    self.lsp.did_save(&path, &text);
                }
            }
        }
    }

    /// `[editor] autosave_secs > 0` ⇒ save any dirty editor buffer whose last
    /// edit was at least that long ago. No-op when off (the default). LSP gets a
    /// `didSave` per saved file so the server stays in sync.
    fn autosave_idle_buffers(&mut self) {
        let after = self.config.editor.autosave_secs;
        if after == 0 {
            return;
        }
        let after = std::time::Duration::from_secs(after);
        let saved: Vec<(std::path::PathBuf, String)> = self
            .panes
            .iter_mut()
            .filter_map(|p| match p {
                Pane::Editor(b) => {
                    if b.dirty
                        && b.path.is_some()
                        && b.last_edited.map(|t| t.elapsed() >= after).unwrap_or(false)
                        && b.save_to_disk().is_ok()
                    {
                        b.path.clone().map(|p| (p, b.editor.text().to_string()))
                    } else {
                        None
                    }
                }
                _ => None,
            })
            .collect();
        for (p, t) in saved {
            self.lsp.did_save(&p, &t);
        }
    }

    /// #1023 (2026-08-18) — When `[ui] theme_auto_system` is on,
    /// poll the OS dark/light preference every 15s and swap
    /// themes if the user toggled system-wide dark mode. No-op
    /// when the pref is off, so users on split-preference setups
    /// aren't overridden. First call schedules the initial poll
    /// immediately; steady-state throttles to 1 poll per 15s.
    ///
    /// Swap policy: if system is dark, apply `theme_toggle` (the
    /// configured dark counterpart); if light, apply `theme`
    /// (the base). Falls back to `theme` when `theme_toggle` is
    /// unset. Matches the one-shot `theme.auto_system` command's
    /// mapping in `src/command.rs`.
    fn maybe_poll_system_theme(&mut self) {
        if !self.config.ui.theme_auto_system {
            return;
        }
        const THEME_POLL_MIN: std::time::Duration = std::time::Duration::from_secs(15);
        let should_check = self
            .last_theme_system_check
            .map(|t| t.elapsed() >= THEME_POLL_MIN)
            .unwrap_or(true);
        if !should_check {
            return;
        }
        self.last_theme_system_check = Some(std::time::Instant::now());
        let is_dark = crate::ui::theme::detect_system_dark();
        let target = if is_dark {
            self.config
                .ui
                .theme_toggle
                .clone()
                .unwrap_or_else(|| self.config.ui.theme.clone())
        } else {
            self.config.ui.theme.clone()
        };
        if crate::ui::theme::cur().name != target && crate::ui::theme::set(&target).is_some() {
            let mode = if is_dark { "dark" } else { "light" };
            self.toast(format!("theme: {target} (system {mode})"));
        }
    }
}
