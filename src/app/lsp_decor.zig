//! What a language server paints INTO the text without changing it:
//! inlay hints (dim virtual text at a position), code lenses (a row of
//! titles above a symbol that runs a server command), document colours
//! (a swatch cell before the literal) and document links (an underline
//! that `gx` or a click opens).
//!
//! Every dataset is a per-file snapshot (D1): one arena each, replaced
//! wholesale by the reply, tagged with the edit-log seq the reply
//! describes. A set whose seq no longer matches the buffer is not
//! painted — stale hints beside moved text are worse than none — and
//! the frame asks again once the buffer has been idle for `idle_ms`.
//! Requests carry the seq's low word in `Ctx.extra` so a reply for an
//! older text is stored as stale rather than trusted.
//!
//! The seq is an optional, not a zero: an untouched document's head IS
//! 0 (`EditLog.head` is `next_seq - 1`), so a `0 = never landed`
//! sentinel made every reply for a file nobody had edited yet stale on
//! arrival — zls's hints on open painted only after the first
//! keystroke, and the toggle painted nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const alloc = @import("../core/alloc.zig");
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;
const editor_view = @import("../ui/editor_view.zig");
const Theme = @import("../ui/theme.zig");
const clip = @import("../ui/clip.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const client = @import("../lsp/client.zig");
const types = @import("../lsp/types.zig");
const lsp = @import("lsp.zig");
const semantic_app = @import("lsp_semantic.zig");

const Server = client.Server;
const ReqKind = client.ReqKind;
const Ctx = client.Ctx;
const Value = jsonrpc.Value;
const Style = @import("vaxis").Style;

/// How long the buffer must have been quiet before the sets refresh.
pub const idle_ms: i64 = 250;
/// Lens segments register `.script_hit{pane, lens_hit_base + index}`.
pub const lens_hit_base: u32 = 0x4C45_0000;
/// A `codeLens/resolve` the view sent for a title (`Ctx.extra` bit):
/// the reply names the lens, nothing runs.
const lens_view_bit: u32 = 1 << 31;
/// The most view resolves one frame sends.
const lens_view_batch = 32;

/// One replace-wholesale dataset.
fn Set(comptime T: type) type {
    return struct {
        arena: alloc.SnapshotArena,
        items: []T = &.{},
        /// The edit-log seq the items describe; null = stale or never landed.
        seq: ?u64 = null,
        /// The reply the items borrow (a lens keeps its raw `Value`).
        incoming: ?*jsonrpc.Incoming = null,

        const Self = @This();

        fn clear(self: *Self, gpa: Allocator) void {
            if (self.incoming) |m| m.destroy(gpa);
            self.incoming = null;
            self.arena.reset();
            self.items = &.{};
            self.seq = null;
        }

        fn deinit(self: *Self, gpa: Allocator) void {
            if (self.incoming) |m| m.destroy(gpa);
            self.arena.deinit();
        }
    };
}

pub const FileDecor = struct {
    hints: Set(types.InlayHint),
    lenses: Set(types.CodeLens),
    colors: Set(types.ColorInfo),
    links: Set(types.DocumentLink),

    fn create(gpa: Allocator) Allocator.Error!*FileDecor {
        const fd = try gpa.create(FileDecor);
        fd.* = .{
            .hints = .{ .arena = alloc.SnapshotArena.init(gpa) },
            .lenses = .{ .arena = alloc.SnapshotArena.init(gpa) },
            .colors = .{ .arena = alloc.SnapshotArena.init(gpa) },
            .links = .{ .arena = alloc.SnapshotArena.init(gpa) },
        };
        return fd;
    }

    pub fn destroy(self: *FileDecor, gpa: Allocator) void {
        self.hints.deinit(gpa);
        self.lenses.deinit(gpa);
        self.colors.deinit(gpa);
        self.links.deinit(gpa);
        gpa.destroy(self);
    }
};

/// Per pane: when the sets were last asked for, and for which text.
pub const Track = struct {
    /// The seq every set was requested at; null = never asked.
    seq: ?u64 = null,
    /// When the buffer first differed from `seq`; the debounce clock.
    dirty_since: ?i64 = null,
    /// The line window the hints were requested for, and at which seq.
    hint_lines: [2]u32 = .{ 0, 0 },
    hint_seq: ?u64 = null,
};

fn seqLow(seq: u64) u32 {
    return @truncate(seq);
}

/// The file's sets, made on first use when `create`.
pub fn fileDecor(app: *App, path: []const u8, create: bool) Allocator.Error!?*FileDecor {
    if (app.lsp.decor.get(path)) |fd| return fd;
    if (!create) return null;
    const gpa = app.gpa;
    const key = try gpa.dupe(u8, path);
    errdefer gpa.free(key);
    const fd = try FileDecor.create(gpa);
    errdefer fd.destroy(gpa);
    try app.lsp.decor.put(gpa, key, fd);
    return fd;
}

/// The last editor on `path` closed: the sets go with it.
pub fn drop(app: *App, path: []const u8) void {
    if (app.lsp.decor.fetchRemove(path)) |kv| {
        app.gpa.free(kv.key);
        kv.value.destroy(app.gpa);
    }
}

pub fn forgetPane(app: *App, pane: PaneId) void {
    _ = app.lsp.decor_track.remove(pane);
}

/// `s` became ready (a start, or a restart): every pane it serves asks
/// for its sets on the next frame, whatever text it last asked at.
/// Before this, a buffer open across a restart kept the old server's
/// answer and never asked the new one. Panes another server serves
/// keep their marks.
pub fn onServerReady(app: *App, s: *const Server) void {
    var it = app.lsp.decor_track.iterator();
    while (it.next()) |kv| {
        const e = app.panes.editor(kv.key_ptr.*) orelse continue;
        const path = e.buf.doc.path orelse continue;
        if (lsp.serverFor(app, path) != s) continue;
        kv.value_ptr.seq = null;
        kv.value_ptr.hint_seq = null;
        kv.value_ptr.dirty_since = null;
    }
    app.needs_render = true;
}

// ─── requests, from the frame ───────────────────────────────────────────

/// Called by the frame after the pane synced: refresh every set once
/// the buffer has been idle, and the hints when the view left their
/// window. `first`..`last` are the visible lines.
pub fn onFrame(app: *App, pane: PaneId, e: *EditorPane, first: u32, last: u32) Allocator.Error!void {
    const path = e.buf.doc.path orelse return;
    // A file over the highlight ceiling gets no per-file extras either:
    // the server keeps the document (goto, references, rename work),
    // but nothing here asks it to walk all of it (`Syntax.overCeiling`).
    if (e.syntax.overCeiling()) return;
    const s = lsp.serverFor(app, path) orelse return;
    if (!s.ready or !s.isOpen(path)) return;
    const head = e.buf.doc.edits.head();
    const gop = try app.lsp.decor_track.getOrPut(app.gpa, pane);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const tr = gop.value_ptr;
    const now = app.now_ms;
    var fire = false;
    if (tr.seq == null or tr.seq.? != head) {
        if (tr.dirty_since == null) tr.dirty_since = now;
        if (tr.seq == null or now - tr.dirty_since.? >= idle_ms) fire = true;
    }
    const rows = last -| first + 1;
    const window: [2]u32 = .{ first -| rows, last + rows };
    if (fire) {
        tr.seq = head;
        tr.dirty_since = null;
        if (app.cfg.editor.inlay_hints and s.caps.inlay_hint) requestHints(app, s, pane, e, path, window, tr);
        if (app.cfg.editor.code_lens and s.caps.code_lens) requestSimple(app, s, pane, path, .code_lens, "textDocument/codeLens", head);
        if (s.caps.document_color) requestSimple(app, s, pane, path, .document_color, "textDocument/documentColor", head);
        if (s.caps.document_link) requestSimple(app, s, pane, path, .document_link, "textDocument/documentLink", head);
        if (app.cfg.editor.semantic_tokens and s.caps.semanticTokens()) semantic_app.request(app, s, pane, e, first, last);
        return;
    }
    const hints_out = first < tr.hint_lines[0] or last > tr.hint_lines[1] or tr.hint_seq == null or tr.hint_seq.? != head;
    if (hints_out and app.cfg.editor.inlay_hints and s.caps.inlay_hint) requestHints(app, s, pane, e, path, window, tr);
    try resolveVisibleLenses(app, s, pane, path, head, window);
}

/// Lenses that came without a command are a row of `…` until resolved:
/// the ones in the view's window (`onFrame`'s, a screen either side) ask
/// for their titles, once each, as VS Code and Neovim do.
fn resolveVisibleLenses(app: *App, s: *Server, pane: PaneId, path: []const u8, head: u64, window: [2]u32) Allocator.Error!void {
    if (!app.cfg.editor.code_lens or !s.caps.code_lens_resolve) return;
    const fd = app.lsp.decor.get(path) orelse return;
    if (!setFresh(types.CodeLens, &fd.lenses, head)) return;
    const gpa = app.gpa;
    var sent: usize = 0;
    for (fd.lenses.items, 0..) |*l, i| {
        if (l.title != null or l.resolving) continue;
        if (l.range.start.line < window[0] or l.range.start.line > window[1]) continue;
        if (sent == lens_view_batch or i >= lens_view_bit) break;
        const raw_json = try jsonrpc.stringify(gpa, l.raw);
        defer gpa.free(raw_json);
        const id = s.transport.allocId();
        const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"codeLens/resolve\",\"params\":{s}}}", .{ id, raw_json });
        defer gpa.free(body);
        try s.transport.expect(id, .{ .kind = @intFromEnum(ReqKind.code_lens_resolve), .ctx = (Ctx{ .pane = pane, .extra = @as(u32, @intCast(i)) | lens_view_bit }).pack() });
        s.transport.send(body) catch {
            _ = s.transport.forget(id);
            return;
        };
        l.resolving = true;
        sent += 1;
    }
}

/// The hints for a line window; the reply replaces the file's set.
fn requestHints(app: *App, s: *Server, pane: PaneId, e: *EditorPane, path: []const u8, window: [2]u32, tr: *Track) void {
    const arena = app.frame.allocator();
    const ed = e.buf.editor;
    const text = ed.bytes();
    const last_line: u32 = @intCast(@min(window[1], ed.lineCount() - 1));
    const uri = types.uriFromPath(arena, path) catch return;
    const range: types.Range = .{ .start = .{ .line = window[0], .character = 0 }, .end = types.positionOf(text, ed.lineEnd(last_line), s.encoding) };
    const head = ed.doc.edits.head();
    _ = s.request(.inlay_hint, "textDocument/inlayHint", .{ .textDocument = .{ .uri = uri }, .range = range }, .{ .pane = pane, .extra = seqLow(head) }) catch return;
    tr.hint_lines = .{ window[0], last_line };
    tr.hint_seq = head;
}

fn requestSimple(app: *App, s: *Server, pane: PaneId, path: []const u8, kind: ReqKind, method: []const u8, head: u64) void {
    const arena = app.frame.allocator();
    const uri = types.uriFromPath(arena, path) catch return;
    _ = s.request(kind, method, .{ .textDocument = .{ .uri = uri } }, .{ .pane = pane, .extra = seqLow(head) }) catch {};
}

/// `lsp.inlay_hints_toggle`: flip the flag; the sets follow at once.
pub fn inlayHintsToggle(app: *App) CommandError!void {
    app.cfg.editor.inlay_hints = !app.cfg.editor.inlay_hints;
    var it = app.lsp.decor.valueIterator();
    while (it.next()) |fd| fd.*.hints.clear(app.gpa);
    // Every pane asks again on its next idle frame.
    var tk = app.lsp.decor_track.valueIterator();
    while (tk.next()) |tr| tr.hint_seq = null;
    app.toast("inlay hints: {s}", .{if (app.cfg.editor.inlay_hints) "on" else "off"});
    app.needs_render = true;
}

// ─── replies ────────────────────────────────────────────────────────────

/// Returns true when the reply was adopted (the lenses borrow it).
pub fn handleResponse(app: *App, s: *Server, kind: ReqKind, ctx: Ctx, result: ?Value, msg: *jsonrpc.Incoming) Allocator.Error!bool {
    const gpa = app.gpa;
    if (kind == .code_lens_resolve) {
        try runResolvedLens(app, s, ctx, result);
        return false;
    }
    const e = app.panes.editor(ctx.pane) orelse return false;
    const path = e.buf.doc.path orelse return false;
    const fd = (try fileDecor(app, path, true)).?;
    const head = e.buf.doc.edits.head();
    const seq: ?u64 = if (seqLow(head) == ctx.extra) head else null;
    var adopted = false;
    switch (kind) {
        .inlay_hint => {
            fd.hints.clear(gpa);
            const a = fd.hints.arena.allocator();
            const hints = try types.readInlayHints(a, result);
            for (hints) |*h| h.label = try a.dupe(u8, h.label);
            fd.hints.items = hints;
            fd.hints.seq = seq;
        },
        .code_lens => {
            fd.lenses.clear(gpa);
            fd.lenses.items = try types.readCodeLenses(fd.lenses.arena.allocator(), result);
            fd.lenses.incoming = msg;
            fd.lenses.seq = seq;
            adopted = true;
        },
        .document_color => {
            fd.colors.clear(gpa);
            fd.colors.items = try types.readColors(fd.colors.arena.allocator(), result);
            fd.colors.seq = seq;
        },
        .document_link => {
            fd.links.clear(gpa);
            const a = fd.links.arena.allocator();
            const links = try types.readDocumentLinks(a, result);
            for (links) |*l| if (l.target) |t| {
                l.target = try a.dupe(u8, t);
            };
            fd.links.items = links;
            fd.links.seq = seq;
        },
        else => {},
    }
    app.needs_render = true;
    return adopted;
}

// ─── the paint data (frame arena) ───────────────────────────────────────

fn setFresh(comptime T: type, set: *const Set(T), head: u64) bool {
    return set.seq != null and set.seq.? == head;
}

/// Hints and colour swatches as virtual text, sorted by byte.
pub fn virtualTextFor(app: *App, arena: Allocator, e: *EditorPane, theme: *const Theme, ascii: bool) Allocator.Error![]editor_view.VirtualText {
    const path = e.buf.doc.path orelse return &.{};
    const fd = app.lsp.decor.get(path) orelse return &.{};
    const ed = e.buf.editor;
    const head = ed.doc.edits.head();
    const enc = if (lsp.serverFor(app, path)) |s| s.encoding else .utf16;
    var out: std.ArrayListUnmanaged(editor_view.VirtualText) = .empty;
    if (app.cfg.editor.inlay_hints and setFresh(types.InlayHint, &fd.hints, head)) {
        var hint_style = theme.muted;
        hint_style.dim = true;
        for (fd.hints.items) |h| {
            const byte = byteAt(ed, h.position, enc);
            const text = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ if (h.pad_left) " " else "", h.label, if (h.pad_right) " " else "" });
            try out.append(arena, .{ .byte = byte, .text = text, .style = hint_style });
        }
    }
    if (setFresh(types.ColorInfo, &fd.colors, head)) {
        for (fd.colors.items) |c| {
            const byte = byteAt(ed, c.range.start, enc);
            try out.append(arena, .{ .byte = byte, .text = if (ascii) "# " else "■ ", .style = .{ .fg = .{ .rgb = .{ c.r, c.g, c.b } } } });
        }
    }
    std.mem.sort(editor_view.VirtualText, out.items, {}, struct {
        fn lt(_: void, a: editor_view.VirtualText, b: editor_view.VirtualText) bool {
            return a.byte < b.byte;
        }
    }.lt);
    return out.items;
}

/// A byte offset for a position, through the editor's line index.
fn byteAt(ed: anytype, pos: types.Position, enc: types.Encoding) usize {
    const lines = ed.lineCount();
    if (pos.line >= lines) return ed.len();
    const start = ed.lineStart(pos.line);
    const end = ed.lineEnd(pos.line);
    return start + types.byteInLine(ed.bytes()[start..end], pos.character, enc);
}

/// One row per line that has lenses: the titles, each a click target.
pub fn virtualLinesFor(app: *App, arena: Allocator, e: *EditorPane, theme: *const Theme, ascii: bool) Allocator.Error![]editor_view.VirtualLine {
    if (!app.cfg.editor.code_lens) return &.{};
    const path = e.buf.doc.path orelse return &.{};
    const fd = app.lsp.decor.get(path) orelse return &.{};
    const head = e.buf.doc.edits.head();
    if (!setFresh(types.CodeLens, &fd.lenses, head)) return &.{};
    var out: std.ArrayListUnmanaged(editor_view.VirtualLine) = .empty;
    var segs: std.ArrayListUnmanaged(editor_view.VirtualSeg) = .empty;
    var line: ?u32 = null;
    var style = theme.muted;
    style.dim = false;
    style.italic = true;
    for (fd.lenses.items, 0..) |l, i| {
        if (line != null and line.? != l.range.start.line) {
            try out.append(arena, .{ .line = line.?, .segments = try segs.toOwnedSlice(arena) });
            segs = .empty;
        }
        line = l.range.start.line;
        const title = l.title orelse clip.ellipsisText(ascii);
        try segs.append(arena, .{ .text = title, .style = style, .hit = lens_hit_base + @as(u32, @intCast(i)) });
    }
    if (line) |ln| try out.append(arena, .{ .line = ln, .segments = try segs.toOwnedSlice(arena) });
    return out.items;
}

/// Document links as single underlines in the accent colour.
pub fn linkUnderlinesFor(app: *App, arena: Allocator, e: *EditorPane, theme: *const Theme) Allocator.Error![]editor_view.Underline {
    const path = e.buf.doc.path orelse return &.{};
    const fd = app.lsp.decor.get(path) orelse return &.{};
    const ed = e.buf.editor;
    if (!setFresh(types.DocumentLink, &fd.links, ed.doc.edits.head())) return &.{};
    const enc = if (lsp.serverFor(app, path)) |s| s.encoding else .utf16;
    var out: std.ArrayListUnmanaged(editor_view.Underline) = .empty;
    var style = theme.accent;
    style.ul_style = .single;
    var last_end: usize = 0;
    for (fd.links.items) |l| {
        var start = byteAt(ed, l.range.start, enc);
        const end = byteAt(ed, l.range.end, enc);
        if (start < last_end) start = last_end;
        if (end <= start) continue;
        try out.append(arena, .{ .start = start, .end = end, .style = style });
        last_end = end;
    }
    return out.items;
}

/// Two sorted, non-overlapping underline lists into one: where they
/// overlap `prime` wins (a diagnostic over a link).
pub fn mergeUnderlines(arena: Allocator, prime: []const editor_view.Underline, other: []const editor_view.Underline) Allocator.Error![]editor_view.Underline {
    if (other.len == 0) return @constCast(prime);
    if (prime.len == 0) return @constCast(other);
    const engine = @import("highlight").engine;
    return engine.layerSpans(editor_view.Underline, arena, other, prime);
}

// ─── code lenses: run ───────────────────────────────────────────────────

/// Run lens `idx` of the pane's file: its command, else resolve it first.
pub fn runLens(app: *App, pane: PaneId, idx: usize) Allocator.Error!void {
    const e = app.panes.editor(pane) orelse return;
    const path = e.buf.doc.path orelse return;
    const fd = app.lsp.decor.get(path) orelse return;
    if (idx >= fd.lenses.items.len) return;
    const lens = fd.lenses.items[idx];
    const s = lsp.serverFor(app, path) orelse return;
    if (jsonrpc.getObj(lens.raw, "command")) |cmd| {
        app.toast("code lens: {s}", .{lens.title orelse "running"});
        return runLensCommand(app, s, pane, cmd);
    }
    if (!s.caps.code_lens_resolve) {
        app.toast("code lens: nothing to run", .{});
        return;
    }
    const gpa = app.gpa;
    const raw_json = try jsonrpc.stringify(gpa, lens.raw);
    defer gpa.free(raw_json);
    const id = s.transport.allocId();
    const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"codeLens/resolve\",\"params\":{s}}}", .{ id, raw_json });
    defer gpa.free(body);
    try s.transport.expect(id, .{ .kind = @intFromEnum(ReqKind.code_lens_resolve), .ctx = (Ctx{ .pane = pane, .extra = @intCast(@min(idx, std.math.maxInt(u32))) }).pack() });
    s.transport.send(body) catch {
        _ = s.transport.forget(id);
    };
}

/// A resolved lens: its title lands on the set; its command runs unless
/// the view only asked for the title.
fn runResolvedLens(app: *App, s: *Server, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const view_only = ctx.extra & lens_view_bit != 0;
    const idx: usize = ctx.extra & ~lens_view_bit;
    const r = result orelse return;
    if (app.panes.editor(ctx.pane)) |e| if (e.buf.doc.path) |path| if (app.lsp.decor.get(path)) |fd| {
        // The set may have been replaced since the ask: the range says
        // whether this is still the lens that asked.
        const same = idx < fd.lenses.items.len and if (jsonrpc.getObj(r, "range")) |rv|
            (if (types.readRange(rv)) |rg| std.meta.eql(rg, fd.lenses.items[idx].range) else false)
        else
            !view_only;
        if (same) if (jsonrpc.getObj(r, "command")) |cmd| if (jsonrpc.getStr(cmd, "title")) |title| {
            fd.lenses.items[idx].title = try fd.lenses.arena.allocator().dupe(u8, title);
        };
    };
    app.needs_render = true;
    if (view_only) return;
    if (jsonrpc.getObj(r, "command")) |cmd| {
        try runLensCommand(app, s, ctx.pane, cmd);
    } else app.toast("code lens: nothing to run", .{});
}

/// Run a lens's command. One the server lists in
/// `executeCommandProvider.commands` goes back to it as
/// `workspace/executeCommand`. The rest are the client's to run, and
/// servers hand out two such shapes for their reference-count lenses:
/// an LSP request name with its params as the one argument
/// (`textDocument/references` + `ReferenceParams` — csharp-ls, Roslyn),
/// which mnml sends itself and shows as it shows `gr`; and VS Code's
/// `editor.action.showReferences` / `rust-analyzer.showReferences`
/// `[uri, position, locations]`, whose locations open in the picker. Any
/// other command is named in a toast, never sent to a server that did
/// not offer it.
fn runLensCommand(app: *App, s: *Server, pane: PaneId, cmd: Value) Allocator.Error!void {
    const name = jsonrpc.getStr(cmd, "command") orelse return;
    if (s.caps.executesCommand(name)) return lsp.executeCommand(app, s, cmd);
    const args: []const Value = jsonrpc.getArr(cmd, "arguments") orelse &.{};
    const requests = [_]struct { []const u8, ReqKind }{
        .{ "textDocument/references", .references },
        .{ "textDocument/implementation", .implementation },
        .{ "textDocument/definition", .definition },
        .{ "textDocument/typeDefinition", .type_definition },
        .{ "textDocument/declaration", .declaration },
    };
    for (requests) |rq| if (std.mem.eql(u8, name, rq[0])) {
        if (args.len == 0 or args[0] != .object) break;
        _ = s.request(rq[1], rq[0], args[0], .{ .pane = pane }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => app.toast("code lens: couldn't send {s}", .{name}),
        };
        return;
    };
    const show_refs = [_][]const u8{ "editor.action.showReferences", "rust-analyzer.showReferences" };
    for (show_refs) |sr| if (std.mem.eql(u8, name, sr) and args.len >= 3) {
        const locs = try types.readLocations(app.frame.allocator(), args[2]);
        return lsp.locationsPicker(app, "References", locs, "no references");
    };
    app.toast("code lens: {s} is a client-side command mnml does not run", .{name});
}

/// A `.script_hit` on an editor pane: a lens segment.
pub fn scriptHit(app: *App, pane: PaneId, id: u32) Allocator.Error!void {
    if (id < lens_hit_base) return;
    try runLens(app, pane, id - lens_hit_base);
}

/// The first lens on the active editor's cursor line.
pub fn lensAtCursor(app: *App) ?struct { pane: PaneId, idx: usize } {
    const pane = app.active orelse return null;
    const e = app.panes.editor(pane) orelse return null;
    const path = e.buf.doc.path orelse return null;
    const fd = app.lsp.decor.get(path) orelse return null;
    if (!app.cfg.editor.code_lens or !setFresh(types.CodeLens, &fd.lenses, e.buf.doc.edits.head())) return null;
    const line: u32 = @intCast(e.buf.editor.currentLine());
    for (fd.lenses.items, 0..) |l, i| if (l.range.start.line == line) return .{ .pane = pane, .idx = i };
    return null;
}

/// `lsp.code_lens_run`: the lens above the cursor's line.
pub fn runLensAtCursor(app: *App) CommandError!void {
    const hit = lensAtCursor(app) orelse return app.diag.fail(app.frame.allocator(), "no code lens on this line", .{});
    try runLens(app, hit.pane, hit.idx);
}

/// Enter in vim's Normal mode on a line that carries a lens runs it.
/// // changed: Insert / standard-mode Enter is a newline, always; the
/// lens is a click or `lsp.code_lens_run` there.
pub fn interceptKey(app: *App, k: Key) Allocator.Error!bool {
    if (k.code != .enter or k.mods.ctrl or k.mods.alt or k.mods.shift) return false;
    if (app.focus != .pane) return false;
    const e = app.activeEditor() orelse return false;
    if (e.buf.input.mode() != .normal) return false;
    const hit = lensAtCursor(app) orelse return false;
    try runLens(app, hit.pane, hit.idx);
    return true;
}

// ─── document links: open ───────────────────────────────────────────────

/// The link under the active editor's cursor: the server's, else a
/// `scheme://…` token on the line.
pub fn linkAtCursor(app: *App, arena: Allocator) Allocator.Error!?[]const u8 {
    const e = app.activeEditor() orelse return null;
    const ed = e.buf.editor;
    const cur = ed.cursor;
    if (e.buf.doc.path) |path| if (app.lsp.decor.get(path)) |fd| if (setFresh(types.DocumentLink, &fd.links, ed.doc.edits.head())) {
        const enc = if (lsp.serverFor(app, path)) |s| s.encoding else .utf16;
        for (fd.links.items) |l| {
            const start = byteAt(ed, l.range.start, enc);
            const end = byteAt(ed, l.range.end, enc);
            if (cur >= start and cur < end) {
                if (l.target) |t| return t;
                return try arena.dupe(u8, ed.bytes()[start..end]);
            }
        }
    };
    const line = ed.currentLine();
    const text = ed.bytes()[ed.lineStart(line)..ed.lineEnd(line)];
    const col = cur - ed.lineStart(line);
    return urlAt(text, col);
}

/// A `scheme://` token of `line` covering `col`.
pub const urlAt = @import("../ui/link_span.zig").urlAt;

/// `editor.open_url_at_cursor` (`gx`): the link under the cursor, in
/// the OS browser.
pub fn openLinkAtCursor(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    _ = try app.requireEditor();
    const url = (try linkAtCursor(app, arena)) orelse return app.diag.fail(arena, "no link under cursor", .{});
    openExternal(app, url) catch |err| return app.diag.fail(arena, "open {s}: {s}", .{ url, @errorName(err) });
    app.toast("opened {s}", .{url});
}

/// Hand `url` to the desktop's opener.
pub fn openExternal(app: *App, url: []const u8) !void {
    if (@import("browser_open.zig").diverted(app, url)) return;
    // `ui.external_browser` names the application (trust-stripped upstream).
    const argv = try @import("browser_open.zig").argv(app, app.frame.allocator(), url);
    const result = try std.process.run(app.gpa, app.io, .{ .argv = argv, .environ_map = &app.env });
    app.gpa.free(result.stdout);
    app.gpa.free(result.stderr);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "through the fake server: hints and swatches paint as virtual text, lenses as a row above; a lens runs by command, by resolve and by Enter; links underline and answer gx; the toggle clears the hints; an edit stales them" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    const file = lsp.TestRig.file();
    const e = try lsp.TestRig.openFile(&app, file, lsp.TestRig.text);
    const Cond = struct {
        fn decorated(a: *App) bool {
            const fd = a.lsp.decor.get(lsp.TestRig.file()) orelse return false;
            return fd.hints.seq != null and fd.lenses.seq != null and fd.colors.seq != null and fd.links.seq != null;
        }
        fn hintsFresh(a: *App) bool {
            const fd = a.lsp.decor.get(lsp.TestRig.file()) orelse return false;
            return fd.hints.seq != null and fd.hints.seq.? == a.activeEditor().?.buf.doc.edits.head();
        }
        fn ranOne(a: *App) bool {
            return std.mem.indexOf(u8, a.lastToast() orelse return false, "ran refs #1") != null;
        }
        fn ranZero(a: *App) bool {
            return std.mem.indexOf(u8, a.lastToast() orelse return false, "ran refs #0") != null;
        }
        fn lensTitled(a: *App) bool {
            const fd = a.lsp.decor.get(lsp.TestRig.file()) orelse return false;
            return fd.lenses.items.len > 0 and fd.lenses.items[0].title != null;
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.decorated, 5000);
    // The paint: the hint's parts joined after `x`, the swatch before the
    // red `1`, the lens that came with a command titled above line 1; the
    // one that came without is resolved because it is in view — its title
    // lands above line 0 and nothing runs.
    try lsp.TestRig.pump(&app, &app, Cond.lensTitled, 5000);
    const txt = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "let x: number = ■ 1;") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "2 references") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "resolved lens") != null);
    // (An ellipsis on screen is no evidence either way: the tab strip
    // clips the file's long name with one.)
    try testing.expect(std.mem.indexOf(u8, txt, "▌    resolved lens") != null);
    try testing.expect(std.mem.indexOf(u8, app.lastToast() orelse "", "ran refs") == null);
    // Links: one single underline over `foo` on line 1 (bytes 17..20);
    // `gx` there answers with the server's target, elsewhere it fails.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const uls = try linkUnderlinesFor(&app, arena.allocator(), e, &app.theme);
    try testing.expectEqual(@as(usize, 1), uls.len);
    try testing.expectEqual(@as(usize, 17), uls[0].start);
    try testing.expectEqual(@as(usize, 20), uls[0].end);
    try testing.expect(uls[0].style.ul_style == .single);
    e.buf.editor.setCursor(18);
    try testing.expectEqualStrings("https://example.com/foo", (try linkAtCursor(&app, arena.allocator())).?);
    e.buf.editor.setCursor(0);
    try testing.expect((try linkAtCursor(&app, arena.allocator())) == null);
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.open_url_at_cursor" }));
    try testing.expectEqualStrings("no link under cursor", app.lastToast().?);
    // A lens with a command runs it; the server announces what ran.
    e.buf.editor.setCursor(11);
    try command.run(&app, .{ .static = .@"lsp.code_lens_run" });
    try testing.expectEqualStrings("code lens: 2 references", app.lastToast().?);
    try lsp.TestRig.pump(&app, &app, Cond.ranOne, 5000);
    // A lens without one is resolved first: its title lands, then it runs.
    e.buf.editor.setCursor(0);
    try command.run(&app, .{ .static = .@"lsp.code_lens_run" });
    try lsp.TestRig.pump(&app, &app, Cond.ranZero, 5000);
    try testing.expectEqualStrings("resolved lens", app.lsp.decor.get(file).?.lenses.items[0].title.?);
    // Enter in vim's Normal mode on a lens's line runs it; a click on its
    // segment does the same.
    try app.setInputStyle(.vim);
    e.buf.editor.setCursor(11);
    try app.handle(.{ .key = Key.named(.enter) });
    try testing.expectEqualStrings("code lens: 2 references", app.lastToast().?);
    app.toast("cleared", .{});
    try scriptHit(&app, app.active.?, lens_hit_base + 1);
    try testing.expectEqualStrings("code lens: 2 references", app.lastToast().?);
    // No lens on line 2.
    e.buf.editor.setCursor(26);
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"lsp.code_lens_run" }));
    // The toggle: off clears the hints at once, on asks again.
    try command.run(&app, .{ .static = .@"lsp.inlay_hints_toggle" });
    try testing.expect(!app.cfg.editor.inlay_hints);
    const off = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(off);
    try testing.expect(std.mem.indexOf(u8, off, ": number") == null);
    try testing.expect(std.mem.indexOf(u8, off, "■ 1;") != null);
    try command.run(&app, .{ .static = .@"lsp.inlay_hints_toggle" });
    try lsp.TestRig.pump(&app, &app, Cond.hintsFresh, 5000);
    const on = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(on);
    try testing.expect(std.mem.indexOf(u8, on, ": number") != null);
    // An edit stales the set: nothing paints until the idle refresh lands.
    try app.splice(e, 0, 0, "//");
    const stale = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(stale);
    try testing.expect(std.mem.indexOf(u8, stale, ": number") == null);
    try lsp.TestRig.pump(&app, &app, Cond.hintsFresh, 5000);
    const fresh = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(fresh);
    try testing.expect(std.mem.indexOf(u8, fresh, ": number") != null);
    try rig.stop(&app);
}

test "hints answering the request sent on OPEN paint on an untouched document (its head is 0), and the toggle paints them again without an edit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    // From disk, through the open hook: nothing has edited the buffer,
    // so the edit log's head is 0 — the value the old `0 = never
    // landed` sentinel could not tell from "stale".
    const path = lsp.TestRig.scratch("mnml-zig-fake-lsp-open.ts");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = lsp.TestRig.text });
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};
    const pane = try app.openPath(path);
    const e = app.panes.editor(pane).?;
    try testing.expectEqual(@as(u64, 0), e.buf.doc.edits.head());
    const Cond = struct {
        fn painted(a: *App) bool {
            const txt = lsp.TestRig.screenText(a, a.gpa) catch return false;
            defer a.gpa.free(txt);
            return std.mem.indexOf(u8, txt, "let x: number") != null;
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.painted, 5000);
    try testing.expectEqual(@as(u64, 0), e.buf.doc.edits.head());
    // Off clears them; on asks again and the reply paints — still no edit.
    try command.run(&app, .{ .static = .@"lsp.inlay_hints_toggle" });
    const off = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(off);
    try testing.expect(std.mem.indexOf(u8, off, ": number") == null);
    try command.run(&app, .{ .static = .@"lsp.inlay_hints_toggle" });
    try lsp.TestRig.pump(&app, &app, Cond.painted, 5000);
    try testing.expectEqual(@as(u64, 0), e.buf.doc.edits.head());
    try rig.stop(&app);
}

test "urlAt finds the scheme token under a column and trims trailing punctuation" {
    const line = "see https://ziglang.org/docs, or (http://example.com/a).";
    try testing.expectEqualStrings("https://ziglang.org/docs", urlAt(line, 10).?);
    try testing.expectEqualStrings("http://example.com/a", urlAt(line, 40).?);
    try testing.expect(urlAt(line, 0) == null);
    try testing.expect(urlAt("no links here", 3) == null);
}

test "mergeUnderlines: the prime list wins where it overlaps the other" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const diag: Style = .{ .ul_style = .curly };
    const link: Style = .{ .ul_style = .single };
    const prime = [_]editor_view.Underline{.{ .start = 4, .end = 8, .style = diag }};
    const other = [_]editor_view.Underline{.{ .start = 0, .end = 12, .style = link }};
    const out = try mergeUnderlines(arena.allocator(), &prime, &other);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(usize, 0), out[0].start);
    try testing.expectEqual(@as(usize, 4), out[0].end);
    try testing.expect(out[1].style.ul_style == .curly);
    try testing.expectEqual(@as(usize, 8), out[2].start);
}

/// A `.ts` under the rig's `/tmp` root that `openPath` reads from disk,
/// so its edit-log head is 0 — the state a file has when it is only read.
fn readonlyFile() []const u8 {
    return lsp.TestRig.scratch("mnml-zig-fake-lsp-readonly.ts");
}

test "a file only READ (edit-log head 0) has its lenses and tokens asked for on open and painted with no edit; a server that comes up again asks afresh" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = readonlyFile(), .data = lsp.TestRig.text });
    defer std.Io.Dir.cwd().deleteFile(testing.io, readonlyFile()) catch {};
    const pane = try app.openPath(readonlyFile());
    const e = app.panes.editor(pane).?;
    try testing.expectEqual(@as(u64, 0), e.buf.doc.edits.head());
    const Cond = struct {
        fn painted(a: *App) bool {
            const fd = a.lsp.decor.get(readonlyFile()) orelse return false;
            const sf = a.lsp.semantic.get(readonlyFile()) orelse return false;
            return setFresh(types.InlayHint, &fd.hints, 0) and setFresh(types.CodeLens, &fd.lenses, 0) and sf.seq != null and sf.seq.? == 0;
        }
        fn asked(a: *App) bool {
            const tr = a.lsp.decor_track.get(a.active.?) orelse return false;
            return tr.seq != null;
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.painted, 5000);
    // Still untouched: nothing here edited the buffer to get there.
    try testing.expectEqual(@as(u64, 0), e.buf.doc.edits.head());
    const txt = try lsp.TestRig.screenText(&app, gpa);
    defer gpa.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "let x: number") != null);
    try testing.expect(std.mem.indexOf(u8, txt, "2 references") != null);
    // A server that comes up again (a restart) asks for every pane's
    // sets afresh, whatever text they last asked at.
    onServerReady(&app, app.lsp.servers.items[0]);
    try testing.expect(!Cond.asked(&app));
    try lsp.TestRig.pump(&app, &app, Cond.asked, 5000);
    try rig.stop(&app);
}

test "through the fake server: a lens command the server did not offer runs client-side — `textDocument/references` asks for the references and opens the picker, `editor.action.showReferences` opens its locations, anything else is named and never sent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = lsp.TestRig.dir(), .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    _ = try lsp.TestRig.openFile(&app, lsp.TestRig.file(), lsp.TestRig.text);
    const Cond = struct {
        fn ready(a: *App) bool {
            const sv = a.lsp.servers.items[0];
            return sv.ready and sv.isOpen(lsp.TestRig.file());
        }
        fn picker(a: *App) bool {
            return a.overlay == .picker;
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.ready, 5000);
    const s = app.lsp.servers.items[0];
    const pane = app.active.?;
    // The server offers `refs` and nothing else.
    try testing.expect(s.caps.executesCommand("refs"));
    try testing.expect(!s.caps.executesCommand("textDocument/references"));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const uri = try types.uriFromPath(a, lsp.TestRig.file());

    // csharp-ls's resolved lens: the request name, `ReferenceParams` as
    // its one argument (`foo` on line 1).
    const refs_json = try std.fmt.allocPrint(a, "{{\"title\":\"2 Reference(s)\",\"command\":\"textDocument/references\",\"arguments\":[{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":1,\"character\":7}},\"context\":{{\"includeDeclaration\":false}}}}]}}", .{uri});
    const refs = try std.json.parseFromSliceLeaky(Value, a, refs_json, .{});
    try runLensCommand(&app, s, pane, refs);
    try lsp.TestRig.pump(&app, &app, Cond.picker, 5000);
    try testing.expectEqualStrings("References", app.overlay.picker.state.title);
    try testing.expectEqual(@as(usize, 2), app.overlay.picker.labels.len);
    try testing.expectEqualStrings("mnml-zig-fake-lsp.ts:2:7", app.overlay.picker.labels[0]);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.overlay != .picker);

    // VS Code's shape: `[uri, position, locations]` — no round trip.
    const show_json = try std.fmt.allocPrint(a, "{{\"title\":\"1 reference\",\"command\":\"editor.action.showReferences\",\"arguments\":[\"{s}\",{{\"line\":1,\"character\":6}},[{{\"uri\":\"{s}\",\"range\":{{\"start\":{{\"line\":2,\"character\":0}},\"end\":{{\"line\":2,\"character\":3}}}}}}]]}}", .{ uri, uri });
    const show = try std.json.parseFromSliceLeaky(Value, a, show_json, .{});
    const before = s.transport.pendingCount();
    try runLensCommand(&app, s, pane, show);
    try testing.expectEqual(before, s.transport.pendingCount());
    try testing.expect(app.overlay == .picker);
    try testing.expectEqualStrings("References", app.overlay.picker.state.title);
    try testing.expectEqualStrings("mnml-zig-fake-lsp.ts:3:1", app.overlay.picker.labels[0]);
    try app.handle(.{ .key = Key.named(.esc) });
    try testing.expect(app.overlay != .picker);

    // A command the server did not list and mnml does not know: said,
    // not sent — no `workspace/executeCommand` for a server to refuse.
    const other = try std.json.parseFromSliceLeaky(Value, a, "{\"title\":\"x\",\"command\":\"acme.doSomething\",\"arguments\":[1]}", .{});
    try runLensCommand(&app, s, pane, other);
    try testing.expectEqual(before, s.transport.pendingCount());
    try testing.expectEqualStrings("code lens: acme.doSomething is a client-side command mnml does not run", app.lastToast().?);
    // One it did list still goes to it.
    const listed = try std.json.parseFromSliceLeaky(Value, a, "{\"title\":\"x\",\"command\":\"refs\",\"arguments\":[5]}", .{});
    try runLensCommand(&app, s, pane, listed);
    try testing.expectEqual(before + 1, s.transport.pendingCount());
    try rig.stop(&app);
}
