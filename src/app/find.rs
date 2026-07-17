//! Find / replace / multi-cursor word-pick / keyword completion.
//!
//! Find in the active buffer (vim `/`, `*`, `#`, `n`, `N`, etc.),
//! literal + regex replace, find-history walk, smart-case toggle,
//! visual-mode find-selection, multi-cursor `Ctrl+D` shape.
//!
//! Sub-extracted from `app/editor_features.rs`. Non-destructive move.

use super::*;

impl App {
    /// vim `*` / `#` — search forward / backward for the identifier under
    /// the cursor. Sets the find state to that word and jumps. Toasts if
    /// the cursor isn't on an identifier.
    pub fn find_word_under_cursor(&mut self, forward: bool) {
        let Some(cur) = self.active else {
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(cur) else {
            return;
        };
        let word = b.editor.word_under_cursor().to_string();
        if word.is_empty() {
            self.toast("no word under cursor");
            return;
        }
        // `accept_find` sets the state + jumps to the first match at-or-after
        // the cursor — which IS the word under cursor (its start byte is
        // <= cursor). Vim's `*` / `#` semantic is "go to NEXT occurrence";
        // sitting on the current match doesn't help. Advance one step in
        // the requested direction. nvchad-user SEV-3 S3-05 fix:
        // `*` doesn't advance cursor to the next match (statusline shows
        // search registered; cursor stays put).
        self.accept_find(word);
        if forward {
            self.find_next();
        } else {
            self.find_prev();
        }
    }

    /// `find.selection_forward` / `find.selection_backward` — vim's visual
    /// `*` / `#`: search for the literally-selected text (preserves spaces /
    /// punctuation, no word-boundary check). Falls back to a toast when
    /// there's no active selection.
    pub fn find_selection_under_cursor(&mut self, forward: bool) {
        let Some(cur) = self.active else {
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(cur) else {
            return;
        };
        let sel = b.editor.selected_text();
        if sel.is_empty() {
            self.toast("no selection");
            return;
        }
        // Selections may span newlines; the find layer matches literally so
        // multi-line selections work too (the highlight just spans rows).
        self.accept_find(sel.to_string());
        if !forward {
            self.find_prev();
        }
    }

    /// vim insert `Ctrl+N` / `Ctrl+P` — keyword completion. Scans the
    /// active buffer for words matching the prefix-before-cursor and
    /// opens the same completion popup we use for LSP. Direction
    /// (forward/backward through the matches) is set via initial
    /// selection.
    pub fn keyword_complete(&mut self, _backward: bool) {
        let Some(idx) = self.active else {
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            return;
        };
        let cur = b.editor.cursor();
        let text = b.editor.text();
        // Compute identifier prefix immediately left of cursor.
        let mut start = cur;
        while start > 0 {
            let prev = match text[..start].chars().next_back() {
                Some(c) => c,
                None => break,
            };
            if !(prev.is_alphanumeric() || prev == '_') {
                break;
            }
            start -= prev.len_utf8();
        }
        let prefix = text[start..cur].to_string();
        if prefix.is_empty() {
            return;
        }
        // Scan for matching identifiers (word boundary). Dedup, cap at 200.
        let mut matches: Vec<String> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let bytes = text.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            // Skip non-identifier chars.
            let next = match text[i..].chars().next() {
                Some(c) => c,
                None => break,
            };
            if !(next.is_alphanumeric() || next == '_') {
                i += next.len_utf8();
                continue;
            }
            // Capture identifier.
            let s = i;
            let mut j = i;
            while j < bytes.len() {
                let c = match text[j..].chars().next() {
                    Some(c) => c,
                    None => break,
                };
                if !(c.is_alphanumeric() || c == '_') {
                    break;
                }
                j += c.len_utf8();
            }
            let word = &text[s..j];
            if word != prefix && word.starts_with(&prefix) && seen.insert(word.to_string()) {
                matches.push(word.to_string());
                if matches.len() >= 200 {
                    break;
                }
            }
            i = j;
        }
        if matches.is_empty() {
            self.toast(format!("no keyword matches for {prefix:?}"));
            return;
        }
        let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
            return;
        };
        let items: Vec<crate::completion::CompletionItem> = matches
            .into_iter()
            .map(|m| crate::completion::CompletionItem {
                label: m.clone(),
                insert: m,
                detail: "buffer".to_string(),
                documentation: String::new(),
                raw: None,
                resolved: true,
                is_snippet: false,
                kind: 1, // Text — buffer-keyword matches aren't structural
            })
            .collect();
        let popup = crate::completion::CompletionPopup::new(path, items, &prefix);
        if !popup.is_empty() {
            self.completion = Some(popup);
        }
    }

    /// Insert-mode `Ctrl+R <reg>` for vim's special registers:
    /// - `%` = current buffer's workspace-relative path
    /// - `#` = alt buffer's workspace-relative path (MRU[1])
    /// - `/` = last search query on the active buffer
    /// - `:` = last executed ex-command
    /// - `.` = the last inserted text (extracted from `dot_keys`
    ///   by keeping only the printable `Char(c)` events — good
    ///   enough for the common case of typing a word/phrase; motion
    ///   / escape / backspace events are dropped)
    /// nvchad-round-7 + round-9 SEV-3 2026-07-11.
    pub fn insert_special_register(&mut self, reg: char) {
        let text = match reg {
            '%' => self
                .active_editor()
                .and_then(|b| b.path.as_ref())
                .map(|p| crate::app::rel_path(&self.workspace, p))
                .unwrap_or_default(),
            '#' => {
                // MRU[0] is the current pane; MRU[1] is the alt.
                let alt = self.pane_mru.get(1).copied();
                alt.and_then(|pid| match self.panes.get(pid) {
                    Some(Pane::Editor(b)) => b.path.as_ref(),
                    _ => None,
                })
                .map(|p| crate::app::rel_path(&self.workspace, p))
                .unwrap_or_default()
            }
            '/' => self
                .active_editor()
                .and_then(|b| b.find.as_ref())
                .map(|f| f.query.clone())
                .unwrap_or_default(),
            ':' => self.ex_history.last().cloned().unwrap_or_default(),
            '.' => {
                // Best-effort: keep only Char(c) events. Insert-mode
                // typing lands here as `Char('c')` per key; escape /
                // motion / count / operator keys are skipped.
                let mut s = String::new();
                for key in &self.dot_keys {
                    if let ratatui::crossterm::event::KeyCode::Char(c) = key.code
                        && !key
                            .modifiers
                            .contains(ratatui::crossterm::event::KeyModifiers::CONTROL)
                        && !key
                            .modifiers
                            .contains(ratatui::crossterm::event::KeyModifiers::ALT)
                    {
                        s.push(c);
                    }
                }
                // Strip a leading operator letter (i/a/o/O/A/I/s/S/c)
                // that opens Insert. The dot_keys sequence always
                // starts with one of these for an insert-run change.
                if let Some(first) = s.chars().next()
                    && matches!(first, 'i' | 'a' | 'o' | 'O' | 'A' | 'I' | 's' | 'S' | 'c')
                {
                    s.remove(0);
                }
                s
            }
            _ => String::new(),
        };
        if text.is_empty() {
            self.toast(format!("Ctrl+R \"{reg} — empty"));
            return;
        }
        let Some(idx) = self.active else { return };
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let cur = b.editor.cursor();
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start: cur,
                    end: cur,
                    text,
                }],
                &mut self.clipboard,
                0,
            );
        }
    }

    /// vim `Ctrl+R Ctrl+W` (insert) — insert the identifier under the
    /// cursor at the cursor position.
    pub fn insert_word_under_cursor(&mut self) {
        let Some(idx) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            return;
        };
        let word = b.editor.word_under_cursor().to_string();
        if word.is_empty() {
            return;
        }
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let cur = b.editor.cursor();
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start: cur,
                    end: cur,
                    text: word,
                }],
                &mut self.clipboard,
                0,
            );
        }
    }

    /// vim `Ctrl+R Ctrl+A` (insert) — like `Ctrl+R Ctrl+W` but uses
    /// vim's "WORD" definition (whitespace-delimited; punctuation kept).
    pub fn insert_bigword_under_cursor(&mut self) {
        let Some(idx) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            return;
        };
        let text = b.editor.text();
        let cur = b.editor.cursor();
        let bytes = text.as_bytes();
        let mut s = cur;
        while s > 0 {
            let prev = match text[..s].chars().next_back() {
                Some(c) => c,
                None => break,
            };
            if prev.is_whitespace() {
                break;
            }
            s -= prev.len_utf8();
        }
        let mut e = cur;
        while e < bytes.len() {
            let ch = match text[e..].chars().next() {
                Some(c) => c,
                None => break,
            };
            if ch.is_whitespace() {
                break;
            }
            e += ch.len_utf8();
        }
        if s == e {
            return;
        }
        let word = text[s..e].to_string();
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start: cur,
                    end: cur,
                    text: word,
                }],
                &mut self.clipboard,
                0,
            );
        }
    }

    /// `editor.select_all_occurrences` (VS Code `Ctrl+Shift+L`) — drop a
    /// cursor at every whole-word occurrence of the identifier under the
    /// primary cursor. Primary cursor lands at the first occurrence;
    /// extras take the rest. No-op when the cursor isn't on an identifier.
    pub fn select_all_occurrences(&mut self) {
        let Some(idx) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        let word = b.editor.word_under_cursor().to_string();
        if word.is_empty() {
            self.toast("not on an identifier");
            return;
        }
        let hits = crate::editor::find_whole_word_occurrences(b.editor.text(), &word);
        if hits.is_empty() {
            return;
        }
        b.editor.clear_extra_cursors();
        let (first_s, first_e) = hits[0];
        b.editor.set_selection(first_s, first_e);
        // keyboard-round-10 SEV-2 F2 2026-07-14 — was
        // `add_extra_cursor(*s)`, which discarded each hit's end
        // and stored anchor==cursor (zero-length selection). Typing
        // then INSERTED at each extra instead of REPLACING the
        // word, yielding `COUNTcount` at every extra hit. Use the
        // selection-aware helper so all N cursors span the same
        // word range.
        for (s, e) in hits.iter().skip(1) {
            b.editor.add_extra_cursor_with_anchor(*s, *e);
        }
        if hits.len() > 1 {
            self.toast(format!("selected {} occurrences", hits.len()));
        }
    }

    /// `find.find` (`Ctrl+F`) — prompt for a search string. Seeded with the
    /// active editor's selection if any, else its current find query.
    /// `find.find_backward` (vim `?`) — same as `find.find`, but flag the
    /// next `accept_find` to land on the closest match BEFORE the cursor.
    /// `n` / `N` after still walk forward/back; only the initial jump
    /// differs.
    pub fn open_find_prompt_backward(&mut self) {
        self.find_pending_reverse = true;
        self.open_find_prompt();
    }

    pub fn open_find_prompt(&mut self) {
        let Some(cur) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get(cur) else {
            self.toast("find only works in editor panes");
            return;
        };
        // Treat a multi-line selection as a scope: search only within it,
        // and don't seed the query with the (potentially huge) selection
        // text. Single-line selection keeps the existing seed-as-query
        // behavior.
        let multi_line_sel = b.editor.selection().and_then(|(lo, hi)| {
            let text = b.editor.text();
            let crosses_newline = text.get(lo..hi).is_some_and(|s| s.contains('\n'));
            if crosses_newline {
                Some((lo, hi))
            } else {
                None
            }
        });
        // Seed priority:
        //   1. Multi-line selection ⇒ blank (don't dump selection).
        //   2. Single-line selection ⇒ the selected text.
        //   3. Otherwise BLANK. Vim convention: `/` opens an empty
        //      prompt; `n` / `N` repeat the last search. mnml used
        //      to seed from the buffer's prior query, which meant a
        //      second `/` re-opened with the previous text and any
        //      new chars APPENDED — "five" then "/" then "eight"
        //      typed `fiveeight`. 2026-06-13 nvchad-user SEV-1 fix.
        let seed = if multi_line_sel.is_some() {
            String::new()
        } else if b.editor.has_selection() {
            b.editor.selected_text().to_string()
        } else {
            String::new()
        };
        let seed = seed.lines().next().unwrap_or("").to_string();
        self.find_preview_snapshot = Some(b.find.clone());
        self.find_preview_cursor = b.editor.cursor();
        self.find_history_cursor = self.find_history.len();
        // Stash the multi-line selection range so `accept_find` /
        // `update_live_find_preview` can scope matches to it. Cleared on
        // any new find prompt open.
        self.find_pending_range = multi_line_sel;
        let title = if multi_line_sel.is_some() {
            "Find (in selection)"
        } else {
            "Find"
        };
        self.prompt = Some(crate::prompt::Prompt::seeded(
            crate::prompt::PromptKind::Find,
            title,
            seed,
        ));
    }

    /// Replace the Find prompt's input with the previous history entry
    /// (Up arrow on the prompt). No-op when there's no older entry.
    pub fn find_history_prev(&mut self) {
        if self.find_history_cursor == 0 || self.find_history.is_empty() {
            return;
        }
        self.find_history_cursor -= 1;
        let q = self.find_history[self.find_history_cursor].clone();
        if let Some(p) = self.prompt.as_mut() {
            p.input = q.clone();
            p.cursor = p.input.len();
        }
        self.update_live_find_preview(q);
    }

    /// Down arrow on the Find prompt — newer entry, or back to an empty
    /// live input when past the newest.
    pub fn find_history_next(&mut self) {
        if self.find_history_cursor >= self.find_history.len() {
            return;
        }
        self.find_history_cursor += 1;
        let q = if self.find_history_cursor >= self.find_history.len() {
            String::new()
        } else {
            self.find_history[self.find_history_cursor].clone()
        };
        if let Some(p) = self.prompt.as_mut() {
            p.input = q.clone();
            p.cursor = p.input.len();
        }
        self.update_live_find_preview(q);
    }

    /// Update the active editor's find state to reflect the in-flight find
    /// prompt's query so the user sees matches as they type. Cursor isn't
    /// moved — just the highlight set + match index. Empty query clears.
    pub fn update_live_find_preview(&mut self, query: String) {
        // Vim mode: force regex-default so live preview matches the
        // eventual accept_find behavior. nvchad round 3 2026-07-11
        // follow-up — `:%s` was already regex, but `/pattern`'s live
        // preview seeded `regex = false` (bug entered via the
        // prev-find persistence path), so `foo.bar` typed into the
        // Find prompt showed "no matches" even though accept-time
        // would have used regex.
        let is_vim = crate::input::is_vim_style(&self.config);
        let regex_default = self.find_regex_default || is_vim;
        let case_mode = self.search_case_mode;
        let pending_range = self.find_pending_range;
        let Some(cur) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(cur) else {
            return;
        };
        if query.is_empty() {
            b.find = None;
            return;
        }
        let regex = b.find.as_ref().map(|f| f.regex).unwrap_or(regex_default);
        // Same vim-grammar translation as `accept_find` so the live
        // preview matches what Enter will land on. nvchad-round-8
        // SEV-2 2026-07-11.
        let query = if regex && is_vim {
            crate::app::ex_commands::vim_pattern_to_regex_public(&query)
        } else {
            query
        };
        // Case rule: `search_case_mode` overrides smart-case (vim's
        // `:set ic` / `:set noic` / `:set smartcase`). None →
        // historical smart-case default (case-sensitive iff query has
        // an uppercase letter). Only meaningful for literal mode
        // (regex carries its own `(?i)`).
        let case_sensitive = if regex {
            false
        } else {
            match case_mode {
                Some(mode) => mode,
                None => query.chars().any(|c| c.is_uppercase()),
            }
        };
        let mut state = crate::buffer::FindState {
            query,
            regex,
            case_sensitive,
            range: pending_range,
            ..Default::default()
        };
        state.recompute(b.editor.text());
        // Pick the nearest match at or after the cursor (or 0 if none — UI
        // will just show no current).
        if !state.matches.is_empty() {
            let cur_byte = b.editor.cursor();
            let idx = state
                .matches
                .iter()
                .position(|(s, _)| *s >= cur_byte)
                .unwrap_or(0);
            state.current = Some(idx);
        }
        b.find = Some(state);
    }

    /// Discard the live preview and restore the prior find state (from
    /// [`Self::open_find_prompt`]'s snapshot). Called on Esc-cancel of the
    /// Find prompt; Enter-accept leaves the live state in place + the
    /// snapshot is dropped.
    pub fn restore_find_preview_snapshot(&mut self) {
        let snap = self.find_preview_snapshot.take();
        self.find_preview_cursor = 0;
        let Some(prior) = snap else { return };
        let Some(cur) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(cur) else {
            return;
        };
        b.find = prior;
    }

    /// Set the active editor's find state to `query` and jump to the nearest
    /// match at-or-after the cursor (wraps).
    pub fn accept_find(&mut self, query: String) {
        // Remember the query in history (de-duped against the most recent
        // entry, capped at FIND_HISTORY_MAX). Done first so even queries
        // that miss are recallable via Up.
        if !query.is_empty() && self.find_history.last() != Some(&query) {
            self.find_history.push(query.clone());
            if self.find_history.len() > FIND_HISTORY_MAX {
                let drop = self.find_history.len() - FIND_HISTORY_MAX;
                self.find_history.drain(..drop);
            }
        }
        self.find_history_cursor = self.find_history.len();
        // Consume the in-flight scope range — accept_find is one-shot.
        let pending_range = self.find_pending_range.take();
        let regex_default = self.find_regex_default;
        let case_mode = self.search_case_mode;
        let Some(cur) = self.active else { return };
        let Some(Pane::Editor(b)) = self.panes.get_mut(cur) else {
            return;
        };
        if query.is_empty() {
            b.find = None;
            return;
        }
        // Preserve the existing find's regex flag if any, else use the App
        // default so the toggle is sticky. Vim mode overrides the default
        // to `true` — vim's `/pattern` and `?pattern` are regex-first;
        // literal chars are the special case that require escaping.
        // nvchad-user SEV-2 2026-07-10 fix (previously literal-only for
        // both search and :%s/…/…/g).
        let is_vim = crate::input::is_vim_style(&self.config);
        let regex_default = regex_default || is_vim;
        let regex = b.find.as_ref().map(|f| f.regex).unwrap_or(regex_default);
        // nvchad-round-8 SEV-2 2026-07-11 — translate vim regex
        // metachars (`\(…\)`, `\|`, `\<`/`\>`) to the `regex` crate's
        // grammar for the search prompt too. Round-7 wired this only
        // in `:s`, so `/foo\|bar` still failed on the search prompt.
        let query = if regex && is_vim {
            crate::app::ex_commands::vim_pattern_to_regex_public(&query)
        } else {
            query
        };
        // Same case-mode rule as `update_live_find_preview` — vim's
        // `:set ic` / `:set noic` override smart-case for both literal
        // and regex modes. Regex-and-no-override falls back to
        // case-insensitive (nvchad convention: `/foo` matches any
        // case; escape with `\C` for case-sensitive in a single
        // search — that inline flag isn't wired yet).
        let case_sensitive = match case_mode {
            Some(mode) => mode,
            None => !regex && query.chars().any(|c| c.is_uppercase()),
        };
        let mut state = crate::buffer::FindState {
            query: query.clone(),
            regex,
            case_sensitive,
            range: pending_range,
            ..Default::default()
        };
        state.recompute(b.editor.text());
        if state.matches.is_empty() {
            b.find = Some(state);
            self.toast(format!(
                "no {}matches for {query:?}",
                if regex { "regex " } else { "" }
            ));
            return;
        }
        // Direction: forward (vim `/`) lands on the first match at-or-after
        // the cursor; backward (vim `?`) on the closest before. Both wrap.
        let reverse = std::mem::take(&mut self.find_pending_reverse);
        let cur_byte = b.editor.cursor();
        let idx = if reverse {
            state
                .matches
                .iter()
                .rposition(|(s, _)| *s < cur_byte)
                .unwrap_or(state.matches.len() - 1)
        } else {
            state
                .matches
                .iter()
                .position(|(s, _)| *s >= cur_byte)
                .unwrap_or(0)
        };
        state.current = Some(idx);
        let (start, _end) = state.matches[idx];
        let total = state.matches.len();
        b.find = Some(state);
        self.place_cursor_at_byte(cur, start);
        self.toast(format!("match {}/{total}", idx + 1));
    }

    /// `find.next` (`F3`) — advance to the next find match (wraps).
    pub fn find_next(&mut self) {
        self.step_find(1);
    }

    /// `find.prev` (`Shift+F3`) — step to the previous find match (wraps).
    pub fn find_prev(&mut self) {
        self.step_find(-1);
    }

    /// `find.replace` (`Ctrl+H`) — prompt for replacement text (requires a
    /// non-empty find state on the active buffer). Enter ⇒ `accept_replace`
    /// splices the replacement over every match.
    pub fn open_replace_prompt(&mut self) {
        let Some(cur) = self.active else { return };
        let q = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => b.find.as_ref().map(|f| (f.query.clone(), f.matches.len())),
            _ => None,
        };
        match q {
            Some((query, n)) if n > 0 => {
                let title = format!("Replace {n}× {query:?} with");
                self.prompt = Some(crate::prompt::Prompt::new(
                    crate::prompt::PromptKind::Replace,
                    title,
                ));
            }
            Some(_) => self.toast("no matches to replace — refine the find query"),
            None => {
                // vscode-user-keyboard SEV-2 2026-07-11: Ctrl+H with
                // no active find used to open a plain Find prompt and
                // toast "type a find pattern, then Ctrl+H to replace" —
                // two chords for what VS Code does in one. Now open a
                // Find prompt marked `chain_to_replace = true`, so the
                // accept-find path in `accept_find` auto-opens the
                // Replace prompt as soon as the query yields matches.
                // Prior behavior of "Ctrl+H mid-Find opens Replace"
                // (see tui/handlers/overlay.rs) still works — the chain
                // flag just makes Enter do the same thing.
                self.open_find_prompt();
                if crate::input::is_vim_style(&self.config) {
                    // In vim mode Ctrl+H is INSERT-backspace, not the
                    // replace chord. Show the ex-command path.
                    self.toast(":%s/old/new/g — substitute across buffer");
                } else if let Some(p) = self.prompt.as_mut() {
                    p.chain_to_replace = true;
                    p.title = "Find (Enter → Replace)".to_string();
                }
            }
        }
    }

    /// Splice `replacement` over every find match in the active buffer (in
    /// reverse order, so earlier offsets stay valid). Toasts the count.
    pub fn accept_replace(&mut self, replacement: String) {
        let Some(cur) = self.active else { return };
        let ops: Vec<crate::edit_op::EditOp> = match self.panes.get(cur) {
            Some(Pane::Editor(b)) => match &b.find {
                Some(f) if !f.matches.is_empty() => f
                    .matches
                    .iter()
                    .rev()
                    .map(|(s, e)| crate::edit_op::EditOp::ReplaceRange {
                        start: *s,
                        end: *e,
                        text: replacement.clone(),
                    })
                    .collect(),
                _ => {
                    self.toast("no matches to replace");
                    return;
                }
            },
            _ => return,
        };
        let n = ops.len();
        let clip = &mut self.clipboard;
        // keyboard-round-14 SEV-3 #12 2026-07-17 — replace-all
        // used to emit N individual `ReplaceRange` ops through
        // apply_edit_ops, each pushing its own undo checkpoint.
        // User needed N Ctrl+Z presses to fully revert. Wrap in
        // atomic_undo (matches `:%s/.../.../g`'s pattern) so ONE
        // press undoes the whole run.
        let path = if let Some(Pane::Editor(b)) = self.panes.get_mut(cur) {
            b.editor.atomic_undo(|editor| {
                for op in ops {
                    editor.apply(op, 0, clip);
                }
            });
            b.recompute_dirty();
            b.refresh_highlights();
            b.path.clone()
        } else {
            None
        };
        if let Some(p) = path {
            // Same as a normal edit — push the change to the LSP server.
            if let Some(Pane::Editor(b)) = self.panes.get(cur) {
                let t = b.editor.text().to_string();
                self.lsp.did_change(&p, &t);
            }
        }
        self.toast(format!("replaced {n}"));
    }

    /// vim `gn` / `gN` — select the next / previous match of the active
    /// find pattern. Forward picks the first match strictly after the cursor
    /// (wraps to first); backward picks the last match strictly before the
    /// cursor (wraps to last). Sets editor anchor + cursor so the selection
    /// shows up; the user can then `c` / `d` over it via the visual
    /// charwise path (mnml's vim handler keeps mode in Normal — selection
    /// renders regardless of handler mode). Toasts on misses.
    pub fn select_find_match(&mut self, forward: bool) {
        let Some(idx) = self.active else {
            self.toast("gn — no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            self.toast("gn — no active editor");
            return;
        };
        let Some(find) = b.find.as_ref() else {
            self.toast("gn — no active find (use / first)");
            return;
        };
        if find.matches.is_empty() {
            self.toast("gn — no matches");
            return;
        }
        let cur = b.editor.cursor();
        let pick = if forward {
            find.matches
                .iter()
                .find(|(s, _)| *s > cur)
                .copied()
                .unwrap_or(find.matches[0])
        } else {
            find.matches
                .iter()
                .rev()
                .find(|(_, e)| *e <= cur)
                .copied()
                .unwrap_or_else(|| *find.matches.last().unwrap())
        };
        b.editor.set_selection(pick.0, pick.1);
        let arrow = if forward { "→" } else { "←" };
        self.toast(format!("{arrow} match"));
    }
}
