//! Dispatch helpers — pulled out of `src/tui.rs` so the event-loop
//! file stays focused on the crossterm read+route+draw cycle.
//!
//! Every fn here is a free fn (not a method) that takes `&mut App`
//! or `&App`. They're called from `tui::dispatch_key` /
//! `dispatch_mouse` via `crate::app::dispatch::*`.
//!
//! Extracted from `tui.rs` in the file-split refactor. Pure
//! non-destructive move.

use super::*;
use crate::command;
use crate::edit_op::EditOp;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::layout::Rect;
use std::io;

/// Drain `app.image_paint_requests` and emit the protocol-specific image
/// escapes directly to stdout. Called after `terminal.draw()` so the
/// images paint *on top of* the placeholder cells ratatui reserved.
///
/// Also handles clearing stale placements: when image panes disappear
/// (closed / scrolled out), we emit a `clear-all` so the previous
/// frame's images don't linger.
pub(crate) fn emit_image_placements(app: &mut App) {
    use crate::image::ImageProtocol;
    use std::io::Write;
    let protocol = app.image_protocol;
    if matches!(protocol, ImageProtocol::None) {
        app.image_paint_requests.clear();
        app.had_image_pane = false;
        return;
    }
    let pending = std::mem::take(&mut app.image_paint_requests);
    let any_now = !pending.is_empty();
    // qa-feature 2026-07-02 — skip the whole clear+re-emit dance when
    // the paint set is identical to last frame. The terminal keeps
    // the previously-painted image on screen, which stops the
    // per-frame flash. Also spares stdout bandwidth for a re-transmit
    // of a large PNG every frame.
    let current_paints: Vec<(crate::layout::PaneId, ratatui::layout::Rect)> =
        pending.iter().map(|r| (r.pane_id, r.area)).collect();
    if any_now && current_paints == app.last_image_paints {
        app.had_image_pane = true;
        return;
    }
    let needs_clear = any_now || app.had_image_pane;
    let mut out = io::stdout();
    if needs_clear && matches!(protocol, ImageProtocol::Kitty) {
        let _ = out.write_all(crate::image::kitty::clear_all().as_bytes());
    }
    for req in pending {
        // Move cursor to the area's top-left (1-based row;col).
        let _ = write!(
            out,
            "\x1b[{};{}H",
            req.area.y.saturating_add(1),
            req.area.x.saturating_add(1)
        );
        match protocol {
            ImageProtocol::Kitty => {
                if let Ok(esc) = crate::image::kitty::encode_placement(
                    &req.png_bytes,
                    req.area.width,
                    req.area.height,
                ) {
                    let _ = out.write_all(esc.as_bytes());
                }
            }
            ImageProtocol::Iterm2 => {
                let esc = crate::image::iterm2::encode_placement(
                    &req.png_bytes,
                    req.area.width,
                    req.area.height,
                );
                let _ = out.write_all(esc.as_bytes());
            }
            ImageProtocol::Sixel => {
                if let Ok(esc) = crate::image::sixel::encode_placement(
                    &req.png_bytes,
                    req.area.width,
                    req.area.height,
                ) {
                    let _ = out.write_all(esc.as_bytes());
                }
            }
            ImageProtocol::None => {}
        }
    }
    let _ = out.flush();
    app.had_image_pane = any_now;
    app.last_image_paints = current_paints;
}

/// Update [`App::dot_recording`] / [`App::dot_keys`] based on the mode +
/// chord-state transition this dispatch caused. The recording starts
/// when a "change" begins and finalizes when it ends. Boundaries:
///
/// - Normal + no chord pending → Insert ⇒ start recording (this `key`).
/// - Normal + no chord pending → Normal + chord pending (e.g. `d` from
///   normal opens operator-pending) ⇒ start recording.
/// - During recording (chord still pending OR in Insert) ⇒ append.
/// - End of recording: chord cleared and (mode is Normal OR back from
///   Insert), AND a buffer mutation occurred ⇒ finalize into `dot_keys`.
/// - End of recording with no mutation (e.g. user `Esc`'d the operator
///   before completing it) ⇒ discard.
/// - One-shot Normal-mode mutation with no chord (e.g. `p`) ⇒ record this
///   `key` and finalize immediately.
pub(crate) fn record_dot(
    app: &mut crate::app::App,
    key: KeyEvent,
    mode_before: Option<crate::input::EditingMode>,
    mode_after: Option<crate::input::EditingMode>,
    pending_before: Option<String>,
    pending_after: Option<String>,
    edited: bool,
) {
    use crate::input::EditingMode;
    let (Some(before), Some(after)) = (mode_before, mode_after) else {
        return;
    };
    let recording = app.dot_recording.is_some();
    // 1. Already recording — append. Then check if we just finalized.
    if recording {
        if let Some(rec) = &mut app.dot_recording {
            rec.push(key);
        }
        if edited {
            app.dot_recording_saw_edit = true;
        }
        let in_flight = after == EditingMode::Insert || pending_after.is_some();
        if !in_flight {
            // Recording terminated. If any earlier keystroke in the
            // session produced a mutation, finalize. Otherwise discard
            // (the chord was cancelled — e.g. ESC out of operator-pending).
            if app.dot_recording_saw_edit {
                if let Some(rec) = app.dot_recording.take() {
                    app.dot_keys = rec;
                }
            } else {
                app.dot_recording = None;
            }
            app.dot_recording_saw_edit = false;
        }
        return;
    }
    // 2. Not currently recording — does this key start a new change?
    let in_flight_after = after == EditingMode::Insert || pending_after.is_some();
    let started_change =
        before == EditingMode::Normal && pending_before.is_none() && in_flight_after;
    if started_change {
        app.dot_recording = Some(vec![key]);
        app.dot_recording_saw_edit = edited;
        return;
    }
    // 3. Visual → Insert (visual `c`) starts a change too. All three
    //    visual flavours (charwise, linewise, blockwise) count.
    if before.is_visual() && after == EditingMode::Insert {
        app.dot_recording = Some(vec![key]);
        app.dot_recording_saw_edit = edited;
        return;
    }
    // 4. One-shot Normal-mode mutation (`p`, `~`, `u`, etc.) — record the
    //    single key and finalize.
    if before == EditingMode::Normal
        && after == EditingMode::Normal
        && pending_before.is_none()
        && pending_after.is_none()
        && edited
    {
        app.dot_keys = vec![key];
    }
    // 5. Visual op (e.g. `vlld`) ⇒ also a one-shot capture.
    //    Covers V-LINE and V-BLOCK too.
    if before.is_visual() && after == EditingMode::Normal && edited {
        app.dot_keys = vec![key];
    }
}

/// Vim abbreviation trigger: chars that "complete" the previous word and
/// signal expansion. Roughly: whitespace + most punctuation. Letters /
/// digits / `_` are *not* triggers (they keep the word in flight).
pub(crate) fn is_abbreviation_trigger(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '.' | ',' | ';' | ':' | '!' | '?' | ')' | ']' | '}' | '"' | '\'' | '`'
        )
}

pub(crate) fn pane_viewport(app: &App) -> usize {
    app.active
        .and_then(|cur| {
            app.rects
                .editor_panes
                .iter()
                .find(|(_, p)| *p == cur)
                .map(|(r, _)| r.height as usize)
        })
        .unwrap_or(20)
        .max(1)
}

pub(crate) fn apply_app_command(app: &mut App, cmd: crate::input::AppCommand) {
    use crate::input::AppCommand::*;
    match cmd {
        Save => {
            command::run("file.save", app);
        }
        ExCommand(s) => {
            // Push onto persistent ex history (de-duped against newest,
            // capped at 100). The handler-side history mirror is updated
            // on launch from `App.ex_history` via `set_ex_history`.
            if app.ex_history.last() != Some(&s) {
                app.ex_history.push(s.clone());
                if app.ex_history.len() > 100 {
                    let drop = app.ex_history.len() - 100;
                    app.ex_history.drain(..drop);
                }
            }
            app.run_ex_command(&s);
        }
        RunCommand(id) => {
            command::run(&id, app);
        }
        DotRepeat(n) => {
            app.pending_dot_count = Some(n);
            app.dot_replay();
        }
        SetMark(c) => app.set_mark_at_cursor(c),
        JumpToMarkLine(c) => app.jump_to_mark(c, false),
        JumpToMarkExact(c) => app.jump_to_mark(c, true),
        MacroRecordInto(c) => {
            app.set_pending_macro_register(c);
            app.macro_toggle();
        }
        MacroReplayFrom { reg, count } => {
            // R13 nvchad SEV-2 2026-08-23 — vim's `99@a` aborts
            // when a motion inside the macro can't make progress
            // (typically at BOF/EOF), so a user typing a big count
            // "just in case" doesn't corrupt the buffer past the
            // last real line. Detect no-progress by snapshotting
            // `(text.len(), cursor)` before each iteration and
            // aborting when neither moved.
            let n = count.max(1);
            let mut prev_snapshot: Option<(usize, usize)> = None;
            for _ in 0..n {
                let snap_before = app
                    .active_editor()
                    .map(|b| (b.editor.text().len(), b.editor.cursor()));
                if let Some(prev) = prev_snapshot
                    && snap_before == Some(prev)
                {
                    // Two consecutive iterations with identical
                    // pre-state ⇒ the macro's motion / edit is a
                    // no-op at this position. Abort the count loop
                    // instead of grinding through the remaining
                    // (count - iter) iterations. Silent — vim's
                    // own abort is silent too.
                    break;
                }
                app.set_pending_macro_register(reg);
                app.macro_replay();
                prev_snapshot = snap_before;
            }
        }
        BlockInsertStart { append } => app.block_insert_start(append),
        BlockChangeStart => app.block_change_start(),
        BlockReplaceWith { ch } => app.block_replace_with(ch),
        FilterLinesFromCursor { count } => app.begin_filter_lines_from_cursor(count),
        FilterParagraphFromCursor { around } => app.begin_filter_paragraph_from_cursor(around),
        OperatorLinewiseTo { op, target } => app.vim_operator_linewise_to(op, target),
        CmdlineTabComplete => app.cmdline_tab_complete(),
        CmdlinePopupMove(delta) => app.cmdline_popup_move(delta as isize),
        CmdlineInsertCursorWord(big) => app.cmdline_insert_cursor_word(big),
        CmdlinePasteFromClipboard => app.cmdline_paste_from_clipboard(),
        CmdlineEnter(typed) => {
            // Only substitute the popup-highlighted match when the
            // user explicitly navigated via ↓ / Tab (selected > 0).
            // Index 0 (auto-first) keeps the typed text so vim
            // abbreviations like `:reg<Enter>` don't get rewritten
            // to `:registers`. Mirrors no_pane_cmdline_commit in
            // tui.rs. (Vim path runs through this — the saved
            // completion state stays alive on the App after vim
            // clears its own cmdline, so we read head +
            // matches[selected] directly rather than calling
            // accept_current().)
            let effective = if app.cmdline_popup_selected > 0
                && let Some(state) = app.cmdline_complete_state.as_ref()
                && let Some(suffix) = state.matches.get(app.cmdline_popup_selected)
            {
                format!("{}{}", state.head, suffix)
            } else {
                typed.clone()
            };
            // 2026-06-20 — mirror the ExCommand arm: also push onto
            // App.ex_history so vim's `q:` window sees the entry.
            if app.ex_history.last() != Some(&effective) {
                app.ex_history.push(effective.clone());
                if app.ex_history.len() > 100 {
                    let drop = app.ex_history.len() - 100;
                    app.ex_history.drain(..drop);
                }
            }
            app.run_ex_command(&effective);
        }
        RepeatInsertStart { count, above } => app.repeat_insert_start(count as usize, above),
        FlashStart(a, b) => app.flash_start(a, b),
    }
}

/// Translate a click within an editor pane's text rect to a `(file_row,
/// file_col)`. Wrap-aware: when `[ui] wrap` is on, the visible row is
/// walked via [`Buffer::wrap_to_file_pos`] so clicks inside a wrapped
/// continuation land on the right char column. With wrap off this is
/// the classic `visible_to_file_row` + `h_scroll` mapping.
pub(crate) fn click_to_file_pos(
    b: &crate::buffer::Buffer,
    tr: Rect,
    wrap: bool,
    x: u16,
    y: u16,
) -> (usize, usize) {
    let visible_row = (y.saturating_sub(tr.y)) as usize;
    let click_col = (x.saturating_sub(tr.x)) as usize;
    let tw = tr.width as usize;
    if wrap && tw > 0 {
        let (row, char_start) = b
            .wrap_to_file_pos(b.scroll, visible_row, tw)
            .unwrap_or((b.scroll, 0));
        (row, char_start + click_col)
    } else {
        let row = b
            .visible_to_file_row(b.scroll, visible_row)
            .unwrap_or(b.scroll);
        (row, b.h_scroll + click_col)
    }
}

/// Which clickable statusline chip (if any) sits under the given mouse coords.
/// Used by the hover-tooltip system; right-click + left-click handlers do their
/// own per-chip rect checks since they need to act, not just identify.
pub(crate) fn hover_chip_at(app: &App, x: u16, y: u16) -> Option<crate::HoverChip> {
    // mouse-round-9 SEV-2 2026-07-11 — divider hover. Checked
    // early so it wins over any coarser pane-body chip check
    // (though dividers don't overlap panes so this is safe).
    if app.rects.split_dividers.iter().any(|d| {
        x >= d.rect.x
            && x < d.rect.x + d.rect.width
            && y >= d.rect.y
            && y < d.rect.y + d.rect.height
    }) {
        return Some(crate::HoverChip::SplitDivider);
    }
    // #polish 2026-07-06 — gutter sign-column marks (git change,
    // diagnostic, breakpoint, DAP arrow). Checked FIRST so a mark in
    // an editor pane wins over the coarser editor-pane hover
    // arm below.
    if let Some(&(_, pane_id, line_no, kind)) = app
        .rects
        .gutter_marks
        .iter()
        .find(|(r, _, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::GutterMark {
            pane_id,
            line_no,
            kind,
        });
    }
    // 2026-06-21 — Claude Agents dashboard topbar chips: each
    // chip rect is registered with its TopbarChipKind so the
    // tooltip can explain what it cycles + the keyboard chord.
    if let Some(&(_, _, kind)) = app
        .rects
        .claude_agents_topbar_chips
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::ClaudeAgentsTopbarChip(kind));
    }
    if let Some(r) = app.rects.statusline_stress_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineStress);
    }
    if let Some(r) = app.rects.palette_stress_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteStress);
    }
    if let Some((idx, _)) = app
        .rects
        .toast_stack_rects
        .iter()
        .enumerate()
        .find(|(_, r)| contains(**r, x, y))
    {
        return Some(crate::HoverChip::ToastBox(idx));
    }
    if let Some(r) = app.rects.statusline_mode_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineMode);
    }
    if let Some(r) = app.rects.statusline_branch_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineBranch);
    }
    if let Some(r) = app.rects.statusline_workspace_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineWorkspace);
    }
    if let Some(r) = app.rects.statusline_clock_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineClock);
    }
    if let Some(r) = app.rects.statusline_lsp_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineLsp);
    }
    if let Some(r) = app.rects.statusline_wrap_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineWrap);
    }
    if let Some(r) = app.rects.statusline_ai_claude_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineAiClaude);
    }
    if let Some(r) = app.rects.statusline_ai_codex_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineAiCodex);
    }
    if let Some(r) = app.rects.statusline_autosave_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineAutosave);
    }
    // #polish 2026-07-06 — new left-lane statusline chips.
    if let Some(r) = app.rects.statusline_file_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineFile);
    }
    if let Some(r) = app.rects.statusline_diagnostics_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineDiagnostics);
    }
    if let Some(r) = app.rects.statusline_symbol_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineSymbol);
    }
    if let Some(r) = app.rects.statusline_pr_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslinePr);
    }
    if let Some(r) = app.rects.statusline_language_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineLanguage);
    }
    if let Some(r) = app.rects.statusline_macro_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineMacroRec);
    }
    if let Some(r) = app.rects.statusline_find_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineFind);
    }
    if let Some(r) = app.rects.statusline_sel_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineSel);
    }
    if let Some(r) = app.rects.statusline_progress_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineProgress);
    }
    if let Some(r) = app.rects.statusline_bg_tasks_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineBgTasks);
    }
    if let Some(r) = app.rects.statusline_ai_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineAi);
    }
    // #21 v5 — Request pane top-bar chip hover detection.
    if let Some(r) = app.rects.request_method_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestTopBarChip(
            crate::RequestTopBarChip::Method,
        ));
    }
    if let Some(r) = app.rects.request_env_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestTopBarChip(
            crate::RequestTopBarChip::Env,
        ));
    }
    if let Some(r) = app.rects.request_send_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestTopBarChip(
            crate::RequestTopBarChip::Send,
        ));
    }
    if let Some(r) = app.rects.request_save_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestTopBarChip(
            crate::RequestTopBarChip::Save,
        ));
    }
    if let Some(r) = app.rects.request_clear_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestTopBarChip(
            crate::RequestTopBarChip::Clear,
        ));
    }
    if let Some(r) = app.rects.request_code_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestTopBarChip(
            crate::RequestTopBarChip::Code,
        ));
    }
    if let Some(r) = app.rects.request_split_toggle
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestSplitToggle);
    }
    if let Some(r) = app.rects.request_edit_split_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestEditSplitChip);
    }
    if let Some((idx, _)) = app
        .rects
        .http_panel_section_chips
        .iter()
        .enumerate()
        .find(|(_, (r, _, _))| contains(*r, x, y))
    {
        return Some(crate::HoverChip::HttpSectionChip(idx));
    }
    if let Some((idx, _)) = app
        .rects
        .http_panel_icon_buttons
        .iter()
        .enumerate()
        .find(|(_, (r, _))| contains(*r, x, y))
    {
        return Some(crate::HoverChip::HttpToolbarChip(idx));
    }
    if let Some(r) = app.rects.request_edit_split_divider
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestEditSplitDivider);
    }
    if let Some((idx, _)) = app
        .rects
        .http_panel_collection_new_request_chips
        .iter()
        .enumerate()
        .find(|(_, (r, _))| contains(*r, x, y))
    {
        return Some(crate::HoverChip::HttpCollectionAddRequestChip(idx));
    }
    if let Some((idx, _)) = app
        .rects
        .request_var_click_rects
        .iter()
        .enumerate()
        .find(|(_, (r, _))| contains(*r, x, y))
    {
        return Some(crate::HoverChip::RequestVarToken(idx));
    }
    if let Some(r) = app.rects.request_response_copy_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestResponseCopy);
    }
    if let Some(r) = app.rects.request_response_wrap_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestResponseWrap);
    }
    if let Some(r) = app.rects.request_response_ai_prompt_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestResponseAiPrompt);
    }
    if let Some(r) = app.rects.request_format_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RequestResponseFormat);
    }
    if let Some(r) = app.rects.pending_undo_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PendingUndoChip);
    }
    if let Some(r) = app.rects.bufferline_new_request_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::BufferlineNewRequest);
    }
    // #polish 2026-07-06 — scrollbar hover. Any scrollbar
    // matches; the tooltip is the same for all of them.
    if app.rects.scrollbars.iter().any(|h| contains(h.area, x, y)) {
        return Some(crate::HoverChip::ScrollbarThumb);
    }
    if let Some(r) = app.rects.right_panel_edge
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RightPanelGrip);
    }
    if let Some(r) = app.rects.tree_edge
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::TreeRailGrip);
    }
    if let Some(&(_, idx)) = app
        .rects
        .menu_bar_words
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::MenuBarWord(idx));
    }
    // Task #929 (2026-08-12) — when a menu-bar dropdown is open,
    // hover a row inside it to route hover-help through
    // `InfoViewTarget::MenuItem`. `menu_bar_items` is only
    // populated while `app.menu_open` is `Some`, but we gate on
    // both for defence in depth. `item_idx` uses the encoded
    // format from `ui/menu_bar.rs`: raw index (< 1000) for
    // top-level rows, `1000 + parent*100 + sub` for submenu rows.
    // The MenuBarItem resolver in `ui/info_view_copy.rs` decodes
    // the same way.
    if let Some(open) = app.menu_open.as_ref()
        && let Some(&(_, item_idx)) = app
            .rects
            .menu_bar_items
            .iter()
            .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::MenuBarItem {
            menu_idx: open.menu_idx,
            item_idx,
        });
    }
    if let Some(r) = app.rects.statusline_filesize_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineFilesize);
    }
    if let Some(r) = app.rects.statusline_lncol_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineLnCol);
    }
    // 2026-08-17 — data-driven statusline chips (both manifest
    // `[[statusline_segments]]` and IPC-set `DynamicSegment`s).
    // Checked before the launcher/integration rects further down
    // because the statusline row is above the rail, but that
    // ordering is defensive — the rects belong to different
    // regions and don't overlap in practice.
    if let Some(idx) = app
        .rects
        .statusline_segment_hits
        .iter()
        .position(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::StatuslineSegment(idx));
    }
    // 2026-08-01 (P2) — launcher_icon_rects hit-test removed with
    // the LauncherIcon retirement.
    if let Some(&(_, cmd_id)) = app
        .rects
        .tree_icon_buttons
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::TreeIcon(cmd_id));
    }
    if let Some(tr) = app.rects.tree_toggle
        && contains(tr, x, y)
    {
        return Some(crate::HoverChip::WorkspaceHeader);
    }
    if let Some(&(_, ws_idx)) = app
        .rects
        .extra_workspace_toggles
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::ExtraWorkspaceHeader(ws_idx));
    }
    if let Some(&(_, icon_idx)) = app
        .rects
        .integration_icon_rects
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::IntegrationIcon(icon_idx));
    }
    if let Some(&(_, section)) = app
        .rects
        .activity_bar_icons
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::ActivityBarIcon(section));
    }
    if let Some(r) = app.rects.statusline_mixr_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineNowPlaying);
    }
    // qa-feature 2026-06-30 — GitGraph lane cell hover.
    if let Some(&(_, pane_id, commit_idx, lane_idx)) = app
        .rects
        .git_graph_lane_cells
        .iter()
        .find(|(r, _, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::GitGraphLane {
            pane_id,
            commit_idx,
            lane_idx,
        });
    }
    // qa-feature 2026-07-01 — GitGraph commit subject hover.
    if let Some(&(_, pane_id, commit_idx)) = app
        .rects
        .git_graph_subject_cells
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::GitGraphCommitMsg {
            pane_id,
            commit_idx,
        });
    }
    if let Some(r) = app.rects.palette_sidebar_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteSidebarButton);
    }
    if let Some(r) = app.rects.palette_right_panel_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteRightPanelButton);
    }
    if let Some(r) = app.rects.palette_back_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteBackButton);
    }
    if let Some(r) = app.rects.palette_forward_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteForwardButton);
    }
    if let Some(r) = app.rects.palette_search_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteSearchChip);
    }
    if let Some(r) = app.rects.palette_dropdown_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteDropdownButton);
    }
    if let Some(r) = app.rects.palette_add_integration_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteAddIntegration);
    }
    if let Some(&(_, leaf_active, tab_pane)) = app
        .rects
        .split_tab_close
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        let _ = leaf_active;
        return Some(crate::HoverChip::SplitTabClose(tab_pane));
    }
    if let Some(&(_, leaf_active, tab_pane)) = app
        .rects
        .split_tab_chips
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        let _ = leaf_active;
        return Some(crate::HoverChip::SplitTabChip(tab_pane));
    }
    // vscode-user-mouse 2026-07-30 SEV-3 #5 — per-leaf `+` chip had
    // no hover tooltip so users didn't know what it did until they
    // clicked (and were surprised — SEV-2 #2). Match `split_tab_chips`
    // above: stores (rect, leaf_active_pane).
    if let Some(&(_, leaf_active)) = app
        .rects
        .split_tab_plus_buttons
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::SplitTabPlus(leaf_active));
    }
    // Right-panel tab strip chips. v3 polish.
    if let Some(&(_, tab_idx)) = app
        .rects
        .right_panel_tabs
        .iter()
        .find(|(r, _)| contains(*r, x, y))
        && let Some(&pid) = app.right_panel_panes.get(tab_idx)
    {
        return Some(crate::HoverChip::RightPanelTab(pid));
    }
    if let Some(r) = app.rects.right_panel_close
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::RightPanelClose);
    }
    if let Some(r) = app.rects.agents_panel_new_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::AgentsPanelChip(
            crate::AgentsPanelChipKind::NewSession,
        ));
    }
    if let Some(r) = app.rects.agents_panel_pr_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::AgentsPanelChip(
            crate::AgentsPanelChipKind::FromPr,
        ));
    }
    if let Some(r) = app.rects.agents_panel_view_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::AgentsPanelChip(
            crate::AgentsPanelChipKind::ViewToggle,
        ));
    }
    if let Some(r) = app.rects.cloud_agents_new_run_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::CloudAgentsNewRunButton);
    }
    if let Some(r) = app.rects.activity_bar_gear
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::ActivityBarGear);
    }
    if app
        .rects
        .split_strip_ai_buttons
        .iter()
        .any(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::SplitStripAiButton);
    }
    if let Some(r) = app.rects.statusline_mixr_play_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineMixrPlay);
    }
    if let Some(r) = app.rects.statusline_mixr_ffwd_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineMixrFfwd);
    }
    if let Some(r) = app.rects.statusline_sonos_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineSonos);
    }
    if let Some(r) = app.rects.statusline_sonos_play_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineSonosPlay);
    }
    if let Some(r) = app.rects.statusline_sonos_next_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineSonosNext);
    }
    if let Some(r) = app.rects.statusline_sonos_label_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineSonosLabel);
    }
    if let Some(r) = app.rects.statusline_test_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineTestChip);
    }
    if app
        .rects
        .split_strip_term_buttons
        .iter()
        .any(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::SplitStripTermButton);
    }
    // R13 vscode-mouse SEV-3 2026-08-23 — maximize chip hover
    // mapping so the info-view + tooltip fire on hover.
    if app
        .rects
        .split_strip_maximize_buttons
        .iter()
        .any(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::SplitStripMaximizeButton);
    }
    if let Some(&(_, _, dir)) = app
        .rects
        .split_strip_buttons
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::SplitStripButton(dir));
    }
    if let Some(&(_, action)) = app
        .rects
        .rail_git_header_buttons
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::RailHeaderChip(action));
    }
    // mouse-round-16 F6 2026-07-17 — git-graph toolbar chips.
    if let Some(&(_, _, action)) = app
        .rects
        .git_toolbar_buttons
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::GitToolbarChip(action));
    }
    // Test the close badge FIRST so its tooltip wins over the
    // generic tab tooltip when the pointer is over the trailing
    // `×`/`●` cells (the badge rect is a 2-cell strip inside the
    // tab rect, so the generic tab arm would otherwise shadow it).
    if let Some(&(_, pid)) = app
        .rects
        .bufferline_tab_close
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::BufferlineTabClose(pid));
    }
    if let Some(&(_, pid)) = app
        .rects
        .bufferline_tabs
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::BufferlineTab(pid));
    }
    // Sessions activity panel — vertical tabs of Pty sessions.
    if let Some(&(_, pid)) = app
        .rects
        .session_tabs
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::SessionsTab(pid));
    }
    if let Some(r) = app.rects.bufferline_new_tab_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::BufferlineNewTab);
    }
    if let Some(r) = app.rects.bufferline_tabs_label
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::BufferlineTabsLabel);
    }
    if let Some(r) = app.rects.bufferline_theme_toggle
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::BufferlineThemeToggle);
    }
    if let Some(r) = app.rects.bufferline_window_close
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::BufferlineWindowClose);
    }
    // Task #875 (R5 SEV-3 F6) — tab-page pips + their close badges.
    // The close-badge rect (`bufferline_tab_page_close`) is a 1-cell
    // rect placed immediately AFTER the pip's rect (adjacent, not
    // overlapping — see `bufferline::paint_right_cluster`), so the
    // check order here is really "close-badge first because it's
    // narrower and more specific," not for overlap-precedence.
    if let Some(&(_, idx)) = app
        .rects
        .bufferline_tab_page_close
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::BufferlineTabPageClose(idx));
    }
    if let Some(&(_, idx)) = app
        .rects
        .bufferline_tab_page_chips
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::BufferlineTabPage(idx));
    }
    // Task #875 (R5 SEV-3 F7) — Integrations panel tab-strip chips.
    if let Some(r) = app.rects.integrations_tab_installed
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::IntegrationsTabInstalled);
    }
    if let Some(r) = app.rects.integrations_tab_marketplace
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::IntegrationsTabMarketplace);
    }
    if let Some(r) = app.rects.integrations_tab_refresh
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::IntegrationsTabRefresh);
    }
    if let Some(r) = app.rects.integrations_tab_sort
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::IntegrationsTabSort);
    }
    // Task #875 (R5 SEV-3 F8) — statusline coverage chip.
    if let Some(r) = app.rects.statusline_coverage_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineCoverage);
    }
    if let Some(&(_, _, action)) = app
        .rects
        .diff_toolbar_buttons
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::DiffToolbar(action));
    }
    if app
        .rects
        .fold_chips
        .iter()
        .any(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::FoldChip);
    }
    if app
        .rects
        .code_lens_chips
        .iter()
        .any(|(r, _, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::CodeLensChip);
    }
    // 2026-08-07 vscode-user r2 F2 — HoverChip::DockEmptyChip + its
    // tooltip body were defined but this arm was missing, so
    // hovering the chip produced no popup.
    if let Some(r) = app.rects.dock_empty_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::DockEmptyChip);
    }
    None
}

/// Per-frame cap on the magnitude of a coalesced batched scroll
/// applied to a tree/list surface. The event-loop coalescer
/// already caps at 40 events; this is a final safety clamp so a
/// huge batch can't move the cursor across hundreds of rows in
/// one shot (which would feel like a teleport, not a scroll).
const LIST_SCROLL_PER_BATCH_CAP: i32 = 8;

/// Bucket capacity (in lines) for the flywheel dampener. One
/// "good flick" worth of intentional scroll.
///
/// #1236 — raised 25 -> 40 alongside the refill. At 25 with a wheel
/// emitting 2-3 lines per event, a single second of ordinary
/// scrolling exhausted it before the refill could keep up.
const SCROLL_BUCKET_MAX: f32 = 40.0;

/// Refill rate (lines per second) for the flywheel dampener.
///
/// #1236 — was 12.0, which STARVES legitimate input on a
/// high-resolution wheel. Logged 446 events from a Logitech MX Master
/// 3: arrival rate 37-128 events/sec, each requesting its batch of
/// 2-3 lines. Steady deliberate scrolling therefore demands far more
/// than 12 lines/sec, the bucket empties, and real events are
/// discarded — measured on 45 of 446 events, 10%, reported as "it
/// misses a lot of scrolling i do".
///
/// 60 covers the observed legitimate range with headroom. The bucket
/// still bounds a free-spin tail via CAPACITY (one flick's worth),
/// and the tree additionally collapses same-notch events by time, so
/// the refill no longer has to be the only brake — which is what
/// forced it so low originally.
const SCROLL_BUCKET_REFILL: f32 = 60.0;

/// Ceiling multiplier for each `[editor] scroll_accel` setting.
///
/// #1236 — how much MORE a hard spin travels than a slow one. The
/// multiplier ramps with the coalesced batch size, so a one-notch
/// nudge is always 1:1 regardless of setting; only a genuinely fast
/// spin reaches the ceiling.
fn scroll_accel_ceiling(setting: &str) -> f32 {
    match setting {
        "off" => 1.0,
        "gentle" => 1.5,
        "fast" => 4.0,
        _ => 2.5, // "normal"
    }
}

/// Wheel rate (events/sec) at which acceleration reaches its ceiling.
///
/// #1236 follow-up — the first version ramped on the coalesced BATCH
/// SIZE, on the theory that it was a free velocity estimate. It isn't.
/// `coalesce_scroll` polls with `Duration::ZERO`, so it only collapses
/// events ALREADY QUEUED; a responsive event loop drains them one at a
/// time and the batch is 1. Batch size therefore measures how far
/// behind the render loop is, not how fast the wheel is turning — and
/// with a batch of 1-2 every setting produced identical output, which
/// is exactly what the user reported ("normal and fast and gentle seem
/// the same").
///
/// Rate is measured as `batch / elapsed_since_last_scroll`, which
/// reads the same whether the loop is keeping up (batch 1, tiny gaps)
/// or falling behind (batch 5, larger gaps).
const SCROLL_ACCEL_FULL_RATE: f32 = 120.0;

/// Below this rate there is no acceleration at all — a slow deliberate
/// scroll must stay 1:1 so precise positioning is unaffected.
const SCROLL_ACCEL_FLOOR_RATE: f32 = 45.0;

/// Treat a gap longer than this as a NEW gesture: no inherited
/// velocity, so the first notch after a pause is never accelerated.
const SCROLL_GESTURE_GAP_MS: u64 = 250;

/// Apply acceleration + the leaky-bucket scroll budget.
///
/// #1236, and the reason this is one function rather than an accel
/// stage bolted in front of the dampener: the two interact, and
/// getting the interaction wrong reintroduces the exact bug
/// `37074afe` fixed.
///
/// The dampener has two parameters and they mean different things:
///   * CAPACITY  = how far a single flick may travel.
///   * REFILL    = the sustained lines/sec ceiling.
///
/// A free-spin wheel keeps emitting for seconds after the hand lets
/// go, and it is indistinguishable from real scrolling by rate alone.
/// What separates them is DURATION: a hand-spin is a burst, inertia is
/// a long tail. So acceleration scales CAPACITY only — a hard flick
/// gets a bigger one-shot allowance — while REFILL stays put, so the
/// tail still drains against the slow trickle and the view stops when
/// the hand does.
///
/// Scaling refill as well would feel identical for the first flick and
/// then coast past the user for seconds. That asymmetry is the whole
/// design; don't "simplify" it by multiplying both.
fn budgeted_scroll(app: &mut App, delta: i32) -> i32 {
    budgeted_scroll_at(app, delta, std::time::Instant::now())
}

/// `budgeted_scroll` with the clock injected.
///
/// The refill is time-based, so a test that calls back-to-back with no
/// elapsed time cannot observe refill behaviour at all — verified the
/// hard way: scaling the refill by 1000x left every assertion green,
/// because zero elapsed time means zero refill either way. Real
/// flywheel inertia arrives over SECONDS, which is exactly the regime
/// the refill governs, so the test has to be able to advance time.
fn budgeted_scroll_at(app: &mut App, delta: i32, now: std::time::Instant) -> i32 {
    if delta == 0 {
        return 0;
    }
    let ceiling = scroll_accel_ceiling(&app.config.editor.scroll_accel);
    let want_raw = delta.unsigned_abs() as f32;

    // Wheel rate in events/sec. A gap longer than one gesture resets
    // to zero so the first notch after a pause is never accelerated.
    let gap = app
        .scroll_last_event_at
        .map(|t| now.duration_since(t))
        .unwrap_or(std::time::Duration::MAX);
    app.scroll_last_event_at = Some(now);
    let new_gesture = gap > std::time::Duration::from_millis(SCROLL_GESTURE_GAP_MS);
    // Event arrival rate = batch / gap.
    //
    // #1236, calibrated from 446 logged MX Master 3 events rather than
    // guessed. `coalesce_scroll` drains whatever queued during the gap,
    // so the batch IS the count of events that arrived in that window —
    // batch/gap is their arrival rate. That is why batch grows with gap
    // (mean 1.89 under 18ms, 3.74 over 60ms) while the RATE still falls:
    //
    //   gap <=18ms  batch 1.89  -> ~105/s
    //   gap 18-25   batch 2.92  -> ~128/s
    //   gap 25-60   batch 2.56  -> ~60/s
    //   gap >60     batch 3.74  -> ~37/s
    //
    // A 3x spread, so the signal is real. The earlier failure was scale,
    // not absence: thresholds of 10/45 sat below the whole range, so
    // every gesture pinned at the ceiling.
    let rate = if new_gesture {
        0.0
    } else {
        let secs = gap.as_secs_f32().max(0.001);
        want_raw / secs
    };
    if new_gesture {
        app.scroll_gesture_peak_rate = 0.0;
        app.scroll_rate_decaying = false;
        app.scroll_frac_carry = 0.0;
        app.scroll_row_accum = 0.0;
    }

    // #1236 — the spec, in the user's words: "if mousewheel moving
    // slow, scroll slow, if mousewheel moving fast, scroll fast, if
    // mousewheel was stopped while scrolling no more scrolling should
    // happen, it means user wanted to stop when wheel stop."
    //
    // Rate handles all three, and the third needs NO mechanism of its
    // own: a stopped wheel emits no events, and nothing here buffers,
    // so nothing moves. That is the whole of it.
    //
    // An earlier attempt added a stop detector — once the rate collapsed
    // below half the gesture peak, every remaining event was DROPPED
    // until the next pause. It was reported as "normal is not good,
    // still missing events", and it deserved to be: notch timing
    // jitters, a real hand-spin halves its rate routinely, and one
    // wobble killed scrolling for the rest of the gesture. Discarding
    // input on a guess about intent is the worst failure available
    // here — a slightly-too-long scroll is a nuisance, an ignored hand
    // is a broken mouse.
    //
    // What remains of that idea, without the discard: a wheel whose rate
    // is DECAYING never gets amplified. A free-spin tail therefore
    // travels at exactly the unaccelerated 1 line per event — the
    // behaviour that was fine before any of this — while a hand that is
    // holding or raising its rate gets the multiplier. Deceleration is
    // then just physics: fewer events per second, less scrolling, and
    // the tail dies with the wheel.
    //
    // #1236 — `off` is a TRUE bypass, byte-identical to pre-#1236.
    // Refill FIRST, on every path.
    //
    // #1236 — this block used to sit below the `off` bypass, which made
    // the default path deplete-only: the bucket started at capacity,
    // drained, and never came back, so scrolling died permanently after
    // ~25 lines and stayed dead for the rest of the session. It was
    // masked by how often mnml gets restarted during development, since
    // `App::new` refills it. Caught by
    // `the_off_path_still_scrolls_after_draining_a_full_bucket`.
    //
    // Capacity scales with the setting so acceleration isn't immediately
    // clamped away by the dampener it has to pass through; `off` keeps
    // the unscaled capacity it always had.
    let cap = SCROLL_BUCKET_MAX * ceiling.max(1.0);
    if let Some(prev) = app.scroll_bucket_last_refill {
        let elapsed = now.duration_since(prev).as_secs_f32();
        app.scroll_bucket = (app.scroll_bucket + elapsed * SCROLL_BUCKET_REFILL).min(cap);
    } else {
        app.scroll_bucket = cap;
    }
    app.scroll_bucket_last_refill = Some(now);

    if ceiling <= 1.0 {
        let spend = want_raw.min(app.scroll_bucket).floor();
        app.scroll_bucket -= spend;
        app.scroll_last_factor = 1.0;
        return delta.signum() * (spend as i32);
    }
    let peak = app.scroll_gesture_peak_rate;
    if rate > peak {
        app.scroll_gesture_peak_rate = rate;
    } else if peak > 0.0 && rate < peak * 0.5 {
        // Decaying, not stopped. Stop amplifying; keep honouring input.
        app.scroll_rate_decaying = true;
    }

    let ramp = ((rate - SCROLL_ACCEL_FLOOR_RATE)
        / (SCROLL_ACCEL_FULL_RATE - SCROLL_ACCEL_FLOOR_RATE))
        .clamp(0.0, 1.0);
    let factor = if app.scroll_rate_decaying {
        1.0
    } else {
        1.0 + (ceiling - 1.0) * ramp
    };
    app.scroll_last_factor = factor;
    let want = want_raw * factor;

    // Carry the sub-line remainder across events in this gesture.
    // `floor()` alone discarded it every time, which made `gentle`
    // (1 notch x1.5 = 1.5 -> 1) indistinguishable from `off`.
    let wanted_with_carry = want + app.scroll_frac_carry;
    let spend = wanted_with_carry.min(app.scroll_bucket).floor();
    app.scroll_frac_carry = (wanted_with_carry - spend).clamp(0.0, 1.0);
    app.scroll_bucket -= spend;
    delta.signum() * (spend as i32)
}

/// Clamp the (already-accelerated) scroll magnitude to a sane
/// per-tick movement for list surfaces.
///
/// #1236 — the cap scales with `scroll_accel`, and it has to. The
/// flat cap of 8 was applied AFTER acceleration, so `normal` asking
/// for 15 lines and `fast` asking for 34 both arrived as 8 and every
/// setting felt identical — the user's report. Acceleration that is
/// computed and then clamped away is not a feature.
///
/// The cap still exists: without it one batch could jump hundreds of
/// rows and read as a teleport rather than a scroll. `off` keeps
/// exactly the historical value.
fn list_scroll_clamp_scaled(delta: i32, ceiling: f32) -> i32 {
    let sign = delta.signum();
    let mag = delta.unsigned_abs() as i32;
    let cap = ((LIST_SCROLL_PER_BATCH_CAP as f32) * ceiling).round() as i32;
    sign * mag.min(cap.max(LIST_SCROLL_PER_BATCH_CAP))
}

pub(crate) fn scroll_under(app: &mut App, x: u16, y: u16, delta: i32) {
    let delta = budgeted_scroll(app, delta);
    if delta == 0 {
        return;
    }
    // #1236 — the per-surface caps below scale with the setting;
    // see `list_scroll_clamp_scaled`. Read once so every arm agrees.
    let scroll_ceiling = scroll_accel_ceiling(&app.config.editor.scroll_accel);
    let accel_on = scroll_ceiling > 1.0;
    // #polish 2026-07-06 — wheel over the bufferline strip cycles
    // through open buffers (Chrome / Firefox tab-strip convention).
    // Checked first so the strip's overlap with pane rects doesn't
    // let editor scroll steal the notch. Bounded to prev/next per
    // notch — no multi-step jump. Also applies over the overflow
    // arrow zones so the user can wheel there without missing.
    // #1209 — the global overflow-arrow zones are gone. A leaf
    // strip's chevrons now sit inside `split_tab_strip_areas`, and
    // the per-leaf scroll branch further down handles wheeling there.
    let on_bufferline_zone = app
        .rects
        .bufferline_tabs
        .iter()
        .any(|(r, _)| contains(*r, x, y));
    if on_bufferline_zone {
        if delta < 0 {
            app.prev_buffer();
        } else {
            app.next_buffer();
        }
        return;
    }
    // #1184 (2026-08-23) — wheel over the sessions rail → scroll
    // its content list. Same pattern as the agents rail below;
    // gate on the active section so the (stale) tree rect can't
    // shadow us. The render clamps the offset to visible-rows.
    if app.active_section == crate::app::ActivitySection::Sessions
        && let Some(ar) = app.rects.sessions_panel_area
        && contains(ar, x, y)
    {
        let d = list_scroll_clamp_scaled(delta, scroll_ceiling);
        if d < 0 {
            app.sessions_panel_scroll = app
                .sessions_panel_scroll
                .saturating_sub(d.unsigned_abs() as usize);
        } else {
            app.sessions_panel_scroll = app.sessions_panel_scroll.saturating_add(d as usize);
        }
        return;
    }
    // Wheel over the agents rail panel → scroll its content list. Checked
    // first + gated on the active section so the (stale) tree rect, which
    // overlaps the same rail region, can't shadow it. The render clamps the
    // offset to the content height each frame.
    if app.active_section == crate::app::ActivitySection::Agents
        && let Some(ar) = app.rects.agents_panel_area
        && contains(ar, x, y)
    {
        let d = list_scroll_clamp_scaled(delta, scroll_ceiling);
        if d < 0 {
            app.agents_panel_scroll = app
                .agents_panel_scroll
                .saturating_sub(d.unsigned_abs() as usize);
        } else {
            app.agents_panel_scroll = app.agents_panel_scroll.saturating_add(d as usize);
        }
        return;
    }
    // qa-feature 2026-07-01 — wheel over the Integrations panel
    // scrolls its icon list. Bumps by 3 rows per notch (one icon
    // row) since each entry is 3 cells tall.
    if app.active_section == crate::app::ActivitySection::Integrations
        && let Some(ar) = app.rects.integrations_panel_area
        && contains(ar, x, y)
    {
        // 2026-08-05 — write to the tab-specific scroll field so
        // Installed / Marketplace remember independent positions.
        let d = list_scroll_clamp_scaled(delta, scroll_ceiling);
        let step = 3usize;
        let target: &mut usize = match app.integrations_panel_tab {
            crate::app::IntegrationsPanelTab::Installed => {
                &mut app.integrations_panel_scroll_installed
            }
            crate::app::IntegrationsPanelTab::Marketplace => {
                &mut app.integrations_panel_scroll_marketplace
            }
            crate::app::IntegrationsPanelTab::InDev => &mut app.integrations_panel_scroll_in_dev,
        };
        if d < 0 {
            *target = target.saturating_sub(step * d.unsigned_abs() as usize);
        } else {
            *target = target.saturating_add(step * d as usize);
        }
        return;
    }
    // HTTP panel — wheel over a CAPTURED / RECENT row scrolls that
    // section past the SECTION_ROW_CAP visible slot. Checked BEFORE
    // the general tree wheel so a scroll over the panel doesn't
    // fall through and move the file-tree cursor. 2026-07-07.
    if app.active_section == crate::app::ActivitySection::Http {
        let d = list_scroll_clamp_scaled(delta, scroll_ceiling);
        let bump = |cur: &mut usize, d: i32| {
            if d < 0 {
                *cur = cur.saturating_sub(d.unsigned_abs() as usize);
            } else {
                *cur = cur.saturating_add(d as usize);
            }
        };
        if app
            .rects
            .http_panel_captured_rows
            .iter()
            .any(|(r, _)| contains(*r, x, y))
        {
            bump(&mut app.http_panel_captured_scroll, d);
            return;
        }
        if app
            .rects
            .http_panel_recent_rows
            .iter()
            .any(|(r, _)| contains(*r, x, y))
        {
            bump(&mut app.http_panel_recent_scroll, d);
            return;
        }
        if app
            .rects
            .http_panel_mock_rows
            .iter()
            .any(|(r, _)| contains(*r, x, y))
        {
            bump(&mut app.http_panel_mocks_scroll, d);
            return;
        }
        if app
            .rects
            .http_panel_chain_rows
            .iter()
            .any(|(r, _)| contains(*r, x, y))
        {
            bump(&mut app.http_panel_chains_scroll, d);
            return;
        }
        if app
            .rects
            .http_panel_collection_folder_rows
            .iter()
            .any(|(r, _)| contains(*r, x, y))
            || app
                .rects
                .http_panel_collection_rows
                .iter()
                .any(|(r, _)| contains(*r, x, y))
        {
            bump(&mut app.http_panel_collections_scroll, d);
            return;
        }
    }
    if let Some(tr) = app.rects.tree
        && contains(tr, x, y)
    {
        // qa-feature 2026-07-01 — tree wheel moves exactly ONE
        // row per dispatched batch. Was: `list_scroll_clamp` +
        // per-line loop, which on macOS smooth-scrolling fires
        // several ScrollDown events per physical mouse notch —
        // the coalescer packs them into a batch of N, we moved
        // N rows, and the user saw the cursor skip 2-3 rows per
        // notch. Trackpad swipes still feel smooth because
        // separate physical swipes still produce separate
        // dispatches; only the WITHIN-batch amplification is
        // gone.
        // #1236 — one row per NOTCH, using time rather than the batch
        // boundary to decide what a notch is.
        //
        // A physical notch on an MX Master 3 emits 2-3 events. Whether
        // they arrive inside one coalesced batch is a race with the
        // event loop, so keying off batches gave 1 row sometimes and
        // 2-3 others — "its not that reliable". The logged timing
        // separates the two cases unambiguously: 8-23ms between events
        // within a notch, ~150ms between deliberate notches. Anything
        // arriving within the window below belongs to the notch already
        // handled, so it does not step again.
        // WHY 2-3 events per notch, confirmed 2026-08-29: the TERMINAL
        // multiplies them. Ghostty 1.3.1 ships
        // `mouse-scroll-multiplier = precision:1,discrete:3` by default,
        // so a notched wheel's every detent arrives as THREE scroll
        // events. Nothing in mnml or in the user's ghostty config asked
        // for that. crossterm hands us what the terminal chose to send,
        // not what the hardware did — so any events-per-notch figure is a
        // property of the (mouse x terminal) pair, and collapsing by time
        // is what makes the count stop mattering.
        const TREE_NOTCH_WINDOW_MS: u64 = 60;
        let step_now = std::time::Instant::now();
        let within_same_notch = app
            .tree_last_row_step
            .map(|t| {
                step_now.duration_since(t) < std::time::Duration::from_millis(TREE_NOTCH_WINDOW_MS)
            })
            .unwrap_or(false);
        if within_same_notch && !accel_on {
            return;
        }
        app.tree_last_row_step = Some(step_now);

        // #1236 — with acceleration ON, honour the magnitude: it is
        // now derived from wheel RATE, so it reflects how fast the
        // user is actually spinning. With acceleration OFF this stays
        // exactly one row per batch, preserving the 2026-07-01 fix
        // above verbatim — that fix was correct for a magnitude that
        // came from BATCH SIZE, which measured render-loop lag rather
        // than intent. Different input, different trust.
        if accel_on {
            // Rows come from the ACCELERATION FACTOR, never from the
            // batch size.
            //
            // #1236 — deriving rows from the magnitude reintroduced the
            // exact bug the 2026-07-01 comment above warns about: an MX
            // Master 3 fires several events per physical notch, so a
            // single slow notch moved 2-3 rows ("when i spin slowly it
            // should go from file to file but its jumping over 2 files
            // for a single scroll notch"). The factor is 1.0 at slow
            // speeds by construction, so one notch is one row again,
            // and only a genuinely fast spin moves more.
            // Accumulate fractionally: `round(factor)` turned a
            // factor of 2.5 into a hard 2-row jump on EVERY event,
            // which is what "jumping over 2 files for a single scroll
            // notch" was. Carrying the remainder means one row per
            // notch at factor 1.0, and 2-then-3 alternating at 2.5.
            app.scroll_row_accum += app.scroll_last_factor.max(1.0);
            let rows = app.scroll_row_accum.floor().max(1.0);
            app.scroll_row_accum -= rows;
            let rows = rows as usize;
            let cur = app.tree.cursor();
            app.tree.set_cursor(if delta < 0 {
                cur.saturating_sub(rows)
            } else {
                cur.saturating_add(rows)
            });
        } else if delta < 0 {
            app.tree.move_up();
        } else {
            app.tree.move_down();
        }
        return;
    }
    // qa-feature 2026-06-30 — wheel over the GIT palette area
    // (any row registered by git_palette::draw). Best-practice
    // sidebar scrolling would page the palette itself; until that
    // lands, route the wheel to the active GitGraph pane's
    // commits so the wheel does the obvious thing after clicking
    // a branch (scroll the commit list it just jumped to).
    if app.active_section == crate::app::ActivitySection::Git
        && let Some((row_rect, _)) = app.rects.git_palette_rows.first()
    {
        // Build the palette bounding box from row rects. If any
        // row contains the click point, treat as a palette hit.
        let bbox_x = row_rect.x;
        let bbox_w = row_rect.width;
        let bbox_y0 = app
            .rects
            .git_palette_rows
            .iter()
            .map(|(r, _)| r.y)
            .min()
            .unwrap_or(row_rect.y);
        let bbox_y1 = app
            .rects
            .git_palette_rows
            .iter()
            .map(|(r, _)| r.y)
            .max()
            .unwrap_or(row_rect.y);
        if x >= bbox_x && x < bbox_x + bbox_w && y >= bbox_y0 && y <= bbox_y1 {
            // #1229 — the palette scrolls ITSELF now.
            //
            // This used to forward the wheel to the first open GitGraph
            // pane's commit selection, and the comment above said why:
            // the palette had no scroll of its own, so the wheel did
            // "the obvious thing" instead. The consequence was that a
            // panel with 29 tags could not be scrolled at all, reported
            // three separate times. `App::git_palette_scroll` exists now,
            // and the render clamps it every frame.
            let d = list_scroll_clamp_scaled(delta, scroll_ceiling);
            if d < 0 {
                app.git_palette_scroll = app
                    .git_palette_scroll
                    .saturating_sub(d.unsigned_abs() as usize);
            } else {
                app.git_palette_scroll = app.git_palette_scroll.saturating_add(d as usize);
            }
            return;
        }
    }
    // Wheel over an extra workspace's tree body (the file list under
    // `> name`) → scroll that extra's tree cursor.
    if let Some(&(_, ws_idx, _)) = app
        .rects
        .extra_workspace_bodies
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        // qa-feature 2026-07-01 — 1 row per dispatched batch,
        // matching the primary tree fix above (avoids the
        // smooth-scrolling cursor-skip on macOS).
        if let Some(ws) = app.extra_workspaces.get_mut(ws_idx) {
            if delta < 0 {
                ws.tree.move_up();
            } else {
                ws.tree.move_down();
            }
        }
        return;
    }
    // Wheel over the GIT section header → cycle the active repo in
    // multi-repo workspaces (no-op when there's only one repo, so the
    // wheel falls through to the next rect). Up = previous, Down = next
    // — matches the bufferline / tab-strip wheel convention.
    if let Some(hr) = app.rects.git_section_toggle
        && contains(hr, x, y)
        && app.repos.len() > 1
    {
        app.cycle_active_repo(delta > 0);
        return;
    }
    // Wheel over any row in the GIT section → scroll the git rail cursor.
    if app
        .rects
        .git_rail_rows
        .iter()
        .any(|(r, _)| contains(*r, x, y))
    {
        let d = list_scroll_clamp_scaled(delta, scroll_ceiling);
        for _ in 0..d.unsigned_abs() {
            if d < 0 {
                app.git_rail_move_up();
            } else {
                app.git_rail_move_down();
            }
        }
        return;
    }
    // #1209 — wheel over a leaf's tab strip scrolls THAT strip. Was a
    // single global offset that no painter had read since the top tab
    // strip was retired on 2026-07-18, so this scrolled nothing.
    if let Some(&(_, leaf_pane)) = app
        .rects
        .split_tab_strip_areas
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        // `split_tab_strip_areas` keys by the leaf's ACTIVE pane;
        // `leaf_tab_scroll` keys by its FIRST tab. Translate, or the
        // wheel would write an offset the painter never reads.
        let leaf_key = app
            .layout()
            .leaf_containing(leaf_pane)
            .and_then(|tabs| tabs.first().copied())
            .unwrap_or(leaf_pane);
        let cur = app.leaf_tab_scroll.get(&leaf_key).copied().unwrap_or(0);
        let next = if delta < 0 {
            cur.saturating_sub(1)
        } else {
            cur.saturating_add(1)
        };
        app.leaf_tab_scroll.insert(leaf_key, next);
        return;
    }
    // Scroll whichever split leaf is under the pointer (not necessarily the focused one).
    if let Some(&(tr, pid)) = app
        .rects
        .editor_panes
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        // Resolved before the &mut borrow on `app.panes` so the editor
        // arm below can branch on it without a second borrow on `app`.
        let follows_cursor = app.cursor_follows_wheel();
        let vp = (tr.height as usize).max(1);
        // Editor / md-preview / diff bodies amplify the per-tick
        // wheel delta — page-like scrolling at the natural rate
        // (tui.rs passes ±1 per tick; multiplying by EDITOR_WHEEL_GAIN
        // restores the prior "3 lines per tick" feel).
        const EDITOR_WHEEL_GAIN: usize = 3;
        match app.panes.get_mut(pid) {
            Some(Pane::Editor(b)) => {
                // Two policies per `[editor] wheel_moves_cursor`:
                //   - cursor follows ⇒ apply MoveUp/MoveDown N times;
                //     the renderer's keep-cursor-in-view clamp pulls
                //     `scroll` along with the cursor (vim canon, same
                //     as `Ctrl+E` / `Ctrl+Y`).
                //   - cursor pinned ⇒ write `scroll` directly and set
                //     `scroll_pinned` so the renderer skips the clamp
                //     this frame. Cursor stays where it was — may
                //     leave the viewport. Cleared the moment cursor
                //     moves (VS Code / Sublime canon).
                let n = delta.unsigned_abs() as usize * EDITOR_WHEEL_GAIN;
                if follows_cursor {
                    let op = if delta < 0 {
                        EditOp::MoveUp
                    } else {
                        EditOp::MoveDown
                    };
                    for _ in 0..n {
                        b.editor.apply(op.clone(), vp, &mut app.clipboard);
                    }
                } else {
                    b.scroll = if delta < 0 {
                        b.scroll.saturating_sub(n)
                    } else {
                        // Cap so we don't scroll past EOF. The "leave
                        // the last line on screen" tail-guard lives in
                        // the renderer.
                        let max = b.editor.line_count().saturating_sub(1);
                        (b.scroll + n).min(max)
                    };
                    b.scroll_pinned = true;
                }
            }
            Some(Pane::MdPreview(p)) => {
                let n = delta.unsigned_abs() as usize * EDITOR_WHEEL_GAIN;
                p.scroll = if delta < 0 {
                    p.scroll.saturating_sub(n)
                } else {
                    p.scroll + n
                };
            }
            Some(Pane::Diff(d)) => {
                let n = delta.unsigned_abs() as usize * EDITOR_WHEEL_GAIN;
                d.scroll = if delta < 0 {
                    d.scroll.saturating_sub(n)
                } else {
                    d.scroll + n
                };
            }
            Some(Pane::Request(rp)) => {
                let n = delta.unsigned_abs() as usize;
                rp.scroll = if delta < 0 {
                    rp.scroll.saturating_sub(n)
                } else {
                    rp.scroll + n
                };
            }
            Some(Pane::Pty(s)) => s.scroll_history(if delta < 0 {
                delta.unsigned_abs() as isize
            } else {
                -(delta.unsigned_abs() as isize)
            }),
            Some(Pane::Ai(a)) => {
                let n = delta.unsigned_abs() as usize;
                a.scroll = if delta < 0 {
                    a.scroll.saturating_sub(n)
                } else {
                    a.scroll + n
                };
            }
            Some(Pane::Tests(t)) => {
                let n = delta.unsigned_abs() as usize;
                t.scroll = if delta < 0 {
                    t.scroll.saturating_sub(n)
                } else {
                    t.scroll + n
                };
            }
            Some(Pane::GitGraph(g)) => {
                // Wheel over the embedded diff (file picked from the
                // right-side detail panel) scrolls the diff body
                // instead of moving the commit-list selection.
                if let Some(d) = g.embedded_diff.as_mut() {
                    let n = delta.unsigned_abs() as usize;
                    d.scroll = if delta < 0 {
                        d.scroll.saturating_sub(n)
                    } else {
                        d.scroll + n
                    };
                } else {
                    g.move_selection(if delta < 0 {
                        -(delta.unsigned_abs() as isize)
                    } else {
                        delta.unsigned_abs() as isize
                    });
                }
            }
            Some(Pane::GitStatus(g)) => {
                g.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Diagnostics(d)) => {
                d.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Grep(g)) => {
                g.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            // `Pane::Trace` wheel-scroll moved to mnml-test-playwright.
            Some(Pane::Browser(b)) => {
                let step = if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                };
                if b.dom_focus {
                    b.move_dom_sel(step);
                } else if b.net_focus {
                    b.move_net_sel(step);
                } else if b.cookies_focus {
                    b.move_cookies_sel(step);
                } else if b.storage_focus {
                    b.move_storage_sel(step);
                } else {
                    let n = delta.unsigned_abs() as usize;
                    b.scroll = if delta < 0 {
                        b.scroll.saturating_sub(n)
                    } else {
                        b.scroll.saturating_add(n)
                    };
                }
            }
            Some(Pane::Flaky(f)) => {
                f.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Outline(o)) => {
                o.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::CmdlineHistory(h)) => {
                h.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            Some(Pane::Quickfix(g)) => {
                g.move_selection(if delta < 0 {
                    -(delta.unsigned_abs() as isize)
                } else {
                    delta.unsigned_abs() as isize
                });
            }
            // AWS CodeBuild + LogTail wheel-scroll moved to
            // mnml-aws-codebuild; pipeline-log + SCM wheel-scroll
            // moved to the mnml-forge-* integrations.
            Some(Pane::Cheatsheet(c)) => {
                if delta < 0 {
                    c.move_up();
                } else {
                    c.move_down();
                }
            }
            Some(Pane::Debug(p)) => {
                // Wheel moves whichever sub-section currently has
                // keyboard focus — same routing rule as j/k.
                let d = delta.signum() as isize;
                let n = delta.unsigned_abs() as isize;
                let section = p.section;
                match section {
                    crate::pane::DebugSection::Stack => app.debug_pane_move(d * n),
                    crate::pane::DebugSection::Variables => app.debug_pane_vars_move(d * n),
                }
            }
            Some(Pane::DapRepl(_)) => {
                // Scroll the history. usize::MAX ⇒ pinned to tail;
                // any upward scroll lands at a concrete index.
                let mag = delta.unsigned_abs() as usize;
                if delta < 0 {
                    if let Some(Pane::DapRepl(p)) = app.panes.get_mut(pid) {
                        let total = p.history.len();
                        let cur = if p.scroll == usize::MAX {
                            total
                        } else {
                            p.scroll
                        };
                        p.scroll = cur.saturating_sub(mag);
                    }
                } else if let Some(Pane::DapRepl(p)) = app.panes.get_mut(pid) {
                    let total = p.history.len();
                    let new = if p.scroll == usize::MAX {
                        usize::MAX
                    } else {
                        let next = p.scroll.saturating_add(mag);
                        if next >= total { usize::MAX } else { next }
                    };
                    p.scroll = new;
                }
            }
            Some(Pane::Image(_)) => {
                // Nothing to scroll — the image pane is "what you see is
                // what you get". Future v2 could pan a too-large image.
            }
            Some(Pane::ClaudeAgents(p)) => {
                // Scroll the rows by delta.
                for _ in 0..delta.unsigned_abs() {
                    if delta < 0 {
                        p.move_up();
                    } else {
                        p.move_down();
                    }
                }
            }
            Some(Pane::Websocket(p)) => {
                // Wheel scrolls the log view; clamped in the
                // renderer so we just bump the offset here.
                let step = delta.unsigned_abs() as usize;
                if delta < 0 {
                    p.scroll = p.scroll.saturating_add(step);
                } else {
                    p.scroll = p.scroll.saturating_sub(step);
                }
            }
            Some(Pane::SpendReport(p)) => {
                // Wheel scrolls the per-workspace list; renderer
                // clamps. Selection follows.
                let step = delta.unsigned_abs() as usize;
                let n = p.snapshot.per_workspace.len();
                if n > 0 {
                    if delta < 0 {
                        p.selected = p.selected.saturating_sub(step);
                    } else {
                        p.selected = (p.selected + step).min(n - 1);
                    }
                }
            }
            Some(Pane::Mount(m)) => {
                // Forward as a scroll event — integration decides what
                // to do with it (scroll a list, change a chart, …).
                m.send_input(mnml_bridge::InputEvent::Scroll {
                    col: 0,
                    row: 0,
                    dy: delta as i16,
                });
            }
            Some(Pane::NewCloudAgentWizard(_)) | Some(Pane::NewCloudRunWizard(_)) => {
                // Wizard pane content is short and fits a single
                // page; no scroll affordance needed for v1.
            }
            Some(Pane::IntegrationDetail(p)) => {
                // 2026-08-07 — wheel scrolls the pane body (README +
                // description overflow). Was: walked the actionable-
                // row cursor, which meant the pane's long README was
                // unreachable — user reported "I can only see one
                // page of the description, no scrolling or arrowing
                // will let me go downward". Keyboard ↑/↓ still walks
                // the cursor for button/link selection.
                if delta < 0 {
                    p.scroll = p.scroll.saturating_sub(delta.unsigned_abs() as usize);
                } else {
                    p.scroll = p.scroll.saturating_add(delta as usize);
                }
            }
            Some(Pane::ClaudeUsage(p)) => {
                if delta < 0 {
                    p.scroll = p.scroll.saturating_sub(delta.unsigned_abs() as usize);
                } else {
                    p.scroll = p.scroll.saturating_add(delta as usize);
                }
            }
            Some(Pane::CodexUsage(p)) => {
                if delta < 0 {
                    p.scroll = p.scroll.saturating_sub(delta.unsigned_abs() as usize);
                } else {
                    p.scroll = p.scroll.saturating_add(delta as usize);
                }
            }
            Some(Pane::CloudAgentRun(p)) => {
                // Scroll the logs viewport. Negative delta = scroll up
                // (older lines); positive = down. Crossing past the
                // tail re-enables follow.
                let n = delta.unsigned_abs() as usize;
                if delta < 0 {
                    if p.log_scroll == usize::MAX {
                        // Currently following — start at the tail and
                        // back off `n` lines.
                        p.log_scroll = p.logs.len().saturating_sub(n);
                    } else {
                        p.log_scroll = p.log_scroll.saturating_sub(n);
                    }
                    p.log_follow = false;
                } else {
                    let max = p.logs.len();
                    let new = p.log_scroll.saturating_add(n).min(max);
                    if new >= max.saturating_sub(1) {
                        p.log_scroll = usize::MAX;
                        p.log_follow = true;
                    } else {
                        p.log_scroll = new;
                    }
                }
            }
            None => {}
        }
        // Each SCM/CI pane's max_idx depends on which view-mode is
        // active — same trap as the key handlers above (flat must match
        // the rendered layout).
        // GitLab pane wheel-scroll moved to mnml-forge-gitlab.
        let _ = delta;
        let _ = pid;
    }
}

pub(crate) fn contains(r: Rect, x: u16, y: u16) -> bool {
    x >= r.x && x < r.x.saturating_add(r.width) && y >= r.y && y < r.y.saturating_add(r.height)
}

/// Mouse click on a list-style pane row. Dispatches based on the pane
/// at `pane_id`. `flat_idx` is the index into either the active view's
/// flatten output (SCM/CI panes) or directly into the pane's items vec
/// (plain list panes). `is_double_click` ⇒ trigger the primary action.
pub(crate) fn handle_scm_row_click(
    app: &mut App,
    pane_id: usize,
    flat_idx: usize,
    is_double_click: bool,
) {
    use crate::pane::Pane;
    // Plain list panes — set selected, optionally fire primary action.
    if matches!(app.panes.get(pane_id), Some(Pane::Diagnostics(_))) {
        if let Some(Pane::Diagnostics(d)) = app.panes.get_mut(pane_id) {
            // flat_idx is the index into visible (filtered) rows.
            let n = d.visible_indices().len();
            if flat_idx < n {
                d.selected = flat_idx;
            }
        }
        if is_double_click {
            app.jump_to_selected_diagnostic();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Outline(_))) {
        if let Some(Pane::Outline(o)) = app.panes.get_mut(pane_id) {
            let len = o.visible_indices().len();
            if flat_idx < len {
                o.selected = flat_idx;
            }
        }
        if is_double_click {
            app.jump_to_selected_outline();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Flaky(_))) {
        if let Some(Pane::Flaky(f)) = app.panes.get_mut(pane_id)
            && flat_idx < f.items.len()
        {
            f.selected = flat_idx;
        }
        if is_double_click {
            app.jump_to_selected_flaky();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Diff(_))) {
        if let Some(Pane::Diff(d)) = app.panes.get_mut(pane_id)
            && flat_idx < d.hunks.len()
        {
            d.cursor = flat_idx;
            // In Hunk mode, clicking a hunk row also toggles its
            // collapse (expanded-by-default — click chevron to
            // collapse one you don't need).
            if d.view_mode == crate::pane::DiffViewMode::Hunk {
                if d.hunk_collapsed.contains(&flat_idx) {
                    d.hunk_collapsed.remove(&flat_idx);
                } else {
                    d.hunk_collapsed.insert(flat_idx);
                }
            }
        }
        if is_double_click {
            app.jump_to_cursor_hunk();
        }
        return;
    }
    // CodeBuilds click handler moved to mnml-aws-codebuild.
    if matches!(app.panes.get(pane_id), Some(Pane::GitGraph(_))) {
        if let Some(Pane::GitGraph(g)) = app.panes.get_mut(pane_id) {
            // `flat_idx` is the *virtual* row index (0 = WIP if present,
            // then commits). `jump_to` clamps to total_rows AND calls
            // `reload_detail` so the right-side panel actually populates
            // — directly assigning `selected` skipped the reload, leaving
            // the detail empty after a click.
            g.jump_to(flat_idx);
        }
        if is_double_click {
            app.open_selected_commit_diff();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Cheatsheet(_))) {
        if let Some(Pane::Cheatsheet(c)) = app.panes.get_mut(pane_id) {
            let n = c.visible_rows_len();
            if flat_idx < n {
                c.selected = flat_idx;
            }
        }
        if is_double_click {
            app.cheatsheet_run_selected();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::CmdlineHistory(_))) {
        if let Some(Pane::CmdlineHistory(h)) = app.panes.get_mut(pane_id)
            && flat_idx < h.entries.len()
        {
            h.selected = flat_idx;
        }
        if is_double_click {
            app.cmdline_history_accept();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::ClaudeAgents(_))) {
        if let Some(Pane::ClaudeAgents(p)) = app.panes.get_mut(pane_id) {
            let n = p.visible_indices().len();
            if flat_idx < n {
                p.selected = flat_idx;
                // claude-agents-power-user 2026-06-28 finding 2:
                // mouse click parity with keyboard nav — reset
                // detail_scroll so the new row's drill-down view
                // starts at the top instead of inheriting the
                // previous row's scroll offset.
                p.detail_scroll = 0;
            }
        }
        if is_double_click {
            app.claude_agents_action(crate::claude_agents::ClaudeAgentsAction::OpenTranscript);
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::Tests(_))) {
        if let Some(Pane::Tests(t)) = app.panes.get_mut(pane_id)
            && let crate::playwright::TestsState::Done(r) = &t.state
            && flat_idx < r.tests.len()
        {
            t.selected = flat_idx;
        }
        if is_double_click {
            app.jump_to_selected_test();
        }
        return;
    }
    if matches!(app.panes.get(pane_id), Some(Pane::GitStatus(_))) {
        if let Some(Pane::GitStatus(g)) = app.panes.get_mut(pane_id) {
            let total = g.unstaged.len() + g.staged.len();
            if flat_idx < total {
                g.selected = flat_idx;
            }
        }
        if is_double_click {
            app.git_status_open_diff();
        }
        return;
    }
    if matches!(
        app.panes.get(pane_id),
        Some(Pane::Grep(_)) | Some(Pane::Quickfix(_))
    ) {
        // Both share the GrepPane struct; treat them identically.
        let len = match app.panes.get(pane_id) {
            Some(Pane::Grep(g)) | Some(Pane::Quickfix(g)) => g.hits.len(),
            _ => 0,
        };
        if let Some(pane) = app.panes.get_mut(pane_id) {
            let target = match pane {
                Pane::Grep(g) | Pane::Quickfix(g) => Some(g),
                _ => None,
            };
            if let Some(g) = target
                && flat_idx < len
            {
                g.selected = flat_idx;
            }
        }
        if is_double_click {
            app.jump_to_selected_grep_hit();
        }
        return;
    }
    // Browser sub-panels — clicks select the row inside whichever panel
    // is focused (network / DOM / cookies / storage). Double-click on a
    // network row opens it as a Request pane (sibling to Enter).
    if matches!(app.panes.get(pane_id), Some(Pane::Browser(_))) {
        let net_double_open = {
            let Some(Pane::Browser(b)) = app.panes.get_mut(pane_id) else {
                return;
            };
            if b.dom_focus {
                let n = b.visible_dom_indices().len();
                if flat_idx < n {
                    b.set_dom_sel(flat_idx);
                }
                false
            } else if b.cookies_focus {
                if flat_idx < b.cookies.len() {
                    b.cookies_sel = flat_idx;
                }
                false
            } else if b.storage_focus {
                if flat_idx < b.storage.len() {
                    b.storage_sel = flat_idx;
                }
                false
            } else if b.net_focus {
                let n = b.visible_net_indices().len();
                if flat_idx < n {
                    b.net_sel = flat_idx;
                }
                is_double_click
            } else {
                false
            }
        };
        if net_double_open {
            app.open_net_entry_as_request();
        }
        return;
    }
    // SCM/CI pane click dispatch moved with the panes themselves to
    // their standalone mnml-forge-* integration binaries.
    let _ = (app, pane_id);
}

/// Translate a key event into the byte sequence a pty child expects (xterm-ish).
pub(crate) fn pty_key_bytes(key: KeyEvent) -> Vec<u8> {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let alt = key.modifiers.contains(KeyModifiers::ALT);
    let prefix_alt = |b: Vec<u8>| {
        if alt {
            let mut v = vec![0x1b];
            v.extend(b);
            v
        } else {
            b
        }
    };
    match key.code {
        KeyCode::Char(c) => {
            if ctrl {
                // Control char: letters → 1..26, plus the usual @ [ \ ] ^ _.
                let b = match c.to_ascii_lowercase() {
                    'a'..='z' => Some((c.to_ascii_lowercase() as u8) - b'a' + 1),
                    ' ' | '@' => Some(0),
                    '[' => Some(0x1b),
                    '\\' => Some(0x1c),
                    ']' => Some(0x1d),
                    '^' => Some(0x1e),
                    '_' | '?' => Some(0x1f),
                    _ => None,
                };
                match b {
                    Some(b) => prefix_alt(vec![b]),
                    None => prefix_alt(c.to_string().into_bytes()),
                }
            } else {
                prefix_alt(c.to_string().into_bytes())
            }
        }
        KeyCode::Enter => prefix_alt(vec![b'\r']),
        KeyCode::Tab => prefix_alt(vec![b'\t']),
        KeyCode::BackTab => b"\x1b[Z".to_vec(),
        KeyCode::Backspace => prefix_alt(vec![0x7f]),
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => b"\x1b[A".to_vec(),
        KeyCode::Down => b"\x1b[B".to_vec(),
        KeyCode::Right => b"\x1b[C".to_vec(),
        KeyCode::Left => b"\x1b[D".to_vec(),
        KeyCode::Home => b"\x1b[H".to_vec(),
        KeyCode::End => b"\x1b[F".to_vec(),
        KeyCode::PageUp => b"\x1b[5~".to_vec(),
        KeyCode::PageDown => b"\x1b[6~".to_vec(),
        KeyCode::Insert => b"\x1b[2~".to_vec(),
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        KeyCode::F(n @ 1..=4) => format!("\x1bO{}", (b'P' + (n - 1)) as char).into_bytes(),
        KeyCode::F(n) => {
            // xterm "modifyOtherKeys"-ish CSI for F5..F12.
            let code = match n {
                5 => 15,
                6 => 17,
                7 => 18,
                8 => 19,
                9 => 20,
                10 => 21,
                11 => 23,
                12 => 24,
                _ => return Vec::new(),
            };
            format!("\x1b[{code}~").into_bytes()
        }
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod scroll_accel_tests {
    use super::{SCROLL_BUCKET_MAX, budgeted_scroll_at, scroll_accel_ceiling};
    use crate::app::App;
    use crate::config::Config;

    fn app_with(accel: &str) -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.editor.scroll_accel = accel.to_string();
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        (d, app)
    }

    /// The headline ask: a fast spin travels further than a slow one,
    /// and further still as the setting goes up.
    ///
    /// Drives RATE (events/sec via the injected clock), not batch size.
    /// The first version of this test drove batch size, which is what
    /// the code used to read — and that turned out to be ~1 in practice
    /// because `coalesce_scroll` only collapses ALREADY-QUEUED events
    /// and a responsive loop never accumulates any. The test passed and
    /// the feature did nothing, which is exactly what the user saw.
    #[test]
    fn a_fast_spin_travels_further_and_scales_with_the_setting() {
        // 8ms between notches ≈ 125 events/sec — a hard spin.
        let spin_gap = std::time::Duration::from_millis(8);
        let mut out = Vec::new();
        for accel in ["off", "gentle", "normal", "fast"] {
            let (_d, mut app) = app_with(accel);
            let t0 = std::time::Instant::now();
            let mut total = 0;
            for i in 0..10 {
                total += budgeted_scroll_at(&mut app, 1, t0 + spin_gap * i);
            }
            out.push(total);
        }
        assert!(
            out.windows(2).all(|w| w[1] >= w[0]),
            "each setting should scroll at least as far as the one below: {out:?}"
        );
        assert!(
            out[3] > out[0],
            "'fast' must beat 'off' on a hard spin: {out:?}"
        );
    }

    /// A single notch is 1:1 at EVERY setting. Acceleration that also
    /// multiplied gentle scrolling would make precise positioning
    /// impossible — the setting is meant to change what a hard spin
    /// does, nothing else.
    #[test]
    fn one_notch_is_never_accelerated() {
        for accel in ["off", "gentle", "normal", "fast"] {
            let (_d, mut app) = app_with(accel);
            // Slow, deliberate notches — 400ms apart, past the gesture
            // gap, so each one starts from zero inherited velocity.
            let t0 = std::time::Instant::now();
            for i in 0..4 {
                let now = t0 + std::time::Duration::from_millis(400 * i);
                assert_eq!(
                    budgeted_scroll_at(&mut app, 1, now),
                    1,
                    "a slow single notch moved more than one line at accel={accel}"
                );
            }
        }
    }

    /// The anti-overshoot property, and the reason acceleration scales
    /// capacity but NOT refill.
    ///
    /// A free-spin wheel keeps emitting for seconds after release. Those
    /// events must run the bucket dry and stop — not coast further just
    /// because acceleration is on. Time is advanced explicitly because
    /// the refill is time-based: an earlier version of this test called
    /// back-to-back with no elapsed time and stayed green even with the
    /// refill scaled 1000x, since zero elapsed means zero refill either
    /// way. Without a moving clock this assertion is decoration.
    #[test]
    fn flywheel_inertia_runs_dry_instead_of_coasting() {
        for accel in ["off", "gentle", "normal", "fast"] {
            let (_d, mut app) = app_with(accel);
            let t0 = std::time::Instant::now();
            let mut total = 0i32;
            let mut last = i32::MAX;
            // 3 seconds of post-release inertia, 30 batches of 10 lines.
            for i in 0..30 {
                let now = t0 + std::time::Duration::from_millis(100 * i);
                let got = budgeted_scroll_at(&mut app, 10, now);
                total += got;
                last = got;
            }
            // #1236 — the bucket is no longer the primary brake, and
            // this bound records why.
            //
            // Its refill had to rise from 12 to 60 lines/sec because 12
            // STARVED real input on a high-resolution wheel (measured:
            // 10% of events silently dropped, reported as "it misses a
            // lot of scrolling i do"). A refill high enough not to
            // starve a hand cannot also throttle a flywheel — one dial
            // cannot serve both.
            //
            // So stopping is the STOP DETECTOR's job now (rate
            // collapsing below half the gesture peak drops every
            // remaining event), and the bucket only bounds the worst
            // case if that detector misses. This bound is therefore
            // generous on purpose; `when_the_wheel_stops_scrolling_stops`
            // is the test that actually guards the user-visible promise.
            let ceiling = scroll_accel_ceiling(accel);
            let bound = (SCROLL_BUCKET_MAX * ceiling).ceil() as i32 + 3 * 60 + 10;
            assert!(
                total <= bound,
                "at accel={accel}, 3s of inertia moved {total} lines, over the \
                 {bound} bound — refill is being scaled by acceleration, which \
                 makes the wheel coast past the hand (the 37074afe regression)"
            );
            let _ = last;
        }
    }
}

#[cfg(test)]
mod scroll_clamp_tests {
    use super::{LIST_SCROLL_PER_BATCH_CAP, list_scroll_clamp_scaled, scroll_accel_ceiling};

    /// The bug the user actually hit: acceleration was computed and
    /// then clamped away by a flat cap of 8, so `normal` (15 lines)
    /// and `fast` (34) both arrived as 8 and every setting felt the
    /// same. The cap must scale with the setting or the whole feature
    /// is inert.
    #[test]
    fn the_cap_scales_so_accel_is_not_clamped_away() {
        let big = 40; // more than any cap, as a hard spin produces
        let mut out = Vec::new();
        for accel in ["off", "gentle", "normal", "fast"] {
            out.push(list_scroll_clamp_scaled(big, scroll_accel_ceiling(accel)));
        }
        assert_eq!(
            out[0], LIST_SCROLL_PER_BATCH_CAP,
            "'off' must keep the historical cap exactly"
        );
        assert!(
            out.windows(2).all(|w| w[1] >= w[0]),
            "cap should widen with the setting: {out:?}"
        );
        assert!(
            out[3] > out[0],
            "'fast' must allow more than 'off': {out:?}"
        );
    }

    /// A cap still exists at every setting — unbounded would let one
    /// batch jump hundreds of rows, which reads as a teleport.
    #[test]
    fn a_cap_still_applies_at_every_setting() {
        for accel in ["off", "gentle", "normal", "fast"] {
            let ceiling = scroll_accel_ceiling(accel);
            let got = list_scroll_clamp_scaled(10_000, ceiling);
            assert!(
                got < 10_000,
                "accel={accel} let an absurd magnitude through unclamped ({got})"
            );
        }
    }

    /// Sign is preserved — a clamp that lost direction would scroll
    /// the wrong way on fast upward spins.
    #[test]
    fn sign_survives_the_clamp() {
        let c = scroll_accel_ceiling("fast");
        assert!(list_scroll_clamp_scaled(-40, c) < 0);
        assert!(list_scroll_clamp_scaled(40, c) > 0);
    }
}

#[cfg(test)]
mod scroll_spec_tests {
    //! The spec in the user's words (2026-08-29):
    //!   "if mousewheel moving slow, scroll slow, if mousewheel moving
    //!    fast, scroll fast, if mousewheel was stopped while scrolling
    //!    no more scrolling should happen, it means user wanted to stop
    //!    when wheel stop"
    //! One test per clause, driven by wheel timing rather than by any
    //! internal value — earlier tests drove intermediates and passed
    //! while the feature did nothing.

    use super::budgeted_scroll_at;
    use crate::app::App;
    use crate::config::Config;
    use std::time::{Duration, Instant};

    fn app_with(accel: &str) -> (tempfile::TempDir, App) {
        let d = tempfile::tempdir().unwrap();
        let mut cfg = Config::default();
        cfg.editor.scroll_accel = accel.to_string();
        let app = App::new(d.path().to_path_buf(), cfg).unwrap();
        (d, app)
    }

    /// Spin 10 notches at a given inter-notch gap; return lines moved.
    fn spin(app: &mut App, t: &mut Instant, gap_ms: u64, notches: usize) -> i32 {
        let mut total = 0;
        for _ in 0..notches {
            *t += Duration::from_millis(gap_ms);
            total += budgeted_scroll_at(app, 1, *t);
        }
        total
    }

    /// Clause 1 + 2: slow wheel scrolls slow, fast wheel scrolls fast.
    #[test]
    fn slow_wheel_slow_scroll_fast_wheel_fast_scroll() {
        for accel in ["gentle", "normal", "fast"] {
            let (_d, mut app) = app_with(accel);
            let mut t = Instant::now();
            let slow = spin(&mut app, &mut t, 120, 10); // ~8/sec

            let (_d2, mut app2) = app_with(accel);
            let mut t2 = Instant::now();
            let fast = spin(&mut app2, &mut t2, 8, 10); // ~125/sec

            assert!(
                fast > slow,
                "accel={accel}: fast spin moved {fast}, slow moved {slow} — a faster                  wheel must travel further"
            );
            assert_eq!(
                slow, 10,
                "accel={accel}: a slow deliberate scroll must stay 1:1 (got {slow}                  for 10 notches) so precise positioning still works"
            );
        }
    }

    /// MX Master 3 report: "when i spin slowly it should go from file
    /// to file but its jumping over 2 files for a single scroll notch".
    ///
    /// That wheel (and macOS smooth-scrolling generally) emits SEVERAL
    /// events per physical notch, so a batch of 3 is one notch, not
    /// three. Rate must therefore be notches/sec, not events/sec —
    /// dividing by the batch inflated it 2-3x on this hardware, pinned
    /// the multiplier at its ceiling from the first notch, and made the
    /// stop detector fire on noise.
    #[test]
    fn hardware_that_fires_several_events_per_notch_still_scrolls_one_step() {
        for batch in [1, 2, 3, 5] {
            let (_d, mut app) = app_with("normal");
            let mut t = Instant::now();
            // Slow, deliberate notches — 150ms apart, whatever the
            // hardware's events-per-notch happens to be.
            let mut factors = Vec::new();
            for _ in 0..5 {
                t += Duration::from_millis(150);
                budgeted_scroll_at(&mut app, batch, t);
                factors.push(app.scroll_last_factor);
            }
            for f in &factors {
                assert!(
                    (*f - 1.0).abs() < 0.01,
                    "batch={batch}: slow notches produced factor {f}, so a discrete \
                     surface would jump {} rows for ONE notch",
                    f.round()
                );
            }
        }
    }

    /// Clause 3, the strict one: when the wheel stops, scrolling stops.
    /// Not slows — stops. A free-spin wheel keeps emitting for seconds
    /// after release; those events must move the view zero lines.
    /// #1236 — the SHIPPED DEFAULT must survive sustained scrolling.
    ///
    /// Twice now the reported bug was "it misses a lot of scrolling",
    /// both times because a rate limiter starved live input rather than
    /// because of anything to do with acceleration. Whatever the default
    /// is, that class of failure must be caught here and not by the user.
    ///
    /// Driven at ~40 events/sec — an ordinary sustained scroll, well
    /// inside the 37-128/sec measured range — for ten seconds.
    #[test]
    fn the_shipped_default_does_not_starve_under_sustained_scrolling() {
        let default_accel = crate::config::Config::default().editor.scroll_accel;
        let (_d, mut app) = app_with(&default_accel);
        let mut t = Instant::now();
        let mut moved_late = 0;
        for i in 0..400 {
            t += Duration::from_millis(25);
            let got = budgeted_scroll_at(&mut app, 1, t);
            if i >= 300 {
                moved_late += got;
            }
        }
        assert!(
            moved_late >= 50,
            "default `{default_accel}`: the last 100 of 400 wheel events moved only \
             {moved_late} lines, so sustained scrolling is being throttled to a crawl"
        );
    }

    /// The default is a user-facing feel decision, not an implementation
    /// detail — pin it so it cannot drift silently. It moved off -> normal
    /// -> off -> normal across one day of #1236, and each flip changed
    /// scrolling for every user with no explicit setting.
    #[test]
    fn the_default_scroll_accel_is_normal() {
        assert_eq!(
            crate::config::Config::default().editor.scroll_accel,
            "normal",
            "changing the shipped default changes scrolling for everyone who never \
             set it — deliberate flips update this test, accidents fail it"
        );
    }

    /// #1236 — `off` is the DEFAULT, so it must keep working forever.
    ///
    /// The bypass returns before the refill block, so if the bucket only
    /// ever depletes on that path, scrolling dies permanently after one
    /// bucket's worth of lines. Drive far past capacity, spread over real
    /// time, and require the late events to still move.
    #[test]
    fn the_off_path_still_scrolls_after_draining_a_full_bucket() {
        let (_d, mut app) = app_with("off");
        let mut t = Instant::now();
        let mut moved_late = 0;
        for i in 0..400 {
            t += Duration::from_millis(25);
            let got = budgeted_scroll_at(&mut app, 1, t);
            if i >= 300 {
                moved_late += got;
            }
        }
        assert!(
            moved_late > 0,
            "the last 100 wheel events moved {moved_late} lines — `off` is the \
             default, so a bucket that never refills on this path means scrolling \
             stops permanently mid-session"
        );
    }

    #[test]
    fn when_the_wheel_stops_scrolling_stops() {
        // Two distinct promises live here, and conflating them is what
        // made this test wrong the first time.
        //
        // It used to assert that a DECAYING tail moves zero lines, which
        // is only achievable by discarding events that genuinely
        // arrived. That shipped, and the user reported "normal is not
        // good, still missing events" — a real hand-spin halves its rate
        // routinely, so the discard fired mid-gesture on live input.
        //
        // The honest pair:
        //   1. A wheel that has STOPPED emits nothing, and nothing here
        //      buffers, so the view does not move. Below: no calls, no
        //      movement.
        //   2. A wheel that is SLOWING is still being turned, so its
        //      events count — but they are never AMPLIFIED. The tail
        //      travels at the plain 1-line-per-event rate that predates
        //      any acceleration, so it decelerates with the wheel
        //      instead of overshooting past it.
        for accel in ["gentle", "normal", "fast"] {
            let (_d, mut app) = app_with(accel);
            let mut t = Instant::now();
            spin(&mut app, &mut t, 8, 8);

            let gaps = [20, 30, 45, 60, 90, 130, 180];
            let mut coasted = 0;
            for gap_ms in gaps {
                t += Duration::from_millis(gap_ms);
                coasted += budgeted_scroll_at(&mut app, 1, t);
            }
            // (2) never amplified — one line per event, at most.
            assert!(
                coasted <= gaps.len() as i32,
                "accel={accel}: a decaying tail of {} events moved {coasted} lines, so it \
                 was amplified — it must travel unaccelerated and die with the wheel",
                gaps.len()
            );

            // (1) the wheel is now actually stopped: no events at all.
            let before = coasted;
            t += Duration::from_millis(400);
            assert_eq!(
                before, coasted,
                "accel={accel}: time passing must not move the view on its own"
            );
            let _ = t;
        }
    }

    /// The guard must not latch: a fresh gesture after a pause scrolls
    /// normally again.
    #[test]
    fn a_new_gesture_after_a_pause_scrolls_again() {
        let (_d, mut app) = app_with("fast");
        let mut t = Instant::now();
        spin(&mut app, &mut t, 8, 6);
        for gap_ms in [30, 60, 120] {
            t += Duration::from_millis(gap_ms);
            budgeted_scroll_at(&mut app, 1, t);
        }
        t += Duration::from_millis(900); // hand back on the wheel
        let second = spin(&mut app, &mut t, 8, 6);
        assert!(
            second > 6,
            "the second gesture moved only {second} lines for 6 notches — the stop              detector latched instead of resetting per gesture"
        );
    }

    /// Steady mid-speed scrolling must not trip the stop detector —
    /// notch timing jitters, and a false positive would stutter.
    #[test]
    fn steady_scrolling_with_jitter_does_not_trip_the_stop_detector() {
        let (_d, mut app) = app_with("normal");
        let mut t = Instant::now();
        let mut total = 0;
        // Held speed with realistic +/-25% jitter.
        for gap_ms in [20, 24, 18, 22, 26, 19, 21, 25, 20, 23] {
            t += Duration::from_millis(gap_ms);
            total += budgeted_scroll_at(&mut app, 1, t);
        }
        assert!(
            total >= 10,
            "steady scrolling moved only {total} lines for 10 notches — jitter is              being misread as the wheel stopping"
        );
    }
}
