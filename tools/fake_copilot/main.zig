//! mnml-fake-copilot — a deterministic stand-in for GitHub Copilot's
//! language server, over stdio, so mnml's Copilot backend can be tested
//! on every platform with no account, no network and no seat.
//!
//! It answers the subset `docs/research/copilot-backend-2026-09-21.md`
//! verified against `@github/copilot-language-server` 1.548.0, with the
//! same shapes: `initialize`, `checkStatus`, `signIn` (a canned device
//! code AND a `verificationUri`, which the real server returns and its
//! README's example omits), `signOut`, `textDocument/inlineCompletion`
//! with one canned item, and `workspace/executeCommand`. Status reaches
//! the client as `didChangeStatus`.
//!
//! **The log is the point.** `--log PATH` records every method that
//! arrives, one per line, rewritten on each message. A privacy test
//! needs to prove an ABSENCE — that no `didOpen`, no `didChange` and no
//! `inlineCompletion` was ever sent for a workspace that did not opt in
//! — and an absence is only provable against a record of everything
//! that did arrive.
//!
//! Flags:
//!   --log PATH        every incoming method, one per line
//!   --signed-out      `checkStatus` answers `NotSignedIn`, and the
//!                     first `didChangeStatus` says `Error`
//!   --suggest TEXT    what `inlineCompletion` offers (default below)
//!   --no-suggest      answer `{"items":[]}`

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const version = "0.1.0";

pub const Value = std.json.Value;

/// The canned completion, and the opaque id its accept command carries
/// — a test asserts the id reaches the log, which is what proves the
/// accept telemetry went back with the ITEM'S command rather than one
/// mnml made up.
pub const default_suggestion = "fake_copilot_suggestion();";
pub const completion_id = "fake-op-1";

pub const Server = struct {
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    log_path: ?[]const u8 = null,
    log: std.ArrayList(u8) = .empty,
    signed_out: bool = false,
    suggestion: []const u8 = default_suggestion,
    /// The last position `inlineCompletion` was asked at, so the item's
    /// range can cover the line up to the cursor the way Copilot's does.
    done: bool = false,

    pub fn init(gpa: Allocator, io: Io, out: *Io.Writer) Server {
        return .{ .gpa = gpa, .io = io, .out = out };
    }

    pub fn deinit(self: *Server) void {
        self.log.deinit(self.gpa);
        self.* = undefined;
    }

    // ─── the wire ───

    fn emit(self: *Server, json: []const u8) Io.Writer.Error!void {
        try self.out.print("Content-Length: {d}\r\n\r\n", .{json.len});
        try self.out.writeAll(json);
        try self.out.flush();
    }

    fn respondRaw(self: *Server, id: Value, result: []const u8) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("id");
        try js.write(id);
        try js.objectField("result");
        try js.beginWriteRaw();
        try js.writer.writeAll(result);
        js.endWriteRaw();
        try js.endObject();
        try self.emit(aw.written());
    }

    fn respond(self: *Server, id: Value, result: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        try js.write(result);
        try self.respondRaw(id, aw.written());
    }

    fn notify(self: *Server, method: []const u8, params: anytype) !void {
        var aw: Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        try js.beginObject();
        try js.objectField("jsonrpc");
        try js.write("2.0");
        try js.objectField("method");
        try js.write(method);
        try js.objectField("params");
        try js.write(params);
        try js.endObject();
        try self.emit(aw.written());
    }

    // ─── messages ───

    pub fn handle(self: *Server, body: []const u8) !void {
        var parsed = std.json.parseFromSlice(Value, self.gpa, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer parsed.deinit();
        const v = parsed.value;
        const method = getStr(v, "method") orelse return;
        try self.logMethod(method, v);
        const params = getField(v, "params") orelse Value.null;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (getField(v, "id")) |id| try self.request(arena, id, method, params) else try self.notification(method, params);
    }

    /// Every method, one per line. `workspace/executeCommand` also
    /// records the command it carried, because "the accept reached the
    /// server" is only interesting if it carried the item's own id.
    fn logMethod(self: *Server, method: []const u8, v: Value) !void {
        const path = self.log_path orelse return;
        try self.log.appendSlice(self.gpa, method);
        if (std.mem.eql(u8, method, "workspace/executeCommand")) {
            if (getField(v, "params")) |p| if (getStr(p, "command")) |c| {
                try self.log.append(self.gpa, ' ');
                try self.log.appendSlice(self.gpa, c);
                if (getField(p, "arguments")) |args| switch (args) {
                    .array => |a| if (a.items.len > 0) switch (a.items[0]) {
                        .string => |s| {
                            try self.log.append(self.gpa, ' ');
                            try self.log.appendSlice(self.gpa, s);
                        },
                        else => {},
                    },
                    else => {},
                };
            };
        }
        try self.log.append(self.gpa, '\n');
        Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = self.log.items }) catch {};
    }

    fn request(self: *Server, arena: Allocator, id: Value, method: []const u8, params: Value) !void {
        const eql = std.mem.eql;
        if (eql(u8, method, "initialize")) {
            return self.respond(id, .{
                .capabilities = .{ .textDocumentSync = .{ .openClose = true, .change = 2 }, .workspace = .{ .workspaceFolders = .{ .supported = true } } },
                .serverInfo = .{ .name = "mnml-fake-copilot", .version = version },
            });
        }
        if (eql(u8, method, "shutdown")) {
            return self.respondRaw(id, "null");
        }
        if (eql(u8, method, "checkStatus")) {
            if (self.signed_out) return self.respond(id, .{ .status = "NotSignedIn" });
            return self.respond(id, .{ .status = "OK", .user = "fake-octocat" });
        }
        if (eql(u8, method, "signIn")) {
            if (!self.signed_out) return self.respond(id, .{ .status = "AlreadySignedIn", .user = "fake-octocat" });
            // The shape the 1.548.0 handler really returns — the README
            // shows only `userCode`, which would leave a terminal editor
            // with nowhere to send the user.
            return self.respond(id, .{
                .status = "PromptUserDeviceFlow",
                .userCode = "FAKE-CODE",
                .verificationUri = "https://github.com/login/device",
                .expiresIn = @as(i64, 899),
                .interval = @as(i64, 5),
                .command = .{ .command = "github.copilot.finishDeviceFlow", .title = "Sign in with GitHub", .arguments = &[_][]const u8{} },
            });
        }
        if (eql(u8, method, "signOut")) {
            self.signed_out = true;
            try self.respondRaw(id, "{}");
            return self.notify("didChangeStatus", .{ .busy = false, .kind = "Error", .message = "not signed in" });
        }
        if (eql(u8, method, "workspace/executeCommand")) {
            return self.respondRaw(id, "null");
        }
        if (eql(u8, method, "textDocument/inlineCompletion")) {
            if (self.suggestion.len == 0) return self.respondRaw(id, "{\"items\":[]}");
            const pos = getField(params, "position") orelse Value.null;
            const line: i64 = getInt(pos, "line") orelse 0;
            const ch: i64 = getInt(pos, "character") orelse 0;
            // A range that starts at the cursor: the item is a pure
            // insert, which is the case a test can assert on screen.
            const item = .{
                .insertText = self.suggestion,
                .range = .{ .start = .{ .line = line, .character = ch }, .end = .{ .line = line, .character = ch } },
                .command = .{ .command = "github.copilot.didAcceptCompletionItem", .title = "Accept", .arguments = &[_][]const u8{completion_id} },
            };
            return self.respond(id, .{ .items = &[_]@TypeOf(item){item} });
        }
        _ = arena;
        return self.respondRaw(id, "null");
    }

    fn notification(self: *Server, method: []const u8, params: Value) !void {
        _ = params;
        if (std.mem.eql(u8, method, "exit")) {
            self.done = true;
            return;
        }
        if (std.mem.eql(u8, method, "initialized")) {
            // The first status, the way the real server sends one as
            // soon as it knows.
            if (self.signed_out) {
                return self.notify("didChangeStatus", .{ .busy = false, .kind = "Error", .message = "not signed in" });
            }
            return self.notify("didChangeStatus", .{ .busy = false, .kind = "Normal", .message = "" });
        }
    }
};

// ─── JSON access ───

fn getField(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn getStr(v: Value, key: []const u8) ?[]const u8 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(v: Value, key: []const u8) ?i64 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => null,
    };
}

// ─── framing ───

pub const FrameError = error{ Closed, BadFrame } || Allocator.Error;

pub fn readFrame(gpa: Allocator, r: *Io.Reader) FrameError![]u8 {
    var len: ?usize = null;
    while (true) {
        const raw = (r.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.Closed,
            error.StreamTooLong => return error.BadFrame,
        }) orelse return error.Closed;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            if (len != null) break;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "Content-Length")) {
            len = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return error.BadFrame;
        }
    }
    const n = len.?;
    if (n > 8 * 1024 * 1024) return error.BadFrame;
    const body = try gpa.alloc(u8, n);
    errdefer gpa.free(body);
    r.readSliceAll(body) catch return error.Closed;
    return body;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const args = try init.minimal.args.toSlice(arena_state.allocator());
    var log_path: ?[]const u8 = null;
    var signed_out = false;
    var suggestion: []const u8 = default_suggestion;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--version")) {
            var buf: [128]u8 = undefined;
            var w: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
            try w.interface.print("mnml-fake-copilot {s}\n", .{version});
            try w.interface.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var buf: [512]u8 = undefined;
            var w: Io.File.Writer = .initStreaming(.stdout(), io, &buf);
            try w.interface.writeAll("mnml-fake-copilot [--stdio] [--log PATH] [--signed-out] [--suggest TEXT] [--no-suggest]\n");
            try w.interface.flush();
            return 0;
        }
        if (std.mem.eql(u8, a, "--signed-out")) signed_out = true;
        if (std.mem.eql(u8, a, "--no-suggest")) suggestion = "";
        if (std.mem.eql(u8, a, "--log") and i + 1 < args.len) {
            i += 1;
            log_path = args[i];
        }
        if (std.mem.eql(u8, a, "--suggest") and i + 1 < args.len) {
            i += 1;
            suggestion = args[i];
        }
    }
    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &in_buf);
    var writer = Io.File.stdout().writerStreaming(io, &out_buf);
    var server = Server.init(gpa, io, &writer.interface);
    defer server.deinit();
    server.log_path = log_path;
    server.signed_out = signed_out;
    server.suggestion = suggestion;
    while (!server.done) {
        const body = readFrame(gpa, &reader.interface) catch |err| switch (err) {
            error.Closed, error.BadFrame => break,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer gpa.free(body);
        server.handle(body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => break,
        };
    }
    return 0;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

const Harness = struct {
    aw: Io.Writer.Allocating,
    server: Server,

    fn init(h: *Harness) void {
        h.* = .{ .aw = .init(t.allocator), .server = undefined };
        h.server = Server.init(t.allocator, t.io, &h.aw.writer);
    }

    fn deinit(h: *Harness) void {
        h.server.deinit();
        h.aw.deinit();
    }

    fn send(h: *Harness, body: []const u8) !void {
        try h.server.handle(body);
    }

    fn out(h: *Harness) []const u8 {
        return h.aw.written();
    }
};

test "the handshake, and the status that follows `initialized`" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    try t.expect(std.mem.indexOf(u8, h.out(), "mnml-fake-copilot") != null);
    try h.send("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try t.expect(std.mem.indexOf(u8, h.out(), "\"didChangeStatus\"") != null);
    try t.expect(std.mem.indexOf(u8, h.out(), "\"Normal\"") != null);
}

test "signed out: checkStatus says so and signIn hands back a code AND a uri" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.server.signed_out = true;
    try h.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"checkStatus\",\"params\":{}}");
    try t.expect(std.mem.indexOf(u8, h.out(), "NotSignedIn") != null);
    try h.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"signIn\",\"params\":{}}");
    try t.expect(std.mem.indexOf(u8, h.out(), "FAKE-CODE") != null);
    // The README's example omits this; the shipped server returns it.
    try t.expect(std.mem.indexOf(u8, h.out(), "https://github.com/login/device") != null);
    try t.expect(std.mem.indexOf(u8, h.out(), "github.copilot.finishDeviceFlow") != null);
}

test "inlineCompletion: one canned item at the cursor, carrying its own accept command" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    try h.send(
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/inlineCompletion",
        \\ "params":{"textDocument":{"uri":"file:///w/a.zig","version":2},"position":{"line":4,"character":7}}}
    );
    const o = h.out();
    try t.expect(std.mem.indexOf(u8, o, default_suggestion) != null);
    try t.expect(std.mem.indexOf(u8, o, "\"character\":7") != null);
    try t.expect(std.mem.indexOf(u8, o, completion_id) != null);
    // `--no-suggest` is the "nothing to suggest" case.
    h.server.suggestion = "";
    try h.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/inlineCompletion\",\"params\":{}}");
    try t.expect(std.mem.indexOf(u8, h.out(), "\"items\":[]") != null);
}

test "the log records every method, and names the command an accept carried" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.server.log_path = null; // no file; the buffer is what the test reads
    // `logMethod` returns early without a path, so give it one that
    // cannot be written — the buffer still fills, which is what a
    // privacy assertion reads.
    h.server.log_path = "";
    try h.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{}}");
    try h.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{}}");
    try h.send(
        \\{"jsonrpc":"2.0","id":9,"method":"workspace/executeCommand",
        \\ "params":{"command":"github.copilot.didAcceptCompletionItem","arguments":["fake-op-1"]}}
    );
    try t.expectEqualStrings(
        "textDocument/didOpen\ntextDocument/didChange\nworkspace/executeCommand github.copilot.didAcceptCompletionItem fake-op-1\n",
        h.server.log.items,
    );
}
