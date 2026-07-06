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
use ratatui::widgets::{Clear, Paragraph};

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
    // Tooltip uses the shared menu chrome (square border, default fg,
    // bg2 fill) — matches the menu bar / right-click menu aesthetic
    // the user preferred. Two lines when a subtitle is present.
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
    // Primary line: bold fg text on the menu bg (bg2). No yellow chip
    // — matches menu bar / right-click menu label style.
    lines.push(Line::styled(
        format!(" {label} "),
        Style::default()
            .fg(t.fg)
            .bg(t.bg2)
            .add_modifier(Modifier::BOLD),
    ));
    if let Some(s) = sublabel {
        lines.push(Line::styled(
            format!(" {s} "),
            Style::default().fg(t.comment).bg(t.bg2),
        ));
    }
    let block = crate::ui::design_tokens::popup_menu("");
    frame.render_widget(Paragraph::new(lines).block(block), area);
}

/// `(anchor_rect, primary_line, secondary_line)`. None ⇒ chip's rect isn't
/// registered this frame (chip is hidden, terminal too narrow, etc.) — bail.
fn describe(chip: HoverChip, app: &App) -> Option<(Rect, String, Option<String>)> {
    match chip {
        HoverChip::StatuslineMode => {
            // code-reviewer S1-1 — variant-match moved to the
            // enum's tooltip_label() method so the UI layer doesn't
            // branch on input mode (spine rule). Tree-focus is a
            // focus state, not a mode — checked via the focus side.
            let mode_desc = if matches!(app.focus, crate::focus::Focus::Tree)
                && app.editing_mode().label().is_none()
            {
                "blue = TREE focus"
            } else {
                app.editing_mode().tooltip_label()
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
        HoverChip::GitGraphCommitMsg {
            pane_id,
            commit_idx,
        } => {
            let rect = app
                .rects
                .git_graph_subject_cells
                .iter()
                .find(|(_, pid, ci)| *pid == pane_id && *ci == commit_idx)
                .map(|(r, _, _)| *r)?;
            let g = match app.panes.get(pane_id) {
                Some(crate::pane::Pane::GitGraph(g)) => g,
                _ => return None,
            };
            let c = g.commits.get(commit_idx)?;
            let subj = c.subject.clone();
            // Wrap long subjects at ~80 chars for readability.
            let display = if subj.chars().count() > 80 {
                subj.chars().take(80).collect::<String>() + "…"
            } else {
                subj
            };
            let hint = format!("{} · {}", c.author, c.short);
            Some((rect, display, Some(hint)))
        }
        HoverChip::GitGraphLane {
            pane_id,
            commit_idx,
            lane_idx,
        } => {
            // qa-feature 2026-06-30 — walk newer commits (lower
            // commit_idx) in the same lane until we find one with
            // a branch ref, then use that ref name as the lane
            // label. Falls back to a subject preview if nothing
            // named is found. `rect` is the specific lane cell.
            let rect = app
                .rects
                .git_graph_lane_cells
                .iter()
                .find(|(_, pid, ci, li)| *pid == pane_id && *ci == commit_idx && *li == lane_idx)
                .map(|(r, _, _, _)| *r)?;
            let g = match app.panes.get(pane_id) {
                Some(crate::pane::Pane::GitGraph(g)) => g,
                _ => return None,
            };
            // Walk from `commit_idx` upward (i.e. toward index 0
            // = newest) inside the same lane. Include the anchor
            // commit itself first.
            let mut label = None;
            let mut idx = commit_idx;
            while idx < g.commits.len() {
                let c = &g.commits[idx];
                let in_lane = c.graph.get(lane_idx).is_some_and(|cell| cell.ch != ' ');
                if !in_lane {
                    break;
                }
                if let Some(r) = c.refs.iter().find(|r| {
                    matches!(
                        r.kind,
                        crate::git::log::RefKind::LocalBranch
                            | crate::git::log::RefKind::RemoteBranch
                            | crate::git::log::RefKind::Head
                    )
                }) {
                    label = Some(r.name.clone());
                    break;
                }
                if idx == 0 {
                    break;
                }
                idx -= 1;
            }
            let main = label.unwrap_or_else(|| {
                g.commits
                    .get(commit_idx)
                    .map(|c| {
                        let subj = c.subject.chars().take(60).collect::<String>();
                        format!("no branch name · {subj}")
                    })
                    .unwrap_or_else(|| "lane".to_string())
            });
            let hint = g
                .commits
                .get(commit_idx)
                .map(|c| format!("commit: {} · {}", c.short, c.author));
            Some((rect, main, hint))
        }
        HoverChip::StatuslineNowPlaying => {
            let rect = app.rects.statusline_mixr_chip?;
            // qa-6th mouse SEV-3 2026-06-29: was returning None
            // when nothing is playing, so the chip had no tooltip
            // and felt undiscoverable. Fall back to a generic
            // affordance string.
            let main = match app.now_playing.as_ref() {
                Some(np) => {
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
                    format!("{source}: {track}")
                }
                None => "mixr".to_string(),
            };
            Some((
                rect,
                main,
                Some("click: open mixr · right-click: menu".into()),
            ))
        }
        HoverChip::PaletteSidebarButton => {
            let rect = app.rects.palette_sidebar_button?;
            let state = if app.tree_visible { "open" } else { "off" };
            Some((
                rect,
                format!("file tree: {state}"),
                Some("click: toggle file tree (Ctrl+B)".into()),
            ))
        }
        HoverChip::PaletteRightPanelButton => {
            let rect = app.rects.palette_right_panel_button?;
            let state = if app.right_panel_visible {
                "open"
            } else {
                "off"
            };
            Some((
                rect,
                format!("right panel: {state}"),
                Some("click: toggle right side panel (Ctrl+Shift+B)".into()),
            ))
        }
        HoverChip::PaletteBackButton => {
            let rect = app.rects.palette_back_button?;
            Some((rect, "previous buffer".to_string(), None))
        }
        HoverChip::PaletteForwardButton => {
            let rect = app.rects.palette_forward_button?;
            Some((rect, "next buffer".to_string(), None))
        }
        HoverChip::PaletteSearchChip => {
            let rect = app.rects.palette_search_chip?;
            Some((
                rect,
                "command palette".to_string(),
                Some("click: open files, commands, recent (Cmd+P)".into()),
            ))
        }
        HoverChip::PaletteDropdownButton => {
            let rect = app.rects.palette_dropdown_button?;
            Some((rect, "recent files".to_string(), None))
        }
        HoverChip::PaletteAddIntegration => {
            let rect = app.rects.palette_add_integration_button?;
            Some((
                rect,
                "add integration".into(),
                Some("click: discovery overlay (siblings + custom)".into()),
            ))
        }
        HoverChip::RightPanelTab(pid) => {
            // Find this tab's rect by walking right_panel_tabs and
            // matching the pane id.
            let idx = app.right_panel_panes.iter().position(|&p| p == pid)?;
            let rect = app
                .rects
                .right_panel_tabs
                .iter()
                .find(|(_, i)| *i == idx)
                .map(|(r, _)| *r)?;
            use crate::pane::Pane;
            let main = app.panes.get(pid).map(Pane::title).unwrap_or_default();
            // design-critic end-of-day #3 — inactive tab's "×: close
            // active tab" implied "click × to close THIS tab" which
            // is wrong. Give each tab its own helper line.
            let hint = if idx == app.right_panel_active_idx {
                "click: switch · ×: close · right-click: menu"
            } else {
                "click: switch tab · right-click: switch/close"
            };
            Some((rect, main, Some(hint.into())))
        }
        HoverChip::RightPanelClose => {
            let rect = app.rects.right_panel_close?;
            Some((
                rect,
                "close active tab".to_string(),
                Some("left-click: close · right-click: menu · Ctrl+Alt+W".into()),
            ))
        }
        HoverChip::SplitTabChip(pid) => {
            let rect = app
                .rects
                .split_tab_chips
                .iter()
                .find(|(_, _, p)| *p == pid)
                .map(|(r, _, _)| *r)?;
            use crate::pane::Pane;
            let title = app.panes.get(pid).map(Pane::title).unwrap_or_default();
            let path = if let Some(Pane::Editor(b)) = app.panes.get(pid) {
                b.path.as_ref().map(|p| p.display().to_string())
            } else {
                None
            };
            let main = path.unwrap_or(title);
            Some((
                rect,
                main,
                Some("click: switch · middle: close · right: menu".into()),
            ))
        }
        HoverChip::SplitTabClose(pid) => {
            let rect = app
                .rects
                .split_tab_close
                .iter()
                .find(|(_, _, p)| *p == pid)
                .map(|(r, _, _)| *r)?;
            use crate::pane::Pane;
            let dirty = matches!(app.panes.get(pid), Some(Pane::Editor(b)) if b.dirty);
            let label = if dirty {
                "close (unsaved — will prompt)"
            } else {
                "close tab"
            };
            Some((rect, label.into(), None))
        }
        HoverChip::AgentsPanelChip(kind) => {
            let rect = match kind {
                crate::AgentsPanelChipKind::NewSession => app.rects.agents_panel_new_chip,
                crate::AgentsPanelChipKind::FromPr => app.rects.agents_panel_pr_chip,
                crate::AgentsPanelChipKind::ViewToggle => app.rects.agents_panel_view_chip,
            }?;
            let (main, sub) = match kind {
                crate::AgentsPanelChipKind::NewSession => (
                    "new agent session",
                    Some("click: spawn fresh Claude Code session in workspace"),
                ),
                crate::AgentsPanelChipKind::FromPr => (
                    "new agent from PR",
                    Some("click: open wizard — pick PRs + action, fire one session per PR"),
                ),
                crate::AgentsPanelChipKind::ViewToggle => (
                    "view mode",
                    Some("click: cycle workspace ↔ status grouping"),
                ),
            };
            Some((rect, main.into(), sub.map(Into::into)))
        }
        HoverChip::CloudAgentsNewRunButton => {
            let rect = app.rects.cloud_agents_new_run_button?;
            Some((
                rect,
                "new cloud run".into(),
                Some("click: open wizard (Managed Agents · ECS runner)".into()),
            ))
        }
        HoverChip::CloudRunAutoRefresh => {
            // Find the rect in cloud_agent_run_hits.
            let rect = app
                .rects
                .cloud_agent_run_hits
                .iter()
                .find(|(_, _, h)| {
                    matches!(
                        h,
                        crate::ui::cloud_agent_run_view::CloudAgentRunHit::CycleAutoRefresh
                    )
                })
                .map(|(r, _, _)| *r)?;
            Some((
                rect,
                "auto-refresh".into(),
                Some("click: cycle off → 10s → 30s → 60s → 5m".into()),
            ))
        }
        HoverChip::CloudRunRefresh => {
            let rect = app
                .rects
                .cloud_agent_run_hits
                .iter()
                .find(|(_, _, h)| {
                    matches!(
                        h,
                        crate::ui::cloud_agent_run_view::CloudAgentRunHit::Refresh
                    )
                })
                .map(|(r, _, _)| *r)?;
            Some((
                rect,
                "refresh".into(),
                Some("click: re-fetch logs + artifacts (or restart SSE stream)".into()),
            ))
        }
        HoverChip::ActivityBarGear => {
            let rect = app.rects.activity_bar_gear?;
            Some((
                rect,
                "settings".into(),
                Some("click: themes · about · prefs".into()),
            ))
        }
        HoverChip::DockKebab => {
            let rect = app.rects.dock_widget_kebabs.first().map(|(r, _)| *r)?;
            Some((rect, "widget options".into(), None))
        }
        HoverChip::DockEmptyChip => {
            let rect = app.rects.dock_empty_chip?;
            Some((
                rect,
                "create first dock widget".into(),
                Some("click: choose widget kind".into()),
            ))
        }
        HoverChip::StatuslineMixrPlay => {
            let rect = app.rects.statusline_mixr_play_chip?;
            Some((rect, "play / pause".into(), None))
        }
        HoverChip::StatuslineMixrFfwd => {
            let rect = app.rects.statusline_mixr_ffwd_chip?;
            Some((rect, "skip track".into(), None))
        }
        HoverChip::StatuslineTestChip => {
            let rect = app.rects.statusline_test_chip?;
            Some((
                rect,
                "test status".into(),
                Some("click: focus test output pane".into()),
            ))
        }
        HoverChip::SplitStripTermButton => {
            let rect = app
                .rects
                .split_strip_term_buttons
                .iter()
                .map(|(r, _)| *r)
                .next()?;
            Some((rect, "open shell in split".to_string(), None))
        }
        HoverChip::SplitStripButton(dir) => {
            let rect = app
                .rects
                .split_strip_buttons
                .iter()
                .find(|(_, _, d)| *d == dir)
                .map(|(r, _, _)| *r)?;
            let label = match dir {
                crate::layout::SplitDir::Horizontal => "split right",
                crate::layout::SplitDir::Vertical => "split down",
            };
            Some((rect, label.into(), None))
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
            // Stale "click: app.quit" surfaced an internal command
            // id; user-facing sublabel reads better.
            Some((rect, "quit mnml".into(), Some("click: quit".into())))
        }
        HoverChip::SplitStripAiButton => {
            // Anchor on the first AI-button rect (any of them work —
            // the tooltip just needs a position to attach to). The
            // config decides what the label reads.
            let rect = app
                .rects
                .split_strip_ai_buttons
                .iter()
                .map(|(r, _, _)| *r)
                .next()?;
            let (primary, secondary) = match app.config.ui.tab_bar_ai_icon.as_str() {
                "codex" => (
                    "open Codex in this split".to_string(),
                    "click: spawn Codex".into(),
                ),
                "both" => (
                    "open Claude / Codex in this split".to_string(),
                    "click a chip to spawn · right-click: menu".into(),
                ),
                _ => (
                    "open new Claude Code session".to_string(),
                    "click: spawn new session · right-click: menu".into(),
                ),
            };
            Some((rect, primary, Some(secondary)))
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
        HoverChip::SessionsTab(pid) => {
            let rect = app
                .rects
                .session_tabs
                .iter()
                .find(|(_, p)| *p == pid)
                .map(|(r, _)| *r)?;
            use crate::pane::Pane;
            let (title, sub) = match app.panes.get(pid) {
                Some(Pane::Pty(s)) => {
                    let profile_label = s.profile.label.clone();
                    let title = format!("{profile_label} — session");
                    // Claude sessions: try to show the last user + assistant
                    // exchange snippet. Falls back gracefully if the
                    // transcript can't be read (fresh session, missing
                    // file, malformed JSONL).
                    let preview = s.profile.session_id.as_deref().and_then(|sid| {
                        crate::claude_agents::preview_last_messages(sid, &app.workspace)
                    });
                    (title, preview.or(Some("click: focus session".into())))
                }
                Some(p) => (p.title(), Some("click: focus session".into())),
                None => ("session".into(), None),
            };
            Some((rect, title, sub))
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
        HoverChip::ClaudeAgentsTopbarChip(kind) => {
            let rect = app
                .rects
                .claude_agents_topbar_chips
                .iter()
                .find(|(_, _, k)| *k == kind)
                .map(|(r, _, _)| *r)?;
            let label = match kind {
                crate::ui::TopbarChipKind::View => {
                    "click: cycle drill view (Summary → Todos → Files → Bash → Subagents) · key: v"
                }
                crate::ui::TopbarChipKind::Sort => {
                    "click: cycle sort key (state → tokens↓ → cost↓ → recent → …) · key: s"
                }
                crate::ui::TopbarChipKind::Group => {
                    "click: cycle grouping (by source ↔ by workspace) · key: Ctrl+G"
                }
                crate::ui::TopbarChipKind::Source => {
                    "click: cycle source filter (all → ✦ claude → ◈ codex → all) · key: >"
                }
                crate::ui::TopbarChipKind::Workspace => {
                    "click: toggle workspace-only filter · key: W"
                }
            };
            Some((rect, label.into(), None))
        }
        HoverChip::RequestTopBarChip(kind) => {
            use crate::RequestTopBarChip;
            let (rect, primary, secondary) = match kind {
                RequestTopBarChip::Method => (
                    app.rects.request_method_button?,
                    "click: pick HTTP verb (GET / POST / …)",
                    None,
                ),
                RequestTopBarChip::Env => (
                    app.rects.request_env_button?,
                    "click: switch active .env",
                    Some("right-click: switch / edit / clear override"),
                ),
                RequestTopBarChip::Send => (
                    app.rects.request_send_button?,
                    "click: send request (or abort while in-flight)",
                    Some("right-click: send / abort / diff last two"),
                ),
                RequestTopBarChip::Save => (
                    app.rects.request_save_button?,
                    "click: save request (Save-As if new)",
                    Some("right-click: save / save mock / save response"),
                ),
                RequestTopBarChip::Clear => (
                    app.rects.request_clear_button?,
                    "click: clear the request fields",
                    None,
                ),
                RequestTopBarChip::Code => (
                    app.rects.request_code_button?,
                    "click: generate code snippet (curl / py / js / …)",
                    Some("right-click: copy curl / open picker"),
                ),
            };
            Some((rect, primary.into(), secondary.map(|s| s.into())))
        }
    }
}
