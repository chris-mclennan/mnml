//! The Copilot language server's wire — a SECOND, dedicated JSON-RPC
//! client over `rpc/jsonrpc.zig`'s transport, not a row in `lsp.zig`'s
//! server table.
//!
//! It is deliberately not one. Copilot publishes no diagnostics, has no
//! `languageId` table to answer for, must not be started for a file
//! type match, and must not be started at all until the privacy gate
//! opens — everything `app/lsp.zig` does on an open would be wrong
//! here. What the two share is the transport underneath: the same
//! `Content-Length` framing, the same reader/writer tasks, the same
//! spawn (so Windows and Linux work the way the LSP client does).
//!
//! Ownership follows the LSP client's rules: the reader task only
//! posts; every frame reaches the app as an owned `LspEvent` the
//! handler adopts or destroys.
//!
//! Every method name here is one `docs/research/copilot-backend-
//! 2026-09-21.md` verified against `@github/copilot-language-server`
//! 1.548.0's README and its shipped bundle. Nothing is coded from
//! memory: the names that could NOT be confirmed as current
//! (`signInConfirm`, a client-driven poll) are absent on purpose.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const jsonrpc = @import("../rpc/jsonrpc.zig");
const Transport = jsonrpc.Transport;
const event = @import("../core/event.zig");
const types = @import("../lsp/types.zig");
const copilot = @import("../ai/copilot.zig");

pub const SendError = jsonrpc.SendError || Allocator.Error;

/// The requests mnml makes. Rides in the transport's `Pending.kind`.
pub const ReqKind = enum(u16) {
    initialize,
    check_status,
    sign_in,
    sign_out,
    inline_completion,
    execute_command,
};

/// Positions are UTF-16: Copilot declares no `positionEncoding`, and
/// UTF-16 is LSP's default. `acceptedLength` counts the same unit.
pub const encoding: types.Encoding = .utf16;

const OpenDoc = struct { version: i64 };

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    events: *event.EventQueue,
    transport: *Transport,
    /// The workspace folder the server was told about. Owned.
    root: []u8,
    /// argv[0], for the toasts. Owned.
    cmd: []u8,
    /// `initialize` replied and `initialized` went out.
    ready: bool = false,
    /// Open documents by absolute path (owned keys).
    docs: std.StringHashMapUnmanaged(OpenDoc) = .empty,
    /// The completion request still out, so the next keystroke can
    /// `$/cancelRequest` it. Copilot also cancels the previous itself,
    /// but the README asks clients to cancel eagerly and the server
    /// should not be left computing for a cursor that moved.
    in_flight: ?i64 = null,
    /// `github-enterprise.uri`, or null. Owned when set.
    ghe_uri: ?[]u8 = null,

    pub const SpawnError = Transport.SpawnError || Io.ConcurrentError;

    pub const Options = struct {
        argv: []const []const u8,
        root: []const u8,
        env: ?*const std.process.Environ.Map = null,
        github_enterprise_uri: ?[]const u8 = null,
    };

    pub fn spawn(gpa: Allocator, io: Io, events: *event.EventQueue, o: Options) SpawnError!*Client {
        const tr = try Transport.spawn(gpa, io, o.argv, o.root, o.env);
        errdefer tr.shutdown();
        return initWith(gpa, io, events, tr, o);
    }

    /// Over two open files — how the tests drive a fake server without
    /// a process.
    pub fn initFiles(gpa: Allocator, io: Io, events: *event.EventQueue, stdin: Io.File, stdout: Io.File, o: Options) SpawnError!*Client {
        const tr = try Transport.initFiles(gpa, io, stdin, stdout);
        errdefer tr.shutdown();
        return initWith(gpa, io, events, tr, o);
    }

    fn initWith(gpa: Allocator, io: Io, events: *event.EventQueue, tr: *Transport, o: Options) SpawnError!*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        const root = try gpa.dupe(u8, o.root);
        errdefer gpa.free(root);
        const cmd = try gpa.dupe(u8, if (o.argv.len > 0) o.argv[0] else copilot.default_binary);
        errdefer gpa.free(cmd);
        const ghe: ?[]u8 = if (o.github_enterprise_uri) |u| try gpa.dupe(u8, u) else null;
        errdefer if (ghe) |g| gpa.free(g);
        c.* = .{ .gpa = gpa, .io = io, .events = events, .transport = tr, .root = root, .cmd = cmd, .ghe_uri = ghe };
        try tr.start(.{ .ctx = c, .message = onMessage, .closed = onClosed });
        return c;
    }

    /// `signOut` is NOT sent here: quitting the editor must not log the
    /// user out of Copilot. The pair is LSP's `shutdown` + `exit`, with
    /// the same grace the LSP client gives.
    pub fn deinit(self: *Client) void {
        const gpa = self.gpa;
        if (!self.transport.isDead()) {
            _ = self.request(.sign_out, "shutdown", null) catch 0;
            self.notify("exit", null) catch {};
        }
        self.transport.shutdown();
        var it = self.docs.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.docs.deinit(gpa);
        if (self.ghe_uri) |g| gpa.free(g);
        gpa.free(self.cmd);
        gpa.free(self.root);
        gpa.destroy(self);
    }

    // ─── the sink (reader task): post only ───

    fn onMessage(ctx: *anyopaque, msg: *jsonrpc.Incoming) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const ev = self.gpa.create(event.LspEvent) catch {
            msg.destroy(self.gpa);
            return;
        };
        ev.* = .{ .message = msg };
        self.events.post(self.io, .{ .copilot = .{ .msg = ev } });
    }

    fn onClosed(ctx: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const ev = self.gpa.create(event.LspEvent) catch return;
        ev.* = .closed;
        self.events.post(self.io, .{ .copilot = .{ .msg = ev } });
    }

    // ─── the envelope ───

    pub fn request(self: *Client, kind: ReqKind, method: []const u8, params: anytype) SendError!i64 {
        const id = self.transport.allocId();
        const body = try jsonrpc.stringify(self.gpa, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        defer self.gpa.free(body);
        try self.transport.expect(id, .{ .kind = @intFromEnum(kind) });
        self.transport.send(body) catch |err| {
            _ = self.transport.forget(id);
            return err;
        };
        return id;
    }

    pub fn notify(self: *Client, method: []const u8, params: anytype) SendError!void {
        const body = try jsonrpc.stringify(self.gpa, .{ .jsonrpc = "2.0", .method = method, .params = params });
        defer self.gpa.free(body);
        try self.transport.send(body);
    }

    /// Answer a server→client request. `window/showMessageRequest` and
    /// `window/showDocument` are the two that arrive.
    pub fn respond(self: *Client, id: i64, result_json: []const u8) SendError!void {
        const body = try std.fmt.allocPrint(self.gpa, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result_json });
        defer self.gpa.free(body);
        try self.transport.send(body);
    }

    pub fn cancel(self: *Client, id: i64) void {
        _ = self.transport.forget(id);
        self.notify("$/cancelRequest", .{ .id = id }) catch {};
        if (self.in_flight == id) self.in_flight = null;
    }

    /// Cancel whatever completion is out — what a keystroke does.
    pub fn cancelInFlight(self: *Client) void {
        if (self.in_flight) |id| self.cancel(id);
    }

    // ─── the handshake ───

    /// `initialize`, with the two options Copilot keys itself off:
    /// `editorInfo` and `editorPluginInfo` (README "Initialization").
    pub fn initialize(self: *Client) SendError!void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const root_uri = try types.uriFromPath(a, self.root);
        _ = try self.request(.initialize, "initialize", .{
            .processId = null,
            .clientInfo = .{ .name = copilot.editor_name, .version = copilot.editor_version },
            .rootUri = root_uri,
            .workspaceFolders = &[_]struct { uri: []const u8, name: []const u8 }{.{ .uri = root_uri, .name = std.fs.path.basename(self.root) }},
            .capabilities = .{
                .workspace = .{ .workspaceFolders = true, .configuration = true, .didChangeConfiguration = .{ .dynamicRegistration = false } },
                .window = .{ .showDocument = .{ .support = true } },
                .textDocument = .{ .synchronization = .{ .didSave = false, .willSave = false } },
            },
            .initializationOptions = .{
                .editorInfo = .{ .name = copilot.editor_name, .version = copilot.editor_version },
                .editorPluginInfo = .{ .name = copilot.plugin_name, .version = copilot.plugin_version },
            },
        });
    }

    /// `initialized`, then the configuration push the README asks for,
    /// then one `checkStatus` so the chip knows before the first
    /// keystroke whether this machine is signed in.
    pub fn finishHandshake(self: *Client) SendError!void {
        self.ready = true;
        try self.notify("initialized", .{});
        if (self.ghe_uri) |uri| {
            try self.notify("workspace/didChangeConfiguration", .{ .settings = .{ .@"github-enterprise" = .{ .uri = uri } } });
        } else {
            try self.notify("workspace/didChangeConfiguration", .{ .settings = .{} });
        }
        _ = try self.request(.check_status, "checkStatus", .{ .options = .{} });
    }

    // ─── documents ───

    pub fn isOpen(self: *const Client, path: []const u8) bool {
        return self.docs.contains(path);
    }

    pub fn didOpen(self: *Client, path: []const u8, language_id: []const u8, text: []const u8) SendError!void {
        if (self.docs.contains(path)) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const uri = try types.uriFromPath(arena_state.allocator(), path);
        const key = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(key);
        try self.docs.put(self.gpa, key, .{ .version = 1 });
        errdefer _ = self.docs.remove(key);
        try self.notify("textDocument/didOpen", .{ .textDocument = .{ .uri = uri, .languageId = language_id, .version = @as(i64, 1), .text = text } });
    }

    /// One content change. The README calls incremental sync required,
    /// so `range` is filled whenever the editor can say what changed;
    /// a null range is the full-text fallback for the cases it cannot
    /// (an undo that lost the splice log).
    pub const Change = struct { range: ?types.Range, text: []const u8 };

    pub fn didChange(self: *Client, path: []const u8, changes: []const Change) SendError!void {
        const doc = self.docs.getPtr(path) orelse return;
        doc.version += 1;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const uri = try types.uriFromPath(a, path);
        const Full = struct { text: []const u8 };
        const Part = struct { range: types.Range, text: []const u8 };
        var full: std.ArrayListUnmanaged(Full) = .empty;
        var part: std.ArrayListUnmanaged(Part) = .empty;
        for (changes) |c| {
            if (c.range) |r| try part.append(a, .{ .range = r, .text = c.text }) else try full.append(a, .{ .text = c.text });
        }
        if (part.items.len != 0) {
            try self.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = doc.version }, .contentChanges = part.items });
        } else {
            try self.notify("textDocument/didChange", .{ .textDocument = .{ .uri = uri, .version = doc.version }, .contentChanges = full.items });
        }
    }

    pub fn didClose(self: *Client, path: []const u8) SendError!void {
        const kv = self.docs.fetchRemove(path) orelse return;
        self.gpa.free(kv.key);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const uri = try types.uriFromPath(arena_state.allocator(), path);
        try self.notify("textDocument/didClose", .{ .textDocument = .{ .uri = uri } });
    }

    /// Copilot's own notification for a tab change — it weights the
    /// focused document's neighbourhood. `null` says nothing is
    /// focused, which the README spells as an empty params object.
    pub fn didFocus(self: *Client, path: ?[]const u8) SendError!void {
        const p = path orelse return self.notify("textDocument/didFocus", .{});
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const uri = try types.uriFromPath(arena_state.allocator(), p);
        try self.notify("textDocument/didFocus", .{ .textDocument = .{ .uri = uri } });
    }

    pub fn versionOf(self: *const Client, path: []const u8) i64 {
        return if (self.docs.get(path)) |d| d.version else 0;
    }

    // ─── completions ───

    /// `triggerKind`: 1 is Invoked (the user asked), 2 Automatic (we
    /// asked because typing paused). Ghost text is always automatic.
    pub const trigger_automatic: u8 = 2;

    pub fn inlineCompletion(self: *Client, path: []const u8, pos: types.Position, tab_size: u32, insert_spaces: bool) SendError!i64 {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const uri = try types.uriFromPath(arena_state.allocator(), path);
        const id = try self.request(.inline_completion, "textDocument/inlineCompletion", .{
            // `textDocument.version` and `formattingOptions` are
            // Copilot's non-standard additions to LSP 3.18's request —
            // the README documents both.
            .textDocument = .{ .uri = uri, .version = self.versionOf(path) },
            .position = pos,
            .context = .{ .triggerKind = trigger_automatic },
            .formattingOptions = .{ .tabSize = tab_size, .insertSpaces = insert_spaces },
        });
        self.in_flight = id;
        return id;
    }

    /// The item is on screen. LSP has no event for it, so Copilot's
    /// custom one carries the whole item back (README "Inline
    /// Completions"). `item_json` is the raw object as it arrived.
    pub fn didShowCompletion(self: *Client, item_json: []const u8) SendError!void {
        const body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didShowCompletion\",\"params\":{{\"item\":{s}}}}}",
            .{item_json},
        );
        defer self.gpa.free(body);
        try self.transport.send(body);
    }

    /// A `ctrl+→` / `ctrl+↓` accept. `accepted_len` is UTF-16 code
    /// units from the START of `insertText` — see
    /// `ai/copilot.zig::acceptedLength`, where getting it backwards
    /// would skew telemetry silently rather than fail.
    pub fn didPartiallyAccept(self: *Client, item_json: []const u8, accepted_len: u32) SendError!void {
        const body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didPartiallyAcceptCompletion\",\"params\":{{\"item\":{s},\"acceptedLength\":{d}}}}}",
            .{ item_json, accepted_len },
        );
        defer self.gpa.free(body);
        try self.transport.send(body);
    }

    /// The full accept: the item's OWN `command`, echoed verbatim
    /// through `workspace/executeCommand`. Never a command mnml
    /// composes — the id inside it is Copilot's and opaque.
    pub fn executeCommand(self: *Client, command_json: []const u8) SendError!void {
        const id = self.transport.allocId();
        const body = try std.fmt.allocPrint(
            self.gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"workspace/executeCommand\",\"params\":{s}}}",
            .{ id, command_json },
        );
        defer self.gpa.free(body);
        try self.transport.expect(id, .{ .kind = @intFromEnum(ReqKind.execute_command) });
        self.transport.send(body) catch |err| {
            _ = self.transport.forget(id);
            return err;
        };
    }

    // ─── auth ───

    /// Start the device flow. The reply is `AlreadySignedIn` or
    /// `PromptUserDeviceFlow` with `userCode` + `verificationUri` — the
    /// README's example omits the URI, the 1.548.0 bundle returns it,
    /// and a terminal editor needs it (see the research note §1.2).
    pub fn signIn(self: *Client) SendError!i64 {
        return self.request(.sign_in, "signIn", .{});
    }

    /// Run the command `signIn` handed back
    /// (`github.copilot.finishDeviceFlow`) once the user says they have
    /// entered the code. The server polls for the token itself and
    /// reports through `didChangeStatus`; mnml drives no poll loop,
    /// because nothing in 1.548.0 asks a client to.
    pub fn finishDeviceFlow(self: *Client) SendError!void {
        try self.executeCommand("{\"command\":\"" ++ copilot.finish_device_flow_command ++ "\",\"arguments\":[]}");
    }

    pub fn signOut(self: *Client) SendError!i64 {
        return self.request(.sign_out, "signOut", .{});
    }

    pub fn checkStatus(self: *Client) SendError!i64 {
        return self.request(.check_status, "checkStatus", .{ .options = .{} });
    }
};

// ─── reading the replies ────────────────────────────────────────────────

/// The `signIn` reply, borrowed from the response's arena.
pub const SignInReply = struct {
    status: copilot.SignedIn,
    user_code: ?[]const u8 = null,
    verification_uri: ?[]const u8 = null,
    /// Seconds the code is good for.
    expires_in: ?i64 = null,
};

pub fn readSignIn(v: ?jsonrpc.Value) ?SignInReply {
    const obj = v orelse return null;
    const status = jsonrpc.getStr(obj, "status") orelse return null;
    return .{
        .status = copilot.SignedIn.parse(status),
        .user_code = jsonrpc.getStr(obj, "userCode"),
        .verification_uri = jsonrpc.getStr(obj, "verificationUri"),
        .expires_in = jsonrpc.getInt(obj, "expiresIn"),
    };
}

/// `checkStatus`'s reply.
pub fn readStatus(v: ?jsonrpc.Value) copilot.SignedIn {
    const obj = v orelse return .unknown;
    const status = jsonrpc.getStr(obj, "status") orelse return .unknown;
    return copilot.SignedIn.parse(status);
}

/// `didChangeStatus`'s params. `message` is borrowed.
pub const Status = struct {
    kind: copilot.StatusKind = .unknown,
    busy: bool = false,
    message: []const u8 = "",
};

pub fn readDidChangeStatus(v: ?jsonrpc.Value) Status {
    const obj = v orelse return .{};
    return .{
        .kind = if (jsonrpc.getStr(obj, "kind")) |k| copilot.StatusKind.parse(k) else .unknown,
        .busy = jsonrpc.getBool(obj, "busy") orelse false,
        .message = jsonrpc.getStr(obj, "message") orelse "",
    };
}

/// The first usable item of an `inlineCompletion` result, plus the raw
/// JSON of the item and of its `command` — both needed verbatim for the
/// telemetry notifications, so they are re-stringified from the parsed
/// value rather than reconstructed by hand.
pub const Completion = struct {
    item: copilot.Item,
    /// `{"insertText":…}` as it arrived. Arena-owned.
    item_json: []const u8,
};

pub fn readCompletion(arena: Allocator, v: ?jsonrpc.Value) Allocator.Error!?Completion {
    const obj = v orelse return null;
    const items = jsonrpc.getArr(obj, "items") orelse return null;
    for (items) |raw| {
        const insert = jsonrpc.getStr(raw, "insertText") orelse continue;
        if (insert.len == 0) continue;
        var it: copilot.Item = .{ .insert_text = insert };
        if (jsonrpc.getObj(raw, "range")) |r| {
            if (types.readRange(r)) |rr| it.range = .{
                .start = .{ .line = rr.start.line, .character = rr.start.character },
                .end = .{ .line = rr.end.line, .character = rr.end.character },
            };
        }
        if (jsonrpc.getObj(raw, "command")) |c| it.command_json = try jsonrpc.stringify(arena, c);
        return .{ .item = it, .item_json = try jsonrpc.stringify(arena, raw) };
    }
    return null;
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

fn parse(gpa: Allocator, text: []const u8) !std.json.Parsed(jsonrpc.Value) {
    return std.json.parseFromSlice(jsonrpc.Value, gpa, text, .{});
}

test "signIn's reply is read the way 1.548.0 actually sends it" {
    // Already signed in: no code, no URI.
    var a = try parse(t.allocator, "{\"status\":\"AlreadySignedIn\",\"user\":\"octocat\"}");
    defer a.deinit();
    const already = readSignIn(a.value).?;
    try t.expectEqual(copilot.SignedIn.yes, already.status);
    try t.expect(already.user_code == null);
    // The device flow. The README's example shows only `userCode`; the
    // shipped handler returns `verificationUri` too, and a terminal
    // editor must print it.
    var b = try parse(t.allocator,
        \\{"status":"PromptUserDeviceFlow","userCode":"ABCD-1234",
        \\ "verificationUri":"https://github.com/login/device",
        \\ "expiresIn":899,"interval":5,
        \\ "command":{"command":"github.copilot.finishDeviceFlow","title":"Sign in with GitHub","arguments":[]}}
    );
    defer b.deinit();
    const flow = readSignIn(b.value).?;
    try t.expectEqual(copilot.SignedIn.unknown, flow.status); // not a signed-in word
    try t.expectEqualStrings("ABCD-1234", flow.user_code.?);
    try t.expectEqualStrings("https://github.com/login/device", flow.verification_uri.?);
    try t.expectEqual(@as(?i64, 899), flow.expires_in);
    try t.expect(readSignIn(null) == null);
}

test "checkStatus and didChangeStatus" {
    var a = try parse(t.allocator, "{\"status\":\"NotSignedIn\"}");
    defer a.deinit();
    try t.expectEqual(copilot.SignedIn.no, readStatus(a.value));
    var b = try parse(t.allocator, "{\"status\":\"NotAuthorized\"}");
    defer b.deinit();
    try t.expectEqual(copilot.SignedIn.not_authorized, readStatus(b.value));
    try t.expectEqual(copilot.SignedIn.unknown, readStatus(null));

    var c = try parse(t.allocator, "{\"busy\":true,\"kind\":\"Warning\",\"message\":\"request failed\"}");
    defer c.deinit();
    const st = readDidChangeStatus(c.value);
    try t.expectEqual(copilot.StatusKind.warning, st.kind);
    try t.expect(st.busy);
    try t.expectEqualStrings("request failed", st.message);
    try t.expectEqual(copilot.StatusKind.unknown, readDidChangeStatus(null).kind);
}

test "an inlineCompletion result: the first usable item, with its command kept verbatim" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = try parse(t.allocator,
        \\{"items":[
        \\ {"insertText":""},
        \\ {"insertText":"printLine(\"hi\");",
        \\  "range":{"start":{"line":3,"character":4},"end":{"line":3,"character":9}},
        \\  "command":{"command":"github.copilot.didAcceptCompletionItem","arguments":["op-42"]}}]}
    );
    defer p.deinit();
    const got = (try readCompletion(arena.allocator(), p.value)).?;
    try t.expectEqualStrings("printLine(\"hi\");", got.item.insert_text);
    try t.expectEqual(@as(u32, 3), got.item.range.?.start.line);
    try t.expectEqual(@as(u32, 4), got.item.range.?.start.character);
    try t.expectEqual(@as(u32, 9), got.item.range.?.end.character);
    // The opaque telemetry id survives the round trip — a rebuilt
    // command would lose it and Copilot would never learn the accept.
    try t.expect(std.mem.indexOf(u8, got.item.command_json.?, "op-42") != null);
    try t.expect(std.mem.indexOf(u8, got.item_json, "printLine") != null);
    // An empty `items` is "nothing to suggest", not an error.
    var e = try parse(t.allocator, "{\"items\":[]}");
    defer e.deinit();
    try t.expect(try readCompletion(arena.allocator(), e.value) == null);
    try t.expect(try readCompletion(arena.allocator(), null) == null);
}
