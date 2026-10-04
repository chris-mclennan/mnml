//! The one command a control runs on a left click, when it runs one —
//! read by the click (`app/dispatch.zig`) and by the info view's
//! `Key:` line (`app/info_view.zig`), so the chord the help names is
//! the chord of what the click does, and the two cannot drift.
//!
//! A control whose click is not a command (a menu it drops, a toast it
//! shows, a session it starts) answers null here; its right-click menu
//! never counts — the primary is the left button's.

const std = @import("std");
const App = @import("../app.zig").App;
const command = @import("../core/command.zig");
const CommandId = command.CommandId;
const HitTarget = @import("../ui/hit.zig").HitTarget;
const render = @import("render.zig");
const md_preview = @import("md_preview.zig");
const zon_pane = @import("zon_pane.zig");
const zen = @import("zen.zig");
const sessions_mode = @import("sessions_mode.zig");
const statusline = @import("../ui/statusline.zig");
const statusline_app = @import("statusline.zig");
const activity_bar = @import("activity_bar.zig");

/// The command behind `target`'s left click, or null.
pub fn of(app: *const App, target: HitTarget) ?CommandId {
    return switch (target) {
        .button => |id| button(app, id),
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
