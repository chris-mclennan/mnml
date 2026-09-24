//! `ai.apply` as a reviewed diff (`Pane.ai_apply`). The answer's first
//! fenced code block is a *proposal* for the range the action was run
//! on (the selection, else the whole buffer): this pane shows it as a
//! unified diff against what the editor holds now, one hunk at a time,
//! each hunk accepted or skipped on its own. Enter applies the accepted
//! hunks through one `EditOp.replace_range`, so undo is one step and
//! the editor's own undo ring owns the change.
//!
//! The diff is a line diff — common prefix and suffix trimmed, then an
//! LCS over the middle; a middle too large to table falls back to one
//! hunk replacing it whole (still correct, just coarse). Hunks carry
//! three lines of context and merge when closer than that.
//!
//!   D1  everything the pane holds lives on its own arena; the proposal
//!       and the original text are copied in at open time so a later
//!       edit to the editor (or the answer streaming on) cannot move
//!       them under the diff;
//!   D6  the view (`ui/ai_apply_view.zig`) paints from `rows` and
//!       registers one `.script_hit{ pane, id = row }` per row — a
//!       click on a hunk header toggles it.
//!
//! The range is an `Anchor`: taken when the job starts, followed along
//! the document's edit log (`follow`, run before every trim of the log)
//! so an edit above or below it moves it and an edit inside it marks it
//! `lost`. A lost anchor is written only if the text at its last known
//! place is still exactly what the review diffed; otherwise the apply
//! is refused. A stale byte range is never written.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const key_mod = @import("../core/key.zig");
const Mouse = key_mod.Mouse;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const document = @import("../editor/document.zig");

/// A range of one editor's text, kept current across edits made after
/// it was taken. `doc` is compared, never dereferenced: a pane that has
/// since opened another file no longer holds the text this was about.
pub const Anchor = struct {
    pane: PaneId,
    doc: *const anyopaque,
    /// The edit-log seq `start` / `end` are current at.
    seen: u64,
    start: usize,
    end: usize,
    /// The log could not carry the range: an edit landed inside it, the
    /// text was replaced wholesale (an undo, a reload), or the records
    /// were trimmed before they were followed. `start` / `end` are then
    /// where the range last was.
    lost: bool = false,

    /// The range `start..end` of the editor in `pane`, as its text is now.
    pub fn take(pane: PaneId, doc: *const document.Document, start: usize, end: usize) Anchor {
        return .{ .pane = pane, .doc = doc, .seen = doc.edits.head(), .start = start, .end = end };
    }

    /// Move the range across every edit `doc` logged since `seen`. An
    /// insertion exactly at `start` goes before the range and one exactly
    /// at `end` after it; anything that touches the inside loses it.
    pub fn follow(a: *Anchor, doc: *const document.Document) void {
        if (a.lost or a.doc != @as(*const anyopaque, doc)) return;
        const log = &doc.edits;
        const head = log.head();
        if (a.seen == head) return;
        const recs = log.since(a.seen);
        if (log.replacedSince(a.seen) or recs.len != head - a.seen) {
            a.lost = true;
            return;
        }
        for (recs) |sp| {
            if (sp.old_end <= a.start) {
                // Wholly before (an insertion at `start` included).
                a.start = a.start - sp.old_end + sp.new_end;
                a.end = a.end - sp.old_end + sp.new_end;
            } else if (sp.start >= a.end) {
                // Wholly after (an insertion at `end` included).
            } else {
                a.lost = true;
                return;
            }
        }
        a.seen = head;
    }
};

/// Every anchor on `doc` — the AI panes' targets and the open reviews —
/// moved across the log's records before they are trimmed away.
pub fn followAll(app: *App, doc: *const document.Document) void {
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .ai => |*a| if (a.apply) |*an| an.follow(doc),
        .ai_apply => |*ap| ap.anchor.follow(doc),
        else => {},
    };
}

/// Where `anchor`'s text is now, if it still reads `expect`: the
/// followed range, or — for a lost anchor — its last known place when
/// the bytes there are exactly `expect`. Null means the text the review
/// was built for is gone and nothing may be written.
fn locate(app: *App, anchor: *Anchor, expect: ?[]const u8) ?[2]usize {
    const e = app.panes.editor(anchor.pane) orelse return null;
    if (@as(*const anyopaque, e.buf.doc) != anchor.doc) return null;
    anchor.follow(e.buf.doc);
    const bytes = e.buf.editor.bytes();
    if (anchor.start > anchor.end or anchor.end > bytes.len) return null;
    const now = bytes[anchor.start..anchor.end];
    if (expect) |want| {
        if (!std.mem.eql(u8, now, want)) return null;
    } else if (anchor.lost) return null;
    return .{ anchor.start, anchor.end };
}

/// A run of the edit script, in line indices of the old and new texts.
pub const Hunk = struct {
    old_start: u32,
    old_len: u32,
    new_start: u32,
    new_len: u32,
    accepted: bool = true,

    /// `@@ -a,b +c,d @@` with 1-based starts, as git prints them.
    pub fn header(h: Hunk, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "@@ -{d},{d} +{d},{d} @@", .{ h.old_start + 1, h.old_len, h.new_start + 1, h.new_len });
    }
};

/// A line of a hunk, by its line index on the side it comes from.
pub const RowLine = struct { hunk: u32, line: u32 };

/// One painted row.
pub const Row = union(enum) {
    header: u32,
    /// `line` indexes `old_lines`.
    ctx: RowLine,
    del: RowLine,
    /// `line` indexes `new_lines`.
    add: RowLine,

    pub fn hunkOf(r: Row) u32 {
        return switch (r) {
            .header => |h| h,
            .ctx, .del, .add => |l| l.hunk,
        };
    }
};

pub const context_lines: u32 = 3;

pub const AiApplyPane = struct {
    arena: std.heap.ArenaAllocator,
    /// The editor the proposal is for, and the range it replaces — kept
    /// current as the editor is edited behind the review.
    anchor: Anchor,
    /// The text the review diffed (`old_lines`, joined), on the arena:
    /// what the anchor must still read for the apply to go ahead.
    old_text: []const u8,
    /// The AI pane the proposal came from; its `apply` target is
    /// updated after a successful apply.
    source: ?PaneId,
    /// The file name for the header (workspace-relative, on the arena).
    file: []const u8,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    /// Whether the proposal ended in a newline — the result keeps it.
    hunks: []Hunk,
    rows: []const Row,
    /// The focused hunk.
    cursor: usize = 0,
    scroll: usize = 0,

    pub fn deinit(self: *AiApplyPane) void {
        self.arena.deinit();
    }

    pub fn accepted(self: *const AiApplyPane) usize {
        var n: usize = 0;
        for (self.hunks) |h| n += @intFromBool(h.accepted);
        return n;
    }

    /// The row the focused hunk's header is on.
    pub fn cursorRow(self: *const AiApplyPane) usize {
        for (self.rows, 0..) |r, i| if (r == .header and r.header == self.cursor) return i;
        return 0;
    }

    /// What the target range becomes: the new lines of every accepted
    /// hunk, the old lines of every skipped one, the context as is.
    pub fn result(self: *const AiApplyPane, arena: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var old_i: usize = 0;
        for (self.hunks) |h| {
            while (old_i < h.old_start) : (old_i += 1) try appendLine(&out, arena, self.old_lines[old_i]);
            if (h.accepted) {
                for (self.new_lines[h.new_start .. h.new_start + h.new_len]) |l| try appendLine(&out, arena, l);
            } else {
                for (self.old_lines[h.old_start .. h.old_start + h.old_len]) |l| try appendLine(&out, arena, l);
            }
            old_i = h.old_start + h.old_len;
        }
        while (old_i < self.old_lines.len) : (old_i += 1) try appendLine(&out, arena, self.old_lines[old_i]);
        return out.toOwnedSlice(arena);
    }
};

/// A line is stored without its `\n`; the last line of a text that
/// ended without one is marked by the `no_eol` sentinel slice so the
/// result reproduces it byte for byte.
fn appendLine(out: *std.ArrayListUnmanaged(u8), arena: Allocator, line: []const u8) Allocator.Error!void {
    if (line.ptr == no_eol_marker.ptr) {
        // The line before it had no newline: take the one just written back.
        if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
        return;
    }
    try out.appendSlice(arena, line);
    try out.append(arena, '\n');
}

/// Present as the last "line" of a text that does not end in `\n` —
/// it diffs as a line (so a trailing-newline change shows), and
/// `result` writes nothing for it. Identity, not content, marks it.
const no_eol_marker: []const u8 = "\x00no-eol";

/// Split into lines without their terminators; a missing final
/// newline adds the `no_eol_marker` line. Empty text is zero lines.
pub fn splitLines(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (text.len == 0) return out.toOwnedSlice(arena);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(arena, line);
    // A text ending in `\n` yields a trailing empty piece: that is the
    // end, not a line. One that does not is missing its newline.
    if (text[text.len - 1] == '\n') {
        _ = out.pop();
    } else {
        try out.append(arena, no_eol_marker);
    }
    return out.toOwnedSlice(arena);
}

pub const Op = enum { eq, del, add };

/// The largest middle the LCS table is built for; past it the middle
/// is one replacement.
pub const max_table_cells: usize = 4 * 1024 * 1024;

/// The edit script old → new, as one op per line of either side.
pub fn editScript(arena: Allocator, old: []const []const u8, new: []const []const u8) Allocator.Error![]Op {
    var ops: std.ArrayListUnmanaged(Op) = .empty;
    var pre: usize = 0;
    while (pre < old.len and pre < new.len and lineEql(old[pre], new[pre])) : (pre += 1) {}
    var suf: usize = 0;
    while (suf < old.len - pre and suf < new.len - pre and lineEql(old[old.len - 1 - suf], new[new.len - 1 - suf])) : (suf += 1) {}
    try ops.appendNTimes(arena, .eq, pre);
    const a = old[pre .. old.len - suf];
    const b = new[pre .. new.len - suf];
    if (a.len == 0 or b.len == 0 or a.len * b.len > max_table_cells) {
        try ops.appendNTimes(arena, .del, a.len);
        try ops.appendNTimes(arena, .add, b.len);
    } else {
        // LCS lengths, (a.len + 1) × (b.len + 1), walked back from the end.
        const w = b.len + 1;
        const table = try arena.alloc(u32, (a.len + 1) * w);
        @memset(table, 0);
        var i: usize = a.len;
        while (i > 0) : (i -= 1) {
            var j: usize = b.len;
            while (j > 0) : (j -= 1) {
                table[(i - 1) * w + (j - 1)] = if (lineEql(a[i - 1], b[j - 1]))
                    table[i * w + j] + 1
                else
                    @max(table[i * w + (j - 1)], table[(i - 1) * w + j]);
            }
        }
        var x: usize = 0;
        var y: usize = 0;
        while (x < a.len or y < b.len) {
            if (x < a.len and y < b.len and lineEql(a[x], b[y])) {
                try ops.append(arena, .eq);
                x += 1;
                y += 1;
            } else if (x < a.len and (y == b.len or table[(x + 1) * w + y] >= table[x * w + (y + 1)])) {
                // Deletions before insertions, as `git diff` orders a hunk.
                try ops.append(arena, .del);
                x += 1;
            } else {
                try ops.append(arena, .add);
                y += 1;
            }
        }
    }
    try ops.appendNTimes(arena, .eq, suf);
    return ops.toOwnedSlice(arena);
}

fn lineEql(a: []const u8, b: []const u8) bool {
    if (a.ptr == no_eol_marker.ptr or b.ptr == no_eol_marker.ptr) return a.ptr == b.ptr;
    return std.mem.eql(u8, a, b);
}

/// Group the script's changed runs into hunks with `context_lines`
/// of context on each side, merging runs that are closer than twice
/// that. A hunk's `*_start` / `*_len` cover its context too.
pub fn hunksOf(arena: Allocator, ops: []const Op, old_len: usize, new_len: usize) Allocator.Error![]Hunk {
    var out: std.ArrayListUnmanaged(Hunk) = .empty;
    // Every change as (old line, new line) positions of its first and last op.
    const Run = struct { o0: u32, n0: u32, o1: u32, n1: u32 };
    var runs: std.ArrayListUnmanaged(Run) = .empty;
    var o: u32 = 0;
    var n: u32 = 0;
    var cur: ?Run = null;
    for (ops) |op| {
        switch (op) {
            .eq => {
                if (cur) |r| {
                    try runs.append(arena, r);
                    cur = null;
                }
                o += 1;
                n += 1;
            },
            .del => {
                if (cur == null) cur = .{ .o0 = o, .n0 = n, .o1 = o, .n1 = n };
                o += 1;
                cur.?.o1 = o;
                cur.?.n1 = n;
            },
            .add => {
                if (cur == null) cur = .{ .o0 = o, .n0 = n, .o1 = o, .n1 = n };
                n += 1;
                cur.?.o1 = o;
                cur.?.n1 = n;
            },
        }
    }
    if (cur) |r| try runs.append(arena, r);
    const olen: u32 = @intCast(old_len);
    const nlen: u32 = @intCast(new_len);
    var i: usize = 0;
    while (i < runs.items.len) {
        var r = runs.items[i];
        // Merge while the next run's context would overlap this one's.
        while (i + 1 < runs.items.len and runs.items[i + 1].o0 <= r.o1 + 2 * context_lines) : (i += 1) {
            r.o1 = runs.items[i + 1].o1;
            r.n1 = runs.items[i + 1].n1;
        }
        i += 1;
        const before = @min(context_lines, r.o0);
        const after = @min(context_lines, olen - r.o1);
        try out.append(arena, .{
            .old_start = r.o0 - before,
            .old_len = (r.o1 - r.o0) + before + after,
            .new_start = r.n0 - before,
            .new_len = (r.n1 - r.n0) + before + after,
        });
        std.debug.assert(r.n1 + after <= nlen);
    }
    return out.toOwnedSlice(arena);
}

/// The rows: per hunk its header, then its lines in script order.
fn rowsOf(arena: Allocator, ops: []const Op, hunks: []const Hunk) Allocator.Error![]const Row {
    var out: std.ArrayListUnmanaged(Row) = .empty;
    // Walk the script once, emitting rows while inside a hunk's old range.
    var o: u32 = 0;
    var n: u32 = 0;
    var hi: usize = 0;
    var op_i: usize = 0;
    while (hi < hunks.len) : (hi += 1) {
        const h = hunks[hi];
        try out.append(arena, .{ .header = @intCast(hi) });
        // Advance to the hunk's first line.
        while (o < h.old_start and op_i < ops.len) : (op_i += 1) switch (ops[op_i]) {
            .eq => {
                o += 1;
                n += 1;
            },
            .del => o += 1,
            .add => n += 1,
        };
        const end_o = h.old_start + h.old_len;
        const end_n = h.new_start + h.new_len;
        while (op_i < ops.len and (o < end_o or n < end_n)) : (op_i += 1) {
            switch (ops[op_i]) {
                .eq => {
                    try out.append(arena, .{ .ctx = .{ .hunk = @intCast(hi), .line = o } });
                    o += 1;
                    n += 1;
                },
                .del => {
                    try out.append(arena, .{ .del = .{ .hunk = @intCast(hi), .line = o } });
                    o += 1;
                },
                .add => {
                    try out.append(arena, .{ .add = .{ .hunk = @intCast(hi), .line = n } });
                    n += 1;
                },
            }
        }
    }
    return out.toOwnedSlice(arena);
}

/// Build the pane for `old` → `new`. Everything is copied onto the
/// pane's arena.
pub fn build(gpa: Allocator, anchor: Anchor, source: ?PaneId, file: []const u8, old: []const u8, new: []const u8) Allocator.Error!AiApplyPane {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const old_copy = try a.dupe(u8, old);
    const new_copy = try a.dupe(u8, new);
    const old_lines = try splitLines(a, old_copy);
    const new_lines = try splitLines(a, new_copy);
    const ops = try editScript(a, old_lines, new_lines);
    const hunks = try hunksOf(a, ops, old_lines.len, new_lines.len);
    const rows = try rowsOf(a, ops, hunks);
    return .{
        .arena = arena,
        .anchor = anchor,
        .old_text = old_copy,
        .source = source,
        .file = try a.dupe(u8, file),
        .old_lines = old_lines,
        .new_lines = new_lines,
        .hunks = hunks,
        .rows = rows,
    };
}

/// The text a row paints (the marker line paints as nothing).
pub fn lineText(p: *const AiApplyPane, row: Row) []const u8 {
    const l: []const u8 = switch (row) {
        .header => "",
        .ctx, .del => |r| p.old_lines[r.line],
        .add => |r| p.new_lines[r.line],
    };
    return if (l.ptr == no_eol_marker.ptr) "\\ No newline at end of file" else l;
}

// ─── the command ────────────────────────────────────────────────────────

/// The refusal when the text a proposal was made for has changed.
pub const changed_msg = "the text changed since the AI was asked — re-ask (r) for a fresh proposal";

/// `ai.apply` from an AI pane: open (or refresh) the review pane for
/// its first code block against the text the action was run on, as it
/// stands now. `original` is that text as the job saw it, when known:
/// an anchor the log lost is still good if its bytes read the same.
pub fn open(app: *App, source: PaneId, target_in: Anchor, original: ?[]const u8, code: []const u8) CommandError!PaneId {
    var target = target_in;
    const e = app.panes.editor(target.pane) orelse return app.diag.fail(app.frame.allocator(), "the editor is gone", .{});
    const range = locate(app, &target, if (target.lost) original else null) orelse
        return app.diag.fail(app.frame.allocator(), "{s}", .{changed_msg});
    const s = range[0];
    const en = range[1];
    const file: []const u8 = if (e.buf.doc.path) |p| app.relPath(p) else "[scratch]";
    // One review per source: a second `a` replaces it.
    var existing: ?PaneId = null;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .ai_apply => |*ap| if (ap.source != null and ap.source.? == source) {
            existing = @intCast(i);
        },
        else => {},
    };
    if (existing) |id| try app.forceClosePane(id);
    // Re-taken at the current seq: the review diffs the text as it is.
    const pane = try build(app.gpa, Anchor.take(target.pane, e.buf.doc, s, en), source, file, e.buf.editor.bytes()[s..en], code);
    const id = try app.panes.add(.{ .ai_apply = pane });
    app.showPane(id);
    return id;
}

/// Enter: splice the accepted hunks in as one edit, then close.
pub fn apply(app: *App, id: PaneId, p: *AiApplyPane) CommandError!void {
    const arena = app.frame.allocator();
    const e = app.panes.editor(p.anchor.pane) orelse return app.diag.fail(arena, "the editor is gone", .{});
    const n = p.accepted();
    const total = p.hunks.len;
    const target = p.anchor.pane;
    const source = p.source;
    if (n == 0) {
        try app.forceClosePane(id);
        app.toast("nothing accepted — no change", .{});
        app.showPane(target);
        return;
    }
    // Where the reviewed text is now; refused when it is not there to
    // replace. The review stays open so the user can see what was asked.
    const range = locate(app, &p.anchor, p.old_text) orelse return app.diag.fail(arena, "{s}", .{changed_msg});
    const text = try p.result(arena);
    try app.splice(e, range[0], range[1], text);
    if (source) |src| if (app.panes.get(src)) |sp| switch (sp.*) {
        .ai => |*ap| ap.apply = Anchor.take(target, e.buf.doc, range[0], range[0] + text.len),
        else => {},
    };
    try app.forceClosePane(id);
    app.showPane(target);
    app.toast("applied {d} of {d} hunk{s}", .{ n, total, if (total == 1) "" else "s" });
}

pub fn handleKey(app: *App, id: PaneId, p: *AiApplyPane, k: Key) Allocator.Error!bool {
    app.needs_render = true;
    const last = p.hunks.len -| 1;
    switch (k.code) {
        .down => p.cursor = @min(p.cursor + 1, last),
        .up => p.cursor -|= 1,
        .home => p.cursor = 0,
        .end => p.cursor = last,
        .enter => runToast(app, apply(app, id, p)),
        .esc => try cancel(app, id, p),
        .char => |c| {
            if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
            switch (c) {
                ' ' => toggle(p, p.cursor),
                'j', 'n' => p.cursor = @min(p.cursor + 1, last),
                'k', 'p' => p.cursor -|= 1,
                'g' => p.cursor = 0,
                'G' => p.cursor = last,
                'a', 't' => toggle(p, p.cursor),
                'A' => for (p.hunks) |*h| {
                    h.accepted = true;
                },
                'R', 'x' => for (p.hunks) |*h| {
                    h.accepted = false;
                },
                'y' => runToast(app, apply(app, id, p)),
                'q' => try cancel(app, id, p),
                else => return false,
            }
        },
        else => return false,
    }
    return true;
}

fn toggle(p: *AiApplyPane, hunk: usize) void {
    if (hunk < p.hunks.len) p.hunks[hunk].accepted = !p.hunks[hunk].accepted;
}

fn cancel(app: *App, id: PaneId, p: *AiApplyPane) Allocator.Error!void {
    const back = p.source orelse p.anchor.pane;
    try app.forceClosePane(id);
    if (app.panes.get(back) != null) app.showPane(back);
}

fn runToast(app: *App, result: CommandError!void) void {
    result catch |err| {
        if (err == error.Canceled) return;
        if (app.diag.msg) |m| app.toast("{s}", .{m}) else app.toast("ai.apply: {s}", .{@errorName(err)});
        app.diag.clear();
    };
}

/// A click on row `row`: a header toggles its hunk (and focuses it);
/// a line focuses its hunk.
pub fn click(app: *App, p: *AiApplyPane, row: u32, m: Mouse) void {
    if (row >= p.rows.len) return;
    if (m.kind != .press or m.button != .left) return;
    const hunk: usize = p.rows[row].hunkOf();
    if (p.rows[row] == .header and p.cursor == hunk) toggle(p, hunk);
    p.cursor = hunk;
    app.needs_render = true;
}

pub fn scrollBy(p: *AiApplyPane, delta: i64) void {
    const cur: i64 = @intCast(p.scroll);
    p.scroll = @intCast(@max(cur + delta, 0));
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn joined(arena: Allocator, lines: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (lines) |l| try appendLine(&out, arena, l);
    return out.toOwnedSlice(arena);
}

test "the line diff: a middle change, an insertion, a deletion, and the missing final newline" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const old = try splitLines(a, "a\nb\nc\nd\n");
    const new = try splitLines(a, "a\nB\nc\nd\n");
    const ops = try editScript(a, old, new);
    try t.expectEqualSlices(Op, &.{ .eq, .del, .add, .eq, .eq }, ops);
    const hunks = try hunksOf(a, ops, old.len, new.len);
    try t.expectEqual(@as(usize, 1), hunks.len);
    try t.expectEqualStrings("@@ -1,4 +1,4 @@", try hunks[0].header(a));
    // Insert + delete far apart: two hunks with their own context.
    const o2 = try splitLines(a, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n");
    const n2 = try splitLines(a, "1\n2\nX\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n19\n20\n");
    const ops2 = try editScript(a, o2, n2);
    const h2 = try hunksOf(a, ops2, o2.len, n2.len);
    try t.expectEqual(@as(usize, 2), h2.len);
    try t.expectEqualStrings("@@ -1,5 +1,6 @@", try h2[0].header(a));
    try t.expectEqualStrings("@@ -15,6 +16,5 @@", try h2[1].header(a));
    // No newline at the end: the marker line diffs, and round-trips.
    const o3 = try splitLines(a, "x\ny");
    const n3 = try splitLines(a, "x\ny\n");
    try t.expectEqual(@as(usize, 3), o3.len);
    try t.expectEqual(@as(usize, 2), n3.len);
    try t.expectEqualStrings("x\ny", try joined(a, o3));
    try t.expectEqualStrings("x\ny\n", try joined(a, n3));
    try t.expectEqual(@as(usize, 0), (try splitLines(a, "")).len);
    // A middle past the table cap is one replacement, still correct in `result`.
    const ops3 = try editScript(a, o3, n3);
    try t.expectEqualSlices(Op, &.{ .eq, .eq, .del }, ops3);
}

test "result assembles accepted hunks and leaves skipped ones as they were" {
    const old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";
    const new = "1\n2\nX\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n19\n20\n";
    const no_doc: u8 = 0;
    var p = try build(t.allocator, .{ .pane = 0, .doc = &no_doc, .seen = 0, .start = 0, .end = old.len }, null, "f.txt", old, new);
    defer p.deinit();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectEqual(@as(usize, 2), p.hunks.len);
    try t.expectEqualStrings(new, try p.result(a));
    p.hunks[0].accepted = false;
    try t.expectEqualStrings("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n19\n20\n", try p.result(a));
    p.hunks[1].accepted = false;
    try t.expectEqualStrings(old, try p.result(a));
    p.hunks[0].accepted = true;
    try t.expectEqualStrings("1\n2\nX\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n", try p.result(a));
    // Rows: header, 2 context, +X, 3 context; header, 3 context, -18, 2 context.
    try t.expectEqual(@as(usize, 14), p.rows.len);
    try t.expect(p.rows[0] == .header);
    try t.expect(p.rows[3] == .add);
    try t.expectEqualStrings("X", lineText(&p, p.rows[3]));
    try t.expect(p.rows[11] == .del);
    try t.expectEqualStrings("18", lineText(&p, p.rows[11]));
    p.cursor = 1;
    try t.expectEqual(@as(usize, 7), p.cursorRow());
}

test "ai.apply opens the review pane; skipping a hunk applies the rest as one undo step" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    const e = app.panes.editor(ed).?;
    const old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";
    try e.buf.editor.setText(old);
    const code = "1\n2\nX\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n19\n20";
    const id = try open(&app, ed, .take(ed, e.buf.doc, 0, old.len), null, code);
    try t.expectEqual(id, app.active.?);
    const p = &app.panes.get(id).?.ai_apply;
    try t.expectEqual(@as(usize, 2), p.hunks.len);
    // Skip the second hunk (the deletion), keep the insertion.
    _ = try handleKey(&app, id, p, .{ .code = .{ .char = 'j' } });
    _ = try handleKey(&app, id, p, .{ .code = .{ .char = ' ' } });
    try t.expect(!p.hunks[1].accepted);
    try t.expectEqual(@as(usize, 1), p.accepted());
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    try t.expect(app.panes.get(id) == null);
    try t.expectEqual(ed, app.active.?);
    try t.expectEqualStrings("1\n2\nX\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n", e.buf.editor.bytes());
    // One undo step brings the original back.
    _ = try app.applyOps(e, &.{.undo});
    try t.expectEqualStrings(old, e.buf.editor.bytes());
    // Esc cancels without touching the editor.
    const id2 = try open(&app, ed, .take(ed, e.buf.doc, 0, old.len), null, code);
    const p2 = &app.panes.get(id2).?.ai_apply;
    _ = try handleKey(&app, id2, p2, .{ .code = .esc });
    try t.expect(app.panes.get(id2) == null);
    try t.expectEqualStrings(old, e.buf.editor.bytes());
    // Nothing accepted: no edit, the pane closes.
    const id3 = try open(&app, ed, .take(ed, e.buf.doc, 0, old.len), null, code);
    const p3 = &app.panes.get(id3).?.ai_apply;
    _ = try handleKey(&app, id3, p3, .{ .code = .{ .char = 'R' } });
    _ = try handleKey(&app, id3, p3, .{ .code = .{ .char = 'y' } });
    try t.expect(app.panes.get(id3) == null);
    try t.expectEqualStrings(old, e.buf.editor.bytes());
}

test "an anchor follows edits around it, and an edit inside it — or an undo — loses it" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    const e = app.panes.editor(ed).?;
    try e.buf.editor.setText("head\nmid\ntail\n");
    // `mid\n`, bytes 5..9.
    var a = Anchor.take(ed, e.buf.doc, 5, 9);
    // A line typed above moves it down; one below leaves it.
    try app.splice(e, 0, 0, "new\n");
    try app.splice(e, e.buf.editor.len(), e.buf.editor.len(), "more\n");
    a.follow(e.buf.doc);
    try t.expect(!a.lost);
    try t.expectEqualStrings("mid\n", e.buf.editor.bytes()[a.start..a.end]);
    // An insertion right at either edge stays outside it.
    try app.splice(e, a.start, a.start, ">");
    a.follow(e.buf.doc);
    try app.splice(e, a.end, a.end, "<");
    a.follow(e.buf.doc);
    try t.expectEqualStrings("mid\n", e.buf.editor.bytes()[a.start..a.end]);
    // Deleting text before it pulls it up.
    try app.splice(e, 0, 4, "");
    a.follow(e.buf.doc);
    try t.expectEqualStrings("mid\n", e.buf.editor.bytes()[a.start..a.end]);
    // An edit inside it: lost, and it stays lost.
    try app.splice(e, a.start + 1, a.start + 2, "I");
    a.follow(e.buf.doc);
    try t.expect(a.lost);
    // An undo is a wholesale replacement the log cannot carry a range across.
    var b = Anchor.take(ed, e.buf.doc, 0, 1);
    _ = try app.applyOps(e, &.{.undo});
    b.follow(e.buf.doc);
    try t.expect(b.lost);
}

test "apply writes the reviewed text where it now is, and refuses when that text changed" {
    var app = try App.initWith(t.allocator, t.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    const ed = try app.openScratch();
    const e = app.panes.editor(ed).?;
    try e.buf.editor.setText("a\nb\nc\n");
    const id = try open(&app, ed, .take(ed, e.buf.doc, 0, 6), null, "ALPHA\nb\nc\n");
    // A line added above while the review is open.
    try app.splice(e, 0, 0, "ZZZ\n");
    const p = &app.panes.get(id).?.ai_apply;
    _ = try handleKey(&app, id, p, .{ .code = .enter });
    try t.expectEqualStrings("ZZZ\nALPHA\nb\nc\n", e.buf.editor.bytes());
    // An edit inside the reviewed text: refused, the pane stays, the
    // buffer is the user's.
    try e.buf.editor.setText("a\nb\nc\n");
    const id2 = try open(&app, ed, .take(ed, e.buf.doc, 0, 6), null, "ALPHA\nb\nc\n");
    try app.splice(e, 2, 3, "B");
    const p2 = &app.panes.get(id2).?.ai_apply;
    _ = try handleKey(&app, id2, p2, .{ .code = .enter });
    try t.expect(app.panes.get(id2) != null);
    try t.expectEqualStrings("a\nB\nc\n", e.buf.editor.bytes());
    // Opening a review for a range whose text changed since the job
    // started is refused too.
    var gone = Anchor.take(ed, e.buf.doc, 0, 6);
    try app.splice(e, 0, 1, "X");
    gone.follow(e.buf.doc);
    try t.expectError(error.Failed, open(&app, ed, gone, "a\nB\nc\n", "ALPHA\n"));
    app.diag.clear();
    // …unless the text it lost track of reads the same again.
    var back = Anchor.take(ed, e.buf.doc, 0, 6);
    try app.splice(e, 0, 1, "a");
    back.follow(e.buf.doc);
    try t.expect(back.lost);
    _ = try open(&app, ed, back, "a\nB\nc\n", "ALPHA\nB\nc\n");
}
