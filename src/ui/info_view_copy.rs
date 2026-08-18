//! Curated Info View copy — one entry per hover target.
//!
//! Seed set for Phase 1 alpha: ~10 entries covering the highest-hover
//! chrome + a couple examples per target class. The copy-writer agent
//! (see `.claude/agents/info-view-writer.md`, coming next) walks the
//! full 229 `HoverChip` variants + menu inventory + tree row classes
//! and fills in the remaining ~500 entries against the shape here.
//!
//! Style rules (see `docs/design/info-view-v0.3.md` §Voice guide for
//! the full guide):
//!
//! - Title = noun phrase, never a verb form. `"Vim insert mode"` /
//!   `"Claude Code session"`, not `"You are in insert mode"`.
//! - Body = 2-4 sentences, plain English, no jargon a non-power-user
//!   wouldn't recognise from context.
//! - Shortcuts list the 1-3 chords a user hovering THIS thing would
//!   most want to know. Not every chord that touches the target.
//! - `try_it` is 0-2 palette commands the reader might fire while
//!   hovering — actions, not navigation.

use crate::AgentsPanelChipKind;
use crate::DiffToolbarAction;
use crate::GitRailHeaderAction;
use crate::GutterMarkKind;
use crate::RequestTopBarChip as ReqChip;
use crate::app::App;
use crate::ui::TopbarChipKind;
use crate::ui::info_view::{InfoViewCopy, InfoViewTarget, PaletteLink, ShortcutHint};

/// Look up the curated copy for `target`. Returns `None` when nothing
/// matches — caller falls through to the auto-derived placeholder
/// (Phase 1.5) or empty-state copy.
pub fn lookup(app: &App, target: &InfoViewTarget) -> Option<InfoViewCopy> {
    match target {
        // Task #929 — a `MenuBarItem` chip resolves its (menu_idx,
        // item_idx) to real labels via `menu_bar::bar(app)`, then
        // delegates to the curated `menu_item_copy` map. If no
        // curated entry exists, fall back to a generic per-item
        // placeholder so hovering an uncurated menu row still
        // describes what it is (not "no help — falls through to
        // pane"). Handled before the generic `Chip` arm so it
        // wins over `chip_copy`.
        InfoViewTarget::Chip(crate::HoverChip::MenuBarItem { menu_idx, item_idx }) => {
            resolve_menu_bar_item_copy(app, *menu_idx, *item_idx)
        }
        // Task #946 — a hovered bufferline tab that belongs to a Pty
        // pane deserves richer copy than the generic "one tab per
        // open pane" — mention the terminal implementation
        // (libghostty-vt) and the user's `terminal_label` if set.
        InfoViewTarget::Chip(crate::HoverChip::BufferlineTab(pid))
            if matches!(app.panes.get(*pid), Some(crate::pane::Pane::Pty(_))) =>
        {
            Some(pty_tab_copy(app))
        }
        // User feedback 2026-08-17 — a hovered activity-bar icon that
        // maps to a pinned integration deserves the integration's own
        // title/description instead of the generic "one of the sections"
        // copy. Same for the two side-panel toggle chips (IntegrationIcon
        // in the palette bar) — surface the specific integration.
        InfoViewTarget::Chip(crate::HoverChip::ActivityBarIcon(section)) => {
            activity_bar_section_copy(app, *section)
                .or_else(|| chip_copy(crate::HoverChip::ActivityBarIcon(*section)))
        }
        InfoViewTarget::Chip(crate::HoverChip::IntegrationIcon(idx)) => {
            integration_icon_copy(app, *idx)
                .or_else(|| chip_copy(crate::HoverChip::IntegrationIcon(*idx)))
        }
        // 2026-08-17 — manifest-declared dynamic statusline chips.
        // Copy is pulled from the source `[[statusline_segments]]`
        // block's `tooltip` field; a click-command hint lands in
        // the "try_it" row so the reader sees what fires.
        InfoViewTarget::Chip(crate::HoverChip::StatuslineSegment(idx)) => {
            statusline_segment_copy(app, *idx)
        }
        InfoViewTarget::Chip(chip) => chip_copy(*chip),
        InfoViewTarget::TreeRow { label, is_dir } => tree_row_copy(label, *is_dir),
        InfoViewTarget::MenuItem { menu, item } => menu_item_copy(menu, item),
        InfoViewTarget::EditorSymbol { .. } => None,
        InfoViewTarget::None => None,
    }
}

/// Decode `(menu_idx, item_idx)` — with the encoded submenu shape
/// used in `ui/menu_bar.rs` (`1000 + parent*100 + sub` for submenu
/// rows) — into `(menu_label, item_label)` pulled from
/// `menu_bar::bar(app)`, then hand off to `menu_item_copy`. If no
/// curated entry exists, return a generic per-item placeholder so
/// the info panel still describes the hovered row.
fn resolve_menu_bar_item_copy(app: &App, menu_idx: usize, encoded: usize) -> Option<InfoViewCopy> {
    use crate::menu_bar::MenuItem;
    let menus = crate::menu_bar::bar(app);
    let menu = menus.get(menu_idx)?;
    let menu_label = menu.label.trim().to_string();
    let (parent_label, item_label) = if encoded >= 1000 {
        // Submenu row: `1000 + parent*100 + sub`.
        let parent = (encoded - 1000) / 100;
        let sub = (encoded - 1000) % 100;
        let parent_item = menu.items.get(parent)?;
        let (parent_lbl, sub_items) = match parent_item {
            MenuItem::Submenu { label, items, .. } => (Some(label.clone()), items),
            _ => return None,
        };
        let sub_item = sub_items.get(sub)?;
        let sub_lbl = match sub_item {
            MenuItem::Action { label, .. } | MenuItem::Submenu { label, .. } => label.clone(),
            MenuItem::Separator => return None,
        };
        (parent_lbl, sub_lbl)
    } else {
        let item = menu.items.get(encoded)?;
        let item_lbl = match item {
            MenuItem::Action { label, .. } | MenuItem::Submenu { label, .. } => label.clone(),
            MenuItem::Separator => return None,
        };
        (None, item_lbl)
    };
    // Curated lookup keys on the top-level menu label — that's
    // what `menu_item_copy`'s match arms use today.
    if let Some(curated) = menu_item_copy(&menu_label, &item_label) {
        return Some(curated);
    }
    // Fallback: friendly title + "click or Enter to fire". For
    // submenu rows include the parent-item label in the title
    // (e.g. "View → Zoom → Zoom in") so context isn't lost.
    let clean_item = item_label.trim();
    let title = match &parent_label {
        Some(p) => format!("{menu_label} → {} → {clean_item}", p.trim()),
        None => format!("{menu_label} → {clean_item}"),
    };
    Some(InfoViewCopy {
        title,
        body: "Menu item. Click or press Enter to fire its command.".into(),
        shortcuts: vec![ShortcutHint::new("Enter", "Fire")],
        ..Default::default()
    })
}

// Task #946 — Pty tab hover copy. Emitted from `lookup` when the
// hovered bufferline tab belongs to a `Pane::Pty`. Names the
// terminal implementation (libghostty-vt — Ghostty's VT engine,
// used since 2026-06 when mnml swapped away from vt100) and
// surfaces the user's rebrand label if they've set one. The
// generic BufferlineTab arm still handles editor / integration
// tabs — no regression there.
fn pty_tab_copy(app: &App) -> InfoViewCopy {
    let brand = app.config.ui.terminal_label.trim();
    let brand_line = if brand.is_empty() || brand.eq_ignore_ascii_case("terminal") {
        String::new()
    } else {
        format!(" You've rebranded this to \"{brand}\" (change: Terminal menu → Rename terminal…).")
    };
    InfoViewCopy {
        title: "Terminal (Pty) tab".into(),
        body: format!(
            "A running shell hosted inside mnml, driven by the libghostty-vt \
             VT engine (Ghostty's cross-platform terminal emulator library). \
             Click to focus; middle-click closes; drag to reorder. Panes \
             render at ~120 FPS and honor sixel/kitty image protocols where \
             the outer terminal supports them.{brand_line}"
        ),
        shortcuts: vec![
            ShortcutHint::new("Ctrl+PgUp/PgDn", "Prev / next buffer"),
            ShortcutHint::new("Ctrl+W", "Close active buffer"),
        ],
        ..Default::default()
    }
}

/// User feedback 2026-08-17 — activity-bar section hover-help. The
/// generic `chip_copy` arm just said "one of the sections that shares
/// the left panel"; the user complained that hovering pinned
/// integration icons on the activity bar didn't tell them which
/// integration was under the cursor. Now dispatches per-section
/// (Files / Git / Debug / etc.) and per-integration for
/// `LauncherIcon(idx)` — inspects
/// `config.ui.activity_bar_pinned_integrations` to resolve the pinned
/// id, then looks up the matching `IntegrationIcon` for its label +
/// description + homepage.
fn activity_bar_section_copy(
    app: &App,
    section: crate::app::ActivitySection,
) -> Option<InfoViewCopy> {
    use crate::app::ActivitySection;
    match section {
        ActivitySection::LauncherIcon(idx) => {
            let id = app
                .config
                .ui
                .activity_bar_pinned_integrations
                .get(idx as usize)?;
            let icon = app
                .config
                .ui
                .integration_icons
                .iter()
                .find(|i| &i.id == id)?;
            let title = icon.label.clone().unwrap_or_else(|| icon.id.clone());
            let body = icon.description.clone().unwrap_or_else(|| {
                format!(
                    "Pinned integration `{id}`. Click to launch — runs `{cmd}`. \
                     Right-click the chip in the palette bar to unpin or configure.",
                    id = icon.id,
                    cmd = icon.command,
                )
            });
            let mut try_it = Vec::new();
            if !icon.command.is_empty() {
                try_it.push(PaletteLink::new(icon.command.clone(), "Launch"));
            }
            Some(InfoViewCopy {
                title,
                body,
                try_it,
                docs: icon.docs.clone().or_else(|| icon.homepage.clone()),
                ..Default::default()
            })
        }
        ActivitySection::Mount(idx) => {
            // Mounted integration side-panel — hosted by `mount_manifests`
            // (populated by dynamically-mounted integrations), not the
            // static `activity_bar_pinned_integrations` list.
            let m = app.mount_manifests.get(idx as usize)?;
            let icon = app
                .config
                .ui
                .integration_icons
                .iter()
                .find(|i| i.id == m.id);
            let title = icon
                .and_then(|i| i.label.clone())
                .unwrap_or_else(|| m.id.clone());
            let title = format!("{title} (side panel)");
            let body = icon.and_then(|i| i.description.clone()).unwrap_or_else(|| {
                format!(
                    "Integration `{id}` mounted as an activity-bar side panel. \
                         Click to focus its rail; right-click for unmount / configure.",
                    id = m.id,
                )
            });
            Some(InfoViewCopy {
                title,
                body,
                docs: icon.and_then(|i| i.docs.clone().or_else(|| i.homepage.clone())),
                ..Default::default()
            })
        }
        // 2026-08-18 (#969) — per-section copy for the built-in
        // activity-bar sections. Previously fell through to
        // chip_copy's generic "one of the sections" placeholder;
        // now each shipped section explains what it does + surfaces
        // the palette command that focuses it.
        ActivitySection::Explorer => Some(InfoViewCopy {
            title: "Files (explorer)".into(),
            body: "File tree for the active workspace + secondary git / integrations \
                   sections stacked below. Cmd+P opens fuzzy pick; right-click a row \
                   for cut/copy/paste/rename/new-in-here."
                .into(),
            try_it: vec![
                PaletteLink::new("view.activity_explorer", "Focus files"),
                PaletteLink::new("picker.files", "Fuzzy open"),
            ],
            docs: Some("https://mnml.sh/manual/tree/".into()),
            ..Default::default()
        }),
        ActivitySection::Git => Some(InfoViewCopy {
            title: "Git (branch + worktrees)".into(),
            body: "Dedicated git view — branch list, worktrees, log preview, and \
                   stash actions. The compact GIT strip inside Explorer is a \
                   subset of what shows here."
                .into(),
            try_it: vec![PaletteLink::new("view.activity_git", "Focus git")],
            docs: Some("https://mnml.sh/manual/git/".into()),
            ..Default::default()
        }),
        ActivitySection::Integrations => Some(InfoViewCopy {
            title: "Integrations".into(),
            body: "Installed integration list on top, Marketplace tab below. Each \
                   installed row shows its chip glyph + label; right-click to \
                   configure / uninstall / open sibling settings pane."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.activity_integrations",
                "Focus integrations",
            )],
            docs: Some("https://mnml.sh/manual/integrations/".into()),
            ..Default::default()
        }),
        ActivitySection::Agents => Some(InfoViewCopy {
            title: "Agents (Claude / Codex sessions)".into(),
            body: "Cross-workspace dashboard of your Claude Code + Codex CLI \
                   sessions. Rows grouped by status (Action Needed / Running / \
                   Done). Filter input at top; + New starts a fresh session."
                .into(),
            try_it: vec![PaletteLink::new("view.activity_agents", "Focus agents")],
            docs: Some("https://mnml.sh/manual/agents/".into()),
            ..Default::default()
        }),
        ActivitySection::Sessions => Some(InfoViewCopy {
            title: "Sessions (open Pty tabs)".into(),
            body: "Vertical-tab strip of open Pty panes (Claude, Codex, shell). \
                   Each row shows session name + git branch + cwd + notification \
                   ring when there's unread output. Click a row to focus that pane."
                .into(),
            try_it: vec![PaletteLink::new("view.activity_sessions", "Focus sessions")],
            ..Default::default()
        }),
        ActivitySection::Http => Some(InfoViewCopy {
            title: "HTTP requests".into(),
            body: "One row per `.http` / `.curl` / `.rest` file in the workspace, \
                   plus RECENT / CAPTURED / ENVS / CHAINS / MOCKS / COLLECTIONS \
                   sections. `/` filters, `+ New request` scaffolds a fresh file."
                .into(),
            try_it: vec![PaletteLink::new("view.activity_http", "Focus HTTP")],
            docs: Some("https://mnml.sh/manual/http/".into()),
            ..Default::default()
        }),
        ActivitySection::Findings => Some(InfoViewCopy {
            title: "Findings (.mnml/findings/*.md)".into(),
            body: "Viewer for bug-hunt / tester-round finding markdown files in \
                   `<workspace>/.mnml/findings/`. Each finding renders as a \
                   scrollable entry with severity + reproduction steps."
                .into(),
            try_it: vec![PaletteLink::new("view.activity_findings", "Focus findings")],
            ..Default::default()
        }),
        ActivitySection::Search => Some(InfoViewCopy {
            title: "Search (workspace-wide)".into(),
            body: "Ripgrep-backed content search across the workspace. Type to \
                   filter; Enter opens the hit in the editor."
                .into(),
            try_it: vec![PaletteLink::new("view.activity_search", "Focus search")],
            ..Default::default()
        }),
        ActivitySection::Debug => Some(InfoViewCopy {
            title: "Debug (DAP)".into(),
            body: "Debug Adapter Protocol view — breakpoints, call stack, \
                   variables. Wire a DAP adapter via `[dap]` in the config."
                .into(),
            try_it: vec![PaletteLink::new("view.activity_debug", "Focus debug")],
            ..Default::default()
        }),
        ActivitySection::CloudAgents => Some(InfoViewCopy {
            title: "Cloud Agents (ECS)".into(),
            body: "Cloud-side agents dashboard — ECS runner rows and any \
                   future cloud bots. Separated from local Agents because \
                   the affordances differ: Copy runId / Open CloudWatch / \
                   view remote logs instead of resume-in-pty."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.activity_cloud_agents",
                "Focus cloud agents",
            )],
            ..Default::default()
        }),
        ActivitySection::Notes => Some(InfoViewCopy {
            title: "Notes (.mnml/notes/*.md)".into(),
            body: "One row per note file in `<workspace>/.mnml/notes/`. \
                   `+ New note` scaffolds a fresh file; `/` filters; Enter \
                   opens the note in an editor pane."
                .into(),
            try_it: vec![
                PaletteLink::new("view.activity_notes", "Focus notes"),
                PaletteLink::new("notes.new", "New note"),
            ],
            ..Default::default()
        }),
        ActivitySection::Todos => Some(InfoViewCopy {
            title: "TODOs (workspace grep)".into(),
            body: "Ripgrep-backed sweep for `TODO`/`FIXME`/`HACK` comments \
                   across the workspace, grouped by file. Refresh chip \
                   re-runs the scan; `/` filters; Enter jumps to the hit."
                .into(),
            try_it: vec![
                PaletteLink::new("view.activity_todos", "Focus TODOs"),
                PaletteLink::new("todos.refresh", "Refresh scan"),
            ],
            ..Default::default()
        }),
    }
}

/// Info-panel copy for a dynamic statusline chip declared via a
/// `[[statusline_segments]]` block in an integration manifest.
/// Also handles the IPC-driven variant (sibling call to
/// `statusline_set_segment`) as a graceful fallback with a
/// generic "click to fire <cmd>" body. 2026-08-17.
fn statusline_segment_copy(app: &App, idx: usize) -> Option<InfoViewCopy> {
    let (_, seg_id) = app.rects.statusline_segment_hits.get(idx)?;
    // Search the loaded manifests for a matching [[statusline_segments]]
    // block. When found, title = manifest label + segment id, body =
    // manifest tooltip (or a generated one from the format string).
    for m in &app.integration_manifests {
        if let Some(seg) = m.statusline_segments.iter().find(|s| &s.id == seg_id) {
            let title = format!("{} — {}", m.label, seg.id);
            let body = seg.tooltip.clone().unwrap_or_else(|| {
                format!(
                    "Data-driven statusline chip declared by `{}`. Format: `{}`; \
                     source: `{}`.",
                    m.id, seg.format, seg.source
                )
            });
            let mut try_it: Vec<PaletteLink> = Vec::new();
            if let Some(cmd) = seg.click_command.as_deref() {
                try_it.push(PaletteLink::new(cmd.to_string(), "Fire click command"));
            }
            return Some(InfoViewCopy {
                title,
                body,
                try_it,
                docs: m.docs.clone().or_else(|| m.homepage.clone()),
                ..Default::default()
            });
        }
    }
    // IPC-set fallback — no manifest match; describe from the
    // live `DynamicSegment` slot only.
    let d = app.dynamic_segments.iter().find(|d| &d.id == seg_id)?;
    let title = format!("Sibling chip · {}", d.id);
    let body = format!(
        "A statusline chip set at runtime by a sibling via the mnml-bridge \
         `statusline_set_segment` API (id `{}`).",
        d.id
    );
    let try_it = d
        .click_command
        .as_ref()
        .map(|c| vec![PaletteLink::new(c.clone(), "Fire click command")])
        .unwrap_or_default();
    Some(InfoViewCopy {
        title,
        body,
        try_it,
        ..Default::default()
    })
}

/// Integration-chip hover copy (palette-bar variant). Same lookup as
/// `activity_bar_section_copy`'s LauncherIcon branch but scoped to
/// the palette-bar chip index (which is a direct index into
/// `config.ui.integration_icons`, not the pinned-integration list).
fn integration_icon_copy(app: &App, idx: usize) -> Option<InfoViewCopy> {
    let icon = app.config.ui.integration_icons.get(idx)?;
    let title = icon.label.clone().unwrap_or_else(|| icon.id.clone());
    let body = icon.description.clone().unwrap_or_else(|| {
        format!(
            "Integration `{id}` — click to launch (`{cmd}`); right-click for \
             configure / remove / disable. Add or remove from the palette bar \
             via right-click → \"Show in palette bar\".",
            id = icon.id,
            cmd = icon.command,
        )
    });
    Some(InfoViewCopy {
        title,
        body,
        docs: icon.docs.clone().or_else(|| icon.homepage.clone()),
        ..Default::default()
    })
}

// ── Chrome chips ────────────────────────────────────────────────────

fn chip_copy(chip: crate::HoverChip) -> Option<InfoViewCopy> {
    use crate::HoverChip::*;
    match chip {
        StatuslineMode => Some(InfoViewCopy {
            title: "Editor mode indicator".into(),
            body: "The current input handler's mode — NORMAL / INSERT / VISUAL / \
                   REPLACE for vim, or blank in standard mode. Also shows the \
                   focus scope when it's not on an editor pane (TREE / RIGHT / \
                   BOTTOM)."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Esc", "Leave the current mode (vim)"),
                ShortcutHint::new("Ctrl+E", "Cycle keyboard focus across panels"),
            ],
            try_it: vec![PaletteLink::new(
                "editor.toggle_keymap",
                "Swap vim ↔ standard input",
            )],
            docs: Some("https://mnml.sh/manual/statusline-chrome/".into()),
            ..Default::default()
        }),
        StatuslineBranch => Some(InfoViewCopy {
            title: "Active git branch".into(),
            body: "The branch checked out in the active repo, with unpushed / \
                   uncommitted counts appended. Click to open the branch picker."
                .into(),
            aside: Some(
                "In a multi-repo workspace, this tracks whichever repo owns the \
                 active pane's file."
                    .into(),
            ),
            // Drift fix (2026-08-11): `Ctrl+Shift+B` is bound to
            // `view.toggle_right_panel`, not the branch picker.
            // `git.branch_menu` has no chord — click-only for now.
            try_it: vec![PaletteLink::new("git.branch_menu", "Switch branch")],
            docs: Some("https://mnml.sh/manual/git/".into()),
            ..Default::default()
        }),
        StatuslineWrap => Some(InfoViewCopy {
            title: "Line-wrap toggle".into(),
            body: "Visual-wraps long lines at the pane's right edge. When on, \
                   horizontal scroll is forced to 0. Click to toggle; the setting \
                   persists across restarts."
                .into(),
            shortcuts: vec![ShortcutHint::new(":set wrap", "Turn wrap on")],
            try_it: vec![PaletteLink::new("view.toggle_wrap", "Toggle line wrap")],
            ..Default::default()
        }),
        StatuslineAiClaude => Some(InfoViewCopy {
            title: "Claude usage meter".into(),
            body: "Current 5-hour window's Claude quota (percent used, reset time). \
                   Hover to see the full breakdown as a rich tooltip. Click to pin \
                   the panel open."
                .into(),
            aside: Some(
                "Chip goes red at 100% — sessions still run but new turns queue \
                 until the window resets; re-link if it reads 0% for a linked \
                 account."
                    .into(),
            ),
            shortcuts: vec![ShortcutHint::new("Esc", "Dismiss pinned panel")],
            try_it: vec![
                PaletteLink::new("ai.claude_usage", "Open the Claude usage pane"),
                PaletteLink::new("ai.link_claude_token", "Re-link Claude token"),
            ],
            ..Default::default()
        }),
        StatuslineAiCodex => Some(InfoViewCopy {
            title: "Codex activity indicator".into(),
            body: "Live count of active Codex sessions. Click to open the Codex \
                   usage pane (tokens + sessions today)."
                .into(),
            try_it: vec![
                PaletteLink::new("ai.codex_usage", "Open the Codex usage pane"),
                PaletteLink::new("ai.dashboard", "Open agents dashboard"),
            ],
            ..Default::default()
        }),
        StatuslineWorkspace => Some(InfoViewCopy {
            title: "Active workspace".into(),
            body: "The root folder mnml is scoped to. When multiple workspaces are \
                   open, this shows the one containing the active pane's file."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+O", "Switch workspace")],
            try_it: vec![PaletteLink::new(
                "view.switch_workspace",
                "Open workspace picker",
            )],
            ..Default::default()
        }),
        StatuslineClock => Some(InfoViewCopy {
            title: "Wall clock".into(),
            body: "Local time (or UTC if the trailing Z is showing). Click to \
                   toggle local ↔ UTC. Rendered from the render loop, so it lags \
                   at most one render tick."
                .into(),
            try_it: vec![PaletteLink::new("clock.menu", "Toggle UTC / hide clock")],
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_stress_meter
        StatuslineStress => Some(InfoViewCopy {
            title: "Render stress meter".into(),
            body: "4-block bar that fills as p95 frame render time climbs. \
                   Full bar means mnml is spending more than one frame per redraw \
                   — usually a giant buffer or a hot LSP. Hover for the numbers."
                .into(),
            aside: Some("Twin of the meter in the top-right cluster.".into()),
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_stress_meter (top-right variant)
        PaletteStress => Some(InfoViewCopy {
            title: "Render stress meter".into(),
            body: "Mirror of the statusline stress meter, in the top-right \
                   chrome cluster. Fills as p95 frame time climbs. Hover for \
                   the raw numbers."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_lsp_chip
        StatuslineLsp => Some(InfoViewCopy {
            title: "LSP status".into(),
            body: "Diagnostics count for the active buffer's LSP server — \
                   errors and warnings only. Click to open the diagnostics pane."
                .into(),
            try_it: vec![PaletteLink::new("lsp.diagnostics", "Open diagnostics")],
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_autosave_chip
        StatuslineAutosave => Some(InfoViewCopy {
            title: "Autosave indicator".into(),
            body: "On when `[editor] autosave_secs` is nonzero. The delay writes \
                   dirty buffers to disk N seconds after the last keystroke."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_lncol_chip
        StatuslineLnCol => Some(InfoViewCopy {
            title: "Cursor position".into(),
            body: "Line and column of the cursor in the active buffer. Click to \
                   jump to a specific line via the palette."
                .into(),
            try_it: vec![PaletteLink::new("editor.goto_line", "Go to line…")],
            ..Default::default()
        }),
        // src: src/ui/statusline.rs::draw_filesize_chip
        StatuslineFilesize => Some(InfoViewCopy {
            title: "Buffer size".into(),
            body: "Byte count of the active buffer. Grows red when the file is \
                   large enough that highlight / LSP passes measurably lag."
                .into(),
            ..Default::default()
        }),
        // ── Statusline (fill batch 2026-08-11) ──────────────────────
        // src: src/ui/tooltip.rs::HoverChip::StatuslineFile,
        //      src/app/dispatch.rs (hit-test), src/tui/mouse/down_left.rs
        StatuslineFile => Some(InfoViewCopy {
            title: "Active file chip".into(),
            body: "Shows the active buffer's file name with a dirty dot when there \
                   are unsaved edits. Click to reveal it in the file tree; right- \
                   click for the buffer context menu."
                .into(),
            try_it: vec![PaletteLink::new("view.reveal_active", "Reveal in tree")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineDiagnostics
        StatuslineDiagnostics => Some(InfoViewCopy {
            title: "Diagnostics summary".into(),
            body: "Rolls the active buffer's LSP errors and warnings into one \
                   chip. Click to open the diagnostics panel and step through \
                   each one."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+M", "Open diagnostics")],
            try_it: vec![PaletteLink::new("lsp.diagnostics", "Open diagnostics")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineLanguage
        StatuslineLanguage => Some(InfoViewCopy {
            title: "Detected language".into(),
            body: "Names the language mnml picked for the active buffer, inferred \
                   from the file extension. This drives which syntax grammar and \
                   LSP server get attached — click for a toast confirming the \
                   source."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineSymbol
        StatuslineSymbol => Some(InfoViewCopy {
            title: "Enclosing-symbol crumb".into(),
            body: "Names the function, struct, or class that contains the \
                   cursor's current line — computed from a lightweight regex \
                   outline, not full LSP. Click to open the outline pane."
                .into(),
            try_it: vec![PaletteLink::new("outline.show", "Open outline")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslinePr
        StatuslinePr => Some(InfoViewCopy {
            title: "Pull request badge".into(),
            body: "Shows the open PR for the branch checked out in the active \
                   repo — host tag plus PR number. Click opens it in your \
                   browser."
                .into(),
            aside: Some("Only visible when the active branch has an open PR.".into()),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineMacroRec
        StatuslineMacroRec => Some(InfoViewCopy {
            title: "Macro-recording indicator".into(),
            body: "Appears while a vim macro is recording, naming the register \
                   it's recording into. Click stops the recording — the same \
                   effect as pressing `q`."
                .into(),
            try_it: vec![PaletteLink::new("vim.macro_toggle", "Stop recording")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineFind
        StatuslineFind => Some(InfoViewCopy {
            title: "Active find query".into(),
            body: "Shows the current in-buffer search term plus match position \
                   (N/M). Click reopens the find prompt so you can change the \
                   query."
                .into(),
            shortcuts: vec![ShortcutHint::new("n / N", "Next / previous match")],
            try_it: vec![PaletteLink::new("find.find", "Reopen find")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineSel
        StatuslineSel => Some(InfoViewCopy {
            title: "Selection size".into(),
            body: "Live char / byte / line count of the active selection. \
                   Updates as you extend or shrink it — a quick way to confirm \
                   exactly what a visual-mode yank or delete will touch."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineProgress
        StatuslineProgress => Some(InfoViewCopy {
            title: "LSP progress indicator".into(),
            body: "Surfaces the active language server's `$/progress` \
                   notifications — indexing, building, analyzing. Disappears \
                   once the server reports the task complete."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineBgTasks
        StatuslineBgTasks => Some(InfoViewCopy {
            title: "Background tasks".into(),
            body: "Count of tasks mnml is running off the main thread right now \
                   — LSP indexing, git fetches, HTTP sends, and similar async \
                   work. The spinner keeps it visibly alive so a busy workspace \
                   doesn't look frozen."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineAi
        StatuslineAi => Some(InfoViewCopy {
            title: "Inline suggestion pending".into(),
            body: "Shows while an AI inline-completion request is in flight for \
                   the active buffer. Clears automatically the moment the \
                   suggestion — or a timeout — lands."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineNowPlaying
        StatuslineNowPlaying => Some(InfoViewCopy {
            title: "Now-playing chip".into(),
            body: "Names the current track from mixr, Apple Music, or Spotify — \
                   whichever source is active. Click brings that source forward \
                   (or opens mixr when idle); right-click for a source menu."
                .into(),
            try_it: vec![PaletteLink::new("mixr.show", "Open mixr")],
            docs: Some("https://mnml.sh/manual/now-playing/".into()),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineMixrPlay
        StatuslineMixrPlay => Some(InfoViewCopy {
            title: "Play / pause chip".into(),
            body: "Toggles playback for whichever source is currently active — \
                   pauses mixr over IPC, or sends an AppleScript playpause to \
                   Music / Spotify. Hidden entirely when nothing is playing."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineMixrFfwd
        StatuslineMixrFfwd => Some(InfoViewCopy {
            title: "Skip chip".into(),
            body: "Advances playback — teleports to just before the next \
                   mix-out in mixr, or fires the next-track AppleScript command \
                   for Music / Spotify."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::StatuslineTestChip
        StatuslineTestChip => Some(InfoViewCopy {
            title: "Test-run status".into(),
            body: "Appears once you've launched a test run this session — \
                   cargo / npm / pytest / go / Playwright — and stays until that \
                   pane closes. Click to jump straight to the test-output pane."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_new_tab
        // Drift fix (2026-08-11): `tab.new` opens a new TAB PAGE (a
        // vim-style workspace of splits), not a new empty buffer —
        // and its chord is `Ctrl+K n`, not `Ctrl+T` (reserved to
        // avoid colliding with VS Code's Ctrl+T workspace-symbols).
        BufferlineNewTab => Some(InfoViewCopy {
            title: "New tab page".into(),
            body: "Opens a fresh tab page — a new vim-style workspace of splits, \
                   separate from the buffers open on the current one. Switch \
                   between tab pages with `gt` / `gT`."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K n", "New tab page")],
            try_it: vec![PaletteLink::new("tab.new", "New tab page")],
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_theme_toggle
        BufferlineThemeToggle => Some(InfoViewCopy {
            title: "Theme swap".into(),
            body: "Swaps between `[ui] theme` and `[ui] theme_toggle`. Right-click \
                   for the full theme list; left-click cycles the pair."
                .into(),
            try_it: vec![
                PaletteLink::new("theme.toggle", "Swap themes"),
                PaletteLink::new("theme.pick", "Pick a theme…"),
            ],
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_tab — one row per open buffer/pane
        BufferlineTab(_) => Some(InfoViewCopy {
            title: "Bufferline tab".into(),
            body: "One tab per open pane. Click to focus; middle-click closes; \
                   drag to reorder. Dirty buffers show a `•` before the label."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Ctrl+PgUp/PgDn", "Prev / next buffer"),
                ShortcutHint::new("Ctrl+W", "Close active buffer"),
            ],
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_tab_close
        BufferlineTabClose(_) => Some(InfoViewCopy {
            title: "Close tab".into(),
            body: "Closes this specific buffer. If it's dirty, mnml prompts \
                   before discarding. `Ctrl+Shift+T` reopens the last closed tab."
                .into(),
            try_it: vec![PaletteLink::new("tab.reopen", "Reopen last closed")],
            ..Default::default()
        }),
        // src: src/ui/palette_bar.rs — top-row integration chip
        IntegrationIcon(_) => Some(InfoViewCopy {
            title: "Integration chip".into(),
            body: "A sibling integration in the top-row palette bar (browser, \
                   Slack, etc.). Left-click to open its pane; right-click for \
                   remove / disable / configure."
                .into(),
            try_it: vec![PaletteLink::new(
                "integrations.show_marketplace",
                "Marketplace…",
            )],
            docs: Some("https://mnml.sh/manual/integrations/overview/".into()),
            ..Default::default()
        }),
        // src: src/ui/palette_bar.rs::draw_search_chip
        PaletteSearchChip => Some(InfoViewCopy {
            title: "Command palette".into(),
            body: "The universal palette — every command mnml knows, searchable \
                   by name or id. Click to open; `Ctrl+Shift+P` also opens it."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+P", "Open palette")],
            try_it: vec![PaletteLink::new("palette", "Open now")],
            ..Default::default()
        }),
        // src: src/ui/palette_bar.rs — sidebar/right-panel toggle chips
        PaletteSidebarButton => Some(InfoViewCopy {
            title: "Sidebar toggle".into(),
            body: "Shows / hides the left panel (files, git, integrations, \
                   agents, HTTP, findings)."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+B", "Toggle sidebar")],
            try_it: vec![PaletteLink::new("view.toggle_tree", "Toggle now")],
            ..Default::default()
        }),
        // src: src/ui/palette_bar.rs
        PaletteRightPanelButton => Some(InfoViewCopy {
            title: "Right panel toggle".into(),
            body: "Shows / hides the right panel — hosts outline, diagnostics, \
                   or whatever route is currently pinned there."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+B", "Toggle")],
            try_it: vec![PaletteLink::new("view.toggle_right_panel", "Toggle now")],
            docs: Some("https://mnml.sh/manual/right-panel/".into()),
            ..Default::default()
        }),
        // src: src/tui/mouse/down_left.rs — palette-bar back arrow
        PaletteBackButton => Some(InfoViewCopy {
            title: "Back (previous buffer)".into(),
            body: "Jumps to the previous buffer in MRU order — same as \
                   `Ctrl+PageUp`. Mirrors browser back/forward muscle memory \
                   for the bufferline."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+PageUp", "Previous buffer")],
            try_it: vec![PaletteLink::new("buffer.prev", "Go back")],
            ..Default::default()
        }),
        // src: src/tui/mouse/down_left.rs — palette-bar forward arrow
        PaletteForwardButton => Some(InfoViewCopy {
            title: "Forward (next buffer)".into(),
            body: "Jumps to the next buffer in MRU order — same as \
                   `Ctrl+PageDown`. Only does something once Back has moved you \
                   backward."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+PageDown", "Next buffer")],
            try_it: vec![PaletteLink::new("buffer.next", "Go forward")],
            ..Default::default()
        }),
        // src: src/tui/mouse/down_left.rs — palette-bar dropdown chevron
        PaletteDropdownButton => Some(InfoViewCopy {
            title: "Recent files dropdown".into(),
            body: "Opens the recent-files picker — every buffer touched this \
                   session, most-recent first. Same list as `Ctrl+R`, reachable \
                   by mouse."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+R", "Recent files")],
            try_it: vec![PaletteLink::new("picker.recent", "Open recent files")],
            ..Default::default()
        }),
        // src: src/tui/mouse/down_left.rs — palette-bar `+` chip
        PaletteAddIntegration => Some(InfoViewCopy {
            title: "Add integration".into(),
            body: "Opens the integrations Marketplace so you can enable a \
                   sibling tool (browser, Slack, AWS, …) as a chip in this bar. \
                   Right-click any installed chip later to disable or remove it."
                .into(),
            try_it: vec![PaletteLink::new(
                "integrations.show_marketplace",
                "Open Marketplace",
            )],
            ..Default::default()
        }),
        // src: src/app/mod.rs::set_pending_undo / commit_pending_undo (#20)
        PendingUndoChip => Some(InfoViewCopy {
            title: "Pending-undo chip".into(),
            body: "Appears for 10 seconds after a destructive action mnml can \
                   reverse — closing a dirty tab, deleting a file, restoring an \
                   overwritten request. Click it (or the chord) to undo before \
                   it expires; the label names exactly what will be restored."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+Z", "Commit the pending undo")],
            ..Default::default()
        }),
        // src: src/ui/menu_bar.rs::draw_word — File/Edit/View/…/Help
        MenuBarWord(_) => Some(InfoViewCopy {
            title: "Menu bar word".into(),
            body: "Click to open its dropdown; hover to peek at the next one. \
                   Alt+<letter> from anywhere opens the same menu by keyboard."
                .into(),
            shortcuts: vec![ShortcutHint::new("Alt+<letter>", "Open by keyboard")],
            docs: Some("https://mnml.sh/manual/menu-bar/".into()),
            ..Default::default()
        }),
        // src: src/ui/activity_bar.rs — one row per section
        ActivityBarIcon(_) => Some(InfoViewCopy {
            title: "Activity-bar section".into(),
            body: "One of the sections that shares the left panel — Files, Git, \
                   Integrations, Agents, HTTP, Findings. Click to switch."
                .into(),
            docs: Some("https://mnml.sh/manual/activity-bar/".into()),
            ..Default::default()
        }),
        // src: src/ui/activity_bar.rs::draw_gear
        ActivityBarGear => Some(InfoViewCopy {
            title: "Settings gear".into(),
            body: "Opens the mnml settings overlay — a scrollable list of every \
                   config key with inline pickers for each value."
                .into(),
            try_it: vec![PaletteLink::new("file.open_settings", "Open settings")],
            docs: Some("https://mnml.sh/manual/settings/".into()),
            ..Default::default()
        }),
        // src: src/ui/claude_agents_view.rs::draw_topbar_chip
        // R14 modernize pass (2026-08-16, drift fix) — this entry used
        // to describe `ClaudeAgentsTopbarChip` ("filters the agents
        // dashboard by source, workspace, or state") under the WRONG
        // chip. `AgentsPanelChipKind` (src/lib.rs:640-651) is the
        // sidebar Agents-panel HEADER row — New session / From PR /
        // View toggle — verified against src/ui/tooltip.rs:694-715 and
        // the click handlers at src/tui/mouse/down_left.rs:3021-3040.
        // Split into 3 real entries; `ClaudeAgentsTopbarChip` below
        // keeps the (correct) filter-chip copy.
        AgentsPanelChip(AgentsPanelChipKind::NewSession) => Some(InfoViewCopy {
            title: "New agent session".into(),
            body: "Spawns a fresh Claude Code session scoped to this \
                   workspace — same as opening one from the palette. Shows \
                   up as a new row in the Agents dashboard once it starts."
                .into(),
            try_it: vec![PaletteLink::new(
                "ai.claude_code",
                "New Claude Code session",
            )],
            ..Default::default()
        }),
        AgentsPanelChip(AgentsPanelChipKind::FromPr) => Some(InfoViewCopy {
            title: "New agent session from PR".into(),
            body: "Opens the multi-PR wizard — pick one or more open pull \
                   requests and an action (review, fix CI, address \
                   comments), and it fires one Claude session per PR."
                .into(),
            try_it: vec![PaletteLink::new(
                "agents.new_from_pr",
                "New session from PR",
            )],
            ..Default::default()
        }),
        AgentsPanelChip(AgentsPanelChipKind::ViewToggle) => Some(InfoViewCopy {
            title: "Agents-panel view toggle".into(),
            body: "Cycles how the sidebar Agents panel groups its rows — by \
                   workspace or by status. Grouping by workspace collapses \
                   each project into its own expandable section."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/http_panel.rs L75-86 — top toolbar row has
        // exactly 2 chips: refresh + collapse-all. R12 api-workflow
        // SEV-3 correction: R11's rewrite overclaimed 4 actions
        // (search / new-request / collapse-all / refresh) and
        // pointed try_it at `http.new_request`, which has no button
        // in this cluster. Now index-aware.
        HttpToolbarChip(0) => Some(InfoViewCopy {
            title: "HTTP: refresh list".into(),
            body: "Rescan collections / files / envs / captured / mocks and rebuild \
                   the HTTP-panel caches. Same as the palette command."
                .into(),
            try_it: vec![PaletteLink::new("http.refresh", "Refresh HTTP list")],
            docs: Some("https://mnml.sh/manual/http/".into()),
            ..Default::default()
        }),
        HttpToolbarChip(1) => Some(InfoViewCopy {
            title: "HTTP: collapse / expand all sections".into(),
            body: "Fold every HTTP-panel section (FILES / RECENT / CAPTURED / ENVS / \
                   CHAINS / MOCKS / COLLECTIONS) closed, or expand them all when \
                   collapsed. Individual section headers still toggle one at a time."
                .into(),
            try_it: vec![PaletteLink::new(
                "http.toggle_collapse_all",
                "Toggle collapse-all",
            )],
            ..Default::default()
        }),
        HttpToolbarChip(_) => None,
        // src: src/ui/http_panel.rs — per-section mini icon-button
        // row (Filter / Refresh / Clear / New, one row per FILES /
        // RECENT / CAPTURED / etc. section). NOT the header row —
        // that has its own rects at `http_panel_section_headers`.
        // R11 api-workflow SEV-2 correction: was describing the
        // header/collapse behavior which lives elsewhere.
        HttpSectionChip(_) => Some(InfoViewCopy {
            title: "HTTP section mini-button".into(),
            body: "Filter / refresh / clear / new button for ONE section of the \
                   HTTP panel (FILES / RECENT / CAPTURED / ENVS / CHAINS / MOCKS / \
                   COLLECTIONS). The header row above collapses the whole section."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/statusline.rs — top-right git toolbar cluster
        GitToolbarChip(_) => Some(InfoViewCopy {
            title: "Git toolbar chip".into(),
            body: "One-click git action — fetch, pull, push, stage-all, commit. \
                   Same actions live in `> GIT` rail headers and the palette."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/editor_view.rs — gutter fold indicator
        FoldChip => Some(InfoViewCopy {
            title: "Fold chip".into(),
            body: "Marks a foldable region in the gutter. Click to toggle \
                   open / closed at the cursor; `Ctrl+Shift+]` (standard) or \
                   `zR` (vim) unfolds every fold in the buffer."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("za", "Toggle fold at cursor (vim)"),
                ShortcutHint::new("Ctrl+Shift+[", "Toggle fold at cursor (standard)"),
                ShortcutHint::new("Ctrl+Shift+]", "Unfold all"),
            ],
            try_it: vec![PaletteLink::new("editor.toggle_fold", "Toggle at cursor")],
            ..Default::default()
        }),
        // src: src/ui/bufferline.rs::draw_window_close
        BufferlineWindowClose => Some(InfoViewCopy {
            title: "Close window".into(),
            body: "Closes the mnml instance. If any buffer is dirty, mnml \
                   prompts before quitting; `Ctrl+Q` is the same action."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Q", "Quit")],
            try_it: vec![PaletteLink::new("app.quit", "Quit mnml")],
            ..Default::default()
        }),

        // ── Fill batch 2026-08-11 (v2) ──────────────────────────────
        // Gap-closing pass: 32 previously-uncovered HoverChip variants,
        // prioritized per user report — the file-tree action row
        // (`TreeIcon`) was showing the raw echoed tooltip label
        // ("add workspace folder") with no body copy. Grounded against
        // `src/ui/tooltip.rs::describe` for behavior + `src/command.rs`
        // for every cited command id / chord.

        // src: src/ui/tree_view.rs::workspace_header_chips,
        //      draw_add_repo_row, draw_empty_workspace_state;
        //      src/ui/mod.rs (DAP debug-rail rows reuse the same rect
        //      vec — `app.rects.tree_icon_buttons` — for a handful of
        //      cmd_ids not listed here; those fall through to the
        //      legacy tooltip via `_ => None` below).
        TreeIcon(cmd_id) => {
            let (title, body): (&str, &str) = match cmd_id {
                "view.add_workspace" => (
                    "Add workspace folder",
                    "Opens a path prompt to add another folder as an extra \
                     workspace root alongside the current one — the tree grows \
                     a second top-level section instead of replacing what's \
                     open. Type a path (`~` expands) or leave it to browse; \
                     missing intermediate folders are NOT created here.",
                ),
                "file.new" => (
                    "New file",
                    "Creates an empty file in the workspace root and opens it \
                     in a fresh tab, prompting for a name first.",
                ),
                "file.new_folder" => (
                    "New folder",
                    "Creates a new directory in the workspace root after \
                     prompting for a name. The tree jumps to show it.",
                ),
                "tree.refresh" => (
                    "Refresh tree",
                    "Re-scans the workspace root from disk and repaints the \
                     tree — use it after external changes mnml's file-watcher \
                     might have missed (bulk git operations, another process \
                     writing files).",
                ),
                "tree.toggle_collapse_all" => (
                    "Collapse / expand all",
                    "Folds every open directory in the tree closed, or opens \
                     every directory when the tree is already fully collapsed. \
                     One click toggles the whole rail.",
                ),
                "git.pull" => (
                    "Pull (workspace header)",
                    "Runs `git pull --ff-only` against the repo that owns this \
                     workspace root, right from the tree header. Same action \
                     as the `> GIT` rail header's Pull chip.",
                ),
                "picker.files" => (
                    "Search files",
                    "Opens the fuzzy file picker over the workspace — type to \
                     match, Enter opens in the active pane.",
                ),
                "view.discovery" => (
                    "Open file",
                    "Opens the file picker so you can jump straight to a file \
                     without adding a workspace root first.",
                ),
                "view.switch_workspace" => (
                    "Switch workspace",
                    "Opens the workspace picker — swap the tree to a different \
                     root entirely (as opposed to adding one alongside it).",
                ),
                "view.manage_workspaces" => (
                    "Manage workspaces",
                    "Opens the overlay listing every configured workspace root \
                     so you can rename, reorder, or remove entries.",
                ),
                "view.open_default_workspace" => (
                    "Open default workspace",
                    "Switches straight to the `default_workspace` configured in \
                     your user config — a one-click way back to your usual \
                     project from an empty or unrelated workspace.",
                ),
                _ => return None,
            };
            Some(InfoViewCopy {
                title: title.into(),
                body: body.into(),
                try_it: vec![PaletteLink::new(cmd_id, "Run it")],
                ..Default::default()
            })
        }
        // src: src/ui/tooltip.rs::HoverChip::WorkspaceHeader,
        //      src/app/dispatch.rs:652
        WorkspaceHeader => Some(InfoViewCopy {
            title: "Workspace root".into(),
            body: "Names the folder the tree is rooted at — click to collapse \
                   or expand the whole tree, or right-click for workspace \
                   actions (add another root, switch, manage). Hovering shows \
                   the absolute path so you can confirm which directory mnml \
                   actually opened."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.switch_workspace",
                "Switch workspace",
            )],
            docs: Some("https://mnml.sh/manual/workspaces/".into()),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::ExtraWorkspaceHeader,
        //      src/app/dispatch.rs:660
        ExtraWorkspaceHeader(_) => Some(InfoViewCopy {
            title: "Extra workspace root".into(),
            body: "A second (or third…) folder added via Add workspace folder \
                   — its own collapsible section in the tree, independent of \
                   the primary workspace root above it. Click to expand or \
                   collapse just this section; right-click to remove it from \
                   the tree without touching the primary root."
                .into(),
            aside: Some("Only appears once you've added at least one extra root.".into()),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::ToastBox
        ToastBox(_) => Some(InfoViewCopy {
            title: "Toast notification".into(),
            body: "A transient status message stacked in the corner — success, \
                   error, or progress info from whatever just ran. Hovering \
                   pauses its countdown so you have time to read it; click to \
                   dismiss early, or right-click for a small actions menu."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RailHeaderChip
        // R14 modernize pass (2026-08-16) — per-action copy for the 6
        // `GitRailHeaderAction` variants (src/lib.rs:236-247). Command
        // ids taken straight from that enum's own doc comments (which
        // name the exact command each action wraps); `StageAll` has no
        // command id — it calls `git_stage_all_rail` directly.
        RailHeaderChip(GitRailHeaderAction::Fetch) => Some(InfoViewCopy {
            title: "Git rail: Fetch".into(),
            body: "Fetches from origin for the repo that owns this rail \
                   section — updates remote-tracking refs without touching \
                   your working tree or the branch you're on."
                .into(),
            try_it: vec![PaletteLink::new("git.fetch", "Fetch")],
            ..Default::default()
        }),
        RailHeaderChip(GitRailHeaderAction::Pull) => Some(InfoViewCopy {
            title: "Git rail: Pull".into(),
            body: "`git pull --ff-only` for this repo — fast-forwards the \
                   current branch if origin has moved ahead cleanly; \
                   refuses (rather than merging) if it can't."
                .into(),
            try_it: vec![PaletteLink::new("git.pull", "Pull")],
            ..Default::default()
        }),
        RailHeaderChip(GitRailHeaderAction::Push) => Some(InfoViewCopy {
            title: "Git rail: Push".into(),
            body: "Pushes committed work to origin. First push on a new \
                   branch falls back to `--set-upstream` automatically — no \
                   separate step needed."
                .into(),
            aside: Some("Refuses (doesn't force) on a diverged branch — pull first.".into()),
            try_it: vec![PaletteLink::new("git.push", "Push")],
            ..Default::default()
        }),
        RailHeaderChip(GitRailHeaderAction::StageAll) => Some(InfoViewCopy {
            title: "Git rail: Stage all".into(),
            body: "`git add -A` against this repo — stages every working- \
                   tree change (new, modified, deleted) in one click, ready \
                   for Commit."
                .into(),
            ..Default::default()
        }),
        RailHeaderChip(GitRailHeaderAction::Commit) => Some(InfoViewCopy {
            title: "Git rail: Commit".into(),
            body: "Opens the commit-message prompt for whatever's staged in \
                   this repo. Nothing staged yet? Stage all first, or stage \
                   individual files from the WIP row."
                .into(),
            try_it: vec![PaletteLink::new("git.commit", "Commit")],
            ..Default::default()
        }),
        RailHeaderChip(GitRailHeaderAction::Graph) => Some(InfoViewCopy {
            title: "Git rail: Open graph".into(),
            body: "Opens the commit graph pane for this repo — full lane \
                   view of every branch's history, not just the current \
                   one."
                .into(),
            try_it: vec![PaletteLink::new("git.graph", "Open commit graph")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::SplitDivider
        SplitDivider => Some(InfoViewCopy {
            title: "Split divider".into(),
            body: "The resize handle between two panes in a split. Drag it to \
                   change the split ratio; double-click to reset both sides \
                   back to equal size."
                .into(),
            try_it: vec![PaletteLink::new("view.equalize_splits", "Equalize splits")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::BufferlineTabsLabel
        BufferlineTabsLabel => Some(InfoViewCopy {
            title: "Tab pages count".into(),
            body: "Shows how many tab pages are open — separate vim-style \
                   workspaces of splits, distinct from the buffers inside any \
                   one of them. Click to switch between tab pages; right-click \
                   for the full menu."
                .into(),
            shortcuts: vec![ShortcutHint::new("gt / gT", "Next / previous tab page")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RightPanelTab
        RightPanelTab(_) => Some(InfoViewCopy {
            title: "Right-panel tab".into(),
            body: "One tab in the right panel's own strip — outline, \
                   diagnostics, or whatever else got routed there. Click to \
                   switch to it; the `×` on the active tab closes it."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RightPanelClose
        RightPanelClose => Some(InfoViewCopy {
            title: "Close right-panel tab".into(),
            body: "Closes the active tab hosted in the right panel — the panel \
                   itself stays open (and empty) until something else routes \
                   into it, or you hide it entirely with the sidebar toggle."
                .into(),
            shortcuts: vec![ShortcutHint::new(
                "Ctrl+Alt+W",
                "Close active right-panel tab",
            )],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::SplitTabChip
        SplitTabChip(_) => Some(InfoViewCopy {
            title: "Split tab strip tab".into(),
            body: "A tab on one split leaf's own tab strip — separate from the \
                   global bufferline. Click to focus, middle-click to close, \
                   right-click for the tab menu."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::SplitTabClose
        SplitTabClose(_) => Some(InfoViewCopy {
            title: "Close split-leaf tab".into(),
            body: "Closes this one tab from its split leaf. Dirty buffers \
                   prompt before discarding, same as closing from the main \
                   bufferline."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::SplitTabPlus
        SplitTabPlus(_) => Some(InfoViewCopy {
            title: "Add to this split leaf".into(),
            body: "Opens a small Create… menu scoped to this leaf — new \
                   scratch buffer, new terminal, or a further split — without \
                   disturbing any other leaf in the layout."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::SplitStripButton
        SplitStripButton(_) => Some(InfoViewCopy {
            title: "Split editor button".into(),
            body: "Splits the active leaf — horizontal (side by side) or \
                   vertical (stacked), depending on which of the pair you \
                   click. Opens the same buffer in both halves so you can \
                   scroll them independently."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Ctrl+\\", "Split right"),
                ShortcutHint::new("Ctrl+Shift+\\", "Split down"),
            ],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::SplitStripTermButton
        SplitStripTermButton => Some(InfoViewCopy {
            title: "Open shell in split".into(),
            body: "Splits the active leaf and opens a new shell Pty pane in \
                   the new half — a quick way to get a terminal beside the \
                   file you're editing without leaving the layout."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::SplitStripAiButton
        SplitStripAiButton => Some(InfoViewCopy {
            title: "Open AI session in split".into(),
            body: "Spawns a new Claude Code or Codex session in a fresh split \
                   next to the active leaf. Which agent(s) show here follows \
                   `[ui] tab_bar_ai_icon` — right-click for a menu when both \
                   are configured."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::ScrollbarThumb
        ScrollbarThumb => Some(InfoViewCopy {
            title: "Scrollbar".into(),
            body: "Drag the thumb to scroll; click anywhere on the track to \
                   jump straight to that position. Appears on any pane, \
                   overlay, or panel whose content overflows its rect."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RightPanelGrip
        RightPanelGrip => Some(InfoViewCopy {
            title: "Right-panel resize grip".into(),
            body: "Drag to resize the right panel's width; double-click resets \
                   it to the default. Width persists to \
                   `[ui] right_panel_width`."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::TreeRailGrip
        TreeRailGrip => Some(InfoViewCopy {
            title: "Tree rail resize grip".into(),
            body: "Drag to resize the left panel's width; double-click resets \
                   it to the default."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::DockKebab
        DockKebab => Some(InfoViewCopy {
            title: "Dock widget options".into(),
            body: "Opens the per-widget menu for a docked bottom-panel widget \
                   — resize, remove, or reconfigure just that one tile."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::DockEmptyChip
        DockEmptyChip => Some(InfoViewCopy {
            title: "Create first dock widget".into(),
            body: "Shown when the dock has no widgets yet. Click to choose \
                   what kind of widget to add — the dock stays empty (and \
                   hidden) until you place one."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::TreeUpRow
        TreeUpRow => Some(InfoViewCopy {
            title: "Up-navigation row".into(),
            body: "The `..` row above the file tree — click to re-root the \
                   workspace one directory up. Hidden at the filesystem root, \
                   since there's nowhere further up to go."
                .into(),
            try_it: vec![PaletteLink::new("view.workspace_up", "Go up one level")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::GutterMark
        // R14 modernize pass (2026-08-16) — `GutterMark` carries a
        // `GutterMarkKind` (src/lib.rs:615-626); this used to be one
        // generic entry regardless of which kind was actually under
        // the mouse. Split per kind — a breakpoint dot and a
        // diagnostic dot mean very different things at a glance.
        GutterMark {
            kind: GutterMarkKind::DapArrow,
            ..
        } => Some(InfoViewCopy {
            title: "Paused-here arrow".into(),
            body: "`▶` — the debugger is stopped on this line right now. \
                   Step, continue, or inspect variables in the Debug panel; \
                   the arrow moves as execution advances."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("F10", "Step over"),
                ShortcutHint::new("F11", "Step in"),
                ShortcutHint::new("F5", "Continue"),
            ],
            try_it: vec![PaletteLink::new("dap.next", "Step over")],
            ..Default::default()
        }),
        GutterMark {
            kind: GutterMarkKind::ConditionalBreakpoint,
            ..
        } => Some(InfoViewCopy {
            title: "Conditional breakpoint".into(),
            body: "`◆` — a breakpoint that only stops execution when its \
                   condition expression evaluates truthy. Click the gutter \
                   again to clear it; the condition itself is edited via \
                   the same prompt that created it."
                .into(),
            try_it: vec![PaletteLink::new(
                "dap.toggle_breakpoint_conditional",
                "Edit condition",
            )],
            ..Default::default()
        }),
        GutterMark {
            kind: GutterMarkKind::Breakpoint,
            ..
        } => Some(InfoViewCopy {
            title: "Breakpoint".into(),
            body: "`●` (red) — execution pauses here once a DAP session is \
                   running. Works ahead of time — set it before you start \
                   debugging and it's honored the moment a session connects."
                .into(),
            aside: Some("Click the gutter at this line again to clear it.".into()),
            shortcuts: vec![ShortcutHint::new("F9", "Toggle breakpoint")],
            try_it: vec![PaletteLink::new(
                "dap.toggle_breakpoint",
                "Toggle breakpoint at cursor",
            )],
            ..Default::default()
        }),
        GutterMark {
            kind: GutterMarkKind::Diagnostic(_),
            ..
        } => Some(InfoViewCopy {
            title: "Diagnostic mark".into(),
            body: "`●` colored by severity — red for errors, yellow for \
                   warnings, cyan for info, grey for hints. Hover the mark \
                   itself (not just the gutter column) for the message text; \
                   click to jump the cursor to that line."
                .into(),
            try_it: vec![PaletteLink::new("lsp.diagnostics", "Open diagnostics")],
            ..Default::default()
        }),
        GutterMark {
            kind: GutterMarkKind::GitChange(_),
            ..
        } => Some(InfoViewCopy {
            title: "Git change bar".into(),
            body: "`▎` — this line differs from the last commit. Green means \
                   added, blue means modified, red means lines were removed \
                   just above. Reflects the working tree against HEAD, same \
                   diff the `> GIT` rail summarizes."
                .into(),
            shortcuts: vec![ShortcutHint::new(
                "]c / [c",
                "Jump to next / previous git hunk (vim)",
            )],
            try_it: vec![PaletteLink::new("git.jump_next_change", "Next hunk")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::CodeLensChip
        CodeLensChip => Some(InfoViewCopy {
            title: "Code lens".into(),
            body: "An inline actionable hint from the LSP — usually \"N \
                   references\" or a run/test link — rendered just above the \
                   code it describes. Click to fire whatever action the \
                   language server attached."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::DiffToolbar
        // R14 modernize pass (2026-08-16) — per-action copy for the 5
        // `DiffToolbarAction` variants (src/lib.rs:215-229). None of
        // these have a palette command id (click-only UI toggles), so
        // no `try_it` — verified against src/command.rs (no `diff.*`
        // view-mode entries exist).
        DiffToolbar(DiffToolbarAction::ViewInline) => Some(InfoViewCopy {
            title: "Diff: Inline view".into(),
            body: "Renders the whole file with changes highlighted in \
                   place — closest to what the file actually looks like on \
                   disk, with additions and removals colored inline."
                .into(),
            ..Default::default()
        }),
        DiffToolbar(DiffToolbarAction::ViewHunk) => Some(InfoViewCopy {
            title: "Diff: Hunk view".into(),
            body: "Shows only the changed regions, each collapsed to a \
                   focused block with a few lines of context — skips the \
                   unchanged bulk of a large file so you can scan every \
                   change fast."
                .into(),
            ..Default::default()
        }),
        DiffToolbar(DiffToolbarAction::ViewSplit) => Some(InfoViewCopy {
            title: "Diff: Split view".into(),
            body: "Side-by-side old-vs-new columns, classic two-pane diff \
                   layout. Needs more width than Inline or Hunk to stay \
                   readable — narrow panes fall back automatically."
                .into(),
            ..Default::default()
        }),
        DiffToolbar(DiffToolbarAction::ToggleWrap) => Some(InfoViewCopy {
            title: "Diff: toggle wrap".into(),
            body: "Wraps long lines at the pane's right edge instead of \
                   scrolling horizontally — handy for diffs on minified or \
                   very long single-line changes."
                .into(),
            ..Default::default()
        }),
        DiffToolbar(DiffToolbarAction::Close) => Some(InfoViewCopy {
            title: "Diff: close".into(),
            body: "Clears the embedded diff when shown inside a commit \
                   graph's detail panel, or closes the pane entirely for a \
                   standalone Diff view."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::ClaudeAgentsTopbarChip
        // R14 modernize pass (2026-08-16) — per-kind copy for the 5
        // `TopbarChipKind` variants (src/ui/mod.rs:33-39). Click
        // behavior grounded against src/tui/mouse/mod.rs:510-545 —
        // all 5 are `Pane::ClaudeAgents` method calls with no
        // dedicated palette command id, so no `try_it` per-kind.
        ClaudeAgentsTopbarChip(TopbarChipKind::View) => Some(InfoViewCopy {
            title: "Dashboard: cycle detail depth".into(),
            body: "Cycles how much detail each row shows — compact one-line \
                   rows, up through the fullest per-session breakdown. Same \
                   axis regardless of sort or grouping."
                .into(),
            ..Default::default()
        }),
        ClaudeAgentsTopbarChip(TopbarChipKind::Sort) => Some(InfoViewCopy {
            title: "Dashboard: cycle sort".into(),
            body: "Cycles the sort key for the row list — most-recent \
                   activity, workspace, or state. The active key is what \
                   the chip's label currently reads."
                .into(),
            ..Default::default()
        }),
        ClaudeAgentsTopbarChip(TopbarChipKind::Group) => Some(InfoViewCopy {
            title: "Dashboard: cycle grouping".into(),
            body: "Cycles how rows are grouped — flat list, by workspace, \
                   or by state (running / idle / ended)."
                .into(),
            ..Default::default()
        }),
        ClaudeAgentsTopbarChip(TopbarChipKind::Source) => Some(InfoViewCopy {
            title: "Dashboard: filter by source".into(),
            body: "Cycles the source filter — all sessions, Claude only, \
                   Codex only, then back to all. Cloud-runner and \
                   Anthropic-Managed rows live in a separate dashboard, so \
                   they're not part of this cycle."
                .into(),
            ..Default::default()
        }),
        ClaudeAgentsTopbarChip(TopbarChipKind::Workspace) => Some(InfoViewCopy {
            title: "Dashboard: workspace-only toggle".into(),
            body: "Restricts the row list to sessions in the current \
                   workspace only, hiding every other project's sessions. \
                   Click again to see everything."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::SessionsTab
        SessionsTab(_) => Some(InfoViewCopy {
            title: "Session tab".into(),
            body: "One running Pty session in the Sessions panel — Claude \
                   Code, Codex, or a plain shell. Hovering previews the last \
                   few messages (Claude) or a summary of recent output; click \
                   to focus that session's pane."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestTopBarChip
        // R14 modernize pass (2026-08-16) — per-chip copy for the 6
        // `RequestTopBarChip` variants (src/lib.rs:631-638). Command
        // ids grounded against src/command.rs + click behavior against
        // src/tui/mouse/down_left.rs:700-815.
        RequestTopBarChip(ReqChip::Method) => Some(InfoViewCopy {
            title: "HTTP method".into(),
            body: "The verb this request sends — GET / POST / PUT / PATCH / \
                   DELETE / HEAD / OPTIONS. Click to cycle, or right-click \
                   for the full list in one menu."
                .into(),
            try_it: vec![PaletteLink::new("http.cycle_method", "Cycle method")],
            ..Default::default()
        }),
        RequestTopBarChip(ReqChip::Env) => Some(InfoViewCopy {
            title: "Active environment".into(),
            body: "Names the `.env` file supplying `{{VAR}}` values for this \
                   request — dev / staging / prod, whatever your workspace \
                   defines. Click to switch; the picker also offers \
                   creating a new env."
                .into(),
            aside: Some(
                "A var with no match in the active env renders bold red in \
                 the URL / body / headers."
                    .into(),
            ),
            try_it: vec![PaletteLink::new("http.pick_env", "Switch environment")],
            ..Default::default()
        }),
        RequestTopBarChip(ReqChip::Send) => Some(InfoViewCopy {
            title: "Send request".into(),
            body: "Fires the request over the network. While in flight the \
                   chip flips to `⟳ Abort` — click again to cancel a hung \
                   request instead of waiting out the timeout."
                .into(),
            aside: Some(
                "A failed send still lands a response pane — check status \
                 code + the ⚡ AI debug chip if it's not a 2xx."
                    .into(),
            ),
            shortcuts: vec![ShortcutHint::new("r", "Send (vim, Request pane focus)")],
            try_it: vec![PaletteLink::new("http.send", "Send request")],
            docs: Some("https://mnml.sh/manual/http/".into()),
        }),
        RequestTopBarChip(ReqChip::Save) => Some(InfoViewCopy {
            title: "Save request".into(),
            body: "Writes the current method / URL / headers / body back to \
                   its source `.http` / `.curl` file. No source file yet? \
                   Opens a Save-As prompt instead."
                .into(),
            try_it: vec![PaletteLink::new("http.save", "Save request")],
            ..Default::default()
        }),
        RequestTopBarChip(ReqChip::Clear) => Some(InfoViewCopy {
            title: "Clear request".into(),
            body: "Resets every field back to a blank template — same as \
                   opening a fresh scratch request. A pending-undo chip \
                   appears afterward so a misclick is one click to reverse."
                .into(),
            try_it: vec![PaletteLink::new("http.new", "New blank request")],
            ..Default::default()
        }),
        RequestTopBarChip(ReqChip::Code) => Some(InfoViewCopy {
            title: "Generate code".into(),
            body: "Opens the Bruno-style language picker and copies this \
                   request as a ready-to-paste snippet — curl, Python \
                   requests, JS fetch, and more."
                .into(),
            try_it: vec![PaletteLink::new("http.generate_code", "Generate code")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestSplitToggle
        RequestSplitToggle => Some(InfoViewCopy {
            title: "Request/response orientation toggle".into(),
            body: "Cycles how the Request pane lays out its request and \
                   response halves — Auto (picks by pane width), stacked \
                   (request above response), or side-by-side."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestEditSplitChip
        RequestEditSplitChip => Some(InfoViewCopy {
            title: "Edit-area split toggle".into(),
            body: "Opens a side-by-side split of the Request pane's edit \
                   content — e.g. Body on the left, Vars on the right — so \
                   you can see two tabs at once instead of switching between \
                   them."
                .into(),
            try_it: vec![PaletteLink::new(
                "http.toggle_edit_split",
                "Toggle edit split",
            )],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestEditSplitDivider
        RequestEditSplitDivider => Some(InfoViewCopy {
            title: "Edit-split divider".into(),
            body: "The 1-cell divider between the primary and secondary sides \
                   of an edit split. Click cycles the ratio 30/50/70 — unlike \
                   a pane split divider, it doesn't drag-resize yet."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestVarToken
        RequestVarToken(_) => Some(InfoViewCopy {
            title: "{{VAR}} token".into(),
            body: "A `{{variable}}` reference inside the URL, body, params, or \
                   headers. Cyan means it resolves in the active env; bold red \
                   means it's undefined. Click jumps to its definition line in \
                   the env file (or opens the file at EOF, ready to define it)."
                .into(),
            aside: Some(
                "Bold red at send time means the raw `{{name}}` text goes over \
                 the wire unresolved — right-click → \"Set value…\" fixes it \
                 without leaving the pane."
                    .into(),
            ),
            docs: Some("https://mnml.sh/manual/http-envs/".into()),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestResponseCopy
        RequestResponseCopy => Some(InfoViewCopy {
            title: "Copy response body".into(),
            body: "Copies the full response body to the clipboard, exactly as \
                   received — no re-formatting."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestResponseWrap
        RequestResponseWrap => Some(InfoViewCopy {
            title: "Wrap response body".into(),
            body: "Toggles line-wrapping for the response body view — handy \
                   for long unformatted JSON or minified payloads."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestResponseAiPrompt
        RequestResponseAiPrompt => Some(InfoViewCopy {
            title: "Debug-with-AI prompt".into(),
            body: "Copies a ready-made \"debug this failure\" prompt — status \
                   code, headers, and body — to the clipboard, so you can \
                   paste it straight into a Claude or Codex session. Only \
                   shown when the response looks like a failure; headers are \
                   redacted before copy."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::RequestResponseFormat
        RequestResponseFormat => Some(InfoViewCopy {
            title: "Format response body".into(),
            body: "Pretty-prints the response body when it's JSON. Dims out \
                   when the body isn't JSON, since there's nothing to format."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::HttpCollectionAddRequestChip
        HttpCollectionAddRequestChip(_) => Some(InfoViewCopy {
            title: "New request in collection".into(),
            body: "Prompts for a name and creates a new `.http` file inside \
                   this collection's folder — the fastest way to add a \
                   request without leaving the HTTP panel."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::BufferlineNewRequest
        BufferlineNewRequest => Some(InfoViewCopy {
            title: "New HTTP request".into(),
            body: "Opens a blank Request pane as a new tab. Shown on the \
                   bufferline once at least one Request pane is already open; \
                   distinct from the far-right `+` new-tab-page button."
                .into(),
            try_it: vec![PaletteLink::new("http.new_request", "New request")],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::CloudAgentsNewRunButton
        CloudAgentsNewRunButton => Some(InfoViewCopy {
            title: "New cloud run".into(),
            body: "Opens the wizard for launching a managed cloud agent run — \
                   Anthropic Managed Agents or the self-hosted ECS runner, \
                   depending on what's configured."
                .into(),
            try_it: vec![PaletteLink::new(
                "cloud_agents.new_run_wizard",
                "New cloud run wizard",
            )],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::CloudRunAutoRefresh
        CloudRunAutoRefresh => Some(InfoViewCopy {
            title: "Cloud run auto-refresh".into(),
            body: "Cycles how often the run-detail pane re-polls for new logs \
                   and status — off, 10s, 30s, 60s, or 5m."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::CloudRunRefresh
        CloudRunRefresh => Some(InfoViewCopy {
            title: "Cloud run refresh".into(),
            body: "Manually re-fetches logs and artifacts for this run (or \
                   restarts the SSE stream if it dropped)."
                .into(),
            try_it: vec![PaletteLink::new(
                "cloud_agents.refresh_run_detail",
                "Refresh run detail",
            )],
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::GitGraphLane
        GitGraphLane { .. } => Some(InfoViewCopy {
            title: "Git graph lane".into(),
            body: "One column of the commit graph — a lane represents a \
                   branch's line of commits as it merges and diverges. \
                   Hovering names the nearest branch ref in that lane, walking \
                   upward from this commit until it finds one."
                .into(),
            ..Default::default()
        }),
        // src: src/ui/tooltip.rs::HoverChip::GitGraphCommitMsg
        GitGraphCommitMsg { .. } => Some(InfoViewCopy {
            title: "Commit subject".into(),
            body: "The full, untruncated subject line of this commit, plus \
                   author and short hash — useful when the graph column is too \
                   narrow to show the whole message inline."
                .into(),
            ..Default::default()
        }),
        // Task #929 — `MenuBarItem` is resolved via
        // `resolve_menu_bar_item_copy` in `lookup()` before it can
        // reach here; this arm just satisfies the exhaustiveness
        // checker so `chip_copy` stays exhaustive over `HoverChip`.
        MenuBarItem { .. } => None,
        // Task #875 (R5 SEV-3) — chrome chips whose tooltips carry
        // all the useful copy; no separate info-panel entry needed.
        // These arms exist so `chip_copy` stays exhaustive.
        BufferlineTabPage(_) => None,
        BufferlineTabPageClose(_) => None,
        // R13 audit follow-up 2026-08-15 — Integrations panel tab-
        // strip chips got a stale `None` fallthrough. Real copy per
        // chip so the info panel matches the mouse target.
        IntegrationsTabInstalled => Some(InfoViewCopy {
            title: "Integrations — Installed".into(),
            body: "Tab that lists the integrations enabled in this \
                   workspace. Click a row to fire its command; each row's \
                   right-click menu handles Configure / Uninstall / Toggle."
                .into(),
            try_it: vec![PaletteLink::new(
                "integrations.show_installed",
                "Open Installed tab",
            )],
            ..Default::default()
        }),
        IntegrationsTabMarketplace => Some(InfoViewCopy {
            title: "Integrations — Marketplace".into(),
            body: "Browse installable integrations from the hosted catalog. \
                   Enter installs the highlighted row into this workspace."
                .into(),
            try_it: vec![PaletteLink::new(
                "integrations.show_marketplace",
                "Open Marketplace tab",
            )],
            ..Default::default()
        }),
        IntegrationsTabRefresh => Some(InfoViewCopy {
            title: "Integrations — refresh".into(),
            body: "Rescan the integrations directory + the hosted marketplace \
                   catalog. Picks up freshly-installed siblings and drops \
                   uninstalled ones."
                .into(),
            try_it: vec![PaletteLink::new(
                "integrations.refresh",
                "Refresh integrations",
            )],
            ..Default::default()
        }),
        IntegrationsTabSort => Some(InfoViewCopy {
            title: "Integrations — sort".into(),
            body: "Cycle the sort order for the current tab (A-Z / recently \
                   used / installed date). Click to toggle."
                .into(),
            try_it: vec![PaletteLink::new(
                "integrations.cycle_sort",
                "Cycle sort order",
            )],
            ..Default::default()
        }),
        StatuslineCoverage => Some(InfoViewCopy {
            title: "Test coverage".into(),
            body: "Line/branch coverage from the latest run. Click to open the \
                   overlay with per-file breakdown; right-click for refresh / \
                   filter / open-report actions."
                .into(),
            try_it: vec![PaletteLink::new(
                "tattle_coverage_ext.open",
                "Open coverage pane",
            )],
            ..Default::default()
        }),
        // 2026-08-17 — data-driven dynamic statusline chips. Copy
        // is resolved via `statusline_segment_copy` in `lookup`
        // (which has access to `App` to walk the manifests). If
        // we reach here we're inside `chip_copy` which is
        // App-less, so return None and let the caller's fallback
        // path handle it.
        StatuslineSegment(_) => None,
    }
}

// ── Tree rows ────────────────────────────────────────────────────────

fn tree_row_copy(label: &str, is_dir: bool) -> Option<InfoViewCopy> {
    if is_dir {
        return Some(InfoViewCopy {
            title: format!("{label}/"),
            body: "Directory. Enter or click to expand; walk the tree with arrows \
                   or j/k. Right-click for rename / cut / copy / new file."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Enter", "Expand / collapse"),
                ShortcutHint::new("→ / ←", "Expand / collapse (arrows)"),
            ],
            ..Default::default()
        });
    }
    // Language-specific file rows — the copy dictionary can fan out
    // per extension. Seed with the ones most Rust / TS / Python devs
    // hover daily; the writer agent adds the rest.
    // Case-insensitive extension match. `rsplit('.').next()` on a
    // dot-less filename like `Dockerfile` returns the WHOLE filename
    // capitalized — before we lowercased here, `"Dockerfile"` never
    // hit the `"dockerfile"` arm. R10 multilang SEV-2.
    let ext = label.rsplit('.').next()?.to_ascii_lowercase();
    // R10 multilang SEV-3 — `.d.ts` declaration files got the plain
    // TypeScript copy. Check the double-ext BEFORE falling to the
    // last-segment match.
    if label.to_ascii_lowercase().ends_with(".d.ts") {
        return Some(InfoViewCopy {
            title: format!("{label} — TypeScript declarations"),
            body: "`.d.ts` — TypeScript type declarations. No runtime code; \
                   describes the shape of a JS module for tsserver to consume. \
                   Editing here changes types, not behavior."
                .into(),
            shortcuts: vec![
                ShortcutHint::new("Enter", "Open in the active pane"),
                ShortcutHint::new("Ctrl+Enter", "Open in a horizontal split"),
            ],
            ..Default::default()
        });
    }
    // Filename-keyed rows — checked BEFORE the extension fall-through
    // so a file mnml's tree renderer icons by whole filename
    // (`src/ui/icons.rs::filename_icon`) gets copy that matches, not
    // the generic extension blurb (`package.json` deserves npm-manifest
    // copy, not generic "JSON data"). 2026-08-11 fill batch.
    if let Some(copy) = filename_row_copy(label) {
        return Some(copy);
    }
    let (lang, body): (&str, &str) = match ext.as_str() {
        "rs" => (
            "Rust source",
            "Compiled with cargo. Hover a symbol in the buffer for LSP info \
             (once the LSP has warmed up).",
        ),
        "ts" | "tsx" => (
            "TypeScript source",
            "TypeScript / TSX. LSP fires once tsserver is up — takes a few \
             seconds on first open of the workspace.",
        ),
        "py" => (
            "Python source",
            "Python. LSP via pyright once mnml detects a Python interpreter.",
        ),
        "md" | "mdx" => (
            "Markdown",
            "Rendered inline by default when `[ui] render_markdown = true`. \
             `:e path.md` opens the raw editor instead.",
        ),
        "toml" => (
            "TOML config",
            "TOML config file. No LSP; syntax-only highlighting.",
        ),
        "json" => (
            "JSON data",
            "JSON file. Syntax-only highlighting; use a `.http` or `.curl` file \
             to send this as a request body.",
        ),
        "go" => (
            "Go source",
            "Go. LSP fires once gopls is on PATH; module boundary comes from \
             the nearest `go.mod`.",
        ),
        "sh" | "bash" | "zsh" => (
            "Shell script",
            "POSIX / bash / zsh script. No LSP by default; `:!chmod +x` on a new \
             script makes it executable.",
        ),
        "yaml" | "yml" => (
            "YAML config",
            "YAML config file. Indentation-sensitive — mnml paints trailing \
             whitespace red when `[ui] highlight_trailing_ws` is on.",
        ),
        "js" | "jsx" => (
            "JavaScript",
            "JavaScript / JSX. tsserver handles both TS and JS when it warms up, \
             so LSP hover works even without types.",
        ),
        "html" | "htm" => (
            "HTML markup",
            "HTML. No LSP; syntax-only highlighting. Pair with a `.http` file \
             next to it if this is a request-body template.",
        ),
        "css" | "scss" | "sass" => (
            "Stylesheet",
            "CSS / SCSS / SASS. Syntax-only highlighting; no LSP.",
        ),
        "sql" => (
            "SQL",
            "SQL script. Syntax-only highlighting; no linter. Run against a live \
             connection through your usual client — mnml doesn't execute.",
        ),
        "dockerfile" => (
            "Dockerfile",
            "Dockerfile. Syntax-only highlighting. `:!docker build .` from the \
             cmdline works if docker is on PATH.",
        ),
        // ── Top-20 tree-row languages (fill batch 2026-08-11) ────────
        // src: src/ui/icons.rs::extension_icon — grouped to match the
        // renderer's icon groupings so copy and icon stay 1:1.
        "vue" => (
            "Vue single-file component",
            "Vue 3 SFC — `<template>` / `<script>` / `<style>` blocks in one \
             file. Syntax-only highlighting; no dedicated LSP yet.",
        ),
        "svelte" => (
            "Svelte component",
            "Svelte single-file component — markup, script, and scoped styles \
             together. Syntax-only highlighting; no LSP.",
        ),
        "c" => (
            "C source",
            "C source file. Syntax-only highlighting; no LSP wired in yet.",
        ),
        "cpp" => (
            "C++ source",
            "C++ source file. Syntax-only highlighting; no LSP wired in yet.",
        ),
        "h" | "hpp" => (
            "C/C++ header",
            "Declarations only, no implementation. Syntax-only highlighting; \
             no LSP.",
        ),
        "java" => (
            "Java source",
            "Java source file. Syntax-only highlighting; no LSP (jdtls isn't \
             wired in yet).",
        ),
        "kt" => (
            "Kotlin source",
            "Kotlin source file. Syntax-only highlighting; no LSP.",
        ),
        "swift" => (
            "Swift source",
            "Swift source file. Syntax-only highlighting; no LSP.",
        ),
        "cs" => (
            "C# source",
            "C# source file. Syntax-only highlighting; no LSP wired in yet.",
        ),
        "csproj" => (
            "MSBuild project file",
            "References, target framework, and package refs for a .NET \
             project. XML under the hood; syntax-only highlighting.",
        ),
        "sln" => (
            "Visual Studio solution",
            "Groups one or more `.csproj` projects for Visual Studio or \
             `dotnet build`. Plain-text format; syntax-only highlighting.",
        ),
        "cshtml" => (
            "Razor page",
            "ASP.NET Razor page — HTML markup with embedded C# `@` blocks. \
             Syntax-only highlighting.",
        ),
        "razor" => (
            "Razor component",
            "Blazor Razor component — HTML markup with embedded C#. \
             Syntax-only highlighting.",
        ),
        "fs" => (
            "F# source",
            "F# source file. Syntax-only highlighting; no LSP.",
        ),
        "xml" => (
            "XML data",
            "XML markup. Syntax-only highlighting; no schema validation.",
        ),
        "svg" => (
            "SVG image",
            "Scalable vector graphic — technically XML, but mnml treats it as \
             an image. No inline preview; open it in a browser to see it \
             rendered.",
        ),
        "png" | "jpg" | "jpeg" | "gif" | "webp" => (
            "Image",
            "Raster image. mnml doesn't render pixels inline here — open it \
             in a browser or image viewer to see it.",
        ),
        "http" | "curl" | "rest" | "request" => (
            "HTTP request file",
            "mnml's own request format — method, URL, headers, and body in \
             one file. Opening it launches the Request pane UI instead of a \
             plain-text editor.",
        ),
        // ── R13 fill batch (2026-08-15) — extension gaps ─────────────
        // src: src/ui/icons.rs::extension_icon
        "cjs" => (
            "CommonJS module",
            "Explicit CommonJS (`require` / `module.exports`) — same JS \
             runtime as plain `.js`, but the extension forces CommonJS even \
             inside a `\"type\": \"module\"` package. Syntax-only highlighting.",
        ),
        "mjs" => (
            "ES module",
            "Explicit ES module (`import` / `export`) — the extension forces \
             ESM even inside a package that defaults to CommonJS. \
             Syntax-only highlighting.",
        ),
        "less" => (
            "Less stylesheet",
            "Variables, nesting, and mixins that precompile to plain CSS. \
             Syntax-only highlighting; no LSP.",
        ),
        "csv" => (
            "CSV data",
            "Comma-separated tabular data. mnml renders it as plain text, \
             not a spreadsheet grid — no column alignment or sorting.",
        ),
        "ini" | "conf" => (
            "INI config",
            "Key=value settings grouped into `[section]` blocks. No LSP; \
             syntax-only highlighting.",
        ),
        "rb" => (
            "Ruby source",
            "Ruby source file. Syntax-only highlighting; no LSP (solargraph \
             isn't wired in yet).",
        ),
        "php" => (
            "PHP source",
            "PHP source file. Syntax-only highlighting; no LSP (intelephense \
             isn't wired in yet).",
        ),
        "lua" => (
            "Lua source",
            "Lua source file. Syntax-only highlighting; no LSP.",
        ),
        "ps1" => (
            "PowerShell script",
            "PowerShell script. Syntax-only highlighting; no LSP.",
        ),
        "txt" => (
            "Plain text",
            "No syntax highlighting applied — mnml opens it exactly as \
             written.",
        ),
        "lock" => (
            "Dependency lockfile",
            "Pins exact resolved dependency versions (Cargo.lock-style). \
             Generated by the package manager — hand-editing it is unusual \
             and gets overwritten on the next install.",
        ),
        "log" => (
            "Log file",
            "Append-only runtime output, not source. `Ctrl+F` (find) is \
             usually the fastest way to jump around a large one.",
        ),
        "exe" => (
            "Windows executable",
            "Binary Windows executable. mnml doesn't render binary content \
             — opening it shows raw bytes, not source.",
        ),
        "dll" => (
            "Windows library",
            "Binary Windows dynamic-link library. mnml doesn't render \
             binary content — opening it shows raw bytes, not source.",
        ),
        "zip" | "gz" | "tgz" => (
            "Compressed archive",
            "mnml doesn't unpack it inline — extract with a terminal pane \
             (`tar` / `unzip`) to browse the contents.",
        ),
        _ => return None,
    };
    Some(InfoViewCopy {
        title: format!("{label} — {lang}"),
        body: body.into(),
        shortcuts: vec![
            ShortcutHint::new("Enter", "Open in the active pane"),
            ShortcutHint::new("Ctrl+Enter", "Open in a horizontal split"),
        ],
        ..Default::default()
    })
}

/// Copy for tree rows keyed by their WHOLE filename rather than
/// extension — mirrors `src/ui/icons.rs::filename_icon`'s match set.
/// Checked before the extension fall-through in `tree_row_copy` so
/// `package.json` reads as an npm manifest, not generic "JSON data".
/// Case-insensitive on the filename (matches the icon lookup).
fn filename_row_copy(label: &str) -> Option<InfoViewCopy> {
    let (lang, body): (&str, &str) = match label.to_ascii_lowercase().as_str() {
        "package.json" => (
            "npm manifest",
            "Declares this package's dependencies, scripts, and metadata for \
             npm / pnpm / yarn. Syntax-only highlighting; no schema \
             validation. `npm run <script>` from a terminal pane runs \
             anything listed under `scripts`.",
        ),
        "dockerfile" => (
            "Dockerfile",
            "Defines how `docker build` assembles an image — base layer, \
             copied files, entrypoint. Syntax-only highlighting. \
             `:!docker build .` from the cmdline works if docker is on PATH.",
        ),
        ".env" => (
            "Environment variables",
            "Untracked key=value pairs the process reads at startup. This is \
             separate from mnml's own `{{VAR}}` substitution, which reads \
             `.mnml/env/<name>.env` in Request panes. Treat this file as \
             secrets — keep it out of git.",
        ),
        "makefile" => (
            "Build recipes",
            "Defines named targets (`make build`, `make test`, …) as shell \
             recipes. Tab-indentation is significant — a space where a tab \
             is expected is the #1 Makefile syntax error. No LSP; \
             syntax-only highlighting.",
        ),
        // ── R13 fill batch (2026-08-15) — filename-keyed gaps ────────
        // src: src/ui/icons.rs::filename_icon
        "package-lock.json" => (
            "npm lockfile",
            "Exact dependency-tree snapshot npm resolved from `package.json`. \
             Generated by `npm install` — don't hand-edit; a mismatch with \
             `package.json` triggers a warning on the next install.",
        ),
        "pnpm-lock.yaml" => (
            "pnpm lockfile",
            "Exact dependency-tree snapshot pnpm resolved from \
             `package.json`. Generated by `pnpm install` — don't hand-edit.",
        ),
        "tsconfig.json" => (
            "TypeScript project config",
            "Compiler options, path aliases, and `include`/`exclude` globs \
             that tsserver reads to resolve module paths. A wrong `baseUrl` \
             or `paths` entry here is the usual cause of false \
             'cannot find module' errors in the editor.",
        ),
        ".gitignore" => (
            "Git ignore rules",
            "Path patterns excluded from `git status` / `git add`. mnml's \
             own file picker excludes `.git/` unconditionally regardless of \
             what's listed here.",
        ),
        ".gitattributes" => (
            "Git attributes",
            "Per-path git behavior — line-ending normalization, diff \
             drivers, merge strategies, archive export-ignore. Affects what \
             `git` does with the file, not how mnml renders it.",
        ),
        ".gitconfig" => (
            "Git config",
            "INI-style git settings — user identity, aliases, remotes. A \
             repo's `.git/config` takes precedence over this one when both \
             set the same key.",
        ),
        ".eslintrc" => (
            "ESLint config",
            "Lint rules and plugin config for ESLint. mnml doesn't run \
             ESLint itself — pair with a terminal pane (`eslint .`) or an \
             LSP that surfaces its diagnostics.",
        ),
        ".prettierrc" => (
            "Prettier config",
            "Formatting rules — quote style, semicolons, line width — for \
             Prettier. mnml doesn't format on save from this file; run \
             `prettier --write` from a terminal pane.",
        ),
        ".editorconfig" => (
            "EditorConfig",
            "Cross-editor whitespace rules (indent size, tabs vs spaces, \
             trailing newline) keyed by glob. mnml doesn't read this yet — \
             its own indentation settings live under `[editor]` in mnml's \
             config.",
        ),
        ".dockerignore" => (
            "Docker ignore rules",
            "Paths excluded from the build context `docker build` sends to \
             the daemon — same glob syntax as `.gitignore`. Keeping it \
             tight speeds up builds and keeps secrets out of the image.",
        ),
        ".npmrc" => (
            "npm config",
            "Per-project npm settings — registry URL, auth tokens, \
             save-exact behavior. Treat auth-token lines as secrets and \
             keep them out of git.",
        ),
        ".nvmrc" => (
            "Node version pin",
            "A single line naming the Node version this project expects. \
             `nvm use` (or an nvm-aware shell hook) reads it automatically \
             on `cd`.",
        ),
        "docker-compose.yml" | "docker-compose.yaml" | "compose.yml" | "compose.yaml" => (
            "Compose file",
            "Defines the multi-container stack — services, networks, \
             volumes — for `docker compose up`. Indentation-sensitive YAML, \
             same as any other `.yml`; syntax-only highlighting.",
        ),
        "readme" | "readme.md" => (
            "Project readme",
            "The first thing a visitor to this repo or folder reads. mnml \
             renders it like any other Markdown file when \
             `[ui] render_markdown = true`; `:e` opens the raw source.",
        ),
        "license" => (
            "License text",
            "The legal terms this project is distributed under. Plain text \
             or Markdown depending on the project; mnml applies syntax-only \
             highlighting either way.",
        ),
        "copying" => (
            "License text (GNU convention)",
            "Same role as LICENSE — the GNU-project convention for the \
             license filename, common on GPL-licensed code. Plain text; no \
             highlighting.",
        ),
        _ => return None,
    };
    Some(InfoViewCopy {
        title: format!("{label} — {lang}"),
        body: body.into(),
        shortcuts: vec![
            ShortcutHint::new("Enter", "Open in the active pane"),
            ShortcutHint::new("Ctrl+Enter", "Open in a horizontal split"),
        ],
        ..Default::default()
    })
}

// ── Menu-bar items ───────────────────────────────────────────────────

fn menu_item_copy(menu: &str, item: &str) -> Option<InfoViewCopy> {
    match (menu, item) {
        ("View", i) if i.contains("wrap") || i.contains("Wrap") => Some(InfoViewCopy {
            title: "View → Toggle line wrap".into(),
            body: "Turns visual line-wrapping on/off for editor panes. Persists to \
                   `[ui] wrap` in your user config."
                .into(),
            try_it: vec![PaletteLink::new("view.toggle_wrap", "Toggle now")],
            ..Default::default()
        }),
        ("Go", i) if i.contains("Go to definition") => Some(InfoViewCopy {
            title: "Go → Go to definition".into(),
            body: "Jumps the cursor to where the symbol under the cursor is \
                   defined. Uses the active pane's LSP; falls back to a plain-text \
                   grep if no LSP is up."
                .into(),
            shortcuts: vec![ShortcutHint::new("gd", "Vim shortcut")],
            try_it: vec![
                PaletteLink::new("lsp.goto_definition", "Go to"),
                PaletteLink::new("lsp.peek_definition_overlay", "Peek instead"),
            ],
            ..Default::default()
        }),
        // ── R14 modernize pass (2026-08-16) — Go menu gaps ───────────
        // src: src/menu_bar.rs::go_menu
        ("Go", i) if i.contains("Go to file") => Some(InfoViewCopy {
            title: "Go → Go to file…".into(),
            body: "Opens the fuzzy file picker over the workspace — same \
                   overlay as `Ctrl+P`. Type to match, Enter opens in the \
                   active pane."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+P", "Go to file")],
            try_it: vec![PaletteLink::new("view.discovery", "Go to file")],
            ..Default::default()
        }),
        ("Go", i) if i.contains("Go to line") => Some(InfoViewCopy {
            title: "Go → Go to line…".into(),
            body: "Prompts for a 1-based line number and jumps the cursor \
                   there in the active buffer."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+G", "Go to line")],
            try_it: vec![PaletteLink::new("editor.goto_line", "Go to line…")],
            ..Default::default()
        }),
        ("Go", i) if i.contains("Previous buffer") => Some(InfoViewCopy {
            title: "Go → Previous buffer".into(),
            body: "Jumps to the previous buffer in MRU order — same as \
                   `Ctrl+PageUp` or the back-arrow chip in the palette bar."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+PageUp", "Previous buffer")],
            try_it: vec![PaletteLink::new("buffer.prev", "Previous buffer")],
            ..Default::default()
        }),
        ("Go", i) if i.contains("Next buffer") => Some(InfoViewCopy {
            title: "Go → Next buffer".into(),
            body: "Jumps to the next buffer in MRU order — same as \
                   `Ctrl+PageDown` or the forward-arrow chip in the palette \
                   bar."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+PageDown", "Next buffer")],
            try_it: vec![PaletteLink::new("buffer.next", "Next buffer")],
            ..Default::default()
        }),
        ("Go", i) if i.contains("Last buffer") => Some(InfoViewCopy {
            title: "Go → Last buffer".into(),
            body: "Switches to whichever buffer was active before this one \
                   — vim's `Ctrl+^` alternate-file convention. Repeatable — \
                   fire again to bounce back."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Tab", "Last buffer")],
            try_it: vec![PaletteLink::new("buffer.last", "Last buffer")],
            ..Default::default()
        }),
        // ── R14 modernize pass (2026-08-16) — View menu gaps ─────────
        // src: src/menu_bar.rs::view_menu
        ("View", i) if i.contains("Command palette") => Some(InfoViewCopy {
            title: "View → Command palette".into(),
            body: "Opens the universal command palette — every mnml \
                   command, searchable by name or id. Same overlay `Ctrl+P` \
                   / Go → Go to file opens (they share `view.discovery`)."
                .into(),
            try_it: vec![PaletteLink::new("view.discovery", "Open palette")],
            ..Default::default()
        }),
        ("View", i) if i.contains("right panel") => Some(InfoViewCopy {
            title: "View → Toggle right panel".into(),
            body: "Shows / hides the right panel — hosts outline, \
                   diagnostics, or whatever route is currently pinned \
                   there."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+B", "Toggle")],
            try_it: vec![PaletteLink::new("view.toggle_right_panel", "Toggle now")],
            ..Default::default()
        }),
        ("View", i) if i.contains("Cycle menu bar") => Some(InfoViewCopy {
            title: "View → Cycle menu bar".into(),
            body: "Cycles the menu bar's visibility mode — always visible, \
                   auto-hide (appears on Alt), or fully hidden. Doesn't \
                   change any bindings, just how much chrome is on screen."
                .into(),
            try_it: vec![PaletteLink::new("view.menu_bar_cycle", "Cycle now")],
            ..Default::default()
        }),
        ("View", i) if i.contains("zen mode") => Some(InfoViewCopy {
            title: "View → Toggle zen mode".into(),
            body: "Hides the tree, bufferline, and statusline for a \
                   distraction-free single-pane view. Toggle again (or the \
                   chord) to bring the chrome back."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K z", "Toggle zen mode")],
            try_it: vec![PaletteLink::new("view.zen", "Toggle zen mode")],
            ..Default::default()
        }),
        ("View", i) if i.contains("workspace dots") => Some(InfoViewCopy {
            title: "View → Toggle workspace dots".into(),
            body: "Toggles the ● / ○ dot markers mnml paints on workspace- \
                   root rows in the tree — a quick at-a-glance read on which \
                   roots have uncommitted changes."
                .into(),
            try_it: vec![PaletteLink::new("view.toggle_workspace_dots", "Toggle now")],
            ..Default::default()
        }),
        ("View", i) if i.contains("Commands reference") => Some(InfoViewCopy {
            title: "View → Commands reference…".into(),
            body: "Opens every registered palette command, grouped, in a \
                   scratch buffer — the full surface the palette searches, \
                   without needing to type anything into it first."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.commands_reference",
                "Open commands reference",
            )],
            ..Default::default()
        }),
        ("View", i) if i.contains("Pick theme") => Some(InfoViewCopy {
            title: "View → Pick theme…".into(),
            body: "Opens the theme picker — every built-in + user-defined \
                   theme, live preview as you move the selection."
                .into(),
            try_it: vec![PaletteLink::new("theme.pick", "Pick theme…")],
            ..Default::default()
        }),
        ("View", i) if i.contains("Toggle theme") => Some(InfoViewCopy {
            title: "View → Toggle theme".into(),
            body: "Swaps between `[ui] theme` and `[ui] theme_toggle` — the \
                   same action as clicking the `●━` pill in the top-right \
                   chrome cluster."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K t", "Toggle theme")],
            try_it: vec![PaletteLink::new("theme.toggle", "Toggle theme")],
            ..Default::default()
        }),
        // src: src/menu_bar.rs — File menu
        ("File", i) if i.contains("New file") => Some(InfoViewCopy {
            title: "File → New file".into(),
            body: "Opens an untitled buffer in a fresh tab. Save it with `Ctrl+S` \
                   — mnml prompts for a path on first save."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+N", "New file")],
            try_it: vec![PaletteLink::new("file.new", "New file")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Open") && !i.contains("recent") => Some(InfoViewCopy {
            title: "File → Open…".into(),
            body: "Opens the file picker over the workspace. Type to fuzzy-match; \
                   Enter opens in the active pane, `Ctrl+Enter` opens in a split."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+P", "Open picker")],
            try_it: vec![PaletteLink::new("picker.files", "Open picker")],
            ..Default::default()
        }),
        // ── R14 modernize pass (2026-08-16) — File menu gaps ─────────
        // src: src/menu_bar.rs::file_menu
        ("File", i) if i.contains("Add folder to workspace") => Some(InfoViewCopy {
            title: "File → Add folder to workspace…".into(),
            body: "Adds a second (or third…) folder as an extra workspace \
                   root — the tree grows a new top-level section instead of \
                   replacing what's already open. Runtime only; not \
                   persisted to config."
                .into(),
            try_it: vec![PaletteLink::new("view.add_workspace", "Add folder")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Open recent file") => Some(InfoViewCopy {
            title: "File → Open recent file".into(),
            body: "A submenu listing files touched this session, most- \
                   recent first — same list `Ctrl+R` opens as a picker \
                   instead. Pick one to open it in the active pane."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+R", "Recent files (picker)")],
            try_it: vec![PaletteLink::new("picker.recent", "Open recent files")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Switch workspace") => Some(InfoViewCopy {
            title: "File → Switch workspace…".into(),
            body: "Opens the workspace picker — swaps the tree to a \
                   different root entirely, as opposed to Add folder to \
                   workspace which keeps the current one and adds another \
                   alongside it."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+O", "Switch workspace")],
            try_it: vec![PaletteLink::new(
                "view.switch_workspace",
                "Switch workspace",
            )],
            ..Default::default()
        }),
        ("File", i) if i.contains("Close tab") => Some(InfoViewCopy {
            title: "File → Close tab".into(),
            body: "Closes the active buffer. Dirty buffers prompt before \
                   discarding; `Ctrl+Shift+T` reopens the last closed tab \
                   if you change your mind."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+W", "Close tab")],
            try_it: vec![PaletteLink::new("buffer.close", "Close tab")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Settings") => Some(InfoViewCopy {
            title: "File → Settings…".into(),
            body: "Opens the keyboard-driven Settings overlay — sectioned \
                   discrete-choice rows for UI, editor, and integration \
                   toggles. Same overlay as mnml → Settings…."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+,", "Open Settings")],
            try_it: vec![PaletteLink::new("view.settings", "Open Settings")],
            ..Default::default()
        }),
        // Guard tightened (2026-08-16): menu icons moved to their own
        // `MenuItem::Action.icon` field (#886) — labels are now clean
        // ("Save", not a glyph-prefixed string), so an exact match is
        // both correct and simpler than the old glyph-survival anchor.
        ("File", "Save") => Some(InfoViewCopy {
            title: "File → Save".into(),
            body: "Writes the active buffer to disk. Untitled buffers prompt \
                       for a path first."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+S", "Save")],
            try_it: vec![PaletteLink::new("file.save", "Save now")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Save all") => Some(InfoViewCopy {
            title: "File → Save all".into(),
            body: "Writes every dirty buffer to disk in one pass. Untitled \
                   buffers get skipped (they'd need a path prompt each)."
                .into(),
            try_it: vec![PaletteLink::new("file.save_all", "Save all")],
            ..Default::default()
        }),
        ("File", i) if i.contains("Quit") => Some(InfoViewCopy {
            title: "File → Quit".into(),
            body: "Closes mnml. If any buffer is dirty, mnml prompts before \
                   discarding — `:qa!` force-quits without prompt."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Q", "Quit")],
            try_it: vec![PaletteLink::new("app.quit", "Quit")],
            ..Default::default()
        }),
        // src: src/menu_bar.rs — Edit menu
        // Drift fix (2026-08-16): the old broad guards
        // (`contains("Find") && !contains("Replace")` /
        // `contains("Replace")`) swallowed "Find next", "Find
        // previous", "Find in files…", and "Replace in files…" too —
        // all 4 fired the wrong ("Edit → Find" / "Edit → Replace")
        // copy since they're checked first. Tightened to exact labels
        // + added the 4 missing distinct entries.
        ("Edit", "Find…") => Some(InfoViewCopy {
            title: "Edit → Find…".into(),
            body: "Opens the find bar over the active buffer. Type to search; \
                   `n` / `N` step forward / back; Esc closes."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+F", "Find")],
            try_it: vec![PaletteLink::new("find.find", "Find in buffer")],
            ..Default::default()
        }),
        ("Edit", "Find next") => Some(InfoViewCopy {
            title: "Edit → Find next".into(),
            body: "Jumps to the next match of the active find query in the \
                   current buffer. No-op with a toast if there's no active \
                   query yet — run Find first."
                .into(),
            shortcuts: vec![ShortcutHint::new("F3", "Find next")],
            try_it: vec![PaletteLink::new("find.next", "Find next")],
            ..Default::default()
        }),
        ("Edit", "Find previous") => Some(InfoViewCopy {
            title: "Edit → Find previous".into(),
            body: "Jumps to the previous match of the active find query — \
                   the reverse of Find next, same query."
                .into(),
            shortcuts: vec![ShortcutHint::new("Shift+F3", "Find previous")],
            try_it: vec![PaletteLink::new("find.prev", "Find previous")],
            ..Default::default()
        }),
        ("Edit", i) if i.contains("Replace") && !i.contains("files") => Some(InfoViewCopy {
            title: "Edit → Replace…".into(),
            body: "Opens the find + replace bar. Type the pattern, Tab to the \
                   replacement, Enter fires; `Ctrl+Alt+Enter` replaces all."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+H", "Replace")],
            try_it: vec![PaletteLink::new("find.replace", "Replace in buffer")],
            ..Default::default()
        }),
        ("Edit", i) if i.contains("Find in files") => Some(InfoViewCopy {
            title: "Edit → Find in files…".into(),
            body: "Greps the whole workspace (`rg` / `git grep`) instead of \
                   just the active buffer — results land in a dedicated \
                   grep pane, one row per match, Enter jumps to it."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+F", "Find in files")],
            try_it: vec![PaletteLink::new("find.grep", "Find in files")],
            ..Default::default()
        }),
        ("Edit", i) if i.contains("Replace in files") => Some(InfoViewCopy {
            title: "Edit → Replace in files…".into(),
            body: "Applies a replacement across every hit in the active \
                   grep pane's results — the workspace-wide sibling of the \
                   single-buffer Replace. Review the match list before \
                   firing; this touches multiple files at once."
                .into(),
            try_it: vec![PaletteLink::new("find.grep_replace", "Replace in files")],
            ..Default::default()
        }),
        // Drift fix (2026-08-11): removed the `("Edit", "Undo")` arm
        // — the Edit menu has no Undo item (src/menu_bar.rs:207-224,
        // only Find/Replace variants). `editor.undo` exists as a
        // command but isn't on this menu; the arm never fired.
        // src: src/menu_bar.rs — View menu
        ("View", i) if i.contains("left panel") || i.contains("file tree") => Some(InfoViewCopy {
            title: "View → Toggle left panel".into(),
            body: "Shows / hides the left panel — files, git, integrations, \
                       agents, HTTP, findings all live there."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+B", "Toggle sidebar")],
            try_it: vec![PaletteLink::new("view.toggle_tree", "Toggle now")],
            ..Default::default()
        }),
        ("View", i) if i.contains("bottom panel") => Some(InfoViewCopy {
            title: "View → Toggle bottom panel".into(),
            body: "Shows / hides the docked bottom-pane host. Pane content and \
                   height persist between toggles."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+J", "Toggle")],
            try_it: vec![PaletteLink::new("view.toggle_bottom_panel", "Toggle now")],
            ..Default::default()
        }),
        ("View", i) if i.contains("hover-help") || i.contains("Hover") => Some(InfoViewCopy {
            title: "View → Toggle hover-help".into(),
            body: "Shows / hides this Info View — the panel at the bottom \
                       of the left rail. Setting persists across restarts."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.toggle_hover_help",
                "Hide this panel",
            )],
            docs: Some("https://mnml.sh/manual/hover-help/".into()),
            ..Default::default()
        }),
        // src: src/menu_bar.rs — Window menu (fill batch 2026-08-11)
        ("Window", i) if i.contains("Reopen closed tab") => Some(InfoViewCopy {
            title: "Window → Reopen closed tab".into(),
            body: "Restores the most-recently-closed buffer, exactly where you \
                   left it. Repeatable — keep firing it to walk back further."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+T", "Reopen closed tab")],
            try_it: vec![PaletteLink::new("buffer.reopen", "Reopen")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Close other tabs") => Some(InfoViewCopy {
            title: "Window → Close other tabs".into(),
            body: "Closes every pane except the active one. Unsaved-changes \
                   guards still apply per-buffer, so a dirty tab prompts before \
                   it's discarded."
                .into(),
            try_it: vec![PaletteLink::new("view.close_others", "Close others")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Pin / unpin tab") => Some(InfoViewCopy {
            title: "Window → Pin / unpin tab".into(),
            body: "Pins the active tab so it sticks to the front of the \
                   bufferline instead of scrolling out of view. Pinned tabs \
                   also survive `Close other tabs`."
                .into(),
            try_it: vec![PaletteLink::new("buffer.pin_toggle", "Toggle pin")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Split right") => Some(InfoViewCopy {
            title: "Window → Split right".into(),
            body: "Splits the active pane side by side, opening the same \
                   buffer in both halves so you can scroll them independently."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+\\", "Split right")],
            try_it: vec![PaletteLink::new("view.split_right", "Split right")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Split down") => Some(InfoViewCopy {
            title: "Window → Split down".into(),
            body: "Splits the active pane top and bottom, opening the same \
                   buffer in both halves so you can scroll them independently."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+\\", "Split down")],
            try_it: vec![PaletteLink::new("view.split_down", "Split down")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Close split") => Some(InfoViewCopy {
            title: "Window → Close split".into(),
            body: "Closes the active split (or the active buffer, if there's \
                   only one split left) and hands its space to the remaining \
                   panes."
                .into(),
            try_it: vec![PaletteLink::new("view.close_split", "Close split")],
            ..Default::default()
        }),
        // "Equalize splits" — must not also catch "Auto-equalize on
        // split / close (toggle)" below; that item's label doesn't
        // contain this exact phrase.
        ("Window", i) if i.contains("Equalize splits") => Some(InfoViewCopy {
            title: "Window → Equalize splits".into(),
            body: "Resizes every split in the current tab page back to equal \
                   size in one shot. Same as vim's `Ctrl+W =`."
                .into(),
            try_it: vec![PaletteLink::new("view.equalize_splits", "Equalize")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Auto-equalize") => Some(InfoViewCopy {
            title: "Window → Auto-equalize splits (toggle)".into(),
            body: "When on, mnml automatically re-equalizes every split's size \
                   each time you split or close a pane, instead of leaving the \
                   ratio wherever it landed."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.toggle_auto_equalize_splits",
                "Toggle",
            )],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Merge splits into tabs") => Some(InfoViewCopy {
            title: "Window → Merge splits into tabs".into(),
            body: "Collapses the whole split tree in the current tab page into \
                   one leaf, keeping every pane as a tab there instead. \
                   Reversible with Spread tabs into splits."
                .into(),
            try_it: vec![PaletteLink::new("layout.merge_to_tabs", "Merge to tabs")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Spread tabs into splits") => Some(InfoViewCopy {
            title: "Window → Spread tabs into splits".into(),
            body: "Lays every tab in the active leaf out into its own split, \
                   using the same auto-tile heuristic as AI grid layout. \
                   Reversible with Merge splits into tabs."
                .into(),
            try_it: vec![PaletteLink::new(
                "layout.spread_to_splits",
                "Spread to splits",
            )],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Grow split width") => Some(InfoViewCopy {
            title: "Window → Grow split width".into(),
            body: "Widens the active split at its neighbors' expense. Same as \
                   vim's `Ctrl+W >`; repeatable."
                .into(),
            try_it: vec![PaletteLink::new("view.split_grow_width", "Grow width")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Grow split height") => Some(InfoViewCopy {
            title: "Window → Grow split height".into(),
            body: "Grows the active split's height at its neighbors' expense. \
                   Same as vim's `Ctrl+W +`; repeatable."
                .into(),
            try_it: vec![PaletteLink::new("view.split_grow_height", "Grow height")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Focus split left") => Some(InfoViewCopy {
            title: "Window → Focus split left".into(),
            body: "Moves keyboard focus to the split immediately to the left \
                   of the active one, without touching the layout."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+Left", "Focus left")],
            try_it: vec![PaletteLink::new("view.focus_left", "Focus left")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Focus split right") => Some(InfoViewCopy {
            title: "Window → Focus split right".into(),
            body: "Moves keyboard focus to the split immediately to the right \
                   of the active one, without touching the layout."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+Right", "Focus right")],
            try_it: vec![PaletteLink::new("view.focus_right", "Focus right")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Focus split up") => Some(InfoViewCopy {
            title: "Window → Focus split up".into(),
            body: "Moves keyboard focus to the split immediately above the \
                   active one, without touching the layout."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+Up", "Focus up")],
            try_it: vec![PaletteLink::new("view.focus_up", "Focus up")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Focus split down") => Some(InfoViewCopy {
            title: "Window → Focus split down".into(),
            body: "Moves keyboard focus to the split immediately below the \
                   active one, without touching the layout."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+K Ctrl+Down", "Focus down")],
            try_it: vec![PaletteLink::new("view.focus_down", "Focus down")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("AI layout: Grid") => Some(InfoViewCopy {
            title: "Window → AI layout: Grid".into(),
            body: "Switches open Claude / Codex sessions to an auto-tiled grid \
                   of splits (up to 8) instead of stacking them as tabs in one \
                   leaf."
                .into(),
            try_it: vec![PaletteLink::new("view.ai_layout_grid", "Switch to grid")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("AI layout: Tabs") => Some(InfoViewCopy {
            title: "Window → AI layout: Tabs".into(),
            body: "Switches open Claude / Codex sessions to append as tabs in \
                   the active leaf instead of tiling each one into its own \
                   split."
                .into(),
            try_it: vec![PaletteLink::new("view.ai_layout_tabs", "Switch to tabs")],
            ..Default::default()
        }),
        ("Window", i) if i.contains("Restart mnml") => Some(InfoViewCopy {
            title: "Window → Restart mnml".into(),
            body: "Rebuilds and relaunches mnml via `run.sh`'s restart loop, \
                   re-reading source + config from disk. Prompts first if any \
                   buffer is dirty."
                .into(),
            try_it: vec![PaletteLink::new("app.restart", "Restart now")],
            ..Default::default()
        }),
        // ── R13 fill batch (2026-08-15) — Brand / mnml menu ──────────
        // src: src/menu_bar.rs::brand_menu — label is "❯_  mnml"; match
        // on a substring since the menu word carries a leading glyph.
        (menu, i) if menu.contains("mnml") && i.contains("About mnml") => Some(InfoViewCopy {
            title: "mnml → About mnml…".into(),
            body: "Shows the running version, build info, and the active \
                   workspace path. Useful for filing a bug report or \
                   checking whether an update actually landed."
                .into(),
            try_it: vec![PaletteLink::new("view.about", "About mnml")],
            ..Default::default()
        }),
        (menu, i) if menu.contains("mnml") && i.contains("Settings") => Some(InfoViewCopy {
            title: "mnml → Settings…".into(),
            body: "Opens the keyboard-driven Settings overlay — sectioned \
                   discrete-choice rows for UI, editor, and integration \
                   toggles. Config it doesn't cover stays TOML-edited."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+,", "Open Settings")],
            try_it: vec![PaletteLink::new("view.settings", "Open Settings")],
            ..Default::default()
        }),
        (menu, i) if menu.contains("mnml") && i.contains("Quit mnml") => Some(InfoViewCopy {
            title: "mnml → Quit mnml".into(),
            body: "Closes mnml entirely. If any buffer is dirty, mnml \
                   prompts before discarding — the same guard as \
                   File → Quit."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Q", "Quit")],
            try_it: vec![PaletteLink::new("app.quit", "Quit")],
            ..Default::default()
        }),
        // ── R13 fill batch (2026-08-15) — Selection menu ─────────────
        // src: src/menu_bar.rs::selection_menu
        ("Selection", i) if i.contains("Expand selection") => Some(InfoViewCopy {
            title: "Selection → Expand selection".into(),
            body: "Grows the selection outward to the next enclosing \
                   syntax node — word, then expression, then statement, \
                   then block. Uses the active pane's LSP; a no-op until \
                   it's warmed up."
                .into(),
            try_it: vec![PaletteLink::new("lsp.selection_expand", "Expand")],
            ..Default::default()
        }),
        ("Selection", i) if i.contains("Shrink selection") => Some(InfoViewCopy {
            title: "Selection → Shrink selection".into(),
            body: "Shrinks the selection back down to the previous syntax \
                   node — the reverse of Expand selection. Same LSP \
                   dependency."
                .into(),
            try_it: vec![PaletteLink::new("lsp.selection_shrink", "Shrink")],
            ..Default::default()
        }),
        ("Selection", i) if i.contains("Add cursor above") => Some(InfoViewCopy {
            title: "Selection → Add cursor above".into(),
            body: "Adds a second cursor directly above the primary one, \
                   same column. Repeatable — keep firing to stack more \
                   cursors up the buffer."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Alt+↑", "Add cursor above")],
            try_it: vec![PaletteLink::new(
                "editor.add_cursor_above",
                "Add cursor above",
            )],
            ..Default::default()
        }),
        ("Selection", i) if i.contains("Add cursor below") => Some(InfoViewCopy {
            title: "Selection → Add cursor below".into(),
            body: "Adds a second cursor directly below the primary one, \
                   same column. Repeatable — keep firing to stack more \
                   cursors down the buffer."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Alt+↓", "Add cursor below")],
            try_it: vec![PaletteLink::new(
                "editor.add_cursor_below",
                "Add cursor below",
            )],
            ..Default::default()
        }),
        ("Selection", i) if i.contains("Add cursor at next match") => Some(InfoViewCopy {
            title: "Selection → Add cursor at next match".into(),
            body: "Adds a cursor at the next occurrence of the word under \
                   the cursor (or the current selection) — VS Code's \
                   `Ctrl+D` convention. Fire repeatedly to pick up more \
                   occurrences one at a time."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+D", "Add cursor at next match")],
            try_it: vec![PaletteLink::new(
                "editor.add_cursor_at_next_word",
                "Add cursor at next match",
            )],
            ..Default::default()
        }),
        ("Selection", i) if i.contains("Select all occurrences") => Some(InfoViewCopy {
            title: "Selection → Select all occurrences".into(),
            body: "Selects every occurrence of the word under the cursor \
                   (or current selection) in one shot, each as its own \
                   cursor — the select-all version of Add cursor at next \
                   match."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+Shift+L", "Select all occurrences")],
            try_it: vec![PaletteLink::new(
                "editor.select_all_occurrences",
                "Select all occurrences",
            )],
            ..Default::default()
        }),
        ("Selection", i) if i.contains("Clear extra cursors") => Some(InfoViewCopy {
            title: "Selection → Clear extra cursors".into(),
            body: "Drops every cursor except the primary one, collapsing \
                   back to single-cursor editing."
                .into(),
            try_it: vec![PaletteLink::new(
                "editor.clear_extra_cursors",
                "Clear extra cursors",
            )],
            ..Default::default()
        }),
        // ── R13 fill batch (2026-08-15) — Run menu (DAP) ─────────────
        // src: src/menu_bar.rs::run_menu
        ("Run", i) if i.contains("Start debugging") => Some(InfoViewCopy {
            title: "Run → Start debugging".into(),
            body: "Launches a DAP debug session for the active buffer's \
                   filetype, using whatever adapter mnml has configured \
                   for it. Breakpoints set beforehand are honored once the \
                   session connects."
                .into(),
            shortcuts: vec![ShortcutHint::new("F5", "Start debugging")],
            try_it: vec![PaletteLink::new("dap.run", "Start debugging")],
            ..Default::default()
        }),
        ("Run", i) if i.contains("Toggle breakpoint") => Some(InfoViewCopy {
            title: "Run → Toggle breakpoint".into(),
            body: "Sets or clears a breakpoint on the cursor's line. Works \
                   whether or not a session is running yet — breakpoints \
                   set ahead of time get sent once one connects."
                .into(),
            shortcuts: vec![ShortcutHint::new("F9", "Toggle breakpoint")],
            try_it: vec![PaletteLink::new(
                "dap.toggle_breakpoint",
                "Toggle breakpoint",
            )],
            ..Default::default()
        }),
        ("Run", i) if i.contains("Conditional breakpoint") => Some(InfoViewCopy {
            title: "Run → Conditional breakpoint…".into(),
            body: "Same as Toggle breakpoint, but prompts for a condition \
                   expression first — the debugger only stops when it \
                   evaluates truthy."
                .into(),
            shortcuts: vec![ShortcutHint::new("Shift+F9", "Conditional breakpoint")],
            try_it: vec![PaletteLink::new(
                "dap.toggle_breakpoint_conditional",
                "Conditional breakpoint",
            )],
            ..Default::default()
        }),
        ("Run", i) if i.contains("Step in") => Some(InfoViewCopy {
            title: "Run → Step in".into(),
            body: "Steps execution into the function call on the current \
                   line, pausing at its first statement. Only live while a \
                   DAP session is paused at a breakpoint."
                .into(),
            shortcuts: vec![ShortcutHint::new("F11", "Step in")],
            try_it: vec![PaletteLink::new("dap.step_in", "Step in")],
            ..Default::default()
        }),
        ("Run", i) if i.contains("Step out") => Some(InfoViewCopy {
            title: "Run → Step out".into(),
            body: "Runs until the current function returns, then pauses \
                   back in the caller. Only live while a DAP session is \
                   paused."
                .into(),
            shortcuts: vec![ShortcutHint::new("Shift+F11", "Step out")],
            try_it: vec![PaletteLink::new("dap.step_out", "Step out")],
            ..Default::default()
        }),
        ("Run", i) if i.contains("Step back") => Some(InfoViewCopy {
            title: "Run → Step back".into(),
            body: "Reverses one step of execution. Requires a \
                   record-replay-capable debug adapter — most adapters \
                   don't support it, and the command is a no-op there."
                .into(),
            try_it: vec![PaletteLink::new("dap.step_back", "Step back")],
            ..Default::default()
        }),
        // ── R13 fill batch (2026-08-15) — Terminal menu ──────────────
        // src: src/menu_bar.rs::terminal_menu
        ("Terminal", i) if i.contains("New terminal") => Some(InfoViewCopy {
            title: "Terminal → New terminal (split below)".into(),
            body: "Opens a fresh shell in a new Pty pane, split below the \
                   active one. Each shell pane is independent — its own \
                   working directory, its own scrollback."
                .into(),
            try_it: vec![PaletteLink::new("term.shell", "New terminal")],
            ..Default::default()
        }),
        ("Terminal", i) if i.contains("Toggle scratch terminal") => Some(InfoViewCopy {
            title: "Terminal → Toggle scratch terminal".into(),
            body: "Shows / hides a quick scratch shell strip docked at the \
                   bottom — for one-off commands without committing to a \
                   full split."
                .into(),
            shortcuts: vec![ShortcutHint::new("Ctrl+`", "Toggle scratch terminal")],
            try_it: vec![PaletteLink::new(
                "term.scratch_toggle",
                "Toggle scratch terminal",
            )],
            ..Default::default()
        }),
        ("Terminal", i) if i.contains("Rename terminal") => Some(InfoViewCopy {
            title: "Terminal → Rename terminal".into(),
            body: "Renames the active Pty pane's tab label. Handy once \
                   several shells are open and the default names all look \
                   alike in the bufferline."
                .into(),
            try_it: vec![PaletteLink::new("term.rename", "Rename terminal")],
            ..Default::default()
        }),
        // ── R13 fill batch (2026-08-15) — Help menu ───────────────────
        // src: src/menu_bar.rs::help_menu
        ("Help", i) if i.contains("Welcome") => Some(InfoViewCopy {
            title: "Help → Welcome".into(),
            body: "Opens the Welcome overlay — a shortcuts cheatsheet \
                   covering the highest-value chords across editing, \
                   navigation, and panels. Good first stop after a fresh \
                   install."
                .into(),
            try_it: vec![PaletteLink::new("view.welcome", "Open Welcome")],
            ..Default::default()
        }),
        ("Help", i) if i.contains("Keybindings") => Some(InfoViewCopy {
            title: "Help → Keybindings & help".into(),
            body: "Opens the auto-generated keymap reference — every bound \
                   chord, grouped by command, always in sync with the live \
                   keymap rather than a doc that can drift."
                .into(),
            shortcuts: vec![ShortcutHint::new("F1", "Keybindings & help")],
            try_it: vec![PaletteLink::new("view.help", "Open keybindings")],
            ..Default::default()
        }),
        ("Help", i) if i.contains("Commands reference") => Some(InfoViewCopy {
            title: "Help → Commands reference…".into(),
            body: "Opens every registered palette command, grouped, in a \
                   scratch buffer — the full surface the palette searches, \
                   without needing to type anything into it first."
                .into(),
            try_it: vec![PaletteLink::new(
                "view.commands_reference",
                "Open commands reference",
            )],
            ..Default::default()
        }),
        ("Help", i) if i.contains("About mnml") => Some(InfoViewCopy {
            title: "Help → About mnml".into(),
            body: "Shows the running version, build info, and the active \
                   workspace path — same overlay as mnml → About mnml, \
                   reachable from the Help menu too."
                .into(),
            try_it: vec![PaletteLink::new("view.about", "About mnml")],
            ..Default::default()
        }),
        _ => None,
    }
}
