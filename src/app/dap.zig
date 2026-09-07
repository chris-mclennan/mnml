//! Debugging (DAP) on the app side: the breakpoints and watches mnml
//! keeps across sessions, the one live `Session` (`dap/client.zig`), the
//! handshake it drives (`initialize` → `initialized` → breakpoints,
//! exception filters, `launch`, `configurationDone`), what a `stopped`
//! event sets in motion (threads, the stack, scopes, variables, the
//! watches, the ▶ mark in the gutter), and the two panes — `Pane.debug`
//! (call stack, variables, output) and `Pane.dap_repl` (evaluate).
//!
//! Everything here works without an adapter: breakpoints toggle, the
//! REPL keeps its history (an entry lands as "no DAP session"), watches
//! list with "(no value)". The gate exercises exactly that.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const editor_view = @import("../ui/editor_view.zig");
const text_field = @import("../ui/text_field.zig");
const fuzzy = @import("../ui/fuzzy.zig");
const dap_view = @import("../ui/dap_view.zig");
const repl_view = @import("../ui/dap_repl_view.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const client = @import("../dap/client.zig");
const types = @import("../dap/types.zig");
const syntax = @import("syntax.zig");
const layout_mod = @import("layout.zig");
const cmd_picker = @import("cmd_picker.zig");
const config = @import("../config/root.zig");
const build_options = @import("build_options");

pub const Session = client.Session;
pub const Breakpoint = types.Breakpoint;

/// Where execution stopped: the ▶ in the gutter. Owned path, 0-based line.
pub const Arrow = struct { path: []u8, line: u32 };

/// `Pane.debug`: cursors only — the data is the session's.
pub const DebugPane = struct {
    section: dap_view.Section = .stack,
    stack_cursor: usize = 0,
    vars_cursor: usize = 0,
    scrolls: dap_view.Scrolls = .{},
};

/// `Pane.dap_repl`: the input line, the history, the filter.
pub const DapReplPane = struct {
    gpa: Allocator,
    input: text_field.Buf = .empty,
    caret: usize = 0,
    history: std.ArrayListUnmanaged(types.ReplEntry) = .empty,
    /// What was submitted, for ↑/↓ — failed evaluations included, as a
    /// typo is what one most wants back.
    commands: std.ArrayListUnmanaged([]u8) = .empty,
    cmd_idx: ?usize = null,
    /// Index into the visible entries, or `repl_view.scroll_tail`.
    scroll: usize = repl_view.scroll_tail,
    /// The history entry `o` and Esc act on; null = the input has focus.
    selected: ?usize = null,
    filter: text_field.Buf = .empty,
    filter_mode: bool = false,

    pub fn deinit(self: *DapReplPane) void {
        self.input.deinit(self.gpa);
        for (self.history.items) |*e| e.deinit(self.gpa);
        self.history.deinit(self.gpa);
        for (self.commands.items) |c| self.gpa.free(c);
        self.commands.deinit(self.gpa);
        self.filter.deinit(self.gpa);
    }

    /// History indices whose expression fuzzy-matches the filter; every
    /// index when the filter is empty. Frame arena.
    pub fn visible(self: *const DapReplPane, arena: Allocator) Allocator.Error![]usize {
        var out: std.ArrayListUnmanaged(usize) = .empty;
        for (self.history.items, 0..) |e, i| {
            if (self.filter.items.len == 0 or fuzzy.score(self.filter.items, e.expression) != null) try out.append(arena, i);
        }
        return out.items;
    }
};

pub const State = struct {
    /// Per absolute path (owned keys), sorted by line.
    breakpoints: std.StringHashMapUnmanaged(types.FileBreakpoints) = .empty,
    /// Owned expressions, in the order they were added.
    watches: std.ArrayListUnmanaged([]u8) = .empty,
    session: ?*Session = null,
    next_session: u32 = 1,
    arrow: ?Arrow = null,
    /// The config layers read again by `dap.run` when the active file
    /// had no adapter (an adapter added to `.mnml/config.zon` after
    /// launch); `app.cfg.dap` borrows from it from then on.
    adapters_loaded: ?config.Loaded = null,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.session) |s| s.deinit();
        self.session = null;
        if (self.adapters_loaded) |*l| l.deinit();
        var it = self.breakpoints.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            for (e.value_ptr.items) |*b| b.deinit(gpa);
            e.value_ptr.deinit(gpa);
        }
        self.breakpoints.deinit(gpa);
        for (self.watches.items) |w| gpa.free(w);
        self.watches.deinit(gpa);
        if (self.arrow) |a| gpa.free(a.path);
    }

    pub fn bpsFor(self: *const State, path: []const u8) []const Breakpoint {
        const list = self.breakpoints.get(path) orelse return &.{};
        return list.items;
    }

    pub fn hasWatch(self: *const State, expr: []const u8) bool {
        for (self.watches.items) |w| if (std.mem.eql(u8, w, expr)) return true;
        return false;
    }
};

// ─── breakpoints ────────────────────────────────────────────────────────

fn listFor(app: *App, path: []const u8) Allocator.Error!*types.FileBreakpoints {
    const gop = try app.dap.breakpoints.getOrPut(app.gpa, path);
    if (!gop.found_existing) {
        gop.key_ptr.* = app.gpa.dupe(u8, path) catch |err| {
            _ = app.dap.breakpoints.remove(path);
            return err;
        };
        gop.value_ptr.* = .empty;
    }
    return gop.value_ptr;
}

fn indexOfLine(list: *const types.FileBreakpoints, line: u32) ?usize {
    for (list.items, 0..) |b, i| if (b.line == line) return i;
    return null;
}

fn sortByLine(list: *types.FileBreakpoints) void {
    std.mem.sort(Breakpoint, list.items, {}, struct {
        fn lt(_: void, a: Breakpoint, b: Breakpoint) bool {
            return a.line < b.line;
        }
    }.lt);
}

/// The editor + its path, or the reasons the Rust toasts.
fn editorWithPath(app: *App) CommandError!struct { e: *EditorPane, path: []const u8 } {
    const e = app.activeEditor() orelse return app.diag.fail(app.frame.allocator(), "no active editor", .{});
    const path = e.buf.doc.path orelse return app.diag.fail(app.frame.allocator(), "buffer has no path", .{});
    return .{ .e = e, .path = path };
}

/// Flip the breakpoint on the cursor line. Returns whether one was set.
pub fn toggleBreakpoint(app: *App) CommandError!void {
    const ep = try editorWithPath(app);
    const line: u32 = @intCast(ep.e.buf.editor.currentLine());
    const list = try listFor(app, ep.path);
    if (indexOfLine(list, line)) |i| {
        var bp = list.orderedRemove(i);
        bp.deinit(app.gpa);
        app.toast("breakpoint cleared: line {d}", .{line + 1});
    } else {
        try list.append(app.gpa, .{ .line = line });
        sortByLine(list);
        app.toast("breakpoint set: line {d}", .{line + 1});
    }
    app.needs_render = true;
    syncBreakpoints(app, ep.path);
}

/// Push one file's list to a live, initialized adapter.
fn syncBreakpoints(app: *App, path: []const u8) void {
    const s = app.dap.session orelse return;
    if (!s.initialized) return;
    s.setBreakpoints(path, app.dap.bpsFor(path)) catch |err| app.toast("dap setBreakpoints: {s}", .{@errorName(err)});
}

/// Every file's list — the `initialized` step.
fn syncAllBreakpoints(app: *App) void {
    var it = app.dap.breakpoints.iterator();
    while (it.next()) |e| if (e.value_ptr.items.len > 0) syncBreakpoints(app, e.key_ptr.*);
}

pub fn clearAllBreakpoints(app: *App) CommandError!void {
    const ep = try editorWithPath(app);
    const n: usize = if (app.dap.breakpoints.getPtr(ep.path)) |list| blk: {
        const n = list.items.len;
        for (list.items) |*b| b.deinit(app.gpa);
        list.clearRetainingCapacity();
        break :blk n;
    } else 0;
    app.toast("cleared {d} breakpoint{s}", .{ n, if (n == 1) "" else "s" });
    app.needs_render = true;
    syncBreakpoints(app, ep.path);
}

pub fn listBreakpoints(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = app.dap.breakpoints.iterator();
    while (it.next()) |e| if (e.value_ptr.items.len > 0) try paths.append(arena, e.key_ptr.*);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var total: usize = 0;
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    for (paths.items, 0..) |p, i| {
        const list = app.dap.bpsFor(p);
        total += list.len;
        if (i > 0) try parts.appendSlice(arena, " · ");
        try parts.print(arena, "{s}: ", .{std.fs.path.basename(p)});
        for (list, 0..) |b, j| {
            if (j > 0) try parts.append(arena, ',');
            try parts.print(arena, "{d}", .{b.line + 1});
        }
    }
    if (total == 0) app.toast("no breakpoints set", .{}) else app.toast("{d} breakpoint(s) — {s}", .{ total, parts.items });
}

/// `dap.toggle_breakpoint_conditional`: a prompt seeded with the
/// line's condition; accept records it (empty = a plain breakpoint).
pub fn conditionPrompt(app: *App) CommandError!void {
    const ep = try editorWithPath(app);
    const line: u32 = @intCast(ep.e.buf.editor.currentLine());
    const seed: []const u8 = if (app.dap.breakpoints.get(ep.path)) |list| (if (indexOfLine(&list, line)) |i| list.items[i].condition orelse "" else "") else "";
    const title = try std.fmt.allocPrint(app.gpa, "Breakpoint condition (line {d})", .{line + 1});
    errdefer app.gpa.free(title);
    try openBpPrompt(app, title, seed, .{ .dap_bp_condition = .{ .path = try app.gpa.dupe(u8, ep.path), .line = line } });
}

/// `dap.set_breakpoint_hit_count`: the same for `hitCondition`.
pub fn hitCountPrompt(app: *App) CommandError!void {
    const ep = try editorWithPath(app);
    const line: u32 = @intCast(ep.e.buf.editor.currentLine());
    const seed: []const u8 = if (app.dap.breakpoints.get(ep.path)) |list| (if (indexOfLine(&list, line)) |i| list.items[i].hit_condition orelse "" else "") else "";
    const title = try std.fmt.allocPrint(app.gpa, "Hit-count condition (line {d})  e.g. >= 5  or  % 10", .{line + 1});
    errdefer app.gpa.free(title);
    try openBpPrompt(app, title, seed, .{ .dap_hit_count = .{ .path = try app.gpa.dupe(u8, ep.path), .line = line } });
}

fn openBpPrompt(app: *App, title_owned: []u8, seed: []const u8, purpose: app_mod.PromptPurpose) CommandError!void {
    var purpose_owned = purpose;
    errdefer purpose_owned.deinit(app.gpa);
    var state = app_mod.Prompt.init(app.gpa, title_owned);
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    try state.setText(app.gpa, seed);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = purpose_owned, .title_owned = title_owned } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// The condition prompt's accept. Empty clears the condition; the line
/// gains a breakpoint if it had none.
pub fn acceptCondition(app: *App, path: []const u8, line: u32, text_in: []const u8) Allocator.Error!void {
    const text = std.mem.trim(u8, text_in, " \t");
    const list = try listFor(app, path);
    const i = indexOfLine(list, line) orelse blk: {
        try list.append(app.gpa, .{ .line = line });
        sortByLine(list);
        break :blk indexOfLine(list, line).?;
    };
    const bp = &list.items[i];
    if (bp.condition) |c| app.gpa.free(c);
    bp.condition = if (text.len == 0) null else try app.gpa.dupe(u8, text);
    if (text.len == 0) app.toast("bp line {d}", .{line + 1}) else app.toast("bp line {d}: {s}", .{ line + 1, text });
    app.needs_render = true;
    syncBreakpoints(app, path);
}

pub fn acceptHitCount(app: *App, path: []const u8, line: u32, text_in: []const u8) Allocator.Error!void {
    const text = std.mem.trim(u8, text_in, " \t");
    const list = try listFor(app, path);
    const i = indexOfLine(list, line) orelse blk: {
        try list.append(app.gpa, .{ .line = line });
        sortByLine(list);
        break :blk indexOfLine(list, line).?;
    };
    const bp = &list.items[i];
    if (bp.hit_condition) |h| app.gpa.free(h);
    bp.hit_condition = if (text.len == 0) null else try app.gpa.dupe(u8, text);
    app.toast("bp line {d} hit-count {s}", .{ line + 1, if (text.len == 0) "cleared" else text });
    app.needs_render = true;
    syncBreakpoints(app, path);
}

/// The gutter marks for `path`: the ▶ of a stop wins over a
/// breakpoint's `●` (`◆` conditional, `◈` hit-count). Frame arena.
pub fn marksFor(app: *App, arena: Allocator, path: ?[]const u8, theme: *const Theme, ascii: bool) Allocator.Error![]editor_view.GutterMark {
    const p = path orelse return &.{};
    var out: std.ArrayListUnmanaged(editor_view.GutterMark) = .empty;
    for (app.dap.bpsFor(p)) |b| {
        const glyph: []const u8 = if (b.condition != null) (if (ascii) "#" else "◆") else if (b.hit_condition != null) (if (ascii) "@" else "◈") else (if (ascii) "*" else "●");
        try out.append(arena, .{ .line = b.line, .kind = .sign, .glyph = glyph, .style = theme.error_fg });
    }
    if (app.dap.arrow) |a| if (std.mem.eql(u8, a.path, p)) {
        // Replace the breakpoint's mark on that line rather than add.
        for (out.items) |*m| if (m.line == a.line) {
            m.* = .{ .line = a.line, .kind = .sign, .glyph = if (ascii) ">" else "▶", .style = theme.warn_fg };
            return out.items;
        };
        try out.append(arena, .{ .line = a.line, .kind = .sign, .glyph = if (ascii) ">" else "▶", .style = theme.warn_fg });
    };
    return out.items;
}

// ─── watches ────────────────────────────────────────────────────────────

pub fn addWatchPrompt(app: *App) CommandError!void {
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Watch expression"), .purpose = .dap_add_watch } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptWatch(app: *App, text_in: []const u8) Allocator.Error!void {
    const expr = std.mem.trim(u8, text_in, " \t");
    if (expr.len == 0) return;
    try addWatch(app, expr);
}

pub fn addWatch(app: *App, expr: []const u8) Allocator.Error!void {
    if (!app.dap.hasWatch(expr)) {
        const copy = try app.gpa.dupe(u8, expr);
        errdefer app.gpa.free(copy);
        try app.dap.watches.append(app.gpa, copy);
    }
    if (app.dap.session) |s| if (s.stopped != null) {
        _ = s.evaluate(expr, .watch) catch 0;
    };
    app.toast("watch: + {s}", .{expr});
    app.needs_render = true;
}

pub fn removeWatchPicker(app: *App) CommandError!void {
    const st = &app.dap;
    if (st.watches.items.len == 0) return app.diag.fail(app.frame.allocator(), "no watches to remove", .{});
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (st.watches.items) |w| {
        try labels.append(gpa, try gpa.dupe(u8, w));
        const value: []const u8 = if (st.session) |s| (if (s.watch_results.get(w)) |r| (if (r.err) |e| e else r.value) else "(no value yet)") else "(no value yet)";
        try details.append(gpa, try gpa.dupe(u8, value));
    }
    const hints = try gpa.alloc([]u8, 0);
    errdefer gpa.free(hints);
    try cmd_picker.openPickerWith(app, "Remove watch", .dap_remove_watch, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), hints);
}

fn removeWatch(app: *App, expr: []const u8) void {
    const st = &app.dap;
    var i: usize = 0;
    while (i < st.watches.items.len) {
        if (std.mem.eql(u8, st.watches.items[i], expr)) {
            app.gpa.free(st.watches.orderedRemove(i));
        } else i += 1;
    }
    if (st.session) |s| s.removeWatchResult(expr);
    app.toast("watch: − {s}", .{expr});
    app.needs_render = true;
}

pub fn clearWatches(app: *App) CommandError!void {
    const st = &app.dap;
    const n = st.watches.items.len;
    for (st.watches.items) |w| app.gpa.free(w);
    st.watches.clearRetainingCapacity();
    if (st.session) |s| s.clearWatchResults();
    app.toast("watches: cleared {d}", .{n});
    app.needs_render = true;
}

fn evaluateWatches(app: *App) void {
    const s = app.dap.session orelse return;
    for (app.dap.watches.items) |w| _ = s.evaluate(w, .watch) catch 0;
}

// ─── the session ────────────────────────────────────────────────────────

fn endSession(app: *App) void {
    if (app.dap.session) |s| s.deinit();
    app.dap.session = null;
    clearArrow(app);
    app.needs_render = true;
}

fn clearArrow(app: *App) void {
    if (app.dap.arrow) |a| app.gpa.free(a.path);
    app.dap.arrow = null;
}

/// The `.dap.<key>` adapter for a file: its extension first, then the
/// grammar key (`py` / `rust`…), so both spellings of a config work.
fn adapterFor(app: *App, path: []const u8) ?struct { name: []const u8, cfg: app_mod.Config.DapAdapter } {
    const ext_full = std.fs.path.extension(path);
    if (ext_full.len > 1) {
        var lower: [32]u8 = undefined;
        if (ext_full.len - 1 <= lower.len) {
            const ext = std.ascii.lowerString(&lower, ext_full[1..]);
            if (app.cfg.dap.get(ext)) |c| return .{ .name = ext, .cfg = c };
        }
    }
    if (syntax.keyForPath(path)) |k| if (app.cfg.dap.get(k)) |c| return .{ .name = k, .cfg = c };
    return null;
}

/// `dap.run`: spawn the adapter for the active file and start the
/// handshake. One session at a time — a live one is dropped first.
pub fn run(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const ep = try editorWithPath(app);
    const path = try arena.dupe(u8, ep.path);
    const ext = std.fs.path.extension(path);
    const found = adapterFor(app, path) orelse blk: {
        try refreshAdapters(app);
        break :blk adapterFor(app, path) orelse return app.diag.fail(arena, "dap: no .dap.{s} adapter in config", .{if (ext.len > 1) ext[1..] else "<ext>"});
    };
    if (found.cfg.cmd.len == 0) return app.diag.fail(arena, "dap: .dap.{s} has no cmd", .{found.name});
    return startSession(app, found.cfg, path, null);
}

/// No adapter matched: read the config layers again and take their
/// `.dap` table, so an adapter written to `.mnml/config.zon` after
/// launch is found without a restart. Exec-bearing, hence trusted
/// workspaces only; the data root is this App's, not the environment's.
fn refreshAdapters(app: *App) Allocator.Error!void {
    if (!app.workspace_trusted) return;
    var env = try app.env.clone(app.gpa);
    defer env.deinit();
    if (app.data_root.len > 0) try env.put("MNML_DATA_ROOT", app.data_root);
    var fresh = try config.load.load(app.gpa, app.io, .{ .workspace = app.workspace, .trust = .trusted, .env = .{ .vars = &env } });
    if (fresh.config.dap.count() == 0) {
        fresh.deinit();
        return;
    }
    if (app.dap.adapters_loaded) |*old| old.deinit();
    app.dap.adapters_loaded = fresh;
    app.cfg.dap = fresh.config.dap;
}

/// Spawn `cfg`'s adapter with its launch body (substituted), or a body
/// given verbatim (tests). Async from here: the reply drives the rest.
pub fn startSession(app: *App, cfg: app_mod.Config.DapAdapter, file: []const u8, body_override: ?[]const u8) CommandError!void {
    const arena = app.frame.allocator();
    endSession(app);
    // `$NAME` in the command or an argument comes from the environment
    // (`$MNML_FAKE_DAP` is how the corpus reaches the fake adapter).
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, try client.expandEnv(arena, cfg.cmd, &app.env));
    for (cfg.args) |a| try argv.append(arena, try client.expandEnv(arena, a, &app.env));
    const raw = body_override orelse blk: {
        if (cfg.launch.isEmpty()) break :blk "{\"program\":\"${file}\",\"cwd\":\"${workspaceFolder}\"}";
        var aw: std.Io.Writer.Allocating = .init(arena);
        var js: std.json.Stringify = .{ .writer = &aw.writer };
        cfg.launch.toJson(&js) catch return error.OutOfMemory;
        break :blk aw.written();
    };
    const body = try client.substitute(arena, raw, app.workspace, file);
    const id = app.dap.next_session;
    app.dap.next_session += 1;
    const s = Session.spawn(app.gpa, app.io, &app.events, id, argv.items, app.workspace, &app.env, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return app.diag.fail(arena, "dap spawn failed: {s} not found on PATH", .{cfg.cmd}),
        else => return app.diag.fail(arena, "dap spawn failed: {s}", .{@errorName(err)}),
    };
    app.dap.session = s;
    s.initialize() catch |err| {
        endSession(app);
        return app.diag.fail(arena, "dap init failed: {s}", .{@errorName(err)});
    };
    app.toast("dap: spawned {s} adapter", .{cfg.cmd});
}

fn requireStopped(app: *App) CommandError!*Session {
    const s = app.dap.session orelse return app.diag.fail(app.frame.allocator(), "no DAP session (run dap.run first)", .{});
    if (s.stopped == null) return app.diag.fail(app.frame.allocator(), "dap: not stopped", .{});
    return s;
}

/// The step / resume family: a thread-addressed request, failures toasted.
pub fn threadCommand(app: *App, kind: client.ReqKind, verb: []const u8) CommandError!void {
    const s = if (kind == .pause) (app.dap.session orelse return app.diag.fail(app.frame.allocator(), "no DAP session (run dap.run first)", .{})) else try requireStopped(app);
    s.threadRequest(kind, verb) catch |err| return app.diag.fail(app.frame.allocator(), "dap {s}: {s}", .{ verb, @errorName(err) });
}

pub fn terminate(app: *App) CommandError!void {
    const s = app.dap.session orelse return app.diag.fail(app.frame.allocator(), "no DAP session", .{});
    s.terminate() catch {};
    endSession(app);
    app.toast("dap: terminated", .{});
}

pub fn exceptionsPicker(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const s = app.dap.session orelse return app.diag.fail(arena, "dap: adapter advertised no exception filters", .{});
    if (s.filters.items.len == 0) return app.diag.fail(arena, "dap: adapter advertised no exception filters", .{});
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (s.filters.items) |f| {
        const on = s.enabled_filters.contains(f.filter);
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ if (on) "●" else "○", f.label }));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ f.filter, if (f.default) " · default-on" else "" }));
    }
    try cmd_picker.openPickerWith(app, "Toggle exception breakpoint", .dap_exceptions, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try gpa.alloc([]u8, 0));
}

pub fn threadPicker(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const s = app.dap.session orelse return app.diag.fail(arena, "dap: no threads (start a session first)", .{});
    if (s.threads.len == 0) return app.diag.fail(arena, "dap: no threads (start a session first)", .{});
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (s.threads) |t| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (s.thread == t.id) "● " else "  ", t.name }));
        try details.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{t.id}));
    }
    try cmd_picker.openPickerWith(app, "Switch thread", .dap_threads, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try gpa.alloc([]u8, 0));
}

/// A pick in one of the DAP pickers; `label` / `detail` are frame copies.
pub fn pickerAccept(app: *App, kind: app_mod.PickerKind, label: []const u8, detail: []const u8) Allocator.Error!void {
    switch (kind) {
        .dap_remove_watch => removeWatch(app, label),
        .dap_exceptions => {
            const s = app.dap.session orelse return;
            const id = if (std.mem.indexOf(u8, detail, " · ")) |i| detail[0..i] else detail;
            const on = try s.toggleFilter(id);
            s.setExceptionBreakpoints() catch |err| app.toast("dap setExceptionBreakpoints: {s}", .{@errorName(err)});
            app.toast("exception {s}: {s}", .{ id, if (on) "on" else "off" });
        },
        .dap_threads => {
            const s = app.dap.session orelse return;
            const id = std.fmt.parseInt(i64, detail, 10) catch return;
            s.thread = id;
            s.requestStackTrace(id) catch {};
            app.toast("dap: thread {d}", .{id});
        },
        else => {},
    }
}

// ─── events (D1: adopt or free, on every path) ──────────────────────────

pub fn handle(app: *App, session_id: u32, ev: *event.DapEvent) Allocator.Error!void {
    defer ev.destroy(app.gpa);
    const s = app.dap.session orelse return;
    if (s.id != session_id) return;
    switch (ev.*) {
        .closed => {
            if (!s.exited) app.toast("dap: adapter exited", .{});
            endSession(app);
        },
        .message => |msg| try handleMessage(app, s, msg.root()),
    }
    app.needs_render = true;
}

fn handleMessage(app: *App, s: *Session, v: jsonrpc.Value) Allocator.Error!void {
    switch (client.classify(v)) {
        .response => |r| {
            const pending = s.transport.take(r.request_seq) orelse return;
            const kind: client.ReqKind = @enumFromInt(pending.kind);
            try handleResponse(app, s, kind, pending.ctx, r.success, r.message, r.body);
        },
        .event => |e| try handleEvent(app, s, e.name, e.body),
        .request => |rq| s.respondFailure(rq.seq, rq.command, "mnml does not run adapter requests") catch {},
        .unknown => {},
    }
}

fn handleResponse(app: *App, s: *Session, kind: client.ReqKind, ctx: u64, success: bool, message: ?[]const u8, body: ?jsonrpc.Value) Allocator.Error!void {
    if (!success) {
        switch (kind) {
            .evaluate_repl, .evaluate_watch => {},
            .disconnect, .terminate, .cancel => return,
            else => app.toast("dap {s}: {s}", .{ @tagName(kind), message orelse "failed" }),
        }
    }
    switch (kind) {
        .initialize => try s.setCapabilities(body),
        .launch => if (success) {
            s.running = true;
        },
        .threads => try s.setThreads(body),
        .stack_trace => {
            try s.setFrames(body);
            if (s.frames.len > 0) {
                const top = s.frames[0];
                s.requestScopes(top.id) catch {};
                evaluateWatches(app);
                if (top.source) |src| try jumpTo(app, src, top.line -| 1);
            }
        },
        .scopes => {
            try s.setScopes(body);
            for (s.scopes) |sc| if (sc.variables_reference > 0 and !sc.expensive) {
                try s.expanded.put(app.gpa, sc.variables_reference, {});
                s.requestVariables(sc.variables_reference) catch {};
            };
        },
        .variables => try s.setVariables(@bitCast(ctx), body),
        .evaluate_repl => {
            const expr = s.takeEval(ctx) orelse return;
            defer app.gpa.free(expr);
            try replResult(app, expr, success, message, body);
        },
        .evaluate_watch => {
            const expr = s.takeEval(ctx) orelse return;
            defer app.gpa.free(expr);
            const value = if (body) |b| jsonrpc.getStr(b, "result") orelse "" else "";
            const ty = if (body) |b| jsonrpc.getStr(b, "type") else null;
            try s.setWatchResult(expr, value, ty, if (success) null else (message orelse "failed"));
        },
        .set_variable => if (success) {
            const value = if (body) |b| jsonrpc.getStr(b, "value") orelse "" else "";
            app.toast("set = {s}", .{value});
            const parent: i64 = @bitCast(ctx);
            if (parent != 0) s.requestVariables(parent) catch {};
            evaluateWatches(app);
        },
        else => {},
    }
}

fn handleEvent(app: *App, s: *Session, name: []const u8, body: ?jsonrpc.Value) Allocator.Error!void {
    if (std.mem.eql(u8, name, "initialized")) {
        s.initialized = true;
        syncAllBreakpoints(app);
        if (s.filters.items.len > 0) s.setExceptionBreakpoints() catch {};
        s.launch() catch |err| app.toast("dap launch: {s}", .{@errorName(err)});
        s.configurationDone() catch {};
    } else if (std.mem.eql(u8, name, "stopped")) {
        const b = body orelse return;
        const thread = jsonrpc.getInt(b, "threadId") orelse s.thread orelse 1;
        const reason = jsonrpc.getStr(b, "reason") orelse "stopped";
        try s.setStopped(thread, reason, jsonrpc.getStr(b, "description"));
        s.requestStackTrace(thread) catch {};
        s.requestThreads() catch {};
        app.toast("dap: stopped ({s})", .{s.stopped.?.label()});
    } else if (std.mem.eql(u8, name, "continued")) {
        s.onResumed();
        s.clearWatchResults();
        clearArrow(app);
    } else if (std.mem.eql(u8, name, "output")) {
        const b = body orelse return;
        const category = jsonrpc.getStr(b, "category") orelse "console";
        const text = jsonrpc.getStr(b, "output") orelse "";
        try s.appendOutput(category, text);
        if (std.mem.eql(u8, category, "stderr") or std.mem.eql(u8, category, "important")) {
            const first = std.mem.trimEnd(u8, text[0..(std.mem.indexOfScalar(u8, text, '\n') orelse text.len)], "\r");
            if (first.len > 0) app.toast("dap[{s}]: {s}", .{ category, first[0..@min(first.len, 80)] });
        }
    } else if (std.mem.eql(u8, name, "exited")) {
        const code = if (body) |b| jsonrpc.getInt(b, "exitCode") orelse 0 else 0;
        app.toast("dap: exited (code {d})", .{code});
        s.exited = true;
        clearArrow(app);
    } else if (std.mem.eql(u8, name, "terminated")) {
        if (!s.exited) app.toast("dap: session ended", .{});
        s.exited = true;
        endSession(app);
    }
}

/// Open (or reveal) the stopped frame's file with the cursor on `line`.
fn jumpTo(app: *App, path: []const u8, line: u32) Allocator.Error!void {
    const copy = try app.gpa.dupe(u8, path);
    clearArrow(app);
    app.dap.arrow = .{ .path = copy, .line = line };
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    if (app.panes.editor(id)) |e| {
        const ed = e.buf.editor;
        ed.anchor = null;
        ed.placeCursor(@min(line, @as(u32, @intCast(ed.lineCount() -| 1))), 0);
        e.view.scroll_line = @intCast(ed.currentLine() -| app.pane_rows / 2);
    }
}

// ─── the panes ──────────────────────────────────────────────────────────

/// Open `pane` beside the active one, or reveal the one of `tag`.
fn openSingleton(app: *App, tag: std.meta.Tag(app_mod.Pane), pane: app_mod.Pane) CommandError!void {
    if (app.panes.findKind(tag)) |id| {
        app.showPane(id);
        return;
    }
    var p = pane;
    errdefer p.deinit(app.gpa, app.io);
    const cur = app.active;
    const id = try app.panes.add(p);
    p = undefined;
    const layout = app.layouts.current();
    const placed: ?layout_mod.NodeId = if (cur) |c| try layout.split(c, .horizontal, id) else null;
    if (placed == null) _ = try layout.showIn(null, id);
    app.setActive(id);
}

pub fn showDebug(app: *App) CommandError!void {
    return openSingleton(app, .debug, .{ .debug = .{} });
}

pub fn openRepl(app: *App) CommandError!void {
    return openSingleton(app, .dap_repl, .{ .dap_repl = .{ .gpa = app.gpa } });
}

fn statusLine(app: *App, arena: Allocator) Allocator.Error![]const u8 {
    const s = app.dap.session orelse return "(no session — dap.run starts one)";
    if (s.stopped) |st| return std.fmt.allocPrint(arena, "● stopped ({s}) · thread {d}", .{ st.label(), st.thread_id });
    if (s.exited) return "○ exited";
    if (s.running) return "▶ running";
    return "… starting";
}

pub fn drawDebug(app: *App, ui: Ui, id: PaneId, p: *DebugPane, area: Rect) Allocator.Error!void {
    const arena = ui.arena;
    const s = app.dap.session;
    var frames: std.ArrayListUnmanaged(dap_view.Frame) = .empty;
    if (s) |ss| for (ss.frames) |f| {
        const src = if (f.source) |sp| app.relPath(sp) else "?";
        try frames.append(arena, .{ .label = try std.fmt.allocPrint(arena, "{s}:{d}  {s}", .{ src, f.line, f.name }) });
    };
    var watches: std.ArrayListUnmanaged(dap_view.Watch) = .empty;
    for (app.dap.watches.items) |w| {
        const r: ?types.WatchResult = if (s) |ss| ss.watch_results.get(w) else null;
        const value: []const u8, const is_err: bool = if (r) |res| (if (res.err) |e| .{ try std.fmt.allocPrint(arena, "err: {s}", .{e}), true } else if (res.ty) |t| .{ try std.fmt.allocPrint(arena, "{s} : {s}", .{ res.value, t }), false } else .{ res.value, false }) else .{ "(no value)", false };
        try watches.append(arena, .{ .expression = w, .value = value, .is_err = is_err });
    }
    const vars: []const types.VarRow = if (s) |ss| try ss.variableRows(arena) else &.{};
    var output: std.ArrayListUnmanaged([]const u8) = .empty;
    if (s) |ss| for (ss.output.items) |o| try output.append(arena, o.text);
    const total_vars = watches.items.len + vars.len;
    if (p.vars_cursor >= total_vars) p.vars_cursor = total_vars -| 1;
    if (p.stack_cursor >= frames.items.len) p.stack_cursor = frames.items.len -| 1;
    if (app.active == id) app.pane_rows = @max(area.h, 1);
    dap_view.draw(ui, id, area, &p.scrolls, .{
        .status = try statusLine(app, arena),
        .stopped = if (s) |ss| ss.stopped != null else false,
        .has_session = s != null,
        .frames = frames.items,
        .stack_cursor = p.stack_cursor,
        .watches = watches.items,
        .vars = vars,
        .vars_cursor = p.vars_cursor,
        .output = output.items,
        .section = p.section,
        .focused = app.active == id and app.focus == .pane,
    });
}

pub fn drawRepl(app: *App, ui: Ui, id: PaneId, p: *DapReplPane, area: Rect) Allocator.Error!void {
    const arena = ui.arena;
    const vis = try p.visible(arena);
    const entries = try arena.alloc(repl_view.Entry, vis.len);
    for (vis, 0..) |hi, i| {
        const e = p.history.items[hi];
        var children: ?[]const repl_view.Child = null;
        if (e.expanded and e.variables_ref > 0) if (app.dap.session) |s| if (s.variables.get(e.variables_ref)) |kids| {
            const out = try arena.alloc(repl_view.Child, kids.len);
            for (kids, 0..) |k, j| out[j] = .{ .name = k.name, .ty = k.ty, .value = k.value };
            children = out;
        };
        entries[i] = .{
            .index = @intCast(hi),
            .expression = e.expression,
            .value = e.value,
            .ty = e.ty,
            .err = e.err,
            .pending = e.pending,
            .expandable = e.variables_ref > 0,
            .expanded = e.expanded,
            .children = children,
            .selected = p.selected == hi,
        };
    }
    // The scroll is an index into the visible list; map a selected
    // history index onto it.
    var scroll = p.scroll;
    if (p.selected) |sel| {
        for (vis, 0..) |hi, i| if (hi == sel) {
            scroll = i;
        };
    }
    if (app.active == id) app.pane_rows = @max(area.h, 1);
    const caret = repl_view.draw(ui, id, area, .{
        .entries = entries,
        .total = p.history.items.len,
        .input = p.input.items,
        .caret = p.caret,
        .filter = p.filter.items,
        .filter_mode = p.filter_mode,
        .scroll = scroll,
        .focused = app.active == id and app.focus == .pane,
    });
    if (app.active == id and app.focus == .pane) if (caret) |c| {
        app.cursor_pos = .{ .x = c.x, .y = c.y };
    };
}

/// Esc: back to the editor that was last active, else the tree.
fn leaveToEditor(app: *App) void {
    if (app.last_editor) |e| {
        if (app.panes.get(e) != null) {
            app.setActive(e);
            return;
        }
    }
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .tree;
}

/// The debug pane's keys. False lets the chord chain see the key.
pub fn debugKey(app: *App, id: PaneId, p: *DebugPane, k: Key) Allocator.Error!bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const s = app.dap.session;
    const n_frames: usize = if (s) |ss| ss.frames.len else 0;
    const arena = app.frame.allocator();
    const n_vars: usize = app.dap.watches.items.len + (if (s) |ss| (try ss.variableRows(arena)).len else 0);
    const cursor: *usize = if (p.section == .stack) &p.stack_cursor else &p.vars_cursor;
    const n: usize = if (p.section == .stack) n_frames else n_vars;
    const page = @max(app.pane_rows / 2, 1);
    switch (k.code) {
        .tab => p.section = if (p.section == .stack) .variables else .stack,
        .down => cursor.* = @min(cursor.* + 1, n -| 1),
        .up => cursor.* -|= 1,
        .home => cursor.* = 0,
        .end => cursor.* = n -| 1,
        .page_down => cursor.* = @min(cursor.* + page, n -| 1),
        .page_up => cursor.* -|= page,
        .enter => try debugActivate(app, p),
        .esc => leaveToEditor(app),
        .char => |c| switch (c) {
            'j' => cursor.* = @min(cursor.* + 1, n -| 1),
            'k' => cursor.* -|= 1,
            'g' => cursor.* = 0,
            'G' => cursor.* = n -| 1,
            'w' => try watchSelected(app, p),
            'y' => try yankSelected(app, p),
            's' => try setVariablePrompt(app),
            'd' => if (p.section == .variables and p.vars_cursor < app.dap.watches.items.len) {
                const expr = try arena.dupe(u8, app.dap.watches.items[p.vars_cursor]);
                removeWatch(app, expr);
            },
            'q' => try app.forceClosePane(id),
            else => return false,
        },
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// Enter: a frame selects itself (scopes follow); a variable row
/// expands or collapses; a watch row re-evaluates.
fn debugActivate(app: *App, p: *DebugPane) Allocator.Error!void {
    const s = app.dap.session orelse return;
    switch (p.section) {
        .stack => {
            if (p.stack_cursor >= s.frames.len) return;
            const f = s.frames[p.stack_cursor];
            s.scopes = &.{};
            s.variables.clearRetainingCapacity();
            s.requestScopes(f.id) catch {};
            if (f.source) |src| try jumpTo(app, src, f.line -| 1);
        },
        .variables => {
            const nw = app.dap.watches.items.len;
            if (p.vars_cursor < nw) {
                _ = s.evaluate(app.dap.watches.items[p.vars_cursor], .watch) catch 0;
                return;
            }
            const rows = try s.variableRows(app.frame.allocator());
            const i = p.vars_cursor - nw;
            if (i >= rows.len) return;
            const row = rows[i];
            if (!row.expandable) return;
            if (row.expanded) {
                _ = s.expanded.remove(row.var_ref);
            } else {
                try s.expanded.put(app.gpa, row.var_ref, {});
                if (!s.variables.contains(row.var_ref)) s.requestVariables(row.var_ref) catch {};
            }
        },
    }
}

/// The variable row under the cursor, or null (a scope, a watch, nothing).
fn selectedVar(app: *App, p: *DebugPane) Allocator.Error!?types.VarRow {
    const s = app.dap.session orelse return null;
    if (p.section != .variables) return null;
    const nw = app.dap.watches.items.len;
    if (p.vars_cursor < nw) return null;
    const rows = try s.variableRows(app.frame.allocator());
    const i = p.vars_cursor - nw;
    if (i >= rows.len) return null;
    return rows[i];
}

fn watchSelected(app: *App, p: *DebugPane) Allocator.Error!void {
    const row = (try selectedVar(app, p)) orelse return;
    if (row.is_scope) {
        app.toast("can't watch a scope row", .{});
        return;
    }
    if (app.dap.hasWatch(row.name)) {
        app.toast("watch: already tracking {s}", .{row.name});
        return;
    }
    const name = try app.frame.allocator().dupe(u8, row.name);
    try addWatch(app, name);
}

fn yankSelected(app: *App, p: *DebugPane) Allocator.Error!void {
    const row = (try selectedVar(app, p)) orelse return;
    try app.clipboard.setYank(row.value, false);
    const short = row.value[0..@min(row.value.len, 40)];
    app.toast("yanked: {s}{s}", .{ short, if (row.value.len > 40) "…" else "" });
}

/// `dap.set_variable`: a prompt seeded with the selected variable's
/// value. Without a debug pane, a session, or a variable row there is
/// nothing to set and the command is a quiet no-op.
pub fn setVariablePrompt(app: *App) Allocator.Error!void {
    const active = app.active orelse return;
    const pane = app.panes.get(active) orelse return;
    const p: *DebugPane = switch (pane.*) {
        .debug => |*d| d,
        else => return,
    };
    const row = (try selectedVar(app, p)) orelse return;
    if (row.is_scope) {
        app.toast("can't set a scope row", .{});
        return;
    }
    if (row.parent_ref == 0) {
        app.toast("can't set this variable (no parent ref)", .{});
        return;
    }
    const title = try std.fmt.allocPrint(app.gpa, "Set {s} =", .{row.name});
    errdefer app.gpa.free(title);
    const name = try app.gpa.dupe(u8, row.name);
    errdefer app.gpa.free(name);
    var state = app_mod.Prompt.init(app.gpa, title);
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    try state.setText(app.gpa, row.value);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .dap_set_variable = .{ .parent_ref = row.parent_ref, .name = name } }, .title_owned = title } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptSetVariable(app: *App, parent_ref: i64, name: []const u8, value: []const u8) Allocator.Error!void {
    const s = app.dap.session orelse {
        app.toast("dap: no session", .{});
        return;
    };
    _ = s.requestCtx(.set_variable, "setVariable", .{ .variablesReference = parent_ref, .name = name, .value = value }, @bitCast(parent_ref)) catch |err| {
        app.toast("dap setVariable: {s}", .{@errorName(err)});
    };
}

// ─── the REPL ───

/// The REPL's keys. Everything is the pane's while it has focus except
/// modified chords, which reach the chord chain.
pub fn replKey(app: *App, id: PaneId, p: *DapReplPane, k: Key) Allocator.Error!bool {
    const gpa = app.gpa;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) {
        // The line-editing chords are the field's; the rest are chords.
        if (k.mods.ctrl and k.code == .char and (k.code.char == 'u' or k.code.char == 'w' or k.code.char == 'a' or k.code.char == 'e' or k.code.char == 'k')) {
            _ = try text_field.handleKey(&p.input, &p.caret, gpa, k);
            app.needs_render = true;
            return true;
        }
        return false;
    }
    app.needs_render = true;
    if (p.filter_mode) {
        switch (k.code) {
            .backspace => {
                if (p.filter.items.len > 0) p.filter.items.len = text_field.prevCp(p.filter.items, p.filter.items.len);
                p.selected = null;
            },
            .enter => p.filter_mode = false,
            .esc => {
                p.filter.clearRetainingCapacity();
                p.filter_mode = false;
                p.selected = null;
            },
            .char => if (k.typed()) |cp| {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &tmp) catch return true;
                try p.filter.appendSlice(gpa, tmp[0..n]);
                p.selected = null;
            },
            else => {},
        }
        return true;
    }
    switch (k.code) {
        .enter => try replSubmit(app, p),
        .up => if (k.mods.shift) try replSelectMove(app, p, -1) else replHistoryWalk(p, -1),
        .down => if (k.mods.shift) try replSelectMove(app, p, 1) else replHistoryWalk(p, 1),
        .page_up => try replSelectMove(app, p, -1),
        .page_down => try replSelectMove(app, p, 1),
        .esc => {
            if (p.filter.items.len > 0) {
                p.filter.clearRetainingCapacity();
                p.selected = null;
            } else if (p.selected != null) {
                p.selected = null;
            } else leaveToEditor(app);
        },
        .char => |c| {
            if (c == 'o' and p.selected != null) {
                try replToggleExpand(app, p);
                return true;
            }
            if (c == '/' and (p.input.items.len == 0 or p.selected != null)) {
                p.filter_mode = true;
                return true;
            }
            if (c == 'q' and p.selected != null) {
                try app.forceClosePane(id);
                return true;
            }
            _ = try text_field.handleKey(&p.input, &p.caret, gpa, k);
        },
        else => _ = try text_field.handleKey(&p.input, &p.caret, gpa, k),
    }
    return true;
}

/// Submit the input: a history entry, `evaluate` with `context: "repl"`,
/// or "no DAP session" when there is none.
fn replSubmit(app: *App, p: *DapReplPane) Allocator.Error!void {
    const gpa = app.gpa;
    const expr = std.mem.trim(u8, p.input.items, " \t");
    if (expr.len == 0) return;
    var entry: types.ReplEntry = .{ .expression = try gpa.dupe(u8, expr), .pending = true };
    errdefer entry.deinit(gpa);
    if (p.commands.getLastOrNull() == null or !std.mem.eql(u8, p.commands.getLastOrNull().?, expr)) {
        try p.commands.append(gpa, try gpa.dupe(u8, expr));
    }
    p.cmd_idx = null;
    p.scroll = repl_view.scroll_tail;
    p.selected = null;
    if (app.dap.session) |s| {
        _ = s.evaluate(expr, .repl) catch |err| {
            try entry.setResult(gpa, "", null, @errorName(err), 0);
        };
    } else {
        try entry.setResult(gpa, "", null, "no DAP session (run dap.run first)", 0);
    }
    try p.history.append(gpa, entry);
    p.input.clearRetainingCapacity();
    p.caret = 0;
}

/// A reply for `expr` lands on the oldest pending entry with that text.
fn replResult(app: *App, expr: []const u8, success: bool, message: ?[]const u8, body: ?jsonrpc.Value) Allocator.Error!void {
    const id = app.panes.findKind(.dap_repl) orelse return;
    const pane = app.panes.get(id) orelse return;
    const p = &pane.dap_repl;
    for (p.history.items) |*e| if (e.pending and std.mem.eql(u8, e.expression, expr)) {
        if (success) {
            const value = if (body) |b| jsonrpc.getStr(b, "result") orelse "" else "";
            const ty = if (body) |b| jsonrpc.getStr(b, "type") else null;
            const vref = if (body) |b| jsonrpc.getInt(b, "variablesReference") orelse 0 else 0;
            try e.setResult(app.gpa, value, ty, null, vref);
        } else try e.setResult(app.gpa, "", null, message orelse "failed", 0);
        return;
    };
}

/// Shift+↑/↓ move the row selection through the visible entries;
/// the first press lands on the last row.
fn replSelectMove(app: *App, p: *DapReplPane, delta: i32) Allocator.Error!void {
    const vis = try p.visible(app.frame.allocator());
    if (vis.len == 0) return;
    var cur: i64 = @intCast(vis.len);
    if (p.selected) |sel| for (vis, 0..) |hi, i| if (hi == sel) {
        cur = @intCast(i);
    };
    const next: usize = @intCast(std.math.clamp(cur + delta, 0, @as(i64, @intCast(vis.len)) - 1));
    p.selected = vis[next];
    p.scroll = next;
}

/// ↑/↓ walk the submitted lines; past the newest the typed input is
/// restored (vim's cmdline convention).
fn replHistoryWalk(p: *DapReplPane, dir: i32) void {
    const h = p.commands.items;
    if (h.len == 0) return;
    const next: ?usize = if (dir < 0)
        (if (p.cmd_idx) |i| i -| 1 else h.len - 1)
    else
        (if (p.cmd_idx) |i| (if (i + 1 < h.len) i + 1 else null) else return);
    p.input.clearRetainingCapacity();
    if (next) |i| {
        p.input.appendSlice(p.gpa, h[i]) catch {};
    }
    p.caret = p.input.items.len;
    p.cmd_idx = next;
}

fn replToggleExpand(app: *App, p: *DapReplPane) Allocator.Error!void {
    const sel = p.selected orelse return;
    if (sel >= p.history.items.len) return;
    const e = &p.history.items[sel];
    if (e.variables_ref == 0) return;
    e.expanded = !e.expanded;
    if (e.expanded) if (app.dap.session) |s| {
        if (!s.variables.contains(e.variables_ref)) s.requestVariables(e.variables_ref) catch {};
    };
}

/// A click on a pane row (`.script_hit`).
pub fn click(app: *App, id: PaneId, hit_id: u32) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    switch (pane.*) {
        .debug => |*p| {
            if (hit_id >= dap_view.watch_base) {
                p.section = .variables;
                p.vars_cursor = hit_id - dap_view.watch_base;
            } else if (hit_id >= dap_view.vars_base) {
                p.section = .variables;
                p.vars_cursor = app.dap.watches.items.len + (hit_id - dap_view.vars_base);
                try debugActivate(app, p);
            } else {
                p.section = .stack;
                p.stack_cursor = hit_id;
                try debugActivate(app, p);
            }
        },
        .dap_repl => |*p| {
            if (hit_id == repl_view.input_hit) {
                p.selected = null;
            } else if (hit_id < p.history.items.len) {
                p.selected = hit_id;
            }
        },
        else => {},
    }
    app.needs_render = true;
}

/// The wheel on a pane: the debug pane moves the focused cursor, the
/// REPL moves its selection.
pub fn scrollBy(app: *App, id: PaneId, delta: i32) Allocator.Error!void {
    const pane = app.panes.get(id) orelse return;
    switch (pane.*) {
        .debug => |*p| {
            const key: Key = if (delta < 0) Key.named(.up) else Key.named(.down);
            var n: u32 = @intCast(@abs(delta));
            while (n > 0) : (n -= 1) _ = try debugKey(app, id, p, key);
        },
        .dap_repl => |*p| try replSelectMove(app, p, delta),
        else => {},
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(testing.allocator, &app.screen);
}

test "breakpoints: toggle on/off toasts the 1-based line, list summarises, clear counts" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/code.rs");
    try e.buf.editor.setText("fn main() {\n    let a = 1;\n    let b = 2;\n}\n");
    e.buf.editor.placeCursor(2, 0);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });
    try testing.expectEqualStrings("breakpoint set: line 3", app.lastToast().?);
    try testing.expectEqual(@as(u32, 2), app.dap.bpsFor("/tmp/code.rs")[0].line);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });
    try testing.expectEqualStrings("breakpoint cleared: line 3", app.lastToast().?);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });
    e.buf.editor.placeCursor(0, 0);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });
    try command.run(&app, .{ .static = .@"dap.list_breakpoints" });
    try testing.expectEqualStrings("2 breakpoint(s) — code.rs: 1,3", app.lastToast().?);
    // The gutter carries the marks.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const marks = try marksFor(&app, arena.allocator(), "/tmp/code.rs", &app.theme, false);
    try testing.expectEqual(@as(usize, 2), marks.len);
    try testing.expectEqualStrings("●", marks[1].glyph);
    try command.run(&app, .{ .static = .@"dap.clear_all_breakpoints" });
    try testing.expectEqualStrings("cleared 2 breakpoints", app.lastToast().?);
    try command.run(&app, .{ .static = .@"dap.list_breakpoints" });
    try testing.expectEqualStrings("no breakpoints set", app.lastToast().?);
}

test "conditional + hit-count prompts record on the line; empty input clears" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/loop.py");
    try e.buf.editor.setText("for i in range(10):\n    print(i)\n");
    e.buf.editor.placeCursor(1, 0);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint_conditional" });
    try testing.expectEqualStrings("Breakpoint condition (line 2)", app.overlay.prompt.state.title);
    for ("i == 5") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("bp line 2: i == 5", app.lastToast().?);
    try testing.expectEqualStrings("i == 5", app.dap.bpsFor("/tmp/loop.py")[0].condition.?);
    try command.run(&app, .{ .static = .@"dap.set_breakpoint_hit_count" });
    for (">= 5") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("bp line 2 hit-count >= 5", app.lastToast().?);
    // Reopening seeds the prompt with the condition; clearing it keeps the breakpoint.
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint_conditional" });
    try testing.expectEqualStrings("i == 5", app.overlay.prompt.state.text());
    try app.handle(.{ .key = Key.ctrl('u') });
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("bp line 2", app.lastToast().?);
    try testing.expect(app.dap.bpsFor("/tmp/loop.py")[0].condition == null);
    try testing.expectEqualStrings(">= 5", app.dap.bpsFor("/tmp/loop.py")[0].hit_condition.?);
}

test "REPL without a session: entries land as no-session, the filter narrows, selection leaves the input" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 90, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"dap.repl" });
    try testing.expectEqualStrings("DAP REPL", app.panes.get(app.active.?).?.title());
    for ("alpha") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    for ("bravo") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    const p = &app.panes.get(app.active.?).?.dap_repl;
    try testing.expectEqual(@as(usize, 2), p.history.items.len);
    try testing.expectEqualStrings("no DAP session (run dap.run first)", p.history.items[0].err.?);
    const t1 = try screenText(&app);
    defer testing.allocator.free(t1);
    try testing.expect(std.mem.indexOf(u8, t1, "alpha") != null and std.mem.indexOf(u8, t1, "bravo") != null);
    // `/` on an empty input filters.
    try app.handle(.{ .key = Key.char('/') });
    for ("alp") |c| try app.handle(.{ .key = Key.char(c) });
    const t2 = try screenText(&app);
    defer testing.allocator.free(t2);
    try testing.expect(std.mem.indexOf(u8, t2, "filter: alp") != null);
    try testing.expect(std.mem.indexOf(u8, t2, "bravo") == null);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(!p.filter_mode and p.filter.items.len == 3);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expectEqual(@as(usize, 0), p.filter.items.len);
    // Shift+Up selects the last row; Esc returns to the input.
    try app.handle(.{ .key = Key.char('y') });
    try app.handle(.{ .key = .{ .code = .up, .mods = .{ .shift = true } } });
    try testing.expectEqual(@as(usize, 1), p.selected.?);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(p.selected == null);
    try app.handle(.{ .key = Key.char('z') });
    try testing.expectEqualStrings("yz", p.input.items);
    // ↑ walks the command history, ↓ past the newest restores the input.
    try app.handle(.{ .key = Key.named(.up) });
    try testing.expectEqualStrings("bravo", p.input.items);
    try app.handle(.{ .key = Key.named(.up) });
    try testing.expectEqualStrings("alpha", p.input.items);
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try testing.expectEqualStrings("", p.input.items);
}

test "watches: add via the prompt, the debug pane lists them, the picker removes one" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 90, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"dap.show" });
    try testing.expectEqualStrings("Debug", app.panes.get(app.active.?).?.title());
    try command.run(&app, .{ .static = .@"dap.add_watch" });
    try testing.expectEqualStrings("Watch expression", app.overlay.prompt.state.title);
    for ("my_var.field") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("watch: + my_var.field", app.lastToast().?);
    const t = try screenText(&app);
    defer testing.allocator.free(t);
    try testing.expect(std.mem.indexOf(u8, t, "my_var.field = (no value)") != null);
    try command.run(&app, .{ .static = .@"dap.remove_watch" });
    try testing.expectEqualStrings("Remove watch", app.overlay.picker.state.title);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("watch: − my_var.field", app.lastToast().?);
    try testing.expectEqual(@as(usize, 0), app.dap.watches.items.len);
    // Nothing to set without a session: a quiet no-op.
    try command.run(&app, .{ .static = .@"dap.set_variable" });
    try testing.expect(app.overlay == .none);
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"dap.exceptions" }));
    try testing.expectEqualStrings("dap: adapter advertised no exception filters", app.lastToast().?);
}

// ─── a scripted adapter, in process ─────────────────────────────────────

/// What the fake saw on the wire, for the assertions.
const FakeLog = struct {
    lock: std.Io.Mutex = .init,
    bp_lines: [8]u32 = undefined,
    bp_count: usize = 0,
    filters_count: usize = 0,
    launched: bool = false,
    configured: bool = false,
    set_variable: bool = false,

    fn note(self: *FakeLog, comptime field: []const u8, value: anytype) void {
        self.lock.lockUncancelable(testing.io);
        defer self.lock.unlock(testing.io);
        @field(self, field) = value;
    }
};

fn fakeReply(io: std.Io, gpa: Allocator, out: std.Io.File, seq: *i64, request_seq: i64, cmd: []const u8, body: []const u8) void {
    seq.* += 1;
    const text = std.fmt.allocPrint(gpa, "{{\"seq\":{d},\"type\":\"response\",\"request_seq\":{d},\"command\":\"{s}\",\"success\":true,\"body\":{s}}}", .{ seq.*, request_seq, cmd, body }) catch return;
    defer gpa.free(text);
    jsonrpc.writeFrame(io, out, text) catch {};
}

fn fakeEvent(io: std.Io, gpa: Allocator, out: std.Io.File, seq: *i64, name: []const u8, body: []const u8) void {
    seq.* += 1;
    const text = std.fmt.allocPrint(gpa, "{{\"seq\":{d},\"type\":\"event\",\"event\":\"{s}\",\"body\":{s}}}", .{ seq.*, name, body }) catch return;
    defer gpa.free(text);
    jsonrpc.writeFrame(io, out, text) catch {};
}

/// A debugpy-shaped adapter: stops on `launch` at line 3 of the file,
/// steps to line 4 on `next`, answers the inspection requests with
/// one scope / one variable, echoes evaluations as `<expr> = 42`.
fn fakeAdapter(io: std.Io, gpa: Allocator, in: std.Io.File, out: std.Io.File, log: *FakeLog, file: []const u8) std.Io.Cancelable!void {
    var buf: [8192]u8 = undefined;
    var fr = in.readerStreaming(io, &buf);
    var seq: i64 = 1000;
    var line: u32 = 3;
    while (true) {
        const body = jsonrpc.readFrame(gpa, &fr.interface) catch return;
        defer gpa.free(body);
        var parsed = std.json.parseFromSlice(jsonrpc.Value, gpa, body, .{}) catch return;
        defer parsed.deinit();
        const v = parsed.value;
        const cmd = jsonrpc.getStr(v, "command") orelse continue;
        const rseq = jsonrpc.getInt(v, "seq") orelse 0;
        const args = jsonrpc.getField(v, "arguments") orelse jsonrpc.Value.null;
        if (std.mem.eql(u8, cmd, "initialize")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"exceptionBreakpointFilters\":[{\"filter\":\"uncaught\",\"label\":\"Uncaught Exceptions\",\"default\":true},{\"filter\":\"raised\",\"label\":\"Raised Exceptions\",\"default\":false}]}");
            fakeEvent(io, gpa, out, &seq, "initialized", "{}");
        } else if (std.mem.eql(u8, cmd, "setBreakpoints")) {
            const lines: []const jsonrpc.Value = jsonrpc.getArr(args, "lines") orelse &.{};
            log.lock.lockUncancelable(io);
            log.bp_count = @min(lines.len, log.bp_lines.len);
            for (lines[0..log.bp_count], 0..) |l, i| log.bp_lines[i] = @intCast(jsonrpc.asInt(l) orelse 0);
            log.lock.unlock(io);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"breakpoints\":[{\"verified\":true}]}");
        } else if (std.mem.eql(u8, cmd, "setExceptionBreakpoints")) {
            const filters: []const jsonrpc.Value = jsonrpc.getArr(args, "filters") orelse &.{};
            log.note("filters_count", filters.len);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
        } else if (std.mem.eql(u8, cmd, "launch")) {
            log.note("launched", true);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
        } else if (std.mem.eql(u8, cmd, "configurationDone")) {
            log.note("configured", true);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
            fakeEvent(io, gpa, out, &seq, "output", "{\"category\":\"stdout\",\"output\":\"hello\\n\"}");
            fakeEvent(io, gpa, out, &seq, "stopped", "{\"reason\":\"breakpoint\",\"threadId\":1}");
        } else if (std.mem.eql(u8, cmd, "threads")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"threads\":[{\"id\":1,\"name\":\"MainThread\"}]}");
        } else if (std.mem.eql(u8, cmd, "stackTrace")) {
            const b = std.fmt.allocPrint(gpa, "{{\"stackFrames\":[{{\"id\":100,\"name\":\"main\",\"line\":{d},\"column\":1,\"source\":{{\"path\":\"{s}\"}}}}]}}", .{ line, file }) catch return;
            defer gpa.free(b);
            fakeReply(io, gpa, out, &seq, rseq, cmd, b);
        } else if (std.mem.eql(u8, cmd, "scopes")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":10,\"expensive\":false}]}");
        } else if (std.mem.eql(u8, cmd, "variables")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"variables\":[{\"name\":\"a\",\"value\":\"1\",\"type\":\"int\",\"variablesReference\":0}]}");
        } else if (std.mem.eql(u8, cmd, "evaluate")) {
            const expr = jsonrpc.getStr(args, "expression") orelse "";
            const b = std.fmt.allocPrint(gpa, "{{\"result\":\"{s} = 42\",\"type\":\"int\",\"variablesReference\":0}}", .{expr}) catch return;
            defer gpa.free(b);
            fakeReply(io, gpa, out, &seq, rseq, cmd, b);
        } else if (std.mem.eql(u8, cmd, "setVariable")) {
            log.note("set_variable", true);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"value\":\"7\"}");
        } else if (std.mem.eql(u8, cmd, "next")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
            fakeEvent(io, gpa, out, &seq, "continued", "{\"threadId\":1}");
            line += 1;
            fakeEvent(io, gpa, out, &seq, "stopped", "{\"reason\":\"step\",\"threadId\":1}");
        } else if (std.mem.eql(u8, cmd, "disconnect") or std.mem.eql(u8, cmd, "terminate")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
            if (std.mem.eql(u8, cmd, "disconnect")) return;
        } else {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
        }
    }
}

/// Tick the app until `cond` holds or the budget runs out.
fn pumpUntil(app: *App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool, budget_ms: u32) !void {
    var spent: u32 = 0;
    while (!cond(ctx)) : (spent += 10) {
        if (spent > budget_ms) return error.Timeout;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
        try app.tick(App.nowMs(app.io));
    }
}

test "a scripted adapter: the handshake, a stop with frames/scopes/variables/watches, the REPL, setVariable, a step" {
    const gpa = testing.allocator;
    const io = testing.io;
    var app = try App.initWith(gpa, io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const file = "/tmp/mnml-zig-fake-dap.py";
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath(file);
    try e.buf.editor.setText("import x\n\nx = 1\ny = 2\nprint(x)\n");
    e.buf.editor.placeCursor(2, 0);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });
    try addWatch(&app, "a");

    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const c2s = try std.Io.Threaded.pipe2(.{});
    const s2c = try std.Io.Threaded.pipe2(.{});
    const F = std.Io.File;
    const flags: F.Flags = .{ .nonblocking = false };
    var log: FakeLog = .{};
    var group: std.Io.Group = .init;
    try group.concurrent(io, fakeAdapter, .{ io, gpa, F{ .handle = c2s[0], .flags = flags }, F{ .handle = s2c[1], .flags = flags }, &log, file });
    const s = try Session.initFiles(gpa, io, &app.events, app.dap.next_session, F{ .handle = c2s[1], .flags = flags }, F{ .handle = s2c[0], .flags = flags }, "{\"program\":\"x\"}");
    app.dap.next_session += 1;
    app.dap.session = s;
    try s.initialize();

    // The stop: frames, scope, its variables, the watch, the ▶ mark.
    const Cond = struct {
        fn stopped(a: *App) bool {
            const ss = a.dap.session orelse return false;
            return ss.stopped != null and ss.variables.contains(10) and ss.watch_results.contains("a") and ss.threads.len > 0;
        }
        fn replied(a: *App) bool {
            const id = a.panes.findKind(.dap_repl) orelse return false;
            const p = &a.panes.get(id).?.dap_repl;
            return p.history.items.len > 0 and !p.history.items[0].pending;
        }
        fn stepped(a: *App) bool {
            const ss = a.dap.session orelse return false;
            return ss.frames.len > 0 and ss.frames[0].line == 4 and ss.variables.contains(10);
        }
        fn setVar(a: *App) bool {
            return a.lastToast() != null and std.mem.startsWith(u8, a.lastToast().?, "set = 7");
        }
    };
    try pumpUntil(&app, &app, Cond.stopped, 5000);
    try testing.expect(s.initialized);
    try testing.expect(log.launched and log.configured);
    try testing.expectEqual(@as(usize, 1), log.bp_count);
    try testing.expectEqual(@as(u32, 3), log.bp_lines[0]);
    try testing.expectEqual(@as(usize, 1), log.filters_count); // the default-on filter
    try testing.expect(s.enabled_filters.contains("uncaught"));
    try testing.expectEqual(@as(usize, 2), s.filters.items.len);
    try testing.expectEqualStrings("breakpoint", s.stopped.?.reason);
    try testing.expectEqualStrings("main", s.frames[0].name);
    try testing.expectEqualStrings("MainThread", s.threads[0].name);
    try testing.expectEqual(@as(u32, 2), app.dap.arrow.?.line);
    try testing.expectEqualStrings(file, app.dap.arrow.?.path);
    try testing.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try testing.expectEqualStrings("a = 42", s.watch_results.get("a").?.value);
    try testing.expectEqualStrings("hello", s.output.items[0].text);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try s.variableRows(arena.allocator());
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("a: int", rows[1].label);
    const marks = try marksFor(&app, arena.allocator(), file, &app.theme, false);
    try testing.expectEqualStrings("▶", marks[0].glyph);

    // The REPL evaluates against the stop.
    try command.run(&app, .{ .static = .@"dap.repl" });
    for ("a + 1") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try pumpUntil(&app, &app, Cond.replied, 5000);
    const repl = &app.panes.get(app.panes.findKind(.dap_repl).?).?.dap_repl;
    try testing.expectEqualStrings("a + 1 = 42", repl.history.items[0].value);
    try testing.expectEqualStrings("int", repl.history.items[0].ty.?);

    // setVariable round-trips and re-fetches the parent.
    try acceptSetVariable(&app, 10, "a", "7");
    try pumpUntil(&app, &app, Cond.setVar, 5000);
    try testing.expect(log.set_variable);

    // A step: continued clears the cache, the next stop refills it one line down.
    try command.run(&app, .{ .static = .@"dap.next" });
    try pumpUntil(&app, &app, Cond.stepped, 5000);
    try testing.expectEqualStrings("step", s.stopped.?.reason);
    try testing.expectEqual(@as(u32, 3), app.dap.arrow.?.line);

    // Goodbye: terminate drops the session; the fake leaves on disconnect.
    try command.run(&app, .{ .static = .@"dap.terminate" });
    try testing.expect(app.dap.session == null);
    try testing.expect(app.dap.arrow == null);
    try group.await(io);
    (F{ .handle = c2s[0], .flags = flags }).close(io);
    (F{ .handle = s2c[1], .flags = flags }).close(io);
}

// ─── the real fake adapter (mnml-fake-dap), out of process ─────────────

/// The program the integration test debugs, as `prog.dbg` in a temp
/// workspace. Line numbers matter: the breakpoint goes on 4.
const fake_program =
    \\let x = 1
    \\let p = struct{a=1,b="two"}
    \\print "hello"
    \\x = x + 1
    \\fn f
    \\  let y = 10
    \\  x = x * y
    \\end
    \\call f
    \\print x
    \\
;

test "mnml-fake-dap end to end: spawn, initialize → launch → stop at a breakpoint → stack/scopes/variables (a struct expands) → next → evaluate → setVariable → continue → terminated" {
    const gpa = testing.allocator;
    const io = testing.io;
    const exe = build_options.fake_dap_exe;
    std.Io.Dir.cwd().access(io, exe, .{}) catch return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "prog.dbg", .data = fake_program });
    const file = try std.fs.path.join(gpa, &.{ ws, "prog.dbg" });
    defer gpa.free(file);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("MNML_FAKE_DAP", exe);
    var app = try App.initWith(gpa, io, .{ .workspace = ws, .cols = 100, .rows = 30, .env = &env });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openPath(file);
    const e = app.activeEditor().?;
    e.buf.editor.placeCursor(3, 0);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });
    try addWatch(&app, "x + 100");
    try command.run(&app, .{ .static = .@"dap.show" });

    // The adapter comes from `$MNML_FAKE_DAP`, as a `.test` would write it.
    try startSession(&app, .{ .cmd = "$MNML_FAKE_DAP" }, file, null);
    const s = app.dap.session.?;
    const Cond = struct {
        fn stopped(a: *App) bool {
            const ss = a.dap.session orelse return false;
            return ss.stopped != null and ss.variables.contains(1) and ss.watch_results.contains("x + 100") and ss.threads.len > 0 and ss.output.items.len > 0;
        }
        fn expanded(a: *App) bool {
            const ss = a.dap.session orelse return false;
            return ss.variables.contains(1000);
        }
        fn stepped(a: *App) bool {
            const ss = a.dap.session orelse return false;
            return ss.stopped != null and std.mem.eql(u8, ss.stopped.?.reason, "step") and ss.frames.len > 0 and ss.frames[0].line == 9 and ss.variables.contains(1) and ss.watch_results.contains("x + 100");
        }
        fn replied(a: *App) bool {
            const id = a.panes.findKind(.dap_repl) orelse return false;
            const p = &a.panes.get(id).?.dap_repl;
            return p.history.items.len > 0 and !p.history.items[0].pending;
        }
        fn setVar(a: *App) bool {
            const ss = a.dap.session orelse return false;
            const vars = ss.variables.get(1) orelse return false;
            return vars.len > 0 and std.mem.eql(u8, vars[0].value, "7") and std.mem.eql(u8, ss.watch_results.get("x + 100").?.value, "107");
        }
        fn ended(a: *App) bool {
            return a.dap.session == null;
        }
    };

    // The stop: the ▶ on line 4, the stack, the scope's variables, the
    // watch, the output line.
    try pumpUntil(&app, &app, Cond.stopped, 10_000);
    try testing.expect(s.initialized);
    try testing.expectEqualStrings("breakpoint", s.stopped.?.reason);
    try testing.expectEqual(@as(usize, 1), s.frames.len);
    try testing.expectEqualStrings("main", s.frames[0].name);
    try testing.expectEqual(@as(u32, 4), s.frames[0].line);
    try testing.expectEqualStrings(file, s.frames[0].source.?);
    try testing.expectEqual(@as(u32, 3), app.dap.arrow.?.line);
    try testing.expectEqual(@as(usize, 3), e.buf.editor.currentLine());
    try testing.expectEqualStrings("main", s.threads[0].name);
    try testing.expectEqual(@as(usize, 2), s.scopes.len);
    try testing.expectEqualStrings("Locals", s.scopes[0].name);
    try testing.expectEqualStrings("Globals", s.scopes[1].name);
    try testing.expectEqual(@as(usize, 2), s.filters.items.len);
    try testing.expect(s.enabled_filters.contains("uncaught"));
    try testing.expect(!s.enabled_filters.contains("error"));
    const locals = s.variables.get(1).?;
    try testing.expectEqual(@as(usize, 2), locals.len);
    try testing.expectEqualStrings("x", locals[0].name);
    try testing.expectEqualStrings("1", locals[0].value);
    try testing.expectEqualStrings("int", locals[0].ty.?);
    try testing.expectEqualStrings("p", locals[1].name);
    try testing.expectEqualStrings("{a=1, b=\"two\"}", locals[1].value);
    try testing.expectEqual(@as(i64, 1000), locals[1].variables_reference);
    try testing.expectEqualStrings("101", s.watch_results.get("x + 100").?.value);
    try testing.expectEqualStrings("int", s.watch_results.get("x + 100").?.ty.?);
    try testing.expectEqualStrings("hello", s.output.items[0].text);
    try testing.expectEqualStrings("stdout", s.output.items[0].category);

    // Expanding the struct fetches its fields.
    try s.expanded.put(gpa, 1000, {});
    try s.requestVariables(1000);
    try pumpUntil(&app, &app, Cond.expanded, 10_000);
    const kids = s.variables.get(1000).?;
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqualStrings("a", kids[0].name);
    try testing.expectEqualStrings("1", kids[0].value);
    try testing.expectEqualStrings("b", kids[1].name);
    try testing.expectEqualStrings("\"two\"", kids[1].value);
    try testing.expectEqualStrings("string", kids[1].ty.?);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try s.variableRows(arena.allocator());
    // Locals, x, p, a, b, Globals (Globals is not expanded: the scopes
    // reply expanded both; its rows come after).
    try testing.expect(rows.len >= 6);
    try testing.expectEqualStrings("p: struct", rows[2].label);
    try testing.expectEqual(@as(u8, 2), rows[3].depth);
    try testing.expectEqualStrings("a", rows[3].name);

    // next: `x = x + 1` runs; the stop is on line 9 (`fn f` is skipped),
    // the cache refilled, the watch re-evaluated.
    try command.run(&app, .{ .static = .@"dap.next" });
    try pumpUntil(&app, &app, Cond.stepped, 10_000);
    try testing.expectEqual(@as(u32, 8), app.dap.arrow.?.line);
    try testing.expectEqualStrings("2", s.variables.get(1).?[0].value);
    try testing.expectEqualStrings("102", s.watch_results.get("x + 100").?.value);
    try testing.expect(!s.variables.contains(1000));

    // The REPL evaluates against the stop; a bad expression is an error row.
    try command.run(&app, .{ .static = .@"dap.repl" });
    for ("x * 10") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try pumpUntil(&app, &app, Cond.replied, 10_000);
    const repl = &app.panes.get(app.panes.findKind(.dap_repl).?).?.dap_repl;
    try testing.expectEqualStrings("20", repl.history.items[0].value);
    try testing.expectEqualStrings("int", repl.history.items[0].ty.?);
    for ("nope") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    const Cond2 = struct {
        fn replied2(a: *App) bool {
            const id = a.panes.findKind(.dap_repl) orelse return false;
            const p = &a.panes.get(id).?.dap_repl;
            return p.history.items.len > 1 and !p.history.items[1].pending;
        }
    };
    try pumpUntil(&app, &app, Cond2.replied2, 10_000);
    try testing.expectEqualStrings("no such variable", repl.history.items[1].err.?);

    // setVariable: the Locals scope's `x` becomes 7; the parent is
    // re-fetched and the watch follows.
    try acceptSetVariable(&app, 1, "x", "7");
    try pumpUntil(&app, &app, Cond.setVar, 10_000);
    try testing.expect(std.mem.startsWith(u8, app.lastToast().?, "set = 7"));

    // continue: f runs (x = 70), `print x`, the program ends: exited +
    // terminated take the session down.
    try command.run(&app, .{ .static = .@"dap.continue" });
    try pumpUntil(&app, &app, Cond.ended, 10_000);
    try testing.expect(app.dap.arrow == null);
    try testing.expect(app.lastToast() != null);
}
