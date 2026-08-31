//! Toasts (transient, stack, persistent), progress bars, dynamic
//! statusline segments, and OS-level notifications (OSC 9 / 777).
//! This is the SDK surface integrations write to via `mnml-bridge`.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    /// Level-tagged toast. Info + warn render with the standard
    /// comment-color border; error renders red. All toasts also
    /// land in `message_log` (recoverable via `:messages`).
    pub fn toast_leveled(&mut self, msg: impl Into<String>, level: ToastLevel) {
        let s: String = msg.into();
        // `:silent <cmd>` suppresses the visible toast but the message
        // is still recorded in the log so `:messages` can recover it.
        if self.silent_depth == 0 {
            let now = Instant::now();
            self.toast = Some((s.clone(), now));
            let entry = ToastEntry {
                text: s.clone(),
                created_at: now,
                level,
                persistent_id: None,
            };
            self.toast_stack.push_front(entry);
            while self.toast_stack.len() > TOAST_STACK_MAX {
                self.toast_stack.pop_back();
            }
        }
        // Recorded even when `:silent` suppressed the visible toast —
        // that is the point of a log.
        self.message_log.push(crate::app::LoggedMessage {
            text: s,
            level,
            at: crate::app::now_unix(),
        });
        if matches!(level, ToastLevel::Warn | ToastLevel::Error) {
            self.unread_messages += 1;
        }
        // Straight to disk, per entry rather than dumped on quit: a crash
        // is exactly when you want to know what the last message said,
        // and a quit-time dump loses that case.
        if let Some(m) = self.message_log.last() {
            let m = m.clone();
            self.persist_message(&m);
        }
        if self.message_log.len() > MESSAGE_LOG_MAX {
            let drop = self.message_log.len() - MESSAGE_LOG_MAX;
            self.message_log.drain(..drop);
        }
    }

    /// Convenience — level=Error (renders with red border).
    pub fn toast_error(&mut self, msg: impl Into<String>) {
        self.toast_leveled(msg, ToastLevel::Error);
    }

    /// Show a pinned toast identified by `id`. A repeat call with
    /// the same `id` updates the text/level in place (single toast,
    /// not stacked). Stays visible until `toast_dismiss(id)`.
    pub fn toast_persistent(
        &mut self,
        id: impl Into<String>,
        msg: impl Into<String>,
        level: ToastLevel,
    ) {
        let id: String = id.into();
        let s: String = msg.into();
        self.message_log.push(crate::app::LoggedMessage {
            text: s.clone(),
            level,
            at: crate::app::now_unix(),
        });
        if self.message_log.len() > MESSAGE_LOG_MAX {
            let drop = self.message_log.len() - MESSAGE_LOG_MAX;
            self.message_log.drain(..drop);
        }
        if self.silent_depth > 0 {
            return;
        }
        if let Some(slot) = self
            .persistent_toasts
            .iter_mut()
            .find(|t| t.persistent_id.as_deref() == Some(id.as_str()))
        {
            slot.text = s;
            slot.level = level;
            slot.created_at = Instant::now();
        } else {
            self.persistent_toasts.push(ToastEntry {
                text: s,
                created_at: Instant::now(),
                level,
                persistent_id: Some(id),
            });
        }
    }

    /// Dismiss a persistent toast by id. No-op if the id isn't
    /// currently pinned.
    pub fn toast_dismiss(&mut self, id: &str) {
        self.persistent_toasts
            .retain(|t| t.persistent_id.as_deref() != Some(id));
    }

    /// Start (or restart) a progress notification for `id`. If an
    /// item with the same id already exists, it's reset —
    /// spinner phase restarts, percent clears.
    pub fn progress_start(&mut self, id: impl Into<String>, label: impl Into<String>) {
        let id: String = id.into();
        let label: String = label.into();
        if self.silent_depth > 0 {
            return;
        }
        if let Some(slot) = self.progress_items.iter_mut().find(|p| p.id == id) {
            slot.label = label;
            slot.percent = None;
            slot.started_at = Instant::now();
            slot.finished = None;
        } else {
            self.progress_items.push(ProgressItem {
                id,
                label,
                percent: None,
                started_at: Instant::now(),
                finished: None,
            });
        }
    }

    /// Update an in-flight progress item. `label` is optional —
    /// pass `None` to keep the previous label. `percent` similarly
    /// optional; clamped to 0..=100. No-op if `id` isn't tracked
    /// or already finished.
    pub fn progress_update(&mut self, id: &str, label: Option<String>, percent: Option<u8>) {
        if let Some(p) = self.progress_items.iter_mut().find(|p| p.id == id)
            && p.finished.is_none()
        {
            if let Some(l) = label {
                p.label = l;
            }
            if let Some(pct) = percent {
                p.percent = Some(pct.min(100));
            }
        }
    }

    /// Finish a progress item. Sets its terminal status glyph and
    /// starts the fade timer — the row lingers for
    /// [`PROGRESS_END_FADE`] before removal so the user can see
    /// the outcome. `Failed` also fires a `toast_error` with the
    /// item's label. `Success` and `Cancelled` don't toast (the
    /// on-screen glyph is enough — cheap common cases).
    pub fn progress_end(&mut self, id: &str, status: ProgressStatus) {
        let Some(p) = self.progress_items.iter_mut().find(|p| p.id == id) else {
            return;
        };
        if p.finished.is_some() {
            return;
        }
        p.finished = Some((status, Instant::now()));
        let label = p.label.clone();
        if matches!(status, ProgressStatus::Failed) {
            self.toast_error(format!("failed: {label}"));
        }
    }

    /// Purge progress items whose fade has elapsed. Called from
    /// the main tick.
    pub(crate) fn expire_progress_items(&mut self) {
        self.progress_items.retain(|p| match p.finished {
            None => true,
            Some((_, at)) => at.elapsed() < PROGRESS_END_FADE,
        });
    }

    /// Insert or update a integration statusline segment. Keyed by
    /// `id`; repeat calls with the same id update the entry in
    /// place. Rendered on the next paint.
    #[allow(clippy::too_many_arguments)]
    pub fn statusline_set_segment(
        &mut self,
        id: impl Into<String>,
        side: SegmentSide,
        text: impl Into<String>,
        color: Option<String>,
        click_command: Option<String>,
        priority: u8,
        min_width: u16,
        max_width: u16,
    ) {
        // Delegate to the tooltip-aware setter with tooltip=None so
        // existing integration IPC callers stay call-compatible while
        // the manifest-driven poll pipeline can pass a real tooltip.
        self.statusline_set_segment_full(
            id,
            side,
            text,
            color,
            None,
            click_command,
            priority,
            min_width,
            max_width,
        );
    }

    /// Task #965 follow-up 2026-08-17 — same as `statusline_set_segment`
    /// with an added `tooltip` slot so the manifest-driven pipeline
    /// can surface `waiting for first poll` / `last error: …` states
    /// through hover-help instead of silently swallowing them.
    #[allow(clippy::too_many_arguments)]
    pub fn statusline_set_segment_full(
        &mut self,
        id: impl Into<String>,
        side: SegmentSide,
        text: impl Into<String>,
        color: Option<String>,
        tooltip: Option<String>,
        click_command: Option<String>,
        priority: u8,
        min_width: u16,
        max_width: u16,
    ) {
        let id: String = id.into();
        let text: String = text.into();
        if let Some(slot) = self.dynamic_segments.iter_mut().find(|s| s.id == id) {
            slot.side = side;
            slot.text = text;
            slot.color = color;
            slot.tooltip = tooltip;
            slot.click_command = click_command;
            slot.priority = priority;
            slot.min_width = min_width;
            slot.max_width = max_width;
            slot.last_updated = Instant::now();
        } else {
            self.dynamic_segments.push(DynamicSegment {
                id,
                side,
                text,
                color,
                tooltip,
                click_command,
                priority,
                min_width,
                max_width,
                last_updated: Instant::now(),
            });
        }
    }

    /// Remove a integration statusline segment by id.
    pub fn statusline_clear_segment(&mut self, id: &str) {
        self.dynamic_segments.retain(|s| s.id != id);
    }

    /// Fire a notification. Always renders an in-app toast at
    /// `level` (per Call 1: info + warn share the comment border,
    /// error gets red). If the `source` integration's manifest
    /// permits OS notifications and the per-integration rate
    /// limit has elapsed, also queues the OSC 9 / OSC 777 escape
    /// sequences for the next render pass — the terminal (Ghostty
    /// / iTerm2 / kitty) routes those to native banners.
    ///
    /// Rate-limit behavior:
    ///   - `source = None` → always fires (no rate tracking).
    ///   - `source = Some(id)` → suppressed if last fire was
    ///     within `os_rate_limit_sec` on the integration's
    ///     manifest (default 5s). Suppressed OS fires still fire
    ///     the in-app toast.
    pub fn notify(
        &mut self,
        title: impl Into<String>,
        body: impl Into<String>,
        level: ToastLevel,
        sound: bool,
        source: Option<&str>,
    ) {
        let title: String = title.into();
        let body: String = body.into();
        // In-app toast — `level=error` pins to the persistent slot
        // so critical notifications don't expire on TTL. `warn`
        // and `info` stay ephemeral like before. mouse-round-10
        // SEV-3 2026-07-12.
        if matches!(level, ToastLevel::Error) {
            // Use the source id when provided so a follow-up
            // notify(same source) updates the existing pinned
            // slot in place rather than stacking a duplicate. Fall
            // back to a title-derived id so at least the same title
            // deduplicates.
            let id = source
                .map(str::to_string)
                .unwrap_or_else(|| format!("notify:{title}"));
            self.toast_persistent(id, format!("{title}: {body}"), level);
        } else {
            self.toast_leveled(format!("{title}: {body}"), level);
        }
        // OS notification is opt-in per integration.
        let (os_ok, rate_secs) = match source {
            None => (true, 0), // no source → no policy → fire
            Some(id) => self.os_notify_policy_for(id),
        };
        if !os_ok {
            return;
        }
        if let Some(src) = source
            && rate_secs > 0
        {
            let now = Instant::now();
            if let Some(&last) = self.notify_last_fired.get(src)
                && now.duration_since(last) < Duration::from_secs(rate_secs)
            {
                return; // rate-limited — in-app toast only
            }
            self.notify_last_fired.insert(src.to_string(), now);
        }
        self.pending_os_notifications.push((title, body, sound));
    }

    /// Resolve the OS-notification policy for an integration id
    /// by consulting its manifest. Returns `(should_fire,
    /// rate_secs)`. Absent manifest → default policy: fire, no
    /// rate limit. Present manifest with `os_notify_on = "never"`
    /// → don't fire.
    fn os_notify_policy_for(&self, id: &str) -> (bool, u64) {
        let Some(m) = self.integration_manifests.iter().find(|m| m.id == id) else {
            return (true, 0);
        };
        let Some(n) = &m.notifications else {
            return (true, 0);
        };
        let fire = !matches!(
            n.os_notify_on,
            crate::integration_manifest::OsNotifyPolicy::Never
        );
        (fire, n.os_rate_limit_sec)
    }

    /// Drain queued OS notifications — invoked by the tui render
    /// loop after `term.draw`. Returns the drained items so the
    /// caller can flush them via crossterm's `execute!` (App
    /// doesn't own stdout).
    pub fn take_pending_os_notifications(&mut self) -> Vec<(String, String, bool)> {
        std::mem::take(&mut self.pending_os_notifications)
    }
    /// Current toast text if it hasn't expired AND there's no live
    /// top-right toast box painting the same message. mouse-round-11
    /// SEV-3 2026-07-12 — solo toasts now always render as a box
    /// (round-10 SEV-3 fix), so echoing the same string on the
    /// cmdline row while the box is up double-renders. Cmdline
    /// echo returns only once every box has faded (log-tail
    /// semantic) so the message still persists past the box's TTL.
    pub fn live_toast(&self) -> Option<&str> {
        if !self.toast_stack.is_empty() || !self.persistent_toasts.is_empty() {
            return None;
        }
        self.toast
            .as_ref()
            .filter(|(_, t)| t.elapsed() < TOAST_TTL)
            .map(|(s, _)| s.as_str())
    }
}
