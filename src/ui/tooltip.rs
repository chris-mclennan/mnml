//! Hover-tooltip overlay — a small floating label rendered above (or below) the
//! currently-hovered clickable chip, ~500ms after the mouse settles on it. Closes
//! the discoverability loop: lets users learn what each chip does without trial-
//! and-error or memorizing the README.
//!
//! `App.hover_chip` carries `(HoverChip, Instant)`; `tui::dispatch_mouse` updates
//! it on every `MouseEventKind::Moved`. This module reads it and paints if the
//! delay has elapsed.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::Line;
use ratatui::widgets::{Block, Borders, Clear, Paragraph};

use crate::HoverChip;
use crate::app::{App, HOVER_TOOLTIP_DELAY_MS};
use crate::ui::theme;

/// Render the tooltip overlay if a chip has been stably hovered for at least
/// `HOVER_TOOLTIP_DELAY_MS`. Called after every other UI layer so the popup
/// sits on top.
pub fn draw(frame: &mut Frame, app: &App, screen: Rect) {
    let Some((chip, since)) = app.hover_chip else {
        return;
    };
    if since.elapsed().as_millis() < HOVER_TOOLTIP_DELAY_MS as u128 {
        return;
    }
    let Some((anchor, label, sublabel)) = describe(chip, app) else {
        return;
    };
    // Compose the label as up to two lines: primary action + secondary (right-
    // click) hint. Width = max line + 2 (padding) + 2 (borders).
    let prim_w = label.chars().count();
    let sub_w = sublabel.as_deref().map(|s| s.chars().count()).unwrap_or(0);
    let inner_w = prim_w.max(sub_w) as u16;
    let w = inner_w + 4; // 2 padding + 2 borders
    let h: u16 = if sublabel.is_some() { 4 } else { 3 };
    // Anchor: place above the chip when there's room; else below.
    let want_y = anchor.y.saturating_sub(h);
    let y = if anchor.y >= h {
        want_y
    } else {
        (anchor.y + 1).min(screen.height.saturating_sub(h))
    };
    let x = anchor.x.min(screen.width.saturating_sub(w)).max(screen.x);
    let area = Rect {
        x,
        y: y.max(screen.y),
        width: w.min(screen.width),
        height: h.min(screen.height),
    };
    let t = theme::cur();
    frame.render_widget(Clear, area);
    let mut lines: Vec<Line<'static>> = Vec::new();
    lines.push(Line::styled(
        format!(" {label} "),
        Style::default()
            .fg(t.bg_darker)
            .bg(t.yellow)
            .add_modifier(Modifier::BOLD),
    ));
    if let Some(s) = sublabel {
        lines.push(Line::styled(
            format!(" {s} "),
            Style::default().fg(t.comment).bg(t.bg2),
        ));
    }
    let block = Block::default()
        .borders(Borders::ALL)
        .style(Style::default().fg(t.comment).bg(t.bg2));
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

/// `(anchor_rect, primary_line, secondary_line)`. None ⇒ chip's rect isn't
/// registered this frame (chip is hidden, terminal too narrow, etc.) — bail.
fn describe(chip: HoverChip, app: &App) -> Option<(Rect, String, Option<String>)> {
    match chip {
        HoverChip::StatuslineMode => {
            // Mode chip color encodes the editing mode — name it in the
            // tooltip so users learn the palette without trial and error.
            let mode_desc = match app.editing_mode() {
                crate::input::EditingMode::Insert => "green = INSERT",
                crate::input::EditingMode::Replace => "orange = REPLACE",
                crate::input::EditingMode::Visual => "purple = VISUAL",
                crate::input::EditingMode::VisualLine => "purple = V-LINE",
                crate::input::EditingMode::VisualBlock => "purple = V-BLOCK",
                crate::input::EditingMode::Normal => "red = NORMAL",
                crate::input::EditingMode::None => match app.focus {
                    crate::focus::Focus::Tree => "blue = TREE focus",
                    crate::focus::Focus::Pane => "green = EDIT (cyan = read-only)",
                },
            };
            Some((
                app.rects.statusline_mode_chip?,
                format!("click: toggle vim ⇄ standard · {mode_desc}"),
                Some("right-click: input-style menu".into()),
            ))
        }
        HoverChip::StatuslineBranch => {
            // Branch chip carries the git counts; explain the glyphs.
            let g = app.git.snapshot();
            let mut extra: Vec<&'static str> = Vec::new();
            if g.added > 0 {
                extra.push("+ added");
            }
            if g.changed > 0 {
                extra.push("● changed");
            }
            if g.removed > 0 {
                extra.push("- removed");
            }
            if g.conflicts > 0 {
                extra.push("⚠ conflicts");
            }
            if g.ahead > 0 {
                extra.push("⇡ ahead");
            }
            if g.behind > 0 {
                extra.push("⇣ behind");
            }
            let label = if extra.is_empty() {
                "click: open commit graph".to_string()
            } else {
                format!("click: graph · {}", extra.join(" "))
            };
            Some((
                app.rects.statusline_branch_chip?,
                label,
                Some("right-click: git ops menu".into()),
            ))
        }
        HoverChip::StatuslineWorkspace => {
            let primary = if app.repos.len() > 1 {
                "click: switch repo"
            } else {
                "click: repo / worktree menu"
            };
            Some((
                app.rects.statusline_workspace_chip?,
                primary.into(),
                Some("right-click: workspace menu".into()),
            ))
        }
        HoverChip::StatuslineClock => Some((
            app.rects.statusline_clock_chip?,
            "click: local ⇄ UTC".into(),
            Some("right-click: clock menu".into()),
        )),
        HoverChip::StatuslineLsp => Some((
            app.rects.statusline_lsp_chip?,
            "click: :LspStatus (running servers)".into(),
            None,
        )),
        HoverChip::StatuslineWrap => Some((
            app.rects.statusline_wrap_chip?,
            "click: toggle word wrap".into(),
            None,
        )),
        HoverChip::StatuslineAutosave => Some((
            app.rects.statusline_autosave_chip?,
            "click: show autosave config".into(),
            None,
        )),
        HoverChip::StatuslineFilesize => Some((
            app.rects.statusline_filesize_chip?,
            "click: :Stat (file metadata)".into(),
            None,
        )),
        HoverChip::StatuslineLnCol => Some((
            app.rects.statusline_lncol_chip?,
            "click: goto line".into(),
            None,
        )),
        HoverChip::LauncherIcon(idx) => {
            let icon = app.config.ui.launcher_icons.get(idx)?;
            let &(rect, _) = app
                .rects
                .launcher_icon_rects
                .iter()
                .find(|(_, i)| *i == idx)?;
            let label = icon
                .tooltip
                .clone()
                .unwrap_or_else(|| format!("click: {}", icon.command));
            Some((rect, label, None))
        }
        HoverChip::IntegrationIcon(idx) => {
            let icon = app.config.ui.integration_icons.get(idx)?;
            let &(rect, _) = app
                .rects
                .integration_icon_rects
                .iter()
                .find(|(_, i)| *i == idx)?;
            let label = icon
                .tooltip
                .clone()
                .unwrap_or_else(|| format!("click: {}", icon.command));
            Some((rect, label, None))
        }
        HoverChip::WorkspaceHeader => {
            let rect = app.rects.tree_toggle?;
            Some((rect, app.workspace.display().to_string(), None))
        }
        HoverChip::ExtraWorkspaceHeader(idx) => {
            let rect = app
                .rects
                .extra_workspace_toggles
                .iter()
                .find(|(_, i)| *i == idx)
                .map(|(r, _)| *r)?;
            let path = app.extra_workspaces.get(idx)?.root.display().to_string();
            Some((rect, path, None))
        }
        HoverChip::TreeIcon(cmd_id) => {
            let &(rect, _) = app
                .rects
                .tree_icon_buttons
                .iter()
                .find(|(_, id)| *id == cmd_id)?;
            let label: std::borrow::Cow<'static, str> = match cmd_id {
                "view.add_workspace" => "add workspace folder".into(),
                "file.new" => "new file".into(),
                "file.new_folder" => "new folder".into(),
                "tree.refresh" => "refresh tree".into(),
                "tree.collapse_all" => "collapse all".into(),
                "tree.toggle_collapse_all" => {
                    if app.tree.is_fully_collapsed() {
                        "expand all".into()
                    } else {
                        "collapse all".into()
                    }
                }
                "picker.files" => "search files".into(),
                "integrations.add" => "add integration".into(),
                other => other.into(),
            };
            Some((rect, label.into_owned(), None))
        }
        HoverChip::ActivityBarIcon(section) => {
            let &(rect, _) = app
                .rects
                .activity_bar_icons
                .iter()
                .find(|(_, s)| *s == section)?;
            let (_, _, label, _) = section.meta();
            Some((rect, label.to_string(), None))
        }
        HoverChip::StatuslineNowPlaying => {
            let rect = app.rects.statusline_mixr_chip?;
            let np = app.now_playing.as_ref()?;
            let track = if np.track.is_empty() {
                "(no track)".to_string()
            } else {
                np.track.clone()
            };
            let source = if np.source.is_empty() {
                "now playing".to_string()
            } else {
                np.source.clone()
            };
            Some((rect, format!("{source}: {track}"), None))
        }
        HoverChip::PaletteBackButton => {
            let rect = app.rects.palette_back_button?;
            Some((rect, "previous buffer".to_string(), None))
        }
        HoverChip::PaletteForwardButton => {
            let rect = app.rects.palette_forward_button?;
            Some((rect, "next buffer".to_string(), None))
        }
        HoverChip::PaletteDropdownButton => {
            let rect = app.rects.palette_dropdown_button?;
            Some((rect, "recent files".to_string(), None))
        }
        HoverChip::RailHeaderChip(action) => {
            let rect = app
                .rects
                .rail_git_header_buttons
                .iter()
                .find(|(_, a)| *a == action)
                .map(|(r, _)| *r)?;
            let label = match action {
                crate::GitRailHeaderAction::Fetch => "fetch",
                crate::GitRailHeaderAction::Pull => "pull",
                crate::GitRailHeaderAction::Push => "push",
                crate::GitRailHeaderAction::StageAll => "stage all changes",
                crate::GitRailHeaderAction::Commit => "commit…",
                crate::GitRailHeaderAction::Graph => "open commit graph",
            };
            Some((rect, label.into(), None))
        }
        HoverChip::BufferlineNewTab => {
            let rect = app.rects.bufferline_new_tab_button?;
            Some((
                rect,
                "new tab".into(),
                Some("click: open a new scratch buffer".into()),
            ))
        }
        HoverChip::BufferlineThemeToggle => {
            let rect = app.rects.bufferline_theme_toggle?;
            let cur = app.config.ui.theme.as_str();
            Some((
                rect,
                format!("theme: {cur}"),
                Some("click: toggle between configured themes".into()),
            ))
        }
        HoverChip::BufferlineWindowClose => {
            let rect = app.rects.bufferline_window_close?;
            Some((rect, "quit mnml".into(), Some("click: app.quit".into())))
        }
        HoverChip::BufferlineTabClose(pid) => {
            let rect = app
                .rects
                .bufferline_tab_close
                .iter()
                .find(|(_, p)| *p == pid)
                .map(|(r, _)| *r)?;
            // Dirty editors show `●` instead of `×`. Mention what a
            // click would actually do — the close behavior is the
            // same in both cases today (dirty triggers an unsaved-
            // changes confirmation), so the tooltip is informational
            // either way.
            use crate::pane::Pane;
            let is_dirty = matches!(app.panes.get(pid), Some(Pane::Editor(b)) if b.dirty);
            let label = if is_dirty {
                "unsaved changes"
            } else {
                "close tab"
            };
            Some((
                rect,
                label.into(),
                Some(
                    "click: close (prompts on unsaved) · use the tab right-click menu to Save"
                        .into(),
                ),
            ))
        }
        HoverChip::BufferlineTab(pid) => {
            let rect = app
                .rects
                .bufferline_tabs
                .iter()
                .find(|(_, p)| *p == pid)
                .map(|(r, _)| *r)?;
            // For editor panes, prefer the workspace-relative path so the
            // tooltip is the full file location. Fall back to the pane's
            // generic title for non-editor panes (Git status / Browser / …).
            use crate::pane::Pane;
            let label = match app.panes.get(pid) {
                Some(Pane::Editor(b)) => match &b.path {
                    Some(p) => {
                        let rel = p
                            .strip_prefix(&app.workspace)
                            .unwrap_or(p)
                            .to_string_lossy()
                            .into_owned();
                        if b.dirty { format!("{rel}  ●") } else { rel }
                    }
                    None => b.display_name().to_string(),
                },
                Some(p) => p.title(),
                None => "tab".into(),
            };
            Some((
                rect,
                label,
                Some("click: focus · middle: close · right: menu".into()),
            ))
        }
        HoverChip::DiffToolbar(action) => {
            let rect = app
                .rects
                .diff_toolbar_buttons
                .iter()
                .find(|(_, _, a)| *a == action)
                .map(|(r, _, _)| *r)?;
            let label = match action {
                crate::DiffToolbarAction::ViewInline => "view: inline (whole file)",
                crate::DiffToolbarAction::ViewHunk => "view: hunks (focused)",
                crate::DiffToolbarAction::ViewSplit => "view: split (side-by-side)",
                crate::DiffToolbarAction::ToggleWrap => "toggle word wrap",
                crate::DiffToolbarAction::Close => "close diff",
            };
            Some((rect, label.into(), None))
        }
        HoverChip::FoldChip => {
            // Tooltip anchors above the first fold chip the cursor is over.
            // Mouse is over a fold chip so at least one is hovered — find
            // the first rect that matches.
            let rect = app.rects.fold_chips.first().map(|(r, _, _)| *r)?;
            Some((rect, "click: unfold this block".into(), None))
        }
        HoverChip::CodeLensChip => {
            let rect = app.rects.code_lens_chips.first().map(|(r, _, _)| *r)?;
            Some((rect, "click: run code lens".into(), None))
        }
    }
}
