//! LSP subsystem methods on `App` — completion popup, signature help,
//! goto definition / declaration / type-def / impl, references,
//! hover, rename, code actions, formatting, call/type hierarchy,
//! document highlight, selection range, folding range, semantic
//! tokens, document symbol + workspace symbol pickers + outline pane.
//!
//! Extracted from `app/mod.rs` in the file-split refactor
//!. Pure non-destructive move.

use super::*;

impl App {
    /// Move the completion-popup selection by `delta` rows (no-op if none open).
    pub fn completion_move(&mut self, delta: isize) {
        if let Some(p) = &mut self.completion {
            p.move_by(delta);
        }
        self.completion_request_resolve_if_needed();
    }

    /// If the popup's currently selected item has no documentation yet AND
    /// is backed by a server item we can round-trip, fire
    /// `completionItem/resolve`. The reply arrives as
    /// [`crate::lsp::LspEvent::CompletionResolve`] and is merged back into
    /// the popup. Marked `resolved = true` immediately so we don't spam.
    pub fn completion_request_resolve_if_needed(&mut self) {
        let Some(popup) = self.completion.as_mut() else {
            return;
        };
        let Some(it_idx) = popup.current_index_mut() else {
            return;
        };
        let path = popup.path.clone();
        let item = popup.item_at_mut(it_idx);
        if item.resolved || !item.documentation.is_empty() || item.raw.is_none() {
            return;
        }
        let raw = item.raw.clone().unwrap();
        let label = item.label.clone();
        item.resolved = true;
        self.lsp.completion_resolve(&path, &label, raw);
    }

    /// Accept the highlighted completion: replace the identifier prefix left of
    /// the cursor with the item's insert text, then close the popup. Snippet
    /// items (`insertTextFormat == 2`) get LSP snippet syntax expanded into
    /// mnml's placeholder machinery so `$1` / `$0` drive Tab-cycling.
    pub fn completion_accept(&mut self) {
        let Some(popup) = self.completion.take() else {
            return;
        };
        let Some(item) = popup.current().cloned() else {
            return;
        };
        let prefix_len = popup.prefix.len(); // bytes — prefix chars are all id chars
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&popup.path)))
        else {
            return;
        };
        if item.is_snippet {
            // Snippet path — parse LSP syntax with per-stop default lengths,
            // then apply via the defaults-aware snippet edit machinery so
            // `${1:default}` gets the default text *selected* at landing.
            let parsed = crate::snippets::parse_lsp_snippet(&item.insert);
            let (cursor, start) = match self.panes.get(idx) {
                Some(Pane::Editor(b)) => {
                    let c = b.editor.cursor();
                    (c, c.saturating_sub(prefix_len))
                }
                _ => return,
            };
            let placeholders: Vec<usize> = parsed.placeholders.iter().map(|(p, _)| *p).collect();
            let default_lens: Vec<usize> = parsed.placeholders.iter().map(|(_, d)| *d).collect();
            self.apply_snippet_edit_with_defaults(
                start,
                cursor,
                parsed.text,
                parsed.cursor_offset,
                placeholders,
                default_lens,
            );
            return;
        }
        let clip = &mut self.clipboard;
        if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
            let cursor = b.editor.cursor();
            let start = cursor.saturating_sub(prefix_len);
            b.apply_edit_ops(
                vec![crate::edit_op::EditOp::ReplaceRange {
                    start,
                    end: cursor,
                    text: item.insert.clone(),
                }],
                clip,
                0,
            );
        }
        if let Some(Pane::Editor(b)) = self.panes.get(idx) {
            let t = b.editor.text().to_string();
            self.lsp.did_change(&popup.path, &t);
        }
    }

    pub fn completion_on_edit(&mut self, typed: Option<char>) {
        let is_id = |c: char| c.is_alphanumeric() || c == '_';
        let Some(prefix) = self.cursor_id_prefix() else {
            self.completion = None;
            return;
        };
        if let Some(popup) = &mut self.completion {
            if prefix.is_empty() || !popup.refilter(&prefix) {
                self.completion = None;
            } else {
                return; // already showing — refiltered locally, no re-request
            }
        }
        match typed {
            Some('.') | Some(':') => self.request_completion_at_cursor(),
            Some(c) if is_id(c) => {
                // Auto-trigger only at the start of a word (the char *before*
                // the one just typed isn't an identifier char) — subsequent
                // keystrokes just narrow the popup that this request opens.
                let at_word_start = self.active_editor().is_some_and(|b| {
                    let cur = b.editor.cursor();
                    let before: Vec<char> = b.editor.text()[..cur].chars().collect();
                    before.len() < 2 || !is_id(before[before.len() - 2])
                });
                if at_word_start {
                    self.request_completion_at_cursor();
                }
            }
            _ => {}
        }
        // Signature-help auto-trigger — orthogonal to completion. `(` opens
        // a fresh popup; `,` re-fires so the active param can advance. `)`
        // dismisses any open popup (we left the function call).
        match typed {
            Some('(') | Some(',') => self.request_signature_help_at_cursor(),
            Some(')') => {
                self.signature = None;
            }
            _ => {}
        }
    }

    /// `lsp.signature_help` — fire `textDocument/signatureHelp` at the active
    /// cursor. The reply lands as [`crate::lsp::LspEvent::SignatureHelp`]
    /// and replaces any open popup. Silent if no server is attached.
    pub fn request_signature_help_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let Some(path) = b.path.clone() else { return };
        let (row, col) = b.editor.row_col();
        let text = b.editor.text().to_string();
        self.lsp.did_change(&path, &text);
        self.lsp.signature_help(&path, row as u32, col as u32);
    }

    /// Fire a `textDocument/completion` at the active editor's cursor — the reply
    /// (`tick` → `apply_lsp_event`) opens the popup. Assumes the server already
    /// has the latest text (the edit path sends `didChange` first). Silent if
    /// there's no server for the file.
    fn request_completion_at_cursor(&mut self) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let Some(path) = b.path.clone() else { return };
        let (row, col) = b.editor.row_col();
        self.lsp.completion(&path, row as u32, col as u32);
    }

    /// vim `Ctrl+W d` — split the active leaf horizontally then fire
    /// `lsp.goto_definition`. The reply opens the def in the new pane.
    pub fn split_goto_definition(&mut self) {
        self.split_active(crate::layout::SplitDir::Vertical);
        self.lsp_goto_definition();
    }

    /// `:lsp.peek_definition` — like `split_goto_definition` but
    /// docks the def below the current pane (horizontal split) so
    /// you can see both at once without sideways layout. Equivalent
    /// to VS Code's "Peek Definition" alt+F12 behavior, minus the
    /// floating-overlay rendering (mnml uses a real pane instead).
    pub fn peek_definition(&mut self) {
        self.split_active(crate::layout::SplitDir::Horizontal);
        self.lsp_goto_definition();
    }

    /// `:lsp.peek_definition_overlay` — true VS Code Alt+F12
    /// behavior: a floating bordered box appears OVER the editor
    /// showing 15 lines of source around the def. Cursor doesn't
    /// move; Esc closes the overlay and the user is right back
    /// where they were.
    pub fn peek_definition_overlay(&mut self) {
        // 2026-06-21 lsp-cheat-test SEV-2: clear the flag inline
        // after firing if no LSP / no editor / no path — would
        // otherwise leak into the next `gd` and turn a normal
        // jump into an unwanted overlay. The GotoDefinition event
        // handler also clears the flag, but that only runs if the
        // request actually goes out.
        self.pending_peek_definition = true;
        let fired = self.lsp_goto_definition_returning_fired();
        if !fired {
            self.pending_peek_definition = false;
        }
    }

    /// Same as `lsp_goto_definition` but returns true iff the LSP
    /// request actually went out. Used by `peek_definition_overlay`
    /// to clear its pending flag when no LSP is attached.
    fn lsp_goto_definition_returning_fired(&mut self) -> bool {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return false;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return false;
        };
        let text = b.editor.text().to_string();
        let (row, col) = b.editor.row_col();
        self.lsp.did_change(&path, &text);
        let fired = self.lsp.goto_definition(&path, row as u32, col as u32);
        if !fired {
            self.toast("no language server for this file (peek)");
        }
        fired
    }

    /// If an outline pane is open and the now-active editor is a different
    /// file, retarget the outline to that file and re-fire `documentSymbol`.
    /// No-op when nothing's open, the active pane isn't an editor with a
    /// saved path, or the outline's already on this target.
    pub fn retarget_outline_to_active(&mut self) {
        let active_path = self.active_editor().and_then(|b| b.path.clone());
        let Some(path) = active_path else { return };
        let outline_idx = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Outline(_)));
        let Some(idx) = outline_idx else { return };
        let needs_retarget = match self.panes.get(idx) {
            Some(Pane::Outline(o)) => o.target != path,
            _ => false,
        };
        if !needs_retarget {
            return;
        }
        if let Some(Pane::Outline(o)) = self.panes.get_mut(idx) {
            o.target = path.clone();
            o.items.clear();
            o.clamp();
        }
        if is_markdown_path(&path) {
            self.populate_markdown_outline(&path);
            return;
        }
        self.pending_outline = true;
        if !self.lsp.document_symbol(&path) {
            self.pending_outline = false;
        }
    }

    /// Tell the LSP server `path` was saved (re-reads the file — we just wrote it).
    /// Also fires `textDocument/inlayHint` for the visible window range so the
    /// hint chips refresh after edits.
    pub(super) fn notify_lsp_saved(&mut self, path: &Path) {
        if let Ok(text) = std::fs::read_to_string(path) {
            self.lsp.did_save(path, &text);
            let line_count = text.lines().count().max(1) as u32;
            self.lsp.inlay_hint(path, line_count);
            self.lsp.code_lens(path);
            self.lsp.document_link(path);
            self.lsp.document_color(path);
            let viewport = self.semantic_tokens_viewport_for(path);
            self.lsp.semantic_tokens(path, line_count, viewport);
            if viewport.is_some()
                && let Some(b) = self.panes.iter_mut().find_map(|p| match p {
                    Pane::Editor(b) if b.path.as_deref() == Some(path) => Some(b),
                    _ => None,
                })
            {
                b.last_semantic_viewport = viewport;
            }
        }
    }

    /// Compute the visible viewport `(start_line, end_line)` for `path`
    /// to pass to `lsp.semantic_tokens` when `[editor]
    /// semantic_tokens_viewport` is on. Returns `None` when the flag is
    /// off or the pane isn't currently rendered (no rect known).
    pub(super) fn semantic_tokens_viewport_for(&self, path: &Path) -> Option<(u32, u32)> {
        if !self.config.editor.semantic_tokens_viewport {
            return None;
        }
        let (idx, scroll) = self.panes.iter().enumerate().find_map(|(i, p)| match p {
            Pane::Editor(b) if b.path.as_deref() == Some(path) => Some((i, b.scroll)),
            _ => None,
        })?;
        // Use the recorded pane rect height when available; fall back
        // to a generous estimate of 100 rows for the first-render case
        // (open_path before the first draw cycle).
        let h = self
            .rects
            .editor_panes
            .iter()
            .find(|(_, pid)| *pid == idx)
            .map(|(r, _)| r.height as u32)
            .unwrap_or(100);
        let s = scroll as u32;
        Some((s, s.saturating_add(h)))
    }

    /// `lsp.goto_definition` — ask the server where the symbol under the cursor
    /// is defined; the answer arrives async (`tick` jumps there).
    pub fn lsp_goto_definition(&mut self) {
        self.lsp_request_at_cursor(
            |lsp, p, l, c| lsp.goto_definition(p, l, c),
            "go-to-definition",
        );
    }

    /// `lsp.goto_declaration` — ask the server for the *declaration* of the
    /// symbol under the cursor (vs `definition` which is "where it's bound").
    /// For many languages these are the same; C/C++ headers + JS imports
    /// are where they diverge.
    pub fn lsp_goto_declaration(&mut self) {
        self.lsp_request_at_cursor(
            |lsp, p, l, c| lsp.goto_declaration(p, l, c),
            "go-to-declaration",
        );
    }

    /// `lsp.goto_type_definition` — jump to the *type* of the symbol under
    /// the cursor (e.g. `let x: Foo = …` jumps to `Foo`'s definition).
    pub fn lsp_goto_type_definition(&mut self) {
        self.lsp_request_at_cursor(
            |lsp, p, l, c| lsp.goto_type_definition(p, l, c),
            "go-to-type-definition",
        );
    }

    /// `lsp.goto_implementation` — jump to (one of) the concrete
    /// implementations of an interface / trait method under the cursor.
    pub fn lsp_goto_implementation(&mut self) {
        self.lsp_request_at_cursor(
            |lsp, p, l, c| lsp.goto_implementation(p, l, c),
            "go-to-implementation",
        );
    }

    /// `lsp.hover` — ask the server for hover docs at the cursor (`tick` toasts them).
    pub fn lsp_hover(&mut self) {
        self.lsp_request_at_cursor(|lsp, p, l, c| lsp.hover(p, l, c), "hover");
    }

    /// Mouse-driven variant of `lsp_hover` — fires a
    /// `textDocument/hover` for `(row, col)` in `pane_id`'s buffer
    /// WITHOUT moving the cursor (a cursor jump on every hover would
    /// be jarring). The reply lands via the normal `LspEvent::Hover`
    /// path and populates `app.hover`. Silent on no-LSP / no-path —
    /// hover-over-text shouldn't toast.
    pub fn lsp_hover_at_pane(&mut self, pane_id: PaneId, row: usize, col: usize) {
        let Some(Pane::Editor(b)) = self.panes.get(pane_id) else {
            return;
        };
        let Some(path) = b.path.clone() else { return };
        let text = b.editor.text().to_string();
        self.lsp.did_change(&path, &text);
        let _ = self.lsp.hover(&path, row as u32, col as u32);
    }

    /// Called from `tick` — if the mouse has been steady over an
    /// editor cell for ≥`HOVER_DEBOUNCE_MS` AND we haven't already
    /// fired for this exact cell, send a `textDocument/hover` request.
    /// 2026-06-08 SEV-2 fix.
    pub fn maybe_fire_mouse_hover(&mut self) {
        const HOVER_DEBOUNCE_MS: u128 = 600;
        let Some((pid, row, col, when)) = self.mouse_hover_at else {
            return;
        };
        if when.elapsed().as_millis() < HOVER_DEBOUNCE_MS {
            return;
        }
        if self.mouse_hover_fired == Some((pid, row, col)) {
            return;
        }
        self.mouse_hover_fired = Some((pid, row, col));
        self.lsp_hover_at_pane(pid, row, col);
    }

    /// `lsp.references` — find references to the symbol at the cursor (→ picker).
    pub fn lsp_references(&mut self) {
        self.lsp_request_at_cursor(|lsp, p, l, c| lsp.references(p, l, c), "references");
    }

    /// `lsp.{next,prev}_diagnostic` — move the cursor to the next / previous
    /// diagnostic in the active buffer (wrapping), and show its message in the
    /// hover popup.
    pub fn lsp_goto_diagnostic(&mut self, forward: bool) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let has_any = b
            .diagnostics
            .iter()
            .chain(b.linter_diagnostics.iter())
            .next()
            .is_some();
        if !has_any {
            self.toast("no diagnostics in this file");
            return;
        }
        let (row, col) = b.editor.row_col();
        let cur = (row as u32, col as u32);
        let mut diags: Vec<(u32, u32, String)> = b
            .all_diagnostics()
            .map(|d| {
                (
                    d.range.start.line,
                    d.range.start.character,
                    d.message.clone(),
                )
            })
            .collect();
        diags.sort_by_key(|&(l, c, _)| (l, c));
        let target = if forward {
            diags
                .iter()
                .find(|&&(l, c, _)| (l, c) > cur)
                .or_else(|| diags.first())
        } else {
            diags
                .iter()
                .rev()
                .find(|&&(l, c, _)| (l, c) < cur)
                .or_else(|| diags.last())
        };
        let Some(&(l, c, ref msg)) = target else {
            return;
        };
        let (l, c, msg) = (l, c, msg.clone());
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(l as usize, c as usize);
        }
        match crate::hover::HoverPopup::from_text(&msg) {
            Some(h) => self.hover = Some(h),
            None => self.toast(msg),
        }
    }

    /// `lsp.rename` — open a one-line prompt (seeded with the identifier under
    /// the cursor); on accept, send `textDocument/rename` for that spot.
    /// Also fills `rename_preview_state` so the renderer can paint the
    /// proposed new identifier inline at every whole-word occurrence in the
    /// active editor (single-file MVP).
    pub fn lsp_rename(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let (row, col) = b.editor.row_col();
        let word = self.word_under_cursor();
        // Fill rename preview state for the active pane (single-file).
        if let (Some(pid), Some(w)) = (self.active, word.clone()) {
            let text_owned = match self.panes.get(pid) {
                Some(Pane::Editor(b)) => b.editor.text().to_string(),
                _ => String::new(),
            };
            let occurrences = collect_whole_word_occurrences(&text_owned, &w);
            self.rename_preview_state = Some(RenamePreviewState {
                pane_id: pid,
                original_word: w,
                occurrences,
            });
        }
        self.pending_rename = Some((path, row as u32, col as u32));
        let kind = crate::prompt::PromptKind::LspRename;
        self.prompt = Some(match word {
            Some(w) => crate::prompt::Prompt::seeded(kind, "Rename symbol to", w),
            None => crate::prompt::Prompt::new(kind, "Rename symbol to"),
        });
    }

    /// `lsp.symbols` (`Ctrl+Shift+O`) — open a fuzzy picker over the active
    /// buffer's symbols (`textDocument/documentSymbol`). The reply lands async
    /// in `apply_lsp_event` → `open_symbols_picker`.
    pub fn lsp_symbols(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        self.lsp.did_change(&path, &text);
        if !self.lsp.document_symbol(&path) {
            self.toast("no language server for this file (symbols)");
        }
    }

    /// `lsp.workspace_symbols` — prompt for a query, then fire
    /// `workspace/symbol` against every running language server. Replies
    /// (`LspEvent::WorkspaceSymbols`) land async and feed
    /// [`Self::apply_workspace_symbols`] which routes the hits to a
    /// `PickerKind::Locations` picker.
    pub fn lsp_workspace_symbols(&mut self) {
        if self.lsp.is_empty() {
            self.toast("no language server running");
            return;
        }
        self.prompt = Some(crate::prompt::Prompt::new(
            crate::prompt::PromptKind::LspWorkspaceSymbol,
            "Workspace symbols (query)",
        ));
    }

    /// Fire `workspace/symbol` after the prompt is accepted. Resets the picker
    /// stash so partial replies from previous queries don't bleed in.
    pub fn run_workspace_symbol_query(&mut self, query: &str) {
        self.pending_workspace_symbols.clear();
        self.pending_workspace_symbol_query = Some(query.to_string());
        if !self.lsp.workspace_symbol(query) {
            self.toast("no language server (workspace symbols)");
        }
    }

    /// Apply a `workspace/symbol` reply: merge hits into a Locations picker.
    /// Multiple servers may each reply — we collect them in a stash and
    /// (re-)open the picker after every reply so the user sees results as
    /// they arrive.
    fn apply_workspace_symbols(&mut self, syms: Vec<crate::lsp::WorkspaceSymbol>) {
        if syms.is_empty() {
            return;
        }
        self.pending_workspace_symbols.extend(syms);
        let stash = self.pending_workspace_symbols.clone();
        use crate::picker::PickerItem;
        let items: Vec<PickerItem> = stash
            .iter()
            .map(|s| {
                let rel = rel_path(&self.workspace, &s.path);
                let detail = match &s.container {
                    Some(c) if !c.is_empty() => format!("{}  {}", s.kind, c),
                    _ => s.kind.to_string(),
                };
                PickerItem::new(
                    format!("{}\t{}\t{}", s.path.display(), s.line, s.character),
                    format!("{}  {}:{}", s.name, rel, s.line + 1),
                    detail,
                )
            })
            .collect();
        let title = match &self.pending_workspace_symbol_query {
            Some(q) if !q.is_empty() => format!("Workspace symbols ({})  '{q}'", items.len()),
            _ => format!("Workspace symbols ({})", items.len()),
        };
        self.open_picker(Picker::new(PickerKind::Locations, title, items));
    }

    /// `outline.show` — open (or refocus) a persistent symbol outline for the
    /// active editor. Fires `documentSymbol`; the reply lands async and
    /// populates the outline pane (instead of opening a picker — the
    /// `pending_outline` flag routes the next reply to the pane).
    pub fn open_outline_pane(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        // Already open ⇒ retarget + refresh.
        if let Some(id) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Outline(_)))
        {
            if let Some(Pane::Outline(o)) = self.panes.get_mut(id) {
                o.target = path.clone();
                o.items.clear();
                o.clamp();
            }
            self.reveal_pane(id);
        } else {
            let pane = Pane::Outline(crate::lsp::outline_pane::OutlinePane::new(
                path.clone(),
                Vec::new(),
            ));
            match self.active {
                Some(cur) => {
                    let new_id =
                        self.split_leaf_with(cur, crate::layout::SplitDir::Horizontal, pane);
                    self.active = Some(new_id);
                }
                None => {
                    self.panes.push(pane);
                    let id = self.panes.len() - 1;
                    *self.layout_mut() = Layout::leaf(id);
                    self.active = Some(id);
                }
            }
            self.focus = Focus::Pane;
        }
        // Markdown buffers don't need a language server — extract headings
        // directly from the text and populate the pane synchronously.
        if is_markdown_path(&path) {
            self.populate_markdown_outline(&path);
            return;
        }
        // Ask for symbols; the reply routes to the outline.
        let text = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(&path) => Some(b.editor.text().to_string()),
                _ => None,
            })
            .unwrap_or_default();
        self.lsp.did_change(&path, &text);
        self.pending_outline = true;
        if !self.lsp.document_symbol(&path) {
            self.pending_outline = false;
            // Fallback: regex-based extraction for the languages we support.
            // Empty result on unknown extensions just leaves the pane blank.
            self.populate_regex_outline(&path);
        }
    }

    /// Synchronous regex-based outline fallback — runs when no LSP is
    /// attached for this file's language. Pulls patterns from
    /// `crate::regex_outline::extract_symbols`.
    fn populate_regex_outline(&mut self, path: &Path) {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_string();
        let text = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(path) => Some(b.editor.text().to_string()),
                _ => None,
            })
            .unwrap_or_default();
        let items = crate::regex_outline::extract_symbols(&text, &ext);
        if let Some(o) = self.panes.iter_mut().find_map(|p| match p {
            Pane::Outline(o) => Some(o),
            _ => None,
        }) {
            o.items = items;
            o.clamp();
        }
    }

    /// Read the active markdown editor's text, extract ATX headings, and
    /// drop them onto the open outline pane. Synchronous — markdown headings
    /// don't need a language server.
    fn populate_markdown_outline(&mut self, path: &Path) {
        let text = self
            .panes
            .iter()
            .find_map(|p| match p {
                Pane::Editor(b) if b.is_at(path) => Some(b.editor.text().to_string()),
                _ => None,
            })
            .unwrap_or_default();
        let items = crate::markdown_outline::extract_headings(&text);
        if let Some(o) = self.panes.iter_mut().find_map(|p| match p {
            Pane::Outline(o) => Some(o),
            _ => None,
        }) {
            o.items = items;
            o.clamp();
        }
    }

    /// `r` in the outline pane — refire the request for its current target.
    pub fn refresh_outline_pane(&mut self) {
        let Some(Pane::Outline(o)) = self.active.and_then(|i| self.panes.get(i)) else {
            return;
        };
        let path = o.target.clone();
        if is_markdown_path(&path) {
            self.populate_markdown_outline(&path);
            return;
        }
        self.pending_outline = true;
        if !self.lsp.document_symbol(&path) {
            self.pending_outline = false;
            self.populate_regex_outline(&path);
        }
    }

    pub fn move_outline_selection(&mut self, delta: isize) {
        if let Some(Pane::Outline(o)) = self.active.and_then(|i| self.panes.get_mut(i)) {
            o.move_selection(delta);
        }
    }

    /// `Enter` in the outline pane: open the target file (refocusing if
    /// already open) and place the cursor at the selected symbol.
    pub fn jump_to_selected_outline(&mut self) {
        let (target, line, col) = match self.active.and_then(|i| self.panes.get(i)) {
            Some(Pane::Outline(o)) => {
                let Some(sym) = o.selected_item() else {
                    return;
                };
                (o.target.clone(), sym.line, sym.character)
            }
            _ => return,
        };
        self.open_path(&target);
        if let Some(b) = self.active_editor_mut() {
            b.editor.place_cursor(line as usize, col as usize);
        }
    }

    /// Apply a `textDocument/documentSymbol` reply: open a fuzzy picker over
    /// the symbols, indented by depth. Empty list ⇒ toast.
    fn open_symbols_picker(&mut self, symbols: Vec<crate::lsp::DocumentSymbol>) {
        if symbols.is_empty() {
            self.toast("no symbols");
            return;
        }
        use crate::picker::PickerItem;
        let n = symbols.len();
        let items: Vec<PickerItem> = symbols
            .into_iter()
            .map(|s| {
                let indent = "  ".repeat(s.depth as usize);
                let label = format!("{indent}{}", s.name);
                let detail = format!("{}  {}", s.kind, s.line + 1);
                PickerItem::new(format!("{}\t{}", s.line, s.character), label, detail)
            })
            .collect();
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Symbols,
            format!("Symbols ({n})"),
            items,
        ));
    }

    /// `lsp.code_action` (`Ctrl+.`) — ask the server what actions apply at the
    /// cursor (or across the active selection), passing along the diagnostics
    /// that overlap so quickfixes are offered. The reply lands async in
    /// [`Self::tick`] → `apply_code_action_reply`.
    pub fn lsp_code_action(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        let (start, end) = if let Some((s, e)) = b.editor.selection() {
            let (sl, sc) = byte_to_line_col(&text, s);
            let (el, ec) = byte_to_line_col(&text, e);
            (
                crate::lsp::Pos {
                    line: sl as u32,
                    character: sc as u32,
                },
                crate::lsp::Pos {
                    line: el as u32,
                    character: ec as u32,
                },
            )
        } else {
            let (row, col) = b.editor.row_col();
            let p = crate::lsp::Pos {
                line: row as u32,
                character: col as u32,
            };
            (p, p)
        };
        let range = crate::lsp::Range { start, end };
        let diagnostics: Vec<crate::lsp::Diagnostic> = b
            .diagnostics
            .iter()
            .filter(|d| ranges_overlap(d.range, range))
            .cloned()
            .collect();
        self.pending_code_action_path = Some(path.clone());
        self.lsp.did_change(&path, &text);
        if !self.lsp.code_action(&path, range, &diagnostics) {
            self.pending_code_action_path = None;
            self.pending_code_action_auto_apply = false;
            self.toast("no language server for this file (code action)");
        }
    }

    /// `lsp.quick_fix` (Alt+Enter) — like [`Self::lsp_code_action`], but the
    /// reply handler auto-applies the *first* action instead of opening a
    /// picker. The point is the common "fix this for me" gesture next to
    /// an inline diagnostic — pick-the-first matches what most IDEs do
    /// because servers front-load the most relevant action.
    pub fn lsp_quick_fix(&mut self) {
        self.pending_code_action_auto_apply = true;
        // Reuse the same request path; `apply_code_action_reply` branches
        // on the auto-apply flag.
        self.lsp_code_action();
    }

    /// `lsp.organize_imports` — fire `textDocument/codeAction` with the
    /// `kind: "source.organizeImports"` filter; the auto-apply path picks
    /// the first matching action (servers typically return only the one).
    /// Sister to `lsp.quick_fix` but scoped to a specific code-action kind.
    pub fn lsp_organize_imports(&mut self) {
        // Same request path as `lsp_code_action` but filtered to imports
        // via the `only` field. We reuse the auto-apply machinery so the
        // first returned action is applied without opening a picker.
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("no path for active editor");
            return;
        };
        // Whole-buffer range — vim's `:OrganizeImports` is buffer-scoped
        // and so is the typical `source.organizeImports` server response.
        let line_count = b.editor.line_count() as u32;
        let diagnostics = b.diagnostics.clone();
        let range = crate::lsp::Range {
            start: crate::lsp::Pos {
                line: 0,
                character: 0,
            },
            end: crate::lsp::Pos {
                line: line_count.saturating_sub(1),
                character: 0,
            },
        };
        // Ask explicitly with the `only` filter — servers that respect it
        // return just import-organization actions. We piggyback on
        // pending_code_action_auto_apply so the first action applies.
        self.pending_code_action_auto_apply = true;
        if !self.lsp.code_action_with_only(
            &path,
            range,
            &diagnostics,
            &["source.organizeImports".to_string()],
        ) {
            self.pending_code_action_auto_apply = false;
            self.toast("no language server for this file");
        }
    }

    /// Handle a `textDocument/codeAction` reply.
    ///
    /// - With `pending_code_action_auto_apply` set: applies the first action
    ///   directly (toasts when the list is empty). Resets the flag either way.
    /// - Otherwise: stashes the actions and opens a picker; the picker's
    ///   `accept` calls [`Self::apply_code_action`].
    fn apply_code_action_reply(&mut self, actions: Vec<crate::lsp::CodeAction>) {
        let auto = std::mem::take(&mut self.pending_code_action_auto_apply);
        if actions.is_empty() {
            self.toast(if auto {
                "no quick fix available"
            } else {
                "no code actions"
            });
            return;
        }
        if auto {
            // Apply the first action without prompting.
            self.pending_code_actions = actions;
            self.apply_code_action(0);
            return;
        }
        use crate::picker::PickerItem;
        // Group by kind so the picker reads source→refactor→quickfix→…
        // each kind with a short header chip. Order within a kind is
        // server-given. Indices we hand the picker still point at the
        // original action slot.
        fn kind_priority(k: &str) -> u8 {
            // Lower = earlier. Quick fixes first (most-used), then
            // refactors, then source actions, then anything else / blank.
            if k.starts_with("quickfix") {
                0
            } else if k.starts_with("refactor") {
                1
            } else if k.starts_with("source") {
                2
            } else {
                3
            }
        }
        let mut indexed: Vec<(usize, &crate::lsp::CodeAction)> =
            actions.iter().enumerate().collect();
        indexed.sort_by(|(_, a), (_, b)| {
            let ka = a.kind.as_deref().unwrap_or("");
            let kb = b.kind.as_deref().unwrap_or("");
            kind_priority(ka).cmp(&kind_priority(kb))
        });
        let items: Vec<PickerItem> = indexed
            .iter()
            .map(|(i, a)| {
                let detail = a.kind.clone().unwrap_or_default();
                PickerItem::new(i.to_string(), a.title.clone(), detail)
            })
            .collect();
        let n = items.len();
        self.pending_code_actions = actions;
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::CodeActions,
            format!("Code actions ({n})"),
            items,
        ));
    }

    /// Apply the chosen code action: edit (if any) — through the same workspace-
    /// edit code path as rename — then `workspace/executeCommand` (if any).
    pub fn apply_code_action(&mut self, idx: usize) {
        let Some(action) = self.pending_code_actions.get(idx).cloned() else {
            return;
        };
        let path = self.pending_code_action_path.clone();
        // Lazy resolve — server sent us a "stub" action with only `data` (no
        // edit, no command). Fire `codeAction/resolve` and apply when the
        // reply lands.
        if action.edit.is_none()
            && action.command.is_none()
            && let (Some(raw), Some(p)) = (action.raw.clone(), path.clone())
        {
            self.pending_code_action_resolve = Some(idx);
            self.lsp.code_action_resolve(&p, raw);
            self.toast(format!("code action: resolving '{}'…", action.title));
            return;
        }
        if action.edit.is_none() && action.command.is_none() {
            self.toast(format!("code action: '{}' has no edit", action.title));
            return;
        }
        if let Some(edits) = action.edit {
            self.apply_rename_edits(edits);
        }
        if let (Some(cmd), Some(p)) = (action.command, path)
            && !self.lsp.execute_command(&p, &cmd)
        {
            self.toast(format!("code action: couldn't run '{}'", cmd.command));
        }
    }

    /// Click handler for a `⚡ <title>` code-lens chip — `pane_id` + `lens_idx`
    /// come from the rect registered during render
    /// (`app.rects.code_lens_chips`). Looks up the lens, then fires its
    /// `workspace/executeCommand` against the language server attached
    /// to the buffer's path. No-op (with a toast) when the lens has no
    /// command — those are stub lenses that would need
    /// `codeLens/resolve` to flesh out, which the MVP skips.
    pub fn trigger_code_lens(&mut self, pane_id: PaneId, lens_idx: usize) {
        let Some(Pane::Editor(b)) = self.panes.get(pane_id) else {
            return;
        };
        let Some(lens) = b.code_lenses.get(lens_idx) else {
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("code lens needs a saved file");
            return;
        };
        // Stub: title-only lens that the server expects us to round-trip
        // through `codeLens/resolve` for the command. Stash the click so
        // the reply handler can re-fire it; toast a one-liner so the user
        // knows we're working on it.
        if lens.command.is_none() {
            let Some(raw) = lens.raw.clone() else {
                self.toast(format!("code lens '{}' has no command", lens.title));
                return;
            };
            let title = lens.title.clone();
            self.pending_code_lens_resolve = Some((pane_id, lens_idx));
            if !self.lsp.code_lens_resolve(&path, raw, lens_idx) {
                self.pending_code_lens_resolve = None;
                self.toast(format!("code lens: no server for '{}'", title));
                return;
            }
            self.toast(format!("code lens: resolving '{title}'…"));
            return;
        }
        let cmd = lens.command.clone().unwrap();
        let title = lens.title.clone();
        if !self.lsp.execute_command(&path, &cmd) {
            self.toast(format!("code lens: no server for '{}'", title));
            return;
        }
        self.toast(format!("code lens: {title}"));
    }

    /// `lsp.completion` (`Ctrl+Space`) — manually ask the server for completions
    /// at the cursor; the reply (`tick` → `apply_lsp_event`) opens the popup
    /// ([`Self::completion_on_edit`] auto-triggers it as you type otherwise).
    pub fn lsp_completion(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        let (row, col) = b.editor.row_col();
        self.lsp.did_change(&path, &text);
        if !self.lsp.completion(&path, row as u32, col as u32) {
            self.toast("no language server for this file (completion)");
        }
    }

    fn lsp_request_at_cursor(
        &mut self,
        send: impl FnOnce(&mut crate::lsp::LspManager, &Path, u32, u32) -> bool,
        what: &str,
    ) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("LSP needs a saved file");
            return;
        };
        let text = b.editor.text().to_string();
        let (row, col) = b.editor.row_col();
        // Sync the latest text first so positions line up, then send the request.
        self.lsp.did_change(&path, &text);
        if !send(&mut self.lsp, &path, row as u32, col as u32) {
            self.toast(format!("no language server for this file ({what})"));
        }
    }

    /// Apply one LSP event (called from `tick`).
    fn apply_lsp_event(&mut self, ev: crate::lsp::LspEvent) {
        use crate::lsp::LspEvent;
        match ev {
            LspEvent::Diagnostics { path, diags } => {
                for pane in &mut self.panes {
                    if let Pane::Editor(b) = pane
                        && b.is_at(&path)
                    {
                        b.diagnostics = diags.clone();
                    }
                }
                self.refresh_diagnostics_panes();
            }
            LspEvent::GotoDefinition {
                path,
                line,
                character,
            } => {
                if self.pending_peek_definition {
                    self.pending_peek_definition = false;
                    match crate::peek_overlay::PeekOverlay::load(path.clone(), line) {
                        Some(po) => self.peek_overlay = Some(po),
                        None => self.toast(format!(
                            "peek: can't read {}",
                            path.display()
                        )),
                    }
                } else {
                    self.open_path(&path);
                    if let Some(b) = self.active_editor_mut() {
                        b.editor.place_cursor(line as usize, character as usize);
                    }
                }
            }
            LspEvent::Hover { text } => match crate::hover::HoverPopup::from_text(&text) {
                Some(h) => self.hover = Some(h),
                None => self.toast("hover: (nothing)"),
            },
            LspEvent::References(locs) => {
                if locs.is_empty() {
                    self.toast("no references");
                    return;
                }
                // Open into Pane::Quickfix so the user can navigate references
                // with `:cnext` / `:cprev` and keep the list visible. Previously
                // surfaced as a Locations picker — that flow is still
                // reachable via the palette if needed.
                let n = locs.len();
                let hits: Vec<crate::grep_pane::GrepHit> = locs
                    .into_iter()
                    .map(|(path, line, col)| {
                        let rel = rel_path(&self.workspace, &path);
                        crate::grep_pane::GrepHit {
                            path,
                            rel,
                            line,
                            col,
                            text: String::new(),
                        }
                    })
                    .collect();
                self.open_quickfix(&format!("References ({n})"), hits);
            }
            LspEvent::Rename(edits) => {
                if edits.is_empty() {
                    self.toast("rename: no edits");
                    return;
                }
                // Show a confirmation picker — Apply or Cancel — listing
                // each file + its edit count so the user can see what's
                // about to change before committing.
                use crate::picker::PickerItem;
                let n_edits: usize = edits.iter().map(|(_, v)| v.len()).sum();
                let n_files = edits.len();
                let mut items: Vec<PickerItem> = Vec::with_capacity(n_files + 2);
                items.push(PickerItem::new(
                    "apply",
                    format!("✓ Apply {n_edits} edit(s) across {n_files} file(s)"),
                    String::new(),
                ));
                items.push(PickerItem::new("cancel", "✗ Cancel", String::new()));
                for (path, ranges) in &edits {
                    let rel = rel_path(&self.workspace, path);
                    items.push(PickerItem::new(
                        format!("info:{}", path.display()),
                        format!("  {rel}"),
                        format!("{} edit(s)", ranges.len()),
                    ));
                }
                self.pending_rename_preview = Some(edits);
                self.open_picker(crate::picker::Picker::new(
                    crate::picker::PickerKind::RenamePreview,
                    format!("Rename preview · {n_edits} edits"),
                    items,
                ));
            }
            LspEvent::ApplyEdit { label, edits } => {
                let n = edits.iter().map(|(_, v)| v.len()).sum::<usize>();
                self.apply_rename_edits(edits);
                let lbl = label.unwrap_or_else(|| "workspace edit".to_string());
                self.toast(format!("LSP {lbl} · applied {n} edit(s)"));
            }
            LspEvent::CodeActionResolve { edit, command } => {
                // We told the server "resolve and apply" on a specific action.
                // Merge the resolved fields back in, then apply.
                let Some(idx) = self.pending_code_action_resolve.take() else {
                    return;
                };
                let path = self.pending_code_action_path.clone();
                let (title, resolved_edit, resolved_command) = {
                    let Some(action) = self.pending_code_actions.get_mut(idx) else {
                        return;
                    };
                    if action.edit.is_none() {
                        action.edit = edit;
                    }
                    if action.command.is_none() {
                        action.command = command;
                    }
                    (
                        action.title.clone(),
                        action.edit.take(),
                        action.command.take(),
                    )
                };
                if resolved_edit.is_none() && resolved_command.is_none() {
                    self.toast(format!(
                        "code action: server returned no edit for '{title}'"
                    ));
                    return;
                }
                if let Some(edits) = resolved_edit {
                    self.apply_rename_edits(edits);
                }
                if let (Some(cmd), Some(p)) = (resolved_command, path)
                    && !self.lsp.execute_command(&p, &cmd)
                {
                    self.toast(format!("code action: couldn't run '{}'", cmd.command));
                }
            }
            LspEvent::Completion(items) => {
                use crate::completion::{CompletionItem, CompletionPopup};
                if items.is_empty() {
                    return;
                }
                // Build from the *current* cursor — the request may have been
                // fired a few keystrokes ago; we filter against the live prefix.
                let Some(prefix) = self.cursor_id_prefix() else {
                    return;
                };
                let Some(path) = self.active_editor().and_then(|b| b.path.clone()) else {
                    return;
                };
                let cis: Vec<CompletionItem> = items
                    .into_iter()
                    .take(500)
                    .map(
                        |(label, insert, detail, documentation, raw, is_snippet, kind)| {
                            CompletionItem {
                                label,
                                insert,
                                detail: detail.unwrap_or_default(),
                                documentation: documentation.unwrap_or_default(),
                                raw: Some(raw),
                                resolved: false,
                                is_snippet,
                                kind,
                            }
                        },
                    )
                    .collect();
                let popup = CompletionPopup::new(path, cis, &prefix);
                if !popup.is_empty() {
                    self.completion = Some(popup);
                    // Eagerly ask the server to resolve the FIRST item's docs
                    // (no docs ⇒ likely a server that withholds them; the
                    // resolve fills the footer before the user navigates).
                    self.completion_request_resolve_if_needed();
                }
            }
            LspEvent::CompletionResolve {
                label,
                detail,
                documentation,
            } => {
                let Some(popup) = self.completion.as_mut() else {
                    return;
                };
                let Some(idx) = popup.item_index_by_label(&label) else {
                    return;
                };
                let it = popup.item_at_mut(idx);
                if let Some(d) = documentation
                    && it.documentation.is_empty()
                {
                    it.documentation = d;
                }
                if let Some(d) = detail
                    && it.detail.is_empty()
                {
                    it.detail = d;
                }
            }
            LspEvent::Formatting { path, edits } => self.apply_formatting_edits(path, edits),
            LspEvent::WillSaveWaitUntil { path, edits } => self.apply_will_save_edits(path, edits),
            LspEvent::InlayHints { path, hints } => {
                for p in self.panes.iter_mut() {
                    if let Pane::Editor(b) = p
                        && b.path.as_deref() == Some(path.as_path())
                    {
                        b.inlay_hints = hints;
                        break;
                    }
                }
            }
            LspEvent::SemanticTokens { path, tokens } => {
                for p in self.panes.iter_mut() {
                    if let Pane::Editor(b) = p
                        && b.path.as_deref() == Some(path.as_path())
                    {
                        b.semantic_tokens = tokens;
                        break;
                    }
                }
            }
            LspEvent::CodeLens { path, lenses } => {
                for p in self.panes.iter_mut() {
                    if let Pane::Editor(b) = p
                        && b.path.as_deref() == Some(path.as_path())
                    {
                        b.code_lenses = lenses;
                        break;
                    }
                }
            }
            LspEvent::CodeLensResolve {
                path,
                lens_index,
                lens,
            } => {
                // Merge the resolved command back onto the original lens
                // in the buffer (matched by index). Then re-fire the
                // click that triggered the resolve.
                let pending = self.pending_code_lens_resolve.take();
                for (i, p) in self.panes.iter_mut().enumerate() {
                    if let Pane::Editor(b) = p
                        && b.path.as_deref() == Some(path.as_path())
                    {
                        if let Some(orig) = b.code_lenses.get_mut(lens_index) {
                            if orig.command.is_none() {
                                orig.command = lens.command;
                            }
                            // Clear `raw` so we don't resolve again on the
                            // next click.
                            orig.raw = None;
                        }
                        if let Some((pane_id, idx)) = pending
                            && pane_id == i
                            && idx == lens_index
                        {
                            self.trigger_code_lens(pane_id, lens_index);
                        }
                        return;
                    }
                }
            }
            LspEvent::DocumentLinks { path, links } => {
                for p in self.panes.iter_mut() {
                    if let Pane::Editor(b) = p
                        && b.path.as_deref() == Some(path.as_path())
                    {
                        b.document_links = links;
                        break;
                    }
                }
            }
            LspEvent::FoldingRanges { path, ranges } => {
                self.apply_folding_ranges(&path, ranges);
            }
            LspEvent::SelectionRanges { path, ranges } => {
                self.apply_selection_ranges(&path, ranges);
            }
            LspEvent::DocumentColor { path, colors } => {
                for p in self.panes.iter_mut() {
                    if let Pane::Editor(b) = p
                        && b.path.as_deref() == Some(path.as_path())
                    {
                        b.color_decorations = colors;
                        break;
                    }
                }
            }
            LspEvent::DocumentHighlights { path, ranges } => {
                for p in self.panes.iter_mut() {
                    if let Pane::Editor(b) = p
                        && b.path.as_deref() == Some(path.as_path())
                    {
                        b.document_highlights = ranges;
                        break;
                    }
                }
            }
            LspEvent::CallHierarchyPrepared { direction, items } => {
                self.apply_call_hierarchy_prepared(direction, items);
            }
            LspEvent::CallHierarchyCalls {
                direction,
                origin_name,
                hits,
            } => {
                self.apply_call_hierarchy_calls(direction, origin_name, hits);
            }
            LspEvent::TypeHierarchyPrepared { direction, items } => {
                self.apply_type_hierarchy_prepared(direction, items);
            }
            LspEvent::TypeHierarchyTypes {
                direction,
                origin_name,
                hits,
            } => {
                self.apply_type_hierarchy_types(direction, origin_name, hits);
            }
            LspEvent::CodeAction(actions) => self.apply_code_action_reply(actions),
            LspEvent::DocumentSymbols(symbols) => {
                if self.pending_outline {
                    self.pending_outline = false;
                    if let Some(o) = self.panes.iter_mut().find_map(|p| match p {
                        Pane::Outline(o) => Some(o),
                        _ => None,
                    }) {
                        o.items = symbols;
                        o.clamp();
                    }
                } else {
                    self.open_symbols_picker(symbols);
                }
            }
            LspEvent::WorkspaceSymbols(syms) => self.apply_workspace_symbols(syms),
            LspEvent::SignatureHelp(sh) => {
                self.signature = crate::signature::SignaturePopup::from_reply(sh);
            }
            LspEvent::ProgressBegin { token, title } => {
                self.lsp_progress.insert(token, title);
            }
            LspEvent::ProgressReport { token, title } => {
                if !title.is_empty() {
                    self.lsp_progress.insert(token, title);
                }
            }
            LspEvent::ProgressEnd { token } => {
                self.lsp_progress.remove(&token);
            }
            LspEvent::Message(m) => self.toast(m),
        }
    }

    /// Apply a `TextEdit[]` from `textDocument/formatting` to the matching open
    /// buffer (single file). Reuses `build_replace_ops` for the Range → byte
    /// translation, applies through `apply_edit_ops` (one undo step). If a
    /// format-on-save is pending for this file, chains the actual save.
    fn apply_formatting_edits(&mut self, path: PathBuf, edits: Vec<(crate::lsp::Range, String)>) {
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        else {
            return;
        };
        let ops = match self.panes.get(idx) {
            Some(Pane::Editor(b)) => build_replace_ops(b.editor.text(), &edits),
            _ => Vec::new(),
        };
        let was_format_then_save = matches!(
            &self.pending_format_save,
            Some((p, _)) if p == &path,
        );
        if !ops.is_empty() {
            let clip = &mut self.clipboard;
            if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                b.apply_edit_ops(ops, clip, 0);
            }
            if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                let t = b.editor.text().to_string();
                self.lsp.did_change(&path, &t);
            }
            if !was_format_then_save {
                self.toast(format!("formatted {}", rel_path(&self.workspace, &path)));
            }
        }
        if was_format_then_save {
            self.pending_format_save = None;
            self.save_active_now();
        }
    }

    /// Apply the `TextEdit[]` returned by `textDocument/willSaveWaitUntil`
    /// to the matching open buffer, then advance the save state machine.
    /// Empty edits are a valid no-op reply (the server saw the save event
    /// but had nothing to change) — we still chain forward so the save
    /// completes.
    fn apply_will_save_edits(&mut self, path: PathBuf, edits: Vec<(crate::lsp::Range, String)>) {
        let was_pending = matches!(
            &self.pending_will_save,
            Some((p, _)) if p == &path,
        );
        if !was_pending {
            return; // stale reply (deadline expired, save already chained)
        }
        let Some(idx) = self
            .panes
            .iter()
            .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)))
        else {
            self.pending_will_save = None;
            return;
        };
        if !edits.is_empty() {
            let ops = match self.panes.get(idx) {
                Some(Pane::Editor(b)) => build_replace_ops(b.editor.text(), &edits),
                _ => Vec::new(),
            };
            if !ops.is_empty() {
                let clip = &mut self.clipboard;
                if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                    b.apply_edit_ops(ops, clip, 0);
                }
                if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                    let t = b.editor.text().to_string();
                    self.lsp.did_change(&path, &t);
                }
            }
        }
        self.pending_will_save = None;
        self.save_active_after_will_save();
    }

    /// `lsp.format` (`Ctrl+Shift+I`) — ask the LSP to format the active
    /// buffer. The reply lands async in [`Self::tick`] → `apply_formatting_edits`.
    pub fn lsp_format(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("nothing to format (scratch buffer)");
            return;
        };
        let tab_size = self.config.editor.tab_width as u32;
        if !self.lsp.formatting(&path, tab_size, true) {
            self.toast("no LSP server attached to this file");
        }
    }

    /// Drain completed linter jobs and write their diagnostics onto the
    /// matching buffer. Called once per `App::tick`.
    pub fn drain_linter_jobs(&mut self) {
        let Some((_, rx)) = &self.linter_chan else {
            return;
        };
        let done: Vec<LinterJobDone> = rx.try_iter().collect();
        for (path, parser, result) in done {
            let target = self.panes.iter_mut().find_map(|p| match p {
                Pane::Editor(b) if b.path.as_deref() == Some(path.as_path()) => Some(b),
                _ => None,
            });
            let Some(b) = target else {
                continue;
            };
            match result {
                Ok(diags) => {
                    let n = diags.len();
                    b.linter_diagnostics = diags;
                    self.toast(format!(
                        "{parser}: {n} issue{}",
                        if n == 1 { "" } else { "s" }
                    ));
                }
                Err(e) => {
                    self.toast(format!("linter failed — {e}"));
                }
            }
        }
        self.refresh_diagnostics_panes();
    }

    /// `editor.format_external` — conform-style external formatter for
    /// the active buffer. Picks a command from `[formatters.<ext>] cmd =
    /// "..."` (config) or the built-in defaults (`prettier`, `rustfmt`,
    /// `gofmt`, `ruff format`, `shfmt`, etc). Tries each candidate in
    /// order until one exits successfully; non-zero exits ⇒ no buffer
    /// change + toast with stderr preview. Cursor preserved by
    /// `ReplaceRange` (single edit op so undo restores the original).
    pub fn format_external_active(&mut self) {
        let Some(idx) = self.active else {
            self.toast("no active editor");
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get(idx) else {
            self.toast("no active editor");
            return;
        };
        let ext = match b.language_ext.as_deref() {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => {
                self.toast("formatter: no filetype");
                return;
            }
        };
        let cands = crate::formatter::formatters_for(&self.config.formatters, &ext);
        if cands.is_empty() {
            self.toast(format!("formatter: no command configured for .{ext}"));
            return;
        }
        let path = b.path.clone();
        let input = b.editor.text().to_string();
        let buf_len = input.len();
        let workspace = self.workspace.clone();
        let mut last_err = String::new();
        for template in &cands {
            let cmd = crate::formatter::expand_cmd(template, &workspace, path.as_deref());
            match crate::formatter::run_formatter(&cmd, &workspace, &input) {
                Ok(stdout) => {
                    if let Some(Pane::Editor(b)) = self.panes.get_mut(idx) {
                        b.apply_edit_ops(
                            vec![crate::edit_op::EditOp::ReplaceRange {
                                start: 0,
                                end: buf_len,
                                text: stdout.clone(),
                            }],
                            &mut self.clipboard,
                            0,
                        );
                    }
                    // Trim the command to its first token for the toast.
                    let bin = template.split_whitespace().next().unwrap_or("formatter");
                    self.toast(format!("formatted via {bin}"));
                    return;
                }
                Err(e) => last_err = format!("{template}: {e}"),
            }
        }
        self.toast(format!("formatter failed — {last_err}"));
    }

    /// Apply a flattened `WorkspaceEdit` (from `textDocument/rename`): edit each
    /// affected file — through `Editor::apply` if it's open as a buffer (left
    /// dirty for review), else by splicing the file on disk directly.
    pub(super) fn apply_rename_edits(
        &mut self,
        edits: Vec<(PathBuf, Vec<(crate::lsp::Range, String)>)>,
    ) {
        if edits.is_empty() {
            self.toast("rename: no changes");
            return;
        }
        let (mut buffers, mut disk, mut total) = (0usize, 0usize, 0usize);
        for (path, file_edits) in edits {
            let idx = self
                .panes
                .iter()
                .position(|p| matches!(p, Pane::Editor(b) if b.is_at(&path)));
            if let Some(idx) = idx {
                let ops = match self.panes.get(idx) {
                    Some(Pane::Editor(b)) => build_replace_ops(b.editor.text(), &file_edits),
                    _ => Vec::new(),
                };
                if ops.is_empty() {
                    continue;
                }
                let n = ops.len();
                let clip = &mut self.clipboard;
                let applied = match self.panes.get_mut(idx) {
                    Some(Pane::Editor(b)) => b.apply_edit_ops(ops, clip, 0),
                    _ => false,
                };
                if applied {
                    buffers += 1;
                    total += n;
                    if let Some(Pane::Editor(b)) = self.panes.get(idx) {
                        let t = b.editor.text().to_string();
                        self.lsp.did_change(&path, &t);
                    }
                }
            } else if let Ok(text) = std::fs::read_to_string(&path) {
                let ops = build_replace_ops(&text, &file_edits);
                if ops.is_empty() {
                    continue;
                }
                let n = ops.len();
                let mut s = text;
                for op in &ops {
                    if let crate::edit_op::EditOp::ReplaceRange { start, end, text } = op {
                        s.replace_range(*start..*end, text);
                    }
                }
                if std::fs::write(&path, s).is_ok() {
                    disk += 1;
                    total += n;
                }
            }
        }
        if disk > 0 {
            self.git.refresh();
        }
        self.toast(format!(
            "renamed {total} occurrence(s): {buffers} open buffer(s), {disk} on-disk file(s) — review & save"
        ));
    }

    pub fn drain_lsp_events(&mut self) {
        for ev in self.lsp.poll() {
            self.apply_lsp_event(ev);
        }
    }

    /// Rebuild the item list of any open diagnostics pane (called when
    /// diagnostics change, or on the pane's `r` key).
    pub fn refresh_diagnostics_panes(&mut self) {
        if !self.panes.iter().any(|p| matches!(p, Pane::Diagnostics(_))) {
            return;
        }
        let fresh = self.build_diagnostics_pane();
        for pane in &mut self.panes {
            if let Pane::Diagnostics(d) = pane {
                d.items = fresh.items.clone();
                d.clamp();
            }
        }
    }

    /// `lsp.incoming_calls` — "who calls this function". Two-step:
    /// `prepareCallHierarchy` at the cursor → first item → `incomingCalls`.
    /// The final reply opens a fuzzy picker of call sites.
    pub fn lsp_incoming_calls(&mut self) {
        let direction = crate::lsp::CallHierarchyDirection::Incoming;
        self.lsp_request_at_cursor(
            move |lsp, p, l, c| lsp.prepare_call_hierarchy(p, l, c, direction),
            "incoming-calls",
        );
    }

    /// `lsp.outgoing_calls` — "what does this function call". Same shape
    /// as `lsp_incoming_calls`, opposite direction.
    pub fn lsp_outgoing_calls(&mut self) {
        let direction = crate::lsp::CallHierarchyDirection::Outgoing;
        self.lsp_request_at_cursor(
            move |lsp, p, l, c| lsp.prepare_call_hierarchy(p, l, c, direction),
            "outgoing-calls",
        );
    }

    /// `lsp.supertypes` — parent classes / traits / supertypes of the
    /// type at the cursor. Two-step: prepareTypeHierarchy → supertypes.
    pub fn lsp_supertypes(&mut self) {
        let direction = crate::lsp::TypeHierarchyDirection::Supertypes;
        self.lsp_request_at_cursor(
            move |lsp, p, l, c| lsp.prepare_type_hierarchy(p, l, c, direction),
            "supertypes",
        );
    }

    /// `lsp.subtypes` — subclasses / implementations / subtypes.
    pub fn lsp_subtypes(&mut self) {
        let direction = crate::lsp::TypeHierarchyDirection::Subtypes;
        self.lsp_request_at_cursor(
            move |lsp, p, l, c| lsp.prepare_type_hierarchy(p, l, c, direction),
            "subtypes",
        );
    }

    /// Handle `LspEvent::TypeHierarchyPrepared` — take the first item and
    /// fire the follow-up `{super,sub}types` request.
    fn apply_type_hierarchy_prepared(
        &mut self,
        direction: crate::lsp::TypeHierarchyDirection,
        items: Vec<crate::lsp::CallHierarchyItem>,
    ) {
        if items.is_empty() {
            self.toast("type hierarchy: nothing under cursor");
            return;
        }
        let item = items.into_iter().next().unwrap();
        match direction {
            crate::lsp::TypeHierarchyDirection::Supertypes => {
                self.lsp.type_hierarchy_supertypes(&item);
            }
            crate::lsp::TypeHierarchyDirection::Subtypes => {
                self.lsp.type_hierarchy_subtypes(&item);
            }
        }
    }

    /// Handle `LspEvent::TypeHierarchyTypes` — open a Locations picker.
    fn apply_type_hierarchy_types(
        &mut self,
        direction: crate::lsp::TypeHierarchyDirection,
        origin_name: String,
        hits: Vec<crate::lsp::CallHit>,
    ) {
        if hits.is_empty() {
            let label = match direction {
                crate::lsp::TypeHierarchyDirection::Supertypes => "supertypes",
                crate::lsp::TypeHierarchyDirection::Subtypes => "subtypes",
            };
            self.toast(format!("type hierarchy: no {label}"));
            return;
        }
        let items: Vec<crate::picker::PickerItem> = hits
            .into_iter()
            .map(|h| {
                let rel = h
                    .path
                    .strip_prefix(&self.workspace)
                    .unwrap_or(h.path.as_path())
                    .to_string_lossy()
                    .to_string();
                let id = format!("{}\t{}\t{}", h.path.display(), h.line, h.character);
                let label = format!("{}  {}", h.name, rel);
                let detail = format!("{}:{}", h.line + 1, h.character + 1);
                crate::picker::PickerItem::new(id, label, detail)
            })
            .collect();
        let title = match direction {
            crate::lsp::TypeHierarchyDirection::Supertypes => {
                format!("Supertypes — {origin_name}")
            }
            crate::lsp::TypeHierarchyDirection::Subtypes => {
                format!("Subtypes — {origin_name}")
            }
        };
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Locations,
            title,
            items,
        ));
    }

    /// Handle `LspEvent::CallHierarchyPrepared` — fire the follow-up
    /// `{incoming,outgoing}Calls`. Single item: dispatch directly.
    /// Multi-item (overloaded fn / cursor straddles symbols): open a
    /// `CallHierarchyItems` picker so the user can disambiguate.
    fn apply_call_hierarchy_prepared(
        &mut self,
        direction: crate::lsp::CallHierarchyDirection,
        items: Vec<crate::lsp::CallHierarchyItem>,
    ) {
        if items.is_empty() {
            self.toast("call hierarchy: nothing under cursor");
            return;
        }
        if items.len() == 1 {
            let item = items.into_iter().next().unwrap();
            match direction {
                crate::lsp::CallHierarchyDirection::Incoming => {
                    self.lsp.call_hierarchy_incoming(&item);
                }
                crate::lsp::CallHierarchyDirection::Outgoing => {
                    self.lsp.call_hierarchy_outgoing(&item);
                }
            }
            self.pending_call_hierarchy_items = vec![item];
            return;
        }
        // Multi-item — stash for the picker to look up by index on accept.
        let dir_tag = match direction {
            crate::lsp::CallHierarchyDirection::Incoming => "in",
            crate::lsp::CallHierarchyDirection::Outgoing => "out",
        };
        let picker_items: Vec<crate::picker::PickerItem> = items
            .iter()
            .enumerate()
            .map(|(i, it)| {
                let rel = it
                    .path
                    .strip_prefix(&self.workspace)
                    .unwrap_or(it.path.as_path())
                    .to_string_lossy()
                    .to_string();
                let detail = format!("{}:{}", rel, it.line + 1);
                crate::picker::PickerItem {
                    id: format!("{i}\t{dir_tag}"),
                    label: it.name.clone(),
                    detail,
                }
            })
            .collect();
        self.pending_call_hierarchy_items = items;
        let title = match direction {
            crate::lsp::CallHierarchyDirection::Incoming => "Incoming calls — pick symbol",
            crate::lsp::CallHierarchyDirection::Outgoing => "Outgoing calls — pick symbol",
        };
        self.picker = Some(crate::picker::Picker::new(
            crate::picker::PickerKind::CallHierarchyItems,
            title,
            picker_items,
        ));
    }

    /// Handle `LspEvent::CallHierarchyCalls` — open the call sites as a
    /// `PickerKind::Locations` picker so accept jumps to the source line.
    fn apply_call_hierarchy_calls(
        &mut self,
        direction: crate::lsp::CallHierarchyDirection,
        origin_name: String,
        hits: Vec<crate::lsp::CallHit>,
    ) {
        if hits.is_empty() {
            let label = match direction {
                crate::lsp::CallHierarchyDirection::Incoming => "incoming",
                crate::lsp::CallHierarchyDirection::Outgoing => "outgoing",
            };
            self.toast(format!("call hierarchy: no {label} calls"));
            return;
        }
        let items: Vec<crate::picker::PickerItem> = hits
            .into_iter()
            .map(|h| {
                let rel = h
                    .path
                    .strip_prefix(&self.workspace)
                    .unwrap_or(h.path.as_path())
                    .to_string_lossy()
                    .to_string();
                let id = format!("{}\t{}\t{}", h.path.display(), h.line, h.character);
                let label = format!("{}  {}", h.name, rel);
                let detail = format!("{}:{}", h.line + 1, h.character + 1);
                crate::picker::PickerItem::new(id, label, detail)
            })
            .collect();
        let title = match direction {
            crate::lsp::CallHierarchyDirection::Incoming => {
                format!("Incoming calls — {origin_name}")
            }
            crate::lsp::CallHierarchyDirection::Outgoing => {
                format!("Outgoing calls — {origin_name}")
            }
        };
        self.open_picker(crate::picker::Picker::new(
            crate::picker::PickerKind::Locations,
            title,
            items,
        ));
    }

    /// `lsp.highlight_symbol` — fire `textDocument/documentHighlight` at the
    /// cursor; the reply tints every same-symbol usage with `bg2`. Scope-
    /// aware (unlike the text-match `highlight_word_under_cursor`). Refresh
    /// on demand only — wiring it into every cursor move would chatter the
    /// server.
    pub fn lsp_highlight_symbol(&mut self) {
        self.lsp_request_at_cursor(
            |lsp, p, l, c| lsp.document_highlight(p, l, c),
            "document-highlight",
        );
    }

    /// `lsp.clear_highlights` — drop the active buffer's highlight set.
    pub fn lsp_clear_highlights(&mut self) {
        if let Some(b) = self.active_editor_mut() {
            b.document_highlights.clear();
        }
    }

    /// `lsp.selection_expand` — vim-style smart-expand selection. First
    /// press fires `textDocument/selectionRange` at the cursor; subsequent
    /// presses walk up the ladder of server-supplied semantic ranges
    /// (token → expression → statement → block → function → …). Reply
    /// arrives async — see `apply_selection_ranges`.
    pub fn lsp_selection_expand(&mut self) {
        if let Some(l) = &mut self.selection_range_ladder
            && Some(l.pane) == self.active
            && l.current + 1 < l.ranges.len()
        {
            l.current += 1;
            let (start, end) = l.ranges[l.current];
            self.apply_selection_range_to_active(start, end);
            return;
        }
        self.lsp_request_at_cursor(
            |lsp, p, l, c| lsp.selection_range(p, l, c),
            "selection-range",
        );
    }

    /// `lsp.selection_shrink` — inverse of expand. Walks back down the
    /// ladder. No-op when there's no ladder or we're at the smallest range.
    pub fn lsp_selection_shrink(&mut self) {
        let Some(l) = &mut self.selection_range_ladder else {
            self.toast("no selection ladder — expand first");
            return;
        };
        if Some(l.pane) != self.active {
            self.toast("selection ladder belongs to a different pane");
            return;
        }
        if l.current == 0 {
            self.toast("already at smallest selection");
            return;
        }
        l.current -= 1;
        let (start, end) = l.ranges[l.current];
        self.apply_selection_range_to_active(start, end);
    }

    /// Install server-supplied selection ranges as a ladder and apply the
    /// smallest one (`current = 0`). Subsequent expand calls walk up.
    fn apply_selection_ranges(&mut self, path: &Path, ranges: Vec<(u32, u32, u32, u32)>) {
        if ranges.is_empty() {
            self.toast("no selection ranges returned");
            return;
        }
        // Find the matching open buffer + convert LSP positions → byte offsets.
        let mut byte_ranges: Vec<(usize, usize)> = Vec::new();
        let mut pane_idx: Option<usize> = None;
        for (i, p) in self.panes.iter().enumerate() {
            if let Pane::Editor(b) = p
                && b.path.as_deref() == Some(path)
            {
                pane_idx = Some(i);
                let text = b.editor.text();
                for (s_line, s_char, e_line, e_char) in &ranges {
                    let (Some(start), Some(end)) = (
                        crate::lsp::byte_at(text, *s_line, *s_char),
                        crate::lsp::byte_at(text, *e_line, *e_char),
                    ) else {
                        continue;
                    };
                    if start < end {
                        byte_ranges.push((start, end));
                    }
                }
                break;
            }
        }
        let Some(pane) = pane_idx else {
            return;
        };
        if byte_ranges.is_empty() {
            self.toast("selection ranges out of range");
            return;
        }
        self.selection_range_ladder = Some(SelectionRangeLadder {
            path: path.to_path_buf(),
            pane,
            ranges: byte_ranges.clone(),
            current: 0,
        });
        let (start, end) = byte_ranges[0];
        self.apply_selection_range_to_active(start, end);
    }

    /// Apply a `(start, end)` byte range as a selection on the active editor:
    /// anchor = start, cursor = end (vim convention so motions extend right).
    fn apply_selection_range_to_active(&mut self, start: usize, end: usize) {
        let Some(idx) = self.active else {
            return;
        };
        let Some(Pane::Editor(b)) = self.panes.get_mut(idx) else {
            return;
        };
        b.editor.set_selection(start, end);
        b.input.request_visual_mode();
    }

    /// `lsp.on_type_format` — fire `textDocument/onTypeFormatting` at the
    /// cursor with the typed `trigger`. Reply lands as
    /// [`crate::lsp::LspEvent::Formatting`] and goes through the existing
    /// `apply_formatting_edits` path. Called from `tui::dispatch_key` only
    /// when `[editor] format_on_type` is true.
    pub fn lsp_on_type_format(&mut self, trigger: char) {
        let Some(b) = self.active_editor() else {
            return;
        };
        let Some(path) = b.path.clone() else {
            return;
        };
        let (row, col) = b.editor.row_col();
        let tab_size = self.config.editor.tab_width as u32;
        // mnml writes spaces (no tabs) for new indents — match that.
        self.lsp
            .on_type_formatting(&path, row as u32, col as u32, trigger, tab_size, true);
    }

    /// `lsp.fold_all` — ask the active buffer's language server for its
    /// suggested fold ranges (`textDocument/foldingRange`); when the reply
    /// arrives, `apply_folding_ranges` installs every range as a fold on
    /// the buffer. Works for languages where bracket-based folding doesn't
    /// (Python / YAML / etc.).
    pub fn lsp_fold_all(&mut self) {
        let Some(b) = self.active_editor() else {
            self.toast("no active editor");
            return;
        };
        let Some(path) = b.path.clone() else {
            self.toast("buffer has no path");
            return;
        };
        if !self.lsp.folding_range(&path) {
            self.toast("no language server for this buffer");
        }
    }

    /// Install server-supplied folding ranges on the matching open buffer.
    /// Toasts the count and replaces any existing bracket-based folds —
    /// the server's view is authoritative once requested.
    fn apply_folding_ranges(&mut self, path: &Path, ranges: Vec<(u32, u32)>) {
        if ranges.is_empty() {
            self.toast("no fold ranges returned");
            return;
        }
        let mut applied = 0usize;
        for p in self.panes.iter_mut() {
            if let Pane::Editor(b) = p
                && b.path.as_deref() == Some(path)
            {
                let line_count = b.editor.text().matches('\n').count() + 1;
                b.folds.clear();
                for (s, e) in &ranges {
                    let s = *s as usize;
                    let e = *e as usize;
                    if s >= line_count || e >= line_count || e <= s {
                        continue;
                    }
                    b.folds.insert(s, e);
                    applied += 1;
                }
                break;
            }
        }
        self.toast(format!("folded {applied} range(s)"));
    }

    /// Second stage of `save_active`: format-on-save → disk. Reached
    /// either directly (when `will_save_wait_until` is off) or after the
    /// wsw reply lands.
    pub(super) fn save_active_after_will_save(&mut self) {
        if self.config.editor.format_on_save
            && let Some(b) = self.active_editor()
            && let Some(path) = b.path.clone()
        {
            let tab_size = self.config.editor.tab_width as u32;
            if self.lsp.formatting(&path, tab_size, true) {
                self.pending_format_save = Some((
                    path,
                    std::time::Instant::now() + std::time::Duration::from_millis(2000),
                ));
                return;
            }
        }
        self.save_active_now();
    }

    /// Scroll-driven viewport refresh for `[editor]
    /// semantic_tokens_viewport`. For every open editor pane whose
    /// current viewport diverges from `last_semantic_viewport` by more
    /// than [`Self::VIEWPORT_REFIRE_THRESHOLD`] lines, fire a fresh
    /// `semanticTokens/range` covering the new viewport. Cheap: a
    /// no-op when the flag is off or every buffer's viewport is still
    /// inside the cached one.
    pub(super) fn refresh_scroll_semantic_tokens(&mut self) {
        if !self.config.editor.semantic_tokens_viewport {
            return;
        }
        // Collect target (path, viewport) pairs without holding any
        // &mut on panes — we want to consult `app.rects` (immutable
        // borrow) and then mutate the matching buffer afterward.
        let mut refire: Vec<(PathBuf, (u32, u32))> = Vec::new();
        for p in self.panes.iter() {
            let Pane::Editor(b) = p else { continue };
            let Some(path) = b.path.clone() else { continue };
            let Some(new_vp) = self.semantic_tokens_viewport_for(&path) else {
                continue;
            };
            let stale = match b.last_semantic_viewport {
                Some((s, e)) => {
                    new_vp.0.abs_diff(s) > Self::VIEWPORT_REFIRE_THRESHOLD
                        || new_vp.1.abs_diff(e) > Self::VIEWPORT_REFIRE_THRESHOLD
                }
                None => true,
            };
            if stale {
                refire.push((path, new_vp));
            }
        }
        for (path, viewport) in refire {
            let line_count = self
                .panes
                .iter()
                .find_map(|p| match p {
                    Pane::Editor(b) if b.path.as_deref() == Some(path.as_path()) => {
                        Some(b.editor.line_count() as u32)
                    }
                    _ => None,
                })
                .unwrap_or(0);
            self.lsp.semantic_tokens(&path, line_count, Some(viewport));
            if let Some(b) = self.panes.iter_mut().find_map(|p| match p {
                Pane::Editor(b) if b.path.as_deref() == Some(path.as_path()) => Some(b),
                _ => None,
            }) {
                b.last_semantic_viewport = Some(viewport);
            }
        }
    }
}

#[cfg(test)]
mod lsp_tests {
    use super::*;
    use std::fs;

    #[test]
    fn code_action_reply_opens_picker_and_apply_runs_edits() {
        // No LSP server needed — we drive `apply_code_action_reply` directly
        // with synthesized actions, then walk the picker → `apply_code_action`
        // path to confirm the edit is applied to an open buffer.
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("x.rs"), "let x = 1;\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        let path = app.workspace.join("x.rs");
        app.open_path(&path);

        // Build a fake code-action reply: a single quickfix that replaces
        // "let x = 1;" with "let y = 1;".
        let edit_range = crate::lsp::Range {
            start: crate::lsp::Pos {
                line: 0,
                character: 4,
            },
            end: crate::lsp::Pos {
                line: 0,
                character: 5,
            },
        };
        let action = crate::lsp::CodeAction {
            title: "rename x → y".into(),
            kind: Some("quickfix".into()),
            edit: Some(vec![(path.clone(), vec![(edit_range, "y".into())])]),
            command: None,
            raw: None,
        };
        app.apply_code_action_reply(vec![action]);

        // The picker should be open + populated.
        let pk = app.picker.as_ref().expect("picker opened");
        assert_eq!(pk.kind, crate::picker::PickerKind::CodeActions);
        assert_eq!(pk.len(), 1);
        // No items selected matter (only one) — accept it.
        app.picker_accept();

        // The open editor should reflect the edit (left dirty for review).
        let b = app.active_editor().unwrap();
        assert_eq!(b.editor.text(), "let y = 1;\n");
        assert!(b.dirty);
    }

    #[test]
    fn lsp_rename_arms_preview_state() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("a.txt"), "alpha beta alpha\n").unwrap();
        let mut app = App::new(d.path().to_path_buf(), Config::default()).unwrap();
        app.open_path(&d.path().join("a.txt"));
        // Place cursor inside the first "alpha".
        if let Some(pid) = app.active
            && let Some(Pane::Editor(b)) = app.panes.get_mut(pid)
        {
            b.editor.place_cursor(0, 1);
        }
        app.lsp_rename();
        let state = app
            .rename_preview_state
            .as_ref()
            .expect("preview should be armed");
        assert_eq!(state.original_word, "alpha");
        assert_eq!(state.occurrences.len(), 2);
        // The prompt should also be open with the seeded word.
        let prompt = app.prompt.as_ref().expect("prompt should be open");
        assert_eq!(prompt.input, "alpha");
        // Cancel — preview should clear.
        app.prompt_cancel();
        assert!(app.rename_preview_state.is_none());
    }
}
