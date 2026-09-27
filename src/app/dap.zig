//! Debugging (DAP) on the app side: the breakpoints and watches mnml
//! keeps across sessions, the one live `Session` (`dap/client.zig`), the
//! handshake it drives (`initialize` → its reply sends `launch` /
//! `attach` → the adapter's `initialized` → breakpoints, exception
//! filters, `configurationDone` — the protocol's own order, which
//! lldb-dap and debugpy require: they emit `initialized` only while
//! handling `launch`; netcoredbg emits it before the `initialize`
//! reply, so the configuration step waits for both), what a `stopped`
//! event sets in motion (threads, the stack, scopes, variables, the
//! watches, the ▶ mark in the gutter), and the two panes — `Pane.debug`
//! and the console pane — `Pane.debug`: the step toolbar and the Debug
//! Console (output + evaluations in one scrollback). The sidebar
//! section (variables, watch, call stack, breakpoints) is
//! `debug_panel.zig`.
//!
//! Everything here works without an adapter: breakpoints toggle, the
//! REPL keeps its history (an entry lands as "no DAP session"), watches
//! list with "(no value)". The gate exercises exactly that.

const std = @import("std");
/// The one "does this pane have the keys" (`render.paneFocused`).
const paneFocused = @import("render.zig").paneFocused;
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
const toolbar = @import("../ui/debug_toolbar.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const client = @import("../dap/client.zig");
const types = @import("../dap/types.zig");
const syntax = @import("syntax.zig");
const Io = std.Io;
const dotnet = @import("dotnet.zig");
const runners = @import("runners.zig");
const pty_pane = @import("pty_pane.zig");
const layout_mod = @import("layout.zig");
const cmd_picker = @import("cmd_picker.zig");
const debug_panel = @import("debug_panel.zig");
const side = @import("side.zig");
const activity_bar = @import("activity_bar.zig");
const lsp = @import("lsp.zig");
const find_mod = @import("find.zig");
const config = @import("../config/root.zig");
const build_options = @import("build_options");
const hooks = @import("../core/hooks.zig");
const document = @import("../editor/document.zig");

pub const Session = client.Session;
pub const Breakpoint = types.Breakpoint;

/// Where execution stopped: the ▶ in the gutter. Owned path, 0-based line.
/// The ▶ of the stop: a file by path — or, for a frame whose text
/// came from the adapter (`source_ref`), the read-only pane it was
/// shown in, `path` then being the frame's display name.
pub const Arrow = struct { path: []u8, line: u32, pane: ?PaneId = null };

/// `Pane.debug`: the console pane. Its scrollback and input live in
/// `State.console` so they outlive the pane (and land while it is closed).
pub const DebugPane = struct {};

/// One line of the Debug Console's scrollback.
pub const ConsoleEntry = union(enum) {
    /// A program `output` event line (`stdout` / `stderr` / `console`).
    output: struct { category: []u8, text: []u8 },
    /// An evaluation: the `> expr` echo and its result.
    eval: types.ReplEntry,
    /// A session note (`── started prog.dbg ──`).
    note: []u8,

    pub fn deinit(self: *ConsoleEntry, gpa: Allocator) void {
        switch (self.*) {
            .output => |o| {
                gpa.free(o.category);
                gpa.free(o.text);
            },
            .eval => |*e| e.deinit(gpa),
            .note => |n| gpa.free(n),
        }
    }
};

/// The Debug Console: the scrollback, the input row, the history
/// (`↑` / `↓`) and the Tab completion in flight.
pub const Console = struct {
    entries: std.ArrayListUnmanaged(ConsoleEntry) = .empty,
    input: text_field.Buf = .empty,
    caret: usize = 0,
    /// What was submitted, for ↑/↓ — failed evaluations included, as a
    /// typo is what one most wants back.
    commands: std.ArrayListUnmanaged([]u8) = .empty,
    cmd_idx: ?usize = null,
    /// What was typed before ↑ started walking — ↓ past the newest
    /// puts it back (vim's cmdline convention). Owned.
    typed: ?[]u8 = null,
    /// Lines hidden past the bottom; 0 follows the tail.
    scroll: usize = 0,
    /// A Tab in progress: the fragment's start, the names that begin
    /// with it (owned), which one is in.
    completion: ?struct { start: usize, candidates: [][]u8, idx: usize } = null,

    pub const max_entries = 4000;

    pub fn deinit(self: *Console, gpa: Allocator) void {
        for (self.entries.items) |*e| e.deinit(gpa);
        self.entries.deinit(gpa);
        self.input.deinit(gpa);
        for (self.commands.items) |c| gpa.free(c);
        self.commands.deinit(gpa);
        if (self.typed) |t| gpa.free(t);
        self.clearCompletion(gpa);
    }

    pub fn clearCompletion(self: *Console, gpa: Allocator) void {
        const comp = self.completion orelse return;
        for (comp.candidates) |c| gpa.free(c);
        gpa.free(comp.candidates);
        self.completion = null;
    }

    /// The last evaluation (tests).
    pub fn lastEval(self: *const Console) ?*const types.ReplEntry {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i] == .eval) return &self.entries.items[i].eval;
        }
        return null;
    }
};

pub const State = struct {
    /// Per absolute path (owned keys), sorted by line.
    breakpoints: std.StringHashMapUnmanaged(types.FileBreakpoints) = .empty,
    /// Owned expressions, in the order they were added.
    watches: std.ArrayListUnmanaged([]u8) = .empty,
    /// Exception filters the user switched, by id (owned keys) → on.
    /// Like the breakpoints and the watches, these outlive a session:
    /// a restart re-applies them over the adapter's defaults.
    filter_overrides: Session.FilterOverrides = .empty,
    session: ?*Session = null,
    next_session: u32 = 1,
    arrow: ?Arrow = null,
    /// The read-only panes holding text fetched with `source` — a
    /// frame without a file (dyld, libc, a panic's std frames) — by the
    /// frame's display name (owned), so a second stop in the same place
    /// reuses the pane rather than opening another.
    source_panes: std.StringHashMapUnmanaged(PaneId) = .empty,
    /// The config layers read again by `dap.run` when the active file
    /// had no adapter (an adapter added to `.mnml/config.zon` after
    /// launch); `app.cfg.dap` borrows from it from then on.
    adapters_loaded: ?config.Loaded = null,
    /// The file the last session was started on — what `dap.restart`
    /// starts again. Owned.
    last_file: ?[]u8 = null,
    /// Where the pending `evaluate_hover` shows its answer.
    hover_at: ?struct { pane: PaneId, byte: usize } = null,
    /// `dotnet.debug`: the build pane whose exit starts the session on
    /// `file` (owned).
    pending_launch: ?PendingLaunch = null,
    console: Console = .{},

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.session) |s| s.deinit();
        self.session = null;
        if (self.pending_launch) |pl| gpa.free(pl.file);
        self.pending_launch = null;
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
        var fk = self.filter_overrides.keyIterator();
        while (fk.next()) |k| gpa.free(k.*);
        self.filter_overrides.deinit(gpa);
        if (self.arrow) |a| gpa.free(a.path);
        var sk = self.source_panes.keyIterator();
        while (sk.next()) |k| gpa.free(k.*);
        self.source_panes.deinit(gpa);
        if (self.last_file) |f| gpa.free(f);
        self.console.deinit(gpa);
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

/// The breakpoint a `dap.*breakpoint*` command acts on: the row under
/// the DEBUG section's cursor when it has the keys, else the editor's
/// cursor line. `path` is a frame copy.
const BpTarget = struct { path: []const u8, line: u32 };

fn bpTarget(app: *App) CommandError!BpTarget {
    if (try debug_panel.selectedBreakpoint(app)) |b| return .{ .path = b.path, .line = b.line };
    const ep = try editorWithPath(app);
    return .{ .path = ep.path, .line = @intCast(ep.e.buf.editor.currentLine()) };
}

/// Flip the breakpoint on the cursor line.
pub fn toggleBreakpoint(app: *App) CommandError!void {
    const ep = try editorWithPath(app);
    return toggleBreakpointAt(app, ep.path, @intCast(ep.e.buf.editor.currentLine()));
}

/// Flip the breakpoint on `line` of `path` (the gutter's click).
pub fn toggleBreakpointAt(app: *App, path: []const u8, line: u32) CommandError!void {
    const list = try listFor(app, path);
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
    syncBreakpoints(app, path);
}

/// Whether a left press anywhere in the gutter flips a breakpoint: the
/// file already carries breakpoints, or an adapter answers to it — the
/// config's `.dap` table (re-read on a miss, as `dap.run` does, so an
/// adapter written after launch counts) or a built-in one (a `.cs`
/// beside its csproj). A file nothing can debug keeps the line-numbers
/// click — F9 and the gutter menu still set breakpoints on it.
pub fn gutterToggles(app: *App, e: *const EditorPane) Allocator.Error!bool {
    const path = e.buf.doc.path orelse return false;
    if (app.dap.bpsFor(path).len > 0) return true;
    if (adapterFor(app, path) != null) return true;
    try refreshAdapters(app);
    if (adapterFor(app, path) != null) return true;
    const built_in = builtinAdapterFor(app, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            app.diag.clear();
            break :blk null;
        },
    };
    return built_in != null;
}

/// The gutter: flip the breakpoint on `line` of the pane's file.
pub fn gutterToggle(app: *App, pane: PaneId, line: u32) Allocator.Error!void {
    const e = app.panes.editor(pane) orelse return;
    const path = e.buf.doc.path orelse {
        app.toast("breakpoints need a saved file", .{});
        return;
    };
    const copy = try app.frame.allocator().dupe(u8, path);
    toggleBreakpointAt(app, copy, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// Whether the cursor line has a breakpoint, and whether it is enabled
/// (the gutter menu's words).
pub fn breakpointAtCursor(app: *App) struct { bool, bool } {
    const e = app.activeEditor() orelse return .{ false, true };
    const path = e.buf.doc.path orelse return .{ false, true };
    const line: u32 = @intCast(e.buf.editor.currentLine());
    for (app.dap.bpsFor(path)) |b| if (b.line == line) return .{ true, b.enabled };
    return .{ false, true };
}

/// `dap.toggle_breakpoint_enabled`: a disabled breakpoint keeps its
/// condition and leaves the adapter's list.
pub fn toggleEnabled(app: *App) CommandError!void {
    const t = try bpTarget(app);
    const list = app.dap.breakpoints.getPtr(t.path) orelse return app.diag.fail(app.frame.allocator(), "no breakpoint on line {d}", .{t.line + 1});
    const i = indexOfLine(list, t.line) orelse return app.diag.fail(app.frame.allocator(), "no breakpoint on line {d}", .{t.line + 1});
    const bp = &list.items[i];
    bp.enabled = !bp.enabled;
    if (!bp.enabled) bp.verified = null;
    app.toast("breakpoint line {d}: {s}", .{ t.line + 1, if (bp.enabled) "enabled" else "disabled" });
    app.needs_render = true;
    syncBreakpoints(app, t.path);
}

/// `dap.remove_breakpoint`.
pub fn removeBreakpoint(app: *App) CommandError!void {
    const t = try bpTarget(app);
    const list = app.dap.breakpoints.getPtr(t.path) orelse return app.diag.fail(app.frame.allocator(), "no breakpoint on line {d}", .{t.line + 1});
    const i = indexOfLine(list, t.line) orelse return app.diag.fail(app.frame.allocator(), "no breakpoint on line {d}", .{t.line + 1});
    var bp = list.orderedRemove(i);
    bp.deinit(app.gpa);
    app.toast("breakpoint cleared: line {d}", .{t.line + 1});
    app.needs_render = true;
    syncBreakpoints(app, t.path);
}

/// `dap.enable_all_breakpoints` / `dap.disable_all_breakpoints`.
pub fn setAllEnabled(app: *App, on: bool) CommandError!void {
    var n: usize = 0;
    var it = app.dap.breakpoints.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.items) |*b| if (b.enabled != on) {
            b.enabled = on;
            if (!on) b.verified = null;
            n += 1;
        };
        syncBreakpoints(app, e.key_ptr.*);
    }
    app.toast("{s} {d} breakpoint{s}", .{ if (on) "enabled" else "disabled", n, if (n == 1) "" else "s" });
    app.needs_render = true;
}

/// A breakpoint belongs to its line's text, not to a line number: move
/// `doc`'s breakpoints across every edit it logged since they last
/// moved (`Splice.shiftPoint` — a line opened above takes the
/// breakpoint down with its text, as Neovim's signs and VS Code's
/// breakpoints do). Called for every drawn editor before the frame trims
/// the log (`render`), and on a save; a log that lost its records
/// (`EditLog.lostSince`) leaves them where they are. Two breakpoints
/// whose lines were deleted into one keep the first.
pub fn followBreakpoints(app: *App, doc: *document.Document) void {
    const head = doc.edits.head();
    const seen = doc.bp_seen orelse head;
    doc.bp_seen = head;
    if (seen == head or doc.edits.lostSince(seen)) return;
    const recs = doc.edits.since(seen);
    if (recs.len != head - seen) return;
    const path = doc.path orelse return;
    const list = app.dap.breakpoints.getPtr(path) orelse return;
    if (list.items.len == 0) return;
    for (recs) |sp| for (list.items) |*b| {
        b.line = sp.shiftPoint(.{ .row = b.line, .col = 0 }).row;
    };
    sortByLine(list);
    var i: usize = 1;
    while (i < list.items.len) {
        if (list.items[i].line == list.items[i - 1].line) {
            var gone = list.orderedRemove(i);
            gone.deinit(app.gpa);
        } else i += 1;
    }
    app.needs_render = true;
}

/// A save: the breakpoints follow the text that was written, and a live
/// adapter hears where they are now — the program it runs is built from
/// the saved file, so the lines it is sent must be the saved text's.
pub fn onSavePost(app: *App, args: hooks.HookArgs) void {
    const e = app.panes.editor(args.save_post.pane) orelse return;
    followBreakpoints(app, e.buf.doc);
    const path = e.buf.doc.path orelse return;
    if (app.dap.bpsFor(path).len > 0) syncBreakpoints(app, path);
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
    const t = try bpTarget(app);
    const seed: []const u8 = if (app.dap.breakpoints.get(t.path)) |list| (if (indexOfLine(&list, t.line)) |i| list.items[i].condition orelse "" else "") else "";
    const title = try std.fmt.allocPrint(app.gpa, "Breakpoint condition (line {d})", .{t.line + 1});
    errdefer app.gpa.free(title);
    try openBpPrompt(app, title, seed, .{ .dap_bp_condition = .{ .path = try app.gpa.dupe(u8, t.path), .line = t.line } });
}

/// `dap.set_breakpoint_log_message`: a logpoint — the adapter prints
/// the message (with `{expr}` interpolation) instead of stopping.
pub fn logMessagePrompt(app: *App) CommandError!void {
    const t = try bpTarget(app);
    const seed: []const u8 = if (app.dap.breakpoints.get(t.path)) |list| (if (indexOfLine(&list, t.line)) |i| list.items[i].log_message orelse "" else "") else "";
    const title = try std.fmt.allocPrint(app.gpa, "Log message (line {d})  e.g. x is {{x}}", .{t.line + 1});
    errdefer app.gpa.free(title);
    try openBpPrompt(app, title, seed, .{ .dap_bp_log = .{ .path = try app.gpa.dupe(u8, t.path), .line = t.line } });
}

pub fn acceptLogMessage(app: *App, path: []const u8, line: u32, text_in: []const u8) Allocator.Error!void {
    const text = std.mem.trim(u8, text_in, " \t");
    const list = try listFor(app, path);
    const i = indexOfLine(list, line) orelse blk: {
        try list.append(app.gpa, .{ .line = line });
        sortByLine(list);
        break :blk indexOfLine(list, line).?;
    };
    const bp = &list.items[i];
    if (bp.log_message) |l| app.gpa.free(l);
    bp.log_message = if (text.len == 0) null else try app.gpa.dupe(u8, text);
    if (text.len == 0) app.toast("bp line {d}: log message cleared", .{line + 1}) else app.toast("bp line {d}: log \"{s}\"", .{ line + 1, text });
    app.needs_render = true;
    syncBreakpoints(app, path);
}

/// `dap.set_breakpoint_hit_count`: the same for `hitCondition`.
pub fn hitCountPrompt(app: *App) CommandError!void {
    const t = try bpTarget(app);
    const seed: []const u8 = if (app.dap.breakpoints.get(t.path)) |list| (if (indexOfLine(&list, t.line)) |i| list.items[i].hit_condition orelse "" else "") else "";
    const title = try std.fmt.allocPrint(app.gpa, "Hit-count condition (line {d})  e.g. >= 5  or  % 10", .{t.line + 1});
    errdefer app.gpa.free(title);
    try openBpPrompt(app, title, seed, .{ .dap_hit_count = .{ .path = try app.gpa.dupe(u8, t.path), .line = t.line } });
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
/// breakpoint's `●` (`◐` conditional or hit-counted, `◆` a logpoint,
/// `○` disabled); one the adapter did not verify paints muted. Frame arena.
/// `marksFor` for a pane: a pane holding a frame's fetched text has
/// no path, and the ▶ finds it by id.
pub fn marksForPane(app: *App, arena: Allocator, pane: PaneId, e: *EditorPane, theme: *const Theme, ascii: bool) Allocator.Error![]editor_view.GutterMark {
    if (app.dap.arrow) |a| if (a.pane != null and a.pane.? == pane and sourcePane(app, pane, a.path) == e) {
        var out: std.ArrayListUnmanaged(editor_view.GutterMark) = .empty;
        try out.append(arena, .{ .line = a.line, .kind = .sign, .glyph = if (ascii) ">" else "▶", .style = theme.warn_fg, .priority = editor_view.mark_priority.breakpoint });
        return out.items;
    };
    return marksFor(app, arena, e.buf.doc.path, theme, ascii);
}

pub fn marksFor(app: *App, arena: Allocator, path: ?[]const u8, theme: *const Theme, ascii: bool) Allocator.Error![]editor_view.GutterMark {
    const p = path orelse return &.{};
    var out: std.ArrayListUnmanaged(editor_view.GutterMark) = .empty;
    for (app.dap.bpsFor(p)) |b| {
        const glyph: []const u8 = if (!b.enabled) (if (ascii) "o" else "\u{25CB}") else switch (b.kind()) {
            .plain => if (ascii) "*" else "\u{25CF}",
            .conditional => if (ascii) "#" else "\u{25D0}",
            .log => if (ascii) "@" else "\u{25C6}",
        };
        const dim = !b.enabled or (b.verified != null and !b.verified.?);
        try out.append(arena, .{ .line = b.line, .kind = .sign, .glyph = glyph, .style = if (dim) theme.muted else theme.error_fg, .priority = editor_view.mark_priority.breakpoint });
    }
    if (app.dap.arrow) |a| if (std.mem.eql(u8, a.path, p)) {
        // Replace the breakpoint's mark on that line rather than add.
        for (out.items) |*m| if (m.line == a.line) {
            m.* = .{ .line = a.line, .kind = .sign, .glyph = if (ascii) ">" else "▶", .style = theme.warn_fg, .priority = editor_view.mark_priority.breakpoint };
            return out.items;
        };
        try out.append(arena, .{ .line = a.line, .kind = .sign, .glyph = if (ascii) ">" else "▶", .style = theme.warn_fg, .priority = editor_view.mark_priority.breakpoint });
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

/// `dap.edit_selected` on a watch row: a prompt seeded with the expression; accept
/// replaces it in place (its position kept).
pub fn editWatchPrompt(app: *App, expr: []const u8) CommandError!void {
    const old = try app.gpa.dupe(u8, expr);
    errdefer app.gpa.free(old);
    var state = app_mod.Prompt.init(app.gpa, "Edit watch expression");
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    try state.setText(app.gpa, expr);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .{ .dap_edit_watch = old } } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptEditWatch(app: *App, old: []const u8, text_in: []const u8) Allocator.Error!void {
    const expr = std.mem.trim(u8, text_in, " \t");
    const st = &app.dap;
    if (expr.len == 0) {
        const copy = try app.frame.allocator().dupe(u8, old);
        removeWatch(app, copy);
        return;
    }
    for (st.watches.items, 0..) |w, i| if (std.mem.eql(u8, w, old)) {
        const copy = try app.gpa.dupe(u8, expr);
        app.gpa.free(st.watches.items[i]);
        st.watches.items[i] = copy;
        if (st.session) |s| {
            s.removeWatchResult(old);
            if (s.stopped != null) _ = s.evaluate(expr, .watch) catch 0;
        }
        app.toast("watch: {s} \u{2192} {s}", .{ old, expr });
        app.needs_render = true;
        return;
    };
    try addWatch(app, expr);
}

pub fn removeWatch(app: *App, expr: []const u8) void {
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

/// An adapter resolved for a file: the config entry (or a built-in
/// row), and the launch body a built-in row derived, when it did.
const Found = struct {
    name: []const u8,
    cfg: app_mod.Config.DapAdapter,
    body: ?[]const u8 = null,
};

/// The `.dap.<key>` adapter for a file: its extension first, then the
/// grammar key (`py` / `rust`…), so both spellings of a config work.
fn adapterFor(app: *App, path: []const u8) ?Found {
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

/// How a built-in adapter's launch body is derived.
pub const BuiltinLaunch = enum {
    /// The nearest csproj's debug assembly: `{ program:
    /// <dir>/bin/Debug/<TargetFramework>/<AssemblyName>.dll, cwd: <dir> }`.
    dotnet_project,
};

/// An adapter mnml knows without a config entry, by grammar key.
pub const BuiltinAdapter = struct {
    key: []const u8,
    cmd: []const u8,
    args: []const []const u8,
    launch: BuiltinLaunch,
};

/// Consulted after `.dap.<key>` and the config re-read, so a
/// workspace's own entry for the same key always wins. `CONFIG.md`
/// lists them.
pub const builtin_adapters = [_]BuiltinAdapter{
    .{ .key = "cs", .cmd = "netcoredbg", .args = &.{"--interpreter=vscode"}, .launch = .dotnet_project },
};

pub fn builtinFor(key: []const u8) ?BuiltinAdapter {
    for (builtin_adapters) |b| if (std.mem.eql(u8, b.key, key)) return b;
    return null;
}

/// The built-in adapter for `path`, its launch body derived, on the
/// frame arena. Null when no row matches the file's grammar; a row
/// that cannot derive its body (a `.cs` with no project above it)
/// fails with the reason.
fn builtinAdapterFor(app: *App, path: []const u8) CommandError!?Found {
    const arena = app.frame.allocator();
    const key = syntax.keyForPath(path) orelse return null;
    const b = builtinFor(key) orelse return null;
    const body = switch (b.launch) {
        .dotnet_project => blk: {
            const start = std.fs.path.dirname(path) orelse app.workspace;
            const proj = (try dotnet.find(app.io, arena, start, app.workspace)) orelse
                return app.diag.fail(arena, "dap: no *.csproj found at or above {s} — the built-in netcoredbg adapter needs one", .{app.relPath(path)});
            const csproj = proj.csproj orelse
                return app.diag.fail(arena, "dap: only a .sln above {s} — the built-in netcoredbg adapter needs the project's .csproj", .{app.relPath(path)});
            const text = Io.Dir.cwd().readFileAlloc(app.io, csproj, arena, .limited(1 << 20)) catch "";
            break :blk try dotnet.launchBody(arena, csproj, text);
        },
    };
    return .{ .name = b.key, .cfg = .{ .cmd = b.cmd, .args = b.args }, .body = body };
}

/// The adapter for `path`: the config's, the config re-read, then a
/// built-in row.
fn resolveAdapter(app: *App, path: []const u8) CommandError!Found {
    const arena = app.frame.allocator();
    if (adapterFor(app, path)) |f| return f;
    try refreshAdapters(app);
    if (adapterFor(app, path)) |f| return f;
    if (try builtinAdapterFor(app, path)) |f| return f;
    const ext = std.fs.path.extension(path);
    return app.diag.fail(arena, "dap: no .dap.{s} adapter in config", .{if (ext.len > 1) ext[1..] else "<ext>"});
}

/// `dap.run`: spawn the adapter for the active file and start the
/// handshake. One session at a time — a live one is dropped first.
pub fn run(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const ep = try editorWithPath(app);
    return launchFile(app, try arena.dupe(u8, ep.path));
}

fn launchFile(app: *App, path: []const u8) CommandError!void {
    const found = try resolveAdapter(app, path);
    if (found.cfg.cmd.len == 0) return app.diag.fail(app.frame.allocator(), "dap: .dap.{s} has no cmd", .{found.name});
    return startSession(app, found.cfg, path, found.body);
}

// ─── dotnet.debug: build, then launch ───────────────────────────────────

pub const PendingLaunch = struct { pane: PaneId, file: []u8 };

/// `dotnet.debug`: `dotnet build` in a task pane at the project (or
/// solution), then — once it exits 0 — the session on the active
/// `.cs` file (`pollPendingLaunch`). A failed build says so and
/// launches nothing; a second `dotnet.debug` replaces the wait.
pub fn dotnetDebug(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const ep = try editorWithPath(app);
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(ep.path), ".cs")) return app.diag.fail(arena, "dotnet.debug: {s} is not a .cs file", .{app.relPath(ep.path)});
    const start = std.fs.path.dirname(ep.path) orelse app.workspace;
    const proj = (try dotnet.find(app.io, arena, start, app.workspace)) orelse
        return app.diag.fail(arena, "dotnet.debug: no *.csproj / *.sln found in {s} or any parent", .{app.workspace});
    if (!runners.onPath(app, "dotnet")) return runners.offerInstall(app, "dotnet");
    const file = try app.gpa.dupe(u8, ep.path);
    errdefer app.gpa.free(file);
    const root = try arena.dupe(u8, proj.buildRoot());
    const pane = try runners.spawn(app, "dotnet build", "dotnet build", root, .task);
    clearPendingLaunch(app);
    app.dap.pending_launch = .{ .pane = pane, .file = file };
    app.toast("dotnet build — the debugger starts when it succeeds", .{});
}

fn clearPendingLaunch(app: *App) void {
    if (app.dap.pending_launch) |pl| app.gpa.free(pl.file);
    app.dap.pending_launch = null;
}

/// Every tick: the build pane `dotnet.debug` waits on has exited (or
/// is gone). Exit 0 launches; anything else is a toast.
pub fn pollPendingLaunch(app: *App) void {
    const pl = app.dap.pending_launch orelse return;
    const pane = app.panes.get(pl.pane) orelse return clearPendingLaunch(app);
    const p = switch (pane.*) {
        .pty => |*p| p,
        else => return clearPendingLaunch(app),
    };
    const exit = p.exit orelse return;
    const file = pl.file;
    app.dap.pending_launch = null;
    defer app.gpa.free(file);
    if (!exit.ok()) {
        app.toast("dotnet build failed — not launching the debugger", .{});
        return;
    }
    const path = app.frame.allocator().dupe(u8, file) catch return;
    launchFile(app, path) catch |err| {
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("dap: {s}", .{@errorName(err)});
        app.diag.clear();
    };
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
    const s = Session.spawn(app.gpa, app.io, app.events, id, argv.items, app.workspace, &app.env, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return app.diag.fail(arena, "dap spawn failed: {s} not found on PATH", .{cfg.cmd}),
        else => return app.diag.fail(arena, "dap spawn failed: {s}", .{@errorName(err)}),
    };
    app.dap.session = s;
    s.initialize() catch |err| {
        endSession(app);
        return app.diag.fail(arena, "dap init failed: {s}", .{@errorName(err)});
    };
    const remembered = try app.gpa.dupe(u8, file);
    if (app.dap.last_file) |old| app.gpa.free(old);
    app.dap.last_file = remembered;
    try consoleNote(app, "started {s}", .{std.fs.path.basename(file)});
    app.toast("dap: spawned {s} adapter", .{cfg.cmd});
}

/// `dap.restart`: the last session's file again — VS Code's ↻. Without
/// a session to remember, the active file.
pub fn restart(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const file = if (app.dap.last_file) |f| try arena.dupe(u8, f) else (try editorWithPath(app)).path;
    const found = adapterFor(app, file) orelse (try builtinAdapterFor(app, file)) orelse return app.diag.fail(arena, "dap: no adapter for {s}", .{std.fs.path.basename(file)});
    // `Session.terminate` is a no-op for an attached session; the
    // `disconnect` inside `startSession`'s `endSession` releases it.
    if (app.dap.session) |s| s.terminate() catch {};
    try startSession(app, found.cfg, file, found.body);
    app.toast("dap: restarted", .{});
}

/// `dap.evaluate_hover` (vim `K` while stopped, `<leader>dh`): the
/// word under the cursor, evaluated in the current frame, into the
/// hover box. False when there is nothing to evaluate here, so the
/// LSP hover can have the key.
pub fn hoverAtCursor(app: *App) CommandError!bool {
    const s = app.dap.session orelse return false;
    if (s.stopped == null) return false;
    const pane = app.active orelse return false;
    const e = app.panes.editor(pane) orelse return false;
    const ed = e.buf.editor;
    const r = find_mod.wordAt(ed.bytes(), ed.cursor) orelse return false;
    const word = try app.frame.allocator().dupe(u8, ed.bytes()[r.start..r.end]);
    app.dap.hover_at = .{ .pane = pane, .byte = r.start };
    _ = s.evaluate(word, .hover) catch |err| return app.diag.fail(app.frame.allocator(), "dap evaluate: {s}", .{@errorName(err)});
    return true;
}

pub fn evaluateHover(app: *App) CommandError!void {
    if (try hoverAtCursor(app)) return;
    if (app.dap.session == null or app.dap.session.?.stopped == null) return app.diag.fail(app.frame.allocator(), "dap: not stopped", .{});
    return app.diag.fail(app.frame.allocator(), "dap: no word under the cursor", .{});
}

/// The stopped frame's variable named `word`, from the scopes the last
/// stop fetched (no round trip): its scope, type and value.
pub const KnownValue = struct { scope: []const u8, ty: ?[]const u8, value: []const u8 };

pub fn valueOfWord(app: *App, word: []const u8) ?KnownValue {
    const s = app.dap.session orelse return null;
    if (s.stopped == null) return null;
    for (s.scopes) |sc| {
        const vars = s.variables.get(sc.variables_reference) orelse continue;
        for (vars) |v| if (std.mem.eql(u8, v.name, word)) return .{ .scope = sc.name, .ty = v.ty, .value = v.value };
    }
    return null;
}

/// The hover tip for an editor cell while stopped: `x: int = 1` with
/// the scope beneath; null when the word under the cell is not a
/// variable of the stop (the caller paints its usual tip).
pub fn hoverValue(app: *App, arena: Allocator, pane: PaneId, line: u32, col: u32) Allocator.Error!?@import("../ui/tooltip.zig").Tip {
    const s = app.dap.session orelse return null;
    if (s.stopped == null) return null;
    const e = app.panes.editor(pane) orelse return null;
    const ed = e.buf.editor;
    if (line >= ed.lineCount()) return null;
    const byte = @min(ed.lineStart(line) + col, ed.lineEnd(line));
    const r = find_mod.wordAt(ed.bytes(), byte) orelse return null;
    const word = ed.bytes()[r.start..r.end];
    const known = valueOfWord(app, word) orelse return null;
    return .{
        .title = if (known.ty) |t| try std.fmt.allocPrint(arena, "{s}: {s} = {s}", .{ word, t, known.value }) else try std.fmt.allocPrint(arena, "{s} = {s}", .{ word, known.value }),
        .detail = try std.fmt.allocPrint(arena, "{s} \u{B7} debugger value \u{B7} right-click the gutter: breakpoints", .{known.scope}),
    };
}

/// The debugger's current line in `e`'s file, for the row band.
pub fn stoppedLine(app: *App, e: *EditorPane) ?u32 {
    const a = app.dap.arrow orelse return null;
    if (a.pane) |pid| return if (sourcePane(app, pid, a.path) == e) a.line else null;
    const path = e.buf.doc.path orelse return null;
    return if (std.mem.eql(u8, a.path, path)) a.line else null;
}

/// Inline values (`editor.inline_values`): while stopped in `e`'s file,
/// every line from a screenful above the stop down to it gets
/// `  name = value` after its text for each variable of the stop named
/// on it (whole words, once each), dimmed. Sorted by byte. Frame arena.
pub fn inlineValuesFor(app: *App, arena: Allocator, e: *EditorPane, theme: *const Theme) Allocator.Error![]editor_view.VirtualText {
    if (!app.cfg.editor.inline_values) return &.{};
    const s = app.dap.session orelse return &.{};
    if (s.stopped == null) return &.{};
    const stop = stoppedLine(app, e) orelse return &.{};
    const ed = e.buf.editor;
    if (stop >= ed.lineCount()) return &.{};
    var names: std.ArrayListUnmanaged(struct { name: []const u8, value: []const u8 }) = .empty;
    for (s.scopes) |sc| {
        const vars = s.variables.get(sc.variables_reference) orelse continue;
        for (vars) |v| {
            var seen = false;
            for (names.items) |n| if (std.mem.eql(u8, n.name, v.name)) {
                seen = true;
            };
            if (!seen and v.name.len > 0) try names.append(arena, .{ .name = v.name, .value = v.value });
        }
    }
    if (names.items.len == 0) return &.{};
    var style = theme.muted;
    style.italic = true;
    var out: std.ArrayListUnmanaged(editor_view.VirtualText) = .empty;
    const text = ed.bytes();
    const first: u32 = stop -| 60;
    var line = first;
    while (line <= stop) : (line += 1) {
        const ls = ed.lineStart(line);
        const le = ed.lineEnd(line);
        const lt = text[ls..le];
        var parts: std.ArrayListUnmanaged(u8) = .empty;
        for (names.items) |n| if (hasWord(lt, n.name)) {
            try parts.appendSlice(arena, if (parts.items.len == 0) "  " else ", ");
            try parts.print(arena, "{s} = {s}", .{ n.name, n.value });
        };
        if (parts.items.len > 0) try out.append(arena, .{ .byte = le, .text = parts.items, .style = style });
    }
    return out.items;
}

fn hasWord(text: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (i + word.len <= text.len) {
        const at = std.mem.indexOfPos(u8, text, i, word) orelse return false;
        const before_ok = at == 0 or !find_mod.isWord(text[at - 1]);
        const after_ok = at + word.len >= text.len or !find_mod.isWord(text[at + word.len]);
        if (before_ok and after_ok) return true;
        i = at + 1;
    }
    return false;
}

/// `dap.toggle_section` on a composite variable: expand or collapse it.
pub fn toggleExpand(app: *App, row: types.VarRow) CommandError!void {
    const s = app.dap.session orelse return;
    if (!row.expandable) return;
    if (row.expanded) {
        _ = s.expanded.remove(row.var_ref);
    } else {
        try s.expanded.put(app.gpa, row.var_ref, {});
        if (!s.variables.contains(row.var_ref)) s.requestVariables(row.var_ref) catch {};
    }
    app.needs_render = true;
}

/// A frame in the call stack: the scopes follow it, evaluations
/// address it, the editor jumps to it.
pub fn selectFrame(app: *App, idx: usize) CommandError!void {
    const s = try requireStopped(app);
    if (idx >= s.frames.len) return app.diag.fail(app.frame.allocator(), "dap: no frame {d}", .{idx});
    const f = s.frames[idx];
    s.frame_id = f.id;
    s.scopes = &.{};
    s.variables.clearRetainingCapacity();
    s.requestScopes(f.id) catch {};
    evaluateWatches(app);
    try openFrame(app, s, f);
    app.needs_render = true;
}

pub fn selectThread(app: *App, id: i64) CommandError!void {
    const s = app.dap.session orelse return app.diag.fail(app.frame.allocator(), "no DAP session", .{});
    s.thread = id;
    s.requestStackTrace(id) catch {};
    app.toast("dap: thread {d}", .{id});
    app.needs_render = true;
}

/// An exception filter row's checkbox.
/// Flip an exception filter on the live session, and remember the
/// choice for the sessions after it.
pub fn toggleFilter(app: *App, id: []const u8) CommandError!void {
    const s = app.dap.session orelse return app.diag.fail(app.frame.allocator(), "no DAP session", .{});
    const on = try s.toggleFilter(id);
    try rememberFilter(app, id, on);
    s.setExceptionBreakpoints() catch |err| app.toast("dap setExceptionBreakpoints: {s}", .{@errorName(err)});
    app.toast("exception {s}: {s}", .{ id, if (on) "on" else "off" });
    app.needs_render = true;
}

fn rememberFilter(app: *App, id: []const u8, on: bool) Allocator.Error!void {
    const gop = try app.dap.filter_overrides.getOrPut(app.gpa, id);
    if (!gop.found_existing) {
        gop.key_ptr.* = app.gpa.dupe(u8, id) catch |err| {
            _ = app.dap.filter_overrides.remove(id);
            return err;
        };
    }
    gop.value_ptr.* = on;
}

fn requireStopped(app: *App) CommandError!*Session {
    const s = app.dap.session orelse return app.diag.fail(app.frame.allocator(), "no DAP session (run dap.run first)", .{});
    if (s.stopped == null) return app.diag.fail(app.frame.allocator(), "dap: not stopped", .{});
    return s;
}

/// The step / resume family: a thread-addressed request, failures toasted.
pub fn threadCommand(app: *App, kind: client.ReqKind, verb: []const u8) CommandError!void {
    // nvim-dap's `continue()`: without a session it starts one.
    if (kind == .@"continue" and app.dap.session == null) return run(app);
    const s = if (kind == .pause) (app.dap.session orelse return app.diag.fail(app.frame.allocator(), "no DAP session (run dap.run first)", .{})) else try requireStopped(app);
    s.threadRequest(kind, verb) catch |err| return app.diag.fail(app.frame.allocator(), "dap {s}: {s}", .{ verb, @errorName(err) });
}

/// `dap.terminate` (Stop): a launched program is ended; an attached one
/// is detached from and keeps running — `terminate` is not sent and
/// the `disconnect` says `terminateDebuggee: false`.
pub fn terminate(app: *App) CommandError!void {
    const s = app.dap.session orelse return app.diag.fail(app.frame.allocator(), "no DAP session", .{});
    const attached = s.is_attach;
    s.terminate() catch {};
    endSession(app);
    if (attached) app.toast("dap: detached (the process keeps running)", .{}) else app.toast("dap: terminated", .{});
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
            const id = if (std.mem.indexOf(u8, detail, " · ")) |i| detail[0..i] else detail;
            toggleFilter(app, id) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
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
            .evaluate_repl, .evaluate_watch, .evaluate_hover, .set_breakpoints => {},
            .disconnect, .terminate, .cancel => return,
            else => app.toast("dap {s}: {s}", .{ @tagName(kind), message orelse "failed" }),
        }
    }
    switch (kind) {
        .initialize => {
            try s.setCapabilities(body, &app.dap.filter_overrides);
            s.ready = true;
            // `launch` / `attach` goes out on this reply, not on
            // `initialized`: lldb-dap and debugpy send `initialized`
            // only while handling `launch`, so a client that waited for
            // the event first never started (hunt: dap-launch-never-sent).
            s.launch() catch |err| app.toast("dap launch: {s}", .{@errorName(err)});
            // netcoredbg's `initialized` came before this reply: the
            // filters were not known then, so the configuration step
            // runs now, with them.
            if (s.initialized) configure(app, s);
        },
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
                try openFrame(app, s, top);
            }
        },
        .source => {
            // The text of a frame that has no file, asked for by
            // `openFrame`; the reference rides back as the context.
            const ref: i64 = @bitCast(ctx);
            if (!success) {
                app.toast("dap: no source for the frame ({s})", .{message orelse "the adapter has none"});
                return;
            }
            const b = body orelse return;
            const content = jsonrpc.getStr(b, "content") orelse return;
            const f = frameForSource(s, ref) orelse return;
            try showFetchedSource(app, f.source orelse f.name, content, f.line -| 1);
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
            try consoleResult(app, expr, success, message, body);
            // A console line may have changed the program (`total = 7`,
            // a call with side effects): the DAP guidance for
            // `context: "repl"` is to re-fetch what the panel shows.
            // Variable references stay valid until the next resume,
            // so the expanded nodes are asked again in place, the
            // watches re-evaluated, and the inline values — read off
            // the same scopes — follow (hunt: dap-repl-assignment-stale).
            if (success) refreshAfterEvaluate(app, s);
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
        .set_breakpoints => {
            const path = s.takeBpPath(ctx) orelse return;
            defer app.gpa.free(path);
            if (!success) return;
            const list = app.dap.breakpoints.getPtr(path) orelse return;
            const replies: []const jsonrpc.Value = if (body) |b| jsonrpc.getArr(b, "breakpoints") orelse &.{} else &.{};
            var i: usize = 0;
            for (list.items) |*b| if (b.enabled) {
                b.verified = if (i < replies.len) (jsonrpc.getBool(replies[i], "verified") orelse true) else null;
                i += 1;
            };
        },
        .evaluate_hover => {
            const expr = s.takeEval(ctx) orelse return;
            defer app.gpa.free(expr);
            const at = app.dap.hover_at orelse return;
            app.dap.hover_at = null;
            const arena = app.frame.allocator();
            const line: []const u8 = if (success) blk: {
                const value = if (body) |b| jsonrpc.getStr(b, "result") orelse "" else "";
                const ty = if (body) |b| jsonrpc.getStr(b, "type") else null;
                break :blk if (ty) |t| try std.fmt.allocPrint(arena, "{s}: {s} = {s}", .{ expr, t, value }) else try std.fmt.allocPrint(arena, "{s} = {s}", .{ expr, value });
            } else try std.fmt.allocPrint(arena, "{s}: {s}", .{ expr, message orelse "cannot evaluate" });
            try lsp.showHoverLines(app, at.pane, at.byte, &.{line});
        },
        else => {},
    }
}

fn handleEvent(app: *App, s: *Session, name: []const u8, body: ?jsonrpc.Value) Allocator.Error!void {
    if (std.mem.eql(u8, name, "initialized")) {
        s.initialized = true;
        if (s.ready) configure(app, s);
    } else if (std.mem.eql(u8, name, "stopped")) {
        const b = body orelse return;
        const thread = jsonrpc.getInt(b, "threadId") orelse s.thread orelse 1;
        const reason = jsonrpc.getStr(b, "reason") orelse "stopped";
        // `text` is the exception's type (`ZeroDivisionError`),
        // `description` its message: the label says both (hunt:
        // dap-exception-stop-drops-type).
        try s.setStopped(thread, reason, jsonrpc.getStr(b, "description"), jsonrpc.getStr(b, "text"));
        s.requestStackTrace(thread) catch {};
        s.requestThreads() catch {};
        app.toast("dap: stopped ({s})", .{s.stopped.?.label()});
        // The toast goes; an exception's type and message stay in the
        // console, where the program's own last words are.
        if (std.mem.eql(u8, reason, "exception")) try consoleNote(app, "exception \u{2014} {s}", .{s.stopped.?.label()});
    } else if (std.mem.eql(u8, name, "continued")) {
        try debug_panel.snapshotValues(app);
        s.onResumed();
        s.clearWatchResults();
        clearArrow(app);
    } else if (std.mem.eql(u8, name, "output")) {
        const b = body orelse return;
        const category = jsonrpc.getStr(b, "category") orelse "console";
        // `telemetry` is the adapter reporting on itself (debugpy sends
        // `ptvsd` / `debugpy` with a package version at every start),
        // not something the program said: VS Code drops it, and so does
        // the console (hunt: dap-console-shows-telemetry-output).
        if (std.mem.eql(u8, category, "telemetry")) return;
        const text = jsonrpc.getStr(b, "output") orelse "";
        try s.appendOutput(category, text);
        try consoleOutput(app, category, text);
        if (std.mem.eql(u8, category, "stderr") or std.mem.eql(u8, category, "important")) {
            const first = std.mem.trimEnd(u8, text[0..(std.mem.indexOfScalar(u8, text, '\n') orelse text.len)], "\r");
            if (first.len > 0) app.toast("dap[{s}]: {s}", .{ category, first[0..@min(first.len, 80)] });
        }
    } else if (std.mem.eql(u8, name, "exited")) {
        const code = if (body) |b| jsonrpc.getInt(b, "exitCode") orelse 0 else 0;
        app.toast("dap: exited (code {d})", .{code});
        try consoleNote(app, "exited (code {d})", .{code});
        s.exited = true;
        clearArrow(app);
    } else if (std.mem.eql(u8, name, "terminated")) {
        if (!s.exited) {
            app.toast("dap: session ended", .{});
            try consoleNote(app, "session ended", .{});
        }
        s.exited = true;
        endSession(app);
    }
}

/// Ask again for every expanded scope and composite, and the watches.
fn refreshAfterEvaluate(app: *App, s: *Session) void {
    if (s.stopped == null) return;
    var it = s.expanded.keyIterator();
    while (it.next()) |ref| s.requestVariables(ref.*) catch {};
    evaluateWatches(app);
}

/// The configuration step, once `initialized` has arrived AND the
/// `initialize` reply has landed (either order): every file's
/// breakpoints, the exception filters, then `configurationDone`.
fn configure(app: *App, s: *Session) void {
    if (s.configured) return;
    syncAllBreakpoints(app);
    if (s.filters.items.len > 0) s.setExceptionBreakpoints() catch {};
    s.configurationDone() catch {};
}

/// Show where a frame is: its file — or, for a `source_ref`, the text
/// the adapter holds for it, asked with `source` and shown read-only
/// when it answers. lldb-dap names such a frame `/usr/lib/dyld`start`;
/// opening that PATH made an empty file the user could `:w`
/// (hunt: dap-sourceref-frame-opens-empty-file).
fn openFrame(app: *App, s: *Session, f: types.StackFrame) Allocator.Error!void {
    if (f.source_ref > 0) {
        clearArrow(app);
        s.requestSource(f.source_ref) catch {};
        app.needs_render = true;
        return;
    }
    if (f.source) |src| try jumpTo(app, src, f.line -| 1);
}

/// The frame a `source` reply is for: the selected one when it has
/// that reference, else the first that does.
fn frameForSource(s: *Session, ref: i64) ?types.StackFrame {
    if (s.frame_id) |id| for (s.frames) |f| if (f.id == id and f.source_ref == ref) return f;
    for (s.frames) |f| if (f.source_ref == ref) return f;
    return null;
}

/// `content` in a read-only pane titled `name` — the one already
/// holding it when there is one — with the ▶ on `line`.
fn showFetchedSource(app: *App, name: []const u8, content: []const u8, line: u32) Allocator.Error!void {
    const id: PaneId = blk: {
        if (app.dap.source_panes.get(name)) |id| if (sourcePane(app, id, name) != null) {
            app.showPane(id);
            break :blk id;
        };
        const id = app.openScratchWith(content) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        const e = app.panes.editor(id) orelse return;
        e.buf.doc.read_only = true;
        e.label = try app.gpa.dupe(u8, name);
        const gop = try app.dap.source_panes.getOrPut(app.gpa, name);
        if (!gop.found_existing) gop.key_ptr.* = try app.gpa.dupe(u8, name);
        gop.value_ptr.* = id;
        break :blk id;
    };
    const copy = try app.gpa.dupe(u8, name);
    clearArrow(app);
    app.dap.arrow = .{ .path = copy, .line = line, .pane = id };
    if (app.panes.editor(id)) |e| {
        const ed = e.buf.editor;
        ed.anchor = null;
        ed.placeCursor(@min(line, @as(u32, @intCast(ed.lineCount() -| 1))), 0);
        e.view.scroll_line = @intCast(ed.currentLine() -| app.pane_rows / 2);
    }
    app.needs_render = true;
}

/// The pane holding a frame's fetched text, when `id` still is that
/// pane: pane ids are reused after a close, so an editor at the id
/// with a path, or another label, is some other pane.
fn sourcePane(app: *App, id: PaneId, name: []const u8) ?*EditorPane {
    const e = app.panes.editor(id) orelse return null;
    if (e.buf.doc.path != null) return null;
    const label = e.label orelse return null;
    return if (std.mem.eql(u8, label, name)) e else null;
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

// ─── the console pane ───────────────────────────────────────────────────

/// Open (or reveal) the debug pane beside the active one.
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

/// `dap.show`: the DEBUG section in its column and the console pane
/// beside the editor — the whole debug layout in one go.
pub fn showDebug(app: *App) CommandError!void {
    activity_bar.enter(app, .debug);
    side.place(app, .debug, false);
    return openSingleton(app, .debug, .{ .debug = .{} });
}

/// `dap.repl`: focus the console (its input row).
pub fn openRepl(app: *App) CommandError!void {
    return openSingleton(app, .debug, .{ .debug = .{} });
}

/// `dap.clear_console`.
pub fn clearConsole(app: *App) CommandError!void {
    const c = &app.dap.console;
    for (c.entries.items) |*e| e.deinit(app.gpa);
    c.entries.clearRetainingCapacity();
    c.scroll = 0;
    app.needs_render = true;
}

fn consoleAppend(app: *App, entry: ConsoleEntry) Allocator.Error!void {
    const c = &app.dap.console;
    if (c.entries.items.len >= Console.max_entries) {
        var first = c.entries.orderedRemove(0);
        first.deinit(app.gpa);
    }
    try c.entries.append(app.gpa, entry);
    app.needs_render = true;
}

/// A session note: `── started prog.dbg ──`.
fn consoleNote(app: *App, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const text = try std.fmt.allocPrint(app.gpa, "\u{2500}\u{2500} " ++ fmt ++ " \u{2500}\u{2500}", args);
    errdefer app.gpa.free(text);
    try consoleAppend(app, .{ .note = text });
}

/// Every non-empty line of an `output` event.
fn consoleOutput(app: *App, category: []const u8, text: []const u8) Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const cat = try app.gpa.dupe(u8, category);
        errdefer app.gpa.free(cat);
        const copy = try app.gpa.dupe(u8, line);
        errdefer app.gpa.free(copy);
        try consoleAppend(app, .{ .output = .{ .category = cat, .text = copy } });
    }
}

/// What the toolbar shows for the session.
pub fn sessionState(app: *const App) toolbar.SessionState {
    const s = app.dap.session orelse return .none;
    if (s.stopped != null) return .stopped;
    return .running;
}

/// The editor pane that carries the toolbar strip this frame, or
/// null: `ui.debug_toolbar` hidden, `auto` without a session, or no
/// editor to carry it. The active editor; else the one showing the
/// stopped file.
pub fn stripPane(app: *App) ?PaneId {
    switch (app.cfg.ui.debug_toolbar) {
        .hidden => return null,
        .auto => if (app.dap.session == null) return null,
        .always => {},
    }
    if (app.active) |a| if (app.panes.editor(a) != null) return a;
    if (app.dap.arrow) |ar| {
        if (ar.pane) |pid| return if (sourcePane(app, pid, ar.path) != null) pid else null;
        return app.panes.findPath(ar.path);
    }
    return null;
}

/// A toolbar button, from the pane or the editor's strip.
pub fn toolbarAction(app: *App, action: toolbar.Action) CommandError!void {
    const id: command.CommandId = switch (action) {
        .@"continue" => switch (sessionState(app)) {
            .none => .@"dap.run",
            .running => .@"dap.pause",
            .stopped => .@"dap.continue",
        },
        .step_over => .@"dap.next",
        .step_into => .@"dap.step_in",
        .step_out => .@"dap.step_out",
        .restart => .@"dap.restart",
        .stop => .@"dap.terminate",
    };
    return command.run(app, .{ .static = id });
}

/// The scrollback flattened to painted lines. Frame arena.
fn consoleLines(app: *App, arena: Allocator) Allocator.Error![]dap_view.Line {
    var out: std.ArrayListUnmanaged(dap_view.Line) = .empty;
    for (app.dap.console.entries.items, 0..) |e, i| {
        const idx: u32 = @intCast(i);
        switch (e) {
            .output => |o| try out.append(arena, .{
                .kind = if (std.mem.eql(u8, o.category, "stderr")) .stderr else if (std.mem.eql(u8, o.category, "stdout")) .stdout else .console,
                .text = o.text,
            }),
            .note => |n| try out.append(arena, .{ .kind = .note, .text = n }),
            .eval => |ev| {
                try out.append(arena, .{ .kind = .echo, .text = ev.expression, .entry = idx });
                if (ev.pending) {
                    try out.append(arena, .{ .kind = .pending, .text = "  (evaluating\u{2026})", .entry = idx });
                } else if (ev.err) |err| {
                    // Every line: lldb's diagnostic is on the second
                    // line of its message, a Python traceback's last
                    // (hunt: dap-repl-multiline-result).
                    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, err, "\n"), '\n');
                    var first = true;
                    while (lines.next()) |line| : (first = false) {
                        const text = if (first) try std.fmt.allocPrint(arena, "  err: {s}", .{line}) else try std.fmt.allocPrint(arena, "  {s}", .{std.mem.trimEnd(u8, line, "\r")});
                        try out.append(arena, .{ .kind = .err, .text = text, .entry = idx });
                    }
                } else {
                    // A foldable result carries its expander; the view
                    // paints it before the text. A result of several
                    // lines (`bt`, `frame variable`, `p` of a struct)
                    // is one row each, the type after the first.
                    const folds = ev.variables_ref > 0;
                    const indent: []const u8 = if (folds) "" else "  ";
                    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, ev.value, "\n"), '\n');
                    const head = lines.next() orelse "";
                    const text = if (ev.ty) |ty| try std.fmt.allocPrint(arena, "{s}{s} : {s}", .{ indent, head, ty }) else try std.fmt.allocPrint(arena, "{s}{s}", .{ indent, head });
                    try out.append(arena, .{ .kind = .result, .text = text, .entry = idx, .fold = if (folds) ev.expanded else null });
                    while (lines.next()) |line| {
                        try out.append(arena, .{ .kind = .result, .text = try std.fmt.allocPrint(arena, "  {s}", .{std.mem.trimEnd(u8, line, "\r")}), .entry = idx });
                    }
                    if (ev.expanded and ev.variables_ref > 0) {
                        if (app.dap.session) |s| if (s.variables.get(ev.variables_ref)) |kids| {
                            for (kids) |k| {
                                const kl = if (k.ty) |ty| try std.fmt.allocPrint(arena, "      {s} : {s} = {s}", .{ k.name, ty, k.value }) else try std.fmt.allocPrint(arena, "      {s} = {s}", .{ k.name, k.value });
                                try out.append(arena, .{ .kind = .child, .text = kl, .entry = idx });
                            }
                            continue;
                        };
                        try out.append(arena, .{ .kind = .pending, .text = "      (fetching children\u{2026})", .entry = idx });
                    }
                }
            },
        }
    }
    return out.items;
}

pub fn drawDebug(app: *App, ui: Ui, id: PaneId, p: *DebugPane, area: Rect) Allocator.Error!void {
    _ = p;
    const c = &app.dap.console;
    const lines = try consoleLines(app, ui.arena);
    if (c.scroll > lines.len -| 1) c.scroll = lines.len -| 1;
    if (app.active == id) app.pane_rows = @max(area.h, 1);
    const caret = dap_view.draw(ui, id, area, .{
        .lines = lines,
        .scroll = c.scroll,
        .input = c.input.items,
        .caret = c.caret,
        .state = sessionState(app),
        .focused = paneFocused(app, id),
    });
    if (paneFocused(app, id)) if (caret) |cr| {
        app.cursor_pos = .{ .x = cr.x, .y = cr.y };
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

/// The console's keys: the input row's editing, Enter submits, ↑↓ walk
/// the history, Tab completes a variable name, PageUp / PageDown and
/// Ctrl+U/D scroll the scrollback, Ctrl+L clears it, Esc leaves. False
/// lets the chord chain see the key.
pub fn debugKey(app: *App, id: PaneId, p: *DebugPane, k: Key) Allocator.Error!bool {
    _ = id;
    _ = p;
    const gpa = app.gpa;
    const c = &app.dap.console;
    const page = @max(app.pane_rows / 2, 1);
    if (k.mods.ctrl or k.mods.alt or k.mods.super) {
        if (!k.mods.ctrl or k.code != .char) return false;
        switch (k.code.char) {
            'u', 'w', 'a', 'e', 'k' => {
                _ = try text_field.handleKey(&c.input, &c.caret, gpa, k);
                c.clearCompletion(gpa);
            },
            'l' => clearConsole(app) catch {},
            'd' => c.scroll -|= page,
            'b' => c.scroll += page,
            else => return false,
        }
        app.needs_render = true;
        return true;
    }
    app.needs_render = true;
    switch (k.code) {
        .enter => try consoleSubmit(app),
        .tab => try consoleComplete(app),
        .up => historyWalk(c, gpa, -1),
        .down => historyWalk(c, gpa, 1),
        .page_up => c.scroll += page,
        .page_down => c.scroll -|= page,
        .esc => leaveToEditor(app),
        else => {
            _ = try text_field.handleKey(&c.input, &c.caret, gpa, k);
            c.clearCompletion(gpa);
        },
    }
    return true;
}

/// Submit the input: an entry in the scrollback, `evaluate` with
/// `context: "repl"`, or "no DAP session" when there is none.
fn consoleSubmit(app: *App) Allocator.Error!void {
    const gpa = app.gpa;
    const c = &app.dap.console;
    c.clearCompletion(gpa);
    const expr = std.mem.trim(u8, c.input.items, " \t");
    if (expr.len == 0) return;
    var entry: types.ReplEntry = .{ .expression = try gpa.dupe(u8, expr), .pending = true };
    errdefer entry.deinit(gpa);
    if (c.commands.getLastOrNull() == null or !std.mem.eql(u8, c.commands.getLastOrNull().?, expr)) {
        try c.commands.append(gpa, try gpa.dupe(u8, expr));
    }
    c.cmd_idx = null;
    c.scroll = 0;
    if (app.dap.session) |s| {
        if (s.stopped == null) {
            try entry.setResult(gpa, "", null, "dap: not stopped", 0);
        } else _ = s.evaluate(expr, .repl) catch |err| {
            try entry.setResult(gpa, "", null, @errorName(err), 0);
        };
    } else {
        try entry.setResult(gpa, "", null, "no DAP session (run dap.run first)", 0);
    }
    try consoleAppend(app, .{ .eval = entry });
    c.input.clearRetainingCapacity();
    c.caret = 0;
}

/// A reply for `expr` lands on the oldest pending entry with that text.
fn consoleResult(app: *App, expr: []const u8, success: bool, message: ?[]const u8, body: ?jsonrpc.Value) Allocator.Error!void {
    for (app.dap.console.entries.items) |*e| if (e.* == .eval and e.eval.pending and std.mem.eql(u8, e.eval.expression, expr)) {
        if (success) {
            const value = if (body) |b| jsonrpc.getStr(b, "result") orelse "" else "";
            const ty = if (body) |b| jsonrpc.getStr(b, "type") else null;
            const vref = if (body) |b| jsonrpc.getInt(b, "variablesReference") orelse 0 else 0;
            try e.eval.setResult(app.gpa, value, ty, null, vref);
        } else try e.eval.setResult(app.gpa, "", null, message orelse "failed", 0);
        app.needs_render = true;
        return;
    };
}

/// ↑/↓ walk the submitted lines; past the newest the typed input is
/// restored (vim's cmdline convention).
fn historyWalk(c: *Console, gpa: Allocator, dir: i32) void {
    const h = c.commands.items;
    if (h.len == 0) return;
    const next: ?usize = if (dir < 0)
        (if (c.cmd_idx) |i| i -| 1 else h.len - 1)
    else
        (if (c.cmd_idx) |i| (if (i + 1 < h.len) i + 1 else null) else return);
    if (c.cmd_idx == null) {
        // The walk starts: keep what was typed.
        if (c.typed) |t| gpa.free(t);
        c.typed = gpa.dupe(u8, c.input.items) catch null;
    }
    c.input.clearRetainingCapacity();
    if (next) |i| {
        c.input.appendSlice(gpa, h[i]) catch {};
    } else if (c.typed) |t| {
        c.input.appendSlice(gpa, t) catch {};
        gpa.free(t);
        c.typed = null;
    }
    c.caret = c.input.items.len;
    c.cmd_idx = next;
}

/// The names Tab completes: every variable the session has fetched
/// (any scope, any expanded composite), the watches, sorted, unique.
/// Frame arena.
pub fn completionNames(app: *App, arena: Allocator) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (app.dap.session) |s| {
        var it = s.variables.valueIterator();
        while (it.next()) |vars| for (vars.*) |v| try out.append(arena, v.name);
    }
    for (app.dap.watches.items) |w| try out.append(arena, w);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var uniq: std.ArrayListUnmanaged([]const u8) = .empty;
    for (out.items) |n| if (uniq.getLastOrNull() == null or !std.mem.eql(u8, uniq.getLastOrNull().?, n)) try uniq.append(arena, n);
    return uniq.items;
}

/// Tab: the identifier fragment before the caret becomes the first
/// name that starts with it; Tab again cycles; any other key ends it.
fn consoleComplete(app: *App) Allocator.Error!void {
    const gpa = app.gpa;
    const c = &app.dap.console;
    if (c.completion) |*comp| {
        comp.idx = (comp.idx + 1) % comp.candidates.len;
        try applyCompletion(c, gpa);
        return;
    }
    // The fragment: identifier bytes before the caret.
    var start = c.caret;
    while (start > 0 and find_mod.isWord(c.input.items[start - 1])) start -= 1;
    const frag = c.input.items[start..c.caret];
    const names = try completionNames(app, app.frame.allocator());
    var cands: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (cands.items) |x| gpa.free(x);
        cands.deinit(gpa);
    }
    for (names) |n| if (std.mem.startsWith(u8, n, frag) and n.len > 0) try cands.append(gpa, try gpa.dupe(u8, n));
    if (cands.items.len == 0) {
        app.toast("no completion for \"{s}\"", .{frag});
        return;
    }
    c.completion = .{ .start = start, .candidates = try cands.toOwnedSlice(gpa), .idx = 0 };
    try applyCompletion(c, gpa);
}

fn applyCompletion(c: *Console, gpa: Allocator) Allocator.Error!void {
    const comp = c.completion orelse return;
    const name = comp.candidates[comp.idx];
    // Replace [start, caret) with the candidate.
    const tail = try gpa.dupe(u8, c.input.items[c.caret..]);
    defer gpa.free(tail);
    c.input.items.len = comp.start;
    try c.input.appendSlice(gpa, name);
    c.caret = c.input.items.len;
    try c.input.appendSlice(gpa, tail);
}

/// A click on the pane (`.script_hit`): a toolbar button, or an
/// evaluation's line (a composite folds / unfolds).
pub fn click(app: *App, id: PaneId, hit_id: u32) Allocator.Error!void {
    _ = id;
    if (toolbar.actionOf(hit_id)) |a| {
        toolbarAction(app, a) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (app.diag.msg) |m| app.toast("{s}", .{m});
                app.diag.clear();
            },
        };
        return;
    }
    if (hit_id == dap_view.input_hit) return;
    const c = &app.dap.console;
    if (hit_id >= c.entries.items.len) return;
    const e = &c.entries.items[hit_id];
    if (e.* != .eval or e.eval.variables_ref == 0) return;
    e.eval.expanded = !e.eval.expanded;
    if (e.eval.expanded) if (app.dap.session) |s| {
        if (!s.variables.contains(e.eval.variables_ref)) s.requestVariables(e.eval.variables_ref) catch {};
    };
    app.needs_render = true;
}

/// The wheel on the pane scrolls the scrollback.
pub fn scrollBy(app: *App, id: PaneId, delta: i32) Allocator.Error!void {
    _ = id;
    const c = &app.dap.console;
    if (delta < 0) c.scroll += @intCast(-delta) else c.scroll -|= @intCast(delta);
    app.needs_render = true;
}

/// `dap.set_variable`: the DEBUG section's selected variable row.
pub fn setVariablePrompt(app: *App) CommandError!void {
    const row = (try debug_panel.selectedVariable(app)) orelse return;
    return setVariableFor(app, row);
}

/// The prompt for one variable row, seeded with its value.
pub fn setVariableFor(app: *App, row: types.VarRow) CommandError!void {
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

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const screen_mod = @import("../ipc/screen.zig");

fn screenText(app: *App) ![]u8 {
    try app.render();
    return screen_mod.toTestText(testing.allocator, &app.screen);
}

test "consoleLines: a result or an error of several lines is one row each, the type after the first line, all rows the entry's" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    var bt: types.ReplEntry = .{ .expression = try app.gpa.dupe(u8, "bt") };
    try bt.setResult(app.gpa, "* thread #1, stop reason = breakpoint 1.1\n  * frame #0: main at main.c:22\n    frame #1: start\n", null, null, 0);
    try consoleAppend(&app, .{ .eval = bt });
    var nope: types.ReplEntry = .{ .expression = try app.gpa.dupe(u8, "nope") };
    try nope.setResult(app.gpa, "", null, "Expression evaluation in pure C not supported.\nerror: use of undeclared identifier 'nope'", 0);
    try consoleAppend(&app, .{ .eval = nope });
    var typed: types.ReplEntry = .{ .expression = try app.gpa.dupe(u8, "p") };
    try typed.setResult(app.gpa, "(point) {\n  x = 1\n  y = 2\n}", "point", null, 0);
    try consoleAppend(&app, .{ .eval = typed });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lines = try consoleLines(&app, arena.allocator());
    try testing.expectEqual(@as(usize, 4 + 3 + 5), lines.len);
    try testing.expectEqualStrings("bt", lines[0].text);
    try testing.expectEqualStrings("  * thread #1, stop reason = breakpoint 1.1", lines[1].text);
    try testing.expectEqualStrings("    * frame #0: main at main.c:22", lines[2].text);
    try testing.expectEqualStrings("      frame #1: start", lines[3].text);
    try testing.expectEqual(@as(?u32, 0), lines[3].entry);
    try testing.expectEqual(dap_view.Line.Kind.result, lines[3].kind);
    try testing.expectEqualStrings("  err: Expression evaluation in pure C not supported.", lines[5].text);
    try testing.expectEqualStrings("  error: use of undeclared identifier 'nope'", lines[6].text);
    try testing.expectEqual(dap_view.Line.Kind.err, lines[6].kind);
    try testing.expectEqual(@as(?u32, 1), lines[6].entry);
    try testing.expectEqualStrings("  (point) { : point", lines[8].text);
    try testing.expectEqualStrings("  }", lines[11].text);
}

test "a fetched source's pane: closed and its id taken by another buffer, the ▶ and the strip leave, and the next stop there makes a new pane; the same name reuses it" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 90, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    try showFetchedSource(&app, "start", "start:\n    call main\n    exit\n", 1);
    const first = app.dap.arrow.?.pane.?;
    try testing.expectEqualStrings("start", app.panes.get(first).?.title());
    try testing.expect(app.panes.editor(first).?.buf.doc.read_only);
    try testing.expectEqual(@as(?u32, 1), stoppedLine(&app, app.panes.editor(first).?));
    // The strip over the editor finds the pane by the arrow when no
    // editor is active (the console is).
    app.cfg.ui.debug_toolbar = .always;
    try command.run(&app, .{ .static = .@"dap.show" });
    try testing.expectEqual(@as(?PaneId, first), stripPane(&app));
    // The same frame again: the pane is reused, not doubled.
    try showFetchedSource(&app, "start", "start:\n    call main\n    exit\n", 2);
    try testing.expectEqual(first, app.dap.arrow.?.pane.?);
    try testing.expectEqual(@as(?u32, 2), stoppedLine(&app, app.panes.editor(first).?));
    // Closed, and a scratch buffer takes the freed id.
    try app.closePane(first, true);
    const taken = try app.openScratch();
    try testing.expectEqual(first, taken);
    const other = app.panes.editor(taken).?;
    try testing.expectEqual(@as(?u32, null), stoppedLine(&app, other));
    try command.run(&app, .{ .static = .@"dap.show" });
    try testing.expectEqual(@as(?PaneId, null), stripPane(&app));
    const marks = try marksForPane(&app, testing.allocator, taken, other, &app.theme, false);
    defer testing.allocator.free(marks);
    try testing.expectEqual(@as(usize, 0), marks.len);
    // The next stop in `start` gets a pane of its own, not the scratch.
    try showFetchedSource(&app, "start", "start:\n    call main\n    exit\n", 1);
    const again = app.dap.arrow.?.pane.?;
    try testing.expect(again != taken);
    try testing.expectEqual(again, app.dap.source_panes.get("start").?);
    try testing.expectEqualStrings("start", app.panes.get(again).?.title());
    try testing.expectEqual(@as(?u32, null), stoppedLine(&app, other));
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

test "gutter: the sign glyphs per breakpoint kind, a disabled or unverified one muted; the sign cell toggles on a left press, a right press opens the breakpoint menu" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/g.py");
    try e.buf.editor.setText("a = 1\nb = 2\nc = 3\nd = 4\n");
    try acceptCondition(&app, "/tmp/g.py", 0, "a > 0");
    try acceptLogMessage(&app, "/tmp/g.py", 1, "b is {b}");
    e.buf.editor.placeCursor(2, 0);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint_enabled" });
    try testing.expectEqualStrings("breakpoint line 3: disabled", app.lastToast().?);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const marks = try marksFor(&app, arena.allocator(), "/tmp/g.py", &app.theme, false);
    try testing.expectEqual(@as(usize, 3), marks.len);
    try testing.expectEqualStrings("\u{25D0}", marks[0].glyph);
    try testing.expectEqualStrings("\u{25C6}", marks[1].glyph);
    try testing.expectEqualStrings("\u{25CB}", marks[2].glyph);
    try testing.expect(std.meta.eql(marks[2].style, app.theme.muted));
    try testing.expect(std.meta.eql(marks[0].style, app.theme.error_fg));
    const ascii = try marksFor(&app, arena.allocator(), "/tmp/g.py", &app.theme, true);
    try testing.expectEqualStrings("#", ascii[0].glyph);
    try testing.expectEqualStrings("@", ascii[1].glyph);
    try testing.expectEqualStrings("o", ascii[2].glyph);
    // The gutter registers a hit per row; line 4's sign cell toggles.
    try app.render();
    var gutter: ?Rect = null;
    for (app.hits.items.items) |h| if (h.target == .gutter and h.target.gutter.line == 3) {
        gutter = h.rect;
    };
    const g = gutter.?;
    try app.handle(.{ .mouse = .{ .x = g.x, .y = g.y, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = g.x, .y = g.y, .kind = .release, .button = .left } });
    try testing.expectEqualStrings("breakpoint set: line 4", app.lastToast().?);
    try testing.expectEqual(@as(usize, 4), app.dap.bpsFor("/tmp/g.py").len);
    // The number cell is the margin too on a file that carries
    // breakpoints (`gutterToggles`): line 3's clears, the cursor parks
    // at its column 1; a second press sets it again.
    try app.handle(.{ .mouse = .{ .x = g.x + 1, .y = g.y - 1, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = g.x + 1, .y = g.y - 1, .kind = .release, .button = .left } });
    try testing.expectEqual(@as(usize, 3), app.dap.bpsFor("/tmp/g.py").len);
    try testing.expectEqualStrings("breakpoint cleared: line 3", app.lastToast().?);
    try testing.expectEqual(@as(usize, 2), e.buf.editor.currentLine());
    try testing.expectEqual(@as(usize, 0), e.buf.editor.rowCol().col);
    try app.handle(.{ .mouse = .{ .x = g.x + 1, .y = g.y - 1, .kind = .press, .button = .left } });
    try app.handle(.{ .mouse = .{ .x = g.x + 1, .y = g.y - 1, .kind = .release, .button = .left } });
    try testing.expectEqual(@as(usize, 4), app.dap.bpsFor("/tmp/g.py").len);
    // A right press opens the breakpoint menu for that line.
    try app.handle(.{ .mouse = .{ .x = g.x + 1, .y = g.y, .kind = .press, .button = .right } });
    try testing.expect(app.overlay == .menu);
    try testing.expectEqualStrings("Breakpoint", app.overlay.menu.title);
    try testing.expectEqualStrings("Remove breakpoint", app.overlay.menu.items[0].label);
    try testing.expectEqual(@as(usize, 3), e.buf.editor.currentLine());
    for (app.overlay.menu.items) |it| try testing.expect(it.action == .command);
}

test "console without a session: entries land as no-session, ↑↓ walk the history, Ctrl+L clears, Esc leaves" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 90, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try command.run(&app, .{ .static = .@"dap.repl" });
    try testing.expectEqualStrings("Debug", app.panes.get(app.active.?).?.title());
    for ("alpha") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    for ("bravo") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    const c = &app.dap.console;
    try testing.expectEqual(@as(usize, 2), c.entries.items.len);
    try testing.expectEqualStrings("no DAP session (run dap.run first)", c.entries.items[0].eval.err.?);
    const t1 = try screenText(&app);
    defer testing.allocator.free(t1);
    try testing.expect(std.mem.indexOf(u8, t1, "> alpha") != null and std.mem.indexOf(u8, t1, "> bravo") != null);
    // The toolbar's first button is Start (the play glyph) without a session.
    try testing.expect(std.mem.indexOf(u8, t1, "\u{F040A}") != null);
    // ↑ walks the command history, ↓ past the newest restores the input.
    try app.handle(.{ .key = Key.named(.up) });
    try testing.expectEqualStrings("bravo", c.input.items);
    try app.handle(.{ .key = Key.named(.up) });
    try testing.expectEqualStrings("alpha", c.input.items);
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.down) });
    try testing.expectEqualStrings("", c.input.items);
    for ("ty") |ch| try app.handle(.{ .key = Key.char(ch) });
    try app.handle(.{ .key = Key.named(.up) });
    try testing.expectEqualStrings("bravo", c.input.items);
    try app.handle(.{ .key = Key.named(.down) });
    try testing.expectEqualStrings("ty", c.input.items);
    try app.handle(.{ .key = Key.ctrl('u') });
    // A watch name completes on Tab; a second Tab cycles; typing ends it.
    try addWatch(&app, "alpha_len");
    try addWatch(&app, "alpha_max");
    for ("al") |ch| try app.handle(.{ .key = Key.char(ch) });
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqualStrings("alpha_len", c.input.items);
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqualStrings("alpha_max", c.input.items);
    try app.handle(.{ .key = Key.char('!') });
    try testing.expectEqualStrings("alpha_max!", c.input.items);
    try testing.expect(c.completion == null);
    // Ctrl+L empties the scrollback; Esc leaves the pane.
    try app.handle(.{ .key = Key.ctrl('l') });
    try testing.expectEqual(@as(usize, 0), c.entries.items.len);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.focus != .pane or app.active.? != app.panes.findKind(.debug).?);
}

test "watches: add via the prompt, the debug pane lists them, the picker removes one" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 90, .rows = 24 });
    defer app.deinit();
    // A narrow screen with the column docked: this test is about
    // what sits beside it, not the width rule (`ui.sidebar_auto_below`).
    app.cfg.ui.sidebar_auto_below = 0;
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
    try testing.expect(std.mem.indexOf(u8, t, "my_var.field = (no") != null);
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
    /// What the goodbye looked like: whether `terminate` came, and
    /// `disconnect`'s `terminateDebuggee`.
    terminate_seen: bool = false,
    disconnect_terminate: ?bool = null,
    /// How many `variables` requests, and how many `evaluate`s with
    /// `context: "watch"`, have come — a REPL line re-asks for both.
    variables_count: u32 = 0,
    watch_evals: u32 = 0,

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

/// A debugpy-shaped adapter (`initialized` after the `launch` reply,
/// as debugpy and lldb-dap have it): stops at line 3 of the file,
/// steps to line 4 on `next`, answers the inspection requests with
/// one scope / one variable, echoes evaluations as `<expr> = 42`.
fn fakeAdapter(io: std.Io, gpa: Allocator, in: std.Io.File, out: std.Io.File, log: *FakeLog, file: []const u8) std.Io.Cancelable!void {
    var buf: [8192]u8 = undefined;
    var fr = in.readerStreaming(io, &buf);
    var seq: i64 = 1000;
    var line: u32 = 3;
    while (true) {
        const body = jsonrpc.readBody(gpa, &fr.interface) catch return;
        defer gpa.free(body);
        var parsed = std.json.parseFromSlice(jsonrpc.Value, gpa, body, .{}) catch return;
        defer parsed.deinit();
        const v = parsed.value;
        const cmd = jsonrpc.getStr(v, "command") orelse continue;
        const rseq = jsonrpc.getInt(v, "seq") orelse 0;
        const args = jsonrpc.getField(v, "arguments") orelse jsonrpc.Value.null;
        if (std.mem.eql(u8, cmd, "initialize")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"exceptionBreakpointFilters\":[{\"filter\":\"uncaught\",\"label\":\"Uncaught Exceptions\",\"default\":true},{\"filter\":\"raised\",\"label\":\"Raised Exceptions\",\"default\":false}]}");
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
        } else if (std.mem.eql(u8, cmd, "launch") or std.mem.eql(u8, cmd, "attach")) {
            log.note("launched", true);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
            // debugpy (and lldb-dap): `initialized` only while handling
            // `launch` / `attach` — a client waiting for it first hangs here.
            fakeEvent(io, gpa, out, &seq, "initialized", "{}");
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
            log.lock.lockUncancelable(io);
            log.variables_count += 1;
            log.lock.unlock(io);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"variables\":[{\"name\":\"a\",\"value\":\"1\",\"type\":\"int\",\"variablesReference\":0}]}");
        } else if (std.mem.eql(u8, cmd, "evaluate")) {
            const expr = jsonrpc.getStr(args, "expression") orelse "";
            if (jsonrpc.getStr(args, "context")) |c| if (std.mem.eql(u8, c, "watch")) {
                log.lock.lockUncancelable(io);
                log.watch_evals += 1;
                log.lock.unlock(io);
            };
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
        } else if (std.mem.eql(u8, cmd, "terminate")) {
            log.note("terminate_seen", true);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
        } else if (std.mem.eql(u8, cmd, "disconnect")) {
            log.note("disconnect_terminate", jsonrpc.getBool(args, "terminateDebuggee"));
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
            return;
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
    const ed_pane = app.activeEditor().?;
    try ed_pane.buf.setPath(file);
    try ed_pane.buf.editor.setText("import x\n\nx = 1\ny = 2\nprint(x)\n");
    ed_pane.buf.editor.placeCursor(2, 0);
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
    const s = try Session.initFiles(gpa, io, app.events, app.dap.next_session, F{ .handle = c2s[1], .flags = flags }, F{ .handle = s2c[0], .flags = flags }, "{\"program\":\"x\"}");
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
            const e = a.dap.console.lastEval() orelse return false;
            return !e.pending;
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
    try testing.expectEqual(@as(usize, 2), ed_pane.buf.editor.currentLine());
    try testing.expectEqualStrings("a = 42", s.watch_results.get("a").?.value);
    try testing.expectEqualStrings("hello", s.output.items[0].text);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rows = try s.variableRows(arena.allocator());
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("a: int", rows[1].label);
    const marks = try marksFor(&app, arena.allocator(), file, &app.theme, false);
    try testing.expectEqualStrings("▶", marks[0].glyph);

    // The REPL evaluates against the stop — and the panel is asked
    // again afterwards: the scope's variables and the watch.
    const vars_before = log.variables_count;
    const watch_before = log.watch_evals;
    try command.run(&app, .{ .static = .@"dap.repl" });
    for ("a + 1") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    try pumpUntil(&app, &app, Cond.replied, 5000);
    try testing.expectEqualStrings("a + 1 = 42", app.dap.console.lastEval().?.value);
    try testing.expectEqualStrings("int", app.dap.console.lastEval().?.ty.?);
    const Refreshed = struct {
        log: *FakeLog,
        vars: u32,
        watches: u32,
        fn done(r: *const @This()) bool {
            r.log.lock.lockUncancelable(testing.io);
            defer r.log.lock.unlock(testing.io);
            return r.log.variables_count > r.vars and r.log.watch_evals > r.watches;
        }
    };
    const refreshed: Refreshed = .{ .log = &log, .vars = vars_before, .watches = watch_before };
    try pumpUntil(&app, &refreshed, Refreshed.done, 5000);

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
    // A LAUNCHED program is ended with it: `terminate`, then
    // `disconnect { terminateDebuggee: true }`.
    try testing.expect(!s.is_attach);
    try command.run(&app, .{ .static = .@"dap.terminate" });
    try testing.expectEqualStrings("dap: terminated", app.lastToast().?);
    try testing.expect(app.dap.session == null);
    try testing.expect(app.dap.arrow == null);
    try group.await(io);
    try testing.expect(log.terminate_seen);
    try testing.expectEqual(@as(?bool, true), log.disconnect_terminate);
    (F{ .handle = c2s[0], .flags = flags }).close(io);
    (F{ .handle = s2c[1], .flags = flags }).close(io);
}

test "an attach session: Stop detaches — no `terminate`, `disconnect { terminateDebuggee: false }` — and the process is not mnml's to end" {
    const gpa = testing.allocator;
    const io = testing.io;
    var app = try App.initWith(gpa, io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const file = "/tmp/mnml-zig-fake-dap-attach.py";
    _ = try app.openScratch();
    const ed_pane = app.activeEditor().?;
    try ed_pane.buf.setPath(file);
    try ed_pane.buf.editor.setText("import x\n\nx = 1\ny = 2\n");

    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const c2s = try std.Io.Threaded.pipe2(.{});
    const s2c = try std.Io.Threaded.pipe2(.{});
    const F = std.Io.File;
    const flags: F.Flags = .{ .nonblocking = false };
    var log: FakeLog = .{};
    var group: std.Io.Group = .init;
    try group.concurrent(io, fakeAdapter, .{ io, gpa, F{ .handle = c2s[0], .flags = flags }, F{ .handle = s2c[1], .flags = flags }, &log, file });
    const s = try Session.initFiles(gpa, io, app.events, app.dap.next_session, F{ .handle = c2s[1], .flags = flags }, F{ .handle = s2c[0], .flags = flags }, "{\"request\":\"attach\",\"listen\":{\"host\":\"127.0.0.1\",\"port\":5678}}");
    app.dap.next_session += 1;
    app.dap.session = s;
    try testing.expect(s.is_attach);
    try s.initialize();
    const Cond = struct {
        fn stopped(a: *App) bool {
            const ss = a.dap.session orelse return false;
            return ss.stopped != null and ss.frames.len > 0;
        }
    };
    try pumpUntil(&app, &app, Cond.stopped, 5000);
    try testing.expect(log.launched and log.configured);
    try command.run(&app, .{ .static = .@"dap.terminate" });
    try testing.expectEqualStrings("dap: detached (the process keeps running)", app.lastToast().?);
    try testing.expect(app.dap.session == null);
    try group.await(io);
    try testing.expect(!log.terminate_seen);
    try testing.expectEqual(@as(?bool, false), log.disconnect_terminate);
    (F{ .handle = c2s[0], .flags = flags }).close(io);
    (F{ .handle = s2c[1], .flags = flags }).close(io);
}

/// netcoredbg's handshake: `initialized` is sent from inside
/// `initialize`, before that request's reply, and the reply carries
/// its two filters (`user-unhandled` on by default). A breakpoint stop
/// after `configurationDone`, one thread, one frame.
fn fakeNetcoredbg(io: std.Io, gpa: Allocator, in: std.Io.File, out: std.Io.File, log: *FakeLog, file: []const u8) std.Io.Cancelable!void {
    var buf: [8192]u8 = undefined;
    var fr = in.readerStreaming(io, &buf);
    var seq: i64 = 2000;
    while (true) {
        const body = jsonrpc.readBody(gpa, &fr.interface) catch return;
        defer gpa.free(body);
        var parsed = std.json.parseFromSlice(jsonrpc.Value, gpa, body, .{}) catch return;
        defer parsed.deinit();
        const v = parsed.value;
        const cmd = jsonrpc.getStr(v, "command") orelse continue;
        const rseq = jsonrpc.getInt(v, "seq") orelse 0;
        const args = jsonrpc.getField(v, "arguments") orelse jsonrpc.Value.null;
        if (std.mem.eql(u8, cmd, "initialize")) {
            fakeEvent(io, gpa, out, &seq, "initialized", "{}");
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"supportsConfigurationDoneRequest\":true,\"supportsFunctionBreakpoints\":true,\"supportsConditionalBreakpoints\":true,\"supportTerminateDebuggee\":true,\"supportsExceptionInfoRequest\":true,\"supportsSetVariable\":true,\"supportsEvaluateForHovers\":true,\"supportsExceptionFilterOptions\":true,\"exceptionBreakpointFilters\":[{\"filter\":\"all\",\"label\":\"All Exceptions\",\"default\":false},{\"filter\":\"user-unhandled\",\"label\":\"User-Unhandled Exceptions\",\"default\":true}]}");
        } else if (std.mem.eql(u8, cmd, "setBreakpoints")) {
            const lines: []const jsonrpc.Value = jsonrpc.getArr(args, "lines") orelse &.{};
            log.lock.lockUncancelable(io);
            log.bp_count = @min(lines.len, log.bp_lines.len);
            for (lines[0..log.bp_count], 0..) |l, i| log.bp_lines[i] = @intCast(jsonrpc.asInt(l) orelse 0);
            log.lock.unlock(io);
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"breakpoints\":[{\"verified\":true,\"line\":3}]}");
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
            fakeEvent(io, gpa, out, &seq, "thread", "{\"reason\":\"started\",\"threadId\":4242}");
            fakeEvent(io, gpa, out, &seq, "stopped", "{\"reason\":\"breakpoint\",\"threadId\":4242,\"allThreadsStopped\":true}");
        } else if (std.mem.eql(u8, cmd, "threads")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"threads\":[{\"id\":4242,\"name\":\"Main Thread\"}]}");
        } else if (std.mem.eql(u8, cmd, "stackTrace")) {
            const b = std.fmt.allocPrint(gpa, "{{\"stackFrames\":[{{\"id\":1,\"name\":\"Program.Main()\",\"line\":3,\"column\":9,\"source\":{{\"name\":\"Program.cs\",\"path\":\"{s}\"}}}}],\"totalFrames\":1}}", .{file}) catch return;
            defer gpa.free(b);
            fakeReply(io, gpa, out, &seq, rseq, cmd, b);
        } else if (std.mem.eql(u8, cmd, "scopes")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":1001,\"expensive\":false}]}");
        } else if (std.mem.eql(u8, cmd, "variables")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"variables\":[{\"name\":\"args\",\"value\":\"{string[0]}\",\"type\":\"string[]\",\"variablesReference\":0}]}");
        } else if (std.mem.eql(u8, cmd, "evaluate")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{\"result\":\"0\",\"type\":\"int\",\"variablesReference\":0}");
        } else if (std.mem.eql(u8, cmd, "disconnect") or std.mem.eql(u8, cmd, "terminate")) {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
            if (std.mem.eql(u8, cmd, "disconnect")) return;
        } else {
            fakeReply(io, gpa, out, &seq, rseq, cmd, "{}");
        }
    }
}

test "a netcoredbg-shaped adapter: initialized before the initialize reply still gets the default filter, then launch, configurationDone and a stop" {
    const gpa = testing.allocator;
    const io = testing.io;
    var app = try App.initWith(gpa, io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const file = "/tmp/mnml-zig-fake-netcoredbg/Program.cs";
    _ = try app.openScratch();
    const ed_pane = app.activeEditor().?;
    try ed_pane.buf.setPath(file);
    try ed_pane.buf.editor.setText("using System;\n\nConsole.WriteLine(\"hi\");\nConsole.WriteLine(\"bye\");\n");
    ed_pane.buf.editor.placeCursor(2, 0);
    try command.run(&app, .{ .static = .@"dap.toggle_breakpoint" });

    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const c2s = try std.Io.Threaded.pipe2(.{});
    const s2c = try std.Io.Threaded.pipe2(.{});
    const F = std.Io.File;
    const flags: F.Flags = .{ .nonblocking = false };
    var log: FakeLog = .{};
    var group: std.Io.Group = .init;
    try group.concurrent(io, fakeNetcoredbg, .{ io, gpa, F{ .handle = c2s[0], .flags = flags }, F{ .handle = s2c[1], .flags = flags }, &log, file });
    const s = try Session.initFiles(gpa, io, app.events, app.dap.next_session, F{ .handle = c2s[1], .flags = flags }, F{ .handle = s2c[0], .flags = flags }, "{\"program\":\"/tmp/x/bin/Debug/net8.0/x.dll\",\"cwd\":\"/tmp/x\"}");
    app.dap.next_session += 1;
    app.dap.session = s;
    try s.initialize();
    const Cond = struct {
        fn stopped(a: *App) bool {
            const ss = a.dap.session orelse return false;
            return ss.stopped != null and ss.frames.len > 0 and ss.variables.contains(1001) and ss.threads.len > 0;
        }
    };
    try pumpUntil(&app, &app, Cond.stopped, 5000);
    try testing.expect(s.initialized);
    try testing.expect(log.launched and log.configured);
    try testing.expectEqual(@as(usize, 1), log.bp_count);
    try testing.expectEqual(@as(u32, 3), log.bp_lines[0]);
    // The reply's filters landed after `initialized`: the default one was still sent.
    try testing.expectEqual(@as(usize, 2), s.filters.items.len);
    try testing.expect(s.enabled_filters.contains("user-unhandled"));
    try testing.expect(!s.enabled_filters.contains("all"));
    try testing.expectEqual(@as(usize, 1), log.filters_count);
    try testing.expectEqualStrings("breakpoint", s.stopped.?.reason);
    try testing.expectEqual(@as(i64, 4242), s.thread.?);
    try testing.expectEqualStrings("Program.Main()", s.frames[0].name);
    try testing.expectEqualStrings("Main Thread", s.threads[0].name);
    try testing.expectEqual(@as(u32, 2), app.dap.arrow.?.line);
    try command.run(&app, .{ .static = .@"dap.terminate" });
    try testing.expect(app.dap.session == null);
    try group.await(io);
    (F{ .handle = c2s[0], .flags = flags }).close(io);
    (F{ .handle = s2c[1], .flags = flags }).close(io);
}

test "the built-in netcoredbg row: a .cs file derives its launch body from the csproj; a workspace .dap.cs wins; no project is a reason" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 80, .rows = 24 });
    defer app.deinit();
    try tmp.dir.createDirPath(testing.io, "src/App");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/App/App.csproj", .data = "<Project Sdk=\"Microsoft.NET.Sdk\">\n<PropertyGroup>\n<OutputType>Exe</OutputType>\n<TargetFramework>net9.0</TargetFramework>\n<AssemblyName>Acme.App</AssemblyName>\n</PropertyGroup>\n</Project>\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/App/Program.cs", .data = "Console.WriteLine(1);\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Lonely.cs", .data = "class L {}\n" });
    const program = try std.fs.path.join(testing.allocator, &.{ root, "src", "App", "Program.cs" });
    defer testing.allocator.free(program);
    try testing.expect(builtinFor("cs") != null);
    try testing.expect(builtinFor("py") == null);
    const found = (try builtinAdapterFor(&app, program)).?;
    try testing.expectEqualStrings("netcoredbg", found.cfg.cmd);
    try testing.expectEqualStrings("--interpreter=vscode", found.cfg.args[0]);
    // Both paths joined natively (`\` on Windows) and JSON-escaped.
    const dll = try std.fs.path.join(testing.allocator, &.{ root, "src", "App", "bin", "Debug", "net9.0", "Acme.App.dll" });
    defer testing.allocator.free(dll);
    const cwd = try std.fs.path.join(testing.allocator, &.{ root, "src", "App" });
    defer testing.allocator.free(cwd);
    const expected = try std.fmt.allocPrint(testing.allocator, "{{\"program\":{f},\"cwd\":{f},\"stopAtEntry\":false}}", .{ std.json.fmt(dll, .{}), std.json.fmt(cwd, .{}) });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, found.body.?);
    // A .cs with no project: the reason names the file.
    const lonely = try std.fs.path.join(testing.allocator, &.{ root, "Lonely.cs" });
    defer testing.allocator.free(lonely);
    try testing.expectError(error.Failed, builtinAdapterFor(&app, lonely));
    try testing.expectEqualStrings("dap: no *.csproj found at or above Lonely.cs — the built-in netcoredbg adapter needs one", app.diag.msg.?);
    app.diag.clear();
    // Not a .cs: no row, no error.
    try testing.expect((try builtinAdapterFor(&app, "/x/y.py")) == null);
    // A config entry for the same key is what `resolveAdapter` returns.
    var cfg_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer cfg_arena.deinit();
    try app.cfg.dap.put(cfg_arena.allocator(), "cs", .{ .cmd = "my-own-dbg" });
    const own = try resolveAdapter(&app, program);
    try testing.expectEqualStrings("my-own-dbg", own.cfg.cmd);
    try testing.expect(own.body == null);
    // dap.run on the .cs spawns the config's adapter — which is not on PATH.
    _ = try app.openPath(program);
    try testing.expectError(error.Failed, run(&app));
    try testing.expectEqualStrings("dap spawn failed: my-own-dbg not found on PATH", app.diag.msg.?);
}

test "dotnet.debug: dotnet build in a task pane, the launch on exit 0, a toast on a failed build" {
    if (!pty_pane.supported or builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    try tmp.dir.createDirPath(testing.io, "src/App");
    try tmp.dir.createDirPath(testing.io, "bin");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "All.sln", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/App/App.csproj", .data = "<Project><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/App/Program.cs", .data = "Console.WriteLine(1);\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "x\n" });
    const program = try std.fs.path.join(testing.allocator, &.{ root, "src", "App", "Program.cs" });
    defer testing.allocator.free(program);
    const notes = try std.fs.path.join(testing.allocator, &.{ root, "notes.txt" });
    defer testing.allocator.free(notes);
    _ = try app.openPath(notes);
    try testing.expectError(error.Failed, dotnetDebug(&app));
    try testing.expectEqualStrings("dotnet.debug: notes.txt is not a .cs file", app.diag.msg.?);
    app.diag.clear();
    // A `dotnet` that fails: the toast, no session.
    const exe = try std.fs.path.join(testing.allocator, &.{ root, "bin", "dotnet" });
    defer testing.allocator.free(exe);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin/dotnet", .data = "#!/bin/sh\necho build failed\nexit 1\n" });
    try Io.Dir.cwd().setFilePermissions(testing.io, exe, .fromMode(0o755), .{});
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/bin:/usr/bin:/bin", .{root});
    defer testing.allocator.free(path);
    try app.env.put("PATH", path);
    _ = try app.openPath(program);
    try dotnetDebug(&app);
    try testing.expect(app.dap.pending_launch != null);
    const pane = app.panes.pty(app.dap.pending_launch.?.pane).?;
    try testing.expectEqualStrings(root, pane.cwd.?);
    try testing.expectEqualStrings("dotnet build", pane.label);
    const Cond = struct {
        fn settled(a: *App) bool {
            return a.dap.pending_launch == null;
        }
    };
    try pumpUntil(&app, &app, Cond.settled, 10_000);
    try testing.expectEqualStrings("dotnet build failed — not launching the debugger", app.lastToast().?);
    try testing.expect(app.dap.session == null);
    // A build that succeeds hands over to the adapter — netcoredbg is not on this PATH, and the toast says so.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bin/dotnet", .data = "#!/bin/sh\necho ok\nexit 0\n" });
    _ = try app.openPath(program);
    try dotnetDebug(&app);
    try pumpUntil(&app, &app, Cond.settled, 10_000);
    try testing.expectEqualStrings("dap spawn failed: netcoredbg not found on PATH", app.lastToast().?);
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
    const ed_pane = app.activeEditor().?;
    ed_pane.buf.editor.placeCursor(3, 0);
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
            const e = a.dap.console.lastEval() orelse return false;
            return !e.pending;
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
    try testing.expectEqual(@as(usize, 3), ed_pane.buf.editor.currentLine());
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

    // Editor integration at the stop: the band on line 4, `  x = 1`
    // after every line naming x up to it, the hover tip for x, and
    // `K` (dap.evaluate_hover) into the hover box.
    try testing.expectEqual(@as(?u32, 3), stoppedLine(&app, ed_pane));
    const inline_vals = try inlineValuesFor(&app, app.frame.allocator(), ed_pane, &app.theme);
    try testing.expectEqual(@as(usize, 3), inline_vals.len);
    try testing.expectEqualStrings("  x = 1", inline_vals[0].text);
    try testing.expectEqual(ed_pane.buf.editor.lineEnd(0), inline_vals[0].byte);
    try testing.expectEqualStrings("  p = {a=1, b=\"two\"}", inline_vals[1].text);
    try testing.expectEqualStrings("  x = 1", inline_vals[2].text);
    try testing.expectEqual(ed_pane.buf.editor.lineEnd(3), inline_vals[2].byte);
    app.cfg.editor.inline_values = false;
    try testing.expectEqual(@as(usize, 0), (try inlineValuesFor(&app, app.frame.allocator(), ed_pane, &app.theme)).len);
    app.cfg.editor.inline_values = true;
    const tip = (try hoverValue(&app, app.frame.allocator(), app.active.?, 3, 0)).?;
    try testing.expectEqualStrings("x: int = 1", tip.title);
    try testing.expect(std.mem.startsWith(u8, tip.detail.?, "Locals"));
    try testing.expect((try hoverValue(&app, app.frame.allocator(), app.active.?, 2, 1)) == null);
    ed_pane.buf.editor.placeCursor(3, 0);
    try command.run(&app, .{ .static = .@"dap.evaluate_hover" });
    const CondHover = struct {
        fn shown(a: *App) bool {
            return a.lsp.hover != null;
        }
    };
    try pumpUntil(&app, &app, CondHover.shown, 10_000);
    try testing.expectEqualStrings("x: int = 1", app.lsp.hover.?.pages[0][0]);
    lsp.closeHover(&app);

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
    try testing.expectEqualStrings("20", app.dap.console.lastEval().?.value);
    try testing.expectEqualStrings("int", app.dap.console.lastEval().?.ty.?);
    for ("nope") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.enter) });
    const Cond2 = struct {
        fn replied2(a: *App) bool {
            const e = a.dap.console.lastEval() orelse return false;
            return std.mem.eql(u8, e.expression, "nope") and !e.pending;
        }
    };
    try pumpUntil(&app, &app, Cond2.replied2, 10_000);
    // The fake's console error runs to two lines, as lldb's and Python's do.
    try testing.expectEqualStrings("no such variable\n  in: nope", app.dap.console.lastEval().?.err.?);

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
