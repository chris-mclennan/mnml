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
// Azure DevOps views moved to mnml-forge-azdevops.
pub mod blit_host_view;
pub mod browser_view;
pub mod bufferline;
pub mod cheatsheet_view;
pub mod close_prompt;
pub mod cmdline_bar;
pub mod cmdline_history_view;
// codebuilds_view moved to mnml-aws-codebuild.
pub mod completion;
pub mod context_menu;
pub mod dap_repl_view;
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
// log_tail_view moved to mnml-aws-codebuild.
pub mod md_inline_overlay;
pub mod md_preview;
pub mod mixr_view;
pub mod outline_view;
pub mod picker;
// pipeline_log_view removed after 2026-06 SCM split.
pub mod prompt;
pub mod pty_view;
pub mod rename_preview_overlay;
pub mod request_view;
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
use ratatui::text::Span;
use ratatui::widgets::{Block, Paragraph};

use crate::app::App;
use crate::focus::Focus;
use crate::layout::{Layout, SplitDir, split_rects};

pub fn draw(frame: &mut Frame, app: &mut App) {
    // Reset the per-frame cursor capture — populated below whenever this
    // draw calls `set_cursor_position`. Blit reads it to gate
    // `cursor_visible` on the wire, suppressing the stale-(0,0) flash that
    // tmnl would otherwise paint before mnml has shown anything.
    app.rects.drawn_cursor_pos = None;
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
        app.rects.split_dividers.clear();
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
            app.rects.drawn_cursor_pos = Some((x, y));
        } else if app.focus == Focus::Pane
            && let Some((x, y)) = cursor_pos
        {
            frame.set_cursor_position((x, y));
            app.rects.drawn_cursor_pos = Some((x, y));
        }
        return;
    }

    // Split off the bottom statusline + cmdline bar (each 1 row, full width).
    // Cmdline bar sits BELOW the statusline (vim/neovim convention: the
    // statusline shows steady state, the cmdline below it shows the live `:`
    // line + transient echo messages). The top row is a 1-row palette bar
    // (VS Code-style centered "search files, run commands…" chip) — visible
    // when the window is wide enough AND we're not under tmnl. Under tmnl,
    // the host renders the palette chip directly in its native chrome
    // strip (next to the macOS traffic lights), so the inline bar would
    // be duplicate chrome.
    let palette_bar_visible = area.width >= 80 && !app.under_tmnl;
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
        // The rail's rightmost cell column is the resize handle.
        app.rects.tree_edge = Some(Rect {
            x: cols[0].x + cols[0].width.saturating_sub(1),
            y: cols[0].y,
            width: 1,
            height: cols[0].height,
        });
        (Some(cols[0]), cols[1])
    } else {
        app.rects.tree_edge = None;
        (None, upper)
    };

    // right column: optionally a 1-row bufferline above the body.
    // `app.bufferline_visible = false` ⇒ skip the strip; the body grows.
    let (bufferline_area, body_area) = if app.bufferline_visible {
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
                draw_git_section_content(frame, app, content_area);
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
    let mut mixr_area: Option<Rect> = None;
    let mut mixr_header: Option<Rect> = None;
    if let Some(size) = app.mixr_panel.as_ref().map(|p| p.size) {
        use crate::mixr_host::MixrSize;
        let panel: Option<Rect> = match size {
            MixrSize::Minimized => None,
            MixrSize::BottomStrip => {
                let h = crate::mixr_host::STRIP_ROWS.min(body_area.height);
                let w = body_area.width.min(crate::mixr_host::MAX_WIDTH);
                (w >= 20 && h >= 6).then_some(Rect {
                    x: body_area.x,
                    y: body_area.y + body_area.height - h,
                    width: w,
                    height: h,
                })
            }
            MixrSize::Full => {
                let w = body_area.width.min(crate::mixr_host::MAX_WIDTH);
                (w >= 20 && body_area.height >= 6).then_some(Rect {
                    x: body_area.x,
                    y: body_area.y,
                    width: w,
                    height: body_area.height,
                })
            }
            MixrSize::Floating => {
                // The free window — `panel.float`, clamped into the body.
                let f = app
                    .mixr_panel
                    .as_ref()
                    .map(|p| p.float)
                    .unwrap_or(body_area);
                let w = f.width.clamp(24, body_area.width.max(24));
                let h = f.height.clamp(8, body_area.height.max(8));
                let x =
                    f.x.clamp(body_area.x, body_area.x + body_area.width.saturating_sub(w));
                let y = f.y.clamp(
                    body_area.y,
                    body_area.y + body_area.height.saturating_sub(h),
                );
                (w >= 20 && h >= 6).then_some(Rect {
                    x,
                    y,
                    width: w,
                    height: h,
                })
            }
        };
        if let Some(panel) = panel {
            // Split: 1-row title header + mixr cells below.
            mixr_header = Some(Rect { height: 1, ..panel });
            mixr_area = Some(Rect {
                x: panel.x,
                y: panel.y + 1,
                width: panel.width,
                height: panel.height.saturating_sub(1),
            });
        }
    }
    app.rects.mixr_panel = mixr_area;
    app.rects.mixr_panel_header = mixr_header;
    app.rects.body = Some(body_area);
    app.rects.editor_panes.clear();
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
    app.rects.split_dividers.clear();
    app.rects.pty_tabs.clear();
    app.rects.pty_tab_new.clear();
    app.rects.pty_tab_close.clear();
    let layout = app.layout().clone();
    let cursor_pos: Option<(u16, u16)> = if matches!(layout, Layout::Empty) {
        welcome::draw(frame, app, body_area);
        None
    } else {
        let mut path = Vec::new();
        render_layout(frame, app, &layout, body_area, &mut path)
    };

    // Scratch terminal strip — paints below the body. Resizes the pty
    // so the shell knows about the new viewport.
    if let Some(strip) = scratch_strip
        && app.scratch_term.is_some()
    {
        scratch_term_view::draw(frame, app, strip);
    }

    // Native mixr panel — the 1-row title header, then mixr's cells.
    if let Some(harea) = mixr_header {
        mixr_view::draw_header(frame, harea);
    }
    if let Some(marea) = mixr_area
        && let Some(panel) = app.mixr_panel.as_ref()
    {
        mixr_view::draw(frame, panel, marea);
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
    // Help overlay — `?` / view.help (auto-generated keymap reference).
    help_overlay::draw(frame, app, area);
    // Startup picker — drawn last among modal overlays so it sits on
    // top of welcome/about/etc. when launched from the .app.
    startup_picker::draw(frame, app, area);
    // …and the flash highlight paints last so it can sit on top of even
    // the discovery panel (if the user picks a category whose rect lies
    // beneath the panel, the highlight will still flash through).
    discovery::draw_flash(frame, app, area);

    // ── terminal cursor ──
    // An overlay's text caret (picker query, prompt input) wins when it's open;
    // otherwise the editor caret when the editor pane has focus and no overlay is
    // up; otherwise nothing.
    if let Some((x, y)) = app.rects.prompt_caret.or(app.rects.picker_caret) {
        frame.set_cursor_position((x, y));
        app.rects.drawn_cursor_pos = Some((x, y));
    } else if app.focus == Focus::Pane
        && app.whichkey.is_none()
        && app.close_prompt.is_none()
        && app.prompt.is_none()
        && let Some((x, y)) = cursor_pos
    {
        frame.set_cursor_position((x, y));
        app.rects.drawn_cursor_pos = Some((x, y));
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
        Layout::Leaf(id) => {
            let focused = app.active == Some(*id);
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
                Some(crate::pane::Pane::BlitHost(_)) => 33,
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
                33 => blit_host_view::draw(frame, app, *id, area, focused),
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

    let back_glyph = if ascii { "<" } else { "\u{EA9B}" }; // codicon: arrow-left
    let fwd_glyph = if ascii { ">" } else { "\u{EA9C}" }; // codicon: arrow-right
    let magnify = if ascii { "?" } else { "\u{F0349}" };
    // `\u{EAB4}` is the real codicon `chevron-down` in Nerd Fonts.
    // `\u{EAA1}` (the obvious-looking choice) renders as chevron-UP in
    // this font — same bug we hit on the tmnl chrome chip; this is the
    // matching fix for mnml's inline palette bar.
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
    // arrows still read as glyphs but visually recede. (Previous
    // attempt used `comment`/`bg2` to mirror the tmnl chrome chip,
    // but `bg2` matched the chip background and made the arrows
    // disappear entirely on some themes — `comment` is the floor.)
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
    // Mirrors tmnl chrome's BTN_BG (~0.13) vs CHIP_BG (~0.18).
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
/// `:ex` / `tmnl:host_id`).
/// Result of probing whether the binary backing an integration's
/// command is actually on the user's PATH. Today only the
/// `:host.launch <binary>` shape is probed; mnml-internal commands
/// (no prefix) and tmnl host commands (`tmnl:<id>`) are assumed
/// available because they don't shell out.
enum IntegrationAvailability {
    Available,
    /// Binary name (just the leaf, no path) the user would need to
    /// install. Surfaced as `(<bin> not installed)` next to the row.
    Missing(String),
}

/// Walk the `command` string from an `IntegrationIcon` and decide
/// whether the underlying tool is installed. Only `:host.launch
/// <binary>` is probed via `which`; everything else returns
/// `Available`. Cheap enough to call per-frame for a small fixed
/// set of icons (~6 by default), but the call site only renders this
/// section when the Integrations activity-bar icon is active so the
/// PATH lookups are gated behind a click anyway.
fn integration_availability(command: &str) -> IntegrationAvailability {
    let Some(rest) = command.strip_prefix(":host.launch ") else {
        return IntegrationAvailability::Available;
    };
    let bin = rest.split_whitespace().next().unwrap_or("").to_string();
    if bin.is_empty() {
        return IntegrationAvailability::Available;
    }
    let installed = std::process::Command::new("/usr/bin/which")
        .arg(&bin)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if installed {
        IntegrationAvailability::Available
    } else {
        IntegrationAvailability::Missing(bin)
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
        // Probe availability for `:host.launch <binary>` commands —
        // a stale or missing binary is the only "broken" state worth
        // surfacing at v1. Internal `mnml` commands (no prefix) and
        // tmnl host-runs (`tmnl:`) are always assumed available.
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
        // (palette command / `:ex` / `tmnl:` prefix handling).
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
