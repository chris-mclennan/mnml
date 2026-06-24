//! The render path — backend-agnostic, so the same `draw` serves the real
//! terminal (`tui.rs`) and the headless virtual screen (`headless.rs`). Layout
//! mirrors NvChad: the file-tree rail is a full-height column on the left (the
//! buffer tabs do NOT sit above it); the right column is a one-line bufferline
//! over the pane body; the statusline spans the full width at the bottom.
//!
//! ```text
//! ┌──────────┬────────────────────────────────────┐
//! │  tree    │ bufferline (open buffers)        h1 │
//! │  rail    ├────────────────────────────────────┤
//! │ (full    │ active pane body                   │
//! │  height) │ (editor view / welcome)            │
//! ├──────────┴────────────────────────────────────┤
//! │ statusline (mode · git · file … Ln:Col · lang) │
//! └───────────────────────────────────────────────┘
//! ```
//!
//! "active pane body" is actually a recursive split tree (`render_layout`) — one
//! editor per `Layout::Leaf`, 1-cell dividers between splits. Overlays (picker /
//! palette / which-key / popups) draw on top.

pub mod about_overlay;
pub mod activity_bar;
pub mod ai_view;
pub mod spend_report_view;

/// 2026-06-21 vscode-mouse SEV-2 — which Claude Agents dashboard
/// topbar chip a click is on. The mouse dispatcher matches this
/// to the corresponding pane-level action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TopbarChipKind {
    View,
    Sort,
    Group,
    Source,
    Workspace,
}
// Azure DevOps views moved to mnml-forge-azdevops.
pub mod browser_view;
pub mod bufferline;
pub mod cheatsheet_view;
pub mod claude_agents_view;
pub mod peek_overlay_view;
pub mod ws_view;
pub mod close_prompt;
pub mod cmdline_bar;
pub mod cmdline_popup_view;
pub mod cmdline_history_view;
// codebuilds_view moved to mnml-aws-codebuild.
pub mod completion;
pub mod context_menu;
pub mod dap_repl_view;
pub mod debug_rects;
pub mod debug_view;
pub mod diagnostics_view;
pub mod diff_view;
pub mod discovery;
pub mod editor_view;
pub mod fim_progress_overlay;
pub mod flaky_view;
pub mod flash_overlay;
pub mod ghost_overlay;
pub mod git_graph_view;
pub mod git_status_view;
// GitHub views moved to mnml-forge-github.
// GitLab views moved to mnml-forge-gitlab.
pub mod grep_view;
pub mod help_overlay;
pub mod hover;
pub mod icons;
pub mod image_view;
pub mod integration_edit_overlay;
// log_tail_view moved to mnml-aws-codebuild.
pub mod md_inline_overlay;
pub mod md_preview;
pub mod outline_view;
pub mod picker;
// pipeline_log_view removed after 2026-06 SCM split.
pub mod discovery_overlay;
pub mod prompt;
pub mod pty_view;
pub mod rename_preview_overlay;
pub mod request_view;
pub mod git_palette;
pub mod menu_bar;
pub mod workspace_picker;
pub mod scratch_term_view;
pub mod scrollbar;
pub mod settings_overlay;
pub mod signature;
pub mod startup_picker;
pub mod statusline;
pub mod tests_view;
pub mod theme;
pub mod toast_stack;
pub mod tooltip;
// `trace_view` moved to mnml-test-playwright in 2026-06.
pub mod tree_view;
pub mod welcome;
pub mod welcome_overlay;
pub mod whichkey;
pub mod yank_flash_overlay;

use ratatui::Frame;
use ratatui::layout::{Constraint, Layout as RLayout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Paragraph};

use crate::app::App;
use crate::focus::Focus;
use crate::layout::{Layout, SplitDir, split_rects};

pub fn draw(frame: &mut Frame, app: &mut App) {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().bg(theme::cur().bg_dark)),
        area,
    );

    // Zen mode: skip the tree, bufferline, and statusline — the editor takes
    // the full window. Returning early keeps the toggle a flat opt-out from
    // the rest of the layout pipeline.
    if app.zen_mode {
        app.rects.tree = None;
        app.rects.tree_toggle = None;
        app.rects.bufferline = None;
        app.rects.bufferline_tabs.clear();
        app.rects.bufferline_tab_close.clear();
        app.rects.bufferline_overflow_left = None;
        app.rects.bufferline_overflow_right = None;
        app.rects.bufferline_new_tab_button = None;
        app.rects.bufferline_tab_page_chips.clear();
        app.rects.bufferline_tab_page_close.clear();
        app.rects.bufferline_theme_toggle = None;
        app.rects.bufferline_window_close = None;
        app.rects.statusline = None;
        app.rects.body = Some(area);
        app.rects.editor_panes.clear();
        app.rects.pane_bodies.clear();
        app.rects.editor_gutters.clear();
        app.rects.fold_chips.clear();
        app.rects.code_lens_chips.clear();
        app.rects.wip_buttons.clear();
        app.rects.wip_file_rows.clear();
        app.rects.wip_commit_textarea = None;
        app.rects.git_toolbar_buttons.clear();
        app.rects.commit_file_rows.clear();
        app.rects.diff_toolbar_buttons.clear();
        app.rects.diff_hunk_buttons.clear();
        app.rects.scrollbars.clear();
        app.rects.git_graph_detail_dividers.clear();
        app.rects.git_graph_column_headers.clear();
        app.rects.request_tabs.clear();
        app.rects.request_fields.clear();
        app.rects.completion_rows.clear();
        app.rects.list_rows.clear();
        app.rects.cheatsheet_headers.clear();
        app.rects.ws_send_buttons.clear();
        app.rects.claude_agents_topbar_chips.clear();
        app.rects.spend_headers.clear();
        app.rects.claude_drill_files.clear();
        app.rects.split_dividers.clear();
        app.rects.split_strip_buttons.clear();
        app.rects.split_strip_term_buttons.clear();
        app.rects.pty_tabs.clear();
        app.rects.pty_tab_new.clear();
        app.rects.pty_tab_close.clear();
        let layout = app.layout().clone();
        let cursor_pos: Option<(u16, u16)> = if matches!(layout, Layout::Empty) {
            welcome::draw(frame, app, area);
            None
        } else {
            let mut path = Vec::new();
            render_layout(frame, app, &layout, area, &mut path)
        };
        // Overlays still work in zen — picker, prompt, which-key, popups.
        if app.picker.is_some() {
            picker::draw(frame, app, area);
        }
        if app.whichkey.is_some() {
            whichkey::draw(frame, app, area);
        }
        if app.prompt.is_some() {
            prompt::draw(frame, app, area);
        }
        if app.hover.is_some() {
            hover::draw(frame, app, area, cursor_pos);
        }
        if app.signature.is_some() {
            signature::draw(frame, app, area, cursor_pos);
        }
        if app.completion.is_some() {
            completion::draw(frame, app, area, cursor_pos);
        }
        if let Some((x, y)) = app.rects.prompt_caret.or(app.rects.picker_caret) {
            frame.set_cursor_position((x, y));
        } else if app.focus == Focus::Pane
            && let Some((x, y)) = cursor_pos
        {
            frame.set_cursor_position((x, y));
        }
        return;
    }

    // Clear the split-strip button rects at the top of every
    // non-zen frame so two populating call sites (`bufferline::draw`
    // for single-leaf, `paint_leaf_tab_strip` for multi-leaf) can
    // BOTH push their entries this frame without one wiping the
    // other's contribution.
    app.rects.split_strip_buttons.clear();
    app.rects.split_strip_term_buttons.clear();
    app.rects.split_strip_ai_buttons.clear();

    // Split off the bottom statusline + cmdline bar (each 1 row, full width).
    // Cmdline bar sits BELOW the statusline (vim/neovim convention: the
    // statusline shows steady state, the cmdline below it shows the live `:`
    // line + transient echo messages). The top row is a 1-row palette bar
    // (VS Code-style centered "search files, run commands…" chip) — visible
    // when the window is wide enough.
    let palette_bar_visible = area.width >= 80;
    let palette_bar_h: u16 = if palette_bar_visible { 1 } else { 0 };
    let v = RLayout::vertical([
        Constraint::Length(palette_bar_h),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .split(area);
    let (palette_bar_area, upper, statusline_area, cmdline_bar_area) = (v[0], v[1], v[2], v[3]);

    if palette_bar_visible {
        draw_palette_bar(frame, app, palette_bar_area);
    } else {
        app.rects.palette_search_chip = None;
    }

    // tree rail | right column. `tree_visible` here means "the rail itself is
    // showing" (toggled by `Ctrl+B`); a separate `tree_root_expanded` flag,
    // read by `tree_view::draw`, controls whether the file list under the
    // workspace-name header is shown (the VS-Code-style section collapse).
    let (tree_area, right) = if app.tree_visible {
        let w = app.tree_width.min(upper.width.saturating_sub(20)).max(8);
        let cols = RLayout::horizontal([Constraint::Length(w), Constraint::Min(1)]).split(upper);
        // The rail's resize handle is only the visible grip area —
        // a 3-cell-wide × 4-row-tall band centered vertically on the
        // rail. Wider hit zone (3 cols vs the 1-col visible grip)
        // for trackpad findability per vscode-mouse-2026-06-10
        // SEV-3 #6; taller hit area (4 rows vs the 2-row visible
        // grip) gives an extra row of margin on each side. Restricts
        // to the grip's y-range so clicking anywhere ELSE on the
        // separator strip (e.g. on a right-aligned chip) doesn't
        // initiate a drag. 2026-06-19 user-requested.
        let resize_x = cols[0].x + cols[0].width.saturating_sub(1);
        let grip_visible_h: u16 = 2;
        let grip_hit_h: u16 = (grip_visible_h + 2).min(cols[0].height);
        let grip_visible_y = cols[0].y + cols[0].height.saturating_sub(grip_visible_h) / 2;
        let grip_hit_y = grip_visible_y.saturating_sub(1).max(cols[0].y);
        app.rects.tree_edge = Some(Rect {
            x: resize_x.saturating_sub(1),
            y: grip_hit_y,
            width: 3,
            height: grip_hit_h,
        });
        (Some(cols[0]), cols[1])
    } else {
        app.rects.tree_edge = None;
        (None, upper)
    };

    // right column: optionally a 1-row bufferline above the body.
    // `app.bufferline_visible = false` ⇒ skip the strip; the body grows.
    // 2026-06-22 — also skip when the current layout has any
    // splits. Each split paints its own per-leaf tab strip above
    // its body, and the global bufferline would duplicate that
    // info (user feedback: "tabs on the left + subheading with
    // the name = goofy"). The per-leaf strips are the source of
    // truth when splits exist; only a single-leaf layout falls
    // back to the global bufferline.
    let has_splits = app
        .layouts
        .get(app.active_layout)
        .map(|l| l.has_splits())
        .unwrap_or(false);
    let (bufferline_area, body_area) = if app.bufferline_visible && !has_splits {
        let r = RLayout::vertical([Constraint::Length(1), Constraint::Min(1)]).split(right);
        (Some(r[0]), r[1])
    } else {
        (None, right)
    };

    // ── tree rail (full height of `upper`) ──
    // The rail is split into two columns: a 4-cell activity-bar
    // strip on the far left + the larger content pane that hosts
    // whichever ActivitySection is active. tree_view continues to
    // render the Explorer mode; other modes paint a stub.
    if let Some(ta) = tree_area {
        let bar_w = crate::ui::activity_bar::ACTIVITY_BAR_WIDTH.min(ta.width);
        let bar_area = Rect {
            x: ta.x,
            y: ta.y,
            width: bar_w,
            height: ta.height,
        };
        let content_area = Rect {
            x: ta.x + bar_w,
            y: ta.y,
            width: ta.width.saturating_sub(bar_w),
            height: ta.height,
        };
        crate::ui::activity_bar::draw(frame, app, bar_area);
        match app.active_section {
            crate::app::ActivitySection::Explorer => {
                tree_view::draw(frame, app, content_area);
            }
            crate::app::ActivitySection::Integrations => {
                draw_integrations_section(frame, app, content_area);
            }
            crate::app::ActivitySection::Search => {
                draw_search_section(frame, app, content_area);
            }
            crate::app::ActivitySection::Debug => {
                draw_debug_section(frame, app, content_area);
            }
            crate::app::ActivitySection::Git => {
                git_palette::draw(frame, app, content_area);
            }
        }
        // For non-Explorer sections the tree_view click rects aren't
        // populated; ensure they're at least cleared so a stale click
        // from a prior frame doesn't fire.
        if app.active_section != crate::app::ActivitySection::Explorer {
            app.rects.tree = None;
            app.rects.tree_toggle = None;
            app.rects.tree_icon_buttons.clear();
        }
        // Tiny drag-handle indicator — a 3-row vertical grip centered on
        // the rail's right edge (not a full-height border). Telegraphs
        // "you can drag this column to resize" without painting a visible
        // separator line down the whole rail.
        if let Some(edge) = app.rects.tree_edge
            && edge.height >= 3
        {
            let t = theme::cur();
            let glyph = if app.config.ui.ascii_icons {
                "|"
            } else {
                "┃"
            };
            let grip_h: u16 = 2;
            let grip_y = edge.y + edge.height.saturating_sub(grip_h) / 2;
            let grip_rect = Rect {
                x: edge.x,
                y: grip_y,
                width: 1,
                height: grip_h,
            };
            let line = std::iter::repeat_n(glyph, grip_h as usize)
                .collect::<Vec<_>>()
                .join("\n");
            frame.render_widget(
                ratatui::widgets::Paragraph::new(line)
                    .style(Style::default().fg(t.comment).bg(t.bg_darker)),
                grip_rect,
            );
        }
    } else {
        app.rects.tree = None;
        app.rects.tree_toggle = None;
        app.rects.git_section_toggle = None;
        app.rects.git_rail_rows.clear();
    }

    // ── bufferline ──
    if let Some(ba) = bufferline_area {
        bufferline::draw(frame, app, ba);
        app.rects.bufferline = Some(ba);
    } else {
        app.rects.bufferline = None;
        app.rects.bufferline_tabs.clear();
        app.rects.bufferline_tab_close.clear();
        app.rects.bufferline_overflow_left = None;
        app.rects.bufferline_overflow_right = None;
        app.rects.bufferline_new_tab_button = None;
        app.rects.bufferline_tab_page_chips.clear();
        app.rects.bufferline_tab_page_close.clear();
        app.rects.bufferline_theme_toggle = None;
        app.rects.bufferline_window_close = None;
    }

    // ── the split-tree of pane bodies ──
    // If the scratch terminal is open, reserve its strip at the bottom
    // before laying out the split tree so panes don't overlap it.
    let mut body_area = body_area;
    let mut scratch_strip: Option<Rect> = None;
    if app.scratch_term.is_some() {
        let want_h = crate::app::SCRATCH_TERM_ROWS;
        if body_area.height > want_h + 2 {
            let strip_h = want_h;
            scratch_strip = Some(Rect {
                x: body_area.x,
                y: body_area.y + body_area.height - strip_h,
                width: body_area.width,
                height: strip_h,
            });
            body_area.height -= strip_h;
        }
    }
    app.rects.scratch_term_strip = scratch_strip;
    // The native mixr panel — an overlay docked at the bottom-left of
    // the body (from the file-tree edge across). `BottomStrip` is a
    // short strip; `Full` is full body height. Width is capped at
    // `MAX_WIDTH` so a very wide screen doesn't blow it out.
    // `Minimized` = hidden (just the ♪ chip).
    app.rects.body = Some(body_area);
    app.rects.editor_panes.clear();
    app.rects.pane_bodies.clear();
    app.rects.editor_gutters.clear();
    app.rects.fold_chips.clear();
    app.rects.code_lens_chips.clear();
    app.rects.wip_buttons.clear();
    app.rects.wip_file_rows.clear();
    app.rects.wip_commit_textarea = None;
    app.rects.git_toolbar_buttons.clear();
    app.rects.commit_file_rows.clear();
    app.rects.diff_toolbar_buttons.clear();
    app.rects.diff_hunk_buttons.clear();
    app.rects.scrollbars.clear();
    app.rects.git_graph_detail_dividers.clear();
    app.rects.git_graph_column_headers.clear();
    app.rects.request_tabs.clear();
    app.rects.request_fields.clear();
    app.rects.completion_rows.clear();
    app.rects.list_rows.clear();
    app.rects.claude_drill_files.clear();
    app.rects.split_dividers.clear();
    app.rects.pty_tabs.clear();
    app.rects.pty_tab_new.clear();
    app.rects.pty_tab_close.clear();
    let layout = app.layout().clone();
    // 2026-06-22 — clear per-split tab chip rects before the
    // recursive walk re-populates them. Without this, frames
    // would accumulate stale chip rects from prior layouts and
    // clicks would target deleted leaves.
    app.rects.split_tab_chips.clear();
    app.rects.split_tab_close.clear();
    // Note: `split_strip_buttons` / `split_strip_term_buttons` are
    // NOT cleared here — they were cleared earlier in ui::draw,
    // before `bufferline::draw` populated them for the single-leaf
    // case. Clearing here would wipe the bufferline's rects before
    // mouse dispatch reads them. The per-leaf strip in
    // `paint_leaf_tab_strip` pushes additional entries on top for
    // the multi-leaf case.
    let cursor_pos: Option<(u16, u16)> = if matches!(layout, Layout::Empty) {
        welcome::draw(frame, app, body_area);
        None
    } else {
        let mut path = Vec::new();
        render_layout(frame, app, &layout, body_area, &mut path)
    };

    // Drag-to-split: while a bufferline tab is dragged over a pane body, paint
    // a hint showing where the pane will land.
    draw_tab_drop_hint(frame, app);
    // 2026-06-22 — drag ghost (paints near the cursor while a
    // file drag is in flight). Comes AFTER the drop-zone hint so
    // the ghost reads on top of the highlighted zone.
    draw_tree_drag_ghost(frame, app);

    // Scratch terminal strip — paints below the body. Resizes the pty
    // so the shell knows about the new viewport.
    if let Some(strip) = scratch_strip
        && app.scratch_term.is_some()
    {
        scratch_term_view::draw(frame, app, strip);
    }

    // Inline-rendered markdown overlay: paints heading-line bold + colored,
    // `**bold**` / `*italic*` / `` `code` `` / `[label](url)` decorations
    // IN the editor pane for markdown buffers. Off by default.
    if app.config.ui.render_markdown {
        md_inline_overlay::draw(frame, app);
    }
    // Yank flash overlay: tints the yanked byte range yellow for ~200ms
    // (vim.highlight.on_yank() equivalent).
    yank_flash_overlay::draw(frame, app);
    // AI ghost-text: paint the active editor's pending suggestion in
    // grey starting at the cursor cell.
    ghost_overlay::draw(frame, app, cursor_pos);
    // Local-model download progress — bottom-centered bar during the
    // one-time fim-engine model pull.
    fim_progress_overlay::draw(frame, app, area);
    // Stacked toasts: top-right vertical column when more than one toast
    // is live (rapid-fire toasts no longer clobber each other).
    toast_stack::draw(frame, app);
    // Flash overlay: paints label glyphs over the editor body when a
    // `s<a><b>` jump is armed.
    if app.flash_state.is_some() {
        flash_overlay::draw(frame, app);
    }
    // Inline rename preview: while an `lsp.rename` prompt is open, paint
    // the new identifier at every whole-word occurrence in the active editor.
    if app.rename_preview_state.is_some() {
        rename_preview_overlay::draw(frame, app);
    }

    // ── statusline ──
    statusline::draw(frame, app, statusline_area);
    app.rects.statusline = Some(statusline_area);

    // ── cmdline bar (below statusline) ──
    cmdline_bar::draw(frame, app, cmdline_bar_area);

    // ── cmdline completion popup (floats UP from the cmdline bar
    //     over the editor pane content while a `:` cmdline is open
    //     and has ≥2 matches). 2026-06-19 — discoverability gold:
    //     auto-shows on type so users don't have to know Tab cycles.
    cmdline_popup_view::draw(frame, app, cmdline_bar_area);

    // ── overlays (picker / palette, then which-key) ──
    if app.picker.is_some() {
        picker::draw(frame, app, area);
    } else {
        app.rects.picker_box = None;
        app.rects.picker_items.clear();
        app.rects.picker_caret = None;
    }
    if app.whichkey.is_some() {
        whichkey::draw(frame, app, area);
    } else if app.vim_operator_menu().is_some() {
        // 2026-06-21 — vim-operator whichkey popup. Only paints
        // when leader-whichkey isn't already showing (leader
        // takes priority on the unlikely overlap).
        whichkey::draw_vim_operators(frame, app, area);
    }
    if app.close_prompt.is_some() {
        close_prompt::draw(frame, app, area);
    } else {
        app.rects.close_prompt_buttons.clear();
    }
    if app.prompt.is_some() {
        prompt::draw(frame, app, area);
    } else {
        app.rects.prompt_caret = None;
    }
    if app.context_menu.is_some() {
        context_menu::draw(frame, app, area);
    } else {
        app.rects.context_menu_box = None;
        app.rects.context_menu_items.clear();
    }
    if app.hover.is_some() {
        hover::draw(frame, app, area, cursor_pos);
    }
    if app.signature.is_some() {
        signature::draw(frame, app, area, cursor_pos);
    }
    if app.completion.is_some() {
        completion::draw(frame, app, area, cursor_pos);
    }
    if app.peek_overlay.is_some() {
        peek_overlay_view::draw(frame, app, area);
    }
    // Hover tooltip — sits above everything else (chip popups can't conflict
    // with picker/prompt/etc. because the hover_chip is only set when the
    // mouse moves freely outside any modal).
    if app.hover_chip.is_some() {
        tooltip::draw(frame, app, area);
    }
    // F1 discovery overlay — sits on top of everything else.
    discovery::draw(frame, app, area);
    // Welcome overlay — peer of discovery; auto-open on first launch.
    welcome_overlay::draw(frame, app, area);
    // About overlay — `:about` / view.about.
    about_overlay::draw(frame, app, area);
    // Settings overlay — `:settings` / view.settings.
    settings_overlay::draw(frame, app, area);
    // "+ Add integration" overlay — `:integrations.add` or clicking
    // the + chip on the sidebar's INTEGRATIONS header.
    discovery_overlay::draw(frame, app, area);
    // Integration edit panel — layered on TOP of the discovery
    // overlay when the user presses `e` on a rail row or selects the
    // `[+ Add custom integration]` row. No-op when no edit is in
    // flight; the renderer reads `discovery_overlay.edit_panel`.
    integration_edit_overlay::draw(frame, app, area);
    // Help overlay — `?` / view.help (auto-generated keymap reference).
    help_overlay::draw(frame, app, area);
    // Startup picker — drawn last among modal overlays so it sits on
    // top of welcome/about/etc. when launched from the .app.
    startup_picker::draw(frame, app, area);
    // Menu-bar dropdown — paints on top of everything else so it
    // overlays the editor body / overlays when open. Mouse-up
    // outside the dropdown closes it (see tui.rs dispatch).
    menu_bar::draw_dropdown(frame, app);
    // Workspace-picker dropdown — same overlay treatment, anchored
    // below the workspace header chevron.
    workspace_picker::draw(frame, app);
    // …and the flash highlight paints last so it can sit on top of even
    // the discovery panel (if the user picks a category whose rect lies
    // beneath the panel, the highlight will still flash through).
    discovery::draw_flash(frame, app, area);

    // `:debug.rects` overlay — paints colored borders around every
    // registered click rect so the user can SEE where clicks are caught.
    // Runs last so the borders sit on top of every other paint layer.
    debug_rects::draw(frame, app);

    // ── terminal cursor ──
    // An overlay's text caret (picker query, prompt input) wins when it's open;
    // otherwise the editor caret when the editor pane has focus and no overlay is
    // up; otherwise nothing.
    if let Some((x, y)) = app.rects.prompt_caret.or(app.rects.picker_caret) {
        frame.set_cursor_position((x, y));
    } else if app.focus == Focus::Pane
        && app.whichkey.is_none()
        && app.close_prompt.is_none()
        && app.prompt.is_none()
        && let Some((x, y)) = cursor_pos
    {
        frame.set_cursor_position((x, y));
    }
}

/// Recursively render a layout subtree into `area`: leaves draw their editor;
/// splits draw a 1-cell divider and recurse. Only the focused leaf returns a
/// cursor cell, so the `.or` chain bubbles it up. `path` accumulates the
/// first(false)/second(true) choices to the current node, recorded with each
/// divider so the mouse can drag-resize a specific split.
fn render_layout(
    frame: &mut Frame,
    app: &mut App,
    layout: &Layout,
    area: Rect,
    path: &mut Vec<bool>,
) -> Option<(u16, u16)> {
    match layout {
        Layout::Empty => None,
        Layout::Leaf { active: id, tabs } => {
            let focused = app.active == Some(*id);
            let tabs_owned = tabs.clone();
            // 2026-06-21 — VS Code-style per-split tab strip. When
            // this leaf is INSIDE a split (path non-empty) AND the
            // pane isn't a Pty (which has its own tab strip in
            // pty_view), carve out the top row of `area` and paint
            // a horizontal row of tab chips (one per pane in the
            // leaf's `tabs`). The body area shrinks by 1 row.
            let is_split_leaf = !path.is_empty();
            let has_own_tab_strip =
                matches!(app.panes.get(*id), Some(crate::pane::Pane::Pty(_)));
            let body_area = if is_split_leaf
                && !has_own_tab_strip
                && area.height >= 2
            {
                let strip = ratatui::layout::Rect {
                    x: area.x,
                    y: area.y,
                    width: area.width,
                    height: 1,
                };
                paint_leaf_tab_strip(frame, app, *id, &tabs_owned, strip, focused);
                ratatui::layout::Rect {
                    x: area.x,
                    y: area.y + 1,
                    width: area.width,
                    height: area.height - 1,
                }
            } else {
                area
            };
            // Record this leaf's body rect (all pane kinds) for tab drag-drop
            // hit-testing (drag-to-split). Uses the post-strip body
            // so drag-to-split zones don't overlap the per-leaf tab.
            app.rects.pane_bodies.push((body_area, *id));
            let area = body_area;
            // Resolve the variant first so the immutable peek doesn't outlive into
            // the `&mut App` draw call.
            let kind: u8 = match app.panes.get(*id) {
                Some(crate::pane::Pane::MdPreview(_)) => 1,
                Some(crate::pane::Pane::Diff(_)) => 2,
                Some(crate::pane::Pane::Request(_)) => 3,
                Some(crate::pane::Pane::Pty(_)) => 4,
                Some(crate::pane::Pane::Ai(_)) => 5,
                Some(crate::pane::Pane::Tests(_)) => 6,
                Some(crate::pane::Pane::GitGraph(_)) => 7,
                Some(crate::pane::Pane::GitStatus(_)) => 8,
                Some(crate::pane::Pane::Diagnostics(_)) => 9,
                Some(crate::pane::Pane::Browser(_)) => 11,
                Some(crate::pane::Pane::Grep(_)) => 12,
                Some(crate::pane::Pane::Flaky(_)) => 13,
                Some(crate::pane::Pane::Outline(_)) => 14,
                Some(crate::pane::Pane::CmdlineHistory(_)) => 15,
                Some(crate::pane::Pane::Quickfix(_)) => 16,
                Some(crate::pane::Pane::Cheatsheet(_)) => 29,
                Some(crate::pane::Pane::Debug(_)) => 30,
                Some(crate::pane::Pane::DapRepl(_)) => 31,
                Some(crate::pane::Pane::Image(_)) => 32,
                Some(crate::pane::Pane::ClaudeAgents(_)) => 34,
                Some(crate::pane::Pane::Websocket(_)) => 35,
                Some(crate::pane::Pane::SpendReport(_)) => 36,
                _ => 0,
            };
            match kind {
                1 => md_preview::draw(frame, app, *id, area, focused),
                2 => diff_view::draw(frame, app, *id, area, focused),
                3 => request_view::draw(frame, app, *id, area, focused),
                4 => pty_view::draw(frame, app, *id, area, focused),
                5 => ai_view::draw(frame, app, *id, area, focused),
                6 => tests_view::draw(frame, app, *id, area, focused),
                7 => git_graph_view::draw(frame, app, *id, area, focused),
                8 => git_status_view::draw(frame, app, *id, area, focused),
                9 => diagnostics_view::draw(frame, app, *id, area, focused),
                11 => browser_view::draw(frame, app, *id, area, focused),
                12 => grep_view::draw(frame, app, *id, area, focused),
                13 => flaky_view::draw(frame, app, *id, area, focused),
                14 => outline_view::draw(frame, app, *id, area, focused),
                15 => cmdline_history_view::draw(frame, app, *id, area, focused),
                // Quickfix shares the Grep view — same shape, different
                // pane identity so `:grep` results don't clobber it.
                16 => grep_view::draw(frame, app, *id, area, focused),
                29 => {
                    cheatsheet_view::draw(frame, app, *id, area, focused);
                    None
                }
                30 => {
                    debug_view::draw(frame, app, *id, area);
                    None
                }
                31 => {
                    dap_repl_view::draw(frame, app, *id, area, focused);
                    None
                }
                32 => image_view::draw(frame, app, *id, area, focused),
                34 => {
                    claude_agents_view::draw(frame, app, *id, area, focused);
                    None
                }
                35 => {
                    ws_view::draw(frame, app, *id, area, focused);
                    None
                }
                36 => {
                    spend_report_view::draw(frame, app, *id, area, focused);
                    None
                }
                _ => editor_view::draw_pane(frame, app, *id, area, focused),
            }
        }
        Layout::Split {
            dir,
            ratio,
            first,
            second,
        } => {
            let (a, divider, b) = split_rects(area, *dir, *ratio);
            if divider.width > 0 && divider.height > 0 {
                let divider_idx = app.rects.split_dividers.len();
                let is_hover = app.hover_divider_idx == Some(divider_idx) || app.dragging.is_some();
                draw_divider(frame, divider, *dir, is_hover);
                app.rects.split_dividers.push(crate::layout::DividerHit {
                    rect: divider,
                    dir: *dir,
                    area,
                    path: path.clone(),
                });
            }
            path.push(false);
            let c1 = render_layout(frame, app, first, a, path);
            path.pop();
            path.push(true);
            let c2 = render_layout(frame, app, second, b, path);
            path.pop();
            c1.or(c2)
        }
    }
}

/// 2026-06-22 — drag ghost for a tree-file drag. Paints a small
/// chip showing the file's name near the cursor while the drag
/// is armed and the mouse is past the origin row. Cleared
/// automatically when `tree_drag` clears on mouse-up.
fn draw_tree_drag_ghost(frame: &mut Frame, app: &App) {
    use ratatui::style::{Modifier, Style};
    use ratatui::text::{Line, Span};
    use ratatui::widgets::Paragraph;
    let Some(drag) = app.tree_drag.as_ref() else {
        return;
    };
    if !drag.armed {
        return;
    }
    let cx = drag.cursor_x;
    let cy = drag.cursor_y;
    let name = drag
        .src_path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| drag.src_path.to_string_lossy().into_owned());
    let label = clip_to_cells(&name, 28);
    let label_w = label.chars().count() as u16;
    // 2026-06-22 — ghost chip: ` ⤴ <icon> <name> ` (5 + name cells).
    // The ⤴ "moving" arrow makes it instantly read as a drag,
    // and the bright bg means the user can't miss it.
    let prefix = if drag.src_is_dir { "📁 " } else { "📄 " };
    let chip_w = label_w + 5; // " 📄 <name> "
    let area = frame.area();
    // Paint the chip RIGHT next to the cursor (1 cell offset to
    // avoid covering the cursor itself). User-feedback 2026-06-22
    // — earlier (+2, +1) offset put the chip too far from the
    // cursor, making it hard to align with the drop zone.
    let mut chip_x = cx.saturating_add(1);
    let mut chip_y = cy;
    if chip_x + chip_w > area.x + area.width {
        chip_x = (area.x + area.width).saturating_sub(chip_w);
    }
    if chip_y >= area.y + area.height {
        chip_y = cy.saturating_sub(1);
    }
    let chip_rect = Rect {
        x: chip_x,
        y: chip_y,
        width: chip_w,
        height: 1,
    };
    let t = theme::cur();
    // Bright accent bg + dark fg so the chip really pops.
    let bg = t.blue;
    let fg = t.bg_darker;
    let line = Line::from(vec![
        Span::styled(" ".to_string(), Style::default().bg(bg)),
        Span::styled(prefix.to_string(), Style::default().fg(fg).bg(bg)),
        Span::styled(
            label,
            Style::default().fg(fg).bg(bg).add_modifier(Modifier::BOLD),
        ),
        Span::styled(" ".to_string(), Style::default().bg(bg)),
    ]);
    frame.render_widget(
        Paragraph::new(line).style(Style::default().bg(bg)),
        chip_rect,
    );
}

/// Drag-to-split drop hint. When a bufferline tab is dragged over a pane body,
/// paint the zone it will land in (left/right/top/bottom half for a split, or
/// the center box for a move-in-place) with a tinted fill + accent border and a
/// short label. No-op when no tab is being dragged over a pane.
fn draw_tab_drop_hint(frame: &mut Frame, app: &App) {
    use crate::app::tab_drop::{DropZone, zone_rect};
    let Some((pid, active_zone)) = app.rects.tab_drop_target else {
        return;
    };
    let Some((body, _)) = app
        .rects
        .pane_bodies
        .iter()
        .find(|(_, p)| *p == pid)
        .copied()
    else {
        return;
    };
    let t = theme::cur();
    // 2026-06-22 — VS Code-style drop overlay. Only the ACTIVE
    // zone gets painted; no outlines for the other zones, no
    // labels. For Left/Right/Top/Bottom the overlay covers HALF
    // the pane; for Center it covers the WHOLE pane. Style:
    // translucent gray (preserve some readability of the
    // underlying content). User-feedback 2026-06-22: earlier
    // 5-zone outlined version with labels was too busy.
    let rect = match active_zone {
        DropZone::Center => body,
        _ => zone_rect(body, active_zone),
    };
    if rect.width == 0 || rect.height == 0 {
        return;
    }
    // VS Code's drop indicator is a TRANSLUCENT GRAY overlay
    // (its `editorGroup.dropBackground` token is roughly 18%
    // alpha). A ratatui TUI can't do real alpha, but we can
    // mimic the effect by mutating ONLY the bg color of cells
    // under the overlay — the existing cell content + fg color
    // stay intact, so the user still reads what's underneath,
    // just with a gray tint. User-feedback 2026-06-22: a solid
    // blue paint hid the text entirely; gray-bg-only matches
    // VS Code's behavior.
    let buf = frame.buffer_mut();
    for y in rect.y..rect.y.saturating_add(rect.height) {
        for x in rect.x..rect.x.saturating_add(rect.width) {
            if let Some(cell) = buf.cell_mut((x, y)) {
                cell.set_bg(t.grey);
            }
        }
    }
}

/// VS Code-style top "command palette" strip — a single row across the
/// full window width with three regions, centered as a group:
///
///   `[ ← ][ → ]   [ 🔍  search files, run commands…  ▾ ]`
///
/// * Back / Forward arrows → `buffer.prev` / `buffer.next` (file history).
/// * Center chip → opens the command palette.
/// * Dropdown chevron → opens the recent-files picker.
///
/// Auto-hides when the window is narrower than `MIN_WIDTH`.
fn draw_palette_bar(frame: &mut Frame, app: &mut App, area: Rect) {
    if area.height == 0 || area.width == 0 {
        app.rects.palette_search_chip = None;
        app.rects.palette_back_button = None;
        app.rects.palette_forward_button = None;
        app.rects.palette_dropdown_button = None;
        return;
    }
    let t = theme::cur();
    let ascii = app.config.ui.ascii_icons;
    frame.render_widget(Block::default().style(Style::default().bg(t.bg_dark)), area);

    // Menu-bar words (File / Edit / View / …) — far-left of the
    // chrome row, before any centered cluster, matching the
    // standard macOS / Windows / Linux menu-bar position.
    // Visibility per `[ui] menu_bar` mode.
    app.rects.menu_bar_words.clear();
    let menu_mode = app.config.ui.menu_bar.as_str();
    let menu_visible = matches!(menu_mode, "always")
        || (menu_mode == "auto" && app.menu_open.is_some());
    if menu_visible {
        let menus = crate::menu_bar::bar();
        let mut mx = area.x;
        for (i, m) in menus.iter().enumerate() {
            let label_w = m.label.chars().count() as u16 + 2;
            if mx.saturating_add(label_w) > area.x + area.width {
                break;
            }
            let word_rect = Rect {
                x: mx,
                y: area.y,
                width: label_w,
                height: 1,
            };
            let is_open = app
                .menu_open
                .as_ref()
                .is_some_and(|s| s.menu_idx == i);
            // Always reveal the Alt+<letter> accelerator underlines.
            // Terminals can't send key events for modifier keys alone
            // (no "Alt down" event), so the Windows-style press-Alt-
            // to-reveal pattern isn't achievable. Always-on underlines
            // give the user a permanent reference for which letter
            // opens which menu.
            let any_menu_open = true;
            // Foreground matches the palette/search chip's `t.comment`
            // (dim grey); background stays on the chrome row's
            // `t.bg_dark`. When open, invert to a cyan highlight so
            // the active menu reads as the focal target.
            let (word_fg, word_bg) = if is_open {
                (t.bg_dark, t.cyan)
            } else {
                (t.comment, t.bg_dark)
            };
            let base_style = Style::default()
                .fg(word_fg)
                .bg(word_bg)
                .add_modifier(if is_open {
                    Modifier::BOLD
                } else {
                    Modifier::empty()
                });
            // The leading character of an ASCII-letter label is the
            // Alt+<letter> accelerator. Underline it when ANY menu
            // is open so the user discovers the shortcut while
            // browsing.
            let first_alpha_idx = m
                .label
                .chars()
                .position(|c| c.is_ascii_alphabetic());
            // The brand menu is the one whose first char isn't an
            // ASCII letter — its leading `>` is the prompt-mark
            // brand, the rest is the wordmark.
            let is_brand_menu = m
                .label
                .chars()
                .next()
                .is_some_and(|c| !c.is_ascii_alphabetic() && c != ' ');
            let mut spans: Vec<Span<'static>> = Vec::with_capacity(m.label.chars().count() + 2);
            spans.push(Span::styled(" ", base_style));
            for (idx, ch) in m.label.chars().enumerate() {
                let mut style = base_style;
                // Resting-state brand-mark glyphs (all chars before
                // the wordmark, e.g. `>` and `_` in `>_  mnml`) pop
                // in accent (cyan). Open-state inverts the whole
                // word, so we leave it alone there.
                let is_brand_mark =
                    is_brand_menu && first_alpha_idx.is_some_and(|fa| idx < fa);
                if is_brand_mark && !ch.is_whitespace() && !is_open {
                    style = style.fg(t.cyan);
                }
                if any_menu_open && Some(idx) == first_alpha_idx {
                    style = style.add_modifier(Modifier::UNDERLINED);
                }
                // BOLD the brand icon AND its wordmark text.
                if is_brand_menu && !ch.is_whitespace() {
                    style = style.add_modifier(Modifier::BOLD);
                }
                spans.push(Span::styled(ch.to_string(), style));
            }
            spans.push(Span::styled(" ", base_style));
            frame.render_widget(
                ratatui::widgets::Paragraph::new(Line::from(spans)),
                word_rect,
            );
            app.rects.menu_bar_words.push((word_rect, i));
            mx = mx.saturating_add(label_w);
        }
    }

    let back_glyph = if ascii { "<" } else { "\u{EA9B}" }; // codicon: arrow-left
    let fwd_glyph = if ascii { ">" } else { "\u{EA9C}" }; // codicon: arrow-right
    let magnify = if ascii { "?" } else { "\u{F0349}" };
    // `\u{EAB4}` is the real codicon `chevron-down` in Nerd Fonts.
    // `\u{EAA1}` (the obvious-looking choice) renders as chevron-UP in
    // this font.
    let dropdown_glyph = if ascii { "v" } else { "\u{EAB4}" };
    // VS Code shows the workspace / repo name as the palette label
    // when no search is active (rather than placeholder text). Fall
    // back to a generic placeholder if the workspace path has no
    // file-name component (root `/`, or a path that fails UTF-8).
    let workspace_label_raw: String = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| "search files, run commands…".to_string());
    // Pad the label so the chip has a consistent width (VS Code's chip
    // is fixed-width regardless of repo name). Truncate long names
    // with `…` so the chip never overflows.
    const CHIP_LABEL_W: usize = 24;
    let workspace_label = if workspace_label_raw.chars().count() > CHIP_LABEL_W {
        let mut s: String = workspace_label_raw.chars().take(CHIP_LABEL_W - 1).collect();
        s.push('…');
        s
    } else {
        let need = CHIP_LABEL_W - workspace_label_raw.chars().count();
        let mut s = workspace_label_raw;
        s.extend(std::iter::repeat_n(' ', need));
        s
    };

    // Button strings — each ` glyph ` = 3 cells.
    let back_str = format!(" {back_glyph} ");
    let fwd_str = format!(" {fwd_glyph} ");
    let dropdown_str = format!(" {dropdown_glyph} ");
    // Chip text without the dropdown — that's a separate clickable cell.
    let chip_text = format!("  {magnify}  {workspace_label}  ");

    // Forward / back arrows are "enabled" iff there's somewhere to
    // navigate — i.e. there's more than one open buffer (next_buffer
    // / prev_buffer cycle, so a single-buffer click is a no-op).
    // Enabled state uses the bright `fg` slot for max contrast on
    // every theme; disabled drops to the muted `comment` slot so the
    // arrows still read as glyphs but visually recede.
    let nav_enabled = app.panes.len() > 1;
    let nav_fg = if nav_enabled { t.fg } else { t.comment };

    let back_w = back_str.chars().count() as u16;
    let fwd_w = fwd_str.chars().count() as u16;
    let dropdown_w = dropdown_str.chars().count() as u16;
    let chip_w = chip_text.chars().count() as u16;
    // Layout: `[back][fwd] [chip][dropdown]` — a single cell of
    // strip-bg between the nav cluster and the chip body so the
    // back/forward buttons read as separate chrome from the chip
    // (rather than appearing fused). Anything wider felt off-balance
    // vs the back/forward inter-button spacing; 1 cell is the
    // narrowest meaningful separator.
    const NAV_GAP: u16 = 1;
    let total_w = back_w + fwd_w + NAV_GAP + chip_w + dropdown_w;
    if total_w > area.width {
        // Window too narrow for the full layout — fall back to chip only,
        // centered. Skips arrows + dropdown until there's room.
        let chip_only_w = chip_w.min(area.width);
        let cx = area.x + area.width.saturating_sub(chip_only_w) / 2;
        let chip_rect = Rect {
            x: cx,
            y: area.y,
            width: chip_only_w,
            height: 1,
        };
        frame.render_widget(
            ratatui::widgets::Paragraph::new(chip_text)
                .style(Style::default().fg(t.comment).bg(t.bg2)),
            chip_rect,
        );
        app.rects.palette_search_chip = Some(chip_rect);
        app.rects.palette_back_button = None;
        app.rects.palette_forward_button = None;
        app.rects.palette_dropdown_button = None;
        return;
    }

    let mut x = area.x + (area.width - total_w) / 2;
    let y = area.y;

    // Back button.
    let back_rect = Rect {
        x,
        y,
        width: back_w,
        height: 1,
    };
    // Buttons sit on a darker bg than the chip so the back/forward
    // cluster reads as chrome and the chip reads as the focal input.
    let btn_bg = t.bg_dark;
    frame.render_widget(
        ratatui::widgets::Paragraph::new(back_str).style(Style::default().fg(nav_fg).bg(btn_bg)),
        back_rect,
    );
    app.rects.palette_back_button = Some(back_rect);
    x += back_w;

    // Forward button.
    let fwd_rect = Rect {
        x,
        y,
        width: fwd_w,
        height: 1,
    };
    frame.render_widget(
        ratatui::widgets::Paragraph::new(fwd_str).style(Style::default().fg(nav_fg).bg(btn_bg)),
        fwd_rect,
    );
    app.rects.palette_forward_button = Some(fwd_rect);
    x += fwd_w + NAV_GAP;

    // Search chip.
    let chip_rect = Rect {
        x,
        y,
        width: chip_w,
        height: 1,
    };
    frame.render_widget(
        ratatui::widgets::Paragraph::new(chip_text).style(Style::default().fg(t.comment).bg(t.bg2)),
        chip_rect,
    );
    app.rects.palette_search_chip = Some(chip_rect);
    x += chip_w;

    // Dropdown chevron — visually glued to the chip's right edge but
    // dispatches its own command.
    let dropdown_rect = Rect {
        x,
        y,
        width: dropdown_w,
        height: 1,
    };
    frame.render_widget(
        ratatui::widgets::Paragraph::new(dropdown_str)
            .style(Style::default().fg(t.comment).bg(t.bg2)),
        dropdown_rect,
    );
    app.rects.palette_dropdown_button = Some(dropdown_rect);

    // 2026-06-21 — right-aligned chrome cluster (launcher icons /
    // `+` / TABS chips / theme toggle / close). Right-edge of the
    // workspace chip + dropdown is the leftward bound; if the
    // full cluster would visually overlap them, drop the TABS +
    // tab-page section. If even the compact cluster won't fit,
    // skip the cluster entirely.
    //
    // 2026-06-22 user-reported: at narrow widths the launcher
    // icons + tab-page chips overlapped (rendered on top of each
    // other). Stage the fallback so the most-clicked chips
    // (launchers + close) stay visible the longest.
    // `x` at this point is the LEFT edge of the dropdown chevron
    // (it wasn't bumped past the chevron after painting). The real
    // right edge of the workspace cluster is `x + dropdown_w`.
    let palette_right_edge = x + dropdown_w;
    let full_w = bufferline::right_cluster_width(app);
    let cluster_w = bufferline::pick_cluster_mode(
        area.x,
        area.width,
        palette_right_edge,
        full_w,
        4, // gap cells between palette + cluster
    );
    if let Some(w) = cluster_w {
        let cluster_area = Rect {
            x: area.x + area.width.saturating_sub(w),
            y: area.y,
            width: w,
            height: 1,
        };
        bufferline::paint_right_cluster(frame, app, cluster_area, t.bg_dark);
    } else {
        // Cluster hidden entirely — clear the chip rects so stale
        // rects from a wider frame don't steal clicks.
        app.rects.launcher_icon_rects.clear();
        app.rects.bufferline_new_tab_button = None;
        app.rects.bufferline_tab_page_chips.clear();
        app.rects.bufferline_tab_page_close.clear();
        app.rects.bufferline_theme_toggle = None;
        app.rects.bufferline_window_close = None;
    }
}

/// Sort key for the activity-bar Git section's file-change list.
/// Groups conflicts at the top (need attention first), then staged,
/// then modified, then untracked.
fn file_state_order(s: crate::git::status::FileState) -> u8 {
    match s {
        crate::git::status::FileState::Conflicted => 0,
        crate::git::status::FileState::Staged => 1,
        crate::git::status::FileState::Modified => 2,
        crate::git::status::FileState::Untracked => 3,
    }
}

/// Activity-bar Git section — branch + change-counts header, change
/// chips (`+N ●N -N` mapped from snapshot's added/changed/removed),
/// ahead/behind chip, then a launcher list of common git commands.
/// The existing GIT sub-section inside the Explorer rail stays
/// untouched (it's the always-visible compact branch list); this
/// activity section is the dedicated mode with more breathing room.
/// v2 follow-up: render the file-change list inline + a recent-commits
/// strip below the actions.
fn draw_git_section_content(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    // Header.
    frame.render_widget(
        Paragraph::new(ratatui::text::Line::from(" SOURCE CONTROL")).style(
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );

    let snap = app.git.snapshot().clone();
    let branch_label = snap
        .branch
        .clone()
        .unwrap_or_else(|| "(no branch)".to_string());
    let workspace_root = app.workspace.clone();
    let mut branch_spans: Vec<Span<'static>> = vec![Span::styled(
        format!("  ⎇ {branch_label}"),
        Style::default().fg(t.purple).bg(bg),
    )];
    if snap.ahead > 0 {
        branch_spans.push(Span::styled(
            format!("  ↑{}", snap.ahead),
            Style::default().fg(t.green).bg(bg),
        ));
    }
    if snap.behind > 0 {
        branch_spans.push(Span::styled(
            format!(" ↓{}", snap.behind),
            Style::default().fg(t.orange).bg(bg),
        ));
    }
    frame.render_widget(
        Paragraph::new(ratatui::text::Line::from(branch_spans)),
        Rect {
            x: area.x,
            y: area.y + 2,
            width: area.width,
            height: 1,
        },
    );

    // Change-count chips (semantic added/changed/removed counts).
    let chips_line = ratatui::text::Line::from(vec![
        Span::styled(
            format!("  +{}", snap.added),
            Style::default().fg(t.green).bg(bg),
        ),
        Span::styled(
            format!(" ●{}", snap.changed),
            Style::default().fg(t.yellow).bg(bg),
        ),
        Span::styled(
            format!(" -{}", snap.removed),
            Style::default().fg(t.red).bg(bg),
        ),
        if snap.conflicts > 0 {
            Span::styled(
                format!(
                    "  ⚠ {} conflict{}",
                    snap.conflicts,
                    if snap.conflicts == 1 { "" } else { "s" }
                ),
                Style::default()
                    .fg(t.red)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD),
            )
        } else {
            Span::styled("", Style::default().bg(bg))
        },
    ]);
    frame.render_widget(
        Paragraph::new(chips_line),
        Rect {
            x: area.x,
            y: area.y + 3,
            width: area.width,
            height: 1,
        },
    );

    // Inline change list (v2). Group files by state, render up to 12
    // rows total. Click a row → open that file in the editor (the
    // user can then run `git.diff_file` or save). Future v2.x: click
    // → open the per-file diff directly.
    let mut y_after_files = area.y + 5;
    if !snap.files.is_empty() && area.height > 6 {
        let header_y = area.y + 5;
        frame.render_widget(
            Paragraph::new(ratatui::text::Line::from(" CHANGES")).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD | Modifier::DIM),
            ),
            Rect {
                x: area.x,
                y: header_y,
                width: area.width,
                height: 1,
            },
        );
        // Sort by state group then by path.
        let mut files: Vec<(std::path::PathBuf, crate::git::status::FileState)> =
            snap.files.iter().map(|(p, s)| (p.clone(), *s)).collect();
        files.sort_by(|a, b| (file_state_order(a.1), &a.0).cmp(&(file_state_order(b.1), &b.0)));
        let mut fy = header_y + 1;
        let max_y = area.y + area.height;
        let cap = 12usize;
        for (path, state) in files.iter().take(cap) {
            if fy >= max_y {
                break;
            }
            let (glyph, color) = match state {
                crate::git::status::FileState::Modified => ("●", t.yellow),
                crate::git::status::FileState::Staged => ("◆", t.green),
                crate::git::status::FileState::Untracked => ("?", t.cyan),
                crate::git::status::FileState::Conflicted => ("⚠", t.red),
            };
            let rel = path
                .strip_prefix(&workspace_root)
                .unwrap_or(path)
                .to_string_lossy()
                .into_owned();
            let row_rect = Rect {
                x: area.x,
                y: fy,
                width: area.width,
                height: 1,
            };
            let line = ratatui::text::Line::from(vec![
                Span::styled(format!("  {glyph} "), Style::default().fg(color).bg(bg)),
                Span::styled(rel, Style::default().fg(t.fg).bg(bg)),
            ]);
            frame.render_widget(Paragraph::new(line), row_rect);
            // Click → open the file (works on the leaf path string, not
            // an absolute path — `tree_icon_buttons` carries a `&'static
            // str` command id, so for now we use the existing per-file
            // git.diff_file command which dispatches against whatever
            // editor is active. v2.x: a dedicated "open file at path"
            // click handler with the path embedded.
            app.rects
                .tree_icon_buttons
                .push((row_rect, "git.diff_file"));
            fy = fy.saturating_add(1);
        }
        if files.len() > cap && fy < max_y {
            frame.render_widget(
                Paragraph::new(ratatui::text::Line::from(format!(
                    "  + {} more (use git.diff_all)",
                    files.len() - cap
                )))
                .style(
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
                Rect {
                    x: area.x,
                    y: fy,
                    width: area.width,
                    height: 1,
                },
            );
            fy = fy.saturating_add(1);
        }
        y_after_files = fy.saturating_add(1);
    }

    // Inline commit textarea (v2.x). One-line input — click to focus,
    // Ctrl+Enter to submit, Esc to blur. Sits between the file-change
    // list and the launcher actions.
    let commit_focused = app.git_section_commit_focused;
    let mut y_after_commit = y_after_files;
    if area.height > 3 + (y_after_files - area.y) {
        let label_y = y_after_files;
        if label_y < area.y + area.height {
            frame.render_widget(
                Paragraph::new(ratatui::text::Line::from(" COMMIT MESSAGE")).style(
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::BOLD | Modifier::DIM),
                ),
                Rect {
                    x: area.x,
                    y: label_y,
                    width: area.width,
                    height: 1,
                },
            );
        }
        let input_y = label_y + 1;
        if input_y < area.y + area.height {
            let cursor_glyph = if commit_focused { "█" } else { "" };
            let input_line = ratatui::text::Line::from(vec![
                Span::styled(" > ", Style::default().fg(t.yellow).bg(bg)),
                Span::styled(
                    app.git_section_commit_buffer.clone(),
                    Style::default().fg(t.fg).bg(bg),
                ),
                Span::styled(
                    cursor_glyph.to_string(),
                    Style::default().fg(t.yellow).bg(bg),
                ),
            ]);
            let input_rect = Rect {
                x: area.x,
                y: input_y,
                width: area.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(input_line), input_rect);
            // Click anywhere on the input row → focus the textarea.
            app.rects
                .tree_icon_buttons
                .push((input_rect, "view.git_commit_focus"));
        }
        let hint_y = input_y + 1;
        if hint_y < area.y + area.height {
            let hint_text = if commit_focused {
                " type · Ctrl+Enter commit · Esc blur"
            } else {
                " click to focus · Ctrl+Enter to commit"
            };
            frame.render_widget(
                Paragraph::new(ratatui::text::Line::from(hint_text)).style(
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
                Rect {
                    x: area.x,
                    y: hint_y,
                    width: area.width,
                    height: 1,
                },
            );
        }
        y_after_commit = hint_y.saturating_add(2);
    }

    // Action rows — the high-frequency git operations.
    let rows: &[(&str, &str, &'static str)] = &[
        ("▸ Commit…", "—", "git.commit"),
        ("▸ Diff workspace", "—", "git.diff_all"),
        ("▸ Diff file", "—", "git.diff_file"),
        ("▸ Pull", "—", "git.pull"),
        ("▸ Push", "—", "git.push"),
        ("▸ Fetch", "—", "git.fetch"),
        ("▸ Stash", "—", "git.stash"),
        ("▸ Pop stash", "—", "git.stash_pop"),
        ("▸ Toggle blame", "—", "git.blame_toggle"),
        ("▸ Switch repo", "—", "git.switch_repo"),
        ("▸ Refresh repos", "—", "git.refresh_repos"),
    ];

    let mut y = y_after_commit;
    for (label, chord, cmd_id) in rows {
        if y + 1 >= area.y + area.height {
            break;
        }
        let label_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(ratatui::text::Line::from(format!("  {label}")))
                .style(Style::default().fg(t.fg).bg(bg)),
            label_rect,
        );
        let chord_rect = Rect {
            x: area.x,
            y: y + 1,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(ratatui::text::Line::from(format!("    {chord}"))).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
            chord_rect,
        );
        app.rects.tree_icon_buttons.push((label_rect, *cmd_id));
        app.rects.tree_icon_buttons.push((chord_rect, *cmd_id));
        y = y.saturating_add(2);
    }
}

/// Activity-bar Debug section — DAP launcher + at-a-glance status.
/// Shows whether a session is running, the watch + breakpoint counts,
/// and clickable rows for the run/continue/step family. The actual
/// Variables / Call-stack / Watches grid lives in the existing
/// `debug_view.rs` (an editor-body pane); this section is a control
/// panel, not a replacement. v2 follow-up: inline mini-watches list
/// so the user can glance without opening the pane.
fn draw_debug_section(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    // Header.
    frame.render_widget(
        Paragraph::new(ratatui::text::Line::from(" DEBUG")).style(
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );

    // Session status line.
    let session_active = app.dap.is_some();
    let status_label = if session_active {
        "● session active"
    } else {
        "○ no session"
    };
    let status_color = if session_active { t.green } else { t.comment };
    let watch_n = app.dap_watches.len();
    frame.render_widget(
        Paragraph::new(ratatui::text::Line::from(format!(
            "  {status_label}    {watch_n} watch{}",
            if watch_n == 1 { "" } else { "es" }
        )))
        .style(Style::default().fg(status_color).bg(bg)),
        Rect {
            x: area.x,
            y: area.y + 2,
            width: area.width,
            height: 1,
        },
    );

    // Inline watches list (v2). Each watch gets a row:
    //   <expr> = <value>     (dim error if eval failed)
    // Truncated to fit width; only rendered when there are any.
    let mut y_after_watches = area.y + 4;
    if !app.dap_watches.is_empty() && area.height > 5 {
        let header_y = area.y + 4;
        frame.render_widget(
            Paragraph::new(ratatui::text::Line::from(" WATCHES")).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::BOLD | Modifier::DIM),
            ),
            Rect {
                x: area.x,
                y: header_y,
                width: area.width,
                height: 1,
            },
        );
        let mut wy = header_y + 1;
        // Cap to ~5 rows so we don't crowd the launcher actions below.
        for expr in app.dap_watches.iter().take(5) {
            if wy + 1 >= area.y + area.height {
                break;
            }
            let result = app.dap_watch_results.get(expr);
            let (value_text, value_style) = match result {
                Some(r) if r.err.is_some() => (
                    format!("err: {}", r.err.as_deref().unwrap_or("")),
                    Style::default()
                        .fg(t.red)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
                Some(r) => (r.value.clone(), Style::default().fg(t.fg).bg(bg)),
                None => (
                    "(not evaluated)".to_string(),
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
            };
            // Truncate the value column so the row stays one line.
            let avail = (area.width as usize).saturating_sub(expr.chars().count() + 5);
            let truncated_value: String = if value_text.chars().count() > avail {
                let take = avail.saturating_sub(1);
                let mut s: String = value_text.chars().take(take).collect();
                s.push('…');
                s
            } else {
                value_text
            };
            let line = ratatui::text::Line::from(vec![
                Span::styled(format!("  {expr} = "), Style::default().fg(t.cyan).bg(bg)),
                Span::styled(truncated_value, value_style),
            ]);
            frame.render_widget(
                Paragraph::new(line),
                Rect {
                    x: area.x,
                    y: wy,
                    width: area.width,
                    height: 1,
                },
            );
            wy = wy.saturating_add(1);
        }
        if app.dap_watches.len() > 5 && wy < area.y + area.height {
            frame.render_widget(
                Paragraph::new(ratatui::text::Line::from(format!(
                    "  + {} more (use add/remove)",
                    app.dap_watches.len() - 5
                )))
                .style(
                    Style::default()
                        .fg(t.comment)
                        .bg(bg)
                        .add_modifier(Modifier::DIM),
                ),
                Rect {
                    x: area.x,
                    y: wy,
                    width: area.width,
                    height: 1,
                },
            );
            wy = wy.saturating_add(1);
        }
        y_after_watches = wy.saturating_add(1);
    }

    let rows: &[(&str, &str, &'static str)] = &[
        ("▸ Run", "F5", "dap.run"),
        ("▸ Continue", "F5 (running)", "dap.continue"),
        ("▸ Step over", "F10", "dap.next"),
        ("▸ Step into", "F11", "dap.step_in"),
        ("▸ Step out", "Shift+F11", "dap.step_out"),
        ("▸ Pause", "F6", "dap.pause"),
        ("▸ Toggle breakpoint", "F9", "dap.toggle_breakpoint"),
        ("▸ List breakpoints", "—", "dap.list_breakpoints"),
        ("▸ Add watch…", "—", "dap.add_watch"),
        ("▸ Remove watch…", "—", "dap.remove_watch"),
        ("▸ Clear watches", "—", "dap.clear_watches"),
    ];

    let mut y = y_after_watches;
    for (label, chord, cmd_id) in rows {
        if y + 1 >= area.y + area.height {
            break;
        }
        let label_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(ratatui::text::Line::from(format!("  {label}")))
                .style(Style::default().fg(t.fg).bg(bg)),
            label_rect,
        );
        let chord_rect = Rect {
            x: area.x,
            y: y + 1,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(ratatui::text::Line::from(format!("    {chord}"))).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
            chord_rect,
        );
        app.rects.tree_icon_buttons.push((label_rect, *cmd_id));
        app.rects.tree_icon_buttons.push((chord_rect, *cmd_id));
        y = y.saturating_add(2);
    }
}

/// Activity-bar Search section — inline grep with results streaming
/// below the input. Type-then-Enter runs the workspace grep; ↑↓ steps
/// the selection; Enter on a result row jumps to that file+line.
///
/// Layout:
///   SEARCH
///
///    / <query>█
///    <N hits (rg)>  or hint when not run
///
///    src/foo.rs
///      42:5  let x = 1;
///      55:5  let y = 2;
///    src/bar.rs
///      18:9  let z = 3;
///
/// Focus: clicking the Search activity-bar icon auto-focuses the
/// input (handled in `App::set_activity_section`). `Esc` blurs back
/// to the editor; while blurred, Enter on a result still jumps via
/// the editor's normal handling (selection is preserved across the
/// blur).
fn draw_search_section(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    app.rects.search_section_hit_rects.clear();
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    frame.render_widget(
        Paragraph::new(ratatui::text::Line::from(" SEARCH")).style(
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );
    let input_y = area.y + 2;
    if input_y >= area.y + area.height {
        return;
    }
    let focused = app.search_input_focused;
    let cursor_glyph = if focused { "█" } else { "" };
    let input_line = ratatui::text::Line::from(vec![
        Span::styled(" / ", Style::default().fg(t.yellow).bg(bg)),
        Span::styled(app.search_query.clone(), Style::default().fg(t.fg).bg(bg)),
        Span::styled(
            cursor_glyph.to_string(),
            Style::default().fg(t.yellow).bg(bg),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(input_line),
        Rect {
            x: area.x,
            y: input_y,
            width: area.width,
            height: 1,
        },
    );
    let status_y = input_y + 1;
    if status_y < area.y + area.height {
        let status_text = if app.search_used.is_empty() {
            if focused {
                " type · Enter to run · Esc to blur".to_string()
            } else {
                " click 🔍 icon to focus".to_string()
            }
        } else {
            let n = app.search_hits.len();
            format!(
                " {} hit{} ({})",
                n,
                if n == 1 { "" } else { "s" },
                app.search_used
            )
        };
        frame.render_widget(
            Paragraph::new(ratatui::text::Line::from(status_text)).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
            Rect {
                x: area.x,
                y: status_y,
                width: area.width,
                height: 1,
            },
        );
    }
    if app.search_hits.is_empty() {
        return;
    }
    let body_top = status_y.saturating_add(2);
    let body_max = area.y + area.height;
    let mut y = body_top;
    let selected = app.search_selected;
    let mut prev_path: Option<String> = None;
    let visible_rows = (body_max - body_top) as usize;
    if visible_rows == 0 {
        return;
    }
    let scroll_start = if selected >= visible_rows {
        selected + 1 - visible_rows
    } else {
        0
    };
    for (i, hit) in app
        .search_hits
        .iter()
        .enumerate()
        .skip(scroll_start)
        .take(visible_rows)
    {
        if y >= body_max {
            break;
        }
        if prev_path.as_deref() != Some(hit.rel.as_str()) {
            if y >= body_max {
                break;
            }
            frame.render_widget(
                Paragraph::new(ratatui::text::Line::from(format!(" {}", hit.rel)))
                    .style(Style::default().fg(t.cyan).bg(bg)),
                Rect {
                    x: area.x,
                    y,
                    width: area.width,
                    height: 1,
                },
            );
            prev_path = Some(hit.rel.clone());
            y = y.saturating_add(1);
            if y >= body_max {
                break;
            }
        }
        let is_sel = i == selected;
        let line_style = if is_sel {
            Style::default()
                .fg(t.fg)
                .bg(t.bg2)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::default().fg(t.fg).bg(bg)
        };
        let lineno_color = if is_sel { t.fg } else { t.yellow };
        let row = ratatui::text::Line::from(vec![
            Span::styled(
                format!("   {}:{}  ", hit.line + 1, hit.col + 1),
                Style::default()
                    .fg(lineno_color)
                    .bg(if is_sel { t.bg2 } else { bg }),
            ),
            Span::styled(hit.text.trim().to_string(), line_style),
        ]);
        let row_rect = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(Paragraph::new(row), row_rect);
        app.rects.search_section_hit_rects.push((row_rect, i));
        y = y.saturating_add(1);
    }
}

/// Activity-bar Integrations section — renders the configured
/// `[[ui.integration_icon]]` entries as a vertical list of clickable
/// rows. Each row: large glyph + tooltip/id, with the bound command
/// shown dim below. Clicking a row fires the same command path as
/// the compact icon strip in the Explorer rail (palette command id /
/// `:ex`).
/// Result of probing whether the binary backing an integration's
/// command is actually on the user's PATH. Today only the
/// `:term <binary>` shape is probed; mnml-internal commands
/// (no prefix) are assumed available because they don't shell out.
enum IntegrationAvailability {
    Available,
    /// Binary name (just the leaf, no path) the user would need to
    /// install. Surfaced as `(<bin> not installed)` next to the row.
    Missing(String),
}

/// Walk the `command` string from an `IntegrationIcon` and decide
/// whether the underlying tool is installed. Only `:term <binary>`
/// invocations are probed (built-in palette commands like
/// `:ai.claude_code` always return `Available`). Detection happens in
/// `integration_detect`: in-process `$PATH` walk + per-OS well-known
/// install dirs (`~/.cargo/bin`, Homebrew, etc.), with results cached
/// per-session so this is cheap to call per-frame.
fn integration_availability(command: &str) -> IntegrationAvailability {
    let Some(bin) = crate::integration_detect::sibling_binary_for_command(command) else {
        return IntegrationAvailability::Available;
    };
    if crate::integration_detect::is_binary_installed(bin) {
        IntegrationAvailability::Available
    } else {
        IntegrationAvailability::Missing(bin.to_string())
    }
}

fn draw_integrations_section(frame: &mut Frame, app: &mut App, area: Rect) {
    let t = theme::cur();
    let bg = t.bg_darker;
    frame.render_widget(Block::default().style(Style::default().bg(bg)), area);
    if area.height < 2 || area.width < 8 {
        return;
    }
    let nerd = !app.config.ui.ascii_icons;

    // Header.
    frame.render_widget(
        Paragraph::new(ratatui::text::Line::from(" INTEGRATIONS")).style(
            Style::default()
                .fg(t.fg)
                .bg(bg)
                .add_modifier(Modifier::BOLD),
        ),
        Rect {
            x: area.x,
            y: area.y,
            width: area.width,
            height: 1,
        },
    );

    // Empty-state hint when no icons are configured.
    let icons = app.config.ui.integration_icons.clone();
    if icons.is_empty() {
        let msg = " No integrations — add [[ui.integration_icon]] in your config";
        let body = Rect {
            x: area.x,
            y: area.y + 2,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(msg).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::ITALIC),
            ),
            body,
        );
        return;
    }

    // Each entry takes 3 rows: glyph+name, command dim, blank.
    let mut y = area.y + 2;
    for (idx, icon) in icons.iter().enumerate() {
        if y + 1 >= area.y + area.height {
            break;
        }
        let glyph = if nerd {
            icon.glyph.as_str()
        } else {
            icon.fallback.as_str()
        };
        let fg = match icon.color.as_str() {
            "orange" => t.orange,
            "yellow" => t.yellow,
            "cyan" => t.cyan,
            "blue" => t.blue,
            "green" => t.green,
            "red" => t.red,
            "purple" => t.purple,
            "teal" => t.teal,
            _ => t.fg,
        };
        let name = icon
            .tooltip
            .as_deref()
            .filter(|s| !s.is_empty())
            .unwrap_or(icon.id.as_str())
            .to_string();
        // Probe availability for `:term <binary>` commands —
        // a stale or missing binary is the only "broken" state worth
        // surfacing at v1. Internal `mnml` commands (no prefix) are
        // always assumed available.
        let availability = integration_availability(&icon.command);
        let (name_fg, suffix) = match availability {
            IntegrationAvailability::Available => (t.fg, None),
            IntegrationAvailability::Missing(bin) => {
                (t.comment, Some(format!("  ({} not installed)", bin)))
            }
        };
        let row1 = Rect {
            x: area.x,
            y,
            width: area.width,
            height: 1,
        };
        let mut name_spans: Vec<Span<'static>> = vec![
            Span::styled(format!("  {glyph} "), Style::default().fg(fg).bg(bg)),
            Span::styled(name, Style::default().fg(name_fg).bg(bg)),
        ];
        if let Some(suffix) = suffix {
            name_spans.push(Span::styled(
                suffix,
                Style::default()
                    .fg(t.red)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ));
        }
        frame.render_widget(Paragraph::new(ratatui::text::Line::from(name_spans)), row1);
        // Register the whole row as a click target. The mouse
        // dispatcher in tui.rs walks the same `integration_icon_rects`
        // list it uses for the compact rail strip, so adding our row
        // there gives it the existing click semantics for free
        // (palette command / `:ex` prefix handling).
        app.rects.integration_icon_rects.push((row1, idx));

        if y + 1 >= area.y + area.height {
            break;
        }
        let row2 = Rect {
            x: area.x,
            y: y + 1,
            width: area.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(ratatui::text::Line::from(format!("    {}", icon.command))).style(
                Style::default()
                    .fg(t.comment)
                    .bg(bg)
                    .add_modifier(Modifier::DIM),
            ),
            row2,
        );
        // The second row should be clickable too — same target.
        app.rects.integration_icon_rects.push((row2, idx));

        y = y.saturating_add(3);
    }
}

/// 2026-06-22 — paint a multi-tab strip above an in-split leaf,
/// one chip per pane in the leaf's `tabs`. Active chip is
/// highlighted (bg2); inactive chips are dimmer (bg_darker).
/// Each chip renders ` <icon> <name> <•/×> ` left-to-right.
/// Click chip → switch active. Click × → close that tab.
fn paint_leaf_tab_strip(
    frame: &mut Frame,
    app: &mut App,
    active: crate::layout::PaneId,
    tabs: &[crate::layout::PaneId],
    strip: Rect,
    leaf_focused: bool,
) {
    use crate::pane::Pane;
    use ratatui::style::{Modifier, Style};
    use ratatui::text::{Line, Span};
    use ratatui::widgets::Paragraph;
    let t = theme::cur();
    let nerd = !app.config.ui.ascii_icons;

    // Paint the strip bg first so gaps between chips read as the
    // un-tabbed bar background, not random terminal fill.
    let strip_bg = t.bg_darker;
    frame.render_widget(
        Paragraph::new("").style(Style::default().bg(strip_bg)),
        strip,
    );

    // Per-chip layout: ` <icon> <name>[•] <× >`. Min name width 4
    // so chips with short names don't squish to nothing.
    let chip_max_name_w: usize = 18;

    // 2026-06-22 — VS Code-style split-editor buttons at the
    // far right of the strip. Reserve 6 cells (` ⊟ ` + ` ⊞ `,
    // 3 each) before laying tabs so chips don't overflow into
    // the buttons. Tabs that don't fit get clipped per the
    // existing chip_w logic.
    const SPLIT_BTN_W: u16 = 3;
    // Three base buttons (terminal + V-split + H-split) plus the
    // optional AI button when `[ui] tab_bar_ai_icon != "none"`.
    let ai_enabled = app.config.ui.tab_bar_ai_icon != "none";
    let split_btns_total: u16 = SPLIT_BTN_W * if ai_enabled { 4 } else { 3 };
    let mut chip_x = strip.x;
    let strip_right = strip.x + strip.width;
    let tabs_right = strip_right.saturating_sub(split_btns_total);

    for &id in tabs {
        if chip_x >= tabs_right {
            break;
        }
        let Some(pane) = app.panes.get(id) else {
            continue;
        };
        let is_active = id == active;
        // Active chip: bg2 + bright fg. Inactive: bg_darker + dim fg.
        let chip_bg = if is_active { t.bg2 } else { strip_bg };
        let chip_fg = if is_active && leaf_focused {
            t.fg
        } else if is_active {
            t.fg
        } else {
            t.comment
        };
        let title = pane.title();
        let dirty = pane.is_dirty();
        let (glyph, icon_color) = icon_for_pane(pane, nerd);
        let pinned = matches!(pane, Pane::Editor(b) if b.is_pinned);
        let is_preview = matches!(pane, Pane::Editor(b) if b.is_preview);

        // 2026-06-22 — pinned tabs keep the file-type glyph on
        // the LEFT (so you can still see what kind of file it
        // is) and show the pin indicator on the RIGHT where the
        // close × would normally be. User-feedback.
        let icon_text = glyph.to_string();

        // chip = " <icon> <name> <•/⌹/×> "
        let name_clipped = clip_to_cells(&title, chip_max_name_w);
        let icon_w = icon_text.chars().count() as u16;
        let name_w = name_clipped.chars().count() as u16;
        // Status char priority:
        //   dirty       → •  (orange — any tab)
        //   pinned      → 📌  (yellow — any tab)
        //   active+clean → ×  (red close — only active)
        //   else        → space
        let pin_glyph = if nerd { "\u{f08d}" } else { "P" };
        // Pinned wins over dirty + active (matches VS Code).
        let status_char = if pinned {
            pin_glyph
        } else if dirty {
            "•"
        } else if is_active {
            "×"
        } else {
            " "
        };
        let status_color = if pinned {
            t.yellow
        } else if dirty {
            t.orange
        } else if is_active {
            t.red
        } else {
            chip_fg
        };
        let chip_w = 1 + icon_w + 1 + name_w + 1 + 1 + 1; // pad + icon + gap + name + gap + status + pad
        // Clip to remaining space.
        let avail = tabs_right.saturating_sub(chip_x);
        let painted_w = chip_w.min(avail);
        if painted_w == 0 {
            break;
        }
        let chip_rect = Rect {
            x: chip_x,
            y: strip.y,
            width: painted_w,
            height: 1,
        };

        // Build the line as a sequence of styled spans with the chip's bg.
        let mut name_style = Style::default().fg(chip_fg).bg(chip_bg);
        if is_active {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        if is_preview {
            name_style = name_style.add_modifier(Modifier::ITALIC);
        }
        let line = Line::from(vec![
            Span::styled(" ".to_string(), Style::default().bg(chip_bg)),
            Span::styled(
                icon_text,
                Style::default().fg(icon_color).bg(chip_bg),
            ),
            Span::styled(" ".to_string(), Style::default().bg(chip_bg)),
            Span::styled(name_clipped, name_style),
            Span::styled(" ".to_string(), Style::default().bg(chip_bg)),
            Span::styled(
                status_char.to_string(),
                Style::default().fg(status_color).bg(chip_bg),
            ),
            Span::styled(" ".to_string(), Style::default().bg(chip_bg)),
        ]);
        frame.render_widget(
            Paragraph::new(line).style(Style::default().bg(chip_bg)),
            chip_rect,
        );

        // Register click rects: whole chip → switch active.
        // Active chip's × (4th-from-end of the chip) → close.
        app.rects
            .split_tab_chips
            .push((chip_rect, active, id));
        if is_active && painted_w >= 3 {
            // The × sits at: pad(1) + icon(1) + gap(1) + name + gap(1) → 4+name_w from chip_x
            // Actually let me compute it from the right: the trailing pad is 1, then × is 1.
            let close_x = chip_rect.x + chip_rect.width.saturating_sub(2);
            let close_rect = Rect {
                x: close_x,
                y: chip_rect.y,
                width: 1,
                height: 1,
            };
            app.rects
                .split_tab_close
                .push((close_rect, active, id));
        }

        chip_x = chip_x.saturating_add(painted_w);
        // 1-cell gap between chips (strip bg shows through).
        chip_x = chip_x.saturating_add(1);
    }

    // VS Code-style split-editor + terminal buttons on the far
    // right of the strip. Three glyphs (terminal, vertical-split,
    // horizontal-split), each in a 3-cell ` <glyph> ` button.
    // Terminal click → focus this leaf + open a shell. Split
    // clicks → focus this leaf + split_active(dir).
    // Glyph naming follows the *visual* layout, not the
    // SplitDir axis label. See `bufferline::paint_split_buttons`.
    let term_glyph = if nerd { "\u{ea85}" } else { "$" };
    let side_by_side_glyph = if nerd { "\u{eb56}" } else { "|" };
    let stacked_glyph = if nerd { "\u{eb57}" } else { "-" };
    let dim_fg = t.comment;
    let mut bx = strip_right.saturating_sub(split_btns_total);

    // AI button (leftmost in cluster) — only when configured.
    if ai_enabled {
        let (ai_glyph, ai_fallback, ai_fg) = match app.config.ui.tab_bar_ai_icon.as_str() {
            "codex" => ("\u{F8B1}", "C", t.cyan),
            _ => ("\u{F8B0}", "*", t.orange),
        };
        let glyph = if nerd { ai_glyph } else { ai_fallback };
        let ai_rect = Rect {
            x: bx,
            y: strip.y,
            width: SPLIT_BTN_W,
            height: 1,
        };
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(strip_bg)),
            Span::styled(glyph, Style::default().fg(ai_fg).bg(strip_bg)),
            Span::styled(" ", Style::default().bg(strip_bg)),
        ]);
        frame.render_widget(Paragraph::new(line), ai_rect);
        app.rects.split_strip_ai_buttons.push((ai_rect, active));
        bx = bx.saturating_add(SPLIT_BTN_W);
    }

    // Terminal button.
    {
        let term_rect = Rect {
            x: bx,
            y: strip.y,
            width: SPLIT_BTN_W,
            height: 1,
        };
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(strip_bg)),
            Span::styled(term_glyph, Style::default().fg(dim_fg).bg(strip_bg)),
            Span::styled(" ", Style::default().bg(strip_bg)),
        ]);
        frame.render_widget(Paragraph::new(line), term_rect);
        app.rects.split_strip_term_buttons.push((term_rect, active));
        bx = bx.saturating_add(SPLIT_BTN_W);
    }

    for (glyph, dir) in [
        (side_by_side_glyph, crate::layout::SplitDir::Horizontal),
        (stacked_glyph, crate::layout::SplitDir::Vertical),
    ] {
        let btn_rect = Rect {
            x: bx,
            y: strip.y,
            width: SPLIT_BTN_W,
            height: 1,
        };
        let line = Line::from(vec![
            Span::styled(" ", Style::default().bg(strip_bg)),
            Span::styled(glyph, Style::default().fg(dim_fg).bg(strip_bg)),
            Span::styled(" ", Style::default().bg(strip_bg)),
        ]);
        frame.render_widget(Paragraph::new(line), btn_rect);
        app.rects
            .split_strip_buttons
            .push((btn_rect, active, dir));
        bx = bx.saturating_add(SPLIT_BTN_W);
    }
}

/// Pick a `(glyph, color)` for any pane kind — duplicates the
/// dispatch in `bufferline::draw` but kept inline here so the
/// per-leaf tab strip doesn't need a public API on bufferline.
fn icon_for_pane(
    pane: &crate::pane::Pane,
    nerd: bool,
) -> (&'static str, ratatui::style::Color) {
    use crate::pane::Pane;
    match pane {
        Pane::Editor(b) => {
            let p = b
                .path
                .clone()
                .unwrap_or_else(|| std::path::PathBuf::from("untitled"));
            crate::ui::icons::for_path(&p, false, false, nerd)
        }
        Pane::MdPreview(p) => crate::ui::icons::for_path(&p.path, false, false, nerd),
        Pane::Diff(_) => (if nerd { "\u{f0e7e}" } else { "±" }, theme::cur().orange),
        Pane::GitGraph(_) => (if nerd { "\u{f1d3}" } else { "⎇" }, theme::cur().orange),
        Pane::GitStatus(_) => (if nerd { "\u{f1d2}" } else { "±" }, theme::cur().green),
        Pane::Request(_) => (if nerd { "\u{f0a3e}" } else { "⚡" }, theme::cur().yellow),
        Pane::Pty(_) => (if nerd { "\u{f489}" } else { "▶" }, theme::cur().teal),
        Pane::Ai(_) => (if nerd { "\u{f0e0a}" } else { "✦" }, theme::cur().purple),
        Pane::Tests(_) => (if nerd { "\u{f0668}" } else { "✓" }, theme::cur().green),
        Pane::Browser(_) => (if nerd { "\u{f059f}" } else { "◉" }, theme::cur().blue),
        Pane::Diagnostics(_) => (if nerd { "\u{f0026}" } else { "⚠" }, theme::cur().red),
        Pane::Grep(_) => (if nerd { "\u{f0349}" } else { "⌕" }, theme::cur().yellow),
        Pane::Flaky(_) => (if nerd { "\u{f0668}" } else { "≋" }, theme::cur().purple),
        Pane::Outline(_) => (if nerd { "\u{f01bd}" } else { "⌥" }, theme::cur().purple),
        Pane::Quickfix(_) => (if nerd { "\u{f0349}" } else { "⌕" }, theme::cur().teal),
        Pane::CmdlineHistory(_) => (if nerd { "\u{eb15}" } else { "❯" }, theme::cur().comment),
        Pane::Cheatsheet(_) => (if nerd { "\u{f128}" } else { "?" }, theme::cur().yellow),
        Pane::Debug(_) => (if nerd { "\u{f188}" } else { "🐛" }, theme::cur().red),
        Pane::DapRepl(_) => (if nerd { "\u{F018D}" } else { ">" }, theme::cur().cyan),
        Pane::Image(_) => (if nerd { "\u{F021F}" } else { "▤" }, theme::cur().purple),
        Pane::ClaudeAgents(_) => (if nerd { "\u{F06A9}" } else { "◆" }, theme::cur().purple),
        Pane::Websocket(_) => (if nerd { "\u{F0317}" } else { "◇" }, theme::cur().teal),
        Pane::SpendReport(_) => (if nerd { "\u{F01C2}" } else { "$" }, theme::cur().orange),
    }
}

/// Cell-width-aware clip with `…` suffix.
fn clip_to_cells(s: &str, max_cells: usize) -> String {
    if s.chars().count() <= max_cells {
        return s.to_string();
    }
    if max_cells == 0 {
        return String::new();
    }
    let mut out: String = s.chars().take(max_cells.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn draw_divider(frame: &mut Frame, rect: Rect, dir: SplitDir, hover: bool) {
    let t = theme::cur();
    // Hover/drag state: paint the divider in yellow so the user knows it's
    // grabbable. Idle state stays subtle (`t.line` / `t.comment`).
    let (line_fg, grip_fg) = if hover {
        (t.yellow, t.yellow)
    } else {
        (t.line, t.comment)
    };
    let line_style = Style::default().fg(line_fg).bg(t.bg_dark);
    let grip_style = Style::default()
        .fg(grip_fg)
        .bg(t.bg_dark)
        .add_modifier(if hover {
            Modifier::BOLD
        } else {
            Modifier::empty()
        });
    match dir {
        SplitDir::Horizontal => {
            // Vertical divider — paint `│` everywhere, then a centered
            // 2-row `┃` grip cue advertising the drag handle.
            let grip_h: u16 = 2;
            let grip_y = rect.y + rect.height.saturating_sub(grip_h) / 2;
            for dy in 0..rect.height {
                let abs_y = rect.y + dy;
                let in_grip = abs_y >= grip_y && abs_y < grip_y + grip_h;
                let (glyph, style) = if in_grip {
                    ("┃", grip_style)
                } else {
                    ("│", line_style)
                };
                frame.render_widget(
                    Paragraph::new(Span::styled(glyph, style)),
                    Rect::new(rect.x, abs_y, 1, 1),
                );
            }
        }
        SplitDir::Vertical => {
            // Horizontal divider — paint `─` everywhere, then a
            // centered 2-cell `━` grip cue.
            let grip_w: u16 = 4;
            let grip_x = rect.x + rect.width.saturating_sub(grip_w) / 2;
            let line: String = "─".repeat(rect.width as usize);
            frame.render_widget(Paragraph::new(Span::styled(line, line_style)), rect);
            // Overpaint the grip cells.
            let grip = "━".repeat(grip_w as usize);
            frame.render_widget(
                Paragraph::new(Span::styled(grip, grip_style)),
                Rect::new(grip_x, rect.y, grip_w, 1),
            );
        }
    }
}

#[cfg(test)]
mod palette_bar_tests {
    use super::*;
    use crate::app::App;
    use crate::config::Config;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    /// Render the palette bar at `width` cells and return the row
    /// as a String. Drives the real `draw_palette_bar` (not just
    /// the math helper) so we catch behavior across the actual
    /// render path — including the bufferline cluster paint,
    /// which the unit tests in bufferline.rs can't verify.
    fn render_palette_bar_row(width: u16, n_tabs: usize) -> String {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        let mut app = App::new(ws, Config::default()).unwrap();
        // Open extra tab pages to populate the TABS chip list.
        for _ in 1..n_tabs {
            app.tab_new(None);
        }
        let mut term = Terminal::new(TestBackend::new(width, 3)).unwrap();
        term.draw(|f| {
            let area = Rect {
                x: 0,
                y: 0,
                width,
                height: 1,
            };
            draw_palette_bar(f, &mut app, area);
        })
        .unwrap();
        let buf = term.backend().buffer();
        (0..buf.area.width).map(|x| buf[(x, 0)].symbol()).collect()
    }

    #[test]
    fn palette_bar_wide_shows_full_cluster_with_tabs() {
        let row = render_palette_bar_row(200, 3);
        // Wide enough — TABS label + numbered chips must be present.
        assert!(row.contains("TABS"), "expected 'TABS' in wide row: {row:?}");
        assert!(
            row.contains(" 1 "),
            "expected ' 1 ' tab chip in wide row: {row:?}"
        );
        assert!(
            row.contains(" 2 "),
            "expected ' 2 ' tab chip in wide row: {row:?}"
        );
    }

    #[test]
    fn palette_bar_narrow_hides_cluster_entirely() {
        // 90 cells: too narrow for the full cluster — and there's
        // no compact stage anymore. User preference (2026-06-22):
        // full-or-hidden, no intermediate. TABS / + / theme / × all
        // disappear in one drop.
        let row = render_palette_bar_row(90, 3);
        assert!(
            !row.contains("TABS"),
            "TABS label should be hidden at width 90: {row:?}"
        );
        assert!(
            !row.contains(" 1 "),
            "numbered tab chip ' 1 ' should be hidden at width 90: {row:?}"
        );
    }

    /// Regression: the bufferline used to clear `launcher_icon_rects`
    /// + the cluster chip rects every frame, but no longer paints
    /// them — the palette bar does. The clears wiped the click
    /// targets the palette bar just registered, so the chips
    /// rendered but were unclickable. This test runs the FULL
    /// `draw` (not just palette_bar) at a width wide enough for
    /// every chip and asserts the click rects survive afterward.
    #[test]
    fn full_draw_keeps_cluster_click_rects_registered() {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        let mut cfg = Config::default();
        // Seed a launcher icon so we can verify launcher_icon_rects
        // gets populated (and survives the full draw).
        cfg.ui.launcher_icons.push(crate::config::LauncherIcon {
            id: "test_launcher".to_string(),
            glyph: "\u{F0E58}".to_string(),
            fallback: "C".to_string(),
            command: ":noop".to_string(),
            color: "orange".to_string(),
            tooltip: Some("test launcher".to_string()),
        });
        let mut app = App::new(ws, cfg).unwrap();
        let mut term = Terminal::new(TestBackend::new(200, 30)).unwrap();
        term.draw(|f| draw(f, &mut app)).unwrap();

        // After a full draw, every cluster chip's rect must still
        // be registered — confirming the bufferline-clears-after-
        // palette-paint bug doesn't reappear.
        assert!(
            !app.rects.launcher_icon_rects.is_empty(),
            "launcher_icon_rects empty post-draw: cluster rects must be registered \
             (bufferline_visible={})",
            app.bufferline_visible,
        );
        assert!(
            app.rects.bufferline_new_tab_button.is_some(),
            "new tab button rect missing post-draw"
        );
        assert!(
            app.rects.bufferline_theme_toggle.is_some(),
            "theme toggle rect missing post-draw"
        );
        assert!(
            app.rects.bufferline_window_close.is_some(),
            "window close rect missing post-draw"
        );
    }

    #[test]
    fn palette_bar_extra_narrow_hides_cluster_entirely() {
        // 82 cells: even compact doesn't fit past the workspace
        // chip — cluster should vanish completely (still above
        // the 80-col palette-bar-visible cutoff).
        let row = render_palette_bar_row(82, 3);
        assert!(
            !row.contains("TABS"),
            "TABS must be hidden: {row:?}"
        );
        // No tab chip
        assert!(!row.contains(" 1 "), "no tab chip allowed: {row:?}");
    }

    /// 2026-06-22 — full integration test: simulate the events
    /// crossterm would dispatch during a tree-file drag and
    /// verify the ghost + drop overlay paint at every stage.
    /// This covers what terminals (Apple Terminal, iTerm, Ghostty,
    /// kitty) should produce when the user drags a file from the
    /// tree to a pane. Catches regressions where:
    ///   - mouse-Moved without held-button is the only mid-drag
    ///     event (some terminals report it this way)
    ///   - tree_drag isn't being set on mouse-down on tree row
    ///   - ghost / overlay paint code paths regress
    #[test]
    fn full_drag_flow_paints_ghost_and_overlay() {
        use ratatui::crossterm::event::{
            KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
        };
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        std::fs::write(ws.join("a.txt"), "alpha").unwrap();
        std::fs::write(ws.join("b.txt"), "beta").unwrap();
        let mut app = App::new(ws.clone(), Config::default()).unwrap();
        // Open a.txt so there's a pane body to drop onto.
        app.open_path(&ws.join("a.txt"));
        let mut term = Terminal::new(TestBackend::new(120, 30)).unwrap();
        term.draw(|f| draw(f, &mut app)).unwrap();

        // Find a tree row for b.txt — pick the row + col that the
        // click handler would resolve. Compute the screen row for
        // a b.txt entry by walking the visible tree.
        let tree_rect = app
            .rects
            .tree
            .expect("tree should render with a workspace open");
        let visible_rows = app.tree.visible_rows();
        let b_idx = visible_rows
            .iter()
            .position(|r| r.path.file_name().is_some_and(|n| n == "b.txt"))
            .unwrap_or_else(|| {
                panic!(
                    "b.txt not in visible_rows; rows={:?}",
                    visible_rows
                        .iter()
                        .map(|r| r.path.file_name().map(|n| n.to_string_lossy().into_owned()))
                        .collect::<Vec<_>>()
                )
            });
        let click_x = tree_rect.x + tree_rect.width / 2;
        let click_y = tree_rect.y + (b_idx as u16);

        // === STAGE 1: mouse-down on tree row → begin_tree_drag ===
        crate::tui::dispatch_mouse(
            &mut app,
            MouseEvent {
                kind: MouseEventKind::Down(MouseButton::Left),
                column: click_x,
                row: click_y,
                modifiers: KeyModifiers::empty(),
            },
        );
        assert!(
            app.tree_drag.is_some(),
            "tree_drag should be Some after mouse-down on tree row (tree_rect={:?}, click=({},{}))",
            tree_rect,
            click_x,
            click_y
        );

        // === STAGE 2: cursor moves into a pane body ===
        // Terminals can deliver this as either Drag(Left) or
        // Moved depending on platform / capture mode. Test both.
        let body_rect = app
            .rects
            .pane_bodies
            .first()
            .map(|(r, _)| *r)
            .expect("expected at least one pane body");
        let move_x = body_rect.x + body_rect.width / 2;
        let move_y = body_rect.y + body_rect.height / 2;

        // First with Moved (the case other terminals sometimes
        // send during a drag).
        crate::tui::dispatch_mouse(
            &mut app,
            MouseEvent {
                kind: MouseEventKind::Moved,
                column: move_x,
                row: move_y,
                modifiers: KeyModifiers::empty(),
            },
        );
        assert!(
            app.tree_drag
                .as_ref()
                .map(|d| d.armed)
                .unwrap_or(false),
            "tree_drag should arm on cursor motion during drag (Moved event)"
        );
        assert!(
            app.rects.tab_drop_target.is_some(),
            "tab_drop_target should be set when cursor is over a pane body during a tree drag"
        );

        // === STAGE 3: render — ghost + overlay must be on screen ===
        term.draw(|f| draw(f, &mut app)).unwrap();
        let buf = term.backend().buffer();
        let screen: String = (0..buf.area.height)
            .map(|y| {
                let row: String = (0..buf.area.width)
                    .map(|x| buf[(x, y)].symbol())
                    .collect();
                row + "\n"
            })
            .collect();
        assert!(
            screen.contains("b.txt"),
            "drag ghost chip should render 'b.txt' on screen.\n{}",
            screen
        );
        // 2026-06-22 — overlay redesigned to be label-less (a
        // translucent gray over the active zone). Verify the
        // drop target is registered instead.
        assert!(
            app.rects.tab_drop_target.is_some(),
            "drag flow should register a tab_drop_target.\n{}",
            screen
        );

        // === STAGE 4: mouse-up over pane → drop succeeds ===
        let initial_layouts: Vec<_> = app.layouts.iter().map(|l| l.clone()).collect();
        let _ = initial_layouts;
        crate::tui::dispatch_mouse(
            &mut app,
            MouseEvent {
                kind: MouseEventKind::Up(MouseButton::Left),
                column: move_x,
                row: move_y,
                modifiers: KeyModifiers::empty(),
            },
        );
        assert!(
            app.tree_drag.is_none(),
            "tree_drag should clear on mouse-up"
        );
        // The release dropped b.txt onto a.txt's pane → either a
        // split or center-move (depends on which zone the click
        // landed in). Either way, b.txt is now a buffer.
        let pane_paths: Vec<_> = app
            .panes
            .iter()
            .filter_map(|p| match p {
                crate::pane::Pane::Editor(b) => b.path.clone(),
                _ => None,
            })
            .collect();
        let b_open = pane_paths
            .iter()
            .any(|p| p.file_name().is_some_and(|n| n == "b.txt"));
        assert!(
            b_open,
            "after drop, b.txt should be open as a Pane::Editor. \
             panes: {:?}",
            pane_paths
        );
    }

    /// 2026-06-22 — verify the drop overlay paints when a tree
    /// drag is over a pane body.
    #[test]
    fn drop_overlay_paints_when_over_pane() {
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        std::fs::write(ws.join("a.txt"), "alpha").unwrap();
        std::fs::write(ws.join("b.txt"), "beta").unwrap();
        let mut app = App::new(ws.clone(), Config::default()).unwrap();
        // Open a file so there's a pane body to drop on.
        app.open_path(&ws.join("a.txt"));
        // Render once to populate pane_bodies.
        let mut term = Terminal::new(TestBackend::new(120, 30)).unwrap();
        term.draw(|f| draw(f, &mut app)).unwrap();
        // Now simulate: drag from tree (e.g. b.txt) over the pane.
        // Pick a coord that's inside the pane body.
        let body_rect = app
            .rects
            .pane_bodies
            .first()
            .map(|(r, _)| *r)
            .expect("expected at least one pane body");
        let center_x = body_rect.x + body_rect.width / 2;
        let center_y = body_rect.y + body_rect.height / 2;
        app.begin_tree_drag(ws.join("b.txt"), false, 10);
        app.set_tree_drag_cursor(center_x, center_y);
        app.update_tab_drop_target(center_x, center_y);
        assert!(
            app.rects.tab_drop_target.is_some(),
            "drop target should be set when cursor is over a pane body"
        );
        term.draw(|f| draw(f, &mut app)).unwrap();
        let buf = term.backend().buffer();
        let screen: String = (0..buf.area.height)
            .map(|y| {
                let row: String = (0..buf.area.width)
                    .map(|x| buf[(x, y)].symbol())
                    .collect();
                row + "\n"
            })
            .collect();
        assert!(
            app.rects.tab_drop_target.is_some(),
            "drop overlay should register a tab_drop_target.\n\
             screen:\n{}",
            screen
        );
    }

    /// 2026-06-22 — verify the drag ghost actually paints during
    /// a tree drag. User-reported: no visible ghost during drag.
    /// This test simulates the drag (mouse-down on tree, then
    /// move) and asserts the ghost chip text appears on screen.
    #[test]
    fn drag_ghost_paints_during_armed_drag() {
        use std::path::PathBuf;
        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        std::fs::write(ws.join("dragme.txt"), "drag me").unwrap();
        let mut app = App::new(ws.clone(), Config::default()).unwrap();
        // Start a tree drag from row y=10 (simulating mouse-down on
        // the tree row), then move the cursor to (50, 20) — past
        // the tree, onto a pane area.
        app.begin_tree_drag(ws.join("dragme.txt"), false, 10);
        app.set_tree_drag_cursor(50, 20);
        assert!(
            app.tree_drag.as_ref().unwrap().armed,
            "drag should arm on cursor motion past origin"
        );
        let mut term = Terminal::new(TestBackend::new(120, 30)).unwrap();
        term.draw(|f| draw(f, &mut app)).unwrap();
        let buf = term.backend().buffer();
        // The ghost chip should contain the filename "dragme.txt"
        // somewhere on screen. Scan all rows.
        let screen: String = (0..buf.area.height)
            .map(|y| {
                let row: String = (0..buf.area.width)
                    .map(|x| buf[(x, y)].symbol())
                    .collect();
                row + "\n"
            })
            .collect();
        assert!(
            screen.contains("dragme.txt"),
            "drag ghost chip should render 'dragme.txt' on screen but didn't.\n\
             Cursor: ({}, {}) armed: {} screen:\n{}",
            app.tree_drag.as_ref().unwrap().cursor_x,
            app.tree_drag.as_ref().unwrap().cursor_y,
            app.tree_drag.as_ref().unwrap().armed,
            screen
        );
    }
}
