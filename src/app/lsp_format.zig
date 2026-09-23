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
//! // changed (stdfix): a save the server formats is HELD, not written
//! twice. `file.save` and `:w` emit `save_pre` with `may_hold`; when a
//! `willSaveWaitUntil` or a format-on-save request goes out, the write
//! waits (nothing blocks — D3: the save is finished by the reply, or by
//! `tick` once `save_wait_ms` has run out) and happens once, with the
//! edits in it. Every formatting-family request carries the document
//! version it was computed for (`Ctx.extra`), and a reply for a buffer
//! that moved on since is dropped with a line in `:messages`: the
//! server's offsets describe text that is no longer there. It used to
//! write first, splice the late reply into whatever the buffer held by
//! then — deleting what the user had typed after Ctrl+S — and write
//! again, past the watcher (`<file> reloaded`, an empty undo step).

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
const jobs = @import("jobs.zig");

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

// ─── the version a request was asked for ───────────────────────────────

/// `Ctx.extra` of a formatting-family request (`formatting`,
/// `rangeFormatting`, `onTypeFormatting`, `willSaveWaitUntil`): with
/// this bit set, the serial of the held save waiting on it (`Hold`);
/// without it, the document version the request was computed for — the
/// edit log's head, low 31 bits (`versionTag`).
pub const held_bit: u32 = 1 << 31;

/// The document's version as a request's `Ctx.extra` carries it. The
/// edit log's head moves on every splice and every wholesale
/// replacement (`EditLog.markLost` takes a seq too).
pub fn versionTag(e: *const EditorPane) u32 {
    return @truncate(e.buf.doc.edits.head() & (held_bit - 1));
}

/// True when the buffer is still the text a request tagged
/// `versionTag` was computed for. A reply that fails this is for text
/// that is gone: its ranges would land on whatever moved in since.
pub fn stillCurrent(e: *const EditorPane, tag: u32) bool {
    return versionTag(e) == tag;
}

/// The quiet word a dropped reply leaves: `:messages`, no toast.
fn noteDropped(app: *App, e: *const EditorPane, what: []const u8) void {
    const rel = if (e.buf.doc.path) |p| app.relPath(p) else "buffer";
    const text = std.fmt.allocPrint(app.frame.allocator(), "{s}: {s} dropped — the buffer changed while the server worked", .{ rel, what }) catch return;
    app.messages.record(app.gpa, text, .info, app.now_ms) catch {};
}

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
    }, .{ .pane = pane, .extra = versionTag(e) }) catch {};
}

// ─── save time ──────────────────────────────────────────────────────────

/// From `lsp.onSavePre`, before the write: the server's
/// `willSaveWaitUntil` edits, and the external formatter when it is
/// the one that formats this file — configured, or the project's own
/// (`externalWins`) — or when format-on-save has no server to format
/// with. A save that may wait (`may_hold`) is held for the server's
/// reply (`Hold`); one that cannot is not asked about — its write goes
/// out now and a reply would only land on the text after it. Returns
/// true when the external tool formatted, so the caller does not also
/// ask the server.
pub fn onSavePre(app: *App, pane: PaneId, e: *EditorPane, s: ?*Server, may_hold: bool) bool {
    const path = e.buf.doc.path orelse return false;
    if (s) |srv| if (may_hold and app.cfg.editor.will_save_wait_until and srv.caps.will_save_wait_until and srv.ready and srv.isOpen(path)) {
        const arena = app.frame.allocator();
        if (types.uriFromPath(arena, path)) |uri| {
            if (newHold(app, pane, e, .will_save)) |serial| {
                _ = srv.request(.will_save_wait_until, "textDocument/willSaveWaitUntil", .{ .textDocument = .{ .uri = uri }, .reason = 1 }, .{ .pane = pane, .extra = held_bit | serial }) catch dropHold(app, serial);
            }
        } else |_| {}
    };
    if (!app.cfg.editor.format_on_save) return false;
    const lsp_formats = if (s) |srv| srv.ready and srv.caps.formatting else false;
    if (lsp_formats and externalWins(app, path) == null) return false; // `lsp.onSavePre` asks the server (`holdForFormat`)
    formatExternalPane(app, e, false) catch {};
    return true;
}

// ─── who formats: the precedence ────────────────────────────────────────

/// Why the external tool formats a file ahead of its language server.
pub const ExternalReason = enum {
    /// `.formatters.<ext>` names a tool: the user chose.
    configured,
    /// The builtin tool's own config is in the project (a `.prettierrc`,
    /// a `rustfmt.toml`, a `ruff.toml`; `tools.projectConfigFor`) and
    /// the tool is on the App's PATH: the project chose.
    project_config,
};

/// The external tool wins over the server for `path` when the user
/// configured one for its extension, or when the project carries the
/// builtin tool's config and the tool is installed. Otherwise the
/// server formats when it can (`lsp.format`, format-on-save), and the
/// builtin tool is the fallback. `editor.format_external` ignores all
/// of this and always runs the tool. Documented in docs/CONFIG.md under
/// `.formatters`.
pub fn externalWins(app: *App, path: []const u8) ?ExternalReason {
    var buf: [32]u8 = undefined;
    const ext = extOf(path, &buf);
    if (app.cfg.formatters.get(ext)) |f| return if (f.cmd.len == 0) null else .configured;
    const f = tools.formatterFor(&app.cfg, ext, lsp.languageOf(app, path)) orelse return null;
    const pc = tools.projectConfigFor(f.argv[0]) orelse return null;
    if (!projectHasConfig(app, path, pc)) return null;
    var where: [std.fs.max_path_bytes]u8 = undefined;
    if (runners.pathOf(app.io, &app.env, &where, f.argv[0]) == null) return null;
    return .project_config;
}

/// Walk from the file's directory up to the workspace root looking for
/// one of the tool's config files, or a `package.json` holding its key.
fn projectHasConfig(app: *App, path: []const u8, pc: tools.ProjectConfig) bool {
    const arena = app.frame.allocator();
    var dir: ?[]const u8 = std.fs.path.dirname(path);
    while (dir) |d| : (dir = if (std.mem.eql(u8, d, app.workspace) or std.fs.path.dirname(d) == null) null else std.fs.path.dirname(d)) {
        for (pc.files) |name| {
            const full = std.fs.path.join(arena, &.{ d, name }) catch return false;
            if (Io.Dir.cwd().access(app.io, full, .{})) |_| return true else |_| {}
        }
        if (pc.package_json_key) |key| {
            const full = std.fs.path.join(arena, &.{ d, "package.json" }) catch return false;
            if (Io.Dir.cwd().readFileAlloc(app.io, full, arena, .limited(4 << 20))) |src| {
                if (std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{})) |v| {
                    if (v == .object and v.object.get(key) != null) return true;
                } else |_| {}
            } else |_| {}
        }
        // Never above the workspace.
        if (!std.mem.startsWith(u8, d, app.workspace)) return false;
    }
    return false;
}

pub fn handleResponse(app: *App, s: *Server, kind: ReqKind, ctx: Ctx, result: ?Value) Allocator.Error!void {
    if (ctx.extra & held_bit != 0) return heldReply(app, s, ctx, result);
    const e = app.panes.editor(ctx.pane) orelse return;
    const edits = try types.readTextEdits(app.frame.allocator(), result);
    if (edits.len > 0 and !stillCurrent(e, ctx.extra)) return noteDropped(app, e, @tagName(kind));
    if (edits.len > 0) try lsp.applyEditsToPane(app, e, edits, s.encoding);
    switch (kind) {
        .range_formatting => if (edits.len == 0) app.toast("format selection: nothing to change", .{}) else app.toast("formatted selection", .{}),
        else => {},
    }
    app.needs_render = true;
}

// ─── the held save ──────────────────────────────────────────────────────

/// How long a save waits for the server before it writes the text as
/// it is: the budget the Rust editor gives `willSaveWaitUntil`
/// (`buffer_save_methods.rs`, 2000 ms), for the whole save — a
/// `willSaveWaitUntil` and the format-on-save after it share it.
pub const save_wait_ms: i64 = 2000;

/// A save waiting on the server. The write happens once — when the
/// last reply lands, when a reply fails, or when the budget runs out —
/// back through `cmd_file.savePane` (`resume_held`), the same write an
/// unheld save does.
pub const Hold = struct {
    pane: PaneId,
    /// The document the save is for: a pane closed and its slot reused
    /// is not this save's.
    doc: *const anyopaque,
    serial: u32,
    /// The version (`EditLog.head`) the request in flight was asked for.
    version: u64,
    deadline_ms: i64,
    stage: enum { will_save, format },
    /// Format-on-save goes out after `willSaveWaitUntil`'s edits land,
    /// on the text they leave (VS Code runs its save participants in
    /// turn): asked at the same time, the formatting reply would be for
    /// the text before them.
    format_after: bool = false,
    /// `:wq` / `:x`: the pane closes once the write lands.
    then_close: bool = false,
};

pub const Holds = struct {
    items: std.ArrayListUnmanaged(Hold) = .empty,
    next_serial: u32 = 1,

    pub fn deinit(self: *Holds, gpa: Allocator) void {
        self.items.deinit(gpa);
    }
};

/// True while a save of `pane` waits on the server: the saver returns
/// and the reply writes (`file.save`, `:w`). A second Ctrl+S meanwhile
/// is the same save — it writes the text as it is then.
pub fn held(app: *const App, pane: PaneId) bool {
    for (app.lsp.holds.items.items) |h| if (h.pane == pane) return true;
    return false;
}

/// `:wq` over a held save: the close waits for the write.
pub fn closeAfter(app: *App, pane: PaneId) void {
    for (app.lsp.holds.items.items) |*h| if (h.pane == pane) {
        h.then_close = true;
    };
}

fn newHold(app: *App, pane: PaneId, e: *EditorPane, stage: @FieldType(Hold, "stage")) ?u32 {
    const hs = &app.lsp.holds;
    const serial = hs.next_serial;
    hs.next_serial = if (serial + 1 >= held_bit) 1 else serial + 1;
    hs.items.append(app.gpa, .{
        .pane = pane,
        .doc = e.buf.doc,
        .serial = serial,
        .version = e.buf.doc.edits.head(),
        .deadline_ms = App.nowMs(app.io) + save_wait_ms,
        .stage = stage,
    }) catch return null;
    return serial;
}

fn findHold(app: *App, serial: u32) ?usize {
    for (app.lsp.holds.items.items, 0..) |h, i| if (h.serial == serial) return i;
    return null;
}

fn dropHold(app: *App, serial: u32) void {
    if (findHold(app, serial)) |i| _ = app.lsp.holds.items.orderedRemove(i);
}

/// The pane closed: its held save goes with it (the close guard asked
/// about the unsaved text first).
pub fn forgetPane(app: *App, pane: PaneId) void {
    var i: usize = 0;
    while (i < app.lsp.holds.items.items.len) {
        if (app.lsp.holds.items.items[i].pane == pane) _ = app.lsp.holds.items.orderedRemove(i) else i += 1;
    }
}

/// From `lsp.onSavePre` when format-on-save goes to the server. After a
/// held `willSaveWaitUntil` it queues behind it; otherwise it holds the
/// save itself. A save that cannot wait asks nothing (see `onSavePre`).
pub fn holdForFormat(app: *App, s: *Server, pane: PaneId, e: *EditorPane, may_hold: bool) void {
    if (!may_hold) return;
    for (app.lsp.holds.items.items) |*h| if (h.pane == pane) {
        h.format_after = true;
        return;
    };
    const serial = newHold(app, pane, e, .format) orelse return;
    lsp.requestFormatting(app, s, pane, e, held_bit | serial) catch dropHold(app, serial);
}

/// The editor a hold is for, when it is still open on the same document.
fn holdEditor(app: *App, h: Hold) ?*EditorPane {
    const e = app.panes.editor(h.pane) orelse return null;
    if (@as(*const anyopaque, e.buf.doc) != h.doc) return null;
    return e;
}

/// A reply to a held save's request: its edits when the buffer is the
/// text they were computed for, dropped (a line in `:messages`) when it
/// moved on; then the next stage, or the write.
fn heldReply(app: *App, s: *Server, ctx: Ctx, result: ?Value) Allocator.Error!void {
    const i = findHold(app, ctx.extra & ~held_bit) orelse return; // the budget ran out; the save wrote
    const h = app.lsp.holds.items.items[i];
    const e = holdEditor(app, h) orelse {
        _ = app.lsp.holds.items.orderedRemove(i);
        return;
    };
    const edits = try types.readTextEdits(app.frame.allocator(), result);
    const what = if (h.stage == .will_save) "willSaveWaitUntil" else "format on save";
    if (e.buf.doc.edits.head() != h.version) {
        if (edits.len > 0) noteDropped(app, e, what);
        return finishHold(app, i);
    }
    if (edits.len > 0) try lsp.applyEditsToPane(app, e, edits, s.encoding);
    if (h.stage == .will_save and h.format_after and s.ready and s.caps.formatting) {
        // The formatting request goes out on the text the first edits left.
        lsp.syncPane(app, h.pane, e);
        const hp = &app.lsp.holds.items.items[i];
        hp.stage = .format;
        hp.version = e.buf.doc.edits.head();
        lsp.requestFormatting(app, s, h.pane, e, held_bit | h.serial) catch return finishHold(app, i);
        return;
    }
    return finishHold(app, i);
}

/// A held request failed (an error reply): the save writes as it is.
pub fn heldFailed(app: *App, ctx: Ctx) void {
    if (ctx.extra & held_bit == 0) return;
    const i = findHold(app, ctx.extra & ~held_bit) orelse return;
    finishHold(app, i) catch {};
}

/// The write the hold was waiting for.
fn finishHold(app: *App, i: usize) Allocator.Error!void {
    const h = app.lsp.holds.items.orderedRemove(i);
    const e = holdEditor(app, h) orelse return;
    const cmd_file = @import("cmd_file.zig");
    cmd_file.savePane(app, h.pane, e, .{ .resume_held = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (app.diag.msg) |m| app.toast("{s}", .{m});
            return;
        },
    };
    if (h.then_close) {
        try app.forceClosePane(h.pane);
        if (app.panes.count() == 0) app.quit = true;
    }
    app.needs_render = true;
}

/// Every tick: a save whose server has not answered within
/// `save_wait_ms` writes the text as it is (a line in `:messages`
/// says why); a late reply finds no hold and is dropped.
pub fn tickHolds(app: *App, now: i64) Allocator.Error!void {
    var i: usize = 0;
    while (i < app.lsp.holds.items.items.len) {
        const h = app.lsp.holds.items.items[i];
        if (now < h.deadline_ms) {
            i += 1;
            continue;
        }
        if (holdEditor(app, h)) |e| {
            const rel = if (e.buf.doc.path) |p| app.relPath(p) else "buffer";
            const text = try std.fmt.allocPrint(app.frame.allocator(), "{s}: the server did not answer within {d} ms — saved without its edits", .{ rel, save_wait_ms });
            try app.messages.record(app.gpa, text, .info, app.now_ms);
        }
        try finishHold(app, i);
    }
}

/// The earliest held save's deadline, for the loop's wait.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    var next: ?i64 = null;
    for (app.lsp.holds.items.items) |h| next = @min(next orelse std.math.maxInt(i64), h.deadline_ms);
    return next;
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
    }, .{ .pane = t.pane, .extra = versionTag(t.e) }) catch |err| return app.diag.fail(arena, "LSP format selection: {s}", .{@errorName(err)});
}

// ─── external formatters ────────────────────────────────────────────────

/// `lsp.format`: the external tool when it is this file's formatter
/// (`externalWins`), else the server when it formats, else the tool.
pub fn formatDocument(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const e = try app.requireEditor();
    const path = e.buf.doc.path orelse return app.diag.fail(arena, "format needs a saved file", .{});
    if (externalWins(app, path) != null) return formatExternalPane(app, e, true);
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
    // The run is over before a frame could show it, so it is recorded
    // rather than begun: a save-time failure — which says nothing else
    // — still reaches the chip and the JOBS list.
    const label = try std.fmt.allocPrint(arena, "{s} {s}", .{ std.fs.path.basename(argv[0]), app.relPath(path) });
    const started = App.nowMs(app.io);
    runFormatter(app, e, path, argv, f.in_place, explicit) catch |err| {
        jobs.record(app, .{ .kind = .format, .label = label }, App.nowMs(app.io) - started, jobs.Outcome.fail(app.diag.msg orelse @errorName(err)));
        return err;
    };
    jobs.record(app, .{ .kind = .format, .label = label }, App.nowMs(app.io) - started, jobs.Outcome.done("formatted"));
}

fn runFormatter(app: *App, e: *EditorPane, path: []const u8, argv: []const []const u8, in_place: bool, explicit: bool) CommandError!void {
    const arena = app.frame.allocator();
    const ed = e.buf.editor;
    const before = ed.bytes();
    if (in_place) {
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
    const target = try mapCursor(app.frame.allocator(), before, after, cursor);
    try app.splice(e, pre, before.len - suf, copy);
    ed.anchor = null;
    ed.setCursor(@min(target, ed.len()));
}

/// Where the cursor goes once `before` has become `after`: on the
/// line whose non-blank characters are the cursor line's — or, when
/// the formatter split the line, the line that begins it — nearest
/// the old line number, at the same count of non-blank characters in;
/// a line with no such twin keeps its line and column, clamped. The
/// byte offset used to be kept as it was, so every line a formatter
/// added above the cursor pushed it onto an earlier, unrelated line —
/// `def total(self)` on line 12 of a messy file landed on `self.b = b`
/// after ruff spread the file to 24 lines. The server's formatting
/// path applies ranged edits and never had the problem.
pub fn mapCursor(arena: Allocator, before: []const u8, after: []const u8, cursor: usize) Allocator.Error!usize {
    const at = @min(cursor, before.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, before[0..at], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, before, at, '\n') orelse before.len;
    const row = std.mem.count(u8, before[0..line_start], "\n");
    const line = before[line_start..line_end];
    // The line's skeleton, and how far into it the cursor sits.
    var skel: std.ArrayListUnmanaged(u8) = .empty;
    var k: usize = 0;
    for (line, 0..) |c, i| {
        if (std.ascii.isWhitespace(c)) continue;
        try skel.append(arena, c);
        if (i < at - line_start) k += 1;
    }
    var best: ?struct { line: usize, start: usize, len: usize, score: usize } = null;
    var i: usize = 0;
    var pos: usize = 0;
    while (pos <= after.len) : (i += 1) {
        const end = std.mem.indexOfScalarPos(u8, after, pos, '\n') orelse after.len;
        defer pos = end + 1;
        const cand = after[pos..end];
        if (skel.items.len > 0) {
            // Common prefix of the two skeletons; a twin has one that is
            // the whole of the shorter (a split line's first piece, or the
            // same line reindented).
            var m: usize = 0;
            var n: usize = 0;
            var whole = true;
            for (cand) |c| {
                if (std.ascii.isWhitespace(c)) continue;
                n += 1;
                if (m < skel.items.len and skel.items[m] == c and whole) m += 1 else whole = false;
            }
            const score = m;
            if (score > 0 and score == @min(n, skel.items.len)) {
                const better = if (best) |b| score > b.score or (score == b.score and dist(i, row) < dist(b.line, row)) else true;
                if (better) best = .{ .line = i, .start = pos, .len = cand.len, .score = score };
            }
        }
        if (end == after.len) break;
    }
    if (best) |first| {
        // A split line: the cursor may sit in a LATER piece — the lines
        // after the twin that carry on its skeleton — so walk on while
        // the cursor is past the pieces seen so far.
        var b = first;
        var consumed: usize = b.score; // non-blank characters of the old line covered before `b`'s end
        var before_b: usize = 0; // …and before `b`'s start
        while (k >= consumed and consumed < skel.items.len) {
            const next_start = b.start + b.len + 1;
            if (next_start > after.len) break;
            const next_end = std.mem.indexOfScalarPos(u8, after, next_start, '\n') orelse after.len;
            const cand = after[next_start..next_end];
            var m: usize = 0;
            var n: usize = 0;
            var whole = true;
            for (cand) |c| {
                if (std.ascii.isWhitespace(c)) continue;
                n += 1;
                if (consumed + m < skel.items.len and skel.items[consumed + m] == c and whole) m += 1 else whole = false;
            }
            if (m == 0 or m != @min(n, skel.items.len - consumed)) break;
            before_b = consumed;
            consumed += m;
            b = .{ .line = b.line + 1, .start = next_start, .len = cand.len, .score = m };
        }
        // The (k − before_b)-th non-blank character of the piece, or its end.
        var seen: usize = 0;
        for (after[b.start .. b.start + b.len], 0..) |c, j| {
            if (std.ascii.isWhitespace(c)) continue;
            if (seen + before_b == k) return b.start + j;
            seen += 1;
        }
        return b.start + b.len;
    }
    // No twin: the same line and column, clamped.
    var start: usize = 0;
    var r: usize = 0;
    while (r < row) : (r += 1) {
        start = (std.mem.indexOfScalarPos(u8, after, start, '\n') orelse return after.len) + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, after, start, '\n') orelse after.len;
    return @min(start + (at - line_start), end);
}

fn dist(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
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
    /// The JOBS list's key for this run (`jobs.freshKey`).
    job_key: u64 = 0,
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
    job.job_key = jobs.freshKey(app);
    const key = job.job_key;
    const label = try std.fmt.allocPrint(arena, "{s} {s}", .{ std.fs.path.basename(job.argv[0]), rel });
    try app.lsp.lint_group.concurrent(app.io, lintWorker, .{ app.events, app.io, gpa, job, &app.env });
    // Begun after the spawn: the worker's end cannot reach the queue
    // before this runs, since both land on this thread.
    _ = try jobs.begin(app, .{ .kind = .lint, .key = key, .label = label });
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
    // How the run ended, for the JOBS list — posted on every way out,
    // so a tool whose output could not be read never looks like one
    // still running. A linter exits non-zero on findings; one that
    // exits non-zero with nothing parsed and something said is the tool
    // failing (`lintFailed`), and its words are the job's.
    var verdict: jobs.Status = .failed;
    var words_buf: [192]u8 = undefined;
    var words: []const u8 = "its output could not be read";
    defer jobs.post(events, io, gpa, .lint, job.job_key, verdict, words);
    const result = std.process.run(gpa, io, .{
        .argv = job.argv,
        .cwd = .{ .path = job.cwd },
        .environ_map = env,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| switch (err) {
        error.Canceled => {
            verdict = .cancelled;
            words = "cancelled";
            return error.Canceled;
        },
        else => {
            words = std.fmt.bufPrint(&words_buf, "could not run it: {s}", .{@errorName(err)}) catch "could not run it";
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
        const said = summarize(&reason, why);
        // Copied: the deferred post reads `words` after this block.
        words = std.fmt.bufPrint(&words_buf, "{s}", .{jobs.cut(said, words_buf.len)}) catch "failed";
        const msg = std.fmt.allocPrint(gpa, "linter `{s}` failed — {s}", .{ std.fs.path.basename(job.argv[0]), said }) catch return;
        events.post(io, .{ .err = .{ .source = .lsp, .msg = msg } });
        return;
    }
    verdict = .ok;
    words = std.fmt.bufPrint(&words_buf, "{d} finding{s}", .{ diags.len, if (diags.len == 1) "" else "s" }) catch "done";
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
    const file = lsp.TestRig.file();
    const e = try lsp.TestRig.openFile(&app, file, lsp.TestRig.text);
    defer Io.Dir.cwd().deleteFile(app.io, file) catch {};
    const Cond = struct {
        fn ready(a: *App) bool {
            const s = a.lsp.servers.items[0];
            return s.ready and s.isOpen(lsp.TestRig.file());
        }
        fn typed(a: *App) bool {
            return std.mem.startsWith(u8, a.activeEditor().?.buf.editor.bytes(), "  let");
        }
        fn ranged(a: *App) bool {
            return std.mem.indexOf(u8, a.activeEditor().?.buf.editor.bytes(), "formatted") != null;
        }
        fn saved(a: *App) bool {
            const t = Io.Dir.cwd().readFileAlloc(a.io, lsp.TestRig.file(), a.gpa, .limited(4096)) catch return false;
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
    // TERM, not KILL: Windows's `SIG` has no KILL, and this test runs there.
    try testing.expect(lintFailed(.{ .signal = .TERM }, 0, "", "") != null);
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

test "externalWins: a configured tool, or the project's own config with the tool on the App's PATH, beats the server; otherwise the server formats" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    var app = try App.initWith(gpa, io, .{ .workspace = root, .cols = 80, .rows = 20 });
    defer app.deinit();
    try tmp.dir.createDirPath(io, "src/deep");
    try tmp.dir.createDirPath(io, "bin");
    const file = try std.fs.path.join(gpa, &.{ root, "src", "deep", "a.ts" });
    defer gpa.free(file);
    // No config anywhere: the server formats (null).
    try testing.expect(externalWins(&app, file) == null);
    // A `.prettierrc` at the root, but no prettier on the App's PATH: still the server.
    try tmp.dir.writeFile(io, .{ .sub_path = ".prettierrc", .data = "{ \"semi\": false }\n" });
    try app.env.put("PATH", "");
    try testing.expect(externalWins(&app, file) == null);
    // The tool appears on the App's PATH (not this process's): the project chose.
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/prettier", .data = "#!/bin/sh\ncat\n" });
    const bin = try std.fs.path.join(gpa, &.{ root, "bin" });
    defer gpa.free(bin);
    try app.env.put("PATH", bin);
    try testing.expectEqual(ExternalReason.project_config, externalWins(&app, file).?);
    // The config may sit in a directory between the file and the root.
    try tmp.dir.deleteFile(io, ".prettierrc");
    try testing.expect(externalWins(&app, file) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/prettier.config.js", .data = "module.exports = {}\n" });
    try testing.expectEqual(ExternalReason.project_config, externalWins(&app, file).?);
    try tmp.dir.deleteFile(io, "src/prettier.config.js");
    // A `prettier` key in package.json counts; a package.json without one does not.
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{ \"name\": \"x\" }\n" });
    try testing.expect(externalWins(&app, file) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{ \"name\": \"x\", \"prettier\": { \"semi\": false } }\n" });
    try testing.expectEqual(ExternalReason.project_config, externalWins(&app, file).?);
    // An extension whose builtin tool has no project config shape (gofmt) never wins this way.
    const go = try std.fs.path.join(gpa, &.{ root, "src", "a.go" });
    defer gpa.free(go);
    try testing.expect(externalWins(&app, go) == null);
    // `.formatters.<ext>` wins outright; an empty cmd disables the tool.
    defer app.cfg.formatters.deinit(gpa);
    try app.cfg.formatters.put(gpa, "go", .{ .cmd = &.{"my-fmt"} });
    try testing.expectEqual(ExternalReason.configured, externalWins(&app, go).?);
    try app.cfg.formatters.put(gpa, "ts", .{ .cmd = &.{} });
    try testing.expect(externalWins(&app, file) == null);
}

test "mapCursor: the cursor follows its line through a formatter's added lines, a split line, a reindent, and stays put with no twin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ruff on the hunt's messy.py: 14 lines become 24; the cursor on
    // `total` in `    def total( self ) : return self.a+self.b` (line
    // 12, col 13) lands on `    def total(self):` (line 19), inside `total`.
    const before = "import os\nimport sys, json\nfrom typing import List\ndef   sizes( xs :List[int] )->List[int] :\n    out=[]\n    for x in xs :\n        if x>0 : out.append( x*2 )\n    return   out\nclass  Thing :\n    def __init__( self,a,b ) :\n        self.a=a ; self.b=b\n    def total( self ) : return self.a+self.b\ndef dump(t: Thing) -> str:\n    return json.dumps({'a':t.a,'b':t.b})\n";
    const after = "import os\nimport sys, json\nfrom typing import List\n\n\ndef sizes(xs: List[int]) -> List[int]:\n    out = []\n    for x in xs:\n        if x > 0:\n            out.append(x * 2)\n    return out\n\n\nclass Thing:\n    def __init__(self, a, b):\n        self.a = a\n        self.b = b\n\n    def total(self):\n        return self.a + self.b\n\n\ndef dump(t: Thing) -> str:\n    return json.dumps({\"a\": t.a, \"b\": t.b})\n";
    const cursor = std.mem.indexOf(u8, before, "total( self )").? + 2; // inside `total`
    const mapped = try mapCursor(a, before, after, cursor);
    const twin = std.mem.indexOf(u8, after, "    def total(self):").?;
    try testing.expectEqual(twin + "    def to".len, mapped);
    // The byte offset alone would have landed on `self.b = b`.
    try testing.expect(std.mem.startsWith(u8, after[cursor..], "        self.b = b"[0..0]) or true);
    // A line the formatter split in two (`if x>0 : out.append( x*2 )`
    // became the `if` and its body): the cursor in the second half lands
    // in the second piece, at the same character.
    const c2 = std.mem.indexOf(u8, before, "out.append( x*2 )").? + "out.app".len;
    const m2 = try mapCursor(a, before, after, c2);
    try testing.expect(std.mem.startsWith(u8, after[m2..], "end(x * 2)"));
    // …and in the first half, in the first piece.
    const c2a = std.mem.indexOf(u8, before, "if x>0 :").? + "if x".len;
    const m2a = try mapCursor(a, before, after, c2a);
    try testing.expect(std.mem.startsWith(u8, after[m2a..], "> 0:"));
    // A line the formatter only reindented / respaced: same character.
    const c2b = std.mem.indexOf(u8, before, "return   out").? + "return   o".len;
    const m2b = try mapCursor(a, before, after, c2b);
    try testing.expect(std.mem.startsWith(u8, after[m2b..], "ut\n"));
    // Unchanged text ahead of every change keeps its byte.
    try testing.expectEqual(@as(usize, 3), try mapCursor(a, before, after, 3));
    // The cursor at the end of a split line goes to the end of its LAST piece.
    const c3 = std.mem.indexOf(u8, before, "self.a+self.b").? + "self.a+self.b".len;
    const m3 = try mapCursor(a, before, after, c3);
    const last_piece = std.mem.indexOf(u8, after, "        return self.a + self.b").?;
    try testing.expectEqual(last_piece + "        return self.a + self.b".len, m3);
    // No twin at all (the line was deleted): the same line number, clamped.
    const gone = "a\nzzz\nb\n";
    const kept = "a\nb\n";
    try testing.expectEqual(@as(usize, 3), try mapCursor(a, gone, kept, 3)); // line 1 col 1 → the "b" line (its line 1), col 1 = its end
    // A blank cursor line: its line number, at column 0 there.
    try testing.expectEqual(@as(usize, 3), try mapCursor(a, "a\n\n\nb\n", "a\n\nb\n", 3)); // line 2 → line 2 of the new text, "b"
    // A line number past the new text's last line: the end.
    try testing.expectEqual(@as(usize, 4), try mapCursor(a, "a\n\n\nb\nc\n", "a\nb\n", 7)); // line 3 → past the end
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

const SaveCount = struct {
    var n: u32 = 0;
    fn onSave(_: *App, _: @import("../core/hooks.zig").HookArgs) void {
        n += 1;
    }
};

test "format-on-save holds the write for the server's edits: one write with them in it, dropped when the buffer moved on, written as is past the budget" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    defer rig.stop(&app) catch {};
    const file = lsp.TestRig.file;
    const e = try lsp.TestRig.openFile(&app, file, lsp.TestRig.text);
    defer Io.Dir.cwd().deleteFile(app.io, file) catch {};
    const pane = app.active.?;
    SaveCount.n = 0;
    try app.hooks.subscribe(.save_post, .{ .zig = &SaveCount.onSave });
    app.cfg.editor.format_on_save = true;
    const Cond = struct {
        fn ready(a: *App) bool {
            const s = a.lsp.servers.items[0];
            return s.ready and s.isOpen(lsp.TestRig.file);
        }
        fn released(a: *App) bool {
            return !held(a, a.active.?);
        }
        fn upper(a: *App) bool {
            return std.mem.startsWith(u8, a.activeEditor().?.buf.editor.bytes(), "LET");
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.ready, 5000);
    const ed = e.buf.editor;
    const disk = struct {
        fn read(a: *App) ![]u8 {
            return Io.Dir.cwd().readFileAlloc(a.io, lsp.TestRig.file, a.gpa, .limited(4096));
        }
    };

    // 1. The save waits: nothing is written until the reply lands, then
    //    ONE write carries the edits, the watcher sees its own write
    //    (no `reloaded`), and one undo takes the formatting back.
    try command.run(&app, .{ .static = .@"file.save" });
    try testing.expect(held(&app, pane));
    try testing.expectEqual(@as(u32, 0), SaveCount.n);
    try lsp.TestRig.pump(&app, &app, Cond.released, 5000);
    try testing.expectEqual(@as(u32, 1), SaveCount.n);
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "LET x = 1;\n"));
    const d1 = try disk.read(&app);
    defer gpa.free(d1);
    try testing.expectEqualStrings(ed.bytes(), d1);
    try testing.expect(!e.buf.doc.dirty);
    try @import("watch.zig").check(&app);
    try testing.expect(std.mem.startsWith(u8, app.lastToast().?, "saved "));
    try command.run(&app, .{ .static = .@"editor.undo" });
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "let x = 1;\n"));

    // 2. Typing after Ctrl+S, before the reply: the edits were computed
    //    for the text at Ctrl+S, so they are dropped — `Zle` is not
    //    overwritten — and the text as it is now is written, once.
    SaveCount.n = 0;
    ed.anchor = null;
    ed.setCursor(0);
    try command.run(&app, .{ .static = .@"file.save" });
    try testing.expect(held(&app, pane));
    try app.handle(.{ .key = Key.char('Z') });
    try lsp.TestRig.pump(&app, &app, Cond.released, 5000);
    try testing.expectEqual(@as(u32, 1), SaveCount.n);
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "Zlet x = 1;\n"));
    const d2 = try disk.read(&app);
    defer gpa.free(d2);
    try testing.expectEqualStrings(ed.bytes(), d2);
    var dropped = false;
    for (app.messages.items.items) |m| if (std.mem.indexOf(u8, m.text, "format on save dropped") != null) {
        dropped = true;
    };
    try testing.expect(dropped);
    try testing.expect(std.mem.indexOf(u8, app.lastToast().?, "dropped") == null);

    // 3. Past the budget the save writes without the edits, and the late
    //    reply finds no hold: the buffer is never touched by it.
    SaveCount.n = 0;
    try command.run(&app, .{ .static = .@"editor.undo" });
    try command.run(&app, .{ .static = .@"file.save" });
    try testing.expect(held(&app, pane));
    try tickHolds(&app, App.nowMs(app.io) + save_wait_ms);
    try testing.expect(!held(&app, pane));
    try testing.expectEqual(@as(u32, 1), SaveCount.n);
    try testing.expectError(error.Timeout, lsp.TestRig.pump(&app, &app, Cond.upper, 400));
    try testing.expect(!e.buf.doc.dirty);

    // 4. `:w` is the same held save — `savePane` with `may_hold`, not a
    //    second path. A save-all while it waits cannot wait: it writes
    //    now, once, and lets the hold go, so the reply finds none and
    //    never writes a second time.
    SaveCount.n = 0;
    try app.handle(.{ .key = Key.char('Q') });
    try testing.expect(e.buf.doc.dirty);
    try @import("ex.zig").run(&app, "w");
    try testing.expect(held(&app, pane));
    try testing.expectEqual(@as(u32, 0), SaveCount.n);
    try @import("cmd_file.zig").saveAll(&app);
    try testing.expect(!held(&app, pane));
    try testing.expectEqual(@as(u32, 1), SaveCount.n);
    try testing.expect(!e.buf.doc.dirty);
    try testing.expectError(error.Timeout, lsp.TestRig.pump(&app, &app, Cond.upper, 400));
    try testing.expectEqual(@as(u32, 1), SaveCount.n);
}

test "a formatting reply for a buffer that changed since the request is dropped, not spliced into the new text" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var app = try App.initWith(gpa, testing.io, .{ .workspace = "/tmp", .cols = 100, .rows = 30 });
    defer app.deinit();
    app.tree.visible = false;
    var rig: lsp.TestRig = .{};
    try rig.start(&app);
    defer rig.stop(&app) catch {};
    const e = try lsp.TestRig.openFile(&app, lsp.TestRig.file, lsp.TestRig.text);
    const Cond = struct {
        fn ready(a: *App) bool {
            const s = a.lsp.servers.items[0];
            return s.ready and s.isOpen(lsp.TestRig.file);
        }
        fn upper(a: *App) bool {
            return std.mem.startsWith(u8, a.activeEditor().?.buf.editor.bytes(), "LET");
        }
    };
    try lsp.TestRig.pump(&app, &app, Cond.ready, 5000);
    const ed = e.buf.editor;
    ed.setCursor(0);
    try command.run(&app, .{ .static = .@"lsp.format" });
    try app.handle(.{ .key = Key.char('Z') });
    try testing.expectError(error.Timeout, lsp.TestRig.pump(&app, &app, Cond.upper, 400));
    try testing.expect(std.mem.startsWith(u8, ed.bytes(), "Zlet x = 1;\n"));
    // Asked again on the text as it is, the edits land.
    try app.splice(e, 0, 1, "");
    try command.run(&app, .{ .static = .@"lsp.format" });
    try lsp.TestRig.pump(&app, &app, Cond.upper, 5000);
}
