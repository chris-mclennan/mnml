//! The API socket, the App's side (`docs/research/api-design.md` §3,
//! §5.2, §9 phase 1). `api/server.zig` reads a line off a connection and
//! posts it; `handle` answers it here, between frames, like an IPC line.
//!
//! Phase 1's methods: `initialize`, `ping`, `editor.open`,
//! `commands.list`, `commands.run`, `state.status`, `layout.panes`.
//! Each goes through the file channel's gate (`ipc_gate.zig`) with the
//! connection's identity: a pane's (`pane:<id>`, by the `MNML_API_TOKEN`
//! minted into its environment at spawn) or `unknown`, which may only
//! read — `state.*` and `commands.list`. `commands.run` of a command above
//! `view` from a pane asks the person (or matches `.api`), and the
//! connection waits for the answer; a grant for `pane:<id>` lasts while
//! the pane lives.
//!
//! A token is 128 random bits, kept only here and in the child's
//! environment, dropped when the pane closes; a pane restarted is a new
//! spawn and gets a new one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("../app.zig");
const App = app_mod.App;
const PaneId = app_mod.PaneId;
const command = @import("../core/command.zig");
const Effect = command.Effect;
const gate = @import("ipc_gate.zig");
const server_mod = @import("../api/server.zig");
const paths = @import("../api/paths.zig");
const screen_mod = @import("../ipc/screen.zig");
const app_driver = @import("driver.zig");

/// What `initialize` answers: this protocol, version 1 (additive only).
pub const version = "v1";
pub const protocol = "mnml/1";

pub const err_parse: i32 = -32700;
pub const err_invalid: i32 = -32600;
pub const err_method: i32 = -32601;
pub const err_params: i32 = -32602;
/// The method ran and failed.
pub const err_failed: i32 = -32000;
pub const err_not_permitted: i32 = -32001;
pub const err_denied: i32 = -32002;
pub const err_no_such: i32 = -32003;

const not_permitted_unknown = "not permitted: a client with no token may only read (state.*, commands.list)";

pub const token_len = 32;
pub const Token = [token_len]u8;

pub const State = struct {
    /// The listener, while the loop serves one (`tui/loop.zig`).
    server: ?*server_mod.Server = null,
    /// The socket path pane children are told; borrowed from the server
    /// (a test sets it to a literal).
    socket: []const u8 = "",
    /// Each live pane's token.
    tokens: std.AutoHashMapUnmanaged(PaneId, Token) = .empty,
    /// What each pane was allowed "for the session" (`ipc_gate.zig`).
    grants: std.AutoHashMapUnmanaged(PaneId, std.EnumSet(Effect)) = .empty,
    /// Who each `initialize`d connection is.
    conns: std.AutoHashMapUnmanaged(u32, gate.Caller) = .empty,
    /// Replies with no server to carry them — a test reads these.
    unsent: std.ArrayListUnmanaged(Unsent) = .empty,

    pub const Unsent = struct { conn: u32, line: []u8 };

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.tokens.deinit(gpa);
        s.grants.deinit(gpa);
        s.conns.deinit(gpa);
        for (s.unsent.items) |u| gpa.free(u.line);
        s.unsent.deinit(gpa);
    }
};

/// Whether pane children are told about the API.
pub fn serving(app: *const App) bool {
    return app.cfg.api.enabled and app.api.socket.len > 0;
}

/// Mint pane `id`'s token (a restart re-mints), for its environment.
/// Null while nothing serves.
pub fn mintToken(app: *App, id: PaneId) Allocator.Error!?Token {
    if (!serving(app)) return null;
    var raw: [token_len / 2]u8 = undefined;
    app.io.randomSecure(&raw) catch app.io.random(&raw);
    const tok = std.fmt.bytesToHex(raw, .lower);
    try app.api.tokens.put(app.gpa, id, tok);
    return tok;
}

/// Pane `id` closed: its token, its grants and what it was waiting on go.
/// A connection that presented its token is `unknown` from now on.
pub fn forgetPane(app: *App, id: PaneId) void {
    _ = app.api.tokens.remove(id);
    _ = app.api.grants.remove(id);
    var it = app.api.conns.iterator();
    while (it.next()) |e| if (e.value_ptr.eql(.{ .pane = id })) {
        e.value_ptr.* = .unknown;
    };
    gate.dropCaller(app, .{ .pane = id }) catch {};
}

fn identify(app: *const App, token: []const u8) gate.Caller {
    if (token.len != token_len) return .unknown;
    var it = app.api.tokens.iterator();
    while (it.next()) |e| {
        // Every byte compared, whatever matches first.
        var diff: u8 = 0;
        for (e.value_ptr.*, token) |a, b| diff |= a ^ b;
        if (diff == 0) return .{ .pane = e.key_ptr.* };
    }
    return .unknown;
}

// ─── replies ────────────────────────────────────────────────────────────

fn send(app: *App, conn: u32, line: []const u8) Allocator.Error!void {
    // Connection 0 is a notification's: nothing is written.
    if (conn == 0) return;
    if (app.api.server) |s| return s.reply(conn, line);
    try app.api.unsent.append(app.gpa, .{ .conn = conn, .line = try app.gpa.dupe(u8, line) });
}

/// `{"jsonrpc":"2.0","id":…,"result":…}` with `result_json` verbatim.
pub fn replyResult(app: *App, conn: u32, id_json: []const u8, result_json: []const u8) Allocator.Error!void {
    const line = try std.fmt.allocPrint(app.frame.allocator(), "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result_json });
    try send(app, conn, line);
}

pub fn replyError(app: *App, conn: u32, id_json: []const u8, code: i32, message: []const u8) Allocator.Error!void {
    var a: std.Io.Writer.Allocating = .init(app.frame.allocator());
    const w = &a.writer;
    w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":", .{ id_json, code }) catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(message, .{}, w) catch return error.OutOfMemory;
    w.writeAll("}}") catch return error.OutOfMemory;
    try send(app, conn, a.written());
}

/// Run `ref` and answer `{ok:true}` or the reason it failed — the gate's
/// release of a held `commands.run`, and the unheld path alike.
pub fn runAndReply(app: *App, conn: u32, id_json: []const u8, ref: command.CommandRef) Allocator.Error!void {
    app.diag.clear();
    command.run(app, ref) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const why = if (err == error.Failed) (app.diag.msg orelse command.reason(err)) else command.reason(err);
            return replyError(app, conn, id_json, err_failed, why);
        },
    };
    app.needs_render = true;
    try replyResult(app, conn, id_json, "{\"ok\":true}");
}

// ─── the dispatcher ─────────────────────────────────────────────────────

/// One `.api` event: a request line, or a connection's end.
pub fn handle(app: *App, inc: *server_mod.Incoming) Allocator.Error!void {
    defer inc.destroy(app.gpa);
    if (inc.closed) {
        _ = app.api.conns.remove(inc.conn);
        try gate.dropConn(app, inc.conn);
        return;
    }
    const arena = app.frame.allocator();
    // `API: off` in Settings: the socket stays bound until a restart,
    // but answers nothing but that.
    if (!app.cfg.api.enabled) return replyError(app, inc.conn, "null", err_not_permitted, "the API is off (Settings: API)");
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, inc.line, .{}) catch
        return replyError(app, inc.conn, "null", err_parse, "not JSON");
    const obj = switch (root) {
        .object => |o| o,
        else => return replyError(app, inc.conn, "null", err_invalid, "not a request object"),
    };
    // A notification (no id) is answered with nothing: its replies go to
    // connection 0, which writes nothing, and an empty line releases the
    // reader waiting on it.
    const id_val = obj.get("id");
    const id_json = if (id_val) |v| try std.json.Stringify.valueAlloc(arena, v, .{}) else "null";
    if (id_val == null) if (app.api.server) |s| try s.reply(inc.conn, "");
    const conn: u32 = if (id_val == null) 0 else inc.conn;
    const method = switch (obj.get("method") orelse .null) {
        .string => |m| m,
        else => return replyError(app, conn, id_json, err_invalid, "no method"),
    };
    const params: std.json.Value = obj.get("params") orelse .null;
    return dispatch(app, inc.conn, conn, id_json, method, params);
}

/// `who` is the connection the request came in on (its identity);
/// `conn` the one its answer goes to (0 for a notification).
fn dispatch(app: *App, who: u32, conn: u32, id_json: []const u8, method: []const u8, params: std.json.Value) Allocator.Error!void {
    if (std.mem.eql(u8, method, "initialize")) return initialize(app, who, conn, id_json, params);
    const caller = app.api.conns.get(who) orelse
        return replyError(app, conn, id_json, err_invalid, "initialize first");
    if (std.mem.eql(u8, method, "ping")) return replyResult(app, conn, id_json, "\"pong\"");
    if (std.mem.eql(u8, method, "state.status")) {
        try gate.logApi(app, caller, .api_read, .view, method, false);
        return stateStatus(app, conn, id_json);
    }
    if (std.mem.eql(u8, method, "layout.panes")) {
        // What is open is a pane's to ask; a caller with no token reads
        // only `state.*` and `commands.list`.
        try gate.logApi(app, caller, .api_read, .view, method, caller == .unknown);
        if (caller == .unknown) return replyError(app, conn, id_json, err_not_permitted, not_permitted_unknown);
        return layoutPanes(app, conn, id_json);
    }
    if (std.mem.eql(u8, method, "commands.list")) {
        try gate.logApi(app, caller, .api_read, .view, method, false);
        return commandsList(app, conn, id_json);
    }
    if (std.mem.eql(u8, method, "editor.open")) return editorOpen(app, conn, id_json, caller, params);
    if (std.mem.eql(u8, method, "commands.run")) return commandsRun(app, conn, id_json, caller, params);
    return replyError(app, conn, id_json, err_method, "no such method");
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

fn getUint(params: std.json.Value, key: []const u8) ?u32 {
    const o = switch (params) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get(key) orelse return null) {
        .integer => |i| if (i >= 1 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        else => null,
    };
}

fn initialize(app: *App, who: u32, conn: u32, id_json: []const u8, params: std.json.Value) Allocator.Error!void {
    const caller: gate.Caller = if (getStr(params, "token")) |tok| identify(app, tok) else .unknown;
    try app.api.conns.put(app.gpa, who, caller);
    const arena = app.frame.allocator();
    var a: std.Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    var buf: [32]u8 = undefined;
    w.print("{{\"version\":\"" ++ version ++ "\",\"protocol\":\"" ++ protocol ++ "\",\"instance\":{d},\"workspace\":", .{paths.selfPid()}) catch return error.OutOfMemory;
    std.json.Stringify.encodeJsonString(app.workspace, .{}, w) catch return error.OutOfMemory;
    w.print(",\"identity\":\"{s}\"}}", .{caller.name(&buf)}) catch return error.OutOfMemory;
    try replyResult(app, conn, id_json, a.written());
}

fn stateStatus(app: *App, conn: u32, id_json: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    const st = try app_driver.AppDriver.statusOf(app, arena);
    try replyResult(app, conn, id_json, try screen_mod.statusJson(arena, st));
}

fn layoutPanes(app: *App, conn: u32, id_json: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    var a: std.Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    w.writeByte('[') catch return error.OutOfMemory;
    var first = true;
    for (app.panes.slots.items, 0..) |*slot, i| if (slot.*) |*pane| {
        if (!first) w.writeByte(',') catch return error.OutOfMemory;
        first = false;
        w.print("{{\"pane\":{d},\"kind\":\"{s}\",\"title\":", .{ i, @tagName(pane.*) }) catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(pane.title(), .{}, w) catch return error.OutOfMemory;
        w.print(",\"active\":{},\"dirty\":{},\"preview\":{}}}", .{ app.active == @as(PaneId, @intCast(i)), pane.dirty(), pane.preview() }) catch return error.OutOfMemory;
    };
    w.writeByte(']') catch return error.OutOfMemory;
    try replyResult(app, conn, id_json, a.written());
}

fn commandsList(app: *App, conn: u32, id_json: []const u8) Allocator.Error!void {
    const arena = app.frame.allocator();
    var a: std.Io.Writer.Allocating = .init(arena);
    const w = &a.writer;
    w.writeByte('[') catch return error.OutOfMemory;
    for (std.enums.values(command.CommandId), 0..) |cid, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        w.writeAll("{\"id\":") catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(command.name(cid), .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"title\":") catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(command.title(cid), .{}, w) catch return error.OutOfMemory;
        w.writeAll(",\"group\":") catch return error.OutOfMemory;
        std.json.Stringify.encodeJsonString(command.group(cid), .{}, w) catch return error.OutOfMemory;
        w.print(",\"effect\":\"{s}\"}}", .{@tagName(command.effect(.{ .static = cid }))}) catch return error.OutOfMemory;
    }
    w.writeByte(']') catch return error.OutOfMemory;
    try replyResult(app, conn, id_json, a.written());
}

fn editorOpen(app: *App, conn: u32, id_json: []const u8, caller: gate.Caller, params: std.json.Value) Allocator.Error!void {
    const path = getStr(params, "path") orelse return replyError(app, conn, id_json, err_params, "editor.open needs a path");
    if (caller == .unknown) {
        try gate.logApi(app, caller, .api_open, .view, path, true);
        return replyError(app, conn, id_json, err_not_permitted, not_permitted_unknown);
    }
    try gate.logApi(app, caller, .api_open, .view, path, false);
    const abs = try app.absPath(path);
    const id = app.openPath(abs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return replyError(app, conn, id_json, err_no_such, @errorName(err)),
    };
    if (app.panes.editor(id)) |e| if (getUint(params, "line")) |line| {
        const ed = e.buf.editor;
        ed.anchor = null;
        const bottom: u32 = @intCast(ed.lineCount() -| 1);
        ed.placeCursor(@min(line - 1, bottom), (getUint(params, "col") orelse 1) - 1);
        e.view.scroll_line = @intCast(ed.currentLine() -| app.pane_rows / 2);
    };
    app.needs_render = true;
    const out = try std.fmt.allocPrint(app.frame.allocator(), "{{\"pane\":{d}}}", .{id});
    try replyResult(app, conn, id_json, out);
}

fn commandsRun(app: *App, conn: u32, id_json: []const u8, caller: gate.Caller, params: std.json.Value) Allocator.Error!void {
    const cid = getStr(params, "id") orelse return replyError(app, conn, id_json, err_params, "commands.run needs an id");
    const ref = command.resolve(app, cid) orelse return replyError(app, conn, id_json, err_no_such, "no such command");
    // An unknown caller only reads: even a `view` command is refused.
    const effect = command.effect(ref);
    if (caller == .unknown) {
        _ = try gate.askApi(app, caller, conn, id_json, cid, effect);
        return replyError(app, conn, id_json, err_not_permitted, not_permitted_unknown);
    }
    switch (try gate.askApi(app, caller, conn, id_json, cid, effect)) {
        .run => try runAndReply(app, conn, id_json, ref),
        .refused => try replyError(app, conn, id_json, err_not_permitted, "not permitted"),
        // Answered when the person decides (`ipc_gate.release` / `deny`).
        .held => {},
    }
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

/// A line from connection `conn`, handled as the loop would.
fn feed(app: *App, conn: u32, line: []const u8) !void {
    const inc = try app.gpa.create(server_mod.Incoming);
    inc.* = .{ .conn = conn, .line = try app.gpa.dupe(u8, line) };
    try handle(app, inc);
}

/// The last reply on `conn`, owned by the App until the next `take`.
fn last(app: *App, conn: u32) ?[]const u8 {
    var i = app.api.unsent.items.len;
    while (i > 0) {
        i -= 1;
        if (app.api.unsent.items[i].conn == conn) return app.api.unsent.items[i].line;
    }
    return null;
}

fn has(app: *App, conn: u32, needle: []const u8) bool {
    const l = last(app, conn) orelse return false;
    return std.mem.indexOf(u8, l, needle) != null;
}

const Fx = struct {
    app: App,
    fn init(fx: *Fx) !void {
        fx.app = try App.initWith(t.allocator, t.io, .{ .workspace = App.scratch_workspace, .cols = 100, .rows = 30 });
        fx.app.api.socket = "/test/1.sock";
    }
};

test "initialize names the caller: a pane's token is pane:<id>, none or a wrong one is unknown; nothing answers before it" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.app.deinit();
    const app = &fx.app;
    const tok = (try mintToken(app, 7)).?;
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}");
    try t.expect(has(app, 1, "initialize first"));

    const line = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"initialize\",\"params\":{{\"token\":\"{s}\"}}}}", .{&tok});
    defer t.allocator.free(line);
    try feed(app, 1, line);
    try t.expect(has(app, 1, "\"id\":\"a\""));
    try t.expect(has(app, 1, "\"version\":\"v1\""));
    try t.expect(has(app, 1, "\"identity\":\"pane:7\""));
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}");
    try t.expect(has(app, 1, "\"result\":\"pong\""));

    try feed(app, 2, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"token\":\"00000000000000000000000000000000\"}}");
    try t.expect(has(app, 2, "\"identity\":\"unknown\""));
    try feed(app, 3, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
    try t.expect(has(app, 3, "\"identity\":\"unknown\""));
    try feed(app, 3, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"no.such\"}");
    try t.expect(has(app, 3, "-32601"));
    try feed(app, 3, "not json");
    try t.expect(has(app, 3, "-32700"));
}

test "unknown reads state.* and commands.list only; editor.open, layout.panes and commands.run are refused" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.app.deinit();
    const app = &fx.app;
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\"}");
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"state.status\"}");
    try t.expect(has(app, 1, "\"result\":{\"focus\""));
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"commands.list\"}");
    try t.expect(has(app, 1, "{\"id\":\"view.toggle_tree\""));
    try t.expect(has(app, 1, "\"effect\":\"view\""));
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"layout.panes\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"editor.open\",\"params\":{\"path\":\"x.txt\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"commands.run\",\"params\":{\"id\":\"view.toggle_tree\"}}",
    }) |l| {
        try feed(app, 1, l);
        try t.expect(has(app, 1, "-32001"));
    }
    try t.expect(app.activeEditor() == null);
    try t.expectEqual(@as(usize, 0), app.ipc_gate.pending.items.len);
    // On the audit trail as refused by policy.
    var refused: usize = 0;
    for (app.ipc_gate.audit.items) |l| {
        if (std.mem.indexOf(u8, l, "\"client\":\"unknown\"") != null and std.mem.indexOf(u8, l, "\"decision\":\"denied\",\"by\":\"policy\"") != null) refused += 1;
    }
    try t.expectEqual(@as(usize, 3), refused);
}

test "a pane opens a file at a line, lists panes, runs a view command unasked, and waits on the person for an edit one" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.app.deinit();
    const app = &fx.app;
    const file = try std.fs.path.join(t.allocator, &.{ app.workspace, "notes.txt" });
    defer t.allocator.free(file);
    try std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = file, .data = "one\ntwo\nthree\n" });
    const tok = (try mintToken(app, 4)).?;
    const init_line = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{{\"token\":\"{s}\"}}}}", .{&tok});
    defer t.allocator.free(init_line);
    try feed(app, 1, init_line);

    // The path is JSON-encoded: on Windows it carries backslashes.
    var path_json: std.Io.Writer.Allocating = .init(t.allocator);
    defer path_json.deinit();
    try std.json.Stringify.encodeJsonString(file, .{}, &path_json.writer);
    const open = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"editor.open\",\"params\":{{\"path\":{s},\"line\":3}}}}", .{path_json.written()});
    defer t.allocator.free(open);
    try feed(app, 1, open);
    try t.expect(has(app, 1, "\"result\":{\"pane\":"));
    const ed = app.activeEditor().?;
    try t.expectEqual(@as(usize, 2), ed.buf.editor.currentLine());

    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"layout.panes\"}");
    try t.expect(has(app, 1, "\"title\":\"notes.txt\""));
    try t.expect(has(app, 1, "\"active\":true"));

    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"commands.run\",\"params\":{\"id\":\"view.toggle_tree\"}}");
    try t.expect(has(app, 1, "\"id\":3,\"result\":{\"ok\":true}"));

    // An edit command waits: no reply, one request held, its toast up.
    const before = app.api.unsent.items.len;
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"commands.run\",\"params\":{\"id\":\"scratch.new\"}}");
    try t.expectEqual(before, app.api.unsent.items.len);
    try t.expectEqual(@as(usize, 1), app.ipc_gate.pending.items.len);
    const ask = try gate.askTextFor(app.frame.allocator(), app.ipc_gate.pending.items[0], "x");
    try t.expect(std.mem.startsWith(u8, ask, "pane 4 · x asks to run scratch.new (edit)"));
    // Allowed for the session: answered now, and the next edit runs unasked.
    try gate.answer(app, app.ipc_gate.pending.items[0].id, 1);
    try t.expect(has(app, 1, "\"id\":4,\"result\":{\"ok\":true}"));
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"commands.run\",\"params\":{\"id\":\"scratch.new\"}}");
    try t.expect(has(app, 1, "\"id\":5,\"result\":{\"ok\":true}"));
    // A write command is another class: asked again, and denied.
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"commands.run\",\"params\":{\"id\":\"file.save\"}}");
    try t.expectEqual(@as(usize, 1), app.ipc_gate.pending.items.len);
    try gate.answer(app, app.ipc_gate.pending.items[0].id, 2);
    try t.expect(has(app, 1, "\"id\":6,\"error\":{\"code\":-32002"));
}

test "a pane's grant and token go when it closes, and what it was waiting on is denied" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.app.deinit();
    const app = &fx.app;
    const tok = (try mintToken(app, 4)).?;
    const init_line = try std.fmt.allocPrint(t.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{{\"token\":\"{s}\"}}}}", .{&tok});
    defer t.allocator.free(init_line);
    try feed(app, 1, init_line);
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"commands.run\",\"params\":{\"id\":\"scratch.new\"}}");
    try t.expectEqual(@as(usize, 1), app.ipc_gate.pending.items.len);
    (try app.api.grants.getOrPut(t.allocator, 4)).value_ptr.* = .initFull();

    forgetPane(app, 4);
    try t.expectEqual(@as(usize, 0), app.ipc_gate.pending.items.len);
    try t.expect(has(app, 1, "\"id\":1,\"error\":{\"code\":-32002"));
    try t.expect(app.api.tokens.get(4) == null);
    try t.expect(app.api.grants.get(4) == null);
    try t.expectEqual(gate.Caller.unknown, app.api.conns.get(1).?);
    // Its connection reads only now.
    try feed(app, 1, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"commands.run\",\"params\":{\"id\":\"scratch.new\"}}");
    try t.expect(has(app, 1, "\"id\":2,\"error\":{\"code\":-32001"));
}
