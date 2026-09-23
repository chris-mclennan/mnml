//! The `:` line. A range, a verb, its arguments — the vim subset mnml
//! answers today: files (`:w :q :wq :x :e :bd :bn :bp :b :A :update
//! :saveas :cq`), text (`:s :sort :retab :d :t :m :<n>`), settings
//! (`:set :ab :una :noh`), and the read-outs (`:reg :marks`). The verbs that reach past one line —
//! `:g` / `:v`, `:norm`, `:command`, `:!`, `:r`, `:<` / `:>`, `:&` and
//! `:s///c` — live in `ex_verbs.zig`. A verb nobody here knows is tried
//! as a user command, then as a registered command id (`:tab.close`),
//! then reported.
//!
//! Errors travel as `CommandError`: the reason goes in `app.diag`, the
//! caller (`dispatch.runExLine`, the dyn registry) toasts it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const os_path = @import("../core/os_path.zig");
const side = @import("side.zig");
const launcher_dock = @import("launcher_dock.zig");
const marks_store = @import("marks_store.zig");
const CommandError = command.CommandError;
const find_mod = @import("find.zig");
const regex = @import("../regex/regex.zig");
const editor_mod = @import("../editor/editor.zig");
const Editor = editor_mod.Editor;
const input = @import("../input/mod.zig");
const edit_op = @import("../editor/edit_op.zig");
const dispatch = @import("dispatch.zig");
const Config = app_mod.Config;
const ex_verbs = @import("ex_verbs.zig");
const ex_fname = @import("ex_fname.zig");
const cmd_app = @import("cmd_app.zig");
const cmd_file = @import("cmd_file.zig");
const loclist = @import("loclist.zig");

/// 0-based inclusive rows.
pub const Range = struct { first: usize, last: usize };

pub fn run(app: *App, line_in: []const u8) CommandError!void {
    // Trailing blanks stay: `:norm A ` types one. Every verb trims its own args.
    var line = std.mem.trimStart(u8, std.mem.trimEnd(u8, line_in, "\r\n"), " \t");
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
        return ex_verbs.substituteEntry(app, range, rest[1..], p.saw_percent);
    }
    if (std.mem.startsWith(u8, rest, "substitute") and rest.len > "substitute".len and !std.ascii.isAlphanumeric(rest["substitute".len])) {
        return ex_verbs.substituteEntry(app, range, rest["substitute".len..], p.saw_percent);
    }
    if (rest[0] == '&') return ex_verbs.ampersand(app, range, rest, p.saw_percent);

    var i: usize = 0;
    while (i < rest.len and (std.ascii.isAlphanumeric(rest[i]) or rest[i] == '.' or rest[i] == '_')) i += 1;
    var verb = rest[0..i];
    // A command id may carry dots and digits (`tab.close`); the copy /
    // move verbs take an address right after their letters (`:t.`,
    // `:m0`, `:co5`) and `:d` / `:y` a count (`:1d2`), so those split at
    // the first non-letter.
    var letters: usize = 0;
    while (letters < verb.len and std.ascii.isAlphabetic(verb[letters])) letters += 1;
    if (letters < verb.len and eqAny(verb[0..letters], &.{ "t", "co", "copy", "m", "mo", "move", "d", "de", "del", "delete", "y", "ya", "yan", "yank", "j", "jo", "join" })) {
        i = letters;
        verb = rest[0..i];
    }
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

    // `:!cmd` (`:!!` repeats), or `:[range]!cmd` as a filter.
    if (verb.len == 0 and bang) return ex_verbs.shell(app, range, rest[i..]);
    if (eqAny(verb, &.{ "<", ">" })) return ex_verbs.shift(app, range, verb[0] == '>', args);
    if (eqAny(verb, &.{ "g", "global" })) return ex_verbs.global(app, range, rest[i..], bang);
    if (eqAny(verb, &.{ "v", "vglobal" })) return ex_verbs.global(app, range, rest[i..], true);
    if (eqAny(verb, &.{ "norm", "normal" })) return ex_verbs.normal(app, range, std.mem.trimStart(u8, rest[i..], " \t"));
    if (eqAny(verb, &.{ "com", "command" })) return ex_verbs.defineCommand(app, args, bang);
    if (eqAny(verb, &.{ "delc", "delcommand" })) return ex_verbs.deleteCommand(app, args);
    if (eqAny(verb, &.{ "r", "read" })) return ex_verbs.read(app, range, if (bang) try std.mem.concat(arena, u8, &.{ "!", args }) else args);
    // A bare `:s [flags]` repeats the last substitute.
    if (eqAny(verb, &.{ "s", "su", "substitute" })) return ex_verbs.ampersand(app, range, args, p.saw_percent);

    if (eqAny(verb, &.{ "w", "write" })) return write(app, range, args, false, false);
    if (eqAny(verb, &.{ "wa", "wall" })) return saveAll(app);
    if (eqAny(verb, &.{ "wq", "x", "xit", "exit" })) return write(app, range, args, true, false);
    if (eqAny(verb, &.{ "wqa", "wqall", "xa", "xall" })) {
        try saveAll(app);
        app.quit = true;
        return;
    }
    if (eqAny(verb, &.{ "q", "quit", "clo", "close" })) return quit(app, bang);
    if (eqAny(verb, &.{ "qa", "qall", "quitall", "quita" })) {
        if (!bang and app.anyDirty()) return app.diag.fail(arena, "unsaved changes — use :qa! to discard", .{});
        // ── files: the :qa transfer guard (src/app/transfers.zig) ──
        // A quit kills the transfer workers mid-copy; an explicit cancel
        // promises a cleanup, a quit cannot.
        if (!bang and app.transfersRunning() > 0) return app.diag.fail(arena, "{d} transfer(s) still running — transfer.cancel_all, or :qa! to quit anyway", .{app.transfersRunning()});
        // ── end files ──
        // // changed (quit-confirm): `:qa` ends the session, so it stops
        // at the same box `app.quit` raises; `:qa!` is the way straight
        // out, as it always was.
        if (!bang) return cmd_app.confirmQuitOrQuit(app);
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
        return app.closeDocument(id, bang);
    }
    // `:bn` / `:bp` step over terminal tabs; the bang form takes them too.
    if (eqAny(verb, &.{ "bn", "bnext" })) return if (bang) @import("cmd_buffer.zig").cycleAny(app, 1) else command.run(app, .{ .static = .@"buffer.next" });
    if (eqAny(verb, &.{ "bp", "bprev", "bprevious", "bN", "bNext" })) return if (bang) @import("cmd_buffer.zig").cycleAny(app, -1) else command.run(app, .{ .static = .@"buffer.prev" });
    if (eqAny(verb, &.{ "b", "bu", "buf", "buffer" })) return @import("cmd_buffer.zig").switchTo(app, args);
    if (eqAny(verb, &.{ "bf", "bfirst", "br", "brewind" })) return @import("cmd_buffer.zig").firstTab(app);
    if (eqAny(verb, &.{ "bl", "blast" })) return @import("cmd_buffer.zig").lastTab(app);
    if (eqAny(verb, &.{ "t", "co", "copy" })) return copyMove(app, range, args, false);
    if (eqAny(verb, &.{ "m", "mo", "move" })) return copyMove(app, range, args, true);
    if (eqAny(verb, &.{ "up", "update" })) {
        const e = try editor(app, ":update");
        if (!e.buf.doc.dirty) return;
        return write(app, null, "", false, false);
    }
    if (eqAny(verb, &.{ "sav", "saveas" })) {
        if (args.len == 0) return app.diag.fail(arena, ":saveas — file name required", .{});
        return write(app, null, args, false, true);
    }
    if (eqAny(verb, &.{ "cq", "cquit" })) {
        // Quit with a failing exit code — a `git commit` or `crontab -e`
        // that spawned mnml then treats the edit as abandoned.
        app.exit_code = 1;
        app.quit = true;
        return;
    }
    if (eqAny(verb, &.{"new"})) return newSplit(app, .vertical);
    if (eqAny(verb, &.{ "vne", "vnew" })) return newSplit(app, .horizontal);
    if (eqAny(verb, &.{"rename"})) return @import("cmd_term.zig").renameEx(app, args);
    if (eqAny(verb, &.{ "ls", "buffers", "files" })) return command.run(app, .{ .static = .@"picker.buffers" });
    if (eqAny(verb, &.{"A"})) return alternate(app);
    if (eqAny(verb, &.{ "sor", "sort" })) return sort(app, range, args, bang);
    if (eqAny(verb, &.{ "ret", "retab" })) return retab(app, range, args, bang);
    if (eqAny(verb, &.{ "d", "de", "del", "delete" })) return deleteLines(app, range, args);
    if (eqAny(verb, &.{ "j", "jo", "joi", "join" })) return joinLines(app, range, args, bang);
    if (eqAny(verb, &.{ "y", "ya", "yan", "yank" })) return yankLines(app, range, args);
    if (eqAny(verb, &.{ "ab", "abb", "abbreviate", "iab", "iabbrev" })) return abbreviate(app, args);
    if (eqAny(verb, &.{ "una", "unabbreviate", "iuna", "iunabbrev" })) return unabbreviate(app, args);
    if (eqAny(verb, &.{ "reg", "registers", "di", "display" })) return registers(app, args);
    if (eqAny(verb, &.{"marks"})) return marks(app);
    if (eqAny(verb, &.{ "delm", "delmarks" })) return delmarks(app, args, bang);
    if (eqAny(verb, &.{ "se", "set" })) return set(app, args);
    if (eqAny(verb, &.{"settings"})) return command.run(app, .{ .static = .@"view.settings" });
    if (eqAny(verb, &.{"sidebar"})) return sidebar(app, args);
    // // changed (launcher-dock): the word form of the dock's verbs.
    if (eqAny(verb, &.{"dock"})) return launcherDock(app, args);
    // Full screen's `:` doors: it hides the chrome, so the `:` line is
    // the vim profile's way in and out (`app/zen.zig`).
    if (eqAny(verb, &.{ "fullscreen", "zen" })) return command.run(app, .{ .static = .@"view.fullscreen" });
    if (eqAny(verb, &.{"resetview"})) return command.run(app, .{ .static = .@"view.reset_layout" });
    if (eqAny(verb, &.{"layout"})) return @import("named_layouts.zig").ex(app, args);
    if (eqAny(verb, &.{ "mes", "messages", "Messages" })) {
        if (bang) return @import("messages.zig").dump(app);
        return command.run(app, .{ .static = .@"messages.show" });
    }
    if (eqAny(verb, &.{ "cn", "cnext" })) return command.run(app, .{ .static = .@"qf.next" });
    if (eqAny(verb, &.{ "cp", "cprev", "cprevious", "cN", "cNext" })) return command.run(app, .{ .static = .@"qf.prev" });
    if (eqAny(verb, &.{ "cfir", "cfirst", "cr", "crewind" })) return command.run(app, .{ .static = .@"qf.first" });
    if (eqAny(verb, &.{ "cla", "clast" })) return command.run(app, .{ .static = .@"qf.last" });
    if (eqAny(verb, &.{ "lex", "lexpr", "lgetexpr" })) return loclist.lexpr(app, args);
    if (eqAny(verb, &.{ "lop", "lopen", "lw", "lwindow" })) return loclist.open(app);
    if (eqAny(verb, &.{ "lcl", "lclose" })) return loclist.close(app);
    if (eqAny(verb, &.{ "lne", "lnext" })) return loclist.go(app, .next);
    if (eqAny(verb, &.{ "lp", "lprev", "lprevious", "lN", "lNext" })) return loclist.go(app, .prev);
    if (eqAny(verb, &.{ "lfir", "lfirst", "lr", "lrewind" })) return loclist.go(app, .first);
    if (eqAny(verb, &.{ "lla", "llast" })) return loclist.go(app, .last);
    if (eqAny(verb, &.{ "theme", "colorscheme", "colo" })) {
        if (args.len == 0) return command.run(app, .{ .static = .@"theme.pick" });
        return @import("cmd_view.zig").useTheme(app, args);
    }
    if (eqAny(verb, &.{ "noh", "nohlsearch", "nohl" })) return command.run(app, .{ .static = .@"find.clear" });
    if (eqAny(verb, &.{ "echo", "Echo" })) {
        app.toast("{s}", .{args});
        return;
    }
    if (eqAny(verb, &.{ "sp", "split" })) return splitOpen(app, .vertical, args);
    if (eqAny(verb, &.{ "vs", "vsplit" })) return splitOpen(app, .horizontal, args);
    if (eqAny(verb, &.{ "cex", "cexpr", "cgetexpr" })) return cexpr(app, args);
    if (eqAny(verb, &.{ "on", "only" })) return command.run(app, .{ .static = .@"view.only" });
    if (eqAny(verb, &.{ "tabnew", "tabe", "tabedit" })) return command.run(app, .{ .static = .@"tab.new" });
    if (eqAny(verb, &.{ "tabn", "tabnext" })) return command.run(app, .{ .static = .@"tab.next" });
    if (eqAny(verb, &.{ "tabp", "tabprev", "tabprevious", "tabN", "tabNext" })) return command.run(app, .{ .static = .@"tab.prev" });
    if (eqAny(verb, &.{ "tabfir", "tabfirst", "tabr", "tabrewind" })) return command.run(app, .{ .static = .@"tab.first" });
    if (eqAny(verb, &.{ "tabl", "tablast" })) return command.run(app, .{ .static = .@"tab.last" });
    if (eqAny(verb, &.{ "tabc", "tabclose" })) return command.run(app, .{ .static = .@"tab.close" });
    if (eqAny(verb, &.{ "tabo", "tabonly" })) return command.run(app, .{ .static = .@"tab.only" });
    if (eqAny(verb, &.{"tabs"})) return command.run(app, .{ .static = .@"tab.list" });
    if (eqAny(verb, &.{ "tabm", "tabmove" })) return @import("cmd_tab.zig").moveTo(app, args);
    if (eqAny(verb, &.{ "res", "resize" })) return @import("cmd_view.zig").resizeCells(app, false, args);
    if (eqAny(verb, &.{ "vert", "vertical" })) return vertical(app, args);
    if (eqAny(verb, &.{ "term", "terminal" })) return @import("cmd_term.zig").termEx(app, args);
    if (eqAny(verb, &.{"task"})) return @import("tasks.zig").runNamed(app, args);

    // A user `:command`, then a registered command by id.
    if (try ex_verbs.runUserCommand(app, range, verb, bang, args)) return;
    if (command.resolve(app, verb)) |ref| return command.run(app, ref);
    return app.diag.fail(arena, ":{s} — unknown command", .{verb});
}

/// `:vertical {cmd}` (`:help :vertical`): the width forms of `resize`
/// and `split` — the two it modifies here.
fn vertical(app: *App, args: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const a = std.mem.trim(u8, args, " \t");
    var i: usize = 0;
    while (i < a.len and std.ascii.isAlphabetic(a[i])) i += 1;
    const sub = a[0..i];
    const rest = std.mem.trim(u8, a[i..], " \t");
    if (sub.len >= 3 and std.mem.startsWith(u8, "resize", sub)) return @import("cmd_view.zig").resizeCells(app, true, rest);
    if (eqAny(sub, &.{ "sp", "split", "new" })) return splitOpen(app, .horizontal, rest);
    return app.diag.fail(arena, ":vertical — only `resize` and `split` are supported here", .{});
}

/// `:new` / `:vnew`: a split holding a fresh scratch buffer.
fn newSplit(app: *App, dir: @import("layout.zig").SplitDir) CommandError!void {
    const cur = app.active orelse return error.NoActivePane;
    const id = app.openScratch() catch return error.OutOfMemory;
    // openScratch showed it in the current leaf; move it out into the split.
    app.setActive(cur);
    return @import("cmd_view.zig").splitWith(app, dir, id);
}

/// `:[range]t {address}` / `:[range]m {address}`: copy or move the lines
/// (the cursor's by default) to below `address`; `0` puts them at the
/// top. A move into its own range is E134; onto its own edge, nothing.
/// One undo step; the cursor lands on the last line that arrived.
fn copyMove(app: *App, range: ?Range, args: []const u8, move: bool) CommandError!void {
    const arena = app.frame.allocator();
    const label: []const u8 = if (move) ":m" else ":t";
    const e = try editor(app, label);
    const ed = e.buf.editor;
    const count = ed.lineCount();
    const src = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    const first = @min(src.first, count - 1);
    const last = @min(src.last, count - 1);
    const a = std.mem.trim(u8, args, " \t");
    if (a.len == 0) return app.diag.fail(arena, "{s} — E14: Invalid address", .{label});
    // Null = address 0: above the first line.
    var dest: ?usize = null;
    if (!std.mem.eql(u8, a, "0")) {
        var p = Parser{ .s = a };
        dest = (try p.parseAddr(app)) orelse return app.diag.fail(arena, "{s} — E14: Invalid address", .{label});
    }
    const n_lines = last + 1 - first;
    const body = ed.bytes()[ed.lineStart(first)..ed.lineEnd(last)];
    if (!move) {
        var land: usize = 0;
        if (dest) |d| {
            const at = ed.lineEnd(d);
            try app.splice(e, at, at, try std.mem.concat(arena, u8, &.{ "\n", body }));
            land = d + 1;
        } else {
            try app.splice(e, 0, 0, try std.mem.concat(arena, u8, &.{ body, "\n" }));
        }
        ed.setCursor(ed.firstNonWs(land + n_lines - 1));
        ed.goal_col = null;
        return;
    }
    if (dest) |d| {
        if (d >= first and d < last) return app.diag.fail(arena, ":m — E134: Cannot move a range of lines into itself", .{});
        if (d == last or d + 1 == first) return;
    } else if (first == 0) return;
    // Rebuild the span the move disturbs, lines in their new order.
    const up = if (dest) |d| d < first else true;
    const lo = if (up) (if (dest) |d| d + 1 else 0) else first;
    const hi = if (up) last else dest.?;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    const line_of = struct {
        fn f(editor_: *const Editor, line: usize) []const u8 {
            return editor_.bytes()[editor_.lineStart(line)..editor_.lineEnd(line)];
        }
    }.f;
    var lines_out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (up) {
        var l = first;
        while (l <= last) : (l += 1) try lines_out.append(arena, line_of(ed, l));
        l = lo;
        while (l < first) : (l += 1) try lines_out.append(arena, line_of(ed, l));
    } else {
        var l = last + 1;
        while (l <= hi) : (l += 1) try lines_out.append(arena, line_of(ed, l));
        l = first;
        while (l <= last) : (l += 1) try lines_out.append(arena, line_of(ed, l));
    }
    for (lines_out.items, 0..) |ln, k| {
        if (k > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, ln);
    }
    try app.splice(e, ed.lineStart(lo), ed.lineEnd(hi), out.items);
    const land = if (up) lo + n_lines - 1 else hi;
    ed.setCursor(ed.firstNonWs(@min(land, ed.lineCount() - 1)));
    ed.goal_col = null;
}

/// `:sp [path]` / `:vs [path]`: a split showing `path` (opened if
/// need be), or a duplicate of the active pane.
fn splitOpen(app: *App, dir: @import("layout.zig").SplitDir, args: []const u8) CommandError!void {
    const cmd_view = @import("cmd_view.zig");
    const path = std.mem.trim(u8, args, " \t");
    if (path.len == 0) return cmd_view.splitWith(app, dir, null);
    const cur = app.active orelse return error.NoActivePane;
    const abs = try app.absPath(path);
    const id = app.openPath(abs) catch |err| return app.diag.fail(app.frame.allocator(), "{s}: {s}", .{ path, @errorName(err) });
    if (id == cur) return app.diag.fail(app.frame.allocator(), "{s} is the active pane", .{path});
    app.setActive(cur);
    return cmd_view.splitWith(app, dir, id);
}

/// `:cexpr path:line:col:text` (one entry per line of the argument):
/// fills the quickfix pane.
fn cexpr(app: *App, args: []const u8) CommandError!void {
    const cmd_view = @import("cmd_view.zig");
    var entries: std.ArrayListUnmanaged(app_mod.ListPane.Entry) = .empty;
    const gpa = app.gpa;
    errdefer {
        for (entries.items) |e| {
            gpa.free(e.text);
            if (e.path) |p| gpa.free(p);
        }
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
        try entries.append(gpa, .{
            .text = try gpa.dupe(u8, if (text.len > 0) text else line),
            .path = try gpa.dupe(u8, path),
            .line = ln,
            .col = col,
        });
    }
    try cmd_view.openListPane(app, .quickfix, try entries.toOwnedSlice(gpa));
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
                'A'...'Z' => marks_store.rowIn(app, m, ed.buf.doc.path) orelse return app.diag.fail(arena, "E20: mark '{c} not set", .{m}),
                else => if (ed.buf.doc.markPos(m)) |pos| pos.row else return app.diag.fail(arena, "E20: mark '{c} not set", .{m}),
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

fn write(app: *App, range: ?Range, path_arg: []const u8, then_close: bool, rename: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":w");
    // `:w !cmd` / `:[range]w !cmd` pipe the text to `cmd` and show its
    // output (`:help :w_c`); nothing is written, least of all a file
    // called `!cmd`.
    if (path_arg.len > 0 and path_arg[0] == '!') return writeToCommand(app, e, range, path_arg[1..]);
    if (path_arg.len > 0) {
        const abs = try app.absPath(try fileArg(app, ":w", path_arg));
        // `:w {file}` on a named buffer writes a copy and the buffer keeps
        // its name (`:help :w_f`); `:saveas` and an unnamed buffer take
        // the new name.
        if (!rename) if (e.buf.doc.path) |cur| if (!std.mem.eql(u8, cur, abs)) {
            const data = e.buf.copyForWrite() catch return error.OutOfMemory;
            defer app.gpa.free(data);
            std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = abs, .data = data }) catch |err| return app.diag.fail(arena, ":w — {s}: {s}", .{ app.relPath(abs), @errorName(err) });
            app.toast("wrote {s}", .{app.relPath(abs)});
            if (then_close) {
                try app.forceClosePane(app.active.?);
                if (app.panes.count() == 0) app.quit = true;
            }
            return;
        };
        e.buf.setPath(abs) catch return error.OutOfMemory;
        e.syntax.setLanguage(abs, e.buf.editor.bytes());
        e.syntax.dirty = true;
    }
    if (e.buf.doc.path == null) return app.diag.fail(arena, ":w — no file name (use :w <path>)", .{});
    // The one save path: the hooks, a format-on-save the server is
    // asked for, and a resolved conflict staged.
    const id = app.active.?;
    try cmd_file.savePane(app, id, e, .{ .fail_prefix = ":w —", .may_hold = true });
    // Held for the server's edits: the write — and `:wq`'s close —
    // follow its reply (`lsp_format.finishHold`).
    if (@import("lsp_format.zig").held(app, id)) {
        if (then_close) @import("lsp_format.zig").closeAfter(app, id);
        return;
    }
    if (then_close) {
        try app.forceClosePane(id);
        if (app.panes.count() == 0) app.quit = true;
    }
}

fn writeToCommand(app: *App, e: *EditorPane, range: ?Range, cmd_in: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const cmd = std.mem.trim(u8, cmd_in, " \t");
    if (cmd.len == 0) return app.diag.fail(arena, ":w ! — command required", .{});
    const ed = e.buf.editor;
    const text: []const u8 = if (range) |r| blk: {
        const first = @min(r.first, ed.lineCount() - 1);
        const last = @min(r.last, ed.lineCount() - 1);
        break :blk try std.mem.concat(arena, u8, &.{ ed.bytes()[ed.lineStart(first)..ed.lineEnd(last)], "\n" });
    } else ed.bytes();
    const res = ex_verbs.runShell(app, arena, cmd, text, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Spawn => return app.diag.fail(arena, ":w !{s} — could not start the shell", .{cmd}),
    };
    try ex_verbs.showOutput(app, cmd, res.stdout);
    if (res.code) |c| {
        if (c == 0) app.toast(":w !{s} — done", .{cmd}) else app.toast(":w !{s} — exit {d}", .{ cmd, c });
    } else app.toast(":w !{s} — killed", .{cmd});
}

/// `:wa` is `file.save_all`: every dirty editor through the one save
/// path, so the save hooks and everything after a save run for each.
fn saveAll(app: *App) CommandError!void {
    return cmd_file.saveAllWith(app, ":wa —");
}

/// `:q` closes the window; the buffer stays when another window shows
/// it, and closes with the last one (a dirty one refuses without `!`).
/// On the LAST window it would end the session, so it asks there first
/// (`ui.confirm_quit`); `:q!` goes straight out.
fn quit(app: *App, bang: bool) CommandError!void {
    const id = app.active orelse {
        if (!bang) return cmd_app.confirmQuitOrQuit(app);
        app.quit = true;
        return;
    };
    const pane = app.panes.get(id).?;
    if (!bang and pane.dirty() and !app.isSharedView(id)) {
        return app.diag.fail(app.frame.allocator(), "unsaved changes in {s} — use :q! to discard", .{pane.title()});
    }
    // // changed (quit-confirm): `:q` still closes a pane — but the
    // LAST one ends the session, and that stop is the one `app.quit`
    // asks about. The pane stays open behind the box; Quit ends the
    // session from there, and `:q!` never asks.
    if (!bang and app.panes.count() == 1) return cmd_app.confirmQuitOrQuit(app);
    try app.forceClosePane(id);
    if (app.panes.count() == 0) app.quit = true;
}

fn edit(app: *App, arg: []const u8, bang: bool) CommandError!void {
    const arena = app.frame.allocator();
    if (arg.len == 0 or std.mem.eql(u8, arg, "%")) {
        // Reload from disk; `:e!` discards unsaved changes.
        const e = try editor(app, ":e");
        const path = e.buf.doc.path orelse return app.diag.fail(arena, ":e — no file name", .{});
        if (e.buf.doc.dirty and !bang) return app.diag.fail(arena, ":e — unsaved changes (use :e! to discard)", .{});
        @import("watch.zig").reload(app, app.active.?) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return app.diag.fail(arena, ":e — {s}", .{@errorName(err)}),
        };
        app.toast("reloaded {s}", .{app.relPath(path)});
        return;
    }
    const abs = try app.absPath(try fileArg(app, ":e", arg));
    _ = app.openPath(abs) catch |err| return app.diag.fail(arena, ":e {s} — {s}", .{ arg, @errorName(err) });
}

/// A file argument with `%` / `#` / `<cfile>` and their modifiers
/// expanded (`ex_fname.zig`); the errors are vim's.
pub fn fileArg(app: *App, label: []const u8, arg: []const u8) CommandError![]const u8 {
    const arena = app.frame.allocator();
    const e = app.activeEditor();
    const cur: ?[]const u8 = if (e) |ed| (if (ed.buf.doc.path) |p| app.relPath(p) else null) else null;
    const cfile: ?[]const u8 = if (e) |ed| ex_fname.nameAt(ed.buf.editor.bytes(), ed.buf.editor.cursor) else null;
    return ex_fname.expand(arena, arg, .{ .current = cur, .alternate = alternateFile(app), .cfile = cfile, .workspace = app.workspace }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoFileName => app.diag.fail(arena, "{s} — E499: empty file name for '%'", .{label}),
        error.NoAlternate => app.diag.fail(arena, "{s} — E194: no alternate file name to substitute for '#'", .{label}),
        error.NoCfile => app.diag.fail(arena, "{s} — E446: no file name under cursor", .{label}),
    };
}

/// The alternate file (`:help alternate-file`): the most recently used
/// editor, other than the active one, that has a file — what `:b#` and
/// `Ctrl-^` go back to.
fn alternateFile(app: *App) ?[]const u8 {
    for (app.pane_mru.items) |id| {
        if (app.active == id) continue;
        const ed = app.panes.editor(id) orelse continue;
        if (ed.buf.doc.path) |p| return app.relPath(p);
    }
    return null;
}

/// `:A` — the test ↔ source counterpart of the active file.
fn alternate(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":A");
    const path = e.buf.doc.path orelse return app.diag.fail(arena, ":A — no active file", .{});
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
/// `ex_verbs.substituteEntry` is the way in: it remembers the spec for
/// `:&` and takes the `c` flag. `pat` is a vim pattern (`src/regex/`);
/// `rep` takes `&`, `\\0`–`\\9`, `\\n`, `\\t`, `\\u` `\\l` `\\U` `\\L` `\\E`.
/// Each line is matched on its own, so `^` / `$` are the line's ends
/// and a match never spans lines.
pub fn substitute(app: *App, range: ?Range, spec: []const u8, whole: bool) CommandError!void {
    const arena = app.frame.allocator();
    const label: []const u8 = if (whole) ":%s" else ":s";
    const e = try editor(app, label);
    const ed = e.buf.editor;
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
    // ── regex (search track) ──
    // The escaped delimiter is the delimiter itself; every other escape
    // is the pattern's (or the replacement's) to read.
    const pattern = try unescapeDelim(arena, parts[0], delim);
    const replacement = try unescapeDelim(arena, parts[1], delim);
    var global = false;
    var case: ?bool = null;
    for (parts[2]) |f| switch (f) {
        'g' => global = true,
        'i' => case = false,
        'I' => case = true,
        else => {},
    };
    const case_sensitive = case orelse app.search_case orelse find_mod.hasUpper(pattern);
    var re = try compilePattern(app, label, pattern, case_sensitive);
    defer re.deinit();

    const r = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;
    var row = first;
    while (row <= last) : (row += 1) {
        const line = ed.lineSlice(row);
        var from: usize = 0;
        var copied: usize = 0;
        while (from <= line.len) {
            const m = re.find(line, from) orelse break;
            try out.appendSlice(arena, line[copied..m.start]);
            try regex.expandReplacement(arena, &out, replacement, line, m);
            copied = m.end;
            count += 1;
            if (!global) break;
            if (m.end > m.start) {
                from = m.end;
            } else {
                // An empty match: keep the char under it and move on.
                if (m.end < line.len) try out.append(arena, line[m.end]);
                copied = @min(m.end + 1, line.len);
                from = m.end + 1;
            }
        }
        try out.appendSlice(arena, line[copied..]);
        if (row < last) try out.append(arena, '\n');
    }
    // ── end regex (search track) ──
    if (count == 0) {
        app.toast("{s} — no match for \"{s}\"", .{ label, pattern });
        return;
    }
    try app.splice(e, ed.lineStart(first), ed.lineEnd(last), out.items);
    ed.setCursor(ed.firstNonWs(@min(last, ed.lineCount() - 1)));
    ed.goal_col = null;
    app.toast("{s} — {d} replacement(s)", .{ label, count });
}

/// A vim pattern compiled for an ex verb; the failure names the verb
/// and says what was wrong with the pattern.
pub fn compilePattern(app: *App, label: []const u8, pattern: []const u8, case_sensitive: bool) CommandError!regex.Regex {
    const arena = app.frame.allocator();
    return regex.Regex.compile(pattern, .{ .ignore_case = !case_sensitive }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPattern => return app.diag.fail(arena, "{s} — invalid pattern \"{s}\"", .{ label, pattern }),
        error.Unsupported => return app.diag.fail(arena, "{s} — pattern item not supported in this build: \"{s}\"", .{ label, pattern }),
        error.TooLong => return app.diag.fail(arena, "{s} — pattern too long", .{label}),
    };
}

/// `\\/` → `/` (for whatever the delimiter is); everything else stays.
pub fn unescapeDelim(arena: Allocator, s: []const u8, delim: u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == delim) {
            try out.append(arena, delim);
            i += 1;
        } else try out.append(arena, s[i]);
    }
    return out.items;
}

/// `:[range]sort[!] [b][f][i][n][o][r][u][x] [/{pattern}/]` (`:help
/// :sort`). `!` reverses; `i` ignores case; `n` / `x` / `o` / `b` sort
/// on the first decimal / hex / octal / binary number and `f` on the
/// first float (a line without one sorts first); `u` keeps the first of
/// equal lines (case folded under `i`). A pattern sorts on what follows
/// its match — on the match itself with `r` — and a line it misses
/// sorts first, in its own order. The sort is stable.
fn sort(app: *App, range: ?Range, flags: []const u8, bang: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":sort");
    const ed = e.buf.editor;
    var unique = false;
    var icase = false;
    var on_match = false;
    var kind: SortKind = .text;
    var pattern: ?[]const u8 = null;
    var i: usize = 0;
    while (i < flags.len) : (i += 1) {
        const f = flags[i];
        switch (f) {
            ' ', '\t' => {},
            'u' => unique = true,
            'i' => icase = true,
            'r' => on_match = true,
            'l' => {}, // locale collation: byte order here
            'n' => kind = .decimal,
            'x' => kind = .hex,
            'o' => kind = .octal,
            'b' => kind = .binary,
            'f' => kind = .float,
            else => {
                if (std.ascii.isAlphabetic(f) or f == '"' or f == '\\') return app.diag.fail(arena, ":sort — E474: invalid argument: {s}", .{flags[i..]});
                // Any other character opens the pattern and closes it.
                var j = i + 1;
                while (j < flags.len and flags[j] != f) : (j += 1) {
                    if (flags[j] == '\\' and j + 1 < flags.len) j += 1;
                }
                pattern = try unescapeDelim(arena, flags[i + 1 .. j], f);
                i = j;
            },
        }
    }
    if (pattern) |p| if (p.len == 0) return app.diag.fail(arena, ":sort — E35: no previous regular expression", .{});
    var re: ?regex.Regex = if (pattern) |p| try compilePattern(app, ":sort", p, true) else null;
    defer if (re) |*r| r.deinit();

    const r = range orelse Range{ .first = 0, .last = ed.lineCount() - 1 };
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    const Line = struct { text: []const u8, key: []const u8, has_num: bool = false, num: i64 = 0, flt: f64 = 0 };
    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var row = first;
    while (row <= last) : (row += 1) {
        const text = ed.lineSlice(row);
        var key = text;
        if (re) |*rx| {
            if (rx.find(text, 0)) |m| {
                key = if (on_match) text[m.start..m.end] else text[m.end..];
            } else key = text[0..0];
        }
        var l: Line = .{ .text = text, .key = key };
        if (kind != .text) sortNumber(&l, kind);
        try lines.append(arena, l);
    }
    const Ctx = struct {
        kind: SortKind,
        icase: bool,
        fn lt(c: @This(), a: Line, b: Line) bool {
            switch (c.kind) {
                .text => {
                    if (!c.icase) return std.mem.lessThan(u8, a.key, b.key);
                    return std.ascii.orderIgnoreCase(a.key, b.key) == .lt;
                },
                else => {
                    if (a.has_num != b.has_num) return !a.has_num;
                    if (c.kind == .float) return a.flt < b.flt;
                    return a.num < b.num;
                },
            }
        }
    };
    // Stable, so equal keys keep their order (and `!` reverses it all).
    std.mem.sort(Line, lines.items, Ctx{ .kind = kind, .icase = icase }, Ctx.lt);
    if (bang) std.mem.reverse(Line, lines.items);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var kept: usize = 0;
    var prev: ?[]const u8 = null;
    for (lines.items) |l| {
        if (unique and prev != null) {
            const same = if (icase) std.ascii.eqlIgnoreCase(prev.?, l.text) else std.mem.eql(u8, prev.?, l.text);
            if (same) continue;
        }
        if (kept > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, l.text);
        kept += 1;
        prev = l.text;
    }
    try app.splice(e, ed.lineStart(first), ed.lineEnd(last), out.items);
    ed.setCursor(ed.lineStart(first));
    ed.goal_col = null;
    app.toast(":sort{s}{s}{s}{s}{s}{s}{s}{s} — {d} line(s)", .{
        if (bang) "!" else "",
        if (unique) " u" else "",
        if (icase) " i" else "",
        switch (kind) {
            .text => "",
            .decimal => " n",
            .hex => " x",
            .octal => " o",
            .binary => " b",
            .float => " f",
        },
        if (on_match) " r" else "",
        if (pattern != null) " /" else "",
        pattern orelse "",
        if (pattern != null) "/" else "",
        kept,
    });
}

const SortKind = enum { text, decimal, hex, octal, binary, float };

/// The number `:sort n` / `x` / `o` / `b` / `f` sorts a line on: the
/// first one in its key, a `-` right before it the sign (Neovim's
/// `ex_sort`). No number leaves `has_num` false.
fn sortNumber(l: anytype, kind: SortKind) void {
    const k = l.key;
    const isDig = struct {
        fn f(kd: SortKind, c: u8) bool {
            return switch (kd) {
                .hex => std.ascii.isHex(c),
                .binary => c == '0' or c == '1',
                .octal => c >= '0' and c <= '7',
                else => std.ascii.isDigit(c),
            };
        }
    }.f;
    var i: usize = 0;
    while (i < k.len and !isDig(kind, k[i]) and !(kind == .float and k[i] == '.' and i + 1 < k.len and std.ascii.isDigit(k[i + 1]))) i += 1;
    if (i == k.len) return;
    const neg = i > 0 and k[i - 1] == '-';
    var start = i;
    var base: u8 = 10;
    switch (kind) {
        .hex => {
            base = 16;
            if (k[i] == '0' and i + 2 < k.len and (k[i + 1] == 'x' or k[i + 1] == 'X') and std.ascii.isHex(k[i + 2])) start = i + 2;
        },
        .binary => {
            base = 2;
            if (k[i] == '0' and i + 2 < k.len and (k[i + 1] == 'b' or k[i + 1] == 'B')) start = i + 2;
        },
        .octal => base = 8,
        else => {},
    }
    var end = start;
    if (kind == .float) {
        while (end < k.len and (std.ascii.isDigit(k[end]) or k[end] == '.' or k[end] == 'e' or k[end] == 'E')) end += 1;
        while (end > start) : (end -= 1) {
            if (std.fmt.parseFloat(f64, k[start..end])) |v| {
                l.flt = if (neg) -v else v;
                l.has_num = true;
                return;
            } else |_| {}
        }
        return;
    }
    while (end < k.len and isDig(kind, k[end])) end += 1;
    const v = std.fmt.parseInt(i64, k[start..end], base) catch std.math.maxInt(i64);
    l.num = if (neg) -v else v;
    l.has_num = true;
}

/// `:[range]retab[!] [N]` (`:help :retab`): every run of blanks that
/// holds a TAB is rewritten for tab stop `N` (default: the current
/// one) — as spaces under `expandtab`, else as tabs and the spaces left
/// over. `!` rewrites runs of spaces too. Columns are display cells
/// (`é` is one, `中` two), measured at the old tab stop; `N` becomes the
/// buffer's tab stop.
fn retab(app: *App, range: ?Range, args: []const u8, bang: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":retab");
    const ed = e.buf.editor;
    const doc = ed.doc;
    const trimmed = std.mem.trim(u8, args, " \t");
    const old_ts: usize = @max(doc.tab_width, 1);
    const new_ts: usize = if (trimmed.len == 0) old_ts else std.fmt.parseInt(u8, trimmed, 10) catch return app.diag.fail(arena, ":retab — E475: invalid argument: {s}", .{trimmed});
    if (new_ts == 0) return app.diag.fail(arena, ":retab — E487: argument must be positive", .{});
    const expand = !doc.use_tabs;
    const r = range orelse Range{ .first = 0, .last = ed.lineCount() - 1 };
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    const from = ed.lineStart(first);
    const to = ed.lineEnd(last);
    const text = ed.bytes();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var runs: usize = 0;
    var row = first;
    while (row <= last) : (row += 1) {
        if (row > first) try out.append(arena, '\n');
        const ls = ed.lineStart(row);
        const le = ed.lineEnd(row);
        var b = ls;
        var vcol: usize = 0;
        while (b <= le) {
            if (b < le and (text[b] == ' ' or text[b] == '\t')) {
                // A run of blanks: measure it at the old tab stop.
                const run_s = b;
                const start_vcol = vcol;
                var got_tab = false;
                var spaces: usize = 0;
                while (b < le and (text[b] == ' ' or text[b] == '\t')) : (b += 1) {
                    if (text[b] == '\t') {
                        got_tab = true;
                        vcol += old_ts - vcol % old_ts;
                    } else {
                        spaces += 1;
                        vcol += 1;
                    }
                }
                const len = vcol - start_vcol;
                if (got_tab or (bang and spaces > 1)) {
                    var tabs: usize = 0;
                    var sp: usize = len;
                    if (!expand) {
                        // Neovim's `tabstop_fromto`: the first tab reaches
                        // the next stop, the rest are whole stops.
                        const init = new_ts - start_vcol % new_ts;
                        if (sp >= init) {
                            sp -= init;
                            tabs = 1 + sp / new_ts;
                            sp %= new_ts;
                        }
                    }
                    if (expand or got_tab or tabs + sp < len) {
                        try out.appendNTimes(arena, '\t', tabs);
                        try out.appendNTimes(arena, ' ', sp);
                        runs += 1;
                        continue;
                    }
                }
                try out.appendSlice(arena, text[run_s..b]);
                continue;
            }
            if (b == le) break;
            const nb = ed.nextBoundary(b);
            vcol += doc.cellsAt(b, vcol);
            try out.appendSlice(arena, text[b..nb]);
            b = nb;
        }
    }
    doc.tab_width = new_ts;
    if (std.mem.eql(u8, out.items, text[from..to])) {
        app.toast(":retab — nothing to change", .{});
        return;
    }
    const cursor = ed.cursor;
    try app.splice(e, from, to, out.items);
    ed.setCursor(@min(cursor, ed.len()));
    app.toast(":retab{s} — {d} run(s){s}", .{ if (bang) "!" else "", runs, if (expand) " to spaces" else "" });
}

/// The tail of `:[range]d[elete] [x] [count]` and
/// `:[range]y[ank] [x] [count]` (`:help :d`, `:help :y`): an optional
/// register takes the lines (an uppercase one appends), and an optional
/// count turns the range into `count` lines from the range's LAST line.
const LineArgs = struct { register: ?u8 = null, count: ?usize = null };

fn isRegisterName(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '+' or c == '*';
}

fn parseLineArgs(app: *App, label: []const u8, args: []const u8) CommandError!LineArgs {
    var out: LineArgs = .{};
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |tok| {
        // A digit is always the count, never register `"1` (`:help :d`);
        // `:1d a2` puts both in one token.
        if (isRegisterName(tok[0])) {
            if (out.register != null or out.count != null) return app.diag.fail(app.frame.allocator(), "{s} — usage: {s} [register] [count]", .{ label, label });
            out.register = tok[0];
            if (tok.len == 1) continue;
            out.count = std.fmt.parseInt(usize, tok[1..], 10) catch return app.diag.fail(app.frame.allocator(), "{s} — not a count: {s}", .{ label, tok[1..] });
            continue;
        }
        if (out.count != null) return app.diag.fail(app.frame.allocator(), "{s} — usage: {s} [register] [count]", .{ label, label });
        out.count = std.fmt.parseInt(usize, tok, 10) catch return app.diag.fail(app.frame.allocator(), "{s} — not a count: {s}", .{ label, tok });
    }
    if (out.count) |c| if (c == 0) return app.diag.fail(app.frame.allocator(), "{s} — E939: positive count required", .{label});
    return out;
}

/// The range the verb really acts on once `[count]` has had its say.
fn linesFor(ed: *const Editor, range: ?Range, count: ?usize) [2]usize {
    const r = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    var first = @min(r.first, ed.lineCount() - 1);
    var last = @min(r.last, ed.lineCount() - 1);
    if (count) |n| {
        first = last;
        last = @min(first +| (n - 1), ed.lineCount() - 1);
    }
    return .{ first, last };
}

fn deleteLines(app: *App, range: ?Range, args: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":d");
    const a = try parseLineArgs(app, ":d", args);
    const ed = e.buf.editor;
    const rows = linesFor(ed, range, a.count);
    const first = rows[0];
    const last = rows[1];
    const start = ed.lineStart(first);
    const end = ed.lineEnd(last);
    const copy = try std.mem.concat(arena, u8, &.{ ed.bytes()[start..end], "\n" });
    if (a.register) |reg| app.clipboard.setPendingRegister(reg);
    try app.clipboard.pushDelete(copy, true);
    const del_start = if (end < ed.len()) start else if (start > 0) start - 1 else start;
    const del_end = if (end < ed.len()) end + 1 else end;
    try app.splice(e, del_start, del_end, "");
    const row = @min(first, ed.lineCount() - 1);
    ed.setCursor(ed.firstNonWs(row));
    ed.goal_col = null;
    app.toast(":d — {d} line(s)", .{last - first + 1});
}

/// `:[range]j[oin][!] [count]` (`:help :join`): the range's lines as
/// one, the way `J` joins them — `!` as `gJ`, no spaces added or
/// removed. A range of one line (or none) joins it with the next; a
/// count joins that many lines from the range's last. The cursor ends
/// on the joined line's first non-blank.
fn joinLines(app: *App, range: ?Range, args: []const u8, bang: bool) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":join");
    const ed = e.buf.editor;
    const a = try parseLineArgs(app, ":join", args);
    if (a.register != null) return app.diag.fail(arena, ":join — usage: :[range]join[!] [count]", .{});
    const n = ed.lineCount();
    const r = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    var first = @min(r.first, n - 1);
    var last = @min(r.last, n - 1);
    if (a.count) |c| {
        first = last;
        last = @min(first + c - 1, n - 1);
    }
    if (last == first) {
        if (first + 1 >= n) return app.diag.fail(arena, ":join — nothing below to join", .{});
        last = first + 1;
    }
    const joins: u32 = @intCast(last - first);
    const one = try arena.create(edit_op.EditOp);
    one.* = .{ .join_lines = .{ .keep_space = !bang } };
    _ = try app.applyOps(e, &.{ .{ .move_to_line = first + 1 }, .{ .atomic = &.{.{ .repeat = .{ .count = joins, .inner = one } }} } });
    ed.setCursor(ed.firstNonWs(first));
    ed.goal_col = null;
}

fn yankLines(app: *App, range: ?Range, args: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":y");
    const a = try parseLineArgs(app, ":y", args);
    const ed = e.buf.editor;
    const rows = linesFor(ed, range, a.count);
    const first = rows[0];
    const last = rows[1];
    const copy = try std.mem.concat(arena, u8, &.{ ed.bytes()[ed.lineStart(first)..ed.lineEnd(last)], "\n" });
    if (a.register) |reg| app.clipboard.setPendingRegister(reg);
    try app.clipboard.setYank(copy, true);
    app.toast(":y — {d} line(s)", .{last - first + 1});
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
    // Macros are registers: `:reg a` shows what `qa…q` recorded.
    for (try app.clipboard.listedNames(arena)) |c| {
        if (want.len > 0 and std.mem.indexOfScalar(u8, want, c) == null) continue;
        const entry = app.clipboard.named.get(c).?;
        if (parts.items.len > 0) try parts.appendSlice(arena, "  ");
        try parts.print(arena, "\"{c}  {s}", .{ c, try preview(arena, entry.text, 40) });
    }
    const msg = if (parts.items.len == 0) ":reg — empty" else try std.fmt.allocPrint(arena, ":reg · {s}", .{parts.items});
    try app.toastPersistent("ex:reg", msg, .info);
}

/// Local marks first (`'a@row:col`), then global (`'A  path:row:col`).
fn marks(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":marks");
    var names: std.ArrayListUnmanaged(u8) = .empty;
    var it = e.buf.doc.marks.keyIterator();
    while (it.next()) |k| try names.append(arena, k.*);
    const globals = try marks_store.letters(app, arena);
    if (names.items.len == 0 and globals.len == 0) {
        app.toast(":marks — none set", .{});
        return;
    }
    std.mem.sort(u8, names.items, {}, std.sort.asc(u8));
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    for (names.items, 0..) |c, i| {
        const pos = e.buf.doc.markPos(c).?;
        try parts.print(arena, "{s}'{c}@{d}:{d}", .{ if (i > 0) "  " else "", c, pos.row + 1, pos.col + 1 });
    }
    for (globals) |c| {
        const m = app.global_marks.get(c).?;
        try parts.print(arena, "{s}'{c}  {s}:{d}:{d}", .{ if (parts.items.len > 0) "  " else "", c, app.relPath(m.path), m.row + 1, m.col + 1 });
    }
    app.toast(":marks · {s}", .{parts.items});
}

fn delmarks(app: *App, args: []const u8, bang: bool) CommandError!void {
    const e = try editor(app, ":delmarks");
    if (bang) {
        const n = e.buf.doc.marks.count();
        e.buf.doc.marks.clearRetainingCapacity();
        app.toast(":delmarks! — cleared {d} local mark(s)", .{n});
        return;
    }
    var n: usize = 0;
    for (std.mem.trim(u8, args, " \t")) |c| {
        if (c == ' ') continue;
        if (marks_store.isGlobal(c)) {
            if (marks_store.remove(app, c)) n += 1;
        } else if (e.buf.doc.marks.remove(c)) n += 1;
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
                const cur = e.wrap orelse app.cfg.ui.wrap;
                e.wrap = if (toggle) !cur else !off;
            } else app.cfg.ui.wrap = !off;
            app.toast(":set {s}", .{opt});
        } else if (eqAny(name, &.{ "ic", "ignorecase" })) {
            app.search_case = off;
            app.toast(":set {s}", .{opt});
        } else if (eqAny(name, &.{ "smartcase", "scs" })) {
            app.search_case = null;
            app.toast(":set {s}", .{opt});
        } else if (eqAny(name, &.{ "theme", "colorscheme" })) {
            const v = value orelse return app.diag.fail(arena, ":set theme=<name>", .{});
            try @import("cmd_view.zig").useTheme(app, v);
        } else if (eqAny(name, &.{ "stickycontext", "sticky", "stickycontext!", "invstickycontext" })) {
            const toggle = std.mem.endsWith(u8, name, "!") or std.mem.startsWith(u8, name, "inv");
            app.cfg.ui.sticky_context = if (toggle) !app.cfg.ui.sticky_context else !off;
            app.toast("sticky context: {s}", .{if (app.cfg.ui.sticky_context) "on" else "off"});
        } else if (eqAny(name, &.{ "input", "keymap" })) {
            const v = value orelse return app.diag.fail(arena, ":set input=vim|standard", .{});
            const style: input.Style = if (std.mem.eql(u8, v, "vim")) .vim else if (std.mem.eql(u8, v, "standard")) .standard else return app.diag.fail(arena, ":set input — unknown style \"{s}\"", .{v});
            try app.setInputStyle(style);
            app.toast(":set input={s}", .{v});
        } else if (eqAny(name, &.{ "ts", "tabstop", "sw", "shiftwidth" })) {
            const v = value orelse return app.diag.fail(arena, ":set {s}=N", .{name});
            const n = std.fmt.parseInt(u8, v, 10) catch return app.diag.fail(arena, ":set {s} — not a number: {s}", .{ name, v });
            app.cfg.editor.tab_width = @max(n, 1);
            for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
                .editor => |*e| e.buf.doc.tab_width = @max(n, 1),
                else => {},
            };
            app.toast(":set {s}={d}", .{ name, n });
        } else if (eqAny(name, &.{ "rightpanel", "rightpanel!", "invrightpanel" })) {
            const toggle = std.mem.endsWith(u8, name, "!") or std.mem.startsWith(u8, name, "inv");
            const want = if (toggle) side.shown(app, .right) == null else !off;
            if (want != (side.shown(app, .right) != null)) try command.run(app, .{ .static = .@"view.toggle_right_panel" });
        } else if (eqAny(name, &.{ "et", "expandtab" })) {
            // Buffer-local in vim, and `Document.use_tabs` is its
            // inverse: what Tab types and what `>>` pads with.
            const e = app.activeEditor() orelse return app.diag.fail(arena, ":set {s} — no editor", .{opt});
            e.buf.setIndent(e.buf.doc.tab_width, e.buf.doc.indent_unit, off);
            app.toast(":set {s}", .{opt});
        } else if (eqAny(name, &.{ "hls", "hlsearch", "is", "incsearch" })) {
            // Accepted for muscle memory; mnml always highlights and
            // always searches as you type, so there is nothing to set.
            app.toast(":set {s} — always on", .{opt});
        } else {
            // Every discrete config field, by its dotted path or bare name.
            try setOption(app, opt, name, value, off);
        }
    }
    if (!any) return app.diag.fail(arena, ":set — usage: :set <option>[=value] | no<option> | <option>! | <option>?  (tab completes)", .{});
}

// ─── :set over the config ────────────────────────────────────────────────

const settings = @import("settings.zig");

/// The vim spellings `:set` understands ahead of the config table.
pub const vim_option_names = [_][]const u8{ "wrap", "ignorecase", "smartcase", "number", "relativenumber", "list", "cursorline", "autoindent", "expandtab", "tabstop", "shiftwidth", "input", "theme", "stickycontext", "rightpanel" };

/// Vim names that are one config field in disguise.
const vim_aliases = [_]struct { name: []const u8, path: []const u8 }{
    .{ .name = "rnu", .path = "ui.relative_line_numbers" },
    .{ .name = "relativenumber", .path = "ui.relative_line_numbers" },
    .{ .name = "list", .path = "ui.show_whitespace" },
    .{ .name = "cul", .path = "ui.cursor_line" },
    .{ .name = "cursorline", .path = "ui.cursor_line" },
    .{ .name = "ai", .path = "editor.auto_indent" },
    .{ .name = "autoindent", .path = "editor.auto_indent" },
    .{ .name = "nu", .path = "ui.line_numbers" },
    .{ .name = "number", .path = "ui.line_numbers" },
};

/// Sections whose values are user-keyed maps or forwarded blobs — no
/// discrete leaf to set.
const skipped_sections = [_][]const u8{ "lsp", "tasks", "snippets", "abbr", "formatters", "linters", "dap", "tools", "keys", "workspaces" };

/// Every `section.field` in `Config` whose type is `bool` or an enum —
/// the same dotted paths the settings overlay's rows name.
pub const option_paths: []const []const u8 = blk: {
    @setEvalBranchQuota(200_000);
    var out: []const []const u8 = &.{};
    for (std.meta.fields(Config)) |sec| {
        if (@typeInfo(sec.type) != .@"struct") continue;
        var skip = false;
        for (skipped_sections) |s| if (std.mem.eql(u8, s, sec.name)) {
            skip = true;
        };
        if (skip) continue;
        for (std.meta.fields(sec.type)) |f| {
            switch (@typeInfo(f.type)) {
                .bool, .@"enum" => out = out ++ &[_][]const u8{sec.name ++ "." ++ f.name},
                else => {},
            }
        }
    }
    break :blk out;
};

/// `name` → the one path it means: an exact dotted path, a vim alias,
/// or a bare field name that exactly one section has.
pub fn resolveOption(name: []const u8) ?[]const u8 {
    for (vim_aliases) |a| if (std.mem.eql(u8, a.name, name)) return a.path;
    var found: ?[]const u8 = null;
    for (option_paths) |path| {
        if (std.mem.eql(u8, path, name)) return path;
        const dot = std.mem.indexOfScalar(u8, path, '.') orelse continue;
        if (std.mem.eql(u8, path[dot + 1 ..], name)) {
            if (found != null) return null; // ambiguous — say the section
            found = path;
        }
    }
    return found;
}

/// `:set <opt>`, `:set no<opt>`, `:set <opt>!`, `:set <opt>?`, `:set <opt>=<value>`
/// on a discrete config field. Applies in memory; the settings overlay
/// is where a value is written to disk.
fn setOption(app: *App, opt: []const u8, name_in: []const u8, value: ?[]const u8, off: bool) CommandError!void {
    const arena = app.frame.allocator();
    var name = name_in;
    var toggle = false;
    var query = false;
    if (std.mem.startsWith(u8, name, "inv")) {
        toggle = true;
        name = name[3..];
    } else if (std.mem.endsWith(u8, name, "!")) {
        toggle = true;
        name = name[0 .. name.len - 1];
    } else if (std.mem.endsWith(u8, name, "?")) {
        query = true;
        name = name[0 .. name.len - 1];
    }
    const path = resolveOption(name) orelse {
        if (name.len > 0 and resolveOption(name) == null and ambiguous(name)) return app.diag.fail(arena, ":set — \"{s}\" is in more than one section; use section.{s}", .{ name, name });
        return app.diag.fail(arena, ":set — unknown option \"{s}\"", .{opt});
    };
    inline for (option_paths) |cp| if (std.mem.eql(u8, cp, path)) {
        const opts = comptime settings.options(cp);
        const cur = settings.currentIndex(&app.cfg, cp);
        if (query) {
            app.toast("{s}={s}", .{ cp, opts[cur] });
            return;
        }
        const idx: usize = if (value) |v| blk: {
            for (opts, 0..) |o, i| if (std.mem.eql(u8, o, v)) break :blk i;
            if (opts.len == 2 and std.mem.eql(u8, opts[0], "off")) {
                if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) break :blk 1;
                if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) break :blk 0;
            }
            return app.diag.fail(arena, ":set {s} — not one of {s}", .{ cp, try joinOptions(arena, opts) });
        } else if (toggle) blk: {
            if (opts.len != 2) return app.diag.fail(arena, ":set {s}! — not a switch; use {s}=<{s}>", .{ cp, cp, try joinOptions(arena, opts) });
            break :blk (cur + 1) % 2;
        } else if (opts.len == 2 and std.mem.eql(u8, opts[0], "off")) @as(usize, @intFromBool(!off)) else {
            return app.diag.fail(arena, ":set {s}=<{s}>", .{ cp, try joinOptions(arena, opts) });
        };
        settings.setIndex(&app.cfg, cp, idx);
        if (comptime std.mem.eql(u8, cp, "editor.input_style")) {
            try app.setInputStyle(if (app.cfg.editor.input_style == .vim) .vim else .standard);
        } else if (comptime std.mem.eql(u8, cp, "editor.clipboard")) {
            app.clipboard.selectMode(app.cfg.editor.clipboard);
        } else if (comptime std.mem.eql(u8, cp, "editor.auto_indent") or std.mem.eql(u8, cp, "editor.trim_trailing_ws_on_save") or std.mem.eql(u8, cp, "editor.ensure_trailing_newline")) {
            try app.syncBufferPrefs();
        }
        app.needs_render = true;
        app.toast("{s}={s}", .{ cp, opts[idx] });
        return;
    };
    return app.diag.fail(arena, ":set — unknown option \"{s}\"", .{opt});
}

fn ambiguous(name: []const u8) bool {
    var n: usize = 0;
    for (option_paths) |path| {
        const dot = std.mem.indexOfScalar(u8, path, '.') orelse continue;
        if (std.mem.eql(u8, path[dot + 1 ..], name)) n += 1;
    }
    return n > 1;
}

fn joinOptions(arena: Allocator, opts: []const []const u8) Allocator.Error![]const u8 {
    return std.mem.join(arena, "|", opts);
}

/// Tab completion for `:set <partial>`: option names (dotted paths, bare
/// field names and the vim spellings) that start with `partial`, or —
/// after a `=` — the values the named option takes. Each candidate is a
/// gpa string the caller frees.
pub fn completeSet(gpa: Allocator, partial: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |c| gpa.free(c);
        out.deinit(gpa);
    }
    if (std.mem.indexOfScalar(u8, partial, '=')) |eq| {
        const name = partial[0..eq];
        const vpart = partial[eq + 1 ..];
        const path = resolveOption(name) orelse return try out.toOwnedSlice(gpa);
        inline for (option_paths) |cp| if (std.mem.eql(u8, cp, path)) {
            for (comptime settings.options(cp)) |o| if (std.mem.startsWith(u8, o, vpart)) {
                try out.append(gpa, try std.mem.concat(gpa, u8, &.{ name, "=", o }));
            };
        };
        return try out.toOwnedSlice(gpa);
    }
    var bare = partial;
    var prefix: []const u8 = "";
    if (std.mem.startsWith(u8, partial, "no") and partial.len > 2) {
        // `:set no<tab>` completes switches, keeping the `no`.
        bare = partial[2..];
        prefix = "no";
    }
    for (vim_option_names) |n| if (std.mem.startsWith(u8, n, partial)) try out.append(gpa, try gpa.dupe(u8, n));
    for (option_paths) |path| {
        const dot = std.mem.indexOfScalar(u8, path, '.') orelse continue;
        const field = path[dot + 1 ..];
        if (std.mem.startsWith(u8, path, partial)) {
            try out.append(gpa, try gpa.dupe(u8, path));
        } else if (bare.len > 0 and (std.mem.startsWith(u8, path, bare) or std.mem.startsWith(u8, field, bare))) {
            try out.append(gpa, try std.mem.concat(gpa, u8, &.{ prefix, path }));
        }
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return try out.toOwnedSlice(gpa);
}

/// `:sidebar left` / `right` / `bottom`: the focused section (else the
/// rail's mark) goes there — Neovim's `Ctrl-W H` / `L` / `J` as words.
/// // changed (bottom-dock): `bottom` names the dock. It runs
/// `side.move` rather than a command id: the dock's two command ids
/// are Rust's `toggle` and `host_active`, and there is no third.
/// `:dock bottom|left|right|inner|outer|always|auto|hidden|icons|labels|text|start|center|end|plus|pin|focus|toggle`
/// — the launcher dock (`app/launcher_dock.zig`), not the bottom panel
/// (`:sidebar bottom`) and not the widgets. `icons` / `labels` /
/// `text` is `ui.dock.labels`, the bottom strip's three forms, and
/// `start` / `center` / `end` is `ui.dock.align`; `plus` flips
/// `ui.dock.plus`, the `+` on the strip; `l` stays `left`, so
/// the label words are spelled out.
/// // changed (dock-polish): `plus left|right` is `ui.dock.plus_at`,
/// which end the `+` takes, and `mark bright|dot|none` is
/// `ui.dock.running_mark`.
/// // changed (dock-placement): `inner` / `outer` is
/// `ui.dock.placement` — a bottom strip above the statusline or under
/// the `:` line. `above` and `below` say the same thing in the words
/// the Settings row uses; `below` is spelled out, so `b` is still
/// `bottom`.
fn launcherDock(app: *App, args: []const u8) CommandError!void {
    const a = std.mem.trim(u8, args, " \t");
    if (eqAny(a, &.{ "b", "bot", "bottom" })) return launcher_dock.setEdge(app, .bottom);
    if (eqAny(a, &.{ "l", "left" })) return launcher_dock.setEdge(app, .left);
    if (eqAny(a, &.{ "r", "right" })) return launcher_dock.setEdge(app, .right);
    if (eqAny(a, &.{ "inner", "above" })) return launcher_dock.setPlacement(app, .inner);
    if (eqAny(a, &.{ "outer", "below" })) return launcher_dock.setPlacement(app, .outer);
    if (eqAny(a, &.{"always"})) return launcher_dock.setMode(app, .always);
    if (eqAny(a, &.{ "auto", "auto_hide", "autohide" })) return launcher_dock.setMode(app, .auto_hide);
    if (eqAny(a, &.{ "hidden", "hide", "off" })) return launcher_dock.setMode(app, .hidden);
    if (eqAny(a, &.{ "icon", "icons" })) return launcher_dock.setLabels(app, .icon);
    if (eqAny(a, &.{ "label", "labels" })) return launcher_dock.setLabels(app, .icon_label);
    // `labels` has meant *icons and labels* since the strip shipped, so
    // the third form takes a word of its own rather than stealing it.
    if (eqAny(a, &.{ "text", "words" })) return launcher_dock.setLabels(app, .label);
    if (eqAny(a, &.{ "center", "centre", "centred", "centered" })) return launcher_dock.setAlign(app, .center);
    if (eqAny(a, &.{"start"})) return launcher_dock.setAlign(app, .start);
    if (eqAny(a, &.{"end"})) return launcher_dock.setAlign(app, .end);
    if (eqAny(a, &.{"plus"})) return launcher_dock.setPlus(app, !app.cfg.ui.dock.plus);
    if (eqAny(a, &.{ "plus right", "plus end" })) return launcher_dock.setPlusAt(app, .right);
    if (eqAny(a, &.{ "plus left", "plus start" })) return launcher_dock.setPlusAt(app, .left);
    if (eqAny(a, &.{ "mark bright", "mark" })) return launcher_dock.setRunningMark(app, .bright);
    if (eqAny(a, &.{"mark dot"})) return launcher_dock.setRunningMark(app, .dot);
    if (eqAny(a, &.{ "mark none", "mark off" })) return launcher_dock.setRunningMark(app, .none);
    if (eqAny(a, &.{"pin"})) return command.run(app, .{ .static = .@"view.dock_pin" });
    if (eqAny(a, &.{ "focus", "f" })) return command.run(app, .{ .static = .@"view.focus_dock" });
    if (a.len == 0 or eqAny(a, &.{"toggle"})) return command.run(app, .{ .static = .@"view.dock_toggle" });
    return app.diag.fail(app.frame.allocator(), ":dock bottom|left|right|inner|outer|always|auto|hidden|icons|labels|text|start|center|end|plus [left|right]|mark bright|dot|none|pin|focus|toggle", .{});
}

fn sidebar(app: *App, args: []const u8) CommandError!void {
    const a = std.mem.trim(u8, args, " \t");
    if (eqAny(a, &.{ "l", "left" })) return command.run(app, .{ .static = .@"view.move_section_left" });
    if (eqAny(a, &.{ "r", "right" })) return command.run(app, .{ .static = .@"view.move_section_right" });
    if (eqAny(a, &.{ "b", "bot", "bottom", "dock" })) return side.move(app, side.targetSection(app), .bottom);
    return app.diag.fail(app.frame.allocator(), ":sidebar left|right|bottom", .{});
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

test "ex: substitute is a vim pattern — groups, &, \\<\\>, \\v, a bad pattern" {
    var f = try Fixture.init("foo1 bar22\nis this\nkey=value");
    defer f.deinit();
    try f.ex("1s/\\(\\a\\+\\)\\(\\d\\+\\)/\\2-\\1/g");
    try testing.expectEqualStrings("1-foo 22-bar\nis this\nkey=value", f.text());
    try f.ex("2s/\\<is\\>/[&]/g");
    try testing.expectEqualStrings("1-foo 22-bar\n[is] this\nkey=value", f.text());
    try f.ex("3s/\\v(\\w+)\\=(\\w+)/\\u\\2: \\U\\1/");
    try testing.expectEqualStrings("1-foo 22-bar\n[is] this\nValue: KEY", f.text());
    try f.ex("%s/^/> /");
    try testing.expectEqualStrings("> 1-foo 22-bar\n> [is] this\n> Value: KEY", f.text());
    try f.ex("%s#\\#\\|>#|#g");
    try testing.expectEqualStrings("| 1-foo 22-bar\n| [is] this\n| Value: KEY", f.text());
    try testing.expectError(error.Failed, f.ex("%s/\\(x/y/"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "invalid pattern") != null);
}

test "ex: :t and :m copy and move lines by address; :cq quits with exit 1" {
    var f = try Fixture.init("alpha\nbravo\ncharlie");
    defer f.deinit();
    try f.ex("t.");
    try testing.expectEqualStrings("alpha\nalpha\nbravo\ncharlie", f.text());
    try testing.expectEqual(@as(usize, 1), f.app.activeEditor().?.buf.editor.currentLine());
    try f.ex("3t0");
    try testing.expectEqualStrings("bravo\nalpha\nalpha\nbravo\ncharlie", f.text());
    try f.ex("1,2t$");
    try testing.expectEqualStrings("bravo\nalpha\nalpha\nbravo\ncharlie\nbravo\nalpha", f.text());
    try f.ex("$m0");
    try testing.expectEqualStrings("alpha\nbravo\nalpha\nalpha\nbravo\ncharlie\nbravo", f.text());
    try f.ex("1m$");
    try testing.expectEqualStrings("bravo\nalpha\nalpha\nbravo\ncharlie\nbravo\nalpha", f.text());
    try testing.expectEqual(@as(usize, 6), f.app.activeEditor().?.buf.editor.currentLine());
    try f.ex("2,3m4");
    try testing.expectEqualStrings("bravo\nbravo\nalpha\nalpha\ncharlie\nbravo\nalpha", f.text());
    try testing.expectError(error.Failed, f.ex("1,3m2"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E134") != null);
    // Onto its own edge: nothing happens, no error.
    try f.ex("2m2");
    try testing.expectEqualStrings("bravo\nbravo\nalpha\nalpha\ncharlie\nbravo\nalpha", f.text());
    // The undo step is one per command.
    const e = f.app.activeEditor().?;
    _ = try f.app.applyOps(e, &.{.undo});
    try testing.expectEqualStrings("bravo\nalpha\nalpha\nbravo\ncharlie\nbravo\nalpha", f.text());
    try f.ex("cq");
    try testing.expect(f.app.quit);
    try testing.expectEqual(@as(u8, 1), f.app.exit_code);
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
    try e.buf.doc.setMarkPos('a', .{ .row = 0, .col = 0 });
    try e.buf.doc.setMarkPos('b', .{ .row = 1, .col = 0 });
    try f.ex("'a,'bd");
    try testing.expectEqualStrings("alpha", f.text());
    try e.buf.editor.setText("\tfoo\nx\ty");
    try f.ex("retab");
    try testing.expectEqualStrings("    foo\nx   y", f.text());
    // Neovim 0.12.5: `:set ts=8 noet` then `:retab!` makes the eight
    // spaces a tab and leaves the tab; `:set ts=4 et`, `é\tx` → three
    // spaces (é is one cell); `:retab 8` re-stops a tab-indented line.
    try e.buf.editor.setText("\tfoo\n        bar");
    e.buf.setIndent(8, 8, true);
    try f.ex("retab!");
    try testing.expectEqualStrings("\tfoo\n\tbar", f.text());
    e.buf.setIndent(4, 4, false);
    try e.buf.editor.setText("é\tx\n中\ty");
    try f.ex("retab");
    try testing.expectEqualStrings("é   x\n中  y", f.text());
    try e.buf.editor.setText("\t\tx\n    y");
    e.buf.setIndent(4, 4, true);
    try f.ex("retab 8");
    try testing.expectEqualStrings("\tx\n    y", f.text());
    try testing.expectEqual(@as(usize, 8), e.buf.doc.tab_width);
    // A range: only line 2.
    e.buf.setIndent(4, 4, false);
    try e.buf.editor.setText("\ta\n\tb");
    try f.ex("2retab");
    try testing.expectEqualStrings("\ta\n    b", f.text());
    try f.ex("2");
    try testing.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
    try f.ex("$");
    try testing.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
}

test "ex: :sort takes a pattern, r, i with u, and the number kinds as Neovim does" {
    // Neovim 0.12.5 `--clean`, each row.
    var f = try Fixture.init("x3 b\nx1 c\nx2 a");
    defer f.deinit();
    try f.ex("sort /x. /");
    try testing.expectEqualStrings("x2 a\nx3 b\nx1 c", f.text());
    try f.ex("sort /x\\d/ r");
    try testing.expectEqualStrings("x1 c\nx2 a\nx3 b", f.text());
    const e = f.app.activeEditor().?;
    try e.buf.editor.setText("b\na\nB\na\nb");
    try f.ex("sort iu");
    try testing.expectEqualStrings("a\nb", f.text());
    // A line with no number sorts first, in its own order; `-` is a sign.
    try e.buf.editor.setText("v10\nnone\nv-2\nv3\nalso");
    try f.ex("sort n");
    try testing.expectEqualStrings("none\nalso\nv-2\nv3\nv10", f.text());
    try e.buf.editor.setText("0x1f\n0xa\n0x2");
    try f.ex("sort x");
    try testing.expectEqualStrings("0x2\n0xa\n0x1f", f.text());
    // A letter that is not a flag is refused, not ignored.
    try testing.expectError(error.Failed, f.ex("sort q"));
}

test "ex: a Visual `:` range covers the cursor's line and the command leaves Visual behind" {
    var f = try Fixture.init("banana\napple\ncherry\ndate\napple\nzebra");
    defer f.deinit();
    try command.run(&f.app, .{ .static = .@"editor.use_vim" });
    const Key = @import("../core/key.zig").Key;
    const e = f.app.activeEditor().?;
    e.buf.editor.setCursor(0);
    // `V4j:sort⏎` sorts all five selected lines — `'>` is the cursor's
    // line (`vim -es`: `2GV2j` → `'<`=2, `'>`=4) — and Normal resumes.
    for ([_]Key{ Key.char('V'), Key.char('4'), Key.char('j'), Key.char(':') }) |k| try dispatch.key(&f.app, k);
    try testing.expectEqual(input.EditingMode.normal, e.buf.input.mode());
    try testing.expectEqualStrings("'<,'>", e.buf.input.cmdlineGet().?);
    for ("sort") |c| try dispatch.key(&f.app, Key.char(c));
    try dispatch.key(&f.app, Key.named(.enter));
    try testing.expectEqualStrings("apple\napple\nbanana\ncherry\ndate\nzebra", f.text());
    try testing.expectEqual(input.EditingMode.normal, e.buf.input.mode());
    // A `u` afterwards is undo, not visual-lowercase.
    try dispatch.key(&f.app, Key.char('u'));
    try testing.expectEqualStrings("banana\napple\ncherry\ndate\napple\nzebra", f.text());
    // `V j :s/a/A/g` reaches both lines; Esc on the `:` line lands in Normal.
    e.buf.editor.setCursor(0);
    for ([_]Key{ Key.char('V'), Key.char('j'), Key.char(':') }) |k| try dispatch.key(&f.app, k);
    for ("s/a/A/g") |c| try dispatch.key(&f.app, Key.char(c));
    try dispatch.key(&f.app, Key.named(.enter));
    try testing.expectEqualStrings("bAnAnA\nApple\ncherry\ndate\napple\nzebra", f.text());
    for ([_]Key{ Key.char('v'), Key.char(':'), Key.named(.esc) }) |k| try dispatch.key(&f.app, k);
    try testing.expectEqual(input.EditingMode.normal, e.buf.input.mode());
    try testing.expect(e.buf.editor.anchor == null);
}

test "ex: u after a ranged :d from far away lands on the restored lines, not where the cursor was" {
    var f = try Fixture.init("one\ntwo\nthree\nfour\nfive\nsix\nseven");
    defer f.deinit();
    try command.run(&f.app, .{ .static = .@"editor.use_vim" });
    const Key = @import("../core/key.zig").Key;
    const e = f.app.activeEditor().?;
    try e.buf.doc.setMarkPos('a', .{ .row = 1, .col = 0 });
    try e.buf.doc.setMarkPos('b', .{ .row = 3, .col = 0 });
    try dispatch.key(&f.app, Key.char('G'));
    try f.ex("'a,'bd");
    try testing.expectEqualStrings("one\nfive\nsix\nseven", f.text());
    // The saved cursor (line 7) is outside the changed block: `u` goes
    // to the first restored line's first non-blank (vim: `:'a,'bd` from
    // line 24, then `u` → line 5).
    try dispatch.key(&f.app, Key.char('u'));
    try testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive\nsix\nseven", f.text());
    try testing.expectEqual(@as(usize, 1), e.buf.editor.currentLine());
    try testing.expectEqual(@as(usize, 4), e.buf.editor.cursor);
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
    try testing.expectEqual(input.Style.vim, f.app.input_style);
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
    // `:w {file}` on a named buffer writes a copy and keeps the name
    // (`:help :w_f`; Neovim 0.12.5 on doc.txt: `%` is still doc.txt).
    try f.ex("w copy.txt");
    try testing.expectEqualStrings("doc.txt", f.app.panes.get(f.app.active.?).?.title());
    _ = try f.tmp.dir.statFile(testing.io, "copy.txt", .{});
}

test "ex: set reaches every discrete config field — dotted, bare, no/!/?/=, aliases, and the errors" {
    var f = try Fixture.init("x");
    defer f.deinit();
    try testing.expect(option_paths.len > 60);
    try testing.expectEqualStrings("ui.relative_line_numbers", resolveOption("rnu").?);
    try testing.expectEqualStrings("ui.relative_line_numbers", resolveOption("relative_line_numbers").?);
    try testing.expect(resolveOption("enabled") == null); // sonos.enabled and marketplace.enabled
    try testing.expect(!f.app.cfg.ui.relative_line_numbers);
    try f.ex("set relative_line_numbers");
    try testing.expect(f.app.cfg.ui.relative_line_numbers);
    try f.ex("set norelative_line_numbers");
    try testing.expect(!f.app.cfg.ui.relative_line_numbers);
    try f.ex("set ui.relative_line_numbers!");
    try testing.expect(f.app.cfg.ui.relative_line_numbers);
    try f.ex("set invrnu");
    try testing.expect(!f.app.cfg.ui.relative_line_numbers);
    try f.ex("set editor.scroll_accel=fast");
    try testing.expectEqual(app_mod.Config.ScrollAccel.fast, f.app.cfg.editor.scroll_accel);
    try f.ex("set scroll_accel?");
    try testing.expectEqualStrings("editor.scroll_accel=fast", f.app.lastToast().?);
    try f.ex("set cursor_line=true");
    try testing.expect(f.app.cfg.ui.cursor_line);
    try testing.expectError(error.Failed, f.ex("set editor.scroll_accel=warp"));
    // `editor.clipboard` is a plain enum field, so the generic path
    // reaches it: bare name, `=`, `?`.
    try f.ex("set clipboard=os");
    try testing.expectEqual(app_mod.Config.Clipboard.os, f.app.cfg.editor.clipboard);
    try f.ex("set editor.clipboard?");
    try testing.expectEqualStrings("editor.clipboard=os", f.app.lastToast().?);
    try f.ex("set clipboard=internal");
    try testing.expectEqual(app_mod.Config.Clipboard.internal, f.app.cfg.editor.clipboard);
    // The sink follows the mode at runtime: with a live writer attached,
    // `.auto` is OSC 52 and `.internal` is nothing.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    f.app.clipboard.attach(testing.io, &aw.writer, null, f.app.cfg.editor.clipboard);
    try testing.expect(f.app.clipboard.os == .none);
    try f.ex("set clipboard=auto");
    try testing.expect(f.app.clipboard.os == .osc52);
    try f.ex("set clipboard=internal");
    try testing.expect(f.app.clipboard.os == .none);
    try testing.expectError(error.Failed, f.ex("set clipboard=unnamedplus"));
    try testing.expectError(error.Failed, f.ex("set editor.scroll_accel!"));
    try testing.expectError(error.Failed, f.ex("set enabled"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "more than one section") != null);
    try testing.expectError(error.Failed, f.ex("set nosuchthing"));
    // The input style goes through setInputStyle, so the keymap follows.
    try f.ex("set editor.input_style=vim");
    try testing.expectEqual(input.Style.vim, f.app.input_style);
    try f.ex("set input_style=standard");
    try testing.expectEqual(input.Style.standard, f.app.input_style);
}

test "ex: set completion — names by path, bare field or vim spelling; values after =; no<tab> keeps the no" {
    const gpa = testing.allocator;
    const free = struct {
        fn f(list: [][]u8) void {
            for (list) |c| gpa.free(c);
            gpa.free(list);
        }
    }.f;
    const a = try completeSet(gpa, "ui.line_n");
    defer free(a);
    try testing.expectEqual(@as(usize, 1), a.len);
    try testing.expectEqualStrings("ui.line_numbers", a[0]);
    const b = try completeSet(gpa, "scroll_acc");
    defer free(b);
    try testing.expectEqual(@as(usize, 1), b.len);
    try testing.expectEqualStrings("editor.scroll_accel", b[0]);
    const c = try completeSet(gpa, "editor.scroll_accel=");
    defer free(c);
    try testing.expectEqual(@as(usize, 4), c.len);
    try testing.expectEqualStrings("editor.scroll_accel=off", c[0]);
    const d = try completeSet(gpa, "scroll_accel=f");
    defer free(d);
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqualStrings("scroll_accel=fast", d[0]);
    const e = try completeSet(gpa, "noline_n");
    defer free(e);
    try testing.expectEqual(@as(usize, 1), e.len);
    try testing.expectEqualStrings("noui.line_numbers", e[0]);
    const g = try completeSet(gpa, "rel");
    defer free(g);
    try testing.expect(g.len >= 2); // relativenumber + ui.relative_line_numbers
    try testing.expectEqualStrings("relativenumber", g[0]);
    const h = try completeSet(gpa, "zzz");
    defer free(h);
    try testing.expectEqual(@as(usize, 0), h.len);
}

test "ex: Tab on `:set ui.line_n` completes the option on the : line" {
    var f = try Fixture.init("x");
    defer f.deinit();
    const Key = app_mod.Key;
    try f.app.setInputStyle(.vim);
    try f.app.handle(.{ .key = Key.char(':') });
    for ("set ui.line_n") |c| try f.app.handle(.{ .key = Key.char(c) });
    try f.app.handle(.{ .key = Key.named(.tab) });
    const e = f.app.activeEditor().?;
    try testing.expectEqualStrings("set ui.line_numbers", e.buf.input.cmdlineGet().?);
    // Enter runs it; the gutter flag flips.
    try testing.expect(f.app.cfg.ui.line_numbers);
    try f.app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(f.app.cfg.ui.line_numbers); // bare `set x` on a switch = on
    try f.app.handle(.{ .key = Key.char(':') });
    for ("set noui.line_numbers") |c| try f.app.handle(.{ .key = Key.char(c) });
    try f.app.handle(.{ .key = Key.named(.enter) });
    try testing.expect(!f.app.cfg.ui.line_numbers);
}

test "ex: :messages opens the picker, :messages! dumps, :cn/:cp walk the quickfix list" {
    var f = try Fixture.init("x");
    defer f.deinit();
    try testing.expectError(error.Failed, f.ex("messages")); // nothing yet
    f.app.toast("hello there", .{});
    try f.ex("messages");
    try testing.expect(f.app.overlay == .picker);
    f.app.overlay.deinit(f.app.gpa);
    try f.ex("messages!");
    try testing.expect(std.mem.indexOf(u8, f.app.activeEditor().?.buf.editor.bytes(), "hello there") != null);
    try testing.expectError(error.Failed, f.ex("cn"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "no quickfix list") != null);
}

test "ex: q refuses a dirty buffer, q! discards, the last close quits" {
    var f = try Fixture.init("hi");
    defer f.deinit();
    const e = f.app.activeEditor().?;
    try e.buf.editor.setText("dirty");
    e.buf.doc.dirty = true;
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
