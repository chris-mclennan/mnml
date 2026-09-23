//! Anthropic's Messages API over `std.http.Client`: the request body,
//! the reply, and one blocking `post`. The agentic loop that calls it
//! lives in `src/app/ai.zig`; this file knows nothing of the app and is
//! exercised against a fake server in its tests.
//!
//! Auth is `x-api-key` (never a bearer header — the API rejects one) plus
//! `anthropic-version`. Streaming is not used: a reply is one JSON
//! document, parsed into `Reply`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const endpoint = "https://api.anthropic.com/v1/messages";
/// The environment variable that points every Messages request at
/// another base URL (`http://127.0.0.1:19711`): a mock in the tests, a
/// proxy or a gateway in real use. Read from the App's environment
/// only — never from a workspace config, which a cloned repo writes
/// and which would then decide where the API key goes.
pub const base_url_env = "MNML_ANTHROPIC_BASE_URL";

/// The Messages endpoint for `env`: `<base>/v1/messages` when
/// `MNML_ANTHROPIC_BASE_URL` is set (a trailing `/` dropped), else the
/// real one.
pub fn endpointFor(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]const u8 {
    const base = std.mem.trimEnd(u8, std.mem.trim(u8, env.get(base_url_env) orelse "", " \t"), "/");
    if (base.len == 0) return endpoint;
    return std.fmt.allocPrint(arena, "{s}/v1/messages", .{base});
}
pub const api_version = "2023-06-01";
pub const default_model = "claude-sonnet-4-5";
pub const default_max_tokens: u32 = 4096;
pub const env_key = "ANTHROPIC_API_KEY";

/// One content block of a message, either direction.
pub const Block = union(enum) {
    text: []const u8,
    /// The model asked for a tool; `input_json` is the raw object.
    tool_use: struct { id: []const u8, name: []const u8, input_json: []const u8 },
    /// Our answer to a tool call.
    tool_result: struct { tool_use_id: []const u8, content: []const u8, is_error: bool = false },
};

pub const Message = struct {
    role: []const u8,
    blocks: []const Block,
};

/// Which tools the request advertises.
pub const ToolSet = enum { none, read_only, with_write };

pub const RequestOpts = struct {
    model: []const u8 = default_model,
    max_tokens: u32 = default_max_tokens,
    system: ?[]const u8 = null,
    messages: []const Message,
    tools: ToolSet = .none,
};

/// The request body. Owned by the caller.
pub fn encodeRequest(gpa: Allocator, opts: RequestOpts) Allocator.Error![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: std.json.Stringify = .{ .writer = &out.writer };
    writeRequest(&s, opts) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeRequest(s: *std.json.Stringify, opts: RequestOpts) !void {
    try s.beginObject();
    try s.objectField("model");
    try s.write(opts.model);
    try s.objectField("max_tokens");
    try s.write(opts.max_tokens);
    if (opts.system) |sys| {
        try s.objectField("system");
        try s.write(sys);
    }
    if (opts.tools != .none) {
        try s.objectField("tools");
        try writeTools(s, opts.tools == .with_write);
    }
    try s.objectField("messages");
    try s.beginArray();
    for (opts.messages) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role);
        try s.objectField("content");
        // A lone text block is sent as a plain string — the shape the
        // API documents first, and what a transcript reader expects.
        if (m.blocks.len == 1 and m.blocks[0] == .text) {
            try s.write(m.blocks[0].text);
        } else {
            try s.beginArray();
            for (m.blocks) |b| try writeBlock(s, b);
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn writeBlock(s: *std.json.Stringify, b: Block) !void {
    try s.beginObject();
    try s.objectField("type");
    switch (b) {
        .text => |tx| {
            try s.write("text");
            try s.objectField("text");
            try s.write(tx);
        },
        .tool_use => |tu| {
            try s.write("tool_use");
            try s.objectField("id");
            try s.write(tu.id);
            try s.objectField("name");
            try s.write(tu.name);
            try s.objectField("input");
            try s.beginWriteRaw();
            try s.writer.writeAll(if (tu.input_json.len == 0) "{}" else tu.input_json);
            s.endWriteRaw();
        },
        .tool_result => |tr| {
            try s.write("tool_result");
            try s.objectField("tool_use_id");
            try s.write(tr.tool_use_id);
            try s.objectField("content");
            try s.write(tr.content);
            if (tr.is_error) {
                try s.objectField("is_error");
                try s.write(true);
            }
        },
    }
    try s.endObject();
}

/// The workspace tools. Read-only always; `write_file` when opted in.
/// Every write goes through the user's confirm (`src/app/ai.zig`).
pub const Tool = struct { name: []const u8, description: []const u8, params: []const Param };
pub const Param = struct { name: []const u8, description: []const u8 };

pub const read_tools = [_]Tool{
    .{ .name = "read_file", .description = "Read a text file from the project workspace.", .params = &.{.{ .name = "path", .description = "Workspace-relative file path." }} },
    .{ .name = "list_directory", .description = "List the entries of a directory in the project workspace.", .params = &.{.{ .name = "path", .description = "Workspace-relative directory path." }} },
    .{ .name = "grep", .description = "Search the workspace's text files for a substring; returns path:line: text matches.", .params = &.{.{ .name = "pattern", .description = "The text to search for." }} },
};
pub const write_tool: Tool = .{ .name = "write_file", .description = "Replace the full contents of a file in the project workspace. The user confirms every write.", .params = &.{ .{ .name = "path", .description = "Workspace-relative file path." }, .{ .name = "content", .description = "The full new file contents." } } };

fn writeTools(s: *std.json.Stringify, write: bool) !void {
    try s.beginArray();
    for (read_tools) |tool| try writeTool(s, tool);
    if (write) try writeTool(s, write_tool);
    try s.endArray();
}

fn writeTool(s: *std.json.Stringify, tool: Tool) !void {
    try s.beginObject();
    try s.objectField("name");
    try s.write(tool.name);
    try s.objectField("description");
    try s.write(tool.description);
    try s.objectField("input_schema");
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
    for (tool.params) |p| {
        try s.objectField(p.name);
        try s.beginObject();
        try s.objectField("type");
        try s.write("string");
        try s.objectField("description");
        try s.write(p.description);
        try s.endObject();
    }
    try s.endObject();
    try s.objectField("required");
    try s.beginArray();
    for (tool.params) |p| try s.write(p.name);
    try s.endArray();
    try s.endObject();
    try s.endObject();
}

/// The system prompt of the agent loop: what the tools are and how
/// writes are gated.
pub fn agentSystemPrompt(arena: Allocator, user: ?[]const u8, write: bool) Allocator.Error![]u8 {
    const tools: []const u8 = if (write) "read_file, list_directory, grep, write_file" else "read_file, list_directory, grep";
    const base = try std.fmt.allocPrint(arena, "You are a coding assistant inside the mnml editor, working in the user's project workspace. You have tools — {s} — to explore the code before answering; use them when the question needs the actual source. Keep answers concise and put code in fenced blocks.{s}", .{ tools, if (write) " Every write_file call is shown to the user for confirmation; a denied write comes back as an error result." else "" });
    if (user) |u| return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ base, u });
    return base;
}

// ─── the reply ──────────────────────────────────────────────────────────

pub const ToolUse = struct { id: []const u8, name: []const u8, input_json: []const u8, input: std.json.Value };

pub const Reply = struct {
    arena: std.heap.ArenaAllocator,
    /// Every text block, concatenated.
    text: []const u8 = "",
    tool_uses: []ToolUse = &.{},
    stop_reason: []const u8 = "",
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,

    pub fn deinit(r: *Reply) void {
        r.arena.deinit();
    }
};

pub const ParseError = error{ OutOfMemory, BadReply };

/// A `/v1/messages` reply. `error.BadReply` for anything that is not a
/// message object; an API `error` object surfaces through `errorMessage`.
pub fn parseReply(gpa: Allocator, json: []const u8) ParseError!Reply {
    var r: Reply = .{ .arena = .init(gpa) };
    errdefer r.deinit();
    const a = r.arena.allocator();
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadReply,
    };
    if (v != .object) return error.BadReply;
    const content = v.object.get("content") orelse return error.BadReply;
    if (content != .array) return error.BadReply;
    var text: std.ArrayList(u8) = .empty;
    var uses: std.ArrayList(ToolUse) = .empty;
    for (content.array.items) |block| {
        if (block != .object) continue;
        const ty = strOf(block, "type") orelse continue;
        if (std.mem.eql(u8, ty, "text")) {
            try text.appendSlice(a, strOf(block, "text") orelse "");
        } else if (std.mem.eql(u8, ty, "tool_use")) {
            const input = block.object.get("input") orelse std.json.Value{ .null = {} };
            var raw: Io.Writer.Allocating = .init(a);
            std.json.Stringify.value(input, .{}, &raw.writer) catch return error.OutOfMemory;
            try uses.append(a, .{
                .id = strOf(block, "id") orelse "",
                .name = strOf(block, "name") orelse "",
                .input_json = raw.written(),
                .input = input,
            });
        }
    }
    r.text = text.items;
    r.tool_uses = uses.items;
    r.stop_reason = strOf(v, "stop_reason") orelse "";
    if (v.object.get("usage")) |u| {
        r.input_tokens = intOf(u, "input_tokens");
        r.output_tokens = intOf(u, "output_tokens");
    }
    return r;
}

/// `{"error":{"type":…,"message":…}}` → the message, on `arena`.
pub fn errorMessage(arena: Allocator, json: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return null;
    if (v != .object) return null;
    const e = v.object.get("error") orelse return null;
    return strOf(e, "message");
}

/// A string field of a tool's input.
pub fn inputStr(input: std.json.Value, key: []const u8) ?[]const u8 {
    return strOf(input, key);
}

fn strOf(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

fn intOf(v: std.json.Value, key: []const u8) u64 {
    if (v != .object) return 0;
    const f = v.object.get(key) orelse return 0;
    return switch (f) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        else => 0,
    };
}

// ─── the wire ───────────────────────────────────────────────────────────

pub const Response = struct {
    status: u16,
    /// Owned by the caller.
    body: []u8,
    /// A `retry-after: <seconds>` the server sent (a 429, a 529).
    retry_after_s: ?u32 = null,
};

pub const PostError = error{ OutOfMemory, Canceled, Failed };

/// POST `body` to `url` with the Messages headers. Blocking; call it
/// from a worker. Any transport failure is `error.Failed`. The shape of
/// `std.http.Client.fetch`, spelled out so the `retry-after` header of
/// a rate-limited answer can be read before the body is.
pub fn post(gpa: Allocator, io: Io, url: []const u8, api_key: []const u8, body: []const u8) PostError!Response {
    return postInner(gpa, io, url, api_key, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return error.Failed,
    };
}

fn postInner(gpa: Allocator, io: Io, url: []const u8, api_key: []const u8, body: []const u8) !Response {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const headers = [_]std.http.Header{
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = api_version },
    };
    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &headers,
        .keep_alive = false,
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var bw = try req.sendBodyUnflushed(&.{});
    try bw.writer.writeAll(body);
    try bw.end();
    try req.connection.?.flush();
    var response = try req.receiveHead(&.{});
    // The head's strings are gone once the body is read.
    var retry_after: ?u32 = null;
    var it = response.head.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
        retry_after = std.fmt.parseInt(u32, std.mem.trim(u8, h.value, " \t"), 10) catch null;
    };
    const status: u16 = @intFromEnum(response.head.status);
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&out.writer) catch |err| switch (err) {
        // The body's own error, else the socket's — a cancel lands on
        // the socket, and `fetch`'s bare `bodyErr().?` panicked on it.
        error.ReadFailed => {
            if (response.bodyErr()) |e| return e;
            if (req.connection) |c| if (c.stream_reader.err) |e| return e;
            return error.ReadFailed;
        },
        else => |e| return e,
    };
    return .{ .status = status, .body = try out.toOwnedSlice(), .retry_after_s = retry_after };
}

/// The one-shot completion request the ghost text sends.
pub fn completionRequest(gpa: Allocator, model: []const u8, system: []const u8, user: []const u8, max_tokens: u32) Allocator.Error![]u8 {
    return encodeRequest(gpa, .{
        .model = model,
        .max_tokens = max_tokens,
        .system = system,
        .messages = &.{.{ .role = "user", .blocks = &.{.{ .text = user }} }},
    });
}

// ─── tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "encodeRequest: model, system, a plain user turn, tool blocks and the tool list" {
    const body = try encodeRequest(t.allocator, .{
        .model = "m",
        .max_tokens = 7,
        .system = "sys \"q\"",
        .tools = .with_write,
        .messages = &.{
            .{ .role = "user", .blocks = &.{.{ .text = "hi" }} },
            .{ .role = "assistant", .blocks = &.{ .{ .text = "look" }, .{ .tool_use = .{ .id = "t1", .name = "read_file", .input_json = "{\"path\":\"a\"}" } } } },
            .{ .role = "user", .blocks = &.{.{ .tool_result = .{ .tool_use_id = "t1", .content = "x", .is_error = true } }} },
        },
    });
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"model\":\"m\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"max_tokens\":7") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"system\":\"sys \\\"q\\\"\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"content\":\"hi\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"read_file\",\"input\":{\"path\":\"a\"}}") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"tool_use_id\":\"t1\",\"content\":\"x\",\"is_error\":true") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"name\":\"write_file\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"required\":[\"path\",\"content\"]") != null);
    // Valid JSON end to end.
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, body, .{});
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 4), parsed.value.object.get("tools").?.array.items.len);
    // Read-only omits write_file; none omits the key.
    const ro = try encodeRequest(t.allocator, .{ .tools = .read_only, .messages = &.{} });
    defer t.allocator.free(ro);
    try t.expect(std.mem.indexOf(u8, ro, "write_file") == null);
    const none = try encodeRequest(t.allocator, .{ .messages = &.{} });
    defer t.allocator.free(none);
    try t.expect(std.mem.indexOf(u8, none, "\"tools\"") == null);
}

pub const reply_fixture =
    \\{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-5","stop_reason":"tool_use",
    \\ "content":[{"type":"text","text":"Let me look. "},{"type":"tool_use","id":"toolu_9","name":"read_file","input":{"path":"src/main.zig"}},{"type":"text","text":"Done."}],
    \\ "usage":{"input_tokens":12,"output_tokens":34}}
;

test "parseReply: text concatenated, tool uses with their raw input, stop reason and usage" {
    var r = try parseReply(t.allocator, reply_fixture);
    defer r.deinit();
    try t.expectEqualStrings("Let me look. Done.", r.text);
    try t.expectEqualStrings("tool_use", r.stop_reason);
    try t.expectEqual(@as(usize, 1), r.tool_uses.len);
    try t.expectEqualStrings("read_file", r.tool_uses[0].name);
    try t.expectEqualStrings("toolu_9", r.tool_uses[0].id);
    try t.expectEqualStrings("{\"path\":\"src/main.zig\"}", r.tool_uses[0].input_json);
    try t.expectEqualStrings("src/main.zig", inputStr(r.tool_uses[0].input, "path").?);
    try t.expectEqual(@as(u64, 12), r.input_tokens);
    try t.expectEqual(@as(u64, 34), r.output_tokens);
    try t.expectError(error.BadReply, parseReply(t.allocator, "[1,2]"));
    try t.expectError(error.BadReply, parseReply(t.allocator, "{\"error\":{\"message\":\"nope\"}}"));
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("nope", errorMessage(arena.allocator(), "{\"error\":{\"type\":\"x\",\"message\":\"nope\"}}").?);
    try t.expect(errorMessage(arena.allocator(), "junk") == null);
}

/// A one-request server on the loopback: records the request line,
/// the auth header and the body, answers `reply_fixture`.
const FakeServer = struct {
    var saw_key: [64]u8 = undefined;
    var saw_key_len: usize = 0;
    var saw_body: [4096]u8 = undefined;
    var saw_body_len: usize = 0;
    var saw_target: [64]u8 = undefined;
    var saw_target_len: usize = 0;

    fn serve(io: Io, server: *Io.net.Server) Io.Cancelable!void {
        const stream = server.accept(io) catch return;
        defer stream.close(io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch return;
        @memcpy(saw_target[0..request.head.target.len], request.head.target);
        saw_target_len = request.head.target.len;
        var it = request.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-api-key")) {
                @memcpy(saw_key[0..h.value.len], h.value);
                saw_key_len = h.value.len;
            }
        }
        var body_buf: [4096]u8 = undefined;
        const body_reader = request.readerExpectNone(&body_buf);
        // `readerExpectNone` hands back `Reader.ending` for a method
        // with no body — a `@constCast` of a const global. Reading from
        // it writes `seek` back through that const pointer: a segfault
        // on Linux, silently tolerated on macOS. Only read a body the
        // method can actually carry.
        const n = if (request.head.method.requestHasBody())
            body_reader.readSliceShort(&saw_body) catch 0
        else
            0;
        saw_body_len = n;
        request.respond(reply_fixture, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} }) catch return;
    }
};

test "post: a fake Messages server sees the key and the body; the client parses the reply" {
    const io = t.io;
    var addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    var group: Io.Group = .init;
    try group.concurrent(io, FakeServer.serve, .{ io, &server });
    defer group.cancel(io);

    const url = try std.fmt.allocPrint(t.allocator, "http://127.0.0.1:{d}/v1/messages", .{port});
    defer t.allocator.free(url);
    const body = try completionRequest(t.allocator, "claude-haiku-4-5", "sys", "fn main() {", 64);
    defer t.allocator.free(body);
    const res = try post(t.allocator, io, url, "sk-test-key", body);
    defer t.allocator.free(res.body);
    try group.await(io);
    try t.expectEqual(@as(u16, 200), res.status);
    try t.expectEqualStrings("sk-test-key", FakeServer.saw_key[0..FakeServer.saw_key_len]);
    try t.expectEqualStrings("/v1/messages", FakeServer.saw_target[0..FakeServer.saw_target_len]);
    try t.expectEqualStrings(body, FakeServer.saw_body[0..FakeServer.saw_body_len]);
    var r = try parseReply(t.allocator, res.body);
    defer r.deinit();
    try t.expectEqualStrings("Let me look. Done.", r.text);
}
