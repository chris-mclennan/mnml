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
const table = highlight.table;
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

/// Table key for a file, or null when mnml-zig has no grammar for it.
/// `text` supplies the shebang for extension-less scripts.
pub fn keyFor(path: ?[]const u8, text: []const u8) ?[]const u8 {
    if (path) |p| {
        const base = std.fs.path.basename(p);
        if (table.keyForFilename(base)) |k| return k;
        const ext = std.fs.path.extension(base);
        if (ext.len > 1 and ext.len - 1 <= 32) {
            var lower: [32]u8 = undefined;
            const e = std.ascii.lowerString(&lower, ext[1..]);
            if (table.keyForExtension(e)) |k| return k;
            if (table.find(e)) |i| return table.entries[i].key;
        }
    }
    return keyForShebang(text);
}

/// `#!/usr/bin/env python3` → `py`, and the other interpreters a
/// script file names.
pub fn keyForShebang(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, "#!")) return null;
    const nl = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = text[2..nl];
    const interpreters = [_]struct { []const u8, []const u8 }{
        .{ "python", "py" }, .{ "node", "js" }, .{ "deno", "ts" },   .{ "bash", "sh" },
        .{ "zsh", "sh" },    .{ "fish", "sh" }, .{ "sh", "sh" },     .{ "ruby", "rb" },
        .{ "lua", "lua" },   .{ "php", "php" }, .{ "elixir", "ex" }, .{ "swift", "swift" },
    };
    // The interpreter is the last path segment of the first word, or the
    // word after `env`.
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var word = it.next() orelse return null;
    if (std.mem.endsWith(u8, word, "/env")) word = it.next() orelse return null;
    const name = std.fs.path.basename(word);
    for (interpreters) |i| if (std.mem.startsWith(u8, name, i[0])) return i[1];
    return null;
}

/// Kept for callers that only have a path (the outline's fallback).
pub fn keyForPath(path: []const u8) ?[]const u8 {
    return keyFor(path, "");
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

    pub fn init(gpa: Allocator) Syntax {
        return .{ .hl = highlight.Highlighter.init(gpa) };
    }

    pub fn deinit(self: *Syntax) void {
        self.hl.deinit();
    }

    /// Pick the grammar for `path` (+ `text` for a shebang). A file with
    /// no grammar has no spans and stays that way until a rename.
    pub fn setLanguage(self: *Syntax, path: ?[]const u8, text: []const u8) void {
        const key_name = keyFor(path, text);
        const idx = if (key_name) |k| table.find(k) else null;
        if (idx != self.hl.root) self.parsed_seq = null;
        self.hl.setLanguage(idx);
    }

    pub fn hasLanguage(self: *const Syntax) bool {
        return self.hl.hasLanguage();
    }

    /// The table key of the grammar in use (`rs`, `tsx`), or null.
    pub fn key(self: *const Syntax) ?[]const u8 {
        const i = self.hl.root orelse return null;
        return table.entries[i].key;
    }

    /// Fold the editor's edits since the last call into the tree and the
    /// cached spans. Returns true when the log was lost and only a full
    /// reparse can catch up.
    pub fn absorb(self: *Syntax, ed: *const Editor) bool {
        if (ed.doc.edits.lostSince(self.seen_seq)) {
            self.hl.invalidate();
            self.hl.spans.clearRetainingCapacity();
            self.seen_seq = ed.doc.edits.head();
            self.parsed_seq = null;
            return true;
        }
        for (ed.doc.edits.since(self.seen_seq)) |sp| {
            self.hl.edit(.{
                .start_byte = @intCast(sp.start),
                .old_end_byte = @intCast(sp.old_end),
                .new_end_byte = @intCast(sp.new_end),
                .start_point = .{ .row = sp.start_pt.row, .column = sp.start_pt.col },
                .old_end_point = .{ .row = sp.old_end_pt.row, .column = sp.old_end_pt.col },
                .new_end_point = .{ .row = sp.new_end_pt.row, .column = sp.new_end_pt.col },
            });
            self.hl.shiftSpans(sp.start, sp.old_end, sp.new_end);
        }
        self.seen_seq = ed.doc.edits.head();
        return false;
    }

    /// Reparse now (incrementally when the tree is current).
    pub fn refresh(self: *Syntax, ed: *const Editor) Allocator.Error!void {
        _ = self.absorb(ed);
        try self.hl.refresh(ed.bytes());
        self.parsed_seq = self.seen_seq;
    }

    /// Make the tree current for a structural query, whatever the timer
    /// says. Null when there is no grammar.
    fn fresh(self: *Syntax, ed: *const Editor) ?ts.Node {
        if (!self.hl.hasLanguage()) return null;
        _ = self.absorb(ed);
        if (self.parsed_seq == null or self.parsed_seq.? != self.seen_seq or self.hl.tree == null) {
            self.refresh(ed) catch return null;
        }
        return self.hl.rootNode();
    }

    /// Spans for the editor view, restricted to `[lo, hi)` bytes and
    /// styled by `theme`. Built on `arena`.
    pub fn styledSpans(self: *const Syntax, arena: Allocator, theme: *const Theme, lo: usize, hi: usize) Allocator.Error![]Span {
        const src = self.hl.spansIn(lo, hi);
        const out = try arena.alloc(Span, src.len);
        for (src, 0..) |s, i| out[i] = .{ .start = s.start, .end = s.end, .style = theme.roleStyle(s.role) };
        return out;
    }

    /// How many spans touch `[lo, hi)` — the driver's `highlightCount`.
    pub fn countIn(self: *const Syntax, lo: usize, hi: usize) usize {
        return self.hl.spansIn(lo, hi).len;
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
        const l = @min(line, @as(u32, @intCast(ed.lineCount() - 1)));
        const at: u32 = @intCast(ed.lineStart(l));
        return structure.scopeChain(arena, root, at, line);
    }

    /// Every definition in the file, for the outline. Null when the file
    /// has no grammar (the caller falls back to line patterns).
    pub fn symbols(self: *Syntax, ed: *const Editor, arena: Allocator) Allocator.Error!?[]Symbol {
        const root = self.fresh(ed) orelse return null;
        return try structure.symbols(arena, root, ed.bytes());
    }
};

// ── tests ──

const testing = std.testing;

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
    try testing.expect(s.hl.spans.items.len >= 12);
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
    const fold = @import("cmd_editor.zig").foldRangeAt(ed, 9).?;
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
    const before = s.hl.spans.items.len;
    try testing.expect(before >= 4);
    // Type a line at the top; the old spans slide down without a parse.
    try ed.splice(0, 0, "fn z() {}\n");
    try testing.expect(!s.absorb(ed));
    try testing.expectEqual(before, s.hl.spans.items.len);
    try testing.expectEqual(@as(u32, 10), s.hl.spans.items[0].start);
    // The reparse is incremental (the tree was told) and picks up `z`.
    try s.refresh(ed);
    try testing.expect(s.hl.spans.items.len > before);
    try testing.expectEqual(@as(u32, 0), s.hl.spans.items[0].start);
    // A wholesale replacement is reported as lost.
    try ed.setText("struct S;\n");
    try testing.expect(s.absorb(ed));
    try testing.expectEqual(@as(usize, 0), s.hl.spans.items.len);
    try s.refresh(ed);
    try testing.expect(s.hl.spans.items.len > 0);
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
