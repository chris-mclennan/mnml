//! Debug Adapter Protocol (DAP) methods on `App`.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move: no API
//! change. Owns the `dap.*` palette commands (run / attach / step /
//! continue / pause / breakpoints / watches / exceptions / repl)
//! and the `Pane::Debug` viewer.

use super::*;

impl App {
    /// `dap.toggle_breakpoint` — flip a breakpoint on the active
    /// editor's cursor line. Painted as a red `●` in the gutter (wins
    /// over LSP severity dots + git change marks). Persisted in
    /// session.json. If a DAP session is live, also re-sends the
    /// updated breakpoint list to the adapter so it takes effect
    /// immediately (DAP `setBreakpoints` is per-file, not per-line, so
    /// we send the whole list).
    pub fn dap_toggle_breakpoint(&mut self) {
        let Some(b) = self.active_editor_mut() else {
            self.toast("no active editor");
            return;
        };
        let (row, _) = b.editor.row_col();
        let added = b.toggle_breakpoint(row as u32);
        let line_no = row + 1;
        let path = b.path.clone();
        let lines = b.breakpoints.clone();
        let conds = b.breakpoint_conditions.clone();
        let hits = b.breakpoint_hit_conditions.clone();
        self.toast(if added {
            format!("breakpoint set: line {line_no}")
        } else {
            format!("breakpoint cleared: line {line_no}")
        });
        // If the adapter is live + initialized, push the new list —
        // include condition + hit-condition maps so any pre-existing
        // conditional / hit-count BPs on other lines survive a toggle
        // elsewhere.
        if let (Some(mgr), Some(p)) = (self.dap.as_mut(), path)
            && mgr.initialized
            && let Err(e) = mgr
                .client
                .set_breakpoints_with_conditions(&p, &lines, &conds, &hits)
        {
            self.toast(format!("dap setBreakpoints: {e}"));
        }
    }

    /// `dap.clear_all_breakpoints` — clear every breakpoint in the
    /// active buffer.
    pub fn dap_clear_all_breakpoints(&mut self) {
        let Some(b) = self.active_editor_mut() else {
            self.toast("no active editor");
            return;
        };
        let n = b.breakpoints.len();
        b.breakpoints.clear();
        self.toast(format!(
            "cleared {n} breakpoint{}",
            if n == 1 { "" } else { "s" }
        ));
    }

    /// `dap.list_breakpoints` — toast a summary of all breakpoints
    /// across every open editor buffer. Useful for "where are my
    /// breakpoints?" pre-debug-session check.
    pub fn dap_list_breakpoints(&mut self) {
        let mut total = 0usize;
        let mut parts: Vec<String> = Vec::new();
        for p in &self.panes {
            if let Pane::Editor(b) = p
                && !b.breakpoints.is_empty()
            {
                total += b.breakpoints.len();
                let name = b.display_name();
                let lines: Vec<String> =
                    b.breakpoints.iter().map(|l| (l + 1).to_string()).collect();
                parts.push(format!("{name}: {}", lines.join(",")));
            }
        }
        if total == 0 {
            self.toast("no breakpoints set");
        } else {
            self.toast(format!("{total} breakpoint(s) — {}", parts.join(" · ")));
        }
    }

    /// `dap.run` — spawn the configured DAP adapter for the active
    /// buffer's filetype, send the canonical handshake (initialize →
    /// launch → setBreakpoints (per open buffer) → configurationDone),
    /// and pump adapter events back into `App.dap`. Toasts when no
    /// `[dap.<lang>]` config matches the active filetype.
    ///
    /// Only one session at a time for the MVP — calling this with a
    /// session already live drops the old one (Drop sends `disconnect`).
    pub fn dap_run(&mut self) {
        // Pick an adapter by the active buffer's language extension.
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let lang = match b.language_ext.as_deref() {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => {
                self.toast("dap: no filetype");
                return;
            }
        };
        let raw = match self.config.dap.get(&lang) {
            Some(v) => v.clone(),
            None => {
                self.toast(format!("dap: no [dap.{lang}] config"));
                return;
            }
        };
        let cfg = match crate::dap::AdapterConfig::from_toml(&raw) {
            Ok(c) => c,
            Err(e) => {
                self.toast(format!("dap: config error: {e}"));
                return;
            }
        };
        let active_path = b.path.clone();
        let workspace = self.workspace.clone();
        // Drop any existing session first.
        self.dap = None;
        self.dap_arrow = None;
        self.dap_thread = None;
        let (tx, rx) = std::sync::mpsc::channel();
        let client = match crate::dap::DapClient::spawn(&cfg, &workspace, tx) {
            Ok(c) => c,
            Err(e) => {
                self.toast(format!("dap spawn failed: {e}"));
                return;
            }
        };
        let mut mgr = crate::dap::DapManager::new(client, rx);
        // initialize. The `initialized` event lands later; the App
        // continues the handshake from there (sets breakpoints, then
        // launches with the substituted body).
        if let Err(e) = mgr.client.initialize() {
            self.toast(format!("dap init failed: {e}"));
            return;
        }
        // Stash the substituted launch body + active path on the manager
        // (we'll send launch after `Initialized` to give the adapter time
        // to register).
        let mut launch_body = cfg.launch.clone();
        crate::dap::substitute_vars(&mut launch_body, &workspace, active_path.as_deref());
        self.dap = Some(mgr);
        // Push the launch body + active path onto a deferred slot the
        // drain consumes when `Initialized` lands.
        self.dap_pending_launch = Some(launch_body);
        self.toast(format!("dap: spawned {} adapter", cfg.cmd));
    }

    /// `dap.attach` — open a picker over running processes and attach
    /// the adapter to the picked PID. Same shape as `dap_run` but forces
    /// `request: "attach"` and injects `pid` into the launch body. The
    /// user's `[dap.<lang>]` config can pre-fill other attach fields
    /// (e.g. `host`, `port` for remote attach).
    pub fn open_dap_attach_picker(&mut self) {
        let candidates = list_attachable_processes();
        if candidates.is_empty() {
            self.toast("dap: no processes found (is `ps` on PATH?)");
            return;
        }
        use crate::picker::{Picker, PickerItem, PickerKind};
        let items: Vec<PickerItem> = candidates
            .into_iter()
            .map(|p| {
                PickerItem::new(
                    p.pid.to_string(),
                    format!("{:>6}  {}", p.pid, p.cmd),
                    &p.user,
                )
            })
            .collect();
        self.picker = Some(Picker::new(
            PickerKind::DapAttach,
            "Attach to process",
            items,
        ));
    }

    /// Accept callback for the [`PickerKind::DapAttach`] picker. Runs
    /// the dap_run handshake but forces `request: "attach"` and
    /// `pid: <picked>`. Adapter config still comes from
    /// `[dap.<active-language>]`.
    pub fn dap_attach_to_pid(&mut self, pid: i64) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let lang = match b.language_ext.as_deref() {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => {
                self.toast("dap: no filetype");
                return;
            }
        };
        let raw = match self.config.dap.get(&lang) {
            Some(v) => v.clone(),
            None => {
                self.toast(format!("dap: no [dap.{lang}] config"));
                return;
            }
        };
        let cfg = match crate::dap::AdapterConfig::from_toml(&raw) {
            Ok(c) => c,
            Err(e) => {
                self.toast(format!("dap: config error: {e}"));
                return;
            }
        };
        let active_path = b.path.clone();
        let workspace = self.workspace.clone();
        self.dap = None;
        self.dap_arrow = None;
        self.dap_thread = None;
        let (tx, rx) = std::sync::mpsc::channel();
        let client = match crate::dap::DapClient::spawn(&cfg, &workspace, tx) {
            Ok(c) => c,
            Err(e) => {
                self.toast(format!("dap spawn failed: {e}"));
                return;
            }
        };
        let mut mgr = crate::dap::DapManager::new(client, rx);
        if let Err(e) = mgr.client.initialize() {
            self.toast(format!("dap init failed: {e}"));
            return;
        }
        // Build the attach body: copy the user's config + force
        // `request: "attach"` + inject the picked pid. The user's
        // pre-existing `attach.*` fields (host, port, etc.) survive.
        let mut attach_body = cfg.launch.clone();
        if let Some(obj) = attach_body.as_object_mut() {
            obj.insert(
                "request".to_string(),
                serde_json::Value::String("attach".to_string()),
            );
            obj.insert("pid".to_string(), serde_json::json!(pid));
        }
        crate::dap::substitute_vars(&mut attach_body, &workspace, active_path.as_deref());
        self.dap = Some(mgr);
        self.dap_pending_launch = Some(attach_body);
        self.toast(format!("dap: attaching to pid {pid}"));
    }

    /// Continue execution. No-op when no session / not stopped.
    pub fn dap_continue(&mut self) {
        let Some(mgr) = self.dap.as_mut() else {
            return;
        };
        let Some(tid) = self.dap_thread else {
            self.toast("dap: not stopped");
            return;
        };
        if let Err(e) = mgr.client.cont(tid) {
            self.toast(format!("dap continue: {e}"));
        }
    }

    pub fn dap_next(&mut self) {
        let Some(mgr) = self.dap.as_mut() else {
            return;
        };
        let Some(tid) = self.dap_thread else {
            return;
        };
        if let Err(e) = mgr.client.next(tid) {
            self.toast(format!("dap next: {e}"));
        }
    }

    pub fn dap_step_in(&mut self) {
        let Some(mgr) = self.dap.as_mut() else {
            return;
        };
        let Some(tid) = self.dap_thread else {
            return;
        };
        if let Err(e) = mgr.client.step_in(tid) {
            self.toast(format!("dap step_in: {e}"));
        }
    }

    pub fn dap_step_out(&mut self) {
        let Some(mgr) = self.dap.as_mut() else {
            return;
        };
        let Some(tid) = self.dap_thread else {
            return;
        };
        if let Err(e) = mgr.client.step_out(tid) {
            self.toast(format!("dap step_out: {e}"));
        }
    }

    pub fn dap_pause(&mut self) {
        let Some(mgr) = self.dap.as_mut() else {
            return;
        };
        let tid = self.dap_thread.unwrap_or(1);
        if let Err(e) = mgr.client.pause(tid) {
            self.toast(format!("dap pause: {e}"));
        }
    }

    /// Step backward one statement. Adapter must support reverse-
    /// debugging (rr / lldb-rr / a few record-replay shapes); on
    /// unsupported adapters the request returns `success: false`
    /// which flows through the generic `DapEvent::Failed` toast.
    pub fn dap_step_back(&mut self) {
        let Some(mgr) = self.dap.as_mut() else {
            return;
        };
        let Some(tid) = self.dap_thread else {
            self.toast("dap: not stopped");
            return;
        };
        if let Err(e) = mgr.client.step_back(tid) {
            self.toast(format!("dap step_back: {e}"));
        }
    }

    /// Reverse-continue: resume execution backward to the previous
    /// breakpoint (or the start of recorded history). Same adapter
    /// support caveat as [`Self::dap_step_back`].
    pub fn dap_reverse_continue(&mut self) {
        let Some(mgr) = self.dap.as_mut() else {
            return;
        };
        let Some(tid) = self.dap_thread else {
            self.toast("dap: not stopped");
            return;
        };
        if let Err(e) = mgr.client.reverse_continue(tid) {
            self.toast(format!("dap reverse_continue: {e}"));
        }
    }

    /// `dap.add_watch` — open a prompt for a new watch expression. Any
    /// non-empty expression is pushed onto `dap_watches` and evaluated
    /// immediately if a stopped session is open.
    pub fn open_dap_add_watch_prompt(&mut self) {
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::DapAddWatch,
            "Watch expression",
        ));
    }

    /// `dap.remove_watch` — fuzzy picker over the current watch list;
    /// accept drops the chosen expression from `dap_watches` + its
    /// cached result. No-op when there are no watches.
    pub fn open_dap_remove_watch_picker(&mut self) {
        if self.dap_watches.is_empty() {
            self.toast("no watches to remove");
            return;
        }
        use crate::picker::{Picker, PickerItem, PickerKind};
        let items: Vec<PickerItem> = self
            .dap_watches
            .iter()
            .map(|w| {
                // Detail line shows the cached value (or "(no value yet)"
                // when the watch hasn't been evaluated) so the user
                // can pick by content as well as expression text.
                let detail = self
                    .dap_watch_results
                    .get(w)
                    .map(|r| {
                        if let Some(err) = &r.err {
                            format!("err: {err}")
                        } else {
                            r.value.clone()
                        }
                    })
                    .unwrap_or_else(|| "(no value yet)".to_string());
                PickerItem::new(w, w, detail)
            })
            .collect();
        self.picker = Some(Picker::new(
            PickerKind::DapWatchRemove,
            "Remove watch",
            items,
        ));
    }

    /// `dap.clear_watches` — drop every watch expression + its cached
    /// result. No prompt — the picker handles per-item removal.
    pub fn dap_clear_watches(&mut self) {
        let n = self.dap_watches.len();
        self.dap_watches.clear();
        self.dap_watch_results.clear();
        self.toast(format!("watches: cleared {n}"));
    }

    /// `dap.toggle_breakpoint_conditional` — open a prompt for a
    /// condition expression at the cursor's line. Empty input ⇒ plain
    /// breakpoint (no condition); non-empty ⇒ DAP-conditional. Stashes
    /// the `(line0, path)` on `dap_pending_bp_condition` until accept.
    pub fn open_dap_breakpoint_conditional_prompt(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("buffer has no path");
            return;
        };
        let (row, _) = b.editor.row_col();
        let line0 = row as u32;
        // Pre-fill any existing condition so the user can edit instead
        // of re-typing.
        let seed = b
            .breakpoint_conditions
            .get(&line0)
            .cloned()
            .unwrap_or_default();
        self.dap_pending_bp_condition = Some((line0, path));
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::DapBreakpointCondition,
            format!("Breakpoint condition (line {})", line0 + 1),
            seed,
        ));
    }

    /// `dap.set_breakpoint_hit_count` — open a prompt for a hit-count
    /// expression on the cursor's line. Empty input clears the
    /// existing hit-count (the line stays a regular / conditional BP).
    /// Pre-fills any existing hit-condition so the user can edit
    /// rather than re-type. Reuses `dap_pending_bp_condition` for
    /// the stash (only one BP prompt is open at a time).
    pub fn open_dap_breakpoint_hit_count_prompt(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("buffer has no path");
            return;
        };
        let (row, _) = b.editor.row_col();
        let line0 = row as u32;
        let seed = b
            .breakpoint_hit_conditions
            .get(&line0)
            .cloned()
            .unwrap_or_default();
        self.dap_pending_bp_condition = Some((line0, path));
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::DapBreakpointHitCount,
            format!(
                "Hit-count condition (line {})  e.g. >= 5  or  % 10",
                line0 + 1
            ),
            seed,
        ));
    }

    /// `dap.repl` — open (or focus) the DAP REPL pane.
    pub fn open_dap_repl_pane(&mut self) {
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::DapRepl(_)))
        {
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::DapRepl(crate::pane::DapReplPane::default());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::Leaf(id);
                self.active = Some(id);
            }
        }
        self.focus = Focus::Pane;
    }

    /// Submit the REPL pane's current input — fire `evaluate` with
    /// `context: "repl"`, push a pending entry into history, clear
    /// the input. No-op when there's no live DAP session.
    pub fn dap_repl_submit(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::DapRepl(repl)) = self.panes.get_mut(id) else {
            return;
        };
        let expr = repl.input.trim().to_string();
        if expr.is_empty() {
            return;
        }
        // Push history + clear input.
        repl.history.push(crate::pane::DapReplEntry {
            expression: expr.clone(),
            value: String::new(),
            ty: None,
            err: None,
            pending: true,
            variables_ref: 0,
            expanded: false,
        });
        if repl.command_history.last() != Some(&expr) {
            repl.command_history.push(expr.clone());
        }
        repl.command_history_idx = None;
        repl.input.clear();
        repl.cursor = 0;
        repl.scroll = usize::MAX; // pin to tail
        // Now fire evaluate. Prefer the current stopped frame's id;
        // global eval (no frame) is fine too — some adapters accept it.
        let frame_id = self
            .dap
            .as_ref()
            .and_then(|m| m.stack_frames.first().map(|f| f.id));
        if let Some(mgr) = self.dap.as_mut() {
            if let Err(e) = mgr.client.evaluate(&expr, frame_id, "repl") {
                // Mark the pending entry as failed locally so the user
                // sees feedback instead of an endless "evaluating…".
                if let Some(Pane::DapRepl(repl)) = self.panes.get_mut(id)
                    && let Some(last) = repl.history.last_mut()
                {
                    last.pending = false;
                    last.err = Some(format!("client error: {e}"));
                }
            }
        } else if let Some(Pane::DapRepl(repl)) = self.panes.get_mut(id)
            && let Some(last) = repl.history.last_mut()
        {
            last.pending = false;
            last.err = Some("no DAP session (run dap.run first)".to_string());
        }
    }

    /// Move the REPL's row selection by `delta`. None ⇒ defocus the
    /// row + return focus to the input (vim cmdline convention).
    /// Initial press starts at the bottom of history.
    pub fn dap_repl_select_move(&mut self, delta: isize) {
        let Some(id) = self.active else { return };
        let Some(Pane::DapRepl(repl)) = self.panes.get_mut(id) else {
            return;
        };
        // Move within the *visible* (post-filter) view so a held filter
        // doesn't let the selection land on a hidden row.
        let visible = repl.visible_history_indices();
        let vn = visible.len();
        if vn == 0 {
            return;
        }
        let cur_in_visible = repl
            .selected
            .and_then(|sel| visible.iter().position(|&i| i == sel))
            .unwrap_or(vn); // past-end ⇒ delta=-1 lands on last row (vim cmdline UX)
        let new_in_visible = (cur_in_visible as isize + delta).clamp(0, vn as isize - 1) as usize;
        let new = visible[new_in_visible];
        repl.selected = Some(new);
        repl.scroll = new;
    }

    /// `o` (open) in the REPL pane — expand the selected row if it's
    /// composite (`variables_ref > 0`). Fetches children if not yet
    /// cached. Toggles off on second press (children disappear).
    pub fn dap_repl_toggle_expand(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::DapRepl(repl)) = self.panes.get_mut(id) else {
            return;
        };
        let Some(sel) = repl.selected else {
            return;
        };
        let Some(entry) = repl.history.get_mut(sel) else {
            return;
        };
        if entry.variables_ref == 0 {
            return;
        }
        let r = entry.variables_ref;
        entry.expanded = !entry.expanded;
        let want_fetch = entry.expanded;
        // Trigger variables fetch when expanding. The reply lands on
        // `DapManager.variables[ref]`; the REPL renderer reads from
        // the same cache that drives the variables panel.
        if want_fetch
            && let Some(mgr) = self.dap.as_mut()
            && !mgr.variables.contains_key(&r)
        {
            let _ = mgr.client.variables(r);
        }
    }

    /// Walk the REPL's command history. `dir = -1` ⇒ older; `+1` ⇒
    /// newer. Reaching past newest restores the typed input (vim
    /// cmdline convention).
    pub fn dap_repl_history_walk(&mut self, dir: isize) {
        let Some(id) = self.active else { return };
        let Some(Pane::DapRepl(repl)) = self.panes.get_mut(id) else {
            return;
        };
        let h = &repl.command_history;
        if h.is_empty() {
            return;
        }
        let next = match (repl.command_history_idx, dir.signum()) {
            (None, -1) => Some(h.len() - 1),
            (Some(0), -1) => Some(0),
            (Some(i), -1) => Some(i - 1),
            (None, _) => return,
            (Some(i), 1) if i + 1 < h.len() => Some(i + 1),
            (Some(_), 1) => None,
            _ => return,
        };
        match next {
            Some(i) => {
                repl.input = h[i].clone();
                repl.cursor = repl.input.len();
                repl.command_history_idx = Some(i);
            }
            None => {
                repl.input.clear();
                repl.cursor = 0;
                repl.command_history_idx = None;
            }
        }
    }

    /// `dap.pick_thread` — open a picker over the adapter's current
    /// thread list (refreshed on each `Stopped`). Accept changes
    /// `App.dap_thread` + re-fetches the stack trace for the new
    /// thread. No-op when no session is live OR there's only one
    /// thread (the picker would be useless).
    pub fn open_dap_thread_picker(&mut self) {
        let threads: Vec<crate::dap::ThreadInfo> = self
            .dap
            .as_ref()
            .map(|m| m.threads.clone())
            .unwrap_or_default();
        if threads.is_empty() {
            self.toast("dap: no threads (start a session first)");
            return;
        }
        if threads.len() == 1 {
            self.toast(format!(
                "dap: only one thread ({}#{})",
                threads[0].name, threads[0].id
            ));
            return;
        }
        use crate::picker::{Picker, PickerItem, PickerKind};
        let current = self.dap_thread;
        let items: Vec<PickerItem> = threads
            .into_iter()
            .map(|t| {
                let marker = if Some(t.id) == current { "● " } else { "  " };
                PickerItem::new(
                    t.id.to_string(),
                    format!("{marker}{}", t.name),
                    format!("tid {}", t.id),
                )
            })
            .collect();
        self.picker = Some(Picker::new(PickerKind::DapThread, "Switch thread", items));
    }

    /// `dap.exceptions` — open a picker over the adapter's exception
    /// filters. Each row shows the current on/off state with a `●`
    /// marker; accept toggles that one filter + re-fires
    /// `setExceptionBreakpoints` with the new enabled set. Repeated
    /// picks toggle individual filters; close with Esc.
    pub fn open_dap_exception_picker(&mut self) {
        let filters: Vec<crate::dap::ExceptionFilter> = self
            .dap
            .as_ref()
            .map(|m| m.exception_filters.clone())
            .unwrap_or_default();
        if filters.is_empty() {
            self.toast("dap: adapter advertised no exception filters");
            return;
        }
        use crate::picker::{Picker, PickerItem, PickerKind};
        let enabled = self
            .dap
            .as_ref()
            .map(|m| m.enabled_exception_filters.clone())
            .unwrap_or_default();
        let items: Vec<PickerItem> = filters
            .into_iter()
            .map(|f| {
                let marker = if enabled.contains(&f.filter) {
                    "● "
                } else {
                    "○ "
                };
                let detail = if f.default {
                    format!("{} · default-on", f.filter)
                } else {
                    f.filter.clone()
                };
                PickerItem::new(f.filter, format!("{marker}{}", f.label), detail)
            })
            .collect();
        self.picker = Some(Picker::new(
            PickerKind::DapException,
            "Toggle exception breakpoint",
            items,
        ));
    }

    /// Accept callback for [`PickerKind::DapException`]. Toggles the
    /// filter in `enabled_exception_filters` and pushes the new set
    /// to the adapter.
    pub fn dap_toggle_exception_filter(&mut self, filter_id: &str) {
        let new_enabled: Vec<String> = if let Some(mgr) = self.dap.as_mut() {
            if mgr.enabled_exception_filters.contains(filter_id) {
                mgr.enabled_exception_filters.remove(filter_id);
            } else {
                mgr.enabled_exception_filters.insert(filter_id.to_string());
            }
            mgr.enabled_exception_filters.iter().cloned().collect()
        } else {
            return;
        };
        let on = self
            .dap
            .as_ref()
            .map(|m| m.enabled_exception_filters.contains(filter_id))
            .unwrap_or(false);
        if let Some(mgr) = self.dap.as_mut() {
            let _ = mgr.client.set_exception_breakpoints(&new_enabled);
        }
        self.toast(format!(
            "exception {filter_id}: {}",
            if on { "on" } else { "off" }
        ));
    }

    /// Switch the tracked DAP thread + re-fetch its stack trace so
    /// the call-stack / variables panels reflect the new thread.
    pub fn dap_switch_thread(&mut self, thread_id: i64) {
        self.dap_thread = Some(thread_id);
        if let Some(mgr) = self.dap.as_mut() {
            mgr.scopes.clear();
            mgr.variables.clear();
            let _ = mgr.client.stack_trace(thread_id);
        }
        self.toast(format!("dap: thread {thread_id}"));
    }

    pub fn dap_terminate(&mut self) {
        if let Some(mgr) = self.dap.as_mut() {
            let _ = mgr.client.terminate();
        }
        self.dap = None;
        self.dap_arrow = None;
        self.dap_thread = None;
        self.dap_output_log.clear();
        // Watch *expressions* (user input) survive a terminate so the
        // user doesn't lose their list; just the cached results go.
        self.dap_watch_results.clear();
        self.toast("dap: terminated");
    }

    /// Drain adapter events each tick. Drives the handshake state
    /// machine (sends `launch` + breakpoints after `Initialized`), pushes
    /// program output into `dap_output_log` (the `Pane::Debug` output
    /// section renders the tail; only `stderr` / `important` categories
    /// also toast), and on `Stopped` jumps the active editor to the
    /// source line + paints the execution arrow + requests a stack trace
    /// + threads.
    pub fn drain_dap_events(&mut self) {
        let Some(mgr) = self.dap.as_mut() else {
            return;
        };
        let events: Vec<crate::dap::DapEvent> = mgr.rx.try_iter().collect();
        if events.is_empty() {
            return;
        }
        for ev in events {
            match ev {
                crate::dap::DapEvent::Initialized => {
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.initialized = true;
                    }
                    // Send breakpoints for every open buffer that has any.
                    // Include condition + hit-condition maps so
                    // conditional + hit-count BPs that survived a
                    // session restart take effect immediately.
                    type BpSet = (
                        std::path::PathBuf,
                        Vec<u32>,
                        std::collections::HashMap<u32, String>,
                        std::collections::HashMap<u32, String>,
                    );
                    let bp_sets: Vec<BpSet> = self
                        .panes
                        .iter()
                        .filter_map(|p| match p {
                            Pane::Editor(b) if !b.breakpoints.is_empty() => Some((
                                b.path.clone()?,
                                b.breakpoints.clone(),
                                b.breakpoint_conditions.clone(),
                                b.breakpoint_hit_conditions.clone(),
                            )),
                            _ => None,
                        })
                        .collect();
                    if let Some(mgr) = self.dap.as_mut() {
                        for (path, lines, conds, hits) in &bp_sets {
                            let _ = mgr
                                .client
                                .set_breakpoints_with_conditions(path, lines, conds, hits);
                        }
                    }
                    // Now fire `launch` (with the stashed substituted body).
                    if let Some(body) = self.dap_pending_launch.take()
                        && let Some(mgr) = self.dap.as_mut()
                        && let Err(e) = mgr.client.launch(body)
                    {
                        self.toast(format!("dap launch: {e}"));
                    }
                    // And the obligatory configurationDone after our
                    // breakpoints are registered.
                    if let Some(mgr) = self.dap.as_mut() {
                        let _ = mgr.client.configuration_done();
                    }
                }
                crate::dap::DapEvent::Running => {
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.running = true;
                    }
                    self.dap_arrow = None;
                }
                crate::dap::DapEvent::Output { category, text } => {
                    // Push every non-empty line into the persistent log;
                    // the `Pane::Debug` renders the tail. Skip toasts for
                    // ordinary stdout chunks (would spam), but surface
                    // stderr / important categories.
                    for line in text.lines() {
                        let trimmed = line.trim_end_matches(['\r', '\n']);
                        if trimmed.is_empty() {
                            continue;
                        }
                        self.dap_output_log
                            .push((category.clone(), trimmed.to_string()));
                    }
                    if self.dap_output_log.len() > DAP_LOG_MAX {
                        let drop = self.dap_output_log.len() - DAP_LOG_MAX;
                        self.dap_output_log.drain(..drop);
                    }
                    if matches!(category.as_str(), "stderr" | "important") {
                        let preview: String =
                            text.lines().next().unwrap_or("").chars().take(80).collect();
                        if !preview.is_empty() {
                            self.toast(format!("dap[{category}]: {preview}"));
                        }
                    }
                }
                crate::dap::DapEvent::Stopped {
                    reason,
                    thread_id,
                    description,
                } => {
                    self.dap_thread = Some(thread_id);
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.stopped_at = Some((thread_id, None, 0, reason.clone()));
                        let _ = mgr.client.stack_trace(thread_id);
                        // Refresh the thread list — the multi-thread
                        // picker shows the current set, and adapters
                        // can spawn / join threads between stops.
                        let _ = mgr.client.threads();
                    }
                    let label = description.unwrap_or(reason);
                    self.toast(format!("dap: stopped ({label})"));
                }
                crate::dap::DapEvent::Threads(ts) => {
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.threads = ts;
                    }
                }
                crate::dap::DapEvent::InitializeCaps { exception_filters } => {
                    // Cache the filters; auto-enable any the adapter
                    // flagged `default = true` (debugpy's "uncaught"
                    // is typically default-on, "raised" is not). The
                    // user can toggle via `dap.exceptions`.
                    let defaults: Vec<String> = exception_filters
                        .iter()
                        .filter(|f| f.default)
                        .map(|f| f.filter.clone())
                        .collect();
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.exception_filters = exception_filters;
                        mgr.enabled_exception_filters = defaults.iter().cloned().collect();
                        // Tell the adapter about the defaults. This
                        // happens between `Initialized` (where
                        // setBreakpoints fires) and `configurationDone`
                        // — DAP allows it any time before resume.
                        let _ = mgr.client.set_exception_breakpoints(&defaults);
                    }
                }
                crate::dap::DapEvent::Continued => {
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.stopped_at = None;
                        // Variable references go stale across resume —
                        // drop the cached scopes + vars + ref-based
                        // expansion state. The next Stopped event will
                        // refetch. `expanded_paths` (name-keyed) is
                        // intentionally kept so the user's drill-down
                        // survives the step.
                        mgr.scopes.clear();
                        mgr.variables.clear();
                        mgr.expanded_vars.clear();
                    }
                    self.dap_arrow = None;
                    // Watch results from the prior stop don't reflect
                    // the new program state — drop them. Each watch
                    // re-evaluates on the next Stopped event.
                    self.dap_watch_results.clear();
                }
                crate::dap::DapEvent::StackTrace { frames, .. } => {
                    let top = frames.first().cloned();
                    let top_frame_id = top.as_ref().map(|f| f.id);
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.stack_frames = frames;
                        mgr.scopes.clear();
                        mgr.variables.clear();
                    }
                    // Auto-fetch scopes for the top frame so the
                    // variables panel populates as soon as we hit a
                    // breakpoint — no extra keystroke needed.
                    if let (Some(mgr), Some(fid)) = (self.dap.as_mut(), top_frame_id) {
                        let _ = mgr.client.scopes(fid);
                    }
                    // Re-evaluate every user-added watch expression
                    // against the new top frame so the watch panel
                    // reflects the current stop point.
                    let watches = self.dap_watches.clone();
                    if let (Some(mgr), Some(fid)) = (self.dap.as_mut(), top_frame_id) {
                        for expr in &watches {
                            let _ = mgr.client.evaluate(expr, Some(fid), "watch");
                        }
                    }
                    if let Some(f) = top
                        && let Some(src) = f.source
                    {
                        // DAP lines are 1-based on the wire; we sent
                        // `linesStartAt1: true` in `initialize`.
                        let line0 = f.line.saturating_sub(1);
                        self.dap_arrow = Some((src.clone(), line0));
                        // Jump the active editor to the stopped frame.
                        self.open_path(&src);
                        if let Some(b) = self.active_editor_mut() {
                            b.editor.place_cursor(line0 as usize, 0);
                        }
                    }
                }
                crate::dap::DapEvent::Scopes { scopes, .. } => {
                    // Auto-expand non-expensive scopes (typically
                    // "Locals" / "Arguments") and request their
                    // contents. Expensive scopes ("Globals") stay
                    // collapsed — the user can drill in manually.
                    let refs_to_fetch: Vec<i64> = scopes
                        .iter()
                        .filter(|s| s.variables_reference > 0 && !s.expensive)
                        .map(|s| s.variables_reference)
                        .collect();
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.scopes = scopes;
                        for r in &refs_to_fetch {
                            mgr.expanded_vars.insert(*r);
                        }
                        for r in &refs_to_fetch {
                            let _ = mgr.client.variables(*r);
                        }
                    }
                }
                crate::dap::DapEvent::Variables {
                    variables_ref,
                    variables,
                } => {
                    // Persist incoming children, then walk
                    // `expanded_paths` and re-arm any whose name-path
                    // now resolves in the (newly-richer) flattened
                    // tree. Each re-armed composite triggers a
                    // `variables` request for its fresh ref, which
                    // cascades through nested levels via the next
                    // Variables event. End result: a depth-N user
                    // expansion fans back out across a stop without
                    // any extra clicks.
                    if let Some(mgr) = self.dap.as_mut() {
                        mgr.variables.insert(variables_ref, variables);
                        // Snapshot to avoid borrow conflicts in the
                        // for-loop below.
                        let paths: Vec<Vec<String>> = mgr.expanded_paths.iter().cloned().collect();
                        for path in &paths {
                            if let Some(re) = mgr.var_ref_for_path(path)
                                && !mgr.expanded_vars.contains(&re)
                            {
                                mgr.expanded_vars.insert(re);
                                if !mgr.variables.contains_key(&re) {
                                    let _ = mgr.client.variables(re);
                                }
                            }
                        }
                    }
                }
                crate::dap::DapEvent::SetVariableDone {
                    parent_ref,
                    name,
                    value,
                    ty,
                    variables_ref,
                } => {
                    // Patch the cached child in place so the variables
                    // panel reflects the new value without waiting for
                    // a fresh `variables` request. The adapter may have
                    // rewritten the formatted value (e.g. trimming quotes
                    // off a string literal) — trust the reply.
                    if let Some(mgr) = self.dap.as_mut()
                        && let Some(children) = mgr.variables.get_mut(&parent_ref)
                        && let Some(child) = children.iter_mut().find(|v| v.name == name)
                    {
                        child.value = value.clone();
                        if ty.is_some() {
                            child.ty = ty;
                        }
                        if variables_ref != 0 {
                            child.variables_reference = variables_ref;
                        }
                    }
                    let short: String = value.chars().take(40).collect();
                    let ellipsis = if value.chars().count() > 40 {
                        "…"
                    } else {
                        ""
                    };
                    self.toast(format!("set {name} = {short}{ellipsis}"));
                }
                crate::dap::DapEvent::Evaluate {
                    expression,
                    value,
                    ty,
                    err,
                    variables_ref,
                } => {
                    // Watches and REPL evals share the same channel.
                    // The watch row always reflects the latest value
                    // (handy in REPL too — re-typing an expression
                    // is rare); REPL pane attaches the result to its
                    // pending history entry.
                    self.dap_watch_results.insert(
                        expression.clone(),
                        WatchResult {
                            value: value.clone(),
                            ty: ty.clone(),
                            err: err.clone(),
                        },
                    );
                    // Find the *most recent* pending REPL entry whose
                    // expression matches and fill it in. Matching by
                    // expression handles the typical "type expr, hit
                    // Enter" flow; if the user types two evals fast
                    // we still fill in arrival order.
                    for p in self.panes.iter_mut() {
                        if let Pane::DapRepl(repl) = p
                            && let Some(idx) = repl
                                .history
                                .iter()
                                .rposition(|e| e.pending && e.expression == expression)
                        {
                            let entry = &mut repl.history[idx];
                            entry.value = value.clone();
                            entry.ty = ty.clone();
                            entry.err = err.clone();
                            entry.pending = false;
                            entry.variables_ref = variables_ref;
                        }
                    }
                }
                crate::dap::DapEvent::Exited { exit_code } => {
                    self.toast(format!("dap: exited (code {exit_code})"));
                }
                crate::dap::DapEvent::Terminated => {
                    self.dap = None;
                    self.dap_arrow = None;
                    self.dap_thread = None;
                    self.toast("dap: session ended");
                    return;
                }
                crate::dap::DapEvent::Failed(msg) => {
                    self.toast(msg);
                }
            }
        }
    }

    /// Open the cheatsheet pane in a split below the active leaf. Builds
    /// it fresh each open (rebuilt against the current keymap so re-bound
    /// `dap.show` — open (or focus) the live debug pane (`Pane::Debug`).
    /// Shows the call stack + tailing output log. Independent of
    /// `dap.run`; safe to open before a session is live (just shows
    /// "no session").
    pub fn open_debug_pane(&mut self) {
        if let Some(id) = self.panes.iter().position(|p| matches!(p, Pane::Debug(_))) {
            self.reveal_pane(id);
            return;
        }
        let pane = Pane::Debug(crate::pane::DebugPane::default());
        match self.active {
            Some(cur) => {
                let new_id = self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                self.active = Some(new_id);
            }
            None => {
                self.panes.push(pane);
                let id = self.panes.len() - 1;
                *self.layout_mut() = crate::layout::Layout::Leaf(id);
                self.active = Some(id);
            }
        }
    }

    /// Move the debug pane's stack selection by `delta` (positive = down).
    pub fn debug_pane_move(&mut self, delta: isize) {
        let n = self.dap.as_ref().map(|m| m.stack_frames.len()).unwrap_or(0);
        if n == 0 {
            return;
        }
        let Some(id) = self.active else { return };
        let Some(Pane::Debug(p)) = self.panes.get_mut(id) else {
            return;
        };
        let new = (p.selected as isize + delta).clamp(0, n as isize - 1) as usize;
        p.selected = new;
        // Keep selection on screen — body_h isn't known here so we use
        // a simple scroll-to-include heuristic.
        if new < p.scroll {
            p.scroll = new;
        } else if new >= p.scroll + 20 {
            p.scroll = new - 19;
        }
    }

    /// Enter on a debug-pane stack-frame row — jump the active editor to
    /// that frame's source line. When the Variables sub-section is
    /// focused, Enter expands / collapses the highlighted variable
    /// instead.
    pub fn debug_pane_accept(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::Debug(p)) = self.panes.get(id) else {
            return;
        };
        match p.section {
            crate::pane::DebugSection::Stack => {
                let selected = p.selected;
                let frame_id = self
                    .dap
                    .as_ref()
                    .and_then(|m| m.stack_frames.get(selected).cloned());
                let Some(f) = frame_id else { return };
                // Stack-frame switch: re-fetch scopes for the picked
                // frame so the variables panel shows that frame's
                // locals (was showing the top frame's).
                if let Some(mgr) = self.dap.as_mut() {
                    mgr.scopes.clear();
                    let _ = mgr.client.scopes(f.id);
                }
                if let Some(src) = f.source {
                    let line0 = f.line.saturating_sub(1) as usize;
                    self.open_path(&src);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line0, 0);
                    }
                }
            }
            crate::pane::DebugSection::Variables => {
                self.debug_pane_toggle_var();
            }
        }
    }

    /// `y` in the debug pane's variables section — copy the selected
    /// row's value to the clipboard. For composite rows (no inlined
    /// value), copy the label instead so the user gets *something*.
    /// Scope-header rows copy their name (useful for "Locals" /
    /// "Globals" tagging in notes).
    pub fn debug_pane_yank_var(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::Debug(p)) = self.panes.get(id) else {
            return;
        };
        let sel = p.vars_selected;
        let rows = self
            .dap
            .as_ref()
            .map(|m| m.variable_rows())
            .unwrap_or_default();
        let Some(row) = rows.get(sel).cloned() else {
            return;
        };
        let payload = if !row.value.is_empty() {
            row.value.clone()
        } else {
            row.label.clone()
        };
        self.clipboard.set(&payload, false);
        let short: String = payload.chars().take(40).collect();
        let ellipsis = if payload.chars().count() > 40 {
            "…"
        } else {
            ""
        };
        self.toast(format!("yanked: {short}{ellipsis}"));
    }

    /// `w` in the debug pane's variables section — promote the
    /// selected variable's name into a watch expression. The watch
    /// list is App-wide (independent of which frame the var came from
    /// — adapters can re-evaluate any name in the current frame's
    /// scope). For row labels like `foo: i32` we strip the type
    /// suffix so the watch expression is just `foo`.
    pub fn debug_pane_watch_var(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::Debug(p)) = self.panes.get(id) else {
            return;
        };
        let sel = p.vars_selected;
        let rows = self
            .dap
            .as_ref()
            .map(|m| m.variable_rows())
            .unwrap_or_default();
        let Some(row) = rows.get(sel).cloned() else {
            return;
        };
        if row.is_scope {
            self.toast("can't watch a scope row");
            return;
        }
        // Strip ` : type` suffix if present — keep just the name.
        let name = row
            .label
            .split(" : ")
            .next()
            .unwrap_or(&row.label)
            .trim()
            .to_string();
        if name.is_empty() {
            return;
        }
        if self.dap_watches.iter().any(|w| w == &name) {
            self.toast(format!("watch: already tracking {name}"));
            return;
        }
        self.dap_watches.push(name.clone());
        // Fire immediate eval against the current top frame so the
        // watch row populates without waiting for the next stop.
        let frame_id = self
            .dap
            .as_ref()
            .and_then(|m| m.stack_frames.first().map(|f| f.id));
        if let (Some(mgr), Some(fid)) = (self.dap.as_mut(), frame_id) {
            let _ = mgr.client.evaluate(&name, Some(fid), "watch");
        }
        self.toast(format!("watch: + {name}"));
    }

    /// `s` in the debug pane's variables section — open a prompt
    /// seeded with the row's current value; accept ⇒ `setVariable`
    /// against `(parent_ref, name, new_value)`. Refuses on scope rows
    /// and unset rows. The reply lands as
    /// [`crate::dap::DapEvent::SetVariableDone`] and patches the
    /// cached child in place.
    pub fn debug_pane_set_var(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::Debug(p)) = self.panes.get(id) else {
            return;
        };
        let sel = p.vars_selected;
        let rows = self
            .dap
            .as_ref()
            .map(|m| m.variable_rows())
            .unwrap_or_default();
        let Some(row) = rows.get(sel).cloned() else {
            return;
        };
        if row.is_scope {
            self.toast("can't set a scope row");
            return;
        }
        if row.parent_ref == 0 {
            // Shouldn't happen for non-scope rows (variable_rows always
            // sets parent_ref for vars), but be defensive — without a
            // parent_ref the adapter can't route the request.
            self.toast("can't set this variable (no parent ref)");
            return;
        }
        // Strip ` : type` suffix if present — keep just the bare name.
        let name = row
            .label
            .split(" : ")
            .next()
            .unwrap_or(&row.label)
            .trim()
            .to_string();
        if name.is_empty() {
            return;
        }
        self.dap_pending_set_variable = Some((row.parent_ref, name.clone()));
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::DapSetVariable,
            format!("Set {name} ="),
            row.value.clone(),
        ));
    }

    /// Toggle expansion of the highlighted variable row. If it's
    /// expandable and we haven't fetched its children yet, fire the
    /// `variables` request; the reply lands in `mgr.variables[ref]`.
    pub fn debug_pane_toggle_var(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::Debug(p)) = self.panes.get(id) else {
            return;
        };
        let sel = p.vars_selected;
        let rows = self
            .dap
            .as_ref()
            .map(|m| m.variable_rows())
            .unwrap_or_default();
        let Some(row) = rows.get(sel).cloned() else {
            return;
        };
        if !row.expandable || row.var_ref == 0 {
            return;
        }
        let r = row.var_ref;
        let Some(mgr) = self.dap.as_mut() else { return };
        // Capture the path BEFORE mutating expanded_vars — the path
        // builder reads `variable_rows()` which observes the set.
        let path = mgr.path_for_var_ref(r);
        if mgr.expanded_vars.contains(&r) {
            mgr.expanded_vars.remove(&r);
            if let Some(p) = path {
                mgr.expanded_paths.remove(&p);
            }
        } else {
            mgr.expanded_vars.insert(r);
            if let Some(p) = path {
                mgr.expanded_paths.insert(p);
            }
            // Fetch children on first expand only — already-cached
            // refs (re-collapsed, re-opened) don't re-fire.
            if !mgr.variables.contains_key(&r) {
                let _ = mgr.client.variables(r);
            }
        }
    }

    /// Move the variables-panel selection by `delta`.
    pub fn debug_pane_vars_move(&mut self, delta: isize) {
        let n = self
            .dap
            .as_ref()
            .map(|m| m.variable_rows().len())
            .unwrap_or(0);
        if n == 0 {
            return;
        }
        let Some(id) = self.active else { return };
        let Some(Pane::Debug(p)) = self.panes.get_mut(id) else {
            return;
        };
        let new = (p.vars_selected as isize + delta).clamp(0, n as isize - 1) as usize;
        p.vars_selected = new;
        if new < p.vars_scroll {
            p.vars_scroll = new;
        } else if new >= p.vars_scroll + 20 {
            p.vars_scroll = new - 19;
        }
    }

    /// Tab in the debug pane — cycle keyboard focus between the call-
    /// stack list and the variables panel.
    pub fn debug_pane_toggle_section(&mut self) {
        let Some(id) = self.active else { return };
        let Some(Pane::Debug(p)) = self.panes.get_mut(id) else {
            return;
        };
        p.section = match p.section {
            crate::pane::DebugSection::Stack => crate::pane::DebugSection::Variables,
            crate::pane::DebugSection::Variables => crate::pane::DebugSection::Stack,
        };
    }
}
