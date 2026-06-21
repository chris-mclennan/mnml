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
        SetMark(c) => app.set_mark_at_cursor(c),
        JumpToMarkLine(c) => app.jump_to_mark(c, false),
        JumpToMarkExact(c) => app.jump_to_mark(c, true),
        MacroRecordInto(c) => {
            app.set_pending_macro_register(c);
            app.macro_toggle();
        }
        MacroReplayFrom { reg, count } => {
            for _ in 0..count.max(1) {
                app.set_pending_macro_register(reg);
                app.macro_replay();
            }
        }
        BlockInsertStart { append } => app.block_insert_start(append),
        BlockChangeStart => app.block_change_start(),
        CmdlineTabComplete => app.cmdline_tab_complete(),
        CmdlinePopupMove(delta) => app.cmdline_popup_move(delta as isize),
        CmdlinePopupAcceptCurrentAndCommit => app.cmdline_popup_accept_current(),
        CmdlineEnter(typed) => {
            // 2026-06-19 — earlier impl auto-substituted the
            // popup's highlighted match if the typed first-word
            // wasn't in the registry/EX_COMPLETION_NAMES. That
            // broke legitimate vim abbreviations like `:reg`
            // (handled by ex_commands.rs but not in
            // EX_COMPLETION_NAMES). Now Enter just runs whatever
            // is in the cmdline; users wanting the popup match
            // use Tab/click first to insert it into the line.
            // 2026-06-20 — mirror the ExCommand arm: also push
            // onto App.ex_history so vim's `q:` window sees the
            // entry (otherwise vim users' history lived only in
            // the handler-side mirror, which the cmdline-history
            // pane couldn't read).
            if app.ex_history.last() != Some(&typed) {
                app.ex_history.push(typed.clone());
                if app.ex_history.len() > 100 {
                    let drop = app.ex_history.len() - 100;
                    app.ex_history.drain(..drop);
                }
            }
            app.run_ex_command(&typed);
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
    if let Some(r) = app.rects.statusline_autosave_chip
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::StatuslineAutosave);
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
    if let Some(&(_, icon_idx)) = app
        .rects
        .launcher_icon_rects
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::LauncherIcon(icon_idx));
    }
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
    if let Some(r) = app.rects.palette_dropdown_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::PaletteDropdownButton);
    }
    if let Some(&(_, action)) = app
        .rects
        .rail_git_header_buttons
        .iter()
        .find(|(r, _)| contains(*r, x, y))
    {
        return Some(crate::HoverChip::RailHeaderChip(action));
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
    if let Some(r) = app.rects.bufferline_new_tab_button
        && contains(r, x, y)
    {
        return Some(crate::HoverChip::BufferlineNewTab);
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
    None
}

pub(crate) fn scroll_under(app: &mut App, x: u16, y: u16, delta: i32) {
    if let Some(tr) = app.rects.tree
        && contains(tr, x, y)
    {
        for _ in 0..delta.unsigned_abs() {
            if delta < 0 {
                app.tree.move_up();
            } else {
                app.tree.move_down();
            }
        }
        return;
    }
    // Wheel over an extra workspace's tree body (the file list under
    // `> name`) → scroll that extra's tree cursor.
    if let Some(&(_, ws_idx, _)) = app
        .rects
        .extra_workspace_bodies
        .iter()
        .find(|(r, _, _)| contains(*r, x, y))
    {
        if let Some(ws) = app.extra_workspaces.get_mut(ws_idx) {
            for _ in 0..delta.unsigned_abs() {
                if delta < 0 {
                    ws.tree.move_up();
                } else {
                    ws.tree.move_down();
                }
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
        for _ in 0..delta.unsigned_abs() {
            if delta < 0 {
                app.git_rail_move_up();
            } else {
                app.git_rail_move_down();
            }
        }
        return;
    }
    // Wheel over the bufferline → scroll the tab strip by one per tick.
    if let Some(br) = app.rects.bufferline
        && contains(br, x, y)
    {
        if delta < 0 {
            app.bufferline_first_visible = app.bufferline_first_visible.saturating_sub(1);
        } else if app.bufferline_first_visible + 1 < app.panes.len() {
            app.bufferline_first_visible += 1;
        }
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
                let n = delta.unsigned_abs() as usize;
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
                let n = delta.unsigned_abs() as usize;
                p.scroll = if delta < 0 {
                    p.scroll.saturating_sub(n)
                } else {
                    p.scroll + n
                };
            }
            Some(Pane::Diff(d)) => {
                let n = delta.unsigned_abs() as usize;
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
            // moved to the mnml-forge-* siblings.
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
            Some(Pane::BlitHost(p)) => {
                // Forward wheel events to the hosted child as
                // scroll-up/down with the panel-local coordinates;
                // it owns its own scroll model.
                let kind = if delta < 0 {
                    tmnl_protocol::MouseKind::ScrollUp
                } else {
                    tmnl_protocol::MouseKind::ScrollDown
                };
                let col = (x.saturating_sub(tr.x)).min(p.channel.cols.saturating_sub(1));
                let row = (y.saturating_sub(tr.y)).min(p.channel.rows.saturating_sub(1));
                for _ in 0..delta.unsigned_abs() {
                    p.channel.send_input(tmnl_protocol::InputEvent::Mouse(
                        tmnl_protocol::MouseInput {
                            kind,
                            button: tmnl_protocol::BUTTON_NONE,
                            col,
                            row,
                            mods: 0,
                        },
                    ));
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

/// Apply an in-progress mixr-panel drag to its `float` rect — clamped
/// to `body` so the window can't move or grow past an edge, and never
/// shrinks below a usable minimum.
pub(crate) fn apply_mixr_drag(
    float: &mut Rect,
    body: Rect,
    kind: crate::mixr_host::MixrDrag,
    x: u16,
    y: u16,
) {
    use crate::mixr_host::MixrDrag;
    const MIN_W: u16 = 24;
    const MIN_H: u16 = 8;
    let body_right = body.x.saturating_add(body.width);
    let body_bottom = body.y.saturating_add(body.height);
    match kind {
        MixrDrag::Move { grab_dx, grab_dy } => {
            let max_x = body_right.saturating_sub(float.width).max(body.x);
            let max_y = body_bottom.saturating_sub(float.height).max(body.y);
            float.x = x.saturating_sub(grab_dx).clamp(body.x, max_x);
            float.y = y.saturating_sub(grab_dy).clamp(body.y, max_y);
        }
        MixrDrag::ResizeLeft => {
            let right = float.x.saturating_add(float.width);
            let hi = right.saturating_sub(MIN_W).max(body.x);
            let new_x = x.clamp(body.x, hi);
            float.x = new_x;
            float.width = right.saturating_sub(new_x).max(MIN_W);
        }
        MixrDrag::ResizeRight => {
            let lo = float.x.saturating_add(MIN_W).min(body_right);
            let new_right = x.saturating_add(1).clamp(lo, body_right);
            float.width = new_right.saturating_sub(float.x).max(MIN_W);
        }
        MixrDrag::ResizeBottom => {
            let lo = float.y.saturating_add(MIN_H).min(body_bottom);
            let new_bottom = y.saturating_add(1).clamp(lo, body_bottom);
            float.height = new_bottom.saturating_sub(float.y).max(MIN_H);
        }
    }
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
        if let Some(Pane::Diagnostics(d)) = app.panes.get_mut(pane_id)
            && flat_idx < d.items.len()
        {
            d.selected = flat_idx;
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
    // their standalone mnml-forge-* sibling binaries.
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
