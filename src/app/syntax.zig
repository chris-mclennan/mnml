//! The editor pane's syntax state: a `highlight.Highlighter` fed from
//! the editor's edit log, gated by the idle timer, and read by the
//! editor view (styled spans), the text objects (function / class
//! ranges), the sticky context (the scope chain) and the outline (the
//! symbols).
//!
//! Edits reach the tree the moment a frame asks (`absorb`): the kept
//! tree is told about each splice and the cached spans are shifted to
//! stay aligned with the text, so what is on screen never drifts. The
//! reparse itself waits for `idle_ms` of quiet (or fires at once when
//! the log was lost to a wholesale replacement), so a burst of typing
//! pays for one parse, not one per key.
//!
//! Language detection: the filename (`Makefile`, `Dockerfile.dev`), then
//! the extension (`.tsx` is tsx, not ts), then a shebang.

const std = @import("std");
const Allocator = std.mem.Allocator;
const highlight = @import("highlight");
const ts = highlight.ts;
/// The grammar table (`highlight.table`); `table` itself is this
/// module's command-runner table.
const grammars = highlight.table;
const structure = highlight.structure;
const editor_mod = @import("../editor/editor.zig");
const Editor = editor_mod.Editor;
const editor_view = @import("../ui/editor_view.zig");
const Theme = @import("../ui/theme.zig");

pub const Span = editor_view.Span;
pub const Role = highlight.Role;
pub const Symbol = structure.Symbol;

/// How long after the last observed edit a reparse waits.
pub const idle_ms: i64 = 120;

/// A file up to this size parses on the frame that first sees it; a
/// larger one paints unhighlighted and parses once the idle gate opens,
/// so the first frame after `open` never waits on a full parse.
pub const sync_parse_max_bytes: usize = 32 * 1024;

/// Table key for a file, or null when mnml-zig has no grammar for it.
/// `text` supplies the shebang for extension-less scripts. The rules
/// are `highlight.detect`'s — the one detector the language servers,
/// the tools and the statusline chip read too.
pub fn keyFor(path: ?[]const u8, text: []const u8) ?[]const u8 {
    return highlight.detect.keyFor(path, text);
}

/// `#!/usr/bin/env python3` → `py`, and the other interpreters a
/// script file names.
pub fn keyForShebang(text: []const u8) ?[]const u8 {
    return highlight.detect.keyForShebang(text);
}

/// Kept for callers that only have a path (the outline's fallback).
pub fn keyForPath(path: []const u8) ?[]const u8 {
    return keyFor(path, "");
}

/// A splice as tree-sitter wants to hear it.
pub fn inputEdit(sp: editor_mod.Splice) ts.InputEdit {
    return .{
        .start_byte = @intCast(sp.start),
        .old_end_byte = @intCast(sp.old_end),
        .new_end_byte = @intCast(sp.new_end),
        .start_point = .{ .row = sp.start_pt.row, .column = sp.start_pt.col },
        .old_end_point = .{ .row = sp.old_end_pt.row, .column = sp.old_end_pt.col },
        .new_end_point = .{ .row = sp.new_end_pt.row, .column = sp.new_end_pt.col },
    };
}

pub const Syntax = struct {
    hl: highlight.Highlighter,
    /// Set by every path that mutates the text (and a theme change); the
    /// tree re-parses once `idle_ms` have passed since the frame that
    /// first saw it (`since_ms`), so a burst of typing costs one parse.
    /// One flag per document: the first window to paint clears it for
    /// all of them.
    dirty: bool = true,
    since_ms: ?i64 = null,
    /// The last edit-log seq folded into the tree and the spans.
    seen_seq: u64 = 0,
    /// The seq the kept tree was parsed at; a structural query reparses
    /// when the log moved past it.
    parsed_seq: ?u64 = null,
    /// A worker is parsing this document (`syntax_jobs.zig`): the job's
    /// id, the seq of the text it was handed, and the way to call it off.
    pending: ?Pending = null,
    /// The grammar the document's name (and shebang) picks, kept even
    /// while highlighting is off for it, so turning it back on needs no
    /// re-detection.
    lang: ?usize = null,
    /// Highlighting is off for THIS document: no parse, no tree, no
    /// spans, no injections — every consumer takes the no-grammar path.
    /// Set when the file opens over `editor.highlight_max_bytes`
    /// (`applyLimit`), or by hand (`editor.highlight_toggle_file`).
    /// Per document, never persisted.
    off: bool = false,
    /// The file was over the limit when it opened — what the statusline
    /// chip reports, and why the toast fired. A hand-switched buffer
    /// under the limit has this false and `off` true.
    over_limit: bool = false,
    /// What the limit was measured against: the document's size when it
    /// opened. The chip's ` · 12 MB`.
    size_bytes: usize = 0,
    /// The limit in force when this document opened, for the toast and
    /// the chip's hover.
    limit_bytes: u64 = 0,

    pub const Pending = struct { id: u64, base_seq: u64, ticket: *@import("syntax_jobs.zig").Ticket };

    /// A document longer than this is never parsed by the frame that
    /// paints it — a worker does it (`syntax_jobs.zig`). It decides WHERE
    /// the parse runs, never whether: every file is parsed and
    /// highlighted in full. At ~70 ms per MB for a first parse and ~6 ms
    /// per MB for a reparse, a megabyte is where a parse starts to be
    /// felt in a frame.
    pub const worker_min_bytes: usize = 1 << 20;

    pub fn onWorker(text_len: usize) bool {
        return text_len > worker_min_bytes;
    }

    pub fn init(gpa: Allocator) Syntax {
        return .{ .hl = highlight.Highlighter.init(gpa) };
    }

    pub fn deinit(self: *Syntax) void {
        self.callOff();
        self.hl.deinit();
    }

    /// Tell the worker (if one is parsing this document) that its tree is
    /// not wanted; whatever it posts finds nobody waiting.
    pub fn callOff(self: *Syntax) void {
        const p = self.pending orelse return;
        p.ticket.cancel.store(true, .release);
        p.ticket.release(self.hl.gpa);
        self.pending = null;
    }

    /// The oldest edit-log seq this document's syntax still needs: what
    /// it has folded in, or — while a worker parses — the text that was
    /// handed over, so the edits made since can be told to its tree.
    pub fn trimFloor(self: *const Syntax) u64 {
        return if (self.pending) |p| @min(p.base_seq, self.seen_seq) else self.seen_seq;
    }

    /// Pick the grammar for `path` (+ `text` for a shebang). A file with
    /// no grammar has no spans and stays that way until a rename.
    pub fn setLanguage(self: *Syntax, path: ?[]const u8, text: []const u8) void {
        const key_name = keyFor(path, text);
        self.useLanguage(if (key_name) |k| grammars.find(k) else null);
    }

    /// `setLanguage` on an index already picked. The highlighter is told
    /// nothing while highlighting is off for this document: `off` is the
    /// same state as "no grammar for this file", so folds, the outline,
    /// the sticky context and the text objects all take the path they
    /// take for a plain-text file.
    fn useLanguage(self: *Syntax, idx: ?usize) void {
        self.lang = idx;
        const want = if (self.off) null else idx;
        if (want != self.hl.root) {
            self.parsed_seq = null;
            self.callOff();
        }
        self.hl.setLanguage(want);
    }

    /// On open: decide whether this document is highlighted at all.
    /// `limit` of 0 is no limit — every file is parsed in full. Over the
    /// limit (4 MiB is the shipped default) the file opens with no
    /// tree-sitter at all; `over_limit` then tells the statusline to say
    /// so.
    pub fn applyLimit(self: *Syntax, size: usize, limit: u64) void {
        self.size_bytes = size;
        self.limit_bytes = limit;
        self.over_limit = limit != 0 and size > limit;
        self.setOff(self.over_limit);
    }

    /// Turn highlighting off for this document (dropping the tree, the
    /// spans and any parse under way) or back on (the next frame parses,
    /// on a worker for a large file as any other does).
    pub fn setOff(self: *Syntax, off: bool) void {
        if (self.off == off) return;
        self.off = off;
        if (off) {
            self.callOff();
            self.hl.invalidate();
            self.parsed_seq = null;
        }
        self.useLanguage(self.lang);
        self.dirty = !off;
        self.since_ms = null;
    }

    /// Whether the statusline shows this document's highlight chip: a
    /// file that opened over the limit (on or off), or any buffer
    /// switched off by hand. A normal buffer has no chip.
    pub fn showsChip(self: *const Syntax) bool {
        return self.over_limit or self.off;
    }

    /// `12 MB`, `512 KB`, `73 B` — the chip's and the toast's sizes. A
    /// whole number of units keeps no decimal (`4 MB`, not `4.0 MB`).
    pub fn sizeLabel(buf: []u8, n: u64) []const u8 {
        const mb: u64 = 1024 * 1024;
        if (n >= mb) {
            if (n % mb == 0) return std.fmt.bufPrint(buf, "{d} MB", .{n / mb}) catch "?";
            return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(mb))}) catch "?";
        }
        if (n >= 1024) {
            if (n % 1024 == 0) return std.fmt.bufPrint(buf, "{d} KB", .{n / 1024}) catch "?";
            return std.fmt.bufPrint(buf, "{d:.1} KB", .{@as(f64, @floatFromInt(n)) / 1024.0}) catch "?";
        }
        return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    }

    pub fn hasLanguage(self: *const Syntax) bool {
        return self.hl.hasLanguage();
    }

    /// The table key of the grammar for this file (`rs`, `tsx`), or
    /// null. The file's language, not the highlighter's state: a
    /// document whose highlighting is off still answers, so the
    /// consumers with a no-tree path (the sticky context's line
    /// patterns) keep working on it.
    pub fn key(self: *const Syntax) ?[]const u8 {
        const i = self.lang orelse return null;
        return grammars.entries[i].key;
    }

    /// Fold the editor's edits since the last call into the tree and the
    /// cached spans. Returns true when the log was lost and only a full
    /// reparse can catch up.
    pub fn absorb(self: *Syntax, ed: *const Editor) bool {
        if (ed.doc.edits.lostSince(self.seen_seq)) {
            // The tree goes, and every window built from it with it — and
            // a worker's tree of the text before would be no use either.
            self.callOff();
            self.hl.invalidate();
            self.seen_seq = ed.doc.edits.head();
            self.parsed_seq = null;
            return true;
        }
        for (ed.doc.edits.since(self.seen_seq)) |sp| self.hl.edit(inputEdit(sp));
        self.seen_seq = ed.doc.edits.head();
        return false;
    }

    /// The kept tree and spans describe the current text: a structural
    /// query (`fresh`) parsed since the last edit, or nothing changed.
    pub fn isCurrent(self: *const Syntax) bool {
        return self.parsed_seq != null and self.parsed_seq.? == self.seen_seq;
    }

    /// Whether the frame at `now` reparses: a small file that was never
    /// parsed (or lost its log) does so at once; anything else waits
    /// `idle_ms` from the frame that first saw the text dirty.
    pub fn parseDue(self: *const Syntax, now: i64, text_len: usize) bool {
        if (!self.dirty) return false;
        if (self.parsed_seq == null and text_len <= sync_parse_max_bytes) return true;
        const since = self.since_ms orelse return false;
        return now - since >= idle_ms;
    }

    /// Reparse now (incrementally when the tree is current).
    pub fn refresh(self: *Syntax, ed: *const Editor) Allocator.Error!void {
        _ = self.absorb(ed);
        self.hl.parse(ed.bytes());
        self.parsed_seq = self.seen_seq;
    }

    /// Make the tree current for a structural query, whatever the timer
    /// says. Null when there is no grammar. A document whose parses run
    /// on a worker is never parsed here: the answer comes from the tree
    /// it has — told of every edit, possibly not reparsed since — or is
    /// null while its first parse is still running.
    fn fresh(self: *Syntax, ed: *const Editor) ?ts.Node {
        if (!self.hl.hasLanguage()) return null;
        _ = self.absorb(ed);
        if (onWorker(ed.len())) return self.hl.rootNode();
        if (self.parsed_seq == null or self.parsed_seq.? != self.seen_seq or self.hl.tree == null) {
            self.refresh(ed) catch return null;
        }
        return self.hl.rootNode();
    }

    /// The highlighter's spans over `[lo, hi)`. They are built for the
    /// range asked (and a margin), not the file, so the cost of a frame
    /// follows the viewport. When the range is outside everything kept
    /// and the tree has been told of edits it has not parsed, a small
    /// document parses first; one whose parses run on a worker reads the
    /// window off the tree it has (its nodes sit where the text now is)
    /// and is repainted when the worker's tree lands.
    fn spansOver(self: *Syntax, ed: *const Editor, lo: usize, hi: usize) Allocator.Error![]const highlight.engine.Span {
        if (self.hl.stale and !onWorker(ed.len()) and !self.hl.covers(lo, @min(hi, ed.len()))) try self.refresh(ed);
        return self.hl.spansIn(ed.bytes(), lo, hi);
    }

    /// Spans for the editor view, restricted to `[lo, hi)` bytes and
    /// styled by `theme`. Built on `arena`.
    pub fn styledSpans(self: *Syntax, ed: *const Editor, arena: Allocator, theme: *const Theme, lo: usize, hi: usize) Allocator.Error![]Span {
        const src = try self.spansOver(ed, lo, hi);
        const out = try arena.alloc(Span, src.len);
        for (src, 0..) |s, i| out[i] = .{ .start = s.start, .end = s.end, .style = theme.roleStyle(s.role) };
        return out;
    }

    /// How many spans touch `[lo, hi)` — the driver's `highlightCount`.
    pub fn countIn(self: *Syntax, ed: *const Editor, lo: usize, hi: usize) Allocator.Error!usize {
        return (try self.spansOver(ed, lo, hi)).len;
    }

    /// `if` / `af` / `ic` / `ac`: the tree's answer for the object around
    /// `byte`.
    pub fn objectRange(self: *Syntax, ed: *const Editor, kind: editor_mod.ObjectKind, byte: usize, around: bool) ?[2]usize {
        const root = self.fresh(ed) orelse return null;
        return structure.objectAt(root, ed.bytes(), switch (kind) {
            .function => .function,
            .class => .class,
        }, byte, around);
    }

    /// Start lines of the scopes enclosing `line` that begin above it,
    /// outermost first — the sticky context header rows.
    pub fn scopeChain(self: *Syntax, ed: *const Editor, arena: Allocator, line: u32) Allocator.Error![]u32 {
        const root = self.fresh(ed) orelse return &.{};
        return scopeChainOf(self, root, ed, arena, line);
    }

    /// `scopeChain` on a root the caller already holds (the kept tree).
    pub fn scopeChainOf(self: *const Syntax, root: ts.Node, ed: *const Editor, arena: Allocator, line: u32) Allocator.Error![]u32 {
        _ = self;
        const l = @min(line, @as(u32, @intCast(ed.lineCount() - 1)));
        const at: u32 = @intCast(ed.lineStart(l));
        return structure.scopeChain(arena, root, at, line);
    }

    /// The kept tree's root as it is — told about every edit (`absorb`)
    /// but possibly not reparsed since — or null when there is none yet.
    /// Never parses: the sticky context reads this so a frame stays
    /// cheap while a large file waits for its first parse.
    pub fn keptRoot(self: *const Syntax) ?ts.Node {
        return self.hl.rootNode();
    }

    /// Every definition in the file, for the outline. Null when the file
    /// has no grammar (the caller falls back to line patterns).
    pub fn symbols(self: *Syntax, ed: *const Editor, arena: Allocator) Allocator.Error!?[]Symbol {
        const root = self.fresh(ed) orelse return null;
        return try structure.symbols(arena, root, ed.bytes());
    }
};

// ── the commands ──

const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");

pub const table = .{
    .@"editor.highlight_this_file" = &highlightThisFile,
    .@"editor.highlight_toggle_file" = &highlightToggleFile,
};

/// The name the chip and the toasts use for the active buffer.
fn bufferName(e: *const EditorPane) []const u8 {
    if (e.buf.doc.path) |p| return std.fs.path.basename(p);
    return "[scratch]";
}

/// The toast a file over the limit opens with: what was skipped, why,
/// and the two ways to undo it.
pub fn announceLimit(app: *App, name: []const u8, s: *const Syntax) void {
    var size_buf: [24]u8 = undefined;
    var limit_buf: [24]u8 = undefined;
    app.toast("highlighting off for {s} ({s} > {s}); click the chip or run editor.highlight_this_file to turn it on", .{
        name,
        Syntax.sizeLabel(&size_buf, s.size_bytes),
        Syntax.sizeLabel(&limit_buf, s.limit_bytes),
    });
}

/// `editor.highlight_this_file`: highlight the active buffer after all,
/// whatever the limit said. A file already highlighted is left alone and
/// says so.
fn highlightThisFile(app: *App) command.CommandError!void {
    const e = app.activeEditor() orelse {
        app.toast("no editor", .{});
        return;
    };
    if (!e.syntax.off) {
        app.toast("highlighting is already on for {s}", .{bufferName(e)});
        return;
    }
    try setHighlight(app, e, true);
}

/// `editor.highlight_toggle_file`: the same switch both ways, for ANY
/// buffer — one giant file opened once can be switched off without a
/// config change.
fn highlightToggleFile(app: *App) command.CommandError!void {
    const e = app.activeEditor() orelse {
        app.toast("no editor", .{});
        return;
    };
    try setHighlight(app, e, e.syntax.off);
}

/// Flip one buffer's highlighting and say what happened. The size is the
/// document's now, so a chip on a file that grew reads true.
pub fn setHighlight(app: *App, e: *EditorPane, on: bool) Allocator.Error!void {
    const s = e.syntax;
    s.size_bytes = e.buf.editor.len();
    s.setOff(!on);
    var buf: [24]u8 = undefined;
    app.toast("highlighting {s} for {s} ({s})", .{ if (on) "on" else "off", bufferName(e), Syntax.sizeLabel(&buf, s.size_bytes) });
    app.needs_render = true;
}

// ── tests ──

const testing = std.testing;
const screen_mod = @import("../ipc/screen.zig");

test "language detection: filename, extension (tsx is tsx), shebang" {
    try testing.expectEqualStrings("make", keyFor("/x/Makefile", "").?);
    try testing.expectEqualStrings("dockerfile", keyFor("/x/Dockerfile", "").?);
    try testing.expectEqualStrings("tsx", keyFor("/x/App.tsx", "").?);
    try testing.expectEqualStrings("ts", keyFor("/x/api.ts", "").?);
    try testing.expectEqualStrings("rs", keyFor("/x/LIB.RS", "").?);
    try testing.expect(keyFor("/x/notes.xyz", "plain") == null);
    try testing.expectEqualStrings("py", keyFor("/x/run", "#!/usr/bin/env python3\nprint(1)\n").?);
    try testing.expectEqualStrings("sh", keyFor("/x/run", "#!/bin/bash\n").?);
    try testing.expectEqualStrings("js", keyFor(null, "#!/usr/bin/env node\n").?);
    try testing.expect(keyFor(null, "#!/usr/bin/perl\n") == null);
}

test "C#: the grammar loads for .cs — highlights, the outline, if/af, the sticky chain, a bracket fold" {
    try testing.expectEqualStrings("cs", keyFor("/x/Program.cs", "").?);
    try testing.expectEqualStrings("cs", keyFor("/x/PROGRAM.CS", "").?);
    const gpa = testing.allocator;
    const text = "using System;\n\nnamespace Acme;\n\npublic class Calc\n{\n    public int Count { get; set; }\n\n    public int Add(int a, int b)\n    {\n        var s = \"sum\";\n        return a + b;\n    }\n}\n";
    const ed = try Editor.init(gpa, text);
    defer ed.deinit();
    var s = Syntax.init(gpa);
    defer s.deinit();
    s.setLanguage("/ws/Calc.cs", ed.bytes());
    try testing.expect(s.hasLanguage());
    try s.refresh(ed);
    try testing.expect((try s.hl.spansIn(ed.bytes(), 0, ed.len())).len >= 12);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const syms = (try s.symbols(ed, arena.allocator())).?;
    try testing.expectEqual(@as(usize, 4), syms.len);
    try testing.expectEqualStrings("Acme", syms[0].name);
    try testing.expectEqualStrings("Calc", syms[1].name);
    try testing.expectEqualStrings("Count", syms[2].name);
    try testing.expectEqualStrings("prop", syms[2].kind.label());
    try testing.expectEqualStrings("Add", syms[3].name);
    try testing.expectEqualStrings("method", syms[3].kind.label());
    const at = std.mem.indexOf(u8, text, "return a").?;
    const inner = s.objectRange(ed, .function, at, false).?;
    try testing.expectEqualStrings("\n        var s = \"sum\";\n        return a + b;\n    ", text[inner[0]..inner[1]]);
    const cls = s.objectRange(ed, .class, at, true).?;
    try testing.expect(std.mem.startsWith(u8, text[cls[0]..cls[1]], "public class Calc"));
    // Line 11 (`return`) sits under the class (line 4) and the method (line 8).
    try testing.expectEqualSlices(u32, &.{ 4, 8 }, try s.scopeChain(ed, arena.allocator(), 11));
    // A fold on the method's opening brace covers its block.
    ed.placeCursor(9, 4);
    const fold = @import("cmd_editor.zig").foldRangeAt(ed, .{}, 9).?;
    try testing.expectEqual(@as(usize, 9), fold[0]);
    try testing.expectEqual(@as(usize, 12), fold[1]);
}

test "spans follow the text through the edit log: shifted at once, reparsed on refresh" {
    const gpa = testing.allocator;
    const ed = try Editor.init(gpa, "fn a() {}\nfn b() {}\n");
    defer ed.deinit();
    var s = Syntax.init(gpa);
    defer s.deinit();
    s.setLanguage("/ws/x.rs", ed.bytes());
    try s.refresh(ed);
    // `hl.spansIn` reads what is kept and builds what is not; it never
    // parses, so what follows sees exactly what a frame would paint.
    const before = (try s.hl.spansIn(ed.bytes(), 0, ed.len())).len;
    try testing.expect(before >= 4);
    // Type a line at the top; the old spans slide down without a parse —
    // and typing at the window's first byte is typing inside it: the
    // window still covers the file, so nothing is rebuilt either.
    try ed.splice(0, 0, "fn z() {}\n");
    try testing.expect(!s.absorb(ed));
    try testing.expect(s.hl.stale);
    try testing.expect(s.hl.covers(0, ed.len()));
    const slid = try s.hl.spansIn(ed.bytes(), 0, ed.len());
    try testing.expectEqual(before, slid.len);
    try testing.expectEqual(@as(u32, 10), slid[0].start);
    // The reparse is incremental (the tree was told) and picks up `z`.
    try s.refresh(ed);
    try testing.expect(!s.hl.stale);
    const reparsed = try s.hl.spansIn(ed.bytes(), 0, ed.len());
    try testing.expect(reparsed.len > before);
    try testing.expectEqual(@as(u32, 0), reparsed[0].start);
    // A wholesale replacement is one more edit the tree is told about.
    try ed.setText("struct S;\n");
    try testing.expect(!s.absorb(ed));
    try testing.expect(s.hl.tree != null and s.hl.stale);
    try s.refresh(ed);
    try testing.expect((try s.hl.spansIn(ed.bytes(), 0, ed.len())).len > 0);
    // A log that lost track is reported, and takes the tree with it.
    try ed.splice(0, 0, "// c\n");
    ed.doc.edits.markLost();
    try testing.expect(s.absorb(ed));
    try testing.expect(s.hl.tree == null);
    try testing.expectEqual(@as(usize, 0), s.hl.keptSpanCount());
    try testing.expectEqual(@as(usize, 0), (try s.hl.spansIn(ed.bytes(), 0, ed.len())).len);
    try s.refresh(ed);
    try testing.expect((try s.hl.spansIn(ed.bytes(), 0, ed.len())).len > 0);
}

test "parseDue: a small file's first parse is at once, a large one's waits out the idle gate" {
    var s = Syntax.init(testing.allocator);
    defer s.deinit();
    // Never parsed: small runs now, large waits.
    try testing.expect(s.parseDue(0, sync_parse_max_bytes));
    try testing.expect(!s.parseDue(0, sync_parse_max_bytes + 1));
    s.since_ms = 1000;
    try testing.expect(!s.parseDue(1000 + idle_ms - 1, sync_parse_max_bytes + 1));
    try testing.expect(s.parseDue(1000 + idle_ms, sync_parse_max_bytes + 1));
    // Parsed once: every size waits.
    s.parsed_seq = 0;
    try testing.expect(!s.parseDue(1000, 10));
    try testing.expect(s.parseDue(1000 + idle_ms, 10));
    s.dirty = false;
    try testing.expect(!s.parseDue(1000 + idle_ms, 10));
}

test "the first frame after opening a 6000-line file paints without a parse; the parse lands on the idle gate" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 24 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/large.rs");
    e.syntax.setLanguage("/tmp/large.rs", "");
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..6000) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "fn f{d}(x: u32) -> u32 {{ let y = x + {d}; y }}\n", .{ i, i });
        defer testing.allocator.free(line);
        try text.appendSlice(testing.allocator, line);
    }
    try testing.expect(text.items.len > sync_parse_max_bytes);
    try e.buf.editor.setText(text.items);
    app.now_ms = 1000;
    try app.render();
    // Painted, but the tree is not there yet: the gate opened this frame.
    try testing.expect(e.syntax.parsed_seq == null);
    try testing.expect(e.syntax.hl.tree == null);
    try testing.expectEqual(@as(usize, 0), e.syntax.hl.keptSpanCount());
    try testing.expect(e.syntax.dirty);
    try testing.expectEqual(@as(?i64, 1000), e.syntax.since_ms);
    try testing.expectEqual(@as(?i64, 1000 + idle_ms), app.nextDeadlineMs());
    const plain = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "fn f0(x: u32)") != null);
    // A frame inside the window still waits; the one at the gate parses.
    app.now_ms = 1000 + idle_ms - 1;
    try app.render();
    try testing.expect(e.syntax.parsed_seq == null);
    app.now_ms = 1000 + idle_ms;
    try app.render();
    try testing.expect(e.syntax.parsed_seq != null);
    try testing.expect(!e.syntax.dirty);
    try testing.expect(e.syntax.since_ms == null);
    // The frame painted highlighted — and what it holds is a viewport's
    // worth, not the file's: the 24-row pane keeps some hundreds of spans
    // of a file that has more than six thousand.
    const kept = e.syntax.hl.keptSpanCount();
    try testing.expect(kept > 50);
    try testing.expect(kept < 3000);
    // The whole file is still there to be asked for, and answers in full.
    const ed_now = e.buf.editor;
    try testing.expect((try e.syntax.hl.spansIn(ed_now.bytes(), 0, ed_now.len())).len > 6000);
    try testing.expect(app.nextDeadlineMs() == null or app.nextDeadlineMs().? > 1000 + idle_ms);
    // A replacement is an edit like any other: the tree is told what
    // changed and the reparse waits out the idle gate.
    try e.buf.editor.setText("fn small() {}\n");
    e.syntax.dirty = true;
    try app.render();
    try testing.expect(e.syntax.dirty);
    app.now_ms += idle_ms;
    try app.render();
    try testing.expect(e.syntax.parsed_seq != null);
    try testing.expect(!e.syntax.dirty);
    try testing.expect(e.syntax.hl.keptSpanCount() >= 3);
}

test "structural queries refresh the tree themselves" {
    const gpa = testing.allocator;
    const ed = try Editor.init(gpa, "fn first() {\n    one;\n}\n");
    defer ed.deinit();
    var s = Syntax.init(gpa);
    defer s.deinit();
    s.setLanguage("/ws/fn.rs", ed.bytes());
    const r = s.objectRange(ed, .function, 17, false).?;
    try testing.expectEqualStrings("\n    one;\n", ed.bytes()[r[0]..r[1]]);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const syms = (try s.symbols(ed, arena.allocator())).?;
    try testing.expectEqual(@as(usize, 1), syms.len);
    try testing.expectEqualStrings("first", syms[0].name);
    try testing.expectEqualSlices(u32, &.{0}, try s.scopeChain(ed, arena.allocator(), 1));
    // An edit, then the same query: the answer tracks the text.
    try ed.splice(0, 0, "\n");
    const r2 = s.objectRange(ed, .function, 18, false).?;
    try testing.expectEqualStrings("\n    one;\n", ed.bytes()[r2[0]..r2[1]]);
    var plain = Syntax.init(gpa);
    defer plain.deinit();
    plain.setLanguage("/ws/notes.txt", "");
    try testing.expect(plain.objectRange(ed, .function, 0, false) == null);
    try testing.expect((try plain.symbols(ed, arena.allocator())) == null);
}

// ── the size limit (`editor.highlight_max_bytes`) ──

/// An App on `tmp` with `limit` as the ceiling.
fn limitApp(tmp: *std.testing.TmpDir, buf: []u8, limit: u64) !App {
    const n = try tmp.dir.realPath(testing.io, buf);
    var cfg: @import("../config/root.zig").Config = .{};
    cfg.editor.highlight_max_bytes = limit;
    var app = try App.initWith(testing.allocator, testing.io, .{ .cfg = cfg, .workspace = buf[0..n], .data_root = buf[0..n], .cols = 120, .rows = 40 });
    app.tree.visible = false;
    return app;
}

/// Exactly `bytes` of plausible Rust, written to `tmp` as `name` — the
/// size is exact so the chip's and the toast's labels are too.
fn writeRust(tmp: *std.testing.TmpDir, name: []const u8, bytes: usize) !void {
    const unit = "pub fn one(x: u32) -> u32 {\n    let y: u32 = x + 1;\n    y\n}\n";
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.ensureTotalCapacity(testing.allocator, bytes + unit.len);
    while (text.items.len < bytes) text.appendSliceAssumeCapacity(unit);
    text.shrinkRetainingCapacity(bytes);
    if (bytes > 0) text.items[bytes - 1] = '\n';
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = text.items });
}

fn openIn(app: *App, tmp: *std.testing.TmpDir, root: []const u8, name: []const u8) !*app_mod.EditorPane {
    _ = tmp;
    const p = try std.fs.path.join(testing.allocator, &.{ root, name });
    defer testing.allocator.free(p);
    _ = try app.openEditor(p);
    return app.activeEditor().?;
}

test "a file over editor.highlight_max_bytes opens with no tree-sitter at all, and never quietly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try limitApp(&tmp, &buf, 4 * 1024 * 1024);
    defer app.deinit();
    const root = app.workspace;
    try writeRust(&tmp, "big.rs", 5 * 1024 * 1024);
    const e = try openIn(&app, &tmp, root, "big.rs");
    // The grammar is known — and deliberately not in force.
    try testing.expect(e.syntax.lang != null);
    try testing.expect(e.syntax.off);
    try testing.expect(e.syntax.over_limit);
    try testing.expect(!e.syntax.hasLanguage());
    try app.render();
    // No job was ever handed to a worker, and there is no tree to read.
    try testing.expectEqual(@as(u64, 0), app.syntax_jobs.started);
    try testing.expect(e.syntax.pending == null);
    try testing.expect(e.syntax.hl.tree == null);
    try testing.expect(e.syntax.keptRoot() == null);
    try testing.expectEqual(@as(usize, 0), e.syntax.hl.keptSpanCount());
    const ed = e.buf.editor;
    try testing.expectEqual(@as(usize, 0), try e.syntax.countIn(ed, 0, ed.len()));
    // Everything a tree would have answered falls back to its no-tree path.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(e.syntax.objectRange(ed, .function, 40, false) == null);
    try testing.expect((try e.syntax.symbols(ed, arena.allocator())) == null);
    try testing.expectEqual(@as(usize, 0), (try e.syntax.scopeChain(ed, arena.allocator(), 4)).len);
    // The toast said so, by name and by size.
    const msg = app.toasts.items[app.toasts.items.len - 1].text;
    try testing.expect(std.mem.indexOf(u8, msg, "highlighting off for big.rs") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "(5 MB > 4 MB)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "editor.highlight_this_file") != null);
    // And the chip is asked for.
    try testing.expect(e.syntax.showsChip());
    // Editing still works — the buffer is a buffer.
    try ed.splice(0, 0, "// still editable\n");
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "// still editable"));
}

test "limit 0 is no limit: the same file keeps its grammar however large" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try limitApp(&tmp, &buf, 0);
    defer app.deinit();
    const root = app.workspace;
    try writeRust(&tmp, "big.rs", 5 * 1024 * 1024);
    const e = try openIn(&app, &tmp, root, "big.rs");
    try testing.expect(!e.syntax.off);
    try testing.expect(!e.syntax.over_limit);
    try testing.expect(!e.syntax.showsChip());
    try testing.expect(e.syntax.hasLanguage());
    try testing.expectEqualStrings("rs", e.syntax.key().?);
}

// The value people actually run with. A test that only brackets the
// default — 4 KB on one side, 64 MB on the other — would pass with the
// ceiling set to anything at all; this one boots the App on `Config{}`
// and opens a file on either side of the shipped number.
test "the shipped default is 4 MiB: a 5 MB source opens unhighlighted, a 3 MB one does not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = buf[0..n], .data_root = buf[0..n], .cols = 120, .rows = 40 });
    defer app.deinit();
    app.tree.visible = false;
    try testing.expectEqual(@as(u64, 4 << 20), app.cfg.editor.highlight_max_bytes);
    const root = app.workspace;

    try writeRust(&tmp, "over.rs", 5 * 1024 * 1024);
    const over = try openIn(&app, &tmp, root, "over.rs");
    try testing.expect(over.syntax.over_limit and over.syntax.off);
    try testing.expect(!over.syntax.hasLanguage());
    try testing.expect(over.syntax.showsChip());
    // And it said so, by name and by both sizes.
    const msg = app.toasts.items[app.toasts.items.len - 1].text;
    try testing.expect(std.mem.indexOf(u8, msg, "highlighting off for over.rs") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "(5 MB > 4 MB)") != null);

    try writeRust(&tmp, "under.rs", 3 * 1024 * 1024);
    const under = try openIn(&app, &tmp, root, "under.rs");
    try testing.expect(!under.syntax.over_limit and !under.syntax.off);
    try testing.expect(under.syntax.hasLanguage());
    try testing.expect(!under.syntax.showsChip());
}

test "editor.highlight_this_file parses the file the limit skipped; a second run says it is already on" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // A limit small enough that a quick file trips it: the switch is the
    // same one a 5 MB file gets, and the parse costs a millisecond.
    var app = try limitApp(&tmp, &buf, 1024);
    defer app.deinit();
    const root = app.workspace;
    try writeRust(&tmp, "mid.rs", 8 * 1024);
    const e = try openIn(&app, &tmp, root, "mid.rs");
    try testing.expect(e.syntax.off and e.syntax.over_limit);
    const ed = e.buf.editor;
    try testing.expectEqual(@as(usize, 0), try e.syntax.countIn(ed, 0, ed.len()));
    try command.run(&app, .{ .static = .@"editor.highlight_this_file" });
    try testing.expect(!e.syntax.off);
    // Still over the limit — so the chip stays, now reading `on`.
    try testing.expect(e.syntax.over_limit and e.syntax.showsChip());
    try app.render();
    try testing.expect(e.syntax.hl.tree != null);
    try testing.expect((try e.syntax.countIn(ed, 0, ed.len())) > 10);
    const on_msg = app.toasts.items[app.toasts.items.len - 1].text;
    try testing.expect(std.mem.indexOf(u8, on_msg, "highlighting on for mid.rs") != null);
    // Asking again changes nothing and says why.
    try command.run(&app, .{ .static = .@"editor.highlight_this_file" });
    try testing.expect(!e.syntax.off);
    try testing.expect(std.mem.indexOf(u8, app.toasts.items[app.toasts.items.len - 1].text, "already on") != null);
}

test "editor.highlight_toggle_file switches any buffer: a small file loses its tree and gets it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var app = try limitApp(&tmp, &buf, 0);
    defer app.deinit();
    const root = app.workspace;
    try writeRust(&tmp, "small.rs", 2 * 1024);
    const e = try openIn(&app, &tmp, root, "small.rs");
    const ed = e.buf.editor;
    try app.render();
    const spans = try e.syntax.countIn(ed, 0, ed.len());
    try testing.expect(spans > 10);
    try testing.expect(!e.syntax.showsChip());
    // Off: the tree and the spans go, and the chip appears without a limit.
    try command.run(&app, .{ .static = .@"editor.highlight_toggle_file" });
    try testing.expect(e.syntax.off and !e.syntax.over_limit and e.syntax.showsChip());
    try testing.expect(e.syntax.hl.tree == null);
    try app.render();
    try testing.expect(e.syntax.hl.tree == null);
    try testing.expectEqual(@as(usize, 0), try e.syntax.countIn(ed, 0, ed.len()));
    try testing.expect(std.mem.indexOf(u8, app.toasts.items[app.toasts.items.len - 1].text, "highlighting off for small.rs") != null);
    // On again: the next frame parses and the chip goes.
    try command.run(&app, .{ .static = .@"editor.highlight_toggle_file" });
    try testing.expect(!e.syntax.off and !e.syntax.showsChip());
    try app.render();
    try testing.expectEqual(spans, try e.syntax.countIn(ed, 0, ed.len()));
}
