//! App state, grouped by subsystem (D7). Render-free. `*App` is the
//! parameter for commands and event handlers — components never see it.
//!
//! This file is the state and its lifecycle: panes, layouts, focus,
//! overlays, toasts, the keymap and chord chain. Behaviour lives beside
//! it in `src/app/`: `dispatch.zig` (keys, mouse, the 22 `AppCommand`s),
//! `render.zig` (one frame), `ex.zig` (the `:` interpreter), the
//! `cmd_*.zig` runner tables, and `driver.zig` (the `.test` / headless
//! seam).
//!
//! // changed: D3 resets the frame arena at the top of the loop. Here it
//! is reset at the top of `render` instead — the hit map the components
//! register lives on the frame arena and has to survive until the next
//! mouse event, which arrives at the top of the following iteration.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vaxis = @import("vaxis");
const alloc = @import("core/alloc.zig");
const command = @import("core/command.zig");
const event = @import("core/event.zig");
const keymap = @import("core/keymap.zig");
const key_mod = @import("core/key.zig");
const ids = @import("core/ids.zig");
const hooks = @import("core/hooks.zig");
const input = @import("input/mod.zig");
const config = @import("config/root.zig");
const buffer_mod = @import("editor/buffer.zig");
const edit_op = @import("editor/edit_op.zig");
const pane_mod = @import("app/pane.zig");
const layout_mod = @import("app/layout.zig");
const find_mod = @import("app/find.zig");
const syntax = @import("app/syntax.zig");
const whichkey = @import("app/whichkey.zig");
const tree_mod = @import("app/tree.zig");
const ex = @import("app/ex.zig");
const dispatch = @import("app/dispatch.zig");
const render_mod = @import("app/render.zig");
const theme_mod = @import("ui/theme.zig");
const hit = @import("ui/hit.zig");
const prompt_mod = @import("ui/prompt.zig");
const confirm_mod = @import("ui/confirm.zig");
const picker_mod = @import("ui/picker.zig");
const find_bar_mod = @import("ui/find_bar.zig");
const toast_mod = @import("ui/toast.zig");
const editor_view = @import("ui/editor_view.zig");
const todos = @import("todos.zig");
const panel_mod = @import("core/panel.zig");
const trust_app = @import("app/trust.zig");
const settings_app = @import("app/settings.zig");

pub const PaneId = ids.PaneId;
pub const PanelId = panel_mod.PanelId;
pub const FocusId = ids.FocusId;
pub const Pane = pane_mod.Pane;
pub const EditorPane = pane_mod.EditorPane;
pub const PaneStore = pane_mod.PaneStore;
pub const Buffer = buffer_mod.Buffer;
pub const Clipboard = buffer_mod.Clipboard;
pub const Key = key_mod.Key;
pub const Layout = layout_mod.Layout;
pub const LayoutState = layout_mod.LayoutState;
pub const AppEvent = event.AppEvent;
pub const Prompt = prompt_mod;
pub const Confirm = confirm_mod;
pub const Picker = picker_mod;
pub const FindBar = find_bar_mod;
pub const FindState = find_mod.FindState;

/// The ZON config (E1): `Config{}` is the shipped default, `config.load`
/// the three-layer merge. Every field the app honours is read off
/// `App.cfg`; the loader's arena (`App.loaded`) owns its strings.
pub const Config = config.Config;

/// What `init` needs beyond the allocator and the io.
pub const InitOptions = struct {
    /// The merged config. Borrows `loaded`'s arena when there is one.
    cfg: Config = .{},
    /// The loader's result, when the config came from files. The App
    /// takes ownership — success or failure — and frees it in `deinit`.
    loaded: ?config.Loaded = null,
    /// Absolute. Defaults to the process cwd's name as given.
    workspace: []const u8 = ".",
    data_root: []const u8 = "",
    cols: u16 = 120,
    rows: u16 = 40,
};

/// How long an ordinary toast stays.
pub const toast_ttl_ms: i64 = 4000;

pub const PromptPurpose = enum { goto_line, replace, filter_shell, new_todo };
pub const ConfirmPurpose = union(enum) { close_pane: PaneId, quit, trust_workspace };
pub const PickerKind = enum { buffers, files, themes };

pub const Overlay = union(enum) {
    none,
    prompt: struct {
        state: Prompt.State,
        purpose: PromptPurpose,
        /// A title built at open time (`Replace 3× "q" with`); the
        /// state borrows it.
        title_owned: ?[]u8 = null,
    },
    confirm: struct { state: Confirm.State, purpose: ConfirmPurpose, message: []u8 },
    which_key: whichkey.State,
    picker: struct {
        state: Picker.State,
        kind: PickerKind,
        /// Owned labels, one per candidate (a workspace-relative path
        /// for the files picker).
        labels: [][]u8,
        /// Parallel to `labels` for the buffers picker; empty otherwise.
        panes: []PaneId,
        /// Indices into `labels` in filtered order.
        filtered: std.ArrayListUnmanaged(u32),
        /// The themes picker previews as the cursor moves; Esc puts
        /// this one back.
        restore_theme: ?*const theme_mod = null,
    },
    /// A context menu (a panel row's kebab, a chip's right-click).
    menu: MenuState,
    /// The settings overlay (`view.settings`).
    settings: settings_app.State,

    pub fn deinit(self: *Overlay, gpa: Allocator) void {
        switch (self.*) {
            .none, .which_key => {},
            .settings => |*s| s.deinit(gpa),
            .menu => |*m| gpa.free(m.items),
            .prompt => |*p| {
                Prompt.deinit(&p.state, gpa);
                if (p.title_owned) |t| gpa.free(t);
            },
            .confirm => |*c| gpa.free(c.message),
            .picker => |*p| {
                p.state.deinit(gpa);
                for (p.labels) |l| gpa.free(l);
                gpa.free(p.labels);
                gpa.free(p.panes);
                p.filtered.deinit(gpa);
            },
        }
        self.* = .none;
    }
};

/// A context menu: rows the opener built (gpa-owned slice, literal
/// labels), anchored at the cell that was clicked. `MenuAction` names a
/// static command by enum, so a row cannot point at a missing id.
pub const MenuState = struct {
    title: []const u8,
    items: []command.MenuItem,
    x: u16,
    y: u16,
    cursor: usize = 0,
    /// Where the keyboard goes back to when the menu closes.
    return_focus: FocusId,
};

/// The find bar docked under the active pane while it is open.
pub const FindBarState = struct {
    state: FindBar.State = .{},
    pane: PaneId,
    /// The pane's find state when the bar opened; Esc restores it.
    snapshot: ?FindState,
    snapshot_cursor: usize,
    /// vim `?`: the accept lands on the closest match before the cursor.
    reverse: bool = false,
    /// Enter chains straight into the replace prompt (VS Code `Ctrl+H`).
    chain_to_replace: bool = false,
};

/// Visual-block `I` / `A` / `c` in flight: the typed run on the first
/// row is replayed on the others once Insert mode ends.
pub const BlockInsert = struct { pane: PaneId, first_row: usize, last_row: usize, col: usize, start_byte: usize, len_before: usize };
/// `<count>o` / `<count>O` in flight.
pub const RepeatInsert = struct { pane: PaneId, count: u32, above: bool, start_byte: usize, len_before: usize };

pub const ClosedBuffer = struct { path: []u8, cursor: usize };

/// Where `g;` / `g,` stand in the change list; `len` detects a list that
/// grew since (a fresh edit restarts from the newest entry).
pub const ChangeNav = struct { idx: usize, len: usize };

pub const ChordChain = struct {
    seq: [keymap.max_seq]key_mod.Chord = undefined,
    len: usize = 0,
    deadline_ms: ?i64 = null,
    fallback: ?keymap.Target = null,

    pub fn clear(c: *ChordChain, gpa: Allocator) void {
        c.len = 0;
        c.deadline_ms = null;
        if (c.fallback) |f| switch (f) {
            .named => |s| gpa.free(s),
            .static => {},
        };
        c.fallback = null;
    }
};

pub const ToastLevel = enum { info, warn, err };
pub const Toast = struct {
    text: []u8,
    level: ToastLevel,
    expires_ms: i64,
    /// Stays until dismissed by id (IPC `toast_persistent`).
    id: ?[]u8 = null,
};

/// Tab-completion state on the `:` line: the candidates for the prefix
/// typed, and which one is showing.
pub const CmdComplete = struct {
    prefix: []u8,
    candidates: [][]u8,
    idx: usize,

    pub fn deinit(self: *CmdComplete, gpa: Allocator) void {
        gpa.free(self.prefix);
        for (self.candidates) |c| gpa.free(c);
        gpa.free(self.candidates);
    }
};

pub const App = struct {
    gpa: Allocator,
    io: Io,
    frame: alloc.FrameArena,
    events: event.EventQueue,
    diag: command.Diag = .{},
    cfg: Config,
    /// Owns the arena `cfg` borrows from; null when `cfg` is `Config{}`.
    loaded: ?config.Loaded = null,
    /// `cfg.editor.input_style` in the input layer's own enum — the one
    /// place the two are reconciled (`setInputStyle` keeps them level).
    input_style: input.Style,
    theme: theme_mod = theme_mod.default,
    /// Absolute. Owned.
    workspace: []u8,
    data_root: []u8,
    quit: bool = false,
    restart: bool = false,

    panes: PaneStore,
    layouts: LayoutState,
    tree: tree_mod.Tree,
    /// The right-hand panel slot (Rust's activity panel). One panel at a
    /// time; null hides it. `view.activity_todos` / `view.toggle_right_panel`.
    right_panel: ?PanelId = null,
    todos: todos.State,
    focus: FocusId = .tree,
    active: ?PaneId = null,
    hits: hit.HitMap = .{},
    /// Where the pointer last was; the frame paints hover affordances
    /// (a row's kebab) from it.
    hover: ?struct { x: u16, y: u16 } = null,
    screen: vaxis.Screen,
    /// Rows / text columns of the active pane at the last render; they
    /// size page motions and the wrap width.
    pane_rows: usize = 20,
    pane_cols: usize = 80,
    /// Where the last render put the terminal cursor, if visible.
    cursor_pos: ?editor_view.Cursor = null,

    clipboard: Clipboard,
    keymap: keymap.Keymap,
    chord: ChordChain = .{},
    toasts: std.ArrayListUnmanaged(Toast) = .empty,
    overlay: Overlay = .none,
    find_bar: ?FindBarState = null,
    closed: std.ArrayListUnmanaged(ClosedBuffer) = .empty,
    abbrevs: std.StringHashMapUnmanaged([]u8) = .empty,
    dyn_commands: command.DynRegistry,
    plugin_invocations: std.ArrayListUnmanaged([]u8) = .empty,
    hooks: hooks.Hooks,
    block_insert: ?BlockInsert = null,
    repeat_insert: ?RepeatInsert = null,
    cmd_complete: ?CmdComplete = null,
    /// The line range a `!` filter prompt applies to.
    filter_rows: ?[2]usize = null,
    /// vim `:set ic` / `noic`; null = smart case.
    search_case: ?bool = null,
    /// `g;` / `g,` position in the active editor's change list.
    change_nav: ?ChangeNav = null,
    now_ms: i64 = 0,
    /// `theme.auto_system`: when the OS appearance is next polled.
    theme_auto_poll_ms: ?i64 = null,
    /// Frames since something changed; the loop skips idle renders.
    needs_render: bool = true,

    pub const max_toasts = 32;
    pub const max_closed = 32;

    /// An App on the defaults: 120×40, the standard keymap, workspace `.`.
    pub fn init(gpa: Allocator, io: Io) !App {
        return initWith(gpa, io, .{});
    }

    pub fn initWith(gpa: Allocator, io: Io, opts_in: InitOptions) !App {
        var opts = opts_in;
        errdefer if (opts.loaded) |*l| l.deinit();
        const ws = try gpa.dupe(u8, opts.workspace);
        errdefer gpa.free(ws);
        const dr = try gpa.dupe(u8, opts.data_root);
        errdefer gpa.free(dr);
        var events = try event.EventQueue.init(gpa, 256);
        errdefer events.deinit(io);
        const style = styleOf(opts.cfg.editor.input_style);
        var km = try buildKeymap(gpa, style, opts.cfg.keys);
        errdefer km.deinit();
        var layouts = try LayoutState.init(gpa);
        errdefer layouts.deinit();
        var screen = try vaxis.Screen.init(gpa, .{ .cols = opts.cols, .rows = opts.rows, .x_pixel = 0, .y_pixel = 0 });
        errdefer screen.deinit(gpa);
        screen.width_method = .unicode;
        var app: App = .{
            .gpa = gpa,
            .io = io,
            .frame = .init(gpa),
            .events = events,
            .cfg = opts.cfg,
            .loaded = opts.loaded,
            .input_style = style,
            .workspace = ws,
            .data_root = dr,
            .panes = PaneStore.init(gpa),
            .layouts = layouts,
            .tree = tree_mod.Tree.init(gpa),
            .todos = todos.State.init(gpa),
            .screen = screen,
            .clipboard = Clipboard.init(gpa),
            .keymap = km,
            .dyn_commands = .init(gpa),
            .hooks = hooks.Hooks.init(gpa),
        };
        errdefer app.hooks.deinit();
        opts.loaded = null; // owned by `app` from here
        // D10.2: the first Zig hook subscriber — a save rescans the TODOs.
        try app.hooks.subscribe(.save_post, .{ .zig = &todos.onSavePost });
        app.now_ms = nowMs(io);
        app.tree.width = app.cfg.ui.tree_width;
        try app.toastConfigDiagnostics();
        try app.applyTheme();
        try trust_app.promptIfNeeded(&app);
        return app;
    }

    /// Load the three layers again with `trust` and switch to the result:
    /// the keymap, the input style, the tree width and the theme follow.
    /// The old `Loaded` is retired after `cfg` has stopped borrowing it.
    pub fn reloadConfig(self: *App, trust: config.Trust) Allocator.Error!void {
        const old = &(self.loaded orelse return);
        var fresh = try old.reload(self.gpa, self.io, trust);
        errdefer fresh.deinit();
        var km = try buildKeymap(self.gpa, styleOf(fresh.config.editor.input_style), fresh.config.keys);
        errdefer km.deinit();
        self.cfg = fresh.config;
        old.deinit();
        self.loaded = fresh;
        self.keymap.deinit();
        self.keymap = km;
        self.chord.clear(self.gpa);
        const style = styleOf(self.cfg.editor.input_style);
        if (style != self.input_style) try self.setInputStyle(style);
        self.tree.width = self.cfg.ui.tree_width;
        try self.toastConfigDiagnostics();
        try self.applyTheme();
        self.needs_render = true;
    }

    /// `ui.theme` → `theme`. An unknown name keeps what is painted and
    /// says so — a typo in the config must never blank the screen.
    pub fn applyTheme(self: *App) Allocator.Error!void {
        if (theme_mod.byName(self.cfg.ui.theme)) |t| {
            self.setTheme(t);
        } else {
            try self.toastLevel(.warn, "config: ui.theme \"{s}\" is not a bundled theme; keeping {s}", .{ self.cfg.ui.theme, self.theme.name });
        }
    }

    /// Paint with `t` from the next frame; every editor re-highlights in
    /// its colours.
    pub fn setTheme(self: *App, t: *const theme_mod) void {
        self.theme = t.*;
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*e| e.hl_dirty = true,
        };
        self.needs_render = true;
    }

    /// What the loader could not use, one warning toast each.
    fn toastConfigDiagnostics(self: *App) Allocator.Error!void {
        const l = self.loaded orelse return;
        for (l.diagnostics.items.items) |d| try self.toastLevel(.warn, "config: {f}", .{d});
    }

    /// The input layer's scalar config, read off `cfg.editor`.
    pub fn editorConfig(self: *const App) input.Config {
        return .{ .tab_width = self.cfg.editor.tab_width, .text_width = self.cfg.editor.text_width };
    }

    /// `[keys.global]` + `[keys.<profile>]` over the profile's defaults.
    fn buildKeymap(gpa: Allocator, style: input.Style, keys: Config.Keys) Allocator.Error!keymap.Keymap {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        return keymap.Keymap.build(gpa, profileOf(style), .{
            .global = try bindings(a, keys.global),
            .vim = try bindings(a, keys.vim),
            .standard = try bindings(a, keys.standard),
        });
    }

    fn bindings(a: Allocator, m: config.Map([]const u8)) Allocator.Error![]keymap.Binding {
        const out = try a.alloc(keymap.Binding, m.count());
        for (m.keys(), m.values(), 0..) |k, v, i| out[i] = .{ .spec = k, .command = v };
        return out;
    }

    pub fn deinit(self: *App) void {
        const gpa = self.gpa;
        // Workers first: they borrow `workspace` and post into `events`.
        self.todos.deinit(gpa, self.io);
        self.overlay.deinit(gpa);
        if (self.find_bar) |*fb| {
            fb.state.deinit(gpa);
            if (fb.snapshot) |*s| s.deinit();
        }
        for (self.toasts.items) |t| freeToast(gpa, t);
        self.toasts.deinit(gpa);
        for (self.closed.items) |c| gpa.free(c.path);
        self.closed.deinit(gpa);
        var it = self.abbrevs.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.*);
        }
        self.abbrevs.deinit(gpa);
        for (self.plugin_invocations.items) |p| gpa.free(p);
        self.plugin_invocations.deinit(gpa);
        if (self.cmd_complete) |*c| c.deinit(gpa);
        self.chord.clear(gpa);
        self.hooks.deinit();
        self.dyn_commands.deinit();
        self.keymap.deinit();
        self.clipboard.deinit();
        self.layouts.deinit();
        self.tree.deinit();
        self.panes.deinit();
        self.screen.deinit(gpa);
        self.events.deinit(self.io);
        self.frame.deinit();
        gpa.free(self.data_root);
        gpa.free(self.workspace);
        // Last: `cfg` borrowed from it until here.
        if (self.loaded) |*l| l.deinit();
    }

    pub fn profileOf(style: input.Style) keymap.Profile {
        return switch (style) {
            .vim => .vim,
            .standard => .standard,
        };
    }

    /// The config's enum → the input layer's. Same tags, two modules
    /// that must not import each other.
    pub fn styleOf(s: Config.InputStyle) input.Style {
        return switch (s) {
            .vim => .vim,
            .standard => .standard,
        };
    }

    pub fn configStyleOf(s: input.Style) Config.InputStyle {
        return switch (s) {
            .vim => .vim,
            .standard => .standard,
        };
    }

    pub fn nowMs(io: Io) i64 {
        return Io.Timestamp.now(io, .awake).toMilliseconds();
    }

    // ─── toasts ───

    fn freeToast(gpa: Allocator, t: Toast) void {
        gpa.free(t.text);
        if (t.id) |id| gpa.free(id);
    }

    /// Queue a toast. Formatting failure drops the toast rather than the frame.
    pub fn toast(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.toastLevel(.info, fmt, args) catch {};
    }

    pub fn toastLevel(self: *App, level: ToastLevel, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const s = try std.fmt.allocPrint(self.gpa, fmt, args);
        errdefer self.gpa.free(s);
        if (self.toasts.items.len >= max_toasts) freeToast(self.gpa, self.toasts.orderedRemove(0));
        try self.toasts.append(self.gpa, .{ .text = s, .level = level, .expires_ms = self.now_ms + toast_ttl_ms });
        self.needs_render = true;
    }

    /// A toast that stays until `dismissToast(id)`; a repeat with the
    /// same id replaces the text.
    pub fn toastPersistent(self: *App, id: []const u8, text: []const u8, level: ToastLevel) Allocator.Error!void {
        self.dismissToast(id);
        const s = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(s);
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);
        if (self.toasts.items.len >= max_toasts) freeToast(self.gpa, self.toasts.orderedRemove(0));
        try self.toasts.append(self.gpa, .{ .text = s, .level = level, .expires_ms = std.math.maxInt(i64), .id = owned_id });
        self.needs_render = true;
    }

    pub fn dismissToast(self: *App, id: []const u8) void {
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            const t = self.toasts.items[i];
            if (t.id != null and std.mem.eql(u8, t.id.?, id)) {
                freeToast(self.gpa, self.toasts.orderedRemove(i));
                self.needs_render = true;
            } else i += 1;
        }
    }

    pub fn lastToast(self: *const App) ?[]const u8 {
        return if (self.toasts.getLastOrNull()) |t| t.text else null;
    }

    /// Drop every toast — `Esc` in normal mode does this.
    pub fn dismissToasts(self: *App) void {
        for (self.toasts.items) |t| freeToast(self.gpa, t);
        self.toasts.clearRetainingCapacity();
    }

    // ─── the ex bridge the dyn registry uses ───

    pub fn runEx(self: *App, line: []const u8) command.CommandError!void {
        return ex.run(self, line);
    }

    /// An IPC-registered command was invoked: the host learns about it
    /// through events.jsonl (`pluginInvocations`).
    pub fn ackPluginCommand(self: *App, id: []const u8) command.CommandError!void {
        const copy = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(copy);
        try self.plugin_invocations.append(self.gpa, copy);
    }

    // ─── panes ───

    pub fn activeEditor(self: *App) ?*EditorPane {
        const id = self.active orelse return null;
        return self.panes.editor(id);
    }

    pub fn activeBuffer(self: *App) ?*Buffer {
        const e = self.activeEditor() orelse return null;
        return &e.buf;
    }

    /// The editor pane, or the `NoActivePane` / `NotAnEditor` a command reports.
    pub fn requireEditor(self: *App) command.CommandError!*EditorPane {
        const id = self.active orelse return error.NoActivePane;
        return self.panes.editor(id) orelse error.NotAnEditor;
    }

    /// Open `path` (absolute) in an editor pane and focus it. An already
    /// open file is revealed instead. A missing file is a new buffer.
    pub fn openPath(self: *App, path: []const u8) !PaneId {
        if (self.panes.findPath(path)) |id| {
            self.showPane(id);
            return id;
        }
        const gpa = self.gpa;
        const ecfg = self.editorConfig();
        var buf = Buffer.load(gpa, self.io, path, self.input_style, ecfg) catch |err| switch (err) {
            error.FileNotFound => blk: {
                var b = try Buffer.init(gpa, "", self.input_style, ecfg);
                errdefer b.deinit();
                try b.setPath(path);
                break :blk b;
            },
            else => return err,
        };
        errdefer buf.deinit();
        // A file closed earlier reopens where the cursor was.
        var i: usize = self.closed.items.len;
        while (i > 0) {
            i -= 1;
            const c = self.closed.items[i];
            if (std.mem.eql(u8, c.path, path)) {
                buf.editor.setCursor(@min(c.cursor, buf.editor.len()));
                gpa.free(c.path);
                _ = self.closed.orderedRemove(i);
                break;
            }
        }
        var syn = syntax.Syntax.init(gpa);
        errdefer syn.deinit();
        syn.setLanguage(path);
        const id = try self.panes.add(.{ .editor = .{ .buf = buf, .find = FindState.init(gpa), .syntax = syn } });
        // Moved into the store: the errdefers above must not run from here.
        self.showPane(id);
        self.hooks.emit(self, .{ .open = .{ .path = self.relPath(path), .pane = id } });
        return id;
    }

    /// A fresh unnamed buffer, shown and focused.
    pub fn openScratch(self: *App) !PaneId {
        const gpa = self.gpa;
        var buf = try Buffer.init(gpa, "", self.input_style, self.editorConfig());
        errdefer buf.deinit();
        const id = try self.panes.add(.{ .editor = .{ .buf = buf, .find = FindState.init(gpa), .syntax = syntax.Syntax.init(gpa) } });
        self.showPane(id);
        return id;
    }

    /// Reveal `id` in the focused leaf (or a new one) and focus it.
    pub fn showPane(self: *App, id: PaneId) void {
        const layout = self.layouts.current();
        const where: ?layout_mod.NodeId = if (self.active) |a| layout.leafOf(a) else null;
        _ = layout.showIn(where, id) catch {};
        self.setActive(id);
    }

    pub fn setActive(self: *App, id: ?PaneId) void {
        if (self.active != id) {
            if (self.activeBuffer()) |b| b.input.onBlur();
            self.change_nav = null;
        }
        self.active = id;
        self.focus = if (id != null) .{ .pane = id.? } else .tree;
        self.needs_render = true;
        self.hooks.emit(self, .{ .pane_focus = .{ .pane = id } });
    }

    /// Close `id`. A dirty editor gets the Save / Discard / Cancel box
    /// instead; `force` skips it (discarding).
    pub fn closePane(self: *App, id: PaneId, force: bool) Allocator.Error!void {
        const pane = self.panes.get(id) orelse return;
        if (!force and pane.dirty()) {
            const msg = try std.fmt.allocPrint(self.gpa, "  {s} has unsaved changes.", .{pane.title()});
            errdefer self.gpa.free(msg);
            self.overlay.deinit(self.gpa);
            self.overlay = .{ .confirm = .{
                .state = .{ .title = "Unsaved changes", .message = msg, .choices = &close_choices },
                .purpose = .{ .close_pane = id },
                .message = msg,
            } };
            self.focus = .overlay;
            return;
        }
        if (force and pane.dirty()) self.toast("discarded unsaved changes", .{});
        try self.forceClosePane(id);
    }

    pub const close_choices = [_]Confirm.Choice{ .{ .key = 's', .label = "Save" }, .{ .key = 'd', .label = "Discard" }, .{ .key = 'c', .label = "Cancel" } };

    pub fn forceClosePane(self: *App, id: PaneId) Allocator.Error!void {
        const pane = self.panes.get(id) orelse return;
        if (pane.asEditor()) |e| if (e.buf.path) |p| {
            const copy = try self.gpa.dupe(u8, p);
            errdefer self.gpa.free(copy);
            if (self.closed.items.len >= max_closed) self.gpa.free(self.closed.orderedRemove(0).path);
            try self.closed.append(self.gpa, .{ .path = copy, .cursor = e.buf.editor.cursor });
        };
        if (self.find_bar) |*fb| if (fb.pane == id) self.closeFindBar(false);
        if (self.block_insert) |b| if (b.pane == id) {
            self.block_insert = null;
        };
        if (self.repeat_insert) |r| if (r.pane == id) {
            self.repeat_insert = null;
        };
        const layout = self.layouts.current();
        const next = layout.removePane(id);
        self.panes.remove(id);
        if (self.active == id) {
            const fallback: ?PaneId = next orelse if (layout.firstLeaf()) |l| layout.leaf(l).?.active else null;
            self.active = null;
            self.setActive(fallback);
        }
        self.needs_render = true;
    }

    /// Switch every buffer and the keymap to `style`.
    pub fn setInputStyle(self: *App, style: input.Style) Allocator.Error!void {
        self.input_style = style;
        self.cfg.editor.input_style = configStyleOf(style);
        var km = try buildKeymap(self.gpa, style, self.cfg.keys);
        self.keymap.deinit();
        self.keymap = km;
        km = undefined;
        self.chord.clear(self.gpa);
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
            .editor => |*e| e.buf.setInputStyle(style, self.editorConfig()),
        };
        self.needs_render = true;
    }

    /// Workspace-relative when inside it, else the path itself.
    pub fn relPath(self: *const App, path: []const u8) []const u8 {
        if (std.mem.startsWith(u8, path, self.workspace) and path.len > self.workspace.len and path[self.workspace.len] == '/') {
            return path[self.workspace.len + 1 ..];
        }
        return path;
    }

    /// `<workspace>/<rel>` on the frame arena; absolute input passes through.
    pub fn absPath(self: *App, rel: []const u8) Allocator.Error![]const u8 {
        if (std.fs.path.isAbsolute(rel)) return rel;
        return std.fs.path.join(self.frame.allocator(), &.{ self.workspace, rel });
    }

    // ─── text mutation helpers every subsystem goes through ───

    /// Run editor ops on `pane`. Returns whether the text changed. An op
    /// the editor refuses is toasted by name.
    pub fn applyOps(self: *App, pane: *EditorPane, ops: []const edit_op.EditOp) Allocator.Error!bool {
        const changed = try pane.buf.applyOps(ops, &self.clipboard, self.pane_rows, self.frame.allocator());
        if (pane.buf.last_unsupported) |name| {
            self.toast("{s}: not supported yet", .{name});
            pane.buf.last_unsupported = null;
        }
        if (changed) {
            pane.hl_dirty = true;
            self.needs_render = true;
        }
        return changed;
    }

    /// Replace `[start, end)` with `text` as one undo step, cursor after it.
    pub fn splice(self: *App, pane: *EditorPane, start: usize, end: usize, text: []const u8) Allocator.Error!void {
        _ = try self.applyOps(pane, &.{.{ .replace_range = .{ .start = start, .end = end, .text = text } }});
    }

    /// Close the find bar; `restore` puts the pre-open find state back.
    pub fn closeFindBar(self: *App, restore: bool) void {
        const fb = &(self.find_bar orelse return);
        if (fb.snapshot) |*snap| {
            if (restore) {
                if (self.panes.editor(fb.pane)) |e| {
                    e.find.deinit();
                    e.find = snap.*;
                    e.buf.editor.setCursor(@min(fb.snapshot_cursor, e.buf.editor.len()));
                    snap.* = undefined;
                    fb.snapshot = null;
                }
            }
            if (fb.snapshot) |*s| s.deinit();
        }
        fb.state.deinit(self.gpa);
        self.find_bar = null;
        if (self.focus == .overlay) self.focus = if (self.active) |a| .{ .pane = a } else .tree;
        self.needs_render = true;
    }

    /// Any pane with unsaved changes?
    pub fn anyDirty(self: *App) bool {
        for (self.panes.slots.items) |*slot| if (slot.*) |*p| if (p.dirty()) return true;
        return false;
    }

    // ─── overlays every subsystem can open ───

    /// Open a context menu. Takes ownership of `items` (gpa); the labels
    /// must be literals or otherwise outlive the menu.
    pub fn openMenu(self: *App, title: []const u8, items: []command.MenuItem, x: u16, y: u16) Allocator.Error!void {
        self.overlay.deinit(self.gpa);
        const back: FocusId = if (self.focus == .overlay) (if (self.active) |a| .{ .pane = a } else .tree) else self.focus;
        self.overlay = .{ .menu = .{ .title = title, .items = items, .x = x, .y = y, .return_focus = back } };
        self.focus = .overlay;
        self.needs_render = true;
    }

    // ─── the loop's three entry points ───

    pub fn handle(self: *App, ev: AppEvent) Allocator.Error!void {
        switch (ev) {
            .key => |k| try dispatch.key(self, k),
            .mouse => |m| try dispatch.mouse(self, m),
            .winsize => |ws| try self.resize(ws.cols, ws.rows),
            .paste => |text| {
                defer self.gpa.free(text);
                try dispatch.paste(self, text);
            },
            .focus => {},
            // D1: the payload is the handler's to adopt or free.
            .todos => |result| try todos.handle(self, result),
            .err => |e| {
                defer self.gpa.free(e.msg);
                if (e.source == .todos) self.todos.scanning = false;
                try self.toastLevel(.err, "{s}: {s}", .{ @tagName(e.source), e.msg });
            },
            .timer => {},
            else => event.freeEvent(self.gpa, ev),
        }
        self.needs_render = true;
    }

    /// Drain the inbound queue without blocking. The terminal loop does
    /// this itself before `tick`; the headless / `.test` drivers reach it
    /// through `tick`, so a worker's result lands there too.
    /// // changed: D3 has the runner call `pumpEvents` beside `tick`;
    /// `tick` calls it instead so the `e2e.Driver` vtable stays as is.
    pub fn pumpEvents(self: *App) Allocator.Error!void {
        var buf: [64]AppEvent = undefined;
        while (true) {
            const n = self.events.drain(self.io, &buf);
            if (n == 0) break;
            for (buf[0..n]) |ev| try self.handle(ev);
        }
    }

    pub fn resize(self: *App, cols: u16, rows: u16) Allocator.Error!void {
        if (self.screen.width == cols and self.screen.height == rows) return;
        var fresh = try vaxis.Screen.init(self.gpa, .{ .cols = cols, .rows = rows, .x_pixel = 0, .y_pixel = 0 });
        fresh.width_method = .unicode;
        self.screen.deinit(self.gpa);
        self.screen = fresh;
        self.needs_render = true;
    }

    /// Timers: the chord chain, toast expiry, the deferred replays.
    pub fn tick(self: *App, now: i64) Allocator.Error!void {
        self.now_ms = now;
        try self.pumpEvents();
        if (self.chord.deadline_ms) |d| if (now >= d) try dispatch.expireChords(self);
        var i: usize = 0;
        while (i < self.toasts.items.len) {
            const t = self.toasts.items[i];
            if (t.id == null and now >= t.expires_ms) {
                freeToast(self.gpa, self.toasts.orderedRemove(i));
                self.needs_render = true;
            } else i += 1;
        }
        try dispatch.finishDeferredInserts(self);
        if (self.theme_auto_poll_ms) |at| if (now >= at) try @import("app/cmd_view.zig").pollSystemTheme(self);
    }

    /// The next moment `tick` has something to do, or null when idle.
    pub fn nextDeadlineMs(self: *const App) ?i64 {
        var next: ?i64 = self.chord.deadline_ms;
        if (self.theme_auto_poll_ms) |at| next = @min(next orelse std.math.maxInt(i64), at);
        // A spinner is animating: keep frames coming.
        if (self.todos.scanning) next = @min(next orelse std.math.maxInt(i64), self.now_ms + 80);
        for (self.toasts.items) |t| {
            if (t.id != null) continue;
            if (next == null or t.expires_ms < next.?) next = t.expires_ms;
        }
        return next;
    }

    /// One frame into the app's own screen (the headless / `.test` path).
    pub fn render(self: *App) Allocator.Error!void {
        try self.renderInto(&self.screen);
    }

    /// One frame into any screen (the terminal loop paints into the
    /// terminal's).
    pub fn renderInto(self: *App, screen: *vaxis.Screen) Allocator.Error!void {
        try render_mod.render(self, screen);
        self.needs_render = false;
    }

    /// The rendered-toast view for the toast component.
    pub fn visibleToasts(self: *App, arena: Allocator) Allocator.Error![]toast_mod.Toast {
        var out: std.ArrayListUnmanaged(toast_mod.Toast) = .empty;
        // toast.draw wants the newest first: index 0 lands nearest the
        // statusline and the oldest is what folds into "+K more…".
        var i = self.toasts.items.len;
        while (i > 0) : (i -= 1) try out.append(arena, .{ .text = self.toasts.items[i - 1].text, .level = switch (self.toasts.items[i - 1].level) {
            .info => .info,
            .warn => .warn,
            .err => .err,
        } });
        return out.items;
    }
};

test {
    _ = @import("app/trust.zig");
    _ = @import("app/settings.zig");
    _ = @import("app/pane.zig");
    _ = @import("app/layout.zig");
    _ = @import("app/find.zig");
    _ = @import("app/syntax.zig");
    _ = @import("app/whichkey.zig");
    _ = @import("app/tree.zig");
    _ = @import("app/ex.zig");
    _ = @import("app/dispatch.zig");
    _ = @import("app/render.zig");
    _ = @import("app/cmd_file.zig");
    _ = @import("app/cmd_buffer.zig");
    _ = @import("app/cmd_editor.zig");
    _ = @import("app/cmd_find.zig");
    _ = @import("app/cmd_view.zig");
    _ = @import("app/cmd_picker.zig");
    _ = @import("app/cmd_app.zig");
    _ = @import("todos.zig");
    _ = @import("ui/hit.zig");
    _ = @import("ui/prompt.zig");
    _ = @import("ui/confirm.zig");
    _ = @import("ui/find_bar.zig");
    _ = @import("ui/picker.zig");
    _ = @import("ui/fuzzy.zig");
    _ = @import("ui/editor_view.zig");
}

test "run: an unimplemented command toasts and fails; a bad name toasts" {
    var app = try App.initWith(std.testing.allocator, std.testing.io, .{ .workspace = "/tmp", .cols = 40, .rows = 10 });
    defer app.deinit();
    try std.testing.expectError(error.Failed, command.run(&app, .{ .static = .@"ai.ask" }));
    try std.testing.expectEqualStrings("ai.ask: not implemented yet", app.lastToast().?);
    try std.testing.expectError(error.Failed, command.runNamed(&app, "nope.nope"));
    try std.testing.expectEqualStrings("no such command: nope.nope", app.lastToast().?);
    // A dyn command with an ex runner reaches the interpreter.
    _ = try app.dyn_commands.register(.{ .id = "user.hi", .runner = .{ .ex = "frobnicate" }, .owner = .script });
    try std.testing.expectError(error.Failed, command.runNamed(&app, "user.hi"));
    try std.testing.expectEqualStrings(":frobnicate — unknown command", app.lastToast().?);
    // An IPC runner is acknowledged through pluginInvocations.
    _ = try app.dyn_commands.register(.{ .id = "p.a", .runner = .ipc, .owner = .ipc });
    try command.runNamed(&app, "p.a");
    try std.testing.expectEqualStrings("p.a", app.plugin_invocations.items[0]);
}

test "config → App: every behaviour-changing field flipped once" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: Config = .{};
    c.editor.input_style = .vim;
    c.editor.tab_width = 2;
    c.editor.text_width = 40;
    c.editor.chord_timeout_ms = 900;
    c.ui.wrap = true;
    c.ui.line_numbers = false;
    c.ui.ascii_icons = true;
    c.ui.tree_width = 17;
    c.ui.theme = "Gruvbox";
    try c.keys.global.put(arena, "ctrl+shift+x", "view.about");
    try c.keys.vim.put(arena, "ctrl+q", "none");
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = c, .workspace = "/tmp", .cols = 60, .rows = 12 });
    defer app.deinit();

    // input_style: the buffers and the keymap follow the config's enum
    try t.expectEqual(input.Style.vim, app.input_style);
    _ = try app.openScratch();
    try t.expectEqual(input.Style.vim, app.activeBuffer().?.input.style());
    try t.expectEqualStrings("NORMAL", app.activeBuffer().?.input.mode().label().?);
    // tab_width / text_width reach the editor
    try t.expectEqual(@as(usize, 2), app.activeBuffer().?.editor.tab_width);
    try t.expectEqual(@as(usize, 40), app.editorConfig().text_width);
    // chord timeout is the deadline the chain waits for
    try t.expectEqual(@as(u16, 900), app.cfg.editor.chord_timeout_ms);
    // tree width, theme
    try t.expectEqual(@as(u16, 17), app.tree.width);
    try t.expectEqualStrings("gruvbox", app.theme.name);
    try t.expectEqual(@as(usize, 0), app.toasts.items.len);
    // keys: global adds, the profile layer removes
    var buf: [keymap.max_seq]key_mod.Chord = undefined;
    try t.expectEqual(command.CommandId.@"view.about", app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+shift+x", &buf).?).run.static);
    try t.expect(app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+q", &buf).?) == .none);
    // wrap / line numbers / ascii reach the frame: no gutter digits, the
    // ascii divider, and a long line that wraps instead of clipping
    app.tree.visible = true;
    try app.activeEditor().?.buf.editor.setText("0123456789 0123456789 0123456789 0123456789 0123456789");
    try app.render();
    const txt = try @import("ipc/screen.zig").toTestText(t.allocator, &app.screen);
    defer t.allocator.free(txt);
    try t.expect(std.mem.indexOf(u8, txt, "|") != null);
    try t.expect(std.mem.indexOf(u8, txt, "│") == null);
    try t.expect(std.mem.indexOf(u8, txt, " 1 0123") == null);
    try t.expectEqual(@as(usize, 0), app.cfg.ui.tree_width - app.tree.width);
    try t.expect(std.mem.count(u8, txt, "0123456789") >= 2);

    // switching the style keeps cfg and the input layer level, and the
    // config's key layers survive the rebuild
    try app.setInputStyle(.standard);
    try t.expectEqual(Config.InputStyle.standard, app.cfg.editor.input_style);
    try t.expectEqual(command.CommandId.@"view.about", app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+shift+x", &buf).?).run.static);
    try t.expectEqual(command.CommandId.@"app.quit", app.keymap.resolveSeq(keymap.parseKeySeqBuf("ctrl+q", &buf).?).run.static);
}

test "config → App: an unknown theme keeps the default and warns; loader diagnostics become toasts" {
    const t = std.testing;
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.createDirPath(t.io, ".mnml");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".mnml/config.zon", .data = ".{ .ui = .{ .theme = \"no-such\" }, .bogus = 1 }" });
    var loaded = try config.load.load(t.allocator, t.io, .{ .workspace = root, .env = .{ .vars = &vars } });
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = root, .cols = 60, .rows = 12 });
    loaded = undefined; // the app owns it now
    defer app.deinit();
    try t.expectEqualStrings("onedark", app.theme.name);
    try t.expectEqual(@as(usize, 2), app.toasts.items.len);
    try t.expect(std.mem.indexOf(u8, app.toasts.items[0].text, "unknown section 'bogus'") != null);
    try t.expect(std.mem.indexOf(u8, app.toasts.items[1].text, "no-such") != null);
    try t.expect(app.toasts.items[1].level == .warn);
}

test "persistent toasts survive tick; dismiss removes by id" {
    var app = try App.init(std.testing.allocator, std.testing.io);
    defer app.deinit();
    app.toast("gone soon", .{});
    try app.toastPersistent("ex:reg", "stays", .info);
    try app.tick(app.now_ms + 10_000);
    try std.testing.expectEqual(@as(usize, 1), app.toasts.items.len);
    try std.testing.expectEqualStrings("stays", app.lastToast().?);
    app.dismissToast("ex:reg");
    try std.testing.expectEqual(@as(usize, 0), app.toasts.items.len);
}
