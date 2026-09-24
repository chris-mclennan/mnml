//! The quickfix list: vim's one app-wide list of places — `App.quickfix`.
//! Every producer writes it: a workspace grep (the grep pane and the
//! SEARCH section, as each run finishes), `:grep` / `:vimgrep`, a test
//! run with failures (vim's `:make`), `qf.from_diagnostics` (Neovim's
//! `vim.diagnostic.setqflist()`), `:cexpr` / `:cgetexpr`, the markdown
//! link check and the transcript search. The list outlives its pane:
//! `:copen` shows it in the `.quickfix` list pane, `:cclose` drops the
//! pane, `:cwindow` opens it only when there is something in it.
//!
//! `:cnext` / `:cprev` / `:cfirst` / `:clast` / `:cc [N]` (and the
//! `qf.*` ids) walk it: the entry's file opens, the cursor lands on its
//! line and column, and the toast reads `(i of n) text`. Off the end is
//! Neovim's `E553: No more items` — no wrap; an empty list is
//! `E42: No Errors`. `:clist` prints ` 1 a.txt:2 col 5: text`.
//!
//! A list a grep filled has no current entry until one is visited, so
//! the first `:cnext` lands on entry 1; Enter on a grep hit makes that
//! hit the current entry, so `:cnext` goes on from where the user is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const ListPane = app_mod.ListPane;
const Entry = ListPane.Entry;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const cmd_view = @import("cmd_view.zig");
const grep = @import("grep.zig");
const os_path = @import("../core/os_path.zig");
const document = @import("../editor/document.zig");

pub const State = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// The current entry; null before any is visited.
    idx: ?usize = null,
    /// The grep pane whose hits the list holds (its hit `i` is entry
    /// `i`), so Enter on a hit there moves `idx`.
    grep_pane: ?PaneId = null,
    /// `:grep`: the run this grep pane is doing jumps to its first hit
    /// once it finishes (Neovim's `:grep` without `!`).
    jump_when_done: ?PaneId = null,
    /// The list is `qf.from_diagnostics`': its entries move with the
    /// diagnostics they were made from (`followDiagnosticEdits`).
    from_diagnostics: bool = false,

    pub fn deinit(self: *State, gpa: Allocator) void {
        ListPane.freeEntries(gpa, self.entries.items);
        self.entries.deinit(gpa);
    }
};

pub const table = .{
    .@"qf.first" = &firstCmd,
    .@"qf.last" = &lastCmd,
    .@"qf.next" = &nextCmd,
    .@"qf.prev" = &prevCmd,
    .@"qf.open" = &open,
    .@"qf.close" = &close,
    .@"qf.from_diagnostics" = &fromDiagnostics,
};

fn firstCmd(app: *App) CommandError!void {
    return go(app, .first);
}
fn lastCmd(app: *App) CommandError!void {
    return go(app, .last);
}
fn nextCmd(app: *App) CommandError!void {
    return go(app, .next);
}
fn prevCmd(app: *App) CommandError!void {
    return go(app, .prev);
}

/// The one `.quickfix` list pane, if it is open.
fn listPane(app: *App) ?struct { id: PaneId, list: *ListPane } {
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .list => |*l| if (l.kind == .quickfix) return .{ .id = @intCast(i), .list = l },
        else => {},
    };
    return null;
}

/// Owned copies of `entries`, for the list pane.
fn copies(gpa: Allocator, entries: []const Entry) Allocator.Error![]Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        ListPane.freeEntries(gpa, out.items);
        out.deinit(gpa);
    }
    try out.ensureTotalCapacity(gpa, entries.len);
    for (entries) |e| {
        const text = try gpa.dupe(u8, e.text);
        errdefer gpa.free(text);
        const path: ?[]u8 = if (e.path) |p| try gpa.dupe(u8, p) else null;
        out.appendAssumeCapacity(.{ .text = text, .path = path, .line = e.line, .col = e.col });
    }
    return out.toOwnedSlice(gpa);
}

pub const Origin = struct {
    /// The current entry after the fill (`:cgetexpr` and `:cexpr` sit on
    /// entry 1; a grep has visited nothing yet).
    idx: ?usize = null,
    grep_pane: ?PaneId = null,
    from_diagnostics: bool = false,
};

/// Replace the list with `entries` (owned, taken even on error). An
/// open quickfix pane refills in place; the focus stays where it is.
pub fn set(app: *App, entries: []Entry, origin: Origin) Allocator.Error!void {
    const gpa = app.gpa;
    const q = &app.quickfix;
    ListPane.freeEntries(gpa, q.entries.items);
    q.entries.deinit(gpa);
    q.entries = .fromOwnedSlice(entries);
    q.idx = if (origin.idx) |i| (if (i < entries.len) i else null) else null;
    q.grep_pane = origin.grep_pane;
    q.from_diagnostics = origin.from_diagnostics;
    if (listPane(app)) |lp| {
        const fresh = try copies(gpa, q.entries.items);
        // The rows only: `ListPane.deinit` would leave the filter undefined.
        ListPane.freeEntries(gpa, lp.list.entries.items);
        lp.list.entries.deinit(gpa);
        lp.list.entries = .fromOwnedSlice(fresh);
        lp.list.cursor = q.idx orelse 0;
        lp.list.scroll = 0;
    }
    app.needs_render = true;
}

/// `set`, then show the list in its pane (focused) — for the producers
/// whose list IS their result view (`:cexpr`, the link check).
pub fn setAndOpen(app: *App, entries: []Entry, origin: Origin) CommandError!void {
    try set(app, entries, origin);
    return open(app);
}

/// A finished workspace grep's hits, in the order its rows show them.
/// `pane` is the grep pane, or `grep.section_target` for the SEARCH
/// section.
pub fn fromGrepHits(app: *App, hits: []const grep.Hit, pane: PaneId) Allocator.Error!void {
    const gpa = app.gpa;
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        ListPane.freeEntries(gpa, entries.items);
        entries.deinit(gpa);
    }
    try entries.ensureTotalCapacity(gpa, hits.len);
    for (hits) |h| {
        const text = try gpa.dupe(u8, std.mem.trim(u8, h.text, " \t"));
        errdefer gpa.free(text);
        const path = try gpa.dupe(u8, h.rel);
        entries.appendAssumeCapacity(.{ .text = text, .path = path, .line = h.line, .col = h.ccol + 1 });
    }
    const n = entries.items.len;
    try set(app, try entries.toOwnedSlice(gpa), .{ .grep_pane = pane });
    if (app.quickfix.jump_when_done == pane) {
        app.quickfix.jump_when_done = null;
        if (n > 0) go(app, .first) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
    }
}

/// Enter on grep hit `hit` of pane `pane`: when the list is that
/// pane's hits, the hit becomes the current entry.
pub fn noteGrepHit(app: *App, pane: PaneId, hit: usize) void {
    const q = &app.quickfix;
    if (q.grep_pane != pane) return;
    if (hit < q.entries.items.len) q.idx = hit;
}

/// Enter on row `idx` of the quickfix pane.
pub fn noteEnter(app: *App, idx: usize) void {
    if (idx < app.quickfix.entries.items.len) app.quickfix.idx = idx;
}

/// `path:line:col:text`, one entry per line; a line without colons is
/// its own path and text.
pub fn parseEntries(gpa: Allocator, args: []const u8) Allocator.Error![]Entry {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        ListPane.freeEntries(gpa, entries.items);
        entries.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, args, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // The path ends at its first colon — after a drive letter on
        // Windows (`C:\src\a.zig:12:3: msg`).
        const loc = os_path.splitLocation(line, .native);
        const path = loc.path;
        var parts = std.mem.splitScalar(u8, loc.rest, ':');
        const ln = std.fmt.parseInt(u32, parts.next() orelse "1", 10) catch 1;
        const col = std.fmt.parseInt(u32, parts.next() orelse "1", 10) catch 1;
        const text = parts.rest();
        const owned_text = try gpa.dupe(u8, if (text.len > 0) text else line);
        errdefer gpa.free(owned_text);
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        try entries.append(gpa, .{ .text = owned_text, .path = owned_path, .line = ln, .col = col });
    }
    return entries.toOwnedSlice(gpa);
}

/// `:cexpr` fills the list and shows it; `:cgetexpr` only fills it.
/// Either way entry 1 is the current one, so `:cnext` goes to entry 2.
pub fn cexpr(app: *App, args: []const u8, show: bool) CommandError!void {
    const entries = try parseEntries(app.gpa, args);
    if (show) return setAndOpen(app, entries, .{ .idx = 0 });
    try set(app, entries, .{ .idx = 0 });
    app.toast("quickfix: {d} entr{s}", .{ entries.len, if (entries.len == 1) "y" else "ies" });
}

/// `:copen` / `qf.open`: the list in its pane, focused, the cursor on
/// the current entry. An empty list opens an empty pane, as in vim.
pub fn open(app: *App) CommandError!void {
    const q = &app.quickfix;
    const fresh = try copies(app.gpa, q.entries.items);
    try cmd_view.openListPane(app, .quickfix, fresh);
    if (listPane(app)) |lp| {
        lp.list.cursor = q.idx orelse 0;
        app.focus = .{ .pane = lp.id };
    }
}

/// `:cwindow`: open when the list has entries, else close.
pub fn window(app: *App) CommandError!void {
    if (app.quickfix.entries.items.len == 0) return close(app);
    return open(app);
}

/// `:cclose` / `qf.close`: the pane goes; nothing open is not an error.
pub fn close(app: *App) CommandError!void {
    const lp = listPane(app) orelse return;
    try app.forceClosePane(lp.id);
}

pub const Where = union(enum) { first, last, next, prev, current, nth: usize };

/// Walk the list and open the entry the way Enter on its row does.
pub fn go(app: *App, where: Where) CommandError!void {
    const arena = app.frame.allocator();
    const q = &app.quickfix;
    const n = q.entries.items.len;
    if (n == 0) return app.diag.fail(arena, "E42: No Errors", .{});
    const idx: usize = switch (where) {
        .first => 0,
        .last => n - 1,
        .current => q.idx orelse 0,
        // `:cc N` past the end is the last entry (Neovim).
        .nth => |k| @min(k -| 1, n - 1),
        .next => if (q.idx) |i| (if (i + 1 < n) i + 1 else return app.diag.fail(arena, "E553: No more items", .{})) else 0,
        .prev => if (q.idx) |i| (if (i > 0) i - 1 else return app.diag.fail(arena, "E553: No more items", .{})) else return app.diag.fail(arena, "E553: No more items", .{}),
    };
    q.idx = idx;
    // Opening a file may add a pane: copy what the jump needs first.
    const entry = q.entries.items[idx];
    const text = try arena.dupe(u8, entry.text);
    const rel = try arena.dupe(u8, entry.path orelse return app.diag.fail(arena, "E42: entry {d} names no file", .{idx + 1}));
    const line = entry.line;
    const col = entry.col;
    const abs = try app.absPath(rel);
    const id = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return app.diag.fail(arena, "open {s}: {s}", .{ rel, @errorName(err) }),
    };
    if (app.panes.editor(id)) |ed| {
        // A grep's entry is found again by its line's text.
        const w: grep.Where = if (q.grep_pane != null) grep.relocate(ed.buf.editor, line, text, 0, true) else .{ .row = line -| 1 };
        ed.buf.editor.placeCursor(w.row, col -| 1);
        ed.buf.editor.goal_col = null;
        grep.noteRelocation(app, w, line);
    }
    if (listPane(app)) |lp| lp.list.cursor = idx;
    app.toast("({d} of {d}) {s}", .{ idx + 1, n, text });
    app.needs_render = true;
}

/// `:clist`: every entry as Neovim prints it — ` 1 a.txt:2 col 5: text`.
pub fn list(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const q = &app.quickfix;
    if (q.entries.items.len == 0) return app.diag.fail(arena, "E42: No Errors", .{});
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (q.entries.items, 0..) |e, i| {
        if (i > 0) try out.append(arena, '\n');
        try out.print(arena, "{d:>2} {s}:{d} col {d}: {s}", .{ i + 1, e.path orelse "", e.line, e.col, e.text });
    }
    try app.toastPersistent("ex:clist", out.items, .info);
}

/// `:grep {query}` (`!`: no jump): a workspace grep in the grep pane —
/// the query read as a regex, as `rg` reads it — whose hits fill the
/// list when the run finishes, then the first one opens.
pub fn grepEx(app: *App, args: []const u8, bang: bool) CommandError!void {
    const q = unquote(std.mem.trim(u8, args, " \t"));
    if (q.len == 0) return app.diag.fail(app.frame.allocator(), "E471: Argument required", .{});
    return runGrep(app, q, bang);
}

/// `:vimgrep /{pattern}/[g][j] {file}…` (or `:vimgrep {word} {file}…`):
/// the pattern is a vim pattern. `j` does not jump. The workspace is
/// searched; file arguments other than `**` / `%` are named in the
/// toast as not narrowing the search.
pub fn vimgrepEx(app: *App, args: []const u8, bang: bool) CommandError!void {
    const arena = app.frame.allocator();
    const a = std.mem.trim(u8, args, " \t");
    if (a.len == 0) return app.diag.fail(arena, "E683: File name missing or invalid pattern", .{});
    var pattern: []const u8 = undefined;
    var rest: []const u8 = undefined;
    var no_jump = bang;
    if (!std.ascii.isAlphanumeric(a[0]) and a[0] != '\\' and a[0] != '"' and a[0] != '|') {
        const delim = a[0];
        var i: usize = 1;
        while (i < a.len and a[i] != delim) : (i += 1) {
            if (a[i] == '\\') i += 1;
        }
        if (i >= a.len) return app.diag.fail(arena, "E683: File name missing or invalid pattern", .{});
        pattern = a[1..i];
        var j = i + 1;
        while (j < a.len and (a[j] == 'g' or a[j] == 'j' or a[j] == 'f')) : (j += 1) {
            if (a[j] == 'j') no_jump = true;
        }
        rest = std.mem.trim(u8, a[j..], " \t");
    } else {
        const sp = std.mem.indexOfAny(u8, a, " \t") orelse a.len;
        pattern = a[0..sp];
        rest = std.mem.trim(u8, a[sp..], " \t");
    }
    if (pattern.len == 0) {
        pattern = app.last_search_pattern orelse return app.diag.fail(arena, "E35: No previous regular expression", .{});
    }
    // As typed, in vim's syntax: the grep reads a `\m`-led query so.
    const q = try std.fmt.allocPrint(arena, "\\m{s}", .{pattern});
    try runGrep(app, q, no_jump);
    var files = std.mem.tokenizeAny(u8, rest, " \t");
    while (files.next()) |f| {
        if (std.mem.eql(u8, f, "**") or std.mem.eql(u8, f, "**/*") or std.mem.eql(u8, f, ".") or std.mem.eql(u8, f, "%")) continue;
        app.toast(":vimgrep searches the whole workspace — \"{s}\" does not narrow it", .{f});
        break;
    }
}

fn runGrep(app: *App, query: []const u8, no_jump: bool) CommandError!void {
    try grep.runGrepWith(app, query, true);
    const id = grep.find(app) orelse return;
    app.quickfix.jump_when_done = if (no_jump) null else id;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

/// `qf.from_diagnostics`: every LSP diagnostic in the workspace, by
/// file then position — Neovim's `vim.diagnostic.setqflist()`. The
/// list opens.
pub fn fromDiagnostics(app: *App) CommandError!void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = app.lsp.diags.iterator();
    while (it.next()) |kv| if (kv.value_ptr.*.items.len > 0) try paths.append(arena, kv.key_ptr.*);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        ListPane.freeEntries(gpa, entries.items);
        entries.deinit(gpa);
    }
    for (paths.items) |path| {
        const rel = app.relPath(path);
        // The places as the text reads now: a diagnostic behind an edit
        // not yet drawn is carried across it first.
        @import("lsp.zig").followDiagnosticsAt(app, path);
        for (app.lsp.diags.get(path).?.items) |d| {
            const sev: []const u8 = switch (d.severity) {
                .err => "error",
                .warning => "warning",
                .info => "info",
                .hint => "hint",
            };
            const text = try std.fmt.allocPrint(gpa, "{s}: {s}", .{ sev, d.message });
            errdefer gpa.free(text);
            const p = try gpa.dupe(u8, rel);
            errdefer gpa.free(p);
            try entries.append(gpa, .{ .text = text, .path = p, .line = d.range.start.line + 1, .col = d.range.start.character + 1 });
        }
    }
    if (entries.items.len == 0) {
        entries.deinit(gpa);
        return app.diag.fail(arena, "no diagnostics in the workspace", .{});
    }
    const n = entries.items.len;
    try setAndOpen(app, try entries.toOwnedSlice(gpa), .{ .from_diagnostics = true });
    app.toast("quickfix: {d} diagnostic{s}", .{ n, if (n == 1) "" else "s" });
}

/// The edits `recs` made to the file at `abs`, applied to the entries of
/// a list `qf.from_diagnostics` filled — and to the open list pane's
/// rows — as `lsp.followDiagnostics` applies them to the diagnostics:
/// an entry keeps pointing at its diagnostic's text (Neovim adjusts a
/// loaded buffer's quickfix entries the same way). A grep's entries are
/// found again by their line's text when opened instead (`go`).
pub fn followDiagnosticEdits(app: *App, abs: []const u8, recs: []const document.Splice) void {
    const q = &app.quickfix;
    if (!q.from_diagnostics or q.entries.items.len == 0) return;
    const rel = app.relPath(abs);
    shiftEntries(q.entries.items, rel, recs);
    if (listPane(app)) |lp| shiftEntries(lp.list.entries.items, rel, recs);
}

fn shiftEntries(entries: []Entry, rel: []const u8, recs: []const document.Splice) void {
    for (entries) |*e| {
        const p = e.path orelse continue;
        if (!std.mem.eql(u8, p, rel) or e.line == 0) continue;
        for (recs) |sp| {
            const at = sp.shiftPoint(.{ .row = e.line - 1, .col = e.col -| 1 });
            e.line = at.row + 1;
            e.col = at.col + 1;
        }
    }
}

/// A finished test run with failures fills the list with them, as
/// vim's `:make` does with a compiler's errors: `file:line` and the
/// test's name with the first line of its error.
pub fn fromTestFailures(app: *App, run: anytype) Allocator.Error!void {
    const gpa = app.gpa;
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    errdefer {
        ListPane.freeEntries(gpa, entries.items);
        entries.deinit(gpa);
    }
    for (run.tests) |tc| {
        if (tc.status != .failed or tc.file.len == 0) continue;
        const first = if (tc.err) |e| std.mem.trim(u8, e[0 .. std.mem.indexOfScalar(u8, e, '\n') orelse e.len], " \t\r") else "";
        const text = if (first.len > 0) try std.fmt.allocPrint(gpa, "{s}: {s}", .{ tc.title, first }) else try gpa.dupe(u8, tc.title);
        errdefer gpa.free(text);
        const p = try gpa.dupe(u8, tc.file);
        errdefer gpa.free(p);
        try entries.append(gpa, .{ .text = text, .path = p, .line = @max(tc.line, 1), .col = 1 });
    }
    if (entries.items.len == 0) {
        entries.deinit(gpa);
        return;
    }
    try set(app, try entries.toOwnedSlice(gpa), .{});
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    app: App,
    tmp: testing.TmpDir,
    root: []u8,

    fn init(src: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 60, .rows = 12 });
        errdefer app.deinit();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "doc.txt", .data = src });
        _ = try app.openPath(try std.fs.path.join(app.frame.allocator(), &.{ root, "doc.txt" }));
        return .{ .app = app, .tmp = tmp, .root = root };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn ex(f: *Fixture, line: []const u8) !void {
        f.app.frame.begin();
        try @import("ex.zig").run(&f.app, line);
    }

    fn row(f: *Fixture) usize {
        return f.app.activeEditor().?.buf.editor.rowCol().row;
    }
};

test "quickfix: an empty list is E42; cgetexpr sits on entry 1, cnext / cprev stop at E553, cc N clamps, clist prints Neovim's rows" {
    var f = try Fixture.init("one\ntwo\nthree\nfour\n");
    defer f.deinit();
    try testing.expectError(error.Failed, f.ex("cn"));
    try testing.expectEqualStrings("E42: No Errors", f.app.diag.msg.?);
    try testing.expectError(error.Failed, f.ex("clist"));
    try f.ex("cgetexpr doc.txt:2:1:two here\ndoc.txt:4:3:four here\ndoc.txt:3:2:three here");
    try testing.expectEqual(@as(usize, 3), f.app.quickfix.entries.items.len);
    try testing.expectEqual(@as(?usize, 0), f.app.quickfix.idx);
    try f.ex("cnext");
    try testing.expectEqual(@as(usize, 3), f.row());
    try testing.expectEqualStrings("(2 of 3) four here", f.app.lastToast().?);
    try f.ex("cn");
    try testing.expectError(error.Failed, f.ex("cn"));
    try testing.expectEqualStrings("E553: No more items", f.app.diag.msg.?);
    try testing.expectEqual(@as(usize, 2), f.row());
    try f.ex("cc 1");
    try testing.expectEqual(@as(usize, 1), f.row());
    try testing.expectError(error.Failed, f.ex("cprev"));
    try testing.expectEqualStrings("E553: No more items", f.app.diag.msg.?);
    try f.ex("cc 9");
    try testing.expectEqualStrings("(3 of 3) three here", f.app.lastToast().?);
    try f.ex("clist");
    try testing.expectEqualStrings(" 1 doc.txt:2 col 1: two here\n 2 doc.txt:4 col 3: four here\n 3 doc.txt:3 col 2: three here", f.app.lastToast().?);
}

test "quickfix: a grep's hits fill the list with no current entry; Enter on a hit makes it current; the list outlives its pane" {
    var f = try Fixture.init("alpha\nbeta alpha\n");
    defer f.deinit();
    const hits = [_]grep.Hit{
        .{ .path = "/x/doc.txt", .rel = "doc.txt", .line = 1, .col = 0, .len = 5, .text = "alpha" },
        .{ .path = "/x/doc.txt", .rel = "doc.txt", .line = 2, .col = 5, .len = 5, .text = "beta alpha", .ccol = 5 },
    };
    try fromGrepHits(&f.app, &hits, 7);
    try testing.expect(f.app.quickfix.idx == null);
    try testing.expectEqual(@as(u32, 6), f.app.quickfix.entries.items[1].col);
    noteGrepHit(&f.app, 8, 1); // another pane's hit: not this list
    try testing.expect(f.app.quickfix.idx == null);
    noteGrepHit(&f.app, 7, 0);
    try testing.expectEqual(@as(?usize, 0), f.app.quickfix.idx);
    try f.ex("copen");
    try testing.expect(listPane(&f.app) != null);
    // Refilled twice while open (the pane's filter stays intact).
    try fromGrepHits(&f.app, &hits, 7);
    try fromGrepHits(&f.app, hits[0..1], 7);
    try testing.expectEqual(@as(usize, 1), listPane(&f.app).?.list.entries.items.len);
    try f.ex("cclose");
    try testing.expect(listPane(&f.app) == null);
    try f.ex("cnext");
    try testing.expectEqual(@as(usize, 0), f.row());
    try f.ex("cw");
    try testing.expect(listPane(&f.app) != null);
}

test "quickfix: a test run's failures and the workspace's diagnostics each become the list" {
    var f = try Fixture.init("one\ntwo\nthree\n");
    defer f.deinit();
    const Case = struct { title: []const u8, file: []const u8, line: u32, status: enum { passed, failed }, err: ?[]const u8 };
    const run = struct { tests: []const Case }{ .tests = &.{
        .{ .title = "adds", .file = "doc.txt", .line = 2, .status = .failed, .err = "expected 2\nfound 3" },
        .{ .title = "subtracts", .file = "doc.txt", .line = 3, .status = .passed, .err = null },
        .{ .title = "divides", .file = "doc.txt", .line = 3, .status = .failed, .err = null },
    } };
    try fromTestFailures(&f.app, run);
    try testing.expectEqual(@as(usize, 2), f.app.quickfix.entries.items.len);
    try testing.expectEqualStrings("adds: expected 2", f.app.quickfix.entries.items[0].text);
    try f.ex("cn");
    try testing.expectEqual(@as(usize, 1), f.row());
    try f.ex("cn");
    try testing.expectEqualStrings("(2 of 2) divides", f.app.lastToast().?);

    const abs = try std.fs.path.join(testing.allocator, &.{ f.root, "doc.txt" });
    defer testing.allocator.free(abs);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[{\"range\":{\"start\":{\"line\":2,\"character\":1},\"end\":{\"line\":2,\"character\":3}},\"severity\":1,\"message\":\"bad three\"},{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"severity\":2,\"message\":\"odd one\"}]", .{});
    defer parsed.deinit();
    try @import("lsp.zig").applyDiagnostics(&f.app, abs, parsed.value.array.items);
    try command.run(&f.app, .{ .static = .@"qf.from_diagnostics" });
    try testing.expectEqual(@as(usize, 2), f.app.quickfix.entries.items.len);
    try testing.expectEqualStrings("warning: odd one", f.app.quickfix.entries.items[0].text);
    try testing.expectEqualStrings("doc.txt", f.app.quickfix.entries.items[1].path.?);
    try testing.expectEqual(@as(u32, 3), f.app.quickfix.entries.items[1].line);
    try testing.expectEqual(@as(u32, 2), f.app.quickfix.entries.items[1].col);
    try testing.expect(listPane(&f.app) != null);
}
