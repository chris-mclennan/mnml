//! Language intelligence (LSP) on the app side. One server per
//! language and project root (`lsp/client.zig`), attached when a file
//! opens; diagnostics as a per-file snapshot painted as squiggles,
//! gutter dots, a statusline chip and the DIAGNOSTICS panel; the
//! completion popup, hover and signature help, peek; go-to-* and
//! references; rename, formatting, code actions; document symbols for
//! the outline; highlights, folds, selection ranges, hierarchies.
//!
//! No server is ever awaited: every request carries a `Ctx` naming the
//! pane it was made for, and the reply is acted on when it lands — or
//! dropped when the pane is gone. A missing binary is toasted once per
//! session with its install hint; a server is only started inside a
//! project (a root marker was found), so a stray file never launches
//! one into a directory it cannot make sense of.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const hooks = @import("../core/hooks.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const Mouse = key_mod.Mouse;
const alloc = @import("../core/alloc.zig");
const Rect = @import("../ui/rect.zig");
const Ui = @import("../ui/context.zig");
const Theme = @import("../ui/theme.zig");
const editor_view = @import("../ui/editor_view.zig");
const list_panel = @import("../ui/list_panel.zig");
const fuzzy = @import("../ui/fuzzy.zig");
const completion_view = @import("../ui/completion_view.zig");
const hover_view = @import("../ui/hover_view.zig");
const peek_view = @import("../ui/peek_view.zig");
const diagnostics_view = @import("../ui/diagnostics_view.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const client = @import("../lsp/client.zig");
const types = @import("../lsp/types.zig");
const snippets = @import("snippets.zig");
const decor = @import("lsp_decor.zig");
const semantic_app = @import("lsp_semantic.zig");
const format_app = @import("lsp_format.zig");
const rename_app = @import("lsp_rename.zig");
const cmd_picker = @import("cmd_picker.zig");
const cmd_view = @import("cmd_view.zig");
const side = @import("side.zig");
const layout_mod = @import("layout.zig");
const find_mod = @import("find.zig");

const Style = @import("vaxis").Style;

pub const Server = client.Server;
pub const ReqKind = client.ReqKind;
pub const Ctx = client.Ctx;
const Value = jsonrpc.Value;

/// One file's diagnostics from two sources — the server's publish and
/// an external linter's run — each replaced wholesale by its next
/// delivery, merged into `items` (sorted, gpa-owned) for every reader.
const FileDiags = struct {
    arena: alloc.SnapshotArena,
    lint_arena: alloc.SnapshotArena,
    server_items: []types.Diagnostic = &.{},
    lint_items: []types.Diagnostic = &.{},
    items: []types.Diagnostic = &.{},

    fn create(gpa: Allocator) Allocator.Error!*FileDiags {
        const fd = try gpa.create(FileDiags);
        fd.* = .{ .arena = alloc.SnapshotArena.init(gpa), .lint_arena = alloc.SnapshotArena.init(gpa) };
        return fd;
    }

    fn destroy(self: *FileDiags, gpa: Allocator) void {
        self.arena.deinit();
        self.lint_arena.deinit();
        gpa.free(self.items);
        gpa.destroy(self);
    }

    /// Rebuild `items` from both sources.
    fn merge(self: *FileDiags, gpa: Allocator) Allocator.Error!void {
        const merged = try gpa.alloc(types.Diagnostic, self.server_items.len + self.lint_items.len);
        @memcpy(merged[0..self.server_items.len], self.server_items);
        @memcpy(merged[self.server_items.len..], self.lint_items);
        std.mem.sort(types.Diagnostic, merged, {}, struct {
            fn lt(_: void, a: types.Diagnostic, b: types.Diagnostic) bool {
                if (a.range.start.line != b.range.start.line) return a.range.start.line < b.range.start.line;
                return a.range.start.character < b.range.start.character;
            }
        }.lt);
        gpa.free(self.items);
        self.items = merged;
    }
};

/// One file's symbols, replaced by every `documentSymbol` reply.
const SymbolSet = struct {
    arena: alloc.SnapshotArena,
    items: []types.Symbol = &.{},

    fn destroy(self: *SymbolSet, gpa: Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// The completion popup. The items borrow the reply (kept alive here).
pub const Completion = struct {
    pane: PaneId,
    server: *Server,
    /// Where the word being completed starts (byte).
    start: usize,
    incoming: *jsonrpc.Incoming,
    arena: alloc.SnapshotArena,
    items: []types.CompletionItem,
    selected: usize = 0,
    scroll: usize = 0,
    /// `ctrl+space`; a popup the typing opened closes when the word ends.
    manual: bool,

    fn destroy(self: *Completion, gpa: Allocator) void {
        self.arena.deinit();
        self.incoming.destroy(gpa);
    }
};

/// Hover text, or signature help (several pages, one per overload).
pub const Hover = struct {
    pane: PaneId,
    arena: alloc.SnapshotArena,
    pages: []const []const []const u8,
    active: usize = 0,
    scroll: usize = 0,
    /// Anchor the box at this byte (the cursor when the request went out).
    at: usize,

    fn lines(self: *const Hover) []const []const u8 {
        return if (self.pages.len == 0) &.{} else self.pages[@min(self.active, self.pages.len - 1)];
    }
};

/// The peek overlay: lines around a definition.
pub const Peek = struct {
    pane: PaneId,
    arena: alloc.SnapshotArena,
    path: []const u8,
    lines: []const []const u8,
    /// 0-based line of `lines[0]` in the file.
    first_line: u32,
    highlight: usize,
    scroll: usize = 0,
};

/// Locations behind a picker (references, many definitions, hierarchies).
const LocSet = struct { arena: alloc.SnapshotArena, items: []types.Location };

/// A command held for a starting server. `initialize` stamps the two
/// times: the request goes out at `not_before_ms` unless a `$/progress`
/// is open by then (tsserver loads the project after the first
/// `didOpen`; an answer given during that load covers one file), in
/// which case it goes out when the last progress ends — or at
/// `deadline_ms`, whichever is first.
const Deferred = struct { server: u32, cmd: command.CommandId, not_before_ms: i64 = 0, deadline_ms: i64 = 0 };
/// How long after `initialize` a server gets to announce it is loading.
const deferred_grace_ms: i64 = 500;
/// The most a held command waits on a loading server before it goes anyway.
const deferred_max_wait_ms: i64 = 15_000;
/// Code actions behind a picker; `raw` borrows the reply.
const ActionSet = struct { arena: alloc.SnapshotArena, incoming: *jsonrpc.Incoming, items: []types.CodeAction, server: *Server, pane: PaneId };
const SymbolPick = struct { arena: alloc.SnapshotArena, items: []types.Symbol, pane: PaneId };
/// `selectionRange`'s chain from the cursor outward, as byte ranges.
const Ladder = struct { pane: PaneId, ranges: [][2]usize, idx: usize };

pub const SeverityFilter = enum {
    all,
    warnings,
    errors,

    pub fn label(f: SeverityFilter) []const u8 {
        return switch (f) {
            .all => "All",
            .warnings => "Warnings+",
            .errors => "Errors",
        };
    }
    pub fn next(f: SeverityFilter) SeverityFilter {
        return switch (f) {
            .all => .warnings,
            .warnings => .errors,
            .errors => .all,
        };
    }
    fn admits(f: SeverityFilter, s: types.Severity) bool {
        return switch (f) {
            .all => true,
            .warnings => s == .err or s == .warning,
            .errors => s == .err,
        };
    }
};

pub const DiagRow = diagnostics_view.Row;
pub const DiagPanel = list_panel.ListPanel(DiagRow);

pub const State = struct {
    servers: std.ArrayListUnmanaged(*Server) = .empty,
    next_id: u32 = 1,
    /// Servers that could not start, by name (owned); toasted once.
    dead: std.StringHashMapUnmanaged(void) = .empty,
    /// By absolute path (owned keys).
    diags: std.StringHashMapUnmanaged(*FileDiags) = .empty,
    symbols: std.StringHashMapUnmanaged(*SymbolSet) = .empty,
    completion: ?Completion = null,
    hover: ?Hover = null,
    peek: ?Peek = null,
    /// `lsp.peek_definition_overlay` in flight: the next definition
    /// reply opens the overlay instead of jumping. Set only once the
    /// request is out; cleared by the reply or its failure.
    pending_peek: bool = false,
    panel: DiagPanel.State = .{},
    severity_filter: SeverityFilter = .all,
    picker_locs: ?LocSet = null,
    picker_actions: ?ActionSet = null,
    picker_symbols: ?SymbolPick = null,
    ladder: ?Ladder = null,
    /// The completion request in flight; a newer one cancels it.
    completion_req: ?struct { server: *Server, id: i64 } = null,
    /// A command that asked a server still answering `initialize`. It
    /// runs once the server is ready and quiet (see `tick`). One per
    /// session — the latest.
    deferred: ?Deferred = null,
    /// Inlay hints, code lenses, colours, links — by absolute path (owned keys).
    decor: std.StringHashMapUnmanaged(*decor.FileDecor) = .empty,
    /// When each pane last asked for its decorations.
    decor_track: std.AutoHashMapUnmanaged(PaneId, decor.Track) = .empty,
    /// Semantic tokens by absolute path (owned keys).
    semantic: std.StringHashMapUnmanaged(*semantic_app.SemFile) = .empty,
    /// The external linters' workers.
    lint_group: Io.Group = .init,
    rename: rename_app.State = .{},

    pub fn deinit(self: *State, gpa: Allocator, io: Io) void {
        self.lint_group.cancel(io);
        for (self.servers.items) |s| s.deinit();
        self.servers.deinit(gpa);
        var dk = self.dead.keyIterator();
        while (dk.next()) |k| gpa.free(k.*);
        self.dead.deinit(gpa);
        var di = self.diags.iterator();
        while (di.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.destroy(gpa);
        }
        self.diags.deinit(gpa);
        var si = self.symbols.iterator();
        while (si.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.destroy(gpa);
        }
        self.symbols.deinit(gpa);
        if (self.completion) |*c| c.destroy(gpa);
        if (self.hover) |*h| h.arena.deinit();
        if (self.peek) |*p| p.arena.deinit();
        if (self.picker_locs) |*l| l.arena.deinit();
        if (self.picker_actions) |*a| {
            a.arena.deinit();
            a.incoming.destroy(gpa);
        }
        if (self.picker_symbols) |*s| s.arena.deinit();
        if (self.ladder) |l| gpa.free(l.ranges);
        self.panel.deinit(gpa);
        var dc = self.decor.iterator();
        while (dc.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.destroy(gpa);
        }
        self.decor.deinit(gpa);
        self.decor_track.deinit(gpa);
        var sm = self.semantic.iterator();
        while (sm.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.*.destroy(gpa);
        }
        self.semantic.deinit(gpa);
        self.rename.deinit();
    }
};

// ─── servers ────────────────────────────────────────────────────────────

/// What starts for an extension: a builtin, overridden field by field
/// by `.lsp.<name>`, or a config-only server. Slices borrow the config
/// / the builtin table.
const Spec = struct {
    name: []const u8,
    cmd: []const u8,
    args: []const []const u8,
    root_markers: []const []const u8,
    settings: app_mod.Config.Dynamic,
    init_options: app_mod.Config.Dynamic,
};

fn extOf(path: []const u8, buf: []u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2 or ext.len - 1 > buf.len) return "";
    return std.ascii.lowerString(buf[0 .. ext.len - 1], ext[1..]);
}

fn hasExt(list: []const []const u8, ext: []const u8) bool {
    for (list) |e| if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    return false;
}

fn specFor(app: *App, path: []const u8) ?Spec {
    var buf: [32]u8 = undefined;
    const ext = extOf(path, &buf);
    if (ext.len == 0) return null;
    // Config entries first: a user server for the extension wins.
    for (app.cfg.lsp.keys(), app.cfg.lsp.values()) |name, cfg| {
        if (!hasExt(cfg.extensions, ext)) continue;
        const cmd = cfg.cmd orelse blk: {
            for (client.builtins) |b| if (std.mem.eql(u8, b.name, name)) break :blk b.cmd;
            break :blk null;
        } orelse continue;
        return .{ .name = name, .cmd = cmd, .args = cfg.args, .root_markers = cfg.root_markers, .settings = cfg.settings, .init_options = cfg.initialization_options };
    }
    for (client.builtins) |b| {
        if (!hasExt(b.extensions, ext)) continue;
        // `.lsp.<name>` without extensions still overrides the command.
        if (app.cfg.lsp.get(b.name)) |cfg| {
            return .{
                .name = b.name,
                .cmd = cfg.cmd orelse b.cmd,
                .args = if (cfg.cmd != null) cfg.args else b.args,
                .root_markers = if (cfg.root_markers.len > 0) cfg.root_markers else b.root_markers,
                .settings = cfg.settings,
                .init_options = cfg.initialization_options,
            };
        }
        return .{ .name = b.name, .cmd = b.cmd, .args = b.args, .root_markers = b.root_markers, .settings = .empty_object, .init_options = .empty_object };
    }
    return null;
}

/// Walk up from the file's directory to the first directory holding a
/// marker. Without one the root is the file's own directory, as Rust's
/// `find_root` falls back — the server still starts (rust-analyzer then
/// says so itself: `Failed to discover workspace…`), so a lone `.rs`
/// outside a crate gets the same server and the same toast as under
/// Rust. A spec with no markers roots at the workspace.
fn findRoot(app: *App, arena: Allocator, path: []const u8, markers: []const []const u8) Allocator.Error![]const u8 {
    if (markers.len == 0) return app.workspace;
    const start = std.fs.path.dirname(path) orelse app.workspace;
    var dir: ?[]const u8 = start;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        for (markers) |m| {
            const p = try std.fs.path.join(arena, &.{ d, m });
            if (Io.Dir.cwd().statFile(app.io, p, .{})) |_| return d else |_| {}
        }
        if (d.len <= 1) break;
    }
    return start;
}

/// Is `cmd` runnable: an absolute path that exists, or a name on PATH.
pub fn onPath(app: *App, arena: Allocator, cmd: []const u8) Allocator.Error!bool {
    if (std.fs.path.isAbsolute(cmd) or std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return if (Io.Dir.cwd().statFile(app.io, cmd, .{})) |_| true else |_| false;
    }
    const path_var = app.env.get("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_var, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        const p = try std.fs.path.join(arena, &.{ d, cmd });
        if (Io.Dir.cwd().statFile(app.io, p, .{})) |st| {
            if (st.kind != .directory) return true;
        } else |_| {}
    }
    return false;
}

fn markDead(app: *App, name: []const u8) Allocator.Error!void {
    if (app.lsp.dead.contains(name)) return;
    const key = try app.gpa.dupe(u8, name);
    errdefer app.gpa.free(key);
    try app.lsp.dead.put(app.gpa, key, {});
}

fn dynamicJson(arena: Allocator, d: app_mod.Config.Dynamic) Allocator.Error![]const u8 {
    if (d.isEmpty()) return "{}";
    var aw: Io.Writer.Allocating = .init(arena);
    var js: std.json.Stringify = .{ .writer = &aw.writer };
    d.toJson(&js) catch return error.OutOfMemory;
    return aw.written();
}

/// The running server for `path`, if one is attached to its language
/// and root.
pub fn serverFor(app: *App, path: []const u8) ?*Server {
    var buf: [32]u8 = undefined;
    const ext = extOf(path, &buf);
    for (app.lsp.servers.items) |s| {
        if (s.transport.isDead()) continue;
        if (!std.mem.startsWith(u8, path, s.root)) continue;
        if (s.isOpen(path)) return s;
        const spec = specFor(app, path) orelse continue;
        if (std.mem.eql(u8, spec.name, s.name) and ext.len > 0) return s;
    }
    return null;
}

/// The server for `path`, started if need be. Null when there is no
/// spec or the binary is missing (toasted once).
pub fn ensureServer(app: *App, path: []const u8) Allocator.Error!?*Server {
    if (serverFor(app, path)) |s| return s;
    const spec = specFor(app, path) orelse return null;
    if (app.lsp.dead.contains(spec.name)) return null;
    const arena = app.frame.allocator();
    if (!try onPath(app, arena, spec.cmd)) {
        try markDead(app, spec.name);
        if (client.installHint(spec.cmd)) |hint| {
            try app.toastLevel(.warn, "LSP: {s} not installed — `{s}`", .{ spec.cmd, hint });
        } else {
            try app.toastLevel(.warn, "LSP: {s} not installed — install it on PATH", .{spec.cmd});
        }
        return null;
    }
    const root = try findRoot(app, arena, path, spec.root_markers);
    for (app.lsp.servers.items) |s| if (std.mem.eql(u8, s.name, spec.name) and std.mem.eql(u8, s.root, root) and !s.transport.isDead()) return s;
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, spec.cmd);
    for (spec.args) |a| try argv.append(arena, a);
    const id = app.lsp.next_id;
    const s = Server.spawn(app.gpa, app.io, &app.events, id, .{
        .name = spec.name,
        .argv = argv.items,
        .root = root,
        .env = &app.env,
        .init_options = try dynamicJson(arena, spec.init_options),
        .settings = try dynamicJson(arena, spec.settings),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try markDead(app, spec.name);
            try app.toastLevel(.warn, "LSP: {s} unavailable ({s})", .{ spec.cmd, @errorName(err) });
            return null;
        },
    };
    app.lsp.next_id += 1;
    try app.lsp.servers.append(app.gpa, s);
    s.initialize() catch |err| {
        app.toast("LSP: {s}: initialize failed ({s})", .{ spec.cmd, @errorName(err) });
        retireServer(app, s);
        return null;
    };
    return s;
}

pub fn retireServer(app: *App, s: *Server) void {
    for (app.lsp.servers.items, 0..) |x, i| if (x == s) {
        _ = app.lsp.servers.orderedRemove(i);
        break;
    };
    if (app.lsp.completion) |*c| if (c.server == s) closeCompletion(app);
    if (app.lsp.picker_actions) |*a| if (a.server == s) dropActions(app);
    if (app.lsp.completion_req) |r| if (r.server == s) {
        app.lsp.completion_req = null;
    };
    if (app.lsp.deferred) |d| if (d.server == s.id) {
        app.lsp.deferred = null;
    };
    s.deinit();
}

// ─── hooks: open / save / close, and the per-frame sync ─────────────────

/// D10.2: a file opened → attach its server and `didOpen`.
pub fn onOpen(app: *App, args: hooks.HookArgs) void {
    const e = app.panes.editor(args.open.pane) orelse return;
    attach(app, args.open.pane, e) catch {};
}

pub fn attach(app: *App, pane: PaneId, e: *EditorPane) Allocator.Error!void {
    const path = e.buf.doc.path orelse return;
    // The external linter does not need a server.
    format_app.lintOnHook(app, path);
    const s = (try ensureServer(app, path)) orelse return;
    const was_open = s.isOpen(path);
    s.didOpen(path, client.languageIdFor(path), e.buf.editor.bytes()) catch return;
    e.buf.doc.lsp_seen = e.buf.doc.edits.head();
    if (!was_open) {
        app.hooks.emit(app, .{ .lsp_attach = .{ .server = s.name, .pane = pane } });
        if (s.ready) requestSymbols(app, s, path);
    }
}

/// Before the write: `willSaveWaitUntil` and the external formatter
/// (`lsp_format.onSavePre`), then format-on-save through the server
/// when it formats.
pub fn onSavePre(app: *App, args: hooks.HookArgs) void {
    const pane = args.save_pre.pane;
    const e = app.panes.editor(pane) orelse return;
    const path = e.buf.doc.path orelse return;
    const s = serverFor(app, path);
    if (s != null) syncPane(app, pane, e);
    format_app.onSavePre(app, pane, e, s);
    if (!app.cfg.editor.format_on_save) return;
    const srv = s orelse return;
    if (!srv.caps.formatting or !srv.ready) return;
    requestFormatting(app, srv, pane, e, true) catch {};
}

pub fn onSavePost(app: *App, args: hooks.HookArgs) void {
    const e = app.panes.editor(args.save_post.pane) orelse return;
    const path = e.buf.doc.path orelse return;
    format_app.lintOnHook(app, path);
    const s = serverFor(app, path) orelse return;
    syncPane(app, args.save_post.pane, e);
    s.didSave(path, e.buf.editor.bytes()) catch {};
    requestSymbols(app, s, path);
}

/// The last editor on `path` closed: `didClose`, and the diagnostics
/// for it go too (a reopen republishes).
pub fn onClose(app: *App, pane: PaneId, path: []const u8) void {
    decor.forgetPane(app, pane);
    if (app.lsp.completion) |c| if (c.pane == pane) closeCompletion(app);
    if (app.lsp.hover) |h| if (h.pane == pane) closeHover(app);
    if (app.lsp.peek) |p| if (p.pane == pane) closePeek(app);
    if (app.panes.findPath(path) != null) return;
    for (app.lsp.servers.items) |s| s.didClose(path) catch {};
    decor.drop(app, path);
    semantic_app.drop(app, path);
}

/// Push the edits since the last sync as `didChange`: one splice on an
/// incremental server (and a pure insertion, or utf-8, so the range
/// converts exactly) goes as a range; anything else is the full text.
/// Called from the frame, so every mutation path is covered. The sync
/// point is the document's: two windows on a file send its edits once.
pub fn syncPane(app: *App, pane: PaneId, e: *EditorPane) void {
    _ = pane;
    const path = e.buf.doc.path orelse return;
    const ed = e.buf.editor;
    const head = ed.doc.edits.head();
    const seen = ed.doc.lsp_seen orelse return;
    if (seen == head) return;
    const s = serverFor(app, path) orelse return;
    if (!s.isOpen(path)) return;
    const text = ed.bytes();
    var full = ed.doc.edits.lostSince(seen) or !s.caps.incremental;
    const splices = ed.doc.edits.since(seen);
    if (!full and splices.len == 1) {
        const sp = splices[0];
        const insertion = sp.old_end == sp.start;
        if (insertion or s.encoding == .utf8) {
            const start = types.positionOf(text, sp.start, s.encoding);
            const end: types.Position = if (insertion) start else .{ .line = sp.old_end_pt.row, .character = sp.old_end_pt.col };
            const new_text = text[@min(sp.start, text.len)..@min(sp.new_end, text.len)];
            s.didChange(path, &.{.{ .range = .{ .start = start, .end = end }, .text = new_text }}) catch {};
            ed.doc.lsp_seen = head;
            return;
        }
    } else if (!full and splices.len == 0) {
        full = true;
    }
    s.didChange(path, &.{.{ .range = null, .text = text }}) catch {};
    ed.doc.lsp_seen = head;
}

// ─── events (D1: adopt or free, on every path) ──────────────────────────

pub fn handle(app: *App, server_id: u32, ev: *event.LspEvent) Allocator.Error!void {
    if (server_id == format_app.linter_server_id) {
        try format_app.handleLintEvent(app, ev);
        app.needs_render = true;
        return;
    }
    var adopted = false;
    defer if (!adopted) ev.destroy(app.gpa);
    var server: ?*Server = null;
    for (app.lsp.servers.items) |s| if (s.id == server_id) {
        server = s;
    };
    const s = server orelse return;
    switch (ev.*) {
        .closed => {
            try app.toastLevel(.warn, "LSP: {s} exited", .{s.cmd});
            retireServer(app, s);
        },
        .message => |msg| {
            adopted = try handleMessage(app, s, msg);
            if (adopted) app.gpa.destroy(ev);
        },
    }
    app.needs_render = true;
}

/// Returns true when the message was adopted (the completion popup and
/// the code-action picker keep the tree the items borrow).
fn handleMessage(app: *App, s: *Server, msg: *jsonrpc.Incoming) Allocator.Error!bool {
    const v = msg.root();
    switch (jsonrpc.classify(v)) {
        .response => |r| {
            const pending = s.transport.take(r.id) orelse return false;
            const kind: ReqKind = @enumFromInt(pending.kind);
            const ctx = Ctx.unpack(pending.ctx);
            if (r.err) |err| {
                const text = jsonrpc.getStr(err, "message") orelse "error";
                switch (kind) {
                    .completion, .completion_resolve, .document_highlight, .signature_help, .hover => {},
                    // The outline's refresh is silent; `lsp.symbols` asked.
                    .document_symbol => if (ctx.extra == symbols_pick) app.toast("LSP symbols: {s}", .{text}),
                    .definition, .declaration, .type_definition, .implementation => app.lsp.pending_peek = false,
                    else => app.toast("LSP {s}: {s}", .{ @tagName(kind), text }),
                }
                return false;
            }
            return handleResponse(app, s, kind, ctx, r.result, msg);
        },
        .notification => |n| {
            try handleNotification(app, s, n.method, n.params);
            return false;
        },
        .request => |rq| {
            try handleServerRequest(app, s, rq.id, rq.method, rq.params);
            return false;
        },
        .unknown => return false,
    }
}

fn handleNotification(app: *App, s: *Server, method: []const u8, params: ?Value) Allocator.Error!void {
    if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
        const p = params orelse return;
        const uri = jsonrpc.getStr(p, "uri") orelse return;
        const arena = app.frame.allocator();
        const path = (try types.pathFromUri(arena, uri)) orelse return;
        try applyDiagnostics(app, path, jsonrpc.getArr(p, "diagnostics") orelse &.{});
    } else if (std.mem.eql(u8, method, "window/showMessage")) {
        // Errors only (MessageType 1), as Rust's client gates them:
        // typescript-language-server warns on every inlay-hint request,
        // and that must not toast. The prefix is Rust's `LSP: `, the
        // level its plain toast, the text the server's verbatim (the
        // toast painter clips it to one row).
        const p = params orelse return;
        const text = jsonrpc.getStr(p, "message") orelse return;
        const level = jsonrpc.getInt(p, "type") orelse 1;
        if (level == 1) try app.toastLevel(.info, "LSP: {s}", .{text});
    } else if (std.mem.eql(u8, method, "$/progress")) {
        // Loading / indexing: a held command waits for the last end.
        const p = params orelse return;
        const value = jsonrpc.getObj(p, "value") orelse return;
        const kind = jsonrpc.getStr(value, "kind") orelse return;
        if (std.mem.eql(u8, kind, "begin")) {
            s.progress_open += 1;
        } else if (std.mem.eql(u8, kind, "end")) {
            s.progress_open -|= 1;
            if (s.progress_open == 0 and s.ready) try runDeferred(app, s);
        }
    }
    // `window/logMessage`: nothing to paint yet.
}

/// The command held for `s`, if any, runs now: it toasts its own
/// failure the way it would have from the keymap.
fn runDeferred(app: *App, s: *Server) Allocator.Error!void {
    const d = app.lsp.deferred orelse return;
    if (d.server != s.id) return;
    app.lsp.deferred = null;
    command.run(app, .{ .static = d.cmd }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// Per tick: a held command goes out once its server is ready and quiet
/// past the grace, or at its deadline regardless.
pub fn tick(app: *App, now: i64) Allocator.Error!void {
    const d = app.lsp.deferred orelse return;
    if (d.not_before_ms == 0) return; // `initialize` has not answered
    for (app.lsp.servers.items) |s| if (s.id == d.server) {
        if (!s.ready) return;
        if (now >= d.deadline_ms or (now >= d.not_before_ms and s.progress_open == 0)) try runDeferred(app, s);
        return;
    };
    // Its server retired without the retire path seeing it.
    app.lsp.deferred = null;
}

/// The few requests a server makes of its client.
fn handleServerRequest(app: *App, s: *Server, id: i64, method: []const u8, params: ?Value) Allocator.Error!void {
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        // One answer per item: the configured settings, or null.
        const items: []const Value = if (params) |p| (jsonrpc.getArr(p, "items") orelse &.{}) else &.{};
        const n: usize = items.len;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const arena = app.frame.allocator();
        try out.append(arena, '[');
        for (0..n) |i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, if (std.mem.eql(u8, s.settings, "{}")) "null" else s.settings);
        }
        try out.append(arena, ']');
        s.respond(id, out.items) catch {};
    } else if (std.mem.eql(u8, method, "workspace/applyEdit")) {
        if (params) |p| if (jsonrpc.getObj(p, "edit")) |edit| {
            const n = try applyWorkspaceEdit(app, s, edit);
            app.toast("LSP: applied {d} edit(s)", .{n});
        };
        s.respond(id, "{\"applied\":true}") catch {};
    } else {
        // `client/registerCapability`, `window/workDoneProgress/create`…
        s.respond(id, "null") catch {};
    }
}

fn handleResponse(app: *App, s: *Server, kind: ReqKind, ctx: Ctx, result: ?Value, msg: *jsonrpc.Incoming) Allocator.Error!bool {
    switch (kind) {
        .initialize => {
            try s.onInitialized(result);
            // Documents opened while the server was starting are on the
            // wire now; symbols for the ones showing can follow.
            for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .editor => |*e| if (e.buf.doc.path) |path| if (s.isOpen(path)) requestSymbols(app, s, path),
                else => {},
            };
            // The request that arrived while this server was starting
            // waits for it to be quiet; `tick` sends it.
            if (app.lsp.deferred) |*d| if (d.server == s.id) {
                d.not_before_ms = app.now_ms + deferred_grace_ms;
                d.deadline_ms = app.now_ms + deferred_max_wait_ms;
            };
        },
        .shutdown => {},
        .completion => return try openCompletion(app, s, ctx, result, msg),
        .completion_resolve => try acceptResolved(app, ctx, result),
        .hover => try showHover(app, ctx, try types.readHover(app.frame.allocator(), result), 0),
        .signature_help => try showSignatures(app, ctx, result),
        .definition, .declaration, .type_definition, .implementation => try gotoResult(app, kind, ctx, result),
        .references => try locationsPicker(app, "References", try types.readLocations(app.frame.allocator(), result), "no references"),
        .rename => {
            const r = result orelse {
                app.toast("rename: no edits", .{});
                return false;
            };
            // More than one file: the preview asks first.
            if (rename_app.fileCount(r) > 1) return try adoptRenamePreview(app, s, r);
            const n = try applyWorkspaceEdit(app, s, r);
            if (n == 0) app.toast("rename: no edits", .{}) else app.toast("LSP rename · applied {d} edit(s)", .{n});
        },
        .formatting => try applyFormatting(app, s, ctx, result),
        .code_action => return try openActions(app, s, ctx, result, msg),
        .code_action_resolve => try applyResolvedAction(app, s, ctx, result),
        .execute_command => {},
        .document_symbol => try storeSymbols(app, ctx, result),
        .workspace_symbol => try symbolsPicker(app, ctx, result, true),
        .incoming_prepare, .outgoing_prepare, .type_prepare => try hierarchyStep(app, s, kind, ctx, result),
        .incoming_calls, .outgoing_calls, .supertypes, .subtypes => try hierarchyLocations(app, kind, result),
        .document_highlight => try applyHighlights(app, s, ctx, result),
        .selection_range => try applyLadder(app, s, ctx, result),
        .folding_range => try applyFolds(app, ctx, result),
        .inlay_hint, .code_lens, .code_lens_resolve, .document_color, .document_link => return try decor.handleResponse(app, s, kind, ctx, result, msg),
        .semantic_full, .semantic_delta, .semantic_range => try semantic_app.handleResponse(app, s, kind, ctx, result),
        .on_type_formatting, .will_save_wait_until, .range_formatting => try format_app.handleResponse(app, s, kind, ctx, result),
    }
    return false;
}

// ─── diagnostics ────────────────────────────────────────────────────────

fn fileDiags(app: *App, path: []const u8) Allocator.Error!*FileDiags {
    const gpa = app.gpa;
    const gop = try app.lsp.diags.getOrPut(gpa, path);
    if (!gop.found_existing) {
        gop.key_ptr.* = gpa.dupe(u8, path) catch |err| {
            _ = app.lsp.diags.remove(path);
            return err;
        };
        gop.value_ptr.* = FileDiags.create(gpa) catch |err| {
            gpa.free(gop.key_ptr.*);
            _ = app.lsp.diags.remove(path);
            return err;
        };
    }
    return gop.value_ptr.*;
}

/// Copy `list` onto `arena` (messages, source, code) and sort it.
fn copyDiagnostics(arena: Allocator, list: []const types.Diagnostic) Allocator.Error![]types.Diagnostic {
    const out = try arena.alloc(types.Diagnostic, list.len);
    for (list, 0..) |d_in, i| {
        var d = d_in;
        d.message = try arena.dupe(u8, d.message);
        if (d.source) |src| d.source = try arena.dupe(u8, src);
        if (d.code) |c| d.code = try arena.dupe(u8, c);
        out[i] = d;
    }
    return out;
}

/// After either source landed: merge, tell the hooks, repaint.
fn finishDiagnostics(app: *App, path: []const u8, fd: *FileDiags) Allocator.Error!void {
    try fd.merge(app.gpa);
    var errors: u32 = 0;
    var warnings: u32 = 0;
    for (fd.items) |d| switch (d.severity) {
        .err => errors += 1,
        .warning => warnings += 1,
        else => {},
    };
    app.hooks.emit(app, .{ .diagnostics = .{ .path = app.relPath(path), .errors = errors, .warnings = warnings } });
    app.needs_render = true;
}

/// The server's publish for `path`: its list replaced wholesale.
/// Public for the location-list tests, which seed a list from it.
pub fn applyDiagnostics(app: *App, path: []const u8, list: []const Value) Allocator.Error!void {
    const arena = app.frame.allocator();
    var read: std.ArrayListUnmanaged(types.Diagnostic) = .empty;
    for (list) |v| if (types.readDiagnostic(v)) |d| try read.append(arena, d);
    const fd = try fileDiags(app, path);
    fd.arena.reset();
    fd.server_items = &.{};
    fd.server_items = try copyDiagnostics(fd.arena.allocator(), read.items);
    try finishDiagnostics(app, path, fd);
}

/// An external linter's findings for `path`: its list replaced
/// wholesale; the server's stays.
pub fn applyLintDiagnostics(app: *App, path: []const u8, list: []const types.Diagnostic) Allocator.Error!void {
    const fd = try fileDiags(app, path);
    fd.lint_arena.reset();
    fd.lint_items = &.{};
    fd.lint_items = try copyDiagnostics(fd.lint_arena.allocator(), list);
    try finishDiagnostics(app, path, fd);
}

pub fn diagnosticsFor(app: *App, path: []const u8) []const types.Diagnostic {
    const fd = app.lsp.diags.get(path) orelse return &.{};
    return fd.items;
}

fn severityStyle(t: *const Theme, s: types.Severity) Style {
    return switch (s) {
        .err => t.error_fg,
        .warning => t.warn_fg,
        .info, .hint => t.info_fg,
    };
}

/// The squiggles for an editor: the file's diagnostics as byte ranges
/// on the current text. Frame arena.
pub fn underlinesFor(app: *App, arena: Allocator, e: *EditorPane, theme: *const Theme) Allocator.Error![]editor_view.Underline {
    const path = e.buf.doc.path orelse return &.{};
    const list = diagnosticsFor(app, path);
    if (list.len == 0) return &.{};
    const enc = if (serverFor(app, path)) |s| s.encoding else .utf16;
    const text = e.buf.editor.bytes();
    var out: std.ArrayListUnmanaged(editor_view.Underline) = .empty;
    var last_end: usize = 0;
    for (list) |d| {
        var start = types.byteOf(text, d.range.start, enc);
        var end = types.byteOf(text, d.range.end, enc);
        if (end <= start) end = @min(start + 1, text.len);
        if (start < last_end) start = last_end;
        if (end <= start) continue;
        var style = severityStyle(theme, d.severity);
        style.ul_style = .curly;
        try out.append(arena, .{ .start = start, .end = end, .style = style });
        last_end = end;
    }
    return out.items;
}

/// One dot per line that has a diagnostic, the worst severity winning.
/// Frame arena.
pub fn marksFor(app: *App, arena: Allocator, path: ?[]const u8, theme: *const Theme, ascii: bool) Allocator.Error![]editor_view.GutterMark {
    const p = path orelse return &.{};
    const list = diagnosticsFor(app, p);
    var out: std.ArrayListUnmanaged(editor_view.GutterMark) = .empty;
    for (list) |d| {
        const line = d.range.start.line;
        if (out.items.len > 0 and out.items[out.items.len - 1].line == line) {
            // Same line: keep the worse one (the list is sorted by line).
            continue;
        }
        try out.append(arena, .{ .line = line, .kind = .sign, .glyph = if (ascii) (if (d.severity == .err) "E" else "W") else "●", .style = severityStyle(theme, d.severity) });
    }
    return out.items;
}

/// `lsp.next_diagnostic` / `lsp.prev_diagnostic`: the cursor goes to
/// the next start after it (wrapping), with the message toasted.
pub fn gotoDiagnostic(app: *App, forward: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = app.activeEditor() orelse return app.diag.fail(arena, "no active editor", .{});
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "no diagnostics in this file", .{});
    const list = diagnosticsFor(app, path);
    if (list.len == 0) return app.diag.fail(arena, "no diagnostics in this file", .{});
    const enc = if (serverFor(app, path)) |s| s.encoding else .utf16;
    const text = e.buf.editor.bytes();
    const cur = e.buf.editor.cursor;
    var pick: ?usize = null;
    if (forward) {
        for (list, 0..) |d, i| if (types.byteOf(text, d.range.start, enc) > cur) {
            pick = i;
            break;
        };
        if (pick == null) pick = 0;
    } else {
        var i = list.len;
        while (i > 0) {
            i -= 1;
            if (types.byteOf(text, list[i].range.start, enc) < cur) {
                pick = i;
                break;
            }
        }
        if (pick == null) pick = list.len - 1;
    }
    const d = list[pick.?];
    e.buf.editor.anchor = null;
    e.buf.editor.setCursor(types.byteOf(text, d.range.start, enc));
    app.toast("{s}: {s}", .{ d.severity.label(), d.message });
    app.needs_render = true;
}

/// The DIAGNOSTICS panel's rows: every file's, sorted by path then
/// line, through the severity filter and the text filter. Frame arena.
fn panelRows(app: *App, arena: Allocator) Allocator.Error![]DiagRow {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = app.lsp.diags.iterator();
    while (it.next()) |e| if (e.value_ptr.*.items.len > 0) try paths.append(arena, e.key_ptr.*);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    const q = app.lsp.panel.filterText();
    var out: std.ArrayListUnmanaged(DiagRow) = .empty;
    for (paths.items) |p| for (diagnosticsFor(app, p)) |d| {
        if (!app.lsp.severity_filter.admits(d.severity)) continue;
        const rel = app.relPath(p);
        if (q.len > 0 and fuzzy.score(q, d.message) == null and fuzzy.score(q, rel) == null) continue;
        try out.append(arena, .{ .path = p, .rel = rel, .line = d.range.start.line, .character = d.range.start.character, .severity = d.severity, .message = d.message, .source = d.source });
    };
    return out.items;
}

pub fn drawPanel(app: *App, ui: Ui, area: Rect) Allocator.Error!void {
    const rows = try panelRows(app, ui.arena);
    var total: usize = 0;
    var it = app.lsp.diags.valueIterator();
    while (it.next()) |fd| total += fd.*.items.len;
    const subtitle = if (rows.len == total) ui.fmt(" ({d})", .{total}) else ui.fmt(" ({d} of {d})", .{ rows.len, total });
    const empty: list_panel.EmptyState = if (total == 0)
        .{ .message = "No problems — the language servers are quiet.", .hint = "Diagnostics land here as servers publish them." }
    else
        .{ .message = "No matches — Esc clears" };
    const caret = DiagPanel.draw(&app.lsp.panel, ui, area, .{
        .panel = .diagnostics,
        .label = "DIAGNOSTICS",
        .subtitle = subtitle,
        .sort_chip = app.lsp.severity_filter.label(),
        .sort_widest = 9,
        .rows = rows,
        .paintRow = diagnostics_view.paintRow,
        .empty = empty,
        .show_refresh = false,
    });
    if (caret) |c| app.cursor_pos = .{ .x = c.x, .y = c.y };
}

fn openRow(app: *App, row: DiagRow) Allocator.Error!void {
    const path = try app.frame.allocator().dupe(u8, row.path);
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    if (app.panes.editor(id)) |e| {
        const enc = if (serverFor(app, path)) |s| s.encoding else .utf16;
        e.buf.editor.anchor = null;
        e.buf.editor.setCursor(types.byteOf(e.buf.editor.bytes(), .{ .line = row.line, .character = row.character }, enc));
        e.view.scroll_line = @intCast(e.buf.editor.currentLine() -| app.pane_rows / 2);
    }
}

/// Keys while the panel has focus.
pub fn panelKey(app: *App, k: Key) Allocator.Error!bool {
    const st = &app.lsp;
    switch (try DiagPanel.handleKey(&st.panel, app.gpa, k)) {
        .consumed, .filter_changed => return true,
        .activate => |i| {
            const rows = try panelRows(app, app.frame.allocator());
            if (i < rows.len) try openRow(app, rows[i]);
            return true;
        },
        .new_activate => {},
        .ignored => {},
    }
    if (st.panel.filter_focused) return false;
    switch (k.code) {
        .esc => {
            if (app.active) |a| app.focus = .{ .pane = a };
            return true;
        },
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                's' => cycleFilter(app) catch {},
                else => return false,
            }
            return true;
        },
        else => return false,
    }
}

pub fn focusPanel(app: *App) void {
    if (app.activeBuffer()) |b| b.input.onBlur();
    app.focus = .{ .panel = .diagnostics };
    app.needs_render = true;
}

pub fn rowMouse(app: *App, idx: u32, m: Mouse) Allocator.Error!void {
    const st = &app.lsp;
    switch (m.kind) {
        .press => {
            focusPanel(app);
            const was = st.panel.cursor;
            st.panel.cursor = idx;
            if (m.button == .left and was == idx) {
                const rows = try panelRows(app, app.frame.allocator());
                if (idx < rows.len) try openRow(app, rows[idx]);
            }
        },
        .scroll_up => st.panel.cursor -|= 3,
        .scroll_down => st.panel.cursor += 3,
        else => {},
    }
}

pub fn chipMouse(app: *App, m: Mouse) Allocator.Error!void {
    if (m.kind != .press) return;
    cycleFilter(app) catch {};
}

pub fn filterMouse(app: *App, m: Mouse) void {
    if (m.kind != .press) return;
    focusPanel(app);
    app.lsp.panel.filter_focused = true;
}

pub fn scrollbarMouse(app: *App, bar: Rect, m: Mouse) void {
    const st = &app.lsp;
    const total = st.panel.total;
    if (total == 0 or bar.h == 0) return;
    switch (m.kind) {
        .press, .drag => {
            focusPanel(app);
            st.panel.cursor = @min((m.y -| bar.y) * total / bar.h, total - 1);
        },
        .scroll_up => st.panel.cursor -|= 3,
        .scroll_down => st.panel.cursor = @min(st.panel.cursor + 3, total - 1),
        else => {},
    }
}

/// `lsp.diagnostics`: the panel in its column (the right, by default).
pub fn showDiagnostics(app: *App) CommandError!void {
    side.place(app, .diagnostics, true);
}

pub fn cycleFilter(app: *App) CommandError!void {
    app.lsp.severity_filter = app.lsp.severity_filter.next();
    app.lsp.panel.cursor = 0;
    app.toast("diagnostics filter: {s}", .{app.lsp.severity_filter.label()});
    app.needs_render = true;
}

// ─── requests from the cursor ───────────────────────────────────────────

pub const Target = struct { server: *Server, pane: PaneId, e: *EditorPane, path: []const u8 };

/// The active editor's server, or the reason there is none.
pub fn requireServer(app: *App, what: []const u8) CommandError!Target {
    const arena = app.frame.allocator();
    const pane = app.active orelse return app.diag.fail(arena, "no active editor", .{});
    const e = app.panes.editor(pane) orelse return app.diag.fail(arena, "no active editor", .{});
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "LSP needs a saved file", .{});
    const s = serverFor(app, path) orelse return app.diag.fail(arena, "no language server for this file ({s})", .{what});
    if (!s.ready) {
        // A server answers `initialize` a second or two after its spawn
        // (tsserver boots node first). A `gr` in that window is kept and
        // run when the answer lands, not bounced back to be typed again.
        if (app.running_cmd) |ref| if (ref == .static) {
            app.lsp.deferred = .{ .server = s.id, .cmd = ref.static };
            return app.diag.fail(arena, "language server for {s} is starting — {s} runs when it is ready", .{ s.name, what });
        };
        return app.diag.fail(arena, "language server for {s} is still starting", .{s.name});
    }
    syncPane(app, pane, e);
    return .{ .server = s, .pane = pane, .e = e, .path = path };
}

fn docPosAt(t: Target, arena: Allocator, byte: usize) Allocator.Error!Server.DocPos {
    return t.server.docPos(arena, t.path, t.e.buf.editor.bytes(), byte);
}

fn sendAt(app: *App, t: Target, kind: ReqKind, method: []const u8, extra: u32) CommandError!void {
    const arena = app.frame.allocator();
    const params = try docPosAt(t, arena, t.e.buf.editor.cursor);
    _ = t.server.request(kind, method, params, .{ .pane = t.pane, .extra = extra }) catch |err| return app.diag.fail(arena, "LSP {s}: {s}", .{ method, @errorName(err) });
}

/// The identifier under the cursor (for rename's seed).
fn wordAt(text: []const u8, cursor: usize) []const u8 {
    var start = @min(cursor, text.len);
    while (start > 0 and isIdent(text[start - 1])) start -= 1;
    var end = @min(cursor, text.len);
    while (end < text.len and isIdent(text[end])) end += 1;
    return text[start..end];
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ── go to ──

pub fn gotoDefinition(app: *App) CommandError!void {
    // `gd` on a `{{VAR}}` in a request file: its line in the env file.
    if (try @import("http.zig").jumpVarAtCursor(app)) return;
    const t = try requireServer(app, "definition");
    try sendAt(app, t, .definition, "textDocument/definition", 0);
}

pub fn gotoDeclaration(app: *App) CommandError!void {
    const t = try requireServer(app, "declaration");
    try sendAt(app, t, .declaration, "textDocument/declaration", 0);
}

pub fn gotoTypeDefinition(app: *App) CommandError!void {
    const t = try requireServer(app, "type definition");
    try sendAt(app, t, .type_definition, "textDocument/typeDefinition", 0);
}

pub fn gotoImplementation(app: *App) CommandError!void {
    const t = try requireServer(app, "implementation");
    try sendAt(app, t, .implementation, "textDocument/implementation", 0);
}

pub fn references(app: *App) CommandError!void {
    const t = try requireServer(app, "references");
    const arena = app.frame.allocator();
    const pos = try docPosAt(t, arena, t.e.buf.editor.cursor);
    _ = t.server.request(.references, "textDocument/references", .{ .textDocument = pos.textDocument, .position = pos.position, .context = .{ .includeDeclaration = true } }, .{ .pane = t.pane }) catch |err| return app.diag.fail(arena, "LSP references: {s}", .{@errorName(err)});
}

/// `lsp.peek_definition`: the definition opens in a split below.
pub fn peekDefinition(app: *App) CommandError!void {
    const t = try requireServer(app, "peek");
    try sendAt(app, t, .definition, "textDocument/definition", goto_split);
}

/// `lsp.peek_definition_overlay`: a floating box; the cursor stays.
/// `pending_peek` is set only once the request is out, so a failure to
/// reach a server cannot leave it armed for the next `gd`.
pub fn peekDefinitionOverlay(app: *App) CommandError!void {
    const t = try requireServer(app, "peek");
    try sendAt(app, t, .definition, "textDocument/definition", goto_overlay);
    app.lsp.pending_peek = true;
}

const goto_jump: u32 = 0;
const goto_split: u32 = 1;
const goto_overlay: u32 = 2;

fn gotoResult(app: *App, kind: ReqKind, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const arena = app.frame.allocator();
    const locs = try types.readLocations(arena, result);
    const overlay = ctx.extra == goto_overlay or app.lsp.pending_peek;
    app.lsp.pending_peek = false;
    if (locs.len == 0) {
        app.toast("no {s}", .{switch (kind) {
            .declaration => "declaration",
            .type_definition => "type definition",
            .implementation => "implementation",
            else => "definition",
        }});
        return;
    }
    if (overlay) return openPeek(app, ctx.pane, locs[0]);
    if (locs.len == 1) return jumpTo(app, locs[0], ctx.extra == goto_split);
    try locationsPicker(app, "Definitions", locs, "no definition");
}

/// Open `loc`'s file with the cursor on its range; `split` puts it in
/// a new leaf below instead of the current leaf.
fn jumpTo(app: *App, loc: types.Location, split: bool) Allocator.Error!void {
    const path = try app.frame.allocator().dupe(u8, loc.path);
    const cur = app.active;
    const id = app.openPath(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            app.toast("open {s}: {s}", .{ app.relPath(path), @errorName(err) });
            return;
        },
    };
    if (split and cur != null and cur.? != id) {
        const layout = app.layouts.current();
        _ = layout.removePane(id);
        if (try layout.split(cur.?, .vertical, id) == null) _ = try layout.showIn(null, id);
        app.setActive(id);
    }
    if (app.panes.editor(id)) |e| {
        const enc = if (serverFor(app, path)) |s| s.encoding else .utf16;
        e.buf.editor.anchor = null;
        e.buf.editor.setCursor(types.byteOf(e.buf.editor.bytes(), loc.range.start, enc));
        e.view.scroll_line = @intCast(e.buf.editor.currentLine() -| app.pane_rows / 2);
    }
    app.needs_render = true;
}

fn dropLocs(app: *App) void {
    if (app.lsp.picker_locs) |*l| l.arena.deinit();
    app.lsp.picker_locs = null;
}

/// A picker over locations: `rel:line:col  the line's text`.
fn locationsPicker(app: *App, title: []const u8, locs: []const types.Location, empty_msg: []const u8) Allocator.Error!void {
    if (locs.len == 0) {
        app.toast("{s}", .{empty_msg});
        return;
    }
    dropLocs(app);
    var set: LocSet = .{ .arena = alloc.SnapshotArena.init(app.gpa), .items = &.{} };
    errdefer set.arena.deinit();
    const a = set.arena.allocator();
    const items = try a.alloc(types.Location, locs.len);
    for (locs, 0..) |l, i| items[i] = .{ .path = try a.dupe(u8, l.path), .range = l.range };
    set.items = items;
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (items) |l| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s}:{d}:{d}", .{ app.relPath(l.path), l.range.start.line + 1, l.range.start.character + 1 }));
        try details.append(gpa, try gpa.dupe(u8, try lineTextOf(app, l)));
    }
    app.lsp.picker_locs = set;
    cmd_picker.openPickerWith(app, title, .lsp_locations, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try gpa.alloc([]u8, 0)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

/// The text of a location's line: from an open buffer, else the file.
fn lineTextOf(app: *App, l: types.Location) Allocator.Error![]const u8 {
    const arena = app.frame.allocator();
    const text: []const u8 = if (app.panes.findPath(l.path)) |id| app.panes.editor(id).?.buf.editor.bytes() else Io.Dir.cwd().readFileAlloc(app.io, l.path, arena, .limited(4 * 1024 * 1024)) catch return "";
    var line: u32 = 0;
    var start: usize = 0;
    while (line < l.range.start.line) : (line += 1) {
        start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return "") + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return std.mem.trim(u8, text[start..end], " \t");
}

// ── peek ──

fn openPeek(app: *App, pane: PaneId, loc: types.Location) Allocator.Error!void {
    closePeek(app);
    var peek: Peek = .{ .pane = pane, .arena = alloc.SnapshotArena.init(app.gpa), .path = "", .lines = &.{}, .first_line = 0, .highlight = 0 };
    errdefer peek.arena.deinit();
    const a = peek.arena.allocator();
    const frame = app.frame.allocator();
    const text: []const u8 = if (app.panes.findPath(loc.path)) |id| app.panes.editor(id).?.buf.editor.bytes() else Io.Dir.cwd().readFileAlloc(app.io, loc.path, frame, .limited(4 * 1024 * 1024)) catch {
        app.toast("peek: can't read {s}", .{app.relPath(loc.path)});
        return;
    };
    const around: u32 = 6;
    const anchor = loc.range.start.line;
    const first = anchor -| around;
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var ln: u32 = 0;
    while (it.next()) |raw| : (ln += 1) {
        if (ln < first) continue;
        if (ln > anchor + around) break;
        try lines.append(a, try a.dupe(u8, std.mem.trimEnd(u8, raw, "\r")));
    }
    peek.path = try a.dupe(u8, loc.path);
    peek.lines = lines.items;
    peek.first_line = first;
    peek.highlight = anchor - first;
    app.lsp.peek = peek;
    app.needs_render = true;
}

pub fn closePeek(app: *App) void {
    if (app.lsp.peek) |*p| p.arena.deinit();
    app.lsp.peek = null;
    app.needs_render = true;
}

// ── hover + signature help ──

pub fn hover(app: *App) CommandError!void {
    // While the debugger is stopped, `K` / the hover verb evaluates the
    // word under the cursor instead (`dap.hoverAtCursor`).
    if (try @import("dap.zig").hoverAtCursor(app)) return;
    const t = try requireServer(app, "hover");
    try sendAt(app, t, .hover, "textDocument/hover", @intCast(@min(t.e.buf.editor.cursor, std.math.maxInt(u32))));
}

pub fn signatureHelp(app: *App) CommandError!void {
    const t = try requireServer(app, "signature help");
    try sendAt(app, t, .signature_help, "textDocument/signatureHelp", @intCast(@min(t.e.buf.editor.cursor, std.math.maxInt(u32))));
}

/// The hover box with `lines`, anchored at byte `at` of `pane` — for
/// the debugger's evaluations (`dap.evaluate_hover`).
pub fn showHoverLines(app: *App, pane: PaneId, at: usize, lines: []const []const u8) Allocator.Error!void {
    return showHover(app, .{ .pane = pane, .extra = @intCast(@min(at, std.math.maxInt(u32))) }, lines, 0);
}

fn showHover(app: *App, ctx: Ctx, lines: []const []const u8, active: usize) Allocator.Error!void {
    closeHover(app);
    if (lines.len == 0) {
        app.toast("hover: (nothing)", .{});
        return;
    }
    const pages = try app.frame.allocator().alloc([]const []const u8, 1);
    pages[0] = lines;
    try showPages(app, ctx, pages, active);
}

fn showPages(app: *App, ctx: Ctx, pages: []const []const []const u8, active: usize) Allocator.Error!void {
    closeHover(app);
    var h: Hover = .{ .pane = ctx.pane, .arena = alloc.SnapshotArena.init(app.gpa), .pages = &.{}, .active = active, .at = ctx.extra };
    errdefer h.arena.deinit();
    const a = h.arena.allocator();
    const out = try a.alloc([]const []const u8, pages.len);
    for (pages, 0..) |page, i| {
        const copy = try a.alloc([]const u8, page.len);
        for (page, 0..) |line, j| copy[j] = try a.dupe(u8, line);
        out[i] = copy;
    }
    h.pages = out;
    app.lsp.hover = h;
    app.needs_render = true;
}

fn showSignatures(app: *App, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const arena = app.frame.allocator();
    const r = result orelse {
        app.toast("signature help: (nothing)", .{});
        return;
    };
    const sigs = jsonrpc.getArr(r, "signatures") orelse &.{};
    if (sigs.len == 0) {
        app.toast("signature help: (nothing)", .{});
        return;
    }
    var pages: std.ArrayListUnmanaged([]const []const u8) = .empty;
    for (sigs) |sig| {
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        try lines.append(arena, jsonrpc.getStr(sig, "label") orelse "");
        if (jsonrpc.getField(sig, "documentation")) |doc| {
            const text: ?[]const u8 = switch (doc) {
                .string => |s| s,
                .object => jsonrpc.getStr(doc, "value"),
                else => null,
            };
            if (text) |tx| {
                var it = std.mem.splitScalar(u8, tx, '\n');
                while (it.next()) |l| try lines.append(arena, l);
            }
        }
        try pages.append(arena, lines.items);
    }
    const active: usize = @intCast(@max(jsonrpc.getInt(r, "activeSignature") orelse 0, 0));
    try showPages(app, ctx, pages.items, @min(active, pages.items.len - 1));
}

pub fn signatureStep(app: *App, dir: i32) CommandError!void {
    const h = &(app.lsp.hover orelse return app.diag.fail(app.frame.allocator(), "no signature help open", .{}));
    if (h.pages.len < 2) return;
    const n: i64 = @intCast(h.pages.len);
    h.active = @intCast(@mod(@as(i64, @intCast(h.active)) + dir, n));
    h.scroll = 0;
    app.needs_render = true;
}

pub fn closeHover(app: *App) void {
    if (app.lsp.hover) |*h| h.arena.deinit();
    app.lsp.hover = null;
    app.needs_render = true;
}

// ── completion ──

/// `lsp.completion` (ctrl+space): a request at the cursor; the popup
/// opens when the reply lands.
pub fn completion(app: *App) CommandError!void {
    const t = try requireServer(app, "completion");
    try requestCompletion(app, t, true, null);
}

fn requestCompletion(app: *App, t: Target, manual: bool, trigger: ?u8) CommandError!void {
    const arena = app.frame.allocator();
    if (app.lsp.completion_req) |r| r.server.cancel(r.id);
    app.lsp.completion_req = null;
    const ed = t.e.buf.editor;
    const w = snippets.wordBefore(ed.bytes(), ed.cursor);
    const pos = try docPosAt(t, arena, ed.cursor);
    const Context = struct { triggerKind: u8, triggerCharacter: ?[]const u8 = null };
    const context: Context = if (trigger) |c| .{ .triggerKind = 2, .triggerCharacter = try arena.dupe(u8, &.{c}) } else .{ .triggerKind = 1 };
    const id = t.server.request(.completion, "textDocument/completion", .{ .textDocument = pos.textDocument, .position = pos.position, .context = context }, .{ .pane = t.pane, .extra = @as(u32, @intCast(@min(w.start, std.math.maxInt(u32)))) | (if (manual) manual_flag else 0) }) catch |err| return app.diag.fail(arena, "LSP completion: {s}", .{@errorName(err)});
    app.lsp.completion_req = .{ .server = t.server, .id = id };
}

const manual_flag: u32 = 0x8000_0000;

/// Typing in an editor: a trigger character or an identifier of two
/// characters opens the popup; a cursor that left the word closes it.
/// An on-type formatting trigger asks the server for its edits.
pub fn onTyped(app: *App, pane: PaneId, e: *EditorPane, k: Key) Allocator.Error!void {
    const c = k.typed() orelse return;
    const path = e.buf.doc.path orelse return;
    const s = serverFor(app, path) orelse return;
    if (!s.ready) return;
    if (s.caps.on_type_triggers.len > 0) {
        syncPane(app, pane, e);
        format_app.onTyped(app, pane, e, s, c);
    }
    if (app.lsp.completion) |comp| if (comp.pane == pane) {
        if (e.buf.editor.cursor < comp.start) closeCompletion(app);
        return;
    };
    if (!s.caps.completion) return;
    const ed = e.buf.editor;
    const w = snippets.wordBefore(ed.bytes(), ed.cursor);
    const is_trigger = c < 128 and std.mem.indexOfScalar(u8, s.caps.trigger_chars, @intCast(c)) != null;
    const is_word = c < 128 and isIdent(@intCast(c)) and w.word.len >= 2;
    if (!is_trigger and !is_word) return;
    syncPane(app, pane, e);
    const t: Target = .{ .server = s, .pane = pane, .e = e, .path = path };
    requestCompletion(app, t, false, if (is_trigger) @intCast(c) else null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

fn openCompletion(app: *App, s: *Server, ctx: Ctx, result: ?Value, msg: *jsonrpc.Incoming) Allocator.Error!bool {
    app.lsp.completion_req = null;
    const manual = ctx.extra & manual_flag != 0;
    const start: usize = ctx.extra & ~manual_flag;
    const e = app.panes.editor(ctx.pane) orelse return false;
    if (app.active != ctx.pane) return false;
    var comp: Completion = .{ .pane = ctx.pane, .server = s, .start = start, .incoming = msg, .arena = alloc.SnapshotArena.init(app.gpa), .items = &.{}, .manual = manual };
    comp.items = try types.readCompletions(comp.arena.allocator(), result);
    if (comp.items.len == 0) {
        comp.arena.deinit();
        if (manual) app.toast("no completions", .{});
        return false;
    }
    // The cursor moved on since the request: keep it only while the
    // word being completed is still under it.
    if (e.buf.editor.cursor < start) {
        comp.arena.deinit();
        return false;
    }
    closeCompletion(app);
    app.lsp.completion = comp;
    app.needs_render = true;
    return true;
}

pub fn closeCompletion(app: *App) void {
    if (app.lsp.completion) |*c| c.destroy(app.gpa);
    app.lsp.completion = null;
    app.needs_render = true;
}

/// The popup's items that match the word typed so far, best first.
/// Frame arena; indices into `comp.items`.
pub fn visibleCompletions(app: *App, arena: Allocator) Allocator.Error![]u32 {
    const comp = &(app.lsp.completion orelse return &.{});
    const e = app.panes.editor(comp.pane) orelse return &.{};
    const text = e.buf.editor.bytes();
    const word = text[@min(comp.start, text.len)..@min(e.buf.editor.cursor, text.len)];
    const Scored = struct { idx: u32, score: u32, sort: []const u8 };
    var scored: std.ArrayListUnmanaged(Scored) = .empty;
    for (comp.items, 0..) |it, i| {
        const key = it.filter_text orelse it.label;
        const score = if (word.len == 0) fuzzy.base else (fuzzy.score(word, key) orelse continue);
        try scored.append(arena, .{ .idx = @intCast(i), .score = score, .sort = it.sort_text orelse it.label });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.sort, b.sort);
        }
    }.lt);
    const out = try arena.alloc(u32, scored.items.len);
    for (scored.items, 0..) |s, i| out[i] = s.idx;
    return out;
}

/// Keys the popups take before the editor sees them. False = not ours.
pub fn interceptKey(app: *App, k: Key) Allocator.Error!bool {
    if (try rename_app.interceptKey(app, k)) return true;
    if (app.lsp.peek != null) {
        const p = &app.lsp.peek.?;
        switch (k.code) {
            .esc => closePeek(app),
            .down => p.scroll += 1,
            .up => p.scroll -|= 1,
            .char => |c| switch (c) {
                'j' => p.scroll += 1,
                'k' => p.scroll -|= 1,
                'q' => closePeek(app),
                else => return false,
            },
            else => return false,
        }
        app.needs_render = true;
        return true;
    }
    if (app.lsp.hover != null) {
        const h = &app.lsp.hover.?;
        switch (k.code) {
            .down => h.scroll += 1,
            .up => h.scroll -|= 1,
            .esc => closeHover(app),
            .char => |c| if (!k.mods.ctrl and !k.mods.alt) switch (c) {
                'j' => h.scroll += 1,
                'k' => h.scroll -|= 1,
                else => {
                    closeHover(app);
                    return false;
                },
            } else {
                closeHover(app);
                return false;
            },
            else => {
                closeHover(app);
                return false;
            },
        }
        app.needs_render = true;
        return true;
    }
    // No popup: Enter on a code lens's line runs it (vim Normal only).
    const comp = &(app.lsp.completion orelse return decor.interceptKey(app, k));
    if (app.active != comp.pane) {
        closeCompletion(app);
        return false;
    }
    const vis = try visibleCompletions(app, app.frame.allocator());
    const n = vis.len;
    if (n == 0 and !comp.manual) {
        closeCompletion(app);
        return false;
    }
    const ctrl = k.mods.ctrl and !k.mods.alt;
    switch (k.code) {
        .down => comp.selected = @min(comp.selected + 1, n -| 1),
        .up => comp.selected -|= 1,
        .page_down => comp.selected = @min(comp.selected + completion_view.max_rows, n -| 1),
        .page_up => comp.selected -|= completion_view.max_rows,
        .esc => closeCompletion(app),
        .tab, .enter => {
            if (n == 0) {
                closeCompletion(app);
                return false;
            }
            try acceptCompletion(app, vis[@min(comp.selected, n - 1)]);
        },
        .char => |c| if (ctrl and (c == 'n' or c == 'j')) {
            comp.selected = @min(comp.selected + 1, n -| 1);
        } else if (ctrl and (c == 'p' or c == 'k')) {
            comp.selected -|= 1;
        } else if (ctrl and c == 'e') {
            closeCompletion(app);
        } else return false,
        else => return false,
    }
    app.needs_render = true;
    return true;
}

/// A click on popup row `i` (index into the visible list).
pub fn clickCompletion(app: *App, i: usize) Allocator.Error!void {
    const vis = try visibleCompletions(app, app.frame.allocator());
    if (i >= vis.len) return;
    try acceptCompletion(app, vis[i]);
}

/// Insert item `idx`: the server's edit range, else the word; a snippet
/// body goes through the snippet machinery so its stops Tab-cycle.
fn acceptCompletion(app: *App, idx: u32) Allocator.Error!void {
    const comp = &(app.lsp.completion orelse return);
    const e = app.panes.editor(comp.pane) orelse return closeCompletion(app);
    const item = comp.items[idx];
    const ed = e.buf.editor;
    const text = ed.bytes();
    var start = comp.start;
    var end = ed.cursor;
    if (item.edit_range) |r| {
        start = types.byteOf(text, r.start, comp.server.encoding);
        end = @max(types.byteOf(text, r.end, comp.server.encoding), ed.cursor);
    }
    start = @min(start, end);
    const gpa = app.gpa;
    const insert = try gpa.dupe(u8, item.insert_text);
    defer gpa.free(insert);
    const is_snippet = item.format == .snippet;
    const pane = comp.pane;
    const server = comp.server;
    const raw = item.raw;
    const has_extra = jsonrpc.getArr(raw, "additionalTextEdits") != null;
    const arena = app.frame.allocator();
    const extra_edits = if (has_extra) try types.readTextEdits(arena, jsonrpc.getField(raw, "additionalTextEdits")) else &.{};
    const label = try arena.dupe(u8, item.label);
    const wants_resolve = !has_extra and server.caps.completion_resolve;
    const raw_json: ?[]u8 = if (wants_resolve) jsonrpc.stringify(gpa, raw) catch null else null;
    defer if (raw_json) |j| gpa.free(j);
    closeCompletion(app);
    if (is_snippet) {
        var parsed = try snippets.parse(gpa, insert);
        defer parsed.deinit(gpa);
        app.snippets.endSession();
        const body = try arena.dupe(u8, parsed.text);
        try app.splice(e, start, end, body);
        const first: ?snippets.Stop = if (parsed.stops.len > 0) parsed.stops[0] else null;
        const land = start + (if (first) |f| f.pos else parsed.text.len);
        ed.anchor = null;
        ed.setCursor(@min(land, ed.len()));
        if (first) |f| if (f.default_len > 0) {
            ed.anchor = land;
            ed.setCursor(@min(land + f.default_len, ed.len()));
        };
        if (parsed.stops.len > 1) {
            const stops = try gpa.alloc(snippets.Stop, parsed.stops.len);
            for (parsed.stops, 0..) |s, i| stops[i] = .{ .pos = start + s.pos, .default_len = s.default_len, .exit = if (i == 0 and s.default_len > 0) start + s.pos + s.default_len else null };
            app.snippets.session = .{ .pane = pane, .stops = stops, .current = 0, .seen_seq = ed.doc.edits.head() };
        }
    } else {
        try app.splice(e, start, end, insert);
    }
    if (extra_edits.len > 0) try applyEditsToPane(app, e, extra_edits, server.encoding);
    if (raw_json) |j| {
        // Auto-imports ride on the resolved item; ask for it now.
        const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"completionItem/resolve\",\"params\":{s}}}", .{ server.transport.allocId(), j });
        defer gpa.free(body);
        const id = server.transport.next_id - 1;
        try server.transport.expect(id, .{ .kind = @intFromEnum(ReqKind.completion_resolve), .ctx = (Ctx{ .pane = pane }).pack() });
        server.transport.send(body) catch {
            _ = server.transport.forget(id);
        };
    }
    _ = label;
    app.needs_render = true;
}

fn acceptResolved(app: *App, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const r = result orelse return;
    const edits = try types.readTextEdits(app.frame.allocator(), jsonrpc.getField(r, "additionalTextEdits"));
    if (edits.len == 0) return;
    const e = app.panes.editor(ctx.pane) orelse return;
    const path = e.buf.doc.path orelse return;
    const enc = if (serverFor(app, path)) |s| s.encoding else .utf16;
    try applyEditsToPane(app, e, edits, enc);
}

// ── rename / formatting / edits ──

pub fn rename(app: *App) CommandError!void {
    const t = try requireServer(app, "rename");
    const seed = wordAt(t.e.buf.editor.bytes(), t.e.buf.editor.cursor);
    var state = app_mod.Prompt.init(app.gpa, "Rename symbol");
    errdefer app_mod.Prompt.deinit(&state, app.gpa);
    try state.setText(app.gpa, seed);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = state, .purpose = .lsp_rename } };
    app.focus = .overlay;
    app.needs_render = true;
}

pub fn acceptRename(app: *App, text_in: []const u8) Allocator.Error!void {
    const name = std.mem.trim(u8, text_in, " \t");
    if (name.len == 0) return;
    const t = requireServer(app, "rename") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m});
            return;
        },
    };
    const arena = app.frame.allocator();
    const pos = try docPosAt(t, arena, t.e.buf.editor.cursor);
    _ = t.server.request(.rename, "textDocument/rename", .{ .textDocument = pos.textDocument, .position = pos.position, .newName = name }, .{ .pane = t.pane }) catch |err| {
        app.toast("LSP rename: {s}", .{@errorName(err)});
    };
}

pub fn format(app: *App) CommandError!void {
    const t = try requireServer(app, "format");
    if (!t.server.caps.formatting) return app.diag.fail(app.frame.allocator(), "{s} does not format documents", .{t.server.name});
    try requestFormatting(app, t.server, t.pane, t.e, false);
}

const format_save_flag: u32 = 1;

fn requestFormatting(app: *App, s: *Server, pane: PaneId, e: *EditorPane, then_save: bool) CommandError!void {
    const arena = app.frame.allocator();
    const path = e.buf.doc.path orelse return;
    const uri = try types.uriFromPath(arena, path);
    _ = s.request(.formatting, "textDocument/formatting", .{ .textDocument = .{ .uri = uri }, .options = .{ .tabSize = app.cfg.editor.tab_width, .insertSpaces = true, .trimTrailingWhitespace = true } }, .{ .pane = pane, .extra = if (then_save) format_save_flag else 0 }) catch |err| return app.diag.fail(arena, "LSP format: {s}", .{@errorName(err)});
}

fn applyFormatting(app: *App, s: *Server, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const e = app.panes.editor(ctx.pane) orelse return;
    const edits = try types.readTextEdits(app.frame.allocator(), result);
    if (edits.len == 0) return;
    try applyEditsToPane(app, e, edits, s.encoding);
    if (ctx.extra & format_save_flag != 0) {
        e.buf.save(app.io) catch {};
    } else if (e.buf.doc.path) |p| app.toast("formatted {s}", .{app.relPath(p)});
}

/// Apply `edits` to one pane, last first so earlier offsets stay valid.
/// One undo step; the cursor keeps its byte where it can.
pub fn applyEditsToPane(app: *App, e: *EditorPane, edits_in: []const types.TextEdit, enc: types.Encoding) Allocator.Error!void {
    const arena = app.frame.allocator();
    const edits = try arena.dupe(types.TextEdit, edits_in);
    std.mem.sort(types.TextEdit, edits, {}, struct {
        fn lt(_: void, a: types.TextEdit, b: types.TextEdit) bool {
            if (a.range.start.line != b.range.start.line) return a.range.start.line > b.range.start.line;
            return a.range.start.character > b.range.start.character;
        }
    }.lt);
    const ed = e.buf.editor;
    const cursor = ed.cursor;
    for (edits) |te| {
        const text = ed.bytes();
        const start = types.byteOf(text, te.range.start, enc);
        const end = @max(types.byteOf(text, te.range.end, enc), start);
        const new_text = try arena.dupe(u8, te.new_text);
        try app.splice(e, start, end, new_text);
    }
    ed.anchor = null;
    ed.setCursor(@min(cursor, ed.len()));
    app.needs_render = true;
}

/// A multi-file rename: the preview box takes over. The reply is not
/// adopted — the preview copies what it shows.
fn adoptRenamePreview(app: *App, s: *Server, edit: Value) Allocator.Error!bool {
    try rename_app.open(app, s, edit);
    return false;
}

/// A `WorkspaceEdit` (`changes` or `documentChanges`): every file's
/// edits, opening files that are not. Returns the edit count.
fn applyWorkspaceEdit(app: *App, s: *Server, edit: Value) Allocator.Error!usize {
    const arena = app.frame.allocator();
    var n: usize = 0;
    if (jsonrpc.getArr(edit, "documentChanges")) |changes| {
        for (changes) |ch| {
            const td = jsonrpc.getObj(ch, "textDocument") orelse continue; // create/rename/delete files: not applied
            const uri = jsonrpc.getStr(td, "uri") orelse continue;
            n += try applyFileEdits(app, s, arena, uri, jsonrpc.getField(ch, "edits"));
        }
        return n;
    }
    if (jsonrpc.getObj(edit, "changes")) |changes| switch (changes) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |kv| n += try applyFileEdits(app, s, arena, kv.key_ptr.*, kv.value_ptr.*);
        },
        else => {},
    };
    return n;
}

fn applyFileEdits(app: *App, s: *Server, arena: Allocator, uri: []const u8, edits_v: ?Value) Allocator.Error!usize {
    const path = (try types.pathFromUri(arena, uri)) orelse return 0;
    const edits = try types.readTextEdits(arena, edits_v);
    if (edits.len == 0) return 0;
    const keep_active = app.active;
    const id = app.panes.findPath(path) orelse (app.openEditor(path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    });
    const e = app.panes.editor(id) orelse return 0;
    try applyEditsToPane(app, e, edits, s.encoding);
    if (keep_active) |k| if (k != id and app.panes.get(k) != null) app.setActive(k);
    return edits.len;
}

// ── code actions ──

pub fn codeAction(app: *App) CommandError!void {
    const t = try requireServer(app, "code action");
    try requestActions(app, t, null, action_pick);
}

pub fn quickFix(app: *App) CommandError!void {
    const t = try requireServer(app, "quick fix");
    try requestActions(app, t, "quickfix", action_first);
}

pub fn organizeImports(app: *App) CommandError!void {
    const t = try requireServer(app, "organize imports");
    try requestActions(app, t, "source.organizeImports", action_first);
}

const action_pick: u32 = 0;
const action_first: u32 = 1;

fn requestActions(app: *App, t: Target, only: ?[]const u8, mode: u32) CommandError!void {
    const arena = app.frame.allocator();
    const ed = t.e.buf.editor;
    const text = ed.bytes();
    const line = ed.currentLine();
    const start = types.positionOf(text, ed.lineStart(line), t.server.encoding);
    const end = types.positionOf(text, ed.lineEnd(line), t.server.encoding);
    // The diagnostics on the line give the server its context.
    var diags: std.ArrayListUnmanaged(struct { range: types.Range, severity: u8, message: []const u8 }) = .empty;
    for (diagnosticsFor(app, t.path)) |d| if (d.range.start.line == line) try diags.append(arena, .{ .range = d.range, .severity = @intFromEnum(d.severity), .message = d.message });
    const uri = try types.uriFromPath(arena, t.path);
    const only_list: ?[]const []const u8 = if (only) |o| try arena.dupe([]const u8, &.{o}) else null;
    _ = t.server.request(.code_action, "textDocument/codeAction", .{
        .textDocument = .{ .uri = uri },
        .range = .{ .start = start, .end = end },
        .context = .{ .diagnostics = diags.items, .only = only_list },
    }, .{ .pane = t.pane, .extra = mode }) catch |err| return app.diag.fail(arena, "LSP code action: {s}", .{@errorName(err)});
}

fn dropActions(app: *App) void {
    if (app.lsp.picker_actions) |*a| {
        a.arena.deinit();
        a.incoming.destroy(app.gpa);
    }
    app.lsp.picker_actions = null;
}

fn openActions(app: *App, s: *Server, ctx: Ctx, result: ?Value, msg: *jsonrpc.Incoming) Allocator.Error!bool {
    dropActions(app);
    var set: ActionSet = .{ .arena = alloc.SnapshotArena.init(app.gpa), .incoming = msg, .items = &.{}, .server = s, .pane = ctx.pane };
    set.items = try types.readCodeActions(set.arena.allocator(), result);
    if (set.items.len == 0) {
        set.arena.deinit();
        app.toast("no code actions here", .{});
        return false;
    }
    app.lsp.picker_actions = set;
    if (ctx.extra == action_first) {
        try runAction(app, 0);
        return true;
    }
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (set.items) |a| {
        try labels.append(gpa, try gpa.dupe(u8, a.title));
        try details.append(gpa, try gpa.dupe(u8, a.kind orelse ""));
    }
    cmd_picker.openPickerWith(app, "Code actions", .lsp_code_actions, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try gpa.alloc([]u8, 0)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
    return true;
}

/// Apply action `idx`: its edit, else its command, else resolve it.
fn runAction(app: *App, idx: usize) Allocator.Error!void {
    const set = &(app.lsp.picker_actions orelse return);
    if (idx >= set.items.len) return;
    const a = set.items[idx];
    const s = set.server;
    if (jsonrpc.getObj(a.raw, "edit")) |edit| {
        const n = try applyWorkspaceEdit(app, s, edit);
        app.toast("{s} · applied {d} edit(s)", .{ a.title, n });
        if (jsonrpc.getObj(a.raw, "command") == null) return dropActions(app);
    }
    if (jsonrpc.getObj(a.raw, "command")) |cmd| {
        try executeCommand(app, s, cmd);
        return dropActions(app);
    }
    if (jsonrpc.getStr(a.raw, "command")) |_| {
        // A bare `Command` shape: title/command/arguments at the top.
        try executeCommand(app, s, a.raw);
        return dropActions(app);
    }
    // Neither: resolve for the edit.
    const gpa = app.gpa;
    const raw_json = try jsonrpc.stringify(gpa, a.raw);
    defer gpa.free(raw_json);
    const id = s.transport.allocId();
    const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"codeAction/resolve\",\"params\":{s}}}", .{ id, raw_json });
    defer gpa.free(body);
    try s.transport.expect(id, .{ .kind = @intFromEnum(ReqKind.code_action_resolve), .ctx = (Ctx{ .pane = set.pane }).pack() });
    s.transport.send(body) catch {
        _ = s.transport.forget(id);
    };
    app.toast("code action: resolving '{s}'…", .{a.title});
}

fn applyResolvedAction(app: *App, s: *Server, ctx: Ctx, result: ?Value) Allocator.Error!void {
    _ = ctx;
    defer dropActions(app);
    const r = result orelse return;
    if (jsonrpc.getObj(r, "edit")) |edit| {
        const n = try applyWorkspaceEdit(app, s, edit);
        app.toast("code action · applied {d} edit(s)", .{n});
    } else if (jsonrpc.getObj(r, "command")) |cmd| {
        try executeCommand(app, s, cmd);
    } else app.toast("code action: '{s}' has no edit", .{jsonrpc.getStr(r, "title") orelse "?"});
}

pub fn executeCommand(app: *App, s: *Server, cmd: Value) Allocator.Error!void {
    const name = jsonrpc.getStr(cmd, "command") orelse return;
    const gpa = app.gpa;
    const args_json = if (jsonrpc.getField(cmd, "arguments")) |a| try jsonrpc.stringify(gpa, a) else try gpa.dupe(u8, "[]");
    defer gpa.free(args_json);
    const id = s.transport.allocId();
    const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"workspace/executeCommand\",\"params\":{{\"command\":\"{s}\",\"arguments\":{s}}}}}", .{ id, name, args_json });
    defer gpa.free(body);
    try s.transport.expect(id, .{ .kind = @intFromEnum(ReqKind.execute_command) });
    s.transport.send(body) catch {
        _ = s.transport.forget(id);
        app.toast("code action: couldn't run '{s}'", .{name});
    };
}

// ── symbols ──

/// Ask for the file's symbols; the reply feeds the outline.
pub fn requestSymbols(app: *App, s: *Server, path: []const u8) void {
    if (!s.caps.document_symbol or !s.ready or !s.isOpen(path)) return;
    const arena = app.frame.allocator();
    const uri = types.uriFromPath(arena, path) catch return;
    const pane = app.panes.findPath(path) orelse return;
    _ = s.request(.document_symbol, "textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } }, .{ .pane = pane, .extra = 0 }) catch {};
}

/// `lsp.symbols`: the file's symbols in a picker.
pub fn symbols(app: *App) CommandError!void {
    const t = try requireServer(app, "symbols");
    const arena = app.frame.allocator();
    const uri = try types.uriFromPath(arena, t.path);
    _ = t.server.request(.document_symbol, "textDocument/documentSymbol", .{ .textDocument = .{ .uri = uri } }, .{ .pane = t.pane, .extra = symbols_pick }) catch |err| return app.diag.fail(arena, "LSP symbols: {s}", .{@errorName(err)});
}

const symbols_pick: u32 = 1;

fn storeSymbols(app: *App, ctx: Ctx, result: ?Value) Allocator.Error!void {
    if (ctx.extra == symbols_pick) return symbolsPicker(app, ctx, result, false);
    const e = app.panes.editor(ctx.pane) orelse return;
    const path = e.buf.doc.path orelse return;
    const gpa = app.gpa;
    const gop = try app.lsp.symbols.getOrPut(gpa, path);
    if (!gop.found_existing) {
        gop.key_ptr.* = gpa.dupe(u8, path) catch |err| {
            _ = app.lsp.symbols.remove(path);
            return err;
        };
        const set = try gpa.create(SymbolSet);
        set.* = .{ .arena = alloc.SnapshotArena.init(gpa) };
        gop.value_ptr.* = set;
    }
    const set = gop.value_ptr.*;
    set.arena.reset();
    set.items = &.{};
    const a = set.arena.allocator();
    const syms = try types.readSymbols(a, result);
    for (syms) |*s| s.name = try a.dupe(u8, s.name);
    set.items = syms;
    // The outline watching this file repaints from the new list.
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .editor => |*ed| if (ed.buf.doc.path) |pp| if (std.mem.eql(u8, pp, path)) {
            ed.syntax.dirty = true;
        },
        else => {},
    };
    app.needs_render = true;
}

/// The cached symbols for `path` (the outline prefers them to the
/// tree-sitter walk). Null when no server has answered.
pub fn symbolsFor(app: *App, path: []const u8) ?[]const types.Symbol {
    const set = app.lsp.symbols.get(path) orelse return null;
    return set.items;
}

fn dropSymbolPick(app: *App) void {
    if (app.lsp.picker_symbols) |*s| s.arena.deinit();
    app.lsp.picker_symbols = null;
}

fn symbolsPicker(app: *App, ctx: Ctx, result: ?Value, workspace: bool) Allocator.Error!void {
    dropSymbolPick(app);
    var pick: SymbolPick = .{ .arena = alloc.SnapshotArena.init(app.gpa), .items = &.{}, .pane = ctx.pane };
    errdefer pick.arena.deinit();
    const a = pick.arena.allocator();
    const syms = try types.readSymbols(a, result);
    for (syms) |*s| s.name = try a.dupe(u8, s.name);
    pick.items = syms;
    if (syms.len == 0) {
        pick.arena.deinit();
        app.toast("no symbols", .{});
        return;
    }
    const gpa = app.gpa;
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
    }
    for (syms) |s| {
        try labels.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ types.symbolKindLabel(s.kind), s.name }));
        if (workspace and s.path != null) {
            try details.append(gpa, try std.fmt.allocPrint(gpa, "{s}:{d}", .{ app.relPath(s.path.?), s.line + 1 }));
        } else try details.append(gpa, try std.fmt.allocPrint(gpa, ":{d}", .{s.line + 1}));
    }
    app.lsp.picker_symbols = pick;
    cmd_picker.openPickerWith(app, if (workspace) "Workspace symbols" else "Symbols", .lsp_symbols, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try gpa.alloc([]u8, 0)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    };
}

pub fn workspaceSymbols(app: *App) CommandError!void {
    _ = try requireServer(app, "workspace symbols");
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .prompt = .{ .state = app_mod.Prompt.init(app.gpa, "Workspace symbol"), .purpose = .lsp_workspace_symbol } };
    app.focus = .overlay;
    app.needs_render = true;
}

/// `picker.workspace_symbol` (VS Code `Ctrl+T`): every workspace symbol
/// straight into the one symbol picker — no query prompt, the picker's
/// own filter narrows. `lsp.symbols` and `lsp.workspace_symbols` land
/// in the same `.lsp_symbols` picker.
pub fn workspaceSymbolPicker(app: *App) CommandError!void {
    const t = try requireServer(app, "workspace symbols");
    const arena = app.frame.allocator();
    _ = t.server.request(.workspace_symbol, "workspace/symbol", .{ .query = "" }, .{ .pane = t.pane }) catch |err| return app.diag.fail(arena, "LSP workspace symbols: {s}", .{@errorName(err)});
}

pub fn acceptWorkspaceSymbol(app: *App, query: []const u8) Allocator.Error!void {
    const t = requireServer(app, "workspace symbols") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    _ = t.server.request(.workspace_symbol, "workspace/symbol", .{ .query = std.mem.trim(u8, query, " \t") }, .{ .pane = t.pane }) catch {};
}

/// A pick in one of the LSP pickers, by original index.
pub fn pickerAccept(app: *App, kind: app_mod.PickerKind, idx: usize) Allocator.Error!void {
    switch (kind) {
        .lsp_locations => {
            const set = app.lsp.picker_locs orelse return;
            if (idx < set.items.len) try jumpTo(app, set.items[idx], false);
            dropLocs(app);
        },
        .lsp_code_actions => try runAction(app, idx),
        .lsp_symbols => {
            const pick = app.lsp.picker_symbols orelse return;
            if (idx >= pick.items.len) return;
            const s = pick.items[idx];
            const path: []const u8 = s.path orelse (if (app.panes.editor(pick.pane)) |e| (e.buf.doc.path orelse return) else return);
            try jumpTo(app, .{ .path = path, .range = .{ .start = .{ .line = s.line, .character = s.character }, .end = .{ .line = s.line, .character = s.character } } }, false);
            dropSymbolPick(app);
        },
        else => {},
    }
}

// ── hierarchies: prepare, then the calls / types → a locations picker ──

pub fn incomingCalls(app: *App) CommandError!void {
    const t = try requireServer(app, "call hierarchy");
    try sendAt(app, t, .incoming_prepare, "textDocument/prepareCallHierarchy", 0);
}

pub fn outgoingCalls(app: *App) CommandError!void {
    const t = try requireServer(app, "call hierarchy");
    try sendAt(app, t, .outgoing_prepare, "textDocument/prepareCallHierarchy", 0);
}

pub fn supertypes(app: *App) CommandError!void {
    const t = try requireServer(app, "type hierarchy");
    try sendAt(app, t, .type_prepare, "textDocument/prepareTypeHierarchy", 0);
}

pub fn subtypes(app: *App) CommandError!void {
    const t = try requireServer(app, "type hierarchy");
    try sendAt(app, t, .type_prepare, "textDocument/prepareTypeHierarchy", 1);
}

fn hierarchyStep(app: *App, s: *Server, kind: ReqKind, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const r = result orelse Value.null;
    const items: []const Value = switch (r) {
        .array => |a| a.items,
        else => &.{},
    };
    if (items.len == 0) {
        app.toast("{s}: nothing under cursor", .{if (kind == .type_prepare) "type hierarchy" else "call hierarchy"});
        return;
    }
    const gpa = app.gpa;
    const item_json = try jsonrpc.stringify(gpa, items[0]);
    defer gpa.free(item_json);
    const next: ReqKind, const method: []const u8 = switch (kind) {
        .incoming_prepare => .{ .incoming_calls, "callHierarchy/incomingCalls" },
        .outgoing_prepare => .{ .outgoing_calls, "callHierarchy/outgoingCalls" },
        else => if (ctx.extra == 1) .{ .subtypes, "typeHierarchy/subtypes" } else .{ .supertypes, "typeHierarchy/supertypes" },
    };
    const id = s.transport.allocId();
    const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"item\":{s}}}}}", .{ id, method, item_json });
    defer gpa.free(body);
    try s.transport.expect(id, .{ .kind = @intFromEnum(next), .ctx = (Ctx{ .pane = ctx.pane }).pack() });
    s.transport.send(body) catch {
        _ = s.transport.forget(id);
    };
}

fn hierarchyLocations(app: *App, kind: ReqKind, result: ?Value) Allocator.Error!void {
    const arena = app.frame.allocator();
    const r = result orelse Value.null;
    const items: []const Value = switch (r) {
        .array => |a| a.items,
        else => &.{},
    };
    var locs: std.ArrayListUnmanaged(types.Location) = .empty;
    for (items) |it| {
        // Calls wrap the item in `from` / `to`; types are the items.
        const item = jsonrpc.getObj(it, "from") orelse jsonrpc.getObj(it, "to") orelse it;
        const uri = jsonrpc.getStr(item, "uri") orelse continue;
        const range = types.readRange(jsonrpc.getObj(item, "selectionRange") orelse jsonrpc.getObj(item, "range") orelse continue) orelse continue;
        const path = (try types.pathFromUri(arena, uri)) orelse continue;
        try locs.append(arena, .{ .path = path, .range = range });
    }
    const title: []const u8, const empty: []const u8 = switch (kind) {
        .incoming_calls => .{ "Incoming calls", "call hierarchy: no incoming calls" },
        .outgoing_calls => .{ "Outgoing calls", "call hierarchy: no outgoing calls" },
        .supertypes => .{ "Supertypes", "type hierarchy: no supertypes" },
        else => .{ "Subtypes", "type hierarchy: no subtypes" },
    };
    try locationsPicker(app, title, locs.items, empty);
}

// ── highlights, selection ranges, folds, inlay hints ──

pub fn highlightSymbol(app: *App) CommandError!void {
    const t = try requireServer(app, "highlight");
    try sendAt(app, t, .document_highlight, "textDocument/documentHighlight", 0);
}

pub fn clearHighlights(app: *App) CommandError!void {
    const e = try app.requireEditor();
    e.find.matches.clearRetainingCapacity();
    e.find.current = null;
    app.needs_render = true;
}

/// The usages land in the pane's find matches — the same paint.
fn applyHighlights(app: *App, s: *Server, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const e = app.panes.editor(ctx.pane) orelse return;
    const r = result orelse return;
    const items: []const Value = switch (r) {
        .array => |a| a.items,
        else => &.{},
    };
    e.find.matches.clearRetainingCapacity();
    e.find.current = null;
    const text = e.buf.editor.bytes();
    for (items) |it| {
        const range = types.readRange(jsonrpc.getObj(it, "range") orelse continue) orelse continue;
        const start = types.byteOf(text, range.start, s.encoding);
        const end = types.byteOf(text, range.end, s.encoding);
        if (end > start) try e.find.matches.append(app.gpa, .{ .start = start, .end = end });
    }
    std.mem.sort(find_mod.Range, e.find.matches.items, {}, struct {
        fn lt(_: void, a: find_mod.Range, b: find_mod.Range) bool {
            return a.start < b.start;
        }
    }.lt);
    app.toast("{d} usage(s) highlighted", .{e.find.matches.items.len});
    app.needs_render = true;
}

pub fn selectionExpand(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    if (app.lsp.ladder) |*l| if (l.pane == app.active) {
        if (l.idx + 1 >= l.ranges.len) return app.diag.fail(arena, "already at the widest selection", .{});
        l.idx += 1;
        applyLadderStep(app);
        return;
    };
    const t = try requireServer(app, "selection range");
    const pos = try docPosAt(t, arena, t.e.buf.editor.cursor);
    _ = t.server.request(.selection_range, "textDocument/selectionRange", .{ .textDocument = pos.textDocument, .positions = &[_]types.Position{pos.position} }, .{ .pane = t.pane }) catch |err| return app.diag.fail(arena, "LSP selection range: {s}", .{@errorName(err)});
}

pub fn selectionShrink(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const l = &(app.lsp.ladder orelse return app.diag.fail(arena, "no selection ladder — expand first", .{}));
    if (l.pane != app.active) return app.diag.fail(arena, "selection ladder belongs to a different pane", .{});
    if (l.idx == 0) return app.diag.fail(arena, "already at smallest selection", .{});
    l.idx -= 1;
    applyLadderStep(app);
}

fn applyLadderStep(app: *App) void {
    const l = app.lsp.ladder orelse return;
    const e = app.panes.editor(l.pane) orelse return;
    const r = l.ranges[l.idx];
    e.buf.editor.setSelection(@min(r[0], e.buf.editor.len()), @min(r[1], e.buf.editor.len()));
    app.needs_render = true;
}

fn applyLadder(app: *App, s: *Server, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const e = app.panes.editor(ctx.pane) orelse return;
    const r = result orelse return;
    const items: []const Value = switch (r) {
        .array => |a| a.items,
        else => &.{},
    };
    if (items.len == 0) {
        app.toast("no selection ranges returned", .{});
        return;
    }
    const text = e.buf.editor.bytes();
    var ranges: std.ArrayListUnmanaged([2]usize) = .empty;
    errdefer ranges.deinit(app.gpa);
    var node: ?Value = items[0];
    while (node) |n| : (node = jsonrpc.getObj(n, "parent")) {
        const range = types.readRange(jsonrpc.getObj(n, "range") orelse break) orelse break;
        const a = types.byteOf(text, range.start, s.encoding);
        const b = types.byteOf(text, range.end, s.encoding);
        if (b > a) try ranges.append(app.gpa, .{ a, b });
    }
    if (ranges.items.len == 0) {
        app.toast("no selection ranges returned", .{});
        return;
    }
    if (app.lsp.ladder) |old| app.gpa.free(old.ranges);
    app.lsp.ladder = .{ .pane = ctx.pane, .ranges = try ranges.toOwnedSlice(app.gpa), .idx = 0 };
    applyLadderStep(app);
}

pub fn foldAll(app: *App) CommandError!void {
    const t = try requireServer(app, "folding");
    const arena = app.frame.allocator();
    const uri = try types.uriFromPath(arena, t.path);
    _ = t.server.request(.folding_range, "textDocument/foldingRange", .{ .textDocument = .{ .uri = uri } }, .{ .pane = t.pane }) catch |err| return app.diag.fail(arena, "LSP fold: {s}", .{@errorName(err)});
}

fn applyFolds(app: *App, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const e = app.panes.editor(ctx.pane) orelse return;
    const r = result orelse return;
    const items: []const Value = switch (r) {
        .array => |a| a.items,
        else => &.{},
    };
    var n: usize = 0;
    const lines = e.buf.editor.lineCount();
    for (items) |it| {
        const start: usize = @intCast(@max(jsonrpc.getInt(it, "startLine") orelse continue, 0));
        const end: usize = @intCast(@max(jsonrpc.getInt(it, "endLine") orelse continue, 0));
        if (end <= start or end >= lines) continue;
        try e.buf.editor.folds.put(app.gpa, start, end);
        n += 1;
    }
    if (n == 0) app.toast("no fold ranges returned", .{}) else app.toast("folded {d} range(s)", .{n});
    app.needs_render = true;
}

// ─── popups: the frame ──────────────────────────────────────────────────

/// After the panes and the overlay: the completion popup, the hover box,
/// the peek overlay — each anchored at the active editor's cursor cell.
pub fn drawPopups(app: *App, ui: Ui, body: Rect) Allocator.Error!void {
    const cursor = app.cursor_pos;
    if (app.lsp.completion) |*comp| if (comp.pane == app.active and app.focus == .pane) {
        const vis = try visibleCompletions(app, ui.arena);
        if (vis.len == 0 and !comp.manual) {
            closeCompletion(app);
        } else if (vis.len > 0) {
            if (comp.selected >= vis.len) comp.selected = vis.len - 1;
            const rows = try ui.arena.alloc(completion_view.Row, vis.len);
            for (vis, 0..) |idx, i| {
                const it = comp.items[idx];
                rows[i] = .{ .label = it.label, .kind = types.completionKindLabel(it.kind), .detail = it.detail orelse "" };
            }
            const doc: ?[]const u8 = if (comp.items[vis[comp.selected]].documentation) |d| firstLine(d) else null;
            completion_view.draw(ui, body, cursor, &comp.scroll, .{ .rows = rows, .selected = comp.selected, .doc = doc });
        }
    };
    if (app.lsp.hover) |*h| if (h.pane == app.active) {
        hover_view.draw(ui, body, cursor, &h.scroll, .{ .lines = h.lines(), .page = h.active, .pages = h.pages.len });
    };
    if (app.lsp.peek) |*p| if (p.pane == app.active) {
        peek_view.draw(ui, body, &p.scroll, .{ .title = app.relPath(p.path), .lines = p.lines, .first_line = p.first_line, .highlight = p.highlight });
    };
    rename_app.draw(app, ui, body);
}

fn firstLine(s: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > 0 and !std.mem.startsWith(u8, l, "```")) return l;
    }
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const screen_mod = @import("../ipc/screen.zig");

test "no server: every request explains itself, and peek never arms pending_peek" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"lsp.hover" }));
    try testing.expectEqualStrings("LSP needs a saved file", app.lastToast().?);
    try app.activeEditor().?.buf.setPath("/tmp/nothing.xyz");
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"lsp.peek_definition_overlay" }));
    try testing.expectEqualStrings("no language server for this file (peek)", app.lastToast().?);
    try testing.expect(!app.lsp.pending_peek);
    try testing.expect(app.lsp.peek == null);
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"lsp.next_diagnostic" }));
    try testing.expectEqualStrings("no diagnostics in this file", app.lastToast().?);
    // The VS Code Ctrl+T picker asks the same server the prompt does.
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"picker.workspace_symbol" }));
    try testing.expectEqualStrings("no language server for this file (workspace symbols)", app.lastToast().?);
    try testing.expect(app.overlay == .none);
}

test "a missing binary toasts once with its install hint, and never again this session" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    var c: app_mod.Config = .{};
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try c.lsp.put(arena_state.allocator(), "python", .{ .cmd = "mnml-no-such-language-server", .extensions = &.{"py"} });
    app.cfg = c;
    try testing.expect((try ensureServer(&app, "/tmp/a.py")) == null);
    try testing.expectEqualStrings("LSP: mnml-no-such-language-server not installed — install it on PATH", app.lastToast().?);
    const n = app.toasts.items.len;
    try testing.expect((try ensureServer(&app, "/tmp/b.py")) == null);
    try testing.expectEqual(n, app.toasts.items.len);
    try testing.expect(app.lsp.dead.contains("python"));
}

test "diagnostics: the snapshot, squiggles and gutter dots on the buffer, the statusline chip, next/prev" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/api.ts");
    try e.buf.editor.setText("let a = 1;\nlet b = 2;\nlet c = 3;\n");
    var parsed = try std.json.parseFromSlice(Value, testing.allocator, "[{\"range\":{\"start\":{\"line\":2,\"character\":4},\"end\":{\"line\":2,\"character\":5}},\"severity\":2,\"message\":\"c unused\"},{\"range\":{\"start\":{\"line\":0,\"character\":4},\"end\":{\"line\":0,\"character\":5}},\"severity\":1,\"message\":\"a unused\",\"source\":\"ts\"}]", .{});
    defer parsed.deinit();
    try applyDiagnostics(&app, "/tmp/api.ts", parsed.value.array.items);
    const list = diagnosticsFor(&app, "/tmp/api.ts");
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqual(@as(u32, 0), list[0].range.start.line); // sorted
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const uls = try underlinesFor(&app, arena.allocator(), e, &app.theme);
    try testing.expectEqual(@as(usize, 2), uls.len);
    try testing.expectEqual(@as(usize, 4), uls[0].start);
    try testing.expectEqual(@as(usize, 26), uls[1].start);
    const marks = try marksFor(&app, arena.allocator(), "/tmp/api.ts", &app.theme, false);
    try testing.expectEqual(@as(usize, 2), marks.len);
    // The statusline's diagnostics chips: the error count in red, the
    // warning count in yellow, after the file name (`app/statusline.zig`).
    try app.render();
    const row = try @import("../ipc/screen.zig").toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(row);
    try testing.expect(std.mem.indexOf(u8, row, "api.ts  \u{f057} 1  ⚠ 1 ") != null);
    e.buf.editor.setCursor(0);
    try command.run(&app, .{ .static = .@"lsp.next_diagnostic" });
    try testing.expectEqual(@as(usize, 4), e.buf.editor.cursor);
    try testing.expectEqualStrings("error: a unused", app.lastToast().?);
    try command.run(&app, .{ .static = .@"lsp.next_diagnostic" });
    try testing.expectEqual(@as(usize, 26), e.buf.editor.cursor);
    try command.run(&app, .{ .static = .@"lsp.next_diagnostic" }); // wraps
    try testing.expectEqual(@as(usize, 4), e.buf.editor.cursor);
    try command.run(&app, .{ .static = .@"lsp.prev_diagnostic" });
    try testing.expectEqual(@as(usize, 26), e.buf.editor.cursor);
    // The panel in the right slot lists both, the filter narrows to errors.
    try command.run(&app, .{ .static = .@"lsp.diagnostics" });
    try testing.expectEqual(side.Section.diagnostics, side.shown(&app, .right).?);
    try app.render();
    const txt = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "DIAGNOSTICS") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "c unused") != null);
    try command.run(&app, .{ .static = .@"lsp.diagnostics_filter" });
    try command.run(&app, .{ .static = .@"lsp.diagnostics_filter" });
    try testing.expectEqual(SeverityFilter.errors, app.lsp.severity_filter);
    const rows = try panelRows(&app, arena.allocator());
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("a unused", rows[0].message);
    // A republish with an empty list clears the file.
    try applyDiagnostics(&app, "/tmp/api.ts", &.{});
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(&app, "/tmp/api.ts").len);
}

// The lsp-more modules are file-scope imports above; a `test` block is
// what puts their tests in front of `-Dtest-filter` (the full suite
// finds them either way, the filter — and so `tools/break-check.sh` —
// only through here).
test {
    _ = decor;
    _ = semantic_app;
    _ = format_app;
    _ = rename_app;
    _ = @import("../lsp/semantic.zig");
    _ = @import("../lsp/tools.zig");
}

// ─── a scripted language server, in process ─────────────────────────────

fn lspReply(io: Io, gpa: Allocator, out: Io.File, id: i64, result: []const u8) void {
    const text = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result }) catch return;
    defer gpa.free(text);
    jsonrpc.writeFrame(io, out, text) catch {};
}

/// A typescript-shaped server: a diagnostic on every open, two
/// completions (one a snippet), a hover, a definition on line 1, a
/// rename that rewrites the word, one document symbol.
fn fakeLanguageServer(io: Io, gpa: Allocator, in: Io.File, out: Io.File) Io.Cancelable!void {
    var buf: [16384]u8 = undefined;
    var fr = in.readerStreaming(io, &buf);
    // tsserver's shape: `initialized` begins a "loading" progress that
    // the first `didOpen` ends; references asked before the end see
    // one file's worth.
    var loaded = false;
    while (true) {
        const body = jsonrpc.readFrame(gpa, &fr.interface) catch return;
        defer gpa.free(body);
        var parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch return;
        defer parsed.deinit();
        switch (jsonrpc.classify(parsed.value)) {
            .request => |rq| {
                const m = rq.method;
                if (std.mem.eql(u8, m, "initialize")) {
                    lspReply(io, gpa, out, rq.id, "{\"capabilities\":{\"textDocumentSync\":{\"change\":2,\"willSaveWaitUntil\":true},\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,\"renameProvider\":true,\"documentSymbolProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]},\"inlayHintProvider\":true,\"codeLensProvider\":{\"resolveProvider\":true},\"colorProvider\":true,\"documentLinkProvider\":{},\"documentRangeFormattingProvider\":true,\"documentOnTypeFormattingProvider\":{\"firstTriggerCharacter\":\";\"},\"executeCommandProvider\":{\"commands\":[\"refs\"]},\"semanticTokensProvider\":{\"legend\":{\"tokenTypes\":[\"keyword\",\"variable\",\"function\"],\"tokenModifiers\":[\"declaration\"]},\"full\":{\"delta\":true}}}}");
                } else if (std.mem.eql(u8, m, "textDocument/completion")) {
                    lspReply(io, gpa, out, rq.id, "{\"isIncomplete\":false,\"items\":[{\"label\":\"alphaOne\",\"kind\":3,\"detail\":\"fn\"},{\"label\":\"alphaTwo\",\"kind\":2,\"insertText\":\"alphaTwo($1)\",\"insertTextFormat\":2}]}");
                } else if (std.mem.eql(u8, m, "textDocument/hover")) {
                    lspReply(io, gpa, out, rq.id, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"```ts\\nconst x: number\\n```\\n\\nThe x.\"}}");
                } else if (std.mem.eql(u8, m, "textDocument/definition")) {
                    const uri = jsonrpc.getStr(jsonrpc.getObj(rq.params.?, "textDocument").?, "uri").?;
                    const r = std.fmt.allocPrint(gpa, "[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":1,\"character\":6}},\"end\":{{\"line\":1,\"character\":9}}}}}}]", .{uri}) catch return;
                    defer gpa.free(r);
                    lspReply(io, gpa, out, rq.id, r);
                } else if (std.mem.eql(u8, m, "textDocument/rename")) {
                    const uri = jsonrpc.getStr(jsonrpc.getObj(rq.params.?, "textDocument").?, "uri").?;
                    const name = jsonrpc.getStr(rq.params.?, "newName").?;
                    // A name starting `multi` also renames line 1 of a
                    // second file, `/tmp/mnml-zig-fake-lsp-other.ts`.
                    const r = if (std.mem.startsWith(u8, name, "multi"))
                        std.fmt.allocPrint(gpa, "{{\"changes\":{{\"{s}\":[{{\"range\":{{\"start\":{{\"line\":1,\"character\":6}},\"end\":{{\"line\":1,\"character\":9}}}},\"newText\":\"{s}\"}}],\"file:///tmp/mnml-zig-fake-lsp-other.ts\":[{{\"range\":{{\"start\":{{\"line\":1,\"character\":0}},\"end\":{{\"line\":1,\"character\":3}}}},\"newText\":\"{s}\"}}]}}}}", .{ uri, name, name }) catch return
                    else
                        std.fmt.allocPrint(gpa, "{{\"changes\":{{\"{s}\":[{{\"range\":{{\"start\":{{\"line\":1,\"character\":6}},\"end\":{{\"line\":1,\"character\":9}}}},\"newText\":\"{s}\"}}]}}}}", .{ uri, name }) catch return;
                    defer gpa.free(r);
                    lspReply(io, gpa, out, rq.id, r);
                } else if (std.mem.eql(u8, m, "textDocument/references")) {
                    // `foo`'s declaration on line 1 and, once loaded, its use on line 2.
                    const uri = jsonrpc.getStr(jsonrpc.getObj(rq.params.?, "textDocument").?, "uri").?;
                    const r = if (loaded)
                        std.fmt.allocPrint(gpa, "[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":1,\"character\":6}},\"end\":{{\"line\":1,\"character\":9}}}}}},{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":2,\"character\":0}},\"end\":{{\"line\":2,\"character\":3}}}}}}]", .{ uri, uri }) catch return
                    else
                        std.fmt.allocPrint(gpa, "[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":1,\"character\":6}},\"end\":{{\"line\":1,\"character\":9}}}}}}]", .{uri}) catch return;
                    defer gpa.free(r);
                    lspReply(io, gpa, out, rq.id, r);
                } else if (std.mem.eql(u8, m, "textDocument/documentSymbol")) {
                    // The main file answers in `DocumentSymbol[]` — `foo` with
                    // a child — the other file in flat `SymbolInformation[]`.
                    const uri = jsonrpc.getStr(jsonrpc.getObj(rq.params.?, "textDocument").?, "uri").?;
                    if (std.mem.endsWith(u8, uri, "-other.ts")) {
                        const r = std.fmt.allocPrint(gpa, "[{{\"name\":\"a\",\"kind\":13,\"location\":{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":0,\"character\":6}},\"end\":{{\"line\":0,\"character\":7}}}}}}}},{{\"name\":\"b\",\"kind\":13,\"location\":{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":1,\"character\":6}},\"end\":{{\"line\":1,\"character\":7}}}}}}}}]", .{ uri, uri }) catch return;
                        defer gpa.free(r);
                        lspReply(io, gpa, out, rq.id, r);
                    } else {
                        lspReply(io, gpa, out, rq.id, "[{\"name\":\"foo\",\"kind\":12,\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":2,\"character\":4}},\"selectionRange\":{\"start\":{\"line\":1,\"character\":6},\"end\":{\"line\":1,\"character\":9}},\"children\":[{\"name\":\"bar\",\"kind\":13,\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":4}},\"selectionRange\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":3}}}]}]");
                    }
                } else if (std.mem.eql(u8, m, "textDocument/inlayHint")) {
                    // A type hint after `x` on line 0, its label in parts.
                    lspReply(io, gpa, out, rq.id, "[{\"position\":{\"line\":0,\"character\":5},\"label\":[{\"value\":\": \"},{\"value\":\"number\"}],\"kind\":1}]");
                } else if (std.mem.eql(u8, m, "textDocument/codeLens")) {
                    // Line 1's lens carries its command; line 0's needs a resolve.
                    lspReply(io, gpa, out, rq.id, "[{\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":5}},\"command\":{\"title\":\"2 references\",\"command\":\"refs\",\"arguments\":[1]}},{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}},\"data\":7}]");
                } else if (std.mem.eql(u8, m, "codeLens/resolve")) {
                    lspReply(io, gpa, out, rq.id, "{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":3}},\"command\":{\"title\":\"resolved lens\",\"command\":\"refs\",\"arguments\":[0]}}");
                } else if (std.mem.eql(u8, m, "workspace/executeCommand")) {
                    lspReply(io, gpa, out, rq.id, "null");
                    // Announce what ran as a warning so the client toasts it.
                    const cmd = jsonrpc.getStr(rq.params.?, "command") orelse "?";
                    const args = jsonrpc.getArr(rq.params.?, "arguments") orelse &.{};
                    const first: i64 = if (args.len > 0) switch (args[0]) {
                        .integer => |i| i,
                        else => -1,
                    } else -1;
                    const note = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"window/showMessage\",\"params\":{{\"type\":2,\"message\":\"ran {s} #{d}\"}}}}", .{ cmd, first }) catch return;
                    defer gpa.free(note);
                    jsonrpc.writeFrame(io, out, note) catch return;
                } else if (std.mem.eql(u8, m, "textDocument/documentColor")) {
                    // The `1` on line 0 is red.
                    lspReply(io, gpa, out, rq.id, "[{\"range\":{\"start\":{\"line\":0,\"character\":8},\"end\":{\"line\":0,\"character\":9}},\"color\":{\"red\":1,\"green\":0,\"blue\":0,\"alpha\":1}}]");
                } else if (std.mem.eql(u8, m, "textDocument/documentLink")) {
                    // `foo` on line 1 links out.
                    lspReply(io, gpa, out, rq.id, "[{\"range\":{\"start\":{\"line\":1,\"character\":6},\"end\":{\"line\":1,\"character\":9}},\"target\":\"https://example.com/foo\"}]");
                } else if (std.mem.eql(u8, m, "textDocument/semanticTokens/full")) {
                    // `let` keyword, `x` a declared variable, `const` keyword.
                    lspReply(io, gpa, out, rq.id, "{\"resultId\":\"1\",\"data\":[0,0,3,0,0,0,4,1,1,1,1,0,5,0,0]}");
                } else if (std.mem.eql(u8, m, "textDocument/semanticTokens/full/delta")) {
                    // The `const` token becomes `foo`, a function, on line 1 col 6.
                    lspReply(io, gpa, out, rq.id, "{\"resultId\":\"2\",\"edits\":[{\"start\":10,\"deleteCount\":5,\"data\":[1,6,3,2,0]}]}");
                } else if (std.mem.eql(u8, m, "textDocument/rangeFormatting")) {
                    const range = jsonrpc.stringify(gpa, jsonrpc.getObj(rq.params.?, "range").?) catch return;
                    defer gpa.free(range);
                    const r = std.fmt.allocPrint(gpa, "[{{\"range\":{s},\"newText\":\"formatted\"}}]", .{range}) catch return;
                    defer gpa.free(r);
                    lspReply(io, gpa, out, rq.id, r);
                } else if (std.mem.eql(u8, m, "textDocument/onTypeFormatting")) {
                    // Two spaces at the start of the typed line.
                    const line = jsonrpc.getInt(jsonrpc.getObj(rq.params.?, "position").?, "line") orelse 0;
                    const r = std.fmt.allocPrint(gpa, "[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":0}},\"end\":{{\"line\":{d},\"character\":0}}}},\"newText\":\"  \"}}]", .{ line, line }) catch return;
                    defer gpa.free(r);
                    lspReply(io, gpa, out, rq.id, r);
                } else if (std.mem.eql(u8, m, "textDocument/willSaveWaitUntil")) {
                    lspReply(io, gpa, out, rq.id, "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}},\"newText\":\"// saved\\n\"}]");
                } else {
                    lspReply(io, gpa, out, rq.id, "null");
                }
            },
            .notification => |n| {
                if (std.mem.eql(u8, n.method, "exit")) return;
                if (std.mem.eql(u8, n.method, "initialized")) {
                    jsonrpc.writeFrame(io, out, "{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{\"token\":\"load\",\"value\":{\"kind\":\"begin\",\"title\":\"Loading\"}}}") catch return;
                }
                if (std.mem.eql(u8, n.method, "textDocument/didOpen")) {
                    const uri = jsonrpc.getStr(jsonrpc.getObj(n.params.?, "textDocument").?, "uri").?;
                    const note = std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"{s}\",\"diagnostics\":[{{\"range\":{{\"start\":{{\"line\":0,\"character\":4}},\"end\":{{\"line\":0,\"character\":5}}}},\"severity\":1,\"message\":\"x is never read\"}}]}}}}", .{uri}) catch return;
                    defer gpa.free(note);
                    jsonrpc.writeFrame(io, out, note) catch return;
                    if (!loaded) {
                        loaded = true;
                        jsonrpc.writeFrame(io, out, "{\"jsonrpc\":\"2.0\",\"method\":\"$/progress\",\"params\":{\"token\":\"load\",\"value\":{\"kind\":\"end\"}}}") catch return;
                    }
                }
            },
            else => {},
        }
    }
}

fn pumpUntil(app: *App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool, budget_ms: u32) !void {
    var spent: u32 = 0;
    while (!cond(ctx)) : (spent += 10) {
        if (spent > budget_ms) return error.Timeout;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
        try app.tick(App.nowMs(app.io));
    }
}

/// The scripted server wired into an `App` for the tests of the
/// app-side modules (`lsp_decor`, `lsp_semantic`, `lsp_format`,
/// `lsp_rename`): `start` spawns `fakeLanguageServer` on two pipes and
/// registers it as the typescript server rooted at `/tmp`, so a `.ts`
/// path under `/tmp` attaches to it without a binary or a root marker;
/// `stop` retires it and joins the task.
pub const TestRig = struct {
    group: Io.Group = .init,
    in_r: Io.File = undefined,
    out_w: Io.File = undefined,
    server: *Server = undefined,

    pub const file = "/tmp/mnml-zig-fake-lsp.ts";
    pub const other = "/tmp/mnml-zig-fake-lsp-other.ts";
    pub const text = "let x = 1;\nconst foo = 2;\nfoo.\n";

    pub fn start(self: *TestRig, app: *App) !void {
        const gpa = app.gpa;
        const io = app.io;
        const c2s = try Io.Threaded.pipe2(.{});
        const s2c = try Io.Threaded.pipe2(.{});
        const F = Io.File;
        const flags: F.Flags = .{ .nonblocking = false };
        self.* = .{ .in_r = F{ .handle = c2s[0], .flags = flags }, .out_w = F{ .handle = s2c[1], .flags = flags } };
        try self.group.concurrent(io, fakeLanguageServer, .{ io, gpa, self.in_r, self.out_w });
        const s = try Server.initFiles(gpa, io, &app.events, app.lsp.next_id, F{ .handle = c2s[1], .flags = flags }, F{ .handle = s2c[0], .flags = flags }, .{ .name = "typescript", .argv = &.{"fake-ts"}, .root = "/tmp" });
        app.lsp.next_id += 1;
        try app.lsp.servers.append(gpa, s);
        try s.initialize();
        self.server = s;
    }

    pub fn stop(self: *TestRig, app: *App) !void {
        retireServer(app, self.server);
        try self.group.await(app.io);
        self.in_r.close(app.io);
        self.out_w.close(app.io);
    }

    /// A scratch editor given `path` and `text_in`, attached to the server.
    pub fn openFile(app: *App, path: []const u8, text_in: []const u8) !*EditorPane {
        _ = try app.openScratch();
        const pane = app.active.?;
        const e = app.activeEditor().?;
        try e.buf.setPath(path);
        try e.buf.editor.setText(text_in);
        try attach(app, pane, e);
        return e;
    }

    /// Tick and render until `cond`: the decorations are asked for from
    /// the frame, so a wait that never paints never asks.
    pub fn pump(app: *App, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool, budget_ms: u32) !void {
        var spent: u32 = 0;
        while (!cond(ctx)) : (spent += 10) {
            if (spent > budget_ms) return error.Timeout;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
            try app.tick(App.nowMs(app.io));
            try app.render();
        }
    }

    pub fn screenText(app: *App, gpa: Allocator) ![]u8 {
        try app.render();
        return screen_mod.toTestText(gpa, &app.screen);
    }
};

test "diagnostics from a server and a linter merge sorted, and each source replaces only its own" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    const path = "/tmp/merge.ts";
    var parsed = try std.json.parseFromSlice(Value, testing.allocator, "[{\"range\":{\"start\":{\"line\":3,\"character\":0},\"end\":{\"line\":3,\"character\":1}},\"severity\":1,\"message\":\"server\"}]", .{});
    defer parsed.deinit();
    try applyDiagnostics(&app, path, parsed.value.array.items);
    const lint = [_]types.Diagnostic{.{ .range = .{ .start = .{ .line = 1, .character = 0 }, .end = .{ .line = 1, .character = 1 } }, .severity = .warning, .message = "lint", .source = "lint", .code = null }};
    try applyLintDiagnostics(&app, path, &lint);
    var list = diagnosticsFor(&app, path);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("lint", list[0].message);
    try testing.expectEqualStrings("server", list[1].message);
    // The server republishes empty: the linter's finding stays.
    try applyDiagnostics(&app, path, &.{});
    list = diagnosticsFor(&app, path);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("lint", list[0].message);
    // The linter runs clean: nothing left.
    try applyLintDiagnostics(&app, path, &.{});
    try testing.expectEqual(@as(usize, 0), diagnosticsFor(&app, path).len);
}

test "a scripted server through the app: attach + diagnostics, completion (a snippet), hover, peek, rename, symbols into the outline" {
    const gpa = testing.allocator;
    const io = testing.io;
    var app = try App.initWith(gpa, io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const file = "/tmp/mnml-zig-fake-lsp.ts";
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const c2s = try Io.Threaded.pipe2(.{});
    const s2c = try Io.Threaded.pipe2(.{});
    const F = Io.File;
    const flags: F.Flags = .{ .nonblocking = false };
    var group: Io.Group = .init;
    try group.concurrent(io, fakeLanguageServer, .{ io, gpa, F{ .handle = c2s[0], .flags = flags }, F{ .handle = s2c[1], .flags = flags } });
    // Registered as the typescript server rooted at /tmp, so the builtin
    // spec for `.ts` resolves to it without a binary or a root marker.
    const s = try Server.initFiles(gpa, io, &app.events, app.lsp.next_id, F{ .handle = c2s[1], .flags = flags }, F{ .handle = s2c[0], .flags = flags }, .{ .name = "typescript", .argv = &.{"fake-ts"}, .root = "/tmp" });
    app.lsp.next_id += 1;
    try app.lsp.servers.append(gpa, s);
    try s.initialize();

    _ = try app.openScratch();
    const pane = app.active.?;
    const e = app.activeEditor().?;
    try e.buf.setPath(file);
    try e.buf.editor.setText("let x = 1;\nconst foo = 2;\nfoo.\n");
    try attach(&app, pane, e);
    try testing.expectEqual(s, serverFor(&app, file).?);

    const Cond = struct {
        fn diag(a: *App) bool {
            return diagnosticsFor(a, file).len > 0 and a.lsp.symbols.contains(file);
        }
        fn comp(a: *App) bool {
            return a.lsp.completion != null;
        }
        fn hov(a: *App) bool {
            return a.lsp.hover != null;
        }
        fn peeked(a: *App) bool {
            return a.lsp.peek != null;
        }
        fn renamed(a: *App) bool {
            const ed = a.activeEditor() orelse return false;
            return std.mem.indexOf(u8, ed.buf.editor.bytes(), "const bar = 2") != null;
        }
    };
    try pumpUntil(&app, &app, Cond.diag, 5000);
    try testing.expect(s.ready and s.isOpen(file));
    try testing.expectEqualStrings("x is never read", diagnosticsFor(&app, file)[0].message);
    try testing.expectEqualStrings("foo", symbolsFor(&app, file).?[0].name);

    // Completion at the end of `foo.` — the snippet item expands with its stop.
    e.buf.editor.setCursor(e.buf.editor.len() - 1);
    try command.run(&app, .{ .static = .@"lsp.completion" });
    try pumpUntil(&app, &app, Cond.comp, 5000);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 2), (try visibleCompletions(&app, arena.allocator())).len);
    try app.handle(.{ .key = Key.named(.down) });
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expect(app.lsp.completion == null);
    try testing.expect(std.mem.indexOf(u8, e.buf.editor.bytes(), "foo.alphaTwo()") != null);
    try testing.expectEqual(@as(u8, ')'), e.buf.editor.bytes()[e.buf.editor.cursor]);

    // Hover: the code fence dropped, the doc kept; a plain key closes it.
    try command.run(&app, .{ .static = .@"lsp.hover" });
    try pumpUntil(&app, &app, Cond.hov, 5000);
    try testing.expectEqualStrings("const x: number", app.lsp.hover.?.lines()[0]);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.lsp.hover == null);

    // Peek: the overlay opens on the definition's line and the flag is down.
    try command.run(&app, .{ .static = .@"lsp.peek_definition_overlay" });
    try testing.expect(app.lsp.pending_peek);
    try pumpUntil(&app, &app, Cond.peeked, 5000);
    try testing.expect(!app.lsp.pending_peek);
    try testing.expectEqualStrings("const foo = 2;", app.lsp.peek.?.lines[app.lsp.peek.?.highlight]);
    try app.render();
    const txt = try screen_mod.toTestText(gpa, &app.screen);
    defer gpa.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "✦ peek") != null);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.lsp.peek == null);

    // Rename through the workspace edit.
    try acceptRename(&app, "bar");
    try pumpUntil(&app, &app, Cond.renamed, 5000);
    try testing.expect(std.mem.indexOf(u8, txt, "✦ peek") != null);

    // The outline takes the server's symbols.
    const outline = @import("outline.zig");
    try command.run(&app, .{ .static = .@"outline.show" });
    const o = app.panes.get(app.active.?).?.asOutline().?;
    try testing.expectEqualStrings("foo", o.items.items[0].name);
    try testing.expectEqualStrings("fn", o.items.items[0].kind);
    _ = outline;

    // Goodbye: retiring the server says shutdown + exit; the fake leaves.
    retireServer(&app, s);
    try group.await(io);
    (F{ .handle = c2s[0], .flags = flags }).close(io);
    (F{ .handle = s2c[1], .flags = flags }).close(io);
}

test "a scripted server: references and symbols asked for while the server starts run when it is ready; the pickers list every row, in both symbol shapes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: TestRig = .{};
    try rig.start(&app);
    const e = try TestRig.openFile(&app, TestRig.file, TestRig.text);
    // `initialize` is on the wire and its answer waits for a tick: the
    // server is what tsserver is for its first second — not ready.
    try testing.expect(!rig.server.ready);
    e.buf.editor.setCursor(std.mem.indexOf(u8, TestRig.text, "foo").?);
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"lsp.references" }));
    try testing.expect(app.lsp.deferred != null);
    try testing.expectEqual(command.CommandId.@"lsp.references", app.lsp.deferred.?.cmd);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "references runs when it is ready") != null);
    const Cond = struct {
        fn picker(a: *App) bool {
            return a.overlay == .picker;
        }
    };
    // The answer lands, the request goes out, the picker opens on its own.
    try pumpUntil(&app, &app, Cond.picker, 5000);
    try testing.expect(rig.server.ready);
    try testing.expectEqual(@as(u32, 0), rig.server.progress_open);
    try testing.expect(app.lsp.deferred == null);
    try testing.expectEqualStrings("References", app.overlay.picker.state.title);
    try testing.expectEqual(@as(usize, 2), app.overlay.picker.labels.len);
    try testing.expectEqualStrings("mnml-zig-fake-lsp.ts:2:7", app.overlay.picker.labels[0]);
    try testing.expectEqualStrings("mnml-zig-fake-lsp.ts:3:1", app.overlay.picker.labels[1]);
    try testing.expectEqualStrings("const foo = 2;", app.overlay.picker.details[0]);
    try testing.expectEqual(@as(usize, 2), app.lsp.picker_locs.?.items.len);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.overlay == .none);

    // `DocumentSymbol[]`, nested: the child follows its parent one level in.
    try command.run(&app, .{ .static = .@"lsp.symbols" });
    try pumpUntil(&app, &app, Cond.picker, 5000);
    try testing.expectEqualStrings("Symbols", app.overlay.picker.state.title);
    try testing.expectEqual(@as(usize, 2), app.overlay.picker.labels.len);
    try testing.expectEqualStrings("fn foo", app.overlay.picker.labels[0]);
    try testing.expectEqualStrings("var bar", app.overlay.picker.labels[1]);
    try testing.expectEqualStrings(":3", app.overlay.picker.details[1]);
    try testing.expectEqual(@as(u8, 1), app.lsp.picker_symbols.?.items[1].depth);
    try app.handle(.{ .key = Key.named(.esc) });

    // `SymbolInformation[]`, flat: the other file's answer, the same picker.
    _ = try TestRig.openFile(&app, TestRig.other, "const a = 1;\nconst b = 2;\n");
    try command.run(&app, .{ .static = .@"lsp.symbols" });
    try pumpUntil(&app, &app, Cond.picker, 5000);
    try testing.expectEqualStrings("Symbols", app.overlay.picker.state.title);
    try testing.expectEqual(@as(usize, 2), app.overlay.picker.labels.len);
    try testing.expectEqualStrings("var a", app.overlay.picker.labels[0]);
    try testing.expectEqualStrings("var b", app.overlay.picker.labels[1]);
    try testing.expectEqual(@as(u8, 0), app.lsp.picker_symbols.?.items[1].depth);
    try app.handle(.{ .key = Key.named(.esc) });
    try rig.stop(&app);
}

test "a held command waits out the server's $/progress: sent at the last end, at the grace when nothing is loading, at the deadline regardless" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: TestRig = .{};
    try rig.start(&app);
    const e = try TestRig.openFile(&app, TestRig.file, TestRig.text);
    const Cond = struct {
        fn ready(a: *App) bool {
            return a.lsp.servers.items[0].ready and a.lsp.servers.items[0].progress_open == 0 and a.lsp.symbols.contains(TestRig.file);
        }
    };
    try pumpUntil(&app, &app, Cond.ready, 5000);
    const s = rig.server;
    e.buf.editor.setCursor(std.mem.indexOf(u8, TestRig.text, "foo").?);
    var begin = try std.json.parseFromSlice(Value, gpa, "{\"token\":\"load\",\"value\":{\"kind\":\"begin\",\"title\":\"Loading\"}}", .{});
    defer begin.deinit();
    var end = try std.json.parseFromSlice(Value, gpa, "{\"token\":\"load\",\"value\":{\"kind\":\"end\"}}", .{});
    defer end.deinit();
    const held: Deferred = .{ .server = s.id, .cmd = .@"lsp.references", .not_before_ms = app.now_ms + deferred_grace_ms, .deadline_ms = app.now_ms + deferred_max_wait_ms };

    // Loading past the grace: held; the end sends it.
    app.lsp.deferred = held;
    try handleNotification(&app, s, "$/progress", begin.value);
    try testing.expectEqual(@as(u32, 1), s.progress_open);
    try tick(&app, held.not_before_ms + 100);
    try testing.expect(app.lsp.deferred != null);
    try handleNotification(&app, s, "$/progress", end.value);
    try testing.expectEqual(@as(u32, 0), s.progress_open);
    try testing.expect(app.lsp.deferred == null);

    // Nothing loading: held through the grace, sent at it.
    app.lsp.deferred = held;
    try tick(&app, held.not_before_ms - 1);
    try testing.expect(app.lsp.deferred != null);
    try tick(&app, held.not_before_ms);
    try testing.expect(app.lsp.deferred == null);

    // A load that never ends: the deadline sends it anyway.
    app.lsp.deferred = held;
    try handleNotification(&app, s, "$/progress", begin.value);
    try tick(&app, held.deadline_ms - 1);
    try testing.expect(app.lsp.deferred != null);
    try tick(&app, held.deadline_ms);
    try testing.expect(app.lsp.deferred == null);
    try handleNotification(&app, s, "$/progress", end.value);

    // Every send reached the server: three References pickers came back.
    const Sent = struct {
        fn three(a: *App) bool {
            return a.overlay == .picker and a.lsp.picker_locs != null and a.lsp.servers.items[0].transport.pendingCount() == 0;
        }
    };
    try pumpUntil(&app, &app, Sent.three, 5000);
    try testing.expectEqualStrings("References", app.overlay.picker.state.title);
    try app.handle(.{ .key = Key.named(.esc) });
    try rig.stop(&app);
}
