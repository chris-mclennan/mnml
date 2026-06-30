//! Left-click (`MouseEventKind::Down(MouseButton::Left)`) dispatch
//! — extracted from `mouse/mod.rs` (T-5 of the file-split refactor,
//! 2026-06-29). At ~1700 lines this was the biggest chunk of
//! dispatch_mouse: every clickable surface — rail rows, palette
//! bar buttons, statusline chips, panel chrome, dock widgets,
//! pane bodies, scrollbars, drag-start, drop targets, and so on.
//!
//! Public surface: `handle_down_left(app, m, x, y, ...)`. Called
//! from `dispatch_mouse`'s left-Down arm. Returns nothing; each
//! consuming branch uses `return` to exit this function only,
//! leaving the outer match arm to complete naturally.

use ratatui::crossterm::event::{KeyModifiers, MouseEvent};

use super::{send_macos_player, send_mixr_command};
use crate::app::App;
use crate::command;
use crate::pane::Pane;

pub(super) fn handle_down_left(app: &mut App, m: MouseEvent, x: u16, y: u16) {
    // Grab the rail's right-edge resize handle first — its grip
    // band shares the rail's rightmost column with the file-tree
    // scrollbar, so the (specific, ~4-row) resize zone must win
    // there before the (full-height) scrollbar claims the click.
    if app.begin_tree_edge_drag(x, y) {
        return;
    }
    // vscode-user-mouse SEV-1 — mirror for the right-panel
    // grip. Without this, the field stayed false and the
    // grip was decorative.
    if app.maybe_start_right_panel_edge_drag(x, y) {
        return;
    }
    // Right-panel v3: tab strip click → switch active tab.
    // Checked BEFORE the × close since the tabs occupy the
    // left half of the same row.
    if let Some(&(_, tab_idx)) = app
        .rects
        .right_panel_tabs
        .iter()
        .find(|(rect, _)| crate::app::dispatch::contains(*rect, x, y))
    {
        app.right_panel_active_idx = tab_idx;
        return;
    }
    // mouse-polish F-2 — empty-state command lines as
    // click targets so a mouse-first user can populate
    // the panel without typing.
    if let Some(rect) = app.rects.right_panel_empty_outline
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("outline.show", app);
        return;
    }
    if let Some(rect) = app.rects.right_panel_empty_diagnostics
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("lsp.diagnostics", app);
        return;
    }
    // design-critic 2026-06-28 #3 — 3 more empty-state
    // click rects so all 5 routable commands are mouse
    // reachable from the empty state.
    if let Some(rect) = app.rects.right_panel_empty_ai
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("ai.chat", app);
        return;
    }
    if let Some(rect) = app.rects.right_panel_empty_grep
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("find.grep", app);
        return;
    }
    if let Some(rect) = app.rects.right_panel_empty_test
        && crate::app::dispatch::contains(rect, x, y)
    {
        crate::command::run("test.run", app);
        return;
    }
    // Right-panel v3 `×` on the header closes the active
    // tab (panel stays open; next tab takes its place, or
    // empty-state returns if it was the last).
    if let Some(rect) = app.rects.right_panel_close
        && crate::app::dispatch::contains(rect, x, y)
    {
        if let Some(pid) = app.right_panel_active_pane_id() {
            // crash-investigator SEV-1 #3: close_pane FIRST.
            // On a dirty editor this exits early with a close
            // prompt; the pane is still in right_panel_panes
            // so confirm-discard routes through
            // remove_pane_storage which now also drops the
            // right-panel record. For non-dirty panes,
            // remove_pane_storage takes care of the shift.
            app.close_pane(pid);
        }
        return;
    }
    // Grab a scrollbar (editor / diff / embedded-diff / tree) before
    // any pane-level handler — the bar sits inside the pane's
    // own rect, so without this short-circuit a click on the
    // bar would also land in the editor / row-select handlers
    // below and shift the cursor / row selection.
    if app.begin_scrollbar_drag(x, y) {
        return;
    }
    // Grab the GitGraph commit-list ↔ detail-panel divider?
    if app.begin_git_graph_detail_drag(x, y) {
        return;
    }
    // Grab a split divider? (do this first — it sits between two pane rects)
    if app.begin_divider_drag(x, y) {
        return;
    }
    // Click on a fold chip → unfold that block. Match before the
    // editor-pane click handler so the chip "owns" the click.
    if let Some(&(_, pid, start)) = app
        .rects
        .fold_chips
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            b.folds.remove(&start);
        }
        return;
    }
    // Click on a code-lens chip → fire its `workspace/executeCommand`.
    // Same priority as fold chips — chip owns the click.
    if let Some(&(_, pid, lens_idx)) = app
        .rects
        .code_lens_chips
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        app.trigger_code_lens(pid, lens_idx);
        return;
    }
    // Click on a WIP-detail button → fire its action (stage/unstage
    // file or all, open commit prompt, request AI commit message).
    // High priority so the button "owns" the click instead of the
    // pane-focus handler eating it.
    if let Some((_, pid, action)) = app
        .rects
        .wip_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.active = Some(pid);
        app.focus_pane();
        // Clicking a button blurs the textarea so the user
        // doesn't keep typing into a no-longer-visible field.
        app.blur_active_wip_commit_textarea();
        app.run_wip_action(action);
        return;
    }
    // Click on a WIP-detail file row (not the button) →
    // open that file's diff (`Pane::Diff`) so the user can
    // browse Hunk / Inline / Split views.
    if let Some((_, pid, abs_path, staged)) = app
        .rects
        .wip_file_rows
        .iter()
        .find(|(r, _, _, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.active = Some(pid);
        app.focus_pane();
        app.blur_active_wip_commit_textarea();
        app.click_wip_file_row(abs_path, staged);
        return;
    }
    // Click inside the WIP commit textarea rect → focus it.
    // Wins over the pane-focus handler so the click both
    // focuses the GitGraph pane AND focuses the textarea.
    if let Some((r, pid)) = app.rects.wip_commit_textarea
        && crate::app::dispatch::contains(r, x, y)
    {
        app.active = Some(pid);
        app.focus_pane();
        app.focus_wip_commit_textarea(pid);
        return;
    }
    // Click on a GitGraph top-toolbar button → fire its action.
    // Pull / Push / Fetch / Branch / Commit / Stash / Pop /
    // Reflog / Terminal. High priority so the button owns the
    // click.
    if let Some(&(_, pid, action)) = app
        .rects
        .git_toolbar_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        app.run_git_toolbar_action(action);
        return;
    }
    // Click on a per-hunk action chip ([Stage] / [Unstage]
    // / [Discard]) in the Hunk view's header row → dispatch
    // the action against that hunk. Runs before the
    // toolbar / row click handlers so the chip "owns" the
    // click.
    if let Some(&(_, pid, hi, action)) = app
        .rects
        .diff_hunk_buttons
        .iter()
        .find(|(r, _, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        app.apply_hunk_action(pid, hi, action);
        return;
    }
    // Click on a Diff pane toolbar button → switch view mode
    // or toggle wrap. Also store the choice as the App-level
    // preference so every subsequent diff opens in that mode.
    // Works against both a standalone `Pane::Diff` and a
    // `Pane::GitGraph` with an embedded diff (when the user
    // clicked a file from a commit's right-side detail panel
    // and the diff opened in-place on the left).
    if let Some(&(_, pid, action)) = app
        .rects
        .diff_toolbar_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        // `Close` is special — clears embedded diff if any,
        // else closes the standalone Pane::Diff. Returns
        // before the view-mode handling block since the
        // pane may no longer exist after closing.
        if matches!(action, crate::DiffToolbarAction::Close) {
            match app.panes.get_mut(pid) {
                Some(Pane::GitGraph(g)) if g.embedded_diff.is_some() => {
                    g.embedded_diff = None;
                }
                Some(Pane::Diff(_)) => {
                    app.close_pane(pid);
                }
                _ => {}
            }
            return;
        }
        let mut new_wrap_pref: Option<bool> = None;
        let mut new_mode_pref: Option<crate::pane::DiffViewMode> = None;
        let dv: Option<&mut crate::pane::DiffView> = match app.panes.get_mut(pid) {
            Some(Pane::Diff(d)) => Some(d),
            Some(Pane::GitGraph(g)) => g.embedded_diff.as_mut(),
            _ => None,
        };
        if let Some(d) = dv {
            match action {
                crate::DiffToolbarAction::ViewInline => {
                    d.view_mode = crate::pane::DiffViewMode::Inline;
                    new_mode_pref = Some(d.view_mode);
                }
                crate::DiffToolbarAction::ViewHunk => {
                    d.view_mode = crate::pane::DiffViewMode::Hunk;
                    new_mode_pref = Some(d.view_mode);
                }
                crate::DiffToolbarAction::ViewSplit => {
                    d.view_mode = crate::pane::DiffViewMode::Split;
                    new_mode_pref = Some(d.view_mode);
                }
                crate::DiffToolbarAction::ToggleWrap => {
                    d.wrap = !d.wrap;
                    new_wrap_pref = Some(d.wrap);
                }
                crate::DiffToolbarAction::Close => unreachable!(),
            }
        }
        if let Some(m) = new_mode_pref {
            app.diff_view_mode_pref = m;
        }
        if let Some(w) = new_wrap_pref {
            app.diff_wrap_pref = w;
        }
        return;
    }
    // Click on a commit-detail changed-file row → open that
    // file's diff for the selected commit.
    if let Some(&(_, pid, file_idx)) = app
        .rects
        .commit_file_rows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        app.click_commit_file_row(pid, file_idx);
        return;
    }
    // Click on a request-pane tab chip → switch view (Edit ⇄ Response).
    if let Some(&(_, pid, view)) = app
        .rects
        .request_tabs
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
            rp.view = view;
        }
        return;
    }
    // Click on a row in the cmdline completion popup →
    // accept that match (writes the completion into the
    // cmdline and bumps cmdline_popup_selected so subsequent
    // Tabs continue from there). 2026-06-19 — discoverability
    // gold: users can mouse-pick from the popup.
    if let Some(&(_, idx)) = app
        .rects
        .cmdline_popup_items
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.cmdline_popup_accept(idx);
        return;
    }
    // Click on an Auth-tab action row → dispatch to the
    // matching App method (prompt or palette command).
    if let Some((_, id)) = app
        .rects
        .request_auth_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        app.http_auth_row_clicked(&id);
        return;
    }
    // Click on the AI section header → opens a prompt
    // asking what the user wants to know (custom Q + A).
    // The `a` key still fires the default debug prompt
    // (no question, just 'why is this not working').
    if let Some(r) = app.rects.request_ai_section
        && crate::app::dispatch::contains(r, x, y)
    {
        app.ai_ask_about_request_prompt();
        return;
    }
    // Click on a Vars-tab row → open the env editor
    // directly. Empty key (the `+ Add` row) → add prompt;
    // non-empty key → edit prompt for that key.
    if let Some((_, key)) = app
        .rects
        .request_vars_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        if key.is_empty() {
            app.accept_env_vars("+add");
        } else {
            app.accept_env_vars(&key);
        }
        return;
    }
    // Click on a Params-tab row → empty (`+ Add`) opens
    // the KEY=VALUE prompt; non-empty deletes that param
    // from the URL (v2 will open an edit prompt instead).
    if let Some((_, key)) = app
        .rects
        .request_params_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        if key.is_empty() {
            app.http_params_add();
        } else {
            app.http_params_delete(&key);
        }
        return;
    }
    // Click on a Request pane Edit-view tab chip (Body /
    // Headers / Params / Vars / Source) → switch the
    // pane's edit_tab.
    if let Some(&(_, pid, tab)) = app
        .rects
        .request_edit_tabs
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.edit_tab = tab;
            if tab == crate::request_pane::EditTab::Source {
                rp.focus = crate::request_pane::EditField::Source;
            } else if rp.focus == crate::request_pane::EditField::Source {
                rp.focus = crate::request_pane::EditField::Url;
            }
        }
        return;
    }
    // Click on a request-pane Edit-mode field row → focus that field.
    // 2026-06-19 — vscode-user-mouse agent caught that the
    // caret was never positioned at the click site (it stayed
    // wherever it was, typically end-of-value). For the URL
    // field — the most common edit target — compute the byte
    // position from the visual column and update url_cursor.
    // Headers / Body are multi-line; positioning their carets
    // by click requires per-row mapping that's a v2 follow-up;
    // they still get focused so the user can type / use arrows.
    if let Some(&(rect, pid, field)) = app
        .rects
        .request_fields
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        if let Some(Pane::Request(rp)) = app.panes.get_mut(pid) {
            rp.view = crate::request_pane::ViewMode::Edit;
            rp.focus = field;
            // 2026-06-20 — Method chip click opens a
            // verb-picker context menu (one entry per
            // HTTP verb). Click an item → method set.
            // Width ≤ 12 disambiguates the chip rect from
            // the wider headers/body rows.
            let chip_clicked =
                matches!(field, crate::request_pane::EditField::Method) && rect.width <= 12;
            if chip_clicked {
                let _ = rp;
                app.open_method_dropdown((x, y));
                return;
            }
            if matches!(field, crate::request_pane::EditField::Url) {
                // URL row layout: " URL  <value>". Label
                // offset = leading-space + "URL" + 2 spaces ≈
                // 6 cells. Visual column within the value =
                // click x - rect.x - label_offset. Convert
                // visual column to a byte position via
                // char_indices(); clamp to value length.
                let dx = x.saturating_sub(rect.x);
                let label_offset: u16 = 6;
                let visual_col = dx.saturating_sub(label_offset) as usize;
                let url = &rp.request.url;
                let byte_pos = url
                    .char_indices()
                    .nth(visual_col)
                    .map(|(i, _)| i)
                    .unwrap_or(url.len());
                rp.url_cursor = byte_pos;
            }
        }
        return;
    }
    // Bufferline overflow chevrons — scroll the tab strip by one.
    if let Some(r) = app.rects.bufferline_overflow_left
        && crate::app::dispatch::contains(r, x, y)
    {
        if app.bufferline_first_visible > 0 {
            app.bufferline_first_visible -= 1;
            // qa-7th vscode SEV-2 — stamp the active pane so the
            // auto-scroll-to-keep-active-visible logic in
            // ui::bufferline::draw doesn't immediately clobber
            // this manual scroll. Cleared when active changes.
            app.bufferline_active_at_scroll = app.active;
        }
        return;
    }
    if let Some(r) = app.rects.bufferline_overflow_right
        && crate::app::dispatch::contains(r, x, y)
    {
        // qa-8th crash SEV-3 2026-06-30 — was app.panes.len(),
        // which includes right_panel_panes (not in the bufferline
        // visible list). The render-side clamp swallowed the
        // extra clicks silently. Use the actual visible count.
        let visible_count = app.panes.len().saturating_sub(app.right_panel_panes.len());
        if app.bufferline_first_visible + 1 < visible_count {
            app.bufferline_first_visible += 1;
            app.bufferline_active_at_scroll = app.active;
        }
        return;
    }
    // Bufferline tab — clicking the close badge closes; clicking elsewhere on the tab activates.
    if let Some(&(_, id)) = app
        .rects
        .bufferline_tab_close
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.close_pane(id);
        return;
    }
    if let Some(&(_, id)) = app
        .rects
        .bufferline_tabs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // Arm a drag — the buffer-switch (reveal) is deferred to
        // mouse-up so a drag-to-split doesn't first swap the grabbed
        // tab into the pane (which would make the drop land on its own
        // pane). A subsequent Drag into another tab's rect reorders;
        // a Drag onto a pane body splits. On a plain click (up on the
        // same tab) the Up handler reveals.
        app.rects.bufferline_drag_tab = Some(id);
        return;
    }
    // Pty-pane tab strip — click `+` to add a new Claude session
    // as a TAB of that strip's leaf (no split); click a session
    // tab to switch; click the `×` to kill that session. Test
    // close BEFORE switch so the badge wins over the chip body.
    if let Some(&(_, pid)) = app
        .rects
        .pty_tab_close
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.close_pane(pid);
        return;
    }
    if let Some(&(_, owner)) = app
        .rects
        .pty_tab_new
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let profile = crate::pty_pane::BinaryProfile::claude_code(app.workspace.clone());
        app.add_pty_tab(owner, profile);
        return;
    }
    if let Some(&(_, pid)) = app
        .rects
        .pty_tabs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.reveal_pane(pid);
        return;
    }
    // Bufferline right cluster — Claude / Codex launch chips,
    // `+` new tab, per-tabpage chip / close, theme toggle,
    // window close. Order matters (the `⊗` rect sits adjacent
    // to its chip; check close before chip).
    // Palette top-bar — sidebar / back / forward / chip / dropdown.
    if let Some(r) = app.rects.palette_sidebar_button
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("view.toggle_tree", app);
        return;
    }
    if let Some(r) = app.rects.palette_right_panel_button
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("view.toggle_right_panel", app);
        return;
    }
    if let Some(r) = app.rects.palette_add_integration_button
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("integrations.add", app);
        return;
    }
    if let Some(r) = app.rects.palette_back_button
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("buffer.prev", app);
        return;
    }
    if let Some(r) = app.rects.palette_forward_button
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("buffer.next", app);
        return;
    }
    if let Some(r) = app.rects.palette_search_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_command_palette();
        return;
    }
    if let Some(r) = app.rects.palette_dropdown_button
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("picker.recent", app);
        return;
    }
    // Launcher-icon strip — click hands off to the configured
    // command (registered command id, or ex-cmdline string).
    if let Some(&(_, icon_idx)) = app
        .rects
        .launcher_icon_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        && let Some(icon) = app.config.ui.launcher_icons.get(icon_idx)
    {
        let cmd = icon.command.clone();
        if let Some(rest) = cmd.strip_prefix(':') {
            app.run_ex_command(rest);
        } else {
            crate::command::run(&cmd, app);
        }
        return;
    }
    if let Some(r) = app.rects.bufferline_new_tab_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.tab_new(None);
        return;
    }
    if let Some(&(_, idx)) = app
        .rects
        .bufferline_tab_page_close
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.tab_close_at(idx);
        return;
    }
    if let Some(&(_, idx)) = app
        .rects
        .bufferline_tab_page_chips
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.switch_tab(idx);
        // Arm a drag — a subsequent mouse-drag over a
        // different chip's rect swaps the two tabs.
        app.dragging_tab_page = Some(app.active_layout);
        return;
    }
    // 2026-06-22 — per-split tab chip clicks (multi-tab
    // leaves). Close × FIRST so a close-button click in the
    // chip body doesn't get swallowed by the chip-switch.
    if let Some(&(_, leaf_active, tab_pane)) = app
        .rects
        .split_tab_close
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.close_split_tab(leaf_active, tab_pane);
        return;
    }
    // AI launch button in the split-strip cluster.
    // Focus the clicked leaf, then fire the configured
    // `ai.*` command (Claude Code / Codex).
    if let Some(&(_, leaf_active)) = app
        .rects
        .split_strip_ai_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let cmd = match app.config.ui.tab_bar_ai_icon.as_str() {
            "codex" => "ai.codex",
            _ => "ai.claude_code",
        };
        app.active = Some(leaf_active);
        app.focus = crate::focus::Focus::Pane;
        crate::command::run(cmd, app);
        return;
    }
    // Terminal button in the split-strip cluster.
    // Focus the clicked leaf, then open a shell in a
    // split (mirrors the `term.shell` palette command).
    if let Some(&(_, leaf_active)) = app
        .rects
        .split_strip_term_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(leaf_active);
        app.focus = crate::focus::Focus::Pane;
        app.open_shell();
        return;
    }
    // 2026-06-22 — per-split split-editor buttons at the
    // right of the strip. Focus the clicked leaf's active
    // pane, then dispatch split_active(dir).
    if let Some(&(_, leaf_active, dir)) = app
        .rects
        .split_strip_buttons
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(leaf_active);
        app.focus = crate::focus::Focus::Pane;
        app.split_active(dir);
        return;
    }
    if let Some(&(_, leaf_active, tab_pane)) = app
        .rects
        .split_tab_chips
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // 2026-06-27 — arm a drag like the bufferline tab
        // handler does, so per-leaf tabs are also
        // drag-to-split / drag-to-move. Without this,
        // a click on a per-leaf tab activated the tab
        // and returned, never setting bufferline_drag_tab,
        // so subsequent Drag / Moved events did nothing.
        // The bufferline_drag_tab field doubles as the
        // drag-source for both global bufferline AND
        // per-leaf strips — the pane id is the same.
        app.rects.bufferline_drag_tab = Some(tab_pane);
        // Switch the visible tab immediately so the click
        // also activates as the user expects. The mouse-up
        // handler will still see bufferline_drag_tab Some
        // and route through drop / reveal logic.
        let now = std::time::Instant::now();
        let is_double = matches!(
            app.last_click,
            Some((prev, px, py, _))
                if px == x
                    && py == y
                    && now.duration_since(prev) < std::time::Duration::from_millis(450)
        );
        app.last_click = Some((now, x, y, if is_double { 2 } else { 1 }));
        if is_double && let Some(Pane::Editor(b)) = app.panes.get_mut(tab_pane) {
            b.is_preview = false;
        }
        app.switch_split_tab(leaf_active, tab_pane);
        return;
    }
    if let Some(r) = app.rects.bufferline_theme_toggle
        && crate::app::dispatch::contains(r, x, y)
    {
        // NvChad convention: the slider is a binary toggle between
        // `[ui] theme` ↔ `[ui] theme_toggle`. Falls back to opening
        // the picker when `theme_toggle` is unconfigured.
        if app.config.ui.theme_toggle.is_some() {
            app.toggle_theme();
        } else {
            app.open_theme_picker();
        }
        return;
    }
    if let Some(r) = app.rects.bufferline_window_close
        && crate::app::dispatch::contains(r, x, y)
    {
        app.close_active_pane();
        return;
    }
    // Statusline branch chip → open the commit graph. Always-visible
    // click target for git.graph (vs the keyboard-only `<leader>g l`).
    if let Some(r) = app.rects.statusline_branch_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("git.graph", app);
        return;
    }
    // Statusline test-runner chip → focus the test pane.
    if let Some(r) = app.rects.statusline_test_chip
        && crate::app::dispatch::contains(r, x, y)
        && let Some((_, pane_idx)) = app.last_test_run
        && pane_idx < app.panes.len()
    {
        app.active = Some(pane_idx);
        app.focus_pane();
        return;
    }
    // Statusline mode chip → toggle input style (vim ↔ standard).
    if let Some(r) = app.rects.statusline_mode_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("editor.toggle_keymap", app);
        return;
    }
    // Cmdline bar — click anywhere on the bottom 1-row strip
    // opens the ex-cmdline (same as typing `:`). Checked
    // BEFORE the statusline chips because the bar sits below
    // the statusline and overlapping hit-rects are otherwise
    // resolved top-down. A click while the cmdline is
    // already open is a no-op (let the user keep typing).
    //
    // 2026-06-20 — check the right-side `⟳ … running…`
    // indicator FIRST so clicks there abort the in-flight
    // op instead of opening the cmdline. Same area covers
    // both targets; narrower one wins.
    if let Some(r) = app.rects.cmdline_inflight
        && crate::app::dispatch::contains(r, x, y)
    {
        app.http_abort_all();
        return;
    }
    // 2026-06-20 — toast `[name]` mention: click reveals
    // the matching pane (substring match on pane title).
    if let Some((r, name)) = app.rects.cmdline_toast_target.clone()
        && crate::app::dispatch::contains(r, x, y)
        && let Some((idx, _)) = app
            .panes
            .iter()
            .enumerate()
            .find(|(_, p)| p.title().contains(&name))
    {
        app.active = Some(idx);
        app.focus_pane();
        app.reveal_pane(idx);
        return;
    }
    if app.no_pane_cmdline.is_none()
        && let Some(r) = app.rects.cmdline_bar
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_ex_command_prompt();
        return;
    }
    // Statusline workspace / active-repo chip → open the repo picker
    // (single-repo workspace toasts "only one repo").
    if let Some(r) = app.rects.statusline_workspace_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_repo_picker();
        return;
    }
    // Statusline clock chip → flip between local and UTC.
    if let Some(r) = app.rects.statusline_clock_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.clock_show_utc = !app.clock_show_utc;
        app.toast(if app.clock_show_utc {
            "clock: UTC"
        } else {
            "clock: local"
        });
        return;
    }
    // Play / pause control — source-aware: mixr → pause IPC,
    // Apple Music / Spotify → AppleScript `playpause`. Checked
    // before the track-text chip because the three sit
    // adjacent. Returns silently when no source matches
    // (cluster is in idle form).
    if let Some(r) = app.rects.statusline_mixr_play_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let source = app
            .now_playing
            .as_ref()
            .map(|np| np.source.as_str())
            .unwrap_or("");
        if source.eq_ignore_ascii_case("mixr") {
            send_mixr_command("pause");
        } else if !source.is_empty() {
            send_macos_player(source, "playpause");
        }
        return;
    }
    // Ffwd control — mixr → teleport (jump on beat to just
    // before mix-out); Apple Music / Spotify → next track via
    // AppleScript.
    if let Some(r) = app.rects.statusline_mixr_ffwd_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let source = app
            .now_playing
            .as_ref()
            .map(|np| np.source.as_str())
            .unwrap_or("");
        if source.eq_ignore_ascii_case("mixr") {
            send_mixr_command("teleport");
        } else if !source.is_empty() {
            send_macos_player(source, "next track");
        }
        return;
    }
    // Track text — source-aware activate:
    //   * mixr        → `mixr.show` (open / cycle the docked
    //                   panel; today's behavior)
    //   * Music       → AppleScript `activate` (brings the app
    //                   forward without changing playback)
    //   * Spotify     → AppleScript `activate`
    //   * idle (none) → activate the user's preferred app
    //                   (`ui.preferred_music_app`), opening
    //                   Music / Spotify or the mixr panel
    //                   based on the Settings pick.
    if let Some(r) = app.rects.statusline_mixr_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let source = app
            .now_playing
            .as_ref()
            .map(|np| np.source.as_str())
            .unwrap_or("");
        if source.eq_ignore_ascii_case("mixr") {
            command::run("mixr.show", app);
        } else if !source.is_empty() {
            send_macos_player(source, "activate");
        } else {
            // Idle — use the preferred-app pick.
            match app.config.ui.preferred_music_app.as_str() {
                "music" => send_macos_player("Music", "activate"),
                "spotify" => send_macos_player("Spotify", "activate"),
                _ => {
                    command::run("mixr.show", app);
                }
            }
        }
        return;
    }
    // LSP chip → :LspStatus toast (breakdown of running servers).
    if let Some(r) = app.rects.statusline_lsp_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.run_ex_command("LspStatus");
        return;
    }
    // WRAP chip → toggle `[ui] wrap`.
    if let Some(r) = app.rects.statusline_wrap_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.config.ui.wrap = !app.config.ui.wrap;
        app.toast(if app.config.ui.wrap {
            "wrap: on"
        } else {
            "wrap: off"
        });
        return;
    }
    // Autosave chip → :set autosave_secs= prompt (palette command).
    if let Some(r) = app.rects.statusline_autosave_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.toast(format!(
            "autosave: {}s (`:set autosave_secs=N` to change)",
            app.config.editor.autosave_secs
        ));
        return;
    }
    // Filesize chip → :Stat toast.
    if let Some(r) = app.rects.statusline_filesize_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.run_ex_command("Stat");
        return;
    }
    // Ln/Col chip → goto-line prompt.
    if let Some(r) = app.rects.statusline_lncol_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        let _ = crate::command::run("editor.goto_line", app);
        return;
    }
    // Activity bar (the 4-cell vscode-style strip on the far
    // left of the rail). Click an icon → switch the active
    // section. Checked before the tree-icon row + workspace
    // toggle since the strip occupies the same x-range.
    if let Some(&(_, section)) = app
        .rects
        .activity_bar_icons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // Git icon: switch the rail to the GitKraken-style
        // git palette AND open the git graph as a pane in
        // the editor area. The two work together — the
        // rail navigates branches / worktrees / PRs while
        // the graph shows commit history + diff. Other
        // activity sections just switch the rail.
        app.set_activity_section(section);
        if matches!(section, crate::app::ActivitySection::Git) {
            crate::command::run("git.graph", app);
        }
        if let crate::app::ActivitySection::Mount(idx) = section {
            app.open_mount_from_manifest(idx);
        }
        return;
    }
    // Gear icon at the bottom of the activity bar → pop the
    // VS Code-style settings menu.
    if let Some(r) = app.rects.activity_bar_gear
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_gear_context_menu((x, y));
        return;
    }
    // Search activity-bar section result rows — click → open
    // the hit's file at its line:col. Checked before tree
    // icons since they may overlap (tree_icon_buttons spans
    // the same width).
    if let Some(&(_, idx)) = app
        .rects
        .search_section_hit_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.search_section_open_hit(idx);
        return;
    }
    // File-tree toolbar icons (row 0 of the rail). Check BEFORE
    // the WORKSPACE-toggle below since the workspace header is row 1
    // and the icon row sits above it. Each chip dispatches a palette
    // command by id.
    if let Some(&(_, cmd_id)) = app
        .rects
        .tree_icon_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let _ = crate::command::run(cmd_id, app);
        return;
    }
    // INTEGRATIONS icon — hand off to the configured command.
    // Two command forms supported:
    //   `:<ex>`  → mnml ex command
    //   `<id>`   → mnml registered command id
    // Check BEFORE the section-toggle below.
    if let Some(&(_, icon_idx)) = app
        .rects
        .integration_icon_rects
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        && let Some(icon) = app.config.ui.integration_icons.get(icon_idx)
    {
        // api-workflow-user F4 — disabled chips still appear
        // in the RAIL strip (binary-availability-filtered) but
        // shouldn't fire on left-click. Toast a hint instead
        // so the user knows the menu is available.
        if !icon.enabled {
            let label = icon
                .tooltip
                .clone()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| icon.id.clone());
            app.toast(format!("{label}: disabled (right-click → Enable)"));
            return;
        }
        let cmd = icon.command.clone();
        if let Some(rest) = cmd.strip_prefix(':') {
            app.run_ex_command(rest);
        } else {
            crate::command::run(&cmd, app);
        }
        return;
    }
    // Menu-bar item click — fire the palette command and
    // close the dropdown.
    if let Some(&(_, item_idx)) = app
        .rects
        .menu_bar_items
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        && let Some(open) = app.menu_open.as_ref().cloned()
    {
        let menus = crate::menu_bar::bar();
        if let Some(menu) = menus.get(open.menu_idx)
            && let Some(crate::menu_bar::MenuItem::Action { command_id, .. }) =
                menu.items.get(item_idx)
        {
            let id = *command_id;
            app.menu_open = None;
            crate::command::run(id, app);
        }
        return;
    }
    // Menu-bar word click — toggle the dropdown.
    if let Some(&(_, menu_idx)) = app
        .rects
        .menu_bar_words
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let already_open = app
            .menu_open
            .as_ref()
            .is_some_and(|s| s.menu_idx == menu_idx);
        app.menu_open = if already_open {
            None
        } else {
            Some(crate::menu_bar::MenuOpenState::new_mouse(menu_idx))
        };
        return;
    }
    // Click anywhere else while a menu is open → close it.
    // Fall through to the rest of the dispatch (the click
    // still hits the underlying target).
    if app.menu_open.is_some() {
        app.menu_open = None;
        // Don't return — the click goes through to the
        // underlying target (e.g. an editor pane, a tab).
    }
    // `> INTEGRATIONS` section header — arm drag-resize. On
    // mouse-up: !moved → toggle collapse; moved → commit
    // the new max height.
    if let Some(tr) = app.rects.integration_section_toggle
        && crate::app::dispatch::contains(tr, x, y)
    {
        app.rail_section_drag = Some(crate::app::RailSectionDrag {
            kind: crate::app::RailSectionKind::Integrations,
            start_y: y,
            start_h: app.rects.integration_section_h.max(1),
            moved: false,
        });
        return;
    }
    // The `> WORKSPACE-NAME` section header — clicking it toggles the
    // workspace section's expand/collapse state (VS-Code Explorer-style).
    if let Some(tr) = app.rects.tree_toggle
        && crate::app::dispatch::contains(tr, x, y)
    {
        app.toggle_tree_root_expanded();
        return;
    }
    // GIT header right-aligned chip cluster — Fetch / Pull / Push /
    // Stage all / Commit / Graph. Check BEFORE the toggle so the
    // chip wins over the section-collapse gesture.
    if let Some(&(_, action)) = app
        .rects
        .rail_git_header_buttons
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.run_git_rail_header_action(action);
        return;
    }
    // qa-feature 2026-06-30 — GitGraph repo-switch pill. The
    // sidebar's pill is anchored to the GIT pane's repo, so the
    // most useful click action is `switch_active_repo` (changes
    // what the git pane is looking at, which is what the user
    // expects from a dropdown next to the repo name). Fallback
    // cascade: 2+ repos → open_repo_picker; extras configured →
    // open_workspace_picker; else open_workspaces_editor so the
    // click leads somewhere even on a single-repo single-WS setup.
    if let Some(rect) = app.rects.git_graph_repo_switch
        && crate::app::dispatch::contains(rect, x, y)
    {
        if app.repos.len() > 1 {
            app.open_repo_picker();
        } else if !app.extra_workspaces.is_empty() {
            app.open_workspace_picker();
        } else {
            app.open_workspaces_editor();
        }
        return;
    }
    // GitGraph column header click → cycle sort. Falls through to
    // the row-click handler since the header row is OUTSIDE
    // `app.rects.list_rows`.
    if let Some(&(_, col)) = app
        .rects
        .git_graph_column_headers
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(cur) = app.active
            && let Some(crate::pane::Pane::GitGraph(g)) = app.panes.get_mut(cur)
        {
            g.cycle_sort(col);
        }
        return;
    }
    // The `> GIT` section header — arm drag-resize. Mouse-up
    // without movement falls through to the toggle; movement
    // commits the new max height.
    if let Some(tr) = app.rects.git_section_toggle
        && crate::app::dispatch::contains(tr, x, y)
    {
        app.rail_section_drag = Some(crate::app::RailSectionDrag {
            kind: crate::app::RailSectionKind::Git,
            start_y: y,
            start_h: app.rects.git_section_h.max(1),
            moved: false,
        });
        return;
    }
    // Extra-workspace section header → toggle expansion.
    if let Some(&(_, ws_idx)) = app
        .rects
        .extra_workspace_toggles
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.toggle_extra_workspace(ws_idx);
        return;
    }
    // Extra-workspace row click → focus / select / open in that tree.
    if let Some(&(tr, ws_idx, scroll)) = app
        .rects
        .extra_workspace_bodies
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        let row_idx = (y - tr.y) as usize + scroll;
        app.click_extra_workspace_row(ws_idx, row_idx);
        return;
    }
    // Tree? (no header now — row 0 of the rail is the first entry)
    if let Some(tr) = app.rects.tree
        && crate::app::dispatch::contains(tr, x, y)
    {
        app.focus_tree();
        app.rail_section = crate::app::RailSection::Workspace;
        // Clicking the primary tree returns focus from any
        // extra workspace; cursor highlight follows.
        app.focused_extra_ws = None;
        // VS Code preview/pin gesture: single-click on a file
        // opens it as a preview tab (replaceable by the next
        // single-click); double-click promotes to a real tab
        // (the editor's `open_path` non-preview path is the
        // promotion). Use the same `last_click` tracker the
        // editor uses for word/line select.
        // vscode-mouse-2026-06-10 SEV-2 #5.
        let now = std::time::Instant::now();
        let count = match app.last_click {
            Some((prev, px, py, c))
                if px == x
                    && py == y
                    && now.duration_since(prev) < std::time::Duration::from_millis(450) =>
            {
                (c + 1).min(3)
            }
            _ => 1,
        };
        app.last_click = Some((now, x, y, count));
        {
            let idx = (y - tr.y) as usize + app.rects.tree_scroll;
            if idx < app.tree.visible_rows().len() {
                app.tree.set_cursor(idx);
                // Arm a drag — the source is captured here; the
                // actual move happens on mouse-up over a different
                // directory row.
                if let Some(row) = app.tree.selected_row() {
                    app.begin_tree_drag(row.path.clone(), row.is_dir, y);
                }
                if let Some(row) = app.tree.selected_row()
                    && row.is_dir
                {
                    // Multi-repo workspace: clicking a depth-0
                    // repo dir also switches the active repo
                    // (so the git rail / branches / PRs follow
                    // the user's focus). The dir then expands /
                    // collapses normally.
                    if row.depth == 0 && app.repos.len() > 1 {
                        let repo_hit = app.repos.iter().position(|r| r.path == row.path);
                        if let Some(idx) = repo_hit
                            && idx != app.active_repo
                        {
                            app.switch_active_repo(idx);
                        }
                    }
                    app.tree.toggle_current();
                }
                // Files: the open is DEFERRED to mouse-up. On a
                // plain click the Up handler opens it (preview, or
                // a permanent tab on double-click); if the user
                // instead click-holds and drags, it becomes a
                // drag (onto a pane body → drag-to-split; onto a
                // tree dir → move-in-tree) and never opens here.
                // Opening on Down made a drag impossible — the
                // file flashed open the instant you pressed.
            }
        }
        return;
    }
    // A GIT-section row — focus the rail's git section + run the row's
    // default action (checkout the branch / open shell in the worktree).
    if let Some(&(_, hit)) = app
        .rects
        .git_rail_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.click_git_rail(hit);
        return;
    }
    // Empty-state `+ dock` chip → fire dock.new_text.
    if let Some(r) = app.rects.dock_empty_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::command::run("dock.new_text", app);
        return;
    }
    // Open kebab-menu row click → apply choice + close.
    // Checked FIRST so a click on a menu row wins over
    // anything underneath (the menu is an overlay).
    if app.dock_kebab_menu.is_some()
        && let Some(&(_, idx)) = app
            .rects
            .dock_kebab_rows
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(menu) = app.dock_kebab_menu.as_ref()
            && let Some(item) = menu.items.get(idx).copied()
        {
            let wid = menu.widget_id;
            crate::dock::apply_kebab_choice(app, wid, item);
        }
        return;
    }
    // Click ANYWHERE else with the kebab menu open → close it.
    if app.dock_kebab_menu.is_some() {
        app.dock_kebab_menu = None;
        // Fall through — let the click hit whatever it
        // was meant for.
    }
    // Dock widget kebab `⋮` click → open the menu.
    // Checked BEFORE the title-bar / body so the kebab
    // wins.
    if let Some(&(r, id)) = app
        .rects
        .dock_widget_kebabs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(w) = app.dock_widgets.iter().find(|w| w.id == id) {
            app.dock_kebab_menu = Some(crate::dock::KebabMenuState::build(w, r.x, r.y));
        }
        return;
    }
    // Dock widget title bar mouse-down → arm a drag. Final
    // corner resolves on mouse-up based on which quadrant
    // of the editor body the cursor ended up in.
    if let Some(&(_, id)) = app
        .rects
        .dock_widget_titles
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.dock_drag_id = Some(id);
        app.dock_drag_cursor = Some((x, y));
        return;
    }
    // Dock widget body click → toast (placeholder; content-
    // specific actions can hook in later).
    if let Some(&(_, id)) = app
        .rects
        .dock_widget_bodies
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(w) = app.dock_widgets.iter().find(|w| w.id == id) {
            let title = w.title.clone();
            app.toast(format!("dock: {title}"));
        }
        return;
    }
    // Workspaces editor kebab `⋮` click → open per-row menu.
    if app.workspaces_editor_open
        && let Some(&(_, idx)) = app
            .rects
            .workspaces_editor_kebabs
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.open_workspaces_editor_kebab(idx, (x, y));
        return;
    }
    // Workspaces editor row click → focus + Enter
    // equivalent (rename for normal rows; add for the
    // `+ Add` action).
    if app.workspaces_editor_open
        && let Some(&(_, code)) = app
            .rects
            .workspaces_editor_rows
            .iter()
            .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if code >= 0 {
            let idx = code as usize;
            app.workspaces_editor_selected = idx;
            app.workspaces_editor_open_rename(idx);
        } else {
            crate::command::run("view.add_workspace", app);
        }
        return;
    }
    // Click outside the overlay (when open) closes it.
    if app.workspaces_editor_open && app.context_menu.is_none() {
        // Fall through normally; clicks anywhere outside
        // dismiss like Esc.
        app.close_workspaces_editor();
        return;
    }
    // Workspace-picker chevron → toggle the dropdown.
    if let Some(r) = app.rects.workspace_picker_chevron
        && crate::app::dispatch::contains(r, x, y)
    {
        app.workspace_picker_open = !app.workspace_picker_open;
        if !app.workspace_picker_open {
            app.workspace_picker_filter.clear();
        }
        return;
    }
    // Workspace NAME (not chevron) → open the repo picker
    // when multi-repo. Single-repo: fall through to other
    // tree-row handlers below.
    if let Some(r) = app.rects.workspace_name_rect
        && crate::app::dispatch::contains(r, x, y)
        && app.repos.len() > 1
    {
        app.open_repo_picker();
        return;
    }
    // Workspace-picker row click → switch + close.
    if let Some(&(_, ws_idx)) = app
        .rects
        .workspace_picker_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.switch_workspace(ws_idx);
        app.workspace_picker_open = false;
        app.workspace_picker_filter.clear();
        return;
    }
    // Workspace-picker filter input → focus stays implicit
    // (no separate focus flag; the dropdown owns the
    // keyboard while open). Click anywhere outside the
    // picker closes it.
    if app.workspace_picker_open
        && app
            .rects
            .workspace_picker_filter_input
            .is_none_or(|r| !crate::app::dispatch::contains(r, x, y))
        && app
            .rects
            .workspace_picker_rows
            .iter()
            .all(|(r, _)| !crate::app::dispatch::contains(*r, x, y))
    {
        app.workspace_picker_open = false;
        app.workspace_picker_filter.clear();
        // Fall through — let the click hit whatever's under.
    }
    // Git-palette filter input — click to focus + start typing.
    if let Some(r) = app.rects.git_palette_filter_input
        && crate::app::dispatch::contains(r, x, y)
    {
        app.git_palette_filter_focused = true;
        return;
    }
    // Click anywhere else inside the rail (or outside) while
    // the filter is focused → unfocus (keeps the typed text
    // so navigating doesn't lose what they typed).
    if app.git_palette_filter_focused {
        app.git_palette_filter_focused = false;
    }
    // Sessions panel `+ New session` chip → spawn a Claude
    // Code pane (the most common case). Checked BEFORE
    // tab clicks so a click on the chip wins.
    if let Some(r) = app.rects.session_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::command::run("ai.claude_code", app);
        return;
    }
    // Agents rail panel — filter input, + New, and row
    // clicks.
    if let Some(r) = app.rects.agents_panel_filter_input
        && crate::app::dispatch::contains(r, x, y)
    {
        app.agents_panel_filter_focused = true;
        return;
    }
    if let Some(r) = app.rects.agents_panel_new_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        crate::command::run("ai.claude_code", app);
        return;
    }
    if let Some(r) = app.rects.agents_panel_pr_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_new_cloud_agent_wizard();
        return;
    }
    // View-mode toggle chip → switch between by-status
    // and by-workspace grouping.
    if let Some(r) = app.rects.agents_panel_view_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.agents_panel_group_by_workspace = !app.agents_panel_group_by_workspace;
        app.agents_panel_expanded_workspaces.clear();
        return;
    }
    // Workspace header (by-workspace view only) → toggle
    // expansion for that workspace.
    if let Some((_, ws)) = app
        .rects
        .agents_panel_workspace_headers
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .cloned()
    {
        if app.agents_panel_expanded_workspaces.contains(&ws) {
            app.agents_panel_expanded_workspaces.remove(&ws);
        } else {
            app.agents_panel_expanded_workspaces.insert(ws);
        }
        return;
    }
    if let Some(&(_, row_idx)) = app
        .rects
        .agents_panel_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        if let Some(row) = app.agents_panel_rows.get(row_idx).cloned() {
            match row.source {
                crate::claude_agents::AgentSource::TattleQwe => {
                    // Cloud rows can't be resumed locally —
                    // copy the runId so the user can paste
                    // it into Slack / a browser, and toast
                    // what we know about the run.
                    app.clipboard.set(row.session_id.clone(), false);
                    let summary = row
                        .last_assistant_msg
                        .clone()
                        .unwrap_or_else(|| "(cloud run)".to_string());
                    app.toast(format!("{} · {} · runId copied", row.workspace, summary));
                }
                _ => {
                    // Resume in a fresh pty — mirrors the
                    // dashboard's `R` chord.
                    app.resume_claude_session_in_pty(&row.session_id);
                }
            }
        }
        return;
    }
    // Cloud Agents panel — filter input + row clicks +
    // density chip (compact ↔ standard) + + New Cloud
    // Agent button.
    if let Some(r) = app.rects.cloud_agents_view_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.cloud_agents_toggle_view();
        return;
    }
    if let Some(r) = app.rects.cloud_agents_new_run_button
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_new_cloud_run_wizard();
        return;
    }
    if let Some(r) = app.rects.cloud_agents_change_defaults_chip
        && crate::app::dispatch::contains(r, x, y)
    {
        app.open_new_cloud_run_wizard();
        return;
    }
    if let Some(r) = app.rects.cloud_agents_quick_input
        && crate::app::dispatch::contains(r, x, y)
    {
        app.cloud_run_prompt_focused = true;
        app.cloud_agents_filter_focused = false;
        return;
    }
    if let Some(r) = app.rects.cloud_agents_filter_input
        && crate::app::dispatch::contains(r, x, y)
    {
        app.cloud_agents_filter_focused = true;
        return;
    }
    if let Some(&(_, row_idx)) = app
        .rects
        .cloud_agents_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // 2026-06-27 — single-click on a cloud-agent row now
        // opens the full detail pane (summary, links,
        // artifacts, logs) instead of just copying the runId.
        // The runId is still accessible via the right-click
        // menu / palette.
        app.open_cloud_agent_run(row_idx);
        return;
    }
    // Click anywhere else inside the rail while either
    // agents filter is focused → unfocus.
    if app.agents_panel_filter_focused {
        app.agents_panel_filter_focused = false;
    }
    if app.cloud_agents_filter_focused {
        app.cloud_agents_filter_focused = false;
    }
    // Sessions panel tab (vertical-tab strip shown when
    // `ActivitySection::Sessions` is active). Click →
    // focus that Pty pane. Also arms a drag — mouse-up
    // over another tab swaps them.
    if let Some(&(_, pid)) = app
        .rects
        .session_tabs
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        app.session_drag_pid = Some(pid);
        return;
    }
    // Git-palette row (the GitKraken-style panel shown when
    // `ActivitySection::Git` is active). Maps to the same
    // `GitRailHit` dispatch as the legacy rail.
    if let Some(&(_, hit)) = app
        .rects
        .git_palette_rows
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // GitKraken-style: left-click on a ref (branch /
        // remote / worktree / tag / stash) HIGHLIGHTS the
        // ref's commit in the open git-graph pane. The
        // action (checkout / cd / pop / etc.) lives on
        // the right-click context menu. PRs still open in
        // the browser since they're not graph commits.
        // qa-feature 2026-06-30 — stamp the clicked row's
        // identifier so git_palette::draw can paint the
        // highlight bg on its render call. Click feedback was
        // missing — clicking a branch jumped the graph but the
        // sidebar row looked unselected.
        match &hit {
            crate::ui::git_palette::GitPaletteHit::Branch(i) => {
                if let Some(b) = app.git_rail.branches.get(*i) {
                    app.git_palette_selected = Some(b.name.clone());
                }
            }
            crate::ui::git_palette::GitPaletteHit::Worktree(i) => {
                if let Some(wt) = app.git_rail.worktrees.get(*i) {
                    app.git_palette_selected = Some(wt.label.clone());
                }
            }
            crate::ui::git_palette::GitPaletteHit::RemoteBranch(i) => {
                if let Some(name) = app.git_rail.remote_branches.get(*i).cloned() {
                    app.git_palette_selected = Some(name);
                }
            }
            crate::ui::git_palette::GitPaletteHit::Stash(i) => {
                if let Some(st) = app.git_rail.stashes.get(*i) {
                    app.git_palette_selected = Some(st.id.clone());
                }
            }
            crate::ui::git_palette::GitPaletteHit::Tag(i) => {
                if let Some(name) = app.git_rail.tags.get(*i).cloned() {
                    app.git_palette_selected = Some(name);
                }
            }
            crate::ui::git_palette::GitPaletteHit::Pull(_) => {
                // PRs open in browser; no in-sidebar selection
                // semantics.
            }
        }
        match hit {
            crate::ui::git_palette::GitPaletteHit::Branch(i) => {
                if let Some(b) = app.git_rail.branches.get(i) {
                    let name = b.name.clone();
                    app.git_jump_to_ref(&name);
                }
            }
            crate::ui::git_palette::GitPaletteHit::Worktree(i) => {
                if let Some(wt) = app.git_rail.worktrees.get(i) {
                    let label = wt.label.clone();
                    app.git_jump_to_ref(&label);
                }
            }
            crate::ui::git_palette::GitPaletteHit::Pull(i) => {
                // PRs aren't commits — open in browser
                // (same as the legacy rail).
                app.click_git_rail(crate::git::rail::GitRailHit::Pull(i));
            }
            crate::ui::git_palette::GitPaletteHit::RemoteBranch(i) => {
                if let Some(name) = app.git_rail.remote_branches.get(i).cloned() {
                    app.git_jump_to_ref(&name);
                }
            }
            crate::ui::git_palette::GitPaletteHit::Stash(i) => {
                if let Some(st) = app.git_rail.stashes.get(i) {
                    let id = st.id.clone();
                    app.git_jump_to_ref(&id);
                }
            }
            crate::ui::git_palette::GitPaletteHit::Tag(i) => {
                if let Some(name) = app.git_rail.tags.get(i).cloned() {
                    app.git_jump_to_ref(&name);
                }
            }
        }
        return;
    }
    // Claude Agents — Files drill-down file row click → open
    // the file in an editor pane.
    if let Some(path) = app
        .rects
        .claude_drill_files
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
        .map(|(_, p)| p.clone())
    {
        let pb = std::path::PathBuf::from(&path);
        app.open_path(&pb);
        return;
    }
    // SCM/CI pane row click? Match before the generic editor-pane
    // handler since these panes also register editor-pane rects.
    // Single click: focus + select that row. If it's a header,
    // toggle collapse (sibling to Enter). Double-click on a data
    // row: open in browser.
    if let Some(&(_, pid, flat_idx)) = app
        .rects
        .list_rows
        .iter()
        .find(|(r, _, _)| crate::app::dispatch::contains(*r, x, y))
    {
        app.active = Some(pid);
        app.focus_pane();
        let now = std::time::Instant::now();
        let count = match app.last_click {
            Some((prev, px, py, c))
                if px == x
                    && py == y
                    && now.duration_since(prev) < std::time::Duration::from_millis(450) =>
            {
                (c + 1).min(3)
            }
            _ => 1,
        };
        app.last_click = Some((now, x, y, count));
        // Click on a list row blurs the WIP commit textarea
        // (the user is moving focus to the commits / status
        // list, not the editor box).
        app.blur_active_wip_commit_textarea();
        crate::app::dispatch::handle_scm_row_click(app, pid, flat_idx, count >= 2);
        return;
    }

    // Editor text in some split leaf? Focus that leaf and place the cursor.
    // Track multi-click: 2 = select word, 3 = select line. The threshold
    // (450 ms, same cell) matches what most OSes use.
    if let Some(&(tr, pid)) = app
        .rects
        .editor_panes
        .iter()
        .find(|(r, _)| crate::app::dispatch::contains(*r, x, y))
    {
        // Alt+click → add an extra cursor at the clicked position
        // (VS Code convention). Skips the focus / drag-arm path so
        // the existing primary stays put.
        if m.modifiers.contains(KeyModifiers::ALT) {
            let wrap = app.config.ui.wrap;
            if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
                let byte = b.editor.byte_at_col_pub(row, col);
                b.editor.add_extra_cursor(byte);
            }
            return;
        }
        app.active = Some(pid);
        app.focus_pane();
        let now = std::time::Instant::now();
        let count = match app.last_click {
            Some((prev, px, py, c))
                if px == x
                    && py == y
                    && now.duration_since(prev) < std::time::Duration::from_millis(450) =>
            {
                (c + 1).min(3)
            }
            _ => 1,
        };
        app.last_click = Some((now, x, y, count));
        // Ctrl+click → place cursor + fire `lsp.goto_definition`
        // (VS Code convention — "click through" identifiers).
        let ctrl_click = m.modifiers.contains(KeyModifiers::CONTROL);
        let wrap = app.config.ui.wrap;
        if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
            let (row, col) = crate::app::dispatch::click_to_file_pos(b, tr, wrap, x, y);
            b.editor.place_cursor(row, col);
            if count >= 2 {
                let clip = &mut app.clipboard;
                if let Some(Pane::Editor(b)) = app.panes.get_mut(pid) {
                    let op = if count == 2 {
                        crate::edit_op::EditOp::SelectWord
                    } else {
                        crate::edit_op::EditOp::SelectLine
                    };
                    b.apply_edit_ops(vec![op], clip, 0);
                }
            } else {
                // Arm a potential drag-select. If the user actually
                // drags, the first Drag event will SelectStart at
                // the origin and move the cursor.
                app.drag_select = Some((pid, row, col, false));
            }
        }
        if ctrl_click {
            // Ctrl+Shift+Click → references picker; plain Ctrl+Click
            // → go-to-definition. Matches VS Code's "peek references"
            // / "go to definition" gestures.
            if m.modifiers.contains(KeyModifiers::SHIFT) {
                app.lsp_references();
            } else {
                app.lsp_goto_definition();
            }
        }
    }
}
