//! Settings, app side: the rows the overlay shows, what a change does,
//! and where it is written.
//!
//! Every row is a discrete choice over one `Config` field, named by its
//! dotted path (`ui.line_numbers`) — the same path `persistScalar` takes,
//! split on the dots. A bool offers `off / on`, an enum its tags, and
//! `ui.theme` the bundled themes. Number and text rows are v2.
//!
//! **The file follows the row.** Adjusting a row applies to the live
//! config at once and writes the value to the row's file (`Scope`: the
//! home config for a preference, the workspace's `.mnml/config.zon` for
//! a per-project view setting) — so what you see is what is on disk.
//! Enter keeps that and closes. Esc puts back the config, the input
//! style, the theme, and the exact bytes of every file that was written
//! since the overlay opened, including "the file did not exist".
//!
//! `persist` is also the one write every other settings surface (the
//! theme picker, the first-launch wizard) goes through.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Key = app_mod.Key;
const config = @import("../config/root.zig");
const suggest = @import("../ai/suggest.zig");
const ai_app = @import("ai.zig");
const setup = @import("setup.zig");
const Config = config.Config;
const command = @import("../core/command.zig");
const side = @import("side.zig");
const bottom = @import("bottom.zig");
const input = @import("../input/mod.zig");
const Theme = @import("../ui/theme.zig");
const ui_settings = @import("../ui/settings.zig");
const Item = ui_settings.Item;
const integrations = @import("integrations.zig");

pub const Scope = enum { home, workspace };

/// The `view.toggle_*` runners for the fields the settings rows also
/// name: flip in memory and say so, like `:set`. The overlay is where a
/// value is written to disk.
pub const table = .{
    .@"view.toggle_relative_numbers" = toggleRunner("ui.relative_line_numbers", "relative numbers"),
    .@"view.toggle_whitespace" = toggleRunner("ui.show_whitespace", "whitespace"),
    .@"view.toggle_bracket_rainbow" = toggleRunner("ui.bracket_rainbow", "rainbow brackets"),
    .@"view.toggle_highlight_trailing_ws" = toggleRunner("ui.highlight_trailing_ws", "trailing whitespace"),
    .@"view.toggle_highlight_word" = toggleRunner("ui.highlight_word_under_cursor", "word highlight"),
    .@"view.toggle_todo_highlight" = toggleRunner("ui.highlight_todo_keywords", "todo keywords"),
    .@"view.toggle_render_markdown" = toggleRunner("ui.render_markdown", "inline markdown"),
    .@"view.toggle_breadcrumb" = toggleRunner("editor.breadcrumb", "breadcrumb"),
    .@"view.toggle_click_echo" = toggleRunner("ui.click_echo", "click echo"),
    .@"view.toggle_hover_help" = toggleRunner("ui.hover_help", "hover help"),
    .@"view.toggle_hover_tooltip" = toggleRunner("ui.hover_tooltip", "hover tooltips"),
    .@"view.toggle_workspace_dots" = toggleRunner("ui.show_workspace_dots", "workspace dots"),
    .@"view.toggle_color_column" = &toggleColorColumn,
    .@"editor.toggle_indent_guides" = &toggleIndentGuides,
    // The setters Rust listed and never ran: set the key, write it to
    // the home config, say so.
    .@"view.tab_bar_ai_claude_only" = setRunner("ui.tab_bar_ai_icon", .claude_code, "AI chips: Claude, and Codex when its icon is enabled"),
    .@"view.tab_bar_ai_codex_only" = setRunner("ui.tab_bar_ai_icon", .codex, "AI chips: Codex, and Claude when its icon is enabled"),
    .@"view.tab_bar_ai_both" = setRunner("ui.tab_bar_ai_icon", .both, "AI chips: Claude + Codex when found"),
    .@"view.tab_bar_ai_none" = setRunner("ui.tab_bar_ai_icon", .none, "AI chips hidden"),
    .@"view.cluster_mode_expanded" = setRunner("ui.top_bar_cluster_mode", .expanded, "top-bar cluster: expanded"),
    .@"view.cluster_mode_compact" = setRunner("ui.top_bar_cluster_mode", .compact, "top-bar cluster: compact"),
    .@"view.cluster_mode_auto" = setRunner("ui.top_bar_cluster_mode", .auto, "top-bar cluster: auto"),
    .@"view.ai_layout_grid" = setRunner("ui.ai_layout_mode", .grid, "AI layout: grid"),
    .@"view.ai_layout_tabs" = setRunner("ui.ai_layout_mode", .tabs, "AI layout: tabs"),
    .@"view.toggle_picker_position" = &togglePickerPosition,
};

/// `view.toggle_picker_position`: `center` ⇄ `top`, written to the home
/// config like the setters above.
fn togglePickerPosition(app: *App) command.CommandError!void {
    const next: Config.PickerPosition = if (app.cfg.ui.picker_position == .top) .center else .top;
    app.cfg.ui.picker_position = next;
    _ = try persist(app, .home, &.{ "ui", "picker_position" }, next);
    app.toast("picker position: {s}", .{@tagName(next)});
    app.needs_render = true;
}

/// A runner that sets `path` to `value`, persists it to the home
/// config, and toasts `label`.
fn setRunner(comptime path: []const u8, comptime value: FieldType(path), comptime label: []const u8) command.CommandFn {
    return &struct {
        fn run(app: *App) command.CommandError!void {
            fieldPtr(&app.cfg, path).* = value;
            _ = try persist(app, .home, comptime keyPath(path), value);
            app.toast(label, .{});
            app.needs_render = true;
        }
    }.run;
}

fn toggleRunner(comptime path: []const u8, comptime label: []const u8) command.CommandFn {
    return &struct {
        fn run(app: *App) command.CommandError!void {
            const p = fieldPtr(&app.cfg, path);
            p.* = !p.*;
            app.toast(label ++ " {s}", .{if (p.*) "on" else "off"});
            app.needs_render = true;
        }
    }.run;
}

/// `editor.toggle_indent_guides`: shown (as `.on`, or `.active` when
/// that is what the config asked for) ⇄ `.off`, in memory like the
/// other toggles. Turning them back on from `.off` gives `.on`.
fn toggleIndentGuides(app: *App) command.CommandError!void {
    const g = &app.cfg.editor.indent_guides;
    g.* = if (g.* == .off) .on else .off;
    app.toast("indent guides {s}", .{if (g.* == .off) "off" else "on"});
    app.needs_render = true;
}

/// `view.toggle_color_column`: off ↔ the editor's `text_width`.
fn toggleColorColumn(app: *App) command.CommandError!void {
    app.cfg.ui.color_column = if (app.cfg.ui.color_column == 0) @max(app.cfg.editor.text_width, 1) else 0;
    if (app.cfg.ui.color_column == 0) app.toast("colour column off", .{}) else app.toast("colour column at {d}", .{app.cfg.ui.color_column});
    app.needs_render = true;
}

/// The file a scope writes to, or null when there is no home at all
/// (no `$HOME`, no data root — nothing to write into).
pub fn configPath(app: *App, scope: Scope) Allocator.Error!?[]const u8 {
    const arena = app.frame.allocator();
    return switch (scope) {
        .workspace => try std.fs.path.join(arena, &.{ app.workspace, ".mnml", config.data_root.config_file }),
        .home => blk: {
            if (app.loaded) |l| if (l.home_path) |p| break :blk p;
            if (app.data_root.len != 0) break :blk try std.fs.path.join(arena, &.{ app.data_root, config.data_root.config_file });
            break :blk null;
        },
    };
}

/// Write `value` at `key_path` in `scope`'s file. A failure is toasted,
/// never fatal — a read-only home must not stop the setting from
/// applying in memory. Returns whether the file changed.
pub fn persist(app: *App, scope: Scope, key_path: []const []const u8, value: anytype) Allocator.Error!bool {
    return persistLiteral(app, scope, key_path, try config.persist.serializeLiteral(app.frame.allocator(), value));
}

/// `persist` for a value already written as ZON source — a list laid
/// out one element per line, say.
pub fn persistLiteral(app: *App, scope: Scope, key_path: []const []const u8, literal: []const u8) Allocator.Error!bool {
    const path = (try configPath(app, scope)) orelse {
        app.toast("nowhere to save settings (no home directory)", .{});
        return false;
    };
    const outcome = config.persist.persistScalar(app.gpa, app.io, path, key_path, literal) catch |err| {
        app.toast("could not write {s}: {s}", .{ path, @errorName(err) });
        return false;
    };
    if (app.overlay == .settings) app.overlay.settings.markTouched(scope);
    return outcome == .written;
}

// ─── the rows ────────────────────────────────────────────────────────────

pub const Section = enum {
    ui,
    editor,
    ai,
    integrations,

    fn label(s: Section) []const u8 {
        return switch (s) {
            .ui => "UI",
            .editor => "Editor",
            .ai => "AI",
            .integrations => "Integrations",
        };
    }
};

const RowSpec = struct {
    /// Dotted `Config` path; also the persist key path.
    path: []const u8,
    label: []const u8,
    section: Section,
    scope: Scope,
    /// A number row: `←→` step the integer field within `min..max`.
    number: ?ui_settings.Row.Number = null,
};

/// v1: discrete-choice rows only. Order within a section is display
/// order; `ui.line_numbers` is the first row on purpose (the corpus
/// opens the overlay and adjusts "the first focusable").
pub const rows = [_]RowSpec{
    // ── UI (per-project view settings, written to the workspace) ──
    .{ .path = "ui.line_numbers", .label = "Line numbers", .section = .ui, .scope = .workspace },
    .{ .path = "ui.relative_line_numbers", .label = "Relative line numbers", .section = .ui, .scope = .workspace },
    .{ .path = "ui.cursor_line", .label = "Highlight cursor line", .section = .ui, .scope = .workspace },
    .{ .path = "ui.wrap", .label = "Soft wrap", .section = .ui, .scope = .workspace },
    .{ .path = "ui.scrollbar", .label = "Scrollbar", .section = .ui, .scope = .workspace },
    .{ .path = "ui.show_whitespace", .label = "Show whitespace", .section = .ui, .scope = .workspace },
    .{ .path = "ui.highlight_trailing_ws", .label = "Highlight trailing whitespace", .section = .ui, .scope = .workspace },
    .{ .path = "ui.bracket_rainbow", .label = "Rainbow brackets", .section = .ui, .scope = .workspace },
    .{ .path = "ui.syntax", .label = "Syntax highlighting", .section = .ui, .scope = .workspace },
    .{ .path = "ui.tree_preview_on_arrow", .label = "Tree previews on arrow", .section = .ui, .scope = .workspace },
    .{ .path = "ui.preview_tabs", .label = "Preview tabs", .section = .ui, .scope = .workspace },
    .{ .path = "ui.todos_sort", .label = "TODOS sort", .section = .ui, .scope = .workspace },
    .{ .path = "ui.theme", .label = "Theme", .section = .ui, .scope = .home },
    .{ .path = "ui.ascii_icons", .label = "ASCII icons", .section = .ui, .scope = .home },
    .{ .path = "ui.clock", .label = "Clock in statusline", .section = .ui, .scope = .home },
    .{ .path = "ui.menu_bar", .label = "Menu bar", .section = .ui, .scope = .home },
    .{ .path = "ui.activity_bar", .label = "Activity bar", .section = .ui, .scope = .home },
    .{ .path = "ui.sidebar", .label = "Side columns", .section = .ui, .scope = .home },
    // // changed (launcher-dock): the strip's five discrete rows. Its
    // dwells and its pins are config-only (v1 is choices).
    .{ .path = "ui.dock.mode", .label = "Launcher dock", .section = .ui, .scope = .home },
    .{ .path = "ui.dock.edge", .label = "Launcher dock edge", .section = .ui, .scope = .home },
    .{ .path = "ui.dock.placement", .label = "Launcher dock placement", .section = .ui, .scope = .home },
    .{ .path = "ui.dock.labels", .label = "Launcher dock labels", .section = .ui, .scope = .home },
    .{ .path = "ui.dock.align", .label = "Launcher dock alignment", .section = .ui, .scope = .home },
    .{ .path = "ui.dock.plus", .label = "Launcher dock + button", .section = .ui, .scope = .home },
    // // changed (dock-polish): which end the `+` takes, and the mark
    // a running item wears. The order stays config-only.
    .{ .path = "ui.dock.plus_at", .label = "Launcher dock + end", .section = .ui, .scope = .home },
    .{ .path = "ui.dock.running_mark", .label = "Launcher dock running mark", .section = .ui, .scope = .home },
    // // changed (edge-grip): one row for all three grips — it sits
    // under the surfaces it governs, after the last of them.
    .{ .path = "ui.edge_grips", .label = "Edge grips on slide-ins", .section = .ui, .scope = .home },
    .{ .path = "ui.debug_toolbar", .label = "Debug toolbar strip", .section = .ui, .scope = .home },
    .{ .path = "ui.bufferline_diag_style", .label = "Diag chip on tabs", .section = .ui, .scope = .home },
    .{ .path = "ui.expand_indicator", .label = "Expand indicator", .section = .ui, .scope = .home },
    .{ .path = "ui.tab_indicator", .label = "Integration tab indicator", .section = .ui, .scope = .home },
    .{ .path = "ui.picker_position", .label = "Picker position", .section = .ui, .scope = .home },
    .{ .path = "ui.show_workspace_dots", .label = "Workspace dots", .section = .ui, .scope = .home },
    .{ .path = "ui.hover_help", .label = "Hover help", .section = .ui, .scope = .home },
    .{ .path = "ui.hover_tooltip", .label = "Hover tooltips", .section = .ui, .scope = .home },
    .{ .path = "ui.click_echo", .label = "Click echo in statusline", .section = .ui, .scope = .home },
    // Opt-in: `off` is click-to-focus. The dwell is the number row
    // under it (`app/focus_follow.zig`).
    .{ .path = "ui.focus_follows_mouse", .label = "Focus follows mouse", .section = .ui, .scope = .home },
    .{ .path = "ui.focus_follows_mouse_delay_ms", .label = "Focus follows mouse delay (ms)", .section = .ui, .scope = .home, .number = .{ .min = 0, .max = config.Config.focus_follows_mouse_delay_ms_max, .step = 50 } },
    // // changed (quit-confirm): `on` (the default) makes Ctrl+Q always
    // stop and ask; `off` asks only when something is unsaved.
    .{ .path = "ui.confirm_quit", .label = "Confirm on quit", .section = .ui, .scope = .home },
    .{ .path = "ui.highlight_word_under_cursor", .label = "Highlight word under cursor", .section = .ui, .scope = .workspace },
    .{ .path = "ui.highlight_todo_keywords", .label = "Highlight TODO keywords", .section = .ui, .scope = .workspace },
    .{ .path = "ui.render_markdown", .label = "Inline-rendered markdown", .section = .ui, .scope = .workspace },
    .{ .path = "ui.sticky_context", .label = "Sticky scope context", .section = .ui, .scope = .workspace },
    .{ .path = "ui.markdown_opens_rendered", .label = "Markdown opens rendered", .section = .ui, .scope = .home },
    .{ .path = "ui.auto_md_preview", .label = "Auto markdown preview", .section = .ui, .scope = .home },
    .{ .path = "ui.stress_meter", .label = "Stress meter", .section = .ui, .scope = .home },
    .{ .path = "ui.top_bar_cluster_mode", .label = "Top bar cluster", .section = .ui, .scope = .home },
    .{ .path = "ui.tab_bar_ai_icon", .label = "AI icon in the bar", .section = .ui, .scope = .home },
    // Which of the maximize button's two modes a left click runs
    // (`app/zen.zig`); the button's own right-click menu ticks it.
    .{ .path = "ui.maximize_click", .label = "Maximize button", .section = .ui, .scope = .home },
    // *Icon* is the user's word for the thing the chips wear; the
    // config keys keep the older *mark* / *glyph* spelling so a config
    // already on disk keeps working.
    .{ .path = "ui.terminal_glyph", .label = "Terminal icon", .section = .ui, .scope = .home },
    // The Claude chip's icons, the twin of the row above
    // (`app/claude_mark.zig`) down to its third *custom* value; the
    // cluster chip's right-click `Icon ▸` menu is the other way in.
    .{ .path = "ui.claude_mark", .label = "Claude icon", .section = .ui, .scope = .home },
    .{ .path = "ui.ai_layout_mode", .label = "AI session layout", .section = .ui, .scope = .home },
    .{ .path = "ui.coverage_chip_mode", .label = "Coverage chip", .section = .ui, .scope = .home },
    .{ .path = "ui.jobs_chip", .label = "Background jobs chip", .section = .ui, .scope = .home },
    .{ .path = "ui.cursor_shape", .label = "Cursor shape", .section = .ui, .scope = .home },
    .{ .path = "ui.pty_cursor.unfocused", .label = "Terminal cursor, other panes", .section = .ui, .scope = .home },
    .{ .path = "ui.pty_cursor.blink", .label = "Terminal cursor blinks", .section = .ui, .scope = .home },
    .{ .path = "ui.pane_rail", .label = "Pane colour rail", .section = .ui, .scope = .home },
    .{ .path = "ui.welcome", .label = "Welcome screen", .section = .ui, .scope = .home },
    // How the focused pane and section are marked (`ui/focus_cue.zig`).
    .{ .path = "ui.focus_cue", .label = "Focus cue", .section = .ui, .scope = .home },
    // // changed (accent-defaults): the colour the first pane of each
    // kind opens in, under the rail they paint.
    .{ .path = "ui.accent_defaults.shell", .label = "First terminal colour", .section = .ui, .scope = .home },
    .{ .path = "ui.accent_defaults.claude", .label = "First Claude colour", .section = .ui, .scope = .home },
    .{ .path = "ui.accent_defaults.codex", .label = "First Codex colour", .section = .ui, .scope = .home },
    .{ .path = "ui.right_panel_visible", .label = "Right panel at start", .section = .ui, .scope = .workspace },
    .{ .path = "ui.right_panel_width", .label = "Right panel width", .section = .ui, .scope = .workspace, .number = .{ .min = 8, .max = 120, .step = 2 } },
    // // changed (bottom-dock): the dock's pair, beside the column's.
    .{ .path = "ui.bottom_panel_visible", .label = "Bottom dock at start", .section = .ui, .scope = .workspace },
    .{ .path = "ui.bottom_panel_height", .label = "Bottom dock rows", .section = .ui, .scope = .workspace, .number = .{ .min = config.Config.bottom_panel_height_min, .max = config.Config.bottom_panel_height_max, .step = 1 } },
    .{ .path = "ui.tree_width", .label = "Tree width", .section = .ui, .scope = .workspace, .number = .{ .min = config.Config.tree_width_min, .max = config.Config.tree_width_max, .step = 2 } },
    .{ .path = "ui.sidebar_side", .label = "Default sidebar side", .section = .ui, .scope = .home },
    // The width under which a docked column (`ui.sidebar`) reads as
    // `auto`; 0 is never. With the column's other geometry — its
    // width, its default side.
    .{ .path = "ui.sidebar_auto_below", .label = "Side columns auto-hide below", .section = .ui, .scope = .home, .number = .{ .min = 0, .max = 300, .step = 10 } },
    .{ .path = "ui.color_column", .label = "Colour column (0 = off)", .section = .ui, .scope = .workspace, .number = .{ .min = 0, .max = 240, .step = 4 } },
    .{ .path = "ui.wheel_lines", .label = "Lines per wheel notch", .section = .ui, .scope = .home, .number = .{ .min = 1, .max = 12, .step = 1 } },
    .{ .path = "ui.md_image_rows", .label = "Markdown image rows", .section = .ui, .scope = .home, .number = .{ .min = 3, .max = 40, .step = 1 } },
    .{ .path = "ui.hover_help_height", .label = "Hover help rows", .section = .ui, .scope = .home, .number = .{ .min = config.Config.hover_help_height_min, .max = config.Config.hover_help_height_max, .step = 1 } },
    // How long the box holds an entry while the pointer travels to it
    // (`app/info_view.zig`, the corridor).
    .{ .path = "ui.hover_help_grace_ms", .label = "Hover help grace (ms)", .section = .ui, .scope = .home, .number = .{ .min = 0, .max = config.Config.hover_help_grace_ms_max, .step = 100 } },
    // ── Editor ──
    .{ .path = "editor.input_style", .label = "Input style", .section = .editor, .scope = .home },
    .{ .path = "editor.auto_pair", .label = "Auto-pair brackets", .section = .editor, .scope = .workspace },
    .{ .path = "editor.auto_indent", .label = "Auto-indent", .section = .editor, .scope = .workspace },
    .{ .path = "editor.format_on_save", .label = "Format on save", .section = .editor, .scope = .workspace },
    .{ .path = "editor.trim_trailing_ws_on_save", .label = "Trim trailing whitespace on save", .section = .editor, .scope = .workspace },
    .{ .path = "editor.ensure_trailing_newline", .label = "Ensure trailing newline", .section = .editor, .scope = .workspace },
    .{ .path = "editor.breadcrumb", .label = "Breadcrumb", .section = .editor, .scope = .home },
    .{ .path = "editor.inline_values", .label = "Inline debugger values", .section = .editor, .scope = .workspace },
    .{ .path = "editor.indent_guides", .label = "Indent guides", .section = .editor, .scope = .home },
    .{ .path = "editor.line_blame", .label = "Current-line blame", .section = .editor, .scope = .home },
    // The gutter's fold chevron is an offer made under the pointer; on
    // `on` every foldable line wears one whether the pointer is there
    // or not, so the offer is findable without hunting for it
    // (`ui/editor_view.zig`). A `ui.` key in the Editor section on
    // purpose — it is the editor's own gutter, and that is where
    // someone looking for it looks.
    .{ .path = "ui.always_show_fold_arrows", .label = "Always show fold arrows", .section = .editor, .scope = .home },
    .{ .path = "editor.cursor_blink", .label = "Cursor blink", .section = .editor, .scope = .home },
    .{ .path = "editor.wheel_moves_cursor", .label = "Mouse wheel moves cursor", .section = .editor, .scope = .home },
    .{ .path = "editor.scroll_accel", .label = "Scroll acceleration", .section = .editor, .scope = .home },
    .{ .path = "editor.clipboard", .label = "System clipboard", .section = .editor, .scope = .home },
    .{ .path = "editor.lsp_missing_defaults", .label = "Missing default LSP servers", .section = .editor, .scope = .home },
    .{ .path = "editor.tab_width", .label = "Tab width", .section = .editor, .scope = .workspace, .number = .{ .min = 1, .max = 16, .step = 1 } },
    .{ .path = "editor.text_width", .label = "Text width", .section = .editor, .scope = .workspace, .number = .{ .min = 20, .max = 400, .step = 10 } },
    .{ .path = "editor.chord_timeout_ms", .label = "Chord timeout (ms)", .section = .editor, .scope = .home, .number = .{ .min = config.Config.chord_timeout_ms_min, .max = config.Config.chord_timeout_ms_max, .step = 100 } },
    // The tree-sitter size ceiling. A discrete row on a number field:
    // the overlay is v1 (choices only) and the sizes worth picking are a
    // short list — the raw byte count is the ZON view's to edit.
    .{ .path = "editor.highlight_max_bytes", .label = "Highlighting size limit", .section = .editor, .scope = .home },
    // The language-server size ceiling, the same shape of row and for
    // the same reason. Its sizes are bigger: a parse tree is held for
    // as long as the buffer is, where `didOpen` is paid once.
    .{ .path = "editor.lsp_max_bytes", .label = "Language server size limit", .section = .editor, .scope = .home },
    // ── AI (the model is `ai.model`, free text in the config: v1 rows are
    //    discrete choices) ──
    .{ .path = "ai.inline_suggestions", .label = "Ghost text", .section = .ai, .scope = .home },
    .{ .path = "ai.suggest_backend", .label = "Ghost-text backend", .section = .ai, .scope = .home },
    // Copilot's opt-in is the one AI row scoped to the WORKSPACE: it is
    // consent for this project's files and must not follow the user to
    // the next one. (Everything else Copilot needs — the argv, the
    // exclude globs — is home-scoped and exec-bearing, so it is not a
    // settings row at all.)
    .{ .path = "ai.copilot_here", .label = "Copilot: share this workspace", .section = .ai, .scope = .workspace },
    .{ .path = "ai.suggest_idle_ms", .label = "Ghost-text idle (ms)", .section = .ai, .scope = .home, .number = .{ .min = config.Config.suggest_idle_ms_min, .max = config.Config.suggest_idle_ms_max, .step = 50 } },
    .{ .path = "ai.suggest_timeout_ms", .label = "Ghost-text budget (ms)", .section = .ai, .scope = .home, .number = .{ .min = config.Config.suggest_timeout_ms_min, .max = config.Config.suggest_timeout_ms_max, .step = 500 } },
    .{ .path = "ai.routing.claude.backend", .label = "Claude backend", .section = .ai, .scope = .home },
    .{ .path = "ai.routing.codex.backend", .label = "Codex backend", .section = .ai, .scope = .home },
    .{ .path = "ai.claude_meter_mode", .label = "Claude meter", .section = .ai, .scope = .home },
    // A session that needs you, or ends: the desktop notification and
    // the bell that rides with it (`sessions.notifySession`). `ui.`
    // keys in the AI section: they are about sessions, which is where
    // someone looking for them looks.
    .{ .path = "ui.session_notify", .label = "Session notifications", .section = .ai, .scope = .home },
    .{ .path = "ui.session_bell", .label = "Session bell", .section = .ai, .scope = .home },
    // ── Integrations ──
    .{ .path = "sonos.enabled", .label = "Sonos", .section = .integrations, .scope = .home },
    .{ .path = "sonos.chip_label", .label = "Sonos chip label", .section = .integrations, .scope = .home },
    .{ .path = "browser.headless", .label = "Browser: headless", .section = .integrations, .scope = .home },
    .{ .path = "browser.profile_mode", .label = "Browser profile", .section = .integrations, .scope = .home },
    .{ .path = "http.collection_root", .label = "HTTP collection root", .section = .integrations, .scope = .home },
    .{ .path = "marketplace.enabled", .label = "Marketplace", .section = .integrations, .scope = .home },
    .{ .path = "session.restore", .label = "Restore session on open", .section = .integrations, .scope = .home },
    // What a restored terminal pane comes back as — running (a shell
    // restarts, an AI session resumes) or dormant (every one waits for
    // a key). Beside the row that turns the restore on, which is where
    // someone looking for it looks (`app/session.zig`).
    .{ .path = "session.restore_terminals", .label = "Restore terminals", .section = .integrations, .scope = .home },
    .{ .path = "integrations.arrange", .label = "New pane sizing", .section = .integrations, .scope = .home },
};

pub const reset_label = "Reset all to defaults";
/// The action row's hit id, past every row.
pub const reset_id: u32 = rows.len;
/// Rows from installed manifests' `settings[]` start here, in
/// `integrations.settingRefs` order.
pub const integ_base: u32 = reset_id + 1;

const bool_options = [_][]const u8{ "off", "on" };

/// `"ui.line_numbers"` → `&.{ "ui", "line_numbers" }`, at comptime.
fn keyPath(comptime path: []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var parts: []const []const u8 = &.{};
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |p| parts = parts ++ &[_][]const u8{p};
        return parts;
    }
}

/// The field type behind a dotted path.
fn FieldType(comptime path: []const u8) type {
    comptime {
        @setEvalBranchQuota(20_000);
        var T: type = Config;
        for (keyPath(path)) |p| T = @FieldType(T, p);
        return T;
    }
}

/// A pointer to the field behind a dotted path.
fn fieldPtr(cfg: *Config, comptime path: []const u8) *FieldType(path) {
    @setEvalBranchQuota(20_000);
    comptime var T: type = Config;
    var ptr: *anyopaque = @ptrCast(cfg);
    inline for (comptime keyPath(path)) |p| {
        const typed: *T = @ptrCast(@alignCast(ptr));
        ptr = @ptrCast(&@field(typed, p));
        T = @FieldType(T, p);
    }
    return @ptrCast(@alignCast(ptr));
}

/// The bundled theme names, in table order — `ui.theme`'s options.
pub const theme_names: [Theme.all.len][]const u8 = blk: {
    var out: [Theme.all.len][]const u8 = undefined;
    for (&Theme.all, 0..) |*th, i| out[i] = th.name;
    break :blk out;
};

fn isTheme(comptime path: []const u8) bool {
    return std.mem.eql(u8, path, "ui.theme");
}

/// `editor.highlight_max_bytes` is an integer the overlay offers as a
/// short list of sizes rather than a step row: stepping a byte count
/// through four orders of magnitude is not a control. 0 is "off" — no
/// limit at all; the shipped default is 4 MB.
fn isHighlightMax(comptime path: []const u8) bool {
    return std.mem.eql(u8, path, "editor.highlight_max_bytes");
}

/// `editor.lsp_max_bytes`, the same kind of row over a longer scale.
fn isLspMax(comptime path: []const u8) bool {
    return std.mem.eql(u8, path, "editor.lsp_max_bytes");
}

pub const highlight_max_labels = [_][]const u8{ "off", "1 MB", "4 MB", "16 MB", "64 MB" };
pub const highlight_max_values = [_]u64{ 0, 1 << 20, 4 << 20, 16 << 20, 64 << 20 };

pub const lsp_max_labels = [_][]const u8{ "off", "4 MB", "16 MB", "50 MB", "200 MB" };
pub const lsp_max_values = [_]u64{ 0, 4 << 20, 16 << 20, 50 << 20, 200 << 20 };

/// Which choice a byte count reads as. A value set by hand that is not
/// one of the five shows as the smallest choice above it (and adjusting
/// the row then writes that one) — the overlay never claims a file over
/// the limit is unlimited.
fn highlightMaxIndex(v: u64) usize {
    return sizeIndex(&highlight_max_values, v);
}

fn sizeIndex(values: []const u64, v: u64) usize {
    if (v == 0) return 0;
    for (values, 0..) |hv, i| if (i > 0 and v <= hv) return i;
    return values.len - 1;
}

/// // changed (dock-placement): `ui.dock.placement` is a two-value
/// enum whose tag names (`inner` / `outer`) say nothing to a person
/// reading a settings row. The row offers the words instead; the key
/// keeps the tags, because the list is in tag order and `setIndex`
/// writes `@enumFromInt(i)` as it does for every other enum row.
fn isDockPlacement(comptime path: []const u8) bool {
    return std.mem.eql(u8, path, "ui.dock.placement");
}

pub const dock_placement_labels = [_][]const u8{ "above statusline", "below command line" };

/// `ai.suggest_backend` is not a typed field: the config keeps it in
/// `ai.extra` (a string, aliases allowed) and the setup picker sets a
/// runtime override. The row reads through `ai.suggestBackend` and
/// writes the override plus the file.
fn isSuggestBackend(comptime path: []const u8) bool {
    return std.mem.eql(u8, path, "ai.suggest_backend");
}

/// The ghost-text backend tokens, in `suggest.Backend` order. The
/// length follows the enum: a new backend must not need this line.
pub const suggest_tokens: [std.enums.values(suggest.Backend).len][]const u8 = blk: {
    var out: [std.enums.values(suggest.Backend).len][]const u8 = undefined;
    for (std.enums.values(suggest.Backend), 0..) |b, i| out[i] = b.token();
    break :blk out;
};

/// An optional enum's choices: `unset` first, then the enum's tags.
fn optionalOptions(comptime E: type) []const []const u8 {
    return &[_][]const u8{"unset"} ++ std.meta.fieldNames(E);
}

/// The choices for a row.
pub fn options(comptime path: []const u8) []const []const u8 {
    @setEvalBranchQuota(200_000);
    if (comptime isTheme(path)) return &theme_names;
    if (comptime isSuggestBackend(path)) return &suggest_tokens;
    if (comptime isHighlightMax(path)) return &highlight_max_labels;
    if (comptime isLspMax(path)) return &lsp_max_labels;
    if (comptime isDockPlacement(path)) return &dock_placement_labels;
    const T = FieldType(path);
    return switch (@typeInfo(T)) {
        .bool => &bool_options,
        .@"enum" => comptime std.meta.fieldNames(T),
        .optional => |o| if (@typeInfo(o.child) == .@"enum") comptime optionalOptions(o.child) else @compileError("settings: no discrete options for " ++ path),
        // A number row has no list; `currentIndex` is the value itself.
        .int => &.{},
        else => @compileError("settings: no discrete options for " ++ path ++ " (" ++ @typeName(T) ++ ")"),
    };
}

/// True for the integer fields — the rows that step instead of cycle.
pub fn isNumber(comptime path: []const u8) bool {
    if (comptime isSuggestBackend(path)) return false;
    if (comptime isHighlightMax(path) or isLspMax(path)) return false;
    return @typeInfo(FieldType(path)) == .int;
}

/// Which option a config holds for a row. The ghost-text row reads the
/// file's token only; `rowIndex` adds the runtime override.
pub fn currentIndex(cfg: *Config, comptime path: []const u8) usize {
    @setEvalBranchQuota(200_000);
    if (comptime isTheme(path)) {
        const name = cfg.ui.theme;
        for (theme_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return i;
        return 0;
    }
    if (comptime isHighlightMax(path)) return highlightMaxIndex(cfg.editor.highlight_max_bytes);
    if (comptime isLspMax(path)) return sizeIndex(&lsp_max_values, cfg.editor.lsp_max_bytes);
    if (comptime isSuggestBackend(path)) {
        const v = cfg.ai.extra.get("suggest_backend") orelse return 0;
        return switch (v) {
            .string, .enum_literal => |s| @intFromEnum(suggest.Backend.parse(s)),
            else => 0,
        };
    }
    const v = fieldPtr(cfg, path).*;
    return switch (@typeInfo(FieldType(path))) {
        .bool => @intFromBool(v),
        .@"enum" => @intFromEnum(v),
        .optional => if (v) |e| @as(usize, @intFromEnum(e)) + 1 else 0,
        .int => @intCast(v),
        else => unreachable,
    };
}

/// `currentIndex` over the live app: the ghost-text row shows the
/// backend in force (the setup picker's override wins over the file).
fn rowIndex(app: *App, comptime path: []const u8) usize {
    if (comptime isSuggestBackend(path)) return @intFromEnum(ai_app.suggestBackend(app));
    return currentIndex(&app.cfg, path);
}

/// Set a row to its `idx`th option (wrapping); a number row to `idx`
/// itself, clamped to the field's type.
pub fn setIndex(cfg: *Config, comptime path: []const u8, idx: usize) void {
    @setEvalBranchQuota(200_000);
    const T = FieldType(path);
    if (comptime isHighlightMax(path)) {
        cfg.editor.highlight_max_bytes = highlight_max_values[idx % highlight_max_values.len];
        return;
    }
    if (comptime isLspMax(path)) {
        cfg.editor.lsp_max_bytes = lsp_max_values[idx % lsp_max_values.len];
        return;
    }
    if (comptime isNumber(path)) {
        fieldPtr(cfg, path).* = @intCast(@min(idx, std.math.maxInt(T)));
        return;
    }
    const opts = options(path);
    const i = idx % opts.len;
    if (comptime isTheme(path)) {
        cfg.ui.theme = theme_names[i];
        return;
    }
    // The ghost-text token lives in `ai.extra`; `setRow` writes the
    // override and the file instead.
    if (comptime isSuggestBackend(path)) return;
    fieldPtr(cfg, path).* = switch (@typeInfo(T)) {
        .bool => i == 1,
        .@"enum" => @enumFromInt(i),
        .optional => if (i == 0) null else @enumFromInt(i - 1),
        else => unreachable,
    };
}

fn defaultIndex(comptime path: []const u8) usize {
    var d: Config = .{};
    return currentIndex(&d, path);
}

// ─── the overlay's state ─────────────────────────────────────────────────

/// One file the overlay may write: its bytes when the overlay opened
/// (null = did not exist), and whether a write has happened since.
const FileSnapshot = struct {
    path: ?[]u8 = null,
    text: ?[]u8 = null,
    touched: bool = false,

    fn deinit(f: *FileSnapshot, gpa: Allocator) void {
        if (f.path) |p| gpa.free(p);
        if (f.text) |text| gpa.free(text);
        f.* = .{};
    }
};

pub const State = struct {
    ui: ui_settings.State = .{},
    /// The config as it was when the overlay opened; Esc restores it.
    before: Config,
    /// The ghost-text override when the overlay opened (the row writes it).
    before_suggest: ?suggest.Backend = null,
    files: std.EnumArray(Scope, FileSnapshot) = .initFill(.{}),
    /// Per row: a layer loaded AFTER the row's own file that sets the
    /// same key — the workspace's `.mnml/config.zon` over a home row,
    /// `--config` over either. What that file says is what the next
    /// launch runs on, so the row says so (`footer`) and a change to it
    /// is toasted (`setRow`). Gpa-owned paths, found once at `open`.
    overrides: [rows.len]?[]u8 = @splat(null),

    pub fn deinit(s: *State, gpa: Allocator) void {
        for (&s.files.values) |*f| f.deinit(gpa);
        for (s.overrides) |o| if (o) |p| gpa.free(p);
        s.ui.deinit(gpa);
    }

    pub fn markTouched(s: *State, scope: Scope) void {
        s.files.getPtr(scope).touched = true;
    }
};

/// `view.settings`: snapshot, then open.
pub fn open(app: *App) Allocator.Error!void {
    const gpa = app.gpa;
    var st: State = .{ .before = app.cfg, .before_suggest = app.ai.backend_override };
    errdefer st.deinit(gpa);
    inline for (comptime std.enums.values(Scope)) |scope| {
        const snap = st.files.getPtr(scope);
        if (try configPath(app, scope)) |p| {
            snap.path = try gpa.dupe(u8, p);
            snap.text = Io.Dir.cwd().readFileAlloc(app.io, p, gpa, .limited(config.load.max_file_bytes)) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        }
    }
    try findOverrides(app, &st);
    app.overlay.deinit(gpa);
    app.overlay = .{ .settings = st };
    app.focus = .overlay;
    app.needs_render = true;
}

/// One layer file as a patch, or null when it is absent or unreadable
/// (the loader has already said so).
fn readPatch(app: *App, arena: Allocator, path: []const u8) Allocator.Error!?config.load.Patch(Config) {
    const src = Io.Dir.cwd().readFileAllocOptions(app.io, path, arena, .limited(config.load.max_file_bytes), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var diags = config.diag.Diagnostics.init(arena);
    return try config.load.parseLayer(arena, src, path, &diags);
}

/// Whether the layer `p` sets the field at `parts`.
fn patchSets(comptime T: type, p: config.load.Patch(T), comptime parts: []const []const u8) bool {
    const F = @FieldType(T, parts[0]);
    const v = @field(p, parts[0]);
    if (comptime parts.len == 1) return v != null;
    const sub = v orelse return false;
    return patchSets(F, sub, parts[1..]);
}

/// Fill `st.overrides`: for each row, the first layer above its own file
/// that sets its key — `--config` (loaded last, so it wins over both),
/// else the workspace file for a home row.
fn findOverrides(app: *App, st: *State) Allocator.Error!void {
    @setEvalBranchQuota(400_000);
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const explicit: ?[]const u8 = if (app.loaded) |l| l.explicit_path else null;
    const ws_path = (try configPath(app, .workspace)).?;
    const ex_patch = if (explicit) |p| try readPatch(app, arena, p) else null;
    const ws_patch = try readPatch(app, arena, ws_path);
    inline for (rows, 0..) |r, i| {
        // The ghost-text backend row names no `Config` field: its value
        // is a token in `ai.extra`.
        if (comptime isSuggestBackend(r.path)) continue;
        const parts = comptime keyPath(r.path);
        const above: ?[]const u8 = blk: {
            if (ex_patch) |p| if (patchSets(Config, p, parts)) break :blk explicit.?;
            if (r.scope == .home) if (ws_patch) |p| if (patchSets(Config, p, parts)) break :blk ws_path;
            break :blk null;
        };
        if (above) |a| st.overrides[i] = try app.gpa.dupe(u8, a);
    }
}

/// A layer path the way the user reads it: relative inside the
/// workspace, `~` for home, else as it is.
fn shownPath(app: *App, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, path, app.workspace)) return app.relPath(path);
    return setup.tilde(app, arena, path);
}

/// `view.settings_search`: the box, with the filter pill up and
/// holding the keys. `/` inside the box does the same, but the box has
/// to be open before a user can learn that — from the palette this is
/// one step.
///
/// Opening it fresh every time is deliberate: a box already open is
/// re-snapshotted, so Esc still puts back exactly the config the
/// search started from.
pub fn openSearch(app: *App) Allocator.Error!void {
    try open(app);
    app.overlay.settings.ui.openFilter();
}

/// The list as it stands, on the frame arena.
pub fn items(app: *App, arena: Allocator) Allocator.Error![]Item {
    @setEvalBranchQuota(200_000);
    var out: std.ArrayListUnmanaged(Item) = .empty;
    inline for (comptime std.enums.values(Section)) |section| {
        try out.append(arena, .{ .section = section.label() });
        inline for (rows, 0..) |r, i| if (r.section == section) {
            try out.append(arena, .{ .row = .{
                .label = r.label,
                .options = options(r.path),
                .current = rowIndex(app, r.path),
                .modified = rowIndex(app, r.path) != comptime defaultIndex(r.path),
                .id = i,
                .number = r.number,
            } });
        };
        if (section == .integrations) {
            // What the installed manifests declare, after the built-ins.
            const refs = try integrations.settingRefs(app, arena);
            for (refs, 0..) |ref, k| {
                const inst = &app.integrations.list[ref.installed];
                const s = inst.manifest.settings[ref.setting];
                try out.append(arena, .{ .row = .{
                    .label = try std.fmt.allocPrint(arena, "{s}: {s}", .{ inst.manifest.label, s.label }),
                    .options = s.options,
                    .current = integrations.settingIndex(app, ref),
                    .modified = integrations.settingIndex(app, ref) != integrations.settingDefaultIndex(app, ref),
                    .id = integ_base + @as(u32, @intCast(k)),
                } });
            }
        }
    }
    try out.append(arena, .{ .section = "Reset" });
    try out.append(arena, .{ .action = .{ .label = reset_label, .id = reset_id } });
    return out.items;
}

/// // changed (settings-search): the two lists a frame needs — the
/// whole thing (the strip, the footer's total and the box's geometry
/// come off it) and what the filter query leaves of it (the rows, the
/// cursor and every key that moves it). No query means the same list
/// twice over, at the cost of one arena copy.
pub const Lists = struct { all: []Item, visible: []Item };

pub fn lists(app: *App, arena: Allocator) Allocator.Error!Lists {
    const all = try items(app, arena);
    const q = app.overlay.settings.ui.filter.text();
    return .{ .all = all, .visible = if (q.len == 0) all else try ui_settings.filtered(arena, all, q) };
}

/// What the keys act on: the rows the query left.
fn visibleItems(app: *App, arena: Allocator) Allocator.Error![]Item {
    return (try lists(app, arena)).visible;
}

/// The subtitle: where the focused row is written.
pub fn footer(app: *App, arena: Allocator, list: []const Item) Allocator.Error!?[]const u8 {
    const st = &app.overlay.settings;
    st.ui.settle(list);
    if (st.ui.cursor >= list.len) return null;
    const row = switch (list[st.ui.cursor]) {
        .row => |r| r,
        else => return null,
    };
    // // changed (settings-title-path): a home-scope row used to put the
    // RAW absolute path here, which the box then chopped from the right
    // — so the file name, the one thing this line exists to say, was
    // what got thrown away. `~` for `$HOME` fixes the common case; the
    // box's `elideLeft` fixes the rest.
    if (row.id >= integ_base) {
        const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ app.data_root, integrations.settings_file });
        return try std.fmt.allocPrint(arena, "→ {s}", .{try setup.tilde(app, arena, p)});
    }
    const scope = rows[row.id].scope;
    const path = (try configPath(app, scope)) orelse return "no config file to write";
    const shown = if (scope == .workspace) app.relPath(path) else try setup.tilde(app, arena, path);
    // A layer above the row's file sets the same key: say which, or the
    // row reads as saved and the next launch quietly puts it back.
    if (st.overrides[row.id]) |over| return try std.fmt.allocPrint(arena, "→ {s} · overridden by {s}", .{ shown, try shownPath(app, arena, over) });
    return try std.fmt.allocPrint(arena, "→ {s}", .{shown});
}

pub fn key(app: *App, k: Key) Allocator.Error!void {
    const arena = app.frame.allocator();
    const list = try visibleItems(app, arena);
    const st = &app.overlay.settings;
    // `/` is the filter everywhere; the standard profile takes Ctrl+F
    // for it too, the way VS Code's settings screen does.
    const opts: ui_settings.KeyOpts = .{ .gpa = app.gpa, .ctrl_f = app.input_style != .vim, .typeahead = app.input_style != .vim };
    switch (try ui_settings.handleKey(&st.ui, k, list, opts)) {
        .consumed => {},
        .refilter => try refocus(app, list),
        .cancel => try cancel(app),
        .save => close(app),
        .adjust => |a| try adjust(app, list[a.item].row.id, a.delta),
        .reset_row => |i| try resetRow(app, list[i].row.id),
        .reset_all => try resetAll(app),
        // // changed (settings-reset-confirm): the Reset row asks first,
        // the same box `R` raises in the vim profile.
        .activate => |i| if (list[i].action.id == reset_id) st.ui.askResetAll(),
    }
    app.needs_render = true;
}

/// // changed (settings-search): the query moved, so the list under the
/// cursor did. The row that had focus keeps it when it still matches;
/// otherwise the cursor is clamped to the first match, with the window
/// back at the top — a cursor left pointing at a row that is no longer
/// there would adjust the wrong setting.
fn refocus(app: *App, before: []const Item) Allocator.Error!void {
    const st = &app.overlay.settings;
    const was: ?u32 = if (st.ui.cursor < before.len and before[st.ui.cursor] == .row) before[st.ui.cursor].row.id else null;
    const list = try visibleItems(app, app.frame.allocator());
    if (was) |id| if (itemIndexOf(list, id)) |i| {
        st.ui.cursor = i;
        st.ui.settle(list);
        return;
    };
    st.ui.cursor = 0;
    st.ui.scroll = 0;
    st.ui.settle(list);
}

/// A paste while the filter pill has the keys.
pub fn paste(app: *App, text: []const u8) Allocator.Error!void {
    const st = &app.overlay.settings;
    const list = try visibleItems(app, app.frame.allocator());
    try ui_settings.Filter.insert(&st.ui.filter, app.gpa, text);
    try refocus(app, list);
    app.needs_render = true;
}

/// The wheel over the box: `lines` down (negative up), the cursor
/// riding inside the window.
pub fn wheel(app: *App, lines: isize) Allocator.Error!void {
    const list = try visibleItems(app, app.frame.allocator());
    app.overlay.settings.ui.wheel(list, lines);
    app.needs_render = true;
}

/// A press or drag `off` rows down the box's scrollbar track: the
/// window lands at the pointer's fraction of the list, the cursor
/// riding inside it.
pub fn barJump(app: *App, off: usize, track_h: usize) Allocator.Error!void {
    const list = try visibleItems(app, app.frame.allocator());
    app.overlay.settings.ui.barJump(list, off, track_h);
    app.needs_render = true;
}

/// A click on `hit` (an `.overlay_item` id): focus the row, or jump the
/// row to the option under the pointer.
pub fn click(app: *App, hit: u32) Allocator.Error!void {
    const arena = app.frame.allocator();
    const st = &app.overlay.settings;
    // // changed (settings-reset-confirm): the ask paints last, so its
    // two choices are the hits a click lands on and `hit` is the index.
    if (st.ui.confirm != null) {
        st.ui.confirm = null;
        app.needs_render = true;
        if (hit == 0) try resetAll(app);
        return;
    }
    const both = try lists(app, arena);
    const list = both.visible;
    switch (ui_settings.decodeHit(hit)) {
        .surface => {},
        // The pill: the keys go back to it, query and all.
        .filter => st.ui.openFilter(),
        // A name in the box's section strip: the same jump `]` / `[`
        // make. The strip is painted from the whole list, so the name
        // is looked up in what is actually on screen; a section the
        // query emptied has nowhere to jump to.
        .section => |n| {
            const name = ui_settings.sectionName(both.all, n) orelse return;
            const k = ui_settings.sectionIndexOfName(list, name) orelse return;
            st.ui.jumpTo(list, k);
        },
        .row => |id| {
            if (id == reset_id) return st.ui.askResetAll();
            st.ui.cursor = itemIndexOf(list, id) orelse return;
            st.ui.filter.focused = false;
        },
        .option => |o| {
            st.ui.cursor = itemIndexOf(list, o.id) orelse return;
            st.ui.filter.focused = false;
            // A number row's arrows: index 0 steps down, 1 up.
            if (o.id < rows.len and rows[o.id].number != null) return adjust(app, o.id, if (o.index == 0) -1 else 1);
            try setRow(app, o.id, o.index);
        },
    }
    app.needs_render = true;
}

fn itemIndexOf(list: []const Item, id: u32) ?usize {
    for (list, 0..) |it, i| if (it == .row and it.row.id == id) return i;
    return null;
}

/// Move row `id` by `delta` choices, wrapping.
pub fn adjust(app: *App, id: u32, delta: i8) Allocator.Error!void {
    @setEvalBranchQuota(200_000);
    if (id >= integ_base) {
        const refs = try integrations.settingRefs(app, app.frame.allocator());
        const k = id - integ_base;
        if (k >= refs.len) return;
        const n = app.integrations.list[refs[k].installed].manifest.settings[refs[k].setting].options.len;
        if (n == 0) return;
        const cur = integrations.settingIndex(app, refs[k]);
        const next = if (delta < 0) (cur + n - 1) % n else (cur + 1) % n;
        return setRow(app, id, next);
    }
    inline for (rows, 0..) |r, i| if (i == id) {
        const cur = rowIndex(app, r.path);
        if (r.number) |num| {
            const next = if (delta < 0) @max(cur -| num.step, num.min) else @min(cur + num.step, num.max);
            return setRow(app, id, next);
        }
        const n = options(r.path).len;
        const next = if (delta < 0) (cur + n - 1) % n else (cur + 1) % n;
        return setRow(app, id, next);
    };
}

/// Set row `id` to its `idx`th option: the live config, the derived
/// state, and the row's file.
pub fn setRow(app: *App, id: u32, idx: usize) Allocator.Error!void {
    @setEvalBranchQuota(200_000);
    if (id >= integ_base) {
        const refs = try integrations.settingRefs(app, app.frame.allocator());
        const k = id - integ_base;
        if (k >= refs.len) return;
        try integrations.setSetting(app, refs[k], idx);
        app.needs_render = true;
        return;
    }
    inline for (rows, 0..) |r, i| if (i == id) {
        if (comptime isSuggestBackend(r.path)) {
            const b: suggest.Backend = @enumFromInt(idx % suggest_tokens.len);
            app.ai.backend_override = b;
            app.ai.local_note_shown = false;
            app.ai.key_missing_toasted = false;
            _ = try persist(app, r.scope, comptime keyPath(r.path), b.token());
            app.needs_render = true;
            return;
        }
        setIndex(&app.cfg, r.path, idx);
        try applyDerived(app, r.path);
        _ = try persist(app, r.scope, comptime keyPath(r.path), fieldPtr(&app.cfg, r.path).*);
        if (app.overlay == .settings) if (app.overlay.settings.overrides[i]) |over| {
            const arena = app.frame.allocator();
            try app.toastLevel(.warn, "{s}: saved, but {s} sets it too — that value wins at the next launch", .{ r.path, try shownPath(app, arena, over) });
        };
        app.needs_render = true;
        return;
    };
}

fn resetRow(app: *App, id: u32) Allocator.Error!void {
    @setEvalBranchQuota(200_000);
    if (id >= integ_base) {
        const refs = try integrations.settingRefs(app, app.frame.allocator());
        const k = id - integ_base;
        if (k >= refs.len) return;
        return setRow(app, id, integrations.settingDefaultIndex(app, refs[k]));
    }
    inline for (rows, 0..) |r, i| if (i == id) return setRow(app, id, comptime defaultIndex(r.path));
}

fn resetAll(app: *App) Allocator.Error!void {
    @setEvalBranchQuota(200_000);
    inline for (rows, 0..) |r, i| {
        if (rowIndex(app, r.path) != comptime defaultIndex(r.path)) try setRow(app, i, comptime defaultIndex(r.path));
    }
    app.toast("settings reset to defaults", .{});
}

/// What a field change means beyond the value: the keymap and the
/// buffers follow the input style, the frame follows the theme.
fn applyDerived(app: *App, comptime path: []const u8) Allocator.Error!void {
    if (comptime std.mem.eql(u8, path, "editor.input_style")) {
        const style = App.styleOf(app.cfg.editor.input_style);
        if (style != app.input_style) try app.setInputStyle(style);
    } else if (comptime std.mem.eql(u8, path, "editor.clipboard")) {
        app.clipboard.selectMode(app.cfg.editor.clipboard);
    } else if (comptime std.mem.eql(u8, path, "editor.auto_indent") or std.mem.eql(u8, path, "editor.trim_trailing_ws_on_save") or std.mem.eql(u8, path, "editor.ensure_trailing_newline")) {
        try app.syncBufferPrefs();
    } else if (comptime isTheme(path)) {
        try app.applyTheme();
    } else if (comptime std.mem.eql(u8, path, "ui.clock")) {
        @import("clock.zig").seed(app);
    } else if (comptime std.mem.eql(u8, path, "ui.tree_width")) {
        app.tree.width = app.cfg.ui.tree_width;
    } else if (comptime std.mem.eql(u8, path, "ui.right_panel_width")) {
        app.side.right_width = @max(app.cfg.ui.right_panel_width, 8);
    } else if (comptime std.mem.eql(u8, path, "ui.right_panel_visible")) {
        const is_open = side.shown(app, .right) != null;
        if (app.cfg.ui.right_panel_visible != is_open) side.toggleColumn(app, .right) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        // The overlay keeps the keys while it is up.
        if (app.overlay != .none) app.focus = .overlay;
    } else if (comptime std.mem.eql(u8, path, "ui.bottom_panel_height")) {
        app.side.bottom_height = app.cfg.ui.bottom_panel_height;
    } else if (comptime std.mem.eql(u8, path, "ui.bottom_panel_visible")) {
        const dock_open = bottom.open(app);
        if (app.cfg.ui.bottom_panel_visible != dock_open) command.run(app, .{ .static = .@"view.toggle_bottom_panel" }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        if (app.overlay != .none) app.focus = .overlay;
    } else if (comptime std.mem.eql(u8, path, "ui.sidebar_side")) {
        side.reseed(app);
        if (app.overlay != .none) app.focus = .overlay;
    } else if (comptime std.mem.eql(u8, path, "editor.tab_width")) {
        for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*e| e.buf.setInputStyle(app.input_style, app.editorConfig()),
            else => {},
        };
    }
}

/// Enter / click outside: what is written stays.
pub fn close(app: *App) void {
    app.overlay.deinit(app.gpa);
    app.focus = if (app.active) |a| .{ .pane = a } else .tree;
    app.needs_render = true;
}

/// Esc: the config, the derived state, and every touched file go back
/// to how they were when the overlay opened.
pub fn cancel(app: *App) Allocator.Error!void {
    const st = &app.overlay.settings;
    app.cfg = st.before;
    app.ai.backend_override = st.before_suggest;
    for (&st.files.values) |*f| {
        if (!f.touched) continue;
        const path = f.path orelse continue;
        if (f.text) |text| {
            Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = text }) catch |err| app.toast("could not restore {s}: {s}", .{ path, @errorName(err) });
        } else {
            Io.Dir.cwd().deleteFile(app.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => app.toast("could not remove {s}: {s}", .{ path, @errorName(err) }),
            };
        }
    }
    const style = App.styleOf(app.cfg.editor.input_style);
    if (style != app.input_style) try app.setInputStyle(style);
    try app.applyTheme();
    close(app);
}

// ─── tests ───────────────────────────────────────────────────────────────

const t = std.testing;
const Fixture = @import("../ui/test_fixture.zig");

fn readOrNull(dir: std.testing.TmpDir, rel: []const u8) !?[]u8 {
    return dir.dir.readFileAlloc(t.io, rel, t.allocator, .unlimited) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

test "rows: every path is a bool, an enum, a number or the theme; defaults index the shipped values" {
    inline for (rows) |r| {
        var d: Config = .{};
        if (r.number) |num| {
            try t.expect(comptime isNumber(r.path));
            try t.expect(currentIndex(&d, r.path) >= num.min and currentIndex(&d, r.path) <= num.max);
        } else {
            try t.expect(options(r.path).len >= 2);
            try t.expect(currentIndex(&d, r.path) < options(r.path).len);
        }
    }
    var num_cfg: Config = .{};
    try t.expectEqual(@as(usize, 32), currentIndex(&num_cfg, "ui.right_panel_width"));
    setIndex(&num_cfg, "ui.right_panel_width", 44);
    try t.expectEqual(@as(u16, 44), num_cfg.ui.right_panel_width);
    var c: Config = .{};
    try t.expectEqual(@as(usize, 1), currentIndex(&c, "ui.line_numbers"));
    try t.expectEqual(@as(usize, 1), currentIndex(&c, "editor.input_style")); // standard
    setIndex(&c, "editor.input_style", 0);
    try t.expectEqual(Config.InputStyle.vim, c.editor.input_style);
    setIndex(&c, "ui.line_numbers", 0);
    try t.expect(!c.ui.line_numbers);
    setIndex(&c, "ui.theme", 3);
    try t.expectEqualStrings(theme_names[3], c.ui.theme);
    try t.expectEqual(@as(usize, 3), currentIndex(&c, "ui.theme"));
    try t.expectEqualStrings("line_numbers", (comptime keyPath("ui.line_numbers"))[1]);
    // Three levels down: the pty-cursor rows sit inside `ui.pty_cursor`,
    // and both the read and the write have to walk the whole path.
    try t.expectEqual(@as(usize, 0), currentIndex(&c, "ui.pty_cursor.unfocused")); // hollow
    setIndex(&c, "ui.pty_cursor.unfocused", 2);
    try t.expectEqual(Config.PtyCursor.Unfocused.none, c.ui.pty_cursor.unfocused);
    try t.expectEqual(@as(usize, 1), currentIndex(&c, "ui.pty_cursor.blink")); // on
    setIndex(&c, "ui.pty_cursor.blink", 0);
    try t.expect(!c.ui.pty_cursor.blink);
    try t.expectEqualStrings("unfocused", (comptime keyPath("ui.pty_cursor.unfocused"))[2]);
    // The shape of mnml's own cursor: `terminal` — follow the mode — is
    // the default, and the three fixed shapes follow it.
    try t.expectEqual(@as(usize, 0), currentIndex(&c, "ui.cursor_shape"));
    setIndex(&c, "ui.cursor_shape", 2);
    try t.expectEqual(Config.CursorShape.bar, c.ui.cursor_shape);
    setIndex(&c, "ui.cursor_shape", 0);
    try t.expectEqual(Config.CursorShape.terminal, c.ui.cursor_shape);
}

test "the highlighting size limit is a choice row, not a step row: 4 MB is the default, and a hand-set value reads as the choice above it" {
    // A u64 of bytes, offered as five sizes — the raw number is the ZON
    // view's to edit.
    try t.expect(!comptime isNumber("editor.highlight_max_bytes"));
    try t.expectEqual(@as(usize, 5), options("editor.highlight_max_bytes").len);
    try t.expectEqualStrings("off", options("editor.highlight_max_bytes")[0]);
    try t.expectEqualStrings("4 MB", options("editor.highlight_max_bytes")[2]);
    var c: Config = .{};
    // The shipped default is the third choice, and the row says so.
    try t.expectEqual(@as(usize, 2), currentIndex(&c, "editor.highlight_max_bytes"));
    setIndex(&c, "editor.highlight_max_bytes", 3);
    try t.expectEqual(@as(u64, 16 << 20), c.editor.highlight_max_bytes);
    try t.expectEqual(@as(usize, 3), currentIndex(&c, "editor.highlight_max_bytes"));
    // Round to off, and round the row wraps.
    setIndex(&c, "editor.highlight_max_bytes", 5);
    try t.expectEqual(@as(u64, 0), c.editor.highlight_max_bytes);
    try t.expectEqual(@as(usize, 0), currentIndex(&c, "editor.highlight_max_bytes"));
    // A value typed into the file by hand: never reported as "off".
    c.editor.highlight_max_bytes = 8 << 20;
    try t.expectEqual(@as(usize, 3), currentIndex(&c, "editor.highlight_max_bytes"));
    c.editor.highlight_max_bytes = 1;
    try t.expectEqual(@as(usize, 1), currentIndex(&c, "editor.highlight_max_bytes"));
    c.editor.highlight_max_bytes = 1 << 40;
    try t.expectEqual(@as(usize, 4), currentIndex(&c, "editor.highlight_max_bytes"));
}

test "a row a later layer also sets says which file wins, and saving it says so too" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.createDirPath(t.io, "home");
    // `--config extra.zon` pins the clock off; the workspace pins the theme.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "extra.zon", .data = ".{ .ui = .{ .clock = false } }\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data = ".{ .ui = .{ .theme = \"gruvbox\" } }\n" });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const home = try std.fs.path.join(t.allocator, &.{ root, "home" });
    defer t.allocator.free(home);
    const extra = try std.fs.path.join(t.allocator, &.{ root, "extra.zon" });
    defer t.allocator.free(extra);
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    try vars.put("MNML_DATA_ROOT", home);
    const loaded = try config.load.load(t.allocator, t.io, .{ .explicit = extra, .workspace = ws, .trust = .trusted, .data_root = home, .env = .{ .vars = &vars } });
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .data_root = home, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();
    try t.expect(!app.cfg.ui.clock);

    try command.run(&app, .{ .static = .@"view.settings" });
    const arena = app.frame.allocator();
    const list = try items(&app, arena);
    var clock_item: ?usize = null;
    var theme_item: ?usize = null;
    var dots_item: ?usize = null;
    for (list, 0..) |it, i| if (it == .row) {
        if (std.mem.eql(u8, it.row.label, "Clock in statusline")) clock_item = i;
        if (std.mem.eql(u8, it.row.label, "Theme")) theme_item = i;
        if (std.mem.eql(u8, it.row.label, "Workspace dots")) dots_item = i;
    };
    // The row's subtitle names the file that wins…
    app.overlay.settings.ui.cursor = clock_item.?;
    try t.expect(std.mem.indexOf(u8, (try footer(&app, arena, list)).?, "overridden by ") != null);
    try t.expect(std.mem.endsWith(u8, (try footer(&app, arena, list)).?, "extra.zon"));
    app.overlay.settings.ui.cursor = theme_item.?;
    try t.expect(std.mem.endsWith(u8, (try footer(&app, arena, list)).?, "overridden by .mnml/config.zon"));
    // …and a row nothing else sets does not claim one.
    app.overlay.settings.ui.cursor = dots_item.?;
    try t.expect(std.mem.indexOf(u8, (try footer(&app, arena, list)).?, "overridden") == null);

    // Saving the pinned row still writes the home file, and says the
    // value will not stick.
    app.overlay.settings.ui.cursor = clock_item.?;
    try app.handle(.{ .key = Key.named(.right) });
    try t.expect(app.cfg.ui.clock);
    const written = (try readOrNull(tmp, "home/config.zon")).?;
    defer t.allocator.free(written);
    try t.expect(std.mem.indexOf(u8, written, ".clock = true") != null);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "ui.clock: saved, but ") != null);
    try t.expect(std.mem.indexOf(u8, app.lastToast().?, "extra.zon sets it too — that value wins at the next launch") != null);
    try app.handle(.{ .key = Key.named(.esc) });
}

test "adjust writes the row's file live; Esc restores bytes (and absence); Enter keeps; r and R reset" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.createDirPath(t.io, "home");
    const seed = ".{\n    .ui = .{\n        .tree_width = 40,\n    },\n}\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "ws/.mnml/config.zon", .data = seed });
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const home = try std.fs.path.join(t.allocator, &.{ root, "home" });
    defer t.allocator.free(home);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = home, .cols = 100, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();

    try command.run(&app, .{ .static = .@"view.settings" });
    try t.expect(app.overlay == .settings);
    try t.expect(app.focus == .overlay);

    // → on the first row (ui.line_numbers, workspace-scoped): live in cfg
    // and on disk, beside the seed.
    try app.handle(.{ .key = Key.named(.right) });
    try t.expect(!app.cfg.ui.line_numbers);
    {
        const text = (try readOrNull(tmp, "ws/.mnml/config.zon")).?;
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, ".line_numbers = false") != null);
        try t.expect(std.mem.indexOf(u8, text, ".tree_width = 40") != null);
    }
    // a home-scoped row: theme, via the option chips' click path
    try app.handle(.{ .key = Key.named(.esc) });
    {
        const text = (try readOrNull(tmp, "ws/.mnml/config.zon")).?;
        defer t.allocator.free(text);
        try t.expectEqualStrings(seed, text);
    }
    try t.expect(app.cfg.ui.line_numbers);
    try t.expect(app.overlay == .none);
    try t.expect(app.focus == .pane);

    // Enter keeps: adjust, save, and the file still says so.
    try command.run(&app, .{ .static = .@"view.settings" });
    try app.handle(.{ .key = Key.named(.right) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay == .none);
    try t.expect(!app.cfg.ui.line_numbers);
    {
        const text = (try readOrNull(tmp, "ws/.mnml/config.zon")).?;
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, ".line_numbers = false") != null);
    }

    // The home file did not exist; a home row creates it and Esc removes it.
    try command.run(&app, .{ .static = .@"view.settings" });
    const list = try items(&app, app.frame.allocator());
    var theme_item: usize = 0;
    for (list, 0..) |it, i| if (it == .row and std.mem.eql(u8, it.row.label, "Theme")) {
        theme_item = i;
    };
    app.overlay.settings.ui.cursor = theme_item;
    try app.handle(.{ .key = Key.named(.right) });
    try t.expect(!std.mem.eql(u8, app.cfg.ui.theme, "onedark"));
    try t.expectEqualStrings(app.cfg.ui.theme, app.theme.name);
    {
        const created = (try readOrNull(tmp, "home/config.zon")).?;
        defer t.allocator.free(created);
        try t.expect(std.mem.indexOf(u8, created, ".theme = ") != null);
    }
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqualStrings("onedark", app.theme.name);
    try t.expect((try readOrNull(tmp, "home/config.zon")) == null);

    // Ctrl+R resets the row; the `*` marker follows. // changed
    // (settings-typeahead): this app is in the standard profile, where
    // a bare `r` is a query character — Ctrl+R is the reset the footer
    // advertises there, and it works in both profiles.
    try command.run(&app, .{ .static = .@"view.settings" });
    {
        const l = try items(&app, app.frame.allocator());
        try t.expect(l[1].row.modified); // line_numbers is off, default on
    }
    try app.handle(.{ .key = Key.ctrl('r') });
    try t.expect(app.cfg.ui.line_numbers);
    {
        const l = try items(&app, app.frame.allocator());
        try t.expect(!l[1].row.modified);
    }
    try app.handle(.{ .key = Key.named(.right) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.right) });
    try t.expect(!app.cfg.ui.line_numbers and app.cfg.ui.relative_line_numbers);
    // // changed (settings-reset-confirm): reset-all is the Reset
    // section's action row here, and it asks first. Enter takes the
    // focused Cancel and changes nothing; the `R` letter answers Reset.
    {
        const l = try items(&app, app.frame.allocator());
        app.overlay.settings.ui.cursor = l.len - 1;
    }
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay.settings.ui.confirm != null);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay.settings.ui.confirm == null);
    try t.expect(!app.cfg.ui.line_numbers and app.cfg.ui.relative_line_numbers);
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(app.overlay.settings.ui.confirm != null);
    try app.handle(.{ .key = Key.char('R') });
    try t.expect(app.cfg.ui.line_numbers and !app.cfg.ui.relative_line_numbers);
    try app.handle(.{ .key = Key.named(.enter) });

    // input style through the overlay switches the keymap too
    try command.run(&app, .{ .static = .@"view.settings" });
    const l2 = try items(&app, app.frame.allocator());
    for (l2, 0..) |it, i| if (it == .row and std.mem.eql(u8, it.row.label, "Input style")) {
        app.overlay.settings.ui.cursor = i;
    };
    try app.handle(.{ .key = Key.named(.left) });
    try t.expectEqual(input.Style.vim, app.input_style);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqual(input.Style.standard, app.input_style);
}

test "the overlay renders the sections and the footer names the target file" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp/ws", .data_root = "/tmp/home", .cols = 100, .rows = 80 });
    defer app.deinit();
    try open(&app);
    try app.render();
    const text = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, " Settings ") != null);
    try t.expect(std.mem.indexOf(u8, text, "── UI ──") != null);
    try t.expect(std.mem.indexOf(u8, text, "▸ Line numbers:") != null);
    try t.expect(std.mem.indexOf(u8, text, " Settings · → .mnml/config.zon ") != null);
    // The box caps at ~70 % of the screen and UI is the longest section,
    // so no terminal this side of 90 rows shows a second header on open;
    // the section below UI has to be scrolled to before it renders.
    try openAt(&app, .editor);
    try app.render();
    const scrolled = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(scrolled);
    try t.expect(std.mem.indexOf(u8, scrolled, "── Editor ──") != null);
    try t.expect(std.mem.indexOf(u8, scrolled, "▸ Input style:") != null);
    // // changed (settings-title-path): a home-scope row's file is shown
    // under `~`, and when it still does not fit the box cuts the path
    // from the LEFT so the file name — the fact the line exists to
    // carry — survives.
    try app.env.put("HOME", "/tmp");
    try openAt(&app, .ui);
    for ((try items(&app, app.frame.allocator())), 0..) |it, i| if (it == .row and std.mem.eql(u8, it.row.label, "Theme")) {
        app.overlay.settings.ui.cursor = i;
    };
    {
        const sub = (try footer(&app, app.frame.allocator(), try items(&app, app.frame.allocator()))).?;
        try t.expectEqualStrings("→ ~/home/config.zon", sub);
    }
    try app.render();
    const home_title = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(home_title);
    try t.expect(std.mem.indexOf(u8, home_title, " Settings · → ~/home/config.zon ") != null);
    // click outside closes and keeps
    try app.handle(.{ .mouse = .{ .x = 1, .y = 1, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .none);
}

test "// changed (settings-title-path): a subtitle too long for the box is cut from the LEFT, so the file name survives" {
    var f = try Fixture.init(60, 10);
    defer f.deinit();
    const ui = f.ui();
    const long = "→ /var/folders/md/rtcqqnkn661bgwnl4h__tgz80000gn/T/mnml-e2e/config.zon";
    try t.expectEqualStrings(long, ui_settings.elideLeft(ui, long, @intCast(long.len)));
    const cut = ui_settings.elideLeft(ui, long, 20);
    try t.expect(std.mem.startsWith(u8, cut, "…"));
    try t.expect(std.mem.endsWith(u8, cut, "config.zon"));
    try t.expect(ui.fitsIn(cut, 20));
    // Never past the cut: one cell of room is the mark alone.
    try t.expectEqualStrings("…", ui_settings.elideLeft(ui, long, 1));
    try t.expectEqualStrings("", ui_settings.elideLeft(ui, long, 0));
}

test "number rows: → steps the right panel width, writes it, and the config seeds the slot" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = root, .cols = 100, .rows = 80, .cfg = .{ .ui = .{ .right_panel_visible = true, .right_panel_width = 30 } } });
    defer app.deinit();
    // `right_panel_visible` opens the right column on the first section
    // that lives there. // changed (bottom-dock): the diagnostics moved
    // to the dock, so that is the outline.
    try t.expectEqual(side.Section.outline, side.shown(&app, .right).?);
    try t.expectEqual(@as(u16, 30), app.side.right_width);
    try open(&app);
    const list = try items(&app, app.frame.allocator());
    for (list, 0..) |it, i| if (it == .row and std.mem.eql(u8, it.row.label, "Right panel width")) {
        app.overlay.settings.ui.cursor = i;
        try t.expect(it.row.number != null);
        try t.expectEqual(@as(usize, 30), it.row.current);
    };
    try app.handle(.{ .key = Key.named(.right) });
    try t.expectEqual(@as(u16, 32), app.cfg.ui.right_panel_width);
    try t.expectEqual(@as(u16, 32), app.side.right_width);
    try app.handle(.{ .key = Key.named(.left) });
    try app.handle(.{ .key = Key.named(.left) });
    try t.expectEqual(@as(u16, 28), app.cfg.ui.right_panel_width);
    {
        const text = (try readOrNull(tmp, "ws/.mnml/config.zon")).?;
        defer t.allocator.free(text);
        try t.expect(std.mem.indexOf(u8, text, ".right_panel_width = 28") != null);
    }
    // The visible row hides the panel live; Esc puts everything back.
    for (list, 0..) |it, i| if (it == .row and std.mem.eql(u8, it.row.label, "Right panel at start")) {
        app.overlay.settings.ui.cursor = i;
    };
    try app.handle(.{ .key = Key.named(.right) });
    try t.expect(side.shown(&app, .right) == null);
    try t.expect(app.focus == .overlay);
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expectEqual(@as(u16, 30), app.cfg.ui.right_panel_width);
    try t.expect((try readOrNull(tmp, "ws/.mnml/config.zon")) == null);
    // The rendered row reads `‹ [30] ›`. // changed (dock-v2): the UI
    // section grew past what 80 rows show, so the reopened list has to
    // be scrolled to the row — `draw` scrolls to the cursor.
    try open(&app);
    for (try items(&app, app.frame.allocator()), 0..) |it, i| if (it == .row and std.mem.eql(u8, it.row.label, "Right panel width")) {
        app.overlay.settings.ui.cursor = i;
    };
    try app.render();
    const screen = try @import("../ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(screen);
    try t.expect(std.mem.indexOf(u8, screen, "Right panel width:") != null);
    try t.expect(std.mem.indexOf(u8, screen, "‹ [30] ›") != null);
}

/// The row index of a path, for the tests.
fn rowId(comptime path: []const u8) u32 {
    inline for (rows, 0..) |r, i| if (comptime std.mem.eql(u8, r.path, path)) return i;
    @compileError("no settings row for " ++ path);
}

test "the AI section: the ghost-text row writes the token and the runtime override, an optional backend row writes the tag or null; Esc restores the override" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 40 });
    defer app.deinit();
    try open(&app);
    const list = try items(&app, app.frame.allocator());
    var saw_ai = false;
    for (list) |it| if (it == .section and std.mem.eql(u8, it.section, "AI")) {
        saw_ai = true;
    };
    try t.expect(saw_ai);
    // Ghost-text backend: unset → claude-api.
    try t.expectEqual(@as(usize, 0), rowIndex(&app, "ai.suggest_backend"));
    try setRow(&app, rowId("ai.suggest_backend"), 2);
    try t.expectEqual(suggest.Backend.claude_api, app.ai.backend_override.?);
    try t.expectEqual(@as(usize, 2), rowIndex(&app, "ai.suggest_backend"));
    const home = (try configPath(&app, .home)).?;
    const text = try Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".suggest_backend = \"claude-api\"") != null);
    // Claude backend: an optional enum — `unset` is null, the rest the tags.
    try t.expectEqual(@as(usize, 0), rowIndex(&app, "ai.routing.claude.backend"));
    try t.expectEqualStrings("unset", options("ai.routing.claude.backend")[0]);
    try setRow(&app, rowId("ai.routing.claude.backend"), 2);
    try t.expectEqual(Config.AiBackend.api, app.cfg.ai.routing.claude.backend.?);
    const text2 = try Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text2);
    try t.expect(std.mem.indexOf(u8, text2, ".backend = .api") != null);
    try setRow(&app, rowId("ai.routing.claude.backend"), 0);
    try t.expect(app.cfg.ai.routing.claude.backend == null);
    // Esc: the override goes back to how it was when the overlay opened.
    try cancel(&app);
    try t.expect(app.ai.backend_override == null);
    try t.expect(app.overlay == .none);
}

test "view.tab_bar_ai_* and view.cluster_mode_* set the key, persist it to the home config, and toast" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = root, .data_root = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    try command.run(&app, .{ .static = .@"view.tab_bar_ai_none" });
    try std.testing.expectEqual(Config.TabBarAiIcon.none, app.cfg.ui.tab_bar_ai_icon);
    try std.testing.expectEqualStrings("AI chips hidden", app.lastToast().?);
    try command.run(&app, .{ .static = .@"view.cluster_mode_compact" });
    try std.testing.expectEqual(Config.TopBarClusterMode.compact, app.cfg.ui.top_bar_cluster_mode);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(app.frame.allocator(), &.{ root, "config.zon" }), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".tab_bar_ai_icon = .none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".top_bar_cluster_mode = .compact") != null);
    try command.run(&app, .{ .static = .@"view.tab_bar_ai_both" });
    try std.testing.expectEqual(Config.TabBarAiIcon.both, app.cfg.ui.tab_bar_ai_icon);
    try command.run(&app, .{ .static = .@"view.tab_bar_ai_claude_only" });
    try std.testing.expectEqual(Config.TabBarAiIcon.claude_code, app.cfg.ui.tab_bar_ai_icon);
    try command.run(&app, .{ .static = .@"view.tab_bar_ai_codex_only" });
    try command.run(&app, .{ .static = .@"view.cluster_mode_expanded" });
    try command.run(&app, .{ .static = .@"view.cluster_mode_auto" });
    try std.testing.expectEqual(Config.TabBarAiIcon.codex, app.cfg.ui.tab_bar_ai_icon);
    try std.testing.expectEqual(Config.TopBarClusterMode.auto, app.cfg.ui.top_bar_cluster_mode);
}

test "the UI section's Terminal icon row: three choices, the ghost the shipped one, `←→` writes the key to the home config" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 40 });
    defer app.deinit();
    try open(&app);
    const opts = options("ui.terminal_glyph");
    try t.expectEqual(@as(usize, 3), opts.len);
    try t.expectEqualStrings("ghostty", opts[0]);
    try t.expectEqualStrings("terminal", opts[1]);
    try t.expectEqualStrings("custom", opts[2]);
    // The shipped value is the one the row opens on.
    try t.expectEqual(@as(usize, 0), rowIndex(&app, "ui.terminal_glyph"));
    try setRow(&app, rowId("ui.terminal_glyph"), 1);
    try t.expectEqual(Config.TerminalGlyph.terminal, app.cfg.ui.terminal_glyph);
    const home = (try configPath(&app, .home)).?;
    const text = try Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".terminal_glyph = .terminal") != null);
}

test "the UI section's Claude icon row: three choices, the figure the shipped one, `←→` writes the key to the home config" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = root, .data_root = root, .cols = 100, .rows = 40 });
    defer app.deinit();
    try open(&app);
    // The twin of the Terminal icon row above, and it grew the same
    // third choice: the user's own SVG, baked at the figure's
    // codepoint (`app/mark_bake.zig`).
    const opts = options("ui.claude_mark");
    try t.expectEqual(@as(usize, 3), opts.len);
    try t.expectEqualStrings("figure", opts[0]);
    try t.expectEqualStrings("spark", opts[1]);
    try t.expectEqualStrings("custom", opts[2]);
    // The shipped value is the one the row opens on.
    try t.expectEqual(@as(usize, 0), rowIndex(&app, "ui.claude_mark"));
    try setRow(&app, rowId("ui.claude_mark"), 1);
    try t.expectEqual(Config.ClaudeMark.spark, app.cfg.ui.claude_mark);
    const home = (try configPath(&app, .home)).?;
    const text = try Io.Dir.cwd().readFileAlloc(app.io, home, t.allocator, .limited(64 * 1024));
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, ".claude_mark = .spark") != null);
}

// ─── opening on a section ────────────────────────────────────────────────

/// `open`, then the cursor on `section`'s first row — what
/// `integrations.configure_picker` wants: the overlay scrolled to the
/// rows the installed manifests declare.
pub fn openAt(app: *App, section: Section) Allocator.Error!void {
    try open(app);
    const list = try items(app, app.frame.allocator());
    const st = &app.overlay.settings;
    for (list, 0..) |it, i| switch (it) {
        .section => |name| if (std.mem.eql(u8, name, section.label())) {
            st.ui.cursor = i + 1;
            st.ui.settle(list);
            return;
        },
        else => {},
    };
}

test "openAt lands the cursor on the section's first row" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp/ws", .data_root = "/tmp/home", .cols = 100, .rows = 40 });
    defer app.deinit();
    try openAt(&app, .editor);
    try t.expect(app.overlay == .settings);
    const list = try items(&app, app.frame.allocator());
    const cur = app.overlay.settings.ui.cursor;
    try t.expect(list[cur] == .row);
    try t.expect(list[cur - 1] == .section);
    try t.expectEqualStrings("Editor", list[cur - 1].section);
    try t.expect(rows[list[cur].row.id].section == .editor);
}

test "view.toggle_picker_position flips center ⇄ top, writes it to the home config and toasts; view.ai_layout_* set the mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root = buf[0..n];
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = root, .data_root = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    try std.testing.expectEqual(Config.PickerPosition.center, app.cfg.ui.picker_position);
    try command.run(&app, .{ .static = .@"view.toggle_picker_position" });
    try std.testing.expectEqual(Config.PickerPosition.top, app.cfg.ui.picker_position);
    try std.testing.expectEqualStrings("picker position: top", app.lastToast().?);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(app.frame.allocator(), &.{ root, "config.zon" }), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, ".picker_position = .top") != null);
    try command.run(&app, .{ .static = .@"view.toggle_picker_position" });
    try std.testing.expectEqual(Config.PickerPosition.center, app.cfg.ui.picker_position);
    try std.testing.expectEqualStrings("picker position: center", app.lastToast().?);
    try command.run(&app, .{ .static = .@"view.ai_layout_tabs" });
    try std.testing.expectEqual(Config.AiLayoutMode.tabs, app.cfg.ui.ai_layout_mode);
    try std.testing.expectEqualStrings("AI layout: tabs", app.lastToast().?);
    try command.run(&app, .{ .static = .@"view.ai_layout_grid" });
    try std.testing.expectEqual(Config.AiLayoutMode.grid, app.cfg.ui.ai_layout_mode);
    try std.testing.expectEqualStrings("AI layout: grid", app.lastToast().?);
    const again = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fs.path.join(app.frame.allocator(), &.{ root, "config.zon" }), std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(again);
    try std.testing.expect(std.mem.indexOf(u8, again, ".ai_layout_mode = .grid") != null);
}

test "the filter narrows the rows to the ones that match, clamps the cursor to one, and Esc takes the query before the box" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.createDirPath(t.io, "home");
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const home = try std.fs.path.join(t.allocator, &.{ root, "home" });
    defer t.allocator.free(home);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = home, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();

    try command.run(&app, .{ .static = .@"view.settings" });
    const st = &app.overlay.settings;
    const arena = app.frame.allocator();
    const total = (try lists(&app, arena)).all.len;
    try t.expect(total > 40);

    // End puts the cursor on the last item of ninety-odd — the `Reset
    // all to defaults` action — so a query that leaves six rows has
    // somewhere badly wrong to leave it.
    try app.handle(.{ .key = Key.named(.end) });
    {
        const l = try lists(&app, app.frame.allocator());
        try t.expectEqual(l.all.len - 1, st.ui.cursor);
    }

    // `/` opens the pill; typing narrows the list live.
    try app.handle(.{ .key = Key.char('/') });
    try t.expect(st.ui.filter.open and st.ui.filter.focused);
    for ("dock") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqualStrings("dock", st.ui.filter.text());
    {
        const l = try lists(&app, app.frame.allocator());
        try t.expectEqual(total, l.all.len);
        try t.expect(l.visible.len < l.all.len);
        // Every row left says `dock` somewhere; the UI header rode
        // along because its rows matched, and no other header did.
        var headers: usize = 0;
        for (l.visible) |it| switch (it) {
            .section => headers += 1,
            .row => |r| {
                var vb: [24]u8 = undefined;
                try t.expect(std.ascii.indexOfIgnoreCase(r.label, "dock") != null or
                    std.ascii.indexOfIgnoreCase(ui_settings.valueWord(r, &vb), "dock") != null);
            },
            .action => try t.expect(false),
        };
        try t.expectEqual(@as(usize, 1), headers);
        // The row the cursor was on is gone, so the cursor is clamped
        // to the FIRST match — item 1, under the one header — with the
        // window back at the top. Not the last row it can reach.
        try t.expectEqual(@as(usize, 1), st.ui.cursor);
        try t.expectEqual(@as(usize, 0), st.ui.scroll);
        try t.expectEqualStrings("Launcher dock", l.visible[st.ui.cursor].row.label);
    }

    // A row that still matches keeps the focus across a query change,
    // wherever the narrowing moved it to. // changed (dock-placement):
    // the placement row sits between the edge row and the labels one,
    // so three downs is where `Launcher dock labels` is now.
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    {
        const l = try lists(&app, app.frame.allocator());
        try t.expectEqualStrings("Launcher dock labels", l.visible[st.ui.cursor].row.label);
    }
    try app.handle(.{ .key = Key.named(.backspace) });
    try t.expectEqualStrings("doc", st.ui.filter.text());
    {
        const l = try lists(&app, app.frame.allocator());
        try t.expectEqualStrings("Launcher dock labels", l.visible[st.ui.cursor].row.label);
    }
    try app.handle(.{ .key = Key.char('k') });
    try t.expectEqualStrings("dock", st.ui.filter.text());

    // A query nothing answers to: no rows, and the cursor has nowhere
    // to sit — the next keystroke must not reach into an empty list.
    for ("zzz") |c| try app.handle(.{ .key = Key.char(c) });
    {
        const l = try lists(&app, app.frame.allocator());
        try t.expectEqual(@as(usize, 0), l.visible.len);
    }
    try app.handle(.{ .key = Key.named(.right) }); // the caret, not a row
    for (0..3) |_| try app.handle(.{ .key = Key.named(.backspace) });
    try t.expectEqualStrings("dock", st.ui.filter.text());

    // Enter hands the list back; `←` then adjusts the focused *matched*
    // row — the launcher dock's mode, the first `dock` row there is.
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(!st.ui.filter.focused);
    const before_mode = app.cfg.ui.dock.mode;
    try app.handle(.{ .key = Key.named(.left) });
    try t.expect(app.cfg.ui.dock.mode != before_mode);

    // Esc takes the query and leaves the box open; the second Esc
    // cancels it, and cancelling puts the value back.
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .settings);
    try t.expectEqualStrings("", st.ui.filter.text());
    try t.expect(!st.ui.filter.open);
    {
        const l = try lists(&app, app.frame.allocator());
        try t.expectEqual(total, l.visible.len);
    }
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(app.overlay == .none);
    try t.expectEqual(before_mode, app.cfg.ui.dock.mode);
}

test "a click on the pill puts the keys back in it, and one on a section the query emptied does nothing" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();

    try command.run(&app, .{ .static = .@"view.settings" });
    const st = &app.overlay.settings;
    try app.handle(.{ .key = Key.char('/') });
    for ("dock") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try t.expect(!st.ui.filter.focused);
    try click(&app, ui_settings.filter_id);
    try t.expect(st.ui.filter.focused);

    // `Editor` is section 1 of the whole list and holds no `dock` row:
    // its name is still on the strip and still clickable, and the click
    // is a no-op rather than a jump into the wrong section.
    const before = st.ui.cursor;
    try click(&app, ui_settings.sectionHit(1));
    try t.expectEqual(before, st.ui.cursor);
    // `UI` does hold them, so its own click still jumps.
    try click(&app, ui_settings.sectionHit(0));
    const l = try lists(&app, app.frame.allocator());
    try t.expect(l.visible[st.ui.cursor] == .row);
}

test "the fold-arrows row sits in Editor, offers off / on, and writes ui.always_show_fold_arrows to the home config" {
    // The gutter's chevron is offered under the pointer; this row is
    // how you ask for it on every foldable line without one.
    const idx = comptime blk: {
        for (rows, 0..) |r, i| if (std.mem.eql(u8, r.path, "ui.always_show_fold_arrows")) break :blk i;
        @compileError("no settings row for ui.always_show_fold_arrows");
    };
    try t.expectEqual(Section.editor, rows[idx].section);
    try t.expectEqual(Scope.home, rows[idx].scope);
    try t.expectEqualStrings("Always show fold arrows", rows[idx].label);
    try t.expectEqual(@as(usize, 2), options("ui.always_show_fold_arrows").len);
    try t.expectEqualStrings("off", options("ui.always_show_fold_arrows")[0]);
    try t.expectEqualStrings("on", options("ui.always_show_fold_arrows")[1]);
    // Off is the default, so a fresh config shows the row unmodified.
    try t.expectEqual(@as(usize, 0), comptime defaultIndex("ui.always_show_fold_arrows"));

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    try tmp.dir.createDirPath(t.io, "home");
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    const home = try std.fs.path.join(t.allocator, &.{ root, "home" });
    defer t.allocator.free(home);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = home, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();

    try command.run(&app, .{ .static = .@"view.settings" });
    try t.expect(!app.cfg.ui.always_show_fold_arrows);
    // The row's own id, adjusted the way `←→` adjust it: the live
    // config flips and the home file carries the value.
    try adjust(&app, idx, 1);
    try t.expect(app.cfg.ui.always_show_fold_arrows);
    const path = try std.fs.path.join(t.allocator, &.{ home, config.data_root.config_file });
    defer t.allocator.free(path);
    const written = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .unlimited);
    defer t.allocator.free(written);
    try t.expect(std.mem.indexOf(u8, written, ".always_show_fold_arrows = true") != null);

    // Esc cancels, and cancelling puts both the value and the file back.
    try app.handle(.{ .key = Key.named(.esc) });
    try t.expect(!app.cfg.ui.always_show_fold_arrows);
}

test "view.settings_search opens the box with the filter holding the keys, and `fold` finds the row" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &buf);
    const root = buf[0..n];
    try tmp.dir.createDirPath(t.io, "ws/.mnml");
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = ws, .data_root = root, .cols = 120, .rows = 40 });
    defer app.deinit();
    _ = try app.openScratch();

    // `view.settings` alone leaves the pill down — the keys move the
    // list. The search verb is the one that opens it.
    try command.run(&app, .{ .static = .@"view.settings" });
    try t.expect(!app.overlay.settings.ui.filter.open);
    try app.handle(.{ .key = Key.named(.esc) });

    try command.run(&app, .{ .static = .@"view.settings_search" });
    try t.expect(app.overlay == .settings);
    try t.expect(app.focus == .overlay);
    const st = &app.overlay.settings;
    try t.expect(st.ui.filter.open and st.ui.filter.focused);
    try t.expectEqualStrings("", st.ui.filter.text());

    // Typing goes to the query, not the list: `fold` leaves the row
    // this track added, and the cursor is on it.
    for ("fold") |c| try app.handle(.{ .key = Key.char(c) });
    try t.expectEqualStrings("fold", st.ui.filter.text());
    const l = try lists(&app, app.frame.allocator());
    try t.expect(l.visible.len < l.all.len);
    try t.expectEqualStrings("Always show fold arrows", l.visible[st.ui.cursor].row.label);
}
