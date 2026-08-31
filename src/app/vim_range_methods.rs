//! Vim range-and-global command implementations — the `:1,5d` /
//! `:g/re/d` / `:norm` / `:retab` family, plus the linewise-yank
//! and linewise-operator (`d`, `y`, `>`, `<`, `J`) helpers they
//! share with the vim input layer.
//!
//! Extracted from `app/mod.rs` (file-split refactor — Task #963).
//! Pure non-destructive move; no API change.

use super::*;

impl App {
    /// `:sort [u]` — sort lines. With an active selection, sorts only those
    /// lines (full lines including any partial-line selection); without one,
    /// sorts the whole buffer. `unique` ⇒ de-dupe consecutive equal lines
    /// after sorting. Single edit op so undo restores the original order.
    /// `:1,5d` — delete lines `[start_line..=end_line]` (0-based, inclusive),
    /// yanking them into the unnamed register first (vim convention).
    /// Single edit op so undo restores.
    pub fn delete_lines(&mut self, start_line: usize, end_line: usize) {
        let Some(idx) = self.active else {
            self.toast(":d — no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            self.toast(":d — no active editor");
            return;
        };
        let text = b.editor.text();
        let line_count = b.editor.line_count();
        let end_line = end_line.min(line_count.saturating_sub(1));
        let start_line = start_line.min(end_line);
        let line_start =
            |row: usize| -> usize { text.split('\n').take(row).map(|s| s.len() + 1).sum() };
        let start = line_start(start_line);
        let end = if end_line + 1 >= line_count {
            text.len()
        } else {
            line_start(end_line + 1)
        };
        let n = end_line - start_line + 1;
        let yanked = text[start..end].to_string();
        self.clipboard.set(yanked, true);
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start,
                    end,
                    text: String::new(),
                }],
                &mut self.clipboard,
                0,
            );
        }
        self.toast(format!(":d {start_line}..{end_line} ({n} line(s))"));
    }

    /// `:1,5>` / `:1,5<` — indent / outdent the line range by one
    /// `[editor] tab_width` step. `indent=true` ⇒ `>`. Selects the
    /// range first, then runs the existing Indent/Outdent op.
    pub fn indent_lines_range(&mut self, start_line: usize, end_line: usize, indent: bool) {
        let Some(idx) = self.active else {
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        let line_count = b.editor.line_count();
        let end_line = end_line.min(line_count.saturating_sub(1));
        let start_line = start_line.min(end_line);
        // Place cursor at start of start_line, then SelectLine + extend
        // by (end - start) MoveDown's + MoveLineEnd. Operator emits
        // Indent/Outdent. nvchad-user SEV-2 2026-07-11 fix: without
        // the trailing MoveLineEnd the selection stopped at column 0
        // of end_line — Indent then applied to lines start..end_line-1
        // (off by one), so `:5,10>` indented 5 lines instead of 6.
        b.editor.place_cursor(start_line, 0);
        b.editor
            .apply(crate::edit_op::EditOp::SelectLine, 20, &mut self.clipboard);
        for _ in 0..(end_line - start_line) {
            b.editor
                .apply(crate::edit_op::EditOp::MoveDown, 20, &mut self.clipboard);
        }
        b.editor
            .apply(crate::edit_op::EditOp::MoveLineEnd, 20, &mut self.clipboard);
        let op = if indent {
            crate::edit_op::EditOp::Indent
        } else {
            crate::edit_op::EditOp::Outdent
        };
        b.editor.apply(op, 20, &mut self.clipboard);
        b.mark_edited();
        b.editor
            .apply(crate::edit_op::EditOp::SelectClear, 20, &mut self.clipboard);
        let arrow = if indent { ">" } else { "<" };
        self.toast(format!(":{arrow} {start_line}..{end_line}"));
    }

    /// `:1,5j` / `:1,5join` — join lines in `[start_line..=end_line]` into
    /// one line. Same trim+space-insert rules as the `J` op (vim
    /// canonical). No-op when range is a single line.
    pub fn join_lines_range(&mut self, start_line: usize, end_line: usize) {
        if end_line <= start_line {
            return;
        }
        let Some(idx) = self.active else {
            self.toast(":j — no active editor");
            return;
        };
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            // Place cursor on start_line, then fire J (end_line - start_line)
            // times to collapse the range upward.
            b.editor.place_cursor(start_line, 0);
            let count = end_line - start_line;
            for _ in 0..count {
                b.editor.apply(
                    crate::edit_op::EditOp::JoinLines { keep_space: true },
                    20,
                    &mut self.clipboard,
                );
                b.mark_edited();
            }
            self.toast(format!(":j {start_line}..{end_line}"));
        }
    }

    /// `:1,5y` — yank lines `[start_line..=end_line]` (0-based, inclusive)
    /// linewise into the unnamed register. Doesn't modify the buffer.
    pub fn yank_lines(&mut self, start_line: usize, end_line: usize) {
        let Some(b) = self.active_editor() else {
            self.toast(":y — no active editor");
            return;
        };
        let text = b.editor.text();
        let line_count = b.editor.line_count();
        let end_line = end_line.min(line_count.saturating_sub(1));
        let start_line = start_line.min(end_line);
        let line_start =
            |row: usize| -> usize { text.split('\n').take(row).map(|s| s.len() + 1).sum() };
        let start = line_start(start_line);
        let end = if end_line + 1 >= line_count {
            text.len()
        } else {
            line_start(end_line + 1)
        };
        let n = end_line - start_line + 1;
        let yanked = text[start..end].to_string();
        self.clipboard.set(yanked, true);
        self.toast(format!(":y {start_line}..{end_line} ({n} line(s))"));
    }

    /// nvchad-round-13 SEV-2 F3 2026-07-14 — vim `dG` / `dgg` /
    /// `d<n>G` (and y/c variants). Delete / yank / change the
    /// LINEWISE span from the cursor's current line to `target`.
    /// The input handler doesn't have access to line count or
    /// cursor position, so it fires an AppCommand and this method
    /// resolves the span here. `target` semantics:
    ///   * `None` → buffer end (`G` with no count).
    ///   * `Some(0)` → buffer start (`gg`).
    ///   * `Some(n)` → 1-based line `n` (`<n>G`).
    pub fn vim_operator_linewise_to(&mut self, op: char, target: Option<u32>) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let (cur_row, _) = b.editor.row_col();
        let line_count = b.editor.line_count();
        let target_row = match target {
            None => line_count.saturating_sub(1),
            Some(0) => 0usize,
            Some(n) => (n as usize)
                .saturating_sub(1)
                .min(line_count.saturating_sub(1)),
        };
        let (lo, hi) = if target_row < cur_row {
            (target_row, cur_row)
        } else {
            (cur_row, target_row)
        };
        match op {
            'd' => self.delete_lines(lo, hi),
            'y' => self.yank_lines(lo, hi),
            // `c` (change-to-G) needs an insert-mode transition; the
            // App layer doesn't own the vim handler's mode. Left
            // unsupported for now — `cG` is far less common than the
            // muscle-memory `dG` / `yG` pair this round targets.
            // Nvchad users can fall back to `dG` + `O`.
            _ => {}
        }
    }

    /// `:g/pattern/cmd` (or `:v/pattern/cmd` for invert) — run `<cmd>`
    /// on every line in the buffer whose text contains `<pattern>`
    /// (literal substring; vim's regex isn't wired). Lines visited
    /// top-to-bottom with cursor pre-placed at line start. Captures the
    /// matching rows up front so `<cmd>` operations that delete lines
    /// don't misalign the visit list.
    pub fn run_global_cmd(&mut self, spec: &str, invert: bool) {
        // spec = "<pattern>/<cmd>"
        let Some(slash) = spec.find('/') else {
            self.toast(":g — usage `g/pattern/cmd`");
            return;
        };
        let pattern = &spec[..slash];
        let cmd = &spec[slash + 1..];
        if pattern.is_empty() || cmd.is_empty() {
            self.toast(":g — pattern and cmd both required");
            return;
        }
        let Some(idx) = self.active else {
            self.toast(":g — no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            self.toast(":g — no active editor");
            return;
        };
        // Capture matching row indices (top-to-bottom). Pattern is a
        // vim regex — translate `\(…\)`/`\|`/`\<`/`\>` first, then
        // compile. Falls back to literal substring when the pattern
        // fails to compile as regex (so `:g/foo/` still works if
        // `foo` isn't a valid regex somehow). nvchad-round-8 SEV-2
        // 2026-07-11 — was literal substring only.
        let translated = crate::app::ex_commands::vim_pattern_to_regex_public(pattern);
        let re = regex::Regex::new(&translated).ok();
        let mut rows: Vec<usize> = Vec::new();
        for (i, line) in b.editor.text().split('\n').enumerate() {
            let matched = if let Some(re) = &re {
                re.is_match(line)
            } else {
                line.contains(pattern)
            };
            if matched != invert {
                rows.push(i);
            }
        }
        if rows.is_empty() {
            self.toast(format!(":g — no lines match {pattern:?}"));
            return;
        }
        let count = rows.len();
        // `:g/pat/p` — print each matching line to a toast + append
        // to the `message_log` (accessible via `:messages`). Vim
        // canonical shows matches in the command-line area; mnml's
        // toast queue is close enough for scan-through workflows.
        // nvchad-round-8 SEV-3 2026-07-11.
        let cmd_trimmed = cmd.trim();
        if cmd_trimmed == "p" || cmd_trimmed == "print" {
            let lines: Vec<String> = rows
                .iter()
                .filter_map(|&r| b.editor.text().split('\n').nth(r).map(|s| s.to_string()))
                .collect();
            for line in &lines {
                self.message_log.push(crate::app::LoggedMessage {
                    text: line.clone(),
                    level: crate::app::ToastLevel::Info,
                    at: crate::app::now_unix(),
                });
            }
            if self.message_log.len() > MESSAGE_LOG_MAX {
                let drop = self.message_log.len() - MESSAGE_LOG_MAX;
                self.message_log.drain(..drop);
            }
            // Toast the first line as a quick preview + a hint.
            let preview = lines.first().map(|s| s.as_str()).unwrap_or("");
            self.toast(format!(
                ":g/p — {count} line(s); first: {} · `:messages`",
                if preview.len() > 60 {
                    &preview[..60]
                } else {
                    preview
                }
            ));
            return;
        }
        let cmd = cmd.to_string();
        // Walk in reverse so `:d`-style line removals don't shift later
        // row indices.
        for row in rows.into_iter().rev() {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                if row >= b.editor.line_count() {
                    continue;
                }
                b.editor.place_cursor(row, 0);
            }
            self.run_ex_command(&cmd);
        }
        self.toast(format!(":g · ran on {count} line(s)"));
    }

    /// `:[%]norm <keys>` — for each line in the requested range, place
    /// the cursor at line start, then re-dispatch each char of `<keys>`
    /// through the active editor's vim handler. `whole=true` ⇒ whole
    /// buffer (`:%norm`); `whole=false` + selection ⇒ selection's
    /// lines; `whole=false` + no selection ⇒ current line. Idempotent:
    /// the loop walks 0-based line indices captured up front (so edits
    /// that add/remove lines don't repeat-fire the new lines).
    /// `:{start},{end}norm <keys>` — feed `<keys>` through the vim
    /// handler once per line in the range. nvchad-round-9 SEV-2
    /// 2026-07-11.
    pub fn run_norm_range(&mut self, keys: &str, start_line: usize, end_line: usize) {
        let keys = keys.trim();
        if keys.is_empty() {
            self.toast(":norm <keys>");
            return;
        }
        let Some(idx) = self.active else {
            return;
        };
        let key_events: Vec<ratatui::crossterm::event::KeyEvent> = keys
            .chars()
            .map(|c| {
                ratatui::crossterm::event::KeyEvent::new(
                    ratatui::crossterm::event::KeyCode::Char(c),
                    ratatui::crossterm::event::KeyModifiers::NONE,
                )
            })
            .collect();
        // nvchad-round-10 SEV-2 2026-07-11 — feed an implicit Esc
        // between iterations so a chord that entered Insert (e.g.
        // `Ihello`) doesn't leak into the next line. Mirrors
        // `run_norm`'s pattern.
        let esc = ratatui::crossterm::event::KeyEvent::new(
            ratatui::crossterm::event::KeyCode::Esc,
            ratatui::crossterm::event::KeyModifiers::NONE,
        );
        for row in start_line..=end_line {
            if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                if row >= b.editor.line_count() {
                    break;
                }
                b.editor.place_cursor(row, 0);
            }
            for key in &key_events {
                crate::tui::dispatch_key(self, *key);
            }
            crate::tui::dispatch_key(self, esc);
        }
        self.toast(format!(
            ":{start_line}..{end_line}norm — {} line(s)",
            end_line - start_line + 1
        ));
    }

    pub fn run_norm(&mut self, keys: &str, whole: bool) {
        let keys = keys.trim();
        if keys.is_empty() {
            self.toast(":norm <keys>");
            return;
        }
        let Some(idx) = self.active else {
            self.toast(":norm — no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            self.toast(":norm — no active editor");
            return;
        };
        let (start_line, end_line) = if whole {
            (0, b.editor.line_count().saturating_sub(1))
        } else if let Some((lo, hi)) = b.editor.selection() {
            let text = b.editor.text();
            let line_at = |byte: usize| text[..byte].bytes().filter(|&c| c == b'\n').count();
            (line_at(lo), line_at(hi))
        } else {
            let r = b.editor.row_col().0;
            (r, r)
        };
        // Pre-build the KeyEvents — same parser the e2e harness uses for
        // raw text, with simple Ctrl/Shift-modifier passthrough.
        let key_events: Vec<ratatui::crossterm::event::KeyEvent> = keys
            .chars()
            .map(|c| {
                ratatui::crossterm::event::KeyEvent::new(
                    ratatui::crossterm::event::KeyCode::Char(c),
                    ratatui::crossterm::event::KeyModifiers::NONE,
                )
            })
            .collect();
        for row in start_line..=end_line {
            // Re-check that the line still exists (edits may have shrunk
            // the buffer).
            if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                if row >= b.editor.line_count() {
                    break;
                }
                b.editor.place_cursor(row, 0);
            }
            for key in &key_events {
                crate::tui::dispatch_key(self, *key);
            }
            // Each line's chord may have entered Insert; force Normal back
            // so the next line's keystrokes are interpreted right. We do
            // this by feeding Esc (no-op if already Normal).
            let esc = ratatui::crossterm::event::KeyEvent::new(
                ratatui::crossterm::event::KeyCode::Esc,
                ratatui::crossterm::event::KeyModifiers::NONE,
            );
            crate::tui::dispatch_key(self, esc);
        }
        let count = end_line.saturating_sub(start_line) + 1;
        self.toast(format!(":norm · ran on {count} line(s)"));
    }

    /// `:retab` (`reverse=false`) ⇒ tabs → N spaces. `:retab!`
    /// (`reverse=true`) ⇒ leading runs of N spaces (per line) → tabs.
    /// `N = [editor] tab_width`. Single edit op so undo restores.
    pub fn run_retab(&mut self, reverse: bool) {
        let tab_w = self.config.editor.tab_width.max(1);
        let Some(b) = self.active_editor_mut() else {
            self.toast("no active editor");
            return;
        };
        let text = b.editor.text();
        let new_text = if reverse {
            // Per-line: collapse leading runs of `tab_w` spaces into a tab.
            let pad: String = " ".repeat(tab_w);
            let mut out = String::with_capacity(text.len());
            for (i, line) in text.split('\n').enumerate() {
                if i > 0 {
                    out.push('\n');
                }
                let mut rest = line;
                while let Some(stripped) = rest.strip_prefix(&pad as &str) {
                    out.push('\t');
                    rest = stripped;
                }
                out.push_str(rest);
            }
            out
        } else {
            if !text.contains('\t') {
                return;
            }
            text.replace('\t', &" ".repeat(tab_w))
        };
        if new_text == text {
            return;
        }
        let end = text.len();
        let ops = vec![crate::edit_op::EditOp::ReplaceRange {
            start: 0,
            end,
            text: new_text,
        }];
        let mut clip = crate::clipboard::Clipboard::new();
        b.apply_edit_ops(ops, &mut clip, 0);
        if reverse {
            self.toast(format!(":retab! — leading {tab_w}-space runs → tabs"));
        } else {
            self.toast(format!(":retab — tabs → {tab_w} spaces"));
        }
    }
}
