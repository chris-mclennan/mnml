//! Semantic tokens on the app side: one cache per file (the raw
//! `data[]`, the server's `resultId`, the decoded tokens and the edit
//! seq they describe), the request chooser (`full/delta` when the
//! server takes deltas and a `resultId` is held, `full` when it does
//! not, `range` for the visible lines when that is all it offers), and
//! the frame's layering: the tokens of the visible lines become styled
//! spans laid OVER the tree-sitter spans through
//! `highlight.engine.layerSpans`, so the grammar keeps every byte the
//! server does not name.
//!
//! A cache whose seq is behind the buffer paints nothing until the
//! frame's idle refresh brings a fresh reply (`lsp_decor.onFrame`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const editor_view = @import("../ui/editor_view.zig");
const Theme = @import("../ui/theme.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const client = @import("../lsp/client.zig");
const types = @import("../lsp/types.zig");
const semantic = @import("../lsp/semantic.zig");
const highlight = @import("highlight");
const lsp = @import("lsp.zig");

const Server = client.Server;
const ReqKind = client.ReqKind;
const Ctx = client.Ctx;
const Value = jsonrpc.Value;
const Style = @import("vaxis").Style;

/// One file's tokens. Every slice is gpa-owned by the entry.
pub const SemFile = struct {
    data: []u32 = &.{},
    result_id: ?[]u8 = null,
    tokens: []semantic.Token = &.{},
    /// The edit-log seq the tokens describe; null = stale or never landed.
    seq: ?u64 = null,
    /// A `range` reply: the tokens cover only the lines asked for, and
    /// the next request must not be a delta.
    partial: bool = false,

    pub fn destroy(self: *SemFile, gpa: Allocator) void {
        gpa.free(self.data);
        if (self.result_id) |r| gpa.free(r);
        gpa.free(self.tokens);
        gpa.destroy(self);
    }
};

fn entry(app: *App, path: []const u8, create: bool) Allocator.Error!?*SemFile {
    if (app.lsp.semantic.get(path)) |f| return f;
    if (!create) return null;
    const gpa = app.gpa;
    const key = try gpa.dupe(u8, path);
    errdefer gpa.free(key);
    const f = try gpa.create(SemFile);
    errdefer gpa.destroy(f);
    f.* = .{};
    try app.lsp.semantic.put(gpa, key, f);
    return f;
}

pub fn drop(app: *App, path: []const u8) void {
    if (app.lsp.semantic.fetchRemove(path)) |kv| {
        app.gpa.free(kv.key);
        kv.value.destroy(app.gpa);
    }
}

fn seqLow(seq: u64) u32 {
    return @truncate(seq);
}

/// Ask for the file's tokens in the cheapest shape the server takes.
pub fn request(app: *App, s: *Server, pane: PaneId, e: *EditorPane, first: u32, last: u32) void {
    const path = e.buf.doc.path orelse return;
    const arena = app.frame.allocator();
    const uri = types.uriFromPath(arena, path) catch return;
    const head = e.buf.doc.edits.head();
    const ctx: Ctx = .{ .pane = pane, .extra = seqLow(head) };
    const held: ?*SemFile = app.lsp.semantic.get(path);
    if (s.caps.semantic_delta and held != null and held.?.result_id != null and !held.?.partial) {
        _ = s.request(.semantic_delta, "textDocument/semanticTokens/full/delta", .{ .textDocument = .{ .uri = uri }, .previousResultId = held.?.result_id.? }, ctx) catch {};
    } else if (s.caps.semantic_full) {
        _ = s.request(.semantic_full, "textDocument/semanticTokens/full", .{ .textDocument = .{ .uri = uri } }, ctx) catch {};
    } else if (s.caps.semantic_range) {
        const ed = e.buf.editor;
        const lo: u32 = first -| (last -| first + 1);
        const hi: u32 = @intCast(@min(last + (last -| first + 1), ed.lineCount() - 1));
        const range: types.Range = .{ .start = .{ .line = lo, .character = 0 }, .end = types.positionOf(ed.bytes(), ed.lineEnd(hi), s.encoding) };
        _ = s.request(.semantic_range, "textDocument/semanticTokens/range", .{ .textDocument = .{ .uri = uri }, .range = range }, ctx) catch {};
    }
}

pub fn handleResponse(app: *App, s: *Server, kind: ReqKind, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const gpa = app.gpa;
    const e = app.panes.editor(ctx.pane) orelse return;
    const path = e.buf.doc.path orelse return;
    const f = (try entry(app, path, true)).?;
    const r = result orelse {
        // `null`: the server has nothing — keep painting nothing.
        replaceData(gpa, f, try gpa.alloc(u32, 0));
        f.seq = null;
        return;
    };
    const head = e.buf.doc.edits.head();
    const fresh = seqLow(head) == ctx.extra;
    if (kind == .semantic_delta and jsonrpc.getField(r, "edits") != null) {
        const arena = app.frame.allocator();
        const edits = try semantic.readEdits(arena, jsonrpc.getField(r, "edits"));
        replaceData(gpa, f, try semantic.applyDelta(gpa, f.data, edits));
    } else {
        replaceData(gpa, f, try semantic.readData(gpa, jsonrpc.getField(r, "data")));
    }
    if (f.result_id) |old| gpa.free(old);
    f.result_id = if (jsonrpc.getStr(r, "resultId")) |id| try gpa.dupe(u8, id) else null;
    f.partial = kind == .semantic_range;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const decoded = try semantic.decode(arena.allocator(), f.data, s.caps.token_types);
    gpa.free(f.tokens);
    f.tokens = try gpa.dupe(semantic.Token, decoded);
    f.seq = if (fresh) head else null;
    app.needs_render = true;
}

fn replaceData(gpa: Allocator, f: *SemFile, fresh: []u32) void {
    gpa.free(f.data);
    f.data = fresh;
}

/// The style a token paints with: its role's, plus what the modifiers
/// say. // changed: no theme names modifier styles, so the mapping is
/// fixed — `declaration` bold, `static` italic, `deprecated` struck
/// through, `documentation` in the comment colour.
fn tokenStyle(theme: *const Theme, tok: semantic.Token, legend: []const semantic.Modifier) Style {
    var st = if (tok.has(legend, .documentation)) theme.syntax.comment else theme.roleStyle(tok.role);
    if (tok.has(legend, .declaration)) st.bold = true;
    if (tok.has(legend, .static)) st.italic = true;
    if (tok.has(legend, .deprecated)) st.strikethrough = true;
    return st;
}

/// The tokens of lines `lo..=hi` as styled byte spans, sorted and
/// non-overlapping; empty when off, stale or absent. Frame arena.
pub fn spansFor(app: *App, arena: Allocator, e: *EditorPane, theme: *const Theme, lo_line: usize, hi_line: usize) Allocator.Error![]editor_view.Span {
    if (!app.cfg.editor.semantic_tokens) return &.{};
    const path = e.buf.doc.path orelse return &.{};
    const f = app.lsp.semantic.get(path) orelse return &.{};
    const ed = e.buf.editor;
    if (f.seq == null or f.seq.? != ed.doc.edits.head()) return &.{};
    const s = lsp.serverFor(app, path) orelse return &.{};
    const text = ed.bytes();
    const lines = ed.lineCount();
    // Binary search the first token on or after `lo_line`.
    var a: usize = 0;
    var b: usize = f.tokens.len;
    while (a < b) {
        const mid = a + (b - a) / 2;
        if (f.tokens[mid].line < lo_line) a = mid + 1 else b = mid;
    }
    var out: std.ArrayListUnmanaged(editor_view.Span) = .empty;
    var last_end: usize = 0;
    var i = a;
    while (i < f.tokens.len and f.tokens[i].line <= hi_line) : (i += 1) {
        const tok = f.tokens[i];
        if (tok.line >= lines) break;
        const ls = ed.lineStart(tok.line);
        const le = ed.lineEnd(tok.line);
        const slice = text[ls..le];
        const start = ls + types.byteInLine(slice, tok.start, s.encoding);
        const end = ls + types.byteInLine(slice, tok.start + tok.len, s.encoding);
        if (end <= start or start < last_end) continue;
        try out.append(arena, .{ .start = start, .end = end, .style = tokenStyle(theme, tok, s.caps.token_modifiers) });
        last_end = end;
    }
    return out.items;
}

/// `base` (the grammar's spans for the window) with the server's tokens
/// laid over it.
pub fn layer(app: *App, arena: Allocator, e: *EditorPane, theme: *const Theme, base: []editor_view.Span, lo_line: usize, hi_line: usize) Allocator.Error![]editor_view.Span {
    const over = try spansFor(app, arena, e, theme, lo_line, hi_line);
    if (over.len == 0) return base;
    return highlight.engine.layerSpans(editor_view.Span, arena, base, over);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const builtin = @import("builtin");
const Color = @import("vaxis").Color;

test "through the fake server: a full reply's tokens layer over the grammar's spans; an edit stales them until the delta reply replaces the cache" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    const file = lsp.TestRig.file;
    const e = try lsp.TestRig.openFile(&app, file, lsp.TestRig.text);
    const Cond = struct {
        fn landed(a: *App, id: []const u8) bool {
            const f = a.lsp.semantic.get(lsp.TestRig.file) orelse return false;
            return f.seq != null and f.result_id != null and std.mem.eql(u8, f.result_id.?, id);
        }
        fn full(a: *App) bool {
            return landed(a, "1");
        }
        fn delta(a: *App) bool {
            return landed(a, "2");
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.full, 5000);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t = &app.theme;
    // `let` (keyword), `x` (a declared variable: bold), `const` (keyword).
    const sp = try spansFor(&app, a, e, t, 0, 2);
    try testing.expectEqual(@as(usize, 3), sp.len);
    try testing.expectEqual(@as(usize, 0), sp[0].start);
    try testing.expectEqual(@as(usize, 3), sp[0].end);
    try testing.expect(Color.eql(sp[0].style.fg, t.syntax.keyword.fg));
    try testing.expectEqual(@as(usize, 4), sp[1].start);
    try testing.expect(sp[1].style.bold);
    try testing.expectEqual(@as(usize, 11), sp[2].start);
    try testing.expectEqual(@as(usize, 16), sp[2].end);
    // Layered over a grammar span covering line 0: the tokens win their
    // bytes, the grammar keeps the rest, in order.
    const base = try a.dupe(editor_view.Span, &.{.{ .start = 0, .end = 10, .style = t.syntax.comment }});
    const out = try layer(&app, a, e, t, base, 0, 2);
    try testing.expectEqual(@as(usize, 5), out.len);
    try testing.expectEqual(@as(usize, 3), out[1].start);
    try testing.expectEqual(@as(usize, 4), out[1].end);
    try testing.expect(Color.eql(out[1].style.fg, t.syntax.comment.fg));
    try testing.expectEqual(@as(usize, 5), out[3].start);
    try testing.expectEqual(@as(usize, 10), out[3].end);
    try testing.expectEqual(@as(usize, 11), out[4].start);
    // The master switch leaves the base alone.
    app.cfg.editor.semantic_tokens = false;
    try testing.expectEqual(@as(usize, 1), (try layer(&app, a, e, t, base, 0, 2)).len);
    app.cfg.editor.semantic_tokens = true;
    // An edit on line 2 stales the cache; the idle refresh asks for a
    // delta (a resultId is held) and the splice lands.
    try app.splice(e, e.buf.editor.len() - 1, e.buf.editor.len() - 1, "x");
    try testing.expectEqual(@as(usize, 0), (try spansFor(&app, a, e, t, 0, 2)).len);
    try lsp.TestRig.pump(&app, &app, Cond.delta, 5000);
    const f = app.lsp.semantic.get(file).?;
    try testing.expectEqualSlices(u32, &.{ 0, 0, 3, 0, 0, 0, 4, 1, 1, 1, 1, 6, 3, 2, 0 }, f.data);
    const sp2 = try spansFor(&app, a, e, t, 0, 2);
    try testing.expectEqual(@as(usize, 3), sp2.len);
    try testing.expectEqual(@as(usize, 17), sp2[2].start);
    try testing.expectEqual(@as(usize, 20), sp2[2].end);
    try testing.expect(Color.eql(sp2[2].style.fg, t.syntax.function.fg));
    try rig.stop(&app);
}

test "tokenStyle: the role's colour, the modifiers' attributes" {
    const theme = Theme.default;
    const legend = [_]semantic.Modifier{ .declaration, .none, .deprecated, .static, .documentation };
    const plain = tokenStyle(&theme, .{ .line = 0, .start = 0, .len = 1, .role = .function, .mods = 0 }, &legend);
    try testing.expect(@import("vaxis").Color.eql(plain.fg, theme.syntax.function.fg));
    try testing.expect(!plain.bold);
    const decl = tokenStyle(&theme, .{ .line = 0, .start = 0, .len = 1, .role = .function, .mods = 0b1 }, &legend);
    try testing.expect(decl.bold);
    const gone = tokenStyle(&theme, .{ .line = 0, .start = 0, .len = 1, .role = .type, .mods = 0b1100 }, &legend);
    try testing.expect(gone.strikethrough and gone.italic);
    const doc = tokenStyle(&theme, .{ .line = 0, .start = 0, .len = 1, .role = .type, .mods = 0b10000 }, &legend);
    try testing.expect(@import("vaxis").Color.eql(doc.fg, theme.syntax.comment.fg));
}
