//! Vim macros (`q<reg>...q`/`@<reg>`/`@@`), dot-repeat (`.`),
//! marks (`m<letter>`/`<letter>`/`` `<letter> ``), and the
//! edit-history jumplist (`g;`/`g,`).
//!
//! Sub-extracted from `app/editor_features.rs`. Non-destructive move.

use super::*;

impl App {
    /// `vim.macro_toggle` — `q` in vim normal. Idle ⇒ start recording into
    /// the conventional `'@'` register (or whatever `pending_macro_register`
    /// holds, set by the vim handler when the user typed `q<reg>` first).
    /// Recording ⇒ stop, save buffer (the trailing `q` is popped from the
    /// captured keys).
    pub fn macro_toggle(&mut self) {
        // If we're already recording, stop — ignore any new register hint
        // (the user just pressed `q` to stop, possibly via the prefix).
        if matches!(self.macro_state, MacroState::Recording { .. }) {
            self.pending_macro_register = None;
            return self.macro_toggle_stop();
        }
        let target = std::mem::take(&mut self.pending_macro_register).unwrap_or('@');
        match std::mem::take(&mut self.macro_state) {
            MacroState::Idle => {
                self.macro_state = MacroState::Recording {
                    register: target,
                    keys: Vec::new(),
                };
                if target == '@' {
                    self.toast("recording macro · q to stop");
                } else {
                    self.toast(format!("recording macro into \"{target} · q to stop"));
                }
            }
            MacroState::Recording { register, mut keys } => {
                // The `q` that triggered the stop got pushed by dispatch_key
                // before we ran. Pop it so replay doesn't re-trigger toggle.
                if let Some(last) = keys.last()
                    && last.code == ratatui::crossterm::event::KeyCode::Char('q')
                {
                    keys.pop();
                }
                let n = keys.len();
                self.macro_buffer.insert(register, keys);
                if register == '@' {
                    self.toast(format!("macro saved · {n} key(s)"));
                } else {
                    self.toast(format!("\"{register} saved · {n} key(s)"));
                }
            }
            MacroState::Replaying => {
                // Shouldn't normally happen — Replaying is set only inside
                // replay_macro. Reset to idle just in case.
                self.macro_state = MacroState::Idle;
            }
        }
    }

    /// `vim.macro_replay` — `@` in vim normal. Re-feed the saved macro
    /// keys through dispatch_key. Sets `macro_state = Replaying` so
    /// dispatch_key skips re-recording AND skips re-triggering replay
    /// when the macro contains another `@` (recursion guard). With a
    /// pending register letter (set by the vim handler when the user typed
    /// `@<reg>`), uses that register's macro; else replays `'@'`.
    pub fn macro_replay(&mut self) {
        // Vim `@@` semantics: repeat the LAST macro replay (whatever
        // register it was), not literally register `'@'`. When
        // `pending_macro_register` is `Some('@')`, redirect to
        // `last_replayed_macro_reg` if set. Otherwise the very first
        // `@@` before any `@<reg>` still falls back to the literal `@`
        // register (parity with unset last-replayed).
        // nvchad-round-7 SEV-2 2026-07-11.
        let raw_target = std::mem::take(&mut self.pending_macro_register).unwrap_or('@');
        let target = if raw_target == '@'
            && let Some(prev) = self.last_replayed_macro_reg
        {
            prev
        } else {
            raw_target
        };
        let Some(keys) = self.macro_buffer.get(&target).cloned() else {
            if target == '@' {
                self.toast("no macro to replay");
            } else {
                self.toast(format!("no macro in \"{target}"));
            }
            return;
        };
        // Persist for the next `@@`. Only remember explicit registers;
        // `@` itself is the sentinel.
        if target != '@' {
            self.last_replayed_macro_reg = Some(target);
        }
        if keys.is_empty() {
            self.toast("no macro to replay");
            return;
        }
        if matches!(self.macro_state, MacroState::Replaying) {
            return;
        }
        self.macro_state = MacroState::Replaying;
        for key in keys {
            crate::tui::dispatch_key(self, key);
        }
        self.macro_state = MacroState::Idle;
    }

    /// Set the next-up macro register (used by the vim `q<reg>` /
    /// `@<reg>` chord — the handler stashes the letter here before
    /// firing `vim.macro_toggle` / `vim.macro_replay`).
    pub fn set_pending_macro_register(&mut self, reg: char) {
        self.pending_macro_register = Some(reg);
    }

    /// vim `.` — re-feed the last recorded change through the
    /// dispatcher. Sets `is_replaying_dot = true` so the replay
    /// doesn't re-record itself or recurse on a nested `.` inside
    /// the captured sequence.
    pub fn dot_replay(&mut self) {
        if self.dot_keys.is_empty() {
            self.toast("nothing to repeat");
            return;
        }
        if self.is_replaying_dot {
            return;
        }
        // nvchad-user SEV-3 2026-07-10 fix: `3.` should replay the
        // last change three times. Count is armed by the vim `.`
        // handler before dispatching this command; consumed here.
        let n = self.pending_dot_count.take().unwrap_or(1).max(1);
        let keys = self.dot_keys.clone();
        self.is_replaying_dot = true;
        for _ in 0..n {
            for key in &keys {
                crate::tui::dispatch_key(self, *key);
            }
        }
        self.is_replaying_dot = false;
    }

    /// Stop recording — finalize the current macro into its register.
    /// Pulled out of [`Self::macro_toggle`] so the dispatch path can
    /// short-circuit without re-checking the (idle ⇒ start, recording ⇒
    /// stop) toggle.
    fn macro_toggle_stop(&mut self) {
        let MacroState::Recording { register, mut keys } = std::mem::take(&mut self.macro_state)
        else {
            return;
        };
        if let Some(last) = keys.last()
            && last.code == ratatui::crossterm::event::KeyCode::Char('q')
        {
            keys.pop();
        }
        let n = keys.len();
        self.macro_buffer.insert(register, keys);
        if register == '@' {
            self.toast(format!("macro saved · {n} key(s)"));
        } else {
            self.toast(format!("\"{register} saved · {n} key(s)"));
        }
    }

    /// Set mark `letter` to the active editor's cursor `(row, col)`.
    /// Lowercase letters are buffer-local (`Buffer.marks`); uppercase
    /// letters are global (`App.global_marks`, persisted in session.json).
    /// Bound to vim normal-mode `m<letter>` (via [`AppCommand::SetMark`]).
    /// `:delmarks a`, `:delmarks aBc`, `:delmarks!` — vim canonical
    /// delete-marks. Lowercase letters delete per-buffer marks;
    /// uppercase delete global marks. `!` (as the whole arg) means
    /// "all lowercase local marks + all buffer-scoped state". Emits
    /// a single toast summarising what was cleared.
    /// nvchad-round-7 SEV-3 2026-07-11.
    pub fn delete_marks(&mut self, spec: &str) {
        let spec = spec.trim();
        if spec.is_empty() {
            self.toast(":delmarks — usage: `:delmarks <letters>` or `:delmarks!`");
            return;
        }
        // `:delmarks!` — wipe every buffer's local marks.
        if spec == "!" {
            let mut count = 0usize;
            for pane in self.panes.iter_mut() {
                if let crate::pane::Pane::Editor(b) = pane {
                    count += b.marks.len();
                    b.marks.clear();
                }
            }
            self.toast(format!(":delmarks! — cleared {count} local mark(s)"));
            return;
        }
        // Parse spec: letters + `X-Y` ranges. Whitespace ignored.
        let mut targets: Vec<char> = Vec::new();
        let mut prev: Option<char> = None;
        let mut range_pending = false;
        for ch in spec.chars() {
            if ch.is_whitespace() {
                prev = None;
                range_pending = false;
                continue;
            }
            if ch == '-' && prev.is_some() {
                range_pending = true;
                continue;
            }
            if !ch.is_ascii_alphanumeric() {
                continue;
            }
            if range_pending && let Some(start) = prev {
                let (a, b) = if start <= ch {
                    (start, ch)
                } else {
                    (ch, start)
                };
                for c in (a as u32)..=(b as u32) {
                    if let Some(c) = char::from_u32(c) {
                        targets.push(c);
                    }
                }
                range_pending = false;
                prev = Some(ch);
                continue;
            }
            targets.push(ch);
            prev = Some(ch);
        }
        let mut local_removed = 0usize;
        let mut global_removed = 0usize;
        for c in &targets {
            if c.is_ascii_lowercase() || c.is_ascii_digit() {
                if let Some(b) = self.active_editor_mut()
                    && b.marks.remove(c).is_some()
                {
                    local_removed += 1;
                }
            } else if c.is_ascii_uppercase() && self.global_marks.remove(c).is_some() {
                global_removed += 1;
            }
        }
        self.toast(format!(
            ":delmarks — {local_removed} local, {global_removed} global"
        ));
    }

    pub fn set_mark_at_cursor(&mut self, letter: char) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let (row, col) = b.editor.row_col();
        if letter.is_ascii_uppercase() {
            let Some(path) = b.path.clone() else {
                self.toast("global marks need a saved file");
                return;
            };
            self.global_marks.insert(letter, (path, row, col));
            self.toast(format!("mark '{letter} set (global)"));
        } else if let Some(b) = self.active_editor_mut() {
            b.marks.insert(letter, (row, col));
            self.toast(format!("mark '{letter} set"));
        }
    }

    /// Jump to mark `letter`. Lowercase ⇒ within the active buffer.
    /// Uppercase ⇒ open the buffer the mark points at (if needed) and jump
    /// there. `exact` false (`'<letter>`) lands at column 0; `exact` true
    /// (`` `<letter>``) lands at the stored `(row, col)`. Pushes the current
    /// position onto the nav-back stack so `Alt+Left` returns.
    pub fn jump_to_mark(&mut self, letter: char, exact: bool) {
        let (target_path, row, col) = if letter.is_ascii_uppercase() {
            let Some((path, row, col)) = self.global_marks.get(&letter).cloned() else {
                self.toast(format!("no mark '{letter}"));
                return;
            };
            (Some(path), row, col)
        } else {
            let Some(b) = self.active_editor() else {
                self.toast("no active editor");
                return;
            };
            let Some(&(row, col)) = b.marks.get(&letter) else {
                self.toast(format!("no mark '{letter}"));
                return;
            };
            (None, row, col)
        };

        if let Some(here) = self.current_nav_point() {
            self.push_nav_back(here);
        }
        if let Some(path) = target_path
            && self
                .active_editor()
                .and_then(|b| b.path.clone())
                .is_none_or(|p| p != path)
        {
            self.open_path(&path);
        }
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let target_col = if exact { col } else { 0 };
        b.editor.place_cursor(row, target_col);
        self.toast(format!("→ '{letter} {}:{}", row + 1, target_col + 1));
    }

    /// `editor.jump_prev_edit` — vim `g;`. Walks back through the active
    /// buffer's change list (per-edit `(row, col)` history) and places the
    /// cursor there. Pushes the *current* position onto the nav-back stack
    /// so `Alt+Left` can return after the jump.
    pub fn jump_prev_edit(&mut self) {
        let here = self.current_nav_point();
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let Some((row, col)) = b.jump_prev_edit() else {
            self.toast("no earlier edit");
            return;
        };
        if let Some(np) = here {
            self.push_nav_back(np);
        }
        self.toast(format!("g; → {}:{}", row + 1, col + 1));
    }

    /// `editor.jump_next_edit` — vim `g,`. Mirror of [`Self::jump_prev_edit`].
    pub fn jump_next_edit(&mut self) {
        let here = self.current_nav_point();
        let Some(b) = self.active_editor_mut() else {
            return;
        };
        let Some((row, col)) = b.jump_next_edit() else {
            self.toast("at newest edit");
            return;
        };
        if let Some(np) = here {
            self.push_nav_back(np);
        }
        self.toast(format!("g, → {}:{}", row + 1, col + 1));
    }
}
