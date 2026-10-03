//! The agent face: Claude Code's IDE protocol, the App's side
//! (`docs/research/api-design.md` §6.1–6.4, `docs/API.md` "Agent face").
//!
//! A Claude Code session pane spawned while the API serves gets its own
//! loopback WebSocket listener (`api/ide_server.zig`), a lock file
//! `<claude config>/ide/<port>.lock` (0600) naming it and its token, and
//! `CLAUDE_CODE_SSE_PORT` / `ENABLE_IDE_INTEGRATION=true` in its
//! environment — so the session links to mnml with no setup. One port per
//! pane: the token is read from the lock file the port names, so the
//! connection *is* that pane (`pane:<id>`), and every tool goes through
//! the gate (`ipc_gate.zig`) as it.
//!
//! The session speaks MCP over the socket: `initialize`, `tools/list`,
//! `tools/call`. The tools read (selection, open editors, diagnostics,
//! workspace folders, dirty state), open things to look at (`openFile`,
//! `openDiff`), close a tab, and — the one write — `saveDocument`, which
//! asks you (or matches `.api`). `openDiff` shows the proposal in the
//! review pane (`ai_apply.zig`) and answers when you accept or reject it;
//! an accept lands in the buffer and leaves it unsaved.
//!
//! mnml tells the session about your selection (`selection_changed`, to
//! the session pane you looked at last, at most one per 100 ms) and,
//! on `ai.send_selection`, points it at a range (`at_mentioned`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const CommandError = command.CommandError;
const gate = @import("ipc_gate.zig");
const api = @import("api.zig");
const api_paths = @import("../api/paths.zig");
const server = @import("../api/ide_server.zig");
const launch_profiles = @import("launch_profiles.zig");
const ai_apply = @import("ai_apply.zig");
const lsp = @import("lsp.zig");
const lsp_types = @import("../lsp/types.zig");
const cmd_file = @import("cmd_file.zig");

pub const env_port = "CLAUDE_CODE_SSE_PORT";
pub const env_enable = "ENABLE_IDE_INTEGRATION";
/// Where Claude Code looks for lock files: `$CLAUDE_CONFIG_DIR/ide`,
/// else `~/.claude/ide`.
pub const env_config_dir = "CLAUDE_CONFIG_DIR";
pub const ide_name = "mnml";
/// What `initialize` answers when the client names no version.
pub const mcp_version = "2025-03-26";
/// At most one `selection_changed` per this long.
pub const selection_throttle_ms: i64 = 100;

/// The mark a linked session wears on its card and its tab.
pub const link_glyph = "\u{21C4}";
pub const link_ascii = "=";

pub const State = struct {
    links: std.AutoHashMapUnmanaged(PaneId, Link) = .empty,
    /// A test's lock directory. Under test nothing else is used, so no
    /// test can write into a real `~/.claude`.
    lock_dir_override: ?[]const u8 = null,
    /// Messages with no listener to carry them — a test reads these.
    unsent: std.ArrayListUnmanaged(Unsent) = .empty,
    /// The selection last told, and when; a change not told yet.
    sel_seen: Sel = .{},
    sel_sent_ms: i64 = std.math.minInt(i64) / 2,
    sel_pending: bool = false,

    pub const Unsent = struct { pane: PaneId, conn: u32, line: []u8 };

    pub fn deinit(s: *State, gpa: Allocator) void {
        var it = s.links.valueIterator();
        while (it.next()) |l| l.deinit(gpa);
        s.links.deinit(gpa);
        for (s.unsent.items) |u| gpa.free(u.line);
        s.unsent.deinit(gpa);
    }
};

/// What identifies a selection without copying it.
pub const Sel = struct {
    pane: ?PaneId = null,
    doc: ?*const anyopaque = null,
    seq: u64 = 0,
    cursor: usize = 0,
    anchor: ?usize = null,

    fn eql(a: Sel, b: Sel) bool {
        return a.pane == b.pane and a.doc == b.doc and a.seq == b.seq and a.cursor == b.cursor and a.anchor == b.anchor;
    }
};

/// One session pane's link.
pub const Link = struct {
    listener: ?*server.Listener = null,
    port: u16 = 0,
    /// Owned; empty when no lock file was written (a test's link).
    lock_path: []u8 = &.{},
    /// Each upgraded connection, and whether it has said `initialize`.
    conns: std.AutoHashMapUnmanaged(u32, bool) = .empty,
    /// The first-connect toast is said once per link.
    greeted: bool = false,

    fn deinit(l: *Link, gpa: Allocator) void {
        l.conns.deinit(gpa);
        gpa.free(l.lock_path);
    }

    /// A connection has said `initialize`: the link is up.
    pub fn up(l: *const Link) bool {
        var it = l.conns.valueIterator();
        while (it.next()) |v| if (v.*) return true;
        return false;
    }
};

/// Whether `pane` is a session whose IDE link is up — its card and tab
/// wear `link_glyph`.
pub fn linked(app: *const App, pane: PaneId) bool {
    const l = app.ide.links.getPtr(pane) orelse return false;
    return l.up();
}

// ─── the lock file ──────────────────────────────────────────────────────

/// The lock directory, or null when there is none to use. On the frame
/// arena.
fn lockDir(app: *App) Allocator.Error!?[]const u8 {
    if (app.ide.lock_dir_override) |d| return d;
    if (builtin.is_test) return null;
    const arena = app.frame.allocator();
    if (app.env.get(env_config_dir)) |d| if (d.len > 0) return try std.fs.path.join(arena, &.{ d, "ide" });
    const home = app.env.get("HOME") orelse app.env.get("USERPROFILE") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(arena, &.{ home, ".claude", "ide" });
}

/// The lock file's JSON: what Claude Code reads to find and trust the
/// listener.
pub fn lockJson(arena: Allocator, pid: i64, workspace: []const u8, token: []const u8) Allocator.Error![]u8 {
    var a: Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    w.print("{{\"pid\":{d},\"workspaceFolders\":[", .{pid}) catch return error.OutOfMemory;
    try jstr(w, workspace);
    w.writeAll("],\"ideName\":\"" ++ ide_name ++ "\",\"transport\":\"ws\",\"authToken\":") catch return error.OutOfMemory;
    try jstr(w, token);
    w.writeAll("}") catch return error.OutOfMemory;
    return a.written();
}

fn writeLock(app: *App, dir: []const u8, port: u16, token: []const u8) ![]u8 {
    const io = app.io;
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    const path = try std.fmt.allocPrint(app.gpa, "{s}{c}{d}.lock", .{ dir, std.fs.path.sep, port });
    errdefer app.gpa.free(path);
    const perms: @FieldType(Io.Dir.CreateFileOptions, "permissions") = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    const f = try cwd.createFile(io, path, .{ .permissions = perms });
    defer f.close(io);
    // A file that was there already keeps its old mode through a create.
    if (builtin.os.tag != .windows) cwd.setFilePermissions(io, path, .fromMode(0o600), .{}) catch {};
    try f.writeStreamingAll(io, try lockJson(app.frame.allocator(), api_paths.selfPid(), app.workspace, token));
    return path;
}

// ─── spawn and close ────────────────────────────────────────────────────

/// Whether pane `id` gets the agent face: the API serves, and its child
/// is Claude Code. Codex gets nothing in this slice.
pub fn wants(app: *App, id: PaneId) bool {
    if (!api.serving(app)) return false;
    const p = app.panes.pty(id) orelse return false;
    return launch_profiles.productOfArgv(app, p.argv) == .claude;
}

/// Pane `id` is spawning: bind its listener and write its lock file;
/// the port its child is told, or null when it gets no agent face. A
/// respawn replaces the link (a new port and a new token).
pub fn startFor(app: *App, id: PaneId) Allocator.Error!?u16 {
    if (!wants(app, id)) return null;
    stopFor(app, id);
    const dir = try lockDir(app) orelse return null;
    var raw: [server.token_len / 2]u8 = undefined;
    app.io.randomSecure(&raw) catch app.io.random(&raw);
    const tok = std.fmt.bytesToHex(raw, .lower);
    const l = server.Listener.start(app.gpa, app.io, app.events, id, tok) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            app.toast("Claude Code link: no listener ({s})", .{@errorName(err)});
            return null;
        },
    };
    const lock = writeLock(app, dir, l.port, &tok) catch |err| {
        l.stop();
        l.destroy();
        if (err == error.OutOfMemory) return error.OutOfMemory;
        app.toast("Claude Code link: no lock file in {s} ({s})", .{ dir, @errorName(err) });
        return null;
    };
    try app.ide.links.put(app.gpa, id, .{ .listener = l, .port = l.port, .lock_path = lock });
    return l.port;
}

/// Pane `id`'s link goes: the listener closes, the lock file is removed,
/// and what it was waiting on is let go.
pub fn stopFor(app: *App, id: PaneId) void {
    var kv = app.ide.links.fetchRemove(id) orelse return;
    var it = kv.value.conns.keyIterator();
    while (it.next()) |c| gate.dropConn(app, c.*) catch {};
    if (kv.value.listener) |l| {
        l.stop();
        l.destroy();
    }
    if (kv.value.lock_path.len > 0) Io.Dir.cwd().deleteFile(app.io, kv.value.lock_path) catch {};
    kv.value.deinit(app.gpa);
    // A diff it was waiting on stays up as a plain review.
    for (app.panes.slots.items) |*slot| if (slot.*) |*p| switch (p.*) {
        .ai_apply => |*ap| if (ap.ide) |d| if (d.session == id) {
            ap.ide = null;
        },
        else => {},
    };
    app.needs_render = true;
}

/// Pane `id` is closing: a session's link goes; a diff under review
/// answers the session that asked for it.
pub fn forgetPane(app: *App, id: PaneId) void {
    stopFor(app, id);
    const p = app.panes.get(id) orelse return;
    switch (p.*) {
        .ai_apply => |*ap| if (ap.ide) |d| {
            ap.ide = null;
            answerDiff(app, d, ap) catch {};
        },
        else => {},
    }
}

/// mnml is quitting: every listener and lock file goes.
pub fn shutdown(app: *App) void {
    while (true) {
        var it = app.ide.links.keyIterator();
        const id = (it.next() orelse break).*;
        stopFor(app, id);
    }
}

// ─── replies ────────────────────────────────────────────────────────────

fn jstr(w: *Io.Writer, s: []const u8) Allocator.Error!void {
    std.json.Stringify.encodeJsonString(s, .{}, w) catch return error.OutOfMemory;
}

fn connPane(app: *App, conn: u32) ?PaneId {
    var it = app.ide.links.iterator();
    while (it.next()) |e| if (e.value_ptr.conns.contains(conn)) return e.key_ptr.*;
    return null;
}

fn send(app: *App, pane: PaneId, conn: u32, line: []const u8) Allocator.Error!void {
    const l = app.ide.links.getPtr(pane) orelse return;
    if (l.listener) |s| return s.send(conn, line);
    try app.ide.unsent.append(app.gpa, .{ .pane = pane, .conn = conn, .line = try app.gpa.dupe(u8, line) });
}

fn sendOn(app: *App, conn: u32, line: []const u8) Allocator.Error!void {
    const pane = connPane(app, conn) orelse return;
    try send(app, pane, conn, line);
}

fn reply(app: *App, conn: u32, id_json: []const u8, result_json: []const u8) Allocator.Error!void {
    try sendOn(app, conn, try std.fmt.allocPrint(app.frame.allocator(), "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json }));
}

fn replyError(app: *App, conn: u32, id_json: []const u8, code: i32, message: []const u8) Allocator.Error!void {
    var a: Io.Writer.Allocating = .init(app.frame.allocator());
    const w = &a.writer;
    w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":", .{ id_json, code }) catch return error.OutOfMemory;
    try jstr(w, message);
    w.writeAll("}}") catch return error.OutOfMemory;
    try sendOn(app, conn, a.written());
}

/// A `tools/call` result: `texts` as text content items.
fn replyTool(app: *App, conn: u32, id_json: []const u8, texts: []const []const u8, is_error: bool) Allocator.Error!void {
    var a: Io.Writer.Allocating = .init(app.frame.allocator());
    const w = &a.writer;
    w.writeAll("{\"content\":[") catch return error.OutOfMemory;
    for (texts, 0..) |text, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("{\"type\":\"text\",\"text\":") catch return error.OutOfMemory;
        try jstr(w, text);
        w.writeByte('}') catch return error.OutOfMemory;
    }
    w.writeByte(']') catch return error.OutOfMemory;
    if (is_error) w.writeAll(",\"isError\":true") catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;
    try reply(app, conn, id_json, a.written());
}

/// A tool refused or failed, in the protocol's terms (an error result).
pub fn replyToolError(app: *App, conn: u32, id_json: []const u8, why: []const u8) Allocator.Error!void {
    try replyTool(app, conn, id_json, &.{why}, true);
}

// ─── the dispatcher ─────────────────────────────────────────────────────

/// One `.ide` event: a connection up, a message, or a connection gone.
pub fn handle(app: *App, inc: *server.Incoming) Allocator.Error!void {
    defer inc.destroy(app.gpa);
    const link = app.ide.links.getPtr(inc.pane) orelse return;
    switch (inc.kind) {
        .opened => return link.conns.put(app.gpa, inc.conn, false),
        .closed => {
            _ = link.conns.remove(inc.conn);
            try gate.dropConn(app, inc.conn);
            app.needs_render = true;
            return;
        },
        .message => {},
    }
    if (!link.conns.contains(inc.conn)) return;
    // `API: off` in Settings after the link was made: it answers nothing.
    if (!app.cfg.api.enabled) return replyError(app, inc.conn, "null", api.err_not_permitted, "the API is off (Settings: API)");
    const arena = app.frame.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, inc.text, .{}) catch
        return replyError(app, inc.conn, "null", api.err_parse, "not JSON");
    const obj = switch (root) {
        .object => |o| o,
        else => return replyError(app, inc.conn, "null", api.err_invalid, "not a request object"),
    };
    const method = switch (obj.get("method") orelse .null) {
        .string => |m| m,
        // A reply to something mnml sent (it sends none that want one).
        else => return,
    };
    const params: std.json.Value = obj.get("params") orelse .null;
    // A notification (`notifications/initialized`, …) wants no answer.
    const id_val = obj.get("id") orelse return;
    const id_json = try std.json.Stringify.valueAlloc(arena, id_val, .{});
    return dispatch(app, inc.pane, inc.conn, id_json, method, params);
}

fn dispatch(app: *App, pane: PaneId, conn: u32, id_json: []const u8, method: []const u8, params: std.json.Value) Allocator.Error!void {
    if (std.mem.eql(u8, method, "initialize")) return initialize(app, pane, conn, id_json, params);
    if (std.mem.eql(u8, method, "ping")) return reply(app, conn, id_json, "{}");
    if (std.mem.eql(u8, method, "tools/list")) return reply(app, conn, id_json, tools_json);
    if (std.mem.eql(u8, method, "tools/call")) return toolsCall(app, pane, conn, id_json, params);
    // What Claude Code may probe for and mnml does not offer.
    if (std.mem.eql(u8, method, "prompts/list")) return reply(app, conn, id_json, "{\"prompts\":[]}");
    if (std.mem.eql(u8, method, "resources/list")) return reply(app, conn, id_json, "{\"resources\":[]}");
    return replyError(app, conn, id_json, api.err_method, "no such method");
}

fn initialize(app: *App, pane: PaneId, conn: u32, id_json: []const u8, params: std.json.Value) Allocator.Error!void {
    const link = app.ide.links.getPtr(pane) orelse return;
    try link.conns.put(app.gpa, conn, true);
    if (!link.greeted) {
        link.greeted = true;
        app.toast("Claude Code connected to mnml (pane {d})", .{pane});
    }
    app.needs_render = true;
    const arena = app.frame.allocator();
    var a: Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    w.writeAll("{\"protocolVersion\":") catch return error.OutOfMemory;
    try jstr(w, getStr(params, "protocolVersion") orelse mcp_version);
    w.writeAll(",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"" ++ ide_name ++ "\",\"version\":") catch return error.OutOfMemory;
    try jstr(w, @import("build_options").version);
    w.writeAll("}}") catch return error.OutOfMemory;
    try reply(app, conn, id_json, a.written());
}

fn getStr(params: std.json.Value, key: []const u8) ?[]const u8 {
    const o = switch (params) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(params: std.json.Value, key: []const u8) ?bool {
    const o = switch (params) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

// ─── the tools ──────────────────────────────────────────────────────────

pub const Tool = enum {
    openFile,
    openDiff,
    getCurrentSelection,
    getLatestSelection,
    getOpenEditors,
    getWorkspaceFolders,
    getDiagnostics,
    checkDocumentDirty,
    saveDocument,
    close_tab,
    closeAllDiffTabs,
    executeCode,
};

const no_args = "{\"type\":\"object\",\"properties\":{}}";

/// `tools/list`'s answer.
pub const tools_json = "{\"tools\":[" ++
    tool("openFile", "Open a file in mnml's editor, optionally selecting from startText to endText", "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"},\"preview\":{\"type\":\"boolean\"},\"startText\":{\"type\":\"string\"},\"endText\":{\"type\":\"string\"},\"selectToEndOfLine\":{\"type\":\"boolean\"},\"makeFrontmost\":{\"type\":\"boolean\"}},\"required\":[\"filePath\"]}") ++ "," ++
    tool("openDiff", "Show a proposed version of a file for the user to accept or reject; answers FILE_SAVED or DIFF_REJECTED", "{\"type\":\"object\",\"properties\":{\"old_file_path\":{\"type\":\"string\"},\"new_file_path\":{\"type\":\"string\"},\"new_file_contents\":{\"type\":\"string\"},\"tab_name\":{\"type\":\"string\"}},\"required\":[\"old_file_path\",\"new_file_path\",\"new_file_contents\",\"tab_name\"]}") ++ "," ++
    tool("getCurrentSelection", "The selection in mnml's active editor", no_args) ++ "," ++
    tool("getLatestSelection", "The most recent selection in any editor", no_args) ++ "," ++
    tool("getOpenEditors", "The editors open in mnml", no_args) ++ "," ++
    tool("getWorkspaceFolders", "mnml's workspace folders", no_args) ++ "," ++
    tool("getDiagnostics", "Language-server diagnostics, for one file (uri) or all", "{\"type\":\"object\",\"properties\":{\"uri\":{\"type\":\"string\"}}}") ++ "," ++
    tool("checkDocumentDirty", "Whether a file has unsaved changes in mnml", "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"}},\"required\":[\"filePath\"]}") ++ "," ++
    tool("saveDocument", "Save a file's buffer (asks the user)", "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"}},\"required\":[\"filePath\"]}") ++ "," ++
    tool("close_tab", "Close a tab by its name", "{\"type\":\"object\",\"properties\":{\"tab_name\":{\"type\":\"string\"}},\"required\":[\"tab_name\"]}") ++ "," ++
    tool("closeAllDiffTabs", "Close every diff tab", no_args) ++ "," ++
    tool("executeCode", "Not supported in mnml", "{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\"}},\"required\":[\"code\"]}") ++
    "]}";

fn tool(comptime name: []const u8, comptime desc: []const u8, comptime schema: []const u8) []const u8 {
    return "{\"name\":\"" ++ name ++ "\",\"description\":\"" ++ desc ++ "\",\"inputSchema\":" ++ schema ++ "}";
}

fn toolsCall(app: *App, pane: PaneId, conn: u32, id_json: []const u8, params: std.json.Value) Allocator.Error!void {
    const name = getStr(params, "name") orelse return replyError(app, conn, id_json, api.err_params, "tools/call needs a name");
    const args: std.json.Value = switch (params) {
        .object => |o| o.get("arguments") orelse .null,
        else => .null,
    };
    const caller: gate.Caller = .{ .pane = pane };
    const which = std.meta.stringToEnum(Tool, name) orelse {
        try gate.logApi(app, caller, .ide_tool, .view, name, true);
        return replyError(app, conn, id_json, api.err_params, "no such tool");
    };
    const arena = app.frame.allocator();
    switch (which) {
        // The one write: asks (or matches `.api`), audited by the gate.
        .saveDocument => {
            const path = getStr(args, "filePath") orelse return replyToolError(app, conn, id_json, "saveDocument needs a filePath");
            const abs = try app.absPath(path);
            switch (try gate.askIde(app, caller, conn, id_json, abs)) {
                .run => try saveAndReply(app, .{ .conn = conn, .id_json = @constCast(id_json), .ide = true }, abs),
                .refused => try replyToolError(app, conn, id_json, "not permitted"),
                .held => {},
            }
            return;
        },
        else => {},
    }
    // Everything else reads, or opens something to look at: run unasked,
    // on the audit trail all the same.
    const target = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ name, if (getStr(args, "filePath") orelse getStr(args, "new_file_path") orelse getStr(args, "uri")) |_| " " else "", getStr(args, "filePath") orelse getStr(args, "new_file_path") orelse getStr(args, "uri") orelse "" });
    try gate.logApi(app, caller, .ide_tool, .view, target, which == .executeCode);
    switch (which) {
        .saveDocument => unreachable,
        .executeCode => try replyToolError(app, conn, id_json, "executeCode is not supported in mnml"),
        .getWorkspaceFolders => try workspaceFolders(app, conn, id_json),
        .getOpenEditors => try openEditors(app, conn, id_json),
        .getCurrentSelection, .getLatestSelection => try currentSelection(app, conn, id_json),
        .getDiagnostics => try diagnostics(app, conn, id_json, args),
        .checkDocumentDirty => try documentDirty(app, conn, id_json, args),
        .openFile => try openFile(app, conn, id_json, args),
        .openDiff => try openDiff(app, pane, conn, id_json, args),
        .close_tab => try closeTab(app, conn, id_json, args),
        .closeAllDiffTabs => try closeAllDiffs(app, conn, id_json),
    }
}

fn fileUrl(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "file://{s}", .{path});
}

/// `file:///x` → `/x`; a plain path as it is.
fn pathOfUri(uri: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
}

fn workspaceFolders(app: *App, conn: u32, id_json: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    var a: Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    w.writeAll("{\"success\":true,\"folders\":[{\"name\":") catch return error.OutOfMemory;
    try jstr(w, std.fs.path.basename(app.workspace));
    w.writeAll(",\"uri\":") catch return error.OutOfMemory;
    try jstr(w, try fileUrl(arena, app.workspace));
    w.writeAll(",\"path\":") catch return error.OutOfMemory;
    try jstr(w, app.workspace);
    w.writeAll("}],\"rootPath\":") catch return error.OutOfMemory;
    try jstr(w, app.workspace);
    w.writeByte('}') catch return error.OutOfMemory;
    try replyTool(app, conn, id_json, &.{a.written()}, false);
}

fn openEditors(app: *App, conn: u32, id_json: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    var a: Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    w.writeAll("{\"tabs\":[") catch return error.OutOfMemory;
    var first = true;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| {
        const e = p.asEditor() orelse continue;
        const path = e.buf.doc.path orelse continue;
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        first = false;
        w.writeAll("{\"uri\":") catch return error.OutOfMemory;
        try jstr(w, try fileUrl(arena, path));
        w.print(",\"isActive\":{},\"label\":", .{app.active == @as(PaneId, @intCast(i))}) catch return error.OutOfMemory;
        try jstr(w, p.title());
        w.writeAll(",\"languageId\":") catch return error.OutOfMemory;
        try jstr(w, languageOf(path));
        w.print(",\"isDirty\":{}}}", .{p.dirty()}) catch return error.OutOfMemory;
    };
    w.writeAll("]}") catch return error.OutOfMemory;
    try replyTool(app, conn, id_json, &.{a.written()}, false);
}

fn languageOf(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    return if (ext.len > 1) ext[1..] else "plaintext";
}

/// The editor whose selection the session hears about: the active one,
/// else the one last active.
fn selectionEditor(app: *App) ?struct { id: PaneId, e: *app_mod.EditorPane } {
    if (app.active) |id| if (app.panes.editor(id)) |e| return .{ .id = id, .e = e };
    if (app.last_editor) |id| if (app.panes.editor(id)) |e| return .{ .id = id, .e = e };
    return null;
}

/// `{text, filePath, fileUrl, selection:{start, end, isEmpty}}`, lines
/// and characters 0-based. Null with no editor that has a file.
fn selectionJson(app: *App, with_success: bool) Allocator.Error!?[]const u8 {
    const se = selectionEditor(app) orelse return null;
    const ed = se.e.buf.editor;
    const path = se.e.buf.doc.path orelse return null;
    const arena = app.frame.allocator();
    const range = ed.selection() orelse [2]usize{ ed.cursor, ed.cursor };
    const s = ed.rowColAt(range[0]);
    const en = ed.rowColAt(range[1]);
    var a: Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    if (with_success) w.writeAll("\"success\":true,") catch return error.OutOfMemory;
    w.writeAll("\"text\":") catch return error.OutOfMemory;
    try jstr(w, ed.bytes()[range[0]..range[1]]);
    w.writeAll(",\"filePath\":") catch return error.OutOfMemory;
    try jstr(w, path);
    w.writeAll(",\"fileUrl\":") catch return error.OutOfMemory;
    try jstr(w, try fileUrl(arena, path));
    w.print(",\"selection\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}},\"isEmpty\":{}}}}}", .{ s.row, s.col, en.row, en.col, range[0] == range[1] }) catch return error.OutOfMemory;
    return a.written();
}

fn currentSelection(app: *App, conn: u32, id_json: []const u8) Allocator.Error!void {
    const json = try selectionJson(app, true) orelse "{\"success\":false,\"message\":\"no editor is open\"}";
    try replyTool(app, conn, id_json, &.{json}, false);
}

fn severityNumber(s: lsp_types.Severity) u8 {
    return @intFromEnum(s);
}

fn diagnosticsFor(app: *App, w: *Io.Writer, path: []const u8) Allocator.Error!void {
    w.writeAll("{\"uri\":") catch return error.OutOfMemory;
    try jstr(w, try fileUrl(app.frame.allocator(), path));
    w.writeAll(",\"diagnostics\":[") catch return error.OutOfMemory;
    for (lsp.diagnosticsFor(app, path), 0..) |d, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("{\"message\":") catch return error.OutOfMemory;
        try jstr(w, d.message);
        w.print(",\"severity\":{d},\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}", .{ severityNumber(d.severity), d.range.start.line, d.range.start.character, d.range.end.line, d.range.end.character }) catch return error.OutOfMemory;
        w.writeAll(",\"source\":") catch return error.OutOfMemory;
        try jstr(w, d.source orelse "");
        w.writeByte('}') catch return error.OutOfMemory;
    }
    w.writeAll("]}") catch return error.OutOfMemory;
}

fn diagnostics(app: *App, conn: u32, id_json: []const u8, args: std.json.Value) Allocator.Error!void {
    const arena = app.frame.allocator();
    var a: Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    w.writeByte('[') catch return error.OutOfMemory;
    if (getStr(args, "uri")) |uri| {
        try diagnosticsFor(app, w, try app.absPath(pathOfUri(uri)));
    } else {
        var first = true;
        var it = app.lsp.diags.keyIterator();
        while (it.next()) |path| {
            if (lsp.diagnosticsFor(app, path.*).len == 0) continue;
            if (!first) w.writeByte(',') catch return error.OutOfMemory;
            first = false;
            try diagnosticsFor(app, w, path.*);
        }
    }
    w.writeByte(']') catch return error.OutOfMemory;
    try replyTool(app, conn, id_json, &.{a.written()}, false);
}

fn documentDirty(app: *App, conn: u32, id_json: []const u8, args: std.json.Value) Allocator.Error!void {
    const path = getStr(args, "filePath") orelse return replyToolError(app, conn, id_json, "checkDocumentDirty needs a filePath");
    const abs = try app.absPath(path);
    const arena = app.frame.allocator();
    var a: Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    const id = app.panes.findPath(abs) orelse {
        w.writeAll("{\"success\":false,\"message\":\"not open: ") catch return error.OutOfMemory;
        w.writeAll(abs) catch return error.OutOfMemory;
        w.writeAll("\"}") catch return error.OutOfMemory;
        return replyTool(app, conn, id_json, &.{try std.fmt.allocPrint(arena, "{{\"success\":false,\"message\":{f}}}", .{std.json.fmt(try std.fmt.allocPrint(arena, "not open: {s}", .{abs}), .{})})}, false);
    };
    const p = app.panes.get(id).?;
    w.writeAll("{\"success\":true,\"filePath\":") catch return error.OutOfMemory;
    try jstr(w, abs);
    w.print(",\"isDirty\":{},\"isUntitled\":false}}", .{p.dirty()}) catch return error.OutOfMemory;
    try replyTool(app, conn, id_json, &.{a.written()}, false);
}

/// `saveDocument` once allowed (now, or when the person says yes).
pub fn saveAndReply(app: *App, a: gate.ApiReply, path: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const id = app.panes.findPath(path) orelse
        return replyTool(app, a.conn, a.id_json, &.{try std.fmt.allocPrint(arena, "{{\"success\":false,\"filePath\":{f},\"saved\":false,\"message\":\"not open in mnml\"}}", .{std.json.fmt(path, .{})})}, false);
    const e = app.panes.editor(id).?;
    app.diag.clear();
    cmd_file.savePane(app, id, e, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const why = app.diag.msg orelse @errorName(err);
            return replyTool(app, a.conn, a.id_json, &.{try std.fmt.allocPrint(arena, "{{\"success\":false,\"filePath\":{f},\"saved\":false,\"message\":{f}}}", .{ std.json.fmt(path, .{}), std.json.fmt(why, .{}) })}, false);
        },
    };
    app.needs_render = true;
    try replyTool(app, a.conn, a.id_json, &.{try std.fmt.allocPrint(arena, "{{\"success\":true,\"filePath\":{f},\"saved\":true,\"message\":\"saved\"}}", .{std.json.fmt(path, .{})})}, false);
}

fn openFile(app: *App, conn: u32, id_json: []const u8, args: std.json.Value) Allocator.Error!void {
    const path = getStr(args, "filePath") orelse return replyToolError(app, conn, id_json, "openFile needs a filePath");
    const abs = try app.absPath(path);
    const id = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return replyToolError(app, conn, id_json, @errorName(err)),
    };
    if (app.panes.editor(id)) |e| if (getStr(args, "startText")) |start_text| {
        const ed = e.buf.editor;
        if (std.mem.indexOf(u8, ed.bytes(), start_text)) |s| {
            var end = s + start_text.len;
            if (getStr(args, "endText")) |end_text| {
                if (std.mem.indexOfPos(u8, ed.bytes(), end, end_text)) |at| end = at + end_text.len;
            }
            if (getBool(args, "selectToEndOfLine") orelse false) end = ed.lineEnd(ed.lineOfByte(end));
            ed.anchor = s;
            ed.cursor = end;
            e.view.scroll_line = @intCast(ed.currentLine() -| app.pane_rows / 2);
        }
    };
    app.needs_render = true;
    const arena = app.frame.allocator();
    if (getBool(args, "makeFrontmost") orelse true) {
        return replyTool(app, conn, id_json, &.{try std.fmt.allocPrint(arena, "Opened file: {s}", .{abs})}, false);
    }
    const lines: usize = if (app.panes.editor(id)) |e| e.buf.editor.lineCount() else 0;
    try replyTool(app, conn, id_json, &.{try std.fmt.allocPrint(arena, "{{\"success\":true,\"filePath\":{f},\"languageId\":{f},\"lineCount\":{d}}}", .{ std.json.fmt(abs, .{}), std.json.fmt(languageOf(abs), .{}), lines })}, false);
}

// ─── openDiff ───────────────────────────────────────────────────────────

/// An `openDiff` under review: who asked, and where the answer goes.
pub const Diff = struct {
    session: PaneId,
    conn: u32,
    /// The request's id, as JSON. On the pane's arena.
    id_json: []u8,
    /// The tab's title (the session's `tab_name`), on the pane's arena.
    tab_name: []const u8,
    /// Set by an accept just before the pane closes.
    accepted: bool = false,
};

pub const diff_saved = "FILE_SAVED";
pub const diff_rejected = "DIFF_REJECTED";

fn openDiff(app: *App, session: PaneId, conn: u32, id_json: []const u8, args: std.json.Value) Allocator.Error!void {
    const path = getStr(args, "new_file_path") orelse getStr(args, "old_file_path") orelse
        return replyToolError(app, conn, id_json, "openDiff needs new_file_path");
    const contents = getStr(args, "new_file_contents") orelse return replyToolError(app, conn, id_json, "openDiff needs new_file_contents");
    const tab_name = getStr(args, "tab_name") orelse std.fs.path.basename(path);
    const abs = try app.absPath(path);
    // The proposal is diffed against the buffer as it stands — unsaved
    // edits included — so the file is opened when it is not.
    const target = app.panes.findPath(abs) orelse (app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return replyToolError(app, conn, id_json, @errorName(err)),
    });
    const e = app.panes.editor(target) orelse return replyToolError(app, conn, id_json, "not a text file");
    // A second proposal for the same file supersedes the first.
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .ai_apply => |*ap| if (ap.ide != null and ap.anchor.pane == target) {
            try app.forceClosePane(@intCast(i));
        },
        else => {},
    };
    const bytes = e.buf.editor.bytes();
    var pane = try ai_apply.build(app.gpa, ai_apply.Anchor.take(target, e.buf.doc, 0, bytes.len), null, app.relPath(abs), bytes, contents);
    errdefer pane.deinit();
    const pa = pane.arena.allocator();
    pane.ide = .{ .session = session, .conn = conn, .id_json = try pa.dupe(u8, id_json), .tab_name = try pa.dupe(u8, tab_name) };
    const id = try app.panes.add(.{ .ai_apply = pane });
    app.showPane(id);
    app.needs_render = true;
    // Answered when the review closes (`forgetPane` → `answerDiff`).
}

/// The review pane is closing: tell the session what became of it.
fn answerDiff(app: *App, d: Diff, ap: *ai_apply.AiApplyPane) Allocator.Error!void {
    if (!d.accepted) return replyTool(app, d.conn, d.id_json, &.{diff_rejected}, false);
    const final: []const u8 = if (app.panes.editor(ap.anchor.pane)) |e| e.buf.editor.bytes() else "";
    try replyTool(app, d.conn, d.id_json, &.{ diff_saved, final }, false);
}

/// The toast an accepted `openDiff` raises: saved, as the session was told.
pub fn acceptedToast(app: *App, n: usize, total: usize) void {
    app.toast("applied {d} of {d} hunk{s} from Claude Code and saved", .{ n, total, if (total == 1) "" else "s" });
}

fn closeTab(app: *App, conn: u32, id_json: []const u8, args: std.json.Value) Allocator.Error!void {
    const name = getStr(args, "tab_name") orelse return replyToolError(app, conn, id_json, "close_tab needs a tab_name");
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .ai_apply => |*ap| if (ap.ide) |d| if (std.mem.eql(u8, d.tab_name, name)) {
            try app.forceClosePane(@intCast(i));
            break;
        },
        else => {},
    };
    try replyTool(app, conn, id_json, &.{"TAB_CLOSED"}, false);
}

fn closeAllDiffs(app: *App, conn: u32, id_json: []const u8) Allocator.Error!void {
    var n: usize = 0;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*p| switch (p.*) {
        .ai_apply => |*ap| if (ap.ide != null) {
            try app.forceClosePane(@intCast(i));
            n += 1;
        },
        else => {},
    };
    try replyTool(app, conn, id_json, &.{try std.fmt.allocPrint(app.frame.allocator(), "CLOSED_{d}_DIFF_TABS", .{n})}, false);
}

// ─── notifications ──────────────────────────────────────────────────────

/// The session pane you are pointing at: of the panes you have looked
/// at, the most recent whose link is up.
pub fn pointed(app: *const App) ?PaneId {
    for (app.pane_mru.items) |id| if (linked(app, id)) return id;
    return null;
}

fn anyUp(app: *const App) bool {
    var it = app.ide.links.valueIterator();
    while (it.next()) |l| if (l.up()) return true;
    return false;
}

fn notify(app: *App, pane: PaneId, method: []const u8, params_json: []const u8) Allocator.Error!void {
    const l = app.ide.links.getPtr(pane) orelse return;
    const line = try std.fmt.allocPrint(app.frame.allocator(), "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{ method, params_json });
    var it = l.conns.iterator();
    while (it.next()) |e| if (e.value_ptr.*) try send(app, pane, e.key_ptr.*, line);
}

fn currentSel(app: *App) Sel {
    const se = selectionEditor(app) orelse return .{};
    const ed = se.e.buf.editor;
    return .{ .pane = se.id, .doc = se.e.buf.doc, .seq = se.e.buf.doc.edits.head(), .cursor = ed.cursor, .anchor = ed.anchor };
}

/// Every frame: a selection change is told to the pointed session, at
/// most once per `selection_throttle_ms`. Nothing happens with no link up.
pub fn tick(app: *App, now: i64) Allocator.Error!void {
    if (app.ide.links.count() == 0 or !anyUp(app)) return;
    const sel = currentSel(app);
    if (!sel.eql(app.ide.sel_seen)) {
        app.ide.sel_seen = sel;
        app.ide.sel_pending = sel.pane != null;
    }
    if (!app.ide.sel_pending or now - app.ide.sel_sent_ms < selection_throttle_ms) return;
    app.ide.sel_pending = false;
    const to = pointed(app) orelse return;
    const json = try selectionJson(app, false) orelse return;
    app.ide.sel_sent_ms = now;
    try notify(app, to, "selection_changed", json);
}

/// When `tick` next has a selection to tell.
pub fn nextDeadlineMs(app: *const App) ?i64 {
    if (!app.ide.sel_pending) return null;
    return app.ide.sel_sent_ms + selection_throttle_ms;
}

/// `ai.send_selection`: point the session you looked at last at the
/// active editor's file and selected lines (the cursor's line with none).
pub fn sendSelectionCmd(app: *App) CommandError!void {
    const arena = app.frame.allocator();
    const se = selectionEditor(app) orelse return error.NotAnEditor;
    const path = se.e.buf.doc.path orelse return app.diag.fail(arena, "this buffer has no file to point a session at", .{});
    const to = pointed(app) orelse return app.diag.fail(arena, "no Claude Code session is linked to mnml — start one in a pane", .{});
    const ed = se.e.buf.editor;
    const range = ed.selection() orelse [2]usize{ ed.cursor, ed.cursor };
    const first = ed.lineOfByte(range[0]);
    const last = ed.lineOfByte(range[1]);
    const params = try std.fmt.allocPrint(arena, "{{\"filePath\":{f},\"lineStart\":{d},\"lineEnd\":{d}}}", .{ std.json.fmt(path, .{}), first, last });
    try notify(app, to, "at_mentioned", params);
    app.toast("sent {s}:{d}-{d} to pane {d}", .{ app.relPath(path), first + 1, last + 1, to });
}

pub const table = .{
    .@"ai.send_selection" = &sendSelectionCmd,
};

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Fx = struct {
    app: App,
    tmp: std.testing.TmpDir,
    dir: [:0]u8,

    fn init(fx: *Fx) !void {
        fx.app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
        fx.app.api.socket = "/test/1.sock";
        fx.tmp = t.tmpDir(.{});
        fx.dir = try fx.tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
        fx.app.ide.lock_dir_override = fx.dir;
    }

    fn deinit(fx: *Fx) void {
        fx.app.deinit();
        t.allocator.free(fx.dir);
        fx.tmp.cleanup();
    }

    /// A session pane's link with no listener: its messages land in
    /// `unsent`. Connection `conn`, initialized.
    fn link(fx: *Fx, pane: PaneId, conn: u32) !void {
        const gop = try fx.app.ide.links.getOrPut(t.allocator, pane);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.conns.put(t.allocator, conn, false);
        try fx.feed(pane, conn, "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}");
    }

    fn feed(fx: *Fx, pane: PaneId, conn: u32, text: []const u8) !void {
        const inc = try t.allocator.create(server.Incoming);
        inc.* = .{ .pane = pane, .conn = conn, .text = try t.allocator.dupe(u8, text) };
        try handle(&fx.app, inc);
    }

    fn call(fx: *Fx, pane: PaneId, conn: u32, id: u32, name: []const u8, args: []const u8) !void {
        const line = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ id, name, args });
        defer t.allocator.free(line);
        try fx.feed(pane, conn, line);
    }

    fn last(fx: *Fx, conn: u32) ?[]const u8 {
        var i = fx.app.ide.unsent.items.len;
        while (i > 0) {
            i -= 1;
            if (fx.app.ide.unsent.items[i].conn == conn) return fx.app.ide.unsent.items[i].line;
        }
        return null;
    }

    fn has(fx: *Fx, conn: u32, needle: []const u8) bool {
        const l = fx.last(conn) orelse return false;
        return std.mem.indexOf(u8, l, needle) != null;
    }

    fn count(fx: *Fx, conn: u32, needle: []const u8) usize {
        var n: usize = 0;
        for (fx.app.ide.unsent.items) |u| if (u.conn == conn and std.mem.indexOf(u8, u.line, needle) != null) {
            n += 1;
        };
        return n;
    }

    fn file(fx: *Fx, name: []const u8, data: []const u8) ![]u8 {
        const p = try std.fs.path.join(t.allocator, &.{ fx.app.workspace, name });
        try Io.Dir.cwd().writeFile(t.io, .{ .sub_path = p, .data = data });
        return p;
    }

    /// A dormant terminal pane running `argv` (nothing is spawned).
    fn pty(fx: *Fx, argv: []const []const u8) !PaneId {
        return @import("pty_pane.zig").open(&fx.app, .{ .argv = argv, .label = "s", .kind = .command, .placement = .tab, .dormant = true });
    }

    fn audited(fx: *Fx, needle: []const u8) bool {
        for (fx.app.ipc_gate.audit.items) |l| if (std.mem.indexOf(u8, l, needle) != null) return true;
        return false;
    }
};

test "the lock file names the port's listener: pid, workspace, ideName mnml, ws, the token — 0600, and gone when the pane closes" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    const pid = try fx.pty(&.{"claude"});
    const port = (try startFor(app, pid)).?;
    const link = app.ide.links.getPtr(pid).?;
    try t.expectEqual(port, link.port);
    var name_buf: [32]u8 = undefined;
    try t.expectEqualStrings(try std.fmt.bufPrint(&name_buf, "{d}.lock", .{port}), std.fs.path.basename(link.lock_path));
    const text = try Io.Dir.cwd().readFileAlloc(t.io, link.lock_path, t.allocator, .limited(4096));
    defer t.allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, text, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try t.expectEqual(api_paths.selfPid(), o.get("pid").?.integer);
    try t.expectEqualStrings(app.workspace, o.get("workspaceFolders").?.array.items[0].string);
    try t.expectEqualStrings("mnml", o.get("ideName").?.string);
    try t.expectEqualStrings("ws", o.get("transport").?.string);
    try t.expectEqualSlices(u8, &link.listener.?.token, o.get("authToken").?.string);
    if (builtin.os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(t.io, link.lock_path, .{});
        try t.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
    const lock = try t.allocator.dupe(u8, link.lock_path);
    defer t.allocator.free(lock);
    try app.forceClosePane(pid);
    try t.expect(app.ide.links.get(pid) == null);
    try t.expectError(error.FileNotFound, Io.Dir.cwd().statFile(t.io, lock, .{}));
}

test "only a Claude Code pane gets the agent face, and only while the API serves" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    const claude = try fx.pty(&.{"claude"});
    const codex = try fx.pty(&.{"codex"});
    const shell = try fx.pty(&.{"/bin/zsh"});
    var env = try @import("pty_env.zig").build(app, claude, &.{}, null);
    defer env.deinit();
    const port = env.get(env_port).?;
    try t.expectEqualStrings("true", env.get(env_enable).?);
    try t.expectEqual(app.ide.links.get(claude).?.port, try std.fmt.parseInt(u16, port, 10));
    for ([_]PaneId{ codex, shell }) |id| {
        var e = try @import("pty_env.zig").build(app, id, &.{}, null);
        defer e.deinit();
        try t.expect(e.get(env_port) == null and e.get(env_enable) == null);
        try t.expect(app.ide.links.get(id) == null);
    }
    // The API off: no port, no lock.
    app.cfg.api.enabled = false;
    stopFor(app, claude);
    var off = try @import("pty_env.zig").build(app, claude, &.{}, null);
    defer off.deinit();
    try t.expect(off.get(env_port) == null);
    try t.expect(app.ide.links.get(claude) == null);
}

test "initialize names mnml, tools/list offers the protocol's tools, and the first connect is toasted once" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    try fx.link(3, 900);
    try t.expect(fx.has(900, "\"serverInfo\":{\"name\":\"mnml\""));
    try t.expect(fx.has(900, "\"protocolVersion\":\"2025-06-18\""));
    try t.expect(linked(app, 3));
    try fx.feed(3, 900, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try fx.feed(3, 900, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
    for (std.enums.values(Tool)) |tl| {
        const needle = try std.fmt.allocPrint(app.frame.allocator(), "\"name\":\"{s}\"", .{@tagName(tl)});
        try t.expect(fx.has(900, needle));
    }
    var toasts: usize = 0;
    for (app.toasts.items) |ts| if (std.mem.indexOf(u8, ts.text, "Claude Code connected to mnml (pane 3)") != null) {
        toasts += 1;
    };
    try t.expectEqual(@as(usize, 1), toasts);
    // Once the toast has gone, a second connection raises no other.
    try app.tick(app.now_ms + 3_600_000);
    try fx.link(3, 901);
    toasts = 0;
    for (app.toasts.items) |ts| if (std.mem.indexOf(u8, ts.text, "Claude Code connected") != null) {
        toasts += 1;
    };
    try t.expectEqual(@as(usize, 0), toasts);
}

test "each read tool runs unasked as pane:<id>, on the audit trail; executeCode is refused" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    const path = try fx.file("auth.zig", "one\ntwo\nthree\n");
    defer t.allocator.free(path);
    try fx.link(6, 900);
    const ed_id = try app.openPath(path);
    const ed = app.panes.editor(ed_id).?.buf.editor;
    ed.anchor = 4;
    ed.cursor = 7;

    try fx.call(6, 900, 1, "getWorkspaceFolders", "{}");
    try t.expect(fx.has(900, "rootPath"));
    try fx.call(6, 900, 2, "getOpenEditors", "{}");
    try t.expect(fx.has(900, "auth.zig") and fx.has(900, "isDirty"));
    try fx.call(6, 900, 3, "getCurrentSelection", "{}");
    try t.expect(fx.has(900, "\\\"text\\\":\\\"two\\\""));
    try t.expect(fx.has(900, "\\\"start\\\":{\\\"line\\\":1,\\\"character\\\":0}"));
    try fx.call(6, 900, 4, "getDiagnostics", "{}");
    try t.expect(fx.has(900, "\"id\":4,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[]\"}]}"));
    try fx.call(6, 900, 5, "checkDocumentDirty", try std.fmt.allocPrint(app.frame.allocator(), "{{\"filePath\":\"{s}\"}}", .{path}));
    try t.expect(fx.has(900, "\\\"isDirty\\\":false"));
    try fx.call(6, 900, 6, "openFile", "{\"filePath\":\"auth.zig\",\"startText\":\"three\"}");
    try t.expect(fx.has(900, "Opened file:"));
    try t.expectEqualStrings("three", ed.selectedText());
    try fx.call(6, 900, 7, "executeCode", "{\"code\":\"1\"}");
    try t.expect(fx.has(900, "\"id\":7") and fx.has(900, "not supported") and fx.has(900, "\"isError\":true"));
    try t.expectEqual(@as(usize, 0), app.ipc_gate.pending.items.len);
    try t.expect(fx.audited("\"client\":\"pane:6\",\"method\":\"ide\",\"target\":\"getDiagnostics\",\"class\":\"view\",\"decision\":\"free\""));
    try t.expect(fx.audited("\"client\":\"pane:6\",\"method\":\"ide\",\"target\":\"executeCode\",\"class\":\"view\",\"decision\":\"denied\""));
}

test "saveDocument is write: it asks as pane:<id>, saves on yes, and answers no on no" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    const path = try fx.file("w.txt", "a\n");
    defer t.allocator.free(path);
    try fx.link(6, 900);
    const id = try app.openPath(path);
    try app.splice(app.panes.editor(id).?, 0, 0, "b");
    const args = try std.fmt.allocPrint(t.allocator, "{{\"filePath\":\"{s}\"}}", .{path});
    defer t.allocator.free(args);

    const before = app.ide.unsent.items.len;
    try fx.call(6, 900, 1, "saveDocument", args);
    try t.expectEqual(before, app.ide.unsent.items.len);
    try t.expectEqual(@as(usize, 1), app.ipc_gate.pending.items.len);
    const ask = try gate.askTextFor(app.frame.allocator(), app.ipc_gate.pending.items[0], "claude");
    try t.expect(std.mem.startsWith(u8, ask, "pane 6 · claude asks to save "));
    try gate.answer(app, app.ipc_gate.pending.items[0].id, 0);
    try t.expect(fx.has(900, "\\\"saved\\\":true"));
    const on_disk = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(64));
    defer t.allocator.free(on_disk);
    try t.expectEqualStrings("ba\n", on_disk);

    try fx.call(6, 900, 2, "saveDocument", args);
    try gate.answer(app, app.ipc_gate.pending.items[0].id, 2);
    try t.expect(fx.has(900, "\"id\":2") and fx.has(900, "the user said no") and fx.has(900, "\"isError\":true"));
    try t.expect(fx.audited("\"client\":\"pane:6\",\"method\":\"saveDocument\""));
}

test "openDiff shows the review; accept saves the file and answers FILE_SAVED with the text, reject answers DIFF_REJECTED" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    const path = try fx.file("d.txt", "one\ntwo\n");
    defer t.allocator.free(path);
    try fx.link(6, 900);
    const args = try std.fmt.allocPrint(t.allocator, "{{\"old_file_path\":\"{s}\",\"new_file_path\":\"{s}\",\"new_file_contents\":\"one\\nTWO\\n\",\"tab_name\":\"d.txt (claude)\"}}", .{ path, path });
    defer t.allocator.free(args);

    const before = app.ide.unsent.items.len;
    try fx.call(6, 900, 1, "openDiff", args);
    // Blocks: nothing answered while the review is up.
    try t.expectEqual(before, app.ide.unsent.items.len);
    const rid = app.active.?;
    const ap = &app.panes.get(rid).?.ai_apply;
    try t.expectEqualStrings("d.txt (claude)", app.panes.get(rid).?.title());
    for (ap.hunks) |*h| h.accepted = true;
    _ = try ai_apply.handleKey(app, rid, ap, .{ .code = .enter });
    try t.expect(fx.has(900, "\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"FILE_SAVED\"},{\"type\":\"text\",\"text\":\"one\\nTWO\\n\"}]}"));
    const ed = app.panes.get(app.panes.findPath(path).?).?;
    // Saved to disk before the reply: the session's next read sees it.
    try t.expect(!ed.dirty());
    const on_disk = try Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(64));
    defer t.allocator.free(on_disk);
    try t.expectEqualStrings("one\nTWO\n", on_disk);
    var said = false;
    for (app.toasts.items) |ts| said = said or std.mem.indexOf(u8, ts.text, "and saved") != null;
    try t.expect(said);

    try fx.call(6, 900, 2, "openDiff", args);
    const rid2 = app.active.?;
    _ = try ai_apply.handleKey(app, rid2, &app.panes.get(rid2).?.ai_apply, .{ .code = .esc });
    try t.expect(fx.has(900, "\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"DIFF_REJECTED\"}]}"));
    try t.expect(fx.audited("\"client\":\"pane:6\",\"method\":\"ide\",\"target\":\"openDiff "));
}

test "selection_changed goes only to the pointed session, at most once per 100 ms; ai.send_selection sends at_mentioned" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const app = &fx.app;
    const path = try fx.file("s.txt", "alpha\nbeta\ngamma\n");
    defer t.allocator.free(path);
    // Two sessions, both linked; pane 8 was looked at last.
    try fx.link(7, 700);
    try fx.link(8, 800);
    const ed_id = try app.openPath(path);
    try app.pane_mru.insert(t.allocator, 1, 7);
    try app.pane_mru.insert(t.allocator, 1, 8);
    try t.expectEqual(@as(?PaneId, 8), pointed(app));
    const ed = app.panes.editor(ed_id).?.buf.editor;

    try tick(app, 1000);
    try t.expectEqual(@as(usize, 1), fx.count(800, "selection_changed"));
    // Moves inside the window are held, then the latest one is told.
    ed.cursor = 6;
    try tick(app, 1030);
    ed.cursor = 7;
    try tick(app, 1060);
    try t.expectEqual(@as(usize, 1), fx.count(800, "selection_changed"));
    try t.expectEqual(@as(?i64, 1100), nextDeadlineMs(app));
    try tick(app, 1100);
    try t.expectEqual(@as(usize, 2), fx.count(800, "selection_changed"));
    try t.expect(fx.has(800, "\"character\":1"));
    // No change, nothing more.
    try tick(app, 1500);
    try t.expectEqual(@as(usize, 2), fx.count(800, "selection_changed"));
    try t.expectEqual(@as(usize, 0), fx.count(700, "selection_changed"));

    ed.anchor = 0;
    ed.cursor = 8;
    try sendSelectionCmd(app);
    try t.expect(fx.has(800, "\"method\":\"at_mentioned\",\"params\":{\"filePath\":"));
    try t.expect(fx.has(800, "\"lineStart\":0,\"lineEnd\":1"));
    try t.expectEqual(@as(usize, 0), fx.count(700, "at_mentioned"));
}
