//! Snippets: a trigger word before the cursor expands into a body with
//! tab stops. The table is keyed by scope (a file extension, or
//! `global`) then trigger; the `.test` `snippet` directive and
//! `config.snippets` both feed it.
//!
//! A body is `$1` … `$9` for the stops, `$0` for where the cursor lands
//! last, `${1:placeholder}` for a stop with default text (selected when
//! reached so typing replaces it), `\$` for a literal dollar. After an
//! expansion with more than one stop a session is open: Tab goes to the
//! next stop, Shift+Tab back (landing at the end of what was typed
//! there), Esc ends it. Stops track the text through the editor's edit
//! log — an insert before a stop moves it, typing at a stop leaves it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const key_mod = @import("../core/key.zig");
const Key = key_mod.Key;

pub const table = .{
    .@"snippet.expand" = &expandCmd,
    .@"snippet.next_placeholder" = &nextCmd,
    .@"snippet.prev_placeholder" = &prevCmd,
};

pub const Stop = struct {
    pos: usize,
    /// Length of the default text at `pos`, selected when the stop is
    /// reached for the first time.
    default_len: usize = 0,
    /// Where the cursor was when the stop was left; a return lands here.
    exit: ?usize = null,
};

/// The parsed body: the text to insert and the stops as offsets into it,
/// `$1..$9` in order then `$0` last.
pub const Parsed = struct {
    text: []u8,
    stops: []Stop,

    pub fn deinit(p: *Parsed, gpa: Allocator) void {
        gpa.free(p.text);
        gpa.free(p.stops);
    }
};

pub fn parse(gpa: Allocator, raw: []const u8) Allocator.Error!Parsed {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(gpa);
    var found: [10]?Stop = .{null} ** 10;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len and (raw[i + 1] == '$' or raw[i + 1] == '\\' or raw[i + 1] == '}')) {
            try text.append(gpa, raw[i + 1]);
            i += 2;
            continue;
        }
        if (c == '$' and i + 1 < raw.len) {
            const n = raw[i + 1];
            if (std.ascii.isDigit(n)) {
                // The first `$N` is the stop; a repeat is literal text.
                const d = n - '0';
                if (found[d] == null) {
                    found[d] = .{ .pos = text.items.len };
                    i += 2;
                    continue;
                }
            }
            if (n == '{') {
                if (std.mem.indexOfScalarPos(u8, raw, i + 2, '}')) |close| {
                    const inner = raw[i + 2 .. close];
                    if (inner.len > 0 and std.ascii.isDigit(inner[0]) and (inner.len == 1 or inner[1] == ':')) {
                        const d = inner[0] - '0';
                        const default = if (inner.len > 2) inner[2..] else "";
                        // A repeat of a braced stop keeps only its default text.
                        if (found[d] == null) found[d] = .{ .pos = text.items.len, .default_len = default.len };
                        try text.appendSlice(gpa, default);
                        i = close + 1;
                        continue;
                    }
                }
            }
        }
        try text.append(gpa, c);
        i += 1;
    }
    var stops: std.ArrayListUnmanaged(Stop) = .empty;
    errdefer stops.deinit(gpa);
    for (1..10) |d| if (found[d]) |s| try stops.append(gpa, s);
    if (found[0]) |s| try stops.append(gpa, s);
    return .{ .text = try text.toOwnedSlice(gpa), .stops = try stops.toOwnedSlice(gpa) };
}

pub const Session = struct {
    pane: PaneId,
    /// Absolute byte positions.
    stops: []Stop,
    current: usize,
    /// The edit-log seq the stops are current at.
    seen_seq: u64,
};

pub const State = struct {
    gpa: Allocator,
    /// scope → trigger → body. Keys and bodies are owned.
    scopes: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]u8)) = .empty,
    session: ?Session = null,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *State) void {
        var it = self.scopes.iterator();
        while (it.next()) |e| {
            var inner = e.value_ptr.*;
            var it2 = inner.iterator();
            while (it2.next()) |t| {
                self.gpa.free(t.key_ptr.*);
                self.gpa.free(t.value_ptr.*);
            }
            inner.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.scopes.deinit(self.gpa);
        self.endSession();
    }

    /// Add (or replace) `trigger` in `scope`.
    pub fn seed(self: *State, scope: []const u8, trigger: []const u8, body: []const u8) Allocator.Error!void {
        const gpa = self.gpa;
        const gop = try self.scopes.getOrPut(gpa, scope);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, scope);
            gop.value_ptr.* = .empty;
        }
        errdefer if (!gop.found_existing) {
            gpa.free(gop.key_ptr.*);
            _ = self.scopes.remove(scope);
        };
        const owned = try gpa.dupe(u8, body);
        errdefer gpa.free(owned);
        const inner = gop.value_ptr;
        if (inner.getEntry(trigger)) |e| {
            gpa.free(e.value_ptr.*);
            e.value_ptr.* = owned;
            return;
        }
        const key = try gpa.dupe(u8, trigger);
        errdefer gpa.free(key);
        try inner.put(gpa, key, owned);
    }

    /// The config's `snippets` section: `scope → trigger → body`.
    pub fn absorbConfig(self: *State, snippets: anytype) Allocator.Error!void {
        for (snippets.keys()) |scope| {
            const inner = snippets.get(scope) orelse continue;
            for (inner.keys()) |trigger| try self.seed(scope, trigger, inner.get(trigger).?);
        }
    }

    /// `scope` first, then `global`.
    pub fn lookup(self: *const State, scope: []const u8, trigger: []const u8) ?[]const u8 {
        if (self.scopes.get(scope)) |inner| if (inner.get(trigger)) |b| return b;
        if (self.scopes.get("global")) |inner| if (inner.get(trigger)) |b| return b;
        return null;
    }

    pub fn count(self: *const State) usize {
        var n: usize = 0;
        var it = self.scopes.valueIterator();
        while (it.next()) |inner| n += inner.count();
        return n;
    }

    pub fn endSession(self: *State) void {
        if (self.session) |s| self.gpa.free(s.stops);
        self.session = null;
    }
};

/// The snippet scope of a file: its extension, lower-cased.
pub fn scopeFor(path: ?[]const u8, buf: []u8) []const u8 {
    const p = path orelse return "global";
    const ext = std.fs.path.extension(p);
    if (ext.len < 2 or ext.len - 1 > buf.len) return "global";
    return std.ascii.lowerString(buf[0 .. ext.len - 1], ext[1..]);
}

/// The identifier run ending at `cursor`: `(start, word)`.
pub fn wordBefore(text: []const u8, cursor: usize) struct { start: usize, word: []const u8 } {
    const cur = @min(cursor, text.len);
    var start = cur;
    while (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]) or text[start - 1] == '_')) start -= 1;
    return .{ .start = start, .word = text[start..cur] };
}

/// Expand the trigger before the cursor in `e`. Returns false (and
/// toasts) when nothing matches.
pub fn expand(app: *App, pane_id: PaneId, e: *EditorPane) Allocator.Error!bool {
    const ed = &e.buf.editor;
    const w = wordBefore(ed.bytes(), ed.cursor);
    var scope_buf: [32]u8 = undefined;
    const scope = scopeFor(e.buf.path, &scope_buf);
    const body = (if (w.word.len > 0) app.snippets.lookup(scope, w.word) else null) orelse {
        app.toast("no snippet matches \"{s}\"", .{w.word});
        return false;
    };
    var parsed = try parse(app.gpa, body);
    defer parsed.deinit(app.gpa);
    app.snippets.endSession();
    const start = w.start;
    const cursor = ed.cursor;
    const text = try app.frame.allocator().dupe(u8, parsed.text);
    try app.splice(e, start, cursor, text);
    // Land on the first stop (or the end of the body).
    const first: ?Stop = if (parsed.stops.len > 0) parsed.stops[0] else null;
    const land = start + (if (first) |f| f.pos else parsed.text.len);
    ed.anchor = null;
    ed.setCursor(@min(land, ed.len()));
    if (first) |f| if (f.default_len > 0) {
        ed.anchor = land;
        ed.setCursor(@min(land + f.default_len, ed.len()));
    };
    if (parsed.stops.len > 1) {
        const stops = try app.gpa.alloc(Stop, parsed.stops.len);
        for (parsed.stops, 0..) |s, i| stops[i] = .{ .pos = start + s.pos, .default_len = s.default_len, .exit = if (i == 0 and s.default_len > 0) start + s.pos + s.default_len else null };
        app.snippets.session = .{ .pane = pane_id, .stops = stops, .current = 0, .seen_seq = ed.edits.head() };
    }
    app.needs_render = true;
    return true;
}

/// Move to the next (`dir = 1`) or previous stop. Forward past the last
/// stop ends the session; backward at the first stays.
pub fn step(app: *App, dir: i8) void {
    const sess = if (app.snippets.session) |*s| s else return;
    const e = app.panes.editor(sess.pane) orelse return app.snippets.endSession();
    if (app.active != sess.pane) return app.snippets.endSession();
    const ed = &e.buf.editor;
    afterEdit(app, sess.pane, e);
    sess.stops[sess.current].exit = ed.cursor;
    const next: i64 = @as(i64, @intCast(sess.current)) + dir;
    if (next >= @as(i64, @intCast(sess.stops.len))) return app.snippets.endSession();
    if (next < 0) return;
    const idx: usize = @intCast(next);
    const s = sess.stops[idx];
    ed.anchor = null;
    if (s.exit) |x| {
        ed.setCursor(@min(x, ed.len()));
    } else if (s.default_len > 0) {
        ed.anchor = @min(s.pos, ed.len());
        ed.setCursor(@min(s.pos + s.default_len, ed.len()));
        sess.stops[idx].exit = @min(s.pos + s.default_len, ed.len());
    } else {
        ed.setCursor(@min(s.pos, ed.len()));
    }
    sess.current = idx;
    app.needs_render = true;
}

/// Fold the pane's edits since the session last looked into the stops.
/// A stop strictly after an edit moves with the text; one at the edit
/// (typing at the stop) stays; one inside a deleted range clamps to it.
pub fn afterEdit(app: *App, pane_id: PaneId, e: *EditorPane) void {
    const sess = if (app.snippets.session) |*s| s else return;
    if (sess.pane != pane_id) return;
    const ed = &e.buf.editor;
    if (ed.edits.lostSince(sess.seen_seq)) return app.snippets.endSession();
    for (ed.edits.since(sess.seen_seq)) |sp| {
        for (sess.stops) |*s| {
            s.pos = shift(s.pos, sp.start, sp.old_end, sp.new_end);
            if (s.exit) |x| s.exit = shift(x, sp.start, sp.old_end, sp.new_end);
        }
    }
    sess.seen_seq = ed.edits.head();
}

fn shift(pos: usize, start: usize, old_end: usize, new_end: usize) usize {
    if (pos <= start) return pos;
    if (pos >= old_end) return pos - old_end + new_end;
    return start;
}

/// Tab / Shift+Tab / Esc while a session is open on `pane_id`, and Tab
/// on a trigger word when none is. Returns true when the key was taken.
pub fn interceptKey(app: *App, pane_id: PaneId, e: *EditorPane, k: Key) Allocator.Error!bool {
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    if (app.snippets.session) |s| if (s.pane == pane_id) {
        switch (k.code) {
            .tab => {
                if (k.mods.shift) step(app, -1) else step(app, 1);
                return true;
            },
            .backtab => {
                step(app, -1);
                return true;
            },
            .esc => app.snippets.endSession(),
            else => {},
        }
    };
    if (k.code != .tab or k.mods.shift) return false;
    const mode = e.buf.input.mode();
    if (mode != .insert and mode != .none) return false;
    if (app.snippets.count() == 0) return false;
    const ed = &e.buf.editor;
    const w = wordBefore(ed.bytes(), ed.cursor);
    if (w.word.len == 0) return false;
    var scope_buf: [32]u8 = undefined;
    if (app.snippets.lookup(scopeFor(e.buf.path, &scope_buf), w.word) == null) return false;
    return expand(app, pane_id, e);
}

fn expandCmd(app: *App) CommandError!void {
    const id = app.active orelse return error.NoActivePane;
    const e = try app.requireEditor();
    _ = try expand(app, id, e);
}

fn nextCmd(app: *App) CommandError!void {
    if (app.snippets.session == null) return app.diag.fail(app.frame.allocator(), "no snippet session", .{});
    step(app, 1);
}

fn prevCmd(app: *App) CommandError!void {
    if (app.snippets.session == null) return app.diag.fail(app.frame.allocator(), "no snippet session", .{});
    step(app, -1);
}

// ── tests ──

const testing = std.testing;

test "parse: bare, braced and defaulted stops, $0 last, escapes" {
    var p = try parse(testing.allocator, "for $1 in ${2:items} {\n    $0\n}\\$x ${1} $2");
    defer p.deinit(testing.allocator);
    // A repeated `$2` is literal text; a repeated `${1}` is its (empty) default.
    try testing.expectEqualStrings("for  in items {\n    \n}$x  $2", p.text);
    try testing.expectEqual(@as(usize, 3), p.stops.len);
    try testing.expectEqual(@as(usize, 4), p.stops[0].pos);
    try testing.expectEqual(@as(usize, 8), p.stops[1].pos);
    try testing.expectEqual(@as(usize, 5), p.stops[1].default_len);
    try testing.expectEqual(@as(usize, 20), p.stops[2].pos);
    var none = try parse(testing.allocator, "plain");
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.stops.len);
}

test "shift: after moves, at stays, inside a deletion clamps" {
    try testing.expectEqual(@as(usize, 12), shift(10, 5, 5, 7));
    try testing.expectEqual(@as(usize, 5), shift(5, 5, 5, 7));
    try testing.expectEqual(@as(usize, 3), shift(3, 5, 5, 7));
    try testing.expectEqual(@as(usize, 6), shift(10, 5, 9, 5));
    try testing.expectEqual(@as(usize, 5), shift(7, 5, 9, 5));
}

test "table: scope then global, replace on re-seed, config absorb" {
    var st = State.init(testing.allocator);
    defer st.deinit();
    try st.seed("rs", "fn", "fn $1() {}");
    try st.seed("global", "ts", "2026");
    try st.seed("rs", "fn", "fn name() {}");
    try testing.expectEqualStrings("fn name() {}", st.lookup("rs", "fn").?);
    try testing.expectEqualStrings("2026", st.lookup("rs", "ts").?);
    try testing.expectEqualStrings("2026", st.lookup("md", "ts").?);
    try testing.expect(st.lookup("md", "fn") == null);
    try testing.expectEqual(@as(usize, 2), st.count());
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("rs", scopeFor("/x/a.RS", &buf));
    try testing.expectEqualStrings("global", scopeFor(null, &buf));
    const w = wordBefore("let forr", 8);
    try testing.expectEqualStrings("forr", w.word);
    try testing.expectEqual(@as(usize, 4), w.start);
}

test "expansion places the cursor at $1, tab walks the stops, backtab returns to the typed end" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    try app.snippets.seed("global", "forr", "for $1 in $2 {\n    $0\n}");
    const id = try app.openScratch();
    const e = app.activeEditor().?;
    for ("forr") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try testing.expectEqualStrings("for  in  {\n    \n}", e.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 4), e.buf.editor.cursor);
    try testing.expect(app.snippets.session != null);
    try app.handle(.{ .key = Key.char('i') });
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqual(@as(usize, 9), e.buf.editor.cursor);
    for ("items") |c| try app.handle(.{ .key = Key.char(c) });
    try testing.expectEqualStrings("for i in items {\n    \n}", e.buf.editor.bytes());
    try app.handle(.{ .key = Key.named(.backtab) });
    try testing.expectEqual(@as(usize, 5), e.buf.editor.cursor);
    for ("_var") |c| try app.handle(.{ .key = Key.char(c) });
    try app.handle(.{ .key = Key.named(.tab) });
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expectEqual(@as(usize, 25), e.buf.editor.cursor); // the $0 indent
    try app.handle(.{ .key = Key.named(.tab) });
    try testing.expect(app.snippets.session == null);
    try testing.expectEqualStrings("for i_var in items {\n    \n}", e.buf.editor.bytes());
    // A trigger with no match toasts and leaves the text alone.
    for (" todo") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "no snippet matches") != null);
    _ = id;
}
