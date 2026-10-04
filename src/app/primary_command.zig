//! The one command a control runs on a left click, when it runs one —
//! read by the click (`app/dispatch.zig`) and by the info view's
//! `Key:` line (`app/info_view.zig`), so the chord the help names is
//! the chord of what the click does, and the two cannot drift.
//!
//! A control whose click is not a command (a menu it drops, a toast it
//! shows, a session it starts) answers null here; its right-click menu
//! never counts — the primary is the left button's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("../app.zig").App;
const command = @import("../core/command.zig");
const CommandId = command.CommandId;
const hit = @import("../ui/hit.zig");
const HitTarget = hit.HitTarget;
const render = @import("render.zig");
const md_preview = @import("md_preview.zig");
const zon_pane = @import("zon_pane.zig");
const zen = @import("zen.zig");
const sessions_mode = @import("sessions_mode.zig");
const statusline = @import("../ui/statusline.zig");
const statusline_app = @import("statusline.zig");
const activity_bar = @import("activity_bar.zig");
const tree_app = @import("tree.zig");
const launcher_dock = @import("launcher_dock.zig");
const cmd_picker = @import("cmd_picker.zig");
const picker_view = @import("../ui/picker.zig");

/// The command behind `target`'s left click, or null. `arena` holds
/// the launcher dock's rows while they are read.
pub fn of(app: *App, arena: Allocator, target: HitTarget) Allocator.Error!?CommandId {
    return switch (target) {
        .button => |id| button(app, id),
        .chip => |c| chip(app, c.panel, c.kind),
        // The tree's header chips: `tree.chipClick` runs this same id.
        .tree_chip => |c| tree_app.chipCommand(c),
        .launcher_dock => |part| try dockPart(app, arena, part),
        .overlay_item => |idx| paletteRow(app, idx),
        .statusline_seg => |seg| statusSeg(app, seg),
        .rail => |part| switch (part) {
            .section => |s| activity_bar.commandOf(s),
            .gear => .@"view.settings",
            else => null,
        },
        .menu_item => |mi| menuRow(app, mi.menu, mi.idx),
        .ai_placeholder => .@"ai.claude_code_new",
        else => null,
    };
}

/// The strip's mode chips — read ahead of the toast and overlay arms.
pub fn stripChip(id: u32) ?CommandId {
    if (id == md_preview.button_edit) return .@"markdown.edit_raw";
    if (id == md_preview.button_preview) return .@"markdown.preview";
    if (id == zon_pane.button_view) return .@"zon.view";
    if (id == zon_pane.button_source) return .@"zon.source";
    return null;
}

/// A chrome button's command. The strip's cluster (`onLeaf`) acts on
/// the leaf it sits on, which the click makes current first.
pub fn button(app: *const App, id: u32) ?CommandId {
    if (stripChip(id)) |c| return c;
    // The strip's `+` drops the `Create…` menu — no command — except in
    // git mode, where it brings a closed repo back.
    if (render.Button.newTabLeaf(id) != null) return if (app.git_palette.active) .@"git.reopen_repo" else null;
    return switch (@as(render.Button, @enumFromInt(id))) {
        .cmdline_inflight => .@"http.abort",
        .palette => .palette,
        .toggle_tree => .@"view.toggle_tree",
        .toggle_right_panel => .@"view.toggle_right_panel",
        .right_close => .@"view.right_panel_close_tab",
        .right_tab => .@"view.focus_right_panel",
        .bottom_close => .@"view.toggle_bottom_panel",
        .sidebar_pin => .@"view.sidebar_pin",
        .menu_bar_pin, .edge_grip_menu_bar => .@"view.menu_bar_pin",
        .edge_grip_dock => .@"view.dock_pin",
        .back => .@"buffer.prev",
        .forward => .@"buffer.next",
        .dropdown => .@"picker.recent",
        .new_tab_page => .@"tab.new",
        .tabs_label => .@"tab.picker",
        // The pill swaps to the configured alternate; without one it
        // opens the picker, so the click never dead-ends.
        .theme_toggle => if (app.cfg.ui.theme_toggle != null) .@"theme.toggle" else .@"theme.pick",
        .window_close => .@"app.quit",
        .split_term => .@"term.shell",
        .split_right => .@"view.split_right",
        .split_down => .@"view.split_down",
        // `ui.maximize_click`'s to say (`app/zen.zig`).
        .split_max => zen.clickCommand(app),
        .fullscreen_exit => .@"view.fullscreen",
        .all_tabs => .@"picker.buffers",
        // In the sessions mode the arrows step this column's stack.
        .session_prev => if (sessions_mode.showing(app)) .@"sessions.column_prev" else .@"ai.focus_prev_session",
        .session_next => if (sessions_mode.showing(app)) .@"sessions.column_next" else .@"ai.focus_next_session",
        else => null,
    };
}

/// The buttons whose command acts on the leaf they sit on.
pub fn onLeaf(id: u32) bool {
    return switch (@as(render.Button, @enumFromInt(id))) {
        .split_term, .split_right, .split_down, .split_max, .session_prev, .session_next => true,
        else => false,
    };
}

/// A statusline chip's left-click command.
pub fn statusSeg(app: *const App, seg: u32) ?CommandId {
    switch (seg) {
        statusline.seg_mode => return .@"editor.toggle_keymap",
        statusline.seg_position => return .@"editor.goto_line",
        statusline.seg_restricted => return .@"workspace.review_trust",
        else => {},
    }
    const id = statusline_app.SegId.of(seg) orelse return null;
    return switch (id) {
        .branch => .@"git.status_pane",
        .diagnostics => .@"lsp.diagnostics",
        .symbol => .@"outline.show",
        .macro => .@"vim.macro_toggle",
        .find => .@"find.find",
        .ai_claude => .@"ai.claude_usage",
        .ai_codex => .@"ai.codex_usage",
        .ghost => .@"ai.setup_suggestions",
        .coverage => .@"coverage.toast",
        .jobs => .@"jobs.show",
        .lsp => .@"lsp.status",
        .wrap => .@"view.toggle_wrap",
        .highlight => .@"editor.highlight_toggle_file",
        .stress => .@"perf.toast_stress",
        .bell => .@"messages.show",
        .clock => if (app.clock.mode == .utc) .@"clock.local" else .@"clock.utc",
        .workspace => if (app.git.repos.items.len > 1) .@"git.switch_repo" else .@"view.switch_workspace",
        .zoom => .@"view.toggle_zoom",
        .sessions => .@"view.activity_sessions",
        .session_prev => .@"ai.focus_prev_session",
        .session_next => .@"ai.focus_next_session",
        else => null,
    };
}

/// An open menu's row (menu 0, or 1 for the child list): the command
/// it runs. A kebab on a row (2, 3) opens the row's actions instead.
pub fn menuRow(app: *const App, menu: u32, idx: u16) ?CommandId {
    if (app.overlay != .menu) return null;
    const m = &app.overlay.menu;
    const list = switch (menu) {
        0 => m.items,
        1 => if (m.sub) |s| s.items else return null,
        else => return null,
    };
    if (idx >= list.len) return null;
    return switch (list[idx].action) {
        .command => |c| c,
        else => null,
    };
}

/// A panel header chip's command: the sort, refresh, new and ended
/// chips whose click is one registered command. A chip whose click is
/// the panel's own handler (git's refresh, the debug watch prompt, the
/// HTTP list's rescan, the sessions `+` menu, the scripts sort, the
/// diagnostics filter) answers null and keeps it.
pub fn chip(app: *const App, panel: hit.PanelId, kind: hit.ChipKind) ?CommandId {
    return switch (panel) {
        .todos => switch (kind) {
            .sort => .@"todos.sort",
            .refresh => .@"todos.refresh",
            .new => .@"todos.new",
            .history => null,
        },
        .notes => switch (kind) {
            .sort => .@"notes.sort",
            .refresh => .@"notes.refresh",
            .new => .@"notes.new",
            .history => null,
        },
        .findings => switch (kind) {
            .sort => .@"findings.sort",
            .refresh => .@"findings.refresh",
            .new => .@"findings.new",
            .history => null,
        },
        .sessions => switch (kind) {
            .sort => .@"sessions.sort",
            .refresh => .@"sessions.refresh",
            .history => .@"sessions.toggle_ended",
            .new => null,
        },
        .http => if (kind == .new) .@"http.new" else null,
        .integrations => switch (kind) {
            .sort => .@"integrations.cycle_sort",
            // The refresh acts on the tab it sits on; the dev tab's
            // rescan is no command.
            .refresh => switch (app.integrations.tab) {
                .installed => .@"integrations.refresh",
                .marketplace => .@"marketplace.refresh",
                else => null,
            },
            .new => .@"marketplace.add_source",
            .history => null,
        },
        .search => if (kind == .refresh) .@"search.refresh" else null,
        else => null,
    };
}

/// A launcher dock part: the pin chip's toggle, or an entry's command
/// — read off the rows `launcher_dock.activateAt` runs, an
/// integration's chip by its registered name. A pane row, the `+` menu
/// and a script's own command have no static id.
fn dockPart(app: *App, arena: Allocator, part: hit.LauncherDockPart) Allocator.Error!?CommandId {
    switch (part) {
        .pin => return .@"view.dock_pin",
        .item => |i| {
            const list = try launcher_dock.items(app, arena);
            if (i >= list.len) return null;
            return switch (list[i].action) {
                .static => |id| id,
                .named => |name| if (command.resolve(app, name)) |ref| switch (ref) {
                    .static => |id| id,
                    .dyn => null,
                } else null,
                else => null,
            };
        },
    }
}

/// A command palette row: the command it runs (`cmd_picker.accept`'s
/// `commandAt`). Every other overlay's rows answer null.
fn paletteRow(app: *const App, idx: u32) ?CommandId {
    if (app.overlay != .picker) return null;
    const p = &app.overlay.picker;
    if (p.kind != .commands or idx == picker_view.query_item or idx >= p.filtered.items.len) return null;
    const ref = cmd_picker.commandAt(app, p.filtered.items[idx]) orelse return null;
    return switch (ref) {
        .static => |id| id,
        .dyn => null,
    };
}
