//! Pty-pane methods on `App` — clipboard copy/paste out of a live
//! terminal grid, restart, rename, external-tool launcher, install
//! confirm prompt, PTY tab bufferline management.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    /// Extract text from the Pty pane's render grid between two cell
    /// coords (col, row) and copy to the system clipboard. Uses
    /// row-major linear cell order — for multi-row selections, joins
    /// with `\n` at row boundaries. mouse-round-9 SEV-2 2026-07-11.
    pub fn copy_pty_selection_to_clipboard(
        &mut self,
        pane_id: PaneId,
        origin: (u16, u16),
        cur: (u16, u16),
    ) {
        let Some(Pane::Pty(session)) = self.panes.get_mut(pane_id) else {
            return;
        };
        let grid = session.render_grid(false);
        let (cols, rows) = (grid.cols, grid.rows);
        // Order origin/cur in row-major reading order.
        let (start, end) = {
            let a_idx = origin.1 as usize * cols as usize + origin.0 as usize;
            let b_idx = cur.1 as usize * cols as usize + cur.0 as usize;
            if a_idx <= b_idx {
                (origin, cur)
            } else {
                (cur, origin)
            }
        };
        let mut out = String::new();
        for r in start.1..=end.1 {
            if r >= rows {
                break;
            }
            let col_lo = if r == start.1 { start.0 } else { 0 };
            let col_hi = if r == end.1 { end.0 } else { cols - 1 };
            let mut row_text = String::new();
            for c in col_lo..=col_hi {
                if let Some(cell) = grid.cell(r, c) {
                    if cell.text.is_empty() {
                        row_text.push(' ');
                    } else {
                        row_text.push_str(&cell.text);
                    }
                }
            }
            // Trim trailing spaces per row so selections that cross
            // whitespace-padded rows don't paste with a huge tail.
            let trimmed = row_text.trim_end();
            out.push_str(trimmed);
            if r < end.1 {
                out.push('\n');
            }
        }
        if out.is_empty() {
            return;
        }
        self.clipboard.set(out, false);
        self.toast("pty: selection copied");
    }

    /// `term.paste` — paste the system clipboard into the active Pty
    /// pane's child process. No-op when the active pane isn't a Pty
    /// or the clipboard is empty. mouse-round-9 SEV-2 2026-07-11.
    pub fn pty_paste_clipboard(&mut self) {
        let Some(cur) = self.active else { return };
        if !matches!(self.panes.get(cur), Some(Pane::Pty(_))) {
            self.toast("term.paste — active pane is not a terminal");
            return;
        }
        let text = self.clipboard.text();
        if text.is_empty() {
            self.toast("term.paste — clipboard empty");
            return;
        }
        if let Some(Pane::Pty(s)) = self.panes.get_mut(cur) {
            s.write_bytes(text.as_bytes());
        }
    }

    /// `term.clear` — send Ctrl+L to the child (clears the screen in
    /// most shells / terminals). Same effect the user gets by typing
    /// Ctrl+L while the Pty is focused, but reachable from the
    /// right-click menu. mouse-round-9 SEV-2 2026-07-11.
    pub fn pty_send_ctrl_l(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Pty(s)) = self.panes.get_mut(cur) {
            s.write_bytes(&[0x0c]);
        } else {
            self.toast("term.clear — active pane is not a terminal");
        }
    }

    /// `term.restart` — restart the child process in the active Pty
    /// pane. Sends `SIGTERM` then re-spawns from the same profile.
    /// mouse-round-9 SEV-2 2026-07-11. TODO: proper respawn — for now
    /// send Ctrl+C and let the user re-run manually (safer than
    /// destroying the pty state).
    pub fn pty_restart(&mut self) {
        let Some(cur) = self.active else { return };
        if let Some(Pane::Pty(s)) = self.panes.get_mut(cur) {
            // Ctrl+C to interrupt, then Ctrl+D to signal EOF — most
            // shells re-launch under the launcher. Users who want a
            // full teardown can close the pane and re-open.
            s.write_bytes(&[0x03]);
            self.toast("term.restart — sent Ctrl+C (re-run manually)");
        } else {
            self.toast("term.restart — active pane is not a terminal");
        }
    }

    /// Accept handler for `PromptKind::PtySessionName`. Empty input
    /// clears the name (reverts to the binary profile's label).
    pub fn rename_active_pty(&mut self, name: &str) {
        let Some(cur) = self.active else { return };
        let name = name.trim();
        // Snapshot prefixes upfront so we don't hold a config borrow
        // while the pane is mutated below.
        let prefixes: Vec<String> = self.config.ui.ticket_prefixes.clone();
        if let Some(Pane::Pty(s)) = self.panes.get_mut(cur) {
            s.display_name = (!name.is_empty()).then(|| name.to_string());
            let label = s.tab_label_with_prefixes(&prefixes);
            self.toast(format!("session: {label}"));
        }
    }

    pub fn open_shell(&mut self) {
        // Spawn in the *active* workspace — so in a multi-workspace
        // setup, term.shell opens in the focused workspace's directory,
        // not the launch primary.
        //
        // 2026-07-22 — user asked for side-by-side (Horizontal) as
        // the default terminal placement to match Claude/Codex. Was
        // Vertical (stacked below). Explicit placement variants
        // (`term.shell_left/right/top/bottom`) let the right-click
        // menu override per gesture.
        let cwd = self.active_workspace_path().to_path_buf();
        self.open_pty_dir(
            crate::pty_pane::BinaryProfile::shell(Some(cwd)),
            crate::layout::SplitDir::Horizontal,
        );
    }

    /// Placement-aware variant of `open_shell` — used by the split-
    /// strip terminal chip's right-click menu so users can pick
    /// where a new shell lands (left / right / top / bottom half).
    pub fn open_shell_at(&mut self, placement: crate::app::ai::PanePlacement) {
        let cwd = self.active_workspace_path().to_path_buf();
        self.open_pty_at_placement(crate::pty_pane::BinaryProfile::shell(Some(cwd)), placement);
    }

    /// External-tool launcher — htop / iftop / btop / etc. If the
    /// binary is on PATH, opens it in a Pty pane; otherwise toasts
    /// a `brew install <pkg>` hint. Wired to `:tools.<id>` palette
    /// commands and to the integration_icon chips.
    pub fn run_external_tool(&mut self, id: &str) {
        let Some(tool) = crate::tools::EXTERNAL_TOOLS.iter().find(|t| t.id == id) else {
            self.toast(format!("tools: unknown tool `{id}`"));
            return;
        };
        if crate::tools::is_on_path(tool.binary) {
            let ws = self.active_workspace_path().to_path_buf();
            // qa-feature 2026-07-01 — tools that require root
            // (e.g. iftop needs /dev/bpf*) are launched under
            // `sudo` so the user gets a password prompt instead
            // of a permission-denied dump.
            // 2026-07-04 — `--preserve-env=TERM,TERMINFO_DIRS` so
            // the terminfo lookup path we set on the pty child
            // survives across sudo's env-scrub (default sudoers
            // whitelist doesn't include TERMINFO_DIRS, so iftop
            // otherwise dies with "Error opening terminal:
            // xterm-ghostty").
            let bin_with_args = match tool.id {
                // iftop's auto-picked interface is often `anpi2` on
                // macOS (Apple's secondary radio) which sees zero
                // traffic. Detect the default-route interface and
                // pass it explicitly.
                "iftop" => match crate::tools::default_route_iface() {
                    Some(iface) => format!("{} -i {}", tool.binary, iface),
                    None => tool.binary.to_string(),
                },
                _ => tool.binary.to_string(),
            };
            let cmdline = if tool.needs_sudo {
                format!("sudo --preserve-env=TERM,TERMINFO_DIRS {}", bin_with_args)
            } else {
                bin_with_args
            };
            // First-launch hint for sudo-needing tools — one-time
            // toast pointing at the docs page with the sudoers.d
            // one-liner so power users can skip the password prompt.
            // Marker at `~/.config/mnml/.tools-sudo-hint-shown` so it
            // only fires once across sessions. See docs/tools.md.
            if tool.needs_sudo {
                maybe_show_sudo_tools_hint(self);
            }
            // 2026-07-19 — was hardcoded "tools" as the pane tab
            // label. Use the tool's `id` for the label AND stamp
            // the integration_id so the tab-icon resolver reads
            // the chip glyph via a deterministic id lookup rather
            // than a fuzzy substring match on args/label.
            self.open_pty(
                crate::pty_pane::BinaryProfile::task(tool.id, &cmdline, ws)
                    .with_integration(tool.id),
            );
            return;
        }
        // Not installed. On macOS + Linux we offer to install via
        // brew / apt; elsewhere (Windows / unknown OS) we just
        // toast a hint since there's no single canonical package
        // manager + the `$SHELL -c` Pty spawn assumes POSIX.
        let install_cmd = crate::tools::install_hint(tool.brew_pkg, tool.apt_pkg);
        if !crate::tools::install_is_spawnable() {
            self.toast(format!(
                "{label}: not installed. Try `{install_cmd}`",
                label = tool.label
            ));
            return;
        }
        self.pending_tool_install = Some((tool.id.to_string(), install_cmd.clone()));
        let mut prompt = crate::prompt::Prompt::new(
            crate::prompt::PromptKind::ToolInstallConfirm,
            format!("Install {} via `{install_cmd}`?", tool.label),
        );
        // User invoked the tool that isn't installed — the affirmative
        // answer is the intent. Focus Install.
        prompt.cursor = 0;
        self.prompt = Some(prompt);
    }

    /// Accept handler for `PromptKind::ToolInstallConfirm` — fired
    /// from the picker accept path. If the user accepted with `y`,
    /// spawn the install command in a Pty pane.
    pub fn accept_tool_install(&mut self, input: String) {
        let Some((_id, install_cmd)) = self.pending_tool_install.take() else {
            return;
        };
        let accepted = input
            .trim()
            .chars()
            .next()
            .map(|c| c.eq_ignore_ascii_case(&'y'))
            .unwrap_or(false);
        if !accepted {
            return;
        }
        let ws = self.active_workspace_path().to_path_buf();
        self.open_pty(crate::pty_pane::BinaryProfile::task(
            "install",
            &install_cmd,
            ws,
        ));
    }

    /// Spawn a new pty session as a *tab* of the pty pane `strip_owner`
    /// — no split. The new session takes over `strip_owner`'s leaf;
    /// `strip_owner` becomes a background pane reachable via the tab
    /// strip. Backs the strip's `+` button.
    pub fn add_pty_tab(&mut self, strip_owner: PaneId, profile: crate::pty_pane::BinaryProfile) {
        match crate::pty_pane::PtySession::spawn(profile, 24, 80) {
            Ok(mut s) => {
                self.apply_saved_pty_name(&mut s);
                self.assign_auto_accent_color(&mut s);
                self.panes.push(Pane::Pty(s));
                let new_id = self.panes.len() - 1;
                // Re-point every leaf that shows `strip_owner` to the new
                // session — keeps it a single leaf with a tab strip.
                self.layout_mut().set_leaf_pane(strip_owner, new_id);
                self.active = Some(new_id);
                self.focus = crate::focus::Focus::Pane;
            }
            Err(e) => self.toast(format!("can't open session: {e}")),
        }
    }

    /// True if any pane is a pty (the event loop polls faster while one's open so
    /// streaming output stays smooth).
    pub fn has_pty_pane(&self) -> bool {
        self.panes.iter().any(|p| matches!(p, Pane::Pty(_)))
    }

    // ─── AI: `claude -p` one-shots ──────────────────────────────────
    /// Relay the user's `AiToolConfirm` answer to the blocked agent
    /// worker through its confirm channel.
    pub(crate) fn resolve_tool_confirm(&mut self, approved: bool) {
        if let Some(job_id) = self.pending_tool_confirm.take()
            && let Some(tx) = self.ai_confirm_senders.get(&job_id)
        {
            let _ = tx.send(approved);
        }
    }
}
