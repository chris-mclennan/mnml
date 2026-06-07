//! The left rail. Two stacked sections, each with a collapsible header:
//!
//! * `> WORKSPACE-NAME` — the file tree (VS-Code Explorer-style).
//! * `> GIT` — local branches (`●` marks the current one) followed by linked
//!   worktrees (`⤿` marks the one we're in). Click a branch ⇒ checkout; click
//!   a worktree ⇒ open a shell pane there. Right-click for the per-row menu.
//!
//! The rail itself is independently toggled by `Ctrl+B` (`tree_visible`). Both
//! section-expand states are persisted in session.json.

use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

use crate::app::{App, RailSection};
use crate::focus::Focus;
use crate::git::rail::GitRailHit;
use crate::git::status::FileState;
use crate::ui::{icons, theme};

const CHEVRON_OPEN: &str = "\u{f107}"; //  (angle-down)
const CHEVRON_CLOSED: &str = "\u{f105}"; //  (angle-right)

/// Max branches shown in the GIT section's branches sub-list when
/// `App.git_branches_expanded` is false (the default). User clicks
/// the trailing `+ N more` row to flip to "show all".
const BRANCH_LIST_CAP: usize = 8;

pub fn draw(frame: &mut Frame, app: &mut App, area: Rect) {
    let rail_bg = theme::cur().bg_darker;
    // `Block` actually fills every cell in `area` with the bg color;
    // an empty `Paragraph` doesn't (it only writes glyphs where text
    // exists). Without this, when a section shrinks frame-to-frame
    // (e.g. INTEGRATIONS toggling expanded → collapsed), leftover
    // text from the previous render remains visible in the cells the
    // shrunk section no longer covers. See bug: stale "e" + "x" from
    // "Claude Code" / "Codex" labels showing above INTEGRATIONS.
    frame.render_widget(
        ratatui::widgets::Block::default().style(Style::default().bg(rail_bg)),
        area,
    );
    app.rects.tree = None;
    app.rects.tree_toggle = None;
    app.rects.git_section_toggle = None;
    app.rects.git_rail_rows.clear();
    app.rects.extra_workspace_bodies.clear();
    app.rects.extra_workspace_toggles.clear();
    app.rects.tree_icon_buttons.clear();
    app.rects.integration_icon_rects.clear();
    app.rects.integration_section_toggle = None;
    if area.height == 0 || area.width == 0 {
        return;
    }

    let nerd = !app.config.ui.ascii_icons;
    let width = area.width as usize;
    if area.height < 2 {
        return;
    }

    // The rail's bottom slice hosts (top to bottom): INTEGRATIONS
    // section + GIT section. Both are pinned to the bottom and grow
    // upward to fit their content; the workspace tree gets whatever's
    // left above. Compute each section's needed height, then carve
    // them out of `area` from the bottom up.
    let git_needed = compute_git_section_height(app);
    let integration_needed = compute_integration_section_height(app, area.width as usize);
    // Keep at least `MIN_TREE_ROWS` for the workspace; anything beyond
    // that the two bottom sections can claim.
    const MIN_TREE_ROWS: u16 = 6;
    let bottom_budget = area.height.saturating_sub(MIN_TREE_ROWS).max(1);
    // INTEGRATIONS gets first dibs — it's small (1 header + 1-2 icon
    // rows) and a long GIT branch list would otherwise eat the whole
    // bottom budget and squeeze it out. GIT then gets what's left and
    // its branch list scrolls if it can't fit (GIT is the section
    // designed to grow; INTEGRATIONS is a stable fixed-size strip).
    let integration_height = integration_needed.min(bottom_budget);
    let remaining_for_git = bottom_budget.saturating_sub(integration_height);
    let git_height = git_needed.min(remaining_for_git).max(1);
    // Bottom-pad GIT by 1 row when collapsed so the chevron-only
    // header doesn't sit flush against the rail's bottom edge —
    // visually anchors it as a real section header rather than a
    // stray row. Expanded GIT runs to the bottom edge as before
    // (the branch list provides its own visual weight there).
    let git_bottom_pad: u16 = if !app.git_section_expanded { 1 } else { 0 };
    let git_top_y = area.y + area.height - git_height - git_bottom_pad;
    let integration_top_y = git_top_y.saturating_sub(integration_height + 1); // +1 separator
    // Workspace section gets everything above the integration section
    // (with a one-row separator immediately above it).
    let ws_end_y = if integration_height > 0 {
        integration_top_y.saturating_sub(1)
    } else {
        git_top_y.saturating_sub(1)
    };

    // ── row 0: WORKSPACE header (with right-aligned action chips).
    let ws_name = app
        .workspace
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("workspace")
        .to_string();
    let chev = section_chev(app.tree_root_expanded, nerd);
    let chev_str = format!(" {chev} ");
    let header_used = chev_str.chars().count() + ws_name.chars().count();
    let header_rect = Rect {
        x: area.x,
        y: area.y,
        width: area.width,
        height: 1,
    };
    let chip_spans = workspace_header_chips(app, header_rect, header_used, nerd, rail_bg);
    let mut spans = vec![
        Span::styled(
            chev_str,
            Style::default().fg(theme::cur().comment).bg(rail_bg),
        ),
        Span::styled(
            ws_name.clone(),
            Style::default()
                .fg(theme::cur().fg)
                .bg(rail_bg)
                .add_modifier(Modifier::BOLD),
        ),
    ];
    spans.extend(chip_spans);
    frame.render_widget(Paragraph::new(Line::from(spans)), header_rect);
    app.rects.tree_toggle = Some(header_rect);

    // The clipped rect bounds the workspace-tree / extras / `+ repo`
    // rows so they never spill into the GIT panel pinned below.
    let ws_area = Rect {
        x: area.x,
        y: area.y,
        width: area.width,
        height: ws_end_y.saturating_sub(area.y),
    };

    // ── workspace file list (only when expanded). Returns the row past the
    //    last one it drew, so the next workspace section / `+ repo` row
    //    can render below.
    let mut next_y = area.y + 1;
    if app.tree_root_expanded && ws_area.height >= 2 {
        next_y = draw_workspace_files(frame, app, ws_area, next_y, nerd);
    }

    // ── extra workspace sections (from `[[workspaces]]` config). Each gets
    //    a blank separator + collapsible header (with action chips); expanded
    //    sections show a bounded file-list slot below the header.
    for ws_idx in 0..app.extra_workspaces.len() {
        if next_y + 1 >= ws_end_y {
            break;
        }
        next_y = draw_extra_workspace_section(frame, app, ws_area, next_y, ws_idx, nerd);
        if next_y >= ws_end_y {
            break;
        }
    }

    // ── `+ repo` row — a single right-aligned chip on its own row, sitting
    //    just below the last workspace section's content and above the GIT
    //    separator. Only drawn if there's space for it AND the workspace
    //    section is expanded (otherwise the rail header alone implies "add
    //    repo" via the [+] chip in the workspace header anyway).
    if next_y < ws_end_y {
        draw_add_repo_row(frame, app, area, next_y, nerd, rail_bg);
    }

    // ── INTEGRATIONS section: pinned just above GIT (with a blank
    //    separator row between). Only rendered if there's space + the
    //    user has configured at least one integration icon.
    if integration_height > 0 {
        draw_integration_section(
            frame,
            app,
            area,
            integration_top_y,
            integration_height,
            nerd,
            rail_bg,
        );
    }

    // ── GIT section: pinned to bottom. Render at git_top_y regardless of
    //    where the workspace section ended; the separator row above it is
    //    left blank by the row-0 bg fill at the top of `draw`.
    let git_header_y = git_top_y;
    if git_header_y >= area.y + area.height {
        return;
    }
    let chev = section_chev(app.git_section_expanded, nerd);
    // Multi-repo workspaces append `· <repo-name>` to the GIT header so
    // the user knows which repo the rail is currently scoped to. Single-
    // repo case keeps the bare "GIT" label.
    let multi_repo_chip = if app.repos.len() > 1 {
        app.repos
            .get(app.active_repo)
            .map(|r| format!("  · {}", r.name))
            .unwrap_or_default()
    } else {
        String::new()
    };
    let chev_str = format!(" {chev} ");
    let label_str = format!("GIT{multi_repo_chip}");
    let header_used = chev_str.chars().count() + label_str.chars().count();
    // Right-aligned cluster of one-click git op chips. Each is 3 cells
    // (`' <glyph> '`). Drop chips from the right until the cluster fits
    // in the remaining width with at least one space of separation.
    // Order matches the GitGraph toolbar so the visual language is
    // consistent.
    let t = theme::cur();
    type ChipSpec = (
        &'static str,
        &'static str,
        crate::GitRailHeaderAction,
        ratatui::style::Color,
    );
    let chips_full: [ChipSpec; 6] = [
        ("\u{EB37}", "↺", crate::GitRailHeaderAction::Fetch, t.cyan),
        ("\u{EA9A}", "↓", crate::GitRailHeaderAction::Pull, t.green),
        ("\u{EAA1}", "↑", crate::GitRailHeaderAction::Push, t.blue),
        (
            "\u{EA60}",
            "+",
            crate::GitRailHeaderAction::StageAll,
            t.green,
        ),
        (
            "\u{F012C}",
            "✓",
            crate::GitRailHeaderAction::Commit,
            t.green,
        ),
        (
            "\u{F062C}",
            "⎇",
            crate::GitRailHeaderAction::Graph,
            t.yellow,
        ),
    ];
    // Decide how many chips fit: each is 3 cells; keep at least one space
    // of padding between label and cluster.
    let chip_w = 3usize;
    let min_separation = 1usize;
    let chip_count = {
        let mut n = chips_full.len();
        while n > 0 && header_used + min_separation + n * chip_w > width {
            n -= 1;
        }
        n
    };
    let chips_used = chip_count * chip_w;
    let pad_between = width.saturating_sub(header_used + chips_used);

    app.rects.rail_git_header_buttons.clear();
    let mut spans: Vec<Span<'static>> = Vec::with_capacity(3 + chip_count);
    spans.push(Span::styled(
        chev_str,
        Style::default().fg(t.comment).bg(rail_bg),
    ));
    spans.push(Span::styled(
        label_str,
        Style::default()
            .fg(t.fg)
            .bg(rail_bg)
            .add_modifier(Modifier::BOLD),
    ));
    spans.push(Span::styled(
        " ".repeat(pad_between),
        Style::default().bg(rail_bg),
    ));
    // Translate chip-cluster cells into screen-relative rects as we paint.
    let cluster_start_x = area.x + (header_used + pad_between) as u16;
    for (i, (glyph_nerd, glyph_ascii, action, fg)) in chips_full.iter().take(chip_count).enumerate()
    {
        let glyph = if nerd { *glyph_nerd } else { *glyph_ascii };
        spans.push(Span::styled(
            format!(" {glyph} "),
            Style::default().fg(*fg).bg(rail_bg),
        ));
        let chip_x = cluster_start_x + (i * chip_w) as u16;
        app.rects.rail_git_header_buttons.push((
            Rect {
                x: chip_x,
                y: git_header_y,
                width: chip_w as u16,
                height: 1,
            },
            *action,
        ));
    }
    let git_header_rect = Rect {
        x: area.x,
        y: git_header_y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(Paragraph::new(Line::from(spans)), git_header_rect);
    app.rects.git_section_toggle = Some(git_header_rect);

    if !app.git_section_expanded {
        return;
    }
    let body_y = git_header_y + 1;
    if body_y >= area.y + area.height {
        return;
    }
    draw_git_section(frame, app, area, body_y, nerd);
}

/// The four per-workspace action chips that hang off the right edge of
/// every workspace/repo header row. Click dispatches a palette command
/// by id; the cluster reads `+ file · + folder · ↺ refresh · ↕ collapse`
/// from left to right.
/// Per-workspace action chips. The fourth chip is a toggle whose glyph
/// + dispatch flip with the tree's current expansion state:
///   - any dir expanded   → ` collapse-all` (EAC5)
///   - everything closed  → ` expand-all`   (EBD9)
///
/// The toggle dispatches `tree.toggle_collapse_all` either way; the
/// glyph swap is purely visual.
fn workspace_action_chip_specs(
    app: &App,
) -> [(
    &'static str,
    &'static str,
    &'static str,
    ratatui::style::Color,
); 4] {
    let t = theme::cur();
    let (collapse_glyph, collapse_ascii) = if app.tree.is_fully_collapsed() {
        ("\u{F0AB4}", "↧") // expand-all
    } else {
        ("\u{EAC5}", "↕") // collapse-all
    };
    [
        ("\u{EA80}", "f+", "file.new", t.blue),
        ("\u{EA7F}", "d+", "file.new_folder", t.yellow),
        ("\u{EB37}", "↺", "tree.refresh", t.cyan),
        (
            collapse_glyph,
            collapse_ascii,
            "tree.toggle_collapse_all",
            t.teal,
        ),
    ]
}

/// Right-aligned action-chip cluster for a workspace header row. Caller
/// supplies the header's already-painted prefix width (chevron + label)
/// so this helper can compute the gap-pad span and chip positions.
/// Returns the spans to append to the header's `Line`; also pushes each
/// chip's screen-rect + command-id into `app.rects.tree_icon_buttons`.
///
/// Drops trailing chips when the header is too narrow to host the full
/// cluster with at least one space of separation from the label.
fn workspace_header_chips(
    app: &mut App,
    header_rect: Rect,
    label_used: usize,
    nerd: bool,
    rail_bg: ratatui::style::Color,
) -> Vec<Span<'static>> {
    let chips = workspace_action_chip_specs(app);
    let width = header_rect.width as usize;
    let chip_w = 3usize;
    let min_separation = 1usize;
    let chip_count = {
        let mut n = chips.len();
        while n > 0 && label_used + min_separation + n * chip_w > width {
            n -= 1;
        }
        n
    };
    let chips_used = chip_count * chip_w;
    let pad = width.saturating_sub(label_used + chips_used);
    let mut spans: Vec<Span<'static>> = Vec::with_capacity(1 + chip_count);
    spans.push(Span::styled(" ".repeat(pad), Style::default().bg(rail_bg)));
    let cluster_start_x = header_rect.x + (label_used + pad) as u16;
    for (i, (glyph_nerd, glyph_ascii, cmd_id, fg)) in chips.iter().take(chip_count).enumerate() {
        let glyph = if nerd { *glyph_nerd } else { *glyph_ascii };
        spans.push(Span::styled(
            format!(" {glyph} "),
            Style::default().fg(*fg).bg(rail_bg),
        ));
        let chip_x = cluster_start_x + (i * chip_w) as u16;
        app.rects.tree_icon_buttons.push((
            Rect {
                x: chip_x,
                y: header_rect.y,
                width: chip_w as u16,
                height: 1,
            },
            *cmd_id,
        ));
    }
    spans
}

/// Single right-aligned `+ repo` chip on its own row — sits below the
/// last workspace section's content, above the GIT separator. Replaces
/// the old top-of-rail "add workspace" chip.
fn draw_add_repo_row(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    y: u16,
    nerd: bool,
    rail_bg: ratatui::style::Color,
) {
    let width = area.width as usize;
    let chip_w = 3usize;
    if width < chip_w + 1 {
        return;
    }
    let glyph = if nerd { "\u{F0419}" } else { "+" };
    let pad = width.saturating_sub(chip_w);
    let row_rect = Rect {
        x: area.x,
        y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" ".repeat(pad), Style::default().bg(rail_bg)),
            Span::styled(
                format!(" {glyph} "),
                Style::default().fg(theme::cur().green).bg(rail_bg),
            ),
        ])),
        row_rect,
    );
    app.rects.tree_icon_buttons.push((
        Rect {
            x: area.x + pad as u16,
            y,
            width: chip_w as u16,
            height: 1,
        },
        "view.add_workspace",
    ));
}

/// Original-config indices of the integration icons that should
/// render in the sidebar — built-ins always show; `:host.launch X`
/// entries only show when `X` is detected on PATH or a well-known
/// install dir. Preserving the original index matters because the
/// hover/click rect map uses it to look the icon up again.
fn visible_integration_indices(app: &App) -> Vec<usize> {
    app.config
        .ui
        .integration_icons
        .iter()
        .enumerate()
        .filter_map(|(i, ic)| {
            match crate::integration_detect::sibling_binary_for_command(&ic.command) {
                None => Some(i), // built-in palette command — always available
                Some(bin) if crate::integration_detect::is_binary_installed(bin) => Some(i),
                Some(_) => None,
            }
        })
        .collect()
}

/// Height the INTEGRATIONS section wants when pinned above GIT. Counts
/// 1 row for the header + `ceil(N / icons_per_row)` rows for the grid
/// (where `icons_per_row` is derived from `rail_w / chip_w`). Returns
/// 1 (just the header) when there are no installed integrations — the
/// header stays visible so the user can still see the section + the
/// future `+` button (the misleading "Jira is configured" state when
/// it's just a default is gone).
fn compute_integration_section_height(app: &App, rail_width: usize) -> u16 {
    let n = visible_integration_indices(app).len();
    if n == 0 {
        // Header-only — keeps the section's identity visible even when
        // nothing is installed yet. (Used to return 0, which hid the
        // section entirely. With detection in place we want users to
        // see "INTEGRATIONS" so the `+` button discovery flow is
        // discoverable from an empty rail.)
        return if app.config.ui.integration_icons.is_empty() {
            0
        } else {
            1
        };
    }
    if !app.integration_section_expanded {
        // Compact: header + 1 row of icons packed horizontally. Each
        // chip is 4 cells (` g  ` or ` g ` for the 2-cell-wide
        // Claude/Codex variants — see render). Multiple rows if the
        // icons don't all fit in one rail width.
        const CHIP_W: usize = 4;
        let per_row = (rail_width / CHIP_W).max(1);
        let rows = n.div_ceil(per_row);
        return (1 + rows) as u16;
    }
    // Expanded: one icon per row (icon + name). Header + N rows.
    (1 + n) as u16
}

/// Render the INTEGRATIONS section: a `> INTEGRATIONS` header (using
/// the same chevron + label pattern as GIT) followed by a grid of
/// plain-glyph icons. Each icon row is `chip_w` cells per slot; no
/// chip background — just colored glyphs spaced inside the rail.
fn draw_integration_section(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    start_y: u16,
    height: u16,
    nerd: bool,
    rail_bg: ratatui::style::Color,
) {
    if height == 0 {
        return;
    }
    let t = theme::cur();
    let width = area.width as usize;

    // Header row: `> INTEGRATIONS  ……  + `
    // (the `+` chip on the right mirrors the GIT section's add-repo
    // chip — clicking it opens the discovery overlay.)
    let chev = section_chev(app.integration_section_expanded, nerd);
    let chev_str = format!(" {chev} ");
    let label = "INTEGRATIONS".to_string();
    let plus_glyph = if nerd { "\u{F0419}" } else { "+" };
    let plus_chip = format!(" {plus_glyph} ");
    let plus_chip_w = plus_chip.chars().count();
    let used = chev_str.chars().count() + label.chars().count() + plus_chip_w;
    let pad = width.saturating_sub(used);
    let header_rect = Rect {
        x: area.x,
        y: start_y,
        width: area.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(chev_str, Style::default().fg(t.comment).bg(rail_bg)),
            Span::styled(
                label,
                Style::default()
                    .fg(t.fg)
                    .bg(rail_bg)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(" ".repeat(pad), Style::default().bg(rail_bg)),
            Span::styled(plus_chip, Style::default().fg(t.green).bg(rail_bg)),
        ])),
        header_rect,
    );
    // Toggle rect is the chevron+label area only — clicking on the
    // `+` chip at the right edge fires the discovery overlay instead.
    let toggle_w = area.width.saturating_sub(plus_chip_w as u16);
    app.rects.integration_section_toggle = Some(Rect {
        x: area.x,
        y: start_y,
        width: toggle_w,
        height: 1,
    });
    // Register the `+` chip's hit rect — handled by the same dispatch
    // path the workspace-tree `view.add_workspace` chip uses.
    app.rects.tree_icon_buttons.push((
        Rect {
            x: area.x + toggle_w,
            y: start_y,
            width: plus_chip_w as u16,
            height: 1,
        },
        "integrations.add",
    ));

    let max_y = start_y + height;

    // ── Collapsed: a horizontal row of icon-only chips below the
    //    header. Each chip is 4 cells wide; the wide-glyph rows
    //    (Claude / Codex) trim a trailing space to keep the visual
    //    cell-count consistent with 1-cell glyphs.
    if !app.integration_section_expanded {
        // Only render icons whose underlying binary is detected on
        // PATH / well-known dirs (built-ins always pass). The original
        // config index is preserved so click/hover rect lookups still
        // resolve to the right `integration_icons[i]` entry.
        let visible = visible_integration_indices(app);
        let n = visible.len();
        if n == 0 {
            return;
        }
        const CHIP_W: usize = 4;
        let per_row = (width / CHIP_W).max(1);
        let icons: Vec<(usize, String, String, String)> = visible
            .iter()
            .map(|&i| {
                let ic = &app.config.ui.integration_icons[i];
                (i, ic.glyph.clone(), ic.fallback.clone(), ic.color.clone())
            })
            .collect();
        for (row_y, chunk) in (start_y + 1..).zip(icons.chunks(per_row)) {
            if row_y >= max_y {
                break;
            }
            let mut spans: Vec<Span<'static>> = Vec::with_capacity(chunk.len() + 1);
            for (slot_i, (i, glyph, fallback, color)) in chunk.iter().enumerate() {
                let g = if nerd {
                    glyph.as_str()
                } else {
                    fallback.as_str()
                };
                let fg = match color.as_str() {
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
                // Same wide-glyph trick used in the expanded layout:
                // Claude / Codex glyphs render 2-cell wide, so drop a
                // trailing space to keep the visual chip width
                // consistent.
                let wide_glyph = matches!(glyph.as_str(), "\u{F8B0}" | "\u{F8B1}");
                let chip_text = if wide_glyph {
                    format!(" {g} ")
                } else {
                    format!(" {g}  ")
                };
                spans.push(Span::styled(chip_text, Style::default().fg(fg).bg(rail_bg)));
                let chip_x = area.x + (slot_i * CHIP_W) as u16;
                app.rects.integration_icon_rects.push((
                    Rect {
                        x: chip_x,
                        y: row_y,
                        width: CHIP_W as u16,
                        height: 1,
                    },
                    *i,
                ));
            }
            let used = chunk.len() * CHIP_W;
            spans.push(Span::styled(
                " ".repeat(width.saturating_sub(used)),
                Style::default().bg(rail_bg),
            ));
            let row_rect = Rect {
                x: area.x,
                y: row_y,
                width: area.width,
                height: 1,
            };
            frame.render_widget(Paragraph::new(Line::from(spans)), row_rect);
        }
        return;
    }

    // ── Expanded: one icon per row with its label, full width.
    // The grid layout drifts out of alignment with Nerd-Font icons
    // that render as 2-cell-wide glyphs (PUA + MDI codepoints in
    // non-Mono variants), causing tooltips to attach to the wrong
    // icon — but the vertical layout sidesteps that since each row
    // only contains one icon. Each row is also wider, so the
    // human-readable name fits next to the glyph — easier to scan
    // than a 7-glyph chip grid.
    //
    // Filtering note: same as the collapsed view, only render rows
    // whose binary is installed (or built-in palette commands). The
    // original config index is preserved for the click rect.
    let visible = visible_integration_indices(app);
    let icons: Vec<(usize, String, String, String, String)> = visible
        .iter()
        .map(|&i| {
            let ic = &app.config.ui.integration_icons[i];
            let label = ic.tooltip.clone().unwrap_or_else(|| ic.id.clone());
            (
                i,
                ic.glyph.clone(),
                ic.fallback.clone(),
                ic.color.clone(),
                label,
            )
        })
        .collect();

    for (row_y, (i, glyph, fallback, color, label)) in (start_y + 1..).zip(icons.iter()) {
        if row_y >= max_y {
            break;
        }
        let g = if nerd {
            glyph.as_str()
        } else {
            fallback.as_str()
        };
        let fg = match color.as_str() {
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
        // Claude (U+F8B0) and Codex (U+F8B1) are patched into the
        // mnml Nerd Font as 2-cell-wide glyphs (most terminals render
        // PUA codepoints as wide); the rest of the integration icons
        // are 1-cell. Compensate by trimming a trailing space on the
        // wide rows so the leading space + glyph + trailing space
        // sum to the same VISUAL width as ` glyph  ` does on 1-cell
        // rows. Both columns (icon left-edge + label left-edge) line
        // up across all rows.
        //
        //   1-cell glyph: ` g  ` → cells [_ g _ _] → label at col 4
        //   2-cell glyph: ` g ` → cells [_ g g _] → label at col 4
        let wide_glyph = matches!(glyph.as_str(), "\u{F8B0}" | "\u{F8B1}");
        let icon_part = if wide_glyph {
            format!(" {g} ")
        } else {
            format!(" {g}  ")
        };
        // Truncate the label to fit the rail width (icon takes 4
        // cells, leaving width - 4 for the label).
        let label_cells = width.saturating_sub(icon_part.chars().count());
        let label_display: String = label.chars().take(label_cells).collect();
        let used = icon_part.chars().count() + label_display.chars().count();
        let pad = width.saturating_sub(used);
        let spans = vec![
            Span::styled(icon_part, Style::default().fg(fg).bg(rail_bg)),
            Span::styled(label_display, Style::default().fg(t.fg).bg(rail_bg)),
            Span::styled(" ".repeat(pad), Style::default().bg(rail_bg)),
        ];
        let row_rect = Rect {
            x: area.x,
            y: row_y,
            width: area.width,
            height: 1,
        };
        frame.render_widget(Paragraph::new(Line::from(spans)), row_rect);
        // The hit-rect is the WHOLE row — clicking the label or the
        // icon fires the integration's command.
        app.rects.integration_icon_rects.push((row_rect, *i));
    }
}

/// Rough estimate of the height GIT wants when pinned to the bottom of
/// the rail. Counts: 1 row for the header, then (if expanded) a
/// sub-label + the branch rows + a sub-label + the worktree rows.
/// Caller clamps against a per-rail maximum so a long branch list
/// can't push the workspace tree out entirely.
fn compute_git_section_height(app: &App) -> u16 {
    if !app.git_section_expanded {
        return 1;
    }
    let mut h: u16 = 1; // header
    if !app.git_rail.branches.is_empty() {
        let total = app.git_rail.branches.len();
        // Match the renderer's collapse logic: cap when not expanded,
        // add 1 for the `+ N more` toggle row when applicable, add 1
        // for the current-branch force-show (already counted if cap
        // covers it; +1 max).
        let shown = if app.git_branches_expanded {
            total
        } else {
            total.min(BRANCH_LIST_CAP)
        };
        let toggle_row = if total > BRANCH_LIST_CAP { 1 } else { 0 };
        let current_outside_cap = if !app.git_branches_expanded && total > BRANCH_LIST_CAP {
            // +1 for the force-shown current branch, only when it'd
            // actually be hidden by the cap. Cheap upper-bound: assume
            // it falls outside and reserve the row.
            1
        } else {
            0
        };
        h = h.saturating_add(1 + (shown + toggle_row + current_outside_cap) as u16);
    }
    if !app.git_rail.worktrees.is_empty() {
        h = h.saturating_add(1 + app.git_rail.worktrees.len() as u16);
    }
    // Clamp at a sane upper bound so a 50-branch repo can't eat the
    // whole rail — the actual rail-height cap is applied by the caller.
    h.min(40)
}

fn section_chev(expanded: bool, nerd: bool) -> &'static str {
    if expanded {
        if nerd { CHEVRON_OPEN } else { "▾" }
    } else if nerd {
        CHEVRON_CLOSED
    } else {
        "▸"
    }
}

/// Draw the WORKSPACE section's file list starting at `start_y`; returns the
/// row immediately past the last one drawn (so the GIT section follows on).
fn draw_workspace_files(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    start_y: u16,
    nerd: bool,
) -> u16 {
    let rail_bg = theme::cur().bg_darker;
    let width = area.width as usize;
    let avail = (area.y + area.height).saturating_sub(start_y);
    if avail == 0 {
        return start_y;
    }
    // The file list takes UP TO half the rail height when the GIT section is
    // expanded (so the rail doesn't become a wall of files crowding out git);
    // otherwise it can claim everything below it.
    let reserve_for_git = if app.git_section_expanded {
        let need = 2 + app.git_rail.row_count().min(8) as u16;
        need.min(avail.saturating_sub(2))
    } else {
        0
    };
    let h = (avail - reserve_for_git) as usize;
    if h == 0 {
        return start_y;
    }
    let mut inner = Rect {
        x: area.x,
        y: start_y,
        width: area.width,
        height: h as u16,
    };

    // Filter line — when the tree's in filter mode or has a sticky filter,
    // reserve the top row of the tree section for a `/ <query>` input.
    let show_filter = app.tree.filter_mode || !app.tree.filter.is_empty();
    if show_filter && inner.height >= 2 {
        let t = theme::cur();
        let cursor_glyph = if app.tree.filter_mode { "█" } else { "" };
        let line = Line::from(vec![
            Span::styled(" / ", Style::default().fg(t.yellow).bg(rail_bg)),
            Span::styled(
                app.tree.filter.clone(),
                Style::default().fg(t.fg).bg(rail_bg),
            ),
            Span::styled(
                cursor_glyph.to_string(),
                Style::default().fg(t.yellow).bg(rail_bg),
            ),
        ]);
        let filter_rect = Rect {
            x: inner.x,
            y: inner.y,
            width: inner.width,
            height: 1,
        };
        frame.render_widget(
            Paragraph::new(line).style(Style::default().bg(rail_bg)),
            filter_rect,
        );
        inner = Rect {
            x: inner.x,
            y: inner.y + 1,
            width: inner.width,
            height: inner.height - 1,
        };
    }
    app.rects.tree = Some(inner);
    let h = inner.height as usize;
    if h == 0 {
        return start_y + inner.height + if show_filter { 1 } else { 0 };
    }

    // Empty-workspace state: when mnml is launched without a real
    // workspace (workspace path == $HOME), show a vscode-style empty
    // panel with `Open file` / `Open folder` actions instead of the
    // tree contents. Registers click-rects on tree_icon_buttons so
    // mouse handling fires the same commands as the keychords.
    if is_empty_workspace(app) {
        draw_empty_workspace_state(frame, app, inner);
        return start_y + inner.height + if show_filter { 1 } else { 0 };
    }

    let rows = app.tree.visible_rows();
    let cursor = app.tree.cursor();

    if cursor < app.tree.scroll {
        app.tree.scroll = cursor;
    } else if cursor >= app.tree.scroll + h {
        app.tree.scroll = cursor + 1 - h;
    }
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    app.tree.scroll = app.tree.scroll.min(max_scroll);
    app.rects.tree_scroll = app.tree.scroll;

    let git_files = &app.git.snapshot().files;
    let focused = app.focus == Focus::Tree && app.rail_section == RailSection::Workspace;

    // Pre-compute a per-row "is this a repo dir?" lookup for the multi-repo
    // case. Only check depth-0 dirs (sub-repos aren't supported by
    // discover_repos and matching wouldn't fire), and only when there's
    // more than one repo (single-repo workspaces — including ones where
    // the workspace itself is the repo — don't get repo decoration so
    // the tree looks unchanged).
    let multi_repo = app.repos.len() > 1;
    let active_repo_path = app.repos.get(app.active_repo).map(|r| r.path.clone());

    let mut lines: Vec<Line> = Vec::with_capacity(h);
    const ROOT_INDENT: &str = "  ";
    for (vi, row) in rows.iter().enumerate().skip(app.tree.scroll).take(h) {
        let is_cursor = vi == cursor;
        let is_repo_row = multi_repo
            && row.is_dir
            && row.depth == 0
            && app.repos.iter().any(|r| r.path == row.path);
        let is_active_repo = is_repo_row && active_repo_path.as_ref() == Some(&row.path);
        let (glyph, icon_color) = if is_repo_row {
            if nerd {
                if row.is_expanded {
                    icons::REPO_OPEN
                } else {
                    icons::REPO_CLOSED
                }
            } else if row.is_expanded {
                icons::REPO_OPEN_ASCII
            } else {
                icons::REPO_CLOSED_ASCII
            }
        } else {
            icons::for_path(&row.path, row.is_dir, row.is_expanded, nerd)
        };
        let indent = format!("{ROOT_INDENT}{}", "  ".repeat(row.depth));
        // Split chevron + icon so the chevron renders in a muted grey
        // (VS Code / NvChad tree style) while the folder/file icon keeps
        // its devicon color.
        let (chev_part, icon_part) = if nerd && row.is_dir {
            let c = if row.is_expanded {
                CHEVRON_OPEN
            } else {
                CHEVRON_CLOSED
            };
            (format!("{indent}{c} "), format!("{glyph} "))
        } else if nerd {
            // File row — pad the chevron column with spaces so icons
            // align with sibling dir rows.
            (format!("{indent}  "), format!("{glyph} "))
        } else {
            (indent.clone(), format!("{glyph} "))
        };
        let prefix_width = chev_part.chars().count() + icon_part.chars().count();
        let git_state = if row.is_dir {
            None
        } else {
            git_files.get(&row.path).copied()
        };
        let name_color = if is_repo_row {
            theme::cur().yellow
        } else if row.is_dir {
            theme::cur().blue
        } else {
            match git_state {
                Some(FileState::Modified) => theme::cur().yellow,
                Some(FileState::Staged | FileState::Untracked) => theme::cur().green,
                Some(FileState::Conflicted) => theme::cur().red,
                None => theme::cur().fg,
            }
        };
        let bg = row_bg(is_cursor, focused, rail_bg);
        let mut name_style = Style::default().fg(name_color).bg(bg);
        if row.is_dir || (is_cursor && focused) {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        // Non-active repo dirs render slightly dimmed to make the active
        // one pop visually (matches the `●` / `○` convention).
        if is_repo_row && !is_active_repo {
            name_style = name_style.add_modifier(Modifier::DIM);
        }
        // Hidden entries (filename starts with `.`) render dimmed when
        // they're visible — only happens when `show_hidden = true`, but
        // the dim hint is useful regardless to tell users "this is a
        // dotfile / dot-dir".
        let is_hidden = row.name.starts_with('.');
        if is_hidden {
            name_style = name_style.add_modifier(Modifier::DIM);
        }
        let prefix_color = if is_repo_row {
            theme::cur().yellow
        } else if row.is_dir {
            // TEMP: yellow folder icons (test); was `theme::cur().blue`.
            // Restore the blue branch when reverting.
            theme::cur().yellow
        } else {
            icon_color
        };
        // Right-aligned 1-char git-state badge (vim-fugitive style): M / A / ? / !.
        // Reserves 2 trailing cells (`<letter> `) when there's a state to show.
        let (badge, badge_color) = match git_state {
            Some(FileState::Modified) => ("M", theme::cur().yellow),
            Some(FileState::Staged) => ("A", theme::cur().green),
            Some(FileState::Untracked) => ("?", theme::cur().green),
            Some(FileState::Conflicted) => ("!", theme::cur().red),
            None => ("", theme::cur().fg),
        };
        let badge_width = if badge.is_empty() { 0 } else { 2 };
        // Repo dirs get a leading `● ` (active) or `○ ` (non-active) marker
        // before the name — same convention the git rail uses for branches.
        // Reserves 2 cells regardless of state so name columns align across
        // active and non-active repo rows.
        let (repo_marker, repo_marker_color) = if is_repo_row {
            if is_active_repo {
                ("● ", theme::cur().green)
            } else {
                ("○ ", theme::cur().comment)
            }
        } else {
            ("", theme::cur().fg)
        };
        let repo_marker_width = repo_marker.chars().count();
        let used = prefix_width + repo_marker_width + row.name.chars().count() + badge_width;
        let pad = width.saturating_sub(used);
        let mut spans = vec![
            Span::styled(chev_part, Style::default().fg(theme::cur().comment).bg(bg)),
            Span::styled(icon_part, Style::default().fg(prefix_color).bg(bg)),
        ];
        if !repo_marker.is_empty() {
            spans.push(Span::styled(
                repo_marker,
                Style::default().fg(repo_marker_color).bg(bg),
            ));
        }
        spans.push(Span::styled(row.name.clone(), name_style));
        spans.push(Span::styled(" ".repeat(pad), Style::default().bg(bg)));
        if !badge.is_empty() {
            spans.push(Span::styled(
                format!("{badge} "),
                Style::default().fg(badge_color).bg(bg),
            ));
        }
        lines.push(Line::from(spans));
    }
    let drew = lines.len() as u16;
    frame.render_widget(Paragraph::new(lines), inner);
    // Hover preview: when the cursor's on an image row and the cache
    // is warm, paint a small card at the bottom-left of the tree area.
    // The image escape lands post-`terminal.draw()` so it covers the
    // tree text underneath — we still wipe the cells in ratatui-land
    // so they don't bleed through when the protocol clears the image.
    draw_tree_image_preview(frame, app, inner);
    start_y + drew
}

/// Paint the file-tree hover-preview card at the bottom-left of the
/// workspace tree area, if there's an active preview with PNG bytes
/// loaded. Skipped when the area is too short (<8 rows) so a narrow
/// rail doesn't lose half its tree to a thumbnail.
fn draw_tree_image_preview(frame: &mut Frame, app: &mut App, inner: Rect) {
    const CARD_W: u16 = 14;
    const CARD_H: u16 = 5; // 1 caption row + 4 image rows
    const MIN_TREE_REMAINING: u16 = 4;
    let Some(prev) = app.tree_image_preview.clone() else {
        return;
    };
    // Only paint once we've got something to show — either decoded
    // bytes or an error caption.
    if prev.png_bytes.is_none() && prev.error.is_none() {
        return;
    }
    // Don't squash the tree to less than `MIN_TREE_REMAINING` rows;
    // bail rather than push the card into the user's working area.
    if inner.height < CARD_H + MIN_TREE_REMAINING || inner.width < CARD_W {
        return;
    }
    let bg = theme::cur().bg_darker;
    let card_x = inner.x;
    let card_y = inner.y + inner.height - CARD_H;
    let card_rect = Rect {
        x: card_x,
        y: card_y,
        width: CARD_W.min(inner.width),
        height: CARD_H,
    };
    // Wipe the cells the card occupies so the tree text below the
    // workspace fold doesn't peek through under the image (the image
    // escape paints pixels, not cells; ratatui's previous-frame
    // glyphs would otherwise persist around the image edges).
    frame.render_widget(
        ratatui::widgets::Block::default().style(Style::default().bg(bg)),
        card_rect,
    );
    // Caption row: filename, truncated to fit. Errors get their own
    // line (already short by construction).
    let fname = prev
        .path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("?")
        .to_string();
    let caption_text = match &prev.error {
        Some(e) => e.clone(),
        None => {
            let max = (CARD_W as usize).saturating_sub(2);
            if fname.chars().count() > max {
                let truncated: String = fname.chars().take(max.saturating_sub(1)).collect();
                format!("{truncated}…")
            } else {
                fname
            }
        }
    };
    let caption_style = if prev.error.is_some() {
        Style::default().fg(theme::cur().red).bg(bg)
    } else {
        Style::default().fg(theme::cur().comment).bg(bg)
    };
    let caption_rect = Rect {
        x: card_rect.x,
        y: card_rect.y,
        width: card_rect.width,
        height: 1,
    };
    frame.render_widget(
        Paragraph::new(Line::from(Span::styled(caption_text, caption_style))),
        caption_rect,
    );
    // Image area is the rest of the card. Reserve the cells via an
    // empty Block (already wiped above) then push the PaintRequest;
    // the post-draw emitter writes the protocol escape, which paints
    // pixels into the reserved area.
    if let Some(png) = prev.png_bytes {
        let image_rect = Rect {
            x: card_rect.x,
            y: card_rect.y + 1,
            width: card_rect.width,
            height: card_rect.height - 1,
        };
        // Pane id is just a logging tag for the emitter — use a
        // sentinel value so it's obvious in any debugging output
        // that this came from the tree preview, not a real Pane.
        app.image_paint_requests.push(crate::image::PaintRequest {
            pane_id: usize::MAX,
            area: image_rect,
            png_bytes: png,
        });
    }
}

/// Draw one extra-workspace section starting at `start_y`. Renders a 1-row
/// blank separator + a collapsible `> name` header; if the section is
/// expanded, renders a bounded file-list slot beneath it (capped at
/// `EXTRA_TREE_MAX_ROWS` so a deep tree can't crowd out siblings + the GIT
/// section). Returns the row past the last drawn.
const EXTRA_TREE_MAX_ROWS: usize = 12;

fn draw_extra_workspace_section(
    frame: &mut Frame,
    app: &mut App,
    area: Rect,
    start_y: u16,
    ws_idx: usize,
    nerd: bool,
) -> u16 {
    let rail_bg = theme::cur().bg_darker;
    let width = area.width as usize;
    let area_end = area.y + area.height;
    if start_y + 1 >= area_end {
        return start_y;
    }
    let header_y = start_y + 1; // blank separator row above
    if header_y >= area_end {
        return start_y;
    }
    let (name, expanded) = {
        let ws = &app.extra_workspaces[ws_idx];
        (ws.name.clone(), ws.expanded)
    };
    let chev = section_chev(expanded, nerd);
    let chev_str = format!(" {chev} ");
    let used = chev_str.chars().count() + name.chars().count();
    let header_rect = Rect {
        x: area.x,
        y: header_y,
        width: area.width,
        height: 1,
    };
    let chip_spans = workspace_header_chips(app, header_rect, used, nerd, rail_bg);
    let mut spans = vec![
        Span::styled(
            chev_str,
            Style::default().fg(theme::cur().comment).bg(rail_bg),
        ),
        Span::styled(
            name.clone(),
            Style::default()
                .fg(theme::cur().fg)
                .bg(rail_bg)
                .add_modifier(Modifier::BOLD),
        ),
    ];
    spans.extend(chip_spans);
    frame.render_widget(Paragraph::new(Line::from(spans)), header_rect);
    app.rects
        .extra_workspace_toggles
        .push((header_rect, ws_idx));
    let _ = width; // width is now used inside `workspace_header_chips`.

    if !expanded {
        return header_y + 1;
    }
    let body_y = header_y + 1;
    if body_y >= area_end {
        return header_y + 1;
    }
    let avail = (area_end - body_y) as usize;
    // Reserve a bit for the GIT section that follows (4 rows = blank + header
    // + at least 2 body rows) when applicable. Cap at EXTRA_TREE_MAX_ROWS so
    // a 200-line tree can't swallow the rail.
    let h = avail.saturating_sub(4).min(EXTRA_TREE_MAX_ROWS);
    if h == 0 {
        return body_y;
    }
    let body_rect = Rect {
        x: area.x,
        y: body_y,
        width: area.width,
        height: h as u16,
    };
    app.rects.extra_workspace_bodies.push((
        body_rect,
        ws_idx,
        app.extra_workspaces[ws_idx].tree.scroll,
    ));

    // Clamp the tree's scroll so the cursor stays in view. We're not the
    // focused tree (filter mode is a primary-only feature for now), so we
    // just paint top-down with the saved scroll.
    let rows = app.extra_workspaces[ws_idx].tree.visible_rows();
    let scroll = app.extra_workspaces[ws_idx].tree.scroll;
    let max_scroll = rows.len().saturating_sub(h.min(rows.len()));
    let scroll = scroll.min(max_scroll);
    app.extra_workspaces[ws_idx].tree.scroll = scroll;

    let multi_repo = app.repos.len() > 1;
    let active_repo_path = app.repos.get(app.active_repo).map(|r| r.path.clone());

    let mut lines: Vec<Line> = Vec::with_capacity(h);
    const ROOT_INDENT: &str = "  ";
    for row in rows.iter().skip(scroll).take(h) {
        let is_repo_row = multi_repo
            && row.is_dir
            && row.depth == 0
            && app.repos.iter().any(|r| r.path == row.path);
        let is_active_repo = is_repo_row && active_repo_path.as_ref() == Some(&row.path);
        let (glyph, icon_color) = if is_repo_row {
            if nerd {
                if row.is_expanded {
                    icons::REPO_OPEN
                } else {
                    icons::REPO_CLOSED
                }
            } else if row.is_expanded {
                icons::REPO_OPEN_ASCII
            } else {
                icons::REPO_CLOSED_ASCII
            }
        } else {
            icons::for_path(&row.path, row.is_dir, row.is_expanded, nerd)
        };
        let indent = format!("{ROOT_INDENT}{}", "  ".repeat(row.depth));
        let (chev_part, icon_part) = if nerd && row.is_dir {
            let c = if row.is_expanded {
                CHEVRON_OPEN
            } else {
                CHEVRON_CLOSED
            };
            (format!("{indent}{c} "), format!("{glyph} "))
        } else if nerd {
            (format!("{indent}  "), format!("{glyph} "))
        } else {
            (indent.clone(), format!("{glyph} "))
        };
        let prefix_width = chev_part.chars().count() + icon_part.chars().count();
        let name_color = if is_repo_row {
            theme::cur().yellow
        } else if row.is_dir {
            theme::cur().blue
        } else {
            theme::cur().fg
        };
        let mut name_style = Style::default().fg(name_color).bg(rail_bg);
        if row.is_dir {
            name_style = name_style.add_modifier(Modifier::BOLD);
        }
        if is_repo_row && !is_active_repo {
            name_style = name_style.add_modifier(Modifier::DIM);
        }
        if row.name.starts_with('.') {
            name_style = name_style.add_modifier(Modifier::DIM);
        }
        let prefix_color = if is_repo_row {
            theme::cur().yellow
        } else if row.is_dir {
            // TEMP: yellow folder icons (test); was `theme::cur().blue`.
            // Restore the blue branch when reverting.
            theme::cur().yellow
        } else {
            icon_color
        };
        let (repo_marker, repo_marker_color) = if is_repo_row {
            if is_active_repo {
                ("● ", theme::cur().green)
            } else {
                ("○ ", theme::cur().comment)
            }
        } else {
            ("", theme::cur().fg)
        };
        let used = prefix_width + repo_marker.chars().count() + row.name.chars().count();
        let pad_n = width.saturating_sub(used);
        let mut spans = vec![
            Span::styled(
                chev_part,
                Style::default().fg(theme::cur().comment).bg(rail_bg),
            ),
            Span::styled(icon_part, Style::default().fg(prefix_color).bg(rail_bg)),
        ];
        if !repo_marker.is_empty() {
            spans.push(Span::styled(
                repo_marker,
                Style::default().fg(repo_marker_color).bg(rail_bg),
            ));
        }
        spans.push(Span::styled(row.name.clone(), name_style));
        spans.push(Span::styled(
            " ".repeat(pad_n),
            Style::default().bg(rail_bg),
        ));
        lines.push(Line::from(spans));
    }
    let drew = lines.len() as u16;
    frame.render_widget(Paragraph::new(lines), body_rect);
    body_y + drew
}

/// Draw the GIT section: a "branches" sub-label, the branch rows, a
/// "worktrees" sub-label, the worktree rows. Sub-labels are dim, not
/// selectable. Records click-rects in `app.rects.git_rail_rows`.
fn draw_git_section(frame: &mut Frame, app: &mut App, area: Rect, start_y: u16, _nerd: bool) {
    let rail_bg = theme::cur().bg_darker;
    let width = area.width as usize;
    let avail = (area.y + area.height).saturating_sub(start_y) as usize;
    if avail == 0 {
        return;
    }
    let focused = app.focus == Focus::Tree && app.rail_section == RailSection::Git;
    let cursor_row = app.git_rail.cursor;
    let nb = app.git_rail.branches.len();

    let mut lines: Vec<Line> = Vec::with_capacity(avail);
    let mut row_y = start_y;
    let mut row_count_drawn: usize = 0; // counts only selectable rows
    const INDENT: &str = "  ";

    // ── branches sub-section ──
    if !app.git_rail.branches.is_empty() {
        // Sub-label (dim, not selectable).
        push_sublabel(&mut lines, "branches", width, rail_bg);
        row_y += 1;
        if (row_y - area.y) as usize >= avail {
            frame.render_widget(Paragraph::new(lines), git_body_rect(area, start_y));
            return;
        }
        // Cap to `BRANCH_LIST_CAP` when collapsed so a 100-branch
        // monorepo doesn't drown the rail; user clicks the trailing
        // `+ N more` row to expand.
        let total_branches = app.git_rail.branches.len();
        let cap = if app.git_branches_expanded {
            total_branches
        } else {
            total_branches.min(BRANCH_LIST_CAP)
        };
        let always_show_current = !app.git_branches_expanded && total_branches > BRANCH_LIST_CAP;
        for (i, br) in app.git_rail.branches.iter().enumerate() {
            if (row_y - area.y) as usize >= avail {
                break;
            }
            // When collapsed: render first `cap` branches PLUS the
            // current branch (if it'd otherwise be hidden) so the
            // user never loses sight of where they are.
            let in_cap = i < cap;
            let force_show = always_show_current && br.is_current && !in_cap;
            if !in_cap && !force_show {
                continue;
            }
            let is_cur_row = row_count_drawn == cursor_row;
            let bg = row_bg(is_cur_row, focused, rail_bg);
            let marker = if br.is_current { "●" } else { "○" };
            let marker_color = if br.is_current {
                theme::cur().green
            } else {
                theme::cur().fg
            };
            let name = &br.name;
            let prefix = format!("{INDENT}{marker} ");
            let used = prefix.chars().count() + name.chars().count();
            let pad = width.saturating_sub(used);
            let mut name_style = Style::default().fg(theme::cur().fg).bg(bg);
            if br.is_current {
                name_style = name_style.add_modifier(Modifier::BOLD);
            }
            lines.push(Line::from(vec![
                Span::styled(prefix, Style::default().fg(marker_color).bg(bg)),
                Span::styled(name.clone(), name_style),
                Span::styled(" ".repeat(pad), Style::default().bg(bg)),
            ]));
            app.rects.git_rail_rows.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                GitRailHit::Branch(i),
            ));
            row_y += 1;
            row_count_drawn += 1;
        }
        // `+ N more` / `show less` toggle row (only when there's
        // something to toggle).
        if total_branches > BRANCH_LIST_CAP && (row_y - area.y) as usize <= avail {
            let toggle_text = if app.git_branches_expanded {
                "  show less".to_string()
            } else {
                format!("  + {} more", total_branches - cap)
            };
            let pad = width.saturating_sub(toggle_text.chars().count());
            lines.push(Line::from(vec![
                Span::styled(
                    toggle_text,
                    Style::default()
                        .fg(theme::cur().comment)
                        .bg(rail_bg)
                        .add_modifier(Modifier::ITALIC),
                ),
                Span::styled(" ".repeat(pad), Style::default().bg(rail_bg)),
            ]));
            app.rects.git_rail_rows.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                GitRailHit::ToggleBranches,
            ));
            row_y += 1;
        }
    }

    // ── worktrees sub-section ──
    if !app.git_rail.worktrees.is_empty() && ((row_y - area.y) as usize) < avail {
        push_sublabel(&mut lines, "worktrees", width, rail_bg);
        row_y += 1;
        for (i, wt) in app.git_rail.worktrees.iter().enumerate() {
            if (row_y - area.y) as usize >= avail {
                break;
            }
            let row_idx = nb + i;
            let is_cur_row = row_idx == cursor_row;
            let bg = row_bg(is_cur_row, focused, rail_bg);
            let marker = if wt.is_current { "⤿" } else { "·" };
            let marker_color = if wt.is_current {
                theme::cur().yellow
            } else {
                theme::cur().fg
            };
            let label = if wt.label.is_empty() {
                "(detached)".to_string()
            } else {
                wt.label.clone()
            };
            let dir = wt
                .path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("?")
                .to_string();
            let shown = if label == dir || label.starts_with('(') {
                label.clone()
            } else {
                format!("{label} ({dir})")
            };
            let prefix = format!("{INDENT}{marker} ");
            let used = prefix.chars().count() + shown.chars().count();
            let pad = width.saturating_sub(used);
            let mut name_style = Style::default().fg(theme::cur().fg).bg(bg);
            if wt.is_current {
                name_style = name_style.add_modifier(Modifier::BOLD);
            }
            lines.push(Line::from(vec![
                Span::styled(prefix, Style::default().fg(marker_color).bg(bg)),
                Span::styled(shown, name_style),
                Span::styled(" ".repeat(pad), Style::default().bg(bg)),
            ]));
            app.rects.git_rail_rows.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                GitRailHit::Worktree(i),
            ));
            row_y += 1;
        }
    }

    // ── pulls sub-section (open PRs / MRs for the current repo) ──
    if !app.git_rail.pulls.is_empty() && ((row_y - area.y) as usize) < avail {
        push_sublabel(&mut lines, "open prs", width, rail_bg);
        row_y += 1;
        let nb_and_nw = nb + app.git_rail.worktrees.len();
        for (i, pr) in app.git_rail.pulls.iter().enumerate() {
            if (row_y - area.y) as usize >= avail {
                break;
            }
            let row_idx = nb_and_nw + i;
            let is_cur_row = row_idx == cursor_row;
            let bg = row_bg(is_cur_row, focused, rail_bg);
            // Pick a per-host color so the glyph telegraphs which host the
            // PR came from.
            let host_color = match pr.host_tag {
                "BB" => theme::cur().blue,
                "GH" => theme::cur().fg,
                "GL" => theme::cur().orange,
                "AZ" => theme::cur().cyan,
                _ => theme::cur().fg,
            };
            // The branch-marker convention: ● for the PR on the current branch,
            // ○ otherwise — mirrors the branches sub-section.
            let marker = if pr.is_current_branch { "●" } else { "○" };
            // Truncate the title hard so wide titles don't blow out the row.
            let avail_for_title =
                width.saturating_sub(2 + 1 + 1 + pr.number_label.chars().count() + 1);
            let title_disp = truncate_chars(&pr.title, avail_for_title);
            let prefix = format!("  {marker} ");
            let head = format!("{} ", pr.number_label);
            let used = prefix.chars().count() + head.chars().count() + title_disp.chars().count();
            let pad = width.saturating_sub(used);
            let mut title_style = Style::default().fg(theme::cur().fg).bg(bg);
            if pr.is_current_branch {
                title_style = title_style.add_modifier(Modifier::BOLD);
            }
            lines.push(Line::from(vec![
                Span::styled(prefix, Style::default().fg(host_color).bg(bg)),
                Span::styled(head, Style::default().fg(host_color).bg(bg)),
                Span::styled(title_disp, title_style),
                Span::styled(" ".repeat(pad), Style::default().bg(bg)),
            ]));
            app.rects.git_rail_rows.push((
                Rect {
                    x: area.x,
                    y: row_y,
                    width: area.width,
                    height: 1,
                },
                GitRailHit::Pull(i),
            ));
            row_y += 1;
        }
    }

    if app.git_rail.is_empty() {
        // Friendly placeholder so the user sees the section even outside a repo.
        push_sublabel(&mut lines, "no git repo here", width, rail_bg);
    }

    let body = git_body_rect(area, start_y);
    frame.render_widget(Paragraph::new(lines), body);
}

fn truncate_chars(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    let count = s.chars().count();
    if count <= max {
        return s.to_string();
    }
    if max <= 1 {
        return s.chars().take(max).collect();
    }
    let mut out: String = s.chars().take(max - 1).collect();
    out.push('…');
    out
}

fn git_body_rect(area: Rect, start_y: u16) -> Rect {
    Rect {
        x: area.x,
        y: start_y,
        width: area.width,
        height: area.height.saturating_sub(start_y - area.y),
    }
}

fn push_sublabel(lines: &mut Vec<Line>, text: &str, width: usize, bg: ratatui::style::Color) {
    let s = format!("  {text}");
    let pad = width.saturating_sub(s.chars().count());
    lines.push(Line::from(vec![
        Span::styled(s, Style::default().fg(theme::cur().comment).bg(bg)),
        Span::styled(" ".repeat(pad), Style::default().bg(bg)),
    ]));
}

fn row_bg(is_cursor: bool, focused: bool, rail_bg: ratatui::style::Color) -> ratatui::style::Color {
    if is_cursor {
        if focused {
            theme::cur().bg2
        } else {
            theme::cur().bg
        }
    } else {
        rail_bg
    }
}

/// True when mnml was launched without a real workspace — its
/// workspace path equals the OS home directory. Triggers the
/// vscode-style empty-state panel in the file tree area so the
/// rail doesn't show the user's entire $HOME as if it were a
/// project.
fn is_empty_workspace(app: &App) -> bool {
    let Some(home) = std::env::var_os("HOME") else {
        return false;
    };
    let home = std::path::PathBuf::from(home);
    // Canonicalize both sides — `app.workspace` is already canonical
    // (set via canonicalize() at launch / add_workspace_runtime), so
    // we only have to canonicalize $HOME to match.
    let home_c = std::fs::canonicalize(&home).unwrap_or(home);
    app.workspace == home_c
}

/// Paint the vscode-style empty-state panel into `inner`. Lines:
///   No workspace open
///   (blank)
///   ▸ Open file…       (registers a click rect → view.discovery)
///   ▸ Open folder…     (registers a click rect → view.add_workspace)
fn draw_empty_workspace_state(frame: &mut Frame, app: &mut App, inner: Rect) {
    let t = theme::cur();
    let rail_bg = t.bg_darker;

    // Build the action list. Include "Open default workspace" only
    // when one is configured and it's a different path than the
    // current (empty) workspace — otherwise the entry would be a
    // no-op.
    let mut lines: Vec<(String, Option<&'static str>, ratatui::style::Color)> = vec![
        ("No workspace open".to_string(), None, t.comment),
        (String::new(), None, t.comment),
        ("▸ Open file…".to_string(), Some("view.discovery"), t.fg),
        (
            "▸ Open folder…".to_string(),
            Some("view.add_workspace"),
            t.fg,
        ),
    ];
    if let Some(dw) = &app.config.default_workspace
        && dw != &app.workspace
    {
        let label = dw
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| dw.to_string_lossy().into_owned());
        lines.push((
            format!("▸ Open default workspace ({label})"),
            Some("view.open_default_workspace"),
            t.fg,
        ));
    }

    for (i, (text, cmd, color)) in lines.iter().enumerate() {
        let y = inner.y + i as u16;
        if y >= inner.y + inner.height {
            break;
        }
        let row = Rect {
            x: inner.x,
            y,
            width: inner.width,
            height: 1,
        };
        let style = Style::default().fg(*color).bg(rail_bg);
        let para_text = format!(" {text}");
        frame.render_widget(
            Paragraph::new(Line::from(Span::styled(para_text, style)))
                .style(Style::default().bg(rail_bg)),
            row,
        );
        if let Some(cmd_id) = cmd {
            app.rects.tree_icon_buttons.push((row, *cmd_id));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Render-assertion: paint the rail into a `TestBackend` and check
    /// that the workspace's files actually land in the file tree.
    #[test]
    fn draw_paints_workspace_files() {
        use ratatui::Terminal;
        use ratatui::backend::TestBackend;

        let d = tempfile::tempdir().unwrap();
        let ws = d.path().to_path_buf();
        // Create the files before App::new so the tree picks them up.
        std::fs::write(ws.join("alpha.txt"), "a\n").unwrap();
        std::fs::write(ws.join("beta.txt"), "b\n").unwrap();
        let mut app = App::new(ws.clone(), crate::config::Config::default()).unwrap();

        let mut term = Terminal::new(TestBackend::new(32, 24)).unwrap();
        term.draw(|f| draw(f, &mut app, f.area())).unwrap();
        let buf = term.backend().buffer();
        let mut screen = String::new();
        for y in 0..buf.area.height {
            for x in 0..buf.area.width {
                screen.push_str(buf[(x, y)].symbol());
            }
            screen.push('\n');
        }
        assert!(
            screen.contains("alpha.txt"),
            "tree missing alpha.txt:\n{screen}"
        );
        assert!(
            screen.contains("beta.txt"),
            "tree missing beta.txt:\n{screen}"
        );
    }
}
