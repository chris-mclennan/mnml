//! Flash-motion labels. In vim Normal, `s<a><b>` looks for every `ab`
//! in the active pane's viewport. One match jumps at once; none toasts
//! and stays; several ARM the app: each match wears a one-key label
//! (nearest to the cursor first, drawn from `label_pool` minus the two
//! trigger chars) and the next key decides — a label jumps to its match,
//! Esc disarms, anything else disarms and goes on to whatever it would
//! have done. The armed state is `App.flash`; it dies with a pane
//! change, a buffer edit, a mouse press, or the next `s`.
//!
//! The view paints the labels through `editor_view.Doc.labels`
//! (`render.zig` fills it from `current`); the cue on the pane's last
//! row says what to press.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const Key = @import("../core/key.zig").Key;

/// The label alphabet: home row first, then the rest, then uppercase.
/// The trigger pair's chars are skipped so the third key is never the
/// one the user was already typing.
pub const label_pool = "fjdkslaghrueiwoqptyzxcvbnmFJDKSLAGHRUEIWOQPTYZXCVBNM";

/// No more than this many matches get a label — flash points at what is
/// on screen, it is not a search. The pool itself holds 52, so the cap
/// binds only in theory.
pub const max_matches = 60;

pub const Match = struct {
    /// Byte offset of the pair's first char.
    byte: usize,
    /// The key that jumps here — an index into `label_pool`.
    label: u8,

    /// The label as a one-byte slice into the pool (static lifetime).
    pub fn text(m: Match) []const u8 {
        const i = std.mem.indexOfScalar(u8, label_pool, m.label) orelse 0;
        return label_pool[i .. i + 1];
    }
};

/// The armed state.
pub const State = struct {
    pane: PaneId,
    a: u21,
    b: u21,
    /// Sorted by `byte` — the paint order. gpa-owned.
    matches: []Match,
    /// `edits.head()` when armed; a later edit disarms.
    edit_seq: u64,

    pub fn deinit(self: *State, gpa: Allocator) void {
        gpa.free(self.matches);
    }

    pub fn labelFor(self: *const State, key: u8) ?Match {
        for (self.matches) |m| if (m.label == key) return m;
        return null;
    }
};

fn lower(c: u21) u21 {
    return if (c < 128) std.ascii.toLower(@intCast(c)) else c;
}

/// The labels available for the pair `a b`, in pool order, into `buf`.
pub fn labelsFor(a: u21, b: u21, buf: *[label_pool.len]u8) []const u8 {
    var n: usize = 0;
    for (label_pool) |c| {
        if (lower(c) == lower(a) or lower(c) == lower(b)) continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// Append the byte offset (relative to `base`) of every `ab` in `line`,
/// ASCII-case-insensitively; overlapping pairs both count (`aaa` holds
/// two `aa`s), as the Rust does.
pub fn findPairs(gpa: Allocator, out: *std.ArrayList(usize), line: []const u8, base: usize, a: u21, b: u21) Allocator.Error!void {
    var it = std.unicode.Utf8View.initUnchecked(line).iterator();
    var prev: ?struct { c: u21, at: usize } = null;
    var at: usize = 0;
    while (it.nextCodepoint()) |c| {
        const len = std.unicode.utf8CodepointSequenceLength(c) catch 1;
        if (prev) |p| if (lower(p.c) == lower(a) and lower(c) == lower(b)) try out.append(gpa, base + p.at);
        prev = .{ .c = c, .at = at };
        at += len;
    }
}

/// `s<a><b>` landed: look through the viewport and jump, toast, or arm.
pub fn start(app: *App, pane_id: PaneId, e: *EditorPane, a: u21, b: u21) Allocator.Error!void {
    cancel(app);
    const arena = app.frame.allocator();
    const ed = e.buf.editor;
    var hits: std.ArrayList(usize) = .empty;
    // The rows the last frame showed: from the view's first line, one
    // row per visible line, a closed fold counting as its first line.
    var line: usize = e.view.scroll_line;
    var rows: usize = 0;
    const total = ed.lineCount();
    while (line < total and rows < @max(app.pane_rows, 1)) : (rows += 1) {
        try findPairs(arena, &hits, ed.lineSlice(line), ed.lineStart(line), a, b);
        line = if (e.buf.editor.folds.get(line)) |end| end + 1 else line + 1;
    }
    // The pair under the cursor is where we already are.
    const cursor = ed.cursor;
    var n: usize = 0;
    for (hits.items) |h| if (h != cursor) {
        hits.items[n] = h;
        n += 1;
    };
    hits.items.len = n;

    if (n == 0) {
        var pair: [8]u8 = undefined;
        app.toast("flash: no match for \"{s}\" on screen", .{pairText(a, b, &pair)});
        return;
    }
    if (n == 1) {
        jumpTo(e, hits.items[0]);
        return;
    }
    // Nearest to the cursor first; on a tie the one ahead of it.
    std.mem.sort(usize, hits.items, cursor, struct {
        fn lessThan(c: usize, x: usize, y: usize) bool {
            const dx = if (x > c) x - c else c - x;
            const dy = if (y > c) y - c else c - y;
            if (dx != dy) return dx < dy;
            return x > y;
        }
    }.lessThan);
    var pool: [label_pool.len]u8 = undefined;
    const labels = labelsFor(a, b, &pool);
    const count = @min(n, @min(labels.len, max_matches));
    const matches = try app.gpa.alloc(Match, count);
    errdefer app.gpa.free(matches);
    for (matches, 0..) |*m, i| m.* = .{ .byte = hits.items[i], .label = labels[i] };
    std.mem.sort(Match, matches, {}, struct {
        fn lessThan(_: void, x: Match, y: Match) bool {
            return x.byte < y.byte;
        }
    }.lessThan);
    app.flash = .{ .pane = pane_id, .a = a, .b = b, .matches = matches, .edit_seq = ed.doc.edits.head() };
    app.needs_render = true;
}

/// `ab` as UTF-8, into `buf`.
pub fn pairText(a: u21, b: u21, buf: *[8]u8) []const u8 {
    const na = std.unicode.utf8Encode(a, buf[0..4]) catch 0;
    const nb = std.unicode.utf8Encode(b, buf[na..]) catch 0;
    return buf[0 .. na + nb];
}

fn jumpTo(e: *EditorPane, byte: usize) void {
    const ed = e.buf.editor;
    const p = ed.rowColAt(byte);
    ed.placeCursor(p.row, p.col);
    e.view.pin = null;
}

pub fn cancel(app: *App) void {
    if (app.flash) |*f| {
        f.deinit(app.gpa);
        app.flash = null;
        app.needs_render = true;
    }
}

/// The armed state, if it still applies: the pane is the active editor
/// and its text has not changed since. Anything else disarms.
pub fn current(app: *App) ?*State {
    const f: *State = if (app.flash) |*f| f else return null;
    const alive = app.active == f.pane and if (app.panes.editor(f.pane)) |e| e.buf.doc.edits.head() == f.edit_seq else false;
    if (!alive) {
        cancel(app);
        return null;
    }
    return f;
}

/// The next key while armed. Esc disarms and is consumed; a label
/// jumps and is consumed; any other key disarms and is NOT consumed —
/// it goes on to the editor as if flash had never been up.
pub fn interceptKey(app: *App, k: Key) bool {
    const f = current(app) orelse return false;
    if (k.code == .esc) {
        cancel(app);
        return true;
    }
    if (k.typed()) |c| if (c < 128) if (f.labelFor(@intCast(c))) |m| {
        const pane = f.pane;
        cancel(app);
        if (app.panes.editor(pane)) |e| jumpTo(e, m.byte);
        return true;
    };
    cancel(app);
    return false;
}

// ── tests ──

const testing = std.testing;
const command = @import("../core/command.zig");
const dispatch = @import("dispatch.zig");
const screen_mod = @import("../ipc/screen.zig");

test "labelsFor: pool order, minus the trigger pair in either case" {
    var buf: [label_pool.len]u8 = undefined;
    const l = labelsFor('a', 'B', &buf);
    try testing.expectEqual(label_pool.len - 4, l.len);
    try testing.expectEqualStrings("fjdkslghrueiwoqptyzxcvnmFJDKSLGHRUEIWOQPTYZXCVNM", l);
    const all = labelsFor('1', '2', &buf);
    try testing.expectEqualStrings(label_pool, all);
}

test "findPairs: case-insensitive, overlapping, offset by base, utf-8 aware" {
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(testing.allocator);
    try findPairs(testing.allocator, &out, "ab AB xab", 10, 'a', 'b');
    try testing.expectEqualSlices(usize, &.{ 10, 13, 17 }, out.items);
    out.clearRetainingCapacity();
    try findPairs(testing.allocator, &out, "aaa", 0, 'a', 'a');
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, out.items);
    out.clearRetainingCapacity();
    try findPairs(testing.allocator, &out, "éab", 0, 'a', 'b');
    try testing.expectEqualSlices(usize, &.{2}, out.items);
}

fn vimApp(text: []const u8, rows: u16) !App {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = App.scratch_workspace, .cols = 60, .rows = rows });
    errdefer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    try app.activeEditor().?.buf.editor.setText(text);
    try command.run(&app, .{ .static = .@"editor.use_vim" });
    try app.render();
    return app;
}

fn press(app: *App, k: Key) !void {
    try dispatch.key(app, k);
}

test "flash: labels go nearest-first in pool order, only in the viewport, capped by the pool" {
    // 9 rows: palette bar, strip, 5 text rows, statusline, cmdline. Lines
    // 6+ are off-screen.
    var app = try vimApp("ab ab\nxx\nab\nxx\nab\nab\nab\nab", 9);
    defer app.deinit();
    try testing.expectEqual(@as(usize, 5), app.pane_rows);
    const e = app.activeEditor().?;
    e.buf.editor.placeCursor(2, 0); // on the `ab` of line 3 (byte 9)
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    const f = app.flash orelse return error.TestExpectedArmed;
    // Bytes 0, 3, 15 — the cursor's own pair (9) is not a target and
    // lines 6-8 are below the viewport.
    try testing.expectEqual(@as(usize, 3), f.matches.len);
    try testing.expectEqual(@as(usize, 0), f.matches[0].byte);
    try testing.expectEqual(@as(usize, 3), f.matches[1].byte);
    try testing.expectEqual(@as(usize, 15), f.matches[2].byte);
    // Nearest first: 3 and 15 are both 6 away; the one ahead gets `f`,
    // the one behind `j`, and 0 `d`.
    try testing.expectEqual(@as(u8, 'f'), f.matches[2].label);
    try testing.expectEqual(@as(u8, 'j'), f.matches[1].label);
    try testing.expectEqual(@as(u8, 'd'), f.matches[0].label);
    try testing.expectEqualStrings("d", f.matches[0].text());
}

test "flash: the pool caps the label count" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..70) |_| try text.appendSlice(testing.allocator, "ab ");
    var app = try vimApp(text.items, 8);
    defer app.deinit();
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    const f = app.flash orelse return error.TestExpectedArmed;
    try testing.expectEqual(label_pool.len - 4, f.matches.len);
}

test "flash: a label key lands the cursor on its match and disarms" {
    var app = try vimApp("one ab two\nxx\nthree ab four\nab five", 12);
    defer app.deinit();
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    const f = app.flash orelse return error.TestExpectedArmed;
    try testing.expectEqual(@as(usize, 3), f.matches.len);
    // Nearest to byte 0: 4 (`f`), 20 (`j`), 28 (`d`).
    try testing.expectEqual(@as(u8, 'j'), f.matches[1].label);
    try press(&app, Key.char('j'));
    try testing.expect(app.flash == null);
    const p = app.activeEditor().?.buf.editor.rowCol();
    try testing.expectEqual(@as(usize, 2), p.row);
    try testing.expectEqual(@as(usize, 6), p.col);
    // The key was consumed: `j` did not also move down a line.
    try testing.expectEqual(@as(usize, 2), app.activeEditor().?.buf.editor.currentLine());
}

test "flash: esc disarms with the cursor where it was" {
    var app = try vimApp("one ab two\nthree ab four", 12);
    defer app.deinit();
    app.activeEditor().?.buf.editor.placeCursor(0, 1);
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    try testing.expect(app.flash != null);
    try press(&app, Key.named(.esc));
    try testing.expect(app.flash == null);
    try testing.expectEqual(@as(usize, 1), app.activeEditor().?.buf.editor.cursor);
}

test "flash: a key that is no label disarms and still does its own thing" {
    var app = try vimApp("one ab two\nthree ab four\nfive", 12);
    defer app.deinit();
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    try testing.expect(app.flash != null);
    try press(&app, Key.named(.down));
    try testing.expect(app.flash == null);
    try testing.expectEqual(@as(usize, 1), app.activeEditor().?.buf.editor.currentLine());
}

test "flash: one match jumps at once, none toasts and stays" {
    var app = try vimApp("one two\nthree ab four", 12);
    defer app.deinit();
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    try testing.expect(app.flash == null);
    try testing.expectEqual(@as(usize, 14), app.activeEditor().?.buf.editor.cursor);
    app.activeEditor().?.buf.editor.placeCursor(0, 0);
    try press(&app, Key.char('s'));
    try press(&app, Key.char('z'));
    try press(&app, Key.char('q'));
    try testing.expect(app.flash == null);
    try testing.expectEqual(@as(usize, 0), app.activeEditor().?.buf.editor.cursor);
    try testing.expect(app.toasts.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, app.toasts.items[app.toasts.items.len - 1].text, "no match") != null);
}

test "flash: an edit while armed disarms; the label then does not jump" {
    var app = try vimApp("one ab two\nthree ab four\nab", 12);
    defer app.deinit();
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    try testing.expect(app.flash != null);
    try dispatch.runExLine(&app, "s/one/uno/");
    try testing.expect(current(&app) == null);
    try testing.expect(app.flash == null);
    try press(&app, Key.char('d'));
    try testing.expectEqual(@as(usize, 0), app.activeEditor().?.buf.editor.currentLine());
}

test "flash: a pane change disarms" {
    var app = try vimApp("one ab two\nthree ab four\nab", 12);
    defer app.deinit();
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    try testing.expect(app.flash != null);
    _ = try app.openScratch();
    try testing.expect(app.flash == null);
}

test "flash: the frame paints each label over its match and the cue on the last row; both go with the state" {
    var app = try vimApp("one ab two\nthree ab four\nab", 12);
    defer app.deinit();
    // The `use_vim` toast is still up: the stack moves off the cue's row.
    try press(&app, Key.char('s'));
    try press(&app, Key.char('a'));
    try press(&app, Key.char('b'));
    try app.render();
    const armed = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(armed);
    // Nearest to byte 0: 4 → `f`, 17 → `j`, 25 → `d`.
    try testing.expect(std.mem.indexOf(u8, armed, "one fb two") != null);
    try testing.expect(std.mem.indexOf(u8, armed, "three jb four") != null);
    try testing.expect(std.mem.indexOf(u8, armed, "db") != null);
    try testing.expect(std.mem.indexOf(u8, armed, "press a label to jump") != null);
    try testing.expect(std.mem.indexOf(u8, armed, "Esc cancels") != null);
    // The state survived the render.
    try testing.expect(app.flash != null);
    try press(&app, Key.named(.esc));
    try app.render();
    const clear = try screen_mod.toTestText(testing.allocator, &app.screen);
    defer testing.allocator.free(clear);
    try testing.expect(std.mem.indexOf(u8, clear, "one ab two") != null);
    try testing.expect(std.mem.indexOf(u8, clear, "press a label") == null);
}
