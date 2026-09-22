//! Formatting beyond `textDocument/formatting`, and the external tools:
//!
//! - on-type formatting (`textDocument/onTypeFormatting` when a typed
//!   character is one the server declared, behind `editor.format_on_type`);
//! - `willSaveWaitUntil` (the server's edits at save time, behind
//!   `editor.will_save_wait_until`);
//! - range formatting on a selection (`lsp.format_selection`);
//! - external formatters (`.formatters.<ext>`, else the builtin table):
//!   stdin → stdout, or in place, run synchronously so a save-time run
//!   lands before the write;
//! - external linters (`.linters.<ext>`, else the builtin table): a
//!   worker runs the tool on the saved file and its findings land in
//!   the diagnostics store beside the server's, through the same
//!   `.lsp` event lane as a `publishDiagnostics` notification from a
//!   server whose id is `linter_server_id`.
//!
//! // changed: `willSaveWaitUntil` cannot hold the write — the
//! `save_pre` hook is fire-and-forget and no server is ever awaited
//! (D3). The reply's edits are applied and the buffer written again;
//! the file on disk is right within a round-trip of the save.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const EditorPane = app_mod.EditorPane;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const event = @import("../core/event.zig");
const jsonrpc = @import("../rpc/jsonrpc.zig");
const runners = @import("runners.zig");
const client = @import("../lsp/client.zig");
const types = @import("../lsp/types.zig");
const tools = @import("../lsp/tools.zig");
const Config = @import("../config/Config.zig");
const lsp = @import("lsp.zig");
const indent = @import("../editor/indent.zig");

const Server = client.Server;
const ReqKind = client.ReqKind;
const Ctx = client.Ctx;
const Value = jsonrpc.Value;

/// The "server" a linter's findings arrive from. Real servers start at 1.
pub const linter_server_id: u32 = 0;

/// LSP `FormattingOptions` for a buffer: the indent its text is
/// written in (`editor/indent.zig`) — a two-space script asks for
/// `tabSize: 2`, a tab-indented one for `insertSpaces: false` — the
/// document's own settings when a `.editorconfig` pinned them or the
/// text says nothing. It used to be the config's `tab_width` for every
/// file, so bash-language-server handed shfmt `-i 4` and re-indented a
/// two-space script whole.
pub const FormattingOptions = struct {
    tabSize: usize,
    insertSpaces: bool,
    trimTrailingWhitespace: bool = true,
};

pub fn formattingOptions(e: *const EditorPane) FormattingOptions {
    const doc = e.buf.doc;
    if (!doc.indent_pinned) if (indent.detect(e.buf.editor.bytes())) |d| {
        return .{ .tabSize = if (d.use_tabs) doc.tab_width else d.unit, .insertSpaces = !d.use_tabs };
    };
    return .{ .tabSize = doc.indent_unit, .insertSpaces = !doc.use_tabs };
}

const save_flag: u32 = 1;

fn extOf(path: []const u8, buf: []u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2 or ext.len - 1 > buf.len) return "";
    return std.ascii.lowerString(buf[0 .. ext.len - 1], ext[1..]);
}

/// What a "no tool for …" toast names: `.sh` for a file with an
/// extension, the file's own name for one without (`run-all`) — a
/// toast reading `no linter for .` named nothing.
fn toolSubject(path: []const u8, ext: []const u8) []const u8 {
    return if (ext.len > 0) path[path.len - ext.len - 1 ..] else std.fs.path.basename(path);
}

// ─── on-type formatting ─────────────────────────────────────────────────

/// A character typed in `e`: when it is one of the server's on-type
/// triggers, ask for the edits around the cursor.
pub fn onTyped(app: *App, pane: PaneId, e: *EditorPane, s: *Server, c: u21) void {
    if (!app.cfg.editor.format_on_type or c >= 128) return;
    if (std.mem.indexOfScalar(u8, s.caps.on_type_triggers, @intCast(c)) == null) return;
    const path = e.buf.doc.path orelse return;
    const arena = app.frame.allocator();
    const pos = s.docPos(arena, path, e.buf.editor.bytes(), e.buf.editor.cursor) catch return;
    const ch = [_]u8{@intCast(c)};
    _ = s.request(.on_type_formatting, "textDocument/onTypeFormatting", .{
        .textDocument = pos.textDocument,
        .position = pos.position,
        .ch = &ch,
        .options = formattingOptions(e),
    }, .{ .pane = pane }) catch {};
}

// ─── save time ──────────────────────────────────────────────────────────

/// From `lsp.onSavePre`, before the write: the server's
/// `willSaveWaitUntil` edits (applied when they land), and the external
/// formatter when format-on-save has no server to format with.
pub fn onSavePre(app: *App, pane: PaneId, e: *EditorPane, s: ?*Server) void {
    const path = e.buf.doc.path orelse return;
    if (s) |srv| if (app.cfg.editor.will_save_wait_until and srv.caps.will_save_wait_until and srv.ready and srv.isOpen(path)) {
        const arena = app.frame.allocator();
        if (types.uriFromPath(arena, path)) |uri| {
            _ = srv.request(.will_save_wait_until, "textDocument/willSaveWaitUntil", .{ .textDocument = .{ .uri = uri }, .reason = 1 }, .{ .pane = pane, .extra = save_flag }) catch {};
        } else |_| {}
    };
    if (!app.cfg.editor.format_on_save) return;
    const lsp_formats = if (s) |srv| srv.ready and srv.caps.formatting else false;
    if (lsp_formats) return; // `lsp.onSavePre` asked the server
    formatExternalPane(app, e, false) catch {};
}

pub fn handleResponse(app: *App, s: *Server, kind: ReqKind, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const e = app.panes.editor(ctx.pane) orelse return;
    const edits = try types.readTextEdits(app.frame.allocator(), result);
    if (edits.len > 0) try lsp.applyEditsToPane(app, e, edits, s.encoding);
    switch (kind) {
        .will_save_wait_until => if (edits.len > 0 and ctx.extra & save_flag != 0) {
            e.buf.save(app.io) catch {};
        },
        .range_formatting => if (edits.len == 0) app.toast("format selection: nothing to change", .{}) else app.toast("formatted selection", .{}),
        else => {},
    }
    app.needs_render = true;
}

// ─── range formatting ───────────────────────────────────────────────────

/// `lsp.format_selection`: the server formats the selected range.
pub fn formatSelection(app: *App) CommandError!void {
    const t = try lsp.requireServer(app, "format selection");
    const arena = app.frame.allocator();
    if (!t.server.caps.range_formatting) return app.diag.fail(arena, "{s} does not format ranges", .{t.server.name});
    const ed = t.e.buf.editor;
    const sel = ed.selection() orelse return app.diag.fail(arena, "select a range first", .{});
    const text = ed.bytes();
    const uri = try types.uriFromPath(arena, t.path);
    const range: types.Range = .{ .start = types.positionOf(text, sel[0], t.server.encoding), .end = types.positionOf(text, sel[1], t.server.encoding) };
    _ = t.server.request(.range_formatting, "textDocument/rangeFormatting", .{
        .textDocument = .{ .uri = uri },
        .range = range,
        .options = formattingOptions(t.e),
    }, .{ .pane = t.pane }) catch |err| return app.diag.fail(arena, "LSP format selection: {s}", .{@errorName(err)});
}

// ─── external formatters ────────────────────────────────────────────────

/// `lsp.format`: the server when it formats, else the external tool.
pub fn formatDocument(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try app.requireEditor();
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "format needs a saved file", .{});
    if (lsp.serverFor(app, path)) |s| if (s.ready and s.caps.formatting) return lsp.format(app);
    try formatExternalPane(app, e, true);
}

/// `editor.format_external`: the configured / builtin tool, always.
pub fn formatExternal(app: *App) CommandError!void {
    const e = try app.requireEditor();
    try formatExternalPane(app, e, true);
}

/// Run the tool for the pane's extension over its text and splice the
/// result back as one undo step. `explicit` says a missing tool is a
/// failure to report; a save-time run stays quiet.
pub fn formatExternalPane(app: *App, e: *EditorPane, explicit: bool) CommandError!void {
    const arena = app.frame.allocator();
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "format needs a saved file", .{});
    var buf: [32]u8 = undefined;
    const ext = extOf(path, &buf);
    const f = tools.formatterFor(&app.cfg, ext, lsp.languageOf(app, path)) orelse {
        if (explicit) return app.diag.fail(arena, "no formatter for {s} (no server formats it, nothing in .formatters)", .{toolSubject(path, ext)});
        return;
    };
    const argv = try arena.dupe([]const u8, try tools.expandArgv(arena, f.argv, app.relPath(path)));
    argv[0] = try lsp.resolveOnPath(app, arena, argv[0]);
    const ed = e.buf.editor;
    const before = ed.bytes();
    if (f.in_place) {
        // The tool wants the file: write what the buffer holds, run it
        // on the path, read the result back.
        Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = before }) catch |err| return app.diag.fail(arena, "format: write {s}: {s}", .{ app.relPath(path), @errorName(err) });
        const run = runTool(app, arena, argv, "") catch |err| return app.diag.fail(arena, "formatter `{s}`: {s}", .{ argv[0], @errorName(err) });
        if (!run.ok) return app.diag.fail(arena, "formatter `{s}` failed — {s}", .{ argv[0], preview(run.stderr) });
        const after = Io.Dir.cwd().readFileAlloc(app.io, path, arena, .limited(1 << 30)) catch |err| return app.diag.fail(arena, "format: read {s}: {s}", .{ app.relPath(path), @errorName(err) });
        try replaceWhole(app, e, after);
    } else {
        const run = runTool(app, arena, argv, before) catch |err| return app.diag.fail(arena, "formatter `{s}`: {s}", .{ argv[0], @errorName(err) });
        if (!run.ok) return app.diag.fail(arena, "formatter `{s}` failed — {s}", .{ argv[0], preview(run.stderr) });
        try replaceWhole(app, e, run.stdout);
    }
    if (explicit) app.toast("formatted {s} with {s}", .{ app.relPath(path), std.fs.path.basename(argv[0]) });
    app.needs_render = true;
}

/// The whole text as one splice, cursor kept where it can be. A tool
/// that returned the same bytes changes nothing.
fn replaceWhole(app: *App, e: *EditorPane, after: []const u8) Allocator.Error!void {
    const ed = e.buf.editor;
    if (std.mem.eql(u8, ed.bytes(), after)) return;
    const cursor = ed.cursor;
    // Trim the common prefix and suffix so the undo step and the edit
    // log carry only what changed.
    const before = ed.bytes();
    var pre: usize = 0;
    while (pre < before.len and pre < after.len and before[pre] == after[pre]) pre += 1;
    var suf: usize = 0;
    while (suf < before.len - pre and suf < after.len - pre and before[before.len - 1 - suf] == after[after.len - 1 - suf]) suf += 1;
    const copy = try app.frame.allocator().dupe(u8, after[pre .. after.len - suf]);
    try app.splice(e, pre, before.len - suf, copy);
    ed.anchor = null;
    ed.setCursor(@min(cursor, ed.len()));
}

fn preview(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const first_nl = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..@min(first_nl, 120)];
}

const RunOut = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

/// Spawn `argv` in the workspace with `stdin` on its input; both output
/// streams land on `arena`.
fn runTool(app: *App, arena: Allocator, argv_in: []const []const u8, stdin: []const u8) !RunOut {
    const io = app.io;
    // Resolved on the App's PATH (see `lintWorker`).
    const argv = try arena.dupe([]const u8, argv_in);
    var where: [std.fs.max_path_bytes]u8 = undefined;
    if (runners.pathOf(io, &app.env, &where, argv[0])) |abs| argv[0] = try arena.dupe(u8, abs);
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = app.workspace },
        .environ_map = &app.env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    if (child.stdin) |in| {
        in.writeStreamingAll(io, stdin) catch {};
        in.close(io);
        child.stdin = null;
    }
    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(app.gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const term = try child.wait(io);
    const stdout = try arena.dupe(u8, multi_reader.reader(0).buffered());
    const stderr = try arena.dupe(u8, multi_reader.reader(1).buffered());
    return .{ .ok = term == .exited and term.exited == 0, .stdout = stdout, .stderr = stderr };
}

// ─── external linters ───────────────────────────────────────────────────

/// `editor.lint_external`: the tool for the active file, now.
pub fn lintExternal(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try app.requireEditor();
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "lint needs a saved file", .{});
    if (e.buf.doc.dirty) return app.diag.fail(arena, "lint runs on the saved file — save first", .{});
    var buf: [32]u8 = undefined;
    const ext = extOf(path, &buf);
    const l = tools.linterFor(&app.cfg, ext, lsp.languageOf(app, path)) orelse return app.diag.fail(arena, "no linter for {s} (nothing in .linters)", .{toolSubject(path, ext)});
    lintPath(app, path, l) catch |err| return app.diag.fail(arena, "lint: {s}", .{@errorName(err)});
    app.toast("linting {s} with {s}…", .{ app.relPath(path), std.fs.path.basename(l.argv[0]) });
}

/// A file opened or saved: lint it when a tool is configured. Quiet
/// when there is none. `has_server` says a language server is attached
/// to the file: the BUILTIN row then stands down — the server lints
/// (bash-language-server runs shellcheck itself), and the tool's copy
/// of every finding doubled the panel, the badges and `]d`. A tool the
/// config names in `.linters` was asked for and runs regardless, as
/// does `editor.lint_external`.
pub fn lintOnHook(app: *App, path: []const u8, has_server: bool) void {
    var buf: [32]u8 = undefined;
    const ext = extOf(path, &buf);
    const key = lsp.languageOf(app, path);
    const l = tools.linterFor(&app.cfg, ext, key) orelse return;
    if (!tools.linterConfigured(&app.cfg, ext, key)) {
        if (has_server) return;
        // A builtin tool that is not installed is not worth a spawn per save.
        if (!(lsp.onPath(app, app.frame.allocator(), l.argv[0]) catch false)) return;
    }
    lintPath(app, path, l) catch {};
}

/// Owned copies for the worker; freed by it.
const Job = struct {
    argv: [][]u8,
    cwd: []u8,
    path: []u8,
    rel: []u8,
    pattern: []u8,
    parser: Config.LintParser,

    fn destroy(self: *Job, gpa: Allocator) void {
        for (self.argv) |a| gpa.free(a);
        gpa.free(self.argv);
        gpa.free(self.cwd);
        gpa.free(self.path);
        gpa.free(self.rel);
        gpa.free(self.pattern);
        gpa.destroy(self);
    }
};

fn lintPath(app: *App, path: []const u8, l: tools.Linter) !void {
    const gpa = app.gpa;
    const arena = app.frame.allocator();
    const rel = app.relPath(path);
    const expanded = try tools.expandArgv(arena, l.argv, rel);
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    job.* = .{ .argv = &.{}, .cwd = &.{}, .path = &.{}, .rel = &.{}, .pattern = &.{}, .parser = l.parser };
    var argv: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    for (expanded, 0..) |a, i| try argv.append(gpa, try gpa.dupe(u8, if (i == 0) try lsp.resolveOnPath(app, arena, a) else a));
    job.argv = try argv.toOwnedSlice(gpa);
    errdefer {
        for (job.argv) |a| gpa.free(a);
        gpa.free(job.argv);
    }
    job.cwd = try gpa.dupe(u8, app.workspace);
    errdefer gpa.free(job.cwd);
    job.path = try gpa.dupe(u8, path);
    errdefer gpa.free(job.path);
    job.rel = try gpa.dupe(u8, rel);
    errdefer gpa.free(job.rel);
    job.pattern = try gpa.dupe(u8, l.pattern);
    errdefer gpa.free(job.pattern);
    try app.lsp.lint_group.concurrent(app.io, lintWorker, .{ &app.events, app.io, gpa, job, &app.env });
}

const WireDiag = struct {
    range: types.Range,
    severity: u8,
    message: []const u8,
    source: ?[]const u8,
    code: ?[]const u8,
};

/// Run the tool, parse its output, post the findings as a
/// `publishDiagnostics` from `linter_server_id`.
fn lintWorker(events: *event.EventQueue, io: Io, gpa: Allocator, job: *Job, env: *const std.process.Environ.Map) Io.Cancelable!void {
    defer job.destroy(gpa);
    // The App's PATH, not this process's, decides which tool runs — a
    // spawn looks argv[0] up on the environment mnml was started in,
    // which is not the one the user configured (`runners.pathOf`, as
    // the tests pane's worker does).
    var where: [std.fs.max_path_bytes]u8 = undefined;
    if (runners.pathOf(io, env, &where, job.argv[0])) |abs| {
        if (gpa.dupe(u8, abs)) |owned| {
            gpa.free(job.argv[0]);
            job.argv[0] = owned;
        } else |_| {}
    }
    const result = std.process.run(gpa, io, .{
        .argv = job.argv,
        .cwd = .{ .path = job.cwd },
        .environ_map = env,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            const msg = std.fmt.allocPrint(gpa, "linter `{s}`: {s}", .{ job.argv[0], @errorName(err) }) catch return;
            events.post(io, .{ .err = .{ .source = .lsp, .msg = msg } });
            return;
        },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try io.checkCancel();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Most linters exit non-zero on findings: parse whatever came out.
    const text = if (result.stdout.len > 0) result.stdout else result.stderr;
    const diags = tools.parseOutput(a, job.parser, job.pattern, text, job.path) catch return;
    // A non-zero exit that yielded no finding is the tool failing (a
    // rejected flag, a broken config, a crash), not a clean file: say
    // so, and leave the file's last findings alone.
    if (lintFailed(result.term, diags.len, result.stdout, result.stderr)) |why| {
        var reason: [160]u8 = undefined;
        const msg = std.fmt.allocPrint(gpa, "linter `{s}` failed — {s}", .{ std.fs.path.basename(job.argv[0]), summarize(&reason, why) }) catch return;
        events.post(io, .{ .err = .{ .source = .lsp, .msg = msg } });
        return;
    }
    const wire = a.alloc(WireDiag, diags.len) catch return;
    for (diags, 0..) |d, i| wire[i] = .{ .range = d.range, .severity = @intFromEnum(d.severity), .message = d.message, .source = d.source, .code = d.code };
    const uri = types.uriFromPath(a, job.path) catch return;
    const body = jsonrpc.stringify(gpa, .{
        .jsonrpc = "2.0",
        .method = "textDocument/publishDiagnostics",
        .params = .{ .uri = uri, .diagnostics = wire },
    }) catch return;
    defer gpa.free(body);
    const inc = jsonrpc.Incoming.create(gpa, body) catch return;
    const ev = gpa.create(event.LspEvent) catch {
        inc.destroy(gpa);
        return;
    };
    ev.* = .{ .message = inc };
    events.post(io, .{ .lsp = .{ .server = linter_server_id, .msg = ev } });
}

/// The output to report when a lint run failed: the process did not
/// exit 0, nothing parsed as a finding, and it said something (stderr
/// first, else stdout). A zero exit, or any finding, is a real result.
fn lintFailed(term: std.process.Child.Term, findings: usize, stdout: []const u8, stderr: []const u8) ?[]const u8 {
    if (findings > 0) return null;
    const clean = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (clean) return null;
    const err_text = std.mem.trim(u8, stderr, " \t\r\n");
    if (err_text.len > 0) return err_text;
    const out_text = std.mem.trim(u8, stdout, " \t\r\n");
    if (out_text.len > 0) return out_text;
    // Silent and non-zero is a `grep`-style "no match", i.e. clean;
    // only a signal is a failure without words.
    return switch (term) {
        .exited => null,
        else => "terminated by a signal",
    };
}

/// A tool's complaint on one line: its first few non-blank lines joined
/// with ` · ` (ruff's first line is only "ruff failed"; the reason is
/// on the next), cut to `buf`.
fn summarize(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (lines == 3) break;
        const sep: []const u8 = if (lines == 0) "" else " · ";
        for ([_][]const u8{ sep, line }) |part| {
            const take = @min(part.len, buf.len - n);
            @memcpy(buf[n..][0..take], part[0..take]);
            n += take;
        }
        lines += 1;
    }
    return buf[0..n];
}

/// The linter lane of `lsp.handle`: the findings go to the store as
/// the file's linter diagnostics.
pub fn handleLintEvent(app: *App, ev: *event.LspEvent) Allocator.Error!void {
    defer ev.destroy(app.gpa);
    const msg = switch (ev.*) {
        .message => |m| m,
        .closed, .oversize => return,
    };
    switch (jsonrpc.classify(msg.root())) {
        .notification => |n| {
            const p = n.params orelse return;
            const uri = jsonrpc.getStr(p, "uri") orelse return;
            const arena = app.frame.allocator();
            const path = (try types.pathFromUri(arena, uri)) orelse return;
            var list: std.ArrayListUnmanaged(types.Diagnostic) = .empty;
            for (jsonrpc.getArr(p, "diagnostics") orelse &.{}) |v| if (types.readDiagnostic(v)) |d| try list.append(arena, d);
            try lsp.applyLintDiagnostics(app, path, list.items);
        },
        else => {},
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const Key = @import("../core/key.zig").Key;

test "through the fake server: on-type formatting behind its flag, range formatting on a selection, willSaveWaitUntil before the write" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    const file = lsp.TestRig.file;
    const e = try lsp.TestRig.openFile(&app, file, lsp.TestRig.text);
    defer Io.Dir.cwd().deleteFile(app.io, file) catch {};
    const Cond = struct {
        fn ready(a: *App) bool {
            const s = a.lsp.servers.items[0];
            return s.ready and s.isOpen(lsp.TestRig.file);
        }
        fn typed(a: *App) bool {
            return std.mem.startsWith(u8, a.activeEditor().?.buf.editor.bytes(), "  let");
        }
        fn ranged(a: *App) bool {
            return std.mem.indexOf(u8, a.activeEditor().?.buf.editor.bytes(), "formatted") != null;
        }
        fn saved(a: *App) bool {
            const t = Io.Dir.cwd().readFileAlloc(a.io, lsp.TestRig.file, a.gpa, .limited(4096)) catch return false;
            defer a.gpa.free(t);
            return std.mem.startsWith(u8, t, "// saved\n");
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.ready, 5000);
    const ed = e.buf.editor;
    // Off by default: a typed `;` is only a `;`.
    ed.setCursor(10);
    try app.handle(.{ .key = Key.char(';') });
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "let x = 1;;\n"));
    // On: the trigger asks, the server's edit lands at the line's start.
    app.cfg.editor.format_on_type = true;
    try app.handle(.{ .key = Key.char(';') });
    try lsp.TestRig.pump(&app, &app, Cond.typed, 5000);
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "  let x = 1;;;\n"));
    // Range formatting needs a selection; with one the server's edit
    // replaces exactly that range.
    ed.anchor = null;
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"lsp.format_selection" }));
    const l2 = std.mem.indexOf(u8, ed.bytes(), "foo.\n").?;
    ed.anchor = l2;
    ed.setCursor(l2 + 4);
    try command.run(&app, .{ .static = .@"lsp.format_selection" });
    try lsp.TestRig.pump(&app, &app, Cond.ranged, 5000);
    try testing.expect(std.mem.endsWith(u8, ed.bytes(), "formatted\n"));
    try testing.expect(std.mem.indexOf(u8, ed.bytes(), "foo.") == null);
    // Save with `willSaveWaitUntil` off: the disk holds the buffer as is.
    try command.run(&app, .{ .static = .@"file.save" });
    const plain = try Io.Dir.cwd().readFileAlloc(app.io, file, gpa, .limited(4096));
    defer gpa.free(plain);
    try testing.expectEqualStrings(ed.bytes(), plain);
    // On: the server's edit lands and the file is written again.
    app.cfg.editor.will_save_wait_until = true;
    try command.run(&app, .{ .static = .@"file.save" });
    try lsp.TestRig.pump(&app, &app, Cond.saved, 5000);
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "// saved\n  let"));
    try rig.stop(&app);
}

/// A `sh` script under /tmp with `body`; the caller frees the path and
/// deletes the file. Run as `sh <path> …` so no mode bit is needed.
fn writeScript(io: Io, gpa: Allocator, name: []const u8, body: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/tmp/mnml-zig-{s}-{x}.sh", .{ name, @as(u64, @bitCast(App.nowMs(io))) });
    errdefer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
    return path;
}

test "an external formatter runs stdin → stdout or in place as one undo step; a failing or missing tool is a reported failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var app = try App.initWith(gpa, io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    const path = "/tmp/mnml-zig-fmt-test.txt";
    try e.buf.setPath(path);
    try e.buf.editor.setText("abc\n");
    // stdin → stdout.
    const up = try writeScript(io, gpa, "fmt-up", "tr a-z A-Z\n");
    defer gpa.free(up);
    defer Io.Dir.cwd().deleteFile(io, up) catch {};
    const argv_up = [_][]const u8{ "sh", up };
    // A loaded config owns its maps on an arena; this one is built here.
    defer app.cfg.formatters.deinit(gpa);
    try app.cfg.formatters.put(gpa, "txt", .{ .cmd = &argv_up });
    try command.run(&app, .{ .static = .@"editor.format_external" });
    try testing.expectEqualStrings("ABC\n", e.buf.editor.bytes());
    try testing.expectEqualStrings("formatted mnml-zig-fmt-test.txt with sh", app.lastToast().?);
    try command.run(&app, .{ .static = .@"editor.undo" });
    try testing.expectEqualStrings("abc\n", e.buf.editor.bytes());
    // In place: the buffer is written, the tool rewrites `{file}`, the
    // result is read back.
    const ip = try writeScript(io, gpa, "fmt-ip", "printf 'IN PLACE\\n' > \"$1\"\n");
    defer gpa.free(ip);
    defer Io.Dir.cwd().deleteFile(io, ip) catch {};
    defer Io.Dir.cwd().deleteFile(io, path) catch {};
    const argv_ip = [_][]const u8{ "sh", ip, "{file}" };
    try app.cfg.formatters.put(gpa, "txt", .{ .cmd = &argv_ip, .in_place = true });
    try command.run(&app, .{ .static = .@"editor.format_external" });
    try testing.expectEqualStrings("IN PLACE\n", e.buf.editor.bytes());
    // A tool that fails leaves the buffer alone and reports its stderr.
    const bad = try writeScript(io, gpa, "fmt-bad", "echo boom >&2\nexit 3\n");
    defer gpa.free(bad);
    defer Io.Dir.cwd().deleteFile(io, bad) catch {};
    const argv_bad = [_][]const u8{ "sh", bad };
    try app.cfg.formatters.put(gpa, "txt", .{ .cmd = &argv_bad });
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.format_external" }));
    try testing.expectEqualStrings("IN PLACE\n", e.buf.editor.bytes());
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "boom") != null);
    // No tool for the extension.
    try e.buf.setPath("/tmp/x.unobtanium");
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.format_external" }));
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "no formatter for .unobtanium") != null);
}

test "an external linter runs on a worker and its findings land in the diagnostics store; lint_external refuses a dirty buffer" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var app = try App.initWith(gpa, io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    const path = "/tmp/mnml-zig-lint-test.txt";
    try e.buf.setPath(path);
    try e.buf.editor.setText("a\nb\nc\n");
    const script = try writeScript(io, gpa, "lint", "echo \"$1:2:3: error: bad thing\"\necho \"$1:1:1: warning: meh\"\nexit 1\n");
    defer gpa.free(script);
    defer Io.Dir.cwd().deleteFile(io, script) catch {};
    const argv = [_][]const u8{ "sh", script, "{file}" };
    defer app.cfg.linters.deinit(gpa);
    try app.cfg.linters.put(gpa, "txt", .{ .cmd = &argv, .parser = .vimgrep });
    const Cond = struct {
        fn two(a: *App) bool {
            return lsp.diagnosticsFor(a, "/tmp/mnml-zig-lint-test.txt").len == 2;
        }
    };
    lintOnHook(&app, path, false);
    try lsp.TestRig.pump(&app, &app, Cond.two, 5000);
    const list = lsp.diagnosticsFor(&app, path);
    try testing.expectEqualStrings("meh", list[0].message);
    try testing.expectEqual(types.Severity.warning, list[0].severity);
    try testing.expectEqual(@as(u32, 1), list[1].range.start.line);
    try testing.expectEqual(@as(u32, 2), list[1].range.start.character);
    try testing.expectEqualStrings("bad thing", list[1].message);
    try testing.expectEqual(types.Severity.err, list[1].severity);
    try testing.expectEqualStrings("lint", list[1].source.?);
    // The command form: a dirty buffer is refused, a clean one runs.
    e.buf.doc.dirty = true;
    try testing.expectError(error.Failed, command.run(&app, .{ .static = .@"editor.lint_external" }));
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "save first") != null);
    e.buf.doc.dirty = false;
    try command.run(&app, .{ .static = .@"editor.lint_external" });
    try testing.expectEqualStrings("linting mnml-zig-lint-test.txt with sh…", app.lastToast().?);
    try lsp.TestRig.pump(&app, &app, Cond.two, 5000);
    // A tool that rejects its argv (exit 2, usage on stderr, nothing
    // parseable) is reported as a failure, never as a clean file, and
    // the file keeps its last findings.
    const bad = try writeScript(io, gpa, "lint-bad", "echo \"error: unexpected argument '--no-color' found\" >&2\nexit 2\n");
    defer gpa.free(bad);
    defer Io.Dir.cwd().deleteFile(io, bad) catch {};
    const argv_bad = [_][]const u8{ "sh", bad, "{file}" };
    try app.cfg.linters.put(gpa, "txt", .{ .cmd = &argv_bad, .parser = .vimgrep });
    const Failed = struct {
        fn toast(a: *App) bool {
            const t = a.lastToast() orelse return false;
            return std.mem.indexOf(u8, t, "linter `sh` failed") != null;
        }
    };
    lintOnHook(&app, path, false);
    try lsp.TestRig.pump(&app, &app, Failed.toast, 5000);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "unexpected argument '--no-color'") != null);
    try testing.expectEqual(@as(usize, 2), lsp.diagnosticsFor(&app, path).len);
}

test "lintFailed: a non-zero exit with words and no finding is a failure; findings, a zero exit or a silent exit are results" {
    const two: std.process.Child.Term = .{ .exited = 2 };
    try testing.expectEqualStrings("usage", lintFailed(two, 0, "", "  usage\n").?);
    try testing.expectEqualStrings("junk", lintFailed(two, 0, "junk\n", "").?);
    try testing.expect(lintFailed(two, 3, "", "noise") == null);
    try testing.expect(lintFailed(.{ .exited = 0 }, 0, "", "warning: cache") == null);
    try testing.expect(lintFailed(.{ .exited = 1 }, 0, "", "") == null);
    try testing.expect(lintFailed(.{ .signal = .KILL }, 0, "", "") != null);
}

test "summarize joins a tool's first non-blank lines and fits its buffer" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("ruff failed · Cause: bad toml · x", summarize(&buf, "ruff failed\n  Cause: bad toml\n\n x\n y\n"));
    try testing.expectEqual(@as(usize, 40), summarize(&buf, "a" ** 100).len);
}

test "the builtin Python linter's argv is one current ruff accepts" {
    const l = tools.linterFor(&Config{}, "py", "py").?;
    try testing.expectEqualStrings("ruff", l.argv[0]);
    for (l.argv) |a| try testing.expect(!std.mem.eql(u8, a, "--no-color"));
}

test "replaceWhole splices only the changed middle and keeps the cursor" {
    var app = try App.initWith(testing.allocator, testing.io, .{ .workspace = "/tmp", .cols = 80, .rows = 20 });
    defer app.deinit();
    app.tree.visible = false;
    _ = try app.openScratch();
    const e = app.activeEditor().?;
    try e.buf.editor.setText("aaa\nbbb\nccc\n");
    e.buf.editor.setCursor(9);
    const seq = e.buf.doc.edits.head();
    try replaceWhole(&app, e, "aaa\nBBB\nccc\n");
    try testing.expectEqualStrings("aaa\nBBB\nccc\n", e.buf.editor.bytes());
    try testing.expectEqual(@as(usize, 9), e.buf.editor.cursor);
    const splices = e.buf.doc.edits.since(seq);
    try testing.expectEqual(@as(usize, 1), splices.len);
    try testing.expectEqual(@as(usize, 4), splices[0].start);
    try testing.expectEqual(@as(usize, 7), splices[0].old_end);
    // The same bytes change nothing.
    const seq2 = e.buf.doc.edits.head();
    try replaceWhole(&app, e, "aaa\nBBB\nccc\n");
    try testing.expectEqual(seq2, e.buf.doc.edits.head());
}
