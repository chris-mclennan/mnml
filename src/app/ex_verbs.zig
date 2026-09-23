//! The ex verbs that reach past one line or past the buffer: `:g` /
//! `:v` (a command on every matching line), `:norm` (keys through the
//! editor's handler, once per line), user `:command`s, `:!cmd`, `:r`,
//! `:<` / `:>`, `:&`, and the `c` / `n` flags of `:s` (a per-match
//! prompt; a count with nothing replaced).
//! `ex.zig` parses the range and the verb and hands the rest here.
//!
//! Two of these re-enter the interpreter (`:g` runs an ex line per
//! match, a user command expands to one, `:norm` can type a `:` line),
//! so `App.ex_depth` bounds the nesting and `App.in_global` refuses a
//! `:g` inside a `:g` (vim's E147).
//!
//! `:command` definitions persist at `<data root>/commands.zon`; the
//! `.startup` hook reads them back.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const EditorPane = app_mod.EditorPane;
const PaneId = app_mod.PaneId;
const Key = app_mod.Key;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const ex = @import("ex.zig");
const Range = ex.Range;
const find_mod = @import("find.zig");
const regex = @import("../regex/regex.zig");
const buffer_mod = @import("../editor/buffer.zig");
const Editor = @import("../editor/editor.zig").Editor;
const hooks = @import("../core/hooks.zig");
const input = @import("../input/mod.zig");

/// How deep `:g` → user command → `:norm` → `:` may nest.
pub const max_depth: u8 = 8;
pub const commands_file = "commands.zon";
pub const max_user_commands: usize = 200;

fn enter(app: *App, label: []const u8) CommandError!void {
    if (app.ex_depth >= max_depth) return app.diag.fail(app.frame.allocator(), "{s} — E169: command too recursive", .{label});
    app.ex_depth += 1;
}

fn leave(app: *App) void {
    app.ex_depth -= 1;
}

fn editor(app: *App, label: []const u8) CommandError!*EditorPane {
    return app.requireEditor() catch |err| {
        return app.diag.fail(app.frame.allocator(), "{s} — no active editor", .{label}) catch err;
    };
}

/// `app.search_case`, else smart case on the pattern.
fn caseFor(app: *App, needle: []const u8) bool {
    return app.search_case orelse find_mod.patternHasUpper(needle);
}

fn lineHas(line: []const u8, re: *regex.Regex) bool {
    return re.find(line, 0) != null;
}

/// Split `/pat/cmd` at the first unescaped delimiter (`spec[0]`, any
/// non-alphanumeric char). `tail` is everything after it, or empty when
/// the delimiter never closes.
fn splitDelimited(spec: []const u8) ?struct { pattern: []const u8, tail: []const u8 } {
    if (spec.len == 0) return null;
    const delim = spec[0];
    if (std.ascii.isAlphanumeric(delim) or delim == '\\' or delim == '"' or delim == '|' or delim == ' ') return null;
    var j: usize = 1;
    while (j < spec.len) : (j += 1) {
        if (spec[j] == delim and spec[j - 1] != '\\') return .{ .pattern = spec[1..j], .tail = spec[j + 1 ..] };
    }
    return .{ .pattern = spec[1..], .tail = "" };
}

// ─── :g / :v ─────────────────────────────────────────────────────────────

/// `:[range]g[!]/pat/[cmd]` and `:v/pat/[cmd]`: `cmd` (default `p`) runs
/// with the cursor on every line that matches (`:v`: does not match).
/// The whole buffer when there is no range.
///
/// Line numbers stay right under a command that adds or removes lines:
/// the remaining targets are byte offsets mapped through the editor's
/// edit log after each run, so `:g/x/d` and `:g/x/norm o` both visit
/// exactly the lines that matched at the start.
pub fn global(app: *App, range: ?Range, spec_in: []const u8, invert: bool) CommandError!void {
    const arena = app.frame.allocator();
    const label: []const u8 = if (invert) ":v" else ":g";
    const e = try editor(app, label);
    const pane_id = app.active.?;
    const spec = std.mem.trimStart(u8, spec_in, " \t");
    var parts = splitDelimited(spec) orelse return app.diag.fail(arena, "{s} — usage: {s}/pattern/command", .{ label, label });
    if (parts.pattern.len == 0) {
        // `:g//cmd` reuses the last search pattern, as `:s//new/` does.
        const last = app.last_search_pattern orelse return app.diag.fail(arena, "{s} — E35: no pattern", .{label});
        parts.pattern = try arena.dupe(u8, last);
    }
    if (app.in_global) return app.diag.fail(arena, "{s} — E147: cannot do :global recursive", .{label});
    const needle = try ex.unescapeDelim(arena, parts.pattern, spec[0]);
    // `:g/pat/` writes the last search pattern, so the `s//` inside it
    // — the everyday `:g/pat/s//new/g` — finds it. The still-escaped
    // form, as `:s` stores: the reader rebuilds a `/…/` spec from it.
    try app.noteSearchPattern(parts.pattern);
    var re = try ex.compilePattern(app, label, needle, caseFor(app, needle));
    defer re.deinit();
    var cmd = std.mem.trim(u8, parts.tail, " \t");
    if (cmd.len == 0) cmd = "p";

    const ed = e.buf.editor;
    const r = range orelse Range{ .first = 0, .last = ed.lineCount() - 1 };
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    // Targets as line-start bytes; `null` once an edit swallowed one.
    var targets: std.ArrayListUnmanaged(?usize) = .empty;
    var row = first;
    while (row <= last) : (row += 1) {
        if (lineHas(ed.lineSlice(row), &re) != invert) try targets.append(arena, ed.lineStart(row));
    }
    if (targets.items.len == 0) {
        // Vim's `ex_global`: `:v` with every line matching says so;
        // E486 is the `:g` wording and would claim the opposite.
        if (invert) return app.diag.fail(arena, "{s} — Pattern found in every line: {s}", .{ label, needle });
        return app.diag.fail(arena, "{s} — E486: pattern not found: {s}", .{ label, needle });
    }
    const total = targets.items.len;

    if (isPrint(cmd)) {
        var first_line: []const u8 = "";
        for (targets.items, 0..) |t, i| {
            const line = ed.lineSlice(ed.lineOfByte(t.?));
            if (i == 0) first_line = line;
            try app.messages.record(app.gpa, line, .info, app.now_ms);
        }
        app.toast("{s}/{s}/p — {d} line(s); first: {s} · :messages", .{ label, needle, total, try preview(arena, first_line, 50) });
        return;
    }

    try enter(app, label);
    defer leave(app);
    app.in_global = true;
    defer app.in_global = false;
    // One `:g` is one undo step (`:help :g`, `:help undo-blocks`):
    // every sub-command's checkpoint collapses into this one.
    const tok = try ed.beginAtomic();
    const head_before = ed.doc.edits.head();
    var seen = ed.doc.edits.head();
    var ran: usize = 0;
    var failed: usize = 0;
    var i: usize = 0;
    while (i < targets.items.len) : (i += 1) {
        const pane = app.panes.editor(pane_id) orelse break;
        if (app.active != pane_id) break;
        const cur = pane.buf.editor;
        // Map what is left through the edits the last command made.
        if (cur.doc.edits.replacedSince(seen)) {
            app.in_global = false;
            app.toast("{s} — stopped after {d}: the text was replaced wholesale", .{ label, ran });
            break;
        }
        for (cur.doc.edits.since(seen)) |sp| {
            for (targets.items[i..]) |*t| {
                const b = t.* orelse continue;
                if (b >= sp.old_end) {
                    t.* = b + sp.new_end - sp.old_end;
                } else if (b > sp.start) {
                    t.* = null;
                }
            }
        }
        seen = cur.doc.edits.head();
        const b = targets.items[i] orelse continue;
        if (b > cur.len()) continue;
        cur.placeCursor(cur.lineOfByte(b), 0);
        cur.anchor = null;
        ex.run(app, cmd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                failed += 1;
                continue;
            },
        };
        ran += 1;
    }
    if (app.panes.editor(pane_id)) |pane| {
        const cur = pane.buf.editor;
        cur.endAtomic(tok);
        // Nothing edited: no step to undo either.
        if (cur.doc.edits.head() == head_before and !cur.doc.edits.lostSince(head_before)) cur.popCheckpoint();
    }
    app.diag.clear();
    // The summary is the one message the run makes; the sub-commands'
    // were silenced while `in_global` was set.
    app.in_global = false;
    if (failed > 0) {
        app.toast("{s} — ran on {d} line(s), {d} failed", .{ label, ran, failed });
    } else app.toast("{s} — ran on {d} line(s)", .{ label, ran });
}

fn isPrint(cmd: []const u8) bool {
    const names = [_][]const u8{ "p", "print", "#", "nu", "number", "l", "list" };
    for (names) |n| if (std.mem.eql(u8, cmd, n)) return true;
    return false;
}

/// Up to `cap` chars, `…` when cut.
fn preview(arena: Allocator, s: []const u8, cap: usize) Allocator.Error![]const u8 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |g| {
        if (n == cap) return try std.mem.concat(arena, u8, &.{ s[0 .. @intFromPtr(g.ptr) - @intFromPtr(s.ptr)], "…" });
        n += 1;
    }
    return s;
}

// ─── :norm ───────────────────────────────────────────────────────────────

/// `:[range]norm[!] keys`: put the cursor at the start of each line in
/// the range (default: the cursor's line) and type `keys` through the
/// active handler, then Esc so an insert never leaks into the next
/// line. `<esc>` / `<cr>` / `<c-x>` notation is understood.
/// // changed: vim types `<esc>` literally; mnml-zig's `:` line cannot
/// take a raw Esc, so the notation is the only way to spell one.
pub fn normal(app: *App, range: ?Range, keys_spec: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":norm");
    const pane_id = app.active.?;
    if (keys_spec.len == 0) return app.diag.fail(arena, ":norm — E471: keys required", .{});
    const keys = buffer_mod.parseKeys(app.gpa, keys_spec) catch return error.OutOfMemory;
    defer app.gpa.free(keys);
    try enter(app, ":norm");
    defer leave(app);
    const ed = e.buf.editor;
    const r = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    var row = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    var n: usize = 0;
    while (row <= last) : (row += 1) {
        const pane = app.panes.editor(pane_id) orelse break;
        if (app.active != pane_id or app.overlay != .none) break;
        if (row >= pane.buf.editor.lineCount()) break;
        pane.buf.editor.placeCursor(row, 0);
        pane.buf.editor.anchor = null;
        // A key that fails (`j` on the last line, a search with no
        // match) ends this line's keys, as it ends a macro.
        for (keys) |k| {
            try app.handle(.{ .key = k });
            if (app.key_failed) break;
        }
        try app.handle(.{ .key = Key.named(.esc) });
        n += 1;
    }
    app.toast(":norm — {d} line(s)", .{n});
}

// ─── :command ────────────────────────────────────────────────────────────

pub const Stored = struct {
    commands: []const Entry = &.{},
    pub const Entry = struct { name: []const u8, rhs: []const u8 };
};

/// `:command[!] [-flags] Name rhs` defines; `:command` lists; `:command
/// Name` shows one. Names start with an uppercase letter (E183); an
/// existing name needs the `!` (E174).
pub fn defineCommand(app: *App, args_in: []const u8, bang: bool) CommandError!void {
    const arena = app.frame.allocator();
    var args = std.mem.trim(u8, args_in, " \t");
    // vim's attribute flags are accepted and not needed: every user
    // command takes any args, a bang and a range.
    while (args.len > 0 and args[0] == '-') {
        const sp = std.mem.indexOfAny(u8, args, " \t") orelse args.len;
        args = std.mem.trimStart(u8, args[sp..], " \t");
    }
    if (args.len == 0) return listCommands(app, "");
    const sp = std.mem.indexOfAny(u8, args, " \t") orelse args.len;
    const name = args[0..sp];
    const rhs = std.mem.trim(u8, args[sp..], " \t");
    if (rhs.len == 0) return listCommands(app, name);
    if (!std.ascii.isUpper(name[0])) return app.diag.fail(arena, ":command — E183: user defined commands must start with an uppercase letter", .{});
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return app.diag.fail(arena, ":command — E182: invalid command name \"{s}\"", .{name});
    const gpa = app.gpa;
    if (app.user_commands.getPtr(name)) |slot| {
        if (!bang) return app.diag.fail(arena, ":command — E174: command already exists: add ! to replace it: {s}", .{name});
        const value = try gpa.dupe(u8, rhs);
        gpa.free(slot.*);
        slot.* = value;
    } else {
        if (app.user_commands.count() >= max_user_commands) return app.diag.fail(arena, ":command — too many user commands ({d})", .{max_user_commands});
        const value = try gpa.dupe(u8, rhs);
        errdefer gpa.free(value);
        const key = try gpa.dupe(u8, name);
        errdefer gpa.free(key);
        try app.user_commands.put(gpa, key, value);
    }
    app.toast(":command {s} = {s}", .{ name, rhs });
    try store(app);
}

/// `:delcommand Name` (E184 when unknown).
pub fn deleteCommand(app: *App, args: []const u8) CommandError!void {
    const name = std.mem.trim(u8, args, " \t");
    if (name.len == 0) return app.diag.fail(app.frame.allocator(), ":delcommand — usage: :delcommand <Name>", .{});
    const kv = app.user_commands.fetchRemove(name) orelse return app.diag.fail(app.frame.allocator(), ":delcommand — E184: no such user-defined command: {s}", .{name});
    app.gpa.free(kv.key);
    app.gpa.free(kv.value);
    app.toast(":delcommand {s} — removed", .{name});
    try store(app);
}

fn listCommands(app: *App, prefix: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const names = try sortedNames(app, arena, prefix);
    if (names.len == 0) {
        if (prefix.len > 0) return app.diag.fail(arena, ":command — E184: no such user-defined command: {s}", .{prefix});
        app.toast(":command — none defined", .{});
        return;
    }
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    for (names, 0..) |n, i| try parts.print(arena, "{s}{s}={s}", .{ if (i > 0) "  " else "", n, try preview(arena, app.user_commands.get(n).?, 30) });
    app.toast(":command · {s}", .{parts.items});
}

/// User command names starting with `prefix`, sorted, on `arena`.
pub fn sortedNames(app: *App, arena: Allocator, prefix: []const u8) Allocator.Error![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = app.user_commands.keyIterator();
    while (it.next()) |k| if (std.mem.startsWith(u8, k.*, prefix)) try names.append(arena, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return names.items;
}

/// Run `name` if it is a user command. `<args>` / `<q-args>`, `<bang>`,
/// `<line1>` / `<line2>` / `<range>` are substituted; a typed range with
/// no placeholder in the definition is put in front of the expansion.
pub fn runUserCommand(app: *App, range: ?Range, name: []const u8, bang: bool, args: []const u8) CommandError!bool {
    const rhs = app.user_commands.get(name) orelse return false;
    const arena = app.frame.allocator();
    const e = app.activeEditor();
    const cur: usize = if (e) |ed| ed.buf.editor.currentLine() else 0;
    const r = range orelse Range{ .first = cur, .last = cur };
    const line1 = try std.fmt.allocPrint(arena, "{d}", .{r.first + 1});
    const line2 = try std.fmt.allocPrint(arena, "{d}", .{r.last + 1});
    const range_text = if (range != null) try std.fmt.allocPrint(arena, "{s},{s}", .{ line1, line2 }) else "";
    const subs = [_]struct { tag: []const u8, value: []const u8 }{
        .{ .tag = "<q-args>", .value = args },
        .{ .tag = "<args>", .value = args },
        .{ .tag = "<bang>", .value = if (bang) "!" else "" },
        .{ .tag = "<line1>", .value = line1 },
        .{ .tag = "<line2>", .value = line2 },
        .{ .tag = "<range>", .value = range_text },
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var placed_range = false;
    var i: usize = 0;
    outer: while (i < rhs.len) {
        for (subs, 0..) |s, si| if (std.mem.startsWith(u8, rhs[i..], s.tag)) {
            try out.appendSlice(arena, s.value);
            if (si >= 3) placed_range = true;
            i += s.tag.len;
            continue :outer;
        };
        try out.append(arena, rhs[i]);
        i += 1;
    }
    const expanded = if (range != null and !placed_range) try std.mem.concat(arena, u8, &.{ range_text, out.items }) else out.items;
    try enter(app, name);
    defer leave(app);
    try ex.run(app, expanded);
    return true;
}

/// `<data root>/commands.zon`.
pub fn pathFor(arena: Allocator, data_root: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(arena, &.{ data_root, commands_file });
}

fn store(app: *App) Allocator.Error!void {
    if (app.data_root.len == 0) return;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const names = try sortedNames(app, arena, "");
    const entries = try arena.alloc(Stored.Entry, names.len);
    for (names, 0..) |n, i| entries[i] = .{ .name = n, .rhs = app.user_commands.get(n).? };
    var out: std.Io.Writer.Allocating = .init(arena);
    out.writer.writeAll("// mnml user commands — `:command Name rhs` writes this; `:delcommand Name` removes one.\n") catch return error.OutOfMemory;
    std.zon.stringify.serialize(Stored{ .commands = entries }, .{ .emit_default_optional_fields = false }, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    const target = try pathFor(arena, app.data_root);
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(app.io, app.data_root) catch {};
    cwd.writeFile(app.io, .{ .sub_path = target, .data = out.written() }) catch {
        app.toast(":command — could not write {s}", .{target});
    };
}

/// Read the definitions back. Returns how many landed.
pub fn load(app: *App) Allocator.Error!usize {
    if (app.data_root.len == 0) return 0;
    var arena_state = std.heap.ArenaAllocator.init(app.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const target = try pathFor(arena, app.data_root);
    const src: [:0]u8 = Io.Dir.cwd().readFileAllocOptions(app.io, target, arena, .limited(1024 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return 0,
    };
    const stored = std.zon.parse.fromSliceAlloc(Stored, arena, src, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return 0,
    };
    var n: usize = 0;
    for (stored.commands) |c| {
        if (c.name.len == 0 or !std.ascii.isUpper(c.name[0]) or c.rhs.len == 0) continue;
        if (app.user_commands.contains(c.name)) continue;
        if (app.user_commands.count() >= max_user_commands) break;
        const value = try app.gpa.dupe(u8, c.rhs);
        errdefer app.gpa.free(value);
        const key = try app.gpa.dupe(u8, c.name);
        errdefer app.gpa.free(key);
        try app.user_commands.put(app.gpa, key, value);
        n += 1;
    }
    return n;
}

pub fn onStartup(app: *App, _: hooks.HookArgs) void {
    _ = load(app) catch {};
}

pub fn deinitCommands(app: *App) void {
    var it = app.user_commands.iterator();
    while (it.next()) |kv| {
        app.gpa.free(kv.key_ptr.*);
        app.gpa.free(kv.value_ptr.*);
    }
    app.user_commands.deinit(app.gpa);
}

// ─── :! and :r ───────────────────────────────────────────────────────────

pub const ShellResult = struct {
    stdout: []u8,
    /// The exit code, or null when the child was signalled.
    code: ?u8,
};

pub const ShellError = Allocator.Error || error{Spawn};

/// Run `cmd` through the shell in the workspace; `stdin` is fed when
/// given. stderr is merged into stdout for `show`, dropped otherwise
/// (a filter's or `:r !`'s stderr would corrupt the text).
pub fn runShell(app: *App, arena: Allocator, cmd: []const u8, stdin: ?[]const u8, show: bool) ShellError!ShellResult {
    const line = if (show) try std.mem.concat(arena, u8, &.{ "(", cmd, ") 2>&1" }) else cmd;
    const argv: []const []const u8 = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/C", line } else &.{ "/bin/sh", "-c", line };
    var child = std.process.spawn(app.io, .{
        .argv = argv,
        .cwd = .{ .path = app.workspace },
        .environ_map = &app.env,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Spawn,
    };
    if (child.stdin) |in| {
        var wbuf: [4096]u8 = undefined;
        var w: std.Io.File.Writer = .init(in, app.io, &wbuf);
        w.interface.writeAll(stdin.?) catch {};
        w.interface.flush() catch {};
        in.close(app.io);
        child.stdin = null;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (child.stdout) |stdout| {
        var rbuf: [4096]u8 = undefined;
        var r: std.Io.File.Reader = .init(stdout, app.io, &rbuf);
        while (true) {
            var chunk: [4096]u8 = undefined;
            const n = r.interface.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            try out.appendSlice(arena, chunk[0..n]);
        }
    }
    const term: ?std.process.Child.Term = child.wait(app.io) catch null;
    const code: ?u8 = if (term) |t| switch (t) {
        .exited => |c| c,
        else => null,
    } else null;
    return .{ .stdout = out.items, .code = code };
}

/// `:!cmd` shows the output in a scratch pane (reused across runs);
/// `:!!` repeats the last one; `:[range]!cmd` filters the range through
/// it. `:r !cmd` and the filter prompt share `runShell`.
pub fn shell(app: *App, range: ?Range, args_in: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    var cmd = std.mem.trim(u8, args_in, " \t");
    if (std.mem.eql(u8, cmd, "!")) {
        cmd = app.last_shell_cmd orelse return app.diag.fail(arena, ":!! — no previous :! command", .{});
    }
    if (cmd.len == 0) return app.diag.fail(arena, ":! — usage: :!<command>", .{});
    if (!std.mem.eql(u8, cmd, app.last_shell_cmd orelse "")) {
        const copy = try app.gpa.dupe(u8, cmd);
        if (app.last_shell_cmd) |old| app.gpa.free(old);
        app.last_shell_cmd = copy;
    }
    const cmd_owned = app.last_shell_cmd.?;
    if (range) |r| return filter(app, r, cmd_owned);
    const res = runShell(app, arena, cmd_owned, null, true) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Spawn => return app.diag.fail(arena, ":!{s} — could not start the shell", .{cmd_owned}),
    };
    try showOutput(app, cmd_owned, res.stdout);
    if (res.code) |c| {
        if (c == 0) app.toast("!{s} — done", .{cmd_owned}) else app.toast("!{s} — exit {d}", .{ cmd_owned, c });
    } else app.toast("!{s} — killed", .{cmd_owned});
}

/// The `:!` output pane: a scratch buffer kept for the next run.
pub fn showOutput(app: *App, cmd: []const u8, text: []const u8) CommandError!void {
    const body = try std.mem.concat(app.frame.allocator(), u8, &.{ "$ ", cmd, "\n", text });
    const id: PaneId = blk: {
        if (app.shell_pane) |id| if (app.panes.editor(id)) |e| if (e.buf.doc.path == null) {
            app.showPane(id);
            break :blk id;
        };
        const id = app.openScratch() catch return error.OutOfMemory;
        app.shell_pane = id;
        break :blk id;
    };
    const e = app.panes.editor(id).?;
    try e.buf.editor.setText(body);
    try e.buf.doc.markSaved();
    e.buf.editor.setCursor(0);
    e.syntax.dirty = true;
    app.needs_render = true;
}

/// `:[range]!cmd`: the lines through the command, replaced by its stdout.
fn filter(app: *App, r: Range, cmd: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":!");
    const ed = e.buf.editor;
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    const start = ed.lineStart(first);
    const end = ed.lineEnd(last);
    const fed = try std.mem.concat(arena, u8, &.{ ed.bytes()[start..end], "\n" });
    const res = runShell(app, arena, cmd, fed, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Spawn => return app.diag.fail(arena, ":!{s} — could not start the shell", .{cmd}),
    };
    const trimmed = std.mem.trimEnd(u8, res.stdout, "\n");
    try app.splice(e, start, end, trimmed);
    ed.setCursor(ed.firstNonWs(@min(first, ed.lineCount() - 1)));
    ed.goal_col = null;
    app.toast("!{s} — {d} line(s)", .{ cmd, if (trimmed.len == 0) 0 else std.mem.count(u8, trimmed, "\n") + 1 });
}

/// `:[line]r file` / `:r !cmd`: the file's text (or the command's
/// stdout) on new lines after `line` (default: the cursor's).
pub fn read(app: *App, range: ?Range, args_in: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const e = try editor(app, ":r");
    const args = std.mem.trim(u8, args_in, " \t");
    if (args.len == 0) return app.diag.fail(arena, ":r — usage: :r <file> | :r !<command>", .{});
    var body: []const u8 = undefined;
    var what: []const u8 = args;
    if (args[0] == '!') {
        var cmd = std.mem.trim(u8, args[1..], " \t");
        if (std.mem.eql(u8, cmd, "!")) cmd = app.last_shell_cmd orelse return app.diag.fail(arena, ":r !! — no previous :! command", .{});
        if (cmd.len == 0) return app.diag.fail(arena, ":r ! — command required", .{});
        if (!std.mem.eql(u8, cmd, app.last_shell_cmd orelse "")) {
            const copy = try app.gpa.dupe(u8, cmd);
            if (app.last_shell_cmd) |old| app.gpa.free(old);
            app.last_shell_cmd = copy;
        }
        const res = runShell(app, arena, app.last_shell_cmd.?, null, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Spawn => return app.diag.fail(arena, ":r !{s} — could not start the shell", .{cmd}),
        };
        body = res.stdout;
        what = try std.mem.concat(arena, u8, &.{ "!", app.last_shell_cmd.? });
    } else {
        const abs = try app.absPath(try @import("ex.zig").fileArg(app, ":r", args));
        body = Io.Dir.cwd().readFileAlloc(app.io, abs, arena, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return app.diag.fail(arena, ":r — E484: can't open file {s} ({s})", .{ args, @errorName(err) }),
        };
    }
    const text = std.mem.trimEnd(u8, body, "\n");
    const ed = e.buf.editor;
    const row = @min(if (range) |r| r.last else ed.currentLine(), ed.lineCount() - 1);
    const at = ed.lineEnd(row);
    const payload = try std.mem.concat(arena, u8, &.{ "\n", text });
    try app.splice(e, at, at, payload);
    const land = @min(row + 1, ed.lineCount() - 1);
    ed.setCursor(ed.firstNonWs(land));
    ed.goal_col = null;
    app.toast(":r {s} — {d} line(s)", .{ what, std.mem.count(u8, text, "\n") + 1 });
}

// ─── :< / :> ─────────────────────────────────────────────────────────────

/// `:[range]>[>…] [count]` / `:<`: shift the lines by one shift width
/// per repeated sign; a count means "this many lines from the range's
/// last line". Blank lines are left alone by `>`. One undo step; the
/// cursor lands on the last shifted line, like vim.
pub fn shift(app: *App, range: ?Range, right: bool, args: []const u8) CommandError!void {
    const arena = app.frame.allocator();
    const label: []const u8 = if (right) ":>" else ":<";
    const e = try editor(app, label);
    const ed = e.buf.editor;
    const sign: u8 = if (right) '>' else '<';
    var times: usize = 1;
    var i: usize = 0;
    while (i < args.len and args[i] == sign) : (i += 1) times += 1;
    const count_s = std.mem.trim(u8, args[i..], " \t");
    const base = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    var first = @min(base.first, ed.lineCount() - 1);
    var last = @min(base.last, ed.lineCount() - 1);
    if (count_s.len > 0) {
        const n = std.fmt.parseInt(usize, count_s, 10) catch return app.diag.fail(arena, "{s} — E488: trailing characters: {s}", .{ label, count_s });
        if (n == 0) return app.diag.fail(arena, "{s} — E939: positive count required", .{label});
        first = last;
        last = @min(last + n - 1, ed.lineCount() - 1);
    }
    const tw: usize = @max(ed.doc.tab_width, 1);
    const width = tw * times;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var row = first;
    while (row <= last) : (row += 1) {
        const line = ed.lineSlice(row);
        if (right) {
            if (line.len > 0) try out.appendNTimes(arena, ' ', width);
            try out.appendSlice(arena, line);
        } else {
            // Drop up to `width` columns of leading whitespace.
            var col: usize = 0;
            var j: usize = 0;
            while (j < line.len and col < width) : (j += 1) {
                if (line[j] == ' ') {
                    col += 1;
                } else if (line[j] == '\t') {
                    col += tw - (col % tw);
                } else break;
            }
            try out.appendSlice(arena, line[j..]);
        }
        if (row < last) try out.append(arena, '\n');
    }
    try app.splice(e, ed.lineStart(first), ed.lineEnd(last), out.items);
    ed.setCursor(ed.firstNonWs(@min(last, ed.lineCount() - 1)));
    ed.goal_col = null;
    const n = last - first + 1;
    app.toast("{d} line(s) {c}ed {d} time(s)", .{ n, sign, times });
}

// ─── :s — the last substitute, `:&`, and the `c` flag ────────────────────

/// What `:&` repeats.
pub const LastSub = struct {
    delim: u8,
    pattern: []u8,
    replacement: []u8,
    flags: []u8,

    pub fn deinit(s: LastSub, gpa: Allocator) void {
        gpa.free(s.pattern);
        gpa.free(s.replacement);
        gpa.free(s.flags);
    }
};

const SubParts = struct { delim: u8, pattern: []const u8, replacement: []const u8, flags: []const u8 };

/// `/pat/rep/flags` into its three parts (the pattern may be empty —
/// `:s//x/` reuses the last one).
fn splitSub(spec: []const u8) ?SubParts {
    if (spec.len == 0) return null;
    const delim = spec[0];
    if (std.ascii.isAlphanumeric(delim) or delim == '\\' or delim == '"' or delim == '|' or delim == ' ') return null;
    var parts: [3][]const u8 = .{ "", "", "" };
    var n: usize = 0;
    var start: usize = 1;
    var j: usize = 1;
    while (j <= spec.len and n < 3) : (j += 1) {
        if (j == spec.len or (spec[j] == delim and spec[j - 1] != '\\')) {
            parts[n] = spec[start..j];
            n += 1;
            start = j + 1;
        }
    }
    return .{ .delim = delim, .pattern = parts[0], .replacement = parts[1], .flags = parts[2] };
}

/// The `:s/…` entry: remembers the spec for `:&`, fills an empty pattern
/// from the last one, and routes a `c` flag to the prompt.
pub fn substituteEntry(app: *App, range: ?Range, spec: []const u8, whole: bool) CommandError!void {
    const arena = app.frame.allocator();
    const label: []const u8 = if (whole) ":%s" else ":s";
    var parts = splitSub(spec) orelse return app.diag.fail(arena, "{s} — usage: {s}/old/new/[flags]", .{ label, label });
    if (parts.pattern.len == 0) {
        // An empty search part reuses vim's ONE last search pattern —
        // whichever of `/` `?` `*` `#` `:s` `:g` wrote it last, not just
        // a previous `:s` (`:help :s`, `:help E35`).
        const last = app.last_search_pattern orelse return app.diag.fail(arena, "{s} — E35: no previous regular expression", .{label});
        parts.pattern = try arena.dupe(u8, last);
    }
    try remember(app, parts);
    // `remember` freed the previous spec — an empty pattern borrowed from it.
    parts.pattern = app.last_substitute.?.pattern;
    if (std.mem.indexOfScalar(u8, parts.flags, 'n') != null) return substituteCount(app, range, parts, whole);
    if (std.mem.indexOfScalar(u8, parts.flags, 'c') != null) return substituteConfirm(app, range, parts, whole);
    const rebuilt = try std.fmt.allocPrint(arena, "{c}{s}{c}{s}{c}{s}", .{ parts.delim, parts.pattern, parts.delim, parts.replacement, parts.delim, parts.flags });
    return ex.substitute(app, range, rebuilt, whole);
}

fn remember(app: *App, parts: SubParts) Allocator.Error!void {
    const gpa = app.gpa;
    const pattern = try gpa.dupe(u8, parts.pattern);
    errdefer gpa.free(pattern);
    const replacement = try gpa.dupe(u8, parts.replacement);
    errdefer gpa.free(replacement);
    // `c` and `n` are one-shot decisions, never part of what `:&&` repeats.
    var flags: std.ArrayListUnmanaged(u8) = .empty;
    errdefer flags.deinit(gpa);
    for (parts.flags) |f| if (f != 'c' and f != 'n' and f != '&') try flags.append(gpa, f);
    if (app.last_substitute) |old| old.deinit(gpa);
    app.last_substitute = .{ .delim = parts.delim, .pattern = pattern, .replacement = replacement, .flags = try flags.toOwnedSlice(gpa) };
    try app.noteSearchPattern(pattern);
}

/// `:&[&][flags]` and a bare `:s [flags]`: the last substitute again on
/// the range (default: the cursor's line). `&&` keeps its flags; other
/// flags are added.
pub fn ampersand(app: *App, range: ?Range, spec_in: []const u8, whole: bool) CommandError!void {
    const arena = app.frame.allocator();
    const last = app.last_substitute orelse return app.diag.fail(arena, ":& — E35: no previous substitute", .{});
    var spec = std.mem.trim(u8, spec_in, " \t");
    if (spec.len > 0 and spec[0] == '&') spec = spec[1..];
    var flags: std.ArrayListUnmanaged(u8) = .empty;
    if (spec.len > 0 and spec[0] == '&') {
        try flags.appendSlice(arena, last.flags);
        spec = spec[1..];
    }
    for (spec) |f| if (std.ascii.isAlphabetic(f)) try flags.append(arena, f);
    const parts: SubParts = .{ .delim = last.delim, .pattern = last.pattern, .replacement = last.replacement, .flags = flags.items };
    if (std.mem.indexOfScalar(u8, flags.items, 'n') != null) return substituteCount(app, range, parts, whole);
    if (std.mem.indexOfScalar(u8, flags.items, 'c') != null) return substituteConfirm(app, range, parts, whole);
    const rebuilt = try std.fmt.allocPrint(arena, "{c}{s}{c}{s}{c}{s}", .{ last.delim, last.pattern, last.delim, last.replacement, last.delim, flags.items });
    return ex.substitute(app, range, rebuilt, whole);
}

/// A `:s///c` in progress: the matches still to decide, in text order,
/// as byte ranges in the ORIGINAL text; `delta` corrects them for the
/// replacements made so far (every replacement is earlier in the text).
pub const ReplaceConfirm = struct {
    pane: PaneId,
    needle: []u8,
    replacement: []u8,
    matches: [][2]usize,
    /// Per match, `replacement` with its group references expanded
    /// against the original line — decided at scan time, so a `\\1`
    /// under `c` means what it meant when the match was found.
    expansions: [][]u8,
    idx: usize = 0,
    applied: usize = 0,
    delta: isize = 0,

    pub fn deinit(c: ReplaceConfirm, gpa: Allocator) void {
        gpa.free(c.needle);
        gpa.free(c.replacement);
        gpa.free(c.matches);
        for (c.expansions) |x| gpa.free(x);
        gpa.free(c.expansions);
    }

    fn current(c: *const ReplaceConfirm) [2]usize {
        const m = c.matches[c.idx];
        return .{ @intCast(@as(isize, @intCast(m[0])) + c.delta), @intCast(@as(isize, @intCast(m[1])) + c.delta) };
    }
};

pub const confirm_choices = [_]app_mod.Confirm.Choice{
    .{ .key = 'y', .label = "yes" },
    .{ .key = 'n', .label = "no" },
    .{ .key = 'a', .label = "all" },
    .{ .key = 'q', .label = "quit" },
    .{ .key = 'l', .label = "last" },
};

/// `:s/pat/rep/c`: collect the matches in the range (the first per line
/// without `g`), then ask about each in turn.
fn substituteConfirm(app: *App, range: ?Range, parts: SubParts, whole: bool) CommandError!void {
    const arena = app.frame.allocator();
    const label: []const u8 = if (whole) ":%s" else ":s";
    const e = try editor(app, label);
    const pane_id = app.active.?;
    const ed = e.buf.editor;
    const needle = try ex.unescapeDelim(arena, parts.pattern, parts.delim);
    const replacement = try ex.unescapeDelim(arena, parts.replacement, parts.delim);
    if (needle.len == 0) return app.diag.fail(arena, "{s} — empty pattern", .{label});
    var global_flag = false;
    var case: ?bool = null;
    for (parts.flags) |f| switch (f) {
        'g' => global_flag = true,
        'i' => case = false,
        'I' => case = true,
        else => {},
    };
    var re = try ex.compilePattern(app, label, needle, case orelse caseFor(app, needle));
    defer re.deinit();
    var matches: std.ArrayListUnmanaged([2]usize) = .empty;
    errdefer matches.deinit(app.gpa);
    var expansions: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (expansions.items) |x| app.gpa.free(x);
        expansions.deinit(app.gpa);
    }
    _ = try scanMatches(app.gpa, ed, range, &re, global_flag, &matches, .{ .replacement = replacement, .out = &expansions });
    if (matches.items.len == 0) {
        app.toast("{s} — no match for \"{s}\"", .{ label, needle });
        return;
    }
    if (app.replace_confirm) |old| old.deinit(app.gpa);
    app.replace_confirm = null;
    const needle_owned = try app.gpa.dupe(u8, needle);
    errdefer app.gpa.free(needle_owned);
    const rep_owned = try app.gpa.dupe(u8, replacement);
    errdefer app.gpa.free(rep_owned);
    const matches_owned = try matches.toOwnedSlice(app.gpa);
    errdefer app.gpa.free(matches_owned);
    app.replace_confirm = .{ .pane = pane_id, .needle = needle_owned, .replacement = rep_owned, .matches = matches_owned, .expansions = try expansions.toOwnedSlice(app.gpa) };
    try showNext(app);
}

/// The replacement to pre-expand per match (`:s///c`), and where the
/// gpa-owned expansions go — one per appended range.
const Expand = struct { replacement: []const u8, out: *std.ArrayListUnmanaged([]u8) };

/// The matches of `re` in `range` (default: the cursor's line) as byte
/// ranges, appended to `out`; the first per line unless `all`. Each
/// line is matched on its own, as `ex.substitute` does. Returns how
/// many lines had one.
fn scanMatches(gpa: Allocator, ed: *const Editor, range: ?Range, re: *regex.Regex, all: bool, out: *std.ArrayListUnmanaged([2]usize), expand: ?Expand) Allocator.Error!usize {
    const r = range orelse Range{ .first = ed.currentLine(), .last = ed.currentLine() };
    const first = @min(r.first, ed.lineCount() - 1);
    const last = @min(r.last, ed.lineCount() - 1);
    var lines: usize = 0;
    var row = first;
    while (row <= last) : (row += 1) {
        const line = ed.lineSlice(row);
        const base = ed.lineStart(row);
        var from: usize = 0;
        var hit_line = false;
        while (from <= line.len) {
            const m = re.find(line, from) orelse break;
            try out.append(gpa, .{ base + m.start, base + m.end });
            errdefer _ = out.pop();
            if (expand) |x| {
                var exp: std.ArrayListUnmanaged(u8) = .empty;
                errdefer exp.deinit(gpa);
                try regex.expandReplacement(gpa, &exp, x.replacement, line, m);
                try x.out.append(gpa, try exp.toOwnedSlice(gpa));
            }
            hit_line = true;
            if (!all) break;
            // An empty match must not be found again in place.
            from = if (m.end > m.start) m.end else m.end + 1;
        }
        if (hit_line) lines += 1;
    }
    return lines;
}

/// The `n` flag: report the matches, change nothing — `:%s/x//gn`
/// counts every `x`, without `g` one per line, like vim.
fn substituteCount(app: *App, range: ?Range, parts: SubParts, whole: bool) CommandError!void {
    const arena = app.frame.allocator();
    const label: []const u8 = if (whole) ":%s" else ":s";
    const e = try editor(app, label);
    const ed = e.buf.editor;
    const needle = try ex.unescapeDelim(arena, parts.pattern, parts.delim);
    if (needle.len == 0) return app.diag.fail(arena, "{s} — empty pattern", .{label});
    var all = false;
    var case: ?bool = null;
    for (parts.flags) |f| switch (f) {
        'g' => all = true,
        'i' => case = false,
        'I' => case = true,
        else => {},
    };
    var re = try ex.compilePattern(app, label, needle, case orelse caseFor(app, needle));
    defer re.deinit();
    var matches: std.ArrayListUnmanaged([2]usize) = .empty;
    const lines = try scanMatches(arena, ed, range, &re, all, &matches, null);
    if (matches.items.len == 0) return app.diag.fail(arena, "{s} — E486: pattern not found: {s}", .{ label, needle });
    app.toast("{d} match{s} on {d} line{s}", .{ matches.items.len, if (matches.items.len == 1) "" else "es", lines, if (lines == 1) "" else "s" });
}

/// Select the next match and ask; finish when none is left.
fn showNext(app: *App) Allocator.Error!void {
    const c = &(app.replace_confirm orelse return);
    const e = app.panes.editor(c.pane) orelse return finishConfirm(app);
    if (c.idx >= c.matches.len) return finishConfirm(app);
    const m = c.current();
    const ed = e.buf.editor;
    if (m[1] > ed.len()) return finishConfirm(app);
    ed.setSelection(m[0], m[1]);
    ed.goal_col = null;
    app.setActive(c.pane);
    const msg = try std.fmt.allocPrint(app.gpa, "replace \"{s}\" with \"{s}\"?  ({d} of {d})", .{ c.needle, c.replacement, c.idx + 1, c.matches.len });
    errdefer app.gpa.free(msg);
    app.overlay.deinit(app.gpa);
    app.overlay = .{ .confirm = .{
        .state = .{ .title = "Substitute", .message = msg, .choices = &confirm_choices },
        .purpose = .replace_confirm,
        .message = msg,
    } };
    app.focus = .overlay;
    app.needs_render = true;
}

fn applyCurrent(app: *App, c: *ReplaceConfirm) Allocator.Error!void {
    const e = app.panes.editor(c.pane) orelse return;
    const m = c.current();
    if (m[1] > e.buf.editor.len()) return;
    e.buf.editor.anchor = null;
    const rep = c.expansions[c.idx];
    try app.splice(e, m[0], m[1], rep);
    c.delta += @as(isize, @intCast(rep.len)) - @as(isize, @intCast(m[1] - m[0]));
    c.applied += 1;
}

/// The overlay's answer: `y` / `n` / `a` / `q` / `l` by index.
pub fn answerConfirm(app: *App, choice: usize) Allocator.Error!void {
    const c = &(app.replace_confirm orelse return);
    switch (choice) {
        0 => {
            try applyCurrent(app, c);
            c.idx += 1;
        },
        1 => c.idx += 1,
        2 => while (c.idx < c.matches.len) : (c.idx += 1) try applyCurrent(app, c),
        4 => {
            try applyCurrent(app, c);
            c.idx = c.matches.len;
        },
        else => c.idx = c.matches.len,
    }
    try showNext(app);
}

/// Esc on the box: stop here, keeping what was replaced.
pub fn cancelConfirm(app: *App) void {
    finishConfirm(app);
}

fn finishConfirm(app: *App) void {
    const c = app.replace_confirm orelse return;
    app.replace_confirm = null;
    if (app.panes.editor(c.pane)) |e| {
        e.buf.editor.anchor = null;
        e.buf.editor.goal_col = null;
    }
    app.toast(":s — {d} replacement(s)", .{c.applied});
    c.deinit(app.gpa);
    app.needs_render = true;
}

pub fn deinitState(app: *App) void {
    if (app.last_shell_cmd) |s| app.gpa.free(s);
    if (app.last_substitute) |s| s.deinit(app.gpa);
    if (app.last_search_pattern) |s| app.gpa.free(s);
    if (app.replace_confirm) |c| c.deinit(app.gpa);
    deinitCommands(app);
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    app: App,
    tmp: testing.TmpDir,
    root: []u8,

    fn init(src: []const u8) !Fixture {
        return initWith(src, "");
    }

    fn initWith(src: []const u8, data_root: []const u8) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const root = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(root);
        var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = root, .data_root = data_root, .cols = 60, .rows = 12 });
        errdefer app.deinit();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "doc.txt", .data = src });
        const path = try std.fs.path.join(testing.allocator, &.{ root, "doc.txt" });
        defer testing.allocator.free(path);
        _ = try app.openPath(path);
        try app.setInputStyle(.vim);
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

    fn line(f: *Fixture) usize {
        return f.app.activeEditor().?.buf.editor.currentLine();
    }

    fn ex(f: *Fixture, l: []const u8) !void {
        f.app.frame.begin();
        try ex_run(&f.app, l);
    }

    fn key(f: *Fixture, k: Key) !void {
        try f.app.handle(.{ .key = k });
    }
};

const ex_run = ex.run;

test "ex: :g runs a command on every matching line — deletes keep later targets right, :v inverts, p prints" {
    var f = try Fixture.init("keep a\ndrop 1\nkeep b\ndrop 2\ndrop 3\nkeep c");
    defer f.deinit();
    try f.ex("g/drop/d");
    try testing.expectEqualStrings("keep a\nkeep b\nkeep c", f.text());
    try testing.expectEqualStrings(":g — ran on 3 line(s)", f.app.lastToast().?);
    try f.ex("v/b/s/keep/KEPT/");
    try testing.expectEqualStrings("KEPT a\nkeep b\nKEPT c", f.text());
    // A command that adds lines: every original target is still visited once.
    try f.ex("g/KEPT/norm Anew");
    try testing.expectEqualStrings("KEPT anew\nkeep b\nKEPT cnew", f.text());
    try f.ex("g/keep/p");
    try testing.expect(std.mem.indexOf(u8, f.app.lastToast().?, "1 line(s); first: keep b") != null);
    // No match is an error; an alternate delimiter works; `:g!` is `:v`.
    try testing.expectError(error.Failed, f.ex("g/zzz/d"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E486") != null);
    try f.ex("g#KEPT#d");
    try testing.expectEqualStrings("keep b", f.text());
}

test "ex: :g refuses to nest and a ranged :g only visits its lines" {
    var f = try Fixture.init("x1\nx2\nx3\nx4");
    defer f.deinit();
    try f.ex("2,3g/x/d");
    try testing.expectEqualStrings("x1\nx4", f.text());
    try f.ex("command! Nest g/x/d");
    try f.ex("g/x/Nest");
    // The refusal is per line; the outer :g reports it and the text stands.
    try testing.expectEqualStrings(":g — ran on 0 line(s), 2 failed", f.app.lastToast().?);
    try testing.expectEqualStrings("x1\nx4", f.text());
}

test "ex: :norm types keys per line with an Esc between, :%norm covers the buffer" {
    var f = try Fixture.init("one\ntwo\nthree");
    defer f.deinit();
    try f.ex("%norm A;");
    try testing.expectEqualStrings("one;\ntwo;\nthree;", f.text());
    try f.ex("2norm 0i# ");
    try testing.expectEqualStrings("one;\n# two;\nthree;", f.text());
    try f.ex("1,2norm $x");
    try testing.expectEqualStrings("one\n# two\nthree;", f.text());
    // Notation for the keys the `:` line cannot carry.
    try f.ex("3norm I-<lt><esc>x");
    try testing.expectEqualStrings("one\n# two\n-three;", f.text());
    try testing.expectError(error.Failed, f.ex("norm"));
    // Back in normal mode after every line — the next `:` opens cleanly.
    try testing.expectEqual(input.EditingMode.normal, f.app.activeEditor().?.buf.input.mode());
}

test "ex: :command defines, expands <args>/<bang>/<range>, lists, needs ! to replace, :delcommand removes; persisted per data root" {
    var f = try Fixture.init("a\nb\nc");
    defer f.deinit();
    const data = try std.fs.path.join(testing.allocator, &.{ f.root, "data" });
    defer testing.allocator.free(data);
    testing.allocator.free(f.app.data_root);
    f.app.data_root = try testing.allocator.dupe(u8, data);

    try testing.expectError(error.Failed, f.ex("command lower echo x"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E183") != null);
    try f.ex("command Say echo said <args><bang>");
    try f.ex("Say hello");
    try testing.expectEqualStrings("said hello", f.app.lastToast().?);
    try f.ex("Say! hi");
    try testing.expectEqualStrings("said hi!", f.app.lastToast().?);
    try testing.expectError(error.Failed, f.ex("command Say echo again"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E174") != null);
    try f.ex("command! -nargs=* Say echo again <args>");
    try f.ex("Say x");
    try testing.expectEqualStrings("again x", f.app.lastToast().?);
    // A typed range goes in front when the definition has no placeholder.
    try f.ex("command Del d");
    try f.ex("1,2Del");
    try testing.expectEqualStrings("c", f.text());
    try f.ex("command Lines echo <line1>-<line2> <range>");
    try f.ex("Lines");
    try testing.expectEqualStrings("1-1", f.app.lastToast().?);
    try f.ex("command");
    try testing.expect(std.mem.indexOf(u8, f.app.lastToast().?, "Del=d") != null);
    try testing.expect(std.mem.indexOf(u8, f.app.lastToast().?, "Say=echo again <args>") != null);
    // The file is there and comes back on a fresh app.
    const file = try pathFor(testing.allocator, data);
    defer testing.allocator.free(file);
    const back = try Io.Dir.cwd().readFileAlloc(testing.io, file, testing.allocator, .limited(4096));
    defer testing.allocator.free(back);
    try testing.expect(std.mem.indexOf(u8, back, ".name = \"Say\"") != null);
    var g = try Fixture.initWith("x", data);
    defer g.deinit();
    try testing.expectEqual(@as(usize, 3), try load(&g.app));
    try testing.expectEqual(@as(usize, 3), g.app.user_commands.count());
    try g.ex("Say loaded");
    try testing.expectEqualStrings("again loaded", g.app.lastToast().?);
    try g.ex("delcommand Say");
    try testing.expect(g.app.user_commands.get("Say") == null);
    try testing.expectError(error.Failed, g.ex("delcommand Say"));
    try testing.expect(std.mem.indexOf(u8, g.app.diag.msg.?, "E184") != null);
    try testing.expectError(error.Failed, g.ex("Say gone"));
}

test "ex: :! shows output in a scratch pane, :!! repeats, :range! filters, :r and :r ! insert below the line" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init("b\na\nc");
    defer f.deinit();
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "in.txt", .data = "from file\nsecond\n" });
    try f.ex("!printf 'hi there'");
    try testing.expectEqualStrings("[scratch]", f.app.panes.get(f.app.active.?).?.title());
    try testing.expectEqualStrings("$ printf 'hi there'\nhi there", f.text());
    try testing.expect(!f.app.activeEditor().?.buf.doc.dirty);
    try testing.expectEqualStrings("!printf 'hi there' — done", f.app.lastToast().?);
    try f.ex("!!");
    try testing.expectEqualStrings("$ printf 'hi there'\nhi there", f.text());
    try f.ex("!exit 3");
    try testing.expectEqualStrings("!exit 3 — exit 3", f.app.lastToast().?);
    // Back to the document: a ranged `!` is a filter.
    try f.ex("bp");
    while (!std.mem.eql(u8, f.app.panes.get(f.app.active.?).?.title(), "doc.txt")) try f.ex("bp");
    try f.ex("%!sort");
    try testing.expectEqualStrings("a\nb\nc", f.text());
    try f.ex("2r in.txt");
    try testing.expectEqualStrings("a\nb\nfrom file\nsecond\nc", f.text());
    try testing.expectEqual(@as(usize, 2), f.line());
    try f.ex("r !printf 'shell out'");
    try testing.expectEqualStrings("a\nb\nfrom file\nshell out\nsecond\nc", f.text());
    try testing.expectError(error.Failed, f.ex("r nope.txt"));
    try testing.expect(std.mem.indexOf(u8, f.app.diag.msg.?, "E484") != null);
    try testing.expectError(error.Failed, f.ex("!"));
}

test "ex: :> and :< shift by the tab width, stack, take a count and a range, skip blank lines" {
    var f = try Fixture.init("a\n\nb\nc\n\td");
    defer f.deinit();
    try f.ex(">");
    try testing.expectEqualStrings("    a\n\nb\nc\n\td", f.text());
    try f.ex("%>>");
    try testing.expectEqualStrings("            a\n\n        b\n        c\n        \td", f.text());
    try f.ex("%<");
    try testing.expectEqualStrings("        a\n\n    b\n    c\n    \td", f.text());
    // `:> 2` from line 3: two lines.
    try f.ex("3");
    try f.ex("> 2");
    try testing.expectEqualStrings("        a\n\n        b\n        c\n    \td", f.text());
    try testing.expectEqual(@as(usize, 3), f.line());
    try f.ex("5<<<");
    try testing.expectEqualStrings("        a\n\n        b\n        c\nd", f.text());
    try testing.expectError(error.Failed, f.ex("> x"));
    try testing.expectError(error.Failed, f.ex("> 0"));
}

test "ex: :& repeats the last substitute, :&& keeps its flags, :s alone repeats, an empty pattern reuses the last" {
    var f = try Fixture.init("aa aa\naa aa\naa aa");
    defer f.deinit();
    try testing.expectError(error.Failed, f.ex("&"));
    try f.ex("s/a/b/g");
    try testing.expectEqualStrings("bb bb\naa aa\naa aa", f.text());
    try f.ex("2");
    try f.ex("&");
    try testing.expectEqualStrings("bb bb\nba aa\naa aa", f.text());
    try f.ex("3&&");
    try testing.expectEqualStrings("bb bb\nba aa\nbb bb", f.text());
    try f.ex("2s");
    try testing.expectEqualStrings("bb bb\nbb aa\nbb bb", f.text());
    try f.ex("2s//c_/");
    try testing.expectEqualStrings("bb bb\nbb c_a\nbb bb", f.text());
    try f.ex("%&g");
    try testing.expectEqualStrings("bb bb\nbb c_c_\nbb bb", f.text());
    // `n` counts and changes nothing: every match with `g`, one per line without.
    try f.ex("%s/b/X/gn");
    try testing.expectEqualStrings("10 matches on 3 lines", f.app.lastToast().?);
    try f.ex("%s/b/X/n");
    try testing.expectEqualStrings("3 matches on 3 lines", f.app.lastToast().?);
    try f.ex("2s/c_/Y/n");
    try testing.expectEqualStrings("1 match on 1 line", f.app.lastToast().?);
    try f.ex("%&gn");
    try testing.expectEqualStrings("2 matches on 1 line", f.app.lastToast().?);
    try testing.expectEqualStrings("bb bb\nbb c_c_\nbb bb", f.text());
    // `n` was not remembered: a bare `:&&` replaces.
    try f.ex("2&&");
    try testing.expectEqualStrings("bb bb\nbb Yc_\nbb bb", f.text());
    try testing.expectError(error.Failed, f.ex("%s/zzz/-/n"));
}

test "ex: :g, :s///n and :s///c take vim patterns — word bounds, a group reference under c, a bad pattern" {
    var f = try Fixture.init("foo bar\nfoobar\nbar foo\nab12 cd34");
    defer f.deinit();
    // `\<foo\>` is the word, not the prefix of `foobar`.
    try f.ex("g/\\<foo\\>/d");
    try testing.expectEqualStrings("foobar\nab12 cd34", f.text());
    try testing.expectEqualStrings(":g — ran on 2 line(s)", f.app.lastToast().?);
    // `n` counts pattern matches.
    try f.ex("%s/\\d\\+/N/gn");
    try testing.expectEqualStrings("2 matches on 1 line", f.app.lastToast().?);
    try testing.expectEqualStrings("foobar\nab12 cd34", f.text());
    // Under `c`, each match's `\2-\1` is its own groups.
    try f.ex("%s/\\v(\\a+)(\\d+)/\\2-\\1/gc");
    try testing.expect(f.app.overlay == .confirm);
    try f.key(Key.char('y'));
    try testing.expectEqualStrings("foobar\n12-ab cd34", f.text());
    try f.key(Key.char('a'));
    try testing.expectEqualStrings("foobar\n12-ab 34-cd", f.text());
    try testing.expect(f.app.replace_confirm == null);
    // A bad pattern fails the verb and says so.
    try testing.expectError(error.Failed, f.ex("g/\\(x/d"));
    try testing.expectError(error.Failed, f.ex("%s/\\(x/-/c"));
    try testing.expectEqualStrings("foobar\n12-ab 34-cd", f.text());
}

test "ex: :s///c asks per match — y/n/a/q/l and Esc" {
    var f = try Fixture.init("x1 x2\nx3\nx4 x5");
    defer f.deinit();
    try f.ex("%s/x/Y/gc");
    try testing.expect(f.app.overlay == .confirm);
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.confirm.message, "(1 of 5)") != null);
    // The match is selected so the user sees it.
    const sel = f.app.activeEditor().?.buf.editor.selection().?;
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, &sel);
    try f.key(Key.char('y'));
    try testing.expectEqualStrings("Y1 x2\nx3\nx4 x5", f.text());
    try testing.expect(std.mem.indexOf(u8, f.app.overlay.confirm.message, "(2 of 5)") != null);
    try f.key(Key.char('n'));
    try testing.expectEqualStrings("Y1 x2\nx3\nx4 x5", f.text());
    try f.key(Key.char('y'));
    try testing.expectEqualStrings("Y1 x2\nY3\nx4 x5", f.text());
    try f.key(Key.char('l'));
    try testing.expectEqualStrings("Y1 x2\nY3\nY4 x5", f.text());
    try testing.expect(f.app.overlay == .none);
    try testing.expect(f.app.replace_confirm == null);
    try testing.expectEqualStrings(":s — 3 replacement(s)", f.app.lastToast().?);
    try testing.expect(f.app.activeEditor().?.buf.editor.anchor == null);
    // `a` finishes the rest; a longer replacement shifts later matches.
    try f.ex("%s/x/LONG/gc");
    try f.key(Key.char('a'));
    try testing.expectEqualStrings("Y1 LONG2\nY3\nY4 LONG5", f.text());
    // Esc stops, keeping what was done; `q` too.
    try f.ex("%s/Y/z/c");
    try f.key(Key.char('y'));
    try f.key(Key.named(.esc));
    try testing.expectEqualStrings("z1 LONG2\nY3\nY4 LONG5", f.text());
    try testing.expect(f.app.overlay == .none);
    try f.ex("%s/Y/q/c");
    try f.key(Key.char('q'));
    try testing.expectEqualStrings("z1 LONG2\nY3\nY4 LONG5", f.text());
    try testing.expectEqualStrings(":s — 0 replacement(s)", f.app.lastToast().?);
    // Without `g`, one match per line is offered.
    try f.ex("%s/LONG/-/c");
    try f.key(Key.char('a'));
    try testing.expectEqualStrings("z1 -2\nY3\nY4 -5", f.text());
}
