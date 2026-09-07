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
const Config = config.Config;
const command = @import("../core/command.zig");
const side = @import("side.zig");
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
};

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
    const path = (try configPath(app, scope)) orelse {
        app.toast("nowhere to save settings (no home directory)", .{});
        return false;
    };
    const literal = try config.persist.serializeLiteral(app.frame.allocator(), value);
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
    .{ .path = "ui.todos_sort", .label = "TODOS sort", .section = .ui, .scope = .workspace },
    .{ .path = "ui.theme", .label = "Theme", .section = .ui, .scope = .home },
    .{ .path = "ui.ascii_icons", .label = "ASCII icons", .section = .ui, .scope = .home },
    .{ .path = "ui.clock", .label = "Clock in statusline", .section = .ui, .scope = .home },
    .{ .path = "ui.menu_bar", .label = "Menu bar", .section = .ui, .scope = .home },
    .{ .path = "ui.activity_bar", .label = "Activity bar", .section = .ui, .scope = .home },
    .{ .path = "ui.debug_toolbar", .label = "Debug toolbar strip", .section = .ui, .scope = .home },
    .{ .path = "ui.bufferline_diag_style", .label = "Diag chip on tabs", .section = .ui, .scope = .home },
    .{ .path = "ui.expand_indicator", .label = "Expand indicator", .section = .ui, .scope = .home },
    .{ .path = "ui.picker_position", .label = "Picker position", .section = .ui, .scope = .home },
    .{ .path = "ui.show_workspace_dots", .label = "Workspace dots", .section = .ui, .scope = .home },
    .{ .path = "ui.hover_help", .label = "Hover help", .section = .ui, .scope = .home },
    .{ .path = "ui.hover_tooltip", .label = "Hover tooltips", .section = .ui, .scope = .home },
    .{ .path = "ui.click_echo", .label = "Click echo in statusline", .section = .ui, .scope = .home },
    .{ .path = "ui.highlight_word_under_cursor", .label = "Highlight word under cursor", .section = .ui, .scope = .workspace },
    .{ .path = "ui.highlight_todo_keywords", .label = "Highlight TODO keywords", .section = .ui, .scope = .workspace },
    .{ .path = "ui.render_markdown", .label = "Inline-rendered markdown", .section = .ui, .scope = .workspace },
    .{ .path = "ui.sticky_context", .label = "Sticky scope context", .section = .ui, .scope = .workspace },
    .{ .path = "ui.markdown_opens_rendered", .label = "Markdown opens rendered", .section = .ui, .scope = .home },
    .{ .path = "ui.auto_md_preview", .label = "Auto markdown preview", .section = .ui, .scope = .home },
    .{ .path = "ui.stress_meter", .label = "Stress meter", .section = .ui, .scope = .home },
    .{ .path = "ui.top_bar_cluster_mode", .label = "Top bar cluster", .section = .ui, .scope = .home },
    .{ .path = "ui.tab_bar_ai_icon", .label = "AI icon in the bar", .section = .ui, .scope = .home },
    .{ .path = "ui.ai_layout_mode", .label = "AI session layout", .section = .ui, .scope = .home },
    .{ .path = "ui.coverage_chip_mode", .label = "Coverage chip", .section = .ui, .scope = .home },
    .{ .path = "ui.right_panel_visible", .label = "Right panel at start", .section = .ui, .scope = .workspace },
    .{ .path = "ui.right_panel_width", .label = "Right panel width", .section = .ui, .scope = .workspace, .number = .{ .min = 8, .max = 120, .step = 2 } },
    .{ .path = "ui.tree_width", .label = "Tree width", .section = .ui, .scope = .workspace, .number = .{ .min = config.Config.tree_width_min, .max = config.Config.tree_width_max, .step = 2 } },
    .{ .path = "ui.sidebar_side", .label = "Default sidebar side", .section = .ui, .scope = .home },
    .{ .path = "ui.color_column", .label = "Colour column (0 = off)", .section = .ui, .scope = .workspace, .number = .{ .min = 0, .max = 240, .step = 4 } },
    .{ .path = "ui.wheel_lines", .label = "Lines per wheel notch", .section = .ui, .scope = .home, .number = .{ .min = 1, .max = 12, .step = 1 } },
    .{ .path = "ui.md_image_rows", .label = "Markdown image rows", .section = .ui, .scope = .home, .number = .{ .min = 3, .max = 40, .step = 1 } },
    .{ .path = "ui.hover_help_height", .label = "Hover help rows", .section = .ui, .scope = .home, .number = .{ .min = config.Config.hover_help_height_min, .max = config.Config.hover_help_height_max, .step = 1 } },
    // ── Editor ──
    .{ .path = "editor.input_style", .label = "Input style", .section = .editor, .scope = .home },
    .{ .path = "editor.auto_pair", .label = "Auto-pair brackets", .section = .editor, .scope = .workspace },
    .{ .path = "editor.auto_indent", .label = "Auto-indent", .section = .editor, .scope = .workspace },
    .{ .path = "editor.format_on_save", .label = "Format on save", .section = .editor, .scope = .workspace },
    .{ .path = "editor.trim_trailing_ws_on_save", .label = "Trim trailing whitespace on save", .section = .editor, .scope = .workspace },
    .{ .path = "editor.ensure_trailing_newline", .label = "Ensure trailing newline", .section = .editor, .scope = .workspace },
    .{ .path = "editor.breadcrumb", .label = "Breadcrumb", .section = .editor, .scope = .home },
    .{ .path = "editor.inline_values", .label = "Inline debugger values", .section = .editor, .scope = .workspace },
    .{ .path = "editor.cursor_blink", .label = "Cursor blink", .section = .editor, .scope = .home },
    .{ .path = "editor.wheel_moves_cursor", .label = "Mouse wheel moves cursor", .section = .editor, .scope = .home },
    .{ .path = "editor.scroll_accel", .label = "Scroll acceleration", .section = .editor, .scope = .home },
    .{ .path = "editor.clipboard", .label = "System clipboard", .section = .editor, .scope = .home },
    .{ .path = "editor.tab_width", .label = "Tab width", .section = .editor, .scope = .workspace, .number = .{ .min = 1, .max = 16, .step = 1 } },
    .{ .path = "editor.text_width", .label = "Text width", .section = .editor, .scope = .workspace, .number = .{ .min = 20, .max = 400, .step = 10 } },
    .{ .path = "editor.chord_timeout_ms", .label = "Chord timeout (ms)", .section = .editor, .scope = .home, .number = .{ .min = config.Config.chord_timeout_ms_min, .max = config.Config.chord_timeout_ms_max, .step = 100 } },
    // ── AI (the model is `ai.model`, free text in the config: v1 rows are
    //    discrete choices) ──
    .{ .path = "ai.inline_suggestions", .label = "Ghost text", .section = .ai, .scope = .home },
    .{ .path = "ai.suggest_backend", .label = "Ghost-text backend", .section = .ai, .scope = .home },
    .{ .path = "ai.routing.claude.backend", .label = "Claude backend", .section = .ai, .scope = .home },
    .{ .path = "ai.routing.codex.backend", .label = "Codex backend", .section = .ai, .scope = .home },
    .{ .path = "ai.claude_meter_mode", .label = "Claude meter", .section = .ai, .scope = .home },
    // ── Integrations ──
    .{ .path = "sonos.enabled", .label = "Sonos", .section = .integrations, .scope = .home },
    .{ .path = "sonos.chip_label", .label = "Sonos chip label", .section = .integrations, .scope = .home },
    .{ .path = "browser.headless", .label = "Browser: headless", .section = .integrations, .scope = .home },
    .{ .path = "browser.profile_mode", .label = "Browser profile", .section = .integrations, .scope = .home },
    .{ .path = "http.collection_root", .label = "HTTP collection root", .section = .integrations, .scope = .home },
    .{ .path = "marketplace.enabled", .label = "Marketplace", .section = .integrations, .scope = .home },
    .{ .path = "session.restore", .label = "Restore session on open", .section = .integrations, .scope = .home },
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

/// `ai.suggest_backend` is not a typed field: the config keeps it in
/// `ai.extra` (a string, aliases allowed) and the setup picker sets a
/// runtime override. The row reads through `ai.suggestBackend` and
/// writes the override plus the file.
fn isSuggestBackend(comptime path: []const u8) bool {
    return std.mem.eql(u8, path, "ai.suggest_backend");
}

/// The ghost-text backend tokens, in `suggest.Backend` order.
pub const suggest_tokens: [4][]const u8 = blk: {
    var out: [4][]const u8 = undefined;
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

    pub fn deinit(s: *State, gpa: Allocator) void {
        for (&s.files.values) |*f| f.deinit(gpa);
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
    app.overlay.deinit(gpa);
    app.overlay = .{ .settings = st };
    app.focus = .overlay;
    app.needs_render = true;
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

/// The subtitle: where the focused row is written.
pub fn footer(app: *App, arena: Allocator, list: []const Item) Allocator.Error!?[]const u8 {
    const st = &app.overlay.settings;
    st.ui.settle(list);
    if (st.ui.cursor >= list.len) return null;
    const row = switch (list[st.ui.cursor]) {
        .row => |r| r,
        else => return null,
    };
    if (row.id >= integ_base) return try std.fmt.allocPrint(arena, "→ {s}/{s}", .{ app.data_root, integrations.settings_file });
    const scope = rows[row.id].scope;
    const path = (try configPath(app, scope)) orelse return "no config file to write";
    return try std.fmt.allocPrint(arena, "→ {s}", .{if (scope == .workspace) app.relPath(path) else path});
}

pub fn key(app: *App, k: Key) Allocator.Error!void {
    const arena = app.frame.allocator();
    const list = try items(app, arena);
    const st = &app.overlay.settings;
    switch (ui_settings.handleKey(&st.ui, k, list)) {
        .consumed => {},
        .cancel => try cancel(app),
        .save => close(app),
        .adjust => |a| try adjust(app, list[a.item].row.id, a.delta),
        .reset_row => |i| try resetRow(app, list[i].row.id),
        .reset_all => try resetAll(app),
        .activate => |i| if (list[i].action.id == reset_id) try resetAll(app),
    }
    app.needs_render = true;
}

/// The wheel over the box: `lines` down (negative up), the cursor
/// riding inside the window.
pub fn wheel(app: *App, lines: isize) Allocator.Error!void {
    const list = try items(app, app.frame.allocator());
    app.overlay.settings.ui.wheel(list, lines);
    app.needs_render = true;
}

/// A click on `hit` (an `.overlay_item` id): focus the row, or jump the
/// row to the option under the pointer.
pub fn click(app: *App, hit: u32) Allocator.Error!void {
    const arena = app.frame.allocator();
    const list = try items(app, arena);
    const st = &app.overlay.settings;
    switch (ui_settings.decodeHit(hit)) {
        .surface => {},
        .row => |id| {
            if (id == reset_id) return resetAll(app);
            st.ui.cursor = itemIndexOf(list, id) orelse return;
        },
        .option => |o| {
            st.ui.cursor = itemIndexOf(list, o.id) orelse return;
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
    } else if (comptime std.mem.eql(u8, path, "editor.auto_indent")) {
        app.syncAutoIndent();
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
    try app.handle(.{ .key = Key.char('l') });
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

    // r resets the row; the `*` marker follows; R resets everything.
    try command.run(&app, .{ .static = .@"view.settings" });
    {
        const l = try items(&app, app.frame.allocator());
        try t.expect(l[1].row.modified); // line_numbers is off, default on
    }
    try app.handle(.{ .key = Key.char('r') });
    try t.expect(app.cfg.ui.line_numbers);
    {
        const l = try items(&app, app.frame.allocator());
        try t.expect(!l[1].row.modified);
    }
    try app.handle(.{ .key = Key.named(.right) });
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.right) });
    try t.expect(!app.cfg.ui.line_numbers and app.cfg.ui.relative_line_numbers);
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
    try t.expect(std.mem.indexOf(u8, text, "── Editor ──") != null);
    try t.expect(std.mem.indexOf(u8, text, "▸ Line numbers:") != null);
    try t.expect(std.mem.indexOf(u8, text, " Settings · → .mnml/config.zon ") != null);
    // click outside closes and keeps
    try app.handle(.{ .mouse = .{ .x = 1, .y = 1, .kind = .press, .button = .left } });
    try t.expect(app.overlay == .none);
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
    // that lives there (the diagnostics, fresh).
    try t.expectEqual(side.Section.diagnostics, side.shown(&app, .right).?);
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
    // The rendered row reads `‹ [30] ›`.
    try open(&app);
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
