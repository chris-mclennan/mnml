//! The `:` line. A range, a verb, its arguments — the vim subset mnml
//! answers today: files (`:w :q :wq :x :e :bd :bn :bp :A`), text
//! (`:s :sort :retab :d :<n>`), settings (`:set :ab :una :noh`), and the
//! read-outs (`:reg :marks`). A verb nobody here knows is tried as a
//! registered command id (`:tab.close`), then reported.
//!
//! Errors travel as `CommandError`: the reason goes in `app.diag`, the
//! caller (`dispatch.runExLine`, the dyn registry) toasts it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const find_mod = @import("find.zig");
const editor_mod = @import("../editor/editor.zig");
const Editor = editor_mod.Editor;
const input = @import("../input/mod.zig");

/// 0-based inclusive rows.
pub const Range = struct { first: usize, last: usize };

pub fn run(app: *App, line_in: []const u8) CommandError!void {
    var line = std.mem.trim(u8, line_in, " \t\r\n");
    while (line.len > 0 and line[0] == ':') line = std.mem.trimStart(u8, line[1..], " \t");
    if (line.len == 0) return;
    const arena = app.frame.allocator();

    var p = Parser{ .s = line };
    const range = try p.parseRange(app);
    p.skipWs();
    const rest = p.rest();

    // A bare address is a jump: `:5`, `:$`, `:'a`.
    if (rest.len == 0) {
        const r = range orelse return;
        const e = try editor(app, ":<n>");
        const row = @min(r.last, e.buf.editor.lineCount() - 1);
        e.buf.editor.setCursor(e.buf.editor.firstNonWs(row));
        e.buf.editor.goal_col = null;
        app.needs_render = true;
        return;
    }

    // `:s/…/…/` — the verb is one letter followed by a delimiter.
    if (rest[0] == 's' and rest.len > 1 and !std.ascii.isAlphanumeric(rest[1]) and rest[1] != ' ' and rest[1] != '!') {
        return substitute(app, range, rest[1..], p.saw_percent);
    }
    if (std.mem.startsWith(u8, rest, "substitute") and rest.len > "substitute".len and !std.ascii.isAlphanumeric(rest["substitute".len])) {
        return substitute(app, range, rest["substitute".len..], p.saw_percent);
    }
    if (rest[0] == '&') return app.diag.fail(arena, ":& — no previous substitute", .{});

    var i: usize = 0;
    while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '.' or rest[i] == '_')) i += 1;
    var verb = rest[0..i];
    var bang = false;
    if (i < rest.len and rest[i] == '!') {
        bang = true;
        i += 1;
    }
    if (verb.len == 0 and i == 0) {
        // A lone punctuation verb: `:!cmd`, `:<`, `:>`.
        verb = rest[0..1];
        i = 1;
    }
    const args = std.mem.trim(u8, rest[i..], " \t");

    if (eqAny(verb, &.{ "w", "write" })) return write(app, args, false);
    if (eqAny(verb, &.{ "wa", "wall" })) return saveAll(app);
    if (eqAny(verb, &.{ "wq", "x", "xit", "exit" })) return write(app, args, true);
    if (eqAny(verb, &.{ "wqa", "wqall", "xa", "xall" })) {
        try saveAll(app);
        app.quit = true;
        return;
    }
    if (eqAny(verb, &.{ "q", "quit", "clo", "close" })) return quit(app, bang);
    if (eqAny(verb, &.{ "qa", "qall", "quitall", "quita" })) {
        if (!bang and app.anyDirty()) return app.diag.fail(arena, "unsaved changes — use :qa! to discard", .{});
        app.quit = true;
        return;
    }
    if (eqAny(verb, &.{ "e", "ed", "edit" })) return edit(app, args, bang);
    if (eqAny(verb, &.{"enew"})) {
        _ = app.openScratch() catch return error.OutOfMemory;
        return;
    }
    if (eqAny(verb, &.{ "bd", "bdelete", "bw", "bwipeout" })) {
        const id = app.active orelse return error.NoActivePane;
        return app.closePane(id, bang);
    }
    if (eqAny(verb, &.{ "bn", "bnext" })) return command.run(app, .{ .static = .@"buffer.next" });
    if (eqAny(verb, &.{ "bp", "bprev", "bprevious", "bN", "bNext" })) return command.run(app, .{ .static = .@"buffer.prev" });
    if (eqAny(verb, &.{ "ls", "buffers", "files" })) return command.run(app, .{ .static = .@"picker.buffers" });
    if (eqAny(verb, &.{"A"})) return alternate(app);
    if (eqAny(verb, &.{ "sor", "sort" })) return sort(app, range, args, bang);
    if (eqAny(verb, &.{ "ret", "retab" })) return retab(app);
    if (eqAny(verb, &.{ "d", "de", "del", "delete" })) return deleteLines(app, range);
    if (eqAny(verb, &.{ "ab", "abb", "abbreviate", "iab", "iabbrev" })) return abbreviate(app, args);
    if (eqAny(verb, &.{ "una", "unabbreviate", "iuna", "iunabbrev" })) return unabbreviate(app, args);
    if (eqAny(verb, &.{ "reg", "registers", "di", "display" })) return registers(app, args);
    if (eqAny(verb, &.{"marks"})) return marks(app);
    if (eqAny(verb, &.{ "delm", "delmarks" })) return delmarks(app, args, bang);
    if (eqAny(verb, &.{ "se", "set" })) return set(app, args);
    if (eqAny(verb, &.{ "noh", "nohlsearch", "nohl" })) return command.run(app, .{ .static = .@"find.clear" });
    if (eqAny(verb, &.{ "echo", "Echo" })) {
        app.toast("{s}", .{args});
        return;
    }
    if (eqAny(verb, &.{ "sp", "split" })) return command.run(app, .{ .static = .@"view.split_down" });
    if (eqAny(verb, &.{ "vs", "vsplit" })) return command.run(app, .{ .static = .@"view.split_right" });
    if (eqAny(verb, &.{ "on", "only" })) return command.run(app, .{ .static = .@"view.close_others" });
    if (eqAny(verb, &.{ "tabnew", "tabe", "tabedit" })) return command.run(app, .{ .static = .@"tab.new" });
    if (eqAny(verb, &.{ "tabn", "tabnext" })) return command.run(app, .{ .static = .@"tab.next" });
    if (eqAny(verb, &.{ "tabp", "tabprev", "tabprevious", "tabN", "tabNext" })) return command.run(app, .{ .static = .@"tab.prev" });
    if (eqAny(verb, &.{ "tabfir", "tabfirst", "tabr", "tabrewind" })) return command.run(app, .{ .static = .@"tab.first" });
    if (eqAny(verb, &.{ "tabl", "tablast" })) return command.run(app, .{ .static = .@"tab.last" });
    if (eqAny(verb, &.{ "tabc", "tabclose" })) return command.run(app, .{ .static = .@"tab.close" });
    if (eqAny(verb, &.{ "tabo", "tabonly" })) return command.run(app, .{ .static = .@"tab.only" });
    if (eqAny(verb, &.{"tabs"})) return command.run(app, .{ .static = .@"tab.list" });
    if (eqAny(verb, &.{ "term", "terminal" })) return @import("cmd_term.zig").termEx(app, args);
    if (eqAny(verb, &.{"task"})) return @import("tasks.zig").runNamed(app, args);

    // A registered command by id.
    if (command.resolve(app, verb)) |ref| return command.run(app, ref);
    return app.diag.fail(arena, ":{s} — unknown command", .{verb});
}

fn eqAny(s: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, s, l)) return true;
    return false;
}

fn editor(app: *App, label: []const u8) CommandError!*EditorPane {
    return app.requireEditor() catch |err| {
        return app.diag.fail(app.frame.allocator(), "{s} — no active editor", .{label}) catch err;
    };
}

// ─── ranges ─────────────────────────────────────────────────────────────

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    saw_percent: bool = false,

    fn rest(p: *const Parser) []const u8 {
        return p.s[p.i..];
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn skipWs(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    /// `%` | addr [, addr]. Null when the line has no range.
    fn parseRange(p: *Parser, app: *App) CommandError!?Range {
        p.skipWs();
        if (p.peek() == '%') {
            p.i += 1;
            p.saw_percent = true;
            const e = app.activeEditor() orelse return .{ .first = 0, .last = 0 };
            return .{ .first = 0, .last = e.buf.editor.lineCount() - 1 };
        }
        const a = try p.parseAddr(app) orelse return null;
        p.skipWs();
        if (p.peek() == ',' or p.peek() == ';') {
            p.i += 1;
            p.skipWs();
            const b = try p.parseAddr(app) orelse a;
            return .{ .first = @min(a, b), .last = @max(a, b) };
        }
        return .{ .first = a, .last = a };
    }

    /// One address: a line number (1-based), `.`, `$`, `'x`, with an
    /// optional `+n` / `-n`. 0-based row out.
    fn parseAddr(p: *Parser, app: *App) CommandError!?usize {
        const arena = app.frame.allocator();
        const e = app.activeEditor();
        const count: usize = if (e) |ed| ed.buf.editor.lineCount() else 1;
        var base: ?usize = null;
        const c = p.peek() orelse return null;
        if (std.ascii.isDigit(c)) {
            var j = p.i;
            while (j < p.s.len and std.ascii.isDigit(p.s[j])) j += 1;
            const n = std.fmt.parseInt(usize, p.s[p.i..j], 10) catch return null;
            p.i = j;
            base = n -| 1;
        } else if (c == '.') {
            p.i += 1;
            base = if (e) |ed| ed.buf.editor.currentLine() else 0;
        } else if (c == '$') {
            p.i += 1;
            base = count - 1;
        } else if (c == '\'') {
            if (p.i + 1 >= p.s.len) return app.diag.fail(arena, "E20: mark not set", .{});
            const m = p.s[p.i + 1];
            p.i += 2;
            const ed = e orelse return app.diag.fail(arena, "no active editor", .{});
            base = switch (m) {
                '<' => if (ed.buf.editor.last_selection) |s| ed.buf.editor.lineOfByte(@min(s[0], s[1])) else return app.diag.fail(arena, "E20: mark '< not set", .{}),
                '>' => if (ed.buf.editor.last_selection) |s| blk: {
                    // A linewise selection ends on the row AFTER the last
                    // selected line; step back when it sits at column 0.
                    const hi = @max(s[0], s[1]);
                    const row = ed.buf.editor.lineOfByte(hi);
                    break :blk if (hi > 0 and hi == ed.buf.editor.lineStart(row) and row > ed.buf.editor.lineOfByte(@min(s[0], s[1]))) row - 1 else row;
                } else return app.diag.fail(arena, "E20: mark '> not set", .{}),
                else => if (ed.buf.marks.get(m)) |pos| pos.row else return app.diag.fail(arena, "E20: mark '{c} not set", .{m}),
            };
        } else if (c == '+' or c == '-') {
            base = if (e) |ed| ed.buf.editor.currentLine() else 0;
        } else return null;
        // Offsets.
        while (p.peek()) |o| {
            if (o != '+' and o != '-') break;
            p.i += 1;
            var j = p.i;
            while (j < p.s.len and std.ascii.isDigit(p.s[j])) j += 1;
            const n: usize = if (j == p.i) 1 else std.fmt.parseInt(usize, p.s[p.i..j], 10) catch 1;
            p.i = j;
            base = if (o == '+') base.? + n else base.? -| n;
        }
        return @min(base.?, count -| 1);
    }
};

// ─── files ──────────────────────────────────────────────────────────────

fn write(app: *App, path_arg: []const u8, then_close: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":w");
    if (path_arg.len > 0) {
        const abs = try app.absPath(path_arg);
        e.buf.setPath(abs) catch return error.OutOfMemory;
        e.syntax.setLanguage(abs);
        e.hl_dirty = true;
    }
    const path = e.buf.path orelse return app.diag.fail(arena, ":w — no file name (use :w <path>)", .{});
    const rel = app.relPath(path);
    app.hooks.emit(app, .{ .save_pre = .{ .path = rel, .pane = app.active.? } });
    e.buf.save(app.io) catch |err| return app.diag.fail(arena, ":w — {s}: {s}", .{ rel, @errorName(err) });
    app.hooks.emit(app, .{ .save_post = .{ .path = rel, .pane = app.active.?, .bytes = e.buf.editor.len() } });
    app.toast("saved {s}", .{rel});
    if (then_close) {
        try app.forceClosePane(app.active.?);
        if (app.panes.count() == 0) app.quit = true;
    }
}

fn saveAll(app: *App) CommandError!void {
    var n: usize = 0;
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .editor => |*e| if (e.buf.dirty and e.buf.path != null) {
            e.buf.save(app.io) catch |err| return app.diag.fail(app.frame.allocator(), ":wa — {s}: {s}", .{ app.relPath(e.buf.path.?), @errorName(err) });
            n += 1;
        },
        .pty => {},
    };
    app.toast("saved {d} file(s)", .{n});
}

fn quit(app: *App, bang: bool) CommandError!void {
    const id = app.active orelse {
        app.quit = true;
        return;
    };
    const pane = app.panes.get(id).?;
    if (!bang and pane.dirty()) {
        return app.diag.fail(app.frame.allocator(), "unsaved changes in {s} — use :q! to discard", .{pane.title()});
    }
    try app.forceClosePane(id);
    if (app.panes.count() == 0) app.quit = true;
}

fn edit(app: *App, arg: []const u8, bang: bool) CommandError!void {
    const arena = app.frame.allocator();
    if (arg.len == 0 or std.mem.eql(u8, arg, "%")) {
        // Reload from disk; `:e!` discards unsaved changes.
        const e = try editor(app, ":e");
        const path = e.buf.path orelse return app.diag.fail(arena, ":e — no file name", .{});
        if (e.buf.dirty and !bang) return app.diag.fail(arena, ":e — unsaved changes (use :e! to discard)", .{});
        @import("watch.zig").reload(app, app.active.?) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return app.diag.fail(arena, ":e — {s}", .{@errorName(err)}),
        };
        app.toast("reloaded {s}", .{app.relPath(path)});
        return;
    }
    const abs = try app.absPath(arg);
    _ = app.openPath(abs) catch |err| return app.diag.fail(arena, ":e {s} — {s}", .{ arg, @errorName(err) });
}

/// `:A` — the test ↔ source counterpart of the active file.
fn alternate(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":A");
    const path = e.buf.path orelse return app.diag.fail(arena, ":A — no active file", .{});
    const dir = std.fs.path.dirname(path) orelse "";
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(base);
    const stem = base[0 .. base.len - ext.len];
    var cands: std.ArrayListUnmanaged([]const u8) = .empty;
    const suffixes = [_][]const u8{ "_test", "_spec", ".test", ".spec" };
    var stripped = false;
    for (suffixes) |suf| {
        if (std.mem.endsWith(u8, stem, suf)) {
            try cands.append(arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ stem[0 .. stem.len - suf.len], ext }));
            stripped = true;
        }
    }
    if (!stripped) {
        for (suffixes) |suf| try cands.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ stem, suf, ext }));
    }
    for (cands.items) |name| {
        const full = try std.fs.path.join(arena, &.{ dir, name });
        _ = std.Io.Dir.cwd().statFile(app.io, full, .{}) catch continue;
        _ = app.openPath(full) catch |err| return app.diag.fail(arena, ":A — {s}", .{@errorName(err)});
        return;
    }
    return app.diag.fail(arena, ":A — no alternate file found", .{});
}

// ─── text ───────────────────────────────────────────────────────────────

/// `s/pat/rep/[g][i][I]` over `range` (default: the cursor's line).
fn substitute(app: *App, range: ?Range, spec: []const u8, whole: bool) CommandError!void {
    const arena = app.frame.allocator();
    const label: []const u8 = if (whole) ":%s" else ":s";
    const e = try editor(app, label);
    const ed = &e.buf.editor;
    if (spec.len == 0) return app.diag.fail(arena, "{s} — usage: {s}/old/new/[g]", .{ label, label });
    const delim = spec[0];
    var parts: [3][]const u8 = .{ "", "", "" };
    var n_parts: usize = 0;
    var start: usize = 1;
    var j: usize = 1;
    while (j <= spec.len and n_parts < 3) : (j += 1) {
        if (j == spec.len or (spec[j] == delim and (j == 0 or spec[j - 1] != '\\'))) {
            parts[n_parts] = spec[start..j];
            n_parts += 1;
            start = j + 1;
        }
    }
    if (n_parts == 0 or parts[0].len == 0) return app.diag.fail(arena, "{s} — empty pattern", .{label});
    var pat_buf: [256]u8 = undefined;
    const needle = find_mod.unescape(parts[0], &pat_buf);
    var rep_buf: [256]u8 = undefined;
    const replacement = find_mod.unescape(parts[1], &rep_buf);
    var global = false;
    var case: ?bool = null;
    for (parts[2]) |f| switch (f) {
        'g' => global = true,
        'i' => case = false,
        'I' => case = true,
        else => {},
    };
    const case_sensitive = case orelse app.search_case orelse find_mod.hasUpper(needle);

    const r = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;
    var row = first;
    while (row <= last) : (row += 1) {
        const line = ed.lineSlice(row);
        var i: usize = 0;
        var replaced_here = false;
        while (i < line.len) {
            if (needle.len > 0 and i + needle.len <= line.len and (!replaced_here or global)) {
                const hay = line[i .. i + needle.len];
                const hit = if (case_sensitive) std.mem.eql(u8, hay, needle) else std.ascii.eqlIgnoreCase(hay, needle);
                if (hit) {
                    try out.appendSlice(arena, replacement);
                    i += needle.len;
                    count += 1;
                    replaced_here = true;
                    continue;
                }
            }
            try out.append(arena, line[i]);
            i += 1;
        }
        if (row < last) try out.append(arena, '\n');
    }
    if (count == 0) {
        app.toast("{s} — no match for \"{s}\"", .{ label, needle });
        return;
    }
    try app.splice(e, ed.lineStart(first), ed.lineEnd(last), out.items);
    ed.setCursor(ed.firstNonWs(@min(last, ed.lineCount() - 1)));
    ed.goal_col = null;
    app.toast("{s} — {d} replacement(s)", .{ label, count });
}

/// `:sort [u] [r] [i] [n]`; `:sort!` reverses.
fn sort(app: *App, range: ?Range, flags: []const u8, bang: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":sort");
    const ed = &e.buf.editor;
    var unique = false;
    var reverse = bang;
    var icase = false;
    var numeric = false;
    for (flags) |f| switch (f) {
        'u' => unique = true,
        'r' => reverse = true,
        'i' => icase = true,
        'n' => numeric = true,
        else => {},
    };
    const r = range orelse Range{ .first = 0, .last = ed.lineCount() - 1 };
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    var row = first;
    while (row <= last) : (row += 1) try lines.append(arena, ed.lineSlice(row));
    const Ctx = struct {
        icase: bool,
        numeric: bool,
        fn num(s: []const u8) ?i64 {
            var i: usize = 0;
            while (i < s.len and !std.ascii.isDigit(s[i]) and !(s[i] == '-' and i + 1 < s.len and std.ascii.isDigit(s[i + 1]))) i += 1;
            if (i == s.len) return null;
            var j = i + 1;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            return std.fmt.parseInt(i64, s[i..j], 10) catch null;
        }
        fn lt(c: @This(), a: []const u8, b: []const u8) bool {
            if (c.numeric) {
                const na = num(a);
                const nb = num(b);
                if (na == null and nb == null) return false;
                if (na == null) return true;
                if (nb == null) return false;
                return na.? < nb.?;
            }
            if (c.icase) {
                const n = @min(a.len, b.len);
                for (a[0..n], b[0..n]) |x, y| {
                    const lx = std.ascii.toLower(x);
                    const ly = std.ascii.toLower(y);
                    if (lx != ly) return lx < ly;
                }
                return a.len < b.len;
            }
            return std.mem.lessThan(u8, a, b);
        }
    };
    std.mem.sort([]const u8, lines.items, Ctx{ .icase = icase, .numeric = numeric }, Ctx.lt);
    if (reverse) std.mem.reverse([]const u8, lines.items);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var kept: usize = 0;
    var prev: ?[]const u8 = null;
    for (lines.items) |l| {
        if (unique and prev != null and std.mem.eql(u8, prev.?, l)) continue;
        if (kept > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, l);
        kept += 1;
        prev = l;
    }
    try app.splice(e, ed.lineStart(first), ed.lineEnd(last), out.items);
    ed.setCursor(ed.lineStart(first));
    ed.goal_col = null;
    app.toast(":sort{s}{s}{s}{s} — {d} line(s)", .{
        if (unique) " u" else "",
        if (reverse) " r" else "",
        if (icase) " i" else "",
        if (numeric) " n" else "",
        kept,
    });
}

/// `:retab` — every TAB becomes spaces to the next tab stop.
fn retab(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":retab");
    const ed = &e.buf.editor;
    const tw: usize = @max(ed.tab_width, 1);
    const text = ed.bytes();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var col: usize = 0;
    var tabs: usize = 0;
    for (text) |c| {
        switch (c) {
            '\t' => {
                const n = tw - (col % tw);
                try out.appendNTimes(arena, ' ', n);
                col += n;
                tabs += 1;
            },
            '\n' => {
                try out.append(arena, c);
                col = 0;
            },
            else => {
                try out.append(arena, c);
                col += 1;
            },
        }
    }
    if (tabs == 0) {
        app.toast(":retab — no tabs", .{});
        return;
    }
    const cursor = ed.cursor;
    try app.splice(e, 0, text.len, out.items);
    ed.setCursor(cursor);
    app.toast(":retab — {d} tab(s)", .{tabs});
}

/// `:[range]d` — delete whole lines into the unnamed register.
fn deleteLines(app: *App, range: ?Range) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":d");
    const ed = &e.buf.editor;
    const r = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    const start = ed.lineStart(first);
    const end = ed.lineEnd(last);
    const copy = try std.mem.concat(arena, u8, &.{ ed.bytes()[start..end], "\n" });
    try app.clipboard.pushDelete(copy, true);
    const del_start = if (end < ed.len()) start else if (start > 0) start - 1 else start;
    const del_end = if (end < ed.len()) end + 1 else end;
    try app.splice(e, del_start, del_end, "");
    const row = @min(first, ed.lineCount() - 1);
    ed.setCursor(ed.firstNonWs(row));
    ed.goal_col = null;
    app.toast(":d — {d} line(s)", .{last - first + 1});
}

// ─── settings + read-outs ───────────────────────────────────────────────

fn abbreviate(app: *App, args: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const sp = std.mem.indexOfAny(u8, args, " \t") orelse {
        if (args.len == 0) {
            if (app.abbrevs.count() == 0) {
                app.toast(":ab — none", .{});
                return;
            }
            var parts: std.ArrayListUnmanaged(u8) = .empty;
            var it = app.abbrevs.iterator();
            while (it.next()) |kv| try parts.print(arena, "{s}{s} → {s}", .{ if (parts.items.len > 0) "  " else "", kv.key_ptr.*, kv.value_ptr.* });
            app.toast(":ab · {s}", .{parts.items});
            return;
        }
        return app.diag.fail(arena, ":ab — usage: :ab <lhs> <rhs>", .{});
    };
    const lhs = args[0..sp];
    const rhs = std.mem.trim(u8, args[sp..], " \t");
    if (rhs.len == 0) return app.diag.fail(arena, ":ab — usage: :ab <lhs> <rhs>", .{});
    const gpa = app.gpa;
    const value = try gpa.dupe(u8, rhs);
    errdefer gpa.free(value);
    if (app.abbrevs.getPtr(lhs)) |slot| {
        gpa.free(slot.*);
        slot.* = value;
    } else {
        const key = try gpa.dupe(u8, lhs);
        errdefer gpa.free(key);
        try app.abbrevs.put(gpa, key, value);
    }
    app.toast(":ab {s} → {s}", .{ lhs, rhs });
}

fn unabbreviate(app: *App, args: []const u8) CommandError!void {
    const lhs = std.mem.trim(u8, args, " \t");
    if (lhs.len == 0) return app.diag.fail(app.frame.allocator(), ":una — usage: :una <lhs>", .{});
    if (app.abbrevs.fetchRemove(lhs)) |kv| {
        app.gpa.free(kv.key);
        app.gpa.free(kv.value);
        app.toast(":una {s} — removed", .{lhs});
    } else app.toast(":una {s} — no such abbreviation", .{lhs});
}

/// Up to `cap` chars with newlines shown as `↵`, `…` when cut.
fn preview(arena: Allocator, s: []const u8, cap: usize) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |g| {
        if (n == cap) {
            try out.appendSlice(arena, "…");
            break;
        }
        if (g.len == 1 and g[0] == '\n') try out.appendSlice(arena, "↵") else try out.appendSlice(arena, g);
        n += 1;
    }
    return out.items;
}

/// `:reg [names]` — a persistent toast listing the registers.
fn registers(app: *App, filter: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    const want = std.mem.trim(u8, filter, " \t");
    const show_unnamed = want.len == 0 or std.mem.indexOfScalar(u8, want, '"') != null;
    if (show_unnamed) if (app.clipboard.unnamed) |u| if (u.text.len > 0) {
        try parts.print(arena, "\"\"  {s}", .{try preview(arena, u.text, 40)});
    };
    var names: std.ArrayListUnmanaged(u8) = .empty;
    var it = app.clipboard.named.keyIterator();
    while (it.next()) |k| try names.append(arena, k.*);
    std.mem.sort(u8, names.items, {}, std.sort.asc(u8));
    for (names.items) |c| {
        if (want.len > 0 and std.mem.indexOfScalar(u8, want, c) == null) continue;
        const entry = app.clipboard.named.get(c).?;
        if (entry.text.len == 0) continue;
        if (parts.items.len > 0) try parts.appendSlice(arena, "  ");
        try parts.print(arena, "\"{c}  {s}", .{ c, try preview(arena, entry.text, 40) });
    }
    const msg = if (parts.items.len == 0) ":reg — empty" else try std.fmt.allocPrint(arena, ":reg · {s}", .{parts.items});
    try app.toastPersistent("ex:reg", msg, .info);
}

fn marks(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":marks");
    var names: std.ArrayListUnmanaged(u8) = .empty;
    var it = e.buf.marks.keyIterator();
    while (it.next()) |k| try names.append(arena, k.*);
    if (names.items.len == 0) {
        app.toast(":marks — none set", .{});
        return;
    }
    std.mem.sort(u8, names.items, {}, std.sort.asc(u8));
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    for (names.items, 0..) |c, i| {
        const pos = e.buf.marks.get(c).?;
        try parts.print(arena, "{s}'{c}@{d}:{d}", .{ if (i > 0) "  " else "", c, pos.row + 1, pos.col + 1 });
    }
    app.toast(":marks · {s}", .{parts.items});
}

fn delmarks(app: *App, args: []const u8, bang: bool) CommandError!void {
    const e = try editor(app, ":delmarks");
    if (bang) {
        const n = e.buf.marks.count();
        e.buf.marks.clearRetainingCapacity();
        app.toast(":delmarks! — cleared {d} local mark(s)", .{n});
        return;
    }
    var n: usize = 0;
    for (std.mem.trim(u8, args, " \t")) |c| {
        if (c == ' ') continue;
        if (e.buf.marks.remove(c)) n += 1;
    }
    if (args.len == 0) return app.diag.fail(app.frame.allocator(), ":delmarks — usage: `:delmarks <letters>` or `:delmarks!`", .{});
    app.toast(":delmarks — cleared {d} mark(s)", .{n});
}

fn set(app: *App, args: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    var it = std.mem.tokenizeAny(u8, args, " \t");
    var any = false;
    while (it.next()) |opt_in| {
        any = true;
        var opt = opt_in;
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, opt, '=')) |eq| {
            value = opt[eq + 1 ..];
            opt = opt[0..eq];
        }
        const off = std.mem.startsWith(u8, opt, "no") and opt.len > 2;
        const name = if (off) opt[2..] else opt;
        if (eqAny(name, &.{ "wrap", "wrap!" })) {
            const toggle = std.mem.endsWith(u8, name, "!");
            if (app.activeEditor()) |e| {
                const cur = e.wrap orelse app.cfg.wrap;
                e.wrap = if (toggle) !cur else !off;
            } else app.cfg.wrap = !off;
            app.toast(":set {s}", .{opt});
        } else if (eqAny(name, &.{ "ic", "ignorecase" })) {
            app.search_case = off;
            app.toast(":set {s}", .{opt});
        } else if (eqAny(name, &.{ "smartcase", "scs" })) {
            app.search_case = null;
            app.toast(":set {s}", .{opt});
        } else if (eqAny(name, &.{ "nu", "number" })) {
            app.cfg.line_numbers = !off;
            app.toast(":set {s}", .{opt});
        } else if (eqAny(name, &.{ "input", "keymap" })) {
            const v = value orelse return app.diag.fail(arena, ":set input=vim|standard", .{});
            const style: input.Style = if (std.mem.eql(u8, v, "vim")) .vim else if (std.mem.eql(u8, v, "standard")) .standard else return app.diag.fail(arena, ":set input — unknown style \"{s}\"", .{v});
            try app.setInputStyle(style);
            app.toast(":set input={s}", .{v});
        } else if (eqAny(name, &.{ "ts", "tabstop", "sw", "shiftwidth" })) {
            const v = value orelse return app.diag.fail(arena, ":set {s}=N", .{name});
            const n = std.fmt.parseInt(u8, v, 10) catch return app.diag.fail(arena, ":set {s} — not a number: {s}", .{ name, v });
            app.cfg.tab_width = @max(n, 1);
            for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .editor => |*e| e.buf.editor.tab_width = @max(n, 1),
                .pty => {},
            };
            app.toast(":set {s}={d}", .{ name, n });
        } else if (eqAny(name, &.{ "hls", "hlsearch", "is", "incsearch", "ai", "autoindent", "et", "expandtab", "rnu", "relativenumber", "list", "cul", "cursorline" })) {
            // Accepted for muscle memory; the spike has no setting behind them yet.
            app.toast(":set {s} — noted", .{opt});
        } else return app.diag.fail(arena, ":set — unknown option \"{s}\"", .{opt});
    }
    if (!any) return app.diag.fail(arena, ":set — usage: :set wrap|nowrap|ic|noic|input=vim|standard", .{});
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
        const root = try realRoot(&tmp, testing.allocator);
        errdefer testing.allocator.free(root);
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .cols = 60, .rows = 12 });
        errdefer app.deinit();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "doc.txt", .data = src });
        const path = try std.fs.path.join(testing.allocator, &.{ root, "doc.txt" });
        defer testing.allocator.free(path);
        _ = try app.openPath(path);
        return .{ .app = app, .tmp = tmp, .root = root };
    }

    fn deinit(f: *Fixture) void {
        f.app.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
    }

    fn text(f: *Fixture) []const u8 {
        return f.app.activeEditor().?.buf.editor.bytes();
    }

    fn ex(f: *Fixture, line: []const u8) !void {
        f.app.frame.begin();
        try run(&f.app, line);
    }
};

test "ex: substitute honours range, g and i flags and escapes" {
    var f = try Fixture.init("alpha\nbeta alpha\nFoo foo FOO\nkeep [drop] keep");
    defer f.deinit();
    try f.ex("%s/alpha/ALPHA/");
    try testing.expectEqualStrings("ALPHA\nbeta ALPHA\nFoo foo FOO\nkeep [drop] keep", f.text());
    try f.ex("3s/foo/Q/gi");
    try testing.expectEqualStrings("ALPHA\nbeta ALPHA\nQ Q Q\nkeep [drop] keep", f.text());
    try f.ex("%s/\\[drop\\] //");
    try testing.expect(std.mem.indexOf(u8, f.text(), "keep keep") != null);
    // Without `g` only the first hit per line goes.
    try f.ex("%s/Q/z/");
    try testing.expect(std.mem.indexOf(u8, f.text(), "z Q Q") != null);
    try f.ex("%s/nothing/x/");
    try testing.expectEqualStrings(":%s — no match for \"nothing\"", f.app.lastToast().?);
}

test "ex: sort, sort u, retab, ranged delete with marks and a bare line jump" {
    var f = try Fixture.init("charlie\nbravo\nalpha\nbravo");
    defer f.deinit();
    try f.ex("sort");
    try testing.expectEqualStrings("alpha\nbravo\nbravo\ncharlie", f.text());
    try f.ex("sort u");
    try testing.expectEqualStrings("alpha\nbravo\ncharlie", f.text());
    try f.ex("sort!");
    try testing.expectEqualStrings("charlie\nbravo\nalpha", f.text());
    const e = f.app.activeEditor().?;
    try e.buf.marks.put(testing.allocator, 'a', .{ .row = 0, .col = 0 });
    try e.buf.marks.put(testing.allocator, 'b', .{ .row = 1, .col = 0 });
    try f.ex("'a,'bd");
    try testing.expectEqualStrings("alpha", f.text());
    try e.buf.editor.setText("\tfoo\nx\ty");
    try f.ex("retab");
    try testing.expectEqualStrings("    foo\nx   y", f.text());
    try f.ex("2");
    try testing.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
    try f.ex("$");
    try testing.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
}

test "ex: write, abbreviations, set, registers, unknown verbs" {
    var f = try Fixture.init("hi");
    defer f.deinit();
    try f.ex("ab omw on my way");
    try testing.expectEqualStrings("on my way", f.app.abbrevs.get("omw").?);
    try testing.expectEqualStrings(":ab omw → on my way", f.app.lastToast().?);
    try f.ex("una omw");
    try testing.expect(f.app.abbrevs.get("omw") == null);
    try f.ex("set nowrap");
    try testing.expectEqual(false, f.app.activeEditor().?.wrap.?);
    try f.ex("set wrap");
    try testing.expectEqual(true, f.app.activeEditor().?.wrap.?);
    try f.ex("set ic");
    try testing.expectEqual(false, f.app.search_case.?);
    try f.ex("set input=vim");
    try testing.expectEqual(input.Style.vim, f.app.cfg.input_style);
    try testing.expectError(error.Failed, f.ex("set bogus"));
    try testing.expectError(error.Failed, f.ex("frobnicate"));
    try testing.expectEqualStrings(":frobnicate — unknown command", f.app.diag.msg.?);
    try f.app.clipboard.setYank("alpha\n", true);
    try f.ex("reg");
    try testing.expect(std.mem.indexOf(u8, f.app.lastToast().?, ":reg · \"\"  alpha↵") != null);
    // `:w` writes the buffer; `:w other` re-targets it.
    const e = f.app.activeEditor().?;
    try e.buf.editor.setText("changed");
    try f.ex("w");
    const back = try f.tmp.dir.readFileAlloc(testing.io, "doc.txt", testing.allocator, .limited(64));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("changed\n", back); // `:w` adds the terminating newline
    try f.ex("w copy.txt");
    try testing.expectEqualStrings("copy.txt", f.app.panes.get(f.app.active.?).?.title());
    _ = try f.tmp.dir.statFile(testing.io, "copy.txt", .{});
}

test "ex: q refuses a dirty buffer, q! discards, the last close quits" {
    var f = try Fixture.init("hi");
    defer f.deinit();
    const e = f.app.activeEditor().?;
    try e.buf.editor.setText("dirty");
    e.buf.dirty = true;
    try testing.expectError(error.Failed, f.ex("q"));
    try testing.expect(std.mem.startsWith(u8, f.app.diag.msg.?, "unsaved changes in doc.txt"));
    try f.ex("q!");
    try testing.expectEqual(@as(usize, 0), f.app.panes.count());
    try testing.expect(f.app.quit);
}

test "ex: alternate file flips between foo.rs and foo_test.rs" {
    var f = try Fixture.init("x");
    defer f.deinit();
    try f.tmp.dir.createDirPath(testing.io, "src");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/foo.rs", .data = "fn foo() {}" });
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "src/foo_test.rs", .data = "// test" });
    try f.ex("e src/foo.rs");
    try testing.expectEqualStrings("foo.rs", f.app.panes.get(f.app.active.?).?.title());
    try f.ex("A");
    try testing.expectEqualStrings("foo_test.rs", f.app.panes.get(f.app.active.?).?.title());
    try f.ex("A");
    try testing.expectEqualStrings("foo.rs", f.app.panes.get(f.app.active.?).?.title());
}

/// The tmp dir's absolute path, gpa-owned without a sentinel.
fn realRoot(tmp: *std.testing.TmpDir, gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return gpa.dupe(u8, buf[0..n]);
}
