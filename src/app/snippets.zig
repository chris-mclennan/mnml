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
const hl = @import("highlight");

pub const table = .{
    .@"snippet.expand" = &expandCmd,
    .@"snippet.next_placeholder" = &nextCmd,
    .@"snippet.prev_placeholder" = &prevCmd,
    .@"snippet.pick" = &pickCmd,
    .@"snippet.pick_all" = &pickAllCmd,
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

/// scope → trigger → body, every key and body owned.
const Table = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]u8));

fn freeTable(gpa: Allocator, t: *Table) void {
    var it = t.iterator();
    while (it.next()) |e| {
        var inner = e.value_ptr.*;
        var it2 = inner.iterator();
        while (it2.next()) |x| {
            gpa.free(x.key_ptr.*);
            gpa.free(x.value_ptr.*);
        }
        inner.deinit(gpa);
        gpa.free(e.key_ptr.*);
    }
    t.deinit(gpa);
    t.* = .empty;
}

/// Add (or replace) `trigger` in `scope` of `t`; `scope` is taken as
/// it is (the caller normalized it).
fn put(gpa: Allocator, t: *Table, scope: []const u8, trigger: []const u8, body: []const u8) Allocator.Error!void {
    const gop = try t.getOrPut(gpa, scope);
    if (!gop.found_existing) {
        gop.key_ptr.* = gpa.dupe(u8, scope) catch |err| {
            t.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.value_ptr.* = .empty;
    }
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

pub const State = struct {
    gpa: Allocator,
    /// What lookups and the picker read: the config's snippets with the
    /// seeded ones over them. Scopes are normalized (`normalizeScope`).
    scopes: Table = .empty,
    /// The snippets added at run time (`seed`: the `.test` `snippet`
    /// directive), kept apart so a config reload, which rebuilds
    /// `scopes`, lays them back on top.
    seeded: Table = .empty,
    session: ?Session = null,

    pub fn init(gpa: Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *State) void {
        freeTable(self.gpa, &self.scopes);
        freeTable(self.gpa, &self.seeded);
        self.endSession();
    }

    /// Add (or replace) `trigger` in `scope`. It outlives a config reload.
    pub fn seed(self: *State, scope: []const u8, trigger: []const u8, body: []const u8) Allocator.Error!void {
        var buf: [max_scope]u8 = undefined;
        const s = normalizeScope(scope, &buf);
        try put(self.gpa, &self.seeded, s, trigger, body);
        try put(self.gpa, &self.scopes, s, trigger, body);
    }

    /// The config's `snippets` section (`scope → trigger → body`)
    /// becomes the table, replacing what an earlier config put there;
    /// the seeded snippets go back on top. Called when the config is
    /// loaded and on every reload.
    pub fn absorbConfig(self: *State, snippets: anytype) Allocator.Error!void {
        freeTable(self.gpa, &self.scopes);
        var buf: [max_scope]u8 = undefined;
        for (snippets.keys()) |scope| {
            const inner = snippets.get(scope) orelse continue;
            const s = normalizeScope(scope, &buf);
            for (inner.keys()) |trigger| try put(self.gpa, &self.scopes, s, trigger, inner.get(trigger).?);
        }
        var it = self.seeded.iterator();
        while (it.next()) |e| {
            var it2 = e.value_ptr.iterator();
            while (it2.next()) |x| try put(self.gpa, &self.scopes, e.key_ptr.*, x.key_ptr.*, x.value_ptr.*);
        }
    }

    /// `scope` first, then the scope it extends (`tsx` → `ts`), then `global`.
    pub fn lookup(self: *const State, scope: []const u8, trigger: []const u8) ?[]const u8 {
        if (self.scopes.get(scope)) |inner| if (inner.get(trigger)) |b| return b;
        if (parentScope(scope)) |p| if (self.scopes.get(p)) |inner| if (inner.get(trigger)) |b| return b;
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

/// The longest scope name kept as written; longer ones are cut.
const max_scope = 32;

/// A scope as the config or a `.test` writes it → the key a file's
/// scope is compared with. A language name or an extension becomes the
/// language's key — `.rust` and `.rs` are both `rs`, `.yml` is `yaml`,
/// `.typescript` is `ts` — so the config's scopes and `scopeFor` agree.
/// `global`, and a name mnml-zig has no grammar for, stay as written,
/// lower-cased.
pub fn normalizeScope(raw: []const u8, buf: []u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(raw, "global")) return "global";
    if (hl.table.keyForLanguageName(raw)) |k| return k;
    const n = @min(raw.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], raw[0..n]);
    if (hl.table.keyForExtension(lower)) |k| return k;
    return lower;
}

/// The scope a scope's snippets also apply in: TSX files take the
/// TypeScript snippets, JSX files the JavaScript ones.
pub fn parentScope(scope: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, scope, "tsx")) return "ts";
    if (std.mem.eql(u8, scope, "jsx")) return "js";
    return null;
}

/// The snippet scope of a file: its language's key (`rs`, `yaml`, `sh`
/// for a `.zshrc` or a bash shebang), else its extension lower-cased,
/// else `global`. `text` supplies the shebang.
pub fn scopeFor(path: ?[]const u8, text: []const u8, buf: []u8) []const u8 {
    if (hl.detect.keyFor(path, text)) |k| return k;
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
    const ed = e.buf.editor;
    const w = wordBefore(ed.bytes(), ed.cursor);
    var scope_buf: [32]u8 = undefined;
    const scope = scopeFor(e.buf.doc.path, e.buf.editor.bytes(), &scope_buf);
    const body = (if (w.word.len > 0) app.snippets.lookup(scope, w.word) else null) orelse {
        app.toast("no snippet matches \"{s}\"", .{w.word});
        return false;
    };
    try insertBody(app, pane_id, e, w.start, ed.cursor, body);
    return true;
}

/// `body` replaces `[start, cursor)` and its stops open a session — the
/// tail of a trigger expansion, and the whole of a picker insert.
fn insertBody(app: *App, pane_id: PaneId, e: *EditorPane, start: usize, cursor: usize, body: []const u8) Allocator.Error!void {
    const ed = e.buf.editor;
    var parsed = try parse(app.gpa, body);
    defer parsed.deinit(app.gpa);
    app.snippets.endSession();
    // Every line after the first carries the indent of the line the
    // snippet lands on, as in Neovim and VS Code: a body expanded
    // inside a block stays inside it. The stops move with their lines.
    const indent = ed.leadingIndent(ed.lineOfByte(start), start);
    const text = try indentBody(app.frame.allocator(), parsed.text, indent, parsed.stops);
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
        app.snippets.session = .{ .pane = pane_id, .stops = stops, .current = 0, .seen_seq = ed.doc.edits.head() };
    }
    app.needs_render = true;
}

/// `text` with `indent` after every `\n`; each stop's offset moves by
/// the indent of the lines before it. `stops` is updated in place.
fn indentBody(arena: Allocator, text: []const u8, indent: []const u8, stops: []Stop) Allocator.Error![]u8 {
    if (indent.len == 0 or std.mem.indexOfScalar(u8, text, '\n') == null) return arena.dupe(u8, text);
    for (stops) |*st| st.pos += indent.len * std.mem.count(u8, text[0..st.pos], "\n");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (text) |c| {
        try out.append(arena, c);
        if (c == '\n') try out.appendSlice(arena, indent);
    }
    return out.toOwnedSlice(arena);
}

// ── the picker ──

/// `snippet.pick`: the active file's scope (and `global`);
/// `snippet.pick_all`: every scope. One row per snippet — the trigger,
/// its scope as the hint, the body on one line as the detail — and
/// Enter inserts the body at the cursor.
fn pickCmd(app: *App) CommandError!void {
    return openPicker(app, false);
}

fn pickAllCmd(app: *App) CommandError!void {
    return openPicker(app, true);
}

fn openPicker(app: *App, all: bool) CommandError!void {
    const e = try app.requireEditor();
    var scope_buf: [32]u8 = undefined;
    const scope = scopeFor(e.buf.doc.path, e.buf.editor.bytes(), &scope_buf);
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    // Scopes sorted, then triggers sorted: the list reads the same each time.
    var scopes: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = app.snippets.scopes.keyIterator();
    while (it.next()) |k| {
        const parent = parentScope(scope) orelse "";
        if (!all and !std.mem.eql(u8, k.*, scope) and !std.mem.eql(u8, k.*, parent) and !std.mem.eql(u8, k.*, "global")) continue;
        try scopes.append(arena, k.*);
    }
    std.mem.sort([]const u8, scopes.items, {}, lessStr);
    var labels: std.ArrayListUnmanaged([]u8) = .empty;
    var details: std.ArrayListUnmanaged([]u8) = .empty;
    var hints: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
        for (details.items) |d| gpa.free(d);
        details.deinit(gpa);
        for (hints.items) |h| gpa.free(h);
        hints.deinit(gpa);
    }
    for (scopes.items) |sc| {
        const inner = app.snippets.scopes.get(sc) orelse continue;
        var triggers: std.ArrayListUnmanaged([]const u8) = .empty;
        var tit = inner.keyIterator();
        while (tit.next()) |k| try triggers.append(arena, k.*);
        std.mem.sort([]const u8, triggers.items, {}, lessStr);
        for (triggers.items) |trig| {
            try labels.append(gpa, try gpa.dupe(u8, trig));
            try details.append(gpa, try oneLine(gpa, inner.get(trig).?));
            try hints.append(gpa, try gpa.dupe(u8, sc));
        }
    }
    if (labels.items.len == 0) {
        if (all) return app.diag.fail(arena, "no snippets configured (config `.snippets`)", .{});
        return app.diag.fail(arena, "no snippets for scope {s} (config `.snippets`)", .{scope});
    }
    const cmd_picker = @import("cmd_picker.zig");
    try cmd_picker.openPickerWith(app, if (all) "Snippets (every scope)" else "Snippets", .snippets, try labels.toOwnedSlice(gpa), try gpa.alloc(PaneId, 0), try details.toOwnedSlice(gpa), try hints.toOwnedSlice(gpa));
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The body on one line: newlines become ` ↵ `, at most 60 cells.
fn oneLine(gpa: Allocator, body: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.appendSlice(gpa, " ↵ ");
        first = false;
        try out.appendSlice(gpa, std.mem.trim(u8, line, " \t"));
        if (out.items.len > 60) {
            out.shrinkRetainingCapacity(60);
            try out.appendSlice(gpa, "…");
            break;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The picker's Enter: `trigger` of `scope` at the cursor.
pub fn pickerAccept(app: *App, trigger: []const u8, scope: []const u8) Allocator.Error!void {
    const id = app.active orelse return;
    const e = app.panes.editor(id) orelse return;
    const inner = app.snippets.scopes.get(scope) orelse return;
    const body = inner.get(trigger) orelse return;
    try insertBody(app, id, e, e.buf.editor.cursor, e.buf.editor.cursor, body);
}

/// Move to the next (`dir = 1`) or previous stop. Forward past the last
/// stop ends the session; backward at the first stays.
pub fn step(app: *App, dir: i8) void {
    const sess = if (app.snippets.session) |*s| s else return;
    const e = app.panes.editor(sess.pane) orelse return app.snippets.endSession();
    if (app.active != sess.pane) return app.snippets.endSession();
    const ed = e.buf.editor;
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
    const ed = e.buf.editor;
    if (ed.doc.edits.replacedSince(sess.seen_seq)) return app.snippets.endSession();
    for (ed.doc.edits.since(sess.seen_seq)) |sp| {
        for (sess.stops) |*s| {
            s.pos = shift(s.pos, sp.start, sp.old_end, sp.new_end);
            if (s.exit) |x| s.exit = shift(x, sp.start, sp.old_end, sp.new_end);
        }
    }
    sess.seen_seq = ed.doc.edits.head();
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
    const ed = e.buf.editor;
    const w = wordBefore(ed.bytes(), ed.cursor);
    if (w.word.len == 0) return false;
    var scope_buf: [32]u8 = undefined;
    if (app.snippets.lookup(scopeFor(e.buf.doc.path, e.buf.editor.bytes(), &scope_buf), w.word) == null) return false;
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
    try testing.expectEqualStrings("rs", scopeFor("/x/a.RS", "", &buf));
    try testing.expectEqualStrings("global", scopeFor(null, "", &buf));
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

test "snippet.pick lists the file's scope and global sorted, pick_all every scope; Enter inserts the body at the cursor" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 60, .rows = 10 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/tmp/x.rs");
    // Nothing configured explains itself.
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"snippet.pick" }));
    try testing.expectEqualStrings("no snippets for scope rs (config `.snippets`)", app.lastToast().?);
    try app.snippets.seed("global", "todo", "// TODO: $1");
    try app.snippets.seed("rs", "fn", "fn $1() {\n    $0\n}");
    try app.snippets.seed("rs", "derive", "#[derive($1)]");
    try app.snippets.seed("py", "main", "if __name__ == '__main__':\n    $0");
    try command.run(&app, .{ .static = .@"snippet.pick" });
    try testing.expect(app.overlay == .picker);
    try testing.expectEqual(app_mod.PickerKind.snippets, app.overlay.picker.kind);
    const p = &app.overlay.picker;
    try testing.expectEqual(@as(usize, 3), p.labels.len);
    try testing.expectEqualStrings("todo", p.labels[0]);
    try testing.expectEqualStrings("derive", p.labels[1]);
    try testing.expectEqualStrings("fn", p.labels[2]);
    try testing.expectEqualStrings("rs", p.hints[2]);
    try testing.expectEqualStrings("fn $1() { ↵ $0 ↵ }", p.details[2]);
    // Enter on `fn` (the filtered index of the third row).
    const cmd_picker = @import("cmd_picker.zig");
    try cmd_picker.accept(&app, 2);
    try testing.expect(app.overlay == .none);
    try testing.expectEqualStrings("fn () {\n    \n}", e.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 3), e.buf.editor.cursor);
    try testing.expect(app.snippets.session != null);
    try command.run(&app, .{ .static = .@"snippet.pick_all" });
    try testing.expectEqual(@as(usize, 4), app.overlay.picker.labels.len);
    try testing.expectEqualStrings("main", app.overlay.picker.labels[1]);
    try testing.expectEqualStrings("py", app.overlay.picker.hints[1]);
    app.overlay.deinit(app.gpa);
}

test "snippet: a body expanded on an indented line carries the indent onto its later lines, stops and all" {
    var stops = [_]Stop{ .{ .pos = 4 }, .{ .pos = 8 }, .{ .pos = 15 } };
    // `for $1 in $2 {\n    $0\n}` parsed: stops at 4, 8 and 15.
    const out = try indentBody(testing.allocator, "for  in  {\n    \n}", "    ", &stops);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("for  in  {\n        \n    }", out);
    try testing.expectEqual(@as(usize, 4), stops[0].pos);
    try testing.expectEqual(@as(usize, 8), stops[1].pos);
    try testing.expectEqual(@as(usize, 19), stops[2].pos);
}

test "config: `.snippets` in the home config.zon fills the table at launch, by language name or extension, and a reload replaces it with seeds kept" {
    const t = std.testing;
    const config = @import("../config/root.zig");
    var vars = std.process.Environ.Map.init(t.allocator);
    defer vars.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &pbuf);
    const root = pbuf[0..n];
    try tmp.dir.createDirPath(t.io, "data");
    try tmp.dir.createDirPath(t.io, "ws");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/config.zon", .data =
        \\.{ .snippets = .{
        \\    .rust = .{ .fnrs = "fn $1() {}" },
        \\    .yml = .{ .job = "job: $1" },
        \\    .ts = .{ .ifc = "interface $1 {}" },
        \\    .global = .{ .todo = "// TODO: $1" },
        \\} }
    });
    const data = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data);
    const ws = try std.fs.path.join(t.allocator, &.{ root, "ws" });
    defer t.allocator.free(ws);
    try vars.put("MNML_DATA_ROOT", data);
    var loaded = try config.load.load(t.allocator, t.io, .{ .workspace = ws, .env = .{ .vars = &vars } });
    var app = try App.initWith(t.allocator, t.io, .{ .cfg = loaded.config, .loaded = loaded, .workspace = ws, .cols = 60, .rows = 12 });
    loaded = undefined; // the app owns it now
    defer app.deinit();
    app.tree.visible = false;
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("rs", scopeFor("/w/main.rs", "", &buf));
    try t.expectEqualStrings("fn $1() {}", app.snippets.lookup("rs", "fnrs").?);
    try t.expectEqualStrings("job: $1", app.snippets.lookup(scopeFor("/w/ci.yaml", "", &buf), "job").?);
    try t.expectEqualStrings("interface $1 {}", app.snippets.lookup(scopeFor("/w/App.tsx", "", &buf), "ifc").?);
    try t.expectEqualStrings("// TODO: $1", app.snippets.lookup("rs", "todo").?);
    // Typed in a buffer: the trigger expands.
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.setPath("/w/main.rs");
    for ("fnrs") |c| try app.handle(.{ .key = Key.char(c) });
    try command.run(&app, .{ .static = .@"snippet.expand" });
    try t.expectEqualStrings("fn () {}", e.buf.editor.bytes());
    app.snippets.endSession();
    // A seed (the `.test` directive) survives the reload; the reload
    // takes the file as it is now.
    try app.snippets.seed("rs", "seeded", "x");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/config.zon", .data = ".{ .snippets = .{ .rs = .{ .main = \"fn main() {}\" } } }" });
    try app.reloadConfig(.ask);
    try t.expect(app.snippets.lookup("rs", "fnrs") == null);
    try t.expect(app.snippets.lookup("rs", "todo") == null);
    try t.expectEqualStrings("fn main() {}", app.snippets.lookup("rs", "main").?);
    try t.expectEqualStrings("x", app.snippets.lookup("rs", "seeded").?);
    try t.expectEqual(@as(usize, 2), app.snippets.count());
}
